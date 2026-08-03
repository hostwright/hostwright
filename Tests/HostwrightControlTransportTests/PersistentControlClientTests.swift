import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightControlTransport
import HostwrightState
import XCTest

final class PersistentControlClientTests: XCTestCase {
  func testLiveConcurrentClientsAndDurableReplayAcrossListenerRestart() throws {
    let root = try makeOwnedRoot()
    defer { removeOwnedRoot(root) }
    let socketPath = root.appendingPathComponent("control.sock").path
    let identity = try requireCurrentAdHocIdentity()
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let timestamp = ISO8601DateFormatter().string(from: Date())
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "gate3-live-owner",
        userID: UInt32(geteuid()),
        codeIdentity: identity,
        declaredBySubjectID: "gate3-live-owner",
        declaredAt: timestamp,
        updatedAt: timestamp
      )
    )
    let counter = LiveInvocationCounter()
    let serverTrustPolicy = PersistentControlServerTrustPolicy(
      pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
    )
    let initialRequests = (0..<8).map { index in
      ControlRequestEnvelope(
        requestID: "gate3-live-\(index)",
        operation: index == 0 ? "service.start" : "health.get",
        timeoutMilliseconds: 5_000,
        idempotencyKey: index == 0 ? "gate3-live-idempotency" : nil
      )
    }

    let firstListener = try ControlUnixSocketListener(path: socketPath)
    try serve(
      listener: firstListener,
      store: store,
      identity: identity,
      daemonGeneration: 1,
      expectedConnections: initialRequests.count,
      counter: counter
    ) {
      let results = LiveResponseCollector()
      let clients = DispatchGroup()
      for request in initialRequests {
        clients.enter()
        DispatchQueue.global(qos: .userInitiated).async {
          defer { clients.leave() }
          do {
            results.append(
              try PersistentControlClient(
                socketPath: socketPath,
                serverTrustPolicy: serverTrustPolicy
              ).send(request)
            )
          } catch {
            results.record(error)
          }
        }
      }
      XCTAssertEqual(clients.wait(timeout: .now() + 10), .success)
      XCTAssertNil(results.error)
      XCTAssertEqual(results.responses.count, initialRequests.count)
      XCTAssertTrue(results.responses.allSatisfy { $0.status == .completed })
    }
    firstListener.closeAndRemoveOwnedSocket()

    let replay = initialRequests[0]
    let secondListener = try ControlUnixSocketListener(path: socketPath)
    try serve(
      listener: secondListener,
      store: store,
      identity: identity,
      daemonGeneration: 2,
      expectedConnections: 1,
      counter: counter
    ) {
      let response = try PersistentControlClient(
        socketPath: socketPath,
        serverTrustPolicy: serverTrustPolicy
      ).send(replay)
      XCTAssertEqual(response.status, .completed)
      XCTAssertEqual(response.requestID, replay.requestID)
    }
    secondListener.closeAndRemoveOwnedSocket()
    XCTAssertEqual(counter.value, initialRequests.count)
    XCTAssertEqual(try store.controlIdentities.listSessions().count, initialRequests.count + 1)
  }

  func testCurrentCodeAdHocIdentityCompletesRealHandshakeAndUnaryResponse() throws {
    let root = try makeOwnedRoot()
    defer { removeOwnedRoot(root) }
    let socketPath = root.appendingPathComponent("control.sock").path
    let listener = try ControlUnixSocketListener(path: socketPath)
    defer { listener.closeAndRemoveOwnedSocket() }
    try assertPrivateSocket(at: socketPath)

    let identity = try requireCurrentAdHocIdentity()
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let timestamp = ISO8601DateFormatter().string(from: Date())
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "gate3-current-client",
        userID: UInt32(geteuid()),
        codeIdentity: identity,
        declaredBySubjectID: "gate3-current-client",
        declaredAt: timestamp,
        updatedAt: timestamp
      )
    )
    let adapter = try SQLiteControlIdentitySecurityAdapter(
      store: store,
      sessionLifetime: 60
    )
    let policy = try ControlPeerTrustPolicy(
      expectedUserID: UInt32(geteuid()),
      pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
    )
    let authenticator = ControlPeerAuthenticator(
      policy: policy,
      subjectResolver: adapter,
      sessionStore: adapter
    )
    let server = try PersistentControlConnectionServer(
      authenticator: authenticator,
      requestRepository: ControlRequestRepository(store: store),
      daemonGeneration: 1,
      socketIdentity: listener.identity,
      mutatingOperations: [],
      auditRecorder: ClientTestControlAuditRecorder(),
      authorizer: allowingTestControlRequestAuthorizer,
      admissionEvaluator: allowingTestControlAdmissionEvaluator
    ) { _, request, _ in
      ControlResponseEnvelope(
        requestID: request.requestID,
        status: .completed,
        reasonCode: .completed
      )
    }
    let serverResult = ServerResult()
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      defer { completed.signal() }
      do {
        let descriptor = try listener.accept(timeoutMilliseconds: 5_000)
        defer { _ = Darwin.close(descriptor) }
        try server.serve(descriptor: descriptor)
      } catch {
        serverResult.error = error
      }
    }

    let request = ControlRequestEnvelope(
      requestID: "gate3-unary-current-code",
      operation: "health.get",
      timeoutMilliseconds: 5_000
    )
    let response = try client(socketPath: socketPath).send(request)
    XCTAssertEqual(response.requestID, request.requestID)
    XCTAssertEqual(response.status, .completed)
    XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
    XCTAssertNil(serverResult.error)
  }

  func testChallengeSocketBindingMismatchIsRejected() throws {
    let root = try makeOwnedRoot()
    defer { removeOwnedRoot(root) }
    let listener = try ControlUnixSocketListener(
      path: root.appendingPathComponent("control.sock").path)
    defer { listener.closeAndRemoveOwnedSocket() }
    let currentIdentity = try requireCurrentAdHocIdentity()
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      defer { completed.signal() }
      do {
        let descriptor = try listener.accept(timeoutMilliseconds: 5_000)
        defer { _ = Darwin.close(descriptor) }
        let challenge = try Self.challenge(
          descriptor: descriptor,
          identity: currentIdentity,
          socketIdentity: ControlSocketIdentity(
            device: listener.identity.device + 1,
            inode: listener.identity.inode
          )
        )
        try ControlFrameCodec.write(
          try ControlPlaneCanonicalJSON.encode(challenge),
          kind: .frame,
          descriptor: descriptor,
          deadline: try ControlTransportDeadline(timeoutMilliseconds: 5_000)
        )
      } catch {
        XCTFail("minimal mismatch server failed: \(error)")
      }
    }

    XCTAssertThrowsError(
      try client(socketPath: listener.path).send(request())
    ) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .serverBindingMismatch)
    }
    XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
  }

  func testUnpinnedAdHocServerIsRejectedBeforeChallenge() throws {
    let root = try makeOwnedRoot()
    defer { removeOwnedRoot(root) }
    let listener = try ControlUnixSocketListener(
      path: root.appendingPathComponent("control.sock").path)
    defer { listener.closeAndRemoveOwnedSocket() }
    let completed = DispatchSemaphore(value: 0)
    let clientFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      defer { completed.signal() }
      if let descriptor = try? listener.accept(timeoutMilliseconds: 5_000) {
        _ = clientFinished.wait(timeout: .now() + 5)
        _ = Darwin.close(descriptor)
      }
    }

    XCTAssertThrowsError(
      try PersistentControlClient(socketPath: listener.path).send(request())
    ) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .serverBindingMismatch)
    }
    clientFinished.signal()
    XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
  }

  func testResponseRequestIDMismatchIsRejected() throws {
    let root = try makeOwnedRoot()
    defer { removeOwnedRoot(root) }
    let listener = try ControlUnixSocketListener(
      path: root.appendingPathComponent("control.sock").path)
    defer { listener.closeAndRemoveOwnedSocket() }
    let currentIdentity = try requireCurrentAdHocIdentity()
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      defer { completed.signal() }
      do {
        let descriptor = try listener.accept(timeoutMilliseconds: 5_000)
        defer { _ = Darwin.close(descriptor) }
        let challenge = try Self.challenge(
          descriptor: descriptor,
          identity: currentIdentity,
          socketIdentity: listener.identity
        )
        let deadline = try ControlTransportDeadline(timeoutMilliseconds: 5_000)
        try ControlFrameCodec.write(
          try ControlPlaneCanonicalJSON.encode(challenge),
          kind: .frame,
          descriptor: descriptor,
          deadline: deadline
        )
        _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
        _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
        let mismatched = ControlResponseEnvelope(
          requestID: "different-request-id",
          status: .completed,
          reasonCode: .completed
        )
        try ControlFrameCodec.write(
          try ControlPlaneCanonicalJSON.encode(mismatched),
          kind: .response,
          descriptor: descriptor,
          deadline: deadline
        )
      } catch {
        XCTFail("minimal response server failed: \(error)")
      }
    }

    XCTAssertThrowsError(
      try client(socketPath: listener.path).send(request())
    ) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .invalidResponse)
    }
    XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
  }

  func testListenerPublishesOnlyPrivateNonSymlinkSocket() throws {
    let root = try makeOwnedRoot()
    defer { removeOwnedRoot(root) }
    let path = root.appendingPathComponent("control.sock").path
    let listener = try ControlUnixSocketListener(path: path)
    defer { listener.closeAndRemoveOwnedSocket() }
    try assertPrivateSocket(at: path)
    var status = stat()
    XCTAssertEqual(lstat(path, &status), 0)
    XCTAssertEqual(status.st_mode & S_IFMT, S_IFSOCK)
    XCTAssertEqual(status.st_mode & 0o7777, 0o600)
  }

  private func request() -> ControlRequestEnvelope {
    ControlRequestEnvelope(
      requestID: "gate3-client-request",
      operation: "health.get",
      timeoutMilliseconds: 5_000
    )
  }

  private func client(socketPath: String) throws -> PersistentControlClient {
    let identity = try requireCurrentAdHocIdentity()
    return PersistentControlClient(
      socketPath: socketPath,
      serverTrustPolicy: PersistentControlServerTrustPolicy(
        pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
      )
    )
  }

  private func serve(
    listener: ControlUnixSocketListener,
    store: SQLiteStateStore,
    identity: CodeIdentity,
    daemonGeneration: UInt64,
    expectedConnections: Int,
    counter: LiveInvocationCounter,
    clients: () throws -> Void
  ) throws {
    let adapter = try SQLiteControlIdentitySecurityAdapter(store: store, sessionLifetime: 60)
    let authenticator = ControlPeerAuthenticator(
      policy: try ControlPeerTrustPolicy(
        expectedUserID: UInt32(geteuid()),
        pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
      ),
      subjectResolver: adapter,
      sessionStore: adapter
    )
    let server = try PersistentControlConnectionServer(
      authenticator: authenticator,
      requestRepository: ControlRequestRepository(store: store),
      daemonGeneration: daemonGeneration,
      socketIdentity: listener.identity,
      mutatingOperations: ["service.start"],
      auditRecorder: ClientTestControlAuditRecorder(),
      authorizer: allowingTestControlRequestAuthorizer,
      admissionEvaluator: allowingTestControlAdmissionEvaluator
    ) { _, request, _ in
      counter.increment()
      return ControlResponseEnvelope(
        requestID: request.requestID,
        status: .completed,
        reasonCode: .completed
      )
    }
    let accepted = DispatchGroup()
    let serverResult = ServerResult()
    let acceptFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      defer { acceptFinished.signal() }
      do {
        for _ in 0..<expectedConnections {
          let descriptor = try listener.accept(timeoutMilliseconds: 10_000)
          accepted.enter()
          DispatchQueue.global(qos: .userInitiated).async {
            defer {
              _ = Darwin.close(descriptor)
              accepted.leave()
            }
            do {
              try server.serve(descriptor: descriptor)
            } catch {
              serverResult.error = error
            }
          }
        }
      } catch {
        serverResult.error = error
      }
    }
    try clients()
    XCTAssertEqual(acceptFinished.wait(timeout: .now() + 10), .success)
    XCTAssertEqual(accepted.wait(timeout: .now() + 10), .success)
    XCTAssertNil(serverResult.error)
  }

  private static func challenge(
    descriptor: Int32,
    identity: CodeIdentity,
    socketIdentity: ControlSocketIdentity
  ) throws -> ControlPeerCredentialChallenge {
    let credentials = try DarwinControlPeerCredentialReader().read(descriptor: descriptor)
    let peer = UnixPeerIdentity(
      effectiveUID: credentials.auditEffectiveUID,
      effectiveGID: credentials.auditEffectiveGID,
      pid: credentials.auditPID,
      pidVersion: credentials.auditPIDVersion,
      auditSessionID: credentials.auditSessionID,
      codeIdentity: identity
    )
    return ControlPeerCredentialChallenge(
      subjectID: "gate3-current-client",
      serverNonce: Data(repeating: 0x73, count: 32).base64EncodedString(),
      daemonGeneration: 1,
      socketDevice: socketIdentity.device,
      socketInode: socketIdentity.inode,
      peer: peer,
      credentialProofRequired: false
    )
  }

  private func requireCurrentAdHocIdentity() throws -> CodeIdentity {
    let identity = try DarwinCurrentControlCodeIdentity.inspect()
    guard identity.validationMode == .pinnedAdHoc else {
      throw XCTSkip(
        "This reciprocal test requires the current test executable to be ad-hoc signed.")
    }
    return identity
  }

  private func assertPrivateSocket(at path: String) throws {
    var status = stat()
    XCTAssertEqual(lstat(path, &status), 0)
    XCTAssertEqual(status.st_mode & S_IFMT, S_IFSOCK)
    XCTAssertEqual(status.st_mode & 0o7777, 0o600)
    XCTAssertEqual(status.st_uid, geteuid())
  }

  private func makeOwnedRoot() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let compactID = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    let root = repository.appendingPathComponent(
      ".build/p09c-\(compactID.prefix(12))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    return root
  }

  private func removeOwnedRoot(_ root: URL) {
    let expected = "/.build/p09c-"
    guard root.path.contains(expected),
      root.lastPathComponent.range(of: "^p09c-[a-f0-9]{12}$", options: .regularExpression) != nil,
      (try? FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?
        .intValue == 0o700
    else {
      return
    }
    try? FileManager.default.removeItem(at: root)
  }
}

