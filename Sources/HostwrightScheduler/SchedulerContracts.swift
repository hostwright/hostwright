import Foundation

public struct WorkloadResourceSnapshot:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let request: ResourceVector
    public let limit: ResourceVector?

    public init(
        request: ResourceVector,
        limit: ResourceVector? = nil
    ) throws {
        if let limit {
            for resource in request.resourceNames where request[resource] > limit[resource] {
                throw SchedulerValidationError.limitBelowRequest(resource: resource)
            }
        }
        self.request = request
        self.limit = limit
    }

    public var requestedResources: ResourceVector {
        request
    }

    private enum CodingKeys: String, CodingKey {
        case request
        case limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            request: container.decode(ResourceVector.self, forKey: .request),
            limit: container.decodeIfPresent(ResourceVector.self, forKey: .limit)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request, forKey: .request)
        try container.encodeIfPresent(limit, forKey: .limit)
    }
}

public enum SchedulerNodeHealth: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case healthy
    case degraded
    case unhealthy
    case unknown
}

public enum SchedulerNodeMaintenance:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case available
    case draining
    case maintenance
    case cordoned
}

public struct NodeResourceSnapshot:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let nodeID: UUID
    public let capacity: ResourceVector
    public let allocation: ResourceVector
    public let available: ResourceVector

    public init(
        nodeID: UUID,
        capacity: ResourceVector,
        allocation: ResourceVector
    ) throws {
        guard allocation.fits(in: capacity) else {
            let resource = allocation.resourceNames.first {
                allocation[$0] > capacity[$0]
            } ?? allocation.resourceNames.first ?? "unknown"
            throw SchedulerValidationError.allocationExceedsCapacity(resource: resource)
        }

        self.nodeID = nodeID
        self.capacity = capacity
        self.allocation = allocation
        self.available = try capacity.subtracting(allocation)
    }

    private enum CodingKeys: String, CodingKey {
        case nodeID
        case capacity
        case allocation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nodeID: container.decode(UUID.self, forKey: .nodeID),
            capacity: container.decode(ResourceVector.self, forKey: .capacity),
            allocation: container.decode(ResourceVector.self, forKey: .allocation)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(capacity, forKey: .capacity)
        try container.encode(allocation, forKey: .allocation)
    }
}

public struct NodeTaint:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let key: String
    public let value: String?
    public let effect: TaintEffect

    public init(
        key: String,
        value: String? = nil,
        effect: TaintEffect
    ) throws {
        self.key = try SchedulerCanonicalization.identifier(key, field: "taint-key")
        self.value = try SchedulerCanonicalization.optionalText(value, field: "taint-value")
        self.effect = effect
    }

    public var orderingKey: String {
        [key, value ?? "", effect.rawValue].joined(separator: "|")
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case value
        case effect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                key: container.decode(String.self, forKey: .key),
                value: container.decodeIfPresent(String.self, forKey: .value),
                effect: container.decode(TaintEffect.self, forKey: .effect)
            )
        } catch let error as SchedulerValidationError {
            throw error
        } catch {
            throw SchedulerValidationError.invalidTaint("malformed")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encode(effect, forKey: .effect)
    }
}

public enum TaintEffect: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case noSchedule = "no-schedule"
    case noExecute = "no-execute"
}

public enum TolerationOperator: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case equals
    case exists
}

