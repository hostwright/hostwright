import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightNetworking
@testable import HostwrightReconciler
@testable import HostwrightRuntime
@testable import HostwrightState

final class NetworkPortLifecycleCoordinatorTests: XCTestCase {
    func testSamePortUpdateHandoffAndActivationPreserveStoppedPredecessor() throws {
        let update = try makePortUpdate()
        defer { update.prior.cleanup() }
        let before = try update.prior.store.networkPorts.loadProject(projectUUID: update.candidate.plan.projectResourceUUID)
        let reserved = try reservePortUpdate(update)
        XCTAssertEqual(reserved.records.map(\.resourceUUID), [update.candidate.node.resourceUUID])
        XCTAssertEqual(try update.prior.store.networkPorts.load(id: before[0].id)?.lifecycleState, .released)
        XCTAssertEqual(try reservePortUpdate(update), reserved)
        let active = try NetworkPortLifecycleCoordinator.confirmActive(
            node: update.candidate.node, plan: update.candidate.plan, group: update.candidate.group,
            inventory: updateInventory(update, candidate: true), store: update.prior.store
        )
        XCTAssertEqual(active.records.map(\.lifecycleState), [.active])
    }

    func testSamePortUpdateRefusesRunningUnmanagedAndIncompletePriorWithoutChanges() throws {
        for fault in ["running", "unmanaged", "incomplete", "projection", "socket", "other-owner"] {
            let update = try makePortUpdate()
            defer { update.prior.cleanup() }
            let before = try update.prior.store.networkPorts.loadProject(projectUUID: update.candidate.plan.projectResourceUUID, includeReleased: true)
            let snapshot = try updateInventory(update, fault: fault)
            XCTAssertThrowsError(try reservePortUpdate(update, inventory: snapshot, available: fault != "socket"), fault)
            XCTAssertEqual(try update.prior.store.networkPorts.loadProject(projectUUID: update.candidate.plan.projectResourceUUID, includeReleased: true), before, fault)
        }
    }

    func testSamePortHandoffRefusesLeaseReplacementDuringSocketProbeAtomically() throws {
        let update = try makePortUpdate()
        defer { update.prior.cleanup() }
        let before = try update.prior.store.networkPorts.loadProject(projectUUID: update.candidate.plan.projectResourceUUID, includeReleased: true)
        XCTAssertThrowsError(try NetworkPortLifecycleCoordinator.reserve(service: update.candidate.service,
            node: update.candidate.node, plan: update.candidate.plan, group: update.candidate.group,
            inventory: updateInventory(update), store: update.prior.store, isAvailable: { _ in
                try update.prior.store.withConnection { connection in
                    try connection.run("UPDATE operation_groups SET lock_owner = 'replacement-owner' WHERE id = ?",
                        bindings: [.text(update.candidate.group.id)])
                }
                return true
            }))
        XCTAssertEqual(try update.prior.store.networkPorts.loadProject(projectUUID: update.candidate.plan.projectResourceUUID, includeReleased: true), before)
    }

    func testSamePortRollbackReacquiresBeforeRestartAndConfirmsOriginalCreationFence() throws {
        let update = try makePortUpdate()
        defer { update.prior.cleanup() }
        _ = try reservePortUpdate(update)
        let start = try compensationNode(update.stop, action: .start)
        let rollback = try NetworkPortLifecycleCoordinator.reserve(
            service: update.prior.service, node: start, plan: update.candidate.plan,
            group: update.candidate.group, inventory: updateInventory(update), store: update.prior.store
        )
        XCTAssertEqual(rollback.records.map(\.resourceUUID), [update.prior.node.resourceUUID])
        let originalRunning = try RuntimeInventoryBuilder.markRuntimeListAuthoritative(
            inventory(fixture: update.prior, ports: update.ports), source: .appleContainerCLIRuntimeList
        )
        let active = try NetworkPortLifecycleCoordinator.confirmActive(
            node: start, plan: update.candidate.plan, group: update.candidate.group,
            inventory: originalRunning, store: update.prior.store
        )
        XCTAssertEqual(active.records.map(\.lifecycleState), [.active])
        XCTAssertEqual(try update.prior.store.networkPorts.loadProject(projectUUID: update.candidate.plan.projectResourceUUID).map(\.resourceUUID), [update.prior.node.resourceUUID])
    }

