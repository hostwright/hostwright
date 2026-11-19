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
    func applyProbe(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaApplyOutcome {
        guard let targetKind = probeKind(for: node),
              let binding = await state.binding(
                  resourceUUID: node.resourceUUID,
                  resourceIdentifier: node.resourceIdentifier
              ),
              binding.resourceUUID == node.resourceUUID,
              binding.resourceGeneration == node.resourceGeneration,
              binding.projectResourceUUID == context.plan.projectResourceUUID,
              binding.projectGeneration == context.plan.projectGeneration,
              binding.providerID == context.plan.providerID,
              binding.providerGeneration == context.plan.providerGeneration,
              let desired = await state.desiredService(for: node.key),
              desired.identity == binding.identity else {
            await state.recordSpecialEvidence(
                .noEffect("Probe target is missing exact ownership evidence."),
                for: node.key
            )
            return .failed(
                specialFailure(
                    category: .fencingConflict,
                    context: context,
                    diagnostic: "Probe target is missing exact ownership evidence.",
                    guidance: "Re-observe the exact owned resource before retrying."
                )
            )
        }

        let capability: RuntimeCapabilitySnapshot
        do {
            capability = try await adapter.capabilitySnapshot()
            guard capability.descriptor.providerID == context.plan.providerID,
                  capability.canonicalSHA256 == context.plan.capabilitySHA256 else {
                throw LifecycleSpecialExecutionError.staleCapability
            }
        } catch {
            await state.recordSpecialEvidence(
                .noEffect("Probe capability snapshot changed before execution."),
                for: node.key
            )
            return .failed(
                normalizedSpecialFailure(
                    error,
                    context: context,
                    effectPossible: false
                )
            )
        }

        let executor = LifecycleProbeExecutor(
            binding: binding,
            desiredService: desired,
            capabilitySnapshot: capability,
            interactiveExecutor: interactiveExecutor,
            networkClient: probeNetworkClient,
            nowMilliseconds: nowMilliseconds
        )
        let start = probeNodeStartedAtMilliseconds(
            node: node,
            groupID: context.groupID
        ) ?? nowMilliseconds()
        let deadline = start + Int64(node.timeoutSeconds) * 1_000
        var snapshot: RuntimeProbeSnapshot
        do {
            if let persisted = try probeStore.loadLatest(
                groupID: context.groupID,
                resourceIdentifier: binding.resourceIdentifier
            ) {
                snapshot = try RuntimeProbeStateMachine.resumed(
                    persisted,
                    probes: desired.probes,
                    nowMilliseconds: nowMilliseconds()
                )
            } else {
                snapshot = RuntimeProbeStateMachine.initialSnapshot(
                    resourceIdentifier: binding.resourceIdentifier,
                    probes: desired.probes,
                    startedAtMilliseconds: nowMilliseconds()
                )
            }
            try saveProbeSnapshot(snapshot, node: node, context: context)
        } catch {
            await state.recordSpecialEvidence(
                .ambiguous("Persisted probe checkpoint could not be resumed safely."),
                for: node.key
            )
            return .failed(
                normalizedSpecialFailure(
                    error,
                    context: context,
                    effectPossible: true
                )
            )
        }

        while true {
            if Task.isCancelled {
                await state.recordSpecialEvidence(
                    .noEffect("Probe execution was cancelled."),
                    for: node.key
                )
                return .failed(
                    specialFailure(
                        category: .cancelled,
                        context: context,
                        diagnostic: "Probe execution was cancelled.",
                        guidance: "Resume the exact checkpointed probe operation.",
                        retry: .safeAfterObservation,
                        recovery: .resume
                    )
                )
            }
            let now = nowMilliseconds()
            guard now < deadline else {
                await state.recordSpecialEvidence(
                    .noEffect("Probe node exceeded its persisted deadline."),
                    for: node.key
                )
                return .failed(
                    specialFailure(
                        category: .timedOut,
                        context: context,
                        diagnostic: "Probe node exceeded its persisted deadline.",
                        guidance: "Inspect the last checkpointed probe result before retrying."
                    )
                )
            }

            let stableObservationSeconds = stableObservationSeconds(for: node)
            let requiredKinds = RuntimeProbeKind.allCases.filter { kind in
                guard desired.probes[kind] != nil else { return false }
                return stableObservationSeconds > 0 ||
                    kind == .startup || kind == targetKind
            }
            var pendingKind: RuntimeProbeKind?
            probeKinds: for kind in requiredKinds {
                guard let probeState = snapshot.state(for: kind) else {
                    continue
                }
                if probeState.phase == .unavailable {
                    return await terminalProbeFailure(
                        node: node,
                        context: context,
                        outcome: .unavailable,
                        diagnostic: probeState.lastDiagnosticRedacted
                    )
                }
                if probeState.phase == .failed {
                    if kind == .liveness {
                        switch await recoverLiveness(
                            node: node,
                            context: context,
                            desired: desired,
                            binding: binding,
                            deadlineMilliseconds: deadline
                        ) {
                        case .restarted:
                            snapshot = RuntimeProbeStateMachine.initialSnapshot(
                                resourceIdentifier: binding.resourceIdentifier,
                                probes: desired.probes,
                                startedAtMilliseconds: nowMilliseconds()
                            )
                            do {
                                try saveProbeSnapshot(
                                    snapshot,
                                    node: node,
                                    context: context
                                )
                            } catch {
                                await state.recordSpecialEvidence(
                                    .ambiguous(
                                        "Restart succeeded but the reset probe checkpoint could not be persisted."
                                    ),
                                    for: node.key
                                )
                                return .failed(
                                    normalizedSpecialFailure(
                                        error,
                                        context: context,
                                        effectPossible: true
                                    )
                                )
                            }
                            pendingKind = requiredKinds.first
                            break probeKinds
                        case .refused(let reason):
                            return await terminalProbeFailure(
                                node: node,
                                context: context,
                                outcome: .failed,
                                diagnostic: reason
                            )
                        case .ambiguous(let failure):
                            await state.recordSpecialEvidence(
                                .ambiguous(failure.diagnostic),
                                for: node.key
                            )
                            return .failed(failure)
                        }
                    }
                    return await terminalProbeFailure(
                        node: node,
                        context: context,
                        outcome: probeState.lastOutcome ?? .failed,
                        diagnostic: probeState.lastDiagnosticRedacted
                    )
                }
                if probeState.phase != .succeeded {
                    pendingKind = kind
                    break
                }
            }
            if pendingKind == nil, stableObservationSeconds > 0 {
                guard let stableSince = snapshot.stableSinceMilliseconds else {
                    return await terminalProbeFailure(
                        node: node,
                        context: context,
                        outcome: .failed,
                        diagnostic: "Stable rollout observation has no durable healthy-start checkpoint."
                    )
                }
                let stableDeadline = stableSince +
                    Int64(stableObservationSeconds) * 1_000
                let recurringKinds = [
                    RuntimeProbeKind.readiness,
                    .liveness
                ].filter { desired.probes[$0] != nil }
                if now >= stableDeadline {
                    pendingKind = recurringKinds.first { kind in
                        guard let state = snapshot.state(for: kind) else {
                            return true
                        }
                        return (state.lastAttemptAtMilliseconds ?? Int64.min) <
                            stableDeadline
                    }
                } else {
                    pendingKind = recurringKinds.first { kind in
                        guard let state = snapshot.state(for: kind) else {
                            return false
                        }
                        return now >= state.nextAttemptAtMilliseconds
                    }
                    if pendingKind == nil {
                        let nextProbe = recurringKinds.compactMap {
                            snapshot.state(for: $0)?.nextAttemptAtMilliseconds
                        }.min() ?? stableDeadline
                        let wait = min(
                            max(1, nextProbe - now),
                            max(1, stableDeadline - now),
                            250
                        )
                        do {
                            try await sleepMilliseconds(wait)
                            continue
                        } catch {
                            return await terminalProbeFailure(
                                node: node,
                                context: context,
                                outcome: .cancelled,
                                diagnostic: "Stable rollout observation wait was cancelled."
                            )
                        }
                    }
                }
            }
            guard let kind = pendingKind else {
                if targetKind == .liveness {
                    do {
                        try resetRestartPolicyAfterHealthyProbe(
                            desired: desired,
                            projectID: context.plan.projectID
                        )
                    } catch {
                        let failure = normalizedSpecialFailure(
                            error,
                            context: context,
                            effectPossible: true
                        )
                        await state.recordSpecialEvidence(
                            .ambiguous(failure.diagnostic),
                            for: node.key
                        )
                        return .failed(failure)
                    }
                }
                await state.recordSpecialEvidence(
                    .satisfied("Checkpointed \(targetKind.rawValue) probe passed."),
                    for: node.key
                )
                return .accepted
            }

            guard let current = snapshot.state(for: kind) else {
                return await terminalProbeFailure(
                    node: node,
                    context: context,
                    outcome: .unavailable,
                    diagnostic: "Probe checkpoint is missing the required state."
                )
            }
            let currentTime = nowMilliseconds()
            if currentTime < current.nextAttemptAtMilliseconds {
                let wait = min(
                    current.nextAttemptAtMilliseconds - currentTime,
                    deadline - currentTime,
                    250
                )
                do {
                    try await sleepMilliseconds(max(1, wait))
                    continue
                } catch {
                    return await terminalProbeFailure(
                        node: node,
                        context: context,
                        outcome: .cancelled,
                        diagnostic: "Probe wait was cancelled."
                    )
                }
            }

            do {
                let started = try RuntimeProbeStateMachine.markAttemptStarted(
                    kind: kind,
                    probes: desired.probes,
                    snapshot: snapshot,
                    nowMilliseconds: currentTime
                )
                snapshot = started.snapshot
                try saveProbeSnapshot(snapshot, node: node, context: context)
                let result = await executeProbe(
                    executor,
                    request: started.request,
                    deadlineMilliseconds: deadline
                )
                snapshot = try RuntimeProbeStateMachine.record(
                    result,
                    request: started.request,
                    probes: desired.probes,
                    snapshot: snapshot
                )
                try saveProbeSnapshot(snapshot, node: node, context: context)
                if result.outcome == .cancelled {
                    return await terminalProbeFailure(
                        node: node,
                        context: context,
                        outcome: .cancelled,
                        diagnostic: result.diagnosticRedacted
                    )
                }
            } catch {
                await state.recordSpecialEvidence(
                    .ambiguous("Probe state transition could not be checkpointed."),
                    for: node.key
                )
                return .failed(
                    normalizedSpecialFailure(
                        error,
                        context: context,
                        effectPossible: true
                    )
                )
            }
        }
    }

    private func executeProbe(
        _ executor: any RuntimeProbeExecuting,
        request: RuntimeProbeExecutionRequest,
        deadlineMilliseconds: Int64
    ) async -> RuntimeProbeAttemptResult {
        await withTaskGroup(of: RuntimeProbeAttemptResult.self) { group in
            group.addTask {
                await executor.executeProbe(request)
            }
            group.addTask {
                let remaining = max(1, deadlineMilliseconds - nowMilliseconds())
                do {
                    try await sleepMilliseconds(remaining)
                    return RuntimeProbeAttemptResult(
                        outcome: .timedOut,
                        completedAtMilliseconds: max(
                            deadlineMilliseconds,
                            nowMilliseconds()
                        ),
                        diagnosticRedacted: "Probe node deadline elapsed."
                    )
                } catch {
                    return RuntimeProbeAttemptResult(
                        outcome: .cancelled,
                        completedAtMilliseconds: nowMilliseconds(),
                        diagnosticRedacted: "Probe deadline wait was cancelled."
                    )
                }
            }
            let first = await group.next() ?? RuntimeProbeAttemptResult(
                outcome: .cancelled,
                completedAtMilliseconds: nowMilliseconds(),
                diagnosticRedacted: "Probe execution ended without a result."
            )
            group.cancelAll()
            return first
        }
    }

    private func terminalProbeFailure(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        outcome: RuntimeProbeAttemptOutcome,
        diagnostic: String
    ) async -> LifecycleSagaApplyOutcome {
        let category: RuntimeFailureCategory
        switch outcome {
        case .unavailable: category = .incompatible
        case .timedOut: category = .timedOut
        case .cancelled: category = .cancelled
        case .failed, .succeeded: category = .rejected
        }
        await state.recordSpecialEvidence(
            .noEffect(
                diagnostic.isEmpty
                    ? "Checkpointed probe did not satisfy its threshold."
                    : diagnostic
            ),
            for: node.key
        )
        return .failed(
            specialFailure(
                category: category,
                context: context,
                diagnostic: diagnostic.isEmpty
                    ? "Checkpointed probe did not satisfy its threshold."
                    : diagnostic,
                guidance: outcome == .cancelled
                    ? "Resume the exact checkpointed probe operation."
                    : "Inspect the checkpointed probe result and desired thresholds.",
                retry: outcome == .cancelled ? .safeAfterObservation : .never,
                recovery: outcome == .cancelled ? .resume : .none
            )
        )
    }

    private func saveProbeSnapshot(
        _ snapshot: RuntimeProbeSnapshot,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) throws {
        try probeStore.save(
            snapshot,
            groupID: context.groupID,
            fencingToken: context.fencingToken,
            serviceName: node.serviceName,
            updatedAt: hostwrightTimestamp()
        )
    }

    func hookCommand(
        node: LifecyclePlanNode,
        desired: DesiredRuntimeService
    ) throws -> [String] {
        let hookConditions = node.postconditions.filter {
            $0.kind == "hook-completed"
        }
        guard hookConditions.count == 1 else {
            throw LifecycleSpecialExecutionError.invalidHook
        }
        switch hookConditions[0].expectedValue {
        case "postStart":
            guard let command = desired.hooks.postStart else {
                throw LifecycleSpecialExecutionError.invalidHook
            }
            return command
        case "preStop":
            guard let command = desired.hooks.preStop else {
                throw LifecycleSpecialExecutionError.invalidHook
            }
            return command
        default:
            throw LifecycleSpecialExecutionError.invalidHook
        }
    }

    func normalizedSpecialFailure(
        _ error: any Error,
        context: LifecycleSagaContext,
        effectPossible: Bool
    ) -> RuntimeNormalizedFailure {
        if effectPossible {
            return specialFailure(
                category: .ambiguousEffect,
                context: context,
                diagnostic: RuntimeRedactionPolicy.default.redact(String(describing: error)),
                guidance: "Preserve the safe hold because container-side effects cannot be reversed.",
                retry: .safeAfterObservation,
                recovery: .reobserve
            )
        }
        let category: RuntimeFailureCategory
        switch error {
        case LifecycleSpecialExecutionError.staleCapability:
            category = .staleCapability
        case LifecycleSpecialExecutionError.unavailable:
            category = .incompatible
        case RuntimeInteractiveError.processTimedOut:
            category = .timedOut
        case RuntimeInteractiveError.processCancelled:
            category = .cancelled
        case RuntimeInteractiveError.inputBackpressureExceeded:
            category = .outputLimited
        default:
            category = .rejected
        }
        return specialFailure(
            category: category,
            context: context,
            diagnostic: RuntimeRedactionPolicy.default.redact(String(describing: error)),
            guidance: "Correct the exact rejected lifecycle operation before retrying."
        )
    }

    func specialFailure(
        category: RuntimeFailureCategory,
        context: LifecycleSagaContext,
        diagnostic: String,
        guidance: String,
        retry: RuntimeRetryDisposition = .never,
        recovery: RuntimeRecoveryDisposition = .none
    ) -> RuntimeNormalizedFailure {
        RuntimeNormalizedFailure(
            category: category,
            retryDisposition: retry,
            recoveryDisposition: recovery,
            providerID: context.plan.providerID.rawValue,
            providerVersion: "bound-generation-\(context.plan.providerGeneration)",
            operationID: context.operationID,
            diagnostic: diagnostic,
            guidance: guidance
        )
    }

    private func recoverLiveness(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        desired: DesiredRuntimeService,
        binding: LifecycleResourceBinding,
        deadlineMilliseconds: Int64
    ) async -> LifecycleLivenessRecovery {
        do {
            let restartPolicyKey = lifecycleRestartPolicyKey(
                for: desired.identity
            )
            let previous = try store.restartPolicies.load(
                projectID: context.plan.projectID,
                serviceName: restartPolicyKey
            )
            let decision = RuntimeProbeStateMachine.livenessRestartDecision(
                probes: desired.probes,
                snapshot: try probeStore.loadLatest(
                    groupID: context.groupID,
                    resourceIdentifier: binding.resourceIdentifier
                ) ?? RuntimeProbeStateMachine.initialSnapshot(
                    resourceIdentifier: binding.resourceIdentifier,
                    probes: desired.probes,
                    startedAtMilliseconds: nowMilliseconds()
                ),
                desired: desired,
                restartState: previous,
                currentTimestamp: hostwrightTimestamp()
            )
            guard let decision,
                  decision.executionAvailability ==
                    .availableForRestartManagedService else {
                return .refused(
                    decision?.reason ??
                        "Liveness failure has no provable bounded restart action."
                )
            }
            guard nowMilliseconds() < deadlineMilliseconds else {
                return .refused("Liveness restart would exceed the node deadline.")
            }

            try acquireResourceFence(binding: binding, context: context)
            let timestamp = hostwrightTimestamp()
            let attemptCount = (previous?.attemptCount ?? 0) + 1
            let maximumAttempts =
                previous?.maxAttempts ?? RestartPolicyStateDefaults.maxAttempts
            let backoffSeconds =
                previous?.backoffSeconds ?? RestartPolicyStateDefaults.backoffSeconds
            let status: RestartPolicyStateStatus =
                attemptCount >= maximumAttempts ? .crashLoopBlocked : .backingOff
            try store.restartPolicies.upsert(
                RestartPolicyStateRecord(
                    id: previous?.id ?? hostwrightUniqueID(prefix: "restart-policy"),
                    projectID: context.plan.projectID,
                    serviceName: restartPolicyKey,
                    policy: desired.restartPolicy,
                    status: status,
                    attemptCount: attemptCount,
                    maxAttempts: maximumAttempts,
                    backoffSeconds: backoffSeconds,
                    backoffUntil: status == .backingOff
                        ? hostwrightTimestampAdding(
                            seconds: backoffSeconds,
                            to: timestamp
                        )
                        : nil,
                    lastFailureAt: timestamp,
                    updatedAt: timestamp,
                    metadataJSONRedacted:
                        #"{"source":"phase04-liveness-probe","outcome":"restart-pending"}"#
                )
            )
            let action = PlannedRuntimeAction(
                kind: .restart,
                identity: desired.identity,
                resourceIdentifier: binding.resourceIdentifier,
                isDestructive: true,
                summary: "liveness-restart",
                desiredService: nil
            )
            let confirmation = RuntimeMutationConfirmation(
                confirmed: true,
                reason: "Confirmed lifecycle liveness restart",
                planHash: context.plan.planSHA256,
                manifestHash: context.plan.manifestSHA256,
                context: mutationContext(node: node, context: context)
            )
            do {
                try validateSchedulerActivation(action: action, node: node, fencingToken: context.fencingToken)
            } catch {
                return .refused(RuntimeRedactionPolicy.default.redact(String(describing: error)))
            }
            _ = try await executeWithActivationAuthority(action, confirmation: confirmation, node: node)
            return .restarted
        } catch let error as RuntimeActivationAuthorityRejection {
            return .refused(error.diagnostic)
        } catch {
            return .ambiguous(
                normalizedSpecialFailure(
                    error,
                    context: context,
                    effectPossible: true
                )
            )
        }
    }

    private func resetRestartPolicyAfterHealthyProbe(
        desired: DesiredRuntimeService,
        projectID: String
    ) throws {
        let restartPolicyKey = lifecycleRestartPolicyKey(
            for: desired.identity
        )
        guard let previous = try store.restartPolicies.load(
            projectID: projectID,
            serviceName: restartPolicyKey
        ) else {
            return
        }
        let now = hostwrightTimestamp()
        try store.restartPolicies.upsert(
            RestartPolicyStateRecord(
                id: previous.id,
                projectID: previous.projectID,
                serviceName: previous.serviceName,
                policy: desired.restartPolicy,
                status: .active,
                attemptCount: 0,
                maxAttempts: previous.maxAttempts,
                backoffSeconds: previous.backoffSeconds,
                backoffUntil: nil,
                lastFailureAt: nil,
                updatedAt: now,
                metadataJSONRedacted:
                    #"{"source":"phase04-liveness-probe","outcome":"healthy"}"#
            )
        )
    }

    private func acquireResourceFence(
        binding: LifecycleResourceBinding,
        context: LifecycleSagaContext
    ) throws {
        guard let current = try store.ownership.loadAll().first(where: {
            $0.resourceUUID == binding.resourceUUID &&
                RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) ==
                    context.plan.providerID
        }) else {
            throw LifecycleSpecialExecutionError.invalidExactBinding
        }
        if current.fencingToken == context.fencingToken {
            return
        }
        guard current.fencingToken == binding.currentFencingToken,
              try store.ownership.advanceFencingToken(
                  resourceIdentifier: binding.resourceIdentifier,
                  runtimeAdapter: current.runtimeAdapter,
                  expectedResourceUUID: binding.resourceUUID,
                  expectedFencingToken: binding.currentFencingToken,
                  newFencingToken: context.fencingToken,
                  observedAt: hostwrightTimestamp()
              ) != nil else {
            throw LifecycleSpecialExecutionError.invalidExactBinding
        }
    }

    private func probeNodeStartedAtMilliseconds(
        node: LifecyclePlanNode,
        groupID: String
    ) -> Int64? {
        guard let timestamp = (try? store.operationGroupSteps.load(groupID: groupID))?
            .first(where: {
                $0.direction == .forward &&
                    $0.stepKey == node.key &&
                    $0.startedAt != nil
            })?
            .startedAt else {
            return nil
        }
        return lifecycleEpochMilliseconds(timestamp)
    }
}
