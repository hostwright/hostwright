import Foundation
import HostwrightCore

public enum HostwrightSupportBundleContract {
    public static let schemaVersion = 1
    public static let source = "hostwright.support-bundle"
    public static let createdEventType = "support.bundle.created.v1"
    public static let deletedEventType = "support.bundle.deleted.v1"
    public static let failedEventType = "support.bundle.failed.v1"
    public static let maximumLogs = 200
    public static let maximumEvents = 200
    public static let maximumTraces = 20
    public static let maximumOperations = 200
    public static let maximumEvidence = 200
    public static let maximumSectionBytes = 3 * 1_024 * 1_024
    public static let maximumPlaintextBytes = 4 * 1_024 * 1_024
    public static let maximumEncryptedBytes = 8 * 1_024 * 1_024
    public static let maximumRecipientReferenceBytes = 128

    public static func isValidSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    public static func isValidRecipientReference(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumRecipientReferenceBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        return value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._+@ -]{0,127}$",
            options: .regularExpression
        ) != nil
    }
}

public enum HostwrightSupportBundleAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
    case degraded
}

public struct HostwrightSupportBundleSectionSummary: Codable, Equatable, Sendable {
    public let name: String
    public let availability: HostwrightSupportBundleAvailability
    public let records: Int
    public let droppedRecords: Int
    public let encodedBytes: Int
    public let reasonCode: String?

    public init(
        name: String,
        availability: HostwrightSupportBundleAvailability,
        records: Int,
        droppedRecords: Int,
        encodedBytes: Int,
        reasonCode: String? = nil
    ) {
        self.name = name
        self.availability = availability
        self.records = records
        self.droppedRecords = droppedRecords
        self.encodedBytes = encodedBytes
        self.reasonCode = reasonCode
    }
}

public struct HostwrightSupportVersionInventory: Codable, Equatable, Sendable {
    public let productVersion: String
    public let releaseTarget: String
    public let manifestVersion: Int
    public let stateSchemaVersion: Int
    public let controlAPIVersion: Int
    public let runtimeProviderAPIVersion: Int
    public let storageProviderAPIVersion: Int
    public let networkProviderSPIVersion: Int
    public let operatingSystem: String
    public let architecture: String
    public let swiftVersion: String?

    public init(
        productVersion: String,
        releaseTarget: String,
        manifestVersion: Int,
        stateSchemaVersion: Int,
        controlAPIVersion: Int,
        runtimeProviderAPIVersion: Int,
        storageProviderAPIVersion: Int,
        networkProviderSPIVersion: Int,
        operatingSystem: String,
        architecture: String,
        swiftVersion: String?
    ) {
        self.productVersion = productVersion
        self.releaseTarget = releaseTarget
        self.manifestVersion = manifestVersion
        self.stateSchemaVersion = stateSchemaVersion
        self.controlAPIVersion = controlAPIVersion
        self.runtimeProviderAPIVersion = runtimeProviderAPIVersion
        self.storageProviderAPIVersion = storageProviderAPIVersion
        self.networkProviderSPIVersion = networkProviderSPIVersion
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.swiftVersion = swiftVersion
    }
}

public struct HostwrightSupportConfigurationShape: Codable, Equatable, Sendable {
    public let manifestProvided: Bool
    public let manifestVersion: Int?
    public let serviceCount: Int
    public let healthProbeCount: Int
    public let storageMountCount: Int
    public let publishedPortCount: Int
    public let hasRestartPolicy: Bool
    public let hasMaintenancePolicy: Bool
    public let hasRolloutPolicy: Bool
    public let hasRollbackPolicy: Bool
    public let hasRetentionPolicy: Bool
    public let hasObservabilityPolicy: Bool

