import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightState
import XCTest

@testable import HostwrightControlTransport

private struct TestPersistedMutationBinding: Codable {
  let originalRequest: ControlRequestEnvelope
  let effectiveRequest: ControlRequestEnvelope
  let admissionEvaluationDigestSHA256: String
  let admissionPlanHash: String
  let exceptionIDs: [String]
}

final class PersistentControlAuditIntegrationTests: XCTestCase {
  func testDeniedMutationIsAuditedBeforeDurabilityAndNeverInvokesHandler() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let repository = ControlRequestRepository(store: store, now: fixedNow)
    let recorder = RecordingAuditRecorder()
    let invocations = InvocationCounter()
    let server = try makeServer(
      store: store, repository: repository, recorder: recorder,
      mutatingOperations: ["service.start"],
      authorizer: { _, _, _ in
        RBACDecision(
          effect: .deny, ruleIdentifiers: ["deny.service.start"],
          reasonCode: "authorization.explicit-deny")
      },
      handler: { _, request, _ in
        invocations.increment()
        return ControlResponseEnvelope(
          requestID: request.requestID, status: .completed, reasonCode: .completed)
      })
    let session = try start(server: server)
    defer { session.closeClientAndWait() }

    try completeAuthentication(descriptor: session.client)
    let request = ControlRequestEnvelope(
      requestID: "authorization-denied-one", operation: "service.start",
      timeoutMilliseconds: 1_000, idempotencyKey: "authorization-denied-key")
    try write(request, descriptor: session.client)
    let response = try readResponse(descriptor: session.client)

