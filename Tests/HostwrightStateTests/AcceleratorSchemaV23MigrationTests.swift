import Foundation
import XCTest

@testable import HostwrightState

final class AcceleratorSchemaV23MigrationTests: XCTestCase {
    func testV22ToV23CreatesDedicatedAcceleratorAuthorityTables() throws {
        try withTemporaryStore(throughVersion: 22) { store, _ in
            XCTAssertEqual(try store.schemaVersion(), 22)

            try store.migrate()

            XCTAssertEqual(try store.schemaVersion(), 23)
            XCTAssertEqual(MigrationRunner.latestSchemaVersion, 23)
            try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
                let tables = Set(
                    try connection.query(
                        """
                        SELECT name FROM sqlite_master
                        WHERE type = 'table'
                          AND name IN ('accelerator_state_journal', 'accelerator_state_current')
                        """
                    ).compactMap { $0.first ?? nil }
                )
                XCTAssertEqual(
                    tables,
                    Set(["accelerator_state_journal", "accelerator_state_current"])
                )

                let indexes = Set(
                    try connection.query(
                        """
                        SELECT name FROM sqlite_master
                        WHERE type = 'index'
                          AND name LIKE 'accelerator_state_%'
                        """
                    ).compactMap { $0.first ?? nil }
                )
                XCTAssertTrue(
                    indexes.isSuperset(of: [
                        "accelerator_state_journal_type_id_idx",
                        "accelerator_state_current_record_scope_idx",
                        "accelerator_state_current_generation_idx",
                        "accelerator_state_current_record_idx"
                    ])
                )
            }
            try store.validateSchema()
        }
    }

    func testScopeSentinelIsRejectedAndGlobalCurrentIsUnique() throws {
        try withTemporaryStore(throughVersion: 23) { store, _ in
            try store.withConnection { connection in
                XCTAssertThrowsError(
                    try connection.run(
                        """
                        INSERT INTO accelerator_state_journal (
                            id, timestamp, severity, type, source, project_id,
                            message, payload_json_redacted
                        ) VALUES (?, ?, 'info', 'accelerator.state.inventory',
                                  'accelerator-state-journal', ?,
                                  'durable accelerator state append', ?)
                        """,
                        bindings: [
                            .text("sentinel-journal"),
                            .text("1970-01-01T00:00:00Z"),
                            .text("__global__"),
                            .text("{\"envelopeVersion\":1}")
                        ]
                    )
                )

                let values: [SQLiteValue] = [
                    .text("global-current-1"),
                    .text("1970-01-01T00:00:00Z"),
                    .text("info"),
                    .text("accelerator.state.inventory"),
                    .text("accelerator-state-journal"),
                    .null,
                    .text("durable accelerator state append"),
                    .text("{\"envelopeVersion\":1}"),
                    .text("inventory-global"),
                    .int(1)
                ]
                var sentinelValues = values
                sentinelValues[5] = .text("__global__")
                XCTAssertThrowsError(
                    try connection.run(
                        """
                        INSERT INTO accelerator_state_current (
                            id, timestamp, severity, type, source, project_id,
                            message, payload_json_redacted, record_id, generation
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: sentinelValues
                    )
                )
                try connection.run(
                    """
                    INSERT INTO accelerator_state_current (
                        id, timestamp, severity, type, source, project_id,
                        message, payload_json_redacted, record_id, generation
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: values
                )
                XCTAssertThrowsError(
                    try connection.run(
                        """
                        INSERT INTO accelerator_state_current (
                            id, timestamp, severity, type, source, project_id,
                            message, payload_json_redacted, record_id, generation
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text("global-current-2"),
                            .text("1970-01-01T00:00:01Z"),
                            .text("info"),
                            .text("accelerator.state.inventory"),
                            .text("accelerator-state-journal"),
                            .null,
                            .text("durable accelerator state append"),
                            .text("{\"envelopeVersion\":1}"),
                            .text("inventory-global"),
                            .int(2)
                        ]
                    )
                )
            }
        }
    }

    func testV23MigrationRollsBackDedicatedTablesOnConflict() throws {
        try withTemporaryStore(throughVersion: 22) { store, _ in
            try store.withConnection { connection in
                try connection.execute(
                    "CREATE TABLE accelerator_state_journal (unexpected INTEGER)"
                )
            }

            XCTAssertThrowsError(try store.migrate())
            XCTAssertEqual(try store.schemaVersion(), 22)
            try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
                let currentExists = try connection.query(
                    """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name = 'accelerator_state_current'
                    """
                )
                XCTAssertTrue(currentExists.isEmpty)
            }
        }
    }

    func testPreReplayV23DatabaseUpgradesTransactionallyAndAcceptsReplayRecords() throws {
        try withTemporaryStore(throughVersion: 22) { store, _ in
            let legacyStatements = MigrationRunner.legacyV23AcceleratorStatements()
            XCTAssertEqual(legacyStatements.count, 6)
            try store.withConnection { connection in
                for statement in legacyStatements {
                    try connection.execute(statement)
                }
                try connection.run(
                    """
                    INSERT INTO accelerator_state_journal (
                        id, timestamp, severity, type, source, project_id,
                        message, payload_json_redacted
                    ) VALUES (?, ?, 'info', 'accelerator.state.inventory',
                              'accelerator-state-journal', NULL,
                              'durable accelerator state append', ?)
                    """,
                    bindings: [
                        .text("legacy-journal-1"),
                        .text("2026-08-08T12:00:00Z"),
                        .text("{\"envelopeVersion\":1}")
                    ]
                )
                try connection.run(
                    """
                    INSERT INTO accelerator_state_current (
                        id, timestamp, severity, type, source, project_id,
                        message, payload_json_redacted, record_id, generation
                    ) VALUES (?, ?, 'info', 'accelerator.state.inventory',
                              'accelerator-state-journal', NULL,
                              'durable accelerator state append', ?, ?, 1)
                    """,
                    bindings: [
                        .text("legacy-current-1"),
                        .text("2026-08-08T12:00:00Z"),
                        .text("{\"envelopeVersion\":1}"),
                        .text("inventory-1")
                    ]
                )
                try connection.run(
                    """
                    INSERT INTO schema_migrations (
                        version, description, checksum, applied_at
                    ) VALUES (23, ?, ?, ?)
                    """,
                    bindings: [
                        .text("Dedicated accelerator authority journal and current indexes"),
                        .text(MigrationRunner.legacyV23AcceleratorChecksum),
                        .text("2026-08-08T12:00:00Z")
                    ]
                )
            }

            XCTAssertThrowsError(try store.validateSchema()) { error in
                guard case .incompatibleSchema(_, let latest, let message) =
                    error as? StateStoreError else {
                    return XCTFail("expected explicit pre-replay migration refusal, got \(error)")
                }
                XCTAssertEqual(latest, 23)
                XCTAssertTrue(message.contains("replay table upgrade"))
            }

            try store.migrate()
            XCTAssertEqual(try store.schemaVersion(), 23)
            try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
                let preserved = try connection.query(
                    """
                    SELECT COUNT(*) FROM accelerator_state_current
                    WHERE type = 'accelerator.state.inventory' AND record_id = 'inventory-1'
                    """
                )
                XCTAssertEqual(preserved.first?.first, "1")
                let currentSQL = try connection.query(
                    """
                    SELECT sql FROM sqlite_master
                    WHERE type = 'table' AND name = 'accelerator_state_journal'
                    """
                ).first.flatMap { $0.first ?? nil } ?? ""
                XCTAssertTrue(currentSQL.contains("accelerator.state.xpc-replay"))
            }
            try store.withConnection { connection in
                try connection.run(
                    """
                    INSERT INTO accelerator_state_journal (
                        id, timestamp, severity, type, source, project_id,
                        message, payload_json_redacted
                    ) VALUES (?, ?, 'info', 'accelerator.state.xpc-replay',
                              'accelerator-state-journal', NULL,
                              'durable accelerator state append', ?)
                    """,
                    bindings: [
                        .text("replay-journal-1"),
                        .text("2026-08-08T12:00:01Z"),
                        .text("{\"envelopeVersion\":1}")
                    ]
                )
                try connection.run(
                    """
                    INSERT INTO accelerator_state_current (
                        id, timestamp, severity, type, source, project_id,
                        message, payload_json_redacted, record_id, generation
                    ) VALUES (?, ?, 'info', 'accelerator.state.xpc-replay',
                              'accelerator-state-journal', NULL,
                              'durable accelerator state append', ?, ?, 1)
                    """,
                    bindings: [
                        .text("replay-current-1"),
                        .text("2026-08-08T12:00:01Z"),
                        .text("{\"envelopeVersion\":1}"),
                        .text("replay-1")
                    ]
                )
            }
            try store.validateSchema()
        }
    }

    func testPreReplayV23UpgradeRejectsTamperedLegacyTableAndLeavesLedgerUnchanged() throws {
        try withTemporaryStore(throughVersion: 22) { store, _ in
            let legacyStatements = MigrationRunner.legacyV23AcceleratorStatements()
            XCTAssertEqual(legacyStatements.count, 6)
            try store.withConnection { connection in
                for (index, statement) in legacyStatements.enumerated() {
                    if index == 1 {
                        try connection.execute(
                            statement.replacingOccurrences(
                                of: "record_id TEXT NOT NULL CHECK (length(record_id) BETWEEN 1 AND 128),",
                                with: "record_id TEXT NOT NULL,"
                            )
                        )
                    } else {
                        try connection.execute(statement)
                    }
                }
                try connection.run(
                    """
                    INSERT INTO schema_migrations (
                        version, description, checksum, applied_at
                    ) VALUES (23, ?, ?, ?)
                    """,
                    bindings: [
                        .text("Dedicated accelerator authority journal and current indexes"),
                        .text(MigrationRunner.legacyV23AcceleratorChecksum),
                        .text("2026-08-08T12:00:00Z")
                    ]
                )
            }

            XCTAssertThrowsError(try store.migrate())
            try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
                let checksum = try connection.query(
                    "SELECT checksum FROM schema_migrations WHERE version = 23"
                ).first?.first
                XCTAssertEqual(checksum, MigrationRunner.legacyV23AcceleratorChecksum)
                let currentTable = try connection.query(
                    """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name = 'accelerator_state_current'
                    """
                )
                XCTAssertEqual(currentTable.count, 1)
                let replayRows = try connection.query(
                    """
                    SELECT COUNT(*) FROM accelerator_state_current
                    WHERE type = 'accelerator.state.xpc-replay'
                    """
                )
                XCTAssertEqual(replayRows.first?.first, "0")
            }
        }
    }

    func testUnknownSchemaVersionAndTamperedV23ChecksumFailClosed() throws {
        try withTemporaryStore(throughVersion: 23) { store, _ in
            try store.withConnection { connection in
                try connection.run(
                    """
                    INSERT INTO schema_migrations (version, description, checksum, applied_at)
                    VALUES (?, 'future accelerator schema', 'future-checksum', ?)
                    """,
                    bindings: [
                        .int(24),
                        .text("2026-08-05T12:00:00Z")
                    ]
                )
            }

            XCTAssertThrowsError(try store.validateSchema()) { error in
                guard case .incompatibleSchema(
                    let foundVersion, let latestSupported, _
                ) = error as? StateStoreError else {
                    return XCTFail("Expected future-schema refusal, got (error)")
                }
                XCTAssertEqual(foundVersion, 24)
                XCTAssertEqual(latestSupported, 23)
            }
        }

        try withTemporaryStore(throughVersion: 23) { store, _ in
            try store.withConnection { connection in
                try connection.run(
                    "UPDATE schema_migrations SET checksum = ? WHERE version = 23",
                    bindings: [.text("tampered")]
                )
            }

            XCTAssertThrowsError(try store.validateSchema())
            XCTAssertThrowsError(try store.migrate())
        }
    }

    private func withTemporaryStore(
        throughVersion: Int,
        _ body: (SQLiteStateStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-accelerator-schema-v23-(UUID().uuidString)",
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
