import Foundation
import Dispatch

public enum RegistryTransportAuthorizationScheme: String, Equatable, Sendable {
    case basic = "Basic"
    case bearer = "Bearer"
}

public struct RegistryTransportAuthorization:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let scheme: RegistryTransportAuthorizationScheme
    private let value: String

    public init(scheme: RegistryTransportAuthorizationScheme, value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 64 * 1_024,
              !value.contains("\0"),
              !value.contains(where: \.isNewline) else {
            throw RegistryTransportError.invalidAuthorization
        }
        self.scheme = scheme
        self.value = value
    }

    public var description: String {
        "Registry authorization (\(scheme.rawValue), redacted)."
    }

    public var debugDescription: String {
        description
    }

    public func withHeaderValue<Result>(
        _ body: (String) throws -> Result
    ) rethrows -> Result {
        try body("\(scheme.rawValue) \(value)")
    }
}

public enum RegistryTransportMethod: String, Equatable, Sendable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

public struct RegistryTransportRequest:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let url: URL
    public let method: RegistryTransportMethod
    public let headers: [String: String]
    public let authorization: RegistryTransportAuthorization?
    public let body: Data?
    public let timeoutMilliseconds: Int

    public init(
        url: URL,
        method: RegistryTransportMethod,
        headers: [String: String] = [:],
        authorization: RegistryTransportAuthorization? = nil,
        body: Data? = nil,
        timeoutMilliseconds: Int = 30_000
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.authorization = authorization
        self.body = body
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public var description: String {
        let authorizationDescription = authorization == nil ? "none" : "redacted"
        return "Registry transport request (" +
            "method: \(method.rawValue), " +
            "authorization: \(authorizationDescription), " +
            "bodyBytes: \(body?.count ?? 0))."
    }

    public var debugDescription: String {
        description
    }
}

public struct RegistryTransportResponse:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var description: String {
        "Registry transport response (status: \(statusCode), bodyBytes: \(body.count), body: redacted)."
    }

    public var debugDescription: String {
        description
    }
}

public enum RegistryTransportError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidURL
    case insecureTransport
    case invalidMethod
    case invalidHeader
    case invalidAuthorization
    case requestBodyTooLarge
    case responseBodyTooLarge
    case responseHeadersTooLarge
    case invalidTimeout
    case redirectRejected
    case invalidResponse
    case timedOut
    case cancelled
    case transportFailed

    public var description: String {
        switch self {
        case .invalidURL:
            "The registry transport URL is invalid."
        case .insecureTransport:
            "Registry transport requires HTTPS."
        case .invalidMethod:
            "The registry transport method is invalid."
        case .invalidHeader:
            "A registry transport header is invalid."
        case .invalidAuthorization:
            "Registry authorization is invalid."
        case .requestBodyTooLarge:
            "The registry request body exceeds its bounded size."
        case .responseBodyTooLarge:
            "The registry response body exceeds its bounded size."
        case .responseHeadersTooLarge:
            "The registry response headers exceed their bounded size."
        case .invalidTimeout:
            "The registry transport timeout is invalid."
        case .redirectRejected:
            "The registry redirect was rejected by the same-origin policy."
        case .invalidResponse:
            "The registry returned an invalid HTTP response."
        case .timedOut:
            "The registry request timed out."
        case .cancelled:
            "The registry request was cancelled."
        case .transportFailed:
            "The registry transport failed."
        }
    }
}

public protocol RegistryHTTPTransporting: Sendable {
    func send(_ request: RegistryTransportRequest) async throws -> RegistryTransportResponse
}

public final class RegistryTransportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

public protocol RegistrySynchronousHTTPTransporting: Sendable {
    func send(
        _ request: RegistryTransportRequest,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTransportResponse
}

public extension RegistrySynchronousHTTPTransporting {
    func send(_ request: RegistryTransportRequest) throws -> RegistryTransportResponse {
        try send(request, cancellation: RegistryTransportCancellation())
    }
}

public struct SynchronousURLSessionRegistryTransport: RegistrySynchronousHTTPTransporting {
    private let transport: URLSessionRegistryTransport
    private let maximumRequestBodyBytes: Int
    private let maximumResponseBodyBytes: Int

