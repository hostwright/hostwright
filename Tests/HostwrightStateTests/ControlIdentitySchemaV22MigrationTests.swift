import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightCore
@testable import HostwrightState

final class ControlIdentitySchemaV22MigrationTests: XCTestCase {
  func testV21UpgradeAddsOneActiveInstalledIdentityBucketConstraint() throws {
    try withStore(throughVersion: 21) { store in
      try insertIdentity(identity(subjectID: "owner", hash: "a"), store: store)

      try store.migrate()

      XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
      let sql = try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
        try connection.query(
          "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'peer_identities_active_installed_bucket_idx'"
        ).first?.first ?? nil
      }
      XCTAssertTrue(try XCTUnwrap(sql).contains("WHERE validation_mode = 'installedRequirement'"))
      XCTAssertThrowsError(try store.controlIdentities.declare(
        identity(subjectID: "duplicate", hash: "b")
      ))
    }
  }

  func testV21AmbiguousInstalledBucketFailsMigrationWithoutPartialVersionAdvance() throws {
    try withStore(throughVersion: 21) { store in
      try insertIdentity(identity(subjectID: "owner", hash: "a"), store: store)
      try insertIdentity(identity(subjectID: "duplicate", hash: "b"), store: store)

      XCTAssertThrowsError(try store.migrate())
      XCTAssertEqual(try store.schemaVersion(), 21)
      let identityCount = try store.withConnection(
        createIfNeeded: false,
        readOnly: true
      ) { connection in
        try connection.query("SELECT COUNT(*) FROM peer_identities").first?.first ?? nil
      }
      XCTAssertEqual(identityCount, "2")
      let indexCount = try store.withConnection(
        createIfNeeded: false,
        readOnly: true
      ) { connection in
        try connection.query(
          "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'peer_identities_active_installed_bucket_idx'"
        ).first?.first ?? nil
      }
      XCTAssertEqual(indexCount, "0")
    }
  }

  private func identity(subjectID: String, hash: Character) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: subjectID,
      userID: 501,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q",
        signingIdentifier: "dev.hostwright.client",
        codeDirectoryHash: String(repeating: String(hash), count: 64),
        validationMode: .installedRequirement
      ),
      declaredBySubjectID: "owner",
      declaredAt: "2026-08-02T20:00:00Z",
      updatedAt: "2026-08-02T20:01:00Z"
    )
  }

  private func insertIdentity(
    _ identity: ControlPeerIdentityRecord,
    store: SQLiteStateStore
  ) throws {
    let connection = try SQLiteConnection(
      path: store.path, createIfNeeded: false, profile: .portableArtifact)
    defer { try? connection.close() }
    try connection.run(
      """
      INSERT INTO peer_identities (
        subject_id, user_id, signing_identifier, team_identifier, code_directory_hash,
        validation_mode, generation, credential_id, credential_public_key_base64,
        declared_by_subject_id, declared_at, credential_expires_at, revoked_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, NULL, NULL, ?)
      """,
      bindings: [
        .text(identity.subjectID), .int(Int(identity.userID)),
        .text(identity.codeIdentity.signingIdentifier),
        .text(identity.codeIdentity.teamIdentifier ?? ""),
        .text(identity.codeIdentity.codeDirectoryHash),
        .text(identity.codeIdentity.validationMode.rawValue), .int(identity.generation),
        .text(identity.declaredBySubjectID), .text(identity.declaredAt),
        .text(identity.updatedAt),
      ]
    )
  }

  private func withStore(
    throughVersion: Int,
    _ body: (SQLiteStateStore) throws -> Void
  ) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-control-identity-v22-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try MigrationRunner().apply(to: store, throughVersion: throughVersion)
    try body(store)
  }
}
