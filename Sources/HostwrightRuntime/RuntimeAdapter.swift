public enum RuntimeAdapterError: Error, Equatable, Sendable {
    case runtimeUnavailable(String)
    case executableNotFound(String)
    case unsupportedRuntime(String)
    case commandRejected(classification: RuntimeCommandClassification, message: String)
    case commandTimedOut(command: String, partialOutput: String, partialError: String)
    case commandCancelled(command: String, partialOutput: String, partialError: String)
    case commandOutputLimitExceeded(command: String, partialOutput: String, partialError: String)
    case commandProcessTreeViolation(command: String, partialOutput: String, partialError: String)
    case commandFailed(exitStatus: Int32, message: String, standardError: String)
    case managedRestartStartFailedAfterStop(message: String, standardError: String)
    case outputParseFailed(String)
    case permissionDenied(String)
    case redactionFailure(String)
    case capabilityUnavailable(RuntimeCapability)
    case mutationUnavailableByPolicy(String)
    case normalizedFailure(RuntimeNormalizedFailure)

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
        case .commandCancelled(let command, let partialOutput, let partialError):
            return .commandCancelled(
                command: policy.redact(command, exactValues: exactValues),
                partialOutput: policy.redact(partialOutput, exactValues: exactValues),
                partialError: policy.redact(partialError, exactValues: exactValues)
            )
        case .commandOutputLimitExceeded(let command, let partialOutput, let partialError):
            return .commandOutputLimitExceeded(
                command: policy.redact(command, exactValues: exactValues),
                partialOutput: policy.redact(partialOutput, exactValues: exactValues),
                partialError: policy.redact(partialError, exactValues: exactValues)
            )
        case .commandProcessTreeViolation(let command, let partialOutput, let partialError):
            return .commandProcessTreeViolation(
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
        case .normalizedFailure(let failure):
            return .normalizedFailure(
                failure.redacted(using: policy, exactValues: exactValues)
            )
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
    public let context: RuntimeMutationContext?

    public init(
        confirmed: Bool,
        reason: String,
        planHash: String? = nil,
        manifestHash: String? = nil,
        profileHash: String? = nil,
        approvalHash: String? = nil,
        context: RuntimeMutationContext? = nil
    ) {
        self.confirmed = confirmed
        self.reason = reason
        self.planHash = planHash
        self.manifestHash = manifestHash
        self.profileHash = profileHash
        self.approvalHash = approvalHash
        self.context = context
    }
}

public protocol RuntimeAdapter: Sendable {
    func metadata() async -> RuntimeAdapterMetadata
    func capabilities() async throws -> [RuntimeCapability]
    func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot
    func inventory() async throws -> RuntimeInventory
    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState
    func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan
    func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult
    func runtimeVersion() async throws -> String
    func runtimeReadiness() async throws -> RuntimeReadinessReport
    func localImageEvidence(for imageReference: String) async throws -> RuntimeLocalImageEvidence
    func resourceUsage(for resourceIdentifier: String) async throws -> RuntimeResourceUsageSnapshot
    func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent
}

public extension RuntimeAdapter {
    func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        throw RuntimeAdapterError.capabilityUnavailable(.readOnlyObservation)
    }

    func inventory() async throws -> RuntimeInventory {
        throw RuntimeAdapterError.capabilityUnavailable(.readOnlyObservation)
    }

    func runtimeVersion() async throws -> String {
        throw RuntimeAdapterError.capabilityUnavailable(.readOnlyObservation)
    }

    func runtimeReadiness() async throws -> RuntimeReadinessReport {
        throw RuntimeAdapterError.capabilityUnavailable(.readOnlyObservation)
    }

    func resourceUsage(for resourceIdentifier: String) async throws -> RuntimeResourceUsageSnapshot {
        throw RuntimeAdapterError.capabilityUnavailable(.readOnlyObservation)
    }

    func localImageEvidence(for imageReference: String) async throws -> RuntimeLocalImageEvidence {
        throw RuntimeAdapterError.capabilityUnavailable(.readOnlyObservation)
    }
}

public enum RuntimeCreateSubsetPolicy {
    public static func validate(
        _ service: DesiredRuntimeService,
        providerID: RuntimeProviderID
    ) throws {
        if providerID == .appleContainerCLI {
            try validateAppleContainerCLI(service)
            return
        }
        if providerID == .appleContainerization {
            try validateAppleContainerization(service)
            return
        }
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "Create-subset validation is unavailable for the selected runtime provider."
        )
    }

    private static func validateAppleContainerCLI(_ service: DesiredRuntimeService) throws {
        guard service.ports.allSatisfy({
            guard let hostPort = $0.hostPort else { return false }
            return (1_024...65_535).contains(hostPort) &&
                (1...65_535).contains($0.containerPort)
        }) else {
            throw RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: "Create-only apply requires valid unprivileged host ports and valid container ports."
            )
        }
        guard service.ports.allSatisfy({
            $0.bindAddress == nil || $0.bindAddress == "127.0.0.1"
        }) else {
            throw RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: "Create-only apply accepts only localhost port publishing."
            )
        }
        guard !service.image.hasPrefix("-") else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Create-only apply rejects image values beginning with '-'.")
        }
        guard service.environment.allSatisfy({ $0.secretReference == nil }) else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Create-only apply rejects unresolved secret references.")
        }
        guard service.platformOperatingSystem == "linux",
              (service.platformArchitecture == "arm64" && !service.rosetta) ||
                (
                    service.platformArchitecture == "amd64" &&
                        service.rosetta &&
                        service.virtualization
                ) else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Apple container CLI create supports linux/arm64 without Rosetta or capability-gated linux/amd64 with Rosetta and virtualization."
            )
        }
        guard service.mounts.allSatisfy({
            $0.source.hasPrefix("/") &&
                $0.target.hasPrefix("/") &&
                $0.access != .unknown
        }) else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Apple container CLI create accepts only validated absolute bind mounts with explicit read-only or read-write access."
            )
        }
    }

    private static func validateAppleContainerization(_ service: DesiredRuntimeService) throws {
        guard service.mounts.isEmpty,
              service.ports.isEmpty,
              service.healthCheck == nil,
              service.probes.configuredKinds.isEmpty,
              service.platformOperatingSystem == "linux",
              service.platformArchitecture == "arm64",
              service.cpuCount == nil,
              service.memoryBytes == nil,
              service.userID == nil,
              service.groupID == nil,
              service.workingDirectory == nil,
              service.entrypoint.isEmpty,
              !service.initProcess,
              service.labels.isEmpty,
              service.hooks.postStart == nil,
              service.hooks.preStop == nil,
              !service.rosetta,
              !service.virtualization,
              !service.readOnlyRootFilesystem,
              service.sharedMemoryBytes == nil,
              service.environment.allSatisfy({ $0.secretReference == nil }) else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Containerization 0.35.0 create does not qualify the requested Phase 04 service options; select the Apple CLI provider or remove unsupported fields before mutation."
            )
        }
    }
}

public struct AppleContainerCLIAdapter: RuntimeAdapter {
    private let applyAdapter: AppleContainerApplyAdapter

    public init(
        executableResolver: RuntimeExecutableResolving = RuntimeExecutableResolver(),
        processRunner: RuntimeProcessRunning = SecureRuntimeProcessRunner(),
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

    public func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        try await applyAdapter.capabilitySnapshot()
    }

    public func inventory() async throws -> RuntimeInventory {
        try await applyAdapter.inventory()
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

    public func runtimeReadiness() async throws -> RuntimeReadinessReport {
        try await applyAdapter.runtimeReadiness()
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
