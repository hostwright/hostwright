import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightNetworking
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

struct NetworkPortEndpoint: Hashable, Sendable {
    let bindAddress: String
    let hostPort: Int
    let protocolName: RuntimePortProtocol

    init(
        bindAddress: String?,
        hostPort: Int,
        protocolName: RuntimePortProtocol
    ) {
        self.bindAddress = Self.normalizedBindAddress(bindAddress)
        self.hostPort = hostPort
        self.protocolName = protocolName
    }

    func conflicts(with other: NetworkPortEndpoint) -> Bool {
        NetworkBindAddressPolicy.hostPortsConflict(
            lhsBindAddress: bindAddress,
            lhsHostPort: hostPort,
            lhsProtocolName: protocolName.rawValue,
            rhsBindAddress: other.bindAddress,
            rhsHostPort: other.hostPort,
            rhsProtocolName: other.protocolName.rawValue
        )
    }

    private static func normalizedBindAddress(
        _ value: String?
    ) -> String {
        let normalized =
            NetworkBindAddressPolicy.normalizedBindAddress(value)
        if normalized == "localhost" {
            return NetworkBindAddressPolicy.localhostBindAddress
        }
        return normalized
    }
}

struct NetworkPortReservationBatch: Equatable, Sendable {
    let records: [NetworkPortReservationRecord]
}

private struct NetworkPortDesiredIntent:
    Codable,
    Equatable,
    Sendable
{
    let schemaVersion: Int
    let projectUUID: String
    let resourceUUID: String
    let serviceName: String
    let providerID: String
    let providerGeneration: Int
    let bindAddress: String
    let requestedHostPort: Int?
    let containerPort: Int
    let protocolName: String
    let allocationKind: String
}

private struct NetworkPortWorkItem {
    let serviceIndex: Int
    let portIndex: Int
    let resourceUUID: String
    let service: DesiredRuntimeService
    let mapping: RuntimePortMapping
    let bindAddress: String

    var orderingKey: String {
        [
            resourceUUID,
            String(format: "%05d", mapping.containerPort),
            mapping.protocolName.rawValue,
            bindAddress,
            String(format: "%05d", portIndex),
        ].joined(separator: "\u{1f}")
    }
}

enum NetworkPortLifecycleCoordinator {
    typealias AvailabilityProbe =
        (NetworkPortEndpoint) throws -> Bool
    typealias ExposureAvailabilityProbe =
        (NetworkPortEndpoint, HostwrightPortExposurePolicy) throws -> Bool
    typealias ResourceUUIDResolver =
        (RuntimeServiceIdentity) throws -> String?

    static func occupiedPorts(
        in inventory: RuntimeInventory,
        excludingResourceUUIDs: Set<String> = []
    ) -> Set<NetworkPortEndpoint> {
        Set(
            inventory.containers.filter { container in
                !excludingResourceUUIDs.contains(container.ownership?.resourceUUID ?? "")
            }.flatMap { container in
                container.ports.compactMap {
                    port -> NetworkPortEndpoint? in
                    guard let hostPort = port.hostPort else {
                        return nil
                    }
                    return NetworkPortEndpoint(
                        bindAddress: port.hostAddress,
                        hostPort: hostPort,
                        protocolName:
                            runtimeProtocol(port.protocolName)
                    )
                }
            }
        )
    }

    static func resolveForPlanning(
        desiredState: DesiredRuntimeState,
        projectID: String,
        projectResourceUUID: String,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        bindings: [LifecycleResourceBinding],
        store: SQLiteStateStore,
        occupiedPorts: Set<NetworkPortEndpoint> = [],
        allowReleasingForRemoval: Bool = false,
        isAvailable: AvailabilityProbe = { _ in true },
        isExposureAvailable: ExposureAvailabilityProbe? = nil
    ) throws -> DesiredRuntimeState {
        let bindingsByIdentity = Dictionary(
            grouping: bindings,
            by: \.identity
        )
        return try resolveForPlanning(
            desiredState: desiredState,
            projectID: projectID,
            projectResourceUUID: projectResourceUUID,
            providerID: providerID,
            providerGeneration: providerGeneration,
            resourceUUID: { identity in
                let matches = bindingsByIdentity[identity] ?? []
                guard matches.count <= 1 else {
                    throw conflict(
                        "Port planning found ambiguous lifecycle ownership for \(identity.displayName)."
                    )
                }
                guard let binding = matches.first else {
                    return nil
                }
                guard binding.projectResourceUUID ==
                        projectResourceUUID,
                      binding.providerID == providerID,
                      binding.providerGeneration ==
                        providerGeneration else {
                    throw conflict(
                        "Port planning refused a stale project or provider binding."
                    )
                }
                return binding.resourceUUID
            },
            store: store,
            occupiedPorts: occupiedPorts,
            allowReleasingForRemoval: allowReleasingForRemoval,
            isAvailable: isAvailable,
            isExposureAvailable: isExposureAvailable
        )
    }

    static func resolveForPlanning(
        desiredState: DesiredRuntimeState,
        projectID: String,
        projectResourceUUID: String,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        resourceUUID: ResourceUUIDResolver,
        store: SQLiteStateStore,
        occupiedPorts: Set<NetworkPortEndpoint> = [],
        allowReleasingForRemoval: Bool = false,
        isAvailable: AvailabilityProbe = { _ in true },
        isExposureAvailable: ExposureAvailabilityProbe? = nil
    ) throws -> DesiredRuntimeState {
        guard !projectID.isEmpty,
              HostwrightResourceUUID.isValid(
                  projectResourceUUID
              ),
              RuntimeProviderID.knownValues.contains(providerID),
              providerGeneration > 0 else {
            throw conflict(
                "Port planning requires an exact project and provider authority."
            )
        }

        var resourceUUIDs: [Int: String] = [:]
        var identitiesByResourceUUID:
            [String: RuntimeServiceIdentity] = [:]
        for (index, service) in
            desiredState.services.enumerated()
        {
            guard service.identity.projectName ==
                    desiredState.projectName else {
                throw conflict(
                    "Port planning found a service outside the desired project."
                )
            }
            let resolved =
                try resourceUUID(service.identity) ??
                HostwrightResourceUUID.legacy(
                    kind: "service",
                    identifier:
                        "\(projectID):\(service.identity.displayName)"
                )
            let canonicalResourceUUID = resolved.lowercased()
            guard HostwrightResourceUUID.isValid(
                      canonicalResourceUUID
                  ),
                  identitiesByResourceUUID[
                    canonicalResourceUUID
                  ] == nil ||
                    identitiesByResourceUUID[
                        canonicalResourceUUID
                    ] ==
                        service.identity else {
                throw conflict(
                    "Port planning found an invalid or ambiguous resource UUID."
                )
            }
            resourceUUIDs[index] = canonicalResourceUUID
            identitiesByResourceUUID[canonicalResourceUUID] =
                service.identity
        }

        let records = try store.networkPorts.loadProject(
            projectUUID: projectResourceUUID,
            includeReleased: true
        )
        let liveRecords = records.filter {
            $0.lifecycleState != .released
        }
        let workItems = try planningWorkItems(
            desiredState: desiredState,
            resourceUUIDs: resourceUUIDs
        )
        for item in workItems where item.mapping.exposurePolicy.scope != .localhost {
            guard let isExposureAvailable else {
                throw conflict(
                    "Non-local port planning requires an approved exposure availability check."
                )
            }
            guard try isExposureAvailable(
                NetworkPortEndpoint(
                    bindAddress: item.bindAddress,
                    hostPort: item.mapping.hostPort ?? 0,
                    protocolName: item.mapping.protocolName
                ),
                item.mapping.exposurePolicy
            ) else {
                throw conflict(
                    "The declared non-local exposure is not currently available."
                )
            }
        }
        var resolvedMappings:
            [Int: [Int: RuntimePortMapping]] = [:]
        var claimed: Set<NetworkPortEndpoint> = []

        for item in workItems {
            let desiredSHA256 = try desiredDigest(
                projectUUID: projectResourceUUID,
                resourceUUID: item.resourceUUID,
                serviceName: item.service.identity.displayName,
                providerID: providerID,
                providerGeneration: providerGeneration,
                mapping: item.mapping,
                bindAddress: item.bindAddress
            )
            let candidates = liveRecords.filter {
                logicalMatch(
                    $0,
                    resourceUUID: item.resourceUUID,
                    mapping: item.mapping,
                    bindAddress: item.bindAddress
                )
            }
            guard candidates.count <= 1 else {
                throw conflict(
                    "Port planning found ambiguous durable reservations for one container port."
                )
            }

            let hostPort: Int
            if let existing = candidates.first {
                try requireReusable(
                    existing,
                    projectUUID: projectResourceUUID,
                    resourceUUID: item.resourceUUID,
                    serviceName:
                        item.service.identity.displayName,
                    providerID: providerID,
                    providerGeneration: providerGeneration,
                    mapping: item.mapping,
                    bindAddress: item.bindAddress,
                    desiredSHA256: desiredSHA256,
                    allowReleasingForRemoval: allowReleasingForRemoval
                )
                hostPort = existing.hostPort
            } else {
                hostPort = try selectNewHostPort(
                    mapping: item.mapping,
                    bindAddress: item.bindAddress,
                    stateRecords: liveRecords,
                    occupiedPorts: occupiedPorts,
                    claimedPorts: claimed,
                    store: store,
                    isAvailable: isAvailable,
                    isExposureAvailable: isExposureAvailable
                )
            }

            let endpoint = NetworkPortEndpoint(
                bindAddress: item.bindAddress,
                hostPort: hostPort,
                protocolName: item.mapping.protocolName
            )
            guard !containsConflict(endpoint, in: claimed)
            else {
                throw conflict(
                    "Port planning found duplicate desired host-port ownership."
                )
            }
            claimed.insert(endpoint)
            resolvedMappings[item.serviceIndex, default: [:]][
                item.portIndex
            ] = RuntimePortMapping(
                hostPort: hostPort,
                containerPort: item.mapping.containerPort,
                protocolName: item.mapping.protocolName,
                bindAddress: item.bindAddress,
                allocation: item.mapping.allocation,
                exposurePolicy: item.mapping.exposurePolicy
            )
        }

        let services = desiredState.services.enumerated().map {
            index,
            service in
            replacingPorts(
                in: service,
                with: service.ports.indices.map {
                    resolvedMappings[index]?[$0] ??
                        service.ports[$0]
                }
            )
        }
        return DesiredRuntimeState(
            projectName: desiredState.projectName,
            networks: desiredState.networks,
            services: services,
            ownedResourceHints: desiredState.ownedResourceHints
        )
    }

