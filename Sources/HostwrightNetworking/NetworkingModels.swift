import Foundation
import HostwrightCore

public enum NetworkExposureScope:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case project
    case localhost
    case lan
    case tunnel
    case `public`

    public var isAllowedInFirstRelease: Bool {
        switch self {
        case .project, .localhost:
            return true
        case .lan, .tunnel, .public:
            return false
        }
    }
}

public enum NetworkExposureAuthentication:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case none
    case tls
    case mutualTLS = "mtls"
    case authenticatedTunnel = "authenticated-tunnel"
}

public enum HostwrightIdentityRole: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case workload
    case ingress
    case tunnel
    case node
}

/// The exact localhost mTLS identity carried in a certificate URI SAN.
public struct HostwrightMutualTLSIdentity: Codable, Equatable, Hashable, Sendable {
    public static let trustDomain = "hostwright.internal"

    public let projectUUID: String
    public let resourceUUID: String
    public let role: HostwrightIdentityRole
    public let generation: Int
    public let uriSAN: String

    public init(projectUUID: String, resourceUUID: String, role: HostwrightIdentityRole, generation: Int) throws {
        guard Self.isCanonicalUUID(projectUUID), Self.isCanonicalUUID(resourceUUID), generation > 0 else {
            throw HostwrightMutualTLSIdentityError.invalidIdentity
        }
        self.projectUUID = projectUUID
        self.resourceUUID = resourceUUID
        self.role = role
        self.generation = generation
        self.uriSAN = Self.uriSAN(projectUUID: projectUUID, resourceUUID: resourceUUID, role: role, generation: generation)
    }

    public static func uriSAN(projectUUID: String, resourceUUID: String, role: HostwrightIdentityRole, generation: Int) -> String {
        "spiffe://\(trustDomain)/projects/\(projectUUID)/resources/\(resourceUUID)/roles/\(role.rawValue)/generations/\(generation)"
    }

    public func isExactCanonicalValue() -> Bool {
        Self.isCanonicalUUID(projectUUID) && Self.isCanonicalUUID(resourceUUID) && generation > 0 && uriSAN == Self.uriSAN(projectUUID: projectUUID, resourceUUID: resourceUUID, role: role, generation: generation)
    }

    private enum CodingKeys: String, CodingKey { case projectUUID, resourceUUID, role, generation, uriSAN }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let projectUUID = try values.decode(String.self, forKey: .projectUUID)
        let resourceUUID = try values.decode(String.self, forKey: .resourceUUID)
        let role = try values.decode(HostwrightIdentityRole.self, forKey: .role)
        let generation = try values.decode(Int.self, forKey: .generation)
        let identity = try Self(projectUUID: projectUUID, resourceUUID: resourceUUID, role: role, generation: generation)
        guard try values.decode(String.self, forKey: .uriSAN) == identity.uriSAN else {
            throw HostwrightMutualTLSIdentityError.invalidIdentity
        }
        self = identity
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}

public enum HostwrightMutualTLSIdentityError: Error, Equatable, Sendable { case invalidIdentity }

public struct HostwrightIngressPeerSelector: Codable, Equatable, Hashable, Sendable {
    public let service: String
    public let role: HostwrightIdentityRole

    public init(service: String, role: HostwrightIdentityRole) {
        self.service = service
        self.role = role
    }
}

public enum HostwrightNetworkClass:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case privateLAN = "private"
    case vpn
    case publicInternet = "public"
}

public struct HostwrightPortExposurePolicy:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let maximumInterfaceSelectors = 8
    public static let maximumAllowedCIDRs = 32

    public let scope: NetworkExposureScope
    public let interfaces: [String]
    public let networkClasses: [HostwrightNetworkClass]
    public let allowedCIDRs: [String]
    public let authentication: NetworkExposureAuthentication

    public init(
        scope: NetworkExposureScope = .localhost,
        interfaces: [String] = [],
        networkClasses: [HostwrightNetworkClass] = [],
        allowedCIDRs: [String] = [],
        authentication: NetworkExposureAuthentication = .none
    ) {
        self.scope = scope
        self.interfaces = interfaces.sorted()
        self.networkClasses = networkClasses.sorted {
            $0.rawValue < $1.rawValue
        }
        self.allowedCIDRs = allowedCIDRs.sorted()
        self.authentication = authentication
    }

    public static let localhost = Self()

    public var isDefaultLocalhost: Bool {
        self == .localhost
    }
}

