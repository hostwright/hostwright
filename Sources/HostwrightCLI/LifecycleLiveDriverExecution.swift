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

extension LifecycleLiveDriver {
    func execute(
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation,
        options: LifecycleCLIOptions
    ) throws -> LifecycleSagaExecutionResult {
        let options = options.withOperationIdempotencyKeySHA256(environment.lifecycleOperationIdempotencyKeySHA256)
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
        let validated = try hostwrightValidatedManifest(
            text: manifestText,
            teamProfilePath: nil,
            environment: environment
        )
        let executionManifestSHA256 = try lifecycleManifestSHA256(
            text: manifestText,
            manifest: validated.manifest
        )
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
            adapter: adapter,
            store: store,
            manifest: validated.manifest
        )
        let schedulerSession: LifecycleSchedulerSession?
        if let context = environment.lifecycleScheduler {
            if hasExplicitSchedulerAuthorityValidator {
                try schedulerAuthorityValidator(validated.manifest, compiled, preparation, options)
            }
            let inventory = try hostwrightWaitForAsync { try await adapter.inventory() }
            try LifecycleSchedulerSession.reconcile(
                store: store, projectUUID: preparation.projectResourceUUID,
                providerID: preparation.providerID, inventory: inventory
            )
            schedulerSession = try LifecycleSchedulerSession.admit(
                context: context, store: store, manifest: validated.manifest,
                compiled: compiled, preparation: preparation, options: options,
                providerVersion: inventory.machine.runtimeVersion
            )
        } else {
            try schedulerAuthorityValidator(validated.manifest, compiled, preparation, options)
            schedulerSession = nil
        }
        var schedulerReconciled = false
        defer {
            if !schedulerReconciled, let schedulerSession,
               let inventory = try? hostwrightWaitForAsync({ try await adapter.inventory() }) {
                try? schedulerSession.reconcile(inventory: inventory)
            }
        }
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
        let now = hostwrightTimestamp()
        try store.desiredStates.saveManifestSnapshot(
            projectID: preparation.projectID,
            manifestPath: options.manifestPath,
            manifestHash: preparation.manifestSHA256,
            desiredGeneration: preparation.providerGeneration,
            manifest: validated.manifest,
            timestamp: now,
            mutationProvider: preparation.providerID.rawValue
        )
        let networkReconciliation:
            NetworkLifecycleReconciliationResult?
        if lifecycleRequiresProjectNetworkProvisioning(
            compiled.plan.command
        ) {
            networkReconciliation = try hostwrightWaitForAsync {
                try await NetworkLifecycleCoordinator.reconcile(
                    preparation: preparation,
                    planSHA256: compiled.plan.planSHA256,
                    store: store,
                    environment: environment
                )
            }
        } else {
            networkReconciliation = nil
        }
        let projectDNSHelper: LiveProjectDNSHelperDriver?
        let projectDNSRuntime: LiveProjectDNSRuntimeDriver?
        let projectDNSReconciliation:
            ProjectDNSLifecycleReconciliationResult?
        let hasPersistedProjectDNS =
            try store.projectDNS.load(
                projectUUID: preparation.projectResourceUUID
            ) != nil
        if !preparation.desiredState.networks.isEmpty ||
            !preparation.ingress.isEmpty ||
            hasPersistedProjectDNS {
            let helper = try LiveProjectDNSHelperDriver(
                environment: environment,
                stateDatabasePath: options.stateDatabasePath
            )
            let runtime = LiveProjectDNSRuntimeDriver(
                adapter: adapter
            )
            projectDNSHelper = helper
            projectDNSRuntime = runtime
            if lifecycleRequiresProjectDNSProvisioning(
                compiled.plan.command
            ) {
                projectDNSReconciliation =
                    try hostwrightWaitForAsync {
                        try await ProjectDNSLifecycleCoordinator
                            .reconcile(
                                preparation: preparation,
                                planSHA256:
                                    compiled.plan.planSHA256,
                                store: store,
                                helper: helper,
                                runtime: runtime
                            )
                    }
            } else {
                projectDNSReconciliation = nil
            }
        } else {
            projectDNSHelper = nil
            projectDNSRuntime = nil
            projectDNSReconciliation = nil
        }
        let storageReconciliation:
            StorageLifecycleReconciliationResult?
        if lifecycleRequiresNamedVolumeProvisioning(
            compiled.plan.command
        ) {
            storageReconciliation = try hostwrightWaitForAsync {
                try await StorageLifecycleCoordinator
                    .reconcileNamedVolumes(
                        manifest: validated.manifest,
                        preparation: preparation,
                        compiled: compiled,
                        planSHA256: compiled.plan.planSHA256,
                        timeoutSeconds: options.timeoutSeconds,
                        store: store,
                        environment: environment
                    )
            }
        } else {
            storageReconciliation = nil
        }
        let recoveryStateJSONRedacted = try recoverySnapshot.map(
            lifecycleRecoveryStateJSONRedacted
        )
        let groupIdempotencyKey = options.operationIdempotencyKeySHA256 ??
            compiled.plan.planSHA256
        let operationFencingToken = options.operationIdempotencyKeySHA256.map {
            HostwrightResourceUUID.legacy(
                kind: "lifecycle-fencing",
                identifier: $0
            )
        } ?? preparation.planFencingToken
        let operationID = HostwrightResourceUUID.legacy(
            kind: "lifecycle-operation",
            identifier: groupIdempotencyKey
        )
        let groupID = HostwrightResourceUUID.legacy(
            kind: "lifecycle-group",
            identifier: groupIdempotencyKey
        )
        try lifecyclePersistDesiredImageLocks(
            plan: compiled.plan,
            desiredServicesByNodeKey:
                compiled.desiredServicesByNodeKey,
            groupID: groupID,
            store: store,
            timestamp: now
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
            store: store,
            groupIdempotencyKey: groupIdempotencyKey
        )
        let effects = LifecycleLiveEffects(
            adapter: adapter,
            state: state,
            store: store,
            probeStore: probeStore,
            environment: environment,
            schedulerActivationValidator: { node in
                if let schedulerSession {
                    try schedulerSession.validate(node: node)
                } else if hasExplicitSchedulerAuthorityValidator {
                    try schedulerAuthorityValidator(validated.manifest, compiled, preparation, options)
                } else {
                    throw RuntimeAdapterError.mutationUnavailableByPolicy(lifecycleSchedulerAuthorityUnavailableMessage)
                }
            }
        )
        let hasPersistedServiceTunnels =
            !(try store.serviceTunnels.listRecoverable(
                projectUUID: preparation.projectResourceUUID
            )).isEmpty
        let serviceTunnelFinalizer:
            LifecycleServiceTunnelFinalizer?
        if !preparation.tunnelDeclarations.isEmpty ||
            hasPersistedServiceTunnels {
            serviceTunnelFinalizer =
                try LifecycleServiceTunnelFinalizer(
                    preparation: preparation,
                    timeoutSeconds: options.timeoutSeconds,
                    store: store,
                    helper: LiveServiceTunnelHelperDriver(
                        environment: environment,
                        stateDatabasePath:
                            options.stateDatabasePath
                    )
                )
        } else {
            serviceTunnelFinalizer = nil
        }
        let lifecycleFinalizer = LifecycleCompositeFinalizer(
            dependent: serviceTunnelFinalizer,
            ownership: LifecycleOwnershipFinalizer(
                store: store,
                adapter: adapter
            )
        )
        let executor = LifecycleSagaExecutor(
            store: store,
            effects: effects,
            validator: validator,
            recoveryStateJSONRedacted: recoveryStateJSONRedacted,
            finalizer: lifecycleFinalizer
        )
        let result = try hostwrightWaitForAsync {
            try await executor.execute(
                plan: compiled.plan,
                operationID: operationID,
                groupID: groupID,
                fencingToken: operationFencingToken,
                lockOwner: "hostwright-cli:\(operationID)",
                groupIdempotencyKey: groupIdempotencyKey
            )
        }
        if result.status == .compensated, let recoverySnapshot {
            try lifecycleRestoreHealthyDesiredState(
                recoverySnapshot,
                sourcePlan: compiled.plan,
                store: store
            )
        }
        let manifestDeclaresNamedVolumes =
            !validated.manifest.volumes.isEmpty
        if result.status == .succeeded ||
            result.status == .alreadySucceeded {
            if compiled.plan.command != .remove,
               (
                   !preparation.desiredState.networks.isEmpty ||
                       !preparation.ingress.isEmpty
               ),
               let projectDNSHelper,
               let projectDNSRuntime {
                let freshObserved = try hostwrightWaitForAsync {
                    try await lifecycleProjectDNSRefreshObservation(
                        adapter: adapter,
                        preparation: preparation,
                        store: store
                    )
                }
                guard freshObserved.adapterMetadata?.providerID ==
                        preparation.providerID,
                      freshObserved.capabilitySHA256 ==
                        preparation.capabilitySHA256 else {
                    throw HostwrightDiagnostic(
                        code: .runtimeUnavailable,
                        message:
                            "Project DNS ready-record refresh refused stale provider observation."
                    )
                }
                try hostwrightWaitForAsync {
                    try await ProjectDNSLifecycleCoordinator
                        .refresh(
                            preparation: preparation,
                            observedState: freshObserved,
                            planSHA256:
                                compiled.plan.planSHA256,
                            store: store,
                            helper: projectDNSHelper,
                            runtime: projectDNSRuntime
                        )
                }
            }
            if manifestDeclaresNamedVolumes &&
                lifecycleRequiresNamedVolumeDetach(
                compiled.plan.command
                ) {
                let quiescenceProof = try hostwrightWaitForAsync {
                    try lifecycleStorageQuiescenceProof(
                        inventory: try await adapter.inventory(),
                        preparation: preparation,
                        compiled: compiled
                    )
                }
                try hostwrightWaitForAsync {
                    try await StorageLifecycleCoordinator
                        .detachNamedVolumes(
                            preparation: preparation,
                            compiled: compiled,
                            planSHA256:
                                compiled.plan.planSHA256,
                            timeoutSeconds:
                                options.timeoutSeconds,
                            quiescenceProof:
                                quiescenceProof,
                            store: store,
                            environment: environment
                        )
                }
            }
            if manifestDeclaresNamedVolumes &&
                compiled.plan.command == .remove {
                try hostwrightWaitForAsync {
                    try await StorageLifecycleCoordinator
                        .applyReclaimPolicies(
                            manifest: validated.manifest,
                            preparation: preparation,
                            planSHA256:
                                compiled.plan.planSHA256,
                            timeoutSeconds:
                                options.timeoutSeconds,
                            stateDatabasePath:
                                options.stateDatabasePath,
                            output: options.output,
                            environment: environment
                        )
                }
            }
            if compiled.plan.command == .remove {
                if let projectDNSHelper,
                   let projectDNSRuntime {
                    try hostwrightWaitForAsync {
                        try await ProjectDNSLifecycleCoordinator
                            .remove(
                                preparation: preparation,
                                planSHA256:
                                    compiled.plan.planSHA256,
                                store: store,
                                helper: projectDNSHelper,
                                runtime: projectDNSRuntime
                            )
                    }
                }
                try hostwrightWaitForAsync {
                    try await NetworkLifecycleCoordinator
                        .removeNetworks(
                            networkUUIDs: nil,
                            preparation: preparation,
                            planSHA256:
                                compiled.plan.planSHA256,
                            store: store,
                            environment: environment
                        )
                }
            }
        } else if result.status == .compensated,
                  manifestDeclaresNamedVolumes,
                  let storageReconciliation,
                  !storageReconciliation
                    .newlyAttachedIDs.isEmpty {
            let quiescenceProof = try hostwrightWaitForAsync {
                try lifecycleStorageQuiescenceProof(
                    inventory: try await adapter.inventory(),
                    preparation: preparation,
                    compiled: compiled
                )
            }
            try hostwrightWaitForAsync {
                try await StorageLifecycleCoordinator
                    .detachNamedVolumes(
                        preparation: preparation,
                        compiled: compiled,
                        planSHA256:
                            compiled.plan.planSHA256,
                        timeoutSeconds:
                            options.timeoutSeconds,
                        quiescenceProof:
                            quiescenceProof,
                        onlyAttachmentIDs: Set(
                            storageReconciliation
                                .newlyAttachedIDs
                        ),
                        store: store,
                        environment: environment
                    )
            }
        }
        if result.status == .compensated,
           let projectDNSReconciliation,
           let projectDNSHelper,
           let projectDNSRuntime {
            try hostwrightWaitForAsync {
                try await ProjectDNSLifecycleCoordinator
                    .compensateNewlyCreated(
                        projectDNSReconciliation,
                        preparation: preparation,
                        planSHA256:
                            compiled.plan.planSHA256,
                        store: store,
                        helper: projectDNSHelper,
                        runtime: projectDNSRuntime
                    )
            }
        }
        if result.status == .compensated,
           let networkReconciliation,
           !networkReconciliation
            .newlyCreatedNetworkUUIDs.isEmpty {
            try hostwrightWaitForAsync {
                try await NetworkLifecycleCoordinator
                    .removeNetworks(
                        networkUUIDs: Set(
                            networkReconciliation
                                .newlyCreatedNetworkUUIDs
                        ),
                        preparation: preparation,
                        planSHA256:
                            compiled.plan.planSHA256,
                        store: store,
                        environment: environment
                    )
            }
        }
        if let schedulerSession {
            try schedulerSession.reconcile(inventory: hostwrightWaitForAsync { try await adapter.inventory() })
        }
        schedulerReconciled = true
        return result
    }
}