    @discardableResult
    static func reserve(
        service: DesiredRuntimeService,
        node: LifecyclePlanNode,
        plan: LifecyclePlan,
        group: OperationGroupRecord,
        inventory: RuntimeInventory,
        store: SQLiteStateStore,
        isAvailable: AvailabilityProbe = { _ in true }
    ) throws -> NetworkPortReservationBatch {
        try requireAuthority(
            plan: plan,
            node: node,
            group: group,
            store: store
        )
        let exactServiceNames = Set([
            service.identity.displayName,
            service.logicalServiceName,
        ])
        let rollback = try rollbackPortSource(node: node, plan: plan, group: group, store: store)
        guard (node.action == .create || rollback != nil),
              node.serviceName.map(exactServiceNames.contains) == true,
              service.identity.projectName == plan.projectName else {
            throw conflict(
                "Port reservation requires the exact lifecycle create node and service."
            )
        }
        guard !service.ports.isEmpty else {
            return NetworkPortReservationBatch(records: [])
        }

        let workItems = try planningWorkItems(
            desiredState: DesiredRuntimeState(
                projectName: plan.projectName,
                services: [service]
            ),
            resourceUUIDs: [0: node.resourceUUID]
        )
        let persisted = try store.networkPorts.loadProject(
            projectUUID: plan.projectResourceUUID,
            includeReleased: true
        )
        let liveRecords = persisted.filter {
            $0.lifecycleState != .released
        }
        let prior = try quiescedUpdatePrior(node: node, plan: plan, group: group, inventory: inventory, store: store)
        let excluded: Set<String> = Set([prior?.node.resourceUUID, rollback?.node.resourceUUID].compactMap { $0 })
        var changes: [(record: NetworkPortReservationRecord, expected: NetworkStateExpectedVersion?)] = []
        if let rollback {
            try requireStoppedPortOwner(node: rollback.node, plan: rollback.plan, group: group, inventory: inventory, store: store)
            for candidate in rollback.plan.nodes where candidate.action == .create && depends(candidate, on: rollback.node.key, in: rollback.plan) {
                let rows = liveRecords.filter { $0.resourceUUID == candidate.resourceUUID }
                guard !rows.isEmpty else { continue }
                guard targetContainers(node: candidate, inventory: inventory).isEmpty,
                      rows.allSatisfy({ $0.operationGroupID == rollback.group.id && $0.fencingToken == rollback.group.fencingToken && $0.lifecycleState == .reserved && $0.observedSHA256 == nil }) else {
                    throw conflict("Rollback cannot reacquire ports until the exact candidate is deleted or its unactivated intent is proven absent.")
                }
                changes += releaseChanges(rows, group: group, inventory: inventory, plan: plan)
            }
        }
        let releasingIDs = Set(changes.map { $0.record.id })
        var claimed: Set<NetworkPortEndpoint> = []
        var existingRecords:
            [NetworkPortReservationRecord] = []
        var newRecords: [NetworkPortReservationRecord] = []
        let now = hostwrightTimestamp()

        for item in workItems {
            guard let hostPort = item.mapping.hostPort else {
                throw conflict(
                    "Port reservation requires planning to resolve every dynamic host port."
                )
            }
            let endpoint = NetworkPortEndpoint(
                bindAddress: item.bindAddress,
                hostPort: hostPort,
                protocolName: item.mapping.protocolName
            )
            guard !containsConflict(endpoint, in: claimed)
            else {
                throw conflict(
                    "Port reservation found duplicate desired host-port ownership."
                )
            }
            let desiredSHA256 = try desiredDigest(
                projectUUID: plan.projectResourceUUID,
                resourceUUID: node.resourceUUID,
                serviceName: service.identity.displayName,
                providerID: plan.providerID,
                providerGeneration: plan.providerGeneration,
                mapping: item.mapping,
                bindAddress: item.bindAddress
            )
            let candidates = liveRecords.filter {
                logicalMatch(
                    $0,
                    resourceUUID: node.resourceUUID,
                    mapping: item.mapping,
                    bindAddress: item.bindAddress
                )
            }
            guard candidates.count <= 1 else {
                throw conflict(
                    "Port reservation found ambiguous durable rows for one container port."
                )
            }

            if let existing = candidates.first {
                try requireReusable(
                    existing,
                    projectUUID: plan.projectResourceUUID,
                    resourceUUID: node.resourceUUID,
                    serviceName: service.identity.displayName,
                    providerID: plan.providerID,
                    providerGeneration: plan.providerGeneration,
                    mapping: item.mapping,
                    bindAddress: item.bindAddress,
                    desiredSHA256: desiredSHA256
                )
                guard existing.hostPort == hostPort else {
                    throw conflict(
                        "The confirmed plan changed an existing durable port assignment."
                    )
                }
                try requireNoRuntimeConflict(
                    endpoint,
                    inventory: inventory,
                    allowedResourceUUID: node.resourceUUID,
                    node: node,
                    plan: plan,
                    allowedFencingTokens: rollback == nil ? [group.fencingToken] : [group.fencingToken, inventory.containers.first(where: { $0.ownership?.resourceUUID == node.resourceUUID })?.ownership?.fencingToken ?? ""],
                    excludingResourceUUIDs: excluded
                )
                if existing.operationGroupID == group.id,
                   existing.fencingToken ==
                    group.fencingToken {
                    existingRecords.append(existing)
                } else {
                    let priorGroup = try store.operationGroups.load(id: existing.operationGroupID)
                    guard [.reserved, .active].contains(existing.lifecycleState),
                          let priorGroup,
                          priorGroup.groupKind == "lifecycle-v1",
                          priorGroup.projectID == plan.projectID,
                          priorGroup.fencingToken == existing.fencingToken,
                          priorGroup.lockOwner == nil,
                          priorGroup.lockExpiresAt == nil,
                          (priorGroup.status == .succeeded ||
                            (priorGroup.status == .failed && priorGroup.checkpoint == "compensated")),
                          inventory.isAuthoritative,
                          (targetContainers(node: node, inventory: inventory).isEmpty || rollback != nil),
                          try isAvailable(endpoint) else {
                        throw conflict(
                            "An earlier port reservation cannot be transferred while its exact runtime owner or operation is still present."
                        )
                    }
                    let renewed = replacing(
                        existing,
                        generation:
                            existing.generation + 1,
                        providerGeneration:
                            Int64(plan.providerGeneration),
                        fencingToken: group.fencingToken,
                        observedSHA256: nil,
                        lifecycleState: .reserved,
                        finalizerState: .active,
                        operationGroupID: group.id
                    )
                    changes.append((renewed, existing.expectedVersion))
                    existingRecords.append(renewed)
                }
            } else {
                let handedOff = (prior?.records ?? []).filter { Self.endpoint($0).conflicts(with: endpoint) }
                if !handedOff.isEmpty {
                    changes += releaseChanges(handedOff, group: group, inventory: inventory, plan: plan)
                }
                let ignored = releasingIDs.union(handedOff.map(\.id))
                let unavailable = try store.networkPorts.activeHostPorts(
                    bindAddress: item.bindAddress, protocolName: reservationProtocol(item.mapping.protocolName), excludingIDs: ignored
                )
                guard !unavailable.contains(hostPort),
                      !containsConflict(
                          endpoint,
                          in: occupiedPorts(in: inventory, excludingResourceUUIDs: excluded)
                      ),
                      try isAvailable(endpoint) else {
                    throw conflict(
                        "The confirmed host port became unavailable before runtime mutation."
                    )
                }
                newRecords.append(
                    NetworkPortReservationRecord(
                        id: reservationID(
                            operationGroupID: group.id,
                            nodeKey: node.key,
                            resourceUUID: node.resourceUUID,
                            mapping: item.mapping,
                            bindAddress: item.bindAddress
                        ),
                        projectUUID:
                            plan.projectResourceUUID,
                        resourceUUID: node.resourceUUID,
                        serviceName:
                            service.identity.displayName,
                        generation: 1,
                        providerID: plan.providerID.rawValue,
                        providerGeneration:
                            Int64(plan.providerGeneration),
                        fencingToken: group.fencingToken,
                        bindAddress: item.bindAddress,
                        hostPort: hostPort,
                        containerPort:
                            item.mapping.containerPort,
                        protocolName: reservationProtocol(
                            item.mapping.protocolName
                        ),
                        allocationKind: allocationKind(
                            item.mapping.allocation
                        ),
                        desiredSHA256: desiredSHA256,
                        observedSHA256: nil,
                        lifecycleState: .reserved,
                        finalizerState: .active,
                        operationGroupID: group.id,
                        createdAt: now,
                        updatedAt: now
                    )
                )
            }
            claimed.insert(endpoint)
        }

        changes += newRecords.sorted(by: recordOrder).map { ($0, nil) }
        _ = try store.networkPorts.saveAtomically(changes, requiring: plan.command == .update || plan.command == .rollback ? group : nil)
        return NetworkPortReservationBatch(
            records: (existingRecords + newRecords)
                .sorted(by: recordOrder)
        )
    }

