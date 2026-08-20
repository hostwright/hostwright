import Darwin
import Foundation
import HostwrightReleaseQualification

@main
struct HostwrightReleaseQualificationTool {
    static func main() {
        do {
            let invocation = try ReleaseQualificationCLIInvocation(
                arguments: Array(CommandLine.arguments.dropFirst())
            )
            let output = try ReleaseQualificationCLIExecutor().execute(invocation)
            FileHandle.standardOutput.write(output)
            if !output.isEmpty, output.last != 0x0a {
                FileHandle.standardOutput.write(Data([0x0a]))
            }
            exit(0)
        } catch let error as ReleaseQualificationCLIError {
            writeError(error.description)
            exit(error.exitCode)
        } catch let error as ReleaseQualificationContractError {
            let cliError: ReleaseQualificationCLIError
            switch error {
            case .staleEvidence:
                cliError = .stale(error.description)
            case .unsafePath, .ledgerConflict, .tamperedEvidence, .cancelled:
                cliError = .blocked(error.description)
            default:
                cliError = .failed(error.description)
            }
            writeError(cliError.description)
            exit(cliError.exitCode)
        } catch {
            let cliError = ReleaseQualificationCLIError.failed(error.localizedDescription)
            writeError(cliError.description)
            exit(cliError.exitCode)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("hostwright-release-qualify: \(message)\n".utf8))
    }
}