func lifecyclePersistDesiredImageLocks(
    plan: LifecyclePlan,
    desiredServicesByNodeKey: [String: DesiredRuntimeService],
    groupID: String,
    store: SQLiteStateStore,
    timestamp: String
) throws {
    var persistedResourceUUIDs = Set<String>()
    for node in plan.nodes.sorted(by: { $0.key < $1.key }) {
        guard !persistedResourceUUIDs.contains(node.resourceUUID),
              let service = desiredServicesByNodeKey[node.key],
              let lock = service.imageLock else {
            continue
        }
        if let existing = try store.imageDigestLocks.load(
            planSHA256: plan.planSHA256,
            resourceUUID: node.resourceUUID,
            stateKind: .desired
        ) {
            guard existing.projectID == plan.projectID,
                  existing.resourceUUID == node.resourceUUID,
                  existing.serviceName == service.logicalServiceName,
                  existing.replicaIndex == service.replicaIndex,
                  existing.stateKind == .desired,
                  existing.lock == lock,
                  existing.providerGeneration == plan.providerGeneration,
                  existing.planSHA256 == plan.planSHA256,
                  existing.observationSHA256 == nil else {
                throw StateStoreError.invalidRecord(
                    "Existing desired image digest lock does not match the exact repeated lifecycle plan."
                )
            }
            persistedResourceUUIDs.insert(node.resourceUUID)
            continue
        }
        let record = ImageDigestLockRecord(
            id: HostwrightResourceUUID.legacy(
                kind: "image-digest-lock-desired",
                identifier: "\(plan.planSHA256):\(node.resourceUUID)"
            ),
            projectID: plan.projectID,
            resourceUUID: node.resourceUUID,
            serviceName: service.logicalServiceName,
            replicaIndex: service.replicaIndex,
            stateKind: .desired,
            lock: lock,
            providerGeneration: plan.providerGeneration,
            planSHA256: plan.planSHA256,
            operationGroupID: groupID,
            observationSHA256: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try store.imageDigestLocks.save(record)
        persistedResourceUUIDs.insert(node.resourceUUID)
    }
}