public enum NetworkExposurePolicyValidation {
    public static func isValidInterfaceSelector(
        _ value: String
    ) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= Int(IFNAMSIZ - 1),
              value != ".",
              value != "..",
              !value.contains("*") else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(
                charactersIn:
                    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
            ).contains($0)
        }
    }

    public static func canonicalCIDR(_ value: String) -> String? {
        let components = value.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              let prefix = Int(components[1]),
              String(prefix) == components[1] else {
            return nil
        }
        let address = String(components[0])
        if let bytes = addressBytes(address, family: AF_INET),
           (0...32).contains(prefix),
           hasZeroHostBits(bytes, prefix: prefix) {
            return "\(render(bytes, family: AF_INET))/\(prefix)"
        }
        if let bytes = addressBytes(address, family: AF_INET6),
           (0...128).contains(prefix),
           hasZeroHostBits(bytes, prefix: prefix) {
            return "\(render(bytes, family: AF_INET6))/\(prefix)"
        }
        return nil
    }

    public static func isSemanticallyValid(
        _ policy: HostwrightPortExposurePolicy,
        bindAddress: String
    ) -> Bool {
        guard policy.interfaces.count <=
                HostwrightPortExposurePolicy.maximumInterfaceSelectors,
              policy.allowedCIDRs.count <=
                HostwrightPortExposurePolicy.maximumAllowedCIDRs,
              Set(policy.interfaces).count == policy.interfaces.count,
              Set(policy.networkClasses).count ==
                policy.networkClasses.count,
              Set(policy.allowedCIDRs).count ==
                policy.allowedCIDRs.count,
              policy.interfaces.allSatisfy(isValidInterfaceSelector),
              policy.allowedCIDRs.allSatisfy({
                canonicalCIDR($0) == $0
              }) else {
            return false
        }
        let loopback = NetworkBindAddressPolicy.isLocalhost(bindAddress)
        let exactNonLoopback = !loopback &&
            !NetworkBindAddressPolicy.isBroadBindAddress(bindAddress)
        switch policy.scope {
        case .project:
            return false
        case .localhost:
            return loopback &&
                policy.interfaces.isEmpty &&
                policy.networkClasses.isEmpty &&
                policy.allowedCIDRs.isEmpty &&
                (
                    policy.authentication == .none ||
                        policy.authentication == .tls ||
                        policy.authentication == .mutualTLS
                )
        case .lan:
            return exactNonLoopback &&
                !policy.interfaces.isEmpty &&
                !policy.networkClasses.isEmpty &&
                Set(policy.networkClasses)
                    .isSubset(of: [.privateLAN, .vpn]) &&
                !policy.allowedCIDRs.isEmpty &&
                policy.authentication == .tls
        case .tunnel:
            return loopback &&
                policy.interfaces.isEmpty &&
                policy.networkClasses.isEmpty &&
                policy.authentication == .authenticatedTunnel
        case .public:
            return exactNonLoopback &&
                !policy.interfaces.isEmpty &&
                policy.networkClasses.contains(.publicInternet) &&
                !policy.allowedCIDRs.isEmpty &&
                (
                    policy.authentication == .mutualTLS ||
                        policy.authentication ==
                            .authenticatedTunnel
                )
        }
    }

    private static func addressBytes(
        _ value: String,
        family: Int32
    ) -> [UInt8]? {
        let count = family == AF_INET ? 4 : 16
        var bytes = [UInt8](repeating: 0, count: count)
        let parsed = value.withCString { source in
            bytes.withUnsafeMutableBytes {
                inet_pton(family, source, $0.baseAddress)
            }
        }
        return parsed == 1 ? bytes : nil
    }

    private static func hasZeroHostBits(
        _ bytes: [UInt8],
        prefix: Int
    ) -> Bool {
        for bit in prefix..<(bytes.count * 8) {
            let byte = bit / 8
            let shift = 7 - (bit % 8)
            if bytes[byte] & UInt8(1 << shift) != 0 {
                return false
            }
        }
        return true
    }

    private static func render(
        _ bytes: [UInt8],
        family: Int32
    ) -> String {
        var output = [CChar](
            repeating: 0,
            count: family == AF_INET
                ? Int(INET_ADDRSTRLEN)
                : Int(INET6_ADDRSTRLEN)
        )
        _ = bytes.withUnsafeBytes {
            inet_ntop(
                family,
                $0.baseAddress,
                &output,
                socklen_t(output.count)
            )
        }
        return String(
            decoding: output.prefix { $0 != 0 }.map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )
    }
}

