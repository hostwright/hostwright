public enum StateStoreError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidPath(String)
    case pathPolicyViolation(path: String, message: String)
    case legacyPathMigrationFailed(source: String, destination: String, message: String)
    case openFailed(path: String, message: String)
    case closeFailed(path: String, message: String)
    case databaseLocked(path: String, message: String)
    case corruptDatabase(path: String, message: String)
    case maintenanceRecoveryRequired(journalPath: String)
    case executeFailed(message: String)
    case prepareFailed(sql: String, message: String)
    case bindFailed(index: Int32, message: String)
    case stepFailed(message: String)
    case incompatibleSchema(foundVersion: Int?, latestSupported: Int, message: String)
    case migrationFailed(version: Int, message: String)
    case transactionFailed(message: String)
    case invalidRecord(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .invalidPath(let path):
            return "Invalid state database path: \(path)"
        case .pathPolicyViolation(let path, let message):
            return "State path policy rejected \(path): \(message)"
        case .legacyPathMigrationFailed(let source, let destination, let message):
            return "Could not migrate legacy state from \(source) to \(destination): \(message)"
        case .openFailed(let path, let message):
            return "Failed to open state database at \(path): \(message)"
        case .closeFailed(let path, let message):
            return "Failed to close state database at \(path): \(message)"
        case .databaseLocked(let path, let message):
            return "State database at \(path) is locked by another process: \(message)"
        case .corruptDatabase(let path, let message):
            return "State database at \(path) appears corrupt or is not a SQLite database: \(message)"
        case .maintenanceRecoveryRequired(let journalPath):
            return "State maintenance recovery is required before opening the database. Run 'hostwright state recover'; pending journal: \(journalPath)"
        case .executeFailed(let message):
            return "SQLite execution failed: \(message)"
        case .prepareFailed(let sql, let message):
            return "Failed to prepare SQLite statement '\(sql)': \(message)"
        case .bindFailed(let index, let message):
            return "Failed to bind SQLite value at index \(index): \(message)"
        case .stepFailed(let message):
            return "SQLite step failed: \(message)"
        case .incompatibleSchema(let foundVersion, let latestSupported, let message):
            let found = foundVersion.map(String.init) ?? "unknown"
            return "State database schema version \(found) is incompatible with supported version \(latestSupported): \(message)"
        case .migrationFailed(let version, let message):
            return "Migration \(version) failed: \(message)"
        case .transactionFailed(let message):
            return "SQLite transaction failed: \(message)"
        case .invalidRecord(let message):
            return "Invalid state record: \(message)"
        case .notFound(let message):
            return "State record not found: \(message)"
        }
    }
}
