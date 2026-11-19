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

extension LifecyclePersistedRecoveryDriver {
    func makeRollbackPlan(
        sourcePlan: LifecyclePlan,
        sourceGroup: OperationGroupRecord,
        rollbackFencingToken: String,
        store: SQLiteStateStore,
        deadline: LifecycleRecoveryDeadline
    ) async throws -> LifecyclePlan {
        let steps = try store.operationGroupSteps.load(groupID: sourceGroup.id)
        let latestForward = Dictionary(
            grouping: steps.filter { $0.direction == .forward },
            by: \.stepKey
        ).compactMapValues(\.last)
        let alreadyCompensated = Set(
            Dictionary(
                grouping: steps.filter { $0.direction == .rollback },
                by: \.stepKey
            ).compactMap { key, values in
                values.last?.status == .succeeded ? key : nil
            }
        )
        let unsafeFailures = latestForward.values.filter {
            $0.status == .failed &&
                ($0.metadataJSONRedacted.contains(
                    RuntimeFailureCategory.partialEffect.rawValue
                ) ||
                    $0.metadataJSONRedacted.contains(
                        RuntimeFailureCategory.ambiguousEffect.rawValue
                    ))
        }
        guard unsafeFailures.isEmpty else {
            throw LifecyclePersistedRecoveryError.safeHold(
                LifecycleRecoverySafeHold(
                    reasonCode: .ambiguousEffect,
                    reason:
                        "A failed update step has ambiguous or partial effects.",
                    affectedNodeKeys: unsafeFailures.map(\.stepKey)
                )
            )
        }

        var completedEffectNodeKeys = Set(
            latestForward.compactMap { key, step in
                step.status == .succeeded &&
                    !alreadyCompensated.contains(key) ? key : nil
            }
        )
        var reobservedEffectNodeKeys: Set<String> = []
        let interruptedNodes = sourcePlan.nodes.filter {
            latestForward[$0.key]?.status == .started &&
                !alreadyCompensated.contains($0.key)
        }
        if !interruptedNodes.isEmpty {
            let runtime = try await recoveryRuntime(
                plan: sourcePlan,
                store: store,
                deadline: deadline
            )
            let context = LifecycleSagaContext(
                plan: sourcePlan,
                operationID: sourceGroup.operationID,
                groupID: sourceGroup.id,
                fencingToken: sourceGroup.fencingToken,
                attempt: 1
            )
            var observations: [LifecycleRecoveredForwardObservation] = []
            for node in interruptedNodes.sorted(by: { $0.key < $1.key }) {
                observations.append(
                    LifecycleRecoveredForwardObservation(
                        node: node,
                        observation: try await deadline.run {
                            await runtime.effects.observe(
                                node: node,
                                context: context
                            )
                        }
                    )
                )
            }
            var unsafeNodeKeys: [String] = []
            for recovered in observations {
                switch recovered.observation {
                case .satisfied:
                    completedEffectNodeKeys.insert(recovered.node.key)
                    reobservedEffectNodeKeys.insert(recovered.node.key)
                case .noEffect:
                    break
                case .effectPresent, .ambiguous:
                    unsafeNodeKeys.append(recovered.node.key)
                }
            }
            guard unsafeNodeKeys.isEmpty else {
                throw LifecyclePersistedRecoveryError.safeHold(
                    LifecycleRecoverySafeHold(
                        reasonCode: .ambiguousEffect,
                        reason:
                            "Interrupted update effects are ambiguous or partial; " +
                            "exact compensation cannot be proven.",
                        affectedNodeKeys: unsafeNodeKeys
                    )
                )
            }
        }
        let completedEffects = sourcePlan.nodes.filter {
            completedEffectNodeKeys.contains($0.key)
        }

        let sourceNodesByResourceUUID = Dictionary(
            grouping: sourcePlan.nodes,
            by: \.resourceUUID
        )
        let records = try store.ownership.loadAll().filter { record in
            guard record.projectID == sourcePlan.projectID,
                  record.projectResourceUUID == sourcePlan.projectResourceUUID,
                  record.projectGeneration == sourcePlan.projectGeneration,
                  record.providerGeneration == sourcePlan.providerGeneration,
                  RuntimeProviderBinding.stableID(for: record.runtimeAdapter) ==
                      sourcePlan.providerID,
                  let sourceNodes = sourceNodesByResourceUUID[
                    record.resourceUUID
                  ] else {
                return false
            }
            return sourceNodes.contains {
                $0.resourceIdentifier == record.resourceIdentifier &&
                    $0.resourceGeneration == record.resourceGeneration
            }
        }
        var exactOwnedUUIDs = Set(records.map(\.resourceUUID))
        exactOwnedUUIDs.formUnion(
            completedEffects.compactMap {
                $0.compensation?.action == .create ? $0.resourceUUID : nil
            }
        )
        let healthy = try sourcePlan.nodes
            .filter { $0.action == .retire }
            .map { node -> LifecycleHealthyRevisionRecord in
                let desired = try LifecycleRevisionCodec
                    .decodeRedactedDesiredJSON(
                        node.desiredSpecificationJSONRedacted
                    )
                let revisionSHA256 = try LifecycleRevisionCodec
                    .revisionSHA256(for: desired)
                guard node.preconditions.contains(where: {
                    $0.kind == "old-revision-verified-healthy" &&
                        $0.expectedValue == revisionSHA256
                }) else {
                    throw LifecyclePersistedRecoveryError.safeHold(
                        LifecycleRecoverySafeHold(
                            reasonCode: .healthyRevisionUnavailable,
                            reason:
                                "The persisted update does not prove the exact prior revision was healthy.",
                            affectedNodeKeys: [node.key]
                        )
                    )
                }
                return try LifecycleHealthyRevisionRecord(
                    service: desired,
                    resourceIdentifier: node.resourceIdentifier ?? "",
                    resourceUUID: node.resourceUUID,
                    resourceGeneration: node.resourceGeneration,
                    readinessVerified: true,
                    ownershipVerified:
                        exactOwnedUUIDs.contains(node.resourceUUID)
                )
            }
        let updatePlan = LifecycleUpdatePlan(
            projectName: sourcePlan.projectName,
            servicePlans: [],
            nodes: sourcePlan.nodes
        )
        let completedKeys = Set(completedEffects.map(\.idempotencyKey))
        let decision = try LifecycleRollbackPlanner().decide(
            updatePlan: updatePlan,
            healthyRevisions: healthy,
            proof: LifecycleRollbackProof(
                certainty: .exact,
                exactlyOwnedResourceUUIDs: exactOwnedUUIDs,
                exactlyInvertibleNodeIdempotencyKeys: completedKeys
            ),
            context: LifecycleRollbackRequestContext(
                request: .rollback,
                failure: .runtime,
                completedUpdateNodeIdempotencyKeys: completedKeys
            )
        )
        let rollbackNodes: [LifecyclePlanNode]
        switch decision {
        case .rollback(_, let resume):
            rollbackNodes = try resume.pendingNodes.map { node in
                try recoveryRollbackNode(
                    node,
                    sourceGroup: sourceGroup,
                    fencingToken: rollbackFencingToken,
                    reobservedEffectNodeKeys: reobservedEffectNodeKeys
                )
            }
        case .safeHold(let hold):
            throw LifecyclePersistedRecoveryError.safeHold(hold)
        case .resume:
            throw LifecyclePersistedRecoveryError.safeHold(
                LifecycleRecoverySafeHold(
                    reason:
                        "Rollback planning did not produce exact inverse actions.",
                    affectedNodeKeys: completedEffects.map(\.key)
                )
            )
        }
        return try LifecyclePlan(
            command: .rollback,
            projectID: sourcePlan.projectID,
            projectName: sourcePlan.projectName,
            projectResourceUUID: sourcePlan.projectResourceUUID,
            projectGeneration: sourcePlan.projectGeneration,
            providerID: sourcePlan.providerID,
            providerGeneration: sourcePlan.providerGeneration,
            manifestSHA256: sourcePlan.manifestSHA256,
            observationSHA256: sourcePlan.observationSHA256,
            capabilitySHA256: sourcePlan.capabilitySHA256,
            parallelism: 1,
            nodes: rollbackNodes
        )
    }

