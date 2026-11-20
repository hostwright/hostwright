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

struct LifecycleHookCheckpoint: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let nodeKey: String
    let effectPossible: Bool
    let diagnosticRedacted: String
}

struct LifecycleCompletionCheckpoint: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let nodeKey: String
    let diagnosticRedacted: String
}

private final class LifecycleHookOutputBudget: @unchecked Sendable {
    let lock = NSLock()
    private var consumedBytes = 0

    func consume(_ count: Int) throws {
        try lock.withLock {
            guard count >= 0,
                  consumedBytes <=
                    LifecycleProbeExecutor.maximumDiscardedExecOutputBytes - count else {
                throw LifecycleSpecialExecutionError.outputLimitExceeded
            }
            consumedBytes += count
        }
    }
}

extension LifecycleLiveEffects {
    func probeKind(for node: LifecyclePlanNode) -> RuntimeProbeKind? {
        let kinds = node.postconditions.compactMap { condition -> RuntimeProbeKind? in
            switch condition.kind {
            case "probe-startup": .startup
            case "probe-readiness": .readiness
            case "probe-liveness": .liveness
            default: nil
            }
        }
        guard Set(kinds).count == 1 else { return nil }
        return kinds[0]
    }

    func stableObservationSeconds(for node: LifecyclePlanNode) -> Int {
        let values = node.preconditions.compactMap { condition -> Int? in
            guard condition.kind == "stable-observation-seconds" else {
                return nil
            }
            return Int(condition.expectedValue)
        }
        guard values.count == 1, let value = values.first, value > 0 else {
            return 0
        }
        return value
    }

