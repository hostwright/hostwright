import Foundation

public enum HardPlacementFilterKind:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case capacity
    case architecture
    case runtimeProvider = "runtime-provider"
    case capabilities
    case healthMaintenance = "health-maintenance"
    case labelsAffinity = "labels-affinity"
    case taintsTolerations = "taints-tolerations"
    case acceleratorAvailability = "accelerator-availability"

    fileprivate var orderingIndex: Int {
        switch self {
        case .capacity: 0
        case .architecture: 1
        case .runtimeProvider: 2
        case .capabilities: 3
        case .healthMaintenance: 4
        case .labelsAffinity: 5
        case .taintsTolerations: 6
        case .acceleratorAvailability: 7
        }
    }
}

public enum HardPlacementFilterReasonCode:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
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

    fileprivate var orderingIndex: Int {
        switch self {
        case .insufficientCapacity,
             .architectureMismatch,
             .runtimeMismatch,
             .missingCapability,
             .nodeNotHealthy,
             .requiredLabelMissing,
             .untoleratedTaint,
             .acceleratorUnavailable:
            0
        case .providerMismatch,
             .nodeUnavailableForMaintenance,
             .requiredLabelMismatch:
            1
        case .forbiddenLabelPresent:
            2
        }
    }
}

public struct PlacementFilterReason:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let filter: HardPlacementFilterKind
    public let code: HardPlacementFilterReasonCode
    public let workloadID: UUID
    public let nodeID: UUID
    public let stableDetailKey: String
    public let message: String

    public init(
        filter: HardPlacementFilterKind,
        code: HardPlacementFilterReasonCode,
        workloadID: UUID,
        nodeID: UUID,
        stableDetailKey: String,
        message: String
    ) {
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
            String(format: "%02d", filter.orderingIndex),
            String(format: "%02d", code.orderingIndex),
            code.rawValue,
            stableDetailKey,
            message
        ].joined(separator: "|")
    }
}

public struct PlacementFilterResult:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let workloadID: UUID
    public let nodeID: UUID
    public let reasons: [PlacementFilterReason]

    public init(
        workloadID: UUID,
        nodeID: UUID,
        reasons: [PlacementFilterReason]
    ) {
        self.workloadID = workloadID
        self.nodeID = nodeID
        self.reasons = reasons.sorted { $0.orderingKey < $1.orderingKey }
    }

    public var passed: Bool {
        reasons.isEmpty
    }

    public var orderingKey: String {
        [
            SchedulerOrdering.uuidKey(workloadID),
            SchedulerOrdering.uuidKey(nodeID)
        ].joined(separator: "|")
    }
}

public struct HardTopologySpreadObservation:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let workloadID: UUID
    public let nodeID: UUID
    public let groupID: String?

    public init(
        workloadID: UUID,
        nodeID: UUID,
        groupID: String? = nil
    ) throws {
        if let groupID {
            try SchedulerEngineContractValidation.text(
                groupID,
                field: "topology-observation-group-id"
            )
        }
        self.workloadID = workloadID
        self.nodeID = nodeID
        self.groupID = groupID
    }

    private enum CodingKeys: String, CodingKey {
        case workloadID
        case nodeID
        case groupID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            workloadID: container.decode(UUID.self, forKey: .workloadID),
            nodeID: container.decode(UUID.self, forKey: .nodeID),
            groupID: container.decodeIfPresent(String.self, forKey: .groupID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workloadID, forKey: .workloadID)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encodeIfPresent(groupID, forKey: .groupID)
    }
}

