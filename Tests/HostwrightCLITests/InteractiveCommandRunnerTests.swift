import Darwin
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightState
import XCTest
@testable import HostwrightCLI
@testable import HostwrightRuntime

final class InteractiveCommandRunnerTests: XCTestCase {
    func testLiveDriverUsesExactStateAndInventoryBeforeInjectedExecutor() throws {
        try withLiveFixture(providerID: .appleContainerCLI) { fixture in
            let result = InteractiveCommandRunner(
                options: fixture.options,
                driver: InteractiveLiveDriver(
                    environment: fixture.environment,
                    executor: fixture.executor
                )
            ).run()

            XCTAssertEqual(result.exitCode, 0, result.standardError)
            XCTAssertEqual(result.standardOutput, #"{"id":"managed"}"#)
            XCTAssertEqual(fixture.executor.executionCount, 1)
            XCTAssertEqual(
                fixture.executor.lastOperation,
                .inspect(resourceIdentifier: fixture.ownership.resourceIdentifier)
            )
        }
    }

    func testContainerizationUsesOnlyItsAdvertisedInteractiveSubset() throws {
        try withLiveFixture(providerID: .appleContainerization) { fixture in
            let result = InteractiveCommandRunner(
                options: fixture.options,
                driver: InteractiveLiveDriver(
                    environment: fixture.environment,
                    executor: fixture.executor
                )
            ).run()

            XCTAssertEqual(result.exitCode, 0, result.standardError)
            XCTAssertEqual(fixture.executor.executionCount, 1)
            XCTAssertEqual(
                fixture.executor.lastOperation,
                .inspect(resourceIdentifier: fixture.ownership.resourceIdentifier)
            )
        }
    }

    func testAppleAttachRefusesBeforeExecutorCanStartAStoppedWorkload() throws {
        try withLiveFixture(
            providerID: .appleContainerCLI,
            lifecycle: .stopped
        ) { fixture in
            let options = InteractiveCLIOptions(
                command: .attach,
                manifestPath: fixture.options.manifestPath,
                serviceName: "api",
                stateDatabasePath: fixture.options.stateDatabasePath,
                runtimeProvider: .appleCLI,
                terminal: true,
                forwardsStandardInput: true
            )
            let result = InteractiveCommandRunner(
                options: options,
                driver: InteractiveLiveDriver(
                    environment: fixture.environment,
                    executor: fixture.executor
                )
            ).run()

            XCTAssertEqual(
                result.exitCode,
                CLIExitCode.runtimeUnavailable.rawValue
            )
            XCTAssertTrue(result.standardError.contains("cannot reattach"))
            XCTAssertEqual(fixture.executor.executionCount, 0)
        }
    }

    func testTextOutputPreservesSeparatedRuntimeStreams() throws {
        let driver = ScriptedInteractiveDriver { _, sink in
            try sink(
                RuntimeStreamEnvelope(
                    sequence: 0,
                    stream: .standardOutput,
                    payload: Data("output".utf8)
                )
            )
            try sink(
                RuntimeStreamEnvelope(
                    sequence: 1,
                    stream: .standardError,
                    payload: Data("diagnostic".utf8)
                )
            )
            try sink(
                RuntimeStreamEnvelope(
                    sequence: 2,
                    stream: .standardOutput,
                    payload: Data(),
                    endOfStream: true
                )
            )
            return RuntimeInteractiveExecutionResult(
                operation: .exec,
                exitStatus: 0,
                emittedFrameCount: 3,
                standardErrorTail: ""
            )
        }
        let result = InteractiveCommandRunner(
            options: options(command: .exec),
            driver: driver
        ).run()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "output")
        XCTAssertEqual(result.standardError, "diagnostic")
        XCTAssertEqual(driver.executionCount, 1)
    }

