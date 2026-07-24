import CryptoKit
import Foundation
import HostwrightCore
import HostwrightRuntime

public enum LifecyclePlanError: Error, Equatable, Sendable {
    case invalidField(String)
    case duplicateNodeKey(String)
    case missingDependency(node: String, dependency: String)
    case dependencyCycle([String])
    case encodingFailed
}

public enum LifecycleCommand: String, Codable, CaseIterable, Equatable, Sendable {
    case up
    case down
    case run
    case start
    case stop
    case restart
    case remove = "rm"
    case update
    case apply
    case resume
    case rollback
}

public struct LifecyclePlanAction: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public static let validate = LifecyclePlanAction(rawValue: "validate")
    public static let create = LifecyclePlanAction(rawValue: "create")
    public static let start = LifecyclePlanAction(rawValue: "start")
    public static let stop = LifecyclePlanAction(rawValue: "stop")
    public static let restart = LifecyclePlanAction(rawValue: "restart")
    public static let delete = LifecyclePlanAction(rawValue: "delete")
    public static let verify = LifecyclePlanAction(rawValue: "verify")
    public static let runHook = LifecyclePlanAction(rawValue: "run-hook")
    public static let promote = LifecyclePlanAction(rawValue: "promote")
    public static let retire = LifecyclePlanAction(rawValue: "retire")

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var mutatesRuntime: Bool {
        self != .validate && self != .verify
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer()
        self.init(rawValue: try values.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.singleValueContainer()
        try values.encode(rawValue)
    }
}

public struct LifecyclePlanCondition: Codable, Equatable, Hashable, Sendable {
    public let kind: String
    public let subject: String
    public let expectedValue: String

    public init(kind: String, subject: String, expectedValue: String) {
        self.kind = kind
        self.subject = subject
        self.expectedValue = expectedValue
    }

    var orderingKey: String {
        [kind, subject, expectedValue].joined(separator: "\u{1f}")
    }
}

public struct LifecycleCompensation: Codable, Equatable, Sendable {
    public let action: LifecyclePlanAction
    public let preconditions: [LifecyclePlanCondition]
    public let timeoutSeconds: Int

