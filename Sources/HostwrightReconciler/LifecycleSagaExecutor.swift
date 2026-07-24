import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

public enum LifecyclePersistedIntentCodecError: Error, Equatable, Sendable {
    case encodingFailed
    case decodingFailed
}

public enum LifecyclePersistedIntentCodec {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let planBase64: String
        let planSHA256: String
        let recoveryStateBase64: String?
    }

    private static let schemaVersion = 1

    public static func encode(
        _ plan: LifecyclePlan,
        recoveryStateJSONRedacted: String? = nil
    ) throws -> String {
        let planData = Data(try plan.canonicalJSON().utf8)
        let recoveryStateBase64: String?
        if let recoveryStateJSONRedacted {
            guard let data = recoveryStateJSONRedacted.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data),
                  value is [String: Any],
                  let canonicalData = try? JSONSerialization.data(
                      withJSONObject: value,
                      options: [.sortedKeys]
                  ) else {
                throw LifecyclePersistedIntentCodecError.encodingFailed
            }
            recoveryStateBase64 = canonicalData.base64EncodedString()
        } else {
            recoveryStateBase64 = nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let value = try? encoder.encode(
            Envelope(
                schemaVersion: schemaVersion,
                planBase64: planData.base64EncodedString(),
                planSHA256: plan.planSHA256,
                recoveryStateBase64: recoveryStateBase64
            )
        ), let encoded = String(data: value, encoding: .utf8) else {
            throw LifecyclePersistedIntentCodecError.encodingFailed
        }
        return encoded
    }

    public static func decode(_ value: String) throws -> LifecyclePlan {
        guard let data = value.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == schemaVersion,
              let planData = Data(base64Encoded: envelope.planBase64),
              planData.base64EncodedString() == envelope.planBase64,
              let plan = try? JSONDecoder().decode(
                  LifecyclePlan.self,
                  from: planData
              ),
              plan.planSHA256 == envelope.planSHA256 else {
            throw LifecyclePersistedIntentCodecError.decodingFailed
        }
        return plan
    }

    public static func decodeRecoveryStateJSONRedacted(
        _ value: String
    ) throws -> String? {
        _ = try decode(value)
        guard let data = value.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let recoveryStateBase64 = envelope.recoveryStateBase64 else {
            return nil
        }
        guard let recoveryData = Data(base64Encoded: recoveryStateBase64),
              recoveryData.base64EncodedString() == recoveryStateBase64,
              let object = try? JSONSerialization.jsonObject(with: recoveryData),
              object is [String: Any],
              let canonicalData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ),
              let json = String(data: canonicalData, encoding: .utf8) else {
            throw LifecyclePersistedIntentCodecError.decodingFailed
        }
        return json
    }
}

public struct LifecycleSagaContext: Sendable {
    public let plan: LifecyclePlan
    public let operationID: String
    public let groupID: String
    public let fencingToken: String
    public let attempt: Int
    public let direction: OperationGroupStepDirection

    public init(
        plan: LifecyclePlan,
        operationID: String,
        groupID: String,
        fencingToken: String,
        attempt: Int,
        direction: OperationGroupStepDirection = .forward
    ) {
        self.plan = plan
        self.operationID = operationID
        self.groupID = groupID
        self.fencingToken = fencingToken
        self.attempt = attempt
        self.direction = direction
    }
}

public struct LifecycleSagaValidation: Equatable, Sendable {
    public let providerID: RuntimeProviderID
    public let providerGeneration: Int
    public let capabilitySHA256: String
    public let projectResourceUUID: String
    public let projectGeneration: Int
    public let fencingToken: String
    public let ownershipVerified: Bool

    public init(
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        capabilitySHA256: String,
        projectResourceUUID: String,
        projectGeneration: Int,
        fencingToken: String,
        ownershipVerified: Bool
    ) {
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.capabilitySHA256 = capabilitySHA256
        self.projectResourceUUID = projectResourceUUID
        self.projectGeneration = projectGeneration
        self.fencingToken = fencingToken
        self.ownershipVerified = ownershipVerified
    }
}

public protocol LifecycleSagaContextValidating: Sendable {
    func validate(
        plan: LifecyclePlan,
        node: LifecyclePlanNode,
        expectedFencingToken: String
    ) async -> LifecycleSagaValidation
}

public struct LifecycleNodeVerification: Codable, Equatable, Sendable {
    public let observationSHA256: String?
    public let summaryRedacted: String

    public init(observationSHA256: String? = nil, summaryRedacted: String) {
        self.observationSHA256 = observationSHA256
        self.summaryRedacted = summaryRedacted
    }
}

public enum LifecycleSagaApplyOutcome: Equatable, Sendable {
    case accepted
    case failed(RuntimeNormalizedFailure)
}

public enum LifecycleSagaObservation: Equatable, Sendable {
    case satisfied(LifecycleNodeVerification)
    case noEffect(LifecycleNodeVerification)
    case effectPresent(LifecycleNodeVerification)
    case ambiguous(LifecycleNodeVerification)
}

public enum LifecycleSagaCompensationOutcome: Equatable, Sendable {
    case compensated(LifecycleNodeVerification)
    case failed(RuntimeNormalizedFailure)
}