    private func recoveryRollbackNode(
        _ node: LifecyclePlanNode,
        sourceGroup: OperationGroupRecord,
        fencingToken: String,
        reobservedEffectNodeKeys: Set<String>
    ) throws -> LifecyclePlanNode {
        let sourceNodeKey = node.postconditions.first {
            $0.kind == "rollback-effect-verified"
        }?.subject
        let reobservationProof: [LifecyclePlanCondition]
        if let sourceNodeKey,
           reobservedEffectNodeKeys.contains(sourceNodeKey) {
            reobservationProof = [
                LifecyclePlanCondition(
                    kind: "rollback-source-effect-reobserved",
                    subject: sourceNodeKey,
                    expectedValue: sourceGroup.planHash
                )
            ]
        } else {
            reobservationProof = []
        }
        return try LifecyclePlanNode(
            key: node.key,
            action: node.action,
            serviceName: node.serviceName,
            resourceIdentifier: node.resourceIdentifier,
            resourceUUID: node.resourceUUID,
            resourceGeneration: node.resourceGeneration,
            fencingToken: fencingToken,
            dependencies: node.dependencies,
            preconditions: node.preconditions + [
                LifecyclePlanCondition(
                    kind: "rollback-source-group",
                    subject: sourceGroup.id,
                    expectedValue: sourceGroup.planHash
                )
            ] + reobservationProof,
            postconditions: node.postconditions,
            timeoutSeconds: node.timeoutSeconds,
            compensation: node.compensation,
            desiredSpecificationJSONRedacted:
                node.desiredSpecificationJSONRedacted
        )
    }

