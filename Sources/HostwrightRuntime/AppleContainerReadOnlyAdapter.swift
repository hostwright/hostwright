public struct AppleContainerReadOnlyAdapter: RuntimeAdapter {
    public let executableResolver: RuntimeExecutableResolving
    public let processRunner: RuntimeProcessRunning
    public let redactionPolicy: RuntimeRedactionPolicy

    public init(
        executableResolver: RuntimeExecutableResolving = RuntimeExecutableResolver(),
        processRunner: RuntimeProcessRunning = FoundationRuntimeProcessRunner(),
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.executableResolver = executableResolver
        self.processRunner = processRunner
        self.redactionPolicy = redactionPolicy
    }

    public func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            adapterName: "AppleContainerReadOnlyAdapter",
            adapterVersion: "0.0.0-dev",
            runtimeName: "Apple container CLI",
            runtimeVersion: nil,
            supportsMutation: false,
            capabilities: [.readOnlyObservation]
        )
    }

    public func capabilities() async throws -> [RuntimeCapability] {
        guard executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) != nil else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }

        return [.readOnlyObservation]
    }

    public func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        guard let executable = executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }

        let spec = AppleContainerCommand.spec(kind: .listContainers, executable: executable)
        try RuntimeCommandPolicy.validateReadOnlyExecution(spec, phaseName: "Phase 5")

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
            warnings: ["Apple container read-only adapter does not plan runtime mutation in Phase 5."]
        )
    }

    public func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        throw RuntimeAdapterError.mutationUnavailableInCurrentPhase("Runtime mutation begins in Phase 8; Phase 5 cannot execute action '\(action.kind.rawValue)'.")
    }
}