    func testJSONOutputUsesStrictNDJSONBase64Frames() throws {
        let driver = ScriptedInteractiveDriver { _, sink in
            try sink(
                RuntimeStreamEnvelope(
                    sequence: 8,
                    stream: .standardOutput,
                    payload: Data([0x00, 0xff, 0x41])
                )
            )
            try sink(
                RuntimeStreamEnvelope(
                    sequence: 9,
                    stream: .standardOutput,
                    payload: Data(),
                    endOfStream: true
                )
            )
            return RuntimeInteractiveExecutionResult(
                operation: .inspect,
                exitStatus: 0,
                emittedFrameCount: 2,
                standardErrorTail: ""
            )
        }
        let result = InteractiveCommandRunner(
            options: options(command: .inspect, output: .json),
            driver: driver
        ).run()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardError, "")
        let lines = result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { Data($0.utf8) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(
            try RuntimeStreamEnvelope.decodeNDJSONLine(lines[0]).payload,
            Data([0x00, 0xff, 0x41])
        )
        XCTAssertTrue(
            try RuntimeStreamEnvelope.decodeNDJSONLine(lines[1]).endOfStream
        )
    }

    func testLiveStreamSinkReceivesFramesWithoutBufferingThemInTheResult() throws {
        let recording = RecordingLiveStream()
        let driver = ScriptedInteractiveDriver { _, sink in
            try sink(
                RuntimeStreamEnvelope(
                    sequence: 0,
                    stream: .standardOutput,
                    payload: Data("first".utf8)
                )
            )
            try sink(
                RuntimeStreamEnvelope(
                    sequence: 1,
                    stream: .standardError,
                    payload: Data("second".utf8)
                )
            )
            return RuntimeInteractiveExecutionResult(
                operation: .exec,
                exitStatus: 0,
                emittedFrameCount: 2,
                standardErrorTail: ""
            )
        }
        let result = InteractiveCommandRunner(
            options: options(command: .exec),
            driver: driver,
            liveStreamSink: { envelope, format in
                recording.append(envelope, format: format)
            }
        ).run()

        XCTAssertEqual(result, CLIRunResult())
        XCTAssertEqual(recording.payloads, [Data("first".utf8), Data("second".utf8)])
        XCTAssertEqual(recording.formats, [.text, .text])
    }

    func testStandardIOSessionRelaysBoundedInputAndEOF() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(Darwin.pipe(&descriptors), 0)
        var readDescriptor = descriptors[0]
        var writeDescriptor = descriptors[1]
        defer {
            if readDescriptor >= 0 { close(readDescriptor) }
            if writeDescriptor >= 0 { close(writeDescriptor) }
        }

        let control = RuntimeInteractiveProcessControl()
        let session = try InteractiveStandardIOSession(
            control: control,
            forwardsStandardInput: true,
            terminal: false,
            standardInputDescriptor: readDescriptor,
            installsSignalHandlers: false
        )
        close(readDescriptor)
        readDescriptor = -1
        try session.start()
        let input = Data([0x00, 0xff, 0x41, 0x0a])
        let written = input.withUnsafeBytes { bytes in
            Darwin.write(writeDescriptor, bytes.baseAddress, input.count)
        }
        XCTAssertEqual(written, input.count)
        close(writeDescriptor)
        writeDescriptor = -1

