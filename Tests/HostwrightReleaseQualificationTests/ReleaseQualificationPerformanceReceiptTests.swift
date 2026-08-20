import Foundation
import XCTest
@testable import HostwrightReleaseQualification

final class ReleaseQualificationPerformanceReceiptTests: XCTestCase {
    func testStableMicrobenchmarkReceiptIsCanonicalAndAdvisoryOnly() throws {
        let receipt = try makeReceipt()

        XCTAssertEqual(receipt.evidenceScope, .sourceOnlyAdvisory)
        XCTAssertEqual(receipt.promotionStatus, .nonPromotable)
        XCTAssertFalse(receipt.satisfiesRequiredGate)
        XCTAssertFalse(receipt.isPromotable)
        XCTAssertFalse(receipt.isHardwareOrReleaseEvidence)
        XCTAssertEqual(
            receipt.unmeasuredDimensions,
            ReleaseQualificationPerformanceReceiptUnmeasuredDimension.canonicalSet
        )

        let encoded = try ReleaseQualificationJSON.encode(receipt)
        let decoded = try ReleaseQualificationJSON.decode(
            ReleaseQualificationPerformanceReceipt.self,
            from: encoded
        )
        XCTAssertEqual(decoded, receipt)
        XCTAssertEqual(try ReleaseQualificationJSON.encode(decoded), encoded)
    }

    func testReceiptRejectsUnknownMissingAndDuplicateKeys() throws {
        let encoded = try ReleaseQualificationJSON.encode(makeReceipt())
        let validObject = try object(from: encoded)

        var unknown = validObject
        unknown["futureField"] = true
        XCTAssertThrowsError(try decode(object: unknown))

        var missing = validObject
        missing.removeValue(forKey: "recordedAt")
        XCTAssertThrowsError(try decode(object: missing))

        var nestedUnknown = validObject
        var decision = try XCTUnwrap(nestedUnknown["decision"] as? [String: Any])
        decision["futureField"] = true
        nestedUnknown["decision"] = decision
        XCTAssertThrowsError(try decode(object: nestedUnknown))

        var nestedMissing = validObject
        var incompleteDecision = try XCTUnwrap(
            nestedMissing["decision"] as? [String: Any]
        )
        incompleteDecision.removeValue(forKey: "measurementUnit")
        nestedMissing["decision"] = incompleteDecision
        XCTAssertThrowsError(try decode(object: nestedMissing))

        var duplicate = encoded
        duplicate.insert(
            contentsOf: Data("\"schemaVersion\":1,".utf8),
            at: duplicate.index(after: duplicate.startIndex)
        )
        XCTAssertThrowsError(
            try ReleaseQualificationJSON.decode(
                ReleaseQualificationPerformanceReceipt.self,
                from: duplicate
            )
        )
    }

    func testReceiptRejectsMissingDuplicateAndUnknownDimensions() throws {
        let encoded = try ReleaseQualificationJSON.encode(makeReceipt())
        let validObject = try object(from: encoded)
        let dimensions = try XCTUnwrap(
            validObject["unmeasuredDimensions"] as? [String]
        )

        var missing = validObject
        missing["unmeasuredDimensions"] = Array(dimensions.dropLast())
        XCTAssertThrowsError(try decode(object: missing))

        var duplicate = validObject
        duplicate["unmeasuredDimensions"] = dimensions + [dimensions[0]]
        XCTAssertThrowsError(try decode(object: duplicate))

        var unknown = validObject
        unknown["unmeasuredDimensions"] = Array(dimensions.dropLast()) + ["long-run"]
        XCTAssertThrowsError(try decode(object: unknown))
    }

