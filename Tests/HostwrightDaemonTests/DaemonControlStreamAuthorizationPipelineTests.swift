import Foundation
import XCTest
@testable import HostwrightControlPlane
@testable import HostwrightControlSecurity
@testable import HostwrightControlTransport
@testable import HostwrightDaemon
@testable import HostwrightManifest
@testable import HostwrightPolicy
@testable import HostwrightState

final class DaemonControlStreamAuthorizationPipelineTests: XCTestCase {
  private let timestamp = "2026-08-03T02:00:00Z"
  private let decisionDate = ISO8601DateFormatter().date(from: "2026-08-03T02:30:00Z")!
  private let targetA = "11111111-1111-4111-8111-111111111111"
  private let targetB = "22222222-2222-4222-8222-222222222222"
  private let projectUUID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

  func testAdmissionMutationEffectiveDenialIsAuditedBeforeFailClosedWithoutPersistence() throws {
    try withFixture(subjects: ["scoped"]) { fixture in
      try fixture.installScopedExecutor(subjectID: "scoped", target: targetA)
      try fixture.installTargetMutation(from: targetA, to: targetB)
      let request = interactiveRequest(
        target: targetA,
        requestID: "mutation-effective-deny",
        idempotencyKey: "mutation-effective-deny-key"
      )

      XCTAssertThrowsError(
        try fixture.pipeline().authorize(
          peer: peer("scoped", hash: "b"), streamID: "mutation", request: request,
          at: decisionDate)
      ) { error in
        XCTAssertEqual(error as? ControlStreamAuthorizationError, .admissionDenied)
      }

      XCTAssertNil(try fixture.requests.load("mutation-effective-deny"))
      XCTAssertTrue(try fixture.store.operations.loadAll().isEmpty)
      XCTAssertEqual(
        fixture.audit.events.map { "\($0.action.rawValue):\($0.outcome)" },
        ["authorization:allow", "admission:allowed", "authorization:deny"]
      )
      XCTAssertEqual(fixture.audit.events.last?.target, targetB)
      XCTAssertEqual(fixture.audit.events.last?.reasonCode, "authorization.no-allow")
    }
  }

  func testAuditFailureIsDegradedForReadStreamAndFailClosedForInteractiveStream() throws {
    try withFixture(subjects: []) { fixture in
      fixture.audit.failAll = true
      let pipeline = fixture.pipeline()

      let read = try pipeline.authorize(
        peer: peer("owner", hash: "a"),
        streamID: "events",
        request: ControlStreamOpenRequest(source: .events),
        at: decisionDate
      )
      XCTAssertEqual(read.decision.effect, .allow)
      XCTAssertTrue(read.auditHealthDegraded)

      XCTAssertThrowsError(
        try pipeline.authorize(
          peer: peer("owner", hash: "a"),
          streamID: "exec",
          request: interactiveRequest(
            target: targetA,
            requestID: "audit-fail-exec",
            idempotencyKey: "audit-fail-exec-key"
          ),
          at: decisionDate)
      ) { error in
        XCTAssertEqual(error as? ControlStreamAuthorizationError, .auditUnavailable)
      }
      XCTAssertNil(try fixture.requests.load("audit-fail-exec"))
      XCTAssertTrue(try fixture.store.operations.loadAll().isEmpty)
    }
  }

  func testEventAuthorizationResolvesLegacyFilterToAuthoritativeProjectUUID() throws {
    try withFixture(subjects: ["event-reader"]) { fixture in
      _ = try fixture.store.rbac.createCustomRole(
        RBACRoleRecord(
          roleID: "project-event-reader",
          builtIn: false,
          rules: [RBACRule(
            identifier: "project-event-watch",
            effect: .allow,
            resources: [.observability],
            verbs: [.watch],
            scope: RBACScope(kind: .global)
          )],
          createdBySubjectID: "owner",
          createdAt: timestamp,
          updatedAt: timestamp
        ),
        actorSubjectID: "owner",
        timestamp: timestamp
      )
      _ = try fixture.store.rbac.createBinding(RBACBindingRecord(
        bindingID: "project-event-reader-binding",
        subjectID: "event-reader",
        roleID: "project-event-reader",
        scope: RBACScope(kind: .project, identifier: projectUUID),
        createdBySubjectID: "owner",
        createdAt: timestamp,
        updatedAt: timestamp
      ))
      let request = ControlStreamOpenRequest(
        source: .events,
        filter: .object(["projectID": .string("project-probe")])
      )

      let authorization = try fixture.pipeline().authorize(
        peer: peer("event-reader", hash: "b"),
        streamID: "project-events",
        request: request,
        at: decisionDate
      )
      XCTAssertEqual(authorization.decision.effect, .allow)
      XCTAssertEqual(authorization.decision.ruleIdentifiers, ["project-event-watch"])

      XCTAssertThrowsError(try fixture.pipeline().authorize(
        peer: peer("event-reader", hash: "b"),
        streamID: "missing-project-events",
        request: ControlStreamOpenRequest(
          source: .events,
          filter: .object(["projectID": .string("project-missing")])
        ),
        at: decisionDate
      )) { error in
        XCTAssertEqual(error as? ControlStreamAuthorizationError, .invalidRequest)
      }
    }
  }

