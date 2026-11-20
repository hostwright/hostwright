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

let lifecycleSchedulerAuthorityUnavailableMessage =
    "scheduler-authority-unavailable: lifecycle mutation requires a persisted Control 2.2 scheduler placement decision and fenced reservation; manifest-only admission is not executable. No runtime mutation was attempted."

private func requireLifecycleSchedulerAuthority(
    for options: LifecycleCLIOptions
) throws {
    guard !options.dryRun,
          [.up, .run, .start, .restart, .update].contains(options.command) else {
        return
    }
    throw RuntimeAdapterError.mutationUnavailableByPolicy(
        lifecycleSchedulerAuthorityUnavailableMessage
    )
}

typealias LifecycleSchedulerAuthorityValidator = @Sendable (
    HostwrightManifest,
    LifecycleCompiledCommand,
    LifecycleCommandPreparation,
    LifecycleCLIOptions
) throws -> Void

func defaultLifecycleSchedulerAuthorityValidator(
    _: HostwrightManifest,
    _: LifecycleCompiledCommand,
    _: LifecycleCommandPreparation,
    options: LifecycleCLIOptions
) throws {
    try requireLifecycleSchedulerAuthority(for: options)
}

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
    let schedulerAuthorityValidator: LifecycleSchedulerAuthorityValidator
    let hasExplicitSchedulerAuthorityValidator: Bool

    init(
        environment: CLIEnvironment,
        options: LifecycleCLIOptions,
        schedulerAuthorityValidator: LifecycleSchedulerAuthorityValidator? = nil
    ) {
        self.environment = environment
        self.options = options
        self.schedulerAuthorityValidator = schedulerAuthorityValidator ?? defaultLifecycleSchedulerAuthorityValidator
        hasExplicitSchedulerAuthorityValidator = schedulerAuthorityValidator != nil
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
        _ = try ManifestSchedulerAdmissionBridge.admit(
            manifest: manifest,
            subjectID: "owner"
        )
        let store = SQLiteStateStore(
            configuration: try hostwrightStateStoreConfiguration(
                explicitPath: options.stateDatabasePath,
                environment: environment
            )
        )
        try store.migrate()
        HostwrightTraceContext.session?.attach(StateTraceSink(store: store))

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
                ),
            schedulerAdmissionValidated: true
        )
        try ServiceTunnelLifecycleCoordinator
            .validateLiveCredentialPrerequisites(
                mapping.tunnelDeclarations
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
                    ),
                schedulerAdmissionValidated: true
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
        let exposureEnvironment = try NetworkHostEnvironmentProbe.current()
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
                allowReleasingForRemoval: options.command == .rm,
                isAvailable:
                    NetworkPortSocketAvailability.isAvailable,
                isExposureAvailable: { endpoint, policy in
                    try NetworkPortSocketAvailability.isAvailable(
                        endpoint,
                        exposurePolicy: policy,
                        environment: exposureEnvironment
                    )
                }
            )
        let desiredState = DesiredRuntimeState(
            projectName: plannedDesiredState.projectName,
            networks: plannedDesiredState.networks,
            services: try lifecycleProfiledServices(
                plannedDesiredState.services,
                previous: previousDesiredState?.services ?? [],
                options: options,
                store: store
            ),
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
            certificates: mapping.certificates,
            ingress: mapping.ingress,
            tunnelDeclarations: mapping.tunnelDeclarations,
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
            nextResourceGenerations: try lifecycleNextResourceGenerations(
                store: store, projectID: projectID, projectUUID: projectResourceUUID,
                providerID: providerID, desiredState: desiredState, bindings: resourceBindings
            ),
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
}

func lifecycleRequiresProjectNetworkProvisioning(
    _ command: LifecycleCommand
) -> Bool {
    switch command {
    case .up, .run, .start, .restart, .update, .apply:
        true
    case .down, .stop, .remove, .resume, .rollback:
        false
    }
}

func lifecycleRequiresProjectDNSProvisioning(
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

func lifecycleRequiresNamedVolumeProvisioning(
    _ command: LifecycleCommand
) -> Bool {
    switch command {
    case .up, .run, .start, .restart, .update, .apply:
        true
    case .down, .stop, .remove, .resume, .rollback:
        false
    }
}

func lifecycleRequiresNamedVolumeDetach(
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
