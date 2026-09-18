import Darwin
import Foundation
import HostwrightCore
import HostwrightControlPlane

public struct StateUpgradeSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let databasePath: String
    public let snapshotPath: String
    public let databaseSHA256: String
    public let databaseBytes: UInt64
    public let stateSchemaVersion: Int

    public init(
        schemaVersion: Int = 1,
        databasePath: String,
        snapshotPath: String,
        databaseSHA256: String,
        databaseBytes: UInt64,
        stateSchemaVersion: Int
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "stateUpgradeSnapshot"
        self.databasePath = databasePath
        self.snapshotPath = snapshotPath
        self.databaseSHA256 = databaseSHA256
        self.databaseBytes = databaseBytes
        self.stateSchemaVersion = stateSchemaVersion
    }

    public func validate() throws {
        let normalizedDatabase = try HostwrightLocalPathResolver.normalizedAbsolutePath(
            databasePath,
            role: "state upgrade database"
        )
        let normalizedSnapshot = try HostwrightLocalPathResolver.normalizedAbsolutePath(
            snapshotPath,
            role: "state upgrade snapshot"
        )
        guard schemaVersion == 1,
              kind == "stateUpgradeSnapshot",
              normalizedDatabase == databasePath,
              normalizedSnapshot == snapshotPath,
              databasePath != snapshotPath,
              databaseSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              databaseBytes > 0,
              (0...MigrationRunner.latestSchemaVersion).contains(stateSchemaVersion) else {
            throw StateMaintenanceError.recoveryFailed("state upgrade snapshot metadata is invalid")
        }
    }
}

public struct StateUpgradeMigrationResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let fromSchemaVersion: Int
    public let toSchemaVersion: Int

    public init(fromSchemaVersion: Int, toSchemaVersion: Int) {
        self.schemaVersion = 1
        self.kind = "stateUpgradeMigrationResult"
        self.fromSchemaVersion = fromSchemaVersion
        self.toSchemaVersion = toSchemaVersion
    }
}

public struct StateUpgradePreparedMigrationResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let migration: StateUpgradeMigrationResult
    public let rollbackSnapshot: StateUpgradeSnapshot?

    public init(
        migration: StateUpgradeMigrationResult,
        rollbackSnapshot: StateUpgradeSnapshot?
    ) {
        self.schemaVersion = 1
        self.kind = "stateUpgradePreparedMigrationResult"
        self.migration = migration
        self.rollbackSnapshot = rollbackSnapshot
    }
}

public struct StateUpgradeRevision: Codable, Equatable, Sendable {
    public let databaseSHA256: String
    public let databaseBytes: UInt64
    public let stateSchemaVersion: Int

    public init(databaseSHA256: String, databaseBytes: UInt64, stateSchemaVersion: Int) {
        self.databaseSHA256 = databaseSHA256
        self.databaseBytes = databaseBytes
        self.stateSchemaVersion = stateSchemaVersion
    }
}

enum StateUpgradeTestInterruption: Error, Equatable, Sendable {
    case afterRestorePublishedAndVerified
}

public struct StateUpgradeService: Sendable {
    public let store: SQLiteStateStore
    private let testInterruption: StateUpgradeTestInterruption?

    public init(store: SQLiteStateStore) {
        self.store = store
        self.testInterruption = nil
    }

    init(store: SQLiteStateStore, testInterruption: StateUpgradeTestInterruption) {
        self.store = store
        self.testInterruption = testInterruption
    }

    public func withExclusiveLifecycleFence<T>(
        allowPendingMaintenance: Bool = false,
        lockWaitMilliseconds: Int = 250,
        _ body: () throws -> T
    ) throws -> T {
        guard (1...30_000).contains(lockWaitMilliseconds) else {
            throw StateStoreError.invalidRecord(
                "exclusive lifecycle fence wait must be between 1 and 30000 milliseconds"
            )
        }
        try store.configuration.prepareStateAccessFoundation()
        return try StateAccessCoordinator(configuration: store.configuration)
            .withExclusiveLifecycleFence(
                allowPendingMaintenance: allowPendingMaintenance,
                waitTimeoutNanoseconds: UInt64(lockWaitMilliseconds) * 1_000_000,
                body
            )
    }

    public func withBoundedStateAccessWait<T>(
        lockWaitMilliseconds: Int,
        _ body: () throws -> T
    ) throws -> T {
        guard (1...30_000).contains(lockWaitMilliseconds) else {
            throw StateStoreError.invalidRecord(
                "state-access wait must be between 1 and 30000 milliseconds"
            )
        }
        return try StateAccessCoordinator(configuration: store.configuration)
            .withBoundedStateAccessWait(
                waitTimeoutNanoseconds: UInt64(lockWaitMilliseconds) * 1_000_000,
                body
            )
    }

    public func withSerializedLifecycleMutation<T>(
        lockWaitMilliseconds: Int = 250,
        _ body: () throws -> T
    ) throws -> T {
        guard (1...30_000).contains(lockWaitMilliseconds) else {
            throw StateStoreError.invalidRecord(
                "serialized lifecycle mutation wait must be between 1 and 30000 milliseconds"
            )
        }
        try store.configuration.prepareStateAccessFoundation()
        return try StateAccessCoordinator(configuration: store.configuration)
            .withSerializedLifecycleMutation(
                waitTimeoutNanoseconds: UInt64(lockWaitMilliseconds) * 1_000_000,
                body
            )
    }

