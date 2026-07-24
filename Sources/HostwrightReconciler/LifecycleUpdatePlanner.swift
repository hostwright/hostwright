import Foundation
import HostwrightCore
import HostwrightRuntime

public enum LifecycleUpdatePlanningError: Error, Equatable, Sendable {
    case projectMismatch(expected: String, actual: String)
    case duplicateServiceIdentity(String)
    case replicaSetChanged(String)
    case missingResourceIdentity(String)
    case invalidResourceIdentity(String)
    case inconsistentUpdatePolicy(String)
    case invalidUpdatePolicy(String)
    case dependencyCycle([String])
}

public enum LifecycleUpdatePlanMode: String, Codable, Equatable, Sendable {
    case rolling
    case recreate
}

public enum LifecycleUpdateModeReason: String, Codable, Equatable, Sendable {
    case requestedRolling = "requested-rolling"
    case requestedRecreate = "requested-recreate"
    case exclusiveHostPort = "exclusive-host-port"
}

public struct LifecycleUpdateResourceIdentity: Equatable, Sendable {
    public let identity: RuntimeServiceIdentity
    public let currentResourceIdentifier: String
    public let currentResourceUUID: String
    public let currentGeneration: Int
    public let candidateResourceIdentifier: String
    public let candidateResourceUUID: String
    public let candidateGeneration: Int

    public init(
        identity: RuntimeServiceIdentity,
        currentResourceIdentifier: String,
        currentResourceUUID: String,
        currentGeneration: Int,
        candidateResourceIdentifier: String,
        candidateResourceUUID: String,
        candidateGeneration: Int
    ) {
        self.identity = identity
        self.currentResourceIdentifier = currentResourceIdentifier
        self.currentResourceUUID = currentResourceUUID
        self.currentGeneration = currentGeneration
        self.candidateResourceIdentifier = candidateResourceIdentifier
        self.candidateResourceUUID = candidateResourceUUID
        self.candidateGeneration = candidateGeneration
    }
}

public struct LifecycleUpdateAvailabilityImpact: Codable, Equatable, Sendable {
    public let desiredReplicas: Int
    public let minimumAvailable: Int
    public let maximumTemporaryCapacity: Int
    public let requiresDowntime: Bool
    public let summary: String

    public init(
        desiredReplicas: Int,
        minimumAvailable: Int,
        maximumTemporaryCapacity: Int,
        requiresDowntime: Bool,
        summary: String
    ) {
        self.desiredReplicas = desiredReplicas
        self.minimumAvailable = minimumAvailable
        self.maximumTemporaryCapacity = maximumTemporaryCapacity
        self.requiresDowntime = requiresDowntime
        self.summary = summary
    }
}

public struct LifecycleServiceUpdatePlan: Equatable, Sendable {
    public let serviceName: String
    public let mode: LifecycleUpdatePlanMode
    public let modeReason: LifecycleUpdateModeReason
    public let previousRevisionSHA256: String
    public let desiredRevisionSHA256: String
    public let progressDeadlineSeconds: Int
    public let availabilityImpact: LifecycleUpdateAvailabilityImpact
    public let nodes: [LifecyclePlanNode]

    public init(
        serviceName: String,
        mode: LifecycleUpdatePlanMode,
        modeReason: LifecycleUpdateModeReason,
        previousRevisionSHA256: String,
        desiredRevisionSHA256: String,
        progressDeadlineSeconds: Int,
        availabilityImpact: LifecycleUpdateAvailabilityImpact,
        nodes: [LifecyclePlanNode]
    ) {
        self.serviceName = serviceName
        self.mode = mode
        self.modeReason = modeReason
        self.previousRevisionSHA256 = previousRevisionSHA256
        self.desiredRevisionSHA256 = desiredRevisionSHA256
        self.progressDeadlineSeconds = progressDeadlineSeconds
        self.availabilityImpact = availabilityImpact
        self.nodes = nodes
    }
}

public struct LifecycleUpdateResumePlan: Equatable, Sendable {
    public let satisfiedNodeKeys: [String]
    public let pendingNodes: [LifecyclePlanNode]

    public init(satisfiedNodeKeys: [String], pendingNodes: [LifecyclePlanNode]) {
        self.satisfiedNodeKeys = satisfiedNodeKeys.sorted()
        self.pendingNodes = pendingNodes
    }
}

public struct LifecycleUpdatePlan: Equatable, Sendable {
    public let projectName: String
    public let servicePlans: [LifecycleServiceUpdatePlan]
    public let nodes: [LifecyclePlanNode]

    public init(
        projectName: String,
        servicePlans: [LifecycleServiceUpdatePlan],
        nodes: [LifecyclePlanNode]
    ) {
        self.projectName = projectName
        self.servicePlans = servicePlans.sorted { $0.serviceName < $1.serviceName }
        self.nodes = nodes
    }

    public func resume(
        completedNodeIdempotencyKeys: Set<String>
    ) -> LifecycleUpdateResumePlan {
        let completed = nodes.filter {
            completedNodeIdempotencyKeys.contains($0.idempotencyKey)
        }
        let pending = nodes.filter {
            !completedNodeIdempotencyKeys.contains($0.idempotencyKey)
        }
        return LifecycleUpdateResumePlan(
            satisfiedNodeKeys: completed.map(\.key),
            pendingNodes: pending
        )
    }
}

public enum LifecycleRevisionCodecError: Error, Equatable, Sendable {
    case invalidJSON
    case nonCanonicalJSON
    case missingField(String)
    case unknownField(String)
    case invalidField(String)
}

