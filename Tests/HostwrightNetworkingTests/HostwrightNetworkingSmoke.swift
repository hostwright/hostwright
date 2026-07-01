import XCTest
@testable import HostwrightNetworking

final class HostwrightNetworkingTests: XCTestCase {
    func testTunnelExposureIsRejectedForFirstRelease() {
        let tunnelBinding = PortBinding(target: 443, published: 443, protocolName: .tcp, scope: .tunnel)
        let diagnostics = tunnelBinding.validate()

        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertFalse(NetworkExposureScope.tunnel.isAllowedInFirstRelease)
    }

    func testLocalhostExposureWithValidPortsPasses() {
        let localhostBinding = PortBinding(target: 80, published: 8080, protocolName: .tcp, scope: .localhost)

        XCTAssertTrue(localhostBinding.validate().isEmpty)
        XCTAssertTrue(NetworkExposureScope.localhost.isAllowedInFirstRelease)
    }
}
