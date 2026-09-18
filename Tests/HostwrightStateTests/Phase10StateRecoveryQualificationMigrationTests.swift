import Foundation
import XCTest

import HostwrightCore
import HostwrightScheduler
// @testable is limited to setup-only partial migration and future-ledger
// staging; assertions exercise public SQLiteStateStore and StateUpgradeService APIs.
@testable import HostwrightState

final class Phase10StateRecoveryQualificationMigrationTests: XCTestCase {
    func testPhase10V21ToV22MigrationIsContiguousAcrossReopen() throws {
        guard MigrationRunner.latestSchemaVersion >= 22 else {
            throw XCTSkip(
                "Pending prerequisite: this build exposes state schema \(MigrationRunner.latestSchemaVersion), so the public v21→v22 migration contract is unavailable."
            )
        }

        try withTemporaryStore(throughVersion: 21) { store, _ in
            XCTAssertEqual(try store.schemaVersion(), 21)

            // Setup-only gap: the public store API migrates to latest, so the
            // test-only partial runner creates the v21 checkpoint before the
            // public reopen contract is exercised.
            try MigrationRunner().apply(to: store, throughVersion: 22)

            XCTAssertEqual(try store.schemaVersion(), 22)
            let reopened = SQLiteStateStore(path: store.path)
            XCTAssertEqual(try reopened.schemaVersion(), 22)

            let versionConnection = try SQLiteConnection(
                path: reopened.path,
                createIfNeeded: false,
                readOnly: true,
                profile: .portableArtifact
            )
            let versions = try versionConnection.query(
                "SELECT version FROM schema_migrations ORDER BY version ASC"
            ).compactMap { $0.first ?? nil }.compactMap(Int.init)
            try versionConnection.close()
            XCTAssertEqual(versions, Array(1...22))
        }
    }

    func testPhase10V22MigrationReachesPublicLatestSchema() throws {
        XCTAssertGreaterThanOrEqual(MigrationRunner.latestSchemaVersion, 23)
        try withTemporaryStore(throughVersion: 22) { store, _ in
            try store.migrate()
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
            try store.migrate()
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
            try store.validateSchema()
        }
    }

