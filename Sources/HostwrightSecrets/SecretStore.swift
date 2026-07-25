import Foundation
import LocalAuthentication
import Security

public enum HostwrightSecretProviderKind: String, CaseIterable, Equatable, Sendable {
    case keychain
    case environmentFile = "env-file"
    case localFile = "local-file"
    case external
    case plugin
}

public struct HostwrightSecretReference: Equatable, Hashable, Sendable {
    public static let supportedScheme = "keychain"
    public static let manifestPattern =
        #"^(?:(?:keychain|external|plugin)://[A-Za-z0-9._:@-]+/[A-Za-z0-9._:@-]+|env-file:///[^#]+#[A-Za-z_][A-Za-z0-9_]{0,127}|local-file:///[^#]+)$"#
    public static let manifestReferenceDescription =
        "keychain://<service>/<account>, env-file:///absolute/path#KEY, local-file:///absolute/path, external://<provider>/<item>, or plugin://<provider>/<item>"

    public let rawValue: String
    public let providerKind: HostwrightSecretProviderKind
    public let service: String
    public let account: String

    public init(service: String, account: String) throws {
        try Self.validateComponent(service, name: "service")
        try Self.validateComponent(account, name: "account")
        self.providerKind = .keychain
        self.service = service
        self.account = account
        self.rawValue = "\(Self.supportedScheme)://\(service)/\(account)"
    }

    public static func parse(_ rawValue: String) throws -> HostwrightSecretReference {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SecretStoreError.invalidReference("Secret reference must not be empty.")
        }
        for kind in HostwrightSecretProviderKind.allCases {
            let prefix = "\(kind.rawValue)://"
            guard trimmed.hasPrefix(prefix) else {
                continue
            }
            let remainder = String(trimmed.dropFirst(prefix.count))
            return try parse(kind: kind, remainder: remainder, rawValue: trimmed)
        }
        throw SecretStoreError.invalidReference(
            "Secret references must use a supported provider scheme."
        )
    }

    public static func isSupportedReferenceString(_ value: String) -> Bool {
        value.range(of: manifestPattern, options: .regularExpression) != nil
    }

    public var redactedDescription: String {
        "\(providerKind.rawValue)://[REDACTED]"
    }

    private init(
        rawValue: String,
        providerKind: HostwrightSecretProviderKind,
        service: String,
        account: String
    ) {
        self.rawValue = rawValue
        self.providerKind = providerKind
        self.service = service
        self.account = account
    }

    private static func parse(
        kind: HostwrightSecretProviderKind,
        remainder: String,
        rawValue: String
    ) throws -> HostwrightSecretReference {
        switch kind {
        case .keychain:
            let parts = remainder.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard parts.count == 2 else {
                throw invalidShape(kind)
            }
            try validateComponent(parts[0], name: "provider")
            try validateComponent(parts[1], name: "item")
            return HostwrightSecretReference(
                rawValue: rawValue,
                providerKind: kind,
                service: parts[0],
                account: parts[1]
            )
        case .external, .plugin:
            let parts = remainder.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard parts.count == 2 else {
                throw invalidShape(kind)
            }
            try validateProviderAuthority(parts[0])
            try validateComponent(parts[1], name: "item")
            return HostwrightSecretReference(
                rawValue: rawValue,
                providerKind: kind,
                service: parts[0],
                account: parts[1]
            )
        case .environmentFile:
            guard let separator = remainder.lastIndex(of: "#") else {
                throw invalidShape(kind)
            }
            let path = String(remainder[..<separator])
            let key = String(remainder[remainder.index(after: separator)...])
            try validateAbsolutePath(path)
            try validateEnvironmentKey(key)
            return HostwrightSecretReference(
                rawValue: rawValue,
                providerKind: kind,
                service: path,
                account: key
            )
        case .localFile:
            try validateAbsolutePath(remainder)
            return HostwrightSecretReference(
                rawValue: rawValue,
                providerKind: kind,
                service: remainder,
                account: ""
            )
        }
    }

    static func requireKeychain(
        _ reference: HostwrightSecretReference
    ) throws {
        guard reference.providerKind == .keychain else {
            throw SecretStoreError.invalidReference(
                "macOS Keychain operations require keychain://<service>/<account>."
            )
        }
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

    private static func validateEnvironmentKey(_ value: String) throws {
        guard value.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw SecretStoreError.invalidReference(
                "Environment-file secret references require a valid key."
            )
        }
    }

    private static func validateProviderAuthority(_ value: String) throws {
        guard value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw SecretStoreError.invalidReference(
                "External and plugin secret references require a stable provider identifier."
            )
        }
    }

    private static func validateAbsolutePath(_ path: String) throws {
        guard path.utf8.count <= 4_096,
              path.hasPrefix("/"),
              !path.contains("#"),
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw SecretStoreError.invalidReference(
                "File-backed secret references require an absolute normalized path."
            )
        }
    }

    private static func invalidShape(
        _ kind: HostwrightSecretProviderKind
    ) -> SecretStoreError {
        let expected: String
        switch kind {
        case .keychain:
            expected = "keychain://<service>/<account>"
        case .environmentFile:
            expected = "env-file:///absolute/path#KEY"
        case .localFile:
            expected = "local-file:///absolute/path"
        case .external:
            expected = "external://<provider>/<item>"
        case .plugin:
            expected = "plugin://<provider>/<item>"
        }
        return .invalidReference(
            "Secret reference must use \(expected)."
        )
    }
}

