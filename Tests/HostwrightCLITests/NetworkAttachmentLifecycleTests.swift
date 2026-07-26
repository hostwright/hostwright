import Foundation
import HostwrightCore
@testable import HostwrightCLI
import HostwrightRuntime
@testable import HostwrightState
import XCTest

final class NetworkAttachmentLifecycleTests: XCTestCase {
    private let projectID = "project-network-attachment"
    private let projectUUID =
        "10000000-0000-4000-8000-000000000001"
    private let capabilitySHA256 =
        String(repeating: "7", count: 64)
    private let timestamp = "2026-07-26T12:00:00Z"

    func testCreateIntentPrecedesExactObservationAndAmbiguityQuarantines()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let network = try availableNetwork(
                name: "backend",
                operation: "network-backend",
                store: store
            )
            let group = try operationGroup(
                "attach-api",
                store: store
            )
            let context = mutationContext(
                service: "api",
                resourceUUID:
                    "20000000-0000-4000-8000-000000000001",
                group: group
            )
            let descriptor = try NetworkAttachmentCreateDescriptor(
                network: network,
                containerRuntimeIdentifier:
                    runtimeIdentifier(service: "api"),
                containerContext: context,
                aliases: ["api"]
            )
            let authority = authority(group)

            let intent = try NetworkAttachmentLifecycle
                .persistCreateIntent(
                    descriptor,
                    authority: authority,
                    timestamp: timestamp,
                    repository: store.networks
                )

            XCTAssertEqual(intent.lifecycleState, .attaching)
            XCTAssertEqual(intent.finalizerState, .pending)
            XCTAssertNil(intent.observedSHA256)
            XCTAssertEqual(
                intent.id,
                NetworkAttachmentLifecycle.attachmentUUID(
                    networkUUID: network.id,
                    resourceUUID: context.resourceUUID
                )
            )
            XCTAssertEqual(
                try store.networks.loadAttachment(id: intent.id),
                intent
            )
            XCTAssertEqual(
                try NetworkAttachmentLifecycle.persistCreateIntent(
                    descriptor,
                    authority: authority,
                    timestamp: timestamp,
                    repository: store.networks
                ),
                intent
            )

            let exactInventory = try inventory(
                networks: [network],
                descriptors: [descriptor]
            )
            let resolution = try NetworkAttachmentLifecycle
                .resolveCreateObservation(
                    record: intent,
                    descriptor: descriptor,
                    inventory: exactInventory,
                    trigger: .partialEffect,
                    authority: authority,
                    timestamp: "2026-07-26T12:01:00Z",
                    repository: store.networks
                )
            guard case .attached(let attached) = resolution else {
                return XCTFail(
                    "Exact UUID ownership must commit the attachment."
                )
            }
            XCTAssertEqual(attached.lifecycleState, .attached)
            XCTAssertEqual(attached.finalizerState, .active)
            XCTAssertNotNil(attached.observedSHA256)

