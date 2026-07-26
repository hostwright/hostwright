import CryptoKit
import Foundation

public enum StorageOrphanStateVolumeLifecycle:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case creating
    case available
    case expanding
    case deleting
    case deleted
    case faulted
}

public enum StorageOrphanStateAttachmentLifecycle:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case attaching
    case attached
    case detaching
    case detached
    case faulted
    case ambiguousHold = "ambiguous-hold"

    public var keepsResourceLive: Bool {
        switch self {
        case .attaching, .attached, .detaching, .ambiguousHold:
            true
        case .detached, .faulted:
            false
        }
    }
}

public enum StorageOrphanStateSnapshotLifecycle:
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

public enum StorageOrphanStateBackupLifecycle:
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

public enum StorageOrphanResourceKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
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

public enum StorageOrphanDiscoveryReason:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case reclaimEligible = "reclaim-eligible"
    case awaitingAge = "awaiting-age"
    case retainPolicy = "retain-policy"
    case liveAttachment = "live-attachment"
    case activeHold = "active-hold"
    case durableOperation = "durable-operation"
    case unmanaged = "unmanaged"
    case ambiguousProvider = "ambiguous-provider"
    case modifiedMetadata = "modified-metadata"
    case unknownAttachment = "unknown-attachment"
}

public enum StorageOrphanRecoveryDisposition:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case none
    case quarantine
    case exactCleanup = "exact-cleanup"
    case safeHold = "safe-hold"
}

public enum StorageOrphanEngineError:
    Error,
    Equatable,
    Sendable
{
    case invalidArgument(String)
    case confirmationMismatch
}

public struct StorageOrphanEngineConfiguration:
    Codable,
    Equatable,
    Sendable
{
    public let quarantineAgeUnixMilliseconds: Int64
    public let reclaimAgeUnixMilliseconds: Int64
    public let maximumTrackedResources: Int
    public let maximumReclaimSelection: Int

    public init(
        quarantineAgeUnixMilliseconds: Int64 = 15 * 60 * 1_000,
        reclaimAgeUnixMilliseconds: Int64 = 60 * 60 * 1_000,
        maximumTrackedResources: Int =
            StorageSemanticLimits.maximumResources,
        maximumReclaimSelection: Int = 256
    ) throws {
        guard quarantineAgeUnixMilliseconds >= 0,
              reclaimAgeUnixMilliseconds >=
                quarantineAgeUnixMilliseconds,
              maximumTrackedResources > 0,
              maximumTrackedResources <=
                StorageSemanticLimits.maximumResources,
              maximumReclaimSelection > 0,
              maximumReclaimSelection <= 256 else {
            throw StorageOrphanEngineError.invalidArgument(
                "Storage orphan configuration exceeds bounded age or selection limits."
            )
        }
        self.quarantineAgeUnixMilliseconds =
            quarantineAgeUnixMilliseconds
        self.reclaimAgeUnixMilliseconds = reclaimAgeUnixMilliseconds
        self.maximumTrackedResources = maximumTrackedResources
        self.maximumReclaimSelection = maximumReclaimSelection
    }
}

public struct StorageOrphanObservedAttachment:
    Codable,
    Equatable,
    Sendable
{
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
    ) throws {
        guard StorageSemanticValidation.validUUID(attachmentID),
              StorageSemanticValidation.validIdentifier(
                consumerID,
                maximumBytes: StorageSemanticLimits.maximumNameBytes
              ),
              generation > 0,
              StorageSemanticValidation.validUUID(fencingToken) else {
            throw StorageOrphanEngineError.invalidArgument(
                "Observed attachment identity is not canonical and bounded."
            )
        }
        self.attachmentID = attachmentID
        self.consumerID = consumerID
        self.generation = generation
        self.fencingToken = fencingToken
        self.readOnly = readOnly
    }
}

