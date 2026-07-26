import CryptoKit
import Foundation
import HostwrightCore
@testable import HostwrightCLI
import HostwrightSecrets
import HostwrightState
import HostwrightStorage
import XCTest

final class StorageReclaimCommandCoordinatorTests:
    XCTestCase
{
    func testDeleteDryRunIsDeterministicAndExactConfirmationDeletes()
        async throws
    {
        let fixture = try await makeFixture(
            suffix: "01",
            reclaimPolicy: .delete
        )
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()

        let first = try await coordinator.delete(
            volumeID: fixture.record.id,
            confirmation: .init(
                dryRun: true,
                confirmationPlanSHA256: nil
            ),
            client: fixture.client
        )
        let second = try await coordinator.delete(
            volumeID: fixture.record.id,
            confirmation: .init(
                dryRun: true,
                confirmationPlanSHA256: nil
            ),
            client: fixture.client
        )
        let plan = try planSHA256(first)
        XCTAssertEqual(plan, try planSHA256(second))

        await XCTAssertThrowsErrorAsync(
            try await coordinator.delete(
                volumeID: fixture.record.id,
                confirmation: .init(
                    dryRun: false,
                    confirmationPlanSHA256:
                        String(repeating: "0", count: 64)
                ),
                client: fixture.client
            )
        ) {
            XCTAssertEqual(
                ($0 as? HostwrightDiagnostic)?.code,
                .storageConflict
            )
        }
        XCTAssertEqual(
            try fixture.provider.list().volumes.map(\.volumeID),
            [fixture.record.id]
        )

        let result = try await coordinator.delete(
            volumeID: fixture.record.id,
            confirmation: .init(
                dryRun: false,
                confirmationPlanSHA256: plan
            ),
            client: fixture.client
        )
        XCTAssertEqual(
            try report(result)["disposition"] as? String,
            LocalStorageMutationDisposition.performed.rawValue
        )
        XCTAssertTrue(try fixture.provider.list().volumes.isEmpty)
        let state = try XCTUnwrap(
            try fixture.repository.loadVolume(
                id: fixture.record.id
            )
        )
        XCTAssertEqual(state.lifecycleState, .deleted)
        XCTAssertEqual(state.generation, 3)
        XCTAssertEqual(
            try fixture.store.operationGroups.load(
                id: state.operationGroupID
            )?.status,
            .succeeded
        )
    }

    func testDeleteRefusesAttachmentHoldRetainAndRecycle()
        async throws
    {
        let attached = try await makeFixture(
            suffix: "02",
            reclaimPolicy: .delete
        )
        defer { attached.cleanup() }
        let attachmentID =
            "22000000-0000-4000-8000-000000000002"
        let _: LocalStorageMutationResult =
            try await attached.client.invoke(
                operation: .attach,
                mutationContext: StorageProviderMutationContext(
                    projectUUID: attached.projectUUID,
                    projectGeneration: 1,
                    resourceUUID:
                        UUID(uuidString: attached.record.id)!,
                    resourceGeneration: 1,
                    attachmentGeneration: 1,
                    fencingToken: attached.fence
                ),
                idempotencyKey: sha256(
                    "attach:\(attachmentID)"
                ),
                payload: LocalStorageAttachPayload(
                    attachmentID: attachmentID,
                    consumerID: "workload",
                    readOnly: false,
                    volumeGeneration: 1,
                    volumeFencingToken:
                        attached.fence.uuidString.lowercased()
                ),
                result: LocalStorageMutationResult.self
            )
        await assertDeleteRefused(
            attached,
            code: .storageConflict
        )

        let held = try await makeFixture(
            suffix: "03",
            reclaimPolicy: .delete
        )
        defer { held.cleanup() }
        try held.repository.saveHold(
            StorageStateHoldRecord(
                id:
                    "33000000-0000-4000-8000-000000000003",
                resourceKind: .volume,
                resourceID: held.record.id,
                reasonRedacted: "operator hold",
                generation: 1,
                fencingToken:
                    held.fence.uuidString.lowercased(),
                operationGroupID: held.initialGroupID,
                createdAt: held.createdAt,
                expiresAt: nil,
                releasedAt: nil
            )
        )
        await assertDeleteRefused(
            held,
            code: .storageConflict
        )

        let retained = try await makeFixture(
            suffix: "04",
            reclaimPolicy: .retain
        )
        defer { retained.cleanup() }
        let retainedDryRun = try await retained.coordinator()
            .delete(
                volumeID: retained.record.id,
                confirmation: StorageDestructiveCLIOptions(
                    dryRun: true,
                    confirmationPlanSHA256: nil
                ),
                client: retained.client
            )
        let retainedPlan = try XCTUnwrap(
            try report(retainedDryRun)["planSHA256"] as? String
        )
        _ = try await retained.coordinator().delete(
            volumeID: retained.record.id,
            confirmation: StorageDestructiveCLIOptions(
                dryRun: false,
                confirmationPlanSHA256: retainedPlan
            ),
            client: retained.client
        )
        XCTAssertTrue(try retained.provider.list().volumes.isEmpty)
        XCTAssertEqual(
            try retained.repository.loadVolume(
                id: retained.record.id
            )?.lifecycleState,
            .deleted
        )

        let recycled = try await makeFixture(
            suffix: "05",
            reclaimPolicy: .recycle
        )
        defer { recycled.cleanup() }
        await assertDeleteRefused(
            recycled,
            code: .storageUnavailable
        )
    }

    func testProviderMissingDeletingReplayFinalizesState()
        async throws
    {
        let fixture = try await makeFixture(
            suffix: "06",
            reclaimPolicy: .delete
        )
        defer { fixture.cleanup() }
        let replayPlan = String(repeating: "b", count: 64)
        let groupID =
            "66000000-0000-4000-8000-000000000006"
        let operationFence =
            "66000000-0000-4000-9000-000000000006"
        let group = OperationGroupRecord(
            id: groupID,
            operationID: groupID,
            groupKind: "storage-reclaim",
            projectID: fixture.record.projectID,
            serviceName: nil,
            plannedActionType: "delete",
            status: .active,
            groupIdempotencyKey:
                String(repeating: "c", count: 64),
            planHash: replayPlan,
            checkpoint: "provider-effect-requested",
            lockOwner: "hostwright-cli",
            lockExpiresAt: "2035-01-01T00:00:00Z",
            rollbackAvailable: false,
            manualRecoveryHintRedacted: "re-observe",
            createdAt: fixture.createdAt,
            updatedAt: fixture.createdAt,
            metadataJSONRedacted: "{}",
            fencingToken: operationFence,
            intentJSONRedacted: "{}",
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        XCTAssertNotNil(
            try fixture.store.operationGroups.acquire(
                group,
                currentTimestamp: fixture.createdAt
            ).acquired
        )
        let deleting = fixture.record.replacing(
            generation: 2,
            fencingToken: operationFence,
            lifecycleState: .deleting,
            operationGroupID: groupID,
            updatedAt: "2026-07-25T12:00:01Z"
        )
        try fixture.repository.saveVolume(
            deleting,
            replacing: .init(
                generation: fixture.record.generation,
                fencingToken:
                    fixture.record.fencingToken
            )
        )
        let _: LocalStorageMutationResult =
            try await fixture.client.invoke(
                operation: .delete,
                mutationContext: fixture.providerContext,
                idempotencyKey: sha256("provider-missing"),
                payload: LocalStorageDeletePayload(),
                result: LocalStorageMutationResult.self
            )

        let coordinator = fixture.coordinator()
        let dryRun = try await coordinator.delete(
            volumeID: fixture.record.id,
            confirmation: .init(
                dryRun: true,
                confirmationPlanSHA256: nil
            ),
            client: fixture.client
        )
        XCTAssertEqual(try planSHA256(dryRun), replayPlan)
        _ = try await coordinator.delete(
            volumeID: fixture.record.id,
            confirmation: .init(
                dryRun: false,
                confirmationPlanSHA256: replayPlan
            ),
            client: fixture.client
        )

        let finalized = try XCTUnwrap(
            try fixture.repository.loadVolume(
                id: fixture.record.id
            )
        )
        XCTAssertEqual(finalized.lifecycleState, .deleted)
        XCTAssertEqual(finalized.generation, 3)
        XCTAssertEqual(
            try fixture.store.operationGroups.load(
                id: groupID
            )?.status,
            .succeeded
        )
    }

    func testPruneDeletesOnlyAgedExactOwnedDeletedState()
        async throws
    {
        let now: Int64 = 2_000_000_000_000
        let fixture = try await makeFixture(
            suffix: "07",
            reclaimPolicy: .delete,
            lifecycleState: .deleted,
            now: now
        )
        defer { fixture.cleanup() }
        let volumesRoot = fixture.providerRoot
            .appendingPathComponent("volumes", isDirectory: true)
        let unmanaged = volumesRoot.appendingPathComponent(
            "leave-me",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unmanaged,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let ambiguousID =
            "77000000-0000-4000-8000-000000000099"
        let external = fixture.root.appendingPathComponent(
            "ambiguous-target",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: volumesRoot.appendingPathComponent(
                ambiguousID,
                isDirectory: true
            ),
            withDestinationURL: external
        )

        let hash = orphanResourceHash(
            providerID:
                LocalStorageProviderContract.providerID,
            providerVolumeID: fixture.record.id
        )
        try fixture.repository.saveOrphan(
            StorageStateOrphanRecord(
                id:
                    "77000000-0000-4000-8000-000000000007",
                providerID:
                    LocalStorageProviderContract.providerID,
                resourceKind: .volume,
                providerResourceIDHash: hash,
                ownershipProofSHA256: nil,
                generation: 1,
                fencingToken:
                    fixture.fence.uuidString.lowercased(),
                lifecycleState: .discovered,
                operationGroupID: fixture.initialGroupID,
                discoveredAt:
                    timestamp(now - 2 * 60 * 60 * 1_000),
                resolvedAt: nil
            )
        )

        let coordinator = fixture.coordinator(now: now)
        let dryRun = try await coordinator.prune(
            confirmation: .init(
                dryRun: true,
                confirmationPlanSHA256: nil
            ),
            client: fixture.client
        )
        XCTAssertEqual(
            try report(dryRun)["volumeIDs"] as? [String],
            [fixture.record.id]
        )
        let plan = try planSHA256(dryRun)
        _ = try await coordinator.prune(
            confirmation: .init(
                dryRun: false,
                confirmationPlanSHA256: plan
            ),
            client: fixture.client
        )

        let after = try fixture.provider.list()
        XCTAssertTrue(after.volumes.isEmpty)
        XCTAssertEqual(after.unmanagedEntries, ["leave-me"])
        XCTAssertEqual(
            after.ambiguousVolumeIDs,
            [ambiguousID]
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: unmanaged.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: external.path
            )
        )
        let tracked = try fixture.repository.loadOrphans(
            providerID:
                LocalStorageProviderContract.providerID
        )
        let reclaimed = try XCTUnwrap(
            tracked.first {
                $0.providerResourceIDHash == hash
            }
        )
        XCTAssertEqual(reclaimed.lifecycleState, .reclaimed)
        XCTAssertNotNil(reclaimed.resolvedAt)
    }

    func testPruneResumesExactCandidatesAfterPartialProviderDeletion()
        async throws
    {
        let now: Int64 = 2_000_000_000_000
        let fixture = try await makeFixture(
            suffix: "11",
            reclaimPolicy: .delete,
            lifecycleState: .deleted,
            now: now
        )
        defer { fixture.cleanup() }
        let second = try await addDeletedVolume(
            to: fixture,
            volumeID:
                "88000000-0000-4000-8000-000000000011",
            name: "volume-11-second",
            fence:
                "ee000000-0000-4000-8000-000000000011"
        )
        try saveAgedOrphan(
            fixture.record,
            orphanID:
                "99000000-0000-4000-8000-000000000011",
            in: fixture,
            now: now
        )
        try saveAgedOrphan(
            second,
            orphanID:
                "99000000-0000-4000-8000-000000000012",
            in: fixture,
            now: now
        )

        let volumesRoot = fixture.providerRoot
            .appendingPathComponent(
                "volumes",
                isDirectory: true
            )
        let unmanaged = volumesRoot.appendingPathComponent(
            "leave-resume-unmanaged",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unmanaged,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let ambiguousID =
            "aa000000-0000-4000-8000-000000000011"
        let ambiguousTarget = fixture.root
            .appendingPathComponent(
                "leave-resume-ambiguous",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: ambiguousTarget,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: volumesRoot.appendingPathComponent(
                ambiguousID,
                isDirectory: true
            ),
            withDestinationURL: ambiguousTarget
        )

        let failingProvider =
            FailAfterFirstDeleteStorageProvider(
                provider: fixture.provider
            )
        let failingClient = try StorageProviderClient(
            provider: failingProvider
        )
        let coordinator = fixture.coordinator(now: now)
        let dryRun = try await coordinator.prune(
            confirmation: .init(
                dryRun: true,
                confirmationPlanSHA256: nil
            ),
            client: failingClient
        )
        XCTAssertEqual(
            try report(dryRun)["volumeIDs"] as? [String],
            [fixture.record.id, second.id]
        )
        let plan = try planSHA256(dryRun)

        await XCTAssertThrowsErrorAsync(
            try await coordinator.prune(
                confirmation: .init(
                    dryRun: false,
                    confirmationPlanSHA256: plan
                ),
                client: failingClient
            )
        )
        XCTAssertEqual(
            try fixture.provider.list().volumes
                .map(\.volumeID),
            [second.id]
        )
        let groupID = HostwrightResourceUUID.legacy(
            kind: "storage-prune-operation",
            identifier: plan
        )
        let interrupted = try XCTUnwrap(
            try fixture.store.operationGroups.load(
                id: groupID
            )
        )
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertTrue(
            interrupted.intentJSONRedacted.contains(
                fixture.record.id
            )
        )
        XCTAssertTrue(
            interrupted.intentJSONRedacted.contains(second.id)
        )

        let recovered = try await coordinator.prune(
            confirmation: .init(
                dryRun: false,
                confirmationPlanSHA256: plan
            ),
            client: fixture.client
        )
        XCTAssertEqual(
            try report(recovered)["disposition"] as? String,
            "recovered"
        )
        XCTAssertEqual(
            try report(recovered)["volumeIDs"] as? [String],
            [fixture.record.id, second.id]
        )
        let after = try fixture.provider.list()
        XCTAssertTrue(after.volumes.isEmpty)
        XCTAssertEqual(
            after.unmanagedEntries,
            ["leave-resume-unmanaged"]
        )
        XCTAssertEqual(
            after.ambiguousVolumeIDs,
            [ambiguousID]
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: unmanaged.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: ambiguousTarget.path
            )
        )
        for original in [fixture.record, second] {
            let state = try XCTUnwrap(
                try fixture.repository.loadVolume(
                    id: original.id
                )
            )
            XCTAssertEqual(state.lifecycleState, .deleted)
            XCTAssertEqual(
                state.generation,
                original.generation + 1
            )
            XCTAssertEqual(state.operationGroupID, groupID)
        }
        let reclaimedHashes = Set(
            try fixture.repository.loadOrphans(
                providerID:
                    LocalStorageProviderContract.providerID
            )
            .filter { $0.lifecycleState == .reclaimed }
            .map(\.providerResourceIDHash)
        )
        XCTAssertEqual(
            reclaimedHashes,
            Set([
                orphanResourceHash(
                    providerID:
                        LocalStorageProviderContract
                            .providerID,
                    providerVolumeID: fixture.record.id
                ),
                orphanResourceHash(
                    providerID:
                        LocalStorageProviderContract
                            .providerID,
                    providerVolumeID: second.id
                ),
            ])
        )
        XCTAssertEqual(
            try fixture.store.operationGroups.load(
                id: groupID
            )?.status,
            .succeeded
        )
    }

    func testLifecyclePolicyUsesExistingAuthorizationWithoutSecondConfirmation()
        async throws
    {
        let fixture = try await makeFixture(
            suffix: "08",
            reclaimPolicy: .delete
        )
        defer { fixture.cleanup() }
        let lifecyclePlan = String(repeating: "d", count: 64)
        let result = try await fixture.coordinator()
            .applyPolicy(
                volumeID: fixture.record.id,
                authorizedLifecyclePlanSHA256:
                    lifecyclePlan,
                client: fixture.client
            )
        XCTAssertEqual(
            try report(result)["planSHA256"] as? String,
            lifecyclePlan
        )
        XCTAssertTrue(try fixture.provider.list().volumes.isEmpty)
        let replayed = try await fixture.coordinator()
            .applyPolicy(
                volumeID: fixture.record.id,
                authorizedLifecyclePlanSHA256:
                    lifecyclePlan,
                client: fixture.client
            )
        XCTAssertEqual(
            try report(replayed)["disposition"] as? String,
            "already-satisfied"
        )
        XCTAssertEqual(
            try report(replayed)["planSHA256"] as? String,
            lifecyclePlan
        )

        let retained = try await makeFixture(
            suffix: "09",
            reclaimPolicy: .retain
        )
        defer { retained.cleanup() }
        let retainedResult = try await retained.coordinator()
            .applyPolicy(
                volumeID: retained.record.id,
                authorizedLifecyclePlanSHA256:
                    lifecyclePlan,
                client: retained.client
            )
        XCTAssertEqual(
            try report(retainedResult)["disposition"]
                as? String,
            "retained"
        )
        XCTAssertEqual(
            try retained.provider.list().volumes.map(\.volumeID),
            [retained.record.id]
        )
    }

    func testVolumeDeleteCommandRoutesThroughReclaimCoordinator()
        async throws
    {
        let fixture = try await makeFixture(
            suffix: "10",
            reclaimPolicy: .delete
        )
        defer { fixture.cleanup() }

        let dryRun = HostwrightCLI.run(
            arguments: [
                "volume", "delete", fixture.record.id,
                "--dry-run",
                "--state-db", fixture.statePath,
                "--json",
            ],
            environment: fixture.environment
        )
        XCTAssertEqual(dryRun.exitCode, 0, dryRun.standardError)
        let plan = try planSHA256(dryRun)
        let deleted = HostwrightCLI.run(
            arguments: [
                "volume", "delete", fixture.record.id,
                "--confirm-plan", plan,
                "--state-db", fixture.statePath,
                "--json",
            ],
            environment: fixture.environment
        )
        XCTAssertEqual(deleted.exitCode, 0, deleted.standardError)
        XCTAssertTrue(try fixture.provider.list().volumes.isEmpty)
        XCTAssertEqual(
            try fixture.repository.loadVolume(
                id: fixture.record.id
            )?.lifecycleState,
            .deleted
        )
    }

    func testPrerequisiteArtifactsAreFreshlyVerifiedBeforeDelete()
        async throws
    {
        let snapshot = try await makeFixture(
            suffix: "13",
            reclaimPolicy: .snapshotBeforeDelete
        )
        defer { snapshot.cleanup() }
        let snapshotID =
            "dd000000-0000-4000-8000-000000000013"
        let snapshotResult: LocalStorageSnapshotResult =
            try await snapshot.client.invoke(
                operation: .snapshot,
                mutationContext: snapshot.providerContext,
                idempotencyKey:
                    sha256("snapshot:\(snapshotID)"),
                payload: LocalStorageSnapshotPayload(
                    snapshotID: snapshotID,
                    name: "before-delete"
                ),
                result: LocalStorageSnapshotResult.self
            )
        try snapshot.repository.saveSnapshot(
            StorageStateSnapshotRecord(
                id: snapshotID,
                name: "before-delete",
                sourceVolumeID: snapshot.record.id,
                providerID: snapshot.record.providerID,
                providerSnapshotID: snapshotID,
                consistencyClass:
                    snapshotResult.consistencyClass,
                parentContentTreeSHA256:
                    snapshotResult
                        .parentContentTreeSHA256,
                contentTreeSHA256:
                    snapshotResult.contentTreeSHA256,
                lineage: snapshotResult.lineage,
                generation: 1,
                fencingToken:
                    snapshot.record.fencingToken,
                sizeBytes: snapshot.record.capacityBytes,
                lifecycleState: .ready,
                operationGroupID:
                    snapshot.initialGroupID,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.createdAt
            )
        )
        _ = try await snapshot.coordinator().delete(
            volumeID: snapshot.record.id,
            confirmation: .init(
                dryRun: true,
                confirmationPlanSHA256: nil
            ),
            client: snapshot.client
        )
        let _: LocalStorageSnapshotResult =
            try await snapshot.client.invoke(
                operation: .snapshot,
                mutationContext: snapshot.providerContext,
                idempotencyKey:
                    sha256("remove:\(snapshotID)"),
                payload: LocalStorageSnapshotPayload(
                    action: .delete,
                    snapshotID: snapshotID,
                    expectedContentTreeSHA256:
                        snapshotResult.contentTreeSHA256
                ),
                result: LocalStorageSnapshotResult.self
            )
        await assertDeleteRefused(
            snapshot,
            code: .storageConflict
        )

        let backup = try await makeFixture(
            suffix: "14",
            reclaimPolicy: .backupBeforeDelete
        )
        defer { backup.cleanup() }
        let valueURL = URL(
            fileURLWithPath:
                try backup.provider.inspect(
                    volumeID: backup.record.id
                ).dataPath
        ).appendingPathComponent("value.txt")
        try Data("before-delete".utf8).write(to: valueURL)
        let backupID =
            "ee000000-0000-4000-8000-000000000014"
        let keyReference =
            "keychain://hostwright-tests/reclaim"
        let backupResult: LocalStorageBackupResult =
            try await backup.client.invoke(
                operation: .backup,
                mutationContext: backup.providerContext,
                idempotencyKey:
                    sha256("backup:\(backupID)"),
                payload: LocalStorageBackupPayload(
                    backupID: backupID,
                    name: "before-delete",
                    keyReference: keyReference,
                    volumes: [
                        LocalStorageBackupVolumePayload(
                            volumeID: backup.record.id,
                            generation: 1,
                            fencingToken:
                                backup.record.fencingToken
                        ),
                    ]
                ),
                result: LocalStorageBackupResult.self
            )
        try backup.repository.saveBackup(
            StorageStateBackupRecord(
                id: backupID,
                volumeID: backup.record.id,
                snapshotID: nil,
                destinationRedacted:
                    "hostwright-local://[REDACTED]",
                contentSHA256:
                    backupResult.manifestSHA256,
                sizeBytes: backup.record.capacityBytes,
                generation: 1,
                fencingToken:
                    backup.record.fencingToken,
                lifecycleState: .ready,
                operationGroupID: backup.initialGroupID,
                createdAt: backup.createdAt,
                updatedAt: backup.createdAt
            )
        )
        _ = try await backup.coordinator().delete(
            volumeID: backup.record.id,
            confirmation: .init(
                dryRun: true,
                confirmationPlanSHA256: nil
            ),
            client: backup.client
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            StorageBackupRecord.self,
            from: Data(
                contentsOf:
                    backup.providerRoot
                        .appendingPathComponent(
                            "backups/sets/\(backupID)/manifest.json"
                        )
            )
        )
        let chunk = try XCTUnwrap(
            manifest.volumes.first?.chunkDigest
        )
        let chunkRecord = try decoder.decode(
            StorageBackupChunkRecord.self,
            from: Data(
                contentsOf:
                    backup.providerRoot
                        .appendingPathComponent(
                            "backups/chunks/\(chunk)/chunk.json"
                        )
            )
        )
        let blob = try XCTUnwrap(
            chunkRecord.entries.compactMap(\.blob).first
        )
        try Data("tampered".utf8).write(
            to: backup.providerRoot.appendingPathComponent(
                "backups/chunks/\(chunk)/blobs/\(blob.blobID)"
            )
        )
        await assertDeleteRefused(
            backup,
            code: .storageConflict
        )
    }

    func testPruneResolvesStaleTrackedOrphanMetadata() async throws {
        let fixture = try await makeFixture(
            suffix: "12",
            reclaimPolicy: .delete
        )
        defer { fixture.cleanup() }
        let hash = orphanResourceHash(
            providerID: LocalStorageProviderContract.providerID,
            providerVolumeID: fixture.record.id
        )
        try fixture.repository.saveOrphan(
            StorageStateOrphanRecord(
                id: "cc000000-0000-4000-8000-000000000012",
                providerID: LocalStorageProviderContract.providerID,
                resourceKind: .volume,
                providerResourceIDHash: hash,
                ownershipProofSHA256: nil,
                generation: 1,
                fencingToken: fixture.fence.uuidString.lowercased(),
                lifecycleState: .held,
                operationGroupID: fixture.initialGroupID,
                discoveredAt: fixture.createdAt,
                resolvedAt: nil
            )
        )

        let coordinator = fixture.coordinator()
        let dryRun = try await coordinator.prune(
            confirmation: .init(
                dryRun: true,
                confirmationPlanSHA256: nil
            ),
            client: fixture.client
        )
        let plan = try planSHA256(dryRun)
        let result = try await coordinator.prune(
            confirmation: .init(
                dryRun: false,
                confirmationPlanSHA256: plan
            ),
            client: fixture.client
        )

        XCTAssertEqual(
            try report(result)["disposition"] as? String,
            "performed"
        )
        let orphan = try XCTUnwrap(
            try fixture.repository.loadOrphans(
                providerID: LocalStorageProviderContract.providerID
            ).first
        )
        XCTAssertEqual(orphan.lifecycleState, .ignored)
        XCTAssertNotNil(orphan.resolvedAt)
    }

    private struct Fixture {
        let root: URL
        let providerRoot: URL
        let statePath: String
        let provider: LocalStorageProvider
        let client: StorageProviderClient
        let environment: CLIEnvironment
        let store: SQLiteStateStore
        let repository: StorageStateRepository
        let record: StorageStateVolumeRecord
        let projectUUID: UUID
        let fence: UUID
        let providerContext: StorageProviderMutationContext
        let initialGroupID: String
        let createdAt: String
        let now: Int64

        func coordinator(
            now override: Int64? = nil
        ) -> StorageReclaimCommandCoordinator {
            StorageReclaimCommandCoordinator(
                options: StorageCLIOptions(
                    action: .delete(
                        volumeID: record.id,
                        confirmation: .init(
                            dryRun: true,
                            confirmationPlanSHA256: nil
                        )
                    ),
                    stateDatabasePath: statePath,
                    timeoutSeconds: 30,
                    output: .json
                ),
                environment: environment,
                nowUnixMilliseconds: {
                    override ?? now
                }
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture(
        suffix: String,
        reclaimPolicy: StorageReclaimPolicy,
        lifecycleState:
            StorageVolumeLifecycleState = .available,
        now: Int64 = 2_000_000_000_000
    ) async throws -> Fixture {
        let root = try temporaryRoot(suffix: suffix)
        let providerRoot = root.appendingPathComponent(
            "provider",
            isDirectory: true
        )
        let statePath = root.appendingPathComponent(
            "state.sqlite3"
        ).path
        let provider = try LocalStorageProvider(
            rootURL: providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024,
            backupKeyResolver:
                ReclaimBackupKeyResolver()
        )
        let client = try StorageProviderClient(
            provider: provider,
            requestTimeoutMilliseconds: 30_000
        )
        let logicalProjectID = "project-\(suffix)"
        let projectUUID = UUID(
            uuidString: HostwrightResourceUUID.legacy(
                kind: "project",
                identifier: logicalProjectID
            )
        )!
        let volumeID =
            "11000000-0000-4000-8000-0000000000\(suffix)"
        let fence = UUID(
            uuidString:
                "ff000000-0000-4000-8000-0000000000\(suffix)"
        )!
        let providerContext = StorageProviderMutationContext(
            projectUUID: projectUUID,
            projectGeneration: 1,
            resourceUUID: UUID(uuidString: volumeID)!,
            resourceGeneration: 1,
            fencingToken: fence
        )
        let _: LocalStorageMutationResult =
            try await client.invoke(
                operation: .create,
                mutationContext: providerContext,
                idempotencyKey:
                    sha256("create:\(volumeID)"),
                payload: LocalStorageCreatePayload(
                    name: "volume-\(suffix)",
                    capacityBytes: 1_048_576,
                    retention:
                        reclaimPolicy == .retain ||
                            reclaimPolicy == .recycle
                            ? .retain
                            : .deleteWhenUnused
                ),
                result: LocalStorageMutationResult.self
            )

        let store = SQLiteStateStore(path: statePath)
        try store.migrate()
        let repository = StorageStateRepository(store: store)
        let initialGroupID =
            "aa000000-0000-4000-8000-0000000000\(suffix)"
        let createdAt = "2026-07-25T12:00:00Z"
        let group = OperationGroupRecord(
            id: initialGroupID,
            operationID: initialGroupID,
            groupKind: "storage-volume",
            projectID: logicalProjectID,
            serviceName: nil,
            plannedActionType: "create",
            status: .active,
            groupIdempotencyKey:
                sha256("state:\(volumeID)"),
            planHash: String(repeating: "a", count: 64),
            checkpoint: "provider-observed",
            lockOwner: "test",
            lockExpiresAt: "2035-01-01T00:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: createdAt,
            updatedAt: createdAt,
            metadataJSONRedacted: "{}",
            fencingToken:
                fence.uuidString.lowercased(),
            intentJSONRedacted: "{}",
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        XCTAssertNotNil(
            try store.operationGroups.acquire(
                group,
                currentTimestamp: createdAt
            ).acquired
        )
        let record = StorageStateVolumeRecord(
            id: volumeID,
            projectID: logicalProjectID,
            name: "volume-\(suffix)",
            providerID:
                LocalStorageProviderContract.providerID,
            providerVolumeID: volumeID,
            topologyNodeID: "local-apple-silicon",
            generation: 1,
            fencingToken:
                fence.uuidString.lowercased(),
            capacityBytes: 1_048_576,
            lifecycleState: lifecycleState,
            reclaimPolicy: reclaimPolicy,
            accessMode: .readWriteOnce,
            operationGroupID: initialGroupID,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try repository.saveVolume(record)
        try store.operationGroups.finish(
            groupID: initialGroupID,
            status: .succeeded,
            checkpoint: "state-committed",
            manualRecoveryHintRedacted: "",
            updatedAt: "2026-07-25T12:00:01Z",
            metadataJSONRedacted: "{}"
        )
        let environment = CLIEnvironment(
            fileExists: {
                FileManager.default.fileExists(atPath: $0)
            },
            readTextFile: {
                try String(
                    contentsOfFile: $0,
                    encoding: .utf8
                )
            },
            writeTextFile: { path, text in
                try text.write(
                    toFile: path,
                    atomically: true,
                    encoding: .utf8
                )
            },
            executablePath: { _ in nil },
            storageProvider: { provider },
            storageProviderRootURL: { providerRoot },
            swiftVersion: { "Swift test" },
            platformSnapshot: {
                PlatformSnapshot(
                    macOSMajorVersion: 26,
                    architecture: "arm64"
                )
            },
            operatingSystemDescription: { "macOS test" }
        )
        return Fixture(
            root: root,
            providerRoot: providerRoot,
            statePath: statePath,
            provider: provider,
            client: client,
            environment: environment,
            store: store,
            repository: repository,
            record: record,
            projectUUID: projectUUID,
            fence: fence,
            providerContext: providerContext,
            initialGroupID: initialGroupID,
            createdAt: createdAt,
            now: now
        )
    }

    private func assertDeleteRefused(
        _ fixture: Fixture,
        code: HostwrightErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await XCTAssertThrowsErrorAsync(
            try await fixture.coordinator().delete(
                volumeID: fixture.record.id,
                confirmation: .init(
                    dryRun: true,
                    confirmationPlanSHA256: nil
                ),
                client: fixture.client
            ),
            file: file,
            line: line
        ) {
            XCTAssertEqual(
                ($0 as? HostwrightDiagnostic)?.code,
                code,
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            try? fixture.provider.list().volumes
                .map(\.volumeID),
            [fixture.record.id],
            file: file,
            line: line
        )
    }

    private func addDeletedVolume(
        to fixture: Fixture,
        volumeID: String,
        name: String,
        fence: String
    ) async throws -> StorageStateVolumeRecord {
        let context = StorageProviderMutationContext(
            projectUUID: fixture.projectUUID,
            projectGeneration: 1,
            resourceUUID: UUID(uuidString: volumeID)!,
            resourceGeneration: 1,
            fencingToken: UUID(uuidString: fence)!
        )
        let _: LocalStorageMutationResult =
            try await fixture.client.invoke(
                operation: .create,
                mutationContext: context,
                idempotencyKey:
                    sha256("create:\(volumeID)"),
                payload: LocalStorageCreatePayload(
                    name: name,
                    capacityBytes: 1_048_576,
                    retention: .deleteWhenUnused
                ),
                result: LocalStorageMutationResult.self
            )
        let operationGroupID =
            HostwrightResourceUUID.legacy(
                kind: "storage-test-create",
                identifier: volumeID
            )
        let group = OperationGroupRecord(
            id: operationGroupID,
            operationID: operationGroupID,
            groupKind: "storage-volume",
            projectID: fixture.record.projectID,
            serviceName: nil,
            plannedActionType: "create",
            status: .active,
            groupIdempotencyKey:
                sha256("state:\(volumeID)"),
            planHash: String(repeating: "a", count: 64),
            checkpoint: "provider-observed",
            lockOwner: "test",
            lockExpiresAt: "2035-01-01T00:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: fixture.createdAt,
            updatedAt: fixture.createdAt,
            metadataJSONRedacted: "{}",
            fencingToken: fence,
            intentJSONRedacted: "{}",
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        XCTAssertNotNil(
            try fixture.store.operationGroups.acquire(
                group,
                currentTimestamp: fixture.createdAt
            ).acquired
        )
        let record = StorageStateVolumeRecord(
            id: volumeID,
            projectID: fixture.record.projectID,
            name: name,
            providerID:
                LocalStorageProviderContract.providerID,
            providerVolumeID: volumeID,
            topologyNodeID: "local-apple-silicon",
            generation: 1,
            fencingToken: fence,
            capacityBytes: 1_048_576,
            lifecycleState: .deleted,
            reclaimPolicy: .delete,
            accessMode: .readWriteOnce,
            operationGroupID: operationGroupID,
            createdAt: fixture.createdAt,
            updatedAt: fixture.createdAt
        )
        try fixture.repository.saveVolume(record)
        try fixture.store.operationGroups.finish(
            groupID: operationGroupID,
            status: .succeeded,
            checkpoint: "state-committed",
            manualRecoveryHintRedacted: "",
            updatedAt: fixture.createdAt,
            metadataJSONRedacted: "{}"
        )
        return record
    }

    private func saveAgedOrphan(
        _ volume: StorageStateVolumeRecord,
        orphanID: String,
        in fixture: Fixture,
        now: Int64
    ) throws {
        try fixture.repository.saveOrphan(
            StorageStateOrphanRecord(
                id: orphanID,
                providerID: volume.providerID,
                resourceKind: .volume,
                providerResourceIDHash:
                    orphanResourceHash(
                        providerID: volume.providerID,
                        providerVolumeID:
                            volume.providerVolumeID
                    ),
                ownershipProofSHA256: nil,
                generation: 1,
                fencingToken: volume.fencingToken,
                lifecycleState: .discovered,
                operationGroupID: volume.operationGroupID,
                discoveredAt:
                    timestamp(
                        now - 2 * 60 * 60 * 1_000
                    ),
                resolvedAt: nil
            )
        )
    }

    private func report(
        _ result: CLIRunResult
    ) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(result.standardOutput.utf8)
            ) as? [String: Any]
        )
    }

    private func planSHA256(
        _ result: CLIRunResult
    ) throws -> String {
        try XCTUnwrap(
            try report(result)["planSHA256"] as? String
        )
    }

    private func temporaryRoot(suffix: String) throws -> URL {
        let raw = FileManager.default.temporaryDirectory.path
        let canonical = raw.hasPrefix("/var/")
            ? "/private\(raw)"
            : raw
        let root = URL(
            fileURLWithPath: canonical,
            isDirectory: true
        ).appendingPathComponent(
            "hostwright-storage-reclaim-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func orphanResourceHash(
        providerID: String,
        providerVolumeID: String
    ) -> String {
        sha256(
            [
                "hostwright.storage.orphan-resource-id.v1",
                providerID,
                "volume",
                providerVolumeID,
            ].joined(separator: "\n")
        )
    }

    private func timestamp(_ milliseconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(
            from: Date(
                timeIntervalSince1970:
                    TimeInterval(milliseconds) / 1_000
            )
        )
    }

    private func sha256(_ value: String) -> String {
        Self.sha256(value)
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct ReclaimBackupKeyResolver:
    StorageBackupKeyResolver
{
    func resolveKey(
        reference: HostwrightSecretReference
    ) throws -> SymmetricKey {
        SymmetricKey(
            data: Data(
                SHA256.hash(
                    data: Data(
                        "reclaim-backup-test-key".utf8
                    )
                )
            )
        )
    }
}

private extension StorageStateVolumeRecord {
    func replacing(
        generation: Int64,
        fencingToken: String,
        lifecycleState: StorageVolumeLifecycleState,
        operationGroupID: String,
        updatedAt: String
    ) -> StorageStateVolumeRecord {
        StorageStateVolumeRecord(
            id: id,
            projectID: projectID,
            name: name,
            providerID: providerID,
            providerVolumeID: providerVolumeID,
            topologyNodeID: topologyNodeID,
            generation: generation,
            fencingToken: fencingToken,
            capacityBytes: capacityBytes,
            lifecycleState: lifecycleState,
            reclaimPolicy: reclaimPolicy,
            accessMode: accessMode,
            sourceKind: sourceKind,
            sourceID: sourceID,
            operationGroupID: operationGroupID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(
            "Expected expression to throw.",
            file: file,
            line: line
        )
    } catch {
        handler(error)
    }
}

private enum InjectedPruneInterruption: Error {
    case afterProviderDelete
}

private actor FailAfterFirstDeleteStorageProvider:
    StorageProviderSPI
{
    private let provider: LocalStorageProvider
    private var injected = false

    init(provider: LocalStorageProvider) {
        self.provider = provider
    }

    func descriptor() async throws -> StorageProviderDescriptor {
        try await provider.descriptor()
    }

    func invoke(canonicalRequest: Data) async throws -> Data {
        let deleteRequest =
            try? StorageProviderCanonicalJSON.decodeRequest(
                LocalStorageDeletePayload.self,
                from: canonicalRequest
            )
        let response = try await provider.invoke(
            canonicalRequest: canonicalRequest
        )
        if deleteRequest?.operation == .delete,
           !injected {
            injected = true
            throw InjectedPruneInterruption
                .afterProviderDelete
        }
        return response
    }

    func cancel(requestID: UUID) async {
        await provider.cancel(requestID: requestID)
    }
}
