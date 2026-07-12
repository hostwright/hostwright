import Foundation

public enum AppleContainerObservationParser {
    public static let supportedSchema = "hostwright.apple-container.observation.v1"

    public static func parse(
        _ output: String,
        desiredState: DesiredRuntimeState,
        metadata: RuntimeAdapterMetadata,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> ObservedRuntimeState {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RuntimeAdapterError.outputParseFailed("Apple container observation output was empty.")
        }

        do {
            let data = Data(trimmed.utf8)
            let json = try JSONSerialization.jsonObject(with: data)

            if let realList = json as? [Any] {
                return try parseRealList(
                    realList,
                    desiredState: desiredState,
                    metadata: metadata,
                    redactionPolicy: redactionPolicy,
                    rawOutput: trimmed
                )
            }

            try validateAllowedKeys(in: json)
            let fixture = try JSONDecoder().decode(ObservationFixture.self, from: data)

            guard fixture.schema == supportedSchema else {
                throw RuntimeAdapterError.outputParseFailed("Unsupported Apple container observation schema in output: \(redactionPolicy.redact(trimmed))")
            }

            guard fixture.project == desiredState.projectName else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Observed project '\(redactionPolicy.redact(fixture.project))' did not match desired project '\(redactionPolicy.redact(desiredState.projectName))'."
                )
            }

