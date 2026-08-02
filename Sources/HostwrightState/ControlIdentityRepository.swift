import Foundation
import HostwrightControlPlane

public struct ControlIdentityRepository: Sendable {
  private let store: SQLiteStateStore

  public init(store: SQLiteStateStore) {
    self.store = store
  }

  public func bootstrap(_ identity: ControlPeerIdentityRecord) throws {
    try identity.validate()
    try requireNewIdentity(identity)
    guard identity.subjectID == identity.declaredBySubjectID else {
      throw StateStoreError.invalidRecord("Bootstrap identity must declare itself.")
    }
    try store.withValidatedConnection { connection in
      try connection.transaction {
        let count = try connection.query("SELECT COUNT(*) FROM peer_identities")
        guard count.first?.first == "0" else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Control identity bootstrap is permitted only for an empty identity store."
          )
        }
        try requireIdentityTargetsNotRevoked(identity, on: connection)
        try insert(identity, on: connection)
      }
    }
  }

  public func declare(_ identity: ControlPeerIdentityRecord) throws {
    try identity.validate()
    try requireNewIdentity(identity)
    try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let actor = try loadIdentity(identity.declaredBySubjectID, on: connection),
          actor.revokedAt == nil
        else {
          throw StateStoreError.notFound("Declaring subject is not active.")
        }
        try requireIdentityTargetsNotRevoked(identity, on: connection)
        try insert(identity, on: connection)
      }
    }
  }

  public func rotateCredential(
    subjectID: String,
    expectedGeneration: Int,
    credentialID: String?,
    credentialPublicKeyBase64: String?,
    credentialExpiresAt: String?,
    updatedAt: String
  ) throws -> ControlPeerIdentityRecord {
    try ControlIdentityValidation.identifier(subjectID, named: "subject ID")
    guard expectedGeneration >= 1 else {
      throw StateStoreError.invalidRecord("Expected generation must be at least one.")
    }
    try ControlIdentityValidation.optionalCredential(
      id: credentialID,
      publicKeyBase64: credentialPublicKeyBase64
    )
    try ControlIdentityValidation.utcTimestamp(updatedAt, named: "updated at")
    if let credentialExpiresAt {
      _ = try ControlIdentityValidation.utcTimestamp(
        credentialExpiresAt,
        named: "credential expiry"
      )
    }
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let existing = try loadIdentity(subjectID, on: connection) else {
          throw StateStoreError.notFound("Peer identity \(subjectID) does not exist.")
        }
        guard existing.revokedAt == nil else {
          throw StateStoreError.invalidRecord("Revoked identities cannot rotate credentials.")
        }
        guard existing.generation == expectedGeneration else {
          throw StateStoreError.transactionInvariantViolation(
            message:
              "Credential rotation generation does not match the current identity generation."
          )
        }
        if let credentialID,
          try isRevoked(.credential, target: credentialID, on: connection)
        {
          throw StateStoreError.invalidRecord("Revoked credentials cannot be restored by rotation.")
        }
        let replacement = ControlPeerIdentityRecord(
          subjectID: existing.subjectID,
          userID: existing.userID,
          codeIdentity: existing.codeIdentity,
          generation: existing.generation + 1,
          credentialID: credentialID,
          credentialPublicKeyBase64: credentialPublicKeyBase64,
          declaredBySubjectID: existing.declaredBySubjectID,
          declaredAt: existing.declaredAt,
          credentialExpiresAt: credentialExpiresAt,
          revokedAt: nil,
          updatedAt: updatedAt
        )
        try replacement.validate()
        try connection.run(
          """
          UPDATE peer_identities
          SET generation = ?, credential_id = ?, credential_public_key_base64 = ?,
              credential_expires_at = ?, updated_at = ?
          WHERE subject_id = ? AND generation = ? AND revoked_at IS NULL
          """,
          bindings: [
            .int(replacement.generation),
            controlIdentityOptionalText(replacement.credentialID),
            controlIdentityOptionalText(replacement.credentialPublicKeyBase64),
            controlIdentityOptionalText(replacement.credentialExpiresAt),
            .text(replacement.updatedAt),
            .text(replacement.subjectID),
            .int(expectedGeneration),
          ]
        )
        guard let stored = try loadIdentity(subjectID, on: connection),
          stored.generation == replacement.generation
        else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Credential rotation did not persist the expected generation."
          )
        }
        return stored
      }
    }
  }

  public func loadIdentity(_ subjectID: String) throws -> ControlPeerIdentityRecord? {
    try ControlIdentityValidation.identifier(subjectID, named: "subject ID")
    return try store.withValidatedConnection(readOnly: true) { connection in
      try loadIdentity(subjectID, on: connection)
    }
  }

  public func listIdentities() throws -> [ControlPeerIdentityRecord] {
    try store.withValidatedConnection(readOnly: true) { connection in
      try connection.query(
        """
        SELECT subject_id, user_id, signing_identifier, team_identifier,
               code_directory_hash, validation_mode, generation, credential_id,
               credential_public_key_base64, declared_by_subject_id, declared_at,
               credential_expires_at, revoked_at, updated_at
        FROM peer_identities
        ORDER BY subject_id
        """
      ).map(identity(from:))
    }
  }

  public func persistSession(_ session: ControlSessionRecord) throws {
    try session.validate()
    try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let identity = try loadIdentity(session.subjectID, on: connection) else {
          throw StateStoreError.notFound("Session subject does not have a declared identity.")
        }
        try requireSessionTargetsNotRevoked(session, on: connection)
        try requireCurrent(session: session, matches: identity, at: session.createdAt)
        try connection.run(
          """
          INSERT INTO control_sessions (
              session_id, subject_id, daemon_generation, server_nonce_sha256,
              socket_device, socket_inode, euid, egid, pid, pid_version,
              audit_session_id, code_directory_hash, credential_id, created_at,
              expires_at, revoked_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          bindings: sessionBindings(session)
        )
      }
    }
  }

  public func loadSession(_ sessionID: String) throws -> ControlSessionRecord? {
    try ControlIdentityValidation.identifier(sessionID, named: "session ID")
    return try store.withValidatedConnection(readOnly: true) { connection in
      try loadSession(sessionID, on: connection)
    }
  }

  public func listSessions(subjectID: String? = nil) throws -> [ControlSessionRecord] {
    if let subjectID {
      try ControlIdentityValidation.identifier(subjectID, named: "subject ID")
    }
    return try store.withValidatedConnection(readOnly: true) { connection in
      let rows: [[String?]]
      if let subjectID {
        rows = try connection.query(
          """
          SELECT session_id, subject_id, daemon_generation, server_nonce_sha256,
                 socket_device, socket_inode, euid, egid, pid, pid_version,
                 audit_session_id, code_directory_hash, credential_id, created_at,
                 expires_at, revoked_at, updated_at
          FROM control_sessions WHERE subject_id = ? ORDER BY created_at, session_id
          """,
          bindings: [.text(subjectID)]
        )
      } else {
        rows = try connection.query(
          """
          SELECT session_id, subject_id, daemon_generation, server_nonce_sha256,
                 socket_device, socket_inode, euid, egid, pid, pid_version,
                 audit_session_id, code_directory_hash, credential_id, created_at,
                 expires_at, revoked_at, updated_at
          FROM control_sessions ORDER BY created_at, session_id
          """
        )
      }
      return try rows.map(session(from:))
    }
  }

  public func revoke(_ revocation: ControlIdentityRevocationRecord) throws {
    try revocation.validate()
    try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let actor = try loadIdentity(revocation.actorSubjectID, on: connection),
          actor.revokedAt == nil
        else {
          throw StateStoreError.notFound("Revocation actor is not active.")
        }
        try connection.run(
          """
          INSERT INTO identity_revocations (
              revocation_id, target_kind, target_identifier, reason,
              actor_subject_id, revoked_at
          ) VALUES (?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .text(revocation.revocationID), .text(revocation.targetKind.rawValue),
            .text(revocation.targetIdentifier), .text(revocation.reason),
            .text(revocation.actorSubjectID), .text(revocation.revokedAt),
          ]
        )
        try applyRevocation(revocation, on: connection)
      }
    }
  }

  public func validateActiveSession(
    _ sessionID: String,
    daemonGeneration: UInt64,
    at timestamp: String
  ) throws -> ControlSessionRecord {
    try ControlIdentityValidation.identifier(sessionID, named: "session ID")
    guard daemonGeneration > 0 else {
      throw StateStoreError.invalidRecord("Daemon generation must be positive.")
    }
    let now = try ControlIdentityValidation.utcTimestamp(timestamp, named: "validation timestamp")
    return try store.withValidatedConnection(readOnly: true) { connection in
      guard let session = try loadSession(sessionID, on: connection) else {
        throw StateStoreError.notFound("Control session does not exist.")
      }
      guard session.daemonGeneration == daemonGeneration,
        session.revokedAt == nil,
        try ControlIdentityValidation.utcTimestamp(session.expiresAt, named: "session expiry") > now
      else {
        throw StateStoreError.invalidRecord("Control session is inactive.")
      }
      try requireSessionTargetsNotRevoked(session, on: connection)
      guard let identity = try loadIdentity(session.subjectID, on: connection) else {
        throw StateStoreError.invalidRecord("Control session subject no longer exists.")
      }
      try requireCurrent(session: session, matches: identity, at: timestamp)
      return session
    }
  }

  private func applyRevocation(
    _ revocation: ControlIdentityRevocationRecord,
    on connection: SQLiteConnection
  ) throws {
    let at = SQLiteValue.text(revocation.revokedAt)
    switch revocation.targetKind {
    case .subject:
      try connection.run(
        "UPDATE peer_identities SET revoked_at = COALESCE(revoked_at, ?), updated_at = ? WHERE subject_id = ?",
        bindings: [at, at, .text(revocation.targetIdentifier)]
      )
      try connection.run(
        "UPDATE control_sessions SET revoked_at = COALESCE(revoked_at, ?), updated_at = ? WHERE subject_id = ?",
        bindings: [at, at, .text(revocation.targetIdentifier)]
      )
    case .credential:
      try connection.run(
        "UPDATE peer_identities SET revoked_at = COALESCE(revoked_at, ?), updated_at = ? WHERE credential_id = ?",
        bindings: [at, at, .text(revocation.targetIdentifier)]
      )
      try connection.run(
        "UPDATE control_sessions SET revoked_at = COALESCE(revoked_at, ?), updated_at = ? WHERE credential_id = ?",
        bindings: [at, at, .text(revocation.targetIdentifier)]
      )
    case .codeHash:
      try connection.run(
        "UPDATE peer_identities SET revoked_at = COALESCE(revoked_at, ?), updated_at = ? WHERE code_directory_hash = ?",
        bindings: [at, at, .text(revocation.targetIdentifier)]
      )
      try connection.run(
        "UPDATE control_sessions SET revoked_at = COALESCE(revoked_at, ?), updated_at = ? WHERE code_directory_hash = ?",
        bindings: [at, at, .text(revocation.targetIdentifier)]
      )
    case .session:
      try connection.run(
        "UPDATE control_sessions SET revoked_at = COALESCE(revoked_at, ?), updated_at = ? WHERE session_id = ?",
        bindings: [at, at, .text(revocation.targetIdentifier)]
      )
    }
  }

  private func insert(
    _ identity: ControlPeerIdentityRecord,
    on connection: SQLiteConnection
  ) throws {
    try connection.run(
      """
      INSERT INTO peer_identities (
          subject_id, user_id, signing_identifier, team_identifier,
          code_directory_hash, validation_mode, generation, credential_id,
          credential_public_key_base64, declared_by_subject_id, declared_at,
          credential_expires_at, revoked_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: identityBindings(identity)
    )
  }

  private func requireNewIdentity(_ identity: ControlPeerIdentityRecord) throws {
    guard identity.generation == 1, identity.revokedAt == nil else {
      throw StateStoreError.invalidRecord(
        "New control identities must begin at generation one and cannot be pre-revoked."
      )
    }
  }

  private func requireIdentityTargetsNotRevoked(
    _ identity: ControlPeerIdentityRecord,
    on connection: SQLiteConnection
  ) throws {
    var targets: [(ControlIdentityRevocationTargetKind, String)] = [
      (.subject, identity.subjectID),
      (.codeHash, identity.codeIdentity.codeDirectoryHash),
    ]
    if let credentialID = identity.credentialID {
      targets.append((.credential, credentialID))
    }
    for (kind, target) in targets where try isRevoked(kind, target: target, on: connection) {
      throw StateStoreError.invalidRecord("A revoked identity target cannot be declared.")
    }
  }

  private func requireSessionTargetsNotRevoked(
    _ session: ControlSessionRecord,
    on connection: SQLiteConnection
  ) throws {
    var targets: [(ControlIdentityRevocationTargetKind, String)] = [
      (.session, session.sessionID),
      (.subject, session.subjectID),
      (.codeHash, session.codeDirectoryHash),
    ]
    if let credentialID = session.credentialID {
      targets.append((.credential, credentialID))
    }
    for (kind, target) in targets where try isRevoked(kind, target: target, on: connection) {
      throw StateStoreError.invalidRecord("A revoked target makes the control session inactive.")
    }
  }

  private func isRevoked(
    _ kind: ControlIdentityRevocationTargetKind,
    target: String,
    on connection: SQLiteConnection
  ) throws -> Bool {
    try !connection.query(
      "SELECT 1 FROM identity_revocations WHERE target_kind = ? AND target_identifier = ? LIMIT 1",
      bindings: [.text(kind.rawValue), .text(target)]
    ).isEmpty
  }

  private func requireCurrent(
    session: ControlSessionRecord,
    matches identity: ControlPeerIdentityRecord,
    at timestamp: String
  ) throws {
    guard identity.revokedAt == nil,
      identity.userID == session.effectiveUID,
      identity.codeIdentity.codeDirectoryHash == session.codeDirectoryHash,
      identity.credentialID == session.credentialID
    else {
      throw StateStoreError.invalidRecord(
        "Session does not exactly match an active declared identity.")
    }
    if let expiry = identity.credentialExpiresAt {
      let expires = try ControlIdentityValidation.utcTimestamp(expiry, named: "credential expiry")
      let at = try ControlIdentityValidation.utcTimestamp(timestamp, named: "session timestamp")
      guard expires > at else {
        throw StateStoreError.invalidRecord("Session credential is expired.")
      }
    }
  }

  private func loadIdentity(_ subjectID: String, on connection: SQLiteConnection) throws
    -> ControlPeerIdentityRecord?
  {
    let rows = try connection.query(
      """
      SELECT subject_id, user_id, signing_identifier, team_identifier,
             code_directory_hash, validation_mode, generation, credential_id,
             credential_public_key_base64, declared_by_subject_id, declared_at,
             credential_expires_at, revoked_at, updated_at
      FROM peer_identities WHERE subject_id = ? LIMIT 1
      """,
      bindings: [.text(subjectID)]
    )
    return try rows.first.map(identity(from:))
  }

  private func loadSession(_ sessionID: String, on connection: SQLiteConnection) throws
    -> ControlSessionRecord?
  {
    let rows = try connection.query(
      """
      SELECT session_id, subject_id, daemon_generation, server_nonce_sha256,
             socket_device, socket_inode, euid, egid, pid, pid_version,
             audit_session_id, code_directory_hash, credential_id, created_at,
             expires_at, revoked_at, updated_at
      FROM control_sessions WHERE session_id = ? LIMIT 1
      """,
      bindings: [.text(sessionID)]
    )
    return try rows.first.map(session(from:))
  }

  private func identity(from row: [String?]) throws -> ControlPeerIdentityRecord {
    guard row.count == 14,
      let subjectID = row[0], let userID = row[1].flatMap(UInt32.init),
      let signingIdentifier = row[2], let hash = row[4],
      let modeRaw = row[5], let mode = CodeValidationMode(rawValue: modeRaw),
      let generation = row[6].flatMap(Int.init), let declaredBy = row[9],
      let declaredAt = row[10], let updatedAt = row[13]
    else {
      throw StateStoreError.invalidRecord("Stored peer identity has an invalid shape.")
    }
    let record = ControlPeerIdentityRecord(
      subjectID: subjectID, userID: userID,
      codeIdentity: CodeIdentity(
        teamIdentifier: row[3] ?? nil, signingIdentifier: signingIdentifier,
        codeDirectoryHash: hash, validationMode: mode),
      generation: generation, credentialID: row[7] ?? nil,
      credentialPublicKeyBase64: row[8] ?? nil, declaredBySubjectID: declaredBy,
      declaredAt: declaredAt, credentialExpiresAt: row[11] ?? nil,
      revokedAt: row[12] ?? nil, updatedAt: updatedAt
    )
    try record.validate()
    return record
  }

  private func session(from row: [String?]) throws -> ControlSessionRecord {
    guard row.count == 17,
      let sessionID = row[0], let subjectID = row[1],
      let daemonGeneration = row[2].flatMap(UInt64.init), let nonce = row[3],
      let device = row[4].flatMap(UInt64.init), let inode = row[5].flatMap(UInt64.init),
      let euid = row[6].flatMap(UInt32.init), let egid = row[7].flatMap(UInt32.init),
      let pid = row[8].flatMap(Int32.init), let pidVersion = row[9].flatMap(UInt32.init),
      let auditSessionID = row[10].flatMap(UInt32.init), let hash = row[11],
      let createdAt = row[13], let expiresAt = row[14], let updatedAt = row[16]
    else {
      throw StateStoreError.invalidRecord("Stored control session has an invalid shape.")
    }
    let record = ControlSessionRecord(
      sessionID: sessionID, subjectID: subjectID, daemonGeneration: daemonGeneration,
      serverNonceSHA256: nonce, socketDevice: device, socketInode: inode,
      effectiveUID: euid, effectiveGID: egid, pid: pid, pidVersion: pidVersion,
      auditSessionID: auditSessionID, codeDirectoryHash: hash,
      credentialID: row[12] ?? nil, createdAt: createdAt, expiresAt: expiresAt,
      revokedAt: row[15] ?? nil, updatedAt: updatedAt
    )
    try record.validate()
    return record
  }

  private func identityBindings(_ record: ControlPeerIdentityRecord) -> [SQLiteValue] {
    [
      .text(record.subjectID), .int64(Int64(record.userID)),
      .text(record.codeIdentity.signingIdentifier),
      controlIdentityOptionalText(record.codeIdentity.teamIdentifier),
      .text(record.codeIdentity.codeDirectoryHash),
      .text(record.codeIdentity.validationMode.rawValue),
      .int(record.generation), controlIdentityOptionalText(record.credentialID),
      controlIdentityOptionalText(record.credentialPublicKeyBase64),
      .text(record.declaredBySubjectID),
      .text(record.declaredAt), controlIdentityOptionalText(record.credentialExpiresAt),
      controlIdentityOptionalText(record.revokedAt), .text(record.updatedAt),
    ]
  }

  private func sessionBindings(_ record: ControlSessionRecord) -> [SQLiteValue] {
    [
      .text(record.sessionID), .text(record.subjectID), .int64(Int64(record.daemonGeneration)),
      .text(record.serverNonceSHA256), .int64(Int64(record.socketDevice)),
      .int64(Int64(record.socketInode)), .int64(Int64(record.effectiveUID)),
      .int64(Int64(record.effectiveGID)), .int(Int(record.pid)), .int64(Int64(record.pidVersion)),
      .int64(Int64(record.auditSessionID)), .text(record.codeDirectoryHash),
      controlIdentityOptionalText(record.credentialID), .text(record.createdAt),
      .text(record.expiresAt),
      controlIdentityOptionalText(record.revokedAt), .text(record.updatedAt),
    ]
  }
}

private func controlIdentityOptionalText(_ value: String?) -> SQLiteValue {
  value.map(SQLiteValue.text) ?? .null
}