    XCTAssertEqual(response.status, .rejected)
    XCTAssertEqual(response.reasonCode, .unauthorized)
    XCTAssertEqual(response.error?.code, "authorizationDenied")
    XCTAssertEqual(invocations.value, 0)
    XCTAssertNil(try repository.load(request.requestID))
    XCTAssertEqual(recorder.events.count, 1)
    XCTAssertEqual(recorder.events[0].action, .authorization)
    XCTAssertEqual(recorder.events[0].outcome, "deny")
    XCTAssertEqual(recorder.events[0].reasonCode, "authorization.explicit-deny")
  }

  func testMutationPersistsAcceptedAuditBeforeHandlerAndTerminalAuditBeforeResponse() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let repository = ControlRequestRepository(store: store, now: fixedNow)
    let recorder = RecordingAuditRecorder()
    let invocation = InvocationCounter()
    let request = ControlRequestEnvelope(
      requestID: "audit-terminal-one",
      operation: "service.start",
      timeoutMilliseconds: 1_000,
      idempotencyKey: "audit-terminal-idempotency"
    )
    let expectedAcceptedPayload = sha256(
      try ControlPlaneCanonicalJSON.encode(
        TestPersistedMutationBinding(
          originalRequest: request, effectiveRequest: request,
          admissionEvaluationDigestSHA256: String(repeating: "b", count: 64),
          admissionPlanHash: String(repeating: "a", count: 64), exceptionIDs: [])))
    let authorizationKey = try authorizationDeduplicationKey(
      requestID: request.requestID,
      decision: RBACDecision(
        effect: .allow, ruleIdentifiers: ["test.allow"],
        reasonCode: "authorization.allowed"))
    let server = try makeServer(
      store: store,
      repository: repository,
      recorder: recorder,
      mutatingOperations: ["service.start"],
      handler: { _, received, _ in
        invocation.increment()
        XCTAssertEqual(try repository.load(received.requestID)?.status, .accepted)
        XCTAssertEqual(recorder.events.map(\.deduplicationKey), [
          authorizationKey,
          "control:audit-terminal-one:admission-" + String(repeating: "b", count: 64),
          "control:audit-terminal-one:effective-authorization-"
            + authorizationKey.split(separator: "-").last!,
          "control:audit-terminal-one:accepted",
        ])
        return ControlResponseEnvelope(
          requestID: request.requestID,
          status: .completed,
          reasonCode: .completed
        )
      }
    )
    let session = try start(server: server)
    defer { session.closeClientAndWait() }

    try completeAuthentication(descriptor: session.client)
    try write(request, descriptor: session.client)
    let response = try readResponse(descriptor: session.client)

    XCTAssertEqual(response.status, .completed)
    XCTAssertEqual(response.reasonCode, .completed)
    XCTAssertTrue(response.operationRef?.hasPrefix("unary:") == true)
    let expectedTerminalPayload = sha256(try ControlPlaneCanonicalJSON.encode(response))
    XCTAssertEqual(invocation.value, 1)
    XCTAssertEqual(try repository.load(request.requestID)?.status, .completed)
    let events = recorder.events
    XCTAssertEqual(events.count, 5)
    XCTAssertEqual(events[0].deduplicationKey, authorizationKey)
    XCTAssertEqual(events[0].action, .authorization)
    XCTAssertEqual(events[0].outcome, "allow")
    XCTAssertEqual(events[0].reasonCode, "authorization.allowed")
    XCTAssertEqual(events[1].action, .admission)
    XCTAssertEqual(events[1].outcome, "allowed")
    XCTAssertEqual(events[1].planRef, "sha256:" + String(repeating: "a", count: 64))
    XCTAssertEqual(events[2].action, .authorization)
    XCTAssertEqual(events[2].outcome, "allow")
    XCTAssertEqual(events[3].deduplicationKey, "control:audit-terminal-one:accepted")
    XCTAssertEqual(events[3].action, .request)
    XCTAssertEqual(events[3].outcome, "accepted")
    XCTAssertEqual(events[3].reasonCode, "accepted")
    XCTAssertEqual(events[3].payloadDigest, expectedAcceptedPayload)
    XCTAssertEqual(events[4].deduplicationKey, "control:audit-terminal-one:terminal")
    XCTAssertEqual(events[4].action, .operation)
    XCTAssertEqual(events[4].outcome, "completed")
    XCTAssertEqual(events[4].reasonCode, "completed")
    XCTAssertEqual(events[4].payloadDigest, expectedTerminalPayload)
  }

  func testAuditFailureFailsClosedForMutationWhileReadOnlyOperationRemainsCallable() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let repository = ControlRequestRepository(store: store, now: fixedNow)
    let recorder = RecordingAuditRecorder(failAllRecords: true)
    let readInvocations = InvocationCounter()
    let mutationInvocations = InvocationCounter()
    let server = try makeServer(
      store: store,
      repository: repository,
      recorder: recorder,
      mutatingOperations: ["service.start"],
      handler: { _, request, _ in
        if request.operation == "state.get" {
          readInvocations.increment()
          return ControlResponseEnvelope(
            requestID: request.requestID, status: .completed, reasonCode: .completed)
        }
        mutationInvocations.increment()
        return ControlResponseEnvelope(
          requestID: request.requestID, status: .completed, reasonCode: .completed)
      }
    )
    let session = try start(server: server)
    defer { session.closeClientAndWait() }

    try completeAuthentication(descriptor: session.client)
    let read = ControlRequestEnvelope(
      requestID: "audit-read-one", operation: "state.get", timeoutMilliseconds: 1_000)
    try write(read, descriptor: session.client)
    XCTAssertEqual(try readResponse(descriptor: session.client).status, .completed)
    XCTAssertEqual(readInvocations.value, 1)

    let mutation = ControlRequestEnvelope(
      requestID: "audit-failure-one", operation: "service.start", timeoutMilliseconds: 1_000,
      idempotencyKey: "audit-failure-idempotency"
    )
    try write(mutation, descriptor: session.client)
    XCTAssertThrowsError(try readResponse(descriptor: session.client)) { error in
      XCTAssertEqual(error as? ControlTransportError, .peerClosed)
    }
    session.waitForServer()

    XCTAssertNil(session.result.error)
    XCTAssertEqual(mutationInvocations.value, 0)
    XCTAssertNil(try repository.load(mutation.requestID))
    XCTAssertTrue(recorder.events.isEmpty)
  }

  func testAcceptedReplayUsesAuditDeduplicationAndNeverReinvokesHandler() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let repository = ControlRequestRepository(store: store, now: fixedNow)
    let recorder = RecordingAuditRecorder()
    let invocations = InvocationCounter()
    let request = ControlRequestEnvelope(
      requestID: "audit-replay-one",
      operation: "service.start",
      timeoutMilliseconds: 1_000,
      idempotencyKey: "audit-replay-idempotency"
    )
    let server = try makeServer(
      store: store,
      repository: repository,
      recorder: recorder,
      mutatingOperations: ["service.start"],
      handler: { _, received, _ in
        invocations.increment()
        return ControlResponseEnvelope(
          requestID: received.requestID,
          status: .accepted,
          reasonCode: .accepted
        )
      }
    )
    let session = try start(server: server)
    defer { session.closeClientAndWait() }

    try completeAuthentication(descriptor: session.client)
    try write(request, descriptor: session.client)
    let first = try readResponse(descriptor: session.client)
    XCTAssertEqual(first.status, .accepted)
    XCTAssertTrue(first.operationRef?.hasPrefix("unary:") == true)
    try write(request, descriptor: session.client)
    let replay = try readResponse(descriptor: session.client)
    XCTAssertEqual(replay, first)

    XCTAssertEqual(invocations.value, 1)
    XCTAssertEqual(try repository.load(request.requestID)?.status, .accepted)
    XCTAssertEqual(
      try repository.load(request.requestID)?.operationReference,
      first.operationRef
    )
    let authorizationKey = try authorizationDeduplicationKey(
      requestID: request.requestID,
      decision: RBACDecision(
        effect: .allow, ruleIdentifiers: ["test.allow"],
        reasonCode: "authorization.allowed"))
    XCTAssertEqual(recorder.events.map(\.deduplicationKey), [
      authorizationKey,
      "control:audit-replay-one:admission-" + String(repeating: "b", count: 64),
      "control:audit-replay-one:effective-authorization-"
        + authorizationKey.split(separator: "-").last!,
      "control:audit-replay-one:accepted",
      "control:audit-replay-one:operation-accepted",
    ])
    XCTAssertEqual(recorder.recordAttemptCount, 10)
  }

  func testChangedAuthorizationDecisionUsesDistinctAuditIdentityAndDeniesReplay() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let repository = ControlRequestRepository(store: store, now: fixedNow)
    let recorder = RecordingAuditRecorder()
    let invocations = InvocationCounter()
    let authorization = MutableAuthorizationDecision()
    let server = try makeServer(
      store: store, repository: repository, recorder: recorder,
      mutatingOperations: ["service.start"],
      authorizer: { _, _, _ in authorization.decision },
      handler: { _, request, _ in
        invocations.increment()
        return ControlResponseEnvelope(
          requestID: request.requestID, status: .completed, reasonCode: .completed)
      })
    let session = try start(server: server)
    defer { session.closeClientAndWait() }

    try completeAuthentication(descriptor: session.client)
    let request = ControlRequestEnvelope(
      requestID: "authorization-change-one", operation: "service.start",
      timeoutMilliseconds: 1_000, idempotencyKey: "authorization-change-key")
    try write(request, descriptor: session.client)
    XCTAssertEqual(try readResponse(descriptor: session.client).status, .completed)
    authorization.deny()
    try write(request, descriptor: session.client)
    let denied = try readResponse(descriptor: session.client)

    XCTAssertEqual(denied.status, .rejected)
    XCTAssertEqual(denied.reasonCode, .unauthorized)
    XCTAssertEqual(invocations.value, 1)
    let authorizationEvents = recorder.events.filter { $0.action == .authorization }
    XCTAssertEqual(authorizationEvents.count, 3)
    XCTAssertEqual(Set(authorizationEvents.map(\.deduplicationKey)).count, 3)
    XCTAssertEqual(authorizationEvents.map(\.outcome), ["allow", "allow", "deny"])
  }

  private func makeServer(
    store: SQLiteStateStore,
    repository: ControlRequestRepository,
    recorder: any ControlSecurityAuditRecording,
    mutatingOperations: Set<String>,
    authorizer: @escaping PersistentControlConnectionServer.Authorizer =
      allowingTestControlRequestAuthorizer,
    handler: @escaping PersistentControlConnectionServer.Handler
  ) throws -> PersistentControlConnectionServer {
    let identity = fixtureIdentity()
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "control-audit-subject",
        userID: UInt32(geteuid()),
        codeIdentity: identity,
        declaredBySubjectID: "control-audit-subject",
        declaredAt: "2026-08-02T20:00:00Z",
        updatedAt: "2026-08-02T20:00:00Z"
      )
    )
    let adapter = try SQLiteControlIdentitySecurityAdapter(
      store: store, sessionLifetime: 600, now: fixedNow)
    let credentials = RawControlPeerCredentials(
      peerUID: UInt32(geteuid()), peerGID: UInt32(getegid()), peerPID: getpid(),
      auditEffectiveUID: UInt32(geteuid()), auditEffectiveGID: UInt32(getegid()),
      auditPID: getpid(), auditPIDVersion: 1, auditSessionID: 1,
      auditTokenData: Data(repeating: 9, count: MemoryLayout<audit_token_t>.size)
    )
    let authenticator = ControlPeerAuthenticator(
      policy: try ControlPeerTrustPolicy(
        expectedUserID: UInt32(geteuid()),
        pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
      ),
      credentialReader: FixedCredentialReader(credentials: credentials),
      codeValidator: FixedCodeValidator(identity: identity),
      subjectResolver: adapter,
      sessionStore: adapter
    )
    return try PersistentControlConnectionServer(
      authenticator: authenticator,
      requestRepository: repository,
      daemonGeneration: 1,
      socketIdentity: ControlSocketIdentity(device: 41, inode: 43),
      mutatingOperations: mutatingOperations,
      auditRecorder: recorder,
      authorizer: authorizer,
      admissionEvaluator: allowingTestControlAdmissionEvaluator,
      now: fixedNow,
      handler: handler
    )
  }

  private func start(server: PersistentControlConnectionServer) throws -> ServerSession {
    let pair = try socketPair()
    try ControlFrameCodec.configureNoSigPipe(descriptor: pair.client)
    let result = ServerResult()
    let finished = expectation(description: "server exits")
    DispatchQueue.global().async {
      defer {
        _ = Darwin.close(pair.server)
        finished.fulfill()
      }
      do {
        try server.serve(descriptor: pair.server)
      } catch {
        result.error = error
      }
    }
    return ServerSession(client: pair.client, result: result, finished: finished, testCase: self)
  }

  private func completeAuthentication(descriptor: Int32) throws {
    let challenge = try ControlAuthenticationWireContract.decodeChallenge(
      ControlFrameCodec.read(kind: .frame, descriptor: descriptor, deadline: try deadline())
    )
    XCTAssertFalse(challenge.credentialProofRequired)
    try ControlFrameCodec.write(
      try ControlPlaneCanonicalJSON.encode(ControlAuthenticationResponse()),
      kind: .request,
      descriptor: descriptor,
      deadline: try deadline()
    )
  }

  private func write(_ request: ControlRequestEnvelope, descriptor: Int32) throws {
    try ControlFrameCodec.write(
      try ControlPlaneCanonicalJSON.encode(request), kind: .request,
      descriptor: descriptor, deadline: try deadline())
  }

  private func readResponse(descriptor: Int32) throws -> ControlResponseEnvelope {
    let data = try ControlFrameCodec.read(
      kind: .response, descriptor: descriptor, deadline: try deadline())
    return try Phase09StrictDecoder.decode(
      ControlResponseEnvelope.self,
      from: data,
      allowedKeys: [
        "apiVersion", "protocolRevision", "requestID", "status", "reasonCode", "operationRef",
        "result", "error",
      ],
      requiredKeys: ["apiVersion", "protocolRevision", "requestID", "status", "reasonCode"]
    )
  }

  private func deadline() throws -> ControlTransportDeadline {
    try ControlTransportDeadline(timeoutMilliseconds: 1_000)
  }

  private func socketPair() throws -> (client: Int32, server: Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw NSError(domain: "PersistentControlAuditIntegrationTests", code: Int(errno))
    }
    return (descriptors[0], descriptors[1])
  }

  private func fixtureIdentity() -> CodeIdentity {
    CodeIdentity(
      signingIdentifier: "hostwright-control-audit",
      codeDirectoryHash: String(repeating: "b", count: 40), validationMode: .pinnedAdHoc)
  }

  private func temporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent(".build", isDirectory: true)
      .appendingPathComponent("hw-p09-audit-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }
}