public protocol LifecycleSagaEffects: Sendable {
    func apply(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaApplyOutcome

    func observe(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaObservation

    func compensate(
        compensation: LifecycleCompensation,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaCompensationOutcome
}

public protocol LifecycleSagaClock: Sendable {
    func now() -> String
}

public struct LifecycleSystemClock: LifecycleSagaClock {
    public init() {}

    public func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

public enum LifecycleSagaExecutionStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case alreadySucceeded = "already-succeeded"
    case compensated
    case interrupted
    case safeHold = "safe-hold"
}

public struct LifecycleSagaExecutionResult: Equatable, Sendable {
    public let status: LifecycleSagaExecutionStatus
    public let operationID: String
    public let groupID: String
    public let planSHA256: String
    public let checkpoint: String
    public let completedNodeKeys: [String]
    public let recoveryHintRedacted: String

    public init(
        status: LifecycleSagaExecutionStatus,
        operationID: String,
        groupID: String,
        planSHA256: String,
        checkpoint: String,
        completedNodeKeys: [String],
        recoveryHintRedacted: String
    ) {
        self.status = status
        self.operationID = operationID
        self.groupID = groupID
        self.planSHA256 = planSHA256
        self.checkpoint = checkpoint
        self.completedNodeKeys = completedNodeKeys
        self.recoveryHintRedacted = recoveryHintRedacted
    }
}

public enum LifecycleSagaError: Error, Equatable, Sendable {
    case invalidIdentity(String)
    case operationConflict(existingGroupID: String)
    case persistedPlanMismatch
    case stateFailure(String)
}

private struct LifecycleSagaRecoveryResult: Sendable {
    let node: LifecyclePlanNode
    let attempt: Int
    let observation: LifecycleSagaObservation
}

private struct LifecycleSagaValidationResult: Sendable {
    let node: LifecyclePlanNode
    let attempt: Int
    let validation: LifecycleSagaValidation
}

private struct LifecycleSagaAttemptResult: Sendable {
    let node: LifecyclePlanNode
    let attempt: Int
    let outcome: LifecycleSagaApplyOutcome
    let observation: LifecycleSagaObservation
}

private enum LifecycleSagaWaveResult: Sendable {
    case advanced(Set<String>)
    case terminal(LifecycleSagaExecutionResult)
}

public struct LifecycleSagaExecutor: Sendable {
    public static let maximumAttempts = 3
    public static let leaseDurationSeconds = 900

    private let store: SQLiteStateStore
    private let effects: any LifecycleSagaEffects
    private let validator: any LifecycleSagaContextValidating
    private let clock: any LifecycleSagaClock
    private let recoveryStateJSONRedacted: String?

    public init(
        store: SQLiteStateStore,
        effects: any LifecycleSagaEffects,
        validator: any LifecycleSagaContextValidating,
        clock: any LifecycleSagaClock = LifecycleSystemClock(),
        recoveryStateJSONRedacted: String? = nil
    ) {
        self.store = store
        self.effects = effects
        self.validator = validator
        self.clock = clock
        self.recoveryStateJSONRedacted = recoveryStateJSONRedacted
    }

    public func execute(
        plan: LifecyclePlan,
        operationID: String,
        groupID: String,
        fencingToken: String,
        lockOwner: String,
        lockExpiresAt: String? = nil
    ) async throws -> LifecycleSagaExecutionResult {
        guard HostwrightResourceUUID.isValid(operationID),
              HostwrightResourceUUID.isValid(groupID),
              HostwrightResourceUUID.isValid(fencingToken),
              !lockOwner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LifecycleSagaError.invalidIdentity(
                "Lifecycle saga requires canonical operation, group, and fencing UUIDs plus a lock owner."
            )
        }
        let normalizedFence = fencingToken.lowercased()
        let group = try prepareGroup(
            plan: plan,
            operationID: operationID.lowercased(),
            groupID: groupID.lowercased(),
            fencingToken: normalizedFence,
            lockOwner: lockOwner,
            lockExpiresAt: lockExpiresAt
        )
        if group.status == .succeeded {
            return result(
                status: .alreadySucceeded,
                plan: plan,
                operationID: operationID,
                groupID: group.id,
                checkpoint: group.checkpoint,
                completed: plan.nodes.map(\.key),
                hint: ""
            )
        }
        if group.status == .failed {
            let planNodeKeys = Set(plan.nodes.map(\.key))
            return result(
                status: .safeHold,
                plan: plan,
                operationID: operationID,
                groupID: group.id,
                checkpoint: group.checkpoint,
                completed: try completedNodeKeys(groupID: group.id).intersection(planNodeKeys),
                hint: group.manualRecoveryHintRedacted
            )
        }
        guard group.planHash == plan.planSHA256,
              group.fencingToken == normalizedFence else {
            throw LifecycleSagaError.persistedPlanMismatch
        }

        let planNodeKeys = Set(plan.nodes.map(\.key))
        var completed = try completedNodeKeys(groupID: group.id).intersection(planNodeKeys)
        while completed != planNodeKeys {
            if Task.isCancelled {
                let pendingKey = plan.nodes.first { !completed.contains($0.key) }?.key ?? "lifecycle"
                return try interrupt(
                    plan: plan,
                    group: group,
                    completed: completed,
                    checkpoint: "\(pendingKey):cancelled-before-effect",
                    hint: "Resume the exact fenced operation after inspecting current runtime state."
                )
            }
            let ready = plan.nodes.filter { node in
                !completed.contains(node.key) &&
                    node.dependencies.allSatisfy(completed.contains)
            }
            guard !ready.isEmpty else {
                throw LifecycleSagaError.stateFailure(
                    "Lifecycle DAG has pending nodes but no dependency-ready work."
                )
            }
            let wave = Array(ready.prefix(plan.parallelism))
            switch try await executeWave(
                plan: plan,
                group: group,
                nodes: wave,
                completed: completed,
                normalizedFence: normalizedFence
            ) {
            case .advanced(let nodeKeys):
                guard !nodeKeys.isEmpty else {
                    throw LifecycleSagaError.stateFailure(
                        "Lifecycle wave completed without advancing a dependency-ready node."
                    )
                }
                completed.formUnion(nodeKeys)
            case .terminal(let result):
                return result
            }
        }

        let finishedAt = clock.now()
        try store.operationGroups.finish(
            groupID: group.id,
            status: .succeeded,
            checkpoint: "verified",
            manualRecoveryHintRedacted: "",
            updatedAt: finishedAt,
            metadataJSONRedacted: try jsonObject([
                "lifecyclePlanSchemaVersion": LifecyclePlan.currentSchemaVersion,
                "planSHA256": plan.planSHA256,
                "result": LifecycleSagaExecutionStatus.succeeded.rawValue
            ])
        )
        return result(
            status: .succeeded,
            plan: plan,
            operationID: operationID,
            groupID: group.id,
            checkpoint: "verified",
            completed: completed,
            hint: ""
        )
    }

    private func executeWave(
        plan: LifecyclePlan,
        group: OperationGroupRecord,
        nodes: [LifecyclePlanNode],
        completed: Set<String>,
        normalizedFence: String
    ) async throws -> LifecycleSagaWaveResult {
        let orderedNodes = nodes.sorted { $0.key < $1.key }
        let persistedSteps = try store.operationGroupSteps.load(groupID: group.id)
        let previousStepsByKey = Dictionary(
            grouping: persistedSteps.filter { $0.direction == .forward },
            by: \.stepKey
        )
        var advanced = Set<String>()
        let recoveryCandidates = orderedNodes.compactMap { node
            -> (LifecyclePlanNode, Int)? in
            let previousSteps = previousStepsByKey[node.key] ?? []
            guard let latest = previousSteps.last,
                  latest.status == .started || latest.status == .failed else {
                return nil
            }
            return (node, max(1, attemptCount(previousSteps)))
        }
        let recoveryResults = await observeConcurrently(
            recoveryCandidates,
            plan: plan,
            group: group
        )
        var recoveryEffectNodes: [LifecyclePlanNode] = []
        var recoveryAmbiguousNodes: [LifecyclePlanNode] = []
        for recovery in recoveryResults {
            switch recovery.observation {
            case .satisfied(let verification):
                try recordStep(
                    group: group,
                    node: recovery.node,
                    direction: .forward,
                    status: .succeeded,
                    attempt: recovery.attempt,
                    verification: verification,
                    failure: nil
                )
                advanced.insert(recovery.node.key)
                try checkpoint(
                    group: group,
                    node: recovery.node,
                    suffix: "verified-after-resume",
                    verification: verification
                )
            case .effectPresent:
                recoveryEffectNodes.append(recovery.node)
            case .ambiguous:
                recoveryAmbiguousNodes.append(recovery.node)
            case .noEffect:
                break
            }
        }
        let completedAfterRecovery = completed.union(advanced)
        if let ambiguous = recoveryAmbiguousNodes.first {
            return .terminal(
                try safeHold(
                    plan: plan,
                    group: group,
                    completed: completedAfterRecovery,
                    checkpoint: "\(ambiguous.key):ambiguous-after-resume",
                    hint: "Runtime observation could not prove whether the interrupted effect occurred."
                )
            )
        }
        if !recoveryEffectNodes.isEmpty {
            return .terminal(
                try await compensate(
                    plan: plan,
                    group: group,
                    completed: completedAfterRecovery,
                    currentNodes: recoveryEffectNodes,
                    reason: "Interrupted lifecycle effects were observed and require compensation."
                )
            )
        }

        var activeNodes = orderedNodes.filter { !advanced.contains($0.key) }
        var attemptsByKey: [String: Int] = [:]
        for node in activeNodes {
            let startingAttempt = attemptCount(previousStepsByKey[node.key] ?? []) + 1
            guard startingAttempt <= Self.maximumAttempts else {
                return .terminal(
                    try await compensate(
                        plan: plan,
                        group: group,
                        completed: completedAfterRecovery,
                        currentNodes: [],
                        reason: "Lifecycle node \(node.key) exhausted its bounded attempts."
                    )
                )
            }
            attemptsByKey[node.key] = startingAttempt
        }

        while !activeNodes.isEmpty {
            activeNodes.sort { $0.key < $1.key }
            if Task.isCancelled {
                let node = activeNodes[0]
                return .terminal(
                    try interrupt(
                        plan: plan,
                        group: group,
                        completed: completed.union(advanced),
                        checkpoint: "\(node.key):cancelled-before-effect",
                        hint: "Resume the exact fenced operation after inspecting current runtime state."
                    )
                )
            }

            let validationInputs = activeNodes.map { node in
                (node, attemptsByKey[node.key] ?? 1)
            }
            let validationResults = await validateConcurrently(
                validationInputs,
                plan: plan,
                fence: normalizedFence
            )
            let staleResults = validationResults.filter {
                !isCurrent(
                    $0.validation,
                    plan: plan,
                    node: $0.node,
                    fence: normalizedFence
                )
            }
            if let stale = staleResults.first {
                for result in staleResults {
                    try recordStep(
                        group: group,
                        node: result.node,
                        direction: .forward,
                        status: .failed,
                        attempt: result.attempt,
                        verification: nil,
                        failure: staleContextFailure(
                            plan: plan,
                            operationID: group.operationID
                        )
                    )
                }
                return .terminal(
                    try safeHold(
                        plan: plan,
                        group: group,
                        completed: completed.union(advanced),
                        checkpoint: "\(stale.node.key):context-stale",
                        hint:
                            "Provider identity, generation, capabilities, ownership, or fencing changed before mutation."
                    )
                )
            }
            if Task.isCancelled {
                let node = activeNodes[0]
                return .terminal(
                    try interrupt(
                        plan: plan,
                        group: group,
                        completed: completed.union(advanced),
                        checkpoint: "\(node.key):cancelled-before-effect",
                        hint: "Resume the exact fenced operation after inspecting current runtime state."
                    )
                )
            }

            for node in activeNodes {
                let attempt = attemptsByKey[node.key] ?? 1
                try recordStep(
                    group: group,
                    node: node,
                    direction: .forward,
                    status: .started,
                    attempt: attempt,
                    verification: nil,
                    failure: nil
                )
                try checkpoint(
                    group: group,
                    node: node,
                    suffix: "effect-pending",
                    verification: nil
                )
            }

            let attemptInputs = activeNodes.map { node in
                (node, attemptsByKey[node.key] ?? 1)
            }
            let attemptResults = await applyAndObserveConcurrently(
                attemptInputs,
                plan: plan,
                group: group
            )
            var retryNodes: [LifecyclePlanNode] = []
            var definitiveFailures: [LifecyclePlanNode] = []
            var cancelledNodes: [LifecyclePlanNode] = []
            var effectPresentNodes: [LifecyclePlanNode] = []
            var ambiguousNodes: [LifecyclePlanNode] = []
            var acceptedWithoutEffectNodes: [LifecyclePlanNode] = []

            for attemptResult in attemptResults {
                switch (attemptResult.outcome, attemptResult.observation) {
                case (_, .satisfied(let verification)):
                    try recordStep(
                        group: group,
                        node: attemptResult.node,
                        direction: .forward,
                        status: .succeeded,
                        attempt: attemptResult.attempt,
                        verification: verification,
                        failure: nil
                    )
                    try checkpoint(
                        group: group,
                        node: attemptResult.node,
                        suffix: "verified",
                        verification: verification
                    )
                    advanced.insert(attemptResult.node.key)
                case (.failed(let failure), .noEffect(let verification)):
                    try recordStep(
                        group: group,
                        node: attemptResult.node,
                        direction: .forward,
                        status: .failed,
                        attempt: attemptResult.attempt,
                        verification: verification,
                        failure: failure
                    )
                    if failure.category == .cancelled {
                        cancelledNodes.append(attemptResult.node)
                    } else if failure.retryDisposition == .safeAfterObservation,
                              attemptResult.attempt < Self.maximumAttempts {
                        attemptsByKey[attemptResult.node.key] = attemptResult.attempt + 1
                        retryNodes.append(attemptResult.node)
                    } else {
                        definitiveFailures.append(attemptResult.node)
                    }
                case (.accepted, .noEffect(let verification)):
                    try recordStep(
                        group: group,
                        node: attemptResult.node,
                        direction: .forward,
                        status: .failed,
                        attempt: attemptResult.attempt,
                        verification: verification,
                        failure: uncertainEffectFailure(
                            plan: plan,
                            operationID: group.operationID,
                            diagnostic:
                                "Provider accepted the mutation but no effect satisfied its postconditions."
                        )
                    )
                    acceptedWithoutEffectNodes.append(attemptResult.node)
                case (_, .effectPresent(let verification)):
                    try recordStep(
                        group: group,
                        node: attemptResult.node,
                        direction: .forward,
                        status: .failed,
                        attempt: attemptResult.attempt,
                        verification: verification,
                        failure: partialEffectFailure(
                            plan: plan,
                            operationID: group.operationID
                        )
                    )
                    effectPresentNodes.append(attemptResult.node)
                case (_, .ambiguous(let verification)):
                    try recordStep(
                        group: group,
                        node: attemptResult.node,
                        direction: .forward,
                        status: .failed,
                        attempt: attemptResult.attempt,
                        verification: verification,
                        failure: uncertainEffectFailure(
                            plan: plan,
                            operationID: group.operationID,
                            diagnostic: "Runtime observation could not prove whether the effect occurred."
                        )
                    )
                    ambiguousNodes.append(attemptResult.node)
                }
            }

            let completedAfterAttempts = completed.union(advanced)
            if let ambiguous = (ambiguousNodes + acceptedWithoutEffectNodes)
                .sorted(by: { $0.key < $1.key })
                .first {
                let acceptedWithoutEffect = acceptedWithoutEffectNodes.contains {
                    $0.key == ambiguous.key
                }
                let checkpoint = acceptedWithoutEffect
                    ? "\(ambiguous.key):accepted-without-effect"
                    : "\(ambiguous.key):ambiguous-effect"
                let hint = acceptedWithoutEffect
                    ? "The provider accepted the mutation but postcondition observation found no effect."
                    : "Runtime observation cannot prove the effect or its inverse; " +
                        "preserve owned resources for recovery."
                return .terminal(
                    try safeHold(
                        plan: plan,
                        group: group,
                        completed: completedAfterAttempts,
                        checkpoint: checkpoint,
                        hint: hint
                    )
                )
            }
            if !effectPresentNodes.isEmpty {
                return .terminal(
                    try await compensate(
                        plan: plan,
                        group: group,
                        completed: completedAfterAttempts,
                        currentNodes: effectPresentNodes,
                        reason: "Lifecycle effects did not satisfy their postconditions."
                    )
                )
            }
            if !definitiveFailures.isEmpty {
                return .terminal(
                    try await compensate(
                        plan: plan,
                        group: group,
                        completed: completedAfterAttempts,
                        currentNodes: [],
                        reason: "Lifecycle effects failed without an observed effect."
                    )
                )
            }
            if let cancelled = cancelledNodes.sorted(by: { $0.key < $1.key }).first {
                return .terminal(
                    try interrupt(
                        plan: plan,
                        group: group,
                        completed: completedAfterAttempts,
                        checkpoint: "\(cancelled.key):cancelled-no-effect",
                        hint: "No effect was observed; resume the exact fenced operation when ready."
                    )
                )
            }
            activeNodes = retryNodes
        }
        return .advanced(advanced)
    }

    private func observeConcurrently(
        _ inputs: [(LifecyclePlanNode, Int)],
        plan: LifecyclePlan,
        group: OperationGroupRecord
    ) async -> [LifecycleSagaRecoveryResult] {
        let effects = effects
        return await withTaskGroup(
            of: LifecycleSagaRecoveryResult.self,
            returning: [LifecycleSagaRecoveryResult].self
        ) { tasks in
            for (node, attempt) in inputs {
                let context = context(plan: plan, group: group, attempt: attempt)
                tasks.addTask {
                    LifecycleSagaRecoveryResult(
                        node: node,
                        attempt: attempt,
                        observation: await effects.observe(node: node, context: context)
                    )
                }
            }
            var results: [LifecycleSagaRecoveryResult] = []
            for await result in tasks {
                results.append(result)
            }
            return results.sorted { $0.node.key < $1.node.key }
        }
    }

    private func validateConcurrently(
        _ inputs: [(LifecyclePlanNode, Int)],
        plan: LifecyclePlan,
        fence: String
    ) async -> [LifecycleSagaValidationResult] {
        let validator = validator
        return await withTaskGroup(
            of: LifecycleSagaValidationResult.self,
            returning: [LifecycleSagaValidationResult].self
        ) { tasks in
            for (node, attempt) in inputs {
                tasks.addTask {
                    LifecycleSagaValidationResult(
                        node: node,
                        attempt: attempt,
                        validation: await validator.validate(
                            plan: plan,
                            node: node,
                            expectedFencingToken: fence
                        )
                    )
                }
            }
            var results: [LifecycleSagaValidationResult] = []
            for await result in tasks {
                results.append(result)
            }
            return results.sorted { $0.node.key < $1.node.key }
        }
    }

    private func applyAndObserveConcurrently(
        _ inputs: [(LifecyclePlanNode, Int)],
        plan: LifecyclePlan,
        group: OperationGroupRecord
    ) async -> [LifecycleSagaAttemptResult] {
        let effects = effects
        return await withTaskGroup(
            of: LifecycleSagaAttemptResult.self,
            returning: [LifecycleSagaAttemptResult].self
        ) { tasks in
            for (node, attempt) in inputs {
                let context = context(plan: plan, group: group, attempt: attempt)
                tasks.addTask {
                    let outcome = await effects.apply(node: node, context: context)
                    let observation = await effects.observe(node: node, context: context)
                    return LifecycleSagaAttemptResult(
                        node: node,
                        attempt: attempt,
                        outcome: outcome,
                        observation: observation
                    )
                }
            }
            var results: [LifecycleSagaAttemptResult] = []
            for await result in tasks {
                results.append(result)
            }
            return results.sorted { $0.node.key < $1.node.key }
        }
    }

    private func prepareGroup(
        plan: LifecyclePlan,
        operationID: String,
        groupID: String,
        fencingToken: String,
        lockOwner: String,
        lockExpiresAt: String?
    ) throws -> OperationGroupRecord {
        let now = clock.now()
        let renewedLease = try lockExpiresAt ??
            Self.leaseExpiration(after: now)
        guard renewedLease > now else {
            throw LifecycleSagaError.stateFailure(
                "Lifecycle operation lease must expire after its acquisition timestamp."
            )
        }
        if let latest = try store.operationGroups.latest(groupIdempotencyKey: plan.planSHA256) {
            guard latest.planHash == plan.planSHA256,
                  latest.fencingToken == fencingToken else {
                throw LifecycleSagaError.persistedPlanMismatch
            }
            switch latest.status {
            case .active:
                switch try store.operationGroups.reclaimExpiredActive(
                    groupID: latest.id,
                    expectedPlanHash: plan.planSHA256,
                    expectedFencingToken: fencingToken,
                    lockOwner: lockOwner,
                    lockExpiresAt: renewedLease,
                    currentTimestamp: now
                ) {
                case .reclaimed(let reclaimed):
                    return reclaimed
                case .activeUnexpired:
                    throw LifecycleSagaError.operationConflict(existingGroupID: latest.id)
                }
            case .succeeded:
                return latest
            case .interrupted:
                return try store.operationGroups.resumeInterrupted(
                    groupID: latest.id,
                    expectedFencingToken: fencingToken,
                    lockOwner: lockOwner,
                    lockExpiresAt: renewedLease,
                    updatedAt: now
                )
            case .failed:
                return latest
            }
        }

        let compensationJSON = try jsonArray(
            plan.nodes.compactMap { node -> [String: Any]? in
                guard let compensation = node.compensation else { return nil }
                return [
                    "nodeKey": node.key,
                    "action": compensation.action.rawValue,
                    "timeoutSeconds": compensation.timeoutSeconds
                ]
            }
        )
        let record = OperationGroupRecord(
            id: groupID,
            operationID: operationID,
            groupKind: "lifecycle-v1",
            projectID: plan.projectID,
            serviceName: nil,
            plannedActionType: plan.command.rawValue,
            status: .active,
            groupIdempotencyKey: plan.planSHA256,
            planHash: plan.planSHA256,
            checkpoint: "intent-persisted",
            lockOwner: lockOwner,
            lockExpiresAt: renewedLease,
            rollbackAvailable: plan.nodes.contains { $0.compensation != nil },
            manualRecoveryHintRedacted: "",
            createdAt: now,
            updatedAt: now,
            metadataJSONRedacted: try jsonObject([
                "lifecyclePlanSchemaVersion": LifecyclePlan.currentSchemaVersion,
                "providerID": plan.providerID.rawValue,
                "providerGeneration": plan.providerGeneration,
                "capabilitySHA256": plan.capabilitySHA256,
                "parallelism": plan.parallelism
            ]),
            fencingToken: fencingToken,
            intentJSONRedacted: try LifecyclePersistedIntentCodec.encode(
                plan,
                recoveryStateJSONRedacted: recoveryStateJSONRedacted
            ),
            compensationJSONRedacted: compensationJSON,
            verificationJSONRedacted: try jsonObject([
                "checkpoint": "intent-persisted",
                "completedNodeKeys": []
            ])
        )
        let acquired = try store.operationGroups.acquire(record, currentTimestamp: now)
        if let group = acquired.acquired {
            return group
        }
        if let existing = acquired.existingActive {
            throw LifecycleSagaError.operationConflict(existingGroupID: existing.id)
        }
        throw LifecycleSagaError.stateFailure("Operation group acquisition produced no result.")
    }

    private func completedNodeKeys(groupID: String) throws -> Set<String> {
        let steps = try store.operationGroupSteps.load(groupID: groupID)
        let latestByKey = Dictionary(
            grouping: steps.filter { $0.direction == .forward },
            by: \.stepKey
        ).compactMapValues(\.last)
        return Set(
            latestByKey.compactMap { key, value in
                value.status == .succeeded ? key : nil
            }
        )
    }

    private func attemptCount(_ steps: [OperationGroupStepRecord]) -> Int {
        steps.filter { $0.status == .started }.count
    }

    private func context(
        plan: LifecyclePlan,
        group: OperationGroupRecord,
        attempt: Int,
        direction: OperationGroupStepDirection = .forward
    ) -> LifecycleSagaContext {
        LifecycleSagaContext(
            plan: plan,
            operationID: group.operationID,
            groupID: group.id,
            fencingToken: group.fencingToken,
            attempt: attempt,
            direction: direction
        )
    }

    private func isCurrent(
        _ validation: LifecycleSagaValidation,
        plan: LifecyclePlan,
        node: LifecyclePlanNode,
        fence: String
    ) -> Bool {
        validation.providerID == plan.providerID &&
            validation.providerGeneration == plan.providerGeneration &&
            validation.capabilitySHA256 == plan.capabilitySHA256 &&
            validation.projectResourceUUID.lowercased() == plan.projectResourceUUID &&
            validation.projectGeneration == plan.projectGeneration &&
            validation.fencingToken.lowercased() == fence &&
            node.fencingToken == fence &&
            validation.ownershipVerified
    }

    private func staleContextFailure(
        plan: LifecyclePlan,
        operationID: String
    ) -> RuntimeNormalizedFailure {
        RuntimeNormalizedFailure(
            category: .staleCapability,
            retryDisposition: .never,
            recoveryDisposition: .none,
            providerID: plan.providerID.rawValue,
            providerVersion: "bound-generation-\(plan.providerGeneration)",
            operationID: operationID,
            diagnostic: "Lifecycle mutation context changed before the external effect.",
            guidance: "Re-observe and generate a new confirmed lifecycle plan."
        )
    }

    private func partialEffectFailure(
        plan: LifecyclePlan,
        operationID: String
    ) -> RuntimeNormalizedFailure {
        RuntimeNormalizedFailure(
            category: .partialEffect,
            retryDisposition: .resumeFromCheckpoint,
            recoveryDisposition: .compensate,
            providerID: plan.providerID.rawValue,
            providerVersion: "bound-generation-\(plan.providerGeneration)",
            operationID: operationID,
            diagnostic: "Lifecycle effect exists but did not satisfy its postconditions.",
            guidance: "Use the recorded compensation checkpoint and exact ownership evidence."
        )
    }

    private func uncertainEffectFailure(
        plan: LifecyclePlan,
        operationID: String,
        diagnostic: String
    ) -> RuntimeNormalizedFailure {
        RuntimeNormalizedFailure(
            category: .ambiguousEffect,
            retryDisposition: .never,
            recoveryDisposition: .reobserve,
            providerID: plan.providerID.rawValue,
            providerVersion: "bound-generation-\(plan.providerGeneration)",
            operationID: operationID,
            diagnostic: diagnostic,
            guidance: "Preserve the fenced checkpoint and re-observe before any new mutation."
        )
    }

    private func recordStep(
        group: OperationGroupRecord,
        node: LifecyclePlanNode,
        direction: OperationGroupStepDirection,
        status: OperationGroupStepStatus,
        attempt: Int,
        verification: LifecycleNodeVerification?,
        failure: RuntimeNormalizedFailure?
    ) throws {
        let now = clock.now()
        var metadata: [String: Any] = [
            "attempt": attempt,
            "planNodeIdempotencyKey": node.idempotencyKey,
            "providerID": group.metadataJSONRedacted.contains("providerID")
                ? "bound"
                : "unknown"
        ]
        if let verification {
            metadata["verificationSummary"] = verification.summaryRedacted
            metadata["observationSHA256"] = verification.observationSHA256
        }
        if let failure {
            metadata["failureCategory"] = failure.category.rawValue
            metadata["retryDisposition"] = failure.retryDisposition.rawValue
            metadata["recoveryDisposition"] = failure.recoveryDisposition.rawValue
        }
        try store.operationGroupSteps.append(
            OperationGroupStepRecord(
                id: HostwrightResourceUUID.generate(),
                groupID: group.id,
                stepKey: node.key,
                direction: direction,
                plannedActionType: direction == .forward
                    ? node.action.rawValue
                    : (node.compensation?.action.rawValue ?? "none"),
                serviceName: node.serviceName,
                resourceIdentifier: node.resourceIdentifier,
                stepIdempotencyKey: "\(node.idempotencyKey):\(direction.rawValue):\(attempt)",
                status: status,
                startedAt: status == .started ? now : nil,
                updatedAt: now,
                finishedAt: status == .started ? nil : now,
                lastErrorRedacted: failure?.diagnostic,
                manualRecoveryHintRedacted: failure?.guidance ?? "",
                metadataJSONRedacted: try jsonObject(metadata)
            ),
            expectedFencingToken: group.fencingToken
        )
    }

    private func checkpoint(
        group: OperationGroupRecord,
        node: LifecyclePlanNode,
        suffix: String,
        verification: LifecycleNodeVerification?
    ) throws {
        var payload: [String: Any] = [
            "nodeKey": node.key,
            "checkpoint": "\(node.key):\(suffix)"
        ]
        if let verification {
            payload["summary"] = verification.summaryRedacted
            payload["observationSHA256"] = verification.observationSHA256
        }
        guard let lockOwner = group.lockOwner else {
            throw LifecycleSagaError.stateFailure(
                "Lifecycle operation lost its finite lease owner before checkpoint."
            )
        }
        let now = clock.now()
        try store.operationGroups.recordCheckpointRenewingLease(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            expectedLockOwner: lockOwner,
            checkpoint: "\(node.key):\(suffix)",
            verificationJSONRedacted: try jsonObject(payload),
            lockExpiresAt: try Self.leaseExpiration(after: now),
            updatedAt: now
        )
    }

    private static func leaseExpiration(after timestamp: String) throws -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: timestamp) else {
            throw LifecycleSagaError.stateFailure(
                "Lifecycle operation clock did not produce a valid ISO-8601 timestamp."
            )
        }
        return formatter.string(
            from: date.addingTimeInterval(TimeInterval(leaseDurationSeconds))
        )
    }

