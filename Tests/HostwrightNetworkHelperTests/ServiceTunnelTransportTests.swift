import CryptoKit
import Darwin
import Foundation
import HostwrightNetworking
import XCTest

@testable import HostwrightNetworkHelperCore

final class ServiceTunnelTransportTests: XCTestCase {
    private let project =
        "11111111-1111-4111-8111-111111111111"
    private let peer =
        "44444444-4444-4444-8444-444444444444"
    private let fence =
        "33333333-3333-4333-8333-333333333333"
    private let operationGroup =
        "55555555-5555-4555-8555-555555555555"

    func testTLS13LoopbackMultiplexesChannelsAndDrains()
        throws
    {
        let fixture = try certificateFixture()
        defer { fixture.cleanup() }
        let port = try availablePort()
        let route = try makeRoute(directPort: port)
        let listener = try HostwrightServiceTunnelListener(
            route: route,
            credentials: fixture.credentials.server,
            port: port
        )
        defer { listener.stop() }
        let deadline = now() + 8_000
        try listener.start(deadlineUnixMilliseconds: deadline)

        let dialer = HostwrightServiceTunnelDialer {
            _, _, _ in fixture.credentials.client
        }
        let client = try dialer.connect(
            route: route,
            deadlineUnixMilliseconds: deadline
        )
        defer { client.cancel() }
        let server = try listener.next(
            deadlineUnixMilliseconds: deadline
        )
        defer { server.cancel() }

        try client.startKeepalive(
            intervalMilliseconds: 1_000
        )
        XCTAssertEqual(
            try client.send(
                channel: 7,
                payload: Data("first".utf8),
                deadlineUnixMilliseconds: deadline
            ).sequence,
            1
        )
        XCTAssertEqual(
            try client.send(
                channel: 9,
                payload: Data("other".utf8),
                deadlineUnixMilliseconds: deadline
            ).sequence,
            1
        )
        XCTAssertEqual(
            try client.send(
                channel: 7,
                payload: Data("second".utf8),
                deadlineUnixMilliseconds: deadline
            ).sequence,
            2
        )

        let first = try XCTUnwrap(
            server.receive(
                deadlineUnixMilliseconds: deadline
            )
        )
        let other = try XCTUnwrap(
            server.receive(
                deadlineUnixMilliseconds: deadline
            )
        )
        let second = try XCTUnwrap(
            server.receive(
                deadlineUnixMilliseconds: deadline
            )
        )
        XCTAssertEqual(first.channel, 7)
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.payload, Data("first".utf8))
        XCTAssertEqual(other.channel, 9)
        XCTAssertEqual(other.sequence, 1)
        XCTAssertEqual(other.payload, Data("other".utf8))
        XCTAssertEqual(second.channel, 7)
        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(second.payload, Data("second".utf8))