public struct PlacementToleration:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let key: String?
    public let value: String?
    public let effect: TaintEffect?
    public let matching: TolerationOperator

    public init(
        key: String? = nil,
        value: String? = nil,
        effect: TaintEffect? = nil,
        matching: TolerationOperator
    ) throws {
        self.key = try SchedulerCanonicalization.optionalIdentifier(
            key,
            field: "toleration-key"
        )
        self.value = try SchedulerCanonicalization.optionalText(
            value,
            field: "toleration-value"
        )
        self.effect = effect
        self.matching = matching

        switch matching {
        case .equals:
            guard self.key != nil, self.value != nil else {
                throw SchedulerValidationError.invalidToleration(
                    "equals-requires-key-and-value"
                )
            }
        case .exists:
            guard self.value == nil else {
                throw SchedulerValidationError.invalidToleration(
                    "exists-requires-no-value"
                )
            }
        }
    }

    public var orderingKey: String {
        [key ?? "", value ?? "", effect?.rawValue ?? "", matching.rawValue]
            .joined(separator: "|")
    }

    public func tolerates(_ taint: NodeTaint) -> Bool {
        guard effect == nil || effect == taint.effect else {
            return false
        }

        switch matching {
        case .equals:
            return key == taint.key && value == taint.value
        case .exists:
            return key == nil || key == taint.key
        }
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case value
        case effect
        case matching
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                key: container.decodeIfPresent(String.self, forKey: .key),
                value: container.decodeIfPresent(String.self, forKey: .value),
                effect: container.decodeIfPresent(TaintEffect.self, forKey: .effect),
                matching: container.decode(TolerationOperator.self, forKey: .matching)
            )
        } catch let error as SchedulerValidationError {
            throw error
        } catch {
            throw SchedulerValidationError.invalidToleration("malformed")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(effect, forKey: .effect)
        try container.encode(matching, forKey: .matching)
    }
}

public enum SchedulerLabelSelectorOperator:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case equals
    case notEquals = "not-equals"
    case `in`
    case notIn = "not-in"
    case exists
    case doesNotExist = "does-not-exist"
}

public struct SchedulerLabelSelector:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let maximumCount = 64
    public static let maximumValueCount = 64

    public let key: String
    public let `operator`: SchedulerLabelSelectorOperator
    public let values: [String]

    public init(
        key: String,
        operator: SchedulerLabelSelectorOperator,
        values: [String] = []
    ) throws {
        try SchedulerEngineContractValidation.text(key, field: "selector-key")
        guard values.count <= Self.maximumValueCount else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: "selector-values",
                limit: Self.maximumValueCount,
                actual: values.count
            )
        }
        guard Set(values).count == values.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(field: "selector-values")
        }
        for value in values {
            try SchedulerEngineContractValidation.text(value, field: "selector-value")
        }
        switch `operator` {
        case .equals, .notEquals:
            guard values.count == 1 else {
                throw SchedulerEngineValidationError.invalidValue(
                    field: "selector-values",
                    value: Int64(values.count)
                )
            }
        case .in, .notIn:
            guard !values.isEmpty else {
                throw SchedulerEngineValidationError.invalidValue(
                    field: "selector-values",
                    value: 0
                )
            }
        case .exists, .doesNotExist:
            guard values.isEmpty else {
                throw SchedulerEngineValidationError.invalidValue(
                    field: "selector-values",
                    value: Int64(values.count)
                )
            }
        }
        self.key = key
        self.operator = `operator`
        self.values = values.sorted()
    }

    public var orderingKey: String {
        SchedulerOrdering.stableKey(
            [key, `operator`.rawValue] + (values.isEmpty ? [""] : values)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case `operator`
        case values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            key: container.decode(String.self, forKey: .key),
            operator: container.decode(
                SchedulerLabelSelectorOperator.self,
                forKey: .`operator`
            ),
            values: container.decode([String].self, forKey: .values)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(`operator`, forKey: .`operator`)
        try container.encode(values, forKey: .values)
    }

    /// `not-in` requires the label key to exist; an absent key does not match.
    public func matches(_ labels: [String: String]) -> Bool {
        switch `operator` {
        case .equals:
            guard let actual = labels[key] else {
                return false
            }
            return actual == values[0]
        case .notEquals:
            guard let actual = labels[key] else {
                return false
            }
            return actual != values[0]
        case .in:
            guard let actual = labels[key] else {
                return false
            }
            return values.contains(actual)
        case .notIn:
            guard let actual = labels[key] else {
                return false
            }
            return !values.contains(actual)
        case .exists:
            return labels[key] != nil
        case .doesNotExist:
            return labels[key] == nil
        }
    }
}

