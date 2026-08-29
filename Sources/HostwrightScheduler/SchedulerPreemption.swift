import Foundation

public struct SchedulerDisruptionProfile:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let `default` = SchedulerDisruptionProfile(
        uncheckedMovementCostBasisPoints: 2_000
    )

    public let movementCostBasisPoints: Int64

    public init(movementCostBasisPoints: Int64 = 2_000) throws {
        guard movementCostBasisPoints >= 0,
              movementCostBasisPoints <= SchedulerEngineContractValidation.scale else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "movement-cost-basis-points",
                value: movementCostBasisPoints
            )
        }
        self.movementCostBasisPoints = movementCostBasisPoints
    }

    private init(uncheckedMovementCostBasisPoints: Int64) {
        movementCostBasisPoints = uncheckedMovementCostBasisPoints
    }

    private enum CodingKeys: String, CodingKey {
        case movementCostBasisPoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            movementCostBasisPoints: container.decodeIfPresent(
                Int64.self,
                forKey: .movementCostBasisPoints
            ) ?? 2_000
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(movementCostBasisPoints, forKey: .movementCostBasisPoints)
    }
}

public struct SchedulerExistingPlacement:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let workloadID: UUID
    public let nodeID: UUID
    public let allocation: ResourceVector
    public let topologyGroupID: String?
    public let stability: SchedulerPlacementStabilitySnapshot

    public init(
        workloadID: UUID,
        nodeID: UUID,
        allocation: ResourceVector,
        topologyGroupID: String? = nil,
        stability: SchedulerPlacementStabilitySnapshot = .none
    ) throws {
        if let topologyGroupID {
            try SchedulerEngineContractValidation.text(
                topologyGroupID,
                field: "placement-topology-group-id"
            )
        }
        self.workloadID = workloadID
        self.nodeID = nodeID
        self.allocation = allocation
        self.topologyGroupID = topologyGroupID
        self.stability = stability
    }

    private enum CodingKeys: String, CodingKey {
        case workloadID
        case nodeID
        case allocation
        case topologyGroupID
        case stability
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            workloadID: container.decode(UUID.self, forKey: .workloadID),
            nodeID: container.decode(UUID.self, forKey: .nodeID),
            allocation: container.decode(ResourceVector.self, forKey: .allocation),
            topologyGroupID: container.decodeIfPresent(String.self, forKey: .topologyGroupID),
            stability: container.decodeIfPresent(
                SchedulerPlacementStabilitySnapshot.self,
                forKey: .stability
            ) ?? .none
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workloadID, forKey: .workloadID)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(allocation, forKey: .allocation)
        try container.encodeIfPresent(topologyGroupID, forKey: .topologyGroupID)
        try container.encode(stability, forKey: .stability)
    }
}