public enum LifecycleRevisionCodec {
    public static func redactedDesiredJSON(
        for service: DesiredRuntimeService
    ) throws -> String {
        let environment = service.environment.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.value < rhs.value
        }.map { entry -> [String: Any] in
            var encoded: [String: Any] = [
                "name": entry.name,
                "sensitive": entry.isSensitive || entry.secretReference != nil,
                "value": entry.isSensitive || entry.secretReference != nil
                    ? RuntimeRedactionPolicy.default.replacement
                    : entry.value
            ]
            if let reference = entry.secretReference {
                encoded["reference"] = reference.redactedDescription
                encoded["referenceDigest"] = LifecycleCanonicalJSON.sha256(
                    Data(reference.rawValue.utf8)
                )
            }
            return encoded
        }
        let dependencies = service.dependencies.sorted {
            ($0.serviceName, $0.condition.rawValue) <
                ($1.serviceName, $1.condition.rawValue)
        }.map {
            [
                "condition": $0.condition.rawValue,
                "service": $0.serviceName
            ]
        }
        let ports = service.ports.sorted {
            (
                $0.hostPort ?? -1,
                $0.containerPort,
                $0.protocolName.rawValue,
                $0.bindAddress ?? ""
            ) < (
                $1.hostPort ?? -1,
                $1.containerPort,
                $1.protocolName.rawValue,
                $1.bindAddress ?? ""
            )
        }.map {
            [
                "bindAddress": $0.bindAddress.map { $0 as Any } ?? NSNull(),
                "containerPort": $0.containerPort,
                "hostPort": $0.hostPort.map { $0 as Any } ?? NSNull(),
                "protocol": $0.protocolName.rawValue
            ]
        }
        let mounts = service.mounts.sorted {
            ($0.target, $0.source, $0.access.rawValue) <
                ($1.target, $1.source, $1.access.rawValue)
        }.map {
            [
                "access": $0.access.rawValue,
                "source": $0.source,
                "target": $0.target
            ]
        }
        var probeObject: [String: Any] = [:]
        for kind in RuntimeProbeKind.allCases {
            if let probe = service.probes[kind] {
                probeObject[kind.rawValue] = encode(probe)
            }
        }
        let health: Any
        if let healthCheck = service.healthCheck {
            health = [
                "command": healthCheck.command,
                "intervalSeconds": healthCheck.intervalSeconds,
                "timeoutSeconds": healthCheck.timeout.seconds
            ]
        } else {
            health = NSNull()
        }
        let labels = Dictionary(
            uniqueKeysWithValues: service.labels.sorted { $0.key < $1.key }
        )
        let object: [String: Any] = [
            "command": service.command,
            "cpuCount": service.cpuCount.map { $0 as Any } ?? NSNull(),
            "dependencies": dependencies,
            "entrypoint": service.entrypoint,
            "environment": environment,
            "groupID": service.groupID.map { String($0) as Any } ?? NSNull(),
            "healthCheck": health,
            "hooks": [
                "postStart": service.hooks.postStart.map { $0 as Any } ?? NSNull(),
                "preStop": service.hooks.preStop.map { $0 as Any } ?? NSNull()
            ],
            "identity": [
                "instance": service.identity.instanceName.map { $0 as Any } ?? NSNull(),
                "project": service.identity.projectName,
                "service": service.identity.serviceName
            ],
            "image": service.image,
            "init": service.initProcess,
            "labels": labels,
            "logicalServiceName": service.logicalServiceName,
            "memoryBytes": service.memoryBytes.map { String($0) as Any } ?? NSNull(),
            "mounts": mounts,
            "platform": [
                "architecture": service.platformArchitecture,
                "operatingSystem": service.platformOperatingSystem
            ],
            "ports": ports,
            "probes": probeObject,
            "readOnlyRootFilesystem": service.readOnlyRootFilesystem,
            "replicaIndex": service.replicaIndex,
            "restartPolicy": service.restartPolicy.rawValue,
            "rosetta": service.rosetta,
            "sharedMemoryBytes":
                service.sharedMemoryBytes.map { String($0) as Any } ?? NSNull(),
            "updatePolicy": [
                "maxSurge": service.updatePolicy.maxSurge,
                "maxUnavailable": service.updatePolicy.maxUnavailable,
                "progressDeadlineSeconds": service.updatePolicy.progressDeadlineSeconds,
                "strategy": service.updatePolicy.strategy.rawValue
            ],
            "userID": service.userID.map { String($0) as Any } ?? NSNull(),
            "virtualization": service.virtualization,
            "workingDirectory":
                service.workingDirectory.map { $0 as Any } ?? NSNull()
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let json = String(data: data, encoding: .utf8) else {
            throw LifecyclePlanError.encodingFailed
        }
        return try LifecycleCanonicalJSON.canonicalObjectJSON(json)
    }

    public static func revisionSHA256(
        for service: DesiredRuntimeService
    ) throws -> String {
        LifecycleCanonicalJSON.sha256(
            Data(try redactedDesiredJSON(for: service).utf8)
        )
    }

    public static func decodeRedactedDesiredJSON(
        _ json: String
    ) throws -> DesiredRuntimeService {
        guard let data = json.data(using: .utf8) else {
            throw LifecycleRevisionCodecError.invalidJSON
        }
        let canonical: String
        do {
            canonical = try LifecycleCanonicalJSON.canonicalObjectJSON(json)
        } catch {
            throw LifecycleRevisionCodecError.invalidJSON
        }
        guard canonical == json else {
            throw LifecycleRevisionCodecError.nonCanonicalJSON
        }
        do {
            return try JSONDecoder().decode(RevisionDocument.self, from: data).service()
        } catch let error as LifecycleRevisionCodecError {
            throw error
        } catch {
            throw LifecycleRevisionCodecError.invalidField(
                decodingPath(for: error)
            )
        }
    }

    private static func encode(
        _ probe: RuntimeProbeConfiguration
    ) -> [String: Any] {
        let action: [String: Any]
        switch probe.action {
        case .exec(let value):
            action = ["kind": RuntimeProbeActionKind.exec.rawValue, "command": value.command]
        case .http(let value):
            action = [
                "kind": RuntimeProbeActionKind.http.rawValue,
                "path": value.path,
                "port": value.port
            ]
        case .tcp(let value):
            action = ["kind": RuntimeProbeActionKind.tcp.rawValue, "port": value.port]
        }
        return [
            "action": action,
            "failureThreshold": probe.failureThreshold,
            "intervalSeconds": probe.intervalSeconds,
            "startPeriodSeconds": probe.startPeriodSeconds,
            "successThreshold": probe.successThreshold,
            "timeoutSeconds": probe.timeoutSeconds
        ]
    }

    private static func validateKeys(
        _ container: KeyedDecodingContainer<RevisionCodingKey>,
        required: Set<String>,
        optional: Set<String> = [],
        path: String
    ) throws {
        let actual = Set(container.allKeys.map(\.stringValue))
        if let unknown = actual.subtracting(required.union(optional)).sorted().first {
            throw LifecycleRevisionCodecError.unknownField(
                path.isEmpty ? unknown : "\(path).\(unknown)"
            )
        }
        if let missing = required.subtracting(actual).sorted().first {
            throw LifecycleRevisionCodecError.missingField(
                path.isEmpty ? missing : "\(path).\(missing)"
            )
        }
    }

    private static func invalidEnum(
        _ path: String
    ) -> LifecycleRevisionCodecError {
        .invalidField(path)
    }

    private static func decodingPath(for error: Error) -> String {
        let path: [CodingKey]
        switch error {
        case DecodingError.typeMismatch(_, let context):
            path = context.codingPath
        case DecodingError.valueNotFound(_, let context):
            path = context.codingPath
        case DecodingError.keyNotFound(let key, let context):
            return (context.codingPath + [key])
                .map(\.stringValue)
                .joined(separator: ".")
        case DecodingError.dataCorrupted(let context):
            path = context.codingPath
        default:
            return "revision"
        }
        let value = path.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "revision" : value
    }

