import Foundation
import HostwrightManifest
import HostwrightRuntime
import HostwrightState
import XCTest

final class Gate03RecoveryStateEvidenceTests: XCTestCase {
    func testLegacyAdapterIdentityMigratesToStableProviderWithoutChangingUUIDs() throws {
        try withStore { store in
            let manifest = try ManifestValidator.validated(
                """
                version: 2
                project: sample
                services:
                  api:
                    image: example.local/api:1
                """
            )
            try store.desiredStates.saveManifestSnapshot(
                projectID: "project-sample",
                manifestPath: "hostwright.yaml",
                manifestHash: "manifest-hash",
                desiredGeneration: 1,
                manifest: manifest,
                timestamp: "2026-07-19T12:00:00Z",
                mutationProvider: "AppleContainerApplyAdapter"
            )
            let projectBefore = try store.desiredStates.loadProject(id: "project-sample")
            let desiredBefore = try XCTUnwrap(
                try store.desiredStates.loadDesiredServices(projectID: "project-sample").first
            )
            let identity = RuntimeServiceIdentity(projectName: "sample", serviceName: "api")
            let resourceUUID = "22222222-2222-4222-8222-222222222222"
            let sourceFence = "33333333-3333-4333-8333-333333333333"
            let targetFence = "44444444-4444-4444-8444-444444444444"
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "ownership-api",
                    resourceIdentifier: identity.managedResourceIdentifier,
                    resourceType: "container",
                    projectID: "project-sample",
                    serviceName: "api",
                    runtimeAdapter: "AppleContainerApplyAdapter",
                    createdAt: "2026-07-19T12:00:00Z",
                    observedAt: "2026-07-19T12:00:00Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}",
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                    resourceUUID: resourceUUID,
                    resourceGeneration: 1,
                    projectResourceUUID: projectBefore.resourceUUID,
                    projectGeneration: 1,
                    providerGeneration: 1,
                    fencingToken: sourceFence
                )
            )

            XCTAssertEqual(
                RuntimeProviderRecoveryEvaluator.bindingDecision(
                    for: try XCTUnwrap(projectBefore.mutationProvider)
                ),
                .migrateLegacy(from: "AppleContainerApplyAdapter", to: .appleContainerCLI)
            )
            XCTAssertEqual(
                try store.desiredStates.commitRuntimeProviderMigration(
                    projectResourceUUID: projectBefore.resourceUUID,
                    projectGeneration: 1,
                    expectedSourceProviderID: .appleContainerCLI,
                    expectedSourceProviderGeneration: 1,
                    targetProviderID: .appleContainerization,
                    targetProviderGeneration: 2,
                    targetFencingToken: targetFence,
                    resources: [
                        RuntimeProviderMigrationStateResource(
                            resourceIdentifier: identity.managedResourceIdentifier,
                            serviceName: "api",
                            identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                            resourceUUID: resourceUUID,
                            resourceGeneration: 1
                        )
                    ],
                    timestamp: "2026-07-19T12:01:00Z"
                ),
                .committed(projectID: "project-sample")
            )

            let projectAfter = try store.desiredStates.loadProject(id: "project-sample")
            let desiredAfter = try XCTUnwrap(
                try store.desiredStates.loadDesiredServices(projectID: "project-sample").first
            )
            let ownershipAfter = try XCTUnwrap(try store.ownership.loadAll().first)
            XCTAssertEqual(projectAfter.resourceUUID, projectBefore.resourceUUID)
            XCTAssertEqual(desiredAfter.resourceUUID, desiredBefore.resourceUUID)
            XCTAssertEqual(ownershipAfter.resourceUUID, resourceUUID)
            XCTAssertEqual(ownershipAfter.projectResourceUUID, projectBefore.resourceUUID)
            XCTAssertEqual(projectAfter.mutationProvider, RuntimeProviderID.appleContainerization.rawValue)
            XCTAssertEqual(
                ownershipAfter.runtimeAdapter,
                RuntimeProviderID.appleContainerization.rawValue
            )
            XCTAssertEqual(projectAfter.providerGeneration, 2)
            XCTAssertEqual(ownershipAfter.providerGeneration, 2)
        }
    }

    private func withStore(_ body: (SQLiteStateStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-gate03-recovery-evidence-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try body(store)
    }
}
