import CryptoKit
import Foundation
import HostwrightSecrets

public enum StorageBackupCompressionCodec: String, Codable, Equatable, Sendable {
    case lzfse
}

public enum StorageBackupEncryptionAlgorithm: String, Codable, Equatable, Sendable {
    case aesGCM256 = "aes-gcm-256"
}

public enum StorageBackupRemoteKind: String, Codable, Equatable, Sendable {
    case s3
}

public struct StorageBackupRemoteDestination: Codable, Equatable, Sendable {
    public let kind: StorageBackupRemoteKind
    public let endpoint: String
    public let bucket: String
    public let region: String
    public let objectPrefix: String
    public let accessKeyIDReference: String
    public let secretAccessKeyReference: String

    public init(
        kind: StorageBackupRemoteKind = .s3,
        endpoint: String,
        bucket: String,
        region: String,
        objectPrefix: String = "",
        accessKeyIDReference: String,
        secretAccessKeyReference: String
    ) throws {
        self.kind = kind
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.objectPrefix = objectPrefix
        self.accessKeyIDReference = accessKeyIDReference
        self.secretAccessKeyReference = secretAccessKeyReference
        _ = try validatedCredentialReferences()
    }

    public var redactedDescription: String {
        let prefix = objectPrefix.isEmpty ? "" : "/\(objectPrefix)"
        return "s3://\(bucket)\(prefix) (\(region), credentials keychain://[REDACTED])"
    }

    public func canonicalSHA256() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func validatedCredentialReferences() throws
        -> (
            accessKeyID: HostwrightSecretReference,
            secretAccessKey: HostwrightSecretReference
        )
    {
        guard kind == .s3,
              let endpointURL = URL(string: endpoint),
              endpointURL.scheme == "https",
              endpointURL.host?.isEmpty == false,
              endpointURL.user == nil,
              endpointURL.password == nil,
              endpointURL.query == nil,
              endpointURL.fragment == nil,
              endpointURL.path.isEmpty ||
                endpointURL.path == "/",
              (3...63).contains(bucket.utf8.count),
              bucket.first.map({
                  $0.isLetter || $0.isNumber
              }) == true,
              bucket.last.map({
                  $0.isLetter || $0.isNumber
              }) == true,
              bucket.allSatisfy({
                  $0.isLowercase || $0.isNumber ||
                    $0 == "." || $0 == "-"
              }),
              !bucket.contains(".."),
              (1...64).contains(region.utf8.count),
              region.allSatisfy({
                  $0.isLetter || $0.isNumber || $0 == "-"
              }),
              objectPrefix.utf8.count <= 512,
              !objectPrefix.hasPrefix("/"),
              !objectPrefix.hasSuffix("/"),
              objectPrefix.split(
                  separator: "/",
                  omittingEmptySubsequences: false
              ).allSatisfy({
                  !$0.isEmpty &&
                    $0 != "." &&
                    $0 != ".." &&
                    $0.allSatisfy {
                        $0.isLetter || $0.isNumber ||
                            $0 == "." || $0 == "_" ||
                            $0 == "-"
                    }
              }) || objectPrefix.isEmpty else {
            throw StorageBackupError.invalidRemoteDestination
        }
        do {
            let accessKeyID = try HostwrightSecretReference.parse(
                accessKeyIDReference
            )
            let secretAccessKey = try HostwrightSecretReference.parse(
                secretAccessKeyReference
            )
            guard accessKeyID.providerKind == .keychain,
                  secretAccessKey.providerKind == .keychain,
                  accessKeyID != secretAccessKey else {
                throw StorageBackupError.invalidRemoteDestination
            }
            return (accessKeyID, secretAccessKey)
        } catch let error as StorageBackupError {
            throw error
        } catch {
            throw StorageBackupError.invalidRemoteDestination
        }
    }
}

public enum StorageBackupCheckpoint: String, Codable, Equatable, Sendable, CaseIterable {
    case createIntentPersisted = "create-intent-persisted"
    case snapshotsComplete = "snapshots-complete"
    case chunksPrepared = "chunks-prepared"
    case setManifestPrepared = "set-manifest-prepared"
    case remoteUploadIntentPersisted = "remote-upload-intent-persisted"
    case remoteUploadComplete = "remote-upload-complete"
    case setPromoted = "set-promoted"
    case restoreIntentPersisted = "restore-intent-persisted"
    case restoreStagesPrepared = "restore-stages-prepared"
    case restoreBackupsPrepared = "restore-backups-prepared"
    case restorePromotionsComplete = "restore-promotions-complete"
}

