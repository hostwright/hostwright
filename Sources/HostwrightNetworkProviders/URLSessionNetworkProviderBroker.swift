import Foundation

public final class URLSessionNetworkProviderBroker:
    @unchecked Sendable,
    NetworkProviderBroker
{
    public typealias SecretReferenceResolver =
        @Sendable (String) async throws -> NetworkProviderSecretHandle
    public typealias ScopedRequestHandler =
        @Sendable (String, Data) async throws -> Data

    private let session: URLSession
    private let sessionDelegate: ExactOriginSessionDelegate?
    private let secretReferenceResolver: SecretReferenceResolver
    private let identityHandler: ScopedRequestHandler
    private let routeHandler: ScopedRequestHandler

    public init(
        secretReferenceResolver: @escaping SecretReferenceResolver,
        identityHandler: @escaping ScopedRequestHandler,
        routeHandler: @escaping ScopedRequestHandler
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        let delegate = ExactOriginSessionDelegate()
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        sessionDelegate = delegate
        self.secretReferenceResolver = secretReferenceResolver
        self.identityHandler = identityHandler
        self.routeHandler = routeHandler
    }

    init(
        configuration: URLSessionConfiguration,
        secretReferenceResolver: @escaping SecretReferenceResolver,
        identityHandler: @escaping ScopedRequestHandler,
        routeHandler: @escaping ScopedRequestHandler
    ) {
        let delegate = ExactOriginSessionDelegate()
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        sessionDelegate = delegate
        self.secretReferenceResolver = secretReferenceResolver
        self.identityHandler = identityHandler
        self.routeHandler = routeHandler
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func https(origin: String, request: Data) async throws -> Data {
        guard Self.isCanonicalHTTPSOrigin(origin),
              request.count
                  <= RestrictedNetworkProviderHost.maximumBrokerRequestBytes,
              let url = URL(string: origin)
        else {
            throw NetworkProviderError.deniedGrant
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request
        urlRequest.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Content-Type"
        )
        urlRequest.setValue(
            String(request.count),
            forHTTPHeaderField: "Content-Length"
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw NetworkProviderError.deniedGrant
        }
        guard data.count
                <= RestrictedNetworkProviderHost.maximumBrokerResponseBytes,
              let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.url?.absoluteString == origin
        else {
            throw NetworkProviderError.deniedGrant
        }
        return data
    }

    public func secretReference(
        _ reference: String
    ) async throws -> NetworkProviderSecretHandle {
        guard Self.isScope(reference, prefix: "secret:") else {
            throw NetworkProviderError.deniedGrant
        }
        let handle = try await secretReferenceResolver(reference)
        guard Self.isSafeHandle(handle.identifier) else {
            throw NetworkProviderError.deniedGrant
        }
        return handle
    }

    public func identity(scope: String, request: Data) async throws -> Data {
        guard Self.isScope(scope, prefix: "identity:") else {
            throw NetworkProviderError.deniedGrant
        }
        return try await executeScopedHandler(
            identityHandler,
            scope: scope,
            request: request
        )
    }

    public func route(scope: String, request: Data) async throws -> Data {
        guard Self.isScope(scope, prefix: "route:") else {
            throw NetworkProviderError.deniedGrant
        }
        return try await executeScopedHandler(
            routeHandler,
            scope: scope,
            request: request
        )
    }

    private func executeScopedHandler(
        _ handler: ScopedRequestHandler,
        scope: String,
        request: Data
    ) async throws -> Data {
        guard request.count
                <= RestrictedNetworkProviderHost.maximumBrokerRequestBytes
        else {
            throw NetworkProviderError.deniedGrant
        }
        let response = try await handler(scope, request)
        guard response.count
                <= RestrictedNetworkProviderHost.maximumBrokerResponseBytes
        else {
            throw NetworkProviderError.outputLimitExceeded
        }
        return response
    }

    private static func isCanonicalHTTPSOrigin(_ value: String) -> Bool {
        guard value.utf8.count <= 2_048,
              !value.contains(".."),
              let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty,
              host == host.lowercased(),
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil
        else {
            return false
        }
        if let port = components.port, !(1...65_535).contains(port) {
            return false
        }
        var canonical = "https://"
        canonical += host.contains(":") ? "[\(host)]" : host
        if let port = components.port {
            canonical += ":\(port)"
        }
        return canonical == value
    }

    private static func isScope(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else {
            return false
        }
        let suffix = String(value.dropFirst(prefix.count))
        return suffix.utf8.count <= 256
            && suffix.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$",
                options: .regularExpression
            ) != nil
            && !suffix.contains("..")
    }

    private static func isSafeHandle(_ value: String) -> Bool {
        value.utf8.count <= 128
            && value.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}$",
                options: .regularExpression
            ) != nil
            && !value.contains("..")
    }
}

private final class ExactOriginSessionDelegate:
    NSObject,
    @unchecked Sendable,
    URLSessionTaskDelegate
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