        for _ in 0..<200 where control.inputPrefix(maximumBytes: 64).count < input.count {
            usleep(5_000)
        }
        XCTAssertEqual(control.inputPrefix(maximumBytes: 64), input)
        control.consumeInput(input.count)
        for _ in 0..<200 where !control.shouldCloseInput {
            usleep(5_000)
        }
        XCTAssertTrue(control.shouldCloseInput)
        session.stop()
    }

    func testCapabilityFailureIsStableAndDoesNotEmitOutput() {
        let driver = ScriptedInteractiveDriver { _, _ in
            throw RuntimeInteractiveError.capabilityUnavailable(
                operation: .attach,
                reason: "streaming is unavailable"
            )
        }
        let result = InteractiveCommandRunner(
            options: options(command: .attach),
            driver: driver
        ).run()

        XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.runtimeUnavailable.rawValue))
        XCTAssertTrue(result.standardError.contains("streaming is unavailable"))
    }

    func testOutputLimitStopsTheDriverThroughTheThrowingSink() {
        let driver = ScriptedInteractiveDriver { _, sink in
            for sequence in 0..<129 {
                try sink(
                    RuntimeStreamEnvelope(
                        sequence: UInt64(sequence),
                        stream: .standardOutput,
                        payload: Data(
                            repeating: 0x61,
                            count: RuntimeStreamEnvelope.maximumChunkBytes
                        )
                    )
                )
            }
            return RuntimeInteractiveExecutionResult(
                operation: .exec,
                exitStatus: 0,
                emittedFrameCount: 129,
                standardErrorTail: ""
            )
        }
        let result = InteractiveCommandRunner(
            options: options(command: .exec),
            driver: driver
        ).run()

        XCTAssertEqual(result.exitCode, CLIExitCode.partialFailure.rawValue)
        XCTAssertTrue(result.standardError.contains("bounded 8 MiB"))
    }

    func testOperationBuilderTranslatesEveryCLIInteractiveVerb() throws {
        let identifier = managedIdentifier
        XCTAssertEqual(
            try InteractiveOperationBuilder.build(
                InteractiveCLIOptions(
                    command: .exec,
                    serviceName: "api",
                    arguments: ["/bin/echo", "ok"],
                    terminal: true,
                    forwardsStandardInput: true
                ),
                resourceIdentifier: identifier,
                workingDirectory: "/work"
            ),
            .exec(
                resourceIdentifier: identifier,
                arguments: ["/bin/echo", "ok"],
                interactive: true,
                tty: true,
                workingDirectory: "/work"
            )
        )
        XCTAssertEqual(
            try InteractiveOperationBuilder.build(
                InteractiveCLIOptions(
                    command: .attach,
                    serviceName: "api",
                    forwardsStandardInput: false
                ),
                resourceIdentifier: identifier,
                workingDirectory: nil
            ),
            .attach(resourceIdentifier: identifier, interactive: false, tty: false)
        )
        XCTAssertEqual(
            try InteractiveOperationBuilder.build(
                InteractiveCLIOptions(
                    command: .copy,
                    source: "/tmp/source.bin",
                    destination: "api:/work/input.bin"
                ),
                resourceIdentifier: identifier,
                workingDirectory: nil
            ),
            .copyIn(
                resourceIdentifier: identifier,
                hostRoot: "/tmp",
                sourceRelativePath: "source.bin",
                containerDestinationPath: "/work/input.bin"
            )
        )
        XCTAssertEqual(
            try InteractiveOperationBuilder.build(
                InteractiveCLIOptions(
                    command: .copy,
                    source: "api:/work/output.bin",
                    destination: "/tmp/output.bin"
                ),
                resourceIdentifier: identifier,
                workingDirectory: nil
            ),
            .copyOut(
                resourceIdentifier: identifier,
                containerSourcePath: "/work/output.bin",
                hostRoot: "/tmp",
                destinationRelativePath: "output.bin"
            )
        )
        XCTAssertEqual(
            try InteractiveOperationBuilder.build(
                InteractiveCLIOptions(
                    command: .export,
                    serviceName: "api",
                    destination: "/tmp/rootfs.tar"
                ),
                resourceIdentifier: identifier,
                workingDirectory: nil
            ),
            .export(
                resourceIdentifier: identifier,
                hostRoot: "/tmp",
                destinationRelativePath: "rootfs.tar"
            )
        )
        XCTAssertEqual(
            try InteractiveOperationBuilder.build(
                InteractiveCLIOptions(command: .inspect, serviceName: "api"),
                resourceIdentifier: identifier,
                workingDirectory: nil
            ),
            .inspect(resourceIdentifier: identifier)
        )
        XCTAssertEqual(
            try InteractiveOperationBuilder.build(
                InteractiveCLIOptions(command: .stats, serviceName: "api"),
                resourceIdentifier: identifier,
                workingDirectory: nil
            ),
            .stats(resourceIdentifier: identifier)
        )
        XCTAssertEqual(
            try InteractiveOperationBuilder.build(
                InteractiveCLIOptions(
                    command: .logsFollow,
                    serviceName: "api",
                    forwardsStandardInput: false,
                    tail: 25
                ),
                resourceIdentifier: identifier,
                workingDirectory: nil
            ),
            .logsFollow(resourceIdentifier: identifier, tail: 25)
        )
    }

    func testCopyEndpointAndHostPathValidationFailClosed() {
        XCTAssertThrowsError(
            try InteractiveOperationBuilder.requestedService(
                InteractiveCLIOptions(
                    command: .copy,
                    source: "api:/one",
                    destination: "worker:/two"
                )
            )
        )
        XCTAssertThrowsError(
            try InteractiveOperationBuilder.build(
                InteractiveCLIOptions(
                    command: .export,
                    serviceName: "api",
                    destination: "/tmp/../private/rootfs.tar"
                ),
                resourceIdentifier: managedIdentifier,
                workingDirectory: nil
            )
        )
    }

    func testOwnershipResolverRequiresOneExactUUIDBackedRecord() throws {
        let fixture = ownershipFixture()
        XCTAssertEqual(
            try InteractiveOwnershipResolver.resolve(
                records: [fixture.ownership],
                project: fixture.project,
                serviceName: "api",
                expectedIdentity: fixture.identity,
                providerID: .appleContainerCLI
            ),
            fixture.ownership
        )

        XCTAssertThrowsError(
            try InteractiveOwnershipResolver.resolve(
                records: [fixture.ownership, fixture.ownership],
                project: fixture.project,
                serviceName: "api",
                expectedIdentity: fixture.identity,
                providerID: .appleContainerCLI
            )
        ) { error in
            XCTAssertEqual(
                error as? InteractiveCommandRunnerError,
                .ambiguousManagedResource("api")
            )
        }

        let wrongFence = ownership(
            fixture: fixture,
            fencingToken: "not-a-uuid"
        )
        XCTAssertThrowsError(
            try InteractiveOwnershipResolver.resolve(
                records: [wrongFence],
                project: fixture.project,
                serviceName: "api",
                expectedIdentity: fixture.identity,
                providerID: .appleContainerCLI
            )
        )
    }

    func testLiveInventoryMustRepeatEveryOwnershipFieldExactly() throws {
        let fixture = ownershipFixture()
        let inventory = try runtimeInventory(
            ownership: runtimeEvidence(fixture.ownership)
        )
        XCTAssertNoThrow(
            try InteractiveOwnershipResolver.verifyLiveInventory(
                inventory,
                ownership: fixture.ownership,
                project: fixture.project,
                providerID: .appleContainerCLI,
                serviceName: "api"
            )
        )

        let wrongEvidence = RuntimeInventoryOwnershipEvidence(
            resourceUUID: fixture.ownership.resourceUUID,
            projectUUID: fixture.project.resourceUUID,
            resourceGeneration: fixture.ownership.resourceGeneration,
            projectGeneration: fixture.ownership.projectGeneration,
            providerID: .appleContainerCLI,
            providerGeneration: fixture.ownership.providerGeneration,
            fencingToken: HostwrightResourceUUID.generate()
        )
        XCTAssertThrowsError(
            try InteractiveOwnershipResolver.verifyLiveInventory(
                runtimeInventory(ownership: wrongEvidence),
                ownership: fixture.ownership,
                project: fixture.project,
                providerID: .appleContainerCLI,
                serviceName: "api"
            )
        ) { error in
            XCTAssertEqual(
                error as? InteractiveCommandRunnerError,
                .runtimeOwnershipMismatch("api")
            )
        }
    }

    private func options(
        command: InteractiveCommandKind,
        output: CLIOutputFormat = .text
    ) -> InteractiveCLIOptions {
        InteractiveCLIOptions(
            command: command,
            serviceName: "api",
            arguments: command == .exec ? ["/bin/true"] : [],
            output: output,
            terminal: command == .attach
        )
    }
}

