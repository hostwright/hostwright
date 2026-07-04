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
        XCTAssertEqual(try CLICommand.parse(arguments: ["plan"]), .plan(path: "hostwright.yaml"))
        XCTAssertEqual(try CLICommand.parse(arguments: ["status"]), .status(path: "hostwright.yaml", stateDatabasePath: nil))
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["status", "--state-db", "/tmp/state.sqlite"]),
            .status(path: "hostwright.yaml", stateDatabasePath: "/tmp/state.sqlite")
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
            .events(stateDatabasePath: "/tmp/state.sqlite", projectName: "demo")
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["cleanup", "--state-db", "/tmp/state.sqlite", "--dry-run"]),
            .cleanup(path: "hostwright.yaml", stateDatabasePath: "/tmp/state.sqlite", confirmation: .dryRun)
        )
        XCTAssertEqual(try CLICommand.parse(arguments: ["doctor"]), .doctor)
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

    func testInitCreatesStarterManifestWithoutOverwriting() {
        let initFiles = FileBox()
        let initResult = HostwrightCLI.run(arguments: ["init"], environment: environment(files: initFiles))

        XCTAssertEqual(initResult.exitCode, 0)
        XCTAssertTrue(initFiles.files[HostwrightIdentity.manifestFileName]?.contains("project: api-local") == true)

        let existingFiles = FileBox(files: [HostwrightIdentity.manifestFileName: "project: existing\nservices:\n"])
        let overwriteResult = HostwrightCLI.run(arguments: ["init"], environment: environment(files: existingFiles))

        XCTAssertEqual(overwriteResult.exitCode, 1)
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
        XCTAssertTrue(planResult.standardOutput.contains("Execution: unavailable unless one createMissingService or startManagedService action is explicitly confirmed"))
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

    func testDoctorReportsMissingAppleContainerAsWarning() {
        let result = HostwrightCLI.run(arguments: ["doctor"], environment: environment(files: FileBox()))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("[warning] appleContainerCLI"))
    }

    func testApplyRefusesWrongPlanHashBeforeMutation() throws {
        try withTemporaryDatabase { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let adapter = FakeApplyRuntimeAdapter()

            let result = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", "wrong-hash"],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, 1)
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
            XCTAssertEqual(operations.count, 1)
            XCTAssertEqual(operations[0].status, .succeeded)
            XCTAssertEqual(operations[0].planHash, expectedHash)

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

            let events = try SQLiteStateStore(path: databasePath).events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "apply.started-service" })
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

            XCTAssertEqual(result.exitCode, 1)
            XCTAssertFalse(result.standardError.contains(fakeSecret))

            let store = SQLiteStateStore(path: databasePath)
            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations[0].status, .failed)

            let events = try store.events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "apply.failed" })
            XCTAssertFalse(events.map(\.message).joined(separator: "\n").contains(fakeSecret))
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

    private func environment(files: FileBox, containerPath: String? = nil, runtimeAdapter: (any RuntimeAdapter)? = nil) -> CLIEnvironment {
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
            platformSnapshot: { PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64") },
            operatingSystemDescription: { "macOS 26.5" }
        )
    }

    private func planHash(for manifestText: String, observed: ObservedRuntimeState) throws -> String {
        let manifest = try ManifestValidator.validated(manifestText)
        return ReconciliationPlanner().plan(manifest: manifest, observedState: observed).planHash
    }

    private func withTemporaryDatabase(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-cli-xctest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory.appendingPathComponent("state.sqlite").path)
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

    private final class FakeApplyRuntimeAdapter: RuntimeAdapter, @unchecked Sendable {
        let observedState: ObservedRuntimeState
        let executeError: RuntimeAdapterError?
        let logsText: String
        var executedActions: [PlannedRuntimeAction] = []
        var logRequests: [RuntimeServiceIdentity] = []

        init(
            observedState: ObservedRuntimeState? = nil,
            executeError: RuntimeAdapterError? = nil,
            logsText: String = ""
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
            self.executeError = executeError
            self.logsText = logsText
        }

        func metadata() async -> RuntimeAdapterMetadata {
            observedState.adapterMetadata!
        }

        func capabilities() async throws -> [RuntimeCapability] {
            [.readOnlyObservation, .lifecycleMutation, .logStreaming, .cleanup]
        }

        func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
            observedState
        }

        func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
            RuntimePlan(actions: [])
        }

        func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
            executedActions.append(action)
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
