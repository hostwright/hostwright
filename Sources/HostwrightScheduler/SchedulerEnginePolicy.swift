import Foundation

public enum SchedulerBinClass: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case compact
    case balanced
    case spread
}

public struct SchedulerQueuePolicy:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let standard = SchedulerQueuePolicy(
        uncheckedPriorityPrecedesFairness: true,
        uncheckedStarvationAgeThresholdUnits: 0
    )

    public let priorityPrecedesFairness: Bool
    public let starvationAgeThresholdUnits: Int64

    public init(
        priorityPrecedesFairness: Bool = true,
        starvationAgeThresholdUnits: Int64 = 0
    ) throws {
        guard starvationAgeThresholdUnits >= 0,
              starvationAgeThresholdUnits <= SchedulerEngineLimits.absoluteMaxWeight else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "starvation-age-threshold",
                value: starvationAgeThresholdUnits
            )
        }
        self.priorityPrecedesFairness = priorityPrecedesFairness
        self.starvationAgeThresholdUnits = starvationAgeThresholdUnits
    }

    private init(
        uncheckedPriorityPrecedesFairness: Bool,
        uncheckedStarvationAgeThresholdUnits: Int64
    ) {
        priorityPrecedesFairness = uncheckedPriorityPrecedesFairness
        starvationAgeThresholdUnits = uncheckedStarvationAgeThresholdUnits
    }

    private enum CodingKeys: String, CodingKey {
        case priorityPrecedesFairness
        case starvationAgeThresholdUnits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            priorityPrecedesFairness: container.decodeIfPresent(
                Bool.self,
                forKey: .priorityPrecedesFairness
            ) ?? true,
            starvationAgeThresholdUnits: container.decodeIfPresent(
                Int64.self,
                forKey: .starvationAgeThresholdUnits
            ) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(priorityPrecedesFairness, forKey: .priorityPrecedesFairness)
        try container.encode(starvationAgeThresholdUnits, forKey: .starvationAgeThresholdUnits)
    }
}

public struct SchedulerPlacementStabilitySnapshot:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let none = SchedulerPlacementStabilitySnapshot(
        uncheckedResidenceUnits: 0,
        uncheckedCooldownRemainingUnits: 0,
        uncheckedRecoveryDelayRemainingUnits: 0,
        uncheckedRolloutGeneration: nil,
        uncheckedRolloutProtected: false
    )

    public let residenceUnits: Int64
    public let cooldownRemainingUnits: Int64
    public let recoveryDelayRemainingUnits: Int64
    public let rolloutGeneration: String?
    public let rolloutProtected: Bool

    public init(
        residenceUnits: Int64 = 0,
        cooldownRemainingUnits: Int64 = 0,
        recoveryDelayRemainingUnits: Int64 = 0,
        rolloutGeneration: String? = nil,
        rolloutProtected: Bool = false
    ) throws {
        for (field, value) in [
            ("residence-units", residenceUnits),
            ("cooldown-remaining-units", cooldownRemainingUnits),
            ("recovery-delay-remaining-units", recoveryDelayRemainingUnits)
        ] where value < 0 || value > SchedulerEngineLimits.absoluteMaxWeight {
            throw SchedulerEngineValidationError.invalidValue(field: field, value: value)
        }
        if let rolloutGeneration {
            try SchedulerEngineContractValidation.text(
                rolloutGeneration,
                field: "rollout-generation"
            )
        }
        self.residenceUnits = residenceUnits
        self.cooldownRemainingUnits = cooldownRemainingUnits
        self.recoveryDelayRemainingUnits = recoveryDelayRemainingUnits
        self.rolloutGeneration = rolloutGeneration
        self.rolloutProtected = rolloutProtected
    }

    private init(
        uncheckedResidenceUnits: Int64,
        uncheckedCooldownRemainingUnits: Int64,
        uncheckedRecoveryDelayRemainingUnits: Int64,
        uncheckedRolloutGeneration: String?,
        uncheckedRolloutProtected: Bool
    ) {
        residenceUnits = uncheckedResidenceUnits
        cooldownRemainingUnits = uncheckedCooldownRemainingUnits
        recoveryDelayRemainingUnits = uncheckedRecoveryDelayRemainingUnits
        rolloutGeneration = uncheckedRolloutGeneration
        rolloutProtected = uncheckedRolloutProtected
    }

    private enum CodingKeys: String, CodingKey {
        case residenceUnits
        case cooldownRemainingUnits
        case recoveryDelayRemainingUnits
        case rolloutGeneration
        case rolloutProtected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            residenceUnits: container.decodeIfPresent(Int64.self, forKey: .residenceUnits) ?? 0,
            cooldownRemainingUnits: container.decodeIfPresent(
                Int64.self,
                forKey: .cooldownRemainingUnits
            ) ?? 0,
            recoveryDelayRemainingUnits: container.decodeIfPresent(
                Int64.self,
                forKey: .recoveryDelayRemainingUnits
            ) ?? 0,
            rolloutGeneration: container.decodeIfPresent(String.self, forKey: .rolloutGeneration),
            rolloutProtected: container.decodeIfPresent(
                Bool.self,
                forKey: .rolloutProtected
            ) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(residenceUnits, forKey: .residenceUnits)
        try container.encode(cooldownRemainingUnits, forKey: .cooldownRemainingUnits)
        try container.encode(recoveryDelayRemainingUnits, forKey: .recoveryDelayRemainingUnits)
        try container.encodeIfPresent(rolloutGeneration, forKey: .rolloutGeneration)
        try container.encode(rolloutProtected, forKey: .rolloutProtected)
    }
}

