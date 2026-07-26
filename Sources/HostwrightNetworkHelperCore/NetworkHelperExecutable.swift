import Foundation
import HostwrightRuntime

public enum NetworkHelperExecutable {
    public static func run(
        runtimeDirectoryURL: URL,
        idleTimeoutMilliseconds: Int64 = 30_000
    ) throws {
        let runtimeDirectory =
            try ContainerizationHelperRuntimeDirectory.prepare(
                at: runtimeDirectoryURL,
                socketName: "network-helper.sock"
            )
        let stateRoot = runtimeDirectoryURL.appendingPathComponent(
            "dns-state",
            isDirectory: true
        )
        let store = try NetworkHelperStateStore(rootURL: stateRoot)
        let server = NetworkHelperUnixServer(
            runtimeDirectory: runtimeDirectory,
            dispatcher: NetworkHelperDispatcher(store: store),
            authenticator: .productionClient(),
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        )
        try server.run()
    }
}
