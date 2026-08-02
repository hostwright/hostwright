import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightState
import Security

enum ControlSecurityQualificationError: String, Error, Equatable {
  case invalidArguments
  case invalidAbsolutePath
  case unsafeSocketRoot
  case unsafeClientPath
  case socketCreationFailed
  case socketBindFailed
  case socketListenFailed
  case socketAcceptTimedOut
  case socketAcceptFailed
  case socketIdentityChanged
  case clientLaunchFailed
  case clientDidNotExit
  case clientConnectionFailed
  case unexpectedCodeIdentity
  case statePreparationFailed
  case identityStateFailed
  case authenticationFailed
  case authenticationHandshakeFailed
  case credentialFileFailed
  case sessionWasNotActive
  case revocationDidNotInvalidateSession
  case resultTooLarge
}

enum ControlSecurityQualificationCommand: Equatable {
  case client(socketPath: String, credentialFilePath: String?)
  case server(
    signedClientPath: String,
    adHocClientPath: String,
    stateDatabasePath: String,
    socketRootPath: String
  )

  static func parse(_ arguments: [String]) throws -> Self {
    guard let mode = arguments.first else {
      throw ControlSecurityQualificationError.invalidArguments
    }
    switch mode {
    case "client":
      guard arguments.count == 2 || arguments.count == 4 else {
        throw ControlSecurityQualificationError.invalidArguments
      }
      let socketPath = try absolutePath(arguments[1])
      if arguments.count == 2 {
        return .client(socketPath: socketPath, credentialFilePath: nil)
      }
      guard arguments[2] == "--credential-file" else {
        throw ControlSecurityQualificationError.invalidArguments
      }
      return .client(
        socketPath: socketPath,
        credentialFilePath: try absolutePath(arguments[3])
      )
    case "server":
      guard arguments.count == 9 else {
        throw ControlSecurityQualificationError.invalidArguments
      }
      var values: [String: String] = [:]
      var index = 1
      while index < arguments.count {
        let flag = arguments[index]
        guard ["--signed-client", "--adhoc-client", "--state-db", "--socket-root"].contains(flag),
          values[flag] == nil
        else {
          throw ControlSecurityQualificationError.invalidArguments
        }
        values[flag] = try absolutePath(arguments[index + 1])
        index += 2
      }
      guard let signed = values["--signed-client"], let adHoc = values["--adhoc-client"],
        let state = values["--state-db"], let root = values["--socket-root"]
      else {
        throw ControlSecurityQualificationError.invalidArguments
      }
      return .server(
        signedClientPath: signed,
        adHocClientPath: adHoc,
        stateDatabasePath: state,
        socketRootPath: root
      )
    default:
      throw ControlSecurityQualificationError.invalidArguments
    }
  }

  private static func absolutePath(_ value: String) throws -> String {
    guard value.hasPrefix("/"), !value.contains("\u{0000}") else {
      throw ControlSecurityQualificationError.invalidAbsolutePath
    }
    return value
  }
}

struct ControlSecurityQualificationModeResult: Codable, Equatable {
  let mode: String
  let subjectID: String
  let sessionID: String
  let nativeCDHashLength: Int
  let credentialProof: String
  let revocationStatus: String

  func validate() throws {
    guard mode == "signed" || mode == "adHoc",
      subjectID.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil,
      UUID(uuidString: sessionID) != nil,
      nativeCDHashLength == 20 || nativeCDHashLength == 32,
      (mode == "signed" && credentialProof == "verified")
        || (mode == "adHoc" && credentialProof == "not-required"),
      revocationStatus == "inactive"
    else {
      throw ControlSecurityQualificationError.invalidArguments
    }
  }
}

struct ControlSecurityQualificationResult: Codable, Equatable {
  let qualification: String
  let signed: ControlSecurityQualificationModeResult
  let adHoc: ControlSecurityQualificationModeResult

  init(
    signed: ControlSecurityQualificationModeResult,
    adHoc: ControlSecurityQualificationModeResult
  ) {
    qualification = "phase09-gate2-live-v1"
    self.signed = signed
    self.adHoc = adHoc
  }

  func canonicalJSON() throws -> Data {
    try signed.validate()
    try adHoc.validate()
    let data = try ControlPlaneCanonicalJSON.encode(self)
    guard data.count <= ControlPlaneContract.maximumResponseOrFrameBytes else {
      throw ControlSecurityQualificationError.resultTooLarge
    }
    return data
  }
}

enum ControlSecurityQualificationRunner {
  static let socketNamePrefix = "phase09-control-security-"
  private static let clientDeadline: TimeInterval = 10
  private static let daemonGeneration: UInt64 = 1

  static func run(_ command: ControlSecurityQualificationCommand) throws -> Data? {
    switch command {
    case .client(let socketPath, let credentialFilePath):
      try requireCanonicalExistingPath(socketPath)
      try connectClient(to: socketPath, credentialFilePath: credentialFilePath)
      return nil
    case .server(
      let signedClientPath, let adHocClientPath, let stateDatabasePath, let socketRootPath):
      let result = try runServer(
        signedClientPath: signedClientPath,
        adHocClientPath: adHocClientPath,
        stateDatabasePath: stateDatabasePath,
        socketRootPath: socketRootPath
      )
      return try result.canonicalJSON()
    }
  }

