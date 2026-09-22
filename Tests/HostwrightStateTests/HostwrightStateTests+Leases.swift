import Foundation
import Synchronization
import XCTest
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightState

extension HostwrightStateTests {
    func testExpiredActiveLeaseReclaimIsExactAndHasOneWinner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-state-xctest-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let store = SQLiteStateStore(path: databaseURL.path)
        try store.migrate()
        let fence = HostwrightResourceUUID.generate()
        let planHash = String(repeating: "a", count: 64)
        let group = OperationGroupRecord(
            id: HostwrightResourceUUID.generate(),
            operationID: "operation-lifecycle-expired",
            groupKind: "lifecycle-v1",
            projectID: nil,
            serviceName: nil,
            plannedActionType: "up",
            status: .active,
            groupIdempotencyKey: planHash,
            planHash: planHash,
            checkpoint: "create-web:effect-pending",
            lockOwner: "lifecycle-original",
            lockExpiresAt: "2026-07-23T00:10:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-23T00:00:00Z",
            updatedAt: "2026-07-23T00:00:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: fence
        )
        XCTAssertNotNil(
            try store.operationGroups.acquire(
                group,
                currentTimestamp: "2026-07-23T00:00:00Z"
            ).acquired
        )

        let live = try store.operationGroups.reclaimExpiredActive(
            groupID: group.id,
            expectedPlanHash: planHash,
            expectedFencingToken: fence,
            lockOwner: "lifecycle-contender",
            lockExpiresAt: "2026-07-23T00:20:00Z",
            currentTimestamp: "2026-07-23T00:05:00Z"
        )
        guard case .activeUnexpired(let stillOwned) = live else {
            return XCTFail("A live lifecycle lease must not be reclaimed.")
        }
        XCTAssertEqual(stillOwned.lockOwner, "lifecycle-original")

        XCTAssertThrowsError(
            try store.operationGroups.reclaimExpiredActive(
                groupID: group.id,
                expectedPlanHash: String(repeating: "b", count: 64),
                expectedFencingToken: fence,
                lockOwner: "lifecycle-wrong-plan",
                lockExpiresAt: "2026-07-23T00:30:00Z",
                currentTimestamp: "2026-07-23T00:11:00Z"
            )
        )
        XCTAssertThrowsError(
            try store.operationGroups.reclaimExpiredActive(
                groupID: group.id,
                expectedPlanHash: planHash,
                expectedFencingToken: HostwrightResourceUUID.generate(),
                lockOwner: "lifecycle-wrong-fence",
                lockExpiresAt: "2026-07-23T00:30:00Z",
                currentTimestamp: "2026-07-23T00:11:00Z"
            )
        )

