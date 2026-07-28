import Darwin
import Foundation
import HostwrightNetworking
import XCTest
@testable import HostwrightNetworkHelperCore

final class NetworkHelperIngressBrokerTests: XCTestCase {
    private let projectUUID = "11111111-1111-4111-8111-111111111111"
    private let dnsUUID = "22222222-2222-4222-8222-222222222222"

    func testParserProducesCanonicalRouteFields() throws {
        let request = try NetworkHelperIngressHTTPParser.parse(
            headerData: Data(
                "GET /v1 HTTP/1.1\r\nHost: api.internal\r\n\r\n".utf8
            ),
            body: Data()
        )

        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/v1")
        XCTAssertEqual(request.hostname, "api.internal")
        XCTAssertFalse(request.isWebSocket)
    }

    func testWebSocketHandshakeIsValidatedAndForwarded() throws {
        let backend = try makeServer()
        defer { Darwin.close(backend.descriptor) }
        let finished = DispatchSemaphore(value: 0)
        serveOnce(
            backend.descriptor,
            response:
                "HTTP/1.1 101 Switching Protocols\r\n" +
                "upgrade: websocket\r\nconnection: upgrade\r\n\r\n",
            finished: finished
        )

        let ingressPort = try availablePort()
        let broker = NetworkHelperIngressBroker()
        _ = try broker.apply(
            identity: identity(),
            bindings: [
                binding(
                    port: ingressPort,
                    backendPort: backend.port,
                    protocolName: .websocket
                )
            ]
        )
        defer { broker.remove(identity: identity()) }

        let response = try request(
            port: ingressPort,
            request:
                "GET /v1 HTTP/1.1\r\n" +
                "Host: api.internal\r\n" +
                "Connection: Upgrade\r\n" +
                "Upgrade: websocket\r\n" +
                "Sec-WebSocket-Version: 13\r\n" +
                "Sec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==\r\n\r\n"
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 101 Switching Protocols"),
            response
        )
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)

