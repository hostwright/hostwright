import CryptoKit
import Foundation
import HostwrightSecrets
import HostwrightStorage
import XCTest

final class LocalStorageProviderDataProtectionTests:
    XCTestCase
{
    func testLegacyCreatePayloadsRemainWireCompatible()
        throws
    {
        let snapshot = LocalStorageSnapshotPayload(
            snapshotID: UUID().uuidString.lowercased(),
            name: "legacy-snapshot"
        )
        let snapshotData = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(
            try JSONDecoder().decode(
                LocalStorageSnapshotPayload.self,
                from: snapshotData
            ),
            snapshot
        )
        XCTAssertNil(
            try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: snapshotData
                ) as? [String: Any]
            )["action"]
        )

        let backup = LocalStorageBackupPayload(
            backupID: UUID().uuidString.lowercased(),
            name: "legacy-backup",
            keyReference:
                "keychain://hostwright-tests/provider",
            volumes: [
                LocalStorageBackupVolumePayload(
                    volumeID: UUID().uuidString.lowercased(),
                    generation: 1,
                    fencingToken:
                        UUID().uuidString.lowercased()
                ),
            ]
        )
        let backupData = try JSONEncoder().encode(backup)
        XCTAssertEqual(
            try JSONDecoder().decode(
                LocalStorageBackupPayload.self,
                from: backupData
            ),
            backup
        )
        XCTAssertNil(
            try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: backupData
                ) as? [String: Any]
            )["action"]
        )
    }

    func testSnapshotCreateReplayAndRestoreUseExactOwnership()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try makeProvider(harness)
        let project = UUID()
        let source = DataProtectionIdentity(project: project)
        let target = DataProtectionIdentity(project: project)
        let sourceVolume = try await createVolume(
            provider,
            identity: source,
            key: "snapshot-source"
        )
        let targetVolume = try await createVolume(
            provider,
            identity: target,
            key: "snapshot-target"
        )
        try Data("snapshot-value".utf8).write(
            to: URL(fileURLWithPath: sourceVolume.dataPath)
                .appendingPathComponent("value.txt")
        )
        try Data("old-value".utf8).write(
            to: URL(fileURLWithPath: targetVolume.dataPath)
                .appendingPathComponent("value.txt")
        )

        let snapshotID = UUID().uuidString.lowercased()
        let payload = LocalStorageSnapshotPayload(
            snapshotID: snapshotID,
            name: "provider-snapshot"
        )
        let request = LocalStorageProviderTestRequest(
            operation: .snapshot,
            context: source.context,
            idempotencyKey: "provider-snapshot-create",
            payload: payload
        )
        let created: LocalStorageSnapshotResult =
            try await call(provider, request)
        XCTAssertEqual(created.disposition, .performed)
        XCTAssertEqual(created.sourceVolumeID, source.volumeID)
        XCTAssertEqual(
            created.consistencyClass,
            .crashConsistent
        )
        XCTAssertEqual(
            created.parentContentTreeSHA256,
            created.contentTreeSHA256
        )
        XCTAssertEqual(created.contentTreeSHA256.utf8.count, 64)
        XCTAssertEqual(
            created.lineage,
            ["volume:\(source.volumeID)@1"]
        )

        let replayed: LocalStorageSnapshotResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .snapshot,
                    context: source.context,
                    idempotencyKey:
                        request.idempotencyKey,
                    payload: payload
                )
            )
        XCTAssertEqual(replayed, created)

        let restored: LocalStorageRestoreResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .restore,
                    context: target.context,
                    idempotencyKey:
                        "provider-snapshot-restore",
                    payload: LocalStorageRestorePayload(
                        source: .snapshot,
                        sourceID: snapshotID,
                        referenceID:
                            UUID().uuidString.lowercased(),
                        targets: [
                            LocalStorageRestoreTargetPayload(
                                sourceVolumeID:
                                    source.volumeID,
                                targetVolumeID:
                                    target.volumeID,
                                generation: 1,
                                fencingToken:
                                    target.fenceText
                            ),
                        ]
                    )
                )
            )
        XCTAssertEqual(restored.source, .snapshot)
        XCTAssertEqual(
            restored.restoredTargetVolumeIDs,
            [target.volumeID]
        )
        XCTAssertEqual(
            try String(
                contentsOf: URL(
                    fileURLWithPath: targetVolume.dataPath
                ).appendingPathComponent("value.txt"),
                encoding: .utf8
            ),
            "snapshot-value"
        )
        XCTAssertTrue(
            try provider.list().pendingRecoveryIDs.isEmpty
        )
    }

    func testBackupIsVerifiedAndRestoresThroughSPI()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try makeProvider(harness)
        let project = UUID()
        let source = DataProtectionIdentity(project: project)
        let target = DataProtectionIdentity(project: project)
        let sourceVolume = try await createVolume(
            provider,
            identity: source,
            key: "backup-source"
        )
        let targetVolume = try await createVolume(
            provider,
            identity: target,
            key: "backup-target"
        )
        try Data("backup-value".utf8).write(
            to: URL(fileURLWithPath: sourceVolume.dataPath)
                .appendingPathComponent("value.txt")
        )
        try Data("target-before".utf8).write(
            to: URL(fileURLWithPath: targetVolume.dataPath)
                .appendingPathComponent("value.txt")
        )
        let backupID = UUID().uuidString.lowercased()
        let keyReference =
            "keychain://hostwright-tests/provider"
        let backup: LocalStorageBackupResult = try await call(
            provider,
            LocalStorageProviderTestRequest(
                operation: .backup,
                context: source.context,
                idempotencyKey: "provider-backup-create",
                payload: LocalStorageBackupPayload(
                    backupID: backupID,
                    name: "provider-backup",
                    keyReference: keyReference,
                    volumes: [
                        LocalStorageBackupVolumePayload(
                            volumeID: source.volumeID,
                            generation: 1,
                            fencingToken: source.fenceText
                        ),
                    ]
                )
            )
        )
        XCTAssertEqual(backup.disposition, .performed)
        XCTAssertEqual(backup.verifiedVolumeIDs, [source.volumeID])
        XCTAssertEqual(backup.manifestSHA256.utf8.count, 64)

        let restored: LocalStorageRestoreResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .restore,
                    context: target.context,
                    idempotencyKey:
                        "provider-backup-restore",
                    payload: LocalStorageRestorePayload(
                        source: .backup,
                        sourceID: backupID,
                        expectedManifestSHA256:
                            backup.manifestSHA256,
                        keyReference: keyReference,
                        targets: [
                            LocalStorageRestoreTargetPayload(
                                sourceVolumeID:
                                    source.volumeID,
                                targetVolumeID:
                                    target.volumeID,
                                generation: 1,
                                fencingToken:
                                    target.fenceText
                            ),
                        ]
                    )
                )
            )
        XCTAssertEqual(restored.source, .backup)
        XCTAssertEqual(
            restored.restoredTargetVolumeIDs,
            [target.volumeID]
        )
        XCTAssertEqual(
            try String(
                contentsOf: URL(
                    fileURLWithPath: targetVolume.dataPath
                ).appendingPathComponent("value.txt"),
                encoding: .utf8
            ),
            "backup-value"
        )
        XCTAssertTrue(
            try provider.list().pendingRecoveryIDs.isEmpty
        )
    }

    func testBackupRestoreRejectsManifestRebindingBeforeMutation()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try makeProvider(harness)
        let project = UUID()
        let source = DataProtectionIdentity(project: project)
        let target = DataProtectionIdentity(project: project)
        let sourceVolume = try await createVolume(
            provider,
            identity: source,
            key: "rebind-source"
        )
        let targetVolume = try await createVolume(
            provider,
            identity: target,
            key: "rebind-target"
        )
        try Data("source-value".utf8).write(
            to: URL(fileURLWithPath: sourceVolume.dataPath)
                .appendingPathComponent("value.txt")
        )
        let targetFile = URL(
            fileURLWithPath: targetVolume.dataPath
        ).appendingPathComponent("value.txt")
        try Data("target-must-survive".utf8).write(
            to: targetFile
        )
        let backupID = UUID().uuidString.lowercased()
        let keyReference =
            "keychain://hostwright-tests/provider"
        let backup: LocalStorageBackupResult = try await call(
            provider,
            LocalStorageProviderTestRequest(
                operation: .backup,
                context: source.context,
                idempotencyKey: "rebind-backup",
                payload: LocalStorageBackupPayload(
                    backupID: backupID,
                    name: "rebind-backup",
                    keyReference: keyReference,
                    volumes: [
                        LocalStorageBackupVolumePayload(
                            volumeID: source.volumeID,
                            generation: 1,
                            fencingToken: source.fenceText
                        ),
                    ]
                )
            )
        )
        XCTAssertNotEqual(
            backup.manifestSHA256,
            String(repeating: "f", count: 64)
        )

        let restoreFailure = try await failure(
            provider,
            LocalStorageProviderTestRequest(
                operation: .restore,
                context: target.context,
                idempotencyKey: "rebind-restore",
                payload: LocalStorageRestorePayload(
                    source: .backup,
                    sourceID: backupID,
                    expectedManifestSHA256:
                        String(repeating: "f", count: 64),
                    keyReference: keyReference,
                    targets: [
                        LocalStorageRestoreTargetPayload(
                            sourceVolumeID: source.volumeID,
                            targetVolumeID: target.volumeID,
                            generation: 1,
                            fencingToken: target.fenceText
                        ),
                    ]
                )
            )
        )
        XCTAssertEqual(restoreFailure.category, .rejected)
        XCTAssertEqual(
            restoreFailure.recoveryDisposition,
            .safeHold
        )
        XCTAssertEqual(
            try String(
                contentsOf: targetFile,
                encoding: .utf8
            ),
            "target-must-survive"
        )
    }

    func testWrongProjectAndFenceRefuseBeforeSnapshot()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try makeProvider(harness)
        let identity = DataProtectionIdentity(project: UUID())
        _ = try await createVolume(
            provider,
            identity: identity,
            key: "refusal-source"
        )
        let payload = LocalStorageSnapshotPayload(
            snapshotID: UUID().uuidString.lowercased(),
            name: "refused-snapshot"
        )
        let wrongProject = StorageProviderMutationContext(
            projectUUID: UUID(),
            projectGeneration: 1,
            resourceUUID: identity.resource,
            resourceGeneration: 1,
            fencingToken: identity.fence
        )
        let ownershipFailure = try await failure(
            provider,
            LocalStorageProviderTestRequest(
                operation: .snapshot,
                context: wrongProject,
                idempotencyKey:
                    "snapshot-wrong-project",
                payload: payload
            )
        )
        XCTAssertEqual(
            ownershipFailure.category,
            .ambiguousEffect
        )

        let wrongFence = StorageProviderMutationContext(
            projectUUID: identity.project,
            projectGeneration: 1,
            resourceUUID: identity.resource,
            resourceGeneration: 1,
            fencingToken: UUID()
        )
        let fencingFailure = try await failure(
            provider,
            LocalStorageProviderTestRequest(
                operation: .snapshot,
                context: wrongFence,
                idempotencyKey: "snapshot-wrong-fence",
                payload: LocalStorageSnapshotPayload(
                    snapshotID:
                        UUID().uuidString.lowercased(),
                    name: "refused-fence"
                )
            )
        )
        XCTAssertEqual(
            fencingFailure.category,
            .fencingConflict
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.providerRoot
                    .appendingPathComponent(
                        "snapshots/snapshots/\(payload.snapshotID)"
                    ).path
            )
        )
    }

    func testTamperedBackupIsRefusedWithoutTargetMutation()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try makeProvider(harness)
        let project = UUID()
        let source = DataProtectionIdentity(project: project)
        let target = DataProtectionIdentity(project: project)
        let sourceVolume = try await createVolume(
            provider,
            identity: source,
            key: "tamper-source"
        )
        let targetVolume = try await createVolume(
            provider,
            identity: target,
            key: "tamper-target"
        )
        try Data("protected".utf8).write(
            to: URL(fileURLWithPath: sourceVolume.dataPath)
                .appendingPathComponent("value.txt")
        )
        let targetFile = URL(
            fileURLWithPath: targetVolume.dataPath
        ).appendingPathComponent("value.txt")
        try Data("must-survive".utf8).write(to: targetFile)

        let backupID = UUID().uuidString.lowercased()
        let keyReference =
            "keychain://hostwright-tests/provider"
        let backup: LocalStorageBackupResult = try await call(
            provider,
            LocalStorageProviderTestRequest(
                operation: .backup,
                context: source.context,
                idempotencyKey: "tamper-backup",
                payload: LocalStorageBackupPayload(
                    backupID: backupID,
                    name: "tamper-backup",
                    keyReference: keyReference,
                    volumes: [
                        LocalStorageBackupVolumePayload(
                            volumeID: source.volumeID,
                            generation: 1,
                            fencingToken: source.fenceText
                        ),
                    ]
                )
            )
        )
        let chunks = harness.providerRoot
            .appendingPathComponent(
                "backups/chunks",
                isDirectory: true
            )
        let chunk = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: chunks,
                includingPropertiesForKeys: nil
            ).first
        )
        let blob = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: chunk.appendingPathComponent(
                    "blobs",
                    isDirectory: true
                ),
                includingPropertiesForKeys: nil
            ).first
        )
        try Data("tampered".utf8).write(to: blob)

        let restoreFailure = try await failure(
            provider,
            LocalStorageProviderTestRequest(
                operation: .restore,
                context: target.context,
                idempotencyKey: "tampered-restore",
                payload: LocalStorageRestorePayload(
                    source: .backup,
                    sourceID: backupID,
                    expectedManifestSHA256:
                        backup.manifestSHA256,
                    keyReference: keyReference,
                    targets: [
                        LocalStorageRestoreTargetPayload(
                            sourceVolumeID: source.volumeID,
                            targetVolumeID: target.volumeID,
                            generation: 1,
                            fencingToken: target.fenceText
                        ),
                    ]
                )
            )
        )
        XCTAssertEqual(restoreFailure.category, .rejected)
        XCTAssertEqual(
            restoreFailure.recoveryDisposition,
            .safeHold
        )
        XCTAssertEqual(
            try String(contentsOf: targetFile, encoding: .utf8),
            "must-survive"
        )
        XCTAssertEqual(
            try provider.list().pendingRecoveryIDs.count,
            1
        )
    }

    func testSnapshotRetainExportDeleteAndReplayUseExactOwnership()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let identity = DataProtectionIdentity(project: UUID())
        var provider = try makeProvider(harness)
        let source = try await createVolume(
            provider,
            identity: identity,
            key: "snapshot-actions-source"
        )
        try Data("snapshot-actions".utf8).write(
            to: URL(fileURLWithPath: source.dataPath)
                .appendingPathComponent("value.txt")
        )

        let retainedSnapshot: LocalStorageSnapshotResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .snapshot,
                    context: identity.context,
                    idempotencyKey:
                        "snapshot-actions-retained-create",
                    payload: LocalStorageSnapshotPayload(
                        snapshotID:
                            UUID().uuidString.lowercased(),
                        name: "retained"
                    )
                )
            )
        let retained: LocalStorageSnapshotResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .snapshot,
                    context: identity.context,
                    idempotencyKey:
                        "snapshot-actions-retain",
                    payload: LocalStorageSnapshotPayload(
                        action: .retain,
                        snapshotID:
                            retainedSnapshot.snapshotID,
                        retainerID: "qualification"
                    )
                )
            )
        XCTAssertEqual(retained.action, .retain)
        XCTAssertEqual(retained.retainedBy, ["qualification"])
        XCTAssertEqual(
            retained.consistencyClass,
            retainedSnapshot.consistencyClass
        )
        XCTAssertEqual(
            retained.parentContentTreeSHA256,
            retainedSnapshot.parentContentTreeSHA256
        )
        XCTAssertEqual(
            retained.contentTreeSHA256,
            retainedSnapshot.contentTreeSHA256
        )
        XCTAssertEqual(
            retained.lineage,
            retainedSnapshot.lineage
        )
        let retainedDeleteFailure = try await failure(
            provider,
            LocalStorageProviderTestRequest(
                operation: .snapshot,
                context: identity.context,
                idempotencyKey:
                    "snapshot-actions-retained-delete",
                payload: LocalStorageSnapshotPayload(
                    action: .delete,
                    snapshotID: retained.snapshotID,
                    expectedContentTreeSHA256:
                        retained.contentTreeSHA256
                )
            )
        )
        XCTAssertEqual(
            retainedDeleteFailure.category,
            .ambiguousEffect
        )

        let exportSnapshot: LocalStorageSnapshotResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .snapshot,
                    context: identity.context,
                    idempotencyKey:
                        "snapshot-actions-export-create",
                    payload: LocalStorageSnapshotPayload(
                        snapshotID:
                            UUID().uuidString.lowercased(),
                        name: "exported"
                    )
                )
            )
        let exportParent = harness.providerRoot
            .appendingPathComponent(
                "qualified-exports",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: exportParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let export = exportParent.appendingPathComponent(
            "snapshot",
            isDirectory: true
        )
        let exportFault = DataProtectionOneShotFault(
            point: .afterEffectPersisted
        )
        provider = try makeProvider(
            harness,
            faultInjector: exportFault.injector
        )
        let exportRequest = LocalStorageProviderTestRequest(
            operation: .snapshot,
            context: identity.context,
            idempotencyKey: "snapshot-actions-export",
            payload: LocalStorageSnapshotPayload(
                action: .export,
                snapshotID: exportSnapshot.snapshotID,
                destinationPath: export.path,
                expectedContentTreeSHA256:
                    exportSnapshot.contentTreeSHA256
            )
        )
        await XCTAssertThrowsProviderError(
            try await provider.invoke(
                canonicalRequest: exportRequest.canonical()
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: export.path)
        )

        provider = try makeProvider(harness)
        let replayedExport: LocalStorageSnapshotResult =
            try await call(provider, exportRequest)
        XCTAssertEqual(
            replayedExport.disposition,
            .alreadySatisfied
        )
        XCTAssertEqual(replayedExport.action, .export)
        XCTAssertEqual(replayedExport.exportedPath, export.path)

        let deleted: LocalStorageSnapshotResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .snapshot,
                    context: identity.context,
                    idempotencyKey:
                        "snapshot-actions-delete",
                    payload: LocalStorageSnapshotPayload(
                        action: .delete,
                        snapshotID:
                            exportSnapshot.snapshotID,
                        expectedContentTreeSHA256:
                            exportSnapshot
                                .contentTreeSHA256
                    )
                )
            )
        XCTAssertEqual(deleted.action, .delete)
        XCTAssertEqual(deleted.deleted, true)
        XCTAssertTrue(
            try provider.list().pendingRecoveryIDs.isEmpty
        )
    }

    func testSnapshotDeleteReapsSupersededInterruptedExportIntent()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let identity = DataProtectionIdentity(project: UUID())
        var provider = try makeProvider(harness)
        let source = try await createVolume(
            provider,
            identity: identity,
            key: "snapshot-superseded-export-source"
        )
        try Data("snapshot-superseded-export".utf8).write(
            to: URL(fileURLWithPath: source.dataPath)
                .appendingPathComponent("value.txt")
        )

        let created: LocalStorageSnapshotResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .snapshot,
                    context: identity.context,
                    idempotencyKey:
                        "snapshot-superseded-export-create",
                    payload: LocalStorageSnapshotPayload(
                        snapshotID:
                            UUID().uuidString.lowercased(),
                        name: "superseded-export"
                    )
                )
            )
        let exportRoot = harness.providerRoot
            .appendingPathComponent(
                "superseded-exports",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: exportRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let exportPath = exportRoot.appendingPathComponent(
            "snapshot",
            isDirectory: true
        )
        let exportFault = DataProtectionOneShotFault(
            point: .afterEffectPersisted
        )
        provider = try makeProvider(
            harness,
            faultInjector: exportFault.injector
        )
        let exportRequest = LocalStorageProviderTestRequest(
            operation: .snapshot,
            context: identity.context,
            idempotencyKey: "snapshot-superseded-export",
            payload: LocalStorageSnapshotPayload(
                action: .export,
                snapshotID: created.snapshotID,
                destinationPath: exportPath.path,
                expectedContentTreeSHA256:
                    created.contentTreeSHA256
            )
        )
        await XCTAssertThrowsProviderError(
            try await provider.invoke(
                canonicalRequest: exportRequest.canonical()
            )
        )
        XCTAssertEqual(
            try provider.list().pendingRecoveryIDs.count,
            1
        )

        provider = try makeProvider(harness)
        let deleted: LocalStorageSnapshotResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .snapshot,
                    context: identity.context,
                    idempotencyKey:
                        "snapshot-superseded-export-delete",
                    payload: LocalStorageSnapshotPayload(
                        action: .delete,
                        snapshotID: created.snapshotID,
                        expectedContentTreeSHA256:
                            created.contentTreeSHA256
                    )
                )
            )
        XCTAssertEqual(deleted.action, .delete)
        XCTAssertEqual(deleted.deleted, true)
        XCTAssertTrue(
            try provider.list().pendingRecoveryIDs.isEmpty
        )
    }

    func testBackupVerifyRetainDeleteAndReplayUseExactOwnership()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let identity = DataProtectionIdentity(project: UUID())
        var provider = try makeProvider(harness)
        let source = try await createVolume(
            provider,
            identity: identity,
            key: "backup-actions-source"
        )
        try Data("backup-actions".utf8).write(
            to: URL(fileURLWithPath: source.dataPath)
                .appendingPathComponent("value.txt")
        )
        let keyReference =
            "keychain://hostwright-tests/provider"
        let volume = LocalStorageBackupVolumePayload(
            volumeID: identity.volumeID,
            generation: 1,
            fencingToken: identity.fenceText
        )

        let retainedBackup: LocalStorageBackupResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .backup,
                    context: identity.context,
                    idempotencyKey:
                        "backup-actions-retained-create",
                    payload: LocalStorageBackupPayload(
                        backupID:
                            UUID().uuidString.lowercased(),
                        name: "retained",
                        keyReference: keyReference,
                        volumes: [volume]
                    )
                )
            )
        let cancelledRequest = LocalStorageProviderTestRequest(
            operation: .backup,
            context: identity.context,
            idempotencyKey: "backup-actions-cancelled-verify",
            payload: LocalStorageBackupPayload(
                action: .verify,
                backupID: retainedBackup.backupID,
                keyReference: keyReference,
                volumes: [volume],
                expectedManifestSHA256:
                    retainedBackup.manifestSHA256
            )
        )
        await provider.cancel(
            requestID: cancelledRequest.requestID
        )
        let cancelled = try await failure(
            provider,
            cancelledRequest
        )
        XCTAssertEqual(cancelled.category, .cancelled)
        let verified: LocalStorageBackupResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .backup,
                    context: identity.context,
                    idempotencyKey:
                        "backup-actions-verify",
                    payload: LocalStorageBackupPayload(
                        action: .verify,
                        backupID: retainedBackup.backupID,
                        keyReference: keyReference,
                        volumes: [volume],
                        expectedManifestSHA256:
                            retainedBackup.manifestSHA256
                    )
                )
            )
        XCTAssertEqual(verified.action, .verify)
        XCTAssertEqual(
            verified.verifiedVolumeIDs,
            [identity.volumeID]
        )
        let retained: LocalStorageBackupResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .backup,
                    context: identity.context,
                    idempotencyKey:
                        "backup-actions-retain",
                    payload: LocalStorageBackupPayload(
                        action: .retain,
                        backupID: retainedBackup.backupID,
                        volumes: [volume],
                        retainerID: "qualification",
                        expectedManifestSHA256:
                            retainedBackup.manifestSHA256
                    )
                )
            )
        XCTAssertEqual(retained.action, .retain)
        XCTAssertEqual(retained.retainedBy, ["qualification"])
        let retainedDeleteFailure = try await failure(
            provider,
            LocalStorageProviderTestRequest(
                operation: .backup,
                context: identity.context,
                idempotencyKey:
                    "backup-actions-retained-delete",
                payload: LocalStorageBackupPayload(
                    action: .delete,
                    backupID: retained.backupID,
                    volumes: [volume],
                    expectedManifestSHA256:
                        retained.manifestSHA256
                )
            )
        )
        XCTAssertEqual(
            retainedDeleteFailure.category,
            .ambiguousEffect
        )

        let deletable: LocalStorageBackupResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .backup,
                    context: identity.context,
                    idempotencyKey:
                        "backup-actions-delete-create",
                    payload: LocalStorageBackupPayload(
                        backupID:
                            UUID().uuidString.lowercased(),
                        name: "deletable",
                        keyReference: keyReference,
                        volumes: [volume]
                    )
                )
            )
        let deleteFault = DataProtectionOneShotFault(
            point: .afterEffectPersisted
        )
        provider = try makeProvider(
            harness,
            faultInjector: deleteFault.injector
        )
        let deleteRequest = LocalStorageProviderTestRequest(
            operation: .backup,
            context: identity.context,
            idempotencyKey: "backup-actions-delete",
            payload: LocalStorageBackupPayload(
                action: .delete,
                backupID: deletable.backupID,
                volumes: [volume],
                expectedManifestSHA256:
                    deletable.manifestSHA256
            )
        )
        await XCTAssertThrowsProviderError(
            try await provider.invoke(
                canonicalRequest: deleteRequest.canonical()
            )
        )

        provider = try makeProvider(harness)
        let replayedDelete: LocalStorageBackupResult =
            try await call(provider, deleteRequest)
        XCTAssertEqual(
            replayedDelete.disposition,
            .alreadySatisfied
        )
        XCTAssertEqual(replayedDelete.action, .delete)
        XCTAssertEqual(replayedDelete.deleted, true)
        XCTAssertTrue(
            try provider.list().pendingRecoveryIDs.isEmpty
        )
    }

    func testInterruptedSnapshotReplaysFromDurableIntent()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let identity = DataProtectionIdentity(project: UUID())
        var provider = try makeProvider(harness)
        let source = try await createVolume(
            provider,
            identity: identity,
            key: "recovery-source"
        )
        try Data("recoverable".utf8).write(
            to: URL(fileURLWithPath: source.dataPath)
                .appendingPathComponent("value.txt")
        )
        let fault = DataProtectionOneShotFault(
            point: .afterEffectPersisted
        )
        provider = try makeProvider(
            harness,
            faultInjector: fault.injector
        )
        let request = LocalStorageProviderTestRequest(
            operation: .snapshot,
            context: identity.context,
            idempotencyKey: "snapshot-recovery",
            payload: LocalStorageSnapshotPayload(
                snapshotID: UUID().uuidString.lowercased(),
                name: "recovery-snapshot"
            )
        )
        await XCTAssertThrowsProviderError(
            try await provider.invoke(
                canonicalRequest: request.canonical()
            )
        )
        XCTAssertEqual(
            try provider.list().pendingRecoveryIDs.count,
            1
        )

        provider = try makeProvider(harness)
        let recovered: LocalStorageSnapshotResult =
            try await call(provider, request)
        XCTAssertEqual(
            recovered.disposition,
            .alreadySatisfied
        )
        XCTAssertTrue(
            try provider.list().pendingRecoveryIDs.isEmpty
        )
    }

    func testRemoteBackupProviderCreateHydrateVerifyRestoreDeleteAndReplay()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let accessReference =
            try HostwrightSecretReference(
                service: "hostwright-tests",
                account: "remote-access"
            )
        let secretReference =
            try HostwrightSecretReference(
                service: "hostwright-tests",
                account: "remote-secret"
            )
        let secretStore =
            DataProtectionRemoteSecretStore(
                values: [
                    accessReference:
                        "REMOTE-ACCESS-ID",
                    secretReference:
                        "REMOTE-SECRET-KEY",
                ]
            )
        let transport =
            DataProtectionRemoteTransport()
        let factory =
            DataProtectionRemoteTransportFactory(
                transport: transport
            )
        var provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024,
            backupKeyResolver:
                DataProtectionBackupKeyResolver(),
            backupRemoteSecretStore: secretStore,
            backupRemoteTransportFactory: factory
        )
        let project = UUID()
        let sourceIdentity =
            DataProtectionIdentity(project: project)
        let targetIdentity =
            DataProtectionIdentity(project: project)
        let source = try await createVolume(
            provider,
            identity: sourceIdentity,
            key: "remote-provider-source"
        )
        let target = try await createVolume(
            provider,
            identity: targetIdentity,
            key: "remote-provider-target"
        )
        try Data("remote-provider-data".utf8).write(
            to: URL(
                fileURLWithPath: source.dataPath
            ).appendingPathComponent("value.txt")
        )
        let destination =
            try StorageBackupRemoteDestination(
                endpoint:
                    "https://backup.example.test",
                bucket: "hostwright-provider-tests",
                region: "us-east-1",
                objectPrefix: "phase06",
                accessKeyIDReference:
                    accessReference.rawValue,
                secretAccessKeyReference:
                    secretReference.rawValue
            )
        let backupID = UUID().uuidString.lowercased()
        let volume = LocalStorageBackupVolumePayload(
            volumeID: sourceIdentity.volumeID,
            generation: 1,
            fencingToken: sourceIdentity.fenceText
        )
        let createRequest =
            LocalStorageProviderTestRequest(
                operation: .backup,
                context: sourceIdentity.context,
                idempotencyKey:
                    "remote-provider-create",
                payload: LocalStorageBackupPayload(
                    backupID: backupID,
                    name: "remote-provider",
                    keyReference:
                        "keychain://hostwright-tests/provider",
                    volumes: [volume],
                    remoteDestination: destination
                )
            )
        let created: LocalStorageBackupResult =
            try await call(provider, createRequest)
        XCTAssertTrue(
            transport.keys.contains(
                "sets/\(backupID)/manifest.json"
            )
        )
        XCTAssertEqual(
            secretStore.requestedReferences,
            [
                accessReference.rawValue,
                secretReference.rawValue,
            ]
        )
        try resetBackupCache(
            harness.providerRoot
        )

        provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024,
            backupKeyResolver:
                DataProtectionBackupKeyResolver(),
            backupRemoteSecretStore: secretStore,
            backupRemoteTransportFactory: factory
        )
        let verified: LocalStorageBackupResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .backup,
                    context: sourceIdentity.context,
                    idempotencyKey:
                        "remote-provider-verify",
                    payload: LocalStorageBackupPayload(
                        action: .verify,
                        backupID: backupID,
                        keyReference:
                            "keychain://hostwright-tests/provider",
                        volumes: [volume],
                        expectedManifestSHA256:
                            created.manifestSHA256,
                        remoteDestination: destination
                    )
                )
            )
        XCTAssertEqual(
            verified.verifiedVolumeIDs,
            [sourceIdentity.volumeID]
        )
        try resetBackupChunks(
            harness.providerRoot
        )
        let restored: LocalStorageRestoreResult =
            try await call(
                provider,
                LocalStorageProviderTestRequest(
                    operation: .restore,
                    context: targetIdentity.context,
                    idempotencyKey:
                        "remote-provider-restore",
                    payload: LocalStorageRestorePayload(
                        source: .backup,
                        sourceID: backupID,
                        expectedManifestSHA256:
                            created.manifestSHA256,
                        keyReference:
                            "keychain://hostwright-tests/provider",
                        targets: [
                            LocalStorageRestoreTargetPayload(
                                sourceVolumeID:
                                    sourceIdentity.volumeID,
                                targetVolumeID:
                                    targetIdentity.volumeID,
                                generation: 1,
                                fencingToken:
                                    targetIdentity.fenceText
                            ),
                        ],
                        remoteDestination: destination
                    )
                )
            )
        XCTAssertEqual(
            restored.restoredTargetVolumeIDs,
            [targetIdentity.volumeID]
        )
        XCTAssertEqual(
            try String(
                contentsOf: URL(
                    fileURLWithPath: target.dataPath
                ).appendingPathComponent("value.txt"),
                encoding: .utf8
            ),
            "remote-provider-data"
        )

        let deleteRequest =
            LocalStorageProviderTestRequest(
                operation: .backup,
                context: sourceIdentity.context,
                idempotencyKey:
                    "remote-provider-delete",
                payload: LocalStorageBackupPayload(
                    action: .delete,
                    backupID: backupID,
                    volumes: [volume],
                    expectedManifestSHA256:
                        created.manifestSHA256,
                    remoteDestination: destination
                )
            )
        let deleteFault = DataProtectionOneShotFault(
            point: .afterEffectPersisted
        )
        provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024,
            faultInjector: deleteFault.injector,
            backupKeyResolver:
                DataProtectionBackupKeyResolver(),
            backupRemoteSecretStore: secretStore,
            backupRemoteTransportFactory: factory
        )
        await XCTAssertThrowsProviderError(
            try await provider.invoke(
                canonicalRequest:
                    deleteRequest.canonical()
            )
        )
        XCTAssertTrue(transport.keys.isEmpty)

        provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024,
            backupKeyResolver:
                DataProtectionBackupKeyResolver(),
            backupRemoteSecretStore: secretStore,
            backupRemoteTransportFactory: factory
        )
        let replayed: LocalStorageBackupResult =
            try await call(provider, deleteRequest)
        XCTAssertEqual(
            replayed.disposition,
            .alreadySatisfied
        )
        XCTAssertEqual(replayed.deleted, true)
        XCTAssertTrue(
            try provider.list().pendingRecoveryIDs.isEmpty
        )
        XCTAssertFalse(
            try recursiveText(
                harness.providerRoot
            ).contains("REMOTE-SECRET-KEY")
        )
    }

    func testRemoteDestinationRejectsNonKeychainAndMissingCredentialsBeforeUpload()
        async throws
    {
        XCTAssertThrowsError(
            try StorageBackupRemoteDestination(
                endpoint:
                    "https://backup.example.test",
                bucket: "hostwright-provider-tests",
                region: "us-east-1",
                accessKeyIDReference:
                    "local-file:///tmp/access",
                secretAccessKeyReference:
                    "keychain://hostwright-tests/secret"
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageBackupError,
                .invalidRemoteDestination
            )
        }

        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let transport =
            DataProtectionRemoteTransport()
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024,
            backupKeyResolver:
                DataProtectionBackupKeyResolver(),
            backupRemoteSecretStore:
                DataProtectionRemoteSecretStore(
                    values: [:]
                ),
            backupRemoteTransportFactory:
                DataProtectionRemoteTransportFactory(
                    transport: transport
                )
        )
        let identity =
            DataProtectionIdentity(project: UUID())
        _ = try await createVolume(
            provider,
            identity: identity,
            key: "remote-missing-credential-source"
        )
        let destination =
            try StorageBackupRemoteDestination(
                endpoint:
                    "https://backup.example.test",
                bucket: "hostwright-provider-tests",
                region: "us-east-1",
                accessKeyIDReference:
                    "keychain://hostwright-tests/missing-access",
                secretAccessKeyReference:
                    "keychain://hostwright-tests/missing-secret"
            )
        let failed = try await failure(
            provider,
            LocalStorageProviderTestRequest(
                operation: .backup,
                context: identity.context,
                idempotencyKey:
                    "remote-missing-credential-create",
                payload: LocalStorageBackupPayload(
                    backupID:
                        UUID().uuidString.lowercased(),
                    name: "missing-credential",
                    keyReference:
                        "keychain://hostwright-tests/provider",
                    volumes: [
                        LocalStorageBackupVolumePayload(
                            volumeID: identity.volumeID,
                            generation: 1,
                            fencingToken:
                                identity.fenceText
                        ),
                    ],
                    remoteDestination: destination
                )
            )
        )
        XCTAssertEqual(failed.category, .internalFailure)
        XCTAssertTrue(transport.keys.isEmpty)
    }

    private func resetBackupCache(
        _ providerRoot: URL
    ) throws {
        let backupRoot = providerRoot
            .appendingPathComponent(
                "backups",
                isDirectory: true
            )
        for name in ["sets", "chunks"] {
            let path = backupRoot.appendingPathComponent(
                name,
                isDirectory: true
            )
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createDirectory(
                at: path,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func resetBackupChunks(
        _ providerRoot: URL
    ) throws {
        let path = providerRoot
            .appendingPathComponent(
                "backups/chunks",
                isDirectory: true
            )
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(
            at: path,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func recursiveText(_ root: URL) throws
        -> String
    {
        guard let enumerator =
                FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                    ],
                    options: [.skipsHiddenFiles]
                ) else {
            return ""
        }
        var text = ""
        for case let file as URL in enumerator {
            let values = try file.resourceValues(
                forKeys: [.isRegularFileKey]
            )
            if values.isRegularFile == true,
               let data = try? Data(
                   contentsOf: file,
                   options: [.mappedIfSafe]
               ),
               data.count <= 1_048_576 {
                text += String(
                    decoding: data,
                    as: UTF8.self
                )
            }
        }
        return text
    }

    private func makeProvider(
        _ harness: LocalStorageProviderTestHarness,
        faultInjector: LocalStorageProviderFaultInjector = .none
    ) throws -> LocalStorageProvider {
        try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024,
            faultInjector: faultInjector,
            backupKeyResolver:
                DataProtectionBackupKeyResolver()
        )
    }

    private func createVolume(
        _ provider: LocalStorageProvider,
        identity: DataProtectionIdentity,
        key: String
    ) async throws -> LocalStorageVolumeObservation {
        let result: LocalStorageMutationResult = try await call(
            provider,
            LocalStorageProviderTestRequest(
                operation: .create,
                context: identity.context,
                idempotencyKey: key,
                payload: LocalStorageCreatePayload(
                    name:
                        "volume-\(identity.volumeID.prefix(8))",
                    capacityBytes: 1_024 * 1_024
                )
            )
        )
        return try XCTUnwrap(result.volume)
    }

    private func call<Payload, Result>(
        _ provider: LocalStorageProvider,
        _ request: LocalStorageProviderTestRequest<Payload>
    ) async throws -> Result
    where Payload: Codable & Sendable,
        Result: Codable & Sendable
    {
        let response = try await provider.invoke(
            canonicalRequest: request.canonical()
        )
        if let error = try? StorageProviderCanonicalJSON
            .decodeError(from: response) {
            XCTFail(
                "Unexpected \(error.failure.category.rawValue): "
                    + error.failure.diagnostic
            )
            throw LocalStorageProviderError.invalidRequest
        }
        return try StorageProviderCanonicalJSON.decodeResult(
            Result.self,
            from: response
        ).result
    }

    private func failure<Payload>(
        _ provider: LocalStorageProvider,
        _ request: LocalStorageProviderTestRequest<Payload>
    ) async throws -> StorageProviderFailure
    where Payload: Codable & Sendable {
        let response = try await provider.invoke(
            canonicalRequest: request.canonical()
        )
        return try StorageProviderCanonicalJSON.decodeError(
            from: response
        ).failure
    }
}

private struct DataProtectionIdentity {
    let project: UUID
    let resource = UUID()
    let fence = UUID()

    var volumeID: String {
        resource.uuidString.lowercased()
    }

    var fenceText: String {
        fence.uuidString.lowercased()
    }

    var context: StorageProviderMutationContext {
        StorageProviderMutationContext(
            projectUUID: project,
            projectGeneration: 1,
            resourceUUID: resource,
            resourceGeneration: 1,
            fencingToken: fence
        )
    }
}

private struct DataProtectionBackupKeyResolver:
    StorageBackupKeyResolver
{
    func resolveKey(
        reference: HostwrightSecretReference
    ) throws -> SymmetricKey {
        SymmetricKey(
            data: Data(
                SHA256.hash(
                    data: Data("provider-test-key".utf8)
                )
            )
        )
    }
}

private final class DataProtectionRemoteSecretStore:
    SecretStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let values:
        [HostwrightSecretReference: String]
    private var requested: [String] = []

    init(
        values:
            [HostwrightSecretReference: String]
    ) {
        self.values = values
    }

    var requestedReferences: [String] {
        lock.withLock { requested }
    }

    func readString(
        reference: HostwrightSecretReference
    ) throws -> String {
        try lock.withLock {
            requested.append(reference.rawValue)
            guard let value = values[reference] else {
                throw SecretStoreError.notFound(
                    "Remote credential was not found."
                )
            }
            return value
        }
    }
}

