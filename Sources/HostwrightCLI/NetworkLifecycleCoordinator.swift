import CryptoKit
import Foundation
import HostwrightCore
import HostwrightNetworking
import HostwrightRuntime
import HostwrightState

struct NetworkLifecycleReconciliationResult: Sendable {
    let newlyCreatedNetworkUUIDs: [String]
}

private struct NetworkLifecycleOperationIntent:
    Codable,
    Equatable,
    Sendable
{
    let schemaVersion: Int
    let action: String
    let projectUUID: String
    let networkUUID: String
    let runtimeName: String
    let providerID: String
    let providerGeneration: Int
    let capabilitySHA256: String
    let desiredSHA256: String
    let runtimeResourceGeneration: Int
}

private struct NetworkCreateGeneration: Equatable, Sendable {
    let state: Int64
    let runtime: Int
}

enum NetworkLifecycleCoordinator {
    static func reconcile(
        preparation: LifecycleCommandPreparation,
        planSHA256: String,
        store: SQLiteStateStore,
        environment: CLIEnvironment
    ) async throws -> NetworkLifecycleReconciliationResult {
        guard !preparation.desiredState.networks.isEmpty else {
            return NetworkLifecycleReconciliationResult(
                newlyCreatedNetworkUUIDs: []
            )
        }
        let provider = try environment.networkProviderForProvider(
            preparation.providerID
        )
        let adapter = try environment.runtimeAdapterForProvider(
            preparation.providerID
        )
        try await validateProvider(
            provider,
            adapter: adapter,
            preparation: preparation,
            requiredOperation: .create
        )

        var created: [String] = []
        for desired in preparation.desiredState.networks.sorted(
            by: { $0.identity.logicalName < $1.identity.logicalName }
        ) {
            let desiredSHA256 = try digest(desired.createRequest)
            if let existing = try store.networks.loadNetwork(
                id: desired.identity.resourceUUID
            ) {
                guard existing.projectUUID ==
                        preparation.projectResourceUUID,
                      existing.providerID ==
                        preparation.providerID.rawValue,
                      existing.providerGeneration ==
                        Int64(preparation.providerGeneration),
                      existing.name == desired.identity.logicalName,
                      existing.runtimeName ==
                        desired.identity.runtimeIdentifier,
                      existing.desiredSHA256 == desiredSHA256 else {
                    throw conflict(
                        "Persisted network identity or desired state conflicts with the confirmed lifecycle plan."
                    )
                }
                if existing.lifecycleState == .available,
                   existing.finalizerState == .active {
                    let inventory = try await adapter.inventory()
                    guard exactNetwork(
                        desired.identity,
                        in: inventory,
                        providerID: preparation.providerID,
                        providerGeneration:
                            preparation.providerGeneration,
                        projectGeneration:
                            preparation.projectGeneration,
                        resourceGeneration:
                            Int(existing.generation),
                        fencingToken: existing.fencingToken
                    ) != nil else {
                        throw conflict(
                            "An available network lost exact runtime ownership; recovery must not recreate or delete it implicitly."
                        )
                    }
                    continue
                }
                guard existing.lifecycleState == .creating,
                      existing.finalizerState == .pending else {
                    throw conflict(
                        "A prior network operation requires exact recovery before lifecycle mutation."
                    )
                }
                let recovered = try await resumeCreate(
                    desired: desired,
                    existing: existing,
                    preparation: preparation,
                    provider: provider,
                    adapter: adapter,
                    store: store
                )
                if recovered {
                    created.append(desired.identity.resourceUUID)
                }
                continue
            }

            let createGeneration = try createGeneration(
                desired: desired,
                preparation: preparation,
                store: store
            )
            let group = try acquireOperation(
                action: "create",
                desired: desired,
                desiredSHA256: desiredSHA256,
                runtimeResourceGeneration:
                    createGeneration.runtime,
                preparation: preparation,
                planSHA256: planSHA256,
                fencingToken: nil,
                store: store
            )
            let timestamp = hostwrightTimestamp()
            let authority = try await mutationAuthority(
                group: group,
                preparation: preparation,
                adapter: adapter
            )
            let creating = NetworkStateResourceRecord(
                id: desired.identity.resourceUUID,
                projectUUID: desired.identity.projectUUID,
                name: desired.identity.logicalName,
                runtimeName: desired.identity.runtimeIdentifier,
                generation: createGeneration.state,
                providerID: preparation.providerID.rawValue,
                providerGeneration:
                    Int64(preparation.providerGeneration),
                fencingToken: group.fencingToken,
                driver: stateDriver(desired.mode),
                requestedIPv4: stateAddress(desired.ipv4),
                requestedIPv6: stateAddress(desired.ipv6),
                observedIPv4: [],
                observedIPv6: [],
                desiredSHA256: desiredSHA256,
                observedSHA256: nil,
                lifecycleState: .creating,
                finalizerState: .pending,
                operationGroupID: group.id,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            try store.networks.saveNetwork(
                creating,
                authority: authority
            )
            do {
                try await createAndCommit(
                    desired: desired,
                    creating: creating,
                    group: group,
                    preparation: preparation,
                    provider: provider,
                    adapter: adapter,
                    store: store
                )
                created.append(desired.identity.resourceUUID)
            } catch {
                try await recoverCreateFailure(
                    desired: desired,
                    creating: creating,
                    group: group,
                    preparation: preparation,
                    adapter: adapter,
                    store: store,
                    originalError: error
                )
                if try store.networks.loadNetwork(
                    id: desired.identity.resourceUUID
                )?.lifecycleState == .available {
                    created.append(desired.identity.resourceUUID)
                }
            }
        }
        return NetworkLifecycleReconciliationResult(
            newlyCreatedNetworkUUIDs: created.sorted()
        )
    }

    static func removeNetworks(
        networkUUIDs: Set<String>?,
        preparation: LifecycleCommandPreparation,
        planSHA256: String,
        store: SQLiteStateStore,
        environment: CLIEnvironment
    ) async throws {
        let records = try store.networks.listNetworks(
            projectUUID: preparation.projectResourceUUID
        ).filter {
            networkUUIDs?.contains($0.id) ?? true
        }.sorted {
            if $0.name != $1.name { return $0.name > $1.name }
            return $0.id > $1.id
        }
        guard !records.isEmpty else { return }

        let provider = try environment.networkProviderForProvider(
            preparation.providerID
        )
        let adapter = try environment.runtimeAdapterForProvider(
            preparation.providerID
        )
        try await validateProvider(
            provider,
            adapter: adapter,
            preparation: preparation,
            requiredOperation: .delete
        )
        for record in records {
            try await removeNetwork(
                record,
                preparation: preparation,
                planSHA256: planSHA256,
                provider: provider,
                adapter: adapter,
                store: store
            )
        }
    }

    private static func resumeCreate(
        desired: DesiredRuntimeNetwork,
        existing: NetworkStateResourceRecord,
        preparation: LifecycleCommandPreparation,
        provider: any RuntimeNetworkProvider,
        adapter: any RuntimeAdapter,
        store: SQLiteStateStore
    ) async throws -> Bool {
        guard let storedGroup = try store.operationGroups.load(
            id: existing.operationGroupID
        ),
        storedGroup.projectID == preparation.projectID,
        storedGroup.fencingToken == existing.fencingToken else {
            throw conflict(
                "The interrupted network intent lost its exact operation group."
            )
        }
        let group: OperationGroupRecord
        switch storedGroup.status {
        case .active:
            group = storedGroup
        case .interrupted:
            group = try store.operationGroups.resumeInterrupted(
                groupID: storedGroup.id,
                expectedFencingToken: storedGroup.fencingToken,
                lockOwner: "hostwright-cli",
                lockExpiresAt: hostwrightTimestampAdding(
                    seconds: 86_400,
                    to: hostwrightTimestamp()
                ),
                updatedAt: hostwrightTimestamp()
            )
        case .succeeded, .failed:
            throw conflict(
                "A terminal network operation is missing authoritative committed state."
            )
        }

        let inventory = try await adapter.inventory()
        if exactNetwork(
            desired.identity,
            in: inventory,
            providerID: preparation.providerID,
            providerGeneration: preparation.providerGeneration,
            projectGeneration: preparation.projectGeneration,
            resourceGeneration: Int(existing.generation + 1),
            fencingToken: group.fencingToken
        ) != nil {
            try commitAvailable(
                desired: desired,
                creating: existing,
                group: group,
                inventory: inventory,
                preparation: preparation,
                adapter: adapter,
                store: store
            )
            return true
        }
        guard collision(
            desired.identity,
            in: inventory
        ) == nil else {
            let authority = try await mutationAuthority(
                group: group,
                preparation: preparation,
                adapter: adapter
            )
            _ = try store.networks.quarantineNetwork(
                id: existing.id,
                expected: version(existing),
                authority: authority,
                observedSHA256: inventory.semanticSHA256,
                updatedAt: hostwrightTimestamp()
            )
            try finish(
                group,
                status: .failed,
                checkpoint: "ownership-quarantined",
                store: store
            )
            throw conflict(
                "Network recovery found a conflicting runtime owner and quarantined the exact record."
            )
        }
        try await createAndCommit(
            desired: desired,
            creating: existing,
            group: group,
            preparation: preparation,
            provider: provider,
            adapter: adapter,
            store: store
        )
        return true
    }

    private static func createAndCommit(
        desired: DesiredRuntimeNetwork,
        creating: NetworkStateResourceRecord,
        group: OperationGroupRecord,
        preparation: LifecycleCommandPreparation,
        provider: any RuntimeNetworkProvider,
        adapter: any RuntimeAdapter,
        store: SQLiteStateStore
    ) async throws {
        try await validateProvider(
            provider,
            adapter: adapter,
            preparation: preparation,
            requiredOperation: .create
        )
        let before = try await adapter.inventory()
        guard collision(desired.identity, in: before) == nil else {
            throw conflict(
                "Network creation found a runtime name or UUID collision before mutation."
            )
        }
        let context = RuntimeMutationContext(
            providerID: preparation.providerID,
            capabilitySHA256: preparation.capabilitySHA256,
            operationID: group.operationID,
            resourceUUID: desired.identity.resourceUUID,
            resourceGeneration: Int(creating.generation + 1),
            projectResourceUUID:
                preparation.projectResourceUUID,
            projectGeneration: preparation.projectGeneration,
            providerGeneration: preparation.providerGeneration,
            fencingToken: group.fencingToken
        )
        _ = try await provider.networkCreate(
            desired.createRequest,
            context: context
        )
        let inventory = try await adapter.inventory()
        try commitAvailable(
            desired: desired,
            creating: creating,
            group: group,
            inventory: inventory,
            preparation: preparation,
            adapter: adapter,
            store: store
        )
    }

    private static func commitAvailable(
        desired: DesiredRuntimeNetwork,
        creating: NetworkStateResourceRecord,
        group: OperationGroupRecord,
        inventory: RuntimeInventory,
        preparation: LifecycleCommandPreparation,
        adapter: any RuntimeAdapter,
        store: SQLiteStateStore
    ) throws {
        guard let observed = exactNetwork(
            desired.identity,
            in: inventory,
            providerID: preparation.providerID,
            providerGeneration: preparation.providerGeneration,
            projectGeneration: preparation.projectGeneration,
            resourceGeneration: Int(creating.generation + 1),
            fencingToken: group.fencingToken
        ) else {
            throw conflict(
                "Network mutation was not verified through exact structured ownership observation."
            )
        }
        let addressReport = try verifiedAddressObservation(
            desired: desired,
            observed: observed,
            inventory: inventory
        )
        let observedSHA256 = try digest(observed)
        let authority = NetworkStateMutationAuthority(
            providerID: preparation.providerID.rawValue,
            providerGeneration:
                Int64(preparation.providerGeneration),
            operationGroupID: group.id,
            fencingToken: group.fencingToken,
            plannedCapabilitySHA256:
                preparation.capabilitySHA256,
            currentCapabilitySHA256:
                preparation.capabilitySHA256
        )
        let available = NetworkStateResourceRecord(
            id: creating.id,
            projectUUID: creating.projectUUID,
            name: creating.name,
            runtimeName: creating.runtimeName,
            generation: creating.generation + 1,
            providerID: creating.providerID,
            providerGeneration: creating.providerGeneration,
            fencingToken: group.fencingToken,
            driver: creating.driver,
            requestedIPv4: creating.requestedIPv4,
            requestedIPv6: creating.requestedIPv6,
            observedIPv4: observedAddressValues(
                addressReport.family(.ipv4)
            ),
            observedIPv6: observedAddressValues(
                addressReport.family(.ipv6)
            ),
            desiredSHA256: creating.desiredSHA256,
            observedSHA256: observedSHA256,
            lifecycleState: .available,
            finalizerState: .active,
            operationGroupID: group.id,
            createdAt: creating.createdAt,
            updatedAt: hostwrightTimestamp()
        )
        try store.networks.saveNetwork(
            available,
            replacing: version(creating),
            authority: authority
        )
        try checkpoint(
            group,
            name: "provider-observed",
            verification:
                #"{"networkUUID":"\#(creating.id)","observationSHA256":"\#(observedSHA256)"}"#,
            store: store
        )
        try finish(
            group,
            status: .succeeded,
            checkpoint: "state-committed",
            store: store
        )
        _ = adapter
    }

    private static func verifiedAddressObservation(
        desired: DesiredRuntimeNetwork,
        observed: RuntimeInventoryNetwork,
        inventory: RuntimeInventory
    ) throws -> NetworkAddressObservationReport {
        let constraints = try addressConstraints(
            inventory: inventory,
            excludingResourceUUIDs: [
                desired.identity.resourceUUID,
            ]
        )
        let plan = try NetworkAddressPlanner.makePlans(
            definitions: [addressDefinition(desired)],
            capabilities: .dualStack,
            constraints: constraints
        ).first
        guard let plan else {
            throw conflict(
                "Network address verification could not recover the confirmed desired plan."
            )
        }
        let report: NetworkAddressObservationReport
        do {
            report = try NetworkAddressObserver.verify(
                plan: plan,
                observed: try addressObservations(observed),
                constraints: constraints
            )
        } catch {
            throw conflict(
                "Network address observation failed verification: \(String(describing: error))"
            )
        }
        for family in plan.activeFamilies {
            guard report.family(family)?.state == .available else {
                throw conflict(
                    "Network '\(desired.identity.logicalName)' did not receive its requested \(family.rawValue) address family."
                )
            }
        }
        return report
    }

    private static func addressObservations(
        _ network: RuntimeInventoryNetwork
    ) throws -> [NetworkAddressFamilyObservation] {
        let topology: NetworkAddressTopology
        let kind = network.kind.lowercased()
        if kind.contains("host-only") ||
            kind.contains("hostonly") {
            topology = .hostOnly
        } else if kind.contains("routed") {
            topology = .routed
        } else if kind.contains("nat") ||
            kind.contains("vmnet") {
            topology = .nat
        } else {
            throw conflict(
                "Network observation reported unsupported topology '\(network.kind)'."
            )
        }

        var result: [NetworkAddressFamilyObservation] = []
        for family in NetworkAddressFamily.canonicalOrder {
            let familyValues = network.addresses.filter {
                ($0.contains(":") ? NetworkAddressFamily.ipv6 : .ipv4)
                    == family
            }
            let cidrs = familyValues.filter { $0.contains("/") }
            let gateways = familyValues.filter { !$0.contains("/") }
            guard cidrs.count <= 1,
                  gateways.count <= 1 else {
                throw conflict(
                    "Network observation reported ambiguous \(family.rawValue) subnet or gateway data."
                )
            }
            if let cidr = cidrs.first {
                result.append(
                    NetworkAddressFamilyObservation(
                        family: family,
                        topology: topology,
                        cidr: cidr,
                        gateway: gateways.first
                    )
                )
            } else if !gateways.isEmpty {
                throw conflict(
                    "Network observation reported a \(family.rawValue) gateway without a subnet."
                )
            }
        }
        return result
    }

    private static func observedAddressValues(
        _ report: NetworkAddressFamilyReport?
    ) -> [String] {
        guard let report, report.state == .available else {
            return []
        }
        return [report.cidr, report.gateway]
            .compactMap { $0 }
    }

    private static func recoverCreateFailure(
        desired: DesiredRuntimeNetwork,
        creating: NetworkStateResourceRecord,
        group: OperationGroupRecord,
        preparation: LifecycleCommandPreparation,
        adapter: any RuntimeAdapter,
        store: SQLiteStateStore,
        originalError: Error
    ) async throws {
        do {
            let inventory = try await adapter.inventory()
            if exactNetwork(
                desired.identity,
                in: inventory,
                providerID: preparation.providerID,
                providerGeneration: preparation.providerGeneration,
                projectGeneration: preparation.projectGeneration,
                resourceGeneration: Int(creating.generation + 1),
                fencingToken: group.fencingToken
            ) != nil {
                try commitAvailable(
                    desired: desired,
                    creating: creating,
                    group: group,
                    inventory: inventory,
                    preparation: preparation,
                    adapter: adapter,
                    store: store
                )
                return
            }
            if collision(desired.identity, in: inventory) != nil {
                let authority = NetworkStateMutationAuthority(
                    providerID: preparation.providerID.rawValue,
                    providerGeneration:
                        Int64(preparation.providerGeneration),
                    operationGroupID: group.id,
                    fencingToken: group.fencingToken,
                    plannedCapabilitySHA256:
                        preparation.capabilitySHA256,
                    currentCapabilitySHA256:
                        preparation.capabilitySHA256
                )
                _ = try store.networks.quarantineNetwork(
                    id: creating.id,
                    expected: version(creating),
                    authority: authority,
                    observedSHA256: inventory.semanticSHA256,
                    updatedAt: hostwrightTimestamp()
                )
                try finish(
                    group,
                    status: .failed,
                    checkpoint: "ownership-quarantined",
                    store: store
                )
                throw conflict(
                    "Network mutation returned uncertainly and re-observation found conflicting ownership."
                )
            }
            try finish(
                group,
                status: .interrupted,
                checkpoint: "effect-not-observed",
                store: store
            )
            throw originalError
        } catch let recovery as HostwrightDiagnostic {
            if (try? store.operationGroups.load(id: group.id)?.status)
                == .active {
                try? finish(
                    group,
                    status: .interrupted,
                    checkpoint: "address-verification-failed",
                    store: store
                )
            }
            throw recovery
        } catch {
            if (try? store.operationGroups.load(id: group.id)?.status)
                == .active {
                try? finish(
                    group,
                    status: .interrupted,
                    checkpoint: "observation-unavailable",
                    store: store
                )
            }
            throw originalError
        }
    }

    private static func removeNetwork(
        _ record: NetworkStateResourceRecord,
        preparation: LifecycleCommandPreparation,
        planSHA256: String,
        provider: any RuntimeNetworkProvider,
        adapter: any RuntimeAdapter,
        store: SQLiteStateStore
    ) async throws {
        guard record.lifecycleState == .available,
              record.finalizerState == .active,
              record.projectUUID ==
                preparation.projectResourceUUID,
              record.providerID ==
                preparation.providerID.rawValue,
              record.providerGeneration ==
                Int64(preparation.providerGeneration) else {
            throw conflict(
                "Network deletion requires one exact available provider-bound record."
            )
        }
        guard try store.networks.listAttachments(
            networkUUID: record.id
        ).isEmpty else {
            throw conflict(
                "Network deletion requires every exact attachment record to be released first."
            )
        }
        let identity = try RuntimeNetworkIdentity(
            logicalName: record.name,
            resourceUUID: record.id,
            projectUUID: record.projectUUID,
            runtimeIdentifier: record.runtimeName
        )
        let inventory = try await adapter.inventory()
        guard exactNetwork(
            identity,
            in: inventory,
            providerID: preparation.providerID,
            providerGeneration: preparation.providerGeneration,
            projectGeneration: preparation.projectGeneration,
            resourceGeneration: Int(record.generation),
            fencingToken: record.fencingToken
        ) != nil,
        inventory.containers.allSatisfy({
            !$0.networks.contains(where: {
                $0.networkID == record.runtimeName ||
                    $0.networkID == record.id
            })
        }) else {
            throw conflict(
                "Network deletion requires exact ownership and zero observed workload attachments."
            )
        }
        let desired = DesiredRuntimeNetwork(
            identity: identity,
            mode: runtimeMode(record.driver),
            ipv4: runtimeAddress(record.requestedIPv4),
            ipv6: runtimeAddress(record.requestedIPv6)
        )
        let group = try acquireOperation(
            action: "delete",
            desired: desired,
            desiredSHA256: record.desiredSHA256,
            runtimeResourceGeneration:
                Int(record.generation + 1),
            preparation: preparation,
            planSHA256: planSHA256,
            fencingToken: nil,
            store: store
        )
        let authority = try await mutationAuthority(
            group: group,
            preparation: preparation,
            adapter: adapter
        )
        let deleting = NetworkStateResourceRecord(
            id: record.id,
            projectUUID: record.projectUUID,
            name: record.name,
            runtimeName: record.runtimeName,
            generation: record.generation + 1,
            providerID: record.providerID,
            providerGeneration: record.providerGeneration,
            fencingToken: group.fencingToken,
            driver: record.driver,
            requestedIPv4: record.requestedIPv4,
            requestedIPv6: record.requestedIPv6,
            observedIPv4: record.observedIPv4,
            observedIPv6: record.observedIPv6,
            desiredSHA256: record.desiredSHA256,
            observedSHA256: record.observedSHA256,
            lifecycleState: .deleting,
            finalizerState: .releasing,
            operationGroupID: group.id,
            createdAt: record.createdAt,
            updatedAt: hostwrightTimestamp()
        )
        try store.networks.saveNetwork(
            deleting,
            replacing: version(record),
            authority: authority
        )
        do {
            try await validateProvider(
                provider,
                adapter: adapter,
                preparation: preparation,
                requiredOperation: .delete
            )
            _ = try await provider.networkDelete(
                RuntimeNetworkDeleteRequest(
                    identity: identity,
                    expectedOwnership:
                        RuntimeInventoryOwnershipEvidence(
                            resourceUUID: record.id,
                            projectUUID: record.projectUUID,
                            resourceGeneration:
                                Int(record.generation),
                            projectGeneration:
                                preparation.projectGeneration,
                            providerID:
                                preparation.providerID,
                            providerGeneration:
                                preparation.providerGeneration,
                            fencingToken:
                                record.fencingToken
                        )
                ),
                context: RuntimeMutationContext(
                    providerID: preparation.providerID,
                    capabilitySHA256:
                        preparation.capabilitySHA256,
                    operationID: group.operationID,
                    resourceUUID: record.id,
                    resourceGeneration:
                        Int(record.generation + 1),
                    projectResourceUUID:
                        preparation.projectResourceUUID,
                    projectGeneration:
                        preparation.projectGeneration,
                    providerGeneration:
                        preparation.providerGeneration,
                    fencingToken: group.fencingToken
                )
            )
            let after = try await adapter.inventory()
            guard collision(identity, in: after) == nil else {
                throw conflict(
                    "Network deletion did not produce verified absence."
                )
            }
            try commitDeleted(
                deleting,
                group: group,
                absenceSHA256: after.semanticSHA256,
                authority: authority,
                store: store
            )
        } catch {
            let after = try? await adapter.inventory()
            if let after, collision(identity, in: after) == nil {
                try commitDeleted(
                    deleting,
                    group: group,
                    absenceSHA256: after.semanticSHA256,
                    authority: authority,
                    store: store
                )
                return
            }
            try? finish(
                group,
                status: .interrupted,
                checkpoint: "delete-requires-reobservation",
                store: store
            )
            throw error
        }
    }

    private static func commitDeleted(
        _ deleting: NetworkStateResourceRecord,
        group: OperationGroupRecord,
        absenceSHA256: String,
        authority: NetworkStateMutationAuthority,
        store: SQLiteStateStore
    ) throws {
        let deleted = NetworkStateResourceRecord(
            id: deleting.id,
            projectUUID: deleting.projectUUID,
            name: deleting.name,
            runtimeName: deleting.runtimeName,
            generation: deleting.generation + 1,
            providerID: deleting.providerID,
            providerGeneration: deleting.providerGeneration,
            fencingToken: deleting.fencingToken,
            driver: deleting.driver,
            requestedIPv4: deleting.requestedIPv4,
            requestedIPv6: deleting.requestedIPv6,
            observedIPv4: [],
            observedIPv6: [],
            desiredSHA256: deleting.desiredSHA256,
            observedSHA256: absenceSHA256,
            lifecycleState: .deleted,
            finalizerState: .released,
            operationGroupID: group.id,
            createdAt: deleting.createdAt,
            updatedAt: hostwrightTimestamp()
        )
        try store.networks.saveNetwork(
            deleted,
            replacing: version(deleting),
            authority: authority
        )
        try finish(
            group,
            status: .succeeded,
            checkpoint: "state-committed",
            store: store
        )
        _ = try store.networks.removeDeletedNetwork(
            id: deleted.id,
            expected: version(deleted)
        )
    }

    private static func validateProvider(
        _ provider: any RuntimeNetworkProvider,
        adapter: any RuntimeAdapter,
        preparation: LifecycleCommandPreparation,
        requiredOperation: RuntimeNetworkProviderOperation
    ) async throws {
        let snapshot = try await adapter.capabilitySnapshot()
        let capabilities = try await provider.networkCapabilities()
        guard snapshot.descriptor.providerID ==
                preparation.providerID,
              snapshot.canonicalSHA256 ==
                preparation.capabilitySHA256,
              capabilities.providerID ==
                preparation.providerID,
              capabilities.status(
                for: requiredOperation
              )?.state == .available else {
            throw HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message:
                    "Network mutation refused a stale provider, capability snapshot, or unavailable operation."
            )
        }
        guard requiredOperation == .create else { return }
        for desired in preparation.desiredState.networks {
            guard capabilities.modes.contains(desired.mode) else {
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "Network '\(desired.identity.logicalName)' requests driver '\(desired.mode.rawValue)', which provider '\(preparation.providerID.rawValue)' does not advertise."
                )
            }
            try validateAddressMode(
                desired.ipv4,
                family: .ipv4,
                networkName: desired.identity.logicalName,
                supported: capabilities.ipv4AddressModes,
                providerID: preparation.providerID
            )
            try validateAddressMode(
                desired.ipv6,
                family: .ipv6,
                networkName: desired.identity.logicalName,
                supported: capabilities.ipv6AddressModes,
                providerID: preparation.providerID
            )
        }

