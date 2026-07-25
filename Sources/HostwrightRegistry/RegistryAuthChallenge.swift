import Foundation

public enum RegistryAuthenticationScheme: String, Sendable {
    case basic = "Basic"
    case bearer = "Bearer"
}

public struct RegistryBasicChallenge: Equatable, Sendable {
    public let realm: String
    public let usesUTF8: Bool

    public init(realm: String, usesUTF8: Bool) {
        self.realm = realm
        self.usesUTF8 = usesUTF8
    }
}

public struct RegistryBearerChallenge: Equatable, Sendable {
    public let realm: URL
    public let service: String?
    public let scopes: RegistryAccessScopeSet

    public init(
        realm: URL,
        service: String?,
        scopes: RegistryAccessScopeSet
    ) {
        self.realm = realm
        self.service = service
        self.scopes = scopes
    }
}

public enum RegistryAuthenticationChallenge: Equatable, Sendable {
    public static let maximumHeaderBytes = 16 * 1_024
    public static let maximumParameterCount = 32
    public static let maximumParameterValueBytes = 4_096

    case basic(RegistryBasicChallenge)
    case bearer(RegistryBearerChallenge)

    public static func parse(_ header: String) throws -> RegistryAuthenticationChallenge {
        guard !header.isEmpty,
              header.utf8.count <= maximumHeaderBytes,
              header.unicodeScalars.allSatisfy({
                  $0.value == 9 || ($0.value >= 0x20 && $0.value != 0x7F)
              }) else {
            throw RegistryContractError.invalidChallenge(
                "Registry authentication challenge must be a bounded single header value."
            )
        }

        var parser = ChallengeParser(header)
        let rawScheme = try parser.parseToken(role: "authentication scheme")
        try parser.requireWhitespace()
        let parameters = try parser.parseParameters()
        guard parameters.count <= maximumParameterCount else {
            throw RegistryContractError.invalidChallenge(
                "Registry authentication challenge contains too many parameters."
            )
        }

        switch rawScheme.lowercased() {
        case "basic":
            return try parseBasic(parameters)
        case "bearer":
            return try parseBearer(parameters)
        default:
            throw RegistryContractError.invalidChallenge(
                "Registry authentication challenge uses an unsupported scheme."
            )
        }
    }

    private static func parseBasic(
        _ parameters: [String: String]
    ) throws -> RegistryAuthenticationChallenge {
        guard let realm = parameters["realm"],
              !realm.isEmpty,
              realm.utf8.count <= 1_024 else {
            throw RegistryContractError.invalidChallenge(
                "Basic registry challenge requires a bounded realm."
            )
        }
        let usesUTF8: Bool
        if let charset = parameters["charset"] {
            guard charset.caseInsensitiveCompare("UTF-8") == .orderedSame else {
                throw RegistryContractError.invalidChallenge(
                    "Basic registry challenge uses an unsupported charset."
                )
            }
            usesUTF8 = true
        } else {
            usesUTF8 = false
        }
        return .basic(
            RegistryBasicChallenge(realm: realm, usesUTF8: usesUTF8)
        )
    }

    private static func parseBearer(
        _ parameters: [String: String]
    ) throws -> RegistryAuthenticationChallenge {
        guard let rawRealm = parameters["realm"],
              rawRealm.utf8.count <= 2_048,
              let components = URLComponents(string: rawRealm),
              components.scheme?.lowercased() == "https",
              let realmHost = components.host,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let realm = components.url,
              Self.validBearerOrigin(host: realmHost, port: components.port) else {
            throw RegistryContractError.invalidChallenge(
                "Bearer registry challenge requires an HTTPS realm without credentials or fragments."
            )
        }

        let service: String?
        if let rawService = parameters["service"] {
            guard !rawService.isEmpty,
                  rawService.utf8.count <= 255,
                  rawService.range(
                      of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$"#,
                      options: .regularExpression
                  ) != nil else {
                throw RegistryContractError.invalidChallenge(
                    "Bearer registry challenge service is invalid."
                )
            }
            service = rawService
        } else {
            service = nil
        }

        let scopes: RegistryAccessScopeSet
        if let rawScope = parameters["scope"] {
            scopes = try RegistryAccessScopeSet.parse(rawScope)
        } else {
            scopes = .empty
        }
        return .bearer(
            RegistryBearerChallenge(
                realm: realm,
                service: service,
                scopes: scopes
            )
        )
    }