public enum SecretStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidReference(String)
    case invalidValue(String)
    case backendUnavailable(String)
    case notFound(String)
    case duplicate(String)
    case unmanaged(String)
    case permissionDenied(String)
    case interactionNotAllowed(String)
    case cancelled(String)
    case concurrentMutation(String)
    case corruptedMetadata(String)
    case partialEffect(String)

    public var description: String {
        switch self {
        case .invalidReference(let message),
             .invalidValue(let message),
             .backendUnavailable(let message),
             .notFound(let message),
             .duplicate(let message),
             .unmanaged(let message),
             .permissionDenied(let message),
             .interactionNotAllowed(let message),
             .cancelled(let message),
             .concurrentMutation(let message),
             .corruptedMetadata(let message),
             .partialEffect(let message):
            return message
        }
    }
}

public struct HostwrightSecretValue: Sendable {
    public static let maximumByteCount = 64 * 1_024

    let data: Data

    public init(_ value: String) throws {
        try self.init(utf8Data: Data(value.utf8))
    }

    public init(utf8Data: Data) throws {
        guard utf8Data.count <= Self.maximumByteCount else {
            throw SecretStoreError.invalidValue(
                "Secret values must not exceed 64 KiB."
            )
        }
        guard String(data: utf8Data, encoding: .utf8) != nil else {
            throw SecretStoreError.invalidValue(
                "Secret values must contain valid UTF-8."
            )
        }
        guard !utf8Data.contains(0) else {
            throw SecretStoreError.invalidValue(
                "Secret values must not contain null bytes."
            )
        }
        self.data = utf8Data
    }

    public var byteCount: Int {
        data.count
    }

    public func dataString() -> String {
        String(decoding: data, as: UTF8.self)
    }
}

public enum SecretAccessibility: String, Equatable, Sendable {
    case whenUnlockedThisDeviceOnly
}

public struct SecretMetadata: Equatable, Sendable {
    public let reference: HostwrightSecretReference
    public let itemID: UUID
    public let version: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let accessibility: SecretAccessibility
    public let synchronizable: Bool

    public init(
        reference: HostwrightSecretReference,
        itemID: UUID = UUID(),
        version: Int,
        createdAt: Date,
        updatedAt: Date,
        accessibility: SecretAccessibility,
        synchronizable: Bool
    ) {
        self.reference = reference
        self.itemID = itemID
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.accessibility = accessibility
        self.synchronizable = synchronizable
    }
}

public protocol SecretStore: Sendable {
    func readString(reference: HostwrightSecretReference) throws -> String
}

public protocol SecretManager: SecretStore {
    func create(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        itemID: UUID
    ) throws -> SecretMetadata
    func update(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        expectedItemID: UUID
    ) throws -> SecretMetadata
    func listMetadata() throws -> [SecretMetadata]
    func check(reference: HostwrightSecretReference) throws -> SecretMetadata
    func delete(
        reference: HostwrightSecretReference,
        expectedItemID: UUID
    ) throws
}