  func testPreparedRuntimeBindingRejectsSameUUIDOwnershipReplacementBeforeStart() throws {
    try withFixture(subjects: []) { fixture in
      let pipeline = fixture.pipeline()
      let request = interactiveRequest(
        target: targetA,
        requestID: "binding-replacement",
        idempotencyKey: "binding-replacement-key"
      )
      let authorization = try pipeline.authorize(
        peer: peer("owner", hash: "a"),
        streamID: "binding-replacement-stream",
        request: request,
        at: decisionDate
      )
      let bound = try XCTUnwrap(authorization.effectiveRequest)

      try fixture.store.withValidatedConnection { connection in
        try connection.transaction {
          try connection.run(
            """
            UPDATE ownership_records
            SET resource_identifier = ?
            WHERE resource_uuid = ? AND service_name = ?
            """,
            bindings: [
              .text("resource-swapped-after-authorization"),
              .text(targetA),
              .text("probe"),
            ]
          )
        }
      }

      XCTAssertThrowsError(try pipeline.reauthorize(
        peer: peer("owner", hash: "a"),
        request: bound,
        at: decisionDate
      )) { error in
        XCTAssertEqual(error as? ControlStreamAuthorizationError, .invalidRequest)
      }
    }
  }

  func testExactReplayConflictAmbiguousStartAndExpiryUseOneProductionPipeline() throws {
    try withFixture(subjects: []) { fixture in
      let request = interactiveRequest(
        target: targetA,
        requestID: "replay-request",
        idempotencyKey: "replay-key"
      )
      let pipeline = fixture.pipeline()
      let created = try pipeline.authorize(
        peer: peer("owner", hash: "a"), streamID: "created", request: request,
        at: decisionDate)
      XCTAssertTrue(created.shouldStartProducer)

      let exactRetry = try pipeline.authorize(
        peer: peer("owner", hash: "a"), streamID: "retry", request: request,
        at: decisionDate)
      XCTAssertTrue(exactRetry.shouldStartProducer)
      XCTAssertEqual(try fixture.store.operations.loadAll().count, 1)

      let conflicting = interactiveRequest(
        target: targetA,
        requestID: "conflicting-request",
        idempotencyKey: "replay-key"
      )
      XCTAssertThrowsError(
        try pipeline.authorize(
          peer: peer("owner", hash: "a"), streamID: "conflict", request: conflicting,
          at: decisionDate)
      ) { error in
        XCTAssertEqual(error as? ControlStreamAuthorizationError, .idempotencyConflict)
      }

      let operationReference = try XCTUnwrap(created.operationReference)
      let requestID = try XCTUnwrap(request.requestID)
      try fixture.requests.markStreamOperationStarted(
        requestID: requestID,
        operationReference: operationReference,
        updatedAt: "2026-08-03T02:31:00Z"
      )
      let ambiguous = try pipeline.authorize(
        peer: peer("owner", hash: "a"), streamID: "ambiguous", request: request,
        at: decisionDate)
      XCTAssertFalse(ambiguous.shouldStartProducer)
      XCTAssertEqual(try fixture.store.operations.loadAll().count, 1)

      let expiredRepository = ControlRequestRepository(
        store: fixture.store,
        now: { ISO8601DateFormatter().date(from: "2026-08-04T02:31:00Z")! }
      )
      let expiredPipeline = fixture.pipeline(requestRepository: expiredRepository)
      XCTAssertThrowsError(
        try expiredPipeline.authorize(
          peer: peer("owner", hash: "a"), streamID: "expired", request: request,
          at: decisionDate)
      ) { error in
        XCTAssertEqual(error as? ControlStreamAuthorizationError, .idempotencyConflict)
      }
      XCTAssertEqual(try fixture.store.operations.loadAll().count, 1)
    }
  }

