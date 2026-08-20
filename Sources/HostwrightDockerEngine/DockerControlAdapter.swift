import Foundation
import HostwrightCommandTransport
import HostwrightControlPlane
import HostwrightControlTransport

public enum DockerControlAdapterError: Error, Equatable, Sendable {
    case cancelled
    case unavailable
    case rejected
    case invalidResponse
    case unsupportedEndpoint
}

/// The Docker surface is deliberately a client of the authenticated Phase 09
/// Control API. It has no runtime, state, or filesystem authority of its own.
public struct DockerControlAdapter: Sendable {
    public typealias RequestSender = @Sendable (
        ControlRequestEnvelope
    ) throws -> ControlResponseEnvelope

    private let sendRequest: RequestSender

    public init(client: PersistentControlClient) {
        self.sendRequest = { request in
            try client.send(request)
        }
    }

    public init(sendRequest: @escaping RequestSender) {
        self.sendRequest = sendRequest
    }

    public func route(for endpoint: DockerEndpoint) throws -> CLIControlRoute {
        throw DockerControlAdapterError.unsupportedEndpoint
    }

    public func read(
        endpoint: DockerEndpoint,
        timeoutMilliseconds: Int = 30_000,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Data {
        guard !endpoint.isLocal else {
            throw DockerControlAdapterError.unsupportedEndpoint
        }
        guard (1...300_000).contains(timeoutMilliseconds) else {
            throw DockerControlAdapterError.invalidResponse
        }
        guard !isCancelled() else { throw DockerControlAdapterError.cancelled }
        throw DockerControlAdapterError.unsupportedEndpoint
    }
}
