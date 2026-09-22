import Darwin
import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightRuntime
@testable import HostwrightState

extension HostwrightCLITests {
    func testBlockedManagedStartPreservesCleanupEligibility() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: restartableServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: restartableServiceManifest)
            try saveOwnership(store: store)

            let stoppedObserved = ObservedRuntimeState(
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
            let startAdapter = ScriptedApplyRuntimeAdapter(observedState: stoppedObserved)
            let startHash = try planHash(for: restartableServiceManifest, observed: stoppedObserved)
            let startResult = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", startHash],
                environment: environment(files: files, runtimeAdapter: startAdapter)
            )

            XCTAssertEqual(startResult.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(startResult.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(startAdapter.executedActions.isEmpty)
            let ownership = try store.ownership.loadAll()
            XCTAssertEqual(ownership.count, 1)
            XCTAssertTrue(ownership[0].cleanupEligible)
        }
    }

    func testCleanupDryRunAndConfirmedDeleteOnlyEligibleStoppedOwnedContainers() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "owner-api",
                    resourceIdentifier: "hostwright-demo-api",
                    resourceType: "container",
                    projectID: "project-demo",
                    serviceName: "api",
                    runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                    createdAt: "2026-07-01T00:00:00Z",
                    observedAt: "2026-07-01T00:00:00Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}"
                )
            )
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [ObservedRuntimeService(
                    identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                    resourceIdentifier: "hostwright-demo-api",
                    lifecycleState: .stopped
                )],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = ScriptedApplyRuntimeAdapter(
                observedState: observed,
                postExecuteObservedState: ObservedRuntimeState(
                    projectName: "demo",
                    services: [],
                    adapterMetadata: fakeAdapterMetadata
                )
            )

            let dryRun = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--dry-run"],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(dryRun.exitCode, 0)
            XCTAssertTrue(dryRun.standardOutput.contains("hostwright-demo-api"))
            XCTAssertTrue(dryRun.standardOutput.contains("[eligible] hostwright-demo-api service=api lifecycle=stopped"))
            let token = dryRun.standardOutput
                .split(separator: "\n")
                .first { $0.hasPrefix("Confirmation token: ") }!
                .replacingOccurrences(of: "Confirmation token: ", with: "")

            let mismatch = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--confirm-cleanup", "wrong-token"],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(mismatch.exitCode, CLIExitCode.confirmationMismatch.rawValue)
            XCTAssertTrue(mismatch.standardError.contains(HostwrightErrorCode.confirmationMismatch.rawValue))
            XCTAssertEqual(adapter.executedActions.count, 0)

            let confirmed = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--confirm-cleanup", token],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(
                confirmed.exitCode,
                0,
                "stdout=\(confirmed.standardOutput) stderr=\(confirmed.standardError)"
            )
            XCTAssertEqual(adapter.executedActions.map(\.kind), [.remove])
            let cleanupContext = try XCTUnwrap(adapter.confirmations.last?.context)
            XCTAssertNil(cleanupContext.validationIssue)
            let events = try SQLiteStateStore(path: databasePath).events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "cleanup.planned" })
            XCTAssertTrue(events.contains { $0.type == "cleanup.deleted" })
            if let plannedIndex = events.firstIndex(where: {
                $0.type == "cleanup.planned"
            }), let deletedIndex = events.firstIndex(where: {
                $0.type == "cleanup.deleted"
            }) {
                XCTAssertLessThan(plannedIndex, deletedIndex)
            }
            let ownership = try SQLiteStateStore(path: databasePath).ownership.loadAll()
            XCTAssertTrue(ownership.isEmpty)
            XCTAssertNotEqual(
                HostwrightResourceUUID.legacy(
                    kind: "ownership-fence",
                    identifier: "owner-api"
                ),
                cleanupContext.fencingToken
            )
        }
    }

    func testCleanupDryRunClassifiesBlockedResourcesAndDeletesOnlyEligibleExactIDs() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)

            func ownership(
                _ id: String,
                resourceIdentifier: String,
                resourceType: String = "container",
                serviceName: String,
                runtimeAdapter: String = RuntimeProviderID.appleContainerCLI.rawValue,
                cleanupEligible: Bool = true
            ) -> OwnershipRecord {
                OwnershipRecord(
                    id: id,
                    resourceIdentifier: resourceIdentifier,
                    resourceType: resourceType,
                    projectID: "project-demo",
                    serviceName: serviceName,
                    runtimeAdapter: runtimeAdapter,
                    createdAt: "2026-07-01T00:00:00Z",
                    observedAt: "2026-07-01T00:00:00Z",
                    cleanupEligible: cleanupEligible,
                    metadataJSONRedacted: "{}"
                )
            }

            let ownershipRecords = [
                ownership("owner-api", resourceIdentifier: "hostwright-demo-api", serviceName: "api"),
                ownership("owner-worker", resourceIdentifier: "hostwright-demo-worker", serviceName: "worker"),
                ownership("owner-stale", resourceIdentifier: "hostwright-demo-stale", serviceName: "stale"),
                ownership("owner-unknown", resourceIdentifier: "hostwright-demo-unknown", serviceName: "unknown"),
                ownership("owner-dupe", resourceIdentifier: "hostwright-demo-dupe", serviceName: "dupe"),
                ownership("owner-collide", resourceIdentifier: "hostwright-demo-collide", serviceName: "old-name"),
                ownership("owner-adapter", resourceIdentifier: "hostwright-demo-adapter", serviceName: "adapter", runtimeAdapter: "other"),
                ownership("owner-disabled", resourceIdentifier: "hostwright-demo-disabled", serviceName: "disabled", cleanupEligible: false),
                ownership("owner-volume", resourceIdentifier: "hostwright-demo-volume", resourceType: "volume", serviceName: "volume"),
                ownership("owner-external", resourceIdentifier: "external-container", serviceName: "external")
            ]
            for ownership in ownershipRecords {
                try store.ownership.upsert(ownership)
            }

            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"), resourceIdentifier: "hostwright-demo-api", lifecycleState: .stopped),
                    ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "worker"), resourceIdentifier: "hostwright-demo-worker", lifecycleState: .running),
                    ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "unknown"), resourceIdentifier: "hostwright-demo-unknown", lifecycleState: .unknown),
                    ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "dupe", instanceName: "one"), resourceIdentifier: "hostwright-demo-dupe", lifecycleState: .stopped),
                    ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "dupe", instanceName: "two"), resourceIdentifier: "hostwright-demo-dupe", lifecycleState: .exited),
                    ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "collide"), resourceIdentifier: "hostwright-demo-collide", lifecycleState: .stopped),
                    ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "adapter"), resourceIdentifier: "hostwright-demo-adapter", lifecycleState: .stopped),
                    ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "disabled"), resourceIdentifier: "hostwright-demo-disabled", lifecycleState: .stopped),
                    ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "orphan"), resourceIdentifier: "hostwright-demo-orphan", lifecycleState: .stopped)
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = ScriptedApplyRuntimeAdapter(
                observedState: observed,
                postExecuteObservedState: ObservedRuntimeState(
                    projectName: "demo",
                    services: [],
                    adapterMetadata: fakeAdapterMetadata
                )
            )

            let dryRun = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--dry-run"],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(dryRun.exitCode, 0)
            XCTAssertTrue(dryRun.standardOutput.contains("[eligible] hostwright-demo-api"))
            XCTAssertTrue(dryRun.standardOutput.contains("[running] hostwright-demo-worker"))
            XCTAssertTrue(dryRun.standardOutput.contains("[stale] hostwright-demo-stale"))
            XCTAssertTrue(dryRun.standardOutput.contains("[unknown] hostwright-demo-unknown"))
            XCTAssertTrue(dryRun.standardOutput.contains("[ambiguous] hostwright-demo-dupe"))
            XCTAssertTrue(dryRun.standardOutput.contains("[blocked] hostwright-demo-collide"))
            XCTAssertTrue(dryRun.standardOutput.contains("[blocked] hostwright-demo-adapter"))
            XCTAssertTrue(dryRun.standardOutput.contains("[never-delete] hostwright-demo-disabled"))
            XCTAssertTrue(dryRun.standardOutput.contains("[never-delete] hostwright-demo-volume"))
            XCTAssertTrue(dryRun.standardOutput.contains("[never-delete] external-container"))
            XCTAssertTrue(dryRun.standardOutput.contains("[never-delete] hostwright-demo-orphan"))
            XCTAssertTrue(dryRun.standardOutput.contains("observed container has no Hostwright ownership record"))

            let token = dryRun.standardOutput
                .split(separator: "\n")
                .first { $0.hasPrefix("Confirmation token: ") }!
                .replacingOccurrences(of: "Confirmation token: ", with: "")

            let confirmed = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--confirm-cleanup", token],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(confirmed.exitCode, 0)
            XCTAssertEqual(adapter.executedActions.map(\.identity.serviceName), ["api"])
            XCTAssertTrue(confirmed.standardOutput.contains("- deleted hostwright-demo-api"))
            XCTAssertFalse(confirmed.standardOutput.contains("- deleted hostwright-demo-worker"))
            XCTAssertFalse(confirmed.standardOutput.contains("- deleted hostwright-demo-dupe"))

            let ownership = try store.ownership.loadAll()
            XCTAssertNil(
                ownership.first {
                    $0.resourceIdentifier == "hostwright-demo-api"
                }
            )
            XCTAssertTrue(try XCTUnwrap(ownership.first { $0.resourceIdentifier == "hostwright-demo-worker" }).cleanupEligible)
            XCTAssertTrue(try XCTUnwrap(ownership.first { $0.resourceIdentifier == "hostwright-demo-dupe" }).cleanupEligible)
        }
    }

    func testCleanupUsesPersistedAdapterAndBlocksAdapterMismatch() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            try saveOwnership(store: store)
            let ownership = try store.ownership.loadAll()
            XCTAssertEqual(ownership.count, 1)
            XCTAssertEqual(ownership[0].runtimeAdapter, RuntimeProviderID.appleContainerCLI.rawValue)
            let resourceIdentifier = RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier

            let stoppedObserved = ObservedRuntimeState(
                projectName: "demo",
                services: [ObservedRuntimeService(
                    identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                    resourceIdentifier: resourceIdentifier,
                    lifecycleState: .stopped
                )],
                adapterMetadata: fakeAdapterMetadata
            )
            let cleanupAdapter = ScriptedApplyRuntimeAdapter(observedState: stoppedObserved)
            let eligibleDryRun = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--dry-run"],
                environment: environment(files: files, runtimeAdapter: cleanupAdapter)
            )
            XCTAssertEqual(eligibleDryRun.exitCode, 0)
            XCTAssertTrue(eligibleDryRun.standardOutput.contains("[eligible] \(resourceIdentifier)"))

            let otherMetadata = RuntimeAdapterMetadata(
                providerID: .appleContainerization,
                adapterName: "other-apply-adapter",
                adapterVersion: "test",
                runtimeName: "other-runtime",
                runtimeVersion: nil,
                supportsMutation: true,
                capabilities: [.readOnlyObservation, .lifecycleMutation, .logStreaming, .cleanup]
            )
            let mismatchedObserved = ObservedRuntimeState(
                projectName: "demo",
                services: [ObservedRuntimeService(
                    identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                    resourceIdentifier: resourceIdentifier,
                    lifecycleState: .stopped
                )],
                adapterMetadata: otherMetadata
            )
            let mismatchedAdapter = ScriptedApplyRuntimeAdapter(observedState: mismatchedObserved)
            let blockedDryRun = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--dry-run"],
                environment: environment(files: files, runtimeAdapter: mismatchedAdapter)
            )

            XCTAssertEqual(blockedDryRun.exitCode, 0)
            XCTAssertTrue(blockedDryRun.standardOutput.contains("[blocked] \(resourceIdentifier)"))
            XCTAssertTrue(blockedDryRun.standardOutput.contains("runtime adapter mismatch"))
            let blockedToken = blockedDryRun.standardOutput
                .split(separator: "\n")
                .first { $0.hasPrefix("Confirmation token: ") }!
                .replacingOccurrences(of: "Confirmation token: ", with: "")

            let blockedConfirm = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--confirm-cleanup", blockedToken],
                environment: environment(files: files, runtimeAdapter: mismatchedAdapter)
            )

            XCTAssertEqual(blockedConfirm.exitCode, CLIExitCode.commandUsage.rawValue)
            XCTAssertEqual(mismatchedAdapter.executedActions.count, 0)
        }
    }

    func testCleanupMigratesLegacyOwnershipRuntimeAdapterBeforeClassification() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try MigrationRunner().apply(to: store, throughVersion: 4)
            let connection = try SQLiteConnection(path: databasePath)
            try connection.run(
                """
                INSERT INTO projects (id, name, manifest_path, manifest_hash, created_at, updated_at)
                VALUES ('project-demo', 'demo', 'hostwright.yaml', 'manifest-hash',
                        '2026-07-01T00:00:00Z', '2026-07-01T00:00:00Z')
                """
            )
            try connection.run(
                """
                INSERT INTO ownership_records (
                    id, resource_identifier, resource_type, project_id, service_name, runtime_adapter,
                    created_at, observed_at, cleanup_eligible, metadata_json_redacted
                )
                VALUES (
                    'owner-legacy', 'hostwright-demo-api', 'container', 'project-demo', 'api',
                    'runtime-adapter', '2026-07-01T00:00:00Z', '2026-07-01T00:00:00Z', 1, '{}'
                )
                """
            )
            let appleApplyMetadata = RuntimeAdapterMetadata(
                providerID: .appleContainerCLI,
                adapterName: "AppleContainerApplyAdapter",
                adapterVersion: "test",
                runtimeName: "Apple container CLI",
                runtimeVersion: nil,
                supportsMutation: true,
                capabilities: [.readOnlyObservation, .lifecycleMutation, .logStreaming, .cleanup]
            )
            let stoppedObserved = ObservedRuntimeState(
                projectName: "demo",
                services: [ObservedRuntimeService(
                    identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                    resourceIdentifier: "hostwright-demo-api",
                    lifecycleState: .stopped
                )],
                adapterMetadata: appleApplyMetadata
            )

            let result = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--dry-run"],
                environment: environment(files: files, runtimeAdapter: ScriptedApplyRuntimeAdapter(observedState: stoppedObserved))
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardOutput.contains("[eligible] hostwright-demo-api"))
            XCTAssertFalse(result.standardOutput.contains("runtime adapter mismatch"))
            let ownership = try SQLiteStateStore(path: databasePath).ownership.loadAll()
            XCTAssertEqual(ownership.count, 1)
            XCTAssertEqual(ownership[0].runtimeAdapter, "AppleContainerApplyAdapter")
        }
    }

    func testCleanupDeleteSuccessStatePersistenceFailureIsReportedAsStateUnavailable() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "owner-api",
                    resourceIdentifier: "hostwright-demo-api",
                    resourceType: "container",
                    projectID: "project-demo",
                    serviceName: "api",
                    runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                    createdAt: "2026-07-01T00:00:00Z",
                    observedAt: "2026-07-01T00:00:00Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}"
                )
            )
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [ObservedRuntimeService(
                    identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                    resourceIdentifier: "hostwright-demo-api",
                    lifecycleState: .stopped
                )],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = ScriptedApplyRuntimeAdapter(
                observedState: observed,
                postExecuteObservedState: ObservedRuntimeState(
                    projectName: "demo",
                    services: [],
                    adapterMetadata: fakeAdapterMetadata
                ),
                onExecute: { _ in
                    try FileManager.default.removeItem(atPath: databasePath)
                    try FileManager.default.createDirectory(atPath: databasePath, withIntermediateDirectories: false)
                }
            )

            let dryRun = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--dry-run"],
                environment: environment(files: files, runtimeAdapter: adapter)
            )
            let token = dryRun.standardOutput
                .split(separator: "\n")
                .first { $0.hasPrefix("Confirmation token: ") }!
                .replacingOccurrences(of: "Confirmation token: ", with: "")

            let confirmed = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--confirm-cleanup", token],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(confirmed.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertTrue(confirmed.standardOutput.contains("- deleted hostwright-demo-api"))
            XCTAssertTrue(confirmed.standardOutput.contains("- state update failed hostwright-demo-api"))
            XCTAssertTrue(confirmed.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
            XCTAssertFalse(confirmed.standardError.contains(HostwrightErrorCode.runtimeUnavailable.rawValue))
            XCTAssertEqual(adapter.executedActions.map(\.kind), [.remove])
        }
    }

    func testCleanupPartialFailureReportsSuccessAndFailureAndPreservesOwnership() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: twoServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: twoServiceManifest)
            for service in ["api", "worker"] {
                try store.ownership.upsert(
                    OwnershipRecord(
                        id: "owner-\(service)",
                        resourceIdentifier: "hostwright-demo-\(service)",
                        resourceType: "container",
                        projectID: "project-demo",
                        serviceName: service,
                        runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                        createdAt: "2026-07-01T00:00:00Z",
                        observedAt: "2026-07-01T00:00:00Z",
                        cleanupEligible: true,
                        metadataJSONRedacted: "{}"
                    )
                )
            }
            let originalWorkerOwnership = try XCTUnwrap(
                try store.ownership.loadAll().first { $0.serviceName == "worker" }
            )
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"), resourceIdentifier: "hostwright-demo-api", lifecycleState: .stopped),
                    ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "worker"), resourceIdentifier: "hostwright-demo-worker", lifecycleState: .stopped)
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let secret = fakeSecret
            let adapter = ScriptedApplyRuntimeAdapter(
                observedState: observed,
                postExecuteObservedState: ObservedRuntimeState(
                    projectName: "demo",
                    services: [
                        ObservedRuntimeService(
                            identity: RuntimeServiceIdentity(
                                projectName: "demo",
                                serviceName: "worker"
                            ),
                            resourceIdentifier: "hostwright-demo-worker",
                            lifecycleState: .stopped
                        )
                    ],
                    adapterMetadata: fakeAdapterMetadata
                ),
                onExecute: { action in
                    if action.identity.serviceName == "worker" {
                        throw RuntimeAdapterError.commandFailed(exitStatus: 2, message: "delete failed", standardError: "token=\(secret)")
                    }
                }
            )

            let dryRun = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--dry-run"],
                environment: environment(files: files, runtimeAdapter: adapter)
            )
            let token = dryRun.standardOutput
                .split(separator: "\n")
                .first { $0.hasPrefix("Confirmation token: ") }!
                .replacingOccurrences(of: "Confirmation token: ", with: "")
            let confirmed = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--confirm-cleanup", token],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(confirmed.exitCode, CLIExitCode.partialFailure.rawValue)
            XCTAssertTrue(confirmed.standardOutput.contains("- deleted hostwright-demo-api"))
            XCTAssertTrue(confirmed.standardOutput.contains("- failed hostwright-demo-worker"))
            XCTAssertTrue(confirmed.standardError.contains(HostwrightErrorCode.partialFailure.rawValue))
            XCTAssertFalse(confirmed.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
            XCTAssertFalse(confirmed.standardOutput.contains(fakeSecret))

            let operations = try store.operations.loadAll()
            XCTAssertTrue(operations.contains { $0.serviceName == "api" && $0.status == .succeeded })
            XCTAssertTrue(operations.contains { $0.serviceName == "worker" && $0.status == .failed })
            let events = try store.events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "cleanup.deleted" })
            XCTAssertTrue(events.contains { $0.type == "cleanup.failed" })
            let ownership = try store.ownership.loadAll()
            XCTAssertNil(ownership.first { $0.serviceName == "api" })
            let survivingWorkerOwnership = try XCTUnwrap(ownership.first { $0.serviceName == "worker" })
            XCTAssertTrue(survivingWorkerOwnership.cleanupEligible)
            XCTAssertNotEqual(
                survivingWorkerOwnership.fencingToken,
                originalWorkerOwnership.fencingToken
            )
            let workerAuthority = try XCTUnwrap(
                OwnershipAuthorityMetadata.decode(
                    from: survivingWorkerOwnership.metadataJSONRedacted
                )
            )
            XCTAssertNotNil(workerAuthority.deletionTimestamp)
            XCTAssertEqual(
                Set(workerAuthority.finalizers.map(\.state)),
                [.releasing]
            )
            XCTAssertEqual(adapter.observedDesiredStates.count, 4)
            let recoveryHint = try XCTUnwrap(
                adapter.observedDesiredStates.last?.ownedResourceHints.first {
                    $0.resourceIdentifier == originalWorkerOwnership.resourceIdentifier
                }
            )
            XCTAssertEqual(recoveryHint.ownership?.resourceUUID, originalWorkerOwnership.resourceUUID)
            XCTAssertEqual(recoveryHint.ownership?.fencingToken, originalWorkerOwnership.fencingToken)
        }
    }

    func testCleanupProviderErrorWithVerifiedAbsenceFinalizesDeletion() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "owner-api",
                    resourceIdentifier: "hostwright-demo-api",
                    resourceType: "container",
                    projectID: "project-demo",
                    serviceName: "api",
                    runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                    createdAt: "2026-07-01T00:00:00Z",
                    observedAt: "2026-07-01T00:00:00Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}"
                )
            )
            let present = ObservedRuntimeState(
                projectName: "demo",
                services: [ObservedRuntimeService(
                    identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                    resourceIdentifier: "hostwright-demo-api",
                    lifecycleState: .stopped
                )],
                adapterMetadata: fakeAdapterMetadata
            )
            let absent = ObservedRuntimeState(
                projectName: "demo",
                services: [],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = ScriptedApplyRuntimeAdapter(
                observedState: present,
                postExecuteObservedState: absent,
                executeError: .commandFailed(
                    exitStatus: 2,
                    message: "provider reported failure",
                    standardError: "token=\(fakeSecret)"
                )
            )

            let dryRun = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--dry-run"],
                environment: environment(files: files, runtimeAdapter: adapter)
            )
            let token = dryRun.standardOutput
                .split(separator: "\n")
                .first { $0.hasPrefix("Confirmation token: ") }!
                .replacingOccurrences(of: "Confirmation token: ", with: "")
            let confirmed = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--confirm-cleanup", token],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(confirmed.exitCode, 0)
            XCTAssertTrue(confirmed.standardOutput.contains("- deleted hostwright-demo-api"))
            XCTAssertEqual(confirmed.standardError, "")
            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations.map(\.status), [.recorded, .succeeded])
            let succeeded = try XCTUnwrap(operations.last)
            XCTAssertTrue(succeeded.payloadJSONRedacted.contains(#""result":"deleted-after-provider-error""#))
            XCTAssertTrue(succeeded.payloadJSONRedacted.contains(#""recovery":"resource-absence-verified""#))
            XCTAssertFalse(succeeded.payloadJSONRedacted.contains(fakeSecret))
            let events = try store.events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "cleanup.deleted" })
            XCTAssertFalse(events.contains { $0.type == "cleanup.failed" })
            XCTAssertTrue(try store.ownership.loadAll().isEmpty)
        }
    }

    func testCleanupAmbiguousReobservationRetainsOperationFenceAndFailure() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "owner-api",
                    resourceIdentifier: "hostwright-demo-api",
                    resourceType: "container",
                    projectID: "project-demo",
                    serviceName: "api",
                    runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                    createdAt: "2026-07-01T00:00:00Z",
                    observedAt: "2026-07-01T00:00:00Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}"
                )
            )
            let originalOwnership = try XCTUnwrap(store.ownership.loadAll().first)
            let service = ObservedRuntimeService(
                identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                resourceIdentifier: "hostwright-demo-api",
                lifecycleState: .stopped
            )
            let present = ObservedRuntimeState(
                projectName: "demo",
                services: [service],
                adapterMetadata: fakeAdapterMetadata
            )
            let mismatchedCapability = ObservedRuntimeState(
                projectName: "demo",
                services: [service],
                adapterMetadata: fakeAdapterMetadata,
                capabilitySHA256: String(repeating: "b", count: 64)
            )
            let adapter = ScriptedApplyRuntimeAdapter(
                observedState: present,
                postExecuteObservedState: mismatchedCapability,
                executeError: .commandFailed(
                    exitStatus: 2,
                    message: "provider reported failure",
                    standardError: "token=\(fakeSecret)"
                )
            )

            let dryRun = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--dry-run"],
                environment: environment(files: files, runtimeAdapter: adapter)
            )
            let token = dryRun.standardOutput
                .split(separator: "\n")
                .first { $0.hasPrefix("Confirmation token: ") }!
                .replacingOccurrences(of: "Confirmation token: ", with: "")
            let confirmed = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--confirm-cleanup", token],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(confirmed.exitCode, CLIExitCode.partialFailure.rawValue)
            XCTAssertTrue(confirmed.standardOutput.contains("- failed hostwright-demo-api"))
            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations.map(\.status), [.recorded, .failed])
            let failed = try XCTUnwrap(operations.last)
            XCTAssertTrue(failed.payloadJSONRedacted.contains(
                #""recovery":"reobservation-ambiguous-operation-fence-retained""#
            ))
            XCTAssertFalse(failed.payloadJSONRedacted.contains(fakeSecret))
            let retainedOwnership = try XCTUnwrap(store.ownership.loadAll().first)
            XCTAssertTrue(retainedOwnership.cleanupEligible)
            XCTAssertNotEqual(retainedOwnership.fencingToken, originalOwnership.fencingToken)
            XCTAssertTrue(failed.payloadJSONRedacted.contains(
                #""fencingToken":"\#(retainedOwnership.fencingToken)""#
            ))
            XCTAssertTrue(try store.events.loadAll().contains { $0.type == "cleanup.failed" })
        }
    }
}
