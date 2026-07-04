import HostwrightCore

public struct MockRuntimeAdapter: RuntimeAdapter {
    public enum Scenario: Sendable {
        case unavailable(String)
        case availableEmpty
        case observed([ObservedRuntimeService])
        case commandFailure(RuntimeAdapterError)
        case timeout
        case redactedFailure(String)
        case logs(String)
    }

    public let scenario: Scenario
    public let adapterMetadata: RuntimeAdapterMetadata
    public let redactionPolicy: RuntimeRedactionPolicy

    public init(
        scenario: Scenario,
        adapterMetadata: RuntimeAdapterMetadata = MockRuntimeAdapter.defaultMetadata,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.scenario = scenario
        self.adapterMetadata = adapterMetadata
        self.redactionPolicy = redactionPolicy
    }

    public static let defaultMetadata = RuntimeAdapterMetadata(
        adapterName: "MockRuntimeAdapter",
        adapterVersion: HostwrightIdentity.version,
        runtimeName: "mock",
        runtimeVersion: nil,
        supportsMutation: false,
        capabilities: [.readOnlyObservation, .healthObservation]
    )

    public func metadata() async -> RuntimeAdapterMetadata {
        adapterMetadata
    }

    public func capabilities() async throws -> [RuntimeCapability] {
        switch scenario {
        case .unavailable(let message):
            throw RuntimeAdapterError.runtimeUnavailable(redactionPolicy.redact(message))
        default:
            return adapterMetadata.capabilities
        }
    }

    public func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        switch scenario {
        case .unavailable(let message):
            throw RuntimeAdapterError.runtimeUnavailable(redactionPolicy.redact(message))
        case .availableEmpty:
            return ObservedRuntimeState(projectName: desiredState.projectName, services: [], adapterMetadata: adapterMetadata)
        case .observed(let services):
            return ObservedRuntimeState(projectName: desiredState.projectName, services: services, adapterMetadata: adapterMetadata)
        case .commandFailure(let error):
            throw error.redacted(using: redactionPolicy)
        case .timeout:
            throw RuntimeAdapterError.commandTimedOut(command: "mock-runtime-observe", partialOutput: "", partialError: "")
        case .redactedFailure(let output):
            throw RuntimeAdapterError.commandFailed(exitStatus: 1, message: "mock command failed", standardError: redactionPolicy.redact(output))
        case .logs:
            return ObservedRuntimeState(projectName: desiredState.projectName, services: [], adapterMetadata: adapterMetadata)
        }
    }

    public func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
        let observedIdentities = Set(observedState.services.map(\.identity))
        let actions = desiredState.services
            .filter { !observedIdentities.contains($0.identity) }
            .map { service in
                PlannedRuntimeAction(
                    kind: .create,
                    identity: service.identity,
                    isDestructive: false,
                    summary: "Mock plan would create \(service.identity.displayName)."
                )
            }

        return RuntimePlan(actions: actions)
    }

    public func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        throw RuntimeAdapterError.mutationUnavailableByPolicy("MockRuntimeAdapter does not execute runtime mutation.")
    }

    public func logs(for identity: RuntimeServiceIdentity, tail: Int) async throws -> RuntimeLogResult {
        switch scenario {
        case .logs(let text):
            return RuntimeLogResult(identity: identity, text: redactionPolicy.redact(text), lineLimit: min(max(1, tail), 1_000))
        case .unavailable(let message):
            throw RuntimeAdapterError.runtimeUnavailable(redactionPolicy.redact(message))
        default:
            throw RuntimeAdapterError.capabilityUnavailable(.logStreaming)
        }
    }
}
