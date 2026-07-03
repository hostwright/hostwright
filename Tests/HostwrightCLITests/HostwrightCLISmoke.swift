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
        XCTAssertEqual(try CLICommand.parse(arguments: ["status"]), .status(path: "hostwright.yaml"))
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["apply", "--state-db", "/tmp/state.sqlite", "--confirm-plan", "abc123"]),
            .apply(path: "hostwright.yaml", stateDatabasePath: "/tmp/state.sqlite", confirmedPlanHash: "abc123")
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["apply", "custom.yaml", "--state-db", "/tmp/state.sqlite", "--confirm-plan", "abc123"]),
            .apply(path: "custom.yaml", stateDatabasePath: "/tmp/state.sqlite", confirmedPlanHash: "abc123")
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
        XCTAssertEqual(result.standardOutput, "0.0.0-dev\n")
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
        XCTAssertTrue(planResult.standardOutput.contains("Execution: unavailable until Phase 8"))
        XCTAssertTrue(planResult.standardOutput.contains("No runtime actions were executed"))

        let statusResult = HostwrightCLI.run(arguments: ["status"], environment: environment(files: validFiles))
        XCTAssertEqual(statusResult.exitCode, 0)
        XCTAssertTrue(statusResult.standardOutput.contains("Manifest: hostwright.yaml valid"))
        XCTAssertTrue(statusResult.standardOutput.contains("Runtime: unavailable"))
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
            XCTAssertTrue(events.contains { $0.type == "apply.started" })
            XCTAssertTrue(events.contains { $0.type == "apply.succeeded" })

            let ownership = try store.ownership.loadAll()
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

    private final class FakeApplyRuntimeAdapter: RuntimeAdapter, @unchecked Sendable {
        let observedState: ObservedRuntimeState
        let executeError: RuntimeAdapterError?
        var executedActions: [PlannedRuntimeAction] = []

        init(executeError: RuntimeAdapterError? = nil) {
            self.observedState = ObservedRuntimeState(
                projectName: "demo",
                services: [],
                adapterMetadata: RuntimeAdapterMetadata(
                    adapterName: "fake-apply-adapter",
                    adapterVersion: "test",
                    runtimeName: "fake-runtime",
                    runtimeVersion: nil,
                    supportsMutation: true,
                    capabilities: [.readOnlyObservation, .lifecycleMutation]
                )
            )
            self.executeError = executeError
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
            executedActions.append(action)
            if let executeError {
                throw executeError
            }
            return RuntimeEvent(
                identity: action.identity,
                message: "created token=plain-secret-token",
                resourceIdentifier: "hostwright-test://\(action.identity.displayName)"
            )
        }
    }
}
