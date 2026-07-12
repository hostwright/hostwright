import Foundation
import LocalAuthentication
import Security

public struct HostwrightSecretReference: Equatable, Hashable, Sendable {
    public static let supportedScheme = "keychain"

    public let rawValue: String
    public let service: String
    public let account: String

    public init(service: String, account: String) throws {
        try Self.validateComponent(service, name: "service")
        try Self.validateComponent(account, name: "account")
        self.service = service
        self.account = account
        self.rawValue = "\(Self.supportedScheme)://\(service)/\(account)"
    }

    public static func parse(_ rawValue: String) throws -> HostwrightSecretReference {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SecretStoreError.invalidReference("Secret reference must not be empty.")
        }
        guard trimmed.hasPrefix("\(supportedScheme)://") else {
            throw SecretStoreError.invalidReference("Secret references must use keychain://<service>/<account>.")
        }

        let remainder = String(trimmed.dropFirst("\(supportedScheme)://".count))
        let parts = remainder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            throw SecretStoreError.invalidReference("Secret references must use keychain://<service>/<account>.")
        }

        return try HostwrightSecretReference(service: parts[0], account: parts[1])
    }

    public var redactedDescription: String {
        "\(Self.supportedScheme)://[REDACTED]"
    }

    private static func validateComponent(_ value: String, name: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SecretStoreError.invalidReference("Secret reference \(name) must not be empty.")
        }
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw SecretStoreError.invalidReference("Secret reference \(name) must not contain whitespace.")
        }
        let pattern = #"^[A-Za-z0-9._:@-]{1,128}$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw SecretStoreError.invalidReference("Secret reference \(name) contains unsupported characters.")
        }
    }
}

public enum SecretStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidReference(String)
    case backendUnavailable(String)
    case notFound(String)
    case interactionNotAllowed(String)

    public var description: String {
        switch self {
        case .invalidReference(let message),
             .backendUnavailable(let message),
             .notFound(let message),
             .interactionNotAllowed(let message):
            return message
        }
    }
}

public protocol SecretStore: Sendable {
    func readString(reference: HostwrightSecretReference) throws -> String
}

public struct MacOSKeychainSecretStore: SecretStore {
    public init() {}

    public func readString(reference: HostwrightSecretReference) throws -> String {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SecretStoreError.backendUnavailable(
                    "macOS Keychain returned an unsupported value type for \(reference.redactedDescription)."
                )
            }
            guard let value = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.backendUnavailable(
                    "macOS Keychain item data is not valid UTF-8 for \(reference.redactedDescription)."
                )
            }
            return value
        case errSecItemNotFound:
            throw SecretStoreError.notFound(
                "No local macOS Keychain item was found for \(reference.redactedDescription)."
            )
        case errSecInteractionNotAllowed, errSecAuthFailed:
            throw SecretStoreError.interactionNotAllowed(
                "macOS Keychain access requires disallowed user interaction for \(reference.redactedDescription)."
            )
        case errSecNotAvailable:
            throw SecretStoreError.backendUnavailable(
                "macOS Keychain is unavailable for \(reference.redactedDescription)."
            )
        default:
            throw SecretStoreError.backendUnavailable(
                "macOS Keychain lookup failed with status \(status) for \(reference.redactedDescription)."
            )
        }
    }
}

public enum SecretNamePolicy {
    private static let sensitiveFragments = [
        "TOKEN",
        "PASSWORD",
        "PASS",
        "SECRET",
        "CREDENTIAL",
        "AUTH",
        "KEY"
    ]

    public static func isSensitiveEnvironmentKey(_ key: String) -> Bool {
        let uppercased = key.uppercased()
        return sensitiveFragments.contains { uppercased.contains($0) }
    }

    public static func requiresSecretReferenceEnvironmentKey(_ key: String) -> Bool {
        let uppercased = key.uppercased()
        if ["TOKEN", "PASSWORD", "PASSWD", "PASSPHRASE", "SECRET", "CREDENTIAL"].contains(where: { uppercased.contains($0) }) {
            return true
        }

        let parts = uppercased
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard parts.contains("KEY") else {
            return false
        }
        return parts.contains { ["API", "ACCESS", "PRIVATE", "CLIENT", "SESSION"].contains($0) }
    }
}

public struct UnavailableKeychainSecretStore: SecretStore {
    public init() {}

    public func readString(reference: HostwrightSecretReference) throws -> String {
        throw SecretStoreError.backendUnavailable(
            "Live macOS Keychain access is not enabled for noninteractive Hostwright commands. Configure a separately approved secret backend before resolving \(reference.redactedDescription)."
        )
    }
}
