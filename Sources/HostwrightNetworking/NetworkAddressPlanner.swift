import Darwin
import Foundation

public enum NetworkAddressFamily: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case ipv4
    case ipv6

    public static let canonicalOrder: [Self] = [.ipv4, .ipv6]
    public static let connectionPreferenceOrder: [Self] = [.ipv6, .ipv4]

    fileprivate var byteCount: Int {
        switch self {
        case .ipv4: return 4
        case .ipv6: return 16
        }
    }

    fileprivate var maximumPrefix: Int {
        byteCount * 8
    }

    fileprivate var systemValue: Int32 {
        switch self {
        case .ipv4: return AF_INET
        case .ipv6: return AF_INET6
        }
    }

    fileprivate var maximumNetworkPrefix: Int {
        switch self {
        case .ipv4: return 30
        case .ipv6: return 126
        }
    }
}

public enum NetworkAddressTopology: String, Codable, Equatable, Sendable {
    case nat
    case hostOnly
    case routed
    case unavailable
}

public enum NetworkAddressRequestMode: String, Codable, Equatable, Sendable {
    case automatic
    case disabled
    case cidr
}

public struct NetworkAddressFamilyCapability: Codable, Equatable, Sendable {
    public let automatic: Bool
    public let explicitCIDR: Bool
    public let disabled: Bool
    public let unavailableReason: String?

    public init(
        automatic: Bool,
        explicitCIDR: Bool,
        disabled: Bool = true,
        unavailableReason: String? = nil
    ) {
        self.automatic = automatic
        self.explicitCIDR = explicitCIDR
        self.disabled = disabled
        self.unavailableReason = unavailableReason
    }

    public static let fullyAvailable = Self(
        automatic: true,
        explicitCIDR: true,
        disabled: true
    )

    public static func unavailable(reason: String) -> Self {
        Self(
            automatic: false,
            explicitCIDR: false,
            disabled: true,
            unavailableReason: reason
        )
    }
}

public struct NetworkAddressCapabilities: Codable, Equatable, Sendable {
    public let ipv4: NetworkAddressFamilyCapability
    public let ipv6: NetworkAddressFamilyCapability

    public init(
        ipv4: NetworkAddressFamilyCapability,
        ipv6: NetworkAddressFamilyCapability
    ) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }

    public static let dualStack = Self(
        ipv4: .fullyAvailable,
        ipv6: .fullyAvailable
    )

    public func capability(
        for family: NetworkAddressFamily
    ) -> NetworkAddressFamilyCapability {
        switch family {
        case .ipv4: return ipv4
        case .ipv6: return ipv6
        }
    }
}

public struct NetworkAddressPlanningConstraints: Codable, Equatable, Sendable {
    public let hostCIDRs: [String]
    public let occupiedCIDRs: [String]

    public init(
        hostCIDRs: [String] = [],
        occupiedCIDRs: [String] = []
    ) {
        self.hostCIDRs = hostCIDRs
        self.occupiedCIDRs = occupiedCIDRs
    }
}

public enum NetworkHostInterfaceInventoryError: Error, Equatable, Sendable {
    case unavailable(Int32)
    case invalidNetmask
    case addressRenderingFailed
}

public enum NetworkHostInterfaceInventory {
    public static func currentCIDRs() throws -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        let status = getifaddrs(&first)
        guard status == 0 else {
            throw NetworkHostInterfaceInventoryError.unavailable(errno)
        }
        guard let first else { return [] }
        defer { freeifaddrs(first) }

