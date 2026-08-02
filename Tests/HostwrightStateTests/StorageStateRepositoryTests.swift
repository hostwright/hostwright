import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightState
@testable import HostwrightStorage

final class StorageStateRepositoryTests: XCTestCase {
    private let volumeID = "11111111-1111-4111-8111-111111111111"
    private let attachmentID =
        "22222222-2222-4222-8222-222222222222"
    private let snapshotID =
        "33333333-3333-4333-8333-333333333333"
    private let backupID = "44444444-4444-4444-8444-444444444444"
    private let holdID = "55555555-5555-4555-8555-555555555555"
    private let orphanID = "66666666-6666-4666-8666-666666666666"

    func testSchemaV14MigratesAdditivelyToV15StorageState() throws {
        try withStore(throughVersion: 14) { store in
            XCTAssertEqual(try store.schemaVersion(), 14)
            let before = try tableNames(store)
            XCTAssertFalse(before.contains("storage_volumes"))

            try store.migrate()

            XCTAssertEqual(
                try store.schemaVersion(),
                HostwrightContractVersions.stateSchema
            )
            XCTAssertEqual(HostwrightContractVersions.stateSchema, 17)
            XCTAssertEqual(
                try migrationVersions(store),
                Array(1...HostwrightContractVersions.stateSchema)
            )
            XCTAssertEqual(
                Set(try tableNames(store).filter {
                    $0.hasPrefix("storage_")
                }),
                Set([
                    "storage_volumes",
                    "storage_attachments",
                    "storage_snapshots",
                    "storage_backups",
                    "storage_holds",
                    "storage_orphans",
                    "storage_capacity_samples",
                    "storage_quotas",
                    "storage_capacity_admissions"
                ])
            )
            XCTAssertEqual(
                StateIntegrityService(store: store).inspect().health,
                .healthy
            )
        }
    }

    func testCapacityQuotaAndAdmissionPersistAcrossReopen()
        throws
    {
        try withStore { store in
            let firstGroup = try operationGroup(
                store: store,
                suffix: "81"
            )
            let sample = try capacitySample(
                id: "91000000-0000-4000-8000-000000000001"
            )
            let sampleRecord = StorageStateCapacitySampleRecord(
                sample: sample,
                pressureLevel: .normal,
                fencingToken: firstGroup.fence,
                operationGroupID: firstGroup.id,
                createdAt: "2026-07-25T12:00:00Z"
            )
            XCTAssertEqual(
                try store.storage.saveCapacitySample(sampleRecord),
                sampleRecord
            )
            XCTAssertEqual(
                try store.storage.latestCapacitySample(
                    providerID: "local-apfs",
                    topologyNodeID: "dev-mbp"
                ),
                sampleRecord
            )

            let quota = StorageStateQuotaRecord(
                id: "92000000-0000-4000-8000-000000000001",
                resourceID: volumeID,
                providerID: "local-apfs",
                byteLimit: 8_192,
                inodeLimit: 512,
                enforcementMode: .logical,
                enforcementEvidenceSHA256: nil,
                generation: 1,
                fencingToken: firstGroup.fence,
                lifecycleState: .active,
                retryAttempt: 1,
                recoveryCheckpoint: .admitted,
                operationID:
                    "93000000-0000-4000-8000-000000000001",
                idempotencyKey: String(repeating: "a", count: 64),
                operationGroupID: firstGroup.id,
                createdAt: "2026-07-25T12:00:00Z",
                updatedAt: "2026-07-25T12:00:00Z"
            )
            XCTAssertEqual(
                try store.storage.saveQuota(quota),
                quota
            )

            let request = try StorageCapacityAdmissionRequest(
                operationID:
                    "94000000-0000-4000-8000-000000000001",
                idempotencyKey: String(repeating: "b", count: 64),
                action: .create,
                additionalBytes: 1_024,
                additionalInodes: 1,
                writable: true
            )
            let result = StorageCapacityPolicy().evaluate(
                request,
                sample: sample,
                previousPressure: .normal,
                atUnixMilliseconds: 1_001_000
            )
            let admission = StorageStateCapacityAdmissionRecord(
                id: "95000000-0000-4000-8000-000000000001",
                sampleID: sample.id,
                sampleDigestSHA256: sample.digestSHA256,
                action: request.action,
                additionalBytes: request.additionalBytes,
                additionalInodes: request.additionalInodes,
                writable: request.writable,
                result: result,
                maximumAttempts: request.maximumAttempts,
                fencingToken: firstGroup.fence,
                operationGroupID: firstGroup.id,
                createdAt: "2026-07-25T12:00:01Z"
            )
            XCTAssertEqual(
                try store.storage.saveCapacityAdmission(admission),
                admission
            )

            let reopened = SQLiteStateStore(path: store.path)
            try reopened.validateSchema()
            XCTAssertEqual(
                try reopened.storage.loadCapacitySample(
                    id: sample.id
                ),
                sampleRecord
            )
            XCTAssertEqual(
                try reopened.storage.loadQuota(id: quota.id),
                quota
            )
            XCTAssertEqual(
                try reopened.storage.latestCapacityAdmission(
                    operationID: result.operationID
                ),
                admission
            )
            XCTAssertEqual(
                StateIntegrityService(store: reopened).inspect().health,
                .healthy
            )

            let secondGroup = try operationGroup(
                store: store,
                suffix: "82"
            )
            let replacement = StorageStateQuotaRecord(
                id: quota.id,
                resourceID: quota.resourceID,
                providerID: quota.providerID,
                byteLimit: 16_384,
                inodeLimit: quota.inodeLimit,
                enforcementMode: .logical,
                enforcementEvidenceSHA256: nil,
                generation: 2,
                fencingToken: secondGroup.fence,
                lifecycleState: .active,
                retryAttempt: 1,
                recoveryCheckpoint: .admitted,
                operationID:
                    "93000000-0000-4000-8000-000000000002",
                idempotencyKey: String(repeating: "c", count: 64),
                operationGroupID: secondGroup.id,
                createdAt: quota.createdAt,
                updatedAt: "2026-07-25T12:01:00Z"
            )
            XCTAssertThrowsError(
                try store.storage.saveQuota(
                    replacement,
                    replacing: StorageStateExpectedVersion(
                        generation: 1,
                        fencingToken:
                            "ffffffff-ffff-4fff-8fff-ffffffffffff"
                    )
                )
            )
            XCTAssertEqual(
                try store.storage.saveQuota(
                    replacement,
                    replacing: StorageStateExpectedVersion(
                        generation: 1,
                        fencingToken: quota.fencingToken
                    )
                ),
                replacement
            )
        }
    }