public enum NetworkExposureEnvironmentIssue:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case policyInvalid
    case localNetworkPermissionNotGranted
    case bindAddressUnavailable
    case interfaceNotAllowed
    case networkClassNotAllowed
}

public enum NetworkExposureEnvironmentWarning:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case privateRelayActive
    case privateRelayNotObservable
    case vpnRouteActive
}

public struct NetworkExposureEnvironmentEvaluation:
    Codable,
    Equatable,
    Sendable
{
    public let selectedAddress: NetworkHostInterfaceAddress?
    public let issues: [NetworkExposureEnvironmentIssue]
    public let warnings: [NetworkExposureEnvironmentWarning]
    public let environmentFingerprint: String

    public init(
        selectedAddress: NetworkHostInterfaceAddress?,
        issues: [NetworkExposureEnvironmentIssue],
        warnings: [NetworkExposureEnvironmentWarning],
        environmentFingerprint: String
    ) {
        self.selectedAddress = selectedAddress
        self.issues = Array(Set(issues)).sorted {
            $0.rawValue < $1.rawValue
        }
        self.warnings = Array(Set(warnings)).sorted {
            $0.rawValue < $1.rawValue
        }
        self.environmentFingerprint = environmentFingerprint
    }

    public var isAllowed: Bool {
        issues.isEmpty
    }
}

public enum NetworkExposureTransitionAction:
    String,
    Codable,
    Equatable,
    Sendable
{
    case activate
    case keep
    case rebindAtomically
    case drainAndStop
}

public enum NetworkExposureEnvironmentEvaluator {
    public static func evaluate(
        policy: HostwrightPortExposurePolicy,
        bindAddress: String,
        environment: NetworkHostEnvironmentSnapshot
    ) -> NetworkExposureEnvironmentEvaluation {
        var issues: [NetworkExposureEnvironmentIssue] = []
        var warnings: [NetworkExposureEnvironmentWarning] = []
        let selected: NetworkHostInterfaceAddress?

        guard NetworkExposurePolicyValidation.isSemanticallyValid(
            policy,
            bindAddress: bindAddress
        ) else {
            return NetworkExposureEnvironmentEvaluation(
                selectedAddress: nil,
                issues: [.policyInvalid],
                warnings: [],
                environmentFingerprint: environment.stableFingerprint
            )
        }

        switch policy.scope {
        case .project:
            selected = nil
            issues.append(.bindAddressUnavailable)
        case .localhost, .tunnel:
            selected = nil
            if !NetworkBindAddressPolicy.isLocalhost(bindAddress) {
                issues.append(.bindAddressUnavailable)
            }
        case .lan, .public:
            if environment.localNetworkPermission != .granted {
                issues.append(.localNetworkPermissionNotGranted)
            }
            let exactAddress = environment.addresses.first {
                !$0.isLoopback && $0.address == bindAddress
            }
            selected = exactAddress
            if exactAddress == nil {
                issues.append(.bindAddressUnavailable)
            } else if let exactAddress {
                if !policy.interfaces.contains(
                    exactAddress.interfaceName
                ) {
                    issues.append(.interfaceNotAllowed)
                }
                if !policy.networkClasses.contains(
                    exactAddress.networkClass
                ) {
                    issues.append(.networkClassNotAllowed)
                }
            }
            switch environment.privateRelayState {
            case .active:
                warnings.append(.privateRelayActive)
            case .notObservable:
                warnings.append(.privateRelayNotObservable)
            case .inactive:
                break
            }
            if environment.vpnState == .active {
                warnings.append(.vpnRouteActive)
            }
        }

        return NetworkExposureEnvironmentEvaluation(
            selectedAddress: selected,
            issues: issues,
            warnings: warnings,
            environmentFingerprint: environment.stableFingerprint
        )
    }

