import Foundation
import XCTest
@testable import HostwrightObservability
@testable import HostwrightState

final class StateSupportBundleTests: XCTestCase {
    func testSnapshotAcceptsCommittedNonemptyWALFromAnActiveWriter() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()

        let writer = try SQLiteConnection(
            path: store.path,
            createIfNeeded: false,
            readOnly: false,
            profile: .authoritativeState
        )
        defer { try? writer.close() }
        try writer.execute("PRAGMA wal_autocheckpoint = 0")
        try writer.transaction {
            try writer.run(
                """
                INSERT INTO event_ledger(
                    id, timestamp, severity, type, source, project_id, service_name,
                    runtime_adapter, message, payload_json_redacted
                ) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?)
                """,
                bindings: [
                    .text("11111111-1111-4111-8111-111111111111"),
                    .text("2026-08-01T11:00:00Z"),
                    .text("info"),
                    .text("lifecycle.completed"),
                    .text("test"),
                    .text("Committed active-writer evidence."),
                    .text("{}")
                ]
            )
        }
        let wal = store.path + "-wal"
        XCTAssertGreaterThan(
            try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: wal)[.size] as? NSNumber
            ).intValue,
            0
        )

        let snapshot = try StateSupportBundleSnapshotService(
            store: store,
            date: { ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")! }
        ).collect(projectID: nil)
        XCTAssertEqual(snapshot.integrity.health, "healthy")
        XCTAssertEqual(snapshot.integrity.stateSchemaVersion, 17)
        XCTAssertEqual(snapshot.events.count, 1)
    }

    func testVersionSixteenRequiresExplicitUpgradeAndFutureVersionIsRefused() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try MigrationRunner().apply(to: store, throughVersion: 16)
        let date: @Sendable () -> Date = {
            ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!
        }
        XCTAssertThrowsError(try StateSupportBundleSnapshotService(store: store, date: date).collect(projectID: nil))
        XCTAssertEqual(try store.schemaVersion(), 16)

        try store.migrate()
        let snapshot = try StateSupportBundleSnapshotService(store: store, date: date).collect(projectID: nil)
        XCTAssertEqual(snapshot.integrity.stateSchemaVersion, 17)
        XCTAssertEqual(snapshot.metrics.series.count, 59)
        XCTAssertTrue(snapshot.traces.isEmpty)

        try store.withValidatedConnection { connection in
            try connection.transaction {
                try connection.run(
                    "INSERT INTO schema_migrations(version, description, checksum, applied_at) " +
                        "VALUES (18, 'future', 'future', '2026-08-01T12:00:00Z')"
                )
            }
        }
        XCTAssertThrowsError(try StateSupportBundleSnapshotService(store: store, date: date).collect(projectID: nil))
    }

    func testSupportEvidenceRetentionIsAvailableAndDisjointFromEventsAuditsAndTraces() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try store.events.append([EventRecord(
            id: "11111111-1111-4111-8111-111111111111",
            timestamp: "2020-01-01T00:00:00Z",
            severity: .info,
            type: HostwrightSupportBundleContract.createdEventType,
            source: HostwrightSupportBundleContract.source,
            projectID: nil,
            serviceName: nil,
            runtimeAdapter: nil,
            message: "Support bundle creation committed.",
            payloadJSONRedacted: "{}"
        )])
        let policy = retentionPolicy()
        let status = try StateRetentionService(store: store).status(
            policy: policy,
            at: ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!
        )
        let support = try XCTUnwrap(status.classes.first { $0.retentionClass == .supportEvidence })
        XCTAssertTrue(support.producerAvailable)
        XCTAssertEqual(support.currentRecords, 1)
        XCTAssertEqual(support.candidateRecords, 1)
        XCTAssertEqual(status.classes.first { $0.retentionClass == .events }?.currentRecords, 0)
        XCTAssertEqual(status.classes.first { $0.retentionClass == .audits }?.currentRecords, 0)
        XCTAssertEqual(status.classes.first { $0.retentionClass == .traces }?.currentRecords, 0)
        XCTAssertFalse(try XCTUnwrap(status.classes.first { $0.retentionClass == .logs }).producerAvailable)
    }

    func testConfirmedCompactionExpiresOnlyTheExactSupportEvidenceReceipt() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try store.events.append([
            EventRecord(
                id: "11111111-1111-4111-8111-111111111111",
                timestamp: "2020-01-01T00:00:00Z",
                severity: .info,
                type: HostwrightSupportBundleContract.createdEventType,
                source: HostwrightSupportBundleContract.source,
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: nil,
                message: "Support bundle creation committed.",
                payloadJSONRedacted: "{}"
            ),
            EventRecord(
                id: "22222222-2222-4222-8222-222222222222",
                timestamp: "2020-01-01T00:00:00Z",
                severity: .info,
                type: "lifecycle.completed",
                source: "test",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: nil,
                message: "Retain the disjoint ordinary event.",
                payloadJSONRedacted: "{}"
            )
        ])
        var classes = retentionPolicy().classes
        classes[.events] = StateRetentionClassPolicy(
            maxAgeSeconds: 31_536_000,
            maxRecords: 100,
            minimumRecords: 1
        )
        let policy = StateRetentionPolicy(
            recoveryHorizonSeconds: 60,
            maximumDatabaseBytes: 1_048_576,
            targetDatabaseBytes: 1_048_576,
            classes: classes
        )
        let date = ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!
        let service = try StateRetentionService(store: store)
        let plan = try service.compactionPlan(policy: policy, at: date)
        XCTAssertEqual(plan.candidateRecords, 1)
        XCTAssertEqual(
            plan.classes.first { $0.retentionClass == .supportEvidence }?.candidateRecords,
            1
        )
        let result = try service.compact(
            policy: policy,
            confirmationToken: plan.confirmationToken,
            at: date
        )
        XCTAssertEqual(result.deletedRecords[.supportEvidence], 1)
        XCTAssertFalse(try store.events.loadAll().contains {
            $0.id == "11111111-1111-4111-8111-111111111111"
        })
        XCTAssertTrue(try store.events.loadAll().contains {
            $0.id == "22222222-2222-4222-8222-222222222222"
        })
    }

    func testSnapshotHashesIdentifiersAndNeverCopiesMessagesPayloadsOrProjectNames() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try store.events.append([EventRecord(
            id: "raw-event-secret",
            timestamp: "2026-08-01T11:00:00Z",
            severity: .error,
            type: "lifecycle/Users/private",
            source: "operator@example.test",
            projectID: nil,
            serviceName: nil,
            runtimeAdapter: nil,
            message: "password=state-secret-sentinel",
            payloadJSONRedacted: "{\"path\":\"/Users/private/state\"}"
        )])
        let snapshot = try StateSupportBundleSnapshotService(
            store: store,
            date: { ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")! }
        ).collect(projectID: nil)
        let data = try JSONEncoder().encode(snapshot.evidence)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("raw-event-secret"))
        XCTAssertFalse(text.contains("state-secret-sentinel"))
        XCTAssertFalse(text.contains("/Users/private/state"))
        XCTAssertEqual(snapshot.evidence.first?.id.count, 64)
        XCTAssertEqual(snapshot.evidence.first?.type, "redacted")
        XCTAssertEqual(snapshot.evidence.first?.source, "redacted")
    }

    func testSnapshotQueriesBoundLargeEventAndOperationLedgersWithExactDroppedCounts() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try store.events.append((0..<250).map { index in
            EventRecord(
                id: String(format: "00000000-0000-4000-8000-%012d", index),
                timestamp: "2026-08-01T11:00:00Z",
                severity: .info,
                type: "lifecycle.completed",
                source: "test",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: nil,
                message: "not exported",
                payloadJSONRedacted: "{}"
            )
        })
        for index in 0..<205 {
            try store.operations.record(OperationRecord(
                id: String(format: "10000000-0000-4000-8000-%012d", index),
                createdAt: "2026-08-01T10:00:00Z",
                updatedAt: "2026-08-01T11:00:00Z",
                plannedActionType: "up",
                projectID: nil,
                serviceName: nil,
                status: .succeeded,
                idempotencyKey: "bounded-\(index)",
                planHash: String(repeating: "a", count: 64),
                payloadJSONRedacted: "{}"
            ))
        }
        let snapshot = try StateSupportBundleSnapshotService(
            store: store,
            date: { ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")! }
        ).collect(projectID: nil)
        XCTAssertEqual(snapshot.events.count, HostwrightSupportBundleContract.maximumEvents)
        XCTAssertEqual(snapshot.droppedEvents, 50)
        XCTAssertEqual(snapshot.operations.count, HostwrightSupportBundleContract.maximumOperations)
        XCTAssertEqual(snapshot.droppedOperations, 5)
    }

    private func retentionPolicy() -> StateRetentionPolicy {
        let classPolicy = StateRetentionClassPolicy(
            maxAgeSeconds: 60,
            maxRecords: 1,
            minimumRecords: 0
        )
        return StateRetentionPolicy(
            recoveryHorizonSeconds: 60,
            maximumDatabaseBytes: 1_048_576,
            targetDatabaseBytes: 1_048_576,
            classes: Dictionary(uniqueKeysWithValues: StateRetentionClass.allCases.map { ($0, classPolicy) })
        )
    }

    private func privateRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-support-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }
}
