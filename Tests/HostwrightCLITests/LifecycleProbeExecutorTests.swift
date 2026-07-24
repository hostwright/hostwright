import Foundation
import XCTest
@testable import HostwrightCLI
import HostwrightReconciler
import HostwrightRuntime

final class LifecycleProbeExecutorTests: XCTestCase {
    func testExecUsesExactOwnedResourceWithoutInteractiveTTYAndDiscardsOutput() async throws {
        let action = RuntimeProbeAction.exec(
            RuntimeProbeExecAction(command: ["/usr/bin/true"])
        )
        let interactive = RecordingLifecycleProbeInteractiveExecutor(
            outputFrameCount: 2
        )
        let fixture = try fixture(
            action: action,
            interactiveExecutor: interactive
        )

        let result = await fixture.executor.executeProbe(fixture.request)

        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(result.completedAtMilliseconds, 1_234)
        XCTAssertEqual(interactive.callCount, 1)
        XCTAssertEqual(interactive.resourceIdentifier, fixture.binding.resourceIdentifier)
        XCTAssertEqual(interactive.arguments, ["/usr/bin/true"])
        XCTAssertEqual(interactive.workingDirectory, "/work")
        XCTAssertEqual(interactive.timeoutMilliseconds, 2_000)
    }

    func testLiveExecAdapterNeverRequestsInteractiveOrTTY() async throws {
        let runner = RecordingProbeProcessRunner()
        let executor = AppleContainerLifecycleProbeInteractiveExecutor(
            executor: AppleContainerInteractiveExecutor(
                executableResolver: ProbeExecutableResolver(),
                processRunner: runner
            )
        )

        _ = try await executor.executeProbeCommand(
            resourceIdentifier: managedIdentifier,
            arguments: ["/usr/bin/true"],
            workingDirectory: "/work",
            capabilitySnapshot: snapshot(),
            timeoutMilliseconds: 2_000
        ) { _ in }

        XCTAssertEqual(
            runner.request?.arguments,
            ["exec", "--workdir", "/work", managedIdentifier, "/usr/bin/true"]
        )
        XCTAssertEqual(runner.request?.interactive, false)
        XCTAssertEqual(runner.request?.tty, false)
    }

