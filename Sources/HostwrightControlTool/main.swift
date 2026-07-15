import Darwin
import Foundation
import HostwrightControl
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
case .run(let configuration):
    let result: LocalControlRunResult
    do {
        let requestData = try LocalControlInputReader.read()
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