private final class ClientTestControlAuditRecorder: ControlSecurityAuditRecording, @unchecked Sendable {
  func record(_ event: ControlSecurityAuditEvent) throws -> AuditRecord {
    try event.validate()
    return AuditRecord(
      identifier: "client-test-audit",
      segmentID: "client-test-segment",
      sequence: 1,
      timestamp: Date(),
      subjectID: event.subjectID,
      requestID: event.requestID,
      target: event.target,
      action: event.action,
      outcome: event.outcome,
      reasonCode: event.reasonCode,
      operationRef: event.operationRef,
      payloadDigest: event.payloadDigest,
      recordDigest: "sha256:" + String(repeating: "3", count: 64),
      signingKeyID: "test-key"
    )
  }
}

private final class ServerResult: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: Error?

  var error: Error? {
    get { lock.withLock { storedError } }
    set { lock.withLock { storedError = newValue } }
  }
}

private final class LiveInvocationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue = 0

  var value: Int { lock.withLock { storedValue } }
  func increment() { lock.withLock { storedValue += 1 } }
}

private final class LiveResponseCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storedResponses: [ControlResponseEnvelope] = []
  private var storedError: Error?

  var responses: [ControlResponseEnvelope] { lock.withLock { storedResponses } }
  var error: Error? { lock.withLock { storedError } }
  func append(_ response: ControlResponseEnvelope) {
    lock.withLock { storedResponses.append(response) }
  }
  func record(_ error: Error) {
    lock.withLock { if storedError == nil { storedError = error } }
  }
}
