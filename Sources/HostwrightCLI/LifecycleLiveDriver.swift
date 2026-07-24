import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

struct LifecycleLiveDriver: LifecycleCommandDriving {
    let environment: CLIEnvironment
    let options: LifecycleCLIOptions

    init(environment: CLIEnvironment, options: LifecycleCLIOptions) {
        self.environment = environment
        self.options = options
    }

    func prepare(options: LifecycleCLIOptions) throws -> LifecycleCommandPreparation {
        let manifestText = try hostwrightReadManifestText(
            path: options.manifestPath,
            environment: environment
        )
        let validated = try hostwrightValidatedManifest(
            text: manifestText,
            teamProfilePath: nil,
            environment: environment
        )
        let manifest = validated.manifest
        let mapping = ManifestRuntimeMapper.map(
            manifest,
            bindMountBaseDirectory: manifestBaseDirectory(for: options.manifestPath)
        )
        let store = SQLiteStateStore(
            configuration: try hostwrightStateStoreConfiguration(
                explicitPath: options.stateDatabasePath,
                environment: environment
            )
        )
        try store.migrate()

        let projectName = mapping.desiredState.projectName
        let projectID = "project-\(projectName)"
        let selectedProvider = try hostwrightSelectRuntimeProvider(
            requested: options.runtimeProvider,
            store: store,
            projectID: projectID,
            requiredFeatures: [.observation, .lifecycle],
            environment: environment
        )
        let providerID = selectedProvider.selection.providerID
        let providerGeneration = currentProviderGeneration(
            store: store,
            projectID: projectID,
            providerID: providerID
        )
        let resourceBindings = try lifecycleBindings(
            store: store,
            projectID: projectID,
            providerID: providerID,
            desiredState: mapping.desiredState
        )
        let previousDesiredState = try lifecycleHealthyDesiredState(
            store: store,
            projectID: projectID,
            providerID: providerID,
            bindings: resourceBindings
        )
        let desiredState = DesiredRuntimeState(
            projectName: mapping.desiredState.projectName,
            services: mapping.desiredState.services,
            ownedResourceHints: resourceBindings.map {
                RuntimeOwnedResourceHint(
                    resourceIdentifier: $0.resourceIdentifier,
                    identity: $0.identity,
                    identityVersion: $0.identityVersion,
                    ownership: $0.ownershipEvidence
                )
            }
        )
        let adapter = selectedProvider.adapter
        let observedState = try hostwrightWaitForAsync {
            try await adapter.observe(desiredState: desiredState)
        }
        guard let observedMetadata = observedState.adapterMetadata,
              observedMetadata.providerID == providerID,
              RuntimeProviderCompatibility.mutationIncompatibility(observedMetadata) == nil,
              observedState.capabilitySHA256 == selectedProvider.selection.capabilitySHA256 else {
            throw HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message: "Lifecycle observation returned stale or incompatible provider metadata. No mutation was attempted."
            )
        }
        let inventory = try hostwrightWaitForAsync {
            try await adapter.inventory()
        }
        let projectResourceUUID = try currentProjectResourceUUID(
            store: store,
            projectID: projectID,
            fallbackBindings: resourceBindings
        )
        let projectGeneration = max(
            resourceBindings.map(\.projectGeneration).max() ?? 1,
            1
        )
        let selectedServices = options.serviceNames.isEmpty
            ? mapping.desiredState.services.map(\.logicalServiceName).sorted()
            : options.serviceNames.sorted()
        let planFence = lifecyclePlanFence(
            command: options.command,
            manifestSHA256: sha256(manifestText),
            observationSHA256: inventory.semanticSHA256,
            capabilitySHA256: selectedProvider.selection.capabilitySHA256,
            projectID: projectID,
            providerID: providerID,
            providerGeneration: providerGeneration,
            selectedServices: selectedServices,
            timeoutSeconds: options.timeoutSeconds,
            parallelism: options.parallelism,
            resourceBindings: resourceBindings
        )

        return LifecycleCommandPreparation(
            manifestSHA256: sha256(manifestText),
            manifestBaseDirectory: manifestBaseDirectory(for: options.manifestPath),
            mappingIssues: mapping.issues,
            desiredState: desiredState,
            previousDesiredState: previousDesiredState,
            observedState: observedState,
            observationSHA256: inventory.semanticSHA256,
            projectID: projectID,
            projectResourceUUID: projectResourceUUID,
            projectGeneration: projectGeneration,
            providerID: providerID,
            providerGeneration: providerGeneration,
            capabilitySHA256: selectedProvider.selection.capabilitySHA256,
            planFencingToken: planFence,
            resourceBindings: resourceBindings,
            unmanagedResourceIdentifiers: lifecycleUnmanagedIdentifiers(
                inventory: inventory,
                bindings: resourceBindings
            )
        )
    }

    func localImageEvidence(
        for requirement: LifecycleLocalImageRequirement,
        preparation: LifecycleCommandPreparation
    ) throws -> RuntimeLocalImageEvidence {
        let adapter = try environment.runtimeAdapterForProvider(preparation.providerID)
        return try hostwrightWaitForAsync {
            try await adapter.localImageEvidence(for: requirement.reference)
        }
    }

    func revalidate(
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation
    ) throws {
        let fresh = try prepare(options: options)
        let freshPlan = try LifecycleCommandPlanCompiler().compile(
            options: options,
            preparation: fresh
        )
        guard freshPlan.plan.planSHA256 == compiled.plan.planSHA256 else {
            throw LifecycleCommandRunnerError.confirmationMismatch(
                expected: freshPlan.plan.planSHA256,
                provided: compiled.plan.planSHA256
            )
        }
    }

    func execute(
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation,
        options: LifecycleCLIOptions
    ) throws -> LifecycleSagaExecutionResult {
        let store = SQLiteStateStore(
            configuration: try hostwrightStateStoreConfiguration(
                explicitPath: options.stateDatabasePath,
                environment: environment
            )
        )
        try store.migrate()
        let manifestText = try hostwrightReadManifestText(
            path: options.manifestPath,
            environment: environment
        )
        let executionManifestSHA256 = sha256(manifestText)
        guard executionManifestSHA256 == preparation.manifestSHA256,
              executionManifestSHA256 == compiled.plan.manifestSHA256 else {
            throw LifecycleCommandRunnerError.confirmationMismatch(
                expected: compiled.plan.manifestSHA256,
                provided: executionManifestSHA256
            )
        }
        let adapter = try environment.runtimeAdapterForProvider(preparation.providerID)
        try lifecyclePreflightDesiredExecution(
            compiled: compiled,
            preparation: preparation,
            options: options,
            environment: environment,
            adapter: adapter
        )
        let validated = try hostwrightValidatedManifest(
            text: manifestText,
            teamProfilePath: nil,
            environment: environment
        )
        let now = hostwrightTimestamp()
        let recoverySnapshot: DesiredStateRecoverySnapshot?
        if compiled.plan.command == .update {
            guard let snapshot = try store.desiredStates.loadRecoverySnapshot(
                projectID: preparation.projectID
            ) else {
                throw StateStoreError.invalidRecord(
                    "Lifecycle update requires one authoritative healthy desired-state snapshot."
                )
            }
            recoverySnapshot = snapshot
        } else {
            recoverySnapshot = nil
        }
        let recoveryStateJSONRedacted = try recoverySnapshot.map(
            lifecycleRecoveryStateJSONRedacted
        )
        try store.desiredStates.saveManifestSnapshot(
            projectID: preparation.projectID,
            manifestPath: options.manifestPath,
            manifestHash: preparation.manifestSHA256,
            desiredGeneration: preparation.providerGeneration,
            manifest: validated.manifest,
            timestamp: now,
            mutationProvider: preparation.providerID.rawValue
        )
        try store.observedStates.saveSnapshot(
            snapshotID: HostwrightResourceUUID.generate(),
            projectID: preparation.projectID,
            observedState: preparation.observedState,
            runtimeAdapter: preparation.providerID.rawValue,
            parserVersion: "phase04-lifecycle-v1",
            rawOutputHash: nil,
            redactedSummary: "phase04.lifecycle.prepare",
            observedAt: now
        )

        let state = LifecycleRuntimeExecutionState(
            projectID: preparation.projectID,
            providerID: preparation.providerID,
            capabilitySHA256: preparation.capabilitySHA256,
            desiredState: preparation.desiredState,
            observedState: preparation.observedState,
            bindings: Dictionary(
                uniqueKeysWithValues: preparation.resourceBindings.map { ($0.identity, $0) }
            ),
            desiredByNode: compiled.desiredServicesByNodeKey
        )
        let probeStore = LifecycleProbeCheckpointStore(store: store)
        let validator = LifecycleLiveValidator(
            adapter: adapter,
            state: state,
            store: store
        )
        let effects = LifecycleLiveEffects(
            adapter: adapter,
            state: state,
            store: store,
            probeStore: probeStore,
            environment: environment
        )
        let executor = LifecycleSagaExecutor(
            store: store,
            effects: effects,
            validator: validator,
            recoveryStateJSONRedacted: recoveryStateJSONRedacted
        )
        let operationID = HostwrightResourceUUID.legacy(
            kind: "lifecycle-operation",
            identifier: compiled.plan.planSHA256
        )
        let groupID = HostwrightResourceUUID.legacy(
            kind: "lifecycle-group",
            identifier: compiled.plan.planSHA256
        )
        let result = try hostwrightWaitForAsync {
            try await executor.execute(
                plan: compiled.plan,
                operationID: operationID,
                groupID: groupID,
                fencingToken: preparation.planFencingToken,
                lockOwner: "hostwright-cli"
            )
        }
        if result.status == .compensated, let recoverySnapshot {
            try lifecycleRestoreHealthyDesiredState(
                recoverySnapshot,
                sourcePlan: compiled.plan,
                store: store
            )
        }
        return result
    }
}

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

