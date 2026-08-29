import Foundation

public enum ReleaseQualificationPerformanceReceiptEvidenceScope:
    String, Codable, Sendable
{
    case sourceOnlyAdvisory = "source-only-advisory"
}

public enum ReleaseQualificationPerformanceReceiptPromotionStatus:
    String, Codable, Sendable
{
    case nonPromotable = "non-promotable"
}

public enum ReleaseQualificationPerformanceReceiptUnmeasuredDimension:
    String, Codable, CaseIterable, Sendable
{
    case capacity
    case density
    case energy
    case hardwareQualification = "hardware-qualification"
    case sleepWake = "sleep-wake"
    case thermal

    public static var canonicalSet: [Self] {
        allCases.sorted { $0.rawValue < $1.rawValue }
    }
}

/// A source-derived performance precursor, not hardware or release evidence.
/// This schema intentionally has no raw-sample corpus, external report, hardware
/// identity, distribution evidence, or cleanup contract, so it can never promote.
public struct ReleaseQualificationPerformanceReceipt:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let schemaVersion: Int
    public let releaseTarget: String
    public let baselineCommit: ReleaseQualificationCommit
    public let candidateCommit: ReleaseQualificationCommit
    public let metricID: String
    public let recordedAt: ReleaseQualificationTimestamp
    public let evidenceScope: ReleaseQualificationPerformanceReceiptEvidenceScope
    public let promotionStatus: ReleaseQualificationPerformanceReceiptPromotionStatus
    public let satisfiesRequiredGate: Bool
    public let unmeasuredDimensions:
        [ReleaseQualificationPerformanceReceiptUnmeasuredDimension]
    public let decision: ReleaseQualificationPerformanceDecision

    public var isPromotable: Bool { false }
    public var isHardwareOrReleaseEvidence: Bool { false }

    public init(
        releaseTarget: String,
        recordedAt: ReleaseQualificationTimestamp,
        decision: ReleaseQualificationPerformanceDecision
    ) throws {
        schemaVersion = ReleaseQualificationLimits.schemaVersion
        self.releaseTarget = releaseTarget
        baselineCommit = decision.baselineCommit
        candidateCommit = decision.candidateCommit
        metricID = decision.metricID
        self.recordedAt = recordedAt
        evidenceScope = .sourceOnlyAdvisory
        promotionStatus = .nonPromotable
        satisfiesRequiredGate = false
        unmeasuredDimensions =
            ReleaseQualificationPerformanceReceiptUnmeasuredDimension.canonicalSet
        self.decision = decision
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == ReleaseQualificationLimits.schemaVersion else {
            throw ReleaseQualificationContractError.unsupportedSchemaVersion(schemaVersion)
        }
        guard releaseTarget ==
                ReleaseQualificationSupportedMatrix.committed.releaseTarget else {
            throw ReleaseQualificationContractError.invalid(
                field: "performanceReceipt.releaseTarget",
                reason: "receipt must bind the exact committed release target"
            )
        }
        try baselineCommit.validate()
        try candidateCommit.validate()
        try recordedAt.validate()
        try decision.validate()
        guard baselineCommit == decision.baselineCommit,
              candidateCommit == decision.candidateCommit,
              metricID == decision.metricID else {
            throw ReleaseQualificationContractError.invalid(
                field: "performanceReceipt.decisionBinding",
                reason: "receipt source commits and metric must match the embedded decision"
            )
        }
        guard evidenceScope == .sourceOnlyAdvisory,
              promotionStatus == .nonPromotable,
              satisfiesRequiredGate == false,
              decision.isHardwareOrReleaseEvidence == false else {
            throw ReleaseQualificationContractError.invalid(
                field: "performanceReceipt.promotion",
                reason: "source-only advisory receipts cannot promote or satisfy a gate"
            )
        }
        guard unmeasuredDimensions ==
                ReleaseQualificationPerformanceReceiptUnmeasuredDimension.canonicalSet else {
            throw ReleaseQualificationContractError.invalid(
                field: "performanceReceipt.unmeasuredDimensions",
                reason: "all source-only coverage gaps must be present once in canonical order"
            )
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case releaseTarget
        case baselineCommit
        case candidateCommit
        case metricID
        case recordedAt
        case evidenceScope
        case promotionStatus
        case satisfiesRequiredGate
        case unmeasuredDimensions
        case decision
    }

    public init(from decoder: Decoder) throws {
        let rawValues = try decoder.container(
            keyedBy: ReleaseQualificationPerformanceReceiptDynamicCodingKey.self
        )
        let actualKeys = Set(rawValues.allKeys.map(\.stringValue))
        let expectedKeys = Set(CodingKeys.allCases.map(\.stringValue))
        guard actualKeys == expectedKeys else {
            throw ReleaseQualificationContractError.invalid(
                field: "performanceReceipt.keys",
                reason: "receipt keys must exactly match the closed schema"
            )
        }

        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        releaseTarget = try values.decode(String.self, forKey: .releaseTarget)
        baselineCommit = try values.decode(
            ReleaseQualificationCommit.self,
            forKey: .baselineCommit
        )
        candidateCommit = try values.decode(
            ReleaseQualificationCommit.self,
            forKey: .candidateCommit
        )
        metricID = try values.decode(String.self, forKey: .metricID)
        recordedAt = try values.decode(
            ReleaseQualificationTimestamp.self,
            forKey: .recordedAt
        )
        evidenceScope = try values.decode(
            ReleaseQualificationPerformanceReceiptEvidenceScope.self,
            forKey: .evidenceScope
        )
        promotionStatus = try values.decode(
            ReleaseQualificationPerformanceReceiptPromotionStatus.self,
            forKey: .promotionStatus
        )
        satisfiesRequiredGate = try values.decode(
            Bool.self,
            forKey: .satisfiesRequiredGate
        )
        unmeasuredDimensions = try values.decode(
            [ReleaseQualificationPerformanceReceiptUnmeasuredDimension].self,
            forKey: .unmeasuredDimensions
        )
        decision = try values.decode(
            ReleaseQualificationPerformanceDecision.self,
            forKey: .decision
        )
        try validate()
    }
}

private struct ReleaseQualificationPerformanceReceiptDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}
