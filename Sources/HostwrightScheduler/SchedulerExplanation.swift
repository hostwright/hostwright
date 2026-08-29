import Foundation

public enum SchedulerDecisionOutcome: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case placed
    case retainedExistingPlacement = "retained-existing-placement"
    case preemptionProposed = "preemption-proposed"
    case unschedulable
}

public enum SchedulerExplanationCode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case placed
    case retainedExistingPlacement = "retained-existing-placement"
    case preemptionProposed = "preemption-proposed"
    case noFeasibleNode = "no-feasible-node"
}

public struct SchedulerCapacityExplanation:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let rawRequest: ResourceVector
    public let declaredLimit: ResourceVector?
    public let overhead: ResourceVector
    public let safetyMargin: ResourceVector
    public let chargedCapacity: ResourceVector
    public let overcommitRatios: [String: SchedulerResourceRatio]

    public init(
        rawRequest: ResourceVector,
        declaredLimit: ResourceVector?,
        overhead: ResourceVector,
        safetyMargin: ResourceVector,
        chargedCapacity: ResourceVector,
        overcommitRatios: [String: SchedulerResourceRatio] = [:]
    ) throws {
        let withOverhead = try rawRequest.adding(overhead)
        let minimumCharge = try withOverhead.adding(safetyMargin)
        guard minimumCharge.fits(in: chargedCapacity) else {
            throw SchedulerEngineValidationError.invalidDecision("capacity-explanation-charge")
        }
        guard overcommitRatios.count <= SchedulerEngineLimits.absoluteMaxOvercommitRatioCount else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: "capacity-explanation-overcommit-ratios",
                limit: SchedulerEngineLimits.absoluteMaxOvercommitRatioCount,
                actual: overcommitRatios.count
            )
        }
        for resource in overcommitRatios.keys {
            try SchedulerEngineContractValidation.text(
                resource,
                field: "capacity-explanation-overcommit-resource"
            )
        }
        self.rawRequest = rawRequest
        self.declaredLimit = declaredLimit
        self.overhead = overhead
        self.safetyMargin = safetyMargin
        self.chargedCapacity = chargedCapacity
        self.overcommitRatios = overcommitRatios.keys.sorted().reduce(into: [:]) { result, resource in
            result[resource] = overcommitRatios[resource]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case rawRequest
        case declaredLimit
        case overhead
        case safetyMargin
        case chargedCapacity
        case overcommitRatios
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            rawRequest: container.decode(ResourceVector.self, forKey: .rawRequest),
            declaredLimit: container.decodeIfPresent(
                ResourceVector.self,
                forKey: .declaredLimit
            ),
            overhead: container.decodeIfPresent(ResourceVector.self, forKey: .overhead) ?? .zero,
            safetyMargin: container.decodeIfPresent(
                ResourceVector.self,
                forKey: .safetyMargin
            ) ?? .zero,
            chargedCapacity: container.decode(ResourceVector.self, forKey: .chargedCapacity),
            overcommitRatios: container.decodeIfPresent(
                [String: SchedulerResourceRatio].self,
                forKey: .overcommitRatios
            ) ?? [:]
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawRequest, forKey: .rawRequest)
        try container.encodeIfPresent(declaredLimit, forKey: .declaredLimit)
        try container.encode(overhead, forKey: .overhead)
        try container.encode(safetyMargin, forKey: .safetyMargin)
        try container.encode(chargedCapacity, forKey: .chargedCapacity)
        try container.encode(overcommitRatios, forKey: .overcommitRatios)
    }
}

