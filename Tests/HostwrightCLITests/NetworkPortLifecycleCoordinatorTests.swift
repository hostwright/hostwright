import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightReconciler
@testable import HostwrightRuntime
@testable import HostwrightState

final class NetworkPortLifecycleCoordinatorTests: XCTestCase {
    func testPlanningResolutionIsReadOnlyStableAndProtocolScoped()
        throws
    {
        let fixture = try makeFixture(
            ports: [
                RuntimePortMapping(
                    hostPort: nil,
                    containerPort: 8_081,
                    protocolName: .tcp,
                    allocation: .dynamic
                ),
                RuntimePortMapping(
                    hostPort: nil,
                    containerPort: 5_353,
                    protocolName: .udp,
                    allocation: .dynamic
                ),
                RuntimePortMapping(
                    hostPort: nil,
                    containerPort: 8_080,
                    protocolName: .tcp,
                    allocation: .dynamic
                ),
            ]
        )
        defer { fixture.cleanup() }
        let desired = DesiredRuntimeState(
            projectName: fixture.plan.projectName,
            services: [fixture.service]
        )
        let occupied: Set<NetworkPortEndpoint> = [
            NetworkPortEndpoint(
                bindAddress: "127.0.0.1",
                hostPort: 49_152,
                protocolName: .tcp
            ),
        ]

        let first = try NetworkPortLifecycleCoordinator
            .resolveForPlanning(
                desiredState: desired,
                projectID: fixture.plan.projectID,
                projectResourceUUID:
                    fixture.plan.projectResourceUUID,
                providerID: fixture.plan.providerID,
                providerGeneration:
                    fixture.plan.providerGeneration,
                resourceUUID: { _ in nil },
                store: fixture.store,
                occupiedPorts: occupied,
                isAvailable: {
                    !(
                        $0.protocolName == .tcp &&
                        $0.hostPort == 49_153
                    )
                }
            )
        XCTAssertEqual(
            first.services[0].ports.map(\.hostPort),
            [49_155, 49_152, 49_154]
        )
        XCTAssertTrue(
            first.services[0].ports.allSatisfy {
                $0.allocation == .dynamic
            }
        )
        XCTAssertEqual(
            first.services[0].ports.map(\.bindAddress),
            [
                "127.0.0.1",
                "127.0.0.1",
                "127.0.0.1",
            ]
        )
        XCTAssertTrue(
            try fixture.store.networkPorts.loadProject(
                projectUUID: fixture.plan.projectResourceUUID,
                includeReleased: true
            ).isEmpty
        )

        let second = try NetworkPortLifecycleCoordinator
            .resolveForPlanning(
                desiredState: first,
                projectID: fixture.plan.projectID,
                projectResourceUUID:
                    fixture.plan.projectResourceUUID,
                providerID: fixture.plan.providerID,
                providerGeneration:
                    fixture.plan.providerGeneration,
                resourceUUID: { _ in nil },
                store: fixture.store,
                occupiedPorts: occupied,
                isAvailable: {
                    !(
                        $0.protocolName == .tcp &&
                        $0.hostPort == 49_153
                    )
                }
            )
        XCTAssertEqual(second, first)
    }

