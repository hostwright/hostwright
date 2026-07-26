import Foundation
import XCTest
@testable import HostwrightStorage

final class StorageProviderContractTests: XCTestCase {
    func testOperationContractIsExact() {
        XCTAssertEqual(
            StorageProviderOperation.allCases.map(\.rawValue),
            [
                "create",
                "observe",
                "attach",
                "detach",
                "snapshot",
                "backup",
                "restore",
                "expand",
                "delete",
                "health",
                "recovery"
            ]
        )
        XCTAssertEqual(
            StorageProviderOperation.allCases.filter(\.mutatesProviderState),
            [.create, .attach, .detach, .snapshot, .backup, .restore, .expand, .delete, .recovery]
        )
    }

    func testDescriptorDigestIsCanonicalAndCaptureTimeFree() throws {
        let first = descriptor(capabilities: Array(capabilities().reversed()))
        let second = descriptor(capabilities: capabilities())

        try StorageProviderDescriptorValidator.validate(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            try first.canonicalSHA256(),
            try second.canonicalSHA256()
        )
        XCTAssertNotNil(
            try first.canonicalSHA256().range(
                of: "^[a-f0-9]{64}$",
                options: .regularExpression
            )
        )
        XCTAssertNotEqual(
            try first.canonicalSHA256(),
            try descriptor(providerVersion: "1.0.1").canonicalSHA256()
        )

        let encoded = try StorageProviderCanonicalJSON.encodeDescriptor(first)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("capturedAt"))
        XCTAssertEqual(
            try StorageProviderCanonicalJSON.decodeDescriptor(from: encoded),
            first
        )
    }

    func testDescriptorRequiresEveryOperationExactlyOnce() {
        let missing = descriptor(
            capabilities: capabilities().filter { $0.operation != .delete }
        )
        XCTAssertThrowsError(try StorageProviderDescriptorValidator.validate(missing)) {
            XCTAssertEqual(
                $0 as? StorageProviderDescriptorError,
                .missingCapability(.delete)
            )
        }

        let duplicate = descriptor(
            capabilities: capabilities() + [
                StorageProviderCapability(
                    operation: .delete,
                    state: .blocked,
                    reason: "blocked for test"
                )
            ]
        )
        XCTAssertThrowsError(try StorageProviderDescriptorValidator.validate(duplicate)) {
            XCTAssertEqual(
                $0 as? StorageProviderDescriptorError,
                .duplicateCapability(.delete)
            )
        }
    }

    func testCapabilityNegotiationFailsClosedForEveryNonAvailableState() throws {
        let available = descriptor()
        XCTAssertNoThrow(
            try StorageProviderCapabilityNegotiator.requireAvailable(
                .snapshot,
                in: available
            )
        )

        let states: [(StorageProviderCapabilityState, StorageProviderCapabilityError)] = [
            (
                .unavailable,
                .unavailable(operation: .snapshot, reason: "not implemented")
            ),
            (
                .degraded,
                .degraded(operation: .snapshot, reason: "provider unhealthy")
            ),
            (
                .blocked,
                .blocked(operation: .snapshot, reason: "operator policy")
            )
        ]
        for (state, expected) in states {
            let value = descriptor(
                capabilities: capabilities().map {
                    $0.operation == .snapshot
                        ? StorageProviderCapability(
                            operation: .snapshot,
                            state: state,
                            reason: expectedReason(for: state)
                        )
                        : $0
                }
            )
            XCTAssertThrowsError(
                try StorageProviderCapabilityNegotiator.requireAvailable(
                    .snapshot,
                    in: value
                )
            ) {
                XCTAssertEqual($0 as? StorageProviderCapabilityError, expected)
            }
        }
    }

    func testDescriptorRejectsVersionIdentifierReasonAndBoundViolations() {
        let invalid: [(StorageProviderDescriptor, StorageProviderDescriptorError)] = [
            (
                descriptor(apiVersion: 2),
                .unsupportedAPIVersion(2)
            ),
            (
                descriptor(protocolVersion: 2),
                .unsupportedProtocolVersion(2)
            ),
            (
                descriptor(providerID: "../provider"),
                .invalidProviderID
            ),
            (
                descriptor(providerVersion: ""),
                .invalidProviderVersion
            ),
            (
                descriptor(maximumRequestBytes: StorageProviderContract.maximumRequestBytes + 1),
                .invalidRequestBound(StorageProviderContract.maximumRequestBytes + 1)
            ),
            (
                descriptor(maximumResultBytes: StorageProviderContract.maximumResultBytes + 1),
                .invalidResultBound(StorageProviderContract.maximumResultBytes + 1)
            )
        ]

        for (value, expected) in invalid {
            XCTAssertThrowsError(try StorageProviderDescriptorValidator.validate(value)) {
                XCTAssertEqual($0 as? StorageProviderDescriptorError, expected)
            }
        }

        let badReason = descriptor(
            capabilities: capabilities().map {
                $0.operation == .backup
                    ? StorageProviderCapability(
                        operation: .backup,
                        state: .available,
                        reason: "\u{0000}"
                    )
                    : $0
            }
        )
        XCTAssertThrowsError(try StorageProviderDescriptorValidator.validate(badReason)) {
            XCTAssertEqual(
                $0 as? StorageProviderDescriptorError,
                .invalidCapabilityReason(.backup)
            )
        }
    }

    func testFailureBoundsAndRedactsDiagnostics() {
        let secret = "sensitive-token"
        let failure = StorageProviderFailure(
            category: .ambiguousEffect,
            retryDisposition: .resumeFromCheckpoint,
            recoveryDisposition: .safeHold,
            diagnostic: String(repeating: "é", count: 4_096) + secret,
            guidance: String(repeating: "g", count: 2_048) + secret,
            sensitiveValues: [secret]
        )

        XCTAssertLessThanOrEqual(
            failure.diagnostic.utf8.count,
            StorageProviderContract.maximumDiagnosticBytes
        )
        XCTAssertLessThanOrEqual(
            failure.guidance.utf8.count,
            StorageProviderContract.maximumGuidanceBytes
        )
        XCTAssertFalse(failure.diagnostic.contains(secret))
        XCTAssertFalse(failure.guidance.contains(secret))
        XCTAssertTrue(failure.requiresObservationBeforeRetry)
    }

    private func descriptor(
        apiVersion: Int = StorageProviderContract.apiVersion,
        protocolVersion: Int = StorageProviderContract.protocolVersion,
        providerID: String = "hostwright-local",
        providerVersion: String = "1.0.0",
        capabilities: [StorageProviderCapability]? = nil,
        maximumRequestBytes: Int = StorageProviderContract.maximumRequestBytes,
        maximumResultBytes: Int = StorageProviderContract.maximumResultBytes
    ) -> StorageProviderDescriptor {
        StorageProviderDescriptor(
            apiVersion: apiVersion,
            protocolVersion: protocolVersion,
            providerID: providerID,
            providerVersion: providerVersion,
            capabilities: capabilities ?? self.capabilities(),
            maximumRequestBytes: maximumRequestBytes,
            maximumResultBytes: maximumResultBytes
        )
    }

    private func capabilities() -> [StorageProviderCapability] {
        StorageProviderOperation.allCases.map {
            StorageProviderCapability(
                operation: $0,
                state: .available,
                reason: "implemented"
            )
        }
    }

    private func expectedReason(
        for state: StorageProviderCapabilityState
    ) -> String {
        switch state {
        case .available:
            "implemented"
        case .unavailable:
            "not implemented"
        case .degraded:
            "provider unhealthy"
        case .blocked:
            "operator policy"
        }
    }
}
