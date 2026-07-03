public enum RuntimeAdapterError: Error, Equatable, Sendable {
    case runtimeUnavailable(String)
    case executableNotFound(String)
    case unsupportedRuntime(String)
    case commandRejected(classification: RuntimeCommandClassification, message: String)
    case commandTimedOut(command: String, partialOutput: String, partialError: String)
    case commandFailed(exitStatus: Int32, message: String, standardError: String)
    case outputParseFailed(String)
    case permissionDenied(String)
    case redactionFailure(String)
    case capabilityUnavailable(RuntimeCapability)
    case mutationUnavailableByPolicy(String)

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> RuntimeAdapterError {
        switch self {
        case .runtimeUnavailable(let message):
            return .runtimeUnavailable(policy.redact(message))
        case .executableNotFound(let path):
            return .executableNotFound(policy.redact(path))
        case .unsupportedRuntime(let message):
            return .unsupportedRuntime(policy.redact(message))
        case .commandRejected(let classification, let message):
            return .commandRejected(classification: classification, message: policy.redact(message))
        case .commandTimedOut(let command, let partialOutput, let partialError):
            return .commandTimedOut(
                command: policy.redact(command),
                partialOutput: policy.redact(partialOutput),
                partialError: policy.redact(partialError)
            )
        case .commandFailed(let exitStatus, let message, let standardError):
            return .commandFailed(
                exitStatus: exitStatus,
                message: policy.redact(message),
                standardError: policy.redact(standardError)
            )
        case .outputParseFailed(let message):
            return .outputParseFailed(policy.redact(message))
        case .permissionDenied(let message):
            return .permissionDenied(policy.redact(message))
        case .redactionFailure(let message):
            return .redactionFailure(policy.redact(message))
        case .capabilityUnavailable(let capability):
            return .capabilityUnavailable(capability)
        case .mutationUnavailableByPolicy(let message):
            return .mutationUnavailableByPolicy(policy.redact(message))
        }
    }
}

public struct RuntimeMutationConfirmation: Equatable, Sendable {
    public let confirmed: Bool
    public let reason: String
    public let planHash: String?

    public init(confirmed: Bool, reason: String, planHash: String? = nil) {
        self.confirmed = confirmed
        self.reason = reason
        self.planHash = planHash
    }
}

public protocol RuntimeAdapter: Sendable {
    func metadata() async -> RuntimeAdapterMetadata
    func capabilities() async throws -> [RuntimeCapability]
    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState
    func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan
    func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent
}

public struct AppleContainerCLIAdapter: RuntimeAdapter {
    private let applyAdapter: AppleContainerApplyAdapter

    public init(
        executableResolver: RuntimeExecutableResolving = RuntimeExecutableResolver(),
        processRunner: RuntimeProcessRunning = FoundationRuntimeProcessRunner(),
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.applyAdapter = AppleContainerApplyAdapter(
            executableResolver: executableResolver,
            processRunner: processRunner,
            redactionPolicy: redactionPolicy
        )
    }

    public func metadata() async -> RuntimeAdapterMetadata {
        await applyAdapter.metadata()
    }

    public func capabilities() async throws -> [RuntimeCapability] {
        try await applyAdapter.capabilities()
    }

    public func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        try await applyAdapter.observe(desiredState: desiredState)
    }

    public func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
        try await applyAdapter.plan(desiredState: desiredState, observedState: observedState)
    }

    public func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        try await applyAdapter.execute(action, confirmation: confirmation)
    }
}

public enum RuntimeAdapterFactory {
    public static func defaultLocal() -> any RuntimeAdapter {
        AppleContainerCLIAdapter()
    }
}
