import Foundation
import HostwrightControlPlane

public struct DockerProxyConfiguration: Equatable, Sendable {
    public let socketPath: String
    public let controlSocketPath: String
    public let serverVersion: String
    public let maximumAPIVersion: DockerAPIVersion
    public let requestTimeoutMilliseconds: Int

    public init(
        socketPath: String,
        controlSocketPath: String,
        serverVersion: String = "0.0.2-dev",
        maximumAPIVersion: DockerAPIVersion = .maximum,
        requestTimeoutMilliseconds: Int = 30_000
    ) throws {
        guard Self.isSafeAbsolutePath(socketPath),
              Self.isSafeAbsolutePath(controlSocketPath),
              socketPath.utf8.count < 100,
              controlSocketPath.utf8.count < 100,
              serverVersion.utf8.count <= 128,
              !serverVersion.isEmpty,
              requestTimeoutMilliseconds > 0,
              requestTimeoutMilliseconds <= 300_000,
              maximumAPIVersion.isSupported else {
            throw DockerSocketError.unsafePath
        }
        self.socketPath = socketPath
        self.controlSocketPath = controlSocketPath
        self.serverVersion = serverVersion
        self.maximumAPIVersion = maximumAPIVersion
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
    }

    private static func isSafeAbsolutePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return path.hasPrefix("/")
            && !path.contains("\0")
            && !path.contains("//")
            && !path.hasSuffix("/")
            && !components.isEmpty
            && !components.contains(".")
            && !components.contains("..")
    }
}

public final class DockerProxyServer: @unchecked Sendable {
    public let configuration: DockerProxyConfiguration
    public let adapter: DockerControlAdapter

    public init(
        configuration: DockerProxyConfiguration,
        adapter: DockerControlAdapter
    ) throws {
        self.configuration = configuration
        self.adapter = adapter
    }

