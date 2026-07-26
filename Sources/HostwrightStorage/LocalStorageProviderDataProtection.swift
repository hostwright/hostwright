import Foundation

public enum LocalStorageSnapshotAction:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case create
    case verify
    case retain
    case export
    case delete
}

public struct LocalStorageSnapshotPayload:
    Codable,
    Equatable,
    Sendable
{
    public let action: LocalStorageSnapshotAction?
    public let snapshotID: String
    public let name: String?
    public let consistency: StorageSnapshotConsistencyClass?
    public let retainerID: String?
    public let destinationPath: String?
    public let expectedContentTreeSHA256: String?

    public init(
        snapshotID: String,
        name: String,
        consistency: StorageSnapshotConsistencyClass =
            .crashConsistent
    ) {
        action = nil
        self.snapshotID = snapshotID
        self.name = name
        self.consistency = consistency
        retainerID = nil
        destinationPath = nil
        expectedContentTreeSHA256 = nil
    }

    public init(
        action: LocalStorageSnapshotAction,
        snapshotID: String,
        name: String? = nil,
        consistency: StorageSnapshotConsistencyClass? = nil,
        retainerID: String? = nil,
        destinationPath: String? = nil,
        expectedContentTreeSHA256: String? = nil
    ) {
        self.action = action
        self.snapshotID = snapshotID
        self.name = name
        self.consistency = consistency
        self.retainerID = retainerID
        self.destinationPath = destinationPath
        self.expectedContentTreeSHA256 =
            expectedContentTreeSHA256
    }
}

public struct LocalStorageSnapshotResult:
    Codable,
    Equatable,
    Sendable
{
    public let disposition: LocalStorageMutationDisposition
    public let action: LocalStorageSnapshotAction?
    public let snapshotID: String
    public let sourceVolumeID: String
    public let sourceGeneration: Int
    public let sourceFencingToken: String
    public let consistencyClass: StorageSnapshotConsistencyClass
    public let parentContentTreeSHA256: String
    public let contentTreeSHA256: String
    public let lineage: [String]
    public let retainedBy: [String]?
    public let exportedPath: String?
    public let deleted: Bool?

    public init(
        disposition: LocalStorageMutationDisposition,
        snapshotID: String,
        sourceVolumeID: String,
        sourceGeneration: Int,
        sourceFencingToken: String,
        consistencyClass: StorageSnapshotConsistencyClass,
        parentContentTreeSHA256: String,
        contentTreeSHA256: String,
        lineage: [String],
        action: LocalStorageSnapshotAction? = nil,
        retainedBy: [String]? = nil,
        exportedPath: String? = nil,
        deleted: Bool? = nil
    ) {
        self.disposition = disposition
        self.action = action
        self.snapshotID = snapshotID
        self.sourceVolumeID = sourceVolumeID
        self.sourceGeneration = sourceGeneration
        self.sourceFencingToken = sourceFencingToken
        self.consistencyClass = consistencyClass
        self.parentContentTreeSHA256 =
            parentContentTreeSHA256
        self.contentTreeSHA256 = contentTreeSHA256
        self.lineage = lineage
        self.retainedBy = retainedBy?.sorted()
        self.exportedPath = exportedPath
        self.deleted = deleted
    }
}

public enum LocalStorageBackupAction:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case create
    case verify
    case retain
    case delete
}

public struct LocalStorageBackupVolumePayload:
    Codable,
    Equatable,
    Sendable
{
    public let volumeID: String
    public let generation: Int
    public let fencingToken: String

    public init(
        volumeID: String,
        generation: Int,
        fencingToken: String
    ) {
        self.volumeID = volumeID
        self.generation = generation
        self.fencingToken = fencingToken
    }
}

