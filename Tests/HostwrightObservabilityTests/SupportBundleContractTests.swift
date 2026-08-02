import Foundation
import XCTest
@testable import HostwrightObservability

final class SupportBundleContractTests: XCTestCase {
    func testContractIsVersionedFixedAndBounded() {
        XCTAssertEqual(HostwrightSupportBundleContract.schemaVersion, 1)
        XCTAssertEqual(HostwrightSupportBundleContract.source, "hostwright.support-bundle")
        XCTAssertEqual(HostwrightSupportBundleContract.maximumLogs, 200)
        XCTAssertEqual(HostwrightSupportBundleContract.maximumEvents, 200)
        XCTAssertEqual(HostwrightSupportBundleContract.maximumTraces, 20)
        XCTAssertEqual(HostwrightSupportBundleContract.maximumOperations, 200)
        XCTAssertEqual(HostwrightSupportBundleContract.maximumEvidence, 200)
        XCTAssertLessThanOrEqual(
            HostwrightSupportBundleContract.maximumPlaintextBytes,
            HostwrightSupportBundleContract.maximumEncryptedBytes
        )
        XCTAssertLessThanOrEqual(
            HostwrightSupportBundleContract.maximumSectionBytes,
            HostwrightSupportBundleContract.maximumPlaintextBytes
        )
    }

    func testRecipientReferenceIsNonSecretBoundedAndArgumentSafe() {
        XCTAssertTrue(HostwrightSupportBundleContract.isValidRecipientReference("support@example.test"))
        XCTAssertTrue(HostwrightSupportBundleContract.isValidRecipientReference("Hostwright Support 2026"))
        XCTAssertFalse(HostwrightSupportBundleContract.isValidRecipientReference(""))
        XCTAssertFalse(HostwrightSupportBundleContract.isValidRecipientReference("-p password"))
        XCTAssertFalse(HostwrightSupportBundleContract.isValidRecipientReference("recipient\nother"))
        XCTAssertFalse(HostwrightSupportBundleContract.isValidRecipientReference(" recipient"))
        XCTAssertFalse(HostwrightSupportBundleContract.isValidRecipientReference(String(repeating: "a", count: 129)))
        XCTAssertTrue(HostwrightSupportBundleContract.isValidSHA256(String(repeating: "a", count: 64)))
        XCTAssertFalse(HostwrightSupportBundleContract.isValidSHA256(String(repeating: "A", count: 64)))
    }

    func testErrorCodesAreStableAndDistinct() {
        let errors: [HostwrightSupportBundleError] = [
            .invalidContract, .previewChanged, .unsafeOutputPath, .sectionLimitExceeded,
            .plaintextLimitExceeded, .invalidRecipientReference, .encryptionUnavailable,
            .encryptionFailed, .receiptUnavailable, .bundleIdentityChanged,
            .recoveryRequired, .recoverySafeHold, .cancelled
        ]
        XCTAssertEqual(Set(errors.map(\.code)).count, errors.count)
        XCTAssertTrue(errors.allSatisfy { $0.description.hasPrefix($0.code) })
    }
}
