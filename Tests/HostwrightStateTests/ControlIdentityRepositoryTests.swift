import CryptoKit
import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightCore
@testable import HostwrightState

final class ControlIdentityRepositoryTests: XCTestCase {
  private let declaredAt = "2026-08-02T20:00:00Z"
  private let updatedAt = "2026-08-02T20:01:00Z"

  func testBootstrapIsExplicitOneTimeAndDeclareRequiresActiveActor() throws {
    try withStore { store in
      let owner = identity(subjectID: "owner", declaredBy: "owner")
      let invalidGeneration = ControlPeerIdentityRecord(
        subjectID: owner.subjectID, userID: owner.userID, codeIdentity: owner.codeIdentity,
        generation: 2, declaredBySubjectID: owner.declaredBySubjectID,
        declaredAt: owner.declaredAt, updatedAt: owner.updatedAt
      )
      let preRevoked = ControlPeerIdentityRecord(
        subjectID: owner.subjectID, userID: owner.userID, codeIdentity: owner.codeIdentity,
        declaredBySubjectID: owner.declaredBySubjectID, declaredAt: owner.declaredAt,
        revokedAt: "2026-08-02T20:00:30Z", updatedAt: owner.updatedAt
      )
      XCTAssertThrowsError(try store.controlIdentities.bootstrap(invalidGeneration))
      XCTAssertThrowsError(try store.controlIdentities.bootstrap(preRevoked))
      XCTAssertThrowsError(try store.controlIdentities.declare(owner))
      try store.controlIdentities.bootstrap(owner)
      XCTAssertThrowsError(try store.controlIdentities.bootstrap(owner))

      let delegatedGeneration = ControlPeerIdentityRecord(
        subjectID: "delegate", userID: owner.userID, codeIdentity: codeIdentity(hashCharacter: "b"),
        generation: 2, declaredBySubjectID: owner.subjectID,
        declaredAt: owner.declaredAt, updatedAt: owner.updatedAt
      )
      XCTAssertThrowsError(try store.controlIdentities.declare(delegatedGeneration))
    }
  }

  func testDeclaresInstalledAndPinnedAdHocIdentities() throws {
    try withStore { store in
      let installed = identity(subjectID: "owner", declaredBy: "owner")
      let adHoc = identity(
        subjectID: "local-tool",
        declaredBy: "owner",
        validationMode: .pinnedAdHoc,
        hashCharacter: "b"
      )
      try store.controlIdentities.bootstrap(installed)
      try store.controlIdentities.declare(adHoc)

      XCTAssertEqual(try store.controlIdentities.loadIdentity("owner"), installed)
      XCTAssertEqual(try store.controlIdentities.listIdentities(), [adHoc, installed])
    }
  }

  func testCredentialRotationRequiresCurrentGenerationAndInvalidatesOldSession() throws {
    try withStore { store in
      let first = signingKeyBase64()
      var owner = identity(subjectID: "owner", declaredBy: "owner")
      owner = ControlPeerIdentityRecord(
        subjectID: owner.subjectID, userID: owner.userID, codeIdentity: owner.codeIdentity,
        credentialID: "credential-one", credentialPublicKeyBase64: first,
        declaredBySubjectID: owner.declaredBySubjectID, declaredAt: owner.declaredAt,
        credentialExpiresAt: "2026-08-03T20:00:00Z", updatedAt: owner.updatedAt
      )
      try store.controlIdentities.bootstrap(owner)
      let session = session(subjectID: "owner", credentialID: "credential-one")
      try store.controlIdentities.persistSession(session)

      let rotated = try store.controlIdentities.rotateCredential(
        subjectID: "owner", expectedGeneration: 1, credentialID: "credential-two",
        credentialPublicKeyBase64: signingKeyBase64(),
        credentialExpiresAt: "2026-08-04T20:00:00Z", updatedAt: "2026-08-02T21:00:00Z"
      )
      XCTAssertEqual(rotated.generation, 2)
      XCTAssertEqual(rotated.credentialID, "credential-two")
      XCTAssertThrowsError(
        try store.controlIdentities.rotateCredential(
          subjectID: "owner", expectedGeneration: 1, credentialID: nil,
          credentialPublicKeyBase64: nil, credentialExpiresAt: nil,
          updatedAt: "2026-08-02T21:01:00Z"
        )
      )
      XCTAssertThrowsError(
        try store.controlIdentities.validateActiveSession(
          session.sessionID, daemonGeneration: session.daemonGeneration,
          at: "2026-08-02T21:02:00Z"
        )
      )
    }
  }

