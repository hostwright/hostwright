import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import Security

public enum ControlPeerAuthenticationError: Error, Equatable, Sendable {
  case invalidPolicy
  case invalidDescriptor
  case peerCredentialsUnavailable
  case peerTokenUnavailable
  case malformedPeerToken
  case peerUIDMismatch
  case peerGIDMismatch
  case peerPIDMismatch
  case peerPIDVersionInvalid
  case peerAuditSessionInvalid
  case expectedUserMismatch
  case codeTaskUnavailable
  case codeUnavailable
  case staticCodeUnavailable
  case signingInformationUnavailable
  case codeIdentityMalformed
  case codeRequirementRejected
  case installedTeamRejected
  case installedIdentifierRejected
  case adHocTeamRejected
  case adHocHashRejected
  case subjectNotDeclared
  case subjectIdentityMismatch
  case subjectRevoked
  case credentialProofRequired
  case credentialProofUnexpected
  case credentialIDMismatch
  case credentialMaterialInvalid
  case credentialProofMalformed
  case credentialProofRejected
  case invalidServerNonce
  case invalidSocketBinding
  case authenticationAttemptConsumed
  case authenticationAttemptMismatch
  case sessionPersistenceFailed
  case sessionInactive
  case daemonGenerationChanged
}

public struct ControlPeerTrustPolicy: Sendable, Equatable {
  public static let installedTeamIdentifier = "993YC3JY4Q"
  public static let defaultInstalledIdentifiers: Set<String> = [
    "dev.hostwright.cli", "hostwright", "hostwright-control", "hostwrightd",
  ]

  public let expectedUserID: UInt32
  public let installedTeamIdentifier: String
  public let installedIdentifiers: Set<String>
  public let pinnedAdHocCodeDirectoryHashes: Set<String>

  public init(
    expectedUserID: UInt32,
    installedTeamIdentifier: String = Self.installedTeamIdentifier,
    installedIdentifiers: Set<String> = Self.defaultInstalledIdentifiers,
    pinnedAdHocCodeDirectoryHashes: Set<String> = []
  ) throws {
    self.expectedUserID = expectedUserID
    self.installedTeamIdentifier = installedTeamIdentifier
    self.installedIdentifiers = installedIdentifiers
    self.pinnedAdHocCodeDirectoryHashes = pinnedAdHocCodeDirectoryHashes
    try validate()
  }

  public func validate() throws {
    let installedIdentifiersValid = installedIdentifiers.allSatisfy {
      ControlPeerInputValidation.isSafeIdentifier($0, maximumLength: 128)
    }
    guard installedTeamIdentifier == Self.installedTeamIdentifier,
      installedIdentifiers == Self.defaultInstalledIdentifiers,
      ControlPeerInputValidation.isSafeIdentifier(installedTeamIdentifier, maximumLength: 32),
      installedIdentifiersValid,
      pinnedAdHocCodeDirectoryHashes.allSatisfy(ControlPeerInputValidation.isCodeDirectoryHash)
    else {
      throw ControlPeerAuthenticationError.invalidPolicy
    }
  }

  func validate(identity: CodeIdentity) throws {
    guard ControlPeerInputValidation.isCodeDirectoryHash(identity.codeDirectoryHash),
      ControlPeerInputValidation.isSafeIdentifier(identity.signingIdentifier, maximumLength: 128)
    else {
      throw ControlPeerAuthenticationError.codeIdentityMalformed
    }
    switch identity.validationMode {
    case .installedRequirement:
      guard identity.teamIdentifier == installedTeamIdentifier else {
        throw ControlPeerAuthenticationError.installedTeamRejected
      }
      guard installedIdentifiers.contains(identity.signingIdentifier) else {
        throw ControlPeerAuthenticationError.installedIdentifierRejected
      }
    case .pinnedAdHoc:
      guard identity.teamIdentifier == nil else {
        throw ControlPeerAuthenticationError.adHocTeamRejected
      }
      guard !pinnedAdHocCodeDirectoryHashes.isEmpty,
        pinnedAdHocCodeDirectoryHashes.contains(identity.codeDirectoryHash)
      else {
        throw ControlPeerAuthenticationError.adHocHashRejected
      }
    }
  }
}

