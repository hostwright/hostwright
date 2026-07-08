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

    func testSecretReferenceRejectsUnsupportedShapes() {
        for value in ["", "env://hostwright.api/api-token", "keychain://missing-account", "keychain:///account", "keychain://service/", "keychain://bad service/account"] {
            XCTAssertThrowsError(try HostwrightSecretReference.parse(value), value)
        }
    }

    func testFakeKeychainBackendReturnsConfiguredValuesAndUnavailableStoreFailsClosed() throws {
        let reference = try HostwrightSecretReference.parse("keychain://hostwright.api/api-token")
        let fakeStore = FakeKeychainSecretStore(values: [reference: "token=fake-secret"])

        XCTAssertEqual(try fakeStore.readString(reference: reference), "token=fake-secret")
        XCTAssertThrowsError(try UnavailableKeychainSecretStore().readString(reference: reference)) { error in
            XCTAssertTrue(String(describing: error).contains("not enabled"))
            XCTAssertFalse(String(describing: error).contains("hostwright.api"))
            XCTAssertFalse(String(describing: error).contains("api-token"))
        }
    }
}
