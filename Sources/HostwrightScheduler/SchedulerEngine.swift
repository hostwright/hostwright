import Foundation
import CryptoKit

public enum SchedulerEngineValidationErrorCode: String, Codable, Equatable, Hashable, Sendable {
    case countLimitExceeded = "count-limit-exceeded"
    case stringLimitExceeded = "string-limit-exceeded"
    case digestLimitExceeded = "digest-limit-exceeded"
    case invalidCount = "invalid-count"
    case invalidValue = "invalid-value"
    case duplicateIdentifier = "duplicate-identifier"
    case unknownReference = "unknown-reference"
    case invalidPlacement = "invalid-placement"
    case unsupportedLimit = "unsupported-limit"
    case unknownStringReference = "unknown-string-reference"
    case arithmeticOverflow = "arithmetic-overflow"
    case invalidDecision = "invalid-decision"
}

public enum SchedulerEngineValidationError:
    Error,
    Equatable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    case countLimitExceeded(field: String, limit: Int, actual: Int)
    case stringLimitExceeded(field: String, limit: Int, actual: Int)
    case digestLimitExceeded(limit: Int, actual: Int)
    case invalidCount(field: String, value: Int)
    case invalidValue(field: String, value: Int64)
    case duplicateIdentifier(field: String)
    case unknownReference(field: String, id: UUID)
    case invalidPlacement(field: String, id: UUID)
    case unsupportedLimit(resource: String)
    case unknownStringReference(field: String, value: String)
    case arithmeticOverflow(field: String)
    case invalidDecision(String)

    public var code: SchedulerEngineValidationErrorCode {
        switch self {
        case .countLimitExceeded:
            .countLimitExceeded
        case .stringLimitExceeded:
            .stringLimitExceeded
        case .digestLimitExceeded:
            .digestLimitExceeded
        case .invalidCount:
            .invalidCount
        case .invalidValue:
            .invalidValue
        case .duplicateIdentifier:
            .duplicateIdentifier
        case .unknownReference:
            .unknownReference
        case .invalidPlacement:
            .invalidPlacement
        case .unsupportedLimit:
            .unsupportedLimit
        case .unknownStringReference:
            .unknownStringReference
        case .arithmeticOverflow:
            .arithmeticOverflow
        case .invalidDecision:
            .invalidDecision
        }
    }

    public var stableKey: String {
        switch self {
        case .countLimitExceeded(let field, let limit, let actual):
            "\(code.rawValue):\(field):\(limit):\(actual)"
        case .stringLimitExceeded(let field, let limit, let actual):
            "\(code.rawValue):\(field):\(limit):\(actual)"
        case .digestLimitExceeded(let limit, let actual):
            "\(code.rawValue):\(limit):\(actual)"
        case .invalidCount(let field, let value):
            "\(code.rawValue):\(field):\(value)"
        case .invalidValue(let field, let value):
            "\(code.rawValue):\(field):\(value)"
        case .duplicateIdentifier(let field):
            "\(code.rawValue):\(field)"
        case .unknownReference(let field, let id),
             .invalidPlacement(let field, let id):
            "\(code.rawValue):\(field):\(SchedulerOrdering.uuidKey(id))"
        case .unsupportedLimit(let resource):
            "\(code.rawValue):\(resource)"
        case .unknownStringReference(let field, let value):
            "\(code.rawValue):\(field):\(value)"
        case .arithmeticOverflow(let field):
            "\(code.rawValue):\(field)"
        case .invalidDecision(let detail):
            "\(code.rawValue):\(detail)"
        }
    }

    public var description: String {
        stableKey
    }
}

public struct SchedulerEngineLimits:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let absoluteMaxWorkloadCount = 10_000
    public static let absoluteMaxNodeCount = 2_000
    public static let absoluteMaxVictimCount = 20_000
    public static let absoluteMaxAlternativeCount = 256
    public static let absoluteMaxBudgetCount = 20_000
    public static let absoluteMaxOvercommitRatioCount = 128
    public static let absoluteMaxTopologyEntryCount = 4_096
    public static let absoluteMaxFilterFailureCount = 100_000
    public static let absoluteMaxExactPreemptionVictimsPerNode = 32
    public static let absoluteMaxExactPreemptionSearchStates = 1_000_000
    public static let absoluteMaxStringBytes = 4_096
    public static let absoluteMaxDigestBytes = 512
    public static let absoluteMaxWeight: Int64 = 1_000_000
    public static let absoluteMaxExplanationDetails = 64
    public static let absoluteMaxResourceEntries = 128

    public static let `default` = SchedulerEngineLimits(
        uncheckedMaxWorkloadCount: 4_096,
        uncheckedMaxNodeCount: 512,
        uncheckedMaxVictimCount: 8_192,
        uncheckedMaxAlternativeCount: 32,
        uncheckedMaxBudgetCount: 4_096,
        uncheckedMaxOvercommitRatioCount: 128,
        uncheckedMaxTopologyEntryCount: 1_024,
        uncheckedMaxFilterFailureCount: 16_384,
        uncheckedMaxStringBytes: 1_024,
        uncheckedMaxDigestBytes: 256,
        uncheckedMaxExactPreemptionVictimsPerNode: 16,
        uncheckedMaxExactPreemptionSearchStates: 65_536
    )

    public let maxWorkloadCount: Int
    public let maxNodeCount: Int
    public let maxVictimCount: Int
    public let maxAlternativeCount: Int
    public let maxBudgetCount: Int
    public let maxOvercommitRatioCount: Int
    public let maxTopologyEntryCount: Int
    public let maxFilterFailureCount: Int
    public let maxStringBytes: Int
    public let maxDigestBytes: Int
    public let maxExactPreemptionVictimsPerNode: Int
    public let maxExactPreemptionSearchStates: Int

    public init(
        maxWorkloadCount: Int = 4_096,
        maxNodeCount: Int = 512,
        maxVictimCount: Int = 8_192,
        maxAlternativeCount: Int = 32,
        maxBudgetCount: Int = 4_096,
        maxOvercommitRatioCount: Int = 128,
        maxTopologyEntryCount: Int = 1_024,
        maxFilterFailureCount: Int = 16_384,
        maxStringBytes: Int = 1_024,
        maxDigestBytes: Int = 256,
        maxExactPreemptionVictimsPerNode: Int = 16,
        maxExactPreemptionSearchStates: Int = 65_536
    ) throws {
        let values = [
            ("workloads", maxWorkloadCount, Self.absoluteMaxWorkloadCount),
            ("nodes", maxNodeCount, Self.absoluteMaxNodeCount),
            ("victims", maxVictimCount, Self.absoluteMaxVictimCount),
            ("alternatives", maxAlternativeCount, Self.absoluteMaxAlternativeCount),
            ("budgets", maxBudgetCount, Self.absoluteMaxBudgetCount),
            ("overcommit-ratios", maxOvercommitRatioCount, Self.absoluteMaxOvercommitRatioCount),
            ("topology-entries", maxTopologyEntryCount, Self.absoluteMaxTopologyEntryCount),
            ("filter-failures", maxFilterFailureCount, Self.absoluteMaxFilterFailureCount),
            ("strings", maxStringBytes, Self.absoluteMaxStringBytes),
            ("digests", maxDigestBytes, Self.absoluteMaxDigestBytes),
            (
                "exact-preemption-victims-per-node",
                maxExactPreemptionVictimsPerNode,
                Self.absoluteMaxExactPreemptionVictimsPerNode
            ),
            (
                "exact-preemption-search-states",
                maxExactPreemptionSearchStates,
                Self.absoluteMaxExactPreemptionSearchStates
            )
        ]
        for (field, value, maximum) in values where value <= 0 || value > maximum {
            throw SchedulerEngineValidationError.invalidCount(field: field, value: value)
        }
        self.maxWorkloadCount = maxWorkloadCount
        self.maxNodeCount = maxNodeCount
        self.maxVictimCount = maxVictimCount
        self.maxAlternativeCount = maxAlternativeCount
        self.maxBudgetCount = maxBudgetCount
        self.maxOvercommitRatioCount = maxOvercommitRatioCount
        self.maxTopologyEntryCount = maxTopologyEntryCount
        self.maxFilterFailureCount = maxFilterFailureCount
        self.maxStringBytes = maxStringBytes
        self.maxDigestBytes = maxDigestBytes
        self.maxExactPreemptionVictimsPerNode = maxExactPreemptionVictimsPerNode
        self.maxExactPreemptionSearchStates = maxExactPreemptionSearchStates
    }

    private init(
        uncheckedMaxWorkloadCount: Int,
        uncheckedMaxNodeCount: Int,
        uncheckedMaxVictimCount: Int,
        uncheckedMaxAlternativeCount: Int,
        uncheckedMaxBudgetCount: Int,
        uncheckedMaxOvercommitRatioCount: Int,
        uncheckedMaxTopologyEntryCount: Int,
        uncheckedMaxFilterFailureCount: Int,
        uncheckedMaxStringBytes: Int,
        uncheckedMaxDigestBytes: Int,
        uncheckedMaxExactPreemptionVictimsPerNode: Int,
        uncheckedMaxExactPreemptionSearchStates: Int
    ) {
        maxWorkloadCount = uncheckedMaxWorkloadCount
        maxNodeCount = uncheckedMaxNodeCount
        maxVictimCount = uncheckedMaxVictimCount
        maxAlternativeCount = uncheckedMaxAlternativeCount
        maxBudgetCount = uncheckedMaxBudgetCount
        maxOvercommitRatioCount = uncheckedMaxOvercommitRatioCount
        maxTopologyEntryCount = uncheckedMaxTopologyEntryCount
        maxFilterFailureCount = uncheckedMaxFilterFailureCount
        maxStringBytes = uncheckedMaxStringBytes
        maxDigestBytes = uncheckedMaxDigestBytes
        maxExactPreemptionVictimsPerNode = uncheckedMaxExactPreemptionVictimsPerNode
        maxExactPreemptionSearchStates = uncheckedMaxExactPreemptionSearchStates
    }

    private enum CodingKeys: String, CodingKey {
        case maxWorkloadCount
        case maxNodeCount
        case maxVictimCount
        case maxAlternativeCount
        case maxBudgetCount
        case maxOvercommitRatioCount
        case maxTopologyEntryCount
        case maxFilterFailureCount
        case maxStringBytes
        case maxDigestBytes
        case maxExactPreemptionVictimsPerNode
        case maxExactPreemptionSearchStates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maxWorkloadCount: container.decodeIfPresent(Int.self, forKey: .maxWorkloadCount) ?? 4_096,
            maxNodeCount: container.decodeIfPresent(Int.self, forKey: .maxNodeCount) ?? 512,
            maxVictimCount: container.decodeIfPresent(Int.self, forKey: .maxVictimCount) ?? 8_192,
            maxAlternativeCount: container.decodeIfPresent(
                Int.self,
                forKey: .maxAlternativeCount
            ) ?? 32,
            maxBudgetCount: container.decodeIfPresent(Int.self, forKey: .maxBudgetCount) ?? 4_096,
            maxOvercommitRatioCount: container.decodeIfPresent(
                Int.self,
                forKey: .maxOvercommitRatioCount
            ) ?? 128,
            maxTopologyEntryCount: container.decodeIfPresent(
                Int.self,
                forKey: .maxTopologyEntryCount
            ) ?? 1_024,
            maxFilterFailureCount: container.decodeIfPresent(
                Int.self,
                forKey: .maxFilterFailureCount
            ) ?? 16_384,
            maxStringBytes: container.decodeIfPresent(Int.self, forKey: .maxStringBytes) ?? 1_024,
            maxDigestBytes: container.decodeIfPresent(Int.self, forKey: .maxDigestBytes) ?? 256,
            maxExactPreemptionVictimsPerNode: container.decodeIfPresent(
                Int.self,
                forKey: .maxExactPreemptionVictimsPerNode
            ) ?? 16,
            maxExactPreemptionSearchStates: container.decodeIfPresent(
                Int.self,
                forKey: .maxExactPreemptionSearchStates
            ) ?? 65_536
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxWorkloadCount, forKey: .maxWorkloadCount)
        try container.encode(maxNodeCount, forKey: .maxNodeCount)
        try container.encode(maxVictimCount, forKey: .maxVictimCount)
        try container.encode(maxAlternativeCount, forKey: .maxAlternativeCount)
        try container.encode(maxBudgetCount, forKey: .maxBudgetCount)
        try container.encode(maxOvercommitRatioCount, forKey: .maxOvercommitRatioCount)
        try container.encode(maxTopologyEntryCount, forKey: .maxTopologyEntryCount)
        try container.encode(maxFilterFailureCount, forKey: .maxFilterFailureCount)
        try container.encode(maxStringBytes, forKey: .maxStringBytes)
        try container.encode(maxDigestBytes, forKey: .maxDigestBytes)
        try container.encode(
            maxExactPreemptionVictimsPerNode,
            forKey: .maxExactPreemptionVictimsPerNode
        )
        try container.encode(
            maxExactPreemptionSearchStates,
            forKey: .maxExactPreemptionSearchStates
        )
    }
}

public enum SchedulerEngineContractValidation {
    public static let scale: Int64 = 10_000

