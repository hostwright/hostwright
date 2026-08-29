import CryptoKit
import Foundation
import HostwrightControlPlane

public struct ControlPeerIdentityRecord: Codable, Equatable, Sendable {
  public let subjectID: String
  public let userID: UInt32
  public let codeIdentity: CodeIdentity
  public let generation: Int
  public let credentialID: String?
  public let credentialPublicKeyBase64: String?
  public let declaredBySubjectID: String
  public let declaredAt: String
  public let credentialExpiresAt: String?
  public let revokedAt: String?
  public let updatedAt: String

  public init(
    subjectID: String,
    userID: UInt32,
    codeIdentity: CodeIdentity,
    generation: Int = 1,
    credentialID: String? = nil,
    credentialPublicKeyBase64: String? = nil,
    declaredBySubjectID: String,
    declaredAt: String,
    credentialExpiresAt: String? = nil,
    revokedAt: String? = nil,
    updatedAt: String
  ) {
    self.subjectID = subjectID
    self.userID = userID
    self.codeIdentity = codeIdentity
    self.generation = generation
    self.credentialID = credentialID
    self.credentialPublicKeyBase64 = credentialPublicKeyBase64
    self.declaredBySubjectID = declaredBySubjectID
    self.declaredAt = declaredAt
    self.credentialExpiresAt = credentialExpiresAt
    self.revokedAt = revokedAt
    self.updatedAt = updatedAt
  }

  public func validate() throws {
    try ControlIdentityValidation.identifier(subjectID, named: "subject ID")
    try ControlIdentityValidation.identifier(declaredBySubjectID, named: "declaring subject ID")
    try codeIdentity.validate()
    try ControlIdentityValidation.codeIdentity(codeIdentity)
    guard generation >= 1 else {
      throw StateStoreError.invalidRecord("Identity generation must be at least one.")
    }
    try ControlIdentityValidation.optionalCredential(
      id: credentialID,
      publicKeyBase64: credentialPublicKeyBase64
    )
    try ControlIdentityValidation.utcTimestamp(declaredAt, named: "declared at")
    try ControlIdentityValidation.utcTimestamp(updatedAt, named: "updated at")
    if let credentialExpiresAt {
      let expiry = try ControlIdentityValidation.utcTimestamp(
        credentialExpiresAt,
        named: "credential expiry"
      )
      let declared = try ControlIdentityValidation.utcTimestamp(declaredAt, named: "declared at")
      guard expiry > declared else {
        throw StateStoreError.invalidRecord("Credential expiry must follow declaration.")
      }
    }
    if let revokedAt {
      _ = try ControlIdentityValidation.utcTimestamp(revokedAt, named: "revoked at")
    }
  }
}

public struct ControlSessionRecord: Codable, Equatable, Sendable {
  public let sessionID: String
  public let subjectID: String
  public let daemonGeneration: UInt64
  public let serverNonceSHA256: String
  public let socketDevice: UInt64
  public let socketInode: UInt64
  public let effectiveUID: UInt32
  public let effectiveGID: UInt32
  public let pid: Int32
  public let pidVersion: UInt32
  public let auditSessionID: UInt32
  public let codeDirectoryHash: String
  public let credentialID: String?
  public let createdAt: String
  public let expiresAt: String
  public let revokedAt: String?
  public let updatedAt: String

  public init(
    sessionID: String,
    subjectID: String,
    daemonGeneration: UInt64,
    serverNonceSHA256: String,
    socketDevice: UInt64,
    socketInode: UInt64,
    effectiveUID: UInt32,
    effectiveGID: UInt32,
    pid: Int32,
    pidVersion: UInt32,
    auditSessionID: UInt32,
    codeDirectoryHash: String,
    credentialID: String? = nil,
    createdAt: String,
    expiresAt: String,
    revokedAt: String? = nil,
    updatedAt: String
  ) {
    self.sessionID = sessionID
    self.subjectID = subjectID
    self.daemonGeneration = daemonGeneration
    self.serverNonceSHA256 = serverNonceSHA256
    self.socketDevice = socketDevice
    self.socketInode = socketInode
    self.effectiveUID = effectiveUID
    self.effectiveGID = effectiveGID
    self.pid = pid
    self.pidVersion = pidVersion
    self.auditSessionID = auditSessionID
    self.codeDirectoryHash = codeDirectoryHash
    self.credentialID = credentialID
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.revokedAt = revokedAt
    self.updatedAt = updatedAt
  }

