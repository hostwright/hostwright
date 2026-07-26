import Foundation
import HostwrightStorage

public enum StorageVolumeLifecycleState: String, Codable, CaseIterable, Sendable {
    case creating
    case available
    case expanding
    case deleting
    case deleted
    case faulted
}

public enum StorageReclaimPolicy: String, Codable, CaseIterable, Sendable {
    case retain
    case delete
    case snapshotBeforeDelete = "snapshot-before-delete"
    case backupBeforeDelete = "backup-before-delete"
    case recycle
}

public enum StorageAccessMode: String, Codable, CaseIterable, Sendable {
    case readWriteOnce = "read-write-once"
    case readOnlyMany = "read-only-many"
}

public enum StorageAttachmentKind: String, Codable, CaseIterable, Sendable {
    case stage
    case publish
}

public enum StorageSnapshotLifecycleState:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case creating
    case ready
    case deleting
    case deleted
    case faulted
}

public enum StorageBackupLifecycleState:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case creating
    case ready
    case restoring
    case deleting
    case deleted
    case faulted
}

public enum StorageHoldResourceKind: String, Codable, CaseIterable, Sendable {
    case volume
    case snapshot
    case backup
}

public enum StorageOrphanResourceKind: String, Codable, CaseIterable, Sendable {
    case volume
    case attachment
    case snapshot
    case backup
}

public enum StorageOrphanLifecycleState:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case discovered
    case held
    case reclaimed
    case ignored
}

public struct StorageStateExpectedVersion: Codable, Equatable, Sendable {
    public let generation: Int64
    public let fencingToken: String

    public init(generation: Int64, fencingToken: String) {
        self.generation = generation
        self.fencingToken = fencingToken
    }
}