private final class ScriptedInteractiveDriver: InteractiveCommandDriving, @unchecked Sendable {
    typealias Handler = (
        InteractiveCLIOptions,
        @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) throws -> RuntimeInteractiveExecutionResult

    private let lock = NSLock()
    private let handler: Handler
    private var executions = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var executionCount: Int {
        lock.withLock { executions }
    }

    func execute(
        options: InteractiveCLIOptions,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) throws -> RuntimeInteractiveExecutionResult {
        lock.withLock { executions += 1 }
        return try handler(options, sink)
    }
}

private final class RecordingLiveStream: @unchecked Sendable {
    private let lock = NSLock()
    private var envelopes: [RuntimeStreamEnvelope] = []
    private var outputFormats: [CLIOutputFormat] = []

    func append(_ envelope: RuntimeStreamEnvelope, format: CLIOutputFormat) {
        lock.withLock {
            envelopes.append(envelope)
            outputFormats.append(format)
        }
    }

    var payloads: [Data] {
        lock.withLock { envelopes.map(\.payload) }
    }

    var formats: [CLIOutputFormat] {
        lock.withLock { outputFormats }
    }
}

private final class RecordingInteractiveExecutor: InteractiveRuntimeExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [RuntimeInteractiveOperation] = []

    var executionCount: Int {
        lock.withLock { operations.count }
    }

    var lastOperation: RuntimeInteractiveOperation? {
        lock.withLock { operations.last }
    }

    func execute(
        _ operation: RuntimeInteractiveOperation,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        timeoutMilliseconds: Int,
        control: RuntimeInteractiveProcessControl,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) async throws -> RuntimeInteractiveExecutionResult {
        lock.withLock { operations.append(operation) }
        try sink(
            RuntimeStreamEnvelope(
                sequence: 0,
                stream: .standardOutput,
                payload: Data(#"{"id":"managed"}"#.utf8)
            )
        )
        return RuntimeInteractiveExecutionResult(
            operation: operation.kind,
            exitStatus: 0,
            emittedFrameCount: 1,
            standardErrorTail: ""
        )
    }
}

