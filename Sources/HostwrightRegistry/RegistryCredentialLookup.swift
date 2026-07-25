import Foundation
import HostwrightCore

public enum DockerRegistryCredentialKind: String, Equatable, Sendable {
    case password
    case identityToken = "identity-token"
}

public enum RegistryCredentialLookupSource: String, Equatable, Sendable {
    case dockerAuthFile = "docker-auth-file"
    case dockerHelper = "docker-helper"
    case ociAuthFile = "oci-auth-file"
}

public struct RegistryCredentialLookupResult:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let credential: RegistryCredential
    public let kind: DockerRegistryCredentialKind
    public let source: RegistryCredentialLookupSource

    public init(
        credential: RegistryCredential,
        kind: DockerRegistryCredentialKind,
        source: RegistryCredentialLookupSource
    ) {
        self.credential = credential
        self.kind = kind
        self.source = source
    }

    public var description: String {
        "Registry credential lookup result (source: \(source.rawValue), kind: \(kind.rawValue), secret: redacted)."
    }

    public var debugDescription: String {
        description
    }
}

public struct DockerCredentialConfigurationDocument:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let data: Data
    public let source: RegistryCredentialLookupSource

    public init(data: Data, source: RegistryCredentialLookupSource) {
        self.data = data
        self.source = source
    }

    public var description: String {
        "Registry credential configuration (source: \(source.rawValue), bytes: \(data.count), contents: redacted)."
    }

    public var debugDescription: String {
        description
    }
}

public enum RegistryCredentialLookupError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidRegistry
    case configurationTooLarge
    case invalidConfiguration
    case ambiguousConfiguration
    case credentialUnavailable
    case helperUnavailable
    case helperRejected
    case helperTimedOut
    case helperOutputTooLarge
    case invalidHelperOutput
    case cancelled
    case helperProcessFailed

    public var description: String {
        switch self {
        case .invalidRegistry:
            "The registry identifier is invalid."
        case .configurationTooLarge:
            "The registry credential configuration exceeds its bounded size."
        case .invalidConfiguration:
            "The registry credential configuration is invalid."
        case .ambiguousConfiguration:
            "The registry credential configuration contains ambiguous canonical entries."
        case .credentialUnavailable:
            "No credential is available for the exact registry."
        case .helperUnavailable:
            "The configured registry credential helper is unavailable."
        case .helperRejected:
            "The configured registry credential helper failed secure validation."
        case .helperTimedOut:
            "The registry credential helper timed out."
        case .helperOutputTooLarge:
            "The registry credential helper exceeded a bounded output limit."
        case .invalidHelperOutput:
            "The registry credential helper returned an invalid response."
        case .cancelled:
            "Registry credential lookup was cancelled."
        case .helperProcessFailed:
            "The registry credential helper failed."
        }
    }
}

public struct DockerRegistryCanonicalKey: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ rawValue: String) throws {
        value = try Self.canonicalize(rawValue)
    }

    public var description: String {
        value
    }

    private static func canonicalize(_ rawValue: String) throws -> String {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 2_048,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.contains(where: \.isNewline),
              !rawValue.contains("\0") else {
            throw RegistryCredentialLookupError.invalidRegistry
        }

        let hasScheme = rawValue.contains("://")
        let candidate = hasScheme ? rawValue : "https://\(rawValue)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let rawHost = components.host,
              !rawHost.isEmpty else {
            throw RegistryCredentialLookupError.invalidRegistry
        }

        let path = components.percentEncodedPath
        guard path.isEmpty || path == "/" || path == "/v1/" else {
            throw RegistryCredentialLookupError.invalidRegistry
        }

        let renderedHost = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        let authority = components.port.map { "\(renderedHost):\($0)" } ?? renderedHost
        do {
            return try RegistryEndpoint("https://\(authority)").authority
        } catch {
            throw RegistryCredentialLookupError.invalidRegistry
        }
    }
}

public protocol DockerCredentialHelperResolving: Sendable {
    func executableURL(for helperName: String) -> URL?
}

public struct FixedDockerCredentialHelperResolver: DockerCredentialHelperResolving {
    private let executables: [String: URL]

    public init(executables: [String: URL]) {
        self.executables = executables
    }

    public func executableURL(for helperName: String) -> URL? {
        executables[helperName]
    }
}

public protocol DockerCredentialHelperExecuting: Sendable {
    func get(
        executableURL: URL,
        helperName: String,
        registry: DockerRegistryCanonicalKey,
        cancellation: SecureSubprocessCancellation
    ) throws -> Data
}

