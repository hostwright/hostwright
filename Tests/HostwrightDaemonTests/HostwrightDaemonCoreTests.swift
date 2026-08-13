import Darwin
import CryptoKit
import Foundation
import Synchronization
import XCTest
@testable import HostwrightDaemonCore
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightObservability
@testable import HostwrightReconciler
@testable import HostwrightRuntime
@testable import HostwrightState

final class HostwrightDaemonCoreTests: XCTestCase {
    func testEachDaemonIterationPersistsOneCompleteBoundedCorrelatedTrace() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: CountingRuntimeAdapter(),
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in
                    """
                    version: 2
                    project: demo
                    services:
                      api:
                        image: ghcr.io/example/api:latest
                    """
                },
                idGenerator: DeterministicIDs().next
            )

            let summary = try await runner.run()
            XCTAssertEqual(summary.iterations, 1)
            let page = try SQLiteStateStore(path: databasePath).traces.inspect(limit: 10)
            XCTAssertEqual(page.retainedTraceCount, 1)
            let trace = try XCTUnwrap(page.traces.first)
            XCTAssertTrue(trace.complete)
            XCTAssertTrue(trace.spans.contains { $0.name == .daemonReconciliation })
            XCTAssertEqual(trace.status, summary.failedIterations == 0 ? .succeeded : .failed)
            XCTAssertLessThanOrEqual(trace.spanCount, HostwrightTraceContract.maximumSpans)
            XCTAssertFalse(trace.eventIDs.isEmpty)
            XCTAssertFalse(trace.operationIDs.isEmpty)
        }
    }

    func testDaemonStartupWaitsForStateAccessFenceContention() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try store.configuration.prepareStateAccessFoundation()
            let lockPath = try store.configuration.maintenancePaths().accessLockPath
            let descriptor = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            let release = Task.detached {
                try? await Task.sleep(for: .milliseconds(400))
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
            }

            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: CountingRuntimeAdapter(),
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in
                    """
                    version: 2
                    project: demo
                    services:
                      api:
                        image: ghcr.io/example/api:latest
                    """
                },
                idGenerator: DeterministicIDs().next
            )

            let summary: DaemonRunSummary
            do {
                summary = try await runner.run()
            } catch {
                await release.value
                throw error
            }
            await release.value
            XCTAssertEqual(summary.iterations, 1)
            XCTAssertEqual(summary.successfulIterations, 1)
            XCTAssertEqual(summary.failedIterations, 0)
        }
    }

    func testDaemonIterationWaitsForLifecycleMutationFenceBeforeStateWrites() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try store.configuration.prepareStateAccessFoundation()
            let lockPath = try store.configuration.maintenancePaths().accessLockPath + ".lifecycle-mutation"
            let descriptor = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            let release = Task.detached {
                try? await Task.sleep(for: .milliseconds(400))
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
            }

            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: CountingRuntimeAdapter(),
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in
                    """
                    version: 2
                    project: demo
                    services:
                      api:
                        image: ghcr.io/example/api:latest
                    """
                },
                idGenerator: DeterministicIDs().next
            )

            let startedAt = Date()
            let summary = try await runner.run()
            await release.value
            XCTAssertEqual(summary.successfulIterations, 1)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.300)
        }
    }

    func testMaintenanceClassifiesEveryUnattendedUpdateDriftBeforeLifecycleAdmission() {
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
        let plan = ReconciliationPlan(
            projectName: "demo",
            observationConnected: true,
            issues: [],
            drift: [],
            actions: [
                PlannedAction(
                    kind: .replaceForImageDrift,
                    identity: identity,
                    resourceIdentifier: identity.managedResourceIdentifier,
                    reason: "image",
                    driftKind: .imageMismatch
                ),
                PlannedAction(
                    kind: .reconcilePortDrift,
                    identity: identity,
                    resourceIdentifier: identity.managedResourceIdentifier,
                    reason: "port",
                    driftKind: .portMismatch
                ),
                PlannedAction(
                    kind: .reconcileMountDrift,
                    identity: identity,
                    resourceIdentifier: identity.managedResourceIdentifier,
                    reason: "mount",
                    driftKind: .mountMismatch
                )
            ]
        )

        XCTAssertEqual(DaemonLoopRunner.maintenanceActionClasses(plan: plan), [.update])
    }

    func testMaintenanceAdmissionBindingIsVersionedAndStrict() throws {
        let binding = try DaemonMaintenanceAdmission(
            reconciliationPlanSHA256: String(repeating: "a", count: 64),
            policySHA256: String(repeating: "b", count: 64),
            actionClasses: ["create", "start"],
            reason: "active-window",
            confirmationToken: nil,
            windowID: "weekly",
            windowStartsAt: "2026-08-02T04:00:00Z",
            windowEndsAt: "2026-08-02T05:00:00Z"
        )
        XCTAssertEqual(binding.schemaVersion, 1)
        XCTAssertThrowsError(try DaemonMaintenanceAdmission(
            reconciliationPlanSHA256: String(repeating: "a", count: 64),
            policySHA256: String(repeating: "b", count: 64),
            actionClasses: ["recovery"],
            reason: "active-window",
            confirmationToken: nil,
            windowID: nil,
            windowStartsAt: nil,
            windowEndsAt: nil
        ))
        XCTAssertThrowsError(try DaemonMaintenanceAdmission(
            reconciliationPlanSHA256: String(repeating: "a", count: 64),
            policySHA256: String(repeating: "b", count: 64),
            actionClasses: ["create"],
            reason: "active-window",
            confirmationToken: nil,
            windowID: "weekly",
            windowStartsAt: "2026-08-02T04:00:00.000Z",
            windowEndsAt: "2026-08-02T05:00:00Z"
        ))
        XCTAssertThrowsError(try DaemonMaintenanceAdmission(
            reconciliationPlanSHA256: String(repeating: "a", count: 64),
            policySHA256: String(repeating: "b", count: 64),
            actionClasses: ["update"],
            reason: "safety-recovery",
            confirmationToken: nil,
            windowID: nil,
            windowStartsAt: nil,
            windowEndsAt: nil
        ))
    }

    func testMaintenanceOutsideWindowPersistsDeferralWithoutCallingLifecycleDriver() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let driver = ScriptedDaemonReconciliationDriver()
            let manifest = """
            version: 2
            project: demo
            maintenance:
              timezone: UTC
              maximumDeferral: 3600s
              windows:
                - id: future
                  actions:
                    - create
                  oneShot:
                    startsAt: "2027-01-01T00:00:00Z"
                    duration: 3600s
            services:
              api:
                image: ghcr.io/example/api:latest
            """
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: CountingRuntimeAdapter(),
                reconciliationDriver: driver,
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in manifest },
                idGenerator: DeterministicIDs().next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.successfulIterations, 1)
            XCTAssertTrue(driver.requests.isEmpty)
            let store = SQLiteStateStore(path: databasePath)
            let pending = try XCTUnwrap(store.maintenanceDeferrals.latest(projectID: "project-demo"))
            XCTAssertEqual(pending.state, .deferred)
            XCTAssertEqual(pending.actionClasses, [.create])
            XCTAssertTrue(try store.events.loadAll().contains {
                $0.type == DaemonReconciliationReasonCode.maintenanceDeferred.rawValue
            })
            XCTAssertEqual(try store.restartAttempts.loadProject("project-demo").count, 0)
        }
    }

    func testMaintenanceActiveWindowPassesExactAdmissionToLifecycleDriver() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let driver = ScriptedDaemonReconciliationDriver()
            let manifest = """
            version: 2
            project: demo
            maintenance:
              timezone: UTC
              windows:
                - id: live
                  actions:
                    - create
                  oneShot:
                    startsAt: "2026-07-07T00:00:00Z"
                    duration: 3600s
            services:
              api:
                image: ghcr.io/example/api:latest
            """
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: CountingRuntimeAdapter(),
                reconciliationDriver: driver,
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in manifest },
                idGenerator: DeterministicIDs().next
            )

            _ = try await runner.run()

            let request = try XCTUnwrap(driver.requests.first)
            let binding = try XCTUnwrap(request.maintenanceAdmission)
            XCTAssertEqual(binding.reason, "active-window")
            XCTAssertEqual(binding.actionClasses, ["create"])
            XCTAssertEqual(binding.windowID, "live")
        }
    }

    func testUnattendedReconciliationContractIsVersionedAndBounded() throws {
        let request = try DaemonReconciliationRequest(
            manifestPath: "/private/tmp/hostwright.yaml",
            manifestSHA256: String(repeating: "a", count: 64),
            stateDatabasePath: "/private/tmp/state.sqlite",
            projectID: "project-demo",
            maximumParallelism: 4
        )

        XCTAssertEqual(request.schemaVersion, 1)
        XCTAssertEqual(request.maximumParallelism, 4)
        XCTAssertThrowsError(
            try DaemonReconciliationRequest(
                manifestPath: "/private/tmp/hostwright.yaml",
                manifestSHA256: "not-a-digest",
                stateDatabasePath: "/private/tmp/state.sqlite",
                projectID: "project-demo",
                maximumParallelism: 4
            )
        )
        XCTAssertThrowsError(
            try DaemonReconciliationRequest(
                manifestPath: "/private/tmp/hostwright.yaml",
                manifestSHA256: String(repeating: "a", count: 64),
                stateDatabasePath: "/private/tmp/state.sqlite",
                projectID: "project-demo",
                maximumParallelism: 33
            )
        )
        XCTAssertThrowsError(
            try DaemonReconciliationRequest(
                manifestPath: "/private/tmp/hostwright.yaml",
                manifestSHA256: String(repeating: "a", count: 64),
                stateDatabasePath: "/private/tmp/state.sqlite",
                projectID: "project-demo",
                maximumParallelism: 4,
                operationIdempotencyKeySHA256: "not-a-digest"
            )
        )
        XCTAssertThrowsError(
            try DaemonReconciliationResult(
                status: .mutated,
                reasonCode: .mutationVerified,
                planSHA256: String(repeating: "b", count: 64),
                nodeCount: 1,
                completedNodeCount: 1,
                runtimeMutationAttempted: true,
                operationID: HostwrightResourceUUID.generate(),
                groupID: HostwrightResourceUUID.generate(),
                checkpoint: "verified"
            )
        )
        let managed = DaemonConfiguration(
            mode: .managedService,
            configPath: "/private/tmp/hostwright.yaml",
            stateDatabasePath: "/private/tmp/state.sqlite"
        )
        XCTAssertEqual(managed.cadenceSeconds, 5)
        XCTAssertEqual(managed.jitterSeconds, 0)
        XCTAssertThrowsError(
            try DaemonConfiguration(
                mode: .managedService,
                configPath: "/private/tmp/hostwright.yaml",
                stateDatabasePath: "/private/tmp/state.sqlite",
                cadenceSeconds: 5,
                jitterSeconds: 1
            ).validate()
        )
    }

    func testLevelTriggeredLoopInvokesSharedMutationDriverAndPersistsVerifiedResult() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let driver = ScriptedDaemonReconciliationDriver(results: [
                .success(
                    try DaemonReconciliationResult(
                        status: .mutated,
                        reasonCode: .mutationVerified,
                        planSHA256: String(repeating: "c", count: 64),
                        nodeCount: 2,
                        completedNodeCount: 2,
                        runtimeMutationAttempted: true,
                        attemptedServiceNames: ["api"],
                        operationID: HostwrightResourceUUID.generate(),
                        groupID: HostwrightResourceUUID.generate(),
                        checkpoint: "verified"
                    )
                )
            ])
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: CountingRuntimeAdapter(),
                reconciliationDriver: driver,
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in Self.singleServiceManifest },
                idGenerator: DeterministicIDs().next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.successfulIterations, 1)
            XCTAssertEqual(driver.requests.count, 1)
            XCTAssertEqual(driver.requests[0].projectID, "project-demo")
            XCTAssertEqual(driver.requests[0].maximumParallelism, 4)
            XCTAssertEqual(driver.requests[0].manifestSHA256.count, 64)
            let store = SQLiteStateStore(path: databasePath)
            XCTAssertTrue(
                try store.events.loadAll().contains {
                    $0.type == "daemon.reconcile.mutated"
                }
            )
            let operation = try XCTUnwrap(
                try store.operations.loadAll().first {
                    $0.plannedActionType == "daemon.reconcile"
                }
            )
            XCTAssertEqual(operation.status, .succeeded)
            XCTAssertTrue(operation.payloadJSONRedacted.contains(#""completedNodes":2"#))
            XCTAssertTrue(operation.payloadJSONRedacted.contains(#""mutationAttempted":true"#))
        }
    }

    func testPhase08AdmittedDaemonRestartConsumesOneDurableAttempt() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let operationID = HostwrightResourceUUID.generate()
            let driver = ScriptedDaemonReconciliationDriver(results: [
                .success(
                    try DaemonReconciliationResult(
                        status: .mutated,
                        reasonCode: .mutationVerified,
                        planSHA256: String(repeating: "c", count: 64),
                        nodeCount: 1,
                        completedNodeCount: 1,
                        runtimeMutationAttempted: true,
                        attemptedServiceNames: ["api"],
                        operationID: operationID,
                        groupID: HostwrightResourceUUID.generate(),
                        checkpoint: "verified"
                    )
                )
            ])
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: CountingRuntimeAdapter(observedServices: [
                    Self.observedService(lifecycleState: .exited, healthState: .unknown)
                ]),
                reconciliationDriver: driver,
                healthChecker: ScriptedHealthChecker(results: []),
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in Self.healthRestartManifest },
                idGenerator: DeterministicIDs().next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.successfulIterations, 1)
            let store = SQLiteStateStore(path: databasePath)
            let state = try XCTUnwrap(
                store.restartPolicies.load(projectID: "project-demo", serviceName: "api")
            )
            XCTAssertEqual(state.status, .backingOff)
            XCTAssertEqual(state.attemptCount, 1)
            XCTAssertEqual(state.reasonClass, .processExit)
            let attempts = try store.restartAttempts.loadProject("project-demo")
            XCTAssertEqual(attempts.count, 1)
            XCTAssertEqual(attempts[0].decision, .admitted)
            XCTAssertEqual(attempts[0].operationID, operationID)
            XCTAssertEqual(try store.restartAttempts.admittedCount(
                projectID: "project-demo",
                since: "2026-01-01T00:00:00Z"
            ), 1)
        }
    }

    func testPhase08OnlyExactStartedRestartServiceConsumesBudget() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let manifest = """
            version: 2
            project: demo
            services:
              api:
                image: ghcr.io/example/api:latest
                restart:
                  policy: on-failure
              worker:
                image: ghcr.io/example/api:latest
                restart:
                  policy: on-failure
            """
            let driver = ScriptedDaemonReconciliationDriver(results: [
                .success(
                    try DaemonReconciliationResult(
                        status: .mutated,
                        reasonCode: .mutationVerified,
                        planSHA256: String(repeating: "c", count: 64),
                        nodeCount: 1,
                        completedNodeCount: 1,
                        runtimeMutationAttempted: true,
                        attemptedServiceNames: ["api"],
                        operationID: HostwrightResourceUUID.generate(),
                        groupID: HostwrightResourceUUID.generate(),
                        checkpoint: "verified"
                    )
                )
            ])
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: CountingRuntimeAdapter(observedServices: [
                    Self.observedService(
                        serviceName: "api",
                        lifecycleState: .exited,
                        healthState: .unknown,
                        ports: []
                    ),
                    Self.observedService(
                        serviceName: "worker",
                        lifecycleState: .exited,
                        healthState: .unknown,
                        ports: []
                    )
                ]),
                reconciliationDriver: driver,
                healthChecker: ScriptedHealthChecker(results: []),
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in manifest },
                idGenerator: DeterministicIDs().next
            )

            _ = try await runner.run()

            let store = SQLiteStateStore(path: databasePath)
            XCTAssertEqual(
                try store.restartAttempts.loadProject("project-demo").map(\.serviceName),
                ["api"]
            )
            XCTAssertEqual(
                try store.restartPolicies.load(
                    projectID: "project-demo",
                    serviceName: "api"
                )?.attemptCount,
                1
            )
            XCTAssertEqual(
                try store.restartPolicies.load(
                    projectID: "project-demo",
                    serviceName: "worker"
                )?.attemptCount,
                0
            )
        }
    }

    func testPhase08PostAdmissionInterruptionConsumesFailedUnknownAttempt() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let operationID = HostwrightResourceUUID.generate()
            let driver = ScriptedDaemonReconciliationDriver(results: [
                .success(
                    try DaemonReconciliationResult(
                        status: .interrupted,
                        reasonCode: .interrupted,
                        planSHA256: String(repeating: "d", count: 64),
                        nodeCount: 1,
                        completedNodeCount: 0,
                        runtimeMutationAttempted: true,
                        attemptedServiceNames: ["api"],
                        operationID: operationID,
                        groupID: HostwrightResourceUUID.generate(),
                        checkpoint: "effect-ambiguous"
                    )
                )
            ])
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: CountingRuntimeAdapter(observedServices: [
                    Self.observedService(lifecycleState: .exited, healthState: .unknown)
                ]),
                reconciliationDriver: driver,
                healthChecker: ScriptedHealthChecker(results: []),
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in Self.healthRestartManifest },
                idGenerator: DeterministicIDs().next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.successfulIterations, 0)
            XCTAssertEqual(summary.failedIterations, 1)
            let store = SQLiteStateStore(path: databasePath)
            let state = try XCTUnwrap(
                store.restartPolicies.load(projectID: "project-demo", serviceName: "api")
            )
            XCTAssertEqual(state.attemptCount, 1)
            XCTAssertEqual(state.reasonClass, .unknown)
            let attempts = try store.restartAttempts.loadProject("project-demo")
            XCTAssertEqual(attempts.count, 1)
            XCTAssertEqual(attempts[0].decision, .failed)
            XCTAssertEqual(attempts[0].reasonClass, .unknown)
            XCTAssertEqual(attempts[0].operationID, operationID)
        }
    }

    func testPhase08FreshDaemonRestartAttemptsAdvanceExecutionIdentityAndFence() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let ids = DeterministicIDs()
            let driver = ScriptedDaemonReconciliationDriver(results: try ["e", "f"].map {
                .success(
                    try DaemonReconciliationResult(
                        status: .mutated,
                        reasonCode: .mutationVerified,
                        planSHA256: String(repeating: $0, count: 64),
                        nodeCount: 1,
                        completedNodeCount: 1,
                        runtimeMutationAttempted: true,
                        attemptedServiceNames: ["api"],
                        operationID: HostwrightResourceUUID.generate(),
                        groupID: HostwrightResourceUUID.generate(),
                        checkpoint: "verified"
                    )
                )
            })
            for timestamp in ["2026-08-01T12:00:00Z", "2026-08-01T12:01:01Z"] {
                let runner = DaemonLoopRunner(
                    configuration: DaemonConfiguration(
                        configPath: "hostwright.yaml",
                        stateDatabasePath: databasePath,
                        maxIterations: 1
                    ),
                    runtimeAdapter: CountingRuntimeAdapter(observedServices: [
                        Self.observedService(lifecycleState: .exited, healthState: .unknown)
                    ]),
                    reconciliationDriver: driver,
                    healthChecker: ScriptedHealthChecker(results: []),
                    clock: ManualDaemonClock(timestamps: Array(
                        repeating: timestamp,
                        count: 3
                    )),
                    instanceLock: ScriptedDaemonLock(),
                    readConfig: { _ in Self.healthRestartManifest },
                    idGenerator: ids.next
                )
                let summary = try await runner.run()
                XCTAssertEqual(summary.successfulIterations, 1)
            }

            let keys = driver.requests.compactMap(\.operationIdempotencyKeySHA256)
            XCTAssertEqual(keys.count, 2)
            XCTAssertEqual(Set(keys).count, 2)
            XCTAssertTrue(keys.allSatisfy {
                $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
            })
            XCTAssertEqual(
                try SQLiteStateStore(path: databasePath)
                    .restartAttempts.loadProject("project-demo").map(\.attemptNumber),
                [1, 2]
            )
        }
    }

    func testPhase08StableRunResetSurvivesFreshDaemonProcessesAndRecordsHistory() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let ids = DeterministicIDs()
            let first = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: CountingRuntimeAdapter(observedServices: [
                    Self.observedService(lifecycleState: .exited, healthState: .unknown)
                ]),
                reconciliationDriver: ScriptedDaemonReconciliationDriver(results: [
                    .success(try DaemonReconciliationResult(
                        status: .mutated,
                        reasonCode: .mutationVerified,
                        planSHA256: String(repeating: "c", count: 64),
                        nodeCount: 1,
                        completedNodeCount: 1,
                        runtimeMutationAttempted: true,
                        attemptedServiceNames: ["api"],
                        operationID: HostwrightResourceUUID.generate(),
                        groupID: HostwrightResourceUUID.generate(),
                        checkpoint: "verified"
                    ))
                ]),
                healthChecker: ScriptedHealthChecker(results: []),
                clock: ManualDaemonClock(timestamps: Array(
                    repeating: "2026-08-01T12:00:00Z",
                    count: 3
                )),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in Self.healthRestartManifest },
                idGenerator: ids.next
            )
            _ = try await first.run()

            for timestamp in ["2026-08-01T12:00:20Z", "2026-08-01T12:01:21Z"] {
                let runner = DaemonLoopRunner(
                    configuration: DaemonConfiguration(
                        configPath: "hostwright.yaml",
                        stateDatabasePath: databasePath,
                        maxIterations: 1
                    ),
                    runtimeAdapter: CountingRuntimeAdapter(observedServices: [
                        Self.observedService(lifecycleState: .running, healthState: .healthy)
                    ]),
                    reconciliationDriver: ScriptedDaemonReconciliationDriver(),
                    healthChecker: ScriptedHealthChecker(results: []),
                    clock: ManualDaemonClock(timestamps: Array(
                        repeating: timestamp,
                        count: 3
                    )),
                    instanceLock: ScriptedDaemonLock(),
                    readConfig: { _ in Self.healthRestartManifest },
                    idGenerator: ids.next
                )
                _ = try await runner.run()
            }

            let store = SQLiteStateStore(path: databasePath)
            let state = try XCTUnwrap(
                store.restartPolicies.load(projectID: "project-demo", serviceName: "api")
            )
            XCTAssertEqual(state.status, .active)
            XCTAssertEqual(state.attemptCount, 0)
            XCTAssertNil(state.stableSince)
            XCTAssertEqual(
                try store.restartAttempts.loadProject("project-demo").map(\.decision),
                [.admitted, .stableReset]
            )
        }
    }

    func testPhase08HeldWorkloadDoesNotStarveIndependentProjectMutation() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let manifestText = """
            version: 2
            project: demo
            restartBudget:
              maxAttempts: 1
              window: 300s
            services:
              api:
                image: ghcr.io/example/api:latest
                restart:
                  policy: on-failure
                  priority: 100
              worker:
                image: ghcr.io/example/worker:latest
            """
            let manifest = try ManifestValidator.validated(manifestText)
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try store.desiredStates.saveManifestSnapshot(
                projectID: "project-demo",
                manifestPath: "hostwright.yaml",
                manifestHash: "seed",
                desiredGeneration: 1,
                manifest: manifest,
                timestamp: "2026-08-01T12:00:00Z"
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
                    holdToken: String(repeating: "a", count: 64),
                    updatedAt: "2026-08-01T12:00:00Z",
                    metadataJSONRedacted: "{}"
                )
            )
            let driver = ScriptedDaemonReconciliationDriver()
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: CountingRuntimeAdapter(observedServices: [
                    Self.observedService(lifecycleState: .exited, healthState: .unknown)
                ]),
                reconciliationDriver: driver,
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in manifestText },
                idGenerator: DeterministicIDs().next
            )

            _ = try await runner.run()

            XCTAssertEqual(driver.requests.first?.selectedServiceNames, ["worker"])
            XCTAssertEqual(
                try store.restartPolicies.load(projectID: "project-demo", serviceName: "api")?.status,
                .crashLoopBlocked
            )
        }
    }

    func testSafeHoldIsNotReportedAsConvergenceAndBacksOff() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let driver = ScriptedDaemonReconciliationDriver(results: [
                .success(
                    try DaemonReconciliationResult(
                        status: .safeHold,
                        reasonCode: .safeHold,
                        planSHA256: String(repeating: "d", count: 64),
                        nodeCount: 2,
                        completedNodeCount: 1,
                        runtimeMutationAttempted: true,
                        attemptedServiceNames: ["api"],
                        operationID: HostwrightResourceUUID.generate(),
                        groupID: HostwrightResourceUUID.generate(),
                        checkpoint: "start-api:ambiguous-after-effect",
                        recoveryHintRedacted: "inspect token=fake-secret"
                    )
                )
            ])
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: CountingRuntimeAdapter(),
                reconciliationDriver: driver,
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in Self.singleServiceManifest },
                idGenerator: DeterministicIDs().next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.failedIterations, 1)
            let store = SQLiteStateStore(path: databasePath)
            XCTAssertTrue(
                try store.events.loadAll().contains {
                    $0.type == "daemon.reconcile.safe-hold"
                }
            )
            let operation = try XCTUnwrap(
                try store.operations.loadAll().first {
                    $0.plannedActionType == "daemon.reconcile"
                }
            )
            XCTAssertEqual(operation.status, .failed)
            XCTAssertFalse(operation.payloadJSONRedacted.contains("fake-secret"))
        }
    }

    func testHealthyLevelTriggerRechecksWithoutAnEventEdgeWithinFiveSeconds() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let driver = ScriptedDaemonReconciliationDriver()
            let clock = ManualDaemonClock()
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 2
                ),
                runtimeAdapter: CountingRuntimeAdapter(
                    observedServices: [Self.observedService()]
                ),
                reconciliationDriver: driver,
                clock: clock,
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in Self.singleServiceManifest },
                idGenerator: DeterministicIDs().next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.successfulIterations, 2)
            XCTAssertEqual(driver.requests.count, 2)
            XCTAssertEqual(clock.sleepDurations, [5])
            let restartEvents = try SQLiteStateStore(path: databasePath).events.loadAll().filter {
                $0.type == "restart.policy.state"
            }
            XCTAssertEqual(restartEvents.count, 1)
        }
    }

    func testDriverFailurePreservesUncertainMutationEvidenceAndUsesBoundedBackoff() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let driver = ScriptedDaemonReconciliationDriver(results: [
                .failure(
                    RuntimeAdapterError.runtimeUnavailable(
                        "ambiguous provider response token=fake-secret"
                    )
                ),
                .failure(
                    RuntimeAdapterError.runtimeUnavailable(
                        "ambiguous provider response token=fake-secret"
                    )
                )
            ])
            let clock = ManualDaemonClock()
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    cadenceSeconds: 4,
                    jitterSeconds: 1,
                    maxBackoffSeconds: 20,
                    maxIterations: 2
                ),
                runtimeAdapter: CountingRuntimeAdapter(),
                reconciliationDriver: driver,
                clock: clock,
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in Self.singleServiceManifest },
                idGenerator: DeterministicIDs().next,
                jitterProvider: { _, _ in 1 }
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.failedIterations, 2)
            XCTAssertEqual(driver.requests.count, 2)
            XCTAssertEqual(clock.sleepDurations, [5])
            let store = SQLiteStateStore(path: databasePath)
            let failures = try store.events.loadAll().filter {
                $0.type == "daemon.reconcile.failed"
            }
            XCTAssertEqual(failures.count, 2)
            XCTAssertTrue(
                failures.allSatisfy {
                    $0.payloadJSONRedacted.contains("inspect-lifecycle-ledger")
                }
            )
            XCTAssertFalse(
                failures.map(\.message).joined().contains("fake-secret")
            )
        }
    }

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
            "--interval", "4",
            "--jitter", "1",
            "--max-backoff", "60",
            "--max-iterations", "2"
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("Expected run command.")
        }
        XCTAssertEqual(configuration.configPath, "hostwright.yaml")
        XCTAssertEqual(configuration.stateDatabasePath, "/tmp/hostwright.sqlite")
        XCTAssertEqual(configuration.cadenceSeconds, 4)
        XCTAssertEqual(configuration.jitterSeconds, 1)
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
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
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
                    .contains { $0.type == "daemon.reconcile.converged" }
            )
        }
    }

    func testForegroundLoopRecordsLevelTriggeredConvergence() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let adapter = CountingRuntimeAdapter(observedServices: [Self.observedService()])
            let clock = ManualDaemonClock()
            let lock = ScriptedDaemonLock()
            let ids = DeterministicIDs()
            let configuration = DaemonConfiguration(
                configPath: "hostwright.yaml",
                stateDatabasePath: databasePath,
                cadenceSeconds: 5,
                jitterSeconds: 0,
                maxBackoffSeconds: 60,
                maxIterations: 1
            )
            let runner = DaemonLoopRunner(
                configuration: configuration,
                runtimeAdapter: adapter,
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
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
            XCTAssertTrue(events.contains { $0.type == "daemon.reconcile.converged" && $0.message.contains("observed-converged") == false })
            XCTAssertTrue(events.contains { $0.type == "daemon.stopped" })

            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations.filter { $0.plannedActionType == "daemon.reconcile" }.map(\.status), [.succeeded])
            let reconciliation = try XCTUnwrap(
                operations.first { $0.plannedActionType == "daemon.reconcile" }
            )
            let evidence = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(reconciliation.payloadJSONRedacted.utf8)
                ) as? [String: Any]
            )
            XCTAssertGreaterThanOrEqual(
                try XCTUnwrap(evidence["durationMilliseconds"] as? Int),
                0
            )
            XCTAssertNotEqual(reconciliation.createdAt, reconciliation.updatedAt)
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
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
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
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
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
            let driver = ScriptedDaemonReconciliationDriver()
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 1
                ),
                runtimeAdapter: adapter,
                reconciliationDriver: driver,
                healthChecker: ScriptedHealthChecker(results: []),
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in Self.healthRestartManifest },
                idGenerator: DeterministicIDs().next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.successfulIterations, 1)
            XCTAssertEqual(adapter.executeCount, 0)
            XCTAssertEqual(driver.requests.first?.selectedServiceNames, [])
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
                cadenceSeconds: 3,
                jitterSeconds: 2,
                maxBackoffSeconds: 60,
                maxIterations: 3
            )
            let runner = DaemonLoopRunner(
                configuration: configuration,
                runtimeAdapter: adapter,
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
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
            XCTAssertEqual(clock.sleepDurations, [5, 8])

            let store = SQLiteStateStore(path: databasePath)
            let events = try store.events.loadAll()
            XCTAssertEqual(events.filter { $0.type == "daemon.backoff" }.count, 2)
            XCTAssertEqual(events.filter { $0.type == "daemon.reconcile.failed" }.count, 3)
            XCTAssertFalse(events.map(\.message).joined(separator: "\n").contains("fake-secret"))
            XCTAssertEqual(try store.operations.loadAll().filter { $0.plannedActionType == "daemon.reconcile" }.map(\.status), [.failed, .failed, .failed])
        }
    }

    func testTransientStateAccessContentionBacksOffAndResumesWithoutExiting() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            let coordinator = StateAccessCoordinator(configuration: store.configuration)
            let lockAcquired = DispatchSemaphore(value: 0)
            let releaseFence = DispatchSemaphore(value: 0)
            let fenceReleased = DispatchSemaphore(value: 0)
            let backgroundFailure = Mutex<String?>(nil)
            let shouldArmContention = Mutex(true)
            let releaseCompleted = Mutex(false)
            defer {
                releaseFence.signal()
            }

            let clock = HookedDaemonClock {
                releaseFence.signal()
                let completed = fenceReleased.wait(timeout: .now() + 2) == .success
                releaseCompleted.withLock { $0 = completed }
            }
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "hostwright.yaml",
                    stateDatabasePath: databasePath,
                    cadenceSeconds: 1,
                    maxBackoffSeconds: 2,
                    maxIterations: 2
                ),
                runtimeAdapter: CountingRuntimeAdapter(),
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
                clock: clock,
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in
                    let arm = shouldArmContention.withLock { value in
                        defer { value = false }
                        return value
                    }
                    if arm {
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                try coordinator.withExclusiveLifecycleFence {
                                    lockAcquired.signal()
                                    guard releaseFence.wait(timeout: .now() + 5) == .success else {
                                        throw StateStoreError.databaseLocked(
                                            path: databasePath,
                                            message: "the test maintenance release deadline expired"
                                        )
                                    }
                                }
                            } catch {
                                backgroundFailure.withLock { $0 = String(describing: error) }
                            }
                            fenceReleased.signal()
                        }
                        guard lockAcquired.wait(timeout: .now() + 2) == .success else {
                            throw StateStoreError.databaseLocked(
                                path: databasePath,
                                message: "the test maintenance fence was not acquired"
                            )
                        }
                    }
                    return Self.singleServiceManifest
                },
                idGenerator: DeterministicIDs().next
            )

            let summary = try await runner.run()

            XCTAssertTrue(releaseCompleted.withLock { $0 })
            XCTAssertNil(backgroundFailure.withLock { $0 })
            XCTAssertEqual(summary.iterations, 2)
            XCTAssertEqual(summary.failedIterations, 1)
            XCTAssertEqual(summary.successfulIterations, 1)
            XCTAssertEqual(clock.sleepDurations, [1])
            let events = try store.events.loadAll()
            let recovery = try XCTUnwrap(events.first {
                $0.type == "daemon.backoff" && $0.message.contains("state-access contention")
            })
            XCTAssertFalse(recovery.message.contains(databasePath))
            XCTAssertEqual(
                try store.operations.loadAll().filter { $0.plannedActionType == "daemon.reconcile" }.count,
                1
            )
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
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in "version: 2\nproject: demo\nservices: {}\n" },
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
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
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

    func testInvalidReloadIsRejectedOnceAndRetainsLastGoodDesiredState() async throws {
        try await withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            let manifest = try ManifestValidator.validated(Self.singleServiceManifest)
            let manifestHash = SHA256.hash(data: Data(Self.singleServiceManifest.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            try store.desiredStates.saveManifestSnapshot(
                projectID: "project-demo",
                manifestPath: "/private/tmp/hostwright.yaml",
                manifestHash: manifestHash,
                desiredGeneration: 1,
                manifest: manifest,
                timestamp: "2026-08-01T00:00:00Z"
            )
            var reads = 0
            let driver = ScriptedDaemonReconciliationDriver(results: [
                .success(
                    try DaemonReconciliationResult(
                        status: .converged,
                        reasonCode: .converged,
                        planSHA256: String(repeating: "c", count: 64),
                        nodeCount: 0,
                        completedNodeCount: 0,
                        runtimeMutationAttempted: false,
                        checkpoint: "observed-converged"
                    )
                )
            ])
            let runner = DaemonLoopRunner(
                configuration: DaemonConfiguration(
                    configPath: "/private/tmp/hostwright.yaml",
                    stateDatabasePath: databasePath,
                    maxIterations: 3
                ),
                runtimeAdapter: CountingRuntimeAdapter(
                    observedServices: [Self.observedService()]
                ),
                reconciliationDriver: driver,
                clock: ManualDaemonClock(),
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in
                    defer { reads += 1 }
                    return reads == 0
                        ? Self.singleServiceManifest
                        : "version: 2\nproject: demo\nservices: {}\n"
                },
                idGenerator: DeterministicIDs().next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.successfulIterations, 1)
            XCTAssertEqual(summary.failedIterations, 2)
            XCTAssertEqual(driver.requests.count, 1)
            let events = try store.events.loadAll()
            XCTAssertEqual(events.filter { $0.type == "daemon.configuration.accepted" }.count, 1)
            XCTAssertEqual(events.filter { $0.type == "daemon.configuration.rejected" }.count, 1)
            let retained = try store.desiredStates.loadProject(id: "project-demo")
            XCTAssertEqual(retained.manifestHash, manifestHash)
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
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
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
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
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
                    cadenceSeconds: 5,
                    jitterSeconds: 0,
                    maxBackoffSeconds: 30,
                    maxIterations: 2
                ),
                runtimeAdapter: CountingRuntimeAdapter(observedServices: [Self.observedService()]),
                reconciliationDriver: ScriptedDaemonReconciliationDriver(),
                clock: clock,
                instanceLock: ScriptedDaemonLock(),
                readConfig: { _ in Self.singleServiceManifest },
                idGenerator: ids.next
            )

            let summary = try await runner.run()

            XCTAssertEqual(summary.iterations, 2)
            XCTAssertEqual(clock.sleepDurations, [5])
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
        serviceName: String = "api",
        lifecycleState: RuntimeLifecycleState = .running,
        healthState: RuntimeHealthState = .healthy,
        resourceIdentifier: String? = nil,
        networks: [RuntimeNetworkAttachment] = [],
        ports: [RuntimePortMapping]? = nil
    ) -> ObservedRuntimeService {
        let identity = RuntimeServiceIdentity(
            projectName: "demo",
            serviceName: serviceName
        )
        return ObservedRuntimeService(
            identity: identity,
            resourceIdentifier: resourceIdentifier ?? identity.managedResourceIdentifier,
            image: "ghcr.io/example/api:latest",
            lifecycleState: lifecycleState,
            healthState: healthState,
            ports: ports ?? [RuntimePortMapping(hostPort: 8080, containerPort: 8080, bindAddress: "127.0.0.1")],
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

private final class HookedDaemonClock: DaemonClock {
    private let onFirstSleep: () -> Void
    private var firstSleepPending = true
    private(set) var sleepDurations: [Int] = []

    init(onFirstSleep: @escaping () -> Void) {
        self.onFirstSleep = onFirstSleep
    }

    func timestamp() -> String {
        "2026-07-07T00:00:00Z"
    }

    func sleep(seconds: Int) async throws -> DaemonWakeReason {
        sleepDurations.append(seconds)
        if firstSleepPending {
            firstSleepPending = false
            onFirstSleep()
        }
        return .scheduled
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
            providerID: .appleContainerCLI,
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

private final class ScriptedDaemonReconciliationDriver: DaemonReconciliationDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [DaemonReconciliationRequest] = []
    private var storedResults: [Result<DaemonReconciliationResult, Error>]

    init(results: [Result<DaemonReconciliationResult, Error>] = []) {
        self.storedResults = results
    }

    var requests: [DaemonReconciliationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func reconcile(
        request: DaemonReconciliationRequest
    ) async throws -> DaemonReconciliationResult {
        let result = lock.withLock {
            storedRequests.append(request)
            return storedResults.isEmpty ? nil : storedResults.removeFirst()
        }
        let store = SQLiteStateStore(path: request.stateDatabasePath)
        try store.migrate()
        try store.desiredStates.saveManifestSnapshot(
            projectID: request.projectID,
            manifestPath: request.manifestPath,
            manifestHash: request.manifestSHA256,
            desiredGeneration: 1,
            manifest: HostwrightManifest(
                project: "demo",
                services: [
                    HostwrightService(
                        name: "api",
                        image: "ghcr.io/example/api:latest"
                    )
                ]
            ),
            timestamp: "2026-07-07T00:00:00Z",
            mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue
        )
        if let result {
            return try result.get()
        }
        return try DaemonReconciliationResult(
            status: .converged,
            reasonCode: .converged,
            planSHA256: String(repeating: "b", count: 64),
            nodeCount: 0,
            completedNodeCount: 0,
            runtimeMutationAttempted: false,
            checkpoint: "observed-converged"
        )
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
