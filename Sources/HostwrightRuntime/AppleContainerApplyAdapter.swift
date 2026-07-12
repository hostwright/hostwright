import Foundation
import HostwrightCore

public struct AppleContainerApplyAdapter: RuntimeAdapter {
    public let executableResolver: RuntimeExecutableResolving
    public let processRunner: RuntimeProcessRunning
    public let redactionPolicy: RuntimeRedactionPolicy
    private let readOnlyAdapter: AppleContainerReadOnlyAdapter

    public init(
        executableResolver: RuntimeExecutableResolving = RuntimeExecutableResolver(),
        processRunner: RuntimeProcessRunning = FoundationRuntimeProcessRunner(),
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.executableResolver = executableResolver
        self.processRunner = processRunner
        self.redactionPolicy = redactionPolicy
        self.readOnlyAdapter = AppleContainerReadOnlyAdapter(
            executableResolver: executableResolver,
            processRunner: processRunner,
            redactionPolicy: redactionPolicy
        )
    }

    public func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            adapterName: "AppleContainerApplyAdapter",
            adapterVersion: HostwrightIdentity.version,
            runtimeName: "Apple container CLI",
            runtimeVersion: nil,
            supportsMutation: true,
            capabilities: [.readOnlyObservation, .lifecycleMutation, .logStreaming, .cleanup]
        )
    }

    public func capabilities() async throws -> [RuntimeCapability] {
        guard executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) != nil else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }

        return [.readOnlyObservation, .lifecycleMutation, .logStreaming, .cleanup]
    }

    public func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        let observed = try await readOnlyAdapter.observe(desiredState: desiredState)
        return ObservedRuntimeState(
            projectName: observed.projectName,
            services: observed.services,
            adapterMetadata: await metadata()
        )
    }

    public func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
        RuntimePlan(
            actions: desiredState.services
                .filter { desired in !observedState.services.contains { $0.identity == desired.identity } }
                .sorted { $0.identity.displayName < $1.identity.displayName }
                .map { desired in
                    PlannedRuntimeAction(
                        kind: .create,
                        identity: desired.identity,
                        resourceIdentifier: desired.identity.managedResourceIdentifier,
                        isDestructive: false,
                        summary: "Create missing service \(desired.identity.displayName).",
                        desiredService: desired
                    )
                },
            warnings: []
        )
    }

    public func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        try await readOnlyAdapter.logs(for: service, tail: tail)
    }

    public func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        guard confirmation?.confirmed == true, confirmation?.planHash?.isEmpty == false else {
            throw RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: "Runtime mutation requires explicit plan-hash confirmation."
            )
        }

        guard let executable = executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }

        switch action.kind {
        case .create:
            return try await executeCreate(action, executable: executable)
        case .start:
            return try await executeStart(action, executable: executable)
        case .restart:
            return try await executeRestart(action, executable: executable)
        case .remove:
            return try await executeDelete(action, executable: executable)
        case .update, .stop, .noOp:
            throw RuntimeAdapterError.mutationUnavailableByPolicy("Runtime action '\(action.kind.rawValue)' is not available.")
        }
    }

    private func executeCreate(_ action: PlannedRuntimeAction, executable: ResolvedRuntimeExecutable) async throws -> RuntimeEvent {
        guard let desiredService = action.desiredService else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy("Create-missing-service requires desired runtime service details.")
        }
        guard action.identity == desiredService.identity,
              action.resourceIdentifier == desiredService.identity.managedResourceIdentifier else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Create-missing-service requires an action identity and exact versioned identifier bound to the desired service."
            )
        }
        try validateCreateSubset(desiredService)

        let imageListSpec = AppleContainerCommand.spec(kind: .listImages, executable: executable)
        let imageListResult = try await processRunner.run(imageListSpec)
        guard try AppleContainerImageListParser.contains(desiredService.image, in: imageListResult.standardOutput, redactionPolicy: redactionPolicy) else {
            throw RuntimeAdapterError.capabilityUnavailable(.lifecycleMutation)
        }

        let createSpec = AppleContainerCommand.spec(
            kind: .createContainer,
            executable: executable,
            desiredService: desiredService
        )
        try RuntimeCommandPolicy.validateCreateMissingServiceMutation(createSpec)
        let result = try await runRedacted(createSpec)
        let resourceIdentifier = AppleContainerCommand.containerName(for: desiredService.identity)

        return RuntimeEvent(
            identity: desiredService.identity,
            severity: .info,
            message: "Created missing service \(desiredService.identity.displayName). \(result.standardOutput)",
            resourceIdentifier: resourceIdentifier
        )
    }

    private func executeStart(_ action: PlannedRuntimeAction, executable: ResolvedRuntimeExecutable) async throws -> RuntimeEvent {
        let containerID = action.resourceIdentifier
        guard RuntimeManagedResourceIdentity.isSupportedIdentifier(containerID) else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy("Start-managed-service requires an exact supported Hostwright resource identifier.")
        }
        let spec = AppleContainerCommand.spec(kind: .startContainer(containerID: containerID), executable: executable)
        try RuntimeCommandPolicy.validateStartManagedServiceMutation(spec)
        let result = try await runRedacted(spec)
        return RuntimeEvent(
            identity: action.identity,
            severity: .info,
            message: "Started managed service \(action.identity.displayName). \(result.standardOutput)",
            resourceIdentifier: containerID
        )
    }

    private func executeRestart(_ action: PlannedRuntimeAction, executable: ResolvedRuntimeExecutable) async throws -> RuntimeEvent {
        guard action.isDestructive else {
            throw RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: "Restart-managed-service requires an explicitly destructive planned action."
            )
        }

        let containerID = action.resourceIdentifier
        guard RuntimeManagedResourceIdentity.isSupportedIdentifier(containerID) else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy("Restart-managed-service requires an exact supported Hostwright resource identifier.")
        }
        let stopSpec = AppleContainerCommand.spec(kind: .stopForManagedRestart(containerID: containerID), executable: executable)
        try RuntimeCommandPolicy.validateRestartManagedServiceMutation(stopSpec)
        let stopResult = try await runRedacted(stopSpec)

        let startSpec = AppleContainerCommand.spec(kind: .startForManagedRestart(containerID: containerID), executable: executable)
        let startResult: RuntimeCommandResult
        do {
            try RuntimeCommandPolicy.validateRestartManagedServiceMutation(startSpec)
            startResult = try await runRedacted(startSpec)
        } catch {
            throw managedRestartStartFailedAfterStop(error)
        }

        return RuntimeEvent(
            identity: action.identity,
            severity: .info,
            message: "Restarted managed service \(action.identity.displayName). stop: \(stopResult.standardOutput) start: \(startResult.standardOutput)",
            resourceIdentifier: containerID
        )
    }

    private func managedRestartStartFailedAfterStop(_ error: Error) -> RuntimeAdapterError {
        let redacted = redactionPolicy.redact(String(describing: error))
        if let runtimeError = error as? RuntimeAdapterError {
            switch runtimeError.redacted(using: redactionPolicy) {
            case .commandFailed(_, let message, let standardError):
                return .managedRestartStartFailedAfterStop(message: message, standardError: standardError)
            case .commandTimedOut(let command, let partialOutput, let partialError):
                return .managedRestartStartFailedAfterStop(
                    message: "Managed restart start timed out after stop succeeded: \(command) \(partialOutput)",
                    standardError: partialError
                )
            default:
                return .managedRestartStartFailedAfterStop(message: redactionPolicy.redact(String(describing: runtimeError)), standardError: "")
            }
        }
        return .managedRestartStartFailedAfterStop(message: redacted, standardError: "")
    }

    private func executeDelete(_ action: PlannedRuntimeAction, executable: ResolvedRuntimeExecutable) async throws -> RuntimeEvent {
        guard action.isDestructive else {
            throw RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: "Delete-managed-container requires an explicitly destructive planned action."
            )
        }
        let containerID = action.resourceIdentifier
        guard RuntimeManagedResourceIdentity.isSupportedIdentifier(containerID) else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy("Delete-managed-container requires an exact supported Hostwright resource identifier.")
        }
        let spec = AppleContainerCommand.spec(kind: .deleteContainer(containerID: containerID), executable: executable)
        try RuntimeCommandPolicy.validateDeleteManagedContainerMutation(spec)
        let result = try await runRedacted(spec)
        return RuntimeEvent(
            identity: action.identity,
            severity: .info,
            message: "Deleted managed container \(action.identity.displayName). \(result.standardOutput)",
            resourceIdentifier: containerID
        )
    }

    private func runRedacted(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
        do {
            return try await processRunner.run(spec).redacted(using: redactionPolicy)
        } catch let error as RuntimeAdapterError {
            throw error.redacted(using: redactionPolicy, exactValues: spec.sensitiveValues)
        }
    }

    private func validateCreateSubset(_ service: DesiredRuntimeService) throws {
        guard service.mounts.isEmpty else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Create-only apply rejects mounts.")
        }
        guard service.ports.allSatisfy({ ($0.hostPort ?? 0) >= 1_024 }) else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Create-only apply rejects privileged host ports.")
        }
        guard service.ports.allSatisfy({ $0.bindAddress != "0.0.0.0" && $0.bindAddress != "::" }) else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Create-only apply rejects broad bind addresses.")
        }
        guard !service.image.hasPrefix("-") else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Create-only apply rejects image values beginning with '-'.")
        }
        guard service.command.allSatisfy({ !$0.hasPrefix("-") }) else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Create-only apply rejects command tokens beginning with '-'.")
        }
        guard service.environment.allSatisfy({ $0.secretReference == nil }) else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Create-only apply rejects unresolved secret references.")
        }
    }
}