        var result = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = interface.pointee.ifa_addr,
                  let netmask = interface.pointee.ifa_netmask else {
                continue
            }
            let family: NetworkAddressFamily
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                family = .ipv4
            case AF_INET6:
                family = .ipv6
            default:
                continue
            }
            let addressBytes = bytes(
                address,
                family: family
            )
            let netmaskBytes = bytes(
                netmask,
                family: family
            )
            guard let prefix = contiguousPrefixLength(netmaskBytes) else {
                throw NetworkHostInterfaceInventoryError.invalidNetmask
            }
            let networkBytes = zip(addressBytes, netmaskBytes).map {
                $0 & $1
            }
            result.insert(
                "\(try render(networkBytes, family: family))/\(prefix)"
            )
        }
        return result.sorted()
    }

    private static func bytes(
        _ address: UnsafeMutablePointer<sockaddr>,
        family: NetworkAddressFamily
    ) -> [UInt8] {
        switch family {
        case .ipv4:
            var value = UnsafeRawPointer(address)
                .assumingMemoryBound(to: sockaddr_in.self)
                .pointee.sin_addr
            return withUnsafeBytes(of: &value) { Array($0) }
        case .ipv6:
            var value = UnsafeRawPointer(address)
                .assumingMemoryBound(to: sockaddr_in6.self)
                .pointee.sin6_addr
            return withUnsafeBytes(of: &value) { Array($0) }
        }
    }

    private static func contiguousPrefixLength(
        _ bytes: [UInt8]
    ) -> Int? {
        var prefix = 0
        var sawZero = false
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                let isSet = byte & UInt8(1 << shift) != 0
                if isSet {
                    guard !sawZero else { return nil }
                    prefix += 1
                } else {
                    sawZero = true
                }
            }
        }
        return prefix
    }

    private static func render(
        _ bytes: [UInt8],
        family: NetworkAddressFamily
    ) throws -> String {
        var output = [CChar](
            repeating: 0,
            count: family == .ipv4
                ? Int(INET_ADDRSTRLEN)
                : Int(INET6_ADDRSTRLEN)
        )
        let rendered = bytes.withUnsafeBytes { source in
            inet_ntop(
                family.systemValue,
                source.baseAddress,
                &output,
                socklen_t(output.count)
            )
        }
        guard rendered != nil else {
            throw NetworkHostInterfaceInventoryError
                .addressRenderingFailed
        }
        return ParsedIPAddress.decodedCString(output)
    }
}

public struct NetworkAddressFamilyPlan: Codable, Equatable, Sendable {
    public let family: NetworkAddressFamily
    public let mode: NetworkAddressRequestMode
    public let cidr: String?
    public let topology: NetworkAddressTopology

    public init(
        family: NetworkAddressFamily,
        mode: NetworkAddressRequestMode,
        cidr: String?,
        topology: NetworkAddressTopology
    ) {
        self.family = family
        self.mode = mode
        self.cidr = cidr
        self.topology = topology
    }
}

public struct NetworkAddressPlan: Codable, Equatable, Sendable {
    public let networkName: String
    public let families: [NetworkAddressFamilyPlan]

    public init(
        networkName: String,
        families: [NetworkAddressFamilyPlan]
    ) {
        self.networkName = networkName
        self.families = families.sorted {
            NetworkAddressFamily.canonicalOrder.firstIndex(of: $0.family)! <
                NetworkAddressFamily.canonicalOrder.firstIndex(of: $1.family)!
        }
    }

    public func family(
        _ family: NetworkAddressFamily
    ) -> NetworkAddressFamilyPlan? {
        families.first { $0.family == family }
    }

    public var activeFamilies: [NetworkAddressFamily] {
        families.compactMap {
            $0.mode == .disabled ? nil : $0.family
        }
    }
}

public struct NetworkAddressUnavailable: Error, Codable, Equatable, Sendable {
    public let networkName: String
    public let family: NetworkAddressFamily
    public let requestedMode: NetworkAddressRequestMode
    public let reason: String

    public init(
        networkName: String,
        family: NetworkAddressFamily,
        requestedMode: NetworkAddressRequestMode,
        reason: String
    ) {
        self.networkName = networkName
        self.family = family
        self.requestedMode = requestedMode
        self.reason = reason
    }
}

public enum NetworkAddressPlanResult: Equatable, Sendable {
    case planned([NetworkAddressPlan])
    case unavailable(NetworkAddressUnavailable)
}

