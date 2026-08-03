import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightState

public enum PersistentControlServerError: Error, Equatable, Sendable {
  case unsafeSocketPath
  case socketAlreadyExists
  case socketCreationFailed
  case socketBindFailed
  case socketListenFailed
  case socketIdentityChanged
  case acceptFailed
  case invalidRequest
  case responseTooLarge
  case persistenceFailed
}

public struct ControlSocketIdentity: Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64

  public init(device: UInt64, inode: UInt64) {
    self.device = device
    self.inode = inode
  }
}

public final class ControlUnixSocketListener: @unchecked Sendable {
  public let path: String
  public let identity: ControlSocketIdentity
  public let rootIdentity: ControlSocketIdentity

  private let descriptor: Int32
  private let lock = NSLock()
  private var closed = false

  public init(path: String, recoverStaleSocket: Bool = false) throws {
    let url = URL(fileURLWithPath: path)
    let parent = url.deletingLastPathComponent().path
    let reconstructed = URL(fileURLWithPath: parent, isDirectory: true)
      .appendingPathComponent(url.lastPathComponent).path
    guard path.hasPrefix("/"), path == reconstructed,
      !url.lastPathComponent.isEmpty,
      url.lastPathComponent != ".",
      url.lastPathComponent != "..",
      try Self.canonicalExistingPath(parent) == parent
    else {
      throw PersistentControlServerError.unsafeSocketPath
    }
    var root = stat()
    guard lstat(parent, &root) == 0,
      (root.st_mode & S_IFMT) == S_IFDIR,
      (root.st_mode & 0o7777) == 0o700,
      root.st_uid == geteuid()
    else {
      throw PersistentControlServerError.unsafeSocketPath
    }
    var existing = stat()
    if lstat(path, &existing) == 0 {
      guard recoverStaleSocket else {
        throw PersistentControlServerError.socketAlreadyExists
      }
      try Self.removeVerifiedStaleSocket(path: path, status: existing)
    } else if errno != ENOENT {
      throw PersistentControlServerError.unsafeSocketPath
    }
    let rootIdentity = ControlSocketIdentity(
      device: UInt64(root.st_dev), inode: UInt64(root.st_ino))
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw PersistentControlServerError.socketCreationFailed
    }
    var createdIdentity: ControlSocketIdentity?
    do {
      try ControlFrameCodec.configureNoSigPipe(descriptor: descriptor)
      var address = try Self.address(path)
      let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(descriptor, $0, Self.addressLength(path))
        }
      }
      guard bound == 0, chmod(path, 0o600) == 0 else {
        throw PersistentControlServerError.socketBindFailed
      }
      var socket = stat()
      var currentRoot = stat()
      guard lstat(path, &socket) == 0,
        (socket.st_mode & S_IFMT) == S_IFSOCK,
        (socket.st_mode & 0o7777) == 0o600,
        socket.st_uid == geteuid(),
        lstat(parent, &currentRoot) == 0,
        ControlSocketIdentity(
          device: UInt64(currentRoot.st_dev), inode: UInt64(currentRoot.st_ino)
        ) == rootIdentity
      else {
        throw PersistentControlServerError.socketIdentityChanged
      }
      let identity = ControlSocketIdentity(
        device: UInt64(socket.st_dev), inode: UInt64(socket.st_ino))
      createdIdentity = identity
      guard Darwin.listen(descriptor, 128) == 0 else {
        throw PersistentControlServerError.socketListenFailed
      }
      self.path = path
      self.descriptor = descriptor
      self.identity = identity
      self.rootIdentity = rootIdentity
    } catch {
      _ = Darwin.close(descriptor)
      if let createdIdentity {
        Self.removeOwnedSocket(path: path, identity: createdIdentity)
      }
      throw error
    }
  }

  deinit {
    closeAndRemoveOwnedSocket()
  }

  public func accept(timeoutMilliseconds: Int) throws -> Int32 {
    guard timeoutMilliseconds > 0 else {
      throw PersistentControlServerError.acceptFailed
    }
    var pollEntry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    let result = Darwin.poll(&pollEntry, 1, Int32(min(timeoutMilliseconds, Int(Int32.max))))
    guard result > 0, pollEntry.revents & Int16(POLLIN) != 0 else {
      throw PersistentControlServerError.acceptFailed
    }
    let accepted = Darwin.accept(descriptor, nil, nil)
    guard accepted >= 0 else {
      throw PersistentControlServerError.acceptFailed
    }
    do {
      try ControlFrameCodec.configureNoSigPipe(descriptor: accepted)
      return accepted
    } catch {
      _ = Darwin.close(accepted)
      throw error
    }
  }

  public func closeAndRemoveOwnedSocket() {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    closed = true
    _ = Darwin.close(descriptor)
    Self.removeOwnedSocket(path: path, identity: identity)
  }

  private static func removeOwnedSocket(path: String, identity: ControlSocketIdentity) {
    var status = stat()
    guard lstat(path, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFSOCK,
      ControlSocketIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
        == identity
    else { return }
    _ = unlink(path)
  }

  private static func removeVerifiedStaleSocket(path: String, status: stat) throws {
    guard (status.st_mode & S_IFMT) == S_IFSOCK,
      (status.st_mode & 0o7777) == 0o600,
      status.st_uid == geteuid()
    else {
      throw PersistentControlServerError.unsafeSocketPath
    }
    let pinned = ControlSocketIdentity(
      device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard probe >= 0 else {
      throw PersistentControlServerError.socketCreationFailed
    }
    defer { _ = Darwin.close(probe) }
    var address = try Self.address(path)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(probe, $0, Self.addressLength(path))
      }
    }
    if result == 0 {
      throw PersistentControlServerError.socketAlreadyExists
    }
    guard errno == ECONNREFUSED || errno == ENOENT else {
      throw PersistentControlServerError.socketAlreadyExists
    }
    if errno == ENOENT { return }
    var current = stat()
    guard lstat(path, &current) == 0,
      (current.st_mode & S_IFMT) == S_IFSOCK,
      (current.st_mode & 0o7777) == 0o600,
      current.st_uid == geteuid(),
      ControlSocketIdentity(
        device: UInt64(current.st_dev), inode: UInt64(current.st_ino)) == pinned
    else {
      throw PersistentControlServerError.socketIdentityChanged
    }
    guard unlink(path) == 0 else {
      throw PersistentControlServerError.socketIdentityChanged
    }
  }

  private static func canonicalExistingPath(_ path: String) throws -> String {
    guard let resolved = path.withCString({ realpath($0, nil) }) else {
      throw PersistentControlServerError.unsafeSocketPath
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private static func address(_ path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    else { throw PersistentControlServerError.unsafeSocketPath }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.initializeMemory(as: UInt8.self, repeating: 0)
      destination.copyBytes(from: bytes)
    }
    return address
  }

  private static func addressLength(_ path: String) -> socklen_t {
    socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
  }
}