    public static func count(_ actual: Int, field: String, limit: Int) throws {
        guard actual <= limit else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: field,
                limit: limit,
                actual: actual
            )
        }
    }

    public static func text(_ value: String, field: String) throws {
        let bytes = value.utf8.count
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 }),
              bytes <= SchedulerEngineLimits.absoluteMaxStringBytes else {
            throw SchedulerEngineValidationError.stringLimitExceeded(
                field: field,
                limit: SchedulerEngineLimits.absoluteMaxStringBytes,
                actual: bytes
            )
        }
    }

    public static func text(
        _ value: String,
        field: String,
        limit: Int
    ) throws {
        try text(value, field: field)
        let bytes = value.utf8.count
        guard bytes <= limit else {
            throw SchedulerEngineValidationError.stringLimitExceeded(
                field: field,
                limit: limit,
                actual: bytes
            )
        }
    }

    public static func digest(_ value: String, limit: Int) throws {
        let bytes = value.utf8.count
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw SchedulerEngineValidationError.invalidValue(field: "input-digest", value: 0)
        }
        guard bytes <= limit else {
            throw SchedulerEngineValidationError.digestLimitExceeded(limit: limit, actual: bytes)
        }
    }

    public static func labels(
        _ values: [String: String],
        field: String,
        limit: Int = SchedulerEngineLimits.absoluteMaxStringBytes
    ) throws {
        for key in values.keys.sorted() {
            try text(key, field: field + "-key", limit: limit)
            try text(values[key] ?? "", field: field + "-value", limit: limit)
        }
    }

    public static func resourceVector(
        _ vector: ResourceVector,
        field: String,
        limits: SchedulerEngineLimits
    ) throws {
        guard vector.resourceNames.count <= absoluteResourceLimit(limits) else {
            throw SchedulerEngineValidationError.countLimitExceeded(
                field: field + "-resources",
                limit: absoluteResourceLimit(limits),
                actual: vector.resourceNames.count
            )
        }
        for resource in vector.resourceNames {
            try text(resource, field: field + "-resource", limit: limits.maxStringBytes)
        }
    }

    private static func absoluteResourceLimit(_ limits: SchedulerEngineLimits) -> Int {
        min(limits.maxStringBytes > 0 ? SchedulerEngineLimits.absoluteMaxResourceEntries : 0,
            SchedulerEngineLimits.absoluteMaxResourceEntries)
    }

    public static func workload(
        _ workload: SchedulerWorkload,
        limits: SchedulerEngineLimits
    ) throws {
        try resourceVector(workload.requirements.request, field: "workload-request", limits: limits)
        if let limit = workload.requirements.limit {
            try resourceVector(limit, field: "workload-limit", limits: limits)
        }
        try resourceVector(
            workload.requirements.acceleratorRequirements,
            field: "workload-accelerators",
            limits: limits
        )
        try resourceVector(workload.overhead, field: "workload-overhead", limits: limits)
        try resourceVector(
            workload.safetyMargin,
            field: "workload-safety-margin",
            limits: limits
        )
        try text(workload.subjectID, field: "subject-id", limit: limits.maxStringBytes)
        try text(workload.projectID, field: "project-id", limit: limits.maxStringBytes)
        for value in workload.requirements.requiredArchitectures {
            try text(value, field: "required-architecture", limit: limits.maxStringBytes)
        }
        if let value = workload.requirements.requiredRuntime {
            try text(value, field: "required-runtime", limit: limits.maxStringBytes)
        }
        if let value = workload.requirements.requiredProvider {
            try text(value, field: "required-provider", limit: limits.maxStringBytes)
        }
        for value in workload.requirements.requiredCapabilities {
            try text(value, field: "required-capability", limit: limits.maxStringBytes)
        }
        try labels(
            workload.requirements.affinity.requiredLabels,
            field: "required-label",
            limit: limits.maxStringBytes
        )
        try labels(
            workload.requirements.affinity.forbiddenLabels,
            field: "forbidden-label",
            limit: limits.maxStringBytes
        )
        for toleration in workload.requirements.tolerations {
            if let value = toleration.key {
                try text(value, field: "toleration-key", limit: limits.maxStringBytes)
            }
            if let value = toleration.value {
                try text(value, field: "toleration-value", limit: limits.maxStringBytes)
            }
        }
        if let value = workload.topology.groupID {
            try text(value, field: "topology-group-id", limit: limits.maxStringBytes)
        }
        if let value = workload.topology.spreadKey {
            try text(value, field: "topology-spread-key", limit: limits.maxStringBytes)
        }
        for value in workload.topology.preferredDomainValues {
            try text(value, field: "topology-domain-value", limit: limits.maxStringBytes)
        }
        for preference in workload.topology.preferredAffinity {
            try text(
                preference.selector.key,
                field: "preferred-affinity-selector-key",
                limit: limits.maxStringBytes
            )
            for value in preference.selector.values {
                try text(
                    value,
                    field: "preferred-affinity-selector-value",
                    limit: limits.maxStringBytes
                )
            }
        }
        for preference in workload.topology.preferredAntiAffinity {
            try text(
                preference.selector.key,
                field: "preferred-anti-affinity-selector-key",
                limit: limits.maxStringBytes
            )
            for value in preference.selector.values {
                try text(
                    value,
                    field: "preferred-anti-affinity-selector-value",
                    limit: limits.maxStringBytes
                )
            }
        }
        try labels(
            workload.locality.preferredDomains,
            field: "locality-domain",
            limit: limits.maxStringBytes
        )
        for value in workload.constraints.requiredVolumes {
            try text(value, field: "required-volume", limit: limits.maxStringBytes)
        }
        for value in workload.constraints.requiredNetworks {
            try text(value, field: "required-network", limit: limits.maxStringBytes)
        }
    }

    public static func node(_ node: SchedulerNode, limits: SchedulerEngineLimits) throws {
        let snapshot = node.snapshot
        try resourceVector(snapshot.capacity, field: "node-capacity", limits: limits)
        try resourceVector(snapshot.allocation, field: "node-allocation", limits: limits)
        try resourceVector(node.allocatable, field: "node-allocatable", limits: limits)
        try resourceVector(node.reservation, field: "node-reservation", limits: limits)
        try resourceVector(
            snapshot.acceleratorAvailability,
            field: "node-accelerators",
            limits: limits
        )
        try text(snapshot.architecture, field: "architecture", limit: limits.maxStringBytes)
        try text(snapshot.runtime, field: "runtime", limit: limits.maxStringBytes)
        try text(snapshot.provider, field: "provider", limit: limits.maxStringBytes)
        for value in snapshot.capabilities {
            try text(value, field: "node-capability", limit: limits.maxStringBytes)
        }
        try labels(snapshot.labels, field: "node-label", limit: limits.maxStringBytes)
        for taint in snapshot.taints {
            try text(taint.key, field: "taint-key", limit: limits.maxStringBytes)
            if let value = taint.value {
                try text(value, field: "taint-value", limit: limits.maxStringBytes)
            }
        }
        try labels(node.topologyDomains, field: "topology-domain")
        for value in node.availableVolumeIDs {
            try text(value, field: "available-volume", limit: limits.maxStringBytes)
        }
        for value in node.availableNetworkIDs {
            try text(value, field: "available-network", limit: limits.maxStringBytes)
        }
    }
}

public enum SchedulerCheckedMath {
    public static func add(_ lhs: Int64, _ rhs: Int64, field: String) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw SchedulerEngineValidationError.arithmeticOverflow(field: field)
        }
        return value
    }

    public static func subtract(_ lhs: Int64, _ rhs: Int64, field: String) throws -> Int64 {
        let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard !overflow else {
            throw SchedulerEngineValidationError.arithmeticOverflow(field: field)
        }
        return value
    }

    public static func multiply(_ lhs: Int64, _ rhs: Int64, field: String) throws -> Int64 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw SchedulerEngineValidationError.arithmeticOverflow(field: field)
        }
        return value
    }

    public static func sum<S: Sequence>(_ values: S, field: String) throws -> Int64 where S.Element == Int64 {
        var total: Int64 = 0
        for value in values {
            total = try add(total, value, field: field)
        }
        return total
    }

    public static func ceilDivide(_ numerator: Int64, by denominator: Int64, field: String) throws -> Int64 {
        guard denominator > 0 else {
            throw SchedulerEngineValidationError.invalidValue(field: field, value: denominator)
        }
        let quotient = numerator / denominator
        guard numerator % denominator != 0 else {
            return quotient
        }
        return try add(quotient, 1, field: field)
    }

    public static func clamp(_ value: Int64, lower: Int64 = 0, upper: Int64) -> Int64 {
        min(max(value, lower), upper)
    }
}

public struct SchedulerResourceRatio:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let numerator: Int64
    public let denominator: Int64

    public init(numerator: Int64, denominator: Int64) throws {
        guard numerator > 0, denominator > 0,
              numerator >= denominator,
              numerator <= SchedulerEngineLimits.absoluteMaxWeight,
              denominator <= SchedulerEngineLimits.absoluteMaxWeight else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "resource-overcommit-ratio",
                value: numerator <= 0 ? numerator : denominator
            )
        }
        let divisor = Self.greatestCommonDivisor(numerator, denominator)
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    public static let one = SchedulerResourceRatio(
        uncheckedNumerator: 1,
        uncheckedDenominator: 1
    )

    public var isOvercommit: Bool {
        numerator > denominator
    }

    private init(uncheckedNumerator: Int64, uncheckedDenominator: Int64) {
        numerator = uncheckedNumerator
        denominator = uncheckedDenominator
    }

    private static func greatestCommonDivisor(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        var left = lhs
        var right = rhs
        while right != 0 {
            let remainder = left % right
            left = right
            right = remainder
        }
        return left
    }

    private enum CodingKeys: String, CodingKey {
        case numerator
        case denominator
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            numerator: container.decode(Int64.self, forKey: .numerator),
            denominator: container.decode(Int64.self, forKey: .denominator)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(numerator, forKey: .numerator)
        try container.encode(denominator, forKey: .denominator)
    }
}

public struct SchedulerAdditionalPlacementConstraints:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let none = SchedulerAdditionalPlacementConstraints(
        uncheckedRequiredVolumes: [],
        uncheckedRequiredPorts: [],
        uncheckedRequiredNetworks: []
    )

    public let requiredVolumes: [String]
    public let requiredPorts: [Int]
    public let requiredNetworks: [String]

    public init(
        requiredVolumes: [String] = [],
        requiredPorts: [Int] = [],
        requiredNetworks: [String] = []
    ) throws {
        for value in requiredVolumes {
            try SchedulerEngineContractValidation.text(value, field: "required-volume")
        }
        for value in requiredNetworks {
            try SchedulerEngineContractValidation.text(value, field: "required-network")
        }
        for value in requiredPorts where value < 1 || value > 65_535 {
            throw SchedulerEngineValidationError.invalidCount(field: "required-port", value: value)
        }
        guard Set(requiredVolumes).count == requiredVolumes.count,
              Set(requiredPorts).count == requiredPorts.count,
              Set(requiredNetworks).count == requiredNetworks.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(field: "additional-placement")
        }
        self.requiredVolumes = requiredVolumes.sorted()
        self.requiredPorts = requiredPorts.sorted()
        self.requiredNetworks = requiredNetworks.sorted()
    }

    private init(
        uncheckedRequiredVolumes: [String],
        uncheckedRequiredPorts: [Int],
        uncheckedRequiredNetworks: [String]
    ) {
        requiredVolumes = uncheckedRequiredVolumes
        requiredPorts = uncheckedRequiredPorts
        requiredNetworks = uncheckedRequiredNetworks
    }

    private enum CodingKeys: String, CodingKey {
        case requiredVolumes
        case requiredPorts
        case requiredNetworks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requiredVolumes: container.decodeIfPresent([String].self, forKey: .requiredVolumes) ?? [],
            requiredPorts: container.decodeIfPresent([Int].self, forKey: .requiredPorts) ?? [],
            requiredNetworks: container.decodeIfPresent([String].self, forKey: .requiredNetworks) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requiredVolumes, forKey: .requiredVolumes)
        try container.encode(requiredPorts, forKey: .requiredPorts)
        try container.encode(requiredNetworks, forKey: .requiredNetworks)
    }
}

/// Per-workload admission intent. `eligible` is an opt-in only; the engine
/// still requires daemon/operator authorization in `SchedulerPreemptionPolicy`.
public enum SchedulerWorkloadPreemptionEligibility:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case eligible
    case nonPreempting = "non-preempting"
}

public struct SchedulerWorkload:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let requirements: WorkloadPlacementRequirements
    public let priority: Int64
    public let subjectID: String
    public let projectID: String
    public let topology: SchedulerTopologyPreference
    public let locality: SchedulerLocalityPreference
    public let disruption: SchedulerDisruptionProfile
    public let constraints: SchedulerAdditionalPlacementConstraints
    public let overhead: ResourceVector
    public let safetyMargin: ResourceVector
    public let binClass: SchedulerBinClass
    public let preemptionEligibility: SchedulerWorkloadPreemptionEligibility

    public init(
        requirements: WorkloadPlacementRequirements,
        priority: Int64,
        subjectID: String,
        projectID: String,
        topology: SchedulerTopologyPreference = .none,
        locality: SchedulerLocalityPreference = .none,
        disruption: SchedulerDisruptionProfile = .default,
        constraints: SchedulerAdditionalPlacementConstraints = .none,
        overhead: ResourceVector = .zero,
        safetyMargin: ResourceVector = .zero,
        binClass: SchedulerBinClass = .balanced,
        preemptionEligibility: SchedulerWorkloadPreemptionEligibility = .nonPreempting
    ) throws {
        guard priority >= -SchedulerEngineLimits.absoluteMaxWeight,
              priority <= SchedulerEngineLimits.absoluteMaxWeight else {
            throw SchedulerEngineValidationError.invalidValue(field: "workload-priority", value: priority)
        }
        try SchedulerEngineContractValidation.text(subjectID, field: "subject-id")
        try SchedulerEngineContractValidation.text(projectID, field: "project-id")
        self.requirements = requirements
        self.priority = priority
        self.subjectID = subjectID
        self.projectID = projectID
        self.topology = topology
        self.locality = locality
        self.disruption = disruption
        self.constraints = constraints
        self.overhead = overhead
        self.safetyMargin = safetyMargin
        self.binClass = binClass
        self.preemptionEligibility = preemptionEligibility
    }

    public var workloadID: UUID {
        requirements.workloadID
    }

    public var request: ResourceVector {
        requirements.request
    }

    private enum CodingKeys: String, CodingKey {
        case requirements
        case priority
        case subjectID
        case projectID
        case topology
        case locality
        case disruption
        case constraints
        case overhead
        case safetyMargin
        case binClass
        case preemptionEligibility
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requirements: container.decode(WorkloadPlacementRequirements.self, forKey: .requirements),
            priority: container.decode(Int64.self, forKey: .priority),
            subjectID: container.decode(String.self, forKey: .subjectID),
            projectID: container.decode(String.self, forKey: .projectID),
            topology: container.decodeIfPresent(
                SchedulerTopologyPreference.self,
                forKey: .topology
            ) ?? .none,
            locality: container.decodeIfPresent(
                SchedulerLocalityPreference.self,
                forKey: .locality
            ) ?? .none,
            disruption: container.decodeIfPresent(
                SchedulerDisruptionProfile.self,
                forKey: .disruption
            ) ?? .default,
            constraints: container.decodeIfPresent(
                SchedulerAdditionalPlacementConstraints.self,
                forKey: .constraints
            ) ?? .none,
            overhead: container.decodeIfPresent(
                ResourceVector.self,
                forKey: .overhead
            ) ?? .zero,
            safetyMargin: container.decodeIfPresent(
                ResourceVector.self,
                forKey: .safetyMargin
            ) ?? .zero,
            binClass: container.decodeIfPresent(
                SchedulerBinClass.self,
                forKey: .binClass
            ) ?? .balanced,
            preemptionEligibility: container.decodeIfPresent(
                SchedulerWorkloadPreemptionEligibility.self,
                forKey: .preemptionEligibility
            ) ?? .nonPreempting
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requirements, forKey: .requirements)
        try container.encode(priority, forKey: .priority)
        try container.encode(subjectID, forKey: .subjectID)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(topology, forKey: .topology)
        try container.encode(locality, forKey: .locality)
        try container.encode(disruption, forKey: .disruption)
        try container.encode(constraints, forKey: .constraints)
        try container.encode(overhead, forKey: .overhead)
        try container.encode(safetyMargin, forKey: .safetyMargin)
        try container.encode(binClass, forKey: .binClass)
        try container.encode(preemptionEligibility, forKey: .preemptionEligibility)
    }
}

private struct SchedulerEngineDigestMaterial: Encodable {
    let pendingWorkloads: [SchedulerWorkload]
    let nodes: [SchedulerNode]
    let fairnessStates: [SchedulerFairnessState]
    let existingPlacements: [SchedulerExistingPlacement]
    let victimAllocations: [SchedulerVictimAllocation]
    let disruptionBudgets: [SchedulerDisruptionBudget]
    let antiChurnThresholdBasisPoints: Int64
    let scoringWeights: SchedulerScoreWeights
    let overcommitRatios: [String: SchedulerResourceRatio]
    let preemptionPolicy: SchedulerPreemptionPolicy
    let queuePolicy: SchedulerQueuePolicy
    let stabilityPolicy: SchedulerStabilityPolicy
    let snapshotQuality: SchedulerSnapshotQuality
    let limits: SchedulerEngineLimits
}

