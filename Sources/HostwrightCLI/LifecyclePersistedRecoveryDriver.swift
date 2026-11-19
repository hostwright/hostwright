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

func lifecycleRecoveryStateJSONRedacted(
    _ snapshot: DesiredStateRecoverySnapshot
) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(snapshot)
    guard let json = String(data: data, encoding: .utf8) else {
        throw StateStoreError.invalidRecord(
            "Lifecycle healthy desired-state recovery evidence is not UTF-8."
        )
    }
    return json
}

private func lifecycleRecoverySnapshot(
    from group: OperationGroupRecord
) throws -> DesiredStateRecoverySnapshot? {
    guard let json = try LifecyclePersistedIntentCodec
        .decodeRecoveryStateJSONRedacted(group.intentJSONRedacted) else {
        return nil
    }
    guard let data = json.data(using: .utf8),
          let snapshot = try? JSONDecoder().decode(
              DesiredStateRecoverySnapshot.self,
              from: data
          ),
          snapshot.schemaVersion ==
            DesiredStateRecoverySnapshot.currentSchemaVersion else {
        throw LifecyclePersistedRecoveryError.unavailable(
            "Persisted healthy desired-state recovery evidence is invalid."
        )
    }
    return snapshot
}

func lifecycleRestoreHealthyDesiredState(
    _ snapshot: DesiredStateRecoverySnapshot,
    sourcePlan: LifecyclePlan,
    store: SQLiteStateStore
) throws {
    guard snapshot.project.id == sourcePlan.projectID else {
        throw StateStoreError.invalidRecord(
            "Lifecycle recovery snapshot belongs to a different project."
        )
    }
    try store.desiredStates.restoreRecoverySnapshot(
        snapshot,
        expectedCurrentManifestHash: sourcePlan.manifestSHA256,
        expectedProjectResourceUUID: sourcePlan.projectResourceUUID,
        expectedMutationProvider: sourcePlan.providerID.rawValue,
        expectedProviderGeneration: sourcePlan.providerGeneration
    )
}

enum LifecyclePersistedRecoveryAction: String, Equatable, Sendable {
    case resume
    case rollback
}

struct LifecyclePersistedRecoveryRequest: Sendable {
    let action: LifecyclePersistedRecoveryAction
    let groupID: String
    let confirmationPlanSHA256: String
    let stateStoreConfiguration: StateStoreConfiguration
    let timeoutSeconds: Int

    init(
        action: LifecyclePersistedRecoveryAction,
        groupID: String,
        confirmationPlanSHA256: String,
        stateStoreConfiguration: StateStoreConfiguration,
        timeoutSeconds: Int
    ) {
        self.action = action
        self.groupID = groupID
        self.confirmationPlanSHA256 = confirmationPlanSHA256
        self.stateStoreConfiguration = stateStoreConfiguration
        self.timeoutSeconds = timeoutSeconds
    }
}

enum LifecyclePersistedRecoveryError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case confirmationMismatch
    case unavailable(String)
    case safeHold(LifecycleRecoverySafeHold)
}

struct LifecycleRecoveryRuntime {
    let adapter: any RuntimeAdapter
    let state: LifecycleRuntimeExecutionState
    let effects: LifecycleLiveEffects
}

struct LifecycleRecoveredForwardObservation: Sendable {
    let node: LifecyclePlanNode
    let observation: LifecycleSagaObservation
}

private struct LifecycleRecoveryDeadlineElapsed: Error {}

struct LifecycleRecoveryDeadline: Sendable {
    let uptimeNanoseconds: UInt64

    init(timeoutSeconds: Int) {
        uptimeNanoseconds =
            DispatchTime.now().uptimeNanoseconds +
            UInt64(timeoutSeconds) * 1_000_000_000
    }

    func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < uptimeNanoseconds else {
            throw LifecycleRecoveryDeadlineElapsed()
        }
        let remaining = uptimeNanoseconds - now
        return try await withThrowingTaskGroup(of: T.self) { tasks in
            tasks.addTask {
                try await operation()
            }
            tasks.addTask {
                try await Task.sleep(nanoseconds: remaining)
                throw LifecycleRecoveryDeadlineElapsed()
            }
            defer { tasks.cancelAll() }
            guard let first = try await tasks.next() else {
                throw LifecycleRecoveryDeadlineElapsed()
            }
            return first
        }
    }
}

