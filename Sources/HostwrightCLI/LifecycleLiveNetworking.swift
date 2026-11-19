import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightNetworking
import HostwrightObservability
import HostwrightPolicy
import HostwrightReconciler
import HostwrightRegistry
import HostwrightRuntime
import HostwrightSecrets
import HostwrightState
import HostwrightStorage

extension LifecycleLiveEffects {
    func persistNetworkPortIntent(
        action: PlannedRuntimeAction,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async throws {
        let rollbackStart = node.action == .start &&
            (context.plan.command == .update || context.plan.command == .rollback)
        guard node.action == .create || rollbackStart ||
                node.action == .delete ||
                node.action == .retire else {
            return
        }
        if node.action == .create || rollbackStart {
            let group = try exactNetworkPortOperationGroup(context: context)
            if try rollbackStart && !NetworkPortLifecycleCoordinator.requiresRollbackPortReservation(
                node: node, plan: context.plan, group: group, store: store
            ) { return }
            var desired = action.desiredService
            if desired == nil { desired = await state.desiredService(for: node.key) }
            guard let desired else {
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "Port reservation requires the exact desired service before runtime creation."
                )
            }
            guard !desired.ports.isEmpty else {
                return
            }
            let inventory = try await adapter.inventory()
            _ = try NetworkPortLifecycleCoordinator.reserve(
                service: desired,
                node: node,
                plan: context.plan,
                group: group,
                inventory: inventory,
                store: store,
                isAvailable:
                    NetworkPortSocketAvailability.isAvailable
            )
            return
        }
        let portRecords = try store.networkPorts.loadProject(
            projectUUID: context.plan.projectResourceUUID
        ).filter {
            $0.resourceUUID == node.resourceUUID
        }
        guard !portRecords.isEmpty else {
            return
        }
        let group = try exactNetworkPortOperationGroup(
            context: context
        )
        let inventory = try await adapter.inventory()
        let priorFencingToken = await state.binding(
            resourceUUID: node.resourceUUID,
            resourceIdentifier: node.resourceIdentifier
        )?.currentFencingToken
        _ = try NetworkPortLifecycleCoordinator.beginRelease(
            node: node,
            plan: context.plan,
            group: group,
            inventory: inventory,
            priorFencingToken: priorFencingToken,
            store: store
        )
    }

    func reconcileNetworkPorts(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        inventory: RuntimeInventory
    ) throws {
        let rollbackStart = node.action == .start &&
            (context.plan.command == .update || context.plan.command == .rollback)
        guard node.action == .create || rollbackStart ||
                node.action == .delete ||
                node.action == .retire else {
            return
        }
        let portRecords = try store.networkPorts.loadProject(
            projectUUID: context.plan.projectResourceUUID
        ).filter {
            $0.resourceUUID == node.resourceUUID
        }
        guard !portRecords.isEmpty else {
            return
        }
        let group = try exactNetworkPortOperationGroup(
            context: context
        )
        if try rollbackStart && !NetworkPortLifecycleCoordinator.requiresRollbackPortReservation(
            node: node, plan: context.plan, group: group, store: store
        ) { return }
        if node.action == .create || rollbackStart {
            _ = try NetworkPortLifecycleCoordinator.confirmActive(
                node: node,
                plan: context.plan,
                group: group,
                inventory: inventory,
                store: store
            )
            return
        }
        _ = try NetworkPortLifecycleCoordinator.confirmReleased(
            node: node,
            plan: context.plan,
            group: group,
            inventory: inventory,
            store: store
        )
    }

