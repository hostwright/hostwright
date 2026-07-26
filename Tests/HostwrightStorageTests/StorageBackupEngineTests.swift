import CryptoKit
import Foundation
import HostwrightSecrets
import XCTest
@testable import HostwrightStorage

final class StorageBackupEngineTests: XCTestCase {
    func testCreateListInspectVerifyAndDeleteBackupSet() async throws {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 64 * 1_024 * 1_024
        )
        let snapshotEngine = try StorageSnapshotEngine(
            provider: provider,
            snapshotRootURL: harness.containerRoot.appendingPathComponent("snapshots", isDirectory: true)
        )
        let identityA = LocalStorageTestIdentity()
        let identityB = LocalStorageTestIdentity()
        let volumeA = try await createVolume(provider: provider, identity: identityA, key: "backup-a")
        let volumeB = try await createVolume(provider: provider, identity: identityB, key: "backup-b")
        try writeTree(root: URL(fileURLWithPath: volumeA.dataPath, isDirectory: true), files: ["one.txt": "alpha"])
        try writeTree(root: URL(fileURLWithPath: volumeB.dataPath, isDirectory: true), files: ["two.txt": "beta"])

        let secret = try HostwrightSecretReference(service: "hostwright-tests", account: "backup")
        let engine = try StorageBackupEngine(
            provider: provider,
            snapshotEngine: snapshotEngine,
            backupRootURL: harness.containerRoot.appendingPathComponent("backups", isDirectory: true),
            keyResolver: InlineBackupKeyResolver(secret: "super-secret"),
            keyReference: secret
        )

        let backupID = UUID().uuidString.lowercased()
        let backup = try engine.createBackup(
            backupID: backupID,
            name: "nightly",
            volumes: [
                StorageBackupVolumeRequest(
                    volumeID: volumeB.volumeID,
                    expectedGeneration: volumeB.generation,
                    expectedFencingToken: volumeB.fencingToken
                ),
                StorageBackupVolumeRequest(
                    volumeID: volumeA.volumeID,
                    expectedGeneration: volumeA.generation,
                    expectedFencingToken: volumeA.fencingToken
                )
            ]
        )