    private struct RevisionDocument: Decodable {
        let command: [String]
        let cpuCount: Int?
        let dependencies: [DependencyDocument]
        let entrypoint: [String]
        let environment: [EnvironmentDocument]
        let groupID: String?
        let healthCheck: HealthDocument?
        let hooks: HooksDocument
        let identity: IdentityDocument
        let image: String
        let initProcess: Bool
        let labels: [String: String]
        let logicalServiceName: String
        let memoryBytes: String?
        let mounts: [MountDocument]
        let platform: PlatformDocument
        let ports: [PortDocument]
        let probes: ProbesDocument
        let readOnlyRootFilesystem: Bool
        let replicaIndex: Int
        let restartPolicy: String
        let rosetta: Bool
        let sharedMemoryBytes: String?
        let updatePolicy: UpdatePolicyDocument
        let userID: String?
        let virtualization: Bool
        let workingDirectory: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RevisionCodingKey.self)
            try LifecycleRevisionCodec.validateKeys(
                container,
                required: [
                    "command", "cpuCount", "dependencies", "entrypoint",
                    "environment", "groupID", "healthCheck", "hooks", "identity",
                    "image", "init", "labels", "logicalServiceName",
                    "memoryBytes", "mounts", "platform", "ports", "probes",
                    "readOnlyRootFilesystem", "replicaIndex", "restartPolicy",
                    "rosetta", "sharedMemoryBytes", "updatePolicy", "userID",
                    "virtualization", "workingDirectory"
                ],
                path: ""
            )
            command = try container.decode([String].self, forKey: "command")
            cpuCount = try container.decodeIfPresent(Int.self, forKey: "cpuCount")
            dependencies = try container.decode(
                [DependencyDocument].self,
                forKey: "dependencies"
            )
            entrypoint = try container.decode([String].self, forKey: "entrypoint")
            environment = try container.decode(
                [EnvironmentDocument].self,
                forKey: "environment"
            )
            groupID = try container.decodeIfPresent(String.self, forKey: "groupID")
            healthCheck = try container.decodeIfPresent(
                HealthDocument.self,
                forKey: "healthCheck"
            )
            hooks = try container.decode(HooksDocument.self, forKey: "hooks")
            identity = try container.decode(IdentityDocument.self, forKey: "identity")
            image = try container.decode(String.self, forKey: "image")
            initProcess = try container.decode(Bool.self, forKey: "init")
            labels = try container.decode([String: String].self, forKey: "labels")
            logicalServiceName = try container.decode(
                String.self,
                forKey: "logicalServiceName"
            )
            memoryBytes = try container.decodeIfPresent(
                String.self,
                forKey: "memoryBytes"
            )
            mounts = try container.decode([MountDocument].self, forKey: "mounts")
            platform = try container.decode(PlatformDocument.self, forKey: "platform")
            ports = try container.decode([PortDocument].self, forKey: "ports")
            probes = try container.decode(ProbesDocument.self, forKey: "probes")
            readOnlyRootFilesystem = try container.decode(
                Bool.self,
                forKey: "readOnlyRootFilesystem"
            )
            replicaIndex = try container.decode(Int.self, forKey: "replicaIndex")
            restartPolicy = try container.decode(String.self, forKey: "restartPolicy")
            rosetta = try container.decode(Bool.self, forKey: "rosetta")
            sharedMemoryBytes = try container.decodeIfPresent(
                String.self,
                forKey: "sharedMemoryBytes"
            )
            updatePolicy = try container.decode(
                UpdatePolicyDocument.self,
                forKey: "updatePolicy"
            )
            userID = try container.decodeIfPresent(String.self, forKey: "userID")
            virtualization = try container.decode(Bool.self, forKey: "virtualization")
            workingDirectory = try container.decodeIfPresent(
                String.self,
                forKey: "workingDirectory"
            )
        }

        func service() throws -> DesiredRuntimeService {
            guard let restart = RuntimeRestartPolicy(rawValue: restartPolicy) else {
                throw LifecycleRevisionCodec.invalidEnum("restartPolicy")
            }
            guard let strategy = RuntimeUpdateStrategy(
                rawValue: updatePolicy.strategy
            ) else {
                throw LifecycleRevisionCodec.invalidEnum("updatePolicy.strategy")
            }
            let decodedMemory = try unsigned(memoryBytes, path: "memoryBytes")
            let decodedSharedMemory = try unsigned(
                sharedMemoryBytes,
                path: "sharedMemoryBytes"
            )
            let decodedUser = try unsigned32(userID, path: "userID")
            let decodedGroup = try unsigned32(groupID, path: "groupID")
            return DesiredRuntimeService(
                identity: RuntimeServiceIdentity(
                    projectName: identity.project,
                    serviceName: identity.service,
                    instanceName: identity.instance
                ),
                logicalServiceName: logicalServiceName,
                replicaIndex: replicaIndex,
                image: image,
                platformOperatingSystem: platform.operatingSystem,
                platformArchitecture: platform.architecture,
                cpuCount: cpuCount,
                memoryBytes: decodedMemory,
                userID: decodedUser,
                groupID: decodedGroup,
                workingDirectory: workingDirectory,
                entrypoint: entrypoint,
                command: command,
                initProcess: initProcess,
                dependencies: try dependencies.map { try $0.value },
                environment: try environment.map { try $0.value },
                labels: labels,
                ports: try ports.map { try $0.value },
                mounts: try mounts.map { try $0.value },
                healthCheck: healthCheck?.value,
                probes: try probes.value,
                restartPolicy: restart,
                updatePolicy: RuntimeUpdatePolicy(
                    strategy: strategy,
                    maxSurge: updatePolicy.maxSurge,
                    maxUnavailable: updatePolicy.maxUnavailable,
                    progressDeadlineSeconds: updatePolicy.progressDeadlineSeconds
                ),
                hooks: RuntimeLifecycleHooks(
                    postStart: hooks.postStart,
                    preStop: hooks.preStop
                ),
                rosetta: rosetta,
                virtualization: virtualization,
                readOnlyRootFilesystem: readOnlyRootFilesystem,
                sharedMemoryBytes: decodedSharedMemory
            )
        }

        private func unsigned(
            _ value: String?,
            path: String
        ) throws -> UInt64? {
            guard let value else { return nil }
            guard !value.isEmpty, value.allSatisfy(\.isNumber),
                  let result = UInt64(value) else {
                throw LifecycleRevisionCodecError.invalidField(path)
            }
            return result
        }

        private func unsigned32(
            _ value: String?,
            path: String
        ) throws -> UInt32? {
            guard let decoded = try unsigned(value, path: path) else { return nil }
            guard let result = UInt32(exactly: decoded) else {
                throw LifecycleRevisionCodecError.invalidField(path)
            }
            return result
        }
    }

    private struct IdentityDocument: Decodable {
        let instance: String?
        let project: String
        let service: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RevisionCodingKey.self)
            try LifecycleRevisionCodec.validateKeys(
                container,
                required: ["instance", "project", "service"],
                path: "identity"
            )
            instance = try container.decodeIfPresent(String.self, forKey: "instance")
            project = try container.decode(String.self, forKey: "project")
            service = try container.decode(String.self, forKey: "service")
        }
    }

    private struct EnvironmentDocument: Decodable {
        let name: String
        let sensitive: Bool
        let valueText: String
        let reference: String?
        let referenceDigest: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RevisionCodingKey.self)
            try LifecycleRevisionCodec.validateKeys(
                container,
                required: ["name", "sensitive", "value"],
                optional: ["reference", "referenceDigest"],
                path: "environment"
            )
            name = try container.decode(String.self, forKey: "name")
            sensitive = try container.decode(Bool.self, forKey: "sensitive")
            valueText = try container.decode(String.self, forKey: "value")
            reference = try container.decodeIfPresent(String.self, forKey: "reference")
            referenceDigest = try container.decodeIfPresent(
                String.self,
                forKey: "referenceDigest"
            )
        }

        var value: RuntimeEnvironmentValue {
            get throws {
                guard reference == nil ? referenceDigest == nil : referenceDigest != nil else {
                    throw LifecycleRevisionCodecError.invalidField(
                        "environment.reference"
                    )
                }
                if let reference {
                    guard sensitive,
                          reference == "keychain://[REDACTED]",
                          let referenceDigest,
                          referenceDigest.count == 64,
                          referenceDigest.allSatisfy({
                              ("0"..."9").contains($0) || ("a"..."f").contains($0)
                          }) else {
                        throw LifecycleRevisionCodecError.invalidField(
                            "environment.reference"
                        )
                    }
                }
                if sensitive {
                    guard valueText == RuntimeRedactionPolicy.default.replacement else {
                        throw LifecycleRevisionCodecError.invalidField(
                            "environment.value"
                        )
                    }
                    return RuntimeEnvironmentValue(
                        name: name,
                        value: RuntimeRedactionPolicy.default.replacement,
                        isSensitive: true,
                        secretReference: nil
                    )
                }
                guard reference == nil else {
                    throw LifecycleRevisionCodecError.invalidField(
                        "environment.reference"
                    )
                }
                return RuntimeEnvironmentValue(
                    name: name,
                    value: valueText,
                    isSensitive: false,
                    secretReference: nil
                )
            }
        }
    }

    private struct DependencyDocument: Decodable {
        let condition: String
        let service: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RevisionCodingKey.self)
            try LifecycleRevisionCodec.validateKeys(
                container,
                required: ["condition", "service"],
                path: "dependencies"
            )
            condition = try container.decode(String.self, forKey: "condition")
            service = try container.decode(String.self, forKey: "service")
        }

        var value: RuntimeServiceDependency {
            get throws {
                guard let decoded = RuntimeDependencyCondition(rawValue: condition) else {
                    throw LifecycleRevisionCodec.invalidEnum(
                        "dependencies.condition"
                    )
                }
                return RuntimeServiceDependency(
                    serviceName: service,
                    condition: decoded
                )
            }
        }
    }

    private struct PortDocument: Decodable {
        let bindAddress: String?
        let containerPort: Int
        let hostPort: Int?
        let protocolName: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RevisionCodingKey.self)
            try LifecycleRevisionCodec.validateKeys(
                container,
                required: ["bindAddress", "containerPort", "hostPort", "protocol"],
                path: "ports"
            )
            bindAddress = try container.decodeIfPresent(
                String.self,
                forKey: "bindAddress"
            )
            containerPort = try container.decode(Int.self, forKey: "containerPort")
            hostPort = try container.decodeIfPresent(Int.self, forKey: "hostPort")
            protocolName = try container.decode(String.self, forKey: "protocol")
        }

        var value: RuntimePortMapping {
            get throws {
                guard let decoded = RuntimePortProtocol(rawValue: protocolName) else {
                    throw LifecycleRevisionCodec.invalidEnum("ports.protocol")
                }
                return RuntimePortMapping(
                    hostPort: hostPort,
                    containerPort: containerPort,
                    protocolName: decoded,
                    bindAddress: bindAddress
                )
            }
        }
    }

    private struct MountDocument: Decodable {
        let access: String
        let source: String
        let target: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RevisionCodingKey.self)
            try LifecycleRevisionCodec.validateKeys(
                container,
                required: ["access", "source", "target"],
                path: "mounts"
            )
            access = try container.decode(String.self, forKey: "access")
            source = try container.decode(String.self, forKey: "source")
            target = try container.decode(String.self, forKey: "target")
        }

        var value: RuntimeMountReference {
            get throws {
                guard let decoded = RuntimeMountAccess(rawValue: access) else {
                    throw LifecycleRevisionCodec.invalidEnum("mounts.access")
                }
                return RuntimeMountReference(
                    source: source,
                    target: target,
                    access: decoded
                )
            }
        }
    }

    private struct HealthDocument: Decodable {
        let command: [String]
        let intervalSeconds: Int
        let timeoutSeconds: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RevisionCodingKey.self)
            try LifecycleRevisionCodec.validateKeys(
                container,
                required: ["command", "intervalSeconds", "timeoutSeconds"],
                path: "healthCheck"
            )
            command = try container.decode([String].self, forKey: "command")
            intervalSeconds = try container.decode(Int.self, forKey: "intervalSeconds")
            timeoutSeconds = try container.decode(Int.self, forKey: "timeoutSeconds")
        }

        var value: RuntimeHealthCheckSpec {
            RuntimeHealthCheckSpec(
                command: command,
                intervalSeconds: intervalSeconds,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    private struct HooksDocument: Decodable {
        let postStart: [String]?
        let preStop: [String]?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RevisionCodingKey.self)
            try LifecycleRevisionCodec.validateKeys(
                container,
                required: ["postStart", "preStop"],
                path: "hooks"
            )
            postStart = try container.decodeIfPresent([String].self, forKey: "postStart")
            preStop = try container.decodeIfPresent([String].self, forKey: "preStop")
        }
    }

    private struct PlatformDocument: Decodable {
        let architecture: String
        let operatingSystem: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RevisionCodingKey.self)
            try LifecycleRevisionCodec.validateKeys(
                container,
                required: ["architecture", "operatingSystem"],
                path: "platform"
            )
            architecture = try container.decode(String.self, forKey: "architecture")
            operatingSystem = try container.decode(
                String.self,
                forKey: "operatingSystem"
            )
        }
    }

    private struct UpdatePolicyDocument: Decodable {
        let maxSurge: Int
        let maxUnavailable: Int
        let progressDeadlineSeconds: Int
        let strategy: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RevisionCodingKey.self)
            try LifecycleRevisionCodec.validateKeys(
                container,
                required: [
                    "maxSurge", "maxUnavailable", "progressDeadlineSeconds", "strategy"
                ],
                path: "updatePolicy"
            )
            maxSurge = try container.decode(Int.self, forKey: "maxSurge")
            maxUnavailable = try container.decode(Int.self, forKey: "maxUnavailable")
            progressDeadlineSeconds = try container.decode(
                Int.self,
                forKey: "progressDeadlineSeconds"
            )
            strategy = try container.decode(String.self, forKey: "strategy")
        }
    }

    private struct ProbesDocument: Decodable {
        let startup: ProbeDocument?
        let readiness: ProbeDocument?
        let liveness: ProbeDocument?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RevisionCodingKey.self)
            try LifecycleRevisionCodec.validateKeys(
                container,
                required: [],
                optional: Set(RuntimeProbeKind.allCases.map(\.rawValue)),
                path: "probes"
            )
            startup = try container.decodeIfPresent(
                ProbeDocument.self,
                forKey: "startup"
            )
            readiness = try container.decodeIfPresent(
                ProbeDocument.self,
                forKey: "readiness"
            )
            liveness = try container.decodeIfPresent(
                ProbeDocument.self,
                forKey: "liveness"
            )
        }

        var value: RuntimeProbeSet {
            get throws {
                RuntimeProbeSet(
                    startup: try startup?.value,
                    readiness: try readiness?.value,
                    liveness: try liveness?.value
                )
            }
        }
    }

    private struct ProbeDocument: Decodable {
        let action: ProbeActionDocument
        let failureThreshold: Int
        let intervalSeconds: Int
        let startPeriodSeconds: Int
        let successThreshold: Int
        let timeoutSeconds: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RevisionCodingKey.self)
            try LifecycleRevisionCodec.validateKeys(
                container,
                required: [
                    "action", "failureThreshold", "intervalSeconds",
                    "startPeriodSeconds", "successThreshold", "timeoutSeconds"
                ],
                path: "probes"
            )
            action = try container.decode(ProbeActionDocument.self, forKey: "action")
            failureThreshold = try container.decode(
                Int.self,
                forKey: "failureThreshold"
            )
            intervalSeconds = try container.decode(
                Int.self,
                forKey: "intervalSeconds"
            )
            startPeriodSeconds = try container.decode(
                Int.self,
                forKey: "startPeriodSeconds"
            )
            successThreshold = try container.decode(
                Int.self,
                forKey: "successThreshold"
            )
            timeoutSeconds = try container.decode(Int.self, forKey: "timeoutSeconds")
        }

        var value: RuntimeProbeConfiguration {
            get throws {
                RuntimeProbeConfiguration(
                    action: try action.value,
                    startPeriodSeconds: startPeriodSeconds,
                    intervalSeconds: intervalSeconds,
                    timeoutSeconds: timeoutSeconds,
                    successThreshold: successThreshold,
                    failureThreshold: failureThreshold
                )
            }
        }
    }

    private struct ProbeActionDocument: Decodable {
        let kind: RuntimeProbeActionKind
        let command: [String]?
        let path: String?
        let port: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RevisionCodingKey.self)
            let kindValue = try container.decode(String.self, forKey: "kind")
            guard let kind = RuntimeProbeActionKind(rawValue: kindValue) else {
                throw LifecycleRevisionCodec.invalidEnum("probes.action.kind")
            }
            self.kind = kind
            switch kind {
            case .exec:
                try LifecycleRevisionCodec.validateKeys(
                    container,
                    required: ["kind", "command"],
                    path: "probes.action"
                )
                command = try container.decode([String].self, forKey: "command")
                path = nil
                port = nil
            case .http:
                try LifecycleRevisionCodec.validateKeys(
                    container,
                    required: ["kind", "path", "port"],
                    path: "probes.action"
                )
                command = nil
                path = try container.decode(String.self, forKey: "path")
                port = try container.decode(Int.self, forKey: "port")
            case .tcp:
                try LifecycleRevisionCodec.validateKeys(
                    container,
                    required: ["kind", "port"],
                    path: "probes.action"
                )
                command = nil
                path = nil
                port = try container.decode(Int.self, forKey: "port")
            }
        }

        var value: RuntimeProbeAction {
            get throws {
                switch kind {
                case .exec:
                    guard let command else {
                        throw LifecycleRevisionCodecError.missingField(
                            "probes.action.command"
                        )
                    }
                    return .exec(RuntimeProbeExecAction(command: command))
                case .http:
                    guard let port, let path else {
                        throw LifecycleRevisionCodecError.missingField(
                            "probes.action.http"
                        )
                    }
                    return .http(RuntimeProbeHTTPAction(port: port, path: path))
                case .tcp:
                    guard let port else {
                        throw LifecycleRevisionCodecError.missingField(
                            "probes.action.port"
                        )
                    }
                    return .tcp(RuntimeProbeTCPAction(port: port))
                }
            }
        }
    }
}

