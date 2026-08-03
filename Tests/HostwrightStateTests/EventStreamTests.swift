import Foundation
import XCTest
@testable import HostwrightState

final class EventStreamTests: XCTestCase {
    func testCursorRoundTripsCanonicalShapeAndRejectsTampering() throws {
        let cursor = try HostwrightEventCursor(
            eventID: "event-1",
            eventSHA256: String(repeating: "a", count: 64)
        )

        XCTAssertEqual(try HostwrightEventCursor(token: cursor.token), cursor)
        XCTAssertThrowsError(try HostwrightEventCursor(token: cursor.token + "="))
        let aliasSource = try HostwrightEventCursor(
            eventID: "event-12",
            eventSHA256: String(repeating: "b", count: 64)
        ).token
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var alias = Array(aliasSource)
        let finalIndex = try XCTUnwrap(alphabet.firstIndex(of: try XCTUnwrap(alias.last)))
        alias[alias.count - 1] = alphabet[finalIndex ^ 1]
        XCTAssertThrowsError(try HostwrightEventCursor(token: String(alias)))
        XCTAssertThrowsError(
            try HostwrightEventCursor(
                eventID: "bad\nevent",
                eventSHA256: String(repeating: "a", count: 64)
            )
        )
        XCTAssertEqual(HostwrightEventCursor.schemaVersion, 1)
        XCTAssertLessThanOrEqual(cursor.token.utf8.count, HostwrightEventCursor.maximumTokenBytes)
    }

    func testEventClassContractCoversEveryIssueRequiredFamily() {
        let cases: [(String, HostwrightEventClass)] = [
            ("desired.changed", .desiredChange),
            ("plan.created", .plan),
            ("operation.succeeded", .action),
            ("health.changed", .health),
            ("policy.deferred", .policy),
            ("rollback.completed", .recovery),
            ("retention.completed", .garbageCollection),
            ("provider.observed", .providerState),
            ("operator.decided", .operatorDecision),
            ("state.observed", .state),
            ("daemon.configuration.accepted", .desiredChange),
            ("cleanup.planned", .plan),
            ("state.retention.completed", .garbageCollection),
            ("image.trust.lifecycle.authorized", .policy)
        ]

        XCTAssertEqual(Set(cases.map(\.1)), Set(HostwrightEventClass.allCases))
        for (type, expected) in cases {
            XCTAssertEqual(HostwrightEventClass.classify(type: type), expected)
        }
    }

    func testAppendOrderedPagesResumeWithoutDuplicates() throws {
        try withStore { store in
            try store.events.append([
                event("event-2", timestamp: "2026-08-02T00:00:02Z"),
                event("event-1", timestamp: "2026-08-02T00:00:01Z"),
                event("event-3", timestamp: "2026-08-02T00:00:03Z")
            ])

            let first = try store.events.streamPage(after: nil, pageSize: 2)
            XCTAssertEqual(first.events.map(\.event.id), ["event-2", "event-1"])
            XCTAssertEqual(first.events.map(\.position), [1, 2])
            XCTAssertTrue(first.moreAvailable)

            let second = try store.events.streamPage(
                after: try XCTUnwrap(first.nextCursor),
                pageSize: 2
            )
            XCTAssertEqual(second.events.map(\.event.id), ["event-3"])
            XCTAssertFalse(second.moreAvailable)
            XCTAssertTrue(Set(first.events.map(\.event.id)).isDisjoint(with: second.events.map(\.event.id)))
        }
    }

    func testDeletedCursorReturnsExplicitRetentionGapAndEarliestPage() throws {
        try withStore { store in
            try store.events.append([event("event-1"), event("event-2"), event("event-3")])
            let first = try store.events.streamPage(after: nil, pageSize: 1)
            let cursor = try XCTUnwrap(first.nextCursor)
            try store.withValidatedConnection { connection in
                try connection.run("DELETE FROM event_ledger WHERE id = ?", bindings: [.text("event-1")])
            }

            let resumed = try store.events.streamPage(after: cursor, pageSize: 2)

            XCTAssertEqual(resumed.status, .retentionGap)
            XCTAssertEqual(resumed.events.map(\.event.id), ["event-2", "event-3"])
            XCTAssertEqual(resumed.retentionGap?.requestedCursor, cursor)
            XCTAssertEqual(
                resumed.retentionGap?.earliestAvailableCursor,
                resumed.events.first?.cursor
            )
            XCTAssertNotNil(resumed.retentionGap?.latestAvailableCursor)
        }
    }

