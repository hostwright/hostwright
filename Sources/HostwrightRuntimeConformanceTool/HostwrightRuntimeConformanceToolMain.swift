import Darwin
import Foundation

@main
enum HostwrightRuntimeConformanceToolMain {
    static func main() async {
        if let workerExit = RuntimeQualificationRecoveryWorker.runIfRequested() {
            exit(workerExit)
        }
        let result = await RuntimeQualificationCommand.run(
            arguments: Array(CommandLine.arguments.dropFirst())
        )
        if !result.standardOutput.isEmpty {
            FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
        }
        if !result.standardError.isEmpty {
            FileHandle.standardError.write(Data(result.standardError.utf8))
        }
        exit(result.exitCode)
    }
}
