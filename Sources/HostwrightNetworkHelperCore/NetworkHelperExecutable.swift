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
        let ingressBroker = NetworkHelperIngressBroker()
        for configuration
            in try store.activeHostAccessConfigurations() {
            do {
                guard try hostAccessBroker.apply(
                    identity: configuration.identity,
                    bindings: configuration.bindings
                ) == configuration.sha256 else {
                    throw NetworkHelperError.bindingUnavailable
                }
            } catch NetworkHelperError.bindingUnavailable {
                // The project bridge may not exist until its first attached
                // container starts. The server must remain available so the
                // same persisted generation can be re-observed and activated.
            }
        }
        for configuration in try store.activeIngressConfigurations() {
            do {
                guard try ingressBroker.apply(
                    identity: configuration.identity,
                    bindings: configuration.bindings
                ) == configuration.sha256 else {
                    throw NetworkHelperError.bindingUnavailable
                }
            } catch NetworkHelperError.bindingUnavailable {
                // A conflicting local listener remains inactive while the
                // persisted generation stays available for exact recovery.
            }
        }
        let server = NetworkHelperUnixServer(
            runtimeDirectory: runtimeDirectory,
            dispatcher: NetworkHelperDispatcher(
                store: store,
                hostAccessBroker: hostAccessBroker,
                ingressBroker: ingressBroker
            ),
            authenticator: .productionClient(),
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        )
        try server.run()
    }
}