    func testRetainedCursorSurvivesVacuumRowIdentityChange() throws {
        try withStore { store in
            try store.events.append([event("event-1"), event("event-2"), event("event-3")])
            let first = try store.events.streamPage(after: nil, pageSize: 2)
            let cursor = try XCTUnwrap(first.nextCursor)
            try store.withValidatedConnection { connection in
                try connection.run("DELETE FROM event_ledger WHERE id = ?", bindings: [.text("event-1")])
                try connection.vacuumAuthoritativeDatabase()
            }

            let resumed = try store.events.streamPage(after: cursor, pageSize: 2)

            XCTAssertEqual(resumed.status, .ready)
            XCTAssertEqual(resumed.events.map(\.event.id), ["event-3"])
            XCTAssertGreaterThan(resumed.events.first?.position ?? 0, 0)
        }
    }

    func testCursorDetectsMutationOfRetainedEvent() throws {
        try withStore { store in
            try store.events.append([event("event-1"), event("event-2")])
            let cursor = try XCTUnwrap(
                try store.events.streamPage(after: nil, pageSize: 1).nextCursor
            )
            try store.withValidatedConnection { connection in
                try connection.run(
                    "UPDATE event_ledger SET message = ? WHERE id = ?",
                    bindings: [.text("changed"), .text("event-1")]
                )
            }

            XCTAssertThrowsError(try store.events.streamPage(after: cursor)) { error in
                XCTAssertEqual(error as? HostwrightEventStreamError, .cursorIntegrityMismatch)
            }
        }
    }

    func testStreamPublishesImmutableOperationAndAuditReferences() throws {
        try withStore { store in
            try store.events.append([
                event(
                    "event-audit",
                    type: "state.retention.completed",
                    source: "hostwright",
                    payload: #"{"operationID":"operation-123"}"#
                )
            ])

            let record = try XCTUnwrap(
                try store.events.streamPage(after: nil).events.first
            )

            XCTAssertEqual(record.operationReferences, ["operation-123"])
            XCTAssertEqual(record.auditReference, record.eventReference)
            XCTAssertTrue(record.eventReference.hasPrefix("sha256:"))
            XCTAssertFalse(record.cursor.contains("operation-123"))
        }
    }

    func testFilteredCursorAdvancesAcrossNonMatchingRows() throws {
        try withStore { store in
            try store.events.append([
                event("event-match", type: "health.changed"),
                event("event-other", type: "runtime.observed")
            ])
            let filter = HostwrightEventStreamFilter(type: "health.changed")
            let first = try store.events.streamPage(after: nil, filter: filter)
            XCTAssertEqual(first.events.map(\.event.id), ["event-match"])
            let cursor = try XCTUnwrap(first.nextCursor)
            try store.events.append([event("event-new", type: "health.changed")])

            let resumed = try store.events.streamPage(after: cursor, filter: filter)

            XCTAssertEqual(resumed.events.map(\.event.id), ["event-new"])
        }
    }

    func testPageAndFilterLimitsFailClosed() throws {
        try withStore { store in
            XCTAssertThrowsError(try store.events.streamPage(after: nil, pageSize: 0))
            XCTAssertThrowsError(
                try store.events.streamPage(
                    after: nil,
                    filter: HostwrightEventStreamFilter(
                        type: String(repeating: "x", count: 256)
                    )
                )
            )
        }
    }