public struct StorageOrphanObservedVolume:
    Codable,
    Equatable,
    Sendable
{
    public let providerID: String
    public let providerVolumeID: String
    public let projectID: String
    public let projectGeneration: Int
    public let generation: Int
    public let fencingToken: String
    public let retention: LocalStorageRetentionPolicy
    public let capacityBytes: Int64
    public let attachments: [StorageOrphanObservedAttachment]

    public init(
        providerID: String,
        providerVolumeID: String,
        projectID: String,
        projectGeneration: Int,
        generation: Int,
        fencingToken: String,
        retention: LocalStorageRetentionPolicy,
        capacityBytes: Int64,
        attachments: [StorageOrphanObservedAttachment]
    ) throws {
        guard StorageSemanticValidation.validIdentifier(
                providerID,
                maximumBytes:
                    StorageSemanticLimits.maximumProviderIDBytes
              ),
              StorageSemanticValidation.validUUID(
                providerVolumeID
              ),
              StorageSemanticValidation.validUUID(projectID),
              projectGeneration > 0,
              generation > 0,
              StorageSemanticValidation.validUUID(fencingToken),
              capacityBytes > 0,
              capacityBytes <=
                StorageSemanticLimits.maximumCapacityBytes,
              attachments.count <=
                LocalStorageProviderContract
                    .maximumAttachmentsPerVolume,
              Set(attachments.map(\.attachmentID)).count ==
                attachments.count else {
            throw StorageOrphanEngineError.invalidArgument(
                "Observed provider volume is not canonical, unique, or bounded."
            )
        }
        self.providerID = providerID
        self.providerVolumeID = providerVolumeID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.generation = generation
        self.fencingToken = fencingToken
        self.retention = retention
        self.capacityBytes = capacityBytes
        self.attachments = attachments.sorted {
            $0.attachmentID < $1.attachmentID
        }
    }

    public init(_ observation: LocalStorageVolumeObservation) throws {
        let attachments = try observation.attachments.map {
            try StorageOrphanObservedAttachment(
                attachmentID: $0.attachmentID,
                consumerID: $0.consumerID,
                generation: $0.generation,
                fencingToken: $0.fencingToken,
                readOnly: $0.readOnly
            )
        }
        try self.init(
            providerID: observation.providerID,
            providerVolumeID: observation.volumeID,
            projectID: observation.projectID,
            projectGeneration: observation.projectGeneration,
            generation: observation.generation,
            fencingToken: observation.fencingToken,
            retention: observation.retention,
            capacityBytes: observation.capacityBytes,
            attachments: attachments
        )
    }
}

public struct StorageOrphanObservedInventory:
    Codable,
    Equatable,
    Sendable
{
    public let providerID: String
    public let volumes: [StorageOrphanObservedVolume]
    public let unmanagedEntries: [String]
    public let ambiguousVolumeIDs: [String]

    public init(
        providerID: String,
        volumes: [StorageOrphanObservedVolume],
        unmanagedEntries: [String] = [],
        ambiguousVolumeIDs: [String] = []
    ) throws {
        guard StorageSemanticValidation.validIdentifier(
                providerID,
                maximumBytes:
                    StorageSemanticLimits.maximumProviderIDBytes
              ),
              volumes.count <= StorageSemanticLimits.maximumResources,
              unmanagedEntries.count <=
                StorageSemanticLimits.maximumResources,
              ambiguousVolumeIDs.count <=
                StorageSemanticLimits.maximumResources else {
            throw StorageOrphanEngineError.invalidArgument(
                "Observed storage inventory exceeds bounded provider limits."
            )
        }
        self.providerID = providerID
        self.volumes = volumes.sorted {
            $0.providerVolumeID < $1.providerVolumeID
        }
        self.unmanagedEntries = unmanagedEntries.sorted()
        self.ambiguousVolumeIDs = ambiguousVolumeIDs.sorted()
    }

    public init(_ observation: LocalStorageObservation) throws {
        try self.init(
            providerID: LocalStorageProviderContract.providerID,
            volumes: try observation.volumes.map(StorageOrphanObservedVolume.init),
            unmanagedEntries: observation.unmanagedEntries,
            ambiguousVolumeIDs: observation.ambiguousVolumeIDs
        )
    }
}

public struct StorageOrphanAuthoritativeVolume:
    Codable,
    Equatable,
    Sendable
{
    public let volumeID: String
    public let providerID: String
    public let providerVolumeID: String
    public let projectID: String
    public let lifecycleState: StorageOrphanStateVolumeLifecycle
    public let reclaimPolicy: LocalStorageRetentionPolicy

    public init(
        volumeID: String,
        providerID: String,
        providerVolumeID: String,
        projectID: String,
        lifecycleState: StorageOrphanStateVolumeLifecycle,
        reclaimPolicy: LocalStorageRetentionPolicy
    ) throws {
        guard StorageSemanticValidation.validUUID(volumeID),
              StorageSemanticValidation.validIdentifier(
                providerID,
                maximumBytes:
                    StorageSemanticLimits.maximumProviderIDBytes
              ),
              StorageSemanticValidation.validUUID(
                providerVolumeID
              ),
              StorageSemanticValidation.validUUID(projectID) else {
            throw StorageOrphanEngineError.invalidArgument(
                "Authoritative volume identity is not canonical and bounded."
            )
        }
        self.volumeID = volumeID
        self.providerID = providerID
        self.providerVolumeID = providerVolumeID
        self.projectID = projectID
        self.lifecycleState = lifecycleState
        self.reclaimPolicy = reclaimPolicy
    }
}