public struct RawControlPeerCredentials: Sendable, Equatable {
  public let peerUID: UInt32
  public let peerGID: UInt32
  public let peerPID: pid_t
  public let auditEffectiveUID: UInt32
  public let auditEffectiveGID: UInt32
  public let auditPID: pid_t
  public let auditPIDVersion: UInt32
  public let auditSessionID: UInt32
  public let auditTokenData: Data

  public init(
    peerUID: UInt32,
    peerGID: UInt32,
    peerPID: pid_t,
    auditEffectiveUID: UInt32,
    auditEffectiveGID: UInt32,
    auditPID: pid_t,
    auditPIDVersion: UInt32,
    auditSessionID: UInt32,
    auditTokenData: Data
  ) {
    self.peerUID = peerUID
    self.peerGID = peerGID
    self.peerPID = peerPID
    self.auditEffectiveUID = auditEffectiveUID
    self.auditEffectiveGID = auditEffectiveGID
    self.auditPID = auditPID
    self.auditPIDVersion = auditPIDVersion
    self.auditSessionID = auditSessionID
    self.auditTokenData = auditTokenData
  }
}

public protocol ControlPeerCredentialReading: Sendable {
  func read(descriptor: Int32) throws -> RawControlPeerCredentials
}

public struct DarwinControlPeerCredentialReader: ControlPeerCredentialReading, Sendable {
  public init() {}

  public func read(descriptor: Int32) throws -> RawControlPeerCredentials {
    guard descriptor >= 0 else {
      throw ControlPeerAuthenticationError.invalidDescriptor
    }

    var peerUID = uid_t.max
    var peerGID = gid_t.max
    guard getpeereid(descriptor, &peerUID, &peerGID) == 0 else {
      throw ControlPeerAuthenticationError.peerCredentialsUnavailable
    }

    var peerPID = pid_t(0)
    var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
    guard
      getsockopt(
        descriptor, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDSize
      ) == 0, peerPIDSize == MemoryLayout<pid_t>.size, peerPID > 0
    else {
      throw ControlPeerAuthenticationError.peerCredentialsUnavailable
    }

    var auditToken = audit_token_t()
    var auditTokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
    guard
      getsockopt(
        descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &auditToken, &auditTokenSize
      ) == 0, auditTokenSize == MemoryLayout<audit_token_t>.size
    else {
      throw ControlPeerAuthenticationError.peerTokenUnavailable
    }

    let tokenData = withUnsafeBytes(of: auditToken) { Data($0) }
    guard tokenData.count == MemoryLayout<audit_token_t>.size else {
      throw ControlPeerAuthenticationError.malformedPeerToken
    }

    return RawControlPeerCredentials(
      peerUID: UInt32(peerUID), peerGID: UInt32(peerGID), peerPID: peerPID,
      auditEffectiveUID: UInt32(audit_token_to_euid(auditToken)),
      auditEffectiveGID: UInt32(audit_token_to_egid(auditToken)),
      auditPID: audit_token_to_pid(auditToken),
      auditPIDVersion: UInt32(audit_token_to_pidversion(auditToken)),
      auditSessionID: UInt32(audit_token_to_asid(auditToken)), auditTokenData: tokenData
    )
  }
}

public protocol ControlPeerCodeValidating: Sendable {
  func identity(for auditTokenData: Data, peerPID: pid_t) throws -> CodeIdentity
}

public struct DarwinControlPeerCodeValidator: ControlPeerCodeValidating, Sendable {
  private static let revocationFlag = UInt32(1) << 30

  public init() {}

  public func identity(for auditTokenData: Data, peerPID: pid_t) throws -> CodeIdentity {
    let auditToken = try Self.auditToken(from: auditTokenData)
    guard SecTaskCreateWithAuditToken(nil, auditToken) != nil else {
      throw ControlPeerAuthenticationError.codeTaskUnavailable
    }

    let attributes =
      [
        kSecGuestAttributeAudit as String: auditTokenData as CFData,
        kSecGuestAttributePid as String: NSNumber(value: peerPID),
      ] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
      let code
    else {
      throw ControlPeerAuthenticationError.codeUnavailable
    }

    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      throw ControlPeerAuthenticationError.staticCodeUnavailable
    }

