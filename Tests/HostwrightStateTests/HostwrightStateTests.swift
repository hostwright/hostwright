import Foundation
import Synchronization
import XCTest
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightSecrets
@testable import HostwrightState

final class HostwrightStateTests: XCTestCase {
    let projectID = "project-api-local"
    let snapshotID = "snapshot-1"
    let timestamp = "2026-07-01T00:00:00Z"
    let fakeSecret = "plain-secret-token"

    func lifecycleOwnershipMetadata(
        for identity: RuntimeServiceIdentity
    ) -> String {
        let instanceName = identity.instanceName.map { "\"\($0)\"" } ?? "null"
        return """
        {"schemaVersion":1,"projectName":"\(identity.projectName)","serviceName":"\(identity.serviceName)","instanceName":\(instanceName)}
        """
    }

    func withTemporaryStore(_ body: (SQLiteStateStore, URL) throws -> Void) throws {
        try withTemporaryDirectory { directory in
            let databaseURL = directory.appendingPathComponent("state.sqlite")
            let store = SQLiteStateStore(path: databaseURL.path)
            try body(store, databaseURL)
        }
    }

    func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-state-xctest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory)
    }

    func saveDesiredState(in store: SQLiteStateStore) throws {
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

    func insertOwnershipRecord(
        connection: SQLiteConnection,
        id: String,
        runtimeAdapter: String
    ) throws {
        try connection.run(
            """
            INSERT INTO ownership_records (
                id, resource_identifier, resource_type, project_id, service_name, runtime_adapter,
                created_at, observed_at, cleanup_eligible, metadata_json_redacted
            )
            VALUES (?, ?, 'container', NULL, 'api', ?, ?, ?, 1, '{}')
            """,
            bindings: [
                .text(id),
                .text("hostwright-api-local-api"),
                .text(runtimeAdapter),
                .text(timestamp),
                .text(timestamp)
            ]
        )
    }

    func tableCounts(in databasePath: String) throws -> [String: Int] {
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

    func saveObservedSnapshot(in store: SQLiteStateStore) throws {
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

    var manifest: HostwrightManifest {
        HostwrightManifest(
            project: "api-local",
            services: [
                HostwrightService(
                    name: "api",
                    image: "ghcr.io/example/api:latest",
                    command: ["serve"],
                    env: ["APP_ENV": "test"],
                    secretEnv: ["API_TOKEN": try! HostwrightSecretReference.parse("keychain://hostwright.api/api-token")],
                    ports: ["8080:8080"]
                )
            ]
        )
    }

    var observedState: ObservedRuntimeState {
        ObservedRuntimeState(
            projectName: "api-local",
            services: [
                ObservedRuntimeService(
                    identity: RuntimeServiceIdentity(projectName: "api-local", serviceName: "api", instanceName: "api-1"),
                    resourceIdentifier: RuntimeServiceIdentity(projectName: "api-local", serviceName: "api", instanceName: "api-1").managedResourceIdentifier,
                    image: "ghcr.io/example/api:latest",
                    lifecycleState: .running,
                    healthState: .unknown,
                    ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)],
                    networks: [
                        RuntimeNetworkAttachment(
                            name: "default",
                            hostname: "api.local",
                            ipv4Address: "192.168.64.2/24",
                            ipv4Gateway: "192.168.64.1",
                            macAddress: "02:00:00:00:00:02",
                            mtu: 1280
                        )
                    ],
                    observedAt: timestamp
                )
            ],
            adapterMetadata: RuntimeAdapterMetadata(
                providerID: .appleContainerCLI,
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
