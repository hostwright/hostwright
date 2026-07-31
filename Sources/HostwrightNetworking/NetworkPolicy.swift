import CryptoKit
import Darwin
import Foundation

public enum HostwrightNetworkPolicyProtocol:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case tcp
    case udp
}

public enum HostwrightNetworkPolicyDirection:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case ingress
    case egress
}

/// An allow rule. Every declared selector must match; omitted selectors are
/// unconstrained. A policy's presence changes both directions to default deny.
public struct HostwrightNetworkPolicyRule:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let maximumRulesPerDirection = 256
    public static let maximumIdentityUTF8Bytes = 512

    public var project: String?
    public var service: String?
    public var identity: String?
    public var protocolName: HostwrightNetworkPolicyProtocol?
    public var address: String?
    public var port: Int?
    public var dns: String?

    public init(
        project: String? = nil,
        service: String? = nil,
        identity: String? = nil,
        protocolName: HostwrightNetworkPolicyProtocol? = nil,
        address: String? = nil,
        port: Int? = nil,
        dns: String? = nil
    ) {
        self.project = project
        self.service = service
        self.identity = identity
        self.protocolName = protocolName
        self.address = address
        self.port = port
        self.dns = dns
    }

    public var isEmpty: Bool {
        project == nil &&
            service == nil &&
            identity == nil &&
            protocolName == nil &&
            address == nil &&
            port == nil &&
            dns == nil
    }

    public var canonicalKey: String {
        [
            project ?? "",
            service ?? "",
            identity ?? "",
            protocolName?.rawValue ?? "",
            address ?? "",
            port.map(String.init) ?? "",
            dns ?? ""
        ].joined(separator: "\u{1f}")
    }
}

public struct HostwrightServiceNetworkPolicy:
    Codable,
    Equatable,
    Sendable
{
    public var ingress: [HostwrightNetworkPolicyRule]
    public var egress: [HostwrightNetworkPolicyRule]

    public init(
        ingress: [HostwrightNetworkPolicyRule] = [],
        egress: [HostwrightNetworkPolicyRule] = []
    ) {
        self.ingress = ingress.sorted { $0.canonicalKey < $1.canonicalKey }
        self.egress = egress.sorted { $0.canonicalKey < $1.canonicalKey }
    }
}

public enum HostwrightNetworkPolicyValidation {
    public static func issue(
        in policy: HostwrightServiceNetworkPolicy
    ) -> String? {
        if policy.ingress.count >
            HostwrightNetworkPolicyRule.maximumRulesPerDirection ||
            policy.egress.count >
            HostwrightNetworkPolicyRule.maximumRulesPerDirection {
            return
                "networkPolicy permits at most \(HostwrightNetworkPolicyRule.maximumRulesPerDirection) rules per direction."
        }
        for (direction, rules) in [
            (HostwrightNetworkPolicyDirection.ingress, policy.ingress),
            (.egress, policy.egress)
        ] {
            var identities = Set<String>()
            for rule in rules {
                if let issue = issue(in: rule) {
                    return "\(direction.rawValue) \(issue)"
                }
                guard identities.insert(rule.canonicalKey).inserted else {
                    return "\(direction.rawValue) rules must not contain duplicates."
                }
            }
        }
        return nil
    }

    public static func issue(
        in rule: HostwrightNetworkPolicyRule
    ) -> String? {
        if rule.isEmpty {
            return "rules must declare at least one exact selector."
        }
        if let project = rule.project,
           !HostwrightNetworkIdentity.isValidManifestName(project) {
            return "project selectors must be lowercase DNS-like names."
        }
        if let service = rule.service,
           !HostwrightNetworkIdentity.isValidManifestName(service) {
            return "service selectors must be lowercase DNS-like names."
        }
        if let identity = rule.identity,
           !isValidIdentity(identity) {
            return "identity selectors must be bounded printable exact identities."
        }
        if let address = rule.address,
           NetworkExposurePolicyValidation.canonicalCIDR(address) != address {
            return "address selectors must be canonical IPv4 or IPv6 CIDRs."
        }
        if let port = rule.port, !(1...65_535).contains(port) {
            return "ports must be between 1 and 65535."
        }
        if rule.port != nil, rule.protocolName == nil {
            return "a port selector requires an exact protocol."
        }
        if let dns = rule.dns,
           !HostwrightHostAccessPolicy.isValidHostname(dns) {
            return "DNS selectors must be lowercase exact hostnames."
        }
        return nil
    }