public struct SecureDockerCredentialHelperExecutor: DockerCredentialHelperExecuting {
    public static let maximumInputBytes = 64 * 1_024
    public static let maximumOutputBytes = 64 * 1_024
    public static let timeoutMilliseconds = 10_000

    private let execute: @Sendable (
        SecureSubprocessRequest,
        SecureSubprocessCancellation
    ) throws -> SecureSubprocessResult

    public init() {
        execute = { request, cancellation in
            try SecureSubprocessRunner().run(request, cancellation: cancellation)
        }
    }

    init(
        execute: @escaping @Sendable (
            SecureSubprocessRequest,
            SecureSubprocessCancellation
        ) throws -> SecureSubprocessResult
    ) {
        self.execute = execute
    }

    public func get(
        executableURL: URL,
        helperName: String,
        registry: DockerRegistryCanonicalKey,
        cancellation: SecureSubprocessCancellation
    ) throws -> Data {
        let executablePath = executableURL.standardizedFileURL.path
        guard Self.isValidHelperName(helperName),
              executableURL.isFileURL,
              executablePath.hasPrefix("/"),
              URL(fileURLWithPath: executablePath).lastPathComponent == "docker-credential-\(helperName)" else {
            throw RegistryCredentialLookupError.helperRejected
        }

        guard let input = "\(registry.value)\n".data(using: .utf8),
              input.count <= Self.maximumInputBytes else {
            throw RegistryCredentialLookupError.invalidRegistry
        }

        let request = SecureSubprocessRequest(
            executablePath: executablePath,
            arguments: ["get"],
            environment: SecureSubprocessEnvironment.minimal,
            workingDirectory: "/",
            standardInput: input,
            timeoutMilliseconds: Self.timeoutMilliseconds,
            terminationGraceMilliseconds: 1_000,
            maximumStandardOutputBytes: Self.maximumOutputBytes,
            maximumStandardErrorBytes: Self.maximumOutputBytes,
            maximumStandardInputBytes: Self.maximumInputBytes
        )

        do {
            let result = try execute(request, cancellation)
            guard result.exitStatus == 0,
                  result.terminationSignal == nil else {
                throw RegistryCredentialLookupError.helperProcessFailed
            }
            guard !result.standardOutputTruncated, !result.standardErrorTruncated else {
                throw RegistryCredentialLookupError.helperOutputTooLarge
            }
            return result.standardOutput
        } catch let error as RegistryCredentialLookupError {
            throw error
        } catch let error as SecureSubprocessError {
            switch error {
            case .timedOut:
                throw RegistryCredentialLookupError.helperTimedOut
            case .cancelled:
                throw RegistryCredentialLookupError.cancelled
            case .outputLimitExceeded:
                throw RegistryCredentialLookupError.helperOutputTooLarge
            case .executableRejected, .executableChanged:
                throw RegistryCredentialLookupError.helperRejected
            case .invalidRequest, .workingDirectoryRejected:
                throw RegistryCredentialLookupError.helperRejected
            case .spawnSetupFailed, .launchFailed, .inputWriteFailed, .outputReadFailed,
                 .waitFailed, .descendantProcessDetected, .processTreeCleanupFailed:
                throw RegistryCredentialLookupError.helperProcessFailed
            }
        } catch {
            throw RegistryCredentialLookupError.helperProcessFailed
        }
    }

    private static func isValidHelperName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII &&
                (
                    CharacterSet.alphanumerics.contains(scalar) ||
                        scalar == "." ||
                        scalar == "_" ||
                        scalar == "-"
                )
        }
    }
}

public struct DockerRegistryCredentialLookup: Sendable {
    public static let maximumConfigurationBytes = 1 * 1_024 * 1_024
    public static let maximumCredentialBytes = 64 * 1_024
    public static let maximumEntries = 4_096

    private let helperResolver: any DockerCredentialHelperResolving
    private let helperExecutor: any DockerCredentialHelperExecuting

    public init(
        helperResolver: any DockerCredentialHelperResolving,
        helperExecutor: any DockerCredentialHelperExecuting = SecureDockerCredentialHelperExecutor()
    ) {
        self.helperResolver = helperResolver
        self.helperExecutor = helperExecutor
    }