public struct SchedulerFairnessExplanation:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let subjectID: String
    public let projectID: String
    public let usage: ResourceVector
    public let guarantee: ResourceVector
    public let quota: ResourceVector?
    public let pendingDemand: ResourceVector
    public let starvationAgeUnits: Int64
    public let weightedDominantShareBasisPoints: Int64
    public let guaranteeShareBasisPoints: Int64
    public let borrowingBasisPoints: Int64
    public let reclaimableBorrowedUsage: ResourceVector

    public init(
        subjectID: String,
        projectID: String,
        usage: ResourceVector,
        guarantee: ResourceVector,
        quota: ResourceVector?,
        pendingDemand: ResourceVector,
        starvationAgeUnits: Int64,
        weightedDominantShareBasisPoints: Int64,
        guaranteeShareBasisPoints: Int64,
        borrowingBasisPoints: Int64,
        reclaimableBorrowedUsage: ResourceVector
    ) throws {
        try SchedulerEngineContractValidation.text(subjectID, field: "fairness-subject")
        try SchedulerEngineContractValidation.text(projectID, field: "fairness-project")
        guard starvationAgeUnits >= 0,
              weightedDominantShareBasisPoints >= 0,
              weightedDominantShareBasisPoints <= SchedulerEngineContractValidation.scale,
              guaranteeShareBasisPoints >= 0,
              guaranteeShareBasisPoints <= SchedulerEngineContractValidation.scale,
              borrowingBasisPoints >= 0,
              borrowingBasisPoints <= SchedulerEngineContractValidation.scale else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "fairness-explanation",
                value: weightedDominantShareBasisPoints
            )
        }
        self.subjectID = subjectID
        self.projectID = projectID
        self.usage = usage
        self.guarantee = guarantee
        self.quota = quota
        self.pendingDemand = pendingDemand
        self.starvationAgeUnits = starvationAgeUnits
        self.weightedDominantShareBasisPoints = weightedDominantShareBasisPoints
        self.guaranteeShareBasisPoints = guaranteeShareBasisPoints
        self.borrowingBasisPoints = borrowingBasisPoints
        self.reclaimableBorrowedUsage = reclaimableBorrowedUsage
    }

    private enum CodingKeys: String, CodingKey {
        case subjectID
        case projectID
        case usage
        case guarantee
        case quota
        case pendingDemand
        case starvationAgeUnits
        case weightedDominantShareBasisPoints
        case guaranteeShareBasisPoints
        case borrowingBasisPoints
        case reclaimableBorrowedUsage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            subjectID: container.decode(String.self, forKey: .subjectID),
            projectID: container.decode(String.self, forKey: .projectID),
            usage: container.decodeIfPresent(ResourceVector.self, forKey: .usage) ?? .zero,
            guarantee: container.decodeIfPresent(ResourceVector.self, forKey: .guarantee) ?? .zero,
            quota: container.decodeIfPresent(ResourceVector.self, forKey: .quota),
            pendingDemand: container.decodeIfPresent(
                ResourceVector.self,
                forKey: .pendingDemand
            ) ?? .zero,
            starvationAgeUnits: container.decodeIfPresent(
                Int64.self,
                forKey: .starvationAgeUnits
            ) ?? 0,
            weightedDominantShareBasisPoints: container.decodeIfPresent(
                Int64.self,
                forKey: .weightedDominantShareBasisPoints
            ) ?? 0,
            guaranteeShareBasisPoints: container.decodeIfPresent(
                Int64.self,
                forKey: .guaranteeShareBasisPoints
            ) ?? 0,
            borrowingBasisPoints: container.decodeIfPresent(
                Int64.self,
                forKey: .borrowingBasisPoints
            ) ?? 0,
            reclaimableBorrowedUsage: container.decodeIfPresent(
                ResourceVector.self,
                forKey: .reclaimableBorrowedUsage
            ) ?? .zero
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subjectID, forKey: .subjectID)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(usage, forKey: .usage)
        try container.encode(guarantee, forKey: .guarantee)
        try container.encodeIfPresent(quota, forKey: .quota)
        try container.encode(pendingDemand, forKey: .pendingDemand)
        try container.encode(starvationAgeUnits, forKey: .starvationAgeUnits)
        try container.encode(
            weightedDominantShareBasisPoints,
            forKey: .weightedDominantShareBasisPoints
        )
        try container.encode(guaranteeShareBasisPoints, forKey: .guaranteeShareBasisPoints)
        try container.encode(borrowingBasisPoints, forKey: .borrowingBasisPoints)
        try container.encode(reclaimableBorrowedUsage, forKey: .reclaimableBorrowedUsage)
    }
}

