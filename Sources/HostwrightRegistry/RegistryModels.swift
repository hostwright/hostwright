import CryptoKit
import Darwin
import Foundation

public enum RegistryContractError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidEndpoint(String)
    case invalidScope(String)
    case invalidChallenge(String)
    case invalidTokenResponse(String)
    case invalidCredential(String)

    public var description: String {
        switch self {
        case .invalidEndpoint(let message),
             .invalidScope(let message),
             .invalidChallenge(let message),
             .invalidTokenResponse(let message),
             .invalidCredential(let message):
            return message
        }
    }
}

public struct RegistryEndpoint:
    Equatable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    public static let maximumInputBytes = 2_048
    public static let credentialKeychainService = "dev.hostwright.registry"

    public let host: String
    public let port: Int?

    public init(_ input: String) throws {
        guard !input.isEmpty,
              input.utf8.count <= Self.maximumInputBytes,
              input == input.trimmingCharacters(in: .whitespacesAndNewlines),
              input.unicodeScalars.allSatisfy({
                  $0.isASCII && !CharacterSet.controlCharacters.contains($0)
              }),
              !input.contains("%"),
              !input.hasSuffix(":") else {
            throw RegistryContractError.invalidEndpoint(
                "Registry endpoint must be a bounded ASCII HTTPS host with no surrounding whitespace."
            )
        }

        let candidate: String
        if input.contains("://") {
            candidate = input
        } else {
            candidate = "https://\(input)"
        }

        guard let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              let componentHost = components.host?.lowercased() else {
            throw RegistryContractError.invalidEndpoint(
                "Registry endpoint must contain only host[:port] or an HTTPS origin."
            )
        }
        let parsedHost: String
        if componentHost.hasPrefix("["), componentHost.hasSuffix("]") {
            parsedHost = String(componentHost.dropFirst().dropLast())
        } else {
            parsedHost = componentHost
        }
        guard Self.validHost(parsedHost) else {
            throw RegistryContractError.invalidEndpoint(
                "Registry endpoint must contain a valid DNS name or IP address."
            )
        }

        if let parsedPort = components.port {
            guard (1...65_535).contains(parsedPort) else {
                throw RegistryContractError.invalidEndpoint(
                    "Registry endpoint port must be between 1 and 65535."
                )
            }
        }

        self.host = Self.canonicalHost(parsedHost)
        self.port = components.port == 443 ? nil : components.port

        guard URL(string: canonicalURLString) != nil else {
            throw RegistryContractError.invalidEndpoint(
                "Registry endpoint could not be represented as a canonical HTTPS origin."
            )
        }
    }

    public var authority: String {
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        if let port {
            return "\(renderedHost):\(port)"
        }
        return renderedHost
    }

    public var canonicalURLString: String {
        "https://\(authority)"
    }

    public var url: URL {
        URL(string: canonicalURLString)!
    }

    public var credentialKeychainAccount: String {
        SHA256.hash(data: Data(canonicalURLString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public var description: String {
        authority
    }

    private static func canonicalHost(_ host: String) -> String {
        switch host {
        case "docker.io", "index.docker.io", "registry-1.docker.io":
            return "registry-1.docker.io"
        default:
            return host
        }
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasSuffix(".") else {
            return false
        }
        if host.contains(":") {
            var address = in6_addr()
            return host.withCString {
                inet_pton(AF_INET6, $0, &address) == 1
            }
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            var address = in_addr()
            return host.withCString {
                inet_pton(AF_INET, $0, &address) == 1
            }
        }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty &&
                $0.utf8.count <= 63 &&
                $0.first != "-" &&
                $0.last != "-" &&
                $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

public enum RegistryScopeResourceType: String, CaseIterable, Sendable {
    case repository
    case registry
}

public enum RegistryScopeAction: String, CaseIterable, Hashable, Sendable {
    case delete
    case pull
    case push
    case wildcard = "*"
}

public struct RegistryAccessScope:
    Equatable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    public static let maximumBytes = 1_024

    public let resourceType: RegistryScopeResourceType
    public let name: String
    public let actions: Set<RegistryScopeAction>

    public init(
        resourceType: RegistryScopeResourceType,
        name: String,
        actions: Set<RegistryScopeAction>
    ) throws {
        guard !actions.isEmpty else {
            throw RegistryContractError.invalidScope(
                "Registry access scope must contain at least one action."
            )
        }
        if actions.contains(.wildcard), actions.count != 1 {
            throw RegistryContractError.invalidScope(
                "Registry wildcard access cannot be combined with other actions."
            )
        }
        switch resourceType {
        case .repository:
            guard Self.validRepositoryName(name) else {
                throw RegistryContractError.invalidScope(
                    "Repository scope names must use normalized lowercase distribution syntax."
                )
            }
        case .registry:
            guard name == "catalog", actions == [.wildcard] else {
                throw RegistryContractError.invalidScope(
                    "Registry scope is limited to registry:catalog:*."
                )
            }
        }
        self.resourceType = resourceType
        self.name = name
        self.actions = actions
    }

    public static func parse(_ input: String) throws -> RegistryAccessScope {
        guard !input.isEmpty,
              input.utf8.count <= maximumBytes,
              input == input.trimmingCharacters(in: .whitespacesAndNewlines),
              input.unicodeScalars.allSatisfy({
                  $0.isASCII && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw RegistryContractError.invalidScope(
                "Registry access scope must be bounded ASCII without surrounding whitespace."
            )
        }
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let type = RegistryScopeResourceType(rawValue: String(parts[0])) else {
            throw RegistryContractError.invalidScope(
                "Registry access scope must use type:name:action[,action]."
            )
        }
        let actionParts = parts[2].split(separator: ",", omittingEmptySubsequences: false)
        guard !actionParts.isEmpty,
              actionParts.count <= RegistryScopeAction.allCases.count else {
            throw RegistryContractError.invalidScope(
                "Registry access scope contains an invalid action list."
            )
        }
        var actions = Set<RegistryScopeAction>()
        for rawAction in actionParts {
            guard let action = RegistryScopeAction(rawValue: String(rawAction)),
                  actions.insert(action).inserted else {
                throw RegistryContractError.invalidScope(
                    "Registry access scope contains an unsupported or duplicate action."
                )
            }
        }
        return try RegistryAccessScope(
            resourceType: type,
            name: String(parts[1]),
            actions: actions
        )
    }

    public func isSubset(of other: RegistryAccessScope) -> Bool {
        guard resourceType == other.resourceType, name == other.name else {
            return false
        }
        if other.actions.contains(.wildcard) {
            return true
        }
        if actions.contains(.wildcard) {
            return false
        }
        return actions.isSubset(of: other.actions)
    }

    public var canonicalValue: String {
        let actionList = actions.map(\.rawValue).sorted().joined(separator: ",")
        return "\(resourceType.rawValue):\(name):\(actionList)"
    }

    public var description: String {
        canonicalValue
    }

    private static func validRepositoryName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255 else {
            return false
        }
        return name.range(
            of: #"^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*$"#,
            options: .regularExpression
        ) != nil
    }
}

public struct RegistryAccessScopeSet: Equatable, Sendable, CustomStringConvertible {
    public static let maximumScopeCount = 16
    public static let maximumBytes = 4_096

    public let scopes: [RegistryAccessScope]

    public init(_ scopes: [RegistryAccessScope]) throws {
        guard scopes.count <= Self.maximumScopeCount else {
            throw RegistryContractError.invalidScope(
                "Registry access request exceeds the maximum scope count."
            )
        }
        var combined: [ScopeIdentity: Set<RegistryScopeAction>] = [:]
        for scope in scopes {
            combined[ScopeIdentity(scope), default: []].formUnion(scope.actions)
        }
        var normalized: [RegistryAccessScope] = []
        for (identity, actions) in combined {
            let effectiveActions: Set<RegistryScopeAction> =
                actions.contains(.wildcard) ? [.wildcard] : actions
            normalized.append(
                try RegistryAccessScope(
                    resourceType: identity.resourceType,
                    name: identity.name,
                    actions: effectiveActions
                )
            )
        }
        self.scopes = normalized.sorted { $0.canonicalValue < $1.canonicalValue }
    }

    public static var empty: RegistryAccessScopeSet {
        try! RegistryAccessScopeSet([])
    }

    public static func parse(_ input: String) throws -> RegistryAccessScopeSet {
        guard !input.isEmpty,
              input.utf8.count <= maximumBytes,
              input == input.trimmingCharacters(in: .whitespacesAndNewlines),
              !input.contains(where: { $0.isWhitespace && $0 != " " }) else {
            throw RegistryContractError.invalidScope(
                "Registry scope set must be a bounded single-space-separated value."
            )
        }
        let parts = input.split(separator: " ", omittingEmptySubsequences: false)
        guard !parts.contains(where: \.isEmpty) else {
            throw RegistryContractError.invalidScope(
                "Registry scope set must use one space between scopes."
            )
        }
        return try RegistryAccessScopeSet(
            parts.map { try RegistryAccessScope.parse(String($0)) }
        )
    }

    public func isSubset(of other: RegistryAccessScopeSet) -> Bool {
        scopes.allSatisfy { scope in
            other.scopes.contains { scope.isSubset(of: $0) }
        }
    }

    public var canonicalValue: String {
        scopes.map(\.canonicalValue).joined(separator: " ")
    }

    public var description: String {
        canonicalValue
    }

    private struct ScopeIdentity: Hashable {
        let resourceType: RegistryScopeResourceType
        let name: String

        init(_ scope: RegistryAccessScope) {
            self.resourceType = scope.resourceType
            self.name = scope.name
        }
    }
}

public struct RegistrySecret:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public static let maximumByteCount = 64 * 1_024

    private let value: String

    public init(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= Self.maximumByteCount,
              !value.contains("\0") else {
            throw RegistryContractError.invalidCredential(
                "Registry secret must contain 1 through 65536 UTF-8 bytes without null bytes."
            )
        }
        self.value = value
    }

    public func withValue<Result>(
        _ body: (String) throws -> Result
    ) rethrows -> Result {
        try body(value)
    }

    public var description: String {
        "[REDACTED]"
    }

    public var debugDescription: String {
        "[REDACTED]"
    }
}

public struct RegistryCredential:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public static let storageSchemaVersion = 1
    public static let maximumSecretBytes = 32 * 1_024
    public static let maximumStorageBytes = 64 * 1_024

    public let username: String
    private let secret: RegistrySecret

    public init(username: String, secret: String) throws {
        guard !username.isEmpty,
              username.utf8.count <= 256,
              !username.contains(":"),
              username.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw RegistryContractError.invalidCredential(
                "Registry username must contain 1 through 256 UTF-8 bytes without controls or colons."
            )
        }
        guard secret.utf8.count <= Self.maximumSecretBytes else {
            throw RegistryContractError.invalidCredential(
                "Registry credential secret must not exceed 32768 UTF-8 bytes."
            )
        }
        self.username = username
        self.secret = try RegistrySecret(secret)
    }

    public func withSecret<Result>(
        _ body: (String) throws -> Result
    ) rethrows -> Result {
        try secret.withValue(body)
    }

    public func encodedForStorage() throws -> Data {
        let secretValue = secret.withValue { $0 }
        let object: [String: Any] = [
            "schemaVersion": Self.storageSchemaVersion,
            "secretBase64": Data(secretValue.utf8).base64EncodedString(),
            "username": username
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ),
        data.count <= Self.maximumStorageBytes else {
            throw RegistryContractError.invalidCredential(
                "Registry credential could not be encoded within the storage limit."
            )
        }
        return data
    }

    public static func decodeFromStorage(_ data: Data) throws -> RegistryCredential {
        let object: [String: Any]
        do {
            object = try RegistryStrictJSONObject.decode(
                data,
                maximumBytes: maximumStorageBytes,
                allowedKeys: ["schemaVersion", "secretBase64", "username"],
                requiredKeys: ["schemaVersion", "secretBase64", "username"]
            )
        } catch {
            throw RegistryContractError.invalidCredential(
                "Stored registry credential is malformed or uses unsupported fields."
            )
        }
        guard let version = RegistryStrictJSONObject.integer(object["schemaVersion"]),
              version == storageSchemaVersion,
              let username = object["username"] as? String,
              let encodedSecret = object["secretBase64"] as? String,
              encodedSecret.utf8.count <= 88_000,
              let secretData = Data(base64Encoded: encodedSecret),
              secretData.base64EncodedString() == encodedSecret,
              let secret = String(data: secretData, encoding: .utf8) else {
            throw RegistryContractError.invalidCredential(
                "Stored registry credential has an invalid schema or value."
            )
        }
        return try RegistryCredential(username: username, secret: secret)
    }

    public var description: String {
        "RegistryCredential(username: [REDACTED], secret: [REDACTED])"
    }

    public var debugDescription: String {
        description
    }
}