    var signingInformation: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation
      ) == errSecSuccess,
      let information = signingInformation as? [String: Any],
      let identifier = information[kSecCodeInfoIdentifier as String] as? String,
      let cdHashData = information[kSecCodeInfoUnique as String] as? Data
    else {
      throw ControlPeerAuthenticationError.signingInformationUnavailable
    }

    let cdHash = cdHashData.map { String(format: "%02x", $0) }.joined()
    let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String
    guard ControlPeerInputValidation.isCodeDirectoryHash(cdHash),
      ControlPeerInputValidation.isSafeIdentifier(identifier, maximumLength: 128),
      teamIdentifier == nil
        || teamIdentifier?.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
    else {
      throw ControlPeerAuthenticationError.codeIdentityMalformed
    }
    let mode: CodeValidationMode = teamIdentifier == nil ? .pinnedAdHoc : .installedRequirement

    if mode == .installedRequirement {
      guard let teamIdentifier else {
        throw ControlPeerAuthenticationError.codeIdentityMalformed
      }
      let requirement = try Self.requirement(identifier: identifier, teamIdentifier: teamIdentifier)
      guard
        SecCodeCheckValidity(
          code,
          SecCSFlags(rawValue: kSecCSStrictValidate | Self.revocationFlag),
          requirement
        ) == errSecSuccess
      else {
        throw ControlPeerAuthenticationError.codeRequirementRejected
      }
    } else {
      guard
        SecCodeCheckValidity(
          code,
          SecCSFlags(rawValue: kSecCSStrictValidate | Self.revocationFlag), nil
        ) == errSecSuccess
      else {
        throw ControlPeerAuthenticationError.codeRequirementRejected
      }
    }

    return CodeIdentity(
      teamIdentifier: teamIdentifier, signingIdentifier: identifier, codeDirectoryHash: cdHash,
      validationMode: mode
    )
  }

  private static func requirement(identifier: String, teamIdentifier: String) throws
    -> SecRequirement
  {
    let source =
      "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else {
      throw ControlPeerAuthenticationError.codeRequirementRejected
    }
    return requirement
  }

  private static func auditToken(from data: Data) throws -> audit_token_t {
    guard data.count == MemoryLayout<audit_token_t>.size else {
      throw ControlPeerAuthenticationError.malformedPeerToken
    }
    var token = audit_token_t()
    _ = withUnsafeMutableBytes(of: &token) { destination in
      data.copyBytes(to: destination)
    }
    return token
  }
}

public enum DarwinCurrentControlCodeIdentity {
  private static let revocationFlag = UInt32(1) << 30

  public static func inspect() throws -> CodeIdentity {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
      throw ControlPeerAuthenticationError.codeUnavailable
    }
    guard
      SecCodeCheckValidity(
        code,
        SecCSFlags(rawValue: kSecCSStrictValidate | revocationFlag),
        nil
      ) == errSecSuccess
    else {
      throw ControlPeerAuthenticationError.codeRequirementRejected
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      throw ControlPeerAuthenticationError.staticCodeUnavailable
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let values = information as? [String: Any],
      let identifier = values[kSecCodeInfoIdentifier as String] as? String,
      let cdHashData = values[kSecCodeInfoUnique as String] as? Data
    else {
      throw ControlPeerAuthenticationError.signingInformationUnavailable
    }
    let hash = cdHashData.map { String(format: "%02x", $0) }.joined()
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
      throw ControlPeerAuthenticationError.codeIdentityMalformed
    }
    return identity
  }
}

public struct DeclaredControlCredential: Sendable, Equatable {
  public let identifier: String
  public let p256X963PublicKey: Data

  public init(identifier: String, p256X963PublicKey: Data) {
    self.identifier = identifier
    self.p256X963PublicKey = p256X963PublicKey
  }
}

public struct DeclaredControlSubject: Sendable, Equatable {
  public let localSubject: LocalSubject
  public let credential: DeclaredControlCredential?
  public let isRevoked: Bool

  public init(localSubject: LocalSubject, credential: DeclaredControlCredential?, isRevoked: Bool) {
    self.localSubject = localSubject
    self.credential = credential
    self.isRevoked = isRevoked
  }
}

public protocol DeclaredControlSubjectResolving: Sendable {
  func resolve(userID: UInt32, codeIdentity: CodeIdentity) throws -> DeclaredControlSubject
}

