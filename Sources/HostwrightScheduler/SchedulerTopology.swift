import Foundation

/// A weighted soft selector. The selector operator and values remain part of
/// the canonical contract; callers must not flatten it into an exact label.
public struct SchedulerWeightedLabelSelectorPreference:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let weight: Int64
    public let selector: SchedulerLabelSelector

    public init(weight: Int64, selector: SchedulerLabelSelector) throws {
        guard weight > 0, weight <= SchedulerEngineLimits.absoluteMaxWeight else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "preferred-selector-weight",
                value: weight
            )
        }
        self.weight = weight
        self.selector = selector
    }

    public var orderingKey: String {
        SchedulerOrdering.stableKey(
            [selector.key, selector.`operator`.rawValue]
                + (selector.values.isEmpty ? [""] : selector.values)
                + ["weight:\(weight)"]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case weight
        case selector
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            weight: container.decode(Int64.self, forKey: .weight),
            selector: container.decode(SchedulerLabelSelector.self, forKey: .selector)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(weight, forKey: .weight)
        try container.encode(selector, forKey: .selector)
    }
}

public struct SchedulerTopologyPreference:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let none = SchedulerTopologyPreference(
        uncheckedGroupID: nil,
        uncheckedSpreadKey: nil,
        uncheckedPreferredDomainValues: [],
        uncheckedAffinityWorkloadIDs: [],
        uncheckedAntiAffinityWorkloadIDs: [],
        uncheckedPreferredAffinity: [],
        uncheckedPreferredAntiAffinity: []
    )

    public let groupID: String?
    public let spreadKey: String?
    public let preferredDomainValues: [String]
    public let affinityWorkloadIDs: [UUID]
    public let antiAffinityWorkloadIDs: [UUID]
    public let preferredAffinity: [SchedulerWeightedLabelSelectorPreference]
    public let preferredAntiAffinity: [SchedulerWeightedLabelSelectorPreference]

    public init(
        groupID: String? = nil,
        spreadKey: String? = nil,
        preferredDomainValues: [String] = [],
        affinityWorkloadIDs: [UUID] = [],
        antiAffinityWorkloadIDs: [UUID] = [],
        preferredAffinity: [SchedulerWeightedLabelSelectorPreference] = [],
        preferredAntiAffinity: [SchedulerWeightedLabelSelectorPreference] = []
    ) throws {
        if let groupID {
            try SchedulerEngineContractValidation.text(groupID, field: "topology-group-id")
        }
        if let spreadKey {
            try SchedulerEngineContractValidation.text(spreadKey, field: "topology-spread-key")
        }
        for value in preferredDomainValues {
            try SchedulerEngineContractValidation.text(value, field: "topology-domain-value")
        }
        guard Set(affinityWorkloadIDs).count == affinityWorkloadIDs.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(field: "topology-affinity")
        }
        guard Set(antiAffinityWorkloadIDs).count == antiAffinityWorkloadIDs.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(field: "topology-anti-affinity")
        }
        guard preferredAffinity.count <= SchedulerLabelSelector.maximumCount,
              preferredAntiAffinity.count <= SchedulerLabelSelector.maximumCount else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: "preferred-selector-count",
                limit: SchedulerLabelSelector.maximumCount,
                actual: max(preferredAffinity.count, preferredAntiAffinity.count)
            )
        }
        guard Set(preferredAffinity.map { $0.selector.orderingKey }).count == preferredAffinity.count,
              Set(preferredAntiAffinity.map { $0.selector.orderingKey }).count == preferredAntiAffinity.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(
                field: "preferred-selector"
            )
        }
        self.groupID = groupID
        self.spreadKey = spreadKey
        self.preferredDomainValues = Array(Set(preferredDomainValues)).sorted()
        self.affinityWorkloadIDs = affinityWorkloadIDs.sorted {
            SchedulerOrdering.uuidKey($0) < SchedulerOrdering.uuidKey($1)
        }
        self.antiAffinityWorkloadIDs = antiAffinityWorkloadIDs.sorted {
            SchedulerOrdering.uuidKey($0) < SchedulerOrdering.uuidKey($1)
        }
        self.preferredAffinity = preferredAffinity.sorted { $0.orderingKey < $1.orderingKey }
        self.preferredAntiAffinity = preferredAntiAffinity.sorted { $0.orderingKey < $1.orderingKey }
    }

    private init(
        uncheckedGroupID: String?,
        uncheckedSpreadKey: String?,
        uncheckedPreferredDomainValues: [String],
        uncheckedAffinityWorkloadIDs: [UUID],
        uncheckedAntiAffinityWorkloadIDs: [UUID],
        uncheckedPreferredAffinity: [SchedulerWeightedLabelSelectorPreference],
        uncheckedPreferredAntiAffinity: [SchedulerWeightedLabelSelectorPreference]
    ) {
        groupID = uncheckedGroupID
        spreadKey = uncheckedSpreadKey
        preferredDomainValues = uncheckedPreferredDomainValues
        affinityWorkloadIDs = uncheckedAffinityWorkloadIDs
        antiAffinityWorkloadIDs = uncheckedAntiAffinityWorkloadIDs
        preferredAffinity = uncheckedPreferredAffinity
        preferredAntiAffinity = uncheckedPreferredAntiAffinity
    }

    private enum CodingKeys: String, CodingKey {
        case groupID
        case spreadKey
        case preferredDomainValues
        case affinityWorkloadIDs
        case antiAffinityWorkloadIDs
        case preferredAffinity
        case preferredAntiAffinity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            groupID: container.decodeIfPresent(String.self, forKey: .groupID),
            spreadKey: container.decodeIfPresent(String.self, forKey: .spreadKey),
            preferredDomainValues: container.decodeIfPresent(
                [String].self,
                forKey: .preferredDomainValues
            ) ?? [],
            affinityWorkloadIDs: container.decodeIfPresent(
                [UUID].self,
                forKey: .affinityWorkloadIDs
            ) ?? [],
            antiAffinityWorkloadIDs: container.decodeIfPresent(
                [UUID].self,
                forKey: .antiAffinityWorkloadIDs
            ) ?? [],
            preferredAffinity: container.decodeIfPresent(
                [SchedulerWeightedLabelSelectorPreference].self,
                forKey: .preferredAffinity
            ) ?? [],
            preferredAntiAffinity: container.decodeIfPresent(
                [SchedulerWeightedLabelSelectorPreference].self,
                forKey: .preferredAntiAffinity
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(groupID, forKey: .groupID)
        try container.encodeIfPresent(spreadKey, forKey: .spreadKey)
        try container.encode(preferredDomainValues, forKey: .preferredDomainValues)
        try container.encode(affinityWorkloadIDs, forKey: .affinityWorkloadIDs)
        try container.encode(antiAffinityWorkloadIDs, forKey: .antiAffinityWorkloadIDs)
        try container.encode(preferredAffinity, forKey: .preferredAffinity)
        try container.encode(preferredAntiAffinity, forKey: .preferredAntiAffinity)
    }
}