private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_785_715_200) }

private func sha256(_ data: Data) -> String {
  "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func authorizationDeduplicationKey(
  requestID: String,
  decision: RBACDecision
) throws -> String {
  let digest = SHA256.hash(data: try ControlPlaneCanonicalJSON.encode(decision))
    .map { String(format: "%02x", $0) }.joined()
  return "control:\(requestID):authorization-\(digest)"
}

private final class MutableAuthorizationDecision: @unchecked Sendable {
  private let lock = NSLock()
  private var current = RBACDecision(
    effect: .allow, ruleIdentifiers: ["mutable.allow"],
    reasonCode: "authorization.allowed")

  var decision: RBACDecision {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func deny() {
    lock.lock()
    current = RBACDecision(
      effect: .deny, ruleIdentifiers: ["mutable.deny"],
      reasonCode: "authorization.explicit-deny")
    lock.unlock()
  }
}

private final class RecordingAuditRecorder: ControlSecurityAuditRecording, @unchecked Sendable {
  private let lock = NSLock()
  private let failAllRecords: Bool
  private var recordsByDeduplicationKey: [String: AuditRecord] = [:]
  private var capturedEvents: [ControlSecurityAuditEvent] = []
  private var attempts = 0

  init(failAllRecords: Bool = false) {
    self.failAllRecords = failAllRecords
  }

