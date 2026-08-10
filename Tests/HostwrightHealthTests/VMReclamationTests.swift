import Foundation
import XCTest
@testable import HostwrightHealth

final class VMReclamationTests: XCTestCase {
    private let vmID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let plannedAt = Date(timeIntervalSince1970: 1_754_000_000)
    private let lifecyclePlanDigest = String(repeating: "a", count: 64)

    func testIntentAndMemorySamplesRoundTripAsCodableContracts() throws {
        let intent = try makeIntent()

        let data = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(VMReclamationIntent.self, from: data)

        XCTAssertEqual(decoded, intent)
        XCTAssertEqual(decoded.state, .planned)
        XCTAssertEqual(decoded.measuredReclaimedBytes, 0)
        XCTAssertEqual(decoded.configurationVersion, 1)
        XCTAssertEqual(decoded.stabilitySampleCount, 2)
    }

    func testHappyPathRequiresBothConfirmedMutationsAndStableMeasuredRecovery() throws {
        let machine = VMReclamationStateMachine(
            configuration: try! VMReclamationConfiguration(stabilitySampleCount: 2)
        )
        let intent = try makeIntent(requestedBytes: 1_000)

        let stopped = machine.transition(
            intent: intent,
            request: request(.stopConfirmed, at: 1)
        )
        XCTAssertEqual(stopped.state, .stopConfirmed)
        XCTAssertEqual(stopped.measuredReclaimedBytes, 0)

        let removed = machine.transition(
            intent: stopped.intent,
            request: request(.removeConfirmed, at: 2)
        )
        XCTAssertEqual(removed.state, .removeConfirmed)
        XCTAssertEqual(removed.measuredReclaimedBytes, 0)

        let verifying = machine.transition(
            intent: removed.intent,
            request: request(.beginVerification, at: 3)
        )
        XCTAssertEqual(verifying.state, .verifying)
        XCTAssertEqual(verifying.measuredReclaimedBytes, 0)

        let firstStableSample = machine.transition(
            intent: verifying.intent,
            request: request(
                .memorySample,
                at: 4,
                sample: memorySample(availableBytes: 7_000, offset: 4)
            )
        )
        XCTAssertEqual(firstStableSample.state, .held)
        XCTAssertEqual(firstStableSample.reasonCode, .stabilityWindowPending)
        XCTAssertEqual(firstStableSample.measuredReclaimedBytes, 0)

        let reclaimed = machine.transition(
            intent: firstStableSample.intent,
            request: request(
                .memorySample,
                at: 5,
                sample: memorySample(availableBytes: 7_100, offset: 5)
            )
        )
        XCTAssertEqual(reclaimed.state, .reclaimed)
        XCTAssertEqual(reclaimed.reasonCode, .reclaimed)
        XCTAssertEqual(reclaimed.measuredReclaimedBytes, 1_000)
        XCTAssertEqual(reclaimed.intent.measuredReclaimedBytes, 1_000)
    }

    func testReclaimedBytesAreCappedToOwnedRequestedAmount() throws {
        let configuration = try VMReclamationConfiguration(stabilitySampleCount: 1)
        let machine = VMReclamationStateMachine(configuration: configuration)
        let intent = try makeIntent(
            requestedBytes: 1_000,
            configuration: configuration
        )
        let verifying = verificationReadyIntent(machine: machine, intent: intent)

        let result = machine.transition(
            intent: verifying,
            request: request(
                .memorySample,
                at: 4,
                sample: memorySample(availableBytes: 8_000, offset: 4)
            )
        )

        XCTAssertEqual(result.state, .reclaimed)
        XCTAssertEqual(result.measuredReclaimedBytes, 1_000)
    }

    func testRecoveryBelowThresholdIsHeldWithoutReportingReclaimedBytes() throws {
        let configuration = try VMReclamationConfiguration(stabilitySampleCount: 1)
        let machine = VMReclamationStateMachine(configuration: configuration)
        let intent = try makeIntent(
            requestedBytes: 2_000,
            configuration: configuration
        )
        let verifying = verificationReadyIntent(machine: machine, intent: intent)

        let result = machine.transition(
            intent: verifying,
            request: request(
                .memorySample,
                at: 4,
                sample: memorySample(availableBytes: 6_000, offset: 4)
            )
        )

        XCTAssertEqual(result.state, .held)
        XCTAssertEqual(result.reasonCode, .recoveryBelowThreshold)
        XCTAssertEqual(result.measuredReclaimedBytes, 0)
    }

