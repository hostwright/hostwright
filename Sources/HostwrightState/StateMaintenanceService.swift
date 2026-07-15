import Darwin
import Foundation

public struct StateMaintenanceService {
    public let store: SQLiteStateStore
    public let paths: StateMaintenancePaths

    public init(store: SQLiteStateStore) throws {
        self.store = store
        self.paths = try store.configuration.maintenancePaths()
    }

    public func integrity() -> StateIntegrityReport {
        StateIntegrityService(store: store).inspect()
    }

    public func createBackup() throws -> StateBackupRecord {
        guard !sqliteCurrentTaskIsCancelled() else {
            throw StateMaintenanceError.cancelled
        }
        return try store.withValidatedConnection(readOnly: true) { connection in
            try createBackup(
                source: connection,
                purpose: .manual,
                shouldCancel: sqliteCurrentTaskIsCancelled
            )
        }
    }

    func createBackupForTesting(
        destinationMaximumPages: Int32? = nil,
        shouldCancel: () -> Bool = { false }
    ) throws -> StateBackupRecord {
        try store.withValidatedConnection(readOnly: true) { connection in
            try createBackup(
                source: connection,
                purpose: .manual,
                destinationMaximumPages: destinationMaximumPages,
                shouldCancel: shouldCancel
            )
        }
    }

    public func backupCatalog() throws -> StateBackupCatalog {
        guard StateMaintenanceFileSupport.exists(paths.backupDirectory) else {
            return StateBackupCatalog(backups: [])
        }
        try SecureStatePathManager().validatePrivateMaintenanceDirectory(paths.backupDirectory)
        let entries = try FileManager.default.contentsOfDirectory(atPath: paths.backupDirectory)
        let records = entries.sorted().map { entry -> StateBackupRecord in
            if entry.hasPrefix(".partial-") {
                return StateBackupRecord(
                    backupID: entry,
                    createdAt: nil,
                    databaseSHA256: nil,
                    databaseBytes: nil,
                    stateSchemaVersion: nil,
                    restorable: false,
                    verificationMessage: "Incomplete unpublished backup is preserved for inspection."
                )
            }
            do {
                return try verifyBackup(entry)
            } catch {
                return StateBackupRecord(
                    backupID: entry,
                    createdAt: nil,
                    databaseSHA256: nil,
                    databaseBytes: nil,
                    stateSchemaVersion: nil,
                    restorable: false,
                    verificationMessage: String(describing: error)
                )
            }
        }.sorted {
            if $0.createdAt == $1.createdAt { return $0.backupID > $1.backupID }
            return ($0.createdAt ?? "") > ($1.createdAt ?? "")
        }
        return StateBackupCatalog(backups: records)
    }

    public func restorePlan(backupID: String) throws -> StateRestorePlan {
        let backup = try restorableBackup(backupID)
        try store.configuration.prepareStateAccessFoundation()
        return try StateAccessCoordinator(configuration: store.configuration).withLock(.exclusive) {
            let current = integrityWithoutFence()
            let currentFingerprint = try currentStateFingerprint()
            return StateRestorePlan(
                backup: backup,
                currentHealth: current.health,
                confirmationToken: restoreToken(
                    backup: backup,
                    currentFingerprint: currentFingerprint
                ),
                effects: [
                    "Create and verify a pre-restore backup when the current database is healthy.",
                    "Atomically replace the state database with backup \(backupID).",
                    "Clear runtime-observation and health projections because they must be re-observed.",
                    "Preserve an unreadable current database as a quarantine artifact; never synthesize authoritative state."
                ]
            )
        }
    }

    public func restore(backupID: String, confirmationToken: String) throws -> StateRestoreResult {
        try StateAccessCoordinator(configuration: store.configuration).withLock(.exclusive) {
            let backup = try restorableBackup(backupID)
            let currentFingerprint = try currentStateFingerprint()
            guard confirmationToken == restoreToken(
                backup: backup,
                currentFingerprint: currentFingerprint
            ) else {
                throw StateMaintenanceError.confirmationMismatch
            }
            guard !StateMaintenanceFileSupport.exists(paths.journalPath) else {
                throw StateMaintenanceError.operationInProgress(paths.journalPath)
            }
            return try performRestore(backup: backup)
        }
    }

    func restoreForTesting(
        backupID: String,
        confirmationToken: String,
        interruptAfter checkpoint: StateRestoreInterruptionCheckpoint
    ) throws -> StateRestoreResult {
        try StateAccessCoordinator(configuration: store.configuration).withLock(.exclusive) {
            let backup = try restorableBackup(backupID)
            let currentFingerprint = try currentStateFingerprint()
            guard confirmationToken == restoreToken(
                backup: backup,
                currentFingerprint: currentFingerprint
            ) else {
                throw StateMaintenanceError.confirmationMismatch
            }
            guard !StateMaintenanceFileSupport.exists(paths.journalPath) else {
                throw StateMaintenanceError.operationInProgress(paths.journalPath)
            }
            return try performRestore(backup: backup, interruptAfter: checkpoint)
        }
    }

    func restoreForTesting(
        backupID: String,
        confirmationToken: String,
        interruptBefore checkpoint: StateRestoreInterruptionWindow
    ) throws -> StateRestoreResult {
        try StateAccessCoordinator(configuration: store.configuration).withLock(.exclusive) {
            let backup = try restorableBackup(backupID)
            let currentFingerprint = try currentStateFingerprint()
            guard confirmationToken == restoreToken(
                backup: backup,
                currentFingerprint: currentFingerprint
            ) else {
                throw StateMaintenanceError.confirmationMismatch
            }
            guard !StateMaintenanceFileSupport.exists(paths.journalPath) else {
                throw StateMaintenanceError.operationInProgress(paths.journalPath)
            }
            return try performRestore(backup: backup, interruptBefore: checkpoint)
        }
    }

    func restoreForTesting(
        backupID: String,
        confirmationToken: String,
        failBefore checkpoint: StateRestoreInjectedFailurePoint
    ) throws -> StateRestoreResult {
        try StateAccessCoordinator(configuration: store.configuration).withLock(.exclusive) {
            let backup = try restorableBackup(backupID)
            let currentFingerprint = try currentStateFingerprint()
            guard confirmationToken == restoreToken(
                backup: backup,
                currentFingerprint: currentFingerprint
            ) else {
                throw StateMaintenanceError.confirmationMismatch
            }
            guard !StateMaintenanceFileSupport.exists(paths.journalPath) else {
                throw StateMaintenanceError.operationInProgress(paths.journalPath)
            }
            return try performRestore(backup: backup, failBefore: checkpoint)
        }
    }

    func restoreForTesting(
        backupID: String,
        confirmationToken: String,
        beforeStagingCopy: () throws -> Void
    ) throws -> StateRestoreResult {
        try StateAccessCoordinator(configuration: store.configuration).withLock(.exclusive) {
            let backup = try restorableBackup(backupID)
            let currentFingerprint = try currentStateFingerprint()
            guard confirmationToken == restoreToken(
                backup: backup,
                currentFingerprint: currentFingerprint
            ) else {
                throw StateMaintenanceError.confirmationMismatch
            }
            guard !StateMaintenanceFileSupport.exists(paths.journalPath) else {
                throw StateMaintenanceError.operationInProgress(paths.journalPath)
            }
            return try performRestore(
                backup: backup,
                beforeStagingCopy: beforeStagingCopy
            )
        }
    }

