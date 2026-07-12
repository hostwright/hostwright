import Foundation
import XCTest
@testable import HostwrightState

final class HostwrightStateIntegrationTests: XCTestCase {
    func testTwoRealConnectionsIsolateUncommittedWritesAndShareCommittedRows() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let store = SQLiteStateStore(path: databaseURL.path)
        try store.migrate()

        let writer = try SQLiteConnection(path: databaseURL.path)
        let readerWriter = try SQLiteConnection(path: databaseURL.path)
        var transactionOpen = false
        try writer.execute("BEGIN IMMEDIATE TRANSACTION")
        transactionOpen = true
        defer {
            if transactionOpen {
                try? writer.execute("ROLLBACK")
            }
        }

        try insertEvent(id: "event-uncommitted", timestamp: "2026-07-12T10:00:00Z", on: writer)
        XCTAssertEqual(try eventIDs(on: readerWriter), [])

        try writer.execute("COMMIT")
        transactionOpen = false
        XCTAssertEqual(try eventIDs(on: readerWriter), ["event-uncommitted"])

        try insertEvent(id: "event-second-connection", timestamp: "2026-07-12T10:00:01Z", on: readerWriter)
        XCTAssertEqual(try eventIDs(on: writer), ["event-uncommitted", "event-second-connection"])
    }

    func testCommittedRowsPersistAcrossConnectionCloseAndReopen() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let store = SQLiteStateStore(path: databaseURL.path)
        try store.migrate()

        do {
            let connection = try SQLiteConnection(path: databaseURL.path)
            try insertEvent(id: "event-before-close", timestamp: "2026-07-12T10:01:00Z", on: connection)
        }

        let reopened = try SQLiteConnection(path: databaseURL.path, createIfNeeded: false, readOnly: true)
        XCTAssertEqual(try eventIDs(on: reopened), ["event-before-close"])
    }

    func testConcurrentOperationGroupAcquireAcrossStoresHasOneWinner() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let firstStore = SQLiteStateStore(path: databaseURL.path)
        let secondStore = SQLiteStateStore(path: databaseURL.path)
        try firstStore.migrate()

        for round in 0..<20 {
            let barrier = TwoPartyBarrier()
            let key = "integration:plan:create:api:\(round)"
            let firstAttempt = (
                store: firstStore,
                group: operationGroup(id: "group-first-\(round)", operationID: "operation-first-\(round)", key: key)
            )
            let secondAttempt = (
                store: secondStore,
                group: operationGroup(id: "group-second-\(round)", operationID: "operation-second-\(round)", key: key)
            )

            let results = try await withThrowingTaskGroup(of: OperationGroupAcquireResult.self) { group in
                group.addTask {
                    await barrier.wait()
                    return try firstAttempt.store.operationGroups.acquire(
                        firstAttempt.group,
                        currentTimestamp: "2026-07-12T10:02:00Z"
                    )
                }
                group.addTask {
                    await barrier.wait()
                    return try secondAttempt.store.operationGroups.acquire(
                        secondAttempt.group,
                        currentTimestamp: "2026-07-12T10:02:00Z"
                    )
                }

                var collected: [OperationGroupAcquireResult] = []
                for try await result in group {
                    collected.append(result)
                }
                return collected
            }

            XCTAssertEqual(results.filter { $0.acquired != nil }.count, 1, "round \(round)")
            XCTAssertEqual(results.filter { $0.existingActive != nil }.count, 1, "round \(round)")
        }

        let persisted = try firstStore.operationGroups.loadAll()
        XCTAssertEqual(persisted.count, 20)
        XCTAssertTrue(persisted.allSatisfy { $0.id.hasPrefix("group-first-") || $0.id.hasPrefix("group-second-") })
    }

    func testColdBackupAndRestoreRoundTripCommittedRows() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let backupURL = directory.appendingPathComponent("state.backup.sqlite")
        let restoredURL = directory.appendingPathComponent("state.restored.sqlite")
        let displacedURL = directory.appendingPathComponent("state.displaced.sqlite")
        let store = SQLiteStateStore(path: databaseURL.path)
        try store.migrate()
        try store.events.append([event(id: "event-before-backup", timestamp: "2026-07-12T10:03:00Z")])

        try FileManager.default.copyItem(at: databaseURL, to: backupURL)
        let backupStore = SQLiteStateStore(path: backupURL.path)
        try backupStore.validateSchema()
        XCTAssertEqual(try backupStore.events.loadAll().map(\.id), ["event-before-backup"])

        try store.events.append([event(id: "event-after-backup", timestamp: "2026-07-12T10:03:01Z")])
        try FileManager.default.copyItem(at: databaseURL, to: restoredURL)
        let targetBeforeRestore = SQLiteStateStore(path: restoredURL.path)
        XCTAssertEqual(
            try targetBeforeRestore.events.loadAll().map(\.id),
            ["event-before-backup", "event-after-backup"]
        )

        try FileManager.default.moveItem(at: restoredURL, to: displacedURL)
        try FileManager.default.copyItem(at: backupURL, to: restoredURL)

        let restoredStore = SQLiteStateStore(path: restoredURL.path)
        try restoredStore.validateSchema()
        XCTAssertEqual(try restoredStore.events.loadAll().map(\.id), ["event-before-backup"])
        let displacedStore = SQLiteStateStore(path: displacedURL.path)
        XCTAssertEqual(
            try displacedStore.events.loadAll().map(\.id),
            ["event-before-backup", "event-after-backup"]
        )
    }

    func testMigrationHistoryGapsFailBeforeReadVersionQueryOrMigration() throws {
        let missingVersionSets = [[1], [3], [2, 4]]

        for (index, missingVersions) in missingVersionSets.enumerated() {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let databaseURL = directory.appendingPathComponent("state-\(index).sqlite")
            let store = SQLiteStateStore(path: databaseURL.path)
            try store.migrate()

            do {
                let connection = try SQLiteConnection(path: databaseURL.path)
                for version in missingVersions {
                    try connection.run("DELETE FROM schema_migrations WHERE version = ?", bindings: [.int(version)])
                }
            }

            let actions: [() throws -> Void] = [
                { try store.validateSchema() },
                { _ = try store.schemaVersion() },
                { _ = try store.events.loadAll() },
                { try store.migrate() }
            ]
            for action in actions {
                XCTAssertThrowsError(try action()) { error in
                    guard case .incompatibleSchema(let foundVersion, let latestSupported, let message) = error as? StateStoreError else {
                        return XCTFail("Expected incompatibleSchema, got \(error).")
                    }
                    XCTAssertEqual(foundVersion, MigrationRunner.latestSchemaVersion)
                    XCTAssertEqual(latestSupported, MigrationRunner.latestSchemaVersion)
                    XCTAssertTrue(message.contains("non-contiguous Hostwright migration history"))
                    for version in missingVersions {
                        XCTAssertTrue(message.contains(String(version)))
                    }
                }
            }

            let connection = try SQLiteConnection(path: databaseURL.path, createIfNeeded: false, readOnly: true)
            let persistedVersions = try connection.query("SELECT version FROM schema_migrations ORDER BY version ASC")
                .compactMap { $0.first ?? nil }
                .compactMap(Int.init)
            XCTAssertEqual(
                persistedVersions,
                (1...MigrationRunner.latestSchemaVersion).filter { !missingVersions.contains($0) }
            )
        }
    }

    func testCorruptDatabaseFailsWithActionableError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        try Data("not a sqlite database".utf8).write(to: databaseURL)
        let store = SQLiteStateStore(path: databaseURL.path)

        XCTAssertThrowsError(try store.validateSchema()) { error in
            guard case .corruptDatabase(let path, let message) = error as? StateStoreError else {
                return XCTFail("Expected corruptDatabase, got \(error).")
            }
            XCTAssertEqual(path, databaseURL.path)
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testLockedDatabaseFailsWithActionableError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let store = SQLiteStateStore(path: databaseURL.path)
        try store.migrate()
        let lockedConnection = try SQLiteConnection(path: databaseURL.path)
        try lockedConnection.execute("BEGIN EXCLUSIVE TRANSACTION")
        defer { try? lockedConnection.execute("ROLLBACK") }

        XCTAssertThrowsError(try store.migrate()) { error in
            guard case .databaseLocked(let path, let message) = error as? StateStoreError else {
                return XCTFail("Expected databaseLocked, got \(error).")
            }
            XCTAssertEqual(path, databaseURL.path)
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testTransactionFailureRollsBackPartialWrites() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let store = SQLiteStateStore(path: databaseURL.path)
        try store.migrate()
        let connection = try SQLiteConnection(path: databaseURL.path)

        XCTAssertThrowsError(try connection.transaction {
            try insertEvent(id: "rollback-event", timestamp: "2026-07-12T10:04:00Z", on: connection)
            try insertEvent(id: "rollback-event", timestamp: "2026-07-12T10:04:01Z", on: connection)
        })

        XCTAssertEqual(try eventIDs(on: connection), [])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-state-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func insertEvent(id: String, timestamp: String, on connection: SQLiteConnection) throws {
        try connection.run(
            """
            INSERT INTO event_ledger (
                id, timestamp, severity, type, source, project_id, service_name,
                runtime_adapter, message, payload_json_redacted
            )
            VALUES (?, ?, 'info', 'integration', 'state-integration', NULL, NULL, NULL, 'integration event', '{}')
            """,
            bindings: [.text(id), .text(timestamp)]
        )
    }

    private func eventIDs(on connection: SQLiteConnection) throws -> [String] {
        try connection.query("SELECT id FROM event_ledger ORDER BY timestamp ASC, rowid ASC")
            .compactMap { $0.first ?? nil }
    }

    private func event(id: String, timestamp: String) -> EventRecord {
        EventRecord(
            id: id,
            timestamp: timestamp,
            severity: .info,
            type: "integration",
            source: "state-integration",
            projectID: nil,
            serviceName: nil,
            runtimeAdapter: nil,
            message: "integration event",
            payloadJSONRedacted: "{}"
        )
    }

    private func operationGroup(id: String, operationID: String, key: String) -> OperationGroupRecord {
        OperationGroupRecord(
            id: id,
            operationID: operationID,
            groupKind: "apply",
            projectID: nil,
            serviceName: "api",
            plannedActionType: "createMissingService",
            status: .active,
            groupIdempotencyKey: key,
            planHash: "integration-plan-hash",
            checkpoint: "prepared",
            lockOwner: "state-integration",
            lockExpiresAt: "2026-07-12T10:12:00Z",
            rollbackAvailable: false,
            manualRecoveryHintRedacted: "inspect the exact owned resource",
            createdAt: "2026-07-12T10:02:00Z",
            updatedAt: "2026-07-12T10:02:00Z",
            metadataJSONRedacted: "{}"
        )
    }
}

private actor TwoPartyBarrier {
    private var firstWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if let firstWaiter {
            self.firstWaiter = nil
            firstWaiter.resume()
            return
        }

        await withCheckedContinuation { continuation in
            firstWaiter = continuation
        }
    }
}
