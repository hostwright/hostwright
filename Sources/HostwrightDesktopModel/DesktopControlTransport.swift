import Foundation
import HostwrightControlPlane
import HostwrightControlTransport
import HostwrightCore

public protocol DesktopControlSession: AnyObject, Sendable {
    func openStream(
        streamID: String,
        request: ControlStreamOpenRequest,
        cursor: String?,
        initialCredit: Int
    ) throws
    func nextFrame(streamID: String, timeoutMilliseconds: Int) throws -> StreamFrame
    func acknowledge(streamID: String, credit: Int, cursor: String?) throws
    func cancel(streamID: String) throws
    func close()
}

public protocol DesktopControlTransport: Sendable {
    func send(_ request: ControlRequestEnvelope) throws -> ControlResponseEnvelope
    func connectSession() throws -> any DesktopControlSession
}

public struct DesktopControlEndpoint: Equatable, Sendable {
    public let socketPath: String
    public let stateDatabasePath: String

    public init(socketPath: String, stateDatabasePath: String) throws {
        self.socketPath = try HostwrightLocalPathResolver.normalizedAbsolutePath(
            socketPath,
            role: "desktop control socket"
        )
        self.stateDatabasePath = try HostwrightLocalPathResolver.normalizedAbsolutePath(
            stateDatabasePath,
            role: "desktop state database"
        )
    }

    public static func discover(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        let resolution = try HostwrightLocalPathResolver.resolve(
            homeDirectory: homeDirectory,
            environment: environment
        )
        return try Self(
            socketPath: resolution.layout.controlSocket,
            stateDatabasePath: resolution.stateDatabasePath
        )
    }
}

public struct PersistentDesktopControlTransport: DesktopControlTransport, Sendable {
    private let client: PersistentControlClient

    public init(
        endpoint: DesktopControlEndpoint,
        serverTrustPolicy: PersistentControlServerTrustPolicy = .init(),
        credentialProofProvider: @escaping PersistentControlClient.CredentialProofProvider = { _ in nil }
    ) {
        client = PersistentControlClient(
            socketPath: endpoint.socketPath,
            serverTrustPolicy: serverTrustPolicy,
            credentialProofProvider: credentialProofProvider
        )
    }

    public func send(_ request: ControlRequestEnvelope) throws -> ControlResponseEnvelope {
        try client.send(request)
    }

    public func connectSession() throws -> any DesktopControlSession {
        PersistentDesktopControlSession(base: try client.connectSession())
    }
}

private final class PersistentDesktopControlSession: DesktopControlSession, @unchecked Sendable {
    private let base: PersistentControlClientSession

    init(base: PersistentControlClientSession) {
        self.base = base
    }

    func openStream(
        streamID: String,
        request: ControlStreamOpenRequest,
        cursor: String?,
        initialCredit: Int
    ) throws {
        try base.openStream(
            streamID: streamID,
            request: request,
            cursor: cursor,
            initialCredit: initialCredit
        )
    }

    func nextFrame(streamID: String, timeoutMilliseconds: Int) throws -> StreamFrame {
        try base.nextFrame(streamID: streamID, timeoutMilliseconds: timeoutMilliseconds)
    }

    func acknowledge(streamID: String, credit: Int, cursor: String?) throws {
        try base.acknowledge(streamID: streamID, credit: credit, cursor: cursor)
    }

    func cancel(streamID: String) throws {
        try base.cancel(streamID: streamID)
    }

    func close() {
        base.close()
    }
}
