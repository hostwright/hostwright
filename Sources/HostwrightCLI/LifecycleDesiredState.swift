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

func lifecycleHealthyDesiredState(
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
              lifecycleTextSHA256(metadata.desiredSpecificationJSONRedacted) ==
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

func lifecycleNextResourceGenerations(
    store: SQLiteStateStore, projectID: String, projectUUID: String,
    providerID: RuntimeProviderID, desiredState: DesiredRuntimeState,
    bindings: [LifecycleResourceBinding]
) throws -> [String: Int] {
    let bound = Dictionary(bindings.map { ($0.identity, $0.resourceUUID) }, uniquingKeysWith: { first, _ in first })
    let resources = Dictionary(uniqueKeysWithValues: desiredState.services.map {
        ($0.identity.displayName, bound[$0.identity] ?? HostwrightResourceUUID.legacy(
            kind: "service", identifier: "\(projectID):\($0.identity.displayName)"
        ))
    })
    guard !resources.isEmpty else { return [:] }
    var generations: [String: Int] = [:]
    try store.operationGroups.visitProjectLifecycleHistory(projectID: projectID) { group in
        let plan = try LifecyclePersistedIntentCodec.decode(group.intentJSONRedacted)
        guard plan.planSHA256 == group.planHash else {
            throw StateStoreError.invalidRecord("Lifecycle generation history has an invalid plan digest.")
        }
        guard plan.projectResourceUUID == projectUUID,
              plan.providerID == providerID else { return }
        for node in plan.nodes {
            let resourceUUID: String?
            if node.desiredSpecificationJSONRedacted != "{}" {
                let desired = try LifecycleRevisionCodec.decodeRedactedDesiredJSON(
                    node.desiredSpecificationJSONRedacted
                )
                guard desired.identity.projectName == desiredState.projectName,
                      node.serviceName == desired.identity.displayName ||
                        node.serviceName == desired.logicalServiceName else {
                    throw StateStoreError.invalidRecord("Lifecycle generation history has an inconsistent service identity.")
                }
                resourceUUID = resources[desired.identity.displayName]
            } else {
                resourceUUID = resources.values.first { $0 == node.resourceUUID }
            }
            guard let resourceUUID else { continue }
            guard node.resourceGeneration < Int.max else {
                throw StateStoreError.invalidRecord("Lifecycle resource generation is exhausted.")
            }
            generations[resourceUUID] = max(generations[resourceUUID] ?? 1, node.resourceGeneration + 1)
        }
    }
    return generations
}

func lifecycleBindings(
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

func currentProjectResourceUUID(
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

func currentProviderGeneration(
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

func manifestBaseDirectory(for manifestPath: String) -> String {
    let url = URL(fileURLWithPath: manifestPath).standardizedFileURL
    let parent = url.deletingLastPathComponent()
    return parent.path.isEmpty ? FileManager.default.currentDirectoryPath : parent.path
}

func lifecyclePreflightDesiredExecution(
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
    if let profileID = options.workloadProfileID,
       let expectedSHA256 = options.workloadProfileSHA256 {
        let profileEngine = WorkloadProfilePolicyEngine(repository: store.workloadProfiles)
        let resolution: WorkloadProfileResolution
        do {
            resolution = try profileEngine.resolve(id: profileID)
            guard resolution.profileSHA256 == expectedSHA256 else {
                throw WorkloadProfilePolicyError.workloadViolation(["profileHash"])
            }
            for service in manifest.services {
                try profileEngine.validateManifestAdmission(
                    resources: service.resources,
                    scheduling: service.scheduling,
                    resolution: resolution
                )
            }
            for service in preparation.desiredState.services {
                try profileEngine.validateWorkload(
                    service, resolution: resolution, snapshot: capability)
            }
            try ManifestSchedulerAdmissionBridge.admit(
                manifest: manifest,
                subjectID: "owner",
                profileResolution: resolution
            )
        } catch let error as ManifestSchedulerAdmissionError {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Scheduler admission failed: \(error.stableKey). No runtime mutation was attempted."
            )
        } catch WorkloadProfilePolicyError.providerMismatch(let provider) {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Workload profile provider mismatch: \(provider). No runtime mutation was attempted."
            )
        } catch WorkloadProfilePolicyError.unsupportedCapabilities(let reasons) {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Workload profile provider capability gaps: \(reasons.joined(separator: ",")). No runtime mutation was attempted."
            )
        } catch WorkloadProfilePolicyError.workloadViolation(let reasons) {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Workload profile violations: \(reasons.joined(separator: ",")). No runtime mutation was attempted."
            )
        } catch {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "The selected workload profile cannot be enforced exactly by the desired workload and runtime provider. No runtime mutation was attempted."
            )
        }
    } else {
        do {
            try ManifestSchedulerAdmissionBridge.admit(
                manifest: manifest,
                subjectID: "owner"
            )
        } catch let error as ManifestSchedulerAdmissionError {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Scheduler admission failed: \(error.stableKey). No runtime mutation was attempted."
            )
        }
    }
    if preparation.desiredState.services.contains(where: {
        !$0.hostAccess.isEmpty
    }) {
        let networkProvider =
            try environment.networkProviderForProvider(
                preparation.providerID
            )
        let networkCapabilities = try hostwrightWaitForAsync {
            try await networkProvider.networkCapabilities()
        }
        try lifecyclePreflightHostAccessCapabilities(
            services: preparation.desiredState.services,
            providerID: preparation.providerID,
            capabilities: networkCapabilities
        )
    }
    if preparation.desiredState.services.contains(where: {
        $0.networkPolicy != nil
    }) {
        let networkProvider =
            try environment.networkProviderForProvider(
                preparation.providerID
            )
        let networkCapabilities = try hostwrightWaitForAsync {
            try await networkProvider.networkCapabilities()
        }
        try lifecyclePreflightNetworkPolicyCapabilities(
            services: preparation.desiredState.services,
            providerID: preparation.providerID,
            capabilities: networkCapabilities
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

func lifecyclePreflightNetworkPolicyCapabilities(
    services: [DesiredRuntimeService],
    providerID: RuntimeProviderID,
    capabilities: RuntimeNetworkProviderCapabilities
) throws {
    let declared = services.compactMap(\.networkPolicy)
    guard !declared.isEmpty else { return }
    guard capabilities.providerID == providerID,
          let policy = capabilities.networkPolicy,
          policy.state == .available,
          policy.reason == .implemented,
          Set(policy.directions) ==
            Set(HostwrightNetworkPolicyDirection.allCases),
          policy.enforcesExactIdentity,
          policy.appliesAtomicGenerations,
          policy.observesRuleDigest else {
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "The selected runtime provider does not qualify exact ingress and egress network-policy enforcement with atomic observable generations. No runtime mutation was attempted."
        )
    }
    let rules = declared.flatMap { $0.ingress + $0.egress }
    if rules.contains(where: { $0.address != nil }),
       !policy.enforcesCIDR {
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "The selected runtime provider does not qualify exact CIDR network-policy enforcement. No runtime mutation was attempted."
        )
    }
    if rules.contains(where: { $0.dns != nil }),
       !policy.enforcesDNS {
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "The selected runtime provider does not qualify DNS-aware network-policy enforcement. No runtime mutation was attempted."
        )
    }
}

