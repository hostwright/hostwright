import Foundation
import XCTest
import HostwrightAccelerator

final class Phase10AcceleratorNegativeQualificationTests: XCTestCase {
    private let projectID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let workloadID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let snapshotID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let claimID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    private let reservationID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    private let grantID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    private let requestID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    private let now = Date(timeIntervalSince1970: 1_754_000_000)

    func testGuestPassthroughCannotBeClaimedReservedGrantedOrRequested() throws {
        let context = try makeAuthentication()
        let digest = try digest("a")
        let budget = try AcceleratorBudgetVector(
            memoryBytes: 1,
            computeUnits: 1,
            concurrencyUnits: 1
        )
        let quota = try AcceleratorQuota(
            budget: budget,
            maxInputBytes: 1,
            maxOutputBytes: 1,
            maxTimeoutMilliseconds: 1
        )
        let scope = AcceleratorScope.workload(
            projectID: projectID,
            workloadID: workloadID
        )
        let fence = try AcceleratorFence(nodeEpoch: 1, reservationSequence: 1)

        // Deliberately invalid synthetic input; this is not host-native
        // capability evidence.
        XCTAssertThrowsError(
            try AcceleratorModeEvidence(
                mode: .linuxGuestGPUPassthrough,
                status: .available,
                evidenceDigest: digest,
                source: .callerObservedEvidence,
                observedGeneration: 1
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .linuxGuestPassthroughBlocked
            )
        }

        XCTAssertThrowsError(
            try AcceleratorClaim(
                claimID: claimID,
                scope: .project(projectID: projectID),
                allowedModes: [.linuxGuestGPUPassthrough],
                modelHash: digest,
                quota: quota,
                inventorySnapshotID: snapshotID,
                inventoryGeneration: 1,
                issuer: context,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(10)
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .linuxGuestPassthroughBlocked
            )
        }

        XCTAssertThrowsError(
            try AcceleratorReservation(
                reservationID: reservationID,
                claimID: claimID,
                scope: scope,
                mode: .linuxGuestGPUPassthrough,
                modelHash: digest,
                budget: budget,
                inventorySnapshotID: snapshotID,
                inventoryGeneration: 1,
                fence: fence,
                owner: context,
                createdAt: now,
                expiresAt: now.addingTimeInterval(10)
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .linuxGuestPassthroughBlocked
            )
        }

        XCTAssertThrowsError(
            try AcceleratorGrant(
                grantID: grantID,
                claimID: claimID,
                reservationID: reservationID,
                scope: scope,
                granteeSubjectID: context.subjectID,
                mode: .linuxGuestGPUPassthrough,
                modelHash: digest,
                quota: quota,
                inventorySnapshotID: snapshotID,
                inventoryGeneration: 1,
                fence: fence,
                issuer: context,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(10)
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .linuxGuestPassthroughBlocked
            )
        }

        XCTAssertThrowsError(
            try AcceleratorExecutionRequest(
                requestID: requestID,
                grantID: grantID,
                reservationID: reservationID,
                scope: scope,
                mode: .linuxGuestGPUPassthrough,
                modelHash: digest,
                inputDigest: digest,
                inputBytes: 1,
                outputLimitBytes: 1,
                timeoutMilliseconds: 1,
                budget: budget,
                fence: fence,
                authentication: context,
                requestedAt: now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .linuxGuestPassthroughBlocked
            )
        }
    }

