import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightReconciler
@testable import HostwrightRuntime
@testable import HostwrightState

final class HostwrightCLITests: XCTestCase {
    func testCommandParserRecognizesSupportedCommands() throws {
        XCTAssertEqual(try CLICommand.parse(arguments: ["--version"]), .version)
        XCTAssertEqual(try CLICommand.parse(arguments: ["init"]), .initManifest)
        XCTAssertEqual(try CLICommand.parse(arguments: ["validate"]), .validate(path: "hostwright.yaml"))
        XCTAssertEqual(try CLICommand.parse(arguments: ["validate", "custom.yaml"]), .validate(path: "custom.yaml"))
        XCTAssertEqual(try CLICommand.parse(arguments: ["plan"]), .plan(path: "hostwright.yaml", output: .text))
        XCTAssertEqual(try CLICommand.parse(arguments: ["plan", "--output", "json"]), .plan(path: "hostwright.yaml", output: .json))
        XCTAssertEqual(try CLICommand.parse(arguments: ["status"]), .status(path: "hostwright.yaml", stateDatabasePath: nil, output: .text))
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["status", "--state-db", "/tmp/state.sqlite"]),
            .status(path: "hostwright.yaml", stateDatabasePath: "/tmp/state.sqlite", output: .text)
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["status", "custom.yaml", "--state-db", "/tmp/state.sqlite", "--output", "json"]),
            .status(path: "custom.yaml", stateDatabasePath: "/tmp/state.sqlite", output: .json)
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["apply", "--state-db", "/tmp/state.sqlite", "--confirm-plan", "abc123"]),
            .apply(path: "hostwright.yaml", stateDatabasePath: "/tmp/state.sqlite", confirmedPlanHash: "abc123")
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["apply", "custom.yaml", "--state-db", "/tmp/state.sqlite", "--confirm-plan", "abc123"]),
            .apply(path: "custom.yaml", stateDatabasePath: "/tmp/state.sqlite", confirmedPlanHash: "abc123")
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["logs", "api", "--tail", "25", "--state-db", "/tmp/state.sqlite"]),
            .logs(serviceName: "api", path: "hostwright.yaml", tail: 25, stateDatabasePath: "/tmp/state.sqlite")
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["events", "--state-db", "/tmp/state.sqlite", "--project", "demo"]),
            .events(stateDatabasePath: "/tmp/state.sqlite", projectName: "demo", output: .text)
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["events", "--state-db", "/tmp/state.sqlite", "--output", "json"]),
            .events(stateDatabasePath: "/tmp/state.sqlite", projectName: nil, output: .json)
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["recovery", "--state-db", "/tmp/state.sqlite", "--project", "demo", "--output", "json"]),
            .recovery(stateDatabasePath: "/tmp/state.sqlite", projectName: "demo", output: .json)
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["cleanup", "--state-db", "/tmp/state.sqlite", "--dry-run"]),
            .cleanup(path: "hostwright.yaml", stateDatabasePath: "/tmp/state.sqlite", confirmation: .dryRun)
        )
        XCTAssertEqual(try CLICommand.parse(arguments: ["doctor"]), .doctor(output: .text))
        XCTAssertEqual(try CLICommand.parse(arguments: ["doctor", "--output", "json"]), .doctor(output: .json))
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["doctor", "--output", "yaml"]))
    }

    func testApplyRequiresStateDBAndConfirmedPlanHash() {
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["apply", "--confirm-plan", "abc123"]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["apply", "--state-db", "/tmp/state.sqlite"]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["apply", "--state-db", "/tmp/state.sqlite", "--confirm-plan", "abc123", "--force"]))
    }

    func testVersionOutput() {
        let result = HostwrightCLI.run(arguments: ["--version"], environment: environment(files: FileBox()))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "0.1.0-alpha.1\n")
        XCTAssertEqual(result.standardError, "")
    }

    func testHelpDocumentsOutputModesAndExamples() {
        let result = HostwrightCLI.run(arguments: ["--help"], environment: environment(files: FileBox()))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardError, "")
        XCTAssertTrue(result.standardOutput.contains("hostwright plan [path] [--output text|json]"))
        XCTAssertTrue(result.standardOutput.contains("hostwright status [path] [--state-db <path>] [--output text|json]"))
        XCTAssertTrue(result.standardOutput.contains("hostwright recovery --state-db <path> [--project <name>] [--output text|json]"))
        XCTAssertTrue(result.standardOutput.contains("JSON output is supported for plan, status, events, recovery, doctor"))
        XCTAssertTrue(result.standardOutput.contains("hostwright doctor --output json"))
    }

    func testInitCreatesStarterManifestWithoutOverwriting() {
        let initFiles = FileBox()
        let initResult = HostwrightCLI.run(arguments: ["init"], environment: environment(files: initFiles))

        XCTAssertEqual(initResult.exitCode, 0)
        XCTAssertTrue(initFiles.files[HostwrightIdentity.manifestFileName]?.contains("project: api-local") == true)
        XCTAssertNoThrow(try ManifestValidator.validated(XCTUnwrap(initFiles.files[HostwrightIdentity.manifestFileName])))

        let existingFiles = FileBox(files: [HostwrightIdentity.manifestFileName: "project: existing\nservices:\n"])
        let overwriteResult = HostwrightCLI.run(arguments: ["init"], environment: environment(files: existingFiles))

        XCTAssertEqual(overwriteResult.exitCode, CLIExitCode.commandUsage.rawValue)
        XCTAssertTrue(overwriteResult.standardError.contains("HW-CLI-002"))
        XCTAssertEqual(existingFiles.files[HostwrightIdentity.manifestFileName], "project: existing\nservices:\n")
    }

    func testValidatePlanAndStatusAreNonMutating() {
        let validFiles = FileBox(files: [HostwrightIdentity.manifestFileName: HostwrightCLI.starterManifest])

        let validateResult = HostwrightCLI.run(arguments: ["validate"], environment: environment(files: validFiles))
        XCTAssertEqual(validateResult.exitCode, 0)
        XCTAssertTrue(validateResult.standardOutput.contains("Valid hostwright manifest"))

        let planResult = HostwrightCLI.run(arguments: ["plan"], environment: environment(files: validFiles))
        XCTAssertEqual(planResult.exitCode, 0)
        XCTAssertTrue(planResult.standardOutput.contains("non-mutating"))
        XCTAssertTrue(planResult.standardOutput.contains("Runtime observation"))
        XCTAssertTrue(planResult.standardOutput.contains("Plan hash"))
        XCTAssertTrue(planResult.standardOutput.contains("Execution: unavailable unless one createMissingService, startManagedService, or restartManagedService action is explicitly confirmed"))
        XCTAssertTrue(planResult.standardOutput.contains("No runtime actions were executed"))

        let statusResult = HostwrightCLI.run(arguments: ["status"], environment: environment(files: validFiles))
        XCTAssertEqual(statusResult.exitCode, 0)
        XCTAssertTrue(statusResult.standardOutput.contains("Manifest: hostwright.yaml valid"))
        XCTAssertTrue(statusResult.standardOutput.contains("Runtime: not observed"))
        XCTAssertFalse(statusResult.standardOutput.contains("running"))
        XCTAssertFalse(statusResult.standardOutput.contains("stopped"))
    }

    func testPlanOutputRedactsSecretLikeEnvironmentValues() {
        let files = FileBox(
            files: [
                HostwrightIdentity.manifestFileName: """
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    env:
                      API_TOKEN: token=super-secret

                """
            ]
        )

        let planResult = HostwrightCLI.run(arguments: ["plan"], environment: environment(files: files))

        XCTAssertEqual(planResult.exitCode, 0)
        XCTAssertTrue(planResult.standardOutput.contains("secretRedacted"))
        XCTAssertTrue(planResult.standardOutput.contains("API_TOKEN"))
        XCTAssertFalse(planResult.standardOutput.contains("super-secret"))
    }

    func testPlanJSONOutputIncludesStableShapeAndRedactsSecrets() throws {
        let files = FileBox(
            files: [
                HostwrightIdentity.manifestFileName: """
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    env:
                      API_TOKEN: token=\(fakeSecret)

                """
            ]
        )

        let result = HostwrightCLI.run(arguments: ["plan", "--output", "json"], environment: environment(files: files))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardError, "")
        XCTAssertFalse(result.standardOutput.contains(fakeSecret))
        let json = try jsonObject(result.standardOutput)
        XCTAssertEqual(json["kind"] as? String, "plan")
        XCTAssertEqual(json["project"] as? String, "api-local")
        XCTAssertNotNil(json["planHash"])
        let issues = try XCTUnwrap(json["issues"] as? [[String: Any]])
        XCTAssertTrue(issues.contains { $0["kind"] as? String == "secretRedacted" })
    }

    func testDoctorReportsMissingAppleContainerAsWarning() {
        let result = HostwrightCLI.run(arguments: ["doctor"], environment: environment(files: FileBox()))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("[warning] appleContainerCLI"))
    }

    func testDoctorJSONOutputIncludesChecks() throws {
        let result = HostwrightCLI.run(arguments: ["doctor", "--output", "json"], environment: environment(files: FileBox()))

        XCTAssertEqual(result.exitCode, 0)
        let json = try jsonObject(result.standardOutput)
        XCTAssertEqual(json["kind"] as? String, "doctor")
        XCTAssertEqual(json["hasFailures"] as? Bool, false)
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        XCTAssertTrue(checks.contains { $0["identifier"] as? String == "appleContainerCLI" && $0["status"] as? String == "warning" })
    }

    func testDoctorCompatibilityFailureUsesValidationExitCode() throws {
        let result = HostwrightCLI.run(
            arguments: ["doctor", "--output", "json"],
            environment: environment(files: FileBox(), platform: PlatformSnapshot(macOSMajorVersion: 25, architecture: "x86_64"))
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.validation.rawValue)
        let json = try jsonObject(result.standardOutput)
        XCTAssertEqual(json["hasFailures"] as? Bool, true)
    }

    func testJSONErrorsUseStableExitCodesAndEnvelope() throws {
        let usage = HostwrightCLI.run(arguments: ["unknown", "--output", "json"], environment: environment(files: FileBox()))

        XCTAssertEqual(usage.exitCode, CLIExitCode.commandUsage.rawValue)
        let usageJSON = try jsonObject(usage.standardError)
        XCTAssertEqual(usageJSON["kind"] as? String, "error")
        XCTAssertEqual(usageJSON["code"] as? String, HostwrightErrorCode.commandUsage.rawValue)
        XCTAssertEqual(usageJSON["exitCode"] as? Int, Int(CLIExitCode.commandUsage.rawValue))

        let invalidManifest = HostwrightCLI.run(
            arguments: ["plan", "--output", "json"],
            environment: environment(files: FileBox(files: [HostwrightIdentity.manifestFileName: "project: demo\nservices:\n  api:\n"]))
        )

        XCTAssertEqual(invalidManifest.exitCode, CLIExitCode.validation.rawValue)
        let manifestJSON = try jsonObject(invalidManifest.standardError)
        XCTAssertEqual(manifestJSON["kind"] as? String, "error")
        let issues = try XCTUnwrap(manifestJSON["issues"] as? [[String: Any]])
        XCTAssertTrue(issues.contains { $0["code"] as? String == HostwrightErrorCode.manifestValidationFailed.rawValue })
    }

    func testApplyRefusesWrongPlanHashBeforeMutation() throws {
        try withTemporaryDatabase { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = FakeApplyRuntimeAdapter()

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", "wrong-hash"],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.confirmationMismatch.rawValue)
            XCTAssertTrue(result.standardError.contains("Confirmed plan hash does not match"))
            XCTAssertEqual(adapter.executedActions.count, 0)
        }
    }

    func testApplyPersistsIntentBeforeCreateAndRecordsSuccess() throws {
        try withTemporaryDatabase { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = FakeApplyRuntimeAdapter()
            let expectedHash = try planHash(for: singleServiceManifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardOutput.contains("Applied action: createMissingService demo/api"))
            XCTAssertFalse(result.standardOutput.contains(fakeSecret))
            XCTAssertEqual(adapter.executedActions.map(\.kind), [.create])

            let store = SQLiteStateStore(path: databasePath)
            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations.map(\.status), [.recorded, .succeeded])
            XCTAssertEqual(operations.map(\.planHash), [expectedHash, expectedHash])
            let groups = try store.operationGroups.loadAll()
            XCTAssertEqual(groups.map(\.status), [.succeeded])
            XCTAssertEqual(groups[0].checkpoint, "completed")
            XCTAssertFalse(groups[0].rollbackAvailable)
            let steps = try store.operationGroupSteps.load(groupID: groups[0].id)
            XCTAssertEqual(steps.map(\.stepKey), ["rollback", "runtime-execute", "runtime-execute"])
            XCTAssertEqual(steps.map(\.status), [.unsupported, .started, .succeeded])

            let events = try store.events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "apply.create-intent-recorded" })
            XCTAssertTrue(events.contains { $0.type == "apply.created-service" })

            let ownership = try store.ownership.loadAll()
            XCTAssertEqual(ownership.count, 1)
            XCTAssertTrue(ownership[0].cleanupEligible)
        }
    }

    func testApplyCanStartStoppedServiceWhenRestartPolicyAllowsIt() throws {
        try withTemporaryDatabase { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: restartableServiceManifest])
            let adapter = FakeApplyRuntimeAdapter(
                observedState: ObservedRuntimeState(
                    projectName: "demo",
                    services: [
                        ObservedRuntimeService(
                            identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
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

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardOutput.contains("Applied action: proposeStartStoppedService demo/api"))
            XCTAssertEqual(adapter.executedActions.map(\.kind), [.start])

            let store = SQLiteStateStore(path: databasePath)
            let states = try store.restartPolicies.loadProject(projectID: "project-demo")
            XCTAssertEqual(states.count, 1)
            XCTAssertEqual(states[0].policy, .onFailure)
            XCTAssertEqual(states[0].status, .active)
            XCTAssertEqual(states[0].attemptCount, 0)
            XCTAssertNil(states[0].backoffUntil)

            let events = try store.events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "apply.started-service" })
            XCTAssertTrue(events.contains { $0.type == "restart.policy.active" })
        }
    }

    func testApplyRejectsManagedRestartWithoutOwnershipRecord() throws {
        try withTemporaryDatabase { databasePath in
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
                        image: "local/demo:latest",
                        lifecycleState: .running,
                        healthState: .unhealthy
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = FakeApplyRuntimeAdapter(observedState: observed)
            let expectedHash = try planHash(for: manifestText, observed: observed)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Hostwright ownership record"))
            XCTAssertTrue(adapter.executedActions.isEmpty)

            XCTAssertTrue(try store.operations.loadAll().isEmpty)
            XCTAssertTrue(try store.restartRecovery.loadAll().isEmpty)
        }
    }

    func testApplyRestartsUnhealthyRunningOwnedServiceAndWritesRecoveryRecord() throws {
        try withTemporaryDatabase { databasePath in
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
                        image: "local/demo:latest",
                        lifecycleState: .running,
                        healthState: .unhealthy
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = FakeApplyRuntimeAdapter(observedState: observed)
            let expectedHash = try planHash(for: manifestText, observed: observed)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardOutput.contains("Applied action: restartManagedService demo/api"))
            XCTAssertEqual(adapter.executedActions.map(\.kind), [.restart])
            XCTAssertEqual(adapter.executedActions.map(\.isDestructive), [true])

            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations.map(\.plannedActionType), ["restartManagedService", "restartManagedService"])
            XCTAssertEqual(operations.map(\.status), [.recorded, .succeeded])

            let recovery = try store.restartRecovery.loadAll()
            XCTAssertEqual(recovery.map(\.status), [.prepared, .succeeded])
            XCTAssertEqual(recovery.last?.completedStepsJSONRedacted, #"["stop","start"]"#)
            XCTAssertTrue(recovery.last?.manualRecoveryHintRedacted.contains("No manual recovery") == true)

            let states = try store.restartPolicies.loadProject(projectID: "project-demo")
            XCTAssertEqual(states.count, 1)
            XCTAssertEqual(states[0].status, .active)
            XCTAssertEqual(states[0].attemptCount, 0)

            let events = try store.events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "apply.restart-intent-recorded" })
            XCTAssertTrue(events.contains { $0.type == "apply.restarted-service" })
            XCTAssertTrue(events.contains { $0.type == "restart.policy.active" })
        }
    }

    func testApplyFailedManagedRestartWritesRecoveryHintAndBackoff() throws {
        try withTemporaryDatabase { databasePath in
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
                        image: "local/demo:latest",
                        lifecycleState: .running,
                        healthState: .unhealthy
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = FakeApplyRuntimeAdapter(
                observedState: observed,
                executeError: .managedRestartStartFailedAfterStop(message: "start failed", standardError: "token=\(fakeSecret)")
            )
            let expectedHash = try planHash(for: manifestText, observed: observed)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertFalse(result.standardError.contains(fakeSecret))
            XCTAssertEqual(adapter.executedActions.map(\.kind), [.restart])

            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations.map(\.status), [.recorded, .failed])
            XCTAssertFalse(operations.map(\.payloadJSONRedacted).joined().contains(fakeSecret))

            let recovery = try store.restartRecovery.loadAll()
            XCTAssertEqual(recovery.map(\.status), [.prepared, .stopSucceeded, .failed])
            XCTAssertEqual(recovery[1].completedStepsJSONRedacted, #"["stop"]"#)
            XCTAssertTrue(recovery.last?.manualRecoveryHintRedacted.contains("Inspect the exact Hostwright-owned container") == true)
            let groups = try store.operationGroups.loadAll()
            XCTAssertEqual(groups.map(\.status), [.failed])
            XCTAssertEqual(groups[0].checkpoint, "runtime-failed")
            let steps = try store.operationGroupSteps.load(groupID: groups[0].id)
            XCTAssertEqual(steps.map(\.stepKey), ["rollback", "runtime-execute", "restart-stop", "runtime-execute"])
            XCTAssertEqual(steps.map(\.status), [.unsupported, .started, .succeeded, .failed])

            let states = try store.restartPolicies.loadProject(projectID: "project-demo")
            XCTAssertEqual(states.count, 1)
            XCTAssertEqual(states[0].status, .backingOff)
            XCTAssertEqual(states[0].attemptCount, 1)

            let events = try store.events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "restart.policy.backoff" })
            XCTAssertFalse(events.contains { $0.type == "apply.restarted-service" })
            XCTAssertFalse(events.map(\.message).joined().contains(fakeSecret))
        }
    }

    func testApplyRefusesManagedRestartWithoutFreshPersistedHealthEvenWhenRuntimeUnhealthy() throws {
        try withTemporaryDatabase { databasePath in
            let manifestText = managedRestartHealthManifest
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: manifestText)
            try saveOwnership(store: store)
            let observedUnhealthy = runningObservedService(healthState: .unhealthy)
            let observedForPlanning = runningObservedService(healthState: .unknown)
            let adapter = FakeApplyRuntimeAdapter(observedState: observedUnhealthy)
            let expectedHash = try ReconciliationPlanner()
                .plan(manifest: ManifestValidator.validated(manifestText), observedState: observedForPlanning)
                .planHash

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertTrue(result.standardError.contains("No executable createMissingService, startManagedService, or restartManagedService action exists"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(try store.restartRecovery.loadAll().isEmpty)
        }
    }

    func testApplyRefusesManagedRestartWithoutConfiguredHealthCheck() throws {
        try withTemporaryDatabase { databasePath in
            let manifestText = restartableServiceManifest
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: manifestText)
            try saveOwnership(store: store)
            try saveFreshUnhealthyHealthResult(store: store)
            let observedUnhealthy = runningObservedService(healthState: .unhealthy)
            let observedForPlanning = runningObservedService(healthState: .unknown)
            let adapter = FakeApplyRuntimeAdapter(observedState: observedUnhealthy)
            let expectedHash = try ReconciliationPlanner()
                .plan(manifest: ManifestValidator.validated(manifestText), observedState: observedForPlanning)
                .planHash

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertTrue(result.standardError.contains("No executable createMissingService, startManagedService, or restartManagedService action exists"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(try store.restartRecovery.loadAll().isEmpty)
        }
    }

    func testStatusPlanHashMatchesApplyForPersistedHealthManagedRestart() throws {
        try withTemporaryDatabase { databasePath in
            let manifestText = managedRestartHealthManifest
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: manifestText)
            try saveOwnership(store: store)
            try saveFreshUnhealthyHealthResult(store: store)
            let observedUnknown = runningObservedService(healthState: .unknown)
            let adapter = FakeApplyRuntimeAdapter(observedState: observedUnknown)

            let status = HostwrightCLI.run(
                arguments: ["status", "--state-db", databasePath],
                environment: environment(files: files, runtimeAdapter: adapter)
            )
            let statusHash = try planHash(fromStatusOutput: status.standardOutput)
            XCTAssertTrue(status.standardOutput.contains("health=unhealthy"))

            let apply = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", statusHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(apply.exitCode, 0)
            XCTAssertEqual(adapter.executedActions.map(\.kind), [.restart])
        }
    }

    func testStatusPlanHashMatchesApplyForRestartPolicyBlockedManagedRestart() throws {
        try withTemporaryDatabase { databasePath in
            let manifestText = managedRestartHealthManifest
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: manifestText)
            try saveOwnership(store: store)
            try saveFreshUnhealthyHealthResult(store: store)
            try store.restartPolicies.upsert(
                RestartPolicyStateRecord(
                    id: "restart-state-api",
                    projectID: "project-demo",
                    serviceName: "api",
                    policy: .onFailure,
                    status: .crashLoopBlocked,
                    attemptCount: 3,
                    maxAttempts: 3,
                    backoffSeconds: 60,
                    updatedAt: hostwrightTimestamp(),
                    metadataJSONRedacted: "{}"
                )
            )
            let observedUnknown = runningObservedService(healthState: .unknown)
            let adapter = FakeApplyRuntimeAdapter(observedState: observedUnknown)

            let status = HostwrightCLI.run(
                arguments: ["status", "--state-db", databasePath],
                environment: environment(files: files, runtimeAdapter: adapter)
            )
            let statusHash = try planHash(fromStatusOutput: status.standardOutput)
            XCTAssertTrue(status.standardOutput.contains("health=unhealthy"))

            let apply = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", statusHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(apply.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertTrue(apply.standardError.contains("crash-loop protection"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
        }
    }

    func testApplyUsesFreshPersistedHealthResultForManagedRestart() throws {
        try withTemporaryDatabase { databasePath in
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
            let adapter = FakeApplyRuntimeAdapter(observedState: observedUnknown)
            let expectedHash = try ReconciliationPlanner()
                .plan(manifest: ManifestValidator.validated(manifestText), observedState: observedUnhealthy)
                .planHash

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(adapter.executedActions.map(\.kind), [.restart])
            XCTAssertTrue(try store.restartRecovery.loadAll().contains { $0.status == .succeeded })
        }
    }

    func testApplyIgnoresStalePersistedHealthResultForManagedRestart() throws {
        try withTemporaryDatabase { databasePath in
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
            let adapter = FakeApplyRuntimeAdapter(observedState: observedUnknown)
            let expectedHash = try ReconciliationPlanner()
                .plan(manifest: ManifestValidator.validated(manifestText), observedState: observedUnknown)
                .planHash

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertTrue(result.standardError.contains("No executable createMissingService, startManagedService, or restartManagedService action exists"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            XCTAssertTrue(try store.restartRecovery.loadAll().isEmpty)
        }
    }

    func testApplySuccessfulStartPersistenceFailureDoesNotRecordFailedRestartAttempt() throws {
        try withTemporaryDatabase { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: restartableServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
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
                        image: "local/demo:latest",
                        lifecycleState: .stopped,
                        healthState: .unknown
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = FakeApplyRuntimeAdapter(observedState: observed)
            let expectedHash = try planHash(for: restartableServiceManifest, observed: observed)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
            XCTAssertFalse(result.standardError.contains(HostwrightErrorCode.runtimeUnavailable.rawValue))
            XCTAssertFalse(result.standardError.contains("Runtime mutation failed"))
            XCTAssertEqual(adapter.executedActions.map(\.kind), [.start])

            let states = try store.restartPolicies.loadProject(projectID: "project-demo")
            XCTAssertTrue(states.isEmpty)
            let groups = try store.operationGroups.loadAll()
            XCTAssertEqual(groups.map(\.status), [.interrupted])
            XCTAssertEqual(groups[0].checkpoint, "runtime-finished-state-incomplete")
            XCTAssertFalse(groups[0].rollbackAvailable)
            let steps = try store.operationGroupSteps.load(groupID: groups[0].id)
            XCTAssertEqual(steps.map(\.status), [.unsupported, .started, .succeeded])
            let events = try store.events.loadAll()
            XCTAssertFalse(events.contains { $0.type == "restart.policy.backoff" })
            XCTAssertFalse(events.contains { $0.type == "restart.policy.crash-loop-blocked" })
        }
    }

    func testApplyPreRuntimeStateFailureMarksOperationGroupInterruptedWithoutMutation() throws {
        try withTemporaryDatabase { databasePath in
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
            let adapter = FakeApplyRuntimeAdapter()
            let expectedHash = try planHash(for: singleServiceManifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertTrue(result.standardError.contains("pre-runtime state persistence failed before mutation"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            let groups = try store.operationGroups.loadAll()
            XCTAssertEqual(groups.map(\.status), [.interrupted])
            XCTAssertEqual(groups[0].checkpoint, "pre-runtime-state-incomplete")
            let steps = try store.operationGroupSteps.load(groupID: groups[0].id)
            XCTAssertEqual(steps.map(\.status), [.unsupported])
        }
    }

    func testApplyBlocksManagedStartWhenCrashLoopStateIsPersisted() throws {
        try withTemporaryDatabase { databasePath in
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
                        image: "local/demo:latest",
                        lifecycleState: .exited,
                        healthState: .unknown
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = FakeApplyRuntimeAdapter(observedState: observed)
            let manifest = try ManifestValidator.validated(restartableServiceManifest)
            let expectedHash = ReconciliationPlanner().plan(
                manifest: manifest,
                observedState: observed,
                restartPolicyStates: [RuntimeServiceIdentity(projectName: "demo", serviceName: "api"): crashLoopState],
                currentTimestamp: "2026-07-01T00:00:01Z"
            ).planHash

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardError.contains("No executable createMissingService, startManagedService, or restartManagedService action exists"))
            XCTAssertTrue(result.standardError.contains("crash-loop protection"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
        }
    }

    func testManagedStartDoesNotRemoveCleanupEligibilityFromCreatedOwnership() throws {
        try withTemporaryDatabase { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: restartableServiceManifest])
            let createAdapter = FakeApplyRuntimeAdapter()
            let createHash = try planHash(for: restartableServiceManifest, observed: createAdapter.observedState)

            let createResult = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", createHash],
                environment: environment(files: files, runtimeAdapter: createAdapter)
            )
            XCTAssertEqual(createResult.exitCode, 0)

            let stoppedObserved = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                        image: "local/demo:latest",
                        lifecycleState: .stopped,
                        healthState: .unknown
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let startAdapter = FakeApplyRuntimeAdapter(observedState: stoppedObserved)
            let startHash = try planHash(for: restartableServiceManifest, observed: stoppedObserved)
            let startResult = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", startHash],
                environment: environment(files: files, runtimeAdapter: startAdapter)
            )

            XCTAssertEqual(startResult.exitCode, 0)
            let ownership = try SQLiteStateStore(path: databasePath).ownership.loadAll()
            XCTAssertEqual(ownership.count, 1)
            XCTAssertTrue(ownership[0].cleanupEligible)
        }
    }

    func testStatusWithStateDatabaseObservesAndRecordsEvent() throws {
        try withTemporaryDatabase { databasePath in
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                        image: "local/demo:latest",
                        lifecycleState: .running,
                        healthState: .healthy,
                        ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)]
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])

            let result = HostwrightCLI.run(
                arguments: ["status", "--state-db", databasePath],
                environment: environment(files: files, runtimeAdapter: FakeApplyRuntimeAdapter(observedState: observed))
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardOutput.contains("Runtime: observed"))
            XCTAssertTrue(result.standardOutput.contains("lifecycle=running"))
            let events = try SQLiteStateStore(path: databasePath).events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "status.observed" })
        }
    }

    func testStatusJSONOutputSupportsManifestOnlyAndObservedRuntimeShapes() throws {
        let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
        let manifestOnly = HostwrightCLI.run(arguments: ["status", "--output", "json"], environment: environment(files: files))

        XCTAssertEqual(manifestOnly.exitCode, 0)
        let manifestOnlyJSON = try jsonObject(manifestOnly.standardOutput)
        XCTAssertEqual(manifestOnlyJSON["kind"] as? String, "status")
        let runtime = try XCTUnwrap(manifestOnlyJSON["runtime"] as? [String: Any])
        XCTAssertEqual(runtime["observed"] as? Bool, false)

        try withTemporaryDatabase { databasePath in
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                        image: "local/demo:latest",
                        lifecycleState: .running,
                        healthState: .healthy,
                        ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)]
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let result = HostwrightCLI.run(
                arguments: ["status", "--state-db", databasePath, "--output", "json"],
                environment: environment(files: files, runtimeAdapter: FakeApplyRuntimeAdapter(observedState: observed))
            )

            XCTAssertEqual(result.exitCode, 0)
            let json = try jsonObject(result.standardOutput)
            XCTAssertEqual(json["kind"] as? String, "status")
            XCTAssertNotNil(json["planHash"])
            let observedRuntime = try XCTUnwrap(json["runtime"] as? [String: Any])
            XCTAssertEqual(observedRuntime["observed"] as? Bool, true)
            let services = try XCTUnwrap(json["services"] as? [[String: Any]])
            XCTAssertEqual(services.first?["name"] as? String, "api")
        }
    }

    func testStatusStateDatabaseFailureUsesStateExitCodeAndJSONEnvelope() throws {
        try withTemporaryDirectory { directory in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])

            let result = HostwrightCLI.run(
                arguments: ["status", "--state-db", directory.path, "--output", "json"],
                environment: environment(files: files)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertEqual(result.standardOutput, "")
            let json = try jsonObject(result.standardError)
            XCTAssertEqual(json["kind"] as? String, "error")
            XCTAssertEqual(json["code"] as? String, HostwrightErrorCode.stateStoreUnavailable.rawValue)
            XCTAssertEqual(json["exitCode"] as? Int, Int(CLIExitCode.stateUnavailable.rawValue))
        }
    }

    func testLogsUseRuntimeAdapterAndRedactOutput() throws {
        try withTemporaryDatabase { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"), lifecycleState: .running)],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = FakeApplyRuntimeAdapter(observedState: observed, logsText: "token=\(fakeSecret)\nready")

            let result = HostwrightCLI.run(
                arguments: ["logs", "api", "--tail", "5", "--state-db", databasePath],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardOutput.contains("Tail: 5"))
            XCTAssertTrue(result.standardOutput.contains("[REDACTED]"))
            XCTAssertFalse(result.standardOutput.contains(fakeSecret))
            XCTAssertEqual(adapter.logRequests, [RuntimeServiceIdentity(projectName: "demo", serviceName: "api")])
            let events = try SQLiteStateStore(path: databasePath).events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "logs.read" })
        }
    }

    func testLogsStateDatabaseFailureUsesStateExitCode() throws {
        try withTemporaryDirectory { directory in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"), lifecycleState: .running)],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = FakeApplyRuntimeAdapter(observedState: observed, logsText: "ready")

            let result = HostwrightCLI.run(
                arguments: ["logs", "api", "--state-db", directory.path],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertEqual(result.standardOutput, "")
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
            XCTAssertEqual(adapter.logRequests, [RuntimeServiceIdentity(projectName: "demo", serviceName: "api")])
        }
    }

    func testEventsCommandReadsStateLedgerDeterministically() throws {
        try withTemporaryDatabase { databasePath in
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            try store.events.append([
                EventRecord(id: "event-2", timestamp: "2026-07-01T00:00:02Z", severity: .warning, type: "logs.read", source: "test", projectID: "project-demo", serviceName: "api", runtimeAdapter: nil, message: "token=\(fakeSecret)", payloadJSONRedacted: "{}"),
                EventRecord(id: "event-1", timestamp: "2026-07-01T00:00:01Z", severity: .info, type: "status.observed", source: "test", projectID: "project-demo", serviceName: nil, runtimeAdapter: nil, message: "ok", payloadJSONRedacted: "{}")
            ])

            let result = HostwrightCLI.run(arguments: ["events", "--state-db", databasePath, "--project", "demo"], environment: environment(files: FileBox()))

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertLessThan(result.standardOutput.range(of: "status.observed")!.lowerBound, result.standardOutput.range(of: "logs.read")!.lowerBound)
            XCTAssertFalse(result.standardOutput.contains(fakeSecret))
        }
    }

    func testEventsJSONOutputIsOrderedAndRedacted() throws {
        try withTemporaryDatabase { databasePath in
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            try store.events.append([
                EventRecord(id: "event-2", timestamp: "2026-07-01T00:00:02Z", severity: .warning, type: "logs.read", source: "test", projectID: "project-demo", serviceName: "api", runtimeAdapter: nil, message: "token=\(fakeSecret)", payloadJSONRedacted: #"{"token":"\#(fakeSecret)"}"#),
                EventRecord(id: "event-1", timestamp: "2026-07-01T00:00:01Z", severity: .info, type: "status.observed", source: "test", projectID: "project-demo", serviceName: nil, runtimeAdapter: nil, message: "ok", payloadJSONRedacted: "{}")
            ])

            let result = HostwrightCLI.run(arguments: ["events", "--state-db", databasePath, "--project", "demo", "--output", "json"], environment: environment(files: FileBox()))

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertFalse(result.standardOutput.contains(fakeSecret))
            let json = try jsonObject(result.standardOutput)
            XCTAssertEqual(json["kind"] as? String, "events")
            let events = try XCTUnwrap(json["events"] as? [[String: Any]])
            XCTAssertEqual(events.map { $0["type"] as? String }, ["status.observed", "logs.read"])
            XCTAssertEqual(events.last?["message"] as? String, "token=[REDACTED]")
        }
    }

    func testRecoveryJSONOutputDistinguishesManualAndUnsupportedRecovery() throws {
        try withTemporaryDatabase { databasePath in
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

    func testRecoveryJSONOutputIncludesLegacyRestartRecoveryWhenNoOperationGroupExists() throws {
        try withTemporaryDatabase { databasePath in
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

    func testEventsCommandDoesNotCreateOrMigrateMissingStateDatabase() throws {
        try withTemporaryDatabase { databasePath in
            let result = HostwrightCLI.run(arguments: ["events", "--state-db", databasePath], environment: environment(files: FileBox()))

            XCTAssertEqual(result.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertEqual(result.standardOutput, "")
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
            XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath))
        }
    }

    func testRecoveryCommandDoesNotCreateOrMigrateMissingStateDatabase() throws {
        try withTemporaryDatabase { databasePath in
            let result = HostwrightCLI.run(arguments: ["recovery", "--state-db", databasePath], environment: environment(files: FileBox()))

            XCTAssertEqual(result.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertEqual(result.standardOutput, "")
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
            XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath))
        }
    }

    func testCleanupDryRunAndConfirmedDeleteOnlyEligibleStoppedOwnedContainers() throws {
        try withTemporaryDatabase { databasePath in
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
                    runtimeAdapter: "fake",
                    createdAt: "2026-07-01T00:00:00Z",
                    observedAt: "2026-07-01T00:00:00Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}"
                )
            )
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"), lifecycleState: .stopped)],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = FakeApplyRuntimeAdapter(observedState: observed)

            let dryRun = HostwrightCLI.run(
                arguments: ["cleanup", "--state-db", databasePath, "--dry-run"],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(dryRun.exitCode, 0)
            XCTAssertTrue(dryRun.standardOutput.contains("hostwright-demo-api"))
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

            XCTAssertEqual(confirmed.exitCode, 0)
            XCTAssertEqual(adapter.executedActions.map(\.kind), [.remove])
            let events = try SQLiteStateStore(path: databasePath).events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "cleanup.planned" })
            XCTAssertTrue(events.contains { $0.type == "cleanup.deleted" })
            XCTAssertLessThan(
                events.firstIndex { $0.type == "cleanup.planned" }!,
                events.firstIndex { $0.type == "cleanup.deleted" }!
            )
            let ownership = try SQLiteStateStore(path: databasePath).ownership.loadAll()
            XCTAssertEqual(ownership.count, 1)
            XCTAssertFalse(ownership[0].cleanupEligible)
        }
    }

    func testApplyPersistsFailureWithRedactedError() throws {
        try withTemporaryDatabase { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = FakeApplyRuntimeAdapter(executeError: .commandFailed(exitStatus: 2, message: "failed", standardError: "token=\(fakeSecret)"))
            let expectedHash = try planHash(for: singleServiceManifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertFalse(result.standardError.contains(fakeSecret))

            let store = SQLiteStateStore(path: databasePath)
            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations.map(\.status), [.recorded, .failed])
            let groups = try store.operationGroups.loadAll()
            XCTAssertEqual(groups.map(\.status), [.failed])
            XCTAssertEqual(groups[0].checkpoint, "runtime-failed")
            let steps = try store.operationGroupSteps.load(groupID: groups[0].id)
            XCTAssertEqual(steps.map(\.status), [.unsupported, .started, .failed])
            XCTAssertFalse(steps.map { $0.lastErrorRedacted ?? "" }.joined().contains(fakeSecret))

            let events = try store.events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "apply.failed" })
            XCTAssertFalse(events.map(\.message).joined(separator: "\n").contains(fakeSecret))
        }
    }

    func testApplyExecutesWithOriginalSecretEnvAndRedactsSurfaces() throws {
        try withTemporaryDatabase { databasePath in
            let manifest = """
            project: demo
            services:
              api:
                image: local/demo:latest
                env:
                  API_TOKEN: token=\(fakeSecret)
                ports:
                  - "8080:8080"

            """
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifest])
            let adapter = FakeApplyRuntimeAdapter()
            let expectedHash = try planHash(for: manifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertFalse(result.standardOutput.contains(fakeSecret))
            let executedService = try XCTUnwrap(adapter.executedActions.first?.desiredService)
            XCTAssertEqual(executedService.environment.first?.value, "token=\(fakeSecret)")

            let store = SQLiteStateStore(path: databasePath)
            let desired = try store.desiredStates.loadDesiredServices(projectID: "project-demo")
            XCTAssertTrue(desired[0].environmentJSONRedacted.contains("[REDACTED]"))
            XCTAssertFalse(desired[0].environmentJSONRedacted.contains(fakeSecret))
            let events = try store.events.loadAll()
            XCTAssertFalse(events.map(\.message).joined(separator: "\n").contains(fakeSecret))
        }
    }

    func testApplyIdempotencyBlocksDuplicateSucceededPlan() throws {
        try withTemporaryDatabase { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = FakeApplyRuntimeAdapter()
            let expectedHash = try planHash(for: singleServiceManifest, observed: adapter.observedState)

            let first = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )
            let second = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(first.exitCode, 0)
            XCTAssertEqual(second.exitCode, CLIExitCode.commandUsage.rawValue)
            XCTAssertTrue(second.standardError.contains("idempotency key"))
            XCTAssertEqual(adapter.executedActions.count, 1)
            XCTAssertEqual(try SQLiteStateStore(path: databasePath).operations.loadAll().map(\.status), [.recorded, .succeeded])
        }
    }

    func testApplyCanRetryAfterFailedOperationWithSamePlanHash() throws {
        try withTemporaryDatabase { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let failingAdapter = FakeApplyRuntimeAdapter(executeError: .commandFailed(exitStatus: 2, message: "failed", standardError: "token=\(fakeSecret)"))
            let expectedHash = try planHash(for: singleServiceManifest, observed: failingAdapter.observedState)

            let first = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: failingAdapter)
            )
            let retryAdapter = FakeApplyRuntimeAdapter(observedState: failingAdapter.observedState)
            let second = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: retryAdapter)
            )

            XCTAssertEqual(first.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertEqual(second.exitCode, 0)
            XCTAssertEqual(failingAdapter.executedActions.count, 1)
            XCTAssertEqual(retryAdapter.executedActions.count, 1)

            let store = SQLiteStateStore(path: databasePath)
            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations.map(\.status), [.recorded, .failed, .recorded, .succeeded])
            let idempotencyKey = try XCTUnwrap(operations.first?.idempotencyKey)
            XCTAssertEqual(try store.operations.latest(idempotencyKey: idempotencyKey)?.status, .succeeded)
        }
    }

    func testApplyObservationFailureIsRuntimeFailure() throws {
        try withTemporaryDatabase { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = FakeApplyRuntimeAdapter(observeError: .runtimeUnavailable("observe failed token=\(fakeSecret)"))

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

    func testApplyRuntimeFailureRemainsPrimaryWhenFailurePersistenceFails() throws {
        try withTemporaryDatabase { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = FakeApplyRuntimeAdapter(
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

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.runtimeUnavailable.rawValue))
            XCTAssertTrue(result.standardError.contains("Failure state persistence also failed"))
            XCTAssertFalse(result.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
            XCTAssertFalse(result.standardError.contains(fakeSecret))
        }
    }

    func testApplyRuntimeFailurePersistenceErrorStillFinishesOperationGroup() throws {
        try withTemporaryDatabase { databasePath in
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
            let adapter = FakeApplyRuntimeAdapter(
                executeError: .commandFailed(exitStatus: 2, message: "runtime failed", standardError: "token=\(fakeSecret)")
            )
            let expectedHash = try planHash(for: singleServiceManifest, observed: adapter.observedState)

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", expectedHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertTrue(result.standardError.contains("Failure state persistence also failed"))
            let groups = try store.operationGroups.loadAll()
            XCTAssertEqual(groups.map(\.status), [.failed])
            XCTAssertEqual(groups[0].checkpoint, "runtime-failed")
            let steps = try store.operationGroupSteps.load(groupID: groups[0].id)
            XCTAssertEqual(steps.map(\.status), [.unsupported, .started, .failed])
            XCTAssertFalse(groups[0].metadataJSONRedacted.contains(fakeSecret))
            XCTAssertFalse(steps.map(\.lastErrorRedacted).compactMap { $0 }.joined().contains(fakeSecret))
        }
    }

    func testCleanupPartialFailureReportsSuccessAndFailureAndPreservesOwnership() throws {
        try withTemporaryDatabase { databasePath in
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
                        runtimeAdapter: "fake",
                        createdAt: "2026-07-01T00:00:00Z",
                        observedAt: "2026-07-01T00:00:00Z",
                        cleanupEligible: true,
                        metadataJSONRedacted: "{}"
                    )
                )
            }
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"), lifecycleState: .stopped),
                    ObservedRuntimeService(identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "worker"), lifecycleState: .stopped)
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let secret = fakeSecret
            let adapter = FakeApplyRuntimeAdapter(
                observedState: observed,
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
            XCTAssertFalse(try XCTUnwrap(ownership.first { $0.serviceName == "api" }).cleanupEligible)
            XCTAssertTrue(try XCTUnwrap(ownership.first { $0.serviceName == "worker" }).cleanupEligible)
        }
    }

    private final class FileBox {
        var files: [String: String]

        init(files: [String: String] = [:]) {
            self.files = files
        }
    }

    private let fakeSecret = "plain-secret-token"

    private var singleServiceManifest: String {
        """
        project: demo
        services:
          api:
            image: local/demo:latest
            command: ["serve"]
            env:
              APP_ENV: development
            ports:
              - "8080:8080"

        """
    }

    private var restartableServiceManifest: String {
        """
        project: demo
        services:
          api:
            image: local/demo:latest
            ports:
              - "8080:8080"
            restart:
              policy: on-failure

        """
    }

    private var managedRestartHealthManifest: String {
        """
        project: demo
        services:
          api:
            image: local/demo:latest
            ports:
              - "8080:8080"
            health:
              command: ["false"]
              interval: 60s
            restart:
              policy: on-failure

        """
    }

    private var twoServiceManifest: String {
        """
        project: demo
        services:
          api:
            image: local/demo:latest
            ports:
              - "8080:8080"
          worker:
            image: local/worker:latest
            ports:
              - "8081:8080"

        """
    }

    private var fakeAdapterMetadata: RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            adapterName: "fake-apply-adapter",
            adapterVersion: "test",
            runtimeName: "fake-runtime",
            runtimeVersion: nil,
            supportsMutation: true,
            capabilities: [.readOnlyObservation, .lifecycleMutation, .logStreaming, .cleanup]
        )
    }

    private func environment(
        files: FileBox,
        containerPath: String? = nil,
        runtimeAdapter: (any RuntimeAdapter)? = nil,
        platform: PlatformSnapshot = PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64")
    ) -> CLIEnvironment {
        CLIEnvironment(
            fileExists: { files.files[$0] != nil },
            readTextFile: { path in
                guard let text = files.files[path] else {
                    throw CLIUsageError("missing file")
                }
                return text
            },
            writeTextFile: { path, text in
                files.files[path] = text
            },
            executablePath: { name in name == "container" ? containerPath : "/usr/bin/\(name)" },
            runtimeAdapter: { runtimeAdapter ?? FakeApplyRuntimeAdapter() },
            swiftVersion: { "Swift 6.3.2" },
            platformSnapshot: { platform },
            operatingSystemDescription: { "macOS 26.5" }
        )
    }

    private func planHash(for manifestText: String, observed: ObservedRuntimeState) throws -> String {
        let manifest = try ManifestValidator.validated(manifestText)
        return ReconciliationPlanner().plan(manifest: manifest, observedState: observed).planHash
    }

    private func planHash(fromStatusOutput output: String) throws -> String {
        let line = try XCTUnwrap(output.split(separator: "\n").first { $0.hasPrefix("Plan hash: ") })
        return String(line.replacingOccurrences(of: "Plan hash: ", with: ""))
    }

    private func withTemporaryDatabase(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-cli-xctest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory.appendingPathComponent("state.sqlite").path)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-cli-xctest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory)
    }

    private func saveDesiredManifest(store: SQLiteStateStore, manifestText: String) throws {
        try store.desiredStates.saveManifestSnapshot(
            projectID: "project-demo",
            manifestPath: HostwrightIdentity.manifestFileName,
            manifestHash: "manifest-hash",
            desiredGeneration: 1,
            manifest: try ManifestValidator.validated(manifestText),
            timestamp: "2026-07-01T00:00:00Z"
        )
    }

    private func saveOwnership(store: SQLiteStateStore) throws {
        try store.ownership.upsert(
            OwnershipRecord(
                id: "ownership-api",
                resourceIdentifier: "hostwright-demo-api",
                resourceType: "container",
                projectID: "project-demo",
                serviceName: "api",
                runtimeAdapter: "runtime-adapter",
                createdAt: "2026-07-01T00:00:00Z",
                observedAt: "2026-07-01T00:00:00Z",
                cleanupEligible: true,
                metadataJSONRedacted: "{}"
            )
        )
    }

    private func saveFreshUnhealthyHealthResult(store: SQLiteStateStore) throws {
        try store.healthResults.append([
            HealthCheckResultRecord(
                id: hostwrightUniqueID(prefix: "health-api"),
                projectID: "project-demo",
                serviceName: "api",
                checkedAt: hostwrightTimestamp(),
                status: .unhealthy,
                exitStatus: 1,
                timedOut: false,
                commandJSONRedacted: #"["false"]"#,
                stdoutRedacted: "",
                stderrRedacted: "",
                metadataJSONRedacted: "{}"
            )
        ])
    }

    private func runningObservedService(
        healthState: RuntimeHealthState,
        lifecycleState: RuntimeLifecycleState = .running
    ) -> ObservedRuntimeState {
        ObservedRuntimeState(
            projectName: "demo",
            services: [
                ObservedRuntimeService(
                    identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                    image: "local/demo:latest",
                    lifecycleState: lifecycleState,
                    healthState: healthState
                )
            ],
            adapterMetadata: fakeAdapterMetadata
        )
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private final class FakeApplyRuntimeAdapter: RuntimeAdapter, @unchecked Sendable {
        typealias ExecuteHook = @Sendable (PlannedRuntimeAction) throws -> Void

        let observedState: ObservedRuntimeState
        let observeError: RuntimeAdapterError?
        let executeError: RuntimeAdapterError?
        let logsText: String
        let onExecute: ExecuteHook?
        var executedActions: [PlannedRuntimeAction] = []
        var logRequests: [RuntimeServiceIdentity] = []

        init(
            observedState: ObservedRuntimeState? = nil,
            observeError: RuntimeAdapterError? = nil,
            executeError: RuntimeAdapterError? = nil,
            logsText: String = "",
            onExecute: ExecuteHook? = nil
        ) {
            self.observedState = observedState ?? ObservedRuntimeState(
                projectName: "demo",
                services: [],
                adapterMetadata: RuntimeAdapterMetadata(
                    adapterName: "fake-apply-adapter",
                    adapterVersion: "test",
                    runtimeName: "fake-runtime",
                    runtimeVersion: nil,
                    supportsMutation: true,
                    capabilities: [.readOnlyObservation, .lifecycleMutation, .logStreaming, .cleanup]
                )
            )
            self.observeError = observeError
            self.executeError = executeError
            self.logsText = logsText
            self.onExecute = onExecute
        }

        func metadata() async -> RuntimeAdapterMetadata {
            observedState.adapterMetadata!
        }

        func capabilities() async throws -> [RuntimeCapability] {
            [.readOnlyObservation, .lifecycleMutation, .logStreaming, .cleanup]
        }

        func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
            if let observeError {
                throw observeError
            }
            return observedState
        }

        func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
            RuntimePlan(actions: [])
        }

        func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
            executedActions.append(action)
            try onExecute?(action)
            if let executeError {
                throw executeError
            }
            return RuntimeEvent(
                identity: action.identity,
                message: "\(action.kind.rawValue) token=plain-secret-token",
                resourceIdentifier: action.identity.managedResourceIdentifier
            )
        }

        func logs(for identity: RuntimeServiceIdentity, tail: Int) async throws -> RuntimeLogResult {
            logRequests.append(identity)
            return RuntimeLogResult(identity: identity, text: RuntimeRedactionPolicy.default.redact(logsText), lineLimit: min(max(1, tail), 1_000))
        }
    }
}
