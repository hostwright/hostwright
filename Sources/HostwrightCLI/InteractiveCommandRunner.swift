import Darwin
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightRuntime
import HostwrightState

enum InteractiveCommandRunnerError: Error, Equatable, Sendable {
    case missingProject
    case unknownService(String)
    case replicatedServiceRequiresInstance(String)
    case missingProjectState(String)
    case invalidProjectBinding
    case missingManagedResource(String)
    case ambiguousManagedResource(String)
    case runtimeOwnershipMismatch(String)
    case workloadNotRunning(String)
    case invalidCopyEndpoints
    case invalidHostPath

    var diagnostic: HostwrightDiagnostic {
        switch self {
        case .missingProject:
            return HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "Interactive operations require an explicit manifest project. No runtime operation was attempted."
            )
        case .unknownService(let service):
            return HostwrightDiagnostic(
                code: .commandUsage,
                message: "Manifest does not declare service '\(service)'. No runtime operation was attempted."
            )
        case .replicatedServiceRequiresInstance(let service):
            return HostwrightDiagnostic(
                code: .commandUsage,
                message: "Service '\(service)' has multiple replicas; an exact instance selector is required before an interactive operation can be authorized. No runtime operation was attempted."
            )
        case .missingProjectState(let project):
            return HostwrightDiagnostic(
                code: .stateStoreUnavailable,
                message: "Project '\(project)' has no durable Hostwright state. Run the lifecycle command first; no runtime operation was attempted."
            )
        case .invalidProjectBinding:
            return HostwrightDiagnostic(
                code: .unsafeExposure,
                message: "The manifest, project UUID, provider binding, and provider generation do not form one exact durable identity. No runtime operation was attempted."
            )
        case .missingManagedResource(let service):
            return HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message: "Service '\(service)' has no exact UUID-backed managed resource. No runtime operation was attempted."
            )
        case .ambiguousManagedResource(let service):
            return HostwrightDiagnostic(
                code: .unsafeExposure,
                message: "Service '\(service)' does not resolve to exactly one UUID-backed managed resource. No runtime operation was attempted."
            )
        case .runtimeOwnershipMismatch(let service):
            return HostwrightDiagnostic(
                code: .unsafeExposure,
                message: "Live runtime ownership for service '\(service)' does not match Hostwright's UUID, generation, provider, and fence evidence. No runtime operation was attempted."
            )
        case .workloadNotRunning(let service):
            return HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message: "Service '\(service)' is not running. Attach never starts a workload outside the Hostwright lifecycle saga; no runtime operation was attempted."
            )
        case .invalidCopyEndpoints:
            return HostwrightDiagnostic(
                code: .commandUsage,
                message: "Copy requires exactly one service:/absolute/container/path endpoint and one normalized absolute host path."
            )
        case .invalidHostPath:
            return HostwrightDiagnostic(
                code: .unsafeExposure,
                message: "The requested host path is not an absolute normalized path beneath an existing parent directory. No runtime operation was attempted."
            )
        }
    }
}

protocol InteractiveCommandDriving: Sendable {
    func execute(
        options: InteractiveCLIOptions,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) throws -> RuntimeInteractiveExecutionResult
}

protocol InteractiveRuntimeExecuting: Sendable {
    func execute(
        _ operation: RuntimeInteractiveOperation,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        timeoutMilliseconds: Int,
        control: RuntimeInteractiveProcessControl,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) async throws -> RuntimeInteractiveExecutionResult
}

extension AppleContainerInteractiveExecutor: InteractiveRuntimeExecuting {}
extension ContainerizationHelperInteractiveExecutor:
    InteractiveRuntimeExecuting {}

struct InteractiveCommandRunner: Sendable {
    typealias LiveStreamSink = @Sendable (
        RuntimeStreamEnvelope,
        CLIOutputFormat
    ) throws -> Void

    let options: InteractiveCLIOptions
    let driver: any InteractiveCommandDriving
    let liveStreamSink: LiveStreamSink?

    init(options: InteractiveCLIOptions, environment: CLIEnvironment) {
        self.init(
            options: options,
            driver: InteractiveLiveDriver(
                environment: environment,
                connectsStandardIO: true
            ),
            liveStreamSink: InteractiveStandardOutput.write
        )
    }

