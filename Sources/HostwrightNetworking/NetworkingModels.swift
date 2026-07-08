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