    func testCapacityRetryLedgerIsBoundedAndResumable()
        throws
    {
        try withStore { store in
            let group = try operationGroup(
                store: store,
                suffix: "83"
            )
            let sample = try capacitySample(
                id: "91000000-0000-4000-8000-000000000002",
                capturedAt: 1_000,
                validUntil: 2_000
            )
            _ = try store.storage.saveCapacitySample(
                StorageStateCapacitySampleRecord(
                    sample: sample,
                    pressureLevel: .normal,
                    fencingToken: group.fence,
                    operationGroupID: group.id,
                    createdAt: "2026-07-25T12:00:00Z"
                )
            )
            let operationID =
                "94000000-0000-4000-8000-000000000002"
            let idempotency = String(repeating: "d", count: 64)
            var saved: [StorageStateCapacityAdmissionRecord] = []
            for attempt in 1...3 {
                let request = try StorageCapacityAdmissionRequest(
                    operationID: operationID,
                    idempotencyKey: idempotency,
                    action: .create,
                    additionalBytes: 1,
                    additionalInodes: 1,
                    writable: true,
                    attempt: attempt
                )
                let result = StorageCapacityPolicy().evaluate(
                    request,
                    sample: sample,
                    previousPressure: .normal,
                    atUnixMilliseconds: 3_000
                )
                let record =
                    StorageStateCapacityAdmissionRecord(
                        id:
                            "95000000-0000-4000-8000-00000000000\(attempt + 1)",
                        sampleID: sample.id,
                        sampleDigestSHA256: sample.digestSHA256,
                        action: request.action,
                        additionalBytes: request.additionalBytes,
                        additionalInodes: request.additionalInodes,
                        writable: request.writable,
                        result: result,
                        maximumAttempts: request.maximumAttempts,
                        fencingToken: group.fence,
                        operationGroupID: group.id,
                        createdAt:
                            "2026-07-25T12:00:0\(attempt)Z"
                    )
                saved.append(
                    try store.storage.saveCapacityAdmission(record)
                )
            }
            XCTAssertEqual(saved[0].result.reason, .staleSample)
            XCTAssertEqual(
                saved[0].result.retryDisposition,
                .afterFreshSample
            )
            XCTAssertEqual(saved[2].result.reason, .retryExhausted)
            XCTAssertEqual(
                saved[2].result.retryDisposition,
                .never
            )
            XCTAssertEqual(
                try store.storage.loadCapacityAdmissions(
                    operationID: operationID
                ),
                saved
            )
            XCTAssertThrowsError(
                try StorageCapacityAdmissionRequest(
                    operationID: operationID,
                    idempotencyKey: idempotency,
                    action: .create,
                    additionalBytes: 1,
                    additionalInodes: 1,
                    writable: true,
                    attempt: 4
                )
            )

            let duplicate = StorageStateCapacityAdmissionRecord(
                id: "95000000-0000-4000-8000-000000000009",
                sampleID: saved[1].sampleID,
                sampleDigestSHA256:
                    saved[1].sampleDigestSHA256,
                action: saved[1].action,
                additionalBytes: saved[1].additionalBytes,
                additionalInodes: saved[1].additionalInodes,
                writable: saved[1].writable,
                result: saved[1].result,
                maximumAttempts: saved[1].maximumAttempts,
                fencingToken: saved[1].fencingToken,
                operationGroupID: saved[1].operationGroupID,
                createdAt: "2026-07-25T12:00:09Z"
            )
            XCTAssertThrowsError(
                try store.storage.saveCapacityAdmission(duplicate)
            )
        }
    }

