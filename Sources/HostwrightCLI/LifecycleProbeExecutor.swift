import Darwin
import Foundation
import HostwrightReconciler
import HostwrightRuntime

protocol LifecycleProbeInteractiveExecuting: Sendable {
    func executeProbeCommand(
        resourceIdentifier: String,
        arguments: [String],
        workingDirectory: String?,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        timeoutMilliseconds: Int,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) async throws -> RuntimeInteractiveExecutionResult
}

struct AppleContainerLifecycleProbeInteractiveExecutor:
    LifecycleProbeInteractiveExecuting,
    Sendable
{
    let executor: AppleContainerInteractiveExecutor

    init(executor: AppleContainerInteractiveExecutor = AppleContainerInteractiveExecutor()) {
        self.executor = executor
    }

    func executeProbeCommand(
        resourceIdentifier: String,
        arguments: [String],
        workingDirectory: String?,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        timeoutMilliseconds: Int,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) async throws -> RuntimeInteractiveExecutionResult {
        try await executor.execute(
            .exec(
                resourceIdentifier: resourceIdentifier,
                arguments: arguments,
                interactive: false,
                tty: false,
                workingDirectory: workingDirectory
            ),
            capabilitySnapshot: capabilitySnapshot,
            timeoutMilliseconds: timeoutMilliseconds,
            sink: sink
        )
    }
}

protocol LifecycleProbeNetworkRequesting: Sendable {
    func httpStatusCode(
        at url: URL,
        timeoutMilliseconds: Int,
        maximumRedirects: Int
    ) async throws -> Int

    func connectTCP(
        host: String,
        port: Int,
        timeoutMilliseconds: Int
    ) async throws
}

enum LifecycleProbeTransportError: Error, Equatable, Sendable {
    case invalidLoopbackEndpoint
    case invalidHTTPResponse
    case connectionFailed
    case timedOut
    case cancelled
    case outputLimitExceeded
}

struct LifecycleProbeLoopbackOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http",
              let rawHost = url.host?.lowercased(),
              Self.isLoopback(rawHost),
              url.user == nil,
              url.password == nil else {
            return nil
        }
        self.scheme = scheme
        self.host = rawHost
        self.port = url.port ?? 80
    }

    func validateRedirect(
        to url: URL,
        completedRedirects: Int,
        maximumRedirects: Int
    ) throws {
        guard completedRedirects < maximumRedirects else {
            throw RuntimeProbeValidationError.redirectLimitExceeded
        }
        guard let target = LifecycleProbeLoopbackOrigin(url: url) else {
            throw RuntimeProbeValidationError.redirectNotLoopback
        }
        guard target == self else {
            throw RuntimeProbeValidationError.redirectChangedOrigin
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "::1", "localhost"].contains(host.lowercased())
    }

    static func canonicalHost(_ host: String) -> String {
        host.lowercased() == "localhost" ? "127.0.0.1" : host.lowercased()
    }
}