private actor InteractiveLiveTestAdapter: RuntimeAdapter {
    let snapshot: RuntimeCapabilitySnapshot
    let runtimeInventory: RuntimeInventory

    init(snapshot: RuntimeCapabilitySnapshot, inventory: RuntimeInventory) {
        self.snapshot = snapshot
        runtimeInventory = inventory
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: snapshot.descriptor.providerID,
            adapterName: "InteractiveLiveTestAdapter",
            adapterVersion: "1.0.0",
            runtimeName: "container",
            runtimeVersion: "1.1.0",
            supportsMutation: true,
            capabilities: [.readOnlyObservation, .lifecycleMutation]
        )
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation, .lifecycleMutation]
    }

    func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        snapshot
    }

    func inventory() async throws -> RuntimeInventory {
        runtimeInventory
    }

    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        throw RuntimeAdapterError.capabilityUnavailable(.readOnlyObservation)
    }

    func plan(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) async throws -> RuntimePlan {
        throw RuntimeAdapterError.capabilityUnavailable(.readOnlyObservation)
    }

    func logs(
        for service: ObservedRuntimeService,
        tail: Int
    ) async throws -> RuntimeLogResult {
        throw RuntimeAdapterError.capabilityUnavailable(.logStreaming)
    }

    func execute(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation?
    ) async throws -> RuntimeEvent {
        throw RuntimeAdapterError.capabilityUnavailable(.lifecycleMutation)
    }
}

