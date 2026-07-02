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

        XCTAssertNoThrow(try RuntimeCommandPolicy.validatePhase4(readOnly))
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

            XCTAssertThrowsError(try RuntimeCommandPolicy.validatePhase4(rejected))
            XCTAssertThrowsError(try RuntimeCommandPolicy.validateReadOnlyExecution(rejected))
        }
    }

    func testPhase8BMutationPolicyAcceptsOnlyResolvedCreateMissingServiceSpecs() {
        let create = AppleContainerCommand.spec(
            kind: .createContainer,
            executable: ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture"),
            desiredService: desiredService
        )

        XCTAssertNoThrow(try RuntimeCommandPolicy.validatePhase8BMutation(create))
        XCTAssertEqual(create.classification, .mutating)
        XCTAssertEqual(create.mutationKind, .createMissingService)
        XCTAssertEqual(create.arguments.prefix(3), ["create", "--name", "hostwright-demo-api"])
        XCTAssertTrue(create.arguments.contains("--publish"))
        XCTAssertFalse(create.arguments.contains("run"))
        XCTAssertFalse(create.arguments.contains("--rm"))

        let unresolved = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["create"],
            classification: .mutating,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validatePhase8BMutation(unresolved))

        let forbidden = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["delete"],
            classification: .forbidden,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validatePhase8BMutation(forbidden))
    }

    func testReadOnlyExecutionRejectsUnresolvedExecutable() {
        let unresolvedReadOnly = RuntimeCommandSpec(
            executablePath: "/usr/bin/example",
            arguments: ["list"],
            classification: .readOnly,
            purpose: "fixture"
        )

        XCTAssertNoThrow(try RuntimeCommandPolicy.validatePhase4(unresolvedReadOnly))
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

    func testRuntimeMutationRemainsUnavailable() async {
        let adapter = MockRuntimeAdapter(scenario: .availableEmpty)

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(kind: .start, identity: identity, isDestructive: false, summary: "start"),
                confirmation: nil
            )
            XCTFail("Expected mutation unavailable.")
        } catch let error as RuntimeAdapterError {
            guard case .mutationUnavailableInCurrentPhase = error else {
                return XCTFail("Expected mutationUnavailableInCurrentPhase, got \(error).")
            }
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testAppleContainerApplyAdapterCreatesOnlyWhenLocalImageIsAvailable() async throws {
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["image", "list", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: #"["ghcr.io/example/api:latest"]"#, standardError: "")
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
                identity: identity,
                isDestructive: false,
                summary: "create",
                desiredService: desiredService
            ),
            confirmation: RuntimeMutationConfirmation(confirmed: true, reason: "test", planHash: "plan-hash")
        )

        XCTAssertEqual(runner.calls.compactMap(\.arguments.first), ["image", "create"])
        XCTAssertEqual(event.resourceIdentifier, "hostwright-demo-api")
        XCTAssertFalse(event.message.contains("fake-token"))
        XCTAssertTrue(event.message.contains("[REDACTED]"))
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
        XCTAssertEqual(observed.services[0].mounts.first?.access, .readOnly)
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
            XCTAssertTrue(message.contains("Non-empty real Apple container JSON list output is not supported yet"))
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
                try RuntimeCommandPolicy.validatePhase8BMutation(spec)
            case .forbidden, .unknown:
                throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "rejected")
            }
            return try handler(spec).redacted()
        }
    }
}
