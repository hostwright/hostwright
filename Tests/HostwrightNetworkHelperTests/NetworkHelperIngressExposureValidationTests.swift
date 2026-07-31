import XCTest
@testable import HostwrightNetworkHelperCore
import HostwrightNetworking

final class NetworkHelperIngressExposureValidationTests: XCTestCase {
    func testLANListenerRequiresExactTLSExposure() throws {
        let exposure = HostwrightPortExposurePolicy(
            scope: .lan,
            interfaces: ["en0"],
            networkClasses: [.privateLAN],
            allowedCIDRs: ["192.168.1.0/24"],
            authentication: .tls
        )
        let binding = ProjectIngressListenerBinding(
            name: "api",
            bindAddress: "192.168.1.10",
            port: 8_443,
            exposure: exposure,
            certificate: "api-tls",
            routes: [route()]
        )

        XCTAssertEqual(
            try NetworkHelperIngressValidation.validated([binding]),
            [binding]
        )

        let withoutCertificate = ProjectIngressListenerBinding(
            name: binding.name,
            bindAddress: binding.bindAddress,
            port: binding.port,
            exposure: binding.exposure,
            routes: binding.routes
        )
        XCTAssertThrowsError(
            try NetworkHelperIngressValidation.validated(
                [withoutCertificate]
            )
        ) {
            XCTAssertEqual(
                $0 as? NetworkHelperError,
                .invalidCertificate
            )
        }
    }

    func testPublicListenerRequiresMutualTLS() {
        let binding = ProjectIngressListenerBinding(
            name: "api",
            bindAddress: "203.0.113.10",
            port: 8_443,
            exposure: HostwrightPortExposurePolicy(
                scope: .public,
                interfaces: ["en0"],
                networkClasses: [.publicInternet],
                allowedCIDRs: ["203.0.113.0/24"],
                authentication: .authenticatedTunnel
            ),
            certificate: "api-tls",
            routes: [route()]
        )

        XCTAssertThrowsError(
            try NetworkHelperIngressValidation.validated([binding])
        ) {
            XCTAssertEqual(
                $0 as? NetworkHelperError,
                .invalidRequest
            )
        }
    }

    private func route() -> ProjectIngressRouteBinding {
        ProjectIngressRouteBinding(
            hostname: "api.example.test",
            pathPrefix: "/",
            methods: ["GET"],
            protocolName: .http,
            targetServiceName: "api",
            targetServiceUUIDs: [
                "11111111-1111-4111-8111-111111111111",
            ],
            targetPort: 8_080,
            backends: []
        )
    }
}
