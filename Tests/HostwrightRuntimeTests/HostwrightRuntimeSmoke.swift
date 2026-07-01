import HostwrightCore
import HostwrightRuntime
import Dispatch
import Foundation

final class AsyncResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

func runAsync<T>(_ operation: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncResultBox<T>()

    Task {
        do {
            box.result = .success(try await operation())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }

    semaphore.wait()
    return box.result ?? .failure(RuntimeAdapterError.runtimeUnavailable("Async smoke helper did not produce a result."))
}

let hostwrightRuntimeSmoke: Void = {
    let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "web")
    let plan = RuntimePlan(actions: [
        PlannedRuntimeAction(kind: .create, identity: identity, isDestructive: false, summary: "create web")
    ])

    precondition(plan.mutatesRuntime)
    precondition(!plan.includesDestructiveAction)

    let secretEnvironment = RuntimeEnvironmentValue(name: "API_TOKEN", value: "fake-token-123", isSensitive: true)
    precondition(secretEnvironment.redacted().value == "[REDACTED]")

    let readOnly = RuntimeCommandSpec(
        executablePath: "/usr/bin/example",
        arguments: ["list", "token=fake-token-123"],
        environment: ["PASSWORD": "fake-password"],
        timeout: RuntimeCommandTimeout(seconds: 999),
        classification: .readOnly,
        executableResolution: .resolvedByRuntimeExecutableResolver,
        purpose: "fixture"
    )
    precondition(readOnly.timeout.seconds == RuntimeCommandTimeout.maximumSeconds)
    precondition((try? RuntimeCommandPolicy.validatePhase4(readOnly)) != nil)
    precondition((try? RuntimeCommandPolicy.validateReadOnlyExecution(readOnly)) != nil)
    precondition(readOnly.redacted().arguments[1].contains("[REDACTED]"))
    precondition(readOnly.redacted().environment["PASSWORD"] == "[REDACTED]")
    precondition(!RuntimeRedactionPolicy.default.redact(#""token":"fake-token-123""#).contains("fake-token-123"))

    for rejectedClassification in [RuntimeCommandClassification.mutating, .forbidden, .unknown] {
        let rejected = RuntimeCommandSpec(
            executablePath: "/usr/bin/example",
            arguments: ["not-allowed"],
            classification: rejectedClassification,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "fixture"
        )
        precondition((try? RuntimeCommandPolicy.validatePhase4(rejected)) == nil)
        precondition((try? RuntimeCommandPolicy.validateReadOnlyExecution(rejected)) == nil)
    }

    let unresolvedReadOnly = RuntimeCommandSpec(
        executablePath: "/usr/bin/example",
        arguments: ["list"],
        classification: .readOnly,
        purpose: "fixture"
    )
    precondition((try? RuntimeCommandPolicy.validatePhase4(unresolvedReadOnly)) != nil)
    precondition((try? RuntimeCommandPolicy.validateReadOnlyExecution(unresolvedReadOnly)) == nil)

    let adapter = AppleContainerCLIAdapter()
    _ = adapter
}()

let hostwrightRuntimeAsyncSmoke: Void = {
    let mockIdentity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
    let mockDesired = DesiredRuntimeState(
        projectName: "demo",
        services: [
            DesiredRuntimeService(identity: mockIdentity, image: "ghcr.io/example/api:latest")
        ]
    )
    let mockObservedService = ObservedRuntimeService(
        identity: mockIdentity,
        image: "ghcr.io/example/api:latest",
        lifecycleState: .running,
        healthState: .healthy
    )
    let mockAdapter = MockRuntimeAdapter(scenario: .observed([mockObservedService]))

    switch runAsync({ try await mockAdapter.observe(desiredState: mockDesired) }) {
    case .success(let mockObserved):
        precondition(mockObserved.services.count == 1)
        precondition(mockObserved.services[0].lifecycleState == .running)
    case .failure(let error):
        preconditionFailure("Unexpected mock observe failure: \(error).")
    }

    let emptyAdapter = MockRuntimeAdapter(scenario: .availableEmpty)
    let emptyObserved: ObservedRuntimeState
    switch runAsync({ try await emptyAdapter.observe(desiredState: mockDesired) }) {
    case .success(let observed):
        emptyObserved = observed
    case .failure(let error):
        preconditionFailure("Unexpected empty observe failure: \(error).")
    }

    switch runAsync({ try await emptyAdapter.plan(desiredState: mockDesired, observedState: emptyObserved) }) {
    case .success(let mockPlan):
        precondition(mockPlan.actions.map(\.kind) == [.create])
    case .failure(let error):
        preconditionFailure("Unexpected mock plan failure: \(error).")
    }

    let redactingAdapter = MockRuntimeAdapter(scenario: .redactedFailure("password=fake-password token=fake-token"))
    switch runAsync({ try await redactingAdapter.observe(desiredState: mockDesired) }) {
    case .success:
        preconditionFailure("Expected redacted failure.")
    case .failure(let error as RuntimeAdapterError):
        if case .commandFailed(_, _, let standardError) = error {
            precondition(!standardError.contains("fake-password"))
            precondition(!standardError.contains("fake-token"))
            precondition(standardError.contains("[REDACTED]"))
        } else {
            preconditionFailure("Unexpected runtime error: \(error).")
        }
    case .failure(let error):
        preconditionFailure("Unexpected error: \(error).")
    }

    switch runAsync({
        try await mockAdapter.execute(
            PlannedRuntimeAction(kind: .start, identity: mockIdentity, isDestructive: false, summary: "start"),
            confirmation: nil
        )
    }) {
    case .success:
        preconditionFailure("Expected mutation unavailable.")
    case .failure(let error as RuntimeAdapterError):
        if case .mutationUnavailableInCurrentPhase = error {
            precondition(true)
        } else {
            preconditionFailure("Unexpected runtime error: \(error).")
        }
    case .failure(let error):
        preconditionFailure("Unexpected error: \(error).")
    }

    let missingAppleAdapter = AppleContainerReadOnlyAdapter(
        executableResolver: FixedRuntimeExecutableResolver(executables: [:]),
        processRunner: FakeRuntimeProcessRunner(behavior: .failure(.runtimeUnavailable("should not run")))
    )
    switch runAsync({ try await missingAppleAdapter.observe(desiredState: mockDesired) }) {
    case .success:
        preconditionFailure("Expected missing executable to degrade honestly.")
    case .failure(let error as RuntimeAdapterError):
        if case .runtimeUnavailable(let message) = error {
            precondition(message.contains("not found"))
        } else {
            preconditionFailure("Unexpected missing executable error: \(error).")
        }
    case .failure(let error):
        preconditionFailure("Unexpected error: \(error).")
    }

    func fixture(_ name: String) -> String {
        let path = "Tests/HostwrightRuntimeTests/Fixtures/\(name)"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            preconditionFailure("Missing fixture at \(path).")
        }
        return text
    }

    let resolvedContainer = FixedRuntimeExecutableResolver(executables: ["container": "/usr/bin/container-fixture"])
    let emptySpec = AppleContainerCommand.spec(
        kind: .listContainers,
        executable: ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture")
    )
    let emptyAppleAdapter = AppleContainerReadOnlyAdapter(
        executableResolver: resolvedContainer,
        processRunner: FakeRuntimeProcessRunner(
            behavior: .result(
                RuntimeCommandResult(
                    spec: emptySpec,
                    exitStatus: 0,
                    standardOutput: fixture("apple-container-list-empty.txt"),
                    standardError: ""
                )
            )
        )
    )
    switch runAsync({ try await emptyAppleAdapter.observe(desiredState: mockDesired) }) {
    case .success(let observed):
        precondition(observed.services.isEmpty)
        precondition(observed.adapterMetadata?.supportsMutation == false)
    case .failure(let error):
        preconditionFailure("Unexpected empty fixture failure: \(error).")
    }

    let runningAdapter = AppleContainerReadOnlyAdapter(
        executableResolver: resolvedContainer,
        processRunner: FakeRuntimeProcessRunner(
            behavior: .result(
                RuntimeCommandResult(
                    spec: emptySpec,
                    exitStatus: 0,
                    standardOutput: fixture("apple-container-list-running.txt"),
                    standardError: ""
                )
            )
        )
    )
    switch runAsync({ try await runningAdapter.observe(desiredState: mockDesired) }) {
    case .success(let observed):
        precondition(observed.services.count == 1)
        precondition(observed.services[0].identity.serviceName == "api")
        precondition(observed.services[0].lifecycleState == .running)
        precondition(observed.services[0].healthState == .healthy)
        precondition(observed.services[0].ports.first?.hostPort == 8080)
        precondition(observed.services[0].mounts.first?.access == .readOnly)
    case .failure(let error):
        preconditionFailure("Unexpected running fixture failure: \(error).")
    }

    switch runAsync({
        try AppleContainerObservationParser.parse(
            "not-json token=fake-token password=fake-password",
            desiredState: mockDesired,
            metadata: MockRuntimeAdapter.defaultMetadata
        )
    }) {
    case .success:
        preconditionFailure("Expected malformed output to fail closed.")
    case .failure(let error as RuntimeAdapterError):
        if case .outputParseFailed(let message) = error {
            precondition(!message.contains("fake-token"))
            precondition(!message.contains("fake-password"))
            precondition(message.contains("[REDACTED]"))
        } else {
            preconditionFailure("Unexpected parse error: \(error).")
        }
    case .failure(let error):
        preconditionFailure("Unexpected error: \(error).")
    }

    let redactionFixture = fixture("apple-container-list-redaction.txt")
    switch runAsync({
        try AppleContainerObservationParser.parse(
            redactionFixture,
            desiredState: mockDesired,
            metadata: MockRuntimeAdapter.defaultMetadata
        )
    }) {
    case .success:
        preconditionFailure("Expected unsupported schema to fail closed.")
    case .failure(let error as RuntimeAdapterError):
        if case .outputParseFailed(let message) = error {
            precondition(!message.contains("fake-token"))
            precondition(!message.contains("fake-password"))
            precondition(message.contains("[REDACTED]"))
        } else {
            preconditionFailure("Unexpected parse error: \(error).")
        }
    case .failure(let error):
        preconditionFailure("Unexpected error: \(error).")
    }

    let runtimeCommandFiles = [
        "Sources/HostwrightCLI/main.swift",
        "Sources/HostwrightReconciler/ReconciliationPlanner.swift",
        "Sources/HostwrightHealth/DoctorModels.swift"
    ]
    for file in runtimeCommandFiles {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            preconditionFailure("Unable to inspect \(file).")
        }
        precondition(!text.contains("AppleContainerCommand"))
        precondition(!text.contains("AppleContainerReadOnlyAdapter"))
        precondition(!text.contains("FoundationRuntimeProcessRunner"))
    }
}()
