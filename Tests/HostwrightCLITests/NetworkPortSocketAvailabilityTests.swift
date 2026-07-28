import Darwin
import XCTest
@testable import HostwrightCLI
@testable import HostwrightNetworking
@testable import HostwrightRuntime

final class NetworkPortSocketAvailabilityTests: XCTestCase {
    func testHeldTCPAndUDPPortsAreUnavailable() throws {
        for protocolName in [
            RuntimePortProtocol.tcp,
            RuntimePortProtocol.udp,
        ] {
            let held = try HeldLoopbackSocket(
                protocolName: protocolName
            )
            defer { held.close() }

            XCTAssertFalse(
                try NetworkPortSocketAvailability.isAvailable(
                    NetworkPortEndpoint(
                        bindAddress: "127.0.0.1",
                        hostPort: held.port,
                        protocolName: protocolName
                    )
                )
            )
        }
    }

    func testLocalhostAvailabilityRemainsAvailableThroughDefaultAPI() throws {
        XCTAssertTrue(
            try NetworkPortSocketAvailability.isAvailable(
                NetworkPortEndpoint(
                    bindAddress: "127.0.0.1",
                    hostPort: 0,
                    protocolName: .tcp
                )
            )
        )
    }

    func testNonlocalAvailabilityIsDeniedWithoutApprovedEnvironment() {
        XCTAssertThrowsError(
            try NetworkPortSocketAvailability.isAvailable(
                NetworkPortEndpoint(
                    bindAddress: "192.168.1.10",
                    hostPort: 0,
                    protocolName: .tcp
                ),
                exposurePolicy: HostwrightPortExposurePolicy(
                    scope: .lan,
                    interfaces: ["en0"],
                    networkClasses: [.privateLAN],
                    allowedCIDRs: ["192.168.1.0/24"],
                    authentication: .tls
                ),
                environment: environment(
                    addresses: [],
                    permission: .denied
                )
            )
        )
    }

    func testApprovedExactActiveInterfaceCanBeAvailabilityChecked() throws {
        guard let address = try NetworkHostInterfaceInventory
            .currentAddresses()
            .first(where: { !$0.isLoopback && $0.family == .ipv4 })
        else {
            throw XCTSkip("The test host has no active non-loopback IPv4 interface.")
        }

        XCTAssertTrue(
            try NetworkPortSocketAvailability.isAvailable(
                NetworkPortEndpoint(
                    bindAddress: address.address,
                    hostPort: 0,
                    protocolName: .tcp
                ),
                exposurePolicy: approvedPolicy(for: address),
                environment: environment(addresses: [address])
            )
        )
    }

    func testNonlocalAvailabilityIsDeniedForPermissionInterfaceAndClassMismatch()
        throws
    {
        guard let address = try NetworkHostInterfaceInventory
            .currentAddresses()
            .first(where: { !$0.isLoopback && $0.family == .ipv4 })
        else {
            throw XCTSkip("The test host has no active non-loopback IPv4 interface.")
        }
        let endpoint = NetworkPortEndpoint(
            bindAddress: address.address,
            hostPort: 0,
            protocolName: .tcp
        )

        XCTAssertThrowsError(
            try NetworkPortSocketAvailability.isAvailable(
                endpoint,
                exposurePolicy: approvedPolicy(for: address),
                environment: environment(
                    addresses: [address],
                    permission: .denied
                )
            )
        )
        XCTAssertThrowsError(
            try NetworkPortSocketAvailability.isAvailable(
                endpoint,
                exposurePolicy: HostwrightPortExposurePolicy(
                    scope: .lan,
                    interfaces: ["not-\(address.interfaceName)"],
                    networkClasses: [address.networkClass],
                    allowedCIDRs: [address.cidr],
                    authentication: .tls
                ),
                environment: environment(addresses: [address])
            )
        )
        XCTAssertThrowsError(
            try NetworkPortSocketAvailability.isAvailable(
                endpoint,
                exposurePolicy: HostwrightPortExposurePolicy(
                    scope: .lan,
                    interfaces: [address.interfaceName],
                    networkClasses: HostwrightNetworkClass.allCases.filter {
                        $0 != address.networkClass
                    },
                    allowedCIDRs: [address.cidr],
                    authentication: .tls
                ),
                environment: environment(addresses: [address])
            )
        )
    }

    private func environment(
        addresses: [NetworkHostInterfaceAddress],
        permission: NetworkLocalPermissionState = .granted
    ) -> NetworkHostEnvironmentSnapshot {
        NetworkHostEnvironmentSnapshot(
            addresses: addresses,
            primaryInterface: addresses.first?.interfaceName,
            defaultRouter: nil,
            vpnState: .inactive,
            privateRelayState: .inactive,
            localNetworkPermission: permission
        )
    }

    private func approvedPolicy(
        for address: NetworkHostInterfaceAddress
    ) -> HostwrightPortExposurePolicy {
        HostwrightPortExposurePolicy(
            scope: .lan,
            interfaces: [address.interfaceName],
            networkClasses: [address.networkClass],
            allowedCIDRs: [address.cidr],
            authentication: .tls
        )
    }
}

private final class HeldLoopbackSocket {
    let port: Int
    private var descriptor: Int32

    init(protocolName: RuntimePortProtocol) throws {
        let socketDescriptor = Darwin.socket(
            AF_INET,
            protocolName == .tcp ? SOCK_STREAM : SOCK_DGRAM,
            0
        )
        guard socketDescriptor >= 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }

        var address = sockaddr_in()
        address.sin_len =
            UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(
            s_addr: inet_addr("127.0.0.1")
        )
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    socketDescriptor,
                    $0,
                    socklen_t(
                        MemoryLayout<sockaddr_in>.size
                    )
                )
            }
        }
        guard bindResult == 0 else {
            let code =
                POSIXErrorCode(rawValue: errno) ?? .EIO
            Darwin.close(socketDescriptor)
            throw POSIXError(code)
        }

        var resolved = sockaddr_in()
        var length =
            socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(
            to: &resolved
        ) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.getsockname(
                    socketDescriptor,
                    $0,
                    &length
                )
            }
        }
        guard nameResult == 0 else {
            let code =
                POSIXErrorCode(rawValue: errno) ?? .EIO
            Darwin.close(socketDescriptor)
            throw POSIXError(code)
        }
        descriptor = socketDescriptor
        port = Int(in_port_t(bigEndian: resolved.sin_port))
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        close()
    }
}
