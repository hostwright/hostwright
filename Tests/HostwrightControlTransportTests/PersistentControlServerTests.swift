import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightState
import XCTest

@testable import HostwrightControlTransport

final class PersistentControlServerTests: XCTestCase {
  func testListenerRecoversOnlyVerifiedStaleSocket() throws {
    try withTemporaryDirectory { root in
      let path = root.appendingPathComponent("control.sock").path
      let staleDescriptor = try bindSocket(at: path)
      var stale = stat()
      XCTAssertEqual(lstat(path, &stale), 0)
      XCTAssertEqual(Darwin.close(staleDescriptor), 0)

      let recovered = try ControlUnixSocketListener(path: path, recoverStaleSocket: true)
      defer { recovered.closeAndRemoveOwnedSocket() }
      XCTAssertNotEqual(recovered.identity.inode, UInt64(stale.st_ino))

      XCTAssertThrowsError(
        try ControlUnixSocketListener(path: path, recoverStaleSocket: true)
      ) { error in
        XCTAssertEqual(error as? PersistentControlServerError, .socketAlreadyExists)
      }
      var active = stat()
      XCTAssertEqual(lstat(path, &active), 0)
      XCTAssertEqual(UInt64(active.st_ino), recovered.identity.inode)
    }
  }

  func testListenerCreatesSecureSocketAndPreservesInodeSubstitutionOnCleanup() throws {
    try withTemporaryDirectory { root in
      let path = root.appendingPathComponent("control.sock").path
      let listener = try ControlUnixSocketListener(path: path)
      var initial = stat()
      XCTAssertEqual(lstat(path, &initial), 0)
      XCTAssertEqual(initial.st_mode & S_IFMT, S_IFSOCK)
      XCTAssertEqual(initial.st_mode & 0o7777, 0o600)
      XCTAssertEqual(initial.st_uid, geteuid())
      XCTAssertEqual(
        ControlSocketIdentity(device: UInt64(initial.st_dev), inode: UInt64(initial.st_ino)),
        listener.identity
      )
      XCTAssertEqual(unlink(path), 0)
      let replacement = try bindSocket(at: path)
      defer {
        _ = Darwin.close(replacement)
        _ = unlink(path)
      }

      listener.closeAndRemoveOwnedSocket()

      var substituted = stat()
      XCTAssertEqual(lstat(path, &substituted), 0)
      XCTAssertEqual(substituted.st_mode & S_IFMT, S_IFSOCK)
      XCTAssertNotEqual(UInt64(substituted.st_ino), listener.identity.inode)
    }
  }

