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
                message: "Create-only apply requires explicit plan-hash confirmation."
            )
        }
        guard action.kind == .create, let desiredService = action.desiredService else {
            throw RuntimeAdapterError.mutationUnavailableInCurrentPhase("Create-only apply executes only createMissingService runtime actions.")
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
        try RuntimeCommandPolicy.validateCreateMissingServiceMutation(createSpec)
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
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Create-only apply rejects mounts.")
        }
        guard service.environment.allSatisfy({ !$0.isSensitive && $0.value != redactionPolicy.replacement }) else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Create-only apply rejects sensitive environment values.")
        }
        guard service.ports.allSatisfy({ ($0.hostPort ?? 0) >= 1_024 }) else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Create-only apply rejects privileged host ports.")
        }
        guard service.ports.allSatisfy({ $0.bindAddress != "0.0.0.0" && $0.bindAddress != "::" }) else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "Create-only apply rejects broad bind addresses.")
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
