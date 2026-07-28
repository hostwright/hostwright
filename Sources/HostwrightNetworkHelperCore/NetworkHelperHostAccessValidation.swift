import Darwin
import Foundation
import HostwrightNetworking

enum NetworkHelperHostAccessValidation {
    static let maximumBindings = 4_096

    static func validated(
        _ bindings: [ProjectDNSHostAccessBinding]
    ) throws -> [ProjectDNSHostAccessBinding] {
        guard bindings.count <= maximumBindings else {
            throw NetworkHelperError.invalidRequest
        }

        var identities = Set<String>()
        var hostnames: [String: ProjectDNSHostAccessBinding] = [:]
        var listeners = Set<String>()
        for binding in bindings {
            guard HostwrightHostAccessPolicy.isValidHostname(
                binding.hostname
            ),
            canonicalIPv4(binding.listenAddress) ==
                binding.listenAddress,
            canonicalIPv4(binding.targetAddress) ==
                binding.targetAddress,
            canonicalIPv4CIDR(binding.clientCIDR) ==
                binding.clientCIDR,
            ipv4(binding.listenAddress, belongsTo: binding.clientCIDR),
            !isLoopback(binding.listenAddress),
            (1...65_535).contains(binding.port) else {
                throw NetworkHelperError.invalidRequest
            }

            switch binding.addressClass {
            case .loopback:
                guard binding.targetAddress == "127.0.0.1" else {
                    throw NetworkHelperError.invalidRequest
                }
            case .interface:
                guard !isLoopback(binding.targetAddress),
                      !isUnspecified(binding.targetAddress),
                      !isMulticast(binding.targetAddress) else {
                    throw NetworkHelperError.invalidRequest
                }
            }

            let identity = [
                binding.hostname,
                binding.protocolName.rawValue,
                String(binding.port),
                binding.addressClass.rawValue,
                binding.listenAddress,
                binding.clientCIDR,
                binding.targetAddress
            ].joined(separator: "\u{1f}")
            let listener = [
                binding.protocolName.rawValue,
                binding.listenAddress,
                String(binding.port)
            ].joined(separator: "\u{1f}")
            if let prior = hostnames[binding.hostname],
               (
                   prior.listenAddress != binding.listenAddress ||
                       prior.clientCIDR != binding.clientCIDR
               ) {
                throw NetworkHelperError.invalidRequest
            }
            hostnames[binding.hostname] = binding
            guard identities.insert(identity).inserted,
                  listeners.insert(listener).inserted else {
                throw NetworkHelperError.invalidRequest
            }
        }
        return bindings.sorted(
            by: ProjectDNSHostAccessBinding.canonicalPrecedes
        )
    }

    static func isActiveLocalAddress(_ value: String) -> Bool {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return false }
        defer { freeifaddrs(pointer) }
        var current = pointer
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  let rendered = ipv4String(address) else {
                continue
            }
            if rendered == value {
                return true
            }
        }
        return false
    }

    static func ipv4(
        _ address: String,
        belongsTo cidr: String
    ) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              let addressRaw = ipv4Raw(address),
              let networkRaw = ipv4Raw(String(parts[0])) else {
            return false
        }
        let hostAddress = UInt32(bigEndian: addressRaw)
        let hostNetwork = UInt32(bigEndian: networkRaw)
        let mask = prefix == 0
            ? UInt32(0)
            : UInt32.max << UInt32(32 - prefix)
        return hostAddress & mask == hostNetwork & mask
    }

    private static func canonicalIPv4(_ value: String) -> String? {
        guard let raw = ipv4Raw(value) else { return nil }
        var address = in_addr(s_addr: raw)
        var buffer = [CChar](
            repeating: 0,
            count: Int(INET_ADDRSTRLEN)
        )
        guard inet_ntop(
            AF_INET,
            &address,
            &buffer,
            socklen_t(buffer.count)
        ) != nil else {
            return nil
        }
        let canonical = buffer.withUnsafeBufferPointer { bytes in
            String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        }
        return canonical == value ? canonical : nil
    }

    private static func canonicalIPv4CIDR(
        _ value: String
    ) -> String? {
        let parts = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              let address = canonicalIPv4(String(parts[0])),
              let prefix = Int(parts[1]),
              (0...32).contains(prefix),
              let raw = ipv4Raw(address) else {
            return nil
        }
        let host = UInt32(bigEndian: raw)
        let mask = prefix == 0
            ? UInt32(0)
            : UInt32.max << UInt32(32 - prefix)
        guard host & mask == host else { return nil }
        return "\(address)/\(prefix)"
    }

    private static func ipv4Raw(_ value: String) -> UInt32? {
        var raw = in_addr()
        guard value.withCString({
            inet_pton(AF_INET, $0, &raw)
        }) == 1 else {
            return nil
        }
        return raw.s_addr
    }

    private static func ipv4String(
        _ address: UnsafePointer<sockaddr>
    ) -> String? {
        var value = UnsafeRawPointer(address)
            .assumingMemoryBound(to: sockaddr_in.self)
            .pointee.sin_addr
        var buffer = [CChar](
            repeating: 0,
            count: Int(INET_ADDRSTRLEN)
        )
        guard inet_ntop(
            AF_INET,
            &value,
            &buffer,
            socklen_t(buffer.count)
        ) != nil else {
            return nil
        }
        return buffer.withUnsafeBufferPointer { bytes in
            String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        }
    }

    private static func isLoopback(_ value: String) -> Bool {
        guard let raw = ipv4Raw(value) else { return false }
        return UInt32(bigEndian: raw) >> 24 == 127
    }

    private static func isUnspecified(_ value: String) -> Bool {
        ipv4Raw(value).map { UInt32(bigEndian: $0) == 0 } ?? false
    }

    private static func isMulticast(_ value: String) -> Bool {
        guard let raw = ipv4Raw(value) else { return false }
        return (224...239).contains(UInt32(bigEndian: raw) >> 24)
    }
}
