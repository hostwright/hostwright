import Foundation
import HostwrightStorage

public enum StorageProviderHelperExecutable {
    public static func run(
        provider: any StorageProviderSPI,
        runtimeDirectoryURL: URL,
        authenticator: StorageProviderServerPeerAuthenticator =
            StorageProviderHelperSecurity.peerAuthenticator(),
        connectionTimeoutMilliseconds: Int64 = 5_000
    ) async throws {
        let runtimeDirectory = try StorageProviderRuntimeDirectory.prepare(
            at: runtimeDirectoryURL
        )
        let dispatcher = try await StorageProviderTransportDispatcher.make(
            provider: provider
        )
        let server = try StorageProviderUnixServer(
            runtimeDirectory: runtimeDirectory,
            dispatcher: dispatcher,
            authenticator: authenticator,
            connectionTimeoutMilliseconds: connectionTimeoutMilliseconds
        )
        try await server.run()
    }
}
