import Foundation

public protocol RuntimeHealthChecking: Sendable {
    func check(identity: RuntimeServiceIdentity, spec: RuntimeHealthCheckSpec) async -> RuntimeHealthCheckResult
}

public struct RuntimeHealthURLResponse: Equatable, Sendable {
    public let statusCode: Int
    public let body: String

    public init(statusCode: Int, body: String = "") {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol RuntimeHealthURLFetching: Sendable {
    func fetch(url: URL, timeout: RuntimeCommandTimeout) async throws -> RuntimeHealthURLResponse
}

public struct URLSessionRuntimeHealthURLFetcher: RuntimeHealthURLFetching {
    public init() {}

    public func fetch(url: URL, timeout: RuntimeCommandTimeout) async throws -> RuntimeHealthURLResponse {
        let url = try RuntimeHealthCommandPolicy.validatedLoopbackHTTPURL(url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = TimeInterval(timeout.seconds)
        configuration.timeoutIntervalForResource = TimeInterval(timeout.seconds)
        configuration.urlCache = nil

        let session = URLSession(configuration: configuration, delegate: RejectingRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeout.seconds))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "Health check URL did not return an HTTP response."
            )
        }

        return RuntimeHealthURLResponse(
            statusCode: httpResponse.statusCode,
            body: String(data: data.prefix(1024), encoding: .utf8) ?? ""
        )
    }
}

final class RejectingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

public enum RuntimeHealthCommandPolicy {
    public static let allowedExecutableNames: Set<String> = ["curl", "false", "true", "wget"]
    private static let curlAllowedLongFlags: Set<String> = ["--fail", "--head", "--show-error", "--silent"]
    private static let curlAllowedShortFlagCharacters: Set<Character> = ["I", "S", "f", "s"]
    private static let wgetAllowedFlags: Set<String> = ["--quiet", "--spider", "-q"]

    public static func validate(_ command: [String]) throws {
        guard let executableName = command.first, !executableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeAdapterError.commandRejected(classification: .readOnly, message: "Health command must include an executable name.")
        }

        for token in command where token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || token.contains("\0") || token.contains("\n") {
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "Health command tokens must not be empty or contain null bytes or newlines."
            )
        }

        guard !executableName.contains("/"), !executableName.hasPrefix("-") else {
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "Health command executable must be a bare supported probe name."
            )
        }

        guard allowedExecutableNames.contains(executableName) else {
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "Health command executable '\(executableName)' is not allowed for bounded local health checks."
            )
        }

        switch executableName {
        case "true", "false":
            try validateNoArgumentProbe(command)
        case "curl":
            try validateCurlArguments(Array(command.dropFirst()))
        case "wget":
            try validateWgetArguments(Array(command.dropFirst()))
        default:
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "Health command executable '\(executableName)' is not allowed for bounded local health checks."
            )
        }
    }

    public static func loopbackURL(from command: [String]) throws -> URL? {
        try validate(command)
        guard command[0] == "curl" || command[0] == "wget" else {
            return nil
        }

        for argument in command.dropFirst() where !argument.hasPrefix("-") {
            return try validatedLoopbackHTTPURL(argument)
        }

        return nil
    }

    private static func validateNoArgumentProbe(_ command: [String]) throws {
        guard command.count == 1 else {
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "Health command executable '\(command[0])' does not accept arguments in bounded local health checks."
            )
        }
    }

    private static func validateCurlArguments(_ arguments: [String]) throws {
        var urlCount = 0

        for argument in arguments {
            if argument.hasPrefix("-") {
                guard isAllowedCurlFlag(argument) else {
                    throw RuntimeAdapterError.commandRejected(
                        classification: .readOnly,
                        message: "curl health checks accept only no-output status flags and one loopback HTTP(S) URL."
                    )
                }
            } else {
                _ = try validatedLoopbackHTTPURL(argument)
                urlCount += 1
            }
        }

        guard urlCount == 1 else {
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "curl health checks must include exactly one loopback HTTP(S) URL."
            )
        }
    }

    private static func validateWgetArguments(_ arguments: [String]) throws {
        var hasSpiderFlag = false
        var urlCount = 0

        for argument in arguments {
            if argument.hasPrefix("-") {
                guard wgetAllowedFlags.contains(argument) else {
                    throw RuntimeAdapterError.commandRejected(
                        classification: .readOnly,
                        message: "wget health checks accept only --spider, quiet flags, and one loopback HTTP(S) URL."
                    )
                }
                hasSpiderFlag = hasSpiderFlag || argument == "--spider"
            } else {
                _ = try validatedLoopbackHTTPURL(argument)
                urlCount += 1
            }
        }

        guard hasSpiderFlag, urlCount == 1 else {
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "wget health checks must use --spider with exactly one loopback HTTP(S) URL."
            )
        }
    }

    private static func isAllowedCurlFlag(_ argument: String) -> Bool {
        if argument.hasPrefix("--") {
            return curlAllowedLongFlags.contains(argument)
        }

        let characters = argument.dropFirst()
        guard !characters.isEmpty else {
            return false
        }
        return characters.allSatisfy { curlAllowedShortFlagCharacters.contains($0) }
    }

    static func validatedLoopbackHTTPURL(_ url: URL) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "Health check URLs must be HTTP(S) loopback URLs."
            )
        }

        return try validatedLoopbackHTTPURL(components)
    }

    private static func validatedLoopbackHTTPURL(_ rawValue: String) throws -> URL {
        guard let components = URLComponents(string: rawValue),
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "Health check URLs must be HTTP(S) loopback URLs."
            )
        }

        return try validatedLoopbackHTTPURL(components)
    }

    private static func validatedLoopbackHTTPURL(_ components: URLComponents) throws -> URL {
        guard let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.user == nil,
              components.password == nil,
              let url = components.url,
              isLoopbackHost(host) else {
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "Health check URLs must be HTTP(S) loopback URLs."
            )
        }

        if let port = components.port, !(1 ... 65_535).contains(port) {
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "Health check URL ports must be between 1 and 65535."
            )
        }

        return url
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