    public func repairPlan() throws -> StateRepairPlan {
        try store.configuration.prepareStateAccessFoundation()
        return try StateAccessCoordinator(configuration: store.configuration).withLock(.exclusive) {
            try normalizeAuthoritativeStateForFilesystemOperation()
            let connection = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                readOnly: true,
                profile: .authoritativeState
            )
            defer { try? connection.close() }
            let fingerprint = try StateMaintenanceFileSupport.fingerprint(store.path)
            let report = try StateIntegrityService(store: store).inspect(
                connection: connection,
                fingerprint: fingerprint
            )
            guard report.health == .degraded, !report.repairableProjectionTables.isEmpty else {
                throw StateMaintenanceError.unsafeRepair(
                    report.health == .healthy
                        ? "the database is healthy and has no repairable projection damage"
                        : "authoritative, schema, or SQLite damage requires restoration from a verified backup"
                )
            }
            let counts = try projectionCounts(
                report.repairableProjectionTables,
                connection: connection
            )
            try connection.close()
            return StateRepairPlan(
                health: report.health,
                tables: counts,
                confirmationToken: repairToken(fingerprint: fingerprint, counts: counts)
            )
        }
    }

    public func repair(confirmationToken: String) throws -> StateRepairResult {
        try repair(
            confirmationToken: confirmationToken,
            interruptAfterMutationBeforeJournal: false,
            failBeforeCommitForTesting: false,
            rollbackForTesting: nil
        )
    }

    func repairForTesting(
        confirmationToken: String,
        interruptAfterMutationBeforeJournal: Bool,
        failBeforeCommit: Bool = false,
        rollbackForTesting: (() throws -> Void)? = nil
    ) throws -> StateRepairResult {
        try repair(
            confirmationToken: confirmationToken,
            interruptAfterMutationBeforeJournal: interruptAfterMutationBeforeJournal,
            failBeforeCommitForTesting: failBeforeCommit,
            rollbackForTesting: rollbackForTesting
        )
    }

    private func repair(
        confirmationToken: String,
        interruptAfterMutationBeforeJournal: Bool,
        failBeforeCommitForTesting: Bool,
        rollbackForTesting: (() throws -> Void)?
    ) throws -> StateRepairResult {
        try StateAccessCoordinator(configuration: store.configuration).withLock(.exclusive) {
            guard !StateMaintenanceFileSupport.exists(paths.journalPath) else {
                throw StateMaintenanceError.operationInProgress(paths.journalPath)
            }
            try normalizeAuthoritativeStateForFilesystemOperation()
            let connection = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            defer { try? connection.close() }
            let fingerprint = try StateMaintenanceFileSupport.fingerprint(store.path)
            let report = try StateIntegrityService(store: store).inspect(
                connection: connection,
                fingerprint: fingerprint
            )
            guard report.health == .degraded, !report.repairableProjectionTables.isEmpty else {
                throw StateMaintenanceError.unsafeRepair(
                    "only logically invalid runtime-observation and health projections may be repaired"
                )
            }
            let counts = try projectionCounts(
                report.repairableProjectionTables,
                connection: connection
            )
            guard confirmationToken == repairToken(fingerprint: fingerprint, counts: counts) else {
                throw StateMaintenanceError.confirmationMismatch
            }

            let preRepair = try createBackup(source: connection, purpose: .preRepair)
            let operationID = UUID().uuidString.lowercased()
            var journal = StateMaintenanceJournal.repair(
                operationID: operationID,
                databasePath: store.path,
                preMutationBackupID: preRepair.backupID,
                createdAt: timestamp()
            )
            try writeNewJournal(journal)
            var mutationCommitted = false
            do {
                try connection.transaction(rollbackForTesting: rollbackForTesting) {
                    for table in Self.projectionDeleteOrder where counts[table] != nil {
                        try connection.execute("DELETE FROM \(table)")
                    }
                    try appendMaintenanceEvent(
                        connection: connection,
                        id: "state-repair-\(operationID)",
                        type: "state.maintenance.repaired",
                        message: "Rebuildable state projections were cleared after verified backup \(preRepair.backupID).",
                        payload: counts
                    )
                    if failBeforeCommitForTesting {
                        throw StateMaintenanceSimulatedRepairTransactionFailure()
                    }
                }
                mutationCommitted = true
                if interruptAfterMutationBeforeJournal {
                    throw StateMaintenanceSimulatedRepairInterruption()
                }
                journal = journal.updating(checkpoint: .mutationCommitted)
                try replaceJournal(journal)
                let post = try StateIntegrityService(store: store).inspect(connection: connection)
                guard post.health == .healthy else {
                    throw StateMaintenanceError.recoveryFailed(
                        "the repaired database did not pass full post-mutation verification"
                    )
                }
                try removeJournal()
                try connection.close()
                return StateRepairResult(
                    preRepairBackupID: preRepair.backupID,
                    clearedRows: counts,
                    health: post.health
                )
            } catch {
                let outcomeUncertain: Bool
                if let stateError = error as? StateStoreError,
                   case .transactionOutcomeUncertain = stateError {
                    outcomeUncertain = true
                } else {
                    outcomeUncertain = false
                }
                if !mutationCommitted, !outcomeUncertain {
                    try? removeJournal()
                }
                throw error
            }
        }
    }

    public func recover() throws -> StateRecoveryResult {
        try store.configuration.prepareStateAccessFoundation()
        return try StateAccessCoordinator(configuration: store.configuration).withLock(
            .exclusive,
            allowPendingMaintenance: true
        ) {
            guard StateMaintenanceFileSupport.exists(paths.journalPath) else {
                return StateRecoveryResult(
                    recovered: false,
                    action: "No pending state-maintenance journal was found.",
                    health: integrityWithoutFence().health
                )
            }
            let journal = try readAndValidateJournal()
            try validateExistingJournalFiles(journal)
            try normalizeAuthoritativeStateForFilesystemOperation()
            switch journal.operationKind {
            case .repair:
                return try recoverRepair(journal)
            case .restore:
                return try recoverRestore(journal)
            }
        }
    }

    private func createBackup(
        source: SQLiteConnection,
        purpose: StateBackupPurpose,
        destinationMaximumPages: Int32? = nil,
        shouldCancel: () -> Bool = sqliteCurrentTaskIsCancelled
    ) throws -> StateBackupRecord {
        try ensureBackupRoot()
        let backupID = "backup-\(UUID().uuidString.lowercased())"
        let stagingDirectory = URL(
            fileURLWithPath: paths.backupDirectory,
            isDirectory: true
        ).appendingPathComponent(".partial-\(backupID)", isDirectory: true).path
        let finalDirectory = backupDirectory(backupID)
        guard mkdir(stagingDirectory, S_IRWXU) == 0 else {
            throw StateMaintenanceError.io(
                path: stagingDirectory,
                message: String(cString: strerror(errno))
            )
        }
        var published = false
        defer {
            if !published { cleanupOwnedBackupStaging(stagingDirectory) }
        }
        try SecureStatePathManager().validatePrivateMaintenanceDirectory(stagingDirectory)
        let databasePath = URL(fileURLWithPath: stagingDirectory, isDirectory: true)
            .appendingPathComponent("state.sqlite")
            .path
        try SecureStatePathManager().createExclusiveSensitiveFile(databasePath)
        try source.onlineBackup(
            to: databasePath,
            destinationMaximumPages: destinationMaximumPages,
            shouldCancel: shouldCancel
        )
        try SecureStatePathManager().validateSensitiveRegularFile(databasePath)
        try rejectSQLiteSidecars(databasePath)
        let fingerprint = try StateMaintenanceFileSupport.fingerprint(databasePath)
        let backupConnection = try SQLiteConnection(
            path: databasePath,
            createIfNeeded: false,
            readOnly: true,
            profile: .portableArtifact
        )
        let report: StateIntegrityReport
        do {
            report = try StateIntegrityService(store: store).inspect(
                connection: backupConnection,
                fingerprint: fingerprint
            )
            try backupConnection.close()
        } catch {
            try? backupConnection.close()
            throw error
        }
        let isVerifiedPreRepairSnapshot = purpose == .preRepair && report.health == .degraded
        guard (report.health == .healthy || isVerifiedPreRepairSnapshot),
              report.stateSchemaVersion == MigrationRunner.latestSchemaVersion else {
            throw StateMaintenanceError.backupNotRestorable(
                id: backupID,
                reason: "the copied database failed full integrity or schema verification"
            )
        }

        let manifest = StateBackupManifest(
            schemaVersion: 1,
            backupID: backupID,
            createdAt: timestamp(),
            purpose: purpose,
            databaseSHA256: fingerprint.sha256,
            databaseBytes: fingerprint.bytes,
            stateSchemaVersion: report.stateSchemaVersion ?? 0,
            sourceHealth: report.health
        )
        let manifestPath = URL(fileURLWithPath: stagingDirectory, isDirectory: true)
            .appendingPathComponent("manifest.json")
            .path
        try SecureStatePathManager().writePrivateJSON(manifest, to: manifestPath)
        try StateMaintenanceFileSupport.synchronizeDirectory(stagingDirectory)
        guard renamex_np(stagingDirectory, finalDirectory, UInt32(RENAME_EXCL)) == 0 else {
            throw StateMaintenanceError.io(
                path: finalDirectory,
                message: String(cString: strerror(errno))
            )
        }
        published = true
        try StateMaintenanceFileSupport.synchronizeDirectory(paths.backupDirectory)
        return try verifyBackup(backupID)
    }

    private func verifyBackup(_ backupID: String) throws -> StateBackupRecord {
        try verifiedBackupArtifact(backupID).record
    }

    private func verifiedBackupArtifact(_ backupID: String) throws -> VerifiedStateBackup {
        try StateMaintenanceFileSupport.validateBackupID(backupID)
        let directory = backupDirectory(backupID)
        guard StateMaintenanceFileSupport.exists(directory) else {
            throw StateMaintenanceError.backupNotFound(backupID)
        }
        try SecureStatePathManager().validatePrivateMaintenanceDirectory(directory)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        guard entries == ["manifest.json", "state.sqlite"] else {
            throw StateMaintenanceError.backupNotRestorable(
                id: backupID,
                reason: "the backup directory must contain exactly manifest.json and state.sqlite"
            )
        }
        let manifestPath = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("manifest.json")
            .path
        let databasePath = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("state.sqlite")
            .path
        let data = try SecureStatePathManager().readPrivateFile(
            manifestPath,
            maximumBytes: 64 * 1_024
        )
        do {
            try StateStrictJSONObject.validate(
                data,
                allowedKeys: Self.backupManifestKeys,
                requiredKeys: Self.backupManifestKeys
            )
        } catch let error as StateStrictJSONError {
            throw StateMaintenanceError.backupNotRestorable(
                id: backupID,
                reason: "manifest.json is invalid: \(error.reason)"
            )
        }
        let manifest: StateBackupManifest
        do {
            manifest = try JSONDecoder().decode(StateBackupManifest.self, from: data)
        } catch {
            throw StateMaintenanceError.backupNotRestorable(
                id: backupID,
                reason: "manifest.json is invalid"
            )
        }
        guard manifest.schemaVersion == 1, manifest.backupID == backupID else {
            throw StateMaintenanceError.backupNotRestorable(
                id: backupID,
                reason: "the manifest identity or schema version does not match the catalog path"
            )
        }
        try SecureStatePathManager().validateSensitiveRegularFile(databasePath)
        try rejectSQLiteSidecars(databasePath)
        let fingerprint = try StateMaintenanceFileSupport.fingerprint(databasePath)
        guard fingerprint.sha256 == manifest.databaseSHA256,
              fingerprint.bytes == manifest.databaseBytes else {
            throw StateMaintenanceError.backupNotRestorable(
                id: backupID,
                reason: "the database digest or size does not match the recorded catalog metadata"
            )
        }
        let connection = try SQLiteConnection(
            path: databasePath,
            createIfNeeded: false,
            readOnly: true,
            profile: .portableArtifact
        )
        defer { try? connection.close() }
        let report = try StateIntegrityService(store: store).inspect(
            connection: connection,
            fingerprint: fingerprint
        )
        let isVerifiedPreRepairSnapshot = manifest.purpose == .preRepair
            && manifest.sourceHealth == .degraded
            && report.health == .degraded
            && !report.repairableProjectionTables.isEmpty
        guard (report.health == .healthy || isVerifiedPreRepairSnapshot),
              report.stateSchemaVersion == manifest.stateSchemaVersion,
              manifest.stateSchemaVersion == MigrationRunner.latestSchemaVersion else {
            throw StateMaintenanceError.backupNotRestorable(
                id: backupID,
                reason: "the database no longer passes the recorded schema and integrity contract"
            )
        }
        try connection.close()
        return VerifiedStateBackup(
            record: StateBackupRecord(
                backupID: backupID,
                createdAt: manifest.createdAt,
                databaseSHA256: manifest.databaseSHA256,
                databaseBytes: manifest.databaseBytes,
                stateSchemaVersion: manifest.stateSchemaVersion,
                restorable: report.health == .healthy,
                verificationMessage: report.health == .healthy
                    ? "Digest, size, state schema, SQLite integrity, foreign keys, and logical contracts verified."
                    : "Verified rollback-only pre-repair snapshot; only reconstructible projections are degraded."
            ),
            purpose: manifest.purpose,
            sourceHealth: manifest.sourceHealth,
            repairableProjectionTables: report.repairableProjectionTables
        )
    }

    private func restorableBackup(_ backupID: String) throws -> StateBackupRecord {
        let record = try verifyBackup(backupID)
        guard record.restorable else {
            throw StateMaintenanceError.backupNotRestorable(
                id: backupID,
                reason: record.verificationMessage
            )
        }
        return record
    }

    private func ensureBackupRoot() throws {
        if StateMaintenanceFileSupport.exists(paths.backupDirectory) {
            try SecureStatePathManager().validatePrivateMaintenanceDirectory(paths.backupDirectory)
        } else {
            try SecureStatePathManager().ensurePrivateMaintenanceDirectory(paths.backupDirectory)
        }
    }

    private func backupDirectory(_ backupID: String) -> String {
        URL(fileURLWithPath: paths.backupDirectory, isDirectory: true)
            .appendingPathComponent(backupID, isDirectory: true)
            .path
    }

    private func cleanupOwnedBackupStaging(_ directory: String) {
        for name in [
            "manifest.json",
            "state.sqlite-wal",
            "state.sqlite-shm",
            "state.sqlite-journal",
            "state.sqlite"
        ] {
            let path = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
                .path
            if StateMaintenanceFileSupport.exists(path) {
                try? StateMaintenanceFileSupport.unlinkSensitiveFile(path)
            }
        }
        _ = rmdir(directory)
    }

    private func rejectSQLiteSidecars(_ databasePath: String) throws {
        for suffix in ["-journal", "-wal", "-shm"] {
            let path = databasePath + suffix
            if StateMaintenanceFileSupport.exists(path) {
                throw StateMaintenanceError.io(
                    path: path,
                    message: "SQLite sidecars are forbidden for published backup and filesystem-replacement artifacts"
                )
            }
        }
    }

    private func normalizeAuthoritativeStateForFilesystemOperation() throws {
        guard StateMaintenanceFileSupport.exists(store.path) else {
            try removeEmptyOrphanedWALSidecars()
            return
        }
        _ = try SecureStatePathManager().validateSQLiteFileSet(store.path)

        do {
            let reader = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                readOnly: true,
                profile: .authoritativeState
            )
            do {
                try MigrationRunner().validateAppliedSchema(on: reader)
                try reader.close()
            } catch {
                try? reader.close()
                throw error
            }

            let normalizer = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            do {
                try MigrationRunner().validateAppliedSchema(on: normalizer)
                try normalizer.close()
            } catch {
                try? normalizer.close()
                throw error
            }
        } catch let error as StateStoreError {
            switch error {
            case .corruptDatabase, .openFailed, .executeFailed, .prepareFailed, .stepFailed:
                try removeEmptyOrphanedWALSidecars()
            default:
                throw error
            }
        }
        try removeEmptyOrphanedWALSidecars()
        try rejectSQLiteSidecars(store.path)
    }

    private func removeEmptyOrphanedWALSidecars() throws {
        let journal = store.path + "-journal"
        guard !StateMaintenanceFileSupport.exists(journal) else {
            throw StateMaintenanceError.io(
                path: journal,
                message: "a rollback journal may contain recovery state and cannot be removed implicitly"
            )
        }

        let wal = store.path + "-wal"
        if StateMaintenanceFileSupport.exists(wal) {
            try SecureStatePathManager().validateSensitiveRegularFile(wal)
            var metadata = stat()
            guard lstat(wal, &metadata) == 0, metadata.st_size == 0 else {
                throw StateMaintenanceError.io(
                    path: wal,
                    message: "a non-empty orphaned WAL may contain committed state and cannot be removed implicitly"
                )
            }
            try StateMaintenanceFileSupport.unlinkSensitiveFile(wal)
        }

        let sharedMemory = store.path + "-shm"
        if StateMaintenanceFileSupport.exists(sharedMemory) {
            try SecureStatePathManager().validateSensitiveRegularFile(sharedMemory)
            try StateMaintenanceFileSupport.unlinkSensitiveFile(sharedMemory)
        }
        try StateMaintenanceFileSupport.synchronizeDirectory(
            (store.path as NSString).deletingLastPathComponent
        )
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func restoreToken(
        backup: StateBackupRecord,
        currentFingerprint: StateFileFingerprint?
    ) -> String {
        StateMaintenanceFileSupport.token([
            "hostwright-state-restore-v1",
            store.path,
            backup.backupID,
            backup.databaseSHA256 ?? "missing-backup-digest",
            currentFingerprint?.sha256 ?? "missing-current-database",
            String(currentFingerprint?.device ?? 0),
            String(currentFingerprint?.inode ?? 0)
        ])
    }

    private func currentStateFingerprint() throws -> StateFileFingerprint? {
        try normalizeAuthoritativeStateForFilesystemOperation()
        guard StateMaintenanceFileSupport.exists(store.path) else { return nil }
        try SecureStatePathManager().validateSensitiveRegularFile(store.path)
        return try StateMaintenanceFileSupport.fingerprint(store.path)
    }

    private func validateExistingJournalFiles(_ journal: StateMaintenanceJournal) throws {
        let candidates = [
            store.path,
            journal.stagedDatabasePath,
            journal.displacedDatabasePath
        ].compactMap { $0 }
        for path in candidates where StateMaintenanceFileSupport.exists(path) {
            try SecureStatePathManager().validateSensitiveRegularFile(path)
        }
    }

    private func repairToken(
        fingerprint: StateFileFingerprint,
        counts: [String: Int]
    ) -> String {
        let countContract = counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }
        return StateMaintenanceFileSupport.token([
            "hostwright-state-repair-v1",
            store.path,
            fingerprint.sha256,
            String(fingerprint.device),
            String(fingerprint.inode)
        ] + countContract)
    }

    private static let projectionDeleteOrder = [
        "observed_services",
        "observed_runtime_snapshots",
        "health_check_results"
    ]

    private static let backupManifestKeys: Set<String> = [
        "schemaVersion",
        "backupID",
        "createdAt",
        "purpose",
        "databaseSHA256",
        "databaseBytes",
        "stateSchemaVersion",
        "sourceHealth"
    ]
}

