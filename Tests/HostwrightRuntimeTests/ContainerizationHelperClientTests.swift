import Darwin
import Foundation
import Security
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime

final class ContainerizationHelperClientTests: XCTestCase {
    private let resourceUUID = "11111111-1111-4111-8111-111111111111"
    private let projectUUID = "22222222-2222-4222-8222-222222222222"
    private let fencingToken = "33333333-3333-4333-8333-333333333333"

    func testHelperCodeRequirementSourceIsCanonicalAndParseable() {
        let source = ContainerizationHelperPeerIdentityPolicy.codeRequirementSource(
            identifier: "hostwright-containerization-helper"
        )
        XCTAssertEqual(
            source,
            #"identifier "hostwright-containerization-helper" and anchor apple generic and certificate leaf[subject.OU] = "993YC3JY4Q""#
        )
        XCTAssertFalse(source.contains(#"\""#))

        var requirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(source as CFString, [], &requirement),
            errSecSuccess
        )
        XCTAssertNotNil(requirement)
    }

    func testClientLaunchesHelperWithoutShellAndNegotiatesCanonicalProtocol() async throws {
        let fixture = try ClientFixture()
        let helper = ScriptedHelper(snapshot: snapshot())
        let processState = LockedProcessState()
        let launcher = ContainerizationHelperProcessLauncher { configuration in
            XCTAssertEqual(configuration.executableURL, fixture.executableURL)
            XCTAssertEqual(configuration.configurationURL, fixture.configurationURL)
            processState.recordLaunch(processID: 41)
            return processState.lease(processID: 41)
        }
        let transport = ContainerizationHelperClientTransport { frame, socket, _, expectedPID in
            XCTAssertEqual(socket, fixture.runtimeDirectoryURL.appendingPathComponent(
                ContainerizationHelperClientConfiguration.socketName
            ))
            guard expectedPID == 41 else {
                throw ContainerizationHelperClientError.socketUnavailable
            }
            return try await helper.exchange(frame: frame, peerProcessID: 41)
        }
        let client = ContainerizationHelperClient(
            configuration: fixture.configuration,
            launcher: launcher,
            transport: transport
        )

        let negotiated = try await client.negotiate()

        XCTAssertEqual(negotiated, snapshot())
        XCTAssertEqual(processState.launchCount, 1)
        let operations = await helper.operations()
        let digests = await helper.requestCapabilityDigests()
        let uniqueIDs = await helper.allRequestIDsWereUnique()
        XCTAssertEqual(operations, [.negotiate])
        XCTAssertEqual(digests, [String(repeating: "0", count: 64)])
        XCTAssertTrue(uniqueIDs)
    }

    func testClientRoutesExactTypedReadAndMutationSubset() async throws {
        let fixture = try ClientFixture()
        let helper = ScriptedHelper(snapshot: snapshot())
        let client = directClient(fixture: fixture, helper: helper)
        let negotiated = try await client.negotiate()
        let observed = try await client.observe()
        let imageEvidence = try await client.localImageEvidence("example.local/demo:latest")
        let usage = try await client.resourceUsage("demo")
        let logs = try await client.logs("demo", lineLimit: 100)
        XCTAssertEqual(observed.semanticSHA256, try inventory().semanticSHA256)
        XCTAssertEqual(
            imageEvidence.descriptorDigest,
            "sha256:\(String(repeating: "a", count: 64))"
        )
        XCTAssertEqual(usage.memoryUsageBytes, 2)
        XCTAssertEqual(logs, "bounded output")

        let context = mutationContext(digest: negotiated.canonicalSHA256)
        let image = ContainerizationHelperImageEvidence(
            reference: "example.local/demo:latest",
            descriptorDigest: "sha256:\(String(repeating: "a", count: 64))",
            variantDigest: "sha256:\(String(repeating: "b", count: 64))",
            architecture: "arm64",
            operatingSystem: "linux"
        )
        let create = try await client.create(
                ContainerizationHelperCreatePayload(
                    resourceIdentifier: "demo",
                    resourceUUID: resourceUUID,
                    projectUUID: projectUUID,
                    image: image,
                    command: ["/bin/demo"],
                    environment: [],
                    labels: []
                ),
                context: context
            )
        XCTAssertEqual(create.lifecycle, .created)
        let payload = ContainerizationHelperMutationPayload(
            resourceIdentifier: "demo",
            resourceUUID: resourceUUID
        )
        let start = try await client.start(payload, context: context)
        let stop = try await client.stop(payload, context: context)
        let restart = try await client.restart(payload, context: context)
        let delete = try await client.delete(payload, context: context)
        XCTAssertEqual(start.lifecycle, .running)
        XCTAssertEqual(stop.lifecycle, .stopped)
        XCTAssertEqual(restart.lifecycle, .running)
        XCTAssertEqual(delete.lifecycle, .missing)

        let operations = await helper.operations()
        let digests = await helper.requestCapabilityDigests()
        let operationIDs = await helper.mutationOperationIDs()
        XCTAssertEqual(
            operations,
            [
                .negotiate, .observe, .localImageEvidence, .resourceUsage, .logs,
                .create, .start, .stop, .restart, .delete
            ]
        )
        XCTAssertTrue(digests.dropFirst().allSatisfy {
            $0 == negotiated.canonicalSHA256
        })
        XCTAssertEqual(operationIDs, Array(repeating: "operation-1", count: 5))
    }

    func testClientRejectsMismatchedTruncatedAndOversizedResponses() async throws {
        let fixture = try ClientFixture()
        let validHelper = ScriptedHelper(snapshot: snapshot())
        let mismatched = ContainerizationHelperClientTransport { frame, _, _, _ in
            try await validHelper.exchange(
                frame: frame,
                peerProcessID: 7,
                responseRequestID: UUID()
            )
        }
        let mismatchClient = ContainerizationHelperClient(
            configuration: fixture.configuration,
            launcher: inertLauncher,
            transport: mismatched
        )
        await XCTAssertThrowsErrorAsync(try await mismatchClient.negotiate()) {
            XCTAssertEqual($0 as? ContainerizationHelperClientError, .responseMismatch)
        }

        let truncatedClient = ContainerizationHelperClient(
            configuration: fixture.configuration,
            launcher: inertLauncher,
            transport: ContainerizationHelperClientTransport { _, _, _, _ in
                ContainerizationHelperTransportResponse(
                    frame: Data([0, 0, 0, 10, 1]),
                    peerProcessID: 7
                )
            }
        )
        await XCTAssertThrowsErrorAsync(try await truncatedClient.negotiate()) {
            XCTAssertEqual($0 as? ContainerizationHelperClientError, .truncatedResponse)
        }

        let oversizedClient = ContainerizationHelperClient(
            configuration: fixture.configuration,
            launcher: inertLauncher,
            transport: ContainerizationHelperClientTransport { _, _, _, _ in
                ContainerizationHelperTransportResponse(
                    frame: Data([0, 128, 0, 1]),
                    peerProcessID: 7
                )
            }
        )
        await XCTAssertThrowsErrorAsync(try await oversizedClient.negotiate()) {
            XCTAssertEqual($0 as? ContainerizationHelperClientError, .responseTooLarge)
        }
    }

    func testRemoteErrorsAreTypedRedactedAndInvalidateStaleSnapshot() async throws {
        let fixture = try ClientFixture()
        let helper = ScriptedHelper(snapshot: snapshot())
        await helper.setFailure(
            operation: .observe,
            error: ContainerizationHelperErrorPayload(
                code: .capabilityMismatch,
                message: "authorization=top-secret"
            )
        )
        let client = directClient(fixture: fixture, helper: helper)
        _ = try await client.negotiate()

        await XCTAssertThrowsErrorAsync(try await client.observe()) { error in
            guard case .remote(let failure) = error as? ContainerizationHelperClientError else {
                return XCTFail("Expected normalized helper failure, got \(error).")
            }
            XCTAssertEqual(failure.category, .staleCapability)
            XCTAssertEqual(failure.retryDisposition, .safeAfterObservation)
            XCTAssertEqual(failure.recoveryDisposition, .reobserve)
            XCTAssertFalse(failure.diagnostic.contains("top-secret"))
        }
        await helper.setFailure(operation: .observe, error: nil)
        _ = try await client.observe()
        let finalOperations = await helper.operations()
        XCTAssertEqual(Array(finalOperations.suffix(2)), [.negotiate, .observe])
    }

    func testRuntimeAdapterPreservesNormalizedStaleAndFencingFailures() async throws {
        let fixture = try ClientFixture()
        let helper = ScriptedHelper(snapshot: snapshot())
        let adapter = AppleContainerizationRuntimeAdapter(
            client: directClient(fixture: fixture, helper: helper)
        )
        _ = try await adapter.capabilitySnapshot()

        await helper.setFailure(
            operation: .observe,
            error: ContainerizationHelperErrorPayload(
                code: .capabilityMismatch,
                message: "authorization=stale-secret"
            )
        )
        await XCTAssertThrowsErrorAsync(try await adapter.inventory()) { error in
            guard case .normalizedFailure(let failure) = error as? RuntimeAdapterError else {
                return XCTFail("Expected a preserved normalized failure, got \(error).")
            }
            XCTAssertEqual(failure.category, .staleCapability)
            XCTAssertEqual(failure.retryDisposition, .safeAfterObservation)
            XCTAssertEqual(failure.recoveryDisposition, .reobserve)
            XCTAssertFalse(failure.diagnostic.contains("stale-secret"))
            XCTAssertEqual(
                RuntimeNormalizedFailure.normalize(
                    .normalizedFailure(failure),
                    providerID: "ignored",
                    providerVersion: "ignored",
                    operationID: "ignored"
                ),
                failure
            )
        }

        await helper.setFailure(
            operation: .observe,
            error: ContainerizationHelperErrorPayload(
                code: .conflict,
                message: "fencing token changed"
            )
        )
        await XCTAssertThrowsErrorAsync(try await adapter.inventory()) { error in
            guard case .normalizedFailure(let failure) = error as? RuntimeAdapterError else {
                return XCTFail("Expected a preserved normalized failure, got \(error).")
            }
            XCTAssertEqual(failure.category, .fencingConflict)
            XCTAssertEqual(failure.retryDisposition, .resumeFromCheckpoint)
            XCTAssertEqual(failure.recoveryDisposition, .resume)
        }
    }

    func testDeadHelperReconnectsOnceAndNeverDeletesAReplacementSocket() async throws {
        let fixture = try ClientFixture()
        let helper = ScriptedHelper(snapshot: snapshot())
        let processState = LockedProcessState()
        let launcher = ContainerizationHelperProcessLauncher { _ in
            let pid = processState.nextProcessID()
            return processState.lease(processID: pid)
        }
        let transport = ContainerizationHelperClientTransport { frame, _, _, expectedPID in
            guard let expectedPID else {
                throw ContainerizationHelperClientError.socketUnavailable
            }
            return try await helper.exchange(frame: frame, peerProcessID: expectedPID)
        }
        let client = ContainerizationHelperClient(
            configuration: fixture.configuration,
            launcher: launcher,
            transport: transport
        )

        _ = try await client.negotiate()
        processState.stop(processID: 101)
        _ = try await client.negotiate()

        let operations = await helper.operations()
        XCTAssertEqual(processState.launchedProcessIDs, [101, 102])
        XCTAssertEqual(operations, [.negotiate, .negotiate])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configuration.socketURL.path))
    }

    func testCancellationSendsTypedCancelAndLeavesNoRunningClientTask() async throws {
        let fixture = try ClientFixture()
        let helper = ScriptedHelper(snapshot: snapshot())
        let client = directClient(fixture: fixture, helper: helper)
        _ = try await client.negotiate()
        await helper.blockOperation(.observe)

        let task = Task { try await client.observe() }
        for _ in 0..<1_000 {
            if await helper.operations().contains(.observe) { break }
            await Task.yield()
        }
        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value) {
            XCTAssertEqual($0 as? ContainerizationHelperClientError, .cancelled)
        }
        for _ in 0..<1_000 {
            if await helper.operations().contains(.cancel) { break }
            await Task.yield()
        }
        let operations = await helper.operations()
        let cancellationCount = await helper.cancelledRequestCount()
        XCTAssertTrue(operations.contains(.cancel))
        XCTAssertEqual(cancellationCount, 1)
    }

    func testConfigurationRejectsSymlinkAndBroadPermissions() throws {
        let fixture = try ClientFixture()
        XCTAssertNoThrow(try fixture.configuration.validateForLaunch())

        XCTAssertEqual(chmod(fixture.configurationURL.path, S_IRUSR | S_IWUSR | S_IWGRP), 0)
        XCTAssertThrowsError(try fixture.configuration.validateForLaunch()) {
            XCTAssertEqual($0 as? ContainerizationHelperClientError, .unsafeConfiguration)
        }
        XCTAssertEqual(chmod(fixture.configurationURL.path, S_IRUSR | S_IWUSR), 0)

        let symlinkURL = fixture.rootURL.appendingPathComponent("helper-link")
        XCTAssertEqual(symlink(fixture.executableURL.path, symlinkURL.path), 0)
        let linked = try ContainerizationHelperClientConfiguration(
            executableURL: symlinkURL,
            configurationURL: fixture.configurationURL,
            runtimeDirectoryURL: fixture.runtimeDirectoryURL
        )
        XCTAssertThrowsError(try linked.validateForLaunch()) {
            XCTAssertEqual($0 as? ContainerizationHelperClientError, .unsafeExecutable)
        }
    }

    func testPOSIXLauncherUsesExactArgumentsEnvironmentAndWorkingDirectory() throws {
        let fixture = try POSIXLauncherFixture(configurationContents: "wait")
        setenv("HOSTWRIGHT_HELPER_PARENT_SECRET", "must-not-cross-boundary", 1)
        defer { unsetenv("HOSTWRIGHT_HELPER_PARENT_SECRET") }

        let lease = try ContainerizationHelperPOSIXLauncher.launchPrepared(
            configuration: fixture.configuration
        )
        defer { lease.terminate() }
        let evidence = try fixture.waitForEvidence()

        XCTAssertEqual(evidence.arguments, [
            try SecureExecutableResolver.verify(path: fixture.executableURL.path).path,
            "--configuration",
            fixture.configurationURL.path
        ])
        XCTAssertEqual(evidence.workingDirectory, "/")
        XCTAssertEqual(
            Set(evidence.environment),
            Set([
                "HOME=\(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)",
                "TMPDIR=\(ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp")"
            ])
        )
        XCTAssertFalse(evidence.environment.contains {
            $0.contains("HOSTWRIGHT_HELPER_PARENT_SECRET") || $0.contains("must-not-cross-boundary")
        })
        XCTAssertEqual(evidence.parentProcessID, lease.processID)
        XCTAssertTrue(lease.isRunning)
    }

    func testPOSIXLauncherTerminationKillsProcessGroupAndReapsLeader() throws {
        let fixture = try POSIXLauncherFixture(configurationContents: "fork")
        let lease = try ContainerizationHelperPOSIXLauncher.launchPrepared(
            configuration: fixture.configuration
        )
        let evidence = try fixture.waitForEvidence()
        let childProcessID = try XCTUnwrap(evidence.childProcessID)
        XCTAssertEqual(evidence.parentProcessID, lease.processID)
        XCTAssertTrue(processExists(lease.processID))
        XCTAssertTrue(processExists(childProcessID))

        lease.terminate()

        XCTAssertFalse(lease.isRunning)
        try assertProcessDisappears(lease.processID)
        try assertProcessDisappears(childProcessID)
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(lease.processID, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testPOSIXLauncherCleansDescendantBeforeReapingNaturallyExitedLeader() throws {
        let fixture = try POSIXLauncherFixture(configurationContents: "fork-exit")
        let lease = try ContainerizationHelperPOSIXLauncher.launchPrepared(
            configuration: fixture.configuration
        )
        let evidence = try fixture.waitForEvidence()
        let childProcessID = try XCTUnwrap(evidence.childProcessID)

        let deadline = Date(timeIntervalSinceNow: 5)
        while lease.isRunning, Date() < deadline { usleep(10_000) }

        XCTAssertFalse(lease.isRunning)
        try assertProcessDisappears(childProcessID)
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(lease.processID, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testRuntimeAdapterBuildsExactOwnedCreateRequestAndSupportsManagedStop() async throws {
        let fixture = try ClientFixture()
        let helper = ScriptedHelper(snapshot: snapshot())
        let client = directClient(fixture: fixture, helper: helper)
        let adapter = AppleContainerizationRuntimeAdapter(client: client)
        let negotiated = try await adapter.capabilitySnapshot()
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
        let context = mutationContext(digest: negotiated.canonicalSHA256)
        let service = DesiredRuntimeService(
            identity: identity,
            image: "example.local/demo:latest",
            command: ["/bin/demo"],
            environment: [RuntimeEnvironmentValue(name: "MODE", value: "test")]
        )
        let createAction = PlannedRuntimeAction(
            kind: .create,
            identity: identity,
            resourceIdentifier: identity.managedResourceIdentifier,
            isDestructive: false,
            summary: "create",
            desiredService: service
        )
        let confirmation = RuntimeMutationConfirmation(
            confirmed: true,
            reason: "test",
            planHash: String(repeating: "a", count: 64),
            context: context
        )

        let createEvent = try await adapter.execute(createAction, confirmation: confirmation)
        let recordedCreatePayload = await helper.lastCreatePayload()
        let createPayload = try XCTUnwrap(recordedCreatePayload)
        XCTAssertEqual(createEvent.resourceIdentifier, identity.managedResourceIdentifier)
        XCTAssertEqual(createPayload.resourceUUID, resourceUUID)
        XCTAssertEqual(createPayload.projectUUID, projectUUID)
        XCTAssertEqual(createPayload.environment, [RuntimeInventoryEnvironmentEntry(name: "MODE", value: "test")])
        let labels = Dictionary(uniqueKeysWithValues: createPayload.labels.map { ($0.key, $0.value) })
        XCTAssertEqual(labels[RuntimeManagedResourceIdentity.providerIDLabel], RuntimeProviderID.appleContainerization.rawValue)
        XCTAssertEqual(labels[RuntimeManagedResourceIdentity.fencingTokenLabel], fencingToken)

        let stopAction = PlannedRuntimeAction(
            kind: .stop,
            identity: identity,
            resourceIdentifier: identity.managedResourceIdentifier,
            isDestructive: true,
            summary: "stop"
        )
        let stopEvent = try await adapter.execute(stopAction, confirmation: confirmation)
        XCTAssertEqual(stopEvent.resourceIdentifier, identity.managedResourceIdentifier)
        let operations = await helper.operations()
        XCTAssertEqual(Array(operations.suffix(3)), [.localImageEvidence, .create, .stop])
    }

    private var inertLauncher: ContainerizationHelperProcessLauncher {
        ContainerizationHelperProcessLauncher { _ in
            ContainerizationHelperProcessLease(
                processID: 7,
                isRunning: { true },
                terminate: {}
            )
        }
    }

    private func directClient(
        fixture: ClientFixture,
        helper: ScriptedHelper
    ) -> ContainerizationHelperClient {
        ContainerizationHelperClient(
            configuration: fixture.configuration,
            launcher: inertLauncher,
            transport: ContainerizationHelperClientTransport { frame, _, _, _ in
                try await helper.exchange(frame: frame, peerProcessID: 7)
            }
        )
    }

    private func snapshot() -> RuntimeCapabilitySnapshot {
        let implemented: Set<RuntimeProviderFeature> = [
            .observation, .lifecycle, .processControl, .images, .cancellation,
            .timeouts, .errors, .cleanup
        ]
        return RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: .appleContainerization,
                components: [
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationHelper,
                        version: "0.0.2",
                        build: "test",
                        fingerprint: String(repeating: "a", count: 64)
                    ),
                    RuntimeProviderComponent(
                        identifier: .containerizationHelperProtocolV1,
                        version: "1",
                        build: "test",
                        fingerprint: String(repeating: "b", count: 64)
                    ),
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationFramework,
                        version: "0.35.0",
                        build: "test",
                        fingerprint: String(repeating: "c", count: 64)
                    )
                ],
                minimumMacOSVersion: .init(major: 26),
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: .init(major: 26),
                macOSBuild: "test",
                architecture: .arm64
            ),
            features: RuntimeProviderFeature.knownValues.map { feature in
                implemented.contains(feature)
                    ? RuntimeProviderFeatureStatus(
                        feature: feature,
                        state: .experimental,
                        reason: .qualificationIncomplete
                    )
                    : RuntimeProviderFeatureStatus(
                        feature: feature,
                        state: .unavailable,
                        reason: .notImplemented
                    )
            }
        )
    }

    private func inventory() throws -> RuntimeInventory {
        try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS",
                architecture: "arm64",
                runtimeVersion: "0.35.0",
                services: [
                    RuntimeInventoryService(
                        identifier: "hostwright-containerization-helper",
                        state: .running,
                        required: true
                    )
                ]
            ),
            containers: [],
            images: [],
            networks: [],
            volumes: []
        )
    }

    private func mutationContext(digest: String) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerization,
            capabilitySHA256: digest,
            operationID: "operation-1",
            resourceUUID: resourceUUID,
            resourceGeneration: 1,
            projectResourceUUID: projectUUID,
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: fencingToken
        )
    }
}

