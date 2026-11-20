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

let lifecycleSchedulerActivationRejected =
    "Scheduler activation was rejected before runtime mutation."

struct LifecycleLiveEffects:
    LifecycleSagaEffects,
    LifecycleSagaCompensationVerifying
{
    let adapter: any RuntimeAdapter
    let state: LifecycleRuntimeExecutionState
    let store: SQLiteStateStore
    let probeStore: LifecycleProbeCheckpointStore
    let environment: CLIEnvironment
    let schedulerActivationValidator: @Sendable (LifecyclePlanNode) throws -> Void
    let interactiveExecutor: any LifecycleProbeInteractiveExecuting
    let probeNetworkClient: any LifecycleProbeNetworkRequesting
    let nowMilliseconds: @Sendable () -> Int64
    let sleepMilliseconds: @Sendable (Int64) async throws -> Void

    init(
        adapter: any RuntimeAdapter,
        state: LifecycleRuntimeExecutionState,
        store: SQLiteStateStore,
        probeStore: LifecycleProbeCheckpointStore,
        environment: CLIEnvironment,
        schedulerActivationValidator: @escaping @Sendable (LifecyclePlanNode) throws -> Void = { _ in
            throw RuntimeAdapterError.mutationUnavailableByPolicy(lifecycleSchedulerAuthorityUnavailableMessage)
        },
        interactiveExecutor: any LifecycleProbeInteractiveExecuting =
            AppleContainerLifecycleProbeInteractiveExecutor(),
        probeNetworkClient: any LifecycleProbeNetworkRequesting =
            SystemLifecycleProbeNetworkClient(),
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        sleepMilliseconds: @escaping @Sendable (Int64) async throws -> Void = {
            milliseconds in
            guard milliseconds > 0 else { return }
            try await Task.sleep(
                nanoseconds: UInt64(milliseconds) * 1_000_000
            )
        }
    ) {
        self.adapter = adapter
        self.state = state
        self.store = store
        self.probeStore = probeStore
        self.environment = environment
        self.schedulerActivationValidator = schedulerActivationValidator
        self.interactiveExecutor = interactiveExecutor
        self.probeNetworkClient = probeNetworkClient
        self.nowMilliseconds = nowMilliseconds
        self.sleepMilliseconds = sleepMilliseconds
    }

    func apply(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaApplyOutcome {
        if let failure = rolloutDeadlineFailure(node: node, context: context) {
            await state.recordSpecialEvidence(
                .noEffect(failure.diagnostic),
                for: node.key
            )
            return .failed(failure)
        }
        if node.action == .validate || node.action == .promote {
            return await applyRolloutGate(node: node, context: context)
        }
        if node.action == .verify {
            guard probeKind(for: node) != nil else {
                return .accepted
            }
            return await applyProbe(node: node, context: context)
        }
        do {
            var existingOwnershipWasBound = false
            if let binding = await state.binding(
                   resourceUUID: node.resourceUUID,
                   resourceIdentifier: node.resourceIdentifier
               ) {
                let current = try store.ownership.loadAll().first {
                    $0.resourceUUID == binding.resourceUUID &&
                        RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) ==
                            context.plan.providerID
                }
                guard let current else {
                    return .failed(
                        RuntimeNormalizedFailure(
                            category: .fencingConflict,
                            retryDisposition: .never,
                            recoveryDisposition: .none,
                            providerID: context.plan.providerID.rawValue,
                            providerVersion: "bound-generation-\(context.plan.providerGeneration)",
                            operationID: context.operationID,
                            diagnostic: "Ownership fencing changed before lifecycle mutation.",
                            guidance: "Stop and inspect the active operation and current fencing token."
                        )
                    )
                }
                existingOwnershipWasBound = true
                if current.fencingToken != context.fencingToken {
                    guard current.fencingToken == binding.currentFencingToken,
                          let advanced = try store.ownership.advanceFencingToken(
                              resourceIdentifier: binding.resourceIdentifier,
                              runtimeAdapter: current.runtimeAdapter,
                              expectedResourceUUID: binding.resourceUUID,
                              expectedFencingToken: binding.currentFencingToken,
                              newFencingToken: context.fencingToken,
                              observedAt: hostwrightTimestamp()
                          ) else {
                        return .failed(
                            RuntimeNormalizedFailure(
                                category: .fencingConflict,
                                retryDisposition: .never,
                                recoveryDisposition: .none,
                                providerID: context.plan.providerID.rawValue,
                                providerVersion: "bound-generation-\(context.plan.providerGeneration)",
                                operationID: context.operationID,
                                diagnostic: "Ownership fencing changed before lifecycle mutation.",
                                guidance: "Stop and inspect the active operation and current fencing token."
                            )
                        )
                    }
                    _ = advanced
                }
            }
            if node.action != .create || existingOwnershipWasBound {
                try await bindOwnershipMutationLease(
                    node: node,
                    context: context
                )
            }
            if node.action == .delete || node.action == .retire {
                try await markOwnershipDeleting(
                    node: node,
                    context: context
                )
            }
            if node.action == .runHook {
                return await applyHook(node: node, context: context)
            }
            let action = try await plannedAction(node, plan: context.plan)
            let confirmation = RuntimeMutationConfirmation(
                confirmed: true,
                reason: "Confirmed lifecycle plan",
                planHash: context.plan.planSHA256,
                manifestHash: context.plan.manifestSHA256,
                context: mutationContext(node: node, context: context)
            )
            try await persistNetworkPortIntent(
                action: action,
                node: node,
                context: context
            )
            try await persistNetworkAttachmentIntent(
                action: action,
                node: node,
                context: context
            )
            let imageContentLease =
                try await acquireImageContentLeaseIfNeeded(
                    action: action,
                    node: node,
                    context: context
                )
            defer {
                if let imageContentLease {
                    _ = try? store.contentCache.releaseLease(
                        id: imageContentLease.id,
                        expectedFencingToken:
                            imageContentLease.fencingToken,
                        releasedAt: hostwrightTimestamp()
                    )
                }
            }
            if action.requiresProcessCompletion {
                return await applyCompletionAwareStart(
                    action,
                    confirmation: confirmation,
                    node: node,
                    context: context
                )
            }
            do {
                try validateSchedulerActivation(action: action, node: node, fencingToken: context.fencingToken)
            } catch {
                await state.recordSpecialEvidence(.noEffect(lifecycleSchedulerActivationRejected), for: node.key)
                return .failed(normalizedSpecialFailure(error, context: context, effectPossible: false))
            }
            _ = try await executeWithActivationAuthority(action, confirmation: confirmation, node: node)
            return .accepted
        } catch let error as RuntimeActivationAuthorityRejection {
            await state.recordSpecialEvidence(.noEffect(lifecycleSchedulerActivationRejected), for: node.key)
            return .failed(normalizedSpecialFailure(error, context: context, effectPossible: false))
        } catch let error as RuntimeAdapterError {
            return .failed(
                RuntimeNormalizedFailure.normalize(
                    error,
                    providerID: context.plan.providerID.rawValue,
                    providerVersion: "bound-generation-\(context.plan.providerGeneration)",
                    operationID: context.operationID
                )
            )
        } catch {
            return .failed(
                RuntimeNormalizedFailure(
                    category: .ambiguousEffect,
                    retryDisposition: .safeAfterObservation,
                    recoveryDisposition: .reobserve,
                    providerID: context.plan.providerID.rawValue,
                    providerVersion: "bound-generation-\(context.plan.providerGeneration)",
                    operationID: context.operationID,
                    diagnostic: RuntimeRedactionPolicy.default.redact(String(describing: error)),
                    guidance: "Re-observe the exact owned resource before deciding whether to retry."
                )
            )
        }
    }

    func executeWithActivationAuthority(
        _ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation,
        node: LifecyclePlanNode
    ) async throws -> RuntimeEvent {
        let event = try await RuntimeActivationAuthority.$validator.withValue({
            try validateSchedulerActivation(action: action, node: node, fencingToken: confirmation.context?.fencingToken)
        }) {
            try await adapter.execute(action, confirmation: confirmation)
        }
        if environment.lifecycleScheduler != nil, action.kind != .create, let context = confirmation.context {
            try LifecycleSchedulerSession.reconcile(
                store: store, projectUUID: context.projectResourceUUID, providerID: context.providerID,
                inventory: await adapter.inventory(), resourceUUID: context.resourceUUID
            )
        }
        return event
    }

    func validateSchedulerActivation(
        action: PlannedRuntimeAction,
        node: LifecyclePlanNode, fencingToken: String? = nil
    ) throws {
        let activation: LifecyclePlanAction
        switch action.kind {
        case .create: activation = .create
        case .start: activation = .start
        case .restart: activation = .restart
        default: return
        }
        let activatingNode = try LifecyclePlanNode(
            key: node.key,
            action: activation,
            serviceName: node.serviceName,
            resourceIdentifier: node.resourceIdentifier,
            resourceUUID: node.resourceUUID,
            resourceGeneration: node.resourceGeneration,
            fencingToken: fencingToken ?? node.fencingToken,
            dependencies: [],
            preconditions: node.preconditions,
            postconditions: node.postconditions,
            timeoutSeconds: node.timeoutSeconds,
            compensation: nil,
            desiredSpecificationJSONRedacted: node.desiredSpecificationJSONRedacted
        )
        try schedulerActivationValidator(activatingNode)
    }

    private func bindOwnershipMutationLease(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async throws {
        guard let current = try store.ownership.loadAll().first(where: {
            $0.resourceUUID == node.resourceUUID &&
                $0.resourceIdentifier == node.resourceIdentifier &&
                RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) ==
                    context.plan.providerID
        }),
        current.fencingToken == context.fencingToken,
        let group = try store.operationGroups.load(id: context.groupID),
        group.status == .active,
        group.planHash == context.plan.planSHA256,
        group.fencingToken == context.fencingToken,
        group.lockOwner == context.leaseOwner,
        let groupOwner = group.lockOwner,
        let groupExpiry = group.lockExpiresAt else {
            throw StateStoreError.invalidRecord(
                "Lifecycle mutation requires the exact owned resource and active finite mutation lease."
            )
        }
        let prior = try OwnershipAuthorityMetadata.decode(
            from: current.metadataJSONRedacted
        )
        try prior?.validate(for: current)
        if let prior, prior.deletionTimestamp != nil {
            guard node.action == .delete || node.action == .retire,
                  Set(prior.finalizers.map(\.state)) == [.releasing] else {
                throw StateStoreError.invalidRecord(
                    "Lifecycle mutation found ownership already bound to deletion."
                )
            }
            if prior.operationGroupID == group.id,
               prior.leaseOwner == groupOwner,
               prior.leaseExpiresAt == groupExpiry {
                return
            }
            guard node.action == .delete, group.plannedActionType == "rm",
                  let priorID = prior.operationGroupID,
                  let previous = try store.operationGroups.load(id: priorID),
                  previous.groupKind == "lifecycle-v1",
                  previous.projectID == group.projectID,
                  previous.status == .failed,
                  previous.lockOwner == nil,
                  previous.lockExpiresAt == nil else {
                throw StateStoreError.invalidRecord(
                    "Lifecycle deletion retry requires a failed operation with no active lease."
                )
            }
        }
        if let prior,
           prior.operationGroupID == group.id,
           prior.leaseOwner == groupOwner,
           prior.leaseExpiresAt == groupExpiry {
            return
        }
        let handoffGeneration = (prior?.handoffGeneration ?? 0) +
            ((prior?.operationGroupID == group.id) ? 0 : 1)
        let bound = try OwnershipAuthorityRecord.lifecycle(
            ownership: current,
            operationGroup: group,
            finalizerState: prior?.deletionTimestamp == nil ? .active : .releasing,
            deletionTimestamp: prior?.deletionTimestamp,
            handoffGeneration: handoffGeneration
        )
        let metadata = try OwnershipAuthorityMetadata.encode(
            bound,
            into: current.metadataJSONRedacted
        )
        try store.ownership.upsert(
            OwnershipRecord(
                id: current.id,
                resourceIdentifier: current.resourceIdentifier,
                resourceType: current.resourceType,
                projectID: current.projectID,
                serviceName: current.serviceName,
                runtimeAdapter: current.runtimeAdapter,
                createdAt: current.createdAt,
                observedAt: hostwrightTimestamp(),
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

    private func markOwnershipDeleting(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async throws {
        guard let current = try store.ownership.loadAll().first(where: {
            $0.resourceUUID == node.resourceUUID &&
                $0.resourceIdentifier == node.resourceIdentifier &&
                RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) ==
                    context.plan.providerID
        }),
        current.fencingToken == context.fencingToken,
        let group = try store.operationGroups.load(id: context.groupID),
        group.status == .active,
        group.planHash == context.plan.planSHA256,
        group.fencingToken == context.fencingToken,
        group.lockOwner == context.leaseOwner else {
            throw StateStoreError.invalidRecord(
                "Lifecycle deletion requires the exact owned resource and active mutation lease."
            )
        }
        let prior = try OwnershipAuthorityMetadata.decode(
            from: current.metadataJSONRedacted
        )
        try prior?.validate(for: current)
        if let prior, prior.deletionTimestamp != nil {
            guard prior.operationGroupID == group.id,
                  Set(prior.finalizers.map(\.state)) == [.releasing] else {
                throw StateStoreError.invalidRecord(
                    "Lifecycle deletion found a different or terminal ownership finalizer."
                )
            }
            return
        }
        let deleting = try OwnershipAuthorityRecord.lifecycle(
            ownership: current,
            operationGroup: group,
            finalizerState: .releasing,
            deletionTimestamp: hostwrightTimestamp(),
            handoffGeneration: (prior?.handoffGeneration ?? 0) +
                ((prior?.operationGroupID == group.id) ? 0 : 1)
        )
        let metadata = try OwnershipAuthorityMetadata.encode(
            deleting,
            into: current.metadataJSONRedacted
        )
        try store.ownership.upsert(
            OwnershipRecord(
                id: current.id,
                resourceIdentifier: current.resourceIdentifier,
                resourceType: current.resourceType,
                projectID: current.projectID,
                serviceName: current.serviceName,
                runtimeAdapter: current.runtimeAdapter,
                createdAt: current.createdAt,
                observedAt: hostwrightTimestamp(),
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

    private func acquireImageContentLeaseIfNeeded(
        action: PlannedRuntimeAction,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async throws -> ContentCacheLeaseRecord? {
        guard action.kind == .create,
              let desired = action.desiredService,
              let lock = desired.imageLock,
              lock.providerID == context.plan.providerID else {
            return nil
        }
        let projection = try store.imageOwnership.load()
        guard let ownership = projection.record(
            forReference: lock.requestedReference,
            providerID: context.plan.providerID.rawValue
        ) ?? projection.records.first(where: {
            $0.providerID == context.plan.providerID.rawValue &&
                $0.digest == lock.descriptorDigest
        }),
        ownership.digest == lock.descriptorDigest,
        let ownershipOperationID =
            ownership.ownershipOperationID,
        let ownershipProofSHA256 =
            ownership.ownershipProofSHA256 else {
            return nil
        }
        guard let imageProvider =
                adapter as? any RuntimeImageLifecycleProviding else {
            throw HostwrightDiagnostic(
                code: .imageUnavailable,
                message:
                    "The selected provider cannot lease exact owned image content before creation."
            )
        }
        let capability =
            try await imageProvider.imageOperationCapabilities()
        let runtimeCapability = try await adapter.capabilitySnapshot()
        guard capability.providerID == context.plan.providerID,
              runtimeCapability.descriptor.providerID == context.plan.providerID,
              runtimeCapability.canonicalSHA256 ==
                context.plan.capabilitySHA256,
              capability.status(for: .inspect).state == .available,
              capability.status(for: .inspect).reason ==
                .implemented else {
            throw HostwrightDiagnostic(
                code: .imageUnavailable,
                message:
                    "Exact image inspection is unavailable before lifecycle creation."
            )
        }
        let timestamp = hostwrightTimestamp()
        var snapshot = try store.contentCache.snapshot(
            providerScope: context.plan.providerID.rawValue,
            currentTimestamp: timestamp,
            limit: ImageCacheLimits.maximumRecords
        )
        if snapshot.contents.first(where: {
            $0.digest == lock.descriptorDigest
        }) == nil {
            let request = try RuntimeImageLifecycleRequest(
                operation: .inspect,
                operationID: UUID().uuidString.lowercased(),
                idempotencyKey: lifecycleTextSHA256(
                    [
                        "lifecycle-image-content-lease",
                        context.groupID,
                        node.key,
                        ownership.reference,
                        lock.descriptorDigest
                    ].joined(separator: "\u{1f}")
                ),
                capabilitySHA256:
                    capability.capabilitySHA256,
                sourceReferences: [ownership.reference]
            )
            let result =
                try await imageProvider.performImageOperation(
                    request,
                    confirmation: nil,
                    progress: { _ in }
                )
            guard let image = result.images.first(where: {
                $0.digest == lock.descriptorDigest
            }) else {
                throw HostwrightDiagnostic(
                    code: .imageConflict,
                    message:
                        "Exact owned image content disappeared before lifecycle creation."
                )
            }
            try store.contentCache.upsert(
                ContentCacheRecord(
                    providerScope:
                        context.plan.providerID.rawValue,
                    digest: lock.descriptorDigest,
                    kind: .runtimeImage,
                    sizeBytes: image.sizeBytes,
                    pinPolicy: .policyManaged,
                    createdAt: timestamp,
                    observedAt: timestamp,
                    lastUsedAt: timestamp
                )
            )
            snapshot = try store.contentCache.snapshot(
                providerScope:
                    context.plan.providerID.rawValue,
                currentTimestamp: timestamp,
                limit: ImageCacheLimits.maximumRecords
            )
        } else {
            let existingPinPolicy = snapshot.contents.first {
                $0.digest == lock.descriptorDigest
            }?.pinPolicy
            guard try store.contentCache.setPinPolicy(
                providerScope:
                    context.plan.providerID.rawValue,
                digest: lock.descriptorDigest,
                pinPolicy: existingPinPolicy == .operatorManaged
                    ? .operatorManaged
                    : .policyManaged,
                observedAt: timestamp
            ) else {
                throw HostwrightDiagnostic(
                    code: .imageConflict,
                    message:
                        "Owned image accounting changed before lifecycle creation."
                )
            }
        }
        let existing = snapshot.references.first(where: {
            $0.reference == ownership.reference
        })
        if let existing {
            guard existing.digest == ownership.digest,
                  existing.ownershipOperationID ==
                    ownershipOperationID,
                  existing.ownershipProofSHA256 ==
                    ownershipProofSHA256 else {
                throw HostwrightDiagnostic(
                    code: .imageConflict,
                    message:
                        "Owned image reference accounting changed before lifecycle creation."
                )
            }
        }
        try store.contentCache.saveReference(
            ContentCacheReferenceRecord(
                id: existing?.id ??
                    HostwrightResourceUUID.legacy(
                        kind: "image-content-reference",
                        identifier:
                            "\(ownership.providerID):\(ownership.reference)"
                    ),
                providerScope: ownership.providerID,
                reference: ownership.reference,
                digest: ownership.digest,
                ownershipOperationID: ownershipOperationID,
                ownershipProofSHA256:
                    ownershipProofSHA256,
                createdAt: existing?.createdAt ?? timestamp,
                observedAt: timestamp
            )
        )
        return try store.contentCache.acquireLease(
            providerScope: context.plan.providerID.rawValue,
            digest: lock.descriptorDigest,
            reference: ownership.reference,
            mode: .shared,
            ownerID: context.groupID,
            purpose: "lifecycle-create",
            acquiredAt: timestamp,
            expiresAt: hostwrightTimestampAdding(
                seconds: 86_400,
                to: timestamp
            )
        )
    }
}
