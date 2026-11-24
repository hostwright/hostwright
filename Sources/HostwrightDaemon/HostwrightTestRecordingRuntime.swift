#if HOSTWRIGHT_TEST_RUNTIME
import Darwin
import Foundation
import HostwrightCore
import HostwrightDaemonCore
import HostwrightReconciler
import HostwrightRuntime

actor HostwrightTestRecordingRuntime: RuntimeAdapter {
    struct Action: Codable, Equatable, Sendable {
        let kind: String
        let service: String
        let resource: String
    }

    private struct Resource: Codable {
        let project: String
        let service: String
        let instance: String?
        let image: String
        var lifecycle: RuntimeInventoryLifecycleState
        var ownership: RuntimeInventoryOwnershipEvidence?

        var identity: RuntimeServiceIdentity {
            RuntimeServiceIdentity(projectName: project, serviceName: service, instanceName: instance)
        }
    }

    private struct State: Codable {
        var resources: [String: Resource] = [:]
        var actions: [Action] = []
    }

    static let providerID = RuntimeProviderID(rawValue: "hostwright-test-recording-v1")
    static let lifecycleBinding = RuntimeProviderID.appleContainerCLI
    static let stateFile = "recording-runtime.json"
    private static let maximumStateBytes = 8 * 1_024 * 1_024
    private static let runtimeCapabilities: [RuntimeCapability] = [.readOnlyObservation, .lifecycleMutation]
    private let homeDirectory: URL
    private let bindingID: RuntimeProviderID

    init(homeDirectory: URL, useLifecycleBinding: Bool = false) {
        self.homeDirectory = homeDirectory
        // The isolated daemon uses the same stable storage binding as the lifecycle adapter fixtures.
        self.bindingID = useLifecycleBinding ? Self.lifecycleBinding : Self.providerID
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: bindingID,
            adapterName: "HostwrightTestRecordingRuntime",
            adapterVersion: "1",
            runtimeName: Self.providerID.rawValue,
            runtimeVersion: "1.1.0",
            supportsMutation: true,
            capabilities: Self.runtimeCapabilities
        )
    }

    func capabilities() async throws -> [RuntimeCapability] {
        Self.runtimeCapabilities
    }

    func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        snapshot
    }

    private var snapshot: RuntimeCapabilitySnapshot {
        let supportedFeatures: Set<RuntimeProviderFeature> = [.observation, .lifecycle, .cleanup]
        return RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: bindingID,
                components: [
                    RuntimeProviderComponent(identifier: .appleContainerCLI, version: "1.1.0", build: "109", fingerprint: "099d8db0"),
                    RuntimeProviderComponent(identifier: .appleContainerAPIService, version: "1.1.0", build: "109", fingerprint: "099d8db0")
                ],
                minimumMacOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
                macOSBuild: "25F90",
                architecture: .arm64
            ),
            features: RuntimeProviderFeature.knownValues.map { feature in
                let supported = supportedFeatures.contains(feature)
                return RuntimeProviderFeatureStatus(
                    feature: feature,
                    state: supported ? .available : .unavailable,
                    reason: supported ? .implemented : .notImplemented
                )
            }
        )
    }

    func inventory() async throws -> RuntimeInventory {
        let containers = try load().resources.map { identifier, resource in
            let labels: [RuntimeInventoryLabel]
            if let owner = resource.ownership {
                let context = RuntimeMutationContext(
                    providerID: owner.providerID,
                    capabilitySHA256: snapshot.canonicalSHA256,
                    operationID: "recorded-inventory",
                    resourceUUID: owner.resourceUUID,
                    resourceGeneration: owner.resourceGeneration,
                    projectResourceUUID: owner.projectUUID,
                    projectGeneration: owner.projectGeneration,
                    providerGeneration: owner.providerGeneration,
                    fencingToken: owner.fencingToken
                )
                labels = try RuntimeManagedResourceIdentity.labels(
                    for: resource.identity,
                    resourceIdentifier: identifier,
                    context: context
                ).map { RuntimeInventoryLabel(key: $0.key, value: $0.value) }
            } else {
                labels = []
            }
            return RuntimeInventoryContainer(
                runtimeID: identifier,
                name: identifier,
                imageReference: resource.image,
                lifecycle: resource.lifecycle,
                health: RuntimeInventoryHealth(availability: .notConfigured),
                labels: labels,
                ownership: resource.ownership,
                initConfiguration: RuntimeInventoryInitConfiguration(executable: "rehearsal", arguments: [], environment: []),
                ports: [],
                mounts: [],
                networks: [],
                services: []
            )
        }
        return try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macos",
                architecture: "arm64",
                runtimeVersion: "1.1.0",
                services: [RuntimeInventoryService(identifier: "recording-runtime", state: .running, required: true)]
            ),
            containers: containers,
            images: [],
            networks: [],
            volumes: []
        )
    }

    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        let services = try load().resources.sorted(by: { $0.key < $1.key }).compactMap { identifier, resource in
            guard resource.project == desiredState.projectName else { return nil as ObservedRuntimeService? }
            return ObservedRuntimeService(
                identity: resource.identity,
                resourceIdentifier: identifier,
                image: resource.image,
                lifecycleState: RuntimeLifecycleState(rawValue: resource.lifecycle.rawValue) ?? .unknown,
                healthState: .notConfigured,
                ownership: resource.ownership
            )
        }
        return ObservedRuntimeState(
            projectName: desiredState.projectName,
            services: services,
            adapterMetadata: await metadata(),
            capabilitySHA256: snapshot.canonicalSHA256
        )
    }

    func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
        ReconciliationPlanner().plan(desired: desiredState, observed: observedState)
    }

    func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        throw RuntimeAdapterError.capabilityUnavailable(.logStreaming)
    }

    func runtimeVersion() async throws -> String { "1.1.0" }

    func localImageEvidence(for imageReference: String) async throws -> RuntimeLocalImageEvidence {
        guard let digest = imageReference.split(separator: "@").last,
              digest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil,
              imageReference.contains("@") else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "The recording runtime requires a digest-pinned image."
            )
        }
        return RuntimeLocalImageEvidence(
            reference: imageReference,
            descriptorDigest: String(digest),
            variantDigest: String(digest),
            architecture: "arm64",
            operatingSystem: "linux"
        )
    }

    func recordedActions() throws -> [Action] { try load().actions }

    func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        let event = RuntimeEvent(
            identity: action.identity,
            message: "Recorded rehearsal action",
            resourceIdentifier: action.resourceIdentifier
        )
        guard action.kind != .noOp else { return event }
        guard confirmation?.confirmed == true else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy("Recording runtime mutation requires confirmation.")
        }
        let context = confirmation?.context
        if bindingID == Self.lifecycleBinding {
            guard let context, context.validationIssue == nil,
                  context.providerID == bindingID, context.capabilitySHA256 == snapshot.canonicalSHA256 else {
                throw RuntimeAdapterError.mutationUnavailableByPolicy(
                    "Recording runtime lifecycle mutation requires the exact provider context."
                )
            }
        }

        var state = try load()
        let identifier = action.resourceIdentifier
        let previous = state.resources[identifier]
        let ownership = context.map {
            RuntimeInventoryOwnershipEvidence(
                resourceUUID: $0.resourceUUID,
                projectUUID: $0.projectResourceUUID,
                resourceGeneration: $0.resourceGeneration,
                projectGeneration: $0.projectGeneration,
                providerID: $0.providerID,
                providerGeneration: $0.providerGeneration,
                fencingToken: $0.fencingToken
            )
        }
        if let previous {
            guard previous.identity == action.identity,
                  Self.ownsSameResource(previous.ownership, ownership) else {
                throw RuntimeAdapterError.mutationUnavailableByPolicy(
                    "The recorded resource does not match the mutation ownership."
                )
            }
        }
        switch action.kind {
        case .create:
            guard previous == nil else { return event }
            state.resources[identifier] = try Self.resource(action, lifecycle: .created, ownership: ownership)
        case .update:
            guard let previous else { throw Self.missingResource }
            state.resources[identifier] = try Self.resource(action, lifecycle: previous.lifecycle, ownership: ownership)
        case .start, .restart, .stop:
            guard var previous else { throw Self.missingResource }
            let next: RuntimeInventoryLifecycleState = action.kind == .stop ? .stopped : .running
            if action.kind != .restart, previous.lifecycle == next { return event }
            previous.lifecycle = next
            previous.ownership = ownership
            state.resources[identifier] = previous
        case .remove:
            guard previous != nil else { return event }
            state.resources.removeValue(forKey: identifier)
        case .noOp:
            return event
        }
        state.actions.append(Action(kind: action.kind.rawValue, service: action.identity.serviceName, resource: identifier))
        try RuntimeActivationAuthority.validate()
        try save(state)
        return event
    }

    private static let missingResource = RuntimeAdapterError.outputParseFailed("The recorded resource is absent.")

    private static func ownsSameResource(
        _ previous: RuntimeInventoryOwnershipEvidence?,
        _ next: RuntimeInventoryOwnershipEvidence?
    ) -> Bool {
        switch (previous, next) {
        case (nil, nil):
            return true
        case let (previous?, next?):
            return previous.resourceUUID == next.resourceUUID &&
                previous.projectUUID == next.projectUUID &&
                previous.resourceGeneration == next.resourceGeneration &&
                previous.providerID == next.providerID &&
                previous.providerGeneration == next.providerGeneration &&
                previous.projectGeneration <= next.projectGeneration
        default:
            return false
        }
    }

    private static func resource(
        _ action: PlannedRuntimeAction,
        lifecycle: RuntimeInventoryLifecycleState,
        ownership: RuntimeInventoryOwnershipEvidence?
    ) throws -> Resource {
        guard let desired = action.desiredService, desired.identity == action.identity else {
            throw RuntimeAdapterError.outputParseFailed("The recording action lacks the exact desired service.")
        }
        return Resource(
            project: action.identity.projectName,
            service: action.identity.serviceName,
            instance: action.identity.instanceName,
            image: desired.image,
            lifecycle: lifecycle,
            ownership: ownership
        )
    }

    private var stateURL: URL { homeDirectory.appendingPathComponent(Self.stateFile) }

    private func load() throws -> State {
        let descriptor = open(stateURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return State() }
            throw DaemonError.invalidConfiguration("The recording runtime state file cannot be opened safely.")
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              metadata.st_size > 0, metadata.st_size <= Self.maximumStateBytes,
              let data = try file.read(upToCount: Self.maximumStateBytes + 1),
              data.count == Int(metadata.st_size) else {
            throw DaemonError.invalidConfiguration("The recording runtime state file is unsafe.")
        }
        return try JSONDecoder().decode(State.self, from: data)
    }

    private func save(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumStateBytes else {
            throw DaemonError.invalidConfiguration("The recording runtime state size limit was reached.")
        }
        try data.write(to: stateURL, options: .atomic)
    }
}
#endif
