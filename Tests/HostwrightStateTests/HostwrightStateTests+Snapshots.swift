import Foundation
import Synchronization
import XCTest
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightNetworking
@testable import HostwrightRuntime
@testable import HostwrightState

extension HostwrightStateTests {
    func testSchedulerProjectRegistrationDoesNotPublishDesiredServices() throws {
        try withTemporaryStore { store, _ in
            try store.migrate()
            let project = StateProjectRecord(
                id: projectID, name: "api-local", manifestPath: "/tmp/hostwright.yaml",
                manifestHash: String(repeating: "a", count: 64),
                createdAt: timestamp, updatedAt: timestamp,
                manifestVersion: HostwrightContractVersions.manifest,
                mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue,
                providerGeneration: 1
            )
            XCTAssertTrue(try store.desiredStates.registerProjectForAdmission(project))
            XCTAssertFalse(try store.desiredStates.registerProjectForAdmission(project))
            XCTAssertEqual(try store.desiredStates.loadProject(id: projectID), project)
            XCTAssertTrue(try store.desiredStates.loadDesiredServices(projectID: projectID).isEmpty)
            XCTAssertTrue(try store.ownership.loadAll().isEmpty)
        }
    }

    func testSchedulerProjectRegistrationPreservesPublishedDesiredRevision() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            let before = try store.desiredStates.loadProject(id: projectID)
            let services = try store.desiredStates.loadDesiredServices(projectID: projectID)
            let candidate = StateProjectRecord(
                id: projectID, name: "api-local", manifestPath: "/tmp/new-hostwright.yaml",
                manifestHash: String(repeating: "b", count: 64),
                createdAt: timestamp, updatedAt: timestamp,
                resourceUUID: before.resourceUUID,
                manifestVersion: HostwrightContractVersions.manifest,
                mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue,
                providerGeneration: 2
            )
            XCTAssertFalse(try store.desiredStates.registerProjectForAdmission(candidate))
            XCTAssertEqual(try store.desiredStates.loadProject(id: projectID), before)
            XCTAssertEqual(try store.desiredStates.loadDesiredServices(projectID: projectID), services)
        }
    }

    func testSchedulerProjectRegistrationRejectsConflictingIdentityAndProvider() throws {
        try withTemporaryStore { store, _ in
            try store.migrate()
            let resourceUUID = HostwrightResourceUUID.generate()
            func candidate(uuid: String, provider: String) -> StateProjectRecord {
                StateProjectRecord(
                    id: projectID, name: "api-local", manifestPath: nil,
                    manifestHash: String(repeating: "a", count: 64),
                    createdAt: timestamp, updatedAt: timestamp, resourceUUID: uuid,
                    manifestVersion: HostwrightContractVersions.manifest,
                    mutationProvider: provider, providerGeneration: 1
                )
            }
            let project = candidate(uuid: resourceUUID, provider: "apple-container-cli")
            try store.desiredStates.registerProjectForAdmission(project)
            for rejected in [
                candidate(uuid: HostwrightResourceUUID.generate(), provider: "apple-container-cli"),
                candidate(uuid: resourceUUID, provider: "apple-containerization"),
                candidate(uuid: resourceUUID, provider: "unsupported-provider")
            ] {
                XCTAssertThrowsError(try store.desiredStates.registerProjectForAdmission(rejected))
            }
            XCTAssertEqual(try store.desiredStates.loadProject(id: projectID), project)
            XCTAssertTrue(try store.desiredStates.loadDesiredServices(projectID: projectID).isEmpty)
        }
    }

    func testManifestSnapshotPersistsExplicitProjectResourceUUID()
        throws {
        try withTemporaryStore { store, _ in
            try store.migrate()
            let resourceUUID =
                "11111111-1111-4111-8111-111111111117"
            try store.desiredStates.saveManifestSnapshot(
                projectID: "qualification:\(resourceUUID)",
                manifestPath: nil,
                manifestHash: String(repeating: "a", count: 64),
                desiredGeneration: 1,
                manifest: HostwrightManifest(
                    version: HostwrightManifest.currentVersion,
                    project: "gate13-qualification",
                    services: []
                ),
                timestamp: timestamp,
                mutationProvider: "apple-container-cli",
                projectResourceUUID: resourceUUID
            )

            let project = try store.desiredStates.loadProject(
                id: "qualification:\(resourceUUID)"
            )
            XCTAssertEqual(project.resourceUUID, resourceUUID)
            XCTAssertEqual(
                project.mutationProvider,
                "apple-container-cli"
            )
            XCTAssertEqual(project.providerGeneration, 1)
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
            XCTAssertEqual(
                desiredServices[0].portsJSON,
                #"[{"allocation":"fixed","bindAddress":"127.0.0.1","exposure":{"accessMode":"none","allowedCIDRs":[],"interfaces":[],"networkClasses":[],"scope":"localhost"},"host":"8080","protocol":"tcp","target":"8080"}]"#
            )
            XCTAssertTrue(desiredServices[0].environmentJSONRedacted.contains("[REDACTED]"))
            XCTAssertFalse(desiredServices[0].environmentJSONRedacted.contains(fakeSecret))
            XCTAssertFalse(desiredServices[0].environmentJSONRedacted.contains("hostwright.api"))
            XCTAssertFalse(desiredServices[0].environmentJSONRedacted.contains("api-token"))
        }
    }

    func testDeclaredPortExposurePersistsInDesiredState() throws {
        try withTemporaryStore { store, _ in
            try store.migrate()
            let exposure = HostwrightPortExposurePolicy(
                scope: .lan,
                interfaces: ["en0"],
                networkClasses: [.privateLAN],
                allowedCIDRs: ["192.168.1.0/24"],
                authentication: .tls
            )
            let manifest = HostwrightManifest(
                project: "api-local",
                services: [
                    HostwrightService(
                        name: "api",
                        image: "local/api:latest",
                        publishedPorts: [
                            HostwrightPublishedPort(
                                host: HostwrightPortSpan(start: 8_443),
                                target: HostwrightPortSpan(start: 9_443),
                                protocolName: .tcp,
                                bindAddress: "192.168.1.10",
                                exposure: exposure
                            )
                        ]
                    )
                ]
            )
            try store.desiredStates.saveManifestSnapshot(
                projectID: projectID,
                manifestPath: "/tmp/hostwright.yaml",
                manifestHash: "exposure-manifest-hash",
                desiredGeneration: 1,
                manifest: manifest,
                timestamp: timestamp
            )

            let record = try XCTUnwrap(
                try store.desiredStates
                    .loadDesiredServices(projectID: projectID)
                    .first
            )
            let data = try XCTUnwrap(record.portsJSON.data(using: .utf8))
            let ports = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data)
                    as? [[String: Any]]
            )
            let persisted = try XCTUnwrap(
                ports.first?["exposure"] as? [String: Any]
            )

            XCTAssertEqual(persisted["scope"] as? String, "lan")
            XCTAssertEqual(persisted["accessMode"] as? String, "tls")
            XCTAssertEqual(persisted["interfaces"] as? [String], ["en0"])
            XCTAssertEqual(
                persisted["networkClasses"] as? [String],
                ["private"]
            )
            XCTAssertEqual(
                persisted["allowedCIDRs"] as? [String],
                ["192.168.1.0/24"]
            )
        }
    }

    func testPublishedUnixSocketsPersistInDesiredAndObservedState()
        throws {
        try withTemporaryStore { store, _ in
            try store.migrate()
            let socketManifest = HostwrightManifest(
                project: "api-local",
                services: [
                    HostwrightService(
                        name: "api",
                        image: "local/api:latest",
                        publishedSockets: [
                            HostwrightPublishedSocket(
                                hostName: "api.sock",
                                containerPath: "/run/api.sock",
                                mode: .ownerAndGroup
                            )
                        ]
                    )
                ]
            )
            try store.desiredStates.saveManifestSnapshot(
                projectID: projectID,
                manifestPath: "/tmp/hostwright.yaml",
                manifestHash: "socket-manifest-hash",
                desiredGeneration: 1,
                manifest: socketManifest,
                timestamp: timestamp
            )
            let desired = try store.desiredStates
                .loadDesiredServices(projectID: projectID)
            XCTAssertEqual(
                desired.first?.portsJSON,
                #"[{"host":"api.sock","mode":"0660","protocol":"unix","target":"\/run\/api.sock"}]"#
            )

            let identity = RuntimeServiceIdentity(
                projectName: "api-local",
                serviceName: "api"
            )
            try store.observedStates.saveSnapshot(
                snapshotID: snapshotID,
                projectID: projectID,
                observedState: ObservedRuntimeState(
                    projectName: "api-local",
                    services: [
                        ObservedRuntimeService(
                            identity: identity,
                            resourceIdentifier:
                                identity.managedResourceIdentifier,
                            image: "local/api:latest",
                            lifecycleState: .running,
                            healthState: .unknown,
                            publishedSockets: [
                                RuntimeUnixSocketPublication(
                                    hostPath:
                                        "/tmp/hostwright/api.sock",
                                    containerPath: "/run/api.sock",
                                    mode: .ownerAndGroup
                                )
                            ]
                        )
                    ]
                ),
                runtimeAdapter: "apple-container-cli",
                parserVersion:
                    AppleContainerObservationParser.supportedSchema,
                rawOutputHash: "socket-output-hash",
                redactedSummary: "socket observation",
                observedAt: timestamp
            )
            let observed = try store.observedStates
                .loadObservedServices(snapshotID: snapshotID)
            XCTAssertEqual(
                observed.first?.portsJSON,
                #"[{"containerPath":"\/run\/api.sock","hostPath":"\/tmp\/hostwright\/api.sock","mode":"0660","protocol":"unix"}]"#
            )
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
            XCTAssertEqual(
                observedServices[0].id,
                "\(snapshotID):\(observedState.services[0].identity.displayName)"
            )
            XCTAssertEqual(observedServices[0].lifecycleState, .running)
            XCTAssertEqual(observedServices[0].resourceIdentifier, observedState.services[0].resourceIdentifier)
            XCTAssertTrue(observedServices[0].networksJSON.contains("192.168.64.2"))
        }
    }

    func testObservedSnapshotPersistsConcurrentRevisionsWithOneLogicalIdentity() throws {
        try withTemporaryStore { store, _ in
            try store.migrate()
            let identity = RuntimeServiceIdentity(
                projectName: "api-local",
                serviceName: "api"
            )
            let services = [
                "hostwright-api-old",
                "provider://credential=do-not-copy-into-row-id"
            ].map {
                ObservedRuntimeService(
                    identity: identity,
                    resourceIdentifier: $0,
                    image: "ghcr.io/example/api:latest",
                    lifecycleState: .running,
                    healthState: .healthy
                )
            }
            try store.observedStates.saveSnapshot(
                snapshotID: "snapshot-revisions",
                projectID: nil,
                observedState: ObservedRuntimeState(
                    projectName: "api-local",
                    services: services
                ),
                runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                parserVersion: "phase04-lifecycle-v1",
                rawOutputHash: nil,
                redactedSummary: "two verified revisions",
                observedAt: timestamp
            )

            let persisted = try store.observedStates.loadObservedServices(
                snapshotID: "snapshot-revisions"
            )
            XCTAssertEqual(persisted.count, 2)
            XCTAssertEqual(
                persisted.map(\.resourceIdentifier).sorted(),
                services.map(\.resourceIdentifier).sorted()
            )
            XCTAssertEqual(Set(persisted.map(\.id)).count, 2)
            for value in persisted {
                XCTAssertFalse(
                    services.map(\.resourceIdentifier).contains {
                        value.id.contains($0)
                    }
                )
            }
        }
    }
}