    func testSamePortRollbackRefusesCandidateThatWasActivatedOrIsStillPresent() throws {
        for activated in [false, true] {
            let update = try makePortUpdate()
            defer { update.prior.cleanup() }
            _ = try reservePortUpdate(update)
            if activated {
                _ = try NetworkPortLifecycleCoordinator.confirmActive(
                    node: update.candidate.node, plan: update.candidate.plan, group: update.candidate.group,
                    inventory: updateInventory(update, candidate: true), store: update.prior.store
                )
            }
            let before = try update.prior.store.networkPorts.loadProject(projectUUID: update.candidate.plan.projectResourceUUID, includeReleased: true)
            XCTAssertThrowsError(try NetworkPortLifecycleCoordinator.reserve(
                service: update.prior.service, node: compensationNode(update.stop, action: .start),
                plan: update.candidate.plan, group: update.candidate.group,
                inventory: updateInventory(update, candidate: !activated), store: update.prior.store
            ))
            XCTAssertEqual(try update.prior.store.networkPorts.loadProject(projectUUID: update.candidate.plan.projectResourceUUID, includeReleased: true), before)
        }
    }

    func testRetiredPriorRecreationRequiresCandidateReleaseAndDurableInverseCreationProof() throws {
        for explicit in [false, true] {
            let update = try makePortUpdate(includeRetire: true)
            defer { update.prior.cleanup() }
            let retire = try XCTUnwrap(update.retire)
            _ = try reservePortUpdate(update)
            _ = try NetworkPortLifecycleCoordinator.confirmActive(node: update.candidate.node,
                plan: update.candidate.plan, group: update.candidate.group,
                inventory: updateInventory(update, candidate: true), store: update.prior.store)
            let deletion = try compensationNode(update.candidate.node, action: .delete)
            let candidateOnly = try RuntimeInventoryBuilder.markRuntimeListAuthoritative(
                inventory(fixture: update.candidate, ports: update.ports), source: .appleContainerCLIRuntimeList)
            _ = try NetworkPortLifecycleCoordinator.beginRelease(node: deletion, plan: update.candidate.plan,
                group: update.candidate.group, inventory: candidateOnly, store: update.prior.store)
            let absent = try RuntimeInventoryBuilder.markRuntimeListAuthoritative(
                inventory(fixture: update.prior), source: .appleContainerCLIRuntimeList)
            _ = try NetworkPortLifecycleCoordinator.confirmReleased(node: deletion, plan: update.candidate.plan,
                group: update.candidate.group, inventory: absent, store: update.prior.store)
            let restoration = try portRestoration(update, explicit: explicit)
            let create = restoration.fixture.node
            _ = try NetworkPortLifecycleCoordinator.reserve(service: update.prior.service, node: create,
                plan: restoration.fixture.plan, group: restoration.fixture.group, inventory: absent, store: update.prior.store)
            let recreated = try RuntimeInventoryBuilder.markRuntimeListAuthoritative(
                inventory(fixture: restoration.fixture, ports: update.ports, lifecycle: .created), source: .appleContainerCLIRuntimeList)
            _ = try NetworkPortLifecycleCoordinator.confirmActive(node: create, plan: restoration.fixture.plan,
                group: restoration.fixture.group, inventory: recreated, store: update.prior.store)
            XCTAssertThrowsError(try NetworkPortLifecycleCoordinator.reserve(service: update.prior.service,
                node: restoration.start, plan: restoration.fixture.plan, group: restoration.fixture.group,
                inventory: recreated, store: update.prior.store))
            let proofNode = explicit ? create : retire
            let direction: OperationGroupStepDirection = explicit ? .forward : .rollback
            try update.prior.store.operationGroupSteps.append(OperationGroupStepRecord(id: UUID().uuidString.lowercased(),
                groupID: restoration.fixture.group.id, stepKey: proofNode.key, direction: direction,
                plannedActionType: "create", serviceName: proofNode.serviceName, resourceIdentifier: proofNode.resourceIdentifier,
                stepIdempotencyKey: proofNode.idempotencyKey + ":" + direction.rawValue + ":1", status: .succeeded,
                startedAt: nil, updatedAt: hostwrightTimestamp(), finishedAt: hostwrightTimestamp(),
                lastErrorRedacted: nil, manualRecoveryHintRedacted: "", metadataJSONRedacted: "{}"),
                expectedFencingToken: restoration.fixture.group.fencingToken, expectedLockOwner: restoration.fixture.group.lockOwner!)
            _ = try NetworkPortLifecycleCoordinator.reserve(service: update.prior.service,
                node: restoration.start, plan: restoration.fixture.plan, group: restoration.fixture.group,
                inventory: recreated, store: update.prior.store)
            let running = try RuntimeInventoryBuilder.markRuntimeListAuthoritative(
                inventory(fixture: restoration.fixture, ports: update.ports), source: .appleContainerCLIRuntimeList)
            let active = try NetworkPortLifecycleCoordinator.confirmActive(node: restoration.start,
                plan: restoration.fixture.plan, group: restoration.fixture.group, inventory: running, store: update.prior.store)
            XCTAssertEqual(active.records.map(\.resourceUUID), [update.prior.node.resourceUUID])
        }
    }

