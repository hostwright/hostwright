import Foundation
import XCTest
@testable import HostwrightHealth

final class HostPressurePolicyTests: XCTestCase {
    private let observationTime = Date(timeIntervalSince1970: 1_754_000_000)

    func testSampleRoundTripsAsCodableAndPreservesCallerObservationTime() throws {
        let sample = HostPressureSample(
            thermalState: .fair,
            isLowPowerModeEnabled: true,
            battery: HostBatterySnapshot(
                chargePercent: 19,
                powerSource: .battery,
                isCharging: false
            ),
            systemMemoryPressure: .warning,
            sleepWakeState: .awake,
            diskPressure: HostDiskPressureSnapshot(
                level: .nominal,
                availableBytes: 80_000,
                totalBytes: 100_000
            ),
            maintenanceState: .inactive,
            availability: .available,
            observedAt: observationTime
        )

        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(HostPressureSample.self, from: data)

        XCTAssertEqual(decoded, sample)
        XCTAssertEqual(decoded.observedAt, observationTime)
    }

    func testWarningFairAndSeriousSignalsDeweightAdmission() {
        let policy = HostPressurePolicy()

        for signal in [
            HostPressureSample(thermalState: .fair, observedAt: observationTime),
            HostPressureSample(systemMemoryPressure: .warning, observedAt: observationTime),
            HostPressureSample(thermalState: .serious, observedAt: observationTime)
        ] {
            let decision = policy.evaluate(sample: signal, previousState: .initial)

            XCTAssertEqual(decision.posture, .deweighted)
            XCTAssertFalse(decision.reasonCodes.isEmpty)
            XCTAssertNotEqual(decision.reasonCode, .allowed)
        }
    }

    func testLowPowerBatteryAndDiskPressureDeweightAdmission() {
        let policy = HostPressurePolicy()
        let sample = HostPressureSample(
            isLowPowerModeEnabled: true,
            battery: HostBatterySnapshot(
                chargePercent: 15,
                powerSource: .battery,
                isCharging: false
            ),
            diskPressure: HostDiskPressureSnapshot(level: .warning),
            observedAt: observationTime
        )

        let decision = policy.evaluate(sample: sample, previousState: .initial)

        XCTAssertEqual(decision.posture, .deweighted)
        XCTAssertTrue(decision.reasonCodes.contains(.lowPowerMode))
        XCTAssertTrue(decision.reasonCodes.contains(.batteryLow))
        XCTAssertTrue(decision.reasonCodes.contains(.diskWarning))
    }

    func testCriticalThermalMemorySleepMaintenanceOrUnavailableBlocksAdmission() {
        let policy = HostPressurePolicy()
        let cases: [(HostPressureSample, HostPressureReasonCode)] = [
            (HostPressureSample(thermalState: .critical, observedAt: observationTime), .thermalCritical),
            (HostPressureSample(systemMemoryPressure: .critical, observedAt: observationTime), .memoryCritical),
            (HostPressureSample(sleepWakeState: .sleeping, observedAt: observationTime), .sleeping),
            (HostPressureSample(maintenanceState: .active, observedAt: observationTime), .maintenance),
            (HostPressureSample(availability: .unavailable, observedAt: observationTime), .hostUnavailable)
        ]

        for (sample, reason) in cases {
            let decision = policy.evaluate(sample: sample, previousState: .initial)

            XCTAssertEqual(decision.posture, .blocked)
            XCTAssertTrue(decision.reasonCodes.contains(reason))
        }
    }

    func testUnknownPressureSignalFailsClosedAsUnavailable() {
        let policy = HostPressurePolicy()
        let sample = HostPressureSample(
            systemMemoryPressure: .unknown,
            observedAt: observationTime
        )

        let decision = policy.evaluate(sample: sample, previousState: .initial)

        XCTAssertEqual(decision.posture, .blocked)
        XCTAssertTrue(decision.reasonCodes.contains(.memoryUnavailable))
    }