    func testTimeoutAndExpiryNeverProduceReclaimedCapacity() throws {
        let configuration = try VMReclamationConfiguration(stabilitySampleCount: 1)
        let machine = VMReclamationStateMachine(configuration: configuration)
        let intent = try makeIntent(configuration: configuration)
        let verifying = verificationReadyIntent(machine: machine, intent: intent)

        let timedOut = machine.transition(
            intent: verifying,
            request: request(.timeout, at: 6)
        )
        XCTAssertEqual(timedOut.state, .failed)
        XCTAssertEqual(timedOut.errorCode, .timedOut)
        XCTAssertEqual(timedOut.measuredReclaimedBytes, 0)
        XCTAssertEqual(
            timedOut.intent.lastObservedAt,
            plannedAt.addingTimeInterval(6)
        )

        let expired = machine.transition(
            intent: intent,
            request: request(.stopConfirmed, at: 101)
        )
        XCTAssertEqual(expired.state, .failed)
        XCTAssertEqual(expired.errorCode, .expired)
        XCTAssertEqual(expired.measuredReclaimedBytes, 0)
        XCTAssertEqual(
            expired.intent.lastObservedAt,
            plannedAt.addingTimeInterval(101)
        )
    }

    func testIdentityFenceDigestAndOwnershipMismatchesFailClosed() throws {
        let machine = VMReclamationStateMachine()
        let intent = try makeIntent()
        let mismatches: [(VMReclamationTransitionContext, VMReclamationErrorCode)] = [
            (
                VMReclamationTransitionContext(
                    vmID: vmID,
                    lifecyclePlanDigest: lifecyclePlanDigest,
                    fencingToken: 8
                ),
                .staleFence
            ),
            (
                VMReclamationTransitionContext(
                    vmID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                    lifecyclePlanDigest: lifecyclePlanDigest,
                    fencingToken: 7
                ),
                .vmIdentityMismatch
            ),
            (
                VMReclamationTransitionContext(
                    vmID: vmID,
                    lifecyclePlanDigest: String(repeating: "b", count: 64),
                    fencingToken: 7
                ),
                .lifecyclePlanDigestMismatch
            )
        ]

        for (context, errorCode) in mismatches {
            let result = machine.transition(
                intent: intent,
                request: request(.stopConfirmed, at: 1, context: context)
            )
            XCTAssertEqual(result.state, .planned)
            XCTAssertEqual(result.errorCode, errorCode)
            XCTAssertEqual(result.measuredReclaimedBytes, 0)
        }

        let unmanaged = try makeIntent(ownership: .unmanaged)
        let ownershipResult = machine.transition(
            intent: unmanaged,
            request: request(.stopConfirmed, at: 1)
        )
        XCTAssertEqual(ownershipResult.state, .planned)
        XCTAssertEqual(ownershipResult.errorCode, .unmanagedOwnership)
        XCTAssertEqual(ownershipResult.measuredReclaimedBytes, 0)
    }

    func testDuplicateAndOutOfOrderTransitionsFailClosed() throws {
        let machine = VMReclamationStateMachine()
        let intent = try makeIntent()

        let duplicate = machine.transition(
            intent: machine.transition(
                intent: intent,
                request: request(.stopConfirmed, at: 1)
            ).intent,
            request: request(.stopConfirmed, at: 2)
        )
        XCTAssertEqual(duplicate.state, .stopConfirmed)
        XCTAssertEqual(duplicate.errorCode, .duplicateTransition)

        let outOfOrder = machine.transition(
            intent: intent,
            request: request(.removeConfirmed, at: 1)
        )
        XCTAssertEqual(outOfOrder.state, .planned)
        XCTAssertEqual(outOfOrder.errorCode, .outOfOrderTransition)
    }

