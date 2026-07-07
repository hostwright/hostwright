import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightState

final class HostwrightStateTests: XCTestCase {
    func testSQLiteMigrationsAreIdempotentAndRecordSchemaVersion() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            try store.migrate()

            XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
            XCTAssertEqual(store.configuration.origin, .explicit)
        }
    }

    func testRepeatedMigrationPreservesExistingStateRows() throws {
        try withTemporaryStore { store, databaseURL in
            try saveDesiredState(in: store)
            let beforeCounts = try tableCounts(in: databaseURL.path)

            try store.migrate()
            try store.validateSchema()

            let afterCounts = try tableCounts(in: databaseURL.path)
            XCTAssertEqual(beforeCounts["projects"], 1)
            XCTAssertEqual(beforeCounts["desired_services"], 1)
            XCTAssertEqual(beforeCounts, afterCounts)
            XCTAssertEqual(try store.desiredStates.loadProject(id: projectID).name, "api-local")
        }
    }

    func testRepositoryReadsDoNotCreateOrMigrateStateDatabase() throws {
        try withTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("missing.sqlite")
            let store = SQLiteStateStore(path: databaseURL.path)

            XCTAssertThrowsError(try store.events.loadAll()) { error in
                XCTAssertTrue(String(describing: error).contains("Failed to open state database"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        }
    }

    func testReadOfUnmigratedDatabaseDoesNotCreateMigrationTable() throws {
        try withTemporaryStore { store, databaseURL in
            _ = try SQLiteConnection(path: databaseURL.path)

            XCTAssertThrowsError(try store.events.loadAll()) { error in
                guard case .incompatibleSchema(let foundVersion, let latestSupported, let message) = error as? StateStoreError else {
                    return XCTFail("Expected incompatibleSchema, got \(error).")
                }
                XCTAssertEqual(foundVersion, 0)
                XCTAssertEqual(latestSupported, MigrationRunner.latestSchemaVersion)
                XCTAssertTrue(message.contains("has not been migrated"))
            }

            let connection = try SQLiteConnection(path: databaseURL.path, createIfNeeded: false, readOnly: true)
            let tables = try connection.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name ASC")
                .compactMap { $0.first ?? nil }
            XCTAssertFalse(tables.contains("schema_migrations"))
        }
    }

    func testFutureSchemaVersionFailsBeforeMigrationOrRead() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            let futureVersion = MigrationRunner.latestSchemaVersion + 1
            let connection = try SQLiteConnection(path: databaseURL.path)
            try connection.run(
                """
                INSERT INTO schema_migrations (version, description, checksum, applied_at)
                    VALUES (?, 'future schema', 'future-checksum', '2026-07-01T00:00:00Z')
                """,
                bindings: [.int(futureVersion)]
            )

            for action in [
                { try store.validateSchema() },
                { try store.migrate() }
            ] {
                XCTAssertThrowsError(try action()) { error in
                    guard case .incompatibleSchema(let foundVersion, let latestSupported, let message) = error as? StateStoreError else {
                        return XCTFail("Expected incompatibleSchema, got \(error).")
                    }
                    XCTAssertEqual(foundVersion, futureVersion)
                    XCTAssertEqual(latestSupported, MigrationRunner.latestSchemaVersion)
                    XCTAssertTrue(message.contains("newer Hostwright release"))
                }
            }
        }
    }

    func testMigrationChecksumMismatchFailsClosed() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            let connection = try SQLiteConnection(path: databaseURL.path)
            try connection.run("UPDATE schema_migrations SET checksum = 'tampered' WHERE version = 1")

            XCTAssertThrowsError(try store.validateSchema()) { error in
                guard case .migrationFailed(let version, let message) = error as? StateStoreError else {
                    return XCTFail("Expected migrationFailed, got \(error).")
                }
                XCTAssertEqual(version, 1)
                XCTAssertTrue(message.contains("Recorded checksum tampered"))
            }
        }
    }

    func testExplicitMigrationRefusesExistingNonHostwrightDatabase() throws {
        try withTemporaryStore { store, databaseURL in
            let connection = try SQLiteConnection(path: databaseURL.path)
            try connection.execute("CREATE TABLE unrelated (id TEXT PRIMARY KEY)")

            XCTAssertThrowsError(try store.migrate()) { error in
                guard case .incompatibleSchema(let foundVersion, let latestSupported, let message) = error as? StateStoreError else {
                    return XCTFail("Expected incompatibleSchema, got \(error).")
                }
                XCTAssertNil(foundVersion)
                XCTAssertEqual(latestSupported, MigrationRunner.latestSchemaVersion)
                XCTAssertTrue(message.contains("non-Hostwright tables"))
            }
        }
    }

    func testCorruptDatabaseFailsWithActionableError() throws {
        try withTemporaryDirectory { directory in
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
    }

    func testLockedDatabaseFailsWithActionableError() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            let lockedConnection = try SQLiteConnection(path: databaseURL.path)
            try lockedConnection.execute("BEGIN EXCLUSIVE TRANSACTION")
            defer {
                try? lockedConnection.execute("ROLLBACK")
            }

            XCTAssertThrowsError(try store.migrate()) { error in
                guard case .databaseLocked(let path, let message) = error as? StateStoreError else {
                    return XCTFail("Expected databaseLocked, got \(error).")
                }
                XCTAssertEqual(path, databaseURL.path)
                XCTAssertFalse(message.isEmpty)
            }
        }
    }

    func testTransactionFailureRollsBackPartialWrites() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            let connection = try SQLiteConnection(path: databaseURL.path)

            XCTAssertThrowsError(try connection.transaction {
                try connection.run(
                    """
                    INSERT INTO event_ledger (
                        id, timestamp, severity, type, source, project_id, service_name,
                        runtime_adapter, message, payload_json_redacted
                    )
                    VALUES ('rollback-event', '2026-07-01T00:00:00Z', 'info', 'test', 'state-test',
                            NULL, NULL, NULL, 'before failure', '{}')
                    """
                )
                try connection.run(
                    """
                    INSERT INTO event_ledger (
                        id, timestamp, severity, type, source, project_id, service_name,
                        runtime_adapter, message, payload_json_redacted
                    )
                    VALUES ('rollback-event', '2026-07-01T00:00:01Z', 'info', 'test', 'state-test',
                            NULL, NULL, NULL, 'duplicate failure', '{}')
                    """
                )
            })

            let countRows = try connection.query("SELECT COUNT(*) FROM event_ledger WHERE id = 'rollback-event'")
            XCTAssertEqual(countRows.first?.first.flatMap { $0 }.flatMap(Int.init), 0)
        }
    }

    func testDesiredServicesPersistReloadAndRedactEnvironment() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)

            let project = try store.desiredStates.loadProject(id: projectID)
            XCTAssertEqual(project.name, "api-local")

            let desiredServices = try store.desiredStates.loadDesiredServices(projectID: projectID)
            XCTAssertEqual(desiredServices.count, 1)
            XCTAssertEqual(desiredServices[0].serviceName, "api")
            XCTAssertTrue(desiredServices[0].environmentJSONRedacted.contains("[REDACTED]"))
            XCTAssertFalse(desiredServices[0].environmentJSONRedacted.contains(fakeSecret))
        }
    }

    func testObservedSnapshotsPersistReloadAndRedactSummary() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try saveObservedSnapshot(in: store)

            let snapshots = try store.observedStates.loadSnapshots(projectID: projectID)
            XCTAssertEqual(snapshots.count, 1)
            XCTAssertTrue(snapshots[0].redactedSummary.contains("[REDACTED]"))
            XCTAssertFalse(snapshots[0].redactedSummary.contains(fakeSecret))

            let observedServices = try store.observedStates.loadObservedServices(snapshotID: snapshotID)
            XCTAssertEqual(observedServices.count, 1)
            XCTAssertEqual(observedServices[0].lifecycleState, .running)
        }
    }

    func testEventLedgerAppendsInOrderAndRedactsPayloads() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try store.events.append([
                EventRecord(
                    id: "event-1",
                    timestamp: "2026-07-01T00:00:01Z",
                    severity: .info,
                    type: "state.desired.saved",
                    source: "state-test",
                    projectID: projectID,
                    serviceName: "api",
                    runtimeAdapter: nil,
                    message: "saved token=\(fakeSecret)",
                    payloadJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                ),
                EventRecord(
                    id: "event-2",
                    timestamp: "2026-07-01T00:00:01Z",
                    severity: .warning,
                    type: "state.observed.saved",
                    source: "state-test",
                    projectID: projectID,
                    serviceName: "api",
                    runtimeAdapter: "apple-container-cli",
                    message: "snapshot persisted",
                    payloadJSONRedacted: "{}"
                )
            ])

            let events = try store.events.loadAll()
            XCTAssertEqual(events.map(\.id), ["event-1", "event-2"])
            XCTAssertEqual(events.map(\.timestamp), ["2026-07-01T00:00:01Z", "2026-07-01T00:00:01Z"])
            XCTAssertTrue(events[0].message.contains("[REDACTED]"))
            XCTAssertFalse(events[0].payloadJSONRedacted.contains(fakeSecret))
        }
    }

    func testOperationLedgerRecordsIntentWithoutExecution() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try store.operations.record(
                OperationRecord(
                    id: "operation-1",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    plannedActionType: "create",
                    projectID: projectID,
                    serviceName: "api",
                    status: .planned,
                    idempotencyKey: "plan-hash:create:api",
                    planHash: "plan-hash",
                    payloadJSONRedacted: #"{"password":"\#(fakeSecret)"}"#
                )
            )
            try store.operations.record(
                OperationRecord(
                    id: "operation-2",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    plannedActionType: "createMissingService",
                    projectID: projectID,
                    serviceName: "api",
                    status: .succeeded,
                    idempotencyKey: "plan-hash:create:api:2",
                    planHash: "plan-hash",
                    payloadJSONRedacted: #"{"result":"succeeded"}"#
                )
            )
            try store.operations.record(
                OperationRecord(
                    id: "operation-3",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    plannedActionType: "createMissingService",
                    projectID: projectID,
                    serviceName: "api",
                    status: .recorded,
                    idempotencyKey: "plan-hash:create:api:retry",
                    planHash: "plan-hash",
                    payloadJSONRedacted: #"{"intent":"recorded"}"#
                )
            )
            try store.operations.record(
                OperationRecord(
                    id: "operation-4",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    plannedActionType: "createMissingService",
                    projectID: projectID,
                    serviceName: "api",
                    status: .failed,
                    idempotencyKey: "plan-hash:create:api:retry",
                    planHash: "plan-hash",
                    payloadJSONRedacted: #"{"error":"token=\#(fakeSecret)"}"#
                )
            )
            XCTAssertEqual(try store.operations.latest(idempotencyKey: "plan-hash:create:api:retry")?.status, .failed)
            try store.operations.record(
                OperationRecord(
                    id: "operation-5",
                    createdAt: timestamp,
                    updatedAt: "2026-07-01T00:00:01Z",
                    plannedActionType: "createMissingService",
                    projectID: projectID,
                    serviceName: "api",
                    status: .succeeded,
                    idempotencyKey: "plan-hash:create:api:retry",
                    planHash: "plan-hash",
                    payloadJSONRedacted: #"{"result":"succeeded"}"#
                )
            )

            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations.count, 5)
            XCTAssertEqual(operations[0].status, .planned)
            XCTAssertEqual(operations[1].status, .succeeded)
            XCTAssertEqual(operations[2].status, .recorded)
            XCTAssertEqual(operations[3].status, .failed)
            XCTAssertEqual(operations[4].status, .succeeded)
            XCTAssertFalse(operations[0].payloadJSONRedacted.contains(fakeSecret))
            XCTAssertFalse(operations[3].payloadJSONRedacted.contains(fakeSecret))
            XCTAssertEqual(try store.operations.latest(idempotencyKey: "plan-hash:create:api:retry")?.status, .succeeded)
        }
    }

    func testHealthCheckResultsAppendInOrderAndRedactOutputs() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try store.healthResults.append([
                HealthCheckResultRecord(
                    id: "health-1",
                    projectID: projectID,
                    serviceName: "api",
                    checkedAt: "2026-07-01T00:00:01Z",
                    status: .healthy,
                    exitStatus: 0,
                    timedOut: false,
                    commandJSONRedacted: #"["curl","http://localhost?token=\#(fakeSecret)"]"#,
                    stdoutRedacted: "ok token=\(fakeSecret)",
                    stderrRedacted: "",
                    metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                ),
                HealthCheckResultRecord(
                    id: "health-2",
                    projectID: projectID,
                    serviceName: "api",
                    checkedAt: "2026-07-01T00:00:02Z",
                    status: .unhealthy,
                    exitStatus: 7,
                    timedOut: false,
                    commandJSONRedacted: #"["curl","http://localhost"]"#,
                    stdoutRedacted: "",
                    stderrRedacted: "password=\(fakeSecret)",
                    metadataJSONRedacted: "{}"
                )
            ])

            let results = try store.healthResults.loadProject(projectID: projectID)
            XCTAssertEqual(results.map(\.id), ["health-1", "health-2"])
            XCTAssertEqual(results.map(\.status), [.healthy, .unhealthy])
            XCTAssertEqual(try store.healthResults.latest(projectID: projectID, serviceName: "api")?.id, "health-2")
            XCTAssertFalse(results.map(\.commandJSONRedacted).joined().contains(fakeSecret))
            XCTAssertFalse(results.map(\.stdoutRedacted).joined().contains(fakeSecret))
            XCTAssertFalse(results.map(\.stderrRedacted).joined().contains(fakeSecret))
            XCTAssertFalse(results.map(\.metadataJSONRedacted).joined().contains(fakeSecret))
        }
    }

    func testRestartPolicyStateUpsertsAndRedactsMetadata() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try store.restartPolicies.upsert(
                RestartPolicyStateRecord(
                    id: "restart-1",
                    projectID: projectID,
                    serviceName: "api",
                    policy: .onFailure,
                    status: .backingOff,
                    attemptCount: 1,
                    maxAttempts: 3,
                    backoffSeconds: 60,
                    backoffUntil: "2026-07-01T00:01:00Z",
                    lastFailureAt: "2026-07-01T00:00:00Z",
                    updatedAt: timestamp,
                    metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                )
            )
            try store.restartPolicies.upsert(
                RestartPolicyStateRecord(
                    id: "restart-2",
                    projectID: projectID,
                    serviceName: "api",
                    policy: .onFailure,
                    status: .crashLoopBlocked,
                    attemptCount: 3,
                    maxAttempts: 3,
                    backoffSeconds: 60,
                    backoffUntil: nil,
                    lastFailureAt: "2026-07-01T00:00:30Z",
                    updatedAt: "2026-07-01T00:00:30Z",
                    metadataJSONRedacted: #"{"password":"\#(fakeSecret)"}"#
                )
            )

            let state = try XCTUnwrap(store.restartPolicies.load(projectID: projectID, serviceName: "api"))
            XCTAssertEqual(state.id, "restart-2")
            XCTAssertEqual(state.status, .crashLoopBlocked)
            XCTAssertEqual(state.attemptCount, 3)
            XCTAssertFalse(state.metadataJSONRedacted.contains(fakeSecret))
            XCTAssertEqual(try store.restartPolicies.loadProject(projectID: projectID).count, 1)
        }
    }

    func testRestartRecoveryRecordsAppendAndRedactHints() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try store.restartRecovery.append(
                RestartRecoveryRecord(
                    id: "recovery-1",
                    operationID: "operation-restart",
                    projectID: projectID,
                    serviceName: "api",
                    resourceIdentifier: "hostwright-demo-api",
                    planHash: "plan-hash",
                    status: .prepared,
                    completedStepsJSONRedacted: #"[]"#,
                    manualRecoveryHintRedacted: "prepared token=\(fakeSecret)",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                )
            )
            try store.restartRecovery.append(
                RestartRecoveryRecord(
                    id: "recovery-2",
                    operationID: "operation-restart",
                    projectID: projectID,
                    serviceName: "api",
                    resourceIdentifier: "hostwright-demo-api",
                    planHash: "plan-hash",
                    status: .stopSucceeded,
                    completedStepsJSONRedacted: #"["stop"]"#,
                    manualRecoveryHintRedacted: "container stopped; password=\(fakeSecret)",
                    createdAt: timestamp,
                    updatedAt: "2026-07-01T00:00:01Z",
                    metadataJSONRedacted: "{}"
                )
            )

            let records = try store.restartRecovery.load(operationID: "operation-restart")
            XCTAssertEqual(records.map(\.status), [.prepared, .stopSucceeded])
            XCTAssertEqual(try store.restartRecovery.latest(operationID: "operation-restart")?.status, .stopSucceeded)
            XCTAssertEqual(try store.restartRecovery.loadAll().count, 2)
            XCTAssertFalse(records.map(\.manualRecoveryHintRedacted).joined().contains(fakeSecret))
            XCTAssertFalse(records.map(\.metadataJSONRedacted).joined().contains(fakeSecret))
        }
    }

    func testOwnershipRecordsPersistWithoutCleanupBehavior() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "owner-1",
                    resourceIdentifier: "apple-container://api-local/api",
                    resourceType: "container",
                    projectID: projectID,
                    serviceName: "api",
                    runtimeAdapter: "apple-container-cli",
                    createdAt: timestamp,
                    observedAt: timestamp,
                    cleanupEligible: false,
                    metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                )
            )

            let ownership = try store.ownership.loadAll()
            XCTAssertEqual(ownership.count, 1)
            XCTAssertFalse(ownership[0].cleanupEligible)
            XCTAssertFalse(ownership[0].metadataJSONRedacted.contains(fakeSecret))
        }
    }

    func testOpeningDirectoryAsDatabaseFailsSafely() throws {
        try withTemporaryDirectory { directory in
            let invalidStore = SQLiteStateStore(path: directory.path)

            XCTAssertThrowsError(try invalidStore.migrate()) { error in
                XCTAssertTrue(String(describing: error).contains("Failed to open state database"))
            }
        }
    }

    private let projectID = "project-api-local"
    private let snapshotID = "snapshot-1"
    private let timestamp = "2026-07-01T00:00:00Z"
    private let fakeSecret = "plain-secret-token"

    private func withTemporaryStore(_ body: (SQLiteStateStore, URL) throws -> Void) throws {
        try withTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("state.sqlite")
            let store = SQLiteStateStore(path: databaseURL.path)
            try body(store, databaseURL)
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-state-xctest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory)
    }

    private func saveDesiredState(in store: SQLiteStateStore) throws {
        try store.migrate()
        try store.desiredStates.saveManifestSnapshot(
            projectID: projectID,
            manifestPath: "/tmp/hostwright.yaml",
            manifestHash: "manifest-hash-1",
            desiredGeneration: 1,
            manifest: manifest,
            timestamp: timestamp
        )
    }

    private func tableCounts(in databasePath: String) throws -> [String: Int] {
        let connection = try SQLiteConnection(path: databasePath, createIfNeeded: false, readOnly: true)
        let tableRows = try connection.query(
            """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table'
              AND name NOT LIKE 'sqlite_%'
            ORDER BY name ASC
            """
        )
        let tableNames = tableRows.compactMap { $0.first ?? nil }

        var counts: [String: Int] = [:]
        for tableName in tableNames {
            let rows = try connection.query("SELECT COUNT(*) FROM \(tableName)")
            counts[tableName] = rows.first?.first.flatMap { $0 }.flatMap(Int.init)
        }
        return counts
    }

    private func saveObservedSnapshot(in store: SQLiteStateStore) throws {
        try store.observedStates.saveSnapshot(
            snapshotID: snapshotID,
            projectID: projectID,
            observedState: observedState,
            runtimeAdapter: "apple-container-cli",
            parserVersion: "hostwright.apple-container.observation.v1",
            rawOutputHash: "raw-output-hash",
            redactedSummary: "token=\(fakeSecret)",
            observedAt: timestamp
        )
    }

    private var manifest: HostwrightManifest {
        HostwrightManifest(
            project: "api-local",
            services: [
                HostwrightService(
                    name: "api",
                    image: "ghcr.io/example/api:latest",
                    command: ["serve"],
                    env: ["API_TOKEN": fakeSecret],
                    ports: ["8080:8080"]
                )
            ]
        )
    }

    private var observedState: ObservedRuntimeState {
        ObservedRuntimeState(
            projectName: "api-local",
            services: [
                ObservedRuntimeService(
                    identity: RuntimeServiceIdentity(projectName: "api-local", serviceName: "api", instanceName: "api-1"),
                    image: "ghcr.io/example/api:latest",
                    lifecycleState: .running,
                    healthState: .unknown,
                    ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)],
                    observedAt: timestamp
                )
            ],
            adapterMetadata: RuntimeAdapterMetadata(
                adapterName: "apple-container-read-only",
                adapterVersion: HostwrightIdentity.version,
                runtimeName: "apple-container",
                runtimeVersion: nil,
                supportsMutation: false,
                capabilities: [.readOnlyObservation]
            )
        )
    }
}
