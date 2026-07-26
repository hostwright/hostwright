import XCTest
@testable import HostwrightStorage

final class StorageReclaimEngineTests: XCTestCase {
    private let engine = StorageReclaimEngine()
    private let volumeID =
        "10000000-0000-4000-8000-000000000001"
    private let projectID =
        "20000000-0000-4000-8000-000000000001"
    private let operationID =
        "30000000-0000-4000-8000-000000000001"
    private let fence =
        "40000000-0000-4000-8000-000000000001"
    private let attachmentID =
        "50000000-0000-4000-8000-000000000001"
    private let holdID =
        "60000000-0000-4000-8000-000000000001"
    private let ownership = String(repeating: "a", count: 64)
    private let idempotency = String(repeating: "b", count: 64)

    func testPlansEveryPolicyWithExactDeterministicActions()
        throws
    {
        let expected: [
            StorageReclaimMode: [StorageReclaimAction]
        ] = [
            .retain: [.retain],
            .delete: [.delete],
            .snapshotBeforeDelete: [
                .createSnapshot,
                .verifySnapshot,
                .delete,
            ],
            .backupBeforeDelete: [
                .createBackup,
                .verifyBackup,
                .delete,
            ],
            .recycle: [.recycle, .verifyRecycle],
        ]

        for policy in StorageReclaimMode.allCases {
            let request = try makeRequest(
                ownership: policy == .retain ? nil : ownership,
                current: policy,
                requested: policy
            )
            let first = try engine.preview(request)
            let second = try engine.preview(request)
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.actions, expected[policy])
            XCTAssertEqual(
                first.destructive,
                policy != .retain
            )
            XCTAssertEqual(
                first.confirmationSHA256.utf8.count,
                64
            )
            XCTAssertLessThanOrEqual(
                first.redactedSummary.utf8.count,
                512
            )
        }
    }

    func testCanonicalRequestOrderingAndIdentityAffectToken()
        throws
    {
        let secondAttachment =
            "50000000-0000-4000-8000-000000000002"
        let first = try makeRequest(
            activeAttachments: [
                secondAttachment,
                attachmentID,
            ],
            activeHolds: [],
            ownership: ownership,
            requested: .retain
        )
        let second = try makeRequest(
            activeAttachments: [
                attachmentID,
                secondAttachment,
            ],
            activeHolds: [],
            ownership: ownership,
            requested: .retain
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            try engine.preview(first),
            try engine.preview(second)
        )

        let generationChanged = try makeRequest(
            generation: 2,
            ownership: ownership,
            requested: .delete
        )
        let fenceChanged = try makeRequest(
            fence:
                "40000000-0000-4000-8000-000000000002",
            ownership: ownership,
            requested: .delete
        )
        let baseline = try engine.preview(
            makeRequest(
                ownership: ownership,
                requested: .delete
            )
        )
        XCTAssertNotEqual(
            baseline.confirmationSHA256,
            try engine.preview(generationChanged)
                .confirmationSHA256
        )
        XCTAssertNotEqual(
            baseline.confirmationSHA256,
            try engine.preview(fenceChanged)
                .confirmationSHA256
        )
    }

    func testPolicyChangeAndDestructionRejectUnsafeState()
        throws
    {
        try assertPreviewError(
            makeRequest(
                activeAttachments: [attachmentID],
                ownership: ownership,
                requested: .delete
            ),
            .activeAttachment
        )
        try assertPreviewError(
            makeRequest(
                activeHolds: [holdID],
                ownership: ownership,
                requested: .delete
            ),
            .activeHold
        )
        try assertPreviewError(
            makeRequest(
                ownership: ownership,
                ambiguous: true,
                requested: .delete
            ),
            .ambiguousOwnership
        )
        try assertPreviewError(
            makeRequest(requested: .delete),
            .missingOwnershipProof
        )

        try assertPreviewError(
            makeRequest(
                activeAttachments: [attachmentID],
                ownership: ownership,
                current: .delete,
                requested: .retain
            ),
            .activeAttachment
        )
        try assertPreviewError(
            makeRequest(
                activeHolds: [holdID],
                ownership: ownership,
                current: .delete,
                requested: .retain
            ),
            .activeHold
        )
    }

    func testUnavailableSnapshotAndBackupFailBeforePlan()
        throws
    {
        let unavailable =
            try StorageReclaimPrerequisiteCapability(
                available: false,
                reasonCode: "provider-unavailable"
            )
        try assertPreviewError(
            makeRequest(
                ownership: ownership,
                requested: .snapshotBeforeDelete,
                snapshot: unavailable
            ),
            .prerequisiteUnavailable
        )
        try assertPreviewError(
            makeRequest(
                ownership: ownership,
                requested: .backupBeforeDelete,
                backup: unavailable
            ),
            .prerequisiteUnavailable
        )
    }

    func testExactConfirmationAndFreshPlanAreRequired()
        throws
    {
        let request = try makeRequest(
            ownership: ownership,
            requested: .delete
        )
        let plan = try engine.preview(request)
        let checkpoint = try StorageReclaimCheckpoint.initial(
            request: request,
            plan: plan
        )
        XCTAssertThrowsError(
            try engine.nextAction(
                request: request,
                plan: plan,
                confirmationSHA256:
                    String(repeating: "0", count: 64),
                checkpoint: checkpoint
            )
        ) {
            XCTAssertEqual(
                ($0 as? StorageReclaimError)?.code,
                .confirmationMismatch
            )
        }

        let changed = try makeRequest(
            generation: 2,
            ownership: ownership,
            requested: .delete
        )
        XCTAssertThrowsError(
            try engine.nextAction(
                request: changed,
                plan: plan,
                confirmationSHA256:
                    plan.confirmationSHA256,
                checkpoint: checkpoint
            )
        ) {
            XCTAssertEqual(
                ($0 as? StorageReclaimError)?.code,
                .stalePlan
            )
        }
    }

    func testSnapshotAndBackupProofGateDestructiveDelete()
        throws
    {
        for (
            policy,
            create,
            verify,
            proofKind
        ) in [
            (
                StorageReclaimMode.snapshotBeforeDelete,
                StorageReclaimAction.createSnapshot,
                StorageReclaimAction.verifySnapshot,
                StorageReclaimPrerequisiteKind.snapshot
            ),
            (
                StorageReclaimMode.backupBeforeDelete,
                StorageReclaimAction.createBackup,
                StorageReclaimAction.verifyBackup,
                StorageReclaimPrerequisiteKind.backup
            ),
        ] {
            let request = try makeRequest(
                ownership: ownership,
                requested: policy
            )
            let plan = try engine.preview(request)
            let initial =
                try StorageReclaimCheckpoint.initial(
                    request: request,
                    plan: plan
                )
            XCTAssertEqual(
                try engine.nextAction(
                    request: request,
                    plan: plan,
                    confirmationSHA256:
                        plan.confirmationSHA256,
                    checkpoint: initial
                ).action,
                create
            )

            let withoutProof = try checkpoint(
                request,
                plan,
                completed: [create]
            )
            XCTAssertThrowsError(
                try engine.nextAction(
                    request: request,
                    plan: plan,
                    confirmationSHA256:
                        plan.confirmationSHA256,
                    checkpoint: withoutProof
                )
            ) {
                XCTAssertEqual(
                    ($0 as? StorageReclaimError)?.code,
                    .missingPrerequisiteProof
                )
            }

            let proof = try makeProof(kind: proofKind)
            let verifyCheckpoint = try checkpoint(
                request,
                plan,
                completed: [create],
                proof: proof
            )
            XCTAssertEqual(
                try engine.nextAction(
                    request: request,
                    plan: plan,
                    confirmationSHA256:
                        plan.confirmationSHA256,
                    checkpoint: verifyCheckpoint
                ).action,
                verify
            )

            let deleteCheckpoint = try checkpoint(
                request,
                plan,
                completed: [create, verify],
                proof: proof
            )
            XCTAssertEqual(
                try engine.nextAction(
                    request: request,
                    plan: plan,
                    confirmationSHA256:
                        plan.confirmationSHA256,
                    checkpoint: deleteCheckpoint
                ).action,
                .delete
            )
        }
    }

    func testMismatchedProofCannotReachDelete() throws {
        let request = try makeRequest(
            ownership: ownership,
            requested: .snapshotBeforeDelete
        )
        let plan = try engine.preview(request)
        let wrongProof = try StorageReclaimPrerequisiteProof(
            kind: .snapshot,
            volumeID: volumeID,
            generation: 2,
            fencingToken: fence,
            ownershipProofSHA256: ownership,
            artifactID:
                "70000000-0000-4000-8000-000000000001",
            artifactContentSHA256:
                String(repeating: "c", count: 64),
            verified: true
        )
        let checkpoint = try self.checkpoint(
            request,
            plan,
            completed: [.createSnapshot],
            proof: wrongProof
        )
        XCTAssertThrowsError(
            try engine.nextAction(
                request: request,
                plan: plan,
                confirmationSHA256:
                    plan.confirmationSHA256,
                checkpoint: checkpoint
            )
        ) {
            XCTAssertEqual(
                ($0 as? StorageReclaimError)?.code,
                .mismatchedPrerequisiteProof
            )
        }
    }

    func testCheckpointIsIdempotentAndRejectsNonPrefix()
        throws
    {
        let request = try makeRequest(
            ownership: ownership,
            requested: .recycle
        )
        let plan = try engine.preview(request)
        let complete = try checkpoint(
            request,
            plan,
            completed: [.recycle, .verifyRecycle]
        )
        let first = try engine.nextAction(
            request: request,
            plan: plan,
            confirmationSHA256: plan.confirmationSHA256,
            checkpoint: complete
        )
        let second = try engine.nextAction(
            request: request,
            plan: plan,
            confirmationSHA256: plan.confirmationSHA256,
            checkpoint: complete
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.disposition, .alreadySatisfied)
        XCTAssertNil(first.action)

        let invalid = try checkpoint(
            request,
            plan,
            completed: [.verifyRecycle]
        )
        XCTAssertThrowsError(
            try engine.nextAction(
                request: request,
                plan: plan,
                confirmationSHA256:
                    plan.confirmationSHA256,
                checkpoint: invalid
            )
        ) {
            XCTAssertEqual(
                ($0 as? StorageReclaimError)?.code,
                .invalidCheckpoint
            )
        }
    }

    func testCancellationAndAmbiguityHaveSafeRecovery()
        throws
    {
        let request = try makeRequest(
            ownership: ownership,
            requested: .delete
        )
        let plan = try engine.preview(request)
        let cancelled = try checkpoint(
            request,
            plan,
            interruption: .cancelledBeforeEffect
        )
        let cancelledDecision = try engine.nextAction(
            request: request,
            plan: plan,
            confirmationSHA256: plan.confirmationSHA256,
            checkpoint: cancelled
        )
        XCTAssertEqual(cancelledDecision.disposition, .cancelled)
        XCTAssertEqual(cancelledDecision.retryClass, .never)
        XCTAssertEqual(
            cancelledDecision.recoveryDisposition,
            .none
        )

        for interruption in [
            StorageReclaimInterruption.cancelledAfterPossibleEffect,
            .timedOut,
            .ambiguousEffect,
        ] {
            let ambiguous = try checkpoint(
                request,
                plan,
                interruption: interruption
            )
            let decision = try engine.nextAction(
                request: request,
                plan: plan,
                confirmationSHA256:
                    plan.confirmationSHA256,
                checkpoint: ambiguous
            )
            XCTAssertEqual(
                decision.disposition,
                .recoveryRequired
            )
            XCTAssertEqual(
                decision.retryClass,
                .safeAfterObservation
            )
            XCTAssertEqual(
                decision.recoveryDisposition,
                .reobserve
            )
            XCTAssertNil(decision.action)
        }
    }

    func testErrorsAndResultsAreBoundedAndRedacted() {
        let secret = "do-not-leak"
        let error = StorageReclaimError(
            code: .invalidArgument,
            retryClass: .never,
            recoveryDisposition: .none,
            message: String(repeating: "x", count: 600) +
                secret,
            sensitiveValues: [secret]
        )
        XCTAssertLessThanOrEqual(error.message.utf8.count, 512)
        XCTAssertFalse(error.message.contains(secret))

        let decision = StorageReclaimDecision(
            operationID: operationID,
            idempotencySHA256: idempotency,
            disposition: .perform,
            action: .delete,
            retryClass: .resumeFromCheckpoint,
            recoveryDisposition: .resume,
            redactedSummary: String(repeating: "é", count: 600)
        )
        XCTAssertLessThanOrEqual(
            decision.redactedSummary.utf8.count,
            512
        )
    }

    private func makeRequest(
        generation: Int64 = 1,
        fence: String? = nil,
        activeAttachments: [String] = [],
        activeHolds: [String] = [],
        ownership: String? = nil,
        ambiguous: Bool = false,
        current: StorageReclaimMode = .retain,
        requested: StorageReclaimMode = .retain,
        snapshot:
            StorageReclaimPrerequisiteCapability = .supported,
        backup:
            StorageReclaimPrerequisiteCapability = .supported
    ) throws -> StorageReclaimRequest {
        try StorageReclaimRequest(
            operationID: operationID,
            idempotencySHA256: idempotency,
            volumeID: volumeID,
            projectID: projectID,
            providerID: "local-apfs",
            generation: generation,
            fencingToken: fence ?? self.fence,
            currentPolicy: current,
            requestedPolicy: requested,
            activeAttachmentIDs: activeAttachments,
            activeHoldIDs: activeHolds,
            ownershipProofSHA256: ownership,
            ownershipAmbiguous: ambiguous,
            snapshotCapability: snapshot,
            backupCapability: backup
        )
    }

    private func makeProof(
        kind: StorageReclaimPrerequisiteKind
    ) throws -> StorageReclaimPrerequisiteProof {
        try StorageReclaimPrerequisiteProof(
            kind: kind,
            volumeID: volumeID,
            generation: 1,
            fencingToken: fence,
            ownershipProofSHA256: ownership,
            artifactID:
                "70000000-0000-4000-8000-000000000001",
            artifactContentSHA256:
                String(repeating: "c", count: 64),
            verified: true
        )
    }

    private func checkpoint(
        _ request: StorageReclaimRequest,
        _ plan: StorageReclaimPlan,
        completed: [StorageReclaimAction] = [],
        proof: StorageReclaimPrerequisiteProof? = nil,
        interruption: StorageReclaimInterruption = .none
    ) throws -> StorageReclaimCheckpoint {
        try StorageReclaimCheckpoint(
            operationID: request.operationID,
            idempotencySHA256: request.idempotencySHA256,
            confirmationSHA256: plan.confirmationSHA256,
            completedActions: completed,
            prerequisiteProof: proof,
            interruption: interruption
        )
    }

    private func assertPreviewError(
        _ request: @autoclosure () throws ->
            StorageReclaimRequest,
        _ code: StorageReclaimErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertThrowsError(
            try engine.preview(request()),
            file: file,
            line: line
        ) {
            XCTAssertEqual(
                ($0 as? StorageReclaimError)?.code,
                code,
                file: file,
                line: line
            )
        }
    }
}