    private func exactNetworkPortOperationGroup(
        context: LifecycleSagaContext
    ) throws -> OperationGroupRecord {
        guard let group = try store.operationGroups.load(
            id: context.groupID
        ),
        group.status == .active,
        group.groupKind == "lifecycle-v1",
        group.projectID == context.plan.projectID,
        group.planHash == context.plan.planSHA256,
        group.operationID == context.operationID,
        group.fencingToken == context.fencingToken else {
            throw HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message:
                    "Port lifecycle lost the exact active operation-group authority."
            )
        }
        return group
    }

    func persistNetworkAttachmentIntent(
        action: PlannedRuntimeAction,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async throws {
        switch action.kind {
        case .create:
            guard let desired = action.desiredService,
                  !desired.networks.isEmpty else {
                return
            }
            let authority = try await networkAttachmentAuthority(
                context: context
            )
            let repository = store.networks
            for attachment in desired.networks.sorted(
                by: {
                    if $0.networkRuntimeIdentifier !=
                        $1.networkRuntimeIdentifier {
                        return $0.networkRuntimeIdentifier <
                            $1.networkRuntimeIdentifier
                    }
                    return $0.networkResourceUUID <
                        $1.networkResourceUUID
                }
            ) {
                guard let network = try repository.loadNetwork(
                    id: attachment.networkResourceUUID
                ),
                network.runtimeName ==
                    attachment.networkRuntimeIdentifier else {
                    throw NetworkAttachmentLifecycleError
                        .ownershipConflict(
                            "Create-time attachment requires one exact available network record."
                        )
                }
                let descriptor = try NetworkAttachmentCreateDescriptor(
                    network: network,
                    containerRuntimeIdentifier:
                        action.resourceIdentifier,
                    containerContext:
                        mutationContext(
                            node: node,
                            context: context
                        ),
                    aliases: attachment.aliases
                )
                _ = try NetworkAttachmentLifecycle
                    .persistCreateIntent(
                        descriptor,
                        authority: authority,
                        timestamp: hostwrightTimestamp(),
                        repository: repository
                    )
            }
        case .remove:
            let authority = try await networkAttachmentAuthority(
                context: context
            )
            let repository = store.networks
            let records = try NetworkAttachmentLifecycle
                .reverseReleaseOrder(
                    projectUUID:
                        context.plan.projectResourceUUID,
                    resourceUUID: node.resourceUUID,
                    providerID: context.plan.providerID,
                    providerGeneration:
                        context.plan.providerGeneration,
                    repository: repository
                )
            for record in records {
                _ = try NetworkAttachmentLifecycle
                    .persistReleaseIntent(
                        record: record,
                        authority: authority,
                        timestamp: hostwrightTimestamp(),
                        repository: repository
                    )
            }
        case .start, .stop, .restart, .update, .noOp:
            return
        }
    }

    func reconcileNetworkAttachments(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        inventory: RuntimeInventory
    ) async throws {
        let repository = store.networks
        let authority = try await networkAttachmentAuthority(
            context: context
        )
        if node.action == .create,
           let desired = await state.desiredService(for: node.key) {
            let containerIdentifier =
                node.resourceIdentifier ??
                desired.identity.managedResourceIdentifier
            for attachment in desired.networks.sorted(
                by: {
                    if $0.networkRuntimeIdentifier !=
                        $1.networkRuntimeIdentifier {
                        return $0.networkRuntimeIdentifier <
                            $1.networkRuntimeIdentifier
                    }
                    return $0.networkResourceUUID <
                        $1.networkResourceUUID
                }
            ) {
                guard let network = try repository.loadNetwork(
                    id: attachment.networkResourceUUID
                ) else {
                    throw NetworkAttachmentLifecycleError
                        .ownershipConflict(
                            "Attachment verification lost its exact network record."
                        )
                }
                let descriptor = try NetworkAttachmentCreateDescriptor(
                    network: network,
                    containerRuntimeIdentifier:
                        containerIdentifier,
                    containerContext:
                        mutationContext(
                            node: node,
                            context: context
                        ),
                    aliases: attachment.aliases
                )
                guard let record = try repository.loadAttachment(
                    id: descriptor.attachmentUUID
                ) else {
                    throw NetworkAttachmentLifecycleError
                        .ownershipConflict(
                            "Attachment verification lost its durable pre-mutation intent."
                        )
                }
                switch try NetworkAttachmentLifecycle
                    .resolveCreateObservation(
                        record: record,
                        descriptor: descriptor,
                        inventory: inventory,
                        trigger: .postMutation,
                        authority: authority,
                        timestamp: hostwrightTimestamp(),
                        repository: repository
                    ) {
                case .attached:
                    break
                case .absent:
                    throw NetworkAttachmentLifecycleError
                        .observationIndeterminate(
                            "Structured observation did not prove the requested create-time network attachment."
                        )
                case .quarantined:
                    throw NetworkAttachmentLifecycleError
                        .ownershipConflict(
                            "Structured observation found ambiguous network attachment ownership."
                        )
                }
            }
        }
        if node.action == .delete || node.action == .retire {
            let containerIdentifier: String
            if let resourceIdentifier =
                node.resourceIdentifier {
                containerIdentifier = resourceIdentifier
            } else {
                containerIdentifier = await state.identity(
                    for: node,
                    projectName: context.plan.projectName
                ).managedResourceIdentifier
            }
            let records = try NetworkAttachmentLifecycle
                .reverseReleaseOrder(
                    projectUUID:
                        context.plan.projectResourceUUID,
                    resourceUUID: node.resourceUUID,
                    providerID: context.plan.providerID,
                    providerGeneration:
                        context.plan.providerGeneration,
                    repository: repository
                )
            for record in records {
                try NetworkAttachmentLifecycle
                    .releaseAfterVerifiedAbsence(
                        record: record,
                        containerRuntimeIdentifier:
                            containerIdentifier,
                        inventory: inventory,
                        authority: authority,
                        timestamp: hostwrightTimestamp(),
                        repository: repository
                    )
            }
        }
    }

    private func networkAttachmentAuthority(
        context: LifecycleSagaContext
    ) async throws -> NetworkStateMutationAuthority {
        let capability = try await adapter.capabilitySnapshot()
        guard capability.descriptor.providerID ==
                context.plan.providerID,
              capability.canonicalSHA256 ==
                context.plan.capabilitySHA256 else {
            throw NetworkAttachmentLifecycleError
                .ownershipConflict(
                    "Network attachment mutation refused a stale capability snapshot."
                )
        }
        return NetworkStateMutationAuthority(
            providerID: context.plan.providerID.rawValue,
            providerGeneration:
                Int64(context.plan.providerGeneration),
            operationGroupID: context.groupID,
            fencingToken: context.fencingToken,
            plannedCapabilitySHA256:
                context.plan.capabilitySHA256,
            currentCapabilitySHA256:
                capability.canonicalSHA256
        )
    }
}
