import Foundation
import HostwrightNetworking

protocol HostwrightTunnelIdentityProviding: Sendable {
    func authenticate(projectUUID: String, peerUUID: String, generation: Int64) throws -> HostwrightTunnelIdentity
}

struct HostwrightTunnelIdentity: Equatable, Sendable {
    let peerUUID: String
    let generation: Int64
    let tlsVersion: String
    let authenticated: Bool
    let revoked: Bool
}

struct HostwrightTunnelMetrics: Equatable, Sendable {
    var reconnects = 0
    var keyRotations = 0
    var rejectedFrames = 0
    var teardownCount = 0
}

enum HostwrightTunnelControllerError: Error, Equatable {
    case notFound, staleFence, conflictingGeneration, duplicatePeer, unauthenticated, revoked, downgrade, routeReplay, invalidTransition
}

/// Deterministic tunnel state machine. The connector is injected: this layer
/// owns admission, durable intent, and lifecycle; it performs no socket or VPN
/// mutation itself.
final class HostwrightTunnelController: @unchecked Sendable {
    private struct Session {
        var intent: HostwrightTunnelSessionIntent
        var lastSequence: [Int: UInt64] = [:]
        var metrics = HostwrightTunnelMetrics()
    }
    private let identityProvider: any HostwrightTunnelIdentityProviding
    private let store: any HostwrightTunnelIntentPersisting
    private let now: @Sendable () -> Int64
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var highestGenerationByPeer: [String: Int64] = [:]

    init(identityProvider: any HostwrightTunnelIdentityProviding, store: any HostwrightTunnelIntentPersisting, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.identityProvider = identityProvider
        self.store = store
        self.now = now
    }

    func begin(route: HostwrightTunnelRoute, candidates: [HostwrightBonjourTunnelCandidate] = []) throws -> HostwrightTunnelTransport {
        try lock.withLock {
            if let current = highestGenerationByPeer[route.peerUUID], current > route.generation { throw HostwrightTunnelControllerError.conflictingGeneration }
            if let existing = sessions.values.first(where: { $0.intent.route.peerUUID == route.peerUUID && $0.intent.route.routeUUID != route.routeUUID && $0.intent.phase != .closed }), existing.intent.route.generation >= route.generation { throw HostwrightTunnelControllerError.duplicatePeer }
            if let recovered = try store.load(routeUUID: route.routeUUID) {
                guard recovered.route.fencingToken == route.fencingToken else { throw HostwrightTunnelControllerError.staleFence }
                guard recovered.route.generation == route.generation else { throw HostwrightTunnelControllerError.conflictingGeneration }
            }
            let identity = try identityProvider.authenticate(projectUUID: route.projectUUID, peerUUID: route.peerUUID, generation: route.generation)
            guard identity.authenticated, identity.peerUUID == route.peerUUID, identity.generation == route.generation else { throw HostwrightTunnelControllerError.unauthenticated }
            guard identity.tlsVersion == "TLS1.3" else { throw HostwrightTunnelControllerError.downgrade }
            guard !identity.revoked else { throw HostwrightTunnelControllerError.revoked }
            // Bonjour candidates are accepted only if their already-authenticated endpoint is declared by the route.
            // An empty candidate set means the explicitly configured endpoint
            // is dialed directly. A non-empty discovery response must contain
            // the exact authenticated peer or it is asymmetric and relay may
            // be considered only when the route opted into one.
            let directAvailable = candidates.isEmpty || candidates.contains { $0.peerUUID == route.peerUUID && route.authenticatedEndpoints.contains($0.endpoint) }
            let transport: HostwrightTunnelTransport = directAvailable ? .direct : .relay
            guard transport == .direct || route.relayEndpoint != nil else { throw HostwrightTunnelControllerError.invalidTransition }
            let intent = HostwrightTunnelSessionIntent(route: route, phase: .connecting, finalizer: .pending, selectedTransport: transport, keyEpoch: 1, reconnectAttempt: 0, observedSHA256: nil, updatedAtUnixMilliseconds: now())
            try store.save(intent)
            sessions[route.routeUUID] = Session(intent: intent)
            highestGenerationByPeer[route.peerUUID] = route.generation
            return transport
        }
    }

    func activate(routeUUID: String, fencingToken: String) throws {
        try transition(routeUUID: routeUUID, fencingToken: fencingToken, phase: .active)
    }

    /// Recovery restores only the persisted intent; the caller must still
    /// perform a fresh authenticated connection attempt before activation.
    func recover(route: HostwrightTunnelRoute) throws {
        try lock.withLock {
            guard let intent = try store.load(routeUUID: route.routeUUID) else {
                throw HostwrightTunnelControllerError.notFound
            }
            guard intent.route == route else { throw HostwrightTunnelControllerError.routeReplay }
            guard intent.phase != .closed else { throw HostwrightTunnelControllerError.invalidTransition }
            let recovered = HostwrightTunnelSessionIntent(route: route, phase: .connecting, finalizer: intent.finalizer, selectedTransport: intent.selectedTransport, keyEpoch: intent.keyEpoch, reconnectAttempt: intent.reconnectAttempt, observedSHA256: intent.observedSHA256, updatedAtUnixMilliseconds: now())
            try store.save(recovered)
            sessions[route.routeUUID] = Session(intent: recovered)
            highestGenerationByPeer[route.peerUUID] = route.generation
        }
    }