    func testCompensatedCreateCleanupRequiresAuthoritativeAbsenceAndExactLease() throws {
        let fixture = try makeFixture(ports: [RuntimePortMapping(hostPort: 18_180, containerPort: 8_080)])
        defer { fixture.cleanup() }
        let empty = try inventory(fixture: fixture)
        let reserved = try NetworkPortLifecycleCoordinator.reserve(
            service: fixture.service, node: fixture.node, plan: fixture.plan,
            group: fixture.group, inventory: empty, store: fixture.store
        )
        let context = LifecycleSagaContext(
            plan: fixture.plan, operationID: fixture.group.operationID, groupID: fixture.group.id,
            fencingToken: fixture.group.fencingToken, leaseOwner: fixture.group.lockOwner,
            attempt: 1, direction: .rollback
        )
        let authoritative = try RuntimeInventoryBuilder.markRuntimeListAuthoritative(empty, source: .appleContainerCLIRuntimeList)
        let collision = try RuntimeInventoryBuilder.markRuntimeListAuthoritative(
            inventory(fixture: fixture, managed: false, name: fixture.node.resourceIdentifier),
            source: .appleContainerCLIRuntimeList
        )
        let wrongProvider = try RuntimeInventoryBuilder.markRuntimeListAuthoritative(empty, source: .appleContainerizationRuntimeList)
        for snapshot in [empty, collision, wrongProvider] {
            XCTAssertThrowsError(try NetworkPortLifecycleCoordinator.confirmCompensatedCreateReleased(
                node: fixture.node, context: context, inventory: snapshot, store: fixture.store
            ))
        }
        for invalid in [
            LifecycleSagaContext(plan: fixture.plan, operationID: fixture.group.operationID,
                groupID: UUID().uuidString.lowercased(), fencingToken: fixture.group.fencingToken,
                leaseOwner: fixture.group.lockOwner, attempt: 1, direction: .rollback),
            LifecycleSagaContext(plan: fixture.plan, operationID: fixture.group.operationID,
                groupID: fixture.group.id, fencingToken: UUID().uuidString.lowercased(),
                leaseOwner: fixture.group.lockOwner, attempt: 1, direction: .rollback),
            LifecycleSagaContext(plan: fixture.plan, operationID: fixture.group.operationID,
                groupID: fixture.group.id, fencingToken: fixture.group.fencingToken,
                leaseOwner: "wrong-owner", attempt: 1, direction: .rollback),
            LifecycleSagaContext(plan: fixture.plan, operationID: fixture.group.operationID,
                groupID: fixture.group.id, fencingToken: fixture.group.fencingToken,
                leaseOwner: nil, attempt: 1, direction: .rollback),
            LifecycleSagaContext(plan: fixture.plan, operationID: fixture.group.operationID,
                groupID: fixture.group.id, fencingToken: fixture.group.fencingToken,
                leaseOwner: fixture.group.lockOwner, attempt: 1, direction: .forward)
        ] {
            XCTAssertThrowsError(try NetworkPortLifecycleCoordinator.confirmCompensatedCreateReleased(
                node: fixture.node, context: invalid, inventory: authoritative, store: fixture.store
            ))
        }
        XCTAssertEqual(try fixture.store.networkPorts.loadProject(projectUUID: fixture.plan.projectResourceUUID), reserved.records)
        let released = try NetworkPortLifecycleCoordinator.confirmCompensatedCreateReleased(
            node: fixture.node, context: context, inventory: authoritative, store: fixture.store
        )
        XCTAssertEqual(released.records.map(\.lifecycleState), [.released])
        XCTAssertEqual(released.records.map(\.finalizerState), [.released])
        XCTAssertTrue(try fixture.store.networkPorts.loadProject(projectUUID: fixture.plan.projectResourceUUID).isEmpty)
    }