public enum SchedulerTopologyUnsatisfiablePolicy:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case doNotSchedule = "do-not-schedule"
    case scheduleAnyway = "schedule-anyway"
}

public struct SchedulerHardTopologySpread:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let maximumCount = 16

    public let topologyKey: String
    public let maxSkew: Int
    public let whenUnsatisfiable: SchedulerTopologyUnsatisfiablePolicy
    public let groupID: String?

    public init(
        topologyKey: String,
        maxSkew: Int = 1,
        whenUnsatisfiable: SchedulerTopologyUnsatisfiablePolicy = .doNotSchedule,
        groupID: String? = nil
    ) throws {
        try SchedulerEngineContractValidation.text(
            topologyKey,
            field: "topology-spread-key"
        )
        guard (1...100).contains(maxSkew) else {
            throw SchedulerEngineValidationError.invalidCount(
                field: "topology-spread-max-skew",
                value: maxSkew
            )
        }
        if let groupID {
            try SchedulerEngineContractValidation.text(
                groupID,
                field: "topology-spread-group-id"
            )
        }
        self.topologyKey = topologyKey
        self.maxSkew = maxSkew
        self.whenUnsatisfiable = whenUnsatisfiable
        self.groupID = groupID
    }

    public var orderingKey: String {
        SchedulerOrdering.stableKey([
            topologyKey,
            String(format: "%03d", maxSkew),
            whenUnsatisfiable.rawValue,
            groupID ?? ""
        ])
    }

    private enum CodingKeys: String, CodingKey {
        case topologyKey
        case maxSkew
        case whenUnsatisfiable
        case groupID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            topologyKey: container.decode(String.self, forKey: .topologyKey),
            maxSkew: container.decode(Int.self, forKey: .maxSkew),
            whenUnsatisfiable: container.decode(
                SchedulerTopologyUnsatisfiablePolicy.self,
                forKey: .whenUnsatisfiable
            ),
            groupID: container.decodeIfPresent(String.self, forKey: .groupID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(topologyKey, forKey: .topologyKey)
        try container.encode(maxSkew, forKey: .maxSkew)
        try container.encode(whenUnsatisfiable, forKey: .whenUnsatisfiable)
        try container.encodeIfPresent(groupID, forKey: .groupID)
    }
}