struct LifecycleRecoveryDeadlineEffects:
    LifecycleSagaEffects,
    LifecycleSagaCompensationVerifying
{
    let base: any LifecycleSagaEffects
    let deadline: LifecycleRecoveryDeadline

    func apply(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaApplyOutcome {
        do {
            return try await deadline.run {
                await base.apply(node: node, context: context)
            }
        } catch {
            return .failed(timeoutFailure(context: context))
        }
    }

    func observe(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaObservation {
        await base.observe(node: node, context: context)
    }

    func compensate(
        compensation: LifecycleCompensation,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaCompensationOutcome {
        do {
            return try await deadline.run {
                await base.compensate(
                    compensation: compensation,
                    node: node,
                    context: context
                )
            }
        } catch {
            return .failed(timeoutFailure(context: context))
        }
    }

    func verifyCompensation(
        plan: LifecyclePlan,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaCompensationVerification {
        guard let verifier = base as? any LifecycleSagaCompensationVerifying else {
            return .safeHold(
                reasonCode:
                    LifecycleRecoverySafeHoldReason.restoredHealthFailed.rawValue,
                hintRedacted:
                    "The bounded recovery path cannot verify the restored revision. " +
                    "Preserve the exact recovery checkpoint."
            )
        }
        do {
            return try await deadline.run {
                await verifier.verifyCompensation(
                    plan: plan,
                    context: context
                )
            }
        } catch {
            return .safeHold(
                reasonCode:
                    LifecycleRecoverySafeHoldReason.restoredHealthFailed.rawValue,
                hintRedacted:
                    "The bounded restored-revision health verification timed out. " +
                    "Preserve the exact recovery checkpoint."
            )
        }
    }

    private func timeoutFailure(
        context: LifecycleSagaContext
    ) -> RuntimeNormalizedFailure {
        RuntimeNormalizedFailure(
            category: .cancelled,
            retryDisposition: .resumeFromCheckpoint,
            recoveryDisposition: .resume,
            providerID: context.plan.providerID.rawValue,
            providerVersion:
                "bound-generation-\(context.plan.providerGeneration)",
            operationID: context.operationID,
            diagnostic:
                "The confirmed recovery timeout expired before the operation completed.",
            guidance:
                "Resume the exact persisted recovery group after inspecting its checkpoint."
        )
    }
}

struct LifecyclePersistedRecoveryDriver {
    let environment: CLIEnvironment
    var schedulerActivationValidator: (@Sendable (LifecyclePlan, LifecyclePlanNode) throws -> Void)? = nil

    func execute(
        _ request: LifecyclePersistedRecoveryRequest
    ) throws -> LifecycleSagaExecutionResult {
        guard HostwrightResourceUUID.isValid(request.groupID),
              request.confirmationPlanSHA256.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil,
              (1...RuntimeCommandTimeout.maximumSeconds).contains(
                  request.timeoutSeconds
              ) else {
            throw LifecyclePersistedRecoveryError.invalidRequest(
                "Recovery requires an exact group UUID, plan SHA-256, and bounded timeout."
            )
        }
        let store = SQLiteStateStore(
            configuration: request.stateStoreConfiguration
        )
        guard let sourceGroup = try store.operationGroups.load(
            id: request.groupID.lowercased()
        ), sourceGroup.groupKind == "lifecycle-v1",
        sourceGroup.id == request.groupID.lowercased() else {
            throw LifecyclePersistedRecoveryError.unavailable(
                "The exact lifecycle operation group does not exist."
            )
        }
        guard sourceGroup.planHash == request.confirmationPlanSHA256 else {
            throw LifecyclePersistedRecoveryError.confirmationMismatch
        }
        guard LifecycleMutationCheckpointRecord(
            checkpoint: sourceGroup.checkpoint
        ) != nil else {
            throw LifecyclePersistedRecoveryError.safeHold(
                LifecycleRecoverySafeHold(
                    reasonCode: .planningIncomplete,
                    reason:
                        "The lifecycle checkpoint is not recognized by checkpoint contract v1. No runtime mutation was attempted.",
                    affectedNodeKeys: [],
                    operatorCommands: [
                        "hostwright recovery --state-db <path> --output json",
                        "hostwright inspect --output json"
                    ]
                )
            )
        }
        guard let persistedPlan = try? LifecyclePersistedIntentCodec.decode(
                  sourceGroup.intentJSONRedacted
              ),
              persistedPlan.planSHA256 == sourceGroup.planHash,
              persistedPlan.projectID == sourceGroup.projectID else {
            throw LifecyclePersistedRecoveryError.confirmationMismatch
        }
        if request.action != .rollback ||
            !isCompletedCompensation(sourceGroup) {
            try preflightImageTrustRecovery(
                plan: persistedPlan,
                store: store
            )
            try preflightImageSBOMRecovery(
                plan: persistedPlan,
                store: store
            )
            try preflightImageVulnerabilityRecovery(
                plan: persistedPlan,
                store: store
            )
            try preflightImageProvenanceRecovery(
                plan: persistedPlan,
                store: store
            )
        }
        let recoverySnapshot = try lifecycleRecoverySnapshot(
            from: sourceGroup
        )

        return try hostwrightWaitForAsync {
            try await executeWithinTimeout(
                request: request,
                sourceGroup: sourceGroup,
                persistedPlan: persistedPlan,
                recoverySnapshot: recoverySnapshot,
                store: store
            )
        }
    }

    private func executeWithinTimeout(
        request: LifecyclePersistedRecoveryRequest,
        sourceGroup: OperationGroupRecord,
        persistedPlan: LifecyclePlan,
        recoverySnapshot: DesiredStateRecoverySnapshot?,
        store: SQLiteStateStore
    ) async throws -> LifecycleSagaExecutionResult {
        let deadline = LifecycleRecoveryDeadline(
            timeoutSeconds: request.timeoutSeconds
        )
        do {
            return try await executeValidated(
                request: request,
                sourceGroup: sourceGroup,
                persistedPlan: persistedPlan,
                recoverySnapshot: recoverySnapshot,
                store: store,
                deadline: deadline
            )
        } catch is LifecycleRecoveryDeadlineElapsed {
            throw LifecyclePersistedRecoveryError.unavailable(
                "The confirmed recovery timeout expired before persisted execution could begin. No runtime mutation was attempted."
            )
        }
    }
}

extension LifecyclePersistedRecoveryDriver {
    private func executeValidated(
        request: LifecyclePersistedRecoveryRequest,
        sourceGroup: OperationGroupRecord,
        persistedPlan: LifecyclePlan,
        recoverySnapshot: DesiredStateRecoverySnapshot?,
        store: SQLiteStateStore,
        deadline: LifecycleRecoveryDeadline
    ) async throws -> LifecycleSagaExecutionResult {
        switch request.action {
        case .resume:
            let recoveryOwner = recoveryProcessOwner(for: .resume)
            guard sourceGroup.status == .interrupted ||
                    isExpiredActive(sourceGroup) ||
                    isHandedOffActive(
                        sourceGroup,
                        controllerID: "hostwright-recovery-resume"
                    ) ||
                    isFailedSafeHold(sourceGroup) else {
                throw LifecyclePersistedRecoveryError.unavailable(
                    "Only an interrupted lifecycle operation, its exact expired active lease, or an exact failed safe-hold can be resumed."
                )
            }
            let result = try await execute(
                plan: persistedPlan,
                operationID: sourceGroup.operationID,
                groupID: sourceGroup.id,
                fencingToken: sourceGroup.fencingToken,
                lockOwner: recoveryOwner,
                store: store,
                deadline: deadline,
                recoveryStateJSONRedacted:
                    try recoverySnapshot.map(
                        lifecycleRecoveryStateJSONRedacted
                    ),
                allowFailedSafeHoldResume: isFailedSafeHold(sourceGroup)
            )
            if let recoverySnapshot,
               result.status == .compensated ||
                persistedPlan.command == .rollback &&
                (result.status == .succeeded ||
                    result.status == .alreadySucceeded) {
                try lifecycleRestoreHealthyDesiredState(
                    recoverySnapshot,
                    sourcePlan: persistedPlan,
                    store: store
                )
            }
            return result
        case .rollback:
            let recoveryOwner = recoveryProcessOwner(for: .rollback)
            let handedOffActive = isHandedOffActive(
                sourceGroup,
                controllerID: "hostwright-recovery-rollback"
            )
            guard sourceGroup.status == .interrupted ||
                    sourceGroup.status == .failed ||
                    handedOffActive,
                  sourceGroup.rollbackAvailable,
                  persistedPlan.command == .update else {
                throw LifecyclePersistedRecoveryError.unavailable(
                    "Only an interrupted, failed, or exactly handed-off update with recorded inverses can be rolled back."
                )
            }
            if isCompletedCompensation(sourceGroup) {
                let adapter = try environment.runtimeAdapterForProvider(
                    persistedPlan.providerID
                )
                let capability = try await deadline.run {
                    try await adapter.capabilitySnapshot()
                }
                guard capability.descriptor.providerID ==
                        persistedPlan.providerID,
                      capability.canonicalSHA256 ==
                        persistedPlan.capabilitySHA256,
                      let project = try? store.desiredStates.loadProject(
                          id: persistedPlan.projectID
                      ),
                      project.resourceUUID ==
                        persistedPlan.projectResourceUUID,
                      project.providerGeneration ==
                        persistedPlan.providerGeneration,
                      RuntimeProviderBinding.stableID(
                          for: project.mutationProvider ?? ""
                      ) == persistedPlan.providerID else {
                    throw LifecyclePersistedRecoveryError.unavailable(
                        "Recovery provider, capability, or project generation is stale."
                    )
                }
                let inventory = try await deadline.run {
                    try await adapter.inventory()
                }
                _ = try lifecycleRestoreCompensatedOwnershipProjection(
                    store: store,
                    plan: persistedPlan,
                    operationFencingToken: sourceGroup.fencingToken,
                    inventory: inventory,
                    expectedPriorFencesByResourceUUID: [:],
                    allowObservedRuntimeFence: true
                )
                _ = try await recoveryRuntime(
                    plan: persistedPlan,
                    store: store,
                    deadline: deadline
                )
                if let recoverySnapshot {
                    try lifecycleRestoreHealthyDesiredState(
                        recoverySnapshot,
                        sourcePlan: persistedPlan,
                        store: store
                    )
                }
                return LifecycleSagaExecutionResult(
                    status: .alreadySucceeded,
                    operationID: sourceGroup.operationID,
                    groupID: sourceGroup.id,
                    planSHA256: sourceGroup.planHash,
                    checkpoint: "compensated-projection-verified",
                    completedNodeKeys: [],
                    recoveryHintRedacted:
                        "Completed compensation and exact ownership projection are verified."
                )
            }
            if handedOffActive {
                try claimRollbackHandoff(
                    sourceGroup: sourceGroup,
                    recoveryOwner: recoveryOwner,
                    store: store
                )
            }
            let rollbackFencingToken = HostwrightResourceUUID.legacy(
                kind: "lifecycle-rollback-fence",
                identifier: sourceGroup.id
            )
            let rollbackPlan = try await makeRollbackPlan(
                sourcePlan: persistedPlan,
                sourceGroup: sourceGroup,
                rollbackFencingToken: rollbackFencingToken,
                store: store,
                deadline: deadline
            )
            try rebindImageRecoveryAuthorizations(
                sourcePlan: persistedPlan,
                targetPlan: rollbackPlan,
                store: store
            )
            let rollbackOperationID = HostwrightResourceUUID.legacy(
                kind: "lifecycle-rollback-operation",
                identifier: "\(sourceGroup.id):\(rollbackPlan.planSHA256)"
            )
            let rollbackGroupID = HostwrightResourceUUID.legacy(
                kind: "lifecycle-rollback-group",
                identifier: "\(sourceGroup.id):\(rollbackPlan.planSHA256)"
            )
            let result = try await execute(
                plan: rollbackPlan,
                operationID: rollbackOperationID,
                groupID: rollbackGroupID,
                fencingToken: rollbackFencingToken,
                lockOwner: recoveryOwner,
                store: store,
                deadline: deadline,
                recoveryStateJSONRedacted:
                    try recoverySnapshot.map(
                        lifecycleRecoveryStateJSONRedacted
                    )
            )
            if result.status == .succeeded ||
                result.status == .alreadySucceeded,
               let recoverySnapshot {
                try lifecycleRestoreHealthyDesiredState(
                    recoverySnapshot,
                    sourcePlan: persistedPlan,
                    store: store
                )
            }
            return result
        }
    }
}