    public static func transition(
        previous: NetworkExposureEnvironmentEvaluation?,
        current: NetworkExposureEnvironmentEvaluation
    ) -> NetworkExposureTransitionAction {
        guard current.isAllowed else {
            return .drainAndStop
        }
        guard let previous else {
            return .activate
        }
        guard previous.isAllowed else {
            return .activate
        }
        if previous.selectedAddress != current.selectedAddress ||
            previous.environmentFingerprint !=
                current.environmentFingerprint {
            return .rebindAtomically
        }
        return .keep
    }
}

public enum PortProtocol: String, Equatable, Sendable {
    case tcp
    case udp
}

public enum HostwrightNetworkDriver: String, Codable, Equatable, Sendable {
    case nat
    case hostOnly
}

public enum HostwrightNetworkAddressRequest: Codable, Equatable, Sendable {
    case auto
    case disabled
    case cidr(String)

    public init?(manifestValue: String) {
        switch manifestValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto":
            self = .auto
        case "disabled":
            self = .disabled
        case let value where !value.isEmpty:
            self = .cidr(value)
        default:
            return nil
        }
    }

    public var manifestValue: String {
        switch self {
        case .auto:
            return "auto"
        case .disabled:
            return "disabled"
        case .cidr(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let request = Self(manifestValue: value) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Network address request must be auto, disabled, or a CIDR."
                )
            )
        }
        self = request
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(manifestValue)
    }
}

public struct HostwrightNetworkDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var driver: HostwrightNetworkDriver
    public var ipv4: HostwrightNetworkAddressRequest
    public var ipv6: HostwrightNetworkAddressRequest

    public init(
        name: String,
        driver: HostwrightNetworkDriver = .nat,
        ipv4: HostwrightNetworkAddressRequest = .auto,
        ipv6: HostwrightNetworkAddressRequest = .auto
    ) {
        self.name = name
        self.driver = driver
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }
}

public struct HostwrightServiceNetworkAttachment: Codable, Equatable, Sendable {
    public static let maximumAliases = 64

    public var network: String
    public var aliases: [String]

    public init(network: String, aliases: [String] = []) {
        self.network = network
        self.aliases = aliases
    }
}

public enum HostwrightHostAccessProtocol:
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

public enum HostwrightHostAccessAddressClass:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case loopback
    case interface
}

public struct HostwrightHostAccessEndpoint:
    Codable,
    Equatable,
    Sendable
{
    public static let maximumEndpointsPerService = 64

    public var hostname: String
    public var protocolName: HostwrightHostAccessProtocol
    public var addressClass: HostwrightHostAccessAddressClass
    public var port: Int

    public init(
        hostname: String,
        protocolName: HostwrightHostAccessProtocol = .tcp,
        addressClass: HostwrightHostAccessAddressClass = .loopback,
        port: Int
    ) {
        self.hostname = hostname
        self.protocolName = protocolName
        self.addressClass = addressClass
        self.port = port
    }
}

public enum HostwrightHostAccessPolicy {
    public static let maximumHostnameUTF8Bytes = 253

    private static let reservedHostnames: Set<String> = [
        "instance-data",
        "localhost",
        "localhost.localdomain",
        "metadata",
        "metadata.aws.internal",
        "metadata.google.internal"
    ]

    public static func isValidHostname(_ value: String) -> Bool {
        guard value == value.lowercased(),
              !value.isEmpty,
              value.utf8.count <= maximumHostnameUTF8Bytes,
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains("*"),
              !reservedHostnames.contains(value),
              !isIPv4Literal(value),
              !value.contains(":") else {
            return false
        }
        return value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { HostwrightNetworkIdentity.isValidManifestName(String($0)) }
    }

    public static func endpointIdentity(
        _ endpoint: HostwrightHostAccessEndpoint
    ) -> String {
        "\(endpoint.hostname):\(endpoint.port)/\(endpoint.protocolName.rawValue)@\(endpoint.addressClass.rawValue)"
    }

    public static func canonicalPrecedes(
        _ lhs: HostwrightHostAccessEndpoint,
        _ rhs: HostwrightHostAccessEndpoint
    ) -> Bool {
        (
            lhs.hostname,
            lhs.protocolName.rawValue,
            lhs.port,
            lhs.addressClass.rawValue
        ) < (
            rhs.hostname,
            rhs.protocolName.rawValue,
            rhs.port,
            rhs.addressClass.rawValue
        )
    }

