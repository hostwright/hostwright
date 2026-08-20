import Foundation
import HostwrightControlPlane
import XCTest

@testable import HostwrightCore
@testable import HostwrightState

final class RBACSchemaV20MigrationTests: XCTestCase {
  func testV19UpgradeCreatesExactPolicyProfileSchemaAndVerifiedRollbackRestoresV19() throws {
    try withTemporaryStore(throughVersion: 19) { store, directory in
      let timestamp = "2026-08-03T01:00:00Z"
      try insertIdentity(timestamp: timestamp, store: store)
      let service = StateUpgradeService(store: store)

      let result = try service.migrateToLatestWithVerifiedBackup()

      XCTAssertEqual(result.migration.fromSchemaVersion, 19)
      XCTAssertEqual(result.migration.toSchemaVersion, 22)
      XCTAssertEqual(try store.schemaVersion(), 22)
      XCTAssertEqual(HostwrightContractVersions.stateSchema, 22)
      try store.validateSchema()

      let snapshot = try XCTUnwrap(result.rollbackSnapshot)
      XCTAssertEqual(snapshot.stateSchemaVersion, 19)
      XCTAssertNoThrow(try service.verify(snapshot))
      let schema = try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
        let tables = try connection.query(
          """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND (
            name LIKE 'rbac_%' OR name LIKE 'admission_%' OR name = 'workload_profiles'
          ) ORDER BY name
          """
        ).compactMap { $0.first ?? nil }
        let indexes = try connection.query(
          """
          SELECT name FROM sqlite_master
          WHERE type = 'index' AND (
            name LIKE 'rbac_%' OR name LIKE 'admission_%' OR name LIKE 'workload_profiles_%'
          ) ORDER BY name
          """
        ).compactMap { $0.first ?? nil }
        let triggers = try connection.query(
          """
          SELECT name FROM sqlite_master
          WHERE type = 'trigger' AND name LIKE 'rbac_%' ORDER BY name
          """
        ).compactMap { $0.first ?? nil }
        return (tables, indexes, triggers)
      }
      XCTAssertEqual(schema.0, [
        "admission_exceptions", "admission_policies", "rbac_bindings", "rbac_delegations",
        "rbac_roles", "workload_profiles",
      ])
      XCTAssertEqual(schema.1, [
        "admission_exceptions_lookup_idx", "admission_policies_active_idx",
        "rbac_bindings_identity_idx", "rbac_bindings_role_idx", "rbac_bindings_subject_idx",
        "rbac_delegations_delegate_idx", "rbac_delegations_delegator_idx",
        "rbac_roles_builtin_idx", "workload_profiles_digest_idx", "workload_profiles_parent_idx",
      ])
      XCTAssertEqual(schema.2, [
        "rbac_builtin_role_delete", "rbac_builtin_role_update", "rbac_delegation_owner_insert",
        "rbac_delegation_owner_update", "rbac_last_owner_delete", "rbac_owner_binding_update",
      ])
      XCTAssertEqual(try store.rbac.listRoles().map(\.roleID), [
        "maintainer", "operator", "owner", "security-admin", "viewer",
      ])
      let owner = try XCTUnwrap(store.rbac.listBindings().only)
      XCTAssertEqual(owner.subjectID, "installing-subject")
      XCTAssertEqual(owner.roleID, "owner")
      XCTAssertEqual(owner.scope.kind, .global)
      XCTAssertEqual(StateIntegrityService(store: store).inspect().health, .healthy)

      XCTAssertEqual(
        try service.restoreVerifiedSnapshot(
          snapshot, operationID: "00000000-0000-0000-0000-000000000020"),
        19
      )
      XCTAssertEqual(try store.schemaVersion(), 19)
      XCTAssertEqual(
        try StateMaintenanceFileSupport.fingerprint(store.path).sha256,
        snapshot.databaseSHA256
      )
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent(".hostwright-state-upgrades").path)
      )
    }
  }

  func testV20ChecksumTamperingFailsClosedWithoutFurtherWrites() throws {
    try withTemporaryStore(throughVersion: 20) { store, _ in
      let connection = try SQLiteConnection(
        path: store.path, createIfNeeded: false, profile: .portableArtifact)
      try connection.run("UPDATE schema_migrations SET checksum = 'tampered' WHERE version = 20")
      try connection.close()
      let fingerprint = try StateMaintenanceFileSupport.fingerprint(store.path)

      for action in [
        { try store.validateSchema() },
        { _ = try store.schemaVersion() },
        { try store.migrate() },
      ] as [() throws -> Void] {
        XCTAssertThrowsError(try action()) { error in
          guard case .migrationFailed(let version, _) = error as? StateStoreError else {
            return XCTFail("Expected migration failure, got \(error)")
          }
          XCTAssertEqual(version, 20)
        }
        XCTAssertEqual(try StateMaintenanceFileSupport.fingerprint(store.path), fingerprint)
      }
    }
  }

  func testIntegrityRequiresTheExactFiveFrozenBuiltInRolesAtSchemaV20() throws {
    try withTemporaryStore(throughVersion: 19) { store, _ in
      let timestamp = "2026-08-03T01:00:00Z"
      try insertIdentity(timestamp: timestamp, store: store)
      try store.migrate()

      try store.withConnection { connection in
        try connection.transaction {
          try connection.run("DROP TRIGGER rbac_builtin_role_delete")
          try connection.run("DELETE FROM rbac_roles WHERE role_id = 'viewer'")
          try connection.run(
            """
            INSERT INTO rbac_roles (
              role_id, built_in, rules_json, generation, created_by_subject_id, created_at,
              updated_at
            ) VALUES ('substituted-role', 1, '[]', 1, NULL, ?, ?)
            """,
            bindings: [.text(timestamp), .text(timestamp)])
          try connection.run(
            """
            CREATE TRIGGER rbac_builtin_role_delete
            BEFORE DELETE ON rbac_roles WHEN OLD.built_in = 1
            BEGIN SELECT RAISE(ABORT, 'built-in RBAC roles are immutable'); END
            """)
        }
      }

      let builtInRoleIDs = try store.withConnection(createIfNeeded: false, readOnly: true) {
        try $0.query(
          "SELECT role_id FROM rbac_roles WHERE built_in = 1 ORDER BY role_id"
        ).compactMap(\.first)
      }
      XCTAssertEqual(builtInRoleIDs, [
        "maintainer", "operator", "owner", "security-admin", "substituted-role",
      ])
      let report = StateIntegrityService(store: store).inspect()
      XCTAssertEqual(report.health, .unrecoverable)
      XCTAssertTrue(report.checks.contains {
        $0.identifier == "hostwright.authoritative-records"
          && $0.status == .failed
          && $0.affectedRows >= 1
      })
    }
  }

  private func withTemporaryStore(
    throughVersion: Int,
    _ body: (SQLiteStateStore, URL) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hostwright-rbac-schema-v20-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
    try MigrationRunner().apply(to: store, throughVersion: throughVersion)
    try body(store, directory)
  }

  private func insertIdentity(timestamp: String, store: SQLiteStateStore) throws {
    let connection = try SQLiteConnection(
      path: store.path, createIfNeeded: false, profile: .portableArtifact)
    defer { try? connection.close() }
    try connection.run(
      """
      INSERT INTO peer_identities (
        subject_id, user_id, signing_identifier, team_identifier, code_directory_hash,
        validation_mode, generation, credential_id, credential_public_key_base64,
        declared_by_subject_id, declared_at, credential_expires_at, revoked_at, updated_at
      ) VALUES (?, ?, ?, NULL, ?, 'pinnedAdHoc', 1, NULL, NULL, ?, ?, NULL, NULL, ?)
      """,
      bindings: [
        .text("installing-subject"), .int(Int(geteuid())), .text("dev.hostwright.tests"),
        .text(String(repeating: "a", count: 64)), .text("installing-subject"),
        .text(timestamp), .text(timestamp),
      ]
    )
  }
}

private extension Array {
  var only: Element? { count == 1 ? first : nil }
}