public struct SchedulerVictimAllocation:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let workloadID: UUID
    public let nodeID: UUID
    public let allocation: ResourceVector
    public let subjectID: String
    public let projectID: String
    public let priority: Int64
    public let disruptionCostBasisPoints: Int64
    public let budgetID: String?
    public let preemptible: Bool
    public let reclaimableBorrowed: Bool
    public let starvationAgeUnits: Int64
    public let topologyGroupID: String?

    public init(
        workloadID: UUID,
        nodeID: UUID,
        allocation: ResourceVector,
        subjectID: String,
        projectID: String,
        priority: Int64,
        disruptionCostBasisPoints: Int64,
        budgetID: String? = nil,
        preemptible: Bool = true,
        reclaimableBorrowed: Bool = false,
        starvationAgeUnits: Int64 = 0,
        topologyGroupID: String? = nil
    ) throws {
        try SchedulerEngineContractValidation.text(subjectID, field: "victim-subject-id")
        try SchedulerEngineContractValidation.text(projectID, field: "victim-project-id")
        guard priority >= -SchedulerEngineLimits.absoluteMaxWeight,
              priority <= SchedulerEngineLimits.absoluteMaxWeight else {
            throw SchedulerEngineValidationError.invalidValue(field: "victim-priority", value: priority)
        }
        guard disruptionCostBasisPoints >= 0,
              disruptionCostBasisPoints <= SchedulerEngineContractValidation.scale else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "victim-disruption-cost",
                value: disruptionCostBasisPoints
            )
        }
        guard !reclaimableBorrowed || preemptible else {
            throw SchedulerEngineValidationError.invalidDecision(
                "borrowed-victim-must-be-preemptible"
            )
        }
        guard starvationAgeUnits >= 0,
              starvationAgeUnits <= SchedulerEngineLimits.absoluteMaxWeight else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "victim-starvation-age",
                value: starvationAgeUnits
            )
        }
        if let budgetID {
            try SchedulerEngineContractValidation.text(budgetID, field: "disruption-budget-id")
        }
        if let topologyGroupID {
            try SchedulerEngineContractValidation.text(
                topologyGroupID,
                field: "victim-topology-group-id"
            )
        }
        self.workloadID = workloadID
        self.nodeID = nodeID
        self.allocation = allocation
        self.subjectID = subjectID
        self.projectID = projectID
        self.priority = priority
        self.disruptionCostBasisPoints = disruptionCostBasisPoints
        self.budgetID = budgetID
        self.preemptible = preemptible
        self.reclaimableBorrowed = reclaimableBorrowed
        self.starvationAgeUnits = starvationAgeUnits
        self.topologyGroupID = topologyGroupID
    }

    private enum CodingKeys: String, CodingKey {
        case workloadID
        case nodeID
        case allocation
        case subjectID
        case projectID
        case priority
        case disruptionCostBasisPoints
        case budgetID
        case preemptible
        case reclaimableBorrowed
        case starvationAgeUnits
        case topologyGroupID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            workloadID: container.decode(UUID.self, forKey: .workloadID),
            nodeID: container.decode(UUID.self, forKey: .nodeID),
            allocation: container.decode(ResourceVector.self, forKey: .allocation),
            subjectID: container.decode(String.self, forKey: .subjectID),
            projectID: container.decode(String.self, forKey: .projectID),
            priority: container.decode(Int64.self, forKey: .priority),
            disruptionCostBasisPoints: container.decode(Int64.self, forKey: .disruptionCostBasisPoints),
            budgetID: container.decodeIfPresent(String.self, forKey: .budgetID),
            preemptible: container.decodeIfPresent(Bool.self, forKey: .preemptible) ?? true,
            reclaimableBorrowed: container.decodeIfPresent(
                Bool.self,
                forKey: .reclaimableBorrowed
            ) ?? false,
            starvationAgeUnits: container.decodeIfPresent(
                Int64.self,
                forKey: .starvationAgeUnits
            ) ?? 0,
            topologyGroupID: container.decodeIfPresent(String.self, forKey: .topologyGroupID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workloadID, forKey: .workloadID)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(allocation, forKey: .allocation)
        try container.encode(subjectID, forKey: .subjectID)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(priority, forKey: .priority)
        try container.encode(disruptionCostBasisPoints, forKey: .disruptionCostBasisPoints)
        try container.encodeIfPresent(budgetID, forKey: .budgetID)
        try container.encode(preemptible, forKey: .preemptible)
        try container.encode(reclaimableBorrowed, forKey: .reclaimableBorrowed)
        try container.encode(starvationAgeUnits, forKey: .starvationAgeUnits)
        try container.encodeIfPresent(topologyGroupID, forKey: .topologyGroupID)
    }
}

public struct SchedulerDisruptionBudget:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let budgetID: String
    public let projectID: String
    public let remainingVictimCount: Int
    public let remainingDisruptionCostBasisPoints: Int64

    public init(
        budgetID: String,
        projectID: String,
        remainingVictimCount: Int,
        remainingDisruptionCostBasisPoints: Int64
    ) throws {
        try SchedulerEngineContractValidation.text(budgetID, field: "disruption-budget-id")
        try SchedulerEngineContractValidation.text(projectID, field: "disruption-budget-project-id")
        guard remainingVictimCount >= 0 else {
            throw SchedulerEngineValidationError.invalidCount(
                field: "remaining-victim-count",
                value: remainingVictimCount
            )
        }
        guard remainingDisruptionCostBasisPoints >= 0 else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "remaining-disruption-cost",
                value: remainingDisruptionCostBasisPoints
            )
        }
        self.budgetID = budgetID
        self.projectID = projectID
        self.remainingVictimCount = remainingVictimCount
        self.remainingDisruptionCostBasisPoints = remainingDisruptionCostBasisPoints
    }

    private enum CodingKeys: String, CodingKey {
        case budgetID
        case projectID
        case remainingVictimCount
        case remainingDisruptionCostBasisPoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            budgetID: container.decode(String.self, forKey: .budgetID),
            projectID: container.decode(String.self, forKey: .projectID),
            remainingVictimCount: container.decode(Int.self, forKey: .remainingVictimCount),
            remainingDisruptionCostBasisPoints: container.decode(
                Int64.self,
                forKey: .remainingDisruptionCostBasisPoints
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(budgetID, forKey: .budgetID)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(remainingVictimCount, forKey: .remainingVictimCount)
        try container.encode(
            remainingDisruptionCostBasisPoints,
            forKey: .remainingDisruptionCostBasisPoints
        )
    }
}