    func testExecOutputLimitFailsWithBoundedRedactedDiagnostic() async throws {
        let action = RuntimeProbeAction.exec(
            RuntimeProbeExecAction(command: ["/usr/bin/true"])
        )
        let fixture = try fixture(
            action: action,
            interactiveExecutor: RecordingLifecycleProbeInteractiveExecutor(
                outputFrameCount: 17
            )
        )

        let result = await fixture.executor.executeProbe(fixture.request)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.diagnosticRedacted.contains("bounded discard limit"))
        XCTAssertLessThanOrEqual(
            result.diagnosticRedacted.utf8.count,
            RuntimeProbeAttemptResult.maximumDiagnosticBytes
        )
    }

    func testContainerizationReturnsUnavailableBeforeAnyExecution() async throws {
        let action = RuntimeProbeAction.exec(
            RuntimeProbeExecAction(command: ["/usr/bin/true"])
        )
        let interactive = RecordingLifecycleProbeInteractiveExecutor()
        let network = RecordingLifecycleProbeNetworkClient()
        let fixture = try fixture(
            action: action,
            providerID: .appleContainerization,
            interactiveExecutor: interactive,
            networkClient: network
        )

        let result = await fixture.executor.executeProbe(fixture.request)

        XCTAssertEqual(result.outcome, .unavailable)
        XCTAssertEqual(interactive.callCount, 0)
        XCTAssertEqual(network.httpCallCount, 0)
        XCTAssertEqual(network.tcpCallCount, 0)
    }

    func testCapabilityRefusalOccursBeforeExec() async throws {
        let action = RuntimeProbeAction.exec(
            RuntimeProbeExecAction(command: ["/usr/bin/true"])
        )
        let interactive = RecordingLifecycleProbeInteractiveExecutor()
        let fixture = try fixture(
            action: action,
            capabilitySnapshot: snapshot(unavailableFeature: .processControl),
            interactiveExecutor: interactive
        )

        let result = await fixture.executor.executeProbe(fixture.request)

        XCTAssertEqual(result.outcome, .unavailable)
        XCTAssertEqual(interactive.callCount, 0)
    }

    func testHTTPUsesDeclaredExplicitLoopbackHostMapping() async throws {
        let action = RuntimeProbeAction.http(
            RuntimeProbeHTTPAction(port: 8080, path: "/ready")
        )
        let network = RecordingLifecycleProbeNetworkClient(httpStatusCode: 204)
        let fixture = try fixture(
            action: action,
            ports: [
                RuntimePortMapping(
                    hostPort: 18_080,
                    containerPort: 8_080,
                    bindAddress: "localhost"
                )
            ],
            networkClient: network
        )

        let result = await fixture.executor.executeProbe(fixture.request)

        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(network.httpURL?.absoluteString, "http://127.0.0.1:18080/ready")
        XCTAssertEqual(network.httpTimeoutMilliseconds, 2_000)
        XCTAssertEqual(network.maximumRedirects, 3)
    }

    func testHTTPRejectsExternalOrAmbiguousMappingBeforeNetwork() async throws {
        let action = RuntimeProbeAction.http(
            RuntimeProbeHTTPAction(port: 8080, path: "/ready")
        )
        let network = RecordingLifecycleProbeNetworkClient()
        let fixture = try fixture(
            action: action,
            ports: [
                RuntimePortMapping(
                    hostPort: 18_080,
                    containerPort: 8_080,
                    bindAddress: "0.0.0.0"
                )
            ],
            networkClient: network
        )

        let result = await fixture.executor.executeProbe(fixture.request)

        XCTAssertEqual(result.outcome, .unavailable)
        XCTAssertEqual(network.httpCallCount, 0)
    }

    func testHTTPNonSuccessAndTCPTransportResultsAreMapped() async throws {
        let httpAction = RuntimeProbeAction.http(
            RuntimeProbeHTTPAction(port: 8080, path: "/ready")
        )
        let httpFixture = try fixture(
            action: httpAction,
            ports: [loopbackPort],
            networkClient: RecordingLifecycleProbeNetworkClient(httpStatusCode: 503)
        )
        let httpResult = await httpFixture.executor.executeProbe(httpFixture.request)
        XCTAssertEqual(httpResult.outcome, .failed)
        XCTAssertEqual(httpResult.diagnosticRedacted, "HTTP probe returned status 503.")

        let tcpAction = RuntimeProbeAction.tcp(RuntimeProbeTCPAction(port: 8080))
        let tcpNetwork = RecordingLifecycleProbeNetworkClient(
            tcpError: LifecycleProbeTransportError.timedOut
        )
        let tcpFixture = try fixture(
            action: tcpAction,
            ports: [loopbackPort],
            networkClient: tcpNetwork
        )
        let tcpResult = await tcpFixture.executor.executeProbe(tcpFixture.request)
        XCTAssertEqual(tcpResult.outcome, .timedOut)
        XCTAssertEqual(tcpNetwork.tcpHost, "127.0.0.1")
        XCTAssertEqual(tcpNetwork.tcpPort, 18_080)
    }

    func testWrongResourceAndUnconfiguredActionNeverReachSeams() async throws {
        let action = RuntimeProbeAction.exec(
            RuntimeProbeExecAction(command: ["/usr/bin/true"])
        )
        let interactive = RecordingLifecycleProbeInteractiveExecutor()
        let fixture = try fixture(
            action: action,
            interactiveExecutor: interactive
        )
        let wrongResource = RuntimeProbeExecutionRequest(
            resourceIdentifier: "hw-v2-phase04-other",
            kind: fixture.request.kind,
            attempt: fixture.request.attempt,
            action: fixture.request.action,
            timeoutSeconds: fixture.request.timeoutSeconds
        )

        let wrongResourceResult = await fixture.executor.executeProbe(wrongResource)
        XCTAssertEqual(wrongResourceResult.outcome, .unavailable)

        let wrongAction = RuntimeProbeExecutionRequest(
            resourceIdentifier: fixture.request.resourceIdentifier,
            kind: fixture.request.kind,
            attempt: fixture.request.attempt,
            action: .exec(RuntimeProbeExecAction(command: ["/usr/bin/false"])),
            timeoutSeconds: fixture.request.timeoutSeconds
        )
        let wrongActionResult = await fixture.executor.executeProbe(wrongAction)
        XCTAssertEqual(wrongActionResult.outcome, .unavailable)
        XCTAssertEqual(interactive.callCount, 0)
    }

    func testTimeoutCancellationAndFailureAreRedactedAndTimestamped() async throws {
        let action = RuntimeProbeAction.exec(
            RuntimeProbeExecAction(command: ["/usr/bin/true"])
        )
        let timeoutFixture = try fixture(
            action: action,
            interactiveExecutor: RecordingLifecycleProbeInteractiveExecutor(
                error: RuntimeInteractiveError.processTimedOut
            )
        )
        let timeoutResult = await timeoutFixture.executor.executeProbe(
            timeoutFixture.request
        )
        XCTAssertEqual(timeoutResult.outcome, .timedOut)

        let cancelledFixture = try fixture(
            action: action,
            interactiveExecutor: RecordingLifecycleProbeInteractiveExecutor(
                error: RuntimeInteractiveError.processCancelled
            )
        )
        let cancelledResult = await cancelledFixture.executor.executeProbe(
            cancelledFixture.request
        )
        XCTAssertEqual(cancelledResult.outcome, .cancelled)

        let secret = "token=super-secret-value"
        let failureFixture = try fixture(
            action: action,
            interactiveExecutor: RecordingLifecycleProbeInteractiveExecutor(
                error: RuntimeInteractiveError.processFailed(
                    exitStatus: 1,
                    diagnostic: secret
                )
            )
        )
        let failure = await failureFixture.executor.executeProbe(failureFixture.request)
        XCTAssertEqual(failure.outcome, .failed)
        XCTAssertEqual(failure.completedAtMilliseconds, 1_234)
        XCTAssertFalse(failure.diagnosticRedacted.contains("super-secret-value"))
        XCTAssertLessThanOrEqual(
            failure.diagnosticRedacted.utf8.count,
            RuntimeProbeAttemptResult.maximumDiagnosticBytes
        )
    }

    func testRedirectPolicyAllowsOnlyThreeSameOriginLoopbackRedirects() throws {
        let origin = try XCTUnwrap(
            LifecycleProbeLoopbackOrigin(
                url: URL(string: "http://127.0.0.1:18080/ready")!
            )
        )
        XCTAssertNoThrow(
            try origin.validateRedirect(
                to: URL(string: "http://127.0.0.1:18080/next")!,
                completedRedirects: 2,
                maximumRedirects: 3
            )
        )
        XCTAssertThrowsError(
            try origin.validateRedirect(
                to: URL(string: "http://127.0.0.1:18080/fourth")!,
                completedRedirects: 3,
                maximumRedirects: 3
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeProbeValidationError,
                .redirectLimitExceeded
            )
        }
        XCTAssertThrowsError(
            try origin.validateRedirect(
                to: URL(string: "http://example.com/")!,
                completedRedirects: 0,
                maximumRedirects: 3
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeProbeValidationError,
                .redirectNotLoopback
            )
        }
        XCTAssertThrowsError(
            try origin.validateRedirect(
                to: URL(string: "http://localhost:18080/")!,
                completedRedirects: 0,
                maximumRedirects: 3
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeProbeValidationError,
                .redirectChangedOrigin
            )
        }
    }

    private var managedIdentifier: String {
        RuntimeServiceIdentity(
            projectName: "phase04",
            serviceName: "web"
        ).managedResourceIdentifier
    }

    private var loopbackPort: RuntimePortMapping {
        RuntimePortMapping(
            hostPort: 18_080,
            containerPort: 8_080,
            bindAddress: "127.0.0.1"
        )
    }

    private func fixture(
        action: RuntimeProbeAction,
        ports: [RuntimePortMapping] = [],
        providerID: RuntimeProviderID = .appleContainerCLI,
        capabilitySnapshot: RuntimeCapabilitySnapshot? = nil,
        interactiveExecutor: any LifecycleProbeInteractiveExecuting =
            RecordingLifecycleProbeInteractiveExecutor(),
        networkClient: any LifecycleProbeNetworkRequesting =
            RecordingLifecycleProbeNetworkClient()
    ) throws -> ProbeFixture {
        let identity = RuntimeServiceIdentity(
            projectName: "phase04",
            serviceName: "web"
        )
        let binding = try LifecycleResourceBinding(
            identity: identity,
            resourceIdentifier: identity.managedResourceIdentifier,
            resourceUUID: "11111111-1111-4111-8111-111111111111",
            resourceGeneration: 1,
            projectResourceUUID: "22222222-2222-4222-8222-222222222222",
            projectGeneration: 1,
            providerID: providerID,
            providerGeneration: 1,
            currentFencingToken: "33333333-3333-4333-8333-333333333333"
        )
        let configuration = RuntimeProbeConfiguration(
            action: action,
            timeoutSeconds: 2
        )
        let service = DesiredRuntimeService(
            identity: identity,
            image: "local/phase04:latest",
            workingDirectory: "/work",
            ports: ports,
            probes: RuntimeProbeSet(readiness: configuration)
        )
        let capabilitySnapshot = capabilitySnapshot ?? snapshot(providerID: providerID)
        return ProbeFixture(
            binding: binding,
            request: RuntimeProbeExecutionRequest(
                resourceIdentifier: binding.resourceIdentifier,
                kind: .readiness,
                attempt: 1,
                action: action,
                timeoutSeconds: 2
            ),
            executor: LifecycleProbeExecutor(
                binding: binding,
                desiredService: service,
                capabilitySnapshot: capabilitySnapshot,
                interactiveExecutor: interactiveExecutor,
                networkClient: networkClient,
                nowMilliseconds: { 1_234 }
            )
        )
    }

    private func snapshot(
        providerID: RuntimeProviderID = .appleContainerCLI,
        unavailableFeature: RuntimeProviderFeature? = nil
    ) -> RuntimeCapabilitySnapshot {
        RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: providerID,
                components: [
                    RuntimeProviderComponent(
                        identifier: providerID == .appleContainerCLI
                            ? .appleContainerCLI
                            : .appleContainerizationHelper,
                        version: "1.1.0",
                        build: "release",
                        fingerprint: String(repeating: "a", count: 64)
                    )
                ],
                minimumMacOSVersion:
                    RuntimeProviderCapabilityContract.minimumMacOSVersion,
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: RuntimeProviderMacOSVersion(major: 26),
                macOSBuild: "25A1",
                architecture: .arm64
            ),
            features: RuntimeProviderFeature.knownValues.map {
                RuntimeProviderFeatureStatus(
                    feature: $0,
                    state: $0 == unavailableFeature ? .unavailable : .available,
                    reason: $0 == unavailableFeature
                        ? .qualificationIncomplete
                        : .implemented
                )
            }
        )
    }
}