public struct SchedulerEngineInput:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let inputDigest: String
    public let pendingWorkloads: [SchedulerWorkload]
    public let nodes: [SchedulerNode]
    public let fairnessStates: [SchedulerFairnessState]
    public let existingPlacements: [SchedulerExistingPlacement]
    public let victimAllocations: [SchedulerVictimAllocation]
    public let disruptionBudgets: [SchedulerDisruptionBudget]
    public let antiChurnThresholdBasisPoints: Int64
    public let scoringWeights: SchedulerScoreWeights
    public let overcommitRatios: [String: SchedulerResourceRatio]
    public let preemptionPolicy: SchedulerPreemptionPolicy
    public let queuePolicy: SchedulerQueuePolicy
    public let stabilityPolicy: SchedulerStabilityPolicy
    public let snapshotQuality: SchedulerSnapshotQuality
    public let limits: SchedulerEngineLimits

    public init(
        inputDigest: String? = nil,
        pendingWorkloads: [SchedulerWorkload],
        nodes: [SchedulerNode],
        fairnessStates: [SchedulerFairnessState] = [],
        existingPlacements: [SchedulerExistingPlacement] = [],
        victimAllocations: [SchedulerVictimAllocation] = [],
        disruptionBudgets: [SchedulerDisruptionBudget] = [],
        antiChurnThresholdBasisPoints: Int64 = 250,
        scoringWeights: SchedulerScoreWeights = .default,
        overcommitRatios: [String: SchedulerResourceRatio] = [:],
        preemptionPolicy: SchedulerPreemptionPolicy = .standard,
        queuePolicy: SchedulerQueuePolicy = .standard,
        stabilityPolicy: SchedulerStabilityPolicy = .standard,
        snapshotQuality: SchedulerSnapshotQuality = .standard,
        limits: SchedulerEngineLimits = .default
    ) throws {
        if let inputDigest {
            try SchedulerEngineContractValidation.digest(inputDigest, limit: limits.maxDigestBytes)
        }
        try SchedulerEngineContractValidation.count(
            pendingWorkloads.count,
            field: "workloads",
            limit: limits.maxWorkloadCount
        )
        try SchedulerEngineContractValidation.count(
            nodes.count,
            field: "nodes",
            limit: limits.maxNodeCount
        )
        try SchedulerEngineContractValidation.count(
            victimAllocations.count,
            field: "victims",
            limit: limits.maxVictimCount
        )
        try SchedulerEngineContractValidation.count(
            disruptionBudgets.count,
            field: "disruption-budgets",
            limit: limits.maxBudgetCount
        )
        try SchedulerEngineContractValidation.count(
            overcommitRatios.count,
            field: "overcommit-ratios",
            limit: limits.maxOvercommitRatioCount
        )
        try SchedulerEngineContractValidation.count(
            existingPlacements.count,
            field: "existing-placements",
            limit: limits.maxWorkloadCount
        )
        try SchedulerEngineContractValidation.count(
            fairnessStates.count,
            field: "fairness-states",
            limit: limits.maxWorkloadCount
        )
        guard antiChurnThresholdBasisPoints >= 0,
              antiChurnThresholdBasisPoints <= SchedulerEngineContractValidation.scale else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "anti-churn-threshold",
                value: antiChurnThresholdBasisPoints
            )
        }
        for workload in pendingWorkloads {
            try SchedulerEngineContractValidation.count(
                workload.topology.preferredDomainValues.count,
                field: "workload-topology-domains",
                limit: limits.maxTopologyEntryCount
            )
            try SchedulerEngineContractValidation.count(
                workload.topology.affinityWorkloadIDs.count,
                field: "workload-topology-affinity",
                limit: limits.maxTopologyEntryCount
            )
            try SchedulerEngineContractValidation.count(
                workload.topology.antiAffinityWorkloadIDs.count,
                field: "workload-topology-anti-affinity",
                limit: limits.maxTopologyEntryCount
            )
            try SchedulerEngineContractValidation.count(
                workload.topology.preferredAffinity.count,
                field: "workload-preferred-affinity",
                limit: limits.maxTopologyEntryCount
            )
            try SchedulerEngineContractValidation.count(
                workload.topology.preferredAntiAffinity.count,
                field: "workload-preferred-anti-affinity",
                limit: limits.maxTopologyEntryCount
            )
            try SchedulerEngineContractValidation.count(
                workload.locality.preferredNodeIDs.count,
                field: "workload-locality-nodes",
                limit: limits.maxTopologyEntryCount
            )
            try SchedulerEngineContractValidation.count(
                workload.locality.preferredDomains.count,
                field: "workload-locality-domains",
                limit: limits.maxTopologyEntryCount
            )
            try SchedulerEngineContractValidation.count(
                workload.constraints.requiredVolumes.count,
                field: "required-volumes",
                limit: limits.maxTopologyEntryCount
            )
            try SchedulerEngineContractValidation.count(
                workload.constraints.requiredPorts.count,
                field: "required-ports",
                limit: limits.maxTopologyEntryCount
            )
            try SchedulerEngineContractValidation.count(
                workload.constraints.requiredNetworks.count,
                field: "required-networks",
                limit: limits.maxTopologyEntryCount
            )
        }
        for node in nodes {
            try SchedulerEngineContractValidation.count(
                node.topologyDomains.count,
                field: "node-topology-domains",
                limit: limits.maxTopologyEntryCount
            )
            try SchedulerEngineContractValidation.count(
                node.availableVolumeIDs.count,
                field: "available-volumes",
                limit: limits.maxTopologyEntryCount
            )
            try SchedulerEngineContractValidation.count(
                node.availablePorts.count,
                field: "available-ports",
                limit: limits.maxTopologyEntryCount
            )
            try SchedulerEngineContractValidation.count(
                node.availableNetworkIDs.count,
                field: "available-networks",
                limit: limits.maxTopologyEntryCount
            )
        }
        for resource in overcommitRatios.keys.sorted() {
            try SchedulerEngineContractValidation.text(
                resource,
                field: "overcommit-resource",
                limit: limits.maxStringBytes
            )
        }
        try SchedulerEngineContractValidation.text(
            snapshotQuality.sourceGeneration,
            field: "snapshot-generation",
            limit: limits.maxStringBytes
        )
        if let authorizationReference = preemptionPolicy.authorizationReference {
            try SchedulerEngineContractValidation.text(
                authorizationReference,
                field: "preemption-authorization-reference",
                limit: limits.maxStringBytes
            )
        }
        for workload in pendingWorkloads {
            try SchedulerEngineContractValidation.workload(workload, limits: limits)
        }
        for node in nodes {
            try SchedulerEngineContractValidation.node(node, limits: limits)
        }
        let enforceableResources = Set(
            nodes.flatMap { $0.capacity.resourceNames }
        )
        for workload in pendingWorkloads {
            if let limit = workload.requirements.limit {
                for resource in limit.resourceNames where !enforceableResources.contains(resource) {
                    throw SchedulerEngineValidationError.unsupportedLimit(resource: resource)
                }
            }
        }
        for resource in overcommitRatios.keys where !enforceableResources.contains(resource) {
            throw SchedulerEngineValidationError.unknownStringReference(
                field: "overcommit-resource",
                value: resource
            )
        }
        for state in fairnessStates {
            try SchedulerEngineContractValidation.text(
                state.subjectID,
                field: "fairness-subject-id",
                limit: limits.maxStringBytes
            )
            try SchedulerEngineContractValidation.text(
                state.projectID,
                field: "fairness-project-id",
                limit: limits.maxStringBytes
            )
            try SchedulerEngineContractValidation.resourceVector(
                state.usage,
                field: "fairness-usage",
                limits: limits
            )
            try SchedulerEngineContractValidation.resourceVector(
                state.guarantee,
                field: "fairness-guarantee",
                limits: limits
            )
            try SchedulerEngineContractValidation.resourceVector(
                state.reclaimableBorrowedUsage,
                field: "fairness-borrowed-usage",
                limits: limits
            )
            if let quota = state.quota {
                try SchedulerEngineContractValidation.resourceVector(
                    quota,
                    field: "fairness-quota",
                    limits: limits
                )
            }
            try SchedulerEngineContractValidation.resourceVector(
                state.pendingDemand,
                field: "fairness-pending-demand",
                limits: limits
            )
            let fairnessResources = Set(state.usage.resourceNames)
                .union(state.guarantee.resourceNames)
                .union(state.reclaimableBorrowedUsage.resourceNames)
                .union(state.quota?.resourceNames ?? [])
                .union(state.pendingDemand.resourceNames)
            for resource in fairnessResources where !enforceableResources.contains(resource) {
                throw SchedulerEngineValidationError.unknownStringReference(
                    field: "fairness-resource",
                    value: resource
                )
            }
        }
        try Self.validateUnique(
            pendingWorkloads.map(\.workloadID),
            field: "workloads"
        )
        try Self.validateUnique(nodes.map(\.nodeID), field: "nodes")
        try Self.validateUnique(existingPlacements.map(\.workloadID), field: "existing-placements")
        try Self.validateUnique(victimAllocations.map(\.workloadID), field: "victims")
        try Self.validateUnique(
            fairnessStates.map { $0.subjectID + "\u{1F}" + $0.projectID },
            field: "fairness-states"
        )
        var budgetProjectsByID: [String: String] = [:]
        for budget in disruptionBudgets {
            if let existingProject = budgetProjectsByID[budget.budgetID],
               existingProject != budget.projectID {
                throw SchedulerEngineValidationError.invalidDecision(
                    "disruption-budget-project-ambiguous"
                )
            }
            budgetProjectsByID[budget.budgetID] = budget.projectID
        }
        try Self.validateUnique(disruptionBudgets.map(\.budgetID), field: "disruption-budgets")

        let nodeIDs = Set(nodes.map(\.nodeID))
        let pendingIDs = Set(pendingWorkloads.map(\.workloadID))
        var occupancyTotals: [UUID: ResourceVector] = [:]
        for placement in existingPlacements {
            guard pendingIDs.contains(placement.workloadID) else {
                throw SchedulerEngineValidationError.unknownReference(
                    field: "existing-placement-workload",
                    id: placement.workloadID
                )
            }
            guard nodeIDs.contains(placement.nodeID) else {
                throw SchedulerEngineValidationError.unknownReference(
                    field: "existing-placement-node",
                    id: placement.nodeID
                )
            }
            guard let node = nodes.first(where: { $0.nodeID == placement.nodeID }),
                  placement.allocation.fits(in: node.allocation) else {
                throw SchedulerEngineValidationError.invalidPlacement(
                    field: "existing-placement-allocation",
                    id: placement.workloadID
                )
            }
            try SchedulerEngineContractValidation.resourceVector(
                placement.allocation,
                field: "existing-placement-allocation",
                limits: limits
            )
            let prior = occupancyTotals[placement.nodeID] ?? .zero
            occupancyTotals[placement.nodeID] = try prior.adding(placement.allocation)
            if let groupID = placement.topologyGroupID {
                try SchedulerEngineContractValidation.text(
                    groupID,
                    field: "placement-topology-group-id",
                    limit: limits.maxStringBytes
                )
            }
            if let rolloutGeneration = placement.stability.rolloutGeneration {
                try SchedulerEngineContractValidation.text(
                    rolloutGeneration,
                    field: "placement-rollout-generation",
                    limit: limits.maxStringBytes
                )
            }
        }

        let budgetsByID = Dictionary(uniqueKeysWithValues: disruptionBudgets.map { ($0.budgetID, $0) })
        for budget in disruptionBudgets {
            guard budget.remainingVictimCount <= limits.maxVictimCount else {
                throw SchedulerEngineValidationError.countLimitExceeded(
                    field: "remaining-victim-count",
                    limit: limits.maxVictimCount,
                    actual: budget.remainingVictimCount
                )
            }
            try SchedulerEngineContractValidation.text(
                budget.budgetID,
                field: "disruption-budget-id",
                limit: limits.maxStringBytes
            )
            try SchedulerEngineContractValidation.text(
                budget.projectID,
                field: "disruption-budget-project-id",
                limit: limits.maxStringBytes
            )
        }
        for victim in victimAllocations {
            guard !pendingIDs.contains(victim.workloadID) else {
                throw SchedulerEngineValidationError.invalidPlacement(
                    field: "victim-overlaps-pending",
                    id: victim.workloadID
                )
            }
            guard nodeIDs.contains(victim.nodeID) else {
                throw SchedulerEngineValidationError.unknownReference(
                    field: "victim-node",
                    id: victim.nodeID
                )
            }
            guard let node = nodes.first(where: { $0.nodeID == victim.nodeID }),
                  victim.allocation.fits(in: node.allocation) else {
                throw SchedulerEngineValidationError.invalidPlacement(
                    field: "victim-allocation",
                    id: victim.workloadID
                )
            }
            try SchedulerEngineContractValidation.resourceVector(
                victim.allocation,
                field: "victim-allocation",
                limits: limits
            )
            try SchedulerEngineContractValidation.text(
                victim.subjectID,
                field: "victim-subject-id",
                limit: limits.maxStringBytes
            )
            try SchedulerEngineContractValidation.text(
                victim.projectID,
                field: "victim-project-id",
                limit: limits.maxStringBytes
            )
            if let budgetID = victim.budgetID {
                guard let budget = budgetsByID[budgetID] else {
                    throw SchedulerEngineValidationError.unknownStringReference(
                        field: "victim-budget",
                        value: budgetID
                    )
                }
                guard budget.projectID == victim.projectID else {
                    throw SchedulerEngineValidationError.invalidDecision(
                        "victim-budget-project-mismatch"
                    )
                }
                try SchedulerEngineContractValidation.text(
                    budgetID,
                    field: "disruption-budget-id",
                    limit: limits.maxStringBytes
                )
            }
            if let groupID = victim.topologyGroupID {
                try SchedulerEngineContractValidation.text(
                    groupID,
                    field: "victim-topology-group-id",
                    limit: limits.maxStringBytes
                )
            }
            let occupancy = occupancyTotals[victim.nodeID] ?? .zero
            occupancyTotals[victim.nodeID] = try occupancy.adding(victim.allocation)
        }
        for (nodeID, total) in occupancyTotals {
            guard let node = nodes.first(where: { $0.nodeID == nodeID }), total.fits(in: node.allocation) else {
                throw SchedulerEngineValidationError.invalidPlacement(
                    field: "placement-total-allocation",
                    id: nodeID
                )
            }
        }

        let normalizedPendingWorkloads = pendingWorkloads.sorted {
            SchedulerOrdering.uuidKey($0.workloadID) < SchedulerOrdering.uuidKey($1.workloadID)
        }
        let normalizedNodes = nodes.sorted {
            SchedulerOrdering.uuidKey($0.nodeID) < SchedulerOrdering.uuidKey($1.nodeID)
        }
        let normalizedFairnessStates = fairnessStates.sorted {
            ($0.subjectID, $0.projectID) < ($1.subjectID, $1.projectID)
        }
        let normalizedExistingPlacements = existingPlacements.sorted {
            SchedulerOrdering.uuidKey($0.workloadID) < SchedulerOrdering.uuidKey($1.workloadID)
        }
        let normalizedVictimAllocations = victimAllocations.sorted {
            SchedulerOrdering.uuidKey($0.workloadID) < SchedulerOrdering.uuidKey($1.workloadID)
        }
        let normalizedDisruptionBudgets = disruptionBudgets.sorted { $0.budgetID < $1.budgetID }
        let normalizedOvercommitRatios = overcommitRatios.keys.sorted().reduce(into: [:]) { result, resource in
            result[resource] = overcommitRatios[resource]
        }
        let computedInputDigest = try Self.canonicalDigest(
            pendingWorkloads: normalizedPendingWorkloads,
            nodes: normalizedNodes,
            fairnessStates: normalizedFairnessStates,
            existingPlacements: normalizedExistingPlacements,
            victimAllocations: normalizedVictimAllocations,
            disruptionBudgets: normalizedDisruptionBudgets,
            antiChurnThresholdBasisPoints: antiChurnThresholdBasisPoints,
            scoringWeights: scoringWeights,
            overcommitRatios: normalizedOvercommitRatios,
            preemptionPolicy: preemptionPolicy,
            queuePolicy: queuePolicy,
            stabilityPolicy: stabilityPolicy,
            snapshotQuality: snapshotQuality,
            limits: limits
        )
        guard inputDigest == nil || inputDigest == computedInputDigest else {
            throw SchedulerEngineValidationError.invalidDecision("input-digest-mismatch")
        }
        try SchedulerEngineContractValidation.digest(computedInputDigest, limit: limits.maxDigestBytes)

        self.inputDigest = computedInputDigest
        self.pendingWorkloads = normalizedPendingWorkloads
        self.nodes = normalizedNodes
        self.fairnessStates = normalizedFairnessStates
        self.existingPlacements = normalizedExistingPlacements
        self.victimAllocations = normalizedVictimAllocations
        self.disruptionBudgets = normalizedDisruptionBudgets
        self.antiChurnThresholdBasisPoints = antiChurnThresholdBasisPoints
        self.scoringWeights = scoringWeights
        self.overcommitRatios = normalizedOvercommitRatios
        self.preemptionPolicy = preemptionPolicy
        self.queuePolicy = queuePolicy
        self.stabilityPolicy = stabilityPolicy
        self.snapshotQuality = snapshotQuality
        self.limits = limits
    }

    public var workloads: [SchedulerWorkload] {
        pendingWorkloads
    }

    private static func validateUnique<T: Hashable>(_ values: [T], field: String) throws {
        guard Set(values).count == values.count else {
            throw SchedulerEngineValidationError.duplicateIdentifier(field: field)
        }
    }

    private static func canonicalDigest(
        pendingWorkloads: [SchedulerWorkload],
        nodes: [SchedulerNode],
        fairnessStates: [SchedulerFairnessState],
        existingPlacements: [SchedulerExistingPlacement],
        victimAllocations: [SchedulerVictimAllocation],
        disruptionBudgets: [SchedulerDisruptionBudget],
        antiChurnThresholdBasisPoints: Int64,
        scoringWeights: SchedulerScoreWeights,
        overcommitRatios: [String: SchedulerResourceRatio],
        preemptionPolicy: SchedulerPreemptionPolicy,
        queuePolicy: SchedulerQueuePolicy,
        stabilityPolicy: SchedulerStabilityPolicy,
        snapshotQuality: SchedulerSnapshotQuality,
        limits: SchedulerEngineLimits
    ) throws -> String {
        let material = SchedulerEngineDigestMaterial(
            pendingWorkloads: pendingWorkloads,
            nodes: nodes,
            fairnessStates: fairnessStates,
            existingPlacements: existingPlacements,
            victimAllocations: victimAllocations,
            disruptionBudgets: disruptionBudgets,
            antiChurnThresholdBasisPoints: antiChurnThresholdBasisPoints,
            scoringWeights: scoringWeights,
            overcommitRatios: overcommitRatios,
            preemptionPolicy: preemptionPolicy,
            queuePolicy: queuePolicy,
            stabilityPolicy: stabilityPolicy,
            snapshotQuality: snapshotQuality,
            limits: limits
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(material)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private enum CodingKeys: String, CodingKey {
        case inputDigest
        case pendingWorkloads
        case nodes
        case fairnessStates
        case existingPlacements
        case victimAllocations
        case disruptionBudgets
        case antiChurnThresholdBasisPoints
        case scoringWeights
        case overcommitRatios
        case preemptionPolicy
        case queuePolicy
        case stabilityPolicy
        case snapshotQuality
        case limits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            inputDigest: container.decodeIfPresent(String.self, forKey: .inputDigest),
            pendingWorkloads: container.decodeIfPresent(
                [SchedulerWorkload].self,
                forKey: .pendingWorkloads
            ) ?? [],
            nodes: container.decodeIfPresent([SchedulerNode].self, forKey: .nodes) ?? [],
            fairnessStates: container.decodeIfPresent(
                [SchedulerFairnessState].self,
                forKey: .fairnessStates
            ) ?? [],
            existingPlacements: container.decodeIfPresent(
                [SchedulerExistingPlacement].self,
                forKey: .existingPlacements
            ) ?? [],
            victimAllocations: container.decodeIfPresent(
                [SchedulerVictimAllocation].self,
                forKey: .victimAllocations
            ) ?? [],
            disruptionBudgets: container.decodeIfPresent(
                [SchedulerDisruptionBudget].self,
                forKey: .disruptionBudgets
            ) ?? [],
            antiChurnThresholdBasisPoints: container.decodeIfPresent(
                Int64.self,
                forKey: .antiChurnThresholdBasisPoints
            ) ?? 250,
            scoringWeights: container.decodeIfPresent(
                SchedulerScoreWeights.self,
                forKey: .scoringWeights
            ) ?? .default,
            overcommitRatios: container.decodeIfPresent(
                [String: SchedulerResourceRatio].self,
                forKey: .overcommitRatios
            ) ?? [:],
            preemptionPolicy: container.decodeIfPresent(
                SchedulerPreemptionPolicy.self,
                forKey: .preemptionPolicy
            ) ?? .standard,
            queuePolicy: container.decodeIfPresent(
                SchedulerQueuePolicy.self,
                forKey: .queuePolicy
            ) ?? .standard,
            stabilityPolicy: container.decodeIfPresent(
                SchedulerStabilityPolicy.self,
                forKey: .stabilityPolicy
            ) ?? .standard,
            snapshotQuality: container.decodeIfPresent(
                SchedulerSnapshotQuality.self,
                forKey: .snapshotQuality
            ) ?? .standard,
            limits: container.decodeIfPresent(SchedulerEngineLimits.self, forKey: .limits)
                ?? .default
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputDigest, forKey: .inputDigest)
        try container.encode(pendingWorkloads, forKey: .pendingWorkloads)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(fairnessStates, forKey: .fairnessStates)
        try container.encode(existingPlacements, forKey: .existingPlacements)
        try container.encode(victimAllocations, forKey: .victimAllocations)
        try container.encode(disruptionBudgets, forKey: .disruptionBudgets)
        try container.encode(antiChurnThresholdBasisPoints, forKey: .antiChurnThresholdBasisPoints)
        try container.encode(scoringWeights, forKey: .scoringWeights)
        try container.encode(overcommitRatios, forKey: .overcommitRatios)
        try container.encode(preemptionPolicy, forKey: .preemptionPolicy)
        try container.encode(queuePolicy, forKey: .queuePolicy)
        try container.encode(stabilityPolicy, forKey: .stabilityPolicy)
        try container.encode(snapshotQuality, forKey: .snapshotQuality)
        try container.encode(limits, forKey: .limits)
    }
}