    public init(
        action: LifecyclePlanAction,
        preconditions: [LifecyclePlanCondition] = [],
        timeoutSeconds: Int = 30
    ) {
        self.action = action
        self.preconditions = preconditions.sorted { $0.orderingKey < $1.orderingKey }
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct LifecyclePlanNode: Codable, Equatable, Sendable {
    public let key: String
    public let action: LifecyclePlanAction
    public let serviceName: String?
    public let resourceIdentifier: String?
    public let resourceUUID: String
    public let resourceGeneration: Int
    public let fencingToken: String
    public let dependencies: [String]
    public let preconditions: [LifecyclePlanCondition]
    public let postconditions: [LifecyclePlanCondition]
    public let timeoutSeconds: Int
    public let compensation: LifecycleCompensation?
    public let desiredSpecificationJSONRedacted: String
    public let idempotencyKey: String

    private enum CodingKeys: String, CodingKey {
        case key
        case action
        case serviceName
        case resourceIdentifier
        case resourceUUID
        case resourceGeneration
        case fencingToken
        case dependencies
        case preconditions
        case postconditions
        case timeoutSeconds
        case compensation
        case desiredSpecificationJSONRedacted
        case idempotencyKey
    }

    public init(
        key: String,
        action: LifecyclePlanAction,
        serviceName: String? = nil,
        resourceIdentifier: String? = nil,
        resourceUUID: String,
        resourceGeneration: Int,
        fencingToken: String,
        dependencies: [String] = [],
        preconditions: [LifecyclePlanCondition] = [],
        postconditions: [LifecyclePlanCondition] = [],
        timeoutSeconds: Int = 30,
        compensation: LifecycleCompensation? = nil,
        desiredSpecificationJSONRedacted: String = "{}"
    ) throws {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isStableIdentifier(normalizedKey) else {
            throw LifecyclePlanError.invalidField("Lifecycle node key must be a stable identifier.")
        }
        guard Self.isStableIdentifier(action.rawValue) else {
            throw LifecyclePlanError.invalidField("Lifecycle node action must be a stable identifier.")
        }
        guard HostwrightResourceUUID.isValid(resourceUUID),
              HostwrightResourceUUID.isValid(fencingToken),
              resourceGeneration > 0,
              (1...RuntimeCommandTimeout.maximumSeconds).contains(timeoutSeconds) else {
            throw LifecyclePlanError.invalidField(
                "Lifecycle node identity, generation, fence, or timeout is invalid."
            )
        }
        if let compensation {
            guard Self.isStableIdentifier(compensation.action.rawValue),
                  (1...RuntimeCommandTimeout.maximumSeconds).contains(compensation.timeoutSeconds) else {
                throw LifecyclePlanError.invalidField("Lifecycle compensation is invalid.")
            }
        }
        let normalizedDependencies = dependencies.sorted()
        guard Set(normalizedDependencies).count == normalizedDependencies.count,
              !normalizedDependencies.contains(normalizedKey),
              normalizedDependencies.allSatisfy(Self.isStableIdentifier) else {
            throw LifecyclePlanError.invalidField(
                "Lifecycle node dependencies must be unique stable identifiers and cannot reference self."
            )
        }
        let canonicalDesiredSpecification = try LifecycleCanonicalJSON.canonicalObjectJSON(
            desiredSpecificationJSONRedacted
        )

        self.key = normalizedKey
        self.action = action
        self.serviceName = serviceName
        self.resourceIdentifier = resourceIdentifier
        self.resourceUUID = resourceUUID.lowercased()
        self.resourceGeneration = resourceGeneration
        self.fencingToken = fencingToken.lowercased()
        self.dependencies = normalizedDependencies
        self.preconditions = preconditions.sorted { $0.orderingKey < $1.orderingKey }
        self.postconditions = postconditions.sorted { $0.orderingKey < $1.orderingKey }
        self.timeoutSeconds = timeoutSeconds
        self.compensation = compensation
        self.desiredSpecificationJSONRedacted = canonicalDesiredSpecification
        self.idempotencyKey = try Self.makeIdempotencyKey(
            key: normalizedKey,
            action: action,
            serviceName: serviceName,
            resourceIdentifier: resourceIdentifier,
            resourceUUID: resourceUUID.lowercased(),
            resourceGeneration: resourceGeneration,
            fencingToken: fencingToken.lowercased(),
            dependencies: normalizedDependencies,
            preconditions: self.preconditions,
            postconditions: self.postconditions,
            timeoutSeconds: timeoutSeconds,
            compensation: compensation,
            desiredSpecificationJSONRedacted: canonicalDesiredSpecification
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let persistedIdempotencyKey = try values.decode(String.self, forKey: .idempotencyKey)
        let canonical: LifecyclePlanNode
        do {
            canonical = try LifecyclePlanNode(
                key: values.decode(String.self, forKey: .key),
                action: values.decode(LifecyclePlanAction.self, forKey: .action),
                serviceName: values.decodeIfPresent(String.self, forKey: .serviceName),
                resourceIdentifier: values.decodeIfPresent(
                    String.self,
                    forKey: .resourceIdentifier
                ),
                resourceUUID: values.decode(String.self, forKey: .resourceUUID),
                resourceGeneration: values.decode(Int.self, forKey: .resourceGeneration),
                fencingToken: values.decode(String.self, forKey: .fencingToken),
                dependencies: values.decode([String].self, forKey: .dependencies),
                preconditions: values.decode(
                    [LifecyclePlanCondition].self,
                    forKey: .preconditions
                ),
                postconditions: values.decode(
                    [LifecyclePlanCondition].self,
                    forKey: .postconditions
                ),
                timeoutSeconds: values.decode(Int.self, forKey: .timeoutSeconds),
                compensation: values.decodeIfPresent(
                    LifecycleCompensation.self,
                    forKey: .compensation
                ),
                desiredSpecificationJSONRedacted: values.decode(
                    String.self,
                    forKey: .desiredSpecificationJSONRedacted
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Lifecycle plan node failed canonical validation.",
                    underlyingError: error
                )
            )
        }
        guard canonical.idempotencyKey == persistedIdempotencyKey else {
            throw DecodingError.dataCorruptedError(
                forKey: .idempotencyKey,
                in: values,
                debugDescription: "Lifecycle node idempotency key does not match its canonical fields."
            )
        }
        self = canonical
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key)
        try values.encode(action, forKey: .action)
        try values.encodeIfPresent(serviceName, forKey: .serviceName)
        try values.encodeIfPresent(resourceIdentifier, forKey: .resourceIdentifier)
        try values.encode(resourceUUID, forKey: .resourceUUID)
        try values.encode(resourceGeneration, forKey: .resourceGeneration)
        try values.encode(fencingToken, forKey: .fencingToken)
        try values.encode(dependencies, forKey: .dependencies)
        try values.encode(preconditions, forKey: .preconditions)
        try values.encode(postconditions, forKey: .postconditions)
        try values.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try values.encodeIfPresent(compensation, forKey: .compensation)
        try values.encode(
            desiredSpecificationJSONRedacted,
            forKey: .desiredSpecificationJSONRedacted
        )
        try values.encode(idempotencyKey, forKey: .idempotencyKey)
    }

    private static func makeIdempotencyKey(
        key: String,
        action: LifecyclePlanAction,
        serviceName: String?,
        resourceIdentifier: String?,
        resourceUUID: String,
        resourceGeneration: Int,
        fencingToken: String,
        dependencies: [String],
        preconditions: [LifecyclePlanCondition],
        postconditions: [LifecyclePlanCondition],
        timeoutSeconds: Int,
        compensation: LifecycleCompensation?,
        desiredSpecificationJSONRedacted: String
    ) throws -> String {
        struct Identity: Encodable {
            let key: String
            let action: LifecyclePlanAction
            let serviceName: String?
            let resourceIdentifier: String?
            let resourceUUID: String
            let resourceGeneration: Int
            let fencingToken: String
            let dependencies: [String]
            let preconditions: [LifecyclePlanCondition]
            let postconditions: [LifecyclePlanCondition]
            let timeoutSeconds: Int
            let compensation: LifecycleCompensation?
            let desiredSpecificationJSONRedacted: String
        }
        let data = try LifecycleCanonicalJSON.encode(
            Identity(
                key: key,
                action: action,
                serviceName: serviceName,
                resourceIdentifier: resourceIdentifier,
                resourceUUID: resourceUUID,
                resourceGeneration: resourceGeneration,
                fencingToken: fencingToken,
                dependencies: dependencies,
                preconditions: preconditions,
                postconditions: postconditions,
                timeoutSeconds: timeoutSeconds,
                compensation: compensation,
                desiredSpecificationJSONRedacted: desiredSpecificationJSONRedacted
            )
        )
        return "lifecycle-node:\(LifecycleCanonicalJSON.sha256(data))"
    }

    private static func isStableIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?$"#,
            options: .regularExpression
        ) != nil
    }
}

