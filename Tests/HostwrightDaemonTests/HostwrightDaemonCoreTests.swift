import Foundation
import XCTest
@testable import HostwrightDaemonCore
@testable import HostwrightRuntime
@testable import HostwrightState

final class HostwrightDaemonCoreTests: XCTestCase {
    func testCommandParserRequiresForegroundConfigAndStatePath() throws {
        XCTAssertThrowsError(try DaemonCommand.parse(arguments: ["--config", "hostwright.yaml", "--state-db", "/tmp/state.sqlite"])) { error in
            XCTAssertTrue(String(describing: error).contains("--foreground"))
        }
        XCTAssertThrowsError(try DaemonCommand.parse(arguments: ["--foreground", "--config", "hostwright.yaml"])) { error in
            XCTAssertTrue(String(describing: error).contains("--state-db"))
        }

        let command = try DaemonCommand.parse(arguments: [
            "--foreground",
            "--config", "hostwright.yaml",
            "--state-db", "/tmp/hostwright.sqlite",
            "--interval", "12",
            "--jitter", "0",
            "--max-backoff", "60",
            "--max-iterations", "2"
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("Expected run command.")
        }
        XCTAssertEqual(configuration.configPath, "hostwright.yaml")
        XCTAssertEqual(configuration.stateDatabasePath, "/tmp/hostwright.sqlite")
        XCTAssertEqual(configuration.cadenceSeconds, 12)
        XCTAssertEqual(configuration.jitterSeconds, 0)
        XCTAssertEqual(configuration.maxBackoffSeconds, 60)
        XCTAssertEqual(configuration.maxIterations, 2)
    }

    func testForegroundLoopRecordsReconciliationWithoutRuntimeMutation() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let adapter = CountingRuntimeAdapter(observedServices: [Self.observedService()])
            let clock = FakeDaemonClock()
            let lock = FakeDaemonLock()
            let ids = DeterministicIDs()
            let configuration = DaemonConfiguration(
                configPath: "hostwright.yaml",
                stateDatabasePath: databasePath,
                cadenceSeconds: 10,
                jitterSeconds: 0,
                maxBackoffSeconds: 60,
                maxIterations: 1
            )
            let runner = DaemonLoopRunner(
                configuration: configuration,
                runtimeAdapter: adapter,
                clock: clock,
                instanceLock: lock,
                readConfig: { _ in Self.singleServiceManifest },
                idGenerator: ids.next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.iterations, 1)
            XCTAssertEqual(summary.successfulIterations, 1)
            XCTAssertEqual(summary.failedIterations, 0)
            XCTAssertEqual(adapter.observeCount, 1)
            XCTAssertEqual(adapter.executeCount, 0)
            XCTAssertEqual(lock.releaseCount, 1)

            let store = SQLiteStateStore(path: databasePath)
            let events = try store.events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "daemon.started" })
            XCTAssertTrue(events.contains { $0.type == "daemon.reconcile.succeeded" && $0.message.contains("attempted no runtime mutation") })
            XCTAssertTrue(events.contains { $0.type == "daemon.stopped" })

            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations.filter { $0.plannedActionType == "daemon.reconcile" }.map(\.status), [.succeeded])
            XCTAssertEqual(try store.desiredStates.loadProject(id: "project-demo").name, "demo")
            XCTAssertEqual(try store.observedStates.loadSnapshots(projectID: "project-demo").count, 1)
        }
    }

    func testRuntimeFailuresBackOffWithJitterAndPersistFailureRecords() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let adapter = CountingRuntimeAdapter(error: .runtimeUnavailable("runtime unavailable token=fake-secret"))
            let clock = FakeDaemonClock()
            let ids = DeterministicIDs()
            let configuration = DaemonConfiguration(
                configPath: "hostwright.yaml",
                stateDatabasePath: databasePath,
                cadenceSeconds: 10,
                jitterSeconds: 5,
                maxBackoffSeconds: 60,
                maxIterations: 3
            )
            let runner = DaemonLoopRunner(
                configuration: configuration,
                runtimeAdapter: adapter,
                clock: clock,
                instanceLock: FakeDaemonLock(),
                readConfig: { _ in Self.singleServiceManifest },
                idGenerator: ids.next,
                jitterProvider: { iteration, _ in iteration == 1 ? 2 : 3 }
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.iterations, 3)
            XCTAssertEqual(summary.successfulIterations, 0)
            XCTAssertEqual(summary.failedIterations, 3)
            XCTAssertEqual(clock.sleepDurations, [12, 23])

            let store = SQLiteStateStore(path: databasePath)
            let events = try store.events.loadAll()
            XCTAssertEqual(events.filter { $0.type == "daemon.backoff" }.count, 2)
            XCTAssertEqual(events.filter { $0.type == "daemon.reconcile.failed" }.count, 3)
            XCTAssertFalse(events.map(\.message).joined(separator: "\n").contains("fake-secret"))
            XCTAssertEqual(try store.operations.loadAll().filter { $0.plannedActionType == "daemon.reconcile" }.map(\.status), [.failed, .failed, .failed])
        }
    }

    func testManifestFailuresAreClassifiedWithoutRuntimeCode() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let adapter = CountingRuntimeAdapter(observedServices: [Self.observedService()])
            let ids = DeterministicIDs()
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: adapter,
                clock: FakeDaemonClock(),
                instanceLock: FakeDaemonLock(),
                readConfig: { _ in "project: demo\nservices:\n" },
                idGenerator: ids.next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.failedIterations, 1)
            XCTAssertEqual(adapter.observeCount, 0)
            XCTAssertEqual(adapter.executeCount, 0)
            let events = try SQLiteStateStore(path: databasePath).events.loadAll()
            let failed = try XCTUnwrap(events.first { $0.type == "daemon.reconcile.failed" })
            XCTAssertTrue(failed.message.contains("HW-MANIFEST-002"))
            XCTAssertFalse(failed.message.contains("HW-RUNTIME-001"))
            let operations = try SQLiteStateStore(path: databasePath).operations.loadAll()
            XCTAssertTrue(try XCTUnwrap(operations.first { $0.plannedActionType == "daemon.reconcile" }).payloadJSONRedacted.contains("HW-MANIFEST-002"))
        }
    }

    func testConfigReadFailuresAreClassifiedAndRedacted() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let ids = DeterministicIDs()
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "missing-hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: CountingRuntimeAdapter(observedServices: [Self.observedService()]),
                clock: FakeDaemonClock(),
                instanceLock: FakeDaemonLock(),
                readConfig: { _ in
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileReadNoSuchFileError,
                        userInfo: [NSLocalizedDescriptionKey: "missing config token=fake-secret"]
                    )
                },
                idGenerator: ids.next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.failedIterations, 1)
            let events = try SQLiteStateStore(path: databasePath).events.loadAll()
            let failed = try XCTUnwrap(events.first { $0.type == "daemon.reconcile.failed" })
            XCTAssertTrue(failed.message.contains("HW-MANIFEST-004"))
            XCTAssertFalse(failed.message.contains("fake-secret"))
            XCTAssertFalse(failed.payloadJSONRedacted.contains("fake-secret"))
        }
    }

    func testDefaultReadOnlyLocalAdapterIsNonMutating() async {
        let metadata = await RuntimeAdapterFactory.defaultReadOnlyLocal().metadata()

        XCTAssertFalse(metadata.supportsMutation)
        XCTAssertEqual(metadata.adapterName, "AppleContainerReadOnlyAdapter")
    }

    func testShutdownTokenStopsLoopAfterSleep() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let shutdownToken = DaemonShutdownToken()
            let clock = FakeDaemonClock(wakeReasons: [.shutdownRequested])
            let ids = DeterministicIDs()
            let configuration = DaemonConfiguration(
                configPath: "hostwright.yaml",
                stateDatabasePath: databasePath,
                cadenceSeconds: 5,
                jitterSeconds: 0,
                maxBackoffSeconds: 20
            )
            let runner = DaemonLoopRunner(
                configuration: configuration,
                runtimeAdapter: CountingRuntimeAdapter(observedServices: [Self.observedService()]),
                clock: clock,
                instanceLock: FakeDaemonLock(),
                shutdownToken: shutdownToken,
                readConfig: { _ in Self.singleServiceManifest },
                idGenerator: ids.next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.iterations, 1)
            XCTAssertTrue(summary.stoppedByShutdown)
            XCTAssertEqual(clock.sleepDurations, [5])
            let events = try SQLiteStateStore(path: databasePath).events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "daemon.stopped" && $0.message.contains("shutdown request") })
        }
    }

    func testSingleInstanceLockPreventsLoopStart() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let adapter = CountingRuntimeAdapter(observedServices: [Self.observedService()])
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(configPath: "hostwright.yaml", stateDatabasePath: databasePath, maxIterations: 1),
                runtimeAdapter: adapter,
                clock: FakeDaemonClock(),
                instanceLock: FakeDaemonLock(canAcquire: false),
                readConfig: { _ in Self.singleServiceManifest }
            )

            do {
                _ = try await runner.run()
                XCTFail("Expected lockUnavailable.")
            } catch DaemonError.lockUnavailable(let path) {
                XCTAssertTrue(path.contains("hostwrightd.lock"))
            }
            XCTAssertEqual(adapter.observeCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath))
        }
    }

    func testSleepWakeResumeEventIsPersisted() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let clock = FakeDaemonClock(wakeReasons: [.systemWake])
            let ids = DeterministicIDs()
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    cadenceSeconds: 7,
                    jitterSeconds: 0,
                    maxBackoffSeconds: 30,
                    maxIterations: 2
                ),
                runtimeAdapter: CountingRuntimeAdapter(observedServices: [Self.observedService()]),
                clock: clock,
                instanceLock: FakeDaemonLock(),
                readConfig: { _ in Self.singleServiceManifest },
                idGenerator: ids.next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.iterations, 2)
            XCTAssertEqual(clock.sleepDurations, [7])
            let events = try SQLiteStateStore(path: databasePath).events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "daemon.sleep_wake_resumed" })
        }
    }

    private static let singleServiceManifest = """
    project: demo
    services:
      api:
        image: ghcr.io/example/api:latest
        ports:
          - "8080:8080"
    """

    private static func observedService() -> ObservedRuntimeService {
        ObservedRuntimeService(
            identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
            image: "ghcr.io/example/api:latest",
            lifecycleState: .running,
            healthState: .healthy,
            ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080, bindAddress: "127.0.0.1")]
        )
    }

}