public extension SecretManager {
    func create(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue
    ) throws -> SecretMetadata {
        try create(reference: reference, value: value, itemID: UUID())
    }

    func update(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue
    ) throws -> SecretMetadata {
        let existing = try check(reference: reference)
        return try update(
            reference: reference,
            value: value,
            expectedItemID: existing.itemID
        )
    }

    func delete(reference: HostwrightSecretReference) throws {
        let existing = try check(reference: reference)
        try delete(
            reference: reference,
            expectedItemID: existing.itemID
        )
    }
}

public struct MacOSKeychainSecretStore: SecretManager, @unchecked Sendable {
    static let ownershipMarker = Data("dev.hostwright.secret.v1".utf8)
    private static let itemLabel = "Hostwright managed secret"
    private let keychain: SecKeychain?
    private let cancellationCheck: @Sendable () throws -> Void

    public init() {
        self.keychain = nil
        self.cancellationCheck = {
            var cancelled = false
            withUnsafeCurrentTask { task in
                cancelled = task?.isCancelled ?? false
            }
            if cancelled {
                throw SecretStoreError.cancelled(
                    "macOS Keychain operation was cancelled before mutation."
                )
            }
        }
    }

    init(cancellationCheck: @escaping @Sendable () throws -> Void) {
        self.keychain = nil
        self.cancellationCheck = cancellationCheck
    }

    init(keychain: SecKeychain) {
        self.keychain = keychain
        self.cancellationCheck = {}
    }