    func testIPv4AndIPv6BindingsForSameTargetHaveDistinctReservations()
        throws
    {
        let fixture = try makeFixture(
            ports: [
                RuntimePortMapping(
                    hostPort: 18_080,
                    containerPort: 8_080,
                    protocolName: .tcp,
                    bindAddress: "127.0.0.1"
                ),
                RuntimePortMapping(
                    hostPort: 18_080,
                    containerPort: 8_080,
                    protocolName: .tcp,
                    bindAddress: "::1"
                ),
            ]
        )
        defer { fixture.cleanup() }
        let resolved = try resolvedService(fixture)
        let empty = try inventory(fixture: fixture)

        let reserved = try NetworkPortLifecycleCoordinator.reserve(
            service: resolved,
            node: fixture.node,
            plan: fixture.plan,
            group: fixture.group,
            inventory: empty,
            store: fixture.store
        )
        XCTAssertEqual(reserved.records.count, 2)
        XCTAssertEqual(
            Set(reserved.records.map(\.bindAddress)),
            ["127.0.0.1", "::1"]
        )
        XCTAssertEqual(
            Set(reserved.records.map(\.id)).count,
            2
        )

        let replanned = try NetworkPortLifecycleCoordinator
            .resolveForPlanning(
                desiredState: DesiredRuntimeState(
                    projectName: fixture.plan.projectName,
                    services: [fixture.service]
                ),
                projectID: fixture.plan.projectID,
                projectResourceUUID:
                    fixture.plan.projectResourceUUID,
                providerID: fixture.plan.providerID,
                providerGeneration:
                    fixture.plan.providerGeneration,
                resourceUUID: { _ in
                    fixture.node.resourceUUID
                },
                store: fixture.store
            )
        XCTAssertEqual(replanned.services[0].ports, resolved.ports)

        let observed = try inventory(
            fixture: fixture,
            ports: [
                RuntimeInventoryPort(
                    hostAddress: "127.0.0.1",
                    hostPort: 18_080,
                    containerPort: 8_080,
                    protocolName: .tcp
                ),
                RuntimeInventoryPort(
                    hostAddress: "::1",
                    hostPort: 18_080,
                    containerPort: 8_080,
                    protocolName: .tcp
                ),
            ]
        )
        let active = try NetworkPortLifecycleCoordinator
            .confirmActive(
                node: fixture.node,
                plan: fixture.plan,
                group: fixture.group,
                inventory: observed,
                store: fixture.store
            )
        XCTAssertEqual(
            active.records.map(\.lifecycleState),
            [.active, .active]
        )
    }

    func testFixedConflictAndRuntimeRaceFailBeforeReservation()
        throws
    {
        let fixture = try makeFixture(
            ports: [
                RuntimePortMapping(
                    hostPort: 18_080,
                    containerPort: 8_080,
                    protocolName: .tcp,
                    bindAddress: "127.0.0.1",
                    allocation: .fixed
                ),
            ]
        )
        defer { fixture.cleanup() }
        let desired = DesiredRuntimeState(
            projectName: fixture.plan.projectName,
            services: [fixture.service]
        )
        let occupied = Set([
            NetworkPortEndpoint(
                bindAddress: "0.0.0.0",
                hostPort: 18_080,
                protocolName: .tcp
            ),
        ])

        XCTAssertThrowsError(
            try NetworkPortLifecycleCoordinator
                .resolveForPlanning(
                    desiredState: desired,
                    projectID: fixture.plan.projectID,
                    projectResourceUUID:
                        fixture.plan.projectResourceUUID,
                    providerID: fixture.plan.providerID,
                    providerGeneration:
                        fixture.plan.providerGeneration,
                    resourceUUID: { _ in
                        fixture.node.resourceUUID
                    },
                    store: fixture.store,
                    occupiedPorts: occupied
                )
        )
        XCTAssertTrue(
            try fixture.store.networkPorts.loadProject(
                projectUUID: fixture.plan.projectResourceUUID,
                includeReleased: true
            ).isEmpty
        )

        let unresolvedRace = try inventory(
            fixture: fixture,
            ports: [
                RuntimeInventoryPort(
                    hostAddress: "0.0.0.0",
                    hostPort: 18_080,
                    containerPort: 9_999,
                    protocolName: .tcp
                ),
            ],
            managed: false,
            name: "unmanaged-port-owner"
        )
        XCTAssertThrowsError(
            try NetworkPortLifecycleCoordinator.reserve(
                service: fixture.service,
                node: fixture.node,
                plan: fixture.plan,
                group: fixture.group,
                inventory: unresolvedRace,
                store: fixture.store
            )
        )
        XCTAssertTrue(
            try fixture.store.networkPorts.loadProject(
                projectUUID: fixture.plan.projectResourceUUID,
                includeReleased: true
            ).isEmpty
        )
    }