    init(options: InteractiveCLIOptions, driver: any InteractiveCommandDriving) {
        self.init(options: options, driver: driver, liveStreamSink: nil)
    }

    init(
        options: InteractiveCLIOptions,
        driver: any InteractiveCommandDriving,
        liveStreamSink: LiveStreamSink?
    ) {
        self.options = options
        self.driver = driver
        self.liveStreamSink = liveStreamSink
    }

    func run() -> CLIRunResult {
        let output = InteractiveOutputBuffer(format: options.output)
        do {
            _ = try driver.execute(options: options) { envelope in
                if let liveStreamSink {
                    try liveStreamSink(envelope, options.output)
                } else {
                    try output.append(envelope)
                }
            }
            return liveStreamSink == nil ? output.result() : CLIRunResult()
        } catch let error as InteractiveCommandRunnerError {
            return failure(error.diagnostic)
        } catch let diagnostic as HostwrightDiagnostic {
            return failure(diagnostic)
        } catch let error as ManifestParseError {
            if options.output == .json {
                return CLIRunResult(
                    standardError: CLIJSON.manifestError(
                        issues: error.issues,
                        exitCode: .validation
                    ),
                    exitCode: CLIExitCode.validation.rawValue
                )
            }
            return CLIRunResult(
                standardError: error.issues.map(\.rendered).joined(separator: "\n") + "\n",
                exitCode: CLIExitCode.validation.rawValue
            )
        } catch let error as RuntimeProviderSelectionError {
            return failure(
                HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message: "Runtime provider selection failed: \(error). \(error.guidance) No runtime operation was attempted."
                )
            )
        } catch let error as RuntimeInteractiveError {
            return failure(interactiveDiagnostic(error))
        } catch let error as StateStoreError {
            return failure(
                HostwrightDiagnostic(
                    code: .stateStoreUnavailable,
                    message: "\(redact(error)). No runtime operation was attempted."
                )
            )
        } catch {
            return failure(
                HostwrightDiagnostic(
                    code: .partialFailure,
                    message: redact(error)
                )
            )
        }
    }

    private func failure(_ diagnostic: HostwrightDiagnostic) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: diagnostic.code)
        if options.output == .json {
            return CLIRunResult(
                standardError: CLIJSON.error(
                    code: diagnostic.code,
                    message: diagnostic.message,
                    exitCode: exitCode
                ),
                exitCode: exitCode.rawValue
            )
        }
        return CLIRunResult(
            standardError: "\(diagnostic.code.rawValue): \(diagnostic.message)\n",
            exitCode: exitCode.rawValue
        )
    }

    private func interactiveDiagnostic(
        _ error: RuntimeInteractiveError
    ) -> HostwrightDiagnostic {
        switch error {
        case .capabilityUnavailable(_, let reason):
            return HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message: "\(RuntimeRedactionPolicy.default.redact(reason)) No runtime operation was attempted."
            )
        case .invalidResourceIdentifier,
             .invalidProcessArguments,
             .invalidContainerPath,
             .invalidHostPath:
            return HostwrightDiagnostic(
                code: .commandUsage,
                message: "\(redact(error)). No runtime operation was attempted."
            )
        case .unsafeHostPath, .unsafeArchive:
            return HostwrightDiagnostic(
                code: .unsafeExposure,
                message: "\(redact(error))."
            )
        case .processTimedOut, .processCancelled, .processTreeCleanupFailed:
            return HostwrightDiagnostic(
                code: .partialFailure,
                message: "\(redact(error)). The executor applied bounded process-tree cleanup."
            )
        case .streamFrameTooLarge:
            return HostwrightDiagnostic(
                code: .partialFailure,
                message: "Interactive output exceeded the bounded 8 MiB CLI result limit; the runtime process tree was cancelled and cleaned up."
            )
        default:
            return HostwrightDiagnostic(
                code: .partialFailure,
                message: redact(error)
            )
        }
    }

    private func redact(_ error: Error) -> String {
        RuntimeRedactionPolicy.default.redact(String(describing: error))
    }
}

