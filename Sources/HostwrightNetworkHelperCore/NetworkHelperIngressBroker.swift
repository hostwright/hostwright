import CryptoKit
import Darwin
import Foundation
import HostwrightNetworking

final class NetworkHelperIngressBroker: @unchecked Sendable {
    private struct Group {
        let identity: NetworkHelperDNSIdentity
        let bindings: [ProjectIngressListenerBinding]
        let sha256: String
        let configuration: NetworkHelperIngressConfiguration
        let listeners: [String: NetworkHelperIngressListener]
    }

    private let mutationLock = NSLock()
    private let lock = NSLock()
    private var groups: [String: Group] = [:]
    private var accessLogs:
        [String: [NetworkHelperIngressAccessLogEntry]] = [:]

    func apply(
        identity: NetworkHelperDNSIdentity,
        bindings: [ProjectIngressListenerBinding]
    ) throws -> String? {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let identity = try identity.validated()
        let bindings = try NetworkHelperIngressValidation.validated(
            bindings
        )
        guard !bindings.isEmpty else {
            removeLocked(identity: identity)
            return nil
        }
        let data = try NetworkHelperCanonicalJSON.encode(bindings)
        let digest = Self.sha256(data)
        let groupKey = Self.groupKey(identity)

        lock.lock()
        if let existing = groups[groupKey],
           existing.identity == identity,
           existing.sha256 == digest {
            lock.unlock()
            return digest
        }
        let occupied = Set(
            groups
                .filter { $0.key != groupKey }
                .flatMap { $0.value.bindings.map(Self.listenerKey) }
        )
        guard Set(bindings.map(Self.listenerKey))
            .isDisjoint(with: occupied) else {
            lock.unlock()
            throw NetworkHelperError.bindingUnavailable
        }
        let previous = groups[groupKey]
        lock.unlock()

        let previousByEndpoint = previous?.listeners ?? [:]
        let configuration = previous?.configuration ??
            NetworkHelperIngressConfiguration(
                sha256: digest,
                bindings: bindings
            )
        var created: [NetworkHelperIngressListener] = []
        var next: [String: NetworkHelperIngressListener] = [:]
        do {
            for binding in bindings {
                let endpoint = Self.listenerKey(binding)
                if let reusable = previousByEndpoint[endpoint] {
                    next[endpoint] = reusable
                } else {
                    let listener = try NetworkHelperIngressListener(
                        binding: binding,
                        endpoint: endpoint,
                        configuration: configuration,
                        accessLogger: { [weak self] entry in
                            self?.record(
                                entry,
                                identity: identity
                            )
                        }
                    )
                    created.append(listener)
                    next[endpoint] = listener
                }
            }
        } catch {
            created.forEach { $0.stop() }
            throw NetworkHelperError.bindingUnavailable
        }

        lock.lock()
        if let changed = groups[groupKey],
           changed.identity != previous?.identity ||
            changed.sha256 != previous?.sha256 {
            lock.unlock()
            created.forEach { $0.stop() }
            throw NetworkHelperError.conflict
        }
        configuration.replace(
            sha256: digest,
            bindings: bindings
        )
        if previous?.identity != identity {
            accessLogs[groupKey] = []
        }
        groups[groupKey] = Group(
            identity: identity,
            bindings: bindings,
            sha256: digest,
            configuration: configuration,
            listeners: next
        )
        lock.unlock()

        created.forEach { $0.start() }
        let retained = Set(next.keys)
        previousByEndpoint
            .filter { !retained.contains($0.key) }
            .forEach { $0.value.stop() }
        return digest
    }

