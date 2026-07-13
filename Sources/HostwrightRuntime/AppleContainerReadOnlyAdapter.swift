import HostwrightCore

public struct AppleContainerReadOnlyAdapter: RuntimeAdapter {
    public let executableResolver: RuntimeExecutableResolving
    public let processRunner: RuntimeProcessRunning
    public let redactionPolicy: RuntimeRedactionPolicy

    public init(
        executableResolver: RuntimeExecutableResolving = RuntimeExecutableResolver(),
        processRunner: RuntimeProcessRunning = SecureRuntimeProcessRunner(),
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.executableResolver = executableResolver
        self.processRunner = processRunner
        self.redactionPolicy = redactionPolicy
    }

    public func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            adapterName: "AppleContainerReadOnlyAdapter",
            adapterVersion: HostwrightIdentity.version,
            runtimeName: "Apple container CLI",
            runtimeVersion: nil,
            supportsMutation: false,
            capabilities: [.readOnlyObservation]
        )
    }

    public func capabilities() async throws -> [RuntimeCapability] {
        guard try executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) != nil else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }

        return [.readOnlyObservation]
    }

    public func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        guard let executable = try executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }

        let spec = AppleContainerCommand.spec(kind: .listContainers, executable: executable)
        try RuntimeCommandPolicy.validateReadOnlyExecution(spec)

        let result = try await processRunner.run(spec)
        return try AppleContainerObservationParser.parse(
            result.standardOutput,
            desiredState: desiredState,
            metadata: await metadata(),
            redactionPolicy: redactionPolicy
        )
    }

    public func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
        RuntimePlan(
            actions: [],
            warnings: ["Apple container read-only adapter does not plan runtime mutation."]
        )
    }

    public func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        guard let executable = try executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }

        let containerID = service.resourceIdentifier
        guard RuntimeManagedResourceIdentity.isSupportedIdentifier(containerID) else {
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "Logs require an exact supported Hostwright resource identifier."
            )
        }
        let spec = AppleContainerCommand.spec(kind: .logs(containerID: containerID, tail: tail), executable: executable)
        try RuntimeCommandPolicy.validateReadOnlyExecution(spec)

        let result = try await processRunner.run(spec)
        return RuntimeLogResult(
            identity: service.identity,
            text: redactionPolicy.redact(result.standardOutput),
            lineLimit: min(max(1, tail), 1_000)
        )
    }

    public func runtimeVersion() async throws -> String {
        guard let executable = try executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }
        let spec = AppleContainerCommand.spec(kind: .version, executable: executable)
        try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
        let result = try await processRunner.run(spec)
        let version = redactionPolicy.redact(result.standardOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw RuntimeAdapterError.outputParseFailed("Apple container version output was empty.")
        }
        return version
    }

    public func resourceUsage(for resourceIdentifier: String) async throws -> RuntimeResourceUsageSnapshot {
        guard let executable = try executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }
        let spec = AppleContainerCommand.spec(kind: .stats(containerID: resourceIdentifier), executable: executable)
        try RuntimeCommandPolicy.validateExactResourceStats(spec, resourceIdentifier: resourceIdentifier)
        let result = try await processRunner.run(spec)
        return try AppleContainerStatsParser.parse(
            result.standardOutput,
            expectedResourceIdentifier: resourceIdentifier,
            redactionPolicy: redactionPolicy
        )
    }

    public func localImageEvidence(for imageReference: String) async throws -> RuntimeLocalImageEvidence {
        guard let executable = try executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }
        let spec = AppleContainerCommand.spec(kind: .listImages, executable: executable)
        try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
        let result = try await processRunner.run(spec)
        return try AppleContainerImageEvidenceParser.parse(
            result.standardOutput,
            expectedReference: imageReference,
            preferredArchitecture: "arm64",
            redactionPolicy: redactionPolicy
        )
    }

    public func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        throw RuntimeAdapterError.mutationUnavailableByPolicy("Read-only adapter cannot execute runtime action '\(action.kind.rawValue)'.")
    }
}
