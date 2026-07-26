import CryptoKit
import Foundation

public enum LocalStorageProviderContract {
    public static let providerID = "hostwright-local"
    public static let providerVersion = "1.0.0"
    public static let ownershipMarker = "dev.hostwright.storage.volume.v1"
    public static let maximumVolumes = 10_000
    public static let maximumAttachmentsPerVolume = 256
    public static let maximumDataProtectionVolumes = 256
    public static let maximumJournalRecords = 4_096
    public static let maximumMetadataBytes = 1 * 1_024 * 1_024

    public static let descriptor = StorageProviderDescriptor(
        providerID: providerID,
        providerVersion: providerVersion,
        capabilities: StorageProviderOperation.allCases.map { operation in
            let available: Set<StorageProviderOperation> = [
                .create,
                .observe,
                .attach,
                .detach,
                .snapshot,
                .backup,
                .restore,
                .expand,
                .delete,
                .health,
                .recovery
            ]
            return StorageProviderCapability(
                operation: operation,
                state: available.contains(operation) ? .available : .unavailable,
                reason: available.contains(operation)
                    ? "The built-in private local-filesystem provider implements this operation."
                    : "The built-in provider does not implement \(operation.rawValue) in this phase."
            )
        }
    )
}

public enum LocalStorageRetentionPolicy: String, Codable, CaseIterable, Sendable {
    case retain
    case deleteWhenUnused = "delete-when-unused"
}

public enum LocalStorageMutationDisposition: String, Codable, Sendable {
    case performed
    case alreadySatisfied = "already-satisfied"
    case recovered
}

public struct LocalStorageCreatePayload: Codable, Equatable, Sendable {
    public let name: String
    public let capacityBytes: Int64
    public let retention: LocalStorageRetentionPolicy

    public init(
        name: String,
        capacityBytes: Int64,
        retention: LocalStorageRetentionPolicy = .retain
    ) {
        self.name = name
        self.capacityBytes = capacityBytes
        self.retention = retention
    }
}

public struct LocalStorageObservePayload: Codable, Equatable, Sendable {
    public let volumeID: String?

    public init(volumeID: String? = nil) {
        self.volumeID = volumeID
    }
}

public struct LocalStorageAttachPayload: Codable, Equatable, Sendable {
    public let attachmentID: String
    public let consumerID: String
    public let readOnly: Bool
    public let volumeGeneration: Int
    public let volumeFencingToken: String

    public init(
        attachmentID: String,
        consumerID: String,
        readOnly: Bool,
        volumeGeneration: Int,
        volumeFencingToken: String
    ) {
        self.attachmentID = attachmentID
        self.consumerID = consumerID
        self.readOnly = readOnly
        self.volumeGeneration = volumeGeneration
        self.volumeFencingToken = volumeFencingToken
    }
}

public struct LocalStorageDetachPayload: Codable, Equatable, Sendable {
    public let attachmentID: String
    public let volumeGeneration: Int
    public let volumeFencingToken: String
    public let expectedAttachmentGeneration: Int
    public let expectedAttachmentFencingToken: String

    public init(
        attachmentID: String,
        volumeGeneration: Int,
        volumeFencingToken: String,
        expectedAttachmentGeneration: Int,
        expectedAttachmentFencingToken: String
    ) {
        self.attachmentID = attachmentID
        self.volumeGeneration = volumeGeneration
        self.volumeFencingToken = volumeFencingToken
        self.expectedAttachmentGeneration =
            expectedAttachmentGeneration
        self.expectedAttachmentFencingToken =
            expectedAttachmentFencingToken
    }
}

public struct LocalStorageExpandPayload: Codable, Equatable, Sendable {
    public let capacityBytes: Int64

    public init(capacityBytes: Int64) {
        self.capacityBytes = capacityBytes
    }
}

public struct LocalStorageDeletePayload: Codable, Equatable, Sendable {
    public init() {}
}

public struct LocalStorageHealthPayload: Codable, Equatable, Sendable {
    public init() {}
}