public struct SchedulerEngine: Sendable {
    public init() {}

    public func plan(_ input: SchedulerEngineInput) throws -> SchedulerDecision {
        try makeDecision(input)
    }

    public func simulate(_ input: SchedulerEngineInput) throws -> SchedulerDecision {
        try makeDecision(input)
    }
}

private struct SchedulerEngineNodeState {
    let node: SchedulerNode
    var allocation: ResourceVector

    var nodeID: UUID {
        node.nodeID
    }
}

/// Reuses the validated placement snapshot while a decision is evaluating the
/// same node allocation.  The allocation is part of the key so capacity and
/// availability remain exact as planned placements or preemption victims
/// change the node state.
private final class SchedulerEngineNodeSnapshotCache {
    private struct Entry {
        let allocation: ResourceVector
        let snapshot: NodePlacementSnapshot
    }

    private var entries: [UUID: Entry] = [:]

    func snapshot(
        nodeID: UUID,
        allocation: ResourceVector
    ) -> NodePlacementSnapshot? {
        guard let entry = entries[nodeID], entry.allocation == allocation else {
            return nil
        }
        return entry.snapshot
    }

    func insert(
        nodeID: UUID,
        allocation: ResourceVector,
        snapshot: NodePlacementSnapshot
    ) {
        entries[nodeID] = Entry(allocation: allocation, snapshot: snapshot)
    }
}

private struct SchedulerEngineWorkloadOrder {
    let workload: SchedulerWorkload
    let priority: Int64
    let dominantNormalizedRequest: Int64
    let totalNormalizedRequest: Int64
    let charge: ResourceVector
}

private struct SchedulerEngineQueueKey {
    let orderIndex: Int
    let workloadID: UUID
    let priority: Int64
    let dominantNormalizedRequest: Int64
    let totalNormalizedRequest: Int64
    let fairnessOrderingShare: Int64
    let starvationAgeUnits: Int64
}

private struct SchedulerEngineCandidate {
    let nodeIndex: Int
    let nodeID: UUID
    let score: SchedulerScoreComponents
    let postAllocation: ResourceVector
}

private struct SchedulerEngineObservation {
    let workloadID: UUID
    let nodeID: UUID
    let topologyGroupID: String?
}

private struct SchedulerEngineFairnessKey: Hashable {
    let subjectID: String
    let projectID: String
}

private struct SchedulerEngineBudgetKey: Hashable {
    let projectID: String
    let budgetID: String
}

private struct SchedulerEngineFairnessRecord {
    var usage: ResourceVector
    let guarantee: ResourceVector
    var reclaimableBorrowedUsage: ResourceVector
    let quota: ResourceVector?
    let pendingDemand: ResourceVector
    let starvationAgeUnits: Int64
    let weight: Int64
}

private struct SchedulerEngineFairnessContext {
    let records: [SchedulerEngineFairnessKey: SchedulerEngineFairnessRecord]
    let guaranteeShares: [SchedulerEngineFairnessKey: Int64]
    let unusedGuaranteeByKey: [SchedulerEngineFairnessKey: Int64]
    let totalUnusedGuarantee: Int64
    let weightedShares: [SchedulerEngineFairnessKey: Int64]
}

private struct SchedulerEngineTopologySpreadKey: Hashable {
    let spreadKey: String
    let groupID: String?
}

private struct SchedulerEngineTopologyIndex {
    static let empty = SchedulerEngineTopologyIndex(
        observationsByNodeID: [:],
        spreadCounts: [:],
        availableDomainsBySpreadKey: [:]
    )

    let observationsByNodeID: [UUID: Set<UUID>]
    let spreadCounts: [SchedulerEngineTopologySpreadKey: [String: Int64]]
    let availableDomainsBySpreadKey: [String: Set<String>]
}

private struct SchedulerEngineFairnessMetrics {
    let projectedShare: Int64
    let guaranteeShare: Int64
    let borrowingBasisPoints: Int64
    let weightedShare: Int64
}

private struct SchedulerEnginePreemptionCandidate {
    let nodeID: UUID
    let victims: [SchedulerVictimAllocation]
    let cost: Int64
}

private enum SchedulerExactPreemptionSearchResult {
    case complete(SchedulerEnginePreemptionCandidate?)
    case stateBudgetExhausted(exploredStates: Int)
}

private extension SchedulerEngine {
    func makeDecision(_ input: SchedulerEngineInput) throws -> SchedulerDecision {
        let maxima = try clusterMaxima(nodes: input.nodes)
        let initialFairness = Dictionary(
            uniqueKeysWithValues: input.fairnessStates.map {
                (
                    SchedulerEngineFairnessKey(
                        subjectID: $0.subjectID,
                        projectID: $0.projectID
                    ),
                    SchedulerEngineFairnessRecord(
                        usage: $0.usage,
                        guarantee: $0.guarantee,
                        reclaimableBorrowedUsage: $0.reclaimableBorrowedUsage,
                        quota: $0.quota,
                        pendingDemand: $0.pendingDemand,
                        starvationAgeUnits: $0.starvationAgeUnits,
                        weight: $0.weight
                    )
                )
            }
        )
        let orders = try input.pendingWorkloads.map { workload in
            let charge = try capacityCharge(for: workload, input: input)
            let metrics = try normalizedRequestMetrics(charge: charge, maxima: maxima)
            return SchedulerEngineWorkloadOrder(
                workload: workload,
                priority: workload.priority,
                dominantNormalizedRequest: metrics.dominant,
                totalNormalizedRequest: metrics.total,
                charge: charge
            )
        }

        var nodeStates = input.nodes.map {
            SchedulerEngineNodeState(node: $0, allocation: $0.allocation)
        }
        let nodeTopologyDomains = input.nodes.reduce(into: [:]) { result, node in
            result[node.nodeID] = node.topologyDomains
        }
        var fairness = initialFairness
        var observations = makeInitialObservations(input: input)
        var remainingOrders = orders
        var plannedVictimIDs: Set<UUID> = []
        var plannedBudgetVictimCounts: [SchedulerEngineBudgetKey: Int] = [:]
        var plannedBudgetCosts: [SchedulerEngineBudgetKey: Int64] = [:]
        var decisions: [SchedulerWorkloadDecision] = []
        decisions.reserveCapacity(orders.count)
        let nodeSnapshotCache = SchedulerEngineNodeSnapshotCache()

        while !remainingOrders.isEmpty {
            let fairnessContext = try makeFairnessContext(
                fairness: fairness,
                maxima: maxima
            )
            let nextIndex = try nextWorkloadIndex(
                orders: remainingOrders,
                fairnessContext: fairnessContext,
                maxima: maxima,
                existingPlacements: input.existingPlacements,
                queuePolicy: input.queuePolicy
            )
            // The queue comparator is a total order on the canonical fields
            // (fair class, BFD metrics, then UUID); the array position is only
            // used to return the selected slot. Replacing that slot with the
            // last order avoids an O(n) shift without changing the decision
            // sequence or any serialized explanation fields.
            let order = remainingOrders[nextIndex]
            let lastOrder = remainingOrders.removeLast()
            if nextIndex < remainingOrders.count {
                remainingOrders[nextIndex] = lastOrder
            }
            let workload = order.workload
            let existing = input.existingPlacements.first {
                $0.workloadID == workload.workloadID
            }
            let baselineStates = try removingExistingPlacement(
                existing,
                from: nodeStates
            )
            let baselineFairness = try removingExistingFairness(
                existing,
                workload: workload,
                from: fairness
            )
            let baselineFairnessContext = existing == nil
                ? fairnessContext
                : try makeFairnessContext(
                    fairness: baselineFairness,
                    maxima: maxima
                )
            let chargedRequirements = try chargedRequirements(
                for: workload,
                charge: order.charge
            )
            let hardTopologyContext: HardTopologySpreadContext?
            if chargedRequirements.affinity.topologySpreads.isEmpty {
                hardTopologyContext = nil
            } else {
                hardTopologyContext = try topologyContext(
                    nodeTopologyDomains: nodeTopologyDomains,
                    observations: observations.filter {
                        $0.workloadID != workload.workloadID
                    }
                )
            }
            let topologyIndex: SchedulerEngineTopologyIndex
            if workload.topology.spreadKey != nil
                || !workload.topology.affinityWorkloadIDs.isEmpty
                || !workload.topology.antiAffinityWorkloadIDs.isEmpty {
                topologyIndex = makeTopologyIndex(
                    states: baselineStates,
                    observations: observations,
                    excluding: workload.workloadID
                )
            } else {
                topologyIndex = .empty
            }

            var failures: [SchedulerFilterFailure] = []
            var candidates: [SchedulerEngineCandidate] = []
            for index in baselineStates.indices {
                let state = baselineStates[index]
                var filterFailures = try evaluateHardFilters(
                    workload: workload,
                    chargedRequirements: chargedRequirements,
                    node: state.node,
                    allocation: state.allocation,
                    topologyContext: hardTopologyContext,
                    snapshotCache: nodeSnapshotCache
                )
                let quotaFailures = try quotaFailures(
                    workload: workload,
                    charge: order.charge,
                    nodeID: state.nodeID,
                    fairness: baselineFairness
                )
                if !quotaFailures.isEmpty {
                    filterFailures.append(contentsOf: quotaFailures)
                    filterFailures.sort { $0.orderingKey < $1.orderingKey }
                }
                failures.append(contentsOf: filterFailures)
                guard filterFailures.isEmpty else {
                    continue
                }
                let postAllocation = try state.allocation.adding(order.charge)
                let score = try score(
                    workload: workload,
                    charge: order.charge,
                    node: state.node,
                    postAllocation: postAllocation,
                    maxima: maxima,
                    fairnessContext: baselineFairnessContext,
                    topologyIndex: topologyIndex,
                    existingPlacement: existing,
                    weights: input.scoringWeights
                )
                candidates.append(
                    SchedulerEngineCandidate(
                        nodeIndex: index,
                        nodeID: state.nodeID,
                        score: score,
                        postAllocation: postAllocation
                    )
                )
            }
            failures.sort { $0.orderingKey < $1.orderingKey }
            let sortedCandidates = candidates.sorted(by: candidatePrecedes)

            if !sortedCandidates.isEmpty {
                let selected = try selectCandidate(
                    sortedCandidates,
                    existingPlacement: existing,
                    threshold: input.antiChurnThresholdBasisPoints,
                    stabilityPolicy: input.stabilityPolicy,
                    states: baselineStates
                )
                nodeStates = baselineStates
                nodeStates[selected.nodeIndex].allocation = selected.postAllocation
                fairness = try addingFairness(
                    charge: order.charge,
                    workload: workload,
                    to: baselineFairness
                )
                observations = updatedObservations(
                    observations,
                    removing: workload.workloadID,
                    adding: SchedulerEngineObservation(
                        workloadID: workload.workloadID,
                        nodeID: nodeStates[selected.nodeIndex].nodeID,
                        topologyGroupID: workload.topology.groupID
                    )
                )
                let retained = existing?.nodeID == nodeStates[selected.nodeIndex].nodeID
                let outcome: SchedulerDecisionOutcome = retained
                    ? .retainedExistingPlacement
                    : .placed
                let alternatives = alternatives(
                    candidates: sortedCandidates,
                    selected: selected,
                    limits: input.limits,
                    maxCount: input.stabilityPolicy.maxReconsiderationCount
                )
                let explanation = try placementExplanation(
                    outcome: outcome,
                    workloadID: workload.workloadID,
                    nodeID: nodeStates[selected.nodeIndex].nodeID,
                    topology: workload.topology,
                    failures: failures,
                    alternatives: alternatives,
                    charge: order.charge,
                    rawRequest: workload.request,
                    declaredLimit: workload.requirements.limit
                )
                let tieBreak = try placementTieBreak(
                    selected: selected,
                    candidates: sortedCandidates,
                    existingPlacement: existing,
                    threshold: input.antiChurnThresholdBasisPoints
                )
                decisions.append(
                    try SchedulerWorkloadDecision(
                        workloadID: workload.workloadID,
                        outcome: outcome,
                        chosenNodeID: nodeStates[selected.nodeIndex].nodeID,
                        scoreComponents: selected.score,
                        feasibleAlternatives: alternatives,
                        filterFailures: failures,
                        preemption: nil,
                        explanation: explanation,
                        capacityExplanation: try capacityExplanation(
                            workload: workload,
                            charge: order.charge,
                            overcommitRatios: input.overcommitRatios
                        ),
                        fairnessExplanation: try fairnessExplanation(
                            workload: workload,
                            charge: order.charge,
                            maxima: maxima,
                            fairnessContext: baselineFairnessContext
                        ),
                        tieBreak: tieBreak,
                        snapshotQuality: input.snapshotQuality,
                        limits: input.limits
                    )
                )
                continue
            }

            if let proposal = try preemptionProposal(
                input: input,
                workload: workload,
                charge: order.charge,
                baselineStates: baselineStates,
                observations: observations,
                topologyDomains: nodeTopologyDomains,
                failures: &failures,
                plannedVictimIDs: plannedVictimIDs,
                plannedBudgetVictimCounts: plannedBudgetVictimCounts,
                plannedBudgetCosts: plannedBudgetCosts,
                snapshotCache: nodeSnapshotCache
            ) {
                for victim in proposal.victims {
                    plannedVictimIDs.insert(victim.workloadID)
                    if let budgetID = victim.budgetID {
                        let budgetKey = SchedulerEngineBudgetKey(
                            projectID: victim.projectID,
                            budgetID: budgetID
                        )
                        plannedBudgetVictimCounts[budgetKey, default: 0] += 1
                        plannedBudgetCosts[budgetKey, default: 0] = try SchedulerCheckedMath.add(
                            plannedBudgetCosts[budgetKey, default: 0],
                            victim.disruptionCostBasisPoints,
                            field: "planned-budget-cost"
                        )
                    }
                }
                let explanation = try preemptionDecisionExplanation(
                    workloadID: workload.workloadID,
                    topology: workload.topology,
                    failures: failures,
                    proposal: proposal,
                    charge: order.charge,
                    rawRequest: workload.request,
                    declaredLimit: workload.requirements.limit
                )
                decisions.append(
                    try SchedulerWorkloadDecision(
                        workloadID: workload.workloadID,
                        outcome: .preemptionProposed,
                        chosenNodeID: nil,
                        scoreComponents: nil,
                        feasibleAlternatives: [],
                        filterFailures: failures,
                        preemption: proposal,
                        explanation: explanation,
                        capacityExplanation: try capacityExplanation(
                            workload: workload,
                            charge: order.charge,
                            overcommitRatios: input.overcommitRatios
                        ),
                        fairnessExplanation: try fairnessExplanation(
                            workload: workload,
                            charge: order.charge,
                            maxima: maxima,
                            fairnessContext: baselineFairnessContext
                        ),
                        tieBreak: try SchedulerTieBreakExplanation(
                            reason: .preemptionMinimumDisruption,
                            chosenNodeID: proposal.nodeID
                        ),
                        snapshotQuality: input.snapshotQuality,
                        limits: input.limits
                    )
                )
                continue
            }

            let explanation = try unschedulableExplanation(
                workloadID: workload.workloadID,
                topology: workload.topology,
                failures: failures,
                charge: order.charge,
                rawRequest: workload.request,
                declaredLimit: workload.requirements.limit
            )
            decisions.append(
                try SchedulerWorkloadDecision(
                    workloadID: workload.workloadID,
                    outcome: .unschedulable,
                    chosenNodeID: nil,
                    scoreComponents: nil,
                    feasibleAlternatives: [],
                    filterFailures: failures,
                    preemption: nil,
                    explanation: explanation,
                    capacityExplanation: try capacityExplanation(
                        workload: workload,
                        charge: order.charge,
                        overcommitRatios: input.overcommitRatios
                    ),
                fairnessExplanation: try fairnessExplanation(
                    workload: workload,
                    charge: order.charge,
                    maxima: maxima,
                    fairnessContext: baselineFairnessContext
                    ),
                    tieBreak: try SchedulerTieBreakExplanation(
                        reason: .noFeasibleNode,
                        chosenNodeID: nil
                    ),
                    snapshotQuality: input.snapshotQuality,
                    limits: input.limits
                )
            )
        }

        let orderedIDs = decisions.map(\.workloadID)
        return try SchedulerDecision(
            decisionID: stableDecisionID(
                inputDigest: input.inputDigest,
                orderedIDs: orderedIDs,
                decisions: decisions
            ),
            inputDigest: input.inputDigest,
            orderedWorkloadIDs: orderedIDs,
            workloadDecisions: decisions,
            snapshotQuality: input.snapshotQuality,
            limits: input.limits
        )
    }
}

