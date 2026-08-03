import Foundation
import XCTest
@testable import HostwrightObservability
@testable import HostwrightState

final class StateTraceTests: XCTestCase {
    func testVersionSixteenRequiresExplicitUpgradeAndFutureVersionIsRefused() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("upgrade.sqlite").path)
        try MigrationRunner().apply(to: store, throughVersion: 16)
        XCTAssertEqual(try store.schemaVersion(), 16)
        XCTAssertThrowsError(try store.traces.inspect(limit: 20))
        XCTAssertEqual(try store.schemaVersion(), 16)

        try store.migrate()
        XCTAssertEqual(try store.schemaVersion(), 20)
        XCTAssertTrue(try store.traces.inspect(limit: 20).traces.isEmpty)
        try store.withValidatedConnection { connection in
            try connection.transaction {
                try connection.run(
                    "INSERT INTO schema_migrations(version, description, checksum, applied_at) " +
                        "VALUES (?, 'future', 'future', '2026-08-01T00:00:00Z')",
                    bindings: [.int64(Int64(MigrationRunner.latestSchemaVersion + 1))]
                )
            }
        }
        XCTAssertThrowsError(try store.traces.inspect(limit: 20))
    }

    func testPersistenceCorrelatesEventsOperationsAndSurvivesRestart() throws {
        try withStore { store in
            let session = try HostwrightTraceSession(
                traceID: "11111111-1111-4111-8111-111111111111",
                processCorrelationID: "22222222-2222-4222-8222-222222222222",
                selected: true
            )
            session.attach(StateTraceSink(store: store))
            HostwrightTraceContext.withSession(session) {
                let root = session.start(.cliRequest)
                do {
                    try HostwrightTraceContext.withSpan(root) {
                        try store.operations.record(OperationRecord(
                            id: "operation-correlated",
                            createdAt: "2026-08-01T12:00:00Z",
                            updatedAt: "2026-08-01T12:00:01Z",
                            plannedActionType: "up",
                            projectID: nil,
                            serviceName: nil,
                            status: .failed,
                            idempotencyKey: "trace-operation",
                            planHash: String(repeating: "a", count: 64),
                            payloadJSONRedacted: "{}"
                        ))
                        try store.events.append([EventRecord(
                            id: "event-correlated",
                            timestamp: "2026-08-01T12:00:01Z",
                            severity: .error,
                            type: "lifecycle.failed",
                            source: "test",
                            projectID: nil,
                            serviceName: nil,
                            runtimeAdapter: nil,
                            message: "Lifecycle failed.",
                            payloadJSONRedacted: "{}"
                        )])
                        try HostwrightTraceContext.withSpan(.providerApply) {
                            throw TestFailure.expected
                        }
                    }
                    XCTFail("Expected the traced operation to fail.")
                } catch TestFailure.expected {
                    _ = session.finish(
                        root,
                        status: .failed,
                        attributes: session.rootCompletionAttributes(sampling: "failure-override")
                    )
                    session.complete(status: .failed)
                } catch {
                    XCTFail("Unexpected trace failure: \(error)")
                }
            }
            let reopened = SQLiteStateStore(path: store.path)
            let page = try reopened.traces.inspect(
                traceID: "11111111-1111-4111-8111-111111111111",
                limit: 1
            )
            let trace = try XCTUnwrap(page.traces.first)
            XCTAssertTrue(trace.complete)
            XCTAssertTrue(trace.eventIDs.contains("event-correlated"))
            XCTAssertTrue(trace.operationIDs.contains("operation-correlated"))
            XCTAssertEqual(trace.status, .failed)
        }
    }

    func testCompleteTraceHasStableHashAndRejectsMalformedOrMissingRecords() throws {
        try withStore { store in
            let traceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            let root = try HostwrightTraceSpanRecord(
                traceID: traceID,
                spanID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                parentSpanID: nil,
                processCorrelationID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                name: .cliRequest,
                status: .failed,
                startedAt: "2026-08-01T12:00:00Z",
                endedAt: "2026-08-01T12:00:01Z",
                durationMilliseconds: 1_000,
                depth: 0,
                attributes: [
                    try HostwrightTraceAttribute(key: .sampling, value: "failure-override"),
                    try HostwrightTraceAttribute(key: .droppedSpans, value: "0")
                ]
            )
            XCTAssertEqual(StateTraceSink(store: store).record(root).status, .persisted)
            let first = try store.traces.completeTrace(traceID)
            let second = try SQLiteStateStore(path: store.path).traces.completeTrace(traceID)
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.traceSHA256.count, 64)
            XCTAssertThrowsError(try store.traces.inspect(
                traceID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                limit: 1
            ))
        }
    }

    func testSinkFailureIsDegradedAndDoesNotFabricateSuccess() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = SQLiteStateStore(path: root.appendingPathComponent("missing.sqlite").path)
        let span = try HostwrightTraceSpanRecord(
            traceID: "11111111-1111-4111-8111-111111111111",
            spanID: "22222222-2222-4222-8222-222222222222",
            parentSpanID: nil,
            processCorrelationID: "33333333-3333-4333-8333-333333333333",
            name: .cliRequest,
            status: .failed,
            startedAt: "2026-08-01T12:00:00Z",
            endedAt: "2026-08-01T12:00:01Z",
            durationMilliseconds: 1_000,
            depth: 0
        )
        XCTAssertEqual(StateTraceSink(store: missing).record(span).status, .degraded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    private enum TestFailure: Error { case expected }
    private func withStore(_ body: (SQLiteStateStore) throws -> Void) throws {
        let root = try privateRoot()
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try body(store)
    }

    private func privateRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-trace-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }
}