public struct StorageBackupHooks: Sendable {
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

public struct StorageBackupVolumeRequest: Sendable {
    public let volumeID: String
    public let expectedGeneration: Int?
    public let expectedFencingToken: String?
    public let quiesceHooks: StorageSnapshotQuiesceHooks?

    public init(
        volumeID: String,
        expectedGeneration: Int? = nil,
        expectedFencingToken: String? = nil,
        quiesceHooks: StorageSnapshotQuiesceHooks? = nil
    ) {
        self.volumeID = volumeID
        self.expectedGeneration = expectedGeneration
        self.expectedFencingToken = expectedFencingToken
        self.quiesceHooks = quiesceHooks
    }
}

public struct StorageBackupTargetRequest: Sendable {
    public let sourceVolumeID: String
    public let targetVolumeID: String
    public let expectedGeneration: Int?
    public let expectedFencingToken: String?

    public init(
        sourceVolumeID: String,
        targetVolumeID: String,
        expectedGeneration: Int? = nil,
        expectedFencingToken: String? = nil
    ) {
        self.sourceVolumeID = sourceVolumeID
        self.targetVolumeID = targetVolumeID
        self.expectedGeneration = expectedGeneration
        self.expectedFencingToken = expectedFencingToken
    }
}

public struct StorageBackupEncryptedBlob: Codable, Equatable, Sendable {
    public let blobID: String
    public let plaintextSHA256: String
    public let plaintextBytes: Int64
    public let compressedSHA256: String
    public let compressedBytes: Int64
    public let encryptedSHA256: String
    public let encryptedBytes: Int64
    public let nonceBase64: String
    public let tagBase64: String

    public init(
        blobID: String,
        plaintextSHA256: String,
        plaintextBytes: Int64,
        compressedSHA256: String,
        compressedBytes: Int64,
        encryptedSHA256: String,
        encryptedBytes: Int64,
        nonceBase64: String,
        tagBase64: String
    ) {
        self.blobID = blobID
        self.plaintextSHA256 = plaintextSHA256
        self.plaintextBytes = plaintextBytes
        self.compressedSHA256 = compressedSHA256
        self.compressedBytes = compressedBytes
        self.encryptedSHA256 = encryptedSHA256
        self.encryptedBytes = encryptedBytes
        self.nonceBase64 = nonceBase64
        self.tagBase64 = tagBase64
    }
}

public struct StorageBackupFileEntry: Codable, Equatable, Sendable {
    public let relativePath: String
    public let kind: String
    public let mode: UInt16
    public let contentSHA256: String
    public let sizeBytes: Int64
    public let blob: StorageBackupEncryptedBlob?

    public init(
        relativePath: String,
        kind: String,
        mode: UInt16,
        contentSHA256: String,
        sizeBytes: Int64,
        blob: StorageBackupEncryptedBlob?
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.mode = mode
        self.contentSHA256 = contentSHA256
        self.sizeBytes = sizeBytes
        self.blob = blob
    }
}

public struct StorageBackupChunkRecord: Codable, Equatable, Sendable {
    public let keyVerifier: StorageBackupEncryptedBlob
    public let chunkDigest: String
    public let sourceSnapshotID: String
    public let sourceVolumeID: String
    public let volumeDigest: String
    public let compression: StorageBackupCompressionCodec
    public let encryption: StorageBackupEncryptionAlgorithm
    public let keyReferenceRedacted: String
    public let entries: [StorageBackupFileEntry]
    public let totalPlaintextBytes: Int64

    public init(
        keyVerifier: StorageBackupEncryptedBlob,
        chunkDigest: String,
        sourceSnapshotID: String,
        sourceVolumeID: String,
        volumeDigest: String,
        compression: StorageBackupCompressionCodec,
        encryption: StorageBackupEncryptionAlgorithm,
        keyReferenceRedacted: String,
        entries: [StorageBackupFileEntry],
        totalPlaintextBytes: Int64
    ) {
        self.keyVerifier = keyVerifier
        self.chunkDigest = chunkDigest
        self.sourceSnapshotID = sourceSnapshotID
        self.sourceVolumeID = sourceVolumeID
        self.volumeDigest = volumeDigest
        self.compression = compression
        self.encryption = encryption
        self.keyReferenceRedacted = keyReferenceRedacted
        self.entries = entries.sorted { $0.relativePath < $1.relativePath }
        self.totalPlaintextBytes = totalPlaintextBytes
    }
}

public struct StorageBackupVolumeRecord: Codable, Equatable, Sendable {
    public let source: StorageSnapshotVolumeIdentity
    public let snapshotID: String
    public let consistencyClass: StorageSnapshotConsistencyClass
    public let parentContentTreeSHA256: String
    public let snapshotDigest: String
    public let chunkDigest: String
    public let entryCount: Int
    public let totalPlaintextBytes: Int64
    public let lineage: [String]

