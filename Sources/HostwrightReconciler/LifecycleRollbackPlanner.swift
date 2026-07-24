import Foundation
import HostwrightCore
import HostwrightRuntime

public enum LifecycleRollbackPlanningError: Error, Equatable, Sendable {
    case healthyRevisionNotVerified(String)
    case invalidHealthyRevision(String)
    case duplicateHealthyRevision(String)
    case missingHealthyRevision(String)
    case invalidEffectReference(String)
}

public enum LifecycleRolloutFailureKind: String, Codable, Equatable, Sendable {
    case startup
    case readiness
    case runtime
    case sqlite
    case cancellation
    case processTermination = "process-termination"
}

public enum LifecycleEffectCertainty: String, Codable, Equatable, Sendable {
    case exact
    case ambiguous
}

public enum LifecycleRecoveryRequest: String, Codable, Equatable, Sendable {
    case automatic
    case resume
    case rollback
}

public struct LifecycleHealthyRevisionRecord: Codable, Equatable, Sendable {
    public let projectName: String
    public let serviceName: String
    public let instanceName: String?
    public let resourceIdentifier: String
    public let resourceUUID: String
    public let resourceGeneration: Int
    public let revisionSHA256: String
    public let desiredSpecificationJSONRedacted: String

    public init(
        service: DesiredRuntimeService,
        resourceIdentifier: String,
        resourceUUID: String,
        resourceGeneration: Int,
        readinessVerified: Bool,
        ownershipVerified: Bool
    ) throws {
        guard readinessVerified, ownershipVerified else {
            throw LifecycleRollbackPlanningError.healthyRevisionNotVerified(
                service.identity.displayName
            )
        }
        guard !resourceIdentifier.isEmpty,
              HostwrightResourceUUID.isValid(resourceUUID),
              resourceGeneration > 0 else {
            throw LifecycleRollbackPlanningError.invalidHealthyRevision(
                service.identity.displayName
            )
        }
        let desiredJSON = try LifecycleRevisionCodec.redactedDesiredJSON(for: service)
        projectName = service.identity.projectName
        serviceName = service.identity.serviceName
        instanceName = service.identity.instanceName
        self.resourceIdentifier = resourceIdentifier
        self.resourceUUID = resourceUUID.lowercased()
        self.resourceGeneration = resourceGeneration
        revisionSHA256 = try LifecycleRevisionCodec.revisionSHA256(for: service)
        desiredSpecificationJSONRedacted = desiredJSON
    }

    public var identity: RuntimeServiceIdentity {
        RuntimeServiceIdentity(
            projectName: projectName,
            serviceName: serviceName,
            instanceName: instanceName
        )
    }
}

public struct LifecycleRollbackProof: Equatable, Sendable {
    public let certainty: LifecycleEffectCertainty
    public let exactlyOwnedResourceUUIDs: Set<String>
    public let exactlyInvertibleNodeIdempotencyKeys: Set<String>

    public init(
        certainty: LifecycleEffectCertainty,
        exactlyOwnedResourceUUIDs: Set<String>,
        exactlyInvertibleNodeIdempotencyKeys: Set<String>
    ) {
        self.certainty = certainty
        self.exactlyOwnedResourceUUIDs = Set(
            exactlyOwnedResourceUUIDs.map { $0.lowercased() }
        )
        self.exactlyInvertibleNodeIdempotencyKeys =
            exactlyInvertibleNodeIdempotencyKeys
    }
}

public struct LifecycleRollbackRequestContext: Equatable, Sendable {
    public let request: LifecycleRecoveryRequest
    public let failure: LifecycleRolloutFailureKind
    public let completedUpdateNodeIdempotencyKeys: Set<String>
    public let completedRollbackNodeIdempotencyKeys: Set<String>

    public init(
        request: LifecycleRecoveryRequest,
        failure: LifecycleRolloutFailureKind,
        completedUpdateNodeIdempotencyKeys: Set<String>,
        completedRollbackNodeIdempotencyKeys: Set<String> = []
    ) {
        self.request = request
        self.failure = failure
        self.completedUpdateNodeIdempotencyKeys =
            completedUpdateNodeIdempotencyKeys
        self.completedRollbackNodeIdempotencyKeys =
            completedRollbackNodeIdempotencyKeys
    }
}