public struct SchedulerStabilityPolicy:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let standard = SchedulerStabilityPolicy(
        uncheckedMinimumResidenceUnits: 0,
        uncheckedCooldownUnitsToRetain: 0,
        uncheckedRecoveryDelayUnitsToRetain: 0,
        uncheckedPressureSafetyOverride: true,
        uncheckedPendingWorkBenefitBasisPoints: 0,
        uncheckedMaxReconsiderationCount: 32
    )

    public let minimumResidenceUnits: Int64
    public let cooldownUnitsToRetain: Int64
    public let recoveryDelayUnitsToRetain: Int64
    public let pressureSafetyOverride: Bool
    public let pendingWorkBenefitBasisPoints: Int64
    public let maxReconsiderationCount: Int

    public init(
        minimumResidenceUnits: Int64 = 0,
        cooldownUnitsToRetain: Int64 = 0,
        recoveryDelayUnitsToRetain: Int64 = 0,
        pressureSafetyOverride: Bool = true,
        pendingWorkBenefitBasisPoints: Int64 = 0,
        maxReconsiderationCount: Int = 32
    ) throws {
        for (field, value) in [
            ("minimum-residence-units", minimumResidenceUnits),
            ("cooldown-units-to-retain", cooldownUnitsToRetain),
            ("recovery-delay-units-to-retain", recoveryDelayUnitsToRetain),
            ("pending-work-benefit", pendingWorkBenefitBasisPoints)
        ] where value < 0 || value > SchedulerEngineContractValidation.scale {
            throw SchedulerEngineValidationError.invalidValue(field: field, value: value)
        }
        guard maxReconsiderationCount > 0,
              maxReconsiderationCount <= SchedulerEngineLimits.absoluteMaxAlternativeCount else {
            throw SchedulerEngineValidationError.invalidCount(
                field: "max-reconsideration-count",
                value: maxReconsiderationCount
            )
        }
        self.minimumResidenceUnits = minimumResidenceUnits
        self.cooldownUnitsToRetain = cooldownUnitsToRetain
        self.recoveryDelayUnitsToRetain = recoveryDelayUnitsToRetain
        self.pressureSafetyOverride = pressureSafetyOverride
        self.pendingWorkBenefitBasisPoints = pendingWorkBenefitBasisPoints
        self.maxReconsiderationCount = maxReconsiderationCount
    }

    private init(
        uncheckedMinimumResidenceUnits: Int64,
        uncheckedCooldownUnitsToRetain: Int64,
        uncheckedRecoveryDelayUnitsToRetain: Int64,
        uncheckedPressureSafetyOverride: Bool,
        uncheckedPendingWorkBenefitBasisPoints: Int64,
        uncheckedMaxReconsiderationCount: Int
    ) {
        minimumResidenceUnits = uncheckedMinimumResidenceUnits
        cooldownUnitsToRetain = uncheckedCooldownUnitsToRetain
        recoveryDelayUnitsToRetain = uncheckedRecoveryDelayUnitsToRetain
        pressureSafetyOverride = uncheckedPressureSafetyOverride
        pendingWorkBenefitBasisPoints = uncheckedPendingWorkBenefitBasisPoints
        maxReconsiderationCount = uncheckedMaxReconsiderationCount
    }

    private enum CodingKeys: String, CodingKey {
        case minimumResidenceUnits
        case cooldownUnitsToRetain
        case recoveryDelayUnitsToRetain
        case pressureSafetyOverride
        case pendingWorkBenefitBasisPoints
        case maxReconsiderationCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minimumResidenceUnits: container.decodeIfPresent(
                Int64.self,
                forKey: .minimumResidenceUnits
            ) ?? 0,
            cooldownUnitsToRetain: container.decodeIfPresent(
                Int64.self,
                forKey: .cooldownUnitsToRetain
            ) ?? 0,
            recoveryDelayUnitsToRetain: container.decodeIfPresent(
                Int64.self,
                forKey: .recoveryDelayUnitsToRetain
            ) ?? 0,
            pressureSafetyOverride: container.decodeIfPresent(
                Bool.self,
                forKey: .pressureSafetyOverride
            ) ?? true,
            pendingWorkBenefitBasisPoints: container.decodeIfPresent(
                Int64.self,
                forKey: .pendingWorkBenefitBasisPoints
            ) ?? 0,
            maxReconsiderationCount: container.decodeIfPresent(
                Int.self,
                forKey: .maxReconsiderationCount
            ) ?? 32
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minimumResidenceUnits, forKey: .minimumResidenceUnits)
        try container.encode(cooldownUnitsToRetain, forKey: .cooldownUnitsToRetain)
        try container.encode(recoveryDelayUnitsToRetain, forKey: .recoveryDelayUnitsToRetain)
        try container.encode(pressureSafetyOverride, forKey: .pressureSafetyOverride)
        try container.encode(pendingWorkBenefitBasisPoints, forKey: .pendingWorkBenefitBasisPoints)
        try container.encode(maxReconsiderationCount, forKey: .maxReconsiderationCount)
    }
}