    private func compensate(
        plan: LifecyclePlan,
        group: OperationGroupRecord,
        completed: Set<String>,
        currentNodes: [LifecyclePlanNode],
        reason: String
    ) async throws -> LifecycleSagaExecutionResult {
        let affectedKeys = completed.union(currentNodes.map(\.key))
        let affected = plan.nodes.filter { affectedKeys.contains($0.key) }
        let rollbackStepsByKey = Dictionary(
            grouping: try store.operationGroupSteps.load(groupID: group.id)
                .filter { $0.direction == .rollback },
            by: \.stepKey
        )
        for node in affected.reversed() where node.action.mutatesRuntime {
            guard let compensation = node.compensation else {
                return try safeHold(
                    plan: plan,
                    group: group,
                    completed: completed,
                    checkpoint: "\(node.key):compensation-unavailable",
                    hint: "\(reason) The exact inverse is unavailable; preserve state and owned resources."
                )
            }
            let previousRollbackSteps = rollbackStepsByKey[node.key] ?? []
            if let latest = previousRollbackSteps.last {
                guard latest.plannedActionType == compensation.action.rawValue else {
                    return try safeHold(
                        plan: plan,
                        group: group,
                        completed: completed,
                        checkpoint: "\(node.key):compensation-record-mismatch",
                        hint:
                            "\(reason) The persisted compensation action does not match the exact planned inverse."
                    )
                }
                if latest.status == .succeeded {
                    continue
                }
            }
            let attempt = attemptCount(previousRollbackSteps) + 1
            if let latest = previousRollbackSteps.last,
               latest.status == .started || latest.status == .failed {
                let compensatingNode = try compensationNode(
                    for: node,
                    compensation: compensation
                )
                let observation = await effects.observe(
                    node: compensatingNode,
                    context: context(
                        plan: plan,
                        group: group,
                        attempt: max(1, attempt - 1),
                        direction: .rollback
                    )
                )
                switch observation {
                case .satisfied(let verification):
                    try recordStep(
                        group: group,
                        node: node,
                        direction: .rollback,
                        status: .succeeded,
                        attempt: max(1, attempt - 1),
                        verification: verification,
                        failure: nil
                    )
                    try checkpoint(
                        group: group,
                        node: node,
                        suffix: "compensated",
                        verification: verification
                    )
                    continue
                case .noEffect:
                    break
                case .effectPresent, .ambiguous:
                    return try safeHold(
                        plan: plan,
                        group: group,
                        completed: completed,
                        checkpoint: "\(node.key):compensation-ambiguous-after-resume",
                        hint:
                            "\(reason) Re-observation could not prove whether the interrupted compensation completed."
                    )
                }
            }
            guard attempt <= Self.maximumAttempts else {
                return try safeHold(
                    plan: plan,
                    group: group,
                    completed: completed,
                    checkpoint: "\(node.key):compensation-attempts-exhausted",
                    hint:
                        "\(reason) Compensation exhausted its bounded attempts; preserve the checkpoint for operator recovery."
                )
            }
            let validation = await validator.validate(
                plan: plan,
                node: node,
                expectedFencingToken: group.fencingToken
            )
            guard isCurrent(validation, plan: plan, node: node, fence: group.fencingToken) else {
                return try safeHold(
                    plan: plan,
                    group: group,
                    completed: completed,
                    checkpoint: "\(node.key):compensation-context-stale",
                    hint: "\(reason) Compensation refused because ownership or fencing changed."
                )
            }
            try recordStep(
                group: group,
                node: node,
                direction: .rollback,
                status: .started,
                attempt: attempt,
                verification: nil,
                failure: nil
            )
            try checkpoint(
                group: group,
                node: node,
                suffix: "compensation-pending",
                verification: nil
            )
            let outcome = await effects.compensate(
                compensation: compensation,
                node: node,
                context: context(
                    plan: plan,
                    group: group,
                    attempt: attempt,
                    direction: .rollback
                )
            )
            switch outcome {
            case .compensated(let verification):
                try recordStep(
                    group: group,
                    node: node,
                    direction: .rollback,
                    status: .succeeded,
                    attempt: attempt,
                    verification: verification,
                    failure: nil
                )
                try checkpoint(
                    group: group,
                    node: node,
                    suffix: "compensated",
                    verification: verification
                )
            case .failed(let failure):
                try recordStep(
                    group: group,
                    node: node,
                    direction: .rollback,
                    status: .failed,
                    attempt: attempt,
                    verification: nil,
                    failure: failure
                )
                return try safeHold(
                    plan: plan,
                    group: group,
                    completed: completed,
                    checkpoint: "\(node.key):compensation-failed",
                    hint: "\(reason) Compensation failed; preserve the checkpoint for operator recovery."
                )
            }
        }
        try store.operationGroups.finish(
            groupID: group.id,
            status: .failed,
            checkpoint: "compensated",
            manualRecoveryHintRedacted: reason,
            updatedAt: clock.now(),
            metadataJSONRedacted: try jsonObject([
                "result": LifecycleSagaExecutionStatus.compensated.rawValue,
                "planSHA256": plan.planSHA256
            ])
        )
        return result(
            status: .compensated,
            plan: plan,
            operationID: group.operationID,
            groupID: group.id,
            checkpoint: "compensated",
            completed: completed,
            hint: reason
        )
    }