    func testHardQuotaCannotBeRecordedWithoutEvidence() throws {
        try withStore { store in
            let group = try operationGroup(
                store: store,
                suffix: "84"
            )
            let record = StorageStateQuotaRecord(
                id: "92000000-0000-4000-8000-000000000002",
                resourceID: volumeID,
                providerID: "local-apfs",
                byteLimit: 1_024,
                inodeLimit: nil,
                enforcementMode: .hard,
                enforcementEvidenceSHA256: nil,
                generation: 1,
                fencingToken: group.fence,
                lifecycleState: .active,
                retryAttempt: 1,
                recoveryCheckpoint: .admitted,
                operationID:
                    "93000000-0000-4000-8000-000000000003",
                idempotencyKey: String(repeating: "e", count: 64),
                operationGroupID: group.id,
                createdAt: "2026-07-25T12:00:00Z",
                updatedAt: "2026-07-25T12:00:00Z"
            )
            XCTAssertThrowsError(
                try store.storage.saveQuota(record)
            )
        }
    }

    func testVolumeSaveIsIdempotentAndReplacementRequiresExactFence()
        throws
    {
        try withStore { store in
            let firstGroup = try operationGroup(
                store: store,
                suffix: "01"
            )
            let first = volume(
                fence: firstGroup.fence,
                operationGroupID: firstGroup.id
            )
            XCTAssertEqual(try store.storage.saveVolume(first), first)
            XCTAssertEqual(try store.storage.saveVolume(first), first)
            XCTAssertEqual(
                try store.storage.loadVolume(id: volumeID),
                first
            )
            XCTAssertEqual(
                try store.storage.allocatedCapacityBytes(
                    topologyNodeID: "dev-mbp"
                ),
                1_024
            )

            let secondGroup = try operationGroup(
                store: store,
                suffix: "02"
            )
            let second = volume(
                generation: 2,
                fence: secondGroup.fence,
                capacityBytes: 2_048,
                lifecycleState: .available,
                operationGroupID: secondGroup.id
            )
            XCTAssertThrowsError(
                try store.storage.saveVolume(
                    second,
                    replacing: StorageStateExpectedVersion(
                        generation: 1,
                        fencingToken:
                            "ffffffff-ffff-4fff-8fff-ffffffffffff"
                    )
                )
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "lost its exact generation or fence"
                    )
                )
            }