    public func handle(
        _ request: DockerHTTPRequest,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> DockerHTTPResponse {
        do {
            guard request.version == "HTTP/1.1", request.target.hasPrefix("/") else {
                return DockerHTTPCodec.errorResponse(.badRequest)
            }
            guard !request.isUpgradeRequest else {
                return DockerHTTPCodec.errorResponse(.unsupportedUpgrade)
            }
            guard request.body.isEmpty else {
                return DockerHTTPCodec.errorResponse(.unsupportedOperation)
            }
            guard !isCancelled() else {
                return DockerHTTPCodec.errorResponse(.cancelled)
            }

            let pathVersion: DockerAPIVersion?
            do {
                pathVersion = try DockerEndpoint.targetVersion(request.target)
            } catch {
                return DockerHTTPCodec.errorResponse(.badRequest)
            }
            let headerVersion: DockerAPIVersion?
            if let raw = request.header("docker-api-version") {
                do {
                    headerVersion = try DockerAPIVersion(raw)
                } catch {
                    return DockerHTTPCodec.errorResponse(.unsupportedAPIVersion)
                }
            } else {
                headerVersion = nil
            }
            if let pathVersion, let headerVersion, pathVersion != headerVersion {
                return DockerHTTPCodec.errorResponse(.badRequest)
            }
            let negotiated: DockerAPIVersion
            do {
                negotiated = try DockerAPIVersion.negotiate(
                    requested: (pathVersion ?? headerVersion)?.rawValue
                )
            } catch {
                return DockerHTTPCodec.errorResponse(.unsupportedAPIVersion)
            }
            guard negotiated <= configuration.maximumAPIVersion else {
                return DockerHTTPCodec.errorResponse(.unsupportedAPIVersion)
            }
            let endpoint: DockerEndpoint
            do {
                endpoint = try DockerEndpoint.resolve(
                    method: request.method,
                    target: request.target
                )
            } catch let error as DockerEndpointError {
                return Self.endpointErrorResponse(error)
            } catch {
                return DockerHTTPCodec.errorResponse(.badRequest)
            }
            guard DockerEndpoint.advertised(for: negotiated).contains(
                Self.advertisedKey(for: endpoint, version: negotiated)
            ) else {
                return DockerHTTPCodec.errorResponse(
                    .unsupportedOperation,
                    apiVersion: negotiated
                )
            }

            switch endpoint {
            case .ping:
                return Self.response(
                    statusCode: 200,
                    version: negotiated,
                    contentType: "text/plain",
                    body: Data("OK".utf8),
                    closeConnection: !request.keepAlive
                )
            case .version:
                let body = try Self.versionBody(
                    negotiated: negotiated,
                    serverVersion: configuration.serverVersion
                )
                return Self.response(
                    statusCode: 200,
                    version: negotiated,
                    body: body,
                    closeConnection: !request.keepAlive
                )
            case .info, .containersList, .containerInspect, .imagesList, .imageInspect, .events:
                return DockerHTTPCodec.errorResponse(
                    .unsupportedOperation,
                    apiVersion: negotiated
                )
            }
        } catch {
            return DockerHTTPCodec.errorResponse(.internalError)
        }
    }

    public func responseData(
        for request: DockerHTTPRequest,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Data {
        let response = handle(request, isCancelled: isCancelled)
        return try DockerHTTPCodec.encodeResponse(
            response,
            suppressBody: request.method == .head,
            isCancelled: isCancelled
        )
    }

    private static func endpointErrorResponse(_ error: DockerEndpointError) -> DockerHTTPResponse {
        switch error {
        case .invalidTarget: return DockerHTTPCodec.errorResponse(.badRequest)
        case .unsupportedAPIVersion: return DockerHTTPCodec.errorResponse(.unsupportedAPIVersion)
        case .methodNotAllowed: return DockerHTTPCodec.errorResponse(.methodNotAllowed)
        case .unsupportedOperation, .unsupportedQuery:
            return DockerHTTPCodec.errorResponse(.unsupportedOperation)
        }
    }

    private static func adapterErrorResponse(
        _ error: DockerControlAdapterError,
        version: DockerAPIVersion
    ) -> DockerHTTPResponse {
        switch error {
        case .cancelled:
            return DockerHTTPCodec.errorResponse(.cancelled, apiVersion: version)
        case .unavailable:
            return DockerHTTPCodec.errorResponse(.controlUnavailable, apiVersion: version)
        case .rejected, .invalidResponse, .unsupportedEndpoint:
            return DockerHTTPCodec.errorResponse(.controlRejected, apiVersion: version)
        }
    }

    private static func response(
        statusCode: Int,
        version: DockerAPIVersion,
        contentType: String = "application/json",
        body: Data,
        closeConnection: Bool
    ) -> DockerHTTPResponse {
        DockerHTTPResponse(
            statusCode: statusCode,
            headers: [
                "Api-Version": version.rawValue,
                "Content-Type": contentType,
                "Docker-Experimental": "false",
            ],
            body: body,
            closeConnection: closeConnection
        )
    }

    private static func versionBody(
        negotiated: DockerAPIVersion,
        serverVersion: String
    ) throws -> Data {
        let value: ControlPlaneJSONValue = .object([
            "ApiVersion": .string(negotiated.rawValue),
            "Arch": .string("arm64"),
            "Experimental": .bool(false),
            "MinAPIVersion": .string(DockerAPIVersion.minimum.rawValue),
            "Os": .string("darwin"),
            "Version": .string(serverVersion),
        ])
        return try ControlPlaneCanonicalJSON.encode(value)
    }

    private static func isJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return object is [Any] || object is [String: Any]
    }

    private static func advertisedKey(
        for endpoint: DockerEndpoint,
        version: DockerAPIVersion
    ) -> String {
        let prefix = "/v\(version.rawValue)"
        switch endpoint {
        case .ping: return "GET \(prefix)/_ping"
        case .version: return "GET \(prefix)/version"
        case .info: return "GET \(prefix)/info"
        case .containersList: return "GET \(prefix)/containers/json"
        case .containerInspect: return "GET \(prefix)/containers/{id}/json"
        case .imagesList: return "GET \(prefix)/images/json"
        case .imageInspect: return "GET \(prefix)/images/{name}/json"
        case .events: return "GET \(prefix)/events"
        }
    }
}