    public init(
        maximumRequestBodyBytes: Int = URLSessionRegistryTransport.defaultMaximumRequestBodyBytes,
        maximumResponseBodyBytes: Int = URLSessionRegistryTransport.defaultMaximumResponseBodyBytes
    ) {
        self.maximumRequestBodyBytes = maximumRequestBodyBytes
        self.maximumResponseBodyBytes = maximumResponseBodyBytes
        transport = URLSessionRegistryTransport(
            maximumRequestBodyBytes: maximumRequestBodyBytes,
            maximumResponseBodyBytes: maximumResponseBodyBytes
        )
    }

    public func send(
        _ request: RegistryTransportRequest,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTransportResponse {
        try URLSessionRegistryTransport.validate(
            request,
            maximumRequestBodyBytes: maximumRequestBodyBytes,
            maximumResponseBodyBytes: maximumResponseBodyBytes
        )
        if cancellation.isCancelled {
            throw RegistryTransportError.cancelled
        }

        let completion = RegistrySynchronousTransportCompletion()
        let task = Task.detached {
            do {
                completion.complete(.success(try await transport.send(request)))
            } catch {
                completion.complete(.failure(error))
            }
        }
        let deadline = DispatchTime.now() + .milliseconds(request.timeoutMilliseconds + 2_000)
        while completion.wait(until: DispatchTime.now() + .milliseconds(25)) == .timedOut {
            if cancellation.isCancelled {
                task.cancel()
                throw RegistryTransportError.cancelled
            }
            if DispatchTime.now() >= deadline {
                task.cancel()
                throw RegistryTransportError.timedOut
            }
        }
        if cancellation.isCancelled {
            task.cancel()
            throw RegistryTransportError.cancelled
        }
        guard let result = completion.result else {
            task.cancel()
            throw RegistryTransportError.transportFailed
        }
        do {
            return try result.get()
        } catch let error as RegistryTransportError {
            throw error
        } catch {
            throw RegistryTransportError.transportFailed
        }
    }
}

public struct URLSessionRegistryTransport: RegistryHTTPTransporting {
    public static let defaultMaximumRequestBodyBytes = 8 * 1_024 * 1_024
    public static let defaultMaximumResponseBodyBytes = 8 * 1_024 * 1_024
    public static let maximumHeaderBytes = 64 * 1_024
    public static let maximumHeaderCount = 128
    public static let maximumURLBytes = 8 * 1_024
    public static let maximumRedirects = 3

    private let maximumRequestBodyBytes: Int
    private let maximumResponseBodyBytes: Int

    public init(
        maximumRequestBodyBytes: Int = Self.defaultMaximumRequestBodyBytes,
        maximumResponseBodyBytes: Int = Self.defaultMaximumResponseBodyBytes
    ) {
        self.maximumRequestBodyBytes = maximumRequestBodyBytes
        self.maximumResponseBodyBytes = maximumResponseBodyBytes
    }