    func remove(identity: NetworkHelperDNSIdentity) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        removeLocked(identity: identity)
    }

    private func removeLocked(
        identity: NetworkHelperDNSIdentity
    ) {
        let key = Self.groupKey(identity)
        lock.lock()
        let group = groups.removeValue(forKey: key)
        accessLogs.removeValue(forKey: key)
        lock.unlock()
        group?.listeners.values.forEach { $0.stop() }
    }

    func sha256(identity: NetworkHelperDNSIdentity) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let group = groups[Self.groupKey(identity)]
        guard group?.identity == identity else { return nil }
        return group?.sha256
    }

    var hasActiveBindings: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !groups.isEmpty
    }

    func accessLog(
        identity: NetworkHelperDNSIdentity
    ) -> [NetworkHelperIngressAccessLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.groupKey(identity)
        guard groups[key]?.identity == identity else { return [] }
        return accessLogs[key] ?? []
    }

    private func record(
        _ entry: NetworkHelperIngressAccessLogEntry,
        identity: NetworkHelperDNSIdentity
    ) {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.groupKey(identity)
        guard groups[key]?.identity == identity else { return }
        var entries = accessLogs[key] ?? []
        entries.append(entry)
        if entries.count >
            NetworkHelperProtocolV1.maximumIngressAccessLogEntries {
            entries.removeFirst(
                entries.count -
                    NetworkHelperProtocolV1
                        .maximumIngressAccessLogEntries
            )
        }
        accessLogs[key] = entries
    }

    private static func groupKey(
        _ identity: NetworkHelperDNSIdentity
    ) -> String {
        "\(identity.projectUUID)/\(identity.dnsUUID)"
    }

    private static func listenerKey(
        _ binding: ProjectIngressListenerBinding
    ) -> String {
        "\(binding.bindAddress):\(binding.port)"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class NetworkHelperIngressConfiguration:
    @unchecked Sendable
{
    private struct Generation {
        let sha256: String
        let bindings: [String: ProjectIngressListenerBinding]
    }

    private let lock = NSLock()
    private var generation: Generation

    init(
        sha256: String,
        bindings: [ProjectIngressListenerBinding]
    ) {
        generation = Generation(
            sha256: sha256,
            bindings: Self.index(bindings)
        )
    }

    func replace(
        sha256: String,
        bindings: [ProjectIngressListenerBinding]
    ) {
        let next = Generation(
            sha256: sha256,
            bindings: Self.index(bindings)
        )
        lock.lock()
        generation = next
        lock.unlock()
    }

    func binding(
        for endpoint: String
    ) -> ProjectIngressListenerBinding? {
        lock.lock()
        defer { lock.unlock() }
        return generation.bindings[endpoint]
    }

    private static func index(
        _ bindings: [ProjectIngressListenerBinding]
    ) -> [String: ProjectIngressListenerBinding] {
        Dictionary(uniqueKeysWithValues: bindings.map {
            ("\($0.bindAddress):\($0.port)", $0)
        })
    }
}

struct NetworkHelperIngressHTTPRequest: Equatable {
    let method: String
    let target: String
    let path: String
    let hostname: String
    let headers: [(String, String)]
    let body: Data
    let isWebSocket: Bool

    static func == (
        lhs: NetworkHelperIngressHTTPRequest,
        rhs: NetworkHelperIngressHTTPRequest
    ) -> Bool {
        lhs.method == rhs.method &&
            lhs.target == rhs.target &&
            lhs.path == rhs.path &&
            lhs.hostname == rhs.hostname &&
            lhs.headers.elementsEqual(
                rhs.headers,
                by: { $0.0 == $1.0 && $0.1 == $1.1 }
            ) &&
            lhs.body == rhs.body &&
            lhs.isWebSocket == rhs.isWebSocket
    }
}

enum NetworkHelperIngressHTTPParser {
    static func parse(
        headerData: Data,
        body: Data
    ) throws -> NetworkHelperIngressHTTPRequest {
        guard headerData.count <=
                NetworkHelperProtocolV1.maximumIngressHeaderBytes,
              let text = String(
                  data: headerData,
                  encoding: .utf8
              ),
              text.hasSuffix("\r\n\r\n") else {
            throw NetworkHelperError.invalidRequest
        }
        guard let headerText = String(
            data: headerData.dropLast(4),
            encoding: .utf8
        ) else {
            throw NetworkHelperError.invalidRequest
        }
        let lines = headerText.components(
            separatedBy: "\r\n"
        )
        guard let requestLine = lines.first,
              requestLine.utf8.count <=
                NetworkHelperProtocolV1
                    .maximumIngressRequestLineBytes else {
            throw NetworkHelperError.invalidRequest
        }
        let fields = requestLine.split(
            separator: " ",
            omittingEmptySubsequences: false
        )
        guard fields.count == 3,
              fields[2] == "HTTP/1.1" else {
            throw NetworkHelperError.invalidRequest
        }
        let method = String(fields[0])
        let target = String(fields[1])
        guard !method.isEmpty,
              method.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0 == "-")
              }),
              method == method.uppercased(),
              target.hasPrefix("/"),
              !target.hasPrefix("//"),
              !target.contains("\\"),
              target.rangeOfCharacter(
                  from: .controlCharacters
              ) == nil else {
            throw NetworkHelperError.invalidRequest
        }
        let path = String(
            target.split(
                separator: "?",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0]
        )
        guard validRequestPath(path) else {
            throw NetworkHelperError.invalidRequest
        }

        var headers: [(String, String)] = []
        var values: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  line.first != " ",
                  line.first != "\t",
                  let separator = line.firstIndex(of: ":") else {
                throw NetworkHelperError.invalidRequest
            }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard validHeaderName(String(name)),
                  value.rangeOfCharacter(
                      from: .controlCharacters
                  ) == nil else {
                throw NetworkHelperError.invalidRequest
            }
            headers.append((String(name), value))
            values[String(name), default: []].append(value)
        }
        for singleton in [
            "host", "content-length", "transfer-encoding",
            "upgrade", "sec-websocket-key", "sec-websocket-version"
        ] where values[singleton, default: []].count > 1 {
            throw NetworkHelperError.invalidRequest
        }
        guard let rawHost = values["host"]?.first,
              let hostname = canonicalHostname(rawHost),
              HostwrightHostAccessPolicy.isValidHostname(
                  hostname
              ),
              values["transfer-encoding"] == nil else {
            throw NetworkHelperError.invalidRequest
        }
        let contentLength: Int
        if let raw = values["content-length"]?.first {
            guard raw.range(
                of: "^(0|[1-9][0-9]*)$",
                options: .regularExpression
            ) != nil,
            let length = Int(raw),
            length <=
                NetworkHelperProtocolV1.maximumIngressBodyBytes else {
                throw NetworkHelperError.invalidRequest
            }
            contentLength = length
        } else {
            contentLength = 0
        }
        guard body.count == contentLength else {
            throw NetworkHelperError.invalidRequest
        }
        let connectionTokens = values["connection", default: []]
            .flatMap {
                $0.lowercased().split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            }
        let isWebSocket =
            values["upgrade"]?.first?.lowercased() == "websocket" &&
            connectionTokens.contains("upgrade")
        if values["upgrade"] != nil && !isWebSocket {
            throw NetworkHelperError.invalidRequest
        }
        if isWebSocket {
            guard method == "GET",
                  values["sec-websocket-version"]?.first == "13",
                  let key = values["sec-websocket-key"]?.first,
                  Data(base64Encoded: key)?.count == 16 else {
                throw NetworkHelperError.invalidRequest
            }
        } else if values["sec-websocket-key"] != nil ||
                    values["sec-websocket-version"] != nil {
            throw NetworkHelperError.invalidRequest
        }
        return NetworkHelperIngressHTTPRequest(
            method: method,
            target: target,
            path: path,
            hostname: hostname,
            headers: headers,
            body: body,
            isWebSocket: isWebSocket
        )
    }

    private static func validHeaderName(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = Set(
            "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz"
        )
        return value.allSatisfy { allowed.contains($0) }
    }

    private static func canonicalHostname(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "[" {
            return nil
        }
        let components = trimmed.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 1 ||
                (
                    components.count == 2 &&
                    Int(components[1]).map {
                        (1...65_535).contains($0)
                    } == true
                ) else {
            return nil
        }
        return String(components[0])
    }

    private static func validRequestPath(_ value: String) -> Bool {
        if value == "/" { return true }
        guard value.hasPrefix("/"),
              value.utf8.count <=
                NetworkHelperProtocolV1
                    .maximumIngressRequestLineBytes,
              !value.contains("%"),
              !value.contains("#"),
              !value.contains("\\"),
              value.rangeOfCharacter(
                from: .controlCharacters
              ) == nil,
              !value.contains("//") else {
            return false
        }
        return value.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

private final class NetworkHelperIngressListener:
    @unchecked Sendable
{
    private static let maximumConnections = 128
    private static let maximumChunkBytes = 64 * 1_024
    private static let connectTimeoutMilliseconds: Int64 = 5_000
    private static let idleTimeoutMilliseconds: Int64 = 30_000
    private static let drainTimeoutSeconds = 2
    private static let forcedCleanupTimeoutSeconds = 1

    private let descriptor: Int32
    private let endpoint: String
    private let configuration: NetworkHelperIngressConfiguration
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let stopped = DispatchSemaphore(value: 0)
    private let connections = DispatchGroup()
    private var running = false
    private var closed = false
    private var forceClosing = false
    private var activeConnections = 0
    private var activeDescriptors: [Int32: Set<Int32>] = [:]
    private var nextBackend = 0
    private let accessLogger:
        @Sendable (NetworkHelperIngressAccessLogEntry) -> Void

    init(
        binding: ProjectIngressListenerBinding,
        endpoint: String,
        configuration: NetworkHelperIngressConfiguration,
        accessLogger: @escaping @Sendable (
            NetworkHelperIngressAccessLogEntry
        ) -> Void
    ) throws {
        self.endpoint = endpoint
        self.configuration = configuration
        self.accessLogger = accessLogger
        queue = DispatchQueue(
            label:
                "dev.hostwright.ingress.\(binding.name).\(binding.port)",
            qos: .userInitiated
        )
        let family = binding.bindAddress.contains(":")
            ? AF_INET6
            : AF_INET
        descriptor = Darwin.socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        var succeeded = false
        defer {
            if !succeeded {
                Darwin.close(descriptor)
            }
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        #if os(macOS)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        #endif
        try Self.bind(
            descriptor,
            address: binding.bindAddress,
            port: binding.port
        )
        guard Darwin.listen(descriptor, 128) == 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(
                  descriptor,
                  F_SETFL,
                  flags | O_NONBLOCK
              ) == 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        succeeded = true
    }

    func start() {
        lock.lock()
        guard !running, !closed else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        queue.async { [self] in
            run()
            stopped.signal()
        }
    }

    func stop() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let wasRunning = running
        running = false
        lock.unlock()
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        if wasRunning {
            _ = stopped.wait(timeout: .now() + 2)
        }
        if connections.wait(
            timeout: .now() +
                .seconds(Self.drainTimeoutSeconds)
        ) == .timedOut {
            lock.lock()
            forceClosing = true
            for active in activeDescriptors.values {
                for descriptor in active {
                    _ = Darwin.shutdown(descriptor, SHUT_RDWR)
                }
            }
            lock.unlock()
            _ = connections.wait(
                timeout: .now() +
                    .seconds(Self.forcedCleanupTimeoutSeconds)
            )
        }
        Darwin.close(descriptor)
    }

    private func run() {
        while isRunning {
            guard Self.pollReadable(
                descriptor,
                milliseconds: 100
            ) else {
                continue
            }
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0,
               errno == EAGAIN || errno == EWOULDBLOCK ||
                errno == EINTR {
                continue
            }
            guard client >= 0,
                  let binding = configuration.binding(
                      for: endpoint
                  ),
                  reserveConnection(client) else {
                if client >= 0 { Darwin.close(client) }
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async {
                [self] in
                defer { finishConnection(client) }
                handle(client, binding: binding)
            }
        }
    }

    private func handle(
        _ client: Int32,
        binding: ProjectIngressListenerBinding
    ) {
        let started = Self.monotonicMilliseconds()
        let listenerName = binding.name
        guard Self.configure(client),
              let request = try? Self.readRequest(client) else {
            Self.writeError(client, status: 400, reason: "Bad Request")
            record(
                listenerName: listenerName,
                request: nil,
                route: nil,
                backend: nil,
                outcome: .rejected,
                started: started
            )
            return
        }
        guard let route = matchingRoute(
            request,
            routes: binding.routes
        ) else {
            Self.writeError(client, status: 404, reason: "Not Found")
            record(
                listenerName: listenerName,
                request: request,
                route: nil,
                backend: nil,
                outcome: .noRoute,
                started: started
            )
            return
        }
        guard !route.backends.isEmpty else {
            Self.writeError(
                client,
                status: 503,
                reason: "Service Unavailable"
            )
            record(
                listenerName: listenerName,
                request: request,
                route: route,
                backend: nil,
                outcome: .unavailable,
                started: started
            )
            return
        }
        let ordered = orderedBackends(route.backends)
        var upstream: Int32 = -1
        var selectedBackend: ProjectIngressBackend?
        for backend in ordered.prefix(2) {
            if let connected = try? connect(
                backend,
                client: client
            ) {
                upstream = connected
                selectedBackend = backend
                break
            }
        }
        guard upstream >= 0 else {
            Self.writeError(
                client,
                status: 502,
                reason: "Bad Gateway"
            )
            record(
                listenerName: listenerName,
                request: request,
                route: route,
                backend: nil,
                outcome: .upstreamFailed,
                started: started
            )
            return
        }
        defer {
            closeTrackedDescriptor(
                upstream,
                client: client
            )
        }
        guard Self.writeRequest(
            request,
            descriptor: upstream
        ) else {
            Self.writeError(
                client,
                status: 502,
                reason: "Bad Gateway"
            )
            record(
                listenerName: listenerName,
                request: request,
                route: route,
                backend: selectedBackend,
                outcome: .upstreamFailed,
                started: started
            )
            return
        }
        Self.bridge(client, upstream)
        record(
            listenerName: listenerName,
            request: request,
            route: route,
            backend: selectedBackend,
            outcome: .forwarded,
            started: started
        )
    }

    private func record(
        listenerName: String,
        request: NetworkHelperIngressHTTPRequest?,
        route: ProjectIngressRouteBinding?,
        backend: ProjectIngressBackend?,
        outcome: NetworkHelperIngressAccessOutcome,
        started: Int64
    ) {
        accessLogger(NetworkHelperIngressAccessLogEntry(
            timestampUnixMilliseconds: Int64(
                Date().timeIntervalSince1970 * 1_000
            ),
            listenerName: listenerName,
            method: request?.method,
            routeHostname: route?.hostname,
            routePathPrefix: route?.pathPrefix,
            protocolName: route?.protocolName,
            targetServiceUUID: backend?.serviceUUID,
            outcome: outcome,
            durationMilliseconds:
                Self.monotonicMilliseconds() - started
        ))
    }

    private func matchingRoute(
        _ request: NetworkHelperIngressHTTPRequest,
        routes: [ProjectIngressRouteBinding]
    ) -> ProjectIngressRouteBinding? {
        return routes.filter {
            $0.hostname == request.hostname &&
                $0.methods.contains(request.method) &&
                (
                    request.isWebSocket
                        ? $0.protocolName == .websocket
                        : $0.protocolName == .http
                ) &&
                Self.path(
                    request.path,
                    matchesPrefix: $0.pathPrefix
                )
        }.sorted {
            if $0.pathPrefix.utf8.count !=
                $1.pathPrefix.utf8.count {
                return $0.pathPrefix.utf8.count >
                    $1.pathPrefix.utf8.count
            }
            return ProjectIngressRouteBinding
                .canonicalPrecedes($0, $1)
        }.first
    }

    private func orderedBackends(
        _ backends: [ProjectIngressBackend]
    ) -> [ProjectIngressBackend] {
        lock.lock()
        let start = nextBackend % backends.count
        nextBackend = (nextBackend + 1) % backends.count
        lock.unlock()
        return Array(backends[start...]) +
            Array(backends[..<start])
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func reserveConnection(_ client: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard running,
              !closed,
              activeConnections < Self.maximumConnections else {
            return false
        }
        activeConnections += 1
        activeDescriptors[client] = [client]
        connections.enter()
        return true
    }

    private func finishConnection(_ client: Int32) {
        lock.lock()
        activeDescriptors.removeValue(forKey: client)
        Darwin.close(client)
        activeConnections = max(0, activeConnections - 1)
        lock.unlock()
        connections.leave()
    }

    private func trackUpstream(
        _ upstream: Int32,
        client: Int32
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !forceClosing,
              activeDescriptors[client] != nil else {
            return false
        }
        activeDescriptors[client]?.insert(upstream)
        return true
    }

    private func closeTrackedDescriptor(
        _ descriptor: Int32,
        client: Int32
    ) {
        lock.lock()
        activeDescriptors[client]?.remove(descriptor)
        Darwin.close(descriptor)
        lock.unlock()
    }

    private static func readRequest(
        _ descriptor: Int32
    ) throws -> NetworkHelperIngressHTTPRequest {
        let deadline = monotonicMilliseconds() + 5_000
        var data = Data()
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard data.count <
                    NetworkHelperProtocolV1
                        .maximumIngressHeaderBytes,
                  monotonicMilliseconds() < deadline,
                  pollReadable(
                      descriptor,
                      milliseconds: 100
                  ) else {
                throw NetworkHelperError.invalidRequest
            }
            var buffer = [UInt8](
                repeating: 0,
                count: maximumChunkBytes
            )
            let count = Darwin.recv(
                descriptor,
                &buffer,
                min(
                    buffer.count,
                    NetworkHelperProtocolV1
                        .maximumIngressHeaderBytes - data.count
                ),
                0
            )
            guard count > 0 else {
                throw NetworkHelperError.invalidRequest
            }
            data.append(contentsOf: buffer[0..<count])
        }
        guard let range = data.range(
            of: Data("\r\n\r\n".utf8)
        ) else {
            throw NetworkHelperError.invalidRequest
        }
        let header = data[..<range.upperBound]
        var body = Data(data[range.upperBound...])
        let expected = try expectedBodyLength(Data(header))
        guard expected <=
                NetworkHelperProtocolV1.maximumIngressBodyBytes,
              body.count <= expected else {
            throw NetworkHelperError.invalidRequest
        }
        while body.count < expected {
            guard monotonicMilliseconds() < deadline,
                  pollReadable(
                      descriptor,
                      milliseconds: 100
                  ) else {
                throw NetworkHelperError.invalidRequest
            }
            var buffer = [UInt8](
                repeating: 0,
                count: min(maximumChunkBytes, expected - body.count)
            )
            let count = Darwin.recv(
                descriptor,
                &buffer,
                buffer.count,
                0
            )
            guard count > 0 else {
                throw NetworkHelperError.invalidRequest
            }
            body.append(contentsOf: buffer[0..<count])
        }
        return try NetworkHelperIngressHTTPParser.parse(
            headerData: Data(header),
            body: body
        )
    }

    private static func expectedBodyLength(
        _ header: Data
    ) throws -> Int {
        guard let text = String(data: header, encoding: .utf8)
        else {
            throw NetworkHelperError.invalidRequest
        }
        let values = text.components(separatedBy: "\r\n")
            .dropFirst()
            .compactMap { line -> String? in
                let lower = line.lowercased()
                guard lower.hasPrefix("content-length:") else {
                    return nil
                }
                return line.split(
                    separator: ":",
                    maxSplits: 1
                ).last.map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            }
        guard values.count <= 1 else {
            throw NetworkHelperError.invalidRequest
        }
        guard let raw = values.first else { return 0 }
        guard raw.range(
            of: "^(0|[1-9][0-9]*)$",
            options: .regularExpression
        ) != nil,
        let value = Int(raw) else {
            throw NetworkHelperError.invalidRequest
        }
        return value
    }

    private static func writeRequest(
        _ request: NetworkHelperIngressHTTPRequest,
        descriptor: Int32
    ) -> Bool {
        var lines = [
            "\(request.method) \(request.target) HTTP/1.1"
        ]
        for (name, value) in request.headers
        where name != "proxy-connection" {
            lines.append("\(name): \(value)")
        }
        let data = Data(
            (
                lines.joined(separator: "\r\n") +
                    "\r\n\r\n"
            ).utf8
        ) + request.body
        return writeAll(descriptor, data: data)
    }

    private func connect(
        _ backend: ProjectIngressBackend,
        client: Int32
    ) throws -> Int32 {
        let family = backend.address.contains(":")
            ? AF_INET6
            : AF_INET
        let descriptor = Darwin.socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        guard trackUpstream(
            descriptor,
            client: client
        ) else {
            Darwin.close(descriptor)
            throw NetworkHelperError.bindingUnavailable
        }
        var succeeded = false
        defer {
            if !succeeded {
                closeTrackedDescriptor(
                    descriptor,
                    client: client
                )
            }
        }
        guard Self.configure(descriptor) else {
            throw NetworkHelperError.bindingUnavailable
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(
                  descriptor,
                  F_SETFL,
                  flags | O_NONBLOCK
              ) == 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        let result = Self.withSocketAddress(
            backend.address,
            port: backend.port
        ) {
            Darwin.connect(descriptor, $0.address, $0.length)
        }
        if result != 0, errno != EINPROGRESS {
            throw NetworkHelperError.bindingUnavailable
        }
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLOUT),
            revents: 0
        )
        guard Darwin.poll(
            &pollDescriptor,
            1,
            Int32(Self.connectTimeoutMilliseconds)
        ) > 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &length
        ) == 0,
        socketError == 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        succeeded = true
        return descriptor
    }

    private static func bridge(_ first: Int32, _ second: Int32) {
        var descriptors = [
            pollfd(
                fd: first,
                events: Int16(POLLIN),
                revents: 0
            ),
            pollfd(
                fd: second,
                events: Int16(POLLIN),
                revents: 0
            )
        ]
        let deadlineStep = idleTimeoutMilliseconds
        var deadline = monotonicMilliseconds() + deadlineStep
        var buffer = [UInt8](
            repeating: 0,
            count: maximumChunkBytes
        )
        while monotonicMilliseconds() < deadline {
            let ready = Darwin.poll(
                &descriptors,
                nfds_t(descriptors.count),
                100
            )
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }
            for index in descriptors.indices
            where descriptors[index].revents &
                Int16(POLLIN) != 0 {
                let source = descriptors[index].fd
                let destination =
                    descriptors[index == 0 ? 1 : 0].fd
                let count = Darwin.recv(
                    source,
                    &buffer,
                    buffer.count,
                    0
                )
                guard count > 0,
                      writeAll(
                          destination,
                          data: Data(buffer[0..<count])
                      ) else {
                    return
                }
                deadline = monotonicMilliseconds() + deadlineStep
            }
            if descriptors.contains(where: {
                $0.revents &
                    Int16(POLLERR | POLLHUP | POLLNVAL) != 0
            }) {
                return
            }
        }
    }

    private static func writeError(
        _ descriptor: Int32,
        status: Int,
        reason: String
    ) {
        let body = "\(status) \(reason)\n"
        let response = [
            "HTTP/1.1 \(status) \(reason)",
            "content-type: text/plain; charset=utf-8",
            "content-length: \(body.utf8.count)",
            "connection: close",
            "",
            body
        ].joined(separator: "\r\n")
        _ = writeAll(descriptor, data: Data(response.utf8))
    }

    private static func writeAll(
        _ descriptor: Int32,
        data: Data
    ) -> Bool {
        let deadline = monotonicMilliseconds() +
            idleTimeoutMilliseconds
        var offset = 0
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                return data.isEmpty
            }
            while offset < data.count {
                guard monotonicMilliseconds() < deadline else {
                    return false
                }
                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                guard Darwin.poll(
                    &pollDescriptor,
                    1,
                    100
                ) >= 0 else {
                    if errno == EINTR { continue }
                    return false
                }
                let count = Darwin.send(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset,
                    0
                )
                if count < 0,
                   errno == EAGAIN || errno == EWOULDBLOCK ||
                    errno == EINTR {
                    continue
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func configure(_ descriptor: Int32) -> Bool {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            return false
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }
        #if os(macOS)
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            return false
        }
        #endif
        return true
    }

    private static func pollReadable(
        _ descriptor: Int32,
        milliseconds: Int32
    ) -> Bool {
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        return Darwin.poll(
            &pollDescriptor,
            1,
            milliseconds
        ) > 0
    }

    private static func path(
        _ path: String,
        matchesPrefix prefix: String
    ) -> Bool {
        prefix == "/" ||
            path == prefix ||
            path.hasPrefix(
                prefix.hasSuffix("/") ? prefix : "\(prefix)/"
            )
    }

    private static func bind(
        _ descriptor: Int32,
        address: String,
        port: Int
    ) throws {
        let result = withSocketAddress(address, port: port) {
            Darwin.bind(descriptor, $0.address, $0.length)
        }
        guard result == 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
    }

    private static func withSocketAddress<Result>(
        _ address: String,
        port: Int,
        _ body: ((address: UnsafePointer<sockaddr>, length: socklen_t))
            -> Result
    ) -> Result {
        if address.contains(":") {
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(
                MemoryLayout<sockaddr_in6>.size
            )
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_port = in_port_t(port).bigEndian
            _ = address.withCString {
                inet_pton(
                    AF_INET6,
                    $0,
                    &socketAddress.sin6_addr
                )
            }
            return withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) {
                    body((
                        $0,
                        socklen_t(
                            MemoryLayout<sockaddr_in6>.size
                        )
                    ))
                }
            }
        }
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(
            MemoryLayout<sockaddr_in>.size
        )
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = in_port_t(port).bigEndian
        _ = address.withCString {
            inet_pton(
                AF_INET,
                $0,
                &socketAddress.sin_addr
            )
        }
        return withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                body((
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ))
            }
        }
    }

    private static func monotonicMilliseconds() -> Int64 {
        var value = timespec()
        clock_gettime(CLOCK_MONOTONIC, &value)
        return Int64(value.tv_sec) * 1_000 +
            Int64(value.tv_nsec) / 1_000_000
    }
}