public struct StorageOrphanAuthoritativeAttachment:
    Codable,
    Equatable,
    Sendable
{
    public let attachmentID: String
    public let volumeID: String
    public let lifecycleState: StorageOrphanStateAttachmentLifecycle

    public init(
        attachmentID: String,
        volumeID: String,
        lifecycleState: StorageOrphanStateAttachmentLifecycle
    ) throws {
        guard StorageSemanticValidation.validUUID(attachmentID),
              StorageSemanticValidation.validUUID(volumeID) else {
            throw StorageOrphanEngineError.invalidArgument(
                "Authoritative attachment identity is not canonical."
            )
        }
        self.attachmentID = attachmentID
        self.volumeID = volumeID
        self.lifecycleState = lifecycleState
    }
}

public struct StorageOrphanAuthoritativeSnapshot:
    Codable,
    Equatable,
    Sendable
{
    public let snapshotID: String
    public let sourceVolumeID: String
    public let lifecycleState: StorageOrphanStateSnapshotLifecycle

    public init(
        snapshotID: String,
        sourceVolumeID: String,
        lifecycleState: StorageOrphanStateSnapshotLifecycle
    ) throws {
        guard StorageSemanticValidation.validUUID(snapshotID),
              StorageSemanticValidation.validUUID(sourceVolumeID) else {
            throw StorageOrphanEngineError.invalidArgument(
                "Authoritative snapshot identity is not canonical."
            )
        }
        self.snapshotID = snapshotID
        self.sourceVolumeID = sourceVolumeID
        self.lifecycleState = lifecycleState
    }
}

public struct StorageOrphanAuthoritativeBackup:
    Codable,
    Equatable,
    Sendable
{
    public let backupID: String
    public let volumeID: String
    public let snapshotID: String?
    public let lifecycleState: StorageOrphanStateBackupLifecycle

    public init(
        backupID: String,
        volumeID: String,
        snapshotID: String?,
        lifecycleState: StorageOrphanStateBackupLifecycle
    ) throws {
        guard StorageSemanticValidation.validUUID(backupID),
              StorageSemanticValidation.validUUID(volumeID),
              snapshotID == nil ||
                StorageSemanticValidation.validUUID(snapshotID!) else {
            throw StorageOrphanEngineError.invalidArgument(
                "Authoritative backup identity is not canonical."
            )
        }
        self.backupID = backupID
        self.volumeID = volumeID
        self.snapshotID = snapshotID
        self.lifecycleState = lifecycleState
    }
}

public struct StorageOrphanActiveHold:
    Codable,
    Equatable,
    Sendable
{
    public let resourceKind: StorageOrphanResourceKind
    public let resourceID: String

    public init(
        resourceKind: StorageOrphanResourceKind,
        resourceID: String
    ) throws {
        guard StorageSemanticValidation.validUUID(resourceID) else {
            throw StorageOrphanEngineError.invalidArgument(
                "Storage orphan hold requires a canonical resource UUID."
            )
        }
        self.resourceKind = resourceKind
        self.resourceID = resourceID
    }
}

public struct StorageOrphanTrackedRecord:
    Codable,
    Equatable,
    Sendable
{
    public let providerID: String
    public let resourceKind: StorageOrphanResourceKind
    public let providerResourceIDHash: String
    public let ownershipProofSHA256: String?
    public let lifecycleState: StorageOrphanLifecycleState
    public let discoveredAtUnixMilliseconds: Int64
    public let resolvedAtUnixMilliseconds: Int64?

    public init(
        providerID: String,
        resourceKind: StorageOrphanResourceKind,
        providerResourceIDHash: String,
        ownershipProofSHA256: String?,
        lifecycleState: StorageOrphanLifecycleState,
        discoveredAtUnixMilliseconds: Int64,
        resolvedAtUnixMilliseconds: Int64? = nil
    ) throws {
        guard StorageSemanticValidation.validIdentifier(
                providerID,
                maximumBytes:
                    StorageSemanticLimits.maximumProviderIDBytes
              ),
              StorageSemanticValidation.validSHA256(
                providerResourceIDHash
              ),
              ownershipProofSHA256 == nil ||
                StorageSemanticValidation.validSHA256(
                    ownershipProofSHA256!
                ),
              discoveredAtUnixMilliseconds >= 0,
              resolvedAtUnixMilliseconds == nil ||
                resolvedAtUnixMilliseconds! >=
                    discoveredAtUnixMilliseconds else {
            throw StorageOrphanEngineError.invalidArgument(
                "Tracked orphan state is not canonical or bounded."
            )
        }
        self.providerID = providerID
        self.resourceKind = resourceKind
        self.providerResourceIDHash = providerResourceIDHash
        self.ownershipProofSHA256 = ownershipProofSHA256
        self.lifecycleState = lifecycleState
        self.discoveredAtUnixMilliseconds =
            discoveredAtUnixMilliseconds
        self.resolvedAtUnixMilliseconds =
            resolvedAtUnixMilliseconds
    }
}

