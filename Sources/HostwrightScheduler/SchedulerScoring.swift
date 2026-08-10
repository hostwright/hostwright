import Foundation

public struct SchedulerScoreWeights:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let `default` = SchedulerScoreWeights(
        uncheckedFragmentation: 1,
        uncheckedFairness: 1,
        uncheckedTopology: 1,
        uncheckedLocality: 1,
        uncheckedHostPressureEnergy: 1,
        uncheckedDisruption: 1
    )

    public let fragmentation: Int64
    public let fairness: Int64
    public let topology: Int64
    public let locality: Int64
    public let hostPressureEnergy: Int64
    public let disruption: Int64

    public init(
        fragmentation: Int64 = 1,
        fairness: Int64 = 1,
        topology: Int64 = 1,
        locality: Int64 = 1,
        hostPressureEnergy: Int64 = 1,
        disruption: Int64 = 1
    ) throws {
        let values = [
            ("fragmentation-weight", fragmentation),
            ("fairness-weight", fairness),
            ("topology-weight", topology),
            ("locality-weight", locality),
            ("host-pressure-energy-weight", hostPressureEnergy),
            ("disruption-weight", disruption)
        ]
        for (field, value) in values where value < 0 || value > SchedulerEngineLimits.absoluteMaxWeight {
            throw SchedulerEngineValidationError.invalidValue(field: field, value: value)
        }
        let total = try SchedulerCheckedMath.sum(values.map(\.1), field: "score-weight-total")
        guard total > 0 else {
            throw SchedulerEngineValidationError.invalidValue(field: "score-weight-total", value: total)
        }
        self.fragmentation = fragmentation
        self.fairness = fairness
        self.topology = topology
        self.locality = locality
        self.hostPressureEnergy = hostPressureEnergy
        self.disruption = disruption
    }

    private init(
        uncheckedFragmentation: Int64,
        uncheckedFairness: Int64,
        uncheckedTopology: Int64,
        uncheckedLocality: Int64,
        uncheckedHostPressureEnergy: Int64,
        uncheckedDisruption: Int64
    ) {
        fragmentation = uncheckedFragmentation
        fairness = uncheckedFairness
        topology = uncheckedTopology
        locality = uncheckedLocality
        hostPressureEnergy = uncheckedHostPressureEnergy
        disruption = uncheckedDisruption
    }

    public var total: Int64 {
        fragmentation + fairness + topology + locality + hostPressureEnergy + disruption
    }

    private enum CodingKeys: String, CodingKey {
        case fragmentation
        case fairness
        case topology
        case locality
        case hostPressureEnergy
        case disruption
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            fragmentation: container.decodeIfPresent(Int64.self, forKey: .fragmentation) ?? 1,
            fairness: container.decodeIfPresent(Int64.self, forKey: .fairness) ?? 1,
            topology: container.decodeIfPresent(Int64.self, forKey: .topology) ?? 1,
            locality: container.decodeIfPresent(Int64.self, forKey: .locality) ?? 1,
            hostPressureEnergy: container.decodeIfPresent(
                Int64.self,
                forKey: .hostPressureEnergy
            ) ?? 1,
            disruption: container.decodeIfPresent(Int64.self, forKey: .disruption) ?? 1
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fragmentation, forKey: .fragmentation)
        try container.encode(fairness, forKey: .fairness)
        try container.encode(topology, forKey: .topology)
        try container.encode(locality, forKey: .locality)
        try container.encode(hostPressureEnergy, forKey: .hostPressureEnergy)
        try container.encode(disruption, forKey: .disruption)
    }
}