private enum StateBackupPurpose: String, Codable {
    case manual
    case preRestore = "pre-restore"
    case preRepair = "pre-repair"
}

private struct StateBackupManifest: Codable, Equatable {
    let schemaVersion: Int
    let backupID: String
    let createdAt: String
    let purpose: StateBackupPurpose
    let databaseSHA256: String
    let databaseBytes: UInt64
    let stateSchemaVersion: Int
    let sourceHealth: StateIntegrityHealth
}

private struct VerifiedStateBackup {
    let record: StateBackupRecord
    let purpose: StateBackupPurpose
    let sourceHealth: StateIntegrityHealth
    let repairableProjectionTables: [String]
}

private enum StateMaintenanceOperationKind: String, Codable {
    case restore
    case repair
}

private enum StateMaintenanceCheckpoint: String, Codable {
    case staging
    case prepared
    case sourceDisplaced = "source-displaced"
    case replacementPublished = "replacement-published"
    case mutationCommitted = "mutation-committed"
}

private struct StateMaintenanceJournal: Codable, Equatable {
    let schemaVersion: Int
    let operationID: String
    let operationKind: StateMaintenanceOperationKind
    let checkpoint: StateMaintenanceCheckpoint
    let databasePath: String
    let backupID: String?
    let backupSHA256: String?
    let preMutationBackupID: String?
    let stagedDatabasePath: String?
    let displacedDatabasePath: String?
    let sourceDatabaseExisted: Bool
    let preserveDisplacedDatabase: Bool
    let createdAt: String

    static func repair(
        operationID: String,
        databasePath: String,
        preMutationBackupID: String,
        createdAt: String
    ) -> StateMaintenanceJournal {
        StateMaintenanceJournal(
            schemaVersion: 1,
            operationID: operationID,
            operationKind: .repair,
            checkpoint: .prepared,
            databasePath: databasePath,
            backupID: nil,
            backupSHA256: nil,
            preMutationBackupID: preMutationBackupID,
            stagedDatabasePath: nil,
            displacedDatabasePath: nil,
            sourceDatabaseExisted: true,
            preserveDisplacedDatabase: false,
            createdAt: createdAt
        )
    }