private extension SchedulerEngine {
    func nextWorkloadIndex(
        orders: [SchedulerEngineWorkloadOrder],
        fairnessContext: SchedulerEngineFairnessContext,
        maxima: [String: Int64],
        existingPlacements: [SchedulerExistingPlacement],
        queuePolicy: SchedulerQueuePolicy
    ) throws -> Int {
        var selected: SchedulerEngineQueueKey?
        for (index, order) in orders.enumerated() {
            let existing = existingPlacements.first {
                $0.workloadID == order.workload.workloadID
            }
            let queueFairnessContext: SchedulerEngineFairnessContext
            if let existing {
                let queueFairness = try removingExistingFairness(
                    existing,
                    workload: order.workload,
                    from: fairnessContext.records
                )
                queueFairnessContext = try makeFairnessContext(
                    fairness: queueFairness,
                    maxima: maxima
                )
            } else {
                queueFairnessContext = fairnessContext
            }
            let key = SchedulerEngineFairnessKey(
                subjectID: order.workload.subjectID,
                projectID: order.workload.projectID
            )
            let fairnessRecord = queueFairnessContext.records[key]
            let queueKey = SchedulerEngineQueueKey(
                orderIndex: index,
                workloadID: order.workload.workloadID,
                priority: order.priority,
                dominantNormalizedRequest: order.dominantNormalizedRequest,
                totalNormalizedRequest: order.totalNormalizedRequest,
                fairnessOrderingShare: try fairnessOrderingShare(
                    workload: order.workload,
                    charge: order.charge,
                    maxima: maxima,
                    fairnessContext: queueFairnessContext
                ),
                starvationAgeUnits: fairnessRecord?.starvationAgeUnits ?? 0
            )
            guard let current = selected else {
                selected = queueKey
                continue
            }
            if fairQueueClassPrecedes(queueKey, current, policy: queuePolicy)
                || (fairQueueClassEqual(queueKey, current, policy: queuePolicy)
                    && bfdQueueKeyPrecedes(queueKey, current)) {
                selected = queueKey
            }
        }
        return selected!.orderIndex
    }

    func makeFairnessContext(
        fairness: [SchedulerEngineFairnessKey: SchedulerEngineFairnessRecord],
        maxima: [String: Int64]
    ) throws -> SchedulerEngineFairnessContext {
        var guaranteeShares: [SchedulerEngineFairnessKey: Int64] = [:]
        var unusedGuaranteeByKey: [SchedulerEngineFairnessKey: Int64] = [:]
        var totalUnusedGuarantee: Int64 = 0

        let orderedKeys = fairness.keys.sorted {
            if $0.subjectID != $1.subjectID {
                return $0.subjectID < $1.subjectID
            }
            return $0.projectID < $1.projectID
        }
        for key in orderedKeys {
            guard let record = fairness[key] else {
                continue
            }
            let usageShare = try dominantShare(record.usage, maxima: maxima)
            let guaranteeShare = try dominantShare(record.guarantee, maxima: maxima)
            let unused = record.pendingDemand.resourceNames.isEmpty
                ? max(0, guaranteeShare - usageShare)
                : 0
            guaranteeShares[key] = guaranteeShare
            unusedGuaranteeByKey[key] = unused
            totalUnusedGuarantee = try SchedulerCheckedMath.add(
                totalUnusedGuarantee,
                unused,
                field: "fairness-borrowing"
            )
        }
        var weightedShares: [SchedulerEngineFairnessKey: Int64] = [:]
        weightedShares.reserveCapacity(orderedKeys.count)
        for key in orderedKeys {
            guard let record = fairness[key] else {
                continue
            }
            let projectedShare = try dominantShare(record.usage, maxima: maxima)
            let guaranteeShare = guaranteeShares[key] ?? 0
            let ownUnusedGuarantee = unusedGuaranteeByKey[key] ?? 0
            let unusedGuarantee = try SchedulerCheckedMath.subtract(
                totalUnusedGuarantee,
                ownUnusedGuarantee,
                field: "fairness-borrowing"
            )
            let excess = max(0, projectedShare - guaranteeShare)
            let borrowing = min(excess, unusedGuarantee)
            let effectiveShare = projectedShare - borrowing
            let weightedShare = try SchedulerCheckedMath.ceilDivide(
                effectiveShare,
                by: record.weight,
                field: "weighted-drf-share"
            )
            weightedShares[key] = min(
                SchedulerEngineContractValidation.scale,
                weightedShare
            )
        }
        return SchedulerEngineFairnessContext(
            records: fairness,
            guaranteeShares: guaranteeShares,
            unusedGuaranteeByKey: unusedGuaranteeByKey,
            totalUnusedGuarantee: totalUnusedGuarantee,
            weightedShares: weightedShares
        )
    }

    /// Compares workloads after the dynamic fair-eligibility class has been
    /// selected. This is the canonical stable multi-resource BFD order; node
    /// scoring and fairness accounting never silently reorder this item list.
    func queueKeyPrecedes(
        _ lhs: SchedulerEngineQueueKey,
        _ rhs: SchedulerEngineQueueKey
    ) -> Bool {
        bfdQueueKeyPrecedes(lhs, rhs)
    }

    private func bfdQueueKeyPrecedes(
        _ lhs: SchedulerEngineQueueKey,
        _ rhs: SchedulerEngineQueueKey
    ) -> Bool {
        if lhs.dominantNormalizedRequest != rhs.dominantNormalizedRequest {
            return lhs.dominantNormalizedRequest > rhs.dominantNormalizedRequest
        }
        if lhs.totalNormalizedRequest != rhs.totalNormalizedRequest {
            return lhs.totalNormalizedRequest > rhs.totalNormalizedRequest
        }
        return SchedulerOrdering.uuidKey(lhs.workloadID)
            < SchedulerOrdering.uuidKey(rhs.workloadID)
    }

    private func fairQueueClassPrecedes(
        _ lhs: SchedulerEngineQueueKey,
        _ rhs: SchedulerEngineQueueKey,
        policy: SchedulerQueuePolicy
    ) -> Bool {
        let starvationThreshold = policy.starvationAgeThresholdUnits
        if starvationThreshold > 0 {
            let lhsProtected = lhs.starvationAgeUnits >= starvationThreshold
            let rhsProtected = rhs.starvationAgeUnits >= starvationThreshold
            if lhsProtected != rhsProtected {
                return lhsProtected
            }
        }
        if policy.priorityPrecedesFairness, lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        if lhs.fairnessOrderingShare != rhs.fairnessOrderingShare {
            return lhs.fairnessOrderingShare < rhs.fairnessOrderingShare
        }
        if lhs.starvationAgeUnits != rhs.starvationAgeUnits {
            return lhs.starvationAgeUnits > rhs.starvationAgeUnits
        }
        if !policy.priorityPrecedesFairness, lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        return false
    }

    private func fairQueueClassEqual(
        _ lhs: SchedulerEngineQueueKey,
        _ rhs: SchedulerEngineQueueKey,
        policy: SchedulerQueuePolicy
    ) -> Bool {
        !fairQueueClassPrecedes(lhs, rhs, policy: policy)
            && !fairQueueClassPrecedes(rhs, lhs, policy: policy)
    }

    func clusterMaxima(nodes: [SchedulerNode]) throws -> [String: Int64] {
        var maxima: [String: Int64] = [:]
        for node in nodes {
            for resource in node.capacity.resourceNames {
                maxima[resource] = max(maxima[resource] ?? 0, node.capacity[resource])
            }
        }
        return maxima
    }

    func capacityCharge(
        for workload: SchedulerWorkload,
        input: SchedulerEngineInput
    ) throws -> ResourceVector {
        let request = workload.requirements.request
        let limit = workload.requirements.limit
        let resources = Set(request.resourceNames)
            .union(limit?.resourceNames ?? [])
            .union(workload.overhead.resourceNames)
            .union(workload.safetyMargin.resourceNames)
            .sorted()
        var values: [String: Int64] = [:]
        for resource in resources {
            let requested = request[resource]
            guard let declaredLimit = limit?[resource] else {
                let base = requested
                let withOverhead = try SchedulerCheckedMath.add(
                    base,
                    workload.overhead[resource],
                    field: "workload-overhead-charge:\(resource)"
                )
                let charge = try SchedulerCheckedMath.add(
                    withOverhead,
                    workload.safetyMargin[resource],
                    field: "workload-safety-charge:\(resource)"
                )
                if charge > 0 {
                    values[resource] = charge
                }
                continue
            }
            let ratio = input.overcommitRatios[resource] ?? .one
            let scaledLimit = try SchedulerCheckedMath.multiply(
                declaredLimit,
                ratio.denominator,
                field: "limit-charge:\(resource)"
            )
            let ratioCharge = try SchedulerCheckedMath.ceilDivide(
                scaledLimit,
                by: ratio.numerator,
                field: "limit-charge:\(resource)"
            )
            let base = max(requested, ratioCharge)
            let withOverhead = try SchedulerCheckedMath.add(
                base,
                workload.overhead[resource],
                field: "workload-overhead-charge:\(resource)"
            )
            let charge = try SchedulerCheckedMath.add(
                withOverhead,
                workload.safetyMargin[resource],
                field: "workload-safety-charge:\(resource)"
            )
            if charge > 0 {
                values[resource] = charge
            }
        }
        return try ResourceVector(values)
    }

    func chargedRequirements(
        for workload: SchedulerWorkload,
        charge: ResourceVector
    ) throws -> WorkloadPlacementRequirements {
        try WorkloadPlacementRequirements(
            workloadID: workload.workloadID,
            resources: WorkloadResourceSnapshot(request: charge),
            requiredArchitectures: workload.requirements.requiredArchitectures,
            requiredRuntime: workload.requirements.requiredRuntime,
            requiredProvider: workload.requirements.requiredProvider,
            requiredCapabilities: workload.requirements.requiredCapabilities,
            affinity: workload.requirements.affinity,
            tolerations: workload.requirements.tolerations,
            acceleratorRequirements: workload.requirements.acceleratorRequirements
        )
    }

    func normalizedRequestMetrics(
        charge: ResourceVector,
        maxima: [String: Int64]
    ) throws -> (dominant: Int64, total: Int64) {
        var dominant: Int64 = 0
        var total: Int64 = 0
        for resource in charge.resourceNames {
            let value = try normalizedQuantity(
                charge[resource],
                maximum: maxima[resource] ?? 0,
                ceiling: true,
                field: "workload-normalization:\(resource)"
            )
            dominant = max(dominant, value)
            total = try SchedulerCheckedMath.add(
                total,
                value,
                field: "workload-total-normalization"
            )
        }
        return (dominant, total)
    }

    func normalizedQuantity(
        _ value: Int64,
        maximum: Int64,
        ceiling: Bool,
        field: String
    ) throws -> Int64 {
        guard value >= 0 else {
            throw SchedulerEngineValidationError.invalidValue(field: field, value: value)
        }
        guard value > 0 else {
            return 0
        }
        guard maximum > 0 else {
            return SchedulerEngineContractValidation.scale
        }
        let numerator = try SchedulerCheckedMath.multiply(
            value,
            SchedulerEngineContractValidation.scale,
            field: field
        )
        if ceiling {
            return try SchedulerCheckedMath.ceilDivide(numerator, by: maximum, field: field)
        }
        return numerator / maximum
    }

    func makeInitialObservations(
        input: SchedulerEngineInput
    ) -> [SchedulerEngineObservation] {
        var values: [UUID: SchedulerEngineObservation] = [:]
        for placement in input.existingPlacements {
            values[placement.workloadID] = SchedulerEngineObservation(
                workloadID: placement.workloadID,
                nodeID: placement.nodeID,
                topologyGroupID: placement.topologyGroupID
            )
        }
        for victim in input.victimAllocations where values[victim.workloadID] == nil {
            values[victim.workloadID] = SchedulerEngineObservation(
                workloadID: victim.workloadID,
                nodeID: victim.nodeID,
                topologyGroupID: victim.topologyGroupID
            )
        }
        return values.values.sorted {
            SchedulerOrdering.uuidKey($0.workloadID) < SchedulerOrdering.uuidKey($1.workloadID)
        }
    }

    func topologyContext(
        input: SchedulerEngineInput,
        observations: [SchedulerEngineObservation],
        excluding workloadID: UUID?
    ) throws -> HardTopologySpreadContext {
        try topologyContext(
            nodeTopologyDomains: input.nodes.reduce(into: [:]) { result, node in
                result[node.nodeID] = node.topologyDomains
            },
            observations: observations.filter { $0.workloadID != workloadID }
        )
    }

