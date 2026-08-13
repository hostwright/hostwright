import Foundation
import XCTest
@testable import HostwrightObservability
@testable import HostwrightState

final class StateMetricsTests: XCTestCase {
    func testProjectionIsFixedDeterministicAndCalculatesDeclaredSLOsAcrossTenThousandCycles() throws {
        try withStore { store in
            try insertReconciliationCycles(count: 10_000, store: store)
            try insertSucceededRuntimeGroups(count: 20, store: store)
            try store.operations.record(OperationRecord(
                id: "legacy-daemon-duration",
                createdAt: "2026-08-01T00:00:00Z",
                updatedAt: "2026-08-01T00:00:01Z",
                plannedActionType: "daemon.reconcile",
                projectID: nil,
                serviceName: nil,
                status: .succeeded,
                idempotencyKey: "legacy-daemon-duration",
                planHash: digest("legacy"),
                payloadJSONRedacted: "{}"
            ))

            let first = try StateMetricsService(
                store: store,
                date: { ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")! }
            ).snapshot()
            let reopened = SQLiteStateStore(path: store.path)
            let second = try StateMetricsService(
                store: reopened,
                date: { ISO8601DateFormatter().date(from: "2026-08-01T12:01:00Z")! }
            ).snapshot()

            XCTAssertEqual(first.schemaVersion, 1)
            XCTAssertEqual(first.source.schemaVersion, 17)
            XCTAssertEqual(first.series.count, 59)
            XCTAssertLessThanOrEqual(first.series.count, HostwrightMetricCatalog.maximumSeries)
            XCTAssertEqual(first.snapshotSHA256, second.snapshotSHA256)
            XCTAssertNotEqual(first.generatedAt, second.generatedAt)
            XCTAssertEqual(first.series, second.series)
            XCTAssertEqual(first.retention, HostwrightMetricsRetention())
            try HostwrightMetricCatalog.validate(first.series)

            XCTAssertEqual(
                value("hostwright_reconciliation_iterations_total", label: "outcome", value: "succeeded", in: first),
                9_991
            )
            XCTAssertEqual(
                value("hostwright_reconciliation_iterations_total", label: "outcome", value: "failed", in: first),
                10
            )
            XCTAssertEqual(
                value("hostwright_runtime_actions_total", label: "outcome", value: "succeeded", in: first),
                20
            )
            XCTAssertEqual(
                value("hostwright_metrics_dropped_samples_total", label: "reason", value: "unsupported-duration", in: first),
                1
            )
            let summary = try XCTUnwrap(first.series.first {
                $0.name == "hostwright_reconciliation_duration_seconds"
            }?.summary)
            XCTAssertEqual(summary.count, 10_000)
            XCTAssertEqual(summary.minimum, 1)
            XCTAssertEqual(summary.maximum, 1)
            XCTAssertEqual(summary.mean, 1)
            XCTAssertEqual(
                first.slos.first { $0.name == "reconciliation-success-ratio" }?.status,
                .met
            )
            XCTAssertEqual(
                first.slos.first { $0.name == "runtime-action-success-ratio" }?.status,
                .met
            )
            XCTAssertEqual(
                first.slos.first { $0.name == "reconciliation-duration-p95" }?.observed,
                1
            )
        }
    }

    func testEmptyProjectionHasEveryFixedSeriesAndInsufficientSLOs() throws {
        try withStore { store in
            let snapshot = try StateMetricsService(store: store).snapshot()

            XCTAssertEqual(snapshot.series.count, 59)
            XCTAssertTrue(snapshot.series.allSatisfy { item in
                item.value == nil || item.name == "hostwright_state_database_bytes" || item.value == 0
            })
            XCTAssertEqual(Set(snapshot.slos.map(\.status)), [.insufficientData])
            XCTAssertFalse(snapshot.retention.separateSampleStore)
            XCTAssertFalse(snapshot.retention.automaticUpload)
        }
    }

    func testProjectionDoesNotExposeStoredIdentifiersPathsErrorsOrCredentials() throws {
        try withStore { store in
            let secret = "AKIA-TEST-DO-NOT-EXPOSE"
            let groupID = UUID().uuidString.lowercased()
            _ = try store.operationGroups.acquire(OperationGroupRecord(
                id: groupID,
                operationID: "operation-\(secret)",
                groupKind: "lifecycle-v1",
                projectID: nil,
                serviceName: "service-\(secret)",
                plannedActionType: "up",
                status: .active,
                groupIdempotencyKey: "key-\(secret)",
                planHash: digest(secret),
                checkpoint: "intent-persisted",
                lockOwner: "owner-\(secret)",
                lockExpiresAt: "2026-08-01T00:10:00Z",
                rollbackAvailable: true,
                manualRecoveryHintRedacted: "/Users/private/\(secret)",
                createdAt: "2026-08-01T00:00:00Z",
                updatedAt: "2026-08-01T00:00:00Z",
                metadataJSONRedacted: "{\"credential\":\"\(secret)\"}"
            ), currentTimestamp: "2026-08-01T00:00:00Z")
            try store.events.append([EventRecord(
                id: "event-\(UUID().uuidString.lowercased())",
                timestamp: "2026-08-01T00:00:00Z",
                severity: .error,
                type: "runtime.failed",
                source: "hostwrightd",
                projectID: nil,
                serviceName: "service-\(secret)",
                runtimeAdapter: "provider-\(secret)",
                message: "password=\(secret)",
                payloadJSONRedacted: "{\"path\":\"/Users/private/\(secret)\"}"
            )])

            let snapshot = try StateMetricsService(store: store).snapshot()
            let encoded = try JSONEncoder().encode(snapshot)
            let output = String(decoding: encoded, as: UTF8.self)
            XCTAssertFalse(output.contains(secret))
            XCTAssertFalse(output.contains("/Users/private"))
            XCTAssertEqual(
                value("hostwright_errors_total", label: "component", value: "runtime", in: snapshot),
                1
            )
        }
    }

    func testMissingAndFutureDatabasesAreRefusedWithoutCreationOrMigration() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingPath = root.appendingPathComponent("missing.sqlite").path
        XCTAssertThrowsError(try StateMetricsService(
            store: SQLiteStateStore(path: missingPath)
        ).snapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingPath))