public enum NetworkAddressPlanningError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case duplicateNetworkName(String)
    case allFamiliesDisabled(networkName: String)
    case invalidCIDR(family: NetworkAddressFamily, value: String)
    case invalidPrefix(family: NetworkAddressFamily, value: Int)
    case hostBitsSet(family: NetworkAddressFamily, value: String)
    case reservedRange(family: NetworkAddressFamily, value: String, reserved: String)
    case networkOverlap(first: String, second: String)
    case hostConflict(network: String, host: String)
    case occupiedConflict(network: String, occupied: String)
    case observedFamilyUnexpected(networkName: String, family: NetworkAddressFamily)
    case observedCIDRMismatch(
        networkName: String,
        family: NetworkAddressFamily,
        expected: String,
        actual: String
    )
    case invalidGateway(
        networkName: String,
        family: NetworkAddressFamily,
        value: String
    )
    case invalidAssignedAddress(
        networkName: String,
        family: NetworkAddressFamily,
        value: String
    )

    public var description: String {
        switch self {
        case .duplicateNetworkName(let name):
            return "Duplicate network name '\(name)'."
        case .allFamiliesDisabled(let networkName):
            return "Network '\(networkName)' cannot disable both IPv4 and IPv6."
        case .invalidCIDR(let family, let value):
            return "Invalid \(family.rawValue) CIDR '\(value)'."
        case .invalidPrefix(let family, let value):
            return "Invalid \(family.rawValue) network prefix \(value)."
        case .hostBitsSet(let family, let value):
            return "\(family.rawValue) CIDR '\(value)' has host bits set."
        case .reservedRange(let family, let value, let reserved):
            return "\(family.rawValue) CIDR '\(value)' overlaps reserved range '\(reserved)'."
        case .networkOverlap(let first, let second):
            return "Network CIDRs '\(first)' and '\(second)' overlap."
        case .hostConflict(let network, let host):
            return "Network CIDR '\(network)' overlaps host CIDR '\(host)'."
        case .occupiedConflict(let network, let occupied):
            return "Network CIDR '\(network)' overlaps occupied CIDR '\(occupied)'."
        case .observedFamilyUnexpected(let networkName, let family):
            return "Network '\(networkName)' observed unexpected \(family.rawValue) state."
        case .observedCIDRMismatch(let networkName, let family, let expected, let actual):
            return "Network '\(networkName)' \(family.rawValue) CIDR '\(actual)' does not match requested '\(expected)'."
        case .invalidGateway(let networkName, let family, let value):
            return "Network '\(networkName)' has invalid \(family.rawValue) gateway '\(value)'."
        case .invalidAssignedAddress(let networkName, let family, let value):
            return "Network '\(networkName)' has invalid \(family.rawValue) assigned address '\(value)'."
        }
    }
}

public enum NetworkAddressPlanner {
    public static func evaluate(
        definitions: [HostwrightNetworkDefinition],
        capabilities: NetworkAddressCapabilities,
        constraints: NetworkAddressPlanningConstraints = .init()
    ) throws -> NetworkAddressPlanResult {
        do {
            return .planned(
                try makePlans(
                    definitions: definitions,
                    capabilities: capabilities,
                    constraints: constraints
                )
            )
        } catch let unavailable as NetworkAddressUnavailable {
            return .unavailable(unavailable)
        }
    }

