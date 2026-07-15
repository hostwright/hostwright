import Darwin
import Foundation
import HostwrightCore

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

    public func withExclusiveLifecycleFence<T>(_ body: () throws -> T) throws -> T {
        try store.configuration.prepareStateAccessFoundation()
        return try StateAccessCoordinator(configuration: store.configuration)
            .withExclusiveLifecycleFence(body)
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
                "state upgrade snapshot has forbidden SQLite sidecar \(suffix)"
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
            profile: .portableArtifact
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
