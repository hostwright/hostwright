import Darwin
import Foundation
import HostwrightCore
import HostwrightNetworking
import HostwrightRuntime

enum NetworkPortSocketAvailability {
    static func isAvailable(
        _ endpoint: NetworkPortEndpoint
    ) throws -> Bool {
        try isAvailable(
            endpoint,
            allowedInterfaceAddress: nil
        )
    }

    static func isAvailable(
        _ endpoint: NetworkPortEndpoint,
        exposurePolicy: HostwrightPortExposurePolicy,
        environment: NetworkHostEnvironmentSnapshot
    ) throws -> Bool {
        let evaluation = NetworkExposureEnvironmentEvaluator.evaluate(
            policy: exposurePolicy,
            bindAddress: endpoint.bindAddress,
            environment: environment
        )
        guard evaluation.isAllowed else {
            throw HostwrightDiagnostic(
                code: .unsafeExposure,
                message:
                    "Port availability was denied because the exact host-network exposure policy is not currently satisfied."
            )
        }
        return try isAvailable(
            endpoint,
            allowedInterfaceAddress: evaluation.selectedAddress
        )
    }

    private static func isAvailable(
        _ endpoint: NetworkPortEndpoint,
        allowedInterfaceAddress: NetworkHostInterfaceAddress?
    ) throws -> Bool {
        let family: Int32
        let interfaceIndex: UInt32
        switch endpoint.bindAddress {
        case "127.0.0.1":
            family = AF_INET
            interfaceIndex = 0
        case "::1":
            family = AF_INET6
            interfaceIndex = 0
        default:
            guard let allowedInterfaceAddress,
                  !allowedInterfaceAddress.isLoopback,
                  allowedInterfaceAddress.address ==
                    endpoint.bindAddress else {
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "Port availability checks require an approved exact active local-interface address."
                )
            }
            family = allowedInterfaceAddress.family == .ipv4
                ? AF_INET
                : AF_INET6
            interfaceIndex = family == AF_INET6
                ? if_nametoindex(
                    allowedInterfaceAddress.interfaceName
                )
                : 0
            guard family != AF_INET6 || interfaceIndex != 0 else {
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "Could not resolve the approved IPv6 interface scope."
                )
            }
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
            address.sin6_scope_id = interfaceIndex
            guard inet_pton(
                AF_INET6,
                endpoint.bindAddress,
                &address.sin6_addr
            ) == 1 else {
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "Could not normalize the exact IPv6 bind address."
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
                        "Could not normalize the exact IPv4 bind address."
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
