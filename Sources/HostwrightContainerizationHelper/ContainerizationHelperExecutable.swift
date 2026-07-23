import Foundation
import HostwrightRuntime

public enum ContainerizationHelperExecutable {
    public static func run(
        backend: any ContainerizationHelperBackend,
        capabilityDigest: String,
        runtimeDirectoryURL: URL,
        authenticator: ContainerizationHelperPeerAuthenticator,
        idlePolicy: ContainerizationHelperIdlePolicy = .init()
    ) async throws {
        let runtimeDirectory = try ContainerizationHelperRuntimeDirectory.prepare(
            at: runtimeDirectoryURL
        )
        let dispatcher = ContainerizationHelperDispatcher(
            backend: backend,
            expectedCapabilityDigest: capabilityDigest
        )
        let server = ContainerizationHelperUnixServer(
            runtimeDirectory: runtimeDirectory,
            dispatcher: dispatcher,
            authenticator: authenticator,
            idlePolicy: idlePolicy
        )
        try await server.run()
    }
}
