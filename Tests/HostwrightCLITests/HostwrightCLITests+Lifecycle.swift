import Darwin
import Foundation
import HostwrightTestSupport
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightReconciler
@testable import HostwrightRuntime
@testable import HostwrightState

extension HostwrightCLITests {
    func testPhase08RestartBudgetStatusAndExactReleaseAreNonMutatingUntilConfirmed() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            let holdToken = String(repeating: "a", count: 64)
            try store.restartPolicies.upsert(
                RestartPolicyStateRecord(
                    id: "restart-api",
                    projectID: "project-demo",
                    serviceName: "api",
                    policy: .onFailure,
                    status: .crashLoopBlocked,
                    attemptCount: 3,
                    maxAttempts: 3,
                    holdToken: holdToken,
                    policySHA256: String(repeating: "b", count: 64),
                    updatedAt: "2026-08-01T12:00:00Z",
                    metadataJSONRedacted: "{}"
                )
            )

            let status = HostwrightCLI.run(arguments: [
                "restart-budget", "status", "--project", "project-demo",
                "--state-db", databasePath, "--json"
            ])
            XCTAssertEqual(status.exitCode, CLIExitCode.success.rawValue)
            XCTAssertEqual(try jsonObject(status.standardOutput)["released"] as? Bool, false)
            XCTAssertEqual(try store.restartAttempts.loadProject("project-demo"), [])

            let stale = HostwrightCLI.run(arguments: [
                "restart-budget", "release", "--project", "project-demo",
                "--service", "api", "--confirm-hold", String(repeating: "c", count: 64),
                "--state-db", databasePath, "--json"
            ])
            XCTAssertEqual(stale.exitCode, CLIExitCode.confirmationMismatch.rawValue)
            XCTAssertEqual(
                try store.restartPolicies.load(projectID: "project-demo", serviceName: "api")?.status,
                .crashLoopBlocked
            )
            XCTAssertEqual(try store.restartAttempts.loadProject("project-demo"), [])