    public func credential(
        for registryValue: String,
        configurationDocuments: [DockerCredentialConfigurationDocument],
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> RegistryCredential {
        try lookup(
            for: registryValue,
            configurationDocuments: configurationDocuments,
            cancellation: cancellation
        ).credential
    }

    public func lookup(
        for registryValue: String,
        configurationDocuments: [DockerCredentialConfigurationDocument],
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> RegistryCredentialLookupResult {
        guard !cancellation.isCancelled else {
            throw RegistryCredentialLookupError.cancelled
        }
        let registry = try DockerRegistryCanonicalKey(registryValue)
        guard configurationDocuments.count <= 16 else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }

        for document in configurationDocuments {
            guard !cancellation.isCancelled else {
                throw RegistryCredentialLookupError.cancelled
            }
            guard document.source != .dockerHelper else {
                throw RegistryCredentialLookupError.invalidConfiguration
            }
            let configuration = try ParsedDockerCredentialConfiguration(data: document.data)
            if let helperName = try configuration.helperName(for: registry) {
                guard let executableURL = helperResolver.executableURL(for: helperName) else {
                    throw RegistryCredentialLookupError.helperUnavailable
                }
                let output = try helperExecutor.get(
                    executableURL: executableURL,
                    helperName: helperName,
                    registry: registry,
                    cancellation: cancellation
                )
                guard !cancellation.isCancelled else {
                    throw RegistryCredentialLookupError.cancelled
                }
                return RegistryCredentialLookupResult(
                    credential: try Self.parseHelperOutput(output, expectedRegistry: registry),
                    kind: try Self.helperCredentialKind(output),
                    source: .dockerHelper
                )
            }
            if let material = try configuration.inlineCredential(for: registry) {
                return RegistryCredentialLookupResult(
                    credential: material.credential,
                    kind: material.kind,
                    source: document.source
                )
            }
        }
        throw RegistryCredentialLookupError.credentialUnavailable
    }

    public func lookup(
        registryValue: String,
        configurationDocuments: [DockerCredentialConfigurationDocument],
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> RegistryCredentialLookupResult {
        try lookup(
            for: registryValue,
            configurationDocuments: configurationDocuments,
            cancellation: cancellation
        )
    }

    private static func parseHelperOutput(
        _ data: Data,
        expectedRegistry: DockerRegistryCanonicalKey
    ) throws -> RegistryCredential {
        guard !data.isEmpty, data.count <= maximumCredentialBytes else {
            throw data.count > maximumCredentialBytes
                ? RegistryCredentialLookupError.helperOutputTooLarge
                : RegistryCredentialLookupError.invalidHelperOutput
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary.count <= 4,
              let serverURL = dictionary["ServerURL"] as? String,
              let canonicalServer = try? DockerRegistryCanonicalKey(serverURL),
              canonicalServer == expectedRegistry,
              let username = dictionary["Username"] as? String,
              let secret = dictionary["Secret"] as? String,
              isBoundedCredentialComponent(username),
              isBoundedCredentialComponent(secret) else {
            throw RegistryCredentialLookupError.invalidHelperOutput
        }
        let allowedKeys: Set<String> = ["ServerURL", "Username", "Secret"]
        guard Set(dictionary.keys).isSubset(of: allowedKeys) else {
            throw RegistryCredentialLookupError.invalidHelperOutput
        }
        do {
            return try RegistryCredential(username: username, secret: secret)
        } catch {
            throw RegistryCredentialLookupError.invalidHelperOutput
        }
    }

    private static func helperCredentialKind(_ data: Data) throws -> DockerRegistryCredentialKind {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let username = dictionary["Username"] as? String else {
            throw RegistryCredentialLookupError.invalidHelperOutput
        }
        return username == "<token>" ? .identityToken : .password
    }

    fileprivate static func isBoundedCredentialComponent(_ value: String) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximumCredentialBytes &&
            !value.contains("\0") &&
            !value.contains(where: \.isNewline)
    }
}

private struct ParsedDockerCredentialConfiguration {
    fileprivate struct InlineCredential {
        let credential: RegistryCredential
        let kind: DockerRegistryCredentialKind
    }

    private struct AuthEntry {
        let auth: String?
        let identityToken: String?
    }

    private let authEntries: [DockerRegistryCanonicalKey: AuthEntry]
    private let credentialHelpers: [DockerRegistryCanonicalKey: String]
    private let credentialStore: String?

    init(data: Data) throws {
        guard !data.isEmpty else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        guard data.count <= DockerRegistryCredentialLookup.maximumConfigurationBytes else {
            throw RegistryCredentialLookupError.configurationTooLarge
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary.count <= 64 else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }

        authEntries = try Self.parseAuthEntries(dictionary["auths"])
        credentialHelpers = try Self.parseCredentialHelpers(dictionary["credHelpers"])
        credentialStore = try Self.parseOptionalHelperName(dictionary["credsStore"])
    }

    func helperName(for registry: DockerRegistryCanonicalKey) throws -> String? {
        if let exactHelper = credentialHelpers[registry] {
            return exactHelper
        }
        return credentialStore
    }

    fileprivate func inlineCredential(
        for registry: DockerRegistryCanonicalKey
    ) throws -> InlineCredential? {
        guard let entry = authEntries[registry] else {
            return nil
        }
        if let identityToken = entry.identityToken {
            guard DockerRegistryCredentialLookup.isBoundedCredentialComponent(identityToken) else {
                throw RegistryCredentialLookupError.invalidConfiguration
            }
            do {
                return InlineCredential(
                    credential: try RegistryCredential(username: "<token>", secret: identityToken),
                    kind: .identityToken
                )
            } catch {
                throw RegistryCredentialLookupError.invalidConfiguration
            }
        }
        guard let encoded = entry.auth,
              encoded.utf8.count <= DockerRegistryCredentialLookup.maximumCredentialBytes,
              let decoded = Data(base64Encoded: encoded),
              decoded.count <= DockerRegistryCredentialLookup.maximumCredentialBytes,
              let value = String(data: decoded, encoding: .utf8),
              let separator = value.firstIndex(of: ":") else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        let username = String(value[..<separator])
        let secret = String(value[value.index(after: separator)...])
        guard DockerRegistryCredentialLookup.isBoundedCredentialComponent(username),
              DockerRegistryCredentialLookup.isBoundedCredentialComponent(secret) else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        do {
            return InlineCredential(
                credential: try RegistryCredential(username: username, secret: secret),
                kind: .password
            )
        } catch {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
    }

    private static func parseAuthEntries(_ value: Any?) throws -> [DockerRegistryCanonicalKey: AuthEntry] {
        guard let value else {
            return [:]
        }
        guard let dictionary = value as? [String: Any],
              dictionary.count <= DockerRegistryCredentialLookup.maximumEntries else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        var result: [DockerRegistryCanonicalKey: AuthEntry] = [:]
        for (rawKey, rawEntry) in dictionary {
            let key: DockerRegistryCanonicalKey
            do {
                key = try DockerRegistryCanonicalKey(rawKey)
            } catch {
                throw RegistryCredentialLookupError.invalidConfiguration
            }
            guard result[key] == nil,
                  let entry = rawEntry as? [String: Any],
                  entry.count <= 16 else {
                throw result[key] == nil
                    ? RegistryCredentialLookupError.invalidConfiguration
                    : RegistryCredentialLookupError.ambiguousConfiguration
            }
            let auth = try optionalBoundedString(entry["auth"])
            let lowerToken = try optionalBoundedString(entry["identitytoken"])
            let camelToken = try optionalBoundedString(entry["identityToken"])
            guard lowerToken == nil || camelToken == nil else {
                throw RegistryCredentialLookupError.ambiguousConfiguration
            }
            result[key] = AuthEntry(auth: auth, identityToken: lowerToken ?? camelToken)
        }
        return result
    }

    private static func parseCredentialHelpers(_ value: Any?) throws -> [DockerRegistryCanonicalKey: String] {
        guard let value else {
            return [:]
        }
        guard let dictionary = value as? [String: Any],
              dictionary.count <= DockerRegistryCredentialLookup.maximumEntries else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        var result: [DockerRegistryCanonicalKey: String] = [:]
        for (rawKey, rawHelper) in dictionary {
            let key: DockerRegistryCanonicalKey
            do {
                key = try DockerRegistryCanonicalKey(rawKey)
            } catch {
                throw RegistryCredentialLookupError.invalidConfiguration
            }
            guard result[key] == nil,
                  let helperName = rawHelper as? String,
                  isValidHelperName(helperName) else {
                throw result[key] == nil
                    ? RegistryCredentialLookupError.invalidConfiguration
                    : RegistryCredentialLookupError.ambiguousConfiguration
            }
            result[key] = helperName
        }
        return result
    }

    private static func parseOptionalHelperName(_ value: Any?) throws -> String? {
        guard let value else {
            return nil
        }
        guard let helperName = value as? String,
              isValidHelperName(helperName) else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        return helperName
    }

    private static func optionalBoundedString(_ value: Any?) throws -> String? {
        guard let value else {
            return nil
        }
        guard let string = value as? String,
              string.utf8.count <= DockerRegistryCredentialLookup.maximumCredentialBytes else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        return string
    }

    private static func isValidHelperName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII &&
                (
                    CharacterSet.alphanumerics.contains(scalar) ||
                        scalar == "." ||
                        scalar == "_" ||
                        scalar == "-"
                )
        }
    }
}