struct SystemLifecycleProbeNetworkClient: LifecycleProbeNetworkRequesting, Sendable {
    func httpStatusCode(
        at url: URL,
        timeoutMilliseconds: Int,
        maximumRedirects: Int
    ) async throws -> Int {
        guard timeoutMilliseconds > 0,
              maximumRedirects >= 0,
              let origin = LifecycleProbeLoopbackOrigin(url: url) else {
            throw LifecycleProbeTransportError.invalidLoopbackEndpoint
        }

        let redirectDelegate = LifecycleProbeRedirectDelegate(
            origin: origin,
            maximumRedirects: maximumRedirects
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest =
            TimeInterval(timeoutMilliseconds) / 1_000
        configuration.timeoutIntervalForResource =
            TimeInterval(timeoutMilliseconds) / 1_000

        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = TimeInterval(timeoutMilliseconds) / 1_000

        do {
            let (bytes, response) = try await session.bytes(
                for: request,
                delegate: redirectDelegate
            )
            if let redirectError = redirectDelegate.failure {
                throw redirectError
            }
            guard let response = response as? HTTPURLResponse,
                  let responseURL = response.url,
                  LifecycleProbeLoopbackOrigin(url: responseURL) == origin else {
                throw LifecycleProbeTransportError.invalidHTTPResponse
            }

            // Read at most one response byte so a workload cannot make a probe buffer its body.
            for try await _ in bytes.prefix(1) {
                break
            }
            return response.statusCode
        } catch is CancellationError {
            throw LifecycleProbeTransportError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            if Task.isCancelled {
                throw LifecycleProbeTransportError.cancelled
            }
            throw LifecycleProbeTransportError.connectionFailed
        } catch let error as URLError where error.code == .timedOut {
            throw LifecycleProbeTransportError.timedOut
        }
    }

    func connectTCP(
        host: String,
        port: Int,
        timeoutMilliseconds: Int
    ) async throws {
        guard timeoutMilliseconds > 0,
              (1 ... 65_535).contains(port),
              LifecycleProbeLoopbackOrigin.isLoopback(host) else {
            throw LifecycleProbeTransportError.invalidLoopbackEndpoint
        }

        let canonicalHost = LifecycleProbeLoopbackOrigin.canonicalHost(host)
        let connectionTask = Task.detached(priority: nil) {
            try Self.connectSocket(
                host: canonicalHost,
                port: port,
                timeoutMilliseconds: timeoutMilliseconds
            )
        }
        do {
            try await withTaskCancellationHandler {
                try await connectionTask.value
            } onCancel: {
                connectionTask.cancel()
            }
        } catch is CancellationError {
            throw LifecycleProbeTransportError.cancelled
        }
    }

    private static func connectSocket(
        host: String,
        port: Int,
        timeoutMilliseconds: Int
    ) throws {
        try Task.checkCancellation()
        let family = host == "::1" ? AF_INET6 : AF_INET
        let descriptor = Darwin.socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LifecycleProbeTransportError.connectionFailed
        }
        defer { Darwin.close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw LifecycleProbeTransportError.connectionFailed
        }

        let result: Int32
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else {
                throw LifecycleProbeTransportError.invalidLoopbackEndpoint
            }
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in6>.size)
                    )
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                throw LifecycleProbeTransportError.invalidLoopbackEndpoint
            }
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }

        if result == 0 {
            return
        }
        guard errno == EINPROGRESS else {
            throw LifecycleProbeTransportError.connectionFailed
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let timeoutNanoseconds = UInt64(timeoutMilliseconds) * 1_000_000
        while true {
            try Task.checkCancellation()
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            guard elapsed < timeoutNanoseconds else {
                throw LifecycleProbeTransportError.timedOut
            }
            let remainingMilliseconds = max(
                1,
                Int((timeoutNanoseconds - elapsed) / 1_000_000)
            )
            var readiness = pollfd(
                fd: descriptor,
                events: Int16(POLLOUT),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &readiness,
                1,
                Int32(min(remainingMilliseconds, 50))
            )
            if pollResult < 0, errno == EINTR {
                continue
            }
            guard pollResult >= 0 else {
                throw LifecycleProbeTransportError.connectionFailed
            }
            guard pollResult > 0 else {
                continue
            }

            var socketError: Int32 = 0
            var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &socketErrorSize
            ) == 0,
                socketError == 0 else {
                throw LifecycleProbeTransportError.connectionFailed
            }
            return
        }
    }
}

private final class LifecycleProbeRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let origin: LifecycleProbeLoopbackOrigin
    private let maximumRedirects: Int
    private let lock = NSLock()
    private var completedRedirects = 0
    private var storedFailure: (any Error)?

    init(origin: LifecycleProbeLoopbackOrigin, maximumRedirects: Int) {
        self.origin = origin
        self.maximumRedirects = maximumRedirects
    }

    var failure: (any Error)? {
        lock.withLock { storedFailure }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let accepted = lock.withLock { () -> Bool in
            do {
                guard let url = request.url else {
                    throw LifecycleProbeTransportError.invalidHTTPResponse
                }
                try origin.validateRedirect(
                    to: url,
                    completedRedirects: completedRedirects,
                    maximumRedirects: maximumRedirects
                )
                completedRedirects += 1
                return true
            } catch {
                storedFailure = error
                return false
            }
        }
        completionHandler(accepted ? request : nil)
    }
}

struct LifecycleProbeExecutor: RuntimeProbeExecuting, Sendable {
    static let maximumDiscardedExecOutputBytes = 1 * 1_024 * 1_024
    static let maximumRedirects = 3

    let binding: LifecycleResourceBinding
    let desiredService: DesiredRuntimeService
    let capabilitySnapshot: RuntimeCapabilitySnapshot
    let probeCapabilities: RuntimeProbeCapabilities
    let interactiveExecutor: any LifecycleProbeInteractiveExecuting
    let networkClient: any LifecycleProbeNetworkRequesting
    let nowMilliseconds: @Sendable () -> Int64