  private static func runServer(
    signedClientPath: String,
    adHocClientPath: String,
    stateDatabasePath: String,
    socketRootPath: String
  ) throws -> ControlSecurityQualificationResult {
    try validateSocketRoot(socketRootPath)
    try validateClientPath(signedClientPath)
    try validateClientPath(adHocClientPath)
    try validateStateDatabasePath(stateDatabasePath)

    let store = SQLiteStateStore(path: stateDatabasePath)
    do {
      try store.migrate()
      try store.validateSchema()
    } catch {
      throw ControlSecurityQualificationError.statePreparationFailed
    }
    let sessionAdapter = try SQLiteControlIdentitySecurityAdapter(
      store: store,
      sessionLifetime: 300
    )
    let listener = try QualificationSocketListener(rootPath: socketRootPath)
    defer { listener.closeAndRemoveOwnedSocket() }

    let signed = try qualify(
      mode: .signed,
      clientPath: signedClientPath,
      listener: listener,
      store: store,
      sessionAdapter: sessionAdapter,
      declaringSubjectID: nil
    )
    let adHoc = try qualify(
      mode: .adHoc,
      clientPath: adHocClientPath,
      listener: listener,
      store: store,
      sessionAdapter: sessionAdapter,
      declaringSubjectID: signed.subjectID
    )
    try signed.authenticator.validateSession(signed.binding, daemonGeneration: daemonGeneration)
    try revokeAndProveInactive(
      qualified: adHoc,
      actorSubjectID: signed.subjectID,
      store: store
    )
    try signed.authenticator.validateSession(signed.binding, daemonGeneration: daemonGeneration)
    try revokeAndProveInactive(
      qualified: signed,
      actorSubjectID: signed.subjectID,
      store: store
    )
    return ControlSecurityQualificationResult(signed: signed.result, adHoc: adHoc.result)
  }

  private enum QualificationMode: String {
    case signed
    case adHoc
  }

  private struct AuthenticatedQualificationMode {
    let result: ControlSecurityQualificationModeResult
    let binding: ControlSessionBinding
    let authenticator: ControlPeerAuthenticator

    var subjectID: String { result.subjectID }
  }