    public static func makePlans(
        definitions: [HostwrightNetworkDefinition],
        capabilities: NetworkAddressCapabilities,
        constraints: NetworkAddressPlanningConstraints = .init()
    ) throws -> [NetworkAddressPlan] {
        let hostCIDRs = try constraints.hostCIDRs.map {
            try ParsedNetworkCIDR.parseConstraint($0)
        }
        let occupiedCIDRs = try constraints.occupiedCIDRs.map {
            try ParsedNetworkCIDR.parseConstraint($0)
        }
        var names = Set<String>()
        var explicitNetworks: [(name: String, cidr: ParsedNetworkCIDR)] = []
        var plans: [NetworkAddressPlan] = []

        for definition in definitions.sorted(by: { $0.name < $1.name }) {
            guard names.insert(definition.name).inserted else {
                throw NetworkAddressPlanningError.duplicateNetworkName(
                    definition.name
                )
            }
            guard definition.ipv4 != .disabled || definition.ipv6 != .disabled else {
                throw NetworkAddressPlanningError.allFamiliesDisabled(
                    networkName: definition.name
                )
            }

            var families: [NetworkAddressFamilyPlan] = []
            for family in NetworkAddressFamily.canonicalOrder {
                let request = request(for: family, definition: definition)
                let capability = capabilities.capability(for: family)
                let topology = topology(for: definition.driver)
                switch request {
                case .disabled:
                    guard capability.disabled else {
                        throw NetworkAddressUnavailable(
                            networkName: definition.name,
                            family: family,
                            requestedMode: .disabled,
                            reason: capability.unavailableReason ??
                                "Provider cannot disable \(family.rawValue)."
                        )
                    }
                    families.append(
                        NetworkAddressFamilyPlan(
                            family: family,
                            mode: .disabled,
                            cidr: nil,
                            topology: .unavailable
                        )
                    )
                case .auto:
                    guard capability.automatic else {
                        throw NetworkAddressUnavailable(
                            networkName: definition.name,
                            family: family,
                            requestedMode: .automatic,
                            reason: capability.unavailableReason ??
                                "Provider does not support automatic \(family.rawValue) allocation."
                        )
                    }
                    families.append(
                        NetworkAddressFamilyPlan(
                            family: family,
                            mode: .automatic,
                            cidr: nil,
                            topology: topology
                        )
                    )
                case .cidr(let value):
                    guard capability.explicitCIDR else {
                        throw NetworkAddressUnavailable(
                            networkName: definition.name,
                            family: family,
                            requestedMode: .cidr,
                            reason: capability.unavailableReason ??
                                "Provider does not support explicit \(family.rawValue) CIDRs."
                        )
                    }
                    let parsed = try ParsedNetworkCIDR.parseRequested(
                        value,
                        family: family
                    )
                    try validate(
                        network: parsed,
                        hostCIDRs: hostCIDRs,
                        occupiedCIDRs: occupiedCIDRs
                    )
                    for existing in explicitNetworks where parsed.overlaps(existing.cidr) {
                        throw NetworkAddressPlanningError.networkOverlap(
                            first: existing.cidr.canonical,
                            second: parsed.canonical
                        )
                    }
                    explicitNetworks.append((definition.name, parsed))
                    families.append(
                        NetworkAddressFamilyPlan(
                            family: family,
                            mode: .cidr,
                            cidr: parsed.canonical,
                            topology: topology
                        )
                    )
                }
            }
            plans.append(
                NetworkAddressPlan(
                    networkName: definition.name,
                    families: families
                )
            )
        }
        return plans
    }

    fileprivate static func validate(
        network: ParsedNetworkCIDR,
        hostCIDRs: [ParsedNetworkCIDR],
        occupiedCIDRs: [ParsedNetworkCIDR]
    ) throws {
        if let reserved = network.overlappingReservedRange {
            throw NetworkAddressPlanningError.reservedRange(
                family: network.family,
                value: network.canonical,
                reserved: reserved
            )
        }
        if let host = hostCIDRs.first(where: network.overlaps) {
            throw NetworkAddressPlanningError.hostConflict(
                network: network.canonical,
                host: host.canonical
            )
        }
        if let occupied = occupiedCIDRs.first(where: network.overlaps) {
            throw NetworkAddressPlanningError.occupiedConflict(
                network: network.canonical,
                occupied: occupied.canonical
            )
        }
    }

    private static func request(
        for family: NetworkAddressFamily,
        definition: HostwrightNetworkDefinition
    ) -> HostwrightNetworkAddressRequest {
        switch family {
        case .ipv4: return definition.ipv4
        case .ipv6: return definition.ipv6
        }
    }

    private static func topology(
        for driver: HostwrightNetworkDriver
    ) -> NetworkAddressTopology {
        switch driver {
        case .nat: return .nat
        case .hostOnly: return .hostOnly
        }
    }
}

public struct NetworkAddressFamilyObservation: Codable, Equatable, Sendable {
    public let family: NetworkAddressFamily
    public let topology: NetworkAddressTopology
    public let cidr: String
    public let gateway: String?
    public let assignedAddresses: [String]

    public init(
        family: NetworkAddressFamily,
        topology: NetworkAddressTopology,
        cidr: String,
        gateway: String? = nil,
        assignedAddresses: [String] = []
    ) {
        self.family = family
        self.topology = topology
        self.cidr = cidr
        self.gateway = gateway
        self.assignedAddresses = assignedAddresses
    }
}

public enum NetworkAddressObservedState: String, Codable, Equatable, Sendable {
    case disabled
    case available
    case unavailable
}

public struct NetworkAddressFamilyReport: Codable, Equatable, Sendable {
    public let family: NetworkAddressFamily
    public let state: NetworkAddressObservedState
    public let topology: NetworkAddressTopology
    public let cidr: String?
    public let gateway: String?
    public let assignedAddresses: [String]
    public let reason: String?