private struct InteractiveLiveFixture {
    let environment: CLIEnvironment
    let options: InteractiveCLIOptions
    let ownership: OwnershipRecord
    let executor: RecordingInteractiveExecutor
}

private func withLiveFixture(
    providerID: RuntimeProviderID,
    lifecycle: RuntimeInventoryLifecycleState = .running,
    _ body: (InteractiveLiveFixture) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let manifestPath = directory.appendingPathComponent("hostwright.yaml").path
    let databasePath = directory.appendingPathComponent("state.sqlite").path
    let manifestText = """
    version: 2
    project: demo
    imagePolicy: allow-tags
    services:
      api:
        image: local/api:latest
    """
    let manifest = try ManifestValidator.validated(manifestText)
    let resolution = try HostwrightLocalPathResolver.resolve(
        explicitStateDatabasePath: databasePath,
        homeDirectory: directory.path,
        environment: [:]
    )
    let store = SQLiteStateStore(
        configuration: StateStoreConfiguration(localPathResolution: resolution)
    )
    try store.migrate()
    try store.desiredStates.saveManifestSnapshot(
        projectID: "project-demo",
        manifestPath: manifestPath,
        manifestHash: String(repeating: "a", count: 64),
        desiredGeneration: 3,
        manifest: manifest,
        timestamp: "2026-07-23T00:00:00Z",
        mutationProvider: providerID.rawValue
    )
    let project = try store.desiredStates.loadProject(id: "project-demo")
    let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
    let ownership = OwnershipRecord(
        id: HostwrightResourceUUID.generate(),
        resourceIdentifier: identity.managedResourceIdentifier,
        resourceType: "container",
        projectID: project.id,
        serviceName: "api",
        runtimeAdapter: providerID.rawValue,
        createdAt: "2026-07-23T00:00:00Z",
        observedAt: "2026-07-23T00:00:00Z",
        cleanupEligible: true,
        metadataJSONRedacted: "{}",
        identityVersion: RuntimeManagedResourceIdentity.currentVersion,
        resourceUUID: HostwrightResourceUUID.generate(),
        resourceGeneration: 2,
        projectResourceUUID: project.resourceUUID,
        projectGeneration: 4,
        providerGeneration: 3,
        fencingToken: HostwrightResourceUUID.generate()
    )
    try store.ownership.upsert(ownership)
    let snapshot = interactiveCapability(providerID: providerID)
    let inventory = try runtimeInventory(
        ownership: RuntimeInventoryOwnershipEvidence(
            resourceUUID: ownership.resourceUUID,
            projectUUID: project.resourceUUID,
            resourceGeneration: ownership.resourceGeneration,
            projectGeneration: ownership.projectGeneration,
            providerID: providerID,
            providerGeneration: ownership.providerGeneration,
            fencingToken: ownership.fencingToken
        ),
        lifecycle: lifecycle
    )
    let adapter = InteractiveLiveTestAdapter(
        snapshot: snapshot,
        inventory: inventory
    )
    let environment = CLIEnvironment(
        fileExists: { $0 == manifestPath || $0 == databasePath },
        readTextFile: { path in
            guard path == manifestPath else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return manifestText
        },
        writeTextFile: { _, _ in },
        executablePath: { _ in nil },
        localPathResolution: { _ in resolution },
        runtimeAdapter: { adapter },
        runtimeAdapterForProvider: { requested in
            guard requested == providerID else {
                throw RuntimeProviderSelectionError.providerUnavailable(requested)
            }
            return adapter
        },
        runtimeProviderProbes: {
            RuntimeProviderID.knownValues.map { candidate in
                candidate == providerID
                    ? .available(snapshot)
                    : .unavailable(candidate, reason: .helperHandshakeUnavailable)
            }
        },
        swiftVersion: { "Swift test" },
        platformSnapshot: {
            PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64")
        },
        operatingSystemDescription: { "macOS 26.0" }
    )
    let selection: RuntimeProviderSelection = providerID == .appleContainerCLI
        ? .appleCLI
        : .containerization
    try body(
        InteractiveLiveFixture(
            environment: environment,
            options: InteractiveCLIOptions(
                command: .inspect,
                manifestPath: manifestPath,
                serviceName: "api",
                stateDatabasePath: databasePath,
                runtimeProvider: selection
            ),
            ownership: ownership,
            executor: RecordingInteractiveExecutor()
        )
    )
}