    private static func isValidIdentity(_ value: String) -> Bool {
        !value.isEmpty &&
            value.utf8.count <=
                HostwrightNetworkPolicyRule.maximumIdentityUTF8Bytes &&
            value.unicodeScalars.allSatisfy {
                !$0.properties.isWhitespace &&
                    !CharacterSet.controlCharacters.contains($0)
            }
    }
}

public enum NetworkPolicyDefaultAction:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case allowSameProject
    case deny
}

public struct CompiledNetworkPolicyRule:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let serviceName: String
    public let serviceResourceUUID: String
    public let direction: HostwrightNetworkPolicyDirection
    public let rule: HostwrightNetworkPolicyRule

    public init(
        serviceName: String,
        serviceResourceUUID: String,
        direction: HostwrightNetworkPolicyDirection,
        rule: HostwrightNetworkPolicyRule
    ) {
        self.serviceName = serviceName
        self.serviceResourceUUID = serviceResourceUUID
        self.direction = direction
        self.rule = rule
    }

    public var canonicalKey: String {
        [
            serviceName,
            serviceResourceUUID,
            direction.rawValue,
            rule.canonicalKey
        ].joined(separator: "\u{1e}")
    }
}

public struct NetworkPolicyServicePlan:
    Codable,
    Equatable,
    Sendable
{
    public let serviceName: String
    public let serviceResourceUUID: String
    public let ingressDefault: NetworkPolicyDefaultAction
    public let egressDefault: NetworkPolicyDefaultAction
    public let rules: [CompiledNetworkPolicyRule]

    public init(
        serviceName: String,
        serviceResourceUUID: String,
        policy: HostwrightServiceNetworkPolicy?
    ) throws {
        if let policy, let issue = HostwrightNetworkPolicyValidation.issue(
            in: policy
        ) {
            throw NetworkPolicyCompilerError.invalidPolicy(
                service: serviceName,
                reason: issue
            )
        }
        self.serviceName = serviceName
        self.serviceResourceUUID = serviceResourceUUID
        ingressDefault = policy == nil ? .allowSameProject : .deny
        egressDefault = policy == nil ? .allowSameProject : .deny
        rules = (
            (policy?.ingress ?? []).map {
                CompiledNetworkPolicyRule(
                    serviceName: serviceName,
                    serviceResourceUUID: serviceResourceUUID,
                    direction: .ingress,
                    rule: $0
                )
            } +
                (policy?.egress ?? []).map {
                    CompiledNetworkPolicyRule(
                        serviceName: serviceName,
                        serviceResourceUUID: serviceResourceUUID,
                        direction: .egress,
                        rule: $0
                    )
                }
        ).sorted { $0.canonicalKey < $1.canonicalKey }
    }
}