public enum AppleContainerImageListParser {
    public static func contains(_ image: String, in output: String, redactionPolicy: RuntimeRedactionPolicy = .default) throws -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        do {
            let object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
            guard let list = object as? [Any] else {
                throw RuntimeAdapterError.outputParseFailed("Apple container image list output was not a JSON array.")
            }

            if list.isEmpty {
                return false
            }

            if let strings = list as? [String] {
                return strings.contains(image)
            }

            for item in list {
                guard let object = item as? [String: Any],
                      let configuration = object["configuration"] as? [String: Any] else {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Unsupported Apple container image list item shape: \(redactionPolicy.redact(trimmed))"
                    )
                }

                let names = imageNames(in: configuration)
                guard !names.isEmpty else {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Apple container image list item did not include a supported image name: \(redactionPolicy.redact(trimmed))"
                    )
                }

                if names.contains(image) {
                    return true
                }
            }

            return false
        } catch let error as RuntimeAdapterError {
            throw error.redacted(using: redactionPolicy)
        } catch {
            throw RuntimeAdapterError.outputParseFailed(
                "Failed to parse Apple container image list output: \(redactionPolicy.redact(trimmed))"
            )
        }
    }

    private static func imageNames(in configuration: [String: Any]) -> Set<String> {
        var names = Set<String>()
        if let name = configuration["name"] as? String {
            names.insert(name)
        }
        if let descriptor = configuration["descriptor"] as? [String: Any],
           let annotations = descriptor["annotations"] as? [String: String] {
            for key in ["com.apple.containerization.image.name", "io.containerd.image.name", "org.opencontainers.image.ref.name"] {
                if let value = annotations[key] {
                    names.insert(value)
                }
            }
        }
        return names
    }
}
