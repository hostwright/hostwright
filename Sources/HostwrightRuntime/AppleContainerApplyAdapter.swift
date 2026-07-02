import Foundation

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
            adapterVersion: "0.0.0-dev",
            runtimeName: "Apple container CLI",
            runtimeVersion: nil,
            supportsMutation: true,
            capabilities: [.readOnlyObservation, .lifecycleMutation]
        )
    }

    public func capabilities() async throws -> [RuntimeCapability] {
        guard executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) != nil else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }

        return [.readOnlyObservation, .lifecycleMutation]
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
                        isDestructive: false,
                        summary: "Create missing service \(desired.identity.displayName).",
                        desiredService: desired
                    )
                },
            warnings: []
        )
    }

    public func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        guard confirmation?.confirmed == true, confirmation?.planHash?.isEmpty == false else {
            throw RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: "Phase 8B create requires explicit plan-hash confirmation."
            )
        }
        guard action.kind == .create, let desiredService = action.desiredService else {
            throw RuntimeAdapterError.mutationUnavailableInCurrentPhase("Phase 8B executes only createMissingService runtime actions.")
        }
        try validateCreateSubset(desiredService)

        guard let executable = executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }

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
        try RuntimeCommandPolicy.validatePhase8BMutation(createSpec)
        let result = try await processRunner.run(createSpec)
        let resourceIdentifier = AppleContainerCommand.containerName(for: desiredService.identity)

        return RuntimeEvent(
            identity: desiredService.identity,
            severity: .info,
            message: "Created missing service \(desiredService.identity.displayName). \(redactionPolicy.redact(result.standardOutput))",
            resourceIdentifier: resourceIdentifier
        )
    }

    private func validateCreateSubset(_ service: DesiredRuntimeService) throws {
        guard service.mounts.isEmpty else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Phase 8B create rejects mounts.")
        }
        guard service.environment.allSatisfy({ !$0.isSensitive && $0.value != redactionPolicy.replacement }) else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Phase 8B create rejects sensitive environment values.")
        }
        guard service.ports.allSatisfy({ ($0.hostPort ?? 0) >= 1_024 }) else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Phase 8B create rejects privileged host ports.")
        }
        guard service.ports.allSatisfy({ $0.bindAddress != "0.0.0.0" && $0.bindAddress != "::" }) else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Phase 8B create rejects broad bind addresses.")
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

            throw RuntimeAdapterError.outputParseFailed(
                "Non-empty real Apple container image list output is not supported yet: \(redactionPolicy.redact(trimmed))"
            )
        } catch let error as RuntimeAdapterError {
            throw error.redacted(using: redactionPolicy)
        } catch {
            throw RuntimeAdapterError.outputParseFailed(
                "Failed to parse Apple container image list output: \(redactionPolicy.redact(trimmed))"
            )
        }
    }
}