    func recoveryDesiredServices(
        plan: LifecyclePlan
    ) -> [String: DesiredRuntimeService] {
        var direct: [String: DesiredRuntimeService] = [:]
        var byResourceUUID: [String: DesiredRuntimeService] = [:]
        for node in plan.nodes {
            guard let desired = try? LifecycleRevisionCodec
                .decodeRedactedDesiredJSON(
                    node.desiredSpecificationJSONRedacted
                ) else {
                continue
            }
            direct[node.key] = desired
            byResourceUUID[node.resourceUUID] = desired
        }
        for node in plan.nodes where direct[node.key] == nil {
            if let desired = byResourceUUID[node.resourceUUID] {
                direct[node.key] = desired
            }
        }
        return direct
    }

    func recoveryBindings(
        records: [OwnershipRecord],
        plan: LifecyclePlan,
        desiredByNode: [String: DesiredRuntimeService]
    ) throws -> [LifecycleResourceBinding] {
        let identityByResourceUUID = Dictionary(
            plan.nodes.compactMap { node in
                desiredByNode[node.key].map {
                    (node.resourceUUID, $0.identity)
                }
            },
            uniquingKeysWith: { first, _ in first }
        )
        return try records.compactMap { record in
            guard record.projectID == plan.projectID,
                  RuntimeProviderBinding.stableID(for: record.runtimeAdapter) ==
                    plan.providerID,
                  let identity = lifecycleOwnershipMetadata(from: record)?.identity ??
                    identityByResourceUUID[record.resourceUUID] else {
                return nil
            }
            return try LifecycleResourceBinding(
                record: record,
                identity: identity,
                providerID: plan.providerID
            )
        }
    }

    func recoveryDesiredStateServices(
        plan: LifecyclePlan,
        desiredByNode: [String: DesiredRuntimeService]
    ) -> [DesiredRuntimeService] {
        var selected: [
            RuntimeServiceIdentity: (
                generation: Int,
                desired: DesiredRuntimeService
            )
        ] = [:]
        for node in plan.nodes {
            guard let desired = desiredByNode[node.key] else { continue }
            if node.resourceGeneration >=
                (selected[desired.identity]?.generation ?? 0) {
                selected[desired.identity] = (
                    node.resourceGeneration,
                    desired
                )
            }
        }
        return selected.values.map(\.desired).sorted {
            $0.identity.displayName < $1.identity.displayName
        }
    }
}
