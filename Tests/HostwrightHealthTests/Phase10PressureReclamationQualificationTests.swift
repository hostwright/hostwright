import Foundation
import XCTest

import HostwrightHealth

final class Phase10PressureReclamationQualificationTests: XCTestCase {
    func testPressureRecoveryRequiresConfiguredClearObservations() throws {
        let policy = HostPressurePolicy(
            configuration: try HostPressurePolicyConfiguration(
                recoveryObservationCount: 2
            )
        )
        let blockedSample = HostPressureSample(
            systemMemoryPressure: .critical,
            observedAt: Date(timeIntervalSince1970: 1_000)
        )

        let blocked = policy.evaluate(sample: blockedSample)
        XCTAssertEqual(blocked.posture, .blocked)
        XCTAssertEqual(blocked.reasonCode, .memoryCritical)

        let clearSample = HostPressureSample(
            observedAt: Date(timeIntervalSince1970: 1_001)
        )
        let firstClear = policy.evaluate(
            sample: clearSample,
            previousState: blocked.nextState
        )
        XCTAssertEqual(firstClear.posture, .blocked)
        XCTAssertEqual(firstClear.reasonCode, .hysteresisRecovery)
        XCTAssertEqual(firstClear.nextState.consecutiveClearObservations, 1)

        let secondClear = policy.evaluate(
            sample: HostPressureSample(observedAt: Date(timeIntervalSince1970: 1_002)),
            previousState: firstClear.nextState
        )
        XCTAssertEqual(secondClear.posture, .allowed)
        XCTAssertEqual(secondClear.reasonCode, .allowed)
        XCTAssertEqual(secondClear.nextState.consecutiveClearObservations, 0)
    }

    func testPressurePowerFactsFailClosedWhenUnavailableOrInconsistent() throws {
        let policy = HostPressurePolicy()
        let unavailable = policy.evaluate(
            sample: HostPressureSample(
                powerSourceAvailability: .unavailable,
                observedAt: Date(timeIntervalSince1970: 2_000)
            )
        )
        XCTAssertEqual(unavailable.posture, .blocked)
        XCTAssertEqual(unavailable.reasonCode, .powerSourceUnavailable)

        let inconsistent = HostPowerSourceSnapshot(
            availability: .noBattery,
            battery: HostBatterySnapshot(chargePercent: 80, powerSource: .ac)
        )
        XCTAssertFalse(inconsistent.isConsistent)

        let validNoBattery = HostPowerSourceSnapshot(availability: .noBattery)
        XCTAssertTrue(validNoBattery.isConsistent)
        XCTAssertEqual(
            policy.evaluate(
                sample: HostPressureSample(
                    powerSourceAvailability: validNoBattery.availability,
                    observedAt: Date(timeIntervalSince1970: 2_001)
                )
            ).posture,
            .allowed
        )
    }

    func testReclamationRequiresOwnershipFenceAndStableSamples() throws {
        let configuration = try VMReclamationConfiguration(stabilitySampleCount: 2)
        let machine = VMReclamationStateMachine(configuration: configuration)
        let vmID = UUID(uuidString: "00000000-0000-0000-0000-000000000710")!
        let digest = String(repeating: "a", count: 64)
        let plannedAt = Date(timeIntervalSince1970: 3_000)
        let before = VMReclamationMemorySample(
            availableBytes: 100,
            totalBytes: 1_000,
            observedAt: plannedAt
        )
        var intent = try VMReclamationIntent(
            vmID: vmID,
            lifecyclePlanDigest: digest,
            fencingToken: 9,
            requestedBytes: 100,
            beforeSample: before,
            ownership: .hostwrightOwned,
            plannedAt: plannedAt,
            expiresAt: Date(timeIntervalSince1970: 3_100),
            configuration: configuration
        )
        let context = VMReclamationTransitionContext(
            vmID: vmID,
            lifecyclePlanDigest: digest,
            fencingToken: intent.fencingToken
        )

        intent = try transition(
            machine,
            intent: intent,
            transition: .stopConfirmed,
            context: context,
            at: 3_001
        ).intent
        intent = try transition(
            machine,
            intent: intent,
            transition: .removeConfirmed,
            context: context,
            at: 3_002
        ).intent
        intent = try transition(
            machine,
            intent: intent,
            transition: .beginVerification,
            context: context,
            at: 3_003
        ).intent

        let firstSample = VMReclamationMemorySample(
            availableBytes: 200,
            totalBytes: 1_000,
            observedAt: Date(timeIntervalSince1970: 3_004)
        )
        let pending = machine.transition(
            intent: intent,
            request: VMReclamationTransitionRequest(
                transition: .memorySample,
                context: context,
                observedAt: firstSample.observedAt,
                memorySample: firstSample
            )
        )
        XCTAssertEqual(pending.state, .held)
        XCTAssertEqual(pending.reasonCode, .stabilityWindowPending)
        XCTAssertEqual(pending.measuredReclaimedBytes, 0)

        let secondSample = VMReclamationMemorySample(
            availableBytes: 220,
            totalBytes: 1_000,
            observedAt: Date(timeIntervalSince1970: 3_005)
        )
        let reclaimed = machine.transition(
            intent: pending.intent,
            request: VMReclamationTransitionRequest(
                transition: .memorySample,
                context: context,
                observedAt: secondSample.observedAt,
                memorySample: secondSample
            )
        )
        XCTAssertEqual(reclaimed.state, .reclaimed)
        XCTAssertEqual(reclaimed.reasonCode, .reclaimed)
        XCTAssertEqual(reclaimed.measuredReclaimedBytes, 100)
    }

    func testReclamationRejectsStaleFenceWithoutAdvancingIntent() throws {
        let configuration = try VMReclamationConfiguration(stabilitySampleCount: 1)
        let machine = VMReclamationStateMachine(configuration: configuration)
        let vmID = UUID(uuidString: "00000000-0000-0000-0000-000000000711")!
        let plannedAt = Date(timeIntervalSince1970: 4_000)
        let intent = try VMReclamationIntent(
            vmID: vmID,
            lifecyclePlanDigest: String(repeating: "b", count: 64),
            fencingToken: 11,
            requestedBytes: 1,
            beforeSample: VMReclamationMemorySample(
                availableBytes: 10,
                totalBytes: 100,
                observedAt: plannedAt
            ),
            ownership: .hostwrightOwned,
            plannedAt: plannedAt,
            expiresAt: Date(timeIntervalSince1970: 4_100),
            configuration: configuration
        )
        let staleContext = VMReclamationTransitionContext(
            vmID: vmID,
            lifecyclePlanDigest: intent.lifecyclePlanDigest,
            fencingToken: 10
        )
        let result = machine.transition(
            intent: intent,
            request: VMReclamationTransitionRequest(
                transition: .stopConfirmed,
                context: staleContext,
                observedAt: Date(timeIntervalSince1970: 4_001)
            )
        )

        XCTAssertEqual(result.errorCode, .staleFence)
        XCTAssertEqual(result.state, .planned)
        XCTAssertEqual(result.intent, intent)
    }

    private func transition(
        _ machine: VMReclamationStateMachine,
        intent: VMReclamationIntent,
        transition: VMReclamationTransition,
        context: VMReclamationTransitionContext,
        at seconds: TimeInterval
    ) throws -> VMReclamationResult {
        let result = machine.transition(
            intent: intent,
            request: VMReclamationTransitionRequest(
                transition: transition,
                context: context,
                observedAt: Date(timeIntervalSince1970: seconds)
            )
        )
        XCTAssertNil(result.errorCode)
        XCTAssertNotEqual(result.state, .failed)
        return result
    }
}