    public func withBoundedStateAccessWait<T>(
        lockWaitMilliseconds: Int,
        _ body: () async throws -> T
    ) async throws -> T {
        guard (1...30_000).contains(lockWaitMilliseconds) else {
            throw StateStoreError.invalidRecord(
                "state-access wait must be between 1 and 30000 milliseconds"
            )
        }
        return try await StateAccessCoordinator(configuration: store.configuration)
            .withBoundedStateAccessWait(
                waitTimeoutNanoseconds: UInt64(lockWaitMilliseconds) * 1_000_000,
                body
            )
    }

    public func withExclusiveLifecycleFence<T>(
        allowPendingMaintenance: Bool = false,
        lockWaitMilliseconds: Int = 250,
        _ body: () async throws -> T
    ) async throws -> T {
        guard (1...30_000).contains(lockWaitMilliseconds) else {
            throw StateStoreError.invalidRecord(
                "exclusive lifecycle fence wait must be between 1 and 30000 milliseconds"
            )
        }
        try store.configuration.prepareStateAccessFoundation()
        return try await StateAccessCoordinator(configuration: store.configuration)
            .withExclusiveLifecycleFence(
                allowPendingMaintenance: allowPendingMaintenance,
                waitTimeoutNanoseconds: UInt64(lockWaitMilliseconds) * 1_000_000,
                body
            )
    }

    public func withSerializedLifecycleMutation<T>(
        lockWaitMilliseconds: Int = 250,
        _ body: () async throws -> T
    ) async throws -> T {
        guard (1...30_000).contains(lockWaitMilliseconds) else {
            throw StateStoreError.invalidRecord(
                "serialized lifecycle mutation wait must be between 1 and 30000 milliseconds"
            )
        }
        try store.configuration.prepareStateAccessFoundation()
        return try await StateAccessCoordinator(configuration: store.configuration)
            .withSerializedLifecycleMutation(
                waitTimeoutNanoseconds: UInt64(lockWaitMilliseconds) * 1_000_000,
                body
            )
    }