    @discardableResult
    static func confirmActive(
        node: LifecyclePlanNode,
        plan: LifecyclePlan,
        group: OperationGroupRecord,
        inventory: RuntimeInventory,
        store: SQLiteStateStore
    ) throws -> NetworkPortReservationBatch {
        try requireAuthority(
            plan: plan,
            node: node,
            group: group,
            store: store
        )
        let rollback = try rollbackPortSource(node: node, plan: plan, group: group, store: store)
        guard node.action == .create || rollback != nil else {
            throw conflict("Port activation requires an exact create or authenticated rollback start.")
        }
        let prior = try quiescedUpdatePrior(node: node, plan: plan, group: group, inventory: inventory, store: store)
        let excluded = Set([prior?.node.resourceUUID].compactMap { $0 })
        var fences: Set<String> = [group.fencingToken]
        if let rollback {
            if let container = targetContainers(node: node, inventory: inventory).first,
               let fence = try verifiedPortCreationFence(node: rollback.node, plan: rollback.plan, container: container, store: store, activeGroup: group) { fences.insert(fence) }
        }
        let records = try exactResourceRecords(
            node: node,
            plan: plan,
            store: store
        )
        guard !records.isEmpty else {
            return NetworkPortReservationBatch(records: [])
        }
        guard records.allSatisfy({
            $0.lifecycleState == .reserved ||
                $0.lifecycleState == .active
        }) else {
            throw conflict(
                "Port activation found a non-activatable durable row."
            )
        }

        let containers = targetContainers(
            node: node,
            inventory: inventory
        )
        guard containers.count == 1,
              let container = containers.first,
              exactOwnership(
                  container.ownership,
                  node: node,
                  plan: plan,
                  allowedFencingTokens: fences
              ),
              exactObservedPorts(
                  records,
                  container: container
              ) else {
            throw conflict(
                "Port activation requires one exact owned container with the matching structured port observation."
            )
        }
        for record in records {
            let endpoint = endpoint(record)
            try requireNoRuntimeConflict(
                endpoint,
                inventory: inventory,
                allowedResourceUUID: node.resourceUUID,
                node: node,
                plan: plan,
                allowedFencingTokens: fences,
                excludingResourceUUIDs: excluded
            )
        }

        var activated: [NetworkPortReservationRecord] = []
        var changes: [(record: NetworkPortReservationRecord, expected: NetworkStateExpectedVersion?)] = []
        for record in records.sorted(by: recordOrder) {
            guard record.lifecycleState == .reserved else {
                activated.append(record)
                continue
            }
            let active = replacing(
                record,
                generation: record.generation,
                providerGeneration:
                    Int64(plan.providerGeneration),
                fencingToken: group.fencingToken,
                observedSHA256: inventory.semanticSHA256,
                lifecycleState: .active,
                finalizerState: .active,
                operationGroupID: group.id
            )
            changes.append((active, record.expectedVersion))
            activated.append(active)
        }
        _ = try store.networkPorts.saveAtomically(changes, requiring: plan.command == .update || plan.command == .rollback ? group : nil)
        return NetworkPortReservationBatch(records: activated)
    }

    @discardableResult
    static func beginRelease(
        node: LifecyclePlanNode,
        plan: LifecyclePlan,
        group: OperationGroupRecord,
        inventory: RuntimeInventory,
        priorFencingToken: String? = nil,
        store: SQLiteStateStore
    ) throws -> NetworkPortReservationBatch {
        try requireAuthority(
            plan: plan,
            node: node,
            group: group,
            store: store
        )
        guard node.action == .delete ||
                node.action == .retire else {
            throw conflict(
                "Port release requires the exact lifecycle delete or retire node."
            )
        }
        let records = try exactResourceRecords(
            node: node,
            plan: plan,
            store: store
        )
        guard !records.isEmpty else {
            return NetworkPortReservationBatch(records: [])
        }
        guard records.allSatisfy({
            $0.lifecycleState == .reserved ||
                $0.lifecycleState == .active ||
                $0.lifecycleState == .releasing
        }) else {
            throw conflict(
                "Port release found a faulted or ambiguous durable row."
            )
        }

        let containers = targetContainers(
            node: node,
            inventory: inventory
        )
        guard containers.count <= 1 else {
            throw conflict(
                "Port release found ambiguous runtime ownership."
            )
        }
        if let container = containers.first {
            var fences: Set<String> = [group.fencingToken]
            if let priorFencingToken {
                fences.insert(priorFencingToken)
            }
            if let fence = try verifiedCreationFence(
                node: node, plan: plan, container: container, store: store
            ) { fences.insert(fence) }
            guard exactOwnership(
                container.ownership,
                node: node,
                plan: plan,
                allowedFencingTokens: fences
            ),
            exactObservedPorts(records, container: container) else {
                throw conflict(
                    "Port release refused a non-exact runtime owner or port projection."
                )
            }
        }

        var releasing: [NetworkPortReservationRecord] = []
        for record in records.sorted(by: recordOrder) {
            guard record.lifecycleState != .releasing else {
                releasing.append(record)
                continue
            }
            let value = replacing(
                record,
                generation: record.generation + 1,
                providerGeneration:
                    Int64(plan.providerGeneration),
                fencingToken: group.fencingToken,
                observedSHA256: record.observedSHA256,
                lifecycleState: .releasing,
                finalizerState: .releasing,
                operationGroupID: group.id
            )
            releasing.append(
                try store.networkPorts.save(
                    value,
                    replacing: record.expectedVersion
                )
            )
        }
        return NetworkPortReservationBatch(records: releasing)
    }

    @discardableResult
    static func confirmReleased(
        node: LifecyclePlanNode,
        plan: LifecyclePlan,
        group: OperationGroupRecord,
        inventory: RuntimeInventory,
        store: SQLiteStateStore
    ) throws -> NetworkPortReservationBatch {
        try requireAuthority(
            plan: plan,
            node: node,
            group: group,
            store: store
        )
        guard node.action == .delete ||
                node.action == .retire else {
            throw conflict(
                "Port release confirmation requires the exact lifecycle delete or retire node."
            )
        }
        let records = try exactResourceRecords(
            node: node,
            plan: plan,
            store: store
        )
        guard !records.isEmpty else {
            return NetworkPortReservationBatch(records: [])
        }
        guard records.allSatisfy({
            $0.lifecycleState == .releasing
        }),
        targetContainers(
            node: node,
            inventory: inventory
        ).isEmpty else {
            throw conflict(
                "Port release requires verified structured absence of the exact runtime target."
            )
        }

        var released: [NetworkPortReservationRecord] = []
        for record in records.sorted(by: recordOrder) {
            let value = replacing(
                record,
                generation: record.generation,
                providerGeneration:
                    Int64(plan.providerGeneration),
                fencingToken: group.fencingToken,
                observedSHA256: inventory.semanticSHA256,
                lifecycleState: .released,
                finalizerState: .released,
                operationGroupID: group.id
            )
            released.append(
                try store.networkPorts.save(
                    value,
                    replacing: record.expectedVersion
                )
            )
        }
        return NetworkPortReservationBatch(records: released)
    }