    func sleep(routeUUID: String, fencingToken: String) throws {
        try transition(routeUUID: routeUUID, fencingToken: fencingToken, phase: .draining)
    }

    func wake(routeUUID: String, fencingToken: String) throws {
        try transition(routeUUID: routeUUID, fencingToken: fencingToken, phase: .connecting)
    }

    func reconnect(routeUUID: String, fencingToken: String) throws -> Int {
        try lock.withLock {
            var session = try checked(routeUUID, fencingToken)
            guard session.intent.phase == .active || session.intent.phase == .connecting else { throw HostwrightTunnelControllerError.invalidTransition }
            session.intent = HostwrightTunnelSessionIntent(route: session.intent.route, phase: .connecting, finalizer: session.intent.finalizer, selectedTransport: session.intent.selectedTransport, keyEpoch: session.intent.keyEpoch, reconnectAttempt: min(session.intent.reconnectAttempt + 1, 8), observedSHA256: session.intent.observedSHA256, updatedAtUnixMilliseconds: now())
            session.metrics.reconnects += 1
            try store.save(session.intent); sessions[routeUUID] = session
            return min(30_000, 250 * (1 << session.intent.reconnectAttempt))
        }
    }

    func rotateKey(routeUUID: String, fencingToken: String) throws {
        try lock.withLock {
            var session = try checked(routeUUID, fencingToken)
            session.intent = HostwrightTunnelSessionIntent(route: session.intent.route, phase: session.intent.phase, finalizer: session.intent.finalizer, selectedTransport: session.intent.selectedTransport, keyEpoch: session.intent.keyEpoch + 1, reconnectAttempt: 0, observedSHA256: session.intent.observedSHA256, updatedAtUnixMilliseconds: now())
            session.metrics.keyRotations += 1; try store.save(session.intent); sessions[routeUUID] = session
        }
    }

    func receive(_ frame: HostwrightTunnelFrame) throws {
        try lock.withLock {
            var session = try checked(frame.routeUUID, frame.fencingToken)
            guard session.intent.phase == .active, frame.generation == session.intent.route.generation else { session.metrics.rejectedFrames += 1; sessions[frame.routeUUID] = session; throw HostwrightTunnelControllerError.routeReplay }
            if let last = session.lastSequence[frame.channel], frame.sequence <= last { session.metrics.rejectedFrames += 1; sessions[frame.routeUUID] = session; throw HostwrightTunnelControllerError.routeReplay }
            session.lastSequence[frame.channel] = frame.sequence; sessions[frame.routeUUID] = session
        }
    }

    func teardown(routeUUID: String, fencingToken: String) throws {
        try lock.withLock {
            var session = try checked(routeUUID, fencingToken)
            session.intent = HostwrightTunnelSessionIntent(route: session.intent.route, phase: .draining, finalizer: .releasing, selectedTransport: session.intent.selectedTransport, keyEpoch: session.intent.keyEpoch, reconnectAttempt: 0, observedSHA256: session.intent.observedSHA256, updatedAtUnixMilliseconds: now())
            try store.save(session.intent)
            session.intent = HostwrightTunnelSessionIntent(route: session.intent.route, phase: .closed, finalizer: .released, selectedTransport: session.intent.selectedTransport, keyEpoch: session.intent.keyEpoch, reconnectAttempt: 0, observedSHA256: session.intent.observedSHA256 ?? session.intent.route.desiredSHA256, updatedAtUnixMilliseconds: now())
            session.metrics.teardownCount += 1; try store.save(session.intent); sessions[routeUUID] = session
            try store.remove(routeUUID: routeUUID, generation: session.intent.route.generation, fencingToken: fencingToken)
        }
    }

    func metrics(routeUUID: String) -> HostwrightTunnelMetrics? { lock.withLock { sessions[routeUUID]?.metrics } }

    private func transition(routeUUID: String, fencingToken: String, phase: HostwrightTunnelSessionPhase) throws {
        try lock.withLock {
            var session = try checked(routeUUID, fencingToken)
            let finalizer: HostwrightTunnelFinalizer
            if phase == .active {
                finalizer = .active
            } else if phase == .draining {
                finalizer = .releasing
            } else if phase == .connecting {
                finalizer = session.intent.observedSHA256 == nil ? .pending : .active
            } else {
                finalizer = session.intent.finalizer
            }
            let observed = phase == .active ? session.intent.route.desiredSHA256 : session.intent.observedSHA256
            session.intent = HostwrightTunnelSessionIntent(route: session.intent.route, phase: phase, finalizer: finalizer, selectedTransport: session.intent.selectedTransport, keyEpoch: session.intent.keyEpoch, reconnectAttempt: session.intent.reconnectAttempt, observedSHA256: observed, updatedAtUnixMilliseconds: now())
            try store.save(session.intent)
            sessions[routeUUID] = session
        }
    }
    private func checked(_ routeUUID: String, _ fence: String) throws -> Session {
        guard let session = sessions[routeUUID] else { throw HostwrightTunnelControllerError.notFound }
        guard session.intent.route.fencingToken == fence.lowercased() else { throw HostwrightTunnelControllerError.staleFence }
        return session
    }
}
