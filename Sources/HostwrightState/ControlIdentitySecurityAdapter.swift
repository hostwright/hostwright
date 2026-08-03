import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity

public struct SQLiteControlIdentitySecurityAdapter: Sendable {
  private let store: SQLiteStateStore
  private let sessionLifetime: TimeInterval
  private let now: @Sendable () -> Date

  public init(
    store: SQLiteStateStore,
    sessionLifetime: TimeInterval,
    now: @escaping @Sendable () -> Date = Date.init
  ) throws {
    guard sessionLifetime.isFinite, sessionLifetime > 0 else {
      throw StateStoreError.invalidRecord(
        "Control session lifetime must be finite and positive."
      )
    }
    self.store = store
    self.sessionLifetime = sessionLifetime
    self.now = now
  }

  private func resolvedIdentity(
    userID: UInt32,
    codeIdentity: CodeIdentity
  ) throws -> ControlPeerIdentityRecord {
    let identities = try retryTransientContention {
      try store.controlIdentities.listIdentities()
    }
    let matches = identities.filter {
      guard $0.userID == userID,
        $0.codeIdentity.validationMode == codeIdentity.validationMode
      else { return false }
      switch codeIdentity.validationMode {
      case .installedRequirement:
        return $0.codeIdentity.teamIdentifier == codeIdentity.teamIdentifier
          && $0.codeIdentity.signingIdentifier == codeIdentity.signingIdentifier
      case .pinnedAdHoc:
        return $0.codeIdentity.teamIdentifier == nil
          && $0.codeIdentity.signingIdentifier == codeIdentity.signingIdentifier
          && $0.codeIdentity.codeDirectoryHash == codeIdentity.codeDirectoryHash
      }
    }
    guard let identity = matches.first else {
      throw ControlPeerAuthenticationError.subjectNotDeclared
    }
    guard matches.count == 1 else {
      throw ControlPeerAuthenticationError.subjectIdentityMismatch
    }
    return identity
  }

  private func timestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private func retryTransientContention<T>(_ operation: () throws -> T) throws -> T {
    let deadline = DispatchTime.now().uptimeNanoseconds
      + UInt64(ControlPlaneContract.maximumAuthenticationHandshakeMilliseconds) * 1_000_000
    while true {
      do {
        return try operation()
      } catch let error as StateStoreError {
        guard case .databaseLocked = error,
          DispatchTime.now().uptimeNanoseconds < deadline
        else { throw error }
        usleep(25_000)
      }
    }
  }
}

extension SQLiteControlIdentitySecurityAdapter: DeclaredControlSubjectResolving {
  public func resolve(
    userID: UInt32,
    codeIdentity: CodeIdentity
  ) throws -> DeclaredControlSubject {
    let identity = try resolvedIdentity(userID: userID, codeIdentity: codeIdentity)
    let credential: DeclaredControlCredential?
    if let credentialID = identity.credentialID,
      let encodedKey = identity.credentialPublicKeyBase64,
      let key = Data(base64Encoded: encodedKey)
    {
      credential = DeclaredControlCredential(
        identifier: credentialID,
        p256X963PublicKey: key
      )
    } else if identity.credentialID == nil && identity.credentialPublicKeyBase64 == nil {
      credential = nil
    } else {
      throw ControlPeerAuthenticationError.credentialMaterialInvalid
    }
    let credentialExpired: Bool
    if let expiry = identity.credentialExpiresAt {
      guard let expiryDate = ISO8601DateFormatter().date(from: expiry) else {
        throw ControlPeerAuthenticationError.credentialMaterialInvalid
      }
      credentialExpired = expiryDate <= now()
    } else {
      credentialExpired = false
    }
    return DeclaredControlSubject(
      localSubject: LocalSubject(
        identifier: identity.subjectID,
        userID: identity.userID,
        codeIdentityHash: identity.codeIdentity.codeDirectoryHash,
        credentialID: identity.credentialID
      ),
      credential: credential,
      isRevoked: identity.revokedAt != nil || credentialExpired
    )
  }
}

extension SQLiteControlIdentitySecurityAdapter: ControlSessionBindingStoring {
  public func persist(_ binding: ControlSessionBinding) throws {
    try binding.validate()
    let createdAt = now()
    let nonceDigest = SHA256.hash(data: Data(binding.serverNonce.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    let session = ControlSessionRecord(
      sessionID: binding.sessionID,
      subjectID: binding.subject.identifier,
      daemonGeneration: binding.daemonGeneration,
      serverNonceSHA256: nonceDigest,
      socketDevice: binding.socketDevice,
      socketInode: binding.socketInode,
      effectiveUID: binding.peer.effectiveUID,
      effectiveGID: binding.peer.effectiveGID,
      pid: binding.peer.pid,
      pidVersion: binding.peer.pidVersion,
      auditSessionID: binding.peer.auditSessionID,
      codeDirectoryHash: binding.peer.codeIdentity.codeDirectoryHash,
      credentialID: binding.subject.credentialID,
      createdAt: timestamp(createdAt),
      expiresAt: timestamp(createdAt.addingTimeInterval(sessionLifetime)),
      updatedAt: timestamp(createdAt)
    )
    try retryTransientContention {
      try store.controlIdentities.persistSession(session)
    }
  }

  public func isActive(sessionID: String, daemonGeneration: UInt64) throws -> Bool {
    do {
      try retryTransientContention {
        _ = try store.controlIdentities.validateActiveSession(
          sessionID,
          daemonGeneration: daemonGeneration,
          at: timestamp(now())
        )
      }
      return true
    } catch StateStoreError.notFound, StateStoreError.invalidRecord {
      return false
    }
  }
}