public protocol ControlSessionBindingStoring: Sendable {
  func persist(_ binding: ControlSessionBinding) throws
  func isActive(sessionID: String, daemonGeneration: UInt64) throws -> Bool
}

public struct AuthenticatedControlPeer: Sendable, Equatable {
  public let binding: ControlSessionBinding

  public init(binding: ControlSessionBinding) {
    self.binding = binding
  }
}

public final class PreparedControlPeerAuthentication: @unchecked Sendable {
  public let challenge: ControlPeerCredentialChallenge
  fileprivate let declaredSubject: DeclaredControlSubject
  fileprivate let peer: UnixPeerIdentity
  fileprivate let authenticatorID: UUID
  private let lock = NSLock()
  private var consumed = false

  fileprivate init(
    challenge: ControlPeerCredentialChallenge,
    declaredSubject: DeclaredControlSubject,
    peer: UnixPeerIdentity,
    authenticatorID: UUID
  ) {
    self.challenge = challenge
    self.declaredSubject = declaredSubject
    self.peer = peer
    self.authenticatorID = authenticatorID
  }

  fileprivate func consume(by owner: UUID) throws {
    lock.lock()
    defer { lock.unlock() }
    guard owner == authenticatorID else {
      throw ControlPeerAuthenticationError.authenticationAttemptMismatch
    }
    guard !consumed else {
      throw ControlPeerAuthenticationError.authenticationAttemptConsumed
    }
    consumed = true
  }
}

public final class ControlPeerAuthenticator: @unchecked Sendable {
  public let policy: ControlPeerTrustPolicy
  public let credentialReader: any ControlPeerCredentialReading
  private let codeValidator: any ControlPeerCodeValidating
  private let subjectResolver: any DeclaredControlSubjectResolving
  private let sessionStore: any ControlSessionBindingStoring
  private let authenticatorID = UUID()

  public init(
    policy: ControlPeerTrustPolicy,
    credentialReader: any ControlPeerCredentialReading = DarwinControlPeerCredentialReader(),
    codeValidator: any ControlPeerCodeValidating = DarwinControlPeerCodeValidator(),
    subjectResolver: any DeclaredControlSubjectResolving,
    sessionStore: any ControlSessionBindingStoring
  ) {
    self.policy = policy
    self.credentialReader = credentialReader
    self.codeValidator = codeValidator
    self.subjectResolver = subjectResolver
    self.sessionStore = sessionStore
  }

  public func authenticate(
    descriptor: Int32,
    daemonGeneration: UInt64,
    serverNonce: String,
    socketDevice: UInt64,
    socketInode: UInt64,
    credentialProof: ControlPeerCredentialProof?
  ) throws -> AuthenticatedControlPeer {
    let prepared = try prepareAuthentication(
      descriptor: descriptor,
      daemonGeneration: daemonGeneration,
      serverNonce: serverNonce,
      socketDevice: socketDevice,
      socketInode: socketInode
    )
    return try completeAuthentication(prepared, credentialProof: credentialProof)
  }

  public func prepareAuthentication(
    descriptor: Int32,
    daemonGeneration: UInt64,
    serverNonce: String,
    socketDevice: UInt64,
    socketInode: UInt64
  ) throws -> PreparedControlPeerAuthentication {
    try policy.validate()
    try validateBindingInputs(
      daemonGeneration: daemonGeneration, serverNonce: serverNonce, socketDevice: socketDevice,
      socketInode: socketInode
    )
    let credentials = try credentialReader.read(descriptor: descriptor)
    try validate(credentials: credentials)
    let codeIdentity = try codeValidator.identity(
      for: credentials.auditTokenData, peerPID: credentials.peerPID
    )
    try policy.validate(identity: codeIdentity)
    let peer = try peerIdentity(from: credentials, identity: codeIdentity)
    let declaredSubject = try subjectResolver.resolve(
      userID: peer.effectiveUID, codeIdentity: codeIdentity
    )
    try validate(declaredSubject: declaredSubject, peer: peer)
    let challenge = ControlPeerCredentialChallenge(
      subjectID: declaredSubject.localSubject.identifier,
      serverNonce: serverNonce,
      daemonGeneration: daemonGeneration,
      socketDevice: socketDevice,
      socketInode: socketInode,
      peer: peer,
      credentialProofRequired: declaredSubject.credential != nil
    )
    try challenge.validate()
    return PreparedControlPeerAuthentication(
      challenge: challenge,
      declaredSubject: declaredSubject,
      peer: peer,
      authenticatorID: authenticatorID
    )
  }

