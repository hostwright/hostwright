import Foundation
import HostwrightCore

public struct SecureRuntimeProcessRunner: RuntimeProcessRunning {
    public let redactionPolicy: RuntimeRedactionPolicy

    public init(redactionPolicy: RuntimeRedactionPolicy = .default) {
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
                message: "Runtime process runner rejects forbidden and unknown command specs."
            )
        }

        var environment = SecureSubprocessEnvironment.currentUser
        for (name, value) in spec.environment {
            if let requiredValue = environment[name], requiredValue != value {
                throw RuntimeAdapterError.commandRejected(
                    classification: spec.classification,
                    message: "Runtime command environment cannot override the secure process baseline."
                )
            }
            environment[name] = value
        }

        let request = SecureSubprocessRequest(
            executablePath: spec.executablePath,
            arguments: spec.arguments,
            environment: environment,
            workingDirectory: spec.workingDirectory ?? "/",
            timeoutMilliseconds: spec.timeout.seconds * 1_000,
            maximumStandardOutputBytes: 16 * 1_024 * 1_024,
            maximumStandardErrorBytes: 16 * 1_024 * 1_024
        )

        let secureResult: SecureSubprocessResult
        do {
            secureResult = try await SecureSubprocessRunner().runAsync(request)
        } catch let error as SecureSubprocessError {
            throw normalize(error, spec: spec)
        } catch {
            throw RuntimeAdapterError.commandFailed(
                exitStatus: -1,
                message: "Runtime command failed at the bounded process boundary.",
                standardError: ""
            )
        }

        guard let standardOutput = String(data: secureResult.standardOutput, encoding: .utf8),
              let standardError = String(data: secureResult.standardError, encoding: .utf8) else {
            throw RuntimeAdapterError.outputParseFailed(
                "Runtime command output was not valid UTF-8."
            )
        }
        let result = RuntimeCommandResult(
            spec: spec,
            exitStatus: secureResult.exitStatus,
            standardOutput: standardOutput,
            standardError: standardError
        ).redacted(using: redactionPolicy)

        guard result.exitStatus == 0 else {
            throw RuntimeAdapterError.commandFailed(
                exitStatus: result.exitStatus,
                message: "\(spec.classification.rawValue) runtime command failed.",
                standardError: result.standardError
            )
        }
        return result
    }

    private func normalize(
        _ error: SecureSubprocessError,
        spec: RuntimeCommandSpec
    ) -> RuntimeAdapterError {
        let command = redactionPolicy.redact(spec.purpose, exactValues: spec.sensitiveValues)
        switch error {
        case .invalidRequest:
            return .commandRejected(
                classification: spec.classification,
                message: "Runtime command did not satisfy the bounded process contract."
            )
        case .executableRejected(let validationError):
            if validationError == .pathDoesNotExist || validationError == .notExecutable {
                return .executableNotFound(spec.executablePath).redacted(
                    using: redactionPolicy,
                    exactValues: spec.sensitiveValues
                )
            }
            return .permissionDenied("Runtime executable failed secure identity validation.")
        case .workingDirectoryRejected:
            return .commandRejected(
                classification: spec.classification,
                message: "Runtime command working directory failed secure validation."
            )
        case .timedOut(let result):
            let partial = redactedOutput(result, spec: spec)
            return .commandTimedOut(command: command, partialOutput: partial.output, partialError: partial.error)
        case .cancelled(let result):
            let partial = redactedOutput(result, spec: spec)
            return .commandCancelled(command: command, partialOutput: partial.output, partialError: partial.error)
        case .outputLimitExceeded(let result):
            let partial = redactedOutput(result, spec: spec)
            return .commandOutputLimitExceeded(command: command, partialOutput: partial.output, partialError: partial.error)
        case .descendantProcessDetected(let result), .processTreeCleanupFailed(let result):
            let partial = redactedOutput(result, spec: spec)
            return .commandProcessTreeViolation(command: command, partialOutput: partial.output, partialError: partial.error)
        case .inputWriteFailed(let result),
             .outputReadFailed(let result),
             .waitFailed(let result):
            let partial = redactedOutput(result, spec: spec)
            return .commandFailed(
                exitStatus: result.exitStatus,
                message: "Runtime command failed at the bounded process I/O boundary.",
                standardError: partial.error
            )
        case .spawnSetupFailed, .launchFailed, .executableChanged:
            return .commandFailed(
                exitStatus: -1,
                message: "Runtime command could not cross the secure launch boundary.",
                standardError: ""
            )
        }
    }

    private func redactedOutput(
        _ result: SecureSubprocessResult,
        spec: RuntimeCommandSpec
    ) -> (output: String, error: String) {
        (
            redactionPolicy.redact(
                String(decoding: result.standardOutput, as: UTF8.self),
                exactValues: spec.sensitiveValues
            ),
            redactionPolicy.redact(
                String(decoding: result.standardError, as: UTF8.self),
                exactValues: spec.sensitiveValues
            )
        )
    }
}
