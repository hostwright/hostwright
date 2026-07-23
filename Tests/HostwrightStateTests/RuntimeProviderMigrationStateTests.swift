import Foundation
import XCTest
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightState

final class RuntimeProviderMigrationStateTests: XCTestCase {
    func testCommitAtomicallyAdvancesBindingAndTransfersUUIDOwnership() throws {
        try withStore { store in
            let fixture = try seedSourceState(store)
            let result = try store.desiredStates.commitRuntimeProviderMigration(
                projectResourceUUID: fixture.projectUUID,
                projectGeneration: 1,
                expectedSourceProviderID: .appleContainerCLI,
                expectedSourceProviderGeneration: 1,
                targetProviderID: .appleContainerization,
                targetProviderGeneration: 2,
                targetFencingToken: fixture.targetFence,
                resources: [fixture.resource],
                timestamp: "2026-07-19T12:00:00Z"
            )

            XCTAssertEqual(result, .committed(projectID: "project-demo"))
            let project = try store.desiredStates.loadProject(id: "project-demo")
            XCTAssertEqual(project.mutationProvider, RuntimeProviderID.appleContainerization.rawValue)
            XCTAssertEqual(project.providerGeneration, 2)
            XCTAssertEqual(
                try store.desiredStates.loadDesiredServices(projectID: "project-demo")
                    .map(\.mutationProvider),
                [RuntimeProviderID.appleContainerization.rawValue]
            )
            let ownership = try store.ownership.loadAll()
            XCTAssertEqual(ownership.count, 1)
            XCTAssertNil(ownership.first {
                RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) == .appleContainerCLI
            })
            let target = try XCTUnwrap(ownership.first {
                $0.runtimeAdapter == RuntimeProviderID.appleContainerization.rawValue
            })
            XCTAssertEqual(target.resourceUUID, fixture.resource.resourceUUID)
            XCTAssertEqual(target.projectResourceUUID, fixture.projectUUID)
            XCTAssertEqual(target.providerGeneration, 2)
            XCTAssertEqual(target.fencingToken, fixture.targetFence)

            let repeated = try store.desiredStates.commitRuntimeProviderMigration(
                projectResourceUUID: fixture.projectUUID,
                projectGeneration: 1,
                expectedSourceProviderID: .appleContainerCLI,
                expectedSourceProviderGeneration: 1,
                targetProviderID: .appleContainerization,
                targetProviderGeneration: 2,
                targetFencingToken: fixture.targetFence,
                resources: [fixture.resource],
                timestamp: "2026-07-19T12:00:01Z"
            )
            XCTAssertEqual(repeated, .alreadyCommitted(projectID: "project-demo"))
        }
    }

    func testCommitRefusesStaleSourceAndTargetCollisionWithoutPartialState() throws {
        try withStore { store in
            let fixture = try seedSourceState(store)
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "target-collision",
                    resourceIdentifier: fixture.resource.resourceIdentifier,
                    resourceType: "container",
                    projectID: "project-demo",
                    serviceName: "api",
                    runtimeAdapter: "AppleContainerizationAdapter",
                    createdAt: "2026-07-19T11:00:00Z",
                    observedAt: "2026-07-19T11:00:00Z",
                    cleanupEligible: false,
                    metadataJSONRedacted: "{}",
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                    resourceUUID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                    resourceGeneration: 1,
                    projectResourceUUID: fixture.projectUUID,
                    projectGeneration: 1,
                    providerGeneration: 2,
                    fencingToken: fixture.targetFence
                )
            )

            XCTAssertThrowsError(
                try store.desiredStates.commitRuntimeProviderMigration(
                    projectResourceUUID: fixture.projectUUID,
                    projectGeneration: 1,
                    expectedSourceProviderID: .appleContainerCLI,
                    expectedSourceProviderGeneration: 1,
                    targetProviderID: .appleContainerization,
                    targetProviderGeneration: 2,
                    targetFencingToken: fixture.targetFence,
                    resources: [fixture.resource],
                    timestamp: "2026-07-19T12:00:00Z"
                )
            )
            let project = try store.desiredStates.loadProject(id: "project-demo")
            XCTAssertEqual(RuntimeProviderBinding.stableID(for: project.mutationProvider ?? ""), .appleContainerCLI)
            XCTAssertEqual(project.providerGeneration, 1)
        }
    }

    private struct Fixture {
        let projectUUID: String
        let targetFence: String
        let resource: RuntimeProviderMigrationStateResource
    }

    private func seedSourceState(_ store: SQLiteStateStore) throws -> Fixture {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: demo
            services:
              api:
                image: example.local/api:1
            """
        )
        try store.desiredStates.saveManifestSnapshot(
            projectID: "project-demo",
            manifestPath: "hostwright.yaml",
            manifestHash: "manifest-hash",
            desiredGeneration: 1,
            manifest: manifest,
            timestamp: "2026-07-19T10:00:00Z",
            mutationProvider: "AppleContainerApplyAdapter"
        )
        let project = try store.desiredStates.loadProject(id: "project-demo")
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
        let resourceUUID = "22222222-2222-4222-8222-222222222222"
        let sourceFence = "33333333-3333-4333-8333-333333333333"
        try store.ownership.upsert(
            OwnershipRecord(
                id: "source-ownership",
                resourceIdentifier: identity.managedResourceIdentifier,
                resourceType: "container",
                projectID: "project-demo",
                serviceName: "api",
                runtimeAdapter: "AppleContainerApplyAdapter",
                createdAt: "2026-07-19T10:00:00Z",
                observedAt: "2026-07-19T10:00:00Z",
                cleanupEligible: true,
                metadataJSONRedacted: "{}",
                identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                resourceUUID: resourceUUID,
                resourceGeneration: 1,
                projectResourceUUID: project.resourceUUID,
                projectGeneration: 1,
                providerGeneration: 1,
                fencingToken: sourceFence
            )
        )
        return Fixture(
            projectUUID: project.resourceUUID,
            targetFence: "44444444-4444-4444-8444-444444444444",
            resource: RuntimeProviderMigrationStateResource(
                resourceIdentifier: identity.managedResourceIdentifier,
                serviceName: "api",
                identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                resourceUUID: resourceUUID,
                resourceGeneration: 1
            )
        )
    }

    private func withStore(_ body: (SQLiteStateStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-provider-migration-state-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try body(store)
    }
}
