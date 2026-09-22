import Foundation
import Synchronization
import XCTest
@testable import HostwrightRuntime
@testable import HostwrightState

extension HostwrightStateTests {
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
            XCTAssertTrue(StateJSON.isObject(ownership[0].metadataJSONRedacted))
        }
    }

    func testOwnershipHintsReturnOnlyCanonicalSupportedContainerRows() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            let identity = RuntimeServiceIdentity(projectName: "api-local", serviceName: "api")
            let records = [
                OwnershipRecord(
                    id: "legacy",
                    resourceIdentifier: identity.legacyManagedResourceIdentifier,
                    resourceType: "container",
                    projectID: projectID,
                    serviceName: "api",
                    runtimeAdapter: "AppleContainerApplyAdapter",
                    createdAt: timestamp,
                    observedAt: timestamp,
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}",
                    identityVersion: 1
                ),
                OwnershipRecord(
                    id: "current",
                    resourceIdentifier: identity.managedResourceIdentifier,
                    resourceType: "container",
                    projectID: projectID,
                    serviceName: "api",
                    runtimeAdapter: "AppleContainerApplyAdapter",
                    createdAt: timestamp,
                    observedAt: timestamp,
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}",
                    identityVersion: 2
                ),
                OwnershipRecord(
                    id: "other-adapter",
                    resourceIdentifier: "hostwright-api-local-other",
                    resourceType: "container",
                    projectID: projectID,
                    serviceName: "other",
                    runtimeAdapter: "other",
                    createdAt: timestamp,
                    observedAt: timestamp,
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}"
                )
            ]
            for record in records {
                try store.ownership.upsert(record)
            }

            let hints = try store.ownership.runtimeHints(projectID: projectID, projectName: "api-local")
            XCTAssertEqual(hints.map(\.resourceIdentifier), [identity.legacyManagedResourceIdentifier, identity.managedResourceIdentifier].sorted())
            XCTAssertEqual(Set(hints.map(\.identityVersion)), Set([1, 2]))
        }
    }

    func testOwnershipHintsPreserveExactPrimaryAndReplicaLifecycleIdentities() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            let primary = RuntimeServiceIdentity(
                projectName: "api-local",
                serviceName: "api"
            )
            let replica = RuntimeServiceIdentity(
                projectName: "api-local",
                serviceName: "api",
                instanceName: "replica-1"
            )
            let mismatchedReplica = RuntimeServiceIdentity(
                projectName: "api-local",
                serviceName: "api",
                instanceName: "replica-2"
            )
            let records = [
                OwnershipRecord(
                    id: "primary",
                    resourceIdentifier: primary.managedResourceIdentifier,
                    resourceType: "container",
                    projectID: projectID,
                    serviceName: "api",
                    runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                    createdAt: timestamp,
                    observedAt: timestamp,
                    cleanupEligible: true,
                    metadataJSONRedacted: lifecycleOwnershipMetadata(for: primary),
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion
                ),
                OwnershipRecord(
                    id: "replica",
                    resourceIdentifier: replica.managedResourceIdentifier,
                    resourceType: "container",
                    projectID: projectID,
                    serviceName: "api",
                    runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                    createdAt: timestamp,
                    observedAt: timestamp,
                    cleanupEligible: true,
                    metadataJSONRedacted: lifecycleOwnershipMetadata(for: replica),
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion
                ),
                OwnershipRecord(
                    id: "mismatched-replica",
                    resourceIdentifier: mismatchedReplica.managedResourceIdentifier,
                    resourceType: "container",
                    projectID: projectID,
                    serviceName: "api",
                    runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                    createdAt: timestamp,
                    observedAt: timestamp,
                    cleanupEligible: true,
                    metadataJSONRedacted: lifecycleOwnershipMetadata(for: replica),
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion
                )
            ]
            for record in records {
                try store.ownership.upsert(record)
            }

            let hints = try store.ownership.runtimeHints(
                projectID: projectID,
                projectName: "api-local"
            )

            let identitiesByResource = Dictionary(
                uniqueKeysWithValues: hints.map {
                    ($0.resourceIdentifier, $0.identity)
                }
            )
            XCTAssertEqual(
                identitiesByResource,
                [
                    primary.managedResourceIdentifier: primary,
                    replica.managedResourceIdentifier: replica
                ]
            )
        }
    }
}
