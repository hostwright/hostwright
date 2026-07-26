import Darwin
import Foundation
import HostwrightCore
import XCTest
@testable import HostwrightStorage

final class StorageProviderHelperBootstrapTests: XCTestCase {
    func testLaunchConnectsWithExpectedPIDAndCleansExactly() async throws {
        let harness = try HelperBootstrapHarness()
        defer { harness.removeRoot() }
        let exchangeCount = LockedCounter()
        let transport = StorageProviderClientTransport {
            frame,
            socketURL,
            _,
            expectedProcessID in
            XCTAssertEqual(socketURL, harness.configuration.socketURL)
            XCTAssertEqual(expectedProcessID, harness.process.processID)
            exchangeCount.increment()
            return StorageProviderTransportResponse(
                frame: frame,
                peerProcessID: harness.process.processID,
                socketDevice: 1,
                socketInode: 2
            )
        }
        let session = try await harness.bootstrap(
            transport: transport
        ).launch()
        let frame = try StorageProviderFraming.frameRequest(
            Data(#"{"operation":"health"}"#.utf8)
        )
        let response = try await session.exchange(frame: frame)
        XCTAssertEqual(response.frame, frame)
        XCTAssertEqual(exchangeCount.value, 1)

        try await session.close()
        XCTAssertEqual(harness.process.terminationCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.configuration.runtimeDirectoryURL.path
            )
        )
    }