  private static func qualify(
    mode: QualificationMode,
    clientPath: String,
    listener: QualificationSocketListener,
    store: SQLiteStateStore,
    sessionAdapter: SQLiteControlIdentitySecurityAdapter,
    declaringSubjectID: String?
  ) throws -> AuthenticatedQualificationMode {
    let expectedIdentity = try NativeCodeIdentityInspector.identity(at: clientPath)
    let policy: ControlPeerTrustPolicy
    switch mode {
    case .signed:
      guard expectedIdentity.validationMode == .installedRequirement,
        expectedIdentity.teamIdentifier == ControlPeerTrustPolicy.installedTeamIdentifier,
        expectedIdentity.signingIdentifier == "hostwright-control"
      else {
        throw ControlSecurityQualificationError.unexpectedCodeIdentity
      }
      policy = try ControlPeerTrustPolicy(expectedUserID: UInt32(geteuid()))
    case .adHoc:
      guard expectedIdentity.validationMode == .pinnedAdHoc else {
        throw ControlSecurityQualificationError.unexpectedCodeIdentity
      }
      policy = try ControlPeerTrustPolicy(
        expectedUserID: UInt32(geteuid()),
        pinnedAdHocCodeDirectoryHashes: [expectedIdentity.codeDirectoryHash]
      )
    }
    let credentialFile: EphemeralCredentialFile?
    do {
      credentialFile =
        mode == .signed
        ? try EphemeralCredentialFile.create(
          runtimeRootPath: listener.rootPath,
          expectedRootIdentity: listener.rootIdentity
        )
        : nil
    } catch {
      throw ControlSecurityQualificationError.credentialFileFailed
    }
    defer { credentialFile?.removeOwnedFile() }

    let process = try launch(
      clientPath: clientPath,
      socketPath: listener.path,
      credentialFilePath: credentialFile?.path
    )
    var clientDescriptor: Int32 = -1
    defer {
      if clientDescriptor >= 0 {
        _ = Darwin.close(clientDescriptor)
      }
      try? waitForExit(process)
    }
    clientDescriptor = try listener.acceptOne(timeout: clientDeadline)

    let credentialReader = DarwinControlPeerCredentialReader()
    let codeValidator = DarwinControlPeerCodeValidator()
    let credentials = try credentialReader.read(descriptor: clientDescriptor)
    let acceptedIdentity = try codeValidator.identity(
      for: credentials.auditTokenData,
      peerPID: credentials.peerPID
    )
    guard acceptedIdentity == expectedIdentity else {
      throw ControlSecurityQualificationError.unexpectedCodeIdentity
    }
    let subjectID = subjectIdentifier(
      mode: mode, codeDirectoryHash: acceptedIdentity.codeDirectoryHash)
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let declaredIdentity = ControlPeerIdentityRecord(
      subjectID: subjectID,
      userID: UInt32(geteuid()),
      codeIdentity: acceptedIdentity,
      credentialID: credentialFile == nil ? nil : EphemeralCredentialFile.identifier,
      credentialPublicKeyBase64: credentialFile?.publicKey.x963Representation.base64EncodedString(),
      declaredBySubjectID: declaringSubjectID ?? subjectID,
      declaredAt: timestamp,
      updatedAt: timestamp
    )
    do {
      if declaringSubjectID != nil {
        try store.controlIdentities.declare(declaredIdentity)
      } else {
        try store.controlIdentities.bootstrap(declaredIdentity)
      }
    } catch {
      throw ControlSecurityQualificationError.identityStateFailed
    }

    let authenticator = ControlPeerAuthenticator(
      policy: policy,
      credentialReader: credentialReader,
      codeValidator: codeValidator,
      subjectResolver: sessionAdapter,
      sessionStore: sessionAdapter
    )
    let binding: ControlSessionBinding
    do {
      let prepared = try authenticator.prepareAuthentication(
        descriptor: clientDescriptor,
        daemonGeneration: daemonGeneration,
        serverNonce: serverNonce(),
        socketDevice: listener.identity.device,
        socketInode: listener.identity.inode
      )
      let deadline = AuthenticationFrameDeadline()
      let challenge = try ControlPlaneCanonicalJSON.encode(prepared.challenge)
      try AuthenticationFrameCodec.write(
        challenge,
        kind: .frame,
        descriptor: clientDescriptor,
        deadline: deadline
      )
      let responseData = try AuthenticationFrameCodec.read(
        kind: .request,
        descriptor: clientDescriptor,
        deadline: deadline
      )
      let response = try ControlAuthenticationWireContract.decodeResponse(
        responseData,
        for: prepared.challenge
      )
      binding = try authenticator.completeAuthentication(prepared, response: response).binding
    } catch {
      throw ControlSecurityQualificationError.authenticationFailed
    }
    try authenticator.validateSession(binding, daemonGeneration: daemonGeneration)
    guard
      try sessionAdapter.isActive(
        sessionID: binding.sessionID,
        daemonGeneration: daemonGeneration
      )
    else {
      throw ControlSecurityQualificationError.sessionWasNotActive
    }

    _ = Darwin.close(clientDescriptor)
    clientDescriptor = -1
    try waitForExit(process)
    return AuthenticatedQualificationMode(
      result: ControlSecurityQualificationModeResult(
        mode: mode.rawValue,
        subjectID: subjectID,
        sessionID: binding.sessionID,
        nativeCDHashLength: acceptedIdentity.codeDirectoryHash.count / 2,
        credentialProof: mode == .signed ? "verified" : "not-required",
        revocationStatus: "inactive"
      ),
      binding: binding,
      authenticator: authenticator
    )
  }