  func record(_ event: ControlSecurityAuditEvent) throws -> AuditRecord {
    try event.validate()
    lock.lock()
    defer { lock.unlock() }
    attempts += 1
    if failAllRecords {
      throw PersistentControlServerError.persistenceFailed
    }
    if let prior = recordsByDeduplicationKey[event.deduplicationKey] {
      return prior
    }
    let ordinal = UInt64(capturedEvents.count + 1)
    let record = AuditRecord(
      identifier: "audit-integration-\(ordinal)", segmentID: "segment-\(ordinal)", sequence: ordinal,
      timestamp: Date(timeIntervalSince1970: 1_785_715_200),
      previousDigest: ordinal == 1 ? nil : "sha256:" + String(repeating: "1", count: 64),
      subjectID: event.subjectID, requestID: event.requestID, target: event.target, action: event.action,
      outcome: event.outcome, reasonCode: event.reasonCode, operationRef: event.operationRef,
      payloadDigest: event.payloadDigest,
      recordDigest: "sha256:" + String(repeating: "2", count: 64), signingKeyID: "integration-key"
    )
    recordsByDeduplicationKey[event.deduplicationKey] = record
    capturedEvents.append(event)
    return record
  }

  var events: [ControlSecurityAuditEvent] {
    lock.lock()
    defer { lock.unlock() }
    return capturedEvents
  }