private struct DataProtectionRemoteTransportFactory:
    StorageBackupRemoteTransportFactory,
    @unchecked Sendable
{
    let transport: DataProtectionRemoteTransport

    func makeTransport(
        destination: StorageBackupRemoteDestination,
        secretStore: any SecretStore
    ) throws -> any StorageBackupRemoteTransport {
        let access = try HostwrightSecretReference
            .parse(destination.accessKeyIDReference)
        let secret = try HostwrightSecretReference
            .parse(destination.secretAccessKeyReference)
        guard access.providerKind == .keychain,
              secret.providerKind == .keychain else {
            throw StorageBackupError
                .invalidRemoteDestination
        }
        _ = try secretStore.readString(
            reference: access
        )
        _ = try secretStore.readString(
            reference: secret
        )
        return transport
    }
}

private final class DataProtectionRemoteTransport:
    StorageBackupRemoteTransport,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var objects: [String: Data] = [:]

    var keys: [String] {
        lock.withLock { objects.keys.sorted() }
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
        lock.withLock {
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
        _ = lock.withLock {
            objects.removeValue(forKey: objectKey)
        }
    }
}

private final class DataProtectionOneShotFault:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let point: LocalStorageProviderFaultPoint
    private var fired = false

    init(point: LocalStorageProviderFaultPoint) {
        self.point = point
    }

    var injector: LocalStorageProviderFaultInjector {
        LocalStorageProviderFaultInjector { [self] candidate in
            let shouldFire = lock.withLock {
                guard !fired, candidate == point else {
                    return false
                }
                fired = true
                return true
            }
            if shouldFire {
                throw LocalStorageProviderInjectedInterruption(
                    point: candidate
                )
            }
        }
    }
}

private func XCTAssertThrowsProviderError<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(
            "Expected provider invocation to throw.",
            file: file,
            line: line
        )
    } catch {}
}
