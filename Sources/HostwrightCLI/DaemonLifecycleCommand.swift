import Foundation
import HostwrightCore
import HostwrightDaemonCore

struct DaemonLifecycleCommandRunner {
    let options: DaemonCLIOptions
    let controller: DaemonLifecycleController

    func run() throws -> CLIRunResult {
        do {
            let result: DaemonLifecycleResult
            switch options.action {
            case .status:
                let status = try controller.status()
                result = DaemonLifecycleResult(
                    operation: .status,
                    changed: false,
                    reasonCode: status.reasonCode,
                    status: status
                )
            case .lifecycle(let operation):
                result = try controller.perform(
                    operation,
                    daemonExecutablePath: options.daemonExecutablePath,
                    configPath: options.configPath
                )
            }
            if options.output == .json {
                return CLIRunResult(standardOutput: CLIJSON.codable(result))
            }
            return CLIRunResult(standardOutput: render(result))
        } catch let error as DaemonLifecycleError {
            throw HostwrightDiagnostic(
                code: diagnosticCode(for: error),
                message: error.description
            )
        }
    }

    private func diagnosticCode(
        for error: DaemonLifecycleError
    ) -> HostwrightErrorCode {
        switch error {
        case .invalidRequest, .notInstalled, .rollbackUnavailable:
            return .daemonInvalid
        case .unsafePath, .externalServiceConflict, .unmanagedDaemonProcess:
            return .daemonDenied
        case .processInventoryUnavailable, .commandFailed:
            return .daemonUnavailable
        case .conflict:
            return .daemonConflict
        case .recoveryRequired, .verificationFailed:
            return .daemonPartialEffect
        case .cancelled:
            return .daemonCancelled
        }
    }

    private func render(_ result: DaemonLifecycleResult) -> String {
        let status = result.status
        return """
        Hostwright daemon lifecycle v\(result.schemaVersion)
        Operation: \(displayOperation)
        Changed: \(result.changed ? "true" : "false")
        Reason: \(result.reasonCode.rawValue)
        Readiness: \(status.readiness.rawValue)
        Label: \(status.label)
        Domain: \(status.domain)
        Property list: \(status.propertyListPath)
        Executable: \(status.daemonExecutablePath ?? "none")
        Configuration: \(status.configPath ?? "none")
        Generation: \(status.generation.map(String.init) ?? "none")
        Installation ID: \(status.installationID ?? "none")
        Process: \(status.processID.map(String.init) ?? "none")
        Pending operation: \(status.pendingOperation?.rawValue ?? "none")

        """
    }

    private var displayOperation: String {
        switch options.action {
        case .status: "status"
        case .lifecycle(let operation): operation.rawValue
        }
    }
}
