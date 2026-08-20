import Foundation
import XCTest
@testable import HostwrightReleaseQualification

final class ReleaseQualificationPerformanceTests: XCTestCase {
    func testMicrobenchmarkThresholdIsStrictlyGreaterThanFivePercent() throws {
        let boundary = try evaluate(
            kind: .stableMicrobenchmark,
            baseline: repeated(100),
            candidate: repeated(105)
        )
        XCTAssertEqual(boundary.regressionBasisPoints, 500)
        XCTAssertEqual(boundary.outcome, .withinBudget)

        let regression = try evaluate(
            kind: .stableMicrobenchmark,
            baseline: repeated(100),
            candidate: repeated(106)
        )
        XCTAssertEqual(regression.regressionBasisPoints, 600)
        XCTAssertEqual(regression.outcome, .regression)
    }

    func testLiveHardwareThresholdIsStrictlyGreaterThanTenPercent() throws {
        let boundary = try evaluate(
            kind: .liveHardware,
            baseline: repeated(100),
            candidate: repeated(110)
        )
        XCTAssertEqual(boundary.regressionBasisPoints, 1_000)
        XCTAssertEqual(boundary.outcome, .withinBudget)

        let regression = try evaluate(
            kind: .liveHardware,
            baseline: repeated(100),
            candidate: repeated(111)
        )
        XCTAssertEqual(regression.regressionBasisPoints, 1_100)
        XCTAssertEqual(regression.outcome, .regression)
    }

    func testHigherIsBetterAndEvenSampleMediansAreExact() throws {
        let result = try evaluate(
            direction: .higherIsBetter,
            baseline: [99, 100, 100, 101, 101, 102],
            candidate: [93, 94, 94, 95, 95, 96]
        )
        XCTAssertEqual(result.baselineMedianTwice, 201)
        XCTAssertEqual(result.candidateMedianTwice, 189)
        XCTAssertEqual(result.regressionBasisPoints, 598)
        XCTAssertEqual(result.outcome, .regression)
    }

    func testNonDivisibleRegressionsReportCeilingBasisPoints() throws {
        let baseline = [1_008, 1_009, 1_009, 1_010, 1_010, 1_011].map(Int64.init)
        let microCandidate = [1_058, 1_059, 1_060, 1_060, 1_061, 1_062].map(Int64.init)
        let micro = try evaluate(
            kind: .stableMicrobenchmark,
            baseline: baseline,
            candidate: microCandidate
        )
        XCTAssertEqual(micro.baselineMedianTwice, 2_019)
        XCTAssertEqual(micro.candidateMedianTwice, 2_120)
        XCTAssertEqual(micro.regressionBasisPoints, 501)
        XCTAssertEqual(micro.outcome, .regression)

        let liveCandidate = [1_108, 1_109, 1_110, 1_111, 1_112, 1_113].map(Int64.init)
        let live = try evaluate(
            kind: .liveHardware,
            baseline: baseline,
            candidate: liveCandidate
        )
        XCTAssertEqual(live.candidateMedianTwice, 2_221)
        XCTAssertEqual(live.regressionBasisPoints, 1_001)
        XCTAssertEqual(live.outcome, .regression)
    }

