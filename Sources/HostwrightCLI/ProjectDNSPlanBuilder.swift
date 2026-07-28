import Darwin
import Foundation
import HostwrightNetworking
import HostwrightRuntime

enum ProjectDNSPlanBuilder {
    static func build(
        projectUUID: String,
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState,
        runtimeInventory: RuntimeInventory? = nil,
        options: ProjectDNSOptions = ProjectDNSOptions()
    ) throws -> ProjectDNSPlan {
        let observedByIdentity = Dictionary(
            uniqueKeysWithValues: observedState.services.map {
                ($0.identity, $0)
            }
        )
        let grouped = Dictionary(
            grouping: desiredState.services,
            by: \.logicalServiceName
        )
        let services = grouped.keys.sorted().map {
            serviceName in
            let replicas = grouped[serviceName]!.sorted {
                if $0.replicaIndex != $1.replicaIndex {
                    return $0.replicaIndex < $1.replicaIndex
                }
                return $0.identity.displayName <
                    $1.identity.displayName
            }
            let aliases = Array(
                Set(replicas.flatMap {
                    $0.networks.flatMap(\.aliases)
                })
            ).sorted()
            return ProjectDNSService(
                name: serviceName,
                aliases: aliases,
                replicas: replicas.map {
                    replica(
                        desired: $0,
                        observed: observedByIdentity[$0.identity]
                    )
                }
            )
        }
        return try ProjectDNSPlanner.makePlan(
            projectUUID: projectUUID,
            services: services,
            hostAccessBindings: try hostAccessBindings(
                projectUUID: projectUUID,
                desiredState: desiredState,
                runtimeInventory: runtimeInventory
            ),
            options: options
        )
    }

    private static func hostAccessBindings(
        projectUUID: String,
        desiredState: DesiredRuntimeState,
        runtimeInventory: RuntimeInventory?
    ) throws -> [ProjectDNSHostAccessBinding] {
        let declaring = desiredState.services.filter {
            !$0.hostAccess.isEmpty
        }
        guard !declaring.isEmpty else { return [] }
        guard let runtimeInventory else {
            throw ProjectDNSPlanningError.invalidHostAccess(
                "exact managed network gateway observation is unavailable"
            )
        }
        let networks = Dictionary(
            grouping: runtimeInventory.networks,
            by: \.runtimeID
        )
        var result: [ProjectDNSHostAccessBinding] = []
        for service in declaring.sorted(by: {
            $0.identity.displayName < $1.identity.displayName
        }) {
            guard service.networks.count == 1,
                  let attachment = service.networks.first,
                  let matches = networks[
                    attachment.networkRuntimeIdentifier
                  ],
                  matches.count == 1,
                  let network = matches.first,
                  let ownership = network.ownership,
                  ownership.projectUUID == projectUUID,
                  ownership.resourceUUID ==
                    attachment.networkResourceUUID,
                  let gateway = exactIPv4Gateway(
                    network.addresses
                  ) else {
                throw ProjectDNSPlanningError.invalidHostAccess(
                    "service '\(service.identity.displayName)' requires one exact UUID-owned IPv4 project-network gateway"
                )
            }
            for endpoint in service.hostAccess {
                let target: String
                switch endpoint.addressClass {
                case .loopback:
                    target = "127.0.0.1"
                case .interface:
                    target = try exactLocalInterfaceAddress(
                        hostname: endpoint.hostname
                    )
                }
                result.append(
                    ProjectDNSHostAccessBinding(
                        hostname: endpoint.hostname,
                        protocolName: endpoint.protocolName,
                        addressClass: endpoint.addressClass,
                        listenAddress: gateway.address,
                        clientCIDR: gateway.subnet,
                        targetAddress: target,
                        port: endpoint.port
                    )
                )
            }
        }
        return Array(Set(result)).sorted(
            by: ProjectDNSHostAccessBinding.canonicalPrecedes
        )
    }

    private static func exactIPv4Gateway(
        _ addresses: [String]
    ) -> (address: String, subnet: String)? {
        let candidates = Set(addresses.filter {
            !$0.contains("/") && canonicalIPv4($0) != nil
        })
        let subnets = Set(addresses.filter {
            $0.contains("/") && canonicalIPv4CIDR($0) != nil
        })
        guard candidates.count == 1,
              subnets.count == 1,
              let address = candidates.first,
              let subnet = subnets.first,
              ipv4(address, belongsTo: subnet) else {
            return nil
        }
        return (address, subnet)
    }