  private static func validateSocketRoot(_ path: String) throws {
    try requireCanonicalExistingPath(path)
    var status = stat()
    guard lstat(path, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFDIR,
      (status.st_mode & 0o7777) == 0o700,
      status.st_uid == geteuid()
    else {
      throw ControlSecurityQualificationError.unsafeSocketRoot
    }
  }

  private static func validateClientPath(_ path: String) throws {
    try requireCanonicalExistingPath(path)
    var status = stat()
    guard lstat(path, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_uid == geteuid() || status.st_uid == 0,
      (status.st_mode & 0o022) == 0,
      (status.st_mode & 0o111) != 0
    else {
      throw ControlSecurityQualificationError.unsafeClientPath
    }
  }

  private static func validateStateDatabasePath(_ path: String) throws {
    let fileURL = URL(fileURLWithPath: path)
    let parent = fileURL.deletingLastPathComponent().path
    let basename = fileURL.lastPathComponent
    let reconstructedPath = parent == "/" ? "/\(basename)" : "\(parent)/\(basename)"
    guard !parent.isEmpty,
      parent != path,
      path == reconstructedPath,
      basename == (path as NSString).lastPathComponent,
      basename != ".",
      basename != ".."
    else {
      throw ControlSecurityQualificationError.invalidAbsolutePath
    }
    try requireCanonicalExistingPath(parent)
    var parentStatus = stat()
    guard lstat(parent, &parentStatus) == 0,
      (parentStatus.st_mode & S_IFMT) == S_IFDIR,
      (parentStatus.st_mode & 0o7777) == 0o700,
      parentStatus.st_uid == geteuid()
    else {
      throw ControlSecurityQualificationError.unsafeSocketRoot
    }
    var databaseStatus = stat()
    if lstat(path, &databaseStatus) == 0 {
      guard (databaseStatus.st_mode & S_IFMT) == S_IFREG,
        (databaseStatus.st_mode & 0o7777) == 0o600,
        databaseStatus.st_uid == geteuid(),
        try canonicalExistingPath(path) == path
      else {
        throw ControlSecurityQualificationError.invalidAbsolutePath
      }
    } else if errno != ENOENT {
      throw ControlSecurityQualificationError.invalidAbsolutePath
    }
  }

  private static func revokeAndProveInactive(
    qualified: AuthenticatedQualificationMode,
    actorSubjectID: String,
    store: SQLiteStateStore
  ) throws {
    do {
      try store.controlIdentities.revoke(
        ControlIdentityRevocationRecord(
          revocationID:
            "phase09-gate2-revoke-\(qualified.result.mode)-\(UUID().uuidString.lowercased())",
          targetKind: .subject,
          targetIdentifier: qualified.subjectID,
          reason: "phase09 gate2 live revocation proof",
          actorSubjectID: actorSubjectID,
          revokedAt: ISO8601DateFormatter().string(from: Date())
        )
      )
    } catch {
      throw ControlSecurityQualificationError.identityStateFailed
    }
    do {
      try qualified.authenticator.validateSession(
        qualified.binding,
        daemonGeneration: daemonGeneration
      )
      throw ControlSecurityQualificationError.revocationDidNotInvalidateSession
    } catch ControlPeerAuthenticationError.sessionInactive, ControlPeerAuthenticationError
      .subjectRevoked
    {
      return
    }
  }

  private static func requireCanonicalExistingPath(_ path: String) throws {
    guard try canonicalExistingPath(path) == path else {
      throw ControlSecurityQualificationError.invalidAbsolutePath
    }
  }

  private static func canonicalExistingPath(_ path: String) throws -> String {
    let resolved = path.withCString { Darwin.realpath($0, nil) }
    guard let resolved else {
      throw ControlSecurityQualificationError.invalidAbsolutePath
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private static func launch(
    clientPath: String,
    socketPath: String,
    credentialFilePath: String?
  ) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: clientPath)
    var arguments = ["client", socketPath]
    if let credentialFilePath {
      arguments += ["--credential-file", credentialFilePath]
    }
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.environment = [:]
    do {
      try process.run()
      return process
    } catch {
      throw ControlSecurityQualificationError.clientLaunchFailed
    }
  }

  private static func waitForExit(_ process: Process) throws {
    let deadline = Date().addingTimeInterval(clientDeadline)
    while process.isRunning && Date() < deadline {
      usleep(10_000)
    }
    guard !process.isRunning, process.terminationStatus == 0 else {
      if process.isRunning {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
      throw ControlSecurityQualificationError.clientDidNotExit
    }
  }

  private static func connectClient(to socketPath: String, credentialFilePath: String?) throws {
    let pinnedSocket = try SocketIdentity.pinCurrentSocket(at: socketPath)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw ControlSecurityQualificationError.socketCreationFailed
    }
    defer { _ = Darwin.close(descriptor) }
    var address = try unixSocketAddress(socketPath)
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socketAddressLength(socketPath))
      }
    }
    guard connected == 0 else {
      throw ControlSecurityQualificationError.clientConnectionFailed
    }
    try configureNoSigPipe(descriptor)
    do {
      let deadline = AuthenticationFrameDeadline()
      let challengeData = try AuthenticationFrameCodec.read(
        kind: .frame,
        descriptor: descriptor,
        deadline: deadline
      )
      let challenge = try ControlAuthenticationWireContract.decodeChallenge(challengeData)
      let currentSocket = try SocketIdentity.pinCurrentSocket(at: socketPath)
      let clientIdentity = try NativeCodeIdentityInspector.identity(at: CommandLine.arguments[0])
      try ClientHandshakeBindingValidation.validate(
        challenge: challenge,
        pinnedSocket: pinnedSocket,
        currentSocket: currentSocket,
        clientIdentity: clientIdentity,
        effectiveUID: UInt32(geteuid()),
        effectiveGID: UInt32(getegid()),
        processID: getpid()
      )
      let proof: ControlPeerCredentialProof?
      if challenge.credentialProofRequired {
        guard let credentialFilePath else {
          throw ControlSecurityQualificationError.authenticationHandshakeFailed
        }
        let credential = try EphemeralCredentialFile.load(path: credentialFilePath)
        let signature = try credential.privateKey.signature(for: challenge.canonicalData())
        proof = ControlPeerCredentialProof(
          credentialID: credential.identifier,
          signatureDERBase64: signature.derRepresentation.base64EncodedString()
        )
      } else {
        guard credentialFilePath == nil else {
          throw ControlSecurityQualificationError.authenticationHandshakeFailed
        }
        proof = nil
      }
      let response = ControlAuthenticationResponse(credentialProof: proof)
      let responseData = try ControlPlaneCanonicalJSON.encode(response)
      try AuthenticationFrameCodec.write(
        responseData,
        kind: .request,
        descriptor: descriptor,
        deadline: deadline
      )
    } catch {
      throw ControlSecurityQualificationError.authenticationHandshakeFailed
    }
  }

  private static func subjectIdentifier(mode: QualificationMode, codeDirectoryHash: String)
    -> String
  {
    "phase09-gate2-\(mode.rawValue)-\(codeDirectoryHash.prefix(16))"
  }

  private static func serverNonce() -> String {
    Data(UUID().uuidString.utf8).base64EncodedString()
  }
}