public struct LifecycleRollbackResumePlan: Equatable, Sendable {
    public let satisfiedNodeKeys: [String]
    public let pendingNodes: [LifecyclePlanNode]

    public init(satisfiedNodeKeys: [String], pendingNodes: [LifecyclePlanNode]) {
        self.satisfiedNodeKeys = satisfiedNodeKeys.sorted()
        self.pendingNodes = pendingNodes
    }
}

public struct LifecycleRollbackPlan: Equatable, Sendable {
    public let failure: LifecycleRolloutFailureKind
    public let healthyRevisions: [LifecycleHealthyRevisionRecord]
    public let nodes: [LifecyclePlanNode]
    public let restoredRevisionSHA256ByIdentity: [String: String]

    public init(
        failure: LifecycleRolloutFailureKind,
        healthyRevisions: [LifecycleHealthyRevisionRecord],
        nodes: [LifecyclePlanNode]
    ) {
        self.failure = failure
        self.healthyRevisions = healthyRevisions.sorted {
            $0.identity.displayName < $1.identity.displayName
        }
        self.nodes = nodes
        restoredRevisionSHA256ByIdentity = healthyRevisions.reduce(into: [:]) {
            $0[$1.identity.displayName] = $1.revisionSHA256
        }
    }

    public func resume(
        completedRollbackNodeIdempotencyKeys: Set<String>
    ) -> LifecycleRollbackResumePlan {
        let satisfied = nodes.filter {
            completedRollbackNodeIdempotencyKeys.contains($0.idempotencyKey)
        }
        let pending = nodes.filter {
            !completedRollbackNodeIdempotencyKeys.contains($0.idempotencyKey)
        }
        return LifecycleRollbackResumePlan(
            satisfiedNodeKeys: satisfied.map(\.key),
            pendingNodes: pending
        )
    }
}

public struct LifecycleRecoverySafeHold: Equatable, Sendable {
    public let reason: String
    public let affectedNodeKeys: [String]
    public let operatorCommands: [String]

    public init(
        reason: String,
        affectedNodeKeys: [String],
        operatorCommands: [String] = [
            "hostwright inspect --output json",
            "hostwright recovery --output json",
            "hostwright update --dry-run"
        ]
    ) {
        self.reason = reason
        self.affectedNodeKeys = affectedNodeKeys.sorted()
        self.operatorCommands = operatorCommands
    }
}

public enum LifecycleRecoveryDecision: Equatable, Sendable {
    case resume(LifecycleUpdateResumePlan)
    case rollback(LifecycleRollbackPlan, LifecycleRollbackResumePlan)
    case safeHold(LifecycleRecoverySafeHold)
}

public struct LifecycleRollbackPlanner: Sendable {
    public init() {}

