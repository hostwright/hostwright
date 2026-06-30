import HostwrightCore
import HostwrightRuntime
import Dispatch

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
        purpose: "fixture"
    )
    precondition(readOnly.timeout.seconds == RuntimeCommandTimeout.maximumSeconds)
    precondition((try? RuntimeCommandPolicy.validatePhase4(readOnly)) != nil)
    precondition(readOnly.redacted().arguments[1].contains("[REDACTED]"))
    precondition(readOnly.redacted().environment["PASSWORD"] == "[REDACTED]")

    let mutating = RuntimeCommandSpec(
        executablePath: "/usr/bin/example",
        arguments: ["delete"],
        classification: .mutating,
        purpose: "fixture"
    )
    precondition((try? RuntimeCommandPolicy.validatePhase4(mutating)) == nil)

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
}()
