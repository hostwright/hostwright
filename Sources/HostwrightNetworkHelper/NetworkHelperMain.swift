import Darwin
import Foundation
import HostwrightNetworkHelperCore
import HostwrightState

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
            guard arguments.count >= 2,
                  arguments.count.isMultiple(of: 2) else {
                throw NetworkHelperMainError.invalidArguments
            }
            var runtimeDirectoryPath: String?
            var stateDatabasePath: String?
            var idleTimeoutMilliseconds: Int64 = 30_000
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                let value = arguments[index + 1]
                switch flag {
                case "--runtime-directory":
                    guard runtimeDirectoryPath == nil else {
                        throw NetworkHelperMainError.invalidArguments
                    }
                    runtimeDirectoryPath = value
                case "--idle-timeout-milliseconds":
                    guard let parsed = Int64(value),
                          parsed > 0,
                          parsed <= 30_000 else {
                        throw NetworkHelperMainError.invalidArguments
                    }
                    idleTimeoutMilliseconds = parsed
                case "--state-database":
                    guard stateDatabasePath == nil else {
                        throw NetworkHelperMainError.invalidArguments
                    }
                    stateDatabasePath = value
                default:
                    throw NetworkHelperMainError.invalidArguments
                }
                index += 2
            }
            guard let runtimeDirectoryPath else {
                throw NetworkHelperMainError.invalidArguments
            }
            let runtimeDirectoryURL = URL(
                fileURLWithPath: runtimeDirectoryPath,
                isDirectory: true
            )
            let tunnelStore:
                ServiceTunnelStateRepository?
            if let stateDatabasePath {
                let store = SQLiteStateStore(
                    configuration: StateStoreConfiguration(
                        explicitDatabasePath: stateDatabasePath
                    )
                )
                try store.validateSchema()
                tunnelStore = store.serviceTunnels
            } else {
                tunnelStore = nil
            }
            try NetworkHelperExecutable.run(
                runtimeDirectoryURL: runtimeDirectoryURL,
                idleTimeoutMilliseconds: idleTimeoutMilliseconds,
                tunnelStore: tunnelStore
            )
        } catch {
            FileHandle.standardError.write(
                Data("hostwright-network-helper: startup failed\n".utf8)
            )
            Darwin.exit(EX_CONFIG)
        }
    }
}
