import Foundation
import HostwrightCore
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
        projectResourceUUID: String? = nil,
        bindMountBaseDirectory: String? = nil,
        namedVolumeSources: [String: String] = [:]
    ) -> ManifestRuntimeMappingResult {
        let projectName = manifest.project ?? ""
        let resolvedProjectUUID = projectResourceUUID ??
            HostwrightResourceUUID.legacy(
                kind: "project",
                identifier: "project-\(projectName)"
            )
        var issues: [PlanIssue] = []

        let networks = manifest.networks
            .sorted { $0.key < $1.key }
            .compactMap { name, definition in
                map(
                    definition,
                    name: name,
                    projectResourceUUID: resolvedProjectUUID,
                    issues: &issues
                )
            }
        let services = manifest.services
            .sorted { $0.name < $1.name }
            .flatMap { service in
                (0..<service.replicas).map { replicaIndex in
                    map(
                        service,
                        replicaIndex: replicaIndex,
                        projectName: projectName,
                        projectResourceUUID: resolvedProjectUUID,
                        networkDefinitions: manifest.networks,
                        policy: policy,
                        bindMountBaseDirectory: bindMountBaseDirectory,
                        namedVolumeSources: namedVolumeSources,
                        issues: &issues
                    )
                }
            }

        return ManifestRuntimeMappingResult(
            desiredState: DesiredRuntimeState(
                projectName: projectName,
                networks: networks,
                services: services
            ),
            issues: issues
        )
    }

    private static func map(
        _ service: HostwrightService,
        replicaIndex: Int,
        projectName: String,
        projectResourceUUID: String,
        networkDefinitions: [String: HostwrightNetworkDefinition],
        policy: PlanningPolicy,
        bindMountBaseDirectory: String?,
        namedVolumeSources: [String: String],
        issues: inout [PlanIssue]
    ) -> DesiredRuntimeService {
        let identity = RuntimeServiceIdentity(
            projectName: projectName,
            serviceName: service.name,
            instanceName: replicaIndex == 0 ? nil : "replica-\(replicaIndex)"
        )
        let ports = service.ports.compactMap { parsePort($0, identity: identity, issues: &issues) }
        let networks = service.networks.compactMap { attachment in
            map(
                attachment,
                projectResourceUUID: projectResourceUUID,
                networkDefinitions: networkDefinitions,
                identity: identity,
                issues: &issues
            )
        }
        let mounts = service.mounts.compactMap {
            parseMount(
                $0,
                identity: identity,
                bindMountBaseDirectory: bindMountBaseDirectory,
                namedVolumeSources: namedVolumeSources,
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
            networks: networks,
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

    private static func map(
        _ definition: HostwrightNetworkDefinition,
        name: String,
        projectResourceUUID: String,
        issues: inout [PlanIssue]
    ) -> DesiredRuntimeNetwork? {
        let resourceUUID = HostwrightNetworkIdentity.resourceUUID(
            projectUUID: projectResourceUUID,
            networkName: name
        )
        do {
            return DesiredRuntimeNetwork(
                identity: try RuntimeNetworkIdentity(
                    logicalName: name,
                    resourceUUID: resourceUUID,
                    projectUUID: projectResourceUUID
                ),
                mode: definition.driver == .nat ? .nat : .hostOnly,
                ipv4: map(definition.ipv4),
                ipv6: map(definition.ipv6)
            )
        } catch {
            issues.append(
                PlanIssue(
                    kind: .invalidDesiredIdentity,
                    severity: .blocker,
                    identity: nil,
                    message: "Network '\(name)' could not be mapped to an exact project-scoped runtime identity.",
                    stableDetailKey: name
                )
            )
            return nil
        }
    }

    private static func map(
        _ attachment: HostwrightServiceNetworkAttachment,
        projectResourceUUID: String,
        networkDefinitions: [String: HostwrightNetworkDefinition],
        identity: RuntimeServiceIdentity,
        issues: inout [PlanIssue]
    ) -> RuntimeDesiredNetworkAttachment? {
        guard networkDefinitions[attachment.network] != nil else {
            issues.append(
                PlanIssue(
                    kind: .unsupportedFeature,
                    severity: .blocker,
                    identity: identity,
                    message: "Network attachment '\(attachment.network)' does not reference a declared project network.",
                    stableDetailKey: attachment.network
                )
            )
            return nil
        }
        let resourceUUID = HostwrightNetworkIdentity.resourceUUID(
            projectUUID: projectResourceUUID,
            networkName: attachment.network
        )
        do {
            let networkIdentity = try RuntimeNetworkIdentity(
                logicalName: attachment.network,
                resourceUUID: resourceUUID,
                projectUUID: projectResourceUUID
            )
            return try RuntimeDesiredNetworkAttachment(
                network: networkIdentity,
                aliases: attachment.aliases
            )
        } catch {
            issues.append(
                PlanIssue(
                    kind: .invalidDesiredIdentity,
                    severity: .blocker,
                    identity: identity,
                    message: "Network attachment '\(attachment.network)' could not be mapped to an exact runtime identity.",
                    stableDetailKey: attachment.network
                )
            )
            return nil
        }
    }

    private static func map(
        _ request: HostwrightNetworkAddressRequest
    ) -> RuntimeNetworkAddressRequest {
        switch request {
        case .auto:
            return .automatic
        case .disabled:
            return .disabled
        case .cidr(let value):
            return .cidr(value)
        }
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
        _ mount: HostwrightMountSpec,
        identity: RuntimeServiceIdentity,
        bindMountBaseDirectory: String?,
        namedVolumeSources: [String: String],
        issues: inout [PlanIssue]
    ) -> RuntimeMountReference? {
        let source = mount.source
        switch mount.kind {
        case .bind:
            guard let source else {
                issues.append(
                    PlanIssue(
                        kind: .ambiguousVolumeReference,
                        severity: .blocker,
                        identity: identity,
                        message: "Bind mount requires an exact source path.",
                        stableDetailKey: mount.target
                    )
                )
                return nil
            }
            if HostwrightPathPolicy.isHostRootMountSource(source) {
                issues.append(
                    PlanIssue(
                        kind: .unsafeVolumePath,
                        severity: .blocker,
                        identity: identity,
                        message: "Bind mount source '\(source)' must not mount the host root.",
                        stableDetailKey: source
                    )
                )
                return nil
            }
            if HostwrightPathPolicy.containsParentDirectoryTraversal(source) {
                issues.append(
                    PlanIssue(
                        kind: .unsafeVolumePath,
                        severity: .blocker,
                        identity: identity,
                        message: "Bind mount source '\(source)' must not contain parent-directory traversal.",
                        stableDetailKey: source
                    )
                )
                return nil
            }
            let resolvedSource: String
            if let bindMountBaseDirectory, !source.hasPrefix("/") {
                resolvedSource = URL(
                    fileURLWithPath: source,
                    relativeTo: URL(fileURLWithPath: bindMountBaseDirectory, isDirectory: true)
                ).standardizedFileURL.path
            } else {
                resolvedSource = source
            }
            return RuntimeMountReference(
                source: resolvedSource,
                target: mount.target,
                access: mount.readOnly ? .readOnly : .readWrite
            )
        case .volume:
            guard let name = mount.source,
                  let resolvedSource = namedVolumeSources[name] else {
                issues.append(
                    PlanIssue(
                        kind: .unsupportedFeature,
                        severity: .blocker,
                        identity: identity,
                        message: "Named volume '\(mount.source ?? "")' is not resolved by the selected storage provider.",
                        stableDetailKey: mount.source ?? mount.target
                    )
                )
                return nil
            }
            return RuntimeMountReference(
                source: resolvedSource,
                target: mount.target,
                kind: .volume,
                access: mount.readOnly ? .readOnly : .readWrite
            )
        case .tmpfs:
            return RuntimeMountReference(
                source: "",
                target: mount.target,
                kind: .tmpfs,
                access: mount.readOnly ? .readOnly : .readWrite,
                mode: mount.mode,
                sizeBytes: mount.size.flatMap(parseSizeBytes)
            )
        }
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
