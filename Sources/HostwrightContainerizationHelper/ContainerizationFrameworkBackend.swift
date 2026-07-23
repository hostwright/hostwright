import Containerization
import ContainerizationError
import ContainerizationOCI
import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightRuntime

struct ContainerizationHelperResolvedProcess: Equatable, Sendable {
    let command: [String]
    let environment: [RuntimeInventoryEnvironmentEntry]
    let workingDirectory: String
    let user: String?
}

struct ContainerizationHelperImageRecord: Equatable, Sendable {
    let evidence: ContainerizationHelperImageEvidence
    let references: [String]
}

protocol ContainerizationHelperRuntimeDriving: Sendable {
    func resolveProcess(
        for request: ContainerizationHelperCreatePayload
    ) async throws -> ContainerizationHelperResolvedProcess
    func localImageEvidence(reference: String) async throws -> ContainerizationHelperImageEvidence
    func listImages() async throws -> [ContainerizationHelperImageRecord]
    func create(_ record: ContainerizationHelperPersistedRecord) async throws
    func start(_ record: ContainerizationHelperPersistedRecord) async throws
    func restart(_ record: ContainerizationHelperPersistedRecord) async throws
    func stop(_ record: ContainerizationHelperPersistedRecord) async throws
    func delete(_ record: ContainerizationHelperPersistedRecord) async throws
    func usage(resourceIdentifier: String) async throws -> ContainerizationHelperResourceUsage
    func shutdown() async
}