  private func withFixture(
    subjects: [String],
    _ body: (Fixture) throws -> Void
  ) throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build", isDirectory: true)
      .appendingPathComponent("hw-p09-stream-auth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity("owner", hash: "a", declaredBy: "owner"))
    try store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: timestamp)
    for (index, subject) in subjects.enumerated() {
      let hash = String(UnicodeScalar(98 + index)!)
      try store.controlIdentities.declare(identity(subject, hash: hash, declaredBy: "owner"))
    }
    let manifest = try ManifestValidator.validated(
      """
      version: 3
      project: probe
      services:
        probe:
          image: ghcr.io/example/probe:latest
          resources:
            requests: {cpus: 1, memory: 512MiB}
            limits: {cpus: 1, memory: 512MiB}
      """
    )
    try store.desiredStates.saveManifestSnapshot(
      projectID: "project-probe",
      manifestPath: root.appendingPathComponent("hostwright.yaml").path,
      manifestHash: String(repeating: "a", count: 64),
      desiredGeneration: 1,
      manifest: manifest,
      timestamp: timestamp,
      mutationProvider: "AppleContainerApplyAdapter",
      projectResourceUUID: projectUUID
    )
    try store.ownership.upsert(ownership(id: "target-a", target: targetA))
    try store.ownership.upsert(ownership(id: "target-b", target: targetB))
    let repositoryNow = decisionDate
    try body(Fixture(
      store: store,
      requests: ControlRequestRepository(store: store, now: { repositoryNow }),
      audit: PipelineAuditRecorder(),
      timestamp: timestamp,
      targetA: targetA,
      targetB: targetB,
      projectUUID: projectUUID
    ))
  }

  private func interactiveRequest(
    target: String,
    requestID: String,
    idempotencyKey: String
  ) -> ControlStreamOpenRequest {
    ControlStreamOpenRequest(
      source: .exec,
      target: target,
      filter: .object([
        "serviceName": .string("probe"),
        "arguments": .array([.string("true")]),
      ]),
      requestID: requestID,
      idempotencyKey: idempotencyKey
    )
  }

  private func ownership(id: String, target: String) -> OwnershipRecord {
    OwnershipRecord(
      id: id,
      resourceIdentifier: "resource-\(id)",
      resourceType: "container",
      projectID: "project-probe",
      serviceName: "probe",
      runtimeAdapter: "AppleContainerApplyAdapter",
      createdAt: timestamp,
      observedAt: timestamp,
      cleanupEligible: true,
      metadataJSONRedacted: "{}",
      resourceUUID: target,
      resourceGeneration: 1,
      projectResourceUUID: projectUUID,
      projectGeneration: 1,
      providerGeneration: 1,
      fencingToken: "33333333-3333-4333-8333-333333333333"
    )
  }

  private func identity(
    _ subject: String,
    hash: String,
    declaredBy: String
  ) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: subject,
      userID: 501,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q",
        signingIdentifier: "hostwright-test-\(subject)",
        codeDirectoryHash: String(repeating: hash, count: 40),
        validationMode: .installedRequirement
      ),
      declaredBySubjectID: declaredBy,
      declaredAt: timestamp,
      updatedAt: timestamp
    )
  }

  private func peer(_ subject: String, hash: String) -> AuthenticatedControlPeer {
    let codeIdentity = CodeIdentity(
      teamIdentifier: "993YC3JY4Q",
      signingIdentifier: "hostwright-test-\(subject)",
      codeDirectoryHash: String(repeating: hash, count: 40),
      validationMode: .installedRequirement
    )
    return AuthenticatedControlPeer(binding: ControlSessionBinding(
      sessionID: "session-\(subject)",
      daemonGeneration: 1,
      serverNonce: "nonce-\(String(repeating: "x", count: 16))",
      socketDevice: 1,
      socketInode: 2,
      peer: UnixPeerIdentity(
        effectiveUID: 501,
        effectiveGID: 20,
        pid: 123,
        pidVersion: 1,
        auditSessionID: 1,
        codeIdentity: codeIdentity
      ),
      subject: LocalSubject(
        identifier: subject,
        userID: 501,
        codeIdentityHash: codeIdentity.codeDirectoryHash
      )
    ))
  }

  private struct Fixture {
    let store: SQLiteStateStore
    let requests: ControlRequestRepository
    let audit: PipelineAuditRecorder
    let timestamp: String
    let targetA: String
    let targetB: String
    let projectUUID: String

    func pipeline(
      requestRepository: ControlRequestRepository? = nil
    ) -> DaemonControlStreamAuthorizationPipeline {
      DaemonControlStreamAuthorizationPipeline(
        store: store,
        rbacAuthorizer: RBACAuthorizationEngine(repository: store.rbac),
        admissionEngine: AdmissionPolicyEngine(repository: store.admission),
        requestRepository: requestRepository ?? requests,
        auditRecorder: audit,
        validateStreamRequest: { request in
          try request.validate()
          if request.source != .exec && request.source != .attach { return }
          guard let target = request.target,
            case .object(let fields)? = request.filter,
            case .string(let serviceName)? = fields["serviceName"],
            serviceName == "probe",
            try store.ownership.loadAll().filter({
              $0.resourceType == "container"
                && $0.resourceUUID == target
                && $0.serviceName == serviceName
            }).count == 1
          else { throw ControlStreamAuthorizationError.invalidRequest }
        }
      )
    }

    func installScopedExecutor(subjectID: String, target: String) throws {
      _ = try store.rbac.createCustomRole(
        RBACRoleRecord(
          roleID: "target-a-executor",
          builtIn: false,
          rules: [RBACRule(
            identifier: "target-a-execute",
            effect: .allow,
            resources: [.runtime],
            verbs: [.execute],
            scope: RBACScope(kind: .resource, identifier: target)
          )],
          createdBySubjectID: "owner",
          createdAt: timestamp,
          updatedAt: timestamp
        ),
        actorSubjectID: "owner",
        timestamp: timestamp
      )
      _ = try store.rbac.createBinding(RBACBindingRecord(
        bindingID: "scoped-executor-binding",
        subjectID: subjectID,
        roleID: "target-a-executor",
        scope: RBACScope(kind: .global),
        createdBySubjectID: "owner",
        createdAt: timestamp,
        updatedAt: timestamp
      ))
    }

    func installTargetMutation(from _: String, to target: String) throws {
      let document: ControlPlaneJSONValue = .object([
        "schemaVersion": .integer(1),
        "operations": .array([.string("stream.exec")]),
        "conditions": .array([]),
        "mutations": .array([.object([
          "fieldPath": .string("/resourceUUID"),
          "value": .string(target),
        ])]),
        "validations": .array([]),
      ])
      _ = try store.admission.createPolicy(AdmissionPolicyRecord(
        policyID: "mutate-exec-target",
        version: 1,
        sourceKind: .builtIn,
        stage: .builtInMutation,
        failurePolicy: .deny,
        advisory: false,
        mutating: true,
        document: document,
        documentSHA256: AdmissionPolicyRecord.digest(document),
        createdBySubjectID: "owner",
        createdAt: timestamp,
        updatedAt: timestamp
      ))
    }
  }
}