    func testCompensatedCreateCleanupPreservesUnmanagedRowsAndRefusesAmbiguousReservations() throws {
        for ambiguous in [false, true] {
            let fixture = try makeFixture(ports: [RuntimePortMapping(hostPort: 18_180, containerPort: 8_080)])
            defer { fixture.cleanup() }
            let empty = try inventory(fixture: fixture)
            let first = try XCTUnwrap(NetworkPortLifecycleCoordinator.reserve(
                service: fixture.service, node: fixture.node, plan: fixture.plan,
                group: fixture.group, inventory: empty, store: fixture.store
            ).records.first)
            let second = NetworkPortReservationRecord(
                id: UUID().uuidString.lowercased(), projectUUID: first.projectUUID,
                resourceUUID: ambiguous ? first.resourceUUID : UUID().uuidString.lowercased(),
                serviceName: ambiguous ? first.serviceName : "unmanaged-service", generation: 1,
                providerID: first.providerID, providerGeneration: first.providerGeneration,
                fencingToken: first.fencingToken, bindAddress: first.bindAddress,
                hostPort: 18_181, containerPort: first.containerPort, protocolName: first.protocolName,
                allocationKind: first.allocationKind, desiredSHA256: first.desiredSHA256,
                observedSHA256: nil, lifecycleState: .reserved, finalizerState: .active,
                operationGroupID: first.operationGroupID, createdAt: first.createdAt, updatedAt: first.updatedAt
            )
            _ = try fixture.store.networkPorts.save(second)
            let context = LifecycleSagaContext(plan: fixture.plan, operationID: fixture.group.operationID,
                groupID: fixture.group.id, fencingToken: fixture.group.fencingToken,
                leaseOwner: fixture.group.lockOwner, attempt: 1, direction: .rollback)
            let authoritative = try RuntimeInventoryBuilder.markRuntimeListAuthoritative(empty, source: .appleContainerCLIRuntimeList)
            if ambiguous {
                XCTAssertThrowsError(try NetworkPortLifecycleCoordinator.confirmCompensatedCreateReleased(
                    node: fixture.node, context: context, inventory: authoritative, store: fixture.store
                ))
                XCTAssertEqual(try fixture.store.networkPorts.load(id: first.id), first)
            } else {
                _ = try NetworkPortLifecycleCoordinator.confirmCompensatedCreateReleased(
                    node: fixture.node, context: context, inventory: authoritative, store: fixture.store
                )
                XCTAssertEqual(try fixture.store.networkPorts.load(id: first.id)?.lifecycleState, .released)
            }
            XCTAssertEqual(try fixture.store.networkPorts.load(id: second.id), second)
        }
    }

