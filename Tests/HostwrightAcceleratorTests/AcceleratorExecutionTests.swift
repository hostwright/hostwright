import Foundation
import XCTest
@testable import HostwrightAccelerator

final class AcceleratorExecutionTests: XCTestCase {
    private let projectID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let workloadID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let hostID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let snapshotID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let claimID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    private let reservationID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    private let grantID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    private let requestID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    private let now = Date(timeIntervalSince1970: 1_754_000_000)

    func testReservationUsesImmutableTwoLevelFenceAndRejectsStaleReplay() throws {
        let context = try makeContext()
        let reservation = try makeReservation(context: context)
        let machine = AcceleratorReservationStateMachine()

        XCTAssertThrowsError(
            try machine.transition(
                reservation: reservation,
                request: transitionRequest(
                    transition: .commit,
                    context: context,
                    fence: reservation.fence,
                    observedAt: reservation.expiresAt.addingTimeInterval(1)
                )
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .expired
            )
        }
        XCTAssertEqual(reservation.state, .reserved)

        XCTAssertThrowsError(
            try machine.transition(
                reservation: reservation,
                request: transitionRequest(
                    transition: .commit,
                    context: context,
                    fence: try AcceleratorFence(nodeEpoch: 1, reservationSequence: 3),
                    observedAt: now.addingTimeInterval(1)
                )
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .staleReservationSequence
            )
        }

        let committed = try machine.transition(
            reservation: reservation,
            request: transitionRequest(
                transition: .commit,
                context: context,
                fence: reservation.fence,
                observedAt: now.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(committed.state, .committed)
        XCTAssertEqual(committed.fence, reservation.fence)

        XCTAssertThrowsError(
            try machine.transition(
                reservation: committed,
                request: transitionRequest(
                    transition: .release,
                    context: context,
                    fence: reservation.fence,
                    observedAt: now
                )
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .outOfOrderObservation
            )
        }
    }

    func testExpiredReservationsRemainUntilFencedCleanupAndRejectStaleReplay() throws {
        let context = try makeContext()
        let reservation = try makeReservation(context: context)
        let machine = AcceleratorReservationStateMachine()

        let committed = try machine.transition(
            reservation: reservation,
            request: transitionRequest(
                transition: .commit,
                context: context,
                fence: reservation.fence,
                observedAt: now.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(committed.state, .committed)

        let staleFence = try AcceleratorFence(
            nodeEpoch: committed.fence.nodeEpoch,
            reservationSequence: committed.fence.reservationSequence - 1
        )
        XCTAssertThrowsError(
            try machine.transition(
                reservation: committed,
                request: transitionRequest(
                    transition: .revoke,
                    context: context,
                    fence: staleFence,
                    observedAt: committed.expiresAt.addingTimeInterval(1)
                )
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .staleReservationSequence
            )
        }

        let released = try machine.transition(
            reservation: committed,
            request: transitionRequest(
                transition: .release,
                context: context,
                fence: committed.fence,
                observedAt: committed.expiresAt.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(released.state, .released)
        XCTAssertEqual(
            released.lastTransitionAt,
            committed.expiresAt.addingTimeInterval(1)
        )
        let decoded = try JSONDecoder().decode(
            AcceleratorReservation.self,
            from: JSONEncoder().encode(released)
        )
        XCTAssertEqual(decoded, released)

        let reservedRevocation = try machine.transition(
            reservation: reservation,
            request: transitionRequest(
                transition: .revoke,
                context: context,
                fence: reservation.fence,
                observedAt: reservation.expiresAt.addingTimeInterval(2)
            )
        )
        XCTAssertEqual(reservedRevocation.state, .revoked)

        let cancelled = try machine.transition(
            reservation: committed,
            request: transitionRequest(
                transition: .cancel,
                context: context,
                fence: committed.fence,
                observedAt: committed.expiresAt.addingTimeInterval(3)
            )
        )
        XCTAssertEqual(cancelled.state, .cancelled)
    }

    func testExecutionRequestBindsClaimGrantReservationScopeModeModelAndMeasuredInventory() throws {
        let context = try makeContext()
        let inventory = try makeInventory()
        let modelHash = try digest("c")
        let quota = try AcceleratorQuota(
            budget: AcceleratorBudgetVector(
                memoryBytes: 4 * 1024 * 1024,
                computeUnits: 500,
                concurrencyUnits: 2
            ),
            maxInputBytes: 4 * 1024,
            maxOutputBytes: 8 * 1024,
            maxTimeoutMilliseconds: 2_000
        )
        let claim = try AcceleratorClaim(
            claimID: claimID,
            scope: .project(projectID: projectID),
            allowedModes: [.metal],
            modelHash: modelHash,
            quota: quota,
            inventorySnapshotID: inventory.snapshotID,
            inventoryGeneration: inventory.observedGeneration,
            issuer: context,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
        let reservation = try AcceleratorReservation(
            reservationID: reservationID,
            claimID: claim.claimID,
            scope: .workload(projectID: projectID, workloadID: workloadID),
            mode: .metal,
            modelHash: modelHash,
            budget: AcceleratorBudgetVector(
                memoryBytes: 2 * 1024 * 1024,
                computeUnits: 200,
                concurrencyUnits: 1
            ),
            inventorySnapshotID: inventory.snapshotID,
            inventoryGeneration: inventory.observedGeneration,
            fence: try AcceleratorFence(nodeEpoch: 4, reservationSequence: 9),
            owner: context,
            createdAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let committed = try AcceleratorReservationStateMachine().transition(
            reservation: reservation,
            request: transitionRequest(
                transition: .commit,
                context: context,
                fence: reservation.fence,
                observedAt: now.addingTimeInterval(1)
            )
        )
        let grant = try AcceleratorGrant(
            grantID: grantID,
            claimID: claim.claimID,
            reservationID: committed.reservationID,
            scope: committed.scope,
            granteeSubjectID: context.subjectID,
            mode: .metal,
            modelHash: modelHash,
            quota: quota,
            inventorySnapshotID: inventory.snapshotID,
            inventoryGeneration: inventory.observedGeneration,
            fence: committed.fence,
            issuer: context,
            issuedAt: now.addingTimeInterval(1),
            expiresAt: now.addingTimeInterval(120)
        )
        let request = try AcceleratorExecutionRequest(
            requestID: requestID,
            grantID: grant.grantID,
            reservationID: committed.reservationID,
            scope: committed.scope,
            mode: .metal,
            modelHash: modelHash,
            inputDigest: try digest("d"),
            inputBytes: 1_024,
            outputLimitBytes: 4_096,
            timeoutMilliseconds: 1_000,
            budget: AcceleratorBudgetVector(
                memoryBytes: 1 * 1024 * 1024,
                computeUnits: 100,
                concurrencyUnits: 1
            ),
            fence: committed.fence,
            authentication: context,
            requestedAt: now.addingTimeInterval(2)
        )

        try AcceleratorExecutionContract.validate(
            request: request,
            claim: claim,
            grant: grant,
            reservation: committed,
            inventory: inventory,
            observedAt: now.addingTimeInterval(2)
        )

        XCTAssertEqual(committed.state, .committed)
        let expiredRequest = try AcceleratorExecutionRequest(
            requestID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            grantID: grant.grantID,
            reservationID: committed.reservationID,
            scope: committed.scope,
            mode: .metal,
            modelHash: modelHash,
            inputDigest: try digest("e"),
            inputBytes: 1_024,
            outputLimitBytes: 4_096,
            timeoutMilliseconds: 1_000,
            budget: request.budget,
            fence: committed.fence,
            authentication: context,
            requestedAt: committed.expiresAt.addingTimeInterval(1)
        )
        XCTAssertThrowsError(
            try AcceleratorExecutionContract.validate(
                request: expiredRequest,
                claim: claim,
                grant: grant,
                reservation: committed,
                inventory: inventory,
                observedAt: expiredRequest.requestedAt
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .expired
            )
        }
    }

    func testExecutionResultUsageAndProvenanceAreMeasuredAndBounded() throws {
        let context = try makeContext()
        let modelHash = try digest("e")
        let request = try AcceleratorExecutionRequest(
            requestID: requestID,
            grantID: grantID,
            reservationID: reservationID,
            scope: .workload(projectID: projectID, workloadID: workloadID),
            mode: .coreML,
            modelHash: modelHash,
            inputDigest: try digest("f"),
            inputBytes: 128,
            outputLimitBytes: 1_024,
            timeoutMilliseconds: 500,
            budget: AcceleratorBudgetVector(
                memoryBytes: 1_024,
                computeUnits: 10,
                concurrencyUnits: 1
            ),
            fence: try AcceleratorFence(nodeEpoch: 5, reservationSequence: 11),
            authentication: context,
            requestedAt: now
        )
        let usage = try AcceleratorMeasuredUsage(
            budget: request.budget,
            source: .callerMeasuredUsage,
            observedGeneration: 7,
            authenticatedBy: context,
            observedAt: now.addingTimeInterval(1)
        )
        let provenance = try AcceleratorExecutionProvenance(
            requestID: request.requestID,
            mode: request.mode,
            modelHash: request.modelHash,
            inventorySnapshotID: snapshotID,
            inventoryGeneration: 7,
            evidenceDigest: try digest("a"),
            source: .callerObservedEvidence,
            authenticatedBy: context,
            recordedAt: now.addingTimeInterval(1)
        )
        let result = try AcceleratorExecutionResult(
            requestID: request.requestID,
            grantID: request.grantID,
            reservationID: request.reservationID,
            scope: request.scope,
            mode: request.mode,
            modelHash: request.modelHash,
            fence: request.fence,
            outcome: .succeeded,
            outputBytes: 512,
            outputDigest: try digest("b"),
            usage: usage,
            provenance: provenance,
            completedAt: now.addingTimeInterval(2),
            authenticatedBy: context,
            errorCode: nil
        )

        try result.validate(against: request)
        XCTAssertEqual(result.outputBytes, 512)

        let alternateContext = try AcceleratorAuthenticationContext(
            subjectID: context.subjectID,
            sessionID: "session-2",
            credentialID: "credential-2",
            authenticationDigest: try digest("b"),
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
        let resultWithAlternateAuthentication = try AcceleratorExecutionResult(
            requestID: result.requestID,
            grantID: result.grantID,
            reservationID: result.reservationID,
            scope: result.scope,
            mode: result.mode,
            modelHash: result.modelHash,
            fence: result.fence,
            outcome: result.outcome,
            outputBytes: result.outputBytes,
            outputDigest: result.outputDigest,
            usage: result.usage,
            provenance: result.provenance,
            completedAt: result.completedAt,
            authenticatedBy: alternateContext,
            errorCode: result.errorCode
        )
        XCTAssertThrowsError(
            try resultWithAlternateAuthentication.validate(against: request)
        ) { error in
            XCTAssertEqual((error as? AcceleratorValidationError)?.code, .grantMismatch)
        }

        let usageWithAlternateAuthentication = try AcceleratorMeasuredUsage(
            budget: request.budget,
            source: .callerMeasuredUsage,
            observedGeneration: 7,
            authenticatedBy: alternateContext,
            observedAt: now.addingTimeInterval(1)
        )
        let resultWithAlternateUsageAuthentication = try AcceleratorExecutionResult(
            requestID: result.requestID,
            grantID: result.grantID,
            reservationID: result.reservationID,
            scope: result.scope,
            mode: result.mode,
            modelHash: result.modelHash,
            fence: result.fence,
            outcome: result.outcome,
            outputBytes: result.outputBytes,
            outputDigest: result.outputDigest,
            usage: usageWithAlternateAuthentication,
            provenance: result.provenance,
            completedAt: result.completedAt,
            authenticatedBy: context,
            errorCode: result.errorCode
        )
        XCTAssertThrowsError(
            try resultWithAlternateUsageAuthentication.validate(against: request)
        ) { error in
            XCTAssertEqual((error as? AcceleratorValidationError)?.code, .invalidUsage)
        }

        let provenanceWithAlternateAuthentication = try AcceleratorExecutionProvenance(
            requestID: request.requestID,
            mode: request.mode,
            modelHash: request.modelHash,
            inventorySnapshotID: snapshotID,
            inventoryGeneration: 7,
            evidenceDigest: try digest("a"),
            source: .callerObservedEvidence,
            authenticatedBy: alternateContext,
            recordedAt: now.addingTimeInterval(1)
        )
        let resultWithAlternateProvenanceAuthentication = try AcceleratorExecutionResult(
            requestID: result.requestID,
            grantID: result.grantID,
            reservationID: result.reservationID,
            scope: result.scope,
            mode: result.mode,
            modelHash: result.modelHash,
            fence: result.fence,
            outcome: result.outcome,
            outputBytes: result.outputBytes,
            outputDigest: result.outputDigest,
            usage: result.usage,
            provenance: provenanceWithAlternateAuthentication,
            completedAt: result.completedAt,
            authenticatedBy: context,
            errorCode: result.errorCode
        )
        XCTAssertThrowsError(
            try resultWithAlternateProvenanceAuthentication.validate(against: request)
        ) { error in
            XCTAssertEqual((error as? AcceleratorValidationError)?.code, .invalidProvenance)
        }
    }

    func testBoundsRejectOversizedRequestAndHostileResultDecode() throws {
        XCTAssertThrowsError(
            try AcceleratorExecutionRequest(
                requestID: requestID,
                grantID: grantID,
                reservationID: reservationID,
                scope: .workload(projectID: projectID, workloadID: workloadID),
                mode: .linuxGuestGPUPassthrough,
                modelHash: try digest("a"),
                inputDigest: try digest("b"),
                inputBytes: AcceleratorLimits.maxInputBytes + 1,
                outputLimitBytes: 1,
                timeoutMilliseconds: 1,
                budget: AcceleratorBudgetVector(
                    memoryBytes: 1,
                    computeUnits: 1,
                    concurrencyUnits: 1
                ),
                fence: try AcceleratorFence(nodeEpoch: 1, reservationSequence: 1),
                authentication: try makeContext(),
                requestedAt: now
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .linuxGuestPassthroughBlocked
            )
        }

        let cancellation = try AcceleratorCancellationRecord(
            cancellationID: UUID(),
            requestID: requestID,
            grantID: grantID,
            reservationID: reservationID,
            scope: .workload(projectID: projectID, workloadID: workloadID),
            fence: try AcceleratorFence(nodeEpoch: 1, reservationSequence: 1),
            actor: try makeContext(),
            reason: "operator-request",
            requestedAt: now,
            state: .requested,
            effectiveAt: nil
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(cancellation)
            ) as? [String: Any]
        )
        object["reason"] = String(repeating: "x", count: AcceleratorLimits.maxReasonBytes + 1)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AcceleratorCancellationRecord.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    private func makeContext() throws -> AcceleratorAuthenticationContext {
        try AcceleratorAuthenticationContext(
            subjectID: "subject-owner",
            sessionID: "session-1",
            credentialID: "credential-1",
            authenticationDigest: try digest("a"),
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
    }

    private func makeInventory() throws -> AcceleratorInventorySnapshot {
        let evidence = try digest("a")
        let selfTest: (AcceleratorExecutionMode) throws -> AcceleratorHostNativeExecutionEvidence = { mode in
            try AcceleratorHostNativeExecutionEvidence(
                mode: mode,
                backendIdentifier: mode.rawValue,
                frameworkIdentifier: "host-native",
                operatingSystem: "macos",
                executionDigest: evidence,
                provenanceDigest: evidence,
                observedGeneration: 7,
                observedAt: self.now,
                completedAt: self.now.addingTimeInterval(1)
            )
        }
        return try AcceleratorInventorySnapshot(
            snapshotID: snapshotID,
            hostID: hostID,
            observedAt: now,
            observedGeneration: 7,
            modeEvidence: [
                try AcceleratorModeEvidence(
                    mode: .coreML,
                    status: .available,
                    evidenceDigest: evidence,
                    source: .hostNativeExecutionSelfTest,
                    observedGeneration: 7,
                    executionEvidence: try selfTest(.coreML)
                ),
                try AcceleratorModeEvidence(
                    mode: .linuxGuestANEPassthrough,
                    status: .blocked,
                    evidenceDigest: evidence,
                    source: .contractBoundary,
                    observedGeneration: 7,
                    reasonCode: .linuxGuestPassthroughBlocked
                ),
                try AcceleratorModeEvidence(
                    mode: .linuxGuestGPUPassthrough,
                    status: .blocked,
                    evidenceDigest: evidence,
                    source: .contractBoundary,
                    observedGeneration: 7,
                    reasonCode: .linuxGuestPassthroughBlocked
                ),
                try AcceleratorModeEvidence(
                    mode: .metal,
                    status: .available,
                    evidenceDigest: evidence,
                    source: .hostNativeExecutionSelfTest,
                    observedGeneration: 7,
                    executionEvidence: try selfTest(.metal)
                )
            ],
            budgets: [
                try AcceleratorMeasuredBudget(
                    mode: .metal,
                    kind: .compute,
                    amount: 10_000,
                    unit: .computeUnits,
                    source: .hostNativeModeMeasurement,
                    observedGeneration: 7,
                    measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                        executionDigest: evidence,
                        provenanceDigest: evidence,
                        observedGeneration: 7
                    ),
                    measurementEvidenceDigest: try AcceleratorMeasuredBudget.measurementEvidenceDigest(
                        mode: .metal,
                        kind: .compute,
                        amount: 10_000,
                        unit: .computeUnits,
                        observedGeneration: 7,
                        measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                            executionDigest: evidence,
                            provenanceDigest: evidence,
                            observedGeneration: 7
                        )
                    )
                ),
                try AcceleratorMeasuredBudget(
                    mode: .metal,
                    kind: .concurrency,
                    amount: 8,
                    unit: .concurrentExecutions,
                    source: .hostNativeModeMeasurement,
                    observedGeneration: 7,
                    measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                        executionDigest: evidence,
                        provenanceDigest: evidence,
                        observedGeneration: 7
                    ),
                    measurementEvidenceDigest: try AcceleratorMeasuredBudget.measurementEvidenceDigest(
                        mode: .metal,
                        kind: .concurrency,
                        amount: 8,
                        unit: .concurrentExecutions,
                        observedGeneration: 7,
                        measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                            executionDigest: evidence,
                            provenanceDigest: evidence,
                            observedGeneration: 7
                        )
                    )
                ),
                try AcceleratorMeasuredBudget(
                    mode: .metal,
                    kind: .memory,
                    amount: 64 * 1024 * 1024,
                    unit: .bytes,
                    source: .hostNativeModeMeasurement,
                    observedGeneration: 7,
                    measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                        executionDigest: evidence,
                        provenanceDigest: evidence,
                        observedGeneration: 7
                    ),
                    measurementEvidenceDigest: try AcceleratorMeasuredBudget.measurementEvidenceDigest(
                        mode: .metal,
                        kind: .memory,
                        amount: 64 * 1024 * 1024,
                        unit: .bytes,
                        observedGeneration: 7,
                        measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                            executionDigest: evidence,
                            provenanceDigest: evidence,
                            observedGeneration: 7
                        )
                    )
                )
            ]
        )
    }

    private func makeReservation(
        context: AcceleratorAuthenticationContext
    ) throws -> AcceleratorReservation {
        try AcceleratorReservation(
            reservationID: reservationID,
            claimID: claimID,
            scope: .workload(projectID: projectID, workloadID: workloadID),
            mode: .metal,
            modelHash: try digest("c"),
            budget: AcceleratorBudgetVector(
                memoryBytes: 1_024,
                computeUnits: 10,
                concurrencyUnits: 1
            ),
            inventorySnapshotID: snapshotID,
            inventoryGeneration: 3,
            fence: try AcceleratorFence(nodeEpoch: 1, reservationSequence: 4),
            owner: context,
            createdAt: now,
            expiresAt: now.addingTimeInterval(100)
        )
    }

    private func transitionRequest(
        transition: AcceleratorReservationTransition,
        context: AcceleratorAuthenticationContext,
        fence: AcceleratorFence,
        observedAt: Date
    ) -> AcceleratorReservationTransitionRequest {
        AcceleratorReservationTransitionRequest(
            transition: transition,
            reservationID: reservationID,
            scope: .workload(projectID: projectID, workloadID: workloadID),
            fence: fence,
            actor: context,
            observedAt: observedAt
        )
    }

    private func digest(_ character: Character) throws -> AcceleratorDigest {
        try AcceleratorDigest(String(repeating: character, count: 64))
    }
}
