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
    func recoveryProcessOwner(
        for action: LifecyclePersistedRecoveryAction
    ) -> String {
        let controller = switch action {
        case .resume: "hostwright-recovery-resume"
        case .rollback: "hostwright-recovery-rollback"
        }
        return "\(controller):\(HostwrightResourceUUID.generate())"
    }

    func isHandedOffActive(
        _ group: OperationGroupRecord,
        controllerID: String
    ) -> Bool {
        guard group.status == .active,
              group.lockOwner == controllerID,
              let expiry = group.lockExpiresAt,
              expiry > hostwrightTimestamp(),
              let data = group.metadataJSONRedacted.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let authority = object["localLeaseAuthority"]
                as? [String: Any],
              (authority["schemaVersion"] as? NSNumber)?.intValue == 1,
              authority["controllerID"] as? String == controllerID else {
            return false
        }
        return true
    }

    func claimRollbackHandoff(
        sourceGroup: OperationGroupRecord,
        recoveryOwner: String,
        store: SQLiteStateStore
    ) throws {
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let replacementExpiry = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(300)
        )
        let claim = try store.operationGroups.reclaimExpiredActive(
            groupID: sourceGroup.id,
            expectedPlanHash: sourceGroup.planHash,
            expectedFencingToken: sourceGroup.fencingToken,
            lockOwner: recoveryOwner,
            lockExpiresAt: replacementExpiry,
            currentTimestamp: timestamp
        )
        guard case .reclaimed(let claimed) = claim,
              claimed.lockOwner == recoveryOwner,
              claimed.lockExpiresAt == replacementExpiry else {
            throw LifecyclePersistedRecoveryError.unavailable(
                "The exact rollback handoff was claimed by another local recovery process."
            )
        }
        try store.operationGroups.finishExactLease(
            groupID: claimed.id,
            expectedFencingToken: claimed.fencingToken,
            expectedLockOwner: recoveryOwner,
            expectedLockExpiresAt: replacementExpiry,
            status: .interrupted,
            checkpoint: claimed.checkpoint,
            manualRecoveryHintRedacted:
                claimed.manualRecoveryHintRedacted,
            updatedAt: timestamp,
            metadataJSONRedacted: claimed.metadataJSONRedacted
        )
    }

    func rebindImageRecoveryAuthorizations(
        sourcePlan: LifecyclePlan,
        targetPlan: LifecyclePlan,
        store: SQLiteStateStore
    ) throws {
        guard sourcePlan.planSHA256 != targetPlan.planSHA256,
              sourcePlan.projectID == targetPlan.projectID,
              sourcePlan.manifestSHA256 == targetPlan.manifestSHA256 else {
            return
        }
        let copiedTypes = Set([
            "image.trust.lifecycle.authorized",
            "image.sbom.lifecycle.authorized",
            "image.vulnerability.lifecycle.authorized",
            "image.vulnerability.lifecycle.not-required",
            "image.provenance.lifecycle.authorized",
            "image.provenance.lifecycle.not-required"
        ])
        let allEvents = try store.events.loadAll()
        let existing = Set(allEvents.compactMap {
            event -> String? in
            guard copiedTypes.contains(event.type),
                  event.payloadJSONRedacted.contains(
                      targetPlan.planSHA256
                  ) else {
                return nil
            }
            return "\(event.type)\u{1f}\(event.payloadJSONRedacted)"
        })
        var rebound: [EventRecord] = []
        for event in allEvents where copiedTypes.contains(event.type) {
            guard let data =
                    event.payloadJSONRedacted.data(using: .utf8),
                  var object =
                    try JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                  object["planSHA256"] as? String ==
                    sourcePlan.planSHA256,
                  object["projectID"] as? String ==
                    sourcePlan.projectID else {
                continue
            }
            object["planSHA256"] = targetPlan.planSHA256
            let payload = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            let payloadText = String(
                decoding: payload,
                as: UTF8.self
            )
            guard !existing.contains(
                "\(event.type)\u{1f}\(payloadText)"
            ) else {
                continue
            }
            rebound.append(
                EventRecord(
                    id: UUID().uuidString.lowercased(),
                    timestamp: hostwrightTimestamp(),
                    severity: event.severity,
                    type: event.type,
                    source: "hostwright.recovery",
                    projectID: event.projectID,
                    serviceName: event.serviceName,
                    runtimeAdapter: event.runtimeAdapter,
                    message:
                        "Revalidated image authorization was bound to the exact recovery plan.",
                    payloadJSONRedacted: payloadText
                )
            )
        }
        if !rebound.isEmpty {
            try store.events.append(rebound)
        }
    }

    func isCompletedCompensation(
        _ group: OperationGroupRecord
    ) -> Bool {
        guard group.status == .failed,
              group.checkpoint == "compensated",
              let data = group.metadataJSONRedacted.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return false
        }
        return object["result"] as? String ==
            LifecycleSagaExecutionStatus.compensated.rawValue
    }

    func isFailedSafeHold(
        _ group: OperationGroupRecord
    ) -> Bool {
        guard group.status == .failed,
              group.checkpoint != "compensated",
              let data = group.metadataJSONRedacted.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return false
        }
        return object["result"] as? String ==
                LifecycleSagaExecutionStatus.safeHold.rawValue &&
            object["planSHA256"] as? String == group.planHash
    }

    func isExpiredActive(_ group: OperationGroupRecord) -> Bool {
        guard group.status == .active,
              let lockExpiresAt = group.lockExpiresAt,
              let expiry = ISO8601DateFormatter().date(from: lockExpiresAt) else {
            return false
        }
        return expiry <= Date()
    }

    func execute(
        plan: LifecyclePlan,
        operationID: String,
        groupID: String,
        fencingToken: String,
        lockOwner: String,
        store: SQLiteStateStore,
        deadline: LifecycleRecoveryDeadline,
        recoveryStateJSONRedacted: String? = nil,
        allowFailedSafeHoldResume: Bool = false
    ) async throws -> LifecycleSagaExecutionResult {
        let persistedGroup = try store.operationGroups.load(id: groupID)
        if let persistedGroup,
           persistedGroup.planHash != plan.planSHA256 {
            throw LifecycleSagaError.persistedPlanMismatch
        }
        let desiredByNode = recoveryDesiredServices(plan: plan)
        try lifecyclePersistDesiredImageLocks(
            plan: plan,
            desiredServicesByNodeKey: desiredByNode,
            groupID: groupID,
            store: store,
            timestamp: hostwrightTimestamp()
        )
        let runtime = try await recoveryRuntime(
            plan: plan,
            store: store,
            deadline: deadline
        )
        defer {
            if environment.lifecycleScheduler != nil,
               let inventory = try? hostwrightWaitForAsync({ try await runtime.adapter.inventory() }) {
                try? LifecycleSchedulerSession.reconcile(
                    store: store, projectUUID: plan.projectResourceUUID, providerID: plan.providerID,
                    inventory: inventory
                )
            }
        }
        return try await LifecycleSagaExecutor(
            store: store,
            effects: LifecycleRecoveryDeadlineEffects(
                base: runtime.effects,
                deadline: deadline
            ),
            validator: LifecycleLiveValidator(
                adapter: runtime.adapter,
                state: runtime.state,
                store: store,
                groupIdempotencyKey:
                    persistedGroup?.groupIdempotencyKey ?? plan.planSHA256
            ),
            recoveryStateJSONRedacted: recoveryStateJSONRedacted,
            finalizer: LifecycleOwnershipFinalizer(
                store: store,
                adapter: runtime.adapter
            )
        ).execute(
            plan: plan,
            operationID: operationID,
            groupID: groupID,
            fencingToken: fencingToken,
            lockOwner: lockOwner,
            groupIdempotencyKey:
                persistedGroup?.groupIdempotencyKey ?? plan.planSHA256,
            allowFailedSafeHoldResume: allowFailedSafeHoldResume
        )
    }

    func recoveryRuntime(
        plan: LifecyclePlan,
        store: SQLiteStateStore,
        deadline: LifecycleRecoveryDeadline
    ) async throws -> LifecycleRecoveryRuntime {
        let adapter = try environment.runtimeAdapterForProvider(plan.providerID)
        let capability = try await deadline.run {
            try await adapter.capabilitySnapshot()
        }
        guard capability.descriptor.providerID == plan.providerID,
              capability.canonicalSHA256 == plan.capabilitySHA256,
              let project = try? store.desiredStates.loadProject(id: plan.projectID),
              project.resourceUUID == plan.projectResourceUUID,
              project.providerGeneration == plan.providerGeneration,
              RuntimeProviderBinding.stableID(
                  for: project.mutationProvider ?? ""
              ) == plan.providerID else {
            throw LifecyclePersistedRecoveryError.unavailable(
                "Recovery provider, capability, or project generation is stale."
            )
        }

        let desiredByNode = recoveryDesiredServices(plan: plan)
        let records = try store.ownership.loadAll()
        let bindings = try recoveryBindings(
            records: records,
            plan: plan,
            desiredByNode: desiredByNode
        )
        let desiredServices = recoveryDesiredStateServices(
            plan: plan,
            desiredByNode: desiredByNode
        )
        var ownedResourceHints = bindings.map {
            RuntimeOwnedResourceHint(
                resourceIdentifier: $0.resourceIdentifier,
                identity: $0.identity,
                identityVersion: $0.identityVersion,
                ownership: $0.ownershipEvidence
            )
        }
        for node in plan.nodes where node.action == .create {
            guard let desired = desiredByNode[node.key] else { continue }
            ownedResourceHints.removeAll {
                $0.resourceIdentifier == node.resourceIdentifier ||
                    $0.ownership?.resourceUUID == node.resourceUUID
            }
            ownedResourceHints.append(
                RuntimeOwnedResourceHint(
                    resourceIdentifier:
                        node.resourceIdentifier ??
                        desired.identity.managedResourceIdentifier,
                    identity: desired.identity,
                    identityVersion:
                        RuntimeManagedResourceIdentity.currentVersion,
                    ownership: RuntimeInventoryOwnershipEvidence(
                        resourceUUID: node.resourceUUID,
                        projectUUID: plan.projectResourceUUID,
                        resourceGeneration: node.resourceGeneration,
                        projectGeneration: plan.projectGeneration,
                        providerID: plan.providerID,
                        providerGeneration: plan.providerGeneration,
                        fencingToken: node.fencingToken
                    )
                )
            )
        }
        let desiredState = DesiredRuntimeState(
            projectName: plan.projectName,
            services: desiredServices,
            ownedResourceHints: ownedResourceHints.sorted {
                $0.resourceIdentifier < $1.resourceIdentifier
            }
        )
        let observed = try await deadline.run {
            try await adapter.observe(desiredState: desiredState)
        }
        guard observed.adapterMetadata?.providerID == plan.providerID,
              observed.capabilitySHA256 == plan.capabilitySHA256 else {
            throw LifecyclePersistedRecoveryError.unavailable(
                "Recovery observation returned stale provider evidence."
            )
        }
        let state = LifecycleRuntimeExecutionState(
            projectID: plan.projectID,
            providerID: plan.providerID,
            capabilitySHA256: plan.capabilitySHA256,
            desiredState: desiredState,
            observedState: observed,
            bindings: bindings,
            desiredByNode: desiredByNode
        )
        let effects = LifecycleLiveEffects(
            adapter: adapter,
            state: state,
            store: store,
            probeStore: LifecycleProbeCheckpointStore(store: store),
            environment: environment,
            schedulerActivationValidator: { node in
                if let context = environment.lifecycleScheduler {
                    try LifecycleSchedulerSession.validateRecoveryActivation(
                        context: context, store: store, plan: plan, node: node, environment: environment
                    )
                } else if let schedulerActivationValidator {
                    try schedulerActivationValidator(plan, node)
                } else {
                    throw SchedulerAdmissionError.invalidBinding(field: "recovery-local-authority-unavailable")
                }
            }
        )
        return LifecycleRecoveryRuntime(
            adapter: adapter,
            state: state,
            effects: effects
        )
    }
}