private struct RevisionCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where Key == RevisionCodingKey {
    func decode<T: Decodable>(
        _ type: T.Type,
        forKey key: String
    ) throws -> T {
        try decode(type, forKey: RevisionCodingKey(stringValue: key)!)
    }

    func decodeIfPresent<T: Decodable>(
        _ type: T.Type,
        forKey key: String
    ) throws -> T? {
        try decodeIfPresent(type, forKey: RevisionCodingKey(stringValue: key)!)
    }
}

public struct LifecycleUpdatePlanner: Sendable {
    public init() {}

    public func plan(
        previous: DesiredRuntimeState,
        desired: DesiredRuntimeState,
        resources: [RuntimeServiceIdentity: LifecycleUpdateResourceIdentity],
        fencingToken: String
    ) throws -> LifecycleUpdatePlan {
        guard previous.projectName == desired.projectName else {
            throw LifecycleUpdatePlanningError.projectMismatch(
                expected: previous.projectName,
                actual: desired.projectName
            )
        }
        guard HostwrightResourceUUID.isValid(fencingToken) else {
            throw LifecycleUpdatePlanningError.invalidResourceIdentity("fencing-token")
        }

        let previousByIdentity = try unique(previous.services)
        let desiredByIdentity = try unique(desired.services)
        guard Set(previousByIdentity.keys) == Set(desiredByIdentity.keys) else {
            let changed = Set(previousByIdentity.keys)
                .symmetricDifference(Set(desiredByIdentity.keys))
                .map(\.displayName)
                .sorted()
                .joined(separator: ",")
            throw LifecycleUpdatePlanningError.replicaSetChanged(changed)
        }

        let changed = try desiredByIdentity.values.filter { desiredService in
            guard let previousService = previousByIdentity[desiredService.identity] else {
                return false
            }
            return try LifecycleRevisionCodec.revisionSHA256(for: previousService) !=
                LifecycleRevisionCodec.revisionSHA256(for: desiredService)
        }
        let changedNames = Set(changed.map(\.logicalServiceName))
        let topology = try validateTopology(desired.services)
        let serviceOrder = try stableServiceOrder(
            topology: topology,
            includedServiceNames: changedNames
        )
        let promotionKeysByService = Dictionary(
            uniqueKeysWithValues: serviceOrder.map { serviceName in
                let replicas = changed.filter { $0.logicalServiceName == serviceName }
                return (
                    serviceName,
                    replicas.sorted(by: serviceOrdering).map {
                        nodeKey(service: $0, phase: "promote")
                    }
                )
            }
        )
        let startKeysByService = Dictionary(
            uniqueKeysWithValues: serviceOrder.map { serviceName in
                let replicas = changed.filter { $0.logicalServiceName == serviceName }
                return (
                    serviceName,
                    replicas.sorted(by: serviceOrdering).map {
                        nodeKey(service: $0, phase: "start")
                    }
                )
            }
        )

        var servicePlans: [LifecycleServiceUpdatePlan] = []
        var allNodes: [LifecyclePlanNode] = []
        for serviceName in serviceOrder {
            let desiredReplicas = changed
                .filter { $0.logicalServiceName == serviceName }
                .sorted(by: serviceOrdering)
            guard let firstDesired = desiredReplicas.first,
                  previousByIdentity[firstDesired.identity] != nil else {
                continue
            }
            try validatePolicyConsistency(desiredReplicas)
            let policy = firstDesired.updatePolicy
            guard policy.progressDeadlineSeconds > 0,
                  policy.maxSurge >= 0,
                  policy.maxUnavailable >= 0,
                  !(policy.strategy == .rolling &&
                    policy.maxSurge == 0 &&
                    policy.maxUnavailable == 0) else {
                throw LifecycleUpdatePlanningError.invalidUpdatePolicy(serviceName)
            }

            let modeAndReason = updateMode(
                previous: desiredReplicas.compactMap { previousByIdentity[$0.identity] },
                desired: desiredReplicas,
                policy: policy
            )
            let dependencyKeys = dependencyNodeKeys(
                for: firstDesired,
                changedServiceNames: changedNames,
                promotionsByService: promotionKeysByService,
                startsByService: startKeysByService
            )
            let dependencyConditions = dependencyPreconditions(for: firstDesired)
            let built = try buildNodes(
                mode: modeAndReason.mode,
                previousByIdentity: previousByIdentity,
                desiredReplicas: desiredReplicas,
                resources: resources,
                fencingToken: fencingToken,
                serviceDependencies: dependencyKeys,
                serviceDependencyPreconditions: dependencyConditions
            )
            let priorDigest = try groupedRevisionSHA256(
                desiredReplicas.compactMap { previousByIdentity[$0.identity] }
            )
            let targetDigest = try groupedRevisionSHA256(desiredReplicas)
            let impact = availabilityImpact(
                mode: modeAndReason.mode,
                policy: policy,
                replicas: desiredReplicas.count,
                reason: modeAndReason.reason
            )
            servicePlans.append(
                LifecycleServiceUpdatePlan(
                    serviceName: serviceName,
                    mode: modeAndReason.mode,
                    modeReason: modeAndReason.reason,
                    previousRevisionSHA256: priorDigest,
                    desiredRevisionSHA256: targetDigest,
                    progressDeadlineSeconds: policy.progressDeadlineSeconds,
                    availabilityImpact: impact,
                    nodes: built
                )
            )
            allNodes.append(contentsOf: built)
        }

        return LifecycleUpdatePlan(
            projectName: desired.projectName,
            servicePlans: servicePlans,
            nodes: try LifecyclePlanCompiler.stableTopologicalOrder(allNodes)
        )
    }