private final class PipelineAuditRecorder: ControlSecurityAuditRecording, @unchecked Sendable {
  private let lock = NSLock()
  private var captured: [ControlSecurityAuditEvent] = []
  var failAll = false

  @discardableResult
  func record(_ event: ControlSecurityAuditEvent) throws -> AuditRecord {
    try event.validate()
    lock.lock()
    defer { lock.unlock() }
    if failAll { throw NSError(domain: "PipelineAuditRecorder", code: 1) }
    captured.append(event)
    return AuditRecord(
      identifier: "pipeline-audit-\(captured.count)",
      segmentID: "pipeline-test-segment",
      sequence: UInt64(captured.count),
      timestamp: Date(timeIntervalSince1970: 1_754_000_000),
      previousDigest: captured.count == 1 ? nil : "sha256:" + String(repeating: "b", count: 64),
      subjectID: event.subjectID,
      requestID: event.requestID,
      target: event.target,
      action: event.action,
      outcome: event.outcome,
      reasonCode: event.reasonCode,
      policyRef: event.policyRef,
      planRef: event.planRef,
      approvalRef: event.approvalRef,
      operationRef: event.operationRef,
      payloadDigest: event.payloadDigest,
      recordDigest: "sha256:" + String(repeating: "a", count: 64),
      signingKeyID: "pipeline-test-key"
    )
  }

  var events: [ControlSecurityAuditEvent] {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }
}