    func testReviewedTradeoffMustBindMeasuredBenefitCommitAndUpdatedBudget() throws {
        let tradeoff = ReleaseQualificationPerformanceTradeoff(
            reviewCommit: ReleaseQualificationTestSupport.commit,
            approvedAt: ReleaseQualificationTestSupport.timestamp,
            reviewer: "release-reviewer",
            rationale: "Startup work enables the reviewed recovery guarantee.",
            measuredUserBenefit: "Recovery completes within the declared objective.",
            updatedRegressionBudgetBasisPoints: 750
        )
        let accepted = try evaluate(
            baseline: repeated(100),
            candidate: repeated(106),
            tradeoff: tradeoff
        )
        XCTAssertEqual(accepted.outcome, .reviewedTradeoff)
        XCTAssertFalse(accepted.isHardwareOrReleaseEvidence)

        let encoded = try ReleaseQualificationJSON.encode(accepted)
        var tampered = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        tampered["candidateCommit"] = "2222222222222222222222222222222222222222"
        let tamperedData = try JSONSerialization.data(
            withJSONObject: tampered,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(
            try ReleaseQualificationJSON.decode(
                ReleaseQualificationPerformanceDecision.self,
                from: tamperedData
            )
        )

        let insufficient = ReleaseQualificationPerformanceTradeoff(
            reviewCommit: ReleaseQualificationTestSupport.commit,
            approvedAt: ReleaseQualificationTestSupport.timestamp,
            reviewer: "release-reviewer",
            rationale: "Startup work enables the reviewed recovery guarantee.",
            measuredUserBenefit: "Recovery completes within the declared objective.",
            updatedRegressionBudgetBasisPoints: 550
        )
        XCTAssertThrowsError(
            try evaluate(
                baseline: repeated(100),
                candidate: repeated(106),
                tradeoff: insufficient
            )
        )
    }

    func testSeriesAndTradeoffValidationFailClosed() throws {
        XCTAssertThrowsError(
            try evaluate(baseline: [100, 100, 100, 100], candidate: repeated(100))
        )
        XCTAssertThrowsError(
            try evaluate(baseline: repeated(0), candidate: repeated(100))
        )
        XCTAssertThrowsError(
            try ReleaseQualificationPerformanceEvaluator().evaluate(
                request: request(
                    baseline: series(repeated(100), unit: "milliseconds"),
                    candidate: series(repeated(100), unit: "bytes")
                )
            )
        )
        let differentContext = ReleaseQualificationPerformanceSampleSeries(
            measurementUnit: "milliseconds",
            measurementContextSHA256: ReleaseQualificationHash.sha256(
                data: Data("different-context".utf8)
            ),
            discardedWarmupSamples: 1,
            rawSamples: repeated(100)
        )
        XCTAssertThrowsError(
            try ReleaseQualificationPerformanceEvaluator().evaluate(
                request: request(
                    baseline: series(repeated(100)),
                    candidate: differentContext
                )
            )
        )
        XCTAssertThrowsError(
            try evaluate(
                baseline: repeated(100),
                candidate: repeated(100),
                tradeoff: ReleaseQualificationPerformanceTradeoff(
                    reviewCommit: ReleaseQualificationTestSupport.commit,
                    approvedAt: ReleaseQualificationTestSupport.timestamp,
                    reviewer: "release-reviewer",
                    rationale: "Unnecessary exception.",
                    measuredUserBenefit: "No regression exists.",
                    updatedRegressionBudgetBasisPoints: 750
                )
            )
        )
    }

    func testCanonicalWireRoundTripAndUnknownFutureFieldsFailClosed() throws {
        let value = request(
            baseline: series([100, 101, 99, 100, 100]),
            candidate: series([103, 104, 102, 103, 103])
        )
        let encoded = try ReleaseQualificationJSON.encode(value)
        XCTAssertEqual(
            try ReleaseQualificationJSON.decode(
                ReleaseQualificationPerformanceRequest.self,
                from: encoded
            ),
            value
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["futureField"] = true
        let unknown = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(
            try ReleaseQualificationJSON.decode(
                ReleaseQualificationPerformanceRequest.self,
                from: unknown
            )
        )

        object.removeValue(forKey: "futureField")
        object["schemaVersion"] = 2
        let future = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(
            try ReleaseQualificationJSON.decode(
                ReleaseQualificationPerformanceRequest.self,
                from: future
            )
        ) { error in
            XCTAssertEqual(
                error as? ReleaseQualificationContractError,
                .unsupportedSchemaVersion(2)
            )
        }
    }

    func testSampleOrderingDoesNotChangeTheDecision() throws {
        let first = try evaluate(
            baseline: [100, 99, 101, 100, 100],
            candidate: [106, 105, 107, 106, 106]
        )
        let second = try evaluate(
            baseline: [100, 100, 101, 99, 100],
            candidate: [106, 107, 106, 105, 106]
        )
        XCTAssertEqual(first, second)
    }

    private func evaluate(
        kind: ReleaseQualificationPerformanceBenchmarkKind = .stableMicrobenchmark,
        direction: ReleaseQualificationPerformanceDirection = .lowerIsBetter,
        baseline: [Int64],
        candidate: [Int64],
        tradeoff: ReleaseQualificationPerformanceTradeoff? = nil
    ) throws -> ReleaseQualificationPerformanceDecision {
        try ReleaseQualificationPerformanceEvaluator().evaluate(
            request: request(
                kind: kind,
                direction: direction,
                baseline: series(baseline),
                candidate: series(candidate),
                tradeoff: tradeoff
            )
        )
    }

    private func request(
        kind: ReleaseQualificationPerformanceBenchmarkKind = .stableMicrobenchmark,
        direction: ReleaseQualificationPerformanceDirection = .lowerIsBetter,
        baseline: ReleaseQualificationPerformanceSampleSeries,
        candidate: ReleaseQualificationPerformanceSampleSeries,
        tradeoff: ReleaseQualificationPerformanceTradeoff? = nil
    ) -> ReleaseQualificationPerformanceRequest {
        ReleaseQualificationPerformanceRequest(
            baselineCommit: baselineCommit,
            candidateCommit: ReleaseQualificationTestSupport.commit,
            metricID: "daemon-startup-duration",
            benchmarkKind: kind,
            direction: direction,
            baseline: baseline,
            candidate: candidate,
            tradeoff: tradeoff
        )
    }

    private func series(
        _ samples: [Int64],
        unit: String = "milliseconds"
    ) -> ReleaseQualificationPerformanceSampleSeries {
        ReleaseQualificationPerformanceSampleSeries(
            measurementUnit: unit,
            measurementContextSHA256: measurementContext,
            discardedWarmupSamples: 1,
            rawSamples: samples
        )
    }

    private func repeated(_ value: Int64) -> [Int64] {
        Array(repeating: value, count: 5)
    }

    private var baselineCommit: ReleaseQualificationCommit {
        try! ReleaseQualificationCommit("3333333333333333333333333333333333333333")
    }

    private var measurementContext: ReleaseQualificationSHA256 {
        ReleaseQualificationHash.sha256(data: Data("fixed-measurement-context".utf8))
    }
}
