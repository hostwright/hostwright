import Darwin
import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightRuntime
@testable import HostwrightState

extension HostwrightCLITests {
    func testDiagnosticsWritesLocalRedactedBundleWithoutRuntimeObservation() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let bundlePath = "/tmp/hostwright-diagnostics-\(UUID().uuidString).json"
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            try store.events.append([
                EventRecord(id: "event-secret", timestamp: "2026-07-01T00:00:01Z", severity: .error, type: "apply.failed", source: "test", projectID: "project-demo", serviceName: "api", runtimeAdapter: "fake", message: "token=\(fakeSecret)", payloadJSONRedacted: #"{"token":"\#(fakeSecret)"}"#),
                EventRecord(id: "event-other", timestamp: "2026-07-01T00:00:02Z", severity: .info, type: "status.observed", source: "test", projectID: nil, serviceName: "api", runtimeAdapter: "fake", message: "global event", payloadJSONRedacted: "{}")
            ])
            try store.operations.record(
                OperationRecord(
                    id: "operation-secret",
                    createdAt: "2026-07-01T00:00:01Z",
                    updatedAt: "2026-07-01T00:00:02Z",
                    plannedActionType: "createMissingService",
                    projectID: "project-demo",
                    serviceName: "api",
                    status: .failed,
                    idempotencyKey: "plan:create:api",
                    planHash: "plan",
                    payloadJSONRedacted: #"{"error":"token=\#(fakeSecret)"}"#
                )
            )

            let result = HostwrightCLI.run(
                arguments: ["diagnostics", "--state-db", databasePath, "--bundle", bundlePath, "--project", "demo", "--manifest", HostwrightIdentity.manifestFileName],
                environment: environment(files: files, runtimeAdapter: ScriptedApplyRuntimeAdapter(observeError: .runtimeUnavailable("should not observe")))
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardOutput.contains("Telemetry: local-only; no upload"))
            let bundle = try XCTUnwrap(files.files[bundlePath])
            XCTAssertFalse(bundle.contains(fakeSecret))
            let json = try jsonObject(bundle)
            XCTAssertEqual(json["kind"] as? String, "diagnostics")
            XCTAssertEqual(json["projectID"] as? String, "project-demo")
            XCTAssertEqual(json["telemetryPolicy"] as? String, "local-only; no upload")
            let events = try XCTUnwrap(json["events"] as? [[String: Any]])
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?["message"] as? String, "token=[REDACTED]")
            let manifest = try XCTUnwrap(json["manifest"] as? [String: Any])
            XCTAssertEqual(manifest["projectName"] as? String, "demo")

            let overwrite = HostwrightCLI.run(
                arguments: ["diagnostics", "--state-db", databasePath, "--bundle", bundlePath],
                environment: environment(files: files)
            )
            XCTAssertEqual(overwrite.exitCode, CLIExitCode.commandUsage.rawValue)
            XCTAssertTrue(overwrite.standardError.contains(HostwrightErrorCode.fileAlreadyExists.rawValue))