public struct PersistentControlConnectionServer: Sendable {
  public typealias Handler =
    @Sendable (
      AuthenticatedControlPeer,
      ControlRequestEnvelope,
      ControlTransportDeadline
    ) throws -> ControlResponseEnvelope

  private let authenticator: ControlPeerAuthenticator
  private let requestRepository: ControlRequestRepository
  private let daemonGeneration: UInt64
  private let socketIdentity: ControlSocketIdentity
  private let mutatingOperations: Set<String>
  private let auditRecorder: any ControlSecurityAuditRecording
  private let handler: Handler
  private let now: @Sendable () -> Date
  private let monotonicNow: @Sendable () -> UInt64

  public init(
    authenticator: ControlPeerAuthenticator,
    requestRepository: ControlRequestRepository,
    daemonGeneration: UInt64,
    socketIdentity: ControlSocketIdentity,
    mutatingOperations: Set<String>,
    auditRecorder: any ControlSecurityAuditRecording,
    now: @escaping @Sendable () -> Date = Date.init,
    monotonicNow: @escaping @Sendable () -> UInt64 = {
      DispatchTime.now().uptimeNanoseconds
    },
    handler: @escaping Handler
  ) throws {
    guard daemonGeneration > 0, socketIdentity.device > 0, socketIdentity.inode > 0 else {
      throw PersistentControlServerError.invalidRequest
    }
    self.authenticator = authenticator
    self.requestRepository = requestRepository
    self.daemonGeneration = daemonGeneration
    self.socketIdentity = socketIdentity
    self.mutatingOperations = mutatingOperations
    self.auditRecorder = auditRecorder
    self.now = now
    self.monotonicNow = monotonicNow
    self.handler = handler
  }

  public func serve(descriptor: Int32) throws {
    let peer = try authenticate(descriptor: descriptor)
    while true {
      do {
        try authenticator.validateSession(peer.binding, daemonGeneration: daemonGeneration)
        try ControlFrameCodec.waitForFrame(descriptor: descriptor)
        let requestData = try ControlFrameCodec.read(
          kind: .request,
          descriptor: descriptor,
          deadline: try ControlTransportDeadline(
            timeoutMilliseconds: ControlPlaneContract.maximumAuthenticationHandshakeMilliseconds
          )
        )
        let request = try Self.decodeRequest(requestData)
        let processed = try process(peer: peer, request: request)
        try write(processed.response, descriptor: descriptor, deadline: processed.deadline)
      } catch ControlTransportError.peerClosed {
        return
      }
    }
  }

