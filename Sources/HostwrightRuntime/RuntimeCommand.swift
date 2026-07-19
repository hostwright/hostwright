public enum RuntimeCommandClassification: String, Equatable, Sendable {
    case readOnly
    case mutating
    case forbidden
    case unknown
}

public enum RuntimeExecutableResolution: String, Equatable, Sendable {
    case unresolved
    case resolvedByRuntimeExecutableResolver
}

public enum RuntimeMutationCommandKind: String, Equatable, Sendable {
    case createMissingService
    case startManagedService
    case restartManagedService
    case deleteManagedContainer
}

public enum RuntimeCommandExitStatusPolicy: Equatable, Sendable {
    case zeroOnly
    case appleContainerSystemStatus

    public func accepts(_ exitStatus: Int32) -> Bool {
        switch self {
        case .zeroOnly:
            return exitStatus == 0
        case .appleContainerSystemStatus:
            return exitStatus == 0 || exitStatus == 1
        }
    }
}

public struct RuntimeCommandTimeout: Equatable, Sendable {
    public static let defaultSeconds = 30
    public static let maximumSeconds = 300

    public let seconds: Int

    public init(seconds: Int = RuntimeCommandTimeout.defaultSeconds) {
        self.seconds = min(max(1, seconds), RuntimeCommandTimeout.maximumSeconds)
    }
}

public struct RuntimeCommandSpec: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let sensitiveValues: [String]
    public let workingDirectory: String?
    public let timeout: RuntimeCommandTimeout
    public let classification: RuntimeCommandClassification
    public let executableResolution: RuntimeExecutableResolution
    public let mutationKind: RuntimeMutationCommandKind?
    public let exitStatusPolicy: RuntimeCommandExitStatusPolicy
    public let purpose: String

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = [:],
        sensitiveValues: [String] = [],
        workingDirectory: String? = nil,
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout(),
        classification: RuntimeCommandClassification,
        executableResolution: RuntimeExecutableResolution = .unresolved,
        mutationKind: RuntimeMutationCommandKind? = nil,
        exitStatusPolicy: RuntimeCommandExitStatusPolicy = .zeroOnly,
        purpose: String
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.sensitiveValues = sensitiveValues.filter { !$0.isEmpty }
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.classification = classification
        self.executableResolution = executableResolution
        self.mutationKind = mutationKind
        self.exitStatusPolicy = exitStatusPolicy
        self.purpose = purpose
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> RuntimeCommandSpec {
        RuntimeCommandSpec(
            executablePath: executablePath,
            arguments: policy.redact(arguments: arguments, exactValues: sensitiveValues),
            environment: policy.redact(environment: environment, exactValues: sensitiveValues),
            sensitiveValues: [],
            workingDirectory: workingDirectory,
            timeout: timeout,
            classification: classification,
            executableResolution: executableResolution,
            mutationKind: mutationKind,
            exitStatusPolicy: exitStatusPolicy,
            purpose: purpose
        )
    }
}

public struct RuntimeCommandResult: Equatable, Sendable {
    public let spec: RuntimeCommandSpec
    public let exitStatus: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool
    public let wasCancelled: Bool

    public init(
        spec: RuntimeCommandSpec,
        exitStatus: Int32,
        standardOutput: String,
        standardError: String,
        timedOut: Bool = false,
        wasCancelled: Bool = false
    ) {
        self.spec = spec
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
        self.wasCancelled = wasCancelled
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> RuntimeCommandResult {
        let exactValues = spec.sensitiveValues
        return RuntimeCommandResult(
            spec: spec.redacted(using: policy),
            exitStatus: exitStatus,
            standardOutput: policy.redact(standardOutput, exactValues: exactValues),
            standardError: policy.redact(standardError, exactValues: exactValues),
            timedOut: timedOut,
            wasCancelled: wasCancelled
        )
    }
}

public enum RuntimeCommandPolicy {
    public static func validateReadOnlyCommandClassification(_ spec: RuntimeCommandSpec) throws {
        try rejectNonReadOnlyCommand(spec)
    }