    func testUnavailableAndBlockedModeEvidenceRemainsExplicitAfterRoundTrip() throws {
        let evidenceDigest = try digest("b")
        let modes = [
            try AcceleratorModeEvidence(
                mode: .coreML,
                status: .unavailable,
                evidenceDigest: evidenceDigest,
                source: .contractBoundary,
                observedGeneration: 4,
                reasonCode: .evidenceUnavailable
            ),
            try AcceleratorModeEvidence(
                mode: .linuxGuestANEPassthrough,
                status: .blocked,
                evidenceDigest: evidenceDigest,
                source: .contractBoundary,
                observedGeneration: 4,
                reasonCode: .linuxGuestPassthroughBlocked
            ),
            try AcceleratorModeEvidence(
                mode: .linuxGuestGPUPassthrough,
                status: .blocked,
                evidenceDigest: evidenceDigest,
                source: .contractBoundary,
                observedGeneration: 4,
                reasonCode: .linuxGuestPassthroughBlocked
            ),
            try AcceleratorModeEvidence(
                mode: .metal,
                status: .unavailable,
                evidenceDigest: evidenceDigest,
                source: .contractBoundary,
                observedGeneration: 4,
                reasonCode: .policyUnavailable
            ),
            try AcceleratorModeEvidence(
                mode: .mlxSwift,
                status: .blocked,
                evidenceDigest: evidenceDigest,
                source: .contractBoundary,
                observedGeneration: 4,
                reasonCode: .policyUnavailable
            )
        ]
        let inventory = try AcceleratorInventorySnapshot(
            snapshotID: snapshotID,
            hostID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            observedAt: now,
            observedGeneration: 4,
            modeEvidence: modes,
            budgets: []
        )

        XCTAssertTrue(
            inventory.modeEvidence.allSatisfy { $0.status != .available },
            "the pending inventory must not imply an available accelerator"
        )
        XCTAssertEqual(
            inventory.evidence(for: .metal)?.reasonCode,
            .policyUnavailable
        )
        XCTAssertEqual(
            inventory.evidence(for: .coreML)?.reasonCode,
            .evidenceUnavailable
        )
        let decoded = try JSONDecoder().decode(
            AcceleratorInventorySnapshot.self,
            from: JSONEncoder().encode(inventory)
        )
        XCTAssertEqual(decoded, inventory)
    }

    func testCancellationStateAndEffectiveTimeMustAgree() throws {
        let context = try makeAuthentication()
        let scope = AcceleratorScope.workload(
            projectID: projectID,
            workloadID: workloadID
        )
        let fence = try AcceleratorFence(nodeEpoch: 1, reservationSequence: 1)

        XCTAssertThrowsError(
            try makeCancellation(
                actor: context,
                state: .requested,
                effectiveAt: now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .invalidCancellation
            )
        }
        XCTAssertThrowsError(
            try makeCancellation(
                actor: context,
                state: .accepted,
                effectiveAt: nil
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .invalidCancellation
            )
        }
        XCTAssertThrowsError(
            try AcceleratorCancellationRecord(
                cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
                requestID: requestID,
                grantID: grantID,
                reservationID: reservationID,
                scope: scope,
                fence: fence,
                actor: context,
                reason: "operator\nrequest",
                requestedAt: now,
                state: .rejected,
                effectiveAt: nil
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .invalidIdentifier
            )
        }
        XCTAssertNoThrow(
            try makeCancellation(
                actor: context,
                state: .accepted,
                effectiveAt: now.addingTimeInterval(1)
            )
        )
    }

    func testRevocationTargetsRequireCanonicalScopeAndFenceBindings() throws {
        let context = try makeAuthentication()
        let scope = AcceleratorScope.workload(
            projectID: projectID,
            workloadID: workloadID
        )
        let fence = try AcceleratorFence(nodeEpoch: 1, reservationSequence: 1)
        let target = claimID.uuidString.lowercased()
        let nonCanonicalTarget = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"

        XCTAssertThrowsError(
            try AcceleratorRevocationRecord(
                revocationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
                targetKind: .claim,
                targetIdentifier: nonCanonicalTarget,
                scope: .project(projectID: projectID),
                fence: nil,
                actor: context,
                reason: "operator-request",
                evidenceDigest: try digest("c"),
                revokedAt: now
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .invalidIdentifier
            )
        }
        XCTAssertThrowsError(
            try AcceleratorRevocationRecord(
                revocationID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
                targetKind: .claim,
                targetIdentifier: target,
                scope: .project(projectID: projectID),
                fence: fence,
                actor: context,
                reason: "operator-request",
                evidenceDigest: try digest("d"),
                revokedAt: now
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .invalidRevocation
            )
        }
        XCTAssertThrowsError(
            try AcceleratorRevocationRecord(
                revocationID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
                targetKind: .session,
                targetIdentifier: "session-1",
                scope: scope,
                fence: nil,
                actor: context,
                reason: "operator-request",
                evidenceDigest: try digest("e"),
                revokedAt: now
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .invalidRevocation
            )
        }
        XCTAssertThrowsError(
            try AcceleratorRevocationRecord(
                revocationID: UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!,
                targetKind: .grant,
                targetIdentifier: grantID.uuidString.lowercased(),
                scope: scope,
                fence: nil,
                actor: context,
                reason: "operator-request",
                evidenceDigest: try digest("f"),
                revokedAt: now
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .invalidRevocation
            )
        }
    }