        XCTAssertEqual(try engine.list().map(\.backupID), [backupID])
        let inspected = try engine.inspect(backupID: backupID)
        XCTAssertEqual(inspected.backupID, backup.backupID)
        XCTAssertEqual(inspected.manifestSHA256, backup.manifestSHA256)
        XCTAssertEqual(try engine.verify(backupID: backupID).verifiedVolumeIDs.sorted(), [volumeA.volumeID, volumeB.volumeID].sorted())
        XCTAssertFalse(
            try String(
                decoding: Data(
                    contentsOf: harness.containerRoot
                        .appendingPathComponent("backups", isDirectory: true)
                        .appendingPathComponent("sets", isDirectory: true)
                        .appendingPathComponent(backupID, isDirectory: true)
                        .appendingPathComponent("manifest.json", isDirectory: false)
                ),
                as: UTF8.self
            ).contains("super-secret")
        )
        let secondBackup = try engine.createBackup(
            backupID: UUID().uuidString.lowercased(),
            name: "nightly-shared-chunks",
            volumes: [
                StorageBackupVolumeRequest(
                    volumeID: volumeA.volumeID,
                    expectedGeneration: volumeA.generation,
                    expectedFencingToken:
                        volumeA.fencingToken
                ),
                StorageBackupVolumeRequest(
                    volumeID: volumeB.volumeID,
                    expectedGeneration: volumeB.generation,
                    expectedFencingToken:
                        volumeB.fencingToken
                ),
            ]
        )
        XCTAssertEqual(
            Set(backup.volumes.map(\.chunkDigest)),
            Set(secondBackup.volumes.map(\.chunkDigest))
        )
        XCTAssertEqual(
            try engine.verify(
                backupID: backup.backupID
            ).verifiedVolumeIDs.sorted(),
            [volumeA.volumeID, volumeB.volumeID].sorted()
        )
        XCTAssertEqual(
            try engine.verify(
                backupID: secondBackup.backupID
            ).verifiedVolumeIDs.sorted(),
            [volumeA.volumeID, volumeB.volumeID].sorted()
        )
        try engine.delete(backupID: backupID)
        XCTAssertThrowsError(try engine.inspect(backupID: backupID)) { error in
            XCTAssertEqual(error as? StorageBackupError, .backupNotFound)
        }
        let chunksRoot = harness.containerRoot
            .appendingPathComponent(
                "backups/chunks",
                isDirectory: true
            )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: chunksRoot,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).sorted(),
            secondBackup.volumes.map(\.chunkDigest).sorted()
        )
        try engine.delete(backupID: secondBackup.backupID)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: chunksRoot,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testMultiVolumeApplicationConsistentBackupFreezesAllThenThawsInReverse()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 64 * 1_024 * 1_024
        )
        let snapshotEngine = try StorageSnapshotEngine(
            provider: provider,
            snapshotRootURL: harness.containerRoot
                .appendingPathComponent(
                    "snapshots",
                    isDirectory: true
                )
        )
        let volumeA = try await createVolume(
            provider: provider,
            identity: LocalStorageTestIdentity(),
            key: "backup-application-a"
        )
        let volumeB = try await createVolume(
            provider: provider,
            identity: LocalStorageTestIdentity(),
            key: "backup-application-b"
        )
        let roots = [
            volumeA.volumeID: URL(
                fileURLWithPath: volumeA.dataPath,
                isDirectory: true
            ),
            volumeB.volumeID: URL(
                fileURLWithPath: volumeB.dataPath,
                isDirectory: true
            ),
        ]
        try writeTree(
            root: roots[volumeA.volumeID]!,
            files: ["primary.db": "alpha"]
        )
        try writeTree(
            root: roots[volumeB.volumeID]!,
            files: ["replica.db": "beta"]
        )
        let expectedDigests = try Dictionary(
            uniqueKeysWithValues: roots.map {
                ($0.key, try treeDigest($0.value))
            }
        )
        let events = BackupHookEvents()
        let observations = [volumeA, volumeB].sorted {
            $0.volumeID < $1.volumeID
        }
        let requests = observations.map { volume in
            StorageBackupVolumeRequest(
                volumeID: volume.volumeID,
                expectedGeneration: volume.generation,
                expectedFencingToken: volume.fencingToken,
                quiesceHooks: StorageSnapshotQuiesceHooks(
                    preQuiesce: {
                        events.append("freeze:\(volume.volumeID)")
                    },
                    postQuiesce: {
                        events.append("thaw:\(volume.volumeID)")
                    }
                )
            )
        }
        let secret = try HostwrightSecretReference(
            service: "hostwright-tests",
            account: "multi-volume-application"
        )
        let engine = try StorageBackupEngine(
            provider: provider,
            snapshotEngine: snapshotEngine,
            backupRootURL: harness.containerRoot
                .appendingPathComponent(
                    "backups",
                    isDirectory: true
                ),
            keyResolver: InlineBackupKeyResolver(
                secret: "application-key"
            ),
            keyReference: secret
        )
        let backup = try engine.createBackup(
            backupID: UUID().uuidString.lowercased(),
            name: "application-set",
            volumes: requests
        )

        XCTAssertEqual(
            events.values,
            observations.map { "freeze:\($0.volumeID)" } +
                observations.reversed().map {
                    "thaw:\($0.volumeID)"
                }
        )
        XCTAssertEqual(backup.volumes.count, 2)
        for record in backup.volumes {
            XCTAssertEqual(
                record.snapshotDigest,
                expectedDigests[record.source.volumeID]
            )
            XCTAssertEqual(
                record.chunkDigest.utf8.count,
                64
            )
            XCTAssertEqual(record.snapshotDigest.utf8.count, 64)
        }
        XCTAssertEqual(
            try engine.verify(
                backupID: backup.backupID
            ).verifiedVolumeIDs,
            observations.map(\.volumeID)
        )
    }

    func testMultiVolumeRestoreToNewTargetsPreservesExactDataAndModes()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 64 * 1_024 * 1_024
        )
        let snapshotEngine = try StorageSnapshotEngine(
            provider: provider,
            snapshotRootURL: harness.containerRoot
                .appendingPathComponent("snapshots", isDirectory: true)
        )
        let sourceA = try await createVolume(
            provider: provider,
            identity: LocalStorageTestIdentity(),
            key: "restore-set-source-a"
        )
        let sourceB = try await createVolume(
            provider: provider,
            identity: LocalStorageTestIdentity(),
            key: "restore-set-source-b"
        )
        let targetA = try await createVolume(
            provider: provider,
            identity: LocalStorageTestIdentity(),
            key: "restore-set-target-a"
        )
        let targetB = try await createVolume(
            provider: provider,
            identity: LocalStorageTestIdentity(),
            key: "restore-set-target-b"
        )
        let sourceRootA = URL(
            fileURLWithPath: sourceA.dataPath,
            isDirectory: true
        )
        let sourceRootB = URL(
            fileURLWithPath: sourceB.dataPath,
            isDirectory: true
        )
        let targetRootA = URL(
            fileURLWithPath: targetA.dataPath,
            isDirectory: true
        )
        let targetRootB = URL(
            fileURLWithPath: targetB.dataPath,
            isDirectory: true
        )
        try writeTree(
            root: sourceRootA,
            files: [
                ".env": "production",
                ".settings/token.txt": "hidden-token",
                "database/primary.db": "alpha",
                "manifest.txt": "primary",
            ]
        )
        try writeTree(
            root: sourceRootB,
            files: ["queue/pending.log": "beta"]
        )
        try setMode(
            sourceRootA.appendingPathComponent(
                ".env",
                isDirectory: false
            ),
            0o600
        )
        try setMode(
            sourceRootA.appendingPathComponent(
                ".settings",
                isDirectory: true
            ),
            0o750
        )
        try setMode(
            sourceRootA.appendingPathComponent(
                ".settings/token.txt",
                isDirectory: false
            ),
            0o640
        )
        try setMode(
            sourceRootA.appendingPathComponent(
                "database",
                isDirectory: true
            ),
            0o750
        )
        try setMode(
            sourceRootA.appendingPathComponent(
                "database/primary.db",
                isDirectory: false
            ),
            0o640
        )
        try setMode(
            sourceRootA.appendingPathComponent(
                "manifest.txt",
                isDirectory: false
            ),
            0o600
        )
        try setMode(
            sourceRootB.appendingPathComponent(
                "queue",
                isDirectory: true
            ),
            0o710
        )
        try setMode(
            sourceRootB.appendingPathComponent(
                "queue/pending.log",
                isDirectory: false
            ),
            0o644
        )
        let expectedDigestA = try treeDigest(sourceRootA)
        let expectedDigestB = try treeDigest(sourceRootB)

        let secret = try HostwrightSecretReference(
            service: "hostwright-tests",
            account: "restore-set"
        )
        let engine = try StorageBackupEngine(
            provider: provider,
            snapshotEngine: snapshotEngine,
            backupRootURL: harness.containerRoot
                .appendingPathComponent("backups", isDirectory: true),
            keyResolver: InlineBackupKeyResolver(secret: "restore-set-key"),
            keyReference: secret
        )
        let backup = try engine.createBackup(
            backupID: UUID().uuidString.lowercased(),
            name: "restore-set",
            volumes: [
                StorageBackupVolumeRequest(
                    volumeID: sourceB.volumeID,
                    expectedGeneration: sourceB.generation,
                    expectedFencingToken: sourceB.fencingToken
                ),
                StorageBackupVolumeRequest(
                    volumeID: sourceA.volumeID,
                    expectedGeneration: sourceA.generation,
                    expectedFencingToken: sourceA.fencingToken
                ),
            ]
        )

        XCTAssertEqual(
            try engine.verify(
                backupID: backup.backupID
            ).verifiedVolumeIDs,
            [sourceA.volumeID, sourceB.volumeID].sorted()
        )
        let restored = try engine.restore(
            backupID: backup.backupID,
            targets: [
                StorageBackupTargetRequest(
                    sourceVolumeID: sourceB.volumeID,
                    targetVolumeID: targetB.volumeID,
                    expectedGeneration: targetB.generation,
                    expectedFencingToken: targetB.fencingToken
                ),
                StorageBackupTargetRequest(
                    sourceVolumeID: sourceA.volumeID,
                    targetVolumeID: targetA.volumeID,
                    expectedGeneration: targetA.generation,
                    expectedFencingToken: targetA.fencingToken
                ),
            ]
        )

        XCTAssertEqual(
            restored.restoredTargetVolumeIDs,
            [targetA.volumeID, targetB.volumeID].sorted()
        )
        XCTAssertEqual(try treeDigest(targetRootA), expectedDigestA)
        XCTAssertEqual(try treeDigest(targetRootB), expectedDigestB)
        XCTAssertEqual(
            String(
                decoding: try Data(
                    contentsOf: targetRootA.appendingPathComponent(
                        ".env",
                        isDirectory: false
                    )
                ),
                as: UTF8.self
            ),
            "production"
        )
        XCTAssertEqual(
            String(
                decoding: try Data(
                    contentsOf: targetRootA.appendingPathComponent(
                        ".settings/token.txt",
                        isDirectory: false
                    )
                ),
                as: UTF8.self
            ),
            "hidden-token"
        )
        XCTAssertEqual(
            try mode(
                targetRootA.appendingPathComponent(
                    ".env",
                    isDirectory: false
                )
            ),
            0o600
        )
        XCTAssertEqual(
            try mode(
                targetRootA.appendingPathComponent(
                    ".settings",
                    isDirectory: true
                )
            ),
            0o750
        )
        XCTAssertEqual(
            try mode(
                targetRootA.appendingPathComponent(
                    ".settings/token.txt",
                    isDirectory: false
                )
            ),
            0o640
        )
        XCTAssertEqual(
            try mode(
                targetRootA.appendingPathComponent(
                    "database",
                    isDirectory: true
                )
            ),
            0o750
        )
        XCTAssertEqual(
            try mode(
                targetRootA.appendingPathComponent(
                    "database/primary.db",
                    isDirectory: false
                )
            ),
            0o640
        )
        XCTAssertEqual(
            try mode(
                targetRootA.appendingPathComponent(
                    "manifest.txt",
                    isDirectory: false
                )
            ),
            0o600
        )
        XCTAssertEqual(
            try mode(
                targetRootB.appendingPathComponent(
                    "queue",
                    isDirectory: true
                )
            ),
            0o710
        )
        XCTAssertEqual(
            try mode(
                targetRootB.appendingPathComponent(
                    "queue/pending.log",
                    isDirectory: false
                )
            ),
            0o644
        )
        try assertBackupWorkingDirectoriesAreEmpty(harness)
    }

    func testDiskFullBeforePromotionPreservesEveryActiveTargetAndCleansStages()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 64 * 1_024 * 1_024
        )
        let snapshotEngine = try StorageSnapshotEngine(
            provider: provider,
            snapshotRootURL: harness.containerRoot
                .appendingPathComponent("snapshots", isDirectory: true)
        )
        let sourceA = try await createVolume(
            provider: provider,
            identity: LocalStorageTestIdentity(),
            key: "disk-full-source-a"
        )
        let sourceB = try await createVolume(
            provider: provider,
            identity: LocalStorageTestIdentity(),
            key: "disk-full-source-b"
        )
        let targetA = try await createVolume(
            provider: provider,
            identity: LocalStorageTestIdentity(),
            key: "disk-full-target-a"
        )
        let targetB = try await createVolume(
            provider: provider,
            identity: LocalStorageTestIdentity(),
            key: "disk-full-target-b"
        )
        let sourceRootA = URL(
            fileURLWithPath: sourceA.dataPath,
            isDirectory: true
        )
        let sourceRootB = URL(
            fileURLWithPath: sourceB.dataPath,
            isDirectory: true
        )
        let targetRootA = URL(
            fileURLWithPath: targetA.dataPath,
            isDirectory: true
        )
        let targetRootB = URL(
            fileURLWithPath: targetB.dataPath,
            isDirectory: true
        )
        try writeTree(root: sourceRootA, files: ["new-a.txt": "new-a"])
        try writeTree(root: sourceRootB, files: ["new-b.txt": "new-b"])
        try writeTree(
            root: targetRootA,
            files: ["active/a.txt": "active-a"]
        )
        try writeTree(
            root: targetRootB,
            files: ["active/b.txt": "active-b"]
        )
        try setMode(
            targetRootA.appendingPathComponent(
                "active/a.txt",
                isDirectory: false
            ),
            0o640
        )
        try setMode(
            targetRootB.appendingPathComponent(
                "active/b.txt",
                isDirectory: false
            ),
            0o600
        )
        let activeDigestA = try treeDigest(targetRootA)
        let activeDigestB = try treeDigest(targetRootB)

        let secret = try HostwrightSecretReference(
            service: "hostwright-tests",
            account: "disk-full"
        )
        let engine = try StorageBackupEngine(
            provider: provider,
            snapshotEngine: snapshotEngine,
            backupRootURL: harness.containerRoot
                .appendingPathComponent("backups", isDirectory: true),
            keyResolver: InlineBackupKeyResolver(secret: "disk-full-key"),
            keyReference: secret
        )
        let backup = try engine.createBackup(
            backupID: UUID().uuidString.lowercased(),
            name: "disk-full",
            volumes: [
                StorageBackupVolumeRequest(
                    volumeID: sourceA.volumeID,
                    expectedGeneration: sourceA.generation,
                    expectedFencingToken: sourceA.fencingToken
                ),
                StorageBackupVolumeRequest(
                    volumeID: sourceB.volumeID,
                    expectedGeneration: sourceB.generation,
                    expectedFencingToken: sourceB.fencingToken
                ),
            ]
        )
        let fault = OneShotBackupFault(
            point: .restoreStageCopyComplete,
            error: .diskFull
        )

        XCTAssertThrowsError(
            try engine.restore(
                backupID: backup.backupID,
                targets: [
                    StorageBackupTargetRequest(
                        sourceVolumeID: sourceA.volumeID,
                        targetVolumeID: targetA.volumeID,
                        expectedGeneration: targetA.generation,
                        expectedFencingToken: targetA.fencingToken
                    ),
                    StorageBackupTargetRequest(
                        sourceVolumeID: sourceB.volumeID,
                        targetVolumeID: targetB.volumeID,
                        expectedGeneration: targetB.generation,
                        expectedFencingToken: targetB.fencingToken
                    ),
                ],
                hooks: StorageBackupHooks(
                    faultInjector: fault.injector
                )
            )
        ) { error in
            XCTAssertEqual(error as? StorageBackupError, .diskFull)
        }
        XCTAssertEqual(try treeDigest(targetRootA), activeDigestA)
        XCTAssertEqual(try treeDigest(targetRootB), activeDigestB)
        XCTAssertEqual(
            try mode(
                targetRootA.appendingPathComponent(
                    "active/a.txt",
                    isDirectory: false
                )
            ),
            0o640
        )
        XCTAssertEqual(
            try mode(
                targetRootB.appendingPathComponent(
                    "active/b.txt",
                    isDirectory: false
                )
            ),
            0o600
        )
        try assertBackupWorkingDirectoriesAreEmpty(harness)
    }

    func testTamperedChunkWrongKeyRetentionAndCancellation() async throws {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 64 * 1_024 * 1_024
        )
        let snapshotEngine = try StorageSnapshotEngine(
            provider: provider,
            snapshotRootURL: harness.containerRoot.appendingPathComponent("snapshots", isDirectory: true)
        )
        let identity = LocalStorageTestIdentity()
        let volume = try await createVolume(provider: provider, identity: identity, key: "backup-c")
        try writeTree(root: URL(fileURLWithPath: volume.dataPath, isDirectory: true), files: ["a.txt": "data"])
        let secret = try HostwrightSecretReference(service: "hostwright-tests", account: "tamper")
        let engine = try StorageBackupEngine(
            provider: provider,
            snapshotEngine: snapshotEngine,
            backupRootURL: harness.containerRoot.appendingPathComponent("backups", isDirectory: true),
            keyResolver: InlineBackupKeyResolver(secret: "correct-key"),
            keyReference: secret
        )
        let backupID = UUID().uuidString.lowercased()
        let backup = try engine.createBackup(
            backupID: backupID,
            name: "tamper",
            volumes: [
                StorageBackupVolumeRequest(
                    volumeID: volume.volumeID,
                    expectedGeneration: volume.generation,
                    expectedFencingToken: volume.fencingToken
                )
            ]
        )
        let pristineWrongKeyEngine = try StorageBackupEngine(
            provider: provider,
            snapshotEngine: snapshotEngine,
            backupRootURL: harness.containerRoot.appendingPathComponent("backups", isDirectory: true),
            keyResolver: InlineBackupKeyResolver(secret: "wrong-key"),
            keyReference: secret
        )
        XCTAssertThrowsError(try pristineWrongKeyEngine.verify(backupID: backupID)) { error in
            XCTAssertEqual(error as? StorageBackupError, .wrongKey)
        }

        let retained = try engine.retain(backupID: backupID, retainerID: "hold")
        XCTAssertFalse(retained.retainedBy.isEmpty)
        XCTAssertThrowsError(try engine.delete(backupID: backupID)) { error in
            XCTAssertEqual(error as? StorageBackupError, .retained)
        }

        let chunkDir = harness.containerRoot
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("chunks", isDirectory: true)
            .appendingPathComponent(backup.volumes[0].chunkDigest, isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
        let tamperBlob = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: chunkDir, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first { !$0.lastPathComponent.hasPrefix("key-") }
        )
        try Data("tampered".utf8).write(to: tamperBlob, options: .atomic)
        XCTAssertThrowsError(try engine.verify(backupID: backupID)) { error in
            XCTAssertEqual(error as? StorageBackupError, .integrityMismatch)
        }

        XCTAssertThrowsError(
            try engine.createBackup(
                backupID: UUID().uuidString.lowercased(),
                name: "cancel",
                volumes: [
                    StorageBackupVolumeRequest(
                        volumeID: volume.volumeID,
                        expectedGeneration: volume.generation,
                        expectedFencingToken: volume.fencingToken
                    )
                ],
                hooks: StorageBackupHooks(isCancelled: { true })
            )
        ) { error in
            XCTAssertEqual(error as? StorageBackupError, .cancelled)
        }
        let operations = try FileManager.default.contentsOfDirectory(
            at: harness.containerRoot.appendingPathComponent("backups/.operations", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(operations.isEmpty)
    }

    func testRestoreRollbackCleanupIncompleteManifestAndUnmanagedTargetRefusal() async throws {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 64 * 1_024 * 1_024
        )
        let snapshotEngine = try StorageSnapshotEngine(
            provider: provider,
            snapshotRootURL: harness.containerRoot.appendingPathComponent("snapshots", isDirectory: true)
        )
        let sourceIdentity = LocalStorageTestIdentity()
        let targetIdentity = LocalStorageTestIdentity()
        let source = try await createVolume(provider: provider, identity: sourceIdentity, key: "restore-src")
        let target = try await createVolume(provider: provider, identity: targetIdentity, key: "restore-dst")
        try writeTree(root: URL(fileURLWithPath: source.dataPath, isDirectory: true), files: ["nested/file.txt": "payload"])
        try writeTree(root: URL(fileURLWithPath: target.dataPath, isDirectory: true), files: ["keep.txt": "preserve"])

        let secret = try HostwrightSecretReference(service: "hostwright-tests", account: "restore")
        let engine = try StorageBackupEngine(
            provider: provider,
            snapshotEngine: snapshotEngine,
            backupRootURL: harness.containerRoot.appendingPathComponent("backups", isDirectory: true),
            keyResolver: InlineBackupKeyResolver(secret: "restore-key"),
            keyReference: secret
        )
        let backup = try engine.createBackup(
            backupID: UUID().uuidString.lowercased(),
            name: "restore",
            volumes: [
                StorageBackupVolumeRequest(
                    volumeID: source.volumeID,
                    expectedGeneration: source.generation,
                    expectedFencingToken: source.fencingToken
                )
            ]
        )

        let fault = OneShotBackupFault(point: .restorePromoted)
        XCTAssertThrowsError(
            try engine.restore(
                backupID: backup.backupID,
                targets: [
                    StorageBackupTargetRequest(
                        sourceVolumeID: source.volumeID,
                        targetVolumeID: target.volumeID,
                        expectedGeneration: target.generation,
                        expectedFencingToken: target.fencingToken
                    )
                ],
                hooks: StorageBackupHooks(faultInjector: fault.injector)
            )
        )
        XCTAssertEqual(
            try String(
                decoding: Data(
                    contentsOf: URL(fileURLWithPath: target.dataPath, isDirectory: true)
                        .appendingPathComponent("keep.txt", isDirectory: false)
                ),
                as: UTF8.self
            ),
            "preserve"
        )

        let manifest = harness.containerRoot
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("sets", isDirectory: true)
            .appendingPathComponent(backup.backupID, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        try FileManager.default.removeItem(at: manifest)
        XCTAssertThrowsError(
            try engine.restore(
                backupID: backup.backupID,
                targets: [
                    StorageBackupTargetRequest(
                        sourceVolumeID: source.volumeID,
                        targetVolumeID: target.volumeID,
                        expectedGeneration: target.generation,
                        expectedFencingToken: target.fencingToken
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(error as? StorageBackupError, .ioFailure)
        }

        let unmanagedParent = URL(fileURLWithPath: target.dataPath, isDirectory: true).deletingLastPathComponent()
        let symlinkPath = unmanagedParent.appendingPathComponent("symlinked-target", isDirectory: true)
        XCTAssertEqual(symlink(URL(fileURLWithPath: target.dataPath, isDirectory: true).path, symlinkPath.path), 0)
        XCTAssertThrowsError(try StorageSnapshotFilesystem.ensureSafeParent(symlinkPath)) { _ in }
    }

    func testRemoteTransportUsesStubbedHTTPSAndRejectsRedirects() throws {
        let endpoint = URL(string: "https://example.test")!
        let transport = StorageBackupS3Transport(
            endpoint: endpoint,
            bucket: "bucket",
            region: "us-east-1",
            accessKeyID: "AKID",
            secretAccessKey: "SECRET",
            sessionConfiguration: URLSessionConfiguration.ephemeralWithStub(
                handler: { request in
                    XCTAssertEqual(request.url?.scheme, "https")
                    XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
                    XCTAssertEqual(
                        requestBody(request),
                        Data("payload".utf8)
                    )
                    return (200, Data("ok".utf8))
                }
            )
        )
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data("payload".utf8).write(to: temp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temp) }
        XCTAssertNoThrow(
            try transport.uploadObject(
                objectKey: "object",
                from: temp,
                sizeLimitBytes: 1024
            )
        )
    }

    func testRemoteTransportCancelsTaskWhenBoundedWaitExpires()
        throws
    {
        TimeoutTrackingURLProtocol.reset()
        let configuration =
            URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            TimeoutTrackingURLProtocol.self,
        ]
        let transport = StorageBackupS3Transport(
            endpoint:
                URL(string: "https://example.test")!,
            bucket: "bucket",
            region: "us-east-1",
            accessKeyID: "AKID",
            secretAccessKey: "SECRET",
            timeout: 0.01,
            sessionConfiguration: configuration
        )
        let temp =
            FileManager.default.temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: false
            )
        try Data("payload".utf8).write(
            to: temp,
            options: .atomic
        )
        defer {
            try? FileManager.default.removeItem(at: temp)
        }
        XCTAssertThrowsError(
            try transport.uploadObject(
                objectKey: "object",
                from: temp,
                sizeLimitBytes: 1_024
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageBackupError,
                .remoteTransportFailure
            )
        }
        XCTAssertTrue(
            TimeoutTrackingURLProtocol.waitUntilStopped(
                timeout: 2
            )
        )
    }

    func testRemoteBackupHydratesMissingLocalArtifactsRestoresAndDeletesExactly()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 64 * 1_024 * 1_024
        )
        let snapshotRoot = harness.containerRoot
            .appendingPathComponent(
                "snapshots",
                isDirectory: true
            )
        let backupRoot = harness.containerRoot
            .appendingPathComponent(
                "backups",
                isDirectory: true
            )
        let source = try await createVolume(
            provider: provider,
            identity: LocalStorageTestIdentity(),
            key: "remote-source"
        )
        let target = try await createVolume(
            provider: provider,
            identity: LocalStorageTestIdentity(),
            key: "remote-target"
        )
        try writeTree(
            root: URL(
                fileURLWithPath: source.dataPath,
                isDirectory: true
            ),
            files: [
                ".config": "private",
                "data/value.txt": "remote-value",
            ]
        )
        let expectedDigest = try treeDigest(
            URL(
                fileURLWithPath: source.dataPath,
                isDirectory: true
            )
        )
        let keyReference =
            try HostwrightSecretReference(
                service: "hostwright-tests",
                account: "remote-backup-key"
            )
        let destination = try remoteDestination()
        let transport = InMemoryBackupRemoteTransport()
        var engine = try StorageBackupEngine(
            provider: provider,
            snapshotEngine: try StorageSnapshotEngine(
                provider: provider,
                snapshotRootURL: snapshotRoot
            ),
            backupRootURL: backupRoot,
            keyResolver: InlineBackupKeyResolver(
                secret: "remote-encryption-key"
            ),
            keyReference: keyReference,
            remoteDestination: destination,
            remoteTransport: transport
        )
        let backup = try engine.createBackup(
            backupID: UUID().uuidString.lowercased(),
            name: "remote-qualified",
            volumes: [
                StorageBackupVolumeRequest(
                    volumeID: source.volumeID,
                    expectedGeneration: source.generation,
                    expectedFencingToken:
                        source.fencingToken
                ),
            ]
        )
        XCTAssertEqual(
            backup.remoteDestination,
            destination
        )
        XCTAssertTrue(
            transport.keys.contains(
                "sets/\(backup.backupID)/manifest.json"
            )
        )
        XCTAssertFalse(
            transport.concatenatedUTF8.contains(
                "REMOTE-ACCESS-ID"
            )
        )
        XCTAssertFalse(
            transport.concatenatedUTF8.contains(
                "REMOTE-SECRET"
            )
        )

        try FileManager.default.removeItem(
            at: backupRoot.appendingPathComponent(
                "sets",
                isDirectory: true
            )
        )
        try FileManager.default.createDirectory(
            at: backupRoot.appendingPathComponent(
                "sets",
                isDirectory: true
            ),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.removeItem(
            at: backupRoot.appendingPathComponent(
                "chunks",
                isDirectory: true
            )
        )
        try FileManager.default.createDirectory(
            at: backupRoot.appendingPathComponent(
                "chunks",
                isDirectory: true
            ),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        engine = try StorageBackupEngine(
            provider: provider,
            snapshotEngine: try StorageSnapshotEngine(
                provider: provider,
                snapshotRootURL: snapshotRoot
            ),
            backupRootURL: backupRoot,
            keyResolver: InlineBackupKeyResolver(
                secret: "remote-encryption-key"
            ),
            keyReference: keyReference,
            remoteDestination: destination,
            remoteTransport: transport
        )
        XCTAssertEqual(
            try engine.verify(
                backupID: backup.backupID
            ).verifiedVolumeIDs,
            [source.volumeID]
        )
        try FileManager.default.removeItem(
            at: backupRoot.appendingPathComponent(
                "chunks",
                isDirectory: true
            )
        )
        try FileManager.default.createDirectory(
            at: backupRoot.appendingPathComponent(
                "chunks",
                isDirectory: true
            ),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        _ = try engine.restore(
            backupID: backup.backupID,
            targets: [
                StorageBackupTargetRequest(
                    sourceVolumeID: source.volumeID,
                    targetVolumeID: target.volumeID,
                    expectedGeneration: target.generation,
                    expectedFencingToken:
                        target.fencingToken
                ),
            ]
        )
        XCTAssertEqual(
            try treeDigest(
                URL(
                    fileURLWithPath: target.dataPath,
                    isDirectory: true
                )
            ),
            expectedDigest
        )
        try engine.delete(backupID: backup.backupID)
        XCTAssertTrue(transport.keys.isEmpty)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: backupRoot.appendingPathComponent(
                    "sets",
                    isDirectory: true
                ),
                includingPropertiesForKeys: nil
            ).isEmpty
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: backupRoot.appendingPathComponent(
                    "chunks",
                    isDirectory: true
                ),
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testRemoteCreateInterruptionLeavesDurableCleanupAndRecoveryRemovesExactObjects()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 64 * 1_024 * 1_024
        )
        let snapshotRoot = harness.containerRoot
            .appendingPathComponent("snapshots")
        let backupRoot = harness.containerRoot
            .appendingPathComponent("backups")
        let source = try await createVolume(
            provider: provider,
            identity: LocalStorageTestIdentity(),
            key: "remote-interrupted-source"
        )
        try writeTree(
            root: URL(
                fileURLWithPath: source.dataPath,
                isDirectory: true
            ),
            files: ["value.txt": "recover-me"]
        )
        let keyReference =
            try HostwrightSecretReference(
                service: "hostwright-tests",
                account: "remote-interrupted-key"
            )
        let destination = try remoteDestination()
        let transport = InMemoryBackupRemoteTransport()
        transport.failUploadNumber = 2
        transport.failDeleteNumber = 1
        let engine = try StorageBackupEngine(
            provider: provider,
            snapshotEngine: try StorageSnapshotEngine(
                provider: provider,
                snapshotRootURL: snapshotRoot
            ),
            backupRootURL: backupRoot,
            keyResolver: InlineBackupKeyResolver(
                secret: "remote-interrupted-key"
            ),
            keyReference: keyReference,
            remoteDestination: destination,
            remoteTransport: transport
        )
        XCTAssertThrowsError(
            try engine.createBackup(
                backupID: UUID().uuidString.lowercased(),
                name: "interrupted",
                volumes: [
                    StorageBackupVolumeRequest(
                        volumeID: source.volumeID,
                        expectedGeneration:
                            source.generation,
                        expectedFencingToken:
                            source.fencingToken
                    ),
                ]
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageBackupError,
                .remoteTransportFailure
            )
        }
        XCTAssertFalse(transport.keys.isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: backupRoot.appendingPathComponent(
                    ".operations",
                    isDirectory: true
                ),
                includingPropertiesForKeys: nil
            ).count,
            1
        )

        transport.clearFailures()
        _ = try StorageBackupEngine(
            provider: provider,
            snapshotEngine: try StorageSnapshotEngine(
                provider: provider,
                snapshotRootURL: snapshotRoot
            ),
            backupRootURL: backupRoot,
            keyResolver: InlineBackupKeyResolver(
                secret: "remote-interrupted-key"
            ),
            keyReference: keyReference,
            remoteDestination: destination,
            remoteTransport: transport
        )
        XCTAssertTrue(transport.keys.isEmpty)
        try assertBackupWorkingDirectoriesAreEmpty(harness)
    }

    private func remoteDestination() throws
        -> StorageBackupRemoteDestination
    {
        try StorageBackupRemoteDestination(
            endpoint: "https://backup.example.test",
            bucket: "hostwright-test-backups",
            region: "us-east-1",
            objectPrefix: "phase06",
            accessKeyIDReference:
                "keychain://hostwright-tests/remote-access",
            secretAccessKeyReference:
                "keychain://hostwright-tests/remote-secret"
        )
    }

    private func createVolume(
        provider: LocalStorageProvider,
        identity: LocalStorageTestIdentity,
        key: String
    ) async throws -> LocalStorageVolumeObservation {
        let request = LocalStorageProviderTestRequest(
            operation: .create,
            context: identity.context(resourceGeneration: 1),
            idempotencyKey: key,
            payload: LocalStorageCreatePayload(
                name: "volume-\(identity.volumeID.prefix(8))",
                capacityBytes: 2 * 1_024 * 1_024,
                retention: .retain
            )
        )
        let response = try await provider.invoke(canonicalRequest: request.canonical())
        let result = try StorageProviderCanonicalJSON.decodeResult(
            LocalStorageMutationResult.self,
            from: response
        ).result
        return try XCTUnwrap(result.volume)
    }

    private func writeTree(root: URL, files: [String: String]) throws {
        for (relative, contents) in files {
            let file = root.appendingPathComponent(relative, isDirectory: false)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(contents.utf8).write(to: file, options: .atomic)
        }
    }

    private func treeDigest(_ root: URL) throws -> String {
        try StorageSnapshotFilesystem.hashTree(
            at: root,
            hooks: StorageSnapshotHooks()
        ).sha256
    }

    private func setMode(_ url: URL, _ value: mode_t) throws {
        guard chmod(url.path, value) == 0 else {
            throw StorageBackupError.ioFailure
        }
    }

    private func mode(_ url: URL) throws -> UInt16 {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw StorageBackupError.ioFailure
        }
        return UInt16(metadata.st_mode & 0o7777)
    }

    private func assertBackupWorkingDirectoriesAreEmpty(
        _ harness: LocalStorageProviderTestHarness
    ) throws {
        for relativePath in ["backups/.operations", "backups/.staging"] {
            let entries = try FileManager.default.contentsOfDirectory(
                at: harness.containerRoot.appendingPathComponent(
                    relativePath,
                    isDirectory: true
                ),
                includingPropertiesForKeys: nil
            )
            XCTAssertTrue(
                entries.isEmpty,
                "Expected exact cleanup of \(relativePath), found \(entries)."
            )
        }
    }
}

