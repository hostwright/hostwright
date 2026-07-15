import HostwrightCore
import HostwrightRuntime
import HostwrightSecrets

public struct ScriptedRuntimeAdapter: RuntimeAdapter {
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
        adapterMetadata: RuntimeAdapterMetadata = ScriptedRuntimeAdapter.defaultMetadata,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.scenario = scenario
        self.adapterMetadata = adapterMetadata
        self.redactionPolicy = redactionPolicy
    }

    public static let defaultMetadata = RuntimeAdapterMetadata(
        adapterName: "ScriptedRuntimeAdapter",
        adapterVersion: HostwrightIdentity.version,
        runtimeName: "scripted-test-runtime",
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

    public func runtimeReadiness() async throws -> RuntimeReadinessReport {
        switch scenario {
        case .unavailable(let message):
            throw RuntimeAdapterError.runtimeUnavailable(redactionPolicy.redact(message))
        case .commandFailure(let error):
            throw error.redacted(using: redactionPolicy)
        case .timeout:
            throw RuntimeAdapterError.commandTimedOut(
                command: "scripted-runtime-readiness",
                partialOutput: "",
                partialError: ""
            )
        case .redactedFailure(let output):
            throw RuntimeAdapterError.commandFailed(
                exitStatus: 1,
                message: "scripted readiness failed",
                standardError: redactionPolicy.redact(output)
            )
        case .availableEmpty, .observed, .logs:
            return RuntimeReadinessReport(
                runtimeName: adapterMetadata.runtimeName,
                cliVersion: adapterMetadata.runtimeVersion ?? "scripted-test-version",
                serviceState: .running,
                serviceVersion: adapterMetadata.runtimeVersion ?? "scripted-test-version",
                serviceBuild: "scripted-test-build"
            )
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
            throw RuntimeAdapterError.commandTimedOut(command: "scripted-runtime-observe", partialOutput: "", partialError: "")
        case .redactedFailure(let output):
            throw RuntimeAdapterError.commandFailed(exitStatus: 1, message: "scripted command failed", standardError: redactionPolicy.redact(output))
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
                    resourceIdentifier: service.identity.managedResourceIdentifier,
                    isDestructive: false,
                    summary: "Scripted plan would create \(service.identity.displayName)."
                )
            }

        return RuntimePlan(actions: actions)
    }

    public func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        throw RuntimeAdapterError.mutationUnavailableByPolicy("ScriptedRuntimeAdapter does not execute runtime mutation.")
    }

    public func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        switch scenario {
        case .logs(let text):
            return RuntimeLogResult(identity: service.identity, text: redactionPolicy.redact(text), lineLimit: min(max(1, tail), 1_000))
        case .unavailable(let message):
            throw RuntimeAdapterError.runtimeUnavailable(redactionPolicy.redact(message))
        default:
            throw RuntimeAdapterError.capabilityUnavailable(.logStreaming)
        }
    }
}

public struct ScriptedRuntimeProcessRunner: RuntimeProcessRunning {
    public enum Behavior: Sendable {
        case result(RuntimeCommandResult)
        case failure(RuntimeAdapterError)
    }

    public let behavior: Behavior
    public let redactionPolicy: RuntimeRedactionPolicy

    public init(behavior: Behavior, redactionPolicy: RuntimeRedactionPolicy = .default) {
        self.behavior = behavior
        self.redactionPolicy = redactionPolicy
    }

    public func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
        switch spec.classification {
        case .readOnly:
            try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
        case .mutating:
            try RuntimeCommandPolicy.validateSupportedMutation(spec)
        case .forbidden, .unknown:
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "ScriptedRuntimeProcessRunner rejects forbidden and unknown runtime command specs."
            )
        }

        switch behavior {
        case .result(let result):
            return result.redacted(using: redactionPolicy)
        case .failure(let error):
            throw error.redacted(using: redactionPolicy)
        }
    }
}

public struct DictionaryRuntimeExecutableResolver: RuntimeExecutableResolving {
    public let executables: [String: String]

    public init(executables: [String: String]) {
        self.executables = executables
    }

    public func resolveExecutable(named name: String) -> ResolvedRuntimeExecutable? {
        guard let path = executables[name] else {
            return nil
        }
        return ResolvedRuntimeExecutable(name: name, path: path)
    }
}

public struct InMemorySecretStore: SecretStore {
    private let values: [HostwrightSecretReference: String]

    public init(values: [HostwrightSecretReference: String]) {
        self.values = values
    }

    public init(rawValues: [String: String]) throws {
        var parsed: [HostwrightSecretReference: String] = [:]
        for (reference, value) in rawValues {
            parsed[try HostwrightSecretReference.parse(reference)] = value
        }
        values = parsed
    }

    public func readString(reference: HostwrightSecretReference) throws -> String {
        guard let value = values[reference] else {
            throw SecretStoreError.notFound("Secret value was not found for \(reference.redactedDescription).")
        }
        return value
    }
}