    public init(
        manifestProvided: Bool,
        manifestVersion: Int?,
        serviceCount: Int,
        healthProbeCount: Int,
        storageMountCount: Int,
        publishedPortCount: Int,
        hasRestartPolicy: Bool,
        hasMaintenancePolicy: Bool,
        hasRolloutPolicy: Bool,
        hasRollbackPolicy: Bool,
        hasRetentionPolicy: Bool,
        hasObservabilityPolicy: Bool
    ) {
        self.manifestProvided = manifestProvided
        self.manifestVersion = manifestVersion
        self.serviceCount = serviceCount
        self.healthProbeCount = healthProbeCount
        self.storageMountCount = storageMountCount
        self.publishedPortCount = publishedPortCount
        self.hasRestartPolicy = hasRestartPolicy
        self.hasMaintenancePolicy = hasMaintenancePolicy
        self.hasRolloutPolicy = hasRolloutPolicy
        self.hasRollbackPolicy = hasRollbackPolicy
        self.hasRetentionPolicy = hasRetentionPolicy
        self.hasObservabilityPolicy = hasObservabilityPolicy
    }

    public static let absent = HostwrightSupportConfigurationShape(
        manifestProvided: false,
        manifestVersion: nil,
        serviceCount: 0,
        healthProbeCount: 0,
        storageMountCount: 0,
        publishedPortCount: 0,
        hasRestartPolicy: false,
        hasMaintenancePolicy: false,
        hasRolloutPolicy: false,
        hasRollbackPolicy: false,
        hasRetentionPolicy: false,
        hasObservabilityPolicy: false
    )
}

public struct HostwrightSupportIntegrityCheck: Codable, Equatable, Sendable {
    public let identifier: String
    public let status: String

    public init(identifier: String, status: String) {
        self.identifier = identifier
        self.status = status
    }
}

public struct HostwrightSupportStateIntegrity: Codable, Equatable, Sendable {
    public let health: String
    public let databaseSHA256: String
    public let databaseBytes: UInt64
    public let stateSchemaVersion: Int
    public let checks: [HostwrightSupportIntegrityCheck]

    public init(
        health: String,
        databaseSHA256: String,
        databaseBytes: UInt64,
        stateSchemaVersion: Int,
        checks: [HostwrightSupportIntegrityCheck]
    ) {
        self.health = health
        self.databaseSHA256 = databaseSHA256
        self.databaseBytes = databaseBytes
        self.stateSchemaVersion = stateSchemaVersion
        self.checks = checks
    }
}

public struct HostwrightSupportLogRecord: Codable, Equatable, Sendable {
    public let timestamp: String
    public let category: String
    public let messageType: String
    public let messageRedacted: String

    public init(timestamp: String, category: String, messageType: String, messageRedacted: String) {
        self.timestamp = timestamp
        self.category = category
        self.messageType = messageType
        self.messageRedacted = messageRedacted
    }
}

public struct HostwrightSupportLogCollection: Equatable, Sendable {
    public let availability: HostwrightSupportBundleAvailability
    public let records: [HostwrightSupportLogRecord]
    public let droppedRecords: Int
    public let reasonCode: String?

    public init(
        availability: HostwrightSupportBundleAvailability,
        records: [HostwrightSupportLogRecord],
        droppedRecords: Int,
        reasonCode: String? = nil
    ) {
        self.availability = availability
        self.records = records
        self.droppedRecords = droppedRecords
        self.reasonCode = reasonCode
    }

    public static let unavailable = HostwrightSupportLogCollection(
        availability: .unavailable,
        records: [],
        droppedRecords: 0,
        reasonCode: "HW-SUPPORT-LOGS-UNAVAILABLE"
    )
}

public struct HostwrightSupportEventRecord: Codable, Equatable, Sendable {
    public let id: String
    public let timestamp: String
    public let severity: String
    public let type: String
    public let source: String

    public init(id: String, timestamp: String, severity: String, type: String, source: String) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.type = type
        self.source = source
    }
}

public struct HostwrightSupportOperationRecord: Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: String
    public let updatedAt: String
    public let plannedActionType: String
    public let status: String
    public let planHash: String

    public init(
        id: String,
        createdAt: String,
        updatedAt: String,
        plannedActionType: String,
        status: String,
        planHash: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.plannedActionType = plannedActionType
        self.status = status
        self.planHash = planHash
    }
}