    @discardableResult
    static func confirmCompensatedCreateReleased(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        inventory: RuntimeInventory,
        store: SQLiteStateStore
    ) throws -> NetworkPortReservationBatch {
        guard context.direction == .rollback,
              node.action == .create,
              node.compensation?.action == .delete || node.compensation?.action == .retire,
              let group = try store.operationGroups.load(id: context.groupID),
              group.operationID == context.operationID,
              group.fencingToken == context.fencingToken,
              let owner = context.leaseOwner,
              group.lockOwner == owner,
              let expiry = group.lockExpiresAt,
              ISO8601DateFormatter().date(from: expiry).map({ $0 > Date() }) == true else {
            throw conflict("Compensated create port cleanup requires its exact active finite saga lease.")
        }
        try requireAuthority(plan: context.plan, node: node, group: group, store: store)
        let records = try exactResourceRecords(node: node, plan: context.plan, store: store)
        guard !records.isEmpty else { return NetworkPortReservationBatch(records: []) }
        let expectedAuthority: RuntimeInventoryAuthority = context.plan.providerID == .appleContainerCLI
            ? .appleContainerCLIRuntimeList : .appleContainerizationRuntimeList
        guard inventory.isAuthoritative,
              inventory.authority == expectedAuthority,
              targetContainers(node: node, inventory: inventory).isEmpty,
              records.allSatisfy({
                  $0.operationGroupID == group.id && $0.fencingToken == group.fencingToken &&
                      ($0.lifecycleState == .reserved || $0.lifecycleState == .releasing) &&
                      $0.observedSHA256 == nil
              }) else {
            throw conflict("Compensated create port cleanup could not prove exact unactivated reservations and authoritative provider absence.")
        }
        func requireCleanupLease() throws {
            try requireAuthority(plan: context.plan, node: node, group: group, store: store)
            guard let current = try store.operationGroups.load(id: group.id),
                  current.lockOwner == owner, current.lockExpiresAt == expiry,
                  ISO8601DateFormatter().date(from: expiry).map({ $0 > Date() }) == true else {
                throw conflict("Compensated create port cleanup lost its exact saga lease.")
            }
        }
        var released: [NetworkPortReservationRecord] = []
        for record in records {
            try requireCleanupLease()
            let releasing: NetworkPortReservationRecord
            if record.lifecycleState == .reserved {
                releasing = try store.networkPorts.save(replacing(
                    record, generation: record.generation + 1,
                    providerGeneration: Int64(context.plan.providerGeneration), fencingToken: group.fencingToken,
                    observedSHA256: nil, lifecycleState: .releasing, finalizerState: .releasing,
                    operationGroupID: group.id
                ), replacing: record.expectedVersion)
            } else {
                releasing = record
            }
            try requireCleanupLease()
            released.append(try store.networkPorts.save(replacing(
                releasing, generation: releasing.generation,
                providerGeneration: Int64(context.plan.providerGeneration), fencingToken: group.fencingToken,
                observedSHA256: inventory.semanticSHA256, lifecycleState: .released, finalizerState: .released,
                operationGroupID: group.id
            ), replacing: releasing.expectedVersion))
        }
        return NetworkPortReservationBatch(records: released)
    }

    private struct UpdatePortPrior {
        let node: LifecyclePlanNode
        let plan: LifecyclePlan
        let group: OperationGroupRecord
        let records: [NetworkPortReservationRecord]
    }

    private static func depends(_ node: LifecyclePlanNode, on key: String, in plan: LifecyclePlan) -> Bool {
        var pending = node.dependencies
        var seen: Set<String> = []
        while let dependency = pending.popLast() {
            if dependency == key { return true }
            if seen.insert(dependency).inserted,
               let next = plan.nodes.first(where: { $0.key == dependency }) {
                pending += next.dependencies
            }
        }
        return false
    }

    private static func requireUpdatePortLease(_ group: OperationGroupRecord, plan: LifecyclePlan, store: SQLiteStateStore) throws {
        guard let persisted = try store.operationGroups.load(id: group.id),
              persisted == group, group.status == .active,
              let owner = group.lockOwner, !owner.isEmpty,
              let expiry = group.lockExpiresAt,
              ISO8601DateFormatter().date(from: expiry).map({ $0 > Date() }) == true,
              try LifecyclePersistedIntentCodec.decode(group.intentJSONRedacted).planSHA256 == plan.planSHA256 else {
            throw conflict("Update port handoff requires its exact persisted plan and active finite saga lease.")
        }
    }

    private static func rollbackPortSource(
        node: LifecyclePlanNode, plan: LifecyclePlan, group: OperationGroupRecord, store: SQLiteStateStore
    ) throws -> UpdatePortPrior? {
        guard node.action == .start else { return nil }
        let sourcePlan: LifecyclePlan
        let sourceGroup: OperationGroupRecord
        let sourceNode: LifecyclePlanNode
        if plan.command == .update,
           let stop = plan.nodes.first(where: {
               $0.key == node.key && $0.action == .stop && $0.compensation?.action == .start &&
                   $0.resourceUUID == node.resourceUUID && $0.resourceIdentifier == node.resourceIdentifier &&
                   $0.resourceGeneration == node.resourceGeneration
           }) {
            sourcePlan = plan; sourceGroup = group; sourceNode = stop
        } else if plan.command == .rollback,
                  let source = node.preconditions.first(where: { $0.kind == "rollback-source-group" }),
                  let prior = try store.operationGroups.load(id: source.subject), prior.planHash == source.expectedValue,
                  let key = node.postconditions.first(where: { $0.kind == "rollback-effect-verified" && $0.expectedValue == "true" })?.subject {
            sourcePlan = try LifecyclePersistedIntentCodec.decode(prior.intentJSONRedacted)
            guard sourcePlan.planSHA256 == prior.planHash, sourcePlan.command == .update,
                  sourcePlan.projectResourceUUID == plan.projectResourceUUID,
                  sourcePlan.projectGeneration == plan.projectGeneration,
                  sourcePlan.providerID == plan.providerID, sourcePlan.providerGeneration == plan.providerGeneration,
                  let stop = sourcePlan.nodes.first(where: {
                      $0.key == key && $0.action == .stop && $0.compensation?.action == .start &&
                          $0.resourceUUID == node.resourceUUID && $0.resourceIdentifier == node.resourceIdentifier &&
                          $0.resourceGeneration == node.resourceGeneration
                  }) else { throw conflict("Rollback port reacquisition lost its exact update source.") }
            sourceGroup = prior; sourceNode = stop
        } else { return nil }
        try requireUpdatePortLease(group, plan: plan, store: store)
        let step = try store.operationGroupSteps.load(groupID: sourceGroup.id).last {
            $0.direction == .forward && $0.stepKey == sourceNode.key
        }
        guard step?.status == .succeeded || (step?.status == .started && node.preconditions.contains {
            $0.kind == "rollback-source-effect-reobserved" && $0.subject == sourceNode.key && $0.expectedValue == sourceGroup.planHash
        }) else { throw conflict("Rollback port reacquisition lacks its verified quiesce effect.") }
        return UpdatePortPrior(node: sourceNode, plan: sourcePlan, group: sourceGroup, records: [])
    }

