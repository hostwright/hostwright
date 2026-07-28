import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRegistry
import HostwrightRuntime
import HostwrightSecrets
import HostwrightState
import HostwrightStorage

func lifecycleStorageQuiescenceProof(
    inventory: RuntimeInventory,
    preparation: LifecycleCommandPreparation,
    compiled: LifecycleCompiledCommand
) throws -> StorageRuntimeQuiescenceProof {
    let workloadUUIDs = Set(
        compiled.plan.nodes.map(\.resourceUUID)
    )
    for workloadUUID in workloadUUIDs.sorted() {
        let matches = inventory.containers.filter {
            $0.ownership?.resourceUUID == workloadUUID
        }
        guard matches.count <= 1 else {
            throw HostwrightDiagnostic(
                code: .storageConflict,
                message:
                    "Runtime quiescence found duplicate holders for workload \(workloadUUID); no attachment fence was advanced."
            )
        }
        guard let container = matches.first else {
            continue
        }
        guard let ownership = container.ownership,
              ownership.projectUUID ==
                preparation.projectResourceUUID,
              ownership.projectGeneration ==
                preparation.projectGeneration,
              ownership.providerID == preparation.providerID,
              ownership.providerGeneration ==
                preparation.providerGeneration,
              [.created, .stopped, .exited].contains(
                  container.lifecycle
              ) else {
            throw HostwrightDiagnostic(
                code: .storageConflict,
                message:
                    "Workload \(workloadUUID) is still active or has conflicting runtime authority; no attachment fence was advanced."
            )
        }
    }
    return try StorageRuntimeQuiescenceProof(
        observationSHA256: inventory.semanticSHA256,
        workloadUUIDs: workloadUUIDs
    )
}

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
        let effectiveManifestSHA256 = try lifecycleManifestSHA256(
            text: manifestText,
            manifest: manifest
        )
        let store = SQLiteStateStore(
            configuration: try hostwrightStateStoreConfiguration(
                explicitPath: options.stateDatabasePath,
                environment: environment
            )
        )
        try store.migrate()

        let projectName = manifest.project ?? ""
        let projectID = "project-\(projectName)"
        let initialProjectResourceUUID = try currentProjectResourceUUID(
            store: store,
            projectID: projectID,
            fallbackBindings: []
        )
        var mapping = ManifestRuntimeMapper.map(
            manifest,
            projectResourceUUID: initialProjectResourceUUID,
            bindMountBaseDirectory:
                manifestBaseDirectory(for: options.manifestPath),
            namedVolumeSources:
                StorageLifecycleCoordinator.namedVolumeSources(
                    manifest: manifest,
                    projectResourceUUID: initialProjectResourceUUID,
                    providerRootURL: environment.storageProviderRootURL()
                )
        )
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
        var resourceBindings = try lifecycleBindings(
            store: store,
            projectID: projectID,
            providerID: providerID,
            desiredState: mapping.desiredState
        )
        let projectResourceUUID = try currentProjectResourceUUID(
            store: store,
            projectID: projectID,
            fallbackBindings: resourceBindings
        )
        if projectResourceUUID != initialProjectResourceUUID {
            mapping = ManifestRuntimeMapper.map(
                manifest,
                projectResourceUUID: projectResourceUUID,
                bindMountBaseDirectory:
                    manifestBaseDirectory(for: options.manifestPath),
                namedVolumeSources:
                    StorageLifecycleCoordinator.namedVolumeSources(
                        manifest: manifest,
                        projectResourceUUID: projectResourceUUID,
                        providerRootURL:
                            environment.storageProviderRootURL()
                    )
            )
            resourceBindings = try lifecycleBindings(
                store: store,
                projectID: projectID,
                providerID: providerID,
                desiredState: mapping.desiredState
            )
        }
        let previousDesiredState = try lifecycleHealthyDesiredState(
            store: store,
            projectID: projectID,
            providerID: providerID,
            bindings: resourceBindings
        )
        let adapter = selectedProvider.adapter
        let inventory = try hostwrightWaitForAsync {
            try await adapter.inventory()
        }
        let plannedDesiredState =
            try NetworkPortLifecycleCoordinator.resolveForPlanning(
                desiredState: mapping.desiredState,
                projectID: projectID,
                projectResourceUUID: projectResourceUUID,
                providerID: providerID,
                providerGeneration: providerGeneration,
                bindings: resourceBindings,
                store: store,
                occupiedPorts:
                    NetworkPortLifecycleCoordinator.occupiedPorts(
                        in: inventory
                    ),
                isAvailable:
                    NetworkPortSocketAvailability.isAvailable
            )
        let desiredState = DesiredRuntimeState(
            projectName: plannedDesiredState.projectName,
            networks: plannedDesiredState.networks,
            services: plannedDesiredState.services,
            ownedResourceHints: resourceBindings.map {
                RuntimeOwnedResourceHint(
                    resourceIdentifier: $0.resourceIdentifier,
                    identity: $0.identity,
                    identityVersion: $0.identityVersion,
                    ownership: $0.ownershipEvidence
                )
            }
        )
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
        let projectGeneration = max(
            resourceBindings.map(\.projectGeneration).max() ?? 1,
            1
        )
        let selectedServices = options.serviceNames.isEmpty
            ? plannedDesiredState.services.map(\.logicalServiceName).sorted()
            : options.serviceNames.sorted()
        let planFence = lifecyclePlanFence(
            command: options.command,
            manifestSHA256: effectiveManifestSHA256,
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
            manifestSHA256: effectiveManifestSHA256,
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
        let freshInitial = try prepare(options: options)
        let compiler = LifecycleCommandPlanCompiler()
        let freshInitialPlan = try compiler.compile(
            options: options,
            preparation: freshInitial
        )
        let fresh = try LifecycleImageLockBinder.bind(
            preparation: freshInitial,
            initialCompiled: freshInitialPlan,
            options: options,
            resolve: localImageEvidence
        )
        let freshPlan = try compiler.compile(
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
        let operationID = HostwrightResourceUUID.legacy(
            kind: "lifecycle-operation",
            identifier: compiled.plan.planSHA256
        )
        let groupID = HostwrightResourceUUID.legacy(
            kind: "lifecycle-group",
            identifier: compiled.plan.planSHA256
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
        let manifestDeclaresNamedVolumes =
            !validated.manifest.volumes.isEmpty
        if result.status == .succeeded ||
            result.status == .alreadySucceeded {
            if compiled.plan.command != .remove,
               !preparation.desiredState.networks.isEmpty,
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
        return result
    }
}

private func lifecycleRequiresProjectNetworkProvisioning(
    _ command: LifecycleCommand
) -> Bool {
    switch command {
    case .up, .run, .start, .restart, .update, .apply:
        true
    case .down, .stop, .remove, .resume, .rollback:
        false
    }
}

private func lifecycleRequiresProjectDNSProvisioning(
    _ command: LifecycleCommand
) -> Bool {
    switch command {
    case .up, .run, .start, .restart, .update, .apply,
            .resume, .rollback:
        true
    case .down, .stop, .remove:
        false
    }
}

func lifecycleProjectDNSRefreshObservation(
    adapter: any RuntimeAdapter,
    preparation: LifecycleCommandPreparation,
    store: SQLiteStateStore
) async throws -> ObservedRuntimeState {
    let bindings = try lifecycleBindings(
        store: store,
        projectID: preparation.projectID,
        providerID: preparation.providerID,
        desiredState: preparation.desiredState
    )
    let desiredState = DesiredRuntimeState(
        projectName: preparation.desiredState.projectName,
        networks: preparation.desiredState.networks,
        services: preparation.desiredState.services,
        ownedResourceHints: bindings.map {
            RuntimeOwnedResourceHint(
                resourceIdentifier: $0.resourceIdentifier,
                identity: $0.identity,
                identityVersion: $0.identityVersion,
                ownership: $0.ownershipEvidence
            )
        }.sorted { $0.resourceIdentifier < $1.resourceIdentifier }
    )
    return try await adapter.observe(desiredState: desiredState)
}

private func lifecycleRequiresNamedVolumeProvisioning(
    _ command: LifecycleCommand
) -> Bool {
    switch command {
    case .up, .run, .start, .restart, .update, .apply:
        true
    case .down, .stop, .remove, .resume, .rollback:
        false
    }
}

private func lifecycleRequiresNamedVolumeDetach(
    _ command: LifecycleCommand
) -> Bool {
    switch command {
    case .down, .stop, .remove:
        true
    case .up, .run, .start, .restart, .update, .apply,
         .resume, .rollback:
        false
    }
}

private func lifecyclePersistDesiredImageLocks(
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
        let record = ImageDigestLockRecord(
            id: HostwrightResourceUUID.legacy(
                kind: "image-digest-lock-desired",
                identifier:
                    "\(plan.planSHA256):\(node.resourceUUID)"
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

    func preflightImageTrustRecovery(
        plan: LifecyclePlan,
        store: SQLiteStateStore
    ) throws {
        let authorizationObjects = try store.events.loadAll()
            .filter {
                $0.type == "image.trust.lifecycle.authorized"
            }
            .compactMap { event -> [String: Any]? in
                guard let data = event.payloadJSONRedacted.data(
                    using: .utf8
                ),
                let object = try? JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any],
                object["planSHA256"] as? String ==
                    plan.planSHA256 else {
                    return nil
                }
                return object
            }
        guard !authorizationObjects.isEmpty else {
            return
        }
        let desired = Dictionary(
            grouping: recoveryDesiredServices(plan: plan).values,
            by: \.logicalServiceName
        ).compactMapValues(\.first)
        for serviceName in desired.keys.sorted() {
            guard let service = desired[serviceName],
                  let lock = service.imageLock else {
                throw recoveryTrustSafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
            let candidates = authorizationObjects.filter {
                $0["projectID"] as? String == plan.projectID &&
                    $0["serviceName"] as? String == serviceName &&
                    $0["descriptorDigest"] as? String ==
                        lock.descriptorDigest
            }
            var authorized = false
            for object in candidates {
                guard let policySHA256 =
                        object["policySHA256"] as? String,
                      policySHA256.range(
                          of: "^[a-f0-9]{64}$",
                          options: .regularExpression
                      ) != nil,
                      let authorization =
                        object["decision"] as? String else {
                    continue
                }
                if authorization == "verified",
                   let verification =
                    object["verification"] as? [String: Any],
                   let createdAt =
                    verification["createdAt"] as? String,
                   let discoveryID =
                    verification["discoveryID"] as? String,
                   let graphSHA256 =
                    verification["graphSHA256"] as? String,
                   let rootSHA256 =
                    verification["trustedRootSHA256"] as? String,
                   let record = try store.imageTrust
                    .loadVerifications(
                        projectID: plan.projectID,
                        serviceName: serviceName,
                        descriptorDigest: lock.descriptorDigest
                    )
                    .first(where: {
                        $0.policySHA256 == policySHA256 &&
                            $0.createdAt == createdAt &&
                            $0.evidenceDiscoveryID ==
                                discoveryID &&
                            $0.evidenceGraphSHA256 ==
                                graphSHA256 &&
                            $0.trustedRootSHA256 ==
                                rootSHA256 &&
                            $0.outcome ==
                                ImageTrustVerificationOutcome
                                    .passed.rawValue &&
                            $0.matchedAuthorityIDs.count >=
                                $0.threshold
                    }),
                   let discovery =
                    try store.ociReferrers.loadDiscovery(
                        id: record.evidenceDiscoveryID
                    ),
                   discovery.complete,
                   discovery.graphSHA256 ==
                    record.evidenceGraphSHA256,
                   discovery.subjectDigest ==
                    lock.descriptorDigest,
                   let graph = try store.ociReferrers.loadGraph(
                       discoveryID: record.evidenceDiscoveryID
                   ),
                   let subject =
                    try store.imageTrust.loadSubjectManifest(
                        endpoint: discovery.registryEndpoint,
                        repository: discovery.repository,
                        descriptorDigest: lock.descriptorDigest
                    ),
                   lifecycleSHA256(subject.payload) ==
                    subject.payloadSHA256,
                   subject.descriptorDigest ==
                    lock.descriptorDigest,
                   (try? ImageTrustEvidenceExtractor.bundles(
                       from: graph
                   )) != nil {
                    authorized = true
                    break
                }
                if authorization == "exception",
                   let exceptionID =
                    object["exceptionID"] as? String,
                   let exception =
                    try store.imageTrust.activeException(
                        projectID: plan.projectID,
                        serviceName: serviceName,
                        descriptorDigest: lock.descriptorDigest,
                        policySHA256: policySHA256,
                        currentTimestamp: hostwrightTimestamp()
                    ),
                   exception.id == exceptionID {
                    authorized = true
                    break
                }
            }
            guard authorized else {
                throw recoveryTrustSafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
        }
    }

    func preflightImageSBOMRecovery(
        plan: LifecyclePlan,
        store: SQLiteStateStore
    ) throws {
        let authorizationObjects = try store.events.loadAll()
            .filter {
                $0.type == "image.sbom.lifecycle.authorized"
            }
            .compactMap { event -> [String: Any]? in
                guard let data = event.payloadJSONRedacted.data(
                    using: .utf8
                ),
                let object = try? JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any],
                object["planSHA256"] as? String ==
                    plan.planSHA256 else {
                    return nil
                }
                return object
            }
        guard !authorizationObjects.isEmpty else {
            return
        }
        let desired = Dictionary(
            grouping: recoveryDesiredServices(plan: plan).values,
            by: \.logicalServiceName
        ).compactMapValues(\.first)
        for serviceName in desired.keys.sorted() {
            guard let service = desired[serviceName],
                  let lock = service.imageLock else {
                throw recoverySBOMSafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
            let candidates = authorizationObjects.filter {
                $0["projectID"] as? String == plan.projectID &&
                    $0["serviceName"] as? String == serviceName &&
                    $0["descriptorDigest"] as? String ==
                        lock.descriptorDigest
            }
            var authorized = false
            for object in candidates {
                guard let policySHA256 =
                    object["policySHA256"] as? String,
                    policySHA256.range(
                        of: "^[a-f0-9]{64}$",
                        options: .regularExpression
                    ) != nil,
                    let formats = object["formats"] as? [String],
                    !formats.isEmpty else {
                    continue
                }
                let records = try store.imageSBOM.loadRecords(
                    projectID: plan.projectID,
                    serviceName: serviceName,
                    descriptorDigest: lock.descriptorDigest,
                    policySHA256: policySHA256
                )
                let required = Set(formats)
                let verified = try lifecycleVerifiedSBOMFormats(
                    records: records,
                    descriptorDigest: lock.descriptorDigest,
                    store: store
                )
                if required.isSubset(of: verified) {
                    authorized = true
                    break
                }
            }
            guard authorized else {
                throw recoverySBOMSafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
        }
    }

    func preflightImageVulnerabilityRecovery(
        plan: LifecyclePlan,
        store: SQLiteStateStore
    ) throws {
        let authorizationObjects = try store.events.loadAll()
            .filter {
                $0.type ==
                    "image.vulnerability.lifecycle.authorized"
            }
            .compactMap { event -> [String: Any]? in
                guard let data = event.payloadJSONRedacted.data(
                    using: .utf8
                ),
                let object = try? JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any],
                object["planSHA256"] as? String ==
                    plan.planSHA256 else {
                    return nil
                }
                return object
            }
        let notRequired = try store.events.loadAll().contains {
            event in
            guard event.type ==
                    "image.vulnerability.lifecycle.not-required",
                  let data = event.payloadJSONRedacted.data(
                      using: .utf8
                  ),
                  let object =
                    try? JSONSerialization.jsonObject(
                        with: data
                    ) as? [String: Any] else {
                return false
            }
            return object["planSHA256"] as? String ==
                plan.planSHA256 &&
                object["projectID"] as? String ==
                plan.projectID
        }
        if authorizationObjects.isEmpty, notRequired {
            return
        }
        let desired = Dictionary(
            grouping: recoveryDesiredServices(plan: plan).values,
            by: \.logicalServiceName
        ).compactMapValues(\.first)
        let currentTrust =
            try? recoveryVulnerabilityTrustMapping(
                plan: plan,
                store: store
            )
        let now = environment.registryDate()
        guard !authorizationObjects.isEmpty else {
            let serviceName = desired.keys.sorted().first ??
                "unknown"
            throw recoveryVulnerabilitySafeHold(
                plan: plan,
                serviceName: serviceName
            )
        }
        for serviceName in desired.keys.sorted() {
            guard let service = desired[serviceName],
                  let lock = service.imageLock else {
                throw recoveryVulnerabilitySafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
            let candidates = authorizationObjects.filter {
                $0["projectID"] as? String == plan.projectID &&
                    $0["serviceName"] as? String ==
                        serviceName &&
                    $0["descriptorDigest"] as? String ==
                        lock.descriptorDigest
            }
            var authorized = false
            for object in candidates {
                guard let policyObject =
                        object["policy"] as? [String: Any],
                      let policy =
                        try? lifecycleVulnerabilityPolicy(
                            from: policyObject
                        ),
                      object["policySHA256"] as? String ==
                        policy.policySHA256,
                      let signaturePolicySHA256 =
                        object[
                            "signaturePolicySHA256"
                        ] as? String,
                      signaturePolicySHA256.range(
                        of: "^[a-f0-9]{64}$",
                        options: .regularExpression
                      ) != nil,
                      var observation =
                        try? lifecycleCurrentVulnerabilityObservation(
                            store: store,
                            projectID: plan.projectID,
                            serviceName: serviceName,
                            descriptorDigest:
                                lock.descriptorDigest,
                            policy: policy,
                            signaturePolicySHA256:
                                signaturePolicySHA256,
                            at: now
                        ) else {
                    continue
                }
                if observation.report != nil {
                    guard let currentTrust,
                          currentTrust.material.policySHA256 ==
                            signaturePolicySHA256,
                          let revalidated =
                            try? lifecycleCurrentVulnerabilityObservation(
                                store: store,
                                projectID: plan.projectID,
                                serviceName: serviceName,
                                descriptorDigest:
                                    lock.descriptorDigest,
                                policy: policy,
                                signaturePolicySHA256:
                                    signaturePolicySHA256,
                                signaturePolicy:
                                    currentTrust.policy,
                                signatureMaterial:
                                    currentTrust.material,
                                at: now
                            ) else {
                        continue
                    }
                    observation = revalidated
                }
                if let report = observation.report {
                    guard object["reportID"] as? String ==
                            report.id,
                          object[
                              "signatureProofSHA256"
                          ] as? String ==
                            report.signatureProofSHA256,
                          object["reportDigest"] as? String ==
                            report.reportDigest,
                          object[
                              "reportReferrerDigest"
                          ] as? String ==
                            report.reportReferrerDigest,
                          object["databaseID"] as? String ==
                            report.databaseID,
                          object[
                              "databaseVersion"
                          ] as? String ==
                            report.databaseVersion else {
                        continue
                    }
                } else {
                    guard object["reportID"] as? NSNull != nil,
                          object[
                              "signatureProofSHA256"
                          ] as? NSNull != nil,
                          object["reportDigest"] as? NSNull != nil,
                          object[
                              "reportReferrerDigest"
                          ] as? NSNull != nil else {
                        continue
                    }
                }
                if observation.decision.outcome ==
                    HostwrightRegistry
                    .ImageVulnerabilityDecisionOutcome.allowed {
                    guard object["decisionMode"] as? String ==
                            "policy-pass" else {
                        continue
                    }
                    authorized = true
                    break
                }
                guard let exceptionID =
                    object["exceptionID"] as? String,
                    object["decisionMode"] as? String ==
                        "approved-exception",
                    let exception =
                    try lifecycleActiveVulnerabilityException(
                        store: store,
                        projectID: plan.projectID,
                        serviceName: serviceName,
                        descriptorDigest:
                            lock.descriptorDigest,
                        policy: policy,
                        signaturePolicySHA256:
                            signaturePolicySHA256,
                        observation: observation,
                        at: now
                    ),
                    exception.id == exceptionID else {
                    continue
                }
                authorized = true
                break
            }
            guard authorized else {
                throw recoveryVulnerabilitySafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
        }
    }

    func preflightImageProvenanceRecovery(
        plan: LifecyclePlan,
        store: SQLiteStateStore
    ) throws {
        let allEvents = try store.events.loadAll()
        let notRequiredObjects = allEvents.compactMap {
            event -> [String: Any]? in
            guard event.type ==
                    "image.provenance.lifecycle.not-required",
                  let data = event.payloadJSONRedacted.data(
                      using: .utf8
                  ),
                  let object =
                    try? JSONSerialization.jsonObject(
                        with: data
                    ) as? [String: Any],
                  object["planSHA256"] as? String ==
                    plan.planSHA256,
                  object["projectID"] as? String ==
                    plan.projectID,
                  object["required"] as? Bool == false else {
                return nil
            }
            return object
        }
        if notRequiredObjects.contains(where: {
            $0["policySHA256"] as? NSNull != nil
        }) {
            let project = try store.desiredStates.loadProject(
                id: plan.projectID
            )
            guard project.manifestHash == plan.manifestSHA256 else {
                throw LifecyclePersistedRecoveryError
                    .confirmationMismatch
            }
            return
        }
        let mapping = try recoveryImageProvenanceMapping(
            plan: plan,
            store: store
        )
        let notRequired = notRequiredObjects.contains { object in
            if let mapping {
                return object["policySHA256"] as? String ==
                    mapping.material.policySHA256 &&
                    mapping.policy.requirement == .optional
            }
            return object["policySHA256"] as? NSNull != nil
        }
        guard let mapping,
              mapping.policy.requirement == .required else {
            guard notRequired else {
                throw recoveryProvenanceSafeHold(
                    plan: plan,
                    serviceName:
                        recoveryDesiredServices(plan: plan)
                        .values.map(\.logicalServiceName)
                        .sorted().first ?? "unknown"
                )
            }
            return
        }

        let authorizationObjects = allEvents
            .filter {
                $0.type ==
                    "image.provenance.lifecycle.authorized"
            }
            .compactMap { event -> [String: Any]? in
                guard let data =
                        event.payloadJSONRedacted.data(using: .utf8),
                      let object =
                        try? JSONSerialization.jsonObject(
                            with: data
                        ) as? [String: Any],
                      object["planSHA256"] as? String ==
                        plan.planSHA256,
                      object["projectID"] as? String ==
                        plan.projectID,
                      object["policySHA256"] as? String ==
                        mapping.material.policySHA256 else {
                    return nil
                }
                return object
            }
        let desired = Dictionary(
            grouping: recoveryDesiredServices(plan: plan).values,
            by: \.logicalServiceName
        ).compactMapValues(\.first)
        for serviceName in desired.keys.sorted() {
            guard let service = desired[serviceName],
                  let lock = service.imageLock else {
                throw recoveryProvenanceSafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
            let records = try store.imageProvenance.loadRecords(
                projectID: plan.projectID,
                serviceName: serviceName,
                descriptorDigest: lock.descriptorDigest,
                policySHA256: mapping.material.policySHA256
            )
            let candidates = authorizationObjects.filter {
                $0["serviceName"] as? String == serviceName &&
                    $0["descriptorDigest"] as? String ==
                        lock.descriptorDigest
            }
            var authorized = false
            for object in candidates {
                guard let recordID = object["recordID"] as? String,
                      let record = records.first(where: {
                          $0.id == recordID
                      }),
                      lifecycleProvenanceEvent(
                          object,
                          exactlyMatches: record
                      ),
                      let current =
                        try lifecycleCurrentProvenanceRecord(
                            records: [record],
                            descriptorDigest:
                                lock.descriptorDigest,
                            policy: mapping.policy,
                            material: mapping.material,
                            store: store,
                            at: Date()
                        ),
                      current.id == record.id else {
                    continue
                }
                authorized = true
                break
            }
            guard authorized else {
                throw recoveryProvenanceSafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
        }
    }

    private func recoveryImageProvenanceMapping(
        plan: LifecyclePlan,
        store: SQLiteStateStore
    ) throws -> ImageProvenancePolicyContext? {
        let project = try store.desiredStates.loadProject(
            id: plan.projectID
        )
        guard project.manifestHash == plan.manifestSHA256,
              let manifestPath = project.manifestPath else {
            throw LifecyclePersistedRecoveryError.unavailable(
                "Recovery cannot resolve the exact persisted manifest for image provenance revalidation."
            )
        }
        let manifestText = try hostwrightReadManifestText(
            path: manifestPath,
            environment: environment
        )
        let validated = try hostwrightValidatedManifest(
            text: manifestText,
            teamProfilePath: nil,
            environment: environment
        )
        guard try lifecycleManifestSHA256(
            text: manifestText,
            manifest: validated.manifest
        ) == plan.manifestSHA256,
              validated.manifest.project.map({
                  "project-\($0)"
              }) == plan.projectID else {
            throw LifecyclePersistedRecoveryError
                .confirmationMismatch
        }
        guard validated.manifest.imageProvenance != nil else {
            return nil
        }
        return try ImageProvenancePolicyMapping.map(
            validated.manifest
        )
    }

    private func recoveryVulnerabilityTrustMapping(
        plan: LifecyclePlan,
        store: SQLiteStateStore
    ) throws -> (
        policy: ImageTrustVerificationPolicy,
        material: ImageTrustPolicyMaterial
    ) {
        let project = try store.desiredStates.loadProject(
            id: plan.projectID
        )
        guard project.manifestHash == plan.manifestSHA256,
              let manifestPath = project.manifestPath else {
            throw LifecyclePersistedRecoveryError.unavailable(
                "Recovery cannot resolve the exact persisted manifest for vulnerability signature revalidation."
            )
        }
        let manifestText = try hostwrightReadManifestText(
            path: manifestPath,
            environment: environment
        )
        let validated = try hostwrightValidatedManifest(
            text: manifestText,
            teamProfilePath: nil,
            environment: environment
        )
        guard try lifecycleManifestSHA256(
            text: manifestText,
            manifest: validated.manifest
        ) == plan.manifestSHA256,
              validated.manifest.project.map({
                  "project-\($0)"
              }) == plan.projectID else {
            throw LifecyclePersistedRecoveryError
                .confirmationMismatch
        }
        return try ImageTrustPolicyMapping.map(
            validated.manifest
        )
    }

    private func recoverySBOMSafeHold(
        plan: LifecyclePlan,
        serviceName: String
    ) -> LifecyclePersistedRecoveryError {
        .unavailable(
            "Recovery requires the exact previously authorized image SBOM evidence for plan \(plan.planSHA256) and service '\(RuntimeRedactionPolicy.default.redact(serviceName))'. No runtime mutation was attempted."
        )
    }

    private func recoveryTrustSafeHold(
        plan: LifecyclePlan,
        serviceName: String
    ) -> LifecyclePersistedRecoveryError {
        .safeHold(
            LifecycleRecoverySafeHold(
                reason:
                    "Image trust authorization for recovery is missing, expired, or no longer matches exact evidence.",
                affectedNodeKeys: plan.nodes.filter {
                    (try? LifecycleRevisionCodec
                        .decodeRedactedDesiredJSON(
                            $0.desiredSpecificationJSONRedacted
                        ).logicalServiceName) == serviceName
                }.map(\.key),
                operatorCommands: [
                    "hostwright registry trust status <manifest> --service \(serviceName) --output json",
                    "hostwright recovery --output json"
                ]
            )
        )
    }

    private func recoveryVulnerabilitySafeHold(
        plan: LifecyclePlan,
        serviceName: String
    ) -> LifecyclePersistedRecoveryError {
        .safeHold(
            LifecycleRecoverySafeHold(
                reason:
                    "Image vulnerability authorization for recovery is missing, expired, or no longer matches exact signed evidence.",
                affectedNodeKeys: plan.nodes.filter {
                    (try? LifecycleRevisionCodec
                        .decodeRedactedDesiredJSON(
                            $0.desiredSpecificationJSONRedacted
                        ).logicalServiceName) == serviceName
                }.map(\.key),
                operatorCommands: [
                    "hostwright registry vulnerability status <manifest> --service \(serviceName) --output json",
                    "hostwright recovery --output json"
                ]
            )
        )
    }

    private func recoveryProvenanceSafeHold(
        plan: LifecyclePlan,
        serviceName: String
    ) -> LifecyclePersistedRecoveryError {
        .safeHold(
            LifecycleRecoverySafeHold(
                reason:
                    "Image provenance authorization for recovery is missing, expired, or no longer matches the exact signed attestation.",
                affectedNodeKeys: plan.nodes.filter {
                    (try? LifecycleRevisionCodec
                        .decodeRedactedDesiredJSON(
                            $0.desiredSpecificationJSONRedacted
                        ).logicalServiceName) == serviceName
                }.map(\.key),
                operatorCommands: [
                    "hostwright registry provenance status <manifest> --service \(serviceName) --output json",
                    "hostwright recovery --output json"
                ]
            )
        )
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
                    isExpiredActive(sourceGroup) ||
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
                lockOwner: "hostwright-recovery-resume",
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

    private func rebindImageRecoveryAuthorizations(
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

    private func isFailedSafeHold(
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
        recoveryStateJSONRedacted: String? = nil,
        allowFailedSafeHoldResume: Bool = false
    ) async throws -> LifecycleSagaExecutionResult {
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
            lockOwner: lockOwner,
            allowFailedSafeHoldResume: allowFailedSafeHoldResume
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
                    $0.resourceGeneration + 1 ==
                        node.resourceGeneration &&
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
        guard capability.providerID == context.plan.providerID,
              capability.capabilitySHA256 ==
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
                idempotencyKey: sha256(
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
            var desired = await state.desiredStateSnapshot()
            if node.action == .create {
                let identity = await state.identity(
                    for: node,
                    projectName: context.plan.projectName
                )
                var hints = desired.ownedResourceHints.filter {
                    $0.resourceIdentifier != node.resourceIdentifier &&
                        $0.ownership?.resourceUUID != node.resourceUUID
                }
                hints.append(
                    RuntimeOwnedResourceHint(
                        resourceIdentifier:
                            node.resourceIdentifier ??
                            identity.managedResourceIdentifier,
                        identity: identity,
                        identityVersion:
                            RuntimeManagedResourceIdentity.currentVersion,
                        ownership: RuntimeInventoryOwnershipEvidence(
                            resourceUUID: node.resourceUUID,
                            projectUUID:
                                context.plan.projectResourceUUID,
                            resourceGeneration:
                                node.resourceGeneration,
                            projectGeneration:
                                context.plan.projectGeneration,
                            providerID: context.plan.providerID,
                            providerGeneration:
                                context.plan.providerGeneration,
                            fencingToken: context.fencingToken
                        )
                    )
                )
                desired = DesiredRuntimeState(
                    projectName: desired.projectName,
                    networks: desired.networks,
                    services: desired.services,
                    ownedResourceHints: hints.sorted {
                        $0.resourceIdentifier <
                            $1.resourceIdentifier
                    }
                )
            }
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
                try reconcileNetworkPorts(
                    node: node,
                    context: context,
                    inventory: inventory
                )
                try await reconcileNetworkAttachments(
                    node: node,
                    context: context,
                    inventory: inventory
                )
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

    private func persistNetworkPortIntent(
        action: PlannedRuntimeAction,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async throws {
        guard node.action == .create ||
                node.action == .delete ||
                node.action == .retire else {
            return
        }
        if node.action == .create {
            guard let desired = action.desiredService else {
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "Port reservation requires the exact desired service before runtime creation."
                )
            }
            guard !desired.ports.isEmpty else {
                return
            }
            let group = try exactNetworkPortOperationGroup(
                context: context
            )
            let inventory = try await adapter.inventory()
            _ = try NetworkPortLifecycleCoordinator.reserve(
                service: desired,
                node: node,
                plan: context.plan,
                group: group,
                inventory: inventory,
                store: store,
                isAvailable:
                    NetworkPortSocketAvailability.isAvailable
            )
            return
        }
        let portRecords = try store.networkPorts.loadProject(
            projectUUID: context.plan.projectResourceUUID
        ).filter {
            $0.resourceUUID == node.resourceUUID
        }
        guard !portRecords.isEmpty else {
            return
        }
        let group = try exactNetworkPortOperationGroup(
            context: context
        )
        let inventory = try await adapter.inventory()
        let priorFencingToken = await state.binding(
            resourceUUID: node.resourceUUID,
            resourceIdentifier: node.resourceIdentifier
        )?.currentFencingToken
        _ = try NetworkPortLifecycleCoordinator.beginRelease(
            node: node,
            plan: context.plan,
            group: group,
            inventory: inventory,
            priorFencingToken: priorFencingToken,
            store: store
        )
    }

    private func reconcileNetworkPorts(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        inventory: RuntimeInventory
    ) throws {
        guard node.action == .create ||
                node.action == .delete ||
                node.action == .retire else {
            return
        }
        let portRecords = try store.networkPorts.loadProject(
            projectUUID: context.plan.projectResourceUUID
        ).filter {
            $0.resourceUUID == node.resourceUUID
        }
        guard !portRecords.isEmpty else {
            return
        }
        let group = try exactNetworkPortOperationGroup(
            context: context
        )
        if node.action == .create {
            _ = try NetworkPortLifecycleCoordinator.confirmActive(
                node: node,
                plan: context.plan,
                group: group,
                inventory: inventory,
                store: store
            )
            return
        }
        _ = try NetworkPortLifecycleCoordinator.confirmReleased(
            node: node,
            plan: context.plan,
            group: group,
            inventory: inventory,
            store: store
        )
    }

    private func exactNetworkPortOperationGroup(
        context: LifecycleSagaContext
    ) throws -> OperationGroupRecord {
        guard let group = try store.operationGroups.load(
            id: context.groupID
        ),
        group.status == .active,
        group.groupKind == "lifecycle-v1",
        group.projectID == context.plan.projectID,
        group.planHash == context.plan.planSHA256,
        group.groupIdempotencyKey ==
            context.plan.planSHA256,
        group.fencingToken == context.fencingToken else {
            throw HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message:
                    "Port lifecycle lost the exact active operation-group authority."
            )
        }
        return group
    }

    private func persistNetworkAttachmentIntent(
        action: PlannedRuntimeAction,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async throws {
        switch action.kind {
        case .create:
            guard let desired = action.desiredService,
                  !desired.networks.isEmpty else {
                return
            }
            let authority = try await networkAttachmentAuthority(
                context: context
            )
            let repository = store.networks
            for attachment in desired.networks.sorted(
                by: {
                    if $0.networkRuntimeIdentifier !=
                        $1.networkRuntimeIdentifier {
                        return $0.networkRuntimeIdentifier <
                            $1.networkRuntimeIdentifier
                    }
                    return $0.networkResourceUUID <
                        $1.networkResourceUUID
                }
            ) {
                guard let network = try repository.loadNetwork(
                    id: attachment.networkResourceUUID
                ),
                network.runtimeName ==
                    attachment.networkRuntimeIdentifier else {
                    throw NetworkAttachmentLifecycleError
                        .ownershipConflict(
                            "Create-time attachment requires one exact available network record."
                        )
                }
                let descriptor = try NetworkAttachmentCreateDescriptor(
                    network: network,
                    containerRuntimeIdentifier:
                        action.resourceIdentifier,
                    containerContext:
                        mutationContext(
                            node: node,
                            context: context
                        ),
                    aliases: attachment.aliases
                )
                _ = try NetworkAttachmentLifecycle
                    .persistCreateIntent(
                        descriptor,
                        authority: authority,
                        timestamp: hostwrightTimestamp(),
                        repository: repository
                    )
            }
        case .remove:
            let authority = try await networkAttachmentAuthority(
                context: context
            )
            let repository = store.networks
            let records = try NetworkAttachmentLifecycle
                .reverseReleaseOrder(
                    projectUUID:
                        context.plan.projectResourceUUID,
                    resourceUUID: node.resourceUUID,
                    providerID: context.plan.providerID,
                    providerGeneration:
                        context.plan.providerGeneration,
                    repository: repository
                )
            for record in records {
                _ = try NetworkAttachmentLifecycle
                    .persistReleaseIntent(
                        record: record,
                        authority: authority,
                        timestamp: hostwrightTimestamp(),
                        repository: repository
                    )
            }
        case .start, .stop, .restart, .update, .noOp:
            return
        }
    }

    private func reconcileNetworkAttachments(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext,
        inventory: RuntimeInventory
    ) async throws {
        let repository = store.networks
        let authority = try await networkAttachmentAuthority(
            context: context
        )
        if node.action == .create,
           let desired = await state.desiredService(for: node.key) {
            let containerIdentifier =
                node.resourceIdentifier ??
                desired.identity.managedResourceIdentifier
            for attachment in desired.networks.sorted(
                by: {
                    if $0.networkRuntimeIdentifier !=
                        $1.networkRuntimeIdentifier {
                        return $0.networkRuntimeIdentifier <
                            $1.networkRuntimeIdentifier
                    }
                    return $0.networkResourceUUID <
                        $1.networkResourceUUID
                }
            ) {
                guard let network = try repository.loadNetwork(
                    id: attachment.networkResourceUUID
                ) else {
                    throw NetworkAttachmentLifecycleError
                        .ownershipConflict(
                            "Attachment verification lost its exact network record."
                        )
                }
                let descriptor = try NetworkAttachmentCreateDescriptor(
                    network: network,
                    containerRuntimeIdentifier:
                        containerIdentifier,
                    containerContext:
                        mutationContext(
                            node: node,
                            context: context
                        ),
                    aliases: attachment.aliases
                )
                guard let record = try repository.loadAttachment(
                    id: descriptor.attachmentUUID
                ) else {
                    throw NetworkAttachmentLifecycleError
                        .ownershipConflict(
                            "Attachment verification lost its durable pre-mutation intent."
                        )
                }
                switch try NetworkAttachmentLifecycle
                    .resolveCreateObservation(
                        record: record,
                        descriptor: descriptor,
                        inventory: inventory,
                        trigger: .postMutation,
                        authority: authority,
                        timestamp: hostwrightTimestamp(),
                        repository: repository
                    ) {
                case .attached:
                    break
                case .absent:
                    throw NetworkAttachmentLifecycleError
                        .observationIndeterminate(
                            "Structured observation did not prove the requested create-time network attachment."
                        )
                case .quarantined:
                    throw NetworkAttachmentLifecycleError
                        .ownershipConflict(
                            "Structured observation found ambiguous network attachment ownership."
                        )
                }
            }
        }
        if node.action == .delete || node.action == .retire {
            let containerIdentifier: String
            if let resourceIdentifier =
                node.resourceIdentifier {
                containerIdentifier = resourceIdentifier
            } else {
                containerIdentifier = await state.identity(
                    for: node,
                    projectName: context.plan.projectName
                ).managedResourceIdentifier
            }
            let records = try NetworkAttachmentLifecycle
                .reverseReleaseOrder(
                    projectUUID:
                        context.plan.projectResourceUUID,
                    resourceUUID: node.resourceUUID,
                    providerID: context.plan.providerID,
                    providerGeneration:
                        context.plan.providerGeneration,
                    repository: repository
                )
            for record in records {
                try NetworkAttachmentLifecycle
                    .releaseAfterVerifiedAbsence(
                        record: record,
                        containerRuntimeIdentifier:
                            containerIdentifier,
                        inventory: inventory,
                        authority: authority,
                        timestamp: hostwrightTimestamp(),
                        repository: repository
                    )
            }
        }
    }

    private func networkAttachmentAuthority(
        context: LifecycleSagaContext
    ) async throws -> NetworkStateMutationAuthority {
        let capability = try await adapter.capabilitySnapshot()
        guard capability.descriptor.providerID ==
                context.plan.providerID,
              capability.canonicalSHA256 ==
                context.plan.capabilitySHA256 else {
            throw NetworkAttachmentLifecycleError
                .ownershipConflict(
                    "Network attachment mutation refused a stale capability snapshot."
                )
        }
        return NetworkStateMutationAuthority(
            providerID: context.plan.providerID.rawValue,
            providerGeneration:
                Int64(context.plan.providerGeneration),
            operationGroupID: context.groupID,
            fencingToken: context.fencingToken,
            plannedCapabilitySHA256:
                context.plan.capabilitySHA256,
            currentCapabilitySHA256:
                capability.canonicalSHA256
        )
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
        _ service: DesiredRuntimeService,
        workload: HostwrightSecretWorkloadScope
    ) throws -> DesiredRuntimeService {
        guard service.environment.contains(where: { $0.secretReference != nil }) else {
            return service
        }
        let secretResolver = environment.secretResolver()
        let resolved = try service.environment.map { entry in
            guard let reference = entry.secretReference else {
                return entry
            }
            return RuntimeEnvironmentValue(
                name: entry.name,
                value: try secretResolver.resolve(
                    reference: reference,
                    for: workload,
                    environmentKey: entry.name,
                    at: Date()
                ).stringValue(),
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
        if let service = await state.desiredService(for: node.key) {
            if kind == .create {
                desiredService = try resolveSecretReferences(
                    service,
                    workload: try lifecycleSecretWorkloadScope(
                        projectResourceUUID: plan.projectResourceUUID,
                        resourceUUID: node.resourceUUID,
                        generation: node.resourceGeneration,
                        serviceName: service.logicalServiceName
                    )
                )
            } else {
                desiredService = service
            }
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
            ownership.providerGeneration == plan.providerGeneration
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
            return exactContainer == nil &&
                (observedService == nil ||
                    observedService?.lifecycleState == .missing)
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
        if context.direction == .forward,
           node.action == .create,
           exactContainer != nil,
           let desiredForNode,
           let imageLock = desiredForNode.imageLock {
            let record = ImageDigestLockRecord(
                id: HostwrightResourceUUID.legacy(
                    kind: "image-digest-lock-observed",
                    identifier:
                        "\(context.plan.planSHA256):\(node.resourceUUID)"
                ),
                projectID: context.plan.projectID,
                resourceUUID: node.resourceUUID,
                serviceName: desiredForNode.logicalServiceName,
                replicaIndex: desiredForNode.replicaIndex,
                stateKind: .observed,
                lock: imageLock,
                providerGeneration: context.plan.providerGeneration,
                planSHA256: context.plan.planSHA256,
                operationGroupID: context.groupID,
                observationSHA256: observationSHA256,
                createdAt: now,
                updatedAt: now
            )
            try store.imageDigestLocks.save(record)
        }
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
    adapter: any RuntimeAdapter,
    store: SQLiteStateStore,
    manifest: HostwrightManifest
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
    try lifecyclePreflightImageTrust(
        planSHA256: compiled.plan.planSHA256,
        projectID: preparation.projectID,
        providerID: preparation.providerID,
        desiredState: preparation.desiredState,
        store: store,
        manifest: manifest
    )
    try lifecyclePreflightImageSBOM(
        planSHA256: compiled.plan.planSHA256,
        projectID: preparation.projectID,
        providerID: preparation.providerID,
        desiredState: preparation.desiredState,
        store: store,
        manifest: manifest
    )
    try lifecyclePreflightImageVulnerability(
        planSHA256: compiled.plan.planSHA256,
        projectID: preparation.projectID,
        providerID: preparation.providerID,
        desiredState: preparation.desiredState,
        store: store,
        manifest: manifest,
        at: environment.registryDate()
    )
    try lifecyclePreflightImageProvenance(
        planSHA256: compiled.plan.planSHA256,
        projectID: preparation.projectID,
        providerID: preparation.providerID,
        desiredState: preparation.desiredState,
        store: store,
        manifest: manifest
    )
    let probeCapabilities = lifecycleProbeCapabilities(for: capability)
    let interactiveCapabilities = RuntimeInteractiveCapabilityContract(
        snapshot: capability
    )
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
        let secretResolver = environment.secretResolver()
        let secretNode = compiled.plan.nodes.first { node in
            node.action == .create &&
                compiled.desiredServicesByNodeKey[node.key]?.identity ==
                    service.identity
        }
        let sanitizedEnvironment = try service.environment
            .sorted { $0.name < $1.name }
            .map { entry -> RuntimeEnvironmentValue in
                guard let reference = entry.secretReference else {
                    return entry
                }
                guard let secretNode else {
                    return RuntimeEnvironmentValue(
                        name: entry.name,
                        value: RuntimeRedactionPolicy.default.replacement,
                        isSensitive: true
                    )
                }
                do {
                    let workload = try lifecycleSecretWorkloadScope(
                        projectResourceUUID: compiled.plan.projectResourceUUID,
                        resourceUUID: secretNode.resourceUUID,
                        generation: secretNode.resourceGeneration,
                        serviceName: service.logicalServiceName
                    )
                    _ = try secretResolver.resolve(
                        reference: reference,
                        for: workload,
                        environmentKey: entry.name,
                        at: Date()
                    )
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

func lifecyclePreflightImageTrust(
    planSHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    desiredState: DesiredRuntimeState,
    store: SQLiteStateStore,
    manifest: HostwrightManifest
) throws {
    guard manifest.imageTrust != nil else { return }
    let mapping = try ImageTrustPolicyMapping.map(manifest)
    let now = Date()
    let timestamp = hostwrightTimestamp()
    let rootSHA256 =
        mapping.material.trustedRootSHA256 ?? lifecycleSHA256(Data())
    let activeAuthorityIDs = Set(
        mapping.policy.authorities.filter { authority in
            if let notBefore = authority.notBefore, now < notBefore {
                return false
            }
            if let notAfter = authority.notAfter, now > notAfter {
                return false
            }
            if let revokedAt = authority.revokedAt, now >= revokedAt {
                return false
            }
            return true
        }.map(\.id)
    )
    let services = Dictionary(
        grouping: desiredState.services,
        by: \.logicalServiceName
    ).compactMapValues(\.first)

    for serviceName in services.keys.sorted() {
        guard let service = services[serviceName],
              let lock = service.imageLock else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Image trust requires an exact provider-bound digest lock for every desired service. No runtime mutation was attempted."
            )
        }
        let verifications = try store.imageTrust.loadVerifications(
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest: lock.descriptorDigest
        )
        var verified = false
        for record in verifications.reversed() {
            let matched = Set(record.matchedAuthorityIDs)
            guard record.policySHA256 == mapping.material.policySHA256,
                  record.trustedRootSHA256 == rootSHA256,
                  record.outcome ==
                    ImageTrustVerificationOutcome.passed.rawValue,
                  record.threshold == mapping.policy.threshold,
                  matched.count >= record.threshold,
                  matched.isSubset(of: activeAuthorityIDs),
                  let discovery = try store.ociReferrers.loadDiscovery(
                      id: record.evidenceDiscoveryID
                  ),
                  discovery.complete,
                  discovery.graphSHA256 == record.evidenceGraphSHA256,
                  discovery.subjectDigest == lock.descriptorDigest,
                  let graph = try store.ociReferrers.loadGraph(
                      discoveryID: record.evidenceDiscoveryID
                  ),
                  graph.discovery.subjectDigest.canonicalValue ==
                    lock.descriptorDigest,
                  let subject = try store.imageTrust.loadSubjectManifest(
                      endpoint: discovery.registryEndpoint,
                      repository: discovery.repository,
                      descriptorDigest: lock.descriptorDigest
                  ),
                  subject.payloadSHA256 ==
                    String(lock.descriptorDigest.dropFirst(7)),
                  lifecycleSHA256(subject.payload) ==
                    subject.payloadSHA256,
                  (try? ImageTrustEvidenceExtractor.bundles(
                      from: graph
                  )) != nil else {
                continue
            }
            verified = true
            try lifecycleRecordTrustAuthorization(
                store: store,
                timestamp: timestamp,
                planSHA256: planSHA256,
                projectID: projectID,
                providerID: providerID,
                serviceName: serviceName,
                descriptorDigest: lock.descriptorDigest,
                policySHA256: mapping.material.policySHA256,
                authorization: "verified",
                verification: record,
                exception: nil
            )
            break
        }
        if verified { continue }

        if let exception = try store.imageTrust.activeException(
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest: lock.descriptorDigest,
            policySHA256: mapping.material.policySHA256,
            currentTimestamp: timestamp
        ) {
            let payload = try JSONSerialization.data(
                withJSONObject: [
                    "exceptionID": exception.id,
                    "descriptorDigest": lock.descriptorDigest,
                    "policySHA256": mapping.material.policySHA256
                ],
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            try store.events.append([
                EventRecord(
                    id: UUID().uuidString.lowercased(),
                    timestamp: timestamp,
                    severity: .warning,
                    type: "image.trust.exception.used",
                    source: "hostwright.lifecycle",
                    projectID: projectID,
                    serviceName: serviceName,
                    runtimeAdapter: providerID.rawValue,
                    message: "An exact active image trust exception authorized lifecycle preflight.",
                    payloadJSONRedacted:
                        String(decoding: payload, as: UTF8.self)
                ),
                try lifecycleTrustAuthorizationEvent(
                    timestamp: timestamp,
                    planSHA256: planSHA256,
                    projectID: projectID,
                    providerID: providerID,
                    serviceName: serviceName,
                    descriptorDigest: lock.descriptorDigest,
                    policySHA256:
                        mapping.material.policySHA256,
                    authorization: "exception",
                    verification: nil,
                    exception: exception
                )
            ])
            continue
        }
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "No current image trust verification or exact active exception matches service '\(RuntimeRedactionPolicy.default.redact(serviceName))'. No runtime mutation was attempted."
        )
    }
}

func lifecyclePreflightImageSBOM(
    planSHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    desiredState: DesiredRuntimeState,
    store: SQLiteStateStore,
    manifest: HostwrightManifest
) throws {
    guard let source = manifest.imageSBOM,
          source.requirement == .required else {
        return
    }
    let policy = try ImageSBOMPolicyMapping.map(manifest)
    let requiredFormats = Set(policy.formats.map(\.rawValue))
    let services = Dictionary(
        grouping: desiredState.services,
        by: \.logicalServiceName
    ).compactMapValues(\.first)
    for serviceName in services.keys.sorted() {
        guard let service = services[serviceName],
              let lock = service.imageLock else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Required image SBOM policy needs an exact provider-bound digest lock for every desired service. No runtime mutation was attempted."
            )
        }
        let records = try store.imageSBOM.loadRecords(
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest: lock.descriptorDigest,
            policySHA256: policy.policySHA256
        )
        let verified = try lifecycleVerifiedSBOMFormats(
            records: records,
            descriptorDigest: lock.descriptorDigest,
            store: store
        )
        guard requiredFormats.isSubset(of: verified) else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Required exact image SBOM evidence is missing or invalid for service '\(RuntimeRedactionPolicy.default.redact(serviceName))'. No runtime mutation was attempted."
            )
        }
        let applicable = records.filter {
            verified.contains($0.format.rawValue)
        }
        let object: [String: Any] = [
            "planSHA256": planSHA256,
            "projectID": projectID,
            "serviceName": serviceName,
            "descriptorDigest": lock.descriptorDigest,
            "policySHA256": policy.policySHA256,
            "formats": requiredFormats.sorted(),
            "records": applicable.map {
                [
                    "format": $0.format.rawValue,
                    "documentDigest": $0.documentDigest,
                    "discoveryID": $0.evidenceDiscoveryID,
                    "graphSHA256": $0.evidenceGraphSHA256,
                    "referrerDigest": $0.sbomReferrerDigest
                ]
            }
        ]
        let payload = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try store.events.append([
            EventRecord(
                id: UUID().uuidString.lowercased(),
                timestamp: hostwrightTimestamp(),
                severity: .info,
                type: "image.sbom.lifecycle.authorized",
                source: "hostwright.lifecycle",
                projectID: projectID,
                serviceName: serviceName,
                runtimeAdapter: providerID.rawValue,
                message:
                    "Exact image SBOM evidence authorized lifecycle execution.",
                payloadJSONRedacted:
                    String(decoding: payload, as: UTF8.self)
            )
        ])
    }
}

func lifecyclePreflightImageVulnerability(
    planSHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    desiredState: DesiredRuntimeState,
    store: SQLiteStateStore,
    manifest: HostwrightManifest,
    at now: Date = Date()
) throws {
    guard manifest.imageVulnerability != nil else {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "planSHA256": planSHA256,
                "projectID": projectID,
                "required": false
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try store.events.append([
            EventRecord(
                id: UUID().uuidString.lowercased(),
                timestamp: hostwrightTimestamp(),
                severity: .info,
                type:
                    "image.vulnerability.lifecycle.not-required",
                source: "hostwright.lifecycle",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: providerID.rawValue,
                message:
                    "Image vulnerability policy was not required for this exact lifecycle plan.",
                payloadJSONRedacted:
                    String(decoding: payload, as: UTF8.self)
            )
        ])
        return
    }
    let policy = try ImageVulnerabilityPolicyMapping.map(manifest)
    let trust = try ImageTrustPolicyMapping.map(manifest)
    let signaturePolicySHA256 =
        trust.material.policySHA256
    let services = Dictionary(
        grouping: desiredState.services,
        by: \.logicalServiceName
    ).compactMapValues(\.first)
    for serviceName in services.keys.sorted() {
        guard let service = services[serviceName],
              let lock = service.imageLock else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Image vulnerability policy requires an exact provider-bound digest lock for every desired service. No runtime mutation was attempted."
            )
        }
        let observation =
            try lifecycleCurrentVulnerabilityObservation(
                store: store,
                projectID: projectID,
                serviceName: serviceName,
                descriptorDigest: lock.descriptorDigest,
                policy: policy,
                signaturePolicySHA256:
                    signaturePolicySHA256,
                signaturePolicy: trust.policy,
                signatureMaterial: trust.material,
                at: now
            )
        var exception:
            ImageVulnerabilityExceptionRecord?
        if observation.decision.outcome ==
            HostwrightRegistry
            .ImageVulnerabilityDecisionOutcome.blocked {
            exception =
                try lifecycleActiveVulnerabilityException(
                    store: store,
                    projectID: projectID,
                    serviceName: serviceName,
                    descriptorDigest: lock.descriptorDigest,
                    policy: policy,
                    signaturePolicySHA256:
                        signaturePolicySHA256,
                    observation: observation,
                    at: now
                )
            guard exception != nil else {
                throw RuntimeAdapterError
                    .mutationUnavailableByPolicy(
                        "Image vulnerability policy blocked service '\(RuntimeRedactionPolicy.default.redact(serviceName))'. No runtime mutation was attempted."
                    )
            }
        }
        let object: [String: Any] = [
            "planSHA256": planSHA256,
            "projectID": projectID,
            "serviceName": serviceName,
            "descriptorDigest": lock.descriptorDigest,
            "policySHA256": policy.policySHA256,
            "signaturePolicySHA256":
                signaturePolicySHA256,
            "policy":
                lifecycleVulnerabilityPolicyObject(policy),
            "authorization":
                exception == nil ? "policy" : "exception",
            "decisionMode":
                exception == nil
                    ? "policy-pass" : "approved-exception",
            "exceptionID": exception?.id ?? NSNull(),
            "reportID":
                observation.report?.id ?? NSNull(),
            "signatureProofSHA256":
                observation.report?.signatureProofSHA256 ??
                NSNull(),
            "reportDigest":
                observation.decision.reportDigest ?? NSNull(),
            "reportReferrerDigest":
                observation.decision.referrerDigest ??
                NSNull(),
            "databaseID":
                observation.decision.databaseID ?? NSNull(),
            "databaseVersion":
                observation.decision.databaseVersion ??
                NSNull(),
            "decisionID":
                observation.decision.decisionID,
            "decisionDigest":
                observation.decision.decisionDigest,
            "decisionOutcome":
                observation.decision.outcome.rawValue,
            "blockedFindingsSHA256":
                observation.decision.blockedFindingsSHA256,
            "reasonCodes":
                observation.decision.reasonCodes.map(\.rawValue)
        ]
        let payload = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        var events = [
            EventRecord(
                id: UUID().uuidString.lowercased(),
                timestamp: hostwrightTimestamp(),
                severity:
                    exception == nil ? .info : .warning,
                type:
                    "image.vulnerability.lifecycle.authorized",
                source: "hostwright.lifecycle",
                projectID: projectID,
                serviceName: serviceName,
                runtimeAdapter: providerID.rawValue,
                message:
                    "Exact image vulnerability policy evidence authorized lifecycle execution.",
                payloadJSONRedacted:
                    String(decoding: payload, as: UTF8.self)
            )
        ]
        if let exception {
            let exceptionPayload = try JSONSerialization.data(
                withJSONObject: [
                    "planSHA256": planSHA256,
                    "projectID": projectID,
                    "serviceName": serviceName,
                    "descriptorDigest":
                        lock.descriptorDigest,
                    "exceptionID": exception.id,
                    "decisionID": exception.decisionID,
                    "reportID": exception.reportID,
                    "expiresAt": exception.expiresAt
                ],
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            events.append(
                EventRecord(
                    id: UUID().uuidString.lowercased(),
                    timestamp: hostwrightTimestamp(),
                    severity: .warning,
                    type:
                        "image.vulnerability.exception.used",
                    source: "hostwright.lifecycle",
                    projectID: projectID,
                    serviceName: serviceName,
                    runtimeAdapter: providerID.rawValue,
                    message:
                        "An exact active image vulnerability exception authorized lifecycle preflight.",
                    payloadJSONRedacted: String(
                        decoding: exceptionPayload,
                        as: UTF8.self
                    )
                )
            )
        }
        try store.events.append(events)
    }
}

func lifecyclePreflightImageProvenance(
    planSHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    desiredState: DesiredRuntimeState,
    store: SQLiteStateStore,
    manifest: HostwrightManifest
) throws {
    let mapping = try manifest.imageProvenance.map { _ in
        try ImageProvenancePolicyMapping.map(manifest)
    }
    guard let mapping,
          mapping.policy.requirement == .required else {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "planSHA256": planSHA256,
                "projectID": projectID,
                "required": false,
                "policySHA256": mapping.map {
                    $0.material.policySHA256 as Any
                } ?? NSNull()
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try store.events.append([
            EventRecord(
                id: UUID().uuidString.lowercased(),
                timestamp: hostwrightTimestamp(),
                severity: .info,
                type:
                    "image.provenance.lifecycle.not-required",
                source: "hostwright.lifecycle",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: providerID.rawValue,
                message:
                    "Image provenance policy was not required for this exact lifecycle plan.",
                payloadJSONRedacted:
                    String(decoding: payload, as: UTF8.self)
            )
        ])
        return
    }

    let services = Dictionary(
        grouping: desiredState.services,
        by: \.logicalServiceName
    ).compactMapValues(\.first)
    let now = Date()
    for serviceName in services.keys.sorted() {
        guard let service = services[serviceName],
              let lock = service.imageLock else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Required image provenance policy needs an exact provider-bound digest lock for every desired service. No runtime mutation was attempted."
            )
        }
        let records = try store.imageProvenance.loadRecords(
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest: lock.descriptorDigest,
            policySHA256: mapping.material.policySHA256
        )
        guard let record = try lifecycleCurrentProvenanceRecord(
            records: records,
            descriptorDigest: lock.descriptorDigest,
            policy: mapping.policy,
            material: mapping.material,
            store: store,
            at: now
        ) else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Required exact image provenance is missing, expired, or invalid for service '\(RuntimeRedactionPolicy.default.redact(serviceName))'. No runtime mutation was attempted."
            )
        }
        try store.events.append([
            try lifecycleProvenanceAuthorizationEvent(
                planSHA256: planSHA256,
                projectID: projectID,
                providerID: providerID,
                serviceName: serviceName,
                descriptorDigest: lock.descriptorDigest,
                record: record
            )
        ])
    }
}

private struct LifecycleVulnerabilityObservation {
    let report: ImageVulnerabilityReportRecord?
    let evidence: ImageVulnerabilityEvidence?
    let decision:
        HostwrightRegistry.ImageVulnerabilityDecision
}

private func lifecycleCurrentVulnerabilityObservation(
    store: SQLiteStateStore,
    projectID: String,
    serviceName: String,
    descriptorDigest: String,
    policy: ImageVulnerabilityPolicy,
    signaturePolicySHA256: String,
    signaturePolicy: ImageTrustVerificationPolicy? = nil,
    signatureMaterial: ImageTrustPolicyMaterial? = nil,
    at now: Date
) throws -> LifecycleVulnerabilityObservation {
    let persistedReports =
        try store.imageVulnerability.loadReports(
        projectID: projectID,
        serviceName: serviceName,
        descriptorDigest: descriptorDigest
    )
    let reports = persistedReports.filter {
        $0.signaturePolicySHA256 ==
            signaturePolicySHA256
    }
    guard !reports.isEmpty || persistedReports.isEmpty else {
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "Persisted vulnerability reports do not match the active signature trust material. No runtime mutation was attempted."
        )
    }
    let selected:
        (ImageVulnerabilityReportRecord,
         ImageVulnerabilityEvidence)?
    if let report = try lifecycleAuthoritativeVulnerabilityReport(
        reports
    ) {
        do {
            selected = (
                report,
                try lifecycleVerifiedVulnerabilityEvidence(
                    store: store,
                    report: report,
                    descriptorDigest: descriptorDigest,
                    signaturePolicy: signaturePolicy,
                    signatureMaterial: signatureMaterial,
                    at: now
                )
            )
        } catch {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "The latest persisted vulnerability report failed exact graph revalidation. No runtime mutation was attempted."
            )
        }
    } else {
        selected = nil
    }
    let decision =
        try ImageVulnerabilityPolicyEvaluator.evaluate(
            evidence: selected?.1,
            expectedSubjectDigest:
                OCIContentDigest(descriptorDigest),
            policy: policy,
            signaturePolicySHA256:
                signaturePolicySHA256,
            at: now
        )
    return LifecycleVulnerabilityObservation(
        report: selected?.0,
        evidence: selected?.1,
        decision: decision
    )
}

private func lifecycleAuthoritativeVulnerabilityReport(
    _ reports: [ImageVulnerabilityReportRecord]
) throws -> ImageVulnerabilityReportRecord? {
    let ordered = try reports.sorted { lhs, rhs in
        guard let leftDatabase =
                lifecycleEpochMilliseconds(
                    lhs.databaseUpdatedAt
                ),
              let rightDatabase =
                lifecycleEpochMilliseconds(
                    rhs.databaseUpdatedAt
                ),
              let leftGenerated =
                lifecycleEpochMilliseconds(lhs.generatedAt),
              let rightGenerated =
                lifecycleEpochMilliseconds(rhs.generatedAt) else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Persisted vulnerability report timestamps are invalid. No runtime mutation was attempted."
            )
        }
        if leftDatabase != rightDatabase {
            return leftDatabase < rightDatabase
        }
        if leftGenerated != rightGenerated {
            return leftGenerated < rightGenerated
        }
        return lhs.reportDigest < rhs.reportDigest
    }
    guard let selected = ordered.last else { return nil }
    let peers = ordered.filter {
        $0.databaseUpdatedAt == selected.databaseUpdatedAt &&
        $0.generatedAt == selected.generatedAt
    }
    let identities = Set(peers.map {
        [
            $0.reportDigest,
            $0.reportReferrerDigest,
            $0.databaseID,
            $0.databaseVersion
        ].joined(separator: "\u{1f}")
    })
    guard identities.count == 1 else {
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "The newest vulnerability database evidence is ambiguous. No runtime mutation was attempted."
        )
    }
    return selected
}

private func lifecycleVerifiedVulnerabilityEvidence(
    store: SQLiteStateStore,
    report: ImageVulnerabilityReportRecord,
    descriptorDigest: String,
    signaturePolicy: ImageTrustVerificationPolicy?,
    signatureMaterial: ImageTrustPolicyMaterial?,
    at now: Date
) throws -> ImageVulnerabilityEvidence {
    guard let discovery = try store.ociReferrers.loadDiscovery(
            id: report.evidenceDiscoveryID
          ),
          discovery.complete,
          discovery.subjectDigest == descriptorDigest,
          discovery.graphSHA256 ==
            report.evidenceGraphSHA256,
          let graph = try store.ociReferrers.loadGraph(
              discoveryID: report.evidenceDiscoveryID
          ),
          graph.discovery.subjectDigest.canonicalValue ==
            descriptorDigest else {
        throw ImageVulnerabilityError.invalidGraph
    }
    let evidence = try ImageVulnerabilityEvidenceExtractor.extract(
        from: graph,
        expectedSubjectDigest:
            OCIContentDigest(descriptorDigest)
    ).filter {
        $0.referrerDigest.canonicalValue ==
            report.reportReferrerDigest &&
        $0.report.reportDigest.canonicalValue ==
            report.reportDigest &&
        $0.report.database.id == report.databaseID &&
        $0.report.database.version ==
            report.databaseVersion &&
        $0.report.database.updatedAt ==
            report.databaseUpdatedAt &&
        $0.report.generatedAt == report.generatedAt &&
        !$0.signatureBundles.isEmpty
    }
    guard evidence.count == 1, let value = evidence.first else {
        throw ImageVulnerabilityError.invalidGraph
    }
    try lifecycleValidateVulnerabilitySignatureProof(
        report.signatureProof,
        evidence: value,
        signaturePolicy: signaturePolicy,
        signatureMaterial: signatureMaterial,
        at: now
    )
    return value
}

private func lifecycleValidateVulnerabilitySignatureProof(
    _ proof: ImageVulnerabilitySignatureProof,
    evidence: ImageVulnerabilityEvidence,
    signaturePolicy: ImageTrustVerificationPolicy?,
    signatureMaterial: ImageTrustPolicyMaterial?,
    at now: Date
) throws {
    guard proof.outcome == .passed,
          proof.bundleDigests ==
            evidence.signatureBundles.map(\.digest).sorted()
    else {
        throw ImageVulnerabilityError.invalidGraph
    }
    guard let signaturePolicy, let signatureMaterial else {
        return
    }
    let activeAuthorityIDs = Set(
        signaturePolicy.authorities.compactMap {
            authority -> String? in
            if let notBefore = authority.notBefore,
               now < notBefore {
                return nil
            }
            if let notAfter = authority.notAfter,
               now > notAfter {
                return nil
            }
            if let revokedAt = authority.revokedAt,
               now >= revokedAt {
                return nil
            }
            return authority.id
        }
    )
    let matchedAuthorityIDs = Set(proof.matchedAuthorityIDs)
    guard proof.threshold == signaturePolicy.threshold,
          matchedAuthorityIDs.count >= proof.threshold,
          matchedAuthorityIDs.isSubset(of: activeAuthorityIDs),
          proof.trustedRootSHA256 ==
            signatureMaterial.trustedRootSHA256,
          proof.authorityMaterialSHA256 ==
            signatureMaterial.authorityMaterialSHA256 else {
        throw ImageVulnerabilityError.invalidGraph
    }
}

private func lifecycleActiveVulnerabilityException(
    store: SQLiteStateStore,
    projectID: String,
    serviceName: String,
    descriptorDigest: String,
    policy: ImageVulnerabilityPolicy,
    signaturePolicySHA256: String,
    observation: LifecycleVulnerabilityObservation,
    at now: Date
) throws -> ImageVulnerabilityExceptionRecord? {
    let current = observation.decision
    guard current.outcome ==
            HostwrightRegistry
            .ImageVulnerabilityDecisionOutcome.blocked,
          current.exceptionApproval == .required,
          let currentReport = observation.report else {
        return nil
    }
    let decisions = try store.imageVulnerability.loadDecisions(
        projectID: projectID,
        serviceName: serviceName,
        descriptorDigest: descriptorDigest,
        policySHA256: policy.policySHA256
    )
    for decision in decisions.reversed()
    where decision.outcome ==
        HostwrightState
        .ImageVulnerabilityDecisionOutcome.blocked &&
        decision.signaturePolicySHA256 ==
            signaturePolicySHA256
    {
        guard let reportID = decision.reportID,
              let report = try store.imageVulnerability
                .loadReport(id: reportID),
              report.id == currentReport.id,
              current.reportDigest == report.reportDigest,
              current.referrerDigest ==
                report.reportReferrerDigest,
              current.databaseID == report.databaseID,
              current.databaseVersion ==
                report.databaseVersion,
              current.policySHA256 ==
                decision.policySHA256,
              current.signaturePolicySHA256 ==
                decision.signaturePolicySHA256,
              current.blockedFindingsSHA256 ==
                decision.blockingFindingsSHA256 else {
            continue
        }
        if let exception = try store.imageVulnerability
            .activeException(
                projectID: projectID,
                serviceName: serviceName,
                descriptorDigest: descriptorDigest,
                decisionID: decision.id,
                decisionDigest: decision.decisionDigest,
                reportID: report.id,
                reportDigest: report.reportDigest,
                reportReferrerDigest:
                    report.reportReferrerDigest,
                policySHA256: decision.policySHA256,
                signaturePolicySHA256:
                    decision.signaturePolicySHA256,
                databaseID: report.databaseID,
                databaseVersion: report.databaseVersion,
                blockedFindingsSHA256:
                    decision.blockingFindingsSHA256,
                currentTimestamp:
                    lifecycleVulnerabilityTimestamp(now)
            ) {
            return exception
        }
    }
    return nil
}

private func lifecycleVulnerabilityPolicyObject(
    _ policy: ImageVulnerabilityPolicy
) -> [String: Any] {
    [
        "version": policy.version,
        "severityThreshold":
            policy.severityThreshold.rawValue,
        "minimumVulnerabilityAgeSeconds":
            policy.minimumVulnerabilityAgeSeconds,
        "exploitability": policy.exploitability.rawValue,
        "fixAvailability":
            policy.fixAvailability.rawValue,
        "maximumDatabaseAgeSeconds":
            policy.maximumDatabaseAgeSeconds,
        "staleAction": policy.staleAction.rawValue,
        "unavailableAction":
            policy.unavailableAction.rawValue,
        "exceptionApproval":
            policy.exceptionApproval.rawValue,
        "allowlist": policy.allowlist.map {
            [
                "vulnerabilityID": $0.vulnerabilityID,
                "packagePURL": $0.packagePURL ?? NSNull(),
                "reason": $0.reason,
                "expiresAt": $0.expiresAt
            ] as [String: Any]
        }
    ]
}

private func lifecycleVulnerabilityPolicy(
    from object: [String: Any]
) throws -> ImageVulnerabilityPolicy {
    guard Set(object.keys) == [
        "version", "severityThreshold",
        "minimumVulnerabilityAgeSeconds", "exploitability",
        "fixAvailability", "maximumDatabaseAgeSeconds",
        "staleAction", "unavailableAction",
        "exceptionApproval", "allowlist"
    ],
    let version = object["version"] as? Int,
    let severityRaw = object["severityThreshold"] as? String,
    let severity =
        ImageVulnerabilitySeverity(rawValue: severityRaw),
    let minimumAge =
        object["minimumVulnerabilityAgeSeconds"] as? Int,
    let exploitabilityRaw =
        object["exploitability"] as? String,
    let exploitability =
        ImageVulnerabilityExploitabilitySelector(
            rawValue: exploitabilityRaw
        ),
    let fixRaw = object["fixAvailability"] as? String,
    let fix = ImageVulnerabilityFixSelector(
        rawValue: fixRaw
    ),
    let maximumAge =
        object["maximumDatabaseAgeSeconds"] as? Int,
    let staleRaw = object["staleAction"] as? String,
    let stale = ImageVulnerabilityDataAction(
        rawValue: staleRaw
    ),
    let unavailableRaw =
        object["unavailableAction"] as? String,
    let unavailable = ImageVulnerabilityDataAction(
        rawValue: unavailableRaw
    ),
    let approvalRaw =
        object["exceptionApproval"] as? String,
    let approval =
        ImageVulnerabilityExceptionApprovalMode(
            rawValue: approvalRaw
        ),
    let rawAllowlist =
        object["allowlist"] as? [[String: Any]] else {
        throw ImageVulnerabilityError.invalidPolicy
    }
    let allowlist = try rawAllowlist.map { entry in
        guard Set(entry.keys) == [
            "vulnerabilityID", "packagePURL",
            "reason", "expiresAt"
        ],
        let vulnerabilityID =
            entry["vulnerabilityID"] as? String,
        entry["packagePURL"] is NSNull ||
            entry["packagePURL"] is String,
        let reason = entry["reason"] as? String,
        let expiresAt = entry["expiresAt"] as? String else {
            throw ImageVulnerabilityError.invalidPolicy
        }
        return try ImageVulnerabilityAllowlistEntry(
            vulnerabilityID: vulnerabilityID,
            packagePURL: entry["packagePURL"] as? String,
            reason: reason,
            expiresAt: expiresAt
        )
    }
    return try ImageVulnerabilityPolicy(
        version: version,
        severityThreshold: severity,
        minimumVulnerabilityAgeSeconds: minimumAge,
        exploitability: exploitability,
        fixAvailability: fix,
        maximumDatabaseAgeSeconds: maximumAge,
        staleAction: stale,
        unavailableAction: unavailable,
        exceptionApproval: approval,
        allowlist: allowlist
    )
}

private func lifecycleVulnerabilityTimestamp(
    _ date: Date
) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [
        .withInternetDateTime,
        .withFractionalSeconds
    ]
    return formatter.string(from: date)
}

private func lifecycleVerifiedSBOMFormats(
    records: [ImageSBOMRecord],
    descriptorDigest: String,
    store: SQLiteStateStore
) throws -> Set<String> {
    var verified = Set<String>()
    for record in records.reversed() {
        guard let discovery = try store.ociReferrers
            .loadDiscovery(id: record.evidenceDiscoveryID),
            discovery.complete,
            discovery.subjectDigest == descriptorDigest,
            discovery.graphSHA256 ==
                record.evidenceGraphSHA256,
            let graph = try store.ociReferrers.loadGraph(
                discoveryID: record.evidenceDiscoveryID
            ),
            let format = ImageSBOMFormat(
                rawValue: record.format.rawValue
            ),
            let evidence = try? ImageSBOMEvidenceExtractor.extract(
                from: graph,
                expectedSubjectDigest:
                    OCIContentDigest(descriptorDigest),
                allowedFormats: [format]
            ),
            evidence.contains(where: {
                $0.document.documentDigest.canonicalValue ==
                    record.documentDigest &&
                $0.rootDescriptor.digest.canonicalValue ==
                    record.sbomReferrerDigest &&
                $0.document.components.count ==
                    record.componentCount &&
                $0.document.normalizedComponentsSHA256 ==
                    record.normalizedComponentsSHA256 &&
                $0.provenanceDescriptorDigest?.canonicalValue ==
                    record.provenanceDescriptorDigest &&
                $0.provenanceReferrerDigest?.canonicalValue ==
                    record.provenanceReferrerDigest
            }) else {
            continue
        }
        verified.insert(record.format.rawValue)
    }
    return verified
}

private func lifecycleCurrentProvenanceRecord(
    records: [ImageProvenanceRecord],
    descriptorDigest: String,
    policy: ImageProvenancePolicy,
    material: ImageProvenancePolicyMaterial,
    store: SQLiteStateStore,
    at date: Date
) throws -> ImageProvenanceRecord? {
    let expectedDigest = try OCIContentDigest(descriptorDigest)
    for record in records.reversed() {
        guard record.descriptorDigest == descriptorDigest,
              record.policySHA256 == material.policySHA256,
              record.verifierVersion ==
                ImageProvenanceVerification.verifierVersion,
              let discovery =
                try store.ociReferrers.loadDiscovery(
                    id: record.evidenceDiscoveryID
                ),
              discovery.complete,
              discovery.subjectDigest == descriptorDigest,
              discovery.graphSHA256 ==
                record.evidenceGraphSHA256,
              let graph = try store.ociReferrers.loadGraph(
                  discoveryID: record.evidenceDiscoveryID
              ),
              graph.discovery.subjectDigest == expectedDigest,
              let evidence =
                try? ImageProvenanceEvidenceExtractor.extract(
                    from: graph,
                    expectedSubjectDigest: expectedDigest
                ).first(where: {
                    $0.referrerDigest.canonicalValue ==
                        record.referrerDigest &&
                        $0.envelopeDescriptor.digest
                            .canonicalValue ==
                        record.envelopeDigest
                }),
              let verification =
                try? ImageProvenanceVerifier.verify(
                    envelopePayload: evidence.envelopePayload,
                    expectedSubjectDigest: expectedDigest,
                    policy: policy,
                    material: material,
                    at: date
                ),
              lifecycleProvenanceRecord(
                  record,
                  exactlyMatches: verification,
                  referrerDigest:
                    evidence.referrerDigest.canonicalValue
              ) else {
            continue
        }
        return record
    }
    return nil
}

private func lifecycleProvenanceRecord(
    _ record: ImageProvenanceRecord,
    exactlyMatches verification: ImageProvenanceVerification,
    referrerDigest: String
) -> Bool {
    let statement = verification.statement
    return record.descriptorDigest ==
        statement.subjectDigest.canonicalValue &&
        record.policySHA256 == verification.policySHA256 &&
        record.statementDigest ==
        statement.statementDigest.canonicalValue &&
        record.envelopeDigest ==
        verification.envelopeDigest.canonicalValue &&
        record.referrerDigest == referrerDigest &&
        record.sourceURI == statement.source.uri &&
        record.sourceDigest ==
        statement.source.digest.canonicalValue &&
        record.builderID == statement.builderID &&
        record.builderVersion == statement.builderVersion &&
        record.buildType == statement.buildType &&
        record.invocationID == statement.invocationID &&
        record.normalizedMaterialsSHA256 ==
        statement.normalizedMaterialsSHA256 &&
        record.commandSHA256 == statement.commandSHA256 &&
        record.environmentPolicySHA256 ==
        statement.environmentPolicySHA256 &&
        record.startedAt == statement.startedAt &&
        record.finishedAt == statement.finishedAt &&
        record.reproducibilityStatus ==
        statement.reproducibility.status &&
        record.comparisonDigest ==
        statement.reproducibility.comparisonDigest?
            .canonicalValue &&
        record.signerID == verification.signerID &&
        record.signerPublicKeySHA256 ==
        verification.signerPublicKeySHA256 &&
        record.signatureSHA256 ==
        verification.signatureSHA256
}

private func lifecycleProvenanceEvent(
    _ object: [String: Any],
    exactlyMatches record: ImageProvenanceRecord
) -> Bool {
    object["recordID"] as? String == record.id &&
        object["policySHA256"] as? String ==
        record.policySHA256 &&
        object["statementDigest"] as? String ==
        record.statementDigest &&
        object["envelopeDigest"] as? String ==
        record.envelopeDigest &&
        object["referrerDigest"] as? String ==
        record.referrerDigest &&
        object["discoveryID"] as? String ==
        record.evidenceDiscoveryID &&
        object["graphSHA256"] as? String ==
        record.evidenceGraphSHA256 &&
        object["signerID"] as? String ==
        record.signerID &&
        object["signerPublicKeySHA256"] as? String ==
        record.signerPublicKeySHA256 &&
        object["signatureSHA256"] as? String ==
        record.signatureSHA256
}

private func lifecycleProvenanceAuthorizationEvent(
    planSHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    serviceName: String,
    descriptorDigest: String,
    record: ImageProvenanceRecord
) throws -> EventRecord {
    let payload = try JSONSerialization.data(
        withJSONObject: [
            "planSHA256": planSHA256,
            "projectID": projectID,
            "serviceName": serviceName,
            "descriptorDigest": descriptorDigest,
            "policySHA256": record.policySHA256,
            "recordID": record.id,
            "statementDigest": record.statementDigest,
            "envelopeDigest": record.envelopeDigest,
            "referrerDigest": record.referrerDigest,
            "discoveryID": record.evidenceDiscoveryID,
            "graphSHA256": record.evidenceGraphSHA256,
            "signerID": record.signerID,
            "signerPublicKeySHA256":
                record.signerPublicKeySHA256,
            "signatureSHA256": record.signatureSHA256
        ],
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return EventRecord(
        id: UUID().uuidString.lowercased(),
        timestamp: hostwrightTimestamp(),
        severity: .info,
        type: "image.provenance.lifecycle.authorized",
        source: "hostwright.lifecycle",
        projectID: projectID,
        serviceName: serviceName,
        runtimeAdapter: providerID.rawValue,
        message:
            "Exact signed image provenance authorized lifecycle execution.",
        payloadJSONRedacted:
            String(decoding: payload, as: UTF8.self)
    )
}

private func lifecycleRecordTrustAuthorization(
    store: SQLiteStateStore,
    timestamp: String,
    planSHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    serviceName: String,
    descriptorDigest: String,
    policySHA256: String,
    authorization: String,
    verification: ImageTrustVerificationRecord?,
    exception: ImageTrustExceptionRecord?
) throws {
    try store.events.append([
        try lifecycleTrustAuthorizationEvent(
            timestamp: timestamp,
            planSHA256: planSHA256,
            projectID: projectID,
            providerID: providerID,
            serviceName: serviceName,
            descriptorDigest: descriptorDigest,
            policySHA256: policySHA256,
            authorization: authorization,
            verification: verification,
            exception: exception
        )
    ])
}

private func lifecycleTrustAuthorizationEvent(
    timestamp: String,
    planSHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    serviceName: String,
    descriptorDigest: String,
    policySHA256: String,
    authorization: String,
    verification: ImageTrustVerificationRecord?,
    exception: ImageTrustExceptionRecord?
) throws -> EventRecord {
    var object: [String: Any] = [
        "decision": authorization,
        "planSHA256": planSHA256,
        "projectID": projectID,
        "serviceName": serviceName,
        "descriptorDigest": descriptorDigest,
        "policySHA256": policySHA256
    ]
    if let verification {
        object["verification"] = [
            "createdAt": verification.createdAt,
            "discoveryID": verification.evidenceDiscoveryID,
            "graphSHA256": verification.evidenceGraphSHA256,
            "trustedRootSHA256":
                verification.trustedRootSHA256
        ]
    }
    if let exception {
        object["exceptionID"] = exception.id
    }
    let payload = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return EventRecord(
        id: UUID().uuidString.lowercased(),
        timestamp: timestamp,
        severity: authorization == "exception"
            ? .warning : .info,
        type: "image.trust.lifecycle.authorized",
        source: "hostwright.lifecycle",
        projectID: projectID,
        serviceName: serviceName,
        runtimeAdapter: providerID.rawValue,
        message:
            "Exact image trust evidence authorized lifecycle execution.",
        payloadJSONRedacted: String(decoding: payload, as: UTF8.self)
    )
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
        imageLock: service.imageLock,
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
        publishedSockets: service.publishedSockets,
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

func lifecycleSecretWorkloadScope(
    projectResourceUUID: String,
    resourceUUID: String,
    generation: Int,
    serviceName: String
) throws -> HostwrightSecretWorkloadScope {
    guard let projectID = UUID(uuidString: projectResourceUUID),
          let resourceID = UUID(uuidString: resourceUUID) else {
        throw SecretStoreError.invalidReference(
            "Secret workload scope requires exact Hostwright resource identities."
        )
    }
    return try HostwrightSecretWorkloadScope(
        projectID: projectID,
        resourceID: resourceID,
        generation: generation,
        serviceName: serviceName
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
            "compiler-v2",
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

func lifecycleManifestSHA256(
    text: String,
    manifest: HostwrightManifest
) throws -> String {
    var bound = text
    if manifest.imageTrust != nil {
        let material = try ImageTrustPolicyMapping.map(
            manifest
        ).material
        bound += "\u{1f}imageTrustPolicySHA256=" +
            material.policySHA256
    }
    if manifest.imageSBOM != nil {
        let material = try ImageSBOMPolicyMapping.map(manifest)
        bound += "\u{1f}imageSBOMPolicySHA256=" +
            material.policySHA256
    }
    if manifest.imageVulnerability != nil {
        let material =
            try ImageVulnerabilityPolicyMapping.map(manifest)
        bound += "\u{1f}imageVulnerabilityPolicySHA256=" +
            material.policySHA256
    }
    if manifest.imageProvenance != nil {
        let material =
            try ImageProvenancePolicyMapping.map(manifest).material
        bound += "\u{1f}imageProvenancePolicySHA256=" +
            material.policySHA256
    }
    return sha256(bound)
}

private func lifecycleSHA256(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}