    private static func exactLocalInterfaceAddress(
        hostname: String
    ) throws -> String {
        let local = localIPv4InterfaceAddresses()
        let resolved = Set(resolveIPv4(hostname: hostname))
            .intersection(local)
            .subtracting(["127.0.0.1"])
        guard resolved.count == 1, let address = resolved.first else {
            throw ProjectDNSPlanningError.invalidHostAccess(
                "interface hostname '\(hostname)' must resolve to exactly one active non-loopback host interface"
            )
        }
        return address
    }

    private static func resolveIPv4(hostname: String) -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var resultPointer: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(
            hostname,
            nil,
            &hints,
            &resultPointer
        ) == 0 else {
            return []
        }
        defer { freeaddrinfo(resultPointer) }
        var result: [String] = []
        var current = resultPointer
        while let item = current {
            if let address = item.pointee.ai_addr,
               let value = ipv4String(address) {
                result.append(value)
            }
            current = item.pointee.ai_next
        }
        return result
    }

    private static func localIPv4InterfaceAddresses() -> Set<String> {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return [] }
        defer { freeifaddrs(pointer) }
        var result = Set<String>()
        var current = pointer
        while let item = current {
            if let address = item.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               let value = ipv4String(address) {
                result.insert(value)
            }
            current = item.pointee.ifa_next
        }
        return result
    }

    private static func canonicalIPv4(_ value: String) -> String? {
        var address = in_addr()
        guard value.withCString({
            inet_pton(AF_INET, $0, &address)
        }) == 1 else {
            return nil
        }
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
            String(
                decoding: bytes
                    .prefix { $0 != 0 }
                    .map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
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
              (0...32).contains(prefix) else {
            return nil
        }
        var raw = in_addr()
        guard address.withCString({
            inet_pton(AF_INET, $0, &raw)
        }) == 1 else {
            return nil
        }
        let host = UInt32(bigEndian: raw.s_addr)
        let mask = prefix == 0
            ? UInt32(0)
            : UInt32.max << UInt32(32 - prefix)
        guard host & mask == host else { return nil }
        return "\(address)/\(prefix)"
    }

    private static func ipv4(
        _ address: String,
        belongsTo cidr: String
    ) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              var addressRaw = ipv4Raw(address),
              var networkRaw = ipv4Raw(String(parts[0])) else {
            return false
        }
        addressRaw = UInt32(bigEndian: addressRaw)
        networkRaw = UInt32(bigEndian: networkRaw)
        let mask = prefix == 0
            ? UInt32(0)
            : UInt32.max << UInt32(32 - prefix)
        return addressRaw & mask == networkRaw & mask
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
        guard address.pointee.sa_family == UInt8(AF_INET) else {
            return nil
        }
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
            String(
                decoding: bytes
                    .prefix { $0 != 0 }
                    .map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        }
    }

    private static func replica(
        desired: DesiredRuntimeService,
        observed: ObservedRuntimeService?
    ) -> ProjectDNSReplica {
        guard let observed else {
            return ProjectDNSReplica(
                name: replicaName(desired),
                isReady: false
            )
        }
        let ready = observed.healthState == .healthy ||
            (
                desired.probes.readiness == nil &&
                    observed.lifecycleState == .running &&
                    (
                        observed.healthState == .notConfigured ||
                            observed.healthState == .unknown
                    )
            )
        let desiredNetworkNames = Set(
            desired.networks.map(\.networkRuntimeIdentifier)
        )
        let attachments = observed.networks.filter {
            desiredNetworkNames.contains($0.name)
        }
        let ipv4 = attachments.compactMap(\.ipv4Address)
            .map(dnsHostAddress) +
            attachments.compactMap {
                guard let address = $0.address,
                      !address.contains(":") else {
                    return nil
                }
                return dnsHostAddress(address)
            }
        let ipv6 = attachments.compactMap(\.ipv6Address)
            .map(dnsHostAddress) +
            attachments.compactMap {
                guard let address = $0.address,
                      address.contains(":") else {
                    return nil
                }
                return dnsHostAddress(address)
            }
        return ProjectDNSReplica(
            name: replicaName(desired),
            isReady: ready,
            ipv4Addresses: Array(Set(ipv4)).sorted(),
            ipv6Addresses: Array(Set(ipv6)).sorted()
        )
    }

    private static func dnsHostAddress(_ address: String) -> String {
        let parts = address.split(
            separator: "/",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              !parts[0].isEmpty,
              let prefix = Int(parts[1]) else {
            return address
        }
        let host = String(parts[0])
        let validPrefix = host.contains(":")
            ? (0...128).contains(prefix)
            : (0...32).contains(prefix)
        return validPrefix ? host : address
    }

    private static func replicaName(
        _ desired: DesiredRuntimeService
    ) -> String {
        desired.identity.instanceName ??
            "\(desired.logicalServiceName)-\(desired.replicaIndex)"
    }
}
