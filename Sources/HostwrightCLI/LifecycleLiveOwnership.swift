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
    private func resolveSecretReferences(
        _ service: DesiredRuntimeService,
        workload: HostwrightSecretWorkloadScope
    ) throws -> DesiredRuntimeService {
        guard service.environment.contains(where: { $0.secretReference != nil }) else {
            return service
        }
        let secretResolver = environment.secretResolver()
        let resolved = try service.environment.map { entry in
            guard let reference = entry.secretReference else {
                return entry
            }
            return RuntimeEnvironmentValue(
                name: entry.name,
                value: try secretResolver.resolve(
                    reference: reference,
                    for: workload,
                    environmentKey: entry.name,
                    at: Date()
                ).stringValue(),
                isSensitive: true
            )
        }
        return lifecycleReplacingEnvironment(in: service, with: resolved)
    }

    func plannedAction(
        _ node: LifecyclePlanNode,
        plan: LifecyclePlan
    ) async throws -> PlannedRuntimeAction {
        let identity = await state.identity(for: node, projectName: plan.projectName)
        let kind: PlannedRuntimeActionKind
        switch node.action {
        case .create: kind = .create
        case .start: kind = .start
        case .stop: kind = .stop
        case .restart: kind = .restart
        case .delete, .retire: kind = .remove
        default:
            throw RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: "Lifecycle action \(node.action.rawValue) is not executable through the runtime adapter."
            )
        }
        let desiredService: DesiredRuntimeService?
        if let service = await state.desiredService(for: node.key) {
            if kind == .create {
                desiredService = try resolveSecretReferences(
                    service,
                    workload: try lifecycleSecretWorkloadScope(
                        projectResourceUUID: plan.projectResourceUUID,
                        resourceUUID: node.resourceUUID,
                        generation: node.resourceGeneration,
                        serviceName: service.logicalServiceName
                    )
                )
            } else {
                desiredService = service
            }
        } else {
            desiredService = nil
        }
        return PlannedRuntimeAction(
            kind: kind,
            identity: identity,
            resourceIdentifier: node.resourceIdentifier ?? identity.managedResourceIdentifier,
            isDestructive:
                kind == .remove ||
                kind == .restart ||
                kind == .stop,
            requiresProcessCompletion:
                kind == .start && isCompletionAwareStart(node),
            summary: node.key,
            desiredService: desiredService
        )
    }

    func mutationContext(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: context.plan.providerID,
            capabilitySHA256: context.plan.capabilitySHA256,
            operationID: context.operationID,
            resourceUUID: node.resourceUUID,
            resourceGeneration: node.resourceGeneration,
            projectResourceUUID: context.plan.projectResourceUUID,
            projectGeneration: context.plan.projectGeneration,
            providerGeneration: context.plan.providerGeneration,
            fencingToken: context.fencingToken
        )
    }

    func exactOwnership(
        _ ownership: RuntimeInventoryOwnershipEvidence?,
        node: LifecyclePlanNode,
        plan: LifecyclePlan,
        binding: LifecycleResourceBinding?
    ) -> Bool {
        guard let ownership else { return false }
        return ownership.resourceUUID == node.resourceUUID &&
            ownership.resourceGeneration == node.resourceGeneration &&
            ownership.projectUUID == plan.projectResourceUUID &&
            ownership.projectGeneration == plan.projectGeneration &&
            ownership.providerID == plan.providerID &&
            ownership.providerGeneration == plan.providerGeneration
    }

    func postconditionSatisfied(
        node: LifecyclePlanNode,
        exactContainer: RuntimeInventoryContainer?,
        observedService: ObservedRuntimeService?,
        desiredService: DesiredRuntimeService?
    ) -> Bool {
        switch node.action {
        case .validate:
            return exactContainer == nil && observedService == nil
        case .create:
            return exactContainer != nil &&
                observedService?.lifecycleState != .missing
        case .start, .restart:
            return exactContainer != nil &&
                observedService?.lifecycleState == .running
        case .stop:
            return exactContainer != nil &&
                [.created, .stopped, .exited].contains(
                    observedService?.lifecycleState ?? .unknown
                )
        case .delete, .retire:
            return exactContainer == nil &&
                (observedService == nil ||
                    observedService?.lifecycleState == .missing)
        case .verify:
            guard let observedService else { return false }
            return node.postconditions.allSatisfy { condition in
                switch condition.kind {
                case "dependency-started":
                    return observedService.lifecycleState != .missing &&
                        observedService.lifecycleState != .unknown
                case "dependency-completed":
                    return observedService.lifecycleState == .exited
                case "dependency-ready", "probe-readiness":
                    if desiredService?.probes.readiness == nil {
                        return observedService.lifecycleState == .running
                    }
                    return observedService.healthState == .healthy
                case "probe-startup":
                    return observedService.lifecycleState == .running &&
                        observedService.healthState != .unhealthy
                default:
                    return observedService.lifecycleState == .running
                }
            }
        case .promote:
            return exactContainer != nil &&
                observedService?.lifecycleState == .running &&
                observedService?.healthState != .unhealthy
        case .runHook:
            return false
        default:
            return false
        }
    }

    func isCompletionAwareStart(_ node: LifecyclePlanNode) -> Bool {
        node.action == .start &&
            node.postconditions.contains {
                $0.kind == "lifecycle" &&
                    $0.expectedValue == RuntimeLifecycleState.exited.rawValue
            }
    }

    func lifecycleDeleteTargetStillPresent(
        node: LifecyclePlanNode,
        containers: [RuntimeInventoryContainer]
    ) -> Bool {
        guard node.action == .delete || node.action == .retire else {
            return false
        }
        return containers.contains {
            $0.ownership?.resourceUUID == node.resourceUUID ||
                $0.name == node.resourceIdentifier ||
                $0.runtimeID == node.resourceIdentifier
        }
    }

    func noEffectObserved(
        node: LifecyclePlanNode,
        exactContainer: RuntimeInventoryContainer?,
        observedService: ObservedRuntimeService?,
        collisionCount: Int
    ) -> Bool {
        guard collisionCount <= 1 else { return false }
        switch node.action {
        case .create:
            return exactContainer == nil && observedService == nil
        case .start:
            return exactContainer != nil &&
                [.created, .stopped, .exited].contains(
                    observedService?.lifecycleState ?? .unknown
                )
        case .stop:
            return exactContainer != nil &&
                observedService?.lifecycleState == .running
        case .delete, .retire:
            return exactContainer != nil
        case .restart, .validate, .verify, .runHook, .promote:
            return false
        default:
            return false
        }
    }

    func persistVerifiedProjection(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        identity: RuntimeServiceIdentity,
        exactContainer: RuntimeInventoryContainer?,
        observed: ObservedRuntimeState,
        observationSHA256: String
    ) async throws {
        let now = hostwrightTimestamp()
        let desiredForNode = await state.desiredService(for: node.key)
        if context.direction == .forward,
           node.action == .create,
           exactContainer != nil,
           let desiredForNode,
           let imageLock = desiredForNode.imageLock {
            let record = ImageDigestLockRecord(
                id: HostwrightResourceUUID.legacy(
                    kind: "image-digest-lock-observed",
                    identifier:
                        "\(context.groupID):\(node.resourceUUID)"
                ),
                projectID: context.plan.projectID,
                resourceUUID: node.resourceUUID,
                serviceName: desiredForNode.logicalServiceName,
                replicaIndex: desiredForNode.replicaIndex,
                stateKind: .observed,
                lock: imageLock,
                providerGeneration: context.plan.providerGeneration,
                planSHA256: context.plan.planSHA256,
                operationGroupID: context.groupID,
                observationSHA256: observationSHA256,
                createdAt: now,
                updatedAt: now
            )
            try store.imageDigestLocks.save(record)
        }
        if node.action == .create, let exactContainer {
            let existing = try store.ownership.loadAll().first(where: {
                $0.resourceUUID == node.resourceUUID &&
                    $0.resourceIdentifier ==
                        (node.resourceIdentifier ?? exactContainer.name) &&
                    RuntimeProviderBinding.stableID(
                        for: $0.runtimeAdapter
                    ) == context.plan.providerID
            })
            let existingAuthority = try existing.flatMap {
                try OwnershipAuthorityMetadata.decode(
                    from: $0.metadataJSONRedacted
                )
            }
            if let existing {
                try existingAuthority?.validate(for: existing)
                guard existing.fencingToken == context.fencingToken,
                      existing.projectID == context.plan.projectID,
                      existing.serviceName == identity.serviceName,
                      existing.projectResourceUUID ==
                        context.plan.projectResourceUUID,
                      existingAuthority?.deletionTimestamp == nil,
                      existingAuthority.map({
                          Set($0.finalizers.map(\.state)) == [.active]
                      }) ?? true else {
                    throw StateStoreError.invalidRecord(
                        "Lifecycle replacement create found stale, deleting, or mismatched ownership authority."
                    )
                }
            }
            let baseRecord = OwnershipRecord(
                id: existing?.id ?? HostwrightResourceUUID.generate(),
                resourceIdentifier: node.resourceIdentifier ?? exactContainer.name,
                resourceType: "container",
                projectID: context.plan.projectID,
                serviceName: identity.serviceName,
                runtimeAdapter: context.plan.providerID.rawValue,
                createdAt: existing?.createdAt ?? now,
                observedAt: now,
                cleanupEligible: true,
                metadataJSONRedacted: try lifecycleOwnershipMetadataJSON(
                    identity: identity,
                    desiredService: desiredForNode,
                    healthy: false,
                    capabilitySHA256: context.plan.capabilitySHA256,
                    planSHA256: context.plan.planSHA256
                ),
                identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                resourceUUID: node.resourceUUID,
                resourceGeneration: node.resourceGeneration,
                projectResourceUUID: context.plan.projectResourceUUID,
                projectGeneration: context.plan.projectGeneration,
                providerGeneration: context.plan.providerGeneration,
                fencingToken: context.fencingToken
            )
            guard let group = try store.operationGroups.load(
                id: context.groupID
            ),
            group.status == .active,
            group.planHash == context.plan.planSHA256,
            group.fencingToken == context.fencingToken,
            group.lockOwner == context.leaseOwner else {
                throw StateStoreError.invalidRecord(
                    "Lifecycle ownership authority requires the exact active operation lease."
                )
            }
            let authority = try OwnershipAuthorityRecord.lifecycle(
                ownership: baseRecord,
                operationGroup: group,
                finalizerState: .active,
                handoffGeneration:
                    existingAuthority?.handoffGeneration ?? 0
            )
            let record = OwnershipRecord(
                id: baseRecord.id,
                resourceIdentifier: baseRecord.resourceIdentifier,
                resourceType: baseRecord.resourceType,
                projectID: baseRecord.projectID,
                serviceName: baseRecord.serviceName,
                runtimeAdapter: baseRecord.runtimeAdapter,
                createdAt: baseRecord.createdAt,
                observedAt: baseRecord.observedAt,
                cleanupEligible: baseRecord.cleanupEligible,
                metadataJSONRedacted: try OwnershipAuthorityMetadata.encode(
                    authority,
                    into: baseRecord.metadataJSONRedacted
                ),
                identityVersion: baseRecord.identityVersion,
                resourceUUID: baseRecord.resourceUUID,
                resourceGeneration: baseRecord.resourceGeneration,
                projectResourceUUID: baseRecord.projectResourceUUID,
                projectGeneration: baseRecord.projectGeneration,
                providerGeneration: baseRecord.providerGeneration,
                fencingToken: baseRecord.fencingToken
            )
            try store.ownership.upsert(record)
            await state.setBinding(
                try LifecycleResourceBinding(
                    record: record,
                    identity: identity,
                    providerID: context.plan.providerID
                )
            )
        }
        let marksHealthyRevision = node.action == .promote ||
            (context.plan.command == .rollback &&
                node.action == .verify &&
                node.preconditions.contains(where: {
                    $0.kind == "rollback-restored-revision"
                })) ||
            (context.plan.command != .update &&
                node.action == .verify &&
                node.postconditions.contains(where: {
                    $0.kind == "probe-readiness" ||
                        $0.kind == "dependency-ready"
                })) ||
            (node.action == .start &&
                context.plan.command != .update &&
                desiredForNode?.probes.startup == nil &&
                desiredForNode?.probes.readiness == nil)
        if marksHealthyRevision {
            try await markHealthyRevision(
                node: node,
                context: context,
                identity: identity,
                observedAt: now
            )
        }
        if node.action == .delete || node.action == .retire {
            await state.removeBinding(resourceUUID: node.resourceUUID)
        }
        try store.observedStates.saveSnapshot(
            snapshotID: HostwrightResourceUUID.generate(),
            projectID: context.plan.projectID,
            observedState: observed,
            runtimeAdapter: context.plan.providerID.rawValue,
            parserVersion: "phase04-lifecycle-v1",
            rawOutputHash: observationSHA256,
            redactedSummary: "Lifecycle node \(node.key) verified.",
            observedAt: now
        )
    }

    func markHealthyRevision(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        identity: RuntimeServiceIdentity,
        observedAt: String,
        desiredService: DesiredRuntimeService? = nil
    ) async throws {
        guard let current = try store.ownership.loadAll().first(where: {
            $0.resourceUUID == node.resourceUUID &&
                RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) ==
                    context.plan.providerID
        }) else {
            throw StateStoreError.invalidRecord(
                "Verified healthy revision is missing exact ownership state."
            )
        }
        let resolvedDesiredService = if let desiredService {
            desiredService
        } else {
            await state.desiredService(for: node.key)
        }
        var metadata = try lifecycleOwnershipMetadataJSON(
            identity: identity,
            desiredService: resolvedDesiredService,
            healthy: true,
            capabilitySHA256: context.plan.capabilitySHA256,
            planSHA256: context.plan.planSHA256
        )
        if let authority = try OwnershipAuthorityMetadata.decode(
            from: current.metadataJSONRedacted
        ) {
            try authority.validate(for: current)
            metadata = try OwnershipAuthorityMetadata.encode(
                authority,
                into: metadata
            )
        }
        try store.ownership.upsert(
            OwnershipRecord(
                id: current.id,
                resourceIdentifier: current.resourceIdentifier,
                resourceType: current.resourceType,
                projectID: current.projectID,
                serviceName: current.serviceName,
                runtimeAdapter: current.runtimeAdapter,
                createdAt: current.createdAt,
                observedAt: observedAt,
                cleanupEligible: current.cleanupEligible,
                metadataJSONRedacted: metadata,
                identityVersion: current.identityVersion,
                resourceUUID: current.resourceUUID,
                resourceGeneration: current.resourceGeneration,
                projectResourceUUID: current.projectResourceUUID,
                projectGeneration: current.projectGeneration,
                providerGeneration: current.providerGeneration,
                fencingToken: current.fencingToken
            )
        )
    }

    func releaseResourceFenceIfNeeded(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        observedOwnership: RuntimeInventoryOwnershipEvidence? = nil
    ) async throws {
        guard node.action != .create,
              node.action != .delete,
              node.action != .retire,
              let binding = await state.binding(
                  resourceUUID: node.resourceUUID,
                  resourceIdentifier: node.resourceIdentifier
              ),
              let current = try store.ownership.loadAll().first(where: {
                  $0.resourceUUID == binding.resourceUUID
              }),
              current.fencingToken == context.fencingToken,
              binding.currentFencingToken != context.fencingToken else {
            return
        }
        if context.plan.providerID == .appleContainerization,
           let observedOwnership,
           exactOwnership(observedOwnership, node: node, plan: context.plan, binding: binding),
           observedOwnership.fencingToken == context.fencingToken {
            return
        }
        guard try store.ownership.advanceFencingToken(
            resourceIdentifier: binding.resourceIdentifier,
            runtimeAdapter: current.runtimeAdapter,
            expectedResourceUUID: binding.resourceUUID,
            expectedFencingToken: context.fencingToken,
            newFencingToken: binding.currentFencingToken,
            observedAt: hostwrightTimestamp()
        ) != nil else {
            throw StateStoreError.invalidRecord(
                "Lifecycle operation fence could not be released to the verified resource fence."
            )
        }
    }
}

