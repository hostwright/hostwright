import Darwin
import Foundation
import HostwrightCLI

let result = HostwrightCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
if !result.standardOutput.isEmpty {
    FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
}
if !result.standardError.isEmpty {
    FileHandle.standardError.write(Data(result.standardError.utf8))
}
exit(result.exitCode)