    public init(
        family: NetworkAddressFamily,
        state: NetworkAddressObservedState,
        topology: NetworkAddressTopology,
        cidr: String?,
        gateway: String?,
        assignedAddresses: [String],
        reason: String?
    ) {
        self.family = family
        self.state = state
        self.topology = topology
        self.cidr = cidr
        self.gateway = gateway
        self.assignedAddresses = assignedAddresses
        self.reason = reason
    }

    public var canPublishListener: Bool {
        state == .available && !assignedAddresses.isEmpty
    }
}

public struct NetworkAddressObservationReport: Codable, Equatable, Sendable {
    public let networkName: String
    public let families: [NetworkAddressFamilyReport]

    public init(
        networkName: String,
        families: [NetworkAddressFamilyReport]
    ) {
        self.networkName = networkName
        self.families = families.sorted {
            NetworkAddressFamily.canonicalOrder.firstIndex(of: $0.family)! <
                NetworkAddressFamily.canonicalOrder.firstIndex(of: $1.family)!
        }
    }

    public func family(
        _ family: NetworkAddressFamily
    ) -> NetworkAddressFamilyReport? {
        families.first { $0.family == family }
    }

    public func canPublishListener(
        for family: NetworkAddressFamily
    ) -> Bool {
        self.family(family)?.canPublishListener == true
    }
}

public enum NetworkAddressObserver {
    public static func verify(
        plan: NetworkAddressPlan,
        observed: [NetworkAddressFamilyObservation],
        constraints: NetworkAddressPlanningConstraints = .init()
    ) throws -> NetworkAddressObservationReport {
        let hostCIDRs = try constraints.hostCIDRs.map {
            try ParsedNetworkCIDR.parseConstraint($0)
        }
        let occupiedCIDRs = try constraints.occupiedCIDRs.map {
            try ParsedNetworkCIDR.parseConstraint($0)
        }
        var byFamily: [NetworkAddressFamily: NetworkAddressFamilyObservation] = [:]
        for item in observed {
            guard byFamily[item.family] == nil else {
                throw NetworkAddressPlanningError.observedFamilyUnexpected(
                    networkName: plan.networkName,
                    family: item.family
                )
            }
            byFamily[item.family] = item
        }

        var reports: [NetworkAddressFamilyReport] = []
        for family in NetworkAddressFamily.canonicalOrder {
            guard let familyPlan = plan.family(family) else {
                continue
            }
            guard familyPlan.mode != .disabled else {
                guard byFamily[family] == nil else {
                    throw NetworkAddressPlanningError.observedFamilyUnexpected(
                        networkName: plan.networkName,
                        family: family
                    )
                }
                reports.append(
                    NetworkAddressFamilyReport(
                        family: family,
                        state: .disabled,
                        topology: .unavailable,
                        cidr: nil,
                        gateway: nil,
                        assignedAddresses: [],
                        reason: nil
                    )
                )
                continue
            }
            guard let item = byFamily[family] else {
                reports.append(
                    NetworkAddressFamilyReport(
                        family: family,
                        state: .unavailable,
                        topology: .unavailable,
                        cidr: nil,
                        gateway: nil,
                        assignedAddresses: [],
                        reason: "Provider did not observe an assigned \(family.rawValue) family."
                    )
                )
                continue
            }

            let observedSubnet = try ParsedNetworkCIDR.parseObserved(
                item.cidr,
                family: family
            )
            let subnet = observedSubnet.network
            try NetworkAddressPlanner.validate(
                network: subnet,
                hostCIDRs: hostCIDRs,
                occupiedCIDRs: occupiedCIDRs
            )
            if let expected = familyPlan.cidr, expected != subnet.canonical {
                throw NetworkAddressPlanningError.observedCIDRMismatch(
                    networkName: plan.networkName,
                    family: family,
                    expected: expected,
                    actual: subnet.canonical
                )
            }

            let explicitGateway = try item.gateway.map {
                try ParsedIPAddress.parse($0, family: family)
            }
            if let interfaceAddress = observedSubnet.interfaceAddress,
               let explicitGateway,
               interfaceAddress != explicitGateway {
                throw NetworkAddressPlanningError.invalidGateway(
                    networkName: plan.networkName,
                    family: family,
                    value: item.gateway ?? item.cidr
                )
            }
            let gateway = try (
                explicitGateway ?? observedSubnet.interfaceAddress
            ).map { address in
                guard subnet.contains(address),
                      !subnet.isNetworkAddress(address),
                      !(family == .ipv4 && subnet.isLastAddress(address)) else {
                    throw NetworkAddressPlanningError.invalidGateway(
                        networkName: plan.networkName,
                        family: family,
                        value: item.gateway ?? item.cidr
                    )
                }
                return address.canonical
            }
            let addresses = try item.assignedAddresses.map {
                let address = try ParsedIPAddress.parseAddressOrInterface(
                    $0,
                    family: family
                )
                guard subnet.contains(address) else {
                    throw NetworkAddressPlanningError.invalidAssignedAddress(
                        networkName: plan.networkName,
                        family: family,
                        value: $0
                    )
                }
                return address
            }
            .uniqued()
            .sorted(by: ParsedIPAddress.numericLessThan)
            .map(\.canonical)

            reports.append(
                NetworkAddressFamilyReport(
                    family: family,
                    state: .available,
                    topology: item.topology,
                    cidr: subnet.canonical,
                    gateway: gateway,
                    assignedAddresses: addresses,
                    reason: nil
                )
            )
        }
        return NetworkAddressObservationReport(
            networkName: plan.networkName,
            families: reports
        )
    }
}