actor ContainerizationFrameworkBackend: ContainerizationHelperBackend {
    private let snapshot: RuntimeCapabilitySnapshot
    private let store: ContainerizationHelperStateStore
    private let driver: any ContainerizationHelperRuntimeDriving
    private var records: [String: ContainerizationHelperPersistedRecord]

    static func make(
        configuration: ContainerizationHelperConfiguration
    ) async throws -> ContainerizationFrameworkBackend {
        try configuration.validate()
        try ContainerizationHelperStateStore.preparePrivateDirectory(configuration.dataRootURL)
        let stateURL = configuration.dataRootURL.appendingPathComponent("state", isDirectory: true)
        let store = try ContainerizationHelperStateStore(rootURL: stateURL)
        let driver = try await AppleContainerizationRuntimeDriver(
            configuration: configuration,
            stateStore: store
        )
        return try ContainerizationFrameworkBackend(
            snapshot: try ContainerizationHelperCapabilitySnapshot.make(),
            store: store,
            driver: driver
        )
    }

    init(
        snapshot: RuntimeCapabilitySnapshot,
        store: ContainerizationHelperStateStore,
        driver: any ContainerizationHelperRuntimeDriving
    ) throws {
        self.snapshot = snapshot
        self.store = store
        self.driver = driver
        let loadedRecords = Dictionary(
            uniqueKeysWithValues: try store.loadRecords().map { ($0.resourceIdentifier, $0) }
        )
        self.records = try Self.recoverInterruptedState(loadedRecords, store: store)
    }

    func negotiate() async throws -> RuntimeCapabilitySnapshot {
        snapshot
    }

    func observe(
        _ request: ContainerizationHelperObservePayload
    ) async throws -> ContainerizationHelperObservation {
        try Task.checkCancellation()
        try await finishPreparedDeletes()

        var containers: [RuntimeInventoryContainer] = []
        for record in records.values.sorted(by: { $0.resourceIdentifier < $1.resourceIdentifier }) {
            try Task.checkCancellation()
            let usage: RuntimeInventoryUsage?
            if request.includeResourceUsage, record.phase == .running {
                let value = try await driver.usage(resourceIdentifier: record.resourceIdentifier)
                usage = RuntimeInventoryUsage(
                    cpuUsageMicroseconds: value.cpuUsageMicroseconds,
                    memoryUsageBytes: value.memoryUsageBytes,
                    memoryLimitBytes: value.memoryLimitBytes,
                    networkReceiveBytes: value.networkReceiveBytes,
                    networkTransmitBytes: value.networkTransmitBytes,
                    blockReadBytes: value.blockReadBytes,
                    blockWriteBytes: value.blockWriteBytes,
                    processCount: value.processCount
                )
            } else {
                usage = nil
            }
            containers.append(try inventoryContainer(record, usage: usage))
        }

        let images = try await driver.listImages().map { image in
            RuntimeInventoryImage(
                runtimeID: image.evidence.descriptorDigest,
                descriptorDigest: image.evidence.descriptorDigest,
                references: image.references,
                variants: [
                    RuntimeInventoryImageVariant(
                        digest: image.evidence.variantDigest,
                        architecture: image.evidence.architecture,
                        operatingSystem: image.evidence.operatingSystem
                    )
                ],
                labels: []
            )
        }
        let inventory = try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS",
                architecture: "arm64",
                runtimeVersion: ContainerizationHelperConfiguration.frameworkVersion,
                services: [
                    RuntimeInventoryService(
                        identifier: "hostwright-containerization-helper",
                        state: .running,
                        required: true
                    )
                ]
            ),
            containers: containers,
            images: images,
            networks: [],
            volumes: []
        )
        return ContainerizationHelperObservation(inventory: inventory)
    }

    func localImageEvidence(
        _ request: ContainerizationHelperImageRequest
    ) async throws -> ContainerizationHelperImageEvidence {
        try Task.checkCancellation()
        do {
            return try await driver.localImageEvidence(reference: request.reference)
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            throw ContainerizationHelperBackendError.rejected("image is not available locally")
        }
    }

    func resourceUsage(
        _ request: ContainerizationHelperResourceRequest
    ) async throws -> ContainerizationHelperResourceUsage {
        try Task.checkCancellation()
        guard records[request.resourceIdentifier]?.phase == .running else {
            throw ContainerizationHelperBackendError.conflict("resource is not running")
        }
        return try await driver.usage(resourceIdentifier: request.resourceIdentifier)
    }

    func logs(_ request: ContainerizationHelperLogsRequest) async throws -> ContainerizationHelperLogs {
        try Task.checkCancellation()
        guard records[request.resourceIdentifier] != nil else {
            throw ContainerizationHelperBackendError.rejected("resource is not managed")
        }
        return ContainerizationHelperLogs(
            resourceIdentifier: request.resourceIdentifier,
            text: try store.readLog(
                resourceIdentifier: request.resourceIdentifier,
                lineLimit: request.lineLimit
            ),
            lineLimit: request.lineLimit
        )
    }

    func create(
        _ request: ContainerizationHelperCreatePayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        try Task.checkCancellation()
        try validateCreateOwnership(request: request, context: context)
        guard records[request.resourceIdentifier] == nil else {
            throw ContainerizationHelperBackendError.conflict("resource already exists")
        }

        let resolved = try await driver.resolveProcess(for: request)
        guard !resolved.command.isEmpty else {
            throw ContainerizationHelperBackendError.rejected("image has no executable command")
        }
        var record = ContainerizationHelperPersistedRecord(request: request, context: context)
        record.command = resolved.command
        record.environment = resolved.environment
        record.workingDirectory = resolved.workingDirectory
        record.user = resolved.user
        try store.save(record)
        records[record.resourceIdentifier] = record

        do {
            try Task.checkCancellation()
            try await driver.create(record)
            try Task.checkCancellation()
            record.phase = .stopped
            record.failureCategory = nil
            try store.save(record)
            records[record.resourceIdentifier] = record
            return result(for: record.resourceIdentifier, lifecycle: .stopped)
        } catch {
            try? await driver.stop(record)
            record.phase = error is CancellationError ? .stopped : .failed
            record.failureCategory = error is CancellationError ? "cancelled" : "create-failed"
            try store.save(record)
            records[record.resourceIdentifier] = record
            throw error
        }
    }

    func start(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        var record = try requireRecord(request, context: context)
        guard [.created, .stopped].contains(record.phase) else {
            throw ContainerizationHelperBackendError.conflict("resource cannot be started")
        }
        record.phase = .preparedStart
        record.failureCategory = nil
        try store.save(record)
        records[record.resourceIdentifier] = record
        do {
            try Task.checkCancellation()
            try await driver.start(record)
            try Task.checkCancellation()
            record.phase = .running
            try store.save(record)
            records[record.resourceIdentifier] = record
            return result(for: record.resourceIdentifier, lifecycle: .running)
        } catch {
            try? await driver.stop(record)
            record.phase = .stopped
            record.failureCategory = error is CancellationError ? "cancelled" : "start-failed"
            try store.save(record)
            records[record.resourceIdentifier] = record
            throw error
        }
    }

    func stop(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        var record = try requireRecord(request, context: context)
        guard record.phase == .running else {
            throw ContainerizationHelperBackendError.conflict("resource is not running")
        }
        do {
            try Task.checkCancellation()
            try await driver.stop(record)
            try Task.checkCancellation()
            record.phase = .stopped
            record.failureCategory = nil
            try store.save(record)
            records[record.resourceIdentifier] = record
            return result(for: record.resourceIdentifier, lifecycle: .stopped)
        } catch {
            record.failureCategory = error is CancellationError ? "cancelled" : "stop-failed"
            try store.save(record)
            records[record.resourceIdentifier] = record
            throw error
        }
    }

    func restart(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        var record = try requireRecord(request, context: context)
        guard record.phase == .running else {
            throw ContainerizationHelperBackendError.conflict("resource is not running")
        }
        record.phase = .preparedRestart
        record.failureCategory = nil
        try store.save(record)
        records[record.resourceIdentifier] = record
        do {
            try Task.checkCancellation()
            try await driver.restart(record)
            try Task.checkCancellation()
            record.runtimeInstanceID = UUID().uuidString.lowercased()
            record.phase = .running
            try store.save(record)
            records[record.resourceIdentifier] = record
            return result(for: record.resourceIdentifier, lifecycle: .running)
        } catch {
            try? await driver.stop(record)
            record.phase = .stopped
            record.failureCategory = error is CancellationError ? "cancelled" : "restart-failed"
            try store.save(record)
            records[record.resourceIdentifier] = record
            throw error
        }
    }

    func delete(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        var record = try requireRecord(request, context: context)
        record.phase = .preparedDelete
        record.failureCategory = nil
        try store.save(record)
        records[record.resourceIdentifier] = record
        do {
            try Task.checkCancellation()
            try await driver.delete(record)
            try Task.checkCancellation()
            try store.removeLog(resourceIdentifier: record.resourceIdentifier)
            try store.removeRecord(resourceIdentifier: record.resourceIdentifier)
            records.removeValue(forKey: record.resourceIdentifier)
            return result(for: record.resourceIdentifier, lifecycle: .missing)
        } catch {
            record.failureCategory = error is CancellationError ? "cancelled" : "delete-failed"
            try store.save(record)
            records[record.resourceIdentifier] = record
            throw error
        }
    }

    func cancel(requestID: UUID) async {
        _ = requestID
    }

    func shutdown() async {
        for var record in records.values where record.phase == .running || record.phase == .created {
            do {
                try await driver.stop(record)
                record.phase = .stopped
                record.failureCategory = nil
                try store.save(record)
                records[record.resourceIdentifier] = record
            } catch {
                record.phase = .failed
                record.failureCategory = "shutdown-failed"
                try? store.save(record)
                records[record.resourceIdentifier] = record
            }
        }
        await driver.shutdown()
    }

    private static func recoverInterruptedState(
        _ records: [String: ContainerizationHelperPersistedRecord],
        store: ContainerizationHelperStateStore
    ) throws -> [String: ContainerizationHelperPersistedRecord] {
        var recovered = records
        for var record in records.values {
            switch record.phase {
            case .created, .preparedStart, .running, .preparedRestart:
                record.phase = .stopped
                record.failureCategory = "helper-restarted"
                try store.save(record)
                recovered[record.resourceIdentifier] = record
            case .preparedCreate:
                record.phase = .failed
                record.failureCategory = "interrupted-create"
                try store.save(record)
                recovered[record.resourceIdentifier] = record
            case .preparedDelete, .stopped, .failed:
                break
            }
        }
        return recovered
    }

    private func finishPreparedDeletes() async throws {
        for record in records.values where record.phase == .preparedDelete {
            try Task.checkCancellation()
            try await driver.delete(record)
            try store.removeLog(resourceIdentifier: record.resourceIdentifier)
            try store.removeRecord(resourceIdentifier: record.resourceIdentifier)
            records.removeValue(forKey: record.resourceIdentifier)
        }
    }

    private func requireRecord(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) throws -> ContainerizationHelperPersistedRecord {
        guard let record = records[request.resourceIdentifier],
              record.resourceUUID == request.resourceUUID.lowercased(),
              record.resourceUUID == context.resourceUUID.lowercased(),
              record.projectUUID == context.projectResourceUUID.lowercased(),
              record.mutationContext.resourceGeneration == context.resourceGeneration,
              record.mutationContext.projectGeneration == context.projectGeneration,
              record.mutationContext.providerGeneration == context.providerGeneration,
              record.mutationContext.fencingToken == context.fencingToken.lowercased() else {
            throw ContainerizationHelperBackendError.conflict("resource ownership or fence changed")
        }
        return record
    }

    private func validateCreateOwnership(
        request: ContainerizationHelperCreatePayload,
        context: RuntimeMutationContext
    ) throws {
        let labels = try labelDictionary(request.labels)
        guard let identity = RuntimeManagedResourceIdentity.identity(from: labels),
              RuntimeManagedResourceIdentity.labelsMatch(
                labels,
                identity: identity,
                resourceIdentifier: request.resourceIdentifier
              ),
              let ownership = try RuntimeManagedResourceIdentity.ownershipEvidence(
                from: labels,
                expectedProviderID: .appleContainerization
              ),
              ownership.resourceUUID == context.resourceUUID.lowercased(),
              ownership.projectUUID == context.projectResourceUUID.lowercased(),
              ownership.resourceGeneration == context.resourceGeneration,
              ownership.projectGeneration == context.projectGeneration,
              ownership.providerGeneration == context.providerGeneration,
              ownership.fencingToken == context.fencingToken.lowercased() else {
            throw ContainerizationHelperBackendError.rejected("resource ownership labels are invalid")
        }
    }

    private func labelDictionary(
        _ labels: [RuntimeInventoryLabel]
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for label in labels {
            guard result.updateValue(label.value, forKey: label.key) == nil else {
                throw ContainerizationHelperBackendError.rejected("duplicate resource label")
            }
        }
        return result
    }

    private func inventoryContainer(
        _ record: ContainerizationHelperPersistedRecord,
        usage: RuntimeInventoryUsage?
    ) throws -> RuntimeInventoryContainer {
        let labels = try labelDictionary(record.labels)
        let ownership = try RuntimeManagedResourceIdentity.ownershipEvidence(
            from: labels,
            expectedProviderID: .appleContainerization
        )
        let lifecycle: RuntimeInventoryLifecycleState
        switch record.phase {
        case .created:
            lifecycle = .created
        case .running:
            lifecycle = .running
        case .stopped:
            lifecycle = .stopped
        case .failed, .preparedCreate, .preparedStart, .preparedRestart, .preparedDelete:
            lifecycle = .failed
        }
        return RuntimeInventoryContainer(
            runtimeID: record.runtimeInstanceID ?? record.resourceIdentifier,
            name: record.resourceIdentifier,
            imageID: record.image.variantDigest,
            imageReference: record.image.reference,
            lifecycle: lifecycle,
            health: RuntimeInventoryHealth(availability: .unsupported),
            labels: record.labels,
            ownership: ownership,
            initConfiguration: RuntimeInventoryInitConfiguration(
                executable: record.command[0],
                arguments: Array(record.command.dropFirst()),
                environment: record.environment,
                workingDirectory: record.workingDirectory,
                user: record.user,
                terminal: false
            ),
            ports: [],
            mounts: [],
            networks: [],
            allocation: RuntimeInventoryAllocation(cpuCount: 4, memoryBytes: 1_073_741_824),
            usage: usage,
            services: []
        )
    }

    private func result(
        for resourceIdentifier: String,
        lifecycle: RuntimeInventoryLifecycleState
    ) -> ContainerizationHelperMutationResult {
        ContainerizationHelperMutationResult(
            resourceIdentifier: resourceIdentifier,
            lifecycle: lifecycle,
            verified: true
        )
    }
}

