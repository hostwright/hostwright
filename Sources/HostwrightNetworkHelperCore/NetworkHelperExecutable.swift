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
        let hostAccessBroker = NetworkHelperHostAccessBroker()
        for configuration
            in try store.activeHostAccessConfigurations() {
            guard try hostAccessBroker.apply(
                identity: configuration.identity,
                bindings: configuration.bindings
            ) == configuration.sha256 else {
                throw NetworkHelperError.bindingUnavailable
            }
        }
        let server = NetworkHelperUnixServer(
            runtimeDirectory: runtimeDirectory,
            dispatcher: NetworkHelperDispatcher(
                store: store,
                hostAccessBroker: hostAccessBroker
            ),
            authenticator: .productionClient(),
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        )
        try server.run()
    }
}