func lifecyclePreflightHostAccessCapabilities(
    services: [DesiredRuntimeService],
    providerID: RuntimeProviderID,
    capabilities: RuntimeNetworkProviderCapabilities
) throws {
    let declared = services.filter { !$0.hostAccess.isEmpty }
    guard !declared.isEmpty else { return }
    guard capabilities.providerID == providerID,
          let hostAccess = capabilities.hostAccess,
          hostAccess.state == .available,
          hostAccess.reason == .implemented,
          hostAccess.requiresManagedProjectNetwork,
          hostAccess.enforcesExactEndpointAllowlist else {
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "The selected runtime provider does not qualify guarded host access with exact endpoint enforcement. No runtime mutation was attempted."
        )
    }
    let protocols = Set(hostAccess.protocols)
    let addressClasses = Set(hostAccess.addressClasses)
    guard declared.allSatisfy({ service in
        service.networks.count == 1 &&
            service.hostAccess.allSatisfy {
                protocols.contains($0.protocolName) &&
                    addressClasses.contains($0.addressClass)
            }
    }) else {
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "Guarded host access requires one managed project network and provider-qualified endpoint protocol and address classes. No runtime mutation was attempted."
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

let lifecycleWorkloadProfileIDLabel = "dev.hostwright.workload-profile-id"
let lifecycleWorkloadProfileHashLabel = "dev.hostwright.workload-profile-sha256"

func lifecycleProfiledServices(
    _ services: [DesiredRuntimeService],
    previous: [DesiredRuntimeService],
    options: LifecycleCLIOptions,
    store: SQLiteStateStore
) throws -> [DesiredRuntimeService] {
    let reserved = [lifecycleWorkloadProfileIDLabel, lifecycleWorkloadProfileHashLabel]
    guard services.allSatisfy({ service in reserved.allSatisfy { service.labels[$0] == nil } }) else {
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "Manifest labels cannot use Hostwright workload-profile binding keys. No runtime mutation was attempted."
        )
    }
    let activeMutation = ![LifecycleCommandKind.down, .stop, .rm].contains(options.command)
    guard previous.allSatisfy({ service in
        (service.labels[lifecycleWorkloadProfileIDLabel] == nil)
            == (service.labels[lifecycleWorkloadProfileHashLabel] == nil)
    }) else {
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "The previously applied workload has an incomplete profile binding. No runtime mutation was attempted."
        )
    }
    let previousBindings = previous.compactMap { service -> (String, String)? in
        guard let identifier = service.labels[lifecycleWorkloadProfileIDLabel],
              let digest = service.labels[lifecycleWorkloadProfileHashLabel] else { return nil }
        return (identifier, digest)
    }
    guard previousBindings.isEmpty || previousBindings.count == previous.count,
          Set(previousBindings.map { "\($0.0)\u{0}\($0.1)" }).count <= 1 else {
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "The previously applied workload has mixed profile authority. No runtime mutation was attempted."
        )
    }
    guard let profileID = options.workloadProfileID,
          let suppliedSHA256 = options.workloadProfileSHA256 else {
        if activeMutation && !previousBindings.isEmpty {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "A previously profiled workload cannot be restarted or updated without its exact workload profile. No runtime mutation was attempted."
            )
        }
        return services
    }
    let engine = WorkloadProfilePolicyEngine(repository: store.workloadProfiles)
    let selected = try engine.resolve(id: profileID)
    guard selected.profileSHA256 == suppliedSHA256 else {
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "The workload profile changed after admission. No runtime mutation was attempted."
        )
    }
    for (priorID, priorSHA256) in previousBindings where priorSHA256 != selected.profileSHA256 {
        let prior = try engine.resolve(id: priorID)
        guard prior.profileSHA256 == priorSHA256 else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "The previously applied workload profile has drifted from canonical state. No runtime mutation was attempted."
            )
        }
        let weakening = WorkloadProfilePolicyEngine.weakeningReasons(
            candidate: selected.profile, base: prior.profile)
        guard weakening.isEmpty else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "The selected workload profile would weaken the applied profile at: \(weakening.joined(separator: ",")). No runtime mutation was attempted."
            )
        }
    }
    return services.map { service in
        var labels = service.labels
        labels[lifecycleWorkloadProfileIDLabel] = profileID
        labels[lifecycleWorkloadProfileHashLabel] = selected.profileSHA256
        return lifecycleReplacingEnvironment(
            in: service, with: service.environment, labels: labels)
    }
}