private struct ProbeFixture {
    let binding: LifecycleResourceBinding
    let request: RuntimeProbeExecutionRequest
    let executor: LifecycleProbeExecutor
}

private final class RecordingLifecycleProbeInteractiveExecutor:
    LifecycleProbeInteractiveExecuting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let error: (any Error)?
    private let outputFrameCount: Int
    private var calls = 0
    private var recordedResourceIdentifier: String?
    private var recordedArguments: [String] = []
    private var recordedWorkingDirectory: String?
    private var recordedTimeoutMilliseconds: Int?

    init(
        error: (any Error)? = nil,
        outputFrameCount: Int = 0
    ) {
        self.error = error
        self.outputFrameCount = outputFrameCount
    }

    func executeProbeCommand(
        resourceIdentifier: String,
        arguments: [String],
        workingDirectory: String?,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        timeoutMilliseconds: Int,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) async throws -> RuntimeInteractiveExecutionResult {
        lock.withLock {
            calls += 1
            recordedResourceIdentifier = resourceIdentifier
            recordedArguments = arguments
            recordedWorkingDirectory = workingDirectory
            recordedTimeoutMilliseconds = timeoutMilliseconds
        }
        if let error {
            throw error
        }
        for sequence in 0 ..< outputFrameCount {
            try sink(
                RuntimeStreamEnvelope(
                    sequence: UInt64(sequence),
                    stream: .standardOutput,
                    payload: Data(
                        repeating: 0x41,
                        count: RuntimeStreamEnvelope.maximumChunkBytes
                    )
                )
            )
        }
        return RuntimeInteractiveExecutionResult(
            operation: .exec,
            exitStatus: 0,
            emittedFrameCount: outputFrameCount,
            standardErrorTail: ""
        )
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    var resourceIdentifier: String? {
        lock.withLock { recordedResourceIdentifier }
    }

    var arguments: [String] {
        lock.withLock { recordedArguments }
    }

    var workingDirectory: String? {
        lock.withLock { recordedWorkingDirectory }
    }

    var timeoutMilliseconds: Int? {
        lock.withLock { recordedTimeoutMilliseconds }
    }
}

