import Foundation
import HostwrightNetworking
import Security
import XCTest

@testable import HostwrightNetworkHelperCore

/// Attended evidence lane for an already-running Tahoe VM tunnel peer.
///
/// The guest must already be configured with the exact route/fence and must
/// echo one channel-0 frame. This harness never creates a VM, weakens trust,
/// discovers credentials, or falls back to a public relay.
final class ServiceTunnelTahoeVMHarnessTests: XCTestCase {
    func testExistingTahoeVMEchoesAuthenticatedFrame()
        throws
    {
        let environment = ProcessInfo.processInfo.environment
        guard environment[
            "HOSTWRIGHT_GATE13_TAHOE_VM"
        ] == "1" else {
            throw XCTSkip(
                "Set HOSTWRIGHT_GATE13_TAHOE_VM=1 only for the attended existing-VM evidence lane."
            )
        }
        let routePath = try required(
            "HOSTWRIGHT_GATE13_TAHOE_ROUTE_JSON",
            environment
        )
        let identityFingerprint = try required(
            "HOSTWRIGHT_GATE13_TAHOE_CLIENT_CERT_SHA256",
            environment
        )
        let trustAnchorPath = try required(
            "HOSTWRIGHT_GATE13_TAHOE_SERVER_CA_DER",
            environment
        )
        let serverName = try required(
            "HOSTWRIGHT_GATE13_TAHOE_SERVER_DNS_NAME",
            environment
        )
        let serverFingerprint = try required(
            "HOSTWRIGHT_GATE13_TAHOE_SERVER_CERT_SHA256",
            environment
        )
        let route = try JSONDecoder().decode(
            HostwrightTunnelRoute.self,
            from: Data(
                contentsOf: URL(fileURLWithPath: routePath),
                options: [.mappedIfSafe]
            )
        )
        let anchorData = try Data(
            contentsOf: URL(
                fileURLWithPath: trustAnchorPath
            ),
            options: [.mappedIfSafe]
        )
        guard
            anchorData.count <= 64 * 1_024,
            let anchor = SecCertificateCreateWithData(
                nil,
                anchorData as CFData
            )
        else {
            throw HostwrightTunnelSocketError.invalidCredentials
        }
        let identity = try CertificateIdentityStore()
            .resolveImportedIdentity(
                certificateSHA256: identityFingerprint
            )
        let credentials = HostwrightTunnelTLSCredentials(
            localIdentity: identity,
            peerVerifier: .client(
                HostwrightTunnelClientPeerVerifier(
                    trustAnchors: [anchor],
                    dnsName: serverName,
                    certificateSHA256: serverFingerprint
                )
            )
        )
        let dialer = HostwrightServiceTunnelDialer {
            _, _, transport in
            guard transport == .direct else {
                throw HostwrightTunnelSocketError
                    .connectionFailed
            }
            return credentials
        }
        let deadline =
            HostwrightServiceTunnelConnection.nowMilliseconds()
            + 10_000
        let connection = try dialer.connect(
            route: route,
            deadlineUnixMilliseconds: deadline
        )
        defer { connection.cancel() }
        let request = Data(
            environment[
                "HOSTWRIGHT_GATE13_TAHOE_ECHO_PAYLOAD"
            ]?.utf8 ?? "hostwright-gate13".utf8
        )
        _ = try connection.send(
            channel: 0,
            payload: request,
            deadlineUnixMilliseconds: deadline
        )
        let response = try XCTUnwrap(
            connection.receive(
                deadlineUnixMilliseconds: deadline
            )
        )
        XCTAssertEqual(response.channel, 0)
        XCTAssertEqual(response.payload, request)
        try connection.drain(
            deadlineUnixMilliseconds: deadline
        )
    }

    private func required(
        _ key: String,
        _ environment: [String: String]
    ) throws -> String {
        guard let value = environment[key],
              !value.isEmpty else {
            throw XCTSkip(
                "Missing attended Gate 13 evidence input: \(key)"
            )
        }
        return value
    }
}
