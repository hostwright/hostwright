import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity

public enum PersistentControlClientError: Error, Equatable, Sendable {
  case unsafeSocket
  case connectionFailed
  case serverBindingMismatch
  case credentialRequired
  case invalidResponse
  case concurrencyLimit
  case streamLimit
  case deadlineExceeded
  case connectionClosed
}

public struct PersistentControlServerTrustPolicy: Sendable, Equatable {
  public let expectedUserID: UInt32
  public let pinnedAdHocCodeDirectoryHashes: Set<String>

  public init(
    expectedUserID: UInt32 = UInt32(geteuid()),
    pinnedAdHocCodeDirectoryHashes: Set<String> = []
  ) {
    self.expectedUserID = expectedUserID
    self.pinnedAdHocCodeDirectoryHashes = pinnedAdHocCodeDirectoryHashes
  }

  fileprivate func accepts(_ identity: CodeIdentity) -> Bool {
    switch identity.validationMode {
    case .installedRequirement:
      return identity.teamIdentifier == ControlPeerTrustPolicy.installedTeamIdentifier
        && identity.signingIdentifier == "hostwrightd"
    case .pinnedAdHoc:
      return identity.teamIdentifier == nil
        && identity.codeDirectoryHash.range(
          of: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$",
          options: .regularExpression
        ) != nil
        && pinnedAdHocCodeDirectoryHashes.contains(identity.codeDirectoryHash)
    }
  }
}

public struct PersistentControlClient: Sendable {
  public typealias CredentialProofProvider =
    @Sendable (
      ControlPeerCredentialChallenge
    ) throws -> ControlPeerCredentialProof?

  public let socketPath: String
  private let credentialProofProvider: CredentialProofProvider
  private let serverTrustPolicy: PersistentControlServerTrustPolicy

  public init(
    socketPath: String,
    serverTrustPolicy: PersistentControlServerTrustPolicy = .init(),
    credentialProofProvider: @escaping CredentialProofProvider = { _ in nil }
  ) {
    self.socketPath = socketPath
    self.serverTrustPolicy = serverTrustPolicy
    self.credentialProofProvider = credentialProofProvider
  }

