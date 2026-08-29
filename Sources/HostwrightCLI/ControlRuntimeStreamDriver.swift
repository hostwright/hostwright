import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

public enum ControlRuntimeStreamDriverError: Error, Sendable {
    case stalePreparation
    case unsupportedProvider
    case resourceBindingMismatch
    case logSnapshotTooLarge
}

public struct ControlRuntimeStreamTarget: Codable, Equatable, Sendable {
    public let projectID: String
    public let projectResourceUUID: String
    public let serviceName: String
    public let resourceUUID: String
    public let resourceIdentifier: String
    public let providerID: RuntimeProviderID
    public let resourceGeneration: Int
    public let projectGeneration: Int
    public let providerGeneration: Int
    public let fencingToken: String

    public init(
        projectID: String,
        projectResourceUUID: String,
        serviceName: String,
        resourceUUID: String,
        resourceIdentifier: String,
        providerID: RuntimeProviderID,
        resourceGeneration: Int,
        projectGeneration: Int,
        providerGeneration: Int,
        fencingToken: String
    ) {
        self.projectID = projectID
        self.projectResourceUUID = projectResourceUUID
        self.serviceName = serviceName
        self.resourceUUID = resourceUUID
        self.resourceIdentifier = resourceIdentifier
        self.providerID = providerID
        self.resourceGeneration = resourceGeneration
        self.projectGeneration = projectGeneration
        self.providerGeneration = providerGeneration
        self.fencingToken = fencingToken
    }

    public func validate() throws {
        guard !projectID.isEmpty, projectID.utf8.count <= 256,
              !serviceName.isEmpty, serviceName.utf8.count <= 128,
              !resourceIdentifier.isEmpty, resourceIdentifier.utf8.count <= 512,
              HostwrightResourceUUID.isValid(projectResourceUUID),
              HostwrightResourceUUID.isValid(resourceUUID),
              HostwrightResourceUUID.isValid(fencingToken),
              resourceGeneration > 0, projectGeneration >= 0,
              providerGeneration > 0 else {
            throw ControlRuntimeStreamDriverError.resourceBindingMismatch
        }
    }
}

public struct ControlRuntimeStreamTargetResolver: Sendable {
    private let environment: CLIEnvironment

    public init(environment: CLIEnvironment = .live) {
        self.environment = environment
    }

    public func resolve(options: InteractiveCLIOptions) throws -> ControlRuntimeStreamTarget {
        let manifestText = try hostwrightReadManifestText(
            path: options.manifestPath,
            environment: environment
        )
        let manifest = try hostwrightValidatedManifest(
            text: manifestText,
            teamProfilePath: nil,
            environment: environment
        ).manifest
        guard let projectName = manifest.project, !projectName.isEmpty else {
            throw InteractiveCommandRunnerError.missingProject
        }
        let serviceName = try InteractiveOperationBuilder.requestedService(options)
        guard let service = manifest.services.first(where: { $0.name == serviceName }) else {
            throw InteractiveCommandRunnerError.unknownService(serviceName)
        }
        guard service.replicas == 1 else {
            throw InteractiveCommandRunnerError.replicatedServiceRequiresInstance(serviceName)
        }
        let store = SQLiteStateStore(
            configuration: try hostwrightStateStoreConfiguration(
                explicitPath: options.stateDatabasePath,
                environment: environment
            )
        )
        guard environment.fileExists(store.path) else {
            throw InteractiveCommandRunnerError.missingProjectState(projectName)
        }
        guard try store.schemaVersion() == HostwrightContractVersions.stateSchema else {
            throw InteractiveCommandRunnerError.invalidProjectBinding
        }
        let projectID = "project-\(projectName)"
        let project = try store.desiredStates.loadProject(id: projectID)
        guard project.name == projectName,
              HostwrightResourceUUID.isValid(project.resourceUUID),
              let providerName = project.mutationProvider,
              let providerID = RuntimeProviderBinding.stableID(for: providerName),
              project.providerGeneration > 0 else {
            throw InteractiveCommandRunnerError.invalidProjectBinding
        }
        let ownership = try InteractiveOwnershipResolver.resolve(
            records: store.ownership.loadAll(),
            project: project,
            serviceName: serviceName,
            expectedIdentity: RuntimeServiceIdentity(
                projectName: projectName,
                serviceName: serviceName
            ),
            providerID: providerID
        )
        let target = ControlRuntimeStreamTarget(
            projectID: projectID,
            projectResourceUUID: project.resourceUUID,
            serviceName: serviceName,
            resourceUUID: ownership.resourceUUID,
            resourceIdentifier: ownership.resourceIdentifier,
            providerID: providerID,
            resourceGeneration: ownership.resourceGeneration,
            projectGeneration: ownership.projectGeneration,
            providerGeneration: ownership.providerGeneration,
            fencingToken: ownership.fencingToken
        )
        try target.validate()
        return target
    }
}

