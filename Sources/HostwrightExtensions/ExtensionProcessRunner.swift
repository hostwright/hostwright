import Foundation
import HostwrightCore

struct ExtensionProcessOutcome: Sendable {
    let standardOutput: Data
    let standardError: Data
    let exitStatus: Int32
    let durationMilliseconds: Int
    let outputOverflowed: Bool
    let errorOverflowed: Bool
}

struct ExtensionHandshakeProcessRunner: Sendable {
    func run(
        executableURL: URL,
        request: Data,
        timeoutMilliseconds: Int,
        maximumOutputBytes: Int
    ) throws -> ExtensionProcessOutcome {
        guard executableURL.path.hasPrefix("/"),
              timeoutMilliseconds > 0,
              maximumOutputBytes > 0 else {
            throw executionFailed("The extension process configuration is invalid.")
        }

        let processRequest = SecureSubprocessRequest(
            executablePath: executableURL.path,
            arguments: ["hostwright-extension-handshake-v1"],
            environment: SecureSubprocessEnvironment.minimal,
            workingDirectory: "/",
            standardInput: request,
            timeoutMilliseconds: timeoutMilliseconds,
            maximumStandardOutputBytes: maximumOutputBytes,
            maximumStandardErrorBytes: maximumOutputBytes,
            maximumStandardInputBytes: max(1, request.count)
        )
        do {
            return outcome(try SecureSubprocessRunner().run(processRequest))
        } catch let error as SecureSubprocessError {
            switch error {
            case .timedOut:
                throw executionFailed("The reviewed-local extension handshake timed out.")
            case .cancelled:
                throw executionFailed("The reviewed-local extension handshake was cancelled.")
            case .outputLimitExceeded(let result):
                return outcome(result)
            case .descendantProcessDetected:
                throw executionFailed("The reviewed-local extension left an unexpected descendant process.")
            case .processTreeCleanupFailed:
                throw executionFailed("The reviewed-local extension process tree could not be cleaned up safely.")
            case .executableRejected:
                throw executionFailed("The staged extension executable failed secure identity validation.")
            case .workingDirectoryRejected, .invalidRequest:
                throw executionFailed("The reviewed-local extension process configuration failed secure validation.")
            case .inputWriteFailed:
                throw executionFailed("Could not send the bounded handshake request to the extension process.")
            case .outputReadFailed, .waitFailed, .spawnSetupFailed, .launchFailed, .executableChanged:
                throw executionFailed("The reviewed-local extension process failed at the secure execution boundary.")
            }
        }
    }

    private func outcome(_ result: SecureSubprocessResult) -> ExtensionProcessOutcome {
        ExtensionProcessOutcome(
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            exitStatus: result.exitStatus,
            durationMilliseconds: result.durationMilliseconds,
            outputOverflowed: result.standardOutputTruncated,
            errorOverflowed: result.standardErrorTruncated
        )
    }

    private func executionFailed(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionExecutionFailed, message: message)
    }
}
