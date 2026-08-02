import Foundation
import HostwrightCLI
import HostwrightObservability
@testable import HostwrightState
import XCTest

final class EventWatchCLIIntegrationTests: XCTestCase {
    func testParserLocksCursorWatchAndBounds() throws {
        XCTAssertEqual(
            try CLICommand.parse(
                arguments: [
                    "events", "--state-db", "/tmp/state.sqlite",
                    "--cursor", "beginning", "--limit", "25", "--output", "json"
                ]
            ),
            .events(
                stateDatabasePath: "/tmp/state.sqlite",
                projectName: nil,
                filters: EventFilters(limit: 25),
                stream: EventStreamCLIOptions(cursor: "beginning"),
                output: .json
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(
                arguments: ["events", "--watch", "--timeout", "45"]
            ),
            .events(
                stateDatabasePath: nil,
                projectName: nil,
                filters: EventFilters(),
                stream: EventStreamCLIOptions(watch: true, timeoutSeconds: 45),
                output: .text
            )
        )
        XCTAssertThrowsError(
            try CLICommand.parse(arguments: ["events", "--limit", "1001"])
        )
        XCTAssertThrowsError(
            try CLICommand.parse(arguments: ["events", "--timeout", "1"])
        )
        XCTAssertThrowsError(
            try CLICommand.parse(
                arguments: ["events", "--cursor", "beginning", "--sort", "desc"]
            )
        )
    }

    func testCursorPagesResumeInAppendOrderWithoutDuplicates() throws {
        try withStore { store, path in
            try store.events.append([event("event-2"), event("event-1"), event("event-3")])
            let environment = environment()
            let first = HostwrightCLI.run(
                arguments: [
                    "events", "--state-db", path, "--cursor", "beginning",
                    "--limit", "2", "--output", "json"
                ],
                environment: environment
            )
            XCTAssertEqual(first.exitCode, 0)
            let firstJSON = try json(first.standardOutput)
            XCTAssertEqual(firstJSON["schemaVersion"] as? Int, 1)
            XCTAssertEqual(firstJSON["mode"] as? String, "cursor-page")
            XCTAssertEqual(firstJSON["moreAvailable"] as? Bool, true)
            let firstEvents = try XCTUnwrap(firstJSON["events"] as? [[String: Any]])
            XCTAssertEqual(firstEvents.compactMap { $0["id"] as? String }, ["event-2", "event-1"])
            let cursor = try XCTUnwrap(firstJSON["nextCursor"] as? String)

            let second = HostwrightCLI.run(
                arguments: [
                    "events", "--state-db", path, "--cursor", cursor,
                    "--limit", "2", "--output", "json"
                ],
                environment: environment
            )
            XCTAssertEqual(second.exitCode, 0)
            let secondEvents = try XCTUnwrap(
                try json(second.standardOutput)["events"] as? [[String: Any]]
            )
            XCTAssertEqual(secondEvents.compactMap { $0["id"] as? String }, ["event-3"])
        }
    }

    func testWatchWaitsForOneBoundedPageThenReturnsCursor() throws {
        try withStore { store, path in
            try store.events.append([event("event-existing")])
            var environment = environment()
            var monotonic: UInt64 = 0
            var inserted = false
            environment.eventWatchMonotonicNow = { monotonic }
            environment.eventWatchSleep = { interval in
                monotonic += UInt64(interval * 1_000_000_000)
                if !inserted {
                    inserted = true
                    try? store.events.append([self.event("event-new")])
                }
            }

            let result = HostwrightCLI.run(
                arguments: [
                    "events", "--state-db", path, "--watch", "--timeout", "1",
                    "--limit", "1", "--output", "json"
                ],
                environment: environment
            )

            XCTAssertEqual(result.exitCode, 0)
            let object = try json(result.standardOutput)
            XCTAssertEqual(object["mode"] as? String, "watch")
            XCTAssertEqual(object["status"] as? String, "ready")
            let events = try XCTUnwrap(object["events"] as? [[String: Any]])
            XCTAssertEqual(events.compactMap { $0["id"] as? String }, ["event-new"])
            XCTAssertNotNil(object["nextCursor"] as? String)
        }
    }

    func testWatchTimeoutAndCancellationAreExplicitAndNonMutating() throws {
        try withStore { store, path in
            var timeoutEnvironment = environment()
            var monotonic: UInt64 = 0
            timeoutEnvironment.eventWatchMonotonicNow = { monotonic }
            timeoutEnvironment.eventWatchSleep = { interval in
                monotonic += UInt64(interval * 1_000_000_000)
            }
            let timeout = HostwrightCLI.run(
                arguments: [
                    "events", "--state-db", path, "--watch", "--timeout", "1",
                    "--output", "json"
                ],
                environment: timeoutEnvironment
            )
            XCTAssertEqual(timeout.exitCode, 0)
            XCTAssertEqual(try json(timeout.standardOutput)["status"] as? String, "timeout")

            var cancelledEnvironment = environment()
            var cancelled = false
            cancelledEnvironment.eventWatchMonotonicNow = { 0 }
            cancelledEnvironment.eventWatchSleep = { _ in cancelled = true }
            cancelledEnvironment.eventWatchCancelled = { cancelled }
            let cancellation = HostwrightCLI.run(
                arguments: [
                    "events", "--state-db", path, "--watch", "--timeout", "1",
                    "--output", "json"
                ],
                environment: cancelledEnvironment
            )
            XCTAssertEqual(cancellation.exitCode, CLIExitCode.partialFailure.rawValue)
            XCTAssertEqual(try json(cancellation.standardError)["code"] as? String, "HW-EVENT-004")
            XCTAssertTrue(try store.events.loadAll().isEmpty)
        }
    }

    func testDeletedCursorReturnsGapPageWithoutFailureOrStateMutation() throws {
        try withStore { store, path in
            try store.events.append([event("event-1"), event("event-2")])
            let first = HostwrightCLI.run(
                arguments: [
                    "events", "--state-db", path, "--cursor", "beginning",
                    "--limit", "1", "--output", "json"
                ],
                environment: environment()
            )
            let cursor = try XCTUnwrap(try json(first.standardOutput)["nextCursor"] as? String)
            try store.withValidatedConnection { connection in
                try connection.run("DELETE FROM event_ledger WHERE id = ?", bindings: [.text("event-1")])
            }

            let resumed = HostwrightCLI.run(
                arguments: [
                    "events", "--state-db", path, "--cursor", cursor,
                    "--output", "json"
                ],
                environment: environment()
            )

            XCTAssertEqual(resumed.exitCode, 0)
            let object = try json(resumed.standardOutput)
            XCTAssertEqual(object["status"] as? String, "retention-gap")
            XCTAssertNotNil(object["retentionGap"] as? [String: Any])
            let events = try XCTUnwrap(object["events"] as? [[String: Any]])
            XCTAssertEqual(events.compactMap { $0["id"] as? String }, ["event-2"])
        }
    }

    func testSnapshotDefaultIsBoundedAndPreservesTimestampOrdering() throws {
        try withStore { store, path in
            try store.events.append((0..<101).reversed().map { index in
                event(
                    String(format: "event-%03d", index),
                    timestamp: String(format: "2026-08-02T00:%02d:%02dZ", index / 60, index % 60)
                )
            })

            let result = HostwrightCLI.run(
                arguments: ["events", "--state-db", path, "--output", "json"],
                environment: environment()
            )

            XCTAssertEqual(result.exitCode, 0)
            let object = try json(result.standardOutput)
            XCTAssertEqual(object["mode"] as? String, "snapshot")
            XCTAssertEqual(object["pageSize"] as? Int, 100)
            XCTAssertEqual(object["moreAvailable"] as? Bool, true)
            let events = try XCTUnwrap(object["events"] as? [[String: Any]])
            XCTAssertEqual(events.count, 100)
            XCTAssertEqual(events.first?["id"] as? String, "event-000")
        }
    }

    private func environment() -> CLIEnvironment {
        var environment = CLIEnvironment.live
        environment.observabilitySink = DisabledHostwrightLogSink()
        return environment
    }

    private func event(
        _ id: String,
        timestamp: String = "2026-08-02T00:00:00Z"
    ) -> EventRecord {
        EventRecord(
            id: id,
            timestamp: timestamp,
            severity: .info,
            type: "state.observed",
            source: "test",
            projectID: nil,
            serviceName: nil,
            runtimeAdapter: nil,
            message: "safe",
            payloadJSONRedacted: "{}"
        )
    }

    private func withStore(
        _ body: (SQLiteStateStore, String) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-event-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite3").path
        let store = SQLiteStateStore(path: path)
        try store.migrate()
        try body(store, path)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }
}
