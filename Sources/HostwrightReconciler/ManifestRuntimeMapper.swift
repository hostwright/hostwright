import HostwrightManifest
import HostwrightRuntime

public struct ManifestRuntimeMappingResult: Equatable, Sendable {
    public let desiredState: DesiredRuntimeState
    public let issues: [PlanIssue]

    public init(desiredState: DesiredRuntimeState, issues: [PlanIssue] = []) {
        self.desiredState = desiredState
        self.issues = issues.sorted { $0.orderingKey < $1.orderingKey }
    }
}

public enum ManifestRuntimeMapper {
    public static func map(_ manifest: HostwrightManifest, policy: PlanningPolicy = .default) -> ManifestRuntimeMappingResult {
        let projectName = manifest.project ?? ""
        var issues: [PlanIssue] = []

        let services = manifest.services.map { service in
            map(service, projectName: projectName, policy: policy, issues: &issues)
        }

        return ManifestRuntimeMappingResult(
            desiredState: DesiredRuntimeState(projectName: projectName, services: services),
            issues: issues
        )
    }

    private static func map(
        _ service: HostwrightService,
        projectName: String,
        policy: PlanningPolicy,
        issues: inout [PlanIssue]
    ) -> DesiredRuntimeService {
        let identity = RuntimeServiceIdentity(projectName: projectName, serviceName: service.name)
        let ports = service.ports.compactMap { parsePort($0, identity: identity, issues: &issues) }
        let mounts = service.volumes.compactMap { parseMount($0, identity: identity, issues: &issues) }
        let environment = service.env
            .sorted { $0.key < $1.key }
            .map { key, value in
                RuntimeEnvironmentValue(
                    name: key,
                    value: policy.redactionPolicy.redact(value),
                    isSensitive: policy.redactionPolicy.isSensitiveKey(key)
                )
            }

        return DesiredRuntimeService(
            identity: identity,
            image: service.image ?? "",
            command: service.command,
            environment: environment,
            ports: ports,
            mounts: mounts,
            restartPolicy: mapRestartPolicy(service.restart?.policy)
        )
    }

    private static func mapRestartPolicy(_ value: String?) -> RuntimeRestartPolicy {
        switch value {
        case "on-failure":
            return .onFailure
        case "unless-stopped":
            return .unlessStopped
        default:
            return .no
        }
    }

    private static func parsePort(_ value: String, identity: RuntimeServiceIdentity, issues: inout [PlanIssue]) -> RuntimePortMapping? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hostPort = Int(parts[0]),
              let containerPort = Int(parts[1])
        else {
            issues.append(
                PlanIssue(
                    kind: .unsupportedFeature,
                    severity: .blocker,
                    identity: identity,
                    message: "Port '\(value)' cannot be mapped to a supported runtime port.",
                    stableDetailKey: value
                )
            )
            return nil
        }

        return RuntimePortMapping(hostPort: hostPort, containerPort: containerPort)
    }

    private static func parseMount(_ value: String, identity: RuntimeServiceIdentity, issues: inout [PlanIssue]) -> RuntimeMountReference? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else {
            issues.append(
                PlanIssue(
                    kind: .ambiguousVolumeReference,
                    severity: .blocker,
                    identity: identity,
                    message: "Volume '\(value)' cannot be mapped to a supported runtime mount.",
                    stableDetailKey: value
                )
            )
            return nil
        }

        let access: RuntimeMountAccess
        if parts.count == 3 {
            switch parts[2] {
            case "ro":
                access = .readOnly
            case "rw":
                access = .readWrite
            default:
                access = .unknown
            }
        } else {
            access = .unknown
        }

        return RuntimeMountReference(source: String(parts[0]), target: String(parts[1]), access: access)
    }
}
