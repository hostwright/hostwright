import Darwin
import Foundation
import XCTest
@testable import HostwrightDaemonCore
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightState

final class HostwrightDaemonCoreTests: XCTestCase {
    func testFileDaemonInstanceLockContendsOnRealFile() async throws {
        try await withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("hostwrightd.lock").path
            let first = FileDaemonInstanceLock(path: path)
            let second = FileDaemonInstanceLock(path: path)

            XCTAssertTrue(try first.acquire())
            XCTAssertFalse(try second.acquire())

            first.release()
            XCTAssertTrue(try second.acquire())
            second.release()

            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertEqual(try permissions(path), 0o600)

            let restrictivePath = directory.appendingPathComponent("restrictive.lock").path
            let previousMask = umask(0o777)
            let restrictive = FileDaemonInstanceLock(path: restrictivePath)
            let acquired: Bool
            do {
                acquired = try restrictive.acquire()
            } catch {
                _ = umask(previousMask)
                throw error
            }
            _ = umask(previousMask)
            XCTAssertTrue(acquired)
            restrictive.release()
            XCTAssertEqual(try permissions(restrictivePath), 0o600)
        }
    }

    func testFileDaemonInstanceLockRejectsSymlinkUnsafeParentAndUnsafeMode() async throws {
        try await withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("target.lock")
            try Data().write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            let symlink = directory.appendingPathComponent("symlink.lock")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
            XCTAssertThrowsError(try FileDaemonInstanceLock(path: symlink.path).acquire())

            let unsafeMode = directory.appendingPathComponent("unsafe-mode.lock")
            try Data().write(to: unsafeMode)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unsafeMode.path)
            XCTAssertThrowsError(try FileDaemonInstanceLock(path: unsafeMode.path).acquire())

            let unsafeACL = directory.appendingPathComponent("unsafe-acl.lock")
            try Data().write(to: unsafeACL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: unsafeACL.path
            )
            try setEveryoneReadACL(on: unsafeACL.path)
            XCTAssertThrowsError(try FileDaemonInstanceLock(path: unsafeACL.path).acquire()) { error in
                XCTAssertTrue(String(describing: error).contains("access-granting"))
            }

            let unsafeParent = directory.appendingPathComponent("unsafe-parent", isDirectory: true)
            try FileManager.default.createDirectory(at: unsafeParent, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: unsafeParent.path)
            XCTAssertThrowsError(
                try FileDaemonInstanceLock(path: unsafeParent.appendingPathComponent("hostwrightd.lock").path).acquire()
            )

            let specialParent = directory.appendingPathComponent("special-parent", isDirectory: true)
            try FileManager.default.createDirectory(
                at: specialParent,
                withIntermediateDirectories: false
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o2700],
                ofItemAtPath: specialParent.path
            )
            XCTAssertThrowsError(
                try FileDaemonInstanceLock(
                    path: specialParent.appendingPathComponent("hostwrightd.lock").path
                ).acquire()
            )

            XCTAssertThrowsError(
                try FileDaemonInstanceLock(
                    path: directory.path + "//non-normalized.lock"
                ).acquire()
            )
        }
    }

    func testCommandParserRequiresForegroundAndConfigButDefaultsStatePath() throws {
        XCTAssertThrowsError(try DaemonCommand.parse(arguments: ["--config", "hostwright.yaml", "--state-db", "/tmp/state.sqlite"])) { error in
            XCTAssertTrue(String(describing: error).contains("--foreground"))
        }
        let defaultCommand = try DaemonCommand.parse(
            arguments: ["--foreground", "--config", "hostwright.yaml"],
            homeDirectory: "/Users/example",
            environment: [:]
        )
        guard case .run(let defaultConfiguration) = defaultCommand else {
            return XCTFail("Expected default run command.")
        }
        XCTAssertEqual(
            defaultConfiguration.stateDatabasePath,
            "/Users/example/Library/Application Support/Hostwright/state/state.sqlite"
        )
        XCTAssertEqual(
            defaultConfiguration.lockFilePath,
            "/Users/example/Library/Application Support/Hostwright/run/hostwrightd.lock"
        )
        XCTAssertEqual(defaultConfiguration.stateStoreConfiguration.origin, .applicationSupportDefault)

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

    func testDefaultPathDaemonRunCreatesPrivateLayoutAndUsesRealLock() async throws {
        try await withTemporaryDirectory { home in
            let manifest = home.appendingPathComponent("hostwright.yaml")
            try Data(Self.singleServiceManifest.utf8).write(to: manifest)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
            let command = try DaemonCommand.parse(
                arguments: [
                    "--foreground",
                    "--config", manifest.path,
                    "--max-iterations", "1"
                ],
                homeDirectory: home.path,
                environment: [:]
            )
            guard case .run(let configuration) = command else {
                return XCTFail("Expected run command.")
            }
            let runner = DaemonLoopRunner(
                configuration: configuration,
                runtimeAdapter: CountingRuntimeAdapter(observedServices: [Self.observedService()]),
                clock: ManualDaemonClock(),
                instanceLock: FileDaemonInstanceLock(path: configuration.lockFilePath),
                readConfig: { try String(contentsOfFile: $0, encoding: .utf8) },
                idGenerator: DeterministicIDs().next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.successfulIterations, 1)
            XCTAssertEqual(configuration.stateStoreConfiguration.origin, .applicationSupportDefault)
            XCTAssertEqual(try permissions(configuration.stateDatabasePath), 0o600)
            XCTAssertEqual(try permissions(configuration.lockFilePath), 0o600)
            let resolution = try XCTUnwrap(configuration.stateStoreConfiguration.localPathResolution)
            for directory in resolution.layout.ownedDirectories {
                XCTAssertEqual(try permissions(directory), 0o700, directory)
            }
            XCTAssertTrue(
                try SQLiteStateStore(configuration: configuration.stateStoreConfiguration)
                    .events.loadAll()
                    .contains { $0.type == "daemon.reconcile.succeeded" }
            )
        }
    }

    func testForegroundLoopRecordsReconciliationWithoutRuntimeMutation() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let adapter = CountingRuntimeAdapter(observedServices: [Self.observedService()])
            let clock = ManualDaemonClock()
            let lock = ScriptedDaemonLock()
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

    func testForegroundLoopPersistsRedactedHealthResultAndRestartState() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let healthChecker = ScriptedHealthChecker(results: [
                RuntimeHealthCheckResult(
                    identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                    status: .unhealthy,
                    exitStatus: 22,
                    timedOut: false,
                    command: ["curl", "-f", "http://localhost:8080/health?token=fake-secret"],
                    standardOutput: "token=fake-secret",
                    standardError: "password=fake-password"
                )
            ])
            let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
            let network = RuntimeNetworkAttachment(
                name: "default",
                hostname: "api.local",
                ipv4Address: "192.168.64.8/24",
                mtu: 1500
            )
            let adapter = CountingRuntimeAdapter(observedServices: [
                Self.observedService(
                    healthState: .unknown,
                    resourceIdentifier: identity.legacyManagedResourceIdentifier,
                    networks: [network]
                )
            ])
            let ids = DeterministicIDs()
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: adapter,
                healthChecker: healthChecker,
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in Self.healthRestartManifest },
                idGenerator: ids.next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.successfulIterations, 1)
            XCTAssertEqual(adapter.executeCount, 0)
            XCTAssertEqual(healthChecker.calls.map(\.identity.serviceName), ["api"])

            let store = SQLiteStateStore(path: databasePath)
            let healthResults = try store.healthResults.loadProject(projectID: "project-demo")
            XCTAssertEqual(healthResults.map(\.status), [.unhealthy])
            XCTAssertEqual(healthResults[0].exitStatus, 22)
            XCTAssertFalse(healthResults[0].commandJSONRedacted.contains("fake-secret"))
            XCTAssertFalse(healthResults[0].stdoutRedacted.contains("fake-secret"))
            XCTAssertFalse(healthResults[0].stderrRedacted.contains("fake-password"))

            let latestSnapshot = try XCTUnwrap(store.observedStates.loadSnapshots(projectID: "project-demo").last)
            let observed = try store.observedStates.loadObservedServices(snapshotID: latestSnapshot.id)
            XCTAssertEqual(observed[0].healthState, .unhealthy)
            XCTAssertEqual(observed[0].resourceIdentifier, identity.legacyManagedResourceIdentifier)
            XCTAssertTrue(observed[0].networksJSON.contains("192.168.64.8"))
            XCTAssertTrue(observed[0].networksJSON.contains("1500"))

            let restartState = try XCTUnwrap(store.restartPolicies.load(projectID: "project-demo", serviceName: "api"))
            XCTAssertEqual(restartState.policy, .onFailure)
            XCTAssertEqual(restartState.status, .active)

            let events = try store.events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "health.check.unhealthy" })
            XCTAssertTrue(events.contains { $0.type == "restart.policy.state" })
            XCTAssertFalse(events.map(\.payloadJSONRedacted).joined().contains("fake-secret"))
            XCTAssertFalse(events.map(\.payloadJSONRedacted).joined().contains("fake-password"))
        }
    }

    func testForegroundLoopHonorsPersistedHealthInterval() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let healthChecker = ScriptedHealthChecker(results: [
                RuntimeHealthCheckResult(
                    identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                    status: .healthy,
                    exitStatus: 0,
                    timedOut: false,
                    command: ["curl", "-f", "http://localhost:8080/health"],
                    standardOutput: "",
                    standardError: ""
                )
            ])
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    cadenceSeconds: 1,
                    jitterSeconds: 0,
                    maxBackoffSeconds: 10,
                    maxIterations: 2
                ),
                runtimeAdapter: CountingRuntimeAdapter(observedServices: [Self.observedService(healthState: .unknown)]),
                healthChecker: healthChecker,
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in Self.healthRestartManifest },
                idGenerator: DeterministicIDs().next
            )

            _ = try await runner.run()

            XCTAssertEqual(healthChecker.calls.count, 1)
            XCTAssertEqual(try SQLiteStateStore(path: databasePath).healthResults.loadProject(projectID: "project-demo").count, 1)
        }
    }

    func testForegroundLoopHonorsCrashLoopRestartStateWithoutMutation() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try store.desiredStates.saveManifestSnapshot(
                projectID: "project-demo",
                manifestPath: "hostwright.yaml",
                manifestHash: "seed",
                desiredGeneration: 1,
                manifest: Self.healthRestartManifestModel,
                timestamp: "2026-07-07T00:00:00Z"
            )
            try store.restartPolicies.upsert(
                RestartPolicyStateRecord(
                    id: "restart-api",
                    projectID: "project-demo",
                    serviceName: "api",
                    policy: .onFailure,
                    status: .crashLoopBlocked,
                    attemptCount: 3,
                    maxAttempts: 3,
                    backoffSeconds: 60,
                    updatedAt: "2026-07-07T00:00:00Z",
                    metadataJSONRedacted: "{}"
                )
            )

            let adapter = CountingRuntimeAdapter(observedServices: [
                Self.observedService(lifecycleState: .exited, healthState: .unknown)
            ])
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: adapter,
                healthChecker: ScriptedHealthChecker(results: []),
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in Self.healthRestartManifest },
                idGenerator: DeterministicIDs().next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.successfulIterations, 1)
            XCTAssertEqual(adapter.executeCount, 0)
            let restartState = try XCTUnwrap(store.restartPolicies.load(projectID: "project-demo", serviceName: "api"))
            XCTAssertEqual(restartState.status, .crashLoopBlocked)

            let daemonOperation = try XCTUnwrap(try store.operations.loadAll().first { $0.plannedActionType == "daemon.reconcile" })
            XCTAssertTrue(daemonOperation.payloadJSONRedacted.contains(#""restartPolicyBlocked":1"#))
            let events = try store.events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "restart.policy.state" && $0.message.contains("crashLoopBlocked") })
        }
    }

    func testRuntimeFailuresBackOffWithJitterAndPersistFailureRecords() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let adapter = CountingRuntimeAdapter(error: .runtimeUnavailable("runtime unavailable token=fake-secret"))
            let clock = ManualDaemonClock()
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
                instanceLock: ScriptedDaemonLock(),
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
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
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
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
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
            let clock = ManualDaemonClock(wakeReasons: [.shutdownRequested])
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
                instanceLock: ScriptedDaemonLock(),
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
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(canAcquire: false),
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
            let clock = ManualDaemonClock(wakeReasons: [.systemWake])
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
                instanceLock: ScriptedDaemonLock(),
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
    version: 2
    project: demo
    services:
      api:
        image: ghcr.io/example/api:latest
        ports:
          - "8080:8080"
    """

    private static let healthRestartManifest = """
    version: 2
    project: demo
    services:
      api:
        image: ghcr.io/example/api:latest
        ports:
          - "8080:8080"
        health:
          command: ["curl", "-f", "http://localhost:8080/health?token=fake-secret"]
          interval: 10s
        restart:
          policy: on-failure
    """

    private static var healthRestartManifestModel: HostwrightManifest {
        HostwrightManifest(
            project: "demo",
            services: [
                HostwrightService(
                    name: "api",
                    image: "ghcr.io/example/api:latest",
                    ports: ["8080:8080"],
                    health: HostwrightHealthCheck(
                        command: ["curl", "-f", "http://localhost:8080/health?token=fake-secret"],
                        interval: "10s"
                    ),
                    restart: HostwrightRestart(policy: "on-failure")
                )
            ]
        )
    }

    private static func observedService(
        lifecycleState: RuntimeLifecycleState = .running,
        healthState: RuntimeHealthState = .healthy,
        resourceIdentifier: String? = nil,
        networks: [RuntimeNetworkAttachment] = []
    ) -> ObservedRuntimeService {
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
        return ObservedRuntimeService(
            identity: identity,
            resourceIdentifier: resourceIdentifier ?? identity.managedResourceIdentifier,
            image: "ghcr.io/example/api:latest",
            lifecycleState: lifecycleState,
            healthState: healthState,
            ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080, bindAddress: "127.0.0.1")],
            networks: networks
        )
    }

}

private func permissions(_ path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func setEveryoneReadACL(on path: String) throws {
    let text = """
    !#acl 1
    group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:read

    """
    guard let accessControlList = acl_from_text(text) else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
    guard acl_set_file(path, ACL_TYPE_EXTENDED, accessControlList) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private final class ManualDaemonClock: DaemonClock {
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

private final class ScriptedDaemonLock: DaemonInstanceLock {
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

    func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        RuntimeLogResult(identity: service.identity, text: "", lineLimit: tail)
    }

    func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        executeCount += 1
        return RuntimeEvent(identity: action.identity, severity: .info, message: "unexpected", resourceIdentifier: nil)
    }
}

private final class ScriptedHealthChecker: RuntimeHealthChecking, @unchecked Sendable {
    struct Call {
        let identity: RuntimeServiceIdentity
        let spec: RuntimeHealthCheckSpec
    }

    private var results: [RuntimeHealthCheckResult]
    private(set) var calls: [Call] = []

    init(results: [RuntimeHealthCheckResult]) {
        self.results = results
    }

    func check(identity: RuntimeServiceIdentity, spec: RuntimeHealthCheckSpec) async -> RuntimeHealthCheckResult {
        calls.append(Call(identity: identity, spec: spec))
        if results.isEmpty {
            return RuntimeHealthCheckResult(
                identity: identity,
                status: .healthy,
                exitStatus: 0,
                timedOut: false,
                command: spec.command,
                standardOutput: "",
                standardError: ""
            )
        }
        return results.removeFirst()
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
