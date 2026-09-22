import Foundation
import Synchronization
import XCTest
@testable import HostwrightRuntime
@testable import HostwrightState

extension HostwrightStateTests {
    func testSQLiteMigrationsAreIdempotentAndRecordSchemaVersion() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            try store.migrate()

            XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
            XCTAssertEqual(store.configuration.origin, .explicit)
        }
    }

    func testRepeatedMigrationPreservesExistingStateRows() throws {
        try withTemporaryStore { store, databaseURL in
            try saveDesiredState(in: store)
            let beforeCounts = try tableCounts(in: databaseURL.path)

            try store.migrate()
            try store.validateSchema()

            let afterCounts = try tableCounts(in: databaseURL.path)
            XCTAssertEqual(beforeCounts["projects"], 1)
            XCTAssertEqual(beforeCounts["desired_services"], 1)
            XCTAssertEqual(beforeCounts, afterCounts)
            XCTAssertEqual(try store.desiredStates.loadProject(id: projectID).name, "api-local")
        }
    }

    func testMigrationBackfillsLegacyOwnershipRuntimeAdapter() throws {
        for duplicate in [false, true] {
            let name = duplicate ? "existing canonical owner" : "legacy owner only"
            try withTemporaryStore { store, databaseURL in
                try MigrationRunner().apply(to: store, throughVersion: 4)
                let connection = try SQLiteConnection(path: databaseURL.path)
                try insertOwnershipRecord(connection: connection, id: "owner-legacy", runtimeAdapter: "runtime-adapter")
                if duplicate {
                    try insertOwnershipRecord(connection: connection, id: "owner-canonical", runtimeAdapter: "AppleContainerApplyAdapter")
                }
                try store.migrate()
                let ownership = try store.ownership.loadAll()
                XCTAssertEqual(ownership.count, 1, name)
                XCTAssertEqual(ownership.first?.id, duplicate ? "owner-canonical" : "owner-legacy", name)
                XCTAssertEqual(ownership.first?.runtimeAdapter, "AppleContainerApplyAdapter", name)
                XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion, name)
            }
        }
    }

    func testVersionSixBackfillsSurviveTheVersionSevenContractMigration() throws {
        try withTemporaryStore { store, databaseURL in
            try MigrationRunner().apply(to: store, throughVersion: 5)
            let connection = try SQLiteConnection(path: databaseURL.path)
            try connection.run(
                """
                INSERT INTO observed_runtime_snapshots (
                    id, project_id, runtime_adapter, runtime_name, runtime_version, observed_at,
                    parser_version, raw_output_hash, redacted_summary, capabilities_json
                ) VALUES ('snapshot-v5', NULL, 'AppleContainerApplyAdapter', 'Apple container CLI',
                          '1.0.0', ?, 'v1', NULL, 'legacy', '[]')
                """,
                bindings: [.text(timestamp)]
            )
            try connection.run(
                """
                INSERT INTO observed_services (
                    id, snapshot_id, project_name, service_name, instance_name, image,
                    lifecycle_state, health_state, ports_json, mounts_json, runtime_identifiers_json
                ) VALUES ('service-v5', 'snapshot-v5', 'api-local', 'api', NULL, 'local/api:latest',
                          'stopped', 'unknown', '[]', '[]', '{}')
                """
            )
            try insertOwnershipRecord(connection: connection, id: "owner-v5", runtimeAdapter: "AppleContainerApplyAdapter")

            try store.migrate()

            let observed = try store.observedStates.loadObservedServices(snapshotID: "snapshot-v5")
            XCTAssertEqual(observed.map(\.resourceIdentifier), ["hostwright-api-local-api"])
            XCTAssertEqual(observed.map(\.networksJSON), ["[]"])
            let ownership = try store.ownership.loadAll()
            XCTAssertEqual(ownership.map(\.identityVersion), [1])
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
        }
    }

    func testRepositoryReadsDoNotCreateOrMigrateStateDatabase() throws {
        try withTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("missing.sqlite")
            let store = SQLiteStateStore(path: databaseURL.path)

            XCTAssertThrowsError(try store.events.loadAll()) { error in
                XCTAssertTrue(String(describing: error).contains("Failed to open state database"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        }
    }

    func testReadOfUnmigratedDatabaseDoesNotCreateMigrationTable() throws {
        try withTemporaryStore { store, databaseURL in
            _ = try SQLiteConnection(path: databaseURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)

            XCTAssertThrowsError(try store.events.loadAll()) { error in
                guard case .incompatibleSchema(let foundVersion, let latestSupported, let message) = error as? StateStoreError else {
                    return XCTFail("Expected incompatibleSchema, got \(error).")
                }
                XCTAssertEqual(foundVersion, 0)
                XCTAssertEqual(latestSupported, MigrationRunner.latestSchemaVersion)
                XCTAssertTrue(message.contains("has not been migrated"))
            }

            let connection = try SQLiteConnection(path: databaseURL.path, createIfNeeded: false, readOnly: true)
            let tables = try connection.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name ASC")
                .compactMap { $0.first ?? nil }
            XCTAssertFalse(tables.contains("schema_migrations"))
        }
    }

    func testFutureSchemaVersionFailsBeforeMigrationOrRead() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            let futureVersion = MigrationRunner.latestSchemaVersion + 1
            let connection = try SQLiteConnection(path: databaseURL.path)
            try connection.run(
                """
                INSERT INTO schema_migrations (version, description, checksum, applied_at)
                    VALUES (?, 'future schema', 'future-checksum', '2026-07-01T00:00:00Z')
                """,
                bindings: [.int(futureVersion)]
            )

            for action in [
                { try store.validateSchema() },
                { _ = try store.schemaVersion() },
                { _ = try store.events.loadAll() },
                { try store.migrate() }
            ] {
                XCTAssertThrowsError(try action()) { error in
                    guard case .incompatibleSchema(let foundVersion, let latestSupported, let message) = error as? StateStoreError else {
                        return XCTFail("Expected incompatibleSchema, got \(error).")
                    }
                    XCTAssertEqual(foundVersion, futureVersion)
                    XCTAssertEqual(latestSupported, MigrationRunner.latestSchemaVersion)
                    XCTAssertTrue(message.contains("newer Hostwright release"))
                }
            }
        }
    }

    func testMigrationChecksumMismatchFailsClosed() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            let connection = try SQLiteConnection(path: databaseURL.path)
            try connection.run("UPDATE schema_migrations SET checksum = 'tampered' WHERE version = 1")

            let actions: [() throws -> Void] = [
                { try store.validateSchema() },
                { _ = try store.schemaVersion() },
                { _ = try store.events.loadAll() },
                { try store.migrate() }
            ]
            for action in actions {
                XCTAssertThrowsError(try action()) { error in
                    guard case .migrationFailed(let version, let message) = error as? StateStoreError else {
                        return XCTFail("Expected migrationFailed, got \(error).")
                    }
                    XCTAssertEqual(version, 1)
                    XCTAssertTrue(message.contains("Recorded checksum tampered"))
                }
            }
        }
    }

    func testExplicitMigrationRefusesExistingNonHostwrightDatabase() throws {
        try withTemporaryStore { store, databaseURL in
            let connection = try SQLiteConnection(path: databaseURL.path)
            try connection.execute("CREATE TABLE unrelated (id TEXT PRIMARY KEY)")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)

            XCTAssertThrowsError(try store.migrate()) { error in
                guard case .incompatibleSchema(let foundVersion, let latestSupported, let message) = error as? StateStoreError else {
                    return XCTFail("Expected incompatibleSchema, got \(error).")
                }
                XCTAssertNil(foundVersion)
                XCTAssertEqual(latestSupported, MigrationRunner.latestSchemaVersion)
                XCTAssertTrue(message.contains("non-Hostwright tables"))
            }
        }
    }

    func testOpeningDirectoryAsDatabaseFailsSafely() throws {
        try withTemporaryDirectory { directory in
            let invalidStore = SQLiteStateStore(path: directory.path)

            XCTAssertThrowsError(try invalidStore.migrate()) { error in
                XCTAssertTrue(String(describing: error).contains("regular non-symlink file"))
            }
        }
    }
}