    func testReserveReusesExactIntentAndActivationRequiresExactObservation()
        throws
    {
        let fixture = try makeFixture(
            ports: [
                RuntimePortMapping(
                    hostPort: nil,
                    containerPort: 8_080,
                    protocolName: .tcp,
                    allocation: .dynamic
                ),
            ]
        )
        defer { fixture.cleanup() }
        let resolved = try resolvedService(fixture)
        let empty = try inventory(fixture: fixture)

        let reserved = try NetworkPortLifecycleCoordinator
            .reserve(
                service: resolved,
                node: fixture.node,
                plan: fixture.plan,
                group: fixture.group,
                inventory: empty,
                store: fixture.store
            )
        XCTAssertEqual(reserved.records.count, 1)
        XCTAssertEqual(
            reserved.records[0].lifecycleState,
            .reserved
        )
        XCTAssertEqual(reserved.records[0].hostPort, 49_152)
        XCTAssertEqual(
            reserved.records[0].operationGroupID,
            fixture.group.id
        )

        let replay = try NetworkPortLifecycleCoordinator
            .reserve(
                service: resolved,
                node: fixture.node,
                plan: fixture.plan,
                group: fixture.group,
                inventory: empty,
                store: fixture.store
            )
        XCTAssertEqual(replay, reserved)
        XCTAssertEqual(
            try fixture.store.networkPorts.loadProject(
                projectUUID: fixture.plan.projectResourceUUID
            ),
            reserved.records
        )

        let unresolved = DesiredRuntimeState(
            projectName: fixture.plan.projectName,
            services: [fixture.service]
        )
        let replanned = try NetworkPortLifecycleCoordinator
            .resolveForPlanning(
                desiredState: unresolved,
                projectID: fixture.plan.projectID,
                projectResourceUUID:
                    fixture.plan.projectResourceUUID,
                providerID: fixture.plan.providerID,
                providerGeneration:
                    fixture.plan.providerGeneration,
                resourceUUID: { _ in
                    fixture.node.resourceUUID
                },
                store: fixture.store,
                occupiedPorts: [
                    NetworkPortEndpoint(
                        bindAddress: "127.0.0.1",
                        hostPort: 49_152,
                        protocolName: .tcp
                    ),
                ]
            )
        XCTAssertEqual(
            replanned.services[0].ports[0].hostPort,
            49_152
        )
        XCTAssertEqual(
            try fixture.store.networkPorts.loadProject(
                projectUUID: fixture.plan.projectResourceUUID
            ),
            reserved.records
        )

        XCTAssertThrowsError(
            try NetworkPortLifecycleCoordinator.confirmActive(
                node: fixture.node,
                plan: fixture.plan,
                group: fixture.group,
                inventory: empty,
                store: fixture.store
            )
        )
        XCTAssertEqual(
            try fixture.store.networkPorts.loadProject(
                projectUUID: fixture.plan.projectResourceUUID
            )[0].lifecycleState,
            .reserved
        )

        let observed = try inventory(
            fixture: fixture,
            ports: [
                RuntimeInventoryPort(
                    hostAddress: "127.0.0.1",
                    hostPort: 49_152,
                    containerPort: 8_080,
                    protocolName: .tcp
                ),
            ]
        )
        let active = try NetworkPortLifecycleCoordinator
            .confirmActive(
                node: fixture.node,
                plan: fixture.plan,
                group: fixture.group,
                inventory: observed,
                store: fixture.store
            )
        XCTAssertEqual(
            active.records.map(\.lifecycleState),
            [.active]
        )
        XCTAssertEqual(
            active.records[0].observedSHA256,
            observed.semanticSHA256
        )
    }