public struct LifecyclePlanAvailabilityImpact: Codable, Equatable, Sendable {
    public let serviceName: String
    public let mode: LifecycleUpdatePlanMode
    public let modeReason: LifecycleUpdateModeReason
    public let desiredReplicas: Int
    public let minimumAvailable: Int
    public let maximumTemporaryCapacity: Int
    public let requiresDowntime: Bool
    public let summary: String

    public init(
        serviceName: String,
        mode: LifecycleUpdatePlanMode,
        modeReason: LifecycleUpdateModeReason,
        impact: LifecycleUpdateAvailabilityImpact
    ) {
        self.serviceName = serviceName
        self.mode = mode
        self.modeReason = modeReason
        desiredReplicas = impact.desiredReplicas
        minimumAvailable = impact.minimumAvailable
        maximumTemporaryCapacity = impact.maximumTemporaryCapacity
        requiresDowntime = impact.requiresDowntime
        summary = impact.summary
    }
}

public struct LifecyclePlan: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let supportedParallelism = 1...32

    public let schemaVersion: Int
    public let command: LifecycleCommand
    public let projectID: String
    public let projectName: String
    public let projectResourceUUID: String
    public let projectGeneration: Int
    public let providerID: RuntimeProviderID
    public let providerGeneration: Int
    public let manifestSHA256: String
    public let observationSHA256: String
    public let capabilitySHA256: String
    public let parallelism: Int
    public let availabilityImpacts: [LifecyclePlanAvailabilityImpact]
    public let nodes: [LifecyclePlanNode]
    public let planSHA256: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case command
        case projectID
        case projectName
        case projectResourceUUID
        case projectGeneration
        case providerID
        case providerGeneration
        case manifestSHA256
        case observationSHA256
        case capabilitySHA256
        case parallelism
        case availabilityImpacts
        case nodes
        case planSHA256
    }

    public init(
        command: LifecycleCommand,
        projectID: String,
        projectName: String,
        projectResourceUUID: String,
        projectGeneration: Int,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        manifestSHA256: String,
        observationSHA256: String,
        capabilitySHA256: String,
        parallelism: Int = 1,
        availabilityImpacts: [LifecyclePlanAvailabilityImpact] = [],
        nodes: [LifecyclePlanNode]
    ) throws {
        let orderedImpacts = availabilityImpacts.sorted {
            ($0.serviceName, $0.mode.rawValue, $0.modeReason.rawValue) <
                ($1.serviceName, $1.mode.rawValue, $1.modeReason.rawValue)
        }
        guard !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              HostwrightResourceUUID.isValid(projectResourceUUID),
              projectGeneration > 0,
              RuntimeProviderID.knownValues.contains(providerID),
              providerGeneration > 0,
              Self.isSHA256(manifestSHA256),
              Self.isSHA256(observationSHA256),
              Self.isSHA256(capabilitySHA256),
              Self.supportedParallelism.contains(parallelism),
              Self.valid(orderedImpacts) else {
            throw LifecyclePlanError.invalidField(
                "Lifecycle plan project, provider, generation, digest, parallelism, or availability-impact fields are invalid."
            )
        }
        let orderedNodes = try LifecyclePlanCompiler.stableTopologicalOrder(nodes)

        schemaVersion = Self.currentSchemaVersion
        self.command = command
        self.projectID = projectID
        self.projectName = projectName
        self.projectResourceUUID = projectResourceUUID.lowercased()
        self.projectGeneration = projectGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.manifestSHA256 = manifestSHA256
        self.observationSHA256 = observationSHA256
        self.capabilitySHA256 = capabilitySHA256
        self.parallelism = parallelism
        self.availabilityImpacts = orderedImpacts
        self.nodes = orderedNodes
        self.planSHA256 = try Self.digest(
            command: command,
            projectID: projectID,
            projectName: projectName,
            projectResourceUUID: projectResourceUUID.lowercased(),
            projectGeneration: projectGeneration,
            providerID: providerID,
            providerGeneration: providerGeneration,
            manifestSHA256: manifestSHA256,
            observationSHA256: observationSHA256,
            capabilitySHA256: capabilitySHA256,
            parallelism: parallelism,
            availabilityImpacts: orderedImpacts,
            nodes: orderedNodes
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let persistedSchemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        let persistedPlanSHA256 = try values.decode(String.self, forKey: .planSHA256)
        guard persistedSchemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported lifecycle plan schema version."
            )
        }
        let canonical: LifecyclePlan
        do {
            canonical = try LifecyclePlan(
                command: values.decode(LifecycleCommand.self, forKey: .command),
                projectID: values.decode(String.self, forKey: .projectID),
                projectName: values.decode(String.self, forKey: .projectName),
                projectResourceUUID: values.decode(
                    String.self,
                    forKey: .projectResourceUUID
                ),
                projectGeneration: values.decode(Int.self, forKey: .projectGeneration),
                providerID: values.decode(RuntimeProviderID.self, forKey: .providerID),
                providerGeneration: values.decode(Int.self, forKey: .providerGeneration),
                manifestSHA256: values.decode(String.self, forKey: .manifestSHA256),
                observationSHA256: values.decode(
                    String.self,
                    forKey: .observationSHA256
                ),
                capabilitySHA256: values.decode(
                    String.self,
                    forKey: .capabilitySHA256
                ),
                parallelism: values.decode(Int.self, forKey: .parallelism),
                availabilityImpacts: values.decodeIfPresent(
                    [LifecyclePlanAvailabilityImpact].self,
                    forKey: .availabilityImpacts
                ) ?? [],
                nodes: values.decode([LifecyclePlanNode].self, forKey: .nodes)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Lifecycle plan failed canonical validation.",
                    underlyingError: error
                )
            )
        }
        guard canonical.planSHA256 == persistedPlanSHA256 else {
            throw DecodingError.dataCorruptedError(
                forKey: .planSHA256,
                in: values,
                debugDescription: "Lifecycle plan digest does not match its canonical fields."
            )
        }
        self = canonical
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(command, forKey: .command)
        try values.encode(projectID, forKey: .projectID)
        try values.encode(projectName, forKey: .projectName)
        try values.encode(projectResourceUUID, forKey: .projectResourceUUID)
        try values.encode(projectGeneration, forKey: .projectGeneration)
        try values.encode(providerID, forKey: .providerID)
        try values.encode(providerGeneration, forKey: .providerGeneration)
        try values.encode(manifestSHA256, forKey: .manifestSHA256)
        try values.encode(observationSHA256, forKey: .observationSHA256)
        try values.encode(capabilitySHA256, forKey: .capabilitySHA256)
        try values.encode(parallelism, forKey: .parallelism)
        if !availabilityImpacts.isEmpty {
            try values.encode(availabilityImpacts, forKey: .availabilityImpacts)
        }
        try values.encode(nodes, forKey: .nodes)
        try values.encode(planSHA256, forKey: .planSHA256)
    }

    public func canonicalJSON() throws -> String {
        let data = try LifecycleCanonicalJSON.encode(self)
        guard let value = String(data: data, encoding: .utf8) else {
            throw LifecyclePlanError.encodingFailed
        }
        return value
    }

    private static func digest(
        command: LifecycleCommand,
        projectID: String,
        projectName: String,
        projectResourceUUID: String,
        projectGeneration: Int,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        manifestSHA256: String,
        observationSHA256: String,
        capabilitySHA256: String,
        parallelism: Int,
        availabilityImpacts: [LifecyclePlanAvailabilityImpact],
        nodes: [LifecyclePlanNode]
    ) throws -> String {
        struct DigestInput: Encodable {
            let schemaVersion: Int
            let command: LifecycleCommand
            let projectID: String
            let projectName: String
            let projectResourceUUID: String
            let projectGeneration: Int
            let providerID: RuntimeProviderID
            let providerGeneration: Int
            let manifestSHA256: String
            let observationSHA256: String
            let capabilitySHA256: String
            let parallelism: Int
            let availabilityImpacts: [LifecyclePlanAvailabilityImpact]?
            let nodes: [LifecyclePlanNode]
        }
        return LifecycleCanonicalJSON.sha256(
            try LifecycleCanonicalJSON.encode(
                DigestInput(
                    schemaVersion: currentSchemaVersion,
                    command: command,
                    projectID: projectID,
                    projectName: projectName,
                    projectResourceUUID: projectResourceUUID,
                    projectGeneration: projectGeneration,
                    providerID: providerID,
                    providerGeneration: providerGeneration,
                    manifestSHA256: manifestSHA256,
                    observationSHA256: observationSHA256,
                    capabilitySHA256: capabilitySHA256,
                    parallelism: parallelism,
                    availabilityImpacts:
                        availabilityImpacts.isEmpty ? nil : availabilityImpacts,
                    nodes: nodes
                )
            )
        )
    }

    private static func valid(
        _ impacts: [LifecyclePlanAvailabilityImpact]
    ) -> Bool {
        var serviceNames: Set<String> = []
        for impact in impacts {
            let serviceName = impact.serviceName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !serviceName.isEmpty,
                  serviceName == impact.serviceName,
                  serviceName.count <= 128,
                  serviceNames.insert(serviceName).inserted,
                  impact.desiredReplicas > 0,
                  (0...impact.desiredReplicas).contains(impact.minimumAvailable),
                  impact.maximumTemporaryCapacity >= impact.desiredReplicas,
                  !impact.summary.isEmpty,
                  impact.summary.count <= 1_024,
                  !impact.summary.contains("\n"),
                  !impact.summary.contains("\r") else {
                return false
            }
        }
        return true
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}