  func testRejectsInvalidIdentityAndCredentialBoundaries() throws {
    try withStore { store in
      let invalidTeam = ControlPeerIdentityRecord(
        subjectID: "owner", userID: 501,
        codeIdentity: CodeIdentity(
          teamIdentifier: "BAD", signingIdentifier: "dev.hostwright.client",
          codeDirectoryHash: digest("a"), validationMode: .installedRequirement
        ), declaredBySubjectID: "owner", declaredAt: declaredAt, updatedAt: updatedAt
      )
      XCTAssertThrowsError(try store.controlIdentities.declare(invalidTeam))
      let invalidHash = ControlPeerIdentityRecord(
        subjectID: "owner", userID: 501,
        codeIdentity: CodeIdentity(
          teamIdentifier: "993YC3JY4Q", signingIdentifier: "dev.hostwright.client",
          codeDirectoryHash: String(repeating: "A", count: 64),
          validationMode: .installedRequirement
        ), declaredBySubjectID: "owner", declaredAt: declaredAt, updatedAt: updatedAt
      )
      XCTAssertThrowsError(try store.controlIdentities.declare(invalidHash))
      let invalidCredential = ControlPeerIdentityRecord(
        subjectID: "owner", userID: 501,
        codeIdentity: codeIdentity(), credentialID: "credential", credentialPublicKeyBase64: "AQID",
        declaredBySubjectID: "owner", declaredAt: declaredAt, updatedAt: updatedAt
      )
      XCTAssertThrowsError(try store.controlIdentities.declare(invalidCredential))
      let unsafeID = ControlPeerIdentityRecord(
        subjectID: "owner\n", userID: 501, codeIdentity: codeIdentity(),
        declaredBySubjectID: "owner\n", declaredAt: declaredAt, updatedAt: updatedAt
      )
      XCTAssertThrowsError(try store.controlIdentities.declare(unsafeID))
    }
  }

  func testPersistsOnlyExactActiveIdentitySessionMatchAndRejectsGenerationChange() throws {
    try withStore { store in
      try store.controlIdentities.bootstrap(identity(subjectID: "owner", declaredBy: "owner"))
      let exact = session(subjectID: "owner")
      try store.controlIdentities.persistSession(exact)
      XCTAssertEqual(
        try store.controlIdentities.validateActiveSession(
          exact.sessionID, daemonGeneration: exact.daemonGeneration,
          at: "2026-08-02T20:30:00Z"
        ),
        exact
      )
      XCTAssertThrowsError(
        try store.controlIdentities.validateActiveSession(
          exact.sessionID, daemonGeneration: exact.daemonGeneration + 1,
          at: "2026-08-02T20:30:00Z"
        )
      )
      var wrongUID = session(subjectID: "owner", sessionID: "session-wrong-uid")
      wrongUID = ControlSessionRecord(
        sessionID: wrongUID.sessionID, subjectID: wrongUID.subjectID,
        daemonGeneration: wrongUID.daemonGeneration, serverNonceSHA256: wrongUID.serverNonceSHA256,
        socketDevice: wrongUID.socketDevice, socketInode: wrongUID.socketInode,
        effectiveUID: 502, effectiveGID: wrongUID.effectiveGID, pid: wrongUID.pid,
        pidVersion: wrongUID.pidVersion, auditSessionID: wrongUID.auditSessionID,
        codeDirectoryHash: wrongUID.codeDirectoryHash, createdAt: wrongUID.createdAt,
        expiresAt: wrongUID.expiresAt, updatedAt: wrongUID.updatedAt
      )
      XCTAssertThrowsError(try store.controlIdentities.persistSession(wrongUID))
    }
  }