  private func authenticate(descriptor: Int32) throws -> AuthenticatedControlPeer {
    let prepared = try authenticator.prepareAuthentication(
      descriptor: descriptor,
      daemonGeneration: daemonGeneration,
      serverNonce: Data(UUID().uuidString.utf8).base64EncodedString(),
      socketDevice: socketIdentity.device,
      socketInode: socketIdentity.inode
    )
    let deadline = try ControlTransportDeadline(
      timeoutMilliseconds: ControlPlaneContract.maximumAuthenticationHandshakeMilliseconds)
    try ControlFrameCodec.write(
      try ControlPlaneCanonicalJSON.encode(prepared.challenge),
      kind: .frame,
      descriptor: descriptor,
      deadline: deadline
    )
    let responseData = try ControlFrameCodec.read(
      kind: .request,
      descriptor: descriptor,
      deadline: deadline
    )
    let response = try ControlAuthenticationWireContract.decodeResponse(
      responseData,
      for: prepared.challenge
    )
    return try authenticator.completeAuthentication(prepared, response: response)
  }

  private func process(
    peer: AuthenticatedControlPeer,
    request: ControlRequestEnvelope
  ) throws -> (response: ControlResponseEnvelope, deadline: ControlTransportDeadline) {
    let deadline = try ControlTransportDeadline(
      timeoutMilliseconds: request.timeoutMilliseconds!,
      monotonicNow: monotonicNow
    )
    try deadline.assertActive()
    let isMutation = mutatingOperations.contains(request.operation)
    if isMutation {
      let acceptedAt = now()
      let timestamp = ISO8601DateFormatter().string(from: acceptedAt)
      let canonicalRequest = try ControlPlaneCanonicalJSON.encode(request)
      let digest = SHA256.hash(data: canonicalRequest).map { String(format: "%02x", $0) }.joined()
      let submission = ControlRequestSubmission(
        request: ControlRequestRecord(
          requestID: request.requestID,
          subjectID: peer.binding.subject.identifier,
          idempotencyKey: request.idempotencyKey,
          requestDigestSHA256: digest,
          status: .accepted,
          createdAt: timestamp,
          updatedAt: timestamp
        ),
        idempotencyExpiresAt: request.idempotencyKey == nil
          ? nil
          : ISO8601DateFormatter().string(
            from: acceptedAt.addingTimeInterval(24 * 60 * 60))
      )
      do {
        switch try requestRepository.recordOrReplay(submission) {
        case .replayed(let record):
          let replay = Self.replayResponse(record)
          if record.status == .accepted {
            try recordAudit(
              peer: peer,
              request: request,
              action: .request,
              outcome: "accepted",
              reasonCode: ControlReasonCode.accepted.rawValue,
              operationRef: record.operationReference,
              payloadDigest: "sha256:\(digest)",
              stage: "accepted"
            )
            if record.operationReference != nil {
              try recordResponseAudit(
                peer: peer,
                request: request,
                response: replay,
                stage: "operation-accepted"
              )
            }
          }
          return (replay, deadline)
        case .created:
          try recordAudit(
            peer: peer,
            request: request,
            action: .request,
            outcome: "accepted",
            reasonCode: ControlReasonCode.accepted.rawValue,
            operationRef: nil,
            payloadDigest: "sha256:\(digest)",
            stage: "accepted"
          )
          break
        }
      } catch let error as StateStoreError {
        guard case .invalidRecord = error else { throw error }
        try requestRepository.recordRejectedConflict(
          ControlRequestRecord(
            requestID: request.requestID,
            subjectID: peer.binding.subject.identifier,
            idempotencyKey: nil,
            requestDigestSHA256: digest,
            status: .rejected,
            createdAt: timestamp,
            updatedAt: timestamp
          )
        )
        try recordAudit(
          peer: peer,
          request: request,
          action: .request,
          outcome: "rejected",
          reasonCode: ControlReasonCode.idempotencyConflict.rawValue,
          operationRef: nil,
          payloadDigest: "sha256:\(digest)",
          stage: "idempotency-conflict"
        )
        return (
          ControlResponseEnvelope(
            requestID: request.requestID,
            status: .rejected,
            reasonCode: .idempotencyConflict,
            error: SanitizedError(
              code: "idempotencyConflict",
              message: "The idempotency key or request identifier is already bound."
            )
          )
        , deadline)
      }
    }
    try deadline.assertActive()
    let response: ControlResponseEnvelope
    do {
      response = try handler(peer, request, deadline)
    } catch {
      response = ControlResponseEnvelope(
        requestID: request.requestID,
        status: .error,
        reasonCode: .internalError,
        error: SanitizedError(
          code: "operationFailed",
          message: "The control operation did not complete."
        )
      )
    }
    try deadline.assertActive()
    try response.validate()
    if isMutation, response.status == .accepted {
      guard let operationReference = response.operationRef else {
        throw PersistentControlServerError.persistenceFailed
      }
      do {
        _ = try requestRepository.recordAcceptedOperationReference(
          requestID: request.requestID,
          operationReference: operationReference,
          updatedAt: ISO8601DateFormatter().string(from: now())
        )
      } catch {
        throw PersistentControlServerError.persistenceFailed
      }
      try recordResponseAudit(
        peer: peer,
        request: request,
        response: response,
        stage: "operation-accepted"
      )
    } else if isMutation {
      let canonicalResponse = try ControlPlaneCanonicalJSON.encode(response)
      let responseDigest = SHA256.hash(data: canonicalResponse)
        .map { String(format: "%02x", $0) }.joined()
      try recordAudit(
        peer: peer,
        request: request,
        action: .operation,
        outcome: response.status.rawValue,
        reasonCode: response.reasonCode.rawValue,
        operationRef: response.operationRef,
        payloadDigest: "sha256:\(responseDigest)",
        stage: "terminal"
      )
      let status: ControlRequestStatus
      switch response.status {
      case .completed: status = .completed
      case .rejected: status = .rejected
      case .error: status = .error
      case .accepted: status = .accepted
      }
      do {
        _ = try requestRepository.updateTerminal(
          requestID: request.requestID,
          status: status,
          operationReference: response.operationRef,
          updatedAt: ISO8601DateFormatter().string(from: now())
        )
      } catch {
        throw PersistentControlServerError.persistenceFailed
      }
    }
    return (response, deadline)
  }