private actor AppleContainerizationRuntimeDriver: ContainerizationHelperRuntimeDriving {
    private let configuration: ContainerizationHelperConfiguration
    private let stateStore: ContainerizationHelperStateStore
    private let imageStore: ImageStore
    private var manager: ContainerManager
    private var containers: [String: LinuxContainer] = [:]

    init(
        configuration: ContainerizationHelperConfiguration,
        stateStore: ContainerizationHelperStateStore
    ) async throws {
        self.configuration = configuration
        self.stateStore = stateStore

        let imageStoreURL = configuration.dataRootURL.appendingPathComponent("images", isDirectory: true)
        try ContainerizationHelperStateStore.preparePrivateDirectory(imageStoreURL)
        let imageStore = try ImageStore(path: imageStoreURL)
        self.imageStore = imageStore

        let initImage = try await Self.requireInitImage(
            configuration: configuration,
            imageStore: imageStore
        )
        let bootstrapURL = configuration.dataRootURL.appendingPathComponent("bootstrap", isDirectory: true)
        try ContainerizationHelperStateStore.preparePrivateDirectory(bootstrapURL)
        let initfsURL = bootstrapURL.appendingPathComponent(
            configuration.initfsCacheFileName,
            isDirectory: false
        )
        let initfs: Containerization.Mount
        if FileManager.default.fileExists(atPath: initfsURL.path) {
            _ = try ContainerizationHelperStateStore.requirePrivateRegularFile(initfsURL)
            initfs = .block(
                format: "ext4",
                source: initfsURL.path,
                destination: "/",
                options: ["ro"]
            )
        } else {
            initfs = try await InitImage(image: initImage).initBlock(at: initfsURL, for: .linuxArm)
            guard chmod(initfsURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw ContainerizationHelperPersistenceError.operationFailed
            }
        }
        let kernel = Kernel(path: configuration.kernelURL, platform: .linuxArm)
        self.manager = try ContainerManager(
            kernel: kernel,
            initfs: initfs,
            imageStore: imageStore,
            network: nil,
            rosetta: false,
            nestedVirtualization: false
        )
    }

    func resolveProcess(
        for request: ContainerizationHelperCreatePayload
    ) async throws -> ContainerizationHelperResolvedProcess {
        let image = try await imageStore.get(reference: request.image.reference, pull: false)
        let imageConfiguration = try await image.config(for: .current).config
        var process = imageConfiguration.map(LinuxProcessConfiguration.init(from:)) ?? .init()
        if !request.command.isEmpty {
            process.arguments = request.command
        }
        process.environmentVariables = Self.mergedEnvironment(
            base: process.environmentVariables,
            overrides: request.environment
        )
        return ContainerizationHelperResolvedProcess(
            command: process.arguments,
            environment: Self.environmentEntries(process.environmentVariables),
            workingDirectory: process.workingDirectory,
            user: process.user.username.isEmpty ? nil : process.user.username
        )
    }

    func localImageEvidence(reference: String) async throws -> ContainerizationHelperImageEvidence {
        let image = try await imageStore.get(reference: reference, pull: false)
        let variant = try await image.descriptor(for: .current)
        return ContainerizationHelperImageEvidence(
            reference: image.reference,
            descriptorDigest: image.descriptor.digest,
            variantDigest: variant.digest,
            architecture: Platform.current.architecture,
            operatingSystem: Platform.current.os
        )
    }

    func listImages() async throws -> [ContainerizationHelperImageRecord] {
        let images = try await imageStore.list()
        var byDigest: [String: ContainerizationHelperImageRecord] = [:]
        for image in images.sorted(by: { $0.reference < $1.reference }) {
            try Task.checkCancellation()
            guard let variant = try? await image.descriptor(for: .current) else { continue }
            let evidence = ContainerizationHelperImageEvidence(
                reference: image.reference,
                descriptorDigest: image.descriptor.digest,
                variantDigest: variant.digest,
                architecture: Platform.current.architecture,
                operatingSystem: Platform.current.os
            )
            if let current = byDigest[image.descriptor.digest] {
                byDigest[image.descriptor.digest] = ContainerizationHelperImageRecord(
                    evidence: current.evidence,
                    references: (current.references + [image.reference]).sorted()
                )
            } else {
                byDigest[image.descriptor.digest] = ContainerizationHelperImageRecord(
                    evidence: evidence,
                    references: [image.reference]
                )
            }
        }
        return byDigest.values.sorted { $0.evidence.descriptorDigest < $1.evidence.descriptorDigest }
    }

    func create(_ record: ContainerizationHelperPersistedRecord) async throws {
        guard containers[record.resourceIdentifier] == nil else {
            throw ContainerizationHelperBackendError.conflict("resource already has a live VM")
        }
        let container = try await makeContainer(record, useExistingRootfs: false)
        do {
            try Task.checkCancellation()
            try await container.create()
            try Task.checkCancellation()
            containers[record.resourceIdentifier] = container
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func start(_ record: ContainerizationHelperPersistedRecord) async throws {
        let container: LinuxContainer
        if let current = containers[record.resourceIdentifier] {
            container = current
        } else {
            container = try await makeContainer(record, useExistingRootfs: true)
            try await container.create()
            containers[record.resourceIdentifier] = container
        }
        do {
            try Task.checkCancellation()
            try await container.start()
            try Task.checkCancellation()
        } catch {
            try? await container.stop()
            containers.removeValue(forKey: record.resourceIdentifier)
            throw error
        }
    }

    func restart(_ record: ContainerizationHelperPersistedRecord) async throws {
        guard let current = containers.removeValue(forKey: record.resourceIdentifier) else {
            throw ContainerizationHelperBackendError.conflict("resource has no live VM")
        }
        try await current.stop()
        try Task.checkCancellation()
        let replacement = try await makeContainer(record, useExistingRootfs: true)
        do {
            try await replacement.create()
            try Task.checkCancellation()
            try await replacement.start()
            try Task.checkCancellation()
            containers[record.resourceIdentifier] = replacement
        } catch {
            try? await replacement.stop()
            throw error
        }
    }

    func stop(_ record: ContainerizationHelperPersistedRecord) async throws {
        guard let container = containers.removeValue(forKey: record.resourceIdentifier) else { return }
        try await container.stop()
    }

    func delete(_ record: ContainerizationHelperPersistedRecord) async throws {
        if let container = containers.removeValue(forKey: record.resourceIdentifier) {
            try await container.stop()
        }
        var copy = manager
        let root = imageStore.path
            .appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(record.resourceIdentifier, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try copy.delete(record.resourceIdentifier)
            manager = copy
        }
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw ContainerizationHelperBackendError.executionFailed("managed files remain")
        }
    }

    func usage(resourceIdentifier: String) async throws -> ContainerizationHelperResourceUsage {
        guard let container = containers[resourceIdentifier] else {
            throw ContainerizationHelperBackendError.conflict("resource has no live VM")
        }
        let stats = try await container.statistics()
        return ContainerizationHelperResourceUsage(
            resourceIdentifier: resourceIdentifier,
            cpuUsageMicroseconds: stats.cpu?.usageUsec ?? 0,
            memoryUsageBytes: stats.memory?.usageBytes ?? 0,
            memoryLimitBytes: stats.memory?.limitBytes ?? container.memoryInBytes,
            networkReceiveBytes: Self.saturatingSum(stats.networks?.map(\.receivedBytes) ?? []),
            networkTransmitBytes: Self.saturatingSum(stats.networks?.map(\.transmittedBytes) ?? []),
            blockReadBytes: Self.saturatingSum(stats.blockIO?.devices.map(\.readBytes) ?? []),
            blockWriteBytes: Self.saturatingSum(stats.blockIO?.devices.map(\.writeBytes) ?? []),
            processCount: Int(min(stats.process?.current ?? 0, UInt64(Int.max)))
        )
    }

    func shutdown() async {
        let active = containers.values
        containers.removeAll()
        for container in active {
            try? await container.stop()
        }
    }

    private func makeContainer(
        _ record: ContainerizationHelperPersistedRecord,
        useExistingRootfs: Bool
    ) async throws -> LinuxContainer {
        let image = try await imageStore.get(reference: record.image.reference, pull: false)
        let writer = try stateStore.logWriter(resourceIdentifier: record.resourceIdentifier)
        var copy = manager
        let container: LinuxContainer
        if useExistingRootfs {
            let rootfsURL = imageStore.path
                .appendingPathComponent("containers", isDirectory: true)
                .appendingPathComponent(record.resourceIdentifier, isDirectory: true)
                .appendingPathComponent("rootfs.ext4", isDirectory: false)
            _ = try ContainerizationHelperStateStore.requirePrivateRegularFile(rootfsURL)
            let rootfs = Containerization.Mount.block(
                format: "ext4",
                source: rootfsURL.path,
                destination: "/",
                options: []
            )
            container = try await copy.create(
                record.resourceIdentifier,
                image: image,
                rootfs: rootfs,
                networking: false
            ) { process in
                Self.configure(&process, record: record, writer: writer)
            }
        } else {
            container = try await copy.create(
                record.resourceIdentifier,
                image: image,
                rootfsSizeInBytes: configuration.rootfsSizeBytes,
                networking: false
            ) { process in
                Self.configure(&process, record: record, writer: writer)
            }
            let containerRoot = imageStore.path
                .appendingPathComponent("containers", isDirectory: true)
                .appendingPathComponent(record.resourceIdentifier, isDirectory: true)
            let rootfsURL = containerRoot.appendingPathComponent("rootfs.ext4", isDirectory: false)
            guard chmod(containerRoot.path, S_IRWXU) == 0,
                  chmod(rootfsURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw ContainerizationHelperPersistenceError.operationFailed
            }
        }
        manager = copy
        return container
    }

    private static func configure(
        _ configuration: inout LinuxContainer.Configuration,
        record: ContainerizationHelperPersistedRecord,
        writer: any Writer
    ) {
        configuration.process.arguments = record.command
        configuration.process.environmentVariables = record.environment.map { "\($0.name)=\($0.value)" }
        configuration.process.workingDirectory = record.workingDirectory ?? "/"
        if let user = record.user {
            configuration.process.user = User(username: user)
        }
        configuration.process.stdout = writer
        configuration.process.stderr = writer
    }

    private static func requireInitImage(
        configuration: ContainerizationHelperConfiguration,
        imageStore: ImageStore
    ) async throws -> Containerization.Image {
        var images = try await imageStore.list()
        if !images.contains(where: { $0.reference == configuration.initImageReference }) {
            _ = try await imageStore.load(from: configuration.initImageLayoutURL)
            images = try await imageStore.list()
        }
        guard let image = images.first(where: { $0.reference == configuration.initImageReference }),
              image.descriptor.digest == configuration.initImageDescriptorDigest,
              try await image.descriptor(for: .current).digest == configuration.initImageVariantDigest else {
            throw ContainerizationHelperConfigurationError.assetDigestMismatch
        }
        return image
    }

    private static func mergedEnvironment(
        base: [String],
        overrides: [RuntimeInventoryEnvironmentEntry]
    ) -> [String] {
        var values: [String: String] = [:]
        for entry in base {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                values[String(parts[0])] = String(parts[1])
            }
        }
        for entry in overrides {
            values[entry.name] = entry.value
        }
        return values.keys.sorted().map { "\($0)=\(values[$0]!)" }
    }

    private static func environmentEntries(
        _ values: [String]
    ) -> [RuntimeInventoryEnvironmentEntry] {
        values.compactMap { entry in
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return RuntimeInventoryEnvironmentEntry(name: String(parts[0]), value: String(parts[1]))
        }.sorted { $0.name < $1.name }
    }

    private static func saturatingSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            return overflow ? UInt64.max : result
        }
    }
}