public struct LocalStorageRecoveryPayload: Codable, Equatable, Sendable {
    public let idempotencyKey: String

    public init(idempotencyKey: String) {
        self.idempotencyKey = idempotencyKey
    }
}

public struct LocalStorageUnsupportedPayload: Codable, Equatable, Sendable {
    public init() {}
}

public struct LocalStorageAttachmentObservation: Codable, Equatable, Sendable {
    public let attachmentID: String
    public let consumerID: String
    public let generation: Int
    public let fencingToken: String
    public let readOnly: Bool

    public init(
        attachmentID: String,
        consumerID: String,
        generation: Int,
        fencingToken: String,
        readOnly: Bool
    ) {
        self.attachmentID = attachmentID
        self.consumerID = consumerID
        self.generation = generation
        self.fencingToken = fencingToken
        self.readOnly = readOnly
    }
}

public struct LocalStorageVolumeObservation: Codable, Equatable, Sendable {
    public let volumeID: String
    public let name: String
    public let providerID: String
    public let projectID: String
    public let projectGeneration: Int
    public let generation: Int
    public let fencingToken: String
    public let capacityBytes: Int64
    public let retention: LocalStorageRetentionPolicy
    public let dataPath: String
    public let dataDevice: UInt64
    public let dataInode: UInt64
    public let attachments: [LocalStorageAttachmentObservation]

    public init(
        volumeID: String,
        name: String,
        providerID: String,
        projectID: String,
        projectGeneration: Int,
        generation: Int,
        fencingToken: String,
        capacityBytes: Int64,
        retention: LocalStorageRetentionPolicy,
        dataPath: String,
        dataDevice: UInt64,
        dataInode: UInt64,
        attachments: [LocalStorageAttachmentObservation]
    ) {
        self.volumeID = volumeID
        self.name = name
        self.providerID = providerID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.generation = generation
        self.fencingToken = fencingToken
        self.capacityBytes = capacityBytes
        self.retention = retention
        self.dataPath = dataPath
        self.dataDevice = dataDevice
        self.dataInode = dataInode
        self.attachments = attachments.sorted {
            $0.attachmentID < $1.attachmentID
        }
    }
}

public struct LocalStorageObservation: Codable, Equatable, Sendable {
    public let volumes: [LocalStorageVolumeObservation]
    public let unmanagedEntries: [String]
    public let ambiguousVolumeIDs: [String]
    public let pendingRecoveryIDs: [String]
    public let totalCapacityBytes: Int64
    public let reservedCapacityBytes: Int64
    public let availableCapacityBytes: Int64

    public init(
        volumes: [LocalStorageVolumeObservation],
        unmanagedEntries: [String],
        ambiguousVolumeIDs: [String],
        pendingRecoveryIDs: [String],
        totalCapacityBytes: Int64,
        reservedCapacityBytes: Int64
    ) {
        self.volumes = volumes.sorted { $0.volumeID < $1.volumeID }
        self.unmanagedEntries = unmanagedEntries.sorted()
        self.ambiguousVolumeIDs = ambiguousVolumeIDs.sorted()
        self.pendingRecoveryIDs = pendingRecoveryIDs.sorted()
        self.totalCapacityBytes = totalCapacityBytes
        self.reservedCapacityBytes = reservedCapacityBytes
        availableCapacityBytes = max(
            0,
            totalCapacityBytes - reservedCapacityBytes
        )
    }
}

public struct LocalStorageMutationResult: Codable, Equatable, Sendable {
    public let disposition: LocalStorageMutationDisposition
    public let volume: LocalStorageVolumeObservation?
    public let removedVolumeID: String?

    public init(
        disposition: LocalStorageMutationDisposition,
        volume: LocalStorageVolumeObservation? = nil,
        removedVolumeID: String? = nil
    ) {
        self.disposition = disposition
        self.volume = volume
        self.removedVolumeID = removedVolumeID
    }
}