    func testFencedCleanupRejectsTerminalReplayAndStaleSequence() throws {
        let context = try makeAuthentication()
        let reservation = try AcceleratorReservation(
            reservationID: reservationID,
            claimID: claimID,
            scope: .workload(projectID: projectID, workloadID: workloadID),
            mode: .metal,
            modelHash: try digest("a"),
            budget: try AcceleratorBudgetVector(
                memoryBytes: 1,
                computeUnits: 1,
                concurrencyUnits: 1
            ),
            inventorySnapshotID: snapshotID,
            inventoryGeneration: 1,
            fence: try AcceleratorFence(nodeEpoch: 1, reservationSequence: 1),
            owner: context,
            createdAt: now,
            expiresAt: now.addingTimeInterval(10)
        )
        let machine = AcceleratorReservationStateMachine()
        let revoked = try machine.transition(
            reservation: reservation,
            request: AcceleratorReservationTransitionRequest(
                transition: .revoke,
                reservationID: reservation.reservationID,
                scope: reservation.scope,
                fence: reservation.fence,
                actor: context,
                observedAt: now.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(revoked.state, .revoked)

        XCTAssertThrowsError(
            try machine.transition(
                reservation: revoked,
                request: AcceleratorReservationTransitionRequest(
                    transition: .release,
                    reservationID: revoked.reservationID,
                    scope: revoked.scope,
                    fence: revoked.fence,
                    actor: context,
                    observedAt: now.addingTimeInterval(2)
                )
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .terminalState
            )
        }

        let staleFence = try AcceleratorFence(nodeEpoch: 1, reservationSequence: 2)
        XCTAssertThrowsError(
            try machine.transition(
                reservation: reservation,
                request: AcceleratorReservationTransitionRequest(
                    transition: .revoke,
                    reservationID: reservation.reservationID,
                    scope: reservation.scope,
                    fence: staleFence,
                    actor: context,
                    observedAt: now.addingTimeInterval(1)
                )
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .staleReservationSequence
            )
        }
    }

    private func makeAuthentication() throws -> AcceleratorAuthenticationContext {
        try AcceleratorAuthenticationContext(
            subjectID: "subject-owner",
            sessionID: "session-1",
            authenticationDigest: try digest("b"),
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
    }

    private func makeCancellation(
        actor: AcceleratorAuthenticationContext,
        state: AcceleratorCancellationState,
        effectiveAt: Date?
    ) throws -> AcceleratorCancellationRecord {
        try AcceleratorCancellationRecord(
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            requestID: requestID,
            grantID: grantID,
            reservationID: reservationID,
            scope: .workload(projectID: projectID, workloadID: workloadID),
            fence: try AcceleratorFence(nodeEpoch: 1, reservationSequence: 1),
            actor: actor,
            reason: "operator-request",
            requestedAt: now,
            state: state,
            effectiveAt: effectiveAt
        )
    }

    private func digest(_ character: Character) throws -> AcceleratorDigest {
        try AcceleratorDigest(String(repeating: character, count: 64))
    }
}
