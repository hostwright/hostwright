import Foundation
import Darwin
import HostwrightNetworking
@preconcurrency import Network
import XCTest

@testable import HostwrightNetworkHelperCore

final class ServiceTunnelLifecycleManagerTests: XCTestCase {
    private let project =
        "11111111-1111-4111-8111-111111111111"
    private let routeUUID =
        "22222222-2222-4222-8222-222222222222"
    private let peer =
        "33333333-3333-4333-8333-333333333333"
    private let fence =
        "44444444-4444-4444-8444-444444444444"
    private let group =
        "55555555-5555-4555-8555-555555555555"

    func testSetupIsLiveIdempotentReconnectsDrainsAndCleansExactly()
        throws
    {
        let store = MemoryStore()
        let route = try makeRoute()
        let identity = makeIdentity()
        let request = NetworkHelperTunnelRequest(
            route: route,
            timeoutMilliseconds: 8_000
        )
        let manager = NetworkHelperServiceTunnelManager(
            store: store,
            certificateCoordinator:
                NetworkHelperCertificateCoordinator()
        )

        let first = try manager.setup(
            identity: identity,
            request: request
        )
        XCTAssertEqual(first.phase, .active)
        XCTAssertTrue(first.live)
        XCTAssertEqual(first.observedSHA256, route.desiredSHA256)
        XCTAssertEqual(
            try manager.setup(
                identity: identity,
                request: request
            ),
            first
        )
        let rotated = try manager.rotateKey(
            identity: identity,
            request: request
        )
        XCTAssertEqual(rotated.keyRotations, 1)
        XCTAssertEqual(rotated.reconnects, 0)
        let reconnected = try manager.reconnect(
            identity: identity,
            request: request
        )
        XCTAssertEqual(reconnected.phase, .active)
        XCTAssertTrue(reconnected.live)
        XCTAssertEqual(reconnected.reconnectAttempt, 1)
        XCTAssertEqual(
            reconnected.reconnectDelayMilliseconds,
            500
        )
        XCTAssertEqual(reconnected.reconnects, 1)
        XCTAssertEqual(reconnected.keyRotations, 1)

        let drained = try manager.drain(
            identity: identity,
            request: request
        )
        XCTAssertEqual(drained.phase, .draining)
        XCTAssertFalse(drained.live)
        let removed = try manager.teardown(
            identity: identity,
            request: request
        )
        XCTAssertEqual(removed.phase, .closed)
        XCTAssertFalse(removed.live)
        XCTAssertNil(try store.load(routeUUID: route.routeUUID))
        XCTAssertEqual(store.removeCount, 1)
        XCTAssertEqual(
            try manager.teardown(
                identity: identity,
                request: request
            ),
            removed
        )
        XCTAssertEqual(store.removeCount, 1)
    }

    func testReconnectBackoffDoesNotHoldManagerWideLock()
        async throws
    {
        let store = MemoryStore()
        let route = try makeRoute()
        let identity = makeIdentity()
        let request = NetworkHelperTunnelRequest(
            route: route,
            timeoutMilliseconds: 8_000
        )
        let manager = NetworkHelperServiceTunnelManager(
            store: store,
            certificateCoordinator:
                NetworkHelperCertificateCoordinator()
        )
        _ = try manager.setup(
            identity: identity,
            request: request
        )

        let reconnect = Task.detached {
            try manager.reconnect(
                identity: identity,
                request: request
            )
        }
        var observedBackoff = false
        for _ in 0..<100 {
            if try store.load(
                routeUUID: route.routeUUID
            )?.phase == .connecting {
                observedBackoff = true
                break
            }
            try await Task.sleep(
                nanoseconds: 5_000_000
            )
        }
        XCTAssertTrue(observedBackoff)

        let started = Date()
        let status = try manager.status(
            identity: identity,
            request: request
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            0.4
        )
        XCTAssertEqual(status.phase, .connecting)
        XCTAssertFalse(status.live)
        let reconnected = try await reconnect.value
        XCTAssertTrue(reconnected.live)

        _ = try manager.teardown(
            identity: identity,
            request: request
        )
    }