    func testPhase10SchedulerStateSurvivesV23UpgradeAndReopen() throws {
        XCTAssertGreaterThan(MigrationRunner.latestSchemaVersion, 23)
        try withTemporaryStore(throughVersion: 23) { store, _ in
            let snapshot = try SchedulerNodeCapacitySnapshot(
                nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000a31")!,
                capacity: try ResourceVector(["cpu": 4]),
                generation: 1,
                observedAt: "2026-08-05T12:00:00Z"
            )
            // The current repository refuses writes to old schemas; stage the v23 row only.
            let connection = try SQLiteConnection(
                path: store.path, createIfNeeded: false, profile: .portableArtifact
            )
            try connection.run(
                """
                INSERT INTO scheduler_node_capacity_snapshots (
                    node_uuid, capacity_json, capacity_digest, generation, observed_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(snapshot.nodeID.uuidString.lowercased()),
                    .text(SchedulerAdmissionCanonicalJSON.vectorJSON(snapshot.capacity)),
                    .text(snapshot.capacityDigest), .int64(snapshot.generation),
                    .text(snapshot.observedAt), .text(snapshot.observedAt),
                ]
            )
            try connection.close()
            let prepared = try StateUpgradeService(store: store)
                .migrateToLatestWithVerifiedBackup()
            XCTAssertEqual(prepared.migration.fromSchemaVersion, 23)
            XCTAssertEqual(prepared.migration.toSchemaVersion, MigrationRunner.latestSchemaVersion)
            let backup = try XCTUnwrap(prepared.rollbackSnapshot)
            XCTAssertEqual(backup.stateSchemaVersion, 23)
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
            let reopened = SQLiteStateStore(path: store.path)
            XCTAssertEqual(
                try reopened.schedulerAdmissions.nodeCapacity(nodeID: snapshot.nodeID),
                snapshot
            )
            try reopened.validateSchema()
            try reopened.migrate()
            XCTAssertEqual(try reopened.schemaVersion(), MigrationRunner.latestSchemaVersion)
        }
    }

    func testPhase10UpgradeUsesVerifiedBackupAndReopensAfterRestore() throws {
        guard MigrationRunner.latestSchemaVersion >= 22 else {
            throw XCTSkip(
                "Pending prerequisite: verified Phase 10 upgrade qualification starts at schema v21 and requires a public v22 migration."
            )
        }

        try withTemporaryStore(throughVersion: 21) { store, _ in
            let service = StateUpgradeService(store: store)
            let prepared = try service.migrateToLatestWithVerifiedBackup()

            XCTAssertEqual(prepared.migration.fromSchemaVersion, 21)
            XCTAssertEqual(
                prepared.migration.toSchemaVersion,
                MigrationRunner.latestSchemaVersion
            )
            let snapshot = try XCTUnwrap(prepared.rollbackSnapshot)
            XCTAssertEqual(snapshot.stateSchemaVersion, 21)
            XCTAssertEqual(snapshot.databasePath, store.path)
            XCTAssertGreaterThan(snapshot.databaseBytes, 0)
            XCTAssertEqual(snapshot.databaseSHA256.count, 64)
            XCTAssertNoThrow(try service.verify(snapshot))

            let reopened = SQLiteStateStore(path: store.path)
            XCTAssertEqual(
                try reopened.schemaVersion(),
                MigrationRunner.latestSchemaVersion
            )

            let restoredVersion = try service.restoreVerifiedSnapshot(
                snapshot,
                operationID: "00000000-0000-0000-0000-000000001001"
            )
            XCTAssertEqual(restoredVersion, 21)
            let restoredImmediately = try StateMaintenanceFileSupport.fingerprint(store.path)
            XCTAssertEqual(restoredImmediately.sha256, snapshot.databaseSHA256)
            XCTAssertEqual(try store.schemaVersion(), 21)
            let restoredRevision = try service.verifiedRevision()
            XCTAssertEqual(restoredRevision?.stateSchemaVersion, 21)
            let checkpointedFingerprint = try StateMaintenanceFileSupport.fingerprint(store.path)
            XCTAssertEqual(
                restoredRevision?.databaseSHA256,
                checkpointedFingerprint.sha256
            )

            let reopenedRestored = SQLiteStateStore(path: store.path)
            XCTAssertEqual(try reopenedRestored.schemaVersion(), 21)
        }
    }

    func testPhase10FutureSchemaRefusalPrecedesStateAndSchedulerReads() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            let futureVersion = MigrationRunner.latestSchemaVersion + 1
            // Setup-only gap: there is no public API for inserting an unknown
            // migration ledger row; SQLite is used only to stage the future
            // version before asserting public fail-closed reads and writes.
            let connection = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            try connection.run(
                """
                INSERT INTO schema_migrations (version, description, checksum, applied_at)
                VALUES (?, 'future qualification schema', 'future-checksum', ?)
                """,
                bindings: [
                    .int(futureVersion),
                    .text("2026-08-05T12:00:00Z"),
                ]
            )
            try connection.close()

            let actions: [() throws -> Void] = [
                { try store.validateSchema() },
                { _ = try store.schemaVersion() },
                { _ = try store.events.loadAll() },
                {
                    _ = try store.schedulerAdmissions.nodeCapacity(
                        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
                    )
                },
                { try store.migrate() },
            ]

            for action in actions {
                XCTAssertThrowsError(try action()) { error in
                    guard case .incompatibleSchema(
                        let foundVersion,
                        let latestSupported,
                        let message
                    ) = error as? StateStoreError else {
                        return XCTFail("Expected future-schema refusal, got \(error).")
                    }
                    XCTAssertEqual(foundVersion, futureVersion)
                    XCTAssertEqual(latestSupported, MigrationRunner.latestSchemaVersion)
                    XCTAssertTrue(message.contains("newer Hostwright release"), message)
                }
            }
        }
    }

    private func withTemporaryStore(
        throughVersion: Int,
        _ body: (SQLiteStateStore, URL) throws -> Void
    ) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-phase10-state-recovery-parent-\(UUID().uuidString)",
            isDirectory: true
        )
        let directory = parent.appendingPathComponent("phase10-state", isDirectory: true)
        try validatePhase10Root(parent, ownedChild: directory)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinel = parent.appendingPathComponent("caller-owned-sentinel")
        try Data("caller-owned".utf8).write(to: sentinel)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sentinel.path
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            removeIfPresent(directory)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.path),
                "Phase10 temporary root leaked: \(directory.path)"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: sentinel.path),
                "Caller-owned sentinel was removed by Phase10 cleanup: \(sentinel.path)"
            )
            removeIfPresent(sentinel)
            removeIfPresent(parent)
        }

        let store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        try MigrationRunner().apply(to: store, throughVersion: throughVersion)
        try body(store, directory)
    }

    private func removeIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        } catch {
            XCTFail("Phase10 cleanup failed for \(url.path): \(error)")
        }
    }

    private func validatePhase10Root(_ parent: URL, ownedChild: URL) throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let normalizedParent = parent.standardizedFileURL.path.lowercased()
        let normalizedChild = ownedChild.standardizedFileURL.path.lowercased()
        guard parent.standardizedFileURL.path.hasPrefix(temporaryRoot.path),
              normalizedParent.contains("hostwright-phase10"),
              normalizedChild.contains("phase10-state"),
              !normalizedParent.contains("phase08"),
              !normalizedParent.contains("phase09"),
              !normalizedParent.contains("evidence") else {
            throw NSError(
                domain: "HostwrightPhase10Isolation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Phase10 state qualification root (parent.path)"]
            )
        }
    }
}
