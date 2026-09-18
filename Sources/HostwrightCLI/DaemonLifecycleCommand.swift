import Foundation
import HostwrightCore
import HostwrightDaemonCore

struct DaemonLifecycleCommandRunner {
    let options: DaemonCLIOptions
    let controller: DaemonLifecycleController
    var controlIdentityBootstrap: (Bool) throws -> Void = { _ in }
    var controlIdentityPathValidation: () throws -> Void = {
        try HostwrightControlIdentityBootstrap.validateManagedPaths()
    }

    func run() throws -> CLIRunResult {
        do {
            let result: DaemonLifecycleResult
            switch options.action {
            case .bootstrapIdentities:
                try controlIdentityBootstrap(false)
                return CLIRunResult(standardOutput: options.output == .json
                    ? CLIJSON.codable(IdentityBootstrapResult())
                    : "Control identities are ready for the selected local state.\n")
            case .status:
                let status = try controller.status()
                result = DaemonLifecycleResult(
                    operation: .status,
                    changed: false,
                    reasonCode: status.reasonCode,
                    status: status
                )
            case .lifecycle(let operation):
                let refreshIdentity = [.install, .upgrade, .repair].contains(operation)
                if refreshIdentity { try controlIdentityPathValidation() }
                result = try controller.perform(
                    operation,
                    daemonExecutablePath: options.daemonExecutablePath,
                    configPath: options.configPath,
                    verifiedTransition: refreshIdentity ? { _ in
                        try controlIdentityBootstrap(true)
                    } : nil
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
        case .bootstrapIdentities: "bootstrap-identities"
        case .status: "status"
        case .lifecycle(let operation): operation.rawValue
        }
    }
}

private struct IdentityBootstrapResult: Encodable {
    let schemaVersion = 1
    let operation = "daemon.bootstrap-identities"
    let status = "succeeded"
}