private func interactiveCapability(
    providerID: RuntimeProviderID
) -> RuntimeCapabilitySnapshot {
    let components: [RuntimeProviderComponent]
    let features: [RuntimeProviderFeatureStatus]
    if providerID == .appleContainerCLI {
        components = [
            RuntimeProviderComponent(
                identifier: .appleContainerCLI,
                version: "1.1.0",
                build: "test",
                fingerprint: "abcdef0"
            ),
            RuntimeProviderComponent(
                identifier: .appleContainerAPIService,
                version: "1.1.0",
                build: "test",
                fingerprint: "abcdef0"
            )
        ]
        features = RuntimeProviderCapabilityProbe.appleContainerCLIFeatures
    } else {
        components = [
            RuntimeProviderComponent(
                identifier: .appleContainerizationHelper,
                version: "0.0.2",
                build: "test",
                fingerprint: "abcdef1"
            ),
            RuntimeProviderComponent(
                identifier: .containerizationHelperProtocolV1,
                version: RuntimeProviderCapabilityContract.helperProtocolVersion,
                build: "test",
                fingerprint: "abcdef2"
            ),
            RuntimeProviderComponent(
                identifier: .appleContainerizationFramework,
                version: RuntimeProviderCapabilityContract.containerizationFrameworkVersion,
                build: "test",
                fingerprint: "abcdef3"
            )
        ]
        let availableFeatures: Set<RuntimeProviderFeature> = [
            .observation,
            .lifecycle,
            .images,
            .cancellation,
            .timeouts,
            .errors,
            .cleanup
        ]
        features = RuntimeProviderFeature.knownValues.map { feature in
            RuntimeProviderFeatureStatus(
                feature: feature,
                state: availableFeatures.contains(feature) ? .available : .unavailable,
                reason: availableFeatures.contains(feature) ? .implemented : .notImplemented
            )
        }
    }
    return RuntimeCapabilitySnapshot(
        descriptor: RuntimeProviderDescriptor(
            providerID: providerID,
            components: components,
            minimumMacOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
            supportedArchitectures: [.arm64]
        ),
        host: RuntimeProviderHostPlatform(
            macOSVersion: RuntimeProviderMacOSVersion(major: 26),
            macOSBuild: "25A1",
            architecture: .arm64
        ),
        features: features
    )
}

private struct InteractiveOwnershipFixture {
    let project: StateProjectRecord
    let identity: RuntimeServiceIdentity
    let ownership: OwnershipRecord
}

private var managedIdentifier: String {
    RuntimeServiceIdentity(
        projectName: "demo",
        serviceName: "api"
    ).managedResourceIdentifier
}