enum ContainerizationHelperCapabilitySnapshot {
    static func make() throws -> RuntimeCapabilitySnapshot {
        let helperFingerprint = try executableFingerprint()
        let protocolFingerprint = SHA256.hash(data: Data("hostwright.containerization-helper.protocol.v1".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: .appleContainerization,
                components: [
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationHelper,
                        version: HostwrightIdentity.version,
                        build: "runtime-provider-v2",
                        fingerprint: helperFingerprint
                    ),
                    RuntimeProviderComponent(
                        identifier: .containerizationHelperProtocolV1,
                        version: RuntimeProviderCapabilityContract.helperProtocolVersion,
                        build: "canonical-json-v1",
                        fingerprint: protocolFingerprint
                    ),
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationFramework,
                        version: ContainerizationHelperConfiguration.frameworkVersion,
                        build: ContainerizationRuntimeAssetContract.frameworkRevision,
                        fingerprint: ContainerizationRuntimeAssetContract.frameworkRevision
                    )
                ],
                minimumMacOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: RuntimeProviderMacOSVersion(
                    major: version.majorVersion,
                    minor: version.minorVersion,
                    patch: version.patchVersion
                ),
                macOSBuild: operatingSystemBuild(),
                architecture: .arm64
            ),
            features: RuntimeProviderFeature.knownValues.map { feature in
                let implemented: Set<RuntimeProviderFeature> = [
                    .observation,
                    .lifecycle,
                    .processControl,
                    .streaming,
                    .images,
                    .cancellation,
                    .timeouts,
                    .errors,
                    .cleanup
                ]
                return implemented.contains(feature)
                    ? RuntimeProviderFeatureStatus(
                        feature: feature,
                        state: .available,
                        reason: .implemented
                    )
                    : RuntimeProviderFeatureStatus(
                        feature: feature,
                        state: .unavailable,
                        reason: .notImplemented
                    )
            }
        )
    }

    private static func executableFingerprint() throws -> String {
        guard let executableURL = Bundle.main.executableURL else {
            throw ContainerizationHelperConfigurationError.unsafeAsset
        }
        let data = try Data(contentsOf: executableURL, options: [.mappedIfSafe])
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func operatingSystemBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
