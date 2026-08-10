import Foundation
import XCTest

@testable import HostwrightCore
@testable import HostwrightState

final class PluginSchemaV21MigrationTests: XCTestCase {
    func testV20UpgradeCreatesExactPluginSchemaAndVerifiedRollbackRestoresV20() throws {
        try withTemporaryStore(throughVersion: 20) { store, directory in
            XCTAssertEqual(try store.schemaVersion(), 20)
            let service = StateUpgradeService(store: store)

            let result = try service.migrateToLatestWithVerifiedBackup()

            XCTAssertEqual(result.migration.fromSchemaVersion, 20)
            XCTAssertEqual(result.migration.toSchemaVersion, MigrationRunner.latestSchemaVersion)
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
            XCTAssertEqual(HostwrightContractVersions.stateSchema, MigrationRunner.latestSchemaVersion)
            try store.validateSchema()

            let snapshot = try XCTUnwrap(result.rollbackSnapshot)
            XCTAssertEqual(snapshot.stateSchemaVersion, 20)
            XCTAssertEqual(snapshot.databasePath, store.path)
            XCTAssertEqual(snapshot.databaseSHA256.count, 64)
            XCTAssertGreaterThan(snapshot.databaseBytes, 0)
            XCTAssertNoThrow(try service.verify(snapshot))

            let schema = try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
                let tables = try connection.query(
                    """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'table' AND name LIKE 'plugin_%'
                    ORDER BY name ASC
                    """
                ).compactMap { $0.first ?? nil }
                let indexes = try connection.query(
                    """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'index' AND name LIKE 'plugin_%'
                    ORDER BY name ASC
                    """
                ).compactMap { $0.first ?? nil }
                let triggers = try connection.query(
                    """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'trigger' AND name LIKE 'plugin_%'
                    ORDER BY name ASC
                    """
                ).compactMap { $0.first ?? nil }
                return (tables, indexes, triggers)
            }

            XCTAssertEqual(schema.0, [
                "plugin_activations",
                "plugin_grants",
                "plugin_packages",
                "plugin_provenance",
                "plugin_quarantine",
                "plugin_revocations",
                "plugin_rollback_state",
            ])
            XCTAssertEqual(schema.1, [
                "plugin_activations_digest_idx",
                "plugin_grants_capability_idx",
                "plugin_packages_identifier_idx",
                "plugin_packages_state_idx",
                "plugin_provenance_signer_idx",
                "plugin_quarantine_package_idx",
                "plugin_revocations_target_idx",
                "plugin_rollback_operation_idx",
            ])
            XCTAssertEqual(schema.2, [
                "plugin_active_package_match_insert",
                "plugin_active_package_match_update",
                "plugin_grant_delete",
                "plugin_package_immutable_content",
                "plugin_provenance_delete",
                "plugin_provenance_immutable",
            ])

            let restoredVersion = try service.restoreVerifiedSnapshot(
                snapshot,
                operationID: "00000000-0000-0000-0000-000000000021"
            )
            XCTAssertEqual(restoredVersion, 20)
            XCTAssertEqual(try store.schemaVersion(), 20)
            XCTAssertEqual(
                try StateMaintenanceFileSupport.fingerprint(store.path).sha256,
                snapshot.databaseSHA256
            )

            let rollbackRoot = directory.appendingPathComponent(
                ".hostwright-state-upgrades",
                isDirectory: true
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: rollbackRoot.path))
            XCTAssertEqual(permissions(rollbackRoot.path), 0o700)
        }
    }

    func testV21MigrationChecksumTamperingFailsClosedWithoutFurtherWrites() throws {
        try withTemporaryStore(throughVersion: 21) { store, directory in
            let connection = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            try connection.run(
                "UPDATE schema_migrations SET checksum = 'tampered' WHERE version = 21"
            )
            try connection.close()

            let databaseURL = directory.appendingPathComponent("state.sqlite")
            let fingerprint = try StateMaintenanceFileSupport.fingerprint(databaseURL.path)
            let actions: [() throws -> Void] = [
                { try store.validateSchema() },
                { _ = try store.schemaVersion() },
                { try store.migrate() },
            ]

            for action in actions {
                XCTAssertThrowsError(try action()) { error in
                    guard case .migrationFailed(let version, let message) = error as? StateStoreError else {
                        return XCTFail("Expected migrationFailed, got \(error)")
                    }
                    XCTAssertEqual(version, 21)
                    XCTAssertTrue(message.contains("Recorded checksum"), message)
                }
                XCTAssertEqual(
                    try StateMaintenanceFileSupport.fingerprint(databaseURL.path),
                    fingerprint
                )
            }
        }
    }

    private func withTemporaryStore(
        throughVersion: Int,
        _ body: (SQLiteStateStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-plugin-schema-v21-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try MigrationRunner().apply(to: store, throughVersion: throughVersion)
        try body(store, directory)
    }

    private func permissions(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
