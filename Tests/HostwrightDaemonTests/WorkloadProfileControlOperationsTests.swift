import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightControlSecurity
@testable import HostwrightDaemon
@testable import HostwrightPolicy
@testable import HostwrightState

final class WorkloadProfileControlOperationsTests: XCTestCase {
  private let timestamp = "2026-08-03T00:00:00Z"
  private let now = ISO8601DateFormatter().date(from: "2026-08-03T00:30:00Z")!

  func testEveryProfileOperationRejectsUnknownBodyFieldsWithoutStateChange() throws {
    try withFixture { fixture in
      let existing = try fixture.create(baseProfile("existing"))
      let candidate = baseProfile("candidate")
      let cases: [(String, [String: ControlPlaneJSONValue])] = [
        ("profile.list", [:]),
        ("profile.get", ["identifier": .string(existing.profile.identifier)]),
        ("profile.resolve", ["identifier": .string(existing.profile.identifier)]),
        ("profile.preview", ["profile": value(candidate), "baseIdentifier": .string(existing.profile.identifier)]),
        (
          "profile.drift",
          [
            "identifier": .string(existing.profile.identifier),
            "observedProfileSHA256": .string(existing.profileSHA256), "reasons": .array([]),
          ]
        ),
        ("profile.create", ["profile": value(baseProfile("new-profile"))]),
        (
          "profile.update",
          ["profile": value(existing.profile), "expectedGeneration": .integer(Int64(existing.generation))]
        ),
        (
          "profile.delete",
          ["identifier": .string(existing.profile.identifier), "expectedGeneration": .integer(Int64(existing.generation))]
        ),
      ]
      let before = try fixture.repository.listProfiles()

      for (operation, fields) in cases {
        var invalid = fields
        invalid["unexpected"] = .bool(true)
        assertInvalid(fixture.handle(request(operation, body: invalid)), operation: operation)
      }

      XCTAssertEqual(try fixture.repository.listProfiles(), before)
    }
  }

  func testOwnerControlsCreateUpdateResolvePreviewDriftAndDelete() throws {
    try withFixture { fixture in
      let base = try XCTUnwrap(fixture.handle(request("profile.create", body: ["profile": value(baseProfile("base"))])))
      XCTAssertEqual(base.status, .completed)

      let child = profile("child", parent: "base", hostAccess: false)
      let created = try XCTUnwrap(
        fixture.handle(request("profile.create", body: ["profile": value(child)])))
      let childRecord = try decode(WorkloadProfileRecord.self, from: created.result)
      XCTAssertEqual(childRecord.generation, 1)

      let get = try XCTUnwrap(fixture.handle(request("profile.get", body: ["identifier": .string("child")])))
      XCTAssertEqual(try decode(WorkloadProfileRecord.self, from: get.result), childRecord)
      let resolved = try XCTUnwrap(
        fixture.handle(request("profile.resolve", body: ["identifier": .string("child")])))
      XCTAssertEqual(try decode(WorkloadProfileResolution.self, from: resolved.result).inheritance, ["base", "child"])

      let preview = try XCTUnwrap(
        fixture.handle(request("profile.preview", body: ["profile": value(child), "baseIdentifier": .string("base")])))
      let previewFields = try object(preview.result)
      let baseResolution = try fixture.engine.resolve(id: "base")
      let proposal = try fixture.engine.proposedResolution(child)
      XCTAssertEqual(previewFields["baseProfileSHA256"], .string(baseResolution.profileSHA256))
      XCTAssertEqual(previewFields["profileSHA256"], .string(proposal.profileSHA256))
      XCTAssertEqual(previewFields["recordSHA256"], .string(childRecord.profileSHA256))
      XCTAssertEqual(previewFields["inheritance"], .array([.string("base"), .string("child")]))
      XCTAssertEqual(previewFields["weakeningReasons"], .array([]))

      let drift = try XCTUnwrap(
        fixture.handle(
          request(
            "profile.drift",
            body: [
              "identifier": .string("child"),
              "observedProfileSHA256": .string(String(repeating: "0", count: 64)),
              "reasons": .array([.string("runtime.disappeared")]),
            ])))
      XCTAssertTrue(try decode(WorkloadProfileDrift.self, from: drift.result).drifted)

      let updatedProfile = profile("child", parent: "base", hostAccess: false, logs: false)
      let updated = try XCTUnwrap(
        fixture.handle(
          request(
            "profile.update",
            body: ["profile": value(updatedProfile), "expectedGeneration": .integer(1)])))
      XCTAssertEqual(try decode(WorkloadProfileRecord.self, from: updated.result).generation, 2)

      let deleted = try XCTUnwrap(
        fixture.handle(
          request("profile.delete", body: ["identifier": .string("child"), "expectedGeneration": .integer(2)])))
      XCTAssertEqual(deleted.result, .object(["deleted": .bool(true)]))
      XCTAssertNil(try fixture.repository.profile(id: "child"))
    }
  }