public struct SchedulerPreemptionProposal:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let intentDigest: String
    public let requiresFence: Bool
    public let targetWorkloadID: UUID
    public let projectID: String
    public let nodeID: UUID
    public let victimWorkloadIDs: [UUID]
    public let victims: [SchedulerVictimAllocation]
    public let disruptionCostBasisPoints: Int64
    public let explanation: SchedulerPreemptionExplanation
    public let policy: SchedulerPreemptionPolicy

    public init(
        intentDigest: String,
        targetWorkloadID: UUID,
        projectID: String,
        nodeID: UUID,
        victims: [SchedulerVictimAllocation],
        disruptionCostBasisPoints: Int64,
        explanation: SchedulerPreemptionExplanation,
        requiresFence: Bool = true,
        policy: SchedulerPreemptionPolicy = .standard
    ) throws {
        try SchedulerEngineContractValidation.digest(
            intentDigest,
            limit: SchedulerEngineLimits.absoluteMaxDigestBytes
        )
        try SchedulerEngineContractValidation.text(projectID, field: "preemption-project-id")
        guard requiresFence else {
            throw SchedulerEngineValidationError.invalidDecision("preemption-must-require-fence")
        }
        guard disruptionCostBasisPoints >= 0 else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "preemption-disruption-cost",
                value: disruptionCostBasisPoints
            )
        }
        guard victims.count <= SchedulerEngineLimits.absoluteMaxVictimCount else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: "preemption-victims",
                limit: SchedulerEngineLimits.absoluteMaxVictimCount,
                actual: victims.count
            )
        }
        guard Set(victims.map(\.workloadID)).count == victims.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(field: "preemption-victims")
        }
        let sortedVictims = victims.sorted {
            SchedulerOrdering.uuidKey($0.workloadID) < SchedulerOrdering.uuidKey($1.workloadID)
        }
        self.intentDigest = intentDigest
        self.requiresFence = requiresFence
        self.targetWorkloadID = targetWorkloadID
        self.projectID = projectID
        self.nodeID = nodeID
        self.victimWorkloadIDs = sortedVictims.map(\.workloadID)
        self.victims = sortedVictims
        self.disruptionCostBasisPoints = disruptionCostBasisPoints
        self.explanation = explanation
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case intentDigest
        case requiresFence
        case targetWorkloadID
        case projectID
        case nodeID
        case victimWorkloadIDs
        case victims
        case disruptionCostBasisPoints
        case explanation
        case policy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let victims = try container.decode([SchedulerVictimAllocation].self, forKey: .victims)
        let sortedVictimIDs = victims.sorted {
            SchedulerOrdering.uuidKey($0.workloadID) < SchedulerOrdering.uuidKey($1.workloadID)
        }.map(\.workloadID)
        let encodedVictimIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .victimWorkloadIDs
        ) ?? sortedVictimIDs
        guard encodedVictimIDs == sortedVictimIDs else {
            throw SchedulerEngineValidationError.invalidDecision("preemption-victim-ids")
        }
        try self.init(
            intentDigest: container.decode(String.self, forKey: .intentDigest),
            targetWorkloadID: container.decode(UUID.self, forKey: .targetWorkloadID),
            projectID: container.decode(String.self, forKey: .projectID),
            nodeID: container.decode(UUID.self, forKey: .nodeID),
            victims: victims,
            disruptionCostBasisPoints: container.decode(
                Int64.self,
                forKey: .disruptionCostBasisPoints
            ),
            explanation: container.decode(
                SchedulerPreemptionExplanation.self,
                forKey: .explanation
            ),
            requiresFence: container.decodeIfPresent(Bool.self, forKey: .requiresFence) ?? true,
            policy: container.decodeIfPresent(
                SchedulerPreemptionPolicy.self,
                forKey: .policy
            ) ?? .standard
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intentDigest, forKey: .intentDigest)
        try container.encode(requiresFence, forKey: .requiresFence)
        try container.encode(targetWorkloadID, forKey: .targetWorkloadID)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(victimWorkloadIDs, forKey: .victimWorkloadIDs)
        try container.encode(victims, forKey: .victims)
        try container.encode(disruptionCostBasisPoints, forKey: .disruptionCostBasisPoints)
        try container.encode(explanation, forKey: .explanation)
        try container.encode(policy, forKey: .policy)
    }
}