  func testExpiryAndAllRevocationTargetsTakeEffectImmediately() throws {
    try withStore { store in
      try store.controlIdentities.bootstrap(identity(subjectID: "owner", declaredBy: "owner"))
      let target = identity(subjectID: "target", declaredBy: "owner", hashCharacter: "b")
      try store.controlIdentities.declare(target)
      let targetSession = session(
        subjectID: "target", sessionID: "target-session", hashCharacter: "b")
      try store.controlIdentities.persistSession(targetSession)
      let expired = session(
        subjectID: "owner", sessionID: "expired-session", expiresAt: "2026-08-02T20:00:01Z")
      try store.controlIdentities.persistSession(expired)
      XCTAssertThrowsError(
        try store.controlIdentities.validateActiveSession(
          expired.sessionID, daemonGeneration: 1, at: "2026-08-02T20:00:01Z"
        )
      )

      try store.controlIdentities.revoke(revocation("subject-target", .subject, "target"))
      XCTAssertNotNil(try store.controlIdentities.loadIdentity("target")?.revokedAt)
      XCTAssertNotNil(try store.controlIdentities.loadSession("target-session")?.revokedAt)

      let credentialIdentity = identity(
        subjectID: "credential-target", declaredBy: "owner", hashCharacter: "c",
        credentialID: "credential-target", credentialPublicKeyBase64: signingKeyBase64()
      )
      try store.controlIdentities.declare(credentialIdentity)
      let credentialSession = session(
        subjectID: "credential-target", sessionID: "credential-session", hashCharacter: "c",
        credentialID: "credential-target"
      )
      try store.controlIdentities.persistSession(credentialSession)
      try store.controlIdentities.revoke(
        revocation("credential-target", .credential, "credential-target"))
      XCTAssertNotNil(try store.controlIdentities.loadIdentity("credential-target")?.revokedAt)
      XCTAssertNotNil(try store.controlIdentities.loadSession("credential-session")?.revokedAt)

      let hashIdentity = identity(subjectID: "hash-target", declaredBy: "owner", hashCharacter: "d")
      try store.controlIdentities.declare(hashIdentity)
      try store.controlIdentities.revoke(revocation("hash-target", .codeHash, digest("d")))
      XCTAssertNotNil(try store.controlIdentities.loadIdentity("hash-target")?.revokedAt)
      XCTAssertThrowsError(
        try store.controlIdentities.declare(
          identity(subjectID: "hash-reuse", declaredBy: "owner", hashCharacter: "d")
        )
      )

      let sessionIdentity = identity(
        subjectID: "session-target", declaredBy: "owner", hashCharacter: "e")
      try store.controlIdentities.declare(sessionIdentity)
      let sessionTarget = session(
        subjectID: "session-target", sessionID: "session-target", hashCharacter: "e")
      try store.controlIdentities.persistSession(sessionTarget)
      try store.controlIdentities.revoke(revocation("session-target", .session, "session-target"))
      XCTAssertNil(try store.controlIdentities.loadIdentity("session-target")?.revokedAt)
      XCTAssertNotNil(try store.controlIdentities.loadSession("session-target")?.revokedAt)
      XCTAssertThrowsError(
        try store.controlIdentities.revoke(revocation("duplicate", .session, "session-target")))
    }
  }

