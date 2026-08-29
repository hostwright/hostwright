import Foundation

/// The deliberately small Kubernetes compute-resource subset admitted by Hostwright.
/// This is not a claim of compatibility with Kubernetes `resource.Quantity`.
public enum KubernetesResourceAdmissionContract {
    public static let schemaVersion = 1
    public static let supportedSubset = "hostwright.kubernetes.compute-resources.v1"
}

public struct KubernetesResourceQuantityEntry: Equatable, Sendable {
    public let key: String
    public let value: String?

    public init(key: String, value: String?) {
        self.key = key
        self.value = value
    }

    public init(_ entry: (String, String?)) {
        self.init(key: entry.0, value: entry.1)
    }
}

public struct KubernetesContainerResourceRequirements: Equatable, Sendable {
    public let requests: [KubernetesResourceQuantityEntry]
    public let limits: [KubernetesResourceQuantityEntry]

    public init(
        requests: [KubernetesResourceQuantityEntry] = [],
        limits: [KubernetesResourceQuantityEntry] = []
    ) {
        self.requests = requests
        self.limits = limits
    }
}

public enum KubernetesResourceAdmissionDiagnosticCode: String, Codable, Equatable, Sendable {
    case aggregateOverflow = "aggregate-overflow"
    case duplicateResource = "duplicate-resource"
    case invalidContainerCount = "invalid-container-count"
    case invalidQuantity = "invalid-quantity"
    case invalidReplicaCount = "invalid-replica-count"
    case invalidResourceEntryCount = "invalid-resource-entry-count"
    case missingQuantity = "missing-quantity"
    case nonPositiveQuantity = "non-positive-quantity"
    case quantityOverflow = "quantity-overflow"
    case replicaOverflow = "replica-overflow"
    case requestExceedsLimit = "request-exceeds-limit"
    case unsupportedResource = "unsupported-resource"
    case unsupportedUnit = "unsupported-unit"
}

public struct KubernetesResourceAdmissionDiagnostic: Equatable, Sendable {
    public let code: KubernetesResourceAdmissionDiagnosticCode
    public let path: String
    public let message: String

    public init(code: KubernetesResourceAdmissionDiagnosticCode, path: String) {
        self.code = code
        self.path = path
        self.message = Self.message(for: code)
    }

    private static func message(for code: KubernetesResourceAdmissionDiagnosticCode) -> String {
        let subset = KubernetesResourceAdmissionContract.supportedSubset
        switch code {
        case .aggregateOverflow:
            return "The per-replica compute-resource total exceeds the bounded Int64 domain."
        case .duplicateResource:
            return "A compute-resource key is repeated in the same resource map."
        case .invalidContainerCount:
            return "The workload must contain a bounded, nonempty container collection."
        case .invalidQuantity:
            return "The quantity is not canonical in the supported \(subset) subset; full Kubernetes resource.Quantity syntax is not supported."
        case .invalidReplicaCount:
            return "Deployment replicas must be a positive Int64 value."
        case .invalidResourceEntryCount:
            return "The resource map exceeds the bounded entry count."
        case .missingQuantity:
            return "The compute-resource key has no quantity value."
        case .nonPositiveQuantity:
            return "Compute-resource quantities must be greater than zero."
        case .quantityOverflow:
            return "The normalized quantity exceeds the bounded Int64 domain."
        case .replicaOverflow:
            return "The replica-multiplied compute-resource total exceeds the bounded Int64 domain."
        case .requestExceedsLimit:
            return "The compute-resource request exceeds its declared limit."
        case .unsupportedResource:
            return "Only cpu and memory are supported by \(subset)."
        case .unsupportedUnit:
            return "The quantity unit is outside \(subset); full Kubernetes resource.Quantity units are not supported."
        }
    }
}

public struct KubernetesComputeResources: Codable, Equatable, Sendable {
    public let cpuMillicores: Int64?
    public let memoryBytes: Int64?