    func testExplicitRequestDeadlineOverridesSessionDefaultWithinProtocolBound()
        async throws
    {
        let harness = try HelperBootstrapHarness()
        defer { harness.removeRoot() }
        let capturedDeadline = LockedInt64()
        let transport = StorageProviderClientTransport {
            frame,
            _,
            deadline,
            expectedProcessID in
            capturedDeadline.set(deadline)
            return StorageProviderTransportResponse(
                frame: frame,
                peerProcessID: expectedProcessID ?? 0,
                socketDevice: 1,
                socketInode: 2
            )
        }
        let session = try await harness.bootstrap(
            transport: transport
        ).launch()
        let frame = try StorageProviderFraming.frameRequest(
            Data(#"{"operation":"backup"}"#.utf8)
        )
        let requestedDeadline =
            Int64(Date().timeIntervalSince1970 * 1_000) + 5_000

        _ = try await session.exchange(
            frame: frame,
            deadlineUnixMilliseconds: requestedDeadline
        )

        XCTAssertEqual(capturedDeadline.value, requestedDeadline)
        try await session.close()
    }

    func testProductionValidatorRejectsMissingSymlinkAndUntrustedCode()
        throws
    {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(
            StorageProviderPeerIdentityPolicy.helperCodeIdentifier
        )

        XCTAssertThrowsError(
            try StorageProviderHelperExecutableValidator.signed
                .validate(executable)
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderHelperBootstrapError,
                .executableUnavailable
            )
        }

        try FileManager.default.createSymbolicLink(
            at: executable,
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        XCTAssertThrowsError(
            try StorageProviderHelperExecutableValidator.signed
                .validate(executable)
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderHelperBootstrapError,
                .unsafeExecutable
            )
        }
        try FileManager.default.removeItem(at: executable)

        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: executable
        )
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
        let canonicalExecutable = executable.resolvingSymlinksInPath()
        XCTAssertThrowsError(
            try StorageProviderHelperExecutableValidator.signed
                .validate(canonicalExecutable)
        ) {
            guard let error =
                $0 as? StorageProviderHelperBootstrapError else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertTrue(
                [
                    StorageProviderHelperBootstrapError.unsafeExecutable,
                    .signerMismatch
                ].contains(error)
            )
        }
    }

    func testSystemLauncherResumesSuspendedProcessBeforeReaping()
        throws
    {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(
            StorageProviderPeerIdentityPolicy.helperCodeIdentifier
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: executable
        )
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
        let configuration =
            try StorageProviderHelperBootstrapConfiguration(
                executableURL: executable,
                runtimeDirectoryURL: root.appendingPathComponent(
                    "runtime",
                    isDirectory: true
                ),
                providerRootURL: root.appendingPathComponent(
                    "provider",
                    isDirectory: true
                ),
                capacityBytes: 1_048_576
            )
        let identity = try SecureExecutableResolver.verify(
            path: executable.path
        )
        let lease = try StorageProviderHelperProcessLauncher.system
            .launch(
                configuration: configuration,
                executableIdentity: identity
            )
        defer { lease.terminate() }

        XCTAssertTrue(lease.isRunning)
        XCTAssertNoThrow(try lease.resume())
        let deadline = Date(timeIntervalSinceNow: 2)
        while lease.isRunning, Date() < deadline {
            usleep(10_000)
        }
        XCTAssertFalse(lease.isRunning)
    }

    func testWrongSignerFailsBeforeResumeAndCleans() async throws {
        let harness = try HelperBootstrapHarness()
        defer { harness.removeRoot() }
        let validator = StorageProviderHelperExecutableValidator(
            validate: { _ in
                throw StorageProviderHelperBootstrapError.signerMismatch
            },
            verifyUnchanged: { _ in }
        )
        do {
            _ = try await harness.bootstrap(
                validator: validator
            ).launch()
            XCTFail("Expected signer rejection")
        } catch {
            XCTAssertEqual(
                error as? StorageProviderHelperBootstrapError,
                .signerMismatch
            )
        }
        XCTAssertEqual(harness.process.resumeCount, 0)
        XCTAssertEqual(harness.process.terminationCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.configuration.runtimeDirectoryURL.path
            )
        )
    }

    func testRevokedSignerFailsBeforeResumeAndCleans()
        async throws
    {
        let harness = try HelperBootstrapHarness()
        defer { harness.removeRoot() }
        let validator = StorageProviderHelperExecutableValidator(
            validate: { _ in
                throw StorageProviderHelperBootstrapError
                    .signerRevoked
            },
            verifyUnchanged: { _ in }
        )

        do {
            _ = try await harness.bootstrap(
                validator: validator
            ).launch()
            XCTFail("Expected revoked signer rejection")
        } catch {
            XCTAssertEqual(
                error as? StorageProviderHelperBootstrapError,
                .signerRevoked
            )
        }
        XCTAssertEqual(harness.process.resumeCount, 0)
        XCTAssertEqual(harness.process.terminationCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    harness.configuration.runtimeDirectoryURL.path
            )
        )
    }

    func testChangedExecutableTerminatesSuspendedProcessAndCleans() async throws {
        let harness = try HelperBootstrapHarness()
        defer { harness.removeRoot() }
        let validator = StorageProviderHelperExecutableValidator(
            validate: { _ in harness.executableIdentity },
            verifyUnchanged: { _ in
                throw StorageProviderHelperBootstrapError
                    .executableChanged
            }
        )

        do {
            _ = try await harness.bootstrap(
                validator: validator
            ).launch()
            XCTFail("Expected executable replacement rejection")
        } catch {
            XCTAssertEqual(
                error as? StorageProviderHelperBootstrapError,
                .executableChanged
            )
        }
        XCTAssertEqual(harness.process.resumeCount, 0)
        XCTAssertEqual(harness.process.terminationCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.configuration.runtimeDirectoryURL.path
            )
        )
    }

    func testCrashAndHangTerminateAndLeaveNoSocketOrProcess() async throws {
        let crashed = try HelperBootstrapHarness(
            launchTimeoutMilliseconds: 50,
            createSocketOnResume: false
        )
        crashed.process.running = false
        defer { crashed.removeRoot() }
        do {
            _ = try await crashed.bootstrap().launch()
            XCTFail("Expected helper exit")
        } catch {
            XCTAssertEqual(
                error as? StorageProviderHelperBootstrapError,
                .helperExited
            )
        }
        XCTAssertEqual(crashed.process.terminationCount, 1)

        let hanging = try HelperBootstrapHarness(
            launchTimeoutMilliseconds: 30,
            createSocketOnResume: false
        )
        defer { hanging.removeRoot() }
        do {
            _ = try await hanging.bootstrap().launch()
            XCTFail("Expected launch timeout")
        } catch {
            XCTAssertEqual(
                error as? StorageProviderHelperBootstrapError,
                .timedOut
            )
        }
        XCTAssertEqual(hanging.process.terminationCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: hanging.configuration.runtimeDirectoryURL.path
            )
        )
    }

    func testCancellationTerminatesAndReapsLaunch() async throws {
        let harness = try HelperBootstrapHarness(
            launchTimeoutMilliseconds: 5_000,
            createSocketOnResume: false
        )
        defer { harness.removeRoot() }
        let task = Task {
            try await harness.bootstrap().launch()
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(
                error as? StorageProviderHelperBootstrapError,
                .cancelled
            )
        }
        XCTAssertEqual(harness.process.terminationCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.configuration.socketURL.path
            )
        )
    }

    func testFrameAndOutputOverflowAndWrongPeerTerminateSession()
        async throws
    {
        let overflow = try HelperBootstrapHarness()
        defer { overflow.removeRoot() }
        let overflowSession = try await overflow.bootstrap().launch()
        do {
            _ = try await overflowSession.exchange(
                frame: Data(
                    repeating: 0,
                    count:
                        StorageProviderContract.maximumRequestBytes +
                        StorageProviderFraming.headerBytes + 1
                )
            )
            XCTFail("Expected frame limit")
        } catch {
            XCTAssertEqual(
                error as? StorageProviderHelperBootstrapError,
                .frameTooLarge
            )
        }
        XCTAssertEqual(overflow.process.terminationCount, 1)

        let outputOverflow = try HelperBootstrapHarness()
        defer { outputOverflow.removeRoot() }
        let outputOverflowTransport = StorageProviderClientTransport {
            _,
            _,
            _,
            expectedProcessID in
            StorageProviderTransportResponse(
                frame: Data(
                    repeating: 0,
                    count:
                        StorageProviderContract.maximumResultBytes +
                        StorageProviderFraming.headerBytes + 1
                ),
                peerProcessID: expectedProcessID ?? 0,
                socketDevice: 1,
                socketInode: 2
            )
        }
        let outputOverflowSession = try await outputOverflow.bootstrap(
            transport: outputOverflowTransport
        ).launch()
        let requestFrame = try StorageProviderFraming.frameRequest(
            Data(#"{"operation":"health"}"#.utf8)
        )
        do {
            _ = try await outputOverflowSession.exchange(
                frame: requestFrame
            )
            XCTFail("Expected output frame limit")
        } catch {
            XCTAssertEqual(
                error as? StorageProviderHelperBootstrapError,
                .frameTooLarge
            )
        }
        XCTAssertEqual(outputOverflow.process.terminationCount, 1)

        let wrongPeer = try HelperBootstrapHarness()
        defer { wrongPeer.removeRoot() }
        let transport = StorageProviderClientTransport {
            frame,
            _,
            _,
            _ in
            StorageProviderTransportResponse(
                frame: frame,
                peerProcessID: wrongPeer.process.processID + 1,
                socketDevice: 1,
                socketInode: 2
            )
        }
        let wrongPeerSession = try await wrongPeer.bootstrap(
            transport: transport
        ).launch()
        do {
            _ = try await wrongPeerSession.exchange(
                frame: requestFrame
            )
            XCTFail("Expected peer mismatch")
        } catch {
            XCTAssertEqual(
                error as? StorageProviderHelperBootstrapError,
                .peerAuthenticationFailed
            )
        }
        XCTAssertEqual(wrongPeer.process.terminationCount, 1)
    }

    func testRestartAfterExactCleanupAndUnknownEntryRefusal() async throws {
        let first = try HelperBootstrapHarness()
        defer { first.removeRoot() }
        let firstSession = try await first.bootstrap().launch()
        try await firstSession.close()

        let secondControl = FakeHelperProcess(
            configuration: first.configuration,
            processID: 4343,
            createSocketOnResume: true
        )
        let secondBootstrap = StorageProviderHelperBootstrap(
            configuration: first.configuration,
            executableValidator: first.validator,
            launcher: secondControl.launcher
        )
        let secondSession = try await secondBootstrap.launch()
        try await secondSession.close()
        XCTAssertEqual(secondControl.terminationCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: first.configuration.runtimeDirectoryURL.path
            )
        )

        let guarded = try HelperBootstrapHarness()
        defer { guarded.removeRoot() }
        let guardedSession = try await guarded.bootstrap().launch()
        let sentinel = guarded.configuration.runtimeDirectoryURL
            .appendingPathComponent("unmanaged")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: sentinel.path,
                contents: Data("sentinel".utf8)
            )
        )
        do {
            try await guardedSession.close()
            XCTFail("Expected exact cleanup refusal")
        } catch {
            XCTAssertEqual(
                error as? StorageProviderHelperBootstrapError,
                .cleanupFailed
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinel.path)
        )
    }

    func testConfigurationRejectsUnsafeAndOverlappingPaths() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(
            StorageProviderPeerIdentityPolicy.helperCodeIdentifier
        )
        XCTAssertThrowsError(
            try StorageProviderHelperBootstrapConfiguration(
                executableURL: executable,
                runtimeDirectoryURL: URL(
                    fileURLWithPath: "/"
                ),
                providerRootURL: root.appendingPathComponent("provider"),
                capacityBytes: 4096
            )
        )
        XCTAssertThrowsError(
            try StorageProviderHelperBootstrapConfiguration(
                executableURL: executable,
                runtimeDirectoryURL: root.appendingPathComponent("runtime"),
                providerRootURL: root
                    .appendingPathComponent("runtime")
                    .appendingPathComponent("provider"),
                capacityBytes: 4096
            )
        )
    }
}