public struct NodeAffinity:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let none = NodeAffinity(
        uncheckedRequiredLabels: [:],
        uncheckedForbiddenLabels: [:],
        uncheckedRequiredSelectors: [],
        uncheckedForbiddenSelectors: [],
        uncheckedTopologySpreads: []
    )

    public let requiredLabels: [String: String]
    public let forbiddenLabels: [String: String]
    public let requiredSelectors: [SchedulerLabelSelector]
    public let forbiddenSelectors: [SchedulerLabelSelector]
    public let topologySpreads: [SchedulerHardTopologySpread]

    public init(
        requiredLabels: [String: String] = [:],
        forbiddenLabels: [String: String] = [:],
        requiredSelectors: [SchedulerLabelSelector] = [],
        forbiddenSelectors: [SchedulerLabelSelector] = [],
        topologySpreads: [SchedulerHardTopologySpread] = []
    ) throws {
        let canonicalRequired = try SchedulerCanonicalization.labels(
            requiredLabels,
            field: "required-labels"
        )
        let canonicalForbidden = try SchedulerCanonicalization.labels(
            forbiddenLabels,
            field: "forbidden-labels"
        )
        let conflicts = Set(canonicalRequired.keys)
            .intersection(canonicalForbidden.keys)
            .filter { canonicalRequired[$0] == canonicalForbidden[$0] }
            .sorted()
        guard conflicts.isEmpty else {
            throw SchedulerValidationError.invalidAffinity(
                "conflicting-label:" + conflicts[0]
            )
        }
        guard requiredSelectors.count <= SchedulerLabelSelector.maximumCount,
              forbiddenSelectors.count <= SchedulerLabelSelector.maximumCount else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: "affinity-selectors",
                limit: SchedulerLabelSelector.maximumCount,
                actual: max(requiredSelectors.count, forbiddenSelectors.count)
            )
        }
        guard topologySpreads.count <= SchedulerHardTopologySpread.maximumCount else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: "topology-spreads",
                limit: SchedulerHardTopologySpread.maximumCount,
                actual: topologySpreads.count
            )
        }
        guard Set(requiredSelectors.map(\.orderingKey)).count == requiredSelectors.count,
              Set(forbiddenSelectors.map(\.orderingKey)).count == forbiddenSelectors.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(field: "affinity-selectors")
        }
        guard Set(topologySpreads.map(\.orderingKey)).count == topologySpreads.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(field: "topology-spreads")
        }
        for selector in requiredSelectors {
            guard selector.`operator` == .in,
                  let exact = canonicalRequired[selector.key],
                  !selector.values.contains(exact) else {
                continue
            }
            throw SchedulerValidationError.invalidAffinity(
                "conflicting-selector:" + selector.key
            )
        }
        self.requiredLabels = canonicalRequired
        self.forbiddenLabels = canonicalForbidden
        self.requiredSelectors = requiredSelectors.sorted { $0.orderingKey < $1.orderingKey }
        self.forbiddenSelectors = forbiddenSelectors.sorted { $0.orderingKey < $1.orderingKey }
        self.topologySpreads = topologySpreads.sorted { $0.orderingKey < $1.orderingKey }
    }

    private init(
        uncheckedRequiredLabels: [String: String],
        uncheckedForbiddenLabels: [String: String],
        uncheckedRequiredSelectors: [SchedulerLabelSelector],
        uncheckedForbiddenSelectors: [SchedulerLabelSelector],
        uncheckedTopologySpreads: [SchedulerHardTopologySpread]
    ) {
        self.requiredLabels = uncheckedRequiredLabels
        self.forbiddenLabels = uncheckedForbiddenLabels
        self.requiredSelectors = uncheckedRequiredSelectors
        self.forbiddenSelectors = uncheckedForbiddenSelectors
        self.topologySpreads = uncheckedTopologySpreads
    }

    private enum CodingKeys: String, CodingKey {
        case requiredLabels
        case forbiddenLabels
        case requiredSelectors
        case forbiddenSelectors
        case topologySpreads
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requiredLabels: container.decodeIfPresent(
                [String: String].self,
                forKey: .requiredLabels
            ) ?? [:],
            forbiddenLabels: container.decodeIfPresent(
                [String: String].self,
                forKey: .forbiddenLabels
            ) ?? [:],
            requiredSelectors: container.decodeIfPresent(
                [SchedulerLabelSelector].self,
                forKey: .requiredSelectors
            ) ?? [],
            forbiddenSelectors: container.decodeIfPresent(
                [SchedulerLabelSelector].self,
                forKey: .forbiddenSelectors
            ) ?? [],
            topologySpreads: container.decodeIfPresent(
                [SchedulerHardTopologySpread].self,
                forKey: .topologySpreads
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requiredLabels, forKey: .requiredLabels)
        try container.encode(forbiddenLabels, forKey: .forbiddenLabels)
        try container.encode(requiredSelectors, forKey: .requiredSelectors)
        try container.encode(forbiddenSelectors, forKey: .forbiddenSelectors)
        try container.encode(topologySpreads, forKey: .topologySpreads)
    }
}

