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

public struct ControlRuntimeLogSnapshotReader: Sendable {
    public static let maximumBytes = 1 * 1_024 * 1_024
    private let environment: CLIEnvironment

    public init(environment: CLIEnvironment = .live) { self.environment = environment }

    public func read(
        manifestPath: String,
        stateDatabasePath: String,
        serviceName: String,
        expectedResourceUUID: String,
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
        guard ownership.resourceUUID == expectedResourceUUID else {
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
        expectedResourceUUID: String
    ) throws -> ControlRuntimeStreamTask {
        let driver = InteractiveLiveDriver(environment: environment, connectsStandardIO: false)
        let initial = try driver.prepare(options: options)
        let fresh = try driver.prepare(options: options)
        guard initial == fresh else { throw ControlRuntimeStreamDriverError.stalePreparation }
        guard fresh.ownership.resourceUUID == expectedResourceUUID else {
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