    func testReleaseWaitsForExactAbsenceAndRefusesUnmanagedCollision()
        throws
    {
        let fixture = try makeFixture(
            ports: [
                RuntimePortMapping(
                    hostPort: nil,
                    containerPort: 8_080,
                    protocolName: .udp,
                    allocation: .dynamic
                ),
            ]
        )
        defer { fixture.cleanup() }
        let resolved = try resolvedService(fixture)
        let empty = try inventory(fixture: fixture)
        _ = try NetworkPortLifecycleCoordinator.reserve(
            service: resolved,
            node: fixture.node,
            plan: fixture.plan,
            group: fixture.group,
            inventory: empty,
            store: fixture.store
        )
        let present = try inventory(
            fixture: fixture,
            ports: [
                RuntimeInventoryPort(
                    hostAddress: "127.0.0.1",
                    hostPort: 49_152,
                    containerPort: 8_080,
                    protocolName: .udp
                ),
            ]
        )
        _ = try NetworkPortLifecycleCoordinator
            .confirmActive(
                node: fixture.node,
                plan: fixture.plan,
                group: fixture.group,
                inventory: present,
                store: fixture.store
            )
        let deleteNode = try compensationNode(
            fixture.node,
            action: .delete
        )
        let releasing = try NetworkPortLifecycleCoordinator
            .beginRelease(
                node: deleteNode,
                plan: fixture.plan,
                group: fixture.group,
                inventory: present,
                store: fixture.store
            )
        XCTAssertEqual(
            releasing.records.map(\.lifecycleState),
            [.releasing]
        )
        XCTAssertEqual(releasing.records[0].generation, 2)

        XCTAssertThrowsError(
            try NetworkPortLifecycleCoordinator
                .confirmReleased(
                    node: deleteNode,
                    plan: fixture.plan,
                    group: fixture.group,
                    inventory: present,
                    store: fixture.store
                )
        )

        let unmanagedCollision = try inventory(
            fixture: fixture,
            ports: [],
            managed: false,
            name: fixture.node.resourceIdentifier!
        )
        XCTAssertThrowsError(
            try NetworkPortLifecycleCoordinator
                .confirmReleased(
                    node: deleteNode,
                    plan: fixture.plan,
                    group: fixture.group,
                    inventory: unmanagedCollision,
                    store: fixture.store
                )
        )
        XCTAssertEqual(
            try fixture.store.networkPorts.loadProject(
                projectUUID: fixture.plan.projectResourceUUID
            )[0].lifecycleState,
            .releasing
        )

        let released = try NetworkPortLifecycleCoordinator
            .confirmReleased(
                node: deleteNode,
                plan: fixture.plan,
                group: fixture.group,
                inventory: empty,
                store: fixture.store
            )
        XCTAssertEqual(
            released.records.map(\.lifecycleState),
            [.released]
        )
        XCTAssertTrue(
            try fixture.store.networkPorts.loadProject(
                projectUUID: fixture.plan.projectResourceUUID
            ).isEmpty
        )
        XCTAssertEqual(
            try fixture.store.networkPorts.loadProject(
                projectUUID: fixture.plan.projectResourceUUID,
                includeReleased: true
            ),
            released.records
        )
    }

    func testAmbiguousDurableRowsAreRejectedWithoutMutation()
        throws
    {
        let fixture = try makeFixture(
            ports: [
                RuntimePortMapping(
                    hostPort: nil,
                    containerPort: 8_080,
                    protocolName: .tcp,
                    allocation: .dynamic
                ),
            ]
        )
        defer { fixture.cleanup() }
        let resolved = try resolvedService(fixture)
        let empty = try inventory(fixture: fixture)
        let first = try NetworkPortLifecycleCoordinator.reserve(
            service: resolved,
            node: fixture.node,
            plan: fixture.plan,
            group: fixture.group,
            inventory: empty,
            store: fixture.store
        ).records[0]
        let second = NetworkPortReservationRecord(
            id: HostwrightResourceUUID.legacy(
                kind: "network-port-ambiguity-test",
                identifier: first.id
            ),
            projectUUID: first.projectUUID,
            resourceUUID: first.resourceUUID,
            serviceName: first.serviceName,
            generation: 1,
            providerID: first.providerID,
            providerGeneration: first.providerGeneration,
            fencingToken: first.fencingToken,
            bindAddress: first.bindAddress,
            hostPort: 49_153,
            containerPort: first.containerPort,
            protocolName: first.protocolName,
            allocationKind: first.allocationKind,
            desiredSHA256: first.desiredSHA256,
            observedSHA256: nil,
            lifecycleState: .reserved,
            finalizerState: .active,
            operationGroupID: first.operationGroupID,
            createdAt: first.createdAt,
            updatedAt: first.updatedAt
        )
        _ = try fixture.store.networkPorts.save(second)
        let before = try fixture.store.networkPorts
            .loadProject(
                projectUUID: fixture.plan.projectResourceUUID
            )

        XCTAssertThrowsError(
            try NetworkPortLifecycleCoordinator
                .resolveForPlanning(
                    desiredState: DesiredRuntimeState(
                        projectName: fixture.plan.projectName,
                        services: [fixture.service]
                    ),
                    projectID: fixture.plan.projectID,
                    projectResourceUUID:
                        fixture.plan.projectResourceUUID,
                    providerID: fixture.plan.providerID,
                    providerGeneration:
                        fixture.plan.providerGeneration,
                    resourceUUID: { _ in
                        fixture.node.resourceUUID
                    },
                    store: fixture.store
                )
        )
        XCTAssertEqual(
            try fixture.store.networkPorts.loadProject(
                projectUUID: fixture.plan.projectResourceUUID
            ),
            before
        )
    }
}

