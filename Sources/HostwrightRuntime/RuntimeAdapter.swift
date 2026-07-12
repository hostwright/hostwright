public enum RuntimeAdapterError: Error, Equatable, Sendable {
    case runtimeUnavailable(String)
    case executableNotFound(String)
    case unsupportedRuntime(String)
    case commandRejected(classification: RuntimeCommandClassification, message: String)
    case commandTimedOut(command: String, partialOutput: String, partialError: String)
    case commandFailed(exitStatus: Int32, message: String, standardError: String)
    case managedRestartStartFailedAfterStop(message: String, standardError: String)
    case outputParseFailed(String)
    case permissionDenied(String)
    case redactionFailure(String)
    case capabilityUnavailable(RuntimeCapability)
    case mutationUnavailableByPolicy(String)

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> RuntimeAdapterError {
        redacted(using: policy, exactValues: [])
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default, exactValues: [String]) -> RuntimeAdapterError {
        switch self {
        case .runtimeUnavailable(let message):
            return .runtimeUnavailable(policy.redact(message, exactValues: exactValues))
        case .executableNotFound(let path):
            return .executableNotFound(policy.redact(path, exactValues: exactValues))
        case .unsupportedRuntime(let message):
            return .unsupportedRuntime(policy.redact(message, exactValues: exactValues))
        case .commandRejected(let classification, let message):
            return .commandRejected(classification: classification, message: policy.redact(message, exactValues: exactValues))
        case .commandTimedOut(let command, let partialOutput, let partialError):
            return .commandTimedOut(
                command: policy.redact(command, exactValues: exactValues),
                partialOutput: policy.redact(partialOutput, exactValues: exactValues),
                partialError: policy.redact(partialError, exactValues: exactValues)
            )
        case .commandFailed(let exitStatus, let message, let standardError):
            return .commandFailed(
                exitStatus: exitStatus,
                message: policy.redact(message, exactValues: exactValues),
                standardError: policy.redact(standardError, exactValues: exactValues)
            )
        case .managedRestartStartFailedAfterStop(let message, let standardError):
            return .managedRestartStartFailedAfterStop(
                message: policy.redact(message, exactValues: exactValues),
                standardError: policy.redact(standardError, exactValues: exactValues)
            )
        case .outputParseFailed(let message):
            return .outputParseFailed(policy.redact(message, exactValues: exactValues))
        case .permissionDenied(let message):
            return .permissionDenied(policy.redact(message, exactValues: exactValues))
        case .redactionFailure(let message):
            return .redactionFailure(policy.redact(message, exactValues: exactValues))
        case .capabilityUnavailable(let capability):
            return .capabilityUnavailable(capability)
        case .mutationUnavailableByPolicy(let message):
            return .mutationUnavailableByPolicy(policy.redact(message, exactValues: exactValues))
        }
    }
}

public struct RuntimeMutationConfirmation: Equatable, Sendable {
    public let confirmed: Bool
    public let reason: String
    public let planHash: String?
    public let manifestHash: String?
    public let profileHash: String?
    public let approvalHash: String?

    public init(
        confirmed: Bool,
        reason: String,
        planHash: String? = nil,
        manifestHash: String? = nil,
        profileHash: String? = nil,
        approvalHash: String? = nil
    ) {
        self.confirmed = confirmed
        self.reason = reason
        self.planHash = planHash
        self.manifestHash = manifestHash
        self.profileHash = profileHash
        self.approvalHash = approvalHash
    }
}

public protocol RuntimeAdapter: Sendable {
    func metadata() async -> RuntimeAdapterMetadata
    func capabilities() async throws -> [RuntimeCapability]
    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState
    func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan
    func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult
    func runtimeVersion() async throws -> String
    func localImageEvidence(for imageReference: String) async throws -> RuntimeLocalImageEvidence
    func resourceUsage(for resourceIdentifier: String) async throws -> RuntimeResourceUsageSnapshot
    func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent
}

public extension RuntimeAdapter {
    func runtimeVersion() async throws -> String {
        throw RuntimeAdapterError.capabilityUnavailable(.readOnlyObservation)
    }

    func resourceUsage(for resourceIdentifier: String) async throws -> RuntimeResourceUsageSnapshot {
        throw RuntimeAdapterError.capabilityUnavailable(.readOnlyObservation)
    }

    func localImageEvidence(for imageReference: String) async throws -> RuntimeLocalImageEvidence {
        throw RuntimeAdapterError.capabilityUnavailable(.readOnlyObservation)
    }
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

    public func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        try await applyAdapter.logs(for: service, tail: tail)
    }

    public func runtimeVersion() async throws -> String {
        try await applyAdapter.runtimeVersion()
    }

    public func resourceUsage(for resourceIdentifier: String) async throws -> RuntimeResourceUsageSnapshot {
        try await applyAdapter.resourceUsage(for: resourceIdentifier)
    }

    public func localImageEvidence(for imageReference: String) async throws -> RuntimeLocalImageEvidence {
        try await applyAdapter.localImageEvidence(for: imageReference)
    }

    public func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        try await applyAdapter.execute(action, confirmation: confirmation)
    }
}

public enum RuntimeAdapterFactory {
    public static func defaultLocal() -> any RuntimeAdapter {
        AppleContainerCLIAdapter()
    }

    public static func defaultReadOnlyLocal() -> any RuntimeAdapter {
        AppleContainerReadOnlyAdapter()
    }
}