    private func buildNodes(
        mode: LifecycleUpdatePlanMode,
        previousByIdentity: [RuntimeServiceIdentity: DesiredRuntimeService],
        desiredReplicas: [DesiredRuntimeService],
        resources: [RuntimeServiceIdentity: LifecycleUpdateResourceIdentity],
        fencingToken: String,
        serviceDependencies: [String],
        serviceDependencyPreconditions: [LifecyclePlanCondition]
    ) throws -> [LifecyclePlanNode] {
        guard let policy = desiredReplicas.first?.updatePolicy else { return [] }
        let nodeTimeout = min(
            policy.progressDeadlineSeconds,
            RuntimeCommandTimeout.maximumSeconds
        )
        var nodes: [LifecyclePlanNode] = []
        var retireKeys: [String] = []
        var promoteKeys: [String] = []
        var quiesceKeys: [String] = []

        for desired in desiredReplicas {
            guard let previous = previousByIdentity[desired.identity] else {
                continue
            }
            guard let resource = resources[desired.identity] else {
                throw LifecycleUpdatePlanningError.missingResourceIdentity(
                    desired.identity.displayName
                )
            }
            try validate(resource: resource, expectedIdentity: desired.identity)
            let desiredJSON = try LifecycleRevisionCodec.redactedDesiredJSON(for: desired)
            let previousJSON = try LifecycleRevisionCodec.redactedDesiredJSON(for: previous)
            let prepareKey = nodeKey(service: desired, phase: "prepare")
            let preStopKey = nodeKey(service: desired, phase: "prestop")
            let quiesceKey = nodeKey(service: desired, phase: "quiesce")
            let createKey = nodeKey(service: desired, phase: "create")
            let startKey = nodeKey(service: desired, phase: "start")
            let postStartKey = nodeKey(service: desired, phase: "poststart")
            let startupKey = nodeKey(service: desired, phase: "startup")
            let readinessKey = nodeKey(service: desired, phase: "readiness")
            let promoteKey = nodeKey(service: desired, phase: "promote")
            let retireKey = nodeKey(service: desired, phase: "retire")

            let capacityDependencies: [String]
            if mode == .rolling && policy.maxSurge > 0 {
                let index = retireKeys.count
                capacityDependencies = index >= policy.maxSurge
                    ? [retireKeys[index - policy.maxSurge]]
                    : []
            } else {
                capacityDependencies = []
            }
            let prepareDependencies = Set(serviceDependencies)
                .union(capacityDependencies)
                .sorted()
            nodes.append(
                try node(
                    key: prepareKey,
                    action: .validate,
                    service: desired,
                    resourceIdentifier: resource.candidateResourceIdentifier,
                    resourceUUID: resource.candidateResourceUUID,
                    generation: resource.candidateGeneration,
                    fence: fencingToken,
                    dependencies: prepareDependencies,
                    preconditions: serviceDependencyPreconditions + [
                        condition(
                            "revision-current",
                            desired.identity,
                            try LifecycleRevisionCodec.revisionSHA256(for: previous)
                        ),
                        condition(
                            "progress-deadline-seconds",
                            desired.identity,
                            String(policy.progressDeadlineSeconds)
                        )
                    ],
                    postconditions: [
                        condition("update-prepared", desired.identity, "true")
                    ],
                    timeout: nodeTimeout,
                    desiredJSON: desiredJSON
                )
            )

            var createDependencies = [prepareKey]
            let mustQuiesceBeforeCreate = mode == .recreate || policy.maxSurge == 0
            if mustQuiesceBeforeCreate {
                var beforeStop = [prepareKey]
                if let preStop = previous.hooks.preStop {
                    nodes.append(
                        try node(
                            key: preStopKey,
                            action: .runHook,
                            service: previous,
                            resourceIdentifier: resource.currentResourceIdentifier,
                            resourceUUID: resource.currentResourceUUID,
                            generation: resource.currentGeneration,
                            fence: fencingToken,
                            dependencies: beforeStop,
                            postconditions: [
                                condition("hook-completed", previous.identity, "preStop")
                            ],
                            timeout: nodeTimeout,
                            desiredJSON: hookJSON(kind: "preStop", command: preStop)
                        )
                    )
                    beforeStop = [preStopKey]
                }
                if mode == .rolling, policy.maxUnavailable > 0 {
                    let index = quiesceKeys.count
                    if index >= policy.maxUnavailable {
                        beforeStop.append(promoteKeys[index - policy.maxUnavailable])
                    }
                }
                nodes.append(
                    try node(
                        key: quiesceKey,
                        action: .stop,
                        service: previous,
                        resourceIdentifier: resource.currentResourceIdentifier,
                        resourceUUID: resource.currentResourceUUID,
                        generation: resource.currentGeneration,
                        fence: fencingToken,
                        dependencies: beforeStop,
                        postconditions: [
                            condition("lifecycle", previous.identity, "stopped")
                        ],
                        timeout: nodeTimeout,
                        compensation: LifecycleCompensation(action: .start),
                        desiredJSON: previousJSON
                    )
                )
                quiesceKeys.append(quiesceKey)
                createDependencies.append(quiesceKey)
            }
            if mode == .recreate {
                createDependencies.append(contentsOf: quiesceKeys)
            }
            nodes.append(
                try node(
                    key: createKey,
                    action: .create,
                    service: desired,
                    resourceIdentifier: resource.candidateResourceIdentifier,
                    resourceUUID: resource.candidateResourceUUID,
                    generation: resource.candidateGeneration,
                    fence: fencingToken,
                    dependencies: Set(createDependencies).sorted(),
                    preconditions: [
                        condition("resource-absent", desired.identity, "candidate")
                    ],
                    postconditions: [
                        condition("resource-present", desired.identity, "candidate")
                    ],
                    timeout: nodeTimeout,
                    compensation: LifecycleCompensation(action: .delete),
                    desiredJSON: desiredJSON
                )
            )
            nodes.append(
                try node(
                    key: startKey,
                    action: .start,
                    service: desired,
                    resourceIdentifier: resource.candidateResourceIdentifier,
                    resourceUUID: resource.candidateResourceUUID,
                    generation: resource.candidateGeneration,
                    fence: fencingToken,
                    dependencies: [createKey],
                    postconditions: [
                        condition("lifecycle", desired.identity, "running")
                    ],
                    timeout: nodeTimeout,
                    compensation: LifecycleCompensation(action: .stop),
                    desiredJSON: desiredJSON
                )
            )
            var startupDependency = startKey
            if let postStart = desired.hooks.postStart {
                nodes.append(
                    try node(
                        key: postStartKey,
                        action: .runHook,
                        service: desired,
                        resourceIdentifier: resource.candidateResourceIdentifier,
                        resourceUUID: resource.candidateResourceUUID,
                        generation: resource.candidateGeneration,
                        fence: fencingToken,
                        dependencies: [startKey],
                        postconditions: [
                            condition("hook-completed", desired.identity, "postStart")
                        ],
                        timeout: nodeTimeout,
                        desiredJSON: hookJSON(kind: "postStart", command: postStart)
                    )
                )
                startupDependency = postStartKey
            }
            nodes.append(
                try node(
                    key: startupKey,
                    action: .verify,
                    service: desired,
                    resourceIdentifier: resource.candidateResourceIdentifier,
                    resourceUUID: resource.candidateResourceUUID,
                    generation: resource.candidateGeneration,
                    fence: fencingToken,
                    dependencies: [startupDependency],
                    postconditions: [
                        condition("probe-startup", desired.identity, "succeeded")
                    ],
                    timeout: nodeTimeout,
                    desiredJSON: desiredJSON
                )
            )
            nodes.append(
                try node(
                    key: readinessKey,
                    action: .verify,
                    service: desired,
                    resourceIdentifier: resource.candidateResourceIdentifier,
                    resourceUUID: resource.candidateResourceUUID,
                    generation: resource.candidateGeneration,
                    fence: fencingToken,
                    dependencies: [startupKey],
                    postconditions: [
                        condition("probe-readiness", desired.identity, "ready")
                    ],
                    timeout: nodeTimeout,
                    desiredJSON: desiredJSON
                )
            )
            nodes.append(
                try node(
                    key: promoteKey,
                    action: .promote,
                    service: desired,
                    resourceIdentifier: resource.candidateResourceIdentifier,
                    resourceUUID: resource.candidateResourceUUID,
                    generation: resource.candidateGeneration,
                    fence: fencingToken,
                    dependencies: [readinessKey],
                    preconditions: [
                        condition("revision-healthy", desired.identity, "true")
                    ],
                    postconditions: [
                        condition(
                            "revision-current",
                            desired.identity,
                            try LifecycleRevisionCodec.revisionSHA256(for: desired)
                        )
                    ],
                    timeout: nodeTimeout,
                    compensation: LifecycleCompensation(action: .stop),
                    desiredJSON: desiredJSON
                )
            )
            promoteKeys.append(promoteKey)

            var retireDependencies = [promoteKey]
            if !mustQuiesceBeforeCreate {
                if let preStop = previous.hooks.preStop {
                    nodes.append(
                        try node(
                            key: preStopKey,
                            action: .runHook,
                            service: previous,
                            resourceIdentifier: resource.currentResourceIdentifier,
                            resourceUUID: resource.currentResourceUUID,
                            generation: resource.currentGeneration,
                            fence: fencingToken,
                            dependencies: [promoteKey],
                            postconditions: [
                                condition("hook-completed", previous.identity, "preStop")
                            ],
                            timeout: nodeTimeout,
                            desiredJSON: hookJSON(kind: "preStop", command: preStop)
                        )
                    )
                    retireDependencies = [preStopKey]
                }
                nodes.append(
                    try node(
                        key: quiesceKey,
                        action: .stop,
                        service: previous,
                        resourceIdentifier: resource.currentResourceIdentifier,
                        resourceUUID: resource.currentResourceUUID,
                        generation: resource.currentGeneration,
                        fence: fencingToken,
                        dependencies: retireDependencies,
                        postconditions: [
                            condition("lifecycle", previous.identity, "stopped")
                        ],
                        timeout: nodeTimeout,
                        compensation: LifecycleCompensation(action: .start),
                        desiredJSON: previousJSON
                    )
                )
                quiesceKeys.append(quiesceKey)
                retireDependencies = [quiesceKey]
            }
            nodes.append(
                try node(
                    key: retireKey,
                    action: .retire,
                    service: previous,
                    resourceIdentifier: resource.currentResourceIdentifier,
                    resourceUUID: resource.currentResourceUUID,
                    generation: resource.currentGeneration,
                    fence: fencingToken,
                    dependencies: retireDependencies,
                    preconditions: [
                        condition("candidate-promoted", desired.identity, "true"),
                        condition(
                            "old-revision-verified-healthy",
                            previous.identity,
                            try LifecycleRevisionCodec.revisionSHA256(
                                for: previous
                            )
                        )
                    ],
                    postconditions: [
                        condition("old-revision-retained", previous.identity, "false")
                    ],
                    timeout: nodeTimeout,
                    compensation: LifecycleCompensation(action: .create),
                    desiredJSON: previousJSON
                )
            )
            retireKeys.append(retireKey)
        }

        if mode == .recreate {
            let allQuiesced = quiesceKeys
            nodes = try nodes.map { value in
                guard value.action == .create else { return value }
                return try replacingDependencies(
                    on: value,
                    with: Set(value.dependencies).union(allQuiesced).sorted()
                )
            }
        }
        let deadlineCondition = LifecyclePlanCondition(
            kind: "progress-deadline-seconds",
            subject: desiredReplicas[0].logicalServiceName,
            expectedValue: String(policy.progressDeadlineSeconds)
        )
        return try nodes.map { value in
            guard !value.preconditions.contains(where: {
                $0.kind == deadlineCondition.kind
            }) else {
                return value
            }
            return try replacingPreconditions(
                on: value,
                with: value.preconditions + [deadlineCondition]
            )
        }
    }

