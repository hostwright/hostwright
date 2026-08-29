import Foundation

public enum ReleaseQualificationPerformanceBenchmarkKind: String, Codable, Sendable {
    case stableMicrobenchmark = "stable-microbenchmark"
    case liveHardware = "live-hardware"

    public var defaultRegressionBudgetBasisPoints: Int {
        switch self {
        case .stableMicrobenchmark: 500
        case .liveHardware: 1_000
        }
    }
}

public enum ReleaseQualificationPerformanceDirection: String, Codable, Sendable {
    case lowerIsBetter = "lower-is-better"
    case higherIsBetter = "higher-is-better"
}

public enum ReleaseQualificationPerformanceOutcome: String, Codable, Sendable {
    case withinBudget = "within-budget"
    case regression
    case reviewedTradeoff = "reviewed-tradeoff"
}

public struct ReleaseQualificationPerformanceSampleSeries:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let measurementUnit: String
    public let measurementContextSHA256: ReleaseQualificationSHA256
    public let discardedWarmupSamples: Int
    public let rawSamples: [Int64]

    public init(
        measurementUnit: String,
        measurementContextSHA256: ReleaseQualificationSHA256,
        discardedWarmupSamples: Int,
        rawSamples: [Int64]
    ) {
        self.measurementUnit = measurementUnit
        self.measurementContextSHA256 = measurementContextSHA256
        self.discardedWarmupSamples = discardedWarmupSamples
        self.rawSamples = rawSamples
    }

    public func validate() throws {
        guard Self.isIdentifier(measurementUnit) else {
            throw ReleaseQualificationContractError.invalid(
                field: "performanceSamples.measurementUnit",
                reason: "expected a bounded lowercase identifier"
            )
        }
        try measurementContextSHA256.validate()
        guard (0...10_000).contains(discardedWarmupSamples),
              (5...10_000).contains(rawSamples.count),
              rawSamples.allSatisfy({ (1...1_000_000_000_000).contains($0) }) else {
            throw ReleaseQualificationContractError.invalid(
                field: "performanceSamples",
                reason: "sample count, warmup count, or positive integer sample is out of bounds"
            )
        }
    }

    fileprivate var medianTwice: Int64 {
        let ordered = rawSamples.sorted()
        let midpoint = ordered.count / 2
        if ordered.count.isMultiple(of: 2) {
            return ordered[midpoint - 1] + ordered[midpoint]
        }
        return ordered[midpoint] * 2
    }

    fileprivate static func isIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 64 &&
            value.range(
                of: "^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$",
                options: .regularExpression
            ) != nil
    }
}

public struct ReleaseQualificationPerformanceTradeoff:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let reviewCommit: ReleaseQualificationCommit
    public let approvedAt: ReleaseQualificationTimestamp
    public let reviewer: String
    public let rationale: String
    public let measuredUserBenefit: String
    public let updatedRegressionBudgetBasisPoints: Int

    public init(
        reviewCommit: ReleaseQualificationCommit,
        approvedAt: ReleaseQualificationTimestamp,
        reviewer: String,
        rationale: String,
        measuredUserBenefit: String,
        updatedRegressionBudgetBasisPoints: Int
    ) {
        self.reviewCommit = reviewCommit
        self.approvedAt = approvedAt
        self.reviewer = reviewer
        self.rationale = rationale
        self.measuredUserBenefit = measuredUserBenefit
        self.updatedRegressionBudgetBasisPoints = updatedRegressionBudgetBasisPoints
    }

    public func validate() throws {
        try reviewCommit.validate()
        try approvedAt.validate()
        guard Self.isBoundedText(reviewer, maximumBytes: 128),
              Self.isBoundedText(rationale, maximumBytes: 2_048),
              Self.isBoundedText(measuredUserBenefit, maximumBytes: 2_048),
              (1...5_000).contains(updatedRegressionBudgetBasisPoints) else {
            throw ReleaseQualificationContractError.invalid(
                field: "performanceTradeoff",
                reason: "review identity, benefit, rationale, or updated budget is invalid"
            )
        }
    }

    private static func isBoundedText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximumBytes &&
            value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