private final class RecordingLifecycleProbeNetworkClient:
    LifecycleProbeNetworkRequesting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let returnedHTTPStatusCode: Int
    private let httpError: (any Error)?
    private let tcpError: (any Error)?
    private var httpCalls = 0
    private var tcpCalls = 0
    private var recordedHTTPURL: URL?
    private var recordedHTTPTimeoutMilliseconds: Int?
    private var recordedMaximumRedirects: Int?
    private var recordedTCPHost: String?
    private var recordedTCPPort: Int?

    init(
        httpStatusCode: Int = 200,
        httpError: (any Error)? = nil,
        tcpError: (any Error)? = nil
    ) {
        self.returnedHTTPStatusCode = httpStatusCode
        self.httpError = httpError
        self.tcpError = tcpError
    }

    func httpStatusCode(
        at url: URL,
        timeoutMilliseconds: Int,
        maximumRedirects: Int
    ) async throws -> Int {
        lock.withLock {
            httpCalls += 1
            recordedHTTPURL = url
            recordedHTTPTimeoutMilliseconds = timeoutMilliseconds
            recordedMaximumRedirects = maximumRedirects
        }
        if let httpError {
            throw httpError
        }
        return returnedHTTPStatusCode
    }

    func connectTCP(
        host: String,
        port: Int,
        timeoutMilliseconds: Int
    ) async throws {
        lock.withLock {
            tcpCalls += 1
            recordedTCPHost = host
            recordedTCPPort = port
        }
        if let tcpError {
            throw tcpError
        }
    }

    var httpCallCount: Int {
        lock.withLock { httpCalls }
    }

    var tcpCallCount: Int {
        lock.withLock { tcpCalls }
    }

    var httpURL: URL? {
        lock.withLock { recordedHTTPURL }
    }

    var httpTimeoutMilliseconds: Int? {
        lock.withLock { recordedHTTPTimeoutMilliseconds }
    }

    var maximumRedirects: Int? {
        lock.withLock { recordedMaximumRedirects }
    }

    var tcpHost: String? {
        lock.withLock { recordedTCPHost }
    }

    var tcpPort: Int? {
        lock.withLock { recordedTCPPort }
    }
}

private final class RecordingProbeProcessRunner:
    RuntimeInteractiveProcessRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedRequest: RuntimeInteractiveProcessRequest?

    func run(
        _ request: RuntimeInteractiveProcessRequest,
        control: RuntimeInteractiveProcessControl,
        sink: @escaping @Sendable (RuntimeRawStreamChunk) throws -> Void
    ) async throws -> RuntimeInteractiveProcessResult {
        lock.withLock { recordedRequest = request }
        return RuntimeInteractiveProcessResult(
            exitStatus: 0,
            terminationSignal: nil,
            standardErrorTail: ""
        )
    }

    var request: RuntimeInteractiveProcessRequest? {
        lock.withLock { recordedRequest }
    }
}

private struct ProbeExecutableResolver: RuntimeExecutableResolving {
    func resolveExecutable(named name: String) throws -> ResolvedRuntimeExecutable? {
        ResolvedRuntimeExecutable(name: name, path: "/usr/local/bin/container")
    }
}