private struct NetworkPortCoordinatorFixture {
    let root: URL
    let store: SQLiteStateStore
    let service: DesiredRuntimeService
    let node: LifecyclePlanNode
    let plan: LifecyclePlan
    let group: OperationGroupRecord

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeFixture(
    ports: [RuntimePortMapping]
) throws -> NetworkPortCoordinatorFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "hostwright-port-coordinator-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let store = SQLiteStateStore(
        path: root.appendingPathComponent("state.sqlite").path
    )
    try store.migrate()

    let projectID = "project-port-coordinator"
    let projectName = "port-coordinator"
    try store.desiredStates.saveManifestSnapshot(
        projectID: projectID,
        manifestPath: "hostwright.yaml",
        manifestHash: digest("a"),
        desiredGeneration: 1,
        manifest: HostwrightManifest(
            version: 2,
            project: projectName,
            services: []
        ),
        timestamp: "2026-07-26T12:00:00Z",
        mutationProvider:
            RuntimeProviderID.appleContainerCLI.rawValue
    )
    let projectUUID = try store.desiredStates
        .loadProject(id: projectID)
        .resourceUUID
    let identity = RuntimeServiceIdentity(
        projectName: projectName,
        serviceName: "api"
    )
    let resourceUUID = HostwrightResourceUUID.legacy(
        kind: "service",
        identifier: "\(projectID):\(identity.displayName)"
    )
    let fence = HostwrightResourceUUID.legacy(
        kind: "port-coordinator-fence",
        identifier: projectID
    )
    let service = DesiredRuntimeService(
        identity: identity,
        image: "example.invalid/api:latest",
        ports: ports
    )
    let node = try LifecyclePlanNode(
        key: "api-create",
        action: .create,
        serviceName: identity.displayName,
        resourceIdentifier:
            identity.managedResourceIdentifier,
        resourceUUID: resourceUUID,
        resourceGeneration: 1,
        fencingToken: fence,
        compensation: LifecycleCompensation(
            action: .delete
        )
    )
    let plan = try LifecyclePlan(
        command: .apply,
        projectID: projectID,
        projectName: projectName,
        projectResourceUUID: projectUUID,
        projectGeneration: 1,
        providerID: .appleContainerCLI,
        providerGeneration: 1,
        manifestSHA256: digest("a"),
        observationSHA256: digest("b"),
        capabilitySHA256: digest("c"),
        nodes: [node]
    )
    let group = OperationGroupRecord(
        id: HostwrightResourceUUID.legacy(
            kind: "port-coordinator-group",
            identifier: plan.planSHA256
        ),
        operationID: HostwrightResourceUUID.legacy(
            kind: "port-coordinator-operation",
            identifier: plan.planSHA256
        ),
        groupKind: "lifecycle-v1",
        projectID: projectID,
        serviceName: nil,
        plannedActionType: plan.command.rawValue,
        status: .active,
        groupIdempotencyKey: plan.planSHA256,
        planHash: plan.planSHA256,
        checkpoint: "intent-persisted",
        lockOwner: "network-port-coordinator-test",
        lockExpiresAt: "2027-07-26T12:00:00Z",
        rollbackAvailable: true,
        manualRecoveryHintRedacted: "",
        createdAt: "2026-07-26T12:00:00Z",
        updatedAt: "2026-07-26T12:00:00Z",
        metadataJSONRedacted: "{}",
        fencingToken: fence,
        intentJSONRedacted:
            "{\"planSHA256\":\"\(plan.planSHA256)\"}",
        compensationJSONRedacted: "[\"delete\"]",
        verificationJSONRedacted: "{}"
    )
    XCTAssertEqual(
        try store.operationGroups.acquire(group).acquired,
        group
    )
    return NetworkPortCoordinatorFixture(
        root: root,
        store: store,
        service: service,
        node: node,
        plan: plan,
        group: group
    )
}