private func lifecycleRestoreHealthyDesiredState(
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

private struct LifecycleRecoveryRuntime {
    let adapter: any RuntimeAdapter
    let state: LifecycleRuntimeExecutionState
    let effects: LifecycleLiveEffects
}

private struct LifecycleRecoveredForwardObservation: Sendable {
    let node: LifecyclePlanNode
    let observation: LifecycleSagaObservation
}

private struct LifecycleRecoveryDeadlineElapsed: Error {}

private struct LifecycleRecoveryDeadline: Sendable {
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

private struct LifecycleRecoveryDeadlineEffects: LifecycleSagaEffects {
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
        guard sourceGroup.planHash == request.confirmationPlanSHA256,
              let persistedPlan = try? LifecyclePersistedIntentCodec.decode(
                  sourceGroup.intentJSONRedacted
              ),
              persistedPlan.planSHA256 == sourceGroup.planHash,
              persistedPlan.projectID == sourceGroup.projectID,
              persistedPlan.nodes.allSatisfy({
                  $0.fencingToken == sourceGroup.fencingToken
              }) else {
            throw LifecyclePersistedRecoveryError.confirmationMismatch
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
            guard sourceGroup.status == .interrupted ||
                    isExpiredActive(sourceGroup) else {
                throw LifecyclePersistedRecoveryError.unavailable(
                    "Only an interrupted lifecycle operation or its exact expired active lease can be resumed."
                )
            }
            let result = try await execute(
                plan: persistedPlan,
                operationID: sourceGroup.operationID,
                groupID: sourceGroup.id,
                fencingToken: sourceGroup.fencingToken,
                lockOwner: "hostwright-recovery-resume",
                store: store,
                deadline: deadline,
                recoveryStateJSONRedacted:
                    try recoverySnapshot.map(
                        lifecycleRecoveryStateJSONRedacted
                    )
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
            guard sourceGroup.status == .interrupted ||
                    sourceGroup.status == .failed,
                  sourceGroup.rollbackAvailable,
                  persistedPlan.command == .update else {
                throw LifecyclePersistedRecoveryError.unavailable(
                    "Only an interrupted or failed update with recorded inverses can be rolled back."
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
                lockOwner: "hostwright-recovery-rollback",
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

    private func isCompletedCompensation(
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

    private func isExpiredActive(_ group: OperationGroupRecord) -> Bool {
        guard group.status == .active,
              let lockExpiresAt = group.lockExpiresAt,
              let expiry = ISO8601DateFormatter().date(from: lockExpiresAt) else {
            return false
        }
        return expiry <= Date()
    }

    private func execute(
        plan: LifecyclePlan,
        operationID: String,
        groupID: String,
        fencingToken: String,
        lockOwner: String,
        store: SQLiteStateStore,
        deadline: LifecycleRecoveryDeadline,
        recoveryStateJSONRedacted: String? = nil
    ) async throws -> LifecycleSagaExecutionResult {
        let runtime = try await recoveryRuntime(
            plan: plan,
            store: store,
            deadline: deadline
        )
        return try await LifecycleSagaExecutor(
            store: store,
            effects: LifecycleRecoveryDeadlineEffects(
                base: runtime.effects,
                deadline: deadline
            ),
            validator: LifecycleLiveValidator(
                adapter: runtime.adapter,
                state: runtime.state,
                store: store
            ),
            recoveryStateJSONRedacted: recoveryStateJSONRedacted
        ).execute(
            plan: plan,
            operationID: operationID,
            groupID: groupID,
            fencingToken: fencingToken,
            lockOwner: lockOwner
        )
    }

    private func recoveryRuntime(
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
        let desiredState = DesiredRuntimeState(
            projectName: plan.projectName,
            services: desiredServices,
            ownedResourceHints: bindings.map {
                RuntimeOwnedResourceHint(
                    resourceIdentifier: $0.resourceIdentifier,
                    identity: $0.identity,
                    identityVersion: $0.identityVersion,
                    ownership: $0.ownershipEvidence
                )
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
            environment: environment
        )
        return LifecycleRecoveryRuntime(
            adapter: adapter,
            state: state,
            effects: effects
        )
    }

    private func makeRollbackPlan(
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

    private func recoveryDesiredServices(
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

    private func recoveryBindings(
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

    private func recoveryDesiredStateServices(
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

enum LifecycleSpecialNodeEvidence: Equatable, Sendable {
    case satisfied(String)
    case noEffect(String)
    case ambiguous(String)
}

enum LifecycleSpecialExecutionError: Error, Equatable, Sendable {
    case invalidExactBinding
    case invalidHook
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

private struct LifecycleHookCheckpoint: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let nodeKey: String
    let effectPossible: Bool
    let diagnosticRedacted: String
}

private struct LifecycleCompletionCheckpoint: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let nodeKey: String
    let diagnosticRedacted: String
}

private final class LifecycleHookOutputBudget: @unchecked Sendable {
    private let lock = NSLock()
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

actor LifecycleRuntimeExecutionState {
    let projectID: String
    let providerID: RuntimeProviderID
    let capabilitySHA256: String
    let desiredState: DesiredRuntimeState
    var observedState: ObservedRuntimeState
    var bindingsByResourceUUID: [String: LifecycleResourceBinding]
    let desiredByNode: [String: DesiredRuntimeService]
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
                    $0.providerGeneration == plan.providerGeneration &&
                    ($0.fencingToken == expectedFencingToken ||
                        $0.fencingToken == binding?.currentFencingToken)
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
            groupIdempotencyKey: plan.planSHA256
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

    private func invalid(
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

struct LifecycleLiveEffects: LifecycleSagaEffects {
    let adapter: any RuntimeAdapter
    let state: LifecycleRuntimeExecutionState
    let store: SQLiteStateStore
    let probeStore: LifecycleProbeCheckpointStore
    let environment: CLIEnvironment
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
            return .accepted
        }
        if node.action == .verify {
            guard probeKind(for: node) != nil else {
                return .accepted
            }
            return await applyProbe(node: node, context: context)
        }
        do {
            if node.action != .create,
               let binding = await state.binding(
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
            if action.requiresProcessCompletion {
                return await applyCompletionAwareStart(
                    action,
                    confirmation: confirmation,
                    node: node,
                    context: context
                )
            }
            _ = try await adapter.execute(action, confirmation: confirmation)
            return .accepted
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
            let desired = await state.desiredStateSnapshot()
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
                        context: context
                    )
                    return .satisfied(specialVerification)
                case .noEffect(let summary):
                    try await releaseResourceFenceIfNeeded(
                        node: node,
                        context: context
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
                try await persistVerifiedProjection(
                    node: node,
                    context: context,
                    identity: identity,
                    exactContainer: exactContainer,
                    observed: observed,
                    observationSHA256: inventory.semanticSHA256
                )
                try await releaseResourceFenceIfNeeded(node: node, context: context)
                return .satisfied(verification)
            }
            if noEffectObserved(
                node: node,
                exactContainer: exactContainer,
                observedService: matches.first,
                collisionCount: containers.count
            ) {
                try await releaseResourceFenceIfNeeded(node: node, context: context)
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

    func compensate(
        compensation: LifecycleCompensation,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaCompensationOutcome {
        if compensation.action == .create,
           let desired = await state.desiredService(for: node.key),
           desired.environment.contains(where: {
               $0.isSensitive && $0.secretReference == nil
           }) {
            return .failed(
                RuntimeNormalizedFailure(
                    category: .ambiguousEffect,
                    retryDisposition: .never,
                    recoveryDisposition: .none,
                    providerID: context.plan.providerID.rawValue,
                    providerVersion:
                        "bound-generation-\(context.plan.providerGeneration)",
                    operationID: context.operationID,
                    diagnostic:
                        "Rollback requires sensitive configuration that cannot be reconstructed exactly.",
                    guidance:
                        "Preserve the safe-hold checkpoint and restore the verified revision with an available secret provider."
                )
            )
        }
        do {
            let compensatingNode = try LifecyclePlanNode(
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
                desiredSpecificationJSONRedacted: node.desiredSpecificationJSONRedacted
            )
            switch await apply(node: compensatingNode, context: context) {
            case .accepted:
                switch await observe(node: compensatingNode, context: context) {
                case .satisfied(let verification):
                    _ = try await reconcileCompensatedOwnershipProjection(
                        context: context,
                        allowObservedRuntimeFence: false
                    )
                    return .compensated(verification)
                case .noEffect, .effectPresent:
                    return .failed(
                        RuntimeNormalizedFailure(
                            category: .partialEffect,
                            retryDisposition: .resumeFromCheckpoint,
                            recoveryDisposition: .resume,
                            providerID: context.plan.providerID.rawValue,
                            providerVersion: "bound-generation-\(context.plan.providerGeneration)",
                            operationID: context.operationID,
                            diagnostic: "Compensation did not satisfy its exact structured postcondition.",
                            guidance: "Preserve the safe-hold checkpoint and inspect only the exact owned resource."
                        )
                    )
                case .ambiguous:
                    return .failed(
                        RuntimeNormalizedFailure(
                            category: .ambiguousEffect,
                            retryDisposition: .safeAfterObservation,
                            recoveryDisposition: .reobserve,
                            providerID: context.plan.providerID.rawValue,
                            providerVersion: "bound-generation-\(context.plan.providerGeneration)",
                            operationID: context.operationID,
                            diagnostic: "Compensation could not be verified by structured observation.",
                            guidance: "Preserve the safe-hold checkpoint and inspect only the exact owned resource."
                        )
                    )
                }
            case .failed(let failure):
                return .failed(failure)
            }
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
                    guidance: "Re-observe the exact owned resource before deciding whether compensation is complete."
                )
            )
        }
    }

    @discardableResult
    func reconcileCompensatedOwnershipProjection(
        context: LifecycleSagaContext,
        allowObservedRuntimeFence: Bool
    ) async throws -> Int {
        let inventory = try await adapter.inventory()
        let records = try store.ownership.loadAll()
        var bindingsByResourceUUID: [
            String: LifecycleResourceBinding
        ] = [:]
        for record in records where
            record.projectID == context.plan.projectID &&
            record.fencingToken == context.fencingToken
        {
            if let binding = await state.binding(
                resourceUUID: record.resourceUUID,
                resourceIdentifier: record.resourceIdentifier
            ) {
                bindingsByResourceUUID[record.resourceUUID] = binding
            }
        }
        let restoredRecords =
            try lifecycleRestoreCompensatedOwnershipProjection(
                store: store,
                plan: context.plan,
                operationFencingToken: context.fencingToken,
                inventory: inventory,
                expectedPriorFencesByResourceUUID: bindingsByResourceUUID
                    .mapValues(\.currentFencingToken),
                allowObservedRuntimeFence: allowObservedRuntimeFence
            )
        for restored in restoredRecords {
            guard let binding = bindingsByResourceUUID[
                restored.resourceUUID
            ] else {
                throw StateStoreError.invalidRecord(
                    "Completed compensation lost its exact in-memory ownership binding."
                )
            }
            await state.setBinding(
                try LifecycleResourceBinding(
                    record: restored,
                    identity: binding.identity,
                    providerID: context.plan.providerID
                )
            )
        }
        return restoredRecords.count
    }

    private func rolloutDeadlineFailure(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) -> RuntimeNormalizedFailure? {
        guard context.plan.command == .update,
              context.direction == .forward else {
            return nil
        }
        let conditions = node.preconditions.filter {
            $0.kind == "progress-deadline-seconds"
        }
        guard conditions.count == 1,
              let seconds = Int(conditions[0].expectedValue),
              seconds > 0,
              let group = try? store.operationGroups.latest(
                  groupIdempotencyKey: context.plan.planSHA256
              ),
              group.id == context.groupID,
              let startedAt = lifecycleEpochMilliseconds(group.createdAt) else {
            return RuntimeNormalizedFailure(
                category: .staleCapability,
                retryDisposition: .never,
                recoveryDisposition: .none,
                providerID: context.plan.providerID.rawValue,
                providerVersion:
                    "bound-generation-\(context.plan.providerGeneration)",
                operationID: context.operationID,
                diagnostic:
                    "Rollout progress deadline evidence is missing or invalid.",
                guidance:
                    "Preserve the fenced operation and inspect its durable intent before retrying."
            )
        }
        guard nowMilliseconds() >= startedAt + Int64(seconds) * 1_000 else {
            return nil
        }
        return RuntimeNormalizedFailure(
            category: .timedOut,
            retryDisposition: .never,
            recoveryDisposition: .compensate,
            providerID: context.plan.providerID.rawValue,
            providerVersion:
                "bound-generation-\(context.plan.providerGeneration)",
            operationID: context.operationID,
            diagnostic:
                "Rollout progress deadline of \(seconds) seconds was exceeded before \(node.key).",
            guidance:
                "Restore the last verified healthy revision through the recorded compensation checkpoints."
        )
    }

    private func probeKind(for node: LifecyclePlanNode) -> RuntimeProbeKind? {
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

    private func applyHook(
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

    private func applyCompletionAwareStart(
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
        } catch {
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
            _ = try await adapter.execute(action, confirmation: confirmation)
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

    private func applyProbe(
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

            let requiredKinds = RuntimeProbeKind.allCases.filter { kind in
                guard desired.probes[kind] != nil else { return false }
                return kind == .startup || kind == targetKind
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

    private func hookCommand(
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

    private func normalizedSpecialFailure(
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

    private func specialFailure(
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
            _ = try await adapter.execute(action, confirmation: confirmation)
            return .restarted
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
                    "hook:\(sha256("\(node.key):\(status.rawValue):\(effectPossible)"))",
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

    private func loadHookCheckpoint(
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
                    "completion:\(sha256("\(node.key):\(status.rawValue)"))",
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

    private func loadCompletionCheckpoint(
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

    private func resolveSecretReferences(
        _ service: DesiredRuntimeService
    ) throws -> DesiredRuntimeService {
        guard service.environment.contains(where: { $0.secretReference != nil }) else {
            return service
        }
        let secretStore = environment.secretStore()
        let resolved = try service.environment.map { entry in
            guard let reference = entry.secretReference else {
                return entry
            }
            return RuntimeEnvironmentValue(
                name: entry.name,
                value: try secretStore.readString(reference: reference),
                isSensitive: true
            )
        }
        return lifecycleReplacingEnvironment(in: service, with: resolved)
    }

    private func plannedAction(
        _ node: LifecyclePlanNode,
        plan: LifecyclePlan
    ) async throws -> PlannedRuntimeAction {
        let identity = await state.identity(for: node, projectName: plan.projectName)
        let kind: PlannedRuntimeActionKind
        switch node.action {
        case .create: kind = .create
        case .start: kind = .start
        case .stop: kind = .stop
        case .restart: kind = .restart
        case .delete, .retire: kind = .remove
        default:
            throw RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: "Lifecycle action \(node.action.rawValue) is not executable through the runtime adapter."
            )
        }
        let desiredService: DesiredRuntimeService?
        if kind == .create, let service = await state.desiredService(for: node.key) {
            desiredService = try resolveSecretReferences(service)
        } else {
            desiredService = nil
        }
        return PlannedRuntimeAction(
            kind: kind,
            identity: identity,
            resourceIdentifier: node.resourceIdentifier ?? identity.managedResourceIdentifier,
            isDestructive:
                kind == .remove ||
                kind == .restart ||
                kind == .stop,
            requiresProcessCompletion:
                kind == .start && isCompletionAwareStart(node),
            summary: node.key,
            desiredService: desiredService
        )
    }

    private func mutationContext(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: context.plan.providerID,
            capabilitySHA256: context.plan.capabilitySHA256,
            operationID: context.operationID,
            resourceUUID: node.resourceUUID,
            resourceGeneration: node.resourceGeneration,
            projectResourceUUID: context.plan.projectResourceUUID,
            projectGeneration: context.plan.projectGeneration,
            providerGeneration: context.plan.providerGeneration,
            fencingToken: context.fencingToken
        )
    }

    private func exactOwnership(
        _ ownership: RuntimeInventoryOwnershipEvidence?,
        node: LifecyclePlanNode,
        plan: LifecyclePlan,
        binding: LifecycleResourceBinding?
    ) -> Bool {
        guard let ownership else { return false }
        return ownership.resourceUUID == node.resourceUUID &&
            ownership.resourceGeneration == node.resourceGeneration &&
            ownership.projectUUID == plan.projectResourceUUID &&
            ownership.projectGeneration == plan.projectGeneration &&
            ownership.providerID == plan.providerID &&
            ownership.providerGeneration == plan.providerGeneration &&
            (ownership.fencingToken == node.fencingToken ||
                ownership.fencingToken == binding?.currentFencingToken)
    }

    private func postconditionSatisfied(
        node: LifecyclePlanNode,
        exactContainer: RuntimeInventoryContainer?,
        observedService: ObservedRuntimeService?,
        desiredService: DesiredRuntimeService?
    ) -> Bool {
        switch node.action {
        case .validate:
            return exactContainer == nil && observedService == nil
        case .create:
            return exactContainer != nil &&
                observedService?.lifecycleState != .missing
        case .start, .restart:
            return exactContainer != nil &&
                observedService?.lifecycleState == .running
        case .stop:
            return exactContainer != nil &&
                [.created, .stopped, .exited].contains(
                    observedService?.lifecycleState ?? .unknown
                )
        case .delete, .retire:
            return exactContainer == nil && observedService == nil
        case .verify:
            guard let observedService else { return false }
            return node.postconditions.allSatisfy { condition in
                switch condition.kind {
                case "dependency-started":
                    return observedService.lifecycleState != .missing &&
                        observedService.lifecycleState != .unknown
                case "dependency-completed":
                    return observedService.lifecycleState == .exited
                case "dependency-ready", "probe-readiness":
                    if desiredService?.probes.readiness == nil {
                        return observedService.lifecycleState == .running
                    }
                    return observedService.healthState == .healthy
                case "probe-startup":
                    return observedService.lifecycleState == .running &&
                        observedService.healthState != .unhealthy
                default:
                    return observedService.lifecycleState == .running
                }
            }
        case .promote:
            return exactContainer != nil &&
                observedService?.lifecycleState == .running &&
                observedService?.healthState != .unhealthy
        case .runHook:
            return false
        default:
            return false
        }
    }

    private func isCompletionAwareStart(_ node: LifecyclePlanNode) -> Bool {
        node.action == .start &&
            node.postconditions.contains {
                $0.kind == "lifecycle" &&
                    $0.expectedValue == RuntimeLifecycleState.exited.rawValue
            }
    }

    private func lifecycleDeleteTargetStillPresent(
        node: LifecyclePlanNode,
        containers: [RuntimeInventoryContainer]
    ) -> Bool {
        guard node.action == .delete || node.action == .retire else {
            return false
        }
        return containers.contains {
            $0.ownership?.resourceUUID == node.resourceUUID ||
                $0.name == node.resourceIdentifier ||
                $0.runtimeID == node.resourceIdentifier
        }
    }

    private func noEffectObserved(
        node: LifecyclePlanNode,
        exactContainer: RuntimeInventoryContainer?,
        observedService: ObservedRuntimeService?,
        collisionCount: Int
    ) -> Bool {
        guard collisionCount <= 1 else { return false }
        switch node.action {
        case .create:
            return exactContainer == nil && observedService == nil
        case .start:
            return exactContainer != nil &&
                [.created, .stopped, .exited].contains(
                    observedService?.lifecycleState ?? .unknown
                )
        case .stop:
            return exactContainer != nil &&
                observedService?.lifecycleState == .running
        case .delete, .retire:
            return exactContainer != nil
        case .restart, .validate, .verify, .runHook, .promote:
            return false
        default:
            return false
        }
    }

    private func persistVerifiedProjection(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        identity: RuntimeServiceIdentity,
        exactContainer: RuntimeInventoryContainer?,
        observed: ObservedRuntimeState,
        observationSHA256: String
    ) async throws {
        let now = hostwrightTimestamp()
        let desiredForNode = await state.desiredService(for: node.key)
        if node.action == .create, let exactContainer {
            let record = OwnershipRecord(
                id: HostwrightResourceUUID.generate(),
                resourceIdentifier: node.resourceIdentifier ?? exactContainer.name,
                resourceType: "container",
                projectID: context.plan.projectID,
                serviceName: identity.serviceName,
                runtimeAdapter: context.plan.providerID.rawValue,
                createdAt: now,
                observedAt: now,
                cleanupEligible: true,
                metadataJSONRedacted: try lifecycleOwnershipMetadataJSON(
                    identity: identity,
                    desiredService: desiredForNode,
                    healthy: false,
                    capabilitySHA256: context.plan.capabilitySHA256,
                    planSHA256: context.plan.planSHA256
                ),
                identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                resourceUUID: node.resourceUUID,
                resourceGeneration: node.resourceGeneration,
                projectResourceUUID: context.plan.projectResourceUUID,
                projectGeneration: context.plan.projectGeneration,
                providerGeneration: context.plan.providerGeneration,
                fencingToken: context.fencingToken
            )
            try store.ownership.upsert(record)
            await state.setBinding(
                try LifecycleResourceBinding(
                    record: record,
                    identity: identity,
                    providerID: context.plan.providerID
                )
            )
        }
        let marksHealthyRevision = node.action == .promote ||
            (node.action == .verify &&
                node.postconditions.contains(where: {
                    $0.kind == "probe-readiness" ||
                        $0.kind == "dependency-ready"
                })) ||
            (node.action == .start &&
                context.plan.command != .update &&
                desiredForNode?.probes.startup == nil &&
                desiredForNode?.probes.readiness == nil)
        if marksHealthyRevision {
            try await markHealthyRevision(
                node: node,
                context: context,
                identity: identity,
                observedAt: now
            )
        }
        if node.action == .delete || node.action == .retire {
            if let record = try store.ownership.loadAll().first(where: {
                $0.resourceUUID == node.resourceUUID
            }) {
                guard try store.ownership.removeExact(
                    resourceIdentifier: record.resourceIdentifier,
                    runtimeAdapter: record.runtimeAdapter,
                    expectedResourceUUID: record.resourceUUID,
                    expectedFencingToken: record.fencingToken
                ) else {
                    throw StateStoreError.invalidRecord(
                        "Verified runtime deletion could not remove the exact ownership projection."
                    )
                }
            }
            await state.removeBinding(resourceUUID: node.resourceUUID)
        }
        try store.observedStates.saveSnapshot(
            snapshotID: HostwrightResourceUUID.generate(),
            projectID: context.plan.projectID,
            observedState: observed,
            runtimeAdapter: context.plan.providerID.rawValue,
            parserVersion: "phase04-lifecycle-v1",
            rawOutputHash: observationSHA256,
            redactedSummary: "Lifecycle node \(node.key) verified.",
            observedAt: now
        )
    }

    private func markHealthyRevision(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        identity: RuntimeServiceIdentity,
        observedAt: String
    ) async throws {
        guard let current = try store.ownership.loadAll().first(where: {
            $0.resourceUUID == node.resourceUUID &&
                RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) ==
                    context.plan.providerID
        }) else {
            throw StateStoreError.invalidRecord(
                "Verified healthy revision is missing exact ownership state."
            )
        }
        let metadata = try lifecycleOwnershipMetadataJSON(
            identity: identity,
            desiredService: await state.desiredService(for: node.key),
            healthy: true,
            capabilitySHA256: context.plan.capabilitySHA256,
            planSHA256: context.plan.planSHA256
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
                observedAt: observedAt,
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

    private func releaseResourceFenceIfNeeded(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async throws {
        guard node.action != .create,
              node.action != .delete,
              node.action != .retire,
              let binding = await state.binding(
                  resourceUUID: node.resourceUUID,
                  resourceIdentifier: node.resourceIdentifier
              ),
              let current = try store.ownership.loadAll().first(where: {
                  $0.resourceUUID == binding.resourceUUID
              }),
              current.fencingToken == context.fencingToken,
              binding.currentFencingToken != context.fencingToken else {
            return
        }
        guard try store.ownership.advanceFencingToken(
            resourceIdentifier: binding.resourceIdentifier,
            runtimeAdapter: current.runtimeAdapter,
            expectedResourceUUID: binding.resourceUUID,
            expectedFencingToken: context.fencingToken,
            newFencingToken: binding.currentFencingToken,
            observedAt: hostwrightTimestamp()
        ) != nil else {
            throw StateStoreError.invalidRecord(
                "Lifecycle operation fence could not be released to the verified resource fence."
            )
        }
    }
}

private func lifecycleRestoreCompensatedOwnershipProjection(
    store: SQLiteStateStore,
    plan: LifecyclePlan,
    operationFencingToken: String,
    inventory: RuntimeInventory,
    expectedPriorFencesByResourceUUID: [String: String],
    allowObservedRuntimeFence: Bool
) throws -> [OwnershipRecord] {
    var restoredRecords: [OwnershipRecord] = []
    let records = try store.ownership.loadAll()
    var restorations: [(record: OwnershipRecord, fencingToken: String)] = []

    for record in records.sorted(by: {
        $0.resourceIdentifier < $1.resourceIdentifier
    }) {
        guard record.projectID == plan.projectID,
              record.projectResourceUUID == plan.projectResourceUUID,
              record.projectGeneration == plan.projectGeneration,
              record.providerGeneration == plan.providerGeneration,
              RuntimeProviderBinding.stableID(
                  for: record.runtimeAdapter
              ) == plan.providerID,
              record.fencingToken == operationFencingToken,
              plan.nodes.contains(where: {
                  $0.resourceUUID == record.resourceUUID &&
                      $0.resourceIdentifier == record.resourceIdentifier &&
                      $0.resourceGeneration == record.resourceGeneration
              }) else {
            continue
        }

        let matches = inventory.containers.filter {
            $0.ownership?.resourceUUID == record.resourceUUID
        }
        guard matches.count == 1,
              matches[0].name == record.resourceIdentifier,
              let observed = matches[0].ownership,
              observed.resourceGeneration == record.resourceGeneration,
              observed.projectUUID == plan.projectResourceUUID,
              observed.projectGeneration == plan.projectGeneration,
              observed.providerID == plan.providerID,
              observed.providerGeneration == plan.providerGeneration,
              HostwrightResourceUUID.isValid(observed.fencingToken) else {
            if allowObservedRuntimeFence {
                throw StateStoreError.invalidRecord(
                    "Completed compensation could not prove one exact runtime ownership projection."
                )
            }
            continue
        }

        let restoredFence: String
        if let expectedPriorFence =
            expectedPriorFencesByResourceUUID[record.resourceUUID],
           expectedPriorFence != operationFencingToken
        {
            guard observed.fencingToken == expectedPriorFence else {
                if allowObservedRuntimeFence {
                    throw StateStoreError.invalidRecord(
                        "Completed compensation runtime fencing does not match its exact pre-operation binding."
                    )
                }
                continue
            }
            restoredFence = expectedPriorFence
        } else {
            guard allowObservedRuntimeFence,
                  observed.fencingToken != operationFencingToken else {
                continue
            }
            restoredFence = observed.fencingToken
        }

        restorations.append((record, restoredFence))
    }

    if allowObservedRuntimeFence, !restorations.isEmpty {
        guard lifecycleCompensatedFenceProofMatches(
            plan: plan,
            operationFencingToken: operationFencingToken,
            records: records,
            restoredFencesByResourceUUID: Dictionary(
                uniqueKeysWithValues: restorations.map {
                    ($0.record.resourceUUID, $0.fencingToken)
                }
            )
        ) else {
            throw StateStoreError.invalidRecord(
                "Completed compensation could not prove the observed prior fences against the confirmed lifecycle plan."
            )
        }
    }

    for restoration in restorations {
        let record = restoration.record
        guard let restored = try store.ownership.advanceFencingToken(
            resourceIdentifier: record.resourceIdentifier,
            runtimeAdapter: record.runtimeAdapter,
            expectedResourceUUID: record.resourceUUID,
            expectedFencingToken: operationFencingToken,
            newFencingToken: restoration.fencingToken,
            observedAt: hostwrightTimestamp()
        ) else {
            throw StateStoreError.invalidRecord(
                "Completed compensation could not restore the exact ownership fence."
            )
        }
        restoredRecords.append(restored)
    }
    return restoredRecords
}

private func lifecycleCompensatedFenceProofMatches(
    plan: LifecyclePlan,
    operationFencingToken: String,
    records: [OwnershipRecord],
    restoredFencesByResourceUUID: [String: String]
) -> Bool {
    let timeoutValues = Set(plan.nodes.map(\.timeoutSeconds))
    guard timeoutValues.count == 1,
          let timeoutSeconds = timeoutValues.first,
          let command = LifecycleCommandKind(
              rawValue: plan.command.rawValue
          ) else {
        return false
    }
    let bindings: [LifecycleResourceBinding]
    do {
        bindings = try records.compactMap { record in
            guard record.projectID == plan.projectID,
                  record.projectResourceUUID ==
                    plan.projectResourceUUID,
                  record.projectGeneration == plan.projectGeneration,
                  record.providerGeneration == plan.providerGeneration,
                  RuntimeProviderBinding.stableID(
                      for: record.runtimeAdapter
                  ) == plan.providerID else {
                return nil
            }
            let identity =
                lifecycleOwnershipMetadata(from: record)?.identity ??
                plan.nodes.first(where: {
                    $0.resourceUUID == record.resourceUUID &&
                        $0.resourceIdentifier == record.resourceIdentifier &&
                        $0.resourceGeneration == record.resourceGeneration
                }).flatMap {
                    try? LifecycleRevisionCodec.decodeRedactedDesiredJSON(
                        $0.desiredSpecificationJSONRedacted
                    ).identity
                }
            guard let identity else { return nil }
            return try LifecycleResourceBinding(
                identity: identity,
                resourceIdentifier: record.resourceIdentifier,
                identityVersion: record.identityVersion,
                resourceUUID: record.resourceUUID,
                resourceGeneration: record.resourceGeneration,
                projectResourceUUID: plan.projectResourceUUID,
                projectGeneration: plan.projectGeneration,
                providerID: plan.providerID,
                providerGeneration: plan.providerGeneration,
                currentFencingToken:
                    restoredFencesByResourceUUID[record.resourceUUID] ??
                    record.fencingToken
            )
        }
    } catch {
        return false
    }
    return lifecyclePlanFence(
        command: command,
        manifestSHA256: plan.manifestSHA256,
        observationSHA256: plan.observationSHA256,
        capabilitySHA256: plan.capabilitySHA256,
        projectID: plan.projectID,
        providerID: plan.providerID,
        providerGeneration: plan.providerGeneration,
        selectedServices: Set(plan.nodes.compactMap(\.serviceName)).sorted(),
        timeoutSeconds: timeoutSeconds,
        parallelism: plan.parallelism,
        resourceBindings: bindings
    ) == operationFencingToken
}

private struct LifecycleOwnershipMetadata: Codable {
    let schemaVersion: Int
    let projectName: String
    let serviceName: String
    let instanceName: String?
    let healthy: Bool
    let desiredSpecificationJSONRedacted: String
    let revisionSHA256: String
    let capabilitySHA256: String
    let planSHA256: String

    var identity: RuntimeServiceIdentity {
        RuntimeServiceIdentity(
            projectName: projectName,
            serviceName: serviceName,
            instanceName: instanceName
        )
    }
}

private func lifecycleOwnershipMetadataJSON(
    identity: RuntimeServiceIdentity,
    desiredService: DesiredRuntimeService?,
    healthy: Bool,
    capabilitySHA256: String,
    planSHA256: String
) throws -> String {
    guard let desiredService,
          desiredService.identity == identity else {
        throw StateStoreError.invalidRecord(
            "Lifecycle ownership metadata requires the exact desired service identity."
        )
    }
    let metadata = LifecycleOwnershipMetadata(
        schemaVersion: 1,
        projectName: identity.projectName,
        serviceName: identity.serviceName,
        instanceName: identity.instanceName,
        healthy: healthy,
        desiredSpecificationJSONRedacted:
            try LifecycleRevisionCodec.redactedDesiredJSON(for: desiredService),
        revisionSHA256: try LifecycleRevisionCodec.revisionSHA256(for: desiredService),
        capabilitySHA256: capabilitySHA256,
        planSHA256: planSHA256
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(metadata)
    guard let json = String(data: data, encoding: .utf8) else {
        throw StateStoreError.invalidRecord(
            "Lifecycle ownership metadata could not be encoded."
        )
    }
    return json
}

private func lifecycleOwnershipMetadata(
    from record: OwnershipRecord
) -> LifecycleOwnershipMetadata? {
    guard let data = record.metadataJSONRedacted.data(using: .utf8),
          let metadata = try? JSONDecoder().decode(
              LifecycleOwnershipMetadata.self,
              from: data
          ),
          metadata.schemaVersion == 1,
          metadata.capabilitySHA256.range(
              of: "^[a-f0-9]{64}$",
              options: .regularExpression
          ) != nil,
          metadata.planSHA256.range(
              of: "^[a-f0-9]{64}$",
              options: .regularExpression
          ) != nil,
          metadata.revisionSHA256.range(
              of: "^[a-f0-9]{64}$",
              options: .regularExpression
          ) != nil else {
        return nil
    }
    return metadata
}

private func lifecycleHealthyDesiredState(
    store: SQLiteStateStore,
    projectID: String,
    providerID: RuntimeProviderID,
    bindings: [LifecycleResourceBinding]
) throws -> DesiredRuntimeState? {
    let boundUUIDs = Set(bindings.map(\.resourceUUID))
    let records = try store.ownership.loadAll().filter {
        $0.projectID == projectID &&
            boundUUIDs.contains($0.resourceUUID) &&
            RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) == providerID
    }
    var servicesByIdentity: [RuntimeServiceIdentity: DesiredRuntimeService] = [:]
    var generationsByIdentity: [RuntimeServiceIdentity: Int] = [:]
    for record in records {
        guard let metadata = lifecycleOwnershipMetadata(from: record),
              metadata.healthy else {
            continue
        }
        let service = try LifecycleRevisionCodec.decodeRedactedDesiredJSON(
            metadata.desiredSpecificationJSONRedacted
        )
        guard service.identity == metadata.identity,
              sha256(metadata.desiredSpecificationJSONRedacted) ==
                metadata.revisionSHA256 else {
            throw StateStoreError.invalidRecord(
                "Stored lifecycle healthy revision failed identity or digest verification."
            )
        }
        guard let currentBinding = bindings.first(where: {
            $0.resourceUUID == record.resourceUUID
        }) else {
            continue
        }
        if currentBinding.resourceGeneration <=
            (generationsByIdentity[service.identity] ?? 0) {
            continue
        }
        servicesByIdentity[service.identity] = service
        generationsByIdentity[service.identity] = currentBinding.resourceGeneration
    }
    let services = servicesByIdentity.values.sorted {
        $0.identity.displayName < $1.identity.displayName
    }
    guard let projectName = services.first?.identity.projectName else {
        return nil
    }
    guard services.allSatisfy({ $0.identity.projectName == projectName }) else {
        throw StateStoreError.invalidRecord(
            "Stored lifecycle healthy revisions span multiple projects."
        )
    }
    return DesiredRuntimeState(projectName: projectName, services: services)
}

private func lifecycleBindings(
    store: SQLiteStateStore,
    projectID: String,
    providerID: RuntimeProviderID,
    desiredState: DesiredRuntimeState
) throws -> [LifecycleResourceBinding] {
    return try store.ownership.loadAll().compactMap {
        record -> LifecycleResourceBinding? in
        guard record.projectID == projectID,
              RuntimeProviderBinding.stableID(for: record.runtimeAdapter) == providerID else {
            return nil
        }
        let recordedIdentity = lifecycleOwnershipMetadata(from: record)?.identity
        let declaredIdentity = desiredState.services.first { service in
            if service.identity == recordedIdentity {
                return true
            }
            if service.identity.managedResourceIdentifier == record.resourceIdentifier {
                return true
            }
            return service.identity.instanceName == nil &&
                service.identity.legacyManagedResourceIdentifier ==
                    record.resourceIdentifier
        }?.identity
        let recordedRunIdentity: RuntimeServiceIdentity? =
            recordedIdentity.flatMap { identity in
                guard identity.projectName == desiredState.projectName,
                      let instanceName = identity.instanceName,
                      instanceName.range(
                          of: "^run-[a-f0-9]{12}$",
                          options: .regularExpression
                      ) != nil,
                      desiredState.services.contains(where: {
                          $0.logicalServiceName == identity.serviceName
                      }) else {
                    return nil
                }
                return identity
            }
        let identity = declaredIdentity ?? recordedRunIdentity
        guard let identity else { return nil }
        return try LifecycleResourceBinding(
            record: record,
            identity: identity,
            providerID: providerID
        )
    }.sorted { $0.resourceIdentifier < $1.resourceIdentifier }
}

private func currentProjectResourceUUID(
    store: SQLiteStateStore,
    projectID: String,
    fallbackBindings: [LifecycleResourceBinding]
) throws -> String {
    if let project = try? store.desiredStates.loadProject(id: projectID) {
        return project.resourceUUID
    }
    if let existing = fallbackBindings.first?.projectResourceUUID {
        return existing
    }
    return HostwrightResourceUUID.legacy(kind: "project", identifier: projectID)
}

private func currentProviderGeneration(
    store: SQLiteStateStore,
    projectID: String,
    providerID: RuntimeProviderID
) -> Int {
    if let project = try? store.desiredStates.loadProject(id: projectID),
       RuntimeProviderBinding.stableID(for: project.mutationProvider ?? "") == providerID {
        return max(project.providerGeneration, 1)
    }
    return 1
}

private func manifestBaseDirectory(for manifestPath: String) -> String {
    let url = URL(fileURLWithPath: manifestPath).standardizedFileURL
    let parent = url.deletingLastPathComponent()
    return parent.path.isEmpty ? FileManager.default.currentDirectoryPath : parent.path
}

private func lifecyclePreflightDesiredExecution(
    compiled: LifecycleCompiledCommand,
    preparation: LifecycleCommandPreparation,
    options: LifecycleCLIOptions,
    environment: CLIEnvironment,
    adapter: any RuntimeAdapter
) throws {
    let executesDesiredFields = compiled.plan.nodes.contains {
        $0.action == .create ||
            $0.action == .runHook ||
            $0.action == .verify ||
            $0.action == .promote
    }
    guard executesDesiredFields,
          options.command != .down,
          options.command != .stop,
          options.command != .rm else {
        return
    }

    let capability = try hostwrightWaitForAsync {
        try await adapter.capabilitySnapshot()
    }
    guard capability.descriptor.providerID == preparation.providerID,
          capability.canonicalSHA256 == preparation.capabilitySHA256 else {
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "Runtime capability changed before lifecycle preflight. No runtime mutation was attempted."
        )
    }
    let probeCapabilities = lifecycleProbeCapabilities(for: capability)
    let interactiveCapabilities = RuntimeInteractiveCapabilityContract(
        snapshot: capability
    )
    let secretStore = environment.secretStore()
    for service in preparation.desiredState.services.sorted(by: {
        $0.identity.displayName < $1.identity.displayName
    }) {
        try RuntimeProbeValidator.validate(
            service.probes,
            declaredPorts: service.ports,
            capabilities: probeCapabilities
        )
        let hooks = [service.hooks.postStart, service.hooks.preStop].compactMap {
            $0
        }
        if !hooks.isEmpty,
           !interactiveCapabilities.availableOperations.contains(.exec) {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "The selected runtime provider does not qualify bounded container hooks. No runtime mutation was attempted."
            )
        }
        for hook in hooks {
            try RuntimeProbeValidator.validate(
                RuntimeProbeConfiguration(
                    action: .exec(RuntimeProbeExecAction(command: hook)),
                    timeoutSeconds: min(
                        options.timeoutSeconds,
                        RuntimeProbeValidator.maximumTimeoutSeconds
                    )
                ),
                declaredContainerPorts: []
            )
        }
        let sanitizedEnvironment = try service.environment
            .sorted { $0.name < $1.name }
            .map { entry -> RuntimeEnvironmentValue in
                guard let reference = entry.secretReference else {
                    return entry
                }
                do {
                    _ = try secretStore.readString(reference: reference)
                } catch {
                    throw RuntimeAdapterError.mutationUnavailableByPolicy(
                        "Configured secret for \(service.identity.displayName) environment variable '\(RuntimeRedactionPolicy.default.redact(entry.name))' is unavailable. No runtime mutation was attempted."
                    )
                }
                return RuntimeEnvironmentValue(
                    name: entry.name,
                    value: RuntimeRedactionPolicy.default.replacement,
                    isSensitive: true
                )
            }
        try RuntimeCreateSubsetPolicy.validate(
            lifecycleReplacingEnvironment(
                in: service,
                with: sanitizedEnvironment
            ),
            providerID: preparation.providerID
        )
    }
}

func lifecycleRestartPolicyKey(
    for identity: RuntimeServiceIdentity
) -> String {
    guard let instanceName = identity.instanceName else {
        return identity.serviceName
    }
    return "\(identity.serviceName)/\(instanceName)"
}

private func lifecycleProbeCapabilities(
    for snapshot: RuntimeCapabilitySnapshot
) -> RuntimeProbeCapabilities {
    guard snapshot.descriptor.providerID == .appleContainerCLI else {
        return .allUnavailable(
            for: snapshot.descriptor.providerID,
            reason: .qualificationIncomplete
        )
    }
    let features = Dictionary(grouping: snapshot.features, by: \.feature)
    func available(_ feature: RuntimeProviderFeature) -> Bool {
        guard let statuses = features[feature],
              statuses.count == 1,
              statuses[0].state == .available,
              statuses[0].reason == .implemented else {
            return false
        }
        return true
    }
    var actions = Set<RuntimeProbeActionKind>()
    if available(.processControl) {
        actions.insert(.exec)
    }
    if available(.observation), available(.lifecycle) {
        actions.formUnion([.http, .tcp])
    }
    return .qualified(for: snapshot.descriptor.providerID, actions)
}

private func lifecycleReplacingEnvironment(
    in service: DesiredRuntimeService,
    with environment: [RuntimeEnvironmentValue]
) -> DesiredRuntimeService {
    DesiredRuntimeService(
        identity: service.identity,
        logicalServiceName: service.logicalServiceName,
        replicaIndex: service.replicaIndex,
        image: service.image,
        platformOperatingSystem: service.platformOperatingSystem,
        platformArchitecture: service.platformArchitecture,
        cpuCount: service.cpuCount,
        memoryBytes: service.memoryBytes,
        userID: service.userID,
        groupID: service.groupID,
        workingDirectory: service.workingDirectory,
        entrypoint: service.entrypoint,
        command: service.command,
        initProcess: service.initProcess,
        dependencies: service.dependencies,
        environment: environment,
        labels: service.labels,
        ports: service.ports,
        mounts: service.mounts,
        healthCheck: service.healthCheck,
        probes: service.probes,
        restartPolicy: service.restartPolicy,
        updatePolicy: service.updatePolicy,
        hooks: service.hooks,
        rosetta: service.rosetta,
        virtualization: service.virtualization,
        readOnlyRootFilesystem: service.readOnlyRootFilesystem,
        sharedMemoryBytes: service.sharedMemoryBytes
    )
}

func lifecyclePlanFence(
    command: LifecycleCommandKind,
    manifestSHA256: String,
    observationSHA256: String,
    capabilitySHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    providerGeneration: Int,
    selectedServices: [String],
    timeoutSeconds: Int,
    parallelism: Int,
    resourceBindings: [LifecycleResourceBinding]
) -> String {
    HostwrightResourceUUID.legacy(
        kind: "lifecycle-fence",
        identifier: [
            command.rawValue,
            manifestSHA256,
            observationSHA256,
            capabilitySHA256,
            projectID,
            providerID.rawValue,
            String(providerGeneration),
            selectedServices.joined(separator: ","),
            String(timeoutSeconds),
            String(parallelism),
            resourceBindings.map {
                "\($0.resourceUUID):\($0.resourceGeneration):\($0.currentFencingToken)"
            }.sorted().joined(separator: ",")
        ].joined(separator: "|")
    )
}

private func lifecycleUnmanagedIdentifiers(
    inventory: RuntimeInventory,
    bindings: [LifecycleResourceBinding]
) -> Set<String> {
    let exactUUIDs = Set(bindings.map(\.resourceUUID))
    return Set(
        inventory.containers.flatMap { container -> [String] in
            guard let ownership = container.ownership,
                  exactUUIDs.contains(ownership.resourceUUID) else {
                return [container.name, container.runtimeID]
            }
            return []
        }
    )
}

private func lifecycleHookStepKey(_ nodeKey: String) -> String {
    "hook-\(sha256(nodeKey))"
}

private func lifecycleCompletionStepKey(_ nodeKey: String) -> String {
    "completion-\(sha256(nodeKey))"
}

private func lifecycleEpochMilliseconds(_ timestamp: String) -> Int64? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: timestamp) {
        return Int64(date.timeIntervalSince1970 * 1_000)
    }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: timestamp) else {
        return nil
    }
    return Int64(date.timeIntervalSince1970 * 1_000)
}

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}