    func testMaximumPageAppliesBackpressureWithoutDroppingTheRemainder() throws {
        try withStore { store in
            try store.events.append((0...HostwrightEventStreamPage.maximumPageSize).map { index in
                event(String(format: "event-%04d", index))
            })

            let first = try store.events.streamPage(
                after: nil,
                pageSize: HostwrightEventStreamPage.maximumPageSize
            )
            XCTAssertEqual(first.events.count, HostwrightEventStreamPage.maximumPageSize)
            XCTAssertTrue(first.moreAvailable)
            let second = try store.events.streamPage(
                after: try XCTUnwrap(first.nextCursor),
                pageSize: HostwrightEventStreamPage.maximumPageSize
            )
            XCTAssertEqual(second.events.count, 1)
            XCTAssertFalse(second.moreAvailable)
        }
    }

    func testDuplicateEventIdentityCannotCreateDuplicateSemanticRow() throws {
        try withStore { store in
            let record = event("event-deduplicated", type: "provider.notification")
            try store.events.append([record])
            XCTAssertThrowsError(try store.events.append([record]))

            let page = try store.events.streamPage(after: nil)
            XCTAssertEqual(page.events.map(\.event.id), ["event-deduplicated"])
        }
    }

    func testConcurrentProducersRemainUniquelyAppendOrdered() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-event-concurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite3").path)
        try store.migrate()
        let records = (0..<32).map { index in
            event(String(format: "event-concurrent-%02d", index))
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask {
                    try store.events.append([record])
                }
            }
            try await group.waitForAll()
        }

        let page = try store.events.streamPage(after: nil, pageSize: records.count)
        XCTAssertEqual(page.events.count, records.count)
        XCTAssertEqual(Set(page.events.map(\.event.id)), Set(records.map(\.id)))
        XCTAssertEqual(page.events.map(\.position), Array(1...32))
        XCTAssertFalse(page.moreAvailable)
    }

    func testSchemaV16EventProjectsIntoV1CursorAfterV20Upgrade() throws {
        try withUnmigratedStore { store in
            try MigrationRunner().apply(to: store, throughVersion: 16)
            let legacy = event("event-v16")
            try store.withConnection { connection in
                try connection.run(
                    """
                    INSERT INTO event_ledger (
                        id, timestamp, severity, type, source, project_id, service_name,
                        runtime_adapter, message, payload_json_redacted
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(legacy.id), .text(legacy.timestamp), .text(legacy.severity.rawValue),
                        .text(legacy.type), .text(legacy.source), .null, .null, .null,
                        .text(legacy.message), .text(legacy.payloadJSONRedacted)
                    ]
                )
            }
            try store.migrate()

            XCTAssertEqual(try store.schemaVersion(), 20)
            let page = try store.events.streamPage(after: nil)
            XCTAssertEqual(page.events.map(\.event.id), ["event-v16"])
            XCTAssertEqual(try HostwrightEventCursor(token: page.events[0].cursor).eventID, "event-v16")
        }
    }

    func testMalformedLegacyPayloadDoesNotBreakSafeProjectFiltering() throws {
        try withStore { store in
            try store.events.append([
                event(
                    "event-malformed",
                    type: "image.trust.observed",
                    payload: "not-json"
                )
            ])

            let page = try store.events.streamPage(
                after: nil,
                filter: HostwrightEventStreamFilter(projectID: "project-demo")
            )

            XCTAssertTrue(page.events.isEmpty)
            XCTAssertNotNil(page.nextCursor)
        }
    }

    private func event(
        _ id: String,
        timestamp: String = "2026-08-02T00:00:00Z",
        type: String = "state.observed",
        source: String = "test",
        payload: String = "{}"
    ) -> EventRecord {
        EventRecord(
            id: id,
            timestamp: timestamp,
            severity: .info,
            type: type,
            source: source,
            projectID: nil,
            serviceName: nil,
            runtimeAdapter: nil,
            message: "safe",
            payloadJSONRedacted: payload
        )
    }

    private func withStore(_ body: (SQLiteStateStore) throws -> Void) throws {
        try withUnmigratedStore { store in
            try store.migrate()
            try body(store)
        }
    }

    private func withUnmigratedStore(_ body: (SQLiteStateStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-event-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(SQLiteStateStore(path: root.appendingPathComponent("state.sqlite3").path))
    }
}