    private func replacingDependencies(
        on node: LifecyclePlanNode,
        with dependencies: [String]
    ) throws -> LifecyclePlanNode {
        try LifecyclePlanNode(
            key: node.key,
            action: node.action,
            serviceName: node.serviceName,
            resourceIdentifier: node.resourceIdentifier,
            resourceUUID: node.resourceUUID,
            resourceGeneration: node.resourceGeneration,
            fencingToken: node.fencingToken,
            dependencies: dependencies,
            preconditions: node.preconditions,
            postconditions: node.postconditions,
            timeoutSeconds: node.timeoutSeconds,
            compensation: node.compensation,
            desiredSpecificationJSONRedacted: node.desiredSpecificationJSONRedacted
        )
    }

    private func replacingPreconditions(
        on node: LifecyclePlanNode,
        with preconditions: [LifecyclePlanCondition]
    ) throws -> LifecyclePlanNode {
        try LifecyclePlanNode(
            key: node.key,
            action: node.action,
            serviceName: node.serviceName,
            resourceIdentifier: node.resourceIdentifier,
            resourceUUID: node.resourceUUID,
            resourceGeneration: node.resourceGeneration,
            fencingToken: node.fencingToken,
            dependencies: node.dependencies,
            preconditions: preconditions,
            postconditions: node.postconditions,
            timeoutSeconds: node.timeoutSeconds,
            compensation: node.compensation,
            desiredSpecificationJSONRedacted: node.desiredSpecificationJSONRedacted
        )
    }

