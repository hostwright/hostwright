import Darwin
import Foundation
import HostwrightControl
import HostwrightCommandTransport
import HostwrightControlPlane
import HostwrightControlTransport
import HostwrightCore

let command: LocalControlToolCommand
do {
    command = try LocalControlToolCommand.parse(arguments: Array(CommandLine.arguments.dropFirst()))
} catch let error as LocalControlUsageError {
    FileHandle.standardError.write(Data(("HW-API-001: \(error.message)\n\n" + LocalControlToolCommand.helpText).utf8))
    exit(LocalControlExitCode.usage.rawValue)
} catch {
    FileHandle.standardError.write(Data("HW-API-001: Invalid hostwright-control arguments.\n".utf8))
    exit(LocalControlExitCode.usage.rawValue)
}

switch command {
case .version:
    print(HostwrightIdentity.version)
case .help:
    print(LocalControlToolCommand.helpText, terminator: "")
case .bootstrap:
    do {
        let requestData = try LocalControlInputReader.read(
            maximumBytes: ControlPlaneContract.maximumRequestBytes
        )
        let responseData = BootstrapControlAPI.run(requestData: requestData)
        guard !responseData.isEmpty,
              responseData.count <= ControlPlaneContract.maximumResponseOrFrameBytes else {
            throw HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message: "The Bootstrap API response exceeded its output limit."
            )
        }
        FileHandle.standardOutput.write(responseData)
    } catch {
        FileHandle.standardError.write(
            Data("HW-API-003: The Bootstrap API request failed safely.\n".utf8)
        )
        exit(LocalControlExitCode.executionFailed.rawValue)
    }
case .persistent(let socketPath):
    do {
        let requestData = try LocalControlInputReader.read(
            maximumBytes: ControlPlaneContract.maximumRequestBytes
        )
        let request = try Phase09StrictDecoder.decode(
            ControlRequestEnvelope.self,
            from: requestData,
            allowedKeys: [
                "apiVersion", "protocolRevision", "requestID", "operation",
                "timeoutMilliseconds", "idempotencyKey", "body"
            ],
            requiredKeys: [
                "apiVersion", "protocolRevision", "requestID", "operation", "timeoutMilliseconds"
            ]
        )
        let response = try PersistentControlClient(socketPath: socketPath).send(request)
        FileHandle.standardOutput.write(try ControlPlaneCanonicalJSON.encode(response))
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(
            Data("HW-API-001: The persistent control request failed.\n".utf8)
        )
        exit(LocalControlExitCode.unavailable.rawValue)
    }
case .run(let configuration):
    let result: LocalControlRunResult
    do {
        let requestData = try LocalControlInputReader.read()
        let parsed = try LocalControlRequestParser.parse(requestData)
        guard parsed.operation == .plan else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The revision-2.0 one-shot companion accepts only plan."
            )
        }
        let api = LocalControlAPI(configuration: configuration)
        result = api.run(requestData: requestData)
    } catch let diagnostic as HostwrightDiagnostic {
        result = LocalControlAPI.invalidInputResult(diagnostic)
    } catch {
        result = LocalControlAPI.invalidInputResult(
            HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message: "The local control tool could not read the request."
            )
        )
    }

    if !result.standardOutput.isEmpty {
        FileHandle.standardOutput.write(result.standardOutput)
    }
    if !result.standardError.isEmpty {
        FileHandle.standardError.write(Data(result.standardError.utf8))
    }
    exit(result.exitCode)
}