            let stateOnlyBundlePath = "/tmp/hostwright-diagnostics-state-only-\(UUID().uuidString).json"
            let stateOnly = HostwrightCLI.run(
                arguments: ["diagnostics", "--state-db", databasePath, "--bundle", stateOnlyBundlePath, "--project", "demo"],
                environment: environment(files: files)
            )
            XCTAssertEqual(stateOnly.exitCode, 0)
            let stateOnlyJSON = try jsonObject(try XCTUnwrap(files.files[stateOnlyBundlePath]))
            XCTAssertNil(stateOnlyJSON["manifest"])
        }
    }

    func testDiagnosticsLiveWriterCreatesModeSixHundredAndRefusesOverwrite() throws {
        try withCLITestDirectory(prefix: "hostwright-cli-xctest") { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let bundlePath = directory.appendingPathComponent("diagnostics.json").path
            try SQLiteStateStore(path: databasePath).migrate()

            let previousMask = umask(0o777)
            let first = HostwrightCLI.run(
                arguments: ["diagnostics", "--state-db", databasePath, "--bundle", bundlePath],
                environment: .live
            )
            _ = umask(previousMask)
            XCTAssertEqual(first.exitCode, 0)
            XCTAssertEqual(try permissions(bundlePath), 0o600)
            let original = try Data(contentsOf: URL(fileURLWithPath: bundlePath))

            let second = HostwrightCLI.run(
                arguments: ["diagnostics", "--state-db", databasePath, "--bundle", bundlePath],
                environment: .live
            )
            XCTAssertEqual(second.exitCode, CLIExitCode.commandUsage.rawValue)
            XCTAssertTrue(second.standardError.contains(HostwrightErrorCode.fileAlreadyExists.rawValue))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: bundlePath)), original)
        }
    }

    func testDiagnosticsClassifiesLocalFileFailuresWithoutBlamingState() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            let writeFailure = HostwrightCLI.run(
                arguments: ["diagnostics", "--state-db", databasePath, "--bundle", "/tmp/unwritable.json"],
                environment: environment(
                    files: FileBox(),
                    writeError: NSError(domain: "HostwrightCLITest", code: 1, userInfo: [NSLocalizedDescriptionKey: "permission denied token=\(fakeSecret)"])
                )
            )

            XCTAssertEqual(writeFailure.exitCode, CLIExitCode.commandUsage.rawValue)
            XCTAssertTrue(writeFailure.standardError.contains(HostwrightErrorCode.fileIOFailed.rawValue))
            XCTAssertFalse(writeFailure.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
            XCTAssertFalse(writeFailure.standardError.contains(fakeSecret))

            let manifestFailure = HostwrightCLI.run(
                arguments: ["diagnostics", "--state-db", databasePath, "--bundle", "/tmp/diagnostics.json", "--manifest", "missing.yaml"],
                environment: environment(files: FileBox())
            )

            XCTAssertEqual(manifestFailure.exitCode, CLIExitCode.commandUsage.rawValue)
            XCTAssertTrue(manifestFailure.standardError.contains(HostwrightErrorCode.fileIOFailed.rawValue))
            XCTAssertFalse(manifestFailure.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
        }
    }

    func testDiagnosticsDoesNotCreateOrMigrateMissingStateDatabase() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox()
            let bundlePath = "/tmp/hostwright-diagnostics-\(UUID().uuidString).json"

            let result = HostwrightCLI.run(
                arguments: ["diagnostics", "--state-db", databasePath, "--bundle", bundlePath],
                environment: environment(files: files)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertEqual(result.standardOutput, "")
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
            XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath))
            XCTAssertNil(files.files[bundlePath])
        }
    }

    func testRecoveryJSONOutputDistinguishesManualAndUnsupportedRecovery() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            _ = try store.operationGroups.acquire(
                OperationGroupRecord(
                    id: "group-recovery",
                    operationID: "operation-recovery",
                    groupKind: "apply",
                    projectID: "project-demo",
                    serviceName: "api",
                    plannedActionType: "createMissingService",
                    status: .active,
                    groupIdempotencyKey: "plan-hash:create:api",
                    planHash: "plan-hash",
                    checkpoint: "runtime-started",
                    lockOwner: "hostwright-cli",
                    lockExpiresAt: "2026-07-01T00:10:00Z",
                    rollbackAvailable: false,
                    manualRecoveryHintRedacted: "inspect token=\(fakeSecret)",
                    createdAt: "2026-07-01T00:00:00Z",
                    updatedAt: "2026-07-01T00:00:00Z",
                    metadataJSONRedacted: "{}"
                )
            )
            try store.operationGroups.finish(
                groupID: "group-recovery",
                status: .failed,
                checkpoint: "runtime-failed",
                manualRecoveryHintRedacted: "manual password=\(fakeSecret)",
                updatedAt: "2026-07-01T00:00:01Z",
                metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
            )
            try store.operationGroupSteps.append(
                OperationGroupStepRecord(
                    id: "step-recovery",
                    groupID: "group-recovery",
                    stepKey: "runtime-execute",
                    direction: .forward,
                    plannedActionType: "createMissingService",
                    serviceName: "api",
                    resourceIdentifier: "hostwright-demo-api",
                    stepIdempotencyKey: "plan-hash:create:api:forward:runtime-execute",
                    status: .failed,
                    startedAt: "2026-07-01T00:00:00Z",
                    updatedAt: "2026-07-01T00:00:01Z",
                    finishedAt: "2026-07-01T00:00:01Z",
                    lastErrorRedacted: "token=\(fakeSecret)",
                    manualRecoveryHintRedacted: "manual token=\(fakeSecret)",
                    metadataJSONRedacted: "{}"
                )
            )

            let result = HostwrightCLI.run(arguments: ["recovery", "--state-db", databasePath, "--project", "demo", "--output", "json"], environment: environment(files: FileBox()))

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertFalse(result.standardOutput.contains(fakeSecret))
            let json = try jsonObject(result.standardOutput)
            XCTAssertEqual(json["kind"] as? String, "recovery")
            let groups = try XCTUnwrap(json["operationGroups"] as? [[String: Any]])
            XCTAssertEqual(groups.first?["status"] as? String, "failed")
            let recovery = try XCTUnwrap(groups.first?["recovery"] as? [String: Any])
            XCTAssertEqual(recovery["automatic"] as? String, "none")
            XCTAssertEqual(recovery["manual"] as? String, "required")
            XCTAssertEqual(recovery["rollback"] as? String, "unsupported")
        }
    }

    func testRecoveryOutputIncludesVersionedLifecycleCheckpointContract() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            let groupID = HostwrightResourceUUID.legacy(
                kind: "checkpoint-contract-group",
                identifier: databasePath
            )
            let operationID = HostwrightResourceUUID.legacy(
                kind: "checkpoint-contract-operation",
                identifier: databasePath
            )
            let fence = HostwrightResourceUUID.legacy(
                kind: "checkpoint-contract-fence",
                identifier: databasePath
            )
            let planSHA256 = String(repeating: "a", count: 64)
            XCTAssertNotNil(
                try store.operationGroups.acquire(
                    OperationGroupRecord(
                        id: groupID,
                        operationID: operationID,
                        groupKind: "lifecycle-v1",
                        projectID: "project-demo",
                        serviceName: "api",
                        plannedActionType: "up",
                        status: .active,
                        groupIdempotencyKey: planSHA256,
                        planHash: planSHA256,
                        checkpoint: "intent-persisted",
                        lockOwner: "checkpoint-contract-test",
                        lockExpiresAt: "2026-08-01T23:00:00Z",
                        rollbackAvailable: true,
                        manualRecoveryHintRedacted: "",
                        createdAt: "2026-08-01T22:00:00Z",
                        updatedAt: "2026-08-01T22:00:00Z",
                        metadataJSONRedacted: "{}",
                        fencingToken: fence,
                        intentJSONRedacted: "{}",
                        compensationJSONRedacted: "[]",
                        verificationJSONRedacted: "{}"
                    )
                ).acquired
            )
            try store.operationGroups.finish(
                groupID: groupID,
                status: .interrupted,
                checkpoint: "create-api:effect-pending",
                manualRecoveryHintRedacted: "re-observe exact resource",
                updatedAt: "2026-08-01T22:00:01Z",
                metadataJSONRedacted: "{}"
            )

            let jsonResult = HostwrightCLI.run(
                arguments: [
                    "recovery", "--state-db", databasePath,
                    "--output", "json"
                ],
                environment: environment(files: FileBox())
            )
            XCTAssertEqual(jsonResult.exitCode, 0, jsonResult.standardError)
            let object = try jsonObject(jsonResult.standardOutput)
            let groups = try XCTUnwrap(
                object["operationGroups"] as? [[String: Any]]
            )
            let contract = try XCTUnwrap(
                groups.first?["checkpointContract"] as? [String: Any]
            )
            XCTAssertEqual(contract["schemaVersion"] as? Int, 1)
            XCTAssertEqual(contract["classification"] as? String, "forward-effect")
            XCTAssertEqual(contract["recovery"] as? String, "reobserve")
            XCTAssertEqual(contract["nodeKey"] as? String, "create-api")

            let textResult = HostwrightCLI.run(
                arguments: ["recovery", "--state-db", databasePath],
                environment: environment(files: FileBox())
            )
            XCTAssertEqual(textResult.exitCode, 0, textResult.standardError)
            XCTAssertTrue(
                textResult.standardOutput.contains(
                    "checkpoint-contract: v1 class=forward-effect recovery=reobserve"
                )
            )
        }
    }

    func testRecoveryJSONOutputIncludesLegacyRestartRecoveryWhenNoOperationGroupExists() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            try store.restartRecovery.append(
                RestartRecoveryRecord(
                    id: "legacy-restart",
                    operationID: "operation-legacy",
                    projectID: "project-demo",
                    serviceName: "api",
                    resourceIdentifier: "hostwright-demo-api",
                    planHash: "plan-hash",
                    status: .stopSucceeded,
                    completedStepsJSONRedacted: #"["stop"]"#,
                    manualRecoveryHintRedacted: "manual token=\(fakeSecret)",
                    createdAt: "2026-07-01T00:00:00Z",
                    updatedAt: "2026-07-01T00:00:01Z",
                    metadataJSONRedacted: "{}"
                )
            )

            let result = HostwrightCLI.run(arguments: ["recovery", "--state-db", databasePath, "--project", "demo", "--output", "json"], environment: environment(files: FileBox()))

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertFalse(result.standardOutput.contains(fakeSecret))
            let json = try jsonObject(result.standardOutput)
            let groups = try XCTUnwrap(json["operationGroups"] as? [[String: Any]])
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(groups.first?["groupKind"] as? String, "legacy-restart")
            XCTAssertEqual(groups.first?["status"] as? String, "failed")
            let steps = try XCTUnwrap(groups.first?["steps"] as? [[String: Any]])
            XCTAssertEqual(steps.first?["stepKey"] as? String, "restart-stop")
            XCTAssertEqual(steps.first?["status"] as? String, "succeeded")
        }
    }

    func testRecoveryCommandDoesNotCreateOrMigrateMissingStateDatabase() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let result = HostwrightCLI.run(arguments: ["recovery", "--state-db", databasePath], environment: environment(files: FileBox()))

            XCTAssertEqual(result.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertEqual(result.standardOutput, "")
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
            XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath))
        }
    }
}
