import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightReconciler
@testable import HostwrightRuntime
@testable import HostwrightState

final class CLIFileErrorAndRecoveryTests: XCTestCase {
    func testManifestFileFailuresUseStableClassificationAcrossCommands() throws {
        let databasePath = "/tmp/hostwright-missing-\(UUID().uuidString).sqlite"
        let commands: [([String], CLIOutputFormat)] = [
            (["validate", "missing.yaml"], .text),
            (["plan", "missing.yaml", "--output", "json"], .json),
            (["status", "missing.yaml"], .text),
            (["status", "missing.yaml", "--output", "json"], .json),
            (["apply", "missing.yaml", "--state-db", databasePath, "--confirm-plan", "plan"], .text),
            (["logs", "api", "missing.yaml"], .text),
            (["cleanup", "missing.yaml", "--state-db", databasePath, "--dry-run"], .text)
        ]

        for (arguments, output) in commands {
            let result = HostwrightCLI.run(arguments: arguments, environment: environment(files: FileBox()))

            XCTAssertEqual(result.exitCode, CLIExitCode.validation.rawValue, "arguments: \(arguments)")
            XCTAssertEqual(result.standardOutput, "", "arguments: \(arguments)")
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.manifestFileIOFailed.rawValue), "arguments: \(arguments)")
            XCTAssertFalse(result.standardError.contains(HostwrightErrorCode.runtimeUnavailable.rawValue), "arguments: \(arguments)")
            XCTAssertFalse(result.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue), "arguments: \(arguments)")

            if output == .json {
                let json = try jsonObject(result.standardError)
                XCTAssertEqual(json["kind"] as? String, "error")
                XCTAssertEqual(json["code"] as? String, HostwrightErrorCode.manifestFileIOFailed.rawValue)
                XCTAssertEqual(json["exitCode"] as? Int, Int(CLIExitCode.validation.rawValue))
            }
        }
    }

    func testManifestReadFailureDetailsAreRedacted() throws {
        let secret = "plain-secret-token"
        let files = FileBox(files: ["unreadable.yaml": "present"])
        let result = HostwrightCLI.run(
            arguments: ["plan", "unreadable.yaml", "--output", "json"],
            environment: environment(
                files: files,
                readError: NSError(
                    domain: "HostwrightCLITests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "permission denied token=\(secret)"]
                )
            )
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.validation.rawValue)
        XCTAssertFalse(result.standardError.contains(secret))
        let json = try jsonObject(result.standardError)
        XCTAssertEqual(json["code"] as? String, HostwrightErrorCode.manifestFileIOFailed.rawValue)
    }

    func testImportReadAndInitWriteFailuresUseLocalFileClassification() throws {
        let secret = "plain-secret-token"
        let importResult = HostwrightCLI.run(
            arguments: ["import-stack", "missing-compose.yaml", "--output", "json"],
            environment: environment(files: FileBox())
        )

        XCTAssertEqual(importResult.exitCode, CLIExitCode.commandUsage.rawValue)
        XCTAssertEqual(importResult.standardOutput, "")
        let importJSON = try jsonObject(importResult.standardError)
        XCTAssertEqual(importJSON["code"] as? String, HostwrightErrorCode.fileIOFailed.rawValue)
        XCTAssertEqual(importJSON["exitCode"] as? Int, Int(CLIExitCode.commandUsage.rawValue))

        let initResult = HostwrightCLI.run(
            arguments: ["init"],
            environment: environment(
                files: FileBox(),
                writeError: NSError(
                    domain: "HostwrightCLITests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "write denied token=\(secret)"]
                )
            )
        )

        XCTAssertEqual(initResult.exitCode, CLIExitCode.commandUsage.rawValue)
        XCTAssertEqual(initResult.standardOutput, "")
        XCTAssertTrue(initResult.standardError.contains(HostwrightErrorCode.fileIOFailed.rawValue))
        XCTAssertFalse(initResult.standardError.contains(secret))
    }

    func testApplyActiveLeaseExplainsOwnerExpiryAndDoesNotMutate() throws {
        try withTemporaryDatabase { databasePath in
            let manifestText = singleServiceManifest
            let manifest = try ManifestValidator.validated(manifestText)
            let adapter = RecordingRuntimeAdapter(projectName: "demo")
            let observed = adapter.observedState
            let plan = ReconciliationPlanner().plan(manifest: manifest, observedState: observed)
            let action = try XCTUnwrap(plan.actions.first)
            let idempotencyKey = "\(plan.planHash):\(action.kind.rawValue):\(action.identity.displayName)"
            let lockExpiresAt = "2099-07-12T12:10:00Z"
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try store.desiredStates.saveManifestSnapshot(
                projectID: "project-demo",
                manifestPath: HostwrightIdentity.manifestFileName,
                manifestHash: "manifest",
                desiredGeneration: 1,
                manifest: manifest,
                timestamp: "2026-07-12T12:00:00Z"
            )
            _ = try store.operationGroups.acquire(
                activeGroup(
                    idempotencyKey: idempotencyKey,
                    planHash: plan.planHash,
                    lockOwner: "hostwright-cli:token=plain-secret-token",
                    lockExpiresAt: lockExpiresAt
                )
            )
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])

            let result = HostwrightCLI.run(
                arguments: [
                    "apply",
                    "--state-db", databasePath,
                    "--confirm-plan", plan.planHash
                ],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.commandUsage.rawValue)
            XCTAssertEqual(adapter.executionCount, 0)
            XCTAssertTrue(result.standardError.contains("checkpoint prepared"))
            XCTAssertTrue(result.standardError.contains("owner hostwright-cli:token=[REDACTED]"))
            XCTAssertTrue(result.standardError.contains(lockExpiresAt))
            XCTAssertTrue(result.standardError.contains("lease expires"))
            XCTAssertTrue(result.standardError.contains("No mutation was attempted"))
            XCTAssertFalse(result.standardError.contains("plain-secret-token"))
        }
    }

    func testApplyRecordedIntentActiveLeaseRequiresManualInspection() throws {
        try withTemporaryDatabase { databasePath in
            let manifestText = singleServiceManifest
            let manifest = try ManifestValidator.validated(manifestText)
            let adapter = RecordingRuntimeAdapter(projectName: "demo")
            let plan = ReconciliationPlanner().plan(manifest: manifest, observedState: adapter.observedState)
            let action = try XCTUnwrap(plan.actions.first)
            let idempotencyKey = "\(plan.planHash):\(action.kind.rawValue):\(action.identity.displayName)"
            let lockExpiresAt = "2099-07-12T12:10:00Z"
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try store.desiredStates.saveManifestSnapshot(
                projectID: "project-demo",
                manifestPath: HostwrightIdentity.manifestFileName,
                manifestHash: "manifest",
                desiredGeneration: 1,
                manifest: manifest,
                timestamp: "2026-07-12T12:00:00Z"
            )
            _ = try store.operationGroups.acquire(
                activeGroup(
                    idempotencyKey: idempotencyKey,
                    planHash: plan.planHash,
                    lockOwner: "hostwright-cli:token=plain-secret-token",
                    lockExpiresAt: lockExpiresAt
                )
            )
            try store.operations.record(
                OperationRecord(
                    id: "operation-active-recorded",
                    createdAt: "2026-07-12T12:00:00Z",
                    updatedAt: "2026-07-12T12:00:00Z",
                    plannedActionType: action.kind.rawValue,
                    projectID: "project-demo",
                    serviceName: "api",
                    status: .recorded,
                    idempotencyKey: idempotencyKey,
                    planHash: plan.planHash,
                    payloadJSONRedacted: "{}"
                )
            )
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])

            let result = HostwrightCLI.run(
                arguments: [
                    "apply",
                    "--state-db", databasePath,
                    "--confirm-plan", plan.planHash
                ],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.commandUsage.rawValue)
            XCTAssertEqual(adapter.executionCount, 0)
            XCTAssertTrue(result.standardError.contains("checkpoint prepared"))
            XCTAssertTrue(result.standardError.contains("owner hostwright-cli:token=[REDACTED]"))
            XCTAssertTrue(result.standardError.contains(lockExpiresAt))
            XCTAssertTrue(result.standardError.contains("operation intent is recorded"))
            XCTAssertTrue(result.standardError.contains("automatic retry remains blocked"))
            XCTAssertFalse(result.standardError.contains("plain-secret-token"))
        }
    }

    func testApplyCanRetryAfterPreRuntimePersistenceFailureWithRecordedIntent() throws {
        try withTemporaryDatabase { databasePath in
            let manifestText = singleServiceManifest
            let manifest = try ManifestValidator.validated(manifestText)
            let adapter = RecordingRuntimeAdapter(projectName: "demo")
            let plan = ReconciliationPlanner().plan(manifest: manifest, observedState: adapter.observedState)
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            let connection = try SQLiteConnection(path: databasePath)
            try connection.execute(
                """
                CREATE TRIGGER fail_apply_started_event
                BEFORE INSERT ON event_ledger
                BEGIN
                  SELECT RAISE(FAIL, 'blocked pre-runtime event persistence');
                END
                """
            )
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let arguments = [
                "apply",
                "--state-db", databasePath,
                "--confirm-plan", plan.planHash
            ]

            let first = HostwrightCLI.run(
                arguments: arguments,
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(first.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertEqual(adapter.executionCount, 0)
            XCTAssertEqual(try store.operations.loadAll().map(\.status), [.recorded])
            XCTAssertEqual(try store.operationGroups.loadAll().map(\.status), [.interrupted])
            XCTAssertEqual(try store.operationGroups.loadAll().first?.checkpoint, "pre-runtime-state-incomplete")

            try connection.execute("DROP TRIGGER fail_apply_started_event")
            let retry = HostwrightCLI.run(
                arguments: arguments,
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(retry.exitCode, 0)
            XCTAssertEqual(adapter.executionCount, 1)
            XCTAssertEqual(try store.operations.loadAll().map(\.status), [.recorded, .recorded, .succeeded])
            XCTAssertEqual(try store.operationGroups.loadAll().map(\.status), [.interrupted, .succeeded])
        }
    }

    func testRecoveryTextAndJSONExposeRedactedActiveLeaseFields() throws {
        try withTemporaryDatabase { databasePath in
            let lockExpiresAt = "2099-07-12T12:10:00Z"
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            _ = try store.operationGroups.acquire(
                activeGroup(
                    idempotencyKey: "plan:create:demo/api",
                    planHash: "plan",
                    lockOwner: "hostwright-cli:token=plain-secret-token",
                    lockExpiresAt: lockExpiresAt
                )
            )

            let textResult = HostwrightCLI.run(
                arguments: ["recovery", "--state-db", databasePath],
                environment: environment(files: FileBox())
            )
            XCTAssertEqual(textResult.exitCode, 0)
            XCTAssertTrue(textResult.standardOutput.contains("lock: owner=hostwright-cli:token=[REDACTED] expiresAt=\(lockExpiresAt)"))
            XCTAssertFalse(textResult.standardOutput.contains("plain-secret-token"))

            let jsonResult = HostwrightCLI.run(
                arguments: ["recovery", "--state-db", databasePath, "--output", "json"],
                environment: environment(files: FileBox())
            )
            XCTAssertEqual(jsonResult.exitCode, 0)
            XCTAssertFalse(jsonResult.standardOutput.contains("plain-secret-token"))
            let json = try jsonObject(jsonResult.standardOutput)
            let groups = try XCTUnwrap(json["operationGroups"] as? [[String: Any]])
            let group = try XCTUnwrap(groups.first)
            XCTAssertEqual(group["lockOwner"] as? String, "hostwright-cli:token=[REDACTED]")
            XCTAssertEqual(group["lockExpiresAt"] as? String, lockExpiresAt)
        }
    }

    private var singleServiceManifest: String {
        """
        version: 2
        project: demo
        services:
          api:
            image: local/demo:latest

        """
    }

    private func activeGroup(
        idempotencyKey: String,
        planHash: String,
        lockOwner: String,
        lockExpiresAt: String
    ) -> OperationGroupRecord {
        OperationGroupRecord(
            id: "group-\(UUID().uuidString)",
            operationID: "operation-active",
            groupKind: "apply",
            projectID: "project-demo",
            serviceName: "api",
            plannedActionType: "createMissingService",
            status: .active,
            groupIdempotencyKey: idempotencyKey,
            planHash: planHash,
            checkpoint: "prepared",
            lockOwner: lockOwner,
            lockExpiresAt: lockExpiresAt,
            rollbackAvailable: false,
            manualRecoveryHintRedacted: "Inspect the active operation.",
            createdAt: "2026-07-12T12:00:00Z",
            updatedAt: "2026-07-12T12:00:00Z",
            metadataJSONRedacted: "{}"
        )
    }

    private func environment(
        files: FileBox,
        readError: Error? = nil,
        writeError: Error? = nil,
        runtimeAdapter: (any RuntimeAdapter)? = nil
    ) -> CLIEnvironment {
        CLIEnvironment(
            fileExists: { files.files[$0] != nil },
            readTextFile: { path in
                if let readError {
                    throw readError
                }
                guard let text = files.files[path] else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return text
            },
            writeTextFile: { path, text in
                if let writeError {
                    throw writeError
                }
                files.files[path] = text
            },
            executablePath: { _ in nil },
            runtimeAdapter: { runtimeAdapter ?? RecordingRuntimeAdapter(projectName: "demo") },
            swiftVersion: { "Swift 6.3.3" },
            platformSnapshot: { PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64") },
            operatingSystemDescription: { "macOS 26.5" }
        )
    }

    private func withTemporaryDatabase(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-cli-file-errors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory.appendingPathComponent("state.sqlite").path)
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class FileBox {
    var files: [String: String]

    init(files: [String: String] = [:]) {
        self.files = files
    }
}

private final class RecordingRuntimeAdapter: RuntimeAdapter, @unchecked Sendable {
    let observedState: ObservedRuntimeState
    private let lock = NSLock()
    private var executedActions = 0

    init(projectName: String) {
        observedState = ObservedRuntimeState(
            projectName: projectName,
            services: [],
            adapterMetadata: RuntimeAdapterMetadata(
                adapterName: "RecordingRuntimeAdapter",
                adapterVersion: "test",
                runtimeName: "test-runtime",
                runtimeVersion: nil,
                supportsMutation: true,
                capabilities: [.readOnlyObservation, .lifecycleMutation]
            )
        )
    }

    var executionCount: Int {
        lock.withLock { executedActions }
    }

    func metadata() async -> RuntimeAdapterMetadata {
        observedState.adapterMetadata!
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation, .lifecycleMutation]
    }

    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        observedState
    }

    func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
        RuntimePlan(actions: [])
    }

    func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        lock.withLock { executedActions += 1 }
        return RuntimeEvent(identity: action.identity, message: "executed", resourceIdentifier: action.resourceIdentifier)
    }

    func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        RuntimeLogResult(identity: service.identity, text: "", lineLimit: tail)
    }
}
