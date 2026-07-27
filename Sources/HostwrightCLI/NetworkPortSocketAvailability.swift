import Darwin
import Foundation
import HostwrightCore
import HostwrightRuntime

enum NetworkPortSocketAvailability {
    static func isAvailable(
        _ endpoint: NetworkPortEndpoint
    ) throws -> Bool {
        let family: Int32
        switch endpoint.bindAddress {
        case "127.0.0.1":
            family = AF_INET
        case "::1":
            family = AF_INET6
        default:
            throw HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message:
                    "Port availability checks require an explicit localhost bind address."
            )
        }

        let socketType: Int32 = endpoint.protocolName == .tcp
            ? SOCK_STREAM
            : SOCK_DGRAM
        let descriptor = Darwin.socket(family, socketType, 0)
        guard descriptor >= 0 else {
            throw HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message:
                    "Could not create a local socket while checking port availability."
            )
        }
        defer { Darwin.close(descriptor) }

        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message:
                    "Could not secure the local port-availability socket."
            )
        }

        let result: Int32
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len =
                UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port =
                in_port_t(endpoint.hostPort).bigEndian
            guard inet_pton(
                AF_INET6,
                endpoint.bindAddress,
                &address.sin6_addr
            ) == 1 else {
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "Could not normalize the IPv6 localhost bind address."
                )
            }
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(
                            MemoryLayout<sockaddr_in6>.size
                        )
                    )
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len =
                UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port =
                in_port_t(endpoint.hostPort).bigEndian
            guard inet_pton(
                AF_INET,
                endpoint.bindAddress,
                &address.sin_addr
            ) == 1 else {
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "Could not normalize the IPv4 localhost bind address."
                )
            }
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(
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
        }

        if result == 0 {
            return true
        }
        if errno == EADDRINUSE || errno == EACCES {
            return false
        }
        throw HostwrightDiagnostic(
            code: .runtimeUnavailable,
            message:
                "The operating system could not verify local port availability."
        )
    }
}