  func testRBACReadWriteAndWeakeningApprovalAreFailClosed() throws {
    try withFixture(subjects: ["member", "security"]) { fixture in
      let memberRequest = request("profile.list")
      XCTAssertEqual(
        try fixture.authorizer.preview(subjectID: "member", request: memberRequest, at: now).effect,
        .deny)
      XCTAssertEqual(
        try fixture.authorizer.preview(subjectID: "security", request: memberRequest, at: now).effect,
        .deny)

      _ = try fixture.rbac.createBinding(
        binding("security-admin", subject: "security", role: "security-admin"))
      XCTAssertEqual(
        try fixture.authorizer.preview(subjectID: "security", request: memberRequest, at: now).effect,
        .allow)

      let member = fixture.withPeer(subjectID: "member", hash: String(repeating: "b", count: 40))
      let deniedCreate = try XCTUnwrap(
        member.handle(request("profile.create", body: ["profile": value(baseProfile("member-profile"))])))
      XCTAssertEqual(deniedCreate.status, .rejected)
      XCTAssertEqual(deniedCreate.reasonCode, .unauthorized)
      XCTAssertEqual(deniedCreate.error?.code, "profileManagementDenied")
      XCTAssertNil(try fixture.repository.profile(id: "member-profile"))

      let security = fixture.withPeer(subjectID: "security", hash: String(repeating: "c", count: 40))
      let base = try XCTUnwrap(
        security.handle(request("profile.create", body: ["profile": value(baseProfile("strict-base"))])))
      _ = try decode(WorkloadProfileRecord.self, from: base.result)
      let baseResolution = try fixture.engine.resolve(id: "strict-base")
      let weaker = profile("weaker", parent: "strict-base", hostAccess: true)
      let noApproval = try XCTUnwrap(
        security.handle(request("profile.create", body: ["profile": value(weaker)])))
      XCTAssertEqual(noApproval.status, .rejected)
      XCTAssertEqual(noApproval.reasonCode, .admissionDenied)
      XCTAssertEqual(noApproval.error?.code, "profileWeakeningApprovalRequired")

      let candidateHash = try fixture.engine.proposedResolution(weaker).profileSHA256
      let approval = WorkloadProfileWeakeningApproval(
        profileIdentifier: "weaker", baseProfileSHA256: baseResolution.profileSHA256,
        candidateProfileSHA256: candidateHash, approvalIdentity: "security",
        expiresAt: "2026-08-03T01:00:00Z")
      let accepted = try XCTUnwrap(
        security.handle(
          request(
            "profile.create",
            body: ["profile": value(weaker), "weakeningApproval": value(approval)])))
      XCTAssertEqual(accepted.status, .completed)
    }
  }

