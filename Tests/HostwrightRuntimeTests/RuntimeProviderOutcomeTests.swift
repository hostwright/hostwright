import XCTest
@testable import HostwrightRuntime

final class RuntimeProviderOutcomeTests: XCTestCase {
    func testEveryStableFailureCategoryHasDeterministicGuidanceAndAuditShape() throws {
        for category in RuntimeFailureCategory.allCases {
            let failure = RuntimeNormalizedFailure(
                category: category,
                retryDisposition: category == .partialEffect ? .resumeFromCheckpoint : .never,
                recoveryDisposition: category == .partialEffect ? .resume : .none,
                providerID: "apple-container-cli",
                providerVersion: "1.1.0",
                operationID: "operation-1",
                diagnostic: "diagnostic",
                guidance: "guidance"
            )
            let data = try JSONEncoder().encode(failure)
            XCTAssertEqual(try JSONDecoder().decode(RuntimeNormalizedFailure.self, from: data), failure)
            XCTAssertFalse(failure.providerID.isEmpty)
            XCTAssertFalse(failure.guidance.isEmpty)
        }
    }

    func testProviderSpecificErrorsNormalizeWithoutLeakingSecrets() {
        let secret = "phase03-secret-token"
        let cases: [(RuntimeAdapterError, RuntimeFailureCategory, RuntimeRetryDisposition)] = [
            (.runtimeUnavailable(secret), .unavailable, .safeAfterObservation),
            (.unsupportedRuntime(secret), .incompatible, .never),
            (.commandRejected(classification: .mutating, message: secret), .rejected, .never),
            (.permissionDenied(secret), .permissionDenied, .never),
            (.outputParseFailed(secret), .invalidResponse, .safeAfterObservation),
            (.commandTimedOut(command: "container start", partialOutput: secret, partialError: ""), .timedOut, .safeAfterObservation),
            (.commandCancelled(command: "container start", partialOutput: secret, partialError: ""), .cancelled, .safeAfterObservation),
            (.commandOutputLimitExceeded(command: "container list", partialOutput: secret, partialError: ""), .outputLimited, .safeAfterObservation),
            (.commandProcessTreeViolation(command: "container", partialOutput: secret, partialError: ""), .crashed, .safeAfterObservation),
            (.managedRestartStartFailedAfterStop(message: secret, standardError: ""), .partialEffect, .resumeFromCheckpoint)
        ]

        for (error, category, retry) in cases {
            let failure = RuntimeNormalizedFailure.normalize(
                error,
                providerID: "apple-container-cli",
                providerVersion: "1.1.0",
                operationID: "operation-1"
            )
            XCTAssertEqual(failure.category, category)
            XCTAssertEqual(failure.retryDisposition, retry)
            XCTAssertFalse(failure.diagnostic.contains(secret))
            XCTAssertEqual(failure.requiresObservationBeforeRetry, retry != .never)
        }
    }

    func testDiagnosticAndGuidanceAreBounded() {
        let failure = RuntimeNormalizedFailure(
            category: .ambiguousEffect,
            retryDisposition: .safeAfterObservation,
            recoveryDisposition: .reobserve,
            providerID: String(repeating: "p", count: 1_000),
            providerVersion: String(repeating: "v", count: 1_000),
            operationID: String(repeating: "o", count: 1_000),
            diagnostic: String(repeating: "d", count: 10_000),
            guidance: String(repeating: "g", count: 10_000)
        )

        XCTAssertLessThanOrEqual(failure.providerID.utf8.count, 256)
        XCTAssertLessThanOrEqual(failure.providerVersion.utf8.count, 256)
        XCTAssertLessThanOrEqual(failure.operationID.utf8.count, 256)
        XCTAssertLessThanOrEqual(failure.diagnostic.utf8.count, RuntimeNormalizedFailure.maximumDiagnosticBytes)
        XCTAssertLessThanOrEqual(failure.guidance.utf8.count, RuntimeNormalizedFailure.maximumGuidanceBytes)
        XCTAssertTrue(failure.requiresObservationBeforeRetry)
    }
}
