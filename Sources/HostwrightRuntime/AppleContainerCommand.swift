public enum AppleContainerCommand {
    public static let executableName = "container"

    public enum ReadOnlyKind: Equatable, Sendable {
        case version
        case systemStatus
        case listContainers
        case listImages
        case listNetworks
        case listVolumes
        case listMachines
        case logs(containerID: String, tail: Int)
        case stats(containerID: String)
    }

    public enum MutatingKind: Equatable, Sendable {
        case createContainer
        case startContainer(containerID: String, attach: Bool = false)
        case stopForManagedRestart(containerID: String)
        case startForManagedRestart(containerID: String)
        case deleteContainer(containerID: String)
    }

    public static func spec(
        kind: ReadOnlyKind,
        executable: ResolvedRuntimeExecutable,
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout()
    ) -> RuntimeCommandSpec {
        RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: arguments(for: kind),
            timeout: timeout,
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            exitStatusPolicy: kind == .systemStatus ? .appleContainerSystemStatus : .zeroOnly,
            purpose: purpose(for: kind)
        )
    }

    public static func spec(
        kind: ReadOnlyKind,
        codec: AppleContainerCLICodec,
        executable: ResolvedRuntimeExecutable,
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout()
    ) -> RuntimeCommandSpec {
        RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: arguments(for: kind, codec: codec),
            timeout: timeout,
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            exitStatusPolicy: kind == .systemStatus ? .appleContainerSystemStatus : .zeroOnly,
            purpose: purpose(for: kind)
        )
    }

    public static func spec(
        kind: MutatingKind,
        executable: ResolvedRuntimeExecutable,
        desiredService: DesiredRuntimeService,
        mutationContext: RuntimeMutationContext,
        resourceIdentifier: String? = nil,
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout()
    ) throws -> RuntimeCommandSpec {
        RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: try arguments(
                for: kind,
                desiredService: desiredService,
                mutationContext: mutationContext,
                resourceIdentifier: resourceIdentifier
            ),
            environment: inheritedSensitiveEnvironment(for: desiredService),
            sensitiveValues: desiredService.environment.filter(\.isSensitive).map(\.value),
            timeout: timeout,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: mutationKind(for: kind),
            purpose: purpose(for: kind, desiredService: desiredService)
        )
    }

    public static func spec(
        kind: MutatingKind,
        codec: AppleContainerCLICodec,
        executable: ResolvedRuntimeExecutable,
        desiredService: DesiredRuntimeService,
        mutationContext: RuntimeMutationContext,
        resourceIdentifier: String? = nil,
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout()
    ) throws -> RuntimeCommandSpec {
        RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: try arguments(
                for: kind,
                desiredService: desiredService,
                mutationContext: mutationContext,
                resourceIdentifier: resourceIdentifier,
                codec: codec
            ),
            environment: inheritedSensitiveEnvironment(for: desiredService),
            sensitiveValues: desiredService.environment.filter(\.isSensitive).map(\.value),
            timeout: timeout,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: mutationKind(for: kind),
            purpose: purpose(for: kind, desiredService: desiredService)
        )
    }

    public static func spec(
        kind: MutatingKind,
        executable: ResolvedRuntimeExecutable,
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout()
    ) -> RuntimeCommandSpec {
        RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: arguments(for: kind),
            timeout: timeout,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: mutationKind(for: kind),
            purpose: purpose(for: kind)
        )
    }

    public static func spec(
        kind: MutatingKind,
        codec: AppleContainerCLICodec,
        executable: ResolvedRuntimeExecutable,
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout()
    ) -> RuntimeCommandSpec {
        RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: arguments(for: kind, codec: codec),
            timeout: timeout,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: mutationKind(for: kind),
            purpose: purpose(for: kind)
        )
    }

    public static func arguments(for kind: ReadOnlyKind) -> [String] {
        switch kind {
        case .version:
            return ["--version"]
        case .systemStatus:
            return ["system", "status", "--format", "json"]
        case .listContainers:
            return ["list", "--all", "--format", "json"]
        case .listImages:
            return ["image", "list", "--format", "json"]
        case .listNetworks:
            return ["network", "list", "--format", "json"]
        case .listVolumes:
            return ["volume", "list", "--format", "json"]
        case .listMachines:
            return ["machine", "list", "--format", "json"]
        case .logs(let containerID, let tail):
            return ["logs", "-n", String(clampedTail(tail)), containerID]
        case .stats(let containerID):
            return ["stats", containerID, "--no-stream", "--format", "json"]
        }
    }

    public static func arguments(
        for kind: ReadOnlyKind,
        codec: AppleContainerCLICodec
    ) -> [String] {
        switch codec {
        case .v1_0_0, .v1_1_0:
            return arguments(for: kind)
        }
    }

    public static func arguments(
        for kind: MutatingKind,
        desiredService: DesiredRuntimeService,
        mutationContext: RuntimeMutationContext,
        resourceIdentifier: String? = nil
    ) throws -> [String] {
        switch kind {
        case .createContainer:
            let resourceIdentifier =
                resourceIdentifier ?? desiredService.identity.managedResourceIdentifier
            guard RuntimeManagedResourceIdentity.isScopedCurrentIdentifier(
                resourceIdentifier,
                for: desiredService.identity
            ) else {
                throw RuntimeManagedResourceIdentityError.invalidMutationContext
            }
            var arguments = [
                "create",
                "--name",
                resourceIdentifier
            ]
            let ownershipLabels = try RuntimeManagedResourceIdentity.labels(
                for: desiredService.identity,
                resourceIdentifier: resourceIdentifier,
                context: mutationContext
            )
            let labels = ownershipLabels.merging(desiredService.labels) { owned, _ in owned }
            for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
                arguments += ["--label", "\(key)=\(value)"]
            }
            arguments += ["--os", desiredService.platformOperatingSystem]
            arguments += ["--arch", desiredService.platformArchitecture]
            if let cpuCount = desiredService.cpuCount {
                arguments += ["--cpus", String(cpuCount)]
            }
            if let memoryBytes = desiredService.memoryBytes {
                arguments += ["--memory", "\(memoryBytes)B"]
            }
            if let userID = desiredService.userID {
                arguments += ["--uid", String(userID)]
            }
            if let groupID = desiredService.groupID {
                arguments += ["--gid", String(groupID)]
            }
            if let workingDirectory = desiredService.workingDirectory {
                arguments += ["--workdir", workingDirectory]
            }
            if let executable = desiredService.entrypoint.first {
                arguments += ["--entrypoint", executable]
            }
            if desiredService.initProcess {
                arguments.append("--init")
            }
            for value in desiredService.environment.sorted(by: { $0.name < $1.name }) {
                let argument = value.isSensitive ? value.name : "\(value.name)=\(value.value)"
                arguments += ["--env", argument]
            }
            for port in desiredService.ports.sorted(by: stablePortOrdering) {
                if let hostPort = port.hostPort {
                    arguments += ["--publish", publishSpec(for: port, hostPort: hostPort)]
                }
            }
            for mount in desiredService.mounts.sorted(by: stableMountOrdering) {
                arguments += ["--volume", volumeSpec(for: mount)]
            }
            if desiredService.readOnlyRootFilesystem {
                arguments.append("--read-only")
            }
            if desiredService.rosetta {
                arguments.append("--rosetta")
            }
            if desiredService.virtualization {
                arguments.append("--virtualization")
            }
            if let sharedMemoryBytes = desiredService.sharedMemoryBytes {
                arguments += ["--shm-size", "\(sharedMemoryBytes)B"]
            }
            arguments.append(desiredService.image)
            arguments += desiredService.entrypoint.dropFirst()
            arguments += desiredService.command
            return arguments
        case .startContainer, .stopForManagedRestart, .startForManagedRestart, .deleteContainer:
            return arguments(for: kind)
        }
    }

    public static func arguments(
        for kind: MutatingKind,
        desiredService: DesiredRuntimeService,
        mutationContext: RuntimeMutationContext,
        resourceIdentifier: String? = nil,
        codec: AppleContainerCLICodec
    ) throws -> [String] {
        switch codec {
        case .v1_0_0, .v1_1_0:
            return try arguments(
                for: kind,
                desiredService: desiredService,
                mutationContext: mutationContext,
                resourceIdentifier: resourceIdentifier
            )
        }
    }

    public static func arguments(for kind: MutatingKind) -> [String] {
        switch kind {
        case .createContainer:
            return []
        case .startContainer(let containerID, let attach):
            return attach
                ? ["start", "--attach", containerID]
                : ["start", containerID]
        case .stopForManagedRestart(let containerID):
            return ["stop", containerID]
        case .startForManagedRestart(let containerID):
            return ["start", containerID]
        case .deleteContainer(let containerID):
            return ["delete", containerID]
        }
    }

    public static func arguments(
        for kind: MutatingKind,
        codec: AppleContainerCLICodec
    ) -> [String] {
        switch codec {
        case .v1_0_0, .v1_1_0:
            return arguments(for: kind)
        }
    }

    public static func purpose(for kind: ReadOnlyKind) -> String {
        switch kind {
        case .version:
            return "Read Apple container CLI version."
        case .systemStatus:
            return "Read Apple container service readiness as JSON."
        case .listContainers:
            return "Read Apple container workload list as JSON."
        case .listImages:
            return "Read local Apple container image list as JSON before confirmed create."
        case .listNetworks:
            return "Read Apple container network list as JSON."
        case .listVolumes:
            return "Read Apple container volume list as JSON."
        case .listMachines:
            return "Read Apple container machine list as JSON."
        case .logs(let containerID, let tail):
            return "Read last \(clampedTail(tail)) log lines for Hostwright-managed container \(containerID)."
        case .stats(let containerID):
            return "Read one resource-usage sample for exact Hostwright-managed container \(containerID)."
        }
    }

    public static func purpose(for kind: MutatingKind, desiredService: DesiredRuntimeService) -> String {
        switch kind {
        case .createContainer:
            return "Create missing Hostwright-managed service \(desiredService.identity.displayName)."
        case .startContainer, .stopForManagedRestart, .startForManagedRestart, .deleteContainer:
            return purpose(for: kind)
        }
    }

    public static func purpose(for kind: MutatingKind) -> String {
        switch kind {
        case .createContainer:
            return "Create missing Hostwright-managed service."
        case .startContainer(let containerID, let attach):
            return attach
                ? "Start Hostwright-managed container \(containerID) and require its init process to complete successfully."
                : "Start Hostwright-managed container \(containerID)."
        case .stopForManagedRestart(let containerID):
            return "Stop Hostwright-managed container \(containerID) as the first managed restart step."
        case .startForManagedRestart(let containerID):
            return "Start Hostwright-managed container \(containerID) as the second managed restart step."
        case .deleteContainer(let containerID):
            return "Delete exact Hostwright-managed container \(containerID)."
        }
    }

    public static func mutationKind(for kind: MutatingKind) -> RuntimeMutationCommandKind {
        switch kind {
        case .createContainer:
            return .createMissingService
        case .startContainer:
            return .startManagedService
        case .stopForManagedRestart, .startForManagedRestart:
            return .restartManagedService
        case .deleteContainer:
            return .deleteManagedContainer
        }
    }

    public static func containerName(for identity: RuntimeServiceIdentity) -> String {
        identity.managedResourceIdentifier
    }

    private static func stablePortOrdering(_ lhs: RuntimePortMapping, _ rhs: RuntimePortMapping) -> Bool {
        [
            lhs.hostPort.map(String.init) ?? "",
            String(lhs.containerPort),
            lhs.bindAddress ?? "",
            lhs.protocolName.rawValue
        ].joined(separator: ":") <
        [
            rhs.hostPort.map(String.init) ?? "",
            String(rhs.containerPort),
            rhs.bindAddress ?? "",
            rhs.protocolName.rawValue
        ].joined(separator: ":")
    }

    private static func stableMountOrdering(
        _ lhs: RuntimeMountReference,
        _ rhs: RuntimeMountReference
    ) -> Bool {
        [lhs.source, lhs.target, lhs.access.rawValue].joined(separator: ":") <
            [rhs.source, rhs.target, rhs.access.rawValue].joined(separator: ":")
    }

    private static func volumeSpec(for mount: RuntimeMountReference) -> String {
        let base = "\(mount.source):\(mount.target)"
        return mount.access == .readOnly ? "\(base):ro" : base
    }

    private static func publishSpec(for port: RuntimePortMapping, hostPort: Int) -> String {
        let bindAddress = port.bindAddress ?? "127.0.0.1"
        let base = "\(bindAddress):\(hostPort):\(port.containerPort)"
        switch port.protocolName {
        case .tcp:
            return base
        case .udp:
            return "\(base)/udp"
        }
    }

    private static func clampedTail(_ tail: Int) -> Int {
        min(max(1, tail), 1_000)
    }

    private static func inheritedSensitiveEnvironment(
        for desiredService: DesiredRuntimeService
    ) -> [String: String] {
        desiredService.environment
            .filter(\.isSensitive)
            .sorted { lhs, rhs in
                if lhs.name == rhs.name { return lhs.value < rhs.value }
                return lhs.name < rhs.name
            }
            .reduce(into: [:]) { result, value in
                result[value.name] = value.value
            }
    }
}