public struct HardTopologySpreadContext:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let nodeTopologyDomains: [UUID: [String: String]]
    public let observations: [HardTopologySpreadObservation]

    public init(
        nodeTopologyDomains: [UUID: [String: String]],
        observations: [HardTopologySpreadObservation] = []
    ) throws {
        try SchedulerEngineContractValidation.count(
            nodeTopologyDomains.count,
            field: "topology-context-nodes",
            limit: SchedulerEngineLimits.absoluteMaxNodeCount
        )
        try SchedulerEngineContractValidation.count(
            observations.count,
            field: "topology-context-observations",
            limit: SchedulerEngineLimits.absoluteMaxWorkloadCount
        )
        var entryCount = 0
        for nodeID in nodeTopologyDomains.keys.sorted(by: SchedulerOrdering.uuidPrecedes) {
            let domains = nodeTopologyDomains[nodeID] ?? [:]
            entryCount += domains.count
            try SchedulerEngineContractValidation.labels(
                domains,
                field: "topology-context-domain"
            )
        }
        try SchedulerEngineContractValidation.count(
            entryCount,
            field: "topology-context-entries",
            limit: SchedulerEngineLimits.absoluteMaxTopologyEntryCount
        )
        guard Set(observations.map(\.workloadID)).count == observations.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(
                field: "topology-context-observations"
            )
        }
        let nodeIDs = Set(nodeTopologyDomains.keys)
        for observation in observations {
            guard nodeIDs.contains(observation.nodeID) else {
                throw SchedulerEngineValidationError.unknownReference(
                    field: "topology-context-observation-node",
                    id: observation.nodeID
                )
            }
        }
        self.nodeTopologyDomains = nodeTopologyDomains.keys.sorted(by: SchedulerOrdering.uuidPrecedes)
            .reduce(into: [:]) { result, nodeID in
                result[nodeID] = nodeTopologyDomains[nodeID]!.keys.sorted().reduce(into: [:]) {
                    $0[$1] = nodeTopologyDomains[nodeID]![$1]
                }
            }
        self.observations = observations.sorted {
            SchedulerOrdering.uuidPrecedes($0.workloadID, $1.workloadID)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case nodeTopologyDomains
        case observations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var domainsContainer = try container.nestedUnkeyedContainer(
            forKey: .nodeTopologyDomains
        )
        var nodeTopologyDomains: [UUID: [String: String]] = [:]
        while !domainsContainer.isAtEnd {
            let nodeID = try domainsContainer.decode(UUID.self)
            let domains = try domainsContainer.decode([String: String].self)
            guard nodeTopologyDomains[nodeID] == nil else {
                throw SchedulerEngineValidationError.duplicateIdentifier(
                    field: "topology-context-nodes"
                )
            }
            nodeTopologyDomains[nodeID] = domains
        }
        try self.init(
            nodeTopologyDomains: nodeTopologyDomains,
            observations: container.decode(
                [HardTopologySpreadObservation].self,
                forKey: .observations
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var domainsContainer = container.nestedUnkeyedContainer(forKey: .nodeTopologyDomains)
        for nodeID in nodeTopologyDomains.keys.sorted(by: SchedulerOrdering.uuidPrecedes) {
            try domainsContainer.encode(nodeID)
            try domainsContainer.encode(nodeTopologyDomains[nodeID] ?? [:])
        }
        try container.encode(observations, forKey: .observations)
    }
}

public struct HardPlacementFilterEvaluator: Sendable {
    public init() {}

    public func evaluate(
        workload: WorkloadPlacementRequirements,
        on node: NodePlacementSnapshot
    ) -> PlacementFilterResult {
        evaluate(workload: workload, on: node, topologyContext: nil)
    }

    public func evaluate(
        workload: WorkloadPlacementRequirements,
        on node: NodePlacementSnapshot,
        topologyContext: HardTopologySpreadContext?
    ) -> PlacementFilterResult {
        let reasons = capacityReasons(workload: workload, node: node)
            + architectureReasons(workload: workload, node: node)
            + runtimeProviderReasons(workload: workload, node: node)
            + capabilityReasons(workload: workload, node: node)
            + healthMaintenanceReasons(workload: workload, node: node)
            + labelAffinityReasons(workload: workload, node: node)
            + taintTolerationReasons(workload: workload, node: node)
            + acceleratorReasons(workload: workload, node: node)
            + topologySpreadReasons(
                workload: workload,
                node: node,
                context: topologyContext
            )

        return PlacementFilterResult(
            workloadID: workload.workloadID,
            nodeID: node.nodeID,
            reasons: reasons
        )
    }

    public func evaluate(
        workload: WorkloadPlacementRequirements,
        against nodes: [NodePlacementSnapshot]
    ) -> [PlacementFilterResult] {
        nodes
            .map { evaluate(workload: workload, on: $0) }
            .sorted { $0.orderingKey < $1.orderingKey }
    }

    private func capacityReasons(
        workload: WorkloadPlacementRequirements,
        node: NodePlacementSnapshot
    ) -> [PlacementFilterReason] {
        workload.request.resourceNames.compactMap { resource in
            let requested = workload.request[resource]
            let available = node.available[resource]
            guard requested > available else {
                return nil
            }
            return reason(
                filter: .capacity,
                code: .insufficientCapacity,
                workload: workload,
                node: node,
                detail: "resource:\(resource):requested:\(requested):available:\(available)",
                message: "Resource \(resource) requests \(requested), but node has \(available) available."
            )
        }
    }

    private func architectureReasons(
        workload: WorkloadPlacementRequirements,
        node: NodePlacementSnapshot
    ) -> [PlacementFilterReason] {
        guard !workload.requiredArchitectures.isEmpty,
              !workload.requiredArchitectures.contains(node.architecture) else {
            return []
        }
        let required = workload.requiredArchitectures.joined(separator: ",")
        return [
            reason(
                filter: .architecture,
                code: .architectureMismatch,
                workload: workload,
                node: node,
                detail: "required:\(required):actual:\(node.architecture)",
                message: "Node architecture \(node.architecture) does not match required architectures \(required)."
            )
        ]
    }

    private func runtimeProviderReasons(
        workload: WorkloadPlacementRequirements,
        node: NodePlacementSnapshot
    ) -> [PlacementFilterReason] {
        var reasons: [PlacementFilterReason] = []
        if let requiredRuntime = workload.requiredRuntime,
           requiredRuntime != node.runtime {
            reasons.append(
                reason(
                    filter: .runtimeProvider,
                    code: .runtimeMismatch,
                    workload: workload,
                    node: node,
                    detail: "runtime:required:\(requiredRuntime):actual:\(node.runtime)",
                    message: "Node runtime \(node.runtime) does not match required runtime \(requiredRuntime)."
                )
            )
        }
        if let requiredProvider = workload.requiredProvider,
           requiredProvider != node.provider {
            reasons.append(
                reason(
                    filter: .runtimeProvider,
                    code: .providerMismatch,
                    workload: workload,
                    node: node,
                    detail: "provider:required:\(requiredProvider):actual:\(node.provider)",
                    message: "Node provider \(node.provider) does not match required provider \(requiredProvider)."
                )
            )
        }
        return reasons
    }

    private func capabilityReasons(
        workload: WorkloadPlacementRequirements,
        node: NodePlacementSnapshot
    ) -> [PlacementFilterReason] {
        let available = Set(node.capabilities)
        return workload.requiredCapabilities.compactMap { capability in
            guard !available.contains(capability) else {
                return nil
            }
            return reason(
                filter: .capabilities,
                code: .missingCapability,
                workload: workload,
                node: node,
                detail: "capability:\(capability)",
                message: "Node is missing required capability \(capability)."
            )
        }
    }

    private func healthMaintenanceReasons(
        workload: WorkloadPlacementRequirements,
        node: NodePlacementSnapshot
    ) -> [PlacementFilterReason] {
        var reasons: [PlacementFilterReason] = []
        if node.health != .healthy {
            reasons.append(
                reason(
                    filter: .healthMaintenance,
                    code: .nodeNotHealthy,
                    workload: workload,
                    node: node,
                    detail: "health:\(node.health.rawValue)",
                    message: "Node health is \(node.health.rawValue), not healthy."
                )
            )
        }
        if node.maintenance != .available {
            reasons.append(
                reason(
                    filter: .healthMaintenance,
                    code: .nodeUnavailableForMaintenance,
                    workload: workload,
                    node: node,
                    detail: "maintenance:\(node.maintenance.rawValue)",
                    message: "Node is unavailable for placement while " + node.maintenance.rawValue + "."
                )
            )
        }
        return reasons
    }

    private func labelAffinityReasons(
        workload: WorkloadPlacementRequirements,
        node: NodePlacementSnapshot
    ) -> [PlacementFilterReason] {
        var reasons: [PlacementFilterReason] = []
        for key in workload.affinity.requiredLabels.keys.sorted() {
            let required = workload.affinity.requiredLabels[key]!
            guard let actual = node.labels[key] else {
                reasons.append(
                    reason(
                        filter: .labelsAffinity,
                        code: .requiredLabelMissing,
                        workload: workload,
                        node: node,
                        detail: "required:\(key)=\(required):missing",
                        message: "Node is missing required label \(key)=\(required)."
                    )
                )
                continue
            }
            if actual != required {
                reasons.append(
                    reason(
                        filter: .labelsAffinity,
                        code: .requiredLabelMismatch,
                        workload: workload,
                        node: node,
                        detail: "required:\(key)=\(required):actual:\(actual)",
                        message: "Node label \(key)=\(actual) does not match required value \(required)."
                    )
                )
            }
        }
        for key in workload.affinity.forbiddenLabels.keys.sorted() {
            let forbidden = workload.affinity.forbiddenLabels[key]!
            guard node.labels[key] == forbidden else {
                continue
            }
            reasons.append(
                reason(
                    filter: .labelsAffinity,
                    code: .forbiddenLabelPresent,
                    workload: workload,
                    node: node,
                    detail: "forbidden:\(key)=\(forbidden)",
                    message: "Node has forbidden label \(key)=\(forbidden)."
                )
            )
        }
        for selector in workload.affinity.requiredSelectors {
            guard !selector.matches(node.labels) else {
                continue
            }
            let actual = node.labels[selector.key] ?? "<missing>"
            let code: HardPlacementFilterReasonCode =
                (selector.`operator` == .in || selector.`operator` == .exists)
                    && actual == "<missing>"
                    ? .requiredLabelMissing
                    : .requiredLabelMismatch
            reasons.append(
                reason(
                    filter: .labelsAffinity,
                    code: code,
                    workload: workload,
                    node: node,
                    detail: "required-selector:\(selector.orderingKey):actual:\(actual)",
                    message: "Node labels do not satisfy required \(selector.`operator`.rawValue) selector \(selector.key)."
                )
            )
        }
        for selector in workload.affinity.forbiddenSelectors {
            guard selector.matches(node.labels) else {
                continue
            }
            let actual = node.labels[selector.key] ?? "<missing>"
            reasons.append(
                reason(
                    filter: .labelsAffinity,
                    code: .forbiddenLabelPresent,
                    workload: workload,
                    node: node,
                    detail: "forbidden-selector:\(selector.orderingKey):actual:\(actual)",
                    message: "Node labels satisfy forbidden \(selector.`operator`.rawValue) selector \(selector.key)."
                )
            )
        }
        return reasons
    }

    private func topologySpreadReasons(
        workload: WorkloadPlacementRequirements,
        node: NodePlacementSnapshot,
        context: HardTopologySpreadContext?
    ) -> [PlacementFilterReason] {
        guard let context else {
            return workload.affinity.topologySpreads
                .filter { $0.whenUnsatisfiable == .doNotSchedule }
                .map { spread in
                    reason(
                        filter: .labelsAffinity,
                        code: .requiredLabelMissing,
                        workload: workload,
                        node: node,
                        detail: "topology-spread:\(spread.topologyKey):context-unavailable",
                        message: "Hard topology spread \(spread.topologyKey) cannot be evaluated without a topology snapshot."
                    )
                }
        }
        var reasons: [PlacementFilterReason] = []
        for spread in workload.affinity.topologySpreads
            where spread.whenUnsatisfiable == .doNotSchedule {
            guard let candidateDomain = context.nodeTopologyDomains[node.nodeID]?[spread.topologyKey] else {
                reasons.append(
                    reason(
                        filter: .labelsAffinity,
                        code: .requiredLabelMissing,
                        workload: workload,
                        node: node,
                        detail: "topology-spread:\(spread.topologyKey):missing-domain",
                        message: "Node has no domain for required hard topology key \(spread.topologyKey)."
                    )
                )
                continue
            }

            var counts: [String: Int64] = [:]
            for domains in context.nodeTopologyDomains.values {
                if let value = domains[spread.topologyKey] {
                    counts[value] = 0
                }
            }
            for observation in context.observations {
                guard spread.groupID == nil || observation.groupID == spread.groupID,
                      let value = context.nodeTopologyDomains[observation.nodeID]?[spread.topologyKey] else {
                    continue
                }
                counts[value, default: 0] += 1
            }
            counts[candidateDomain, default: 0] += 1
            let minimum = counts.values.min() ?? 0
            let maximum = counts.values.max() ?? 0
            let skew = maximum - minimum
            if skew > Int64(spread.maxSkew) {
                let countDetail = counts.keys.sorted().map {
                    "\($0)=\(counts[$0]!)"
                }.joined(separator: ",")
                reasons.append(
                    reason(
                        filter: .labelsAffinity,
                        code: .requiredLabelMismatch,
                        workload: workload,
                        node: node,
                        detail: "topology-spread:\(spread.topologyKey):max-skew:\(spread.maxSkew):candidate:\(candidateDomain):counts:\(countDetail)",
                        message: "Node would violate hard topology spread \(spread.topologyKey) maxSkew \(spread.maxSkew)."
                    )
                )
            }
        }
        return reasons
    }

    private func taintTolerationReasons(
        workload: WorkloadPlacementRequirements,
        node: NodePlacementSnapshot
    ) -> [PlacementFilterReason] {
        node.taints.compactMap { taint in
            guard !workload.tolerations.contains(where: { $0.tolerates(taint) }) else {
                return nil
            }
            let detail = [
                "key:\(taint.key)",
                "value:\(taint.value ?? "")",
                "effect:\(taint.effect.rawValue)"
            ].joined(separator: ":")
            return reason(
                filter: .taintsTolerations,
                code: .untoleratedTaint,
                workload: workload,
                node: node,
                detail: detail,
                message: "Node taint \(taint.key)=\(taint.value ?? "") with effect \(taint.effect.rawValue) is not tolerated."
            )
        }
    }

    private func acceleratorReasons(
        workload: WorkloadPlacementRequirements,
        node: NodePlacementSnapshot
    ) -> [PlacementFilterReason] {
        workload.acceleratorRequirements.resourceNames.compactMap { resource in
            let required = workload.acceleratorRequirements[resource]
            let available = node.acceleratorAvailability[resource]
            guard required > available else {
                return nil
            }
            return reason(
                filter: .acceleratorAvailability,
                code: .acceleratorUnavailable,
                workload: workload,
                node: node,
                detail: "resource:\(resource):required:\(required):available:\(available)",
                message: "Accelerator resource \(resource) requires \(required), but node has \(available) available."
            )
        }
    }

    private func reason(
        filter: HardPlacementFilterKind,
        code: HardPlacementFilterReasonCode,
        workload: WorkloadPlacementRequirements,
        node: NodePlacementSnapshot,
        detail: String,
        message: String
    ) -> PlacementFilterReason {
        PlacementFilterReason(
            filter: filter,
            code: code,
            workloadID: workload.workloadID,
            nodeID: node.nodeID,
            stableDetailKey: detail,
            message: message
        )
    }
}