func lifecycleReplacingEnvironment(
    in service: DesiredRuntimeService,
    with environment: [RuntimeEnvironmentValue],
    labels: [String: String]? = nil
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
        labels: labels ?? service.labels,
        ports: service.ports,
        publishedSockets: service.publishedSockets,
        hostAccess: service.hostAccess,
        networkPolicy: service.networkPolicy,
        networks: service.networks,
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

func lifecycleUnmanagedIdentifiers(
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

func lifecycleHookStepKey(_ nodeKey: String) -> String {
    "hook-\(lifecycleTextSHA256(nodeKey))"
}

func lifecycleCompletionStepKey(_ nodeKey: String) -> String {
    "completion-\(lifecycleTextSHA256(nodeKey))"
}

func lifecycleEpochMilliseconds(_ timestamp: String) -> Int64? {
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

func lifecycleTextSHA256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

func lifecycleManifestSHA256(
    text: String,
    manifest: HostwrightManifest
) throws -> String {
    try HostwrightLifecycleManifestDigest.sha256(text: text, manifest: manifest)
}

public enum HostwrightLifecycleManifestDigest {
    public static func sha256(text: String, manifest: HostwrightManifest) throws -> String {
        var bound = text
        if manifest.imageTrust != nil {
            let material = try ImageTrustPolicyMapping.map(manifest).material
            bound += "\u{1f}imageTrustPolicySHA256=" + material.policySHA256
        }
        if manifest.imageSBOM != nil {
            let material = try ImageSBOMPolicyMapping.map(manifest)
            bound += "\u{1f}imageSBOMPolicySHA256=" + material.policySHA256
        }
        if manifest.imageVulnerability != nil {
            let material = try ImageVulnerabilityPolicyMapping.map(manifest)
            bound += "\u{1f}imageVulnerabilityPolicySHA256=" + material.policySHA256
        }
        if manifest.imageProvenance != nil {
            let material = try ImageProvenancePolicyMapping.map(manifest).material
            bound += "\u{1f}imageProvenancePolicySHA256=" + material.policySHA256
        }
        return SHA256.hash(data: Data(bound.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

func lifecycleSHA256(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}