  func testAuthenticatedMutationPersistsBeforeReplyAndIdempotentReplaySkipsHandler() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let identity = fixtureIdentity()
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "control-test-subject",
        userID: UInt32(geteuid()),
        codeIdentity: identity,
        declaredBySubjectID: "control-test-subject",
        declaredAt: "2026-08-02T20:00:00Z",
        updatedAt: "2026-08-02T20:00:00Z"
      )
    )
    let adapter = try SQLiteControlIdentitySecurityAdapter(
      store: store,
      sessionLifetime: 600,
      now: { Date(timeIntervalSince1970: 1_785_715_200) }
    )
    let rawCredentials = RawControlPeerCredentials(
      peerUID: UInt32(geteuid()),
      peerGID: UInt32(getegid()),
      peerPID: getpid(),
      auditEffectiveUID: UInt32(geteuid()),
      auditEffectiveGID: UInt32(getegid()),
      auditPID: getpid(),
      auditPIDVersion: 1,
      auditSessionID: 1,
      auditTokenData: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size)
    )
    let authenticator = ControlPeerAuthenticator(
      policy: try ControlPeerTrustPolicy(
        expectedUserID: UInt32(geteuid()),
        pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
      ),
      credentialReader: FixedCredentialReader(credentials: rawCredentials),
      codeValidator: FixedCodeValidator(identity: identity),
      subjectResolver: adapter,
      sessionStore: adapter
    )
    let invocations = InvocationCounter()
    let repository = ControlRequestRepository(
      store: store,
      now: { Date(timeIntervalSince1970: 1_785_715_200) }
    )
    let server = try PersistentControlConnectionServer(
      authenticator: authenticator,
      requestRepository: repository,
      daemonGeneration: 1,
      socketIdentity: ControlSocketIdentity(device: 31, inode: 37),
      mutatingOperations: ["service.start"],
      now: { Date(timeIntervalSince1970: 1_785_715_200) },
      handler: { _, request, _ in
        invocations.increment()
        XCTAssertEqual(try repository.load(request.requestID)?.status, .accepted)
        return ControlResponseEnvelope(
          requestID: request.requestID,
          status: .completed,
          reasonCode: .completed,
          operationRef: "operation-one"
        )
      }
    )
    let pair = try socketPair()
    defer {
      _ = Darwin.close(pair.client)
      _ = Darwin.close(pair.server)
    }
    try ControlFrameCodec.configureNoSigPipe(descriptor: pair.client)
    let serverResult = ServerResult()
    let serverFinished = expectation(description: "persistent server exits after peer close")
    DispatchQueue.global().async {
      defer { serverFinished.fulfill() }
      do {
        try server.serve(descriptor: pair.server)
      } catch {
        serverResult.error = error
      }
    }

    try completeAuthentication(descriptor: pair.client)
    let request = ControlRequestEnvelope(
      requestID: "mutation-one",
      operation: "service.start",
      timeoutMilliseconds: 1_000,
      idempotencyKey: "idem-one"
    )
    let requestData = try ControlPlaneCanonicalJSON.encode(request)
    try writeRequest(requestData, descriptor: pair.client)
    let first = try readResponse(descriptor: pair.client)
    XCTAssertEqual(first.status, .completed)
    XCTAssertEqual(first.operationRef, "operation-one")
    XCTAssertEqual(try repository.load("mutation-one")?.status, .completed)

    try writeRequest(requestData, descriptor: pair.client)
    let replay = try readResponse(descriptor: pair.client)
    XCTAssertEqual(replay.status, .completed)
    XCTAssertEqual(replay.operationRef, "operation-one")
    XCTAssertEqual(invocations.value, 1)
    XCTAssertEqual(
      try repository.load(subjectID: "control-test-subject", idempotencyKey: "idem-one")?.status,
      .completed)

    _ = Darwin.close(pair.client)
    wait(for: [serverFinished], timeout: 2)
    XCTAssertNil(serverResult.error)
  }

  func testDifferentRequestIDForSameIdempotencyKeyIsRejectedWithoutInvokingHandler() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let identity = fixtureIdentity()
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "control-test-subject",
        userID: UInt32(geteuid()),
        codeIdentity: identity,
        declaredBySubjectID: "control-test-subject",
        declaredAt: "2026-08-02T20:00:00Z",
        updatedAt: "2026-08-02T20:00:00Z"
      )
    )
    let adapter = try SQLiteControlIdentitySecurityAdapter(
      store: store,
      sessionLifetime: 600,
      now: { Date(timeIntervalSince1970: 1_785_715_200) }
    )
    let rawCredentials = RawControlPeerCredentials(
      peerUID: UInt32(geteuid()),
      peerGID: UInt32(getegid()),
      peerPID: getpid(),
      auditEffectiveUID: UInt32(geteuid()),
      auditEffectiveGID: UInt32(getegid()),
      auditPID: getpid(),
      auditPIDVersion: 1,
      auditSessionID: 1,
      auditTokenData: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size)
    )
    let authenticator = ControlPeerAuthenticator(
      policy: try ControlPeerTrustPolicy(
        expectedUserID: UInt32(geteuid()),
        pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
      ),
      credentialReader: FixedCredentialReader(credentials: rawCredentials),
      codeValidator: FixedCodeValidator(identity: identity),
      subjectResolver: adapter,
      sessionStore: adapter
    )
    let invocations = InvocationCounter()
    let server = try PersistentControlConnectionServer(
      authenticator: authenticator,
      requestRepository: ControlRequestRepository(
        store: store,
        now: { Date(timeIntervalSince1970: 1_785_715_200) }
      ),
      daemonGeneration: 1,
      socketIdentity: ControlSocketIdentity(device: 31, inode: 37),
      mutatingOperations: ["service.start"],
      now: { Date(timeIntervalSince1970: 1_785_715_200) },
      handler: { _, request, _ in
        invocations.increment()
        return ControlResponseEnvelope(
          requestID: request.requestID,
          status: .completed,
          reasonCode: .completed
        )
      }
    )
    let pair = try socketPair()
    defer {
      _ = Darwin.close(pair.client)
      _ = Darwin.close(pair.server)
    }
    try ControlFrameCodec.configureNoSigPipe(descriptor: pair.client)
    let serverResult = ServerResult()
    let serverFinished = expectation(description: "persistent server exits after peer close")
    DispatchQueue.global().async {
      defer { serverFinished.fulfill() }
      do {
        try server.serve(descriptor: pair.server)
      } catch {
        serverResult.error = error
      }
    }

    try completeAuthentication(descriptor: pair.client)
    let firstRequest = ControlRequestEnvelope(
      requestID: "idempotency-first",
      operation: "service.start",
      timeoutMilliseconds: 1_000,
      idempotencyKey: "shared-idempotency-key"
    )
    try writeRequest(try ControlPlaneCanonicalJSON.encode(firstRequest), descriptor: pair.client)
    XCTAssertEqual(try readResponse(descriptor: pair.client).status, .completed)

    let conflictingRequest = ControlRequestEnvelope(
      requestID: "idempotency-conflict",
      operation: "service.start",
      timeoutMilliseconds: 1_000,
      idempotencyKey: "shared-idempotency-key"
    )
    try writeRequest(try ControlPlaneCanonicalJSON.encode(conflictingRequest), descriptor: pair.client)
    let conflict = try readResponse(descriptor: pair.client)
    XCTAssertEqual(conflict.requestID, conflictingRequest.requestID)
    XCTAssertEqual(conflict.status, .rejected)
    XCTAssertEqual(conflict.reasonCode, .idempotencyConflict)
    XCTAssertEqual(invocations.value, 1)

    _ = Darwin.close(pair.client)
    wait(for: [serverFinished], timeout: 2)
    XCTAssertNil(serverResult.error)
  }

  func testRevokedSessionPreventsNextPersistentRequestFromInvokingHandler() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let identity = fixtureIdentity()
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "control-test-subject",
        userID: UInt32(geteuid()),
        codeIdentity: identity,
        declaredBySubjectID: "control-test-subject",
        declaredAt: "2026-08-02T20:00:00Z",
        updatedAt: "2026-08-02T20:00:00Z"
      )
    )
    let adapter = try SQLiteControlIdentitySecurityAdapter(
      store: store,
      sessionLifetime: 600,
      now: { Date(timeIntervalSince1970: 1_785_715_200) }
    )
    let sessionStore = ValidationGateSessionStore(base: adapter)
    let rawCredentials = RawControlPeerCredentials(
      peerUID: UInt32(geteuid()),
      peerGID: UInt32(getegid()),
      peerPID: getpid(),
      auditEffectiveUID: UInt32(geteuid()),
      auditEffectiveGID: UInt32(getegid()),
      auditPID: getpid(),
      auditPIDVersion: 1,
      auditSessionID: 1,
      auditTokenData: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size)
    )
    let authenticator = ControlPeerAuthenticator(
      policy: try ControlPeerTrustPolicy(
        expectedUserID: UInt32(geteuid()),
        pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
      ),
      credentialReader: FixedCredentialReader(credentials: rawCredentials),
      codeValidator: FixedCodeValidator(identity: identity),
      subjectResolver: adapter,
      sessionStore: sessionStore
    )
    let invocations = InvocationCounter()
    let server = try PersistentControlConnectionServer(
      authenticator: authenticator,
      requestRepository: ControlRequestRepository(store: store),
      daemonGeneration: 1,
      socketIdentity: ControlSocketIdentity(device: 31, inode: 37),
      mutatingOperations: [],
      handler: { _, request, _ in
        invocations.increment()
        return ControlResponseEnvelope(
          requestID: request.requestID,
          status: .completed,
          reasonCode: .completed
        )
      }
    )
    let pair = try socketPair()
    defer {
      _ = Darwin.close(pair.client)
      _ = Darwin.close(pair.server)
    }
    try ControlFrameCodec.configureNoSigPipe(descriptor: pair.client)
    let serverResult = ServerResult()
    let serverFinished = expectation(description: "server rejects revoked persistent session")
    DispatchQueue.global().async {
      defer { serverFinished.fulfill() }
      do {
        try server.serve(descriptor: pair.server)
      } catch {
        serverResult.error = error
      }
    }

    try completeAuthentication(descriptor: pair.client)
    XCTAssertEqual(sessionStore.validationStarted.wait(timeout: .now() + 1), .success)
    let sessionID = try XCTUnwrap(sessionStore.persistedBinding?.sessionID)
    try store.controlIdentities.revoke(
      ControlIdentityRevocationRecord(
        revocationID: "revoke-persistent-session",
        targetKind: .session,
        targetIdentifier: sessionID,
        reason: "persistent session must be invalidated before request handling",
        actorSubjectID: "control-test-subject",
        revokedAt: "2026-08-03T00:00:01Z"
      )
    )
    let request = ControlRequestEnvelope(
      requestID: "request-after-revocation",
      operation: "health.get",
      timeoutMilliseconds: 1_000
    )
    try writeRequest(try ControlPlaneCanonicalJSON.encode(request), descriptor: pair.client)
    sessionStore.allowValidation.signal()

    wait(for: [serverFinished], timeout: 2)
    XCTAssertEqual(serverResult.error as? ControlPeerAuthenticationError, .sessionInactive)
    XCTAssertEqual(invocations.value, 0)
  }

  func testExpiredRequestDeadlineDoesNotInvokeHandler() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let identity = fixtureIdentity()
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "control-test-subject",
        userID: UInt32(geteuid()),
        codeIdentity: identity,
        declaredBySubjectID: "control-test-subject",
        declaredAt: "2026-08-02T20:00:00Z",
        updatedAt: "2026-08-02T20:00:00Z"
      )
    )
    let adapter = try SQLiteControlIdentitySecurityAdapter(store: store, sessionLifetime: 600)
    let rawCredentials = RawControlPeerCredentials(
      peerUID: UInt32(geteuid()),
      peerGID: UInt32(getegid()),
      peerPID: getpid(),
      auditEffectiveUID: UInt32(geteuid()),
      auditEffectiveGID: UInt32(getegid()),
      auditPID: getpid(),
      auditPIDVersion: 1,
      auditSessionID: 1,
      auditTokenData: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size)
    )
    let authenticator = ControlPeerAuthenticator(
      policy: try ControlPeerTrustPolicy(
        expectedUserID: UInt32(geteuid()),
        pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
      ),
      credentialReader: FixedCredentialReader(credentials: rawCredentials),
      codeValidator: FixedCodeValidator(identity: identity),
      subjectResolver: adapter,
      sessionStore: adapter
    )
    let clock = FixedMonotonicClock(values: [10_000, 1_010_000])
    let invocations = InvocationCounter()
    let server = try PersistentControlConnectionServer(
      authenticator: authenticator,
      requestRepository: ControlRequestRepository(store: store),
      daemonGeneration: 1,
      socketIdentity: ControlSocketIdentity(device: 31, inode: 37),
      mutatingOperations: [],
      monotonicNow: { clock.next() },
      handler: { _, request, _ in
        invocations.increment()
        return ControlResponseEnvelope(
          requestID: request.requestID,
          status: .completed,
          reasonCode: .completed
        )
      }
    )
    let pair = try socketPair()
    defer {
      _ = Darwin.close(pair.client)
      _ = Darwin.close(pair.server)
    }
    try ControlFrameCodec.configureNoSigPipe(descriptor: pair.client)
    let serverResult = ServerResult()
    let serverFinished = expectation(description: "server rejects expired request deadline")
    DispatchQueue.global().async {
      defer { serverFinished.fulfill() }
      do {
        try server.serve(descriptor: pair.server)
      } catch {
        serverResult.error = error
      }
    }

    try completeAuthentication(descriptor: pair.client)
    let request = ControlRequestEnvelope(
      requestID: "expired-before-handler",
      operation: "health.get",
      timeoutMilliseconds: 1
    )
    try writeRequest(try ControlPlaneCanonicalJSON.encode(request), descriptor: pair.client)

    wait(for: [serverFinished], timeout: 2)
    XCTAssertEqual(serverResult.error as? ControlTransportError, .deadlineExceeded)
    XCTAssertEqual(invocations.value, 0)
  }

  func testOversizedFrameClosesConnectionBeforeRequestAllocation() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try minimalServer(root: root)
    let pair = try socketPair()
    defer {
      _ = Darwin.close(pair.client)
      _ = Darwin.close(pair.server)
    }
    try ControlFrameCodec.configureNoSigPipe(descriptor: pair.client)
    let serverResult = ServerResult()
    let finished = expectation(description: "server rejects malformed frame")
    DispatchQueue.global().async {
      defer { finished.fulfill() }
      do {
        try server.serve(descriptor: pair.server)
      } catch {
        serverResult.error = error
      }
    }
    try completeAuthentication(descriptor: pair.client)
    var prefix = UInt32(ControlFrameCodec.maximumRequestBytes + 1).bigEndian
    try withUnsafeBytes(of: &prefix) { bytes in
      try writeRaw(Data(bytes), descriptor: pair.client)
    }
    _ = Darwin.close(pair.client)
    wait(for: [finished], timeout: 2)
    XCTAssertEqual(serverResult.error as? ControlTransportError, .declaredLengthOutOfBounds)
  }

  private func minimalServer(root: URL) throws -> PersistentControlConnectionServer {
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let identity = fixtureIdentity()
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "control-test-subject",
        userID: UInt32(geteuid()),
        codeIdentity: identity,
        declaredBySubjectID: "control-test-subject",
        declaredAt: "2026-08-02T20:00:00Z",
        updatedAt: "2026-08-02T20:00:00Z"
      )
    )
    let adapter = try SQLiteControlIdentitySecurityAdapter(store: store, sessionLifetime: 600)
    let credentials = RawControlPeerCredentials(
      peerUID: UInt32(geteuid()), peerGID: UInt32(getegid()), peerPID: getpid(),
      auditEffectiveUID: UInt32(geteuid()), auditEffectiveGID: UInt32(getegid()),
      auditPID: getpid(), auditPIDVersion: 1, auditSessionID: 1,
      auditTokenData: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size)
    )
    let authenticator = ControlPeerAuthenticator(
      policy: try ControlPeerTrustPolicy(
        expectedUserID: UInt32(geteuid()),
        pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
      ),
      credentialReader: FixedCredentialReader(credentials: credentials),
      codeValidator: FixedCodeValidator(identity: identity), subjectResolver: adapter,
      sessionStore: adapter
    )
    return try PersistentControlConnectionServer(
      authenticator: authenticator,
      requestRepository: ControlRequestRepository(store: store),
      daemonGeneration: 1,
      socketIdentity: ControlSocketIdentity(device: 31, inode: 37),
      mutatingOperations: ["service.start"],
      handler: { _, request, _ in
        ControlResponseEnvelope(
          requestID: request.requestID, status: .completed, reasonCode: .completed)
      }
    )
  }

  private func completeAuthentication(descriptor: Int32) throws {
    let challengeData = try ControlFrameCodec.read(
      kind: .frame,
      descriptor: descriptor,
      deadline: try deadline()
    )
    let challenge = try ControlAuthenticationWireContract.decodeChallenge(challengeData)
    XCTAssertFalse(challenge.credentialProofRequired)
    let response = try ControlPlaneCanonicalJSON.encode(ControlAuthenticationResponse())
    try ControlFrameCodec.write(
      response, kind: .request, descriptor: descriptor, deadline: try deadline())
  }

  private func writeRequest(_ data: Data, descriptor: Int32) throws {
    try ControlFrameCodec.write(
      data, kind: .request, descriptor: descriptor, deadline: try deadline())
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

  private func fixtureIdentity() -> CodeIdentity {
    CodeIdentity(
      signingIdentifier: "hostwright-control",
      codeDirectoryHash: String(repeating: "a", count: 40),
      validationMode: .pinnedAdHoc
    )
  }

  private func deadline() throws -> ControlTransportDeadline {
    try ControlTransportDeadline(timeoutMilliseconds: 1_000)
  }

  private func socketPair() throws -> (client: Int32, server: Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw NSError(domain: "PersistentControlServerTests", code: Int(errno))
    }
    return (descriptors[0], descriptors[1])
  }

  private func bindSocket(at path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw NSError(domain: "PersistentControlServerTests", code: Int(errno))
    }
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.initializeMemory(as: UInt8.self, repeating: 0)
      destination.copyBytes(from: bytes)
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1))
      }
    }
    guard result == 0, chmod(path, 0o600) == 0 else {
      _ = Darwin.close(descriptor)
      throw NSError(domain: "PersistentControlServerTests", code: Int(errno))
    }
    return descriptor
  }

  private func writeRaw(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { source in
      guard let base = source.baseAddress else {
        throw NSError(domain: "PersistentControlServerTests", code: 1)
      }
      let count = Darwin.write(descriptor, base, source.count)
      guard count == source.count else {
        throw NSError(domain: "PersistentControlServerTests", code: Int(errno))
      }
    }
  }

  private func temporaryDirectory() throws -> URL {
    let buildDirectory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).appendingPathComponent(".build", isDirectory: true)
    let candidate = buildDirectory.appendingPathComponent(
      "hw-p09-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: candidate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let resolved = candidate.path.withCString { realpath($0, nil) }
    let pointer = try XCTUnwrap(resolved)
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
  }

  private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
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

