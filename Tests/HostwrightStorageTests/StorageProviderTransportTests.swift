import Darwin
import Foundation
import XCTest
@testable import HostwrightStorage

final class StorageProviderTransportTests: XCTestCase {
    fileprivate struct RequestPayload: Codable, Equatable, Sendable {
        let value: String
    }

    fileprivate struct ResultPayload: Codable, Equatable, Sendable {
        let accepted: Bool
    }

    func testFramingUsesBigEndianLengthAndRejectsTruncationOverflowAndTrailingBytes() throws {
        let payload = Data(#"{"value":"ok"}"#.utf8)
        let frame = try StorageProviderFraming.frameRequest(payload)

        XCTAssertEqual(Array(frame.prefix(4)), [0, 0, 0, 14])
        XCTAssertEqual(try StorageProviderFraming.decodeRequest(frame), payload)
        XCTAssertThrowsError(
            try StorageProviderFraming.decodeRequest(Data(frame.dropLast()))
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderTransportError,
                .truncatedFrame
            )
        }
        XCTAssertThrowsError(
            try StorageProviderFraming.decodeRequest(frame + Data([0]))
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderProtocolError,
                .nonCanonicalJSON
            )
        }
        XCTAssertThrowsError(
            try StorageProviderFraming.decodeRequest(
                Data([0, 16, 0, 1])
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderTransportError,
                .frameTooLarge
            )
        }
    }

    func testRuntimeDirectoryAndSocketUsePrivateModesAndExactCleanup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeURL = root.appendingPathComponent("runtime", isDirectory: true)

        let runtime = try StorageProviderRuntimeDirectory.prepare(at: runtimeURL)
        XCTAssertEqual(fileMode(runtimeURL), 0o700)
        let lease = try runtime.makeListeningSocket()
        XCTAssertEqual(fileType(lease.socketURL), mode_t(S_IFSOCK))
        XCTAssertEqual(fileMode(lease.socketURL), 0o600)

        try lease.closeAndRemove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.socketURL.path))
        try runtime.cleanupDirectoryIfCreated()
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testRuntimeDirectoryRejectsUnsafeModeSymlinkAndUnsafeParent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeURL = root.appendingPathComponent("runtime", isDirectory: true)

        try FileManager.default.createDirectory(
            at: runtimeURL,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(runtimeURL.path, 0o755), 0)
        XCTAssertThrowsError(
            try StorageProviderRuntimeDirectory.prepare(at: runtimeURL)
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderTransportError,
                .unsafeRuntimeDirectory
            )
        }

        try FileManager.default.removeItem(at: runtimeURL)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(target.path, 0o700), 0)
        try FileManager.default.createSymbolicLink(
            at: runtimeURL,
            withDestinationURL: target
        )
        XCTAssertThrowsError(
            try StorageProviderRuntimeDirectory.prepare(at: runtimeURL)
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderTransportError,
                .unsafeRuntimeDirectory
            )
        }

        try FileManager.default.removeItem(at: runtimeURL)
        XCTAssertEqual(chmod(root.path, 0o777), 0)
        XCTAssertThrowsError(
            try StorageProviderRuntimeDirectory.prepare(at: runtimeURL)
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderTransportError,
                .unsafeParent
            )
        }
    }

    func testPeerIdentityPolicyRejectsWrongUIDPIDSignerTeamAndRequirement() throws {
        let policy = StorageProviderPeerIdentityPolicy(
            expectedUserID: 501,
            expectedProcessID: 42
        )
        let valid = StorageProviderPeerIdentity(
            userID: 501,
            processID: 42,
            codeIdentifier:
                StorageProviderPeerIdentityPolicy.helperCodeIdentifier,
            teamIdentifier:
                StorageProviderPeerIdentityPolicy.expectedTeamIdentifier,
            designatedRequirement:
                StorageProviderPeerIdentityPolicy.helperDesignatedRequirement
        )
        XCTAssertNoThrow(try policy.validate(valid))

        let failures: [
            (StorageProviderPeerIdentity, StorageProviderPeerIdentityError)
        ] = [
            (
                identity(valid, userID: 502),
                .userIDMismatch
            ),
            (
                identity(valid, processID: 0),
                .processIDInvalid
            ),
            (
                identity(valid, processID: 43),
                .processIDMismatch
            ),
            (
                identity(valid, codeIdentifier: "hostwright"),
                .codeIdentifierMismatch
            ),
            (
                identity(valid, teamIdentifier: "AAAAAAAAAA"),
                .teamIdentifierMismatch
            ),
            (
                identity(valid, designatedRequirement: "anchor apple"),
                .designatedRequirementMismatch
            )
        ]
        for (candidate, expected) in failures {
            XCTAssertThrowsError(try policy.validate(candidate)) {
                XCTAssertEqual(
                    $0 as? StorageProviderPeerIdentityError,
                    expected
                )
            }
        }
    }

    func testDispatcherRoutesCanonicalRequestAndRejectsReplayAndProtocolMismatch() async throws {
        let provider = try TestStorageProvider(mode: .success)
        let dispatcher = try await StorageProviderTransportDispatcher.make(
            provider: provider
        )
        let now = unixMilliseconds()
        let request = try await makeRequest(
            provider: provider,
            requestID: fixedRequestID,
            deadline: now + 1_000
        )
        let frame = try StorageProviderFraming.frameRequest(
            StorageProviderCanonicalJSON.encodeRequest(request)
        )

        let first = try await dispatcher.dispatch(
            frame: frame,
            nowUnixMilliseconds: now
        )
        XCTAssertEqual(
            try decodeResult(first).result,
            ResultPayload(accepted: true)
        )

        let replay = try await dispatcher.dispatch(
            frame: frame,
            nowUnixMilliseconds: now
        )
        XCTAssertEqual(
            try decodeFailure(replay).failure.category,
            .replayedRequest
        )

        let incompatible = try await makeRequest(
            provider: provider,
            requestID: UUID(),
            protocolVersion: 2,
            deadline: now + 1_000
        )
        let incompatibleFrame = try StorageProviderFraming.frameRequest(
            StorageProviderCanonicalJSON.encodeRequest(incompatible)
        )
        let incompatibleResult = try await dispatcher.dispatch(
            frame: incompatibleFrame,
            nowUnixMilliseconds: now
        )
        XCTAssertEqual(
            try decodeFailure(incompatibleResult).failure.category,
            .incompatible
        )
        let invocationCount = await provider.invocationCount()
        XCTAssertEqual(invocationCount, 1)
    }

    func testDispatcherFailsClosedForProviderCrashInvalidResponseAndHang() async throws {
        let crash = try TestStorageProvider(mode: .crash)
        let crashDispatcher = try await StorageProviderTransportDispatcher.make(
            provider: crash
        )
        let now = unixMilliseconds()
        let crashResult = try await crashDispatcher.dispatch(
            frame: try await requestFrame(
                provider: crash,
                deadline: now + 1_000
            ),
            nowUnixMilliseconds: now
        )
        XCTAssertEqual(
            try decodeFailure(crashResult).failure.category,
            .crashed
        )

        let invalid = try TestStorageProvider(mode: .invalidResponse)
        let invalidDispatcher = try await StorageProviderTransportDispatcher.make(
            provider: invalid
        )
        let invalidResult = try await invalidDispatcher.dispatch(
            frame: try await requestFrame(
                provider: invalid,
                deadline: now + 1_000
            ),
            nowUnixMilliseconds: now
        )
        XCTAssertEqual(
            try decodeFailure(invalidResult).failure.category,
            .crashed
        )

        let hanging = try TestStorageProvider(mode: .hang)
        let hangingDispatcher = try await StorageProviderTransportDispatcher.make(
            provider: hanging
        )
        let hangResult = try await hangingDispatcher.dispatch(
            frame: try await requestFrame(
                provider: hanging,
                deadline: now + 30
            ),
            nowUnixMilliseconds: now
        )
        let hangFailure = try decodeFailure(hangResult).failure
        XCTAssertEqual(hangFailure.category, .timedOut)
        XCTAssertEqual(hangFailure.retryDisposition, .safeAfterObservation)
        try await waitUntil {
            await hanging.cancelledRequestIDs().count == 1
        }
    }

    func testDispatcherEnforcesAdvertisedRequestAndResultBounds() async throws {
        let now = unixMilliseconds()
        let requestBounded = try TestStorageProvider(
            mode: .success,
            maximumRequestBytes: 32
        )
        let requestDispatcher =
            try await StorageProviderTransportDispatcher.make(
                provider: requestBounded
            )
        let requestResult = try await requestDispatcher.dispatch(
            frame: try await requestFrame(
                provider: requestBounded,
                deadline: now + 1_000
            ),
            nowUnixMilliseconds: now
        )
        XCTAssertEqual(
            try decodeFailure(requestResult).failure.category,
            .outputLimited
        )
        let requestInvocationCount =
            await requestBounded.invocationCount()
        XCTAssertEqual(requestInvocationCount, 0)

        let resultBounded = try TestStorageProvider(
            mode: .success,
            maximumResultBytes: 32
        )
        let resultDispatcher =
            try await StorageProviderTransportDispatcher.make(
                provider: resultBounded
            )
        let result = try await resultDispatcher.dispatch(
            frame: try await requestFrame(
                provider: resultBounded,
                deadline: now + 1_000
            ),
            nowUnixMilliseconds: now
        )
        XCTAssertEqual(
            try decodeFailure(result).failure.category,
            .outputLimited
        )
        let resultInvocationCount = await resultBounded.invocationCount()
        XCTAssertEqual(resultInvocationCount, 1)
    }

    func testDispatcherCancellationCancelsExactProviderRequest() async throws {
        let provider = try TestStorageProvider(mode: .hang)
        let dispatcher = try await StorageProviderTransportDispatcher.make(
            provider: provider
        )
        let requestID = UUID()
        let now = unixMilliseconds()
        let frame = try await requestFrame(
            provider: provider,
            requestID: requestID,
            deadline: now + 5_000
        )
        let task = Task {
            try await dispatcher.dispatch(
                frame: frame,
                nowUnixMilliseconds: now
            )
        }
        try await waitUntil {
            await provider.invocationCount() == 1
        }
        await dispatcher.cancel(requestID: requestID)

        let response = try await task.value
        XCTAssertEqual(
            try decodeFailure(response).failure.category,
            .cancelled
        )
        try await waitUntil {
            await provider.cancelledRequestIDs().contains(requestID)
        }
    }

    func testUnixServerRoundTripAndCancellationRemoveSocketAndDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeURL = root.appendingPathComponent("runtime", isDirectory: true)
        let runtime = try StorageProviderRuntimeDirectory.prepare(at: runtimeURL)
        let provider = try TestStorageProvider(mode: .success)
        let dispatcher = try await StorageProviderTransportDispatcher.make(
            provider: provider
        )
        let server = try StorageProviderUnixServer(
            runtimeDirectory: runtime,
            dispatcher: dispatcher,
            authenticator: StorageProviderServerPeerAuthenticator { _ in },
            connectionTimeoutMilliseconds: 1_000
        )
        let serverTask = Task {
            try await server.run()
        }
        try await waitUntil {
            FileManager.default.fileExists(atPath: runtime.socketURL.path)
        }

        let request = try await makeRequest(
            provider: provider,
            requestID: fixedRequestID,
            deadline: unixMilliseconds() + 2_000
        )
        let frame = try StorageProviderFraming.frameRequest(
            StorageProviderCanonicalJSON.encodeRequest(request)
        )
        let transport = StorageProviderClientTransport.unix(
            authenticator: StorageProviderClientPeerAuthenticator { _, expectedPID in
                expectedPID ?? getpid()
            }
        )
        let response = try await transport.exchange(
            frame: frame,
            socketURL: runtime.socketURL,
            deadlineUnixMilliseconds: unixMilliseconds() + 2_000,
            expectedProcessID: getpid()
        )
        XCTAssertEqual(response.peerProcessID, getpid())
        XCTAssertTrue(response.socketDevice > 0)
        XCTAssertTrue(response.socketInode > 0)
        XCTAssertTrue(try decodeResult(response.frame).result.accepted)

        serverTask.cancel()
        try await serverTask.value
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: runtime.socketURL.path)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeURL.path))
    }

    func testUnixServerRejectsNonPositiveConnectionTimeout() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try StorageProviderRuntimeDirectory.prepare(
            at: root.appendingPathComponent("runtime", isDirectory: true)
        )
        let provider = try TestStorageProvider(mode: .success)
        let dispatcher = try await StorageProviderTransportDispatcher.make(
            provider: provider
        )

        XCTAssertThrowsError(
            try StorageProviderUnixServer(
                runtimeDirectory: runtime,
                dispatcher: dispatcher,
                authenticator: StorageProviderServerPeerAuthenticator { _ in },
                connectionTimeoutMilliseconds: 0
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderTransportError,
                .invalidTimeout
            )
        }
        try runtime.cleanupDirectoryIfCreated()
    }

    private let fixedRequestID =
        UUID(uuidString: "01234567-89ab-cdef-8123-456789abcdef")!

    private func makeRequest(
        provider: TestStorageProvider,
        requestID: UUID,
        protocolVersion: Int = StorageProviderContract.protocolVersion,
        deadline: Int64
    ) async throws -> StorageProviderRequest<RequestPayload> {
        StorageProviderRequest(
            protocolVersion: protocolVersion,
            requestID: requestID,
            operation: .observe,
            deadlineUnixMilliseconds: deadline,
            capabilitySHA256: try await provider.descriptor().canonicalSHA256(),
            idempotencyKey: requestID.uuidString.lowercased(),
            payload: RequestPayload(value: "observe")
        )
    }

    private func requestFrame(
        provider: TestStorageProvider,
        requestID: UUID = UUID(),
        deadline: Int64
    ) async throws -> Data {
        try StorageProviderFraming.frameRequest(
            StorageProviderCanonicalJSON.encodeRequest(
                try await makeRequest(
                    provider: provider,
                    requestID: requestID,
                    deadline: deadline
                )
            )
        )
    }

    private func decodeResult(
        _ frame: Data
    ) throws -> StorageProviderResultEnvelope<ResultPayload> {
        try StorageProviderCanonicalJSON.decodeResult(
            ResultPayload.self,
            from: StorageProviderFraming.decodeResult(frame)
        )
    }

    private func decodeFailure(
        _ frame: Data
    ) throws -> StorageProviderErrorEnvelope {
        try StorageProviderCanonicalJSON.decodeError(
            from: StorageProviderFraming.decodeResult(frame)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".hws-transport-\(suffix)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(url.path, 0o700), 0)
        return url
    }

    private func fileMode(_ url: URL) -> mode_t {
        var metadata = stat()
        XCTAssertEqual(lstat(url.path, &metadata), 0)
        return metadata.st_mode & 0o7777
    }

    private func fileType(_ url: URL) -> mode_t {
        var metadata = stat()
        XCTAssertEqual(lstat(url.path, &metadata), 0)
        return metadata.st_mode & S_IFMT
    }

    private func identity(
        _ base: StorageProviderPeerIdentity,
        userID: uid_t? = nil,
        processID: pid_t? = nil,
        codeIdentifier: String? = nil,
        teamIdentifier: String? = nil,
        designatedRequirement: String? = nil
    ) -> StorageProviderPeerIdentity {
        StorageProviderPeerIdentity(
            userID: userID ?? base.userID,
            processID: processID ?? base.processID,
            codeIdentifier: codeIdentifier ?? base.codeIdentifier,
            teamIdentifier: teamIdentifier ?? base.teamIdentifier,
            designatedRequirement:
                designatedRequirement ?? base.designatedRequirement
        )
    }

    private func unixMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private func waitUntil(
        timeoutMilliseconds: Int = 2_000,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(timeoutMilliseconds)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for asynchronous condition.")
    }
}