  public func send(_ request: ControlRequestEnvelope) throws -> ControlResponseEnvelope {
    try request.validate()
    guard request.protocolRevision == .current, let timeout = request.timeoutMilliseconds else {
      throw PersistentControlClientError.invalidResponse
    }
    let pinned = try pinSocket()
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw PersistentControlClientError.connectionFailed }
    defer { _ = Darwin.close(descriptor) }
    try ControlFrameCodec.configureNoSigPipe(descriptor: descriptor)
    var address = try Self.address(socketPath)
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, Self.addressLength(socketPath))
      }
    }
    guard connected == 0, try pinSocket() == pinned else {
      throw PersistentControlClientError.connectionFailed
    }
    try ControlFrameCodec.configureConnectedSocket(descriptor: descriptor)
    try validateServer(descriptor: descriptor)
    let handshakeDeadline = try ControlTransportDeadline(
      timeoutMilliseconds: ControlPlaneContract.maximumAuthenticationHandshakeMilliseconds)
    let challenge = try ControlAuthenticationWireContract.decodeChallenge(
      ControlFrameCodec.read(
        kind: .frame,
        descriptor: descriptor,
        deadline: handshakeDeadline
      )
    )
    try validate(challenge: challenge, pinned: pinned)
    let proof = try credentialProofProvider(challenge)
    guard challenge.credentialProofRequired == (proof != nil) else {
      throw PersistentControlClientError.credentialRequired
    }
    try ControlFrameCodec.write(
      try ControlPlaneCanonicalJSON.encode(ControlAuthenticationResponse(credentialProof: proof)),
      kind: .request,
      descriptor: descriptor,
      deadline: handshakeDeadline
    )
    let requestDeadline = try ControlTransportDeadline(timeoutMilliseconds: timeout)
    try ControlFrameCodec.write(
      try ControlPlaneCanonicalJSON.encode(request),
      kind: .request,
      descriptor: descriptor,
      deadline: requestDeadline
    )
    let responseData = try ControlFrameCodec.read(
      kind: .response,
      descriptor: descriptor,
      deadline: requestDeadline
    )
    let response = try Phase09StrictDecoder.decode(
      ControlResponseEnvelope.self,
      from: responseData,
      allowedKeys: [
        "apiVersion", "protocolRevision", "requestID", "status", "reasonCode",
        "operationRef", "result", "error",
      ],
      requiredKeys: [
        "apiVersion", "protocolRevision", "requestID", "status", "reasonCode",
      ]
    )
    try response.validate()
    guard response.requestID == request.requestID else {
      throw PersistentControlClientError.invalidResponse
    }
    return response
  }

  public func connectSession() throws -> PersistentControlClientSession {
    let pinned = try pinSocket()
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw PersistentControlClientError.connectionFailed }
    do {
      try ControlFrameCodec.configureNoSigPipe(descriptor: descriptor)
      var address = try Self.address(socketPath)
      let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, Self.addressLength(socketPath))
        }
      }
      guard connected == 0, try pinSocket() == pinned else {
        throw PersistentControlClientError.connectionFailed
      }
      try ControlFrameCodec.configureConnectedSocket(descriptor: descriptor)
      try validateServer(descriptor: descriptor)
      let handshakeDeadline = try ControlTransportDeadline(
        timeoutMilliseconds: ControlPlaneContract.maximumAuthenticationHandshakeMilliseconds)
      let challenge = try ControlAuthenticationWireContract.decodeChallenge(
        ControlFrameCodec.read(
          kind: .frame,
          descriptor: descriptor,
          deadline: handshakeDeadline
        )
      )
      try validate(challenge: challenge, pinned: pinned)
      let proof = try credentialProofProvider(challenge)
      guard challenge.credentialProofRequired == (proof != nil) else {
        throw PersistentControlClientError.credentialRequired
      }
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(ControlAuthenticationResponse(credentialProof: proof)),
        kind: .request,
        descriptor: descriptor,
        deadline: handshakeDeadline
      )
      let session = PersistentControlClientSession(descriptor: descriptor)
      session.start()
      return session
    } catch {
      _ = Darwin.close(descriptor)
      throw error
    }
  }

  private func pinSocket() throws -> PinnedControlSocket {
    let url = URL(fileURLWithPath: socketPath)
    let parent = url.deletingLastPathComponent().path
    let reconstructed = URL(fileURLWithPath: parent, isDirectory: true)
      .appendingPathComponent(url.lastPathComponent).path
    guard socketPath.hasPrefix("/"), socketPath == reconstructed,
      let resolved = parent.withCString({ realpath($0, nil) })
    else { throw PersistentControlClientError.unsafeSocket }
    defer { free(resolved) }
    guard String(cString: resolved) == parent else {
      throw PersistentControlClientError.unsafeSocket
    }
    var root = stat()
    var status = stat()
    guard lstat(parent, &root) == 0,
      (root.st_mode & S_IFMT) == S_IFDIR,
      (root.st_mode & 0o7777) == 0o700,
      root.st_uid == geteuid(),
      lstat(socketPath, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFSOCK,
      (status.st_mode & 0o7777) == 0o600,
      status.st_uid == geteuid()
    else { throw PersistentControlClientError.unsafeSocket }
    return PinnedControlSocket(
      root: ControlSocketIdentity(device: UInt64(root.st_dev), inode: UInt64(root.st_ino)),
      socket: ControlSocketIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    )
  }

  private func validate(
    challenge: ControlPeerCredentialChallenge,
    pinned: PinnedControlSocket
  ) throws {
    let identity = try DarwinCurrentControlCodeIdentity.inspect()
    guard challenge.socketDevice == pinned.socket.device,
      challenge.socketInode == pinned.socket.inode,
      challenge.peerUID == UInt32(geteuid()),
      challenge.peerGID == UInt32(getegid()),
      challenge.peerPID == getpid(),
      challenge.codeDirectoryHash == identity.codeDirectoryHash
    else { throw PersistentControlClientError.serverBindingMismatch }
  }

  private func validateServer(descriptor: Int32) throws {
    do {
      let credentials = try DarwinControlPeerCredentialReader().read(descriptor: descriptor)
      guard credentials.peerUID == credentials.auditEffectiveUID,
        credentials.peerGID == credentials.auditEffectiveGID,
        credentials.peerPID == credentials.auditPID,
        credentials.peerUID == serverTrustPolicy.expectedUserID,
        credentials.auditPIDVersion > 0
      else {
        throw PersistentControlClientError.serverBindingMismatch
      }
      let identity = try DarwinControlPeerCodeValidator().identity(
        for: credentials.auditTokenData,
        peerPID: credentials.peerPID
      )
      guard serverTrustPolicy.accepts(identity) else {
        throw PersistentControlClientError.serverBindingMismatch
      }
    } catch let error as PersistentControlClientError {
      throw error
    } catch {
      throw PersistentControlClientError.serverBindingMismatch
    }
  }

  private static func address(_ path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    else { throw PersistentControlClientError.unsafeSocket }
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

private struct PinnedControlSocket: Equatable {
  let root: ControlSocketIdentity
  let socket: ControlSocketIdentity
}