    func applyRolloutGate(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaApplyOutcome {
        guard context.plan.command == .update else {
            return .accepted
        }
        do {
            let desiredState = await state.desiredStateSnapshot()
            let observed = try await adapter.observe(desiredState: desiredState)
            guard observed.adapterMetadata?.providerID == context.plan.providerID,
                  observed.capabilitySHA256 == context.plan.capabilitySHA256 else {
                throw LifecycleSpecialExecutionError.staleCapability
            }
            await state.replaceObservedState(observed)
            try validateRolloutDependencies(
                node: node,
                desiredState: desiredState,
                observedState: observed
            )
            guard node.action == .promote else {
                return .accepted
            }
            try await validatePromotionEvidence(
                node: node,
                context: context,
                observedState: observed
            )
            return .accepted
        } catch {
            let diagnostic = node.action == .promote
                ? "Rollout promotion refused ambiguous or unproven candidate health."
                : "Rollout preparation refused an unhealthy or ambiguous dependency."
            await state.recordSpecialEvidence(.noEffect(diagnostic), for: node.key)
            return .failed(
                specialFailure(
                    category: error is LifecycleSpecialExecutionError
                        ? .rejected
                        : .ambiguousEffect,
                    context: context,
                    diagnostic: diagnostic,
                    guidance:
                        "Preserve the exact rollout checkpoint and restore declared health before resuming."
                )
            )
        }
    }

    func validatePromotionEvidence(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        observedState: ObservedRuntimeState
    ) async throws {
        guard let desired = await state.desiredService(for: node.key) else {
            throw LifecycleSpecialExecutionError.invalidExactBinding
        }
        let identity = await state.identity(
            for: node,
            projectName: context.plan.projectName
        )
        let matches = observedState.services.filter {
            $0.identity == identity &&
                $0.resourceIdentifier == node.resourceIdentifier
        }
        guard matches.count == 1,
              matches[0].lifecycleState == .running else {
            throw LifecycleSpecialExecutionError.invalidExactBinding
        }
        if desired.probes.configuredKinds.isEmpty {
            guard matches[0].healthState == .healthy ||
                    matches[0].healthState == .notConfigured else {
                throw LifecycleSpecialExecutionError.invalidProbe
            }
            return
        }
        guard let snapshot = try probeStore.loadLatest(
            groupID: context.groupID,
            resourceIdentifier: node.resourceIdentifier ?? ""
        ) else {
            throw LifecycleSpecialExecutionError.invalidProbe
        }
        let now = nowMilliseconds()
        let resumed = try RuntimeProbeStateMachine.resumed(
            snapshot,
            probes: desired.probes,
            nowMilliseconds: now
        )
        guard desired.probes.configuredKinds.allSatisfy({
            resumed.state(for: $0)?.phase == .succeeded
        }) else {
            throw LifecycleSpecialExecutionError.invalidProbe
        }
        if desired.updatePolicy.stableObservationSeconds > 0 {
            guard let stableSince = resumed.stableSinceMilliseconds,
                  now >= stableSince +
                    Int64(desired.updatePolicy.stableObservationSeconds) * 1_000 else {
                throw LifecycleSpecialExecutionError.invalidProbe
            }
            let stableDeadline = stableSince +
                Int64(desired.updatePolicy.stableObservationSeconds) * 1_000
            let terminalKinds = [
                RuntimeProbeKind.readiness,
                .liveness
            ].filter { desired.probes[$0] != nil }
            guard terminalKinds.allSatisfy({ kind in
                (resumed.state(for: kind)?.lastAttemptAtMilliseconds ??
                    Int64.min) >= stableDeadline
            }) else {
                throw LifecycleSpecialExecutionError.invalidProbe
            }
        }
    }

    func validateRolloutDependencies(
        node: LifecyclePlanNode,
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) throws {
        let conditions = node.preconditions.filter {
            $0.kind.hasPrefix("dependency-")
        }
        for condition in conditions {
            guard let serviceName = condition.subject.split(separator: "/").last
                .map(String.init) else {
                throw LifecycleSpecialExecutionError.invalidProbe
            }
            let desired = desiredState.services.filter {
                $0.logicalServiceName == serviceName
            }
            let observed = observedState.services.filter {
                $0.identity.serviceName == serviceName
            }
            guard !desired.isEmpty, observed.count >= desired.count else {
                throw LifecycleSpecialExecutionError.invalidProbe
            }
            let satisfied: Bool
            switch condition.kind {
            case "dependency-started":
                satisfied = observed.allSatisfy { $0.lifecycleState == .running }
            case "dependency-ready":
                satisfied = observed.allSatisfy {
                    $0.lifecycleState == .running &&
                        ($0.healthState == .healthy ||
                            $0.healthState == .notConfigured)
                }
            case "dependency-completed":
                satisfied = observed.allSatisfy { $0.lifecycleState == .exited }
            default:
                throw LifecycleSpecialExecutionError.invalidProbe
            }
            guard satisfied else {
                throw LifecycleSpecialExecutionError.invalidProbe
            }
        }
    }

    func applyHook(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaApplyOutcome {
        let binding: LifecycleResourceBinding
        let desired: DesiredRuntimeService
        let command: [String]
        let capability: RuntimeCapabilitySnapshot
        do {
            guard let exactBinding = await state.binding(
                resourceUUID: node.resourceUUID,
                resourceIdentifier: node.resourceIdentifier
            ),
                exactBinding.resourceUUID == node.resourceUUID,
                exactBinding.resourceGeneration == node.resourceGeneration,
                exactBinding.projectResourceUUID == context.plan.projectResourceUUID,
                exactBinding.projectGeneration == context.plan.projectGeneration,
                exactBinding.providerID == context.plan.providerID,
                exactBinding.providerGeneration == context.plan.providerGeneration,
                let exactDesired = await state.desiredService(for: node.key),
                exactDesired.identity == exactBinding.identity else {
                throw LifecycleSpecialExecutionError.invalidExactBinding
            }
            binding = exactBinding
            desired = exactDesired
            command = try hookCommand(node: node, desired: desired)
            try RuntimeProbeValidator.validate(
                RuntimeProbeConfiguration(
                    action: .exec(RuntimeProbeExecAction(command: command)),
                    timeoutSeconds: min(
                        node.timeoutSeconds,
                        RuntimeProbeValidator.maximumTimeoutSeconds
                    )
                ),
                declaredContainerPorts: []
            )
            capability = try await adapter.capabilitySnapshot()
            guard capability.descriptor.providerID == context.plan.providerID,
                  capability.canonicalSHA256 == context.plan.capabilitySHA256 else {
                throw LifecycleSpecialExecutionError.staleCapability
            }
            let contract = RuntimeInteractiveCapabilityContract(snapshot: capability)
            guard contract.availableOperations.contains(.exec) else {
                throw LifecycleSpecialExecutionError.unavailable(
                    contract.unavailableReasons[.exec] ??
                        "The selected provider does not advertise bounded container exec."
                )
            }
            try saveHookCheckpoint(
                .started,
                effectPossible: true,
                node: node,
                context: context,
                diagnostic: ""
            )
        } catch {
            try? saveHookCheckpoint(
                .failed,
                effectPossible: false,
                node: node,
                context: context,
                diagnostic: RuntimeRedactionPolicy.default.redact(String(describing: error))
            )
            await state.recordSpecialEvidence(
                .noEffect("Hook execution was rejected before container exec."),
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

        do {
            let budget = LifecycleHookOutputBudget()
            _ = try await interactiveExecutor.executeProbeCommand(
                resourceIdentifier: binding.resourceIdentifier,
                arguments: command,
                workingDirectory: desired.workingDirectory,
                capabilitySnapshot: capability,
                timeoutMilliseconds: node.timeoutSeconds * 1_000
            ) { frame in
                try budget.consume(frame.payload.count)
            }
            try saveHookCheckpoint(
                .succeeded,
                effectPossible: true,
                node: node,
                context: context,
                diagnostic: ""
            )
            await state.recordSpecialEvidence(
                .satisfied("Bounded container hook completed."),
                for: node.key
            )
            return .accepted
        } catch {
            try? saveHookCheckpoint(
                .failed,
                effectPossible: true,
                node: node,
                context: context,
                diagnostic: RuntimeRedactionPolicy.default.redact(String(describing: error))
            )
            await state.recordSpecialEvidence(
                .ambiguous(
                    "Container hook failed after execution began; external effects are not reversible."
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
    }

    func applyCompletionAwareStart(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaApplyOutcome {
        do {
            try saveCompletionCheckpoint(
                .started,
                node: node,
                context: context,
                diagnostic: ""
            )
            try validateSchedulerActivation(action: action, node: node, fencingToken: context.fencingToken)
        } catch {
            try? saveCompletionCheckpoint(
                .unsupported,
                node: node,
                context: context,
                diagnostic: "Completion-aware start was rejected before runtime mutation."
            )
            await state.recordSpecialEvidence(
                .noEffect("Completion-aware start was rejected before runtime mutation."),
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

        do {
            _ = try await executeWithActivationAuthority(action, confirmation: confirmation, node: node)
            try saveCompletionCheckpoint(
                .succeeded,
                node: node,
                context: context,
                diagnostic: ""
            )
            await state.recordSpecialEvidence(
                .satisfied(
                    "Completion-aware start observed a zero init-process exit."
                ),
                for: node.key
            )
            return .accepted
        } catch let error as RuntimeActivationAuthorityRejection {
            try? saveCompletionCheckpoint(
                .unsupported, node: node, context: context, diagnostic: lifecycleSchedulerActivationRejected
            )
            await state.recordSpecialEvidence(.noEffect(lifecycleSchedulerActivationRejected), for: node.key)
            return .failed(normalizedSpecialFailure(error, context: context, effectPossible: false))
        } catch {
            let diagnostic = RuntimeRedactionPolicy.default.redact(
                String(describing: error)
            )
            try? saveCompletionCheckpoint(
                .failed,
                node: node,
                context: context,
                diagnostic: diagnostic
            )
            await state.recordSpecialEvidence(
                .ambiguous(
                    "Completion-aware start failed after execution began; a zero init-process exit was not proved."
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
    }

    private func saveHookCheckpoint(
        _ status: OperationGroupStepStatus,
        effectPossible: Bool,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        diagnostic: String
    ) throws {
        let checkpoint = LifecycleHookCheckpoint(
            schemaVersion: 1,
            nodeKey: node.key,
            effectPossible: effectPossible,
            diagnosticRedacted: RuntimeRedactionPolicy.default.redact(diagnostic)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(checkpoint)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LifecycleSpecialExecutionError.invalidHook
        }
        let timestamp = hostwrightTimestamp()
        try store.operationGroupSteps.append(
            OperationGroupStepRecord(
                id: HostwrightResourceUUID.generate(),
                groupID: context.groupID,
                stepKey: lifecycleHookStepKey(node.key),
                direction: .forward,
                plannedActionType: "hook-checkpoint",
                serviceName: node.serviceName,
                resourceIdentifier: node.resourceIdentifier,
                stepIdempotencyKey:
                    "hook:\(lifecycleTextSHA256("\(node.key):\(status.rawValue):\(effectPossible)"))",
                status: status,
                startedAt: status == .started ? timestamp : nil,
                updatedAt: timestamp,
                finishedAt: status == .started ? nil : timestamp,
                lastErrorRedacted: status == .failed
                    ? checkpoint.diagnosticRedacted
                    : nil,
                manualRecoveryHintRedacted: effectPossible && status == .failed
                    ? "Preserve safe hold; the container hook may have external effects."
                    : "",
                metadataJSONRedacted: json
            ),
            expectedFencingToken: context.fencingToken
        )
    }

    func loadHookCheckpoint(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) throws -> (OperationGroupStepStatus, LifecycleHookCheckpoint)? {
        guard let record = try store.operationGroupSteps.latest(
            groupID: context.groupID,
            stepKey: lifecycleHookStepKey(node.key)
        ) else {
            return nil
        }
        guard let data = record.metadataJSONRedacted.data(using: .utf8),
              let checkpoint = try? JSONDecoder().decode(
                  LifecycleHookCheckpoint.self,
                  from: data
              ),
              checkpoint.schemaVersion == 1,
              checkpoint.nodeKey == node.key else {
            throw LifecycleSpecialExecutionError.invalidHook
        }
        return (record.status, checkpoint)
    }

    private func saveCompletionCheckpoint(
        _ status: OperationGroupStepStatus,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        diagnostic: String
    ) throws {
        let checkpoint = LifecycleCompletionCheckpoint(
            schemaVersion: 1,
            nodeKey: node.key,
            diagnosticRedacted: RuntimeRedactionPolicy.default.redact(diagnostic)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(checkpoint)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LifecycleSpecialExecutionError.invalidCompletionCheckpoint
        }
        let timestamp = hostwrightTimestamp()
        try store.operationGroupSteps.append(
            OperationGroupStepRecord(
                id: HostwrightResourceUUID.generate(),
                groupID: context.groupID,
                stepKey: lifecycleCompletionStepKey(node.key),
                direction: .forward,
                plannedActionType: "completion-checkpoint",
                serviceName: node.serviceName,
                resourceIdentifier: node.resourceIdentifier,
                stepIdempotencyKey:
                    "completion:\(lifecycleTextSHA256("\(node.key):\(status.rawValue)"))",
                status: status,
                startedAt: status == .started ? timestamp : nil,
                updatedAt: timestamp,
                finishedAt: status == .started ? nil : timestamp,
                lastErrorRedacted: status == .failed
                    ? checkpoint.diagnosticRedacted
                    : nil,
                manualRecoveryHintRedacted: status == .failed
                    ? "Preserve safe hold because a zero init-process exit was not proved."
                    : "",
                metadataJSONRedacted: json
            ),
            expectedFencingToken: context.fencingToken
        )
    }

    func loadCompletionCheckpoint(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) throws -> (OperationGroupStepStatus, LifecycleCompletionCheckpoint)? {
        guard let record = try store.operationGroupSteps.latest(
            groupID: context.groupID,
            stepKey: lifecycleCompletionStepKey(node.key)
        ) else {
            return nil
        }
        guard let data = record.metadataJSONRedacted.data(using: .utf8),
              let checkpoint = try? JSONDecoder().decode(
                  LifecycleCompletionCheckpoint.self,
                  from: data
              ),
              checkpoint.schemaVersion == 1,
              checkpoint.nodeKey == node.key else {
            throw LifecycleSpecialExecutionError.invalidCompletionCheckpoint
        }
        return (record.status, checkpoint)
    }
}