struct LifecycleOwnershipMetadata: Codable {
    let schemaVersion: Int
    let projectName: String
    let serviceName: String
    let instanceName: String?
    let healthy: Bool
    let desiredSpecificationJSONRedacted: String
    let revisionSHA256: String
    let capabilitySHA256: String
    let planSHA256: String

    var identity: RuntimeServiceIdentity {
        RuntimeServiceIdentity(
            projectName: projectName,
            serviceName: serviceName,
            instanceName: instanceName
        )
    }
}

private func lifecycleOwnershipMetadataJSON(
    identity: RuntimeServiceIdentity,
    desiredService: DesiredRuntimeService?,
    healthy: Bool,
    capabilitySHA256: String,
    planSHA256: String
) throws -> String {
    guard let desiredService,
          desiredService.identity == identity else {
        throw StateStoreError.invalidRecord(
            "Lifecycle ownership metadata requires the exact desired service identity."
        )
    }
    let metadata = LifecycleOwnershipMetadata(
        schemaVersion: 1,
        projectName: identity.projectName,
        serviceName: identity.serviceName,
        instanceName: identity.instanceName,
        healthy: healthy,
        desiredSpecificationJSONRedacted:
            try LifecycleRevisionCodec.redactedDesiredJSON(for: desiredService),
        revisionSHA256: try LifecycleRevisionCodec.revisionSHA256(for: desiredService),
        capabilitySHA256: capabilitySHA256,
        planSHA256: planSHA256
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(metadata)
    guard let json = String(data: data, encoding: .utf8) else {
        throw StateStoreError.invalidRecord(
            "Lifecycle ownership metadata could not be encoded."
        )
    }
    return json
}

func lifecycleOwnershipMetadata(
    from record: OwnershipRecord
) -> LifecycleOwnershipMetadata? {
    guard let data = record.metadataJSONRedacted.data(using: .utf8),
          let metadata = try? JSONDecoder().decode(
              LifecycleOwnershipMetadata.self,
              from: data
          ),
          metadata.schemaVersion == 1,
          metadata.capabilitySHA256.range(
              of: "^[a-f0-9]{64}$",
              options: .regularExpression
          ) != nil,
          metadata.planSHA256.range(
              of: "^[a-f0-9]{64}$",
              options: .regularExpression
          ) != nil,
          metadata.revisionSHA256.range(
              of: "^[a-f0-9]{64}$",
              options: .regularExpression
          ) != nil else {
        return nil
    }
    return metadata
}