enum ClientHandshakeBindingValidation {
  static func validate(
    challenge: ControlPeerCredentialChallenge,
    pinnedSocket: SocketIdentity,
    currentSocket: SocketIdentity,
    clientIdentity: CodeIdentity,
    effectiveUID: UInt32,
    effectiveGID: UInt32,
    processID: pid_t
  ) throws {
    let mode = clientIdentity.validationMode == .installedRequirement ? "signed" : "adHoc"
    let expectedSubject = "phase09-gate2-\(mode)-\(clientIdentity.codeDirectoryHash.prefix(16))"
    guard pinnedSocket == currentSocket,
      challenge.socketDevice == pinnedSocket.device,
      challenge.socketInode == pinnedSocket.inode,
      challenge.peerUID == effectiveUID,
      challenge.peerGID == effectiveGID,
      challenge.peerPID == processID,
      challenge.codeDirectoryHash == clientIdentity.codeDirectoryHash,
      challenge.subjectID == expectedSubject
    else {
      throw ControlSecurityQualificationError.authenticationHandshakeFailed
    }
  }
}

private func configureNoSigPipe(_ descriptor: Int32) throws {
  var enabled: Int32 = 1
  guard
    setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &enabled,
      socklen_t(MemoryLayout<Int32>.size)
    ) == 0
  else {
    throw ControlSecurityQualificationError.authenticationHandshakeFailed
  }
}

struct AuthenticationFrameDeadline {
  private let end: Date

  init(
    timeout: TimeInterval = TimeInterval(
      ControlPlaneContract.maximumAuthenticationHandshakeMilliseconds
    ) / 1_000
  ) {
    end = Date().addingTimeInterval(timeout)
  }

  func remainingMilliseconds() throws -> Int32 {
    let remaining = end.timeIntervalSinceNow
    guard remaining > 0 else {
      throw ControlSecurityQualificationError.authenticationHandshakeFailed
    }
    return Int32(
      min(
        Double(ControlPlaneContract.maximumAuthenticationHandshakeMilliseconds),
        max(1, ceil(remaining * 1_000))
      )
    )
  }
}

enum AuthenticationFrameCodec {
  static func validateDeclaredLength(_ length: UInt32, kind: ControlPayloadKind) throws {
    do {
      try ControlFramingContract.validateDeclaredLength(length, kind: kind)
    } catch {
      throw ControlSecurityQualificationError.authenticationHandshakeFailed
    }
  }

  static func write(
    _ data: Data,
    kind: ControlPayloadKind,
    descriptor: Int32,
    deadline: AuthenticationFrameDeadline
  ) throws {
    guard data.count <= Int(UInt32.max) else {
      throw ControlSecurityQualificationError.authenticationHandshakeFailed
    }
    try validateDeclaredLength(UInt32(data.count), kind: kind)
    var prefix = UInt32(data.count).bigEndian
    try withUnsafeBytes(of: &prefix) { bytes in
      try writeAll(bytes, descriptor: descriptor, deadline: deadline)
    }
    try data.withUnsafeBytes { bytes in
      try writeAll(bytes, descriptor: descriptor, deadline: deadline)
    }
  }

  static func read(
    kind: ControlPayloadKind,
    descriptor: Int32,
    deadline: AuthenticationFrameDeadline
  ) throws -> Data {
    let prefix = try readExactly(
      ControlFramingContract.lengthPrefixBytes,
      descriptor: descriptor,
      deadline: deadline
    )
    var networkLength: UInt32 = 0
    _ = withUnsafeMutableBytes(of: &networkLength) { destination in
      prefix.copyBytes(to: destination)
    }
    let length = UInt32(bigEndian: networkLength)
    try validateDeclaredLength(length, kind: kind)
    return try readExactly(Int(length), descriptor: descriptor, deadline: deadline)
  }

  private static func readExactly(
    _ length: Int,
    descriptor: Int32,
    deadline: AuthenticationFrameDeadline
  ) throws -> Data {
    var result = Data(count: length)
    var offset = 0
    try result.withUnsafeMutableBytes { destination in
      while offset < length {
        try waitForReadiness(descriptor, events: Int16(POLLIN), deadline: deadline)
        let count = Darwin.read(
          descriptor, destination.baseAddress!.advanced(by: offset), length - offset)
        guard count > 0 else {
          throw ControlSecurityQualificationError.authenticationHandshakeFailed
        }
        offset += count
      }
    }
    return result
  }