public struct NetworkPolicyPlan:
    Codable,
    Equatable,
    Sendable
{
    public let projectName: String
    public let projectUUID: String
    public let generation: Int
    public let services: [NetworkPolicyServicePlan]
    public let sha256: String

    public init(
        projectName: String,
        projectUUID: String,
        generation: Int,
        services: [NetworkPolicyServicePlan]
    ) throws {
        guard generation > 0 else {
            throw NetworkPolicyCompilerError.invalidGeneration
        }
        guard HostwrightNetworkIdentity.isValidManifestName(projectName),
              Self.isCanonicalUUID(projectUUID) else {
            throw NetworkPolicyCompilerError.invalidProjectIdentity
        }
        let serviceNames = services.map(\.serviceName)
        guard Set(serviceNames).count == serviceNames.count else {
            throw NetworkPolicyCompilerError.duplicateService(
                serviceNames.sorted().first { name in
                    serviceNames.filter { $0 == name }.count > 1
                } ?? ""
            )
        }
        for service in services {
            guard HostwrightNetworkIdentity.isValidManifestName(
                service.serviceName
            ),
            Self.isCanonicalUUID(service.serviceResourceUUID),
            service.ingressDefault == service.egressDefault,
            service.ingressDefault != .allowSameProject ||
                service.rules.isEmpty,
            service.rules == service.rules.sorted(by: {
                $0.canonicalKey < $1.canonicalKey
            }),
            service.rules.allSatisfy({
                $0.serviceName == service.serviceName &&
                    $0.serviceResourceUUID ==
                    service.serviceResourceUUID &&
                    HostwrightNetworkPolicyValidation.issue(
                        in: $0.rule
                    ) == nil
            }),
            Set(service.rules.map(\.canonicalKey)).count ==
                service.rules.count else {
                throw NetworkPolicyCompilerError.invalidServiceIdentity(
                    service.serviceName
                )
            }
        }
        self.projectName = projectName
        self.projectUUID = projectUUID
        self.generation = generation
        self.services = services.sorted { $0.serviceName < $1.serviceName }
        let payload = NetworkPolicyDigestPayload(
            projectName: projectName,
            projectUUID: projectUUID,
            generation: generation,
            services: self.services
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        sha256 = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case projectName
        case projectUUID
        case generation
        case services
        case sha256
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let expectedSHA256 = try values.decode(
            String.self,
            forKey: .sha256
        )
        let decoded = try Self(
            projectName: values.decode(
                String.self,
                forKey: .projectName
            ),
            projectUUID: values.decode(
                String.self,
                forKey: .projectUUID
            ),
            generation: values.decode(Int.self, forKey: .generation),
            services: values.decode(
                [NetworkPolicyServicePlan].self,
                forKey: .services
            )
        )
        guard decoded.sha256 == expectedSHA256 else {
            throw NetworkPolicyCompilerError.invalidDigest
        }
        self = decoded
    }

    public var rules: [CompiledNetworkPolicyRule] {
        services.flatMap(\.rules)
    }

    public var dnsRules: [CompiledNetworkPolicyRule] {
        rules.filter { $0.rule.dns != nil }
    }

    public var ingressRules: [CompiledNetworkPolicyRule] {
        rules.filter { $0.direction == .ingress }
    }

    public var forwardingRules: [CompiledNetworkPolicyRule] {
        rules.filter { $0.rule.protocolName != nil || $0.rule.port != nil }
    }

    public var providerRules: [CompiledNetworkPolicyRule] {
        rules
    }

    public var tunnelRules: [CompiledNetworkPolicyRule] {
        rules.filter {
            guard let project = $0.rule.project else { return false }
            return project != projectName && project != projectUUID
        }
    }

    public func allows(_ flow: NetworkPolicyFlow) -> Bool {
        let governedService =
            flow.direction == .ingress
            ? flow.destinationService
            : flow.sourceService
        guard let service = services.first(where: {
            $0.serviceName == governedService
        }) else {
            return false
        }
        let defaultAction =
            flow.direction == .ingress
            ? service.ingressDefault
            : service.egressDefault
        let directionalRules = service.rules.filter {
            $0.direction == flow.direction
        }
        if directionalRules.contains(where: {
            matches($0.rule, flow: flow)
        }) {
            return true
        }
        return defaultAction == .allowSameProject &&
            isCurrentProject(flow.sourceProject) &&
            isCurrentProject(flow.destinationProject)
    }

    private func matches(
        _ rule: HostwrightNetworkPolicyRule,
        flow: NetworkPolicyFlow
    ) -> Bool {
        let peerProject =
            flow.direction == .ingress
            ? flow.sourceProject
            : flow.destinationProject
        let peerService =
            flow.direction == .ingress
            ? flow.sourceService
            : flow.destinationService
        let peerIdentity =
            flow.direction == .ingress
            ? flow.sourceIdentity
            : flow.destinationIdentity
        return (rule.project == nil ||
            rule.project == peerProject ||
            (
                (rule.project == projectName ||
                    rule.project == projectUUID) &&
                    isCurrentProject(peerProject)
            )) &&
            (rule.service == nil || rule.service == peerService) &&
            (rule.identity == nil || rule.identity == peerIdentity) &&
            (rule.protocolName == nil ||
                rule.protocolName == flow.protocolName) &&
            (
                rule.address == nil ||
                    (
                        flow.address.map {
                            Self.cidr(rule.address!, contains: $0)
                        } ?? false
                    )
            ) &&
            (rule.port == nil || rule.port == flow.port) &&
            (rule.dns == nil || rule.dns == flow.dns)
    }

    private func isCurrentProject(_ value: String) -> Bool {
        value == projectName || value == projectUUID
    }

    private static func cidr(
        _ cidr: String,
        contains address: String
    ) -> Bool {
        let components = cidr.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              let prefix = Int(components[1]) else {
            return false
        }
        for (family, byteCount, maximumPrefix) in [
            (AF_INET, 4, 32),
            (AF_INET6, 16, 128)
        ] {
            guard prefix <= maximumPrefix else { continue }
            var networkBytes = [UInt8](repeating: 0, count: byteCount)
            var addressBytes = [UInt8](repeating: 0, count: byteCount)
            let networkParsed = networkBytes.withUnsafeMutableBytes {
                inet_pton(
                    family,
                    String(components[0]),
                    $0.baseAddress
                )
            }
            let addressParsed = addressBytes.withUnsafeMutableBytes {
                inet_pton(family, address, $0.baseAddress)
            }
            guard networkParsed == 1, addressParsed == 1 else { continue }
            let fullBytes = prefix / 8
            let remainingBits = prefix % 8
            guard networkBytes.prefix(fullBytes) ==
                    addressBytes.prefix(fullBytes) else {
                return false
            }
            if remainingBits == 0 { return true }
            let mask = UInt8(0xff << (8 - remainingBits))
            return networkBytes[fullBytes] & mask ==
                addressBytes[fullBytes] & mask
        }
        return false
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}

public struct NetworkPolicyFlow:
    Equatable,
    Sendable
{
    public let direction: HostwrightNetworkPolicyDirection
    public let sourceProject: String
    public let sourceService: String
    public let sourceIdentity: String?
    public let destinationProject: String
    public let destinationService: String
    public let destinationIdentity: String?
    public let protocolName: HostwrightNetworkPolicyProtocol
    public let address: String?
    public let port: Int?
    public let dns: String?

    public init(
        direction: HostwrightNetworkPolicyDirection,
        sourceProject: String,
        sourceService: String,
        sourceIdentity: String? = nil,
        destinationProject: String,
        destinationService: String,
        destinationIdentity: String? = nil,
        protocolName: HostwrightNetworkPolicyProtocol,
        address: String? = nil,
        port: Int? = nil,
        dns: String? = nil
    ) {
        self.direction = direction
        self.sourceProject = sourceProject
        self.sourceService = sourceService
        self.sourceIdentity = sourceIdentity
        self.destinationProject = destinationProject
        self.destinationService = destinationService
        self.destinationIdentity = destinationIdentity
        self.protocolName = protocolName
        self.address = address
        self.port = port
        self.dns = dns
    }
}

public enum NetworkPolicyCompilerError: Error, Equatable, Sendable {
    case invalidGeneration
    case invalidProjectIdentity
    case invalidServiceIdentity(String)
    case invalidDigest
    case duplicateService(String)
    case invalidPolicy(service: String, reason: String)
}

public enum NetworkPolicyCompiler {
    public static func compile(
        projectName: String,
        projectUUID: String,
        generation: Int,
        services: [(
            name: String,
            resourceUUID: String,
            policy: HostwrightServiceNetworkPolicy?
        )]
    ) throws -> NetworkPolicyPlan {
        let names = services.map(\.name)
        guard Set(names).count == names.count else {
            throw NetworkPolicyCompilerError.duplicateService(
                names.sorted().first { name in
                    names.filter { $0 == name }.count > 1
                } ?? ""
            )
        }
        return try NetworkPolicyPlan(
            projectName: projectName,
            projectUUID: projectUUID,
            generation: generation,
            services: try services.map {
                try NetworkPolicyServicePlan(
                    serviceName: $0.name,
                    serviceResourceUUID: $0.resourceUUID,
                    policy: $0.policy
                )
            }
        )
    }
}

private struct NetworkPolicyDigestPayload: Encodable {
    let projectName: String
    let projectUUID: String
    let generation: Int
    let services: [NetworkPolicyServicePlan]
}
