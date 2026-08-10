import Foundation
import XCTest
@testable import HostwrightAccelerator

final class AcceleratorContractTests: XCTestCase {
    private let projectID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let workloadID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let hostID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let snapshotID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let now = Date(timeIntervalSince1970: 1_754_000_000)

    func testVersionedInventoryRoundTripsDeterministically() throws {
        let inventory = try makeInventory()

        let data = try JSONEncoder().encode(inventory)
        let decoded = try JSONDecoder().decode(
            AcceleratorInventorySnapshot.self,
            from: data
        )

        XCTAssertEqual(decoded, inventory)
        XCTAssertEqual(inventory.contractVersion, AcceleratorContract.currentVersion)
        XCTAssertEqual(
            inventory.modeEvidence.map(\.mode),
            inventory.modeEvidence.map(\.mode).sorted { $0.rawValue < $1.rawValue }
        )
        XCTAssertEqual(
            inventory.budgets.map(\.orderingKey),
            inventory.budgets.map(\.orderingKey).sorted()
        )
    }

    func testInventoryRequiresEvidenceAndExplicitlyBlocksGuestPassthrough() throws {
        XCTAssertThrowsError(
            try AcceleratorModeEvidence(
                mode: .linuxGuestGPUPassthrough,
                status: .available,
                evidenceDigest: try digest("a"),
                source: .contractBoundary,
                observedGeneration: 3,
                reasonCode: nil
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .linuxGuestPassthroughBlocked
            )
        }

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(try makeInventory())
            ) as? [String: Any]
        )
        var modes = try XCTUnwrap(object["modeEvidence"] as? [[String: Any]])
        let guestIndex = try XCTUnwrap(
            modes.firstIndex { $0["mode"] as? String == "linux-guest-gpu-passthrough" }
        )
        modes[guestIndex]["status"] = "available"
        object["modeEvidence"] = modes

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AcceleratorInventorySnapshot.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testHostileInventoryDecoderRejectsVersionOrderingAndBudgetTampering() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(try makeInventory())
            ) as? [String: Any]
        )
        object["contractVersion"] = 99
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AcceleratorInventorySnapshot.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )

        object["contractVersion"] = AcceleratorContract.currentVersion
        var budgets = try XCTUnwrap(object["budgets"] as? [[String: Any]])
        budgets.swapAt(0, 1)
        object["budgets"] = budgets
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AcceleratorInventorySnapshot.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )

        budgets.swapAt(0, 1)
        budgets[0]["amount"] = 0
        object["budgets"] = budgets
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AcceleratorInventorySnapshot.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testProjectAndWorkloadScopesAreExplicitAndContainmentIsNarrow() throws {
        let project = AcceleratorScope.project(projectID: projectID)
        let workload = AcceleratorScope.workload(
            projectID: projectID,
            workloadID: workloadID
        )
        let otherWorkload = AcceleratorScope.workload(
            projectID: projectID,
            workloadID: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        )

        XCTAssertTrue(project.contains(workload))
        XCTAssertFalse(workload.contains(project))
        XCTAssertFalse(workload.contains(otherWorkload))
        XCTAssertEqual(workload.stableKey, "project:\(projectID.uuidString.lowercased())/workload:\(workloadID.uuidString.lowercased())")
    }

    func testAuthenticatedRecordsRoundTripWithoutSigningOrProviderClaims() throws {
        let auth = try makeAuthentication()
        let data = try JSONEncoder().encode(auth)
        let decoded = try JSONDecoder().decode(
            AcceleratorAuthenticationContext.self,
            from: data
        )

        XCTAssertEqual(decoded, auth)
        XCTAssertTrue(auth.isActive(at: now.addingTimeInterval(1)))
        XCTAssertFalse(auth.isActive(at: now.addingTimeInterval(301)))
    }

    func testCapacityBudgetsRequireCallerMeasuredEvidence() throws {
        let rejectedSources: [AcceleratorEvidenceSource] = [
            .callerMeasuredBudget,
            .metalCurrentAllocatedSize,
            .metalWorkingSetApproximation,
            .coreMLComputeUnitsPolicy,
            .coreMLEligibility,
            .mlxPublicDevice,
            .mlxProcessLocalMemory
        ]
        for source in rejectedSources {
            XCTAssertThrowsError(
                try AcceleratorMeasuredBudget(
                    mode: .metal,
                    kind: .memory,
                    amount: 1,
                    unit: .bytes,
                    source: source,
                    observedGeneration: 1,
                    measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                        executionDigest: try digest("a"),
                        provenanceDigest: try digest("a"),
                        observedGeneration: 1
                    ),
                    measurementEvidenceDigest: try AcceleratorMeasuredBudget.measurementEvidenceDigest(
                        mode: .metal,
                        kind: .memory,
                        amount: 1,
                        unit: .bytes,
                        observedGeneration: 1,
                        measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                            executionDigest: try digest("a"),
                            provenanceDigest: try digest("a"),
                            observedGeneration: 1
                        )
                    )
                )
            ) { error in
                XCTAssertEqual(
                    (error as? AcceleratorValidationError)?.code,
                    .invalidBudget
                )
            }
        }
    }

    private func makeInventory() throws -> AcceleratorInventorySnapshot {
        let evidenceDigest = try digest("a")
        let selfTest: (AcceleratorExecutionMode) throws -> AcceleratorHostNativeExecutionEvidence = { mode in
            try AcceleratorHostNativeExecutionEvidence(
                mode: mode,
                backendIdentifier: mode.rawValue,
                frameworkIdentifier: "host-native",
                operatingSystem: "macos",
                executionDigest: evidenceDigest,
                provenanceDigest: evidenceDigest,
                observedGeneration: 3,
                observedAt: self.now,
                completedAt: self.now.addingTimeInterval(1)
            )
        }
        let modes = [
            try AcceleratorModeEvidence(
                mode: .coreML,
                status: .available,
                evidenceDigest: evidenceDigest,
                source: .hostNativeExecutionSelfTest,
                observedGeneration: 3,
                executionEvidence: try selfTest(.coreML)
            ),
            try AcceleratorModeEvidence(
                mode: .linuxGuestANEPassthrough,
                status: .blocked,
                evidenceDigest: evidenceDigest,
                source: .contractBoundary,
                observedGeneration: 3,
                reasonCode: .linuxGuestPassthroughBlocked
            ),
            try AcceleratorModeEvidence(
                mode: .linuxGuestGPUPassthrough,
                status: .blocked,
                evidenceDigest: evidenceDigest,
                source: .contractBoundary,
                observedGeneration: 3,
                reasonCode: .linuxGuestPassthroughBlocked
            ),
            try AcceleratorModeEvidence(
                mode: .metal,
                status: .available,
                evidenceDigest: evidenceDigest,
                source: .hostNativeExecutionSelfTest,
                observedGeneration: 3,
                executionEvidence: try selfTest(.metal)
            ),
            try AcceleratorModeEvidence(
                mode: .mlxSwift,
                status: .available,
                evidenceDigest: evidenceDigest,
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
                    executionDigest: evidenceDigest,
                    provenanceDigest: evidenceDigest,
                    observedGeneration: 3
                ),
                measurementEvidenceDigest: try AcceleratorMeasuredBudget.measurementEvidenceDigest(
                    mode: .metal,
                    kind: .compute,
                    amount: 10_000,
                    unit: .computeUnits,
                    observedGeneration: 3,
                    measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                        executionDigest: evidenceDigest,
                        provenanceDigest: evidenceDigest,
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
                    executionDigest: evidenceDigest,
                    provenanceDigest: evidenceDigest,
                    observedGeneration: 3
                ),
                measurementEvidenceDigest: try AcceleratorMeasuredBudget.measurementEvidenceDigest(
                    mode: .metal,
                    kind: .concurrency,
                    amount: 8,
                    unit: .concurrentExecutions,
                    observedGeneration: 3,
                    measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                        executionDigest: evidenceDigest,
                        provenanceDigest: evidenceDigest,
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
                    executionDigest: evidenceDigest,
                    provenanceDigest: evidenceDigest,
                    observedGeneration: 3
                ),
                measurementEvidenceDigest: try AcceleratorMeasuredBudget.measurementEvidenceDigest(
                    mode: .metal,
                    kind: .memory,
                    amount: 64 * 1024 * 1024,
                    unit: .bytes,
                    observedGeneration: 3,
                    measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                        executionDigest: evidenceDigest,
                        provenanceDigest: evidenceDigest,
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

    private func makeAuthentication() throws -> AcceleratorAuthenticationContext {
        try AcceleratorAuthenticationContext(
            subjectID: "subject-owner",
            sessionID: "session-1",
            credentialID: "credential-1",
            authenticationDigest: try digest("b"),
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
    }

    private func digest(_ character: Character) throws -> AcceleratorDigest {
        try AcceleratorDigest(String(repeating: character, count: 64))
    }
}
