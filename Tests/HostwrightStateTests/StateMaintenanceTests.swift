import Darwin
import Foundation
import XCTest
@testable import HostwrightState

private actor StateMaintenanceCancellationGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

final class StateMaintenanceTests: XCTestCase {
    func testIntegrityAndVerifiedOnlineBackupRoundTrip() throws {
        try withStore { store, _ in
            try appendEvent("before-backup", to: store)
            let maintenance = try StateMaintenanceService(store: store)

            let integrity = maintenance.integrity()
            XCTAssertEqual(integrity.health, .healthy)
            XCTAssertEqual(integrity.stateSchemaVersion, MigrationRunner.latestSchemaVersion)
            XCTAssertTrue(integrity.checks.allSatisfy { $0.status == .passed })

            let backup = try maintenance.createBackup()
            XCTAssertTrue(backup.restorable)
            XCTAssertEqual(backup.stateSchemaVersion, MigrationRunner.latestSchemaVersion)
            XCTAssertEqual(backup.databaseSHA256?.count, 64)
            XCTAssertGreaterThan(backup.databaseBytes ?? 0, 0)

            let catalog = try maintenance.backupCatalog()
            XCTAssertEqual(catalog.backups, [backup])
            let backupDirectory = maintenance.paths.backupDirectory + "/" + backup.backupID
            XCTAssertEqual(permissions(backupDirectory), 0o700)
            XCTAssertEqual(permissions(backupDirectory + "/state.sqlite"), 0o600)
            XCTAssertEqual(permissions(backupDirectory + "/manifest.json"), 0o600)
        }
    }

    func testConfirmedRestoreIsBoundToCurrentStateAndClearsRebuildableProjections() throws {
        try withStore { store, _ in
            try appendEvent("before-backup", to: store)
            try insertValidProjections(store.path)
            let maintenance = try StateMaintenanceService(store: store)
            let backup = try maintenance.createBackup()
            try appendEvent("after-backup", to: store)

            let plan = try maintenance.restorePlan(backupID: backup.backupID)
            let result = try maintenance.restore(
                backupID: backup.backupID,
                confirmationToken: plan.confirmationToken
            )

            XCTAssertEqual(result.health, .healthy)
            XCTAssertNotNil(result.preRestoreBackupID)
            XCTAssertNil(result.quarantinedDatabasePath)
            XCTAssertEqual(result.clearedProjectionRows["observed_runtime_snapshots"], 1)
            XCTAssertEqual(result.clearedProjectionRows["observed_services"], 1)
            let ids = try store.events.loadAll().map(\.id)
            XCTAssertTrue(ids.contains("before-backup"))
            XCTAssertFalse(ids.contains("after-backup"))
            XCTAssertTrue(ids.contains { $0.hasPrefix("state-restore-") })
            XCTAssertEqual(try rowCount("observed_runtime_snapshots", path: store.path), 0)
            XCTAssertEqual(try rowCount("observed_services", path: store.path), 0)
            XCTAssertEqual(maintenance.integrity().health, .healthy)
        }
    }

    func testRestoreConfirmationRefusesStateChangedAfterDryRun() throws {
        try withStore { store, _ in
            try appendEvent("before-backup", to: store)
            let maintenance = try StateMaintenanceService(store: store)
            let backup = try maintenance.createBackup()
            let plan = try maintenance.restorePlan(backupID: backup.backupID)
            try appendEvent("after-plan", to: store)

            XCTAssertThrowsError(
                try maintenance.restore(
                    backupID: backup.backupID,
                    confirmationToken: plan.confirmationToken
                )
            ) { error in
                XCTAssertEqual(error as? StateMaintenanceError, .confirmationMismatch)
            }
            XCTAssertTrue(try store.events.loadAll().contains { $0.id == "after-plan" })
        }
    }