public struct LocalStorageBackupPayload:
    Codable,
    Equatable,
    Sendable
{
    public let action: LocalStorageBackupAction?
    public let backupID: String
    public let name: String?
    public let keyReference: String?
    public let volumes: [LocalStorageBackupVolumePayload]
    public let retainerID: String?
    public let expectedManifestSHA256: String?
    public let remoteDestination:
        StorageBackupRemoteDestination?

    public init(
        backupID: String,
        name: String,
        keyReference: String,
        volumes: [LocalStorageBackupVolumePayload],
        remoteDestination:
            StorageBackupRemoteDestination? = nil
    ) {
        action = nil
        self.backupID = backupID
        self.name = name
        self.keyReference = keyReference
        self.volumes = volumes.sorted {
            $0.volumeID < $1.volumeID
        }
        retainerID = nil
        expectedManifestSHA256 = nil
        self.remoteDestination = remoteDestination
    }

    public init(
        action: LocalStorageBackupAction,
        backupID: String,
        name: String? = nil,
        keyReference: String? = nil,
        volumes: [LocalStorageBackupVolumePayload],
        retainerID: String? = nil,
        expectedManifestSHA256: String? = nil,
        remoteDestination:
            StorageBackupRemoteDestination? = nil
    ) {
        self.action = action
        self.backupID = backupID
        self.name = name
        self.keyReference = keyReference
        self.volumes = volumes.sorted {
            $0.volumeID < $1.volumeID
        }
        self.retainerID = retainerID
        self.expectedManifestSHA256 =
            expectedManifestSHA256
        self.remoteDestination = remoteDestination
    }
}

public struct LocalStorageBackupResult:
    Codable,
    Equatable,
    Sendable
{
    public let disposition: LocalStorageMutationDisposition
    public let action: LocalStorageBackupAction?
    public let backupID: String
    public let manifestSHA256: String
    public let verifiedVolumeIDs: [String]
    public let retainedBy: [String]?
    public let deleted: Bool?

    public init(
        disposition: LocalStorageMutationDisposition,
        backupID: String,
        manifestSHA256: String,
        verifiedVolumeIDs: [String],
        action: LocalStorageBackupAction? = nil,
        retainedBy: [String]? = nil,
        deleted: Bool? = nil
    ) {
        self.disposition = disposition
        self.action = action
        self.backupID = backupID
        self.manifestSHA256 = manifestSHA256
        self.verifiedVolumeIDs = verifiedVolumeIDs.sorted()
        self.retainedBy = retainedBy?.sorted()
        self.deleted = deleted
    }
}

public enum LocalStorageRestoreSource:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case snapshot
    case backup
}

public struct LocalStorageRestoreTargetPayload:
    Codable,
    Equatable,
    Sendable
{
    public let sourceVolumeID: String
    public let targetVolumeID: String
    public let generation: Int
    public let fencingToken: String

    public init(
        sourceVolumeID: String,
        targetVolumeID: String,
        generation: Int,
        fencingToken: String
    ) {
        self.sourceVolumeID = sourceVolumeID
        self.targetVolumeID = targetVolumeID
        self.generation = generation
        self.fencingToken = fencingToken
    }
}

public struct LocalStorageRestorePayload:
    Codable,
    Equatable,
    Sendable
{
    public let source: LocalStorageRestoreSource
    public let sourceID: String
    public let expectedManifestSHA256: String?
    public let keyReference: String?
    public let referenceID: String?
    public let targets: [LocalStorageRestoreTargetPayload]
    public let remoteDestination:
        StorageBackupRemoteDestination?

    public init(
        source: LocalStorageRestoreSource,
        sourceID: String,
        expectedManifestSHA256: String? = nil,
        keyReference: String? = nil,
        referenceID: String? = nil,
        targets: [LocalStorageRestoreTargetPayload],
        remoteDestination:
            StorageBackupRemoteDestination? = nil
    ) {
        self.source = source
        self.sourceID = sourceID
        self.expectedManifestSHA256 =
            expectedManifestSHA256
        self.keyReference = keyReference
        self.referenceID = referenceID
        self.remoteDestination = remoteDestination
        self.targets = targets.sorted {
            if $0.sourceVolumeID != $1.sourceVolumeID {
                return $0.sourceVolumeID < $1.sourceVolumeID
            }
            return $0.targetVolumeID < $1.targetVolumeID
        }
    }
}

public struct LocalStorageRestoreResult:
    Codable,
    Equatable,
    Sendable
{
    public let disposition: LocalStorageMutationDisposition
    public let source: LocalStorageRestoreSource
    public let sourceID: String
    public let restoredTargetVolumeIDs: [String]
    public let verifiedContentSHA256: [String]

    public init(
        disposition: LocalStorageMutationDisposition,
        source: LocalStorageRestoreSource,
        sourceID: String,
        restoredTargetVolumeIDs: [String],
        verifiedContentSHA256: [String]
    ) {
        self.disposition = disposition
        self.source = source
        self.sourceID = sourceID
        self.restoredTargetVolumeIDs =
            restoredTargetVolumeIDs.sorted()
        self.verifiedContentSHA256 =
            verifiedContentSHA256.sorted()
    }
}