    func topologyContext(
        nodeTopologyDomains: [UUID: [String: String]],
        observations: [SchedulerEngineObservation]
    ) throws -> HardTopologySpreadContext {
        try HardTopologySpreadContext(
            nodeTopologyDomains: nodeTopologyDomains,
            observations: try observations.map {
                try HardTopologySpreadObservation(
                    workloadID: $0.workloadID,
                    nodeID: $0.nodeID,
                    groupID: $0.topologyGroupID
                )
            }
        )
    }

    func makeTopologyIndex(
        states: [SchedulerEngineNodeState],
        observations: [SchedulerEngineObservation],
        excluding workloadID: UUID
    ) -> SchedulerEngineTopologyIndex {
        let domainsByNodeID = Dictionary(
            uniqueKeysWithValues: states.map { ($0.nodeID, $0.node.topologyDomains) }
        )
        var observationsByNodeID: [UUID: Set<UUID>] = [:]
        var spreadCounts: [SchedulerEngineTopologySpreadKey: [String: Int64]] = [:]
        var availableDomainsBySpreadKey: [String: Set<String>] = [:]

        for domains in domainsByNodeID.values {
            for (spreadKey, value) in domains {
                availableDomainsBySpreadKey[spreadKey, default: []].insert(value)
            }
        }
        for observation in observations where observation.workloadID != workloadID {
            observationsByNodeID[observation.nodeID, default: []].insert(observation.workloadID)
            guard let domains = domainsByNodeID[observation.nodeID] else {
                continue
            }
            for (spreadKey, value) in domains {
                let allGroupsKey = SchedulerEngineTopologySpreadKey(
                    spreadKey: spreadKey,
                    groupID: nil
                )
                spreadCounts[allGroupsKey, default: [:]][value, default: 0] += 1
                if let groupID = observation.topologyGroupID {
                    let groupKey = SchedulerEngineTopologySpreadKey(
                        spreadKey: spreadKey,
                        groupID: groupID
                    )
                    spreadCounts[groupKey, default: [:]][value, default: 0] += 1
                }
            }
        }
        return SchedulerEngineTopologyIndex(
            observationsByNodeID: observationsByNodeID,
            spreadCounts: spreadCounts,
            availableDomainsBySpreadKey: availableDomainsBySpreadKey
        )
    }

    func removingExistingPlacement(
        _ placement: SchedulerExistingPlacement?,
        from states: [SchedulerEngineNodeState]
    ) throws -> [SchedulerEngineNodeState] {
        guard let placement else {
            return states
        }
        var result = states
        guard let index = result.firstIndex(where: { $0.nodeID == placement.nodeID }) else {
            throw SchedulerEngineValidationError.unknownReference(
                field: "existing-placement-node",
                id: placement.nodeID
            )
        }
        result[index].allocation = try result[index].allocation.subtracting(placement.allocation)
        return result
    }

    func removingExistingFairness(
        _ placement: SchedulerExistingPlacement?,
        workload: SchedulerWorkload,
        from fairness: [SchedulerEngineFairnessKey: SchedulerEngineFairnessRecord]
    ) throws -> [SchedulerEngineFairnessKey: SchedulerEngineFairnessRecord] {
        guard let placement else {
            return fairness
        }
        var result = fairness
        let key = SchedulerEngineFairnessKey(
            subjectID: workload.subjectID,
            projectID: workload.projectID
        )
        if let record = result[key], placement.allocation.fits(in: record.usage) {
            result[key] = SchedulerEngineFairnessRecord(
                usage: try record.usage.subtracting(placement.allocation),
                guarantee: record.guarantee,
                reclaimableBorrowedUsage: placement.allocation.fits(in: record.reclaimableBorrowedUsage)
                    ? try record.reclaimableBorrowedUsage.subtracting(placement.allocation)
                    : .zero,
                quota: record.quota,
                pendingDemand: record.pendingDemand,
                starvationAgeUnits: record.starvationAgeUnits,
                weight: record.weight
            )
        }
        return result
    }

    func addingFairness(
        charge: ResourceVector,
        workload: SchedulerWorkload,
        to fairness: [SchedulerEngineFairnessKey: SchedulerEngineFairnessRecord]
    ) throws -> [SchedulerEngineFairnessKey: SchedulerEngineFairnessRecord] {
        var result = fairness
        let key = SchedulerEngineFairnessKey(
            subjectID: workload.subjectID,
            projectID: workload.projectID
        )
        let record = result[key] ?? SchedulerEngineFairnessRecord(
            usage: .zero,
            guarantee: .zero,
            reclaimableBorrowedUsage: .zero,
            quota: nil,
            pendingDemand: .zero,
            starvationAgeUnits: 0,
            weight: 1
        )
        let projectedUsage = try record.usage.adding(charge)
        let borrowedCharge = charge.resourceNames.contains {
            projectedUsage[$0] > record.guarantee[$0]
        } ? charge : .zero
        result[key] = SchedulerEngineFairnessRecord(
            usage: projectedUsage,
            guarantee: record.guarantee,
            reclaimableBorrowedUsage: try record.reclaimableBorrowedUsage.adding(borrowedCharge),
            quota: record.quota,
            pendingDemand: record.pendingDemand,
            starvationAgeUnits: record.starvationAgeUnits,
            weight: record.weight
        )
        return result
    }

    func updatedObservations(
        _ observations: [SchedulerEngineObservation],
        removing workloadID: UUID,
        adding observation: SchedulerEngineObservation
    ) -> [SchedulerEngineObservation] {
        var result = observations.filter { $0.workloadID != workloadID }
        result.append(observation)
        return result.sorted {
            SchedulerOrdering.uuidKey($0.workloadID) < SchedulerOrdering.uuidKey($1.workloadID)
        }
    }

    func nodeSnapshot(
        _ state: SchedulerEngineNodeState,
        cache: SchedulerEngineNodeSnapshotCache? = nil
    ) throws -> NodePlacementSnapshot {
        if let cache, let snapshot = cache.snapshot(
            nodeID: state.nodeID,
            allocation: state.allocation
        ) {
            return snapshot
        }
        let snapshot = try NodePlacementSnapshot(
            nodeID: state.nodeID,
            capacity: state.node.capacity,
            allocation: state.allocation,
            architecture: state.node.snapshot.architecture,
            runtime: state.node.snapshot.runtime,
            provider: state.node.snapshot.provider,
            capabilities: state.node.snapshot.capabilities,
            health: state.node.snapshot.health,
            maintenance: state.node.snapshot.maintenance,
            labels: state.node.snapshot.labels,
            taints: state.node.snapshot.taints,
            acceleratorAvailability: state.node.snapshot.acceleratorAvailability
        )
        cache?.insert(
            nodeID: state.nodeID,
            allocation: state.allocation,
            snapshot: snapshot
        )
        return snapshot
    }
}

private extension SchedulerEngine {
    func evaluateHardFilters(
        workload: SchedulerWorkload,
        chargedRequirements: WorkloadPlacementRequirements,
        node: SchedulerNode,
        allocation: ResourceVector,
        topologyContext: HardTopologySpreadContext? = nil,
        snapshotCache: SchedulerEngineNodeSnapshotCache? = nil
    ) throws -> [SchedulerFilterFailure] {
        let state = SchedulerEngineNodeState(node: node, allocation: allocation)
        let snapshot = try nodeSnapshot(state, cache: snapshotCache)
        let placementResult = HardPlacementFilterEvaluator().evaluate(
            workload: chargedRequirements,
            on: snapshot,
            topologyContext: topologyContext
        )
        var failures = try placementResult.reasons.map { reason in
            try SchedulerFilterFailure(
                filter: mapFilter(reason.filter),
                code: mapFilterCode(reason.code),
                workloadID: reason.workloadID,
                nodeID: reason.nodeID,
                stableDetailKey: reason.stableDetailKey,
                message: reason.message
            )
        }
        let availableVolumes = Set(node.availableVolumeIDs)
        for volume in workload.constraints.requiredVolumes where !availableVolumes.contains(volume) {
            failures.append(
                try SchedulerFilterFailure(
                    filter: .volumeAvailability,
                    code: .volumeUnavailable,
                    workloadID: workload.workloadID,
                    nodeID: node.nodeID,
                    stableDetailKey: "volume:\(volume)",
                    message: "Required volume \(volume) is unavailable on node."
                )
            )
        }
        let availablePorts = Set(node.availablePorts)
        for port in workload.constraints.requiredPorts where !availablePorts.contains(port) {
            failures.append(
                try SchedulerFilterFailure(
                    filter: .portAvailability,
                    code: .portUnavailable,
                    workloadID: workload.workloadID,
                    nodeID: node.nodeID,
                    stableDetailKey: "port:\(port)",
                    message: "Required port \(port) is unavailable on node."
                )
            )
        }
        let availableNetworks = Set(node.availableNetworkIDs)
        for network in workload.constraints.requiredNetworks where !availableNetworks.contains(network) {
            failures.append(
                try SchedulerFilterFailure(
                    filter: .networkAvailability,
                    code: .networkUnavailable,
                    workloadID: workload.workloadID,
                    nodeID: node.nodeID,
                    stableDetailKey: "network:\(network)",
                    message: "Required network \(network) is unavailable on node."
                )
            )
        }
        switch node.posture.pressure {
        case .critical, .unknown, .unavailable:
            let posture = node.posture.pressure.rawValue
            failures.append(
                try SchedulerFilterFailure(
                    filter: .hostPressureEnergy,
                    code: .pressureUnavailable,
                    workloadID: workload.workloadID,
                    nodeID: node.nodeID,
                    stableDetailKey: "pressure:\(posture)",
                    message: "Node pressure posture \(posture) is unavailable for admission."
                )
            )
        case .nominal, .elevated:
            break
        }
        return failures.sorted { $0.orderingKey < $1.orderingKey }
    }

    func quotaFailures(
        workload: SchedulerWorkload,
        charge: ResourceVector,
        nodeID: UUID,
        fairness: [SchedulerEngineFairnessKey: SchedulerEngineFairnessRecord]
    ) throws -> [SchedulerFilterFailure] {
        let key = SchedulerEngineFairnessKey(
            subjectID: workload.subjectID,
            projectID: workload.projectID
        )
        guard let record = fairness[key], let quota = record.quota else {
            return []
        }
        let projected = try record.usage.adding(charge)
        return try quota.resourceNames.compactMap { resource in
            guard projected[resource] > quota[resource] else {
                return nil
            }
            return try SchedulerFilterFailure(
                filter: .quota,
                code: .quotaExceeded,
                workloadID: workload.workloadID,
                nodeID: nodeID,
                stableDetailKey: "quota:\(resource):limit:\(quota[resource]):projected:\(projected[resource])",
                message: "Subject/project quota for \(resource) would be exceeded by this placement."
            )
        }.sorted { $0.orderingKey < $1.orderingKey }
    }

    func mapFilter(_ filter: HardPlacementFilterKind) -> SchedulerFilterKind {
        switch filter {
        case .capacity:
            .capacity
        case .architecture:
            .architecture
        case .runtimeProvider:
            .runtimeProvider
        case .capabilities:
            .capabilities
        case .healthMaintenance:
            .healthMaintenance
        case .labelsAffinity:
            .labelsAffinity
        case .taintsTolerations:
            .taintsTolerations
        case .acceleratorAvailability:
            .acceleratorAvailability
        }
    }

    func mapFilterCode(_ code: HardPlacementFilterReasonCode) -> SchedulerFilterFailureCode {
        switch code {
        case .insufficientCapacity:
            .insufficientCapacity
        case .architectureMismatch:
            .architectureMismatch
        case .runtimeMismatch:
            .runtimeMismatch
        case .providerMismatch:
            .providerMismatch
        case .missingCapability:
            .missingCapability
        case .nodeNotHealthy:
            .nodeNotHealthy
        case .nodeUnavailableForMaintenance:
            .nodeUnavailableForMaintenance
        case .requiredLabelMissing:
            .requiredLabelMissing
        case .requiredLabelMismatch:
            .requiredLabelMismatch
        case .forbiddenLabelPresent:
            .forbiddenLabelPresent
        case .untoleratedTaint:
            .untoleratedTaint
        case .acceleratorUnavailable:
            .acceleratorUnavailable
        }
    }

    func isCapacityOnly(_ failures: [SchedulerFilterFailure]) -> Bool {
        !failures.isEmpty && failures.allSatisfy { $0.filter == .capacity }
    }
}

private extension SchedulerEngine {
    func score(
        workload: SchedulerWorkload,
        charge: ResourceVector,
        node: SchedulerNode,
        postAllocation: ResourceVector,
        maxima: [String: Int64],
        fairnessContext: SchedulerEngineFairnessContext,
        topologyIndex: SchedulerEngineTopologyIndex,
        existingPlacement: SchedulerExistingPlacement?,
        weights: SchedulerScoreWeights
    ) throws -> SchedulerScoreComponents {
        let fragmentation = try fragmentationScore(
            capacity: node.capacity,
            postAllocation: postAllocation,
            binClass: workload.binClass
        )
        let fairnessScore = try fairnessScore(
            workload: workload,
            charge: charge,
            maxima: maxima,
            nodeCapacity: node.capacity,
            postAllocation: postAllocation,
            fairnessContext: fairnessContext
        )
        let topology = try topologyScore(
            workload: workload,
            node: node,
            topologyIndex: topologyIndex
        )
        let locality = localityScore(workload: workload, node: node)
        let host = hostPressureEnergyScore(node.posture)
        let disruption = disruptionScore(
            workload: workload,
            nodeID: node.nodeID,
            existingPlacement: existingPlacement
        )
        return try makeScoreComponents(
            fragmentation: fragmentation,
            fairness: fairnessScore,
            topology: topology,
            locality: locality,
            hostPressureEnergy: host,
            disruption: disruption,
            weights: weights
        )
    }

    func makeScoreComponents(
        fragmentation: Int64,
        fairness: Int64,
        topology: Int64,
        locality: Int64,
        hostPressureEnergy: Int64,
        disruption: Int64,
        weights: SchedulerScoreWeights
    ) throws -> SchedulerScoreComponents {
        let weighted = [
            try SchedulerCheckedMath.multiply(fragmentation, weights.fragmentation, field: "fragmentation-score"),
            try SchedulerCheckedMath.multiply(fairness, weights.fairness, field: "fairness-score"),
            try SchedulerCheckedMath.multiply(topology, weights.topology, field: "topology-score"),
            try SchedulerCheckedMath.multiply(locality, weights.locality, field: "locality-score"),
            try SchedulerCheckedMath.multiply(
                hostPressureEnergy,
                weights.hostPressureEnergy,
                field: "host-pressure-energy-score"
            ),
            try SchedulerCheckedMath.multiply(disruption, weights.disruption, field: "disruption-score")
        ]
        let numerator = try SchedulerCheckedMath.sum(weighted, field: "total-score")
        let denominator = max(weights.total, 1)
        let total = numerator / denominator
        return try SchedulerScoreComponents(
            fragmentationBasisPoints: fragmentation,
            fairnessBasisPoints: fairness,
            topologyBasisPoints: topology,
            localityBasisPoints: locality,
            hostPressureEnergyBasisPoints: hostPressureEnergy,
            disruptionBasisPoints: disruption,
            totalBasisPoints: SchedulerCheckedMath.clamp(
                total,
                upper: SchedulerEngineContractValidation.scale
            )
        )
    }

    func fragmentationScore(
        capacity: ResourceVector,
        postAllocation: ResourceVector,
        binClass: SchedulerBinClass
    ) throws -> Int64 {
        let remaining = try capacity.subtracting(postAllocation)
        let resources = capacity.resourceNames
        guard !resources.isEmpty else {
            return SchedulerEngineContractValidation.scale
        }
        var total: Int64 = 0
        for resource in resources {
            total = try SchedulerCheckedMath.add(
                total,
                normalizedQuantity(
                    remaining[resource],
                    maximum: capacity[resource],
                    ceiling: false,
                    field: "fragmentation:\(resource)"
                ),
                field: "fragmentation-total"
            )
        }
        let average = total / Int64(resources.count)
        switch binClass {
        case .compact:
            return SchedulerEngineContractValidation.scale - average
        case .balanced:
            return SchedulerEngineContractValidation.scale - average / 2
        case .spread:
            return average
        }
    }

