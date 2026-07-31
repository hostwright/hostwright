import CryptoKit
import Foundation
import HostwrightNetworking

public enum ContainerizationGuestNetworkPolicyError:
    Error,
    Equatable,
    Sendable
{
    case invalidSchema
    case invalidGeneration
    case invalidIdentity
    case invalidRule
    case tooManyRules
    case invalidDNSServer
    case invalidDigest
}

public struct ContainerizationGuestNetworkPolicyRule:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let address: String
    public let port: Int?
    public let protocolName: HostwrightNetworkPolicyProtocol

    public init(
        address: String,
        port: Int? = nil,
        protocolName: HostwrightNetworkPolicyProtocol
    ) throws {
        if NetworkExposurePolicyValidation.canonicalCIDR(address) != address {
            throw ContainerizationGuestNetworkPolicyError.invalidRule
        }
        if let port, !(1...65_535).contains(port) {
            throw ContainerizationGuestNetworkPolicyError.invalidRule
        }
        self.address = address
        self.port = port
        self.protocolName = protocolName
    }

    public var canonicalKey: String {
        [
            address,
            port.map(String.init) ?? "",
            protocolName.rawValue
        ].joined(separator: "\u{1f}")
    }
}

public struct ContainerizationGuestNetworkPolicy:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion = 1
    public static let maximumRulesPerDirection = 4_096
    public static let maximumEncodedBytes = 1 * 1_024 * 1_024

    public let schemaVersion: Int
    public let generation: Int
    public let projectUUID: String
    public let serviceResourceUUID: String
    public let ingressDefault: NetworkPolicyDefaultAction
    public let egressDefault: NetworkPolicyDefaultAction
    public let dnsServers: [String]
    public let ingress: [ContainerizationGuestNetworkPolicyRule]
    public let egress: [ContainerizationGuestNetworkPolicyRule]
    public let sha256: String

    public init(
        generation: Int,
        projectUUID: String,
        serviceResourceUUID: String,
        ingressDefault: NetworkPolicyDefaultAction,
        egressDefault: NetworkPolicyDefaultAction,
        dnsServers: [String],
        ingress: [ContainerizationGuestNetworkPolicyRule],
        egress: [ContainerizationGuestNetworkPolicyRule]
    ) throws {
        guard generation > 0 else {
            throw ContainerizationGuestNetworkPolicyError.invalidGeneration
        }
        guard Self.isCanonicalUUID(projectUUID),
              Self.isCanonicalUUID(serviceResourceUUID),
              projectUUID != serviceResourceUUID else {
            throw ContainerizationGuestNetworkPolicyError.invalidIdentity
        }
        guard ingress.count <= Self.maximumRulesPerDirection,
              egress.count <= Self.maximumRulesPerDirection else {
            throw ContainerizationGuestNetworkPolicyError.tooManyRules
        }
        let orderedDNS = Array(Set(dnsServers)).sorted()
        guard orderedDNS.allSatisfy(Self.isCanonicalIPAddress) else {
            throw ContainerizationGuestNetworkPolicyError.invalidDNSServer
        }
        let orderedIngress = ingress.sorted {
            $0.canonicalKey < $1.canonicalKey
        }
        let orderedEgress = egress.sorted {
            $0.canonicalKey < $1.canonicalKey
        }
        guard Set(orderedIngress).count == orderedIngress.count,
              Set(orderedEgress).count == orderedEgress.count else {
            throw ContainerizationGuestNetworkPolicyError.invalidRule
        }

        schemaVersion = Self.currentSchemaVersion
        self.generation = generation
        self.projectUUID = projectUUID
        self.serviceResourceUUID = serviceResourceUUID
        self.ingressDefault = ingressDefault
        self.egressDefault = egressDefault
        self.dnsServers = orderedDNS
        self.ingress = orderedIngress
        self.egress = orderedEgress
        sha256 = Self.digest(
            generation: generation,
            projectUUID: projectUUID,
            serviceResourceUUID: serviceResourceUUID,
            ingressDefault: ingressDefault,
            egressDefault: egressDefault,
            dnsServers: orderedDNS,
            ingress: orderedIngress,
            egress: orderedEgress
        )
    }

    private enum CodingKeys: String, CodingKey {
        case dnsServers
        case egress
        case egressDefault
        case generation
        case ingress
        case ingressDefault
        case projectUUID
        case schemaVersion
        case serviceResourceUUID
        case sha256
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) ==
                Self.currentSchemaVersion else {
            throw ContainerizationGuestNetworkPolicyError.invalidSchema
        }
        let expectedSHA256 = try values.decode(
            String.self,
            forKey: .sha256
        )
        let decoded = try Self(
            generation: values.decode(Int.self, forKey: .generation),
            projectUUID: values.decode(String.self, forKey: .projectUUID),
            serviceResourceUUID: values.decode(
                String.self,
                forKey: .serviceResourceUUID
            ),
            ingressDefault: values.decode(
                NetworkPolicyDefaultAction.self,
                forKey: .ingressDefault
            ),
            egressDefault: values.decode(
                NetworkPolicyDefaultAction.self,
                forKey: .egressDefault
            ),
            dnsServers: values.decode(
                [String].self,
                forKey: .dnsServers
            ),
            ingress: values.decode(
                [ContainerizationGuestNetworkPolicyRule].self,
                forKey: .ingress
            ),
            egress: values.decode(
                [ContainerizationGuestNetworkPolicyRule].self,
                forKey: .egress
            )
        )
        guard decoded.sha256 == expectedSHA256 else {
            throw ContainerizationGuestNetworkPolicyError.invalidDigest
        }
        self = decoded
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else {
            throw ContainerizationGuestNetworkPolicyError.tooManyRules
        }
        return data
    }

    private static func digest(
        generation: Int,
        projectUUID: String,
        serviceResourceUUID: String,
        ingressDefault: NetworkPolicyDefaultAction,
        egressDefault: NetworkPolicyDefaultAction,
        dnsServers: [String],
        ingress: [ContainerizationGuestNetworkPolicyRule],
        egress: [ContainerizationGuestNetworkPolicyRule]
    ) -> String {
        var lines = [
            "hostwright-netfilter-v1",
            "generation=\(generation)",
            "projectUUID=\(projectUUID)",
            "serviceResourceUUID=\(serviceResourceUUID)",
            "ingressDefault=\(ingressDefault.rawValue)",
            "egressDefault=\(egressDefault.rawValue)"
        ]
        lines += dnsServers.map { "dns=\($0)" }
        lines += ingress.map {
            "ingress=\($0.address)|\($0.protocolName.rawValue)|\($0.port.map(String.init) ?? "*")"
        }
        lines += egress.map {
            "egress=\($0.address)|\($0.protocolName.rawValue)|\($0.port.map(String.init) ?? "*")"
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isCanonicalIPAddress(_ value: String) -> Bool {
        let suffix = value.contains(":") ? "/128" : "/32"
        guard let canonical =
            NetworkExposurePolicyValidation.canonicalCIDR(value + suffix)
        else {
            return false
        }
        return canonical.dropLast(suffix.count) == value
    }
}

public enum ContainerizationGuestNetworkPolicyLoaderOperation:
    String,
    Codable,
    Equatable,
    Sendable
{
    case apply
    case verify
    case remove
}

public struct ContainerizationGuestNetworkPolicyLoaderRule:
    Codable,
    Equatable,
    Sendable
{
    public let cidr: String
    public let `protocol`: String
    public let destinationPort: Int?
}

public struct ContainerizationGuestNetworkPolicyLoaderRequest:
    Codable,
    Equatable,
    Sendable
{
    public static let schemaVersion = 1

    public let schema: Int
    public let operation: ContainerizationGuestNetworkPolicyLoaderOperation
    public let policyDigest: String
    public let generation: Int
    public let projectUUID: String
    public let serviceResourceUUID: String
    public let ingressDefault: NetworkPolicyDefaultAction
    public let egressDefault: NetworkPolicyDefaultAction
    public let ingress: [ContainerizationGuestNetworkPolicyLoaderRule]
    public let egress: [ContainerizationGuestNetworkPolicyLoaderRule]
    public let dnsServers: [String]
    public let targetUID: UInt32?
    public let targetGID: UInt32?
    public let workingDirectory: String?

    public init(
        operation: ContainerizationGuestNetworkPolicyLoaderOperation,
        policy: ContainerizationGuestNetworkPolicy,
        targetUID: UInt32? = nil,
        targetGID: UInt32? = nil,
        workingDirectory: String? = nil
    ) {
        schema = Self.schemaVersion
        self.operation = operation
        policyDigest = policy.sha256
        generation = policy.generation
        projectUUID = policy.projectUUID
        serviceResourceUUID = policy.serviceResourceUUID
        ingressDefault = policy.ingressDefault
        egressDefault = policy.egressDefault
        ingress = policy.ingress.map(Self.loaderRule)
        egress = policy.egress.map(Self.loaderRule)
        dnsServers = policy.dnsServers
        if operation == .apply {
            self.targetUID = targetUID
            self.targetGID = targetGID
            self.workingDirectory = workingDirectory
        } else {
            self.targetUID = nil
            self.targetGID = nil
            self.workingDirectory = nil
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <=
                ContainerizationGuestNetworkPolicy.maximumEncodedBytes else {
            throw ContainerizationGuestNetworkPolicyError.tooManyRules
        }
        return data
    }

    private static func loaderRule(
        _ rule: ContainerizationGuestNetworkPolicyRule
    ) -> ContainerizationGuestNetworkPolicyLoaderRule {
        ContainerizationGuestNetworkPolicyLoaderRule(
            cidr: rule.address,
            protocol: rule.protocolName.rawValue,
            destinationPort: rule.port
        )
    }
}
