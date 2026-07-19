import Darwin
import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime

final class ContainerizationHelperServiceTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private let resourceUUID = "11111111-1111-4111-8111-111111111111"
    private let projectUUID = "22222222-2222-4222-8222-222222222222"
    private let fencingToken = "33333333-3333-4333-8333-333333333333"

    func testDispatcherRoutesTheExactTypedOperationSubset() async throws {
        let backend = try TestBackend(snapshot: snapshot(), inventory: inventory())
        let dispatcher = ContainerizationHelperDispatcher(
            backend: backend,
            expectedCapabilityDigest: digest
        )

        let negotiation: RuntimeCapabilitySnapshot = try await dispatch(
            .negotiate,
            payload: ContainerizationHelperEmptyPayload(),
            through: dispatcher
        )
        XCTAssertEqual(negotiation, snapshot())

        let observation: ContainerizationHelperObservation = try await dispatch(
            .observe,
            payload: ContainerizationHelperObservePayload(),
            through: dispatcher
        )
        XCTAssertEqual(try observation.validatedInventory(), try inventory())

        let evidence: ContainerizationHelperImageEvidence = try await dispatch(
            .localImageEvidence,
            payload: ContainerizationHelperImageRequest(reference: "example.local/demo@sha256:abc"),
            through: dispatcher
        )
        XCTAssertEqual(evidence, TestBackend.imageEvidence)

        let usage: ContainerizationHelperResourceUsage = try await dispatch(
            .resourceUsage,
            payload: ContainerizationHelperResourceRequest(resourceIdentifier: "demo"),
            through: dispatcher
        )
        XCTAssertEqual(usage.resourceIdentifier, "demo")

        let logs: ContainerizationHelperLogs = try await dispatch(
            .logs,
            payload: ContainerizationHelperLogsRequest(resourceIdentifier: "demo", lineLimit: 20),
            through: dispatcher
        )
        XCTAssertEqual(logs.lineLimit, 20)

        let create: ContainerizationHelperMutationResult = try await dispatch(
            .create,
            payload: createPayload(),
            context: mutationContext(),
            through: dispatcher
        )
        XCTAssertEqual(create.lifecycle, .created)

        for (operation, state) in [
            (ContainerizationHelperOperation.start, RuntimeInventoryLifecycleState.running),
            (.stop, .stopped),
            (.restart, .running),
            (.delete, .missing)
        ] {
            let result: ContainerizationHelperMutationResult = try await dispatch(
                operation,
                payload: ContainerizationHelperMutationPayload(
                    resourceIdentifier: "demo",
                    resourceUUID: resourceUUID
                ),
                context: mutationContext(),
                through: dispatcher
            )
            XCTAssertEqual(result.lifecycle, state)
            XCTAssertTrue(result.verified)
        }

        let recordedOperations = await backend.recordedOperations()
        XCTAssertEqual(
            recordedOperations,
            [
                .negotiate, .observe, .localImageEvidence, .resourceUsage, .logs,
                .localImageEvidence, .create, .start, .stop, .restart, .delete
            ]
        )
    }

    func testCreateRequiresMatchingLocalImageEvidenceBeforeMutation() async throws {
        let backend = try TestBackend(snapshot: snapshot(), inventory: inventory())
        let dispatcher = ContainerizationHelperDispatcher(
            backend: backend,
            expectedCapabilityDigest: digest
        )
        let mismatched = ContainerizationHelperCreatePayload(
            resourceIdentifier: "demo",
            resourceUUID: resourceUUID,
            projectUUID: projectUUID,
            image: ContainerizationHelperImageEvidence(
                reference: TestBackend.imageEvidence.reference,
                descriptorDigest: "sha256:wrong",
                variantDigest: TestBackend.imageEvidence.variantDigest,
                architecture: "arm64",
                operatingSystem: "linux"
            ),
            command: [],
            environment: [],
            labels: []
        )

        let frame = try requestFrame(
            operation: .create,
            payload: mismatched,
            context: mutationContext()
        )
        let response = try await dispatcher.dispatch(frame: frame, nowUnixMilliseconds: 1_000)
        let failure = try ContainerizationHelperCanonicalJSON.decodeError(
            from: ContainerizationHelperFraming.decodeSingleFrame(response)
        )

        XCTAssertEqual(failure.error.code, .invalidRequest)
        let recordedOperations = await backend.recordedOperations()
        XCTAssertEqual(recordedOperations, [.localImageEvidence])
    }

    func testNegotiationCanRefreshAStaleDigestButOtherOperationsCannot() async throws {
        let backend = try TestBackend(snapshot: snapshot(), inventory: inventory())
        let dispatcher = ContainerizationHelperDispatcher(
            backend: backend,
            expectedCapabilityDigest: digest
        )
        let staleDigest = String(repeating: "b", count: 64)

        let negotiationFrame = try requestFrame(
            operation: .negotiate,
            payload: ContainerizationHelperEmptyPayload(),
            capabilityDigest: staleDigest
        )
        let negotiationResponse = try await dispatcher.dispatch(
            frame: negotiationFrame,
            nowUnixMilliseconds: 1_000
        )
        let negotiation = try ContainerizationHelperCanonicalJSON.decodeResult(
            RuntimeCapabilitySnapshot.self,
            from: ContainerizationHelperFraming.decodeSingleFrame(negotiationResponse)
        )
        XCTAssertEqual(negotiation.result, snapshot())

        let observationFrame = try requestFrame(
            operation: .observe,
            payload: ContainerizationHelperObservePayload(),
            capabilityDigest: staleDigest
        )
        let observationResponse = try await dispatcher.dispatch(
            frame: observationFrame,
            nowUnixMilliseconds: 1_000
        )
        let failure = try ContainerizationHelperCanonicalJSON.decodeError(
            from: ContainerizationHelperFraming.decodeSingleFrame(observationResponse)
        )
        XCTAssertEqual(failure.error.code, .capabilityMismatch)
    }

    func testMutationContextMustBindTheContainerizationProviderAndRequestDigest() async throws {
        let backend = try TestBackend(snapshot: snapshot(), inventory: inventory())
        let dispatcher = ContainerizationHelperDispatcher(
            backend: backend,
            expectedCapabilityDigest: digest
        )
        let frame = try requestFrame(
            operation: .start,
            payload: ContainerizationHelperMutationPayload(
                resourceIdentifier: "demo",
                resourceUUID: resourceUUID
            ),
            context: mutationContext(providerID: .appleContainerCLI)
        )

        let response = try await dispatcher.dispatch(frame: frame, nowUnixMilliseconds: 1_000)
        let failure = try ContainerizationHelperCanonicalJSON.decodeError(
            from: ContainerizationHelperFraming.decodeSingleFrame(response)
        )
        XCTAssertEqual(failure.error.code, .invalidRequest)
        let recordedOperations = await backend.recordedOperations()
        XCTAssertEqual(recordedOperations, [])
    }

    func testCancellationStopsAnActiveBackendTaskAndReturnsTypedResults() async throws {
        let backend = try TestBackend(
            snapshot: snapshot(),
            inventory: inventory(),
            blockCreateUntilCancelled: true
        )
        let dispatcher = ContainerizationHelperDispatcher(
            backend: backend,
            expectedCapabilityDigest: digest
        )
        let createRequestID = UUID()
        let createFrame = try requestFrame(
            requestID: createRequestID,
            operation: .create,
            payload: createPayload(),
            context: mutationContext()
        )
        let createTask = Task {
            try await dispatcher.dispatch(frame: createFrame, nowUnixMilliseconds: 1_000)
        }

        var createStarted = false
        for _ in 0..<1_000 {
            createStarted = await backend.createStarted()
            if createStarted { break }
            await Task.yield()
        }
        XCTAssertTrue(createStarted)

        let acknowledgement: ContainerizationHelperAcknowledgement = try await dispatch(
            .cancel,
            payload: ContainerizationHelperCancellationPayload(targetRequestID: createRequestID),
            through: dispatcher
        )
        XCTAssertTrue(acknowledgement.accepted)

        let createResponse = try await createTask.value
        let failure = try ContainerizationHelperCanonicalJSON.decodeError(
            from: ContainerizationHelperFraming.decodeSingleFrame(createResponse)
        )
        XCTAssertEqual(failure.error.code, .cancelled)
        let cancelledRequestIDs = await backend.cancelledRequestIDs()
        XCTAssertEqual(cancelledRequestIDs, [createRequestID])
    }

    func testRuntimeDirectoryAndSocketUseExactPrivateModesAndCleanup() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runtimeURL = parent.appendingPathComponent("runtime", isDirectory: true)

        let runtimeDirectory = try ContainerizationHelperRuntimeDirectory.prepare(at: runtimeURL)
        XCTAssertEqual(mode(at: runtimeURL), 0o700)

        let socket = try runtimeDirectory.makeListeningSocket()
        XCTAssertEqual(mode(at: runtimeDirectory.socketURL), 0o600)
        XCTAssertEqual(fileType(at: runtimeDirectory.socketURL), mode_t(S_IFSOCK))

        try socket.closeAndRemove()
        try runtimeDirectory.cleanupDirectoryIfCreated()
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeURL.path))
    }

    func testRuntimeDirectoryRejectsUnsafeModeAndSymlink() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }

        let unsafe = parent.appendingPathComponent("unsafe", isDirectory: true)
        XCTAssertEqual(mkdir(unsafe.path, 0o755), 0)
        XCTAssertThrowsError(try ContainerizationHelperRuntimeDirectory.prepare(at: unsafe)) {
            XCTAssertEqual($0 as? ContainerizationHelperSocketError, .unsafeRuntimeDirectory)
        }

        let target = parent.appendingPathComponent("target", isDirectory: true)
        XCTAssertEqual(mkdir(target.path, 0o700), 0)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        XCTAssertEqual(symlink(target.path, link.path), 0)
        XCTAssertThrowsError(try ContainerizationHelperRuntimeDirectory.prepare(at: link)) {
            XCTAssertEqual($0 as? ContainerizationHelperSocketError, .unsafeRuntimeDirectory)
        }
    }

    func testSocketCleanupRefusesToDeleteAReplacementPath() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runtimeDirectory = try ContainerizationHelperRuntimeDirectory.prepare(
            at: parent.appendingPathComponent("runtime", isDirectory: true)
        )
        let socket = try runtimeDirectory.makeListeningSocket()

        XCTAssertEqual(unlink(runtimeDirectory.socketURL.path), 0)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: runtimeDirectory.socketURL.path,
            contents: Data("sentinel".utf8)
        ))
        XCTAssertThrowsError(try socket.closeAndRemove()) {
            XCTAssertEqual($0 as? ContainerizationHelperSocketError, .socketPathReplaced)
        }
        XCTAssertEqual(
            try Data(contentsOf: runtimeDirectory.socketURL),
            Data("sentinel".utf8)
        )
    }

    func testIdlePolicyAndServerStopOnlyWithoutActiveConnections() async throws {
        let policy = ContainerizationHelperIdlePolicy(timeoutMilliseconds: 100)
        XCTAssertFalse(policy.shouldShutdown(
            nowMilliseconds: 1_100,
            lastActivityMilliseconds: 1_000,
            activeConnections: 1
        ))
        XCTAssertTrue(policy.shouldShutdown(
            nowMilliseconds: 1_100,
            lastActivityMilliseconds: 1_000,
            activeConnections: 0
        ))

        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runtimeDirectory = try ContainerizationHelperRuntimeDirectory.prepare(
            at: parent.appendingPathComponent("runtime", isDirectory: true)
        )
        let backend = try TestBackend(snapshot: snapshot(), inventory: inventory())
        let dispatcher = ContainerizationHelperDispatcher(
            backend: backend,
            expectedCapabilityDigest: digest
        )
        let server = ContainerizationHelperUnixServer(
            runtimeDirectory: runtimeDirectory,
            dispatcher: dispatcher,
            authenticator: ContainerizationHelperPeerAuthenticator { _ in },
            idlePolicy: policy
        )

        try await server.run()
        let terminated = await dispatcher.shouldTerminate()
        XCTAssertTrue(terminated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeDirectory.directoryURL.path))
    }

    private func dispatch<Payload: Codable & Sendable, Result: Codable & Sendable>(
        _ operation: ContainerizationHelperOperation,
        payload: Payload,
        context: RuntimeMutationContext? = nil,
        through dispatcher: ContainerizationHelperDispatcher
    ) async throws -> Result {
        let response = try await dispatcher.dispatch(
            frame: requestFrame(operation: operation, payload: payload, context: context),
            nowUnixMilliseconds: 1_000
        )
        return try ContainerizationHelperCanonicalJSON.decodeResult(
            Result.self,
            from: ContainerizationHelperFraming.decodeSingleFrame(response)
        ).result
    }

    private func requestFrame<Payload: Codable & Sendable>(
        requestID: UUID = UUID(),
        operation: ContainerizationHelperOperation,
        payload: Payload,
        context: RuntimeMutationContext? = nil,
        capabilityDigest: String? = nil
    ) throws -> Data {
        let request = ContainerizationHelperRequest(
            requestID: requestID,
            operation: operation,
            deadlineUnixMilliseconds: 2_000,
            capabilityDigest: capabilityDigest ?? digest,
            mutationContext: context,
            idempotencyKey: "request-\(requestID.uuidString.lowercased())",
            payload: payload
        )
        return try ContainerizationHelperFraming.frame(
            ContainerizationHelperCanonicalJSON.encode(request)
        )
    }

    private func mutationContext(
        providerID: RuntimeProviderID = .appleContainerization,
        capabilitySHA256: String? = nil
    ) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: providerID,
            capabilitySHA256: capabilitySHA256 ?? digest,
            operationID: "operation-1",
            resourceUUID: resourceUUID,
            resourceGeneration: 1,
            projectResourceUUID: projectUUID,
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: fencingToken
        )
    }

    private func createPayload() -> ContainerizationHelperCreatePayload {
        ContainerizationHelperCreatePayload(
            resourceIdentifier: "demo",
            resourceUUID: resourceUUID,
            projectUUID: projectUUID,
            image: TestBackend.imageEvidence,
            command: ["/bin/sh", "-c", "true"],
            environment: [],
            labels: [RuntimeInventoryLabel(key: "dev.hostwright.resource-uuid", value: resourceUUID)]
        )
    }

    private func snapshot() -> RuntimeCapabilitySnapshot {
        RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: .appleContainerization,
                components: [
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationHelper,
                        version: "0.0.2",
                        build: "test",
                        fingerprint: "abcdef0"
                    ),
                    RuntimeProviderComponent(
                        identifier: .containerizationHelperProtocolV1,
                        version: RuntimeProviderCapabilityContract.helperProtocolVersion,
                        build: "test",
                        fingerprint: "abcdef1"
                    ),
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationFramework,
                        version: RuntimeProviderCapabilityContract.containerizationFrameworkVersion,
                        build: "release",
                        fingerprint: "abcdef2"
                    )
                ],
                minimumMacOSVersion: RuntimeProviderMacOSVersion(major: 26),
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: RuntimeProviderMacOSVersion(major: 26),
                macOSBuild: "25A123",
                architecture: .arm64
            ),
            features: RuntimeProviderFeature.knownValues.map {
                RuntimeProviderFeatureStatus(feature: $0, state: .available, reason: .implemented)
            }
        )
    }

    private func inventory() throws -> RuntimeInventory {
        try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "linux",
                architecture: "arm64",
                runtimeVersion: "0.35.0",
                services: [RuntimeInventoryService(identifier: "helper", state: .running, required: true)]
            ),
            containers: [],
            images: [],
            networks: [],
            volumes: []
        )
    }

    private func makePrivateParent() throws -> URL {
        let parent = URL(
            fileURLWithPath: "/tmp/hw-h-\(getpid())-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        guard mkdir(parent.path, 0o700) == 0 else {
            throw ContainerizationHelperSocketError.unsafeParent
        }
        return parent
    }

    private func mode(at url: URL) -> mode_t {
        var metadata = stat()
        XCTAssertEqual(lstat(url.path, &metadata), 0)
        return metadata.st_mode & 0o7777
    }

    private func fileType(at url: URL) -> mode_t {
        var metadata = stat()
        XCTAssertEqual(lstat(url.path, &metadata), 0)
        return metadata.st_mode & S_IFMT
    }
}