private actor TestStorageProvider: StorageProviderSPI {
    enum Mode: Sendable {
        case success
        case crash
        case invalidResponse
        case hang
    }

    enum TestError: Error {
        case crashed
    }

    private let descriptorValue: StorageProviderDescriptor
    private let mode: Mode
    private var invocations = 0
    private var cancellations: [UUID] = []

    init(
        mode: Mode,
        maximumRequestBytes: Int =
            StorageProviderContract.maximumRequestBytes,
        maximumResultBytes: Int =
            StorageProviderContract.maximumResultBytes
    ) throws {
        descriptorValue = StorageProviderDescriptor(
            providerID: "hostwright-test",
            providerVersion: "1.0.0",
            capabilities: StorageProviderOperation.allCases.map {
                StorageProviderCapability(
                    operation: $0,
                    state: .available,
                    reason: "test provider"
                )
            },
            maximumRequestBytes: maximumRequestBytes,
            maximumResultBytes: maximumResultBytes
        )
        try StorageProviderDescriptorValidator.validate(descriptorValue)
        self.mode = mode
    }

    func descriptor() async throws -> StorageProviderDescriptor {
        descriptorValue
    }

    func invoke(canonicalRequest: Data) async throws -> Data {
        invocations += 1
        switch mode {
        case .success:
            let request = try StorageProviderCanonicalJSON.decodeRequest(
                StorageProviderTransportTests.RequestPayload.self,
                from: canonicalRequest
            )
            return try StorageProviderCanonicalJSON.encodeResult(
                StorageProviderResultEnvelope(
                    requestID: request.requestID,
                    operation: request.operation,
                    result: StorageProviderTransportTests.ResultPayload(
                        accepted: true
                    )
                )
            )
        case .crash:
            throw TestError.crashed
        case .invalidResponse:
            return Data(#"{"invalid":true}"#.utf8)
        case .hang:
            try await Task.sleep(for: .seconds(60))
            throw TestError.crashed
        }
    }

    func cancel(requestID: UUID) async {
        cancellations.append(requestID)
    }

    func invocationCount() -> Int {
        invocations
    }

    func cancelledRequestIDs() -> [UUID] {
        cancellations
    }
}