private final class HelperBootstrapHarness: @unchecked Sendable {
    let rootURL: URL
    let configuration: StorageProviderHelperBootstrapConfiguration
    let executableIdentity: SecureExecutableIdentity
    let process: FakeHelperProcess
    let validator: StorageProviderHelperExecutableValidator

    init(
        launchTimeoutMilliseconds: Int64 = 500,
        createSocketOnResume: Bool = true
    ) throws {
        rootURL = try makePrivateTemporaryDirectory()
        let executableURL = rootURL.appendingPathComponent(
            StorageProviderPeerIdentityPolicy.helperCodeIdentifier
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: executableURL.path,
                contents: Data([0xca, 0xfe])
            )
        )
        XCTAssertEqual(chmod(executableURL.path, 0o700), 0)
        let runtimeParent = rootURL.appendingPathComponent(
            "run",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtimeParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        configuration = try StorageProviderHelperBootstrapConfiguration(
            executableURL: executableURL,
            runtimeDirectoryURL: runtimeParent.appendingPathComponent(
                "storage",
                isDirectory: true
            ),
            providerRootURL: rootURL.appendingPathComponent(
                "provider",
                isDirectory: true
            ),
            capacityBytes: 1_048_576,
            launchTimeoutMilliseconds: launchTimeoutMilliseconds,
            requestTimeoutMilliseconds: 1_000
        )
        executableIdentity = SecureExecutableIdentity(
            path: executableURL.path,
            device: 1,
            inode: 2,
            ownerUserID: UInt32(geteuid()),
            mode: 0o700,
            sizeBytes: 2,
            modifiedSeconds: 1,
            modifiedNanoseconds: 0,
            changedSeconds: 1,
            changedNanoseconds: 0,
            ownershipPolicy: .rootOrCurrentUser
        )
        process = FakeHelperProcess(
            configuration: configuration,
            processID: 4242,
            createSocketOnResume: createSocketOnResume
        )
        let expectedIdentity = executableIdentity
        validator = StorageProviderHelperExecutableValidator(
            validate: { _ in expectedIdentity },
            verifyUnchanged: { identity in
                guard identity == expectedIdentity else {
                    throw StorageProviderHelperBootstrapError
                        .executableChanged
                }
            }
        )
    }