private final class ClientFixture: @unchecked Sendable {
    let rootURL: URL
    let executableURL: URL
    let configurationURL: URL
    let runtimeDirectoryURL: URL
    let configuration: ContainerizationHelperClientConfiguration

    init() throws {
        rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "hwc-\(UUID().uuidString.lowercased().prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        executableURL = rootURL.appendingPathComponent("hostwright-containerization-helper")
        configurationURL = rootURL.appendingPathComponent("containerization-helper.json")
        runtimeDirectoryURL = rootURL.appendingPathComponent("runtime", isDirectory: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: executableURL.path,
            contents: Data("helper".utf8),
            attributes: [.posixPermissions: 0o700]
        ))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: configurationURL.path,
            contents: Data("{}".utf8),
            attributes: [.posixPermissions: 0o600]
        ))
        configuration = try ContainerizationHelperClientConfiguration(
            executableURL: executableURL,
            configurationURL: configurationURL,
            runtimeDirectoryURL: runtimeDirectoryURL,
            launchTimeoutMilliseconds: 500,
            requestTimeoutMilliseconds: 2_000
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class LockedProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [pid_t: Bool] = [:]
    private var launches: [pid_t] = []

    var launchCount: Int { lock.withLock { launches.count } }
    var launchedProcessIDs: [pid_t] { lock.withLock { launches } }

    func recordLaunch(processID: pid_t) {
        lock.withLock {
            launches.append(processID)
            running[processID] = true
        }
    }

    func nextProcessID() -> pid_t {
        lock.withLock {
            let processID = pid_t(101 + launches.count)
            launches.append(processID)
            running[processID] = true
            return processID
        }
    }

    func stop(processID: pid_t) {
        lock.withLock { running[processID] = false }
    }

    func lease(processID: pid_t) -> ContainerizationHelperProcessLease {
        ContainerizationHelperProcessLease(
            processID: processID,
            isRunning: { [weak self] in self?.lock.withLock { self?.running[processID] == true } ?? false },
            terminate: { [weak self] in self?.stop(processID: processID) }
        )
    }
}

