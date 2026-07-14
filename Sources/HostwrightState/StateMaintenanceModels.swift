import Foundation

public struct StateMaintenancePaths: Codable, Equatable, Sendable {
    public let backupDirectory: String
    public let journalPath: String
    public let accessLockPath: String

    public init(backupDirectory: String, journalPath: String, accessLockPath: String) {
        self.backupDirectory = backupDirectory
        self.journalPath = journalPath
        self.accessLockPath = accessLockPath
    }
}

public enum StateIntegrityHealth: String, Codable, Equatable, Sendable {
    case healthy
    case degraded
    case unrecoverable
}

public enum StateIntegrityCheckStatus: String, Codable, Equatable, Sendable {
    case passed
    case warning
    case failed
}

public struct StateIntegrityCheck: Codable, Equatable, Sendable {
    public let identifier: String
    public let status: StateIntegrityCheckStatus
    public let message: String
    public let affectedRows: Int

    public init(
        identifier: String,
        status: StateIntegrityCheckStatus,
        message: String,
        affectedRows: Int = 0
    ) {
        self.identifier = identifier
        self.status = status
        self.message = message
        self.affectedRows = affectedRows
    }
}

public struct StateIntegrityReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let health: StateIntegrityHealth
    public let databaseSHA256: String?
    public let databaseBytes: UInt64?
    public let stateSchemaVersion: Int?
    public let checks: [StateIntegrityCheck]
    public let repairableProjectionTables: [String]
    public let recommendedAction: String

    public init(
        schemaVersion: Int = 1,
        health: StateIntegrityHealth,
        databaseSHA256: String?,
        databaseBytes: UInt64?,
        stateSchemaVersion: Int?,
        checks: [StateIntegrityCheck],
        repairableProjectionTables: [String],
        recommendedAction: String
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "stateIntegrityReport"
        self.health = health
        self.databaseSHA256 = databaseSHA256
        self.databaseBytes = databaseBytes
        self.stateSchemaVersion = stateSchemaVersion
        self.checks = checks
        self.repairableProjectionTables = repairableProjectionTables
        self.recommendedAction = recommendedAction
    }
}

public struct StateBackupRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let backupID: String
    public let createdAt: String?
    public let databaseSHA256: String?
    public let databaseBytes: UInt64?
    public let stateSchemaVersion: Int?
    public let restorable: Bool
    public let verificationMessage: String

    public init(
        schemaVersion: Int = 1,
        backupID: String,
        createdAt: String?,
        databaseSHA256: String?,
        databaseBytes: UInt64?,
        stateSchemaVersion: Int?,
        restorable: Bool,
        verificationMessage: String
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "stateBackupRecord"
        self.backupID = backupID
        self.createdAt = createdAt
        self.databaseSHA256 = databaseSHA256
        self.databaseBytes = databaseBytes
        self.stateSchemaVersion = stateSchemaVersion
        self.restorable = restorable
        self.verificationMessage = verificationMessage
    }
}

public struct StateBackupCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let backups: [StateBackupRecord]

    public init(schemaVersion: Int = 1, backups: [StateBackupRecord]) {
        self.schemaVersion = schemaVersion
        self.kind = "stateBackupCatalog"
        self.backups = backups
    }
}

public struct StateRestorePlan: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let backup: StateBackupRecord
    public let currentHealth: StateIntegrityHealth
    public let confirmationToken: String
    public let effects: [String]

    public init(
        schemaVersion: Int = 1,
        backup: StateBackupRecord,
        currentHealth: StateIntegrityHealth,
        confirmationToken: String,
        effects: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "stateRestorePlan"
        self.backup = backup
        self.currentHealth = currentHealth
        self.confirmationToken = confirmationToken
        self.effects = effects
    }
}

public struct StateRestoreResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let backupID: String
    public let preRestoreBackupID: String?
    public let quarantinedDatabasePath: String?
    public let clearedProjectionRows: [String: Int]
    public let health: StateIntegrityHealth

    public init(
        schemaVersion: Int = 1,
        backupID: String,
        preRestoreBackupID: String?,
        quarantinedDatabasePath: String?,
        clearedProjectionRows: [String: Int],
        health: StateIntegrityHealth
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "stateRestoreResult"
        self.backupID = backupID
        self.preRestoreBackupID = preRestoreBackupID
        self.quarantinedDatabasePath = quarantinedDatabasePath
        self.clearedProjectionRows = clearedProjectionRows
        self.health = health
    }
}

public struct StateRepairPlan: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let health: StateIntegrityHealth
    public let tables: [String: Int]
    public let confirmationToken: String

    public init(
        schemaVersion: Int = 1,
        health: StateIntegrityHealth,
        tables: [String: Int],
        confirmationToken: String
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "stateRepairPlan"
        self.health = health
        self.tables = tables
        self.confirmationToken = confirmationToken
    }
}

public struct StateRepairResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let preRepairBackupID: String
    public let clearedRows: [String: Int]
    public let health: StateIntegrityHealth

    public init(
        schemaVersion: Int = 1,
        preRepairBackupID: String,
        clearedRows: [String: Int],
        health: StateIntegrityHealth
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "stateRepairResult"
        self.preRepairBackupID = preRepairBackupID
        self.clearedRows = clearedRows
        self.health = health
    }
}

public struct StateRecoveryResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let recovered: Bool
    public let action: String
    public let health: StateIntegrityHealth?

    public init(
        schemaVersion: Int = 1,
        recovered: Bool,
        action: String,
        health: StateIntegrityHealth?
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "stateRecoveryResult"
        self.recovered = recovered
        self.action = action
        self.health = health
    }
}

public enum StateMaintenanceError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidBackupID(String)
    case backupNotFound(String)
    case backupNotRestorable(id: String, reason: String)
    case confirmationMismatch
    case unsafeRepair(String)
    case operationInProgress(String)
    case cancelled
    case io(path: String, message: String)
    case sqlite(message: String)
    case recoveryFailed(String)

    public var description: String {
        switch self {
        case .invalidBackupID(let id):
            return "Invalid state backup identifier: \(id)"
        case .backupNotFound(let id):
            return "State backup not found: \(id)"
        case .backupNotRestorable(let id, let reason):
            return "State backup \(id) is not restorable: \(reason)"
        case .confirmationMismatch:
            return "State changed after the dry-run plan or the confirmation token is invalid. Generate a new plan."
        case .unsafeRepair(let reason):
            return "State repair refused: \(reason)"
        case .operationInProgress(let journal):
            return "State maintenance is already in progress: \(journal)"
        case .cancelled:
            return "State maintenance was cancelled before publication."
        case .io(let path, let message):
            return "State maintenance I/O failed at \(path): \(message)"
        case .sqlite(let message):
            return "State maintenance SQLite operation failed: \(message)"
        case .recoveryFailed(let message):
            return "State maintenance recovery failed: \(message)"
        }
    }
}