    public init(cpuMillicores: Int64? = nil, memoryBytes: Int64? = nil) throws {
        guard cpuMillicores == nil || cpuMillicores! > 0 else {
            throw KubernetesResourceAdmissionDomainError.invalidNormalizedValue("cpuMillicores")
        }
        guard memoryBytes == nil || memoryBytes! > 0 else {
            throw KubernetesResourceAdmissionDomainError.invalidNormalizedValue("memoryBytes")
        }
        self.cpuMillicores = cpuMillicores
        self.memoryBytes = memoryBytes
    }

    public init(from decoder: Decoder) throws {
        try StrictKubernetesResourceCoding.rejectUnknownKeys(
            from: decoder,
            allowed: Set(CodingKeys.allCases.map(\.stringValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.cpuMillicores) else {
            throw DecodingError.keyNotFound(
                CodingKeys.cpuMillicores,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing required key cpuMillicores."
                )
            )
        }
        guard container.contains(.memoryBytes) else {
            throw DecodingError.keyNotFound(
                CodingKeys.memoryBytes,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing required key memoryBytes."
                )
            )
        }
        try self.init(
            cpuMillicores: container.decodeIfPresent(Int64.self, forKey: .cpuMillicores),
            memoryBytes: container.decodeIfPresent(Int64.self, forKey: .memoryBytes)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cpuMillicores, forKey: .cpuMillicores)
        try container.encode(memoryBytes, forKey: .memoryBytes)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case cpuMillicores
        case memoryBytes
    }
}

public struct KubernetesContainerComputeResources: Codable, Equatable, Sendable {
    public let requests: KubernetesComputeResources
    public let limits: KubernetesComputeResources

    public init(
        requests: KubernetesComputeResources,
        limits: KubernetesComputeResources
    ) throws {
        if let request = requests.cpuMillicores,
           let limit = limits.cpuMillicores,
           request > limit {
            throw KubernetesResourceAdmissionDomainError.requestExceedsLimit("cpu")
        }
        if let request = requests.memoryBytes,
           let limit = limits.memoryBytes,
           request > limit {
            throw KubernetesResourceAdmissionDomainError.requestExceedsLimit("memory")
        }
        self.requests = requests
        self.limits = limits
    }

