public enum AppleContainerCommand {
    public static let executableName = "container"

    public enum ReadOnlyKind: String, Equatable, Sendable {
        case version
        case listContainers
        case listImages
    }

    public enum MutatingKind: String, Equatable, Sendable {
        case createContainer
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
            timeout: timeout,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: purpose(for: kind, desiredService: desiredService)
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
            for value in desiredService.environment.sorted(by: { $0.name < $1.name }) {
                arguments += ["--env", "\(value.name)=\(value.value)"]
            }
            for port in desiredService.ports.sorted(by: stablePortOrdering) {
                if let hostPort = port.hostPort {
                    arguments += ["--publish", "\(hostPort):\(port.containerPort)"]
                }
            }
            arguments.append(desiredService.image)
            arguments += desiredService.command
            return arguments
        }
    }

    public static func purpose(for kind: ReadOnlyKind) -> String {
        switch kind {
        case .version:
            return "Read Apple container CLI version."
        case .listContainers:
            return "Read Apple container workload list as JSON for Phase 8A observation."
        case .listImages:
            return "Read local Apple container image list as JSON before Phase 8B create."
        }
    }

    public static func purpose(for kind: MutatingKind, desiredService: DesiredRuntimeService) -> String {
        switch kind {
        case .createContainer:
            return "Create missing Hostwright-managed service \(desiredService.identity.displayName)."
        }
    }

    public static func containerName(for identity: RuntimeServiceIdentity) -> String {
        "hostwright-\(identity.projectName)-\(identity.serviceName)"
    }

    private static func stablePortOrdering(_ lhs: RuntimePortMapping, _ rhs: RuntimePortMapping) -> Bool {
        [
            lhs.hostPort.map(String.init) ?? "",
            String(lhs.containerPort),
            lhs.protocolName.rawValue
        ].joined(separator: ":") <
        [
            rhs.hostPort.map(String.init) ?? "",
            String(rhs.containerPort),
            rhs.protocolName.rawValue
        ].joined(separator: ":")
    }
}
