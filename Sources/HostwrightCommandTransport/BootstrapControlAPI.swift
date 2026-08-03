import Foundation
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore

public enum BootstrapControlAPI {
    public static func run(requestData: Data) -> Data {
        run(requestData: requestData, environment: .live)
    }

    static func run(requestData: Data, environment: CLIEnvironment) -> Data {
        var requestID = "bootstrap-invalid"
        do {
            guard !requestData.isEmpty,
                  requestData.count <= ControlPlaneContract.maximumRequestBytes else {
                throw HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message: "The Bootstrap API request must be non-empty and no larger than 64 KiB."
                )
            }
            let request = try Phase09StrictDecoder.decode(
                ControlRequestEnvelope.self,
                from: requestData,
                allowedKeys: [
                    "apiVersion", "protocolRevision", "requestID", "operation",
                    "timeoutMilliseconds", "idempotencyKey", "body",
                ],
                requiredKeys: [
                    "apiVersion", "protocolRevision", "requestID", "operation",
                    "timeoutMilliseconds",
                ]
            )
            try request.validate()
            requestID = request.requestID
            guard let route = try CLIControlRoute.validate(
                request: request,
                expectedTransport: .bootstrapAPI
            ) else {
                throw HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message: "The Bootstrap API requires one classified daemon command."
                )
            }
            let commandEnvironment = try environment.resolvingRelativePaths(
                against: route.workingDirectory
            )
            let result = HostwrightCLI.run(
                arguments: route.arguments,
                environment: commandEnvironment
            )
            return try ControlPlaneCanonicalJSON.encode(
                ControlResponseEnvelope(
                    requestID: request.requestID,
                    status: result.exitCode == 0 ? .completed : .error,
                    reasonCode: result.exitCode == 0 ? .completed : .internalError,
                    result: try CLIControlResultContract.value(result),
                    error: result.exitCode == 0 ? nil : SanitizedError(
                        code: "cliExitNonZero",
                        message: "The Bootstrap API command returned a non-zero exit status."
                    )
                )
            )
        } catch let diagnostic as HostwrightDiagnostic {
            return failure(requestID: requestID, diagnostic: diagnostic)
        } catch {
            return failure(
                requestID: requestID,
                diagnostic: HostwrightDiagnostic(
                    code: .controlAPIExecutionFailed,
                    message: "The Bootstrap API request did not complete safely."
                )
            )
        }
    }

    private static func failure(
        requestID: String,
        diagnostic: HostwrightDiagnostic
    ) -> Data {
        let response = ControlResponseEnvelope(
            requestID: requestID,
            status: diagnostic.code == .controlAPIInvalid ? .rejected : .error,
            reasonCode: diagnostic.code == .controlAPIInvalid ? .invalidRequest : .internalError,
            error: SanitizedError(code: diagnostic.code.rawValue, message: diagnostic.message)
        )
        return (try? ControlPlaneCanonicalJSON.encode(response)) ?? Data()
    }
}