public struct NetworkConnectionCandidate: Codable, Equatable, Sendable {
    public let family: NetworkAddressFamily
    public let address: String
    public let startDelayMilliseconds: Int

    public init(
        family: NetworkAddressFamily,
        address: String,
        startDelayMilliseconds: Int
    ) {
        self.family = family
        self.address = address
        self.startDelayMilliseconds = startDelayMilliseconds
    }
}

public enum NetworkHappyEyeballsPlanner {
    public static let fallbackDelayMilliseconds = 250

    public static func candidates(
        ipv4Addresses: [String],
        ipv6Addresses: [String]
    ) throws -> [NetworkConnectionCandidate] {
        var remaining: [NetworkAddressFamily: [ParsedIPAddress]] = [
            .ipv4: try canonicalAddresses(ipv4Addresses, family: .ipv4),
            .ipv6: try canonicalAddresses(ipv6Addresses, family: .ipv6)
        ]
        var ordered: [(NetworkAddressFamily, ParsedIPAddress)] = []
        while remaining.values.contains(where: { !$0.isEmpty }) {
            for family in NetworkAddressFamily.connectionPreferenceOrder
            where remaining[family]?.isEmpty == false {
                ordered.append((family, remaining[family]!.removeFirst()))
            }
        }
        return ordered.enumerated().map { index, candidate in
            NetworkConnectionCandidate(
                family: candidate.0,
                address: candidate.1.canonical,
                startDelayMilliseconds: index * fallbackDelayMilliseconds
            )
        }
    }

    private static func canonicalAddresses(
        _ values: [String],
        family: NetworkAddressFamily
    ) throws -> [ParsedIPAddress] {
        var result: [ParsedIPAddress] = []
        for value in values {
            do {
                result.append(try ParsedIPAddress.parse(value, family: family))
            } catch {
                throw NetworkAddressPlanningError.invalidAssignedAddress(
                    networkName: "connection-candidates",
                    family: family,
                    value: value
                )
            }
        }
        return result
            .uniqued()
            .sorted(by: ParsedIPAddress.numericLessThan)
    }
}

private struct ParsedIPAddress: Equatable, Hashable {
    let family: NetworkAddressFamily
    let bytes: [UInt8]
    let canonical: String

    static func parseAddressOrInterface(
        _ value: String,
        family: NetworkAddressFamily
    ) throws -> Self {
        let components = value.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 1 || (
            components.count == 2 &&
                Int(components[1]).map {
                    (0...family.maximumPrefix).contains($0)
                } == true
        ) else {
            throw NetworkAddressPlanningError.invalidCIDR(
                family: family,
                value: value
            )
        }
        return try parse(String(components[0]), family: family)
    }