    public init(
        source: StorageSnapshotVolumeIdentity,
        snapshotID: String,
        consistencyClass: StorageSnapshotConsistencyClass,
        parentContentTreeSHA256: String,
        snapshotDigest: String,
        chunkDigest: String,
        entryCount: Int,
        totalPlaintextBytes: Int64,
        lineage: [String]
    ) {
        self.source = source
        self.snapshotID = snapshotID
        self.consistencyClass = consistencyClass
        self.parentContentTreeSHA256 =
            parentContentTreeSHA256
        self.snapshotDigest = snapshotDigest
        self.chunkDigest = chunkDigest
        self.entryCount = entryCount
        self.totalPlaintextBytes = totalPlaintextBytes
        self.lineage = lineage.sorted()
    }
}

public struct StorageBackupRecord: Codable, Equatable, Sendable {
    public let backupID: String
    public let name: String
    public let createdAt: Date
    public let keyReferenceRedacted: String
    public let compression: StorageBackupCompressionCodec
    public let encryption: StorageBackupEncryptionAlgorithm
    public let retainedBy: [String]
    public let volumes: [StorageBackupVolumeRecord]
    public let remoteDestination: StorageBackupRemoteDestination?
    public let manifestSHA256: String

    public init(
        backupID: String,
        name: String,
        createdAt: Date,
        keyReferenceRedacted: String,
        compression: StorageBackupCompressionCodec,
        encryption: StorageBackupEncryptionAlgorithm,
        retainedBy: [String],
        volumes: [StorageBackupVolumeRecord],
        remoteDestination: StorageBackupRemoteDestination? = nil
    ) {
        self.backupID = backupID
        self.name = name
        self.createdAt = createdAt
        self.keyReferenceRedacted = keyReferenceRedacted
        self.compression = compression
        self.encryption = encryption
        self.retainedBy = retainedBy.sorted()
        self.volumes = volumes.sorted { $0.source.volumeID < $1.source.volumeID }
        self.remoteDestination = remoteDestination
        self.manifestSHA256 = Self.computeManifestSHA256(
            backupID: backupID,
            name: name,
            createdAt: createdAt,
            keyReferenceRedacted: keyReferenceRedacted,
            compression: compression,
            encryption: encryption,
            retainedBy: retainedBy.sorted(),
            volumes: self.volumes,
            remoteDestination: remoteDestination
        )
    }

