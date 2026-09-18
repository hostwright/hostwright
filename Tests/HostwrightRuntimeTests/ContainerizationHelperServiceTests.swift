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
        XCTAssertEqual(create.lifecycle, .stopped)

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
            labels: [],
            cpuCount: 1,
            memoryBytes: 536_870_912
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
            blockCreateUntilCancelled: true,
            allowsIdleShutdown: true
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

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var createStarted = false
        while clock.now < deadline {
            createStarted = await backend.createStarted()
            if createStarted { break }
            try await clock.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(createStarted)
        let idleDuringCreate = await dispatcher.requestIdleShutdown()
        XCTAssertFalse(idleDuringCreate)
        let idleChecksDuringCreate = await backend.idleCheckCount()
        XCTAssertEqual(idleChecksDuringCreate, 0)

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
        let backend = try TestBackend(snapshot: snapshot(), inventory: inventory(), allowsIdleShutdown: true)
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

    func testIdleDecisionFencesDispatchUntilBackendRefuses() async throws {
        let backend = try TestBackend(snapshot: snapshot(), inventory: inventory(), blocksIdleDecision: true)
        let dispatcher = ContainerizationHelperDispatcher(backend: backend, expectedCapabilityDigest: digest)
        let idleTask = Task { await dispatcher.requestIdleShutdown() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while await backend.idleCheckCount() == 0, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(1))
        }
        let checks = await backend.idleCheckCount()
        XCTAssertEqual(checks, 1)
        do {
            _ = try await dispatcher.dispatch(frame: Data(), nowUnixMilliseconds: 1_000)
            XCTFail("Idle decision must fence even malformed requests before decoding.")
        } catch {
            XCTAssertEqual(error as? ContainerizationHelperServiceError, .shuttingDown)
        }
        await backend.releaseIdleDecision()
        let accepted = await idleTask.value
        XCTAssertFalse(accepted)
        let result: RuntimeCapabilitySnapshot = try await dispatch(
            .negotiate, payload: ContainerizationHelperEmptyPayload(), through: dispatcher
        )
        XCTAssertEqual(result, snapshot())
    }

    func testDisconnectedUnixClientDoesNotShutDownRetainedBackend() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = try ContainerizationHelperRuntimeDirectory.prepare(
            at: parent.appendingPathComponent("runtime", isDirectory: true)
        )
        let backend = try TestBackend(snapshot: snapshot(), inventory: inventory())
        let dispatcher = ContainerizationHelperDispatcher(backend: backend, expectedCapabilityDigest: digest)
        let server = ContainerizationHelperUnixServer(
            runtimeDirectory: directory, dispatcher: dispatcher,
            authenticator: ContainerizationHelperPeerAuthenticator { descriptor in
                try Self.requireCurrentFixturePeer(descriptor)
            },
            idlePolicy: .init(timeoutMilliseconds: 25)
        )
        let serverTask = Task { try await server.run() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        do {
            while !FileManager.default.fileExists(atPath: directory.socketURL.path), clock.now < deadline {
                try await clock.sleep(for: .milliseconds(1))
            }
            let requestDeadline = Int64(Date().timeIntervalSince1970 * 1_000) + 5_000
            let negotiation = try await Self.exchangeWithCurrentFixture(
                frame: requestFrame(operation: .negotiate, payload: ContainerizationHelperEmptyPayload(),
                                    deadlineUnixMilliseconds: requestDeadline),
                socketURL: directory.socketURL, privateParent: parent
            )
            let negotiated = try ContainerizationHelperCanonicalJSON.decodeResult(
                RuntimeCapabilitySnapshot.self,
                from: ContainerizationHelperFraming.decodeSingleFrame(negotiation)
            )
            XCTAssertEqual(negotiated.result, snapshot())
            let postDisconnectIdleBaseline = await backend.idleCheckCount()
            while await backend.idleCheckCount() < postDisconnectIdleBaseline + 2, clock.now < deadline {
                try await clock.sleep(for: .milliseconds(1))
            }
            let checks = await backend.idleCheckCount()
            XCTAssertGreaterThanOrEqual(checks - postDisconnectIdleBaseline, 2)
            let terminated = await dispatcher.shouldTerminate()
            XCTAssertFalse(terminated)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.socketURL.path))
            let shutdown = try await Self.exchangeWithCurrentFixture(
                frame: requestFrame(operation: .shutdown, payload: ContainerizationHelperEmptyPayload(),
                                    deadlineUnixMilliseconds: requestDeadline),
                socketURL: directory.socketURL, privateParent: parent
            )
            let acknowledgement = try ContainerizationHelperCanonicalJSON.decodeResult(
                ContainerizationHelperAcknowledgement.self,
                from: ContainerizationHelperFraming.decodeSingleFrame(shutdown)
            )
            XCTAssertTrue(acknowledgement.result.accepted)
        } catch {
            await dispatcher.requestShutdown()
            _ = try? await serverTask.value
            throw error
        }
        try await serverTask.value
        let shutdownCalls = await backend.shutdownCount()
        XCTAssertEqual(shutdownCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.directoryURL.path))
    }

    private static func requireCurrentFixturePeer(_ descriptor: Int32) throws {
        var uid = uid_t.max
        var gid = gid_t.max
        var pid = pid_t(0)
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid(),
              getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              size == MemoryLayout<pid_t>.size, pid == getpid() else {
            throw ContainerizationHelperClientError.peerAuthenticationFailed
        }
    }

    // This in-process fixture authenticates its own PID/UID, not the signed product helper.
    private static func exchangeWithCurrentFixture(
        frame: Data, socketURL: URL, privateParent: URL
    ) async throws -> Data {
        try await Task.detached {
            guard socketURL.deletingLastPathComponent().deletingLastPathComponent() == privateParent else {
                throw POSIXError(.EINVAL)
            }
            for directory in [privateParent, socketURL.deletingLastPathComponent()] {
                var metadata = stat()
                guard lstat(directory.path, &metadata) == 0,
                      metadata.st_mode & S_IFMT == mode_t(S_IFDIR),
                      metadata.st_mode & 0o7777 == 0o700, metadata.st_uid == geteuid() else {
                    throw POSIXError(.EACCES)
                }
            }
            var before = stat()
            guard lstat(socketURL.path, &before) == 0,
                  before.st_mode & S_IFMT == mode_t(S_IFSOCK),
                  before.st_mode & 0o7777 == 0o600, before.st_uid == geteuid() else {
                throw POSIXError(.EACCES)
            }
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(descriptor) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            var noSignal: Int32 = 1
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                  setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                             socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                             socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                             socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw POSIXError(.EIO) }
            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketURL.path.utf8) + [UInt8(0)]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw POSIXError(.ENAMETOOLONG)
            }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            try requireCurrentFixturePeer(descriptor)
            var after = stat()
            guard lstat(socketURL.path, &after) == 0,
                  after.st_dev == before.st_dev, after.st_ino == before.st_ino else {
                throw POSIXError(.ESTALE)
            }
            var offset = 0
            while offset < frame.count {
                let written = frame.withUnsafeBytes {
                    Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), frame.count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
            func readExact(_ count: Int) throws -> Data {
                var data = Data(count: count)
                var offset = 0
                while offset < count {
                    let received = data.withUnsafeMutableBytes {
                        Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset)
                    }
                    if received < 0, errno == EINTR { continue }
                    guard received > 0 else { throw POSIXError(.EIO) }
                    offset += received
                }
                return data
            }
            let header = try readExact(ContainerizationHelperProtocolV1.frameHeaderBytes)
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= UInt32(ContainerizationHelperProtocolV1.maximumPayloadBytes) else {
                throw ContainerizationHelperProtocolError.frameTooLarge
            }
            return header + (try readExact(Int(length)))
        }.value
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
        capabilityDigest: String? = nil,
        deadlineUnixMilliseconds: Int64 = 2_000
    ) throws -> Data {
        let request = ContainerizationHelperRequest(
            requestID: requestID,
            operation: operation,
            deadlineUnixMilliseconds: deadlineUnixMilliseconds,
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

    func testCreateAllocationRoundTripsAndDispatcherRejectsMissingOrInvalidLimits() async throws {
        let backend = try TestBackend(snapshot: snapshot(), inventory: inventory())
        let dispatcher = ContainerizationHelperDispatcher(backend: backend, expectedCapabilityDigest: digest)
        let valid = createPayload()
        let encoded = try JSONEncoder().encode(valid)
        XCTAssertEqual(try JSONDecoder().decode(ContainerizationHelperCreatePayload.self, from: encoded), valid)
        for (cpu, memory): (Int?, UInt64?) in [(nil, nil), (0, 1), (1, 0), (1, UInt64.max)] {
            let payload = ContainerizationHelperCreatePayload(
                resourceIdentifier: valid.resourceIdentifier, resourceUUID: valid.resourceUUID,
                projectUUID: valid.projectUUID, image: valid.image, command: valid.command,
                environment: valid.environment, labels: valid.labels, cpuCount: cpu, memoryBytes: memory
            )
            do {
                let _: ContainerizationHelperMutationResult = try await dispatch(.create, payload: payload, context: mutationContext(), through: dispatcher)
                XCTFail("Expected allocation rejection")
            } catch {}
        }
        let operations = await backend.recordedOperations()
        XCTAssertFalse(operations.contains(.create))
    }

    private func createPayload() -> ContainerizationHelperCreatePayload {
        ContainerizationHelperCreatePayload(
            resourceIdentifier: "demo",
            resourceUUID: resourceUUID,
            projectUUID: projectUUID,
            image: TestBackend.imageEvidence,
            command: ["/bin/sh", "-c", "true"],
            environment: [],
            labels: [RuntimeInventoryLabel(key: "dev.hostwright.resource-uuid", value: resourceUUID)],
            cpuCount: 1,
            memoryBytes: 536_870_912
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
    private let allowsIdleShutdown: Bool
    private let blocksIdleDecision: Bool
    private var idleChecks = 0
    private var shutdownCalls = 0
    private var idleContinuation: CheckedContinuation<Void, Never>?
    private let blockCreateUntilCancelled: Bool
    private var operations: [ContainerizationHelperOperation] = []
    private var didStartCreate = false
    private var cancellations: [UUID] = []

    init(
        snapshot: RuntimeCapabilitySnapshot,
        inventory: RuntimeInventory,
        blockCreateUntilCancelled: Bool = false,
        allowsIdleShutdown: Bool = false,
        blocksIdleDecision: Bool = false
    ) throws {
        self.snapshotValue = snapshot
        self.observationValue = ContainerizationHelperObservation(inventory: inventory)
        self.blockCreateUntilCancelled = blockCreateUntilCancelled
        self.allowsIdleShutdown = allowsIdleShutdown
        self.blocksIdleDecision = blocksIdleDecision
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
            lifecycle: .stopped,
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

    func shutdown() async { shutdownCalls += 1 }

    func shutdownIfIdle() async -> Bool {
        idleChecks += 1
        if blocksIdleDecision {
            await withCheckedContinuation { idleContinuation = $0 }
        }
        guard allowsIdleShutdown else { return false }
        await shutdown()
        return true
    }

    func releaseIdleDecision() {
        idleContinuation?.resume()
        idleContinuation = nil
    }

    func idleCheckCount() -> Int { idleChecks }
    func shutdownCount() -> Int { shutdownCalls }

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
