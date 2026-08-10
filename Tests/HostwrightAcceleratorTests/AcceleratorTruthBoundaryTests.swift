import Foundation
import XCTest
@testable import HostwrightAccelerator

final class AcceleratorTruthBoundaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_754_000_000)
    private let snapshotID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let hostID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    func testAvailabilityRequiresSuccessfulHostNativeSelfTestEvidence() throws {
        let digest = try fixedDigest("a")
        for source in [
            AcceleratorEvidenceSource.contractBoundary,
            .callerObservedEvidence,
            .metalRegistryIdentity,
            .coreMLComputeUnitsPolicy,
            .coreMLEligibility,
            .mlxPublicDevice
        ] {
            XCTAssertThrowsError(
                try AcceleratorModeEvidence(
                    mode: .metal,
                    status: .available,
                    evidenceDigest: digest,
                    source: source,
                    observedGeneration: 1
                )
            )
        }

        let selfTest = try AcceleratorHostNativeExecutionEvidence(
            mode: .metal,
            backendIdentifier: "metal",
            frameworkIdentifier: "metal",
            operatingSystem: "macos",
            executionDigest: digest,
            provenanceDigest: digest,
            observedGeneration: 1,
            observedAt: now,
            completedAt: now.addingTimeInterval(1)
        )
        XCTAssertNoThrow(
            try AcceleratorModeEvidence(
                mode: .metal,
                status: .available,
                evidenceDigest: digest,
                source: .hostNativeExecutionSelfTest,
                observedGeneration: 1,
                executionEvidence: selfTest
            )
        )
        XCTAssertThrowsError(
            try AcceleratorModeEvidence(
                mode: .metal,
                status: .available,
                evidenceDigest: try fixedDigest("b"),
                source: .hostNativeExecutionSelfTest,
                observedGeneration: 1,
                executionEvidence: selfTest
            )
        )
    }

    func testNoAvailabilityOrBudgetIsInferredFromDeviceOrPolicyFacts() throws {
        let digest = try fixedDigest("a")
        let modes = [
            try AcceleratorModeEvidence(
                mode: .coreML,
                status: .unavailable,
                evidenceDigest: digest,
                source: .coreMLEligibility,
                observedGeneration: 2,
                reasonCode: .evidenceUnavailable
            ),
            try blocked(.linuxGuestANEPassthrough, digest: digest),
            try blocked(.linuxGuestGPUPassthrough, digest: digest),
            try AcceleratorModeEvidence(
                mode: .metal,
                status: .unavailable,
                evidenceDigest: digest,
                source: .metalRegistryIdentity,
                observedGeneration: 2,
                reasonCode: .evidenceUnavailable
            ),
            try AcceleratorModeEvidence(
                mode: .mlxSwift,
                status: .unavailable,
                evidenceDigest: digest,
                source: .mlxPublicDevice,
                observedGeneration: 2,
                reasonCode: .evidenceUnavailable
            ),
        ]
        let inventory = try AcceleratorInventorySnapshot(
            snapshotID: snapshotID,
            hostID: hostID,
            observedAt: now,
            observedGeneration: 2,
            modeEvidence: modes,
            budgets: []
        )
        XCTAssertTrue(inventory.budgets.isEmpty)
        XCTAssertTrue(inventory.modeEvidence.allSatisfy { $0.status != .available })
        XCTAssertNil(inventory.budget(for: .metal, kind: .memory))
    }

    func testMeasuredBudgetIsModeScopedAndDigestBound() throws {
        let digest = try fixedDigest("a")
        let measurementEvidence = try AcceleratorBudgetMeasurementEvidence(
            executionDigest: digest,
            provenanceDigest: digest,
            observedGeneration: 1
        )
        let expected = try AcceleratorMeasuredBudget.measurementEvidenceDigest(
            mode: .metal,
            kind: .memory,
            amount: 4096,
            unit: .bytes,
            observedGeneration: 1,
            measurementEvidence: measurementEvidence
        )
        XCTAssertNoThrow(
            try AcceleratorMeasuredBudget(
                mode: .metal,
                kind: .memory,
                amount: 4096,
                unit: .bytes,
                source: .hostNativeModeMeasurement,
                observedGeneration: 1,
                measurementEvidence: measurementEvidence,
                measurementEvidenceDigest: expected
            )
        )
        XCTAssertThrowsError(
            try AcceleratorMeasuredBudget(
                mode: nil,
                kind: .memory,
                amount: 4096,
                unit: .bytes,
                source: .hostNativeModeMeasurement,
                observedGeneration: 1,
                measurementEvidence: measurementEvidence,
                measurementEvidenceDigest: expected
            )
        )
        XCTAssertThrowsError(
            try AcceleratorMeasuredBudget(
                mode: .metal,
                kind: .memory,
                amount: 4096,
                unit: .bytes,
                source: .hostNativeModeMeasurement,
                observedGeneration: 1,
                measurementEvidence: measurementEvidence,
                measurementEvidenceDigest: digest
            )
        )
    }

    func testInventoryRejectsBudgetForUnavailableMode() throws {
        let digest = try fixedDigest("a")
        let measurementEvidence = try AcceleratorBudgetMeasurementEvidence(
            executionDigest: digest,
            provenanceDigest: digest,
            observedGeneration: 1
        )
        let budgetDigest = try AcceleratorMeasuredBudget.measurementEvidenceDigest(
            mode: .metal,
            kind: .memory,
            amount: 4096,
            unit: .bytes,
            observedGeneration: 1,
            measurementEvidence: measurementEvidence
        )
        let budget = try AcceleratorMeasuredBudget(
            mode: .metal,
            kind: .memory,
            amount: 4096,
            unit: .bytes,
            source: .hostNativeModeMeasurement,
            observedGeneration: 1,
            measurementEvidence: measurementEvidence,
            measurementEvidenceDigest: budgetDigest
        )
        XCTAssertThrowsError(
            try AcceleratorInventorySnapshot(
                snapshotID: snapshotID,
                hostID: hostID,
                observedAt: now,
                observedGeneration: 1,
                modeEvidence: [
                    try unavailable(.metal, digest: digest),
                    try unavailable(.coreML, digest: digest),
                    try unavailable(.mlxSwift, digest: digest),
                    try blocked(.linuxGuestGPUPassthrough, digest: digest),
                    try blocked(.linuxGuestANEPassthrough, digest: digest)
                ],
                budgets: [budget]
            )
        )
    }

    func testMeasuredBudgetRejectsStructuredEvidenceMutationOnDecode() throws {
        let digest = try fixedDigest("a")
        let measurementEvidence = try AcceleratorBudgetMeasurementEvidence(
            executionDigest: digest,
            provenanceDigest: digest,
            observedGeneration: 1
        )
        let budgetDigest = try AcceleratorMeasuredBudget.measurementEvidenceDigest(
            mode: .metal,
            kind: .memory,
            amount: 4096,
            unit: .bytes,
            observedGeneration: 1,
            measurementEvidence: measurementEvidence
        )
        let budget = try AcceleratorMeasuredBudget(
            mode: .metal,
            kind: .memory,
            amount: 4096,
            unit: .bytes,
            source: .hostNativeModeMeasurement,
            observedGeneration: 1,
            measurementEvidence: measurementEvidence,
            measurementEvidenceDigest: budgetDigest
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(budget)
            ) as? [String: Any]
        )
        var evidence = try XCTUnwrap(
            object["measurementEvidence"] as? [String: Any]
        )
        evidence["provenanceDigest"] = try fixedDigest("b").value
        object["measurementEvidence"] = evidence
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AcceleratorMeasuredBudget.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    private func unavailable(
        _ mode: AcceleratorExecutionMode,
        digest: AcceleratorDigest
    ) throws -> AcceleratorModeEvidence {
        try AcceleratorModeEvidence(
            mode: mode,
            status: .unavailable,
            evidenceDigest: digest,
            source: .contractBoundary,
            observedGeneration: 1,
            reasonCode: .evidenceUnavailable
        )
    }

    private func blocked(
        _ mode: AcceleratorExecutionMode,
        digest: AcceleratorDigest
    ) throws -> AcceleratorModeEvidence {
        try AcceleratorModeEvidence(
            mode: mode,
            status: .blocked,
            evidenceDigest: digest,
            source: .contractBoundary,
            observedGeneration: 1,
            reasonCode: .linuxGuestPassthroughBlocked
        )
    }

    private func fixedDigest(_ character: Character) throws -> AcceleratorDigest {
        try AcceleratorDigest(String(repeating: character, count: 64))
    }
}