  func testRecordsPersistAfterReopenAndV18SchemaInventoryIsStrict() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let store = SQLiteStateStore(path: path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity(subjectID: "owner", declaredBy: "owner"))
    try store.controlIdentities.persistSession(session(subjectID: "owner"))
    let reopened = SQLiteStateStore(path: path)
    XCTAssertEqual(try reopened.controlIdentities.listIdentities().count, 1)
    XCTAssertEqual(try reopened.controlIdentities.listSessions().count, 1)
    try reopened.withConnection(createIfNeeded: false, readOnly: true) { connection in
      let tables = Set(
        try connection.query(
          "SELECT name FROM sqlite_master WHERE type = 'table'"
        ).compactMap { $0.first ?? nil })
      XCTAssertTrue(
        Set([
          "peer_identities", "control_sessions", "identity_revocations", "control_requests",
          "idempotency_records",
        ]).isSubset(of: tables))
      let indexes = Set(
        try connection.query(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'control_%' OR name LIKE 'peer_identities_%' OR name LIKE 'identity_revocations_%' OR name LIKE 'idempotency_records_%'"
        ).compactMap { $0.first ?? nil })
      XCTAssertTrue(indexes.contains("control_sessions_subject_idx"))
      XCTAssertTrue(indexes.contains("control_requests_subject_idempotency_idx"))
    }
  }

  func testV17MigratesContiguouslyToV18() throws {
    try withStore(throughVersion: 17) { store in
      XCTAssertEqual(try store.schemaVersion(), 17)
      try store.migrate()
      XCTAssertEqual(try store.schemaVersion(), 18)
      try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
        let versions = try connection.query(
          "SELECT version FROM schema_migrations ORDER BY version"
        ).compactMap { $0.first ?? nil }.compactMap(Int.init)
        XCTAssertEqual(versions, Array(1...18))
      }
    }
  }

  private func identity(
    subjectID: String,
    declaredBy: String,
    validationMode: CodeValidationMode = .installedRequirement,
    hashCharacter: Character = "a",
    credentialID: String? = nil,
    credentialPublicKeyBase64: String? = nil
  ) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: subjectID, userID: 501,
      codeIdentity: codeIdentity(validationMode: validationMode, hashCharacter: hashCharacter),
      credentialID: credentialID, credentialPublicKeyBase64: credentialPublicKeyBase64,
      declaredBySubjectID: declaredBy, declaredAt: declaredAt,
      credentialExpiresAt: credentialID == nil ? nil : "2026-08-03T20:00:00Z",
      updatedAt: updatedAt
    )
  }

  private func codeIdentity(
    validationMode: CodeValidationMode = .installedRequirement,
    hashCharacter: Character = "a"
  ) -> CodeIdentity {
    CodeIdentity(
      teamIdentifier: validationMode == .installedRequirement ? "993YC3JY4Q" : nil,
      signingIdentifier: "dev.hostwright.client", codeDirectoryHash: digest(hashCharacter),
      validationMode: validationMode
    )
  }

  private func session(
    subjectID: String,
    sessionID: String = "owner-session",
    hashCharacter: Character = "a",
    credentialID: String? = nil,
    expiresAt: String = "2026-08-02T22:00:00Z"
  ) -> ControlSessionRecord {
    ControlSessionRecord(
      sessionID: sessionID, subjectID: subjectID, daemonGeneration: 1,
      serverNonceSHA256: digest("f"), socketDevice: 1, socketInode: 2,
      effectiveUID: 501, effectiveGID: 20, pid: 123, pidVersion: 1, auditSessionID: 1,
      codeDirectoryHash: digest(hashCharacter), credentialID: credentialID,
      createdAt: declaredAt, expiresAt: expiresAt, updatedAt: updatedAt
    )
  }

  private func revocation(
    _ id: String,
    _ targetKind: ControlIdentityRevocationTargetKind,
    _ target: String
  ) -> ControlIdentityRevocationRecord {
    ControlIdentityRevocationRecord(
      revocationID: id, targetKind: targetKind, targetIdentifier: target,
      reason: "security test", actorSubjectID: "owner", revokedAt: "2026-08-02T20:30:00Z"
    )
  }

  private func signingKeyBase64() -> String {
    P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
  }

  private func digest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
  }

  private func withStore(
    throughVersion: Int = HostwrightContractVersions.stateSchema,
    _ body: (SQLiteStateStore) throws -> Void
  ) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try MigrationRunner().apply(to: store, throughVersion: throughVersion)
    try body(store)
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-control-identities-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    return root
  }
}