    private static func computeManifestSHA256(
        backupID: String,
        name: String,
        createdAt: Date,
        keyReferenceRedacted: String,
        compression: StorageBackupCompressionCodec,
        encryption: StorageBackupEncryptionAlgorithm,
        retainedBy: [String],
        volumes: [StorageBackupVolumeRecord],
        remoteDestination: StorageBackupRemoteDestination?
    ) -> String {
        struct CanonicalManifest: Codable {
            let backupID: String
            let createdAt: Date
            let compression: StorageBackupCompressionCodec
            let encryption: StorageBackupEncryptionAlgorithm
            let keyReferenceRedacted: String
            let name: String
            let remoteDestination: StorageBackupRemoteDestination?
            let retainedBy: [String]
            let volumes: [StorageBackupVolumeRecord]
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let canonical = CanonicalManifest(
            backupID: backupID,
            createdAt: createdAt,
            compression: compression,
            encryption: encryption,
            keyReferenceRedacted: keyReferenceRedacted,
            name: name,
            remoteDestination: remoteDestination,
            retainedBy: retainedBy,
            volumes: volumes
        )
        let data = (try? encoder.encode(canonical)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct StorageBackupVerifyResult: Equatable, Sendable {
    public let backup: StorageBackupRecord
    public let verifiedVolumeIDs: [String]

    public init(
        backup: StorageBackupRecord,
        verifiedVolumeIDs: [String]
    ) {
        self.backup = backup
        self.verifiedVolumeIDs = verifiedVolumeIDs.sorted()
    }
}

public struct StorageBackupRestoreResult: Equatable, Sendable {
    public let backup: StorageBackupRecord
    public let restoredTargetVolumeIDs: [String]

    public init(
        backup: StorageBackupRecord,
        restoredTargetVolumeIDs: [String]
    ) {
        self.backup = backup
        self.restoredTargetVolumeIDs = restoredTargetVolumeIDs.sorted()
    }
}

public enum StorageBackupOperationKind: String, Codable, Equatable, Sendable {
    case create
    case restore
}

public struct StorageBackupOperationTargetState: Codable, Equatable, Sendable {
    public let targetVolumeID: String
    public let targetPath: String
    public let stagePath: String
    public let backupPath: String
    public let sourceVolumeID: String
    public let promoted: Bool

    public init(
        targetVolumeID: String,
        targetPath: String,
        stagePath: String,
        backupPath: String,
        sourceVolumeID: String,
        promoted: Bool
    ) {
        self.targetVolumeID = targetVolumeID
        self.targetPath = targetPath
        self.stagePath = stagePath
        self.backupPath = backupPath
        self.sourceVolumeID = sourceVolumeID
        self.promoted = promoted
    }
}

public struct StorageBackupOperationRecord: Codable, Equatable, Sendable {
    public let operationID: String
    public let kind: StorageBackupOperationKind
    public let backupID: String
    public let checkpoint: String
    public let workingPaths: [String]
    public let targets: [StorageBackupOperationTargetState]
    public let remoteObjectKeys: [String]?

    public init(
        operationID: String,
        kind: StorageBackupOperationKind,
        backupID: String,
        checkpoint: String,
        workingPaths: [String],
        targets: [StorageBackupOperationTargetState],
        remoteObjectKeys: [String]? = nil
    ) {
        self.operationID = operationID
        self.kind = kind
        self.backupID = backupID
        self.checkpoint = checkpoint
        self.workingPaths = workingPaths.sorted()
        self.targets = targets.sorted { $0.targetVolumeID < $1.targetVolumeID }
        self.remoteObjectKeys = remoteObjectKeys?.sorted()
    }
}

public protocol StorageBackupKeyResolver: Sendable {
    func resolveKey(reference: HostwrightSecretReference) throws -> SymmetricKey
}

public struct StorageBackupSecretStoreKeyResolver: StorageBackupKeyResolver {
    private let store: SecretStore

    public init(store: SecretStore) {
        self.store = store
    }

    public func resolveKey(reference: HostwrightSecretReference) throws -> SymmetricKey {
        let raw = try store.readString(reference: reference)
        let material = SHA256.hash(data: Data(raw.utf8))
        return SymmetricKey(data: Data(material))
    }
}

public protocol StorageBackupRemoteTransport: Sendable {
    func uploadObject(objectKey: String, from fileURL: URL, sizeLimitBytes: Int64) throws
    func downloadObject(objectKey: String, to fileURL: URL, sizeLimitBytes: Int64) throws
    func deleteObject(objectKey: String) throws
}

public protocol StorageBackupRemoteTransportFactory: Sendable {
    func makeTransport(
        destination: StorageBackupRemoteDestination,
        secretStore: any SecretStore
    ) throws -> any StorageBackupRemoteTransport
}

public struct StorageBackupS3TransportFactory:
    StorageBackupRemoteTransportFactory,
    Sendable
{
    public init() {}

    public func makeTransport(
        destination: StorageBackupRemoteDestination,
        secretStore: any SecretStore
    ) throws -> any StorageBackupRemoteTransport {
        let references =
            try destination.validatedCredentialReferences()
        let accessKeyID = try secretStore.readString(
            reference: references.accessKeyID
        )
        let secretAccessKey = try secretStore.readString(
            reference: references.secretAccessKey
        )
        guard !accessKeyID.isEmpty,
              accessKeyID.utf8.count <= 256,
              !secretAccessKey.isEmpty,
              secretAccessKey.utf8.count <= 4_096 else {
            throw StorageBackupError.remoteCredentialFailure
        }
        return StorageBackupS3Transport(
            endpoint: URL(string: destination.endpoint)!,
            bucket: destination.bucket,
            region: destination.region,
            objectPrefix: destination.objectPrefix,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey
        )
    }
}

public enum StorageBackupError: Error, Equatable, Sendable {
    case backupNotFound
    case backupAlreadyExists
    case invalidBackupID
    case retained
    case wrongKey
    case integrityMismatch
    case incompleteBackup
    case cancelled
    case ioFailure
    case diskFull
    case wrongParent
    case unmanagedTarget
    case targetValidationFailed
    case restoreRollbackFailure
    case invalidRemoteDestination
    case remoteCredentialFailure
    case remoteObjectNotFound
    case remoteTransportFailure
}