public struct StorageOrphanAuthoritativeState:
    Codable,
    Equatable,
    Sendable
{
    public let volumes: [StorageOrphanAuthoritativeVolume]
    public let attachments: [StorageOrphanAuthoritativeAttachment]
    public let snapshots: [StorageOrphanAuthoritativeSnapshot]
    public let backups: [StorageOrphanAuthoritativeBackup]
    public let activeHolds: [StorageOrphanActiveHold]
    public let durableOperationResourceIDs: [String]
    public let trackedOrphans: [StorageOrphanTrackedRecord]

    public init(
        volumes: [StorageOrphanAuthoritativeVolume],
        attachments: [StorageOrphanAuthoritativeAttachment] = [],
        snapshots: [StorageOrphanAuthoritativeSnapshot] = [],
        backups: [StorageOrphanAuthoritativeBackup] = [],
        activeHolds: [StorageOrphanActiveHold] = [],
        durableOperationResourceIDs: [String] = [],
        trackedOrphans: [StorageOrphanTrackedRecord] = []
    ) throws {
        guard volumes.count <= StorageSemanticLimits.maximumResources,
              attachments.count <=
                StorageSemanticLimits.maximumResources,
              snapshots.count <=
                StorageSemanticLimits.maximumResources,
              backups.count <=
                StorageSemanticLimits.maximumResources,
              activeHolds.count <=
                StorageSemanticLimits.maximumResources,
              durableOperationResourceIDs.count <=
                StorageSemanticLimits.maximumResources,
              Set(durableOperationResourceIDs).count ==
                durableOperationResourceIDs.count,
              durableOperationResourceIDs.allSatisfy(
                  StorageSemanticValidation.validUUID
              ),
              trackedOrphans.count <=
                StorageSemanticLimits.maximumResources else {
            throw StorageOrphanEngineError.invalidArgument(
                "Authoritative orphan state exceeds bounded resource limits."
            )
        }
        self.volumes = volumes.sorted {
            $0.providerVolumeID < $1.providerVolumeID
        }
        self.attachments = attachments.sorted {
            $0.attachmentID < $1.attachmentID
        }
        self.snapshots = snapshots.sorted {
            $0.snapshotID < $1.snapshotID
        }
        self.backups = backups.sorted {
            $0.backupID < $1.backupID
        }
        self.activeHolds = activeHolds.sorted {
            ($0.resourceKind.rawValue, $0.resourceID) <
                ($1.resourceKind.rawValue, $1.resourceID)
        }
        self.durableOperationResourceIDs =
            durableOperationResourceIDs.sorted()
        self.trackedOrphans = trackedOrphans.sorted {
            (
                $0.providerID,
                $0.resourceKind.rawValue,
                $0.providerResourceIDHash
            ) < (
                $1.providerID,
                $1.resourceKind.rawValue,
                $1.providerResourceIDHash
            )
        }
    }
}