  public func completeAuthentication(
    _ prepared: PreparedControlPeerAuthentication,
    response: ControlAuthenticationResponse
  ) throws -> AuthenticatedControlPeer {
    try prepared.consume(by: authenticatorID)
    try response.validate(for: prepared.challenge)
    return try persistAuthentication(prepared, credentialProof: response.credentialProof)
  }

  public func completeAuthentication(
    _ prepared: PreparedControlPeerAuthentication,
    credentialProof: ControlPeerCredentialProof?
  ) throws -> AuthenticatedControlPeer {
    try prepared.consume(by: authenticatorID)
    return try persistAuthentication(prepared, credentialProof: credentialProof)
  }

  private func persistAuthentication(
    _ prepared: PreparedControlPeerAuthentication,
    credentialProof: ControlPeerCredentialProof?
  ) throws -> AuthenticatedControlPeer {
    let challenge = prepared.challenge
    try validateCredential(
      credentialProof,
      declaredSubject: prepared.declaredSubject,
      peer: prepared.peer,
      serverNonce: challenge.serverNonce,
      daemonGeneration: challenge.daemonGeneration,
      socketDevice: challenge.socketDevice,
      socketInode: challenge.socketInode
    )
    let binding = ControlSessionBinding(
      sessionID: UUID().uuidString.lowercased(), daemonGeneration: challenge.daemonGeneration,
      serverNonce: challenge.serverNonce,
      socketDevice: challenge.socketDevice, socketInode: challenge.socketInode,
      peer: prepared.peer,
      subject: prepared.declaredSubject.localSubject
    )
    do {
      try sessionStore.persist(binding)
    } catch {
      throw ControlPeerAuthenticationError.sessionPersistenceFailed
    }
    return AuthenticatedControlPeer(binding: binding)
  }

  public func validateSession(
    _ binding: ControlSessionBinding, daemonGeneration: UInt64
  ) throws {
    guard binding.daemonGeneration == daemonGeneration else {
      throw ControlPeerAuthenticationError.daemonGenerationChanged
    }
    guard
      try sessionStore.isActive(
        sessionID: binding.sessionID, daemonGeneration: daemonGeneration
      )
    else {
      throw ControlPeerAuthenticationError.sessionInactive
    }
    let declaredSubject = try subjectResolver.resolve(
      userID: binding.peer.effectiveUID, codeIdentity: binding.peer.codeIdentity
    )
    try validate(declaredSubject: declaredSubject, peer: binding.peer)
    guard declaredSubject.localSubject == binding.subject else {
      throw ControlPeerAuthenticationError.subjectIdentityMismatch
    }
  }

  public func peerIdentity(
    from credentials: RawControlPeerCredentials, identity: CodeIdentity
  ) throws -> UnixPeerIdentity {
    try validate(credentials: credentials)
    return UnixPeerIdentity(
      effectiveUID: credentials.auditEffectiveUID, effectiveGID: credentials.auditEffectiveGID,
      pid: credentials.auditPID, pidVersion: credentials.auditPIDVersion,
      auditSessionID: credentials.auditSessionID, codeIdentity: identity
    )
  }

  private func validate(credentials: RawControlPeerCredentials) throws {
    guard credentials.auditTokenData.count == MemoryLayout<audit_token_t>.size else {
      throw ControlPeerAuthenticationError.malformedPeerToken
    }
    guard credentials.peerUID == credentials.auditEffectiveUID else {
      throw ControlPeerAuthenticationError.peerUIDMismatch
    }
    guard credentials.peerGID == credentials.auditEffectiveGID else {
      throw ControlPeerAuthenticationError.peerGIDMismatch
    }
    guard credentials.peerPID > 0, credentials.peerPID == credentials.auditPID else {
      throw ControlPeerAuthenticationError.peerPIDMismatch
    }
    guard credentials.auditPIDVersion > 0 else {
      throw ControlPeerAuthenticationError.peerPIDVersionInvalid
    }
    guard credentials.auditSessionID > 0 else {
      throw ControlPeerAuthenticationError.peerAuditSessionInvalid
    }
    guard credentials.peerUID == policy.expectedUserID else {
      throw ControlPeerAuthenticationError.expectedUserMismatch
    }
  }

