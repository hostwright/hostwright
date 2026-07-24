import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightState

final class SchemaV7ContractTests: XCTestCase {
    func testMigrationChecksumIncludesNonSQLBackfillRevision() {
        let first = SchemaMigration(
            version: 7,
            description: "test",
            implementationRevision: "backfill-v1",
            statements: ["SELECT 1"]
        )
        let second = SchemaMigration(
            version: 7,
            description: "test",
            implementationRevision: "backfill-v2",
            statements: ["SELECT 1"]
        )

        XCTAssertNotEqual(first.checksum, second.checksum)
    }

    func testSchemaV7AddsIdentityBackendAndSagaContractsWithDeterministicBackfill() throws {
        try withTemporaryStore { store, databaseURL in
            XCTAssertEqual(MigrationRunner.latestSchemaVersion, HostwrightContractVersions.stateSchema)
            try MigrationRunner().apply(to: store, throughVersion: 6)
            let connection = try SQLiteConnection(path: databaseURL.path)
            try connection.run(
                "INSERT INTO projects (id, name, manifest_path, manifest_hash, created_at, updated_at) VALUES ('project-legacy', 'demo', NULL, 'hash', 'now', 'now')"
            )
            try connection.run(
                "INSERT INTO projects (id, name, manifest_path, manifest_hash, created_at, updated_at) VALUES ('project-legacy-2', 'demo-2', NULL, 'hash-2', 'now', 'now')"
            )
            try connection.run(
                "INSERT INTO ownership_records (id, resource_identifier, resource_type, project_id, service_name, runtime_adapter, created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version) VALUES ('ownership-legacy', 'hostwright-demo-api', 'container', 'project-legacy', 'api', 'AppleContainerApplyAdapter', 'now', 'now', 0, '{}', 1)"
            )
            try connection.run(
                "INSERT INTO ownership_records (id, resource_identifier, resource_type, project_id, service_name, runtime_adapter, created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version) VALUES ('ownership-legacy-2', 'hostwright-demo-2-worker-a', 'container', 'project-legacy-2', 'worker', 'AppleContainerReadOnlyAdapter', 'now', 'now', 0, '{}', 1)"
            )
            try connection.run(
                "INSERT INTO ownership_records (id, resource_identifier, resource_type, project_id, service_name, runtime_adapter, created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version) VALUES ('ownership-legacy-3', 'hostwright-demo-2-worker-b', 'container', 'project-legacy-2', 'worker', 'apple-container-cli', 'now', 'now', 0, '{}', 1)"
            )
            try connection.run(
                "INSERT INTO operation_groups (id, operation_id, group_kind, project_id, service_name, planned_action_type, status, group_idempotency_key, plan_hash, checkpoint, rollback_available, manual_recovery_hint_redacted, created_at, updated_at, metadata_json_redacted) VALUES ('group-legacy', 'operation-legacy', 'apply', 'project-legacy', 'api', 'create', 'active', 'key', 'plan', 'intent', 1, '', 'now', 'now', '{}')"
            )
            try connection.run(
                "INSERT INTO operation_groups (id, operation_id, group_kind, project_id, service_name, planned_action_type, status, group_idempotency_key, plan_hash, checkpoint, rollback_available, manual_recovery_hint_redacted, created_at, updated_at, metadata_json_redacted) VALUES ('group-legacy-2', 'operation-legacy-2', 'apply', 'project-legacy-2', 'worker', 'create', 'interrupted', 'key-2', 'plan-2', 'intent', 1, '', 'now', 'now', '{}')"
            )
            try connection.run(
                "INSERT INTO desired_services (id, project_id, service_name, image, command_json, ports_json, mounts_json, env_json_redacted, manifest_hash, desired_generation, created_at, updated_at) VALUES ('desired-legacy', 'project-legacy', 'api', 'local/demo:latest', '[]', '[]', '[]', '{}', 'hash', 1, 'now', 'now')"
            )
            try connection.run(
                "INSERT INTO desired_services (id, project_id, service_name, image, command_json, ports_json, mounts_json, env_json_redacted, manifest_hash, desired_generation, created_at, updated_at) VALUES ('desired-legacy-2', 'project-legacy-2', 'worker', 'local/demo:latest', '[]', '[]', '[]', '{}', 'hash-2', 3, 'now', 'now')"
            )

            try store.migrate()

            XCTAssertEqual(try store.schemaVersion(), 7)
            XCTAssertEqual(Set(try columns(in: "projects", connection: connection)), Set([
                "id", "name", "manifest_path", "manifest_hash", "created_at", "updated_at",
                "resource_uuid", "manifest_version", "mutation_provider", "provider_generation"
            ]))
            XCTAssertTrue(Set(try columns(in: "ownership_records", connection: connection)).isSuperset(of: ["resource_uuid", "resource_generation"]))
            XCTAssertTrue(Set(try columns(in: "desired_services", connection: connection)).isSuperset(of: [
                "resource_uuid", "resource_generation", "mutation_provider"
            ]))
            XCTAssertTrue(Set(try columns(in: "ownership_records", connection: connection)).isSuperset(of: [
                "project_resource_uuid", "project_generation", "provider_generation", "fencing_token"
            ]))
            XCTAssertTrue(Set(try columns(in: "operation_groups", connection: connection)).isSuperset(of: [
                "fencing_token", "intent_json_redacted", "compensation_json_redacted", "verification_json_redacted"
            ]))

            let project = try XCTUnwrap(try connection.query("SELECT resource_uuid, manifest_version, mutation_provider, provider_generation FROM projects WHERE id = 'project-legacy'").first)
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(project[0])))
            XCTAssertEqual(project[1], "1")
            XCTAssertEqual(project[2], RuntimeProviderID.appleContainerCLI.rawValue)
            XCTAssertEqual(project[3], "1")
            let secondProjectBinding = try XCTUnwrap(
                try connection.query(
                    "SELECT mutation_provider, provider_generation FROM projects WHERE id = 'project-legacy-2'"
                ).first
            )
            XCTAssertEqual(secondProjectBinding[0], RuntimeProviderID.appleContainerCLI.rawValue)
            XCTAssertEqual(secondProjectBinding[1], "1")
            let ownership = try XCTUnwrap(try connection.query("SELECT resource_uuid, resource_generation FROM ownership_records WHERE id = 'ownership-legacy'").first)
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(ownership[0])))
            XCTAssertEqual(ownership[1], "1")

            let desired = try XCTUnwrap(try connection.query("SELECT resource_uuid, resource_generation, mutation_provider FROM desired_services WHERE id = 'desired-legacy'").first)
            XCTAssertEqual(
                desired[0],
                HostwrightResourceUUID.legacy(kind: "service", identifier: "project-legacy:api")
            )
            XCTAssertEqual(desired[1], "1")
            XCTAssertEqual(desired[2], RuntimeProviderID.appleContainerCLI.rawValue)
            XCTAssertEqual(ownership[0], desired[0])
            let ownershipBinding = try XCTUnwrap(try connection.query("SELECT project_resource_uuid, project_generation, provider_generation, fencing_token FROM ownership_records WHERE id = 'ownership-legacy'").first)
            XCTAssertEqual(ownershipBinding[0], project[0])
            XCTAssertEqual(ownershipBinding[1], "1")
            XCTAssertEqual(ownershipBinding[2], "1")
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(ownershipBinding[3])))

            let projectUUIDs = try connection.query("SELECT resource_uuid FROM projects ORDER BY id").compactMap { $0[0] }
            let ownershipUUIDs = try connection.query("SELECT resource_uuid FROM ownership_records ORDER BY id").compactMap { $0[0] }
            let fencingTokens = try connection.query("SELECT fencing_token FROM operation_groups ORDER BY id").compactMap { $0[0] }
            XCTAssertEqual(projectUUIDs.count, 2)
            XCTAssertEqual(Set(projectUUIDs).count, 2)
            XCTAssertEqual(ownershipUUIDs.count, 3)
            XCTAssertEqual(Set(ownershipUUIDs).count, 3)
            let duplicateOwnershipUUIDs = try connection.query(
                "SELECT resource_uuid FROM ownership_records WHERE project_id = 'project-legacy-2' ORDER BY id"
            ).compactMap { $0[0] }
            XCTAssertTrue(duplicateOwnershipUUIDs.allSatisfy {
                $0 != HostwrightResourceUUID.legacy(kind: "service", identifier: "project-legacy-2:worker")
            })
            XCTAssertEqual(fencingTokens.count, 2)
            XCTAssertEqual(Set(fencingTokens).count, 2)
            XCTAssertTrue(fencingTokens.allSatisfy { UUID(uuidString: $0) != nil })

            let hints = try store.ownership.runtimeHints(
                projectID: "project-legacy",
                projectName: "demo",
                providerID: .appleContainerCLI
            )
            let hint = try XCTUnwrap(hints.first)
            let evidence = try XCTUnwrap(hint.ownership)
            XCTAssertEqual(hints.count, 1)
            XCTAssertEqual(evidence.projectUUID, project[0])
            XCTAssertEqual(evidence.projectGeneration, 1)
            XCTAssertEqual(evidence.providerID, .appleContainerCLI)
            XCTAssertEqual(evidence.providerGeneration, 1)
            XCTAssertEqual(evidence.resourceUUID, desired[0])

            XCTAssertEqual(
                try store.desiredStates.commitRuntimeProviderMigration(
                    projectResourceUUID: try XCTUnwrap(project[0]),
                    projectGeneration: evidence.projectGeneration,
                    expectedSourceProviderID: .appleContainerCLI,
                    expectedSourceProviderGeneration: evidence.providerGeneration,
                    targetProviderID: .appleContainerization,
                    targetProviderGeneration: evidence.providerGeneration + 1,
                    targetFencingToken: "44444444-4444-4444-8444-444444444444",
                    resources: [
                        RuntimeProviderMigrationStateResource(
                            resourceIdentifier: hint.resourceIdentifier,
                            serviceName: hint.identity.serviceName,
                            identityVersion: hint.identityVersion,
                            resourceUUID: evidence.resourceUUID,
                            resourceGeneration: evidence.resourceGeneration
                        )
                    ],
                    timestamp: "2026-07-19T12:00:00Z"
                ),
                .committed(projectID: "project-legacy")
            )
        }
    }

    func testSchemaV7MigrationRejectsConflictingLegacyProjectProviders() throws {
        try withTemporaryStore { store, databaseURL in
            try MigrationRunner().apply(to: store, throughVersion: 6)
            let connection = try SQLiteConnection(path: databaseURL.path)
            try connection.run(
                "INSERT INTO projects (id, name, manifest_path, manifest_hash, created_at, updated_at) VALUES ('project-conflict', 'conflict', NULL, 'hash', 'now', 'now')"
            )
            try connection.run(
                "INSERT INTO ownership_records (id, resource_identifier, resource_type, project_id, service_name, runtime_adapter, created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version) VALUES ('ownership-cli', 'hostwright-conflict-api', 'container', 'project-conflict', 'api', 'AppleContainerApplyAdapter', 'now', 'now', 0, '{}', 1)"
            )
            try connection.run(
                "INSERT INTO ownership_records (id, resource_identifier, resource_type, project_id, service_name, runtime_adapter, created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version) VALUES ('ownership-containerization', 'hostwright-conflict-worker', 'container', 'project-conflict', 'worker', 'AppleContainerizationAdapter', 'now', 'now', 0, '{}', 1)"
            )

            XCTAssertThrowsError(try store.migrate()) { error in
                guard case .migrationFailed(let version, let message) = error as? StateStoreError else {
                    return XCTFail("Expected migrationFailed, got \(error).")
                }
                XCTAssertEqual(version, 7)
                XCTAssertTrue(message.contains("project-conflict"), message)
                XCTAssertTrue(message.contains("conflicting runtime providers"), message)
            }
            XCTAssertEqual(try store.schemaVersion(), 6)
            XCTAssertFalse(try columns(in: "projects", connection: connection).contains("mutation_provider"))
        }
    }

    func testPreviouslyAppliedSchemaV7RunsProviderBindingRevisionTransactionally() throws {
        try withTemporaryStore { store, databaseURL in
            try MigrationRunner().apply(to: store, throughVersion: 6)
            let connection = try SQLiteConnection(path: databaseURL.path)
            try connection.run(
                "INSERT INTO projects (id, name, manifest_path, manifest_hash, created_at, updated_at) VALUES ('project-applied-v7', 'applied-v7', NULL, 'hash', 'now', 'now')"
            )
            try connection.run(
                "INSERT INTO ownership_records (id, resource_identifier, resource_type, project_id, service_name, runtime_adapter, created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version) VALUES ('ownership-applied-v7', 'hostwright-applied-v7-api', 'container', 'project-applied-v7', 'api', 'AppleContainerApplyAdapter', 'now', 'now', 0, '{}', 1)"
            )
            try store.migrate()

            try connection.execute(
                "UPDATE projects SET mutation_provider = NULL, provider_generation = 0 WHERE id = 'project-applied-v7'"
            )
            try connection.execute(
                "UPDATE schema_migrations SET checksum = 'fnv1a64:5bf70e7832651a2' WHERE version = 7"
            )

            try store.migrate()

            let binding = try XCTUnwrap(
                try connection.query(
                    "SELECT mutation_provider, provider_generation FROM projects WHERE id = 'project-applied-v7'"
                ).first
            )
            XCTAssertEqual(binding[0], RuntimeProviderID.appleContainerCLI.rawValue)
            XCTAssertEqual(binding[1], "1")
            let recordedChecksum = try XCTUnwrap(
                try connection.query("SELECT checksum FROM schema_migrations WHERE version = 7")
                    .first?.first ?? nil
            )
            XCTAssertNotEqual(recordedChecksum, "fnv1a64:5bf70e7832651a2")
            XCTAssertNoThrow(try MigrationRunner().validateAppliedSchema(in: store))
        }
    }

    func testLegacyUUIDBackfillIsRepeatableForTheSameIdentifier() {
        XCTAssertEqual(
            HostwrightResourceUUID.legacy(kind: "project", identifier: "project-legacy"),
            HostwrightResourceUUID.legacy(kind: "project", identifier: "project-legacy")
        )
        XCTAssertNotEqual(
            HostwrightResourceUUID.legacy(kind: "project", identifier: "project-legacy"),
            HostwrightResourceUUID.legacy(kind: "ownership", identifier: "project-legacy")
        )
    }

    func testProjectGenerationCannotSilentlySwitchMutationProviders() throws {
        try withTemporaryStore { store, _ in
            try store.migrate()
            let manifest = HostwrightManifest(
                version: 2,
                project: "demo",
                services: [HostwrightService(name: "api", image: "local/demo:latest")]
            )
            try store.desiredStates.saveManifestSnapshot(
                projectID: "project-demo",
                manifestPath: "/tmp/hostwright.yaml",
                manifestHash: "hash-1",
                desiredGeneration: 1,
                manifest: manifest,
                timestamp: "2026-07-13T00:00:00Z",
                mutationProvider: "apple-container-cli"
            )
            try store.desiredStates.saveManifestSnapshot(
                projectID: "project-demo",
                manifestPath: "/tmp/hostwright.yaml",
                manifestHash: "hash-2",
                desiredGeneration: 2,
                manifest: manifest,
                timestamp: "2026-07-13T00:01:00Z",
                mutationProvider: "apple-container-cli"
            )

            let project = try store.desiredStates.loadProject(id: "project-demo")
            XCTAssertEqual(project.manifestVersion, 2)
            XCTAssertEqual(project.mutationProvider, "apple-container-cli")
            XCTAssertEqual(project.providerGeneration, 2)
            let desired = try store.desiredStates.loadDesiredServices(projectID: "project-demo")
            XCTAssertEqual(desired.count, 2)
            XCTAssertEqual(Set(desired.map(\.resourceUUID)).count, 1)
            XCTAssertTrue(desired.allSatisfy { $0.mutationProvider == "apple-container-cli" })
            XCTAssertThrowsError(
                try store.desiredStates.saveManifestSnapshot(
                    projectID: "project-demo",
                    manifestPath: "/tmp/hostwright.yaml",
                    manifestHash: "hash-3",
                    desiredGeneration: 3,
                    manifest: manifest,
                    timestamp: "2026-07-13T00:02:00Z",
                    mutationProvider: "containerization-helper"
                )
            )
            XCTAssertEqual(
                try store.desiredStates.loadProject(id: "project-demo").mutationProvider,
                "apple-container-cli"
            )
        }
    }

    func testOwnershipUpsertPreservesUUIDAndAdvancesGeneration() throws {
        try withTemporaryStore { store, _ in
            try store.migrate()
            let initialUUID = HostwrightResourceUUID.generate()
            let projectUUID = HostwrightResourceUUID.generate()
            let initialFence = HostwrightResourceUUID.generate()
            let currentFence = HostwrightResourceUUID.generate()
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "ownership-initial",
                    resourceIdentifier: "hostwright-demo-api",
                    resourceType: "container",
                    projectID: nil,
                    serviceName: "api",
                    runtimeAdapter: "apple-container-cli",
                    createdAt: "2026-07-13T00:00:00Z",
                    observedAt: "2026-07-13T00:00:00Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}",
                    resourceUUID: initialUUID,
                    resourceGeneration: 1,
                    projectResourceUUID: projectUUID,
                    projectGeneration: 1,
                    providerGeneration: 1,
                    fencingToken: initialFence
                )
            )
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "ownership-retry",
                    resourceIdentifier: "hostwright-demo-api",
                    resourceType: "container",
                    projectID: nil,
                    serviceName: "api",
                    runtimeAdapter: "apple-container-cli",
                    createdAt: "2026-07-13T00:01:00Z",
                    observedAt: "2026-07-13T00:01:00Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}",
                    resourceUUID: HostwrightResourceUUID.generate(),
                    resourceGeneration: 2,
                    projectResourceUUID: projectUUID,
                    projectGeneration: 2,
                    providerGeneration: 2,
                    fencingToken: currentFence
                )
            )
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "ownership-stale",
                    resourceIdentifier: "hostwright-demo-api",
                    resourceType: "container",
                    projectID: nil,
                    serviceName: "api",
                    runtimeAdapter: "apple-container-cli",
                    createdAt: "2026-07-13T00:00:30Z",
                    observedAt: "2026-07-13T00:00:30Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}",
                    resourceUUID: HostwrightResourceUUID.generate(),
                    resourceGeneration: 1,
                    projectResourceUUID: projectUUID,
                    projectGeneration: 1,
                    providerGeneration: 1,
                    fencingToken: HostwrightResourceUUID.generate()
                )
            )

            let ownership = try XCTUnwrap(store.ownership.loadAll().first)
            XCTAssertEqual(ownership.resourceUUID, initialUUID)
            XCTAssertEqual(ownership.resourceGeneration, 2)
            XCTAssertEqual(ownership.projectResourceUUID, projectUUID)
            XCTAssertEqual(ownership.projectGeneration, 2)
            XCTAssertEqual(ownership.providerGeneration, 2)
            XCTAssertEqual(ownership.fencingToken, currentFence)

            let nextFence = HostwrightResourceUUID.generate()
            let advanced = try store.ownership.advanceFencingToken(
                resourceIdentifier: ownership.resourceIdentifier,
                runtimeAdapter: ownership.runtimeAdapter,
                expectedResourceUUID: ownership.resourceUUID,
                expectedFencingToken: ownership.fencingToken,
                newFencingToken: nextFence,
                observedAt: "2026-07-13T00:02:00Z"
            )
            XCTAssertEqual(advanced?.fencingToken, nextFence)
            XCTAssertNil(
                try store.ownership.advanceFencingToken(
                    resourceIdentifier: ownership.resourceIdentifier,
                    runtimeAdapter: ownership.runtimeAdapter,
                    expectedResourceUUID: ownership.resourceUUID,
                    expectedFencingToken: ownership.fencingToken,
                    newFencingToken: HostwrightResourceUUID.generate(),
                    observedAt: "2026-07-13T00:03:00Z"
                )
            )
        }
    }

    func testOwnershipRejectsInvalidUUIDAndGenerationFields() throws {
        try withTemporaryStore { store, _ in
            try store.migrate()
            XCTAssertThrowsError(
                try store.ownership.upsert(
                    OwnershipRecord(
                        id: "ownership-invalid",
                        resourceIdentifier: "hostwright-demo-api",
                        resourceType: "container",
                        projectID: nil,
                        serviceName: "api",
                        runtimeAdapter: "apple-container-cli",
                        createdAt: "2026-07-13T00:00:00Z",
                        observedAt: "2026-07-13T00:00:00Z",
                        cleanupEligible: true,
                        metadataJSONRedacted: "{}",
                        resourceUUID: "not-a-uuid",
                        resourceGeneration: 0,
                        fencingToken: "not-a-fence"
                    )
                )
            )
        }
    }

    func testOwnershipRemovalRequiresTheExactResourceUUIDAndFence() throws {
        try withTemporaryStore { store, _ in
            try store.migrate()
            let resourceUUID = HostwrightResourceUUID.generate()
            let fence = HostwrightResourceUUID.generate()
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "ownership-remove-exact",
                    resourceIdentifier: "hostwright-demo-api",
                    resourceType: "container",
                    projectID: nil,
                    serviceName: "api",
                    runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                    createdAt: "2026-07-23T00:00:00Z",
                    observedAt: "2026-07-23T00:00:00Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}",
                    resourceUUID: resourceUUID,
                    resourceGeneration: 1,
                    projectResourceUUID: HostwrightResourceUUID.generate(),
                    projectGeneration: 1,
                    providerGeneration: 1,
                    fencingToken: fence
                )
            )

            XCTAssertFalse(
                try store.ownership.removeExact(
                    resourceIdentifier: "hostwright-demo-api",
                    runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                    expectedResourceUUID: resourceUUID,
                    expectedFencingToken: HostwrightResourceUUID.generate()
                )
            )
            XCTAssertEqual(try store.ownership.loadAll().count, 1)
            XCTAssertTrue(
                try store.ownership.removeExact(
                    resourceIdentifier: "hostwright-demo-api",
                    runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                    expectedResourceUUID: resourceUUID,
                    expectedFencingToken: fence
                )
            )
            XCTAssertTrue(try store.ownership.loadAll().isEmpty)
        }
    }

    private func columns(in table: String, connection: SQLiteConnection) throws -> [String] {
        try connection.query("PRAGMA table_info(\(table))").compactMap { $0[1] }
    }

    private func withTemporaryStore(_ body: (SQLiteStateStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-schema-v7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        try body(SQLiteStateStore(path: databaseURL.path), databaseURL)
    }
}