private struct InlineBackupKeyResolver: StorageBackupKeyResolver {
    let secret: String

    func resolveKey(reference: HostwrightSecretReference) throws -> SymmetricKey {
        SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
    }
}

private final class OneShotBackupFault: @unchecked Sendable {
    private let point: StorageSnapshotCheckpoint
    private let error: StorageBackupError
    private let lock = NSLock()
    private var fired = false

    init(
        point: StorageSnapshotCheckpoint,
        error: StorageBackupError = .ioFailure
    ) {
        self.point = point
        self.error = error
    }

    var injector: StorageSnapshotFaultInjector {
        StorageSnapshotFaultInjector { [self] candidate in
            lock.lock()
            defer { lock.unlock() }
            if candidate == point, !fired {
                fired = true
                throw error
            }
        }
    }
}

private final class BackupHookEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

private final class InMemoryBackupRemoteTransport:
    StorageBackupRemoteTransport,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private var uploadCount = 0
    private var deleteCount = 0
    var failUploadNumber: Int?
    var failDeleteNumber: Int?

    var keys: [String] {
        lock.withLock { objects.keys.sorted() }
    }

    var concatenatedUTF8: String {
        lock.withLock {
            objects.keys.sorted().map {
                String(
                    decoding: objects[$0] ?? Data(),
                    as: UTF8.self
                )
            }.joined(separator: "\n")
        }
    }

    func clearFailures() {
        lock.withLock {
            failUploadNumber = nil
            failDeleteNumber = nil
        }
    }

    func uploadObject(
        objectKey: String,
        from fileURL: URL,
        sizeLimitBytes: Int64
    ) throws {
        let data = try Data(
            contentsOf: fileURL,
            options: [.mappedIfSafe]
        )
        guard Int64(data.count) <= sizeLimitBytes else {
            throw StorageBackupError
                .remoteTransportFailure
        }
        try lock.withLock {
            uploadCount += 1
            if uploadCount == failUploadNumber {
                throw StorageBackupError
                    .remoteTransportFailure
            }
            objects[objectKey] = data
        }
    }

    func downloadObject(
        objectKey: String,
        to fileURL: URL,
        sizeLimitBytes: Int64
    ) throws {
        let data = try lock.withLock {
            guard let data = objects[objectKey] else {
                throw StorageBackupError
                    .remoteObjectNotFound
            }
            return data
        }
        guard Int64(data.count) <= sizeLimitBytes else {
            throw StorageBackupError
                .remoteTransportFailure
        }
        try data.write(to: fileURL, options: .atomic)
    }

    func deleteObject(objectKey: String) throws {
        try lock.withLock {
            deleteCount += 1
            if deleteCount == failDeleteNumber {
                throw StorageBackupError
                    .remoteTransportFailure
            }
            objects.removeValue(forKey: objectKey)
        }
    }
}