    private func node(
        key: String,
        action: LifecyclePlanAction,
        service: DesiredRuntimeService,
        resourceIdentifier: String,
        resourceUUID: String,
        generation: Int,
        fence: String,
        dependencies: [String] = [],
        preconditions: [LifecyclePlanCondition] = [],
        postconditions: [LifecyclePlanCondition] = [],
        timeout: Int,
        compensation: LifecycleCompensation? = nil,
        desiredJSON: String
    ) throws -> LifecyclePlanNode {
        try LifecyclePlanNode(
            key: key,
            action: action,
            serviceName: service.logicalServiceName,
            resourceIdentifier: resourceIdentifier,
            resourceUUID: resourceUUID,
            resourceGeneration: generation,
            fencingToken: fence,
            dependencies: dependencies,
            preconditions: preconditions,
            postconditions: postconditions,
            timeoutSeconds: timeout,
            compensation: compensation,
            desiredSpecificationJSONRedacted: desiredJSON
        )
    }

    private func validate(
        resource: LifecycleUpdateResourceIdentity,
        expectedIdentity: RuntimeServiceIdentity
    ) throws {
        guard resource.identity == expectedIdentity,
              !resource.currentResourceIdentifier.isEmpty,
              !resource.candidateResourceIdentifier.isEmpty,
              resource.currentResourceIdentifier != resource.candidateResourceIdentifier,
              HostwrightResourceUUID.isValid(resource.currentResourceUUID),
              HostwrightResourceUUID.isValid(resource.candidateResourceUUID),
              resource.currentResourceUUID != resource.candidateResourceUUID,
              resource.currentGeneration > 0,
              resource.candidateGeneration == resource.currentGeneration + 1 else {
            throw LifecycleUpdatePlanningError.invalidResourceIdentity(
                expectedIdentity.displayName
            )
        }
    }

