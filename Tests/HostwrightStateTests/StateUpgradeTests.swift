import Foundation
import Synchronization
import XCTest
@testable import HostwrightState

final class StateUpgradeTests: XCTestCase {
    func testExclusiveLifecycleFenceRejectsConcurrentWriterAndAllowsNestedStateWork() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            let finished = expectation(description: "concurrent state writer refused")
            let outcome = Mutex<String?>(nil)

            try StateUpgradeService(store: store).withExclusiveLifecycleFence {
                XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try store.migrate()
                        outcome.withLock { $0 = "unexpected-success" }
                    } catch {
                        outcome.withLock { $0 = String(describing: error) }
                    }
                    finished.fulfill()
                }
                wait(for: [finished], timeout: 2)
            }

            let result = try XCTUnwrap(outcome.withLock { $0 })
            XCTAssertNotEqual(result, "unexpected-success")
            XCTAssertTrue(result.contains("state-access fence"), result)
            XCTAssertNoThrow(try store.migrate())
        }
    }

    func testVerifiedStateRemovalDeletesOnlyTheManagedSQLiteFileSet() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            let result = try StateDatabaseRemovalService(store: store).removeVerifiedDatabase()

            XCTAssertEqual(result.kind, "stateDatabaseRemovalResult")
            XCTAssertEqual(result.databasePath, store.path)
            XCTAssertTrue(result.removedPaths.contains(store.path))
            XCTAssertEqual(result.removedPaths, result.removedPaths.sorted())
            for path in result.removedPaths {
                XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        }
    }

    func testVerifiedStateRemovalRefusesForeignSQLiteWithoutDeletingIt() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            let foreignID = 0x0BAD_F00D
            let connection = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            try connection.execute("PRAGMA application_id = \(foreignID)")
            try connection.close()
            let before = try StateMaintenanceFileSupport.fingerprint(store.path)

            XCTAssertThrowsError(
                try StateDatabaseRemovalService(store: store).removeVerifiedDatabase()
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
            XCTAssertEqual(try StateMaintenanceFileSupport.fingerprint(store.path), before)
        }
    }

    func testVerifiedPreMigrationSnapshotMigratesAndRestoresExactPriorSchema() throws {
        try withTemporaryStore(throughVersion: 6) { store, directory in
            let snapshotURL = directory.appendingPathComponent("rollback/state.sqlite")
            try FileManager.default.createDirectory(
                at: snapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let service = StateUpgradeService(store: store)

            let snapshot = try service.createVerifiedSnapshot(at: snapshotURL.path)
            XCTAssertEqual(snapshot.kind, "stateUpgradeSnapshot")
            XCTAssertEqual(snapshot.stateSchemaVersion, 6)
            XCTAssertEqual(snapshot.databaseSHA256.count, 64)
            XCTAssertGreaterThan(snapshot.databaseBytes, 0)
            XCTAssertEqual(permissions(snapshotURL.path), 0o600)
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path + "-wal"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path + "-shm"))

            let migration = try service.migrateToLatest()
            XCTAssertEqual(migration.fromSchemaVersion, 6)
            XCTAssertEqual(migration.toSchemaVersion, MigrationRunner.latestSchemaVersion)
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)

            let operationID = "00000000-0000-0000-0000-000000000001"
            let restoreStage = URL(
                fileURLWithPath: (store.path as NSString).deletingLastPathComponent,
                isDirectory: true
            ).appendingPathComponent(
                ".hostwright-state-upgrade-restore-\(operationID).sqlite"
            )

            XCTAssertThrowsError(
                try StateUpgradeService(
                    store: store,
                    testInterruption: .afterRestorePublishedAndVerified
                ).restoreVerifiedSnapshot(snapshot, operationID: operationID)
            ) { error in
                XCTAssertEqual(
                    error as? StateUpgradeTestInterruption,
                    .afterRestorePublishedAndVerified
                )
            }
            XCTAssertEqual(try store.schemaVersion(), 6)
            XCTAssertEqual(
                try StateMaintenanceFileSupport.fingerprint(store.path).sha256,
                snapshot.databaseSHA256
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: restoreStage.path))

            let restoredVersion = try service.restoreVerifiedSnapshot(
                snapshot,
                operationID: operationID
            )
            XCTAssertEqual(restoredVersion, 6)
            XCTAssertEqual(try store.schemaVersion(), 6)
            XCTAssertEqual(
                try StateMaintenanceFileSupport.fingerprint(store.path).sha256,
                snapshot.databaseSHA256
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: restoreStage.path))

            let secondMigration = try service.migrateToLatest()
            XCTAssertEqual(secondMigration.fromSchemaVersion, 6)
            XCTAssertEqual(secondMigration.toSchemaVersion, MigrationRunner.latestSchemaVersion)
        }
    }

    func testTamperedUpgradeSnapshotCannotReplaceCurrentState() throws {
        try withTemporaryStore(throughVersion: 6) { store, directory in
            let rollback = directory.appendingPathComponent("rollback", isDirectory: true)
            try FileManager.default.createDirectory(
                at: rollback,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let service = StateUpgradeService(store: store)
            let snapshot = try service.createVerifiedSnapshot(
                at: rollback.appendingPathComponent("state.sqlite").path
            )
            _ = try service.migrateToLatest()
            let currentDigest = try StateMaintenanceFileSupport.fingerprint(store.path).sha256

            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: snapshot.snapshotPath))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("tamper".utf8))
            try handle.close()

            XCTAssertThrowsError(
                try service.restoreVerifiedSnapshot(
                    snapshot,
                    operationID: "00000000-0000-0000-0000-000000000002"
                )
            )
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
            XCTAssertEqual(try StateMaintenanceFileSupport.fingerprint(store.path).sha256, currentDigest)
        }
    }

    private func withTemporaryStore(
        throughVersion: Int,
        _ body: (SQLiteStateStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-state-upgrade-\(UUID().uuidString)", isDirectory: true)
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
