import Foundation
import HostwrightManifest
import HostwrightRuntime
import HostwrightState

let hostwrightStateSmoke: Void = {
    let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-state-smoke-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    let databaseURL = tempDirectory.appendingPathComponent("state.sqlite")
    let store = SQLiteStateStore(path: databaseURL.path)

    try! store.migrate()
    try! store.migrate()
    precondition(FileManager.default.fileExists(atPath: databaseURL.path))
    precondition(try! store.schemaVersion() == MigrationRunner.latestSchemaVersion)
    precondition(store.configuration.origin == .explicit)

    let timestamp = "2026-07-01T00:00:00Z"
    let manifest = HostwrightManifest(
        project: "api-local",
        services: [
            HostwrightService(
                name: "api",
                image: "ghcr.io/example/api:latest",
                command: ["serve"],
                env: ["API_TOKEN": "plain-secret-token"],
                ports: ["8080:8080"]
            )
        ]
    )

    try! store.desiredStates.saveManifestSnapshot(
        projectID: "project-api-local",
        manifestPath: "/tmp/hostwright.yaml",
        manifestHash: "manifest-hash-1",
        desiredGeneration: 1,
        manifest: manifest,
        timestamp: timestamp
    )

    let project = try! store.desiredStates.loadProject(id: "project-api-local")
    precondition(project.name == "api-local")

    let desiredServices = try! store.desiredStates.loadDesiredServices(projectID: "project-api-local")
    precondition(desiredServices.count == 1)
    precondition(desiredServices[0].serviceName == "api")
    precondition(desiredServices[0].environmentJSONRedacted.contains("[REDACTED]"))
    precondition(!desiredServices[0].environmentJSONRedacted.contains("plain-secret-token"))

    let observed = ObservedRuntimeState(
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
            adapterVersion: "0.0.0-dev",
            runtimeName: "apple-container",
            runtimeVersion: nil,
            supportsMutation: false,
            capabilities: [.readOnlyObservation]
        )
    )

    try! store.observedStates.saveSnapshot(
        snapshotID: "snapshot-1",
        projectID: "project-api-local",
        observedState: observed,
        runtimeAdapter: "apple-container-cli",
        parserVersion: "hostwright.apple-container.observation.v1",
        rawOutputHash: "raw-output-hash",
        redactedSummary: "token=plain-secret-token",
        observedAt: timestamp
    )

    let snapshots = try! store.observedStates.loadSnapshots(projectID: "project-api-local")
    precondition(snapshots.count == 1)
    precondition(snapshots[0].redactedSummary.contains("[REDACTED]"))
    precondition(!snapshots[0].redactedSummary.contains("plain-secret-token"))

    let observedServices = try! store.observedStates.loadObservedServices(snapshotID: "snapshot-1")
    precondition(observedServices.count == 1)
    precondition(observedServices[0].lifecycleState == .running)

    try! store.events.append([
        EventRecord(
            id: "event-1",
            timestamp: "2026-07-01T00:00:01Z",
            severity: .info,
            type: "state.desired.saved",
            source: "state-smoke",
            projectID: "project-api-local",
            serviceName: "api",
            runtimeAdapter: nil,
            message: "saved token=plain-secret-token",
            payloadJSONRedacted: #"{"token":"plain-secret-token"}"#
        ),
        EventRecord(
            id: "event-2",
            timestamp: "2026-07-01T00:00:02Z",
            severity: .warning,
            type: "state.observed.saved",
            source: "state-smoke",
            projectID: "project-api-local",
            serviceName: "api",
            runtimeAdapter: "apple-container-cli",
            message: "snapshot persisted",
            payloadJSONRedacted: "{}"
        )
    ])

    let events = try! store.events.loadAll()
    precondition(events.map(\.id) == ["event-1", "event-2"])
    precondition(events[0].message.contains("[REDACTED]"))
    precondition(!events[0].payloadJSONRedacted.contains("plain-secret-token"))

    try! store.operations.record(
        OperationRecord(
            id: "operation-1",
            createdAt: timestamp,
            updatedAt: timestamp,
            plannedActionType: "create",
            projectID: "project-api-local",
            serviceName: "api",
            status: .planned,
            idempotencyKey: "plan-hash:create:api",
            planHash: "plan-hash",
            payloadJSONRedacted: #"{"password":"plain-secret-token"}"#
        )
    )

    let operations = try! store.operations.loadAll()
    precondition(operations.count == 1)
    precondition(operations[0].status == .planned)
    precondition(!operations[0].payloadJSONRedacted.contains("plain-secret-token"))

    try! store.ownership.upsert(
        OwnershipRecord(
            id: "owner-1",
            resourceIdentifier: "apple-container://api-local/api",
            resourceType: "container",
            projectID: "project-api-local",
            serviceName: "api",
            runtimeAdapter: "apple-container-cli",
            createdAt: timestamp,
            observedAt: timestamp,
            cleanupEligible: false,
            metadataJSONRedacted: #"{"token":"plain-secret-token"}"#
        )
    )

    let ownership = try! store.ownership.loadAll()
    precondition(ownership.count == 1)
    precondition(ownership[0].cleanupEligible == false)
    precondition(!ownership[0].metadataJSONRedacted.contains("plain-secret-token"))

    let invalidStore = SQLiteStateStore(path: tempDirectory.path)
    do {
        try invalidStore.migrate()
        preconditionFailure("Opening a directory as a SQLite database should fail.")
    } catch {
        precondition(String(describing: error).contains("Failed to open state database"))
    }
}()