    public func send(_ request: RegistryTransportRequest) async throws -> RegistryTransportResponse {
        try Self.validate(
            request,
            maximumRequestBodyBytes: maximumRequestBodyBytes,
            maximumResponseBodyBytes: maximumResponseBodyBytes
        )
        if Task.isCancelled {
            throw RegistryTransportError.cancelled
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = TimeInterval(request.timeoutMilliseconds) / 1_000
        configuration.timeoutIntervalForResource = TimeInterval(request.timeoutMilliseconds) / 1_000
        configuration.waitsForConnectivity = false

        let delegate = RegistryURLSessionDelegate(
            maximumResponseBodyBytes: maximumResponseBodyBytes,
            maximumHeaderBytes: Self.maximumHeaderBytes,
            maximumHeaderCount: Self.maximumHeaderCount,
            maximumRedirects: Self.maximumRedirects
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: TimeInterval(request.timeoutMilliseconds) / 1_000
        )
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if let authorization = request.authorization {
            authorization.withHeaderValue { value in
                urlRequest.setValue(value, forHTTPHeaderField: "Authorization")
            }
        }

        do {
            let (data, response) = try await delegate.perform(session: session, request: urlRequest)
            return RegistryTransportResponse(
                statusCode: response.statusCode,
                headers: try Self.normalizedHeaders(response),
                body: data
            )
        } catch let error as RegistryTransportError {
            throw error
        } catch is CancellationError {
            throw RegistryTransportError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw Task.isCancelled ? RegistryTransportError.cancelled : RegistryTransportError.transportFailed
        } catch let error as URLError where error.code == .timedOut {
            throw RegistryTransportError.timedOut
        } catch {
            throw RegistryTransportError.transportFailed
        }
    }

    static func validate(
        _ request: RegistryTransportRequest,
        maximumRequestBodyBytes: Int,
        maximumResponseBodyBytes: Int
    ) throws {
        guard maximumRequestBodyBytes > 0, maximumResponseBodyBytes > 0 else {
            throw RegistryTransportError.requestBodyTooLarge
        }
        guard request.timeoutMilliseconds > 0, request.timeoutMilliseconds <= 120_000 else {
            throw RegistryTransportError.invalidTimeout
        }
        guard request.url.absoluteString.utf8.count <= maximumURLBytes,
              request.url.user == nil,
              request.url.password == nil,
              request.url.host != nil,
              request.url.fragment == nil else {
            throw RegistryTransportError.invalidURL
        }
        guard request.url.scheme?.lowercased() == "https" else {
            throw RegistryTransportError.insecureTransport
        }
        guard request.headers.count <= maximumHeaderCount else {
            throw RegistryTransportError.invalidHeader
        }
        var totalHeaderBytes = 0
        var normalizedNames = Set<String>()
        for (name, value) in request.headers {
            let normalizedName = name.lowercased()
            guard isValidHeaderName(name),
                  normalizedNames.insert(normalizedName).inserted,
                  !["authorization", "proxy-authorization", "cookie"].contains(normalizedName),
                  value.utf8.count <= 8 * 1_024,
                  !value.unicodeScalars.contains(where: {
                      $0.value == 0 || $0.value == 10 || $0.value == 13
                  }) else {
                throw RegistryTransportError.invalidHeader
            }
            totalHeaderBytes += name.utf8.count + value.utf8.count
            guard totalHeaderBytes <= maximumHeaderBytes else {
                throw RegistryTransportError.invalidHeader
            }
        }
        if let body = request.body, body.count > maximumRequestBodyBytes {
            throw RegistryTransportError.requestBodyTooLarge
        }
    }

    private static func isValidHeaderName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else {
            return false
        }
        let separators = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t")
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII &&
                scalar.value > 31 &&
                scalar.value < 127 &&
                !separators.contains(scalar)
        }
    }

    static func normalizedHeaders(_ response: HTTPURLResponse) throws -> [String: String] {
        guard response.allHeaderFields.count <= maximumHeaderCount else {
            throw RegistryTransportError.responseHeadersTooLarge
        }
        var result: [String: String] = [:]
        var totalBytes = 0
        for (rawName, rawValue) in response.allHeaderFields {
            guard let name = rawName as? String else {
                throw RegistryTransportError.invalidResponse
            }
            let value = rawValue as? String ?? String(describing: rawValue)
            totalBytes += name.utf8.count + value.utf8.count
            guard totalBytes <= maximumHeaderBytes else {
                throw RegistryTransportError.responseHeadersTooLarge
            }
            result[name.lowercased()] = value
        }
        return result
    }
}

private final class RegistrySynchronousTransportCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var storedResult: Result<RegistryTransportResponse, Error>?

    var result: Result<RegistryTransportResponse, Error>? {
        lock.withLock { storedResult }
    }

    func complete(_ result: Result<RegistryTransportResponse, Error>) {
        let shouldSignal = lock.withLock {
            guard storedResult == nil else {
                return false
            }
            storedResult = result
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }

    func wait(until deadline: DispatchTime) -> DispatchTimeoutResult {
        semaphore.wait(timeout: deadline)
    }
}

struct RegistryRedirectPolicy {
    static func redirectedRequest(
        response: HTTPURLResponse,
        proposedRequest: URLRequest,
        completedRedirects: Int,
        maximumRedirects: Int
    ) throws -> URLRequest {
        guard completedRedirects < maximumRedirects,
              let sourceURL = response.url,
              let destinationURL = proposedRequest.url,
              destinationURL.scheme?.lowercased() == "https",
              sameOrigin(sourceURL, destinationURL) else {
            throw RegistryTransportError.redirectRejected
        }
        return proposedRequest
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased() else {
            return false
        }
        return effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return nil
        }
    }
}

