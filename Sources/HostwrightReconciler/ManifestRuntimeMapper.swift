import Foundation
import HostwrightManifest
import HostwrightNetworking
import HostwrightRuntime
import HostwrightSecrets

public struct ManifestRuntimeMappingResult: Equatable, Sendable {
    public let desiredState: DesiredRuntimeState
    public let issues: [PlanIssue]

    public init(desiredState: DesiredRuntimeState, issues: [PlanIssue] = []) {
        self.desiredState = desiredState
        self.issues = issues.sorted { $0.orderingKey < $1.orderingKey }
    }
}

public enum ManifestRuntimeMapper {
    public static func map(
        _ manifest: HostwrightManifest,
        policy: PlanningPolicy = .default,
        bindMountBaseDirectory: String? = nil
    ) -> ManifestRuntimeMappingResult {
        let projectName = manifest.project ?? ""
        var issues: [PlanIssue] = []

        let services = manifest.services
            .sorted { $0.name < $1.name }
            .flatMap { service in
                (0..<service.replicas).map { replicaIndex in
                    map(
                        service,
                        replicaIndex: replicaIndex,
                        projectName: projectName,
                        policy: policy,
                        bindMountBaseDirectory: bindMountBaseDirectory,
                        issues: &issues
                    )
                }
            }

        return ManifestRuntimeMappingResult(
            desiredState: DesiredRuntimeState(projectName: projectName, services: services),
            issues: issues
        )
    }

    private static func map(
        _ service: HostwrightService,
        replicaIndex: Int,
        projectName: String,
        policy: PlanningPolicy,
        bindMountBaseDirectory: String?,
        issues: inout [PlanIssue]
    ) -> DesiredRuntimeService {
        let identity = RuntimeServiceIdentity(
            projectName: projectName,
            serviceName: service.name,
            instanceName: replicaIndex == 0 ? nil : "replica-\(replicaIndex)"
        )
        let ports = service.ports.compactMap { parsePort($0, identity: identity, issues: &issues) }
        let mounts = service.volumes.compactMap {
            parseMount(
                $0,
                identity: identity,
                bindMountBaseDirectory: bindMountBaseDirectory,
                issues: &issues
            )
        }
        let literalEnvironment = service.env
            .sorted { $0.key < $1.key }
            .map { key, value in
                RuntimeEnvironmentValue(
                    name: key,
                    value: value,
                    isSensitive: policy.redactionPolicy.isSensitiveKey(key)
                )
            }
        let secretEnvironment = service.secretEnv
            .sorted { $0.key < $1.key }
            .map { key, reference in
                RuntimeEnvironmentValue(
                    name: key,
                    value: reference.redactedDescription,
                    isSensitive: true,
                    secretReference: reference
                )
            }

        let duplicateEnvironmentKeys = Set(service.env.keys).intersection(Set(service.secretEnv.keys)).sorted()
        for key in duplicateEnvironmentKeys {
            issues.append(
                PlanIssue(
                    kind: .unsupportedFeature,
                    severity: .blocker,
                    identity: identity,
                    message: "Environment key \(key) appears in both env and secretEnv.",
                    stableDetailKey: key
                )
            )
        }

        return DesiredRuntimeService(
            identity: identity,
            logicalServiceName: service.name,
            replicaIndex: replicaIndex,
            image: service.image ?? "",
            platformOperatingSystem: service.platform.os.rawValue,
            platformArchitecture: service.platform.architecture.rawValue,
            cpuCount: service.resources?.cpus,
            memoryBytes: service.resources?.memory.flatMap(parseSizeBytes),
            userID: service.user,
            groupID: service.group,
            workingDirectory: service.workdir,
            entrypoint: service.entrypoint,
            command: service.command,
            initProcess: service.initProcess,
            dependencies: service.dependsOn
                .sorted { $0.key < $1.key }
                .map {
                    RuntimeServiceDependency(
                        serviceName: $0.key,
                        condition: mapDependencyCondition($0.value)
                    )
                },
            environment: (literalEnvironment + secretEnvironment).sorted { $0.name < $1.name },
            labels: service.labels,
            ports: ports,
            mounts: mounts,
            healthCheck: mapHealthCheck(service),
            probes: RuntimeProbeManifestMapper.map(service.probes),
            restartPolicy: mapRestartPolicy(service.restart?.policy),
            updatePolicy: RuntimeUpdatePolicy(
                strategy: service.update.strategy == .rolling ? .rolling : .recreate,
                maxSurge: service.update.maxSurge,
                maxUnavailable: service.update.maxUnavailable,
                progressDeadlineSeconds: service.update.progressDeadline
            ),
            hooks: RuntimeLifecycleHooks(
                postStart: service.hooks.postStart,
                preStop: service.hooks.preStop
            ),
            rosetta: service.rosetta,
            virtualization: service.virtualization,
            readOnlyRootFilesystem: service.readOnlyRootFilesystem,
            sharedMemoryBytes: service.shmSize.flatMap(parseSizeBytes)
        )
    }