    static func parse(
        _ value: String,
        family: NetworkAddressFamily
    ) throws -> Self {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 128 else {
            throw NetworkAddressPlanningError.invalidCIDR(
                family: family,
                value: value
            )
        }
        switch family {
        case .ipv4:
            var storage = in_addr()
            guard value.withCString({
                inet_pton(AF_INET, $0, &storage)
            }) == 1 else {
                throw NetworkAddressPlanningError.invalidCIDR(
                    family: family,
                    value: value
                )
            }
            let bytes = withUnsafeBytes(of: &storage) { Array($0) }
            return Self(
                family: family,
                bytes: bytes,
                canonical: canonicalIPv4(bytes)
            )
        case .ipv6:
            var storage = in6_addr()
            guard value.withCString({
                inet_pton(AF_INET6, $0, &storage)
            }) == 1 else {
                throw NetworkAddressPlanningError.invalidCIDR(
                    family: family,
                    value: value
                )
            }
            let bytes = withUnsafeBytes(of: &storage) { Array($0) }
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let rendered = withUnsafePointer(to: &storage) {
                inet_ntop(AF_INET6, $0, &output, socklen_t(output.count))
            }
            guard rendered != nil else {
                throw NetworkAddressPlanningError.invalidCIDR(
                    family: family,
                    value: value
                )
            }
            return Self(
                family: family,
                bytes: bytes,
                canonical: decodedCString(output)
            )
        }
    }