    func testRestoreReplacesCorruptStateAndPreservesOriginalAsQuarantine() throws {
        try withStore { store, _ in
            try appendEvent("known-good", to: store)
            let maintenance = try StateMaintenanceService(store: store)
            let backup = try maintenance.createBackup()
            try Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: store.path))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)

            let plan = try maintenance.restorePlan(backupID: backup.backupID)
            XCTAssertEqual(plan.currentHealth, .unrecoverable)
            let result = try maintenance.restore(
                backupID: backup.backupID,
                confirmationToken: plan.confirmationToken
            )

            let quarantine = try XCTUnwrap(result.quarantinedDatabasePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine))
            XCTAssertEqual(try String(contentsOfFile: quarantine, encoding: .utf8), "not a sqlite database")
            XCTAssertEqual(maintenance.integrity().health, .healthy)
            XCTAssertTrue(try store.events.loadAll().contains { $0.id == "known-good" })
        }
    }

    func testRestoreCanRecreateADeletedDatabaseWithoutInventingAuthority() throws {
        try withStore { store, _ in
            try appendEvent("backup-authority", to: store)
            let maintenance = try StateMaintenanceService(store: store)
            let backup = try maintenance.createBackup()
            XCTAssertEqual(unlink(store.path), 0)

            let plan = try maintenance.restorePlan(backupID: backup.backupID)
            XCTAssertEqual(plan.currentHealth, .unrecoverable)
            let result = try maintenance.restore(
                backupID: backup.backupID,
                confirmationToken: plan.confirmationToken
            )

            XCTAssertEqual(result.health, .healthy)
            XCTAssertNil(result.preRestoreBackupID)
            XCTAssertNil(result.quarantinedDatabasePath)
            XCTAssertTrue(try store.events.loadAll().contains { $0.id == "backup-authority" })
            XCTAssertEqual(maintenance.integrity().health, .healthy)
        }
    }

    func testRestoreRefusesAnUnmanagedFileThatAppearsAfterAMissingStatePlan() throws {
        try withStore { store, directory in
            let maintenance = try StateMaintenanceService(store: store)
            let backup = try maintenance.createBackup()
            XCTAssertEqual(unlink(store.path), 0)
            let plan = try maintenance.restorePlan(backupID: backup.backupID)

            let unmanaged = directory.appendingPathComponent("operator-owned.sqlite").path
            try Data("operator evidence".utf8).write(to: URL(fileURLWithPath: unmanaged))
            XCTAssertEqual(chmod(unmanaged, 0o600), 0)
            XCTAssertEqual(link(unmanaged, store.path), 0)

            XCTAssertThrowsError(
                try maintenance.restore(
                    backupID: backup.backupID,
                    confirmationToken: plan.confirmationToken
                )
            ) { error in
                guard case .pathPolicyViolation(let path, let message) = error as? StateStoreError else {
                    return XCTFail("Expected pathPolicyViolation, got \(error)")
                }
                XCTAssertEqual(path, store.path)
                XCTAssertTrue(message.contains("multiply linked"))
            }
            XCTAssertEqual(
                try String(contentsOfFile: unmanaged, encoding: .utf8),
                "operator evidence"
            )
            XCTAssertEqual(
                try String(contentsOfFile: store.path, encoding: .utf8),
                "operator evidence"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: maintenance.paths.journalPath))
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    .filter {
                        $0.hasPrefix(".hostwright-restore-stage-")
                            || $0.hasPrefix(".hostwright-restore-displaced-")
                    },
                []
            )
        }
    }

    func testIntegrityClassifiesATruncatedSQLiteDatabaseAsUnrecoverable() throws {
        try withStore { store, _ in
            try appendLargeEvent(to: store)
            var bytes = try Data(contentsOf: URL(fileURLWithPath: store.path))
            XCTAssertGreaterThan(bytes.count, 4_096)
            bytes.removeSubrange((bytes.count / 2)..<bytes.count)
            try bytes.write(to: URL(fileURLWithPath: store.path))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: store.path
            )

            let report = try StateMaintenanceService(store: store).integrity()
            XCTAssertEqual(report.health, .unrecoverable)
            XCTAssertTrue(report.checks.contains { $0.status == .failed })
        }
    }

    func testRepairDeletesOnlyInvalidRebuildableProjectionRows() throws {
        try withStore { store, _ in
            try appendEvent("authoritative-event", to: store)
            try insertInvalidObservedProjection(store.path)
            let maintenance = try StateMaintenanceService(store: store)
            let before = maintenance.integrity()
            XCTAssertEqual(before.health, .degraded)
            XCTAssertEqual(
                before.repairableProjectionTables,
                ["observed_runtime_snapshots", "observed_services"]
            )

            let plan = try maintenance.repairPlan()
            XCTAssertEqual(plan.tables["observed_runtime_snapshots"], 1)
            XCTAssertEqual(plan.tables["observed_services"], 0)
            let result = try maintenance.repair(confirmationToken: plan.confirmationToken)

            XCTAssertEqual(result.health, .healthy)
            XCTAssertTrue(result.preRepairBackupID.hasPrefix("backup-"))
            XCTAssertTrue(try store.events.loadAll().contains { $0.id == "authoritative-event" })
            XCTAssertTrue(try store.events.loadAll().contains { $0.id.hasPrefix("state-repair-") })
            XCTAssertEqual(try rowCount("observed_runtime_snapshots", path: store.path), 0)
        }
    }

    func testRecoveryFinalizesRepairCommittedBeforeJournalCheckpoint() throws {
        try withStore { store, _ in
            try insertInvalidObservedProjection(store.path)
            let maintenance = try StateMaintenanceService(store: store)
            let plan = try maintenance.repairPlan()

            XCTAssertThrowsError(
                try maintenance.repairForTesting(
                    confirmationToken: plan.confirmationToken,
                    interruptAfterMutationBeforeJournal: true
                )
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: maintenance.paths.journalPath))
            XCTAssertThrowsError(try store.events.loadAll())

            let recovery = try maintenance.recover()
            XCTAssertTrue(recovery.recovered)
            XCTAssertEqual(recovery.health, .healthy)
            XCTAssertTrue(recovery.action.contains("committed projection repair"))
            XCTAssertTrue(try store.events.loadAll().contains { $0.id.hasPrefix("state-repair-") })
            XCTAssertFalse(FileManager.default.fileExists(atPath: maintenance.paths.journalPath))
        }
    }

    func testRepairRollbackFailurePreservesJournalUntilSafeRecovery() throws {
        try withStore { store, _ in
            try appendEvent("repair-rollback-authority", to: store)
            try insertInvalidObservedProjection(store.path)
            let maintenance = try StateMaintenanceService(store: store)
            let plan = try maintenance.repairPlan()

            XCTAssertThrowsError(
                try maintenance.repairForTesting(
                    confirmationToken: plan.confirmationToken,
                    interruptAfterMutationBeforeJournal: false,
                    failBeforeCommit: true,
                    rollbackForTesting: {
                        throw StateStoreError.ioFailure(
                            path: store.path,
                            message: "injected rollback failure"
                        )
                    }
                )
            ) { error in
                guard case .transactionOutcomeUncertain(let path, let message) = error as? StateStoreError else {
                    return XCTFail("Expected transactionOutcomeUncertain, got \(error)")
                }
                XCTAssertEqual(path, store.path)
                XCTAssertTrue(message.contains("mandatory rollback"))
            }

            XCTAssertTrue(FileManager.default.fileExists(atPath: maintenance.paths.journalPath))
            XCTAssertThrowsError(try store.events.loadAll()) { error in
                guard case .maintenanceRecoveryRequired(let journalPath) = error as? StateStoreError else {
                    return XCTFail("Expected maintenanceRecoveryRequired, got \(error)")
                }
                XCTAssertEqual(journalPath, maintenance.paths.journalPath)
            }

            let recovery = try maintenance.recover()
            XCTAssertTrue(recovery.recovered)
            XCTAssertEqual(recovery.health, .degraded)
            XCTAssertTrue(recovery.action.contains("Rolled back"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: maintenance.paths.journalPath))
            XCTAssertEqual(try rowCount("observed_runtime_snapshots", path: store.path), 1)
            XCTAssertEqual(try store.events.loadAll().map(\.id), ["repair-rollback-authority"])
        }
    }

    func testRepairRefusesAuthoritativeLogicalDamage() throws {
        try withStore { store, _ in
            try appendEvent("invalid-authoritative", payload: "not-json", to: store)
            let maintenance = try StateMaintenanceService(store: store)

            XCTAssertEqual(maintenance.integrity().health, .unrecoverable)
            XCTAssertThrowsError(try maintenance.repairPlan()) { error in
                guard case .unsafeRepair(let message) = error as? StateMaintenanceError else {
                    return XCTFail("Expected unsafeRepair, got \(error)")
                }
                XCTAssertTrue(message.contains("restoration"))
            }
            XCTAssertTrue(try store.events.loadAll().contains { $0.id == "invalid-authoritative" })
        }
    }

    func testCatalogDetectsTamperedBackupWithoutSilentlyDroppingIt() throws {
        try withStore { store, _ in
            let maintenance = try StateMaintenanceService(store: store)
            let backup = try maintenance.createBackup()
            let backupPath = maintenance.paths.backupDirectory + "/" + backup.backupID + "/state.sqlite"
            let descriptor = open(backupPath, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(Darwin.write(descriptor, "x", 1), 1)
            close(descriptor)

            let catalog = try maintenance.backupCatalog()
            XCTAssertEqual(catalog.backups.count, 1)
            XCTAssertEqual(catalog.backups[0].backupID, backup.backupID)
            XCTAssertFalse(catalog.backups[0].restorable)
            XCTAssertTrue(catalog.backups[0].verificationMessage.contains("digest or size"))
            XCTAssertThrowsError(try maintenance.restorePlan(backupID: backup.backupID))
        }
    }

    func testCatalogRootPolicyFailureReturnsAnErrorWithoutInventingAnEntry() throws {
        try withStore { store, _ in
            let maintenance = try StateMaintenanceService(store: store)
            let backup = try maintenance.createBackup()
            XCTAssertEqual(chmod(maintenance.paths.backupDirectory, 0o755), 0)

            XCTAssertThrowsError(try maintenance.backupCatalog()) { error in
                guard case .pathPolicyViolation(let path, let message) = error as? StateStoreError else {
                    return XCTFail("Expected pathPolicyViolation, got \(error)")
                }
                XCTAssertEqual(path, maintenance.paths.backupDirectory)
                XCTAssertTrue(message.contains("mode 0700"))
            }
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: maintenance.paths.backupDirectory + "/" + backup.backupID
                )
            )
            XCTAssertEqual(permissions(maintenance.paths.backupDirectory), 0o755)
        }
    }

    func testBackupCancellationAndDiskFullLeaveNoPublishedOrPartialArtifact() throws {
        try withStore { store, _ in
            try appendLargeEvent(to: store)
            let maintenance = try StateMaintenanceService(store: store)

            XCTAssertThrowsError(
                try maintenance.createBackupForTesting(shouldCancel: { true })
            ) { error in
                XCTAssertEqual(error as? StateMaintenanceError, .cancelled)
            }
            XCTAssertEqual(try backupEntries(maintenance.paths.backupDirectory), [])

            XCTAssertThrowsError(
                try maintenance.createBackupForTesting(destinationMaximumPages: 1)
            ) { error in
                guard case .sqlite(let message) = error as? StateMaintenanceError else {
                    return XCTFail("Expected SQLite backup failure, got \(error)")
                }
                XCTAssertTrue(message.contains("backup failed"))
            }
            XCTAssertEqual(try backupEntries(maintenance.paths.backupDirectory), [])
        }
    }

    func testPublicBackupObservesCurrentTaskCancellationWithoutArtifacts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-state-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try appendLargeEvent(to: store)
        let maintenance = try StateMaintenanceService(store: store)
        let gate = StateMaintenanceCancellationGate()
        let databasePath = store.path
        let task = Task.detached { () throws -> StateBackupRecord in
            await gate.wait()
            let service = try StateMaintenanceService(
                store: SQLiteStateStore(path: databasePath)
            )
            return try service.createBackup()
        }

        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("Expected the public backup operation to observe Task cancellation")
        } catch let error as StateMaintenanceError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Expected StateMaintenanceError.cancelled, got \(error)")
        }
        XCTAssertEqual(try backupEntries(maintenance.paths.backupDirectory), [])
    }

    func testBackupRefusesLockedAndFutureSchemaSourcesWithoutPublishingArtifacts() throws {
        try withStore { store, _ in
            let maintenance = try StateMaintenanceService(store: store)
            let writer = try SQLiteConnection(path: store.path, createIfNeeded: false)
            defer { try? writer.close() }

            try writer.execute("BEGIN EXCLUSIVE TRANSACTION")
            XCTAssertThrowsError(try maintenance.createBackup()) { error in
                guard case .databaseLocked(let path, _) = error as? StateStoreError else {
                    return XCTFail("Expected databaseLocked, got \(error)")
                }
                XCTAssertEqual(path, store.path)
            }
            try writer.execute("ROLLBACK")
            XCTAssertEqual(try backupEntries(maintenance.paths.backupDirectory), [])

            try writer.run(
                """
                INSERT INTO schema_migrations (version, description, checksum, applied_at)
                VALUES (8, 'future schema', 'future-checksum', '2026-07-13T12:00:00Z')
                """
            )
            XCTAssertThrowsError(try maintenance.createBackup()) { error in
                guard case .incompatibleSchema(let foundVersion, let latestSupported, _) = error as? StateStoreError else {
                    return XCTFail("Expected incompatibleSchema, got \(error)")
                }
                XCTAssertEqual(foundVersion, 8)
                XCTAssertEqual(latestSupported, MigrationRunner.latestSchemaVersion)
            }
            XCTAssertEqual(try backupEntries(maintenance.paths.backupDirectory), [])
        }
    }

    func testPendingMaintenanceJournalBlocksOrdinaryStateAccess() throws {
        try withStore { store, _ in
            let maintenance = try StateMaintenanceService(store: store)
            try Data("{}\n".utf8).write(to: URL(fileURLWithPath: maintenance.paths.journalPath))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: maintenance.paths.journalPath
            )

            XCTAssertThrowsError(try store.events.loadAll()) { error in
                XCTAssertEqual(
                    error as? StateStoreError,
                    .maintenanceRecoveryRequired(journalPath: maintenance.paths.journalPath)
                )
            }
            let displaced = store.path + ".displaced-test"
            try FileManager.default.moveItem(
                at: URL(fileURLWithPath: store.path),
                to: URL(fileURLWithPath: displaced)
            )
            XCTAssertThrowsError(try store.migrate()) { error in
                XCTAssertEqual(
                    error as? StateStoreError,
                    .maintenanceRecoveryRequired(journalPath: maintenance.paths.journalPath)
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: displaced))
        }
    }

    func testExclusiveStateAccessFenceBoundsConcurrentStateOperations() throws {
        try withStore { store, _ in
            let paths = try store.configuration.maintenancePaths()
            let descriptor = open(
                paths.accessLockPath,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { close(descriptor) }
            XCTAssertEqual(fchmod(descriptor, S_IRUSR | S_IWUSR), 0)
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            defer { _ = flock(descriptor, LOCK_UN) }

            XCTAssertThrowsError(try store.events.loadAll()) { error in
                guard case .databaseLocked(let path, let message) = error as? StateStoreError else {
                    return XCTFail("Expected databaseLocked, got \(error)")
                }
                XCTAssertEqual(path, store.path)
                XCTAssertTrue(message.contains("state-access fence"))
            }
        }
    }

    func testMissingDatabaseReadStillHonorsExclusiveStateAccessFenceWithoutCreatingDatabase() throws {
        try withStore { _, directory in
            let missingStore = SQLiteStateStore(
                path: directory.appendingPathComponent("missing.sqlite").path
            )
            try missingStore.configuration.prepareStateAccessFoundation()
            let paths = try missingStore.configuration.maintenancePaths()
            let descriptor = open(
                paths.accessLockPath,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { close(descriptor) }
            XCTAssertEqual(fchmod(descriptor, S_IRUSR | S_IWUSR), 0)
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            defer { _ = flock(descriptor, LOCK_UN) }

            XCTAssertThrowsError(try missingStore.events.loadAll()) { error in
                guard case .databaseLocked(let path, let message) = error as? StateStoreError else {
                    return XCTFail("Expected databaseLocked, got \(error)")
                }
                XCTAssertEqual(path, missingStore.path)
                XCTAssertTrue(message.contains("state-access fence"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: missingStore.path))
        }
    }

    func testRecoveryHandlesEveryDurableRestoreCheckpointWithoutInventingState() throws {
        for checkpoint in StateRestoreInterruptionCheckpoint.allCases {
            try withStore { store, directory in
                try appendEvent("before-backup", to: store)
                try insertValidProjections(store.path)
                let maintenance = try StateMaintenanceService(store: store)
                let backup = try maintenance.createBackup()
                try appendEvent("after-backup", to: store)
                let plan = try maintenance.restorePlan(backupID: backup.backupID)

                XCTAssertThrowsError(
                    try maintenance.restoreForTesting(
                        backupID: backup.backupID,
                        confirmationToken: plan.confirmationToken,
                        interruptAfter: checkpoint
                    ),
                    "checkpoint \(checkpoint.rawValue)"
                )
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: maintenance.paths.journalPath),
                    "checkpoint \(checkpoint.rawValue)"
                )
                XCTAssertThrowsError(try store.events.loadAll()) { error in
                    guard case .maintenanceRecoveryRequired = error as? StateStoreError else {
                        return XCTFail("Expected pending maintenance fence at \(checkpoint.rawValue), got \(error)")
                    }
                }

                let recovery = try maintenance.recover()
                XCTAssertTrue(recovery.recovered, "checkpoint \(checkpoint.rawValue)")
                XCTAssertEqual(recovery.health, .healthy, "checkpoint \(checkpoint.rawValue)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: maintenance.paths.journalPath))
                let ids = try store.events.loadAll().map(\.id)
                XCTAssertTrue(ids.contains("before-backup"), "checkpoint \(checkpoint.rawValue)")
                if checkpoint == .staging
                    || checkpoint == .prepared
                    || checkpoint == .sourceDisplaced {
                    XCTAssertTrue(ids.contains("after-backup"), "checkpoint \(checkpoint.rawValue)")
                } else {
                    XCTAssertFalse(ids.contains("after-backup"), "checkpoint \(checkpoint.rawValue)")
                    XCTAssertTrue(ids.contains { $0.hasPrefix("state-restore-") })
                }
                let maintenanceArtifacts = try FileManager.default
                    .contentsOfDirectory(atPath: directory.path)
                    .filter {
                        $0.hasPrefix(".hostwright-restore-stage-")
                            || $0.hasPrefix(".hostwright-restore-displaced-")
                    }
                XCTAssertEqual(maintenanceArtifacts, [], "checkpoint \(checkpoint.rawValue)")
                XCTAssertFalse(try maintenance.recover().recovered)
            }
        }
    }

    func testRecoveryHandlesEveryTornRestoreMutationWindow() throws {
        for window in StateRestoreInterruptionWindow.allCases {
            try withStore { store, directory in
                try appendEvent("before-backup", to: store)
                try insertValidProjections(store.path)
                let maintenance = try StateMaintenanceService(store: store)
                let backup = try maintenance.createBackup()
                try appendEvent("after-backup", to: store)
                let plan = try maintenance.restorePlan(backupID: backup.backupID)

                XCTAssertThrowsError(
                    try maintenance.restoreForTesting(
                        backupID: backup.backupID,
                        confirmationToken: plan.confirmationToken,
                        interruptBefore: window
                    ),
                    "window \(window.rawValue)"
                )
                XCTAssertTrue(FileManager.default.fileExists(atPath: maintenance.paths.journalPath))

                let recovery = try maintenance.recover()
                XCTAssertTrue(recovery.recovered, "window \(window.rawValue)")
                XCTAssertEqual(recovery.health, .healthy, "window \(window.rawValue)")
                let ids = try store.events.loadAll().map(\.id)
                XCTAssertTrue(ids.contains("before-backup"), "window \(window.rawValue)")
                if window == .stagePreparedBeforeJournal
                    || window == .sourceDisplacedBeforeJournal {
                    XCTAssertTrue(ids.contains("after-backup"), "window \(window.rawValue)")
                } else {
                    XCTAssertFalse(ids.contains("after-backup"), "window \(window.rawValue)")
                    XCTAssertTrue(ids.contains { $0.hasPrefix("state-restore-") })
                }
                let maintenanceArtifacts = try FileManager.default
                    .contentsOfDirectory(atPath: directory.path)
                    .filter {
                        $0.hasPrefix(".hostwright-restore-stage-")
                            || $0.hasPrefix(".hostwright-restore-displaced-")
                    }
                XCTAssertEqual(maintenanceArtifacts, [], "window \(window.rawValue)")
                XCTAssertFalse(try maintenance.recover().recovered)
            }
        }
    }

    func testRecoveryPromotesTornPublicationWhenRestoreTargetWasMissing() throws {
        try withStore { store, _ in
            try appendEvent("missing-target-backup", to: store)
            let maintenance = try StateMaintenanceService(store: store)
            let backup = try maintenance.createBackup()
            XCTAssertEqual(unlink(store.path), 0)
            let plan = try maintenance.restorePlan(backupID: backup.backupID)

            XCTAssertThrowsError(
                try maintenance.restoreForTesting(
                    backupID: backup.backupID,
                    confirmationToken: plan.confirmationToken,
                    interruptBefore: .replacementPublishedBeforeJournal
                )
            )
            let recovery = try maintenance.recover()

            XCTAssertTrue(recovery.recovered)
            XCTAssertEqual(recovery.health, .healthy)
            XCTAssertTrue(try store.events.loadAll().contains { $0.id == "missing-target-backup" })
            XCTAssertTrue(try store.events.loadAll().contains { $0.id.hasPrefix("state-restore-") })
            XCTAssertFalse(FileManager.default.fileExists(atPath: maintenance.paths.journalPath))
        }
    }

    func testOnlineBackupIsConsistentDuringRealWALWriterAndReplacementMutationsRefuseOpenExternalHandle() throws {
        try withStore { store, _ in
            let writer = try SQLiteConnection(path: store.path, createIfNeeded: false)
            defer { try? writer.close() }
            XCTAssertEqual(
                try writer.query("PRAGMA journal_mode = WAL").first?.first ?? nil,
                "wal"
            )
            try insertEvent(id: "wal-committed", on: writer)
            try writer.execute("BEGIN IMMEDIATE TRANSACTION")
            try insertEvent(id: "wal-uncommitted", on: writer)

            let maintenance = try StateMaintenanceService(store: store)
            let backup = try maintenance.createBackup()
            try writer.execute("ROLLBACK")

            let backupPath = maintenance.paths.backupDirectory + "/" + backup.backupID + "/state.sqlite"
            let backupConnection = try SQLiteConnection(
                path: backupPath,
                createIfNeeded: false,
                readOnly: true
            )
            defer { try? backupConnection.close() }
            let ids = try backupConnection.query(
                "SELECT id FROM event_ledger ORDER BY id"
            ).compactMap { $0.first ?? nil }
            XCTAssertEqual(ids, ["wal-committed"])

            XCTAssertTrue(FileManager.default.fileExists(atPath: store.path + "-wal"))
            XCTAssertThrowsError(try maintenance.restorePlan(backupID: backup.backupID)) { error in
                guard case .databaseLocked(let path, let message) = error as? StateStoreError else {
                    return XCTFail("Expected a bounded database lock refusal, got \(error)")
                }
                XCTAssertEqual(path, store.path)
                XCTAssertTrue(message.localizedCaseInsensitiveContains("locked"))
            }
            XCTAssertThrowsError(try maintenance.repairPlan()) { error in
                guard case .databaseLocked(let path, let message) = error as? StateStoreError else {
                    return XCTFail("Expected a bounded database lock refusal, got \(error)")
                }
                XCTAssertEqual(path, store.path)
                XCTAssertTrue(message.localizedCaseInsensitiveContains("locked"))
            }
        }
    }

    func testCatalogRejectsStrictManifestViolationsHardlinksAndOversizeWithoutDroppingEntries() throws {
        try withStore { store, _ in
            let maintenance = try StateMaintenanceService(store: store)
            let first = try maintenance.createBackup()
            let firstDirectory = maintenance.paths.backupDirectory + "/" + first.backupID
            let firstManifest = firstDirectory + "/manifest.json"
            let original = try String(contentsOfFile: firstManifest, encoding: .utf8)
            let tampered = original.replacingOccurrences(
                of: "{",
                with: "{\"schemaVersion\":1,\"unsupported\":true,",
                options: [],
                range: original.startIndex..<original.index(after: original.startIndex)
            )
            try tampered.write(toFile: firstManifest, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: firstManifest)

            let second = try maintenance.createBackup()
            let secondDatabase = maintenance.paths.backupDirectory + "/" + second.backupID + "/state.sqlite"
            let hardlink = store.path + ".backup-hardlink"
            XCTAssertEqual(link(secondDatabase, hardlink), 0)

            let third = try maintenance.createBackup()
            let thirdManifest = maintenance.paths.backupDirectory + "/" + third.backupID + "/manifest.json"
            let oversized = Data(repeating: 120, count: 64 * 1_024 + 1)
            try oversized.write(to: URL(fileURLWithPath: thirdManifest))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: thirdManifest)

            let catalog = try maintenance.backupCatalog()
            XCTAssertEqual(Set(catalog.backups.map(\.backupID)), Set([first.backupID, second.backupID, third.backupID]))
            XCTAssertTrue(catalog.backups.allSatisfy { !$0.restorable })
            XCTAssertTrue(
                catalog.backups.first { $0.backupID == first.backupID }?
                    .verificationMessage.contains("duplicate top-level fields") == true
            )
            XCTAssertTrue(
                catalog.backups.first { $0.backupID == second.backupID }?
                    .verificationMessage.contains("multiply linked") == true
            )
            XCTAssertTrue(
                catalog.backups.first { $0.backupID == third.backupID }?
                    .verificationMessage.contains("exceeds") == true
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: firstDirectory))
            XCTAssertTrue(FileManager.default.fileExists(atPath: hardlink))
        }
    }

    func testUnknownPartialBackupIsReportedAndPreserved() throws {
        try withStore { store, _ in
            let maintenance = try StateMaintenanceService(store: store)
            let published = try maintenance.createBackup()
            let partial = maintenance.paths.backupDirectory + "/.partial-operator-evidence"
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: partial),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let unknown = partial + "/unknown-evidence"
            try Data("preserve".utf8).write(to: URL(fileURLWithPath: unknown))

            let catalog = try maintenance.backupCatalog()
            XCTAssertEqual(catalog.backups.count, 2)
            XCTAssertTrue(catalog.backups.contains { $0.backupID == published.backupID && $0.restorable })
            XCTAssertTrue(catalog.backups.contains {
                $0.backupID == ".partial-operator-evidence" && !$0.restorable
            })
            XCTAssertTrue(FileManager.default.fileExists(atPath: unknown))
        }
    }

    func testTamperedRecoveryJournalFailsClosedAndRemainsForInspection() throws {
        try withStore { store, _ in
            let maintenance = try StateMaintenanceService(store: store)
            let backup = try maintenance.createBackup()
            let plan = try maintenance.restorePlan(backupID: backup.backupID)
            XCTAssertThrowsError(
                try maintenance.restoreForTesting(
                    backupID: backup.backupID,
                    confirmationToken: plan.confirmationToken,
                    interruptAfter: .prepared
                )
            )
            let journal = try String(contentsOfFile: maintenance.paths.journalPath, encoding: .utf8)
            let tampered = journal.replacingOccurrences(
                of: "{",
                with: "{\"unsupported\":true,",
                options: [],
                range: journal.startIndex..<journal.index(after: journal.startIndex)
            )
            try tampered.write(toFile: maintenance.paths.journalPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: maintenance.paths.journalPath
            )

            XCTAssertThrowsError(try maintenance.recover()) { error in
                guard case .recoveryFailed(let message) = error as? StateMaintenanceError else {
                    return XCTFail("Expected recoveryFailed, got \(error)")
                }
                XCTAssertTrue(message.contains("unsupported top-level fields"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: maintenance.paths.journalPath))
            XCTAssertThrowsError(try store.events.loadAll())
        }
    }

    func testStateAccessFenceRejectsAnUnmanagedHardLinkWithoutChangingItsMode() throws {
        try withStore { store, directory in
            let lockPath = try store.configuration.maintenancePaths().accessLockPath
            XCTAssertEqual(unlink(lockPath), 0)
            let unmanaged = directory.appendingPathComponent("operator-owned.txt").path
            try Data("operator evidence".utf8).write(to: URL(fileURLWithPath: unmanaged))
            XCTAssertEqual(chmod(unmanaged, 0o644), 0)
            XCTAssertEqual(link(unmanaged, lockPath), 0)

            XCTAssertThrowsError(try store.events.loadAll()) { error in
                guard case .pathPolicyViolation(let path, let message) = error as? StateStoreError else {
                    return XCTFail("Expected pathPolicyViolation, got \(error)")
                }
                XCTAssertEqual(path, lockPath)
                XCTAssertTrue(message.contains("singly linked"))
            }
            XCTAssertEqual(permissions(unmanaged), 0o644)
            XCTAssertEqual(permissions(lockPath), 0o644)
        }
    }

    func testRestoreRejectsASelectedBackupChangedAfterConfirmationBeforeCopy() throws {
        try withStore { store, directory in
            try appendEvent("backup-a", to: store)
            let maintenance = try StateMaintenanceService(store: store)
            let backupA = try maintenance.createBackup()
            try appendEvent("backup-b", to: store)
            let backupB = try maintenance.createBackup()
            let plan = try maintenance.restorePlan(backupID: backupA.backupID)
            let backupAPath = maintenance.paths.backupDirectory + "/" + backupA.backupID + "/state.sqlite"
            let backupBPath = maintenance.paths.backupDirectory + "/" + backupB.backupID + "/state.sqlite"

            XCTAssertThrowsError(
                try maintenance.restoreForTesting(
                    backupID: backupA.backupID,
                    confirmationToken: plan.confirmationToken,
                    beforeStagingCopy: {
                        try Data(contentsOf: URL(fileURLWithPath: backupBPath))
                            .write(to: URL(fileURLWithPath: backupAPath))
                        XCTAssertEqual(chmod(backupAPath, 0o600), 0)
                    }
                )
            ) { error in
                guard case .backupNotRestorable(let id, let reason) = error as? StateMaintenanceError else {
                    return XCTFail("Expected backupNotRestorable, got \(error)")
                }
                XCTAssertEqual(id, backupA.backupID)
                XCTAssertTrue(reason.contains("changed"))
            }
            XCTAssertTrue(try store.events.loadAll().contains { $0.id == "backup-b" })
            XCTAssertFalse(FileManager.default.fileExists(atPath: maintenance.paths.journalPath))
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    .filter { $0.hasPrefix(".hostwright-restore-stage-") },
                []
            )
        }
    }

    func testAutomaticRestoreRollbackHandlesPublicationBeforeJournalUpdate() throws {
        for sourceExists in [true, false] {
            try withStore { store, directory in
                try appendEvent("rollback-authority", to: store)
                let maintenance = try StateMaintenanceService(store: store)
                let backup = try maintenance.createBackup()
                if sourceExists {
                    try appendEvent("post-backup-authority", to: store)
                } else {
                    XCTAssertEqual(unlink(store.path), 0)
                }
                let plan = try maintenance.restorePlan(backupID: backup.backupID)

                XCTAssertThrowsError(
                    try maintenance.restoreForTesting(
                        backupID: backup.backupID,
                        confirmationToken: plan.confirmationToken,
                        failBefore: .replacementPublishedBeforeJournal
                    )
                )

                XCTAssertFalse(FileManager.default.fileExists(atPath: maintenance.paths.journalPath))
                XCTAssertEqual(FileManager.default.fileExists(atPath: store.path), sourceExists)
                if sourceExists {
                    XCTAssertTrue(try store.events.loadAll().contains { $0.id == "post-backup-authority" })
                }
                let artifacts = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                XCTAssertEqual(
                    artifacts.filter { $0.hasPrefix(".hostwright-restore-failed-") }.count,
                    1
                )
                XCTAssertEqual(
                    artifacts.filter {
                        $0.hasPrefix(".hostwright-restore-stage-")
                            || $0.hasPrefix(".hostwright-restore-displaced-")
                    },
                    []
                )
            }
        }
    }

    func testRepairRecoveryUsesRollbackSnapshotWhenCommittedStateBecomesUnrecoverable() throws {
        try withStore { store, directory in
            try appendEvent("repair-authority", to: store)
            try insertInvalidObservedProjection(store.path)
            let maintenance = try StateMaintenanceService(store: store)
            let plan = try maintenance.repairPlan()
            XCTAssertThrowsError(
                try maintenance.repairForTesting(
                    confirmationToken: plan.confirmationToken,
                    interruptAfterMutationBeforeJournal: true
                )
            )
            try Data("failed repaired database".utf8).write(to: URL(fileURLWithPath: store.path))
            XCTAssertEqual(chmod(store.path, 0o600), 0)

            let recovery = try maintenance.recover()

            XCTAssertTrue(recovery.recovered)
            XCTAssertEqual(recovery.health, .healthy)
            XCTAssertTrue(recovery.action.contains("pre-repair snapshot"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: maintenance.paths.journalPath))
            XCTAssertEqual(try rowCount("observed_runtime_snapshots", path: store.path), 0)
            let events = try store.events.loadAll()
            XCTAssertTrue(events.contains { $0.id == "repair-authority" })
            XCTAssertTrue(events.contains { $0.id.hasPrefix("state-repair-rollback-") })
            let failed = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(atPath: directory.path)
                    .first { $0.hasPrefix(".hostwright-repair-failed-") }
            )
            XCTAssertEqual(
                try String(contentsOfFile: directory.appendingPathComponent(failed).path, encoding: .utf8),
                "failed repaired database"
            )
            XCTAssertFalse(try maintenance.recover().recovered)
        }
    }

    func testIntegrityRequiresIndexesUUIDsAndCompleteSagaEnums() throws {
        try withStore { store, _ in
            let connection = try SQLiteConnection(path: store.path, createIfNeeded: false)
            defer { try? connection.close() }
            try connection.execute("DROP INDEX operation_groups_fencing_token_idx")
            var report = try StateIntegrityService(store: store).inspect(connection: connection)
            XCTAssertEqual(report.health, .unrecoverable)
            XCTAssertTrue(report.checks.contains {
                $0.identifier == "hostwright.schema-objects"
                    && $0.message.contains("operation_groups_fencing_token_idx")
            })

            try connection.execute(
                "CREATE UNIQUE INDEX operation_groups_fencing_token_idx ON operation_groups(fencing_token)"
            )
            try connection.run(
                """
                INSERT INTO projects (
                    id, name, manifest_path, manifest_hash, created_at, updated_at,
                    resource_uuid, manifest_version, mutation_provider, provider_generation
                ) VALUES ('invalid-project', 'invalid-project', NULL, 'hash', 'now', 'now',
                          'not-a-uuid', 2, NULL, 0)
                """
            )
            report = try StateIntegrityService(store: store).inspect(connection: connection)
            XCTAssertEqual(report.health, .unrecoverable)
            XCTAssertTrue(report.checks.contains {
                $0.identifier == "hostwright.authoritative-records" && $0.affectedRows == 1
            })

            let projectUUID = UUID().uuidString.lowercased()
            let fencingToken = UUID().uuidString.lowercased()
            try connection.run(
                "UPDATE projects SET resource_uuid = ? WHERE id = 'invalid-project'",
                bindings: [.text(projectUUID)]
            )
            try connection.run(
                """
                INSERT INTO operation_groups (
                    id, operation_id, group_kind, project_id, service_name,
                    planned_action_type, status, group_idempotency_key, plan_hash,
                    checkpoint, lock_owner, lock_expires_at, rollback_available,
                    manual_recovery_hint_redacted, created_at, updated_at,
                    metadata_json_redacted, fencing_token, intent_json_redacted,
                    compensation_json_redacted, verification_json_redacted
                ) VALUES ('invalid-group', 'operation', 'apply', 'invalid-project', NULL,
                          'create', 'not-a-status', 'key', 'plan', 'prepared', NULL, NULL, 1,
                          '', 'now', 'now', '{}', ?, '{}', '[]', '{}')
                """,
                bindings: [.text(fencingToken)]
            )
            report = try StateIntegrityService(store: store).inspect(connection: connection)
            XCTAssertEqual(report.health, .unrecoverable)
            XCTAssertTrue(report.checks.contains {
                $0.identifier == "hostwright.authoritative-records" && $0.affectedRows == 1
            })
        }
    }

    private func withStore(_ body: (SQLiteStateStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-state-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try body(store, directory)
    }

    private func appendEvent(
        _ id: String,
        payload: String = "{}",
        to store: SQLiteStateStore
    ) throws {
        try store.events.append([
            EventRecord(
                id: id,
                timestamp: "2026-07-13T12:00:00Z",
                severity: .info,
                type: "state.maintenance.test",
                source: "state-maintenance-tests",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: nil,
                message: "test event",
                payloadJSONRedacted: payload
            )
        ])
    }

    private func appendLargeEvent(to store: SQLiteStateStore) throws {
        try appendEvent(
            "large-event",
            payload: "{\"value\":\"\(String(repeating: "a", count: 64 * 1_024))\"}",
            to: store
        )
    }

    private func insertValidProjections(_ path: String) throws {
        let connection = try SQLiteConnection(path: path, createIfNeeded: false)
        defer { try? connection.close() }
        try connection.run(
            """
            INSERT INTO observed_runtime_snapshots (
                id, project_id, runtime_adapter, runtime_name, runtime_version,
                observed_at, parser_version, raw_output_hash, redacted_summary, capabilities_json
            ) VALUES ('snapshot-valid', NULL, 'apple-container-cli', 'Apple container CLI',
                      '1.1.0', '2026-07-13T12:00:00Z', 'v1', NULL, 'valid', '[]')
            """
        )
        try connection.run(
            """
            INSERT INTO observed_services (
                id, snapshot_id, project_name, service_name, instance_name, image,
                lifecycle_state, health_state, ports_json, mounts_json,
                runtime_identifiers_json, resource_identifier, networks_json
            ) VALUES ('observed-valid', 'snapshot-valid', 'demo', 'api', NULL, 'demo:latest',
                      'running', 'healthy', '[]', '[]', '{}', 'hostwright-demo-api', '[]')
            """
        )
    }

    private func insertInvalidObservedProjection(_ path: String) throws {
        let connection = try SQLiteConnection(path: path, createIfNeeded: false)
        defer { try? connection.close() }
        try connection.run(
            """
            INSERT INTO observed_runtime_snapshots (
                id, project_id, runtime_adapter, runtime_name, runtime_version,
                observed_at, parser_version, raw_output_hash, redacted_summary, capabilities_json
            ) VALUES ('snapshot-invalid', NULL, 'apple-container-cli', 'Apple container CLI',
                      '1.1.0', '2026-07-13T12:00:00Z', 'v1', NULL, 'invalid', 'not-json')
            """
        )
    }

    private func insertEvent(id: String, on connection: SQLiteConnection) throws {
        try connection.run(
            """
            INSERT INTO event_ledger (
                id, timestamp, severity, type, source, project_id, service_name,
                runtime_adapter, message, payload_json_redacted
            ) VALUES (?, '2026-07-13T12:00:00Z', 'info', 'wal-test',
                      'state-maintenance-tests', NULL, NULL, NULL, 'wal event', '{}')
            """,
            bindings: [.text(id)]
        )
    }

    private func rowCount(_ table: String, path: String) throws -> Int {
        let connection = try SQLiteConnection(path: path, createIfNeeded: false, readOnly: true)
        defer { try? connection.close() }
        return Int(try XCTUnwrap(connection.query("SELECT COUNT(*) FROM \(table)").first?.first ?? nil)) ?? -1
    }

    private func permissions(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func backupEntries(_ path: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: path).sorted()
    }
}
