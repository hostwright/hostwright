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
    func observe(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaObservation {
        if context.direction == .forward,
           case .noEffect(let summary) = await state.specialEvidence(for: node.key),
           summary.hasPrefix("Rollout progress deadline") {
            return .noEffect(
                LifecycleNodeVerification(
                    observationSHA256: nil,
                    summaryRedacted: summary
                )
            )
        }
        do {
            if context.direction == .forward,
               case .noEffect(let summary) = await state.specialEvidence(for: node.key),
               summary == lifecycleSchedulerActivationRejected {
                try await releaseResourceFenceIfNeeded(node: node, context: context)
                return .noEffect(LifecycleNodeVerification(observationSHA256: nil, summaryRedacted: summary))
            }
            var desired = await state.desiredStateSnapshot()
            if node.action == .create {
                let identity = await state.identity(
                    for: node,
                    projectName: context.plan.projectName
                )
                var hints = desired.ownedResourceHints.filter {
                    $0.resourceIdentifier != node.resourceIdentifier &&
                        $0.ownership?.resourceUUID != node.resourceUUID
                }
                hints.append(
                    RuntimeOwnedResourceHint(
                        resourceIdentifier:
                            node.resourceIdentifier ??
                            identity.managedResourceIdentifier,
                        identity: identity,
                        identityVersion:
                            RuntimeManagedResourceIdentity.currentVersion,
                        ownership: RuntimeInventoryOwnershipEvidence(
                            resourceUUID: node.resourceUUID,
                            projectUUID:
                                context.plan.projectResourceUUID,
                            resourceGeneration:
                                node.resourceGeneration,
                            projectGeneration:
                                context.plan.projectGeneration,
                            providerID: context.plan.providerID,
                            providerGeneration:
                                context.plan.providerGeneration,
                            fencingToken: context.fencingToken
                        )
                    )
                )
                desired = DesiredRuntimeState(
                    projectName: desired.projectName,
                    networks: desired.networks,
                    services: desired.services,
                    ownedResourceHints: hints.sorted {
                        $0.resourceIdentifier <
                            $1.resourceIdentifier
                    }
                )
            } else if context.plan.providerID == .appleContainerization {
                desired = try await nativeObservationDesiredState(
                    desired, node: node, context: context
                )
            }
            let inventory = try await adapter.inventory()
            let observed = try await adapter.observe(desiredState: desired)
            guard observed.adapterMetadata?.providerID == context.plan.providerID,
                  observed.capabilitySHA256 == context.plan.capabilitySHA256 else {
                return .ambiguous(
                    LifecycleNodeVerification(
                        observationSHA256: inventory.semanticSHA256,
                        summaryRedacted: "Runtime provider identity or capability changed during postcondition observation."
                    )
                )
            }
            await state.replaceObservedState(observed)
            let identity = await state.identity(for: node, projectName: context.plan.projectName)
            let matches = observed.services.filter {
                $0.identity == identity &&
                    $0.resourceIdentifier == node.resourceIdentifier
            }
            let containers = inventory.containers.filter {
                $0.ownership?.resourceUUID == node.resourceUUID ||
                    $0.name == node.resourceIdentifier ||
                    $0.runtimeID == node.resourceIdentifier
            }
            let binding = await state.binding(
                resourceUUID: node.resourceUUID,
                resourceIdentifier: node.resourceIdentifier
            )
            let exactContainer = containers.count == 1 &&
                exactOwnership(
                    containers[0].ownership,
                    node: node,
                    plan: context.plan,
                    binding: binding
                )
                ? containers[0]
                : nil
            let verification = LifecycleNodeVerification(
                observationSHA256: inventory.semanticSHA256,
                summaryRedacted: "\(identity.displayName):\(matches.first?.lifecycleState.rawValue ?? "missing")"
            )
            if lifecycleDeleteTargetStillPresent(
                node: node,
                containers: containers
            ) {
                return .noEffect(verification)
            }
            if node.action == .runHook ||
                isCompletionAwareStart(node) ||
                (node.action == .verify && probeKind(for: node) != nil) {
                let special = try await recoveredSpecialEvidence(
                    node: node,
                    context: context,
                    desiredService: await state.desiredService(for: node.key)
                )
                guard exactContainer != nil,
                      matches.count == 1 else {
                    return .ambiguous(
                        LifecycleNodeVerification(
                            observationSHA256: inventory.semanticSHA256,
                            summaryRedacted:
                                "Special lifecycle operation lost exact runtime ownership."
                        )
                    )
                }
                switch special {
                case .satisfied(let summary):
                    if isCompletionAwareStart(node),
                       matches[0].lifecycleState != .exited {
                        return .ambiguous(
                            LifecycleNodeVerification(
                                observationSHA256: inventory.semanticSHA256,
                                summaryRedacted:
                                    "Completion-aware start returned success but structured runtime state did not prove process exit."
                            )
                        )
                    }
                    let specialVerification = LifecycleNodeVerification(
                        observationSHA256: inventory.semanticSHA256,
                        summaryRedacted: summary
                    )
                    try await persistVerifiedProjection(
                        node: node,
                        context: context,
                        identity: identity,
                        exactContainer: exactContainer,
                        observed: observed,
                        observationSHA256: inventory.semanticSHA256
                    )
                    try await releaseResourceFenceIfNeeded(
                        node: node,
                        context: context,
                        observedOwnership: exactContainer?.ownership
                    )
                    return .satisfied(specialVerification)
                case .noEffect(let summary):
                    try await releaseResourceFenceIfNeeded(
                        node: node,
                        context: context,
                        observedOwnership: exactContainer?.ownership
                    )
                    return .noEffect(
                        LifecycleNodeVerification(
                            observationSHA256: inventory.semanticSHA256,
                            summaryRedacted: summary
                        )
                    )
                case .ambiguous(let summary):
                    return .ambiguous(
                        LifecycleNodeVerification(
                            observationSHA256: inventory.semanticSHA256,
                            summaryRedacted: summary
                        )
                    )
                }
            }
            if postconditionSatisfied(
                node: node,
                exactContainer: exactContainer,
                observedService: matches.first,
                desiredService: await state.desiredService(for: node.key)
            ) {
                if context.plan.command == .update,
                   node.action == .promote {
                    do {
                        try validateRolloutDependencies(
                            node: node,
                            desiredState: desired,
                            observedState: observed
                        )
                        try await validatePromotionEvidence(
                            node: node,
                            context: context,
                            observedState: observed
                        )
                    } catch {
                        return .noEffect(
                            LifecycleNodeVerification(
                                observationSHA256: inventory.semanticSHA256,
                                summaryRedacted:
                                    "Rollout promotion postcondition lacks current exact health proof."
                            )
                        )
                    }
                }
                try reconcileNetworkPorts(
                    node: node,
                    context: context,
                    inventory: inventory
                )
                try await reconcileNetworkAttachments(
                    node: node,
                    context: context,
                    inventory: inventory
                )
                try await persistVerifiedProjection(
                    node: node,
                    context: context,
                    identity: identity,
                    exactContainer: exactContainer,
                    observed: observed,
                    observationSHA256: inventory.semanticSHA256
                )
                try await releaseResourceFenceIfNeeded(
                    node: node, context: context,
                    observedOwnership: exactContainer?.ownership
                )
                return .satisfied(verification)
            }
            if noEffectObserved(
                node: node,
                exactContainer: exactContainer,
                observedService: matches.first,
                collisionCount: containers.count
            ) {
                try await releaseResourceFenceIfNeeded(
                    node: node, context: context,
                    observedOwnership: exactContainer?.ownership
                )
                return .noEffect(verification)
            }
            if containers.count > 1 ||
                (containers.count == 1 && exactContainer == nil) ||
                matches.count > 1 {
                return .ambiguous(verification)
            }
            return .effectPresent(verification)
        } catch {
            return .ambiguous(
                LifecycleNodeVerification(
                    observationSHA256: nil,
                    summaryRedacted: RuntimeRedactionPolicy.default.redact(String(describing: error))
                )
            )
        }
    }

    private func nativeObservationDesiredState(
        _ desired: DesiredRuntimeState,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async throws -> DesiredRuntimeState {
        guard let group = try store.operationGroups.load(id: context.groupID),
              group.status == .active,
              group.groupKind == "lifecycle-v1",
              group.projectID == context.plan.projectID,
              group.operationID == context.operationID,
              group.planHash == context.plan.planSHA256,
              group.plannedActionType == context.plan.command.rawValue,
              group.fencingToken == context.fencingToken,
              let owner = context.leaseOwner,
              group.lockOwner == owner,
              let expiry = group.lockExpiresAt,
              let expiryDate = ISO8601DateFormatter().date(from: expiry),
              expiryDate > Date(timeIntervalSince1970: Double(nowMilliseconds()) / 1_000),
              try LifecyclePersistedIntentCodec.decode(group.intentJSONRedacted) == context.plan,
              let planned = context.plan.nodes.first(where: { $0.key == node.key }) else {
            throw StateStoreError.invalidRecord(
                "SDK postcondition observation requires the exact confirmed node and active finite operation lease."
            )
        }
        let authorizedNode: LifecyclePlanNode
        if context.direction == .forward {
            authorizedNode = planned
        } else if let compensation = planned.compensation {
            authorizedNode = try LifecyclePlanNode(
                key: planned.key, action: compensation.action,
                serviceName: planned.serviceName,
                resourceIdentifier: planned.resourceIdentifier,
                resourceUUID: planned.resourceUUID,
                resourceGeneration: planned.resourceGeneration,
                fencingToken: planned.fencingToken,
                preconditions: compensation.preconditions,
                postconditions: [], timeoutSeconds: compensation.timeoutSeconds,
                desiredSpecificationJSONRedacted: planned.desiredSpecificationJSONRedacted
            )
        } else {
            throw StateStoreError.invalidRecord(
                "SDK compensation observation requires the exact configured inverse action."
            )
        }
        guard node == authorizedNode else {
            throw StateStoreError.invalidRecord(
                "SDK postcondition observation cannot change the confirmed resource action or scope."
            )
        }
        guard let binding = await state.binding(
            resourceUUID: node.resourceUUID,
            resourceIdentifier: node.resourceIdentifier
        ) else { return desired }
        let records = try store.ownership.loadAll().filter {
            ($0.resourceUUID == node.resourceUUID || $0.resourceIdentifier == node.resourceIdentifier) &&
                RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) == context.plan.providerID
        }
        let hints = desired.ownedResourceHints.filter {
            $0.ownership?.resourceUUID == node.resourceUUID || $0.resourceIdentifier == node.resourceIdentifier
        }
        guard binding.resourceUUID == node.resourceUUID,
              binding.resourceIdentifier == node.resourceIdentifier,
              binding.resourceGeneration == node.resourceGeneration,
              binding.projectResourceUUID == context.plan.projectResourceUUID,
              binding.projectGeneration == context.plan.projectGeneration,
              binding.providerID == context.plan.providerID,
              binding.providerGeneration == context.plan.providerGeneration,
              binding.identity.projectName == context.plan.projectName,
              node.serviceName == binding.identity.serviceName || node.serviceName == binding.identity.displayName,
              records.count == 1, let current = records.first,
              current.resourceType == "container", current.cleanupEligible,
              current.projectID == context.plan.projectID,
              current.serviceName == binding.identity.serviceName,
              current.identityVersion == binding.identityVersion,
              current.resourceIdentifier == binding.resourceIdentifier,
              current.resourceUUID == binding.resourceUUID,
              current.resourceGeneration == binding.resourceGeneration,
              current.projectResourceUUID == binding.projectResourceUUID,
              current.projectGeneration == binding.projectGeneration,
              current.providerGeneration == binding.providerGeneration,
              hints.count == 1, let hint = hints.first,
              hint.identity == binding.identity,
              hint.identityVersion == binding.identityVersion,
              hint.resourceIdentifier == binding.resourceIdentifier,
              hint.ownership == binding.ownershipEvidence,
              hint.authorizedAlternateOwnership == nil else {
            throw StateStoreError.invalidRecord(
                "SDK postcondition observation requires one exact UUID-backed resource binding."
            )
        }
        let authority = try OwnershipAuthorityMetadata.decode(from: current.metadataJSONRedacted)
        try authority?.validate(for: current)
        if current.fencingToken == binding.currentFencingToken,
           current.fencingToken != context.fencingToken {
            return desired
        }
        guard current.fencingToken == context.fencingToken,
              let authority,
              authority.controllerID == OwnershipAuthorityRecord.lifecycleController,
              authority.operationGroupID == group.id,
              authority.leaseOwner == owner,
              authority.leaseExpiresAt == expiry,
              ((node.action == .delete || node.action == .retire) &&
                  authority.deletionTimestamp != nil && Set(authority.finalizers.map(\.state)) == [.releasing]) ||
                (node.action != .delete && node.action != .retire &&
                    authority.deletionTimestamp == nil && Set(authority.finalizers.map(\.state)) == [.active]) else {
            throw StateStoreError.invalidRecord(
                "SDK postcondition observation requires the exact bound lifecycle mutation authority."
            )
        }
        guard binding.currentFencingToken != context.fencingToken else { return desired }
        guard authority.handoffGeneration > 0 else {
            throw StateStoreError.invalidRecord("SDK observation fence handoff is not authenticated.")
        }
        let authorized = RuntimeOwnedResourceHint(
            resourceIdentifier: hint.resourceIdentifier, identity: hint.identity,
            identityVersion: hint.identityVersion, ownership: hint.ownership,
            authorizedAlternateOwnership: RuntimeInventoryOwnershipEvidence(
                resourceUUID: node.resourceUUID, projectUUID: context.plan.projectResourceUUID,
                resourceGeneration: node.resourceGeneration, projectGeneration: context.plan.projectGeneration,
                providerID: context.plan.providerID, providerGeneration: context.plan.providerGeneration,
                fencingToken: context.fencingToken
            )
        )
        return DesiredRuntimeState(
            projectName: desired.projectName, networks: desired.networks, services: desired.services,
            ownedResourceHints: desired.ownedResourceHints.map { $0 == hint ? authorized : $0 }
        )
    }

    private func recoveredSpecialEvidence(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        desiredService: DesiredRuntimeService?
    ) async throws -> LifecycleSpecialNodeEvidence {
        if let inMemory = await state.specialEvidence(for: node.key) {
            return inMemory
        }
        if node.action == .runHook {
            guard let (status, checkpoint) = try loadHookCheckpoint(
                node: node,
                context: context
            ) else {
                return .noEffect("No container hook execution checkpoint exists.")
            }
            switch status {
            case .succeeded:
                return .satisfied("Bounded container hook completed.")
            case .started:
                return .ambiguous(
                    "Container hook was interrupted after execution began."
                )
            case .failed where checkpoint.effectPossible:
                return .ambiguous(
                    checkpoint.diagnosticRedacted.isEmpty
                        ? "Container hook may have irreversible external effects."
                        : checkpoint.diagnosticRedacted
                )
            case .failed, .planned, .unsupported:
                return .noEffect(
                    checkpoint.diagnosticRedacted.isEmpty
                        ? "Container hook did not begin execution."
                        : checkpoint.diagnosticRedacted
                )
            }
        }
        if isCompletionAwareStart(node) {
            guard let (status, checkpoint) = try loadCompletionCheckpoint(
                node: node,
                context: context
            ) else {
                return .noEffect(
                    "No zero-exit completion checkpoint exists for the start operation."
                )
            }
            switch status {
            case .succeeded:
                return .satisfied(
                    "Completion-aware start observed a zero init-process exit."
                )
            case .started:
                return .ambiguous(
                    "Completion-aware start was interrupted before its exit status was durably recorded."
                )
            case .failed:
                return .ambiguous(
                    checkpoint.diagnosticRedacted.isEmpty
                        ? "Completion-aware start did not prove a zero init-process exit."
                        : checkpoint.diagnosticRedacted
                )
            case .planned, .unsupported:
                return .noEffect(
                    "Completion-aware start did not begin execution."
                )
            }
        }
        guard let kind = probeKind(for: node),
              let desiredService,
              let snapshot = try probeStore.loadLatest(
                  groupID: context.groupID,
                  resourceIdentifier: node.resourceIdentifier ?? ""
              ),
              let probeState = snapshot.state(for: kind) else {
            return .noEffect("No completed probe checkpoint exists.")
        }
        _ = try RuntimeProbeStateMachine.resumed(
            snapshot,
            probes: desiredService.probes,
            nowMilliseconds: nowMilliseconds()
        )
        switch probeState.phase {
        case .succeeded:
            return .satisfied("Checkpointed \(kind.rawValue) probe passed.")
        case .failed, .unavailable:
            return .noEffect(
                probeState.lastDiagnosticRedacted.isEmpty
                    ? "Checkpointed \(kind.rawValue) probe did not pass."
                    : probeState.lastDiagnosticRedacted
            )
        case .waiting, .executing, .succeeding, .failing:
            return .noEffect(
                "Checkpointed \(kind.rawValue) probe is resumable."
            )
        }
    }
}
