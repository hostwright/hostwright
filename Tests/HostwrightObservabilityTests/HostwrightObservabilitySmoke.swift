import XCTest
@testable import HostwrightObservability

final class HostwrightObservabilityTests: XCTestCase {
    func testSecretRedactorReplacesConfiguredSecrets() {
        let redacted = SecretRedactor.redact(
            value: "token=abc123",
            secretKeys: ["abc123"]
        )

        XCTAssertEqual(redacted, "token=[REDACTED]")
    }

    func testEmptySecretDoesNotChangeValue() {
        let redacted = SecretRedactor.redact(
            value: "token=abc123",
            secretKeys: [""]
        )

        XCTAssertEqual(redacted, "token=abc123")
    }

    func testKeychainSecretReferenceIsRedactedWithoutExactSecretList() {
        let redacted = SecretRedactor.redact(
            value: "using keychain://hostwright.api/api-token",
            secretKeys: []
        )

        XCTAssertEqual(redacted, "using keychain://[REDACTED]")
    }
}