        try client.drain(
            deadlineUnixMilliseconds: deadline
        )
        XCTAssertNil(
            try server.receive(
                deadlineUnixMilliseconds: deadline
            )
        )
    }

    func testDirectFailureFallsBackOnlyToExplicitRelay()
        throws
    {
        let fixture = try certificateFixture()
        defer { fixture.cleanup() }
        let directPort = try availablePort()
        let relayPort = try availablePort()
        let route = try makeRoute(
            directPort: directPort,
            relayPort: relayPort
        )
        let listener = try HostwrightServiceTunnelListener(
            route: route,
            credentials: fixture.credentials.server,
            port: relayPort
        )
        defer { listener.stop() }
        let deadline = now() + 8_000
        try listener.start(deadlineUnixMilliseconds: deadline)
        let dialer = HostwrightServiceTunnelDialer {
            _, _, _ in fixture.credentials.client
        }

        let client = try dialer.connect(
            route: route,
            deadlineUnixMilliseconds: deadline
        )
        defer { client.cancel() }
        XCTAssertEqual(client.transport, .relay)
        let server = try listener.next(
            deadlineUnixMilliseconds: deadline
        )
        server.cancel()
    }

    func testCancellationAndRevokedPeerEvidenceFailClosed()
        throws
    {
        let fixture = try certificateFixture()
        defer { fixture.cleanup() }
        let port = try availablePort()
        let route = try makeRoute(directPort: port)
        let cancelled = HostwrightTunnelCancellation()
        cancelled.cancel()
        let dialer = HostwrightServiceTunnelDialer {
            _, _, _ in fixture.credentials.client
        }
        XCTAssertThrowsError(
            try dialer.connect(
                route: route,
                deadlineUnixMilliseconds: now() + 2_000,
                cancellation: cancelled
            )
        ) {
            XCTAssertEqual(
                $0 as? HostwrightTunnelSocketError,
                .cancelled
            )
        }

        let listener = try HostwrightServiceTunnelListener(
            route: route,
            credentials: fixture.credentials.server,
            port: port
        )
        defer { listener.stop() }
        try listener.start(
            deadlineUnixMilliseconds: now() + 3_000
        )
        guard case .client(let verifier) =
                fixture.credentials.client.peerVerifier else {
            return XCTFail("expected client verifier")
        }
        let rejected = HostwrightTunnelTLSCredentials(
            localIdentity:
                fixture.credentials.client.localIdentity,
            peerVerifier: .client(
                HostwrightTunnelClientPeerVerifier(
                    trustAnchors: verifier.trustAnchors,
                    dnsName: verifier.dnsName,
                    certificateSHA256:
                        String(repeating: "0", count: 64)
                )
            )
        )
        let rejectedDialer = HostwrightServiceTunnelDialer {
            _, _, _ in rejected
        }
        XCTAssertThrowsError(
            try rejectedDialer.connect(
                route: route,
                deadlineUnixMilliseconds: now() + 3_000
            )
        )
    }

    private func certificateFixture() throws -> Fixture {
        let identity = NetworkHelperDNSIdentity(
            projectUUID: project,
            dnsUUID:
                "22222222-2222-4222-8222-222222222222",
            generation: 1,
            fencingToken: fence
        )
        let tunnelPeer = try HostwrightMutualTLSIdentity(
            projectUUID: project,
            resourceUUID: peer,
            role: .tunnel,
            generation: 1
        )
        let binding = ProjectCertificateRequestBinding(
            name: "tunnel",
            certificateUUID:
                "66666666-6666-4666-8666-666666666666",
            source: .localCA,
            renewBeforeSeconds: 3_600,
            validitySeconds: 86_400,
            statusPolicy: .ifAvailable,
            dnsNames: ["tunnel.internal"],
            peerIdentities: [tunnelPeer]
        )
        let coordinator =
            NetworkHelperCertificateCoordinator()
        let activation = try coordinator.apply(
            identity: identity,
            bindings: [binding]
        )
        let requestDigest = SHA256.hash(
            data: try NetworkHelperCanonicalJSON.encode(
                [binding]
            )
        ).map {
            String(format: "%02x", $0)
        }.joined()
        let evidence =
            NetworkHelperPersistedCertificateEvidence(
                identity: identity,
                requestSHA256: requestDigest,
                certificates: activation.evidence
            )
        let credentials = try
            HostwrightTunnelCertificateCoordinatorAdapter(
                coordinator: coordinator
            ).loopbackCredentials(
                identity: identity,
                bindingName: "tunnel",
                peerIdentityURI: tunnelPeer.uriSAN
            )
        return Fixture(
            coordinator: coordinator,
            identity: identity,
            evidence: evidence,
            credentials: credentials
        )
    }

    private func makeRoute(
        directPort: Int,
        relayPort: Int? = nil
    ) throws -> HostwrightTunnelRoute {
        try HostwrightTunnelRoute(
            projectUUID: project,
            peerUUID: peer,
            generation: 1,
            providerID: "apple-container-cli",
            providerGeneration: 1,
            fencingToken: fence,
            operationGroupID: operationGroup,
            desiredSHA256: String(repeating: "a", count: 64),
            authenticatedEndpoints: [
                try HostwrightTunnelEndpoint(
                    host: "127.0.0.1",
                    port: directPort
                )
            ],
            relayEndpoint: try relayPort.map {
                try HostwrightTunnelEndpoint(
                    host: "127.0.0.1",
                    port: $0
                )
            }
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
        address.sin_len =
            UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard
            "127.0.0.1".withCString({
                inet_pton(
                    AF_INET,
                    $0,
                    &address.sin_addr
                )
            }) == 1
        else {
            throw HostwrightTunnelSocketError.connectionFailed
        }
        let bound = withUnsafePointer(to: &address) {
            pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(
                        MemoryLayout<sockaddr_in>.size
                    )
                )
            }
        }
        guard bound == 0 else {
            throw HostwrightTunnelSocketError.connectionFailed
        }
        var actual = sockaddr_in()
        var length = socklen_t(
            MemoryLayout<sockaddr_in>.size
        )
        guard
            withUnsafeMutablePointer(to: &actual, {
                $0.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) {
                    getsockname(
                        descriptor,
                        $0,
                        &length
                    )
                }
            }) == 0
        else {
            throw HostwrightTunnelSocketError.connectionFailed
        }
        return Int(in_port_t(bigEndian: actual.sin_port))
    }

    private func now() -> Int64 {
        HostwrightServiceTunnelConnection.nowMilliseconds()
    }
}

private struct Fixture {
    let coordinator: NetworkHelperCertificateCoordinator
    let identity: NetworkHelperDNSIdentity
    let evidence: NetworkHelperPersistedCertificateEvidence
    let credentials: HostwrightTunnelLoopbackCredentials

    func cleanup() {
        try? coordinator.cleanup(
            identity: identity,
            evidence: evidence
        )
    }
}