private func resolvedService(
    _ fixture: NetworkPortCoordinatorFixture
) throws -> DesiredRuntimeService {
    try NetworkPortLifecycleCoordinator.resolveForPlanning(
        desiredState: DesiredRuntimeState(
            projectName: fixture.plan.projectName,
            services: [fixture.service]
        ),
        projectID: fixture.plan.projectID,
        projectResourceUUID:
            fixture.plan.projectResourceUUID,
        providerID: fixture.plan.providerID,
        providerGeneration:
            fixture.plan.providerGeneration,
        resourceUUID: { _ in fixture.node.resourceUUID },
        store: fixture.store
    ).services[0]
}

private func compensationNode(
    _ source: LifecyclePlanNode,
    action: LifecyclePlanAction
) throws -> LifecyclePlanNode {
    try LifecyclePlanNode(
        key: source.key,
        action: action,
        serviceName: source.serviceName,
        resourceIdentifier: source.resourceIdentifier,
        resourceUUID: source.resourceUUID,
        resourceGeneration: source.resourceGeneration,
        fencingToken: source.fencingToken,
        timeoutSeconds: source.timeoutSeconds
    )
}

private func inventory(
    fixture: NetworkPortCoordinatorFixture,
    ports: [RuntimeInventoryPort] = [],
    managed: Bool = true,
    name: String? = nil
) throws -> RuntimeInventory {
    let containers: [RuntimeInventoryContainer]
    if ports.isEmpty && name == nil {
        containers = []
    } else {
        let ownership: RuntimeInventoryOwnershipEvidence?
        let labels: [RuntimeInventoryLabel]
        if managed {
            let context = RuntimeMutationContext(
                providerID: fixture.plan.providerID,
                capabilitySHA256:
                    fixture.plan.capabilitySHA256,
                operationID: fixture.group.operationID,
                resourceUUID: fixture.node.resourceUUID,
                resourceGeneration:
                    fixture.node.resourceGeneration,
                projectResourceUUID:
                    fixture.plan.projectResourceUUID,
                projectGeneration:
                    fixture.plan.projectGeneration,
                providerGeneration:
                    fixture.plan.providerGeneration,
                fencingToken: fixture.group.fencingToken
            )
            ownership = RuntimeInventoryOwnershipEvidence(
                resourceUUID: context.resourceUUID,
                projectUUID: context.projectResourceUUID,
                resourceGeneration:
                    context.resourceGeneration,
                projectGeneration:
                    context.projectGeneration,
                providerID: context.providerID,
                providerGeneration:
                    context.providerGeneration,
                fencingToken: context.fencingToken
            )
            labels = try RuntimeManagedResourceIdentity.labels(
                for: fixture.service.identity,
                resourceIdentifier:
                    fixture.node.resourceIdentifier!,
                context: context
            ).map {
                RuntimeInventoryLabel(
                    key: $0.key,
                    value: $0.value
                )
            }
        } else {
            ownership = nil
            labels = []
        }
        containers = [
            RuntimeInventoryContainer(
                runtimeID:
                    name ?? fixture.node.resourceIdentifier!,
                name:
                    name ?? fixture.node.resourceIdentifier!,
                imageReference: fixture.service.image,
                lifecycle: .running,
                health: RuntimeInventoryHealth(
                    availability: .notConfigured
                ),
                labels: labels,
                ownership: ownership,
                initConfiguration:
                    RuntimeInventoryInitConfiguration(
                        executable: "/bin/api",
                        arguments: [],
                        environment: []
                    ),
                ports: ports,
                mounts: [],
                networks: [],
                services: []
            ),
        ]
    }
    return try RuntimeInventoryBuilder.build(
        machine: RuntimeInventoryMachine(
            state: .running,
            operatingSystem: "macOS 26.0",
            architecture: "arm64",
            runtimeVersion: "1.1.0",
            services: []
        ),
        containers: containers,
        images: [],
        networks: [],
        volumes: []
    )
}

private func digest(_ value: Character) -> String {
    String(repeating: String(value), count: 64)
}
