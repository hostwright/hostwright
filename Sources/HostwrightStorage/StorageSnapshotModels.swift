import Foundation

public enum StorageSnapshotConsistencyClass: String, Codable, Equatable, Sendable {
    case crashConsistent = "crash-consistent"
    case applicationConsistent = "application-consistent"
}

public enum StorageSnapshotCheckpoint: String, Codable, Equatable, Sendable, CaseIterable {
    case createPendingPrepared = "create-pending-prepared"
    case createSourceVerified = "create-source-verified"
    case createCopyComplete = "create-copy-complete"
    case createMetadataPrepared = "create-metadata-prepared"
    case createPromoted = "create-promoted"
    case exportIntegrityVerified = "export-integrity-verified"
    case exportCopyComplete = "export-copy-complete"
    case restoreIntegrityVerified = "restore-integrity-verified"
    case restoreStageCopyComplete = "restore-stage-copy-complete"
    case restoreBackupPrepared = "restore-backup-prepared"
    case restorePromoted = "restore-promoted"
    case deleteVerified = "delete-verified"
}

public struct StorageSnapshotQuiesceHooks: Sendable {
    public let preQuiesce: @Sendable () throws -> Void
    public let postQuiesce: @Sendable () throws -> Void

    public init(
        preQuiesce: @escaping @Sendable () throws -> Void,
        postQuiesce: @escaping @Sendable () throws -> Void
    ) {
        self.preQuiesce = preQuiesce
        self.postQuiesce = postQuiesce
    }
}

public struct StorageSnapshotFaultInjector: Sendable {
    private let injection: @Sendable (StorageSnapshotCheckpoint) throws -> Void

    public init(
        injection: @escaping @Sendable (StorageSnapshotCheckpoint) throws -> Void
    ) {
        self.injection = injection
    }

    public func inject(_ checkpoint: StorageSnapshotCheckpoint) throws {
        try injection(checkpoint)
    }

    public static let none = StorageSnapshotFaultInjector { _ in }
}

public struct StorageSnapshotHooks: Sendable {
    public let isCancelled: @Sendable () -> Bool
    public let faultInjector: StorageSnapshotFaultInjector

    public init(
        isCancelled: @escaping @Sendable () -> Bool = { false },
        faultInjector: StorageSnapshotFaultInjector = .none
    ) {
        self.isCancelled = isCancelled
        self.faultInjector = faultInjector
    }
}

public struct StorageSnapshotVolumeIdentity: Codable, Equatable, Sendable {
    public let volumeID: String
    public let providerID: String
    public let projectID: String
    public let projectGeneration: Int
    public let generation: Int
    public let fencingToken: String
    public let capacityBytes: Int64
    public let dataPath: String
    public let dataDevice: UInt64
    public let dataInode: UInt64

    public init(observation: LocalStorageVolumeObservation) {
        volumeID = observation.volumeID
        providerID = observation.providerID
        projectID = observation.projectID
        projectGeneration = observation.projectGeneration
        generation = observation.generation
        fencingToken = observation.fencingToken
        capacityBytes = observation.capacityBytes
        dataPath = observation.dataPath
        dataDevice = observation.dataDevice
        dataInode = observation.dataInode
    }
}

public struct StorageSnapshotReference: Codable, Equatable, Sendable {
    public let referenceID: String
    public let volumeID: String
    public let targetPath: String
    public let createdAt: Date

    public init(
        referenceID: String,
        volumeID: String,
        targetPath: String,
        createdAt: Date
    ) {
        self.referenceID = referenceID
        self.volumeID = volumeID
        self.targetPath = targetPath
        self.createdAt = createdAt
    }
}

public struct StorageSnapshotRecord: Codable, Equatable, Sendable {
    public let snapshotID: String
    public let name: String
    public let consistencyClass: StorageSnapshotConsistencyClass
    public let createdAt: Date
    public let source: StorageSnapshotVolumeIdentity
    public let parentContentTreeSHA256: String
    public let snapshotContentTreeSHA256: String
    public let retainedBy: [String]
    public let references: [StorageSnapshotReference]
    public let lineage: [String]

    public init(
        snapshotID: String,
        name: String,
        consistencyClass: StorageSnapshotConsistencyClass,
        createdAt: Date,
        source: StorageSnapshotVolumeIdentity,
        parentContentTreeSHA256: String,
        snapshotContentTreeSHA256: String,
        retainedBy: [String],
        references: [StorageSnapshotReference],
        lineage: [String]
    ) {
        self.snapshotID = snapshotID
        self.name = name
        self.consistencyClass = consistencyClass
        self.createdAt = createdAt
        self.source = source
        self.parentContentTreeSHA256 = parentContentTreeSHA256
        self.snapshotContentTreeSHA256 = snapshotContentTreeSHA256
        self.retainedBy = retainedBy.sorted()
        self.references = references.sorted { lhs, rhs in
            if lhs.referenceID == rhs.referenceID {
                return lhs.targetPath < rhs.targetPath
            }
            return lhs.referenceID < rhs.referenceID
        }
        self.lineage = lineage.sorted()
    }
}

public struct StorageSnapshotRestoreResult: Equatable, Sendable {
    public let snapshot: StorageSnapshotRecord
    public let restoredVolumeID: String
    public let restoredPath: String

    public init(
        snapshot: StorageSnapshotRecord,
        restoredVolumeID: String,
        restoredPath: String
    ) {
        self.snapshot = snapshot
        self.restoredVolumeID = restoredVolumeID
        self.restoredPath = restoredPath
    }
}

public enum StorageSnapshotError: Error, Equatable, Sendable {
    case snapshotNotFound
    case snapshotAlreadyExists
    case invalidSnapshotID
    case staleGeneration
    case fencingConflict
    case cancelled
    case unsafePath
    case destinationExists
    case wrongParent
    case integrityMismatch
    case applicationConsistencyRequiresHooks
    case snapshotRetained
    case snapshotReferenced
    case ioFailure
}