public struct ControlRuntimeLogSnapshotReader: Sendable {
    public static let maximumBytes = 1 * 1_024 * 1_024
    private let environment: CLIEnvironment

    public init(environment: CLIEnvironment = .live) { self.environment = environment }

    public func read(
        manifestPath: String,
        stateDatabasePath: String,
        serviceName: String,
        expectedTarget: ControlRuntimeStreamTarget,
        tail: Int
    ) throws -> Data {
        guard (1...1_000).contains(tail) else {
            throw ControlRuntimeStreamDriverError.logSnapshotTooLarge
        }
        let manifestText = try hostwrightReadManifestText(path: manifestPath, environment: environment)
        let manifest = try ManifestValidator.validated(manifestText)
        let mapping = ManifestRuntimeMapper.map(manifest)
        guard let desired = mapping.desiredState.services.first(where: {
            $0.identity.serviceName == serviceName
        }) else { throw ControlRuntimeStreamDriverError.resourceBindingMismatch }
        let store = SQLiteStateStore(
            configuration: StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
        )
        guard try store.schemaVersion() == HostwrightContractVersions.stateSchema else {
            throw ControlRuntimeStreamDriverError.resourceBindingMismatch
        }
        let projectID = "project-\(mapping.desiredState.projectName)"
        let project = try store.desiredStates.loadProject(id: projectID)
        guard project.name == mapping.desiredState.projectName,
              HostwrightResourceUUID.isValid(project.resourceUUID),
              let providerName = project.mutationProvider,
              let providerID = RuntimeProviderBinding.stableID(for: providerName),
              project.providerGeneration > 0 else {
            throw ControlRuntimeStreamDriverError.resourceBindingMismatch
        }
        let ownership = try InteractiveOwnershipResolver.resolve(
            records: store.ownership.loadAll(),
            project: project,
            serviceName: serviceName,
            expectedIdentity: desired.identity,
            providerID: providerID
        )
        guard Self.matches(
            target: expectedTarget,
            projectID: projectID,
            projectResourceUUID: project.resourceUUID,
            providerID: providerID,
            providerGeneration: project.providerGeneration,
            ownership: ownership
        ) else {
            throw ControlRuntimeStreamDriverError.resourceBindingMismatch
        }
        let desiredState = try hostwrightDesiredStateWithOwnershipHints(
            mapping.desiredState,
            store: store,
            projectID: projectID,
            providerID: providerID
        )
        let adapter = try environment.runtimeAdapterForProvider(providerID)
        let capability = try hostwrightWaitForAsync { try await adapter.capabilitySnapshot() }
        guard capability.descriptor.providerID == providerID else {
            throw ControlRuntimeStreamDriverError.resourceBindingMismatch
        }
        let observed = try hostwrightWaitForAsync { try await adapter.observe(desiredState: desiredState) }
        let matches = observed.services.filter {
            $0.identity == desired.identity && $0.resourceIdentifier == ownership.resourceIdentifier
        }
        guard matches.count == 1, let service = matches.first else {
            throw ControlRuntimeStreamDriverError.resourceBindingMismatch
        }
        let inventory = try hostwrightWaitForAsync { try await adapter.inventory() }
        _ = try InteractiveOwnershipResolver.verifyLiveInventory(
            inventory,
            ownership: ownership,
            project: project,
            providerID: providerID,
            serviceName: serviceName
        )
        let freshInventory = try hostwrightWaitForAsync { try await adapter.inventory() }
        _ = try InteractiveOwnershipResolver.verifyLiveInventory(
            freshInventory,
            ownership: ownership,
            project: project,
            providerID: providerID,
            serviceName: serviceName
        )
        guard freshInventory.semanticSHA256 == inventory.semanticSHA256 else {
            throw ControlRuntimeStreamDriverError.stalePreparation
        }
        let result = try hostwrightWaitForAsync { try await adapter.logs(for: service, tail: tail) }
        let data = Data(RuntimeRedactionPolicy.default.redact(result.text).utf8)
        guard data.count <= Self.maximumBytes else {
            throw ControlRuntimeStreamDriverError.logSnapshotTooLarge
        }
        return data
    }

    private static func matches(
        target: ControlRuntimeStreamTarget,
        projectID: String,
        projectResourceUUID: String,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        ownership: OwnershipRecord
    ) -> Bool {
        target.projectID == projectID
            && target.projectResourceUUID == projectResourceUUID
            && target.serviceName == ownership.serviceName
            && target.resourceUUID == ownership.resourceUUID
            && target.resourceIdentifier == ownership.resourceIdentifier
            && target.providerID == providerID
            && target.resourceGeneration == ownership.resourceGeneration
            && target.projectGeneration == ownership.projectGeneration
            && target.providerGeneration == providerGeneration
            && target.providerGeneration == ownership.providerGeneration
            && target.fencingToken == ownership.fencingToken
    }
}

