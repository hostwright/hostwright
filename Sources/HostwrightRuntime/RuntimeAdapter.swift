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
    case mutationUnavailableInCurrentPhase(String)

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
        case .mutationUnavailableInCurrentPhase(let message):
            return .mutationUnavailableInCurrentPhase(policy.redact(message))
        }
    }
}

public struct RuntimeMutationConfirmation: Equatable, Sendable {
    public let confirmed: Bool
    public let reason: String

    public init(confirmed: Bool, reason: String) {
        self.confirmed = confirmed
        self.reason = reason
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
    public init() {}

    public func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            adapterName: "AppleContainerCLIAdapter",
            adapterVersion: "0.0.0-dev",
            runtimeName: "Apple container CLI",
            runtimeVersion: nil,
            supportsMutation: false,
            capabilities: []
        )
    }

    public func capabilities() async throws -> [RuntimeCapability] {
        []
    }

    public func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI observation begins in Phase 5; Phase 4 does not execute Apple container.")
    }

    public func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
        RuntimePlan(
            actions: [],
            warnings: ["Apple container CLI adapter is a Phase 4 contract scaffold. No Apple container command was executed."]
        )
    }

    public func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        throw RuntimeAdapterError.mutationUnavailableInCurrentPhase("Runtime mutation begins in Phase 8; Phase 4 cannot execute action '\(action.kind.rawValue)'.")
    }
}