        let inventory = try await adapter.inventory()
        let desiredIDs = Set(
            preparation.desiredState.networks.map {
                $0.identity.resourceUUID
            }
        )
        do {
            let result = try NetworkAddressPlanner.evaluate(
                definitions:
                    preparation.desiredState.networks.map(
                        addressDefinition
                    ),
                capabilities: addressCapabilities(
                    capabilities,
                    providerID: preparation.providerID
                ),
                constraints: try addressConstraints(
                    inventory: inventory,
                    excludingResourceUUIDs: desiredIDs
                )
            )
            if case .unavailable(let unavailable) = result {
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "Network '\(unavailable.networkName)' \(unavailable.family.rawValue) \(unavailable.requestedMode.rawValue) is unavailable: \(unavailable.reason)"
                )
            }
        } catch let diagnostic as HostwrightDiagnostic {
            throw diagnostic
        } catch {
            throw HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message:
                    "Network address planning refused mutation: \(String(describing: error))"
            )
        }
    }

    private static func validateAddressMode(
        _ request: RuntimeNetworkAddressRequest,
        family: NetworkAddressFamily,
        networkName: String,
        supported: [RuntimeNetworkAddressMode],
        providerID: RuntimeProviderID
    ) throws {
        guard supported.contains(request.mode) else {
            throw HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message:
                    "Network '\(networkName)' requests \(family.rawValue) mode '\(request.mode.rawValue)', which provider '\(providerID.rawValue)' cannot enforce."
            )
        }
    }

    private static func addressCapabilities(
        _ capabilities: RuntimeNetworkProviderCapabilities,
        providerID: RuntimeProviderID
    ) -> NetworkAddressCapabilities {
        func family(
            _ modes: [RuntimeNetworkAddressMode],
            name: String
        ) -> NetworkAddressFamilyCapability {
            NetworkAddressFamilyCapability(
                automatic: modes.contains(.automatic),
                explicitCIDR: modes.contains(.cidr),
                disabled: modes.contains(.disabled),
                unavailableReason:
                    "Provider '\(providerID.rawValue)' does not advertise the requested \(name) address mode."
            )
        }
        return NetworkAddressCapabilities(
            ipv4: family(
                capabilities.ipv4AddressModes,
                name: "IPv4"
            ),
            ipv6: family(
                capabilities.ipv6AddressModes,
                name: "IPv6"
            )
        )
    }

    private static func addressDefinition(
        _ desired: DesiredRuntimeNetwork
    ) -> HostwrightNetworkDefinition {
        HostwrightNetworkDefinition(
            name: desired.identity.logicalName,
            driver: desired.mode == .nat ? .nat : .hostOnly,
            ipv4: manifestAddress(desired.ipv4),
            ipv6: manifestAddress(desired.ipv6)
        )
    }

    private static func manifestAddress(
        _ request: RuntimeNetworkAddressRequest
    ) -> HostwrightNetworkAddressRequest {
        switch request {
        case .automatic:
            return .auto
        case .disabled:
            return .disabled
        case .cidr(let value):
            return .cidr(value)
        }
    }

    private static func addressConstraints(
        inventory: RuntimeInventory,
        excludingResourceUUIDs: Set<String>
    ) throws -> NetworkAddressPlanningConstraints {
        let excludedCIDRs = Set(
            inventory.networks
                .filter {
                    guard let resourceUUID = $0.ownership?.resourceUUID else {
                        return false
                    }
                    return excludingResourceUUIDs.contains(resourceUUID)
                }
                .flatMap(\.addresses)
                .filter { $0.contains("/") }
        )
        let hostCIDRs = try NetworkHostInterfaceInventory.currentCIDRs()
            .filter { !excludedCIDRs.contains($0) }
        let occupiedCIDRs = inventory.networks
            .filter {
                guard let resourceUUID = $0.ownership?.resourceUUID else {
                    return true
                }
                return !excludingResourceUUIDs.contains(resourceUUID)
            }
            .flatMap(\.addresses)
            .filter { $0.contains("/") }
        return NetworkAddressPlanningConstraints(
            hostCIDRs: hostCIDRs,
            occupiedCIDRs: occupiedCIDRs
        )
    }

    private static func mutationAuthority(
        group: OperationGroupRecord,
        preparation: LifecycleCommandPreparation,
        adapter: any RuntimeAdapter
    ) async throws -> NetworkStateMutationAuthority {
        let snapshot = try await adapter.capabilitySnapshot()
        return NetworkStateMutationAuthority(
            providerID: preparation.providerID.rawValue,
            providerGeneration:
                Int64(preparation.providerGeneration),
            operationGroupID: group.id,
            fencingToken: group.fencingToken,
            plannedCapabilitySHA256:
                preparation.capabilitySHA256,
            currentCapabilitySHA256: snapshot.canonicalSHA256
        )
    }

    private static func acquireOperation(
        action: String,
        desired: DesiredRuntimeNetwork,
        desiredSHA256: String,
        runtimeResourceGeneration: Int,
        preparation: LifecycleCommandPreparation,
        planSHA256: String,
        fencingToken: String?,
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        let id = HostwrightResourceUUID.legacy(
            kind: "network-operation",
            identifier:
                "\(planSHA256):\(action):\(desired.identity.resourceUUID):\(runtimeResourceGeneration)"
        )
        let fence = fencingToken ?? HostwrightResourceUUID.legacy(
            kind: "network-fence",
            identifier: id
        )
        let intent = NetworkLifecycleOperationIntent(
            schemaVersion: 1,
            action: action,
            projectUUID:
                preparation.projectResourceUUID,
            networkUUID: desired.identity.resourceUUID,
            runtimeName: desired.identity.runtimeIdentifier,
            providerID: preparation.providerID.rawValue,
            providerGeneration:
                preparation.providerGeneration,
            capabilitySHA256:
                preparation.capabilitySHA256,
            desiredSHA256: desiredSHA256,
            runtimeResourceGeneration:
                runtimeResourceGeneration
        )
        let now = hostwrightTimestamp()
        let group = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "network-resource",
            projectID: preparation.projectID,
            serviceName: nil,
            plannedActionType: action,
            status: .active,
            groupIdempotencyKey: try digest(intent),
            planHash: planSHA256,
            checkpoint: "intent-persisted",
            lockOwner: "hostwright-cli",
            lockExpiresAt: hostwrightTimestampAdding(
                seconds: 86_400,
                to: now
            ),
            rollbackAvailable: action == "create",
            manualRecoveryHintRedacted:
                "Re-observe the exact UUID-owned network before resuming.",
            createdAt: now,
            updatedAt: now,
            metadataJSONRedacted:
                #"{"resource":"network"}"#,
            fencingToken: fence,
            intentJSONRedacted: try encoded(intent),
            compensationJSONRedacted:
                action == "create"
                    ? #"["delete-created-network"]"#
                    : "[]",
            verificationJSONRedacted: "{}"
        )
        if let existing = try store.operationGroups.load(id: id) {
            guard existing.planHash == planSHA256,
                  existing.fencingToken == fence,
                  existing.groupIdempotencyKey ==
                    group.groupIdempotencyKey else {
                throw conflict(
                    "A prior network operation reused the identity with different authority."
                )
            }
            switch existing.status {
            case .active:
                return existing
            case .interrupted:
                return try store.operationGroups.resumeInterrupted(
                    groupID: existing.id,
                    expectedFencingToken:
                        existing.fencingToken,
                    lockOwner: "hostwright-cli",
                    lockExpiresAt:
                        group.lockExpiresAt,
                    updatedAt: now
                )
            case .succeeded, .failed:
                throw conflict(
                    "A terminal network operation cannot be replayed without matching authoritative state."
                )
            }
        }
        let acquired = try store.operationGroups.acquire(
            group,
            currentTimestamp: now
        )
        if let value = acquired.acquired { return value }
        guard let existing = acquired.existingActive,
              existing.id == group.id,
              existing.fencingToken == group.fencingToken,
              existing.planHash == group.planHash else {
            throw conflict(
                "Another active operation owns the project network fence."
            )
        }
        return existing
    }

    private static func createGeneration(
        desired: DesiredRuntimeNetwork,
        preparation: LifecycleCommandPreparation,
        store: SQLiteStateStore
    ) throws -> NetworkCreateGeneration {
        let groups = try store.operationGroups.loadProject(
            projectID: preparation.projectID
        ).filter {
            $0.groupKind == "network-resource"
        }
        guard !groups.isEmpty else {
            return NetworkCreateGeneration(state: 1, runtime: 2)
        }

        let decoder = JSONDecoder()
        var exactHistory: [
            (
                group: OperationGroupRecord,
                intent: NetworkLifecycleOperationIntent
            )
        ] = []
        for group in groups {
            guard let data = group.intentJSONRedacted.data(
                using: .utf8
            ),
            let intent = try? decoder.decode(
                NetworkLifecycleOperationIntent.self,
                from: data
            ) else {
                throw conflict(
                    "Network recreation found ambiguous operation history."
                )
            }
            guard intent.networkUUID ==
                    desired.identity.resourceUUID else {
                continue
            }
            guard group.projectID == preparation.projectID,
                  intent.schemaVersion == 1,
                  intent.projectUUID ==
                    preparation.projectResourceUUID,
                  intent.runtimeName ==
                    desired.identity.runtimeIdentifier,
                  intent.providerID ==
                    preparation.providerID.rawValue,
                  intent.providerGeneration ==
                    preparation.providerGeneration,
                  group.plannedActionType == intent.action,
                  intent.action == "create" ||
                    intent.action == "delete",
                  intent.runtimeResourceGeneration > 0 else {
                throw conflict(
                    "Network recreation history does not match the exact project and provider authority."
                )
            }
            exactHistory.append((group, intent))
        }
        guard let latest = exactHistory.last else {
            return NetworkCreateGeneration(state: 1, runtime: 2)
        }
        for pair in zip(exactHistory, exactHistory.dropFirst()) {
            guard pair.0.intent.runtimeResourceGeneration <
                    pair.1.intent.runtimeResourceGeneration else {
                throw conflict(
                    "Network recreation found ambiguous non-monotonic operation history."
                )
            }
        }
        guard latest.group.status == .succeeded,
              latest.group.checkpoint == "state-committed",
              latest.intent.action == "delete" else {
            throw conflict(
                "Missing network state can only be recreated after an exact committed delete."
            )
        }
        guard latest.intent.runtimeResourceGeneration <=
                Int.max - 3 else {
            throw conflict(
                "Network recreation exhausted the resource generation range."
            )
        }

        // A committed delete advances once for deletion and once for
        // durable absence before the next create intent is persisted.
        let state = latest.intent.runtimeResourceGeneration + 2
        return NetworkCreateGeneration(
            state: Int64(state),
            runtime: state + 1
        )
    }

    private static func exactNetwork(
        _ identity: RuntimeNetworkIdentity,
        in inventory: RuntimeInventory,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        projectGeneration: Int,
        resourceGeneration: Int,
        fencingToken: String
    ) -> RuntimeInventoryNetwork? {
        let matches = inventory.networks.filter {
            $0.runtimeID == identity.runtimeIdentifier ||
                $0.name == identity.runtimeIdentifier ||
                $0.ownership?.resourceUUID ==
                    identity.resourceUUID
        }
        guard matches.count == 1,
              let network = matches.first,
              network.runtimeID == identity.runtimeIdentifier ||
                network.name == identity.runtimeIdentifier,
              let ownership = network.ownership,
              ownership.resourceUUID ==
                identity.resourceUUID,
              ownership.projectUUID == identity.projectUUID,
              ownership.resourceGeneration ==
                resourceGeneration,
              ownership.projectGeneration ==
                projectGeneration,
              ownership.providerID == providerID,
              ownership.providerGeneration ==
                providerGeneration,
              ownership.fencingToken == fencingToken else {
            return nil
        }
        return network
    }

    private static func collision(
        _ identity: RuntimeNetworkIdentity,
        in inventory: RuntimeInventory
    ) -> RuntimeInventoryNetwork? {
        inventory.networks.first {
            $0.runtimeID == identity.runtimeIdentifier ||
                $0.name == identity.runtimeIdentifier ||
                $0.ownership?.resourceUUID ==
                    identity.resourceUUID
        }
    }

    private static func checkpoint(
        _ group: OperationGroupRecord,
        name: String,
        verification: String,
        store: SQLiteStateStore
    ) throws {
        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: name,
            verificationJSONRedacted: verification,
            updatedAt: hostwrightTimestamp()
        )
    }

    private static func finish(
        _ group: OperationGroupRecord,
        status: OperationGroupStatus,
        checkpoint: String,
        store: SQLiteStateStore
    ) throws {
        try store.operationGroups.finish(
            groupID: group.id,
            status: status,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted:
                status == .succeeded
                    ? "No manual recovery is required."
                    : "Re-observe the exact UUID-owned network before resuming.",
            updatedAt: hostwrightTimestamp(),
            metadataJSONRedacted:
                #"{"resource":"network","result":"\#(status.rawValue)"}"#
        )
    }

    private static func version(
        _ record: NetworkStateResourceRecord
    ) -> NetworkStateExpectedVersion {
        NetworkStateExpectedVersion(
            generation: record.generation,
            fencingToken: record.fencingToken
        )
    }

    private static func stateDriver(
        _ value: RuntimeNetworkMode
    ) -> NetworkStateDriver {
        value == .nat ? .nat : .hostOnly
    }

    private static func runtimeMode(
        _ value: NetworkStateDriver
    ) -> RuntimeNetworkMode {
        value == .nat ? .nat : .hostOnly
    }

    private static func stateAddress(
        _ value: RuntimeNetworkAddressRequest
    ) -> NetworkStateAddressRequest {
        switch value {
        case .automatic:
            return .auto
        case .disabled:
            return .disabled
        case .cidr(let cidr):
            return .cidr(cidr)
        }
    }

    private static func runtimeAddress(
        _ value: NetworkStateAddressRequest
    ) -> RuntimeNetworkAddressRequest {
        switch value {
        case .auto:
            return .automatic
        case .disabled:
            return .disabled
        case .cidr(let cidr):
            return .cidr(cidr)
        }
    }

    private static func encoded<T: Encodable>(
        _ value: T
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func digest<T: Encodable>(
        _ value: T
    ) throws -> String {
        SHA256.hash(data: Data(try encoded(value).utf8))
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
