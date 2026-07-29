import Darwin
import Foundation
import HostwrightNetworking

public enum ContainerizationGuestNetworkPolicyCompilerError:
    Error,
    Equatable,
    Sendable
{
    case invalidProjectIdentity
    case invalidServiceIdentity
    case tooManyPeers
    case duplicatePeer(String)
    case tooManyPeerIdentities(String)
    case invalidPeerIdentity(peer: String, identity: String)
    case tooManyPeerAddresses(String)
    case invalidPeerAddress(peer: String, address: String)
    case tooManyDNSResolutions
    case invalidDNSName(String)
    case tooManyDNSAddresses(String)
    case invalidDNSAddress(name: String, address: String)
    case tooManyDNSServers
    case invalidDNSServer(String)
    case tooManyTrustedIngressGateways
    case invalidTrustedIngressGateway(String)
    case invalidPolicy(String)
    case unknownIdentity(String)
    case unknownDNS(String)
    case unresolvedDNS(String)
    case unresolvedPeer(
        direction: HostwrightNetworkPolicyDirection,
        selector: String
    )
    case unresolvedSelector(
        direction: HostwrightNetworkPolicyDirection,
        selector: String
    )
    case tooManyExpandedRules(HostwrightNetworkPolicyDirection)
}

public struct ContainerizationGuestNetworkPeer:
    Equatable,
    Sendable
{
    public static let maximumIdentities = 64
    public static let maximumAssignedAddresses = 64

    public let projectName: String
    public let projectUUID: String
    public let serviceName: String
    public let resourceUUID: String
    public let identities: [String]
    public let assignedAddresses: [String]

    public init(
        projectName: String,
        projectUUID: String,
        serviceName: String,
        resourceUUID: String,
        identities: [String] = [],
        assignedAddresses: [String] = []
    ) throws {
        guard HostwrightNetworkIdentity.isValidManifestName(projectName),
              Self.isCanonicalUUID(projectUUID) else {
            throw ContainerizationGuestNetworkPolicyCompilerError
                .invalidProjectIdentity
        }
        guard HostwrightNetworkIdentity.isValidManifestName(serviceName),
              Self.isCanonicalUUID(resourceUUID),
              resourceUUID != projectUUID else {
            throw ContainerizationGuestNetworkPolicyCompilerError
                .invalidServiceIdentity
        }
        guard identities.count <= Self.maximumIdentities else {
            throw ContainerizationGuestNetworkPolicyCompilerError
                .tooManyPeerIdentities(resourceUUID)
        }
        for identity in identities {
            guard HostwrightNetworkPolicyValidation.issue(
                in: HostwrightNetworkPolicyRule(identity: identity)
            ) == nil else {
                throw ContainerizationGuestNetworkPolicyCompilerError
                    .invalidPeerIdentity(
                        peer: resourceUUID,
                        identity: identity
                    )
            }
        }
        guard assignedAddresses.count <= Self.maximumAssignedAddresses else {
            throw ContainerizationGuestNetworkPolicyCompilerError
                .tooManyPeerAddresses(resourceUUID)
        }
        let addresses = try assignedAddresses.map {
            guard let canonical = GuestPolicyIPAddress.hostCIDR($0) else {
                throw ContainerizationGuestNetworkPolicyCompilerError
                    .invalidPeerAddress(
                        peer: resourceUUID,
                        address: $0
                    )
            }
            return canonical
        }

        self.projectName = projectName
        self.projectUUID = projectUUID
        self.serviceName = serviceName
        self.resourceUUID = resourceUUID
        self.identities = Array(Set(identities)).sorted()
        self.assignedAddresses = Array(Set(addresses)).sorted()
    }

    fileprivate var canonicalKey: String {
        [
            projectUUID,
            projectName,
            serviceName,
            resourceUUID,
            identities.joined(separator: "\u{1f}"),
            assignedAddresses.joined(separator: "\u{1f}")
        ].joined(separator: "\u{1e}")
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}

public struct ContainerizationGuestDNSResolutionMap:
    Equatable,
    Sendable
{
    public static let maximumNames = 256
    public static let maximumAddressesPerName = 64

    public let entries: [String: [String]]

    public init() {
        entries = [:]
    }

    public init(_ entries: [String: [String]]) throws {
        guard entries.count <= Self.maximumNames else {
            throw ContainerizationGuestNetworkPolicyCompilerError
                .tooManyDNSResolutions
        }
        var normalized = [String: [String]]()
        for name in entries.keys.sorted() {
            guard HostwrightHostAccessPolicy.isValidHostname(name) else {
                throw ContainerizationGuestNetworkPolicyCompilerError
                    .invalidDNSName(name)
            }
            let values = entries[name] ?? []
            guard values.count <= Self.maximumAddressesPerName else {
                throw ContainerizationGuestNetworkPolicyCompilerError
                    .tooManyDNSAddresses(name)
            }
            normalized[name] = try Array(Set(values.map {
                guard let address = GuestPolicyIPAddress.hostCIDR($0) else {
                    throw ContainerizationGuestNetworkPolicyCompilerError
                        .invalidDNSAddress(name: name, address: $0)
                }
                return address
            })).sorted()
        }
        self.entries = normalized
    }

    public subscript(name: String) -> [String]? {
        entries[name]
    }
}

public struct ContainerizationGuestNetworkPolicyInputs:
    Equatable,
    Sendable
{
    public static let maximumPeers = 2_048
    public static let maximumDNSServers = 16
    public static let maximumTrustedIngressGateways = 64

    public let peers: [ContainerizationGuestNetworkPeer]
    public let dnsResolutions: ContainerizationGuestDNSResolutionMap
    public let dnsServers: [String]
    public let trustedIngressGateways: [String]

    public init(
        peers: [ContainerizationGuestNetworkPeer] = [],
        dnsResolutions: ContainerizationGuestDNSResolutionMap = .init(),
        dnsServers: [String] = [],
        trustedIngressGateways: [String] = []
    ) throws {
        guard peers.count <= Self.maximumPeers else {
            throw ContainerizationGuestNetworkPolicyCompilerError.tooManyPeers
        }
        var peerIDs = Set<String>()
        for peer in peers.sorted(by: {
            $0.resourceUUID < $1.resourceUUID
        }) {
            guard peerIDs.insert(peer.resourceUUID).inserted else {
                throw ContainerizationGuestNetworkPolicyCompilerError
                    .duplicatePeer(peer.resourceUUID)
            }
        }
        guard dnsServers.count <= Self.maximumDNSServers else {
            throw ContainerizationGuestNetworkPolicyCompilerError
                .tooManyDNSServers
        }
        let normalizedDNSServers = try dnsServers.map {
            guard let address = GuestPolicyIPAddress.canonicalAddress($0) else {
                throw ContainerizationGuestNetworkPolicyCompilerError
                    .invalidDNSServer($0)
            }
            return address
        }
        guard trustedIngressGateways.count <=
                Self.maximumTrustedIngressGateways else {
            throw ContainerizationGuestNetworkPolicyCompilerError
                .tooManyTrustedIngressGateways
        }
        let gateways = try trustedIngressGateways.map {
            guard let address = GuestPolicyIPAddress.hostCIDR($0) else {
                throw ContainerizationGuestNetworkPolicyCompilerError
                    .invalidTrustedIngressGateway($0)
            }
            return address
        }

        self.peers = peers.sorted {
            $0.canonicalKey < $1.canonicalKey
        }
        self.dnsResolutions = dnsResolutions
        self.dnsServers = Array(Set(normalizedDNSServers)).sorted()
        self.trustedIngressGateways = Array(Set(gateways)).sorted()
    }
}

public enum ContainerizationGuestNetworkPolicyCompiler {
    public static func compile(
        projectName: String,
        projectUUID: String,
        generation: Int,
        serviceName: String,
        serviceResourceUUID: String,
        policy: HostwrightServiceNetworkPolicy?,
        inputs: ContainerizationGuestNetworkPolicyInputs
    ) throws -> ContainerizationGuestNetworkPolicy {
        guard HostwrightNetworkIdentity.isValidManifestName(projectName),
              isCanonicalUUID(projectUUID) else {
            throw ContainerizationGuestNetworkPolicyCompilerError
                .invalidProjectIdentity
        }
        guard HostwrightNetworkIdentity.isValidManifestName(serviceName),
              isCanonicalUUID(serviceResourceUUID),
              serviceResourceUUID != projectUUID else {
            throw ContainerizationGuestNetworkPolicyCompilerError
                .invalidServiceIdentity
        }
        if let policy,
           let issue = HostwrightNetworkPolicyValidation.issue(in: policy) {
            throw ContainerizationGuestNetworkPolicyCompilerError
                .invalidPolicy(issue)
        }

        let ingress: [ContainerizationGuestNetworkPolicyRule]
        let egress: [ContainerizationGuestNetworkPolicyRule]
        let defaultAction: NetworkPolicyDefaultAction
        if let policy {
            defaultAction = .deny
            ingress = try compile(
                rules: policy.ingress,
                direction: .ingress,
                inputs: inputs
            )
            egress = try compile(
                rules: policy.egress,
                direction: .egress,
                inputs: inputs
            )
        } else {
            defaultAction = .allowSameProject
            let peerAddresses = try sameProjectPeerAddresses(
                projectUUID: projectUUID,
                serviceResourceUUID: serviceResourceUUID,
                peers: inputs.peers
            )
            ingress = try rules(
                addresses: peerAddresses,
                protocols: HostwrightNetworkPolicyProtocol.allCases,
                port: nil,
                direction: .ingress
            )
            egress = try rules(
                addresses: peerAddresses,
                protocols: HostwrightNetworkPolicyProtocol.allCases,
                port: nil,
                direction: .egress
            )
        }

        return try ContainerizationGuestNetworkPolicy(
            generation: generation,
            projectUUID: projectUUID,
            serviceResourceUUID: serviceResourceUUID,
            ingressDefault: defaultAction,
            egressDefault: defaultAction,
            dnsServers: inputs.dnsServers,
            ingress: ingress,
            egress: egress
        )
    }

    private static func compile(
        rules sourceRules: [HostwrightNetworkPolicyRule],
        direction: HostwrightNetworkPolicyDirection,
        inputs: ContainerizationGuestNetworkPolicyInputs
    ) throws -> [ContainerizationGuestNetworkPolicyRule] {
        var compiled = [ContainerizationGuestNetworkPolicyRule]()
        for rule in sourceRules.sorted(by: {
            $0.canonicalKey < $1.canonicalKey
        }) {
            let addresses = try resolveAddresses(
                for: rule,
                direction: direction,
                inputs: inputs
            )
            let protocols = rule.protocolName.map { [$0] } ??
                HostwrightNetworkPolicyProtocol.allCases
            compiled += try rules(
                addresses: addresses,
                protocols: protocols,
                port: rule.port,
                direction: direction
            )
            if direction == .ingress {
                compiled += try rules(
                    addresses: inputs.trustedIngressGateways,
                    protocols: protocols,
                    port: rule.port,
                    direction: direction
                )
            }
            guard Set(compiled).count <=
                    ContainerizationGuestNetworkPolicy
                    .maximumRulesPerDirection else {
                throw ContainerizationGuestNetworkPolicyCompilerError
                    .tooManyExpandedRules(direction)
            }
        }
        return Array(Set(compiled)).sorted {
            $0.canonicalKey < $1.canonicalKey
        }
    }

    private static func resolveAddresses(
        for rule: HostwrightNetworkPolicyRule,
        direction: HostwrightNetworkPolicyDirection,
        inputs: ContainerizationGuestNetworkPolicyInputs
    ) throws -> [String] {
        var selections = [[String]]()
        let hasPeerSelector =
            rule.project != nil ||
            rule.service != nil ||
            rule.identity != nil

        if let identity = rule.identity,
           !inputs.peers.contains(where: {
               $0.identities.contains(identity)
           }) {
            throw ContainerizationGuestNetworkPolicyCompilerError
                .unknownIdentity(identity)
        }
        if hasPeerSelector {
            let peers = inputs.peers.filter {
                (rule.project == nil ||
                    rule.project == $0.projectName ||
                    rule.project == $0.projectUUID) &&
                    (rule.service == nil ||
                        rule.service == $0.serviceName) &&
                    (rule.identity == nil ||
                        $0.identities.contains(rule.identity!))
            }
            guard !peers.isEmpty else {
                throw ContainerizationGuestNetworkPolicyCompilerError
                    .unresolvedPeer(
                        direction: direction,
                        selector: rule.canonicalKey
                    )
            }
            selections.append(
                Array(Set(peers.flatMap(\.assignedAddresses))).sorted()
            )
            return try appendRemainingAddressSelections(
                to: selections,
                rule: rule,
                direction: direction,
                inputs: inputs
            )
        }
        return try appendRemainingAddressSelections(
            to: selections,
            rule: rule,
            direction: direction,
            inputs: inputs
        )
    }

    private static func appendRemainingAddressSelections(
        to initial: [[String]],
        rule: HostwrightNetworkPolicyRule,
        direction: HostwrightNetworkPolicyDirection,
        inputs: ContainerizationGuestNetworkPolicyInputs
    ) throws -> [String] {
        var selections = initial
        if let address = rule.address {
            selections.append([address])
        }
        if let dns = rule.dns {
            guard let resolved = inputs.dnsResolutions[dns] else {
                throw ContainerizationGuestNetworkPolicyCompilerError
                    .unknownDNS(dns)
            }
            selections.append(resolved)
        }
        guard var result = selections.first else {
            return ["0.0.0.0/0", "::/0"]
        }
        for selection in selections.dropFirst() {
            result = intersect(result, selection)
            if result.isEmpty { break }
        }
        return Array(Set(result)).sorted()
    }

    private static func sameProjectPeerAddresses(
        projectUUID: String,
        serviceResourceUUID: String,
        peers: [ContainerizationGuestNetworkPeer]
    ) throws -> [String] {
        let selected = peers.filter {
            $0.projectUUID == projectUUID &&
                $0.resourceUUID != serviceResourceUUID
        }
        return Array(Set(selected.flatMap(\.assignedAddresses))).sorted()
    }

    private static func rules(
        addresses: [String],
        protocols: [HostwrightNetworkPolicyProtocol],
        port: Int?,
        direction: HostwrightNetworkPolicyDirection
    ) throws -> [ContainerizationGuestNetworkPolicyRule] {
        guard addresses.count.multipliedReportingOverflow(
            by: protocols.count
        ).overflow == false,
        addresses.count * protocols.count <=
            ContainerizationGuestNetworkPolicy.maximumRulesPerDirection else {
            throw ContainerizationGuestNetworkPolicyCompilerError
                .tooManyExpandedRules(direction)
        }
        return try addresses.flatMap { address in
            try protocols.map {
                try ContainerizationGuestNetworkPolicyRule(
                    address: address,
                    port: port,
                    protocolName: $0
                )
            }
        }
    }

    private static func intersect(
        _ left: [String],
        _ right: [String]
    ) -> [String] {
        var result = Set<String>()
        for leftValue in left {
            guard let leftCIDR = GuestPolicyCIDR(leftValue) else {
                continue
            }
            for rightValue in right {
                guard let rightCIDR = GuestPolicyCIDR(rightValue),
                      let intersection = leftCIDR.intersection(
                          with: rightCIDR
                      ) else {
                    continue
                }
                result.insert(intersection)
            }
        }
        return result.sorted()
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}

private enum GuestPolicyIPAddress {
    static func canonicalAddress(_ value: String) -> String? {
        guard !value.contains("/") else { return nil }
        return parsed(value)?.canonical
    }

    static func hostCIDR(_ value: String) -> String? {
        let components = value.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 1 || components.count == 2,
              let parsed = parsed(String(components[0])) else {
            return nil
        }
        if components.count == 2 {
            guard let prefix = Int(components[1]),
                  String(prefix) == components[1],
                  (0...parsed.maximumPrefix).contains(prefix) else {
                return nil
            }
        }
        return "\(parsed.canonical)/\(parsed.maximumPrefix)"
    }

    private static func parsed(
        _ value: String
    ) -> (canonical: String, maximumPrefix: Int)? {
        for (family, byteCount, maximumPrefix) in [
            (AF_INET, 4, 32),
            (AF_INET6, 16, 128)
        ] {
            var bytes = [UInt8](repeating: 0, count: byteCount)
            let parsed = bytes.withUnsafeMutableBytes {
                inet_pton(family, value, $0.baseAddress)
            }
            guard parsed == 1 else { continue }
            if family == AF_INET6,
               Array(bytes.prefix(12)) ==
                [UInt8](repeating: 0, count: 10) + [0xff, 0xff] {
                return nil
            }
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(
                family,
                bytes,
                &output,
                socklen_t(output.count)
            ) != nil else {
                return nil
            }
            let terminator = output.firstIndex(of: 0) ?? output.endIndex
            return (
                String(
                    decoding: output[..<terminator].map {
                        UInt8(bitPattern: $0)
                    },
                    as: UTF8.self
                ),
                maximumPrefix
            )
        }
        return nil
    }
}

private struct GuestPolicyCIDR {
    let family: Int32
    let bytes: [UInt8]
    let prefix: Int
    let canonical: String

    init?(_ value: String) {
        guard NetworkExposurePolicyValidation.canonicalCIDR(value) == value
        else {
            return nil
        }
        let components = value.split(separator: "/", maxSplits: 1)
        guard components.count == 2, let prefix = Int(components[1]) else {
            return nil
        }
        for (family, byteCount) in [(AF_INET, 4), (AF_INET6, 16)] {
            var bytes = [UInt8](repeating: 0, count: byteCount)
            let result = bytes.withUnsafeMutableBytes {
                inet_pton(family, String(components[0]), $0.baseAddress)
            }
            guard result == 1 else { continue }
            self.family = family
            self.bytes = bytes
            self.prefix = prefix
            canonical = value
            return
        }
        return nil
    }

    func intersection(with other: Self) -> String? {
        guard family == other.family else { return nil }
        let commonPrefix = min(prefix, other.prefix)
        guard masked(bytes, prefix: commonPrefix) ==
                masked(other.bytes, prefix: commonPrefix) else {
            return nil
        }
        return prefix >= other.prefix ? canonical : other.canonical
    }

    private func masked(_ value: [UInt8], prefix: Int) -> [UInt8] {
        var result = value
        for bit in prefix..<(value.count * 8) {
            result[bit / 8] &= ~(1 << (7 - bit % 8))
        }
        return result
    }
}