public enum SchedulerTieBreakReason: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case score
    case fairness
    case antiChurn
    case stableNodeUUID = "stable-node-uuid"
    case noFeasibleNode = "no-feasible-node"
    case preemptionMinimumDisruption = "preemption-minimum-disruption"
}

public struct SchedulerTieBreakExplanation:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let reason: SchedulerTieBreakReason
    public let chosenNodeID: UUID?
    public let thresholdBasisPoints: Int64

    public init(
        reason: SchedulerTieBreakReason,
        chosenNodeID: UUID?,
        thresholdBasisPoints: Int64 = 0
    ) throws {
        guard thresholdBasisPoints >= 0,
              thresholdBasisPoints <= SchedulerEngineContractValidation.scale else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "tie-break-threshold",
                value: thresholdBasisPoints
            )
        }
        self.reason = reason
        self.chosenNodeID = chosenNodeID
        self.thresholdBasisPoints = thresholdBasisPoints
    }

    private enum CodingKeys: String, CodingKey {
        case reason
        case chosenNodeID
        case thresholdBasisPoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reason: container.decode(SchedulerTieBreakReason.self, forKey: .reason),
            chosenNodeID: container.decodeIfPresent(UUID.self, forKey: .chosenNodeID),
            thresholdBasisPoints: container.decodeIfPresent(
                Int64.self,
                forKey: .thresholdBasisPoints
            ) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reason, forKey: .reason)
        try container.encodeIfPresent(chosenNodeID, forKey: .chosenNodeID)
        try container.encode(thresholdBasisPoints, forKey: .thresholdBasisPoints)
    }
}

public enum SchedulerFilterKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case capacity
    case architecture
    case runtimeProvider = "runtime-provider"
    case capabilities
    case healthMaintenance = "health-maintenance"
    case labelsAffinity = "labels-affinity"
    case taintsTolerations = "taints-tolerations"
    case acceleratorAvailability = "accelerator-availability"
    case hostPressureEnergy = "host-pressure-energy"
    case quota
    case preemption
    case volumeAvailability = "volume-availability"
    case portAvailability = "port-availability"
    case networkAvailability = "network-availability"
}

public enum SchedulerFilterFailureCode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case insufficientCapacity = "insufficient-capacity"
    case architectureMismatch = "architecture-mismatch"
    case runtimeMismatch = "runtime-mismatch"
    case providerMismatch = "provider-mismatch"
    case missingCapability = "missing-capability"
    case nodeNotHealthy = "node-not-healthy"
    case nodeUnavailableForMaintenance = "node-unavailable-for-maintenance"
    case requiredLabelMissing = "required-label-missing"
    case requiredLabelMismatch = "required-label-mismatch"
    case forbiddenLabelPresent = "forbidden-label-present"
    case untoleratedTaint = "untolerated-taint"
    case acceleratorUnavailable = "accelerator-unavailable"
    case pressureUnavailable = "pressure-unavailable"
    case quotaExceeded = "quota-exceeded"
    case preemptionSearchBoundExceeded = "preemption-search-bound-exceeded"
    case preemptionWorkloadNotEligible = "preemption-workload-not-eligible"
    case preemptionAuthorizationRequired = "preemption-authorization-required"
    case volumeUnavailable = "volume-unavailable"
    case portUnavailable = "port-unavailable"
    case networkUnavailable = "network-unavailable"
}