  func testAdmissionBindsResolvedWorkloadProfileHashAndRejectsMismatch() throws {
    try withFixture { fixture in
      _ = try fixture.create(baseProfile("bound-profile"))
      let resolution = try fixture.engine.resolve(id: "bound-profile")
      let requestWithoutHash = request(
        "service.update", body: ["workloadProfileID": .string("bound-profile")])
      let evaluation = try fixture.admissionEngine.evaluate(
        subjectID: "owner", request: requestWithoutHash, at: now)
      XCTAssertTrue(evaluation.allowed)
      XCTAssertEqual(evaluation.decisions.first?.reasonCode, "admission.workload-profile-bound")
      XCTAssertEqual(
        try object(evaluation.effectiveRequest.body)["profileHash"],
        .string(resolution.profileSHA256))

      let mismatched = request(
        "service.update",
        body: [
          "workloadProfileID": .string("bound-profile"),
          "profileHash": .string(String(repeating: "f", count: 64)),
        ])
      let denied = try fixture.admissionEngine.evaluate(subjectID: "owner", request: mismatched, at: now)
      XCTAssertFalse(denied.allowed)
      XCTAssertEqual(denied.reasonCode, "admission.profile-hash-conflict")
      XCTAssertEqual(denied.decisions.last?.stage, .conflictDetection)

      let hashOnly = request(
        "service.update",
        body: ["profileHash": .string(resolution.profileSHA256)])
      XCTAssertThrowsError(
        try fixture.admissionEngine.evaluate(subjectID: "owner", request: hashOnly, at: now)) { error in
          XCTAssertEqual(error as? AdmissionPolicyError, .invalidRequest)
        }
    }
  }

  private func assertInvalid(
    _ response: ControlResponseEnvelope?, operation: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(response?.status, .rejected, "\(operation) accepted an unknown field", file: file, line: line)
    XCTAssertEqual(response?.reasonCode, .invalidRequest, file: file, line: line)
    XCTAssertEqual(response?.error?.code, "invalidProfileRequest", file: file, line: line)
  }

  private func request(
    _ operation: String, body: [String: ControlPlaneJSONValue] = [:]
  ) -> ControlRequestEnvelope {
    ControlRequestEnvelope(
      requestID: "profile-request-\(UUID().uuidString)", operation: operation,
      timeoutMilliseconds: 1_000, body: .object(body))
  }

  private func value<T: Encodable>(_ value: T) -> ControlPlaneJSONValue {
    try! JSONDecoder().decode(ControlPlaneJSONValue.self, from: ControlPlaneCanonicalJSON.encode(value))
  }

  private func decode<T: Decodable>(_ type: T.Type, from value: ControlPlaneJSONValue?) throws -> T {
    try JSONDecoder().decode(T.self, from: try ControlPlaneCanonicalJSON.encode(XCTUnwrap(value)))
  }

  private func object(_ value: ControlPlaneJSONValue?) throws -> [String: ControlPlaneJSONValue] {
    guard case .object(let fields) = try XCTUnwrap(value) else {
      throw NSError(domain: "WorkloadProfileControlOperationsTests", code: 1)
    }
    return fields
  }

  private func baseProfile(_ identifier: String) -> WorkloadProfile {
    profile(identifier, hostAccess: false)
  }

  private func profile(
    _ identifier: String, parent: String? = nil, hostAccess: Bool, logs: Bool = true
  ) -> WorkloadProfile {
    WorkloadProfile(
      identifier: identifier, parent: parent,
      filesystem: FilesystemProfile(readOnlyRoot: true, denyHostRoot: true),
      network: NetworkProfile(mode: .isolated), resources: ResourceProfile(cpu: 1, memoryMiB: 64),
      identity: IdentityProfile(runAsUser: 501, runAsGroup: 20, allowRoot: false),
      secrets: SecretsProfile(), images: ImagesProfile(requireDigest: true, requireSignature: false),
      runtime: RuntimeProfile(), hostAccess: HostAccessProfile(allowed: hostAccess),
      observability: ObservabilityProfile(logs: logs, metrics: false, traces: false),
      accelerators: AcceleratorsProfile(), syscalls: SyscallProfile(defaultDeny: false))
  }