    private static func isIPv4Literal(_ value: String) -> Bool {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 4 else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty,
                  component.count <= 3,
                  component.allSatisfy(\.isNumber),
                  let octet = Int(component),
                  (0...255).contains(octet) else {
                return false
            }
            return component == "0" || component.first != "0"
        }
    }
}

public enum HostwrightIngressRouteProtocol:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case http
    case websocket
}

public struct HostwrightIngressRoute:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let maximumMethods = 8

    public var hostname: String
    public var pathPrefix: String
    public var methods: [String]
    public var protocolName: HostwrightIngressRouteProtocol
    public var targetService: String
    public var targetPort: Int

    public init(
        hostname: String,
        pathPrefix: String = "/",
        methods: [String] = ["GET"],
        protocolName: HostwrightIngressRouteProtocol = .http,
        targetService: String,
        targetPort: Int
    ) {
        self.hostname = hostname
        self.pathPrefix = pathPrefix
        self.methods = methods
        self.protocolName = protocolName
        self.targetService = targetService
        self.targetPort = targetPort
    }

    public static func canonicalPrecedes(
        _ lhs: Self,
        _ rhs: Self
    ) -> Bool {
        let lhsFields = [
            lhs.hostname,
            lhs.pathPrefix,
            lhs.protocolName.rawValue,
            lhs.methods.sorted().joined(separator: ","),
            lhs.targetService,
            String(format: "%05d", lhs.targetPort)
        ]
        let rhsFields = [
            rhs.hostname,
            rhs.pathPrefix,
            rhs.protocolName.rawValue,
            rhs.methods.sorted().joined(separator: ","),
            rhs.targetService,
            String(format: "%05d", rhs.targetPort)
        ]
        return lhsFields.lexicographicallyPrecedes(rhsFields)
    }
}

public struct HostwrightIngressListener:
    Codable,
    Equatable,
    Sendable
{
    public static let maximumListeners = 64
    public static let maximumRoutes = 256
    public static let maximumPeers = 256

    public var bindAddress: String
    public var port: Int
    public var exposure: HostwrightPortExposurePolicy
    public var certificate: String?
    public var peers: [HostwrightIngressPeerSelector]
    public var routes: [HostwrightIngressRoute]

    public init(
        bindAddress: String = "127.0.0.1",
        port: Int,
        exposure: HostwrightPortExposurePolicy = .localhost,
        certificate: String? = nil,
        peers: [HostwrightIngressPeerSelector] = [],
        routes: [HostwrightIngressRoute]
    ) {
        self.bindAddress = bindAddress
        self.port = port
        self.exposure = exposure
        self.certificate = certificate
        self.peers = peers.sorted { ($0.service, $0.role.rawValue) < ($1.service, $1.role.rawValue) }
        self.routes = routes
    }

    /// Compatibility overload for callers built against the pre-peer ingress contract.
    public init(
        bindAddress: String = "127.0.0.1",
        port: Int,
        exposure: HostwrightPortExposurePolicy = .localhost,
        certificate: String?,
        routes: [HostwrightIngressRoute]
    ) {
        self.init(
            bindAddress: bindAddress,
            port: port,
            exposure: exposure,
            certificate: certificate,
            peers: [],
            routes: routes
        )
    }

    public var certificateDNSNames: [String] {
        Array(Set(routes.map(\.hostname))).sorted()
    }
}

public enum HostwrightCertificateSourceKind:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case imported
    case localCA
    case provider
}

public enum HostwrightCertificateStatusPolicy:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case disabled
    case ifAvailable
    case required
}

public struct HostwrightCertificateDeclaration:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let maximumCertificates = 64
    public static let defaultRenewBeforeSeconds = 604_800
    public static let defaultValiditySeconds = 2_592_000

    public var source: HostwrightCertificateSourceKind
    public var identitySHA256: String?
    public var issuer: String?
    public var renewBeforeSeconds: Int
    public var validitySeconds: Int
    public var statusPolicy: HostwrightCertificateStatusPolicy

    public init(
        source: HostwrightCertificateSourceKind,
        identitySHA256: String? = nil,
        issuer: String? = nil,
        renewBeforeSeconds: Int = Self.defaultRenewBeforeSeconds,
        validitySeconds: Int = Self.defaultValiditySeconds,
        statusPolicy: HostwrightCertificateStatusPolicy = .ifAvailable
    ) {
        self.source = source
        self.identitySHA256 = identitySHA256
        self.issuer = issuer
        self.renewBeforeSeconds = renewBeforeSeconds
        self.validitySeconds = validitySeconds
        self.statusPolicy = statusPolicy
    }
}

