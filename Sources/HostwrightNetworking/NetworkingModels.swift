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

