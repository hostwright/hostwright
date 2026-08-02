import Foundation

public enum StateRetentionClass: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case operations
    case observations
    case events
    case logs
    case metrics
    case traces
    case audits
    case supportEvidence
    case backups
    case tombstones
}

public struct StateRetentionClassPolicy: Codable, Equatable, Sendable {
    public let maxAgeSeconds: Int
    public let maxRecords: Int
    public let minimumRecords: Int

    public init(maxAgeSeconds: Int, maxRecords: Int, minimumRecords: Int) {
        self.maxAgeSeconds = maxAgeSeconds
        self.maxRecords = maxRecords
        self.minimumRecords = minimumRecords
    }
}

public struct StateRetentionHold: Codable, Equatable, Sendable {
    public let id: String
    public let retentionClass: StateRetentionClass
    public let selector: String
    public let reason: String
    public let expiresAt: String?

    public init(
        id: String,
        retentionClass: StateRetentionClass,
        selector: String,
        reason: String,
        expiresAt: String? = nil
    ) {
        self.id = id
        self.retentionClass = retentionClass
        self.selector = selector
        self.reason = reason
        self.expiresAt = expiresAt
    }
}

public struct StateRetentionPolicy: Codable, Equatable, Sendable {
    public let recoveryHorizonSeconds: Int
    public let maximumDatabaseBytes: UInt64
    public let targetDatabaseBytes: UInt64
    public let classes: [StateRetentionClass: StateRetentionClassPolicy]
    public let holds: [StateRetentionHold]

    public init(
        recoveryHorizonSeconds: Int,
        maximumDatabaseBytes: UInt64,
        targetDatabaseBytes: UInt64,
        classes: [StateRetentionClass: StateRetentionClassPolicy],
        holds: [StateRetentionHold] = []
    ) {
        self.recoveryHorizonSeconds = recoveryHorizonSeconds
        self.maximumDatabaseBytes = maximumDatabaseBytes
        self.targetDatabaseBytes = targetDatabaseBytes
        self.classes = classes
        self.holds = holds
    }
}

public enum StateRetentionPressure: String, Codable, Equatable, Sendable {
    case normal
    case eligible
    case held
}

public struct StateRetentionClassStatus: Codable, Equatable, Sendable {
    public let retentionClass: StateRetentionClass
    public let producerAvailable: Bool
    public let currentRecords: Int
    public let candidateRecords: Int
    public let heldRecords: Int
    public let recoveryCriticalRecords: Int
    public let candidateIdentitySHA256: String
    public let note: String

    public init(
        retentionClass: StateRetentionClass,
        producerAvailable: Bool,
        currentRecords: Int,
        candidateRecords: Int,
        heldRecords: Int,
        recoveryCriticalRecords: Int,
        candidateIdentitySHA256: String,
        note: String
    ) {
        self.retentionClass = retentionClass
        self.producerAvailable = producerAvailable
        self.currentRecords = currentRecords
        self.candidateRecords = candidateRecords
        self.heldRecords = heldRecords
        self.recoveryCriticalRecords = recoveryCriticalRecords
        self.candidateIdentitySHA256 = candidateIdentitySHA256
        self.note = note
    }
}

public struct StateRetentionStatus: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let policySHA256: String
    public let databaseSHA256: String
    public let databaseBytes: UInt64
    public let pressure: StateRetentionPressure
    public let classes: [StateRetentionClassStatus]
    public let blockers: [String]
    public let pendingCompactionPlanSHA256: String?

    public init(
        schemaVersion: Int = 1,
        policySHA256: String,
        databaseSHA256: String,
        databaseBytes: UInt64,
        pressure: StateRetentionPressure,
        classes: [StateRetentionClassStatus],
        blockers: [String],
        pendingCompactionPlanSHA256: String?
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "stateRetentionStatus"
        self.policySHA256 = policySHA256
        self.databaseSHA256 = databaseSHA256
        self.databaseBytes = databaseBytes
        self.pressure = pressure
        self.classes = classes
        self.blockers = blockers
        self.pendingCompactionPlanSHA256 = pendingCompactionPlanSHA256
    }
}

public struct StateCompactionPlan: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let policySHA256: String
    public let databaseSHA256: String
    public let databaseBytes: UInt64
    public let pressure: StateRetentionPressure
    public let classes: [StateRetentionClassStatus]
    public let candidateRecords: Int
    public let candidateBytes: UInt64
    public let blockers: [String]
    public let executable: Bool
    public let confirmationToken: String

    public init(
        schemaVersion: Int = 1,
        policySHA256: String,
        databaseSHA256: String,
        databaseBytes: UInt64,
        pressure: StateRetentionPressure,
        classes: [StateRetentionClassStatus],
        candidateRecords: Int,
        candidateBytes: UInt64,
        blockers: [String],
        executable: Bool,
        confirmationToken: String
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "stateCompactionPlan"
        self.policySHA256 = policySHA256
        self.databaseSHA256 = databaseSHA256
        self.databaseBytes = databaseBytes
        self.pressure = pressure
        self.classes = classes
        self.candidateRecords = candidateRecords
        self.candidateBytes = candidateBytes
        self.blockers = blockers
        self.executable = executable
        self.confirmationToken = confirmationToken
    }
}

public struct StateCompactionResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let planSHA256: String
    public let preCompactionBackupID: String
    public let deletedRecords: [StateRetentionClass: Int]
    public let databaseBytesBefore: UInt64
    public let databaseBytesAfter: UInt64
    public let integrityHealth: StateIntegrityHealth
    public let resumed: Bool

    public init(
        schemaVersion: Int = 1,
        planSHA256: String,
        preCompactionBackupID: String,
        deletedRecords: [StateRetentionClass: Int],
        databaseBytesBefore: UInt64,
        databaseBytesAfter: UInt64,
        integrityHealth: StateIntegrityHealth,
        resumed: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "stateCompactionResult"
        self.planSHA256 = planSHA256
        self.preCompactionBackupID = preCompactionBackupID
        self.deletedRecords = deletedRecords
        self.databaseBytesBefore = databaseBytesBefore
        self.databaseBytesAfter = databaseBytesAfter
        self.integrityHealth = integrityHealth
        self.resumed = resumed
    }
}