    func testReceiptRejectsReleaseCommitAndMetricMismatches() throws {
        let encoded = try ReleaseQualificationJSON.encode(makeReceipt())
        let validObject = try object(from: encoded)

        var futureSchema = validObject
        futureSchema["schemaVersion"] = 2
        XCTAssertThrowsError(try decode(object: futureSchema)) { error in
            XCTAssertEqual(
                error as? ReleaseQualificationContractError,
                .unsupportedSchemaVersion(2)
            )
        }

        let mismatches: [(String, Any)] = [
            ("releaseTarget", "v0.0.3"),
            ("baselineCommit", "2222222222222222222222222222222222222222"),
            ("candidateCommit", "4444444444444444444444444444444444444444"),
            ("metricID", "different-metric")
        ]

        for (key, value) in mismatches {
            var object = validObject
            object[key] = value
            XCTAssertThrowsError(
                try decode(object: object),
                "accepted mismatch: \(key)"
            )
        }
    }

    func testSourceOnlyReceiptCannotClaimPromotionOrGateSatisfaction() throws {
        let encoded = try ReleaseQualificationJSON.encode(makeReceipt())
        let validObject = try object(from: encoded)

        var gate = validObject
        gate["satisfiesRequiredGate"] = true
        XCTAssertThrowsError(try decode(object: gate))

        var promotion = validObject
        promotion["promotionStatus"] = "promotable"
        XCTAssertThrowsError(try decode(object: promotion))

        var scope = validObject
        scope["evidenceScope"] = "live-hardware"
        XCTAssertThrowsError(try decode(object: scope))
    }

    func testLiveHardwareDecisionStillCannotPromoteWithoutExternalEvidence() throws {
        let receipt = try makeReceipt(kind: .liveHardware)
        XCTAssertEqual(receipt.decision.benchmarkKind, .liveHardware)
        XCTAssertEqual(receipt.promotionStatus, .nonPromotable)
        XCTAssertFalse(receipt.satisfiesRequiredGate)
        XCTAssertTrue(
            receipt.unmeasuredDimensions.contains(.hardwareQualification)
        )

        let encoded = try ReleaseQualificationJSON.encode(receipt)
        XCTAssertEqual(
            try ReleaseQualificationJSON.decode(
                ReleaseQualificationPerformanceReceipt.self,
                from: encoded
            ),
            receipt
        )

        var promoted = try object(from: encoded)
        promoted["satisfiesRequiredGate"] = true
        promoted["promotionStatus"] = "promotable"
        XCTAssertThrowsError(try decode(object: promoted))
    }

    private func makeReceipt(
        kind: ReleaseQualificationPerformanceBenchmarkKind = .stableMicrobenchmark
    ) throws -> ReleaseQualificationPerformanceReceipt {
        try ReleaseQualificationPerformanceReceipt(
            releaseTarget: ReleaseQualificationSupportedMatrix.committed.releaseTarget,
            recordedAt: ReleaseQualificationTestSupport.timestamp,
            decision: decision(kind: kind)
        )
    }

    private func decision(
        kind: ReleaseQualificationPerformanceBenchmarkKind
    ) throws -> ReleaseQualificationPerformanceDecision {
        let context = ReleaseQualificationHash.sha256(
            data: Data("receipt-measurement-context".utf8)
        )
        return try ReleaseQualificationPerformanceEvaluator().evaluate(
            request: ReleaseQualificationPerformanceRequest(
                baselineCommit: baselineCommit,
                candidateCommit: ReleaseQualificationTestSupport.commit,
                metricID: "daemon-startup-duration",
                benchmarkKind: kind,
                direction: .lowerIsBetter,
                baseline: ReleaseQualificationPerformanceSampleSeries(
                    measurementUnit: "milliseconds",
                    measurementContextSHA256: context,
                    discardedWarmupSamples: 1,
                    rawSamples: [100, 99, 101, 100, 100]
                ),
                candidate: ReleaseQualificationPerformanceSampleSeries(
                    measurementUnit: "milliseconds",
                    measurementContextSHA256: context,
                    discardedWarmupSamples: 1,
                    rawSamples: [103, 102, 104, 103, 103]
                )
            )
        )
    }

    private func object(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(object: [String: Any]) throws
        -> ReleaseQualificationPerformanceReceipt
    {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return try ReleaseQualificationJSON.decode(
            ReleaseQualificationPerformanceReceipt.self,
            from: data
        )
    }

    private var baselineCommit: ReleaseQualificationCommit {
        try! ReleaseQualificationCommit("3333333333333333333333333333333333333333")
    }
}