public enum HostwrightNetworkIdentity {
    public static func resourceUUID(projectUUID: String, networkName: String) -> String {
        HostwrightResourceUUID.legacy(
            kind: "network",
            identifier: "\(projectUUID):\(networkName)"
        )
    }

    public static func runtimeName(projectUUID: String, networkName: String) -> String {
        let uuid = resourceUUID(projectUUID: projectUUID, networkName: networkName)
            .replacingOccurrences(of: "-", with: "")
        return "hw-\(uuid)"
    }

    public static func isValidManifestName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 63,
              value.first?.isLetter == true || value.first?.isNumber == true,
              value.last?.isLetter == true || value.last?.isNumber == true else {
            return false
        }
        return value.utf8.allSatisfy {
            ($0 >= 97 && $0 <= 122) ||
                ($0 >= 48 && $0 <= 57) ||
                $0 == 45
        }
    }
}

public enum NetworkBindAddressPolicy {
    public static let localhostBindAddress = "127.0.0.1"
    public static let localhostAliases: Set<String> = ["127.0.0.1", "::1", "localhost"]
    public static let broadBindAddresses: Set<String> = ["0.0.0.0", "::"]

    public static func normalizedBindAddress(_ address: String?) -> String {
        guard let address else {
            return localhostBindAddress
        }

        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return localhostBindAddress
        }

        return trimmed.lowercased()
    }

    public static func isLocalhost(_ address: String?) -> Bool {
        localhostAliases.contains(normalizedBindAddress(address))
    }

    public static func isBroadBindAddress(_ address: String?) -> Bool {
        broadBindAddresses.contains(normalizedBindAddress(address))
    }

    public static func hostPortKey(bindAddress: String?, hostPort: Int, protocolName: String) -> String {
        "\(normalizedBindAddress(bindAddress)):\(hostPort)/\(protocolName.lowercased())"
    }

    public static func hostPortsConflict(
        lhsBindAddress: String?,
        lhsHostPort: Int?,
        lhsProtocolName: String,
        rhsBindAddress: String?,
        rhsHostPort: Int?,
        rhsProtocolName: String
    ) -> Bool {
        guard let lhsHostPort,
              let rhsHostPort,
              lhsHostPort == rhsHostPort,
              lhsProtocolName.lowercased() == rhsProtocolName.lowercased()
        else {
            return false
        }

        let lhsBind = normalizedBindAddress(lhsBindAddress)
        let rhsBind = normalizedBindAddress(rhsBindAddress)

        return lhsBind == rhsBind ||
            broadBindAddresses.contains(lhsBind) ||
            broadBindAddresses.contains(rhsBind)
    }
}

public struct PortBinding: Equatable, Sendable {
    public let target: Int
    public let published: Int?
    public let protocolName: PortProtocol
    public let scope: NetworkExposureScope

    public init(target: Int, published: Int?, protocolName: PortProtocol, scope: NetworkExposureScope) {
        self.target = target
        self.published = published
        self.protocolName = protocolName
        self.scope = scope
    }

    public func validate() -> [HostwrightDiagnostic] {
        var diagnostics: [HostwrightDiagnostic] = []

        if target < 1 || target > 65_535 {
            diagnostics.append(HostwrightDiagnostic(code: .manifestValidationFailed, message: "Target port must be between 1 and 65535."))
        }

        if let published, published < 1 || published > 65_535 {
            diagnostics.append(HostwrightDiagnostic(code: .manifestValidationFailed, message: "Published port must be between 1 and 65535."))
        }

        if !scope.isAllowedInFirstRelease {
            diagnostics.append(HostwrightDiagnostic(code: .unsafeExposure, message: "Only project and localhost scopes are allowed in the first release."))
        }

        return diagnostics
    }
}