public struct SchedulerLocalityPreference:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let none = SchedulerLocalityPreference(
        uncheckedPreferredNodeIDs: [],
        uncheckedPreferredDomains: [:]
    )

    public let preferredNodeIDs: [UUID]
    public let preferredDomains: [String: String]

    public init(
        preferredNodeIDs: [UUID] = [],
        preferredDomains: [String: String] = [:]
    ) throws {
        guard Set(preferredNodeIDs).count == preferredNodeIDs.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(field: "locality-node")
        }
        try SchedulerEngineContractValidation.labels(preferredDomains, field: "locality-domains")
        self.preferredNodeIDs = preferredNodeIDs.sorted {
            SchedulerOrdering.uuidKey($0) < SchedulerOrdering.uuidKey($1)
        }
        self.preferredDomains = preferredDomains.keys.sorted().reduce(into: [:]) { result, key in
            result[key] = preferredDomains[key]
        }
    }

    private init(
        uncheckedPreferredNodeIDs: [UUID],
        uncheckedPreferredDomains: [String: String]
    ) {
        preferredNodeIDs = uncheckedPreferredNodeIDs
        preferredDomains = uncheckedPreferredDomains
    }

    private enum CodingKeys: String, CodingKey {
        case preferredNodeIDs
        case preferredDomains
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            preferredNodeIDs: container.decodeIfPresent(
                [UUID].self,
                forKey: .preferredNodeIDs
            ) ?? [],
            preferredDomains: container.decodeIfPresent(
                [String: String].self,
                forKey: .preferredDomains
            ) ?? [:]
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preferredNodeIDs, forKey: .preferredNodeIDs)
        try container.encode(preferredDomains, forKey: .preferredDomains)
    }
}

public enum SchedulerPressurePosture: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case nominal
    case elevated
    case critical
    case unknown
    case unavailable
}

public enum SchedulerEnergyPosture: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case efficient
    case balanced
    case performance
    case constrained
    case unknown
}

public struct SchedulerHostPosture:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let pressure: SchedulerPressurePosture
    public let energy: SchedulerEnergyPosture

    public init(
        pressure: SchedulerPressurePosture = .nominal,
        energy: SchedulerEnergyPosture = .balanced
    ) {
        self.pressure = pressure
        self.energy = energy
    }
}

