import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightState

final class AuditSchemaV19MigrationTests: XCTestCase {
    func testV18UpgradeCreatesExactAuditSchemaAndVerifiedRollbackRestoresV18() throws {
        try withTemporaryStore(throughVersion: 18) { store, directory in
            XCTAssertEqual(try store.schemaVersion(), 18)
            let service = StateUpgradeService(store: store)

            let result = try service.migrateToLatestWithVerifiedBackup()

            XCTAssertEqual(result.migration.fromSchemaVersion, 18)
            XCTAssertEqual(result.migration.toSchemaVersion, 19)
            XCTAssertEqual(try store.schemaVersion(), 19)
            XCTAssertEqual(HostwrightContractVersions.stateSchema, 19)
            try store.validateSchema()

            let snapshot = try XCTUnwrap(result.rollbackSnapshot)
            XCTAssertEqual(snapshot.stateSchemaVersion, 18)
            XCTAssertEqual(snapshot.databasePath, store.path)
            XCTAssertEqual(snapshot.databaseSHA256.count, 64)
            XCTAssertGreaterThan(snapshot.databaseBytes, 0)
            XCTAssertNoThrow(try service.verify(snapshot))

            let schema = try store.withConnection(createIfNeeded: false, readOnly: true) {
                connection in
                let tables = try connection.query(
                    """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'table' AND name LIKE 'audit_%'
                    ORDER BY name ASC
                    """
                ).compactMap { $0.first ?? nil }
                let indexes = try connection.query(
                    """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'index' AND name LIKE 'audit_%'
                    ORDER BY name ASC
                    """
                ).compactMap { $0.first ?? nil }
                return (tables, indexes)
            }
            XCTAssertEqual(schema.0, [
                "audit_key_metadata",
                "audit_records",
                "audit_retention_anchors",
                "audit_segments",
            ])
            XCTAssertEqual(schema.1, [
                "audit_key_metadata_active_idx",
                "audit_records_deduplication_idx",
                "audit_records_request_idx",
                "audit_records_segment_idx",
                "audit_records_subject_idx",
                "audit_retention_key_idx",
                "audit_segments_key_idx",
                "audit_segments_prior_digest_idx",
            ])

            let restoredVersion = try service.restoreVerifiedSnapshot(
                snapshot,
                operationID: "00000000-0000-0000-0000-000000000019"
            )
            XCTAssertEqual(restoredVersion, 18)
            XCTAssertEqual(try store.schemaVersion(), 18)
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

    func testV19MigrationChecksumTamperingFailsClosedWithoutFurtherWrites() throws {
        try withTemporaryStore(throughVersion: 19) { store, directory in
            let connection = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            try connection.run(
                "UPDATE schema_migrations SET checksum = 'tampered' WHERE version = 19"
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
                    XCTAssertEqual(version, 19)
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
            .appendingPathComponent("hostwright-audit-schema-v19-\(UUID().uuidString)", isDirectory: true)
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