private func ownershipFixture() -> InteractiveOwnershipFixture {
    let projectUUID = HostwrightResourceUUID.generate()
    let project = StateProjectRecord(
        id: "project-demo",
        name: "demo",
        manifestPath: "/tmp/hostwright.yaml",
        manifestHash: String(repeating: "a", count: 64),
        createdAt: "2026-07-23T00:00:00Z",
        updatedAt: "2026-07-23T00:00:00Z",
        resourceUUID: projectUUID,
        manifestVersion: 2,
        mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue,
        providerGeneration: 3
    )
    let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
    let record = OwnershipRecord(
        id: HostwrightResourceUUID.generate(),
        resourceIdentifier: identity.managedResourceIdentifier,
        resourceType: "container",
        projectID: project.id,
        serviceName: "api",
        runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
        createdAt: "2026-07-23T00:00:00Z",
        observedAt: "2026-07-23T00:00:00Z",
        cleanupEligible: true,
        metadataJSONRedacted: "{}",
        identityVersion: RuntimeManagedResourceIdentity.currentVersion,
        resourceUUID: HostwrightResourceUUID.generate(),
        resourceGeneration: 2,
        projectResourceUUID: projectUUID,
        projectGeneration: 4,
        providerGeneration: 3,
        fencingToken: HostwrightResourceUUID.generate()
    )
    return InteractiveOwnershipFixture(
        project: project,
        identity: identity,
        ownership: record
    )
}

private func ownership(
    fixture: InteractiveOwnershipFixture,
    fencingToken: String
) -> OwnershipRecord {
    OwnershipRecord(
        id: fixture.ownership.id,
        resourceIdentifier: fixture.ownership.resourceIdentifier,
        resourceType: fixture.ownership.resourceType,
        projectID: fixture.ownership.projectID,
        serviceName: fixture.ownership.serviceName,
        runtimeAdapter: fixture.ownership.runtimeAdapter,
        createdAt: fixture.ownership.createdAt,
        observedAt: fixture.ownership.observedAt,
        cleanupEligible: fixture.ownership.cleanupEligible,
        metadataJSONRedacted: fixture.ownership.metadataJSONRedacted,
        identityVersion: fixture.ownership.identityVersion,
        resourceUUID: fixture.ownership.resourceUUID,
        resourceGeneration: fixture.ownership.resourceGeneration,
        projectResourceUUID: fixture.ownership.projectResourceUUID,
        projectGeneration: fixture.ownership.projectGeneration,
        providerGeneration: fixture.ownership.providerGeneration,
        fencingToken: fencingToken
    )
}

private func runtimeEvidence(
    _ ownership: OwnershipRecord
) -> RuntimeInventoryOwnershipEvidence {
    RuntimeInventoryOwnershipEvidence(
        resourceUUID: ownership.resourceUUID,
        projectUUID: ownership.projectResourceUUID!,
        resourceGeneration: ownership.resourceGeneration,
        projectGeneration: ownership.projectGeneration,
        providerID: .appleContainerCLI,
        providerGeneration: ownership.providerGeneration,
        fencingToken: ownership.fencingToken
    )
}

private func runtimeInventory(
    ownership: RuntimeInventoryOwnershipEvidence,
    lifecycle: RuntimeInventoryLifecycleState = .running
) throws -> RuntimeInventory {
    try RuntimeInventoryBuilder.build(
        machine: RuntimeInventoryMachine(
            state: .running,
            operatingSystem: "macOS 26.0",
            architecture: "arm64",
            runtimeVersion: "1.1.0",
            services: [
                RuntimeInventoryService(
                    identifier: "container-apiserver",
                    state: .running,
                    required: true
                )
            ]
        ),
        containers: [
            RuntimeInventoryContainer(
                runtimeID: "runtime-api",
                name: managedIdentifier,
                imageReference: "example.invalid/api@sha256:\(String(repeating: "a", count: 64))",
                lifecycle: lifecycle,
                health: RuntimeInventoryHealth(
                    availability: .notConfigured
                ),
                labels: [
                    RuntimeInventoryLabel(
                        key: RuntimeManagedResourceIdentity.managedLabel,
                        value: "true"
                    )
                ],
                ownership: ownership,
                initConfiguration: RuntimeInventoryInitConfiguration(
                    executable: "/bin/api",
                    arguments: [],
                    environment: []
                ),
                ports: [],
                mounts: [],
                networks: [],
                services: []
            )
        ],
        images: [],
        networks: [],
        volumes: []
    )
}