private final class ValidationGateSessionStore: ControlSessionBindingStoring, @unchecked Sendable {
  let validationStarted = DispatchSemaphore(value: 0)
  let allowValidation = DispatchSemaphore(value: 0)

  private let base: SQLiteControlIdentitySecurityAdapter
  private let lock = NSLock()
  private var binding: ControlSessionBinding?

  init(base: SQLiteControlIdentitySecurityAdapter) {
    self.base = base
  }

  var persistedBinding: ControlSessionBinding? {
    lock.lock()
    defer { lock.unlock() }
    return binding
  }

  func persist(_ binding: ControlSessionBinding) throws {
    try base.persist(binding)
    lock.lock()
    self.binding = binding
    lock.unlock()
  }

  func isActive(sessionID: String, daemonGeneration: UInt64) throws -> Bool {
    validationStarted.signal()
    guard allowValidation.wait(timeout: .now() + 1) == .success else {
      return false
    }
    return try base.isActive(sessionID: sessionID, daemonGeneration: daemonGeneration)
  }
}

private final class FixedMonotonicClock: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UInt64]
  private var lastValue: UInt64

  init(values: [UInt64]) {
    precondition(!values.isEmpty)
    self.values = values
    lastValue = values[values.count - 1]
  }

  func next() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    guard !values.isEmpty else { return lastValue }
    lastValue = values.removeFirst()
    return lastValue
  }
}

private final class ServerResult: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: Error?

  var error: Error? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedError
    }
    set {
      lock.lock()
      storedError = newValue
      lock.unlock()
    }
  }
}
