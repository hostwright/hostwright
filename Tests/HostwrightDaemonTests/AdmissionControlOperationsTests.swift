import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightControlSecurity
@testable import HostwrightDaemon
@testable import HostwrightPolicy
@testable import HostwrightState

final class AdmissionControlOperationsTests: XCTestCase {
  private let timestamp = "2026-08-02T20:00:00Z"
  private let now = ISO8601DateFormatter().date(from: "2026-08-02T20:30:00Z")!

  func testEveryAdmissionOperationRejectsUnknownBodyFieldsWithoutStateChange() throws {
    try withFixture { fixture in
      let policy = try fixture.installPolicy("existing-policy")
      let exception = try fixture.installException(policyID: policy.policyID)
      let targetRequest = request("service.update", body: .object([:]))
      let validPolicyDocument = policyDocument()
      let cases: [(String, [String: ControlPlaneJSONValue])] = [
        ("admission.preview", ["request": value(targetRequest)]),
        ("admission.policy.list", [:]),
        (
          "admission.policy.create",
          [
            "identifier": .string("new-policy"), "version": .integer(1),
            "stage": .string("extensionValidation"), "failurePolicy": .string("deny"),
            "advisory": .bool(false), "document": validPolicyDocument,
          ]
        ),
        (
          "admission.policy.set-enabled",
          [
            "identifier": .string(policy.policyID), "enabled": .bool(false),
            "expectedGeneration": .integer(Int64(policy.generation)),
          ]
        ),
        (
          "admission.policy.delete",
          [
            "identifier": .string(policy.policyID),
            "expectedGeneration": .integer(Int64(policy.generation)),
          ]
        ),
        ("admission.exception.list", [:]),
        (
          "admission.exception.create",
          [
            "identifier": .string("new-exception"), "policyID": .string(policy.policyID),
            "subjectID": .string("owner"),
            "target": .string("operation:service.update|project:-|resource:-"),
            "planHash": .string(String(repeating: "a", count: 64)),
            "approvalIdentity": .string("security-approver"),
            "expiresAt": .string("2026-08-02T21:00:00Z"),
          ]
        ),
        (
          "admission.exception.delete",
          [
            "identifier": .string(exception.exceptionID),
            "expectedGeneration": .integer(Int64(exception.generation)),
          ]
        ),
      ]
      let policiesBefore = try fixture.admission.listPolicies()
      let exceptionsBefore = try fixture.admission.listExceptions()

      for (operation, fields) in cases {
        var invalid = fields
        invalid["unexpected"] = .bool(true)
        let response = try XCTUnwrap(fixture.handle(request(operation, body: .object(invalid))))
        XCTAssertEqual(response.status, .rejected, "\(operation) accepted an unknown body key")
        XCTAssertEqual(response.reasonCode, .invalidRequest)
        XCTAssertEqual(response.error?.code, "invalidAdmissionRequest")
      }

      XCTAssertEqual(try fixture.admission.listPolicies(), policiesBefore)
      XCTAssertEqual(try fixture.admission.listExceptions(), exceptionsBefore)
    }
  }

  func testAdmissionManagementRequiresPolicyAuthorityAndAllowsSecurityAdmin() throws {
    try withFixture(subjects: ["member", "security"]) { fixture in
      let document = policyDocument()
      let member = fixture.withPeer(subjectID: "member", codeHash: String(repeating: "b", count: 40))
      let denied = try XCTUnwrap(
        member.handle(policyCreateRequest(identifier: "member-policy", document: document)))
      XCTAssertEqual(denied.status, .rejected)
      XCTAssertEqual(denied.reasonCode, .unauthorized)
      XCTAssertEqual(denied.error?.code, "admissionManagementDenied")
      XCTAssertNil(try fixture.admission.policy(id: "member-policy"))

      _ = try fixture.rbac.createBinding(
        RBACBindingRecord(
          bindingID: "security-admin", subjectID: "security", roleID: "security-admin",
          scope: .init(kind: .global), createdBySubjectID: "owner", createdAt: timestamp,
          updatedAt: timestamp))
      let security = fixture.withPeer(subjectID: "security", codeHash: String(repeating: "c", count: 40))
      let created = try XCTUnwrap(
        security.handle(policyCreateRequest(identifier: "security-policy", document: document)))
      XCTAssertEqual(created.status, .completed)
      XCTAssertEqual(try fixture.admission.policy(id: "security-policy")?.createdBySubjectID, "security")
    }
  }

  func testPolicyCreateRejectsMalformedAndOverbroadPolicyDocumentsWithoutPersistence() throws {
    try withFixture { fixture in
      let malformed = try XCTUnwrap(fixture.handle(policyCreateRequest(
        identifier: "malformed-policy", document: .object(["schemaVersion": .integer(1)]))))
      XCTAssertEqual(malformed.status, .rejected)
      XCTAssertEqual(malformed.reasonCode, .invalidRequest)
      XCTAssertEqual(malformed.error?.code, "invalidAdmissionRequest")

      let wildcard = try XCTUnwrap(fixture.handle(policyCreateRequest(
        identifier: "wildcard-policy",
        document: policyDocument(operations: ["service.*"]))))
      XCTAssertEqual(wildcard.status, .rejected)
      XCTAssertEqual(wildcard.reasonCode, .invalidRequest)
      XCTAssertNil(try fixture.admission.policy(id: "malformed-policy"))
      XCTAssertNil(try fixture.admission.policy(id: "wildcard-policy"))
    }
  }

