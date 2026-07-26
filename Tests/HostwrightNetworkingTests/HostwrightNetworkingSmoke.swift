import XCTest
@testable import HostwrightNetworking

final class HostwrightNetworkingTests: XCTestCase {
    func testNetworkAddressRequestsRoundTripManifestValues() {
        XCTAssertEqual(HostwrightNetworkAddressRequest(manifestValue: "auto"), .auto)
        XCTAssertEqual(HostwrightNetworkAddressRequest(manifestValue: " DISABLED "), .disabled)
        XCTAssertEqual(
            HostwrightNetworkAddressRequest(manifestValue: "10.44.0.0/24"),
            .cidr("10.44.0.0/24")
        )
        XCTAssertNil(HostwrightNetworkAddressRequest(manifestValue: "   "))

        XCTAssertEqual(HostwrightNetworkAddressRequest.auto.manifestValue, "auto")
        XCTAssertEqual(HostwrightNetworkAddressRequest.disabled.manifestValue, "disabled")
        XCTAssertEqual(
            HostwrightNetworkAddressRequest.cidr("fd00:44::/64").manifestValue,
            "fd00:44::/64"
        )
    }

    func testNetworkAddressRequestCodableUsesStableStringContract() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for request in [
            HostwrightNetworkAddressRequest.auto,
            .disabled,
            .cidr("10.44.0.0/24")
        ] {
            let encoded = try encoder.encode(request)
            XCTAssertEqual(
                try decoder.decode(
                    HostwrightNetworkAddressRequest.self,
                    from: encoded
                ),
                request
            )
            XCTAssertEqual(
                encoded,
                try encoder.encode(request.manifestValue)
            )
        }
    }

    func testNetworkDefinitionDefaultsAreStable() {
        let definition = HostwrightNetworkDefinition(name: "backend")

        XCTAssertEqual(definition.driver, .nat)
        XCTAssertEqual(definition.ipv4, .auto)
        XCTAssertEqual(definition.ipv6, .auto)
    }

    func testManifestNetworkNamesUseBoundedLowercaseDNSLabels() {
        for name in ["a", "default", "app-net", "network-7"] {
            XCTAssertTrue(HostwrightNetworkIdentity.isValidManifestName(name), name)
        }

        for name in ["", "-network", "network-", "App", "app_net", "app.net", String(repeating: "a", count: 64)] {
            XCTAssertFalse(HostwrightNetworkIdentity.isValidManifestName(name), name)
        }
    }

    func testRuntimeNetworkIdentityIsUUIDBackedAndDeterministic() {
        let first = HostwrightNetworkIdentity.resourceUUID(
            projectUUID: "11111111-1111-1111-1111-111111111111",
            networkName: "backend"
        )
        let repeated = HostwrightNetworkIdentity.resourceUUID(
            projectUUID: "11111111-1111-1111-1111-111111111111",
            networkName: "backend"
        )
        let otherProject = HostwrightNetworkIdentity.resourceUUID(
            projectUUID: "22222222-2222-2222-2222-222222222222",
            networkName: "backend"
        )

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, otherProject)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(
            HostwrightNetworkIdentity.runtimeName(
                projectUUID: "11111111-1111-1111-1111-111111111111",
                networkName: "backend"
            ),
            "hw-\(first.replacingOccurrences(of: "-", with: ""))"
        )
    }

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