public struct WorkloadPlacementRequirements:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let workloadID: UUID
    public let resources: WorkloadResourceSnapshot
    public let requiredArchitectures: [String]
    public let requiredRuntime: String?
    public let requiredProvider: String?
    public let requiredCapabilities: [String]
    public let affinity: NodeAffinity
    public let tolerations: [PlacementToleration]
    public let acceleratorRequirements: ResourceVector

    public init(
        workloadID: UUID,
        resources: WorkloadResourceSnapshot,
        requiredArchitectures: [String] = [],
        requiredRuntime: String? = nil,
        requiredProvider: String? = nil,
        requiredCapabilities: [String] = [],
        affinity: NodeAffinity = .none,
        tolerations: [PlacementToleration] = [],
        acceleratorRequirements: ResourceVector = .zero
    ) throws {
        self.workloadID = workloadID
        self.resources = resources
        self.requiredArchitectures = try SchedulerCanonicalization.stringList(
            requiredArchitectures,
            field: "required-architectures"
        )
        self.requiredRuntime = try SchedulerCanonicalization.optionalIdentifier(
            requiredRuntime,
            field: "required-runtime"
        )
        self.requiredProvider = try SchedulerCanonicalization.optionalIdentifier(
            requiredProvider,
            field: "required-provider"
        )
        self.requiredCapabilities = try SchedulerCanonicalization.stringList(
            requiredCapabilities,
            field: "required-capabilities"
        )
        self.affinity = affinity
        self.tolerations = Array(Set(tolerations)).sorted {
            $0.orderingKey < $1.orderingKey
        }
        self.acceleratorRequirements = acceleratorRequirements
    }

    public init(
        workloadID: UUID,
        request: ResourceVector,
        limit: ResourceVector? = nil,
        requiredArchitectures: [String] = [],
        requiredRuntime: String? = nil,
        requiredProvider: String? = nil,
        requiredCapabilities: [String] = [],
        affinity: NodeAffinity = .none,
        tolerations: [PlacementToleration] = [],
        acceleratorRequirements: ResourceVector = .zero
    ) throws {
        try self.init(
            workloadID: workloadID,
            resources: WorkloadResourceSnapshot(request: request, limit: limit),
            requiredArchitectures: requiredArchitectures,
            requiredRuntime: requiredRuntime,
            requiredProvider: requiredProvider,
            requiredCapabilities: requiredCapabilities,
            affinity: affinity,
            tolerations: tolerations,
            acceleratorRequirements: acceleratorRequirements
        )
    }

    public var request: ResourceVector {
        resources.request
    }

    public var limit: ResourceVector? {
        resources.limit
    }

    private enum CodingKeys: String, CodingKey {
        case workloadID
        case resources
        case requiredArchitectures
        case requiredRuntime
        case requiredProvider
        case requiredCapabilities
        case affinity
        case tolerations
        case acceleratorRequirements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            workloadID: container.decode(UUID.self, forKey: .workloadID),
            resources: container.decode(WorkloadResourceSnapshot.self, forKey: .resources),
            requiredArchitectures: container.decodeIfPresent(
                [String].self,
                forKey: .requiredArchitectures
            ) ?? [],
            requiredRuntime: container.decodeIfPresent(
                String.self,
                forKey: .requiredRuntime
            ),
            requiredProvider: container.decodeIfPresent(
                String.self,
                forKey: .requiredProvider
            ),
            requiredCapabilities: container.decodeIfPresent(
                [String].self,
                forKey: .requiredCapabilities
            ) ?? [],
            affinity: container.decodeIfPresent(NodeAffinity.self, forKey: .affinity)
                ?? .none,
            tolerations: container.decodeIfPresent(
                [PlacementToleration].self,
                forKey: .tolerations
            ) ?? [],
            acceleratorRequirements: container.decodeIfPresent(
                ResourceVector.self,
                forKey: .acceleratorRequirements
            ) ?? .zero
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workloadID, forKey: .workloadID)
        try container.encode(resources, forKey: .resources)
        try container.encode(requiredArchitectures, forKey: .requiredArchitectures)
        try container.encodeIfPresent(requiredRuntime, forKey: .requiredRuntime)
        try container.encodeIfPresent(requiredProvider, forKey: .requiredProvider)
        try container.encode(requiredCapabilities, forKey: .requiredCapabilities)
        try container.encode(affinity, forKey: .affinity)
        try container.encode(tolerations, forKey: .tolerations)
        try container.encode(acceleratorRequirements, forKey: .acceleratorRequirements)
    }
}

