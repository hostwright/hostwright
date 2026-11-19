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

enum LifecycleSpecialNodeEvidence: Equatable, Sendable {
    case satisfied(String)
    case noEffect(String)
    case ambiguous(String)
}

enum LifecycleSpecialExecutionError: Error, Equatable, Sendable {
    case invalidExactBinding
    case invalidHook
    case invalidProbe
    case invalidCompletionCheckpoint
    case staleCapability
    case unavailable(String)
    case outputLimitExceeded
}

enum LifecycleLivenessRecovery: Equatable, Sendable {
    case restarted
    case refused(String)
    case ambiguous(RuntimeNormalizedFailure)
}

actor LifecycleRuntimeExecutionState {
    let projectID: String
    let providerID: RuntimeProviderID
    let capabilitySHA256: String
    let desiredState: DesiredRuntimeState
    var observedState: ObservedRuntimeState
    var bindingsByResourceUUID: [String: LifecycleResourceBinding]
    var desiredByNode: [String: DesiredRuntimeService]
    var specialEvidenceByNodeKey: [String: LifecycleSpecialNodeEvidence] = [:]

    init(
        projectID: String,
        providerID: RuntimeProviderID,
        capabilitySHA256: String,
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState,
        bindings: [RuntimeServiceIdentity: LifecycleResourceBinding],
        desiredByNode: [String: DesiredRuntimeService]
    ) {
        self.projectID = projectID
        self.providerID = providerID
        self.capabilitySHA256 = capabilitySHA256
        self.desiredState = desiredState
        self.observedState = observedState
        self.bindingsByResourceUUID = Dictionary(
            uniqueKeysWithValues: bindings.values.map { ($0.resourceUUID, $0) }
        )
        self.desiredByNode = desiredByNode
    }

    init(
        projectID: String,
        providerID: RuntimeProviderID,
        capabilitySHA256: String,
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState,
        bindings: [LifecycleResourceBinding],
        desiredByNode: [String: DesiredRuntimeService]
    ) {
        self.projectID = projectID
        self.providerID = providerID
        self.capabilitySHA256 = capabilitySHA256
        self.desiredState = desiredState
        self.observedState = observedState
        bindingsByResourceUUID = Dictionary(
            uniqueKeysWithValues: bindings.map { ($0.resourceUUID, $0) }
        )
        self.desiredByNode = desiredByNode
    }

    func binding(for identity: RuntimeServiceIdentity) -> LifecycleResourceBinding? {
        bindingsByResourceUUID.values
            .filter { $0.identity == identity }
            .max {
                ($0.resourceGeneration, $0.resourceIdentifier) <
                    ($1.resourceGeneration, $1.resourceIdentifier)
            }
    }

    func binding(
        resourceUUID: String,
        resourceIdentifier: String?
    ) -> LifecycleResourceBinding? {
        bindingsByResourceUUID.values.first {
            $0.resourceUUID == resourceUUID ||
                $0.resourceIdentifier == resourceIdentifier
        }
    }

    func setBinding(_ binding: LifecycleResourceBinding) {
        bindingsByResourceUUID[binding.resourceUUID] = binding
    }

    func removeBinding(resourceUUID: String) {
        bindingsByResourceUUID.removeValue(forKey: resourceUUID)
    }

    func desiredService(for nodeKey: String) -> DesiredRuntimeService? {
        desiredByNode[nodeKey]
    }

    func setDesiredService(
        _ service: DesiredRuntimeService,
        for nodeKey: String
    ) {
        desiredByNode[nodeKey] = service
    }

    func recordSpecialEvidence(
        _ evidence: LifecycleSpecialNodeEvidence,
        for nodeKey: String
    ) {
        specialEvidenceByNodeKey[nodeKey] = evidence
    }

    func specialEvidence(for nodeKey: String) -> LifecycleSpecialNodeEvidence? {
        specialEvidenceByNodeKey[nodeKey]
    }

    func identity(for node: LifecyclePlanNode, projectName: String) -> RuntimeServiceIdentity {
        if let desired = desiredByNode[node.key] {
            return desired.identity
        }
        if let binding = bindingsByResourceUUID.values.first(where: {
            $0.resourceUUID == node.resourceUUID ||
                $0.resourceIdentifier == node.resourceIdentifier
        }) {
            return binding.identity
        }
        return RuntimeServiceIdentity(
            projectName: projectName,
            serviceName: node.serviceName ?? ""
        )
    }

    func replaceObservedState(_ observedState: ObservedRuntimeState) {
        self.observedState = observedState
    }

    func currentObservedState() -> ObservedRuntimeState {
        observedState
    }

    func desiredStateSnapshot() -> DesiredRuntimeState {
        DesiredRuntimeState(
            projectName: desiredState.projectName,
            networks: desiredState.networks,
            services: desiredState.services,
            ownedResourceHints: bindingsByResourceUUID.values
                .map {
                    RuntimeOwnedResourceHint(
                        resourceIdentifier: $0.resourceIdentifier,
                        identity: $0.identity,
                        identityVersion: $0.identityVersion,
                        ownership: $0.ownershipEvidence
                    )
                }
                .sorted { $0.resourceIdentifier < $1.resourceIdentifier }
        )
    }
}