private final class POSIXLauncherFixture {
    struct Evidence {
        let arguments: [String]
        let environment: [String]
        let workingDirectory: String
        let parentProcessID: pid_t
        let childProcessID: pid_t?
    }

    let rootURL: URL
    let executableURL: URL
    let configurationURL: URL
    let evidenceURL: URL
    let configuration: ContainerizationHelperClientConfiguration

    init(configurationContents: String) throws {
        rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "hwc-launch-\(UUID().uuidString.lowercased().prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        executableURL = rootURL.appendingPathComponent("hostwright-containerization-helper")
        configurationURL = rootURL.appendingPathComponent("containerization-helper.json")
        evidenceURL = URL(fileURLWithPath: configurationURL.path + ".launch-evidence")
        let sourceURL = rootURL.appendingPathComponent("helper.c")
        try Self.source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let compilation = try SecureSubprocessRunner().run(
            SecureSubprocessRequest(
                executablePath: "/usr/bin/clang",
                arguments: [sourceURL.path, "-o", executableURL.path],
                timeoutMilliseconds: 30_000
            )
        )
        guard compilation.exitStatus == 0 else {
            throw POSIXError(.ENOEXEC)
        }
        guard FileManager.default.createFile(
            atPath: configurationURL.path,
            contents: Data(configurationContents.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw POSIXError(.EIO)
        }
        configuration = try ContainerizationHelperClientConfiguration(
            executableURL: executableURL,
            configurationURL: configurationURL,
            runtimeDirectoryURL: rootURL.appendingPathComponent("runtime", isDirectory: true)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func waitForEvidence() throws -> Evidence {
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if let data = FileManager.default.contents(atPath: evidenceURL.path),
               let text = String(data: data, encoding: .utf8),
               text.contains("ready=1\n") {
                return try parse(text)
            }
            usleep(10_000)
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private func parse(_ text: String) throws -> Evidence {
        let lines = text.split(separator: "\n").map(String.init)
        let arguments = lines.compactMap { line in
            line.hasPrefix("argv=") ? String(line.dropFirst("argv=".count)) : nil
        }
        let environment = lines.compactMap { line in
            line.hasPrefix("env=") ? String(line.dropFirst("env=".count)) : nil
        }
        guard let workingDirectory = value("cwd", in: lines),
              let parentText = value("parent", in: lines),
              let parent = pid_t(parentText) else {
            throw POSIXError(.EINVAL)
        }
        let child = value("child", in: lines).flatMap(pid_t.init)
        return Evidence(
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            parentProcessID: parent,
            childProcessID: child
        )
    }

    private func value(_ key: String, in lines: [String]) -> String? {
        let prefix = "\(key)="
        return lines.first(where: { $0.hasPrefix(prefix) }).map {
            String($0.dropFirst(prefix.count))
        }
    }

    private static let source = #"""
    #include <limits.h>
    #include <signal.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <unistd.h>

    int main(int argc, char **argv, char **envp) {
        if (argc != 3 || strcmp(argv[1], "--configuration") != 0) return 64;
        char evidence[PATH_MAX];
        if (snprintf(evidence, sizeof(evidence), "%s.launch-evidence", argv[2]) >= sizeof(evidence)) return 65;
        FILE *configuration = fopen(argv[2], "r");
        if (configuration == NULL) return 66;
        char mode[16] = {0};
        if (fgets(mode, sizeof(mode), configuration) == NULL) return 67;
        fclose(configuration);

        pid_t child = 0;
        if (strncmp(mode, "fork", 4) == 0) {
            child = fork();
            if (child < 0) return 68;
            if (child == 0) {
                signal(SIGTERM, SIG_IGN);
                for (;;) pause();
            }
        }

        FILE *output = fopen(evidence, "w");
        if (output == NULL) return 69;
        for (int index = 0; index < argc; index++) fprintf(output, "argv=%s\n", argv[index]);
        for (char **entry = envp; *entry != NULL; entry++) fprintf(output, "env=%s\n", *entry);
        char cwd[PATH_MAX];
        if (getcwd(cwd, sizeof(cwd)) == NULL) return 70;
        fprintf(output, "cwd=%s\n", cwd);
        fprintf(output, "parent=%d\n", getpid());
        if (child > 0) fprintf(output, "child=%d\n", child);
        fprintf(output, "ready=1\n");
        fflush(output);
        fsync(fileno(output));
        fclose(output);
        if (strncmp(mode, "fork-exit", 9) == 0) return 0;
        for (;;) pause();
    }
    """#
}

private func processExists(_ processID: pid_t) -> Bool {
    if kill(processID, 0) == 0 { return true }
    return errno == EPERM
}

private func assertProcessDisappears(
    _ processID: pid_t,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let deadline = Date(timeIntervalSinceNow: 5)
    while Date() < deadline {
        if !processExists(processID) { return }
        usleep(10_000)
    }
    XCTFail("Process \(processID) remained after process-group termination.", file: file, line: line)
}

private actor ScriptedHelper {
    private struct RoutingEnvelope: Decodable { let operation: ContainerizationHelperOperation }

    private let snapshot: RuntimeCapabilitySnapshot
    private var recordedOperations: [ContainerizationHelperOperation] = []
    private var recordedIDs: [UUID] = []
    private var recordedDigests: [String] = []
    private var recordedMutationOperationIDs: [String] = []
    private var createPayloads: [ContainerizationHelperCreatePayload] = []
    private var failures: [ContainerizationHelperOperation: ContainerizationHelperErrorPayload] = [:]
    private var blocked: Set<ContainerizationHelperOperation> = []
    private var cancellationTargets: [UUID] = []

    init(snapshot: RuntimeCapabilitySnapshot) {
        self.snapshot = snapshot
    }

    func setFailure(
        operation: ContainerizationHelperOperation,
        error: ContainerizationHelperErrorPayload?
    ) {
        failures[operation] = error
    }

    func blockOperation(_ operation: ContainerizationHelperOperation) {
        blocked.insert(operation)
    }

    func operations() -> [ContainerizationHelperOperation] { recordedOperations }
    func requestCapabilityDigests() -> [String] { recordedDigests }
    func mutationOperationIDs() -> [String] { recordedMutationOperationIDs }
    func cancelledRequestCount() -> Int { cancellationTargets.count }
    func allRequestIDsWereUnique() -> Bool { Set(recordedIDs).count == recordedIDs.count }
    func lastCreatePayload() -> ContainerizationHelperCreatePayload? { createPayloads.last }

    func exchange(
        frame: Data,
        peerProcessID: pid_t,
        responseRequestID: UUID? = nil
    ) async throws -> ContainerizationHelperTransportResponse {
        let payload = try ContainerizationHelperFraming.decodeSingleFrame(frame)
        let operation = try JSONDecoder().decode(RoutingEnvelope.self, from: payload).operation
        switch operation {
        case .negotiate:
            let request = try request(ContainerizationHelperEmptyPayload.self, payload)
            return try await respond(request, result: snapshot, peerPID: peerProcessID, responseID: responseRequestID)
        case .observe:
            let request = try request(ContainerizationHelperObservePayload.self, payload)
            let value = try ContainerizationHelperObservation(inventory: emptyInventory())
            return try await respond(request, result: value, peerPID: peerProcessID, responseID: responseRequestID)
        case .localImageEvidence:
            let request = try request(ContainerizationHelperImageRequest.self, payload)
            return try await respond(
                request,
                result: ContainerizationHelperImageEvidence(
                    reference: request.payload.reference,
                    descriptorDigest: "sha256:\(String(repeating: "a", count: 64))",
                    variantDigest: "sha256:\(String(repeating: "b", count: 64))",
                    architecture: "arm64",
                    operatingSystem: "linux"
                ),
                peerPID: peerProcessID,
                responseID: responseRequestID
            )
        case .resourceUsage:
            let request = try request(ContainerizationHelperResourceRequest.self, payload)
            return try await respond(
                request,
                result: ContainerizationHelperResourceUsage(
                    resourceIdentifier: request.payload.resourceIdentifier,
                    cpuUsageMicroseconds: 1,
                    memoryUsageBytes: 2,
                    memoryLimitBytes: 3,
                    networkReceiveBytes: 4,
                    networkTransmitBytes: 5,
                    blockReadBytes: 6,
                    blockWriteBytes: 7,
                    processCount: 8
                ),
                peerPID: peerProcessID,
                responseID: responseRequestID
            )
        case .logs:
            let request = try request(ContainerizationHelperLogsRequest.self, payload)
            return try await respond(
                request,
                result: ContainerizationHelperLogs(
                    resourceIdentifier: request.payload.resourceIdentifier,
                    text: "bounded output",
                    lineLimit: request.payload.lineLimit
                ),
                peerPID: peerProcessID,
                responseID: responseRequestID
            )
        case .create:
            let request = try request(ContainerizationHelperCreatePayload.self, payload)
            createPayloads.append(request.payload)
            return try await respond(
                request,
                result: mutationResult(request.payload.resourceIdentifier, lifecycle: .created),
                peerPID: peerProcessID,
                responseID: responseRequestID
            )
        case .start, .stop, .restart, .delete:
            let request = try request(ContainerizationHelperMutationPayload.self, payload)
            let lifecycle: RuntimeInventoryLifecycleState
            switch operation {
            case .start, .restart: lifecycle = .running
            case .stop: lifecycle = .stopped
            case .delete: lifecycle = .missing
            default: fatalError()
            }
            return try await respond(
                request,
                result: mutationResult(request.payload.resourceIdentifier, lifecycle: lifecycle),
                peerPID: peerProcessID,
                responseID: responseRequestID
            )
        case .cancel:
            let request = try request(ContainerizationHelperCancellationPayload.self, payload)
            cancellationTargets.append(request.payload.targetRequestID)
            return try await respond(
                request,
                result: ContainerizationHelperAcknowledgement(accepted: true),
                peerPID: peerProcessID,
                responseID: responseRequestID
            )
        case .shutdown:
            let request = try request(ContainerizationHelperEmptyPayload.self, payload)
            return try await respond(
                request,
                result: ContainerizationHelperAcknowledgement(accepted: true),
                peerPID: peerProcessID,
                responseID: responseRequestID
            )
        }
    }

    private func request<Payload: Codable & Sendable>(
        _ type: Payload.Type,
        _ data: Data
    ) throws -> ContainerizationHelperRequest<Payload> {
        try ContainerizationHelperCanonicalJSON.decodeRequest(type, from: data)
    }

    private func respond<Payload: Codable & Sendable, Result: Codable & Sendable>(
        _ request: ContainerizationHelperRequest<Payload>,
        result: Result,
        peerPID: pid_t,
        responseID: UUID?
    ) async throws -> ContainerizationHelperTransportResponse {
        recordedOperations.append(request.operation)
        recordedIDs.append(request.requestID)
        recordedDigests.append(request.capabilityDigest)
        if let context = request.mutationContext {
            recordedMutationOperationIDs.append(context.operationID)
        }
        if blocked.contains(request.operation) {
            do {
                while !Task.isCancelled { try await Task.sleep(for: .milliseconds(10)) }
            } catch {
                throw CancellationError()
            }
            throw CancellationError()
        }
        let responsePayload: Data
        if let failure = failures[request.operation] {
            responsePayload = try ContainerizationHelperCanonicalJSON.encode(
                ContainerizationHelperErrorEnvelope(
                    requestID: responseID ?? request.requestID,
                    operation: request.operation,
                    error: failure
                )
            )
        } else {
            responsePayload = try ContainerizationHelperCanonicalJSON.encode(
                ContainerizationHelperResultEnvelope(
                    requestID: responseID ?? request.requestID,
                    operation: request.operation,
                    result: result
                )
            )
        }
        return ContainerizationHelperTransportResponse(
            frame: try ContainerizationHelperFraming.frame(responsePayload),
            peerProcessID: peerPID
        )
    }

    private func mutationResult(
        _ identifier: String,
        lifecycle: RuntimeInventoryLifecycleState
    ) -> ContainerizationHelperMutationResult {
        ContainerizationHelperMutationResult(
            resourceIdentifier: identifier,
            lifecycle: lifecycle,
            verified: true
        )
    }

    private func emptyInventory() throws -> RuntimeInventory {
        try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS",
                architecture: "arm64",
                runtimeVersion: "0.35.0",
                services: [
                    RuntimeInventoryService(
                        identifier: "hostwright-containerization-helper",
                        state: .running,
                        required: true
                    )
                ]
            ),
            containers: [],
            images: [],
            networks: [],
            volumes: []
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.")
    } catch {
        verify(error)
    }
}