private final class FakeDaemonClock: DaemonClock {
    var timestamps: [String]
    var sleepDurations: [Int] = []
    var wakeReasons: [DaemonWakeReason]

    init(
        timestamps: [String] = (0..<100).map { String(format: "2026-07-07T00:00:%02dZ", $0) },
        wakeReasons: [DaemonWakeReason] = []
    ) {
        self.timestamps = timestamps
        self.wakeReasons = wakeReasons
    }

    func timestamp() -> String {
        if timestamps.isEmpty {
            return "2026-07-07T00:00:00Z"
        }
        return timestamps.removeFirst()
    }

    func sleep(seconds: Int) async throws -> DaemonWakeReason {
        sleepDurations.append(seconds)
        if wakeReasons.isEmpty {
            return .scheduled
        }
        return wakeReasons.removeFirst()
    }
}

private final class FakeDaemonLock: DaemonInstanceLock {
    let canAcquire: Bool
    var releaseCount = 0

    init(canAcquire: Bool = true) {
        self.canAcquire = canAcquire
    }

    func acquire() throws -> Bool {
        canAcquire
    }

    func release() {
        releaseCount += 1
    }
}

private final class CountingRuntimeAdapter: RuntimeAdapter, @unchecked Sendable {
    private let observedServices: [ObservedRuntimeService]
    private let error: RuntimeAdapterError?
    private(set) var observeCount = 0
    private(set) var executeCount = 0

    init(observedServices: [ObservedRuntimeService] = [], error: RuntimeAdapterError? = nil) {
        self.observedServices = observedServices
        self.error = error
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            adapterName: "CountingRuntimeAdapter",
            adapterVersion: "test",
            runtimeName: "test",
            runtimeVersion: nil,
            supportsMutation: true,
            capabilities: [.readOnlyObservation]
        )
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation]
    }

    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        observeCount += 1
        if let error {
            throw error
        }
        return ObservedRuntimeState(
            projectName: desiredState.projectName,
            services: observedServices,
            adapterMetadata: await metadata()
        )
    }

    func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
        RuntimePlan(actions: [])
    }

    func logs(for identity: RuntimeServiceIdentity, tail: Int) async throws -> RuntimeLogResult {
        RuntimeLogResult(identity: identity, text: "", lineLimit: tail)
    }

    func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        executeCount += 1
        return RuntimeEvent(identity: action.identity, severity: .info, message: "unexpected", resourceIdentifier: nil)
    }
}

private final class DeterministicIDs {
    private var counter = 0

    func next(prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }
}

private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-daemon-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    try await body(directory)
}