private final class RegistryURLSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumResponseBodyBytes: Int
    private let maximumHeaderBytes: Int
    private let maximumHeaderCount: Int
    private let maximumRedirects: Int

    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var responseData = Data()
    private var failure: RegistryTransportError?
    private var completedRedirects = 0
    private var completed = false
    private var cancellationRequested = false

    init(
        maximumResponseBodyBytes: Int,
        maximumHeaderBytes: Int,
        maximumHeaderCount: Int,
        maximumRedirects: Int
    ) {
        self.maximumResponseBodyBytes = maximumResponseBodyBytes
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumHeaderCount = maximumHeaderCount
        self.maximumRedirects = maximumRedirects
    }

    func perform(
        session: URLSession,
        request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let shouldCancel = lock.withLock {
                    self.continuation = continuation
                    self.task = task
                    return cancellationRequested
                }
                if shouldCancel {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            let task = self.lock.withLock {
                self.cancellationRequested = true
                self.failure = .cancelled
                return self.task
            }
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        lock.withLock {
            do {
                let redirected = try RegistryRedirectPolicy.redirectedRequest(
                    response: response,
                    proposedRequest: request,
                    completedRedirects: completedRedirects,
                    maximumRedirects: maximumRedirects
                )
                completedRedirects += 1
                return redirected
            } catch {
                failure = .redirectRejected
                return nil
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            lock.withLock { failure = .invalidResponse }
            completionHandler(.cancel)
            return
        }
        do {
            try validateHeaders(httpResponse)
            lock.withLock { self.response = httpResponse }
            completionHandler(.allow)
        } catch let error as RegistryTransportError {
            lock.withLock { failure = error }
            completionHandler(.cancel)
        } catch {
            lock.withLock { failure = .invalidResponse }
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let exceeded = lock.withLock {
            guard failure == nil else {
                return false
            }
            guard responseData.count <= maximumResponseBodyBytes - data.count else {
                failure = .responseBodyTooLarge
                return true
            }
            responseData.append(data)
            return false
        }
        if exceeded {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let resolution: (
            CheckedContinuation<(Data, HTTPURLResponse), Error>?,
            Result<(Data, HTTPURLResponse), Error>
        ) = lock.withLock {
            guard !completed else {
                return (nil, .failure(RegistryTransportError.transportFailed))
            }
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            if let failure {
                return (continuation, .failure(failure))
            }
            if let error = error as? URLError {
                switch error.code {
                case .timedOut:
                    return (continuation, .failure(RegistryTransportError.timedOut))
                case .cancelled:
                    return (
                        continuation,
                        .failure(
                            cancellationRequested
                                ? RegistryTransportError.cancelled
                                : RegistryTransportError.transportFailed
                        )
                    )
                default:
                    return (continuation, .failure(RegistryTransportError.transportFailed))
                }
            }
            if error != nil {
                return (continuation, .failure(RegistryTransportError.transportFailed))
            }
            guard let response else {
                return (continuation, .failure(RegistryTransportError.invalidResponse))
            }
            return (continuation, .success((responseData, response)))
        }
        guard let continuation = resolution.0 else {
            return
        }
        switch resolution.1 {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func validateHeaders(_ response: HTTPURLResponse) throws {
        guard response.allHeaderFields.count <= maximumHeaderCount else {
            throw RegistryTransportError.responseHeadersTooLarge
        }
        var byteCount = 0
        for (name, value) in response.allHeaderFields {
            byteCount += String(describing: name).utf8.count
            byteCount += String(describing: value).utf8.count
            guard byteCount <= maximumHeaderBytes else {
                throw RegistryTransportError.responseHeadersTooLarge
            }
        }
    }
}
