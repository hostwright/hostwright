import Dispatch
import Foundation
import XCTest
@testable import HostwrightObservability

final class HostwrightObservabilityTests: XCTestCase {
    private let correlationID = "11111111-2222-3333-4444-555555555555"

    func testStructuredRecordUsesFixedVersionSubsystemAndSortedFields() throws {
        let record = try HostwrightLogRecord(
            category: .reconciliation,
            severity: .notice,
            reason: .durableEventInfo,
            correlationID: correlationID,
            outcome: .observed,
            fields: [
                HostwrightLogField(name: .status, value: "healthy", privacy: .publicValue),
                HostwrightLogField(name: .iteration, value: "7", privacy: .publicValue)
            ]
        )

        XCTAssertEqual(HostwrightLogRecord.subsystem, "dev.hostwright")
        XCTAssertEqual(record.version, 1)
        XCTAssertEqual(record.fields.map(\.name), [.iteration, .status])
        XCTAssertEqual(
            record.canonicalMessage,
            "version=1 reason=HW-OBS-120 correlation=\(correlationID) outcome=observed iteration=\"7\" status=\"healthy\""
        )
        XCTAssertLessThanOrEqual(record.canonicalMessage.utf8.count, HostwrightLogRecord.maximumPayloadBytes)
    }

    func testReasonOutcomeContractRejectsMisleadingSuccess() {
        XCTAssertThrowsError(
            try HostwrightLogRecord(
                category: .cli,
                severity: .error,
                reason: .cliFailed,
                correlationID: correlationID,
                outcome: .succeeded
            )
        ) { error in
            XCTAssertEqual(error as? HostwrightObservabilityError, .misleadingOutcome)
            XCTAssertEqual((error as? HostwrightObservabilityError)?.code, "HW-OBS-003")
        }
    }

    func testRecordRejectsInvalidIdentifiersDuplicateAndUnboundedFields() {
        XCTAssertThrowsError(
            try HostwrightLogRecord(
                category: .cli,
                severity: .info,
                reason: .cliStarted,
                correlationID: "contains a space",
                outcome: .started
            )
        )
        XCTAssertThrowsError(
            try HostwrightLogRecord(
                category: .state,
                severity: .info,
                reason: .durableEventInfo,
                correlationID: correlationID,
                outcome: .observed,
                fields: [
                    HostwrightLogField(name: .status, value: "one"),
                    HostwrightLogField(name: .status, value: "two")
                ]
            )
        )
        XCTAssertThrowsError(
            try HostwrightLogRecord(
                category: .state,
                severity: .info,
                reason: .durableEventInfo,
                correlationID: correlationID,
                outcome: .observed,
                fields: HostwrightLogFieldName.allCases.map {
                    HostwrightLogField(name: $0, value: "one")
                } + [HostwrightLogField(name: .status, value: "extra")]
            )
        )
    }

    func testConstructionTimeRedactionCoversCredentialsPIIAndPaths() throws {
        let raw = "token=abc123 Bearer ZXl.supersecret keychain://hostwright.api/token "
            + "Basic YWxpY2U6cGFzc3dvcmQ= {\"password\":\"quoted secret\"} "
            + "dev@example.com /Users/dev/private/config.yaml 192.168.1.4 https://alice:password@example.test"
        let field = HostwrightLogField(
            name: .status,
            value: raw,
            privacy: .publicValue,
            sensitiveValues: ["abc123", "supersecret"]
        )

        XCTAssertFalse(field.value.contains("abc123"))
        XCTAssertFalse(field.value.contains("supersecret"))
        XCTAssertFalse(field.value.contains("hostwright.api"))
        XCTAssertFalse(field.value.contains("dev@example.com"))
        XCTAssertFalse(field.value.contains("/Users/dev"))
        XCTAssertFalse(field.value.contains("192.168.1.4"))
        XCTAssertFalse(field.value.contains("alice:password"))
        XCTAssertFalse(field.value.contains("YWxpY2U6"))
        XCTAssertFalse(field.value.contains("quoted secret"))
        XCTAssertLessThanOrEqual(field.value.utf8.count, HostwrightLogField.maximumValueBytes)
        let headerRedaction = SecretRedactor.redact(
            value: "Authorization: Basic YWxpY2U6cGFzc3dvcmQ= {\"password\":\"quoted secret\"}",
            secretKeys: []
        )
        XCTAssertFalse(headerRedaction.contains("YWxpY2U6"))
        XCTAssertFalse(headerRedaction.contains("quoted secret"))
    }

    func testFieldRemovesLogInjectionAndBoundsUnicodeByBytes() {
        let field = HostwrightLogField(
            name: .status,
            value: "ok\nreason=HW-OBS-102\t" + String(repeating: "😀", count: 100),
            privacy: .publicValue
        )

        XCTAssertFalse(field.value.contains("\n"))
        XCTAssertFalse(field.value.contains("\t"))
        XCTAssertLessThanOrEqual(field.value.utf8.count, HostwrightLogField.maximumValueBytes)
    }