    func testInvalidDecreasingAndOutOfOrderMemorySamplesFailClosed() throws {
        let machine = VMReclamationStateMachine(
            configuration: try! VMReclamationConfiguration(stabilitySampleCount: 2)
        )
        let verifying = verificationReadyIntent(machine: machine, intent: try makeIntent())

        let invalid = machine.transition(
            intent: verifying,
            request: request(
                .memorySample,
                at: 4,
                sample: VMReclamationMemorySample(
                    availableBytes: 9_000,
                    totalBytes: 8_000,
                    observedAt: plannedAt.addingTimeInterval(4)
                )
            )
        )
        XCTAssertEqual(invalid.state, .verifying)
        XCTAssertEqual(invalid.errorCode, .invalidSample)
        XCTAssertEqual(invalid.measuredReclaimedBytes, 0)

        let first = machine.transition(
            intent: verifying,
            request: request(
                .memorySample,
                at: 4,
                sample: memorySample(availableBytes: 6_500, offset: 4)
            )
        )
        let decreasing = machine.transition(
            intent: first.intent,
            request: request(
                .memorySample,
                at: 5,
                sample: memorySample(availableBytes: 6_400, offset: 5)
            )
        )
        XCTAssertEqual(decreasing.state, .held)
        XCTAssertEqual(decreasing.errorCode, .decreasingSample)
        XCTAssertEqual(decreasing.measuredReclaimedBytes, 0)

        let outOfOrder = machine.transition(
            intent: verifying,
            request: request(
                .memorySample,
                at: 3,
                sample: memorySample(availableBytes: 6_500, offset: 3)
            )
        )
        XCTAssertEqual(outOfOrder.state, .verifying)
        XCTAssertEqual(outOfOrder.errorCode, .outOfOrderObservation)
    }

    func testEveryTransitionRejectsCallerTimeRegressionAndPrePlanObservation() throws {
        let machine = VMReclamationStateMachine()
        let intent = try makeIntent()

        let beforePlan = machine.transition(
            intent: intent,
            request: request(.stopConfirmed, at: -1)
        )
        XCTAssertEqual(beforePlan.state, .planned)
        XCTAssertEqual(beforePlan.errorCode, .outOfOrderObservation)

        let stopped = machine.transition(
            intent: intent,
            request: request(.stopConfirmed, at: 1)
        )
        let regressed = machine.transition(
            intent: stopped.intent,
            request: request(.removeConfirmed, at: 0)
        )
        XCTAssertEqual(regressed.state, .stopConfirmed)
        XCTAssertEqual(regressed.errorCode, .outOfOrderObservation)
        XCTAssertEqual(regressed.measuredReclaimedBytes, 0)
    }

    func testNonMemoryTransitionsRejectUnexpectedMemoryPayloads() throws {
        let machine = VMReclamationStateMachine()
        let intent = try makeIntent()
        let result = machine.transition(
            intent: intent,
            request: request(
                .stopConfirmed,
                at: 1,
                sample: memorySample(availableBytes: 6_500, offset: 1)
            )
        )

        XCTAssertEqual(result.state, .planned)
        XCTAssertEqual(result.errorCode, .invalidTransition)
        XCTAssertEqual(result.measuredReclaimedBytes, 0)
    }

    func testIntentRequiresBoundedDigestAndNonzeroFence() {
        XCTAssertThrowsError(
            try makeIntent(fencingToken: 0)
        )
        XCTAssertThrowsError(
            try makeIntent(lifecyclePlanDigest: String(repeating: "d", count: 257))
        )
        XCTAssertThrowsError(
            try makeIntent(lifecyclePlanDigest: " plan-digest")
        )
        XCTAssertThrowsError(
            try makeIntent(lifecyclePlanDigest: String(repeating: "A", count: 64))
        )
    }

    func testReclamationConfigurationCarriesReplayVersion() {
        let machine = VMReclamationStateMachine(
            configuration: try! VMReclamationConfiguration(
                stabilitySampleCount: 2,
                version: 1
            )
        )

        XCTAssertEqual(machine.configuration.version, 1)
    }

