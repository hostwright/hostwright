import Foundation
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore

public enum CLIControlResultContract {
    public static let schemaVersion = 1
    public static let maximumCombinedOutputBytes = 960 * 1_024

    public static func value(_ result: CLIRunResult) throws -> ControlPlaneJSONValue {
        try validate(result)
        return .object([
            "exitCode": .integer(Int64(result.exitCode)),
            "resultSchemaVersion": .integer(Int64(schemaVersion)),
            "standardError": .string(result.standardError),
            "standardOutput": .string(result.standardOutput),
        ])
    }

    public static func result(from response: ControlResponseEnvelope) throws -> CLIRunResult {
        let validStatus = (response.status == .completed
            && response.reasonCode == .completed
            && response.error == nil)
            || (response.status == .error
                && response.reasonCode == .internalError
                && response.error?.code == "cliExitNonZero")
        guard validStatus,
              case .object(let fields)? = response.result,
              Set(fields.keys) == [
                "exitCode", "resultSchemaVersion", "standardError", "standardOutput",
              ],
              case .integer(Int64(schemaVersion))? = fields["resultSchemaVersion"],
              case .integer(let rawExitCode)? = fields["exitCode"],
              Int64(Int32.min)...Int64(Int32.max) ~= rawExitCode,
              case .string(let standardOutput)? = fields["standardOutput"],
              case .string(let standardError)? = fields["standardError"] else {
            throw HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message: "The daemon returned an invalid CLI result envelope."
            )
        }
        let result = CLIRunResult(
            standardOutput: standardOutput,
            standardError: standardError,
            exitCode: Int32(rawExitCode)
        )
        try validate(result)
        guard (response.status == .completed && result.exitCode == 0)
            || (response.status == .error && result.exitCode != 0) else {
            throw HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message: "The CLI result status does not match its exit code."
            )
        }
        return result
    }

    private static func validate(_ result: CLIRunResult) throws {
        guard result.standardOutput.utf8.count + result.standardError.utf8.count
                <= maximumCombinedOutputBytes else {
            throw HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message: "The delegated CLI output exceeded the bounded Control API response limit."
            )
        }
    }
}