    private func unique(
        _ services: [DesiredRuntimeService]
    ) throws -> [RuntimeServiceIdentity: DesiredRuntimeService] {
        var result: [RuntimeServiceIdentity: DesiredRuntimeService] = [:]
        for service in services {
            guard result.updateValue(service, forKey: service.identity) == nil else {
                throw LifecycleUpdatePlanningError.duplicateServiceIdentity(
                    service.identity.displayName
                )
            }
        }
        return result
    }

    private func validatePolicyConsistency(
        _ services: [DesiredRuntimeService]
    ) throws {
        guard let first = services.first else { return }
        guard services.dropFirst().allSatisfy({
            $0.updatePolicy == first.updatePolicy
        }) else {
            throw LifecycleUpdatePlanningError.inconsistentUpdatePolicy(
                first.logicalServiceName
            )
        }
    }

    private func updateMode(
        previous: [DesiredRuntimeService],
        desired: [DesiredRuntimeService],
        policy: RuntimeUpdatePolicy
    ) -> (mode: LifecycleUpdatePlanMode, reason: LifecycleUpdateModeReason) {
        if policy.strategy == .recreate {
            return (.recreate, .requestedRecreate)
        }
        if policy.maxSurge > 0, hasExclusiveHostPort(previous: previous, desired: desired) {
            return (.recreate, .exclusiveHostPort)
        }
        return (.rolling, .requestedRolling)
    }

    private func hasExclusiveHostPort(
        previous: [DesiredRuntimeService],
        desired: [DesiredRuntimeService]
    ) -> Bool {
        let previousPorts = Set(previous.flatMap(\.ports).compactMap(\.hostPort))
        let desiredPorts = Set(desired.flatMap(\.ports).compactMap(\.hostPort))
        return !previousPorts.intersection(desiredPorts).isEmpty
    }

    private func availabilityImpact(
        mode: LifecycleUpdatePlanMode,
        policy: RuntimeUpdatePolicy,
        replicas: Int,
        reason: LifecycleUpdateModeReason
    ) -> LifecycleUpdateAvailabilityImpact {
        switch mode {
        case .rolling where policy.maxSurge > 0:
            return LifecycleUpdateAvailabilityImpact(
                desiredReplicas: replicas,
                minimumAvailable: max(0, replicas - policy.maxUnavailable),
                maximumTemporaryCapacity: replicas + min(replicas, policy.maxSurge),
                requiresDowntime: false,
                summary:
                    "Rolling update keeps the old revision until each candidate is ready; " +
                    "temporary capacity is bounded by maxSurge=\(policy.maxSurge)."
            )
        case .rolling:
            return LifecycleUpdateAvailabilityImpact(
                desiredReplicas: replicas,
                minimumAvailable: max(0, replicas - policy.maxUnavailable),
                maximumTemporaryCapacity: replicas,
                requiresDowntime: policy.maxUnavailable >= replicas,
                summary:
                    "Rolling update quiesces at most maxUnavailable=" +
                    "\(policy.maxUnavailable) old replicas while retaining them for rollback."
            )
        case .recreate:
            let suffix = reason == .exclusiveHostPort
                ? " because fixed host ports prevent old and candidate revisions from running together."
                : " because recreate was explicitly requested."
            return LifecycleUpdateAvailabilityImpact(
                desiredReplicas: replicas,
                minimumAvailable: 0,
                maximumTemporaryCapacity: replicas,
                requiresDowntime: true,
                summary: "Recreate update has a declared availability interruption" + suffix
            )
        }
    }

    private func dependencyNodeKeys(
        for service: DesiredRuntimeService,
        changedServiceNames: Set<String>,
        promotionsByService: [String: [String]],
        startsByService: [String: [String]]
    ) -> [String] {
        service.dependencies.sorted {
            ($0.serviceName, $0.condition.rawValue) <
                ($1.serviceName, $1.condition.rawValue)
        }.flatMap { dependency -> [String] in
            guard changedServiceNames.contains(dependency.serviceName) else {
                return []
            }
            switch dependency.condition {
            case .started:
                return startsByService[dependency.serviceName] ?? []
            case .ready, .completed:
                return promotionsByService[dependency.serviceName] ?? []
            }
        }.sorted()
    }

    private func dependencyPreconditions(
        for service: DesiredRuntimeService
    ) -> [LifecyclePlanCondition] {
        service.dependencies.sorted {
            ($0.serviceName, $0.condition.rawValue) <
                ($1.serviceName, $1.condition.rawValue)
        }.map {
            LifecyclePlanCondition(
                kind: "dependency-\($0.condition.rawValue)",
                subject: "\(service.identity.projectName)/\($0.serviceName)",
                expectedValue: "true"
            )
        }
    }

    private func validateTopology(
        _ services: [DesiredRuntimeService]
    ) throws -> [String: Set<String>] {
        let names = Set(services.map(\.logicalServiceName))
        var result: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: names.map { ($0, Set<String>()) }
        )
        for service in services {
            for dependency in service.dependencies where names.contains(dependency.serviceName) {
                result[service.logicalServiceName, default: []].insert(dependency.serviceName)
            }
        }
        return result
    }

    private func stableServiceOrder(
        topology: [String: Set<String>],
        includedServiceNames: Set<String>
    ) throws -> [String] {
        var remaining = Dictionary(
            uniqueKeysWithValues: includedServiceNames.map { name in
                (
                    name,
                    (topology[name] ?? []).intersection(includedServiceNames)
                )
            }
        )
        var result: [String] = []
        var ready = remaining.filter { $0.value.isEmpty }.map(\.key).sorted()
        while let name = ready.first {
            ready.removeFirst()
            result.append(name)
            remaining.removeValue(forKey: name)
            for candidate in remaining.keys.sorted() {
                remaining[candidate]?.remove(name)
                if remaining[candidate]?.isEmpty == true,
                   !ready.contains(candidate) {
                    ready.append(candidate)
                    ready.sort()
                }
            }
        }
        guard remaining.isEmpty else {
            throw LifecycleUpdatePlanningError.dependencyCycle(
                remaining.keys.sorted()
            )
        }
        return result
    }

    private func groupedRevisionSHA256(
        _ services: [DesiredRuntimeService]
    ) throws -> String {
        let material = try services.sorted(by: serviceOrdering).map {
            try LifecycleRevisionCodec.revisionSHA256(for: $0)
        }.joined(separator: "\n")
        return LifecycleCanonicalJSON.sha256(Data(material.utf8))
    }

    private func condition(
        _ kind: String,
        _ identity: RuntimeServiceIdentity,
        _ expected: String
    ) -> LifecyclePlanCondition {
        LifecyclePlanCondition(
            kind: kind,
            subject: identity.displayName,
            expectedValue: expected
        )
    }

    private func hookJSON(kind: String, command: [String]) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: ["hook": kind, "command": command],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func nodeKey(
        service: DesiredRuntimeService,
        phase: String
    ) -> String {
        "update-\(stableComponent(service.logicalServiceName))-" +
            "r\(service.replicaIndex)-\(phase)"
    }

    private func stableComponent(_ value: String) -> String {
        let lowered = value.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }
        let trimmed = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return String((trimmed.isEmpty ? "service" : trimmed).prefix(64))
    }

    private func serviceOrdering(
        _ lhs: DesiredRuntimeService,
        _ rhs: DesiredRuntimeService
    ) -> Bool {
        (
            lhs.logicalServiceName,
            lhs.replicaIndex,
            lhs.identity.displayName
        ) < (
            rhs.logicalServiceName,
            rhs.replicaIndex,
            rhs.identity.displayName
        )
    }
}