    func testCrashRestartRecoversPersistedIntentThroughSetup()
        throws
    {
        let store = MemoryStore()
        let route = try makeRoute()
        let identity = makeIdentity()
        let request = NetworkHelperTunnelRequest(
            route: route,
            timeoutMilliseconds: 8_000
        )
        var first:
            NetworkHelperServiceTunnelManager? =
                NetworkHelperServiceTunnelManager(
                    store: store,
                    certificateCoordinator:
                        NetworkHelperCertificateCoordinator()
                )
        XCTAssertTrue(
            try XCTUnwrap(first).setup(
                identity: identity,
                request: request
            ).live
        )
        first = nil

        let restarted = NetworkHelperServiceTunnelManager(
            store: store,
            certificateCoordinator:
                NetworkHelperCertificateCoordinator()
        )
        let persisted = try restarted.status(
            identity: identity,
            request: request
        )
        XCTAssertEqual(persisted.phase, .active)
        XCTAssertFalse(persisted.live)
        let recovered = try restarted.setup(
            identity: identity,
            request: request
        )
        XCTAssertEqual(recovered.phase, .active)
        XCTAssertTrue(recovered.live)
        _ = try restarted.teardown(
            identity: identity,
            request: request
        )
        XCTAssertNil(try store.load(routeUUID: route.routeUUID))
    }

