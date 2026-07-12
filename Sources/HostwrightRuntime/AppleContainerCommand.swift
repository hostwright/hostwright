public enum AppleContainerCommand {
    public static let executableName = "container"

    public enum ReadOnlyKind: Equatable, Sendable {
        case version
        case listContainers
        case listImages
        case logs(containerID: String, tail: Int)
    }

    public enum MutatingKind: Equatable, Sendable {
        case createContainer
        case startContainer(containerID: String)
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
            purpose: purpose(for: kind)
        )
    }

    public static func spec(
        kind: MutatingKind,
        executable: ResolvedRuntimeExecutable,
        desiredService: DesiredRuntimeService,
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout()
    ) -> RuntimeCommandSpec {
        RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: arguments(for: kind, desiredService: desiredService),
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

    public static func arguments(for kind: ReadOnlyKind) -> [String] {
        switch kind {
        case .version:
            return ["--version"]
        case .listContainers:
            return ["list", "--all", "--format", "json"]
        case .listImages:
            return ["image", "list", "--format", "json"]
        case .logs(let containerID, let tail):
            return ["logs", "-n", String(clampedTail(tail)), containerID]
        }
    }

    public static func arguments(for kind: MutatingKind, desiredService: DesiredRuntimeService) -> [String] {
        switch kind {
        case .createContainer:
            var arguments = [
                "create",
                "--name",
                containerName(for: desiredService.identity)
            ]
            for (key, value) in RuntimeManagedResourceIdentity.labels(for: desiredService.identity).sorted(by: { $0.key < $1.key }) {
                arguments += ["--label", "\(key)=\(value)"]
            }
            for value in desiredService.environment.sorted(by: { $0.name < $1.name }) {
                arguments += ["--env", "\(value.name)=\(value.value)"]
            }
            for port in desiredService.ports.sorted(by: stablePortOrdering) {
                if let hostPort = port.hostPort {
                    arguments += ["--publish", publishSpec(for: port, hostPort: hostPort)]
                }
            }
            arguments.append(desiredService.image)
            arguments += desiredService.command
            return arguments
        case .startContainer, .stopForManagedRestart, .startForManagedRestart, .deleteContainer:
            return arguments(for: kind)
        }
    }

    public static func arguments(for kind: MutatingKind) -> [String] {
        switch kind {
        case .createContainer:
            return []
        case .startContainer(let containerID):
            return ["start", containerID]
        case .stopForManagedRestart(let containerID):
            return ["stop", containerID]
        case .startForManagedRestart(let containerID):
            return ["start", containerID]
        case .deleteContainer(let containerID):
            return ["delete", containerID]
        }
    }

    public static func purpose(for kind: ReadOnlyKind) -> String {
        switch kind {
        case .version:
            return "Read Apple container CLI version."
        case .listContainers:
            return "Read Apple container workload list as JSON."
        case .listImages:
            return "Read local Apple container image list as JSON before confirmed create."
        case .logs(let containerID, let tail):
            return "Read last \(clampedTail(tail)) log lines for Hostwright-managed container \(containerID)."
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
        case .startContainer(let containerID):
            return "Start Hostwright-managed container \(containerID)."
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
}
