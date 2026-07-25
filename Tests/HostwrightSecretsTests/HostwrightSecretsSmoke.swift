import Foundation
import HostwrightTestSupport
import Security
import XCTest
@testable import HostwrightSecrets

final class HostwrightSecretsTests: XCTestCase {
    func testSecretReferenceParsesKeychainURI() throws {
        let reference = try HostwrightSecretReference.parse("keychain://hostwright.api/api-token")

        XCTAssertEqual(reference.service, "hostwright.api")
        XCTAssertEqual(reference.account, "api-token")
        XCTAssertEqual(reference.rawValue, "keychain://hostwright.api/api-token")
        XCTAssertEqual(reference.redactedDescription, "keychain://[REDACTED]")
    }

    func testSecretReferenceParsesEverySupportedProviderShape() throws {
        let cases: [(String, HostwrightSecretProviderKind, String, String)] = [
            ("keychain://hostwright.api/api-token", .keychain, "hostwright.api", "api-token"),
            ("env-file:///Users/dev/.config/hostwright.env#API_TOKEN", .environmentFile, "/Users/dev/.config/hostwright.env", "API_TOKEN"),
            ("local-file:///Users/dev/.config/api-token", .localFile, "/Users/dev/.config/api-token", ""),
            ("external://vault/api-token", .external, "vault", "api-token"),
            ("plugin://team-secrets/api-token", .plugin, "team-secrets", "api-token")
        ]

        for (rawValue, kind, service, account) in cases {
            let reference = try HostwrightSecretReference.parse(rawValue)
            XCTAssertEqual(reference.providerKind, kind)
            XCTAssertEqual(reference.service, service)
            XCTAssertEqual(reference.account, account)
            XCTAssertEqual(reference.rawValue, rawValue)
            XCTAssertEqual(
                reference.redactedDescription,
                "\(kind.rawValue)://[REDACTED]"
            )
        }
    }

    func testSecretReferenceRejectsUnsupportedShapes() {
        for value in [
            "",
            "env://hostwright.api/api-token",
            "keychain://missing-account",
            "keychain:///account",
            "keychain://service/",
            "keychain://bad service/account",
            "env-file://relative.env#TOKEN",
            "env-file:///Users/dev/secrets.env#1TOKEN",
            "local-file://relative-token",
            "external://provider/item/extra",
            "external://vault:prod/item",
            "plugin://-provider/item",
            "plugin://provider/"
        ] {
            XCTAssertThrowsError(try HostwrightSecretReference.parse(value), value)
        }
    }

    func testKeychainStoreRejectsNonKeychainReferencesBeforeBackendAccess() throws {
        let reference = try HostwrightSecretReference.parse(
            "local-file:///Users/dev/.config/api-token"
        )

        XCTAssertThrowsError(
            try MacOSKeychainSecretStore().readString(reference: reference)
        ) { error in
            guard case .invalidReference(let message) = error as? SecretStoreError else {
                return XCTFail("Expected invalidReference, got \(error).")
            }
            XCTAssertTrue(message.contains("keychain://"))
            XCTAssertFalse(message.contains("/Users/dev"))
        }
    }

    func testInMemorySecretStoreReturnsConfiguredValuesAndUnavailableStoreFailsClosed() throws {
        let reference = try HostwrightSecretReference.parse("keychain://hostwright.api/api-token")
        let inMemoryStore = InMemorySecretStore(values: [reference: "token=synthetic-secret"])

        XCTAssertEqual(try inMemoryStore.readString(reference: reference), "token=synthetic-secret")
        XCTAssertThrowsError(try UnavailableKeychainSecretStore().readString(reference: reference)) { error in
            XCTAssertTrue(String(describing: error).contains("not enabled"))
            XCTAssertFalse(String(describing: error).contains("hostwright.api"))
            XCTAssertFalse(String(describing: error).contains("api-token"))
        }
    }

    func testSecretValueAcceptsUTF8ThroughMaximumSize() throws {
        let bytes = Data(repeating: Character("a").asciiValue!, count: HostwrightSecretValue.maximumByteCount)
        let value = try HostwrightSecretValue(utf8Data: bytes)

        XCTAssertEqual(value.byteCount, HostwrightSecretValue.maximumByteCount)
    }

    func testSecretValueRejectsOversizedAndMalformedUTF8() {
        XCTAssertThrowsError(
            try HostwrightSecretValue(
                utf8Data: Data(
                    repeating: Character("a").asciiValue!,
                    count: HostwrightSecretValue.maximumByteCount + 1
                )
            )
        ) { error in
            guard case .invalidValue(let message) = error as? SecretStoreError else {
                return XCTFail("Expected invalidValue, got \(error).")
            }
            XCTAssertTrue(message.contains("64 KiB"))
        }

        XCTAssertThrowsError(try HostwrightSecretValue(utf8Data: Data([0xC3, 0x28]))) { error in
            guard case .invalidValue(let message) = error as? SecretStoreError else {
                return XCTFail("Expected invalidValue, got \(error).")
            }
            XCTAssertTrue(message.contains("UTF-8"))
        }
        XCTAssertThrowsError(
            try HostwrightSecretValue(utf8Data: Data([0x61, 0x00, 0x62]))
        ) { error in
            guard case .invalidValue(let message) = error as? SecretStoreError else {
                return XCTFail("Expected invalidValue, got \(error).")
            }
            XCTAssertTrue(message.contains("null bytes"))
        }
    }

    func testKeychainStatusErrorsRemainStableAndRedacted() {
        let duplicate = MacOSKeychainSecretStore.error(
            for: errSecDuplicateItem,
            operation: "create",
            referenceDescription: "keychain://[REDACTED]"
        )
        guard case .duplicate(let duplicateMessage) = duplicate else {
            return XCTFail("Expected duplicate, got \(duplicate).")
        }
        XCTAssertFalse(duplicateMessage.contains("service"))
        XCTAssertFalse(duplicateMessage.contains("account"))

        let locked = MacOSKeychainSecretStore.error(
            for: errSecInteractionNotAllowed,
            operation: "read",
            referenceDescription: "keychain://[REDACTED]"
        )
        guard case .interactionNotAllowed = locked else {
            return XCTFail("Expected interactionNotAllowed, got \(locked).")
        }

        let denied = MacOSKeychainSecretStore.error(
            for: errSecMissingEntitlement,
            operation: "delete",
            referenceDescription: "keychain://[REDACTED]"
        )
        guard case .permissionDenied = denied else {
            return XCTFail("Expected permissionDenied, got \(denied).")
        }

        let cancelled = MacOSKeychainSecretStore.error(
            for: errSecUserCanceled,
            operation: "update",
            referenceDescription: "keychain://[REDACTED]"
        )
        guard case .cancelled = cancelled else {
            return XCTFail("Expected cancelled, got \(cancelled).")
        }
    }
}