    func testProtocolRejectsMismatchedIdentityAndStaleFence()
        throws
    {
        let route = try makeRoute()
        let request = NetworkHelperTunnelRequest(route: route)
        XCTAssertThrowsError(
            try request.validated(
                identity: NetworkHelperDNSIdentity(
                    projectUUID: project,
                    dnsUUID: routeUUID,
                    generation: 1,
                    fencingToken:
                        "66666666-6666-4666-8666-666666666666"
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? NetworkHelperError,
                .invalidTunnel
            )
        }
    }

    func testRemoteRolesUseSharedWireBindingAcrossDifferentLocalFences()
        throws
    {
        let identityStore = CertificateIdentityStore()
        let serverScope = try CertificateIdentityScope(
            projectUUID: project,
            certificateUUID:
                "66666666-6666-4666-8666-666666666666",
            generation: 1
        )
        let clientIssuerScope = try CertificateIdentityScope(
            projectUUID: project,
            certificateUUID:
                "77777777-7777-4777-8777-777777777777",
            generation: 1
        )
        let clientScope = try CertificateIdentityScope(
            projectUUID: project,
            certificateUUID:
                "88888888-8888-4888-8888-888888888888",
            generation: 1
        )
        let server = try identityStore.generateLocalIdentity(
            scope: serverScope,
            dnsNames: ["peer.hostwright.test"]
        )
        let clientIssuer =
            try identityStore.generateLocalIdentity(
                scope: clientIssuerScope,
                dnsNames: ["client-ca.hostwright.test"]
            )
        let clientPeer = try HostwrightMutualTLSIdentity(
            projectUUID: project,
            resourceUUID: clientScope.certificateUUID,
            role: .tunnel,
            generation: 1
        )
        let client =
            try identityStore.issueManagedClientIdentity(
                issuerScope: clientIssuerScope,
                peerScope: clientScope,
                role: .tunnel,
                uriSAN: clientPeer.uriSAN
            )
        defer {
            try? identityStore.cleanupManagedClientIdentity(
                peerScope: clientScope,
                expectedLeafSHA256:
                    client.metadata.certificateSHA256
            )
            try? identityStore.cleanupManagedIdentity(
                scope: clientIssuerScope,
                expectedLeafSHA256:
                    clientIssuer.metadata.certificateSHA256,
                expectedIssuerSHA256:
                    clientIssuer.metadata
                        .issuerCertificateSHA256!
            )
            try? identityStore.cleanupManagedIdentity(
                scope: serverScope,
                expectedLeafSHA256:
                    server.metadata.certificateSHA256,
                expectedIssuerSHA256:
                    server.metadata.issuerCertificateSHA256!
            )
        }

        let servicePort = try availablePort()
        let remotePort = try availablePort()
        let localPort = try availablePort()
        let service = try PlainEchoServer(port: servicePort)
        defer { service.stop() }
        try service.start()

        let wireRouteUUID =
            "99999999-9999-4999-8999-999999999999"
        let wireFence =
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let listenerFence =
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let dialerFence =
            "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let listenerRoute = try HostwrightTunnelRoute(
            routeUUID: routeUUID,
            projectUUID: project,
            peerUUID: peer,
            generation: 1,
            providerID: "apple-container-cli",
            providerGeneration: 1,
            fencingToken: listenerFence,
            operationGroupID: group,
            desiredSHA256: String(repeating: "a", count: 64),
            role: .listener,
            trust: HostwrightTunnelTrust(
                wireRouteUUID: wireRouteUUID,
                wireGeneration: 7,
                localIdentitySHA256:
                    server.metadata.certificateSHA256,
                peerTrustAnchorSHA256:
                    clientIssuer.metadata
                        .issuerCertificateSHA256!,
                peerCertificateSHA256:
                    client.metadata.certificateSHA256,
                peerIdentityURI: clientPeer.uriSAN
            ),
            bindEndpoint: HostwrightTunnelBindEndpoint(
                host: "127.0.0.1",
                port: remotePort
            ),
            forwardEndpoint: try HostwrightTunnelEndpoint(
                host: "127.0.0.1",
                port: servicePort
            ),
            authenticatedEndpoints: []
        )
        let dialerRouteUUID =
            "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let dialerRoute = try HostwrightTunnelRoute(
            routeUUID: dialerRouteUUID,
            projectUUID: project,
            peerUUID: peer,
            generation: 1,
            providerID: "apple-container-cli",
            providerGeneration: 1,
            fencingToken: dialerFence,
            operationGroupID:
                "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            desiredSHA256: String(repeating: "b", count: 64),
            role: .dialer,
            trust: HostwrightTunnelTrust(
                wireRouteUUID: wireRouteUUID,
                wireGeneration: 7,
                localIdentitySHA256:
                    client.metadata.certificateSHA256,
                peerTrustAnchorSHA256:
                    server.metadata.issuerCertificateSHA256!,
                peerCertificateSHA256:
                    server.metadata.certificateSHA256,
                peerDNSName: "peer.hostwright.test"
            ),
            bindEndpoint: HostwrightTunnelBindEndpoint(
                host: "127.0.0.1",
                port: localPort
            ),
            authenticatedEndpoints: [
                try HostwrightTunnelEndpoint(
                    host: "127.0.0.1",
                    port: remotePort
                ),
            ]
        )
        let listenerExecution = NetworkHelperTunnelExecution(
            role: .listener,
            wireRouteUUID: wireRouteUUID,
            wireGeneration: 7,
            wireFencingToken: wireFence,
            localIdentitySHA256:
                server.metadata.certificateSHA256,
            peerTrustAnchorSHA256:
                clientIssuer.metadata.issuerCertificateSHA256!,
            peerCertificateSHA256:
                client.metadata.certificateSHA256,
            peerIdentityURI: clientPeer.uriSAN,
            serviceTarget: try HostwrightTunnelEndpoint(
                host: "127.0.0.1",
                port: servicePort
            )
        )
        let dialerExecution = NetworkHelperTunnelExecution(
            role: .dialer,
            wireRouteUUID: wireRouteUUID,
            wireGeneration: 7,
            wireFencingToken: wireFence,
            localIdentitySHA256:
                client.metadata.certificateSHA256,
            peerTrustAnchorSHA256:
                server.metadata.issuerCertificateSHA256!,
            peerCertificateSHA256:
                server.metadata.certificateSHA256,
            peerDNSName: "peer.hostwright.test",
            localForwardEndpoint: try HostwrightTunnelEndpoint(
                host: "127.0.0.1",
                port: localPort
            )
        )
        let listenerIdentity = NetworkHelperDNSIdentity(
            projectUUID: project,
            dnsUUID: routeUUID,
            generation: 1,
            fencingToken: listenerFence
        )
        let dialerIdentity = NetworkHelperDNSIdentity(
            projectUUID: project,
            dnsUUID: dialerRouteUUID,
            generation: 1,
            fencingToken: dialerFence
        )
        let listenerProtocolRequest = NetworkHelperRequest(
            requestID: UUID(
                uuidString:
                    "12121212-1212-4212-8212-121212121212"
            )!,
            operation: .tunnelSetup,
            identity: listenerIdentity,
            tunnel: NetworkHelperTunnelRequest(
                route: listenerRoute,
                timeoutMilliseconds: 8_000,
                execution: listenerExecution
            )
        )
        XCTAssertEqual(
            try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperRequest.self,
                from: NetworkHelperCanonicalJSON.frame(
                    listenerProtocolRequest
                )
            ),
            listenerProtocolRequest
        )
        let dialerProtocolRequest = NetworkHelperRequest(
            requestID: UUID(
                uuidString:
                    "13131313-1313-4313-8313-131313131313"
            )!,
            operation: .tunnelSetup,
            identity: dialerIdentity,
            tunnel: NetworkHelperTunnelRequest(
                route: dialerRoute,
                timeoutMilliseconds: 8_000,
                execution: dialerExecution
            )
        )
        XCTAssertEqual(
            try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperRequest.self,
                from: NetworkHelperCanonicalJSON.frame(
                    dialerProtocolRequest
                )
            ),
            dialerProtocolRequest
        )
        let listenerManager =
            NetworkHelperServiceTunnelManager(
                store: MemoryStore(),
                certificateCoordinator:
                    NetworkHelperCertificateCoordinator()
            )
        let dialerManager =
            NetworkHelperServiceTunnelManager(
                store: MemoryStore(),
                certificateCoordinator:
                    NetworkHelperCertificateCoordinator()
            )
        XCTAssertTrue(try listenerManager.setup(
            identity: listenerIdentity,
            request: NetworkHelperTunnelRequest(
                route: listenerRoute,
                timeoutMilliseconds: 8_000,
                execution: listenerExecution
            )
        ).live)
        XCTAssertTrue(try dialerManager.setup(
            identity: dialerIdentity,
            request: NetworkHelperTunnelRequest(
                route: dialerRoute,
                timeoutMilliseconds: 8_000,
                execution: dialerExecution
            )
        ).live)

        let local = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(
                rawValue: UInt16(localPort)
            )!,
            using: .tcp
        )
        let clientConnection = NetworkHelperTLSConnection(
            connection: local,
            label: "service-tunnel-test-client"
        )
        defer { clientConnection.cancel() }
        XCTAssertTrue(clientConnection.start(
            timeoutMilliseconds: 5_000
        ))
        let payload = Data("remote-service-proof".utf8)
        XCTAssertTrue(clientConnection.send(
            payload,
            timeoutMilliseconds: 5_000
        ))
        XCTAssertEqual(
            clientConnection.receive(
                maximumLength: 64 * 1_024,
                timeoutMilliseconds: 5_000
            ),
            payload
        )
        let secondLocal = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(
                rawValue: UInt16(localPort)
            )!,
            using: .tcp
        )
        let secondClient = NetworkHelperTLSConnection(
            connection: secondLocal,
            label: "service-tunnel-second-test-client"
        )
        defer { secondClient.cancel() }
        XCTAssertTrue(secondClient.start(
            timeoutMilliseconds: 5_000
        ))
        let secondPayload = Data(
            "remote-service-second-proof".utf8
        )
        XCTAssertTrue(secondClient.send(
            secondPayload,
            timeoutMilliseconds: 5_000
        ))
        XCTAssertEqual(
            secondClient.receive(
                maximumLength: 64 * 1_024,
                timeoutMilliseconds: 5_000
            ),
            secondPayload
        )

        var stale = dialerExecution
        stale = NetworkHelperTunnelExecution(
            role: stale.role,
            wireRouteUUID: stale.wireRouteUUID,
            wireGeneration: stale.wireGeneration,
            wireFencingToken:
                "ffffffff-ffff-4fff-8fff-ffffffffffff",
            localIdentitySHA256:
                stale.localIdentitySHA256,
            peerTrustAnchorSHA256:
                stale.peerTrustAnchorSHA256,
            peerCertificateSHA256:
                stale.peerCertificateSHA256,
            peerDNSName: stale.peerDNSName,
            localForwardEndpoint:
                stale.localForwardEndpoint
        )
        XCTAssertThrowsError(
            try dialerManager.setup(
                identity: dialerIdentity,
                request: NetworkHelperTunnelRequest(
                    route: dialerRoute,
                    execution: stale
                )
            )
        )

        _ = try dialerManager.teardown(
            identity: dialerIdentity,
            request: NetworkHelperTunnelRequest(
                route: dialerRoute,
                execution: dialerExecution
            )
        )
        _ = try listenerManager.teardown(
            identity: listenerIdentity,
            request: NetworkHelperTunnelRequest(
                route: listenerRoute,
                execution: listenerExecution
            )
        )

        let failingManager =
            NetworkHelperServiceTunnelManager(
                store: MemoryStore(failOnActiveSave: true),
                certificateCoordinator:
                    NetworkHelperCertificateCoordinator()
            )
        XCTAssertThrowsError(
            try failingManager.setup(
                identity: listenerIdentity,
                request: NetworkHelperTunnelRequest(
                    route: listenerRoute,
                    timeoutMilliseconds: 8_000,
                    execution: listenerExecution
                )
            )
        )
        XCTAssertFalse(failingManager.hasActiveSessions)

        let retryManager =
            NetworkHelperServiceTunnelManager(
                store: MemoryStore(),
                certificateCoordinator:
                    NetworkHelperCertificateCoordinator()
            )
        XCTAssertTrue(
            try retryManager.setup(
                identity: listenerIdentity,
                request: NetworkHelperTunnelRequest(
                    route: listenerRoute,
                    timeoutMilliseconds: 8_000,
                    execution: listenerExecution
                )
            ).live
        )
        _ = try retryManager.teardown(
            identity: listenerIdentity,
            request: NetworkHelperTunnelRequest(
                route: listenerRoute,
                execution: listenerExecution
            )
        )
    }

    private func makeIdentity() -> NetworkHelperDNSIdentity {
        NetworkHelperDNSIdentity(
            projectUUID: project,
            dnsUUID: routeUUID,
            generation: 1,
            fencingToken: fence
        )
    }

    private func makeRoute() throws -> HostwrightTunnelRoute {
        try HostwrightTunnelRoute(
            routeUUID: routeUUID,
            projectUUID: project,
            peerUUID: peer,
            generation: 1,
            providerID: "apple-container-cli",
            providerGeneration: 1,
            fencingToken: fence,
            operationGroupID: group,
            desiredSHA256: String(repeating: "a", count: 64),
            authenticatedEndpoints: [
                try HostwrightTunnelEndpoint(
                    host: "127.0.0.1",
                    port: try availablePort()
                ),
            ]
        )
    }

    private func availablePort() throws -> Int {
        let descriptor = Darwin.socket(
            AF_INET,
            SOCK_STREAM,
            0
        )
        guard descriptor >= 0 else {
            throw HostwrightTunnelSocketError.connectionFailed
        }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(
            MemoryLayout<sockaddr_in>.size
        )
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0 else {
            throw HostwrightTunnelSocketError.connectionFailed
        }
        var result = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let loaded = withUnsafeMutablePointer(to: &result) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard loaded == 0 else {
            throw HostwrightTunnelSocketError.connectionFailed
        }
        return Int(UInt16(bigEndian: result.sin_port))
    }

    private final class PlainEchoServer:
        @unchecked Sendable
    {
        private let listener: NWListener
        private let queue = DispatchQueue(
            label: "dev.hostwright.test.tunnel-echo"
        )

        init(port: Int) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(
                    rawValue: UInt16(port)
                )!
            )
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { connection in
                connection.start(
                    queue: DispatchQueue.global(
                        qos: .userInitiated
                    )
                )
                Self.echo(connection)
            }
        }

        func start() throws {
            let completed = DispatchSemaphore(value: 0)
            let ready = LockedOptionalBool()
            listener.stateUpdateHandler = { state in
                let value: Bool?
                switch state {
                case .ready: value = true
                case .failed, .cancelled: value = false
                default: value = nil
                }
                guard let value else { return }
                ready.withLock {
                    if $0 == nil {
                        $0 = value
                        completed.signal()
                    }
                }
            }
            listener.start(queue: queue)
            guard completed.wait(
                timeout: .now() + .seconds(5)
            ) == .success,
            ready.read() == true else {
                stop()
                throw HostwrightTunnelSocketError.connectionFailed
            }
        }

        func stop() {
            listener.cancel()
        }

        private static func echo(_ connection: NWConnection) {
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1_024
            ) { data, _, _, error in
                guard error == nil, let data,
                      !data.isEmpty else {
                    connection.cancel()
                    return
                }
                connection.send(
                    content: data,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
            }
        }
    }

    private final class LockedOptionalBool:
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var value: Bool?

        func withLock(
            _ body: (inout Bool?) -> Void
        ) {
            lock.withLock { body(&value) }
        }

        func read() -> Bool? {
            lock.withLock { value }
        }
    }

    private final class MemoryStore:
        HostwrightTunnelIntentPersisting,
        @unchecked Sendable
    {
        private enum TestStoreError: Error {
            case activeSaveRejected
        }

        private let lock = NSLock()
        private let failOnActiveSave: Bool
        private var values:
            [String: HostwrightTunnelSessionIntent] = [:]
        private var removes = 0

        init(failOnActiveSave: Bool = false) {
            self.failOnActiveSave = failOnActiveSave
        }

        var removeCount: Int {
            lock.withLock { removes }
        }

        func save(
            _ intent: HostwrightTunnelSessionIntent
        ) throws {
            try lock.withLock {
                if failOnActiveSave, intent.phase == .active {
                    throw TestStoreError.activeSaveRejected
                }
                values[intent.route.routeUUID] = intent
            }
        }

        func load(
            routeUUID: String
        ) throws -> HostwrightTunnelSessionIntent? {
            lock.withLock { values[routeUUID] }
        }

        func remove(
            routeUUID: String,
            generation: Int64,
            fencingToken: String
        ) throws {
            try lock.withLock {
                guard let value = values[routeUUID],
                      value.route.generation == generation,
                      value.route.fencingToken ==
                        fencingToken else {
                    throw HostwrightTunnelControllerError.staleFence
                }
                values.removeValue(forKey: routeUUID)
                removes += 1
            }
        }
    }
}