private enum InteractiveStandardOutput {
    static func write(
        _ envelope: RuntimeStreamEnvelope,
        format: CLIOutputFormat
    ) throws {
        let data: Data
        let descriptor: Int32
        if format == .json {
            data = try envelope.ndjsonLine()
            descriptor = STDOUT_FILENO
        } else {
            guard !envelope.endOfStream, !envelope.payload.isEmpty else { return }
            data = envelope.payload
            descriptor = envelope.stream == .standardError
                ? STDERR_FILENO
                : STDOUT_FILENO
        }
        try writeAll(data, to: descriptor)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            throw RuntimeInteractiveError.processIOFailed(count < 0 ? errno : EIO)
        }
    }
}

final class InteractiveStandardIOSession: @unchecked Sendable {
    private static let forwardedSignals = [
        SIGHUP,
        SIGINT,
        SIGQUIT,
        SIGTERM,
        SIGWINCH
    ]

    private let control: RuntimeInteractiveProcessControl
    private let terminal: Bool
    private let inputDescriptor: Int32
    private let installsSignalHandlers: Bool
    private let lock = NSLock()
    private let inputGroup = DispatchGroup()
    private let inputQueue = DispatchQueue(
        label: "dev.hostwright.interactive.stdin",
        qos: .userInitiated
    )
    private let signalQueue = DispatchQueue(
        label: "dev.hostwright.interactive.signals",
        qos: .userInitiated
    )
    private var signalSources: [DispatchSourceSignal] = []
    private var previousSignalHandlers: [(Int32, sig_t?)] = []
    private var savedTerminalAttributes: termios?
    private var failure: RuntimeInteractiveError?
    private var started = false
    private var stopped = false

    init(
        control: RuntimeInteractiveProcessControl,
        forwardsStandardInput: Bool,
        terminal: Bool,
        standardInputDescriptor: Int32 = STDIN_FILENO,
        installsSignalHandlers: Bool = true
    ) throws {
        self.control = control
        self.terminal = terminal
        self.installsSignalHandlers = installsSignalHandlers
        if forwardsStandardInput {
            let descriptor = dup(standardInputDescriptor)
            guard descriptor >= 0 else {
                throw RuntimeInteractiveError.processIOFailed(errno)
            }
            inputDescriptor = descriptor
        } else {
            inputDescriptor = -1
        }
    }

    deinit {
        stop()
    }

    func start() throws {
        let shouldStart = lock.withLock {
            guard !started, !stopped else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        if installsSignalHandlers {
            previousSignalHandlers.append(
                (SIGPIPE, Darwin.signal(SIGPIPE, SIG_IGN))
            )
            for signalNumber in Self.forwardedSignals {
                previousSignalHandlers.append(
                    (signalNumber, Darwin.signal(signalNumber, SIG_IGN))
                )
                let source = DispatchSource.makeSignalSource(
                    signal: signalNumber,
                    queue: signalQueue
                )
                source.setEventHandler { [weak self] in
                    self?.handle(signal: signalNumber)
                }
                source.resume()
                signalSources.append(source)
            }
        }

        if terminal, isatty(STDIN_FILENO) == 1 {
            var current = termios()
            guard tcgetattr(STDIN_FILENO, &current) == 0 else {
                stop()
                throw RuntimeInteractiveError.processIOFailed(errno)
            }
            var raw = current
            cfmakeraw(&raw)
            guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
                stop()
                throw RuntimeInteractiveError.processIOFailed(errno)
            }
            savedTerminalAttributes = current
            updateTerminalSize()
        }

        if inputDescriptor >= 0 {
            inputGroup.enter()
            inputQueue.async { [self] in
                readStandardInput()
                inputGroup.leave()
            }
        }
    }

    func stop() {
        let shouldStop = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }

        for source in signalSources {
            source.setEventHandler {}
            source.cancel()
        }
        signalSources.removeAll()
        if installsSignalHandlers {
            for (signalNumber, handler) in previousSignalHandlers.reversed() {
                Darwin.signal(signalNumber, handler)
            }
            previousSignalHandlers.removeAll()
        }

