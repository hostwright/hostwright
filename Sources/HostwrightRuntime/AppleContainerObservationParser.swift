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
                allowed: ["name", "instance", "image", "lifecycle", "health", "observedAt", "ports", "mounts"],
                context: "service"
            )

            for port in service["ports"] as? [[String: Any]] ?? [] {
                try rejectUnknownKeys(Set(port.keys), allowed: ["host", "container", "protocol", "bind"], context: "port")
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
    let image: String?
    let lifecycle: String
    let health: String?
    let observedAt: String?
    let ports: [PortFixture]?
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

        return ObservedRuntimeService(
            identity: RuntimeServiceIdentity(projectName: projectName, serviceName: name, instanceName: instance),
            image: image,
            lifecycleState: lifecycleState,
            healthState: healthState,
            ports: try (ports ?? []).map { try $0.runtimePortMapping() },
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

