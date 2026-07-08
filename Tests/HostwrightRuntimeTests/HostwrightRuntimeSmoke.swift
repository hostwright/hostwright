import Foundation
import XCTest
@testable import HostwrightRuntime

final class HostwrightRuntimeTests: XCTestCase {
    func testRuntimePlanReportsMutationAndDestructiveFlags() {
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "web")
        let plan = RuntimePlan(actions: [
            PlannedRuntimeAction(kind: .create, identity: identity, isDestructive: false, summary: "create web")
        ])

        XCTAssertTrue(plan.mutatesRuntime)
        XCTAssertFalse(plan.includesDestructiveAction)
    }

    func testRedactionHandlesSensitiveEnvironmentArgumentsAndJSON() {
        let secretEnvironment = RuntimeEnvironmentValue(name: "API_TOKEN", value: "fake-token-123", isSensitive: true)
        XCTAssertEqual(secretEnvironment.redacted().value, "[REDACTED]")

        let readOnly = RuntimeCommandSpec(
            executablePath: "/usr/bin/example",
            arguments: ["list", "token=fake-token-123"],
            environment: ["PASSWORD": "fake-password"],
            timeout: RuntimeCommandTimeout(seconds: 999),
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "fixture"
        )

        XCTAssertEqual(readOnly.timeout.seconds, RuntimeCommandTimeout.maximumSeconds)
        XCTAssertTrue(readOnly.redacted().arguments[1].contains("[REDACTED]"))
        XCTAssertEqual(readOnly.redacted().environment["PASSWORD"], "[REDACTED]")
        XCTAssertFalse(RuntimeRedactionPolicy.default.redact(#""token":"fake-token-123""#).contains("fake-token-123"))
    }

    func testRuntimeCommandPolicyAcceptsReadOnlyResolvedSpecs() {
        let readOnly = RuntimeCommandSpec(
            executablePath: "/usr/bin/example",
            arguments: ["list"],
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "fixture"
        )

        XCTAssertNoThrow(try RuntimeCommandPolicy.validateReadOnlyCommandClassification(readOnly))
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateReadOnlyExecution(readOnly))
    }

    func testRuntimeCommandPolicyRejectsMutatingForbiddenAndUnknownSpecs() {
        for rejectedClassification in [RuntimeCommandClassification.mutating, .forbidden, .unknown] {
            let rejected = RuntimeCommandSpec(
                executablePath: "/usr/bin/example",
                arguments: ["not-allowed"],
                classification: rejectedClassification,
                executableResolution: .resolvedByRuntimeExecutableResolver,
                purpose: "fixture"
            )

            XCTAssertThrowsError(try RuntimeCommandPolicy.validateReadOnlyCommandClassification(rejected))
            XCTAssertThrowsError(try RuntimeCommandPolicy.validateReadOnlyExecution(rejected))
        }
    }

    func testCreateMissingServiceMutationPolicyAcceptsOnlyResolvedCreateSpecs() {
        let create = AppleContainerCommand.spec(
            kind: .createContainer,
            executable: ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture"),
            desiredService: desiredService
        )

        XCTAssertNoThrow(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(create))
        XCTAssertEqual(create.classification, .mutating)
        XCTAssertEqual(create.mutationKind, .createMissingService)
        XCTAssertEqual(create.arguments.prefix(3), ["create", "--name", "hostwright-demo-api"])
        XCTAssertTrue(create.arguments.contains("--publish"))
        XCTAssertTrue(create.arguments.contains("127.0.0.1:8080:8080"))
        XCTAssertFalse(create.arguments.contains("run"))
        XCTAssertFalse(create.arguments.contains("--rm"))

        let unresolved = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["create"],
            classification: .mutating,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(unresolved))

        let forbidden = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["delete"],
            classification: .forbidden,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(forbidden))

        let mislabeledDelete = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["delete", "hostwright-demo-api"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(mislabeledDelete))

        let nonHostwrightCreate = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["create", "--name", "manual-api", "local/demo:latest"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(nonHostwrightCreate))
    }

    func testCreateMissingServiceMutationPolicyRejectsFlagLikeImageAndCommandTokens() {
        let unsafeImage = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["create", "--name", "hostwright-demo-api", "--mount=src=/,dst=/host"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(unsafeImage)) { error in
            XCTAssertTrue(String(describing: error).contains("image"))
        }

        let badImage = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["create", "--name", "hostwright-demo-api", "-bad"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(badImage))

        let unsafeCommandToken = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["create", "--name", "hostwright-demo-api", "local/demo:latest", "--flag"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(unsafeCommandToken)) { error in
            XCTAssertTrue(String(describing: error).contains("command tokens beginning"))
        }
    }

    func testManagedStartAndDeletePoliciesAcceptOnlyExactHostwrightContainers() {
        let executable = ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture")
        let start = AppleContainerCommand.spec(kind: .startContainer(containerID: "hostwright-demo-api"), executable: executable)
        let delete = AppleContainerCommand.spec(kind: .deleteContainer(containerID: "hostwright-demo-api"), executable: executable)

        XCTAssertEqual(start.arguments, ["start", "hostwright-demo-api"])
        XCTAssertEqual(start.mutationKind, .startManagedService)
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateStartManagedServiceMutation(start))
        XCTAssertEqual(delete.arguments, ["delete", "hostwright-demo-api"])
        XCTAssertEqual(delete.mutationKind, .deleteManagedContainer)
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateDeleteManagedContainerMutation(delete))

        let attachedStart = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["start", "--attach", "hostwright-demo-api"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .startManagedService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateStartManagedServiceMutation(attachedStart))

        let forcedDelete = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["delete", "--force", "hostwright-demo-api"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .deleteManagedContainer,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateDeleteManagedContainerMutation(forcedDelete))

        let nonHostwrightDelete = AppleContainerCommand.spec(kind: .deleteContainer(containerID: "manual-api"), executable: executable)
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateDeleteManagedContainerMutation(nonHostwrightDelete))
    }

    func testManagedRestartPolicyAcceptsOnlyInternalStopThenStartSteps() {
        let executable = ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture")
        let stop = AppleContainerCommand.spec(kind: .stopForManagedRestart(containerID: "hostwright-demo-api"), executable: executable)
        let start = AppleContainerCommand.spec(kind: .startForManagedRestart(containerID: "hostwright-demo-api"), executable: executable)

        XCTAssertEqual(stop.arguments, ["stop", "hostwright-demo-api"])
        XCTAssertEqual(start.arguments, ["start", "hostwright-demo-api"])
        XCTAssertEqual(stop.mutationKind, .restartManagedService)
        XCTAssertEqual(start.mutationKind, .restartManagedService)
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateRestartManagedServiceMutation(stop))
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateRestartManagedServiceMutation(start))

        let broadRestart = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["restart", "hostwright-demo-api"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .restartManagedService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateRestartManagedServiceMutation(broadRestart))

        let nonHostwrightStop = AppleContainerCommand.spec(kind: .stopForManagedRestart(containerID: "manual-api"), executable: executable)
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateRestartManagedServiceMutation(nonHostwrightStop))

        let wrongKindStop = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["stop", "hostwright-demo-api"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .startManagedService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateStartManagedServiceMutation(wrongKindStop))
    }

    func testReadOnlyExecutionRejectsUnresolvedExecutable() {
        let unresolvedReadOnly = RuntimeCommandSpec(
            executablePath: "/usr/bin/example",
            arguments: ["list"],
            classification: .readOnly,
            purpose: "fixture"
        )

        XCTAssertNoThrow(try RuntimeCommandPolicy.validateReadOnlyCommandClassification(unresolvedReadOnly))
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateReadOnlyExecution(unresolvedReadOnly))
    }

    func testMockRuntimeAdapterCanObserveServices() async throws {
        let observedService = ObservedRuntimeService(
            identity: identity,
            image: "ghcr.io/example/api:latest",
            lifecycleState: .running,
            healthState: .healthy
        )
        let adapter = MockRuntimeAdapter(scenario: .observed([observedService]))

        let observed = try await adapter.observe(desiredState: desiredState)

        XCTAssertEqual(observed.services.count, 1)
        XCTAssertEqual(observed.services[0].lifecycleState, .running)
    }

    func testMockRuntimeAdapterPlansMissingServicesWithoutExecuting() async throws {
        let adapter = MockRuntimeAdapter(scenario: .availableEmpty)
        let observed = try await adapter.observe(desiredState: desiredState)

        let plan = try await adapter.plan(desiredState: desiredState, observedState: observed)

        XCTAssertEqual(plan.actions.map(\.kind), [.create])
    }

    func testMockRuntimeAdapterRedactsFailureOutput() async {
        let adapter = MockRuntimeAdapter(scenario: .redactedFailure("password=fake-password token=fake-token"))

        do {
            _ = try await adapter.observe(desiredState: desiredState)
            XCTFail("Expected redacted command failure.")
        } catch let error as RuntimeAdapterError {
            guard case .commandFailed(_, _, let standardError) = error else {
                return XCTFail("Expected commandFailed, got \(error).")
            }
            XCTAssertFalse(standardError.contains("fake-password"))
            XCTAssertFalse(standardError.contains("fake-token"))
            XCTAssertTrue(standardError.contains("[REDACTED]"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testFoundationRuntimeProcessRunnerDrainsLargeStdout() async throws {
        let runner = FoundationRuntimeProcessRunner()
        let result = try await runner.run(shellSpec("/usr/bin/yes x | /usr/bin/head -c 131072"))

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertGreaterThan(result.standardOutput.utf8.count, 65_536)
    }

    func testFoundationRuntimeProcessRunnerDrainsLargeStderr() async throws {
        let runner = FoundationRuntimeProcessRunner()
        let result = try await runner.run(shellSpec("/usr/bin/yes e | /usr/bin/head -c 131072 >&2"))

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertGreaterThan(result.standardError.utf8.count, 65_536)
    }

    func testFoundationRuntimeProcessRunnerTimeoutRedactsPartialOutput() async {
        let runner = FoundationRuntimeProcessRunner()

        do {
            _ = try await runner.run(shellSpec("printf 'token=fake-secret\\n'; sleep 2", timeout: 1))
            XCTFail("Expected timeout.")
        } catch let error as RuntimeAdapterError {
            guard case .commandTimedOut(_, let partialOutput, _) = error else {
                return XCTFail("Expected commandTimedOut, got \(error).")
            }
            XCTAssertTrue(partialOutput.contains("[REDACTED]"))
            XCTAssertFalse(partialOutput.contains("fake-secret"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testRuntimeMutationRemainsUnavailable() async {
        let adapter = MockRuntimeAdapter(scenario: .availableEmpty)

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(kind: .start, identity: identity, isDestructive: false, summary: "start"),
                confirmation: nil
            )
            XCTFail("Expected mutation unavailable.")
        } catch let error as RuntimeAdapterError {
            guard case .mutationUnavailableByPolicy = error else {
                return XCTFail("Expected mutationUnavailableByPolicy, got \(error).")
            }
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testBoundedHealthCheckerRunsAllowedLoopbackURLAndRedactsOutput() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(response: RuntimeHealthURLResponse(statusCode: 200, body: "ok token=fake-secret"))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )

        let result = await checker.check(
            identity: identity,
            spec: RuntimeHealthCheckSpec(
                command: ["curl", "-f", "http://localhost:8080/health?token=fake-secret"],
                timeoutSeconds: 2
            )
        )

        XCTAssertEqual(result.status, .healthy)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(fetcher.requests.map(\.url.absoluteString), ["http://localhost:8080/health?token=fake-secret"])
        XCTAssertEqual(fetcher.requests.map(\.timeout.seconds), [2])
        XCTAssertTrue(result.standardOutput.contains("[REDACTED]"))
        XCTAssertFalse(result.standardOutput.contains("fake-secret"))
        XCTAssertFalse(result.command.joined(separator: " ").contains("fake-secret"))
    }

    func testURLSessionHealthFetcherRejectsRedirects() async throws {
        let delegate = RejectingRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let originalURL = try XCTUnwrap(URL(string: "http://localhost:8080/health"))
        let redirectedURL = try XCTUnwrap(URL(string: "http://example.com/health"))
        let task = session.dataTask(with: originalURL)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: originalURL,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": redirectedURL.absoluteString]
            )
        )
        let request = URLRequest(url: redirectedURL)

        let redirectedRequest = await delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request
        )

        XCTAssertNil(redirectedRequest)
        session.invalidateAndCancel()
    }

    func testURLSessionHealthFetcherRejectsNonLoopbackURLBeforeNetwork() async throws {
        let fetcher = URLSessionRuntimeHealthURLFetcher()
        let url = try XCTUnwrap(URL(string: "https://example.com/health"))

        do {
            _ = try await fetcher.fetch(url: url, timeout: RuntimeCommandTimeout(seconds: 1))
            XCTFail("Expected non-loopback health URL to be rejected.")
        } catch let error as RuntimeAdapterError {
            guard case .commandRejected(let classification, let message) = error else {
                return XCTFail("Expected commandRejected, got \(error).")
            }
            XCTAssertEqual(classification, .readOnly)
            XCTAssertTrue(message.contains("loopback"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testBoundedHealthCheckerTreatsRedirectStatusAsUnhealthy() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(response: RuntimeHealthURLResponse(statusCode: 302))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )

        let result = await checker.check(
            identity: identity,
            spec: RuntimeHealthCheckSpec(command: ["curl", "-f", "http://localhost:8080/health"])
        )

        XCTAssertEqual(result.status, .unhealthy)
        XCTAssertEqual(result.exitStatus, 302)
        XCTAssertTrue(result.standardError.contains("HTTP status 302"))
    }

    func testBoundedHealthCheckerRejectsUnsafeCurlAndWgetArgumentsWithoutRunning() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(response: RuntimeHealthURLResponse(statusCode: 200))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )
        let rejectedCommands = [
            ["curl", "-K", "/tmp/curlrc", "http://localhost:8080/health"],
            ["curl", "-o", "/tmp/output", "http://localhost:8080/health"],
            ["curl", "file:///etc/passwd"],
            ["curl", "http://example.com/health"],
            ["wget", "--post-file=/etc/passwd", "http://localhost:8080/health"],
            ["wget", "http://localhost:8080/health"]
        ]

        for command in rejectedCommands {
            let result = await checker.check(identity: identity, spec: RuntimeHealthCheckSpec(command: command))
            XCTAssertEqual(result.status, .unknown)
            XCTAssertTrue(result.standardError.contains("health checks") || result.standardError.contains("Health check URLs"))
        }
        XCTAssertEqual(fetcher.requests.count, 0)
    }

    func testBoundedHealthCheckerRejectsShellExecutableWithoutRunning() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(response: RuntimeHealthURLResponse(statusCode: 200))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )

        let result = await checker.check(
            identity: identity,
            spec: RuntimeHealthCheckSpec(command: ["sh", "-c", "rm -rf /tmp/hostwright"])
        )

        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(result.standardError.contains("not allowed"))
        XCTAssertEqual(fetcher.requests.count, 0)
    }

    func testBoundedHealthCheckerMapsTimeoutToUnhealthyAndRedactsPartialOutput() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(error: URLError(.timedOut))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )

        let result = await checker.check(
            identity: identity,
            spec: RuntimeHealthCheckSpec(command: ["curl", "-f", "http://localhost:8080/health?token=fake-secret"], timeoutSeconds: 1)
        )

        XCTAssertEqual(result.status, .unhealthy)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertTrue(result.standardError.contains("timed out"))
        XCTAssertFalse(result.command.joined(separator: " ").contains("fake-secret"))
        XCTAssertFalse(result.standardError.contains("fake-password"))
    }

    func testAppleContainerApplyAdapterCreatesOnlyWhenLocalImageIsAvailable() async throws {
        let imageListFixture = try fixture("apple-container-image-list-real-json.txt")
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["image", "list", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: imageListFixture, standardError: "")
            }
            if spec.arguments.first == "create" {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "created token=fake-token", standardError: "")
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "unexpected command")
        }
        let adapter = AppleContainerApplyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        let event = try await adapter.execute(
            PlannedRuntimeAction(
                kind: .create,
                identity: proofIdentity,
                isDestructive: false,
                summary: "create",
                desiredService: proofService
            ),
            confirmation: RuntimeMutationConfirmation(confirmed: true, reason: "test", planHash: "plan-hash")
        )

        XCTAssertEqual(runner.calls.compactMap(\.arguments.first), ["image", "create"])
        XCTAssertEqual(event.resourceIdentifier, "hostwright-proof-web")
        XCTAssertFalse(event.message.contains("fake-token"))
        XCTAssertTrue(event.message.contains("[REDACTED]"))
    }

    func testAppleContainerApplyAdapterUsesOriginalEnvironmentValuesInCreateSpec() async throws {
        let imageListFixture = try fixture("apple-container-image-list-real-json.txt")
        let fakeSecret = "fake-secret-token"
        let service = DesiredRuntimeService(
            identity: proofIdentity,
            image: "hostwright-proof-web:create-only",
            environment: [RuntimeEnvironmentValue(name: "API_TOKEN", value: fakeSecret, isSensitive: true)],
            ports: [RuntimePortMapping(hostPort: 18080, containerPort: 80, bindAddress: "127.0.0.1")]
        )
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["image", "list", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: imageListFixture, standardError: "")
            }
            if spec.arguments.first == "create" {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "created token=\(fakeSecret)", standardError: "")
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "unexpected command")
        }
        let adapter = AppleContainerApplyAdapter(executableResolver: resolvedContainer, processRunner: runner)

        let event = try await adapter.execute(
            PlannedRuntimeAction(kind: .create, identity: proofIdentity, isDestructive: false, summary: "create", desiredService: service),
            confirmation: RuntimeMutationConfirmation(confirmed: true, reason: "test", planHash: "plan-hash")
        )

        let createArguments = try XCTUnwrap(runner.calls.first { $0.arguments.first == "create" }?.arguments)
        XCTAssertTrue(createArguments.contains("API_TOKEN=\(fakeSecret)"))
        XCTAssertTrue(createArguments.contains("127.0.0.1:18080:80"))
        XCTAssertFalse(event.message.contains(fakeSecret))
        XCTAssertTrue(event.message.contains("[REDACTED]"))
    }

    func testAppleContainerApplyAdapterStartsManagedServiceOnly() async throws {
        let runner = RoutingRuntimeProcessRunner { spec in
            XCTAssertEqual(spec.arguments, ["start", "hostwright-demo-api"])
            return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "started token=fake-token", standardError: "")
        }
        let adapter = AppleContainerApplyAdapter(executableResolver: resolvedContainer, processRunner: runner)

        let event = try await adapter.execute(
            PlannedRuntimeAction(kind: .start, identity: identity, isDestructive: false, summary: "start"),
            confirmation: RuntimeMutationConfirmation(confirmed: true, reason: "test", planHash: "plan-hash")
        )

        XCTAssertEqual(runner.calls.map(\.arguments), [["start", "hostwright-demo-api"]])
        XCTAssertEqual(event.resourceIdentifier, "hostwright-demo-api")
        XCTAssertFalse(event.message.contains("fake-token"))
    }

    func testAppleContainerApplyAdapterDeletesOnlyExplicitDestructiveManagedContainer() async throws {
        let runner = RoutingRuntimeProcessRunner { spec in
            XCTAssertEqual(spec.arguments, ["delete", "hostwright-demo-api"])
            return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "deleted", standardError: "")
        }
        let adapter = AppleContainerApplyAdapter(executableResolver: resolvedContainer, processRunner: runner)

        let event = try await adapter.execute(
            PlannedRuntimeAction(kind: .remove, identity: identity, isDestructive: true, summary: "delete"),
            confirmation: RuntimeMutationConfirmation(confirmed: true, reason: "test", planHash: "cleanup-token")
        )

        XCTAssertEqual(event.resourceIdentifier, "hostwright-demo-api")

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(kind: .remove, identity: identity, isDestructive: false, summary: "delete"),
                confirmation: RuntimeMutationConfirmation(confirmed: true, reason: "test", planHash: "cleanup-token")
            )
            XCTFail("Expected non-destructive delete action to be rejected.")
        } catch let error as RuntimeAdapterError {
            guard case .commandRejected = error else {
                return XCTFail("Expected commandRejected, got \(error).")
            }
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testAppleContainerApplyAdapterRestartsManagedServiceWithStopThenStartOnly() async throws {
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["stop", "hostwright-demo-api"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "stopped token=fake-token", standardError: "")
            }
            if spec.arguments == ["start", "hostwright-demo-api"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "started token=fake-token", standardError: "")
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "unexpected command")
        }
        let adapter = AppleContainerApplyAdapter(executableResolver: resolvedContainer, processRunner: runner)

        let event = try await adapter.execute(
            PlannedRuntimeAction(kind: .restart, identity: identity, isDestructive: true, summary: "restart"),
            confirmation: RuntimeMutationConfirmation(confirmed: true, reason: "test", planHash: "plan-hash")
        )

        XCTAssertEqual(runner.calls.map(\.arguments), [["stop", "hostwright-demo-api"], ["start", "hostwright-demo-api"]])
        XCTAssertEqual(event.resourceIdentifier, "hostwright-demo-api")
        XCTAssertTrue(event.message.contains("[REDACTED]"))
        XCTAssertFalse(event.message.contains("fake-token"))
    }

    func testAppleContainerApplyAdapterReportsPartialManagedRestartWhenStartFailsAfterStop() async throws {
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["stop", "hostwright-demo-api"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "stopped", standardError: "")
            }
            if spec.arguments == ["start", "hostwright-demo-api"] {
                throw RuntimeAdapterError.commandFailed(exitStatus: 2, message: "start failed", standardError: "token=fake-token")
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "unexpected command")
        }
        let adapter = AppleContainerApplyAdapter(executableResolver: resolvedContainer, processRunner: runner)

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(kind: .restart, identity: identity, isDestructive: true, summary: "restart"),
                confirmation: RuntimeMutationConfirmation(confirmed: true, reason: "test", planHash: "plan-hash")
            )
            XCTFail("Expected partial restart failure.")
        } catch let error as RuntimeAdapterError {
            guard case .managedRestartStartFailedAfterStop(let message, let standardError) = error else {
                return XCTFail("Expected managedRestartStartFailedAfterStop, got \(error).")
            }
            XCTAssertTrue(message.contains("start failed"))
            XCTAssertTrue(standardError.contains("[REDACTED]"))
            XCTAssertFalse(standardError.contains("fake-token"))
            XCTAssertEqual(runner.calls.map(\.arguments), [["stop", "hostwright-demo-api"], ["start", "hostwright-demo-api"]])
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testAppleContainerReadOnlyAdapterReadsTailLogsWithoutFollowAttachOrExec() async throws {
        let runner = RoutingRuntimeProcessRunner { spec in
            XCTAssertEqual(spec.arguments, ["logs", "-n", "25", "hostwright-demo-api"])
            XCTAssertFalse(spec.arguments.contains("--follow"))
            XCTAssertFalse(spec.arguments.contains("--attach"))
            XCTAssertFalse(spec.arguments.contains("exec"))
            return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "token=fake-token\nready", standardError: "")
        }
        let adapter = AppleContainerReadOnlyAdapter(executableResolver: resolvedContainer, processRunner: runner)

        let logs = try await adapter.logs(for: identity, tail: 25)

        XCTAssertEqual(logs.lineLimit, 25)
        XCTAssertTrue(logs.text.contains("[REDACTED]"))
        XCTAssertFalse(logs.text.contains("fake-token"))
    }


    func testAppleContainerApplyAdapterRejectsMissingLocalImageBeforeCreate() async {
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["image", "list", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "[]", standardError: "")
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "create should not run")
        }
        let adapter = AppleContainerApplyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(
                    kind: .create,
                    identity: identity,
                    isDestructive: false,
                    summary: "create",
                    desiredService: desiredService
                ),
                confirmation: RuntimeMutationConfirmation(confirmed: true, reason: "test", planHash: "plan-hash")
            )
            XCTFail("Expected local image availability failure.")
        } catch let error as RuntimeAdapterError {
            guard case .capabilityUnavailable(.lifecycleMutation) = error else {
                return XCTFail("Expected lifecycleMutation capabilityUnavailable, got \(error).")
            }
            XCTAssertEqual(runner.calls.count, 1)
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testAppleContainerApplyAdapterRejectsUnsupportedCreateSubsets() async {
        let adapter = AppleContainerApplyAdapter(
            executableResolver: resolvedContainer,
            processRunner: RoutingRuntimeProcessRunner { _ in
                throw RuntimeAdapterError.commandFailed(exitStatus: 1, message: "should not run", standardError: "")
            }
        )
        let mounted = DesiredRuntimeService(
            identity: identity,
            image: "ghcr.io/example/api:latest",
            mounts: [RuntimeMountReference(source: "./data", target: "/data")]
        )

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(kind: .create, identity: identity, isDestructive: false, summary: "create", desiredService: mounted),
                confirmation: RuntimeMutationConfirmation(confirmed: true, reason: "test", planHash: "plan-hash")
            )
            XCTFail("Expected unsupported subset failure.")
        } catch let error as RuntimeAdapterError {
            guard case .commandRejected(classification: .mutating, message: let message) = error else {
                return XCTFail("Expected commandRejected, got \(error).")
            }
            XCTAssertTrue(message.contains("mounts"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testAppleContainerReadOnlyAdapterMissingExecutableDegradesHonestly() async {
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: FixedRuntimeExecutableResolver(executables: [:]),
            processRunner: FakeRuntimeProcessRunner(behavior: .failure(.runtimeUnavailable("should not run")))
        )

        do {
            _ = try await adapter.observe(desiredState: desiredState)
            XCTFail("Expected missing executable to fail.")
        } catch let error as RuntimeAdapterError {
            guard case .runtimeUnavailable(let message) = error else {
                return XCTFail("Expected runtimeUnavailable, got \(error).")
            }
            XCTAssertTrue(message.contains("not found"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testAppleContainerParserParsesEmptyFixture() async throws {
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: FakeRuntimeProcessRunner(
                behavior: .result(
                    RuntimeCommandResult(
                        spec: listSpec,
                        exitStatus: 0,
                        standardOutput: try fixture("apple-container-list-empty.txt"),
                        standardError: ""
                    )
                )
            )
        )

        let observed = try await adapter.observe(desiredState: desiredState)

        XCTAssertTrue(observed.services.isEmpty)
        XCTAssertEqual(observed.adapterMetadata?.supportsMutation, false)
    }

    func testAppleContainerParserParsesRealEmptyJSONFixture() async throws {
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: FakeRuntimeProcessRunner(
                behavior: .result(
                    RuntimeCommandResult(
                        spec: listSpec,
                        exitStatus: 0,
                        standardOutput: try fixture("apple-container-list-empty-real-json.txt"),
                        standardError: ""
                    )
                )
            )
        )

        let observed = try await adapter.observe(desiredState: desiredState)

        XCTAssertTrue(observed.services.isEmpty)
        XCTAssertEqual(observed.projectName, desiredState.projectName)
        XCTAssertEqual(AppleContainerCommand.arguments(for: .listContainers), ["list", "--all", "--format", "json"])
    }

    func testAppleContainerParserIgnoresRealBuilderContainerFixture() async throws {
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: FakeRuntimeProcessRunner(
                behavior: .result(
                    RuntimeCommandResult(
                        spec: listSpec,
                        exitStatus: 0,
                        standardOutput: try fixture("apple-container-list-builder-real-json.txt"),
                        standardError: ""
                    )
                )
            )
        )

        let observed = try await adapter.observe(desiredState: proofDesiredState)

        XCTAssertTrue(observed.services.isEmpty)
        XCTAssertEqual(observed.projectName, "proof")
    }

    func testAppleContainerParserParsesRealCreatedProofContainerFixture() async throws {
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: FakeRuntimeProcessRunner(
                behavior: .result(
                    RuntimeCommandResult(
                        spec: listSpec,
                        exitStatus: 0,
                        standardOutput: try fixture("apple-container-list-proof-created-real-json.txt"),
                        standardError: ""
                    )
                )
            )
        )

        let observed = try await adapter.observe(desiredState: proofDesiredState)

        XCTAssertEqual(observed.services.count, 1)
        XCTAssertEqual(observed.services[0].identity, proofIdentity)
        XCTAssertEqual(observed.services[0].image, "hostwright-proof-web:create-only")
        XCTAssertEqual(observed.services[0].lifecycleState, .stopped)
        XCTAssertEqual(observed.services[0].ports.first?.hostPort, 18080)
        XCTAssertEqual(observed.services[0].ports.first?.containerPort, 80)
        XCTAssertEqual(observed.services[0].ports.first?.protocolName, .tcp)
        XCTAssertEqual(observed.services[0].ports.first?.bindAddress, "0.0.0.0")
    }

    func testAppleContainerParserParsesRunningFixture() async throws {
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: FakeRuntimeProcessRunner(
                behavior: .result(
                    RuntimeCommandResult(
                        spec: listSpec,
                        exitStatus: 0,
                        standardOutput: try fixture("apple-container-list-running.txt"),
                        standardError: ""
                    )
                )
            )
        )

        let observed = try await adapter.observe(desiredState: desiredState)

        XCTAssertEqual(observed.services.count, 1)
        XCTAssertEqual(observed.services[0].identity.serviceName, "api")
        XCTAssertEqual(observed.services[0].lifecycleState, .running)
        XCTAssertEqual(observed.services[0].healthState, .healthy)
        XCTAssertEqual(observed.services[0].ports.first?.hostPort, 8080)
        XCTAssertEqual(observed.services[0].networks.first?.name, "hostwright-project-demo")
        XCTAssertEqual(observed.services[0].networks.first?.kind, "vmnet")
        XCTAssertEqual(observed.services[0].networks.first?.interfaceName, "vmenet0")
        XCTAssertEqual(observed.services[0].mounts.first?.access, .readOnly)
    }

    func testAppleContainerParserFailsClosedForNonEmptyRealNetworkOutput() {
        let output = """
        [
          {
            "configuration": {
              "id": "hostwright-proof-web",
              "image": { "reference": "hostwright-proof-web:create-only" },
              "publishedPorts": []
            },
            "id": "hostwright-proof-web",
            "status": {
              "state": "running",
              "networks": [
                { "name": "vmnet" }
              ]
            }
          }
        ]
        """

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                output,
                desiredState: proofDesiredState,
                metadata: MockRuntimeAdapter.defaultMetadata
            )
        ) { error in
            guard case RuntimeAdapterError.outputParseFailed(let message) = error else {
                return XCTFail("Expected outputParseFailed, got \(error).")
            }
            XCTAssertTrue(message.contains("Non-empty real Apple container network output is unsupported"))
        }
    }

    func testAppleContainerParserFailsClosedForMalformedOutputWithRedaction() {
        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                "not-json token=fake-token password=fake-password",
                desiredState: desiredState,
                metadata: MockRuntimeAdapter.defaultMetadata
            )
        ) { error in
            guard case RuntimeAdapterError.outputParseFailed(let message) = error else {
                return XCTFail("Expected outputParseFailed, got \(error).")
            }
            XCTAssertFalse(message.contains("fake-token"))
            XCTAssertFalse(message.contains("fake-password"))
            XCTAssertTrue(message.contains("[REDACTED]"))
        }
    }

    func testAppleContainerParserFailsClosedForUnsupportedRealJSONShapesWithRedaction() {
        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                #"{"items":[],"token":"fake-token","password":"fake-password"}"#,
                desiredState: desiredState,
                metadata: MockRuntimeAdapter.defaultMetadata
            )
        ) { error in
            guard case RuntimeAdapterError.outputParseFailed(let message) = error else {
                return XCTFail("Expected outputParseFailed, got \(error).")
            }
            XCTAssertFalse(message.contains("fake-token"))
            XCTAssertFalse(message.contains("fake-password"))
            XCTAssertTrue(message.contains("Unsupported keys"))
        }

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                #"[{"id":"abc","image":"example","token":"fake-token"}]"#,
                desiredState: desiredState,
                metadata: MockRuntimeAdapter.defaultMetadata
            )
        ) { error in
            guard case RuntimeAdapterError.outputParseFailed(let message) = error else {
                return XCTFail("Expected outputParseFailed, got \(error).")
            }
            XCTAssertFalse(message.contains("fake-token"))
            XCTAssertTrue(message.contains("Unsupported real Apple container list item shape"))
        }
    }

    func testAppleContainerParserFailsClosedForRedactionFixture() throws {
        let redactionFixture = try fixture("apple-container-list-redaction.txt")

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                redactionFixture,
                desiredState: desiredState,
                metadata: MockRuntimeAdapter.defaultMetadata
            )
        ) { error in
            guard case RuntimeAdapterError.outputParseFailed(let message) = error else {
                return XCTFail("Expected outputParseFailed, got \(error).")
            }
            XCTAssertFalse(message.contains("fake-token"))
            XCTAssertFalse(message.contains("fake-password"))
            XCTAssertTrue(message.contains("Unsupported keys"))
        }
    }

    func testCLIReconcilerAndHealthDoNotBypassRuntimeBoundary() throws {
        let runtimeCommandFiles = [
            "Sources/HostwrightCLI/main.swift",
            "Sources/HostwrightReconciler/ReconciliationPlanner.swift",
            "Sources/HostwrightHealth/DoctorModels.swift"
        ]

        for file in runtimeCommandFiles {
            let text = try String(contentsOfFile: file, encoding: .utf8)
            XCTAssertFalse(text.contains("AppleContainerCommand"), file)
            XCTAssertFalse(text.contains("AppleContainerReadOnlyAdapter"), file)
            XCTAssertFalse(text.contains("FoundationRuntimeProcessRunner"), file)
        }
    }

    private var identity: RuntimeServiceIdentity {
        RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
    }

    private var desiredState: DesiredRuntimeState {
        DesiredRuntimeState(
            projectName: "demo",
            services: [
                desiredService
            ]
        )
    }

    private var desiredService: DesiredRuntimeService {
        DesiredRuntimeService(
            identity: identity,
            image: "ghcr.io/example/api:latest",
            command: ["serve"],
            environment: [RuntimeEnvironmentValue(name: "APP_ENV", value: "development")],
            ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)]
        )
    }

    private var proofIdentity: RuntimeServiceIdentity {
        RuntimeServiceIdentity(projectName: "proof", serviceName: "web")
    }

    private var proofService: DesiredRuntimeService {
        DesiredRuntimeService(
            identity: proofIdentity,
            image: "hostwright-proof-web:create-only",
            ports: [RuntimePortMapping(hostPort: 18080, containerPort: 80)]
        )
    }

    private var proofDesiredState: DesiredRuntimeState {
        DesiredRuntimeState(projectName: "proof", services: [proofService])
    }

    private var resolvedContainer: FixedRuntimeExecutableResolver {
        FixedRuntimeExecutableResolver(executables: ["container": "/usr/bin/container-fixture"])
    }

    private var listSpec: RuntimeCommandSpec {
        AppleContainerCommand.spec(
            kind: .listContainers,
            executable: ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture")
        )
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func shellSpec(_ script: String, timeout: Int = 5) -> RuntimeCommandSpec {
        RuntimeCommandSpec(
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            timeout: RuntimeCommandTimeout(seconds: timeout),
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "shell fixture"
        )
    }

    private final class RoutingRuntimeProcessRunner: RuntimeProcessRunning, @unchecked Sendable {
        typealias Handler = @Sendable (RuntimeCommandSpec) throws -> RuntimeCommandResult

        private let handler: Handler
        private(set) var calls: [RuntimeCommandSpec] = []

        init(handler: @escaping Handler) {
            self.handler = handler
        }

        func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
            calls.append(spec)
            switch spec.classification {
            case .readOnly:
                try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
            case .mutating:
                try RuntimeCommandPolicy.validateSupportedMutation(spec)
            case .forbidden, .unknown:
                throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "rejected")
            }
            return try handler(spec).redacted()
        }
    }

    private final class RecordingRuntimeHealthURLFetcher: RuntimeHealthURLFetching, @unchecked Sendable {
        struct Request: Equatable {
            let url: URL
            let timeout: RuntimeCommandTimeout
        }

        private let response: RuntimeHealthURLResponse?
        private let error: Error?
        private(set) var requests: [Request] = []

        init(response: RuntimeHealthURLResponse? = nil, error: Error? = nil) {
            self.response = response
            self.error = error
        }

        func fetch(url: URL, timeout: RuntimeCommandTimeout) async throws -> RuntimeHealthURLResponse {
            requests.append(Request(url: url, timeout: timeout))
            if let error {
                throw error
            }
            return response ?? RuntimeHealthURLResponse(statusCode: 200)
        }
    }
}