  private func binding(_ id: String, subject: String, role: String) -> RBACBindingRecord {
    RBACBindingRecord(
      bindingID: id, subjectID: subject, roleID: role, scope: .init(kind: .global),
      createdBySubjectID: "owner", createdAt: timestamp, updatedAt: timestamp)
  }

  private func withFixture(
    subjects: [String] = [], _ body: (Fixture) throws -> Void
  ) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-profile-control-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity("owner", hash: "a"))
    try store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: timestamp)
    for (index, subject) in subjects.enumerated() {
      let hash = String(UnicodeScalar(98 + index)!)
      try store.controlIdentities.declare(identity(subject, hash: hash))
    }
    let authorizer = RBACAuthorizationEngine(repository: store.rbac)
    let engine = WorkloadProfilePolicyEngine(repository: store.workloadProfiles)
    let administration = WorkloadProfileAdministrationService(
      repository: store.workloadProfiles, authorizer: authorizer)
    let admission = AdmissionPolicyEngine(
      repository: store.admission, workloadProfileResolver: { try engine.resolve(id: $0) })
    try body(
      Fixture(
        repository: store.workloadProfiles, rbac: store.rbac, authorizer: authorizer,
        administration: administration, engine: engine, admissionEngine: admission,
        peer: peer(subjectID: "owner", hash: String(repeating: "a", count: 40))))
  }

  private func identity(_ subjectID: String, hash: String) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: subjectID, userID: 501,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright-test-\(subjectID)",
        codeDirectoryHash: String(repeating: hash, count: 40), validationMode: .installedRequirement),
      declaredBySubjectID: "owner", declaredAt: timestamp, updatedAt: timestamp)
  }

  private func peer(subjectID: String, hash: String) -> AuthenticatedControlPeer {
    AuthenticatedControlPeer(
      binding: ControlSessionBinding(
        sessionID: "profile-session", daemonGeneration: 1, serverNonce: "profile-nonce",
        socketDevice: 1, socketInode: 2,
        peer: UnixPeerIdentity(
          effectiveUID: 501, effectiveGID: 20, pid: 123, pidVersion: 1, auditSessionID: 1,
          codeIdentity: CodeIdentity(
            teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright-test-\(subjectID)",
            codeDirectoryHash: hash, validationMode: .installedRequirement)),
        subject: LocalSubject(identifier: subjectID, userID: 501, codeIdentityHash: hash)))
  }

  private struct Fixture {
    let repository: WorkloadProfileRepository
    let rbac: RBACRepository
    let authorizer: RBACAuthorizationEngine
    let administration: WorkloadProfileAdministrationService
    let engine: WorkloadProfilePolicyEngine
    let admissionEngine: AdmissionPolicyEngine
    let peer: AuthenticatedControlPeer

    func handle(_ request: ControlRequestEnvelope) -> ControlResponseEnvelope? {
      WorkloadProfileControlOperations.handle(
        peer: peer, request: request, repository: repository, administration: administration,
        engine: engine, now: ISO8601DateFormatter().date(from: "2026-08-03T00:30:00Z")!)
    }

    func create(_ profile: WorkloadProfile) throws -> WorkloadProfileRecord {
      try administration.create(profile, approval: nil, actorSubjectID: "owner", at: Date(timeIntervalSince1970: 1_786_073_000))
    }

    func withPeer(subjectID: String, hash: String) -> Fixture {
      Fixture(
        repository: repository, rbac: rbac, authorizer: authorizer, administration: administration,
        engine: engine, admissionEngine: admissionEngine,
        peer: WorkloadProfileControlOperationsTests().peer(subjectID: subjectID, hash: hash))
    }
  }
}