private func requestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            return nil
        }
        if count == 0 {
            return data
        }
        data.append(buffer, count: count)
    }
}

private final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try StubURLProtocolHandler.shared.get()(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class TimeoutTrackingURLProtocol:
    URLProtocol
{
    private static let state =
        TimeoutTrackingURLProtocolState()

    static var stopped: Bool {
        state.stopped
    }

    static func reset() {
        state.reset()
    }

    static func waitUntilStopped(
        timeout: TimeInterval
    ) -> Bool {
        state.waitUntilStopped(timeout: timeout)
    }

    override class func canInit(
        with request: URLRequest
    ) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {}

    override func stopLoading() {
        Self.state.markStopped()
    }
}

private final class TimeoutTrackingURLProtocolState:
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var didStop = false

    var stopped: Bool {
        condition.withLock { didStop }
    }

    func reset() {
        condition.withLock { didStop = false }
    }

    func markStopped() {
        condition.withLock {
            didStop = true
            condition.broadcast()
        }
    }

    func waitUntilStopped(
        timeout: TimeInterval
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !didStop else {
            return true
        }
        let deadline = Date(
            timeIntervalSinceNow: timeout
        )
        while !didStop &&
            condition.wait(until: deadline) {}
        return didStop
    }
}

private extension URLSessionConfiguration {
    static func ephemeralWithStub(
        handler: @escaping (URLRequest) -> (Int, Data)
    ) -> URLSessionConfiguration {
        StubURLProtocolHandler.shared.set { request in handler(request) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }
}

private final class StubURLProtocolHandler: @unchecked Sendable {
    static let shared = StubURLProtocolHandler()

    private let lock = NSLock()
    private var handler: (URLRequest) throws -> (Int, Data) = { _ in (500, Data()) }

    func set(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func get() -> (URLRequest) throws -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}