    public func createVerifiedSnapshot(at snapshotPath: String) throws -> StateUpgradeSnapshot {
        let normalized = try HostwrightLocalPathResolver.normalizedAbsolutePath(
            snapshotPath,
            role: "state upgrade snapshot"
        )
        guard normalized == snapshotPath else {
            throw StateMaintenanceError.io(
                path: snapshotPath,
                message: "state upgrade snapshot path must already be normalized"
            )
        }
        let parent = (snapshotPath as NSString).deletingLastPathComponent
        try SecureStatePathManager().validatePrivateMaintenanceDirectory(parent)
        guard !StateMaintenanceFileSupport.exists(snapshotPath) else {
            throw StateMaintenanceError.io(
                path: snapshotPath,
                message: "state upgrade snapshot destination already exists"
            )
        }

        var published = false
        defer {
            if !published, StateMaintenanceFileSupport.exists(snapshotPath) {
                try? StateMaintenanceFileSupport.unlinkSensitiveFile(snapshotPath)
            }
        }
        try SecureStatePathManager().createExclusiveSensitiveFile(snapshotPath)
        try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
            _ = try MigrationRunner().compatibleSchemaVersion(on: connection)
            try connection.onlineBackup(to: snapshotPath)
        }
        let snapshot = try inspectSnapshot(snapshotPath)
        try StateMaintenanceFileSupport.synchronizeDirectory(parent)
        published = true
        return snapshot
    }

    public func verifiedRevision() throws -> StateUpgradeRevision? {
        try store.configuration.prepareStateAccessFoundation()
        return try StateAccessCoordinator(configuration: store.configuration).withLock(.exclusive) {
            guard StateMaintenanceFileSupport.exists(store.path) else {
                for suffix in ["-journal", "-wal", "-shm"]
                    where StateMaintenanceFileSupport.exists(store.path + suffix) {
                    throw StateMaintenanceError.recoveryFailed(
                        "absent state database has an unmanaged SQLite sidecar \(suffix)"
                    )
                }
                return nil
            }
            let version: Int
            do {
                version = try checkpointCurrentState(removeSQLiteSidecars: false)
            } catch {
                throw StateMaintenanceError.recoveryFailed(
                    "state revision checkpoint failed: \(String(describing: error))"
                )
            }
            let fingerprint = try StateMaintenanceFileSupport.fingerprint(store.path)
            return StateUpgradeRevision(
                databaseSHA256: fingerprint.sha256,
                databaseBytes: fingerprint.bytes,
                stateSchemaVersion: version
            )
        }
    }

    public func migrateToLatest() throws -> StateUpgradeMigrationResult {
        let before = try MigrationRunner().compatibleSchemaVersion(in: store)
        try store.migrate()
        try store.validateSchema()
        let report = StateIntegrityService(store: store).inspect()
        guard report.health == .healthy,
              report.stateSchemaVersion == MigrationRunner.latestSchemaVersion else {
            throw StateMaintenanceError.recoveryFailed(
                "state migration completed without a healthy latest-schema result"
            )
        }
        return StateUpgradeMigrationResult(
            fromSchemaVersion: before,
            toSchemaVersion: MigrationRunner.latestSchemaVersion
        )
    }

    public func migrateToLatestWithVerifiedBackup() throws -> StateUpgradePreparedMigrationResult {
        try withExclusiveLifecycleFence {
            guard let revision = try verifiedRevision() else {
                try store.migrate()
                try store.validateSchema()
                return StateUpgradePreparedMigrationResult(
                    migration: StateUpgradeMigrationResult(
                        fromSchemaVersion: MigrationRunner.latestSchemaVersion,
                        toSchemaVersion: MigrationRunner.latestSchemaVersion
                    ),
                    rollbackSnapshot: nil
                )
            }
            if revision.stateSchemaVersion == MigrationRunner.latestSchemaVersion {
                try store.validateSchema()
                return StateUpgradePreparedMigrationResult(
                    migration: StateUpgradeMigrationResult(
                        fromSchemaVersion: revision.stateSchemaVersion,
                        toSchemaVersion: revision.stateSchemaVersion
                    ),
                    rollbackSnapshot: nil
                )
            }

            let databaseParent = (store.path as NSString).deletingLastPathComponent
            let rollbackRoot = URL(fileURLWithPath: databaseParent, isDirectory: true)
                .appendingPathComponent(".hostwright-state-upgrades", isDirectory: true)
            let operationID = UUID().uuidString.lowercased()
            let rollbackDirectory = rollbackRoot.appendingPathComponent(
                operationID,
                isDirectory: true
            )
            let pathManager = SecureStatePathManager()
            try pathManager.ensurePrivateMaintenanceDirectory(rollbackRoot.path)
            try pathManager.ensurePrivateMaintenanceDirectory(rollbackDirectory.path)
            let snapshot = try createVerifiedSnapshot(
                at: rollbackDirectory.appendingPathComponent("state.sqlite").path
            )
            try pathManager.writePrivateJSON(
                snapshot,
                to: rollbackDirectory.appendingPathComponent("snapshot-v1.json").path
            )
            try verify(snapshot)
            let migration = try migrateToLatest()
            try verify(snapshot)
            return StateUpgradePreparedMigrationResult(
                migration: migration,
                rollbackSnapshot: snapshot
            )
        }
    }

    @discardableResult
    public func restoreVerifiedSnapshot(
        _ snapshot: StateUpgradeSnapshot,
        operationID: String
    ) throws -> Int {
        guard let identifier = UUID(uuidString: operationID),
              identifier.uuidString.lowercased() == operationID else {
            throw StateMaintenanceError.recoveryFailed(
                "state restore operation identifier must be a canonical UUID"
            )
        }
        try verify(snapshot)
        try store.configuration.prepareStateAccessFoundation()
        return try StateAccessCoordinator(configuration: store.configuration).withLock(.exclusive) {
            try verify(snapshot)
            let currentExists = StateMaintenanceFileSupport.exists(store.path)
            if currentExists {
                _ = try checkpointCurrentState()
            } else {
                for suffix in ["-journal", "-wal", "-shm"]
                    where StateMaintenanceFileSupport.exists(store.path + suffix) {
                    throw StateMaintenanceError.recoveryFailed(
                        "absent state database has an unmanaged SQLite sidecar \(suffix)"
                    )
                }
            }
            let parent = (store.path as NSString).deletingLastPathComponent
            let stagingPath = URL(fileURLWithPath: parent, isDirectory: true)
                .appendingPathComponent(
                    ".hostwright-state-upgrade-restore-\(operationID).sqlite"
                )
                .path
            for suffix in ["-journal", "-wal", "-shm"]
                where StateMaintenanceFileSupport.exists(stagingPath + suffix) {
                throw StateMaintenanceError.recoveryFailed(
                    "state restore staging path has an unmanaged SQLite sidecar \(suffix)"
                )
            }
            if StateMaintenanceFileSupport.exists(stagingPath) {
                try StateMaintenanceFileSupport.unlinkSensitiveFile(stagingPath)
                try StateMaintenanceFileSupport.synchronizeDirectory(parent)
            }
            if currentExists,
               (try? inspectSnapshotFile(store.path, expected: snapshot)) != nil {
                return snapshot.stateSchemaVersion
            }
            try SecureStatePathManager().createExclusiveSensitiveFile(stagingPath)
            var stagingExists = true
            defer {
                if stagingExists, StateMaintenanceFileSupport.exists(stagingPath) {
                    try? StateMaintenanceFileSupport.unlinkSensitiveFile(stagingPath)
                }
            }
            try StateMaintenanceFileSupport.copyExactSensitiveFile(
                from: snapshot.snapshotPath,
                to: stagingPath,
                expectedSHA256: snapshot.databaseSHA256,
                expectedBytes: snapshot.databaseBytes,
                sourceChanged: { StateMaintenanceError.recoveryFailed($0) }
            )
            _ = try inspectSnapshotFile(stagingPath, expected: snapshot)

            var replacementPublished = false
            do {
                if currentExists {
                    guard renamex_np(store.path, stagingPath, UInt32(RENAME_SWAP)) == 0 else {
                        throw StateMaintenanceError.io(
                            path: store.path,
                            message: "atomic state upgrade restore swap failed: \(String(cString: strerror(errno)))"
                        )
                    }
                    replacementPublished = true
                } else {
                    guard renamex_np(stagingPath, store.path, UInt32(RENAME_EXCL)) == 0 else {
                        throw StateMaintenanceError.io(
                            path: store.path,
                            message: "atomic absent-state restore publish failed: \(String(cString: strerror(errno)))"
                        )
                    }
                    replacementPublished = true
                    stagingExists = false
                }
                try StateMaintenanceFileSupport.synchronizeDirectory(parent)
                let restored = try inspectSnapshotFile(store.path, expected: snapshot)
                if testInterruption == .afterRestorePublishedAndVerified {
                    stagingExists = false
                    throw StateUpgradeTestInterruption.afterRestorePublishedAndVerified
                }
                if currentExists {
                    try StateMaintenanceFileSupport.unlinkSensitiveFile(stagingPath)
                    stagingExists = false
                }
                return restored.stateSchemaVersion
            } catch let interruption as StateUpgradeTestInterruption {
                throw interruption
            } catch {
                let validationError = error
                if currentExists, replacementPublished {
                    if StateMaintenanceFileSupport.exists(stagingPath) {
                        guard renamex_np(store.path, stagingPath, UInt32(RENAME_SWAP)) == 0 else {
                            stagingExists = false
                            throw StateMaintenanceError.recoveryFailed(
                                "restored state failed verification and the exact prior database could not be swapped back"
                            )
                        }
                        try StateMaintenanceFileSupport.synchronizeDirectory(parent)
                    }
                } else if !currentExists, replacementPublished {
                    if StateMaintenanceFileSupport.exists(store.path) {
                        try StateMaintenanceFileSupport.unlinkSensitiveFile(store.path)
                        try StateMaintenanceFileSupport.synchronizeDirectory(parent)
                    }
                }
                throw validationError
            }
        }
    }

    /// Restores application state while retaining the current, externally anchored audit history.
    @discardableResult
    public func restoreVerifiedSnapshotPreservingAudit(
        _ snapshot: StateUpgradeSnapshot,
        operationID: String,
        keyStore: any AuditSigningKeyStoring,
        approvedInstalledCodeIdentities: [CodeIdentity] = [],
        expectedCurrentInstalledCodeIdentities: [CodeIdentity] = [],
        allowAbsentCurrentStateForUninstallRecovery: Bool = false
    ) throws -> Int {
        try verify(snapshot)
        guard snapshot.stateSchemaVersion != 18 else {
            throw StateMaintenanceError.recoveryFailed(
                "pre-audit identity snapshots cannot safely invalidate bearer sessions during rollback"
            )
        }
        return try withExclusiveLifecycleFence {
            guard StateMaintenanceFileSupport.exists(store.path) else {
                guard allowAbsentCurrentStateForUninstallRecovery else {
                    throw StateMaintenanceError.recoveryFailed("audit-continuous restore requires present state and the same current schema")
                }
                let parent = (snapshot.snapshotPath as NSString).deletingLastPathComponent
                try SecureStatePathManager().validatePrivateMaintenanceDirectory(parent)
                guard let identifier = UUID(uuidString: operationID), identifier.uuidString.lowercased() == operationID else {
                    throw StateMaintenanceError.recoveryFailed("invalid uninstall recovery identifier")
                }
                let head = try keyStore.loadHead()
                let key = try keyStore.configuredActiveKey()
                if snapshot.stateSchemaVersion < 19 {
                    guard head == nil, key == nil else { throw AuditTrailError.anchorMismatch }
                    return try restoreVerifiedSnapshot(snapshot, operationID: operationID)
                }
                let proofPath = URL(fileURLWithPath: parent).appendingPathComponent("uninstall-audit-proof-\(UUID().uuidString.lowercased()).sqlite").path
                try SecureStatePathManager().createExclusiveSensitiveFile(proofPath)
                defer {
                    for suffix in ["", "-wal", "-shm"] where StateMaintenanceFileSupport.exists(proofPath + suffix) {
                        try? StateMaintenanceFileSupport.unlinkSensitiveFile(proofPath + suffix)
                    }
                    if let paths = try? SQLiteStateStore(path: proofPath).configuration.maintenancePaths() {
                        for path in [paths.accessLockPath, paths.accessLockPath + ".writer", paths.accessLockPath + ".lifecycle-mutation"] where StateMaintenanceFileSupport.exists(path) {
                            try? StateMaintenanceFileSupport.unlinkSensitiveFile(path)
                        }
                    }
                }
                try StateMaintenanceFileSupport.copyExactSensitiveFile(from: snapshot.snapshotPath, to: proofPath,
                    expectedSHA256: snapshot.databaseSHA256, expectedBytes: snapshot.databaseBytes,
                    sourceChanged: { StateMaintenanceError.recoveryFailed($0) })
                let proofStore = SQLiteStateStore(path: proofPath)
                guard TamperEvidentAuditTrail(store: proofStore, keyStore: keyStore).verify().health == .healthy,
                      try keyStore.loadHead() == head, try keyStore.configuredActiveKey() == key else {
                    throw AuditTrailError.anchorMismatch
                }
                let proofSnapshot = StateUpgradeSnapshot(databasePath: proofPath,
                    snapshotPath: snapshot.snapshotPath, databaseSHA256: snapshot.databaseSHA256,
                    databaseBytes: snapshot.databaseBytes, stateSchemaVersion: snapshot.stateSchemaVersion)
                let proofService = StateUpgradeService(store: proofStore)
                _ = try proofService.restoreVerifiedSnapshotPreservingAudit(proofSnapshot, operationID: operationID,
                    keyStore: keyStore, approvedInstalledCodeIdentities: approvedInstalledCodeIdentities,
                    expectedCurrentInstalledCodeIdentities: expectedCurrentInstalledCodeIdentities)
                let readyPath = URL(fileURLWithPath: parent).appendingPathComponent("uninstall-ready-\(UUID().uuidString.lowercased()).sqlite").path
                defer { if StateMaintenanceFileSupport.exists(readyPath) { try? StateMaintenanceFileSupport.unlinkSensitiveFile(readyPath) } }
                _ = try proofService.checkpointCurrentState()
                let ready: StateUpgradeSnapshot
                do {
                    let fingerprint = try StateMaintenanceFileSupport.fingerprint(proofPath)
                    try SecureStatePathManager().createExclusiveSensitiveFile(readyPath)
                    let source = try SQLiteConnection(path: proofPath, createIfNeeded: false,
                        readOnly: true, profile: .nonMutatingInspection)
                    do { try source.onlineBackup(to: readyPath); try source.close() }
                    catch { try? source.close(); throw error }
                    guard try StateMaintenanceFileSupport.fingerprint(proofPath) == fingerprint else {
                        throw StateMaintenanceError.recoveryFailed("sanitized uninstall proof changed during backup")
                    }
                    ready = try proofService.inspectSnapshot(readyPath)
                    try StateMaintenanceFileSupport.synchronizeDirectory(parent)
                } catch {
                    throw StateMaintenanceError.recoveryFailed("uninstall private sanitized snapshot failed: \(String(describing: error))")
                }
                guard StateMaintenanceFileSupport.exists(readyPath) else {
                    throw StateMaintenanceError.recoveryFailed("uninstall private sanitized snapshot disappeared after creation")
                }
                let readyStore = SQLiteStateStore(path: readyPath)
                let readyMaintenance = try readyStore.configuration.maintenancePaths()
                defer {
                    for path in [readyMaintenance.accessLockPath, readyMaintenance.accessLockPath + ".writer"]
                        where StateMaintenanceFileSupport.exists(path) {
                        try? StateMaintenanceFileSupport.unlinkSensitiveFile(path)
                    }
                }
                guard TamperEvidentAuditTrail(store: readyStore, keyStore: keyStore).verify().health == .healthy,
                      try keyStore.loadHead() == head, try keyStore.configuredActiveKey() == key else {
                    throw AuditTrailError.anchorMismatch
                }
                let publication = StateUpgradeSnapshot(databasePath: store.path, snapshotPath: ready.snapshotPath,
                    databaseSHA256: ready.databaseSHA256, databaseBytes: ready.databaseBytes,
                    stateSchemaVersion: ready.stateSchemaVersion)
                do { return try restoreVerifiedSnapshot(publication, operationID: operationID) }
                catch let interruption as StateUpgradeTestInterruption { throw interruption }
                catch { throw StateMaintenanceError.recoveryFailed("uninstall sanitized publication failed: \(String(describing: error))") }
            }
            let currentVersion = try store.schemaVersion()
            if snapshot.stateSchemaVersion < 19 && currentVersion < 19 {
                if currentVersion >= 18 {
                    let identityCount = try store.withConnection(readOnly: true) {
                        try $0.query("SELECT COUNT(*) FROM peer_identities").first?.first ?? nil
                    }
                    guard identityCount == "0" else {
                        throw StateMaintenanceError.recoveryFailed("pre-audit restoration cannot discard current identity authority")
                    }
                }
                guard try keyStore.loadHead() == nil,
                      try keyStore.configuredActiveKey() == nil else { throw AuditTrailError.anchorMismatch }
                return try restoreVerifiedSnapshot(snapshot, operationID: operationID)
            }
            let trail = TamperEvidentAuditTrail(store: store, keyStore: keyStore)
            let report = trail.verify()
            guard report.health == .healthy else {
                throw StateMaintenanceError.recoveryFailed(
                    "current audit verification failed: \(report.findings.joined(separator: "; "))"
                )
            }
            let head = try keyStore.loadHead()
            if snapshot.stateSchemaVersion < 19 {
                guard report.recordCount == 0, report.segmentCount == 0,
                      report.activeKeyID == nil, head == nil,
                      try store.controlIdentities.listIdentities().isEmpty,
                      try keyStore.configuredActiveKey() == nil else { throw AuditTrailError.anchorMismatch }
                return try restoreVerifiedSnapshot(snapshot, operationID: operationID)
            }
            guard snapshot.stateSchemaVersion == MigrationRunner.latestSchemaVersion,
                  currentVersion == snapshot.stateSchemaVersion else {
                throw StateMaintenanceError.recoveryFailed("audit-continuous rollback requires compatible current-schema state")
            }
            let parent = (snapshot.snapshotPath as NSString).deletingLastPathComponent
            let mergedPath = URL(fileURLWithPath: parent, isDirectory: true)
                .appendingPathComponent("audit-continuous-\(operationID).sqlite").path
            guard let identifier = UUID(uuidString: operationID),
                  identifier.uuidString.lowercased() == operationID else {
                throw StateMaintenanceError.recoveryFailed("invalid audit-continuous restore identifier")
            }
            try SecureStatePathManager().validatePrivateMaintenanceDirectory(parent)
            if StateMaintenanceFileSupport.exists(mergedPath) {
                try StateMaintenanceFileSupport.unlinkSensitiveFile(mergedPath)
            }
            try SecureStatePathManager().createExclusiveSensitiveFile(mergedPath)
            defer {
                for suffix in ["", "-wal", "-shm"] where StateMaintenanceFileSupport.exists(mergedPath + suffix) {
                    try? StateMaintenanceFileSupport.unlinkSensitiveFile(mergedPath + suffix)
                }
            }
            try StateMaintenanceFileSupport.copyExactSensitiveFile(
                from: snapshot.snapshotPath, to: mergedPath,
                expectedSHA256: snapshot.databaseSHA256, expectedBytes: snapshot.databaseBytes,
                sourceChanged: { StateMaintenanceError.recoveryFailed($0) }
            )
            let currentIdentities = try store.controlIdentities.listIdentities()
            let tables = [
                "audit_key_metadata", "audit_segments", "audit_records", "audit_retention_anchors",
                "peer_identities", "control_sessions", "identity_revocations", "control_requests", "idempotency_records",
                "rbac_roles", "rbac_bindings", "rbac_delegations", "admission_policies", "admission_exceptions", "workload_profiles",
                "plugin_packages", "plugin_provenance", "plugin_grants", "plugin_activations", "plugin_revocations",
                "plugin_quarantine", "plugin_rollback_state"
            ]
            let rows = try store.withValidatedConnection(readOnly: true) { connection in
                try tables.map { try connection.query("SELECT * FROM \($0)") }
            }
            let connection = try SQLiteConnection(
                path: mergedPath, createIfNeeded: false, readOnly: false, profile: .portableArtifact
            )
            var priorCredentials: [String] = []
            do {
                try connection.execute("PRAGMA foreign_keys = OFF")
                let priorIdentities = try connection.query("SELECT subject_id,user_id,signing_identifier,team_identifier,code_directory_hash,validation_mode,revoked_at,credential_id FROM peer_identities")
                priorCredentials = priorIdentities.compactMap { $0[7] }
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let triggers = try connection.query("SELECT name,sql,tbl_name FROM sqlite_schema WHERE type='trigger'").filter { row in
                    row[2].map { tables.contains($0) } ?? false
                }
                try connection.transaction {
                    for trigger in triggers {
                        guard let name = trigger[0], name.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else {
                            throw StateMaintenanceError.recoveryFailed("restore artifact trigger name is invalid")
                        }
                        try connection.execute("DROP TRIGGER \(name)")
                    }
                    for table in tables.reversed() { try connection.run("DELETE FROM \(table)") }
                    for (table, records) in zip(tables, rows) {
                        for record in records {
                            let parameters = Array(repeating: "?", count: record.count).joined(separator: ",")
                            try connection.run("INSERT INTO \(table) VALUES (\(parameters))",
                                bindings: record.map { $0.map(SQLiteValue.text) ?? .null })
                        }
                    }
                    for prior in priorIdentities {
                        guard let subject = prior[0], let user = prior[1].flatMap({ UInt32($0) }),
                              let identifier = prior[2], let team = prior[3], let hash = prior[4],
                              prior[5] == "installedRequirement", prior[6] == nil,
                              let current = currentIdentities.first(where: { $0.subjectID == subject }),
                              current.revokedAt == nil,
                              current.userID == user,
                              current.codeIdentity.validationMode == .installedRequirement,
                              current.codeIdentity.signingIdentifier == identifier,
                              current.codeIdentity.teamIdentifier == team,
                              current.codeIdentity.codeDirectoryHash != hash else { continue }
                        let approval = CodeIdentity(teamIdentifier: team, signingIdentifier: identifier,
                            codeDirectoryHash: hash, validationMode: .installedRequirement)
                        guard approvedInstalledCodeIdentities.contains(approval),
                              expectedCurrentInstalledCodeIdentities.contains(current.codeIdentity),
                              currentIdentities.filter({ $0.revokedAt == nil && $0.userID == user &&
                                  $0.codeIdentity.teamIdentifier == team && $0.codeIdentity.signingIdentifier == identifier }).count == 1 else {
                            throw StateMaintenanceError.recoveryFailed("native identity rollback lacks exact verified payload approval")
                        }
                        let retirements = try connection.query(
                            "SELECT revocation_id,reason,actor_subject_id FROM identity_revocations WHERE target_kind='codeHash' AND target_identifier=?",
                            bindings: [.text(hash)])
                        guard retirements.allSatisfy({ retirement in retirement[0] == "installed-rotation-" + hash &&
                            retirement[1] == "installed code identity rotated" &&
                            priorIdentities.contains(where: { priorActor in
                                priorActor[0] == retirement[2] && priorActor[4] == hash && priorActor[5] == "installedRequirement"
                            }) }) else {
                            throw StateMaintenanceError.recoveryFailed("native rollback hash has an independent security revocation")
                        }
                        try connection.run("DELETE FROM identity_revocations WHERE revocation_id=? AND target_kind='codeHash' AND target_identifier=? AND reason='installed code identity rotated'",
                            bindings: [.text("installed-rotation-" + hash), .text(hash)])
                        try connection.run("UPDATE peer_identities SET code_directory_hash=?,generation=generation+1,updated_at=? WHERE subject_id=? AND revoked_at IS NULL",
                            bindings: [.text(hash), .text(timestamp), .text(subject)])
                    }
                    try connection.run("UPDATE control_requests SET status='error',response_json=NULL,operation_reference=NULL,updated_at=? WHERE status='accepted'", bindings: [.text(timestamp)])
                    try connection.run("UPDATE idempotency_records SET status='error' WHERE status='accepted'")
                    for trigger in triggers {
                        guard let sql = trigger[1] else { throw StateMaintenanceError.recoveryFailed("restore trigger definition is absent") }
                        try connection.execute(sql)
                    }
                }
                try connection.close()
            } catch { try? connection.close(); throw error }
            let mergedStore = SQLiteStateStore(path: mergedPath)
            let mergedMaintenance = try mergedStore.configuration.maintenancePaths()
            defer {
                for path in [mergedMaintenance.accessLockPath, mergedMaintenance.accessLockPath + ".writer"] {
                    if StateMaintenanceFileSupport.exists(path) { try? StateMaintenanceFileSupport.unlinkSensitiveFile(path) }
                }
            }
            guard TamperEvidentAuditTrail(store: mergedStore, keyStore: keyStore).verify().health == .healthy,
                  try keyStore.loadHead() == head else { throw AuditTrailError.anchorMismatch }
            let credentials = Set(priorCredentials + currentIdentities.compactMap(\.credentialID))
            let activeSessions = try mergedStore.controlIdentities.listSessions().filter { $0.revokedAt == nil }
            if !activeSessions.isEmpty || !credentials.isEmpty {
                guard let actor = try mergedStore.controlIdentities.listIdentities().first(where: { $0.revokedAt == nil }) else {
                    throw StateMaintenanceError.recoveryFailed("restored sessions have no active revocation actor")
                }
                let timestamp = ISO8601DateFormatter().string(from: Date())
                for session in activeSessions {
                    do { try mergedStore.controlIdentities.revoke(ControlIdentityRevocationRecord(
                        revocationID: "state-rollback:" + UUID().uuidString.lowercased(),
                        targetKind: .session, targetIdentifier: session.sessionID,
                        reason: "state rollback requires a newly established session",
                        actorSubjectID: actor.subjectID, revokedAt: timestamp
                    )) } catch {
                        throw StateMaintenanceError.recoveryFailed("staged session revocation failed: \(String(describing: error))")
                    }
                }
                let existingRevocations = try mergedStore.withValidatedConnection(readOnly: true) {
                    try $0.query("SELECT target_identifier FROM identity_revocations WHERE target_kind='credential'").compactMap { $0[0] }
                }
                let assignedCredentials = Set(currentIdentities.filter { $0.revokedAt == nil }.compactMap(\.credentialID))
                let credentialOrder = credentials.sorted {
                    if assignedCredentials.contains($0) != assignedCredentials.contains($1) { return !assignedCredentials.contains($0) }
                    return $0 < $1
                }
                for credential in credentialOrder where !existingRevocations.contains(credential) {
                    let active = try mergedStore.controlIdentities.listIdentities().filter { $0.revokedAt == nil }
                    guard let credentialActor = active.first(where: { $0.credentialID == nil }) ?? active.first else {
                        throw StateMaintenanceError.recoveryFailed("credential invalidation requires an active revocation actor")
                    }
                    try mergedStore.controlIdentities.revoke(ControlIdentityRevocationRecord(
                        revocationID: "state-rollback:" + UUID().uuidString.lowercased(), targetKind: .credential,
                        targetIdentifier: credential, reason: "state rollback requires a newly provisioned credential subject",
                        actorSubjectID: credentialActor.subjectID, revokedAt: timestamp))
                }
                do { _ = try StateUpgradeService(store: mergedStore).checkpointCurrentState() }
                catch { throw StateMaintenanceError.recoveryFailed("staged session checkpoint failed: \(String(describing: error))") }
            }
            // Online backup creates a new standalone artifact; converting the live WAL file
            // to DELETE can leave a fresh shared-memory sidecar on macOS SQLite.
            let portablePath = URL(fileURLWithPath: parent, isDirectory: true)
                .appendingPathComponent("audit-continuous-portable-\(operationID).sqlite").path
            for suffix in ["-journal", "-wal", "-shm"] where StateMaintenanceFileSupport.exists(portablePath + suffix) {
                throw StateMaintenanceError.recoveryFailed("portable restore artifact has an unmanaged sidecar \(suffix)")
            }
            if StateMaintenanceFileSupport.exists(portablePath) {
                try StateMaintenanceFileSupport.unlinkSensitiveFile(portablePath)
            }
            defer { try? StateMaintenanceFileSupport.unlinkSensitiveFile(portablePath) }
            let portable: StateUpgradeSnapshot
            do {
                _ = try StateUpgradeService(store: mergedStore).checkpointCurrentState()
                let fingerprint = try StateMaintenanceFileSupport.fingerprint(mergedPath)
                _ = try compatibleVersionAndIntegrity(mergedPath)
                try SecureStatePathManager().createExclusiveSensitiveFile(portablePath)
                let source = try SQLiteConnection(path: mergedPath, createIfNeeded: false,
                    readOnly: true, profile: .nonMutatingInspection)
                do { try source.onlineBackup(to: portablePath); try source.close() }
                catch { try? source.close(); throw error }
                guard try StateMaintenanceFileSupport.fingerprint(mergedPath) == fingerprint else {
                    throw StateMaintenanceError.recoveryFailed("checkpointed restore artifact changed during backup")
                }
                portable = try inspectSnapshot(portablePath)
                try StateMaintenanceFileSupport.synchronizeDirectory(parent)
            }
            catch { throw StateMaintenanceError.recoveryFailed("audit-continuous portable backup failed: \(String(describing: error))") }
            let merged = StateUpgradeSnapshot(databasePath: store.path, snapshotPath: portable.snapshotPath,
                databaseSHA256: portable.databaseSHA256, databaseBytes: portable.databaseBytes,
                stateSchemaVersion: portable.stateSchemaVersion)
            try verify(merged)
            let version: Int
            do { version = try restoreVerifiedSnapshot(merged, operationID: operationID) }
            catch { throw StateMaintenanceError.recoveryFailed("audit-continuous publication failed: \(String(describing: error))") }
            guard TamperEvidentAuditTrail(store: store, keyStore: keyStore).verify().health == .healthy,
                  try keyStore.loadHead() == head else { throw AuditTrailError.anchorMismatch }
            return version
        }
    }

    public func verify(_ snapshot: StateUpgradeSnapshot) throws {
        try snapshot.validate()
        guard snapshot.databasePath == store.path else {
            throw StateMaintenanceError.recoveryFailed(
                "state upgrade snapshot belongs to a different database path"
            )
        }
        _ = try inspectSnapshotFile(snapshot.snapshotPath, expected: snapshot)
    }

    private func inspectSnapshot(_ snapshotPath: String) throws -> StateUpgradeSnapshot {
        let fingerprint = try StateMaintenanceFileSupport.fingerprint(snapshotPath)
        let version = try compatibleVersionAndIntegrity(snapshotPath)
        return StateUpgradeSnapshot(
            databasePath: store.path,
            snapshotPath: snapshotPath,
            databaseSHA256: fingerprint.sha256,
            databaseBytes: fingerprint.bytes,
            stateSchemaVersion: version
        )
    }

    private func inspectSnapshotFile(
        _ path: String,
        expected: StateUpgradeSnapshot
    ) throws -> StateUpgradeSnapshot {
        for suffix in ["-journal", "-wal", "-shm"] where StateMaintenanceFileSupport.exists(path + suffix) {
            throw StateMaintenanceError.recoveryFailed(
                "state upgrade snapshot at \(path) has forbidden SQLite sidecar \(suffix)"
            )
        }
        let fingerprint = try StateMaintenanceFileSupport.fingerprint(path)
        guard fingerprint.sha256 == expected.databaseSHA256,
              fingerprint.bytes == expected.databaseBytes else {
            throw StateMaintenanceError.recoveryFailed(
                "state upgrade snapshot digest or size no longer matches its record"
            )
        }
        let version = try compatibleVersionAndIntegrity(path)
        guard version == expected.stateSchemaVersion else {
            throw StateMaintenanceError.recoveryFailed(
                "state upgrade snapshot schema no longer matches its record"
            )
        }
        return StateUpgradeSnapshot(
            databasePath: expected.databasePath,
            snapshotPath: path,
            databaseSHA256: fingerprint.sha256,
            databaseBytes: fingerprint.bytes,
            stateSchemaVersion: version
        )
    }

    private func compatibleVersionAndIntegrity(_ path: String) throws -> Int {
        let connection = try SQLiteConnection(
            path: path,
            createIfNeeded: false,
            readOnly: true,
            profile: .nonMutatingInspection
        )
        defer { try? connection.close() }
        let integrity = try connection.query("PRAGMA integrity_check(100)")
            .compactMap { $0.first ?? nil }
        guard integrity == ["ok"], try connection.query("PRAGMA foreign_key_check").isEmpty else {
            throw StateMaintenanceError.recoveryFailed(
                "state upgrade snapshot failed SQLite integrity or foreign-key verification"
            )
        }
        let version = try MigrationRunner().compatibleSchemaVersion(on: connection)
        try connection.close()
        return version
    }

    private func checkpointCurrentState(removeSQLiteSidecars: Bool = true) throws -> Int {
        _ = try store.configuration.prepare(createIfNeeded: false)
        let connection = try SQLiteConnection(
            path: store.path,
            createIfNeeded: false,
            readOnly: false,
            profile: .authoritativeState
        )
        let version: Int
        do {
            _ = try connection.query("PRAGMA wal_checkpoint(TRUNCATE)")
            let integrity = try connection.query("PRAGMA integrity_check(100)")
                .compactMap { $0.first ?? nil }
            guard integrity == ["ok"],
                  try connection.query("PRAGMA foreign_key_check").isEmpty else {
                throw StateMaintenanceError.recoveryFailed(
                    "state database failed SQLite integrity or foreign-key verification"
                )
            }
            version = try MigrationRunner().compatibleSchemaVersion(on: connection)
            try connection.close()
        } catch {
            try? connection.close()
            throw error
        }
        if removeSQLiteSidecars {
            for suffix in ["-wal", "-shm"] {
                let path = store.path + suffix
                if StateMaintenanceFileSupport.exists(path) {
                    try StateMaintenanceFileSupport.unlinkSensitiveFile(path)
                }
            }
        }
        guard !StateMaintenanceFileSupport.exists(store.path + "-journal") else {
            throw StateMaintenanceError.recoveryFailed(
                "state upgrade restore refused an active rollback journal"
            )
        }
        return version
    }
}
