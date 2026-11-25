import Foundation
import HostwrightRuntime
import XCTest

#if HOSTWRIGHT_TEST_RUNTIME
import HostwrightCLI
import HostwrightState
@testable import HostwrightDaemon
#endif

final class TestRuntimeFlavorTests: XCTestCase {
    func testNormalProviderCatalogStaysClosed() {
        XCTAssertEqual(RuntimeProviderID.knownValues, [.appleContainerCLI, .appleContainerization])
    }

    #if HOSTWRIGHT_TEST_RUNTIME
    func testFlaggedDaemonReconcilesAndReopensItsNodeHomeWithoutContainerTools() async throws {
        let home = try makeNodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let arguments = try nodeArguments(home, iterations: 2)
        let node = try HostwrightTestRuntimeCommand.node(arguments: arguments)
        let store = SQLiteStateStore(configuration: node.configuration.stateStoreConfiguration)
        try store.migrate()
        let runtime = node.runtime
        let manifest = try String(contentsOfFile: node.configuration.configPath, encoding: .utf8)
        try seedDaemonSchedulerAuthority(
            databasePath: node.configuration.stateDatabasePath,
            manifestText: manifest,
            manifestPath: node.configuration.configPath
        )
        let result = try runDaemon(
            arguments: ["--test-runtime"] + arguments,
            environment: ["HOME": home.path, "PATH": home.path]
        )
        guard result.status == 0, result.output.contains("Successful: 2"),
              result.output.contains("Failed: 0") else {
            let diagnostics = try store.events.loadAll().map(\.message).joined(separator: "\n")
            XCTFail(result.output + diagnostics)
            return
        }

        let actions = try await runtime.recordedActions()
        XCTAssertEqual(actions.filter { $0.kind == "create" }.map(\.service).sorted(), ["api", "web"])
        XCTAssertEqual(actions.filter { $0.kind == "start" }.map(\.service).sorted(), ["api", "web"])
        XCTAssertEqual(actions.count, 4)
        let metadata = await runtime.metadata()
        XCTAssertEqual(metadata.runtimeName, "hostwright-test-recording-v1")
        XCTAssertNil(RuntimeProviderCompatibility.mutationIncompatibility(metadata))

        let restarted = try runDaemon(
            arguments: ["--test-runtime"] + arguments,
            environment: ["HOME": home.path, "PATH": home.path]
        )
        XCTAssertEqual(restarted.status, 0, restarted.output)
        XCTAssertTrue(restarted.output.contains("Successful: 2"), restarted.output)
        let afterRestart = try await runtime.recordedActions()
        XCTAssertEqual(afterRestart, actions)

        let down = ["down", node.configuration.configPath, "--output", "json"]
        let plan = await runLifecycleCommand(down + ["--dry-run"], environment: node.environment)
        XCTAssertEqual(plan.exitCode, 0, plan.standardError)
        let envelope = try JSONDecoder().decode(PlanOutput.self, from: Data(plan.standardOutput.utf8))
        let resultDown = await runLifecycleCommand(
            down + ["--confirm-plan", envelope.planSHA256], environment: node.environment
        )
        XCTAssertEqual(resultDown.exitCode, 0, resultDown.standardError + resultDown.standardOutput)
        let observed = try await runtime.observe(
            desiredState: DesiredRuntimeState(projectName: "rehearsal", services: [])
        )
        XCTAssertEqual(observed.services.count, 2)
        XCTAssertTrue(observed.services.allSatisfy { $0.lifecycleState == .stopped })
        let afterDown = try await runtime.recordedActions()
        XCTAssertEqual(afterDown.filter { $0.kind == "stop" }.map(\.service).sorted(), ["api", "web"])

        let secondHome = try makeNodeHome()
        defer { try? FileManager.default.removeItem(at: secondHome) }
        let second = HostwrightTestRecordingRuntime(homeDirectory: secondHome)
        let secondActions = try await second.recordedActions()
        XCTAssertTrue(secondActions.isEmpty)
    }

    func testFlaggedDaemonRequiresDedicatedForegroundNodeAndRejectsStateOverrides() throws {
        let home = try makeNodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let arguments = try nodeArguments(home, iterations: 1)
        let service = try runDaemon(
            arguments: ["--test-runtime"] + arguments.map { $0 == "--foreground" ? "--service" : $0 }
        )
        XCTAssertEqual(service.status, 64, service.output)
        let override = try runDaemon(
            arguments: ["--test-runtime"] + arguments + ["--state-db", "/unused/state.sqlite"]
        )
        XCTAssertEqual(override.status, 64, override.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("support").path))
    }

    func testRecordingMutationRequiresConfirmationAndCurrentActivationAuthority() async throws {
        let home = try makeNodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runtime = HostwrightTestRecordingRuntime(homeDirectory: home)
        let identity = RuntimeServiceIdentity(projectName: "rehearsal", serviceName: "api")
        let desired = DesiredRuntimeService(identity: identity, image: "registry.invalid/api@sha256:" + String(repeating: "a", count: 64))
        let action = PlannedRuntimeAction(
            kind: .create, identity: identity, resourceIdentifier: identity.managedResourceIdentifier,
            isDestructive: false, summary: "test create", desiredService: desired
        )
        do {
            _ = try await runtime.execute(action, confirmation: nil)
            XCTFail("Recording mutation accepted no confirmation.")
        } catch RuntimeAdapterError.mutationUnavailableByPolicy {}
        do {
            _ = try await RuntimeActivationAuthority.$validator.withValue({ throw StaleFence.rejected }) {
                try await runtime.execute(action, confirmation: RuntimeMutationConfirmation(confirmed: true, reason: "test"))
            }
            XCTFail("Recording mutation accepted a stale activation authority.")
        } catch is RuntimeActivationAuthorityRejection {}
        let actions = try await runtime.recordedActions()
        XCTAssertTrue(actions.isEmpty)
    }

    private func makeNodeHome() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("hw-r-\(UUID().uuidString.prefix(10))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        return home
    }

    private func nodeArguments(_ home: URL, iterations: Int) throws -> [String] {
        let manifest = home.appendingPathComponent("hostwright.yaml")
        let digest = String(repeating: "a", count: 64)
        try """
            version: 3
            project: rehearsal
            imagePolicy: require-digest
            services:
              web:
                image: registry.invalid/web@sha256:\(digest)
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
              api:
                image: registry.invalid/api@sha256:\(digest)
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """.write(to: manifest, atomically: true, encoding: .utf8)
        return [
            "--node-home", home.path, "--foreground", "--config", manifest.path,
            "--max-iterations", String(iterations), "--interval", "1"
        ]
    }

    private func runLifecycleCommand(_ arguments: [String], environment: CLIEnvironment) async -> CLIRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: HostwrightCLI.run(arguments: arguments, environment: environment))
            }
        }
    }

    private struct PlanOutput: Decodable { let planSHA256: String }
    private enum StaleFence: Error { case rejected }
    #else
    func testDefaultDaemonRefusesRecordingRuntime() throws {
        let result = try runDaemon(arguments: ["--test-runtime", "--foreground", "--config", "/unused/manifest.yaml"])
        XCTAssertEqual(result.status, 64, result.output)
        XCTAssertTrue(result.output.contains("Unsupported argument '--test-runtime'"), result.output)
    }
    #endif

    private func runDaemon(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("hostwrightd")
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
