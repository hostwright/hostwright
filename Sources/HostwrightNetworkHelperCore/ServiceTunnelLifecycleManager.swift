import CryptoKit
import Foundation
import HostwrightNetworking

final class NetworkHelperServiceTunnelManager:
    @unchecked Sendable
{
    private struct LiveSession {
        let route: HostwrightTunnelRoute
        let identity: NetworkHelperDNSIdentity
        let binding: ProjectCertificateRequestBinding
        let evidence: NetworkHelperPersistedCertificateEvidence
        let listener: HostwrightServiceTunnelListener
        let client: HostwrightServiceTunnelConnection
        let server: HostwrightServiceTunnelConnection
    }

    private enum RemoteTransport {
        case listener(
            HostwrightServiceTunnelListener,
            HostwrightTunnelServiceForwarder
        )
        case dialer(
            HostwrightServiceTunnelConnection,
            HostwrightTunnelLocalForwarder
        )
    }

    private struct RemoteSession {
        let route: HostwrightTunnelRoute
        let identity: NetworkHelperDNSIdentity
        let execution: NetworkHelperTunnelExecution
        let transport: RemoteTransport
    }

    private final class IdentityRegistry:
        HostwrightTunnelIdentityProviding,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var routes: [String: HostwrightTunnelRoute] = [:]
        private var revoked = Set<String>()

        func admit(_ route: HostwrightTunnelRoute) {
            lock.withLock {
                routes[route.routeUUID] = route
                revoked.remove(route.routeUUID)
            }
        }

        func revoke(_ routeUUID: String) {
            lock.withLock {
                routes.removeValue(forKey: routeUUID)
                revoked.insert(routeUUID)
            }
        }

        func authenticate(
            projectUUID: String,
            peerUUID: String,
            generation: Int64
        ) throws -> HostwrightTunnelIdentity {
            try lock.withLock {
                guard let route = routes.values.first(where: {
                    $0.projectUUID == projectUUID &&
                        $0.peerUUID == peerUUID &&
                        $0.generation == generation
                }), !revoked.contains(route.routeUUID) else {
                    throw HostwrightTunnelControllerError.revoked
                }
                return HostwrightTunnelIdentity(
                    peerUUID: peerUUID,
                    generation: generation,
                    tlsVersion: "TLS1.3",
                    authenticated: true,
                    revoked: false
                )
            }
        }
    }

    private let store: any HostwrightTunnelIntentPersisting
    private let certificateCoordinator:
        NetworkHelperCertificateCoordinator
    private let identityRegistry = IdentityRegistry()
    private let controller: HostwrightTunnelController
    private let lock = NSLock()
    private var sessions: [String: LiveSession] = [:]
    private var remoteSessions: [String: RemoteSession] = [:]
    private var reconnectingRoutes = Set<String>()

    init(
        store: any HostwrightTunnelIntentPersisting,
        certificateCoordinator:
            NetworkHelperCertificateCoordinator
    ) {
        self.store = store
        self.certificateCoordinator = certificateCoordinator
        controller = HostwrightTunnelController(
            identityProvider: identityRegistry,
            store: store
        )
    }

    deinit {
        let live = lock.withLock {
            let values = Array(sessions.values)
            sessions.removeAll()
            let remote = Array(remoteSessions.values)
            remoteSessions.removeAll()
            return (values, remote)
        }
        for session in live.0 {
            close(session, drain: false)
            certificateCoordinator.deactivate(
                identity: session.identity
            )
        }
        live.1.forEach { close($0, drain: false) }
    }

    var hasActiveSessions: Bool {
        lock.withLock {
            !sessions.isEmpty || !remoteSessions.isEmpty ||
                !reconnectingRoutes.isEmpty
        }
    }

    func setup(
        identity: NetworkHelperDNSIdentity,
        request: NetworkHelperTunnelRequest
    ) throws -> NetworkHelperTunnelResult {
        try lock.withLock {
            let request = try request.validated(
                identity: identity
            )
            guard !reconnectingRoutes.contains(
                request.route.routeUUID
            ) else {
                throw NetworkHelperError.tunnelRejected
            }
            if let execution = request.execution {
                return try setupRemote(
                    identity: identity,
                    request: request,
                    execution: execution
                )
            }
            if let current = sessions[
                request.route.routeUUID
            ] {
                guard current.route == request.route,
                      current.identity == identity else {
                    throw NetworkHelperError.tunnelRejected
                }
                return try currentResult(
                    route: request.route,
                    live: true
                )
            }
            guard request.route.authenticatedEndpoints.contains(
                where: Self.isLoopbackEndpoint
            ) else {
                throw NetworkHelperError.tunnelRejected
            }

            let binding = try certificateBinding(
                identity: identity,
                route: request.route
            )
            let activation = try certificateCoordinator.apply(
                identity: identity,
                bindings: [binding]
            )
            let requestSHA256 = Self.sha256(
                try NetworkHelperCanonicalJSON.encode([binding])
            )
            let evidence =
                NetworkHelperPersistedCertificateEvidence(
                    identity: identity,
                    requestSHA256: requestSHA256,
                    certificates: activation.evidence
                )
            identityRegistry.admit(request.route)
            do {
                if try store.load(
                    routeUUID: request.route.routeUUID
                ) != nil {
                    try controller.recover(route: request.route)
                } else {
                    _ = try controller.begin(route: request.route)
                }
                let credentials =
                    try HostwrightTunnelCertificateCoordinatorAdapter(
                        coordinator: certificateCoordinator
                    ).loopbackCredentials(
                        identity: identity,
                        bindingName: binding.name,
                        peerIdentityURI:
                            binding.peerIdentities[0].uriSAN
                    )
                let live = try connectLoopback(
                    route: request.route,
                    identity: identity,
                    binding: binding,
                    evidence: evidence,
                    credentials: credentials,
                    timeoutMilliseconds:
                        request.timeoutMilliseconds
                )
                sessions[request.route.routeUUID] = live
                try controller.activate(
                    routeUUID: request.route.routeUUID,
                    fencingToken:
                        request.route.fencingToken
                )
                return try currentResult(
                    route: request.route,
                    live: true
                )
            } catch {
                identityRegistry.revoke(request.route.routeUUID)
                try? certificateCoordinator.cleanup(
                    identity: identity,
                    evidence: evidence
                )
                throw error
            }
        }
    }

    func status(
        identity: NetworkHelperDNSIdentity,
        request: NetworkHelperTunnelRequest
    ) throws -> NetworkHelperTunnelResult {
        try lock.withLock {
            let request = try request.validated(
                identity: identity
            )
            if let session = remoteSessions[
                request.route.routeUUID
            ] {
                guard session.route == request.route,
                      session.identity == identity,
                      session.execution == request.execution else {
                    throw NetworkHelperError.tunnelRejected
                }
                return try currentResult(
                    route: request.route,
                    live: true
                )
            }
            if let session = sessions[
                request.route.routeUUID
            ] {
                guard session.route == request.route,
                      session.identity == identity else {
                    throw NetworkHelperError.tunnelRejected
                }
                return try currentResult(
                    route: request.route,
                    live: true
                )
            }
            guard let persisted = try store.load(
                routeUUID: request.route.routeUUID
            ) else {
                return NetworkHelperTunnelResult(
                    route: request.route,
                    phase: .closed,
                    selectedTransport: nil,
                    live: false,
                    reconnectAttempt: 0,
                    observedSHA256: nil
                )
            }
            guard persisted.route == request.route else {
                throw NetworkHelperError.tunnelRejected
            }
            return NetworkHelperTunnelResult(
                intent: persisted,
                live: false
            )
        }
    }

    func reconnect(
        identity: NetworkHelperDNSIdentity,
        request: NetworkHelperTunnelRequest
    ) throws -> NetworkHelperTunnelResult {
        let request = try request.validated(
            identity: identity
        )
        if let execution = request.execution {
            return try reconnectRemote(
                identity: identity,
                request: request,
                execution: execution
            )
        }
        let existing = try lock.withLock {
            guard reconnectingRoutes.insert(
                request.route.routeUUID
            ).inserted,
            let existing = sessions[
                request.route.routeUUID
            ], existing.route == request.route,
            existing.identity == identity else {
                reconnectingRoutes.remove(
                    request.route.routeUUID
                )
                throw NetworkHelperError.tunnelRejected
            }
            sessions.removeValue(
                forKey: request.route.routeUUID
            )
            return existing
        }
        close(existing, drain: false)
        do {
            let reconnectDelay = try controller.reconnect(
                routeUUID: request.route.routeUUID,
                fencingToken: request.route.fencingToken
            )
            Thread.sleep(
                forTimeInterval:
                    Double(reconnectDelay) / 1_000
            )
            let credentials =
                try HostwrightTunnelCertificateCoordinatorAdapter(
                    coordinator: certificateCoordinator
                ).loopbackCredentials(
                    identity: identity,
                    bindingName: existing.binding.name,
                    peerIdentityURI:
                        existing.binding.peerIdentities[0].uriSAN
                )
            let replacement = try connectLoopback(
                route: request.route,
                identity: identity,
                binding: existing.binding,
                evidence: existing.evidence,
                credentials: credentials,
                timeoutMilliseconds:
                    request.timeoutMilliseconds
            )
            do {
                return try lock.withLock {
                    guard reconnectingRoutes.contains(
                        request.route.routeUUID
                    ),
                    sessions[request.route.routeUUID] == nil,
                    remoteSessions[request.route.routeUUID] == nil else {
                        throw NetworkHelperError.tunnelRejected
                    }
                    sessions[request.route.routeUUID] =
                        replacement
                    do {
                        try controller.activate(
                            routeUUID:
                                request.route.routeUUID,
                            fencingToken:
                                request.route.fencingToken
                        )
                        reconnectingRoutes.remove(
                            request.route.routeUUID
                        )
                        return try currentResult(
                            route: request.route,
                            live: true,
                            reconnectDelayMilliseconds:
                                reconnectDelay
                        )
                    } catch {
                        sessions.removeValue(
                            forKey:
                                request.route.routeUUID
                        )
                        reconnectingRoutes.remove(
                            request.route.routeUUID
                        )
                        throw error
                    }
                }
            } catch {
                close(replacement, drain: false)
                throw error
            }
        } catch {
            _ = lock.withLock {
                reconnectingRoutes.remove(
                    request.route.routeUUID
                )
            }
            throw error
        }
    }

    func rotateKey(
        identity: NetworkHelperDNSIdentity,
        request: NetworkHelperTunnelRequest
    ) throws -> NetworkHelperTunnelResult {
        try lock.withLock {
            let request = try request.validated(
                identity: identity
            )
            guard !reconnectingRoutes.contains(
                request.route.routeUUID
            ) else {
                throw NetworkHelperError.tunnelRejected
            }
            if let session =
                    remoteSessions[request.route.routeUUID] {
                guard session.route == request.route,
                      session.identity == identity,
                      session.execution == request.execution else {
                    throw NetworkHelperError.tunnelRejected
                }
                try controller.rotateKey(
                    routeUUID: request.route.routeUUID,
                    fencingToken: request.route.fencingToken
                )
                return try currentResult(
                    route: request.route,
                    live: true
                )
            }
            guard let session =
                    sessions[request.route.routeUUID],
                  session.route == request.route,
                  session.identity == identity else {
                throw NetworkHelperError.tunnelRejected
            }
            try controller.rotateKey(
                routeUUID: request.route.routeUUID,
                fencingToken: request.route.fencingToken
            )
            return try currentResult(
                route: request.route,
                live: true
            )
        }
    }

    func drain(
        identity: NetworkHelperDNSIdentity,
        request: NetworkHelperTunnelRequest
    ) throws -> NetworkHelperTunnelResult {
        try lock.withLock {
            let request = try request.validated(
                identity: identity
            )
            guard !reconnectingRoutes.contains(
                request.route.routeUUID
            ) else {
                throw NetworkHelperError.tunnelRejected
            }
            if let existing = remoteSessions[
                request.route.routeUUID
            ] {
                guard existing.route == request.route,
                      existing.identity == identity,
                      existing.execution == request.execution else {
                    throw NetworkHelperError.tunnelRejected
                }
                remoteSessions.removeValue(
                    forKey: request.route.routeUUID
                )
                close(existing, drain: true)
                try controller.sleep(
                    routeUUID: request.route.routeUUID,
                    fencingToken: request.route.fencingToken
                )
                return try currentResult(
                    route: request.route,
                    live: false
                )
            }
            if let existing = sessions[
                request.route.routeUUID
            ] {
                guard existing.route == request.route,
                      existing.identity == identity else {
                    throw NetworkHelperError.tunnelRejected
                }
                sessions.removeValue(
                    forKey: request.route.routeUUID
                )
                close(existing, drain: true)
            } else {
                identityRegistry.admit(request.route)
                try controller.recover(route: request.route)
            }
            try controller.sleep(
                routeUUID: request.route.routeUUID,
                fencingToken: request.route.fencingToken
            )
            return try currentResult(
                route: request.route,
                live: false
            )
        }
    }

    func teardown(
        identity: NetworkHelperDNSIdentity,
        request: NetworkHelperTunnelRequest
    ) throws -> NetworkHelperTunnelResult {
        try lock.withLock {
            let request = try request.validated(
                identity: identity
            )
            guard !reconnectingRoutes.contains(
                request.route.routeUUID
            ) else {
                throw NetworkHelperError.tunnelRejected
            }
            if let existing = remoteSessions[
                request.route.routeUUID
            ] {
                guard existing.route == request.route,
                      existing.identity == identity,
                      existing.execution == request.execution else {
                    throw NetworkHelperError.tunnelRejected
                }
                remoteSessions.removeValue(
                    forKey: request.route.routeUUID
                )
                close(existing, drain: true)
                try controller.teardown(
                    routeUUID: request.route.routeUUID,
                    fencingToken: request.route.fencingToken
                )
                identityRegistry.revoke(
                    request.route.routeUUID
                )
                return NetworkHelperTunnelResult(
                    route: request.route,
                    phase: .closed,
                    selectedTransport: nil,
                    live: false,
                    reconnectAttempt: 0,
                    observedSHA256:
                        request.route.desiredSHA256
                )
            }
            if let existing = sessions[
                request.route.routeUUID
            ] {
                guard existing.route == request.route,
                      existing.identity == identity else {
                    throw NetworkHelperError.tunnelRejected
                }
                sessions.removeValue(
                    forKey: request.route.routeUUID
                )
                close(existing, drain: true)
                try certificateCoordinator.cleanup(
                    identity: identity,
                    evidence: existing.evidence
                )
            } else if try store.load(
                routeUUID: request.route.routeUUID
            ) != nil {
                let binding = try certificateBinding(
                    identity: identity,
                    route: request.route
                )
                try certificateCoordinator
                    .cleanupUnrecordedManagedIdentities(
                        identity: identity,
                        bindings: [binding]
                    )
                identityRegistry.admit(request.route)
                try controller.recover(route: request.route)
            } else {
                identityRegistry.revoke(request.route.routeUUID)
                return NetworkHelperTunnelResult(
                    route: request.route,
                    phase: .closed,
                    selectedTransport: nil,
                    live: false,
                    reconnectAttempt: 0,
                    observedSHA256:
                        request.route.desiredSHA256
                )
            }
            try controller.teardown(
                routeUUID: request.route.routeUUID,
                fencingToken: request.route.fencingToken
            )
            identityRegistry.revoke(request.route.routeUUID)
            certificateCoordinator.deactivate(identity: identity)
            return NetworkHelperTunnelResult(
                route: request.route,
                phase: .closed,
                selectedTransport: nil,
                live: false,
                reconnectAttempt: 0,
                observedSHA256: request.route.desiredSHA256
            )
        }
    }

    private func setupRemote(
        identity: NetworkHelperDNSIdentity,
        request: NetworkHelperTunnelRequest,
        execution: NetworkHelperTunnelExecution
    ) throws -> NetworkHelperTunnelResult {
        if let current =
                remoteSessions[request.route.routeUUID] {
            guard current.route == request.route,
                  current.identity == identity,
                  current.execution == execution else {
                throw NetworkHelperError.tunnelRejected
            }
            return try currentResult(
                route: request.route,
                live: true
            )
        }
        guard sessions[request.route.routeUUID] == nil else {
            throw NetworkHelperError.tunnelRejected
        }
        identityRegistry.admit(request.route)
        do {
            if try store.load(
                routeUUID: request.route.routeUUID
            ) != nil {
                try controller.recover(route: request.route)
            } else {
                _ = try controller.begin(route: request.route)
            }
            let session = try connectRemote(
                route: request.route,
                identity: identity,
                execution: execution,
                timeoutMilliseconds:
                    request.timeoutMilliseconds
            )
            remoteSessions[request.route.routeUUID] = session
            try controller.activate(
                routeUUID: request.route.routeUUID,
                fencingToken: request.route.fencingToken
            )
            return try currentResult(
                route: request.route,
                live: true
            )
        } catch {
            if let session = remoteSessions.removeValue(
                forKey: request.route.routeUUID
            ) {
                close(session, drain: false)
            }
            identityRegistry.revoke(request.route.routeUUID)
            throw error
        }
    }

    private func reconnectRemote(
        identity: NetworkHelperDNSIdentity,
        request: NetworkHelperTunnelRequest,
        execution: NetworkHelperTunnelExecution
    ) throws -> NetworkHelperTunnelResult {
        let existing = try lock.withLock {
            guard reconnectingRoutes.insert(
                request.route.routeUUID
            ).inserted,
            let existing = remoteSessions[
                request.route.routeUUID
            ], existing.route == request.route,
            existing.identity == identity,
            existing.execution == execution else {
                reconnectingRoutes.remove(
                    request.route.routeUUID
                )
                throw NetworkHelperError.tunnelRejected
            }
            remoteSessions.removeValue(
                forKey: request.route.routeUUID
            )
            return existing
        }
        close(existing, drain: false)
        do {
            let reconnectDelay = try controller.reconnect(
                routeUUID: request.route.routeUUID,
                fencingToken: request.route.fencingToken
            )
            Thread.sleep(
                forTimeInterval:
                    Double(reconnectDelay) / 1_000
            )
            let replacement = try connectRemote(
                route: request.route,
                identity: identity,
                execution: execution,
                timeoutMilliseconds:
                    request.timeoutMilliseconds
            )
            do {
                return try lock.withLock {
                    guard reconnectingRoutes.contains(
                        request.route.routeUUID
                    ),
                    sessions[request.route.routeUUID] == nil,
                    remoteSessions[request.route.routeUUID] == nil else {
                        throw NetworkHelperError.tunnelRejected
                    }
                    remoteSessions[request.route.routeUUID] =
                        replacement
                    do {
                        try controller.activate(
                            routeUUID:
                                request.route.routeUUID,
                            fencingToken:
                                request.route.fencingToken
                        )
                        reconnectingRoutes.remove(
                            request.route.routeUUID
                        )
                        return try currentResult(
                            route: request.route,
                            live: true,
                            reconnectDelayMilliseconds:
                                reconnectDelay
                        )
                    } catch {
                        remoteSessions.removeValue(
                            forKey:
                                request.route.routeUUID
                        )
                        reconnectingRoutes.remove(
                            request.route.routeUUID
                        )
                        throw error
                    }
                }
            } catch {
                close(replacement, drain: false)
                throw error
            }
        } catch {
            _ = lock.withLock {
                reconnectingRoutes.remove(
                    request.route.routeUUID
                )
            }
            identityRegistry.revoke(request.route.routeUUID)
            throw error
        }
    }

    private func connectRemote(
        route: HostwrightTunnelRoute,
        identity: NetworkHelperDNSIdentity,
        execution: NetworkHelperTunnelExecution,
        timeoutMilliseconds: Int64
    ) throws -> RemoteSession {
        let wireRoute = try HostwrightTunnelRoute(
            routeUUID: execution.wireRouteUUID,
            projectUUID: route.projectUUID,
            peerUUID: route.peerUUID,
            generation: execution.wireGeneration,
            providerID: route.providerID,
            providerGeneration: route.providerGeneration,
            fencingToken: execution.wireFencingToken,
            operationGroupID: route.operationGroupID,
            desiredSHA256: route.desiredSHA256,
            role: route.role,
            trust: route.trust,
            bindEndpoint: route.bindEndpoint,
            forwardEndpoint: route.forwardEndpoint,
            authenticatedEndpoints:
                route.authenticatedEndpoints,
            relayEndpoint: route.relayEndpoint
        )
        let credentials =
            try HostwrightTunnelCertificateCoordinatorAdapter(
                coordinator: certificateCoordinator
            ).remoteCredentials(execution: execution)
        let deadline =
            HostwrightServiceTunnelConnection.nowMilliseconds()
            + timeoutMilliseconds
        switch execution.role {
        case .listener:
            guard let bindEndpoint = route.bindEndpoint,
                  let target = execution.serviceTarget else {
                throw NetworkHelperError.tunnelRejected
            }
            let endpoint = try HostwrightTunnelEndpoint(
                host: bindEndpoint.host,
                port: bindEndpoint.port
            )
            let listener = try HostwrightServiceTunnelListener(
                route: wireRoute,
                credentials: credentials,
                host: endpoint.host,
                port: endpoint.port
            )
            do {
                try listener.start(
                    deadlineUnixMilliseconds: deadline
                )
                guard listener.port == endpoint.port else {
                    throw HostwrightTunnelSocketError
                        .connectionFailed
                }
                let forwarder =
                    HostwrightTunnelServiceForwarder(
                        listener: listener,
                        target: target
                    )
                forwarder.start()
                return RemoteSession(
                    route: route,
                    identity: identity,
                    execution: execution,
                    transport: .listener(
                        listener,
                        forwarder
                    )
                )
            } catch {
                listener.stop()
                throw error
            }
        case .dialer:
            guard let localForwardEndpoint =
                    execution.localForwardEndpoint else {
                throw NetworkHelperError.tunnelRejected
            }
            let connect:
                @Sendable () throws ->
                    HostwrightServiceTunnelConnection = {
                let connection =
                    try HostwrightServiceTunnelDialer {
                        _, _, _ in credentials
                    }.connect(
                    route: wireRoute,
                    deadlineUnixMilliseconds:
                        HostwrightServiceTunnelConnection
                            .nowMilliseconds()
                        + timeoutMilliseconds
                )
                try connection.startKeepalive(
                    intervalMilliseconds: 5_000
                )
                return connection
            }
            let connection = try connect()
            let forwarder = try HostwrightTunnelLocalForwarder(
                initialTunnel: connection,
                endpoint: localForwardEndpoint,
                connect: connect
            )
            do {
                try forwarder.start(
                    deadlineUnixMilliseconds: deadline
                )
            } catch {
                connection.cancel()
                throw error
            }
            return RemoteSession(
                route: route,
                identity: identity,
                execution: execution,
                transport: .dialer(
                    connection,
                    forwarder
                )
            )
        }
    }

    private func connectLoopback(
        route: HostwrightTunnelRoute,
        identity: NetworkHelperDNSIdentity,
        binding: ProjectCertificateRequestBinding,
        evidence: NetworkHelperPersistedCertificateEvidence,
        credentials: HostwrightTunnelLoopbackCredentials,
        timeoutMilliseconds: Int64
    ) throws -> LiveSession {
        let deadline =
            HostwrightServiceTunnelConnection.nowMilliseconds()
            + timeoutMilliseconds
        guard let endpoint =
                route.authenticatedEndpoints.first(where: {
                    $0.host == "127.0.0.1" ||
                        $0.host == "localhost" ||
                        $0.host == "::1"
                }) else {
            throw NetworkHelperError.tunnelRejected
        }
        let listener = try HostwrightServiceTunnelListener(
            route: route,
            credentials: credentials.server,
            host: endpoint.host,
            port: endpoint.port
        )
        do {
            try listener.start(
                deadlineUnixMilliseconds: deadline
            )
            guard listener.port == endpoint.port else {
                throw HostwrightTunnelSocketError.connectionFailed
            }
            let client = try HostwrightServiceTunnelDialer {
                _, _, _ in credentials.client
            }.connect(
                route: route,
                deadlineUnixMilliseconds: deadline
            )
            do {
                let server = try listener.next(
                    deadlineUnixMilliseconds: deadline
                )
                let proof = Data("hostwright-tunnel-ready".utf8)
                _ = try client.send(
                    channel: 0,
                    payload: proof,
                    deadlineUnixMilliseconds: deadline
                )
                let frame = try server.receive(
                    deadlineUnixMilliseconds: deadline
                )
                guard frame?.payload == proof else {
                    throw HostwrightTunnelSocketError
                        .connectionFailed
                }
                try client.startKeepalive(
                    intervalMilliseconds: 5_000
                )
                return LiveSession(
                    route: route,
                    identity: identity,
                    binding: binding,
                    evidence: evidence,
                    listener: listener,
                    client: client,
                    server: server
                )
            } catch {
                client.cancel()
                throw error
            }
        } catch {
            listener.stop()
            throw error
        }
    }

    private func currentResult(
        route: HostwrightTunnelRoute,
        live: Bool,
        reconnectDelayMilliseconds: Int? = nil
    ) throws -> NetworkHelperTunnelResult {
        guard let intent = try store.load(
            routeUUID: route.routeUUID
        ), intent.route == route else {
            throw NetworkHelperError.tunnelRejected
        }
        return NetworkHelperTunnelResult(
            intent: intent,
            live: live,
            metrics: controller.metrics(
                routeUUID: route.routeUUID
            ),
            reconnectDelayMilliseconds:
                reconnectDelayMilliseconds
        )
    }

    private func close(
        _ session: LiveSession,
        drain: Bool
    ) {
        if drain {
            try? session.client.drain(
                deadlineUnixMilliseconds:
                    HostwrightServiceTunnelConnection
                        .nowMilliseconds() + 1_000
            )
        }
        session.client.cancel()
        session.server.cancel()
        session.listener.stop()
    }

    private func close(
        _ session: RemoteSession,
        drain: Bool
    ) {
        switch session.transport {
        case .listener(let listener, let forwarder):
            forwarder.stop()
            listener.stop()
        case .dialer(let connection, let forwarder):
            forwarder.stop()
            if drain {
                try? connection.drain(
                    deadlineUnixMilliseconds:
                        HostwrightServiceTunnelConnection
                            .nowMilliseconds() + 1_000
                )
            }
            connection.cancel()
        }
    }

    private func certificateBinding(
        identity: NetworkHelperDNSIdentity,
        route: HostwrightTunnelRoute
    ) throws -> ProjectCertificateRequestBinding {
        guard identity.dnsUUID == route.routeUUID,
              Int64(identity.generation) == route.generation,
              identity.fencingToken == route.fencingToken,
              let generation = Int(exactly: route.generation) else {
            throw NetworkHelperError.invalidTunnel
        }
        let peer = try HostwrightMutualTLSIdentity(
            projectUUID: route.projectUUID,
            resourceUUID: route.peerUUID,
            role: .tunnel,
            generation: generation
        )
        return ProjectCertificateRequestBinding(
            name: "tunnel",
            certificateUUID:
                try certificateUUID(route.routeUUID),
            source: .localCA,
            renewBeforeSeconds: 3_600,
            validitySeconds: 86_400,
            statusPolicy: .ifAvailable,
            dnsNames: ["tunnel.internal"],
            identityRole: .tunnel,
            peerIdentities: [peer]
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func certificateUUID(
        _ routeUUID: String
    ) throws -> String {
        guard let value = UUID(uuidString: routeUUID) else {
            throw NetworkHelperError.invalidTunnel
        }
        var bytes = value.uuid
        withUnsafeMutableBytes(of: &bytes) {
            $0[15] ^= 0x80
        }
        return UUID(uuid: bytes).uuidString.lowercased()
    }

    private static func isLoopbackEndpoint(
        _ endpoint: HostwrightTunnelEndpoint
    ) -> Bool {
        endpoint.host == "127.0.0.1" ||
            endpoint.host == "localhost" ||
            endpoint.host == "::1"
    }
}
