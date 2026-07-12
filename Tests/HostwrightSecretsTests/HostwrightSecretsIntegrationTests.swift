import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import HostwrightSecrets

final class HostwrightSecretsIntegrationTests: XCTestCase {
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
        let suffix = UUID().uuidString.lowercased()
        let reference = try HostwrightSecretReference(
            service: "dev.hostwright.integration.\(suffix)",
            account: "item-\(suffix)"
        )
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