  public func validate() throws {
    try ControlIdentityValidation.identifier(sessionID, named: "session ID")
    try ControlIdentityValidation.identifier(subjectID, named: "subject ID")
    guard daemonGeneration > 0, daemonGeneration <= UInt64(Int64.max),
      socketDevice <= UInt64(Int64.max), socketInode > 0, socketInode <= UInt64(Int64.max), pid > 0
    else {
      throw StateStoreError.invalidRecord(
        "Session generation and socket identity must fit SQLite signed integers; inode and PID must be positive."
      )
    }
    try ControlIdentityValidation.sha256(serverNonceSHA256, named: "server nonce hash")
    try ControlIdentityValidation.codeDirectoryHash(codeDirectoryHash)
    if let credentialID {
      try ControlIdentityValidation.identifier(credentialID, named: "credential ID")
    }
    let created = try ControlIdentityValidation.utcTimestamp(createdAt, named: "created at")
    let expiry = try ControlIdentityValidation.utcTimestamp(expiresAt, named: "expires at")
    guard expiry > created else {
      throw StateStoreError.invalidRecord("Session expiry must follow creation.")
    }
    try ControlIdentityValidation.utcTimestamp(updatedAt, named: "updated at")
    if let revokedAt {
      _ = try ControlIdentityValidation.utcTimestamp(revokedAt, named: "revoked at")
    }
  }
}

public enum ControlIdentityRevocationTargetKind: String, Codable, CaseIterable, Sendable {
  case subject
  case credential
  case codeHash
  case session
}

public struct ControlIdentityRevocationRecord: Codable, Equatable, Sendable {
  public let revocationID: String
  public let targetKind: ControlIdentityRevocationTargetKind
  public let targetIdentifier: String
  public let reason: String
  public let actorSubjectID: String
  public let revokedAt: String

  public init(
    revocationID: String,
    targetKind: ControlIdentityRevocationTargetKind,
    targetIdentifier: String,
    reason: String,
    actorSubjectID: String,
    revokedAt: String
  ) {
    self.revocationID = revocationID
    self.targetKind = targetKind
    self.targetIdentifier = targetIdentifier
    self.reason = reason
    self.actorSubjectID = actorSubjectID
    self.revokedAt = revokedAt
  }

  public func validate() throws {
    try ControlIdentityValidation.identifier(revocationID, named: "revocation ID")
    try ControlIdentityValidation.identifier(actorSubjectID, named: "actor subject ID")
    switch targetKind {
    case .codeHash:
      try ControlIdentityValidation.codeDirectoryHash(targetIdentifier)
    case .subject, .credential, .session:
      try ControlIdentityValidation.identifier(targetIdentifier, named: "revocation target")
    }
    guard !reason.isEmpty, reason.utf8.count <= 512,
      !ControlIdentityValidation.containsControlCharacter(reason)
    else {
      throw StateStoreError.invalidRecord("Revocation reason must be bounded printable text.")
    }
    try ControlIdentityValidation.utcTimestamp(revokedAt, named: "revoked at")
  }
}

enum ControlIdentityValidation {
  static func identifier(_ value: String, named: String) throws {
    guard (1...128).contains(value.utf8.count),
      value.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil,
      !containsControlCharacter(value)
    else {
      throw StateStoreError.invalidRecord("\(named) is not a bounded safe identifier.")
    }
  }

  static func sha256(_ value: String, named: String) throws {
    guard value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
      throw StateStoreError.invalidRecord("\(named) must be a lowercase SHA-256 digest.")
    }
  }

  static func codeDirectoryHash(_ value: String) throws {
    guard
      value.range(
        of: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$", options: .regularExpression) != nil
    else {
      throw StateStoreError.invalidRecord(
        "Code directory hash must preserve a native 20- or 32-byte lowercase digest.")
    }
  }

  static func codeIdentity(_ identity: CodeIdentity) throws {
    try codeDirectoryHash(identity.codeDirectoryHash)
    try identifier(identity.signingIdentifier, named: "signing identifier")
    switch identity.validationMode {
    case .installedRequirement:
      guard let team = identity.teamIdentifier,
        team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
      else {
        throw StateStoreError.invalidRecord(
          "Installed code identity requires a valid team identifier.")
      }
    case .pinnedAdHoc:
      guard identity.teamIdentifier == nil else {
        throw StateStoreError.invalidRecord(
          "Pinned ad-hoc code identity cannot carry a team identifier.")
      }
    }
  }

  static func optionalCredential(id: String?, publicKeyBase64: String?) throws {
    guard (id == nil) == (publicKeyBase64 == nil) else {
      throw StateStoreError.invalidRecord("Credential ID and public key must be present together.")
    }
    guard let id, let publicKeyBase64 else { return }
    try identifier(id, named: "credential ID")
    guard publicKeyBase64.utf8.count <= 512,
      let bytes = Data(base64Encoded: publicKeyBase64),
      !bytes.isEmpty
    else {
      throw StateStoreError.invalidRecord("Credential public key is not bounded base64.")
    }
    do {
      _ = try P256.Signing.PublicKey(x963Representation: bytes)
    } catch {
      throw StateStoreError.invalidRecord("Credential public key is not a P-256 signing key.")
    }
  }

  @discardableResult
  static func utcTimestamp(_ value: String, named: String) throws -> Date {
    guard value.utf8.count <= 64,
      value.hasSuffix("Z"),
      !containsControlCharacter(value),
      let date = ISO8601DateFormatter().date(from: value)
    else {
      throw StateStoreError.invalidRecord("\(named) must be ISO-8601 UTC text.")
    }
    return date
  }

  static func containsControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { $0.properties.generalCategory == .control }
  }
}