  private func recordResponseAudit(
    peer: AuthenticatedControlPeer,
    request: ControlRequestEnvelope,
    response: ControlResponseEnvelope,
    stage: String
  ) throws {
    let canonicalResponse = try ControlPlaneCanonicalJSON.encode(response)
    let responseDigest = SHA256.hash(data: canonicalResponse)
      .map { String(format: "%02x", $0) }.joined()
    try recordAudit(
      peer: peer,
      request: request,
      action: .operation,
      outcome: response.status.rawValue,
      reasonCode: response.reasonCode.rawValue,
      operationRef: response.operationRef,
      payloadDigest: "sha256:\(responseDigest)",
      stage: stage
    )
  }

  private func recordAudit(
    peer: AuthenticatedControlPeer,
    request: ControlRequestEnvelope,
    action: AuditAction,
    outcome: String,
    reasonCode: String,
    operationRef: String?,
    payloadDigest: String,
    stage: String
  ) throws {
    do {
      try auditRecorder.record(
        ControlSecurityAuditEvent(
          subjectID: peer.binding.subject.identifier,
          requestID: request.requestID,
          target: request.operation,
          action: action,
          outcome: outcome,
          reasonCode: reasonCode,
          operationRef: operationRef,
          payloadDigest: payloadDigest,
          deduplicationKey: "control:\(request.requestID):\(stage)"
        )
      )
    } catch {
      throw PersistentControlServerError.persistenceFailed
    }
  }

  private func write(
    _ response: ControlResponseEnvelope,
    descriptor: Int32,
    deadline: ControlTransportDeadline
  ) throws {
    let data = try ControlPlaneCanonicalJSON.encode(response)
    guard data.count <= ControlPlaneContract.maximumResponseOrFrameBytes else {
      throw PersistentControlServerError.responseTooLarge
    }
    try ControlFrameCodec.write(
      data,
      kind: .response,
      descriptor: descriptor,
      deadline: deadline
    )
  }

  private static func decodeRequest(_ data: Data) throws -> ControlRequestEnvelope {
    let request = try Phase09StrictDecoder.decode(
      ControlRequestEnvelope.self,
      from: data,
      allowedKeys: [
        "apiVersion", "protocolRevision", "requestID", "operation",
        "timeoutMilliseconds", "idempotencyKey", "body",
      ],
      requiredKeys: [
        "apiVersion", "protocolRevision", "requestID", "operation", "timeoutMilliseconds",
      ]
    )
    try request.validate()
    guard request.protocolRevision == .current,
      request.requestID.range(
        of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil,
      request.operation.range(
        of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil
    else { throw PersistentControlServerError.invalidRequest }
    return request
  }

  private static func replayResponse(_ record: ControlRequestRecord) -> ControlResponseEnvelope {
    let status: ControlResponseStatus
    let reason: ControlReasonCode
    switch record.status {
    case .accepted:
      status = .accepted
      reason = .accepted
    case .completed:
      status = .completed
      reason = .completed
    case .rejected:
      status = .rejected
      reason = .conflict
    case .error:
      status = .error
      reason = .internalError
    }
    return ControlResponseEnvelope(
      requestID: record.requestID,
      status: status,
      reasonCode: reason,
      operationRef: record.operationReference,
      error: status == .rejected || status == .error
        ? SanitizedError(code: "durableReplay", message: "The durable request is terminal.")
        : nil
    )
  }
}
