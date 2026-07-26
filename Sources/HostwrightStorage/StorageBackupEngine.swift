import CryptoKit
import Foundation
import HostwrightSecrets

public final class StorageBackupEngine: @unchecked Sendable {
    private let provider: LocalStorageProvider
    private let snapshotEngine: StorageSnapshotEngine
    private let backupRootURL: URL
    private let keyResolver: StorageBackupKeyResolver
    private let keyReference: HostwrightSecretReference
    private let remoteDestination:
        StorageBackupRemoteDestination?
    private let remoteTransport: StorageBackupRemoteTransport?
    private let fileManager: FileManager

    public init(
        provider: LocalStorageProvider,
        snapshotEngine: StorageSnapshotEngine,
        backupRootURL: URL,
        keyResolver: StorageBackupKeyResolver,
        keyReference: HostwrightSecretReference,
        remoteDestination:
            StorageBackupRemoteDestination? = nil,
        remoteTransport: StorageBackupRemoteTransport? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.provider = provider
        self.snapshotEngine = snapshotEngine
        self.backupRootURL = backupRootURL
        self.keyResolver = keyResolver
        self.keyReference = keyReference
        self.remoteDestination = remoteDestination
        self.remoteTransport = remoteTransport
        self.fileManager = fileManager
        guard (remoteDestination == nil) ==
                (remoteTransport == nil) else {
            throw StorageBackupError.invalidRemoteDestination
        }
        if let remoteDestination {
            _ = try remoteDestination
                .validatedCredentialReferences()
        }
        try StorageBackupFilesystem.ensureRoot(backupRootURL)
        try recoverOperations()
    }