public struct ReleaseQualificationPerformanceRequest:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let schemaVersion: Int
    public let baselineCommit: ReleaseQualificationCommit
    public let candidateCommit: ReleaseQualificationCommit
    public let metricID: String
    public let benchmarkKind: ReleaseQualificationPerformanceBenchmarkKind
    public let direction: ReleaseQualificationPerformanceDirection
    public let baseline: ReleaseQualificationPerformanceSampleSeries
    public let candidate: ReleaseQualificationPerformanceSampleSeries
    public let tradeoff: ReleaseQualificationPerformanceTradeoff?

    public init(
        schemaVersion: Int = ReleaseQualificationLimits.schemaVersion,
        baselineCommit: ReleaseQualificationCommit,
        candidateCommit: ReleaseQualificationCommit,
        metricID: String,
        benchmarkKind: ReleaseQualificationPerformanceBenchmarkKind,
        direction: ReleaseQualificationPerformanceDirection,
        baseline: ReleaseQualificationPerformanceSampleSeries,
        candidate: ReleaseQualificationPerformanceSampleSeries,
        tradeoff: ReleaseQualificationPerformanceTradeoff? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.baselineCommit = baselineCommit
        self.candidateCommit = candidateCommit
        self.metricID = metricID
        self.benchmarkKind = benchmarkKind
        self.direction = direction
        self.baseline = baseline
        self.candidate = candidate
        self.tradeoff = tradeoff
    }

    public func validate() throws {
        guard schemaVersion == ReleaseQualificationLimits.schemaVersion else {
            throw ReleaseQualificationContractError.unsupportedSchemaVersion(schemaVersion)
        }
        try baselineCommit.validate()
        try candidateCommit.validate()
        guard baselineCommit != candidateCommit else {
            throw ReleaseQualificationContractError.invalid(
                field: "performance.sourceCommits",
                reason: "baseline and candidate commits must be distinct"
            )
        }
        guard ReleaseQualificationPerformanceSampleSeries.isIdentifier(metricID) else {
            throw ReleaseQualificationContractError.invalid(
                field: "performance.metricID",
                reason: "expected a bounded lowercase identifier"
            )
        }
        try baseline.validate()
        try candidate.validate()
        guard baseline.measurementUnit == candidate.measurementUnit,
              baseline.measurementContextSHA256 == candidate.measurementContextSHA256,
              baseline.discardedWarmupSamples == candidate.discardedWarmupSamples,
              baseline.rawSamples.count == candidate.rawSamples.count else {
            throw ReleaseQualificationContractError.invalid(
                field: "performance.samples",
                reason: "baseline and candidate sampling controls must match exactly"
            )
        }
        if let tradeoff {
            try tradeoff.validate()
            guard tradeoff.reviewCommit == candidateCommit else {
                throw ReleaseQualificationContractError.invalid(
                    field: "performance.tradeoff.reviewCommit",
                    reason: "reviewed tradeoff must bind the exact candidate source commit"
                )
            }
        }
    }
}

public struct ReleaseQualificationPerformanceDecision:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let schemaVersion: Int
    public let baselineCommit: ReleaseQualificationCommit
    public let candidateCommit: ReleaseQualificationCommit
    public let metricID: String
    public let benchmarkKind: ReleaseQualificationPerformanceBenchmarkKind
    public let direction: ReleaseQualificationPerformanceDirection
    public let measurementUnit: String
    public let measurementContextSHA256: ReleaseQualificationSHA256
    public let discardedWarmupSamples: Int
    public let sampleCount: Int
    public let baselineMedianTwice: Int64
    public let candidateMedianTwice: Int64
    public let regressionBasisPoints: Int
    public let defaultRegressionBudgetBasisPoints: Int
    public let effectiveRegressionBudgetBasisPoints: Int
    public let outcome: ReleaseQualificationPerformanceOutcome
    public let tradeoff: ReleaseQualificationPerformanceTradeoff?

    public var isHardwareOrReleaseEvidence: Bool { false }

    public func validate() throws {
        guard schemaVersion == ReleaseQualificationLimits.schemaVersion else {
            throw ReleaseQualificationContractError.unsupportedSchemaVersion(schemaVersion)
        }
        try baselineCommit.validate()
        try candidateCommit.validate()
        try measurementContextSHA256.validate()
        guard baselineCommit != candidateCommit else {
            throw ReleaseQualificationContractError.invalid(
                field: "performanceDecision.sourceCommits",
                reason: "baseline and candidate commits must be distinct"
            )
        }
        guard ReleaseQualificationPerformanceSampleSeries.isIdentifier(metricID),
              ReleaseQualificationPerformanceSampleSeries.isIdentifier(measurementUnit),
              (0...10_000).contains(discardedWarmupSamples),
              (5...10_000).contains(sampleCount),
              (1...2_000_000_000_000).contains(baselineMedianTwice),
              (1...2_000_000_000_000).contains(candidateMedianTwice),
              regressionBasisPoints >= 0,
              defaultRegressionBudgetBasisPoints ==
                  benchmarkKind.defaultRegressionBudgetBasisPoints,
              effectiveRegressionBudgetBasisPoints >= defaultRegressionBudgetBasisPoints,
              effectiveRegressionBudgetBasisPoints <= 5_000 else {
            throw ReleaseQualificationContractError.invalid(
                field: "performanceDecision",
                reason: "decision fields are outside the supported performance contract"
            )
        }
        let regression: Int64
        switch direction {
        case .lowerIsBetter:
            regression = max(0, candidateMedianTwice - baselineMedianTwice)
        case .higherIsBetter:
            regression = max(0, baselineMedianTwice - candidateMedianTwice)
        }
        let scaledRegression = regression * 10_000
        guard regressionBasisPoints == Self.ceilingBasisPoints(
            scaledRegression: scaledRegression,
            baselineMedianTwice: baselineMedianTwice
        ) else {
            throw ReleaseQualificationContractError.invalid(
                field: "performanceDecision.regressionBasisPoints",
                reason: "reported regression does not match the recorded medians"
            )
        }
        let exceedsDefault = scaledRegression >
            Int64(defaultRegressionBudgetBasisPoints) * baselineMedianTwice
        switch outcome {
        case .withinBudget:
            guard tradeoff == nil,
                  effectiveRegressionBudgetBasisPoints ==
                    defaultRegressionBudgetBasisPoints,
                  !exceedsDefault else {
                throw ReleaseQualificationContractError.invalid(
                    field: "performanceDecision.tradeoff",
                    reason: "within-budget decision does not match the recorded regression"
                )
            }
        case .regression:
            guard tradeoff == nil,
                  effectiveRegressionBudgetBasisPoints ==
                    defaultRegressionBudgetBasisPoints,
                  exceedsDefault else {
                throw ReleaseQualificationContractError.invalid(
                    field: "performanceDecision.tradeoff",
                    reason: "regression decision does not match the recorded regression"
                )
            }
        case .reviewedTradeoff:
            guard let tradeoff,
                  tradeoff.reviewCommit == candidateCommit,
                  effectiveRegressionBudgetBasisPoints ==
                    tradeoff.updatedRegressionBudgetBasisPoints,
                  effectiveRegressionBudgetBasisPoints >
                    defaultRegressionBudgetBasisPoints,
                  exceedsDefault,
                  scaledRegression <=
                    Int64(effectiveRegressionBudgetBasisPoints) * baselineMedianTwice else {
                throw ReleaseQualificationContractError.invalid(
                    field: "performanceDecision.tradeoff",
                    reason: "reviewed decisions require one larger explicit budget"
                )
            }
            try tradeoff.validate()
        }
    }

    fileprivate static func ceilingBasisPoints(
        scaledRegression: Int64,
        baselineMedianTwice: Int64
    ) -> Int {
        let quotient = scaledRegression / baselineMedianTwice
        let remainder = scaledRegression % baselineMedianTwice
        return Int(quotient + (remainder == 0 ? 0 : 1))
    }
}