public struct SchedulerPreemptionPolicy:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let standard = SchedulerPreemptionPolicy(
        uncheckedIncomingNonPreempting: false,
        uncheckedPreemptionAuthorized: false,
        uncheckedMinimumPriorityGap: 0,
        uncheckedProtectedVictimStarvationAgeUnits: 0,
        uncheckedGracePeriodUnits: 0,
        uncheckedCheckpointRequired: false,
        uncheckedDrainRequired: false,
        uncheckedAuthorizationReference: nil
    )

    public let incomingNonPreempting: Bool
    public let preemptionAuthorized: Bool
    public let minimumPriorityGap: Int64
    public let protectedVictimStarvationAgeUnits: Int64
    public let gracePeriodUnits: Int64
    public let checkpointRequired: Bool
    public let drainRequired: Bool
    public let authorizationReference: String?

    public init(
        incomingNonPreempting: Bool = false,
        preemptionAuthorized: Bool = false,
        minimumPriorityGap: Int64 = 0,
        protectedVictimStarvationAgeUnits: Int64 = 0,
        gracePeriodUnits: Int64 = 0,
        checkpointRequired: Bool = false,
        drainRequired: Bool = false,
        authorizationReference: String? = nil
    ) throws {
        for (field, value) in [
            ("minimum-priority-gap", minimumPriorityGap),
            ("protected-victim-starvation-age", protectedVictimStarvationAgeUnits),
            ("preemption-grace-period", gracePeriodUnits)
        ] where value < 0 || value > SchedulerEngineLimits.absoluteMaxWeight {
            throw SchedulerEngineValidationError.invalidValue(field: field, value: value)
        }
        if let authorizationReference {
            try SchedulerEngineContractValidation.text(
                authorizationReference,
                field: "preemption-authorization-reference"
            )
        }
        guard !preemptionAuthorized || authorizationReference != nil else {
            throw SchedulerEngineValidationError.invalidDecision(
                "preemption-authorization-reference-required"
            )
        }
        self.incomingNonPreempting = incomingNonPreempting
        self.preemptionAuthorized = preemptionAuthorized
        self.minimumPriorityGap = minimumPriorityGap
        self.protectedVictimStarvationAgeUnits = protectedVictimStarvationAgeUnits
        self.gracePeriodUnits = gracePeriodUnits
        self.checkpointRequired = checkpointRequired
        self.drainRequired = drainRequired
        self.authorizationReference = authorizationReference
    }

    private init(
        uncheckedIncomingNonPreempting: Bool,
        uncheckedPreemptionAuthorized: Bool,
        uncheckedMinimumPriorityGap: Int64,
        uncheckedProtectedVictimStarvationAgeUnits: Int64,
        uncheckedGracePeriodUnits: Int64,
        uncheckedCheckpointRequired: Bool,
        uncheckedDrainRequired: Bool,
        uncheckedAuthorizationReference: String?
    ) {
        incomingNonPreempting = uncheckedIncomingNonPreempting
        preemptionAuthorized = uncheckedPreemptionAuthorized
        minimumPriorityGap = uncheckedMinimumPriorityGap
        protectedVictimStarvationAgeUnits = uncheckedProtectedVictimStarvationAgeUnits
        gracePeriodUnits = uncheckedGracePeriodUnits
        checkpointRequired = uncheckedCheckpointRequired
        drainRequired = uncheckedDrainRequired
        authorizationReference = uncheckedAuthorizationReference
    }

    private enum CodingKeys: String, CodingKey {
        case incomingNonPreempting
        case preemptionAuthorized
        case minimumPriorityGap
        case protectedVictimStarvationAgeUnits
        case gracePeriodUnits
        case checkpointRequired
        case drainRequired
        case authorizationReference
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            incomingNonPreempting: container.decodeIfPresent(
                Bool.self,
                forKey: .incomingNonPreempting
            ) ?? false,
            preemptionAuthorized: container.decodeIfPresent(
                Bool.self,
                forKey: .preemptionAuthorized
            ) ?? false,
            minimumPriorityGap: container.decodeIfPresent(
                Int64.self,
                forKey: .minimumPriorityGap
            ) ?? 0,
            protectedVictimStarvationAgeUnits: container.decodeIfPresent(
                Int64.self,
                forKey: .protectedVictimStarvationAgeUnits
            ) ?? 0,
            gracePeriodUnits: container.decodeIfPresent(
                Int64.self,
                forKey: .gracePeriodUnits
            ) ?? 0,
            checkpointRequired: container.decodeIfPresent(
                Bool.self,
                forKey: .checkpointRequired
            ) ?? false,
            drainRequired: container.decodeIfPresent(Bool.self, forKey: .drainRequired) ?? false,
            authorizationReference: container.decodeIfPresent(
                String.self,
                forKey: .authorizationReference
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(incomingNonPreempting, forKey: .incomingNonPreempting)
        try container.encode(preemptionAuthorized, forKey: .preemptionAuthorized)
        try container.encode(minimumPriorityGap, forKey: .minimumPriorityGap)
        try container.encode(
            protectedVictimStarvationAgeUnits,
            forKey: .protectedVictimStarvationAgeUnits
        )
        try container.encode(gracePeriodUnits, forKey: .gracePeriodUnits)
        try container.encode(checkpointRequired, forKey: .checkpointRequired)
        try container.encode(drainRequired, forKey: .drainRequired)
        try container.encodeIfPresent(authorizationReference, forKey: .authorizationReference)
    }
}