    func testHistoricalCompensatedReservedPortTransfersOnlyAfterVerifiedAbsence() throws {
        let fixture = try makeFixture(ports: [RuntimePortMapping(hostPort: 18_180, containerPort: 8_080)])
        defer { fixture.cleanup() }
        let empty = try inventory(fixture: fixture)
        let prior = try XCTUnwrap(NetworkPortLifecycleCoordinator.reserve(
            service: fixture.service, node: fixture.node, plan: fixture.plan,
            group: fixture.group, inventory: empty, store: fixture.store
        ).records.first)
        try fixture.store.operationGroups.finishExactLease(
            groupID: fixture.group.id, expectedFencingToken: fixture.group.fencingToken,
            expectedLockOwner: fixture.group.lockOwner!, expectedLockExpiresAt: fixture.group.lockExpiresAt!,
            status: .failed, checkpoint: "compensated", manualRecoveryHintRedacted: "",
            updatedAt: hostwrightTimestamp(), metadataJSONRedacted: "{}"
        )
        let identifier = UUID().uuidString.lowercased()
        let group = OperationGroupRecord(
            id: identifier, operationID: identifier, groupKind: fixture.group.groupKind,
            projectID: fixture.group.projectID, serviceName: nil,
            plannedActionType: fixture.group.plannedActionType, status: .active,
            groupIdempotencyKey: identifier, planHash: fixture.group.planHash, checkpoint: "intent-persisted",
            lockOwner: fixture.group.lockOwner, lockExpiresAt: fixture.group.lockExpiresAt,
            rollbackAvailable: true, manualRecoveryHintRedacted: "", createdAt: hostwrightTimestamp(),
            updatedAt: hostwrightTimestamp(), metadataJSONRedacted: "{}",
            fencingToken: UUID().uuidString.lowercased(), intentJSONRedacted: fixture.group.intentJSONRedacted,
            compensationJSONRedacted: fixture.group.compensationJSONRedacted, verificationJSONRedacted: "{}"
        )
        XCTAssertNotNil(try fixture.store.operationGroups.acquire(group).acquired)
        XCTAssertThrowsError(try NetworkPortLifecycleCoordinator.reserve(
            service: fixture.service, node: fixture.node, plan: fixture.plan, group: group,
            inventory: empty, store: fixture.store
        ))
        let observed = try RuntimeInventoryBuilder.markRuntimeListAuthoritative(empty, source: .appleContainerCLIRuntimeList)
        let renewed = try XCTUnwrap(NetworkPortLifecycleCoordinator.reserve(
            service: fixture.service, node: fixture.node, plan: fixture.plan, group: group,
            inventory: observed, store: fixture.store
        ).records.first)
        XCTAssertEqual(renewed.id, prior.id)
        XCTAssertEqual(renewed.hostPort, prior.hostPort)
        XCTAssertEqual(renewed.generation, prior.generation + 1)
        XCTAssertEqual(renewed.lifecycleState, .reserved)
        XCTAssertEqual(renewed.operationGroupID, group.id)
    }

    func testUpdateCreateNodeReservesForExactLogicalServiceName() throws {
        let fixture = try makeFixture(
            ports: [
                RuntimePortMapping(
                    hostPort: 18_080,
                    containerPort: 8_080,
                    protocolName: .tcp,
                    bindAddress: "127.0.0.1"
                ),
            ],
            nodeServiceName: "api"
        )
        defer { fixture.cleanup() }

        let reserved = try NetworkPortLifecycleCoordinator.reserve(
            service: try resolvedService(fixture),
            node: fixture.node,
            plan: fixture.plan,
            group: fixture.group,
            inventory: try inventory(fixture: fixture),
            store: fixture.store
        )

        XCTAssertEqual(reserved.records.count, 1)
        XCTAssertEqual(reserved.records[0].hostPort, 18_080)
    }

    func testNonLocalExactBindPlansOnlyAfterExposureApproval()
        throws
    {
        let bindAddress = "192.168.50.12"
        let policy = HostwrightPortExposurePolicy(
            scope: .lan,
            interfaces: ["en0"],
            networkClasses: [.privateLAN],
            allowedCIDRs: ["192.168.50.0/24"],
            authentication: .tls
        )
        let fixture = try makeFixture(
            ports: [
                RuntimePortMapping(
                    hostPort: 18_080,
                    containerPort: 8_080,
                    protocolName: .tcp,
                    bindAddress: bindAddress,
                    allocation: .fixed,
                    exposurePolicy: policy
                ),
            ]
        )
        defer { fixture.cleanup() }
        var approvedEndpoints: [NetworkPortEndpoint] = []

        let resolved = try NetworkPortLifecycleCoordinator
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
                store: fixture.store,
                isExposureAvailable: { endpoint, exposure in
                    approvedEndpoints.append(endpoint)
                    XCTAssertEqual(exposure, policy)
                    return true
                }
            )