    public func createBackup(
        backupID: String = UUID().uuidString.lowercased(),
        name: String,
        volumes: [StorageBackupVolumeRequest],
        hooks: StorageBackupHooks = StorageBackupHooks()
    ) throws -> StorageBackupRecord {
        try validateBackupID(backupID)
        try recoverOperations()
        let operationID = UUID().uuidString.lowercased()
        let pendingSet = stagingRoot.appendingPathComponent("set-\(backupID)", isDirectory: true)
        try StorageSnapshotFilesystem.removeIfPresent(pendingSet)
        try FileManager.default.createDirectory(at: pendingSet, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var op = StorageBackupOperationRecord(
            operationID: operationID,
            kind: .create,
            backupID: backupID,
            checkpoint: StorageBackupCheckpoint.createIntentPersisted.rawValue,
            workingPaths: [pendingSet.path],
            targets: []
        )
        try persistOperation(op)

        let key = try keyResolver.resolveKey(reference: keyReference)
        let redacted = keyReference.redactedDescription
        var volumeRecords: [StorageBackupVolumeRecord] = []
        let workingPaths = [pendingSet.path]
        var quiescedHooks: [StorageSnapshotQuiesceHooks] = []
        var thawCompleted = false
        var temporarySnapshotIDs: [String] = []
        do {
            let sortedVolumes = volumes.sorted { $0.volumeID < $1.volumeID }

            for request in sortedVolumes {
                if hooks.isCancelled() {
                    throw StorageBackupError.cancelled
                }
                if let quiesce = request.quiesceHooks {
                    try quiesce.preQuiesce()
                    quiescedHooks.append(quiesce)
                }
            }

            var snapshots:
                [(
                    StorageBackupVolumeRequest,
                    StorageSnapshotRecord,
                    [String: StorageBackupEntryMetadata]
                )] = []
            for request in sortedVolumes {
                if hooks.isCancelled() {
                    throw StorageBackupError.cancelled
                }
                let sourceMetadata =
                    try captureSupportedMetadata(request: request)
                let snapshotID = UUID().uuidString.lowercased()
                let isApplicationConsistent =
                    request.quiesceHooks != nil
                let snapshot = try snapshotEngine.create(
                    snapshotID: snapshotID,
                    name: "backup-\(backupID)-\(request.volumeID.prefix(8))",
                    volumeID: request.volumeID,
                    expectedGeneration: request.expectedGeneration,
                    expectedFencingToken: request.expectedFencingToken,
                    consistency:
                        isApplicationConsistent
                            ? .applicationConsistent
                            : .crashConsistent,
                    quiesceHooks:
                        isApplicationConsistent
                            ? StorageSnapshotQuiesceHooks(
                                preQuiesce: {},
                                postQuiesce: {}
                            )
                            : nil,
                    hooks: StorageSnapshotHooks(isCancelled: hooks.isCancelled)
                )
                temporarySnapshotIDs.append(snapshotID)
                snapshots.append((request, snapshot, sourceMetadata))
            }

            var thawFailure: Error?
            for quiesce in quiescedHooks.reversed() {
                do {
                    try quiesce.postQuiesce()
                } catch {
                    if thawFailure == nil {
                        thawFailure = error
                    }
                }
            }
            thawCompleted = true
            if let thawFailure {
                throw thawFailure
            }

            for (_, snapshot, sourceMetadata) in snapshots {
                if hooks.isCancelled() {
                    throw StorageBackupError.cancelled
                }
                let snapshotDataURL = try snapshotDataDirectory(snapshotID: snapshot.snapshotID)
                let chunkRecord = try ensureChunk(
                    snapshot: snapshot,
                    snapshotDataURL: snapshotDataURL,
                    key: key,
                    sourceMetadata: sourceMetadata,
                    hooks: hooks
                )
                volumeRecords.append(
                    StorageBackupVolumeRecord(
                        source: snapshot.source,
                        snapshotID: snapshot.snapshotID,
                        consistencyClass:
                            snapshot.consistencyClass,
                        parentContentTreeSHA256:
                            snapshot
                                .parentContentTreeSHA256,
                        snapshotDigest: snapshot.snapshotContentTreeSHA256,
                        chunkDigest: chunkRecord.chunkDigest,
                        entryCount: chunkRecord.entries.count,
                        totalPlaintextBytes:
                            chunkRecord.totalPlaintextBytes,
                        lineage: snapshot.lineage
                    )
                )
                try snapshotEngine.delete(
                    snapshotID: snapshot.snapshotID
                )
                temporarySnapshotIDs.removeAll {
                    $0 == snapshot.snapshotID
                }
            }
            op = StorageBackupOperationRecord(
                operationID: operationID,
                kind: .create,
                backupID: backupID,
                checkpoint: StorageBackupCheckpoint.chunksPrepared.rawValue,
                workingPaths: workingPaths,
                targets: []
            )
            try persistOperation(op)
            let record = StorageBackupRecord(
                backupID: backupID,
                name: name,
                createdAt: Date(),
                keyReferenceRedacted: redacted,
                compression: .lzfse,
                encryption: .aesGCM256,
                retainedBy: [],
                volumes: volumeRecords,
                remoteDestination: remoteDestination
            )
            try StorageBackupFilesystem.writeAtomic(record, to: pendingSet.appendingPathComponent("manifest.json", isDirectory: false))
            op = StorageBackupOperationRecord(
                operationID: operationID,
                kind: .create,
                backupID: backupID,
                checkpoint: StorageBackupCheckpoint.setManifestPrepared.rawValue,
                workingPaths: workingPaths,
                targets: []
            )
            try persistOperation(op)
            if let remoteTransport {
                let remoteObjectKeys =
                    try remoteObjectKeys(for: record)
                op = StorageBackupOperationRecord(
                    operationID: operationID,
                    kind: .create,
                    backupID: backupID,
                    checkpoint:
                        StorageBackupCheckpoint
                            .remoteUploadIntentPersisted
                            .rawValue,
                    workingPaths: workingPaths,
                    targets: [],
                    remoteObjectKeys: remoteObjectKeys
                )
                try persistOperation(op)
                try uploadRemoteBackup(
                    record,
                    pendingSet: pendingSet,
                    transport: remoteTransport
                )
                op = StorageBackupOperationRecord(
                    operationID: operationID,
                    kind: .create,
                    backupID: backupID,
                    checkpoint:
                        StorageBackupCheckpoint
                            .remoteUploadComplete.rawValue,
                    workingPaths: workingPaths,
                    targets: [],
                    remoteObjectKeys: remoteObjectKeys
                )
                try persistOperation(op)
            }
            try StorageSnapshotFilesystem.atomicMove(pendingSet, to: setDirectory(backupID))
            op = StorageBackupOperationRecord(
                operationID: operationID,
                kind: .create,
                backupID: backupID,
                checkpoint: StorageBackupCheckpoint.setPromoted.rawValue,
                workingPaths: [],
                targets: [],
                remoteObjectKeys: op.remoteObjectKeys
            )
            try persistOperation(op)
            try clearOperation(operationID: operationID)
            return record
        } catch let error as StorageSnapshotError where error == .ioFailure {
            if !thawCompleted {
                for quiesce in quiescedHooks.reversed() {
                    try? quiesce.postQuiesce()
                }
            }
            for snapshotID in temporarySnapshotIDs {
                try? snapshotEngine.delete(
                    snapshotID: snapshotID
                )
            }
            try cleanupFailedCreate(
                operation: op,
                workingPaths: workingPaths
            )
            if hooks.isCancelled() {
                throw StorageBackupError.cancelled
            }
            throw StorageBackupError.ioFailure
        } catch {
            if !thawCompleted {
                for quiesce in quiescedHooks.reversed() {
                    try? quiesce.postQuiesce()
                }
            }
            for snapshotID in temporarySnapshotIDs {
                try? snapshotEngine.delete(
                    snapshotID: snapshotID
                )
            }
            try cleanupFailedCreate(
                operation: op,
                workingPaths: workingPaths
            )
            throw normalize(error)
        }
    }

    public func list() throws -> [StorageBackupRecord] {
        try recoverOperations()
        let entries = try fileManager.contentsOfDirectory(at: setsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var records: [StorageBackupRecord] = []
        for entry in entries where entry.hasDirectoryPath {
            records.append(try loadBackup(entry))
        }
        return records.sorted { $0.backupID < $1.backupID }
    }

    public func inspect(backupID: String) throws -> StorageBackupRecord {
        do {
            let localSet = setDirectory(backupID)
            if !fileManager.fileExists(atPath: localSet.path),
               let remoteTransport {
                try hydrateRemoteSet(
                    backupID: backupID,
                    transport: remoteTransport
                )
            }
            let backup = try loadBackup(from: localSet)
            guard remoteDestination == nil ||
                    backup.remoteDestination ==
                        remoteDestination else {
                throw StorageBackupError
                    .invalidRemoteDestination
            }
            return backup
        } catch let error as StorageBackupError {
            throw error
        } catch {
            throw StorageBackupError.ioFailure
        }
    }

    public func verify(
        backupID: String
    ) throws -> StorageBackupVerifyResult {
        let backup = try inspect(backupID: backupID)
        let key = try keyResolver.resolveKey(reference: keyReference)
        for volume in backup.volumes {
            let chunk = try loadChunkHydratingIfNeeded(
                digest: volume.chunkDigest,
                backupID: backup.backupID
            )
            try StorageBackupFilesystem.verifyChunk(
                chunkRoot: chunkDirectory(volume.chunkDigest),
                record: chunk,
                key: key
            )
        }
        return StorageBackupVerifyResult(
            backup: backup,
            verifiedVolumeIDs: backup.volumes.map { $0.source.volumeID }
        )
    }

    public func verifyStoredArtifact(
        backupID: String,
        expectedManifestSHA256: String
    ) throws -> StorageBackupRecord {
        let backup = try inspect(backupID: backupID)
        let canonical = StorageBackupRecord(
            backupID: backup.backupID,
            name: backup.name,
            createdAt: backup.createdAt,
            keyReferenceRedacted:
                backup.keyReferenceRedacted,
            compression: backup.compression,
            encryption: backup.encryption,
            retainedBy: backup.retainedBy,
            volumes: backup.volumes,
            remoteDestination: backup.remoteDestination
        )
        guard backup.manifestSHA256 ==
                canonical.manifestSHA256,
              backup.manifestSHA256 ==
                expectedManifestSHA256 else {
            throw StorageBackupError.integrityMismatch
        }
        for volume in backup.volumes {
            let chunk = try loadChunkHydratingIfNeeded(
                digest: volume.chunkDigest,
                backupID: backup.backupID
            )
            guard Set(
                chunk.entries.map(\.relativePath)
            ).count == chunk.entries.count else {
                throw StorageBackupError.integrityMismatch
            }
            guard chunk.chunkDigest ==
                    volume.chunkDigest,
                  chunk.sourceVolumeID ==
                    volume.source.volumeID,
                  chunk.volumeDigest ==
                    volume.snapshotDigest,
                  chunk.entries.count ==
                    volume.entryCount,
                  chunk.totalPlaintextBytes ==
                    volume.totalPlaintextBytes else {
                throw StorageBackupError.integrityMismatch
            }
            try StorageBackupFilesystem
                .verifyEncryptedArtifact(
                    chunkRoot: chunkDirectory(
                        volume.chunkDigest
                    ),
                    record: chunk
                )
        }
        return backup
    }

    public func retain(
        backupID: String,
        retainerID: String
    ) throws -> StorageBackupRecord {
        let backup = try inspect(backupID: backupID)
        if backup.retainedBy.contains(retainerID) {
            return backup
        }
        let updated = StorageBackupRecord(
            backupID: backup.backupID,
            name: backup.name,
            createdAt: backup.createdAt,
            keyReferenceRedacted: backup.keyReferenceRedacted,
            compression: backup.compression,
            encryption: backup.encryption,
            retainedBy: backup.retainedBy + [retainerID],
            volumes: backup.volumes,
            remoteDestination: backup.remoteDestination
        )
        if let remoteTransport {
            guard updated.remoteDestination ==
                    remoteDestination else {
                throw StorageBackupError
                    .invalidRemoteDestination
            }
            let stagedManifest = stagingRoot
                .appendingPathComponent(
                    "retain-\(backupID)-manifest.json",
                    isDirectory: false
                )
            try StorageBackupFilesystem.writeAtomic(
                updated,
                to: stagedManifest
            )
            do {
                try remoteTransport.uploadObject(
                    objectKey:
                        remoteSetManifestKey(backupID),
                    from: stagedManifest,
                    sizeLimitBytes:
                        StorageBackupFilesystem
                            .maximumObjectBytes
                )
            } catch {
                try? StorageSnapshotFilesystem
                    .removeIfPresent(stagedManifest)
                throw StorageBackupError
                    .remoteTransportFailure
            }
            try StorageSnapshotFilesystem.removeIfPresent(
                stagedManifest
            )
        }
        try StorageBackupFilesystem.writeAtomic(updated, to: setDirectory(backupID).appendingPathComponent("manifest.json", isDirectory: false))
        return updated
    }

    public func delete(backupID: String) throws {
        let backup = try inspect(backupID: backupID)
        guard backup.retainedBy.isEmpty else {
            throw StorageBackupError.retained
        }
        if let remoteTransport {
            guard backup.remoteDestination ==
                    remoteDestination else {
                throw StorageBackupError
                    .invalidRemoteDestination
            }
            try deleteRemoteBackup(
                backup,
                transport: remoteTransport
            )
        }
        try StorageSnapshotFilesystem.removeIfPresent(setDirectory(backupID))
        try cleanupUnreferencedChunks()
    }

    func cleanupUnreferencedChunks() throws {
        let setEntries = try fileManager.contentsOfDirectory(
            at: setsRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        )
        var referenced = Set<String>()
        for entry in setEntries {
            let values = try entry.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let uuid = UUID(
                      uuidString: entry.lastPathComponent
                  ),
                  uuid.uuidString.lowercased() ==
                    entry.lastPathComponent else {
                throw StorageBackupError.ioFailure
            }
            let record = try loadBackup(entry)
            guard record.backupID ==
                    entry.lastPathComponent else {
                throw StorageBackupError.integrityMismatch
            }
            for volume in record.volumes {
                guard Self.isCanonicalSHA256(
                    volume.chunkDigest
                ) else {
                    throw StorageBackupError.integrityMismatch
                }
                referenced.insert(volume.chunkDigest)
            }
        }

        let chunkEntries = try fileManager.contentsOfDirectory(
            at: chunksRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        )
        for entry in chunkEntries.sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            let digest = entry.lastPathComponent
            let values = try entry.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  Self.isCanonicalSHA256(digest),
                  !referenced.contains(digest) else {
                continue
            }
            let record = try loadChunk(digest: digest)
            guard record.chunkDigest == digest else {
                throw StorageBackupError.integrityMismatch
            }
            try StorageBackupFilesystem.verifyEncryptedArtifact(
                chunkRoot: entry,
                record: record
            )
            try StorageSnapshotFilesystem.removeIfPresent(entry)
        }
    }

    public func restore(
        backupID: String,
        targets: [StorageBackupTargetRequest],
        hooks: StorageBackupHooks = StorageBackupHooks()
    ) throws -> StorageBackupRestoreResult {
        try recoverOperations()
        let backup = try inspect(backupID: backupID)
        let targetMap = Dictionary(uniqueKeysWithValues: targets.map { ($0.sourceVolumeID, $0) })
        guard backup.volumes.allSatisfy({ targetMap[$0.source.volumeID] != nil }) else {
            throw StorageBackupError.targetValidationFailed
        }
        let key = try keyResolver.resolveKey(reference: keyReference)
        let operationID = UUID().uuidString.lowercased()
        var targetStates: [StorageBackupOperationTargetState] = []

        for volume in backup.volumes.sorted(by: { $0.source.volumeID < $1.source.volumeID }) {
            let request = targetMap[volume.source.volumeID]!
            let targetObservation = try provider.inspect(volumeID: request.targetVolumeID)
            if let expectedGeneration = request.expectedGeneration,
               expectedGeneration != targetObservation.generation {
                throw StorageBackupError.targetValidationFailed
            }
            if let expectedFence = request.expectedFencingToken,
               expectedFence != targetObservation.fencingToken {
                throw StorageBackupError.targetValidationFailed
            }
            let targetURL = URL(fileURLWithPath: targetObservation.dataPath, isDirectory: true)
            let parent = targetURL.deletingLastPathComponent()
            let resolvedParent = try StorageSnapshotFilesystem.canonicalFileURL(parent)
            guard resolvedParent.path == parent.standardizedFileURL.path else {
                throw StorageBackupError.unmanagedTarget
            }
            let stage = stagingRoot.appendingPathComponent("restore-\(backupID)-\(request.targetVolumeID)", isDirectory: true)
            let backupPath = stagingRoot.appendingPathComponent("rollback-\(backupID)-\(request.targetVolumeID)", isDirectory: true)
            targetStates.append(
                StorageBackupOperationTargetState(
                    targetVolumeID: request.targetVolumeID,
                    targetPath: targetURL.path,
                    stagePath: stage.path,
                    backupPath: backupPath.path,
                    sourceVolumeID: volume.source.volumeID,
                    promoted: false
                )
            )
        }

        try persistOperation(
            StorageBackupOperationRecord(
                operationID: operationID,
                kind: .restore,
                backupID: backupID,
                checkpoint: StorageBackupCheckpoint.restoreIntentPersisted.rawValue,
                workingPaths: targetStates.flatMap { [$0.stagePath, $0.backupPath] },
                targets: targetStates
            )
        )

        do {
            for volume in backup.volumes.sorted(by: { $0.source.volumeID < $1.source.volumeID }) {
                if hooks.isCancelled() {
                    throw StorageBackupError.cancelled
                }
                let state = targetStates.first { $0.sourceVolumeID == volume.source.volumeID }!
                let chunkRecord = try loadChunkHydratingIfNeeded(
                    digest: volume.chunkDigest,
                    backupID: backup.backupID
                )
                try StorageBackupFilesystem.verifyChunk(
                    chunkRoot: chunkDirectory(volume.chunkDigest),
                    record: chunkRecord,
                    key: key
                )
                try StorageBackupFilesystem.materializeChunk(
                    chunkRoot: chunkDirectory(volume.chunkDigest),
                    record: chunkRecord,
                    key: key,
                    stageRoot: URL(fileURLWithPath: state.stagePath, isDirectory: true),
                    hooks: hooks
                )
            }
            try hooks.faultInjector.inject(.restoreStageCopyComplete)
            try persistOperation(
                StorageBackupOperationRecord(
                    operationID: operationID,
                    kind: .restore,
                    backupID: backupID,
                    checkpoint: StorageBackupCheckpoint.restoreStagesPrepared.rawValue,
                    workingPaths: targetStates.flatMap { [$0.stagePath, $0.backupPath] },
                    targets: targetStates
                )
            )

            for index in targetStates.indices {
                let target = URL(fileURLWithPath: targetStates[index].targetPath, isDirectory: true)
                let rollback = URL(fileURLWithPath: targetStates[index].backupPath, isDirectory: true)
                if fileManager.fileExists(atPath: rollback.path) {
                    try StorageSnapshotFilesystem.removeIfPresent(rollback)
                }
                if fileManager.fileExists(atPath: target.path) {
                    try StorageSnapshotFilesystem.atomicMove(target, to: rollback)
                }
            }
            try hooks.faultInjector.inject(.restoreBackupPrepared)
            try persistOperation(
                StorageBackupOperationRecord(
                    operationID: operationID,
                    kind: .restore,
                    backupID: backupID,
                    checkpoint: StorageBackupCheckpoint.restoreBackupsPrepared.rawValue,
                    workingPaths: targetStates.flatMap { [$0.stagePath, $0.backupPath] },
                    targets: targetStates
                )
            )

            for index in targetStates.indices {
                let stage = URL(fileURLWithPath: targetStates[index].stagePath, isDirectory: true)
                let target = URL(fileURLWithPath: targetStates[index].targetPath, isDirectory: true)
                try StorageSnapshotFilesystem.atomicMove(stage, to: target)
                targetStates[index] = StorageBackupOperationTargetState(
                    targetVolumeID: targetStates[index].targetVolumeID,
                    targetPath: targetStates[index].targetPath,
                    stagePath: targetStates[index].stagePath,
                    backupPath: targetStates[index].backupPath,
                    sourceVolumeID: targetStates[index].sourceVolumeID,
                    promoted: true
                )
            }
            try hooks.faultInjector.inject(.restorePromoted)
            try persistOperation(
                StorageBackupOperationRecord(
                    operationID: operationID,
                    kind: .restore,
                    backupID: backupID,
                    checkpoint: StorageBackupCheckpoint.restorePromotionsComplete.rawValue,
                    workingPaths: targetStates.flatMap { [$0.stagePath, $0.backupPath] },
                    targets: targetStates
                )
            )
            for state in targetStates {
                try StorageSnapshotFilesystem.removeIfPresent(URL(fileURLWithPath: state.backupPath, isDirectory: true))
            }
            try clearOperation(operationID: operationID)
            return StorageBackupRestoreResult(
                backup: backup,
                restoredTargetVolumeIDs: targetStates.map(\.targetVolumeID)
            )
        } catch {
            do {
                try rollbackTargets(targetStates)
            } catch {
                throw StorageBackupError.restoreRollbackFailure
            }
            try? clearOperation(operationID: operationID)
            throw normalize(error)
        }
    }

    private func ensureChunk(
        snapshot: StorageSnapshotRecord,
        snapshotDataURL: URL,
        key: SymmetricKey,
        sourceMetadata: [String: StorageBackupEntryMetadata],
        hooks: StorageBackupHooks
    ) throws -> StorageBackupChunkRecord {
        let chunkDigest = Self.chunkDigest(
            contentDigest: snapshot.snapshotContentTreeSHA256,
            sourceMetadata: sourceMetadata,
            key: key
        )
        let chunkRoot = chunkDirectory(chunkDigest)
        let chunkManifest = chunkRoot.appendingPathComponent("chunk.json", isDirectory: false)
        if fileManager.fileExists(atPath: chunkManifest.path) {
            let existing = try StorageBackupFilesystem.read(StorageBackupChunkRecord.self, from: chunkManifest)
            if existing.volumeDigest == snapshot.snapshotContentTreeSHA256 {
                return existing
            }
        }

        let dataRoot = snapshotDataURL
        let pendingChunk = stagingRoot.appendingPathComponent("chunk-\(chunkDigest)", isDirectory: true)
        try StorageSnapshotFilesystem.removeIfPresent(pendingChunk)
        try FileManager.default.createDirectory(at: pendingChunk, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let blobRoot = pendingChunk.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pendingManifest = pendingChunk.appendingPathComponent("chunk.json", isDirectory: false)

        let verifierPlaintext = Data("hostwright-backup-key-check:\(chunkDigest)".utf8)
        let verifierCompressed = try StorageBackupFilesystem.compress(verifierPlaintext)
        let verifierSealed = try StorageBackupFilesystem.encrypt(
            plaintext: verifierCompressed,
            key: key
        )
        let verifierBlobID = "key-\(chunkDigest).blob"
        try verifierSealed.ciphertext.write(
            to: blobRoot.appendingPathComponent(verifierBlobID, isDirectory: false),
            options: .atomic
        )
        let keyVerifier = StorageBackupEncryptedBlob(
            blobID: verifierBlobID,
            plaintextSHA256: StorageBackupFilesystem.hashData(verifierPlaintext),
            plaintextBytes: Int64(verifierPlaintext.count),
            compressedSHA256: StorageBackupFilesystem.hashData(verifierCompressed),
            compressedBytes: Int64(verifierCompressed.count),
            encryptedSHA256: StorageBackupFilesystem.hashData(verifierSealed.ciphertext),
            encryptedBytes: Int64(verifierSealed.ciphertext.count),
            nonceBase64: verifierSealed.nonceBase64,
            tagBase64: verifierSealed.tagBase64
        )

        let snapshotEntries =
            try StorageBackupFilesystem.enumerateTree(root: dataRoot)
        guard snapshotEntries.count == sourceMetadata.count,
              snapshotEntries.allSatisfy({
                  sourceMetadata[$0.relativePath]?.kind ==
                    $0.kind &&
                    sourceMetadata[$0.relativePath]?.mode ==
                    $0.mode
              }) else {
            throw StorageBackupError.integrityMismatch
        }

        var entries: [StorageBackupFileEntry] = []
        var totalPlaintextBytes: Int64 = 0
        for (relativePath, kind, _, url) in snapshotEntries {
            if hooks.isCancelled() {
                throw StorageBackupError.cancelled
            }
            guard let mode = sourceMetadata[relativePath]?.mode else {
                throw StorageBackupError.integrityMismatch
            }
            if kind == "dir" {
                entries.append(
                    StorageBackupFileEntry(
                        relativePath: relativePath,
                        kind: kind,
                        mode: mode,
                        contentSHA256: "",
                        sizeBytes: 0,
                        blob: nil
                    )
                )
                continue
            }
            let plaintext = try StorageBackupFilesystem.dataFromFile(url)
            let plaintextSHA = StorageBackupFilesystem.hashData(plaintext)
            let compressed = try StorageBackupFilesystem.compress(plaintext)
            let compressedSHA = StorageBackupFilesystem.hashData(compressed)
            let sealed = try StorageBackupFilesystem.encrypt(plaintext: compressed, key: key)
            let encryptedSHA = StorageBackupFilesystem.hashData(sealed.ciphertext)
            let blobID = plaintextSHA + ".blob"
            try sealed.ciphertext.write(
                to: blobRoot.appendingPathComponent(blobID, isDirectory: false),
                options: .atomic
            )
            entries.append(
                StorageBackupFileEntry(
                    relativePath: relativePath,
                    kind: kind,
                    mode: mode,
                    contentSHA256: plaintextSHA,
                    sizeBytes: Int64(plaintext.count),
                    blob: StorageBackupEncryptedBlob(
                        blobID: blobID,
                        plaintextSHA256: plaintextSHA,
                        plaintextBytes: Int64(plaintext.count),
                        compressedSHA256: compressedSHA,
                        compressedBytes: Int64(compressed.count),
                        encryptedSHA256: encryptedSHA,
                        encryptedBytes: Int64(sealed.ciphertext.count),
                        nonceBase64: sealed.nonceBase64,
                        tagBase64: sealed.tagBase64
                    )
                )
            )
            totalPlaintextBytes += Int64(plaintext.count)
        }

        var digestHasher = SHA256()
        digestHasher.update(
            data: StorageBackupFilesystem
                .snapshotTreeDigestLine(
                    kind: "dir",
                    relativePath: "",
                    mode: 0o700,
                    contentSHA256: ""
                )
        )
        for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            digestHasher.update(
                data: StorageBackupFilesystem
                    .snapshotTreeDigestLine(
                        kind: entry.kind,
                        relativePath:
                            entry.relativePath,
                        mode: entry.mode,
                        contentSHA256:
                            entry.contentSHA256
                    )
            )
        }
        let volumeDigest = digestHasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard volumeDigest == snapshot.snapshotContentTreeSHA256 else {
            throw StorageBackupError.integrityMismatch
        }
        let record = StorageBackupChunkRecord(
            keyVerifier: keyVerifier,
            chunkDigest: chunkDigest,
            sourceSnapshotID: snapshot.snapshotID,
            sourceVolumeID: snapshot.source.volumeID,
            volumeDigest: volumeDigest,
            compression: .lzfse,
            encryption: .aesGCM256,
            keyReferenceRedacted: keyReference.redactedDescription,
            entries: entries,
            totalPlaintextBytes: totalPlaintextBytes
        )
        try StorageBackupFilesystem.writeAtomic(record, to: pendingManifest)
        if fileManager.fileExists(atPath: chunkRoot.path) {
            try StorageSnapshotFilesystem.removeIfPresent(chunkRoot)
        }
        try StorageSnapshotFilesystem.atomicMove(pendingChunk, to: chunkRoot)
        return record
    }

    private func uploadRemoteBackup(
        _ backup: StorageBackupRecord,
        pendingSet: URL,
        transport: StorageBackupRemoteTransport
    ) throws {
        do {
            for volume in backup.volumes {
                let chunk = try loadChunk(
                    digest: volume.chunkDigest
                )
                let chunkRoot = chunkDirectory(
                    volume.chunkDigest
                )
                try transport.uploadObject(
                    objectKey: remoteChunkManifestKey(
                        backupID: backup.backupID,
                        digest: volume.chunkDigest
                    ),
                    from: chunkRoot.appendingPathComponent(
                        "chunk.json",
                        isDirectory: false
                    ),
                    sizeLimitBytes:
                        StorageBackupFilesystem
                            .maximumObjectBytes
                )
                for blobID in remoteBlobIDs(for: chunk) {
                    try transport.uploadObject(
                        objectKey: remoteChunkBlobKey(
                            backupID: backup.backupID,
                            digest: volume.chunkDigest,
                            blobID: blobID
                        ),
                        from: chunkRoot
                            .appendingPathComponent(
                                "blobs",
                                isDirectory: true
                            )
                            .appendingPathComponent(
                                blobID,
                                isDirectory: false
                            ),
                        sizeLimitBytes:
                            StorageBackupFilesystem
                                .maximumObjectBytes
                    )
                }
            }
            try transport.uploadObject(
                objectKey: remoteSetManifestKey(
                    backup.backupID
                ),
                from: pendingSet.appendingPathComponent(
                    "manifest.json",
                    isDirectory: false
                ),
                sizeLimitBytes:
                    StorageBackupFilesystem.maximumObjectBytes
            )
        } catch {
            throw StorageBackupError.remoteTransportFailure
        }
    }

    private func deleteRemoteBackup(
        _ backup: StorageBackupRecord,
        transport: StorageBackupRemoteTransport
    ) throws {
        do {
            for key in try remoteObjectKeys(for: backup)
            where key != remoteSetManifestKey(backup.backupID) {
                try transport.deleteObject(objectKey: key)
            }
            try transport.deleteObject(
                objectKey:
                    remoteSetManifestKey(backup.backupID)
            )
        } catch {
            throw StorageBackupError.remoteTransportFailure
        }
    }

    private func hydrateRemoteSet(
        backupID: String,
        transport: StorageBackupRemoteTransport
    ) throws {
        guard let uuid = UUID(uuidString: backupID),
              uuid.uuidString.lowercased() == backupID else {
            throw StorageBackupError.invalidBackupID
        }
        let stage = stagingRoot.appendingPathComponent(
            "remote-set-\(backupID)",
            isDirectory: true
        )
        try StorageSnapshotFilesystem.removeIfPresent(stage)
        try fileManager.createDirectory(
            at: stage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let manifest = stage.appendingPathComponent(
                "manifest.json",
                isDirectory: false
            )
            try transport.downloadObject(
                objectKey: remoteSetManifestKey(backupID),
                to: manifest,
                sizeLimitBytes:
                    StorageBackupFilesystem.maximumObjectBytes
            )
            let record = try loadBackup(stage)
            try validateRemoteRecord(
                record,
                expectedBackupID: backupID
            )
            try StorageSnapshotFilesystem.atomicMove(
                stage,
                to: setDirectory(backupID)
            )
        } catch {
            try? StorageSnapshotFilesystem.removeIfPresent(stage)
            if error as? StorageBackupError ==
                .remoteObjectNotFound {
                throw StorageBackupError.backupNotFound
            }
            throw normalizeRemote(error)
        }
    }

    private func loadChunkHydratingIfNeeded(
        digest: String,
        backupID: String
    ) throws -> StorageBackupChunkRecord {
        if fileManager.fileExists(
            atPath: chunkDirectory(digest).path
        ) {
            return try loadChunk(digest: digest)
        }
        guard Self.isCanonicalSHA256(digest),
              let remoteTransport else {
            throw StorageBackupError.incompleteBackup
        }
        let stage = stagingRoot.appendingPathComponent(
            "remote-chunk-\(backupID)-\(digest)",
            isDirectory: true
        )
        try StorageSnapshotFilesystem.removeIfPresent(stage)
        try fileManager.createDirectory(
            at: stage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let blobRoot = stage.appendingPathComponent(
            "blobs",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: blobRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let manifest = stage.appendingPathComponent(
                "chunk.json",
                isDirectory: false
            )
            try remoteTransport.downloadObject(
                objectKey: remoteChunkManifestKey(
                    backupID: backupID,
                    digest: digest
                ),
                to: manifest,
                sizeLimitBytes:
                    StorageBackupFilesystem.maximumObjectBytes
            )
            let record = try StorageBackupFilesystem.read(
                StorageBackupChunkRecord.self,
                from: manifest
            )
            guard record.chunkDigest == digest else {
                throw StorageBackupError.integrityMismatch
            }
            for blobID in remoteBlobIDs(for: record) {
                try remoteTransport.downloadObject(
                    objectKey: remoteChunkBlobKey(
                        backupID: backupID,
                        digest: digest,
                        blobID: blobID
                    ),
                    to: blobRoot.appendingPathComponent(
                        blobID,
                        isDirectory: false
                    ),
                    sizeLimitBytes:
                        StorageBackupFilesystem
                            .maximumObjectBytes
                )
            }
            try StorageBackupFilesystem
                .verifyEncryptedArtifact(
                    chunkRoot: stage,
                    record: record
                )
            try StorageSnapshotFilesystem.atomicMove(
                stage,
                to: chunkDirectory(digest)
            )
            return record
        } catch {
            try? StorageSnapshotFilesystem.removeIfPresent(stage)
            throw normalizeRemote(error)
        }
    }

    private func validateRemoteRecord(
        _ record: StorageBackupRecord,
        expectedBackupID: String
    ) throws {
        let canonical = StorageBackupRecord(
            backupID: record.backupID,
            name: record.name,
            createdAt: record.createdAt,
            keyReferenceRedacted:
                record.keyReferenceRedacted,
            compression: record.compression,
            encryption: record.encryption,
            retainedBy: record.retainedBy,
            volumes: record.volumes,
            remoteDestination: record.remoteDestination
        )
        guard record.backupID == expectedBackupID,
              record.remoteDestination == remoteDestination,
              record.manifestSHA256 ==
                canonical.manifestSHA256 else {
            throw StorageBackupError.integrityMismatch
        }
    }

    private func remoteObjectKeys(
        for backup: StorageBackupRecord
    ) throws -> [String] {
        var keys: [String] = []
        for volume in backup.volumes {
            let record = try loadChunkHydratingIfNeeded(
                digest: volume.chunkDigest,
                backupID: backup.backupID
            )
            keys.append(
                remoteChunkManifestKey(
                    backupID: backup.backupID,
                    digest: volume.chunkDigest
                )
            )
            keys.append(
                contentsOf: remoteBlobIDs(for: record).map {
                    remoteChunkBlobKey(
                        backupID: backup.backupID,
                        digest: volume.chunkDigest,
                        blobID: $0
                    )
                }
            )
        }
        keys.append(
            remoteSetManifestKey(backup.backupID)
        )
        return Array(Set(keys)).sorted()
    }

    private func remoteBlobIDs(
        for record: StorageBackupChunkRecord
    ) -> [String] {
        Array(
            Set(
                [record.keyVerifier.blobID] +
                    record.entries.compactMap {
                        $0.blob?.blobID
                    }
            )
        ).sorted()
    }

    private func remoteSetManifestKey(
        _ backupID: String
    ) -> String {
        "sets/\(backupID)/manifest.json"
    }

    private func remoteChunkManifestKey(
        backupID: String,
        digest: String
    ) -> String {
        "sets/\(backupID)/chunks/\(digest)/chunk.json"
    }

    private func remoteChunkBlobKey(
        backupID: String,
        digest: String,
        blobID: String
    ) -> String {
        "sets/\(backupID)/chunks/\(digest)/blobs/\(blobID)"
    }

    private func cleanupFailedCreate(
        operation: StorageBackupOperationRecord,
        workingPaths: [String]
    ) throws {
        if let keys = operation.remoteObjectKeys,
           !keys.isEmpty {
            guard let remoteTransport else {
                throw StorageBackupError
                    .remoteTransportFailure
            }
            do {
                for key in keys.sorted(by: {
                    let leftManifest =
                        $0.hasSuffix("/manifest.json")
                    let rightManifest =
                        $1.hasSuffix("/manifest.json")
                    if leftManifest != rightManifest {
                        return leftManifest
                    }
                    return $0 < $1
                }) {
                    try remoteTransport.deleteObject(
                        objectKey: key
                    )
                }
            } catch {
                throw StorageBackupError
                    .remoteTransportFailure
            }
        }
        try cleanupWorkingPaths(workingPaths)
        try clearOperation(operationID: operation.operationID)
    }

    private func rollbackTargets(_ states: [StorageBackupOperationTargetState]) throws {
        for state in states.reversed() {
            let target = URL(fileURLWithPath: state.targetPath, isDirectory: true)
            let backup = URL(fileURLWithPath: state.backupPath, isDirectory: true)
            let stage = URL(fileURLWithPath: state.stagePath, isDirectory: true)
            if fileManager.fileExists(atPath: stage.path) {
                try StorageSnapshotFilesystem.removeIfPresent(stage)
            }
            if fileManager.fileExists(atPath: backup.path) {
                if fileManager.fileExists(atPath: target.path) {
                    try StorageSnapshotFilesystem.removeIfPresent(target)
                }
                try StorageSnapshotFilesystem.atomicMove(backup, to: target)
            }
        }
    }

    private func captureSupportedMetadata(
        request: StorageBackupVolumeRequest
    ) throws -> [String: StorageBackupEntryMetadata] {
        let observation = try provider.inspect(volumeID: request.volumeID)
        if let expectedGeneration = request.expectedGeneration,
           expectedGeneration != observation.generation {
            throw StorageBackupError.targetValidationFailed
        }
        if let expectedFence = request.expectedFencingToken,
           expectedFence != observation.fencingToken {
            throw StorageBackupError.targetValidationFailed
        }
        let entries = try StorageBackupFilesystem.enumerateTree(
            root: URL(
                fileURLWithPath: observation.dataPath,
                isDirectory: true
            )
        )
        return Dictionary(
            uniqueKeysWithValues: entries.map {
                (
                    $0.relativePath,
                    StorageBackupEntryMetadata(
                        kind: $0.kind,
                        mode: $0.mode
                    )
                )
            }
        )
    }

    private static func chunkDigest(
        contentDigest: String,
        sourceMetadata: [String: StorageBackupEntryMetadata],
        key: SymmetricKey
    ) -> String {
        var input = Data(
            "hostwright-backup-chunk-v2\n\(contentDigest)\n".utf8
        )
        for relativePath in sourceMetadata.keys.sorted() {
            guard let metadata = sourceMetadata[relativePath] else {
                continue
            }
            input.append(
                Data(
                    [
                        metadata.kind,
                        relativePath,
                        String(metadata.mode, radix: 8),
                    ]
                    .joined(separator: "\t")
                    .appending("\n")
                    .utf8
                )
            )
        }
        return HMAC<SHA256>.authenticationCode(
            for: input,
            using: key
        )
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func recoverOperations() throws {
        let operationFiles = try fileManager.contentsOfDirectory(at: operationsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for file in operationFiles {
            let operation = try StorageBackupFilesystem.read(StorageBackupOperationRecord.self, from: file)
            switch operation.kind {
            case .create:
                if !fileManager.fileExists(
                    atPath:
                        setDirectory(operation.backupID)
                            .path
                ),
                let keys = operation.remoteObjectKeys,
                !keys.isEmpty {
                    guard let remoteTransport else {
                        throw StorageBackupError
                            .remoteTransportFailure
                    }
                    do {
                        for key in keys.sorted(by: {
                            let leftManifest =
                                $0.hasSuffix(
                                    "/manifest.json"
                                )
                            let rightManifest =
                                $1.hasSuffix(
                                    "/manifest.json"
                                )
                            if leftManifest !=
                                rightManifest {
                                return leftManifest
                            }
                            return $0 < $1
                        }) {
                            try remoteTransport
                                .deleteObject(
                                    objectKey: key
                                )
                        }
                    } catch {
                        throw StorageBackupError
                            .remoteTransportFailure
                    }
                }
                try cleanupWorkingPaths(operation.workingPaths)
            case .restore:
                try rollbackTargets(operation.targets)
            }
            try StorageSnapshotFilesystem.removeIfPresent(file)
        }
    }

    private func cleanupWorkingPaths(_ paths: [String]) throws {
        for path in Set(paths) {
            try? StorageSnapshotFilesystem.removeIfPresent(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    private func persistOperation(_ record: StorageBackupOperationRecord) throws {
        try StorageBackupFilesystem.writeAtomic(
            record,
            to: operationsRoot.appendingPathComponent("\(record.operationID).json", isDirectory: false)
        )
    }

    private func clearOperation(operationID: String) throws {
        try StorageSnapshotFilesystem.removeIfPresent(
            operationsRoot.appendingPathComponent("\(operationID).json", isDirectory: false)
        )
    }

    private func loadBackup(_ url: URL) throws -> StorageBackupRecord {
        try StorageBackupFilesystem.read(
            StorageBackupRecord.self,
            from: url.appendingPathComponent("manifest.json", isDirectory: false)
        )
    }

    private func loadBackup(from url: URL) throws -> StorageBackupRecord {
        guard fileManager.fileExists(atPath: url.path) else {
            throw StorageBackupError.backupNotFound
        }
        return try loadBackup(url)
    }

    private func loadChunk(digest: String) throws -> StorageBackupChunkRecord {
        let url = chunkDirectory(digest).appendingPathComponent("chunk.json", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StorageBackupError.incompleteBackup
        }
        do {
            return try StorageBackupFilesystem.read(StorageBackupChunkRecord.self, from: url)
        } catch let error as StorageBackupError {
            throw error
        } catch {
            throw StorageBackupError.ioFailure
        }
    }

    private func validateBackupID(_ backupID: String) throws {
        guard let uuid = UUID(uuidString: backupID),
              uuid.uuidString.lowercased() == backupID else {
            throw StorageBackupError.invalidBackupID
        }
        if fileManager.fileExists(atPath: setDirectory(backupID).path) {
            throw StorageBackupError.backupAlreadyExists
        }
    }

    private static func isCanonicalSHA256(
        _ value: String
    ) -> Bool {
        value.utf8.count == 64 &&
            value.allSatisfy {
                ("0"..."9").contains($0) ||
                    ("a"..."f").contains($0)
            }
    }

    private func normalize(_ error: Error) -> StorageBackupError {
        if let backup = error as? StorageBackupError {
            return backup
        }
        if let snapshot = error as? StorageSnapshotError {
            switch snapshot {
            case .cancelled:
                return .cancelled
            case .staleGeneration, .fencingConflict:
                return .targetValidationFailed
            case .wrongParent:
                return .wrongParent
            case .integrityMismatch:
                return .integrityMismatch
            default:
                return .ioFailure
            }
        }
        if let cocoa = error as NSError?, cocoa.domain == NSCocoaErrorDomain, cocoa.code == NSFileWriteOutOfSpaceError {
            return .diskFull
        }
        return .ioFailure
    }

    private func normalizeRemote(
        _ error: Error
    ) -> StorageBackupError {
        if let backup = error as? StorageBackupError,
           backup != .ioFailure {
            return backup
        }
        return .remoteTransportFailure
    }

    private var setsRoot: URL {
        backupRootURL.appendingPathComponent("sets", isDirectory: true)
    }

    private var chunksRoot: URL {
        backupRootURL.appendingPathComponent("chunks", isDirectory: true)
    }

    private var operationsRoot: URL {
        backupRootURL.appendingPathComponent(".operations", isDirectory: true)
    }

    private var stagingRoot: URL {
        backupRootURL.appendingPathComponent(".staging", isDirectory: true)
    }

    private func snapshotDataDirectory(snapshotID: String) throws -> URL {
        let mirror = Mirror(reflecting: snapshotEngine)
        guard let snapshotRootURL = mirror.children.first(where: { $0.label == "snapshotRootURL" })?.value as? URL else {
            throw StorageBackupError.ioFailure
        }
        let dataURL = snapshotRootURL
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(snapshotID, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
        try StorageSnapshotFilesystem.requireDirectory(dataURL)
        return dataURL
    }

    private func setDirectory(_ backupID: String) -> URL {
        setsRoot.appendingPathComponent(backupID, isDirectory: true)
    }

    private func chunkDirectory(_ digest: String) -> URL {
        chunksRoot.appendingPathComponent(digest, isDirectory: true)
    }
}

private struct StorageBackupEntryMetadata: Sendable {
    let kind: String
    let mode: UInt16
}

public final class StorageBackupS3Transport:
    NSObject,
    StorageBackupRemoteTransport
{
    private let endpoint: URL
    private let bucket: String
    private let region: String
    private let objectPrefix: String
    private let accessKeyID: String
    private let secretAccessKey: String
    private let redirectDelegate:
        StorageBackupRedirectRejectingDelegate
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        endpoint: URL,
        bucket: String,
        region: String,
        objectPrefix: String = "",
        accessKeyID: String,
        secretAccessKey: String,
        timeout: TimeInterval = 30,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.objectPrefix = objectPrefix
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.timeout = timeout
        sessionConfiguration.timeoutIntervalForRequest = timeout
        sessionConfiguration.timeoutIntervalForResource = timeout
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        let redirectDelegate =
            StorageBackupRedirectRejectingDelegate()
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        super.init()
    }

    public func uploadObject(objectKey: String, from fileURL: URL, sizeLimitBytes: Int64) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = Int64(truncating: (attributes[.size] as? NSNumber) ?? 0)
        guard size <= sizeLimitBytes else {
            throw StorageBackupError.remoteTransportFailure
        }
        let payload = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let request = try signedRequest(
            method: "PUT",
            objectKey: objectKey,
            payload: payload
        )
        _ = try perform(request: request, body: payload)
    }

    public func downloadObject(objectKey: String, to fileURL: URL, sizeLimitBytes: Int64) throws {
        let request = try signedRequest(
            method: "GET",
            objectKey: objectKey,
            payload: nil
        )
        let data = try perform(request: request, body: nil)
        guard Int64(data.count) <= sizeLimitBytes else {
            throw StorageBackupError.remoteTransportFailure
        }
        try data.write(to: fileURL, options: .atomic)
    }

    public func deleteObject(objectKey: String) throws {
        let request = try signedRequest(
            method: "DELETE",
            objectKey: objectKey,
            payload: nil
        )
        _ = try perform(request: request, body: nil)
    }

    private func signedRequest(
        method: String,
        objectKey: String,
        payload: Data?
    ) throws -> URLRequest {
        guard endpoint.scheme == "https" else {
            throw StorageBackupError.remoteTransportFailure
        }
        guard validObjectKey(objectKey) else {
            throw StorageBackupError.remoteTransportFailure
        }
        let prefixedObjectKey = objectPrefix.isEmpty
            ? objectKey
            : "\(objectPrefix)/\(objectKey)"
        let objectPath = "/\(bucket)/\(prefixedObjectKey)"
        guard let url = URL(string: objectPath, relativeTo: endpoint) else {
            throw StorageBackupError.remoteTransportFailure
        }
        let timestamp = Self.iso8601Timestamp(Date())
        let dateStamp = String(timestamp.prefix(8))
        let payloadHash = payload.map(StorageBackupFilesystem.hashData)
            ?? "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(endpoint.host, forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        let canonicalHeaders = "host:\(endpoint.host ?? "")\n" +
            "x-amz-content-sha256:\(payloadHash)\n" +
            "x-amz-date:\(timestamp)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [
            method,
            url.path,
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")
        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            credentialScope,
            StorageBackupFilesystem.hashData(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")
        let signingKey = Self.signingKey(
            secret: secretAccessKey,
            date: dateStamp,
            region: region,
            service: "s3"
        )
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: signingKey
        ).map { String(format: "%02x", $0) }.joined()
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    private func validObjectKey(_ value: String) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= 1_024 &&
            !value.hasPrefix("/") &&
            !value.hasSuffix("/") &&
            value.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).allSatisfy {
                !$0.isEmpty &&
                    $0 != "." &&
                    $0 != ".." &&
                    $0.allSatisfy {
                        $0.isLetter || $0.isNumber ||
                            $0 == "." || $0 == "_" ||
                            $0 == "-"
                    }
            }
    }

    private func perform(
        request: URLRequest,
        body: Data?
    ) throws -> Data {
        var request = request
        request.httpBody = body
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedResultBox<Result<Data, Error>?>(value: nil)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.set(.failure(error))
                return
            }
            guard let response =
                    response as? HTTPURLResponse else {
                box.set(.failure(StorageBackupError.remoteTransportFailure))
                return
            }
            if response.statusCode == 404 {
                box.set(
                    .failure(
                        StorageBackupError
                            .remoteObjectNotFound
                    )
                )
                return
            }
            guard (200..<300).contains(
                response.statusCode
            ) else {
                box.set(.failure(StorageBackupError.remoteTransportFailure))
                return
            }
            box.set(.success(data ?? Data()))
        }
        task.resume()
        let completionGrace = min(
            max(timeout * 0.1, 0.05),
            1
        )
        guard semaphore.wait(
            timeout: .now() + timeout +
                completionGrace
        ) == .success else {
            task.cancel()
            throw StorageBackupError
                .remoteTransportFailure
        }
        switch box.get() {
        case .success(let data):
            return data
        default:
            throw StorageBackupError.remoteTransportFailure
        }
    }

    private static func iso8601Timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func signingKey(
        secret: String,
        date: String,
        region: String,
        service: String
    ) -> SymmetricKey {
        let kDate = hmac(key: Data(("AWS4" + secret).utf8), message: date)
        let kRegion = hmac(key: kDate, message: region)
        let kService = hmac(key: kRegion, message: service)
        let kSigning = hmac(key: kService, message: "aws4_request")
        return SymmetricKey(data: kSigning)
    }

    private static func hmac(key: Data, message: String) -> Data {
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        )
        return Data(signature)
    }
}

private final class StorageBackupRedirectRejectingDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response:
            HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler:
            @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class LockedResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(value: T) {
        self.value = value
    }

    func set(_ value: T) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