public final class ControlRuntimeStreamTask: @unchecked Sendable {
    public typealias Completion = @Sendable (Result<RuntimeInteractiveExecutionResult, Error>) -> Void

    private let preparation: InteractiveLivePreparation
    private let options: InteractiveCLIOptions
    private let environment: CLIEnvironment
    private let control = RuntimeInteractiveProcessControl()
    private let queue = DispatchQueue(label: "dev.hostwright.control.runtime-stream")
    private let lock = NSLock()
    private var started = false

    init(preparation: InteractiveLivePreparation, options: InteractiveCLIOptions, environment: CLIEnvironment) {
        self.preparation = preparation
        self.options = options
        self.environment = environment
        if !options.forwardsStandardInput { control.finishInput() }
    }

    public func start(
        beforeExternalExecution: @escaping @Sendable () throws -> Void,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void,
        completion: @escaping Completion
    ) throws {
        let mayStart = lock.withLock { () -> Bool in
            if started { return false }
            started = true
            return true
        }
        guard mayStart else { throw ControlRuntimeStreamDriverError.stalePreparation }
        queue.async { [self] in
            do {
                let fresh = try InteractiveLiveDriver(
                    environment: self.environment, connectsStandardIO: false
                ).prepare(options: self.options)
                guard fresh == self.preparation else {
                    throw ControlRuntimeStreamDriverError.stalePreparation
                }
                let executor = try Self.executor(for: self.preparation.providerID)
                try beforeExternalExecution()
                let result = try hostwrightWaitForAsync { [self] in
                    try await executor.execute(
                        self.preparation.operation,
                        capabilitySnapshot: self.preparation.capabilitySnapshot,
                        timeoutMilliseconds: self.options.timeoutSeconds * 1_000,
                        control: self.control,
                        sink: sink
                    )
                }
                let resultPayload = try JSONSerialization.data(
                    withJSONObject: [
                        "exitStatus": Int(result.exitStatus),
                        "kind": "cli-stream-result",
                        "schemaVersion": 1,
                    ],
                    options: [.sortedKeys]
                )
                try sink(
                    RuntimeStreamEnvelope(
                        sequence: UInt64(result.emittedFrameCount) + 1,
                        stream: .control,
                        payload: resultPayload,
                        endOfStream: true
                    )
                )
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func cancel() { control.cancel() }
    public func sendInput(
        _ data: Data,
        onConsumed: @escaping @Sendable () -> Void
    ) -> Bool {
        control.sendInput(data, onConsumed: onConsumed)
    }
    public func finishInput() { control.finishInput() }
    public func resize(columns: UInt16, rows: UInt16) -> Bool {
        control.resizeTTY(columns: columns, rows: rows)
    }
    public func forward(signal: Int32) -> Bool { control.forward(signal: signal) }

    private static func executor(
        for providerID: RuntimeProviderID
    ) throws -> any InteractiveRuntimeExecuting {
        switch providerID {
        case .appleContainerCLI:
            return AppleContainerInteractiveExecutor()
        case .appleContainerization:
            let configuration = try ContainerizationHelperClientConfiguration.installed()
            return ContainerizationHelperInteractiveExecutor(
                client: ContainerizationHelperClient(configuration: configuration)
            )
        default:
            throw ControlRuntimeStreamDriverError.unsupportedProvider
        }
    }
}

public struct ControlRuntimeStreamDriver: Sendable {
    private let environment: CLIEnvironment

    public init(environment: CLIEnvironment = .live) {
        self.environment = environment
    }

    public func prepare(
        options: InteractiveCLIOptions,
        expectedTarget: ControlRuntimeStreamTarget
    ) throws -> ControlRuntimeStreamTask {
        let driver = InteractiveLiveDriver(environment: environment, connectsStandardIO: false)
        let initial = try driver.prepare(options: options)
        let fresh = try driver.prepare(options: options)
        guard initial == fresh else { throw ControlRuntimeStreamDriverError.stalePreparation }
        try expectedTarget.validate()
        guard fresh.projectID == expectedTarget.projectID,
              fresh.projectResourceUUID == expectedTarget.projectResourceUUID,
              fresh.providerID == expectedTarget.providerID,
              fresh.providerGeneration == expectedTarget.providerGeneration,
              fresh.ownership.serviceName == expectedTarget.serviceName,
              fresh.ownership.resourceUUID == expectedTarget.resourceUUID,
              fresh.ownership.resourceIdentifier == expectedTarget.resourceIdentifier,
              fresh.ownership.resourceGeneration == expectedTarget.resourceGeneration,
              fresh.ownership.projectGeneration == expectedTarget.projectGeneration,
              fresh.ownership.providerGeneration == expectedTarget.providerGeneration,
              fresh.ownership.fencingToken == expectedTarget.fencingToken else {
            throw ControlRuntimeStreamDriverError.resourceBindingMismatch
        }
        return ControlRuntimeStreamTask(preparation: fresh, options: options, environment: environment)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
