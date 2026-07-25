import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import HostwrightSecrets

final class HostwrightSecretsIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try cleanupTestOwnedManagedItems()
    }

    override func tearDownWithError() throws {
        try cleanupTestOwnedManagedItems()
    }

    func testLiveMacOSKeychainStoreCRUDMetadataAndExactCleanup() throws {
        let reference = try uniqueReference()
        let store = MacOSKeychainSecretStore()
        defer { try? store.delete(reference: reference) }

        let created = try store.create(
            reference: reference,
            value: try HostwrightSecretValue("initial-secret")
        )
        XCTAssertEqual(created.reference, reference)
        XCTAssertEqual(created.version, 1)
        XCTAssertEqual(created.accessibility, .whenUnlockedThisDeviceOnly)
        XCTAssertFalse(created.synchronizable)
        XCTAssertEqual(try store.readString(reference: reference), "initial-secret")
        XCTAssertEqual(try store.check(reference: reference), created)
        XCTAssertTrue(try store.listMetadata().contains(created))

        XCTAssertThrowsError(
            try store.create(
                reference: reference,
                value: try HostwrightSecretValue("duplicate-secret")
            )
        ) { error in
            guard case .duplicate = error as? SecretStoreError else {
                return XCTFail("Expected duplicate, got \(error).")
            }
        }

        let updated = try store.update(
            reference: reference,
            value: try HostwrightSecretValue("rotated-secret")
        )
        XCTAssertEqual(updated.reference, reference)
        XCTAssertEqual(updated.itemID, created.itemID)
        XCTAssertEqual(updated.version, 2)
        XCTAssertEqual(updated.createdAt, created.createdAt)
        XCTAssertGreaterThanOrEqual(updated.updatedAt, created.updatedAt)
        XCTAssertEqual(try store.readString(reference: reference), "rotated-secret")

        try store.delete(reference: reference)
        XCTAssertEqual(copyStatus(for: reference), errSecItemNotFound)
        XCTAssertThrowsError(try store.check(reference: reference)) { error in
            guard case .notFound = error as? SecretStoreError else {
                return XCTFail("Expected notFound, got \(error).")
            }
        }
        XCTAssertThrowsError(try store.delete(reference: reference)) { error in
            guard case .notFound = error as? SecretStoreError else {
                return XCTFail("Expected notFound, got \(error).")
            }
        }
    }

    func testLiveMacOSKeychainStorePreservesLegacyReadOnlyItems() throws {
        let secret = "legacy-read-only-\(UUID().uuidString)"
        let item = try addLiveKeychainItem(data: Data(secret.utf8))
        defer { _ = SecItemDelete(item.deleteQuery as CFDictionary) }

        let store = MacOSKeychainSecretStore()
        XCTAssertEqual(try store.readString(reference: item.reference), secret)
        XCTAssertThrowsError(
            try store.update(
                reference: item.reference,
                value: try HostwrightSecretValue("replacement")
            )
        ) { error in
            guard case .unmanaged = error as? SecretStoreError else {
                return XCTFail("Expected unmanaged, got \(error).")
            }
        }
        XCTAssertThrowsError(try store.delete(reference: item.reference)) { error in
            guard case .unmanaged = error as? SecretStoreError else {
                return XCTFail("Expected unmanaged, got \(error).")
            }
        }
        XCTAssertEqual(try store.readString(reference: item.reference), secret)
    }

    func testLiveMacOSKeychainStoreCreateRaceHasOneWinnerAndCleansUp() async throws {
        let reference = try uniqueReference()
        let store = MacOSKeychainSecretStore()
        defer { try? store.delete(reference: reference) }

        let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for suffix in ["one", "two"] {
                group.addTask {
                    do {
                        _ = try store.create(
                            reference: reference,
                            value: try HostwrightSecretValue("race-\(suffix)")
                        )
                        return "created"
                    } catch SecretStoreError.duplicate {
                        return "duplicate"
                    } catch {
                        return "unexpected:\(String(describing: error))"
                    }
                }
            }
            var values: [String] = []
            for await value in group {
                values.append(value)
            }
            return values.sorted()
        }

        XCTAssertEqual(outcomes, ["created", "duplicate"])
        XCTAssertEqual(try store.check(reference: reference).version, 1)
    }

    func testManagedItemIdentityRejectsStaleUpdateAndDeleteAfterReplacement() throws {
        let store = MacOSKeychainSecretStore()
        let reference = try uniqueReference()
        let original = try store.create(
            reference: reference,
            value: try HostwrightSecretValue("original")
        )
        let originalComment = try managedComment(reference: reference)
        try store.delete(
            reference: reference,
            expectedItemID: original.itemID
        )
        let replacementItemID = UUID()
        let replacement = try store.create(
            reference: reference,
            value: try HostwrightSecretValue("replacement"),
            itemID: replacementItemID
        )
        defer {
            try? store.delete(
                reference: reference,
                expectedItemID: replacementItemID
            )
        }
        XCTAssertEqual(replacement.itemID, replacementItemID)
        let replacementComment = try managedComment(reference: reference)
        XCTAssertNotEqual(originalComment, replacementComment)

        XCTAssertThrowsError(
            try store.update(
                reference: reference,
                value: try HostwrightSecretValue("stale-update"),
                expectedItemID: original.itemID
            )
        ) { error in
            guard case .concurrentMutation = error as? SecretStoreError else {
                return XCTFail("Expected concurrentMutation, got \(error).")
            }
        }
        XCTAssertThrowsError(
            try store.delete(
                reference: reference,
                expectedItemID: original.itemID
            )
        ) { error in
            guard case .concurrentMutation = error as? SecretStoreError else {
                return XCTFail("Expected concurrentMutation, got \(error).")
            }
        }

        let staleQuery = managedQuery(
            reference: reference,
            comment: originalComment
        )
        XCTAssertEqual(
            SecItemUpdate(
                staleQuery as CFDictionary,
                [kSecValueData as String: Data("stale-update".utf8)] as CFDictionary
            ),
            errSecItemNotFound
        )
        XCTAssertEqual(
            SecItemDelete(staleQuery as CFDictionary),
            errSecItemNotFound
        )
        XCTAssertEqual(
            try store.readString(reference: reference),
            "replacement"
        )
    }

    func testCancellationBeforeMutationLeavesNoKeychainItem() throws {
        let reference = try uniqueReference()
        let store = MacOSKeychainSecretStore(cancellationCheck: {
            throw SecretStoreError.cancelled("Keychain operation was cancelled before mutation.")
        })

        XCTAssertThrowsError(
            try store.create(
                reference: reference,
                value: try HostwrightSecretValue("never-written")
            )
        ) { error in
            guard case .cancelled = error as? SecretStoreError else {
                return XCTFail("Expected cancelled, got \(error).")
            }
        }
        XCTAssertEqual(copyStatus(for: reference), errSecItemNotFound)
    }

    func testLockedTemporaryKeychainFailsWithoutInteractionAndCleansUp() throws {
        var priorInteraction = DarwinBoolean(false)
        XCTAssertEqual(
            SecKeychainGetUserInteractionAllowed(&priorInteraction),
            errSecSuccess
        )
        XCTAssertEqual(
            SecKeychainSetUserInteractionAllowed(false),
            errSecSuccess
        )
        defer {
            _ = SecKeychainSetUserInteractionAllowed(
                priorInteraction.boolValue
            )
        }

        var priorDefaultKeychain: SecKeychain?
        var priorSearchList: CFArray?
        XCTAssertEqual(
            SecKeychainCopyDefault(&priorDefaultKeychain),
            errSecSuccess
        )
        XCTAssertEqual(
            SecKeychainCopySearchList(&priorSearchList),
            errSecSuccess
        )
        let savedDefault = try XCTUnwrap(priorDefaultKeychain)
        let savedSearchList = try XCTUnwrap(priorSearchList)

        let keychainPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-locked-\(UUID().uuidString).keychain-db"
            )
            .path
        let password = Data("hostwright-\(UUID().uuidString)".utf8)
        var keychain: SecKeychain?
        let createStatus = keychainPath.withCString { path in
            password.withUnsafeBytes { bytes in
                SecKeychainCreate(
                    path,
                    UInt32(bytes.count),
                    bytes.baseAddress,
                    false,
                    nil,
                    &keychain
                )
            }
        }
        XCTAssertEqual(createStatus, errSecSuccess)
        let createdKeychain = try XCTUnwrap(keychain)
        XCTAssertEqual(SecKeychainSetDefault(savedDefault), errSecSuccess)
        XCTAssertEqual(
            SecKeychainSetSearchList(savedSearchList),
            errSecSuccess
        )
        defer {
            password.withUnsafeBytes { bytes in
                _ = SecKeychainUnlock(
                    createdKeychain,
                    UInt32(bytes.count),
                    bytes.baseAddress,
                    true
                )
            }
            _ = SecKeychainDelete(createdKeychain)
            _ = SecKeychainSetDefault(savedDefault)
            _ = SecKeychainSetSearchList(savedSearchList)
        }

        let reference = try uniqueReference()
        let store = MacOSKeychainSecretStore(keychain: createdKeychain)
        _ = try store.create(
            reference: reference,
            value: try HostwrightSecretValue("temporary-locked-secret")
        )
        XCTAssertEqual(SecKeychainLock(createdKeychain), errSecSuccess)

        let readStartedAt = Date()
        XCTAssertThrowsError(try store.readString(reference: reference)) { error in
            guard case .interactionNotAllowed(let message) = error as? SecretStoreError else {
                return XCTFail("Expected interactionNotAllowed, got \(error).")
            }
            XCTAssertFalse(message.contains("temporary-locked-secret"))
            XCTAssertFalse(message.contains(reference.service))
            XCTAssertFalse(message.contains(reference.account))
        }
        XCTAssertLessThan(Date().timeIntervalSince(readStartedAt), 5)
        XCTAssertEqual(
            SecKeychainSetUserInteractionAllowed(
                priorInteraction.boolValue
            ),
            errSecSuccess
        )

        let unlockStatus = password.withUnsafeBytes { bytes in
            SecKeychainUnlock(
                createdKeychain,
                UInt32(bytes.count),
                bytes.baseAddress,
                true
            )
        }
        XCTAssertEqual(unlockStatus, errSecSuccess)
        try store.delete(reference: reference)
        XCTAssertTrue(try store.listMetadata().isEmpty)
    }

    func testLiveMacOSKeychainStoreReadsAndExactlyDeletesUniqueItem() throws {
        let secret = "hostwright-keychain-proof-\(UUID().uuidString)"
        let item = try addLiveKeychainItem(data: Data(secret.utf8))
        var cleanupRequired = true
        defer {
            if cleanupRequired {
                XCTAssertEqual(SecItemDelete(item.deleteQuery as CFDictionary), errSecSuccess)
            }
        }

        let store = MacOSKeychainSecretStore()
        XCTAssertEqual(try store.readString(reference: item.reference), secret)

        let deleteStatus = SecItemDelete(item.deleteQuery as CFDictionary)
        XCTAssertEqual(deleteStatus, errSecSuccess)
        cleanupRequired = deleteStatus != errSecSuccess
        XCTAssertEqual(copyStatus(for: item.reference), errSecItemNotFound)
        XCTAssertThrowsError(try store.readString(reference: item.reference)) { error in
            guard case .notFound(let message) = error as? SecretStoreError else {
                return XCTFail("Expected notFound, got \(error).")
            }
            XCTAssertTrue(message.contains(item.reference.redactedDescription))
            XCTAssertFalse(message.contains(item.reference.service))
            XCTAssertFalse(message.contains(item.reference.account))
            XCTAssertFalse(message.contains(secret))
        }
    }

    func testLiveMacOSKeychainStoreRejectsNonUTF8DataAndCleansUp() throws {
        let item = try addLiveKeychainItem(data: Data([0xC3, 0x28]))
        var cleanupRequired = true
        defer {
            if cleanupRequired {
                XCTAssertEqual(SecItemDelete(item.deleteQuery as CFDictionary), errSecSuccess)
            }
        }

        XCTAssertThrowsError(try MacOSKeychainSecretStore().readString(reference: item.reference)) { error in
            guard case .backendUnavailable(let message) = error as? SecretStoreError else {
                return XCTFail("Expected backendUnavailable, got \(error).")
            }
            XCTAssertTrue(message.contains("not valid UTF-8"))
            XCTAssertFalse(message.contains(item.reference.service))
            XCTAssertFalse(message.contains(item.reference.account))
        }

        let deleteStatus = SecItemDelete(item.deleteQuery as CFDictionary)
        XCTAssertEqual(deleteStatus, errSecSuccess)
        cleanupRequired = deleteStatus != errSecSuccess
        XCTAssertEqual(copyStatus(for: item.reference), errSecItemNotFound)
    }

    private func addLiveKeychainItem(data: Data) throws -> LiveKeychainItem {
        let reference = try uniqueReference()
        let authenticationContext = noninteractiveAuthenticationContext()
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        var addQuery = deleteQuery
        addQuery[kSecValueData as String] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "HostwrightSecretsLiveKeychainIntegration",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "SecItemAdd failed with status \(status)."]
            )
        }
        return LiveKeychainItem(reference: reference, deleteQuery: deleteQuery)
    }

    private func managedComment(
        reference: HostwrightSecretReference
    ) throws -> String {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            managedQuery(reference: reference, comment: nil)
                .merging([
                    kSecReturnAttributes as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]) { _, new in new } as CFDictionary,
            &result
        )
        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let comment = attributes[kSecAttrComment as String] as? String else {
            throw SecretStoreError.backendUnavailable(
                "Unable to read managed-item test metadata."
            )
        }
        return comment
    }

    private func managedQuery(
        reference: HostwrightSecretReference,
        comment: String?
    ) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
            kSecAttrSynchronizable as String: false,
            kSecAttrGeneric as String: MacOSKeychainSecretStore.ownershipMarker,
            kSecUseAuthenticationContext as String: context
        ]
        if let comment {
            query[kSecAttrComment as String] = comment
        }
        return query
    }

    private func uniqueReference() throws -> HostwrightSecretReference {
        let suffix = UUID().uuidString.lowercased()
        return try HostwrightSecretReference(
            service: "dev.hostwright.integration.\(suffix)",
            account: "item-\(suffix)"
        )
    }

    private func cleanupTestOwnedManagedItems() throws {
        let context = noninteractiveAuthenticationContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrGeneric as String: MacOSKeychainSecretStore.ownershipMarker,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.backendUnavailable(
                "Unable to enumerate test-owned Keychain metadata."
            )
        }
        let items: [[String: Any]]
        if let many = result as? [[String: Any]] {
            items = many
        } else if let one = result as? [String: Any] {
            items = [one]
        } else {
            throw SecretStoreError.backendUnavailable(
                "Keychain returned unsupported test-cleanup metadata."
            )
        }
        for item in items {
            guard let service = item[kSecAttrService as String] as? String,
                  let account = item[kSecAttrAccount as String] as? String,
                  service.hasPrefix("dev.hostwright.integration.") else {
                continue
            }
            let exact: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrGeneric as String: MacOSKeychainSecretStore.ownershipMarker,
                kSecUseAuthenticationContext as String: context
            ]
            let deleteStatus = SecItemDelete(exact as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw SecretStoreError.backendUnavailable(
                    "Unable to clean exact test-owned Keychain metadata."
                )
            }
        }
    }

    private func copyStatus(for reference: HostwrightSecretReference) -> OSStatus {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: noninteractiveAuthenticationContext()
        ]
        return SecItemCopyMatching(query as CFDictionary, &result)
    }

    private func noninteractiveAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}

private struct LiveKeychainItem {
    let reference: HostwrightSecretReference
    let deleteQuery: [String: Any]
}