  private static func writeAll(
    _ bytes: UnsafeRawBufferPointer,
    descriptor: Int32,
    deadline: AuthenticationFrameDeadline
  ) throws {
    var offset = 0
    while offset < bytes.count {
      try waitForReadiness(descriptor, events: Int16(POLLOUT), deadline: deadline)
      let count = Darwin.write(
        descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      guard count > 0 else {
        throw ControlSecurityQualificationError.authenticationHandshakeFailed
      }
      offset += count
    }
  }

  static func writeRaw(_ bytes: UnsafeRawBufferPointer, descriptor: Int32) throws {
    var offset = 0
    while offset < bytes.count {
      let count = Darwin.write(
        descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      guard count > 0 else {
        throw ControlSecurityQualificationError.credentialFileFailed
      }
      offset += count
    }
  }

  static func readRaw(exactly length: Int, descriptor: Int32) throws -> Data {
    var result = Data(count: length)
    var offset = 0
    try result.withUnsafeMutableBytes { destination in
      while offset < length {
        let count = Darwin.read(
          descriptor, destination.baseAddress!.advanced(by: offset), length - offset)
        guard count > 0 else {
          throw ControlSecurityQualificationError.credentialFileFailed
        }
        offset += count
      }
    }
    return result
  }

  private static func waitForReadiness(
    _ descriptor: Int32,
    events: Int16,
    deadline: AuthenticationFrameDeadline
  ) throws {
    var entry = pollfd(fd: descriptor, events: events, revents: 0)
    let outcome = Darwin.poll(&entry, 1, try deadline.remainingMilliseconds())
    let failures = Int16(POLLERR | POLLHUP | POLLNVAL)
    guard outcome > 0, (entry.revents & failures) == 0,
      (entry.revents & events) != 0
    else {
      throw ControlSecurityQualificationError.authenticationHandshakeFailed
    }
  }
}

private struct QualificationFileIdentity: Equatable {
  let device: UInt64
  let inode: UInt64
}

private final class EphemeralCredentialFile {
  static let identifier = "phase09-gate2-client-credential"

  let path: String
  let publicKey: P256.Signing.PublicKey
  private let fileIdentity: QualificationFileIdentity
  private let directoryPath: String
  private let directoryIdentity: QualificationFileIdentity

  private init(
    path: String,
    publicKey: P256.Signing.PublicKey,
    fileIdentity: QualificationFileIdentity,
    directoryPath: String,
    directoryIdentity: QualificationFileIdentity
  ) {
    self.path = path
    self.publicKey = publicKey
    self.fileIdentity = fileIdentity
    self.directoryPath = directoryPath
    self.directoryIdentity = directoryIdentity
  }

  static func create(
    runtimeRootPath: String,
    expectedRootIdentity: SocketIdentity
  ) throws -> EphemeralCredentialFile {
    var rootStatus = stat()
    guard lstat(runtimeRootPath, &rootStatus) == 0,
      (rootStatus.st_mode & S_IFMT) == S_IFDIR,
      (rootStatus.st_mode & 0o7777) == 0o700,
      rootStatus.st_uid == geteuid(),
      SocketIdentity(device: UInt64(rootStatus.st_dev), inode: UInt64(rootStatus.st_ino))
        == expectedRootIdentity
    else {
      throw ControlSecurityQualificationError.credentialFileFailed
    }
    let directoryPath = URL(fileURLWithPath: runtimeRootPath, isDirectory: true)
      .appendingPathComponent("phase09-control-security-runtime-\(UUID().uuidString.lowercased())")
      .path
    guard URL(fileURLWithPath: directoryPath).deletingLastPathComponent().path == runtimeRootPath
    else {
      throw ControlSecurityQualificationError.credentialFileFailed
    }
    guard mkdir(directoryPath, 0o700) == 0 else {
      throw ControlSecurityQualificationError.credentialFileFailed
    }
    var directoryStatus = stat()
    guard lstat(directoryPath, &directoryStatus) == 0,
      (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
      (directoryStatus.st_mode & 0o7777) == 0o700,
      directoryStatus.st_uid == geteuid()
    else {
      _ = rmdir(directoryPath)
      throw ControlSecurityQualificationError.credentialFileFailed
    }
    let directoryIdentity = QualificationFileIdentity(
      device: UInt64(directoryStatus.st_dev), inode: UInt64(directoryStatus.st_ino)
    )
    let filePath = URL(fileURLWithPath: directoryPath, isDirectory: true)
      .appendingPathComponent("credential.p256")
      .path
    let privateKey = P256.Signing.PrivateKey()
    var createdFileIdentity: QualificationFileIdentity?
    do {
      let descriptor = open(filePath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else {
        throw ControlSecurityQualificationError.credentialFileFailed
      }
      defer { _ = Darwin.close(descriptor) }
      var createdStatus = stat()
      guard fstat(descriptor, &createdStatus) == 0,
        (createdStatus.st_mode & S_IFMT) == S_IFREG,
        (createdStatus.st_mode & 0o7777) == 0o600,
        createdStatus.st_uid == geteuid()
      else {
        throw ControlSecurityQualificationError.credentialFileFailed
      }
      createdFileIdentity = QualificationFileIdentity(
        device: UInt64(createdStatus.st_dev), inode: UInt64(createdStatus.st_ino)
      )
      let material = privateKey.rawRepresentation
      try material.withUnsafeBytes { bytes in
        try AuthenticationFrameCodec.writeRaw(bytes, descriptor: descriptor)
      }
      guard fsync(descriptor) == 0 else {
        throw ControlSecurityQualificationError.credentialFileFailed
      }
      var fileStatus = stat()
      guard fstat(descriptor, &fileStatus) == 0,
        (fileStatus.st_mode & S_IFMT) == S_IFREG,
        (fileStatus.st_mode & 0o7777) == 0o600,
        fileStatus.st_uid == geteuid(),
        fileStatus.st_size == 32
      else {
        throw ControlSecurityQualificationError.credentialFileFailed
      }
      return EphemeralCredentialFile(
        path: filePath,
        publicKey: privateKey.publicKey,
        fileIdentity: QualificationFileIdentity(
          device: UInt64(fileStatus.st_dev), inode: UInt64(fileStatus.st_ino)
        ),
        directoryPath: directoryPath,
        directoryIdentity: directoryIdentity
      )
    } catch {
      var status = stat()
      if let createdFileIdentity,
        lstat(filePath, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        QualificationFileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
          == createdFileIdentity
      {
        _ = unlink(filePath)
      }
      _ = rmdir(directoryPath)
      throw error
    }
  }

  static func load(path: String) throws -> LoadedCredential {
    guard try canonicalPath(path) == path else {
      throw ControlSecurityQualificationError.credentialFileFailed
    }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    var parentStatus = stat()
    guard lstat(parent, &parentStatus) == 0,
      (parentStatus.st_mode & S_IFMT) == S_IFDIR,
      (parentStatus.st_mode & 0o7777) == 0o700,
      parentStatus.st_uid == geteuid()
    else {
      throw ControlSecurityQualificationError.credentialFileFailed
    }
    var expectedStatus = stat()
    guard lstat(path, &expectedStatus) == 0,
      (expectedStatus.st_mode & S_IFMT) == S_IFREG,
      (expectedStatus.st_mode & 0o7777) == 0o600,
      expectedStatus.st_uid == geteuid(),
      expectedStatus.st_size == 32
    else {
      throw ControlSecurityQualificationError.credentialFileFailed
    }
    let expectedIdentity = QualificationFileIdentity(
      device: UInt64(expectedStatus.st_dev), inode: UInt64(expectedStatus.st_ino)
    )
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw ControlSecurityQualificationError.credentialFileFailed
    }
    defer { _ = Darwin.close(descriptor) }
    var openedStatus = stat()
    guard fstat(descriptor, &openedStatus) == 0,
      QualificationFileIdentity(
        device: UInt64(openedStatus.st_dev), inode: UInt64(openedStatus.st_ino))
        == expectedIdentity
    else {
      throw ControlSecurityQualificationError.credentialFileFailed
    }
    let material = try AuthenticationFrameCodec.readRaw(exactly: 32, descriptor: descriptor)
    let privateKey: P256.Signing.PrivateKey
    do {
      privateKey = try P256.Signing.PrivateKey(rawRepresentation: material)
    } catch {
      throw ControlSecurityQualificationError.credentialFileFailed
    }
    return LoadedCredential(identifier: identifier, privateKey: privateKey)
  }

  func removeOwnedFile() {
    var fileStatus = stat()
    guard lstat(path, &fileStatus) == 0,
      (fileStatus.st_mode & S_IFMT) == S_IFREG,
      QualificationFileIdentity(device: UInt64(fileStatus.st_dev), inode: UInt64(fileStatus.st_ino))
        == fileIdentity
    else {
      return
    }
    guard unlink(path) == 0 else { return }
    var directoryStatus = stat()
    guard lstat(directoryPath, &directoryStatus) == 0,
      (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
      QualificationFileIdentity(
        device: UInt64(directoryStatus.st_dev), inode: UInt64(directoryStatus.st_ino)
      ) == directoryIdentity
    else {
      return
    }
    _ = rmdir(directoryPath)
  }

  struct LoadedCredential {
    let identifier: String
    let privateKey: P256.Signing.PrivateKey
  }

  private static func canonicalPath(_ path: String) throws -> String {
    let resolved = path.withCString { Darwin.realpath($0, nil) }
    guard let resolved else {
      throw ControlSecurityQualificationError.credentialFileFailed
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

struct SocketIdentity: Equatable {
  let device: UInt64
  let inode: UInt64

  static func pinCurrentSocket(at path: String) throws -> SocketIdentity {
    var status = stat()
    guard lstat(path, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFSOCK,
      (status.st_mode & 0o7777) == 0o600,
      status.st_uid == geteuid()
    else {
      throw ControlSecurityQualificationError.authenticationHandshakeFailed
    }
    return SocketIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
  }
}

private final class QualificationSocketListener {
  let descriptor: Int32
  let path: String
  let identity: SocketIdentity
  let rootPath: String
  let rootIdentity: SocketIdentity
  private var closed = false

  init(rootPath: String) throws {
    let name = ControlSecurityQualificationRunner.socketNamePrefix + UUID().uuidString.lowercased()
    let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
    var rootStatus = stat()
    guard lstat(rootPath, &rootStatus) == 0,
      (rootStatus.st_mode & S_IFMT) == S_IFDIR,
      (rootStatus.st_mode & 0o7777) == 0o700,
      rootStatus.st_uid == geteuid()
    else {
      throw ControlSecurityQualificationError.unsafeSocketRoot
    }
    let capturedRootIdentity = SocketIdentity(
      device: UInt64(rootStatus.st_dev), inode: UInt64(rootStatus.st_ino)
    )
    let socketPath = rootURL.appendingPathComponent(name).path
    guard URL(fileURLWithPath: socketPath).deletingLastPathComponent().path == rootURL.path else {
      throw ControlSecurityQualificationError.unsafeSocketRoot
    }
    let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else {
      throw ControlSecurityQualificationError.socketCreationFailed
    }
    var createdIdentity: SocketIdentity?
    do {
      var address = try unixSocketAddress(socketPath)
      let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(socketDescriptor, $0, socketAddressLength(socketPath))
        }
      }
      guard bound == 0 else {
        throw ControlSecurityQualificationError.socketBindFailed
      }
      guard chmod(socketPath, 0o600) == 0 else {
        throw ControlSecurityQualificationError.socketBindFailed
      }
      var status = stat()
      guard lstat(socketPath, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFSOCK,
        (status.st_mode & 0o7777) == 0o600,
        status.st_uid == geteuid()
      else {
        throw ControlSecurityQualificationError.socketIdentityChanged
      }
      let socketIdentity = SocketIdentity(
        device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
      createdIdentity = socketIdentity
      guard Darwin.listen(socketDescriptor, 1) == 0 else {
        throw ControlSecurityQualificationError.socketListenFailed
      }
      descriptor = socketDescriptor
      path = socketPath
      identity = socketIdentity
      self.rootPath = rootPath
      rootIdentity = capturedRootIdentity
    } catch {
      _ = Darwin.close(socketDescriptor)
      var status = stat()
      if let createdIdentity,
        lstat(socketPath, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFSOCK,
        SocketIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
          == createdIdentity
      {
        _ = unlink(socketPath)
      }
      throw error
    }
  }

  deinit {
    closeAndRemoveOwnedSocket()
  }

  func acceptOne(timeout: TimeInterval) throws -> Int32 {
    var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    let milliseconds = Int32(timeout * 1_000)
    let outcome = Darwin.poll(&entry, 1, milliseconds)
    guard outcome > 0 else {
      throw outcome == 0
        ? ControlSecurityQualificationError.socketAcceptTimedOut
        : ControlSecurityQualificationError.socketAcceptFailed
    }
    let accepted = Darwin.accept(descriptor, nil, nil)
    guard accepted >= 0 else {
      throw ControlSecurityQualificationError.socketAcceptFailed
    }
    try configureNoSigPipe(accepted)
    return accepted
  }

  func closeAndRemoveOwnedSocket() {
    guard !closed else { return }
    closed = true
    _ = Darwin.close(descriptor)
    var status = stat()
    guard lstat(path, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFSOCK,
      SocketIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino)) == identity
    else {
      return
    }
    _ = unlink(path)
  }
}

private enum NativeCodeIdentityInspector {
  private static let revocationFlag = UInt32(1) << 30

  static func identity(at path: String) throws -> CodeIdentity {
    var code: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
      let code
    else {
      throw ControlSecurityQualificationError.unexpectedCodeIdentity
    }
    guard
      SecStaticCodeCheckValidity(
        code,
        SecCSFlags(rawValue: kSecCSStrictValidate | revocationFlag),
        nil
      ) == errSecSuccess
    else {
      throw ControlSecurityQualificationError.unexpectedCodeIdentity
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let values = information as? [String: Any],
      let identifier = values[kSecCodeInfoIdentifier as String] as? String,
      let hashData = values[kSecCodeInfoUnique as String] as? Data
    else {
      throw ControlSecurityQualificationError.unexpectedCodeIdentity
    }
    let hash = hashData.map { String(format: "%02x", $0) }.joined()
    let team = values[kSecCodeInfoTeamIdentifier as String] as? String
    let identity = CodeIdentity(
      teamIdentifier: team,
      signingIdentifier: identifier,
      codeDirectoryHash: hash,
      validationMode: team == nil ? .pinnedAdHoc : .installedRequirement
    )
    do {
      try identity.validate()
    } catch {
      throw ControlSecurityQualificationError.unexpectedCodeIdentity
    }
    return identity
  }
}

private func unixSocketAddress(_ path: String) throws -> sockaddr_un {
  let bytes = Array(path.utf8)
  guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
    throw ControlSecurityQualificationError.invalidAbsolutePath
  }
  var address = sockaddr_un()
  address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) { destination in
    destination.initializeMemory(as: UInt8.self, repeating: 0)
    destination.copyBytes(from: bytes)
  }
  return address
}

private func socketAddressLength(_ path: String) -> socklen_t {
  socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
}
