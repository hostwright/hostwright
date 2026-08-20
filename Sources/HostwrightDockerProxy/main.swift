import Foundation
import HostwrightControlTransport
import HostwrightDockerEngine

@main
enum HostwrightDockerProxyMain {
    static func main() {
        do {
            let options = try options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.help {
                print("hostwright-docker-proxy --socket <absolute-path> --control-socket <absolute-path>")
                return
            }
            let configuration = try DockerProxyConfiguration(
                socketPath: options.socketPath!,
                controlSocketPath: options.controlSocketPath!
            )
            let adapter = DockerControlAdapter(
                client: PersistentControlClient(socketPath: configuration.controlSocketPath)
            )
            let server = try DockerProxyServer(configuration: configuration, adapter: adapter)
            let listener = try DockerUnixSocketListener(
                socketPath: configuration.socketPath,
                recoverStaleSocket: true
            )
            try DockerProxyDaemon(server: server, listener: listener).run()
        } catch {
            FileHandle.standardError.write(
                Data("hostwright-docker-proxy: failed safely (\(String(describing: error)))\n".utf8)
            )
            exit(64)
        }
    }

    private struct Options {
        let socketPath: String?
        let controlSocketPath: String?
        let help: Bool
    }

    private static func options(arguments: [String]) throws -> Options {
        if arguments == ["--help"] || arguments == ["-h"] {
            return Options(socketPath: nil, controlSocketPath: nil, help: true)
        }
        var socketPath: String?
        var controlSocketPath: String?
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw UsageError.invalid }
            switch arguments[index] {
            case "--socket":
                guard socketPath == nil else { throw UsageError.invalid }
                socketPath = arguments[index + 1]
            case "--control-socket":
                guard controlSocketPath == nil else { throw UsageError.invalid }
                controlSocketPath = arguments[index + 1]
            default:
                throw UsageError.invalid
            }
            index += 2
        }
        guard let socketPath, let controlSocketPath else { throw UsageError.invalid }
        return Options(socketPath: socketPath, controlSocketPath: controlSocketPath, help: false)
    }
}

private enum UsageError: Error {
    case invalid
}
