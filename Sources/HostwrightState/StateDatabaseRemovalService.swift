import Foundation

public struct StateDatabaseRemovalResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let databasePath: String
    public let removedPaths: [String]

    public init(databasePath: String, removedPaths: [String]) {
        self.schemaVersion = 1
        self.kind = "stateDatabaseRemovalResult"
        self.databasePath = databasePath
        self.removedPaths = removedPaths.sorted()
    }
}

public struct StateDatabaseRemovalService: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func removeVerifiedDatabase() throws -> StateDatabaseRemovalResult {
        let configuration = store.configuration
        try configuration.prepareStateAccessFoundation()
        return try StateAccessCoordinator(configuration: configuration).withLock(.exclusive) {
            let expectedIdentity = try configuration.prepare(createIfNeeded: false)
            let connection = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                readOnly: false,
                profile: .authoritativeState
            )
            var closed = false
            defer {
                if !closed { try? connection.close() }
            }
            let openedIdentity = try configuration.validateSQLiteFileSet()
            guard expectedIdentity == openedIdentity else {
                throw StateStoreError.pathPolicyViolation(
                    path: store.path,
                    message: "the state database identity changed while removal acquired its fence"
                )
            }
            _ = try MigrationRunner().compatibleSchemaVersion(on: connection)
            _ = try connection.query("PRAGMA wal_checkpoint(TRUNCATE)")
            try connection.close()
            closed = true
            guard try configuration.validateSQLiteFileSet() == openedIdentity else {
                throw StateStoreError.pathPolicyViolation(
                    path: store.path,
                    message: "the state database identity changed before verified removal"
                )
            }

            var removed: [String] = []
            for path in [
                store.path + "-wal",
                store.path + "-shm",
                store.path + "-journal",
                store.path
            ] where StateMaintenanceFileSupport.exists(path) {
                try StateMaintenanceFileSupport.unlinkSensitiveFile(path)
                removed.append(path)
            }
            try StateMaintenanceFileSupport.synchronizeDirectory(
                (store.path as NSString).deletingLastPathComponent
            )
            return StateDatabaseRemovalResult(
                databasePath: store.path,
                removedPaths: removed
            )
        }
    }
}