            let conflicting = try inventory(
                networks: [network],
                descriptors: [descriptor],
                containerFence:
                    "ffffffff-ffff-4fff-8fff-ffffffffffff"
            )
            let conflictResolution = try NetworkAttachmentLifecycle
                .resolveCreateObservation(
                    record: attached,
                    descriptor: descriptor,
                    inventory: conflicting,
                    trigger: .timedOut,
                    authority: authority,
                    timestamp: "2026-07-26T12:02:00Z",
                    repository: store.networks
                )
            guard case .quarantined(let quarantined) =
                conflictResolution else {
                return XCTFail(
                    "Conflicting structured ownership must quarantine."
                )
            }
            XCTAssertEqual(quarantined.lifecycleState, .faulted)
            XCTAssertEqual(
                quarantined.finalizerState,
                .quarantined
            )
        }
    }

    func testCancellationClassifiesAbsentExactConflictAndIndeterminate()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let network = try availableNetwork(
                name: "backend",
                operation: "network-backend",
                store: store
            )
            let group = try operationGroup(
                "attach-worker",
                store: store
            )
            let context = mutationContext(
                service: "worker",
                resourceUUID:
                    "20000000-0000-4000-8000-000000000002",
                group: group
            )
            let descriptor = try NetworkAttachmentCreateDescriptor(
                network: network,
                containerRuntimeIdentifier:
                    runtimeIdentifier(service: "worker"),
                containerContext: context
            )
            let intent = try NetworkAttachmentLifecycle
                .persistCreateIntent(
                    descriptor,
                    authority: authority(group),
                    timestamp: timestamp,
                    repository: store.networks
                )

            XCTAssertEqual(
                NetworkAttachmentLifecycle.classify(
                    record: intent,
                    descriptor: descriptor,
                    inventory: nil
                ),
                .indeterminate
            )
            XCTAssertEqual(
                NetworkAttachmentLifecycle.classify(
                    record: intent,
                    descriptor: descriptor,
                    inventory: try inventory(
                        networks: [network],
                        descriptors: []
                    )
                ),
                .absent
            )
            guard case .exactOwned =
                NetworkAttachmentLifecycle.classify(
                    record: intent,
                    descriptor: descriptor,
                    inventory: try inventory(
                        networks: [network],
                        descriptors: [descriptor]
                    )
                ) else {
                return XCTFail(
                    "Exact structured attachment was not recognized."
                )
            }
            guard case .conflictingOwner =
                NetworkAttachmentLifecycle.classify(
                    record: intent,
                    descriptor: descriptor,
                    inventory: try inventory(
                        networks: [network],
                        descriptors: [descriptor],
                        containerFence:
                            "ffffffff-ffff-4fff-8fff-ffffffffffff"
                    )
                ) else {
                return XCTFail(
                    "Conflicting UUID ownership was not rejected."
                )
            }

            let resolution = try NetworkAttachmentLifecycle
                .resolveCreateObservation(
                    record: intent,
                    descriptor: descriptor,
                    inventory: try inventory(
                        networks: [network],
                        descriptors: []
                    ),
                    trigger: .cancelled,
                    authority: authority(group),
                    timestamp: "2026-07-26T12:03:00Z",
                    repository: store.networks
                )
            XCTAssertEqual(resolution, .absent)
            XCTAssertEqual(
                try store.networks.loadAttachment(id: intent.id),
                intent
            )
        }
    }

    func testReleaseUsesRepositoryReverseOrderAndRequiresAbsence()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let alpha = try availableNetwork(
                name: "alpha",
                operation: "network-alpha",
                store: store
            )
            let zeta = try availableNetwork(
                name: "zeta",
                operation: "network-zeta",
                store: store
            )
            let attachGroup = try operationGroup(
                "attach-both",
                store: store
            )
            let descriptors = try [
                descriptor(
                    network: alpha,
                    service: "api",
                    resourceUUID:
                        "20000000-0000-4000-8000-000000000011",
                    group: attachGroup
                ),
                descriptor(
                    network: zeta,
                    service: "worker",
                    resourceUUID:
                        "20000000-0000-4000-8000-000000000012",
                    group: attachGroup
                ),
            ]
            let exactInventory = try inventory(
                networks: [alpha, zeta],
                descriptors: descriptors
            )
            for descriptor in descriptors {
                let intent = try NetworkAttachmentLifecycle
                    .persistCreateIntent(
                        descriptor,
                        authority: authority(attachGroup),
                        timestamp: timestamp,
                        repository: store.networks
                    )
                guard case .attached =
                    try NetworkAttachmentLifecycle
                        .resolveCreateObservation(
                            record: intent,
                            descriptor: descriptor,
                            inventory: exactInventory,
                            trigger: .partialEffect,
                            authority: authority(attachGroup),
                            timestamp:
                                "2026-07-26T12:01:00Z",
                            repository: store.networks
                        ) else {
                    return XCTFail(
                        "Attachment setup did not converge."
                    )
                }
            }
            try finish(attachGroup.id, store: store)

            let ordered = try NetworkAttachmentLifecycle
                .reverseReleaseOrder(
                    projectUUID: projectUUID,
                    providerID: .appleContainerCLI,
                    providerGeneration: 1,
                    repository: store.networks
                )
            XCTAssertEqual(
                ordered.map(\.networkUUID),
                [alpha.id, zeta.id].sorted(by: >)
            )

            let releaseGroup = try operationGroup(
                "release-both",
                store: store
            )
            let releaseAuthority = authority(releaseGroup)
            let runtimeByResource = Dictionary(
                uniqueKeysWithValues: descriptors.map {
                    (
                        $0.containerContext.resourceUUID,
                        $0.containerRuntimeIdentifier
                    )
                }
            )
            XCTAssertThrowsError(
                try NetworkAttachmentLifecycle
                    .releaseAfterVerifiedAbsence(
                        record: ordered[0],
                        containerRuntimeIdentifier:
                            runtimeByResource[
                                ordered[0].resourceUUID
                            ]!,
                        inventory: exactInventory,
                        authority: releaseAuthority,
                        timestamp:
                            "2026-07-26T12:04:00Z",
                        repository: store.networks
                    )
            )

            let absentInventory = try inventory(
                networks: [alpha, zeta],
                descriptors: []
            )
            for record in ordered {
                try NetworkAttachmentLifecycle
                    .releaseAfterVerifiedAbsence(
                        record: record,
                        containerRuntimeIdentifier:
                            runtimeByResource[
                                record.resourceUUID
                            ]!,
                        inventory: absentInventory,
                        authority: releaseAuthority,
                        timestamp:
                            "2026-07-26T12:05:00Z",
                        repository: store.networks
                    )
            }
            XCTAssertTrue(
                try store.networks.listAttachments().isEmpty
            )
        }
    }

    func testReleaseIntentUsesNewExactAuthorityAndIsIdempotent()
        throws
    {
        try assertReleaseIntentTransition(
            startsAttached: false,
            suffix: "attaching"
        )
        try assertReleaseIntentTransition(
            startsAttached: true,
            suffix: "attached"
        )
    }

    private func assertReleaseIntentTransition(
        startsAttached: Bool,
        suffix: String
    ) throws {
        try withStore { store in
            try seedProject(store)
            let network = try availableNetwork(
                name: "backend",
                operation: "network-\(suffix)",
                store: store
            )
            let attachGroup = try operationGroup(
                "attach-\(suffix)",
                store: store
            )
            let descriptor = try descriptor(
                network: network,
                service: "api",
                resourceUUID:
                    "20000000-0000-4000-8000-000000000021",
                group: attachGroup
            )
            let intent = try NetworkAttachmentLifecycle
                .persistCreateIntent(
                    descriptor,
                    authority: authority(attachGroup),
                    timestamp: timestamp,
                    repository: store.networks
                )
            let source: NetworkStateAttachmentRecord
            if startsAttached {
                let exactInventory = try inventory(
                    networks: [network],
                    descriptors: [descriptor]
                )
                guard case .attached(let attached) =
                    try NetworkAttachmentLifecycle
                        .resolveCreateObservation(
                            record: intent,
                            descriptor: descriptor,
                            inventory: exactInventory,
                            trigger: .partialEffect,
                            authority: authority(attachGroup),
                            timestamp:
                                "2026-07-26T12:01:00Z",
                            repository: store.networks
                        ) else {
                    return XCTFail(
                        "Attachment setup did not converge."
                    )
                }
                source = attached
            } else {
                source = intent
            }
            try finish(attachGroup.id, store: store)

            let releaseGroup = try operationGroup(
                "release-\(suffix)",
                store: store
            )
            let exactAuthority = authority(releaseGroup)
            let staleAuthority = NetworkStateMutationAuthority(
                providerID: exactAuthority.providerID,
                providerGeneration:
                    exactAuthority.providerGeneration,
                operationGroupID:
                    exactAuthority.operationGroupID,
                fencingToken: attachGroup.fencingToken,
                plannedCapabilitySHA256:
                    capabilitySHA256,
                currentCapabilitySHA256:
                    capabilitySHA256
            )
            XCTAssertThrowsError(
                try NetworkAttachmentLifecycle
                    .persistReleaseIntent(
                        record: source,
                        authority: staleAuthority,
                        timestamp:
                            "2026-07-26T12:02:00Z",
                        repository: store.networks
                    )
            )
            XCTAssertEqual(
                try store.networks.loadAttachment(
                    id: source.id
                ),
                source
            )

            let detaching = try NetworkAttachmentLifecycle
                .persistReleaseIntent(
                    record: source,
                    authority: exactAuthority,
                    timestamp: "2026-07-26T12:03:00Z",
                    repository: store.networks
                )
            XCTAssertEqual(
                detaching.generation,
                source.generation + 1
            )
            XCTAssertEqual(detaching.lifecycleState, .detaching)
            XCTAssertEqual(
                detaching.finalizerState,
                .releasing
            )
            XCTAssertEqual(
                detaching.operationGroupID,
                releaseGroup.id
            )
            XCTAssertEqual(
                detaching.fencingToken,
                releaseGroup.fencingToken
            )
            XCTAssertEqual(
                try NetworkAttachmentLifecycle
                    .persistReleaseIntent(
                        record: detaching,
                        authority: exactAuthority,
                        timestamp:
                            "2026-07-26T12:04:00Z",
                        repository: store.networks
                    ),
                detaching
            )

            let conflictingAuthority =
                NetworkStateMutationAuthority(
                    providerID:
                        RuntimeProviderID
                            .appleContainerization.rawValue,
                    providerGeneration: 1,
                    operationGroupID: releaseGroup.id,
                    fencingToken:
                        releaseGroup.fencingToken,
                    plannedCapabilitySHA256:
                        capabilitySHA256,
                    currentCapabilitySHA256:
                        capabilitySHA256
                )
            XCTAssertThrowsError(
                try NetworkAttachmentLifecycle
                    .persistReleaseIntent(
                        record: detaching,
                        authority: conflictingAuthority,
                        timestamp:
                            "2026-07-26T12:05:00Z",
                        repository: store.networks
                    )
            )
        }
    }

    private func descriptor(
        network: NetworkStateResourceRecord,
        service: String,
        resourceUUID: String,
        group: OperationGroupRecord
    ) throws -> NetworkAttachmentCreateDescriptor {
        try NetworkAttachmentCreateDescriptor(
            network: network,
            containerRuntimeIdentifier:
                runtimeIdentifier(service: service),
            containerContext: mutationContext(
                service: service,
                resourceUUID: resourceUUID,
                group: group
            )
        )
    }

    private func availableNetwork(
        name: String,
        operation: String,
        store: SQLiteStateStore
    ) throws -> NetworkStateResourceRecord {
        let identity = try RuntimeNetworkIdentity(
            logicalName: name,
            projectUUID: projectUUID
        )
        let group = try operationGroup(
            operation,
            store: store
        )
        let creating = NetworkStateResourceRecord(
            id: identity.resourceUUID,
            projectUUID: projectUUID,
            name: name,
            runtimeName: identity.runtimeIdentifier,
            generation: 1,
            providerID:
                RuntimeProviderID.appleContainerCLI.rawValue,
            providerGeneration: 1,
            fencingToken: group.fencingToken,
            driver: .nat,
            requestedIPv4: .auto,
            requestedIPv6: .auto,
            observedIPv4: [],
            observedIPv6: [],
            desiredSHA256: digest("a"),
            observedSHA256: nil,
            lifecycleState: .creating,
            finalizerState: .pending,
            operationGroupID: group.id,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        _ = try store.networks.saveNetwork(
            creating,
            authority: authority(group)
        )
        let available = NetworkStateResourceRecord(
            id: creating.id,
            projectUUID: creating.projectUUID,
            name: creating.name,
            runtimeName: creating.runtimeName,
            generation: 2,
            providerID: creating.providerID,
            providerGeneration: creating.providerGeneration,
            fencingToken: creating.fencingToken,
            driver: creating.driver,
            requestedIPv4: creating.requestedIPv4,
            requestedIPv6: creating.requestedIPv6,
            observedIPv4: ["10.44.0.2"],
            observedIPv6: [],
            desiredSHA256: creating.desiredSHA256,
            observedSHA256: digest("b"),
            lifecycleState: .available,
            finalizerState: .active,
            operationGroupID: group.id,
            createdAt: timestamp,
            updatedAt: "2026-07-26T12:00:30Z"
        )
        _ = try store.networks.saveNetwork(
            available,
            replacing: version(creating),
            authority: authority(group)
        )
        try finish(group.id, store: store)
        return available
    }

    private func inventory(
        networks: [NetworkStateResourceRecord],
        descriptors: [NetworkAttachmentCreateDescriptor],
        containerFence: String? = nil
    ) throws -> RuntimeInventory {
        try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS 26.0",
                architecture: "arm64",
                runtimeVersion: "1.1.0",
                services: []
            ),
            containers: descriptors.map { descriptor in
                let context =
                    descriptor.containerContext
                let ownership =
                    RuntimeInventoryOwnershipEvidence(
                        resourceUUID: context.resourceUUID,
                        projectUUID:
                            context.projectResourceUUID,
                        resourceGeneration:
                            context.resourceGeneration,
                        projectGeneration:
                            context.projectGeneration,
                        providerID: context.providerID,
                        providerGeneration:
                            context.providerGeneration,
                        fencingToken:
                            containerFence ??
                            context.fencingToken
                    )
                return RuntimeInventoryContainer(
                    runtimeID:
                        descriptor.containerRuntimeIdentifier,
                    name:
                        descriptor.containerRuntimeIdentifier,
                    imageReference:
                        "example.invalid/local@sha256:" +
                        digest("c"),
                    lifecycle: .running,
                    health: RuntimeInventoryHealth(
                        availability: .notConfigured
                    ),
                    labels: [
                        RuntimeInventoryLabel(
                            key:
                                RuntimeManagedResourceIdentity
                                    .managedLabel,
                            value: "true"
                        ),
                    ],
                    ownership: ownership,
                    initConfiguration:
                        RuntimeInventoryInitConfiguration(
                            executable: "/bin/true",
                            arguments: [],
                            environment: []
                        ),
                    ports: [],
                    mounts: [],
                    networks: [
                        RuntimeInventoryNetworkAttachment(
                            networkID:
                                descriptor.network.runtimeName,
                            interfaceName: "eth0",
                            addresses: ["10.44.0.10"],
                            gateway: "10.44.0.1",
                            macAddress:
                                "02:00:00:00:00:10"
                        ),
                    ],
                    services: []
                )
            },
            images: [],
            networks: networks.map { network in
                RuntimeInventoryNetwork(
                    runtimeID: network.runtimeName,
                    name: network.runtimeName,
                    kind: network.driver.rawValue,
                    addresses:
                        network.observedIPv4 +
                        network.observedIPv6,
                    labels: [
                        RuntimeInventoryLabel(
                            key:
                                RuntimeManagedResourceIdentity
                                    .managedLabel,
                            value: "true"
                        ),
                    ],
                    ownership:
                        RuntimeInventoryOwnershipEvidence(
                            resourceUUID: network.id,
                            projectUUID: network.projectUUID,
                            resourceGeneration:
                                Int(network.generation),
                            projectGeneration: 1,
                            providerID: .appleContainerCLI,
                            providerGeneration: 1,
                            fencingToken:
                                network.fencingToken
                        )
                )
            },
            volumes: []
        )
    }

    private func runtimeIdentifier(service: String) -> String {
        RuntimeManagedResourceIdentity.resourceIdentifier(
            for: RuntimeServiceIdentity(
                projectName: "web",
                serviceName: service
            )
        )
    }

    private func mutationContext(
        service: String,
        resourceUUID: String,
        group: OperationGroupRecord
    ) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: capabilitySHA256,
            operationID: group.operationID,
            resourceUUID: resourceUUID,
            resourceGeneration: 1,
            projectResourceUUID: projectUUID,
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: group.fencingToken
        )
    }

    private func authority(
        _ group: OperationGroupRecord
    ) -> NetworkStateMutationAuthority {
        NetworkStateMutationAuthority(
            providerID:
                RuntimeProviderID.appleContainerCLI.rawValue,
            providerGeneration: 1,
            operationGroupID: group.id,
            fencingToken: group.fencingToken,
            plannedCapabilitySHA256: capabilitySHA256,
            currentCapabilitySHA256: capabilitySHA256
        )
    }

    private func operationGroup(
        _ name: String,
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        let id = HostwrightResourceUUID.legacy(
            kind: "network-attachment-test-operation",
            identifier: name
        )
        let group = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "network-attachment",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: name,
            status: .active,
            groupIdempotencyKey: "attachment:\(name)",
            planHash: digest("9"),
            checkpoint: "intent-persisted",
            lockOwner: "network-attachment-test",
            lockExpiresAt: "2027-07-26T12:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: timestamp,
            updatedAt: timestamp,
            metadataJSONRedacted: "{}",
            fencingToken: HostwrightResourceUUID.legacy(
                kind: "network-attachment-test-fence",
                identifier: name
            ),
            intentJSONRedacted:
                "{\"capabilitySHA256\":\"\(capabilitySHA256)\"}"
        )
        let result = try store.operationGroups.acquire(group)
        return try XCTUnwrap(result.acquired)
    }

    private func finish(
        _ id: String,
        store: SQLiteStateStore
    ) throws {
        let group = try XCTUnwrap(
            try store.operationGroups.load(id: id)
        )
        try store.operationGroups.finish(
            groupID: id,
            status: .succeeded,
            checkpoint: "verified",
            manualRecoveryHintRedacted: "",
            updatedAt: "2026-07-26T12:30:00Z",
            metadataJSONRedacted: "{}"
        )
        XCTAssertEqual(group.status, .active)
    }

    private func version(
        _ record: NetworkStateResourceRecord
    ) -> NetworkStateExpectedVersion {
        NetworkStateExpectedVersion(
            generation: record.generation,
            fencingToken: record.fencingToken
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func seedProject(_ store: SQLiteStateStore) throws {
        try store.withConnection { connection in
            try connection.run(
                """
                INSERT INTO projects (
                    id, name, manifest_path, manifest_hash,
                    created_at, updated_at, resource_uuid,
                    manifest_version, mutation_provider,
                    provider_generation
                ) VALUES (?, ?, NULL, ?, ?, ?, ?, 2, ?, 1)
                """,
                bindings: [
                    .text(projectID),
                    .text("web"),
                    .text(digest("1")),
                    .text(timestamp),
                    .text(timestamp),
                    .text(projectUUID),
                    .text(
                        RuntimeProviderID
                            .appleContainerCLI.rawValue
                    ),
                ]
            )
        }
    }

    private func withStore(
        _ body: (SQLiteStateStore) throws -> Void
    ) throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "hostwright-network-attachment-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(
            path: directory
                .appendingPathComponent("state.sqlite")
                .path
        )
        try store.migrate()
        try body(store)
    }
}