private actor TestBackend: ContainerizationHelperBackend {
    static let imageEvidence = ContainerizationHelperImageEvidence(
        reference: "example.local/demo@sha256:abc",
        descriptorDigest: "sha256:abc",
        variantDigest: "sha256:def",
        architecture: "arm64",
        operatingSystem: "linux"
    )

    private let snapshotValue: RuntimeCapabilitySnapshot
    private let observationValue: ContainerizationHelperObservation
    private let blockCreateUntilCancelled: Bool
    private var operations: [ContainerizationHelperOperation] = []
    private var didStartCreate = false
    private var cancellations: [UUID] = []

    init(
        snapshot: RuntimeCapabilitySnapshot,
        inventory: RuntimeInventory,
        blockCreateUntilCancelled: Bool = false
    ) throws {
        self.snapshotValue = snapshot
        self.observationValue = ContainerizationHelperObservation(inventory: inventory)
        self.blockCreateUntilCancelled = blockCreateUntilCancelled
    }

    func negotiate() async throws -> RuntimeCapabilitySnapshot {
        operations.append(.negotiate)
        return snapshotValue
    }

    func observe(_ request: ContainerizationHelperObservePayload) async throws -> ContainerizationHelperObservation {
        operations.append(.observe)
        return observationValue
    }

    func localImageEvidence(_ request: ContainerizationHelperImageRequest) async throws -> ContainerizationHelperImageEvidence {
        operations.append(.localImageEvidence)
        return Self.imageEvidence
    }

    func resourceUsage(_ request: ContainerizationHelperResourceRequest) async throws -> ContainerizationHelperResourceUsage {
        operations.append(.resourceUsage)
        return ContainerizationHelperResourceUsage(
            resourceIdentifier: request.resourceIdentifier,
            cpuUsageMicroseconds: 1,
            memoryUsageBytes: 2,
            memoryLimitBytes: 3,
            networkReceiveBytes: 4,
            networkTransmitBytes: 5,
            blockReadBytes: 6,
            blockWriteBytes: 7,
            processCount: 8
        )
    }

    func logs(_ request: ContainerizationHelperLogsRequest) async throws -> ContainerizationHelperLogs {
        operations.append(.logs)
        return ContainerizationHelperLogs(
            resourceIdentifier: request.resourceIdentifier,
            text: "line\n",
            lineLimit: request.lineLimit
        )
    }

    func create(
        _ request: ContainerizationHelperCreatePayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        operations.append(.create)
        didStartCreate = true
        if blockCreateUntilCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        return ContainerizationHelperMutationResult(
            resourceIdentifier: request.resourceIdentifier,
            lifecycle: .created,
            verified: true
        )
    }

    func start(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        operations.append(.start)
        return mutationResult(request, lifecycle: .running)
    }

    func stop(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        operations.append(.stop)
        return mutationResult(request, lifecycle: .stopped)
    }

    func restart(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        operations.append(.restart)
        return mutationResult(request, lifecycle: .running)
    }

    func delete(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        operations.append(.delete)
        return mutationResult(request, lifecycle: .missing)
    }

    func cancel(requestID: UUID) async {
        cancellations.append(requestID)
    }

    func shutdown() async {}

    func recordedOperations() -> [ContainerizationHelperOperation] {
        operations
    }

    func createStarted() -> Bool {
        didStartCreate
    }

    func cancelledRequestIDs() -> [UUID] {
        cancellations
    }

    private func mutationResult(
        _ request: ContainerizationHelperMutationPayload,
        lifecycle: RuntimeInventoryLifecycleState
    ) -> ContainerizationHelperMutationResult {
        ContainerizationHelperMutationResult(
            resourceIdentifier: request.resourceIdentifier,
            lifecycle: lifecycle,
            verified: true
        )
    }
}