            return ObservedRuntimeState(
                projectName: desiredState.projectName,
                services: try fixture.services.map { service in
                    try service.observedRuntimeService(projectName: desiredState.projectName)
                },
                adapterMetadata: metadata
            )
        } catch let error as RuntimeAdapterError {
            throw error.redacted(using: redactionPolicy)
        } catch {
            throw RuntimeAdapterError.outputParseFailed(
                "Unsupported Apple container observation output: \(redactionPolicy.redact(trimmed))"
            )
        }
    }

    private static func validateAllowedKeys(in json: Any) throws {
        guard let object = json as? [String: Any] else {
            throw RuntimeAdapterError.outputParseFailed("Apple container observation output must be a JSON object.")
        }

        try rejectUnknownKeys(Set(object.keys), allowed: ["schema", "project", "runtimeVersion", "services"], context: "observation")

        guard let services = object["services"] as? [[String: Any]] else {
            throw RuntimeAdapterError.outputParseFailed("Apple container observation output must include a services array.")
        }

        for service in services {
            try rejectUnknownKeys(
                Set(service.keys),
                allowed: ["name", "instance", "resourceIdentifier", "image", "lifecycle", "health", "observedAt", "ports", "networks", "mounts"],
                context: "service"
            )

            for port in service["ports"] as? [[String: Any]] ?? [] {
                try rejectUnknownKeys(Set(port.keys), allowed: ["host", "container", "protocol", "bind"], context: "port")
            }

            for network in service["networks"] as? [[String: Any]] ?? [] {
                try rejectUnknownKeys(
                    Set(network.keys),
                    allowed: ["name", "kind", "address", "gateway", "interface", "hostname", "ipv4Address", "ipv4Gateway", "ipv6Address", "macAddress", "mtu"],
                    context: "network"
                )
            }

            for mount in service["mounts"] as? [[String: Any]] ?? [] {
                try rejectUnknownKeys(Set(mount.keys), allowed: ["source", "target", "access"], context: "mount")
            }
        }
    }

    private static func rejectUnknownKeys(_ keys: Set<String>, allowed: Set<String>, context: String) throws {
        let unknown = keys.subtracting(allowed)
        guard unknown.isEmpty else {
            throw RuntimeAdapterError.outputParseFailed("Unsupported keys in \(context): \(unknown.sorted().joined(separator: ", ")).")
        }
    }

    private static func parseRealList(
        _ list: [Any],
        desiredState: DesiredRuntimeState,
        metadata: RuntimeAdapterMetadata,
        redactionPolicy: RuntimeRedactionPolicy,
        rawOutput: String
    ) throws -> ObservedRuntimeState {
        let desiredByContainerID = Dictionary(
            uniqueKeysWithValues: desiredState.services.map {
                (AppleContainerCommand.containerName(for: $0.identity), $0)
            }
        )
        let ownedHintsByContainerID = try uniqueOwnedHints(desiredState.ownedResourceHints)
        var services: [ObservedRuntimeService] = []

        for item in list {
            guard let object = item as? [String: Any],
                  let id = object["id"] as? String,
                  let configuration = object["configuration"] as? [String: Any],
                  let status = object["status"] as? [String: Any] else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Unsupported real Apple container list item shape: \(redactionPolicy.redact(rawOutput))"
                )
            }

            if isAppleBuilderContainer(id: id, configuration: configuration) {
                continue
            }

            guard let identity = try observedIdentity(
                containerID: id,
                configuration: configuration,
                desiredState: desiredState,
                desiredByContainerID: desiredByContainerID,
                ownedHintsByContainerID: ownedHintsByContainerID,
                redactionPolicy: redactionPolicy
            ) else {
                continue
            }

            guard let rawState = status["state"] as? String,
                  let lifecycleState = RuntimeLifecycleState(rawValue: rawState) else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Unsupported Apple container lifecycle state for '\(redactionPolicy.redact(id))'."
                )
            }

            let image = (configuration["image"] as? [String: Any])?["reference"] as? String
            let observedAt = status["startedDate"] as? String ?? configuration["creationDate"] as? String
            let ports = try parsePublishedPorts(configuration["publishedPorts"] as? [[String: Any]] ?? [])
            let networks = try parseRealNetworks(status["networks"] as? [Any] ?? [])

            services.append(
                ObservedRuntimeService(
                    identity: identity,
                    resourceIdentifier: id,
                    image: image,
                    lifecycleState: lifecycleState,
                    healthState: .unknown,
                    ports: ports,
                    networks: networks,
                    mounts: [],
                    observedAt: observedAt
                )
            )
        }

        return ObservedRuntimeState(
            projectName: desiredState.projectName,
            services: services.sorted { $0.identity.displayName < $1.identity.displayName },
            adapterMetadata: metadata
        )
    }

    private static func isAppleBuilderContainer(id: String, configuration: [String: Any]) -> Bool {
        if id == "buildkit" {
            return true
        }
        let labels = configuration["labels"] as? [String: String] ?? [:]
        return labels["com.apple.container.plugin"] == "builder" ||
            labels["com.apple.container.resource.role"] == "builder"
    }

    private static func uniqueOwnedHints(_ hints: [RuntimeOwnedResourceHint]) throws -> [String: RuntimeOwnedResourceHint] {
        var result: [String: RuntimeOwnedResourceHint] = [:]
        for hint in hints {
            guard result[hint.resourceIdentifier] == nil else {
                throw RuntimeAdapterError.outputParseFailed(
                    "State supplied duplicate ownership hints for exact runtime identifier '\(hint.resourceIdentifier)'."
                )
            }
            result[hint.resourceIdentifier] = hint
        }
        return result
    }

    private static func observedIdentity(
        containerID: String,
        configuration: [String: Any],
        desiredState: DesiredRuntimeState,
        desiredByContainerID: [String: DesiredRuntimeService],
        ownedHintsByContainerID: [String: RuntimeOwnedResourceHint],
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> RuntimeServiceIdentity? {
        let labels = stringLabels(configuration["labels"])
        if RuntimeManagedResourceIdentity.isManaged(labels) {
            if let labeledProject = labels[RuntimeManagedResourceIdentity.projectLabel],
               labeledProject != desiredState.projectName {
                if desiredByContainerID[containerID] != nil || ownedHintsByContainerID[containerID] != nil {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Hostwright ownership labels for exact desired identifier '\(redactionPolicy.redact(containerID))' claim another project."
                    )
                }
                return nil
            }

            guard let identity = RuntimeManagedResourceIdentity.identity(from: labels),
                  identity.projectName == desiredState.projectName,
                  RuntimeManagedResourceIdentity.labelsMatch(
                      labels,
                      identity: identity,
                      resourceIdentifier: containerID
                  ) else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Hostwright ownership labels for '\(redactionPolicy.redact(containerID))' are incomplete or do not match its exact identifier."
                )
            }
            return identity
        }

        if let hint = ownedHintsByContainerID[containerID] {
            if hint.identity.projectName == desiredState.projectName,
               hint.identityVersion == 1,
               containerID == RuntimeManagedResourceIdentity.legacyResourceIdentifier(for: hint.identity) {
                return hint.identity
            }
            throw RuntimeAdapterError.outputParseFailed(
                "State-owned Hostwright container '\(redactionPolicy.redact(containerID))' is missing compatible exact ownership labels."
            )
        }

        if desiredByContainerID[containerID] != nil {
            throw RuntimeAdapterError.outputParseFailed(
                "Versioned Hostwright container '\(redactionPolicy.redact(containerID))' is missing exact ownership labels."
            )
        }

        return nil
    }

    private static func stringLabels(_ rawValue: Any?) -> [String: String] {
        guard let rawLabels = rawValue as? [String: Any] else {
            return rawValue as? [String: String] ?? [:]
        }
        return rawLabels.reduce(into: [:]) { result, element in
            if let value = element.value as? String {
                result[element.key] = value
            }
        }
    }

    private static func parsePublishedPorts(_ ports: [[String: Any]]) throws -> [RuntimePortMapping] {
        try ports.map { port in
            let hostPort = port["hostPort"] as? Int ?? port["host"] as? Int
            guard let containerPort = port["containerPort"] as? Int ?? port["container"] as? Int else {
                throw RuntimeAdapterError.outputParseFailed("Unsupported Apple container published port shape.")
            }
            let rawProtocol = (port["protocol"] as? String ?? port["proto"] as? String ?? "tcp").lowercased()
            guard let protocolName = RuntimePortProtocol(rawValue: rawProtocol) else {
                throw RuntimeAdapterError.outputParseFailed("Unsupported Apple container published port protocol '\(rawProtocol)'.")
            }
            return RuntimePortMapping(
                hostPort: hostPort,
                containerPort: containerPort,
                protocolName: protocolName,
                bindAddress: port["hostAddress"] as? String ?? port["bind"] as? String
            )
        }
    }

    private static func parseRealNetworks(_ networks: [Any]) throws -> [RuntimeNetworkAttachment] {
        try networks.map { rawNetwork in
            guard let network = rawNetwork as? [String: Any] else {
                throw RuntimeAdapterError.outputParseFailed("Unsupported Apple container network entry shape.")
            }
            let allowed = Set(["hostname", "ipv4Address", "ipv4Gateway", "ipv6Address", "macAddress", "mtu", "network"])
            let unknown = Set(network.keys).subtracting(allowed)
            guard unknown.isEmpty, let name = network["network"] as? String, !name.isEmpty else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Unsupported Apple container network keys: \(unknown.sorted().joined(separator: ", "))."
                )
            }

            let ipv4Address = network["ipv4Address"] as? String
            let ipv4Gateway = network["ipv4Gateway"] as? String
            return RuntimeNetworkAttachment(
                name: name,
                address: ipv4Address,
                gateway: ipv4Gateway,
                hostname: network["hostname"] as? String,
                ipv4Address: ipv4Address,
                ipv4Gateway: ipv4Gateway,
                ipv6Address: network["ipv6Address"] as? String,
                macAddress: network["macAddress"] as? String,
                mtu: network["mtu"] as? Int
            )
        }
    }
}