        XCTAssertEqual(
            resolved.services[0].ports[0].bindAddress,
            bindAddress
        )
        XCTAssertEqual(
            approvedEndpoints,
            [
                NetworkPortEndpoint(
                    bindAddress: bindAddress,
                    hostPort: 18_080,
                    protocolName: .tcp
                ),
                NetworkPortEndpoint(
                    bindAddress: bindAddress,
                    hostPort: 18_080,
                    protocolName: .tcp
                ),
            ]
        )
    }

    func testPlanningResolutionPreservesUnixSocketPublications() throws {
        let socket = RuntimeUnixSocketPublication(
            hostPath: "/tmp/hostwright/api.sock",
            containerPath: "/run/api.sock",
            mode: .ownerAndGroup
        )
        let fixture = try makeFixture(
            ports: [],
            publishedSockets: [socket]
        )
        defer { fixture.cleanup() }

        let resolved = try NetworkPortLifecycleCoordinator
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
                resourceUUID: { _ in nil },
                store: fixture.store
            )

        XCTAssertEqual(resolved.services[0].publishedSockets, [socket])
    }

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
    ports: [RuntimePortMapping],
    publishedSockets: [RuntimeUnixSocketPublication] = [],
    nodeServiceName: String? = nil
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
            version: 3,
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
        ports: ports,
        publishedSockets: publishedSockets
    )
    let node = try LifecyclePlanNode(
        key: "api-create",
        action: .create,
        serviceName: nodeServiceName ?? identity.displayName,
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
        intentJSONRedacted: try LifecyclePersistedIntentCodec.encode(plan),
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
        timeoutSeconds: source.timeoutSeconds,
        desiredSpecificationJSONRedacted: source.desiredSpecificationJSONRedacted
    )
}

