import Darwin
import XCTest
@testable import HostwrightCLI
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
