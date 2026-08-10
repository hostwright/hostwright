import Foundation
import XCTest
@testable import HostwrightAccelerator

final class AcceleratorHostileDecoderTests: XCTestCase {
    private let projectID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let workloadID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let hostID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let snapshotID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let claimID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    private let reservationID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    private let grantID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    private let requestID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    private let now = Date(timeIntervalSince1970: 1_754_000_000)

    func testZeroUUIDIsRejectedAcrossUUIDBearingRecords() throws {
        let context = try makeContext()
        let inventory = try makeInventory()
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
        let modelHash = try digest("c")
        let claim = try AcceleratorClaim(
            claimID: claimID,
            scope: .project(projectID: projectID),
            allowedModes: [.metal],
            modelHash: modelHash,
            quota: quota,
            inventorySnapshotID: snapshotID,
            inventoryGeneration: 3,
            issuer: context,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
        let reservation = try AcceleratorReservation(
            reservationID: reservationID,
            claimID: claimID,
            scope: .workload(projectID: projectID, workloadID: workloadID),
            mode: .metal,
            modelHash: modelHash,
            budget: AcceleratorBudgetVector(
                memoryBytes: 2 * 1024 * 1024,
                computeUnits: 200,
                concurrencyUnits: 1
            ),
            inventorySnapshotID: snapshotID,
            inventoryGeneration: 3,
            fence: try AcceleratorFence(nodeEpoch: 4, reservationSequence: 9),
            owner: context,
            createdAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let committed = try AcceleratorReservationStateMachine().transition(
            reservation: reservation,
            request: AcceleratorReservationTransitionRequest(
                transition: .commit,
                reservationID: reservationID,
                scope: reservation.scope,
                fence: reservation.fence,
                actor: context,
                observedAt: now.addingTimeInterval(1)
            )
        )
        let grant = try AcceleratorGrant(
            grantID: grantID,
            claimID: claimID,
            reservationID: reservationID,
            scope: reservation.scope,
            granteeSubjectID: context.subjectID,
            mode: .metal,
            modelHash: modelHash,
            quota: quota,
            inventorySnapshotID: snapshotID,
            inventoryGeneration: 3,
            fence: committed.fence,
            issuer: context,
            issuedAt: now.addingTimeInterval(1),
            expiresAt: now.addingTimeInterval(120)
        )
        let request = try AcceleratorExecutionRequest(
            requestID: requestID,
            grantID: grantID,
            reservationID: reservationID,
            scope: reservation.scope,
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
        let usage = try AcceleratorMeasuredUsage(
            budget: request.budget,
            source: .callerMeasuredUsage,
            observedGeneration: 3,
            authenticatedBy: context,
            observedAt: now.addingTimeInterval(3)
        )
        let provenance = try AcceleratorExecutionProvenance(
            requestID: request.requestID,
            mode: request.mode,
            modelHash: request.modelHash,
            inventorySnapshotID: snapshotID,
            inventoryGeneration: 3,
            evidenceDigest: try digest("a"),
            source: .callerObservedEvidence,
            authenticatedBy: context,
            recordedAt: now.addingTimeInterval(3)
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
            completedAt: now.addingTimeInterval(4),
            authenticatedBy: context,
            errorCode: nil
        )
        let transitionRequest = AcceleratorReservationTransitionRequest(
            transition: .release,
            reservationID: committed.reservationID,
            scope: committed.scope,
            fence: committed.fence,
            actor: context,
            observedAt: now.addingTimeInterval(5)
        )
        let cancellation = try AcceleratorCancellationRecord(
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            requestID: requestID,
            grantID: grantID,
            reservationID: reservationID,
            scope: request.scope,
            fence: request.fence,
            actor: context,
            reason: "operator-request",
            requestedAt: now,
            state: .requested,
            effectiveAt: nil
        )
        let revocation = try AcceleratorRevocationRecord(
            revocationID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            targetKind: .reservation,
            targetIdentifier: reservationID.uuidString.lowercased(),
            scope: reservation.scope,
            fence: reservation.fence,
            actor: context,
            reason: "operator-request",
            evidenceDigest: try digest("e"),
            revokedAt: now.addingTimeInterval(5)
        )
        let zeroUUID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
        XCTAssertThrowsError(
            try AcceleratorClaim(
                claimID: claimID,
                scope: .project(projectID: zeroUUID),
                allowedModes: [.metal],
                modelHash: modelHash,
                quota: quota,
                inventorySnapshotID: snapshotID,
                inventoryGeneration: 3,
                issuer: context,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(300)
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .invalidIdentifier
            )
        }

        try assertZeroUUIDRejected(inventory, key: "snapshotID")
        try assertZeroUUIDRejected(claim, key: "claimID")
        try assertZeroUUIDRejected(reservation, key: "reservationID")
        try assertZeroUUIDRejected(grant, key: "grantID")
        try assertZeroUUIDRejected(request, key: "requestID")
        try assertZeroUUIDRejected(provenance, key: "requestID")
        try assertZeroUUIDRejected(result, key: "requestID")
        try assertZeroUUIDRejected(transitionRequest, key: "reservationID")
        try assertZeroUUIDRejected(cancellation, key: "cancellationID")
        try assertZeroUUIDRejected(revocation, key: "revocationID")
    }

    func testDateRangeValidationUsesStableInterpolatedField() throws {
        XCTAssertThrowsError(
            try AcceleratorAuthenticationContext(
                subjectID: "subject-owner",
                sessionID: "session-1",
                authenticationDigest: try digest("a"),
                authenticatedAt: now,
                expiresAt: now
            )
        ) { error in
            let validationError = error as? AcceleratorValidationError
            XCTAssertEqual(validationError?.code, .invalidTimestamp)
            XCTAssertEqual(
                validationError?.field,
                "authenticatedAt-expiresAt-order"
            )
            XCTAssertEqual(
                validationError?.description,
                "invalid-timestamp:authenticatedAt-expiresAt-order"
            )
        }
    }

    private func assertZeroUUIDRejected<T: Codable>(
        _ value: T,
        key: String,
        as type: T.Type = T.self,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(value)
            ) as? [String: Any],
            file: file,
            line: line
        )
        object[key] = "00000000-0000-0000-0000-000000000000"
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                type,
                from: JSONSerialization.data(withJSONObject: object)
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .invalidIdentifier,
                file: file,
                line: line
            )
        }
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
                observedGeneration: 3,
                observedAt: self.now,
                completedAt: self.now.addingTimeInterval(1)
            )
        }
        let modes = [
            try AcceleratorModeEvidence(
                mode: .coreML,
                status: .available,
                evidenceDigest: evidence,
                source: .hostNativeExecutionSelfTest,
                observedGeneration: 3,
                executionEvidence: try selfTest(.coreML)
            ),
            try AcceleratorModeEvidence(
                mode: .linuxGuestANEPassthrough,
                status: .blocked,
                evidenceDigest: evidence,
                source: .contractBoundary,
                observedGeneration: 3,
                reasonCode: .linuxGuestPassthroughBlocked
            ),
            try AcceleratorModeEvidence(
                mode: .linuxGuestGPUPassthrough,
                status: .blocked,
                evidenceDigest: evidence,
                source: .contractBoundary,
                observedGeneration: 3,
                reasonCode: .linuxGuestPassthroughBlocked
            ),
            try AcceleratorModeEvidence(
                mode: .metal,
                status: .available,
                evidenceDigest: evidence,
                source: .hostNativeExecutionSelfTest,
                observedGeneration: 3,
                executionEvidence: try selfTest(.metal)
            ),
            try AcceleratorModeEvidence(
                mode: .mlxSwift,
                status: .available,
                evidenceDigest: evidence,
                source: .hostNativeExecutionSelfTest,
                observedGeneration: 3,
                executionEvidence: try selfTest(.mlxSwift)
            )
        ]
        let budgets = [
            try AcceleratorMeasuredBudget(
                mode: .metal,
                kind: .compute,
                amount: 10_000,
                unit: .computeUnits,
                source: .hostNativeModeMeasurement,
                observedGeneration: 3,
                measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                    executionDigest: evidence,
                    provenanceDigest: evidence,
                    observedGeneration: 3
                ),
                measurementEvidenceDigest: try AcceleratorMeasuredBudget.measurementEvidenceDigest(
                    mode: .metal,
                    kind: .compute,
                    amount: 10_000,
                    unit: .computeUnits,
                    observedGeneration: 3,
                    measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                        executionDigest: evidence,
                        provenanceDigest: evidence,
                        observedGeneration: 3
                    )
                )
            ),
            try AcceleratorMeasuredBudget(
                mode: .metal,
                kind: .concurrency,
                amount: 8,
                unit: .concurrentExecutions,
                source: .hostNativeModeMeasurement,
                observedGeneration: 3,
                measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                    executionDigest: evidence,
                    provenanceDigest: evidence,
                    observedGeneration: 3
                ),
                measurementEvidenceDigest: try AcceleratorMeasuredBudget.measurementEvidenceDigest(
                    mode: .metal,
                    kind: .concurrency,
                    amount: 8,
                    unit: .concurrentExecutions,
                    observedGeneration: 3,
                    measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                        executionDigest: evidence,
                        provenanceDigest: evidence,
                        observedGeneration: 3
                    )
                )
            ),
            try AcceleratorMeasuredBudget(
                mode: .metal,
                kind: .memory,
                amount: 64 * 1024 * 1024,
                unit: .bytes,
                source: .hostNativeModeMeasurement,
                observedGeneration: 3,
                measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                    executionDigest: evidence,
                    provenanceDigest: evidence,
                    observedGeneration: 3
                ),
                measurementEvidenceDigest: try AcceleratorMeasuredBudget.measurementEvidenceDigest(
                    mode: .metal,
                    kind: .memory,
                    amount: 64 * 1024 * 1024,
                    unit: .bytes,
                    observedGeneration: 3,
                    measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                        executionDigest: evidence,
                        provenanceDigest: evidence,
                        observedGeneration: 3
                    )
                )
            )
        ]
        return try AcceleratorInventorySnapshot(
            snapshotID: snapshotID,
            hostID: hostID,
            observedAt: now,
            observedGeneration: 3,
            modeEvidence: modes,
            budgets: budgets
        )
    }

    private func digest(_ character: Character) throws -> AcceleratorDigest {
        try AcceleratorDigest(String(repeating: character, count: 64))
    }
}