        if var savedTerminalAttributes {
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &savedTerminalAttributes)
            self.savedTerminalAttributes = nil
        }
        if inputDescriptor >= 0 {
            _ = inputGroup.wait(timeout: .now() + 1)
            close(inputDescriptor)
        }
    }

    func throwIfFailed() throws {
        if let failure = lock.withLock({ failure }) {
            throw failure
        }
    }

    private func readStandardInput() {
        var pending = Data()
        while !isStopped, !control.isCancelled {
            if !pending.isEmpty {
                if control.sendInput(pending) {
                    pending.removeAll(keepingCapacity: true)
                } else {
                    usleep(5_000)
                }
                continue
            }

            var descriptor = pollfd(
                fd: inputDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, 50)
            if pollResult == 0 {
                continue
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                failInput(errno)
                return
            }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                failInput(EBADF)
                return
            }

            var bytes = [UInt8](
                repeating: 0,
                count: RuntimeStreamEnvelope.maximumChunkBytes
            )
            let count = Darwin.read(inputDescriptor, &bytes, bytes.count)
            if count > 0 {
                pending = Data(bytes.prefix(count))
                continue
            }
            if count == 0 {
                control.finishInput()
                return
            }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            failInput(errno)
            return
        }
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    private func failInput(_ errorNumber: Int32) {
        lock.withLock {
            failure = .processIOFailed(errorNumber)
        }
        control.cancel()
    }

    private func handle(signal signalNumber: Int32) {
        if signalNumber == SIGWINCH {
            updateTerminalSize()
        } else if !control.forward(signal: signalNumber) {
            control.cancel()
        }
    }

    private func updateTerminalSize() {
        guard terminal else { return }
        var window = winsize()
        guard ioctl(STDIN_FILENO, TIOCGWINSZ, &window) == 0,
              window.ws_col > 0,
              window.ws_row > 0 else {
            return
        }
        _ = control.resizeTTY(columns: window.ws_col, rows: window.ws_row)
    }
}

struct InteractiveLivePreparation: Equatable, Sendable {
    let operation: RuntimeInteractiveOperation
    let capabilitySnapshot: RuntimeCapabilitySnapshot
    let providerID: RuntimeProviderID
    let capabilitySHA256: String
    let projectID: String
    let projectResourceUUID: String
    let providerGeneration: Int
    let ownership: OwnershipRecord
    let inventorySHA256: String
}

struct InteractiveLiveDriver: InteractiveCommandDriving {
    let environment: CLIEnvironment
    let executor: (any InteractiveRuntimeExecuting)?
    let connectsStandardIO: Bool

    init(
        environment: CLIEnvironment,
        executor: (any InteractiveRuntimeExecuting)? = nil,
        connectsStandardIO: Bool = false
    ) {
        self.environment = environment
        self.executor = executor
        self.connectsStandardIO = connectsStandardIO
    }

    func execute(
        options: InteractiveCLIOptions,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) throws -> RuntimeInteractiveExecutionResult {
        let initial = try prepare(options: options)
        let fresh = try prepare(options: options)
        guard initial == fresh else {
            throw RuntimeProviderSelectionError.staleCapability(
                expectedSHA256: initial.capabilitySHA256,
                currentSHA256: fresh.capabilitySHA256
            )
        }

        let control = RuntimeInteractiveProcessControl()
        if !options.forwardsStandardInput {
            control.finishInput()
        }
        let standardIOSession = connectsStandardIO
            ? try InteractiveStandardIOSession(
                control: control,
                forwardsStandardInput: options.forwardsStandardInput,
                terminal: options.terminal
            )
            : nil
        try standardIOSession?.start()
        defer { standardIOSession?.stop() }
        do {
            let runtimeExecutor = try executor(for: fresh.providerID)
            let result = try hostwrightWaitForAsync {
                try await runtimeExecutor.execute(
                    fresh.operation,
                    capabilitySnapshot: fresh.capabilitySnapshot,
                    timeoutMilliseconds: options.timeoutSeconds * 1_000,
                    control: control,
                    sink: sink
                )
            }
            try standardIOSession?.throwIfFailed()
            return result
        } catch {
            try standardIOSession?.throwIfFailed()
            throw error
        }
    }

