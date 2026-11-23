#if HOSTWRIGHT_TEST_RUNTIME
import Foundation
import HostwrightDaemonCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime

actor HostwrightTestRecordingRuntime: RuntimeAdapter {
    struct Action: Encodable, Sendable {
        let kind: String
        let service: String
        let resource: String
    }

    static let providerID = RuntimeProviderID(rawValue: "hostwright-test-recording-v1")
    private(set) var actions: [Action] = []

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: Self.providerID,
            adapterName: "HostwrightTestRecordingRuntime",
            adapterVersion: "1",
            runtimeName: "recording rehearsal",
            supportsMutation: false,
            capabilities: [.readOnlyObservation]
        )
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation]
    }

    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        ObservedRuntimeState(projectName: desiredState.projectName, services: [], adapterMetadata: await metadata())
    }

    func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
        ReconciliationPlanner().plan(desired: desiredState, observed: observedState)
    }

    func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        throw RuntimeAdapterError.capabilityUnavailable(.logStreaming)
    }

    func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        actions.append(Action(
            kind: action.kind.rawValue,
            service: action.identity.serviceName,
            resource: action.resourceIdentifier
        ))
        return RuntimeEvent(identity: action.identity, message: "Recorded rehearsal action", resourceIdentifier: action.resourceIdentifier)
    }
}

enum HostwrightTestRuntimeCommand {
    private static let usage = "Usage: hostwrightd --test-runtime --foreground --config <hostwright.yaml>\n"

    private struct Report: Encodable {
        let provider: String
        let actions: [HostwrightTestRecordingRuntime.Action]
    }

    static func run(arguments: [String]) async -> DaemonProcessResult {
        if arguments == ["--help"] {
            return DaemonProcessResult(standardOutput: usage)
        }
        guard arguments.count == 3, arguments[0] == "--foreground", arguments[1] == "--config" else {
            return DaemonProcessResult(standardError: usage, exitCode: 64)
        }

        do {
            let url = URL(fileURLWithPath: arguments[2]).standardizedFileURL
            let source = try SecureDaemonConfigurationReader.read(path: url.path, kind: .manifest)
            let manifest = try ManifestValidator.validated(source.text)
            let mapping = ManifestRuntimeMapper.map(manifest, bindMountBaseDirectory: url.deletingLastPathComponent().path)
            if let blocker = mapping.issues.first(where: { $0.severity == .blocker }) {
                throw DaemonError.invalidConfiguration(blocker.message)
            }

            let runtime = HostwrightTestRecordingRuntime()
            let observed = try await runtime.observe(desiredState: mapping.desiredState)
            let plan = try await runtime.plan(desiredState: mapping.desiredState, observedState: observed)
            for action in plan.actions {
                _ = try await runtime.execute(action, confirmation: nil)
            }
            let report = await Report(provider: HostwrightTestRecordingRuntime.providerID.rawValue, actions: runtime.actions)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let output = try encoder.encode(report)
            return DaemonProcessResult(standardOutput: String(decoding: output, as: UTF8.self) + "\n")
        } catch {
            let message = RuntimeRedactionPolicy.default.redact(String(describing: error))
            return DaemonProcessResult(standardError: "\(message)\n", exitCode: 64)
        }
    }
}
#endif