    public func readString(reference: HostwrightSecretReference) throws -> String {
        try HostwrightSecretReference.requireKeychain(reference)
        try cancellationCheck()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        applySearchList(to: &query)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw Self.error(
                for: status,
                operation: "read",
                referenceDescription: reference.redactedDescription
            )
        }
        guard let data = result as? Data else {
            throw SecretStoreError.backendUnavailable(
                "macOS Keychain returned an unsupported value type for \(reference.redactedDescription)."
            )
        }
        guard data.count <= HostwrightSecretValue.maximumByteCount else {
            throw SecretStoreError.invalidValue(
                "macOS Keychain item exceeds the 64 KiB limit for \(reference.redactedDescription)."
            )
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.backendUnavailable(
                "macOS Keychain item data is not valid UTF-8 for \(reference.redactedDescription)."
            )
        }
        return value
    }

    public func create(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        itemID: UUID
    ) throws -> SecretMetadata {
        try HostwrightSecretReference.requireKeychain(reference)
        try cancellationCheck()
        let metadata = StoredMetadata(
            schemaVersion: 1,
            itemVersion: 1,
            itemID: itemID.uuidString.lowercased()
        )
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrGeneric as String: Self.ownershipMarker,
            kSecAttrLabel as String: Self.itemLabel,
            kSecAttrComment as String: try encoded(metadata),
            kSecValueData as String: value.data
        ]
        if let keychain {
            addQuery[kSecUseKeychain as String] = keychain
        }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Self.error(
                for: status,
                operation: "create",
                referenceDescription: reference.redactedDescription
            )
        }

        do {
            let verified = try check(reference: reference)
            guard verified.itemID == itemID, verified.version == 1 else {
                throw SecretStoreError.corruptedMetadata(
                    "Keychain create verification found unexpected metadata for \(reference.redactedDescription)."
                )
            }
            return verified
        } catch {
            var cleanupQuery = managedQuery(reference: reference)
            cleanupQuery[kSecAttrComment as String] = try encoded(metadata)
            let cleanupStatus = SecItemDelete(cleanupQuery as CFDictionary)
            guard cleanupStatus == errSecSuccess || cleanupStatus == errSecItemNotFound else {
                throw SecretStoreError.partialEffect(
                    "Keychain create verification failed and exact compensation also failed for \(reference.redactedDescription)."
                )
            }
            throw error
        }
    }

    public func update(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        expectedItemID: UUID
    ) throws -> SecretMetadata {
        try HostwrightSecretReference.requireKeychain(reference)
        let existing = try managedItem(reference: reference, returnData: true)
        try cancellationCheck()
        guard existing.metadata.itemID == expectedItemID else {
            throw SecretStoreError.concurrentMutation(
                "Keychain item changed concurrently for \(reference.redactedDescription); retry after checking current metadata."
            )
        }
        guard existing.metadata.version < Int.max else {
            throw SecretStoreError.corruptedMetadata(
                "Keychain item version is invalid for \(reference.redactedDescription)."
            )
        }
        guard let priorData = existing.data else {
            throw SecretStoreError.corruptedMetadata(
                "Keychain item data is missing for \(reference.redactedDescription)."
            )
        }
        let nextStored = StoredMetadata(
            schemaVersion: 1,
            itemVersion: existing.metadata.version + 1,
            itemID: existing.metadata.itemID.uuidString.lowercased()
        )
        let nextComment = try encoded(nextStored)
        var query = managedQuery(reference: reference)
        query[kSecAttrComment as String] = existing.comment
        let attributes: [String: Any] = [
            kSecValueData as String: value.data,
            kSecAttrComment as String: nextComment,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: Self.itemLabel
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            throw conditionalMutationMiss(reference: reference)
        }
        guard status == errSecSuccess else {
            throw Self.error(
                for: status,
                operation: "update",
                referenceDescription: reference.redactedDescription
            )
        }

        do {
            let verified = try check(reference: reference)
            guard verified.itemID == expectedItemID,
                  verified.version == nextStored.itemVersion else {
                throw SecretStoreError.corruptedMetadata(
                    "Keychain update verification found unexpected metadata for \(reference.redactedDescription)."
                )
            }
            return verified
        } catch {
            var rollbackQuery = managedQuery(reference: reference)
            rollbackQuery[kSecAttrComment as String] = nextComment
            let rollbackStatus = SecItemUpdate(
                rollbackQuery as CFDictionary,
                [
                    kSecValueData as String: priorData,
                    kSecAttrComment as String: existing.comment
                ] as CFDictionary
            )
            guard rollbackStatus == errSecSuccess else {
                throw SecretStoreError.partialEffect(
                    "Keychain update verification failed and exact rollback also failed for \(reference.redactedDescription)."
                )
            }
            throw error
        }
    }

    public func listMetadata() throws -> [SecretMetadata] {
        try cancellationCheck()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrGeneric as String: Self.ownershipMarker,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        applySearchList(to: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw Self.error(
                for: status,
                operation: "list",
                referenceDescription: "keychain://[REDACTED]"
            )
        }
        let dictionaries: [[String: Any]]
        if let items = result as? [[String: Any]] {
            dictionaries = items
        } else if let item = result as? [String: Any] {
            dictionaries = [item]
        } else {
            throw SecretStoreError.backendUnavailable(
                "macOS Keychain returned an unsupported metadata result."
            )
        }
        return try dictionaries
            .map { try metadata(from: $0, expectedReference: nil).metadata }
            .sorted { $0.reference.rawValue < $1.reference.rawValue }
    }

    public func check(reference: HostwrightSecretReference) throws -> SecretMetadata {
        try HostwrightSecretReference.requireKeychain(reference)
        return try managedItem(reference: reference, returnData: false).metadata
    }

    public func delete(
        reference: HostwrightSecretReference,
        expectedItemID: UUID
    ) throws {
        try HostwrightSecretReference.requireKeychain(reference)
        let existing = try managedItem(reference: reference, returnData: false)
        try cancellationCheck()
        guard existing.metadata.itemID == expectedItemID else {
            throw SecretStoreError.concurrentMutation(
                "Keychain item changed concurrently for \(reference.redactedDescription); retry after checking current metadata."
            )
        }
        var query = managedQuery(reference: reference)
        query[kSecAttrComment as String] = existing.comment
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            throw conditionalMutationMiss(reference: reference)
        }
        guard status == errSecSuccess else {
            throw Self.error(
                for: status,
                operation: "delete",
                referenceDescription: reference.redactedDescription
            )
        }
        let verificationStatus = copyStatus(
            reference: reference,
            requireManaged: false
        )
        guard verificationStatus == errSecItemNotFound else {
            throw SecretStoreError.partialEffect(
                "Keychain exact-delete verification failed for \(reference.redactedDescription)."
            )
        }
    }

    static func error(
        for status: OSStatus,
        operation: String,
        referenceDescription: String
    ) -> SecretStoreError {
        switch status {
        case errSecItemNotFound:
            return .notFound(
                "No local macOS Keychain item was found for \(referenceDescription)."
            )
        case errSecDuplicateItem:
            return .duplicate(
                "A macOS Keychain item already exists for \(referenceDescription)."
            )
        case errSecInteractionNotAllowed, errSecAuthFailed, errAuthorizationInternal:
            return .interactionNotAllowed(
                "macOS Keychain \(operation) requires disallowed user interaction for \(referenceDescription)."
            )
        case errSecUserCanceled:
            return .cancelled(
                "macOS Keychain \(operation) was cancelled for \(referenceDescription)."
            )
        case errSecMissingEntitlement, errSecNoAccessForItem, errAuthorizationDenied:
            return .permissionDenied(
                "macOS Keychain denied \(operation) for \(referenceDescription)."
            )
        case errSecNotAvailable:
            return .backendUnavailable(
                "macOS Keychain is unavailable for \(referenceDescription)."
            )
        case errSecDecode:
            return .corruptedMetadata(
                "macOS Keychain could not decode the item for \(referenceDescription)."
            )
        default:
            return .backendUnavailable(
                "macOS Keychain \(operation) failed with status \(status) for \(referenceDescription)."
            )
        }
    }

    private var authenticationContext: LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private func managedQuery(reference: HostwrightSecretReference) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
            kSecAttrGeneric as String: Self.ownershipMarker,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        applySearchList(to: &query)
        return query
    }

    private func managedItem(
        reference: HostwrightSecretReference,
        returnData: Bool
    ) throws -> ManagedItem {
        try cancellationCheck()
        var query = managedQuery(reference: reference)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = returnData
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw try missingOrUnmanaged(reference: reference)
        }
        guard status == errSecSuccess else {
            throw Self.error(
                for: status,
                operation: "read metadata",
                referenceDescription: reference.redactedDescription
            )
        }
        guard let dictionary = result as? [String: Any] else {
            throw SecretStoreError.backendUnavailable(
                "macOS Keychain returned unsupported metadata for \(reference.redactedDescription)."
            )
        }
        let parsed = try metadata(from: dictionary, expectedReference: reference)
        let data = returnData ? dictionary[kSecValueData as String] as? Data : nil
        return ManagedItem(
            metadata: parsed.metadata,
            comment: parsed.comment,
            data: data
        )
    }

    private func metadata(
        from dictionary: [String: Any],
        expectedReference: HostwrightSecretReference?
    ) throws -> (metadata: SecretMetadata, comment: String) {
        guard dictionary[kSecAttrGeneric as String] as? Data == Self.ownershipMarker,
              let service = dictionary[kSecAttrService as String] as? String,
              let account = dictionary[kSecAttrAccount as String] as? String,
              let comment = dictionary[kSecAttrComment as String] as? String,
              let createdAt = dictionary[kSecAttrCreationDate as String] as? Date,
              let updatedAt = dictionary[kSecAttrModificationDate as String] as? Date else {
            throw SecretStoreError.corruptedMetadata(
                "Hostwright-managed Keychain metadata is incomplete for keychain://[REDACTED]."
            )
        }
        let reference = try HostwrightSecretReference(service: service, account: account)
        guard expectedReference == nil || expectedReference == reference else {
            throw SecretStoreError.corruptedMetadata(
                "Hostwright-managed Keychain identity conflicts with the requested keychain://[REDACTED] item."
            )
        }
        let stored = try decodedMetadata(comment)
        guard stored.schemaVersion == 1,
              stored.itemVersion >= 1,
              let itemID = UUID(uuidString: stored.itemID),
              itemID.uuidString.lowercased() == stored.itemID else {
            throw SecretStoreError.corruptedMetadata(
                "Hostwright-managed Keychain metadata uses an unsupported version for \(reference.redactedDescription)."
            )
        }
        if let accessible = dictionary[kSecAttrAccessible as String] {
            let actual = accessible as? String
            guard actual == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String) else {
                throw SecretStoreError.corruptedMetadata(
                    "Hostwright-managed Keychain access policy is invalid for \(reference.redactedDescription)."
                )
            }
        }
        let synchronizable = dictionary[kSecAttrSynchronizable as String] as? Bool ?? false
        guard !synchronizable else {
            throw SecretStoreError.corruptedMetadata(
                "Hostwright-managed Keychain item unexpectedly allows synchronization for \(reference.redactedDescription)."
            )
        }
        return (
            SecretMetadata(
                reference: reference,
                itemID: itemID,
                version: stored.itemVersion,
                createdAt: createdAt,
                updatedAt: updatedAt,
                accessibility: .whenUnlockedThisDeviceOnly,
                synchronizable: false
            ),
            comment
        )
    }

    private func missingOrUnmanaged(
        reference: HostwrightSecretReference
    ) throws -> SecretStoreError {
        let status = copyStatus(reference: reference, requireManaged: false)
        if status == errSecSuccess {
            return .unmanaged(
                "The exact Keychain item exists but is not owned by Hostwright for \(reference.redactedDescription)."
            )
        }
        if status == errSecItemNotFound {
            return .notFound(
                "No local macOS Keychain item was found for \(reference.redactedDescription)."
            )
        }
        return Self.error(
            for: status,
            operation: "inspect ownership",
            referenceDescription: reference.redactedDescription
        )
    }

    private func copyStatus(
        reference: HostwrightSecretReference,
        requireManaged: Bool
    ) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        applySearchList(to: &query)
        if requireManaged {
            query[kSecAttrGeneric as String] = Self.ownershipMarker
        }
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result)
    }

    private func conditionalMutationMiss(
        reference: HostwrightSecretReference
    ) -> SecretStoreError {
        do {
            _ = try managedItem(reference: reference, returnData: false)
            return .concurrentMutation(
                "Keychain item changed concurrently for \(reference.redactedDescription); retry after checking current metadata."
            )
        } catch let error as SecretStoreError {
            return error
        } catch {
            return .backendUnavailable(
                "macOS Keychain could not classify a conditional mutation failure for \(reference.redactedDescription)."
            )
        }
    }

    private func applySearchList(to query: inout [String: Any]) {
        if let keychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
    }

    private func encoded(_ metadata: StoredMetadata) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let value = String(
            data: try encoder.encode(metadata),
            encoding: .utf8
        ) else {
            throw SecretStoreError.backendUnavailable(
                "Hostwright could not encode Keychain metadata."
            )
        }
        return value
    }

    private func decodedMetadata(_ value: String) throws -> StoredMetadata {
        guard let data = value.data(using: .utf8) else {
            throw SecretStoreError.corruptedMetadata(
                "Hostwright-managed Keychain metadata is not UTF-8."
            )
        }
        do {
            return try JSONDecoder().decode(StoredMetadata.self, from: data)
        } catch {
            throw SecretStoreError.corruptedMetadata(
                "Hostwright-managed Keychain metadata is malformed."
            )
        }
    }
}