enum RegistryStrictJSONObject {
    private enum ScanError: Error {
        case invalid
    }

    static func decode(
        _ data: Data,
        maximumBytes: Int,
        allowedKeys: Set<String>? = nil,
        requiredKeys: Set<String> = []
    ) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ScanError.invalid
        }
        try validate(Array(data))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count <= 32 else {
            throw ScanError.invalid
        }
        let actualKeys = Set(object.keys)
        if let allowedKeys, !actualKeys.isSubset(of: allowedKeys) {
            throw ScanError.invalid
        }
        guard requiredKeys.isSubset(of: actualKeys) else {
            throw ScanError.invalid
        }
        return object
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int.min),
              double <= Double(Int.max) else {
            return nil
        }
        return Int(double)
    }

    private static func validate(_ bytes: [UInt8]) throws {
        let start = skipWhitespace(bytes, from: 0)
        let end = try parseValue(bytes, from: start, depth: 0)
        guard skipWhitespace(bytes, from: end) == bytes.count else {
            throw ScanError.invalid
        }
    }

    private static func parseValue(
        _ bytes: [UInt8],
        from start: Int,
        depth: Int
    ) throws -> Int {
        guard depth <= 128 else {
            throw ScanError.invalid
        }
        let index = skipWhitespace(bytes, from: start)
        guard index < bytes.count else {
            throw ScanError.invalid
        }
        switch bytes[index] {
        case ascii("{"):
            return try parseObject(bytes, from: index, depth: depth)
        case ascii("["):
            return try parseArray(bytes, from: index, depth: depth)
        case ascii("\""):
            return try parseString(bytes, from: index).nextIndex
        default:
            var end = index
            while end < bytes.count,
                  ![ascii(","), ascii("]"), ascii("}")].contains(bytes[end]),
                  !isWhitespace(bytes[end]) {
                end += 1
            }
            guard end > index else {
                throw ScanError.invalid
            }
            return end
        }
    }

    private static func parseObject(
        _ bytes: [UInt8],
        from start: Int,
        depth: Int
    ) throws -> Int {
        var index = skipWhitespace(bytes, from: start + 1)
        if index < bytes.count, bytes[index] == ascii("}") {
            return index + 1
        }
        var seen = Set<String>()
        while true {
            let key = try parseString(bytes, from: index)
            guard seen.insert(key.value).inserted else {
                throw ScanError.invalid
            }
            index = skipWhitespace(bytes, from: key.nextIndex)
            guard index < bytes.count, bytes[index] == ascii(":") else {
                throw ScanError.invalid
            }
            index = skipWhitespace(
                bytes,
                from: try parseValue(
                    bytes,
                    from: index + 1,
                    depth: depth + 1
                )
            )
            guard index < bytes.count else {
                throw ScanError.invalid
            }
            if bytes[index] == ascii("}") {
                return index + 1
            }
            guard bytes[index] == ascii(",") else {
                throw ScanError.invalid
            }
            index = skipWhitespace(bytes, from: index + 1)
            guard index < bytes.count, bytes[index] != ascii("}") else {
                throw ScanError.invalid
            }
        }
    }

    private static func parseArray(
        _ bytes: [UInt8],
        from start: Int,
        depth: Int
    ) throws -> Int {
        var index = skipWhitespace(bytes, from: start + 1)
        if index < bytes.count, bytes[index] == ascii("]") {
            return index + 1
        }
        while true {
            index = skipWhitespace(
                bytes,
                from: try parseValue(
                    bytes,
                    from: index,
                    depth: depth + 1
                )
            )
            guard index < bytes.count else {
                throw ScanError.invalid
            }
            if bytes[index] == ascii("]") {
                return index + 1
            }
            guard bytes[index] == ascii(",") else {
                throw ScanError.invalid
            }
            index = skipWhitespace(bytes, from: index + 1)
            guard index < bytes.count, bytes[index] != ascii("]") else {
                throw ScanError.invalid
            }
        }
    }

    private static func parseString(
        _ bytes: [UInt8],
        from start: Int
    ) throws -> (value: String, nextIndex: Int) {
        guard start < bytes.count, bytes[start] == ascii("\"") else {
            throw ScanError.invalid
        }
        var index = start + 1
        var escaped = false
        while index < bytes.count {
            if escaped {
                escaped = false
            } else if bytes[index] == ascii("\\") {
                escaped = true
            } else if bytes[index] == ascii("\"") {
                let literal = Data(bytes[start...index])
                guard let value = try? JSONDecoder().decode(String.self, from: literal) else {
                    throw ScanError.invalid
                }
                return (value, index + 1)
            }
            index += 1
        }
        throw ScanError.invalid
    }

    private static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count, isWhitespace(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        [9, 10, 13, 32].contains(byte)
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }
}