public struct SchedulerFilterFailure:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let filter: SchedulerFilterKind
    public let code: SchedulerFilterFailureCode
    public let workloadID: UUID
    public let nodeID: UUID
    public let stableDetailKey: String
    public let message: String

    public init(
        filter: SchedulerFilterKind,
        code: SchedulerFilterFailureCode,
        workloadID: UUID,
        nodeID: UUID,
        stableDetailKey: String,
        message: String
    ) throws {
        try SchedulerEngineContractValidation.text(stableDetailKey, field: "filter-detail")
        try SchedulerEngineContractValidation.text(message, field: "filter-message")
        self.filter = filter
        self.code = code
        self.workloadID = workloadID
        self.nodeID = nodeID
        self.stableDetailKey = stableDetailKey
        self.message = message
    }

    public var orderingKey: String {
        [
            SchedulerOrdering.uuidKey(workloadID),
            SchedulerOrdering.uuidKey(nodeID),
            filter.rawValue,
            code.rawValue,
            stableDetailKey,
            message
        ].joined(separator: "|")
    }

    private enum CodingKeys: String, CodingKey {
        case filter
        case code
        case workloadID
        case nodeID
        case stableDetailKey
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            filter: container.decode(SchedulerFilterKind.self, forKey: .filter),
            code: container.decode(SchedulerFilterFailureCode.self, forKey: .code),
            workloadID: container.decode(UUID.self, forKey: .workloadID),
            nodeID: container.decode(UUID.self, forKey: .nodeID),
            stableDetailKey: container.decode(String.self, forKey: .stableDetailKey),
            message: container.decode(String.self, forKey: .message)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filter, forKey: .filter)
        try container.encode(code, forKey: .code)
        try container.encode(workloadID, forKey: .workloadID)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(stableDetailKey, forKey: .stableDetailKey)
        try container.encode(message, forKey: .message)
    }
}

public struct SchedulerDecisionExplanation:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let code: SchedulerExplanationCode
    public let summary: String
    public let detailKeys: [String]

    public init(
        code: SchedulerExplanationCode,
        summary: String,
        detailKeys: [String] = []
    ) throws {
        try SchedulerEngineContractValidation.text(summary, field: "explanation-summary")
        for key in detailKeys {
            try SchedulerEngineContractValidation.text(key, field: "explanation-detail")
        }
        guard detailKeys.count <= SchedulerEngineLimits.absoluteMaxExplanationDetails else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: "explanation-details",
                limit: SchedulerEngineLimits.absoluteMaxExplanationDetails,
                actual: detailKeys.count
            )
        }
        guard Set(detailKeys).count == detailKeys.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(field: "explanation-details")
        }
        self.code = code
        self.summary = summary
        self.detailKeys = detailKeys
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case summary
        case detailKeys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            code: container.decode(SchedulerExplanationCode.self, forKey: .code),
            summary: container.decode(String.self, forKey: .summary),
            detailKeys: container.decodeIfPresent([String].self, forKey: .detailKeys) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(summary, forKey: .summary)
        try container.encode(detailKeys, forKey: .detailKeys)
    }
}

public struct SchedulerPreemptionExplanation:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let summary: String
    public let victimCount: Int
    public let disruptionCostBasisPoints: Int64
    public let budgetIDs: [String]

    public init(
        summary: String,
        victimCount: Int,
        disruptionCostBasisPoints: Int64,
        budgetIDs: [String]
    ) throws {
        try SchedulerEngineContractValidation.text(summary, field: "preemption-explanation")
        guard victimCount >= 0 else {
            throw SchedulerEngineValidationError.invalidCount(
                field: "preemption-victim-count",
                value: victimCount
            )
        }
        guard victimCount <= SchedulerEngineLimits.absoluteMaxVictimCount else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: "preemption-victim-count",
                limit: SchedulerEngineLimits.absoluteMaxVictimCount,
                actual: victimCount
            )
        }
        guard disruptionCostBasisPoints >= 0 else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "preemption-disruption-cost",
                value: disruptionCostBasisPoints
            )
        }
        for budgetID in budgetIDs {
            try SchedulerEngineContractValidation.text(budgetID, field: "preemption-budget-id")
        }
        guard budgetIDs.count <= SchedulerEngineLimits.absoluteMaxVictimCount else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: "preemption-budget-ids",
                limit: SchedulerEngineLimits.absoluteMaxVictimCount,
                actual: budgetIDs.count
            )
        }
        self.summary = summary
        self.victimCount = victimCount
        self.disruptionCostBasisPoints = disruptionCostBasisPoints
        self.budgetIDs = Array(Set(budgetIDs)).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case victimCount
        case disruptionCostBasisPoints
        case budgetIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            summary: container.decode(String.self, forKey: .summary),
            victimCount: container.decode(Int.self, forKey: .victimCount),
            disruptionCostBasisPoints: container.decode(
                Int64.self,
                forKey: .disruptionCostBasisPoints
            ),
            budgetIDs: container.decodeIfPresent([String].self, forKey: .budgetIDs) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(summary, forKey: .summary)
        try container.encode(victimCount, forKey: .victimCount)
        try container.encode(disruptionCostBasisPoints, forKey: .disruptionCostBasisPoints)
        try container.encode(budgetIDs, forKey: .budgetIDs)
    }
}