    func testNoBatteryEvidenceIsAllowedButPowerSourceQueryFailureBlocks() {
        let noBattery = HostPressureSample(
            powerSourceAvailability: .noBattery,
            observedAt: observationTime
        )
        let unavailable = HostPressureSample(
            powerSourceAvailability: .unavailable,
            observedAt: observationTime
        )

        let noBatteryDecision = HostPressurePolicy().evaluate(
            sample: noBattery,
            previousState: .initial
        )
        let unavailableDecision = HostPressurePolicy().evaluate(
            sample: unavailable,
            previousState: .initial
        )

        XCTAssertEqual(noBatteryDecision.posture, .allowed)
        XCTAssertEqual(unavailableDecision.posture, .blocked)
        XCTAssertTrue(unavailableDecision.reasonCodes.contains(.powerSourceUnavailable))
    }

    func testInconsistentPowerSourceShapesFailClosed() throws {
        let inconsistent = HostPressureSample(
            powerSourceAvailability: .available,
            observedAt: observationTime
        )
        let decision = HostPressurePolicy().evaluate(
            sample: inconsistent,
            previousState: .initial
        )
        XCTAssertEqual(decision.posture, .blocked)
        XCTAssertTrue(decision.reasonCodes.contains(.powerSourceUnavailable))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(HostPressureSample(observedAt: observationTime))
            ) as? [String: Any]
        )
        object["powerSourceAvailability"] = HostPowerSourceAvailability.available.rawValue
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                HostPressureSample.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testCriticalDiskPressureBlocksAdmissionConservatively() {
        let sample = HostPressureSample(
            diskPressure: HostDiskPressureSnapshot(level: .critical),
            observedAt: observationTime
        )

        let decision = HostPressurePolicy().evaluate(
            sample: sample,
            previousState: .initial
        )

        XCTAssertEqual(decision.posture, .blocked)
        XCTAssertTrue(decision.reasonCodes.contains(.diskCritical))
    }

    func testRecoveryHysteresisIsExplicitAndDeterministic() {
        let policy = HostPressurePolicy(
            configuration: try! HostPressurePolicyConfiguration(
                recoveryObservationCount: 2
            )
        )
        let deweighted = policy.evaluate(
            sample: HostPressureSample(thermalState: .fair, observedAt: observationTime),
            previousState: .initial
        )
        XCTAssertEqual(deweighted.posture, .deweighted)

        let firstClear = policy.evaluate(
            sample: HostPressureSample(observedAt: observationTime.addingTimeInterval(1)),
            previousState: deweighted.nextState
        )
        XCTAssertEqual(firstClear.posture, .deweighted)
        XCTAssertEqual(firstClear.reasonCodes, [.hysteresisRecovery])

        let secondClear = policy.evaluate(
            sample: HostPressureSample(observedAt: observationTime.addingTimeInterval(2)),
            previousState: firstClear.nextState
        )
        XCTAssertEqual(secondClear.posture, .allowed)
        XCTAssertEqual(secondClear.reasonCodes, [.allowed])
    }

    func testDeweightedRecoveryDecisionRoundTripsBeforeDurableProjection() throws {
        let policy = HostPressurePolicy(
            configuration: try HostPressurePolicyConfiguration(
                recoveryObservationCount: 2
            )
        )
        let warning = policy.evaluate(
            sample: HostPressureSample(
                systemMemoryPressure: .warning,
                observedAt: observationTime
            )
        )
        let recovery = policy.evaluate(
            sample: HostPressureSample(observedAt: observationTime.addingTimeInterval(1)),
            previousState: warning.nextState
        )

        XCTAssertEqual(recovery.posture, .deweighted)
        XCTAssertEqual(recovery.reasonCodes, [.hysteresisRecovery])
        XCTAssertEqual(
            try JSONDecoder().decode(
                HostPressurePolicyDecision.self,
                from: JSONEncoder().encode(recovery)
            ),
            recovery
        )
    }

    func testBlockedRecoveryRequiresTheSameExplicitClearObservationCount() {
        let policy = HostPressurePolicy(
            configuration: try! HostPressurePolicyConfiguration(
                recoveryObservationCount: 2
            )
        )
        let blocked = policy.evaluate(
            sample: HostPressureSample(systemMemoryPressure: .critical, observedAt: observationTime),
            previousState: .initial
        )
        XCTAssertEqual(blocked.posture, .blocked)

        let firstClear = policy.evaluate(
            sample: HostPressureSample(observedAt: observationTime.addingTimeInterval(1)),
            previousState: blocked.nextState
        )
        XCTAssertEqual(firstClear.posture, .blocked)
        XCTAssertEqual(firstClear.reasonCodes, [.hysteresisRecovery])

        let secondClear = policy.evaluate(
            sample: HostPressureSample(observedAt: observationTime.addingTimeInterval(2)),
            previousState: firstClear.nextState
        )
        XCTAssertEqual(secondClear.posture, .allowed)
    }

    func testBlockedRecoveryRequiresConsecutiveNonblockingSamplesBeforeDeweighting() {
        let policy = HostPressurePolicy(
            configuration: try! HostPressurePolicyConfiguration(
                recoveryObservationCount: 2
            )
        )
        let blocked = policy.evaluate(
            sample: HostPressureSample(systemMemoryPressure: .critical, observedAt: observationTime),
            previousState: .initial
        )

        let firstWarning = policy.evaluate(
            sample: HostPressureSample(thermalState: .warning, observedAt: observationTime.addingTimeInterval(1)),
            previousState: blocked.nextState
        )
        XCTAssertEqual(firstWarning.posture, .blocked)
        XCTAssertEqual(firstWarning.reasonCodes, [.hysteresisRecovery])

        let secondWarning = policy.evaluate(
            sample: HostPressureSample(thermalState: .warning, observedAt: observationTime.addingTimeInterval(2)),
            previousState: firstWarning.nextState
        )
        XCTAssertEqual(secondWarning.posture, .deweighted)
        XCTAssertEqual(secondWarning.reasonCodes, [.thermalWarning])
    }

    func testPolicyAndHysteresisVersionsAreCarriedThroughReplayDecision() throws {
        let configuration = try! HostPressurePolicyConfiguration(
            recoveryObservationCount: 2,
            version: 1
        )
        let policy = HostPressurePolicy(configuration: configuration)
        let decision = policy.evaluate(
            sample: HostPressureSample(thermalState: .fair, observedAt: observationTime),
            previousState: try! HostPressureHysteresisState(version: 1)
        )

        XCTAssertEqual(configuration.version, 1)
        XCTAssertEqual(decision.version, 1)
        XCTAssertEqual(decision.nextState.version, 1)

        let stateData = try JSONEncoder().encode(decision.nextState)
        let decodedState = try JSONDecoder().decode(
            HostPressureHysteresisState.self,
            from: stateData
        )
        XCTAssertEqual(decodedState.version, 1)
    }

    func testInvalidPolicyConfigurationIsRejectedOnConstructionAndDecode() throws {
        XCTAssertThrowsError(
            try HostPressurePolicyConfiguration(version: 99)
        )
        XCTAssertThrowsError(
            try HostPressurePolicyConfiguration(recoveryObservationCount: 0)
        )
        XCTAssertThrowsError(
            try HostPressurePolicyConfiguration(batteryDeweightBelowPercent: .nan)
        )

        let valid = try HostPressurePolicyConfiguration()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(valid)
            ) as? [String: Any]
        )
        object["version"] = 99
        let hostileData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                HostPressurePolicyConfiguration.self,
                from: hostileData
            )
        )
    }

    func testPriorHysteresisVersionMismatchFailsClosed() throws {
        let policy = HostPressurePolicy()
        let decision = policy.evaluate(
            sample: HostPressureSample(observedAt: observationTime),
            previousState: try HostPressureHysteresisState(version: 2)
        )

        XCTAssertEqual(decision.posture, .blocked)
        XCTAssertEqual(decision.reasonCodes, [.hysteresisVersionMismatch])
        XCTAssertEqual(decision.version, policy.configuration.version)
    }

    func testDecisionDecoderRejectsInconsistentPostureAndReasons() throws {
        let decision = HostPressurePolicy().evaluate(
            sample: HostPressureSample(thermalState: .fair, observedAt: observationTime),
            previousState: .initial
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(decision)
            ) as? [String: Any]
        )
        object["posture"] = HostAdmissionPosture.allowed.rawValue
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                HostPressurePolicyDecision.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )

        object["posture"] = decision.posture.rawValue
        object["reasonCodes"] = []
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                HostPressurePolicyDecision.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }
}
