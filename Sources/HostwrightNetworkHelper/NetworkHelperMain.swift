import Darwin
import Foundation
import HostwrightNetworkHelperCore

private enum NetworkHelperMainError: Error {
    case invalidArguments
}

@main
struct HostwrightNetworkHelperMain {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--version"] {
                FileHandle.standardOutput.write(
                    Data("network-helper-protocol-v1\n".utf8)
                )
                return
            }
            guard arguments.count == 2 || arguments.count == 4,
                  arguments[0] == "--runtime-directory",
                  arguments.count == 2
                    || arguments[2] == "--idle-timeout-milliseconds" else {
                throw NetworkHelperMainError.invalidArguments
            }
            let idleTimeoutMilliseconds: Int64
            if arguments.count == 4 {
                guard let value = Int64(arguments[3]),
                      value > 0,
                      value <= 30_000 else {
                    throw NetworkHelperMainError.invalidArguments
                }
                idleTimeoutMilliseconds = value
            } else {
                idleTimeoutMilliseconds = 30_000
            }
            let runtimeDirectoryURL = URL(
                fileURLWithPath: arguments[1],
                isDirectory: true
            )
            try NetworkHelperExecutable.run(
                runtimeDirectoryURL: runtimeDirectoryURL,
                idleTimeoutMilliseconds: idleTimeoutMilliseconds
            )
        } catch {
            FileHandle.standardError.write(
                Data("hostwright-network-helper: startup failed\n".utf8)
            )
            Darwin.exit(EX_CONFIG)
        }
    }
}