    private func executor(
        for providerID: RuntimeProviderID
    ) throws -> any InteractiveRuntimeExecuting {
        if let executor {
            return executor
        }
        switch providerID {
        case .appleContainerCLI:
            return AppleContainerInteractiveExecutor()
        case .appleContainerization:
            let configuration =
                try ContainerizationHelperClientConfiguration.installed()
            return ContainerizationHelperInteractiveExecutor(
                client: ContainerizationHelperClient(
                    configuration: configuration
                )
            )
        default:
            throw RuntimeProviderSelectionError.providerUnavailable(providerID)
        }
    }

    func prepare(options: InteractiveCLIOptions) throws -> InteractiveLivePreparation {
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
        try store.migrate()
        guard try store.schemaVersion() == HostwrightContractVersions.stateSchema else {
            throw InteractiveCommandRunnerError.invalidProjectBinding
        }
        let projectID = "project-\(projectName)"
        let project: StateProjectRecord
        do {
            project = try store.desiredStates.loadProject(id: projectID)
        } catch StateStoreError.notFound(_) {
            throw InteractiveCommandRunnerError.missingProjectState(projectName)
        }
        guard project.name == projectName,
              HostwrightResourceUUID.isValid(project.resourceUUID),
              let persistedProvider = project.mutationProvider,
              let boundProviderID = RuntimeProviderBinding.stableID(for: persistedProvider),
              project.providerGeneration > 0 else {
            throw InteractiveCommandRunnerError.invalidProjectBinding
        }

        let operationKind = try InteractiveOperationBuilder.operationKind(options)
        let selected = try hostwrightSelectRuntimeProvider(
            requested: options.runtimeProvider,
            store: store,
            projectID: projectID,
            requiredFeatures: InteractiveOperationBuilder.requiredFeatures(operationKind),
            environment: environment
        )
        let providerID = selected.selection.providerID
        guard providerID == boundProviderID else {
            throw InteractiveCommandRunnerError.invalidProjectBinding
        }
        let capability = try hostwrightWaitForAsync {
            try await selected.adapter.capabilitySnapshot()
        }
        guard capability.descriptor.providerID == providerID else {
            throw InteractiveCommandRunnerError.invalidProjectBinding
        }
        try RuntimeProviderSelector.requireFreshCapability(
            expectedSHA256: selected.selection.capabilitySHA256,
            currentSnapshot: capability
        )
        try RuntimeInteractiveCapabilityContract(snapshot: capability).require(operationKind)

        let expectedIdentity = RuntimeServiceIdentity(
            projectName: projectName,
            serviceName: serviceName
        )
        let ownership = try InteractiveOwnershipResolver.resolve(
            records: store.ownership.loadAll(),
            project: project,
            serviceName: serviceName,
            expectedIdentity: expectedIdentity,
            providerID: providerID
        )
        let inventory = try hostwrightWaitForAsync {
            try await selected.adapter.inventory()
        }
        let liveContainer = try InteractiveOwnershipResolver.verifyLiveInventory(
            inventory,
            ownership: ownership,
            project: project,
            providerID: providerID,
            serviceName: serviceName
        )
        if operationKind == .attach, liveContainer.lifecycle != .running {
            throw InteractiveCommandRunnerError.workloadNotRunning(serviceName)
        }
        let operation = try InteractiveOperationBuilder.build(
            options,
            resourceIdentifier: ownership.resourceIdentifier,
            workingDirectory: service.workdir
        )
        guard operation.kind == operationKind else {
            throw InteractiveCommandRunnerError.invalidCopyEndpoints
        }
        return InteractiveLivePreparation(
            operation: operation,
            capabilitySnapshot: capability,
            providerID: providerID,
            capabilitySHA256: capability.canonicalSHA256,
            projectID: projectID,
            projectResourceUUID: project.resourceUUID,
            providerGeneration: project.providerGeneration,
            ownership: ownership,
            inventorySHA256: inventory.semanticSHA256
        )
    }
}