    func updating(
        checkpoint: StateMaintenanceCheckpoint,
        backupSHA256: String? = nil
    ) -> StateMaintenanceJournal {
        StateMaintenanceJournal(
            schemaVersion: schemaVersion,
            operationID: operationID,
            operationKind: operationKind,
            checkpoint: checkpoint,
            databasePath: databasePath,
            backupID: backupID,
            backupSHA256: backupSHA256 ?? self.backupSHA256,
            preMutationBackupID: preMutationBackupID,
            stagedDatabasePath: stagedDatabasePath,
            displacedDatabasePath: displacedDatabasePath,
            sourceDatabaseExisted: sourceDatabaseExisted,
            preserveDisplacedDatabase: preserveDisplacedDatabase,
            createdAt: createdAt
        )
    }

    static func restore(
        operationID: String,
        databasePath: String,
        backupID: String,
        backupSHA256: String,
        preMutationBackupID: String?,
        stagedDatabasePath: String,
        displacedDatabasePath: String,
        sourceDatabaseExisted: Bool,
        preserveDisplacedDatabase: Bool,
        createdAt: String
    ) -> StateMaintenanceJournal {
        StateMaintenanceJournal(
            schemaVersion: 1,
            operationID: operationID,
            operationKind: .restore,
            checkpoint: .staging,
            databasePath: databasePath,
            backupID: backupID,
            backupSHA256: backupSHA256,
            preMutationBackupID: preMutationBackupID,
            stagedDatabasePath: stagedDatabasePath,
            displacedDatabasePath: displacedDatabasePath,
            sourceDatabaseExisted: sourceDatabaseExisted,
            preserveDisplacedDatabase: preserveDisplacedDatabase,
            createdAt: createdAt
        )
    }
}

enum StateRestoreInterruptionCheckpoint: String, CaseIterable {
    case staging
    case prepared
    case sourceDisplaced
    case replacementPublished
    case mutationCommitted
}

enum StateRestoreInterruptionWindow: String, CaseIterable {
    case stagePreparedBeforeJournal
    case sourceDisplacedBeforeJournal
    case replacementPublishedBeforeJournal
    case mutationCommittedBeforeJournal
}

enum StateRestoreInjectedFailurePoint: String, CaseIterable {
    case replacementPublishedBeforeJournal
}

private struct StateMaintenanceSimulatedInterruption: Error {
    let checkpoint: StateRestoreInterruptionCheckpoint
}

private struct StateMaintenanceSimulatedTornInterruption: Error {
    let window: StateRestoreInterruptionWindow
}

private struct StateMaintenanceInjectedFailure: Error {
    let point: StateRestoreInjectedFailurePoint
}

private struct StateMaintenanceSimulatedRepairInterruption: Error {}

private struct StateMaintenanceSimulatedRepairTransactionFailure: Error {}