    func testPersistedIntentDecoderRejectsForgedReclaimedBytes() throws {
        let intent = try makeIntent()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(intent)
            ) as? [String: Any]
        )
        object["state"] = "reclaimed"
        object["measuredReclaimedBytes"] = 9_999
        let hostileData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                VMReclamationIntent.self,
                from: hostileData
            )
        )
    }

    func testChangedReclamationConfigurationFailsClosedBeforeTransition() throws {
        let intent = try makeIntent(
            configuration: try VMReclamationConfiguration(stabilitySampleCount: 2)
        )
        let changedConfiguration = try VMReclamationConfiguration(
            stabilitySampleCount: 1
        )
        let result = VMReclamationStateMachine(
            configuration: changedConfiguration
        ).transition(
            intent: intent,
            request: request(.stopConfirmed, at: 1)
        )

        XCTAssertEqual(result.state, .planned)
        XCTAssertEqual(result.errorCode, .configurationMismatch)
        XCTAssertEqual(result.measuredReclaimedBytes, 0)
    }

    func testRejectedStaleRequestDoesNotPreventValidReplay() throws {
        let machine = VMReclamationStateMachine()
        let intent = try makeIntent()
        let stale = machine.transition(
            intent: intent,
            request: request(
                .stopConfirmed,
                at: 1,
                context: VMReclamationTransitionContext(
                    vmID: vmID,
                    lifecyclePlanDigest: lifecyclePlanDigest,
                    fencingToken: 6
                )
            )
        )

        XCTAssertEqual(stale.intent, intent)
        XCTAssertEqual(stale.state, .planned)
        XCTAssertEqual(stale.errorCode, .staleFence)

        let valid = machine.transition(
            intent: stale.intent,
            request: request(.stopConfirmed, at: 1)
        )
        XCTAssertEqual(valid.state, .stopConfirmed)
        XCTAssertNil(valid.errorCode)
    }

    func testInvalidReclamationConfigurationIsRejected() {
        XCTAssertThrowsError(
            try VMReclamationConfiguration(version: 99)
        )
        XCTAssertThrowsError(
            try VMReclamationConfiguration(stabilitySampleCount: 0)
        )
    }

    private func makeIntent(
        requestedBytes: UInt64 = 1_000,
        ownership: VMReclamationOwnership = .hostwrightOwned,
        lifecyclePlanDigest: String? = nil,
        fencingToken: UInt64 = 7,
        configuration: VMReclamationConfiguration = .standard
    ) throws -> VMReclamationIntent {
        try VMReclamationIntent(
            vmID: vmID,
            lifecyclePlanDigest: lifecyclePlanDigest ?? self.lifecyclePlanDigest,
            fencingToken: fencingToken,
            requestedBytes: requestedBytes,
            beforeSample: memorySample(availableBytes: 6_000, offset: 0),
            ownership: ownership,
            plannedAt: plannedAt,
            expiresAt: plannedAt.addingTimeInterval(100),
            configuration: configuration
        )
    }

    private func verificationReadyIntent(
        machine: VMReclamationStateMachine,
        intent: VMReclamationIntent
    ) -> VMReclamationIntent {
        let stopped = machine.transition(
            intent: intent,
            request: request(.stopConfirmed, at: 1)
        )
        let removed = machine.transition(
            intent: stopped.intent,
            request: request(.removeConfirmed, at: 2)
        )
        return machine.transition(
            intent: removed.intent,
            request: request(.beginVerification, at: 3)
        ).intent
    }

    private func request(
        _ transition: VMReclamationTransition,
        at offset: TimeInterval,
        context: VMReclamationTransitionContext? = nil,
        sample: VMReclamationMemorySample? = nil
    ) -> VMReclamationTransitionRequest {
        VMReclamationTransitionRequest(
            transition: transition,
            context: context ?? VMReclamationTransitionContext(
                vmID: vmID,
                lifecyclePlanDigest: lifecyclePlanDigest,
                fencingToken: 7
            ),
            observedAt: plannedAt.addingTimeInterval(offset),
            memorySample: sample
        )
    }

    private func memorySample(
        availableBytes: UInt64,
        offset: TimeInterval
    ) -> VMReclamationMemorySample {
        VMReclamationMemorySample(
            availableBytes: availableBytes,
            totalBytes: 10_000,
            observedAt: plannedAt.addingTimeInterval(offset)
        )
    }
}