public struct SchedulerNodeAlternative:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let nodeID: UUID
    public let scoreComponents: SchedulerScoreComponents

    public init(nodeID: UUID, scoreComponents: SchedulerScoreComponents) {
        self.nodeID = nodeID
        self.scoreComponents = scoreComponents
    }
}

public struct SchedulerWorkloadDecision:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let workloadID: UUID
    public let outcome: SchedulerDecisionOutcome
    public let chosenNodeID: UUID?
    public let scoreComponents: SchedulerScoreComponents?
    public let feasibleAlternatives: [SchedulerNodeAlternative]
    public let filterFailures: [SchedulerFilterFailure]
    public let preemption: SchedulerPreemptionProposal?
    public let explanation: SchedulerDecisionExplanation
    public let capacityExplanation: SchedulerCapacityExplanation?
    public let fairnessExplanation: SchedulerFairnessExplanation?
    public let tieBreak: SchedulerTieBreakExplanation?
    public let snapshotQuality: SchedulerSnapshotQuality?

    public init(
        workloadID: UUID,
        outcome: SchedulerDecisionOutcome,
        chosenNodeID: UUID?,
        scoreComponents: SchedulerScoreComponents?,
        feasibleAlternatives: [SchedulerNodeAlternative],
        filterFailures: [SchedulerFilterFailure],
        preemption: SchedulerPreemptionProposal?,
        explanation: SchedulerDecisionExplanation,
        capacityExplanation: SchedulerCapacityExplanation? = nil,
        fairnessExplanation: SchedulerFairnessExplanation? = nil,
        tieBreak: SchedulerTieBreakExplanation? = nil,
        snapshotQuality: SchedulerSnapshotQuality? = nil,
        limits: SchedulerEngineLimits = .default
    ) throws {
        guard feasibleAlternatives.count <= limits.maxAlternativeCount else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: "alternatives",
                limit: limits.maxAlternativeCount,
                actual: feasibleAlternatives.count
            )
        }
        guard filterFailures.count <= limits.maxFilterFailureCount else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: "filter-failures",
                limit: limits.maxFilterFailureCount,
                actual: filterFailures.count
            )
        }
        guard Set(feasibleAlternatives.map(\.nodeID)).count == feasibleAlternatives.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(field: "alternatives")
        }
        guard Set(filterFailures.map(\.orderingKey)).count == filterFailures.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(field: "filter-failures")
        }
        for failure in filterFailures {
            guard failure.workloadID == workloadID else {
                throw SchedulerEngineValidationError.invalidDecision("filter-workload-id")
            }
            try SchedulerEngineContractValidation.text(
                failure.stableDetailKey,
                field: "filter-detail",
                limit: limits.maxStringBytes
            )
            try SchedulerEngineContractValidation.text(
                failure.message,
                field: "filter-message",
                limit: limits.maxStringBytes
            )
        }
        try SchedulerEngineContractValidation.text(
            explanation.summary,
            field: "explanation-summary",
            limit: limits.maxStringBytes
        )
        for detail in explanation.detailKeys {
            try SchedulerEngineContractValidation.text(
                detail,
                field: "explanation-detail",
                limit: limits.maxStringBytes
            )
        }
        switch outcome {
        case .preemptionProposed:
            guard preemption != nil,
                  chosenNodeID == nil,
                  scoreComponents == nil,
                  feasibleAlternatives.isEmpty,
                  preemption?.targetWorkloadID == workloadID else {
                throw SchedulerEngineValidationError.invalidDecision("preemption-shape")
            }
            if let preemption {
                guard preemption.explanation.victimCount == preemption.victims.count,
                      preemption.explanation.disruptionCostBasisPoints
                        == preemption.disruptionCostBasisPoints,
                      Set(preemption.explanation.budgetIDs)
                        == Set(preemption.victims.compactMap(\.budgetID)) else {
                    throw SchedulerEngineValidationError.invalidDecision(
                        "preemption-explanation-mismatch"
                    )
                }
                try SchedulerEngineContractValidation.digest(
                    preemption.intentDigest,
                    limit: limits.maxDigestBytes
                )
            }
        case .placed, .retainedExistingPlacement:
            guard chosenNodeID != nil,
                  scoreComponents != nil,
                  preemption == nil else {
                throw SchedulerEngineValidationError.invalidDecision("placement-shape")
            }
        case .unschedulable:
            guard chosenNodeID == nil,
                  scoreComponents == nil,
                  preemption == nil,
                  feasibleAlternatives.isEmpty else {
                throw SchedulerEngineValidationError.invalidDecision("unschedulable-shape")
            }
        }
        let expectedExplanationCode: SchedulerExplanationCode
        switch outcome {
        case .placed:
            expectedExplanationCode = .placed
        case .retainedExistingPlacement:
            expectedExplanationCode = .retainedExistingPlacement
        case .preemptionProposed:
            expectedExplanationCode = .preemptionProposed
        case .unschedulable:
            expectedExplanationCode = .noFeasibleNode
        }
        guard explanation.code == expectedExplanationCode else {
            throw SchedulerEngineValidationError.invalidDecision("explanation-outcome")
        }
        if let fairnessExplanation {
            try SchedulerEngineContractValidation.text(
                fairnessExplanation.subjectID,
                field: "fairness-subject",
                limit: limits.maxStringBytes
            )
            try SchedulerEngineContractValidation.text(
                fairnessExplanation.projectID,
                field: "fairness-project",
                limit: limits.maxStringBytes
            )
        }
        if let snapshotQuality {
            try SchedulerEngineContractValidation.text(
                snapshotQuality.sourceGeneration,
                field: "snapshot-generation",
                limit: limits.maxStringBytes
            )
        }
        self.workloadID = workloadID
        self.outcome = outcome
        self.chosenNodeID = chosenNodeID
        self.scoreComponents = scoreComponents
        self.feasibleAlternatives = feasibleAlternatives
        self.filterFailures = filterFailures
        self.preemption = preemption
        self.explanation = explanation
        self.capacityExplanation = capacityExplanation
        self.fairnessExplanation = fairnessExplanation
        self.tieBreak = tieBreak
        self.snapshotQuality = snapshotQuality
    }

    public var nodeID: UUID? {
        chosenNodeID
    }

    public var preemptionExplanation: SchedulerPreemptionExplanation? {
        preemption?.explanation
    }

    private enum CodingKeys: String, CodingKey {
        case workloadID
        case outcome
        case chosenNodeID
        case scoreComponents
        case feasibleAlternatives
        case filterFailures
        case preemption
        case explanation
        case capacityExplanation
        case fairnessExplanation
        case tieBreak
        case snapshotQuality
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            workloadID: container.decode(UUID.self, forKey: .workloadID),
            outcome: container.decode(SchedulerDecisionOutcome.self, forKey: .outcome),
            chosenNodeID: container.decodeIfPresent(UUID.self, forKey: .chosenNodeID),
            scoreComponents: container.decodeIfPresent(
                SchedulerScoreComponents.self,
                forKey: .scoreComponents
            ),
            feasibleAlternatives: container.decodeIfPresent(
                [SchedulerNodeAlternative].self,
                forKey: .feasibleAlternatives
            ) ?? [],
            filterFailures: container.decodeIfPresent(
                [SchedulerFilterFailure].self,
                forKey: .filterFailures
            ) ?? [],
            preemption: container.decodeIfPresent(
                SchedulerPreemptionProposal.self,
                forKey: .preemption
            ),
            explanation: container.decode(SchedulerDecisionExplanation.self, forKey: .explanation),
            capacityExplanation: container.decodeIfPresent(
                SchedulerCapacityExplanation.self,
                forKey: .capacityExplanation
            ),
            fairnessExplanation: container.decodeIfPresent(
                SchedulerFairnessExplanation.self,
                forKey: .fairnessExplanation
            ),
            tieBreak: container.decodeIfPresent(
                SchedulerTieBreakExplanation.self,
                forKey: .tieBreak
            ),
            snapshotQuality: container.decodeIfPresent(
                SchedulerSnapshotQuality.self,
                forKey: .snapshotQuality
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workloadID, forKey: .workloadID)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(chosenNodeID, forKey: .chosenNodeID)
        try container.encodeIfPresent(scoreComponents, forKey: .scoreComponents)
        try container.encode(feasibleAlternatives, forKey: .feasibleAlternatives)
        try container.encode(filterFailures, forKey: .filterFailures)
        try container.encodeIfPresent(preemption, forKey: .preemption)
        try container.encode(explanation, forKey: .explanation)
        try container.encodeIfPresent(capacityExplanation, forKey: .capacityExplanation)
        try container.encodeIfPresent(fairnessExplanation, forKey: .fairnessExplanation)
        try container.encodeIfPresent(tieBreak, forKey: .tieBreak)
        try container.encodeIfPresent(snapshotQuality, forKey: .snapshotQuality)
    }
}