    func testAdversarialInputAndSecretListsAreBoundedBeforeRedaction() {
        let field = HostwrightLogField(
            name: .status,
            value: String(repeating: "a", count: 1_000_000) + " token=too-late",
            privacy: .publicValue,
            sensitiveValues: (0..<1_000).map { "secret-\($0)-" + String(repeating: "x", count: 1_000) }
        )

        XCTAssertLessThanOrEqual(field.value.utf8.count, HostwrightLogField.maximumValueBytes)
        XCTAssertEqual(SecretRedactor.maximumInputBytes, 4_096)
        XCTAssertEqual(SecretRedactor.maximumSecretCount, 32)
        XCTAssertEqual(SecretRedactor.maximumSecretBytes, 256)
        XCTAssertEqual(field.value, SecretRedactor.replacement)
        XCTAssertEqual(
            SecretRedactor.redact(
                value: String(repeating: "s", count: 1_000),
                secretKeys: [String(repeating: "s", count: 1_000)]
            ),
            SecretRedactor.replacement
        )
    }

    func testContextPropagatesCorrelationAndSinkWithoutGlobalState() throws {
        let sink = CapturingLogSink()
        try HostwrightLogContext.withValues(sink: sink, correlationID: correlationID) {
            let record = try HostwrightLogRecord(
                category: .state,
                severity: .info,
                reason: .durableEventInfo,
                correlationID: HostwrightLogContext.correlationID ?? "missing",
                outcome: .observed
            )
            XCTAssertEqual(HostwrightLogContext.emit(record).status, .emitted)
        }

        XCTAssertNil(HostwrightLogContext.correlationID)
        XCTAssertEqual(sink.records().map(\.correlationID), [correlationID])
    }

    func testContextIsExactlyRestoredAfterCancellationStyleThrow() {
        enum Stop: Error { case requested }
        let sink = CapturingLogSink()

        XCTAssertThrowsError(
            try HostwrightLogContext.withValues(sink: sink, correlationID: correlationID) {
                throw Stop.requested
            }
        )
        XCTAssertNil(HostwrightLogContext.correlationID)
        XCTAssertNil(HostwrightLogContext.sink)
        XCTAssertTrue(sink.records().isEmpty)
    }

    func testConcurrentWritersRemainBoundedAndIsolated() throws {
        let sink = CapturingLogSink()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "hostwright.observability.tests", attributes: .concurrent)
        for index in 0..<1_000 {
            group.enter()
            queue.async {
                defer { group.leave() }
                let correlation = "correlation-\(index)"
                guard let record = try? HostwrightLogRecord(
                    category: .runtime,
                    severity: .info,
                    reason: .durableEventInfo,
                    correlationID: correlation,
                    outcome: .observed,
                    fields: [
                        HostwrightLogField(
                            name: .iteration,
                            value: String(index),
                            privacy: .publicValue
                        )
                    ]
                ) else { return }
                _ = sink.emit(record)
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(sink.records().count, 1_000)
        XCTAssertEqual(Set(sink.records().map(\.correlationID)).count, 1_000)
    }

    func testDisabledSinkHasExplicitNonSuccessStatus() throws {
        let record = try HostwrightLogRecord(
            category: .cli,
            severity: .info,
            reason: .cliStarted,
            correlationID: correlationID,
            outcome: .started
        )
        XCTAssertEqual(DisabledHostwrightLogSink().emit(record).status, .disabled)
        XCTAssertEqual(HostwrightObservabilityContract.durableAuthority, "sqlite-event-ledger-v1")
        XCTAssertEqual(HostwrightObservabilityContract.rotationAuthority, "macos-unified-logging")
        XCTAssertFalse(HostwrightObservabilityContract.automaticUpload)
    }

    func testProductionSinkCollectionControlsStopBeforeOSLogEmission() throws {
        let record = try HostwrightLogRecord(
            category: .cli,
            severity: .info,
            reason: .durableEventInfo,
            correlationID: correlationID,
            outcome: .observed
        )

        XCTAssertEqual(
            HostwrightOSLogSink(configuration: .disabled).emit(record).status,
            .disabled
        )
        XCTAssertEqual(
            HostwrightOSLogSink(
                configuration: HostwrightLogConfiguration(minimumSeverity: .error)
            ).emit(record).status,
            .filtered
        )
    }

    func testFieldPrivacyDefaultsToConstructionTimePrivateRedaction() {
        let field = HostwrightLogField(name: .status, value: "Alice arbitrary local context")

        XCTAssertEqual(field.privacy, .privateValue)
        XCTAssertEqual(field.value, "[PRIVATE]")
    }

    func testSecretRedactorPreservesExistingExactAndKeychainContract() {
        XCTAssertEqual(
            SecretRedactor.redact(value: "token=abc123", secretKeys: ["abc123"]),
            "token=[REDACTED]"
        )
        XCTAssertEqual(
            SecretRedactor.redact(
                value: "using keychain://hostwright.api/api-token",
                secretKeys: []
            ),
            "using keychain://[REDACTED]"
        )
        XCTAssertEqual(
            SecretRedactor.redact(value: "token=abc123", secretKeys: [""]),
            "token=[REDACTED]"
        )
    }
}

private final class CapturingLogSink: HostwrightLogSinking, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [HostwrightLogRecord] = []

    func emit(_ record: HostwrightLogRecord) -> HostwrightLogEmission {
        lock.lock()
        captured.append(record)
        lock.unlock()
        return HostwrightLogEmission(status: .emitted)
    }

    func records() -> [HostwrightLogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}