    private func compensationNode(
        for node: LifecyclePlanNode,
        compensation: LifecycleCompensation
    ) throws -> LifecyclePlanNode {
        try LifecyclePlanNode(
            key: node.key,
            action: compensation.action,
            serviceName: node.serviceName,
            resourceIdentifier: node.resourceIdentifier,
            resourceUUID: node.resourceUUID,
            resourceGeneration: node.resourceGeneration,
            fencingToken: node.fencingToken,
            dependencies: [],
            preconditions: compensation.preconditions,
            postconditions: [],
            timeoutSeconds: compensation.timeoutSeconds,
            compensation: nil,
            desiredSpecificationJSONRedacted:
                node.desiredSpecificationJSONRedacted
        )
    }

    private func interrupt(
        plan: LifecyclePlan,
        group: OperationGroupRecord,
        completed: Set<String>,
        checkpoint: String,
        hint: String
    ) throws -> LifecycleSagaExecutionResult {
        try store.operationGroups.finish(
            groupID: group.id,
            status: .interrupted,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted: hint,
            updatedAt: clock.now(),
            metadataJSONRedacted: try jsonObject([
                "result": LifecycleSagaExecutionStatus.interrupted.rawValue,
                "planSHA256": plan.planSHA256
            ])
        )
        return result(
            status: .interrupted,
            plan: plan,
            operationID: group.operationID,
            groupID: group.id,
            checkpoint: checkpoint,
            completed: completed,
            hint: hint
        )
    }