public struct SchedulerDecision:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let decisionID: UUID
    public let inputDigest: String
    public let orderedWorkloadIDs: [UUID]
    public let workloadDecisions: [SchedulerWorkloadDecision]
    public let snapshotQuality: SchedulerSnapshotQuality?

    public init(
        decisionID: UUID,
        inputDigest: String,
        orderedWorkloadIDs: [UUID],
        workloadDecisions: [SchedulerWorkloadDecision],
        snapshotQuality: SchedulerSnapshotQuality? = nil,
        limits: SchedulerEngineLimits = .default
    ) throws {
        try SchedulerEngineContractValidation.digest(inputDigest, limit: limits.maxDigestBytes)
        guard orderedWorkloadIDs.count <= limits.maxWorkloadCount else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: "ordered-workloads",
                limit: limits.maxWorkloadCount,
                actual: orderedWorkloadIDs.count
            )
        }
        guard workloadDecisions.count <= limits.maxWorkloadCount else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: "decisions",
                limit: limits.maxWorkloadCount,
                actual: workloadDecisions.count
            )
        }
        guard orderedWorkloadIDs.count == workloadDecisions.count else {
            throw SchedulerEngineValidationError.invalidDecision("workload-count")
        }
        guard Set(orderedWorkloadIDs).count == orderedWorkloadIDs.count,
              workloadDecisions.map(\.workloadID) == orderedWorkloadIDs,
              Set(workloadDecisions.map(\.workloadID)).count == workloadDecisions.count else {
            throw SchedulerEngineValidationError.invalidDecision("workload-identities")
        }
        self.decisionID = decisionID
        self.inputDigest = inputDigest
        self.orderedWorkloadIDs = orderedWorkloadIDs
        self.workloadDecisions = workloadDecisions
        self.snapshotQuality = snapshotQuality
    }

    public var decisions: [SchedulerWorkloadDecision] {
        workloadDecisions
    }

    private enum CodingKeys: String, CodingKey {
        case decisionID
        case inputDigest
        case orderedWorkloadIDs
        case workloadDecisions
        case snapshotQuality
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            decisionID: container.decode(UUID.self, forKey: .decisionID),
            inputDigest: container.decode(String.self, forKey: .inputDigest),
            orderedWorkloadIDs: container.decode([UUID].self, forKey: .orderedWorkloadIDs),
            workloadDecisions: container.decode(
                [SchedulerWorkloadDecision].self,
                forKey: .workloadDecisions
            ),
            snapshotQuality: container.decodeIfPresent(
                SchedulerSnapshotQuality.self,
                forKey: .snapshotQuality
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decisionID, forKey: .decisionID)
        try container.encode(inputDigest, forKey: .inputDigest)
        try container.encode(orderedWorkloadIDs, forKey: .orderedWorkloadIDs)
        try container.encode(workloadDecisions, forKey: .workloadDecisions)
        try container.encodeIfPresent(snapshotQuality, forKey: .snapshotQuality)
    }
}
