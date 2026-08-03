import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightState
import XCTest

@testable import HostwrightControlTransport

final class PersistentControlAdmissionIntegrationTests: XCTestCase {
  private let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_785_715_200) }

  func testAdmissionDenyPreventsHandlerAndDurabilityAndRecordsBoundAuditReferences() throws {
    try withServer(
      evaluator: { _, request, _ in
        try admissionEvaluation(
          request: request, allowed: false, reason: "admission.host-access-forbidden",
          policy: "policy-ref", plan: "a", approval: "approved-by-security", digest: "b")
      }
    ) { fixture, session in
      let request = mutationRequest("admission-denied")
      try session.write(request)
      let response = try session.read()

      XCTAssertEqual(response.status, .rejected)
      XCTAssertEqual(response.reasonCode, .admissionDenied)
      XCTAssertEqual(response.error?.code, "admissionDenied")
      XCTAssertEqual(fixture.invocations.value, 0)
      XCTAssertNil(try fixture.repository.load(request.requestID))
      let admission = try XCTUnwrap(fixture.recorder.events.last)
      XCTAssertEqual(admission.action, .admission)
      XCTAssertEqual(admission.outcome, "denied")
      XCTAssertEqual(
        admission.policyRef,
        "sha256:" + (try admissionDigest([AdmissionDecision(
          policyIdentifier: "policy-ref", stage: .extensionValidation, allowed: false,
          failurePolicy: .deny, reasonCode: "admission.host-access-forbidden")])))
      XCTAssertEqual(admission.planRef, "sha256:" + String(repeating: "a", count: 64))
      XCTAssertEqual(admission.approvalRef, "approved-by-security")
    }
  }

  func testAdmissionEvaluatorErrorFailsClosedBeforeHandlerAndDurability() throws {
    try withServer(evaluator: { _, _, _ in throw EvaluatorFailure.failed }) { fixture, session in
      let request = mutationRequest("admission-evaluator-error")
      try session.write(request)
      let response = try session.read()

      XCTAssertEqual(response.status, .rejected)
      XCTAssertEqual(response.reasonCode, .admissionDenied)
      XCTAssertEqual(response.error?.code, "admissionFailedClosed")
      XCTAssertEqual(fixture.invocations.value, 0)
      XCTAssertNil(try fixture.repository.load(request.requestID))
      XCTAssertEqual(fixture.recorder.events.map(\.action), [.authorization, .admission])
      XCTAssertEqual(fixture.recorder.events.last?.outcome, "error")
    }
  }

  func testAdmissionDryRunReturnsEffectiveIntentWithoutHandlerOrDurability() throws {
    try withServer(
      evaluator: { _, request, _ in
        var effective = request
        effective = ControlRequestEnvelope(
          requestID: request.requestID, operation: request.operation,
          timeoutMilliseconds: request.timeoutMilliseconds,
          idempotencyKey: request.idempotencyKey,
          body: .object(["network": .string("isolated")]))
        return try admissionEvaluation(
          request: effective, allowed: true, reason: "admission.allowed", policy: "policy-ref",
          plan: "a", approval: nil, digest: "b", dryRun: true)
      }
    ) { fixture, session in
      let request = mutationRequest("admission-dry-run")
      try session.write(request)
      let response = try session.read()

      XCTAssertEqual(response.status, .completed)
      XCTAssertEqual(response.reasonCode, .completed)
      XCTAssertNotNil(response.result)
      XCTAssertEqual(fixture.invocations.value, 0)
      XCTAssertNil(try fixture.repository.load(request.requestID))
      XCTAssertEqual(fixture.recorder.events.map(\.action), [
        .authorization, .admission, .authorization,
      ])
    }
  }

  func testEffectiveIntentRequiresSecondAuthorizationBeforeHandlerAndDurability() throws {
    let authorizer: PersistentControlConnectionServer.Authorizer = { _, request, _ in
      if case .object(let fields)? = request.body, fields["hostAccess"] == .bool(true) {
        return RBACDecision(
          effect: .deny, ruleIdentifiers: ["deny.effective.host-access"],
          reasonCode: "authorization.host-access-denied")
      }
      return RBACDecision(
        effect: .allow, ruleIdentifiers: ["allow.requested"],
        reasonCode: "authorization.allowed")
    }
    try withServer(
      authorizer: authorizer,
      evaluator: { _, request, _ in
        let effective = ControlRequestEnvelope(
          requestID: request.requestID, operation: request.operation,
          timeoutMilliseconds: request.timeoutMilliseconds,
          idempotencyKey: request.idempotencyKey,
          body: .object(["hostAccess": .bool(true)]))
        return try admissionEvaluation(
          request: effective, allowed: true, reason: "admission.allowed", policy: "policy-ref",
          plan: "a", approval: nil, digest: "b")
      }
    ) { fixture, session in
      let request = mutationRequest("effective-reauthorization")
      try session.write(request)
      let response = try session.read()

      XCTAssertEqual(response.status, .rejected)
      XCTAssertEqual(response.reasonCode, .unauthorized)
      XCTAssertEqual(response.error?.code, "effectiveAuthorizationDenied")
      XCTAssertEqual(fixture.invocations.value, 0)
      XCTAssertNil(try fixture.repository.load(request.requestID))
      XCTAssertEqual(fixture.recorder.events.map(\.outcome), ["allow", "allowed", "deny"])
      XCTAssertEqual(fixture.recorder.events.last?.reasonCode, "authorization.host-access-denied")
    }
  }

  func testAdmissionMutatedPreparedRequestIsRepreparedBeforeAuthorizationAndExecution() throws {
    let preparations = Counter()
    let expectedBody = ControlPlaneJSONValue.object(["network": .string("isolated")])
    try withServer(
      requestPreparer: { _, request in
        preparations.increment()
        return try PersistentControlPreparedRequest(
          request: request,
          execution: { _, _ in
            ControlResponseEnvelope(
              requestID: request.requestID,
              status: .completed,
              reasonCode: .completed,
              result: request.body
            )
          }
        )
      },
      evaluator: { _, request, _ in
        let effective = ControlRequestEnvelope(
          requestID: request.requestID,
          operation: request.operation,
          timeoutMilliseconds: request.timeoutMilliseconds,
          idempotencyKey: request.idempotencyKey,
          body: expectedBody
        )
        return try admissionEvaluation(
          request: effective,
          allowed: true,
          reason: "admission.allowed",
          policy: "policy-ref",
          plan: "a",
          approval: nil,
          digest: "b"
        )
      }
    ) { fixture, session in
      let request = mutationRequest("prepared-effective-request")
      try session.write(request)
      let response = try session.read()

      XCTAssertEqual(response.status, .completed)
      XCTAssertEqual(response.result, expectedBody)
      XCTAssertEqual(preparations.value, 2)
      XCTAssertEqual(fixture.invocations.value, 0)
      XCTAssertEqual(try fixture.repository.load(request.requestID)?.status, .completed)
    }
  }

  func testIdempotencyBindsOriginalRequestAndAdmissionEffectiveIntent() throws {
    let phase = MutablePhase()
    try withServer(
      evaluator: { _, request, _ in
        let current = phase.next()
        let effective = ControlRequestEnvelope(
          requestID: request.requestID, operation: request.operation,
          timeoutMilliseconds: request.timeoutMilliseconds,
          idempotencyKey: request.idempotencyKey,
          body: .object(["network": .string(current == 1 ? "isolated" : "host")]))
        return try admissionEvaluation(
          request: effective, allowed: true, reason: "admission.allowed", policy: "policy-ref",
          plan: current == 1 ? "a" : "c", approval: nil, digest: current == 1 ? "b" : "d")
      }
    ) { fixture, session in
      let request = mutationRequest("idempotency-effective-binding", idempotencyKey: "shared-key")
      try session.write(request)
      XCTAssertEqual(try session.read().status, .completed)
      try session.write(request)
      let conflict = try session.read()

      XCTAssertEqual(conflict.status, .rejected)
      XCTAssertEqual(conflict.reasonCode, .idempotencyConflict)
      XCTAssertEqual(conflict.error?.code, "idempotencyConflict")
      XCTAssertEqual(fixture.invocations.value, 1)
      XCTAssertEqual(try fixture.repository.load(request.requestID)?.status, .completed)
    }
  }

  private func withServer(
    authorizer: @escaping PersistentControlConnectionServer.Authorizer = { _, _, _ in
      RBACDecision(effect: .allow, ruleIdentifiers: ["allow"], reasonCode: "authorization.allowed")
    },
    requestPreparer: @escaping PersistentControlConnectionServer.RequestPreparer = {
      _, request in try PersistentControlPreparedRequest(request: request)
    },
    evaluator: @escaping PersistentControlConnectionServer.AdmissionEvaluator,
    _ body: (Fixture, Session) throws -> Void
  ) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let identity = CodeIdentity(
      signingIdentifier: "hostwright-admission-integration",
      codeDirectoryHash: String(repeating: "a", count: 40), validationMode: .pinnedAdHoc)
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "admission-subject", userID: UInt32(geteuid()), codeIdentity: identity,
        declaredBySubjectID: "admission-subject", declaredAt: "2026-08-02T20:00:00Z",
        updatedAt: "2026-08-02T20:00:00Z"))
    let adapter = try SQLiteControlIdentitySecurityAdapter(
      store: store, sessionLifetime: 600, now: now)
    let credentials = RawControlPeerCredentials(
      peerUID: UInt32(geteuid()), peerGID: UInt32(getegid()), peerPID: getpid(),
      auditEffectiveUID: UInt32(geteuid()), auditEffectiveGID: UInt32(getegid()),
      auditPID: getpid(), auditPIDVersion: 1, auditSessionID: 1,
      auditTokenData: Data(repeating: 8, count: MemoryLayout<audit_token_t>.size))
    let authenticator = ControlPeerAuthenticator(
      policy: try ControlPeerTrustPolicy(
        expectedUserID: UInt32(geteuid()), pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]),
      credentialReader: CredentialReader(credentials: credentials),
      codeValidator: CodeValidator(identity: identity),
      subjectResolver: adapter, sessionStore: adapter)
    let repository = ControlRequestRepository(store: store, now: now)
    let recorder = Recorder()
    let invocations = Counter()
    let server = try PersistentControlConnectionServer(
      authenticator: authenticator, requestRepository: repository, daemonGeneration: 1,
      socketIdentity: ControlSocketIdentity(device: 19, inode: 23),
      mutatingOperations: ["service.update"], requestPreparer: requestPreparer,
      auditRecorder: recorder, authorizer: authorizer,
      admissionEvaluator: evaluator, now: now,
      handler: { _, request, _ in
        invocations.increment()
        return ControlResponseEnvelope(
          requestID: request.requestID, status: .completed, reasonCode: .completed)
      })
    let session = try Session(testCase: self, server: server)
    defer { session.close() }
    try session.authenticate()
    try body(Fixture(repository: repository, recorder: recorder, invocations: invocations), session)
  }

  private func mutationRequest(
    _ identifier: String, idempotencyKey: String? = "key"
  ) -> ControlRequestEnvelope {
    ControlRequestEnvelope(
      requestID: identifier, operation: "service.update", timeoutMilliseconds: 1_000,
      idempotencyKey: idempotencyKey, body: .object([:]))
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build", isDirectory: true)
      .appendingPathComponent("hw-p09-admission-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }

  private struct Fixture {
    let repository: ControlRequestRepository
    let recorder: Recorder
    let invocations: Counter
  }

  private enum EvaluatorFailure: Error { case failed }
}

private struct CredentialReader: ControlPeerCredentialReading {
  let credentials: RawControlPeerCredentials
  func read(descriptor _: Int32) throws -> RawControlPeerCredentials { credentials }
}

private func admissionEvaluation(
  request: ControlRequestEnvelope, allowed: Bool, reason: String, policy: String,
  plan: Character, approval: String?, digest: Character, dryRun: Bool = false
) throws -> PersistentControlAdmissionEvaluation {
  try PersistentControlAdmissionEvaluation(
    effectiveRequest: request,
    decisions: [AdmissionDecision(
      policyIdentifier: policy, stage: .extensionValidation, allowed: allowed,
      failurePolicy: .deny, reasonCode: reason)],
    target: request.operation, planHash: String(repeating: plan, count: 64),
    approvalIdentity: approval, exceptionIDs: [], allowed: allowed, reasonCode: reason,
    evaluationDigestSHA256: String(repeating: digest, count: 64), dryRun: dryRun)
}

private func admissionDigest<T: Encodable>(_ value: T) throws -> String {
  SHA256.hash(data: try ControlPlaneCanonicalJSON.encode(value))
    .map { String(format: "%02x", $0) }.joined()
}

private struct CodeValidator: ControlPeerCodeValidating {
  let identity: CodeIdentity
  func identity(for _: Data, peerPID _: pid_t) throws -> CodeIdentity { identity }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.lock(); count += 1; lock.unlock() }
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class MutablePhase: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

private final class Recorder: ControlSecurityAuditRecording, @unchecked Sendable {
  private let lock = NSLock()
  private var records: [String: AuditRecord] = [:]
  private var captured: [ControlSecurityAuditEvent] = []

  func record(_ event: ControlSecurityAuditEvent) throws -> AuditRecord {
    try event.validate()
    lock.lock()
    defer { lock.unlock() }
    if let prior = records[event.deduplicationKey] { return prior }
    let ordinal = UInt64(captured.count + 1)
    let record = AuditRecord(
      identifier: "admission-audit-\(ordinal)", segmentID: "segment", sequence: ordinal,
      timestamp: Date(timeIntervalSince1970: 1_785_715_200),
      previousDigest: nil, subjectID: event.subjectID, requestID: event.requestID,
      target: event.target, action: event.action, outcome: event.outcome,
      reasonCode: event.reasonCode, operationRef: event.operationRef,
      payloadDigest: event.payloadDigest,
      recordDigest: "sha256:" + String(repeating: "f", count: 64), signingKeyID: "test-key")
    records[event.deduplicationKey] = record
    captured.append(event)
    return record
  }

  var events: [ControlSecurityAuditEvent] { lock.lock(); defer { lock.unlock() }; return captured }
}

private final class Session {
  let client: Int32
  private let result = ServerResult()
  private let finished: XCTestExpectation
  private unowned let testCase: XCTestCase
  private var closed = false

  init(testCase: XCTestCase, server: PersistentControlConnectionServer) throws {
    self.testCase = testCase
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.ENFILE) }
    client = pair[0]
    try ControlFrameCodec.configureNoSigPipe(descriptor: client)
    finished = testCase.expectation(description: "admission server exits")
    let serverDescriptor = pair[1]
    DispatchQueue.global().async { [result, finished] in
      defer { _ = Darwin.close(serverDescriptor); finished.fulfill() }
      do { try server.serve(descriptor: serverDescriptor) } catch { result.error = error }
    }
  }

  func authenticate() throws {
    let deadline = try ControlTransportDeadline(timeoutMilliseconds: 1_000)
    let data = try ControlFrameCodec.read(kind: .frame, descriptor: client, deadline: deadline)
    _ = try ControlAuthenticationWireContract.decodeChallenge(data)
    try ControlFrameCodec.write(
      try ControlPlaneCanonicalJSON.encode(ControlAuthenticationResponse()), kind: .request,
      descriptor: client, deadline: deadline)
  }

  func write(_ request: ControlRequestEnvelope) throws {
    try ControlFrameCodec.write(
      try ControlPlaneCanonicalJSON.encode(request), kind: .request, descriptor: client,
      deadline: try ControlTransportDeadline(timeoutMilliseconds: 1_000))
  }

  func read() throws -> ControlResponseEnvelope {
    let data = try ControlFrameCodec.read(
      kind: .response, descriptor: client,
      deadline: try ControlTransportDeadline(timeoutMilliseconds: 1_000))
    return try Phase09StrictDecoder.decode(
      ControlResponseEnvelope.self, from: data,
      allowedKeys: [
        "apiVersion", "protocolRevision", "requestID", "status", "reasonCode", "operationRef",
        "result", "error",
      ], requiredKeys: ["apiVersion", "protocolRevision", "requestID", "status", "reasonCode"])
  }

  func close() {
    guard !closed else { return }
    closed = true
    _ = Darwin.close(client)
    testCase.wait(for: [finished], timeout: 2)
    XCTAssertNil(result.error)
  }
}

private final class ServerResult: @unchecked Sendable {
  private let lock = NSLock()
  private var captured: Error?
  var error: Error? {
    get { lock.lock(); defer { lock.unlock() }; return captured }
    set { lock.lock(); captured = newValue; lock.unlock() }
  }
}