    func fairnessScore(
        workload: SchedulerWorkload,
        charge: ResourceVector,
        maxima: [String: Int64],
        nodeCapacity: ResourceVector,
        postAllocation: ResourceVector,
        fairnessContext: SchedulerEngineFairnessContext
    ) throws -> Int64 {
        let key = SchedulerEngineFairnessKey(
            subjectID: workload.subjectID,
            projectID: workload.projectID
        )
        let record = fairnessContext.records[key] ?? SchedulerEngineFairnessRecord(
            usage: .zero,
            guarantee: .zero,
            reclaimableBorrowedUsage: .zero,
            quota: nil,
            pendingDemand: .zero,
            starvationAgeUnits: 0,
            weight: 1
        )
        let weightedShare = try fairnessMetrics(
            record: record,
            charge: charge,
            key: key,
            maxima: maxima,
            fairnessContext: fairnessContext
        ).weightedShare
        let globalScore = SchedulerEngineContractValidation.scale - min(
            SchedulerEngineContractValidation.scale,
            weightedShare
        )
        let nodeMaxima = Dictionary(uniqueKeysWithValues: nodeCapacity.resourceNames.map {
            ($0, nodeCapacity[$0])
        })
        let localShare = try dominantShare(postAllocation, maxima: nodeMaxima)
        let localScore = SchedulerEngineContractValidation.scale - localShare
        let combined = try SchedulerCheckedMath.add(
            globalScore,
            localScore,
            field: "fairness-score"
        )
        return combined / 2
    }

    func fairnessOrderingShare(
        workload: SchedulerWorkload,
        charge _: ResourceVector,
        maxima: [String: Int64],
        fairnessContext: SchedulerEngineFairnessContext
    ) throws -> Int64 {
        let key = SchedulerEngineFairnessKey(
            subjectID: workload.subjectID,
            projectID: workload.projectID
        )
        if let weightedShare = fairnessContext.weightedShares[key] {
            return weightedShare
        }
        let record = fairnessContext.records[key] ?? SchedulerEngineFairnessRecord(
            usage: .zero,
            guarantee: .zero,
            reclaimableBorrowedUsage: .zero,
            quota: nil,
            pendingDemand: .zero,
            starvationAgeUnits: 0,
            weight: 1
        )
        return try fairnessMetrics(
            record: record,
            charge: .zero,
            key: key,
            maxima: maxima,
            fairnessContext: fairnessContext
        ).weightedShare
    }

    func fairnessMetrics(
        record: SchedulerEngineFairnessRecord,
        charge: ResourceVector,
        key: SchedulerEngineFairnessKey,
        maxima: [String: Int64],
        fairnessContext: SchedulerEngineFairnessContext
    ) throws -> SchedulerEngineFairnessMetrics {
        let projectedUsage = try record.usage.adding(charge)
        let projectedShare = try dominantShare(projectedUsage, maxima: maxima)
        let guaranteeShare: Int64
        if let cachedGuaranteeShare = fairnessContext.guaranteeShares[key] {
            guaranteeShare = cachedGuaranteeShare
        } else {
            guaranteeShare = try dominantShare(record.guarantee, maxima: maxima)
        }
        let ownUnusedGuarantee = fairnessContext.unusedGuaranteeByKey[key] ?? 0
        let unusedGuarantee = try SchedulerCheckedMath.subtract(
            fairnessContext.totalUnusedGuarantee,
            ownUnusedGuarantee,
            field: "fairness-borrowing"
        )
        let excess = max(0, projectedShare - guaranteeShare)
        let borrowing = min(excess, unusedGuarantee)
        let effectiveShare = projectedShare - borrowing
        let weightedShare = try SchedulerCheckedMath.ceilDivide(
            effectiveShare,
            by: record.weight,
            field: "weighted-drf-share"
        )
        return SchedulerEngineFairnessMetrics(
            projectedShare: projectedShare,
            guaranteeShare: guaranteeShare,
            borrowingBasisPoints: borrowing,
            weightedShare: min(SchedulerEngineContractValidation.scale, weightedShare)
        )
    }

    func fairnessExplanation(
        workload: SchedulerWorkload,
        charge: ResourceVector,
        maxima: [String: Int64],
        fairnessContext: SchedulerEngineFairnessContext
    ) throws -> SchedulerFairnessExplanation {
        let key = SchedulerEngineFairnessKey(
            subjectID: workload.subjectID,
            projectID: workload.projectID
        )
        let record = fairnessContext.records[key] ?? SchedulerEngineFairnessRecord(
            usage: .zero,
            guarantee: .zero,
            reclaimableBorrowedUsage: .zero,
            quota: nil,
            pendingDemand: .zero,
            starvationAgeUnits: 0,
            weight: 1
        )
        let metrics = try fairnessMetrics(
            record: record,
            charge: charge,
            key: key,
            maxima: maxima,
            fairnessContext: fairnessContext
        )
        return try SchedulerFairnessExplanation(
            subjectID: workload.subjectID,
            projectID: workload.projectID,
            usage: record.usage,
            guarantee: record.guarantee,
            quota: record.quota,
            pendingDemand: record.pendingDemand,
            starvationAgeUnits: record.starvationAgeUnits,
            weightedDominantShareBasisPoints: metrics.weightedShare,
            guaranteeShareBasisPoints: metrics.guaranteeShare,
            borrowingBasisPoints: metrics.borrowingBasisPoints,
            reclaimableBorrowedUsage: record.reclaimableBorrowedUsage
        )
    }

    func dominantShare(
        _ usage: ResourceVector,
        maxima: [String: Int64]
    ) throws -> Int64 {
        var dominant: Int64 = 0
        for resource in usage.resourceNames {
            dominant = max(
                dominant,
                min(
                    SchedulerEngineContractValidation.scale,
                    try normalizedQuantity(
                        usage[resource],
                        maximum: maxima[resource] ?? 0,
                        ceiling: false,
                        field: "fairness-share:\(resource)"
                    )
                )
            )
        }
        return dominant
    }

    func topologyScore(
        workload: SchedulerWorkload,
        node: SchedulerNode,
        topologyIndex: SchedulerEngineTopologyIndex
    ) throws -> Int64 {
        let preference = workload.topology
        var score: Int64 = SchedulerEngineContractValidation.scale / 2
        if let spreadKey = preference.spreadKey,
           let domain = node.topologyDomains[spreadKey] {
            let spreadKey = SchedulerEngineTopologySpreadKey(
                spreadKey: spreadKey,
                groupID: preference.groupID
            )
            var counts = topologyIndex.spreadCounts[spreadKey] ?? [:]
            for value in topologyIndex.availableDomainsBySpreadKey[spreadKey.spreadKey] ?? [] {
                counts[value, default: 0] = counts[value, default: 0]
            }
            let maximum = counts.values.max() ?? 0
            if maximum == 0 {
                score = SchedulerEngineContractValidation.scale
            } else {
                let candidateCount = (counts[domain] ?? 0) + 1
                let denominator = maximum + 1
                let numerator = max(0, denominator - min(candidateCount, denominator))
                let scaled = try SchedulerCheckedMath.multiply(
                    numerator,
                    SchedulerEngineContractValidation.scale,
                    field: "topology-spread"
                )
                score = scaled / denominator
            }
            if preference.preferredDomainValues.contains(domain) {
                score = max(score, 8_500)
            }
        }

        if !preference.affinityWorkloadIDs.isEmpty
            || !preference.antiAffinityWorkloadIDs.isEmpty {
            let observationsOnNode = topologyIndex.observationsByNodeID[node.nodeID] ?? []
            if preference.affinityWorkloadIDs.contains(where: observationsOnNode.contains) {
                score = min(SchedulerEngineContractValidation.scale, score + 2_500)
            }
            if preference.antiAffinityWorkloadIDs.contains(where: observationsOnNode.contains) {
                score = max(0, score - 4_000)
            }
        }
        let affinityReward = try weightedSelectorAdjustment(
            preference.preferredAffinity,
            labels: node.snapshot.labels,
            maximumAdjustment: 2_500
        )
        let antiAffinityPenalty = try weightedSelectorAdjustment(
            preference.preferredAntiAffinity,
            labels: node.snapshot.labels,
            maximumAdjustment: 3_500
        )
        score = try SchedulerCheckedMath.add(score, affinityReward, field: "preferred-affinity-score")
        score = max(
            0,
            try SchedulerCheckedMath.subtract(
                score,
                antiAffinityPenalty,
                field: "preferred-anti-affinity-score"
            )
        )
        return SchedulerEngineCheckedScore.clamp(score)
    }

    func weightedSelectorAdjustment(
        _ preferences: [SchedulerWeightedLabelSelectorPreference],
        labels: [String: String],
        maximumAdjustment: Int64
    ) throws -> Int64 {
        guard !preferences.isEmpty else {
            return 0
        }
        let totalWeight = try SchedulerCheckedMath.sum(
            preferences.map(\.weight),
            field: "preferred-selector-total-weight"
        )
        let matchedWeight = try SchedulerCheckedMath.sum(
            preferences.filter { $0.selector.matches(labels) }.map(\.weight),
            field: "preferred-selector-matched-weight"
        )
        let numerator = try SchedulerCheckedMath.multiply(
            matchedWeight,
            maximumAdjustment,
            field: "preferred-selector-score"
        )
        return numerator / totalWeight
    }

    func localityScore(workload: SchedulerWorkload, node: SchedulerNode) -> Int64 {
        let preference = workload.locality
        if preference.preferredNodeIDs.contains(node.nodeID) {
            return SchedulerEngineContractValidation.scale
        }
        if !preference.preferredDomains.isEmpty,
           preference.preferredDomains.allSatisfy({ node.topologyDomains[$0.key] == $0.value }) {
            return 8_500
        }
        return preference.preferredNodeIDs.isEmpty && preference.preferredDomains.isEmpty
            ? SchedulerEngineContractValidation.scale / 2
            : 2_500
    }

    func hostPressureEnergyScore(_ posture: SchedulerHostPosture) -> Int64 {
        let pressureCost: Int64
        switch posture.pressure {
        case .nominal: pressureCost = 0
        case .elevated: pressureCost = 3_500
        case .critical: pressureCost = 9_000
        case .unknown: pressureCost = 7_000
        case .unavailable: pressureCost = 7_500
        }
        let energyCost: Int64
        switch posture.energy {
        case .efficient: energyCost = 0
        case .balanced: energyCost = 2_500
        case .performance: energyCost = 5_000
        case .constrained: energyCost = 8_000
        case .unknown: energyCost = 6_000
        }
        return SchedulerEngineContractValidation.scale - (pressureCost + energyCost) / 2
    }

    func disruptionScore(
        workload: SchedulerWorkload,
        nodeID: UUID,
        existingPlacement: SchedulerExistingPlacement?
    ) -> Int64 {
        guard let existingPlacement else {
            return SchedulerEngineContractValidation.scale
        }
        guard existingPlacement.nodeID != nodeID else {
            return SchedulerEngineContractValidation.scale
        }
        return SchedulerEngineContractValidation.scale - workload.disruption.movementCostBasisPoints
    }

    func candidatePrecedes(
        _ lhs: SchedulerEngineCandidate,
        _ rhs: SchedulerEngineCandidate
    ) -> Bool {
        if lhs.score.totalBasisPoints != rhs.score.totalBasisPoints {
            return lhs.score.totalBasisPoints > rhs.score.totalBasisPoints
        }
        return SchedulerOrdering.uuidKey(lhs.nodeID) < SchedulerOrdering.uuidKey(rhs.nodeID)
    }

    func selectCandidate(
        _ candidates: [SchedulerEngineCandidate],
        existingPlacement: SchedulerExistingPlacement?,
        threshold: Int64,
        stabilityPolicy: SchedulerStabilityPolicy,
        states: [SchedulerEngineNodeState]
    ) throws -> SchedulerEngineCandidate {
        guard let best = candidates.first else {
            throw SchedulerEngineValidationError.invalidDecision("empty-candidate-set")
        }
        guard let existingPlacement,
              let current = candidates.first(where: { $0.nodeID == existingPlacement.nodeID }),
              current.nodeID != best.nodeID else {
            return best
        }
        let snapshot = existingPlacement.stability
        let currentNode = states.first { $0.nodeID == current.nodeID }?.node
        let unsafePressure = switch currentNode?.posture.pressure {
        case .critical, .unknown, .unavailable:
            true
        case .nominal, .elevated, .none:
            false
        }
        let protectedByResidence = snapshot.residenceUnits < stabilityPolicy.minimumResidenceUnits
            || snapshot.cooldownRemainingUnits > stabilityPolicy.cooldownUnitsToRetain
            || snapshot.recoveryDelayRemainingUnits > stabilityPolicy.recoveryDelayUnitsToRetain
            || snapshot.rolloutProtected
        if protectedByResidence && !(unsafePressure && stabilityPolicy.pressureSafetyOverride) {
            return current
        }
        let rawImprovement = best.score.totalBasisPoints - current.score.totalBasisPoints
        let improvement = try SchedulerCheckedMath.add(
            rawImprovement,
            stabilityPolicy.pendingWorkBenefitBasisPoints,
            field: "anti-churn-improvement"
        )
        return improvement > threshold ? best : current
    }

    func alternatives(
        candidates: [SchedulerEngineCandidate],
        selected: SchedulerEngineCandidate,
        limits: SchedulerEngineLimits,
        maxCount: Int
    ) -> [SchedulerNodeAlternative] {
        let count = min(limits.maxAlternativeCount, maxCount)
        var values = candidates.prefix(count).map {
            SchedulerNodeAlternative(nodeID: $0.nodeID, scoreComponents: $0.score)
        }
        if !values.contains(where: { $0.nodeID == selected.nodeID }),
           count > 0 {
            if values.count == count {
                values[values.count - 1] = SchedulerNodeAlternative(
                    nodeID: selected.nodeID,
                    scoreComponents: selected.score
                )
            } else {
                values.append(
                    SchedulerNodeAlternative(
                        nodeID: selected.nodeID,
                        scoreComponents: selected.score
                    )
                )
            }
        }
        return values
    }
}

private enum SchedulerEngineCheckedScore {
    static func clamp(_ value: Int64) -> Int64 {
        min(max(value, 0), SchedulerEngineContractValidation.scale)
    }
}