    public func decide(
        updatePlan: LifecycleUpdatePlan,
        healthyRevisions: [LifecycleHealthyRevisionRecord],
        proof: LifecycleRollbackProof,
        context: LifecycleRollbackRequestContext
    ) throws -> LifecycleRecoveryDecision {
        try validate(healthyRevisions: healthyRevisions)
        let nodesByIdempotencyKey = Dictionary(
            uniqueKeysWithValues: updatePlan.nodes.map {
                ($0.idempotencyKey, $0)
            }
        )
        for key in context.completedUpdateNodeIdempotencyKeys
        where nodesByIdempotencyKey[key] == nil {
            throw LifecycleRollbackPlanningError.invalidEffectReference(key)
        }
        let effectedNodes = updatePlan.nodes.filter {
            context.completedUpdateNodeIdempotencyKeys.contains($0.idempotencyKey)
        }
        let affectedKeys = effectedNodes.map(\.key)
        let mutatingEffects = effectedNodes.filter(\.action.mutatesRuntime)

        if proof.certainty == .ambiguous {
            return .safeHold(
                LifecycleRecoverySafeHold(
                    reason:
                        "Runtime effects are ambiguous; exact ownership and inverse actions " +
                        "cannot be proven.",
                    affectedNodeKeys: affectedKeys
                )
            )
        }

        switch context.request {
        case .resume:
            return .resume(
                updatePlan.resume(
                    completedNodeIdempotencyKeys:
                        context.completedUpdateNodeIdempotencyKeys
                )
            )
        case .automatic where shouldResumeAutomatically(
            failure: context.failure,
            effectedNodes: mutatingEffects
        ):
            return .resume(
                updatePlan.resume(
                    completedNodeIdempotencyKeys:
                        context.completedUpdateNodeIdempotencyKeys
                )
            )
        case .automatic, .rollback:
            break
        }

        if let irreversibleHook = effectedNodes.first(where: {
            $0.action == .runHook
        }) {
            return .safeHold(
                LifecycleRecoverySafeHold(
                    reason:
                        "Hook \(irreversibleHook.key) completed and its external effects " +
                        "cannot be inverted safely.",
                    affectedNodeKeys: affectedKeys
                )
            )
        }

        for node in mutatingEffects {
            guard proof.exactlyOwnedResourceUUIDs.contains(
                node.resourceUUID.lowercased()
            ) else {
                return .safeHold(
                    LifecycleRecoverySafeHold(
                        reason:
                            "Exact ownership is missing for affected resource " +
                            "\(node.resourceUUID).",
                        affectedNodeKeys: affectedKeys
                    )
                )
            }
            guard proof.exactlyInvertibleNodeIdempotencyKeys.contains(
                node.idempotencyKey
            ), node.compensation != nil else {
                return .safeHold(
                    LifecycleRecoverySafeHold(
                        reason:
                            "An exact inverse is unavailable for completed node \(node.key).",
                        affectedNodeKeys: affectedKeys
                    )
                )
            }
        }

        let requiredHealthyIdentities = Set(
            effectedNodes.compactMap(\.serviceName)
        )
        let healthyByServiceName = Dictionary(
            grouping: healthyRevisions,
            by: \.serviceName
        )
        for serviceName in requiredHealthyIdentities
        where healthyByServiceName[serviceName]?.isEmpty != false {
            throw LifecycleRollbackPlanningError.missingHealthyRevision(
                serviceName
            )
        }
        let healthyByResourceUUID = Dictionary(
            uniqueKeysWithValues: healthyRevisions.map {
                ($0.resourceUUID.lowercased(), $0)
            }
        )
        if let missingExactRevision = mutatingEffects.first(where: { effect in
            guard effect.compensation?.action == .create else { return false }
            guard let healthy = healthyByResourceUUID[effect.resourceUUID.lowercased()] else {
                return true
            }
            return healthy.resourceIdentifier != effect.resourceIdentifier ||
                healthy.resourceGeneration != effect.resourceGeneration
        }) {
            return .safeHold(
                LifecycleRecoverySafeHold(
                    reason:
                        "The exact verified healthy revision required to recreate " +
                        "\(missingExactRevision.key) is unavailable.",
                    affectedNodeKeys: affectedKeys
                )
            )
        }

        if let unsafeInverse = firstInverseRequiringUnavailableSensitiveConfiguration(
            in: mutatingEffects,
            healthyRevisions: healthyRevisions
        ) {
            return .safeHold(
                LifecycleRecoverySafeHold(
                    reason:
                        "Rollback inverse \(unsafeInverse.key) requires desired " +
                        "configuration whose redacted sensitive values or references " +
                        "cannot be reconstructed exactly.",
                    affectedNodeKeys: affectedKeys
                )
            )
        }

        let rollbackNodes = try makeRollbackNodes(
            for: mutatingEffects,
            healthyRevisions: healthyRevisions
        )
        let plan = LifecycleRollbackPlan(
            failure: context.failure,
            healthyRevisions: healthyRevisions,
            nodes: rollbackNodes
        )
        return .rollback(
            plan,
            plan.resume(
                completedRollbackNodeIdempotencyKeys:
                    context.completedRollbackNodeIdempotencyKeys
            )
        )
    }

    private func shouldResumeAutomatically(
        failure: LifecycleRolloutFailureKind,
        effectedNodes: [LifecyclePlanNode]
    ) -> Bool {
        if effectedNodes.isEmpty {
            return true
        }
        switch failure {
        case .processTermination:
            return true
        case .cancellation:
            return effectedNodes.isEmpty
        case .startup, .readiness, .runtime, .sqlite:
            return false
        }
    }