private struct ObservationFixture: Decodable {
    let schema: String
    let project: String
    let runtimeVersion: String?
    let services: [ServiceFixture]
}

private struct ServiceFixture: Decodable {
    let name: String
    let instance: String?
    let resourceIdentifier: String?
    let image: String?
    let lifecycle: String
    let health: String?
    let observedAt: String?
    let ports: [PortFixture]?
    let networks: [NetworkFixture]?
    let mounts: [MountFixture]?

    func observedRuntimeService(projectName: String) throws -> ObservedRuntimeService {
        guard let lifecycleState = RuntimeLifecycleState(rawValue: lifecycle) else {
            throw RuntimeAdapterError.outputParseFailed("Unsupported lifecycle state '\(lifecycle)'.")
        }

        let healthState: RuntimeHealthState
        if let health {
            guard let parsed = RuntimeHealthState(rawValue: health) else {
                throw RuntimeAdapterError.outputParseFailed("Unsupported health state '\(health)'.")
            }
            healthState = parsed
        } else {
            healthState = .unknown
        }

        let identity = RuntimeServiceIdentity(projectName: projectName, serviceName: name, instanceName: instance)
        return ObservedRuntimeService(
            identity: identity,
            resourceIdentifier: resourceIdentifier ?? identity.managedResourceIdentifier,
            image: image,
            lifecycleState: lifecycleState,
            healthState: healthState,
            ports: try (ports ?? []).map { try $0.runtimePortMapping() },
            networks: try (networks ?? []).map { try $0.runtimeNetworkAttachment() },
            mounts: try (mounts ?? []).map { try $0.runtimeMountReference() },
            observedAt: observedAt
        )
    }
}

private struct PortFixture: Decodable {
    let host: Int?
    let container: Int
    let `protocol`: String?
    let bind: String?

    func runtimePortMapping() throws -> RuntimePortMapping {
        let protocolName: RuntimePortProtocol
        if let `protocol` {
            guard let parsed = RuntimePortProtocol(rawValue: `protocol`) else {
                throw RuntimeAdapterError.outputParseFailed("Unsupported port protocol '\(`protocol`)'.")
            }
            protocolName = parsed
        } else {
            protocolName = .tcp
        }

        return RuntimePortMapping(
            hostPort: host,
            containerPort: container,
            protocolName: protocolName,
            bindAddress: bind
        )
    }
}

private struct NetworkFixture: Decodable {
    let name: String
    let kind: String?
    let address: String?
    let gateway: String?
    let `interface`: String?
    let hostname: String?
    let ipv4Address: String?
    let ipv4Gateway: String?
    let ipv6Address: String?
    let macAddress: String?
    let mtu: Int?

    func runtimeNetworkAttachment() throws -> RuntimeNetworkAttachment {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeAdapterError.outputParseFailed("Network attachment name must not be empty.")
        }

        return RuntimeNetworkAttachment(
            name: name,
            kind: kind,
            address: address,
            gateway: gateway,
            interfaceName: `interface`,
            hostname: hostname,
            ipv4Address: ipv4Address,
            ipv4Gateway: ipv4Gateway,
            ipv6Address: ipv6Address,
            macAddress: macAddress,
            mtu: mtu
        )
    }
}

private struct MountFixture: Decodable {
    let source: String
    let target: String
    let access: String?

    func runtimeMountReference() throws -> RuntimeMountReference {
        let mountAccess: RuntimeMountAccess
        if let access {
            guard let parsed = RuntimeMountAccess(rawValue: access) else {
                throw RuntimeAdapterError.outputParseFailed("Unsupported mount access '\(access)'.")
            }
            mountAccess = parsed
        } else {
            mountAccess = .unknown
        }

        return RuntimeMountReference(source: source, target: target, access: mountAccess)
    }
}