    private static func quiescedUpdatePrior(
        node: LifecyclePlanNode, plan: LifecyclePlan, group: OperationGroupRecord,
        inventory: RuntimeInventory, store: SQLiteStateStore
    ) throws -> UpdatePortPrior? {
        guard plan.command == .update, node.action == .create else { return nil }
        let desired = try LifecycleRevisionCodec.decodeRedactedDesiredJSON(node.desiredSpecificationJSONRedacted)
        let stops = try plan.nodes.filter { prior in
            guard prior.action == .stop, prior.compensation?.action == .start,
                  prior.resourceUUID != node.resourceUUID, depends(node, on: prior.key, in: plan) else { return false }
            return try LifecycleRevisionCodec.decodeRedactedDesiredJSON(prior.desiredSpecificationJSONRedacted).identity == desired.identity
        }
        guard stops.count <= 1 else { throw conflict("Update port handoff found ambiguous predecessors.") }
        guard let prior = stops.first else { return nil }
        try requireUpdatePortLease(group, plan: plan, store: store)
        guard try store.operationGroupSteps.load(groupID: group.id).last(where: {
            $0.direction == .forward && $0.stepKey == prior.key
        })?.status == .succeeded else { throw conflict("Update port handoff requires the verified quiesce dependency.") }
        try requireStoppedPortOwner(node: prior, plan: plan, group: group, inventory: inventory, store: store)
        let records = try store.networkPorts.loadProject(projectUUID: plan.projectResourceUUID, includeReleased: true).filter {
            $0.resourceUUID == prior.resourceUUID && ($0.lifecycleState != .released || $0.operationGroupID == group.id)
        }
        let previous = try LifecycleRevisionCodec.decodeRedactedDesiredJSON(prior.desiredSpecificationJSONRedacted)
        guard records.count == previous.ports.count else {
            throw conflict("Update port handoff lost an exact predecessor reservation.")
        }
        for record in records {
            guard let mapping = previous.ports.first(where: {
                $0.containerPort == record.containerPort && reservationProtocol($0.protocolName) == record.protocolName &&
                    NetworkPortEndpoint(bindAddress: $0.bindAddress, hostPort: $0.hostPort ?? 0, protocolName: $0.protocolName) == endpoint(record)
            }) else { throw conflict("Update port handoff found a changed predecessor reservation.") }
            try requireReusable(record, projectUUID: plan.projectResourceUUID, resourceUUID: prior.resourceUUID,
                serviceName: previous.identity.displayName, providerID: plan.providerID,
                providerGeneration: plan.providerGeneration, mapping: mapping, bindAddress: record.bindAddress,
                desiredSHA256: desiredDigest(projectUUID: plan.projectResourceUUID, resourceUUID: prior.resourceUUID,
                    serviceName: previous.identity.displayName, providerID: plan.providerID,
                    providerGeneration: plan.providerGeneration, mapping: mapping, bindAddress: record.bindAddress),
                allowReleasedForUpdate: record.lifecycleState == .released)
        }
        guard records.allSatisfy({
            $0.projectUUID == plan.projectResourceUUID && $0.providerID == plan.providerID.rawValue &&
                $0.providerGeneration == plan.providerGeneration &&
                ($0.lifecycleState == .active || $0.lifecycleState == .reserved ||
                    ($0.lifecycleState == .released && $0.operationGroupID == group.id && $0.fencingToken == group.fencingToken))
        }) else { throw conflict("Update port handoff found stale or non-transferable prior reservations.") }
        for record in records where record.operationGroupID != group.id {
            guard let owner = try store.operationGroups.load(id: record.operationGroupID),
                  owner.groupKind == "lifecycle-v1", owner.projectID == plan.projectID,
                  owner.fencingToken == record.fencingToken, owner.lockOwner == nil, owner.lockExpiresAt == nil,
                  owner.status == .succeeded || (owner.status == .failed && owner.checkpoint == "compensated") else {
                throw conflict("Update port handoff refused a predecessor reservation with live or unrelated authority.")
            }
            let original = try LifecyclePersistedIntentCodec.decode(owner.intentJSONRedacted)
            guard original.planSHA256 == owner.planHash, original.projectResourceUUID == plan.projectResourceUUID,
                  original.projectGeneration == plan.projectGeneration, original.providerID == plan.providerID,
                  original.providerGeneration == plan.providerGeneration,
                  original.nodes.contains(where: {
                      $0.resourceUUID == prior.resourceUUID && $0.resourceIdentifier == prior.resourceIdentifier &&
                          $0.resourceGeneration == prior.resourceGeneration
                  }) else { throw conflict("Update port handoff lost the predecessor reservation's persisted lineage.") }
        }
        guard records.filter({ $0.operationGroupID == group.id }).allSatisfy({ $0.fencingToken == group.fencingToken }) else {
            throw conflict("Update port handoff lost the current reservation fence.")
        }
        return UpdatePortPrior(node: prior, plan: plan, group: group, records: records)
    }

    private static func requireStoppedPortOwner(
        node: LifecyclePlanNode, plan: LifecyclePlan, group: OperationGroupRecord, inventory: RuntimeInventory, store: SQLiteStateStore
    ) throws {
        let expected: RuntimeInventoryAuthority = plan.providerID == .appleContainerCLI
            ? .appleContainerCLIRuntimeList : .appleContainerizationRuntimeList
        let containers = targetContainers(node: node, inventory: inventory)
        guard inventory.authority == expected, containers.count == 1, let container = containers.first,
              [.created, .stopped, .exited].contains(container.lifecycle),
              let fence = try verifiedPortCreationFence(node: node, plan: plan, container: container, store: store, activeGroup: group),
              try (container.lifecycle != .created || verifiedInversePortCreation(node: node, plan: plan, group: group, store: store)),
              exactOwnership(container.ownership, node: node, plan: plan, allowedFencingTokens: [fence]) else {
            throw conflict("Update port handoff requires one authoritative exact stopped predecessor.")
        }
        let desired = try LifecycleRevisionCodec.decodeRedactedDesiredJSON(node.desiredSpecificationJSONRedacted)
        let expectedPorts = desired.ports.compactMap { mapping in mapping.hostPort.map {
            NetworkPortEndpoint(bindAddress: mapping.bindAddress, hostPort: $0, protocolName: mapping.protocolName)
        } }
        let observed = container.ports.compactMap { port in port.hostPort.map {
            NetworkPortEndpoint(bindAddress: port.hostAddress, hostPort: $0, protocolName: runtimeProtocol(port.protocolName))
        } }
        guard expectedPorts.count == observed.count, Set(expectedPorts) == Set(observed) else {
            throw conflict("Update port handoff refused a changed predecessor port projection.")
        }
    }

    private static func verifiedInversePortCreation(
        node: LifecyclePlanNode, plan: LifecyclePlan, group: OperationGroupRecord, store: SQLiteStateStore
    ) throws -> Bool {
        let current = try LifecyclePersistedIntentCodec.decode(group.intentJSONRedacted)
        try requireUpdatePortLease(group, plan: current, store: store)
        guard current.projectResourceUUID == plan.projectResourceUUID, current.projectGeneration == plan.projectGeneration,
              current.providerID == plan.providerID, current.providerGeneration == plan.providerGeneration else { return false }
        let steps = try store.operationGroupSteps.load(groupID: group.id)
        for creation in current.nodes where creation.resourceUUID == node.resourceUUID &&
            creation.resourceIdentifier == node.resourceIdentifier && creation.resourceGeneration == node.resourceGeneration {
            let direction: OperationGroupStepDirection
            if current.command == .update, creation.action == .retire, creation.compensation?.action == .create {
                direction = .rollback
            } else if current.command == .rollback, creation.action == .create,
                      let source = creation.preconditions.first(where: { $0.kind == "rollback-source-group" }),
                      let owner = try store.operationGroups.load(id: source.subject), owner.planHash == source.expectedValue,
                      let sourceKey = creation.postconditions.first(where: { $0.kind == "rollback-effect-verified" && $0.expectedValue == "true" })?.subject {
                let original = try LifecyclePersistedIntentCodec.decode(owner.intentJSONRedacted)
                guard original.command == .update, original.planSHA256 == owner.planHash,
                      original.projectResourceUUID == plan.projectResourceUUID, original.projectGeneration == plan.projectGeneration,
                      original.providerID == plan.providerID, original.providerGeneration == plan.providerGeneration,
                      original.nodes.contains(where: {
                          $0.key == sourceKey && $0.action == .retire && $0.compensation?.action == .create &&
                              $0.resourceUUID == node.resourceUUID && $0.resourceIdentifier == node.resourceIdentifier &&
                              $0.resourceGeneration == node.resourceGeneration
                      }) else { return false }
                direction = .forward
            } else { continue }
            guard let step = steps.last(where: { $0.stepKey == creation.key && $0.direction == direction }),
                  step.status == .succeeded, step.plannedActionType == "create",
                  step.resourceIdentifier == creation.resourceIdentifier, step.serviceName == creation.serviceName,
                  step.stepIdempotencyKey.hasPrefix(creation.idempotencyKey + ":" + direction.rawValue + ":") else { continue }
            let restored = try LifecycleRevisionCodec.decodeRedactedDesiredJSON(creation.desiredSpecificationJSONRedacted)
            let previous = try LifecycleRevisionCodec.decodeRedactedDesiredJSON(node.desiredSpecificationJSONRedacted)
            guard restored.identity == previous.identity, restored.ports == previous.ports else { return false }
            return true
        }
        return false
    }

