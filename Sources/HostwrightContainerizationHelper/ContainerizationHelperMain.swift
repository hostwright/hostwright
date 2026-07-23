import Darwin
import Foundation
import HostwrightCore
import HostwrightRuntime

@main
struct HostwrightContainerizationHelperMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--version"] {
                FileHandle.standardOutput.write(Data("\(HostwrightIdentity.version)\n".utf8))
                return
            }
            let configurationURL = try configurationURL(arguments: arguments)
            let configuration = try ContainerizationHelperConfiguration.load(at: configurationURL)
            let backend = try await ContainerizationFrameworkBackend.make(configuration: configuration)
            let snapshot = try await backend.negotiate()
            try await ContainerizationHelperExecutable.run(
                backend: backend,
                capabilityDigest: snapshot.canonicalSHA256,
                runtimeDirectoryURL: configuration.runtimeDirectoryURL,
                authenticator: ContainerizationHelperSecurity.peerAuthenticator()
            )
        } catch {
            FileHandle.standardError.write(
                Data("hostwright-containerization-helper: startup failed\n".utf8)
            )
            Darwin.exit(EX_CONFIG)
        }
    }

    private static func configurationURL(arguments: [String]) throws -> URL {
        if arguments.isEmpty {
            return ContainerizationHelperConfiguration.defaultConfigurationURL()
        }
        guard arguments.count == 2, arguments[0] == "--configuration" else {
            throw ContainerizationHelperConfigurationError.configurationInvalid
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: false)
    }
}