public struct StorageStateVolumeRecord: Codable, Equatable, Sendable {
    public let id: String
    public let projectID: String
    public let name: String
    public let providerID: String
    public let providerVolumeID: String
    public let topologyNodeID: String
    public let generation: Int64
    public let fencingToken: String
    public let capacityBytes: Int64
    public let lifecycleState: StorageVolumeLifecycleState
    public let reclaimPolicy: StorageReclaimPolicy
    public let accessMode: StorageAccessMode
    public let sourceKind: StorageHoldResourceKind?
    public let sourceID: String?
    public let operationGroupID: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        projectID: String,
        name: String,
        providerID: String,
        providerVolumeID: String,
        topologyNodeID: String,
        generation: Int64,
        fencingToken: String,
        capacityBytes: Int64,
        lifecycleState: StorageVolumeLifecycleState,
        reclaimPolicy: StorageReclaimPolicy,
        accessMode: StorageAccessMode,
        sourceKind: StorageHoldResourceKind? = nil,
        sourceID: String? = nil,
        operationGroupID: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.providerID = providerID
        self.providerVolumeID = providerVolumeID
        self.topologyNodeID = topologyNodeID
        self.generation = generation
        self.fencingToken = fencingToken
        self.capacityBytes = capacityBytes
        self.lifecycleState = lifecycleState
        self.reclaimPolicy = reclaimPolicy
        self.accessMode = accessMode
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StorageStateAttachmentRecord: Codable, Equatable, Sendable {
    public let id: String
    public let volumeID: String
    public let nodeID: String
    public let nodeUUID: String
    public let workloadUUID: String
    public let kind: StorageAttachmentKind
    public let path: String
    public let stagingPath: String?
    public let accessMode: StorageAccessMode
    public let readOnly: Bool
    public let generation: Int64
    public let fencingToken: String
    public let lifecycleState: StorageAttachmentLifecycleState
    public let checkpoint: StorageAttachmentCheckpoint
    public let leaseRenewedAt: String
    public let leaseExpiresAt: String
    public let operationID: String
    public let idempotencyKey: String
    public let providerObservationSHA256: String?
    public let forceDetachAuthorizationSHA256: String?
    public let ambiguousHoldReasonRedacted: String?
    public let operationGroupID: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        volumeID: String,
        nodeID: String,
        nodeUUID: String,
        workloadUUID: String,
        kind: StorageAttachmentKind,
        path: String,
        stagingPath: String?,
        accessMode: StorageAccessMode,
        readOnly: Bool,
        generation: Int64,
        fencingToken: String,
        lifecycleState: StorageAttachmentLifecycleState,
        checkpoint: StorageAttachmentCheckpoint,
        leaseRenewedAt: String,
        leaseExpiresAt: String,
        operationID: String,
        idempotencyKey: String,
        providerObservationSHA256: String?,
        forceDetachAuthorizationSHA256: String?,
        ambiguousHoldReasonRedacted: String?,
        operationGroupID: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.volumeID = volumeID
        self.nodeID = nodeID
        self.nodeUUID = nodeUUID
        self.workloadUUID = workloadUUID
        self.kind = kind
        self.path = path
        self.stagingPath = stagingPath
        self.accessMode = accessMode
        self.readOnly = readOnly
        self.generation = generation
        self.fencingToken = fencingToken
        self.lifecycleState = lifecycleState
        self.checkpoint = checkpoint
        self.leaseRenewedAt = leaseRenewedAt
        self.leaseExpiresAt = leaseExpiresAt
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.providerObservationSHA256 =
            providerObservationSHA256
        self.forceDetachAuthorizationSHA256 =
            forceDetachAuthorizationSHA256
        self.ambiguousHoldReasonRedacted =
            ambiguousHoldReasonRedacted
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StorageStateSnapshotRecord: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let sourceVolumeID: String
    public let providerID: String
    public let providerSnapshotID: String
    public let consistencyClass: StorageSnapshotConsistencyClass
    public let parentContentTreeSHA256: String
    public let contentTreeSHA256: String
    public let lineage: [String]
    public let generation: Int64
    public let fencingToken: String
    public let sizeBytes: Int64
    public let lifecycleState: StorageSnapshotLifecycleState
    public let operationGroupID: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        name: String,
        sourceVolumeID: String,
        providerID: String,
        providerSnapshotID: String,
        consistencyClass: StorageSnapshotConsistencyClass,
        parentContentTreeSHA256: String,
        contentTreeSHA256: String,
        lineage: [String],
        generation: Int64,
        fencingToken: String,
        sizeBytes: Int64,
        lifecycleState: StorageSnapshotLifecycleState,
        operationGroupID: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.sourceVolumeID = sourceVolumeID
        self.providerID = providerID
        self.providerSnapshotID = providerSnapshotID
        self.consistencyClass = consistencyClass
        self.parentContentTreeSHA256 =
            parentContentTreeSHA256
        self.contentTreeSHA256 = contentTreeSHA256
        self.lineage = lineage
        self.generation = generation
        self.fencingToken = fencingToken
        self.sizeBytes = sizeBytes
        self.lifecycleState = lifecycleState
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StorageStateBackupRecord: Codable, Equatable, Sendable {
    public let id: String
    public let volumeID: String
    public let snapshotID: String?
    public let destinationRedacted: String
    public let contentSHA256: String
    public let sizeBytes: Int64
    public let generation: Int64
    public let fencingToken: String
    public let lifecycleState: StorageBackupLifecycleState
    public let operationGroupID: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        volumeID: String,
        snapshotID: String?,
        destinationRedacted: String,
        contentSHA256: String,
        sizeBytes: Int64,
        generation: Int64,
        fencingToken: String,
        lifecycleState: StorageBackupLifecycleState,
        operationGroupID: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.volumeID = volumeID
        self.snapshotID = snapshotID
        self.destinationRedacted = destinationRedacted
        self.contentSHA256 = contentSHA256
        self.sizeBytes = sizeBytes
        self.generation = generation
        self.fencingToken = fencingToken
        self.lifecycleState = lifecycleState
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StorageStateHoldRecord: Codable, Equatable, Sendable {
    public let id: String
    public let resourceKind: StorageHoldResourceKind
    public let resourceID: String
    public let reasonRedacted: String
    public let generation: Int64
    public let fencingToken: String
    public let operationGroupID: String
    public let createdAt: String
    public let expiresAt: String?
    public let releasedAt: String?

    public init(
        id: String,
        resourceKind: StorageHoldResourceKind,
        resourceID: String,
        reasonRedacted: String,
        generation: Int64,
        fencingToken: String,
        operationGroupID: String,
        createdAt: String,
        expiresAt: String?,
        releasedAt: String?
    ) {
        self.id = id
        self.resourceKind = resourceKind
        self.resourceID = resourceID
        self.reasonRedacted = reasonRedacted
        self.generation = generation
        self.fencingToken = fencingToken
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.releasedAt = releasedAt
    }
}

public struct StorageStateOrphanRecord: Codable, Equatable, Sendable {
    public let id: String
    public let providerID: String
    public let resourceKind: StorageOrphanResourceKind
    public let providerResourceIDHash: String
    public let ownershipProofSHA256: String?
    public let generation: Int64
    public let fencingToken: String
    public let lifecycleState: StorageOrphanLifecycleState
    public let operationGroupID: String
    public let discoveredAt: String
    public let resolvedAt: String?

    public init(
        id: String,
        providerID: String,
        resourceKind: StorageOrphanResourceKind,
        providerResourceIDHash: String,
        ownershipProofSHA256: String?,
        generation: Int64,
        fencingToken: String,
        lifecycleState: StorageOrphanLifecycleState,
        operationGroupID: String,
        discoveredAt: String,
        resolvedAt: String?
    ) {
        self.id = id
        self.providerID = providerID
        self.resourceKind = resourceKind
        self.providerResourceIDHash = providerResourceIDHash
        self.ownershipProofSHA256 = ownershipProofSHA256
        self.generation = generation
        self.fencingToken = fencingToken
        self.lifecycleState = lifecycleState
        self.operationGroupID = operationGroupID
        self.discoveredAt = discoveredAt
        self.resolvedAt = resolvedAt
    }
}

public enum StorageQuotaLifecycleState:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case active
    case releasing
    case released
    case faulted
}

public struct StorageStateCapacitySampleRecord:
    Codable,
    Equatable,
    Sendable
{
    public let sample: StorageCapacitySample
    public let pressureLevel: StoragePressureLevel
    public let fencingToken: String
    public let operationGroupID: String
    public let createdAt: String

    public init(
        sample: StorageCapacitySample,
        pressureLevel: StoragePressureLevel,
        fencingToken: String,
        operationGroupID: String,
        createdAt: String
    ) {
        self.sample = sample
        self.pressureLevel = pressureLevel
        self.fencingToken = fencingToken
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
    }
}

public struct StorageStateQuotaRecord:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let resourceID: String
    public let providerID: String
    public let byteLimit: Int64?
    public let inodeLimit: Int64?
    public let enforcementMode: StorageQuotaEnforcementMode
    public let enforcementEvidenceSHA256: String?
    public let generation: Int64
    public let fencingToken: String
    public let lifecycleState: StorageQuotaLifecycleState
    public let retryAttempt: Int
    public let recoveryCheckpoint:
        StorageCapacityRecoveryCheckpoint
    public let operationID: String
    public let idempotencyKey: String
    public let operationGroupID: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        resourceID: String,
        providerID: String,
        byteLimit: Int64?,
        inodeLimit: Int64?,
        enforcementMode: StorageQuotaEnforcementMode,
        enforcementEvidenceSHA256: String?,
        generation: Int64,
        fencingToken: String,
        lifecycleState: StorageQuotaLifecycleState,
        retryAttempt: Int,
        recoveryCheckpoint: StorageCapacityRecoveryCheckpoint,
        operationID: String,
        idempotencyKey: String,
        operationGroupID: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.resourceID = resourceID
        self.providerID = providerID
        self.byteLimit = byteLimit
        self.inodeLimit = inodeLimit
        self.enforcementMode = enforcementMode
        self.enforcementEvidenceSHA256 =
            enforcementEvidenceSHA256
        self.generation = generation
        self.fencingToken = fencingToken
        self.lifecycleState = lifecycleState
        self.retryAttempt = retryAttempt
        self.recoveryCheckpoint = recoveryCheckpoint
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StorageStateCapacityAdmissionRecord:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let sampleID: String
    public let sampleDigestSHA256: String
    public let action: StorageCapacityAction
    public let additionalBytes: Int64
    public let additionalInodes: Int64
    public let writable: Bool
    public let result: StorageCapacityAdmissionResult
    public let maximumAttempts: Int
    public let fencingToken: String
    public let operationGroupID: String
    public let createdAt: String

    public init(
        id: String,
        sampleID: String,
        sampleDigestSHA256: String,
        action: StorageCapacityAction,
        additionalBytes: Int64,
        additionalInodes: Int64,
        writable: Bool,
        result: StorageCapacityAdmissionResult,
        maximumAttempts: Int,
        fencingToken: String,
        operationGroupID: String,
        createdAt: String
    ) {
        self.id = id
        self.sampleID = sampleID
        self.sampleDigestSHA256 = sampleDigestSHA256
        self.action = action
        self.additionalBytes = additionalBytes
        self.additionalInodes = additionalInodes
        self.writable = writable
        self.result = result
        self.maximumAttempts = maximumAttempts
        self.fencingToken = fencingToken
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
    }
}
