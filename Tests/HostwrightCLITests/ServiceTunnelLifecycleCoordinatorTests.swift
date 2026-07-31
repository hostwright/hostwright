import Foundation
import HostwrightCore
import HostwrightNetworking
import HostwrightRuntime
import XCTest

@testable import HostwrightCLI

final class ServiceTunnelLifecycleCoordinatorTests:
    XCTestCase
{
    func testDeclarationAndTunnelPortMaterializeExactRoute()
        throws
    {
        let preparation = try makePreparation()
        let declaration = HostwrightTunnelDeclaration(
            targetService: "web",
            targetPort: 8080,
            peerUUID:
                "33333333-3333-4333-8333-333333333333",
            authenticatedEndpoints: [
                HostwrightTunnelManifestEndpoint(
                    host: "127.0.0.1",
                    port: 9443
                ),
            ],
            bonjourDiscovery: true
        )
        let routes = try ServiceTunnelLifecycleCoordinator
            .routes(
                declarations: ["web-tunnel": declaration],
                preparation: preparation,
                operationGroupID:
                    "55555555-5555-4555-8555-555555555555",
                discovery: { _, _ in
                    [
                        try HostwrightBonjourTunnelCandidate(
                            serviceName: "_hostwright._tcp",
                            endpoint:
                                HostwrightTunnelEndpoint(
                                    host: "localhost",
                                    port: 9555
                                ),
                            peerUUID:
                                "33333333-3333-4333-8333-333333333333"
                        ),
                        try HostwrightBonjourTunnelCandidate(
                            serviceName: "_hostwright._tcp",
                            endpoint:
                                HostwrightTunnelEndpoint(
                                    host: "ignored.test",
                                    port: 9556
                                ),
                            peerUUID:
                                "66666666-6666-4666-8666-666666666666"
                        ),
                    ]
                }
            )
        let route = try XCTUnwrap(routes.first)
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(
            route.projectUUID,
            preparation.projectResourceUUID
        )
        XCTAssertEqual(
            route.peerUUID,
            declaration.peerUUID
        )
        XCTAssertEqual(route.generation, 2)
        XCTAssertEqual(
            route.providerID,
            RuntimeProviderID.appleContainerCLI.rawValue
        )
        XCTAssertEqual(
            route.providerGeneration,
            Int64(preparation.providerGeneration)
        )
        XCTAssertEqual(
            route.fencingToken,
            preparation.planFencingToken
        )
        XCTAssertEqual(
            route.authenticatedEndpoints,
            [
                try HostwrightTunnelEndpoint(
                    host: "127.0.0.1",
                    port: 9443
                ),
                try HostwrightTunnelEndpoint(
                    host: "localhost",
                    port: 9555
                ),
            ]
        )
    }

    func testBonjourOnlyDeclarationFailsClosedWithoutCandidate()
        throws
    {
        let declaration = HostwrightTunnelDeclaration(
            targetService: "web",
            targetPort: 8080,
            peerUUID:
                "33333333-3333-4333-8333-333333333333",
            bonjourDiscovery: true
        )
        XCTAssertThrowsError(
            try ServiceTunnelLifecycleCoordinator.routes(
                declarations: ["web-tunnel": declaration],
                preparation: makePreparation(),
                operationGroupID:
                    "55555555-5555-4555-8555-555555555555"
            )
        )
    }

    func testListenerMaterializesExactForwardingEndpoint()
        throws
    {
        let declaration = HostwrightTunnelDeclaration(
            targetService: "web",
            targetPort: 8080,
            peerUUID:
                "33333333-3333-4333-8333-333333333333",
            role: .listener,
            trust: makeListenerTrust(),
            bindEndpoint: HostwrightTunnelBindEndpoint(
                host: "192.0.2.10",
                port: 9443
            ),
            authenticatedEndpoints: [],
            bonjourDiscovery: false
        )
        let route = try XCTUnwrap(
            ServiceTunnelLifecycleCoordinator.routes(
                declarations: ["remote": declaration],
                preparation: makePreparation(),
                operationGroupID:
                    "55555555-5555-4555-8555-555555555555"
            ).first
        )
        XCTAssertEqual(route.role, .listener)
        XCTAssertEqual(route.trust, declaration.trust)
        XCTAssertEqual(
            route.bindEndpoint,
            declaration.bindEndpoint
        )
        XCTAssertEqual(
            route.forwardEndpoint,
            try HostwrightTunnelEndpoint(
                host: "127.0.0.1",
                port: 8080
            )
        )
        XCTAssertTrue(route.authenticatedEndpoints.isEmpty)
    }

    func testDialerMaterializesWithoutLocalTargetBinding()
        throws
    {
        let declaration = HostwrightTunnelDeclaration(
            targetService: "remote-web",
            targetPort: 8080,
            peerUUID:
                "33333333-3333-4333-8333-333333333333",
            role: .dialer,
            trust: makeDialerTrust(),
            bindEndpoint: HostwrightTunnelBindEndpoint(
                host: "127.0.0.1",
                port: 18_080
            ),
            authenticatedEndpoints: [
                HostwrightTunnelManifestEndpoint(
                    host: "peer.example.test",
                    port: 9443
                ),
            ],
            bonjourDiscovery: false
        )
        let route = try XCTUnwrap(
            ServiceTunnelLifecycleCoordinator.routes(
                declarations: ["remote": declaration],
                preparation: makePreparation(),
                operationGroupID:
                    "55555555-5555-4555-8555-555555555555"
            ).first
        )
        XCTAssertEqual(route.role, .dialer)
        XCTAssertEqual(route.generation, 1)
        XCTAssertNil(route.forwardEndpoint)
        XCTAssertEqual(
            route.authenticatedEndpoints,
            [
                try HostwrightTunnelEndpoint(
                    host: "peer.example.test",
                    port: 9443
                ),
            ]
        )
    }

    func testReciprocalPeersDeriveSameWireAuthorityFromDifferentLocalFences()
        throws
    {
        let listener = try HostwrightTunnelRoute(
            routeUUID:
                "11111111-1111-4111-8111-111111111111",
            projectUUID:
                "22222222-2222-4222-8222-222222222222",
            peerUUID:
                "33333333-3333-4333-8333-333333333333",
            generation: 2,
            providerID: "apple-container-cli",
            providerGeneration: 1,
            fencingToken:
                "44444444-4444-4444-8444-444444444444",
            operationGroupID:
                "55555555-5555-4555-8555-555555555555",
            desiredSHA256: String(repeating: "1", count: 64),
            role: .listener,
            trust: makeListenerTrust(),
            bindEndpoint: HostwrightTunnelBindEndpoint(
                host: "192.0.2.10",
                port: 9443
            ),
            forwardEndpoint: try HostwrightTunnelEndpoint(
                host: "127.0.0.1",
                port: 8080
            ),
            authenticatedEndpoints: []
        )
        let dialer = try HostwrightTunnelRoute(
            routeUUID:
                "66666666-6666-4666-8666-666666666666",
            projectUUID:
                "33333333-3333-4333-8333-333333333333",
            peerUUID:
                "22222222-2222-4222-8222-222222222222",
            generation: 7,
            providerID: "apple-container-cli",
            providerGeneration: 3,
            fencingToken:
                "77777777-7777-4777-8777-777777777777",
            operationGroupID:
                "99999999-9999-4999-8999-999999999999",
            desiredSHA256: String(repeating: "2", count: 64),
            role: .dialer,
            trust: makeDialerTrust(),
            bindEndpoint: HostwrightTunnelBindEndpoint(
                host: "127.0.0.1",
                port: 18_080
            ),
            authenticatedEndpoints: [
                try HostwrightTunnelEndpoint(
                    host: "peer.example.test",
                    port: 9443
                ),
            ]
        )
        let listenerExecution = try XCTUnwrap(
            ServiceTunnelLifecycleCoordinator
                .helperExecution(listener)
        )
        let dialerExecution = try XCTUnwrap(
            ServiceTunnelLifecycleCoordinator
                .helperExecution(dialer)
        )
        XCTAssertEqual(
            listenerExecution.wireRouteUUID,
            dialerExecution.wireRouteUUID
        )
        XCTAssertEqual(
            listenerExecution.wireGeneration,
            dialerExecution.wireGeneration
        )
        XCTAssertEqual(
            listenerExecution.wireFencingToken,
            dialerExecution.wireFencingToken
        )
        XCTAssertNotEqual(
            listener.fencingToken,
            dialer.fencingToken
        )
    }

    private func makePreparation()
        throws -> LifecycleCommandPreparation
    {
        let project =
            "11111111-1111-4111-8111-111111111111"
        let identity = RuntimeServiceIdentity(
            projectName: "demo",
            serviceName: "web"
        )
        let service = DesiredRuntimeService(
            identity: identity,
            image: "local/web:latest",
            ports: [
                RuntimePortMapping(
                    hostPort: 8080,
                    containerPort: 8080,
                    protocolName: .tcp,
                    bindAddress: "127.0.0.1",
                    allocation: .fixed,
                    exposurePolicy:
                        HostwrightPortExposurePolicy(
                            scope: .tunnel,
                            authentication:
                                .authenticatedTunnel
                        )
                ),
            ],
            networks: []
        )
        let binding = try LifecycleResourceBinding(
            identity: identity,
            resourceIdentifier: "hostwright-demo-web",
            resourceUUID:
                "22222222-2222-4222-8222-222222222222",
            resourceGeneration: 2,
            projectResourceUUID: project,
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 3,
            currentFencingToken:
                "77777777-7777-4777-8777-777777777777"
        )
        return LifecycleCommandPreparation(
            manifestSHA256: String(repeating: "a", count: 64),
            manifestBaseDirectory: "/tmp",
            desiredState: DesiredRuntimeState(
                projectName: "demo",
                networks: [],
                services: [service]
            ),
            tunnelDeclarations: [:],
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: []
            ),
            observationSHA256:
                String(repeating: "b", count: 64),
            projectID: "project-demo",
            projectResourceUUID: project,
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 3,
            capabilitySHA256:
                String(repeating: "c", count: 64),
            planFencingToken:
                "44444444-4444-4444-8444-444444444444",
            resourceBindings: [binding]
        )
    }

    private func makeListenerTrust() -> HostwrightTunnelTrust {
        HostwrightTunnelTrust(
            wireRouteUUID:
                "88888888-8888-4888-8888-888888888888",
            wireGeneration: 1,
            localIdentitySHA256: String(repeating: "a", count: 64),
            peerTrustAnchorSHA256:
                String(repeating: "b", count: 64),
            peerCertificateSHA256:
                String(repeating: "c", count: 64),
            peerIdentityURI:
                "spiffe://hostwright.internal/projects/33333333-3333-4333-8333-333333333333/resources/22222222-2222-4222-8222-222222222222/roles/tunnel/generations/1"
        )
    }

    private func makeDialerTrust() -> HostwrightTunnelTrust {
        HostwrightTunnelTrust(
            wireRouteUUID:
                "88888888-8888-4888-8888-888888888888",
            wireGeneration: 1,
            localIdentitySHA256: String(repeating: "c", count: 64),
            peerTrustAnchorSHA256:
                String(repeating: "d", count: 64),
            peerCertificateSHA256:
                String(repeating: "a", count: 64),
            peerDNSName: "peer.example.test"
        )
    }
}
