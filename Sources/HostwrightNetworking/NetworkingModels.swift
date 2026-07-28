import Foundation
import HostwrightCore

public enum NetworkExposureScope: String, Equatable, Sendable {
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