            XCTAssertEqual(
                try store.storage.saveVolume(
                    second,
                    replacing: StorageStateExpectedVersion(
                        generation: 1,
                        fencingToken: first.fencingToken
                    )
                ),
                second
            )
            XCTAssertEqual(
                try store.storage.allocatedCapacityBytes(
                    topologyNodeID: "dev-mbp"
                ),
                2_048
            )
        }
    }

    func testTerminalOperationGroupRetainsFencedRecoveryState() throws {
        try withStore { store in
            let group = try operationGroup(store: store, suffix: "03")
            let record = volume(
                fence: group.fence,
                lifecycleState: .faulted,
                operationGroupID: group.id
            )
            _ = try store.storage.saveVolume(record)

            try store.operationGroups.finish(
                groupID: group.id,
                status: .interrupted,
                checkpoint: "observation-required",
                manualRecoveryHintRedacted:
                    "re-observe before resuming storage operation",
                updatedAt: "2026-07-25T12:10:00Z",
                metadataJSONRedacted: "{}"
            )

            XCTAssertEqual(
                try store.storage.loadVolume(id: volumeID),
                record
            )
            XCTAssertEqual(
                StateIntegrityService(store: store).inspect().health,
                .healthy
            )
        }
    }

    func testAttachmentSnapshotBackupHoldAndOrphanRoundTrip() throws {
        try withStore { store in
            let volumeGroup = try operationGroup(
                store: store,
                suffix: "10"
            )
            _ = try store.storage.saveVolume(
                volume(
                    fence: volumeGroup.fence,
                    operationGroupID: volumeGroup.id
                )
            )

            let attachmentGroup = try operationGroup(
                store: store,
                suffix: "11"
            )
            let attachment = StorageStateAttachmentRecord(
                id: attachmentID,
                volumeID: volumeID,
                nodeID: "dev-mbp",
                nodeUUID:
                    "99999999-9999-4999-8999-999999999999",
                workloadUUID:
                    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                kind: .stage,
                path: "/var/tmp/hostwright/storage/stage",
                stagingPath: nil,
                accessMode: .readWriteOnce,
                readOnly: false,
                generation: 1,
                fencingToken: attachmentGroup.fence,
                lifecycleState: .attaching,
                checkpoint: .attachIntentPersisted,
                leaseRenewedAt: "2026-07-25T12:01:00Z",
                leaseExpiresAt: "2026-07-25T12:06:00Z",
                operationID:
                    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                idempotencyKey: String(repeating: "c", count: 64),
                providerObservationSHA256: nil,
                forceDetachAuthorizationSHA256: nil,
                ambiguousHoldReasonRedacted: nil,
                operationGroupID: attachmentGroup.id,
                createdAt: "2026-07-25T12:01:00Z",
                updatedAt: "2026-07-25T12:01:00Z"
            )
            XCTAssertEqual(
                try store.storage.saveAttachment(attachment),
                attachment
            )
            XCTAssertEqual(
                try store.storage.loadAttachments(volumeID: volumeID),
                [attachment]
            )

            let snapshotGroup = try operationGroup(
                store: store,
                suffix: "12"
            )
            let snapshot = StorageStateSnapshotRecord(
                id: snapshotID,
                name: "database-snapshot",
                sourceVolumeID: volumeID,
                providerID: "local-apfs",
                providerSnapshotID: "provider-snapshot-1",
                consistencyClass: .applicationConsistent,
                parentContentTreeSHA256:
                    String(repeating: "d", count: 64),
                contentTreeSHA256:
                    String(repeating: "e", count: 64),
                lineage: ["volume:\(volumeID)@1"],
                generation: 1,
                fencingToken: snapshotGroup.fence,
                sizeBytes: 1_024,
                lifecycleState: .ready,
                operationGroupID: snapshotGroup.id,
                createdAt: "2026-07-25T12:02:00Z",
                updatedAt: "2026-07-25T12:02:00Z"
            )
            XCTAssertEqual(
                try store.storage.saveSnapshot(snapshot),
                snapshot
            )
            XCTAssertEqual(
                try store.storage.loadSnapshots(
                    sourceVolumeID: volumeID
                ),
                [snapshot]
            )

            let backupGroup = try operationGroup(
                store: store,
                suffix: "13"
            )
            let backup = StorageStateBackupRecord(
                id: backupID,
                volumeID: volumeID,
                snapshotID: snapshotID,
                destinationRedacted:
                    "file:///Volumes/T9/hostwright-backup",
                contentSHA256: String(repeating: "a", count: 64),
                sizeBytes: 1_024,
                generation: 1,
                fencingToken: backupGroup.fence,
                lifecycleState: .ready,
                operationGroupID: backupGroup.id,
                createdAt: "2026-07-25T12:03:00Z",
                updatedAt: "2026-07-25T12:03:00Z"
            )
            XCTAssertEqual(try store.storage.saveBackup(backup), backup)
            XCTAssertEqual(
                try store.storage.loadBackups(volumeID: volumeID),
                [backup]
            )

            let holdGroup = try operationGroup(
                store: store,
                suffix: "14"
            )
            let hold = StorageStateHoldRecord(
                id: holdID,
                resourceKind: .volume,
                resourceID: volumeID,
                reasonRedacted: "operator data-protection hold",
                generation: 1,
                fencingToken: holdGroup.fence,
                operationGroupID: holdGroup.id,
                createdAt: "2026-07-25T12:04:00Z",
                expiresAt: "2026-07-26T12:04:00Z",
                releasedAt: nil
            )
            XCTAssertEqual(try store.storage.saveHold(hold), hold)
            XCTAssertEqual(
                try store.storage.activeHolds(
                    resourceKind: .volume,
                    resourceID: volumeID,
                    at: "2026-07-25T13:00:00Z"
                ),
                [hold]
            )

            let orphanGroup = try operationGroup(
                store: store,
                suffix: "15"
            )
            let orphan = StorageStateOrphanRecord(
                id: orphanID,
                providerID: "local-apfs",
                resourceKind: .volume,
                providerResourceIDHash:
                    String(repeating: "b", count: 64),
                ownershipProofSHA256: nil,
                generation: 1,
                fencingToken: orphanGroup.fence,
                lifecycleState: .discovered,
                operationGroupID: orphanGroup.id,
                discoveredAt: "2026-07-25T12:05:00Z",
                resolvedAt: nil
            )
            XCTAssertEqual(try store.storage.saveOrphan(orphan), orphan)
            XCTAssertEqual(
                try store.storage.loadOrphans(
                    providerID: "local-apfs"
                ),
                [orphan]
            )

            let reopened = SQLiteStateStore(path: store.path)
            XCTAssertEqual(
                try reopened.storage.loadVolume(id: volumeID)?.id,
                volumeID
            )
            XCTAssertEqual(
                StateIntegrityService(store: reopened).inspect().health,
                .healthy
            )
        }
    }

    func testOrphanReclaimAndOperationFenceFailClosed() throws {
        try withStore { store in
            let group = try operationGroup(store: store, suffix: "20")
            let orphan = StorageStateOrphanRecord(
                id: orphanID,
                providerID: "local-apfs",
                resourceKind: .volume,
                providerResourceIDHash:
                    String(repeating: "c", count: 64),
                ownershipProofSHA256: nil,
                generation: 1,
                fencingToken: group.fence,
                lifecycleState: .discovered,
                operationGroupID: group.id,
                discoveredAt: "2026-07-25T12:00:00Z",
                resolvedAt: nil
            )
            _ = try store.storage.saveOrphan(orphan)

            let reclaimGroup = try operationGroup(
                store: store,
                suffix: "21"
            )
            let unsafe = StorageStateOrphanRecord(
                id: orphan.id,
                providerID: orphan.providerID,
                resourceKind: orphan.resourceKind,
                providerResourceIDHash:
                    orphan.providerResourceIDHash,
                ownershipProofSHA256: nil,
                generation: 2,
                fencingToken: reclaimGroup.fence,
                lifecycleState: .reclaimed,
                operationGroupID: reclaimGroup.id,
                discoveredAt: orphan.discoveredAt,
                resolvedAt: "2026-07-25T12:10:00Z"
            )
            XCTAssertThrowsError(
                try store.storage.saveOrphan(
                    unsafe,
                    replacing: StorageStateExpectedVersion(
                        generation: 1,
                        fencingToken: group.fence
                    )
                )
            )

            let wrongGroup = try operationGroup(
                store: store,
                suffix: "22"
            )
            let wrongFence = volume(
                fence: "ffffffff-ffff-4fff-8fff-ffffffffffff",
                operationGroupID: wrongGroup.id
            )
            XCTAssertThrowsError(
                try store.storage.saveVolume(wrongFence)
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "exact fencing token"
                    )
                )
            }
        }
    }

    func testAttachmentCheckpointsHoldDetachAndCleanupAreDurable()
        throws
    {
        try withStore { store in
            let volumeGroup = try operationGroup(
                store: store,
                suffix: "30"
            )
            _ = try store.storage.saveVolume(
                volume(
                    fence: volumeGroup.fence,
                    operationGroupID: volumeGroup.id
                )
            )
            let attachGroup = try operationGroup(
                store: store,
                suffix: "31"
            )
            let expectedAttach = StorageStateExpectedVersion(
                generation: 1,
                fencingToken: attachGroup.fence
            )

            var record = attachment(
                operationGroupID: attachGroup.id,
                fence: attachGroup.fence
            )
            XCTAssertEqual(
                try store.storage.saveAttachment(record),
                record
            )
            record = attachment(
                operationGroupID: attachGroup.id,
                fence: attachGroup.fence,
                checkpoint: .attachFenceAcquired,
                updatedAt: "2026-07-25T12:02:00Z"
            )
            _ = try store.storage.saveAttachment(
                record,
                replacing: expectedAttach
            )
            record = attachment(
                operationGroupID: attachGroup.id,
                fence: attachGroup.fence,
                checkpoint: .attachProviderEffectRequested,
                updatedAt: "2026-07-25T12:03:00Z"
            )
            _ = try store.storage.saveAttachment(
                record,
                replacing: expectedAttach
            )
            record = attachment(
                operationGroupID: attachGroup.id,
                fence: attachGroup.fence,
                lifecycleState: .ambiguousHold,
                checkpoint: .attachProviderEffectRequested,
                ambiguousHoldReasonRedacted:
                    "provider timeout; exact observation required",
                updatedAt: "2026-07-25T12:04:00Z"
            )
            _ = try store.storage.saveAttachment(
                record,
                replacing: expectedAttach
            )
            XCTAssertEqual(
                try store.storage.loadAttachment(id: attachmentID),
                record
            )

            record = attachment(
                operationGroupID: attachGroup.id,
                fence: attachGroup.fence,
                checkpoint: .attachProviderObserved,
                providerObservationSHA256:
                    String(repeating: "d", count: 64),
                updatedAt: "2026-07-25T12:05:00Z"
            )
            _ = try store.storage.saveAttachment(
                record,
                replacing: expectedAttach
            )
            record = attachment(
                operationGroupID: attachGroup.id,
                fence: attachGroup.fence,
                lifecycleState: .attached,
                checkpoint: .attachedCommitted,
                providerObservationSHA256:
                    String(repeating: "d", count: 64),
                updatedAt: "2026-07-25T12:05:30Z"
            )
            _ = try store.storage.saveAttachment(
                record,
                replacing: expectedAttach
            )
            XCTAssertEqual(
                try store.storage.loadStaleAttachments(
                    at: "2026-07-25T12:06:00Z"
                ),
                [record]
            )

            let detachGroup = try operationGroup(
                store: store,
                suffix: "32"
            )
            let expectedDetach = StorageStateExpectedVersion(
                generation: 2,
                fencingToken: detachGroup.fence
            )
            let detachCheckpoints: [
                (
                    StorageAttachmentCheckpoint,
                    StorageAttachmentLifecycleState,
                    String?
                )
            ] = [
                (.detachIntentPersisted, .detaching, nil),
                (.detachFenceAcquired, .detaching, nil),
                (.detachProviderEffectRequested, .detaching, nil),
                (
                    .detachProviderAbsentObserved,
                    .detaching,
                    String(repeating: "e", count: 64)
                ),
                (
                    .detachedCommitted,
                    .detached,
                    String(repeating: "e", count: 64)
                ),
            ]
            for (index, checkpoint) in detachCheckpoints.enumerated() {
                record = attachment(
                    operationGroupID: detachGroup.id,
                    fence: detachGroup.fence,
                    generation: 2,
                    lifecycleState: checkpoint.1,
                    checkpoint: checkpoint.0,
                    leaseRenewedAt: "2026-07-25T12:07:00Z",
                    leaseExpiresAt: "2026-07-25T12:12:00Z",
                    operationID:
                        "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                    idempotencyKey:
                        String(repeating: "f", count: 64),
                    providerObservationSHA256: checkpoint.2,
                    updatedAt: String(
                        format:
                            "2026-07-25T12:%02d:00Z",
                        7 + index
                    )
                )
                _ = try store.storage.saveAttachment(
                    record,
                    replacing: index == 0
                        ? expectedAttach
                        : expectedDetach
                )
            }

            XCTAssertThrowsError(
                try store.storage.removeDetachedAttachment(
                    id: attachmentID,
                    expected: expectedAttach
                )
            )
            XCTAssertTrue(
                try store.storage.removeDetachedAttachment(
                    id: attachmentID,
                    expected: expectedDetach
                )
            )
            XCTAssertFalse(
                try store.storage.removeDetachedAttachment(
                    id: attachmentID,
                    expected: expectedDetach
                )
            )
            XCTAssertNil(
                try store.storage.loadAttachment(id: attachmentID)
            )
            XCTAssertEqual(
                StateIntegrityService(store: store).inspect().health,
                .healthy
            )
        }
    }

    func testAttachmentConflictStaleFenceAndReorderingFailClosed()
        throws
    {
        try withStore { store in
            let volumeGroup = try operationGroup(
                store: store,
                suffix: "40"
            )
            _ = try store.storage.saveVolume(
                volume(
                    fence: volumeGroup.fence,
                    operationGroupID: volumeGroup.id
                )
            )
            let firstGroup = try operationGroup(
                store: store,
                suffix: "41"
            )
            let first = attachment(
                operationGroupID: firstGroup.id,
                fence: firstGroup.fence
            )
            _ = try store.storage.saveAttachment(first)

            let secondGroup = try operationGroup(
                store: store,
                suffix: "42"
            )
            XCTAssertThrowsError(
                try store.storage.saveAttachment(
                    attachment(
                        id:
                            "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                        nodeUUID:
                            "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
                        workloadUUID:
                            "ffffffff-ffff-4fff-8fff-ffffffffffff",
                        operationGroupID: secondGroup.id,
                        fence: secondGroup.fence
                    )
                )
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "single-writer"
                    )
                )
            }

            let expected = StorageStateExpectedVersion(
                generation: 1,
                fencingToken: firstGroup.fence
            )
            XCTAssertThrowsError(
                try store.storage.saveAttachment(
                    attachment(
                        operationGroupID: firstGroup.id,
                        fence: firstGroup.fence,
                        checkpoint:
                            .attachProviderEffectRequested,
                        updatedAt: "2026-07-25T12:02:00Z"
                    ),
                    replacing: expected
                )
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "moved out of order"
                    )
                )
            }

            let fenced = attachment(
                operationGroupID: firstGroup.id,
                fence: firstGroup.fence,
                checkpoint: .attachFenceAcquired,
                updatedAt: "2026-07-25T12:02:00Z"
            )
            _ = try store.storage.saveAttachment(
                fenced,
                replacing: expected
            )
            XCTAssertThrowsError(
                try store.storage.saveAttachment(
                    attachment(
                        operationGroupID: firstGroup.id,
                        fence: firstGroup.fence,
                        checkpoint: .attachFenceAcquired,
                        providerObservationSHA256:
                            String(repeating: "a", count: 64),
                        updatedAt: "2026-07-25T12:03:00Z"
                    ),
                    replacing: expected
                )
            )
            XCTAssertThrowsError(
                try store.storage.saveAttachment(
                    attachment(
                        operationGroupID: firstGroup.id,
                        fence: firstGroup.fence,
                        checkpoint:
                            .attachProviderEffectRequested,
                        updatedAt: "2026-07-25T12:03:00Z"
                    ),
                    replacing: StorageStateExpectedVersion(
                        generation: 1,
                        fencingToken:
                            "ffffffff-ffff-4fff-8fff-ffffffffffff"
                    )
                )
            )
            XCTAssertEqual(
                try store.storage.loadAttachment(id: attachmentID),
                fenced
            )
        }
    }

    func testFutureSchemaRefusesStorageReadAsDowngradeProtection()
        throws
    {
        try withStore { store in
            try store.withConnection { connection in
                try connection.run(
                    """
                    INSERT INTO schema_migrations (
                        version, description, checksum, applied_at
                    ) VALUES (?, 'future storage schema',
                        'future-checksum', '2026-07-25T12:00:00Z')
                    """
                    , bindings: [.int(HostwrightContractVersions.stateSchema + 1)]
                )
            }
            XCTAssertThrowsError(
                try store.storage.loadVolumes()
            ) { error in
                guard case .incompatibleSchema(
                    let found,
                    let supported,
                    _
                ) = error as? StateStoreError else {
                    return XCTFail(
                        "Expected downgrade refusal, got \(error)."
                    )
                }
                XCTAssertEqual(found, HostwrightContractVersions.stateSchema + 1)
                XCTAssertEqual(supported, HostwrightContractVersions.stateSchema)
            }
        }
    }

    private func volume(
        generation: Int64 = 1,
        fence: String,
        capacityBytes: Int64 = 1_024,
        lifecycleState: StorageVolumeLifecycleState = .available,
        operationGroupID: String
    ) -> StorageStateVolumeRecord {
        StorageStateVolumeRecord(
            id: volumeID,
            projectID: "project-database",
            name: "database",
            providerID: "local-apfs",
            providerVolumeID: "provider-volume-1",
            topologyNodeID: "dev-mbp",
            generation: generation,
            fencingToken: fence,
            capacityBytes: capacityBytes,
            lifecycleState: lifecycleState,
            reclaimPolicy: .retain,
            accessMode: .readWriteOnce,
            operationGroupID: operationGroupID,
            createdAt: "2026-07-25T12:00:00Z",
            updatedAt: generation == 1
                ? "2026-07-25T12:00:00Z"
                : "2026-07-25T12:10:00Z"
        )
    }

    private func attachment(
        id: String? = nil,
        nodeUUID: String =
            "99999999-9999-4999-8999-999999999999",
        workloadUUID: String =
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        operationGroupID: String,
        fence: String,
        generation: Int64 = 1,
        lifecycleState: StorageAttachmentLifecycleState = .attaching,
        checkpoint: StorageAttachmentCheckpoint =
            .attachIntentPersisted,
        leaseRenewedAt: String = "2026-07-25T12:01:00Z",
        leaseExpiresAt: String = "2026-07-25T12:06:00Z",
        operationID: String =
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        idempotencyKey: String = String(repeating: "c", count: 64),
        providerObservationSHA256: String? = nil,
        forceDetachAuthorizationSHA256: String? = nil,
        ambiguousHoldReasonRedacted: String? = nil,
        updatedAt: String = "2026-07-25T12:01:00Z"
    ) -> StorageStateAttachmentRecord {
        StorageStateAttachmentRecord(
            id: id ?? attachmentID,
            volumeID: volumeID,
            nodeID: "dev-mbp",
            nodeUUID: nodeUUID,
            workloadUUID: workloadUUID,
            kind: .stage,
            path: "/var/tmp/hostwright/storage/stage",
            stagingPath: nil,
            accessMode: .readWriteOnce,
            readOnly: false,
            generation: generation,
            fencingToken: fence,
            lifecycleState: lifecycleState,
            checkpoint: checkpoint,
            leaseRenewedAt: leaseRenewedAt,
            leaseExpiresAt: leaseExpiresAt,
            operationID: operationID,
            idempotencyKey: idempotencyKey,
            providerObservationSHA256:
                providerObservationSHA256,
            forceDetachAuthorizationSHA256:
                forceDetachAuthorizationSHA256,
            ambiguousHoldReasonRedacted:
                ambiguousHoldReasonRedacted,
            operationGroupID: operationGroupID,
            createdAt: "2026-07-25T12:01:00Z",
            updatedAt: updatedAt
        )
    }

    private func capacitySample(
        id: String,
        capturedAt: Int64 = 1_000_000,
        validUntil: Int64 = 1_060_000
    ) throws -> StorageCapacitySample {
        try StorageCapacitySample(
            id: id,
            providerID: "local-apfs",
            topologyNodeID: "dev-mbp",
            source: .statfs,
            requestedBytes: 4_096,
            reservedBytes: 512,
            usedBytes: 3_000,
            reclaimableBytes: 256,
            availableBytes: 6_000,
            totalBytes: 10_000,
            requestedInodes: 16,
            reservedInodes: 2,
            usedInodes: 300,
            reclaimableInodes: 10,
            availableInodes: 600,
            totalInodes: 1_000,
            quotaCapability: try StorageQuotaCapability(
                mode: .logical
            ),
            capturedAtUnixMilliseconds: capturedAt,
            validUntilUnixMilliseconds: validUntil
        )
    }

    private func operationGroup(
        store: SQLiteStateStore,
        suffix: String
    ) throws -> (id: String, fence: String) {
        let id =
            "70000000-0000-4000-8000-0000000000\(suffix)"
        let fence =
            "80000000-0000-4000-8000-0000000000\(suffix)"
        let record = OperationGroupRecord(
            id: id,
            operationID: "storage-operation-\(suffix)",
            groupKind: "storage-operation",
            projectID: nil,
            serviceName: nil,
            plannedActionType: "storage",
            status: .active,
            groupIdempotencyKey: "storage:\(suffix)",
            planHash: String(repeating: "9", count: 64),
            checkpoint: "intent-persisted",
            lockOwner: "storage-test",
            lockExpiresAt: "2026-07-26T12:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-25T12:00:00Z",
            updatedAt: "2026-07-25T12:00:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: fence
        )
        XCTAssertNotNil(
            try store.operationGroups.acquire(record).acquired
        )
        return (id, fence)
    }

    private func tableNames(
        _ store: SQLiteStateStore
    ) throws -> [String] {
        try store.withConnection(
            createIfNeeded: false,
            readOnly: true
        ) {
            try $0.query(
                """
                SELECT name FROM sqlite_master
                WHERE type = 'table'
                ORDER BY name
                """
            ).compactMap { $0.first ?? nil }
        }
    }

    private func migrationVersions(
        _ store: SQLiteStateStore
    ) throws -> [Int] {
        try store.withConnection(
            createIfNeeded: false,
            readOnly: true
        ) {
            try $0.query(
                "SELECT version FROM schema_migrations ORDER BY version"
            ).compactMap { $0.first ?? nil }.compactMap(Int.init)
        }
    }

    private func withStore(
        throughVersion: Int? = nil,
        _ body: (SQLiteStateStore) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-storage-state-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        if let throughVersion {
            try MigrationRunner().apply(
                to: store,
                throughVersion: throughVersion
            )
        } else {
            try store.migrate()
        }
        try body(store)
    }
}
