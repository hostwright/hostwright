import HostwrightCore

public struct AppleContainerReadOnlyAdapter: RuntimeAdapter {
    public let executableResolver: RuntimeExecutableResolving
    public let processRunner: RuntimeProcessRunning
    public let redactionPolicy: RuntimeRedactionPolicy

    public init(
        executableResolver: RuntimeExecutableResolving = RuntimeExecutableResolver(),
        processRunner: RuntimeProcessRunning = SecureRuntimeProcessRunner(),
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.executableResolver = executableResolver
        self.processRunner = processRunner
        self.redactionPolicy = redactionPolicy
    }

    public func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "AppleContainerReadOnlyAdapter",
            adapterVersion: HostwrightIdentity.version,
            runtimeName: "Apple container CLI",
            runtimeVersion: nil,
            supportsMutation: false,
            capabilities: [.readOnlyObservation]
        )
    }

    public func capabilities() async throws -> [RuntimeCapability] {
        guard let executable = try executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }
        _ = try await selectedCodec(executable: executable)

        return [.readOnlyObservation]
    }

    public func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        try await RuntimeProviderCapabilityProbe(
            executableResolver: executableResolver,
            processRunner: processRunner
        ).probeAppleContainerCLI()
    }

    public func inventory() async throws -> RuntimeInventory {
        try await readInventoryEvidence().inventory
    }

    public func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        let evidence = try await readInventoryEvidence()
        return ObservedRuntimeState(
            projectName: desiredState.projectName,
            services: try observedServices(
                from: evidence.inventory,
                desiredState: desiredState
            ),
            adapterMetadata: await metadata(),
            capabilitySHA256: evidence.capabilitySnapshot.canonicalSHA256
        )
    }

    public func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
        RuntimePlan(
            actions: [],
            warnings: ["Apple container read-only adapter does not plan runtime mutation."],
            capabilitySHA256: observedState.capabilitySHA256
        )
    }

    public func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        guard let executable = try executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }

        let containerID = service.resourceIdentifier
        guard RuntimeManagedResourceIdentity.isSupportedIdentifier(containerID) else {
            throw RuntimeAdapterError.commandRejected(
                classification: .readOnly,
                message: "Logs require an exact supported Hostwright resource identifier."
            )
        }
        let codec = try await selectedCodec(executable: executable)
        let spec = AppleContainerCommand.spec(
            kind: .logs(containerID: containerID, tail: tail),
            codec: codec,
            executable: executable
        )
        try RuntimeCommandPolicy.validateReadOnlyExecution(spec)

        let result = try await processRunner.run(spec)
        return RuntimeLogResult(
            identity: service.identity,
            text: try codec.decodeOpaqueLogs(result.standardOutput, redactionPolicy: redactionPolicy),
            lineLimit: min(max(1, tail), 1_000)
        )
    }

    public func runtimeVersion() async throws -> String {
        guard let executable = try executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }
        let spec = AppleContainerCommand.spec(kind: .version, executable: executable)
        try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
        let result = try await processRunner.run(spec)
        _ = try AppleContainerCLICodec.select(fromVersionOutput: result.standardOutput, redactionPolicy: redactionPolicy)
        guard let version = AppleContainerVersionParser.parse(result.standardOutput) else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container CLI version output did not match the selected codec."
            )
        }
        return version
    }

    public func runtimeReadiness() async throws -> RuntimeReadinessReport {
        guard let executable = try executableResolver.resolveExecutable(
            named: AppleContainerCommand.executableName
        ) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }

        let (codec, version) = try await selectedCodecAndVersion(executable: executable)
        let statusSpec = AppleContainerCommand.spec(
            kind: .systemStatus,
            codec: codec,
            executable: executable,
            timeout: RuntimeCommandTimeout(seconds: 15)
        )
        try RuntimeCommandPolicy.validateReadOnlyExecution(statusSpec)

        let status = try await processRunner.run(statusSpec).standardOutput
        return try codec.decodeSystemStatus(
            status,
            versionOutput: version,
            redactionPolicy: redactionPolicy
        )
    }

    public func resourceUsage(for resourceIdentifier: String) async throws -> RuntimeResourceUsageSnapshot {
        guard let executable = try executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }
        let codec = try await selectedCodec(executable: executable)
        let spec = AppleContainerCommand.spec(
            kind: .stats(containerID: resourceIdentifier),
            codec: codec,
            executable: executable
        )
        try RuntimeCommandPolicy.validateExactResourceStats(spec, resourceIdentifier: resourceIdentifier)
        let result = try await processRunner.run(spec)
        return try codec.decodeResourceUsage(
            result.standardOutput,
            expectedResourceIdentifier: resourceIdentifier,
            redactionPolicy: redactionPolicy
        )
    }

    public func localImageEvidence(for imageReference: String) async throws -> RuntimeLocalImageEvidence {
        guard let executable = try executableResolver.resolveExecutable(named: AppleContainerCommand.executableName) else {
            throw RuntimeAdapterError.runtimeUnavailable("Apple container CLI was not found on PATH.")
        }
        let codec = try await selectedCodec(executable: executable)
        return try await localImageEvidence(
            for: imageReference,
            codec: codec,
            executable: executable
        )
    }

    func localImageEvidence(
        for imageReference: String,
        codec: AppleContainerCLICodec,
        executable: ResolvedRuntimeExecutable
    ) async throws -> RuntimeLocalImageEvidence {
        let spec = AppleContainerCommand.spec(
            kind: .listImages,
            codec: codec,
            executable: executable
        )
        try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
        let result = try await processRunner.run(spec)
        return try codec.decodeLocalImageEvidence(
            result.standardOutput,
            expectedReference: imageReference,
            preferredArchitecture: "arm64",
            redactionPolicy: redactionPolicy
        )
    }

    private struct InventoryEvidence {
        let capabilitySnapshot: RuntimeCapabilitySnapshot
        let inventory: RuntimeInventory
    }

    private func readInventoryEvidence() async throws -> InventoryEvidence {
        do {
            try Task.checkCancellation()
            guard let executable = try executableResolver.resolveExecutable(
                named: AppleContainerCommand.executableName
            ) else {
                throw RuntimeAdapterError.runtimeUnavailable(
                    "Apple container CLI was not found on PATH."
                )
            }

            let initialSnapshot = try await capabilitySnapshot()
            guard initialSnapshot.descriptor.providerID == .appleContainerCLI else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container capability negotiation selected an unexpected provider."
                )
            }

            let version = try await inventoryOutput(
                .version,
                executable: executable
            )
            let codec = try AppleContainerCLICodec.select(
                fromVersionOutput: version,
                redactionPolicy: redactionPolicy
            )
            let systemStatus = try await inventoryOutput(
                .systemStatus,
                codec: codec,
                executable: executable
            )
            let containers = try await inventoryOutput(
                .listContainers,
                codec: codec,
                executable: executable
            )
            let images = try await inventoryOutput(
                .listImages,
                codec: codec,
                executable: executable
            )
            let networks = try await inventoryOutput(
                .listNetworks,
                codec: codec,
                executable: executable
            )
            let volumes = try await inventoryOutput(
                .listVolumes,
                codec: codec,
                executable: executable
            )
            let machines = try await inventoryOutput(
                .listMachines,
                codec: codec,
                executable: executable
            )

            let baseOutputs = AppleContainerInventoryOutputs(
                version: version,
                systemStatus: systemStatus,
                containers: containers,
                images: images,
                networks: networks,
                volumes: volumes,
                machines: machines
            )
            let baseInventory = try AppleContainerInventoryParser.parse(
                outputs: baseOutputs,
                redactionPolicy: redactionPolicy
            )

            var statsByContainerID: [String: String] = [:]
            for container in baseInventory.containers where
                container.lifecycle == .running &&
                container.ownership?.providerID == .appleContainerCLI &&
                RuntimeManagedResourceIdentity.isCurrentIdentifier(container.runtimeID) {
                try Task.checkCancellation()
                statsByContainerID[container.runtimeID] = try await inventoryStatsOutput(
                    containerID: container.runtimeID,
                    codec: codec,
                    executable: executable
                )
            }

            let inventory = try AppleContainerInventoryParser.parse(
                outputs: AppleContainerInventoryOutputs(
                    version: version,
                    systemStatus: systemStatus,
                    containers: containers,
                    images: images,
                    networks: networks,
                    volumes: volumes,
                    machines: machines,
                    statsByContainerID: statsByContainerID
                ),
                redactionPolicy: redactionPolicy
            )

            let finalSnapshot = try await capabilitySnapshot()
            try RuntimeProviderSelector.requireFreshCapability(
                expectedSHA256: initialSnapshot.canonicalSHA256,
                currentSnapshot: finalSnapshot
            )
            try Task.checkCancellation()
            return InventoryEvidence(
                capabilitySnapshot: finalSnapshot,
                inventory: inventory
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RuntimeAdapterError {
            throw error.redacted(using: redactionPolicy)
        }
    }

    private func inventoryOutput(
        _ kind: AppleContainerCommand.ReadOnlyKind,
        codec: AppleContainerCLICodec? = nil,
        executable: ResolvedRuntimeExecutable
    ) async throws -> String {
        let spec = codec.map {
            AppleContainerCommand.spec(kind: kind, codec: $0, executable: executable)
        } ?? AppleContainerCommand.spec(kind: kind, executable: executable)
        try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
        return try await runInventoryRead(spec).standardOutput
    }

    private func inventoryStatsOutput(
        containerID: String,
        codec: AppleContainerCLICodec,
        executable: ResolvedRuntimeExecutable
    ) async throws -> String {
        let spec = AppleContainerCommand.spec(
            kind: .stats(containerID: containerID),
            codec: codec,
            executable: executable
        )
        try RuntimeCommandPolicy.validateExactResourceStats(
            spec,
            resourceIdentifier: containerID
        )
        return try await runInventoryRead(spec).standardOutput
    }

    private func runInventoryRead(
        _ spec: RuntimeCommandSpec
    ) async throws -> RuntimeCommandResult {
        try Task.checkCancellation()
        let result = try await processRunner.run(spec)
        try Task.checkCancellation()
        if result.wasCancelled {
            throw CancellationError()
        }
        guard result.spec == spec,
              !result.timedOut,
              spec.exitStatusPolicy.accepts(result.exitStatus) else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container inventory read returned an invalid process result."
            )
        }
        return result
    }

    private func observedServices(
        from inventory: RuntimeInventory,
        desiredState: DesiredRuntimeState
    ) throws -> [ObservedRuntimeService] {
        var hintsByIdentifier: [String: RuntimeOwnedResourceHint] = [:]
        for hint in desiredState.ownedResourceHints {
            guard hint.identity.projectName == desiredState.projectName,
                  hintsByIdentifier.updateValue(hint, forKey: hint.resourceIdentifier) == nil else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Runtime state contained conflicting owned-resource hints."
                )
            }
        }

        let networksByID = Dictionary(uniqueKeysWithValues: inventory.networks.map {
            ($0.runtimeID, $0)
        })
        var services: [ObservedRuntimeService] = []
        for container in inventory.containers {
            try Task.checkCancellation()
            guard let hint = hintsByIdentifier[container.runtimeID] else {
                continue
            }
            let labels = Dictionary(uniqueKeysWithValues: container.labels.map {
                ($0.key, $0.value)
            })
            guard hint.identityVersion == RuntimeManagedResourceIdentity.currentVersion,
                  let expectedOwnership = hint.ownership,
                  let observedOwnership = container.ownership,
                  expectedOwnership == observedOwnership,
                  expectedOwnership.providerID == .appleContainerCLI,
                  RuntimeManagedResourceIdentity.identity(from: labels) == hint.identity,
                  RuntimeManagedResourceIdentity.labelsMatch(
                    labels,
                    identity: hint.identity,
                    resourceIdentifier: hint.resourceIdentifier
                  ) else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container inventory did not match exact UUID-backed state ownership."
                )
            }
            services.append(
                ObservedRuntimeService(
                    identity: hint.identity,
                    resourceIdentifier: container.runtimeID,
                    image: container.imageReference,
                    lifecycleState: lifecycleState(container.lifecycle),
                    healthState: healthState(container.health),
                    ports: container.ports.map(runtimePort),
                    networks: container.networks.map {
                        runtimeNetwork($0, inventory: networksByID[$0.networkID])
                    },
                    mounts: container.mounts.map(runtimeMount),
                    observedAt: nil
                )
            )
        }
        return services.sorted {
            ($0.identity.displayName, $0.resourceIdentifier) <
                ($1.identity.displayName, $1.resourceIdentifier)
        }
    }

    private func lifecycleState(
        _ state: RuntimeInventoryLifecycleState
    ) -> RuntimeLifecycleState {
        switch state {
        case .unknown: return .unknown
        case .missing: return .missing
        case .created: return .created
        case .running: return .running
        case .stopped: return .stopped
        case .exited: return .exited
        case .failed: return .failed
        }
    }

    private func healthState(_ health: RuntimeInventoryHealth) -> RuntimeHealthState {
        switch health.availability {
        case .notConfigured:
            return .notConfigured
        case .unsupported, .unavailable:
            return .unknown
        case .available:
            switch health.state {
            case .starting: return .starting
            case .healthy: return .healthy
            case .unhealthy: return .unhealthy
            case .unknown, .none: return .unknown
            }
        }
    }

    private func runtimePort(_ port: RuntimeInventoryPort) -> RuntimePortMapping {
        RuntimePortMapping(
            hostPort: port.hostPort,
            containerPort: port.containerPort,
            protocolName: port.protocolName == .udp ? .udp : .tcp,
            bindAddress: port.hostAddress
        )
    }

    private func runtimeNetwork(
        _ attachment: RuntimeInventoryNetworkAttachment,
        inventory: RuntimeInventoryNetwork?
    ) -> RuntimeNetworkAttachment {
        RuntimeNetworkAttachment(
            name: attachment.networkID,
            kind: inventory?.kind,
            address: attachment.addresses.first,
            gateway: attachment.gateway,
            interfaceName: attachment.interfaceName,
            ipv4Address: attachment.addresses.first { $0.contains(".") },
            ipv4Gateway: attachment.gateway?.contains(".") == true ? attachment.gateway : nil,
            ipv6Address: attachment.addresses.first { $0.contains(":") },
            macAddress: attachment.macAddress
        )
    }

    private func runtimeMount(_ mount: RuntimeInventoryMount) -> RuntimeMountReference {
        RuntimeMountReference(
            source: mount.source,
            target: mount.target,
            access: mount.access == .readOnly ? .readOnly : .readWrite
        )
    }

    public func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        throw RuntimeAdapterError.mutationUnavailableByPolicy("Read-only adapter cannot execute runtime action '\(action.kind.rawValue)'.")
    }

    func selectedCodec(executable: ResolvedRuntimeExecutable) async throws -> AppleContainerCLICodec {
        try await selectedCodecAndVersion(executable: executable).codec
    }

    func selectedCodecAndVersion(
        executable: ResolvedRuntimeExecutable
    ) async throws -> (codec: AppleContainerCLICodec, version: String) {
        let spec = AppleContainerCommand.spec(
            kind: .version,
            executable: executable,
            timeout: RuntimeCommandTimeout(seconds: 5)
        )
        try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
        let version = try await processRunner.run(spec).standardOutput
        let codec = try AppleContainerCLICodec.select(
            fromVersionOutput: version,
            redactionPolicy: redactionPolicy
        )
        return (codec, version)
    }
}