    init(
        binding: LifecycleResourceBinding,
        desiredService: DesiredRuntimeService,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        probeCapabilities: RuntimeProbeCapabilities? = nil,
        interactiveExecutor: any LifecycleProbeInteractiveExecuting =
            AppleContainerLifecycleProbeInteractiveExecutor(),
        networkClient: any LifecycleProbeNetworkRequesting =
            SystemLifecycleProbeNetworkClient(),
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.binding = binding
        self.desiredService = desiredService
        self.capabilitySnapshot = capabilitySnapshot
        self.probeCapabilities = probeCapabilities ??
            Self.defaultCapabilities(for: capabilitySnapshot)
        self.interactiveExecutor = interactiveExecutor
        self.networkClient = networkClient
        self.nowMilliseconds = nowMilliseconds
    }

    func executeProbe(_ request: RuntimeProbeExecutionRequest) async
        -> RuntimeProbeAttemptResult
    {
        if Task.isCancelled {
            return result(.cancelled, "Probe execution was cancelled.")
        }
        guard binding.resourceIdentifier == request.resourceIdentifier,
              binding.identity == desiredService.identity,
              binding.providerID == capabilitySnapshot.descriptor.providerID else {
            return result(
                .unavailable,
                "Probe target is not the configured exact owned resource."
            )
        }
        guard capabilitySnapshot.descriptor.providerID == .appleContainerCLI else {
            return result(
                .unavailable,
                "The selected provider has not qualified Phase 04 probe execution."
            )
        }
        guard let configured = desiredService.probes[request.kind],
              configured.action == request.action,
              configured.timeoutSeconds == request.timeoutSeconds,
              request.attempt > 0 else {
            return result(
                .unavailable,
                "Probe request does not match the configured desired service."
            )
        }
        guard let capability = probeCapabilities.status(for: request.action.kind),
              capability.state == .available,
              capability.reason == .implemented else {
            return result(
                .unavailable,
                "The selected provider does not advertise this probe action."
            )
        }

        do {
            try RuntimeProbeValidator.validate(
                configured,
                declaredContainerPorts: Set(desiredService.ports.map(\.containerPort))
            )
            switch request.action {
            case .exec(let action):
                return try await executeCommand(action, request: request)
            case .http(let action):
                return try await executeHTTP(action, request: request)
            case .tcp(let action):
                return try await executeTCP(action, request: request)
            }
        } catch {
            return map(error)
        }
    }

    private func executeCommand(
        _ action: RuntimeProbeExecAction,
        request: RuntimeProbeExecutionRequest
    ) async throws -> RuntimeProbeAttemptResult {
        let contract = RuntimeInteractiveCapabilityContract(snapshot: capabilitySnapshot)
        guard contract.availableOperations.contains(.exec) else {
            return result(
                .unavailable,
                contract.unavailableReasons[.exec] ??
                    "The selected provider does not advertise container exec."
            )
        }

        let budget = LifecycleProbeOutputBudget(
            maximumBytes: Self.maximumDiscardedExecOutputBytes
        )
        let execution = try await interactiveExecutor.executeProbeCommand(
            resourceIdentifier: binding.resourceIdentifier,
            arguments: action.command,
            workingDirectory: desiredService.workingDirectory,
            capabilitySnapshot: capabilitySnapshot,
            timeoutMilliseconds: request.timeoutSeconds * 1_000
        ) { frame in
            try budget.consume(frame.payload.count)
        }
        guard execution.exitStatus == 0 else {
            return result(
                .failed,
                execution.standardErrorTail.isEmpty
                    ? "Container exec probe exited unsuccessfully."
                    : execution.standardErrorTail
            )
        }
        return result(.succeeded)
    }

    private func executeHTTP(
        _ action: RuntimeProbeHTTPAction,
        request: RuntimeProbeExecutionRequest
    ) async throws -> RuntimeProbeAttemptResult {
        guard let endpoint = loopbackEndpoint(
            forContainerPort: action.port,
            requiredProtocol: .tcp
        ),
            let url = endpoint.httpURL(path: action.path) else {
            return result(
                .unavailable,
                "HTTP probe requires one explicit loopback host-port mapping."
            )
        }
        let status = try await networkClient.httpStatusCode(
            at: url,
            timeoutMilliseconds: request.timeoutSeconds * 1_000,
            maximumRedirects: Self.maximumRedirects
        )
        guard (200 ... 399).contains(status) else {
            return result(.failed, "HTTP probe returned status \(status).")
        }
        return result(.succeeded)
    }