    private static func verifiedPortCreationFence(
        node: LifecyclePlanNode, plan: LifecyclePlan, container: RuntimeInventoryContainer, store: SQLiteStateStore,
        activeGroup: OperationGroupRecord? = nil
    ) throws -> String? {
        guard let observed = container.ownership else { return nil }
        if let activeGroup, activeGroup.fencingToken == observed.fencingToken,
           try verifiedInversePortCreation(node: node, plan: plan, group: activeGroup, store: store) {
            return observed.fencingToken
        }
        var verified: String?
        try store.operationGroups.visitProjectLifecycleHistory(projectID: plan.projectID) { origin in
            guard origin.status == .succeeded, origin.fencingToken == observed.fencingToken else { return }
            let source = try LifecyclePersistedIntentCodec.decode(origin.intentJSONRedacted)
            guard source.planSHA256 == origin.planHash, source.projectResourceUUID == plan.projectResourceUUID,
                  source.projectGeneration == plan.projectGeneration, source.providerID == plan.providerID,
                  source.providerGeneration == plan.providerGeneration,
                  source.nodes.contains(where: {
                      $0.action == .create && $0.resourceUUID == node.resourceUUID &&
                          $0.resourceIdentifier == node.resourceIdentifier && $0.resourceGeneration == node.resourceGeneration
                  }) else { return }
            verified = observed.fencingToken
        }
        return verified
    }

    private static func releaseChanges(
        _ records: [NetworkPortReservationRecord], group: OperationGroupRecord, inventory: RuntimeInventory, plan: LifecyclePlan
    ) -> [(record: NetworkPortReservationRecord, expected: NetworkStateExpectedVersion?)] {
        records.filter { $0.lifecycleState != .released }.flatMap { record in
            let releasing = replacing(record, generation: record.generation + 1,
                providerGeneration: Int64(plan.providerGeneration), fencingToken: group.fencingToken,
                observedSHA256: record.observedSHA256, lifecycleState: .releasing, finalizerState: .releasing,
                operationGroupID: group.id)
            let released = replacing(releasing, generation: releasing.generation,
                providerGeneration: Int64(plan.providerGeneration), fencingToken: group.fencingToken,
                observedSHA256: inventory.semanticSHA256, lifecycleState: .released, finalizerState: .released,
                operationGroupID: group.id)
            return [(releasing, record.expectedVersion), (released, releasing.expectedVersion)]
        }
    }

    static func requiresRollbackPortReservation(
        node: LifecyclePlanNode, plan: LifecyclePlan, group: OperationGroupRecord, store: SQLiteStateStore
    ) throws -> Bool {
        try rollbackPortSource(node: node, plan: plan, group: group, store: store) != nil
    }

    private static func planningWorkItems(
        desiredState: DesiredRuntimeState,
        resourceUUIDs: [Int: String]
    ) throws -> [NetworkPortWorkItem] {
        var items: [NetworkPortWorkItem] = []
        var logicalKeys: Set<String> = []
        for (serviceIndex, service) in
            desiredState.services.enumerated()
        {
            guard let resourceUUID =
                    resourceUUIDs[serviceIndex] else {
                throw conflict(
                    "Port planning could not resolve one service resource UUID."
                )
            }
            for (portIndex, mapping) in
                service.ports.enumerated()
            {
                let bindAddress = try canonicalBindAddress(
                    mapping.bindAddress
                )
                try validate(mapping)
                let logicalKey = [
                    resourceUUID,
                    String(mapping.containerPort),
                    mapping.protocolName.rawValue,
                    bindAddress,
                ].joined(separator: "\u{1f}")
                guard logicalKeys.insert(logicalKey).inserted
                else {
                    throw conflict(
                        "A resource cannot declare multiple host mappings for the same container port and protocol."
                    )
                }
                items.append(
                    NetworkPortWorkItem(
                        serviceIndex: serviceIndex,
                        portIndex: portIndex,
                        resourceUUID: resourceUUID,
                        service: service,
                        mapping: mapping,
                        bindAddress: bindAddress
                    )
                )
            }
        }
        return items.sorted {
            $0.orderingKey < $1.orderingKey
        }
    }

    private static func validate(
        _ mapping: RuntimePortMapping
    ) throws {
        guard (1...65_535).contains(mapping.containerPort)
        else {
            throw conflict(
                "Container ports must be between 1 and 65535."
            )
        }
        switch mapping.allocation {
        case .fixed:
            guard let hostPort = mapping.hostPort,
                  (1_024...65_535).contains(hostPort) else {
                throw conflict(
                    "Fixed host ports must be between 1024 and 65535."
                )
            }
        case .dynamic:
            guard mapping.hostPort == nil ||
                    NetworkPortReservationRepository.dynamicRange
                        .contains(mapping.hostPort!) else {
                throw conflict(
                    "Dynamic host ports must be unresolved or inside 49152...65535."
                )
            }
        }
    }

    private static func canonicalBindAddress(
        _ value: String?
    ) throws -> String {
        let normalized = NetworkPortEndpoint(
            bindAddress: value,
            hostPort: 1_024,
            protocolName: .tcp
        ).bindAddress
        var ipv4 = in_addr()
        if normalized.withCString({
            inet_pton(AF_INET, $0, &ipv4)
        }) == 1 {
            return try renderedIPv4(&ipv4)
        }
        var ipv6 = in6_addr()
        if normalized.withCString({
            inet_pton(AF_INET6, $0, &ipv6)
        }) == 1 {
            return try renderedIPv6(&ipv6)
        }
        throw conflict(
            "Port reservation requires an exact IPv4 or IPv6 bind address."
        )
    }