            let released = HostwrightCLI.run(arguments: [
                "restart-budget", "release", "--project", "project-demo",
                "--service", "api", "--confirm-hold", holdToken,
                "--state-db", databasePath, "--json"
            ])
            XCTAssertEqual(released.exitCode, CLIExitCode.success.rawValue)
            XCTAssertEqual(try jsonObject(released.standardOutput)["released"] as? Bool, true)
            XCTAssertEqual(
                try store.restartPolicies.load(projectID: "project-demo", serviceName: "api")?.status,
                .active
            )
            XCTAssertEqual(try store.restartAttempts.loadProject("project-demo").map(\.decision), [.manualRelease])
            XCTAssertTrue(
                try store.events.contains(
                    type: "restart.policy.manual-release",
                    source: "hostwright-cli",
                    payloadContains: "\"releaseGeneration\":1"
                )
            )
        }
    }

    func testApplyRefusesWrongPlanHashBeforeMutation() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = ScriptedApplyRuntimeAdapter()

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", "wrong-hash"],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.confirmationMismatch.rawValue)
            XCTAssertTrue(result.standardError.contains("Confirmed plan hash does not match"))
            XCTAssertEqual(adapter.executedActions.count, 0)
        }
    }

    func testApplyBlocksBeforeCapabilityRevalidationWithoutCommittedSchedulerAuthority() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = ScriptedApplyRuntimeAdapter(
                capabilitySnapshots: [
                    ScriptedApplyRuntimeAdapter.testCapabilitySnapshot,
                    ScriptedApplyRuntimeAdapter.changedCapabilitySnapshot
                ]
            )
            let expectedHash = try planHash(for: singleServiceManifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            let store = SQLiteStateStore(path: databasePath)
            XCTAssertTrue(try store.operations.loadAll().isEmpty)
            XCTAssertTrue(try store.operationGroups.loadAll().isEmpty)
            XCTAssertTrue(
                try store.events.loadAll().allSatisfy {
                    $0.type == "trace.span.v1"
                }
            )
            XCTAssertTrue(try store.ownership.loadAll().isEmpty)
            XCTAssertNil(try store.observedStates.loadLatestSnapshot(
                projectID: "project-demo",
                providerID: .appleContainerCLI
            ))
            XCTAssertThrowsError(try store.desiredStates.loadProject(id: "project-demo"))
        }
    }

    func testApplyWithoutCommittedSchedulerAuthorityPersistsNoIntent() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = ScriptedApplyRuntimeAdapter()
            let expectedHash = try planHash(for: singleServiceManifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertFalse(result.standardOutput.contains(fakeSecret))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(adapter.confirmations.isEmpty)

            let store = SQLiteStateStore(path: databasePath)
            XCTAssertTrue(try store.operations.loadAll().isEmpty)
            XCTAssertTrue(try store.operationGroups.loadAll().isEmpty)
            XCTAssertTrue(try store.events.loadAll().allSatisfy {
                $0.type != "apply.create-intent-recorded" && $0.type != "apply.created-service"
            })
            XCTAssertTrue(try store.ownership.loadAll().isEmpty)
        }
    }

    func testApplyUsesSecureDefaultStateWithoutStateFlag() throws {
        try withCLITestDirectory(prefix: "hostwright-cli-xctest") { home in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = ScriptedApplyRuntimeAdapter()
            let expectedHash = try planHash(for: singleServiceManifest, observed: adapter.observedState)
            let resolution = try HostwrightLocalPathResolver.resolve(homeDirectory: home.path, environment: [:])

            let result = HostwrightCLI.run(
                arguments: ["apply", "--confirm-plan", expectedHash],
                environment: environment(
                    files: files,
                    runtimeAdapter: adapter,
                    localPathResolution: { explicitPath in
                        try HostwrightLocalPathResolver.resolve(
                            explicitStateDatabasePath: explicitPath,
                            homeDirectory: home.path,
                            environment: [:]
                        )
                    }
                )
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertEqual(adapter.executedActions.map(\.kind), [])
            let store = SQLiteStateStore(
                configuration: StateStoreConfiguration(localPathResolution: resolution)
            )
            XCTAssertEqual(try store.operations.loadAll().isEmpty, true)
            XCTAssertEqual(try store.operationGroups.loadAll().isEmpty, true)
            XCTAssertEqual(FileManager.default.fileExists(atPath: resolution.stateDatabasePath), true)
            XCTAssertEqual(try permissions(resolution.stateDatabasePath), 0o600)
        }
    }

    func testApplyRejectsMissingRuntimeAdapterMetadataBeforeMutation() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let observed = ObservedRuntimeState(projectName: "demo", services: [], adapterMetadata: nil)
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observed)
            let expectedHash = try planHash(for: singleServiceManifest, observed: observed)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertTrue(result.standardError.contains("adapter metadata"))
            XCTAssertTrue(adapter.executedActions.isEmpty)

            let store = SQLiteStateStore(path: databasePath)
            XCTAssertTrue(try store.operations.loadAll().isEmpty)
            XCTAssertTrue(try store.operationGroups.loadAll().isEmpty)
            XCTAssertTrue(try store.ownership.loadAll().isEmpty)
        }
    }

    func testApplyRejectsLegacyRuntimeProviderAPIBeforeMutation() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [],
                adapterMetadata: RuntimeAdapterMetadata(
                    providerAPIVersion: 1,
                    providerID: .appleContainerCLI,
                    adapterName: "legacy-provider",
                    adapterVersion: "1.0.0",
                    runtimeName: "legacy-runtime",
                    supportsMutation: true,
                    capabilities: [.readOnlyObservation, .lifecycleMutation]
                )
            )
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observed)
            let expectedHash = try planHash(for: singleServiceManifest, observed: observed)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertTrue(result.standardError.contains("requires Runtime Provider API v2"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(try SQLiteStateStore(path: databasePath).operationGroups.loadAll().isEmpty)
        }
    }

    func testApplyBlocksStoppedServiceWithoutCommittedSchedulerAuthority() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: restartableServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: restartableServiceManifest)
            try saveOwnership(store: store)
            let originalOwnership = try XCTUnwrap(store.ownership.loadAll().first)
            let adapter = ScriptedApplyRuntimeAdapter(
                observedState: ObservedRuntimeState(
                    projectName: "demo",
                    services: [
                        ObservedRuntimeService(
                            identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                            resourceIdentifier: RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier,
                            image: "local/demo:latest",
                            lifecycleState: .stopped,
                            healthState: .unknown
                        )
                    ],
                    adapterMetadata: fakeAdapterMetadata
                )
            )
            let expectedHash = try planHash(for: restartableServiceManifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(adapter.confirmations.isEmpty)
            XCTAssertTrue(try store.operationGroups.loadAll().isEmpty)
            XCTAssertEqual(
                try XCTUnwrap(store.ownership.loadAll().first).fencingToken,
                originalOwnership.fencingToken
            )
        }
    }

    func testApplyBlocksLegacyOwnedServiceWithoutCommittedSchedulerAuthority() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let serviceName = "0123456789abcdef0123456789abcdef"
            let manifestText = """
            version: 3
            project: v2-a-b
            services:
              \(serviceName):
                image: local/demo:latest
                resources:
                  requests:
                    cpus: 1
                    memory: 512MiB
                  limits:
                    cpus: 1
                    memory: 512MiB
                restart:
                  policy: on-failure
            """
            let identity = RuntimeServiceIdentity(projectName: "v2-a-b", serviceName: serviceName)
            let resourceIdentifier = identity.legacyManagedResourceIdentifier
            XCTAssertTrue(RuntimeManagedResourceIdentity.isCurrentIdentifier(resourceIdentifier))
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try store.desiredStates.saveManifestSnapshot(
                projectID: "project-v2-a-b",
                manifestPath: HostwrightIdentity.manifestFileName,
                manifestHash: "manifest-hash",
                desiredGeneration: 1,
                manifest: try ManifestValidator.validated(manifestText),
                timestamp: "2026-07-01T00:00:00Z"
            )
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "ownership-legacy-v2-shape",
                    resourceIdentifier: resourceIdentifier,
                    resourceType: "container",
                    projectID: "project-v2-a-b",
                    serviceName: serviceName,
                    runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                    createdAt: "2026-07-01T00:00:00Z",
                    observedAt: "2026-07-01T00:00:00Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}",
                    identityVersion: 1
                )
            )
            let observed = ObservedRuntimeState(
                projectName: identity.projectName,
                services: [
                    ObservedRuntimeService(
                        identity: identity,
                        resourceIdentifier: resourceIdentifier,
                        image: "local/demo:latest",
                        lifecycleState: .stopped,
                        healthState: .unknown
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observed)
            let expectedHash = try planHash(for: manifestText, observed: observed)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(try store.operationGroups.loadAll().isEmpty)
        }
    }

    func testApplyRejectsManagedRestartWithoutOwnershipRecord() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let manifestText = managedRestartHealthManifest
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: manifestText)
            try saveFreshUnhealthyHealthResult(store: store)
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                        resourceIdentifier: RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier,
                        image: "local/demo:latest",
                        lifecycleState: .running,
                        healthState: .unhealthy
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observed)
            let expectedHash = try planHash(for: manifestText, observed: observed)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(adapter.executedActions.isEmpty)

            XCTAssertTrue(try store.operations.loadAll().isEmpty)
            XCTAssertTrue(try store.restartRecovery.loadAll().isEmpty)
        }
    }

    func testApplyRestartsUnhealthyRunningOwnedServiceAndWritesRecoveryRecord() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let manifestText = managedRestartHealthManifest
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: manifestText)
            try saveOwnership(store: store)
            try saveFreshUnhealthyHealthResult(store: store)
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                        resourceIdentifier: RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier,
                        image: "local/demo:latest",
                        lifecycleState: .running,
                        healthState: .unhealthy
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observed)
            let expectedHash = try planHash(for: manifestText, observed: observed)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertEqual(adapter.executedActions.map(\.kind), [])

            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations.isEmpty, true)

            let recovery = try store.restartRecovery.loadAll()
            XCTAssertEqual(recovery.isEmpty, true)

            let states = try store.restartPolicies.loadProject(projectID: "project-demo")
            XCTAssertEqual(states.count, 0)

            let events = try store.events.loadAll()
            XCTAssertFalse(events.contains { $0.type == "apply.restart-intent-recorded" })
            XCTAssertFalse(events.contains { $0.type == "apply.restarted-service" })
            XCTAssertFalse(events.contains { $0.type == "restart.policy.active" })
        }
    }

    func testApplyFailedManagedRestartWritesRecoveryHintAndBackoff() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let manifestText = managedRestartHealthManifest
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: manifestText)
            try saveOwnership(store: store)
            try saveFreshUnhealthyHealthResult(store: store)
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                        resourceIdentifier: RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier,
                        image: "local/demo:latest",
                        lifecycleState: .running,
                        healthState: .unhealthy
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = ScriptedApplyRuntimeAdapter(
                observedState: observed,
                executeError: .managedRestartStartFailedAfterStop(message: "start failed", standardError: "token=\(fakeSecret)")
            )
            let expectedHash = try planHash(for: manifestText, observed: observed)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertFalse(result.standardError.contains(fakeSecret))
            XCTAssertEqual(adapter.executedActions.map(\.kind), [])

            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations.isEmpty, true)

            let recovery = try store.restartRecovery.loadAll()
            XCTAssertEqual(recovery.isEmpty, true)
            let groups = try store.operationGroups.loadAll()
            XCTAssertEqual(groups.isEmpty, true)

            let states = try store.restartPolicies.loadProject(projectID: "project-demo")
            XCTAssertEqual(states.count, 0)

            let events = try store.events.loadAll()
            XCTAssertFalse(events.contains { $0.type == "restart.policy.backoff" })
            XCTAssertFalse(events.contains { $0.type == "apply.restarted-service" })
            XCTAssertFalse(events.map(\.message).joined().contains(fakeSecret))
        }
    }

    func testApplyRefusesManagedRestartWithoutFreshPersistedHealthEvenWhenRuntimeUnhealthy() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let manifestText = managedRestartHealthManifest
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: manifestText)
            try saveOwnership(store: store)
            let observedUnhealthy = runningObservedService(healthState: .unhealthy)
            let observedForPlanning = runningObservedService(healthState: .unknown)
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observedUnhealthy)
            let expectedHash = try ReconciliationPlanner()
                .plan(manifest: ManifestValidator.validated(manifestText), observedState: observedForPlanning)
                .planHash

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(try store.restartRecovery.loadAll().isEmpty)
        }
    }

    func testApplyRefusesManagedRestartWithoutConfiguredHealthCheck() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let manifestText = restartableServiceManifest
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: manifestText)
            try saveOwnership(store: store)
            try saveFreshUnhealthyHealthResult(store: store)
            let observedUnhealthy = runningObservedService(healthState: .unhealthy)
            let observedForPlanning = runningObservedService(healthState: .unknown)
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observedUnhealthy)
            let expectedHash = try ReconciliationPlanner()
                .plan(manifest: ManifestValidator.validated(manifestText), observedState: observedForPlanning)
                .planHash

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(try store.restartRecovery.loadAll().isEmpty)
        }
    }

    func testApplyWithFreshHealthStillRequiresCommittedSchedulerAuthority() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let manifestText = managedRestartHealthManifest
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: manifestText)
            try saveOwnership(store: store)
            try store.healthResults.append([
                HealthCheckResultRecord(
                    id: "health-api",
                    projectID: "project-demo",
                    serviceName: "api",
                    checkedAt: ISO8601DateFormatter().string(from: Date()),
                    status: .unhealthy,
                    exitStatus: 1,
                    timedOut: false,
                    commandJSONRedacted: #"["false"]"#,
                    stdoutRedacted: "",
                    stderrRedacted: "",
                    metadataJSONRedacted: "{}"
                )
            ])
            let observedUnknown = runningObservedService(healthState: .unknown)
            let observedUnhealthy = runningObservedService(healthState: .unhealthy)
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observedUnknown)
            let expectedHash = try ReconciliationPlanner()
                .plan(manifest: ManifestValidator.validated(manifestText), observedState: observedUnhealthy)
                .planHash

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(try store.restartRecovery.loadAll().isEmpty)
        }
    }

    func testApplyIgnoresStalePersistedHealthResultForManagedRestart() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let manifestText = managedRestartHealthManifest
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: manifestText)
            try saveOwnership(store: store)
            try store.healthResults.append([
                HealthCheckResultRecord(
                    id: "health-api-stale",
                    projectID: "project-demo",
                    serviceName: "api",
                    checkedAt: "2000-07-01T00:00:00Z",
                    status: .unhealthy,
                    exitStatus: 1,
                    timedOut: false,
                    commandJSONRedacted: #"["false"]"#,
                    stdoutRedacted: "",
                    stderrRedacted: "",
                    metadataJSONRedacted: "{}"
                )
            ])
            let observedUnknown = runningObservedService(healthState: .unknown)
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observedUnknown)
            let expectedHash = try ReconciliationPlanner()
                .plan(manifest: ManifestValidator.validated(manifestText), observedState: observedUnknown)
                .planHash

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(try store.restartRecovery.loadAll().isEmpty)
        }
    }

    func testApplyWithoutSchedulerAuthorityDoesNotReachSuccessPersistence() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: restartableServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: restartableServiceManifest)
            try saveOwnership(store: store)
            let connection = try SQLiteConnection(path: databasePath)
            try connection.execute(
                """
                CREATE TRIGGER fail_success_operation
                BEFORE INSERT ON operation_ledger
                WHEN NEW.status = 'succeeded'
                BEGIN
                  SELECT RAISE(FAIL, 'blocked success persistence');
                END
                """
            )
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                        resourceIdentifier: RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier,
                        image: "local/demo:latest",
                        lifecycleState: .stopped,
                        healthState: .unknown
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observed)
            let expectedHash = try planHash(for: restartableServiceManifest, observed: observed)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertFalse(result.standardError.contains(HostwrightErrorCode.runtimeUnavailable.rawValue))
            XCTAssertFalse(result.standardError.contains("Runtime mutation failed"))
            XCTAssertTrue(adapter.executedActions.isEmpty)

            let states = try store.restartPolicies.loadProject(projectID: "project-demo")
            XCTAssertTrue(states.isEmpty)
            XCTAssertTrue(try store.operationGroups.loadAll().isEmpty)
            let events = try store.events.loadAll()
            XCTAssertFalse(events.contains { $0.type == "restart.policy.backoff" })
            XCTAssertFalse(events.contains { $0.type == "restart.policy.crash-loop-blocked" })
        }
    }

    func testApplyWithoutSchedulerAuthorityDoesNotReachPreRuntimePersistence() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            let connection = try SQLiteConnection(path: databasePath)
            try connection.execute(
                """
                CREATE TRIGGER fail_pre_runtime_desired_service
                BEFORE INSERT ON desired_services
                BEGIN
                  SELECT RAISE(FAIL, 'blocked pre-runtime persistence');
                END
                """
            )
            let adapter = ScriptedApplyRuntimeAdapter()
            let expectedHash = try planHash(for: singleServiceManifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(try store.operationGroups.loadAll().isEmpty)
        }
    }

    func testApplyBlocksManagedStartWhenCrashLoopStateIsPersisted() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: restartableServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: restartableServiceManifest)
            let crashLoopState = RestartPolicyStateRecord(
                id: "restart-api",
                projectID: "project-demo",
                serviceName: "api",
                policy: .onFailure,
                status: .crashLoopBlocked,
                attemptCount: 3,
                maxAttempts: 3,
                backoffSeconds: 60,
                updatedAt: "2026-07-01T00:00:00Z",
                metadataJSONRedacted: "{}"
            )
            try store.restartPolicies.upsert(crashLoopState)
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                        resourceIdentifier: RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier,
                        image: "local/demo:latest",
                        lifecycleState: .exited,
                        healthState: .unknown
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observed)
            let manifest = try ManifestValidator.validated(restartableServiceManifest)
            let expectedHash = ReconciliationPlanner().plan(
                manifest: manifest,
                observedState: adapter.observedState,
                restartPolicyStates: [RuntimeServiceIdentity(projectName: "demo", serviceName: "api"): crashLoopState],
                currentTimestamp: "2026-07-01T00:00:01Z"
            ).planHash

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(result.standardError.contains("crash-loop protection"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
        }
    }

    func testApplyWithoutSchedulerAuthorityDoesNotPersistRuntimeFailure() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = ScriptedApplyRuntimeAdapter(executeError: .commandFailed(exitStatus: 2, message: "failed", standardError: "token=\(fakeSecret)"))
            let expectedHash = try planHash(for: singleServiceManifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertFalse(result.standardError.contains(fakeSecret))
            XCTAssertTrue(adapter.executedActions.isEmpty)

            let store = SQLiteStateStore(path: databasePath)
            XCTAssertTrue(try store.operations.loadAll().isEmpty)
            XCTAssertTrue(try store.operationGroups.loadAll().isEmpty)
            XCTAssertFalse(try store.events.loadAll().map(\.message).joined(separator: "\n").contains(fakeSecret))
        }
    }

    func testApplyDoesNotResolveSecretWithoutCommittedSchedulerAuthority() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let manifest = """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  requests:
                    cpus: 1
                    memory: 512MiB
                  limits:
                    cpus: 1
                    memory: 512MiB
                secretEnv:
                  SESSION: keychain://hostwright.api/session
                ports:
                  - "8080:8080"

            """
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifest])
            let adapter = ScriptedApplyRuntimeAdapter()
            let opaqueSecret = "opaque-session-value"
            let secretStore = try InMemorySecretStore(rawValues: ["keychain://hostwright.api/session": opaqueSecret])
            let expectedHash = try planHash(for: manifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter, secretStore: secretStore)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertFalse(result.standardOutput.contains(opaqueSecret))
            XCTAssertTrue(adapter.executedActions.isEmpty)

            let store = SQLiteStateStore(path: databasePath)
            XCTAssertTrue(try store.operations.loadAll().isEmpty)
            let events = try store.events.loadAll()
            XCTAssertFalse(events.map(\.message).joined(separator: "\n").contains(opaqueSecret))
        }
    }

    func testApplyRepeatedPlanRemainsBlockedWithoutCommittedSchedulerAuthority() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = ScriptedApplyRuntimeAdapter()
            let expectedHash = try planHash(for: singleServiceManifest, observed: adapter.observedState)

            let first = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )
            let second = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(first.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertEqual(second.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(first.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(second.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(try SQLiteStateStore(path: databasePath).operations.loadAll().isEmpty)
        }
    }

    func testApplyRepeatedSecretPlanIsBlockedBeforeSecretResolutionWithoutSchedulerAuthority() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let manifest = """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  requests:
                    cpus: 1
                    memory: 512MiB
                  limits:
                    cpus: 1
                    memory: 512MiB
                secretEnv:
                  API_TOKEN: keychain://hostwright.api/api-token
                ports:
                  - "8080:8080"

            """
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifest])
            let adapter = ScriptedApplyRuntimeAdapter()
            let secretStore = try InMemorySecretStore(rawValues: ["keychain://hostwright.api/api-token": "token=\(fakeSecret)"])
            let expectedHash = try planHash(for: manifest, observed: adapter.observedState)

            let first = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter, secretStore: secretStore)
            )
            let second = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(first.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertEqual(second.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(first.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(second.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertFalse(second.standardError.contains("Secret reference resolution failed"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
        }
    }

    func testApplyFailsClosedWhenSecretReferenceBackendIsUnavailable() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let manifest = """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  requests:
                    cpus: 1
                    memory: 512MiB
                  limits:
                    cpus: 1
                    memory: 512MiB
                secretEnv:
                  API_TOKEN: keychain://hostwright.api/api-token
                ports:
                  - "8080:8080"

            """
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifest])
            let adapter = ScriptedApplyRuntimeAdapter()
            let expectedHash = try planHash(for: manifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertFalse(result.standardError.contains("Secret reference resolution failed"))
            XCTAssertFalse(result.standardError.contains("hostwright.api"))
            XCTAssertFalse(result.standardError.contains("api-token"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
        }
    }

    func testApplyRetryRemainsBlockedWithoutCommittedSchedulerAuthority() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let failingAdapter = ScriptedApplyRuntimeAdapter(executeError: .commandFailed(exitStatus: 2, message: "failed", standardError: "token=\(fakeSecret)"))
            let expectedHash = try planHash(for: singleServiceManifest, observed: failingAdapter.observedState)

            let first = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: failingAdapter)
            )
            let retryAdapter = ScriptedApplyRuntimeAdapter(observedState: failingAdapter.observedState)
            let second = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: retryAdapter)
            )

            XCTAssertEqual(first.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertEqual(second.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(first.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(second.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(failingAdapter.executedActions.isEmpty)
            XCTAssertTrue(retryAdapter.executedActions.isEmpty)

            let store = SQLiteStateStore(path: databasePath)
            let operations = try store.operations.loadAll()
            XCTAssertTrue(operations.isEmpty)
        }
    }

    func testApplyObservationFailureIsRuntimeFailure() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = ScriptedApplyRuntimeAdapter(observeError: .runtimeUnavailable("observe failed token=\(fakeSecret)"))

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", "unused"],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.runtimeUnavailable.rawValue))
            XCTAssertFalse(result.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
            XCTAssertFalse(result.standardError.contains(fakeSecret))
            XCTAssertTrue(adapter.executedActions.isEmpty)
        }
    }

    func testApplyWithoutSchedulerAuthorityDoesNotReachRuntimeFailurePersistence() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = ScriptedApplyRuntimeAdapter(
                executeError: .commandFailed(exitStatus: 2, message: "runtime failed", standardError: "token=\(fakeSecret)"),
                onExecute: { _ in
                    try FileManager.default.removeItem(atPath: databasePath)
                    try FileManager.default.createDirectory(atPath: databasePath, withIntermediateDirectories: false)
                }
            )
            let expectedHash = try planHash(for: singleServiceManifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertFalse(result.standardError.contains("Failure state persistence also failed"))
            XCTAssertFalse(result.standardError.contains(fakeSecret))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: databasePath))
        }
    }

    func testApplyWithoutSchedulerAuthorityCreatesNoFailureOperationGroup() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            let connection = try SQLiteConnection(path: databasePath)
            try connection.execute(
                """
                CREATE TRIGGER fail_failed_operation
                BEFORE INSERT ON operation_ledger
                WHEN NEW.status = 'failed'
                BEGIN
                  SELECT RAISE(FAIL, 'blocked failure persistence');
                END
                """
            )
            let adapter = ScriptedApplyRuntimeAdapter(
                executeError: .commandFailed(exitStatus: 2, message: "runtime failed", standardError: "token=\(fakeSecret)")
            )
            let expectedHash = try planHash(for: singleServiceManifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertFalse(result.standardError.contains("Failure state persistence also failed"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(try store.operationGroups.loadAll().isEmpty)
        }
    }
}