enum InteractiveOwnershipResolver {
    static func resolve(
        records: [OwnershipRecord],
        project: StateProjectRecord,
        serviceName: String,
        expectedIdentity: RuntimeServiceIdentity,
        providerID: RuntimeProviderID
    ) throws -> OwnershipRecord {
        let candidates = records.filter {
            $0.resourceType == "container" &&
                $0.projectID == project.id &&
                $0.serviceName == serviceName &&
                RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) == providerID
        }
        guard !candidates.isEmpty else {
            throw InteractiveCommandRunnerError.missingManagedResource(serviceName)
        }
        guard candidates.count == 1, let record = candidates.first else {
            throw InteractiveCommandRunnerError.ambiguousManagedResource(serviceName)
        }
        guard record.identityVersion == 1 ||
                record.identityVersion == RuntimeManagedResourceIdentity.currentVersion,
              record.resourceIdentifier == expectedIdentity.managedResourceIdentifier ||
                record.resourceIdentifier == expectedIdentity.legacyManagedResourceIdentifier,
              RuntimeManagedResourceIdentity.isSupportedIdentifier(record.resourceIdentifier),
              HostwrightResourceUUID.isValid(record.resourceUUID),
              record.resourceGeneration > 0,
              record.projectResourceUUID == project.resourceUUID,
              record.projectGeneration > 0,
              record.providerGeneration == project.providerGeneration,
              HostwrightResourceUUID.isValid(record.fencingToken) else {
            throw InteractiveCommandRunnerError.ambiguousManagedResource(serviceName)
        }
        return record
    }

    static func verifyLiveInventory(
        _ inventory: RuntimeInventory,
        ownership: OwnershipRecord,
        project: StateProjectRecord,
        providerID: RuntimeProviderID,
        serviceName: String
    ) throws -> RuntimeInventoryContainer {
        let matches = inventory.containers.filter {
            $0.name == ownership.resourceIdentifier
        }
        guard matches.count == 1,
              let live = matches.first,
              let evidence = live.ownership,
              evidence.resourceUUID == ownership.resourceUUID,
              evidence.projectUUID == project.resourceUUID,
              evidence.resourceGeneration == ownership.resourceGeneration,
              evidence.projectGeneration == ownership.projectGeneration,
              evidence.providerID == providerID,
              evidence.providerGeneration == ownership.providerGeneration,
              evidence.fencingToken == ownership.fencingToken else {
            throw InteractiveCommandRunnerError.runtimeOwnershipMismatch(serviceName)
        }
        return live
    }
}

enum InteractiveOperationBuilder {
    static func requestedService(_ options: InteractiveCLIOptions) throws -> String {
        if let service = options.serviceName {
            return service
        }
        guard options.command == .copy,
              let source = options.source,
              let destination = options.destination else {
            throw InteractiveCommandRunnerError.unknownService("<missing>")
        }
        if let endpoint = containerEndpoint(source) {
            guard containerEndpoint(destination) == nil else {
                throw InteractiveCommandRunnerError.invalidCopyEndpoints
            }
            return endpoint.service
        }
        if let endpoint = containerEndpoint(destination) {
            return endpoint.service
        }
        throw InteractiveCommandRunnerError.invalidCopyEndpoints
    }

    static func operationKind(
        _ options: InteractiveCLIOptions
    ) throws -> RuntimeInteractiveOperationKind {
        switch options.command {
        case .exec:
            return .exec
        case .attach:
            return .attach
        case .copy:
            guard let source = options.source, let destination = options.destination else {
                throw InteractiveCommandRunnerError.invalidCopyEndpoints
            }
            if containerEndpoint(source) != nil, containerEndpoint(destination) == nil {
                return .copyOut
            }
            if containerEndpoint(source) == nil, containerEndpoint(destination) != nil {
                return .copyIn
            }
            throw InteractiveCommandRunnerError.invalidCopyEndpoints
        case .export:
            return .export
        case .inspect:
            return .inspect
        case .stats:
            return .stats
        case .logsFollow:
            return .logsFollow
        }
    }

    static func requiredFeatures(
        _ operation: RuntimeInteractiveOperationKind
    ) -> Set<RuntimeProviderFeature> {
        switch operation {
        case .inspect, .stats:
            return [.observation]
        case .exec, .copyIn, .copyOut, .export:
            return [.processControl]
        case .attach:
            return [.lifecycle, .processControl, .streaming]
        case .logsFollow:
            return [.streaming, .cancellation]
        }
    }

