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
        switch endpoint {
        case .ping, .version:
            throw DockerControlAdapterError.unsupportedEndpoint
        case .info:
            return try CLIControlRoute.docker(
                operation: "status",
                endpoint: endpoint.identifier,
                arguments: ["status", "--json"]
            )
        case .containersList:
            return try CLIControlRoute.docker(
                operation: "status",
                endpoint: endpoint.identifier,
                arguments: ["status", "--json"]
            )
        case .containerInspect(let id):
            return try CLIControlRoute.docker(
                operation: "inspect",
                endpoint: endpoint.identifier,
                arguments: ["inspect", id, "--json"]
            )
        case .imagesList:
            return try CLIControlRoute.docker(
                operation: "status",
                endpoint: endpoint.identifier,
                arguments: ["status", "--json"]
            )
        case .imageInspect(let reference):
            return try CLIControlRoute.docker(
                operation: "image",
                endpoint: endpoint.identifier,
                arguments: ["image", "inspect", reference, "--json"]
            )
        case .events:
            return try CLIControlRoute.docker(
                operation: "events",
                endpoint: endpoint.identifier,
                arguments: ["events", "--json"]
            )
        }
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
        let route = try route(for: endpoint)
        let requestID = UUID().uuidString.lowercased()
        let request = ControlRequestEnvelope(
            requestID: requestID,
            operation: route.operation,
            timeoutMilliseconds: timeoutMilliseconds,
            body: route.requestBody()
        )
        let response: ControlResponseEnvelope
        do {
            response = try sendRequest(request)
        } catch {
            throw DockerControlAdapterError.unavailable
        }
        guard !isCancelled() else { throw DockerControlAdapterError.cancelled }
        guard response.requestID == requestID else {
            throw DockerControlAdapterError.invalidResponse
        }
        guard response.status == .completed, response.reasonCode == .completed,
              response.error == nil, let result = response.result else {
            switch response.reasonCode {
            case .serviceUnavailable, .deadlineExceeded, .cancelled, .auditUnavailable:
                throw DockerControlAdapterError.unavailable
            default:
                throw DockerControlAdapterError.rejected
            }
        }
        return try outputData(from: result)
    }

    private func outputData(from result: ControlPlaneJSONValue) throws -> Data {
        if case .object(let fields) = result,
           case .integer(1)? = fields["resultSchemaVersion"],
           case .integer(let rawExitCode)? = fields["exitCode"],
           case .string(let standardOutput)? = fields["standardOutput"],
           case .string? = fields["standardError"],
           Int64(Int32.min)...Int64(Int32.max) ~= rawExitCode {
            guard rawExitCode == 0 else { throw DockerControlAdapterError.rejected }
            let data = Data(standardOutput.utf8)
            guard data.count <= DockerHTTPCodec.maximumResponseBytes else {
                throw DockerControlAdapterError.invalidResponse
            }
            return data
        }
        let data = try ControlPlaneCanonicalJSON.encode(result)
        guard data.count <= DockerHTTPCodec.maximumResponseBytes else {
            throw DockerControlAdapterError.invalidResponse
        }
        return data
    }
}