public struct SchedulerNode:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let snapshot: NodePlacementSnapshot
    public let topologyDomains: [String: String]
    public let posture: SchedulerHostPosture
    public let allocatable: ResourceVector
    public let reservation: ResourceVector
    public let schedulableCapacity: ResourceVector
    public let binClass: SchedulerBinClass
    public let availableVolumeIDs: [String]
    public let availablePorts: [Int]
    public let availableNetworkIDs: [String]

    public init(
        snapshot: NodePlacementSnapshot,
        topologyDomains: [String: String] = [:],
        posture: SchedulerHostPosture = SchedulerHostPosture(),
        allocatable: ResourceVector? = nil,
        reservation: ResourceVector = .zero,
        binClass: SchedulerBinClass = .balanced,
        availableVolumeIDs: [String] = [],
        availablePorts: [Int] = [],
        availableNetworkIDs: [String] = []
    ) throws {
        try SchedulerEngineContractValidation.labels(topologyDomains, field: "topology-domains")
        for value in availableVolumeIDs {
            try SchedulerEngineContractValidation.text(value, field: "available-volume")
        }
        for value in availableNetworkIDs {
            try SchedulerEngineContractValidation.text(value, field: "available-network")
        }
        for value in availablePorts where value < 1 || value > 65_535 {
            throw SchedulerEngineValidationError.invalidCount(field: "available-port", value: value)
        }
        guard Set(availableVolumeIDs).count == availableVolumeIDs.count,
              Set(availablePorts).count == availablePorts.count,
              Set(availableNetworkIDs).count == availableNetworkIDs.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(field: "node-admission")
        }
        let resolvedAllocatable = allocatable ?? snapshot.capacity
        guard resolvedAllocatable.fits(in: snapshot.capacity),
              reservation.fits(in: resolvedAllocatable) else {
            throw SchedulerEngineValidationError.invalidPlacement(
                field: "node-allocatable-reservation",
                id: snapshot.nodeID
            )
        }
        let occupied = try snapshot.allocation.adding(reservation)
        guard occupied.fits(in: resolvedAllocatable) else {
            throw SchedulerEngineValidationError.invalidPlacement(
                field: "node-reservation-accounting",
                id: snapshot.nodeID
            )
        }
        let schedulableCapacity = try resolvedAllocatable.subtracting(reservation)
        self.snapshot = snapshot
        self.topologyDomains = topologyDomains.keys.sorted().reduce(into: [:]) { result, key in
            result[key] = topologyDomains[key]
        }
        self.posture = posture
        self.allocatable = resolvedAllocatable
        self.reservation = reservation
        self.schedulableCapacity = schedulableCapacity
        self.binClass = binClass
        self.availableVolumeIDs = availableVolumeIDs.sorted()
        self.availablePorts = availablePorts.sorted()
        self.availableNetworkIDs = availableNetworkIDs.sorted()
    }

    public var nodeID: UUID {
        snapshot.nodeID
    }

    public var capacity: ResourceVector {
        schedulableCapacity
    }

    public var allocation: ResourceVector {
        snapshot.allocation
    }

    private enum CodingKeys: String, CodingKey {
        case snapshot
        case topologyDomains
        case posture
        case allocatable
        case reservation
        case binClass
        case availableVolumeIDs
        case availablePorts
        case availableNetworkIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            snapshot: container.decode(NodePlacementSnapshot.self, forKey: .snapshot),
            topologyDomains: container.decodeIfPresent(
                [String: String].self,
                forKey: .topologyDomains
            ) ?? [:],
            posture: container.decodeIfPresent(
                SchedulerHostPosture.self,
                forKey: .posture
            ) ?? SchedulerHostPosture(),
            allocatable: container.decodeIfPresent(
                ResourceVector.self,
                forKey: .allocatable
            ),
            reservation: container.decodeIfPresent(
                ResourceVector.self,
                forKey: .reservation
            ) ?? .zero,
            binClass: container.decodeIfPresent(
                SchedulerBinClass.self,
                forKey: .binClass
            ) ?? .balanced,
            availableVolumeIDs: container.decodeIfPresent(
                [String].self,
                forKey: .availableVolumeIDs
            ) ?? [],
            availablePorts: container.decodeIfPresent(
                [Int].self,
                forKey: .availablePorts
            ) ?? [],
            availableNetworkIDs: container.decodeIfPresent(
                [String].self,
                forKey: .availableNetworkIDs
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encode(topologyDomains, forKey: .topologyDomains)
        try container.encode(posture, forKey: .posture)
        try container.encode(allocatable, forKey: .allocatable)
        try container.encode(reservation, forKey: .reservation)
        try container.encode(binClass, forKey: .binClass)
        try container.encode(availableVolumeIDs, forKey: .availableVolumeIDs)
        try container.encode(availablePorts, forKey: .availablePorts)
        try container.encode(availableNetworkIDs, forKey: .availableNetworkIDs)
    }
}
