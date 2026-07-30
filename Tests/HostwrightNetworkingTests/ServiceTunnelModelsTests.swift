import Foundation
import XCTest
@testable import HostwrightNetworking

final class ServiceTunnelModelsTests: XCTestCase {
    func testDecodesLegacyDeclarationAsLocalLoopback()
        throws
    {
        let json = """
        {
          "targetService": "web",
          "targetPort": 8080,
          "peerUUID": "22222222-2222-4222-8222-222222222222",
          "authenticatedEndpoints": [
            {"scheme": "tls", "host": "127.0.0.1", "port": 7443}
          ],
          "bonjourDiscovery": false
        }
        """
        let declaration = try JSONDecoder().decode(
            HostwrightTunnelDeclaration.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(declaration.role, .localLoopback)
        XCTAssertNil(declaration.trust)
        XCTAssertNil(declaration.bindEndpoint)
    }

    func testDecodesLegacyRouteAsLocalLoopback() throws {
        let route = try localRoute()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(route)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "role")
        object.removeValue(forKey: "trust")
        object.removeValue(forKey: "bindEndpoint")
        object.removeValue(forKey: "forwardEndpoint")

        let decoded = try JSONDecoder().decode(
            HostwrightTunnelRoute.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.role, .localLoopback)
        XCTAssertNil(decoded.trust)
        XCTAssertNil(decoded.bindEndpoint)
        XCTAssertNil(decoded.forwardEndpoint)
        XCTAssertEqual(decoded, route)
    }

    func testListenerRouteBindsExactTrustAndForwardEndpoint() throws {
        let route = try HostwrightTunnelRoute(
            projectUUID: "11111111-1111-4111-8111-111111111111",
            peerUUID: "22222222-2222-4222-8222-222222222222",
            generation: 1,
            providerID: "apple-container-cli",
            providerGeneration: 1,
            fencingToken: "33333333-3333-4333-8333-333333333333",
            operationGroupID: "44444444-4444-4444-8444-444444444444",
            desiredSHA256: digest("d"),
            role: .listener,
            trust: listenerTrust(),
            bindEndpoint: HostwrightTunnelBindEndpoint(
                host: "10.0.0.8",
                port: 7443
            ),
            forwardEndpoint: try HostwrightTunnelEndpoint(
                host: "127.0.0.1",
                port: 8080
            ),
            authenticatedEndpoints: []
        )

        XCTAssertEqual(route.role, .listener)
        XCTAssertEqual(route.forwardEndpoint?.port, 8080)
        XCTAssertEqual(
            try JSONDecoder().decode(
                HostwrightTunnelRoute.self,
                from: JSONEncoder().encode(route)
            ),
            route
        )
    }

    func testDialerRouteRequiresLoopbackBindAndNoForwardEndpoint() throws {
        let common = (
            project: "11111111-1111-4111-8111-111111111111",
            peer: "22222222-2222-4222-8222-222222222222",
            fence: "33333333-3333-4333-8333-333333333333",
            group: "44444444-4444-4444-8444-444444444444"
        )
        XCTAssertThrowsError(
            try HostwrightTunnelRoute(
                projectUUID: common.project,
                peerUUID: common.peer,
                generation: 1,
                providerID: "apple-container-cli",
                providerGeneration: 1,
                fencingToken: common.fence,
                operationGroupID: common.group,
                desiredSHA256: digest("d"),
                role: .dialer,
                trust: dialerTrust(),
                bindEndpoint: HostwrightTunnelBindEndpoint(
                    host: "10.0.0.9",
                    port: 9443
                ),
                authenticatedEndpoints: [
                    try HostwrightTunnelEndpoint(
                        host: "peer.example.test",
                        port: 7443
                    )
                ]
            )
        )
        XCTAssertThrowsError(
            try HostwrightTunnelRoute(
                projectUUID: common.project,
                peerUUID: common.peer,
                generation: 1,
                providerID: "apple-container-cli",
                providerGeneration: 1,
                fencingToken: common.fence,
                operationGroupID: common.group,
                desiredSHA256: digest("d"),
                role: .dialer,
                trust: dialerTrust(),
                bindEndpoint: HostwrightTunnelBindEndpoint(
                    host: "127.0.0.1",
                    port: 9443
                ),
                forwardEndpoint: try HostwrightTunnelEndpoint(
                    host: "127.0.0.1",
                    port: 8080
                ),
                authenticatedEndpoints: [
                    try HostwrightTunnelEndpoint(
                        host: "peer.example.test",
                        port: 7443
                    )
                ]
            )
        )
    }

    private func localRoute() throws -> HostwrightTunnelRoute {
        try HostwrightTunnelRoute(
            projectUUID: "11111111-1111-4111-8111-111111111111",
            peerUUID: "22222222-2222-4222-8222-222222222222",
            generation: 1,
            providerID: "apple-container-cli",
            providerGeneration: 1,
            fencingToken: "33333333-3333-4333-8333-333333333333",
            operationGroupID: "44444444-4444-4444-8444-444444444444",
            desiredSHA256: digest("d"),
            authenticatedEndpoints: [
                try HostwrightTunnelEndpoint(
                    host: "127.0.0.1",
                    port: 7443
                )
            ]
        )
    }

    private func listenerTrust() -> HostwrightTunnelTrust {
        HostwrightTunnelTrust(
            wireRouteUUID: "55555555-5555-4555-8555-555555555555",
            wireGeneration: 1,
            localIdentitySHA256: digest("a"),
            peerTrustAnchorSHA256: digest("b"),
            peerCertificateSHA256: digest("c"),
            peerIdentityURI:
                "spiffe://hostwright.internal/projects/11111111-1111-4111-8111-111111111111/resources/22222222-2222-4222-8222-222222222222/roles/tunnel/generations/1"
        )
    }

    private func dialerTrust() -> HostwrightTunnelTrust {
        HostwrightTunnelTrust(
            wireRouteUUID: "55555555-5555-4555-8555-555555555555",
            wireGeneration: 1,
            localIdentitySHA256: digest("a"),
            peerTrustAnchorSHA256: digest("b"),
            peerCertificateSHA256: digest("c"),
            peerDNSName: "peer.example.test"
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: character, count: 64)
    }
}