struct LifecycleLiveValidator: LifecycleSagaContextValidating {
    let adapter: any RuntimeAdapter
    let state: LifecycleRuntimeExecutionState
    let store: SQLiteStateStore
    let groupIdempotencyKey: String?

    init(
        adapter: any RuntimeAdapter,
        state: LifecycleRuntimeExecutionState,
        store: SQLiteStateStore,
        groupIdempotencyKey: String? = nil
    ) {
        self.adapter = adapter
        self.state = state
        self.store = store
        self.groupIdempotencyKey = groupIdempotencyKey
    }

    func validate(
        plan: LifecyclePlan,
        node: LifecyclePlanNode,
        expectedFencingToken: String
    ) async -> LifecycleSagaValidation {
        let capability: RuntimeCapabilitySnapshot
        let inventory: RuntimeInventory
        do {
            capability = try await adapter.capabilitySnapshot()
            inventory = try await adapter.inventory()
        } catch {
            return invalid(plan: plan, expectedFencingToken: expectedFencingToken)
        }
        guard capability.descriptor.providerID == plan.providerID,
              capability.canonicalSHA256 == plan.capabilitySHA256,
              let project = try? store.desiredStates.loadProject(id: plan.projectID),
              project.resourceUUID == plan.projectResourceUUID,
              project.providerGeneration == plan.providerGeneration,
              project.mutationProvider.flatMap(RuntimeProviderBinding.stableID(for:)) ==
                plan.providerID else {
            return invalid(plan: plan, expectedFencingToken: expectedFencingToken)
        }
        let binding = await state.binding(
            resourceUUID: node.resourceUUID,
            resourceIdentifier: node.resourceIdentifier
        )
        let records: [OwnershipRecord]
        do {
            records = try store.ownership.loadAll()
        } catch {
            return invalid(plan: plan, expectedFencingToken: expectedFencingToken)
        }
        let record = records.first {
            $0.resourceUUID == node.resourceUUID ||
                ($0.resourceIdentifier == node.resourceIdentifier &&
                    RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) == plan.providerID)
        }
        let containers = inventory.containers.filter {
            $0.ownership?.resourceUUID == node.resourceUUID ||
                $0.name == node.resourceIdentifier ||
                $0.runtimeID == node.resourceIdentifier
        }
        let absentCandidate =
            (node.action == .create || node.action == .validate) &&
            record == nil &&
            containers.isEmpty
        let absentReplacementCandidate =
            node.action == .create &&
            containers.isEmpty &&
            record.map {
                $0.resourceIdentifier == node.resourceIdentifier &&
                    $0.resourceUUID == node.resourceUUID &&
                    $0.resourceGeneration < node.resourceGeneration &&
                    $0.projectResourceUUID ==
                        plan.projectResourceUUID &&
                    $0.projectGeneration == plan.projectGeneration &&
                    $0.providerGeneration == plan.providerGeneration &&
                    RuntimeProviderBinding.stableID(
                        for: $0.runtimeAdapter
                    ) == plan.providerID &&
                    binding?.resourceIdentifier ==
                        $0.resourceIdentifier &&
                    binding?.resourceUUID == $0.resourceUUID &&
                    binding?.resourceGeneration ==
                        $0.resourceGeneration &&
                    binding?.currentFencingToken ==
                        $0.fencingToken
            } == true
        let absentVerifiedInverse =
            node.compensation?.action == .create &&
            record == nil &&
            containers.isEmpty &&
            verifiedForwardEffect(plan: plan, node: node)
        let absentVerifiedRollbackCreate =
            plan.command == .rollback &&
            node.action == .create &&
            record == nil &&
            containers.isEmpty &&
            verifiedRollbackSource(plan: plan, node: node)
        let stateOwned = record.map {
            $0.resourceUUID == node.resourceUUID &&
                $0.resourceGeneration == node.resourceGeneration &&
                $0.projectResourceUUID == plan.projectResourceUUID &&
                $0.projectGeneration == plan.projectGeneration &&
                $0.providerGeneration == plan.providerGeneration &&
                RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) == plan.providerID &&
                ($0.fencingToken == expectedFencingToken ||
                    $0.fencingToken == binding?.currentFencingToken)
        } ?? false
        let runtimeOwned = containers.count == 1 &&
            containers[0].ownership.map {
                $0.resourceUUID == node.resourceUUID &&
                    $0.resourceGeneration == node.resourceGeneration &&
                    $0.projectUUID == plan.projectResourceUUID &&
                    $0.projectGeneration == plan.projectGeneration &&
                    $0.providerID == plan.providerID &&
                    $0.providerGeneration == plan.providerGeneration
            } == true
        return LifecycleSagaValidation(
            providerID: capability.descriptor.providerID,
            providerGeneration: plan.providerGeneration,
            capabilitySHA256: capability.canonicalSHA256,
            projectResourceUUID: project.resourceUUID,
            projectGeneration: plan.projectGeneration,
            fencingToken: expectedFencingToken,
            ownershipVerified:
                absentCandidate ||
                absentReplacementCandidate ||
                absentVerifiedInverse ||
                absentVerifiedRollbackCreate ||
                (stateOwned && runtimeOwned)
        )
    }

    private func verifiedForwardEffect(
        plan: LifecyclePlan,
        node: LifecyclePlanNode
    ) -> Bool {
        guard let group = try? store.operationGroups.latest(
            groupIdempotencyKey: groupIdempotencyKey ?? plan.planSHA256
        ),
        group.planHash == plan.planSHA256,
        let steps = try? store.operationGroupSteps.load(groupID: group.id) else {
            return false
        }
        return steps.last {
            $0.direction == .forward && $0.stepKey == node.key
        }?.status == .succeeded
    }

    private func verifiedRollbackSource(
        plan: LifecyclePlan,
        node: LifecyclePlanNode
    ) -> Bool {
        guard let source = node.preconditions.first(where: {
            $0.kind == "rollback-source-group"
        }),
        let group = try? store.operationGroups.load(id: source.subject),
        group.planHash == source.expectedValue,
        let sourcePlan = try? LifecyclePersistedIntentCodec.decode(
            group.intentJSONRedacted
        ),
        sourcePlan.planSHA256 == group.planHash,
        let sourceNodeKey = node.postconditions.first(where: {
            $0.kind == "rollback-effect-verified" &&
                $0.expectedValue == "true"
        })?.subject,
        let sourceNode = sourcePlan.nodes.first(where: {
            $0.key == sourceNodeKey &&
                $0.resourceUUID == node.resourceUUID &&
                $0.resourceIdentifier == node.resourceIdentifier &&
                $0.compensation?.action == node.action
        }),
        let steps = try? store.operationGroupSteps.load(groupID: group.id) else {
            return false
        }
        guard let latest = steps.last(where: {
            $0.direction == .forward &&
                $0.stepKey == sourceNode.key
        }) else {
            return false
        }
        if latest.status == .succeeded {
            return true
        }
        return latest.status == .started &&
            node.preconditions.contains {
                $0.kind == "rollback-source-effect-reobserved" &&
                    $0.subject == sourceNode.key &&
                    $0.expectedValue == group.planHash
            }
    }

    func invalid(
        plan: LifecyclePlan,
        expectedFencingToken: String
    ) -> LifecycleSagaValidation {
        LifecycleSagaValidation(
            providerID: plan.providerID,
            providerGeneration: 0,
            capabilitySHA256: "",
            projectResourceUUID: plan.projectResourceUUID,
            projectGeneration: 0,
            fencingToken: expectedFencingToken,
            ownershipVerified: false
        )
    }
}