public struct StorageOrphanFinding:
    Codable,
    Equatable,
    Sendable
{
    public let providerID: String
    public let resourceKind: StorageOrphanResourceKind
    public let providerResourceIDHash: String
    public let lifecycleState: StorageOrphanLifecycleState
    public let reason: StorageOrphanDiscoveryReason
    public let discoveredAtUnixMilliseconds: Int64
    public let ageUnixMilliseconds: Int64
    public let ownershipProofSHA256: String?
    public let recoveryDisposition: StorageOrphanRecoveryDisposition
    public let reclaimableBytes: Int64

    public init(
        providerID: String,
        resourceKind: StorageOrphanResourceKind,
        providerResourceIDHash: String,
        lifecycleState: StorageOrphanLifecycleState,
        reason: StorageOrphanDiscoveryReason,
        discoveredAtUnixMilliseconds: Int64,
        ageUnixMilliseconds: Int64,
        ownershipProofSHA256: String?,
        recoveryDisposition: StorageOrphanRecoveryDisposition,
        reclaimableBytes: Int64 = 0
    ) throws {
        guard StorageSemanticValidation.validIdentifier(
                providerID,
                maximumBytes:
                    StorageSemanticLimits.maximumProviderIDBytes
              ),
              StorageSemanticValidation.validSHA256(
                providerResourceIDHash
              ),
              ownershipProofSHA256 == nil ||
                StorageSemanticValidation.validSHA256(
                    ownershipProofSHA256!
                ),
              discoveredAtUnixMilliseconds >= 0,
              ageUnixMilliseconds >= 0,
              reclaimableBytes >= 0 else {
            throw StorageOrphanEngineError.invalidArgument(
                "Storage orphan finding contains invalid identity or accounting."
            )
        }
        self.providerID = providerID
        self.resourceKind = resourceKind
        self.providerResourceIDHash = providerResourceIDHash
        self.lifecycleState = lifecycleState
        self.reason = reason
        self.discoveredAtUnixMilliseconds =
            discoveredAtUnixMilliseconds
        self.ageUnixMilliseconds = ageUnixMilliseconds
        self.ownershipProofSHA256 = ownershipProofSHA256
        self.recoveryDisposition = recoveryDisposition
        self.reclaimableBytes = reclaimableBytes
    }

    public var isEligibleForReclaim: Bool {
        lifecycleState == .discovered &&
            reason == .reclaimEligible &&
            ownershipProofSHA256 != nil
    }
}

public struct StorageOrphanReclaimPlan:
    Codable,
    Equatable,
    Sendable
{
    public let entries: [StorageOrphanFinding]
    public let confirmationSHA256: String
    public let recoveryDisposition: StorageOrphanRecoveryDisposition

    public init(entries: [StorageOrphanFinding]) throws {
        let ordered = entries.sorted {
            (
                $0.providerID,
                $0.resourceKind.rawValue,
                $0.providerResourceIDHash
            ) < (
                $1.providerID,
                $1.resourceKind.rawValue,
                $1.providerResourceIDHash
            )
        }
        guard ordered.allSatisfy(\.isEligibleForReclaim),
              ordered.count <= 256 else {
            throw StorageOrphanEngineError.invalidArgument(
                "Storage orphan reclaim plan requires only exact eligible entries within bounded selection limits."
            )
        }
        self.entries = ordered
        confirmationSHA256 = Self.makeConfirmation(ordered)
        recoveryDisposition = ordered.isEmpty
            ? .none
            : .exactCleanup
    }

    private static func makeConfirmation(
        _ entries: [StorageOrphanFinding]
    ) -> String {
        StorageOrphanHashing.sha256(
            entries.map {
                [
                    "hostwright.storage.orphan-reclaim.v1",
                    $0.providerID,
                    $0.resourceKind.rawValue,
                    $0.providerResourceIDHash,
                    $0.ownershipProofSHA256 ?? "",
                    String($0.reclaimableBytes),
                ].joined(separator: "\n")
            }.joined(separator: "\n---\n")
        )
    }
}

public struct StorageOrphanReclaimResult:
    Codable,
    Equatable,
    Sendable
{
    public let reclaimed: [StorageOrphanFinding]
    public let recoveryDisposition: StorageOrphanRecoveryDisposition

    public init(reclaimed: [StorageOrphanFinding]) {
        self.reclaimed = reclaimed.sorted {
            (
                $0.providerID,
                $0.resourceKind.rawValue,
                $0.providerResourceIDHash
            ) < (
                $1.providerID,
                $1.resourceKind.rawValue,
                $1.providerResourceIDHash
            )
        }
        recoveryDisposition = reclaimed.isEmpty
            ? .none
            : .exactCleanup
    }
}

public struct StorageOrphanReport:
    Codable,
    Equatable,
    Sendable
{
    public let findings: [StorageOrphanFinding]
    public let reclaimPlan: StorageOrphanReclaimPlan

    public init(
        findings: [StorageOrphanFinding],
        reclaimPlan: StorageOrphanReclaimPlan
    ) {
        self.findings = findings.sorted {
            (
                $0.providerID,
                $0.resourceKind.rawValue,
                $0.providerResourceIDHash
            ) < (
                $1.providerID,
                $1.resourceKind.rawValue,
                $1.providerResourceIDHash
            )
        }
        self.reclaimPlan = reclaimPlan
    }
}

enum StorageOrphanHashing {
    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func resourceIDHash(
        providerID: String,
        resourceKind: StorageOrphanResourceKind,
        providerResourceID: String
    ) -> String {
        sha256(
            [
                "hostwright.storage.orphan-resource-id.v1",
                providerID,
                resourceKind.rawValue,
                providerResourceID,
            ].joined(separator: "\n")
        )
    }
}
