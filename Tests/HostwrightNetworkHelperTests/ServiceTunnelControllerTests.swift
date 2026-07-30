import Foundation
import HostwrightNetworking
import XCTest
@testable import HostwrightNetworkHelperCore

final class ServiceTunnelControllerTests: XCTestCase {
    private let project = "11111111-1111-4111-8111-111111111111"
    private let peer = "22222222-2222-4222-8222-222222222222"
    private let fence = "33333333-3333-4333-8333-333333333333"

    func testDirectIsPreferredAndReplayAndStaleFenceAreRejected() throws {
        let subject = try controller()
        let route = try route()
        let endpoint = try HostwrightTunnelEndpoint(host: "peer.local", port: 443)
        let candidate = try HostwrightBonjourTunnelCandidate(serviceName: "_hostwright._tcp", endpoint: endpoint, peerUUID: peer)
        XCTAssertEqual(try subject.begin(route: route, candidates: [candidate]), .direct)
        try subject.activate(routeUUID: route.routeUUID, fencingToken: fence)
        let frame = try HostwrightTunnelFrame(routeUUID: route.routeUUID, generation: 1, fencingToken: fence, channel: 0, sequence: 1, payload: Data("ok".utf8))
        try subject.receive(frame)
        XCTAssertThrowsError(try subject.receive(frame))
        XCTAssertThrowsError(try subject.activate(routeUUID: route.routeUUID, fencingToken: "44444444-4444-4444-8444-444444444444"))
    }

    func testPartitionReconnectRotationAndExactTeardownPersistIntent() throws {
        let store = MemoryStore()
        let subject = HostwrightTunnelController(identityProvider: Identity(), store: store, now: { 1_000 })
        let route = try route()
        _ = try subject.begin(route: route)
        try subject.activate(routeUUID: route.routeUUID, fencingToken: fence)
        XCTAssertEqual(try subject.reconnect(routeUUID: route.routeUUID, fencingToken: fence), 500)
        try subject.rotateKey(routeUUID: route.routeUUID, fencingToken: fence)
        XCTAssertEqual(
            try store.load(
                routeUUID: route.routeUUID
            )?.keyEpoch,
            2
        )
        XCTAssertEqual(
            try store.load(
                routeUUID: route.routeUUID
            )?.reconnectAttempt,
            0
        )
        try subject.teardown(routeUUID: route.routeUUID, fencingToken: fence)
        XCTAssertNil(try store.load(routeUUID: route.routeUUID))
        XCTAssertEqual(subject.metrics(routeUUID: route.routeUUID)?.keyRotations, 1)
        XCTAssertEqual(subject.metrics(routeUUID: route.routeUUID)?.teardownCount, 1)
    }

    func testAsymmetricDiscoveryUsesOnlyExplicitRelay() throws {
        let subject = HostwrightTunnelController(identityProvider: Identity(), store: MemoryStore())
        let relay = try HostwrightTunnelEndpoint(host: "relay.example.test", port: 443)
        let route = try HostwrightTunnelRoute(projectUUID: project, peerUUID: peer, generation: 1, providerID: "apple-container-cli", providerGeneration: 1, fencingToken: fence, operationGroupID: "55555555-5555-4555-8555-555555555555", desiredSHA256: String(repeating: "a", count: 64), authenticatedEndpoints: [try HostwrightTunnelEndpoint(host: "peer.local", port: 443)], relayEndpoint: relay)
        let other = try HostwrightBonjourTunnelCandidate(serviceName: "_hostwright._tcp", endpoint: relay, peerUUID: "44444444-4444-4444-8444-444444444444")
        XCTAssertEqual(try subject.begin(route: route, candidates: [other]), .relay)
    }

    func testCrashRecoveryAndSleepWakeNeverBypassDurableIntent() throws {
        let store = MemoryStore()
        let route = try route()
        let first = HostwrightTunnelController(identityProvider: Identity(), store: store)
        _ = try first.begin(route: route)
        let recovered = HostwrightTunnelController(identityProvider: Identity(), store: store)
        try recovered.recover(route: route)
        try recovered.activate(routeUUID: route.routeUUID, fencingToken: fence)
        try recovered.sleep(routeUUID: route.routeUUID, fencingToken: fence)
        try recovered.wake(routeUUID: route.routeUUID, fencingToken: fence)
        XCTAssertEqual(try store.load(routeUUID: route.routeUUID)?.phase, .connecting)
    }

    func testRejectsRevocationDowngradeAndConflictingGeneration() throws {
        let route = try route()
        XCTAssertThrowsError(try HostwrightTunnelController(identityProvider: Identity(revoked: true), store: MemoryStore()).begin(route: route))
        XCTAssertThrowsError(try HostwrightTunnelController(identityProvider: Identity(tls: "TLS1.2"), store: MemoryStore()).begin(route: route))
    }

    private func controller() throws -> HostwrightTunnelController {
        HostwrightTunnelController(identityProvider: Identity(), store: MemoryStore(), now: { 1_000 })
    }
    private func route() throws -> HostwrightTunnelRoute {
        try HostwrightTunnelRoute(projectUUID: project, peerUUID: peer, generation: 1, providerID: "apple-container-cli", providerGeneration: 1, fencingToken: fence, operationGroupID: "55555555-5555-4555-8555-555555555555", desiredSHA256: String(repeating: "a", count: 64), authenticatedEndpoints: [try HostwrightTunnelEndpoint(host: "peer.local", port: 443)])
    }
    private struct Identity: HostwrightTunnelIdentityProviding {
        var tls = "TLS1.3"; var revoked = false
        func authenticate(projectUUID: String, peerUUID: String, generation: Int64) throws -> HostwrightTunnelIdentity { .init(peerUUID: peerUUID, generation: generation, tlsVersion: tls, authenticated: true, revoked: revoked) }
    }
    private final class MemoryStore: HostwrightTunnelIntentPersisting, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: HostwrightTunnelSessionIntent] = [:]
        func save(_ intent: HostwrightTunnelSessionIntent) throws { lock.withLock { values[intent.route.routeUUID] = intent } }
        func load(routeUUID: String) throws -> HostwrightTunnelSessionIntent? { lock.withLock { values[routeUUID] } }
        func remove(routeUUID: String, generation: Int64, fencingToken: String) throws {
            try lock.withLock {
                guard let value = values[routeUUID],
                      value.route.generation == generation,
                      value.route.fencingToken == fencingToken else {
                    throw HostwrightTunnelControllerError.staleFence
                }
                values.removeValue(forKey: routeUUID)
            }
        }
    }
}