public struct BoundedRuntimeHealthChecker: RuntimeHealthChecking {
    private let urlFetcher: any RuntimeHealthURLFetching
    private let redactionPolicy: RuntimeRedactionPolicy

    public init(
        urlFetcher: any RuntimeHealthURLFetching = URLSessionRuntimeHealthURLFetcher(),
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.urlFetcher = urlFetcher
        self.redactionPolicy = redactionPolicy
    }

    public func check(identity: RuntimeServiceIdentity, spec: RuntimeHealthCheckSpec) async -> RuntimeHealthCheckResult {
        do {
            try RuntimeHealthCommandPolicy.validate(spec.command)
            switch spec.command[0] {
            case "true":
                return directResult(identity: identity, spec: spec, status: .healthy, exitStatus: 0)
            case "false":
                return directResult(identity: identity, spec: spec, status: .unhealthy, exitStatus: 1)
            case "curl", "wget":
                return try await urlResult(identity: identity, spec: spec)
            default:
                throw RuntimeAdapterError.commandRejected(
                    classification: .readOnly,
                    message: "Health command executable '\(spec.command[0])' is not allowed for bounded local health checks."
                )
            }
        } catch let error as RuntimeAdapterError {
            return failedResult(identity: identity, command: spec.command, error: error.redacted(using: redactionPolicy))
        } catch let error as URLError where error.code == .timedOut {
            return RuntimeHealthCheckResult(
                identity: identity,
                status: .unhealthy,
                exitStatus: nil,
                timedOut: true,
                command: redactionPolicy.redact(arguments: spec.command),
                standardOutput: "",
                standardError: "Health check timed out."
            )
        } catch {
            return RuntimeHealthCheckResult(
                identity: identity,
                status: .unhealthy,
                exitStatus: nil,
                timedOut: false,
                command: redactionPolicy.redact(arguments: spec.command),
                standardOutput: "",
                standardError: redactionPolicy.redact(String(describing: error))
            )
        }
    }

    private func directResult(
        identity: RuntimeServiceIdentity,
        spec: RuntimeHealthCheckSpec,
        status: RuntimeHealthCheckStatus,
        exitStatus: Int32
    ) -> RuntimeHealthCheckResult {
        RuntimeHealthCheckResult(
            identity: identity,
            status: status,
            exitStatus: exitStatus,
            timedOut: false,
            command: redactionPolicy.redact(arguments: spec.command),
            standardOutput: "",
            standardError: ""
        )
    }

    private func urlResult(identity: RuntimeServiceIdentity, spec: RuntimeHealthCheckSpec) async throws -> RuntimeHealthCheckResult {
        guard let url = try RuntimeHealthCommandPolicy.loopbackURL(from: spec.command) else {
            throw RuntimeAdapterError.commandRejected(classification: .readOnly, message: "Health command did not include a loopback HTTP(S) URL.")
        }

        let response = try await urlFetcher.fetch(url: url, timeout: spec.timeout)
        let healthy = (200 ... 299).contains(response.statusCode)
        let output = response.body.isEmpty ? "HTTP \(response.statusCode)" : response.body
        return RuntimeHealthCheckResult(
            identity: identity,
            status: healthy ? .healthy : .unhealthy,
            exitStatus: healthy ? 0 : Int32(response.statusCode),
            timedOut: false,
            command: redactionPolicy.redact(arguments: spec.command),
            standardOutput: redactionPolicy.redact(output),
            standardError: healthy ? "" : "HTTP status \(response.statusCode)"
        )
    }

    private func failedResult(identity: RuntimeServiceIdentity, command: [String], error: RuntimeAdapterError) -> RuntimeHealthCheckResult {
        switch error {
        case .commandFailed(let exitStatus, let message, let standardError):
            return RuntimeHealthCheckResult(
                identity: identity,
                status: .unhealthy,
                exitStatus: exitStatus,
                timedOut: false,
                command: redactionPolicy.redact(arguments: command),
                standardOutput: "",
                standardError: [message, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
            )
        case .commandTimedOut(_, let partialOutput, let partialError):
            return RuntimeHealthCheckResult(
                identity: identity,
                status: .unhealthy,
                exitStatus: nil,
                timedOut: true,
                command: redactionPolicy.redact(arguments: command),
                standardOutput: partialOutput,
                standardError: partialError
            )
        default:
            return RuntimeHealthCheckResult(
                identity: identity,
                status: .unknown,
                exitStatus: nil,
                timedOut: false,
                command: redactionPolicy.redact(arguments: command),
                standardOutput: "",
                standardError: String(describing: error)
            )
        }
    }
}