    private static func renderedIPv4(
        _ address: inout in_addr
    ) throws -> String {
        var buffer = [CChar](
            repeating: 0,
            count: Int(INET_ADDRSTRLEN)
        )
        guard inet_ntop(
            AF_INET,
            &address,
            &buffer,
            socklen_t(buffer.count)
        ) != nil else {
            throw conflict(
                "Port reservation could not canonicalize the bind address."
            )
        }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )
    }

    private static func renderedIPv6(
        _ address: inout in6_addr
    ) throws -> String {
        var buffer = [CChar](
            repeating: 0,
            count: Int(INET6_ADDRSTRLEN)
        )
        guard inet_ntop(
            AF_INET6,
            &address,
            &buffer,
            socklen_t(buffer.count)
        ) != nil else {
            throw conflict(
                "Port reservation could not canonicalize the bind address."
            )
        }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )
    }

    private static func selectNewHostPort(
        mapping: RuntimePortMapping,
        bindAddress: String,
        stateRecords: [NetworkPortReservationRecord],
        occupiedPorts: Set<NetworkPortEndpoint>,
        claimedPorts: Set<NetworkPortEndpoint>,
        store: SQLiteStateStore,
        isAvailable: AvailabilityProbe,
        isExposureAvailable: ExposureAvailabilityProbe?
    ) throws -> Int {
        switch mapping.allocation {
        case .fixed:
            let hostPort = mapping.hostPort!
            let endpoint = NetworkPortEndpoint(
                bindAddress: bindAddress,
                hostPort: hostPort,
                protocolName: mapping.protocolName
            )
            let persistedUnavailable = try store.networkPorts
                .activeHostPorts(
                    bindAddress: bindAddress,
                    protocolName: reservationProtocol(
                        mapping.protocolName
                    )
                )
            let available = try availability(
                endpoint,
                policy: mapping.exposurePolicy,
                isAvailable: isAvailable,
                isExposureAvailable: isExposureAvailable
            )
            guard !persistedUnavailable.contains(hostPort),
                  !stateRecords.contains(where: {
                endpoint.conflicts(
                    with: NetworkPortLifecycleCoordinator
                        .endpoint($0)
                )
            }),
            !containsConflict(endpoint, in: occupiedPorts),
            !containsConflict(endpoint, in: claimedPorts),
            available else {
                throw conflict(
                    "A fixed host port conflicts with durable or structured runtime state."
                )
            }
            return hostPort

        case .dynamic:
            let persistedUnavailable = try store.networkPorts
                .activeHostPorts(
                    bindAddress: bindAddress,
                    protocolName: reservationProtocol(
                        mapping.protocolName
                    )
                )
            var selected: Int?
            for hostPort in
                NetworkPortReservationRepository.dynamicRange
            {
                let endpoint = NetworkPortEndpoint(
                    bindAddress: bindAddress,
                    hostPort: hostPort,
                    protocolName: mapping.protocolName
                )
                if persistedUnavailable.contains(hostPort) ||
                    containsConflict(endpoint, in: occupiedPorts) ||
                    containsConflict(endpoint, in: claimedPorts) {
                    continue
                }
                if try !availability(
                    endpoint,
                    policy: mapping.exposurePolicy,
                    isAvailable: isAvailable,
                    isExposureAvailable: isExposureAvailable
                ) {
                    continue
                }
                selected = hostPort
                break
            }
            guard let selected else {
                throw conflict(
                    "No dynamic localhost port is available in 49152...65535."
                )
            }
            if let alreadyResolved = mapping.hostPort,
               alreadyResolved != selected {
                throw conflict(
                    "A concrete dynamic port does not match deterministic lowest-free resolution."
                )
            }
            return selected
        }
    }

    private static func availability(
        _ endpoint: NetworkPortEndpoint,
        policy: HostwrightPortExposurePolicy,
        isAvailable: AvailabilityProbe,
        isExposureAvailable: ExposureAvailabilityProbe?
    ) throws -> Bool {
        if policy.scope == .localhost {
            return try isAvailable(endpoint)
        }
        guard let isExposureAvailable else { return false }
        return try isExposureAvailable(endpoint, policy)
    }

    private static func logicalMatch(
        _ record: NetworkPortReservationRecord,
        resourceUUID: String,
        mapping: RuntimePortMapping,
        bindAddress: String
    ) -> Bool {
        record.resourceUUID == resourceUUID &&
            record.containerPort == mapping.containerPort &&
            record.protocolName ==
                reservationProtocol(mapping.protocolName) &&
            record.bindAddress == bindAddress
    }

    private static func requireReusable(
        _ record: NetworkPortReservationRecord,
        projectUUID: String,
        resourceUUID: String,
        serviceName: String,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        mapping: RuntimePortMapping,
        bindAddress: String,
        desiredSHA256: String,
        allowReleasingForRemoval: Bool = false,
        allowReleasedForUpdate: Bool = false
    ) throws {
        guard record.projectUUID == projectUUID,
              record.resourceUUID == resourceUUID,
              record.serviceName == serviceName,
              record.providerID == providerID.rawValue,
              record.providerGeneration ==
                Int64(providerGeneration),
              record.bindAddress == bindAddress,
              record.containerPort == mapping.containerPort,
              record.protocolName ==
                reservationProtocol(mapping.protocolName),
              record.allocationKind ==
                allocationKind(mapping.allocation),
              record.desiredSHA256 == desiredSHA256,
              record.lifecycleState == .reserved ||
                record.lifecycleState == .active ||
                (allowReleasingForRemoval && record.lifecycleState == .releasing) ||
                (allowReleasedForUpdate && record.lifecycleState == .released),
              mapping.allocation == .dynamic ||
                record.hostPort == mapping.hostPort else {
            throw conflict(
                "A durable port row does not match the exact project, provider, service, or desired mapping."
            )
        }
    }

    private static func exactResourceRecords(
        node: LifecyclePlanNode,
        plan: LifecyclePlan,
        store: SQLiteStateStore
    ) throws -> [NetworkPortReservationRecord] {
        let records = try store.networkPorts.loadProject(
            projectUUID: plan.projectResourceUUID
        ).filter {
            $0.resourceUUID == node.resourceUUID
        }
        var keys: Set<String> = []
        for record in records {
            let key = [
                String(record.containerPort),
                record.protocolName.rawValue,
                try canonicalBindAddress(record.bindAddress),
            ].joined(separator: "\u{1f}")
            guard record.projectUUID ==
                    plan.projectResourceUUID,
                  record.providerID ==
                    plan.providerID.rawValue,
                  record.providerGeneration ==
                    Int64(plan.providerGeneration),
                  (record.serviceName == node.serviceName || record.serviceName == plan.projectName + "/" + (node.serviceName ?? "")),
                  keys.insert(key).inserted else {
                throw conflict(
                    "Port lifecycle found an unmanaged or ambiguous durable row."
                )
            }
        }
        return records.sorted(by: recordOrder)
    }

    private static func requireAuthority(
        plan: LifecyclePlan,
        node: LifecyclePlanNode,
        group: OperationGroupRecord,
        store: SQLiteStateStore
    ) throws {
        let authorizedNode = plan.nodes.first {
            $0.key == node.key &&
                $0.serviceName == node.serviceName &&
                $0.resourceIdentifier ==
                    node.resourceIdentifier &&
                $0.resourceUUID == node.resourceUUID &&
                $0.resourceGeneration ==
                    node.resourceGeneration &&
                $0.fencingToken == node.fencingToken &&
                ($0.action == node.action ||
                    $0.compensation?.action == node.action)
        }
        let persisted = try store.operationGroups.load(
            id: group.id
        )
        let project = try store.desiredStates.loadProject(
            id: plan.projectID
        )
        guard authorizedNode != nil,
              group.groupKind == "lifecycle-v1",
              group.projectID == plan.projectID,
              group.status == .active,
              group.planHash == plan.planSHA256,
              let persisted,
              persisted.status == .active,
              persisted.id == group.id,
              persisted.fencingToken ==
                group.fencingToken,
              persisted.projectID == plan.projectID,
              persisted.groupKind == "lifecycle-v1",
              persisted.planHash == plan.planSHA256,
              persisted.groupIdempotencyKey == group.groupIdempotencyKey,
              persisted.operationID == group.operationID,
              project.resourceUUID ==
                plan.projectResourceUUID,
              project.providerGeneration ==
                plan.providerGeneration,
              project.mutationProvider.flatMap(
                  RuntimeProviderBinding.stableID(for:)
              ) == plan.providerID else {
            throw conflict(
                "Port lifecycle lost the exact project, provider, plan, operation-group, or fencing authority."
            )
        }
    }

    private static func targetContainers(
        node: LifecyclePlanNode,
        inventory: RuntimeInventory
    ) -> [RuntimeInventoryContainer] {
        inventory.containers.filter {
            $0.ownership?.resourceUUID == node.resourceUUID ||
                (node.resourceIdentifier != nil &&
                    ($0.name == node.resourceIdentifier ||
                        $0.runtimeID ==
                            node.resourceIdentifier))
        }
    }

    private static func verifiedCreationFence(
        node: LifecyclePlanNode, plan: LifecyclePlan,
        container: RuntimeInventoryContainer, store: SQLiteStateStore
    ) throws -> String? {
        guard let observed = container.ownership else { return nil }
        let workloadID = UUID(uuidString: HostwrightResourceUUID.legacy(
            kind: "local-scheduler-workload", identifier: "\(node.resourceUUID):\(node.resourceGeneration)"
        ))!
        var verified: String?
        var checkedPlans = Set<String>()
        try store.schedulerAdmissions.visitReservationHistory(
            projectUUID: plan.projectResourceUUID, workloadID: workloadID
        ) { reservation in
            guard let binding = reservation.runtimeOwnership,
                  [.committed, .released].contains(reservation.status),
                  binding.lifecycleWorkloadID == reservation.workloadID,
                  binding.resourceUUID == node.resourceUUID,
                  binding.resourceIdentifier == node.resourceIdentifier,
                  binding.resourceGeneration == Int64(node.resourceGeneration),
                  binding.projectUUID == plan.projectResourceUUID,
                  binding.projectGeneration == Int64(plan.projectGeneration),
                  binding.providerID == plan.providerID,
                  binding.providerGeneration == Int64(plan.providerGeneration),
                  binding.fencingToken == observed.fencingToken else { return true }
            if checkedPlans.count >= 256 { checkedPlans.removeAll(keepingCapacity: true) }
            guard checkedPlans.insert(reservation.lifecyclePlanDigest).inserted else { return true }
            try store.operationGroups.visitProjectLifecycleHistory(
                projectID: plan.projectID, planHash: reservation.lifecyclePlanDigest
            ) { group in
                let origin = try LifecyclePersistedIntentCodec.decode(group.intentJSONRedacted)
                guard origin.planSHA256 == group.planHash else {
                    throw conflict("Port release found invalid creation lineage.")
                }
                if group.status == .succeeded && group.fencingToken == binding.fencingToken &&
                    origin.projectResourceUUID == plan.projectResourceUUID &&
                    origin.projectGeneration == plan.projectGeneration &&
                    origin.providerID == plan.providerID && origin.providerGeneration == plan.providerGeneration &&
                    origin.nodes.contains(where: {
                        $0.action == .create && $0.resourceUUID == node.resourceUUID &&
                            $0.resourceIdentifier == node.resourceIdentifier &&
                            $0.resourceGeneration == node.resourceGeneration &&
                            ($0.serviceName == binding.serviceName || $0.serviceName == RuntimeServiceIdentity(
                                projectName: binding.projectName, serviceName: binding.serviceName,
                                instanceName: binding.instanceName
                            ).displayName)
                    }) { verified = binding.fencingToken }
            }
            return true
        }
        return verified
    }

    private static func exactOwnership(
        _ ownership: RuntimeInventoryOwnershipEvidence?,
        node: LifecyclePlanNode,
        plan: LifecyclePlan,
        allowedFencingTokens: Set<String>
    ) -> Bool {
        guard let ownership else { return false }
        return ownership.resourceUUID == node.resourceUUID &&
            ownership.resourceGeneration ==
                node.resourceGeneration &&
            ownership.projectUUID ==
                plan.projectResourceUUID &&
            ownership.projectGeneration ==
                plan.projectGeneration &&
            ownership.providerID == plan.providerID &&
            ownership.providerGeneration ==
                plan.providerGeneration &&
            allowedFencingTokens.contains(
                ownership.fencingToken
            )
    }

    private static func exactObservedPorts(
        _ records: [NetworkPortReservationRecord],
        container: RuntimeInventoryContainer
    ) -> Bool {
        let observed = container.ports.compactMap {
            port -> NetworkPortEndpoint? in
            guard let hostPort = port.hostPort else {
                return nil
            }
            return NetworkPortEndpoint(
                bindAddress: port.hostAddress,
                hostPort: hostPort,
                protocolName:
                    runtimeProtocol(port.protocolName)
            )
        }
        let expected = records.map(endpoint)
        return observed.count == expected.count &&
            Set(observed).count == observed.count &&
            Set(expected) == Set(observed)
    }

    private static func requireNoRuntimeConflict(
        _ endpoint: NetworkPortEndpoint,
        inventory: RuntimeInventory,
        allowedResourceUUID: String,
        node: LifecyclePlanNode,
        plan: LifecyclePlan,
        allowedFencingTokens: Set<String>,
        excludingResourceUUIDs: Set<String> = []
    ) throws {
        let conflicts = inventory.containers.filter {
            container in
            !excludingResourceUUIDs.contains(container.ownership?.resourceUUID ?? "") && container.ports.contains {
                port in
                guard let hostPort = port.hostPort else {
                    return false
                }
                return endpoint.conflicts(
                    with: NetworkPortEndpoint(
                        bindAddress: port.hostAddress,
                        hostPort: hostPort,
                        protocolName:
                            runtimeProtocol(
                                port.protocolName
                            )
                    )
                )
            }
        }
        guard conflicts.isEmpty ||
                (conflicts.count == 1 &&
                    conflicts[0].ownership?.resourceUUID ==
                        allowedResourceUUID &&
                    exactOwnership(
                        conflicts[0].ownership,
                        node: node,
                        plan: plan,
                        allowedFencingTokens:
                            allowedFencingTokens
                    )) else {
            throw conflict(
                "A structured runtime observation found a conflicting unmanaged or ambiguously owned host port."
            )
        }
    }

    private static func desiredDigest(
        projectUUID: String,
        resourceUUID: String,
        serviceName: String,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        mapping: RuntimePortMapping,
        bindAddress: String
    ) throws -> String {
        try digest(
            NetworkPortDesiredIntent(
                schemaVersion: 1,
                projectUUID: projectUUID,
                resourceUUID: resourceUUID,
                serviceName: serviceName,
                providerID: providerID.rawValue,
                providerGeneration: providerGeneration,
                bindAddress: bindAddress,
                requestedHostPort:
                    mapping.allocation == .fixed
                        ? mapping.hostPort
                        : nil,
                containerPort: mapping.containerPort,
                protocolName:
                    mapping.protocolName.rawValue,
                allocationKind:
                    mapping.allocation.rawValue
            )
        )
    }

    private static func reservationID(
        operationGroupID: String,
        nodeKey: String,
        resourceUUID: String,
        mapping: RuntimePortMapping,
        bindAddress: String
    ) -> String {
        HostwrightResourceUUID.legacy(
            kind: "network-port-reservation",
            identifier: [
                operationGroupID,
                nodeKey,
                resourceUUID,
                String(mapping.containerPort),
                mapping.protocolName.rawValue,
                bindAddress,
            ].joined(separator: ":")
        )
    }

    private static func replacing(
        _ record: NetworkPortReservationRecord,
        generation: Int64,
        providerGeneration: Int64,
        fencingToken: String,
        observedSHA256: String?,
        lifecycleState: NetworkPortReservationLifecycle,
        finalizerState: NetworkStateFinalizer,
        operationGroupID: String
    ) -> NetworkPortReservationRecord {
        NetworkPortReservationRecord(
            id: record.id,
            projectUUID: record.projectUUID,
            resourceUUID: record.resourceUUID,
            serviceName: record.serviceName,
            generation: generation,
            providerID: record.providerID,
            providerGeneration: providerGeneration,
            fencingToken: fencingToken,
            bindAddress: record.bindAddress,
            hostPort: record.hostPort,
            containerPort: record.containerPort,
            protocolName: record.protocolName,
            allocationKind: record.allocationKind,
            desiredSHA256: record.desiredSHA256,
            observedSHA256: observedSHA256,
            lifecycleState: lifecycleState,
            finalizerState: finalizerState,
            operationGroupID: operationGroupID,
            createdAt: record.createdAt,
            updatedAt: hostwrightTimestamp()
        )
    }

    private static func replacingPorts(
        in service: DesiredRuntimeService,
        with ports: [RuntimePortMapping]
    ) -> DesiredRuntimeService {
        DesiredRuntimeService(
            identity: service.identity,
            logicalServiceName:
                service.logicalServiceName,
            replicaIndex: service.replicaIndex,
            image: service.image,
            imageLock: service.imageLock,
            platformOperatingSystem:
                service.platformOperatingSystem,
            platformArchitecture:
                service.platformArchitecture,
            cpuCount: service.cpuCount,
            memoryBytes: service.memoryBytes,
            userID: service.userID,
            groupID: service.groupID,
            workingDirectory: service.workingDirectory,
            entrypoint: service.entrypoint,
            command: service.command,
            initProcess: service.initProcess,
            dependencies: service.dependencies,
            environment: service.environment,
            labels: service.labels,
            ports: ports,
            publishedSockets: service.publishedSockets,
            hostAccess: service.hostAccess,
            networkPolicy: service.networkPolicy,
            networks: service.networks,
            mounts: service.mounts,
            healthCheck: service.healthCheck,
            probes: service.probes,
            restartPolicy: service.restartPolicy,
            updatePolicy: service.updatePolicy,
            hooks: service.hooks,
            rosetta: service.rosetta,
            virtualization: service.virtualization,
            readOnlyRootFilesystem:
                service.readOnlyRootFilesystem,
            sharedMemoryBytes: service.sharedMemoryBytes
        )
    }

    private static func endpoint(
        _ record: NetworkPortReservationRecord
    ) -> NetworkPortEndpoint {
        NetworkPortEndpoint(
            bindAddress: record.bindAddress,
            hostPort: record.hostPort,
            protocolName: runtimeProtocol(
                record.protocolName
            )
        )
    }

    private static func containsConflict(
        _ endpoint: NetworkPortEndpoint,
        in ports: Set<NetworkPortEndpoint>
    ) -> Bool {
        ports.contains {
            endpoint.conflicts(with: $0)
        }
    }

    private static func reservationProtocol(
        _ value: RuntimePortProtocol
    ) -> NetworkPortReservationProtocol {
        value == .tcp ? .tcp : .udp
    }

    private static func runtimeProtocol(
        _ value: NetworkPortReservationProtocol
    ) -> RuntimePortProtocol {
        value == .tcp ? .tcp : .udp
    }

    private static func runtimeProtocol(
        _ value: RuntimeInventoryPortProtocol
    ) -> RuntimePortProtocol {
        value == .tcp ? .tcp : .udp
    }

    private static func allocationKind(
        _ value: RuntimeHostPortAllocation
    ) -> NetworkPortAllocationKind {
        value == .fixed ? .fixed : .dynamic
    }

    private static func recordOrder(
        _ lhs: NetworkPortReservationRecord,
        _ rhs: NetworkPortReservationRecord
    ) -> Bool {
        (
            lhs.bindAddress,
            lhs.hostPort,
            lhs.protocolName.rawValue,
            lhs.containerPort,
            lhs.id
        ) < (
            rhs.bindAddress,
            rhs.hostPort,
            rhs.protocolName.rawValue,
            rhs.containerPort,
            rhs.id
        )
    }

    private static func digest<T: Encodable>(
        _ value: T
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return SHA256.hash(data: try encoder.encode(value))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func conflict(
        _ message: String
    ) -> HostwrightDiagnostic {
        HostwrightDiagnostic(
            code: .runtimeUnavailable,
            message: message
        )
    }
}