private extension SchedulerEngine {
    func preemptionProposal(
        input: SchedulerEngineInput,
        workload: SchedulerWorkload,
        charge: ResourceVector,
        baselineStates: [SchedulerEngineNodeState],
        observations: [SchedulerEngineObservation],
        topologyDomains: [UUID: [String: String]],
        failures: inout [SchedulerFilterFailure],
        plannedVictimIDs: Set<UUID>,
        plannedBudgetVictimCounts: [SchedulerEngineBudgetKey: Int],
        plannedBudgetCosts: [SchedulerEngineBudgetKey: Int64],
        snapshotCache: SchedulerEngineNodeSnapshotCache
    ) throws -> SchedulerPreemptionProposal? {
        guard workload.preemptionEligibility == .eligible else {
            for state in baselineStates where failures.contains(where: {
                $0.nodeID == state.nodeID && $0.filter == .capacity
            }) {
                failures.append(
                    try SchedulerFilterFailure(
                        filter: .preemption,
                        code: .preemptionWorkloadNotEligible,
                        workloadID: workload.workloadID,
                        nodeID: state.nodeID,
                        stableDetailKey: "preemption-workload-not-eligible",
                        message: "The workload did not opt in to preemption."
                    )
                )
            }
            failures.sort { $0.orderingKey < $1.orderingKey }
            return nil
        }

        guard !input.preemptionPolicy.incomingNonPreempting,
              input.preemptionPolicy.preemptionAuthorized else {
            if !input.preemptionPolicy.incomingNonPreempting {
                for state in baselineStates where failures.contains(where: {
                    $0.nodeID == state.nodeID && $0.filter == .capacity
                }) {
                    failures.append(
                        try SchedulerFilterFailure(
                            filter: .preemption,
                            code: .preemptionAuthorizationRequired,
                            workloadID: workload.workloadID,
                            nodeID: state.nodeID,
                            stableDetailKey: "preemption-authorization-required",
                            message: "Daemon/operator authorization is required before preemption may be proposed."
                        )
                    )
                }
            }
            failures.sort { $0.orderingKey < $1.orderingKey }
            return nil
        }

        let budgets = Dictionary(uniqueKeysWithValues: input.disruptionBudgets.map {
            (
                SchedulerEngineBudgetKey(projectID: $0.projectID, budgetID: $0.budgetID),
                $0
            )
        })
        var candidates: [SchedulerEnginePreemptionCandidate] = []
        let chargedRequirements = try chargedRequirements(for: workload, charge: charge)

        for state in baselineStates {
            let nodeFailures = failures.filter { $0.nodeID == state.nodeID }
            guard isCapacityOnly(nodeFailures) else {
                continue
            }
            let victimCandidates = input.victimAllocations
                .filter {
                    $0.nodeID == state.nodeID
                        && $0.priority < workload.priority
                        && priorityGapSatisfied(
                            incoming: workload.priority,
                            victim: $0.priority,
                            minimum: input.preemptionPolicy.minimumPriorityGap
                        )
                        && $0.preemptible
                        && (input.preemptionPolicy.protectedVictimStarvationAgeUnits == 0
                            || $0.starvationAgeUnits
                                < input.preemptionPolicy.protectedVictimStarvationAgeUnits)
                        && !plannedVictimIDs.contains($0.workloadID)
                }
                .sorted {
                    if $0.priority != $1.priority {
                        return $0.priority < $1.priority
                    }
                    return SchedulerOrdering.uuidKey($0.workloadID)
                        < SchedulerOrdering.uuidKey($1.workloadID)
                }

            guard victimCandidates.count <= input.limits.maxExactPreemptionVictimsPerNode else {
                failures.append(
                    try SchedulerFilterFailure(
                        filter: .preemption,
                        code: .preemptionSearchBoundExceeded,
                        workloadID: workload.workloadID,
                        nodeID: state.nodeID,
                        stableDetailKey: "preemption-search-bound:\(input.limits.maxExactPreemptionVictimsPerNode):\(victimCandidates.count)",
                        message: "Exact preemption search is bounded and this node has too many eligible victims."
                    )
                )
                continue
            }
            switch try exactPreemptionCandidate(
                state: state,
                workload: workload,
                chargedRequirements: chargedRequirements,
                victimCandidates: victimCandidates,
                budgets: budgets,
                plannedBudgetVictimCounts: plannedBudgetVictimCounts,
                plannedBudgetCosts: plannedBudgetCosts,
                topologyDomains: topologyDomains,
                observations: observations,
                maxSearchStates: input.limits.maxExactPreemptionSearchStates,
                snapshotCache: snapshotCache
            ) {
            case .complete(let candidate):
                if let candidate {
                    candidates.append(candidate)
                }
            case .stateBudgetExhausted(let exploredStates):
                failures.append(
                    try SchedulerFilterFailure(
                        filter: .preemption,
                        code: .preemptionSearchBoundExceeded,
                        workloadID: workload.workloadID,
                        nodeID: state.nodeID,
                        stableDetailKey: "preemption-search-bound:states:\(input.limits.maxExactPreemptionSearchStates):\(exploredStates)",
                        message: "Exact preemption search exhausted its bounded state budget on this node."
                    )
                )
            }
        }

        failures.sort { $0.orderingKey < $1.orderingKey }

        guard let selected = candidates.sorted(by: preemptionCandidatePrecedes).first else {
            return nil
        }
        let budgetIDs = selected.victims.compactMap(\.budgetID)
        let explanation = try SchedulerPreemptionExplanation(
            summary: "Preemption intent requires later fencing and revalidation before admission.",
            victimCount: selected.victims.count,
            disruptionCostBasisPoints: selected.cost,
            budgetIDs: budgetIDs
        )
        return try SchedulerPreemptionProposal(
            intentDigest: input.inputDigest,
            targetWorkloadID: workload.workloadID,
            projectID: workload.projectID,
            nodeID: selected.nodeID,
            victims: selected.victims,
            disruptionCostBasisPoints: selected.cost,
            explanation: explanation,
            requiresFence: true,
            policy: input.preemptionPolicy
        )
    }

    func exactPreemptionCandidate(
        state: SchedulerEngineNodeState,
        workload: SchedulerWorkload,
        chargedRequirements: WorkloadPlacementRequirements,
        victimCandidates: [SchedulerVictimAllocation],
        budgets: [SchedulerEngineBudgetKey: SchedulerDisruptionBudget],
        plannedBudgetVictimCounts: [SchedulerEngineBudgetKey: Int],
        plannedBudgetCosts: [SchedulerEngineBudgetKey: Int64],
        topologyDomains: [UUID: [String: String]],
        observations: [SchedulerEngineObservation],
        maxSearchStates: Int,
        snapshotCache: SchedulerEngineNodeSnapshotCache
    ) throws -> SchedulerExactPreemptionSearchResult {
        var best: SchedulerEnginePreemptionCandidate?
        var exploredStates = 0
        var stateBudgetExhausted = false

        func search(
            index: Int,
            allocation: ResourceVector,
            selected: [SchedulerVictimAllocation],
            cost: Int64
        ) throws {
            guard !stateBudgetExhausted else {
                return
            }
            guard exploredStates < maxSearchStates else {
                stateBudgetExhausted = true
                return
            }
            exploredStates += 1

            if !selected.isEmpty {
                let filterFailures = try evaluateHardFilters(
                    workload: workload,
                    chargedRequirements: chargedRequirements,
                    node: state.node,
                    allocation: allocation,
                    topologyContext: try topologyContext(
                        nodeTopologyDomains: topologyDomains,
                        observations: observations.filter { observation in
                            !selected.contains(where: { victim in
                                victim.workloadID == observation.workloadID
                            })
                        }
                    ),
                    snapshotCache: snapshotCache
                )
                if filterFailures.isEmpty {
                    let candidate = SchedulerEnginePreemptionCandidate(
                        nodeID: state.nodeID,
                        victims: selected.sorted {
                            SchedulerOrdering.uuidKey($0.workloadID)
                                < SchedulerOrdering.uuidKey($1.workloadID)
                        },
                        cost: cost
                    )
                    if best == nil || preemptionCandidatePrecedes(candidate, best!) {
                        best = candidate
                    }
                }
            }

            guard index < victimCandidates.count else {
                return
            }
            if let best, cost > best.cost {
                return
            }

            let victim = victimCandidates[index]
            if try canAddVictim(
                victim,
                to: allocation,
                selected: selected,
                budgets: budgets,
                plannedBudgetVictimCounts: plannedBudgetVictimCounts,
                plannedBudgetCosts: plannedBudgetCosts
            ) {
                let nextCost = try SchedulerCheckedMath.add(
                    cost,
                    victim.disruptionCostBasisPoints,
                    field: "preemption-disruption-cost"
                )
                if best == nil || nextCost <= best!.cost {
                    try search(
                        index: index + 1,
                        allocation: try allocation.subtracting(victim.allocation),
                        selected: selected + [victim],
                        cost: nextCost
                    )
                }
            }

            try search(
                index: index + 1,
                allocation: allocation,
                selected: selected,
                cost: cost
            )
        }

        try search(
            index: 0,
            allocation: state.allocation,
            selected: [],
            cost: 0
        )
        if stateBudgetExhausted {
            return .stateBudgetExhausted(exploredStates: exploredStates)
        }
        return .complete(best)
    }

    func priorityGapSatisfied(incoming: Int64, victim: Int64, minimum: Int64) -> Bool {
        guard incoming > victim else {
            return false
        }
        let (gap, overflow) = incoming.subtractingReportingOverflow(victim)
        return !overflow && gap >= minimum
    }

    func canAddVictim(
        _ victim: SchedulerVictimAllocation,
        to allocation: ResourceVector,
        selected: [SchedulerVictimAllocation],
        budgets: [SchedulerEngineBudgetKey: SchedulerDisruptionBudget],
        plannedBudgetVictimCounts: [SchedulerEngineBudgetKey: Int],
        plannedBudgetCosts: [SchedulerEngineBudgetKey: Int64]
    ) throws -> Bool {
        guard victim.allocation.fits(in: allocation) else {
            return false
        }
        guard let budgetID = victim.budgetID else {
            return true
        }
        let budgetKey = SchedulerEngineBudgetKey(
            projectID: victim.projectID,
            budgetID: budgetID
        )
        guard let budget = budgets[budgetKey], budget.projectID == victim.projectID else {
            return false
        }
        let selectedCount = selected.filter {
            $0.budgetID == budgetID && $0.projectID == victim.projectID
        }.count
        let usedCount = plannedBudgetVictimCounts[budgetKey, default: 0] + selectedCount
        guard usedCount < budget.remainingVictimCount else {
            return false
        }
        let selectedCost = try SchedulerCheckedMath.sum(
            selected.filter {
                $0.budgetID == budgetID && $0.projectID == victim.projectID
            }.map(\.disruptionCostBasisPoints),
            field: "preemption-budget-cost"
        )
        let usedCost = try SchedulerCheckedMath.add(
            plannedBudgetCosts[budgetKey, default: 0],
            selectedCost,
            field: "preemption-budget-cost"
        )
        guard usedCost <= budget.remainingDisruptionCostBasisPoints else {
            return false
        }
        let totalCost = try SchedulerCheckedMath.add(
            usedCost,
            victim.disruptionCostBasisPoints,
            field: "preemption-budget-cost"
        )
        return totalCost <= budget.remainingDisruptionCostBasisPoints
    }

    func preemptionCandidatePrecedes(
        _ lhs: SchedulerEnginePreemptionCandidate,
        _ rhs: SchedulerEnginePreemptionCandidate
    ) -> Bool {
        if lhs.cost != rhs.cost {
            return lhs.cost < rhs.cost
        }
        if lhs.victims.count != rhs.victims.count {
            return lhs.victims.count < rhs.victims.count
        }
        let lhsVictims = lhs.victims.map { SchedulerOrdering.uuidKey($0.workloadID) }
        let rhsVictims = rhs.victims.map { SchedulerOrdering.uuidKey($0.workloadID) }
        if lhsVictims != rhsVictims {
            return lhsVictims.lexicographicallyPrecedes(rhsVictims)
        }
        return SchedulerOrdering.uuidKey(lhs.nodeID) < SchedulerOrdering.uuidKey(rhs.nodeID)
    }
}

private extension SchedulerEngine {
    func capacityExplanation(
        workload: SchedulerWorkload,
        charge: ResourceVector,
        overcommitRatios: [String: SchedulerResourceRatio]
    ) throws -> SchedulerCapacityExplanation {
        try SchedulerCapacityExplanation(
            rawRequest: workload.request,
            declaredLimit: workload.requirements.limit,
            overhead: workload.overhead,
            safetyMargin: workload.safetyMargin,
            chargedCapacity: charge,
            overcommitRatios: overcommitRatios
        )
    }

    func placementTieBreak(
        selected: SchedulerEngineCandidate,
        candidates: [SchedulerEngineCandidate],
        existingPlacement: SchedulerExistingPlacement?,
        threshold: Int64
    ) throws -> SchedulerTieBreakExplanation {
        if let existingPlacement, selected.nodeID == existingPlacement.nodeID,
           candidates.first?.nodeID != selected.nodeID {
            return try SchedulerTieBreakExplanation(
                reason: .antiChurn,
                chosenNodeID: selected.nodeID,
                thresholdBasisPoints: threshold
            )
        }
        if let first = candidates.first,
           candidates.dropFirst().contains(where: {
               $0.score.totalBasisPoints == first.score.totalBasisPoints
           }) {
            return try SchedulerTieBreakExplanation(
                reason: .stableNodeUUID,
                chosenNodeID: selected.nodeID
            )
        }
        return try SchedulerTieBreakExplanation(reason: .score, chosenNodeID: selected.nodeID)
    }

    func placementExplanation(
        outcome: SchedulerDecisionOutcome,
        workloadID: UUID,
        nodeID: UUID,
        topology: SchedulerTopologyPreference,
        failures: [SchedulerFilterFailure],
        alternatives: [SchedulerNodeAlternative],
        charge: ResourceVector,
        rawRequest: ResourceVector,
        declaredLimit: ResourceVector?
    ) throws -> SchedulerDecisionExplanation {
        let code: SchedulerExplanationCode = outcome == .retainedExistingPlacement
            ? .retainedExistingPlacement
            : .placed
        return try SchedulerDecisionExplanation(
            code: code,
            summary: outcome == .retainedExistingPlacement
                ? "Retained the valid existing placement after anti-churn evaluation."
                : "Placed the workload on the highest-scoring feasible node.",
            detailKeys: explanationDetails(
                topology: topology,
                failures: failures,
                alternatives: alternatives,
                charge: charge,
                rawRequest: rawRequest,
                declaredLimit: declaredLimit,
                includeScore: true
            )
        )
    }

    func preemptionDecisionExplanation(
        workloadID: UUID,
        topology: SchedulerTopologyPreference,
        failures: [SchedulerFilterFailure],
        proposal: SchedulerPreemptionProposal,
        charge: ResourceVector,
        rawRequest: ResourceVector,
        declaredLimit: ResourceVector?
    ) throws -> SchedulerDecisionExplanation {
        try SchedulerDecisionExplanation(
            code: .preemptionProposed,
            summary: "No node fits without lower-priority work; a deterministic preemption intent was returned.",
            detailKeys: explanationDetails(
                topology: topology,
                failures: failures,
                alternatives: [],
                charge: charge,
                rawRequest: rawRequest,
                declaredLimit: declaredLimit,
                includeScore: false
            ) + [
                "preemption-intent",
                "requires-fence",
                "intent-digest:\(proposal.intentDigest)",
                "preemption-incoming-policy:\(proposal.policy.incomingNonPreempting)",
                "preemption-authorized:\(proposal.policy.preemptionAuthorized)",
                "preemption-minimum-priority-gap:\(proposal.policy.minimumPriorityGap)",
                "preemption-starvation-safeguard:\(proposal.policy.protectedVictimStarvationAgeUnits)",
                "preemption-grace-period:\(proposal.policy.gracePeriodUnits)",
                "preemption-checkpoint-required:\(proposal.policy.checkpointRequired)",
                "preemption-drain-required:\(proposal.policy.drainRequired)",
                "preemption-authorization-reference:\(proposal.policy.authorizationReference ?? "none")",
                "preemption-workload-eligibility:eligible"
            ]
        )
    }

    func unschedulableExplanation(
        workloadID: UUID,
        topology: SchedulerTopologyPreference,
        failures: [SchedulerFilterFailure],
        charge: ResourceVector,
        rawRequest: ResourceVector,
        declaredLimit: ResourceVector?
    ) throws -> SchedulerDecisionExplanation {
        try SchedulerDecisionExplanation(
            code: .noFeasibleNode,
            summary: "No node satisfies the hard placement constraints and no safe preemption intent is available.",
            detailKeys: explanationDetails(
                topology: topology,
                failures: failures,
                alternatives: [],
                charge: charge,
                rawRequest: rawRequest,
                declaredLimit: declaredLimit,
                includeScore: false
            )
        )
    }

    func explanationDetails(
        topology: SchedulerTopologyPreference,
        failures: [SchedulerFilterFailure],
        alternatives: [SchedulerNodeAlternative],
        charge: ResourceVector,
        rawRequest: ResourceVector,
        declaredLimit: ResourceVector?,
        includeScore: Bool
    ) -> [String] {
        var details = Array(Set(failures.map { $0.code.rawValue })).sorted()
        if includeScore {
            details.append(contentsOf: [
                "score:fragmentation",
                "score:fairness",
                "score:topology",
                "score:locality",
                "score:host-pressure-energy",
                "score:disruption"
            ])
        }
        details.append(contentsOf: topology.preferredAffinity.map {
            "preferred-affinity:\($0.orderingKey)"
        })
        details.append(contentsOf: topology.preferredAntiAffinity.map {
            "preferred-anti-affinity:\($0.orderingKey)"
        })
        details.append("alternatives:\(alternatives.count)")
        let chargedResources = Set(charge.resourceNames)
            .union(declaredLimit?.resourceNames ?? [])
            .sorted()
        for resource in chargedResources where declaredLimit != nil || charge[resource] != rawRequest[resource] {
            details.append("limit-charge:\(resource):\(charge[resource])")
        }
        return Array(Set(details)).sorted()
    }

    func stableDecisionID(
        inputDigest: String,
        orderedIDs: [UUID],
        decisions: [SchedulerWorkloadDecision]
    ) -> UUID {
        var material = inputDigest
        for id in orderedIDs {
            material.append(contentsOf: "|")
            material.append(contentsOf: SchedulerOrdering.uuidKey(id))
        }
        for decision in decisions {
            material.append(contentsOf: "|")
            material.append(contentsOf: decision.outcome.rawValue)
            material.append(contentsOf: ":")
            if let nodeID = decision.chosenNodeID {
                material.append(contentsOf: SchedulerOrdering.uuidKey(nodeID))
            }
            if let preemption = decision.preemption {
                material.append(contentsOf: ":")
                material.append(contentsOf: preemption.victimWorkloadIDs.map(SchedulerOrdering.uuidKey).joined(separator: ","))
            }
        }
        let digest = SHA256.hash(data: Data(material.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