public struct ReleaseQualificationPerformanceEvaluator: Sendable {
    public init() {}

    public func evaluate(
        request: ReleaseQualificationPerformanceRequest
    ) throws -> ReleaseQualificationPerformanceDecision {
        try request.validate()
        let baseline = request.baseline.medianTwice
        let candidate = request.candidate.medianTwice
        let regression: Int64
        switch request.direction {
        case .lowerIsBetter:
            regression = max(0, candidate - baseline)
        case .higherIsBetter:
            regression = max(0, baseline - candidate)
        }

        let scaledRegression = regression * 10_000
        let reportedBasisPoints = ReleaseQualificationPerformanceDecision.ceilingBasisPoints(
            scaledRegression: scaledRegression,
            baselineMedianTwice: baseline
        )
        let defaultBudget = request.benchmarkKind.defaultRegressionBudgetBasisPoints
        let exceedsDefault = scaledRegression > Int64(defaultBudget) * baseline

        let outcome: ReleaseQualificationPerformanceOutcome
        let effectiveBudget: Int
        if let tradeoff = request.tradeoff {
            guard exceedsDefault,
                  tradeoff.updatedRegressionBudgetBasisPoints > defaultBudget,
                  scaledRegression <=
                    Int64(tradeoff.updatedRegressionBudgetBasisPoints) * baseline else {
                throw ReleaseQualificationContractError.invalid(
                    field: "performance.tradeoff",
                    reason: "tradeoff is unnecessary or does not cover the measured regression"
                )
            }
            outcome = .reviewedTradeoff
            effectiveBudget = tradeoff.updatedRegressionBudgetBasisPoints
        } else {
            outcome = exceedsDefault ? .regression : .withinBudget
            effectiveBudget = defaultBudget
        }

        let decision = ReleaseQualificationPerformanceDecision(
            schemaVersion: ReleaseQualificationLimits.schemaVersion,
            baselineCommit: request.baselineCommit,
            candidateCommit: request.candidateCommit,
            metricID: request.metricID,
            benchmarkKind: request.benchmarkKind,
            direction: request.direction,
            measurementUnit: request.baseline.measurementUnit,
            measurementContextSHA256: request.baseline.measurementContextSHA256,
            discardedWarmupSamples: request.baseline.discardedWarmupSamples,
            sampleCount: request.baseline.rawSamples.count,
            baselineMedianTwice: baseline,
            candidateMedianTwice: candidate,
            regressionBasisPoints: reportedBasisPoints,
            defaultRegressionBudgetBasisPoints: defaultBudget,
            effectiveRegressionBudgetBasisPoints: effectiveBudget,
            outcome: outcome,
            tradeoff: request.tradeoff
        )
        try decision.validate()
        return decision
    }
}