        let incomplete = Data(
            (
                "GET /v1 HTTP/1.1\r\n" +
                    "Host: api.internal\r\n" +
                    "Connection: Upgrade\r\n" +
                    "Upgrade: websocket\r\n\r\n"
            ).utf8
        )
        XCTAssertThrowsError(
            try NetworkHelperIngressHTTPParser.parse(
                headerData: incomplete,
                body: Data()
            )
        )
    }

    func testForwardsMatchingHTTPRouteToReadyBackend() throws {
        let backend = try makeServer()
        defer { Darwin.close(backend.descriptor) }
        let finished = DispatchSemaphore(value: 0)
        serveOnce(backend.descriptor, response: "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok", finished: finished)

        let ingressPort = try availablePort()
        let broker = NetworkHelperIngressBroker()
        _ = try broker.apply(
            identity: identity(),
            bindings: [binding(port: ingressPort, backendPort: backend.port)]
        )
        defer { broker.remove(identity: identity()) }

        let wireRequest = "GET /v1 HTTP/1.1\r\nHost: api.internal\r\n\r\n"
        let parsed = try NetworkHelperIngressHTTPParser.parse(
            headerData: Data(wireRequest.utf8),
            body: Data()
        )
        XCTAssertEqual(parsed.hostname, "api.internal")
        XCTAssertEqual(parsed.path, "/v1")
        XCTAssertEqual(parsed.method, "GET")

        let response = try request(
            port: ingressPort,
            request: wireRequest
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"), response)
        XCTAssertTrue(response.hasSuffix("\r\n\r\nok"), response)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    }

    func testMissingRouteReturnsNotFound() throws {
        let broker = NetworkHelperIngressBroker()
        let port = try availablePort()
        _ = try broker.apply(
            identity: identity(),
            bindings: [binding(port: port, backendPort: 8_080)]
        )
        defer { broker.remove(identity: identity()) }

        let response = try request(
            port: port,
            request: "GET /missing HTTP/1.1\r\nHost: api.internal\r\n\r\n"
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 404 Not Found"))
    }

    func testNoReadyBackendReturnsServiceUnavailable() throws {
        let broker = NetworkHelperIngressBroker()
        let port = try availablePort()
        _ = try broker.apply(
            identity: identity(),
            bindings: [binding(port: port, backendPort: 8_080, backends: [])]
        )
        defer { broker.remove(identity: identity()) }

        let response = try request(
            port: port,
            request: "GET /v1 HTTP/1.1\r\nHost: api.internal\r\n\r\n"
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 503 Service Unavailable"),
            response
        )
    }

    func testConflictingEndpointIsRejectedAcrossProjects() throws {
        let broker = NetworkHelperIngressBroker()
        let port = try availablePort()
        _ = try broker.apply(
            identity: identity(),
            bindings: [binding(port: port, backendPort: 8_080)]
        )
        defer { broker.remove(identity: identity()) }

        XCTAssertThrowsError(
            try broker.apply(
                identity: identity(project: "33333333-3333-4333-8333-333333333333"),
                bindings: [binding(port: port, backendPort: 8_081)]
            )
        ) { error in
            XCTAssertEqual(error as? NetworkHelperError, .bindingUnavailable)
        }
    }

    func testPartialListenerAcquisitionClosesEarlierDescriptors() throws {
        let first = try makeServer()
        let second = try makeServer()
        let freePort: Int
        let occupied: (descriptor: Int32, port: Int)
        if first.port < second.port {
            Darwin.close(first.descriptor)
            freePort = first.port
            occupied = second
        } else {
            Darwin.close(second.descriptor)
            freePort = second.port
            occupied = first
        }
        defer { Darwin.close(occupied.descriptor) }

        let broker = NetworkHelperIngressBroker()
        XCTAssertThrowsError(
            try broker.apply(
                identity: identity(),
                bindings: [
                    binding(
                        name: "first",
                        port: freePort,
                        backendPort: 8_080
                    ),
                    binding(
                        name: "second",
                        port: occupied.port,
                        backendPort: 8_081
                    ),
                ]
            )
        )
        XCTAssertThrowsError(try connect(port: freePort))
        XCTAssertFalse(broker.hasActiveBindings)
    }

    func testImmutableReloadUsesSameListenerWithNewRouteGeneration() throws {
        let first = try makeServer()
        let second = try makeServer()
        defer {
            Darwin.close(first.descriptor)
            Darwin.close(second.descriptor)
        }
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        serveOnce(first.descriptor, response: "HTTP/1.1 200 OK\r\ncontent-length: 3\r\nconnection: close\r\n\r\none", finished: firstFinished)
        serveOnce(second.descriptor, response: "HTTP/1.1 200 OK\r\ncontent-length: 3\r\nconnection: close\r\n\r\ntwo", finished: secondFinished)

        let ingressPort = try availablePort()
        let broker = NetworkHelperIngressBroker()
        _ = try broker.apply(
            identity: identity(),
            bindings: [binding(port: ingressPort, backendPort: first.port)]
        )
        defer { broker.remove(identity: identity()) }
        XCTAssertTrue(
            try request(
                port: ingressPort,
                request: "GET /v1 HTTP/1.1\r\nHost: api.internal\r\n\r\n"
            ).hasSuffix("\r\n\r\none")
        )
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 2), .success)

        _ = try broker.apply(
            identity: identity(),
            bindings: [binding(port: ingressPort, backendPort: second.port)]
        )
        XCTAssertTrue(
            try request(
                port: ingressPort,
                request: "GET /v1 HTTP/1.1\r\nHost: api.internal\r\n\r\n"
            ).hasSuffix("\r\n\r\ntwo")
        )
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 2), .success)
    }

    func testMultiListenerReloadPublishesOneImmutableGeneration() throws {
        let oldFirst = try makeServer()
        let oldSecond = try makeServer()
        let newFirst = try makeServer()
        let newSecond = try makeServer()
        defer {
            Darwin.close(oldFirst.descriptor)
            Darwin.close(oldSecond.descriptor)
            Darwin.close(newFirst.descriptor)
            Darwin.close(newSecond.descriptor)
        }
        let oldFirstFinished = DispatchSemaphore(value: 0)
        let oldSecondFinished = DispatchSemaphore(value: 0)
        let newFirstFinished = DispatchSemaphore(value: 0)
        let newSecondFinished = DispatchSemaphore(value: 0)
        serveOnce(
            oldFirst.descriptor,
            response: response(body: "old-first"),
            finished: oldFirstFinished
        )
        serveOnce(
            oldSecond.descriptor,
            response: response(body: "old-second"),
            finished: oldSecondFinished
        )
        serveOnce(
            newFirst.descriptor,
            response: response(body: "new-first"),
            finished: newFirstFinished
        )
        serveOnce(
            newSecond.descriptor,
            response: response(body: "new-second"),
            finished: newSecondFinished
        )

        let firstPort = try availablePort()
        let secondPort = try availablePort()
        let broker = NetworkHelperIngressBroker()
        _ = try broker.apply(
            identity: identity(),
            bindings: [
                binding(
                    name: "first",
                    port: firstPort,
                    backendPort: oldFirst.port
                ),
                binding(
                    name: "second",
                    port: secondPort,
                    backendPort: oldSecond.port
                ),
            ]
        )
        defer { broker.remove(identity: identity()) }
        XCTAssertTrue(
            try request(
                port: firstPort,
                request:
                    "GET /v1 HTTP/1.1\r\n" +
                    "Host: api.internal\r\n\r\n"
            ).hasSuffix("\r\n\r\nold-first")
        )
        XCTAssertTrue(
            try request(
                port: secondPort,
                request:
                    "GET /v1 HTTP/1.1\r\n" +
                    "Host: api.internal\r\n\r\n"
            ).hasSuffix("\r\n\r\nold-second")
        )

        _ = try broker.apply(
            identity: identity(),
            bindings: [
                binding(
                    name: "first",
                    port: firstPort,
                    backendPort: newFirst.port
                ),
                binding(
                    name: "second",
                    port: secondPort,
                    backendPort: newSecond.port
                ),
            ]
        )
        XCTAssertTrue(
            try request(
                port: firstPort,
                request:
                    "GET /v1 HTTP/1.1\r\n" +
                    "Host: api.internal\r\n\r\n"
            ).hasSuffix("\r\n\r\nnew-first")
        )
        XCTAssertTrue(
            try request(
                port: secondPort,
                request:
                    "GET /v1 HTTP/1.1\r\n" +
                    "Host: api.internal\r\n\r\n"
            ).hasSuffix("\r\n\r\nnew-second")
        )
        for finished in [
            oldFirstFinished,
            oldSecondFinished,
            newFirstFinished,
            newSecondFinished,
        ] {
            XCTAssertEqual(
                finished.wait(timeout: .now() + 2),
                .success
            )
        }
    }

    func testRemovalDrainsActiveWebSocketBeforeReturning() throws {
        let backend = try makeServer()
        defer { Darwin.close(backend.descriptor) }
        let backendReady = DispatchSemaphore(value: 0)
        let backendClosed = DispatchSemaphore(value: 0)
        serveWebSocketUntilClosed(
            backend.descriptor,
            ready: backendReady,
            closed: backendClosed
        )

        let ingressPort = try availablePort()
        let activeIdentity = identity()
        let broker = NetworkHelperIngressBroker()
        _ = try broker.apply(
            identity: activeIdentity,
            bindings: [
                binding(
                    port: ingressPort,
                    backendPort: backend.port,
                    protocolName: .websocket
                ),
            ]
        )

        let client = try openWebSocket(port: ingressPort)
        XCTAssertEqual(
            backendReady.wait(timeout: .now() + 2),
            .success
        )
        let removed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            broker.remove(identity: activeIdentity)
            removed.signal()
        }
        XCTAssertEqual(
            removed.wait(timeout: .now() + 0.2),
            .timedOut
        )

        Darwin.close(client)
        XCTAssertEqual(
            removed.wait(timeout: .now() + 2),
            .success
        )
        XCTAssertEqual(
            backendClosed.wait(timeout: .now() + 2),
            .success
        )
        XCTAssertFalse(broker.hasActiveBindings)
    }

    func testRemovalForcesBoundedCleanupOfStuckWebSocket() throws {
        let backend = try makeServer()
        defer { Darwin.close(backend.descriptor) }
        let backendReady = DispatchSemaphore(value: 0)
        let backendClosed = DispatchSemaphore(value: 0)
        serveWebSocketUntilClosed(
            backend.descriptor,
            ready: backendReady,
            closed: backendClosed
        )

        let ingressPort = try availablePort()
        let activeIdentity = identity()
        let broker = NetworkHelperIngressBroker()
        _ = try broker.apply(
            identity: activeIdentity,
            bindings: [
                binding(
                    port: ingressPort,
                    backendPort: backend.port,
                    protocolName: .websocket
                ),
            ]
        )

        let client = try openWebSocket(port: ingressPort)
        defer { Darwin.close(client) }
        XCTAssertEqual(
            backendReady.wait(timeout: .now() + 2),
            .success
        )
        let started = Date()
        broker.remove(identity: activeIdentity)
        let duration = Date().timeIntervalSince(started)

        XCTAssertGreaterThanOrEqual(duration, 1.5)
        XCTAssertLessThan(duration, 3.5)
        XCTAssertTrue(
            waitForReadable(client, milliseconds: 1_000)
        )
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.recv(client, &byte, 1, 0), 0)
        XCTAssertEqual(
            backendClosed.wait(timeout: .now() + 2),
            .success
        )
        XCTAssertFalse(broker.hasActiveBindings)
    }

    func testRejectsSmugglingTraversalAndOversizedHeaders() throws {
        let smuggling = Data("GET / HTTP/1.1\r\nHost: api.internal\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        XCTAssertThrowsError(try NetworkHelperIngressHTTPParser.parse(headerData: smuggling, body: Data()))

        let traversal = Data("GET /%2e%2e/private HTTP/1.1\r\nHost: api.internal\r\n\r\n".utf8)
        XCTAssertThrowsError(try NetworkHelperIngressHTTPParser.parse(headerData: traversal, body: Data()))

        let oversized = Data(
            "GET / HTTP/1.1\r\nHost: api.internal\r\nX-Long: \(String(repeating: "a", count: NetworkHelperProtocolV1.maximumIngressHeaderBytes))\r\n\r\n".utf8
        )
        XCTAssertThrowsError(try NetworkHelperIngressHTTPParser.parse(headerData: oversized, body: Data()))
    }

    func testRemovalClosesOnlyOwnedListener() throws {
        let broker = NetworkHelperIngressBroker()
        let port = try availablePort()
        let identity = identity()
        _ = try broker.apply(
            identity: identity,
            bindings: [binding(port: port, backendPort: 8_080)]
        )
        XCTAssertNotNil(try? connect(port: port))
        broker.remove(identity: identity)
        usleep(100_000)
        XCTAssertThrowsError(try connect(port: port))
        XCTAssertFalse(broker.hasActiveBindings)
    }

    func testAccessLogIsBoundedAndOmitsRequestSecrets() throws {
        let broker = NetworkHelperIngressBroker()
        let port = try availablePort()
        let activeIdentity = identity()
        _ = try broker.apply(
            identity: activeIdentity,
            bindings: [
                binding(
                    port: port,
                    backendPort: 8_080,
                    backends: []
                ),
            ]
        )
        defer { broker.remove(identity: activeIdentity) }

        let secret = "do-not-record-this-token"
        for _ in 0...NetworkHelperProtocolV1
            .maximumIngressAccessLogEntries {
            let response = try request(
                port: port,
                request:
                    "GET /v1?token=\(secret) HTTP/1.1\r\n" +
                    "Host: api.internal\r\n" +
                    "Authorization: Bearer \(secret)\r\n\r\n"
            )
            XCTAssertTrue(
                response.hasPrefix(
                    "HTTP/1.1 503 Service Unavailable"
                )
            )
        }

        let entries = broker.accessLog(identity: activeIdentity)
        XCTAssertEqual(
            entries.count,
            NetworkHelperProtocolV1.maximumIngressAccessLogEntries
        )
        XCTAssertTrue(entries.allSatisfy {
            $0.listenerName == "api" &&
                $0.method == "GET" &&
                $0.routeHostname == "api.internal" &&
                $0.routePathPrefix == "/v1" &&
                $0.protocolName == .http &&
                $0.targetServiceUUID == nil &&
                $0.outcome == .unavailable &&
                $0.durationMilliseconds >= 0
        })
        let encoded = try JSONEncoder().encode(entries)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("authorization"))

        broker.remove(identity: activeIdentity)
        XCTAssertTrue(broker.accessLog(identity: activeIdentity).isEmpty)
    }

    private func identity(project: String? = nil) -> NetworkHelperDNSIdentity {
        NetworkHelperDNSIdentity(
            projectUUID: project ?? projectUUID,
            dnsUUID: dnsUUID,
            generation: 1,
            fencingToken: "33333333-3333-4333-8333-333333333333"
        )
    }

    private func binding(
        name: String = "api",
        port: Int,
        backendPort: Int,
        backends: [ProjectIngressBackend]? = nil,
        protocolName: HostwrightIngressRouteProtocol = .http
    ) -> ProjectIngressListenerBinding {
        let resolvedBackends = backends ?? [ProjectIngressBackend(
            serviceUUID: projectUUID,
            address: "127.0.0.1",
            port: backendPort
        )]
        return ProjectIngressListenerBinding(
            name: name,
            bindAddress: "127.0.0.1",
            port: port,
            exposure: .localhost,
            routes: [ProjectIngressRouteBinding(
                hostname: "api.internal",
                pathPrefix: "/v1",
                methods: ["GET"],
                protocolName: protocolName,
                targetServiceUUIDs: [projectUUID],
                targetPort: backendPort,
                backends: resolvedBackends
            )]
        )
    }
}

