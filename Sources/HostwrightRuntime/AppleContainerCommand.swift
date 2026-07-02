public enum AppleContainerCommand {
    public static let executableName = "container"

    public enum ReadOnlyKind: String, Equatable, Sendable {
        case version
        case listContainers
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

    public static func arguments(for kind: ReadOnlyKind) -> [String] {
        switch kind {
        case .version:
            return ["--version"]
        case .listContainers:
            return ["list", "--all", "--format", "json"]
        }
    }

    public static func purpose(for kind: ReadOnlyKind) -> String {
        switch kind {
        case .version:
            return "Read Apple container CLI version."
        case .listContainers:
            return "Read Apple container workload list as JSON for Phase 8A observation."
        }
    }
}