    func bootstrap(
        validator: StorageProviderHelperExecutableValidator? = nil,
        transport: StorageProviderClientTransport =
            StorageProviderClientTransport {
                frame,
                _,
                _,
                expectedProcessID in
                StorageProviderTransportResponse(
                    frame: frame,
                    peerProcessID: expectedProcessID ?? 0,
                    socketDevice: 1,
                    socketInode: 2
                )
            }
    ) -> StorageProviderHelperBootstrap {
        StorageProviderHelperBootstrap(
            configuration: configuration,
            executableValidator: validator ?? self.validator,
            launcher: process.launcher,
            transport: transport
        )
    }

    func removeRoot() {
        process.forceCleanup()
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class FakeHelperProcess: @unchecked Sendable {
    let configuration: StorageProviderHelperBootstrapConfiguration
    let processID: pid_t
    let createSocketOnResume: Bool

    private let lock = NSLock()
    private var socketLease: StorageProviderSocketLease?
    private var resumeCounter = 0
    private var terminationCounter = 0
    private var terminationCalled = false
    private var runningValue = true

    init(
        configuration: StorageProviderHelperBootstrapConfiguration,
        processID: pid_t,
        createSocketOnResume: Bool
    ) {
        self.configuration = configuration
        self.processID = processID
        self.createSocketOnResume = createSocketOnResume
    }

    var launcher: StorageProviderHelperProcessLauncher {
        StorageProviderHelperProcessLauncher {
            [self] configuration,
            _ in
            XCTAssertEqual(configuration, self.configuration)
            return StorageProviderHelperProcessLease(
                processID: processID,
                isRunning: { [self] in
                    lock.withLock { runningValue }
                },
                resume: { [self] in
                    try lock.withLock {
                        resumeCounter += 1
                        guard createSocketOnResume else {
                            return
                        }
                        let runtime =
                            try StorageProviderRuntimeDirectory.prepare(
                                at: configuration.runtimeDirectoryURL
                            )
                        socketLease =
                            try runtime.makeListeningSocket()
                    }
                },
                terminate: { [self] in
                    lock.withLock {
                        guard !terminationCalled else {
                            return
                        }
                        terminationCalled = true
                        terminationCounter += 1
                        guard runningValue else {
                            return
                        }
                        runningValue = false
                        try? socketLease?.closeAndRemove()
                        socketLease = nil
                    }
                }
            )
        }
    }

    var running: Bool {
        get {
            lock.withLock { runningValue }
        }
        set {
            lock.withLock { runningValue = newValue }
        }
    }

    var resumeCount: Int {
        lock.withLock { resumeCounter }
    }

    var terminationCount: Int {
        lock.withLock { terminationCounter }
    }

    func forceCleanup() {
        lock.withLock {
            try? socketLease?.closeAndRemove()
            socketLease = nil
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class LockedInt64: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64 = 0

    var value: Int64 {
        lock.withLock { stored }
    }

    func set(_ value: Int64) {
        lock.withLock { stored = value }
    }
}

private func makePrivateTemporaryDirectory() throws -> URL {
    let identifier = UUID().uuidString.prefix(8).lowercased()
    let root = URL(
        fileURLWithPath: "/tmp/hwsh-\(identifier)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    XCTAssertEqual(chmod(root.path, 0o700), 0)
    return root
}