private func response(body: String) -> String {
    "HTTP/1.1 200 OK\r\n" +
        "content-length: \(body.utf8.count)\r\n" +
        "connection: close\r\n\r\n" +
        body
}

private func openWebSocket(port: Int) throws -> Int32 {
    let descriptor = try connect(port: port)
    let request =
        "GET /v1 HTTP/1.1\r\n" +
        "Host: api.internal\r\n" +
        "Connection: Upgrade\r\n" +
        "Upgrade: websocket\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "Sec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==\r\n\r\n"
    let sent = request.withCString { pointer in
        Darwin.send(descriptor, pointer, strlen(pointer), 0)
    }
    guard sent == request.utf8.count,
          waitForReadable(descriptor, milliseconds: 5_000),
          String(
              data: receiveUntilHeaders(descriptor),
              encoding: .utf8
          )?.hasPrefix(
              "HTTP/1.1 101 Switching Protocols"
          ) == true else {
        Darwin.close(descriptor)
        throw NetworkHelperError.ioFailure
    }
    return descriptor
}

private func serveWebSocketUntilClosed(
    _ listener: Int32,
    ready: DispatchSemaphore,
    closed: DispatchSemaphore
) {
    DispatchQueue.global(qos: .userInitiated).async {
        defer { closed.signal() }
        guard waitForReadable(listener, milliseconds: 5_000)
        else {
            return
        }
        let connection = Darwin.accept(listener, nil, nil)
        guard connection >= 0 else { return }
        defer { Darwin.close(connection) }
        _ = receiveUntilHeaders(connection)
        let response =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "upgrade: websocket\r\n" +
            "connection: upgrade\r\n\r\n"
        let sent = response.withCString { pointer in
            Darwin.send(connection, pointer, strlen(pointer), 0)
        }
        guard sent == response.utf8.count else { return }
        ready.signal()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.recv(
                connection,
                &buffer,
                buffer.count,
                0
            )
            if count == 0 { return }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            guard count > 0 else { return }
        }
    }
}

