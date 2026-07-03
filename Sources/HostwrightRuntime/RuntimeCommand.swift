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
    public let workingDirectory: String?
    public let timeout: RuntimeCommandTimeout
    public let classification: RuntimeCommandClassification
    public let executableResolution: RuntimeExecutableResolution
    public let mutationKind: RuntimeMutationCommandKind?
    public let purpose: String

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout(),
        classification: RuntimeCommandClassification,
        executableResolution: RuntimeExecutableResolution = .unresolved,
        mutationKind: RuntimeMutationCommandKind? = nil,
        purpose: String
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.classification = classification
        self.executableResolution = executableResolution
        self.mutationKind = mutationKind
        self.purpose = purpose
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> RuntimeCommandSpec {
        RuntimeCommandSpec(
            executablePath: executablePath,
            arguments: policy.redact(arguments: arguments),
            environment: policy.redact(environment: environment),
            workingDirectory: workingDirectory,
            timeout: timeout,
            classification: classification,
            executableResolution: executableResolution,
            mutationKind: mutationKind,
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
        RuntimeCommandResult(
            spec: spec.redacted(using: policy),
            exitStatus: exitStatus,
            standardOutput: policy.redact(standardOutput),
            standardError: policy.redact(standardError),
            timedOut: timedOut,
            wasCancelled: wasCancelled
        )
    }
}

public enum RuntimeCommandPolicy {
    public static func validatePhase4(_ spec: RuntimeCommandSpec) throws {
        try validateReadOnlyClassification(spec, phaseName: "Phase 4")
    }

    public static func validateReadOnlyExecution(_ spec: RuntimeCommandSpec, phaseName: String = "Phase 5") throws {
        try validateReadOnlyClassification(spec, phaseName: phaseName)

        guard spec.executableResolution == .resolvedByRuntimeExecutableResolver else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "\(phaseName) refuses runtime command specs whose executable was not resolved through RuntimeExecutableResolver."
            )
        }
    }

    public static func validatePhase8BMutation(_ spec: RuntimeCommandSpec) throws {
        guard spec.executableResolution == .resolvedByRuntimeExecutableResolver else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Phase 8B refuses runtime command specs whose executable was not resolved through RuntimeExecutableResolver."
            )
        }

        guard spec.classification == .mutating else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Phase 8B executes only explicitly classified mutating createMissingService specs."
            )
        }

        guard spec.mutationKind == .createMissingService else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Phase 8B mutation policy accepts only createMissingService."
            )
        }

        guard spec.arguments.first == "create" else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Phase 8B mutation policy accepts only create command specs."
            )
        }

        guard let nameIndex = spec.arguments.firstIndex(of: "--name"),
              spec.arguments.indices.contains(spec.arguments.index(after: nameIndex)),
              spec.arguments[spec.arguments.index(after: nameIndex)].hasPrefix("hostwright-") else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Phase 8B create command specs must name a Hostwright-owned container."
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
                message: "Phase 8B create command spec contains an unsupported create option."
            )
        }
    }

    private static func validateReadOnlyClassification(_ spec: RuntimeCommandSpec, phaseName: String) throws {
        switch spec.classification {
        case .readOnly:
            return
        case .mutating, .forbidden, .unknown:
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "\(phaseName) does not execute mutating, forbidden, or unknown runtime command specs."
            )
        }
    }
}

public protocol RuntimeProcessRunning: Sendable {
    func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult
}

public struct FakeRuntimeProcessRunner: RuntimeProcessRunning {
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
        try validate(spec)

        switch behavior {
        case .result(let result):
            return result.redacted(using: redactionPolicy)
        case .failure(let error):
            throw error.redacted(using: redactionPolicy)
        }
    }

    private func validate(_ spec: RuntimeCommandSpec) throws {
        switch spec.classification {
        case .readOnly:
            try RuntimeCommandPolicy.validateReadOnlyExecution(spec, phaseName: "Phase 5")
        case .mutating:
            try RuntimeCommandPolicy.validatePhase8BMutation(spec)
        case .forbidden, .unknown:
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "FakeRuntimeProcessRunner rejects forbidden and unknown runtime command specs."
            )
        }
    }
}