    private static func validBearerOrigin(host: String, port: Int?) -> Bool {
        let renderedHost = host.contains(":") && !host.hasPrefix("[")
            ? "[\(host)]"
            : host
        let authority = port.map { "\(renderedHost):\($0)" } ?? renderedHost
        return (try? RegistryEndpoint(authority)) != nil
    }
}

private struct ChallengeParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ header: String) {
        self.bytes = Array(header.utf8)
    }

    mutating func parseToken(role: String) throws -> String {
        let start = index
        while index < bytes.count, Self.isTokenCharacter(bytes[index]) {
            index += 1
        }
        guard index > start,
              let token = String(bytes: bytes[start..<index], encoding: .utf8) else {
            throw RegistryContractError.invalidChallenge(
                "Registry authentication challenge has an invalid \(role)."
            )
        }
        return token
    }

    mutating func requireWhitespace() throws {
        let start = index
        skipOptionalWhitespace()
        guard index > start, index < bytes.count else {
            throw RegistryContractError.invalidChallenge(
                "Registry authentication challenge must contain authentication parameters."
            )
        }
    }

    mutating func parseParameters() throws -> [String: String] {
        var parameters: [String: String] = [:]
        while index < bytes.count {
            let name = try parseToken(role: "parameter name").lowercased()
            skipOptionalWhitespace()
            guard index < bytes.count, bytes[index] == Self.ascii("=") else {
                throw RegistryContractError.invalidChallenge(
                    "Registry authentication challenge parameter is missing '='."
                )
            }
            index += 1
            skipOptionalWhitespace()
            let value = try parseParameterValue()
            guard value.utf8.count <= RegistryAuthenticationChallenge.maximumParameterValueBytes else {
                throw RegistryContractError.invalidChallenge(
                    "Registry authentication challenge parameter exceeds its size limit."
                )
            }
            guard parameters.updateValue(value, forKey: name) == nil else {
                throw RegistryContractError.invalidChallenge(
                    "Registry authentication challenge contains a duplicate parameter."
                )
            }
            skipOptionalWhitespace()
            guard index < bytes.count else {
                break
            }
            guard bytes[index] == Self.ascii(",") else {
                throw RegistryContractError.invalidChallenge(
                    "Registry authentication challenge has an invalid parameter delimiter."
                )
            }
            index += 1
            skipOptionalWhitespace()
            guard index < bytes.count else {
                throw RegistryContractError.invalidChallenge(
                    "Registry authentication challenge has a trailing delimiter."
                )
            }
        }
        guard !parameters.isEmpty else {
            throw RegistryContractError.invalidChallenge(
                "Registry authentication challenge must contain parameters."
            )
        }
        return parameters
    }

    private mutating func parseParameterValue() throws -> String {
        guard index < bytes.count else {
            throw RegistryContractError.invalidChallenge(
                "Registry authentication challenge parameter has no value."
            )
        }
        if bytes[index] == Self.ascii("\"") {
            return try parseQuotedString()
        }
        return try parseToken(role: "parameter value")
    }

    private mutating func parseQuotedString() throws -> String {
        index += 1
        var value: [UInt8] = []
        var closed = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == Self.ascii("\"") {
                closed = true
                break
            }
            if byte == Self.ascii("\\") {
                guard index < bytes.count else {
                    throw RegistryContractError.invalidChallenge(
                        "Registry authentication challenge has a truncated quoted escape."
                    )
                }
                let escaped = bytes[index]
                index += 1
                guard escaped == 9 || (escaped >= 0x20 && escaped != 0x7F) else {
                    throw RegistryContractError.invalidChallenge(
                        "Registry authentication challenge uses an unsupported quoted escape."
                    )
                }
                value.append(escaped)
            } else {
                guard byte == 9 || (byte >= 0x20 && byte != 0x7F) else {
                    throw RegistryContractError.invalidChallenge(
                        "Registry authentication challenge contains a control character."
                    )
                }
                value.append(byte)
            }
            guard value.count <= RegistryAuthenticationChallenge.maximumParameterValueBytes else {
                throw RegistryContractError.invalidChallenge(
                    "Registry authentication challenge parameter exceeds its size limit."
                )
            }
        }
        guard closed, let decoded = String(bytes: value, encoding: .utf8) else {
            throw RegistryContractError.invalidChallenge(
                "Registry authentication challenge contains an invalid quoted value."
            )
        }
        return decoded
    }

    private mutating func skipOptionalWhitespace() {
        while index < bytes.count, bytes[index] == 32 || bytes[index] == 9 {
            index += 1
        }
    }

    private static func isTokenCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
        }
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }
}