private func serveOnce(
    _ listener: Int32,
    response: String,
    finished: DispatchSemaphore
) {
    DispatchQueue.global(qos: .userInitiated).async {
        defer { finished.signal() }
        guard waitForReadable(listener, milliseconds: 5_000) else { return }
        let connection = Darwin.accept(listener, nil, nil)
        guard connection >= 0 else { return }
        defer { Darwin.close(connection) }
        _ = receiveUntilHeaders(connection)
        _ = response.withCString { pointer in
            Darwin.send(connection, pointer, strlen(pointer), 0)
        }
    }
}

private func request(port: Int, request: String) throws -> String {
    let descriptor = try connect(port: port)
    defer { Darwin.close(descriptor) }
    let sent = request.withCString { pointer in
        Darwin.send(descriptor, pointer, strlen(pointer), 0)
    }
    guard sent == request.utf8.count,
          waitForReadable(descriptor, milliseconds: 5_000) else {
        throw NetworkHelperError.ioFailure
    }
    return try readToEOF(descriptor)
}

private func availablePort() throws -> Int {
    let listener = try makeServer()
    defer { Darwin.close(listener.descriptor) }
    return listener.port
}

private func makeServer() throws -> (descriptor: Int32, port: Int) {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw NetworkHelperError.bindingUnavailable }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard "127.0.0.1".withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
        Darwin.close(descriptor)
        throw NetworkHelperError.bindingUnavailable
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, Darwin.listen(descriptor, 8) == 0 else {
        Darwin.close(descriptor)
        throw NetworkHelperError.bindingUnavailable
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    guard withUnsafeMutablePointer(to: &actual, {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }) == 0 else {
        Darwin.close(descriptor)
        throw NetworkHelperError.bindingUnavailable
    }
    return (descriptor, Int(in_port_t(bigEndian: actual.sin_port)))
}

private func connect(port: Int) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw NetworkHelperError.bindingUnavailable }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    guard "127.0.0.1".withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
        Darwin.close(descriptor)
        throw NetworkHelperError.bindingUnavailable
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        Darwin.close(descriptor)
        throw NetworkHelperError.bindingUnavailable
    }
    return descriptor
}

private func receiveUntilHeaders(_ descriptor: Int32) -> Data {
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while received.range(of: Data("\r\n\r\n".utf8)) == nil,
          received.count < 64 * 1_024 {
        let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { break }
        received.append(contentsOf: buffer[0..<count])
    }
    return received
}

private func readToEOF(_ descriptor: Int32) throws -> String {
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        if count == 0 { break }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw NetworkHelperError.ioFailure }
        response.append(contentsOf: buffer[0..<count])
    }
    guard let value = String(data: response, encoding: .utf8) else {
        throw NetworkHelperError.ioFailure
    }
    return value
}

private func waitForReadable(_ descriptor: Int32, milliseconds: Int32) -> Bool {
    var value = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    return Darwin.poll(&value, 1, milliseconds) > 0
}