  var recordAttemptCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return attempts
  }
}

private final class InvocationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

private struct FixedCredentialReader: ControlPeerCredentialReading {
  let credentials: RawControlPeerCredentials
  func read(descriptor _: Int32) throws -> RawControlPeerCredentials { credentials }
}

private struct FixedCodeValidator: ControlPeerCodeValidating {
  let identity: CodeIdentity
  func identity(for _: Data, peerPID _: pid_t) throws -> CodeIdentity { identity }
}

private final class ServerResult: @unchecked Sendable {
  private let lock = NSLock()
  private var capturedError: Error?

  var error: Error? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return capturedError
    }
    set {
      lock.lock()
      capturedError = newValue
      lock.unlock()
    }
  }
}

private final class ServerSession {
  let client: Int32
  let result: ServerResult
  private let finished: XCTestExpectation
  private unowned let testCase: XCTestCase
  private var clientClosed = false
  private var finishedWaited = false

  init(client: Int32, result: ServerResult, finished: XCTestExpectation, testCase: XCTestCase) {
    self.client = client
    self.result = result
    self.finished = finished
    self.testCase = testCase
  }

  func closeClientAndWait() {
    if !clientClosed {
      _ = Darwin.close(client)
      clientClosed = true
    }
    if !finishedWaited {
      testCase.wait(for: [finished], timeout: 2)
      finishedWaited = true
    }
  }

  func waitForServer() {
    closeClientAndWait()
  }
}