    private func makeRollbackNodes(
        for effectedNodes: [LifecyclePlanNode],
        healthyRevisions: [LifecycleHealthyRevisionRecord]
    ) throws -> [LifecyclePlanNode] {
        let healthyByUUID = healthyRevisions.reduce(into: [:]) {
            $0[$1.resourceUUID.lowercased()] = $1
        }
        var rollbackNodes: [LifecyclePlanNode] = []
        var previousRollbackKey: String?
        for effect in effectedNodes.reversed() {
            guard let inverse = effect.compensation else {
                continue
            }
            let key = rollbackKey(for: effect.key)
            let desiredJSON = rollbackDesiredSpecificationJSON(
                for: effect,
                healthyByUUID: healthyByUUID
            )
            let rollback = try LifecyclePlanNode(
                key: key,
                action: inverse.action,
                serviceName: effect.serviceName,
                resourceIdentifier: effect.resourceIdentifier,
                resourceUUID: effect.resourceUUID,
                resourceGeneration: effect.resourceGeneration,
                fencingToken: effect.fencingToken,
                dependencies: previousRollbackKey.map { [$0] } ?? [],
                preconditions: inverse.preconditions,
                postconditions: [
                    LifecyclePlanCondition(
                        kind: "rollback-effect-verified",
                        subject: effect.key,
                        expectedValue: "true"
                    )
                ],
                timeoutSeconds: inverse.timeoutSeconds,
                compensation: LifecycleCompensation(
                    action: effect.action,
                    preconditions: effect.preconditions,
                    timeoutSeconds: effect.timeoutSeconds
                ),
                desiredSpecificationJSONRedacted: desiredJSON
            )
            rollbackNodes.append(rollback)
            previousRollbackKey = rollback.key
        }
        return try LifecyclePlanCompiler.stableTopologicalOrder(rollbackNodes)
    }

    private func firstInverseRequiringUnavailableSensitiveConfiguration(
        in effectedNodes: [LifecyclePlanNode],
        healthyRevisions: [LifecycleHealthyRevisionRecord]
    ) -> LifecyclePlanNode? {
        let healthyByUUID = healthyRevisions.reduce(into: [:]) {
            $0[$1.resourceUUID.lowercased()] = $1
        }
        for effect in effectedNodes.reversed()
        where effect.compensation?.action == .create {
            let desiredJSON = rollbackDesiredSpecificationJSON(
                for: effect,
                healthyByUUID: healthyByUUID
            )
            guard let desired = try? LifecycleRevisionCodec
                .decodeRedactedDesiredJSON(desiredJSON),
                !desired.environment.contains(where: {
                    $0.isSensitive || $0.secretReference != nil
                }) else {
                return effect
            }
        }
        return nil
    }

    private func rollbackDesiredSpecificationJSON(
        for effect: LifecyclePlanNode,
        healthyByUUID: [String: LifecycleHealthyRevisionRecord]
    ) -> String {
        healthyByUUID[effect.resourceUUID.lowercased()]?
            .desiredSpecificationJSONRedacted ??
            effect.desiredSpecificationJSONRedacted
    }

    private func rollbackKey(for updateKey: String) -> String {
        let available = max(1, 127 - "rollback-".count)
        return "rollback-\(String(updateKey.prefix(available)))"
    }

    private func validate(
        healthyRevisions: [LifecycleHealthyRevisionRecord]
    ) throws {
        var identities: Set<RuntimeServiceIdentity> = []
        var resourceUUIDs: Set<String> = []
        for revision in healthyRevisions {
            guard identities.insert(revision.identity).inserted else {
                throw LifecycleRollbackPlanningError.duplicateHealthyRevision(
                    revision.identity.displayName
                )
            }
            guard resourceUUIDs.insert(revision.resourceUUID.lowercased()).inserted else {
                throw LifecycleRollbackPlanningError.duplicateHealthyRevision(
                    revision.resourceUUID.lowercased()
                )
            }
        }
    }
}