        let results = try await withThrowingTaskGroup(
            of: OperationGroupLeaseRecoveryResult.self,
            returning: [OperationGroupLeaseRecoveryResult].self
        ) { tasks in
            for contender in 1...2 {
                tasks.addTask {
                    let contenderStore = SQLiteStateStore(path: databaseURL.path)
                    return try contenderStore.operationGroups.reclaimExpiredActive(
                        groupID: group.id,
                        expectedPlanHash: planHash,
                        expectedFencingToken: fence,
                        lockOwner: "lifecycle-contender-\(contender)",
                        lockExpiresAt: "2026-07-23T00:30:00Z",
                        currentTimestamp: "2026-07-23T00:11:00Z"
                    )
                }
            }
            var values: [OperationGroupLeaseRecoveryResult] = []
            for try await value in tasks {
                values.append(value)
            }
            return values
        }
        XCTAssertEqual(
            results.filter {
                if case .reclaimed = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(
            results.filter {
                if case .activeUnexpired = $0 { return true }
                return false
            }.count,
            1
        )
        let reclaimed = try XCTUnwrap(
            store.operationGroups.load(id: group.id)
        )
        XCTAssertTrue(
            ["lifecycle-contender-1", "lifecycle-contender-2"].contains(
                reclaimed.lockOwner
            )
        )
        XCTAssertEqual(reclaimed.lockExpiresAt, "2026-07-23T00:30:00Z")

        let legacy = OperationGroupRecord(
            id: "group-lifecycle-legacy",
            operationID: "operation-lifecycle-legacy",
            groupKind: "lifecycle-v1",
            projectID: nil,
            serviceName: nil,
            plannedActionType: "up",
            status: .active,
            groupIdempotencyKey: String(repeating: "c", count: 64),
            planHash: String(repeating: "c", count: 64),
            checkpoint: "intent-persisted",
            lockOwner: "legacy-owner",
            lockExpiresAt: nil,
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-23T00:00:00Z",
            updatedAt: "2026-07-23T00:00:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: HostwrightResourceUUID.generate()
        )
        XCTAssertNotNil(
            try store.operationGroups.acquire(
                legacy,
                currentTimestamp: "2026-07-23T00:00:00Z"
            ).acquired
        )
        XCTAssertThrowsError(
            try store.operationGroups.reclaimExpiredActive(
                groupID: legacy.id,
                expectedPlanHash: legacy.planHash,
                expectedFencingToken: legacy.fencingToken,
                lockOwner: "legacy-reclaimer",
                lockExpiresAt: "2026-07-23T00:30:00Z",
                currentTimestamp: "2026-07-23T00:11:00Z"
            )
        )
    }

    func testExpiredOperationLeaseHandoffIsExactAndNewOwnerCanRenew() throws {
        try withTemporaryStore { store, _ in
            try store.migrate()
            let groupID = HostwrightResourceUUID.generate()
            let operationID = HostwrightResourceUUID.generate()
            let fence = HostwrightResourceUUID.generate()
            let planHash = String(repeating: "a", count: 64)
            let originalOwner = "hostwright-cli:\(operationID)"
            XCTAssertNotNil(
                try store.operationGroups.acquire(
                    OperationGroupRecord(
                        id: groupID,
                        operationID: operationID,
                        groupKind: "lifecycle-v1",
                        projectID: nil,
                        serviceName: nil,
                        plannedActionType: "rm",
                        status: .active,
                        groupIdempotencyKey: planHash,
                        planHash: planHash,
                        checkpoint: "remove-api:effect-pending",
                        lockOwner: originalOwner,
                        lockExpiresAt: "2026-08-01T00:10:00Z",
                        rollbackAvailable: true,
                        manualRecoveryHintRedacted: "",
                        createdAt: "2026-08-01T00:00:00Z",
                        updatedAt: "2026-08-01T00:00:00Z",
                        metadataJSONRedacted: "{}",
                        fencingToken: fence
                    ),
                    currentTimestamp: "2026-08-01T00:00:00Z"
                ).acquired
            )
            let acquiredGroup = try XCTUnwrap(
                store.operationGroups.load(id: groupID)
            )
            let baseOwnership = OwnershipRecord(
                id: "ownership-handoff",
                resourceIdentifier: "hostwright-demo-api",
                resourceType: "container",
                projectID: nil,
                serviceName: "api",
                runtimeAdapter: "AppleContainerApplyAdapter",
                createdAt: "2026-08-01T00:00:00Z",
                observedAt: "2026-08-01T00:00:00Z",
                cleanupEligible: true,
                metadataJSONRedacted: "{}",
                resourceUUID: HostwrightResourceUUID.generate(),
                projectResourceUUID: HostwrightResourceUUID.generate(),
                fencingToken: fence
            )
            let authority = try OwnershipAuthorityRecord.lifecycle(
                ownership: baseOwnership,
                operationGroup: acquiredGroup,
                finalizerState: .active
            )
            try store.ownership.upsert(
                OwnershipRecord(
                    id: baseOwnership.id,
                    resourceIdentifier: baseOwnership.resourceIdentifier,
                    resourceType: baseOwnership.resourceType,
                    projectID: baseOwnership.projectID,
                    serviceName: baseOwnership.serviceName,
                    runtimeAdapter: baseOwnership.runtimeAdapter,
                    createdAt: baseOwnership.createdAt,
                    observedAt: baseOwnership.observedAt,
                    cleanupEligible: baseOwnership.cleanupEligible,
                    metadataJSONRedacted:
                        try OwnershipAuthorityMetadata.encode(
                            authority,
                            into: "{}"
                        ),
                    resourceUUID: baseOwnership.resourceUUID,
                    projectResourceUUID:
                        baseOwnership.projectResourceUUID,
                    fencingToken: baseOwnership.fencingToken
                )
            )

            XCTAssertThrowsError(
                try store.operationGroups.handoffExpiredActive(
                    groupID: groupID,
                    expectedPlanHash: planHash,
                    expectedFencingToken: fence,
                    expectedLockOwner: originalOwner,
                    expectedLockExpiresAt: "2026-08-01T00:10:00Z",
                    newLockOwner: "hostwright-recovery-resume",
                    newLockExpiresAt: "2026-08-01T00:20:00Z",
                    currentTimestamp: "2026-08-01T00:05:00Z"
                )
            )
            let inFlightMutation = try store
                .acquireOperationMutationFence(groupID: groupID)
            XCTAssertThrowsError(
                try store.operationGroups.handoffExpiredActive(
                    groupID: groupID,
                    expectedPlanHash: planHash,
                    expectedFencingToken: fence,
                    expectedLockOwner: originalOwner,
                    expectedLockExpiresAt: "2026-08-01T00:10:00Z",
                    newLockOwner: "hostwright-recovery-resume",
                    newLockExpiresAt: "2026-08-01T00:20:00Z",
                    currentTimestamp: "2026-08-01T00:11:00Z"
                )
            )
            inFlightMutation.release()
            let handedOff = try store.operationGroups.handoffExpiredActive(
                groupID: groupID,
                expectedPlanHash: planHash,
                expectedFencingToken: fence,
                expectedLockOwner: originalOwner,
                expectedLockExpiresAt: "2026-08-01T00:10:00Z",
                newLockOwner: "hostwright-recovery-resume",
                newLockExpiresAt: "2026-08-01T00:20:00Z",
                currentTimestamp: "2026-08-01T00:11:00Z"
            )
            XCTAssertEqual(
                handedOff.lockOwner,
                "hostwright-recovery-resume"
            )
            let reboundOwnership = try XCTUnwrap(
                store.ownership.loadAll().first
            )
            let reboundAuthority = try XCTUnwrap(
                OwnershipAuthorityMetadata.decode(
                    from: reboundOwnership.metadataJSONRedacted
                )
            )
            XCTAssertEqual(
                reboundAuthority.leaseOwner,
                "hostwright-recovery-resume"
            )
            XCTAssertEqual(
                reboundAuthority.leaseExpiresAt,
                "2026-08-01T00:20:00Z"
            )
            XCTAssertEqual(reboundAuthority.handoffGeneration, 1)
            let metadata = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(handedOff.metadataJSONRedacted.utf8)
                ) as? [String: Any]
            )
            let leaseAuthority = try XCTUnwrap(
                metadata["localLeaseAuthority"] as? [String: Any]
            )
            XCTAssertEqual(
                (leaseAuthority["handoffGeneration"] as? NSNumber)?.intValue,
                1
            )
            XCTAssertThrowsError(
                try store.operationGroups.handoffExpiredActive(
                    groupID: groupID,
                    expectedPlanHash: planHash,
                    expectedFencingToken: fence,
                    expectedLockOwner: originalOwner,
                    expectedLockExpiresAt: "2026-08-01T00:10:00Z",
                    newLockOwner: "hostwright-recovery-rollback",
                    newLockExpiresAt: "2026-08-01T00:30:00Z",
                    currentTimestamp: "2026-08-01T00:12:00Z"
                )
            )
            XCTAssertThrowsError(
                try store.operationGroups.finishExactLease(
                    groupID: groupID,
                    expectedFencingToken: fence,
                    expectedLockOwner: originalOwner,
                    expectedLockExpiresAt: "2026-08-01T00:10:00Z",
                    status: .interrupted,
                    checkpoint: "stale-controller",
                    manualRecoveryHintRedacted: "",
                    updatedAt: "2026-08-01T00:12:00Z",
                    metadataJSONRedacted: "{}"
                )
            )
            let sharedControllerAttempt = try store.operationGroups
                .reclaimExpiredActive(
                groupID: groupID,
                expectedPlanHash: planHash,
                expectedFencingToken: fence,
                lockOwner: "hostwright-recovery-resume",
                lockExpiresAt: "2026-08-01T00:30:00Z",
                currentTimestamp: "2026-08-01T00:12:00Z"
            )
            guard case .activeUnexpired = sharedControllerAttempt else {
                return XCTFail(
                    "A shared recovery controller identity must not bypass single-process exclusion."
                )
            }
            let claimant =
                "hostwright-recovery-resume:\(HostwrightResourceUUID.generate())"
            let claim = try store.operationGroups.reclaimExpiredActive(
                groupID: groupID,
                expectedPlanHash: planHash,
                expectedFencingToken: fence,
                lockOwner: claimant,
                lockExpiresAt: "2026-08-01T00:30:00Z",
                currentTimestamp: "2026-08-01T00:12:00Z"
            )
            guard case .reclaimed(let renewed) = claim else {
                return XCTFail("One unique recovery process must claim the handoff.")
            }
            XCTAssertEqual(renewed.lockOwner, claimant)
            XCTAssertEqual(
                renewed.lockExpiresAt,
                "2026-08-01T00:30:00Z"
            )
            let renewedOwnership = try XCTUnwrap(
                store.ownership.loadAll().first
            )
            let renewedAuthority = try XCTUnwrap(
                OwnershipAuthorityMetadata.decode(
                    from: renewedOwnership.metadataJSONRedacted
                )
            )
            XCTAssertEqual(
                renewedAuthority.leaseOwner,
                claimant
            )
            XCTAssertEqual(
                renewedAuthority.leaseExpiresAt,
                "2026-08-01T00:30:00Z"
            )
            XCTAssertEqual(renewedAuthority.handoffGeneration, 2)
            let losingClaim = try store.operationGroups.reclaimExpiredActive(
                groupID: groupID,
                expectedPlanHash: planHash,
                expectedFencingToken: fence,
                lockOwner:
                    "hostwright-recovery-resume:\(HostwrightResourceUUID.generate())",
                lockExpiresAt: "2026-08-01T00:40:00Z",
                currentTimestamp: "2026-08-01T00:13:00Z"
            )
            guard case .activeUnexpired(let winner) = losingClaim else {
                return XCTFail("Only one recovery process may own the handoff.")
            }
            XCTAssertEqual(winner.lockOwner, claimant)
        }
    }

    func testExpiredHandoffRejectsKindsWithoutCompatibleRecoveryClaimants() throws {
        try withTemporaryStore { store, _ in
            try store.migrate()
            let groupID = HostwrightResourceUUID.generate()
            let operationID = HostwrightResourceUUID.generate()
            let fence = HostwrightResourceUUID.generate()
            let planHash = String(repeating: "d", count: 64)
            let originalOwner = "hostwright-cli:\(operationID)"
            XCTAssertNotNil(
                try store.operationGroups.acquire(
                    OperationGroupRecord(
                        id: groupID,
                        operationID: operationID,
                        groupKind: "secret-mutation",
                        projectID: nil,
                        serviceName: nil,
                        plannedActionType: "secret-apply",
                        status: .active,
                        groupIdempotencyKey: planHash,
                        planHash: planHash,
                        checkpoint: "secret:effect-pending",
                        lockOwner: originalOwner,
                        lockExpiresAt: "2026-08-01T00:10:00Z",
                        rollbackAvailable: false,
                        manualRecoveryHintRedacted: "",
                        createdAt: "2026-08-01T00:00:00Z",
                        updatedAt: "2026-08-01T00:00:00Z",
                        metadataJSONRedacted: "{}",
                        fencingToken: fence
                    ),
                    currentTimestamp: "2026-08-01T00:00:00Z"
                ).acquired
            )

            XCTAssertThrowsError(
                try store.operationGroups.handoffExpiredActive(
                    groupID: groupID,
                    expectedPlanHash: planHash,
                    expectedFencingToken: fence,
                    expectedLockOwner: originalOwner,
                    expectedLockExpiresAt: "2026-08-01T00:10:00Z",
                    newLockOwner: "hostwright-recovery-resume",
                    newLockExpiresAt: "2026-08-01T00:20:00Z",
                    currentTimestamp: "2026-08-01T00:11:00Z"
                )
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "compatible local recovery claimant"
                    )
                )
            }
            XCTAssertEqual(
                try store.operationGroups.load(id: groupID)?.lockOwner,
                originalOwner
            )
        }
    }
}