public struct LocalStorageHealthResult: Codable, Equatable, Sendable {
    public let healthy: Bool
    public let issues: [String]
    public let volumeCount: Int
    public let pendingRecoveryCount: Int
    public let totalCapacityBytes: Int64
    public let availableCapacityBytes: Int64

    public init(
        issues: [String],
        volumeCount: Int,
        pendingRecoveryCount: Int,
        totalCapacityBytes: Int64,
        availableCapacityBytes: Int64
    ) {
        let sortedIssues = issues.sorted()
        healthy = sortedIssues.isEmpty
        self.issues = sortedIssues
        self.volumeCount = volumeCount
        self.pendingRecoveryCount = pendingRecoveryCount
        self.totalCapacityBytes = totalCapacityBytes
        self.availableCapacityBytes = availableCapacityBytes
    }
}

public struct LocalStorageRecoveryResult: Codable, Equatable, Sendable {
    public let disposition: LocalStorageMutationDisposition
    public let recoveredOperation: StorageProviderOperation
    public let recoveredRequestID: String

    public init(
        disposition: LocalStorageMutationDisposition,
        recoveredOperation: StorageProviderOperation,
        recoveredRequestID: String
    ) {
        self.disposition = disposition
        self.recoveredOperation = recoveredOperation
        self.recoveredRequestID = recoveredRequestID
    }
}

public struct LocalStoragePrunePlan: Codable, Equatable, Sendable {
    public let volumeIDs: [String]
    public let confirmationSHA256: String
    public let reclaimedCapacityBytes: Int64

    public init(
        volumeIDs: [String],
        reclaimedCapacityBytes: Int64
    ) {
        self.volumeIDs = volumeIDs.sorted()
        self.reclaimedCapacityBytes = reclaimedCapacityBytes
        let text = self.volumeIDs.joined(separator: "\n")
            + "\n\(reclaimedCapacityBytes)"
        confirmationSHA256 = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct LocalStoragePruneResult: Codable, Equatable, Sendable {
    public let removedVolumeIDs: [String]
    public let reclaimedCapacityBytes: Int64

    public init(
        removedVolumeIDs: [String],
        reclaimedCapacityBytes: Int64
    ) {
        self.removedVolumeIDs = removedVolumeIDs.sorted()
        self.reclaimedCapacityBytes = reclaimedCapacityBytes
    }
}

public enum LocalStorageProviderError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidRequest
    case unsafePath
    case unsafeOwnership
    case unsafePermissions
    case crossDeviceEntry
    case capacityExceeded
    case volumeLimitExceeded
    case attachmentLimitExceeded
    case volumeNotFound
    case nameCollision
    case ownershipMismatch
    case generationMismatch
    case fencingConflict
    case attachmentConflict
    case volumeAttached
    case ambiguousVolume
    case idempotencyConflict
    case journalLimitExceeded
    case recoveryNotFound
    case recoveryContextMismatch
    case pruneConfirmationMismatch
    case dataProtectionNotFound
    case dataProtectionConflict
    case integrityMismatch
    case backupKeyRejected
    case unavailable(StorageProviderOperation)
    case cancelled
    case ioFailure
}

public enum LocalStorageProviderFaultPoint: String, Sendable {
    case afterIntentPersisted
    case afterEffectPersisted
    case afterReceiptPersisted
}

public struct LocalStorageProviderFaultInjector: Sendable {
    private let injection: @Sendable (LocalStorageProviderFaultPoint) throws -> Void

    public init(
        injection: @escaping @Sendable (LocalStorageProviderFaultPoint) throws -> Void
    ) {
        self.injection = injection
    }

    public func inject(_ point: LocalStorageProviderFaultPoint) throws {
        try injection(point)
    }

    public static let none = LocalStorageProviderFaultInjector { _ in }
}

public struct LocalStorageProviderInjectedInterruption:
    Error,
    Equatable,
    Sendable
{
    public let point: LocalStorageProviderFaultPoint

    public init(point: LocalStorageProviderFaultPoint) {
        self.point = point
    }
}
