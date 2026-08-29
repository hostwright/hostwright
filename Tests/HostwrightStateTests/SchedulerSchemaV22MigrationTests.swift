import Foundation
import XCTest

@testable import HostwrightCore
@testable import HostwrightState

final class SchedulerSchemaV22MigrationTests: XCTestCase {
    func testV21UpgradeAddsSchedulerSchemaWithoutChangingPriorRows() throws {
        try withTemporaryStore(throughVersion: 21) { store, _ in
            let projectUUID = UUID().uuidString.lowercased()
            try insertProject(id: "phase10-project", resourceUUID: projectUUID, in: store)

            try MigrationRunner().apply(to: store, throughVersion: 23)

            XCTAssertEqual(try store.schemaVersion(), 23)
            XCTAssertEqual(MigrationRunner.latestSchemaVersion, 24)
            XCTAssertEqual(
                try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
                    try connection.query(
                        "SELECT resource_uuid FROM projects WHERE id = ?",
                        bindings: [.text("phase10-project")]
                    ).first?.first ?? nil
                },
                projectUUID
            )

            let schedulerObjects = try store.withConnection(
                createIfNeeded: false,
                readOnly: true
            ) { connection in
                let tables = try connection.query(
                    """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name LIKE 'scheduler_%'
                    ORDER BY name
                    """
                ).compactMap { $0.first ?? nil }
                let indexes = try connection.query(
                    """
                    SELECT name FROM sqlite_master
                    WHERE type = 'index' AND name LIKE 'scheduler_%'
                    ORDER BY name
                    """
                ).compactMap { $0.first ?? nil }
                return (tables, indexes)
            }

            XCTAssertTrue(Set(schedulerObjects.0).isSuperset(of: [
                "scheduler_decisions",
                "scheduler_fence_state",
                "scheduler_node_capacity_snapshots",
                "scheduler_reservations",
                "scheduler_fairness_accounting",
                "scheduler_disruption_budgets",
                "scheduler_preemption_intents",
                "scheduler_host_pressure",
            ]))
            XCTAssertTrue(Set(schedulerObjects.1).isSuperset(of: [
                "scheduler_decisions_node_idx",
                "scheduler_decisions_workload_idx",
                "scheduler_node_capacity_generation_idx",
                "scheduler_reservations_active_workload_idx",
                "scheduler_reservations_decision_idx",
                "scheduler_reservations_node_idx",
                "scheduler_reservations_workload_idx",
                "scheduler_fairness_project_idx",
                "scheduler_disruption_budgets_project_idx",
                "scheduler_preemption_intents_project_idx",
                "scheduler_host_pressure_generation_idx",
            ]))
        }
    }

    func testV22MigrationRollsBackAllSchedulerObjectsWhenOneStatementFails() throws {
        try withTemporaryStore(throughVersion: 21) { store, _ in
            try store.withConnection { connection in
                try connection.execute("CREATE TABLE scheduler_decisions (unexpected INTEGER)")
            }

            XCTAssertThrowsError(try store.migrate())
            XCTAssertEqual(try store.schemaVersion(), 21)

            let remainingObjects = try store.withConnection(
                createIfNeeded: false,
                readOnly: true
            ) { connection in
                try connection.query(
                    """
                    SELECT name FROM sqlite_master
                    WHERE (type = 'table' OR type = 'index')
                      AND name IN (
                        'scheduler_decisions', 'scheduler_fence_state',
                        'scheduler_node_capacity_snapshots',
                        'scheduler_reservations',
                        'scheduler_fairness_accounting',
                        'scheduler_disruption_budgets',
                        'scheduler_preemption_intents',
                        'scheduler_host_pressure',
                        'scheduler_decisions_node_idx', 'scheduler_decisions_workload_idx',
                        'scheduler_node_capacity_generation_idx',
                        'scheduler_reservations_active_workload_idx',
                        'scheduler_reservations_decision_idx',
                        'scheduler_reservations_node_idx',
                        'scheduler_reservations_workload_idx',
                        'scheduler_fairness_project_idx',
                        'scheduler_disruption_budgets_project_idx',
                        'scheduler_preemption_intents_project_idx',
                        'scheduler_host_pressure_generation_idx'
                      )
                    ORDER BY type, name
                    """
                ).compactMap { $0.first ?? nil }
            }
            XCTAssertEqual(remainingObjects, ["scheduler_decisions"])

            // Remove only the test-injected conflict. A retry must be able to
            // complete the entire v22/v23 chain after the interrupted attempt.
            try store.withConnection { connection in
                try connection.execute("DROP TABLE scheduler_decisions")
            }
            try store.migrate()
            XCTAssertEqual(try store.schemaVersion(), 24)
            let reopened = SQLiteStateStore(path: store.path)
            XCTAssertEqual(try reopened.schemaVersion(), 24)
            try reopened.validateSchema()
        }
    }

    func testV22ChecksumTamperingRefusesReopenAndFurtherMigration() throws {
        try withTemporaryStore(throughVersion: 23) { store, _ in
            try store.withConnection { connection in
                try connection.run(
                    "UPDATE schema_migrations SET checksum = 'tampered-v22' WHERE version = 22"
                )
            }

            let reopened = SQLiteStateStore(path: store.path)
            let actions: [() throws -> Void] = [
                { try reopened.validateSchema() },
                { _ = try reopened.schemaVersion() },
                { try reopened.migrate() },
            ]
            for action in actions {
                XCTAssertThrowsError(try action()) { error in
                    guard case .migrationFailed(let version, let message) = error as? StateStoreError else {
                        return XCTFail("Expected v22 checksum refusal, got \(error).")
                    }
                    XCTAssertEqual(version, 22)
                    XCTAssertTrue(message.contains("Recorded checksum"), message)
                }
            }
        }
    }

    func testFutureSchemaVersionRefusalRemainsFailClosedAfterV22() throws {
        try withTemporaryStore(throughVersion: 23) { store, _ in
            try store.withConnection { connection in
                try connection.run(
                    """
                    INSERT INTO schema_migrations (version, description, checksum, applied_at)
                    VALUES (?, 'future scheduler schema', 'future-checksum', ?)
                    """,
                    bindings: [.int(25), .text("2026-08-05T12:00:00Z")]
                )
            }

            for action in [
                { try store.validateSchema() },
                { _ = try store.schemaVersion() },
                { try store.migrate() },
            ] as [() throws -> Void] {
                XCTAssertThrowsError(try action()) { error in
                    guard case .incompatibleSchema(
                        let foundVersion, let latestSupported, _
                    ) = error as? StateStoreError else {
                        return XCTFail("Expected future-schema refusal, got \(error)")
                    }
                    XCTAssertEqual(foundVersion, 25)
                    XCTAssertEqual(latestSupported, 24)
                }
            }
        }
    }

    func testV22FencingSchemaUsesPairedTokensAndRejectsInvalidFenceState() throws {
        try withTemporaryStore(throughVersion: 23) { store, _ in
            let stateColumns = try store.withConnection(
                createIfNeeded: false,
                readOnly: true
            ) { connection in
                try connection.query("PRAGMA table_info(scheduler_fence_state)")
                    .compactMap { $0.count > 1 ? $0[1] : nil }
            }
            XCTAssertTrue(stateColumns.contains("node_epoch"))
            XCTAssertTrue(stateColumns.contains("next_reservation_sequence"))
            XCTAssertFalse(stateColumns.contains("fencing_token"))

            try store.withConnection { connection in
                XCTAssertThrowsError(
                    try connection.run(
                        """
                        INSERT INTO scheduler_fence_state (
                            node_uuid, node_epoch, next_reservation_sequence, updated_at
                        ) VALUES (?, 0, 1, ?)
                        """,
                        bindings: [
                            .text("00000000-0000-0000-0000-000000000901"),
                            .text("2026-08-05T12:00:00Z"),
                        ]
                    )
                )
                XCTAssertThrowsError(
                    try connection.run(
                        """
                        INSERT INTO scheduler_fence_state (
                            node_uuid, node_epoch, next_reservation_sequence, updated_at
                        ) VALUES (?, 1, 0, ?)
                        """,
                        bindings: [
                            .text("00000000-0000-0000-0000-000000000902"),
                            .text("2026-08-05T12:00:00Z"),
                        ]
                    )
                )
                let sql = try XCTUnwrap(
                    try connection.query(
                        "SELECT sql FROM sqlite_master WHERE name = ?",
                        bindings: [.text("scheduler_reservations")]
                    ).first?.first ?? nil
                )
                let normalizedSQL = sql
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                XCTAssertTrue(normalizedSQL.contains("fencing_node_epoch"))
                XCTAssertTrue(normalizedSQL.contains("fencing_reservation_sequence"))
                XCTAssertTrue(normalizedSQL.contains("UNIQUE (node_uuid, fencing_reservation_sequence)"))
                XCTAssertTrue(normalizedSQL.contains("fence_evidence_node_epoch > fencing_node_epoch"))
                XCTAssertTrue(normalizedSQL.contains("release_evidence_node_epoch >= fence_evidence_node_epoch"))
                XCTAssertTrue(normalizedSQL.contains("julianday(fence_evidence_at) <= julianday(release_evidence_at)"))
                XCTAssertFalse(normalizedSQL.contains("fence_evidence_token"))
                XCTAssertFalse(normalizedSQL.contains("release_evidence_fencing_token"))
            }
        }
    }

    private func insertProject(
        id: String,
        resourceUUID: String,
        in store: SQLiteStateStore
    ) throws {
        try store.withConnection { connection in
            try connection.run(
                """
                INSERT INTO projects (
                    id, name, manifest_path, manifest_hash, created_at, updated_at,
                    resource_uuid, manifest_version, mutation_provider, provider_generation
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(id), .text(id), .null, .text(String(repeating: "a", count: 64)),
                    .text("2026-08-05T12:00:00Z"), .text("2026-08-05T12:00:00Z"),
                    .text(resourceUUID), .int(1), .null, .int(0),
                ]
            )
        }
    }

    private func withTemporaryStore(
        throughVersion: Int,
        _ body: (SQLiteStateStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-scheduler-schema-v22-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        try MigrationRunner().apply(to: store, throughVersion: throughVersion)
        try body(store, directory)
    }
}