private struct StoredMetadata: Codable, Sendable {
    let schemaVersion: Int
    let itemVersion: Int
    let itemID: String
}

private struct ManagedItem: Sendable {
    let metadata: SecretMetadata
    let comment: String
    let data: Data?
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

public struct UnavailableKeychainSecretManager: SecretManager {
    public init() {}

    public func readString(reference: HostwrightSecretReference) throws -> String {
        throw unavailable(reference)
    }

    public func create(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        itemID: UUID
    ) throws -> SecretMetadata {
        throw unavailable(reference)
    }

    public func update(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        expectedItemID: UUID
    ) throws -> SecretMetadata {
        throw unavailable(reference)
    }

    public func listMetadata() throws -> [SecretMetadata] {
        throw SecretStoreError.backendUnavailable(
            "Live macOS Keychain management is not enabled."
        )
    }

    public func check(reference: HostwrightSecretReference) throws -> SecretMetadata {
        throw unavailable(reference)
    }

    public func delete(
        reference: HostwrightSecretReference,
        expectedItemID: UUID
    ) throws {
        throw unavailable(reference)
    }

    private func unavailable(
        _ reference: HostwrightSecretReference
    ) -> SecretStoreError {
        .backendUnavailable(
            "Live macOS Keychain management is not enabled for \(reference.redactedDescription)."
        )
    }
}