public enum LifecyclePlanCompiler {
    public static func stableTopologicalOrder(
        _ nodes: [LifecyclePlanNode]
    ) throws -> [LifecyclePlanNode] {
        var nodesByKey: [String: LifecyclePlanNode] = [:]
        for node in nodes {
            guard nodesByKey.updateValue(node, forKey: node.key) == nil else {
                throw LifecyclePlanError.duplicateNodeKey(node.key)
            }
        }
        for node in nodes {
            for dependency in node.dependencies where nodesByKey[dependency] == nil {
                throw LifecyclePlanError.missingDependency(node: node.key, dependency: dependency)
            }
        }

        var remainingDependencies = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.key, Set($0.dependencies)) }
        )
        var dependents: [String: Set<String>] = [:]
        for node in nodes {
            for dependency in node.dependencies {
                dependents[dependency, default: []].insert(node.key)
            }
        }
        var ready = remainingDependencies
            .filter { $0.value.isEmpty }
            .map(\.key)
            .sorted()
        var ordered: [LifecyclePlanNode] = []

        while let key = ready.first {
            ready.removeFirst()
            guard let node = nodesByKey[key] else {
                throw LifecyclePlanError.encodingFailed
            }
            ordered.append(node)
            for dependent in (dependents[key] ?? []).sorted() {
                remainingDependencies[dependent]?.remove(key)
                if remainingDependencies[dependent]?.isEmpty == true,
                   !ordered.contains(where: { $0.key == dependent }),
                   !ready.contains(dependent) {
                    ready.append(dependent)
                    ready.sort()
                }
            }
            remainingDependencies.removeValue(forKey: key)
        }

        guard remainingDependencies.isEmpty else {
            throw LifecyclePlanError.dependencyCycle(remainingDependencies.keys.sorted())
        }
        return ordered
    }
}

enum LifecycleCanonicalJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw LifecyclePlanError.encodingFailed
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalObjectJSON(_ json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any],
              JSONSerialization.isValidJSONObject(object) else {
            throw LifecyclePlanError.invalidField(
                "Lifecycle desired specification must be one canonicalizable JSON object."
            )
        }
        let redacted = redact(object)
        guard JSONSerialization.isValidJSONObject(redacted),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: redacted,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let value = String(data: canonical, encoding: .utf8) else {
            throw LifecyclePlanError.invalidField(
                "Lifecycle desired specification must be one canonicalizable JSON object."
            )
        }
        return value
    }

    private static func redact(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var redacted: [String: Any] = [:]
            for (key, nested) in object {
                redacted[key] = RuntimeRedactionPolicy.default.isSensitiveKey(key)
                    ? RuntimeRedactionPolicy.default.replacement
                    : redact(nested)
            }
            return redacted
        }
        if let array = value as? [Any] {
            return array.map(redact)
        }
        if let string = value as? String {
            return RuntimeRedactionPolicy.default.redact(string)
        }
        return value
    }
}
