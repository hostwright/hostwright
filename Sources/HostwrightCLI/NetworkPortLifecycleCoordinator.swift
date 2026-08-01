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
        in inventory: RuntimeInventory
    ) -> Set<NetworkPortEndpoint> {
        Set(
            inventory.containers.flatMap { container in
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
                    desiredSHA256: desiredSHA256
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
        guard node.action == .create,
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
                    allowedFencingTokens: [group.fencingToken]
                )
                if existing.operationGroupID == group.id,
                   existing.fencingToken ==
                    group.fencingToken {
                    existingRecords.append(existing)
                } else {
                    guard existing.lifecycleState == .active,
                          targetContainers(
                            node: node,
                            inventory: inventory
                          ).isEmpty else {
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
                    existingRecords.append(
                        try store.networkPorts.save(
                            renewed,
                            replacing:
                                existing.expectedVersion
                        )
                    )
                }
            } else {
                let unavailable = try store.networkPorts
                    .activeHostPorts(
                        bindAddress: item.bindAddress,
                        protocolName: reservationProtocol(
                            item.mapping.protocolName
                        )
                    )
                guard !unavailable.contains(hostPort),
                      !containsConflict(
                          endpoint,
                          in: occupiedPorts(in: inventory)
                      ),
                      try isAvailable(endpoint) else {
                    throw conflict(
                        "The confirmed host port became unavailable before runtime mutation."
                    )
                }
                newRecords.append(
                    NetworkPortReservationRecord(
                        id: reservationID(
                            planSHA256: plan.planSHA256,
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

        for record in newRecords.sorted(by: recordOrder) {
            _ = try store.networkPorts.save(record)
        }
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
        guard node.action == .create else {
            throw conflict(
                "Port activation requires the exact lifecycle create node."
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
                  allowedFencingTokens: [group.fencingToken]
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
                allowedFencingTokens: [group.fencingToken]
            )
        }

        var activated: [NetworkPortReservationRecord] = []
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
            activated.append(
                try store.networkPorts.save(
                    active,
                    replacing: record.expectedVersion
                )
            )
        }
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
        desiredSHA256: String
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
                record.lifecycleState == .active,
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
                  record.serviceName == node.serviceName,
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
              node.fencingToken == group.fencingToken,
              group.groupKind == "lifecycle-v1",
              group.projectID == plan.projectID,
              group.status == .active,
              group.planHash == plan.planSHA256,
              group.groupIdempotencyKey ==
                plan.planSHA256,
              let persisted,
              persisted.status == .active,
              persisted.id == group.id,
              persisted.fencingToken ==
                group.fencingToken,
              persisted.projectID == plan.projectID,
              persisted.groupKind == "lifecycle-v1",
              persisted.planHash == plan.planSHA256,
              persisted.groupIdempotencyKey ==
                plan.planSHA256,
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
        allowedFencingTokens: Set<String>
    ) throws {
        let conflicts = inventory.containers.filter {
            container in
            container.ports.contains {
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
        planSHA256: String,
        nodeKey: String,
        resourceUUID: String,
        mapping: RuntimePortMapping,
        bindAddress: String
    ) -> String {
        HostwrightResourceUUID.legacy(
            kind: "network-port-reservation",
            identifier: [
                planSHA256,
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