public struct SchedulerScoreComponents:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let zero = SchedulerScoreComponents(
        uncheckedFragmentationBasisPoints: 0,
        uncheckedFairnessBasisPoints: 0,
        uncheckedTopologyBasisPoints: 0,
        uncheckedLocalityBasisPoints: 0,
        uncheckedHostPressureEnergyBasisPoints: 0,
        uncheckedDisruptionBasisPoints: 0,
        uncheckedTotalBasisPoints: 0
    )

    public let fragmentationBasisPoints: Int64
    public let fairnessBasisPoints: Int64
    public let topologyBasisPoints: Int64
    public let localityBasisPoints: Int64
    public let hostPressureEnergyBasisPoints: Int64
    public let disruptionBasisPoints: Int64
    public let totalBasisPoints: Int64

    public init(
        fragmentationBasisPoints: Int64,
        fairnessBasisPoints: Int64,
        topologyBasisPoints: Int64,
        localityBasisPoints: Int64,
        hostPressureEnergyBasisPoints: Int64,
        disruptionBasisPoints: Int64,
        totalBasisPoints: Int64
    ) throws {
        let values = [
            ("fragmentation-score", fragmentationBasisPoints),
            ("fairness-score", fairnessBasisPoints),
            ("topology-score", topologyBasisPoints),
            ("locality-score", localityBasisPoints),
            ("host-pressure-energy-score", hostPressureEnergyBasisPoints),
            ("disruption-score", disruptionBasisPoints),
            ("total-score", totalBasisPoints)
        ]
        for (field, value) in values where value < 0 || value > SchedulerEngineContractValidation.scale {
            throw SchedulerEngineValidationError.invalidValue(field: field, value: value)
        }
        self.fragmentationBasisPoints = fragmentationBasisPoints
        self.fairnessBasisPoints = fairnessBasisPoints
        self.topologyBasisPoints = topologyBasisPoints
        self.localityBasisPoints = localityBasisPoints
        self.hostPressureEnergyBasisPoints = hostPressureEnergyBasisPoints
        self.disruptionBasisPoints = disruptionBasisPoints
        self.totalBasisPoints = totalBasisPoints
    }

    private init(
        uncheckedFragmentationBasisPoints: Int64,
        uncheckedFairnessBasisPoints: Int64,
        uncheckedTopologyBasisPoints: Int64,
        uncheckedLocalityBasisPoints: Int64,
        uncheckedHostPressureEnergyBasisPoints: Int64,
        uncheckedDisruptionBasisPoints: Int64,
        uncheckedTotalBasisPoints: Int64
    ) {
        fragmentationBasisPoints = uncheckedFragmentationBasisPoints
        fairnessBasisPoints = uncheckedFairnessBasisPoints
        topologyBasisPoints = uncheckedTopologyBasisPoints
        localityBasisPoints = uncheckedLocalityBasisPoints
        hostPressureEnergyBasisPoints = uncheckedHostPressureEnergyBasisPoints
        disruptionBasisPoints = uncheckedDisruptionBasisPoints
        totalBasisPoints = uncheckedTotalBasisPoints
    }

    private enum CodingKeys: String, CodingKey {
        case fragmentationBasisPoints
        case fairnessBasisPoints
        case topologyBasisPoints
        case localityBasisPoints
        case hostPressureEnergyBasisPoints
        case disruptionBasisPoints
        case totalBasisPoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            fragmentationBasisPoints: container.decode(Int64.self, forKey: .fragmentationBasisPoints),
            fairnessBasisPoints: container.decode(Int64.self, forKey: .fairnessBasisPoints),
            topologyBasisPoints: container.decode(Int64.self, forKey: .topologyBasisPoints),
            localityBasisPoints: container.decode(Int64.self, forKey: .localityBasisPoints),
            hostPressureEnergyBasisPoints: container.decode(
                Int64.self,
                forKey: .hostPressureEnergyBasisPoints
            ),
            disruptionBasisPoints: container.decode(Int64.self, forKey: .disruptionBasisPoints),
            totalBasisPoints: container.decode(Int64.self, forKey: .totalBasisPoints)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fragmentationBasisPoints, forKey: .fragmentationBasisPoints)
        try container.encode(fairnessBasisPoints, forKey: .fairnessBasisPoints)
        try container.encode(topologyBasisPoints, forKey: .topologyBasisPoints)
        try container.encode(localityBasisPoints, forKey: .localityBasisPoints)
        try container.encode(
            hostPressureEnergyBasisPoints,
            forKey: .hostPressureEnergyBasisPoints
        )
        try container.encode(disruptionBasisPoints, forKey: .disruptionBasisPoints)
        try container.encode(totalBasisPoints, forKey: .totalBasisPoints)
    }
}