    public init(from decoder: Decoder) throws {
        try StrictKubernetesResourceCoding.rejectUnknownKeys(
            from: decoder,
            allowed: Set(CodingKeys.allCases.map(\.stringValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requests: container.decode(KubernetesComputeResources.self, forKey: .requests),
            limits: container.decode(KubernetesComputeResources.self, forKey: .limits)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case requests
        case limits
    }
}

public struct KubernetesWorkloadComputeResources: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let supportedSubset: String
    public let containers: [KubernetesContainerComputeResources]
    public let perReplicaRequests: KubernetesComputeResources
    public let perReplicaLimits: KubernetesComputeResources
    public let aggregateRequests: KubernetesComputeResources
    public let aggregateLimits: KubernetesComputeResources
    public let replicas: Int64

    public init(
        containers: [KubernetesContainerComputeResources],
        replicas: Int64
    ) throws {
        guard (1...KubernetesResourceAdmission.maximumContainers).contains(containers.count) else {
            throw KubernetesResourceAdmissionDomainError.invalidContainerCount
        }
        guard replicas > 0 else {
            throw KubernetesResourceAdmissionDomainError.invalidReplicaCount
        }
        let perReplicaRequests = try Self.aggregate(
            containers.map(\.requests),
            missingMeansUnbounded: false
        )
        let perReplicaLimits = try Self.aggregate(
            containers.map(\.limits),
            missingMeansUnbounded: true
        )
        let aggregateRequests = try Self.multiply(perReplicaRequests, by: replicas)
        let aggregateLimits = try Self.multiply(perReplicaLimits, by: replicas)

        self.schemaVersion = KubernetesResourceAdmissionContract.schemaVersion
        self.supportedSubset = KubernetesResourceAdmissionContract.supportedSubset
        self.containers = containers
        self.perReplicaRequests = perReplicaRequests
        self.perReplicaLimits = perReplicaLimits
        self.aggregateRequests = aggregateRequests
        self.aggregateLimits = aggregateLimits
        self.replicas = replicas
    }

    public init(from decoder: Decoder) throws {
        try StrictKubernetesResourceCoding.rejectUnknownKeys(
            from: decoder,
            allowed: Set(CodingKeys.allCases.map(\.stringValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let supportedSubset = try container.decode(String.self, forKey: .supportedSubset)
        guard schemaVersion == KubernetesResourceAdmissionContract.schemaVersion,
              supportedSubset == KubernetesResourceAdmissionContract.supportedSubset else {
            throw KubernetesResourceAdmissionDomainError.unsupportedContract
        }
        let decodedContainers = try container.decode(
            [KubernetesContainerComputeResources].self,
            forKey: .containers
        )
        let decodedPerReplicaRequests = try container.decode(
            KubernetesComputeResources.self,
            forKey: .perReplicaRequests
        )
        let decodedPerReplicaLimits = try container.decode(
            KubernetesComputeResources.self,
            forKey: .perReplicaLimits
        )
        let decodedAggregateRequests = try container.decode(
            KubernetesComputeResources.self,
            forKey: .aggregateRequests
        )
        let decodedAggregateLimits = try container.decode(
            KubernetesComputeResources.self,
            forKey: .aggregateLimits
        )
        let decodedReplicas = try container.decode(Int64.self, forKey: .replicas)
        try self.init(containers: decodedContainers, replicas: decodedReplicas)
        guard perReplicaRequests == decodedPerReplicaRequests,
              perReplicaLimits == decodedPerReplicaLimits,
              aggregateRequests == decodedAggregateRequests,
              aggregateLimits == decodedAggregateLimits else {
            throw KubernetesResourceAdmissionDomainError.inconsistentDerivedTotals
        }
    }

    private static func aggregate(
        _ resources: [KubernetesComputeResources],
        missingMeansUnbounded: Bool
    ) throws -> KubernetesComputeResources {
        func sum(_ values: [Int64?]) throws -> Int64? {
            if missingMeansUnbounded, values.contains(where: { $0 == nil }) {
                return nil
            }
            let declared = values.compactMap { $0 }
            guard !declared.isEmpty else { return nil }
            var total: Int64 = 0
            for value in declared {
                let result = total.addingReportingOverflow(value)
                guard !result.overflow else {
                    throw KubernetesResourceAdmissionDomainError.aggregateOverflow
                }
                total = result.partialValue
            }
            return total > 0 ? total : nil
        }
        return try KubernetesComputeResources(
            cpuMillicores: sum(resources.map(\.cpuMillicores)),
            memoryBytes: sum(resources.map(\.memoryBytes))
        )
    }

    private static func multiply(
        _ resources: KubernetesComputeResources,
        by replicas: Int64
    ) throws -> KubernetesComputeResources {
        func product(_ value: Int64?) throws -> Int64? {
            guard let value else { return nil }
            let result = value.multipliedReportingOverflow(by: replicas)
            guard !result.overflow, result.partialValue > 0 else {
                throw KubernetesResourceAdmissionDomainError.replicaOverflow
            }
            return result.partialValue
        }
        return try KubernetesComputeResources(
            cpuMillicores: product(resources.cpuMillicores),
            memoryBytes: product(resources.memoryBytes)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case supportedSubset
        case containers
        case perReplicaRequests
        case perReplicaLimits
        case aggregateRequests
        case aggregateLimits
        case replicas
    }
}

public struct KubernetesResourceAdmissionResult: Equatable, Sendable {
    public let admission: KubernetesWorkloadComputeResources?
    public let diagnostics: [KubernetesResourceAdmissionDiagnostic]

    public init(
        admission: KubernetesWorkloadComputeResources?,
        diagnostics: [KubernetesResourceAdmissionDiagnostic]
    ) {
        self.admission = admission
        self.diagnostics = diagnostics
    }
}

public enum KubernetesResourceAdmission {
    public static let maximumContainers = 128
    public static let maximumResourceEntriesPerMap = 16
    public static let schemaVersion = KubernetesResourceAdmissionContract.schemaVersion
    public static let supportedSubset = KubernetesResourceAdmissionContract.supportedSubset

    public static func admitPod(
        _ containers: [KubernetesContainerResourceRequirements]
    ) -> KubernetesResourceAdmissionResult {
        admit(containers, replicas: 1, deployment: false)
    }

    public static func admitDeployment(
        _ containers: [KubernetesContainerResourceRequirements],
        replicas: Int64
    ) -> KubernetesResourceAdmissionResult {
        admit(containers, replicas: replicas, deployment: true)
    }

    private static func admit(
        _ containers: [KubernetesContainerResourceRequirements],
        replicas: Int64,
        deployment: Bool
    ) -> KubernetesResourceAdmissionResult {
        guard (1...maximumContainers).contains(containers.count) else {
            return failure(.invalidContainerCount, path: "$.spec.containers")
        }
        if deployment, replicas <= 0 {
            return failure(.invalidReplicaCount, path: "$.spec.replicas")
        }

        var diagnostics: [KubernetesResourceAdmissionDiagnostic] = []
        var normalized: [KubernetesContainerComputeResources] = []
        normalized.reserveCapacity(containers.count)

        for (index, container) in containers.enumerated() {
            let basePath = "$.spec.containers[\(index)].resources"
            let requests = parse(container.requests, path: "\(basePath).requests")
            let limits = parse(container.limits, path: "\(basePath).limits")
            diagnostics.append(contentsOf: requests.diagnostics)
            diagnostics.append(contentsOf: limits.diagnostics)

            if let requestCPU = requests.resources.cpuMillicores,
               let limitCPU = limits.resources.cpuMillicores,
               requestCPU > limitCPU {
                diagnostics.append(.init(
                    code: .requestExceedsLimit,
                    path: "\(basePath).requests.cpu"
                ))
            }
            if let requestMemory = requests.resources.memoryBytes,
               let limitMemory = limits.resources.memoryBytes,
               requestMemory > limitMemory {
                diagnostics.append(.init(
                    code: .requestExceedsLimit,
                    path: "\(basePath).requests.memory"
                ))
            }

            if requests.diagnostics.isEmpty,
               limits.diagnostics.isEmpty,
               (requests.resources.cpuMillicores == nil || limits.resources.cpuMillicores == nil
                || requests.resources.cpuMillicores! <= limits.resources.cpuMillicores!),
               (requests.resources.memoryBytes == nil || limits.resources.memoryBytes == nil
                || requests.resources.memoryBytes! <= limits.resources.memoryBytes!) {
                do {
                    normalized.append(try KubernetesContainerComputeResources(
                        requests: requests.resources,
                        limits: limits.resources
                    ))
                } catch {
                    diagnostics.append(.init(code: .invalidQuantity, path: basePath))
                }
            }
        }

        guard diagnostics.isEmpty, normalized.count == containers.count else {
            return KubernetesResourceAdmissionResult(admission: nil, diagnostics: diagnostics)
        }

        do {
            return KubernetesResourceAdmissionResult(
                admission: try KubernetesWorkloadComputeResources(
                    containers: normalized,
                    replicas: deployment ? replicas : 1
                ),
                diagnostics: []
            )
        } catch KubernetesResourceAdmissionDomainError.aggregateOverflow {
            return failure(.aggregateOverflow, path: "$.spec.containers")
        } catch KubernetesResourceAdmissionDomainError.replicaOverflow {
            return failure(.replicaOverflow, path: "$.spec.replicas")
        } catch KubernetesResourceAdmissionDomainError.invalidReplicaCount {
            return failure(.invalidReplicaCount, path: "$.spec.replicas")
        } catch {
            return failure(.invalidQuantity, path: "$.spec.containers")
        }
    }

    private static func parse(
        _ entries: [KubernetesResourceQuantityEntry],
        path: String
    ) -> ParsedResourceMap {
        guard entries.count <= maximumResourceEntriesPerMap else {
            return ParsedResourceMap(
                resources: emptyResources(),
                diagnostics: [.init(code: .invalidResourceEntryCount, path: path)]
            )
        }

        let groups = Dictionary(grouping: entries, by: \.key)
        let orderedKeys = groups.keys.sorted(by: resourceKeyComesBefore)
        var cpu: Int64?
        var memory: Int64?
        var diagnostics: [KubernetesResourceAdmissionDiagnostic] = []

        for key in orderedKeys {
            let values = groups[key] ?? []
            let keyPath = resourcePath(base: path, key: key)
            guard values.count == 1 else {
                diagnostics.append(.init(code: .duplicateResource, path: keyPath))
                continue
            }
            guard key == "cpu" || key == "memory" else {
                diagnostics.append(.init(code: .unsupportedResource, path: keyPath))
                continue
            }
            guard let raw = values[0].value else {
                diagnostics.append(.init(code: .missingQuantity, path: keyPath))
                continue
            }
            switch key == "cpu" ? parseCPU(raw) : parseMemory(raw) {
            case .success(let value):
                if key == "cpu" { cpu = value } else { memory = value }
            case .failure(let code):
                diagnostics.append(.init(code: code, path: keyPath))
            }
        }

        return ParsedResourceMap(
            resources: (try? KubernetesComputeResources(
                cpuMillicores: cpu,
                memoryBytes: memory
            )) ?? emptyResources(),
            diagnostics: diagnostics
        )
    }

    private static func parseCPU(_ raw: String) -> QuantityParseResult {
        if raw.hasSuffix("m") {
            let digits = String(raw.dropLast())
            guard canonicalUnsignedInteger(digits) else { return .failure(.invalidQuantity) }
            return positiveInt64(digits, multiplier: 1)
        }
        if raw.last?.isLetter == true {
            return .failure(.unsupportedUnit)
        }
        if let dot = raw.firstIndex(of: ".") {
            guard raw[raw.index(after: dot)...].contains(".") == false else {
                return .failure(.invalidQuantity)
            }
            let integer = String(raw[..<dot])
            let fraction = String(raw[raw.index(after: dot)...])
            guard canonicalUnsignedInteger(integer),
                  (1...3).contains(fraction.count),
                  fraction.allSatisfy(\.isNumber),
                  fraction.last != "0" else {
                return .failure(.invalidQuantity)
            }
            guard let integerValue = Int64(integer) else { return .failure(.quantityOverflow) }
            let scaledInteger = integerValue.multipliedReportingOverflow(by: 1_000)
            guard !scaledInteger.overflow else { return .failure(.quantityOverflow) }
            guard let fractionValue = Int64(fraction) else { return .failure(.invalidQuantity) }
            let scale = fraction.count == 1 ? 100 : (fraction.count == 2 ? 10 : 1)
            let scaledFraction = fractionValue * Int64(scale)
            let total = scaledInteger.partialValue.addingReportingOverflow(scaledFraction)
            guard !total.overflow else { return .failure(.quantityOverflow) }
            return total.partialValue > 0
                ? .success(total.partialValue)
                : .failure(.nonPositiveQuantity)
        }
        guard canonicalUnsignedInteger(raw) else { return .failure(.invalidQuantity) }
        return positiveInt64(raw, multiplier: 1_000)
    }

    private static func parseMemory(_ raw: String) -> QuantityParseResult {
        let units: [(String, Int64)] = [
            ("Ki", 1_024),
            ("Mi", 1_048_576),
            ("Gi", 1_073_741_824),
            ("k", 1_000),
            ("M", 1_000_000),
            ("G", 1_000_000_000),
        ]
        for (suffix, multiplier) in units where raw.hasSuffix(suffix) {
            let digits = String(raw.dropLast(suffix.count))
            guard canonicalUnsignedInteger(digits) else { return .failure(.invalidQuantity) }
            return positiveInt64(digits, multiplier: multiplier)
        }
        if raw.contains(where: { $0 == "." || $0 == "+" || $0 == "-" })
            || raw.contains("e")
            || raw.contains("E") {
            return .failure(.invalidQuantity)
        }
        if raw.contains(where: \.isLetter) {
            return .failure(.unsupportedUnit)
        }
        guard canonicalUnsignedInteger(raw) else { return .failure(.invalidQuantity) }
        return positiveInt64(raw, multiplier: 1)
    }

    private static func canonicalUnsignedInteger(_ raw: String) -> Bool {
        guard !raw.isEmpty,
              raw.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return false }
        return raw == "0" || raw.first != "0"
    }

    private static func positiveInt64(_ digits: String, multiplier: Int64) -> QuantityParseResult {
        guard let value = Int64(digits) else { return .failure(.quantityOverflow) }
        guard value > 0 else { return .failure(.nonPositiveQuantity) }
        let result = value.multipliedReportingOverflow(by: multiplier)
        guard !result.overflow, result.partialValue > 0 else {
            return .failure(.quantityOverflow)
        }
        return .success(result.partialValue)
    }

    private static func resourceKeyComesBefore(_ lhs: String, _ rhs: String) -> Bool {
        func rank(_ key: String) -> Int {
            switch key {
            case "cpu": return 0
            case "memory": return 1
            default: return 2
            }
        }
        let lhsRank = rank(lhs)
        let rhsRank = rank(rhs)
        return lhsRank == rhsRank ? lhs < rhs : lhsRank < rhsRank
    }

    private static func resourcePath(base: String, key: String) -> String {
        if key == "cpu" || key == "memory" { return "\(base).\(key)" }
        return "\(base)[\"\(escapedPathKey(key))\"]"
    }

    private static func escapedPathKey(_ key: String) -> String {
        var result = ""
        for scalar in key.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x20...0x7E: result.unicodeScalars.append(scalar)
            default: result += String(format: "\\u%04X", scalar.value)
            }
        }
        return result
    }

    private static func emptyResources() -> KubernetesComputeResources {
        try! KubernetesComputeResources()
    }

    private static func failure(
        _ code: KubernetesResourceAdmissionDiagnosticCode,
        path: String
    ) -> KubernetesResourceAdmissionResult {
        KubernetesResourceAdmissionResult(
            admission: nil,
            diagnostics: [.init(code: code, path: path)]
        )
    }

    private struct ParsedResourceMap {
        let resources: KubernetesComputeResources
        let diagnostics: [KubernetesResourceAdmissionDiagnostic]
    }

    private enum QuantityParseResult {
        case success(Int64)
        case failure(KubernetesResourceAdmissionDiagnosticCode)
    }
}

public enum KubernetesResourceAdmissionDomainError: Error, Equatable, Sendable {
    case aggregateOverflow
    case inconsistentDerivedTotals
    case invalidContainerCount
    case invalidNormalizedValue(String)
    case invalidReplicaCount
    case replicaOverflow
    case requestExceedsLimit(String)
    case unsupportedContract
}

private enum StrictKubernetesResourceCoding {
    static func rejectUnknownKeys(from decoder: Decoder, allowed: Set<String>) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        if let unknown = container.allKeys.map(\.stringValue).first(where: { !allowed.contains($0) }) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported key \(unknown)."
            ))
        }
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}