  private func validateBindingInputs(
    daemonGeneration: UInt64,
    serverNonce: String,
    socketDevice: UInt64,
    socketInode: UInt64
  ) throws {
    guard daemonGeneration > 0, socketDevice > 0, socketInode > 0 else {
      throw ControlPeerAuthenticationError.invalidSocketBinding
    }
    guard ControlPeerInputValidation.isServerNonce(serverNonce) else {
      throw ControlPeerAuthenticationError.invalidServerNonce
    }
  }

  private func validate(declaredSubject: DeclaredControlSubject, peer: UnixPeerIdentity) throws {
    guard !declaredSubject.isRevoked else {
      throw ControlPeerAuthenticationError.subjectRevoked
    }
    guard
      ControlPeerInputValidation.isSafeIdentifier(
        declaredSubject.localSubject.identifier, maximumLength: 128
      ), declaredSubject.localSubject.userID == peer.effectiveUID,
      declaredSubject.localSubject.codeIdentityHash == peer.codeIdentity.codeDirectoryHash,
      (declaredSubject.localSubject.credentialID == nil) == (declaredSubject.credential == nil)
    else {
      throw ControlPeerAuthenticationError.subjectIdentityMismatch
    }
  }

  private func validateCredential(
    _ proof: ControlPeerCredentialProof?,
    declaredSubject: DeclaredControlSubject,
    peer: UnixPeerIdentity,
    serverNonce: String,
    daemonGeneration: UInt64,
    socketDevice: UInt64,
    socketInode: UInt64
  ) throws {
    guard let credential = declaredSubject.credential else {
      guard proof == nil else {
        throw ControlPeerAuthenticationError.credentialProofUnexpected
      }
      return
    }
    guard let proof else {
      throw ControlPeerAuthenticationError.credentialProofRequired
    }
    guard proof.credentialID == credential.identifier else {
      throw ControlPeerAuthenticationError.credentialIDMismatch
    }
    guard ControlPeerInputValidation.isSafeIdentifier(proof.credentialID, maximumLength: 128),
      credential.p256X963PublicKey.count == 65,
      ControlPeerInputValidation.isSafeIdentifier(credential.identifier, maximumLength: 128)
    else {
      throw ControlPeerAuthenticationError.credentialMaterialInvalid
    }
    guard proof.signatureDERBase64.utf8.count <= 256,
      let signatureData = Data(base64Encoded: proof.signatureDERBase64),
      (8...128).contains(signatureData.count)
    else {
      throw ControlPeerAuthenticationError.credentialProofMalformed
    }
    let publicKey: P256.Signing.PublicKey
    let signature: P256.Signing.ECDSASignature
    do {
      publicKey = try P256.Signing.PublicKey(x963Representation: credential.p256X963PublicKey)
      signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
    } catch {
      throw ControlPeerAuthenticationError.credentialMaterialInvalid
    }
    let challenge = try ControlPeerCredentialChallenge(
      subjectID: declaredSubject.localSubject.identifier, serverNonce: serverNonce,
      daemonGeneration: daemonGeneration, socketDevice: socketDevice, socketInode: socketInode,
      peer: peer, credentialProofRequired: true
    ).canonicalData()
    guard publicKey.isValidSignature(signature, for: challenge) else {
      throw ControlPeerAuthenticationError.credentialProofRejected
    }
  }
}

private enum ControlPeerInputValidation {
  static func isSafeIdentifier(_ value: String, maximumLength: Int) -> Bool {
    guard !value.isEmpty, value.utf8.count <= maximumLength,
      !value.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F })
    else {
      return false
    }
    return value.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
  }

  static func isCodeDirectoryHash(_ value: String) -> Bool {
    value.range(of: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$", options: .regularExpression) != nil
  }

  static func isServerNonce(_ value: String) -> Bool {
    guard (16...128).contains(value.utf8.count),
      !value.contains(where: { $0.isWhitespace || $0.isNewline }),
      let data = Data(base64Encoded: value), (16...96).contains(data.count)
    else {
      return false
    }
    return data.base64EncodedString() == value
  }
}