    private func executeTCP(
        _ action: RuntimeProbeTCPAction,
        request: RuntimeProbeExecutionRequest
    ) async throws -> RuntimeProbeAttemptResult {
        guard let endpoint = loopbackEndpoint(
            forContainerPort: action.port,
            requiredProtocol: .tcp
        ) else {
            return result(
                .unavailable,
                "TCP probe requires one explicit loopback host-port mapping."
            )
        }
        try await networkClient.connectTCP(
            host: endpoint.host,
            port: endpoint.port,
            timeoutMilliseconds: request.timeoutSeconds * 1_000
        )
        return result(.succeeded)
    }

    private func loopbackEndpoint(
        forContainerPort containerPort: Int,
        requiredProtocol: RuntimePortProtocol
    ) -> LifecycleProbeLoopbackEndpoint? {
        let matches = desiredService.ports.filter {
            $0.containerPort == containerPort &&
                $0.protocolName == requiredProtocol &&
                $0.hostPort != nil &&
                $0.bindAddress.map(LifecycleProbeLoopbackOrigin.isLoopback) == true
        }
        guard matches.count == 1,
              let hostPort = matches[0].hostPort,
              let bindAddress = matches[0].bindAddress,
              (1 ... 65_535).contains(hostPort) else {
            return nil
        }
        return LifecycleProbeLoopbackEndpoint(
            host: LifecycleProbeLoopbackOrigin.canonicalHost(bindAddress),
            port: hostPort
        )
    }

    private func map(_ error: any Error) -> RuntimeProbeAttemptResult {
        if error is CancellationError ||
            error as? LifecycleProbeTransportError == .cancelled ||
            error as? RuntimeInteractiveError == .processCancelled {
            return result(.cancelled, "Probe execution was cancelled.")
        }
        if error as? LifecycleProbeTransportError == .timedOut ||
            error as? RuntimeInteractiveError == .processTimedOut {
            return result(.timedOut, "Probe execution timed out.")
        }
        if case .capabilityUnavailable(_, let reason) =
            error as? RuntimeInteractiveError {
            return result(.unavailable, reason)
        }
        if error as? LifecycleProbeTransportError == .outputLimitExceeded {
            return result(
                .failed,
                "Probe output exceeded the bounded discard limit."
            )
        }
        return result(
            .failed,
            RuntimeRedactionPolicy.default.redact(String(describing: error))
        )
    }

    private func result(
        _ outcome: RuntimeProbeAttemptOutcome,
        _ diagnostic: String = ""
    ) -> RuntimeProbeAttemptResult {
        RuntimeProbeAttemptResult(
            outcome: outcome,
            completedAtMilliseconds: nowMilliseconds(),
            diagnosticRedacted: RuntimeRedactionPolicy.default.redact(diagnostic)
        )
    }

    private static func defaultCapabilities(
        for snapshot: RuntimeCapabilitySnapshot
    ) -> RuntimeProbeCapabilities {
        guard snapshot.descriptor.providerID == .appleContainerCLI else {
            return .allUnavailable(
                for: snapshot.descriptor.providerID,
                reason: .qualificationIncomplete
            )
        }
        let featureStatuses = Dictionary(
            grouping: snapshot.features,
            by: \.feature
        )
        func featureAvailable(_ feature: RuntimeProviderFeature) -> Bool {
            guard let statuses = featureStatuses[feature],
                  statuses.count == 1,
                  statuses[0].state == .available,
                  statuses[0].reason == .implemented else {
                return false
            }
            return true
        }

        var qualified = Set<RuntimeProbeActionKind>()
        if featureAvailable(.processControl) {
            qualified.insert(.exec)
        }
        if featureAvailable(.observation), featureAvailable(.lifecycle) {
            qualified.formUnion([.http, .tcp])
        }
        return .qualified(
            for: snapshot.descriptor.providerID,
            qualified
        )
    }
}

private struct LifecycleProbeLoopbackEndpoint: Equatable, Sendable {
    let host: String
    let port: Int

    func httpURL(path: String) -> URL? {
        let authority = host == "::1" ? "[::1]" : host
        guard let url = URL(string: "http://\(authority):\(port)\(path)"),
              LifecycleProbeLoopbackOrigin(url: url) != nil else {
            return nil
        }
        return url
    }
}

private final class LifecycleProbeOutputBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var consumedBytes = 0

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func consume(_ count: Int) throws {
        try lock.withLock {
            guard count >= 0,
                  consumedBytes <= maximumBytes - count else {
                throw LifecycleProbeTransportError.outputLimitExceeded
            }
            consumedBytes += count
        }
    }
}