private func inventory(
    fixture: NetworkPortCoordinatorFixture,
    ports: [RuntimeInventoryPort] = [],
    managed: Bool = true,
    name: String? = nil,
    lifecycle: RuntimeInventoryLifecycleState = .running
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
                lifecycle: lifecycle,
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

private struct PortUpdateFixture {
    let prior: NetworkPortCoordinatorFixture
    let candidate: NetworkPortCoordinatorFixture
    let stop: LifecyclePlanNode
    let retire: LifecyclePlanNode?
    let ports: [RuntimeInventoryPort]
}

private func makePortUpdate(includeRetire: Bool = false) throws -> PortUpdateFixture {
    let prior = try makeFixture(ports: [RuntimePortMapping(hostPort: 18_180, containerPort: 8_080)])
    let ports = [RuntimeInventoryPort(hostAddress: "127.0.0.1", hostPort: 18_180, containerPort: 8_080, protocolName: .tcp)]
    _ = try NetworkPortLifecycleCoordinator.reserve(service: prior.service, node: prior.node, plan: prior.plan,
        group: prior.group, inventory: inventory(fixture: prior), store: prior.store)
    _ = try NetworkPortLifecycleCoordinator.confirmActive(node: prior.node, plan: prior.plan, group: prior.group,
        inventory: inventory(fixture: prior, ports: ports), store: prior.store)
    try prior.store.operationGroups.finishExactLease(groupID: prior.group.id,
        expectedFencingToken: prior.group.fencingToken, expectedLockOwner: prior.group.lockOwner!,
        expectedLockExpiresAt: prior.group.lockExpiresAt!, status: .succeeded, checkpoint: "verified",
        manualRecoveryHintRedacted: "", updatedAt: hostwrightTimestamp(), metadataJSONRedacted: "{}")
    let fence = UUID().uuidString.lowercased()
    let stop = try LifecyclePlanNode(key: "api-quiesce", action: .stop, serviceName: "api",
        resourceIdentifier: prior.node.resourceIdentifier, resourceUUID: prior.node.resourceUUID,
        resourceGeneration: prior.node.resourceGeneration, fencingToken: fence,
        compensation: LifecycleCompensation(action: .start),
        desiredSpecificationJSONRedacted: LifecycleRevisionCodec.redactedDesiredJSON(for: prior.service))
    let candidate = try LifecyclePlanNode(key: "api-candidate", action: .create, serviceName: "api",
        resourceIdentifier: String(prior.node.resourceIdentifier!.dropLast(32)) + String(repeating: "c", count: 32), resourceUUID: UUID().uuidString.lowercased(),
        resourceGeneration: 2, fencingToken: fence, dependencies: [stop.key],
        compensation: LifecycleCompensation(action: .delete),
        desiredSpecificationJSONRedacted: LifecycleRevisionCodec.redactedDesiredJSON(for: prior.service))
    let retire = try LifecyclePlanNode(key: "api-retire", action: .retire, serviceName: "api",
        resourceIdentifier: prior.node.resourceIdentifier, resourceUUID: prior.node.resourceUUID,
        resourceGeneration: prior.node.resourceGeneration, fencingToken: fence, dependencies: [candidate.key],
        compensation: LifecycleCompensation(action: .create),
        desiredSpecificationJSONRedacted: LifecycleRevisionCodec.redactedDesiredJSON(for: prior.service))
    let plan = try LifecyclePlan(command: .update, projectID: prior.plan.projectID, projectName: prior.plan.projectName,
        projectResourceUUID: prior.plan.projectResourceUUID, projectGeneration: prior.plan.projectGeneration,
        providerID: prior.plan.providerID, providerGeneration: prior.plan.providerGeneration,
        manifestSHA256: digest("d"), observationSHA256: digest("b"), capabilitySHA256: digest("c"), nodes: [stop, candidate] + (includeRetire ? [retire] : []))
    let id = UUID().uuidString.lowercased()
    let group = OperationGroupRecord(id: id, operationID: id, groupKind: "lifecycle-v1", projectID: plan.projectID,
        serviceName: nil, plannedActionType: "update", status: .active, groupIdempotencyKey: plan.planSHA256,
        planHash: plan.planSHA256, checkpoint: "intent-persisted", lockOwner: "port-update-test",
        lockExpiresAt: "2027-07-26T12:00:00Z", rollbackAvailable: true, manualRecoveryHintRedacted: "",
        createdAt: hostwrightTimestamp(), updatedAt: hostwrightTimestamp(), metadataJSONRedacted: "{}",
        fencingToken: fence, intentJSONRedacted: try LifecyclePersistedIntentCodec.encode(plan),
        compensationJSONRedacted: "[]", verificationJSONRedacted: "{}")
    XCTAssertNotNil(try prior.store.operationGroups.acquire(group).acquired)
    try prior.store.operationGroupSteps.append(OperationGroupStepRecord(id: UUID().uuidString.lowercased(),
        groupID: group.id, stepKey: stop.key, direction: .forward, plannedActionType: "stop", serviceName: "api",
        resourceIdentifier: stop.resourceIdentifier, stepIdempotencyKey: "port-quiesce", status: .succeeded,
        startedAt: nil, updatedAt: hostwrightTimestamp(), finishedAt: hostwrightTimestamp(), lastErrorRedacted: nil,
        manualRecoveryHintRedacted: "", metadataJSONRedacted: "{}"), expectedFencingToken: fence, expectedLockOwner: group.lockOwner!)
    return PortUpdateFixture(prior: prior,
        candidate: NetworkPortCoordinatorFixture(root: prior.root, store: prior.store, service: prior.service,
            node: candidate, plan: plan, group: group), stop: stop, retire: includeRetire ? retire : nil, ports: ports)
}

private func portRestoration(_ update: PortUpdateFixture, explicit: Bool) throws -> (fixture: NetworkPortCoordinatorFixture, start: LifecyclePlanNode) {
    let retire = try XCTUnwrap(update.retire)
    if !explicit {
        return (NetworkPortCoordinatorFixture(root: update.prior.root, store: update.prior.store,
            service: update.prior.service, node: try compensationNode(retire, action: .create),
            plan: update.candidate.plan, group: update.candidate.group), try compensationNode(update.stop, action: .start))
    }
    try update.prior.store.operationGroups.finishExactLease(groupID: update.candidate.group.id,
        expectedFencingToken: update.candidate.group.fencingToken, expectedLockOwner: update.candidate.group.lockOwner!,
        expectedLockExpiresAt: update.candidate.group.lockExpiresAt!, status: .failed, checkpoint: "compensated",
        manualRecoveryHintRedacted: "", updatedAt: hostwrightTimestamp(), metadataJSONRedacted: "{}")
    let fence = UUID().uuidString.lowercased()
    let source = LifecyclePlanCondition(kind: "rollback-source-group", subject: update.candidate.group.id,
        expectedValue: update.candidate.plan.planSHA256)
    func inverse(_ original: LifecyclePlanNode, action: LifecyclePlanAction, dependencies: [String]) throws -> LifecyclePlanNode {
        try LifecyclePlanNode(key: "rollback-" + original.key, action: action, serviceName: original.serviceName,
            resourceIdentifier: original.resourceIdentifier, resourceUUID: original.resourceUUID,
            resourceGeneration: original.resourceGeneration, fencingToken: fence, dependencies: dependencies,
            preconditions: [source], postconditions: [LifecyclePlanCondition(kind: "rollback-effect-verified",
                subject: original.key, expectedValue: "true")], desiredSpecificationJSONRedacted: original.desiredSpecificationJSONRedacted)
    }
    let create = try inverse(retire, action: .create, dependencies: [])
    let start = try inverse(update.stop, action: .start, dependencies: [create.key])
    let previous = update.candidate.plan
    let plan = try LifecyclePlan(command: .rollback, projectID: previous.projectID, projectName: previous.projectName,
        projectResourceUUID: previous.projectResourceUUID, projectGeneration: previous.projectGeneration,
        providerID: previous.providerID, providerGeneration: previous.providerGeneration,
        manifestSHA256: previous.manifestSHA256, observationSHA256: previous.observationSHA256,
        capabilitySHA256: previous.capabilitySHA256, nodes: [create, start])
    let id = UUID().uuidString.lowercased()
    let group = OperationGroupRecord(id: id, operationID: id, groupKind: "lifecycle-v1", projectID: plan.projectID,
        serviceName: nil, plannedActionType: "rollback", status: .active, groupIdempotencyKey: plan.planSHA256,
        planHash: plan.planSHA256, checkpoint: "intent-persisted", lockOwner: "port-rollback-test",
        lockExpiresAt: "2027-07-26T12:00:00Z", rollbackAvailable: false, manualRecoveryHintRedacted: "",
        createdAt: hostwrightTimestamp(), updatedAt: hostwrightTimestamp(), metadataJSONRedacted: "{}",
        fencingToken: fence, intentJSONRedacted: try LifecyclePersistedIntentCodec.encode(plan),
        compensationJSONRedacted: "[]", verificationJSONRedacted: "{}")
    XCTAssertNotNil(try update.prior.store.operationGroups.acquire(group).acquired)
    return (NetworkPortCoordinatorFixture(root: update.prior.root, store: update.prior.store,
        service: update.prior.service, node: create, plan: plan, group: group), start)
}

private func updateInventory(_ update: PortUpdateFixture, candidate: Bool = false, fault: String = "") throws -> RuntimeInventory {
    let old = try inventory(fixture: update.prior,
        ports: fault == "projection" ? [RuntimeInventoryPort(hostAddress: "127.0.0.1", hostPort: 18_181, containerPort: 8_080, protocolName: .tcp)] : update.ports,
        managed: fault != "unmanaged", lifecycle: fault == "running" ? .running : .stopped)
    let new = try inventory(fixture: update.candidate, ports: candidate ? update.ports : [])
    let combined = try RuntimeInventoryBuilder.build(machine: old.machine,
        containers: old.containers + new.containers + (fault == "other-owner" ? try inventory(fixture: update.prior,
            ports: update.ports, managed: false, name: "unmanaged-port-owner").containers : []),
        images: [], networks: [], volumes: [])
    return fault == "incomplete" ? combined : try RuntimeInventoryBuilder.markRuntimeListAuthoritative(combined, source: .appleContainerCLIRuntimeList)
}

private func reservePortUpdate(_ update: PortUpdateFixture, inventory: RuntimeInventory? = nil, available: Bool = true) throws -> NetworkPortReservationBatch {
    try NetworkPortLifecycleCoordinator.reserve(service: update.candidate.service, node: update.candidate.node,
        plan: update.candidate.plan, group: update.candidate.group, inventory: inventory ?? updateInventory(update),
        store: update.prior.store, isAvailable: { _ in available })
}

private func digest(_ value: Character) -> String {
    String(repeating: String(value), count: 64)
}
