import Foundation

public final class StorageSnapshotEngine: @unchecked Sendable {
    private let provider: LocalStorageProvider
    private let snapshotRootURL: URL
    private let fileManager: FileManager
    private let snapshotsDirectoryName = "snapshots"
    private let pendingDirectoryName = ".pending"

    public init(
        provider: LocalStorageProvider,
        snapshotRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        self.provider = provider
        self.snapshotRootURL = snapshotRootURL
        self.fileManager = fileManager
        try StorageSnapshotFilesystem.ensurePrivateRoot(snapshotRootURL)
        try StorageSnapshotFilesystem.makeDirectoryIfMissing(snapshotsRoot)
        try StorageSnapshotFilesystem.makeDirectoryIfMissing(pendingRoot)
        try recoverPendingWork()
    }

    public func list() throws -> [StorageSnapshotRecord] {
        try recoverPendingWork()
        let entries = try fileManager.contentsOfDirectory(
            at: snapshotsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try entries
            .filter { $0.hasDirectoryPath }
            .map { try loadRecord(snapshotDirectory: $0) }
            .sorted { $0.snapshotID < $1.snapshotID }
    }

    public func inspect(snapshotID: String) throws -> StorageSnapshotRecord {
        try validateSnapshotID(snapshotID)
        return try loadRecord(snapshotDirectory: snapshotDirectory(snapshotID))
    }

    public func verify(
        snapshotID: String,
        hooks: StorageSnapshotHooks = StorageSnapshotHooks()
    ) throws -> StorageSnapshotRecord {
        let record = try inspect(snapshotID: snapshotID)
        try verifyIntegrity(record: record, hooks: hooks)
        return record
    }

    public func create(
        snapshotID: String = UUID().uuidString.lowercased(),
        name: String,
        volumeID: String,
        expectedGeneration: Int? = nil,
        expectedFencingToken: String? = nil,
        consistency: StorageSnapshotConsistencyClass,
        quiesceHooks: StorageSnapshotQuiesceHooks? = nil,
        hooks: StorageSnapshotHooks = StorageSnapshotHooks()
    ) throws -> StorageSnapshotRecord {
        try recoverPendingWork()
        try validateSnapshotID(snapshotID)
        if consistency == .applicationConsistent, quiesceHooks == nil {
            throw StorageSnapshotError.applicationConsistencyRequiresHooks
        }
        let existing = snapshotDirectory(snapshotID)
        if fileManager.fileExists(atPath: existing.path) {
            throw StorageSnapshotError.snapshotAlreadyExists
        }

        let volume = try provider.inspect(volumeID: volumeID)
        if let expectedGeneration, volume.generation != expectedGeneration {
            throw StorageSnapshotError.staleGeneration
        }
        if let expectedFencingToken, volume.fencingToken != expectedFencingToken {
            throw StorageSnapshotError.fencingConflict
        }
        try hooks.faultInjector.inject(.createSourceVerified)
        try requireManagedDataRoot(volume.dataPath)

        let pending = pendingRoot.appendingPathComponent("create-\(snapshotID)", isDirectory: true)
        try StorageSnapshotFilesystem.removeIfPresent(pending)
        try StorageSnapshotFilesystem.makeDirectory(pending)
        try hooks.faultInjector.inject(.createPendingPrepared)

        var quiesced = false
        var thawAttempted = false
        do {
            if let quiesceHooks {
                try quiesceHooks.preQuiesce()
                quiesced = true
            }

            let sourceRoot = URL(fileURLWithPath: volume.dataPath, isDirectory: true)
            let copiedDigest = try StorageSnapshotFilesystem.copyTree(
                from: sourceRoot,
                to: pending.appendingPathComponent("data", isDirectory: true),
                hooks: hooks
            )
            try hooks.faultInjector.inject(.createCopyComplete)

            let sourceDigest = try StorageSnapshotFilesystem.hashTree(
                at: sourceRoot,
                hooks: hooks
            )
            guard sourceDigest == copiedDigest else {
                throw StorageSnapshotError.integrityMismatch
            }

            if let quiesceHooks, quiesced {
                thawAttempted = true
                try quiesceHooks.postQuiesce()
                quiesced = false
            }

            let record = StorageSnapshotRecord(
                snapshotID: snapshotID,
                name: name,
                consistencyClass: consistency,
                createdAt: Date(),
                source: StorageSnapshotVolumeIdentity(observation: volume),
                parentContentTreeSHA256: sourceDigest.sha256,
                snapshotContentTreeSHA256: copiedDigest.sha256,
                retainedBy: [],
                references: [],
                lineage: ["volume:\(volume.volumeID)@\(volume.generation)"]
            )
            try StorageSnapshotFilesystem.writeAtomicJSON(
                record,
                to: pending.appendingPathComponent("metadata.json", isDirectory: false)
            )
            try hooks.faultInjector.inject(.createMetadataPrepared)

            try StorageSnapshotFilesystem.atomicMove(pending, to: existing)
            try hooks.faultInjector.inject(.createPromoted)
            return record
        } catch {
            if let quiesceHooks, quiesced,
               !thawAttempted {
                try? quiesceHooks.postQuiesce()
            }
            try? StorageSnapshotFilesystem.removeIfPresent(pending)
            throw error
        }
    }

    public func retain(
        snapshotID: String,
        retainerID: String
    ) throws -> StorageSnapshotRecord {
        var record = try inspect(snapshotID: snapshotID)
        if !record.retainedBy.contains(retainerID) {
            record = StorageSnapshotRecord(
                snapshotID: record.snapshotID,
                name: record.name,
                consistencyClass: record.consistencyClass,
                createdAt: record.createdAt,
                source: record.source,
                parentContentTreeSHA256: record.parentContentTreeSHA256,
                snapshotContentTreeSHA256: record.snapshotContentTreeSHA256,
                retainedBy: record.retainedBy + [retainerID],
                references: record.references,
                lineage: record.lineage
            )
            try persist(record)
        }
        return record
    }

    public func exportSnapshot(
        snapshotID: String,
        to destinationURL: URL,
        hooks: StorageSnapshotHooks = StorageSnapshotHooks()
    ) throws {
        let record = try inspect(snapshotID: snapshotID)
        try StorageSnapshotFilesystem.ensureAbsentPath(destinationURL)
        try StorageSnapshotFilesystem.ensureSafeParent(destinationURL.deletingLastPathComponent())
        try verifyIntegrity(record: record, hooks: hooks)
        try hooks.faultInjector.inject(.exportIntegrityVerified)
        let pending = pendingRoot.appendingPathComponent("export-\(snapshotID)-\(UUID().uuidString)", isDirectory: true)
        try StorageSnapshotFilesystem.removeIfPresent(pending)
        do {
            try StorageSnapshotFilesystem.makeDirectory(pending)
            _ = try StorageSnapshotFilesystem.copyTree(
                from: dataDirectory(record.snapshotID),
                to: pending.appendingPathComponent("data", isDirectory: true),
                hooks: hooks
            )
            try StorageSnapshotFilesystem.writeAtomicJSON(
                record,
                to: pending.appendingPathComponent("metadata.json", isDirectory: false)
            )
            try hooks.faultInjector.inject(.exportCopyComplete)
            try StorageSnapshotFilesystem.atomicMove(pending, to: destinationURL)
        } catch {
            try? StorageSnapshotFilesystem.removeIfPresent(pending)
            throw error
        }
    }

    public func restore(
        snapshotID: String,
        toVolumeID volumeID: String,
        expectedGeneration: Int? = nil,
        expectedFencingToken: String? = nil,
        referenceID: String,
        hooks: StorageSnapshotHooks = StorageSnapshotHooks()
    ) throws -> StorageSnapshotRestoreResult {
        try recoverPendingWork()
        var record = try inspect(snapshotID: snapshotID)
        let volume = try provider.inspect(volumeID: volumeID)
        if let expectedGeneration, volume.generation != expectedGeneration {
            throw StorageSnapshotError.staleGeneration
        }
        if let expectedFencingToken, volume.fencingToken != expectedFencingToken {
            throw StorageSnapshotError.fencingConflict
        }
        try requireManagedDataRoot(volume.dataPath)
        try verifyIntegrity(record: record, hooks: hooks)
        try hooks.faultInjector.inject(.restoreIntegrityVerified)

        let target = URL(fileURLWithPath: volume.dataPath, isDirectory: true)
        let parent = target.deletingLastPathComponent()
        try StorageSnapshotFilesystem.ensureSafeParent(parent)
        if let existingReference = record.references.first(
            where: { $0.referenceID == referenceID }
        ) {
            guard existingReference.volumeID == volumeID,
                  existingReference.targetPath == target.path else {
                throw StorageSnapshotError.snapshotReferenced
            }
        }
        let stage = parent.appendingPathComponent(".restore-\(snapshotID)-\(UUID().uuidString)", isDirectory: true)
        let backup = parent.appendingPathComponent(".backup-\(snapshotID)-\(UUID().uuidString)", isDirectory: true)
        try StorageSnapshotFilesystem.ensureAbsentPath(stage)
        try StorageSnapshotFilesystem.ensureAbsentPath(backup)

        do {
            _ = try StorageSnapshotFilesystem.copyTree(
                from: dataDirectory(snapshotID),
                to: stage,
                hooks: hooks
            )
            try hooks.faultInjector.inject(.restoreStageCopyComplete)

            if fileManager.fileExists(atPath: target.path) {
                try StorageSnapshotFilesystem.atomicMove(target, to: backup)
            }
            try hooks.faultInjector.inject(.restoreBackupPrepared)

            do {
                try StorageSnapshotFilesystem.atomicMove(stage, to: target)
            } catch {
                if fileManager.fileExists(atPath: backup.path) {
                    try? StorageSnapshotFilesystem.atomicMove(backup, to: target)
                }
                throw error
            }
            try hooks.faultInjector.inject(.restorePromoted)
            let restoredDigest =
                try StorageSnapshotFilesystem.hashTree(
                    at: target,
                    hooks: hooks
                )
            guard restoredDigest.sha256 ==
                    record.snapshotContentTreeSHA256 else {
                throw StorageSnapshotError.integrityMismatch
            }
            try StorageSnapshotFilesystem.removeIfPresent(backup)

            let reference = StorageSnapshotReference(
                referenceID: referenceID,
                volumeID: volumeID,
                targetPath: target.path,
                createdAt: Date()
            )
            if !record.references.contains(where: {
                $0.referenceID == referenceID
            }) {
                record = StorageSnapshotRecord(
                    snapshotID: record.snapshotID,
                    name: record.name,
                    consistencyClass: record.consistencyClass,
                    createdAt: record.createdAt,
                    source: record.source,
                    parentContentTreeSHA256: record.parentContentTreeSHA256,
                    snapshotContentTreeSHA256: record.snapshotContentTreeSHA256,
                    retainedBy: record.retainedBy,
                    references: record.references + [reference],
                    lineage: record.lineage
                )
                try persist(record)
            }
            return StorageSnapshotRestoreResult(
                snapshot: record,
                restoredVolumeID: volumeID,
                restoredPath: target.path
            )
        } catch {
            try? StorageSnapshotFilesystem.removeIfPresent(stage)
            if fileManager.fileExists(atPath: backup.path) {
                try? StorageSnapshotFilesystem.removeIfPresent(target)
                try? StorageSnapshotFilesystem.atomicMove(
                    backup,
                    to: target
                )
            }
            throw error
        }
    }

    public func delete(snapshotID: String) throws {
        let record = try inspect(snapshotID: snapshotID)
        guard record.retainedBy.isEmpty else {
            throw StorageSnapshotError.snapshotRetained
        }
        let activeReferences = record.references.filter {
            fileManager.fileExists(atPath: $0.targetPath)
        }
        guard activeReferences.isEmpty else {
            throw StorageSnapshotError.snapshotReferenced
        }
        try StorageSnapshotFilesystem.removeIfPresent(snapshotDirectory(snapshotID))
    }

    private func verifyIntegrity(
        record: StorageSnapshotRecord,
        hooks: StorageSnapshotHooks
    ) throws {
        let digest = try StorageSnapshotFilesystem.hashTree(
            at: dataDirectory(record.snapshotID),
            hooks: hooks
        )
        guard digest.sha256 == record.snapshotContentTreeSHA256,
              digest.sha256 == record.parentContentTreeSHA256 else {
            throw StorageSnapshotError.integrityMismatch
        }
    }

    private func persist(_ record: StorageSnapshotRecord) throws {
        try StorageSnapshotFilesystem.writeAtomicJSON(
            record,
            to: metadataPath(record.snapshotID)
        )
    }

    private func loadRecord(snapshotDirectory: URL) throws -> StorageSnapshotRecord {
        guard fileManager.fileExists(atPath: snapshotDirectory.path) else {
            throw StorageSnapshotError.snapshotNotFound
        }
        return try StorageSnapshotFilesystem.readJSON(
            StorageSnapshotRecord.self,
            from: snapshotDirectory.appendingPathComponent("metadata.json", isDirectory: false)
        )
    }

    private func validateSnapshotID(_ snapshotID: String) throws {
        guard let uuid = UUID(uuidString: snapshotID),
              uuid.uuidString.lowercased() == snapshotID else {
            throw StorageSnapshotError.invalidSnapshotID
        }
    }

    private func requireManagedDataRoot(_ path: String) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let resolved = try StorageSnapshotFilesystem.canonicalFileURL(url)
        guard resolved.path == url.standardizedFileURL.path else {
            throw StorageSnapshotError.unsafePath
        }
        try StorageSnapshotFilesystem.requireDirectory(resolved)
    }

