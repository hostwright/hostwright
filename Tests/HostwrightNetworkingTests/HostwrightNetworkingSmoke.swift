import XCTest
@testable import HostwrightNetworking

final class HostwrightNetworkingTests: XCTestCase {
    func testNonLocalExposureScopesAreRejectedForFirstRelease() {
        for scope in [NetworkExposureScope.lan, .tunnel, .public] {
            let binding = PortBinding(target: 443, published: 443, protocolName: .tcp, scope: scope)
            let diagnostics = binding.validate()

            XCTAssertEqual(diagnostics.count, 1, scope.rawValue)
            XCTAssertFalse(scope.isAllowedInFirstRelease, scope.rawValue)
        }
    }

    func testLocalhostExposureWithValidPortsPasses() {
        let localhostBinding = PortBinding(target: 80, published: 8080, protocolName: .tcp, scope: .localhost)

        XCTAssertTrue(localhostBinding.validate().isEmpty)
        XCTAssertTrue(NetworkExposureScope.localhost.isAllowedInFirstRelease)
    }

    func testBindAddressPolicyNormalizesLocalhostAndBroadExposure() {
        XCTAssertEqual(NetworkBindAddressPolicy.normalizedBindAddress(nil), "127.0.0.1")
        XCTAssertTrue(NetworkBindAddressPolicy.isLocalhost("localhost"))
        XCTAssertTrue(NetworkBindAddressPolicy.isLocalhost("127.0.0.1"))
        XCTAssertTrue(NetworkBindAddressPolicy.isBroadBindAddress("0.0.0.0"))
        XCTAssertTrue(NetworkBindAddressPolicy.isBroadBindAddress("::"))
        XCTAssertEqual(
            NetworkBindAddressPolicy.hostPortKey(bindAddress: nil, hostPort: 8080, protocolName: "TCP"),
            "127.0.0.1:8080/tcp"
        )
    }

    func testHostPortConflictTreatsBroadBindAsConflictingWithLocalhost() {
        XCTAssertTrue(
            NetworkBindAddressPolicy.hostPortsConflict(
                lhsBindAddress: "127.0.0.1",
                lhsHostPort: 8080,
                lhsProtocolName: "tcp",
                rhsBindAddress: "0.0.0.0",
                rhsHostPort: 8080,
                rhsProtocolName: "tcp"
            )
        )

        XCTAssertFalse(
            NetworkBindAddressPolicy.hostPortsConflict(
                lhsBindAddress: "127.0.0.1",
                lhsHostPort: 8080,
                lhsProtocolName: "tcp",
                rhsBindAddress: "127.0.0.1",
                rhsHostPort: 8081,
                rhsProtocolName: "tcp"
            )
        )
    }
}