        let store = SQLiteStateStore(path: root.appendingPathComponent("future.sqlite").path)
        try store.migrate()
        try store.withValidatedConnection { connection in
            try connection.transaction {
                try connection.run(
                    "INSERT INTO schema_migrations(version, description, checksum, applied_at) VALUES (18, 'future', 'future', '2026-08-01T00:00:00Z')"
                )
            }
        }
        XCTAssertThrowsError(try StateMetricsService(store: store).snapshot())
    }

    func testVersionSixteenRequiresExplicitUpgradeAndProjectsAfterVersionSeventeenMigration() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("upgrade.sqlite").path)
        try MigrationRunner().apply(to: store, throughVersion: 16)

        XCTAssertEqual(try store.schemaVersion(), 16)
        XCTAssertThrowsError(try StateMetricsService(store: store).snapshot())
        XCTAssertEqual(try store.schemaVersion(), 16)

        try store.migrate()
        let snapshot = try StateMetricsService(store: store).snapshot()
        XCTAssertEqual(snapshot.source.schemaVersion, 17)
        XCTAssertEqual(try store.schemaVersion(), 17)
        XCTAssertEqual(snapshot.series.count, 59)
    }

    private func insertReconciliationCycles(count: Int, store: SQLiteStateStore) throws {
        try store.withValidatedConnection { connection in
            try connection.transaction {
                for index in 0..<count {
                    try connection.run(
                        """
                        INSERT INTO operation_ledger (
                            id, created_at, updated_at, planned_action_type, project_id,
                            service_name, status, idempotency_key, plan_hash,
                            payload_json_redacted
                        ) VALUES (?, '2026-08-01T00:00:00Z', '2026-08-01T00:00:01Z',
                                  'daemon.reconcile', NULL, NULL, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text("metrics-daemon-\(index)"),
                            .text(index % 1_000 == 0 ? "failed" : "succeeded"),
                            .text("metrics-daemon-\(index)"),
                            .text(digest(String(index))),
                            .text("{\"durationMilliseconds\":1000}")
                        ]
                    )
                }
            }
        }
    }

    private func insertSucceededRuntimeGroups(count: Int, store: SQLiteStateStore) throws {
        for index in 0..<count {
            let groupID = UUID().uuidString.lowercased()
            _ = try store.operationGroups.acquire(OperationGroupRecord(
                id: groupID,
                operationID: "metrics-runtime-\(index)",
                groupKind: "lifecycle-v1",
                projectID: nil,
                serviceName: nil,
                plannedActionType: "up",
                status: .active,
                groupIdempotencyKey: "metrics-runtime-\(index)",
                planHash: digest("runtime-\(index)"),
                checkpoint: "intent-persisted",
                lockOwner: "metrics-test",
                lockExpiresAt: "2026-08-01T00:10:00Z",
                rollbackAvailable: true,
                manualRecoveryHintRedacted: "",
                createdAt: "2026-08-01T00:00:00Z",
                updatedAt: "2026-08-01T00:00:00Z",
                metadataJSONRedacted: "{}"
            ), currentTimestamp: "2026-08-01T00:00:00Z")
            try store.operationGroups.finish(
                groupID: groupID,
                status: .succeeded,
                checkpoint: "verified",
                manualRecoveryHintRedacted: "",
                updatedAt: "2026-08-01T00:00:01Z",
                metadataJSONRedacted: "{}"
            )
        }
    }

    private func value(
        _ name: String,
        label: String,
        value: String,
        in snapshot: HostwrightMetricsSnapshot
    ) -> UInt64? {
        snapshot.series.first {
            $0.name == name && $0.labels[label] == value
        }?.value
    }

    private func withStore(_ body: (SQLiteStateStore) throws -> Void) throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try body(store)
    }

    private func privateRoot() throws -> URL {
        let raw = FileManager.default.temporaryDirectory.path
        let base = raw.hasPrefix("/var/") ? "/private\(raw)" : raw
        let root = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("hostwright-metrics-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private func digest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(repeating: "0", count: 48) + String(format: "%016llx", hash)
    }
}