    static func build(
        _ options: InteractiveCLIOptions,
        resourceIdentifier: String,
        workingDirectory: String?
    ) throws -> RuntimeInteractiveOperation {
        switch options.command {
        case .exec:
            return .exec(
                resourceIdentifier: resourceIdentifier,
                arguments: options.arguments,
                interactive: options.forwardsStandardInput,
                tty: options.terminal,
                workingDirectory: workingDirectory
            )
        case .attach:
            return .attach(
                resourceIdentifier: resourceIdentifier,
                interactive: options.forwardsStandardInput,
                tty: options.terminal
            )
        case .copy:
            guard let source = options.source, let destination = options.destination else {
                throw InteractiveCommandRunnerError.invalidCopyEndpoints
            }
            if let endpoint = containerEndpoint(source),
               containerEndpoint(destination) == nil {
                let host = try splitHostPath(destination)
                return .copyOut(
                    resourceIdentifier: resourceIdentifier,
                    containerSourcePath: endpoint.path,
                    hostRoot: host.root,
                    destinationRelativePath: host.relativePath
                )
            }
            if let endpoint = containerEndpoint(destination),
               containerEndpoint(source) == nil {
                let host = try splitHostPath(source)
                return .copyIn(
                    resourceIdentifier: resourceIdentifier,
                    hostRoot: host.root,
                    sourceRelativePath: host.relativePath,
                    containerDestinationPath: endpoint.path
                )
            }
            throw InteractiveCommandRunnerError.invalidCopyEndpoints
        case .export:
            guard let destination = options.destination else {
                throw InteractiveCommandRunnerError.invalidHostPath
            }
            let host = try splitHostPath(destination)
            return .export(
                resourceIdentifier: resourceIdentifier,
                hostRoot: host.root,
                destinationRelativePath: host.relativePath
            )
        case .inspect:
            return .inspect(resourceIdentifier: resourceIdentifier)
        case .stats:
            return .stats(resourceIdentifier: resourceIdentifier)
        case .logsFollow:
            return .logsFollow(
                resourceIdentifier: resourceIdentifier,
                tail: options.tail
            )
        }
    }

    private static func containerEndpoint(
        _ value: String
    ) -> (service: String, path: String)? {
        guard let separator = value.firstIndex(of: ":") else {
            return nil
        }
        let service = String(value[..<separator])
        let path = String(value[value.index(after: separator)...])
        guard !service.isEmpty else { return nil }
        do {
            try RuntimeContainerPathPolicy.validate(path)
            return (service, path)
        } catch {
            return nil
        }
    }

    private static func splitHostPath(
        _ path: String
    ) throws -> (root: String, relativePath: String) {
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\\") else {
            throw InteractiveCommandRunnerError.invalidHostPath
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == path,
              path != "/",
              !url.lastPathComponent.isEmpty else {
            throw InteractiveCommandRunnerError.invalidHostPath
        }
        return (
            url.deletingLastPathComponent().path,
            url.lastPathComponent
        )
    }
}

private final class InteractiveOutputBuffer: @unchecked Sendable {
    static let maximumBufferedBytes = RuntimeStreamEnvelope.maximumFrameBytes

    private let lock = NSLock()
    private let format: CLIOutputFormat
    private var standardOutput = Data()
    private var standardError = Data()

    init(format: CLIOutputFormat) {
        self.format = format
    }

    func append(_ envelope: RuntimeStreamEnvelope) throws {
        let payload: Data
        let destination: RuntimeStreamName
        if format == .json {
            payload = try envelope.ndjsonLine()
            destination = .standardOutput
        } else {
            guard !envelope.endOfStream, !envelope.payload.isEmpty else { return }
            payload = envelope.payload
            destination = envelope.stream
        }
        try lock.withLock {
            guard standardOutput.count + standardError.count + payload.count <=
                    Self.maximumBufferedBytes else {
                throw RuntimeInteractiveError.streamFrameTooLarge
            }
            if destination == .standardError {
                standardError.append(payload)
            } else {
                standardOutput.append(payload)
            }
        }
    }

    func result() -> CLIRunResult {
        lock.withLock {
            CLIRunResult(
                standardOutput: String(decoding: standardOutput, as: UTF8.self),
                standardError: String(decoding: standardError, as: UTF8.self)
            )
        }
    }
}