public struct HostwrightSupportEvidenceRecord: Codable, Equatable, Sendable {
    public let id: String
    public let timestamp: String
    public let severity: String
    public let type: String
    public let source: String

    public init(id: String, timestamp: String, severity: String, type: String, source: String) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.type = type
        self.source = source
    }
}

public struct HostwrightSupportBundleContent: Codable, Equatable, Sendable {
    public let versions: HostwrightSupportVersionInventory
    public let capabilities: HostwrightCapabilityReport
    public let configuration: HostwrightSupportConfigurationShape
    public let stateIntegrity: HostwrightSupportStateIntegrity
    public let logs: [HostwrightSupportLogRecord]
    public let events: [HostwrightSupportEventRecord]
    public let metrics: HostwrightMetricsSnapshot
    public let traces: [HostwrightTraceView]
    public let operations: [HostwrightSupportOperationRecord]
    public let evidence: [HostwrightSupportEvidenceRecord]

    public init(
        versions: HostwrightSupportVersionInventory,
        capabilities: HostwrightCapabilityReport,
        configuration: HostwrightSupportConfigurationShape,
        stateIntegrity: HostwrightSupportStateIntegrity,
        logs: [HostwrightSupportLogRecord],
        events: [HostwrightSupportEventRecord],
        metrics: HostwrightMetricsSnapshot,
        traces: [HostwrightTraceView],
        operations: [HostwrightSupportOperationRecord],
        evidence: [HostwrightSupportEvidenceRecord]
    ) {
        self.versions = versions
        self.capabilities = capabilities
        self.configuration = configuration
        self.stateIntegrity = stateIntegrity
        self.logs = logs
        self.events = events
        self.metrics = metrics
        self.traces = traces
        self.operations = operations
        self.evidence = evidence
    }
}

public struct HostwrightSupportBundlePreview: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let generatedAt: String
    public let bundleID: String
    public let previewSHA256: String
    public let estimatedPlaintextBytes: Int
    public let sections: [HostwrightSupportBundleSectionSummary]
    public let automaticUpload: Bool
    public let requiresConfirmation: Bool

    public init(
        generatedAt: String,
        bundleID: String,
        previewSHA256: String,
        estimatedPlaintextBytes: Int,
        sections: [HostwrightSupportBundleSectionSummary]
    ) {
        self.schemaVersion = HostwrightSupportBundleContract.schemaVersion
        self.kind = "hostwright.support-bundle.preview"
        self.generatedAt = generatedAt
        self.bundleID = bundleID
        self.previewSHA256 = previewSHA256
        self.estimatedPlaintextBytes = estimatedPlaintextBytes
        self.sections = sections
        self.automaticUpload = false
        self.requiresConfirmation = true
    }
}

public struct HostwrightSupportBundle: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let bundleID: String
    public let createdAt: String
    public let previewSHA256: String
    public let content: HostwrightSupportBundleContent
    public let sections: [HostwrightSupportBundleSectionSummary]
    public let automaticUpload: Bool

    public init(
        bundleID: String,
        createdAt: String,
        previewSHA256: String,
        content: HostwrightSupportBundleContent,
        sections: [HostwrightSupportBundleSectionSummary]
    ) {
        self.schemaVersion = HostwrightSupportBundleContract.schemaVersion
        self.kind = "hostwright.support-bundle"
        self.bundleID = bundleID
        self.createdAt = createdAt
        self.previewSHA256 = previewSHA256
        self.content = content
        self.sections = sections
        self.automaticUpload = false
    }
}

public struct HostwrightSupportBundleReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let bundleID: String
    public let previewSHA256: String
    public let outputPath: String
    public let outputSHA256: String
    public let outputBytes: UInt64
    public let encrypted: Bool
    public let recipientReferenceSHA256: String?
    public let automaticUpload: Bool
    public let ownership: String

    public init(
        bundleID: String,
        previewSHA256: String,
        outputPath: String,
        outputSHA256: String,
        outputBytes: UInt64,
        encrypted: Bool,
        recipientReferenceSHA256: String?
    ) {
        self.schemaVersion = HostwrightSupportBundleContract.schemaVersion
        self.kind = "hostwright.support-bundle.receipt"
        self.bundleID = bundleID
        self.previewSHA256 = previewSHA256
        self.outputPath = outputPath
        self.outputSHA256 = outputSHA256
        self.outputBytes = outputBytes
        self.encrypted = encrypted
        self.recipientReferenceSHA256 = recipientReferenceSHA256
        self.automaticUpload = false
        self.ownership = "operator-owned"
    }
}