    public static func validateReadOnlyExecution(_ spec: RuntimeCommandSpec) throws {
        try rejectNonReadOnlyCommand(spec)

        guard spec.executableResolution == .resolvedByRuntimeExecutableResolver else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Read-only runtime execution refuses command specs whose executable was not resolved through RuntimeExecutableResolver."
            )
        }
        try validateReadOnlyExitStatusPolicy(spec)
    }

    public static func validateExactResourceStats(_ spec: RuntimeCommandSpec, resourceIdentifier: String) throws {
        try validateReadOnlyExecution(spec)
        guard RuntimeManagedResourceIdentity.isCurrentIdentifier(resourceIdentifier),
              spec.arguments == ["stats", resourceIdentifier, "--no-stream", "--format", "json"] else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Resource stats require one exact versioned Hostwright identifier and one non-streaming JSON sample."
            )
        }
    }

    public static func validateCreateMissingServiceMutation(_ spec: RuntimeCommandSpec) throws {
        guard spec.executableResolution == .resolvedByRuntimeExecutableResolver else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Create-missing-service mutation refuses runtime command specs whose executable was not resolved through RuntimeExecutableResolver."
            )
        }

        guard spec.classification == .mutating else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Create-missing-service mutation accepts only explicitly classified mutating specs."
            )
        }

        guard spec.exitStatusPolicy == .zeroOnly else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Runtime mutations require a zero-only exit-status policy."
            )
        }

        guard spec.mutationKind == .createMissingService else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Create-missing-service mutation policy accepts only createMissingService."
            )
        }

        guard spec.arguments.first == "create" else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Create-missing-service mutation policy accepts only create command specs."
            )
        }

        let nameIndices = spec.arguments.indices.filter { spec.arguments[$0] == "--name" }
        guard nameIndices.count == 1,
              let nameIndex = nameIndices.first,
              spec.arguments.indices.contains(spec.arguments.index(after: nameIndex)) else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Create-missing-service command specs must contain exactly one Hostwright-owned container name."
            )
        }
        let resourceIdentifier = spec.arguments[spec.arguments.index(after: nameIndex)]
        guard RuntimeManagedResourceIdentity.isCurrentIdentifier(resourceIdentifier) else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Create-missing-service command specs require a versioned Hostwright container identifier."
            )
        }

        let labels = try createLabels(in: spec)
        guard let identity = RuntimeManagedResourceIdentity.identity(from: labels),
              RuntimeManagedResourceIdentity.labelsMatch(
                  labels,
                  identity: identity,
                  resourceIdentifier: resourceIdentifier
              ),
              let providerValue = labels[RuntimeManagedResourceIdentity.providerIDLabel],
              let providerID = RuntimeProviderID.knownValues.first(where: {
                  $0.rawValue == providerValue
              }) else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Create-missing-service command specs require complete ownership labels bound to the exact container identifier."
            )
        }
        let ownership: RuntimeInventoryOwnershipEvidence?
        do {
            ownership = try RuntimeManagedResourceIdentity.ownershipEvidence(
                from: labels,
                expectedProviderID: providerID
            )
        } catch {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Create-missing-service command specs require complete ownership labels bound to the exact container identifier."
            )
        }
        let ownershipKeys: Set<String> = [
            RuntimeManagedResourceIdentity.resourceUUIDLabel,
            RuntimeManagedResourceIdentity.projectUUIDLabel,
            RuntimeManagedResourceIdentity.resourceGenerationLabel,
            RuntimeManagedResourceIdentity.projectGenerationLabel,
            RuntimeManagedResourceIdentity.providerIDLabel,
            RuntimeManagedResourceIdentity.providerGenerationLabel,
            RuntimeManagedResourceIdentity.fencingTokenLabel
        ]
        let expectedKeys = Set(RuntimeManagedResourceIdentity.labels(for: identity).keys)
            .union(ownershipKeys)
        guard ownership != nil, Set(labels.keys) == expectedKeys else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Create-missing-service command specs require complete ownership labels bound to the exact container identifier."
            )
        }

        let rejectedCreateFlags = [
            "--rm",
            "--mount",
            "--volume",
            "--network",
            "--dns",
            "--privileged",
            "--cap-add",
            "--cap-drop"
        ]
        if spec.arguments.contains(where: { rejectedCreateFlags.contains($0) }) {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Create-missing-service command spec contains an unsupported create option."
            )
        }

        try validateCreateImageAndCommandTokens(spec)
    }

    public static func validateSupportedMutation(_ spec: RuntimeCommandSpec) throws {
        switch spec.mutationKind {
        case .createMissingService:
            try validateCreateMissingServiceMutation(spec)
        case .startManagedService:
            try validateStartManagedServiceMutation(spec)
        case .restartManagedService:
            try validateRestartManagedServiceMutation(spec)
        case .deleteManagedContainer:
            try validateDeleteManagedContainerMutation(spec)
        case nil:
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Runtime mutation command specs must declare a supported mutation kind."
            )
        }
    }

    public static func validateStartManagedServiceMutation(_ spec: RuntimeCommandSpec) throws {
        try validateResolvedMutatingSpec(spec, expectedKind: .startManagedService, commandName: "start-managed-service")

        guard spec.arguments.count == 2, spec.arguments.first == "start" else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Start-managed-service mutation accepts only 'start <hostwright-container-id>'."
            )
        }

        guard RuntimeManagedResourceIdentity.isSupportedIdentifier(spec.arguments[1]) else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Start-managed-service mutation requires an exact Hostwright-owned container identifier."
            )
        }
    }

    public static func validateRestartManagedServiceMutation(_ spec: RuntimeCommandSpec) throws {
        try validateResolvedMutatingSpecWithoutLifecycleVerbBlock(spec, expectedKind: .restartManagedService, commandName: "restart-managed-service")

        guard spec.arguments.count == 2,
              (spec.arguments.first == "stop" || spec.arguments.first == "start") else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Restart-managed-service mutation accepts only internal 'stop <hostwright-container-id>' or 'start <hostwright-container-id>' steps."
            )
        }

        guard RuntimeManagedResourceIdentity.isSupportedIdentifier(spec.arguments[1]) else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Restart-managed-service mutation requires an exact Hostwright-owned container identifier."
            )
        }
    }

    public static func validateDeleteManagedContainerMutation(_ spec: RuntimeCommandSpec) throws {
        try validateResolvedMutatingSpec(spec, expectedKind: .deleteManagedContainer, commandName: "delete-managed-container")

        guard spec.arguments.count == 2, spec.arguments.first == "delete" else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Delete-managed-container mutation accepts only 'delete <hostwright-container-id>'."
            )
        }

        guard RuntimeManagedResourceIdentity.isSupportedIdentifier(spec.arguments[1]) else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Delete-managed-container mutation requires an exact Hostwright-owned container identifier."
            )
        }
    }

    private static func rejectNonReadOnlyCommand(_ spec: RuntimeCommandSpec) throws {
        switch spec.classification {
        case .readOnly:
            return
        case .mutating, .forbidden, .unknown:
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Read-only runtime execution rejects mutating, forbidden, and unknown command specs."
            )
        }
    }

    private static func validateReadOnlyExitStatusPolicy(_ spec: RuntimeCommandSpec) throws {
        switch spec.exitStatusPolicy {
        case .zeroOnly:
            return
        case .appleContainerSystemStatus:
            guard spec.mutationKind == nil,
                  spec.arguments == ["system", "status", "--format", "json"] else {
                throw RuntimeAdapterError.commandRejected(
                    classification: spec.classification,
                    message: "The Apple system-status exit policy accepts only the exact read-only JSON status command."
                )
            }
        }
    }

    private static func validateResolvedMutatingSpec(
        _ spec: RuntimeCommandSpec,
        expectedKind: RuntimeMutationCommandKind,
        commandName: String
    ) throws {
        try validateResolvedMutatingSpecWithoutLifecycleVerbBlock(spec, expectedKind: expectedKind, commandName: commandName)

        let forbiddenArguments = [
            "--all",
            "--force",
            "--attach",
            "--interactive",
            "stop",
            "restart",
            "remove",
            "prune",
            "pull",
            "push",
            "build",
            "exec",
            "run"
        ]
        if spec.arguments.contains(where: { forbiddenArguments.contains($0) }) {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "\(commandName) mutation command spec contains a forbidden argument."
            )
        }
    }

    private static func validateResolvedMutatingSpecWithoutLifecycleVerbBlock(
        _ spec: RuntimeCommandSpec,
        expectedKind: RuntimeMutationCommandKind,
        commandName: String
    ) throws {
        guard spec.executableResolution == .resolvedByRuntimeExecutableResolver else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "\(commandName) mutation refuses command specs whose executable was not resolved through RuntimeExecutableResolver."
            )
        }

        guard spec.classification == .mutating else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "\(commandName) mutation accepts only explicitly classified mutating specs."
            )
        }

        guard spec.exitStatusPolicy == .zeroOnly else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Runtime mutations require a zero-only exit-status policy."
            )
        }

        guard spec.mutationKind == expectedKind else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "\(commandName) mutation policy received unsupported mutation kind."
            )
        }

        let forbiddenArguments = [
            "--all",
            "--force",
            "--attach",
            "--interactive",
            "restart",
            "remove",
            "prune",
            "pull",
            "push",
            "build",
            "exec",
            "run"
        ]
        if spec.arguments.contains(where: { forbiddenArguments.contains($0) }) {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "\(commandName) mutation command spec contains a forbidden argument."
            )
        }
    }

    private static func validateCreateImageAndCommandTokens(_ spec: RuntimeCommandSpec) throws {
        var index = 1
        while index < spec.arguments.count {
            let argument = spec.arguments[index]
            switch argument {
            case "--name", "--label", "--env", "--publish":
                let valueIndex = index + 1
                guard valueIndex < spec.arguments.count else {
                    throw RuntimeAdapterError.commandRejected(
                        classification: spec.classification,
                        message: "Create-missing-service command spec is missing a value for \(argument)."
                    )
                }
                index += 2
            default:
                guard !argument.hasPrefix("-") else {
                    throw RuntimeAdapterError.commandRejected(
                        classification: spec.classification,
                        message: "Create-missing-service image must not begin with '-'."
                    )
                }

                for token in spec.arguments.dropFirst(index + 1) where token.hasPrefix("-") {
                    throw RuntimeAdapterError.commandRejected(
                        classification: spec.classification,
                        message: "Create-missing-service command tokens beginning with '-' are not supported in this apply scope."
                    )
                }
                return
            }
        }

        throw RuntimeAdapterError.commandRejected(
            classification: spec.classification,
            message: "Create-missing-service command spec must include an image."
        )
    }

    private static func createLabels(in spec: RuntimeCommandSpec) throws -> [String: String] {
        var labels: [String: String] = [:]
        var index = 1
        while index < spec.arguments.count {
            let argument = spec.arguments[index]
            guard ["--name", "--label", "--env", "--publish"].contains(argument) else {
                break
            }
            let valueIndex = index + 1
            guard valueIndex < spec.arguments.count else {
                throw RuntimeAdapterError.commandRejected(
                    classification: spec.classification,
                    message: "Create-missing-service command spec is missing a value for \(argument)."
                )
            }
            if argument == "--label" {
                let pair = spec.arguments[valueIndex].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, !pair[0].isEmpty, labels[String(pair[0])] == nil else {
                    throw RuntimeAdapterError.commandRejected(
                        classification: spec.classification,
                        message: "Create-missing-service command spec contains an invalid or duplicate ownership label."
                    )
                }
                labels[String(pair[0])] = String(pair[1])
            }
            index += 2
        }
        return labels
    }
}

public protocol RuntimeProcessRunning: Sendable {
    func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult
}