public struct NodePlacementSnapshot:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let resources: NodeResourceSnapshot
    public let architecture: String
    public let runtime: String
    public let provider: String
    public let capabilities: [String]
    public let health: SchedulerNodeHealth
    public let maintenance: SchedulerNodeMaintenance
    public let labels: [String: String]
    public let taints: [NodeTaint]
    public let acceleratorAvailability: ResourceVector

    public init(
        resources: NodeResourceSnapshot,
        architecture: String,
        runtime: String,
        provider: String,
        capabilities: [String] = [],
        health: SchedulerNodeHealth = .healthy,
        maintenance: SchedulerNodeMaintenance = .available,
        labels: [String: String] = [:],
        taints: [NodeTaint] = [],
        acceleratorAvailability: ResourceVector = .zero
    ) throws {
        self.resources = resources
        self.architecture = try SchedulerCanonicalization.identifier(
            architecture,
            field: "architecture"
        )
        self.runtime = try SchedulerCanonicalization.identifier(runtime, field: "runtime")
        self.provider = try SchedulerCanonicalization.identifier(provider, field: "provider")
        self.capabilities = try SchedulerCanonicalization.stringList(
            capabilities,
            field: "capabilities"
        )
        self.health = health
        self.maintenance = maintenance
        self.labels = try SchedulerCanonicalization.labels(labels, field: "labels")
        self.taints = Array(Set(taints)).sorted {
            $0.orderingKey < $1.orderingKey
        }
        self.acceleratorAvailability = acceleratorAvailability
    }

    public init(
        nodeID: UUID,
        capacity: ResourceVector,
        allocation: ResourceVector,
        architecture: String,
        runtime: String,
        provider: String,
        capabilities: [String] = [],
        health: SchedulerNodeHealth = .healthy,
        maintenance: SchedulerNodeMaintenance = .available,
        labels: [String: String] = [:],
        taints: [NodeTaint] = [],
        acceleratorAvailability: ResourceVector = .zero
    ) throws {
        try self.init(
            resources: NodeResourceSnapshot(
                nodeID: nodeID,
                capacity: capacity,
                allocation: allocation
            ),
            architecture: architecture,
            runtime: runtime,
            provider: provider,
            capabilities: capabilities,
            health: health,
            maintenance: maintenance,
            labels: labels,
            taints: taints,
            acceleratorAvailability: acceleratorAvailability
        )
    }

    public var nodeID: UUID {
        resources.nodeID
    }

    public var capacity: ResourceVector {
        resources.capacity
    }

    public var allocation: ResourceVector {
        resources.allocation
    }

    public var available: ResourceVector {
        resources.available
    }

    private enum CodingKeys: String, CodingKey {
        case resources
        case architecture
        case runtime
        case provider
        case capabilities
        case health
        case maintenance
        case labels
        case taints
        case acceleratorAvailability
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            resources: container.decode(NodeResourceSnapshot.self, forKey: .resources),
            architecture: container.decode(String.self, forKey: .architecture),
            runtime: container.decode(String.self, forKey: .runtime),
            provider: container.decode(String.self, forKey: .provider),
            capabilities: container.decodeIfPresent(
                [String].self,
                forKey: .capabilities
            ) ?? [],
            health: container.decodeIfPresent(
                SchedulerNodeHealth.self,
                forKey: .health
            ) ?? .unknown,
            maintenance: container.decodeIfPresent(
                SchedulerNodeMaintenance.self,
                forKey: .maintenance
            ) ?? .maintenance,
            labels: container.decodeIfPresent(
                [String: String].self,
                forKey: .labels
            ) ?? [:],
            taints: container.decodeIfPresent(
                [NodeTaint].self,
                forKey: .taints
            ) ?? [],
            acceleratorAvailability: container.decodeIfPresent(
                ResourceVector.self,
                forKey: .acceleratorAvailability
            ) ?? .zero
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resources, forKey: .resources)
        try container.encode(architecture, forKey: .architecture)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(provider, forKey: .provider)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(health, forKey: .health)
        try container.encode(maintenance, forKey: .maintenance)
        try container.encode(labels, forKey: .labels)
        try container.encode(taints, forKey: .taints)
        try container.encode(
            acceleratorAvailability,
            forKey: .acceleratorAvailability
        )
    }
}