    static func numericLessThan(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    private static func canonicalIPv4(_ bytes: [UInt8]) -> String {
        bytes.map(String.init).joined(separator: ".")
    }

    fileprivate static func decodedCString(_ value: [CChar]) -> String {
        let end = value.firstIndex(of: 0) ?? value.endIndex
        return String(
            decoding: value[..<end].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

private struct ParsedNetworkCIDR: Equatable {
    let family: NetworkAddressFamily
    let bytes: [UInt8]
    let prefix: Int
    let canonical: String

    static func parseRequested(
        _ value: String,
        family: NetworkAddressFamily
    ) throws -> Self {
        try parse(value, expectedFamily: family, networkPrefix: true)
    }

    static func parseConstraint(_ value: String) throws -> Self {
        let separator = value.lastIndex(of: "/")
        guard let separator else {
            throw NetworkAddressPlanningError.invalidCIDR(
                family: value.contains(":") ? .ipv6 : .ipv4,
                value: value
            )
        }
        let addressValue = String(value[..<separator])
        let family: NetworkAddressFamily = addressValue.contains(":") ? .ipv6 : .ipv4
        return try parseComponents(
            value,
            expectedFamily: family,
            networkPrefix: false,
            allowHostBits: true
        ).network
    }

    static func parseObserved(
        _ value: String,
        family: NetworkAddressFamily
    ) throws -> (
        network: Self,
        interfaceAddress: ParsedIPAddress?
    ) {
        try parseComponents(
            value,
            expectedFamily: family,
            networkPrefix: true,
            allowHostBits: true
        )
    }

    private static func parse(
        _ value: String,
        expectedFamily: NetworkAddressFamily,
        networkPrefix: Bool
    ) throws -> Self {
        try parseComponents(
            value,
            expectedFamily: expectedFamily,
            networkPrefix: networkPrefix,
            allowHostBits: false
        ).network
    }

    private static func parseComponents(
        _ value: String,
        expectedFamily: NetworkAddressFamily,
        networkPrefix: Bool,
        allowHostBits: Bool
    ) throws -> (
        network: Self,
        interfaceAddress: ParsedIPAddress?
    ) {
        let components = value.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              let prefix = Int(components[1]) else {
            throw NetworkAddressPlanningError.invalidCIDR(
                family: expectedFamily,
                value: value
            )
        }
        let address = try ParsedIPAddress.parse(
            String(components[0]),
            family: expectedFamily
        )
        guard prefix >= (networkPrefix ? 1 : 0),
              prefix <= (networkPrefix
                  ? expectedFamily.maximumNetworkPrefix
                  : expectedFamily.maximumPrefix) else {
            throw NetworkAddressPlanningError.invalidPrefix(
                family: expectedFamily,
                value: prefix
            )
        }
        let networkBytes = masked(address.bytes, prefix: prefix)
        guard allowHostBits || address.bytes == networkBytes else {
            throw NetworkAddressPlanningError.hostBitsSet(
                family: expectedFamily,
                value: value
            )
        }
        let canonicalAddress: String
        switch expectedFamily {
        case .ipv4:
            canonicalAddress = networkBytes.map(String.init).joined(separator: ".")
        case .ipv6:
            var storage = in6_addr()
            withUnsafeMutableBytes(of: &storage) {
                $0.copyBytes(from: networkBytes)
            }
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard withUnsafePointer(to: &storage, {
                inet_ntop(AF_INET6, $0, &output, socklen_t(output.count))
            }) != nil else {
                throw NetworkAddressPlanningError.invalidCIDR(
                    family: expectedFamily,
                    value: value
                )
            }
            canonicalAddress = ParsedIPAddress.decodedCString(output)
        }
        return (
            network: Self(
                family: expectedFamily,
                bytes: networkBytes,
                prefix: prefix,
                canonical: "\(canonicalAddress)/\(prefix)"
            ),
            interfaceAddress:
                address.bytes == networkBytes ? nil : address
        )
    }

    func overlaps(_ other: Self) -> Bool {
        guard family == other.family else { return false }
        let commonPrefix = min(prefix, other.prefix)
        return Self.masked(bytes, prefix: commonPrefix) ==
            Self.masked(other.bytes, prefix: commonPrefix)
    }

    func contains(_ address: ParsedIPAddress) -> Bool {
        family == address.family &&
            Self.masked(address.bytes, prefix: prefix) == bytes
    }

    func isNetworkAddress(_ address: ParsedIPAddress) -> Bool {
        address.bytes == bytes
    }

    func isLastAddress(_ address: ParsedIPAddress) -> Bool {
        guard family == .ipv4 else { return false }
        var last = bytes
        for bit in prefix..<family.maximumPrefix {
            last[bit / 8] |= UInt8(1 << (7 - (bit % 8)))
        }
        return address.bytes == last
    }

    var overlappingReservedRange: String? {
        Self.reservedRanges[family]?
            .first(where: overlapsReserved)?
            .canonical
    }

    private func overlapsReserved(_ reserved: ReservedNetwork) -> Bool {
        let commonPrefix = min(prefix, reserved.prefix)
        return Self.masked(bytes, prefix: commonPrefix) ==
            Self.masked(reserved.bytes, prefix: commonPrefix)
    }

    private static func masked(_ bytes: [UInt8], prefix: Int) -> [UInt8] {
        var result = bytes
        for bit in prefix..<(bytes.count * 8) {
            result[bit / 8] &= ~UInt8(1 << (7 - (bit % 8)))
        }
        return result
    }

    private struct ReservedNetwork {
        let bytes: [UInt8]
        let prefix: Int
        let canonical: String
    }

    private static let reservedRanges: [NetworkAddressFamily: [ReservedNetwork]] = [
        .ipv4: [
            reserved(.ipv4, "0.0.0.0", 8),
            reserved(.ipv4, "100.64.0.0", 10),
            reserved(.ipv4, "127.0.0.0", 8),
            reserved(.ipv4, "169.254.0.0", 16),
            reserved(.ipv4, "192.0.0.0", 24),
            reserved(.ipv4, "192.0.2.0", 24),
            reserved(.ipv4, "198.18.0.0", 15),
            reserved(.ipv4, "198.51.100.0", 24),
            reserved(.ipv4, "203.0.113.0", 24),
            reserved(.ipv4, "224.0.0.0", 4),
            reserved(.ipv4, "240.0.0.0", 4)
        ],
        .ipv6: [
            reserved(.ipv6, "::", 128),
            reserved(.ipv6, "::1", 128),
            reserved(.ipv6, "::ffff:0:0", 96),
            reserved(.ipv6, "100::", 64),
            reserved(.ipv6, "2001:db8::", 32),
            reserved(.ipv6, "fe80::", 10),
            reserved(.ipv6, "ff00::", 8)
        ]
    ]

    private static func reserved(
        _ family: NetworkAddressFamily,
        _ address: String,
        _ prefix: Int
    ) -> ReservedNetwork {
        let parsed: ParsedIPAddress
        do {
            parsed = try ParsedIPAddress.parse(address, family: family)
        } catch {
            preconditionFailure("Invalid built-in reserved network: \(address)/\(prefix)")
        }
        return ReservedNetwork(
            bytes: masked(parsed.bytes, prefix: prefix),
            prefix: prefix,
            canonical: "\(parsed.canonical)/\(prefix)"
        )
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