    private static func mapHealthCheck(_ service: HostwrightService) -> RuntimeHealthCheckSpec? {
        if let liveness = service.probes.liveness,
           case .exec(let command) = liveness.action,
           !command.isEmpty {
            return RuntimeHealthCheckSpec(
                command: command,
                intervalSeconds: liveness.interval,
                timeoutSeconds: liveness.timeout
            )
        }
        guard let health = service.health, !health.command.isEmpty else {
            return nil
        }

        return RuntimeHealthCheckSpec(
            command: health.command,
            intervalSeconds: parseSeconds(health.interval) ?? RuntimeHealthCheckSpec.defaultIntervalSeconds
        )
    }

    private static func mapDependencyCondition(
        _ condition: HostwrightDependencyCondition
    ) -> RuntimeDependencyCondition {
        switch condition {
        case .started:
            .started
        case .ready:
            .ready
        case .completed:
            .completed
        }
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

        return RuntimePortMapping(
            hostPort: hostPort,
            containerPort: containerPort,
            bindAddress: NetworkBindAddressPolicy.localhostBindAddress
        )
    }

    private static func parseMount(
        _ value: String,
        identity: RuntimeServiceIdentity,
        bindMountBaseDirectory: String?,
        issues: inout [PlanIssue]
    ) -> RuntimeMountReference? {
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
            access = .readWrite
        }

        let source = String(parts[0])
        if !source.hasPrefix("/") && !source.hasPrefix(".") {
            issues.append(
                PlanIssue(
                    kind: .unsupportedFeature,
                    severity: .blocker,
                    identity: identity,
                    message: "Named volume '\(source)' requires the Phase 06 storage provider and is unavailable in Phase 04.",
                    stableDetailKey: value
                )
            )
        }
        let resolvedSource: String
        if let bindMountBaseDirectory,
           !source.hasPrefix("/") {
            resolvedSource = URL(
                fileURLWithPath: source,
                relativeTo: URL(fileURLWithPath: bindMountBaseDirectory, isDirectory: true)
            ).standardizedFileURL.path
        } else {
            resolvedSource = source
        }
        return RuntimeMountReference(
            source: resolvedSource,
            target: String(parts[1]),
            access: access
        )
    }

    private static func parseSeconds(_ value: String?) -> Int? {
        guard let value, value.hasSuffix("s") else {
            return nil
        }
        return Int(value.dropLast())
    }

    private static func parseSizeBytes(_ value: String) -> UInt64? {
        let suffixes: [(String, UInt64)] = [
            ("TiB", 1_099_511_627_776),
            ("GiB", 1_073_741_824),
            ("MiB", 1_048_576),
            ("KiB", 1_024),
            ("B", 1)
        ]
        guard let (suffix, multiplier) = suffixes.first(where: { value.hasSuffix($0.0) }),
              let count = UInt64(value.dropLast(suffix.count)) else {
            return nil
        }
        let (bytes, overflow) = count.multipliedReportingOverflow(by: multiplier)
        return overflow ? nil : bytes
    }
}