private extension StateMaintenanceService {
    func performRestore(
        backup: StateBackupRecord,
        interruptAfter: StateRestoreInterruptionCheckpoint? = nil,
        interruptBefore: StateRestoreInterruptionWindow? = nil,
        failBefore: StateRestoreInjectedFailurePoint? = nil,
        beforeStagingCopy: () throws -> Void = {}
    ) throws -> StateRestoreResult {
        guard let expectedBackupSHA256 = backup.databaseSHA256,
              let expectedBackupBytes = backup.databaseBytes else {
            throw StateMaintenanceError.backupNotRestorable(
                id: backup.backupID,
                reason: "the verified backup has no database digest or size"
            )
        }
        let operationID = UUID().uuidString.lowercased()
        let parent = (store.path as NSString).deletingLastPathComponent
        let stagedPath = URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent(".hostwright-restore-stage-\(operationID).sqlite")
            .path
        let displacedPath = URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent(".hostwright-restore-displaced-\(operationID).sqlite")
            .path
        let sourceExisted = StateMaintenanceFileSupport.exists(store.path)
        if sourceExisted {
            try SecureStatePathManager().validateSensitiveRegularFile(store.path)
            try rejectSQLiteSidecars(store.path)
        }

        var currentReport = StateIntegrityReport(
            health: .unrecoverable,
            databaseSHA256: nil,
            databaseBytes: nil,
            stateSchemaVersion: nil,
            checks: [],
            repairableProjectionTables: [],
            recommendedAction: "Restore a verified backup."
        )
        var currentConnection: SQLiteConnection?
        if sourceExisted {
            do {
                let opened = try SQLiteConnection(
                    path: store.path,
                    createIfNeeded: false,
                    readOnly: true,
                    profile: .authoritativeState
                )
                currentConnection = opened
                currentReport = try StateIntegrityService(store: store).inspect(connection: opened)
            } catch {
                currentReport = StateIntegrityReport(
                    health: .unrecoverable,
                    databaseSHA256: (try? StateMaintenanceFileSupport.fingerprint(store.path))?.sha256,
                    databaseBytes: (try? StateMaintenanceFileSupport.fingerprint(store.path))?.bytes,
                    stateSchemaVersion: nil,
                    checks: [.init(identifier: "state.open", status: .failed, message: String(describing: error))],
                    repairableProjectionTables: [],
                    recommendedAction: "Restore a verified backup."
                )
            }
        }

        var preRestoreBackup: StateBackupRecord?
        if currentReport.health == .healthy, let currentConnection {
            preRestoreBackup = try createBackup(source: currentConnection, purpose: .preRestore)
        }
        try? currentConnection?.close()
        currentConnection = nil

        var journal = StateMaintenanceJournal.restore(
            operationID: operationID,
            databasePath: store.path,
            backupID: backup.backupID,
            backupSHA256: expectedBackupSHA256,
            preMutationBackupID: preRestoreBackup?.backupID,
            stagedDatabasePath: stagedPath,
            displacedDatabasePath: displacedPath,
            sourceDatabaseExisted: sourceExisted,
            preserveDisplacedDatabase: sourceExisted && currentReport.health != .healthy,
            createdAt: timestamp()
        )
        try writeNewJournal(journal)
        try interruptIfRequested(.staging, selected: interruptAfter)

        do {
            try beforeStagingCopy()
            let backupDatabasePath = URL(
                fileURLWithPath: backupDirectory(backup.backupID),
                isDirectory: true
            ).appendingPathComponent("state.sqlite").path
            try SecureStatePathManager().createExclusiveSensitiveFile(stagedPath)
            try StateMaintenanceFileSupport.copyExactSensitiveFile(
                from: backupDatabasePath,
                to: stagedPath,
                expectedSHA256: expectedBackupSHA256,
                expectedBytes: expectedBackupBytes,
                sourceChanged: { reason in
                    StateMaintenanceError.backupNotRestorable(
                        id: backup.backupID,
                        reason: "the selected backup changed while its restore stage was being created: \(reason)"
                    )
                }
            )
            try rejectSQLiteSidecars(stagedPath)
            let stagedFingerprint = try StateMaintenanceFileSupport.fingerprint(stagedPath)
            let stagedConnection = try SQLiteConnection(
                path: stagedPath,
                createIfNeeded: false,
                readOnly: true,
                profile: .portableArtifact
            )
            let stagedReport: StateIntegrityReport
            do {
                stagedReport = try StateIntegrityService(store: store).inspect(
                    connection: stagedConnection,
                    fingerprint: stagedFingerprint
                )
                try stagedConnection.close()
            } catch {
                try? stagedConnection.close()
                throw error
            }
            guard stagedFingerprint.sha256 == expectedBackupSHA256,
                  stagedFingerprint.bytes == expectedBackupBytes else {
                throw StateMaintenanceError.backupNotRestorable(
                    id: backup.backupID,
                    reason: "the selected backup changed while the staged restore copy was being created"
                )
            }
            guard stagedReport.health == .healthy,
                  stagedReport.stateSchemaVersion == MigrationRunner.latestSchemaVersion else {
                throw StateMaintenanceError.backupNotRestorable(
                    id: backup.backupID,
                    reason: "the staged restore copy failed full verification"
                )
            }
            try interruptIfRequested(
                .stagePreparedBeforeJournal,
                selected: interruptBefore
            )
            journal = journal.updating(
                checkpoint: .prepared,
                backupSHA256: stagedFingerprint.sha256
            )
            try replaceJournal(journal)
            try interruptIfRequested(.prepared, selected: interruptAfter)

            if sourceExisted {
                try rejectSQLiteSidecars(store.path)
                guard renamex_np(store.path, displacedPath, UInt32(RENAME_EXCL)) == 0 else {
                    throw StateMaintenanceError.io(
                        path: store.path,
                        message: "could not displace the current database atomically: \(String(cString: strerror(errno)))"
                    )
                }
                try StateMaintenanceFileSupport.synchronizeDirectory(parent)
                try interruptIfRequested(
                    .sourceDisplacedBeforeJournal,
                    selected: interruptBefore
                )
                journal = journal.updating(checkpoint: .sourceDisplaced)
                try replaceJournal(journal)
                try interruptIfRequested(.sourceDisplaced, selected: interruptAfter)
            }
            guard renamex_np(stagedPath, store.path, UInt32(RENAME_EXCL)) == 0 else {
                throw StateMaintenanceError.io(
                    path: store.path,
                    message: "could not publish the restored database atomically: \(String(cString: strerror(errno)))"
                )
            }
            try StateMaintenanceFileSupport.synchronizeDirectory(parent)
            try failIfRequested(
                .replacementPublishedBeforeJournal,
                selected: failBefore
            )
            try interruptIfRequested(
                .replacementPublishedBeforeJournal,
                selected: interruptBefore
            )
            journal = journal.updating(checkpoint: .replacementPublished)
            try replaceJournal(journal)
            try interruptIfRequested(.replacementPublished, selected: interruptAfter)

            let restoredConnection = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                profile: .authoritativeState
            )
            let cleared: [String: Int]
            do {
                let before = try StateIntegrityService(store: store).inspect(connection: restoredConnection)
                guard before.health == .healthy else {
                    throw StateMaintenanceError.recoveryFailed(
                        "the published restored database failed verification before projection reset"
                    )
                }
                cleared = try clearAllRebuildableProjections(
                    connection: restoredConnection,
                    eventID: "state-restore-\(operationID)",
                    backupID: backup.backupID
                )
                let after = try StateIntegrityService(store: store).inspect(connection: restoredConnection)
                guard after.health == .healthy else {
                    throw StateMaintenanceError.recoveryFailed(
                        "the restored database failed verification after projection reset"
                    )
                }
                try restoredConnection.close()
            } catch {
                try? restoredConnection.close()
                throw error
            }
            try interruptIfRequested(
                .mutationCommittedBeforeJournal,
                selected: interruptBefore
            )
            journal = journal.updating(checkpoint: .mutationCommitted)
            try replaceJournal(journal)
            try interruptIfRequested(.mutationCommitted, selected: interruptAfter)

            var quarantinePath: String?
            if sourceExisted {
                if journal.preserveDisplacedDatabase {
                    quarantinePath = displacedPath
                } else {
                    try StateMaintenanceFileSupport.unlinkSensitiveFile(displacedPath)
                }
            }
            try removeJournal()
            return StateRestoreResult(
                backupID: backup.backupID,
                preRestoreBackupID: preRestoreBackup?.backupID,
                quarantinedDatabasePath: quarantinePath,
                clearedProjectionRows: cleared,
                health: .healthy
            )
        } catch {
            if error is StateMaintenanceSimulatedInterruption
                || error is StateMaintenanceSimulatedTornInterruption {
                throw error
            }
            do {
                try rollbackRestore(journal)
            } catch let rollbackError {
                throw StateMaintenanceError.recoveryFailed(
                    "restore failed with \(error); automatic rollback also failed with \(rollbackError). Run 'hostwright state recover'."
                )
            }
            throw error
        }
    }

    func interruptIfRequested(
        _ checkpoint: StateRestoreInterruptionCheckpoint,
        selected: StateRestoreInterruptionCheckpoint?
    ) throws {
        if selected == checkpoint {
            throw StateMaintenanceSimulatedInterruption(checkpoint: checkpoint)
        }
    }

    func interruptIfRequested(
        _ window: StateRestoreInterruptionWindow,
        selected: StateRestoreInterruptionWindow?
    ) throws {
        if selected == window {
            throw StateMaintenanceSimulatedTornInterruption(window: window)
        }
    }

    func failIfRequested(
        _ point: StateRestoreInjectedFailurePoint,
        selected: StateRestoreInjectedFailurePoint?
    ) throws {
        if selected == point {
            throw StateMaintenanceInjectedFailure(point: point)
        }
    }

    func recoverRepair(_ journal: StateMaintenanceJournal) throws -> StateRecoveryResult {
        let report = integrityWithoutFence()
        if report.health == .healthy,
           try repairRollbackMutationCommitted(journal) {
            try removeJournal()
            return StateRecoveryResult(
                recovered: true,
                action: "Finalized rollback from the verified pre-repair snapshot.",
                health: .healthy
            )
        }
        if report.health == .unrecoverable {
            return try rollbackUnrecoverableRepair(journal)
        }

        let committed = report.health == .healthy
            ? try repairMutationCommitted(journal)
            : false
        if journal.checkpoint == .mutationCommitted, !committed {
            throw StateMaintenanceError.recoveryFailed(
                "the repair journal records a committed mutation, but its exact audit/projection evidence is missing"
            )
        }
        if report.health == .healthy, !committed {
            throw StateMaintenanceError.recoveryFailed(
                "state became healthy without the exact interrupted-repair audit evidence"
            )
        }
        try removeJournal()
        return StateRecoveryResult(
            recovered: true,
            action: committed
                ? "Finalized the committed projection repair."
                : "Rolled back the interrupted SQLite repair transaction; generate a fresh repair plan.",
            health: report.health
        )
    }

    func rollbackUnrecoverableRepair(
        _ journal: StateMaintenanceJournal
    ) throws -> StateRecoveryResult {
        let artifact = try verifiedPreRepairArtifact(journal)
        guard let expectedDigest = artifact.record.databaseSHA256,
              let expectedBytes = artifact.record.databaseBytes else {
            throw StateMaintenanceError.recoveryFailed(
                "the pre-repair rollback snapshot has no digest or size"
            )
        }
        let parent = (store.path as NSString).deletingLastPathComponent
        let stagedPath = URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent(".hostwright-repair-rollback-stage-\(journal.operationID).sqlite")
            .path
        let failedPath = URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent(".hostwright-repair-failed-\(journal.operationID).sqlite")
            .path
        var currentExists = StateMaintenanceFileSupport.exists(store.path)
        var failedExists = StateMaintenanceFileSupport.exists(failedPath)
        if failedExists {
            try SecureStatePathManager().validateSensitiveRegularFile(failedPath)
        }

        if !failedExists {
            guard currentExists else {
                throw StateMaintenanceError.recoveryFailed(
                    "the interrupted repair database disappeared before rollback evidence was established"
                )
            }
            try rejectSQLiteSidecars(store.path)
            try ensureRepairRollbackStage(
                stagedPath,
                artifact: artifact,
                expectedDigest: expectedDigest,
                expectedBytes: expectedBytes
            )
            guard renamex_np(store.path, failedPath, UInt32(RENAME_EXCL)) == 0 else {
                throw StateMaintenanceError.io(
                    path: store.path,
                    message: "could not preserve the failed repaired database: \(String(cString: strerror(errno)))"
                )
            }
            try StateMaintenanceFileSupport.synchronizeDirectory(parent)
            currentExists = false
            failedExists = true
        }

        guard failedExists else {
            throw StateMaintenanceError.recoveryFailed(
                "the failed repaired database was not preserved"
            )
        }
        if !currentExists {
            try ensureRepairRollbackStage(
                stagedPath,
                artifact: artifact,
                expectedDigest: expectedDigest,
                expectedBytes: expectedBytes
            )
            guard renamex_np(stagedPath, store.path, UInt32(RENAME_EXCL)) == 0 else {
                throw StateMaintenanceError.io(
                    path: store.path,
                    message: "could not publish the pre-repair rollback snapshot: \(String(cString: strerror(errno)))"
                )
            }
            try StateMaintenanceFileSupport.synchronizeDirectory(parent)
            currentExists = true
        }
        guard currentExists else {
            throw StateMaintenanceError.recoveryFailed(
                "the pre-repair rollback snapshot was not published"
            )
        }
        if StateMaintenanceFileSupport.exists(stagedPath) {
            let currentFingerprint = try StateMaintenanceFileSupport.fingerprint(store.path)
            guard currentFingerprint.sha256 == expectedDigest,
                  currentFingerprint.bytes == expectedBytes else {
                throw StateMaintenanceError.recoveryFailed(
                    "the active database is ambiguous while a repair rollback stage also exists"
                )
            }
            try cleanupRestoreStage(stagedPath)
        }

        let fingerprint = try StateMaintenanceFileSupport.fingerprint(store.path)
        let expectedIdentity = try store.configuration.validateSQLiteFileSet()
        let connection = try SQLiteConnection(
            path: store.path,
            createIfNeeded: false,
            profile: .authoritativeState
        )
        let post: StateIntegrityReport
        do {
            let openedIdentity = try store.configuration.validateSQLiteFileSet()
            guard expectedIdentity == openedIdentity else {
                throw StateStoreError.pathPolicyViolation(
                    path: store.path,
                    message: "the repair rollback target identity changed while SQLite was opening it"
                )
            }
            let before = try StateIntegrityService(store: store).inspect(
                connection: connection,
                fingerprint: fingerprint
            )
            if before.health == .healthy,
               try eventExists(repairRollbackEventID(journal), connection: connection) {
                post = before
            } else {
                guard fingerprint.sha256 == expectedDigest,
                      fingerprint.bytes == expectedBytes,
                      before.health == .degraded,
                      before.repairableProjectionTables == artifact.repairableProjectionTables else {
                    throw StateMaintenanceError.recoveryFailed(
                        "the published pre-repair snapshot does not match its recorded degraded projection contract"
                    )
                }
                let counts = try projectionCounts(
                    artifact.repairableProjectionTables,
                    connection: connection
                )
                try connection.transaction {
                    for table in Self.projectionDeleteOrder where counts[table] != nil {
                        try connection.execute("DELETE FROM \(table)")
                    }
                    try appendMaintenanceEvent(
                        connection: connection,
                        id: repairRollbackEventID(journal),
                        type: "state.maintenance.repair-rollback",
                        message: "State repair rolled back to verified snapshot \(artifact.record.backupID); damaged reconstructible projections were cleared.",
                        payload: counts,
                        ignoreExisting: true
                    )
                }
                post = try StateIntegrityService(store: store).inspect(connection: connection)
            }
            guard post.health == .healthy else {
                throw StateMaintenanceError.recoveryFailed(
                    "the pre-repair rollback did not restore healthy state"
                )
            }
            try connection.close()
        } catch {
            try? connection.close()
            throw error
        }
        try StateMaintenanceFileSupport.synchronizeDirectory(parent)
        try removeJournal()
        return StateRecoveryResult(
            recovered: true,
            action: "Restored the verified pre-repair snapshot and preserved the failed repaired database at \(failedPath).",
            health: post.health
        )
    }

    func ensureRepairRollbackStage(
        _ stagedPath: String,
        artifact: VerifiedStateBackup,
        expectedDigest: String,
        expectedBytes: UInt64
    ) throws {
        if StateMaintenanceFileSupport.exists(stagedPath) {
            if let fingerprint = try? StateMaintenanceFileSupport.fingerprint(stagedPath),
               fingerprint.sha256 == expectedDigest,
               fingerprint.bytes == expectedBytes {
                return
            }
            try cleanupRestoreStage(stagedPath)
        }
        try SecureStatePathManager().createExclusiveSensitiveFile(stagedPath)
        let backupPath = URL(
            fileURLWithPath: backupDirectory(artifact.record.backupID),
            isDirectory: true
        ).appendingPathComponent("state.sqlite").path
        try StateMaintenanceFileSupport.copyExactSensitiveFile(
            from: backupPath,
            to: stagedPath,
            expectedSHA256: expectedDigest,
            expectedBytes: expectedBytes,
            sourceChanged: { reason in
                StateMaintenanceError.recoveryFailed(
                    "the verified pre-repair snapshot changed while its rollback stage was being created: \(reason)"
                )
            }
        )
        let fingerprint = try StateMaintenanceFileSupport.fingerprint(stagedPath)
        guard fingerprint.sha256 == expectedDigest,
              fingerprint.bytes == expectedBytes else {
            throw StateMaintenanceError.recoveryFailed(
                "the copied pre-repair rollback stage does not match the verified snapshot"
            )
        }
        let connection = try SQLiteConnection(
            path: stagedPath,
            createIfNeeded: false,
            readOnly: true,
            profile: .portableArtifact
        )
        do {
            let report = try StateIntegrityService(store: store).inspect(
                connection: connection,
                fingerprint: fingerprint
            )
            guard report.health == .degraded,
                  report.repairableProjectionTables == artifact.repairableProjectionTables else {
                throw StateMaintenanceError.recoveryFailed(
                    "the pre-repair rollback stage no longer matches the recorded projection damage"
                )
            }
            try connection.close()
        } catch {
            try? connection.close()
            throw error
        }
    }

    func verifiedPreRepairArtifact(
        _ journal: StateMaintenanceJournal
    ) throws -> VerifiedStateBackup {
        guard let backupID = journal.preMutationBackupID else {
            throw StateMaintenanceError.recoveryFailed(
                "the repair journal has no pre-mutation rollback snapshot"
            )
        }
        let artifact = try verifiedBackupArtifact(backupID)
        guard artifact.purpose == .preRepair,
              artifact.sourceHealth == .degraded,
              !artifact.record.restorable,
              !artifact.repairableProjectionTables.isEmpty else {
            throw StateMaintenanceError.recoveryFailed(
                "the repair rollback snapshot does not match the pre-repair degraded-state contract"
            )
        }
        return artifact
    }

    func repairRollbackMutationCommitted(
        _ journal: StateMaintenanceJournal
    ) throws -> Bool {
        let parent = (store.path as NSString).deletingLastPathComponent
        let failedPath = URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent(".hostwright-repair-failed-\(journal.operationID).sqlite")
            .path
        guard StateMaintenanceFileSupport.exists(failedPath) else { return false }
        try SecureStatePathManager().validateSensitiveRegularFile(failedPath)
        let artifact = try verifiedPreRepairArtifact(journal)
        let connection = try SQLiteConnection(
            path: store.path,
            createIfNeeded: false,
            readOnly: true,
            profile: .authoritativeState
        )
        defer { try? connection.close() }
        guard try eventExists(repairRollbackEventID(journal), connection: connection) else {
            return false
        }
        return try projectionCounts(
            artifact.repairableProjectionTables,
            connection: connection
        ).values.allSatisfy { $0 == 0 }
    }

    func repairRollbackEventID(_ journal: StateMaintenanceJournal) -> String {
        "state-repair-rollback-\(journal.operationID)"
    }

    func rollbackRestore(_ journal: StateMaintenanceJournal) throws {
        guard journal.operationKind == .restore,
              let stagedPath = journal.stagedDatabasePath,
              let displacedPath = journal.displacedDatabasePath else {
            throw StateMaintenanceError.recoveryFailed("restore rollback received an invalid journal")
        }
        let parent = (store.path as NSString).deletingLastPathComponent
        let failedPath = URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent(".hostwright-restore-failed-\(journal.operationID).sqlite")
            .path
        if StateMaintenanceFileSupport.exists(store.path) {
            try normalizeAuthoritativeStateForFilesystemOperation()
        }
        var currentExists = StateMaintenanceFileSupport.exists(store.path)
        let stagedExists = StateMaintenanceFileSupport.exists(stagedPath)
        var displacedExists = StateMaintenanceFileSupport.exists(displacedPath)
        var failedExists = StateMaintenanceFileSupport.exists(failedPath)

        if failedExists {
            try SecureStatePathManager().validateSensitiveRegularFile(failedPath)
        } else {
            let checkpointClaimsPublication = journal.checkpoint == .replacementPublished
                || journal.checkpoint == .mutationCommitted
            let publicationCompletedBeforeCheckpoint: Bool
            if currentExists,
               !stagedExists,
               displacedExists || !journal.sourceDatabaseExisted {
                publicationCompletedBeforeCheckpoint = try replacementMatchesRestoreIntent(journal)
            } else {
                publicationCompletedBeforeCheckpoint = false
            }
            if checkpointClaimsPublication || publicationCompletedBeforeCheckpoint {
                guard currentExists else {
                    throw StateMaintenanceError.recoveryFailed(
                        "the published replacement database is missing"
                    )
                }
                if journal.sourceDatabaseExisted, !displacedExists {
                    _ = try verifiedPreMutationBackup(journal)
                }
                try SecureStatePathManager().validateSensitiveRegularFile(store.path)
                guard renamex_np(store.path, failedPath, UInt32(RENAME_EXCL)) == 0 else {
                    throw StateMaintenanceError.io(
                        path: store.path,
                        message: "could not preserve the failed replacement: \(String(cString: strerror(errno)))"
                    )
                }
                try StateMaintenanceFileSupport.synchronizeDirectory(parent)
                currentExists = false
                failedExists = true
            }
        }

        if failedExists, currentExists, displacedExists {
            throw StateMaintenanceError.recoveryFailed(
                "restore rollback found both an active database and a displaced original after preserving the failed replacement"
            )
        }
        if journal.sourceDatabaseExisted, displacedExists, !currentExists {
            try SecureStatePathManager().validateSensitiveRegularFile(displacedPath)
            guard renamex_np(displacedPath, store.path, UInt32(RENAME_EXCL)) == 0 else {
                throw StateMaintenanceError.io(
                    path: store.path,
                    message: "could not restore the displaced original: \(String(cString: strerror(errno)))"
                )
            }
            try StateMaintenanceFileSupport.synchronizeDirectory(parent)
            currentExists = true
            displacedExists = false
        }
        if journal.sourceDatabaseExisted, !currentExists, !displacedExists {
            try restorePreMutationBackupForRollback(journal)
            currentExists = true
        }
        if journal.sourceDatabaseExisted {
            guard currentExists, !displacedExists else {
                throw StateMaintenanceError.recoveryFailed(
                    "restore rollback could not re-establish the pre-operation database authority"
                )
            }
            if !journal.preserveDisplacedDatabase,
               integrityWithoutFence().health != .healthy {
                throw StateMaintenanceError.recoveryFailed(
                    "restore rollback did not recover a healthy pre-operation database"
                )
            }
        } else {
            guard !currentExists, !displacedExists else {
                throw StateMaintenanceError.recoveryFailed(
                    "restore rollback could not return the target to its pre-operation missing state"
                )
            }
        }
        try cleanupRestoreStage(stagedPath)
        try StateMaintenanceFileSupport.synchronizeDirectory(parent)
        try removeJournal()
    }

    func verifiedPreMutationBackup(
        _ journal: StateMaintenanceJournal
    ) throws -> StateBackupRecord {
        guard let backupID = journal.preMutationBackupID else {
            throw StateMaintenanceError.recoveryFailed(
                "the displaced pre-operation database is unavailable and no verified rollback backup was recorded"
            )
        }
        return try restorableBackup(backupID)
    }

    func restorePreMutationBackupForRollback(
        _ journal: StateMaintenanceJournal
    ) throws {
        let backup = try verifiedPreMutationBackup(journal)
        guard let expectedDigest = backup.databaseSHA256,
              let expectedBytes = backup.databaseBytes else {
            throw StateMaintenanceError.recoveryFailed(
                "the verified rollback backup has no digest or size"
            )
        }
        let parent = (store.path as NSString).deletingLastPathComponent
        let rollbackStage = URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent(".hostwright-restore-rollback-\(journal.operationID).sqlite")
            .path
        if StateMaintenanceFileSupport.exists(rollbackStage) {
            try cleanupRestoreStage(rollbackStage)
        }
        try SecureStatePathManager().createExclusiveSensitiveFile(rollbackStage)
        let backupPath = URL(
            fileURLWithPath: backupDirectory(backup.backupID),
            isDirectory: true
        ).appendingPathComponent("state.sqlite").path
        try StateMaintenanceFileSupport.copyExactSensitiveFile(
            from: backupPath,
            to: rollbackStage,
            expectedSHA256: expectedDigest,
            expectedBytes: expectedBytes,
            sourceChanged: { reason in
                StateMaintenanceError.recoveryFailed(
                    "the verified pre-operation backup changed while its rollback stage was being created: \(reason)"
                )
            }
        )
        let fingerprint = try StateMaintenanceFileSupport.fingerprint(rollbackStage)
        guard fingerprint.sha256 == expectedDigest,
              fingerprint.bytes == expectedBytes else {
            throw StateMaintenanceError.recoveryFailed(
                "the rollback copy does not match the recorded pre-operation backup"
            )
        }
        let rollbackConnection = try SQLiteConnection(
            path: rollbackStage,
            createIfNeeded: false,
            readOnly: true,
            profile: .portableArtifact
        )
        do {
            let report = try StateIntegrityService(store: store).inspect(
                connection: rollbackConnection,
                fingerprint: fingerprint
            )
            guard report.health == .healthy else {
                throw StateMaintenanceError.recoveryFailed(
                    "the pre-operation rollback backup no longer passes full verification"
                )
            }
            try rollbackConnection.close()
        } catch {
            try? rollbackConnection.close()
            throw error
        }
        guard renamex_np(rollbackStage, store.path, UInt32(RENAME_EXCL)) == 0 else {
            throw StateMaintenanceError.io(
                path: store.path,
                message: "could not publish the verified rollback backup: \(String(cString: strerror(errno)))"
            )
        }
        try StateMaintenanceFileSupport.synchronizeDirectory(parent)
    }

    func cleanupRestoreStage(_ stagedPath: String) throws {
        for suffix in ["-wal", "-shm", "-journal", ""] {
            let path = stagedPath + suffix
            if StateMaintenanceFileSupport.exists(path) {
                try StateMaintenanceFileSupport.unlinkSensitiveFile(path)
            }
        }
    }

    func recoverRestore(_ journal: StateMaintenanceJournal) throws -> StateRecoveryResult {
        guard let stagedPath = journal.stagedDatabasePath,
              let displacedPath = journal.displacedDatabasePath else {
            throw StateMaintenanceError.recoveryFailed("the restore journal has no staged or displaced path")
        }
        let parent = (store.path as NSString).deletingLastPathComponent
        switch journal.checkpoint {
        case .staging:
            guard !StateMaintenanceFileSupport.exists(displacedPath),
                  StateMaintenanceFileSupport.exists(store.path) == journal.sourceDatabaseExisted else {
                throw StateMaintenanceError.recoveryFailed(
                    "the filesystem does not match the restore staging checkpoint"
                )
            }
            try cleanupRestoreStage(stagedPath)
            try removeJournal()
            return StateRecoveryResult(
                recovered: true,
                action: "Removed the incomplete restore stage before any authority changed.",
                health: integrityWithoutFence().health
            )
        case .prepared:
            let currentExists = StateMaintenanceFileSupport.exists(store.path)
            let stagedExists = StateMaintenanceFileSupport.exists(stagedPath)
            let displacedExists = StateMaintenanceFileSupport.exists(displacedPath)
            if journal.sourceDatabaseExisted,
               !currentExists,
               stagedExists,
               displacedExists {
                guard renamex_np(displacedPath, store.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw StateMaintenanceError.io(
                        path: store.path,
                        message: "could not roll back the torn source displacement: \(String(cString: strerror(errno)))"
                    )
                }
                try StateMaintenanceFileSupport.synchronizeDirectory(parent)
                try cleanupRestoreStage(stagedPath)
                try removeJournal()
                return StateRecoveryResult(
                    recovered: true,
                    action: "Rolled back a source displacement that completed before its journal checkpoint.",
                    health: integrityWithoutFence().health
                )
            }
            if !journal.sourceDatabaseExisted,
               currentExists,
               !stagedExists,
               !displacedExists {
                guard try replacementMatchesRestoreIntent(journal) else {
                    throw StateMaintenanceError.recoveryFailed(
                        "a database appeared during an uncheckpointed restore, but it does not match the verified replacement"
                    )
                }
                let promoted = journal.updating(checkpoint: .replacementPublished)
                try replaceJournal(promoted)
                return try recoverRestore(promoted)
            }
            guard !displacedExists,
                  currentExists == journal.sourceDatabaseExisted else {
                throw StateMaintenanceError.recoveryFailed(
                    "the filesystem does not match the prepared restore checkpoint"
                )
            }
            if stagedExists {
                try cleanupRestoreStage(stagedPath)
            }
            try removeJournal()
            return StateRecoveryResult(
                recovered: true,
                action: "Cancelled the unpublished restore and preserved the original database.",
                health: integrityWithoutFence().health
            )
        case .sourceDisplaced:
            guard journal.sourceDatabaseExisted else {
                throw StateMaintenanceError.recoveryFailed(
                    "a source-displaced checkpoint cannot exist when no source database was present"
                )
            }
            let currentExists = StateMaintenanceFileSupport.exists(store.path)
            let stagedExists = StateMaintenanceFileSupport.exists(stagedPath)
            let displacedExists = StateMaintenanceFileSupport.exists(displacedPath)
            if currentExists, displacedExists, !stagedExists {
                guard try replacementMatchesRestoreIntent(journal) else {
                    throw StateMaintenanceError.recoveryFailed(
                        "the uncheckpointed replacement does not match the verified restore intent"
                    )
                }
                let promoted = journal.updating(checkpoint: .replacementPublished)
                try replaceJournal(promoted)
                return try recoverRestore(promoted)
            }
            if currentExists, !displacedExists {
                if stagedExists {
                    try cleanupRestoreStage(stagedPath)
                }
                try removeJournal()
                return StateRecoveryResult(
                    recovered: true,
                    action: "Finalized rollback of the interrupted restore before publication.",
                    health: integrityWithoutFence().health
                )
            }
            guard !currentExists, displacedExists, stagedExists else {
                throw StateMaintenanceError.recoveryFailed(
                    "the filesystem does not match the recorded source-displaced checkpoint"
                )
            }
            guard renamex_np(displacedPath, store.path, UInt32(RENAME_EXCL)) == 0 else {
                throw StateMaintenanceError.io(
                    path: store.path,
                    message: "could not restore the displaced database: \(String(cString: strerror(errno)))"
                )
            }
            try StateMaintenanceFileSupport.synchronizeDirectory(parent)
            try cleanupRestoreStage(stagedPath)
            try removeJournal()
            return StateRecoveryResult(
                recovered: true,
                action: "Rolled back the interrupted restore before publication.",
                health: integrityWithoutFence().health
            )
        case .replacementPublished, .mutationCommitted:
            guard StateMaintenanceFileSupport.exists(store.path) else {
                if journal.sourceDatabaseExisted,
                   StateMaintenanceFileSupport.exists(displacedPath) {
                    guard renamex_np(displacedPath, store.path, UInt32(RENAME_EXCL)) == 0 else {
                        throw StateMaintenanceError.io(path: store.path, message: String(cString: strerror(errno)))
                    }
                    try StateMaintenanceFileSupport.synchronizeDirectory(parent)
                    try removeJournal()
                    return StateRecoveryResult(
                        recovered: true,
                        action: "Restored the displaced original after the replacement disappeared.",
                        health: integrityWithoutFence().health
                    )
                }
                throw StateMaintenanceError.recoveryFailed("both the replacement and recoverable original are missing")
            }
            guard !StateMaintenanceFileSupport.exists(stagedPath) else {
                throw StateMaintenanceError.recoveryFailed(
                    "the published restore still has an unexpected staged database"
                )
            }
            let replacementMatchedBeforeOpen = journal.checkpoint == .replacementPublished
                ? try replacementMatchesRestoreIntent(journal)
                : false
            let expectedIdentity = try store.configuration.validateSQLiteFileSet()
            let connection = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                profile: .authoritativeState
            )
            do {
                let openedIdentity = try store.configuration.validateSQLiteFileSet()
                guard expectedIdentity == openedIdentity else {
                    throw StateStoreError.pathPolicyViolation(
                        path: store.path,
                        message: "the restore target identity changed while SQLite was opening it"
                    )
                }
                let report = try StateIntegrityService(store: store).inspect(connection: connection)
                guard report.health == .healthy else {
                    try connection.close()
                    try rollbackRestore(journal)
                    return StateRecoveryResult(
                        recovered: true,
                        action: "Rejected the invalid replacement and restored the displaced original.",
                        health: integrityWithoutFence().health
                    )
                }
                var finalizedJournal = journal
                if journal.checkpoint == .replacementPublished {
                    if replacementMatchedBeforeOpen {
                        _ = try clearAllRebuildableProjections(
                            connection: connection,
                            eventID: "state-restore-\(journal.operationID)",
                            backupID: journal.backupID ?? "unknown"
                        )
                    } else if try restoreMutationCommitted(journal, connection: connection) {
                        // The projection transaction committed before its journal checkpoint.
                    } else {
                        try connection.close()
                        try rollbackRestore(journal)
                        return StateRecoveryResult(
                            recovered: true,
                            action: "Rejected a replacement whose digest/effects did not match the restore intent and restored the original.",
                            health: integrityWithoutFence().health
                        )
                    }
                    finalizedJournal = journal.updating(checkpoint: .mutationCommitted)
                    try replaceJournal(finalizedJournal)
                } else if !(try restoreMutationCommitted(journal, connection: connection)) {
                    try connection.close()
                    try rollbackRestore(journal)
                    return StateRecoveryResult(
                        recovered: true,
                        action: "Rejected a committed checkpoint whose exact projection/audit effects were missing and restored the original.",
                        health: integrityWithoutFence().health
                    )
                }
                let post = try StateIntegrityService(store: store).inspect(connection: connection)
                guard post.health == .healthy else {
                    throw StateMaintenanceError.recoveryFailed("the replacement failed final recovery verification")
                }
                try connection.close()
                if finalizedJournal.sourceDatabaseExisted,
                   StateMaintenanceFileSupport.exists(displacedPath),
                   !finalizedJournal.preserveDisplacedDatabase {
                    try StateMaintenanceFileSupport.unlinkSensitiveFile(displacedPath)
                }
                if StateMaintenanceFileSupport.exists(stagedPath) {
                    try StateMaintenanceFileSupport.unlinkSensitiveFile(stagedPath)
                }
                try removeJournal()
                return StateRecoveryResult(
                    recovered: true,
                    action: finalizedJournal.preserveDisplacedDatabase
                        ? "Finalized the restored database and preserved the unreadable original as quarantine evidence."
                        : "Finalized and verified the published restored database.",
                    health: post.health
                )
            } catch {
                try? connection.close()
                throw error
            }
        }
    }

    func replacementMatchesRestoreIntent(_ journal: StateMaintenanceJournal) throws -> Bool {
        guard let expectedDigest = journal.backupSHA256 else { return false }
        return try StateMaintenanceFileSupport.fingerprint(store.path).sha256 == expectedDigest
    }

    func restoreMutationCommitted(
        _ journal: StateMaintenanceJournal,
        connection: SQLiteConnection
    ) throws -> Bool {
        guard try eventExists("state-restore-\(journal.operationID)", connection: connection) else {
            return false
        }
        return try projectionCounts(Self.projectionDeleteOrder, connection: connection)
            .values
            .allSatisfy { $0 == 0 }
    }

    func repairMutationCommitted(_ journal: StateMaintenanceJournal) throws -> Bool {
        let artifact = try verifiedPreRepairArtifact(journal)
        let connection = try SQLiteConnection(
            path: store.path,
            createIfNeeded: false,
            readOnly: true,
            profile: .authoritativeState
        )
        defer { try? connection.close() }
        guard try eventExists(
            "state-repair-\(journal.operationID)",
            connection: connection
        ) else {
            return false
        }
        return try projectionCounts(
            artifact.repairableProjectionTables,
            connection: connection
        ).values.allSatisfy { $0 == 0 }
    }

    func eventExists(_ id: String, connection: SQLiteConnection) throws -> Bool {
        guard let value = try connection.query(
            "SELECT COUNT(*) FROM event_ledger WHERE id = ?",
            bindings: [.text(id)]
        ).first?.first ?? nil,
        let count = Int(value) else {
            throw StateMaintenanceError.sqlite(
                message: "could not verify state-maintenance audit event \(id)"
            )
        }
        return count == 1
    }

    func projectionCounts(
        _ tables: [String],
        connection: SQLiteConnection
    ) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for table in tables.sorted() {
            guard Self.projectionDeleteOrder.contains(table) else {
                throw StateMaintenanceError.unsafeRepair("table \(table) is not a reconstructible projection")
            }
            guard let value = try connection.query("SELECT COUNT(*) FROM \(table)").first?.first ?? nil,
                  let count = Int(value) else {
                throw StateMaintenanceError.sqlite(message: "could not count projection table \(table)")
            }
            result[table] = count
        }
        return result
    }

    func clearAllRebuildableProjections(
        connection: SQLiteConnection,
        eventID: String,
        backupID: String
    ) throws -> [String: Int] {
        let counts = try projectionCounts(Self.projectionDeleteOrder, connection: connection)
        try connection.transaction {
            for table in Self.projectionDeleteOrder {
                try connection.execute("DELETE FROM \(table)")
            }
            try appendMaintenanceEvent(
                connection: connection,
                id: eventID,
                type: "state.maintenance.restored",
                message: "State was restored from verified backup \(backupID); rebuildable projections were cleared.",
                payload: counts,
                ignoreExisting: true
            )
        }
        return counts
    }

    func appendMaintenanceEvent(
        connection: SQLiteConnection,
        id: String,
        type: String,
        message: String,
        payload: [String: Int],
        ignoreExisting: Bool = false
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadJSON = String(
            data: try encoder.encode(payload),
            encoding: .utf8
        ) ?? "{}"
        try connection.run(
            """
            INSERT \(ignoreExisting ? "OR IGNORE " : "")INTO event_ledger (
                id, timestamp, severity, type, source, project_id, service_name,
                runtime_adapter, message, payload_json_redacted
            ) VALUES (?, ?, 'info', ?, 'state-maintenance', NULL, NULL, NULL, ?, ?)
            """,
            bindings: [
                .text(id),
                .text(timestamp()),
                .text(type),
                .text(message),
                .text(payloadJSON)
            ]
        )
    }

    func integrityWithoutFence() -> StateIntegrityReport {
        let fingerprint = try? StateMaintenanceFileSupport.fingerprint(store.path)
        do {
            let connection = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                readOnly: true,
                profile: .authoritativeState
            )
            defer { try? connection.close() }
            let report = try StateIntegrityService(store: store).inspect(
                connection: connection,
                fingerprint: fingerprint
            )
            try connection.close()
            return report
        } catch {
            return StateIntegrityReport(
                health: .unrecoverable,
                databaseSHA256: fingerprint?.sha256,
                databaseBytes: fingerprint?.bytes,
                stateSchemaVersion: nil,
                checks: [.init(identifier: "state.open", status: .failed, message: String(describing: error))],
                repairableProjectionTables: [],
                recommendedAction: "Restore a verified backup or recover the pending maintenance journal."
            )
        }
    }

    func writeNewJournal(_ journal: StateMaintenanceJournal) throws {
        guard !StateMaintenanceFileSupport.exists(paths.journalPath) else {
            throw StateMaintenanceError.operationInProgress(paths.journalPath)
        }
        try SecureStatePathManager().writePrivateJSON(journal, to: paths.journalPath)
    }

    func replaceJournal(_ journal: StateMaintenanceJournal) throws {
        try SecureStatePathManager().replacePrivateJSON(journal, at: paths.journalPath)
    }

    func removeJournal() throws {
        try StateMaintenanceFileSupport.unlinkSensitiveFile(paths.journalPath)
    }

    func readAndValidateJournal() throws -> StateMaintenanceJournal {
        let data = try SecureStatePathManager().readPrivateFile(
            paths.journalPath,
            maximumBytes: 128 * 1_024
        )
        do {
            try StateStrictJSONObject.validate(
                data,
                allowedKeys: Self.journalAllowedKeys,
                requiredKeys: Self.journalRequiredKeys
            )
        } catch let error as StateStrictJSONError {
            throw StateMaintenanceError.recoveryFailed(
                "the maintenance journal contract is invalid: \(error.reason)"
            )
        }
        let journal: StateMaintenanceJournal
        do {
            journal = try JSONDecoder().decode(StateMaintenanceJournal.self, from: data)
        } catch {
            throw StateMaintenanceError.recoveryFailed("the maintenance journal is invalid JSON")
        }
        guard journal.schemaVersion == 1,
              journal.databasePath == store.path,
              UUID(uuidString: journal.operationID)?.uuidString.lowercased() == journal.operationID,
              !journal.createdAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StateMaintenanceError.recoveryFailed("the maintenance journal identity does not match this state store")
        }
        switch journal.operationKind {
        case .repair:
            guard journal.stagedDatabasePath == nil,
                  journal.displacedDatabasePath == nil,
                  journal.backupID == nil,
                  journal.backupSHA256 == nil,
                  journal.preMutationBackupID != nil,
                  journal.sourceDatabaseExisted,
                  !journal.preserveDisplacedDatabase,
                  journal.checkpoint == .prepared || journal.checkpoint == .mutationCommitted else {
                throw StateMaintenanceError.recoveryFailed("the repair journal contains an invalid filesystem contract")
            }
        case .restore:
            let parent = (store.path as NSString).deletingLastPathComponent
            let expectedStage = URL(fileURLWithPath: parent, isDirectory: true)
                .appendingPathComponent(".hostwright-restore-stage-\(journal.operationID).sqlite")
                .path
            let expectedDisplaced = URL(fileURLWithPath: parent, isDirectory: true)
                .appendingPathComponent(".hostwright-restore-displaced-\(journal.operationID).sqlite")
                .path
            guard journal.stagedDatabasePath == expectedStage,
                  journal.displacedDatabasePath == expectedDisplaced,
                  let backupID = journal.backupID,
                  journal.backupSHA256?.range(
                    of: "^[a-f0-9]{64}$",
                    options: .regularExpression
                  ) != nil,
                  !journal.preserveDisplacedDatabase || journal.sourceDatabaseExisted,
                  journal.checkpoint != .sourceDisplaced || journal.sourceDatabaseExisted else {
                throw StateMaintenanceError.recoveryFailed("the restore journal contains an invalid filesystem or backup contract")
            }
            try StateMaintenanceFileSupport.validateBackupID(backupID)
        }
        if let preMutationBackupID = journal.preMutationBackupID {
            try StateMaintenanceFileSupport.validateBackupID(preMutationBackupID)
        }
        return journal
    }

    static var journalAllowedKeys: Set<String> {
        [
            "schemaVersion",
            "operationID",
            "operationKind",
            "checkpoint",
            "databasePath",
            "backupID",
            "backupSHA256",
            "preMutationBackupID",
            "stagedDatabasePath",
            "displacedDatabasePath",
            "sourceDatabaseExisted",
            "preserveDisplacedDatabase",
            "createdAt"
        ]
    }

    static var journalRequiredKeys: Set<String> {
        [
            "schemaVersion",
            "operationID",
            "operationKind",
            "checkpoint",
            "databasePath",
            "sourceDatabaseExisted",
            "preserveDisplacedDatabase",
            "createdAt"
        ]
    }
}