    private func safeHold(
        plan: LifecyclePlan,
        group: OperationGroupRecord,
        completed: Set<String>,
        checkpoint: String,
        hint: String
    ) throws -> LifecycleSagaExecutionResult {
        try store.operationGroups.finish(
            groupID: group.id,
            status: .failed,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted: hint,
            updatedAt: clock.now(),
            metadataJSONRedacted: try jsonObject([
                "result": LifecycleSagaExecutionStatus.safeHold.rawValue,
                "planSHA256": plan.planSHA256
            ])
        )
        return result(
            status: .safeHold,
            plan: plan,
            operationID: group.operationID,
            groupID: group.id,
            checkpoint: checkpoint,
            completed: completed,
            hint: hint
        )
    }

    private func result(
        status: LifecycleSagaExecutionStatus,
        plan: LifecyclePlan,
        operationID: String,
        groupID: String,
        checkpoint: String,
        completed: Set<String>,
        hint: String
    ) -> LifecycleSagaExecutionResult {
        result(
            status: status,
            plan: plan,
            operationID: operationID,
            groupID: groupID,
            checkpoint: checkpoint,
            completed: completed.sorted(),
            hint: hint
        )
    }

    private func result(
        status: LifecycleSagaExecutionStatus,
        plan: LifecyclePlan,
        operationID: String,
        groupID: String,
        checkpoint: String,
        completed: [String],
        hint: String
    ) -> LifecycleSagaExecutionResult {
        LifecycleSagaExecutionResult(
            status: status,
            operationID: operationID,
            groupID: groupID,
            planSHA256: plan.planSHA256,
            checkpoint: checkpoint,
            completedNodeKeys: completed.sorted(),
            recoveryHintRedacted: RuntimeRedactionPolicy.default.redact(hint)
        )
    }

    private func jsonObject(_ object: [String: Any]) throws -> String {
        try json(object)
    }

    private func jsonArray(_ array: [[String: Any]]) throws -> String {
        try json(array)
    }

    private func json(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw LifecycleSagaError.stateFailure("Lifecycle saga metadata was not valid JSON.")
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw LifecycleSagaError.stateFailure("Lifecycle saga metadata was not UTF-8.")
        }
        return string
    }
}
