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
                    status: .failed,
                    idempotencyKey: "plan-hash:create:api:retry",
                    planHash: "plan-hash",
                    payloadJSONRedacted: #"{"error":"token=\#(fakeSecret)"}"#
                )
            )
            try store.operations.record(
                OperationRecord(
                    id: "operation-4",
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
            XCTAssertEqual(operations.count, 4)
            XCTAssertEqual(operations[0].status, .planned)
            XCTAssertEqual(operations[1].status, .succeeded)
            XCTAssertEqual(operations[2].status, .failed)
            XCTAssertEqual(operations[3].status, .succeeded)
            XCTAssertFalse(operations[0].payloadJSONRedacted.contains(fakeSecret))
            XCTAssertFalse(operations[2].payloadJSONRedacted.contains(fakeSecret))
            XCTAssertEqual(try store.operations.latest(idempotencyKey: "plan-hash:create:api:retry")?.status, .succeeded)
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
        try store.desiredStates.saveManifestSnapshot(
            projectID: projectID,
            manifestPath: "/tmp/hostwright.yaml",
            manifestHash: "manifest-hash-1",
            desiredGeneration: 1,
            manifest: manifest,
            timestamp: timestamp
        )
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
