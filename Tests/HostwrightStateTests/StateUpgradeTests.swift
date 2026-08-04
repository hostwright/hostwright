import Foundation
import Synchronization
import XCTest
@testable import HostwrightCore
@testable import HostwrightState

final class StateUpgradeTests: XCTestCase {
    func testSchemaV16MigratesRestartBudgetsToV17WithSafeDefaults() throws {
        try withTemporaryStore(throughVersion: 16) { store, _ in
            try store.withConnection { connection in
                try connection.run(
                    """
                    INSERT INTO projects (id, name, manifest_hash, created_at, updated_at)
                    VALUES ('project-demo', 'demo', 'manifest', '2026-08-01T12:00:00Z', '2026-08-01T12:00:00Z')
                    """
                )
                try connection.run(
                    """
                    INSERT INTO restart_policy_state (
                        id, project_id, service_name, policy, status, attempt_count,
                        max_attempts, backoff_seconds, backoff_until, last_failure_at,
                        updated_at, metadata_json_redacted
                    ) VALUES (
                        'restart-api', 'project-demo', 'api', 'onFailure', 'backingOff',
                        1, 3, 60, '2026-08-01T12:01:00Z', '2026-08-01T12:00:00Z',
                        '2026-08-01T12:00:00Z', '{}'
                    )
                    """
                )
            }

            try MigrationRunner().apply(to: store, throughVersion: 17)
            XCTAssertEqual(try store.schemaVersion(), 17)
            try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
                let row = try XCTUnwrap(
                    connection.query(
                        """
                        SELECT reason_class, window_started_at, window_seconds,
                               project_max_attempts, release_generation, policy_sha256
                        FROM restart_policy_state WHERE id = 'restart-api'
                        """
                    ).first)
                XCTAssertEqual(
                    row.compactMap { $0 },
                    [
                        "unknown", "2026-08-01T12:00:00Z", "300", "10", "0",
                        String(repeating: "0", count: 64),
                    ]
                )
                XCTAssertEqual(
                    try connection.query("SELECT id FROM restart_attempt_history"),
                    []
                )
            }
            try store.migrate()
            XCTAssertEqual(
                try store.schemaVersion(),
                HostwrightContractVersions.stateSchema
            )
            XCTAssertEqual(try store.restartAttempts.loadProject("project-demo"), [])
        }
    }

    func testSchemaV13MigratesAdditivelyToV14ContentCacheState()
        throws
    {
        try withTemporaryStore(throughVersion: 13) { store, _ in
            try store.withConnection { connection in
                try connection.run(
                    """
                    INSERT INTO oci_referrer_cache_objects (
                        digest, media_type, size_bytes, object_kind,
                        payload_base64, payload_sha256, children_json,
                        created_at, last_accessed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(
                            "sha256:6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d"
                        ),
                        .text("application/octet-stream"),
                        .int(1), .text("blob"),
                        .text(Data([0]).base64EncodedString()),
                        .text(
                            "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d"
                        ),
                        .text("[]"),
                        .text("2026-07-25T12:00:00Z"),
                        .text("2026-07-25T12:01:00Z")
                    ]
                )
            }

            try store.migrate()

            XCTAssertEqual(
                try store.schemaVersion(),
                HostwrightContractVersions.stateSchema
            )
            XCTAssertEqual(
                try store.contentCache.listContent(),
                [
                    ContentCacheRecord(
                        providerScope: "oci-referrer-cache",
                        digest:
                            "sha256:6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d",
                        kind: .ociCacheObject,
                        sizeBytes: 1,
                        createdAt: "2026-07-25T12:00:00Z",
                        observedAt: "2026-07-25T12:01:00Z",
                        lastUsedAt: "2026-07-25T12:01:00Z"
                    )
                ]
            )
            let report = StateIntegrityService(store: store).inspect()
            XCTAssertNotEqual(
                report.health,
                .unrecoverable,
                String(describing: report.checks)
            )
        }
    }

    func testSchemaV10MigratesToV11ImageSBOMStateWithoutGaps()
        throws
    {
        try withTemporaryStore(throughVersion: 10) { store, _ in
            XCTAssertEqual(try store.schemaVersion(), 10)

            try store.migrate()

            XCTAssertEqual(
                try store.schemaVersion(),
                HostwrightContractVersions.stateSchema
            )
            let evidence = try store.withConnection(
                createIfNeeded: false,
                readOnly: true
            ) { connection in
                let versions = try connection.query(
                    """
                    SELECT version
                    FROM schema_migrations
                    ORDER BY version
                    """
                ).compactMap { $0.first ?? nil }.compactMap(Int.init)
                let tables = Set(
                    try connection.query(
                        """
                        SELECT name
                        FROM sqlite_master
                        WHERE type = 'table'
                          AND name LIKE 'image_sbom%'
                        ORDER BY name
                        """
                    ).compactMap { $0.first ?? nil }
                )
                return (versions, tables)
            }
            XCTAssertEqual(
                evidence.0,
                Array(1...HostwrightContractVersions.stateSchema)
            )
            XCTAssertEqual(evidence.1, Set(["image_sbom_records"]))
        }
    }

    func testSchemaV8MigratesThroughV11ReferrerStateWithoutGaps()
        throws
    {
        try withTemporaryStore(throughVersion: 8) { store, _ in
            XCTAssertEqual(try store.schemaVersion(), 8)

            try store.migrate()

            XCTAssertEqual(
                try store.schemaVersion(),
                HostwrightContractVersions.stateSchema
            )
            let evidence = try store.withConnection(
                createIfNeeded: false,
                readOnly: true
            ) { connection in
                let versions = try connection.query(
                    """
                    SELECT version
                    FROM schema_migrations
                    ORDER BY version
                    """
                ).compactMap { $0.first ?? nil }.compactMap(Int.init)
                let tables = Set(
                    try connection.query(
                        """
                        SELECT name
                        FROM sqlite_master
                        WHERE type = 'table'
                          AND name LIKE 'oci_referrer%'
                        ORDER BY name
                        """
                    ).compactMap { $0.first ?? nil }
                )
                return (versions, tables)
            }
            XCTAssertEqual(
                evidence.0,
                Array(1...HostwrightContractVersions.stateSchema)
            )
            XCTAssertEqual(evidence.1, Set([
                "oci_referrer_cache_objects",
                "oci_referrer_discoveries",
                "oci_referrer_graph_objects",
                "oci_referrer_publications",
                "oci_referrer_retention_leases",
                "oci_referrers"
            ]))
        }
    }

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

    func testSynchronousExclusiveLifecycleFenceAuthorityPropagatesToInheritingTask() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            let outcome = TaskOutcome()

            try StateUpgradeService(store: store).withExclusiveLifecycleFence {
                Task { [store, outcome] in
                    do {
                        let version = try store.schemaVersion()
                        outcome.record(
                            version == MigrationRunner.latestSchemaVersion
                                ? "success" : "unexpected-schema-version"
                        )
                    } catch {
                        outcome.record(String(describing: error))
                    }
                    outcome.finish()
                }
                XCTAssertEqual(outcome.wait(timeout: .now() + 2), .success)
            }

            XCTAssertEqual(outcome.value, "success")
        }
    }

    func testInheritedLifecycleFenceAuthorityIsRevokedWhenTheFenceReturns() async throws {
        try await withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) {
            store, _ in
            try store.configuration.prepareStateAccessFoundation()
            let lockPath = try store.configuration.maintenancePaths().accessLockPath

            let escaped = try StateUpgradeService(store: store).withExclusiveLifecycleFence {
                Task { [store] in
                    try? await Task.sleep(for: .milliseconds(100))
                    do {
                        _ = try store.schemaVersion()
                        return "unexpected-success"
                    } catch {
                        return String(describing: error)
                    }
                }
            }

            let descriptor = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            let outcome = await escaped.value
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)

            XCTAssertNotEqual(outcome, "unexpected-success")
            XCTAssertTrue(outcome.contains("state-access fence"), outcome)
        }
    }

    func testAsyncLifecycleFenceAllowsNestedAccessAcrossAwaitAndExcludesCompetingAccessor()
        async throws
    {
        try await withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) {
            store, _ in
            let service = StateUpgradeService(store: store)

            try await service.withExclusiveLifecycleFence {
                try await Task.sleep(for: .milliseconds(10))
                XCTAssertEqual(
                    try store.schemaVersion(),
                    MigrationRunner.latestSchemaVersion
                )

                let competing = Task.detached { () -> String in
                    do {
                        try store.migrate()
                        return "unexpected-success"
                    } catch {
                        return String(describing: error)
                    }
                }
                let outcome = await competing.value
                XCTAssertNotEqual(outcome, "unexpected-success")
                XCTAssertTrue(outcome.contains("state-access fence"), outcome)
            }

            XCTAssertNoThrow(try store.migrate())
        }
    }

    func testBoundedStateAccessWaitPropagatesAcrossAwaitWithoutBypassingTheFence()
        async throws
    {
        try await withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) {
            store, _ in
            try store.configuration.prepareStateAccessFoundation()
            let lockPath = try store.configuration.maintenancePaths().accessLockPath
            let descriptor = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            let release = Task.detached {
                try? await Task.sleep(for: .milliseconds(400))
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
            }

            let version = try await StateUpgradeService(store: store)
                .withBoundedStateAccessWait(lockWaitMilliseconds: 1_000) {
                    try await StateUpgradeService(store: store)
                        .withBoundedStateAccessWait(lockWaitMilliseconds: 100) {
                            try await Task.sleep(for: .milliseconds(10))
                            return try store.schemaVersion()
                        }
                }
            await release.value
            XCTAssertEqual(version, MigrationRunner.latestSchemaVersion)
        }
    }

    func testBoundedStateAccessWaitRejectsUnboundedWaits() async throws {
        try await withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) {
            store, _ in
            for timeout in [0, 30_001] {
                do {
                    try await StateUpgradeService(store: store)
                        .withBoundedStateAccessWait(lockWaitMilliseconds: timeout) {}
                    XCTFail("Expected invalidRecord for \(timeout) milliseconds.")
                } catch {
                    guard case StateStoreError.invalidRecord = error else {
                        return XCTFail("Expected invalidRecord, received \(error).")
                    }
                }
            }
        }
    }

    func testExclusiveLifecycleFenceSupportsBoundedControlPlaneWait() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            try store.configuration.prepareStateAccessFoundation()
            let lockPath = try store.configuration.maintenancePaths().accessLockPath
            let descriptor = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            let released = expectation(description: "competing writer released")
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
                released.fulfill()
            }

            XCTAssertNoThrow(
                try StateUpgradeService(store: store).withExclusiveLifecycleFence(
                    lockWaitMilliseconds: 1_000
                ) {
                    XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
                }
            )
            wait(for: [released], timeout: 1)
        }
    }

    func testExclusiveLifecycleFenceRejectsUnboundedWaits() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            for timeout in [0, 30_001] {
                XCTAssertThrowsError(
                    try StateUpgradeService(store: store).withExclusiveLifecycleFence(
                        lockWaitMilliseconds: timeout
                    ) {}
                ) { error in
                    guard case StateStoreError.invalidRecord = error else {
                        return XCTFail("Expected invalidRecord, received \(error).")
                    }
                }
            }
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

    func testVerifiedV16SnapshotMigratesAndRestoresExactPriorSchema() throws {
        try withTemporaryStore(throughVersion: 16) { store, directory in
            let snapshotURL = directory.appendingPathComponent("rollback/state.sqlite")
            try FileManager.default.createDirectory(
                at: snapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let service = StateUpgradeService(store: store)

            let snapshot = try service.createVerifiedSnapshot(at: snapshotURL.path)
            XCTAssertEqual(snapshot.kind, "stateUpgradeSnapshot")
            XCTAssertEqual(snapshot.stateSchemaVersion, 16)
            XCTAssertEqual(snapshot.databaseSHA256.count, 64)
            XCTAssertGreaterThan(snapshot.databaseBytes, 0)
            XCTAssertEqual(permissions(snapshotURL.path), 0o600)
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path + "-wal"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path + "-shm"))

            let migration = try service.migrateToLatest()
            XCTAssertEqual(migration.fromSchemaVersion, 16)
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
            XCTAssertEqual(try store.schemaVersion(), 16)
            XCTAssertEqual(
                try StateMaintenanceFileSupport.fingerprint(store.path).sha256,
                snapshot.databaseSHA256
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: restoreStage.path))

            let restoredVersion = try service.restoreVerifiedSnapshot(
                snapshot,
                operationID: operationID
            )
            XCTAssertEqual(restoredVersion, 16)
            XCTAssertEqual(try store.schemaVersion(), 16)
            XCTAssertEqual(
                try StateMaintenanceFileSupport.fingerprint(store.path).sha256,
                snapshot.databaseSHA256
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: restoreStage.path))

            let secondMigration = try service.migrateToLatest()
            XCTAssertEqual(secondMigration.fromSchemaVersion, 16)
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

    func testV17SnapshotMigratesToLatestAndRestoresExactV17() throws {
        try withTemporaryStore(throughVersion: 17) { store, directory in
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
            XCTAssertEqual(snapshot.stateSchemaVersion, 17)
            XCTAssertEqual(
                try service.migrateToLatest().toSchemaVersion,
                MigrationRunner.latestSchemaVersion
            )
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)

            XCTAssertEqual(
                try service.restoreVerifiedSnapshot(
                    snapshot,
                    operationID: "00000000-0000-0000-0000-000000000018"
                ),
                17
            )
            XCTAssertEqual(try store.schemaVersion(), 17)
            XCTAssertEqual(
                try StateMaintenanceFileSupport.fingerprint(store.path).sha256,
                snapshot.databaseSHA256
            )
        }
    }

    func testV17MigrationCreatesVerifiedRollbackPackageAndReachesLatestSchema() throws {
        try withTemporaryStore(throughVersion: 17) { store, directory in
            let service = StateUpgradeService(store: store)

            let result = try service.migrateToLatestWithVerifiedBackup()

            XCTAssertEqual(result.kind, "stateUpgradePreparedMigrationResult")
            XCTAssertEqual(result.migration.fromSchemaVersion, 17)
            XCTAssertEqual(
                result.migration.toSchemaVersion,
                MigrationRunner.latestSchemaVersion
            )
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)

            let snapshot = try XCTUnwrap(result.rollbackSnapshot)
            XCTAssertEqual(snapshot.databasePath, store.path)
            XCTAssertEqual(snapshot.stateSchemaVersion, 17)
            XCTAssertGreaterThan(snapshot.databaseBytes, 0)
            XCTAssertEqual(snapshot.databaseSHA256.count, 64)
            XCTAssertNoThrow(try service.verify(snapshot))

            let rollbackDirectory = URL(fileURLWithPath: snapshot.snapshotPath)
                .deletingLastPathComponent()
            let rollbackRoot = directory.appendingPathComponent(
                ".hostwright-state-upgrades",
                isDirectory: true
            )
            let manifestURL = rollbackDirectory.appendingPathComponent("snapshot-v1.json")
            XCTAssertEqual(rollbackDirectory.deletingLastPathComponent(), rollbackRoot)
            XCTAssertEqual(permissions(rollbackRoot.path), 0o700)
            XCTAssertEqual(permissions(rollbackDirectory.path), 0o700)
            XCTAssertEqual(permissions(snapshot.snapshotPath), 0o600)
            XCTAssertEqual(permissions(manifestURL.path), 0o600)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    StateUpgradeSnapshot.self,
                    from: Data(contentsOf: manifestURL)
                ),
                snapshot
            )
        }
    }

    func testAbsentDatabaseInitializesLatestWithoutRollbackSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-state-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        let rollbackRoot = directory.appendingPathComponent(
            ".hostwright-state-upgrades",
            isDirectory: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackRoot.path))

        let result = try StateUpgradeService(store: store).migrateToLatestWithVerifiedBackup()

        XCTAssertEqual(result.kind, "stateUpgradePreparedMigrationResult")
        XCTAssertEqual(
            result.migration.fromSchemaVersion,
            MigrationRunner.latestSchemaVersion
        )
        XCTAssertEqual(
            result.migration.toSchemaVersion,
            MigrationRunner.latestSchemaVersion
        )
        XCTAssertNil(result.rollbackSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackRoot.path))
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

    private func withTemporaryStore(
        throughVersion: Int,
        _ body: (SQLiteStateStore, URL) async throws -> Void
    ) async throws {
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
        try await body(store, directory)
    }

    private func permissions(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private final class TaskOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var storedValue: String?

    func record(_ value: String) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func finish() {
        completion.signal()
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        completion.wait(timeout: timeout)
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}