public struct SchedulerSnapshotQuality:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let standard = SchedulerSnapshotQuality(
        uncheckedConfidenceBasisPoints: SchedulerEngineContractValidation.scale,
        uncheckedStalenessUnits: 0,
        uncheckedSourceGeneration: "caller-snapshot"
    )

    public let confidenceBasisPoints: Int64
    public let stalenessUnits: Int64
    public let sourceGeneration: String

    public init(
        confidenceBasisPoints: Int64 = SchedulerEngineContractValidation.scale,
        stalenessUnits: Int64 = 0,
        sourceGeneration: String = "caller-snapshot"
    ) throws {
        guard confidenceBasisPoints >= 0,
              confidenceBasisPoints <= SchedulerEngineContractValidation.scale else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "snapshot-confidence",
                value: confidenceBasisPoints
            )
        }
        guard stalenessUnits >= 0,
              stalenessUnits <= SchedulerEngineLimits.absoluteMaxWeight else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "snapshot-staleness",
                value: stalenessUnits
            )
        }
        try SchedulerEngineContractValidation.text(sourceGeneration, field: "snapshot-generation")
        self.confidenceBasisPoints = confidenceBasisPoints
        self.stalenessUnits = stalenessUnits
        self.sourceGeneration = sourceGeneration
    }

    private init(
        uncheckedConfidenceBasisPoints: Int64,
        uncheckedStalenessUnits: Int64,
        uncheckedSourceGeneration: String
    ) {
        confidenceBasisPoints = uncheckedConfidenceBasisPoints
        stalenessUnits = uncheckedStalenessUnits
        sourceGeneration = uncheckedSourceGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case confidenceBasisPoints
        case stalenessUnits
        case sourceGeneration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            confidenceBasisPoints: container.decodeIfPresent(
                Int64.self,
                forKey: .confidenceBasisPoints
            ) ?? SchedulerEngineContractValidation.scale,
            stalenessUnits: container.decodeIfPresent(
                Int64.self,
                forKey: .stalenessUnits
            ) ?? 0,
            sourceGeneration: container.decodeIfPresent(
                String.self,
                forKey: .sourceGeneration
            ) ?? "caller-snapshot"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(confidenceBasisPoints, forKey: .confidenceBasisPoints)
        try container.encode(stalenessUnits, forKey: .stalenessUnits)
        try container.encode(sourceGeneration, forKey: .sourceGeneration)
    }
}