    private func recoverPendingWork() throws {
        try StorageSnapshotFilesystem.makeDirectoryIfMissing(pendingRoot)
        let entries = try fileManager.contentsOfDirectory(
            at: pendingRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            try StorageSnapshotFilesystem.removeIfPresent(entry)
        }
    }

    private var snapshotsRoot: URL {
        snapshotRootURL.appendingPathComponent(snapshotsDirectoryName, isDirectory: true)
    }

    private var pendingRoot: URL {
        snapshotRootURL.appendingPathComponent(pendingDirectoryName, isDirectory: true)
    }

    private func snapshotDirectory(_ snapshotID: String) -> URL {
        snapshotsRoot.appendingPathComponent(snapshotID, isDirectory: true)
    }

    private func metadataPath(_ snapshotID: String) -> URL {
        snapshotDirectory(snapshotID).appendingPathComponent("metadata.json", isDirectory: false)
    }

    private func dataDirectory(_ snapshotID: String) -> URL {
        snapshotDirectory(snapshotID).appendingPathComponent("data", isDirectory: true)
    }
}

private extension StorageSnapshotFilesystem {
    static func makeDirectoryIfMissing(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try makeDirectory(url)
        }
        try requireDirectory(url)
        try setMode(url, mode: 0o700)
    }
}
