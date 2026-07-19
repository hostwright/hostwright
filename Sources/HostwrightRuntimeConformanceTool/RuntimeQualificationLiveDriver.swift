import CryptoKit
import Foundation
import HostwrightCore
import HostwrightRuntime

enum RuntimeQualificationLiveDriverError: Error, Equatable {
    case preflightFailed
    case versionMismatch
    case capabilityMismatch
    case imageMismatch
    case ownershipMismatch
    case lifecycleMismatch
    case boundaryDidNotFail
    case cleanupFailed
    case unsupportedFault
}

actor RuntimeQualificationLiveDriver: RuntimeProviderLiveQualificationDriver {
    nonisolated let providerID: RuntimeProviderID
    nonisolated let providerVersion: String
    nonisolated let advertisedFeatures: [RuntimeProviderFeature]

    let fixtureImage: RuntimeLocalImageEvidence
    let capabilitySHA256: String
    let resourceIdentifier: String
    let resourceUUID: String
    let projectUUID: String
    let recorder: RuntimeQualificationCommandRecorder

    private let adapter: any RuntimeAdapter
    private let identity: RuntimeServiceIdentity
    private let desiredService: DesiredRuntimeService
    private let fencingToken: String
    private let cliExecutablePath: String?
    private let helperClient: ContainerizationHelperClient?
    private let helperFaultController: RuntimeQualificationHelperFaultController?
    private let partialEffectFaultController = RuntimeQualificationPartialEffectFaultController()
    private var observationGeneration = 0
    private var finalCleanupSnapshot: RuntimeProviderLiveQualificationSnapshot?

    private init(
        providerID: RuntimeProviderID,
        providerVersion: String,
        advertisedFeatures: [RuntimeProviderFeature],
        fixtureImage: RuntimeLocalImageEvidence,
        capabilitySHA256: String,
        resourceIdentifier: String,
        resourceUUID: String,
        projectUUID: String,
        recorder: RuntimeQualificationCommandRecorder,
        adapter: any RuntimeAdapter,
        identity: RuntimeServiceIdentity,
        desiredService: DesiredRuntimeService,
        fencingToken: String,
        cliExecutablePath: String?,
        helperClient: ContainerizationHelperClient?,
        helperFaultController: RuntimeQualificationHelperFaultController?
    ) {
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.advertisedFeatures = advertisedFeatures
        self.fixtureImage = fixtureImage
        self.capabilitySHA256 = capabilitySHA256
        self.resourceIdentifier = resourceIdentifier
        self.resourceUUID = resourceUUID
        self.projectUUID = projectUUID
        self.recorder = recorder
        self.adapter = adapter
        self.identity = identity
        self.desiredService = desiredService
        self.fencingToken = fencingToken
        self.cliExecutablePath = cliExecutablePath
        self.helperClient = helperClient
        self.helperFaultController = helperFaultController
    }

    static func make(
        providerID: RuntimeProviderID,
        expectedVersion: String,
        localImage: String
    ) async throws -> RuntimeQualificationLiveDriver {
        let recorder = RuntimeQualificationCommandRecorder()
        let adapter: any RuntimeAdapter
        let cliExecutablePath: String?
        let helperClient: ContainerizationHelperClient?
        let helperFaultController: RuntimeQualificationHelperFaultController?

        switch providerID {
        case .appleContainerCLI:
            let resolver = RuntimeExecutableResolver()
            guard let executable = try resolver.resolveExecutable(
                named: AppleContainerCommand.executableName
            ) else {
                throw RuntimeQualificationLiveDriverError.preflightFailed
            }
            cliExecutablePath = executable.path
            helperClient = nil
            helperFaultController = nil
            adapter = AppleContainerCLIAdapter(
                executableResolver: resolver,
                processRunner: RuntimeQualificationRecordingProcessRunner(recorder: recorder)
            )
        case .appleContainerization:
            guard let hostExecutable = Bundle.main.executableURL else {
                throw RuntimeQualificationLiveDriverError.preflightFailed
            }
            let configuration = try ContainerizationHelperClientConfiguration.installed(
                hostExecutableURL: hostExecutable
            )
            let registry = RuntimeQualificationHelperProcessRegistry()
            let controller = RuntimeQualificationHelperFaultController(
                registry: registry,
                socketURL: configuration.socketURL
            )
            let client = ContainerizationHelperClient(
                configuration: try ContainerizationHelperClientConfiguration(
                    executableURL: configuration.executableURL,
                    configurationURL: configuration.configurationURL,
                    runtimeDirectoryURL: configuration.runtimeDirectoryURL,
                    launchTimeoutMilliseconds: 5_000,
                    requestTimeoutMilliseconds:
                        RuntimeQualificationHelperTiming.normalRequestTimeoutMilliseconds
                ),
                launcher: registry.launcher(),
                transport: controller.transport()
            )
            cliExecutablePath = nil
            helperClient = client
            helperFaultController = controller
            adapter = AppleContainerizationRuntimeAdapter(client: client)
        default:
            throw RuntimeQualificationLiveDriverError.preflightFailed
        }

        let snapshot = try await adapter.capabilitySnapshot()
        let version = try await adapter.runtimeVersion()
        guard snapshot.descriptor.providerID == providerID,
              version == expectedVersion,
              RuntimeProviderCapabilityNegotiator.validationFindings(for: snapshot).isEmpty else {
            throw RuntimeQualificationLiveDriverError.versionMismatch
        }
        let mappedFeatures: Set<RuntimeProviderFeature> = [
            .observation, .lifecycle, .processControl, .streaming, .images,
            .cancellation, .timeouts, .errors, .cleanup
        ]
        let available = snapshot.features.filter {
            ($0.state == .available || $0.state == .experimental) &&
                mappedFeatures.contains($0.feature)
        }.map(\.feature)
        guard Set(available) == mappedFeatures else {
            throw RuntimeQualificationLiveDriverError.capabilityMismatch
        }
        let image = try await adapter.localImageEvidence(for: localImage)
        guard image.reference == localImage,
              Self.validOCI(image.descriptorDigest),
              Self.validOCI(image.variantDigest) else {
            throw RuntimeQualificationLiveDriverError.imageMismatch
        }

        let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let identity = RuntimeServiceIdentity(
            projectName: "p\(suffix.prefix(6))",
            serviceName: "s\(suffix.dropFirst(6).prefix(6))"
        )
        let resourceUUID = UUID().uuidString.lowercased()
        let projectUUID = UUID().uuidString.lowercased()
        let fencingToken = UUID().uuidString.lowercased()
        let desired = DesiredRuntimeService(
            identity: identity,
            image: localImage,
            command: ["sleep", "3600"]
        )
        let driver = RuntimeQualificationLiveDriver(
            providerID: providerID,
            providerVersion: expectedVersion,
            advertisedFeatures: available.sorted { $0.rawValue < $1.rawValue },
            fixtureImage: image,
            capabilitySHA256: snapshot.canonicalSHA256,
            resourceIdentifier: identity.managedResourceIdentifier,
            resourceUUID: resourceUUID,
            projectUUID: projectUUID,
            recorder: recorder,
            adapter: adapter,
            identity: identity,
            desiredService: desired,
            fencingToken: fencingToken,
            cliExecutablePath: cliExecutablePath,
            helperClient: helperClient,
            helperFaultController: helperFaultController
        )
        let initial = try await driver.canonicalInventory()
        guard await driver.managedContainer(in: initial) == nil else {
            throw RuntimeQualificationLiveDriverError.ownershipMismatch
        }
        return driver
    }

    func captureCanonicalInventory() async throws -> RuntimeProviderLiveQualificationSnapshot {
        if let finalCleanupSnapshot { return finalCleanupSnapshot }
        return try await uncachedCanonicalSnapshot()
    }

    func currentCapabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        try await adapter.capabilitySnapshot()
    }

    private func uncachedCanonicalSnapshot() async throws -> RuntimeProviderLiveQualificationSnapshot {
        let full = try await canonicalInventory()
        let unmanaged = try Self.rebuild(
            full,
            containers: full.containers.filter {
                $0.ownership?.resourceUUID != resourceUUID
            }
        )
        return RuntimeProviderLiveQualificationSnapshot(
            inventorySHA256: full.semanticSHA256,
            unmanagedSentinelSHA256: unmanaged.semanticSHA256
        )
    }

    func negotiateCapabilities() async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("negotiate")
        let snapshot = try await adapter.capabilitySnapshot()
        let version = try await adapter.runtimeVersion()
        guard snapshot.descriptor.providerID == providerID,
              snapshot.canonicalSHA256 == capabilitySHA256,
              version == providerVersion,
              RuntimeProviderCapabilityNegotiator.validationFindings(for: snapshot).isEmpty else {
            throw RuntimeQualificationLiveDriverError.capabilityMismatch
        }
        return .passed()
    }

    func observeRuntime() async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("observe")
        let first = try await canonicalInventory()
        let second = try await canonicalInventory()
        guard first.semanticSHA256 == second.semanticSHA256 else {
            throw RuntimeQualificationLiveDriverError.lifecycleMismatch
        }
        return .passed()
    }

    func verifyUUIDIdentity() async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("verify-uuid-identity")
        try await requireAbsent()
        do {
            try await create()
            let inventory = try await canonicalInventory()
            guard let container = managedContainer(in: inventory),
                  exactOwnership(container.ownership) else {
                throw RuntimeQualificationLiveDriverError.ownershipMismatch
            }
            try await cleanupResource()
            return .passed()
        } catch {
            try? await cleanupResource()
            throw error
        }
    }

    func refuseMissingLocalImage() async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("local-image-refusal")
        let missing = "example.invalid/hostwright-phase03-\(resourceUUID.prefix(8)):missing"
        do {
            _ = try await adapter.localImageEvidence(for: missing)
            throw RuntimeQualificationLiveDriverError.boundaryDidNotFail
        } catch let error as RuntimeAdapterError {
            let normalized = RuntimeNormalizedFailure.normalize(
                error,
                providerID: providerID.rawValue,
                providerVersion: providerVersion,
                operationID: "phase03-local-image-refusal"
            )
            guard normalized.category == .rejected else { throw error }
            return .passed(semantics: Self.semantics(normalized))
        }
    }

    func createManagedResource() async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("create")
        try await requireAbsent()
        let before = try await captureCanonicalInventory()
        let beforeGeneration = observationGeneration
        try await create()
        let afterInventory = try await canonicalInventory()
        guard let container = managedContainer(in: afterInventory),
              container.lifecycle == .created,
              exactOwnership(container.ownership) else {
            throw RuntimeQualificationLiveDriverError.lifecycleMismatch
        }
        let after = try await captureCanonicalInventory()
        observationGeneration += 1
        return .passed(resourceTransition: transition(
            before: before,
            after: after,
            beforeLifecycle: .missing,
            afterLifecycle: .created,
            beforeRuntimeID: nil,
            afterRuntimeID: container.runtimeID,
            beforeGeneration: beforeGeneration
        ))
    }

    func startManagedResource() async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("start")
        let beforeInventory = try await canonicalInventory()
        guard let beforeContainer = managedContainer(in: beforeInventory),
              beforeContainer.lifecycle == .created else {
            throw RuntimeQualificationLiveDriverError.lifecycleMismatch
        }
        let before = try await captureCanonicalInventory()
        let beforeGeneration = observationGeneration
        try await execute(.start, destructive: false)
        let afterInventory = try await canonicalInventory()
        guard let afterContainer = managedContainer(in: afterInventory),
              afterContainer.lifecycle == .running,
              exactOwnership(afterContainer.ownership) else {
            throw RuntimeQualificationLiveDriverError.lifecycleMismatch
        }
        let after = try await captureCanonicalInventory()
        observationGeneration += 1
        return .passed(resourceTransition: transition(
            before: before,
            after: after,
            beforeLifecycle: .created,
            afterLifecycle: .running,
            beforeRuntimeID: beforeContainer.runtimeID,
            afterRuntimeID: afterContainer.runtimeID,
            beforeGeneration: beforeGeneration
        ))
    }

    func restartManagedResource() async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("restart")
        let beforeInventory = try await canonicalInventory()
        guard let beforeContainer = managedContainer(in: beforeInventory),
              beforeContainer.lifecycle == .running else {
            throw RuntimeQualificationLiveDriverError.lifecycleMismatch
        }
        let before = try await captureCanonicalInventory()
        let beforeGeneration = observationGeneration
        try await execute(.restart, destructive: true)
        let afterInventory = try await canonicalInventory()
        guard let afterContainer = managedContainer(in: afterInventory),
              afterContainer.lifecycle == .running,
              exactOwnership(afterContainer.ownership) else {
            throw RuntimeQualificationLiveDriverError.lifecycleMismatch
        }
        let after = try await captureCanonicalInventory()
        observationGeneration += 1
        return .passed(resourceTransition: transition(
            before: before,
            after: after,
            beforeLifecycle: .running,
            afterLifecycle: .running,
            beforeRuntimeID: beforeContainer.runtimeID,
            afterRuntimeID: afterContainer.runtimeID,
            beforeGeneration: beforeGeneration
        ))
    }

    func deleteManagedResource() async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("delete")
        let beforeInventory = try await canonicalInventory()
        guard let beforeContainer = managedContainer(in: beforeInventory),
              beforeContainer.lifecycle == .running else {
            throw RuntimeQualificationLiveDriverError.lifecycleMismatch
        }
        let before = try await captureCanonicalInventory()
        let beforeGeneration = observationGeneration
        try await execute(.stop, destructive: true)
        try await execute(.remove, destructive: true)
        try await requireAbsent()
        let after = try await captureCanonicalInventory()
        observationGeneration += 1
        return .passed(resourceTransition: transition(
            before: before,
            after: after,
            beforeLifecycle: .running,
            afterLifecycle: .missing,
            beforeRuntimeID: beforeContainer.runtimeID,
            afterRuntimeID: nil,
            beforeGeneration: beforeGeneration
        ))
    }

    func readBoundedLogs(
        maximumBytes: Int,
        maximumLines: Int
    ) async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("logs")
        return try await withTemporaryRunningResource {
            let service = ObservedRuntimeService(
                identity: identity,
                resourceIdentifier: resourceIdentifier,
                image: desiredService.image,
                lifecycleState: .running
            )
            let result = try await adapter.logs(for: service, tail: maximumLines)
            guard result.identity == identity,
                  result.lineLimit <= maximumLines,
                  Data(result.text.utf8).count <= maximumBytes,
                  result.text.split(separator: "\n", omittingEmptySubsequences: false).count
                    <= maximumLines + 1 else {
                throw RuntimeQualificationLiveDriverError.preflightFailed
            }
        }
    }

    func readBoundedStats(
        maximumBytes: Int
    ) async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("stats")
        return try await withTemporaryRunningResource {
            let usage = try await adapter.resourceUsage(for: resourceIdentifier)
            let bounded = [
                usage.resourceIdentifier,
                String(usage.cpuUsageMicroseconds),
                String(usage.memoryUsageBytes),
                String(usage.memoryLimitBytes),
                String(usage.processCount)
            ].joined(separator: "|")
            guard usage.resourceIdentifier == resourceIdentifier,
                  bounded.utf8.count <= maximumBytes else {
                throw RuntimeQualificationLiveDriverError.preflightFailed
            }
        }
    }

    func exerciseTimeoutRecovery() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try await exerciseFault(.timedOut)
    }

    func exerciseCancellationRecovery() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try await exerciseFault(.cancelled)
    }

    func exerciseCrashRecovery() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try await exerciseFault(.crashed)
    }

    func restartProvider() async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("provider-restart")
        switch providerID {
        case .appleContainerCLI:
            guard let executable = cliExecutablePath else {
                throw RuntimeQualificationLiveDriverError.preflightFailed
            }
            try await runCLIControl(executable: executable, arguments: ["system", "stop"])
            try await runCLIControl(executable: executable, arguments: ["system", "start"])
        case .appleContainerization:
            guard let helperClient else {
                throw RuntimeQualificationLiveDriverError.preflightFailed
            }
            await helperClient.shutdown()
            _ = try await adapter.capabilitySnapshot()
        default:
            throw RuntimeQualificationLiveDriverError.preflightFailed
        }
        let snapshot = try await adapter.capabilitySnapshot()
        guard snapshot.canonicalSHA256 == capabilitySHA256 else {
            throw RuntimeQualificationLiveDriverError.capabilityMismatch
        }
        return .passed()
    }

    func injectRecoverablePartialEffect() async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("partial-effect")
        try await requireAbsent()
        do {
            try await create()
            partialEffectFaultController.arm()
            do {
                try partialEffectFaultController.failAfterRuntimeMutation()
                throw RuntimeQualificationLiveDriverError.boundaryDidNotFail
            } catch RuntimeQualificationInjectedPartialEffect.afterRuntimeMutation {
                // The failure is intentionally injected after the provider effect and before
                // structured observation so this lane proves recovery from a real partial effect.
            }
            let observed = try await canonicalInventory()
            guard let container = managedContainer(in: observed),
                  container.lifecycle == .created,
                  exactOwnership(container.ownership),
                  partialEffectFaultController.didActivate else {
                throw RuntimeQualificationLiveDriverError.ownershipMismatch
            }
            try await cleanupResource()
            let recovered = try await captureCanonicalInventory()
            return .passed(
                semantics: RuntimeProviderConformanceFailureSemantics(
                    category: .partialEffect,
                    retryDisposition: .resumeFromCheckpoint,
                    recoveryDisposition: .resume
                ),
                faultControl: RuntimeProviderLiveQualificationFaultControlEvidence(
                    deadlineEnforced: false,
                    faultControllerActivated: partialEffectFaultController.didActivate,
                    processTreeTerminated: false,
                    recoveryObservationSHA256: recovered.inventorySHA256
                )
            )
        } catch {
            try? await cleanupResource()
            throw error
        }
    }

    func verifyUnmanagedSentinel() async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("unmanaged-sentinel")
        let first = try await captureCanonicalInventory()
        let second = try await captureCanonicalInventory()
        guard first.unmanagedSentinelSHA256 == second.unmanagedSentinelSHA256 else {
            throw RuntimeQualificationLiveDriverError.ownershipMismatch
        }
        return .passed()
    }

    func cleanupManagedResources() async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("cleanup")
        try await cleanupResource()
        try await requireAbsent()
        let recovered = try await uncachedCanonicalSnapshot()
        if let helperClient {
            guard let helperFaultController else {
                throw RuntimeQualificationLiveDriverError.cleanupFailed
            }
            await helperClient.shutdown()
            guard helperFaultController.verifyFinalShutdown() else {
                throw RuntimeQualificationLiveDriverError.cleanupFailed
            }
        }
        finalCleanupSnapshot = recovered
        return .passed(faultControl: RuntimeProviderLiveQualificationFaultControlEvidence(
            deadlineEnforced: true,
            faultControllerActivated: false,
            processTreeTerminated: true,
            recoveryObservationSHA256: recovered.inventorySHA256
        ))
    }

    private enum FaultKind {
        case timedOut
        case cancelled
        case crashed
    }

    private func exerciseFault(
        _ kind: FaultKind
    ) async throws -> RuntimeProviderLiveQualificationDriverResult {
        await recordLogical("fault-\(String(describing: kind))")
        let semantics: RuntimeProviderConformanceFailureSemantics
        let activated: Bool
        let terminated: Bool
        switch providerID {
        case .appleContainerCLI:
            guard let executable = cliExecutablePath else {
                throw RuntimeQualificationLiveDriverError.unsupportedFault
            }
            let result = try await withTemporaryRunningResourceValue {
                switch kind {
                case .timedOut:
                    return try await RuntimeQualificationSubprocessProbe.timedOut(
                        executable: executable,
                        resourceIdentifier: resourceIdentifier
                    )
                case .cancelled:
                    return try await RuntimeQualificationSubprocessProbe.cancelled(
                        executable: executable,
                        resourceIdentifier: resourceIdentifier
                    )
                case .crashed:
                    return try await RuntimeQualificationSubprocessProbe.crashed(
                        executable: executable,
                        resourceIdentifier: resourceIdentifier
                    )
                }
            }
            activated = result
            terminated = result
        case .appleContainerization:
            guard let controller = helperFaultController else {
                throw RuntimeQualificationLiveDriverError.unsupportedFault
            }
            switch kind {
            case .timedOut:
                controller.arm(.timedOut(
                    deadlineMilliseconds: RuntimeQualificationHelperTiming.injectedTimeoutMilliseconds
                ))
            case .cancelled: controller.arm(.cancelled)
            case .crashed: controller.arm(.crashed)
            }
            do {
                switch kind {
                case .cancelled:
                    let task = Task { try await adapter.inventory() }
                    try await Task.sleep(for: .milliseconds(100))
                    task.cancel()
                    _ = try await task.value
                case .timedOut, .crashed:
                    _ = try await adapter.inventory()
                }
                throw RuntimeQualificationLiveDriverError.boundaryDidNotFail
            } catch let error as RuntimeAdapterError {
                let normalized = RuntimeNormalizedFailure.normalize(
                    error,
                    providerID: providerID.rawValue,
                    providerVersion: providerVersion,
                    operationID: "phase03-fault"
                )
                let expected: RuntimeFailureCategory = switch kind {
                case .timedOut: .timedOut
                case .cancelled: .cancelled
                case .crashed: .unavailable
                }
                guard normalized.category == expected else { throw error }
            }
            let state = controller.evidence()
            activated = state.activated
            terminated = state.terminated
            _ = try await adapter.capabilitySnapshot()
            _ = try await adapter.inventory()
        default:
            throw RuntimeQualificationLiveDriverError.unsupportedFault
        }
        guard activated, terminated else {
            throw RuntimeQualificationLiveDriverError.boundaryDidNotFail
        }
        let recovered = try await captureCanonicalInventory()
        semantics = switch kind {
        case .timedOut:
            RuntimeProviderConformanceFailureSemantics(
                category: .timedOut,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            )
        case .cancelled:
            RuntimeProviderConformanceFailureSemantics(
                category: .cancelled,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            )
        case .crashed:
            RuntimeProviderConformanceFailureSemantics(
                category: .crashed,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            )
        }
        return .passed(
            semantics: semantics,
            faultControl: RuntimeProviderLiveQualificationFaultControlEvidence(
                deadlineEnforced: kind == .timedOut && (
                    providerID == .appleContainerCLI ||
                        helperFaultController?.evidence().deadlineEnforced == true
                ),
                faultControllerActivated: activated,
                processTreeTerminated: terminated,
                recoveryObservationSHA256: recovered.inventorySHA256
            )
        )
    }

    private func withTemporaryRunningResource(
        _ operation: () async throws -> Void
    ) async throws -> RuntimeProviderLiveQualificationDriverResult {
        _ = try await withTemporaryRunningResourceValue {
            try await operation()
            return true
        }
        return .passed()
    }

    private func withTemporaryRunningResourceValue<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        try await requireAbsent()
        do {
            try await create()
            try await execute(.start, destructive: false)
            let result = try await operation()
            try await cleanupResource()
            return result
        } catch {
            try? await cleanupResource()
            throw error
        }
    }

    private func create() async throws {
        try await execute(.create, destructive: false)
    }

    private func cleanupResource() async throws {
        let inventory = try await canonicalInventory()
        guard let container = managedContainer(in: inventory) else { return }
        guard exactOwnership(container.ownership) else {
            throw RuntimeQualificationLiveDriverError.ownershipMismatch
        }
        if container.lifecycle == .running {
            try await execute(.stop, destructive: true)
        }
        try await execute(.remove, destructive: true)
    }

    private func execute(
        _ kind: PlannedRuntimeActionKind,
        destructive: Bool
    ) async throws {
        let operationID = "phase03-\(kind.rawValue)-\(UUID().uuidString.lowercased())"
        let context = RuntimeMutationContext(
            providerID: providerID,
            capabilitySHA256: capabilitySHA256,
            operationID: operationID,
            resourceUUID: resourceUUID,
            resourceGeneration: 1,
            projectResourceUUID: projectUUID,
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: fencingToken
        )
        let action = PlannedRuntimeAction(
            kind: kind,
            identity: identity,
            resourceIdentifier: resourceIdentifier,
            isDestructive: destructive,
            summary: "Phase 03 live provider qualification.",
            desiredService: kind == .create ? desiredService : nil
        )
        await recordLogical(kind.rawValue)
        _ = try await adapter.execute(
            action,
            confirmation: RuntimeMutationConfirmation(
                confirmed: true,
                reason: "Phase 03 maintainer live qualification.",
                planHash: capabilitySHA256,
                context: context
            )
        )
    }

    private func runCLIControl(executable: String, arguments: [String]) async throws {
        let result = try await SecureSubprocessRunner().runAsync(
            SecureSubprocessRequest(
                executablePath: executable,
                arguments: arguments,
                environment: SecureSubprocessEnvironment.currentUser,
                workingDirectory: "/",
                timeoutMilliseconds: 60_000,
                maximumStandardOutputBytes: 1 * 1_024 * 1_024,
                maximumStandardErrorBytes: 1 * 1_024 * 1_024
            )
        )
        guard result.exitStatus == 0 else {
            throw RuntimeQualificationLiveDriverError.preflightFailed
        }
        await recorder.record(arguments: [executable] + arguments, exitStatus: 0)
    }

    private func canonicalInventory() async throws -> RuntimeInventory {
        let inventory = try await adapter.inventory()
        return try Self.rebuild(inventory, containers: inventory.containers)
    }

    private static func rebuild(
        _ inventory: RuntimeInventory,
        containers: [RuntimeInventoryContainer]
    ) throws -> RuntimeInventory {
        try RuntimeInventoryBuilder.build(
            machine: inventory.machine,
            containers: containers.map { container in
                RuntimeInventoryContainer(
                    runtimeID: container.runtimeID,
                    name: container.name,
                    imageID: container.imageID,
                    imageReference: container.imageReference,
                    lifecycle: container.lifecycle,
                    health: container.health,
                    labels: container.labels,
                    ownership: container.ownership,
                    initConfiguration: container.initConfiguration,
                    ports: container.ports,
                    mounts: container.mounts,
                    networks: container.networks,
                    allocation: container.allocation,
                    usage: nil,
                    services: container.services
                )
            },
            images: inventory.images,
            networks: inventory.networks,
            volumes: inventory.volumes
        )
    }

    private func managedContainer(in inventory: RuntimeInventory) -> RuntimeInventoryContainer? {
        inventory.containers.first { $0.ownership?.resourceUUID == resourceUUID }
    }

    private func exactOwnership(_ ownership: RuntimeInventoryOwnershipEvidence?) -> Bool {
        ownership?.resourceUUID == resourceUUID &&
            ownership?.projectUUID == projectUUID &&
            ownership?.resourceGeneration == 1 &&
            ownership?.projectGeneration == 1 &&
            ownership?.providerID == providerID &&
            ownership?.providerGeneration == 1 &&
            ownership?.fencingToken == fencingToken
    }

    private func requireAbsent() async throws {
        let inventory = try await canonicalInventory()
        guard managedContainer(in: inventory) == nil,
              !inventory.containers.contains(where: { $0.name == resourceIdentifier }) else {
            throw RuntimeQualificationLiveDriverError.cleanupFailed
        }
    }

    private func transition(
        before: RuntimeProviderLiveQualificationSnapshot,
        after: RuntimeProviderLiveQualificationSnapshot,
        beforeLifecycle: RuntimeInventoryLifecycleState,
        afterLifecycle: RuntimeInventoryLifecycleState,
        beforeRuntimeID: String?,
        afterRuntimeID: String?,
        beforeGeneration: Int
    ) -> RuntimeProviderLiveQualificationResourceTransition {
        RuntimeProviderLiveQualificationResourceTransition(
            resourceUUID: resourceUUID,
            projectUUID: projectUUID,
            beforeLifecycle: beforeLifecycle,
            afterLifecycle: afterLifecycle,
            beforeRuntimeInstanceSHA256: beforeRuntimeID.map(Self.sha256),
            afterRuntimeInstanceSHA256: afterRuntimeID.map(Self.sha256),
            beforeObservationSHA256: before.inventorySHA256,
            afterObservationSHA256: after.inventorySHA256,
            beforeObservationGeneration: beforeGeneration,
            afterObservationGeneration: beforeGeneration + 1
        )
    }

    private func recordLogical(_ operation: String) async {
        guard providerID == .appleContainerization else { return }
        await recorder.record(
            arguments: ["hostwright-containerization-helper", operation],
            exitStatus: 0
        )
    }

    private static func semantics(
        _ failure: RuntimeNormalizedFailure
    ) -> RuntimeProviderConformanceFailureSemantics {
        RuntimeProviderConformanceFailureSemantics(
            category: failure.category,
            retryDisposition: failure.retryDisposition,
            recoveryDisposition: failure.recoveryDisposition
        )
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func validOCI(_ value: String) -> Bool {
        value.range(of: #"\Asha256:[0-9a-f]{64}\z"#, options: .regularExpression) != nil
    }
}