  private func policyCreateRequest(
    identifier: String, document: ControlPlaneJSONValue
  ) -> ControlRequestEnvelope {
    request(
      "admission.policy.create",
      body: .object([
        "identifier": .string(identifier), "version": .integer(1),
        "stage": .string("extensionValidation"), "failurePolicy": .string("deny"),
        "advisory": .bool(false), "document": document,
      ]))
  }

  private func policyDocument(
    operations: [String] = ["service.update"]
  ) -> ControlPlaneJSONValue {
    .object([
      "schemaVersion": .integer(1),
      "operations": .array(operations.map(ControlPlaneJSONValue.string)),
      "conditions": .array([]), "mutations": .array([]),
      "validations": .array([
        .object([
          "kind": .string("forbidden"), "fieldPath": .string("/hostAccess"),
          "reasonCode": .string("admission.host-access-forbidden"),
        ])
      ]),
    ])
  }

  private func request(
    _ operation: String, body: ControlPlaneJSONValue? = nil
  ) -> ControlRequestEnvelope {
    ControlRequestEnvelope(
      requestID: "admission-\(UUID().uuidString)", operation: operation,
      timeoutMilliseconds: 1_000, body: body)
  }

  private func value<T: Encodable>(_ value: T) -> ControlPlaneJSONValue {
    try! JSONDecoder().decode(ControlPlaneJSONValue.self, from: JSONEncoder().encode(value))
  }

  private func withFixture(
    subjects: [String] = [], _ body: (Fixture) throws -> Void
  ) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-admission-control-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }

    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity("owner", hash: "a", declaredBy: "owner"))
    try store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: timestamp)
    for (index, subjectID) in subjects.enumerated() {
      let hash = String(UnicodeScalar(98 + index)!)
      try store.controlIdentities.declare(identity(subjectID, hash: hash, declaredBy: "owner"))
    }
    let authorizer = RBACAuthorizationEngine(repository: store.rbac)
    let administration = AdmissionAdministrationService(
      repository: store.admission, authorizer: authorizer)
    try body(
      Fixture(
        admission: store.admission, rbac: store.rbac, administration: administration,
        engine: AdmissionPolicyEngine(repository: store.admission),
        peer: peer(subjectID: "owner", codeHash: String(repeating: "a", count: 40))))
  }

  private func identity(
    _ subjectID: String, hash: String, declaredBy: String
  ) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: subjectID, userID: 501,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright-test",
        codeDirectoryHash: String(repeating: hash, count: 40), validationMode: .installedRequirement),
      declaredBySubjectID: declaredBy, declaredAt: timestamp, updatedAt: timestamp)
  }

  private func peer(subjectID: String, codeHash: String) -> AuthenticatedControlPeer {
    Self.makePeer(subjectID: subjectID, codeHash: codeHash)
  }

  private static func makePeer(subjectID: String, codeHash: String) -> AuthenticatedControlPeer {
    AuthenticatedControlPeer(
      binding: ControlSessionBinding(
        sessionID: "session", daemonGeneration: 1, serverNonce: "nonce", socketDevice: 1,
        socketInode: 2,
        peer: UnixPeerIdentity(
          effectiveUID: 501, effectiveGID: 20, pid: 123, pidVersion: 1, auditSessionID: 1,
          codeIdentity: CodeIdentity(
            teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright-test",
            codeDirectoryHash: codeHash, validationMode: .installedRequirement)),
        subject: LocalSubject(identifier: subjectID, userID: 501, codeIdentityHash: codeHash)))
  }

  private struct Fixture {
    let admission: AdmissionRepository
    let rbac: RBACRepository
    let administration: AdmissionAdministrationService
    let engine: AdmissionPolicyEngine
    let peer: AuthenticatedControlPeer

    func handle(_ request: ControlRequestEnvelope) -> ControlResponseEnvelope? {
      AdmissionControlOperations.handle(
        peer: peer, request: request, repository: admission, administration: administration,
        engine: engine, now: ISO8601DateFormatter().date(from: "2026-08-02T20:30:00Z")!)
    }

    func installPolicy(_ identifier: String) throws -> AdmissionPolicyRecord {
      let document = ControlPlaneJSONValue.object([
        "schemaVersion": .integer(1), "operations": .array([.string("service.update")]),
        "conditions": .array([]), "mutations": .array([]),
        "validations": .array([
          .object([
            "kind": .string("forbidden"), "fieldPath": .string("/hostAccess"),
            "reasonCode": .string("admission.host-access-forbidden"),
          ])
        ]),
      ])
      return try admission.createPolicy(
        AdmissionPolicyRecord(
          policyID: identifier, version: 1, sourceKind: .extension, stage: .extensionValidation,
          failurePolicy: .deny, advisory: false, mutating: false, document: document,
          documentSHA256: try AdmissionPolicyRecord.digest(document), createdBySubjectID: "owner",
          createdAt: "2026-08-02T20:00:00Z", updatedAt: "2026-08-02T20:00:00Z"))
    }

    func installException(policyID: String) throws -> AdmissionExceptionRecord {
      try admission.createException(
        AdmissionExceptionRecord(
          exceptionID: "existing-exception", policyID: policyID, subjectID: "owner",
          target: "operation:service.update|project:-|resource:-",
          planHash: String(repeating: "a", count: 64), approvalIdentity: "security-approver",
          expiresAt: "2026-08-02T21:00:00Z", createdBySubjectID: "owner",
          createdAt: "2026-08-02T20:00:00Z", updatedAt: "2026-08-02T20:00:00Z"))
    }

    func withPeer(subjectID: String, codeHash: String) -> Fixture {
      Fixture(
        admission: admission, rbac: rbac, administration: administration, engine: engine,
        peer: AdmissionControlOperationsTests.makePeer(subjectID: subjectID, codeHash: codeHash))
    }
  }
}