public struct HostwrightSupportBundleFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let sha256: String
    public let bytes: UInt64

    public init(device: UInt64, inode: UInt64, sha256: String, bytes: UInt64) {
        self.device = device
        self.inode = inode
        self.sha256 = sha256
        self.bytes = bytes
    }
}

public struct HostwrightSupportBundleDeletionReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let bundleID: String
    public let outputPath: String
    public let outputSHA256: String
    public let deleted: Bool

    public init(bundleID: String, outputPath: String, outputSHA256: String) {
        self.schemaVersion = HostwrightSupportBundleContract.schemaVersion
        self.kind = "hostwright.support-bundle.deletion"
        self.bundleID = bundleID
        self.outputPath = outputPath
        self.outputSHA256 = outputSHA256
        self.deleted = true
    }
}

public enum HostwrightSupportBundleError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidContract
    case previewChanged
    case unsafeOutputPath
    case sectionLimitExceeded
    case plaintextLimitExceeded
    case invalidRecipientReference
    case encryptionUnavailable
    case encryptionFailed
    case receiptUnavailable
    case bundleIdentityChanged
    case recoveryRequired
    case recoverySafeHold
    case cancelled

    public var code: String {
        diagnosticCode.rawValue
    }

    public var diagnosticCode: HostwrightErrorCode {
        switch self {
        case .invalidContract: .supportInvalidContract
        case .previewChanged: .supportPreviewChanged
        case .unsafeOutputPath: .supportUnsafeOutputPath
        case .sectionLimitExceeded: .supportSectionLimitExceeded
        case .plaintextLimitExceeded: .supportPlaintextLimitExceeded
        case .invalidRecipientReference: .supportInvalidRecipientReference
        case .encryptionUnavailable: .supportEncryptionUnavailable
        case .encryptionFailed: .supportEncryptionFailed
        case .receiptUnavailable: .supportReceiptUnavailable
        case .bundleIdentityChanged: .supportBundleIdentityChanged
        case .recoveryRequired: .supportRecoveryRequired
        case .recoverySafeHold: .supportRecoverySafeHold
        case .cancelled: .supportCancelled
        }
    }

    public var diagnostic: HostwrightDiagnostic {
        HostwrightDiagnostic(
            code: diagnosticCode,
            message: description.replacingOccurrences(of: "\(code): ", with: "")
        )
    }

    public var description: String {
        switch self {
        case .invalidContract: "\(code): The support-bundle contract is invalid."
        case .previewChanged: "\(code): Support evidence changed; inspect and confirm a fresh preview."
        case .unsafeOutputPath: "\(code): Support bundles require one normalized absolute new private file path."
        case .sectionLimitExceeded: "\(code): A support-bundle section exceeded its fixed size limit."
        case .plaintextLimitExceeded: "\(code): The support bundle exceeded its fixed total size limit."
        case .invalidRecipientReference: "\(code): The non-secret encryption recipient reference is invalid."
        case .encryptionUnavailable: "\(code): Platform CMS encryption is unavailable for the selected recipient."
        case .encryptionFailed: "\(code): Platform CMS encryption failed without producing an output bundle."
        case .receiptUnavailable: "\(code): No retained Hostwright creation receipt proves ownership of this exact bundle."
        case .bundleIdentityChanged: "\(code): The selected support-bundle file identity or content changed."
        case .recoveryRequired: "\(code): A support-bundle journal requires recovery before another mutation."
        case .recoverySafeHold: "\(code): Support-bundle recovery cannot prove the exact external file identity; preserve the journal and file."
        case .cancelled: "\(code): The support-bundle operation was cancelled without an unacknowledged file effect."
        }
    }
}
