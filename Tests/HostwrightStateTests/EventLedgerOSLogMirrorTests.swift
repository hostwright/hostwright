import Foundation
import HostwrightObservability
import HostwrightState
import XCTest

final class EventLedgerOSLogMirrorTests: XCTestCase {
    func testCommittedEventIsMirroredWithCorrelationWithoutMessageOrPayload() throws {
        try withStore { store in
            let sink = EventLogCapture()
            let correlationID = "dddddddd-eeee-ffff-0000-111111111111"
            let event = EventRecord(
                id: "event-11111111-2222-3333-4444-555555555555",
                timestamp: "2026-08-02T00:00:00Z",
                severity: .warning,
                type: "reconciliation.deferred",
                source: "hostwrightd",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: nil,
                message: "token=never-log-this",
                payloadJSONRedacted: #"{"path":"/Users/dev/private/manifest.yaml"}"#
            )

            try HostwrightLogContext.withValues(sink: sink, correlationID: correlationID) {
                try store.events.append([event])
            }

            XCTAssertEqual(try store.events.loadAll().count, 1)
            let record = try XCTUnwrap(sink.records().only)
            XCTAssertEqual(record.correlationID, correlationID)
            XCTAssertEqual(record.category, .reconciliation)
            XCTAssertEqual(record.reason, .durableEventWarning)
            XCTAssertEqual(record.outcome, .observed)
            XCTAssertFalse(record.canonicalMessage.contains("never-log-this"))
            XCTAssertFalse(record.canonicalMessage.contains("/Users/dev"))
            XCTAssertFalse(record.canonicalMessage.contains("project-private"))
            XCTAssertFalse(record.canonicalMessage.contains("service-private"))
        }
    }

    func testFailedLedgerTransactionCannotEmitMirroredSuccess() throws {
        try withStore { store in
            let sink = EventLogCapture()
            let event = EventRecord(
                id: "event-duplicate",
                timestamp: "2026-08-02T00:00:00Z",
                severity: .info,
                type: "daemon.started",
                source: "hostwrightd",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: nil,
                message: "started",
                payloadJSONRedacted: "{}"
            )
            try store.events.append([event])

            XCTAssertThrowsError(
                try HostwrightLogContext.withValues(
                    sink: sink,
                    correlationID: "eeeeeeee-ffff-0000-1111-222222222222"
                ) {
                    try store.events.append([event])
                }
            )
            XCTAssertTrue(sink.records().isEmpty)
            XCTAssertEqual(try store.events.loadAll().count, 1)
        }
    }

    private func withStore(_ body: (SQLiteStateStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-event-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(
            configuration: StateStoreConfiguration(
                explicitDatabasePath: root.appendingPathComponent("state.sqlite3").path
            )
        )
        try store.migrate()
        try body(store)
    }
}

private final class EventLogCapture: HostwrightLogSinking, @unchecked Sendable {
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

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
