import Darwin
import Foundation
import XCTest
@testable import HostwrightCommandTransport
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore
import HostwrightDaemonCore
import HostwrightObservability
import HostwrightState

final class BootstrapControlAPITests: XCTestCase {
    func testBootstrapEntryPointsRejectEachOthersCommands() throws {
        for (arguments, offline) in [(["daemon", "status"], true), (["state", "recover"], false)] {
            let route = try CLIControlRoute.classify(arguments: arguments)
            let request = ControlRequestEnvelope(
                requestID: "wrong-entry", operation: route.operation, timeoutMilliseconds: 1_000,
                idempotencyKey: route.mutating ? "wrong-entry" : nil, body: route.requestBody()
            )
            let data = try ControlPlaneCanonicalJSON.encode(request)
            let response = try decode(offline
                ? BootstrapControlAPI.runOfflineRecovery(requestData: data)
                : BootstrapControlAPI.run(requestData: data))
            XCTAssertEqual(response.status, .rejected)
            XCTAssertEqual(response.reasonCode, .invalidRequest)
        }
    }

    func testOfflineRestorePreservesConfirmationAndRefusesLiveDaemonOrStaleState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-bootstrap-restore-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        let maintenance = try StateMaintenanceService(store: store)
        let backup = try maintenance.createBackup()
        func send(_ confirmation: [String]) throws -> CLIRunResult {
            let route = try CLIControlRoute.classify(arguments: [
                "state", "restore", "--backup", backup.backupID,
                "--state-db", store.path, "--json"
            ] + confirmation)
            let request = ControlRequestEnvelope(
                requestID: "offline-restore", operation: route.operation,
                timeoutMilliseconds: 1_000, idempotencyKey: "offline-restore",
                body: route.requestBody()
            )
            return try CLIControlResultContract.result(from: decode(BootstrapControlAPI.runOfflineRecovery(
                requestData: ControlPlaneCanonicalJSON.encode(request)
            )))
        }
        let daemon = try maintenance.acquireDaemonLease()
        let refused = try send(["--dry-run"])
        XCTAssertEqual(refused.exitCode, CLIExitCode.stateUnavailable.rawValue)
        XCTAssertTrue(refused.standardError.contains("stop hostwrightd"))
        daemon.release()
        let preview = try send(["--dry-run"])
        XCTAssertEqual(preview.exitCode, 0, preview.standardError)
        let plan = try JSONDecoder().decode(StateRestorePlan.self, from: Data(preview.standardOutput.utf8))
        try store.events.append([EventRecord(
            id: "after-preview", timestamp: "2026-09-23T12:00:00Z", severity: .info,
            type: "state.test", source: "bootstrap-test", projectID: nil, serviceName: nil,
            runtimeAdapter: nil, message: "state changed", payloadJSONRedacted: "{}"
        )])
        XCTAssertNotEqual(try send(["--confirm-restore", plan.confirmationToken]).exitCode, 0)
        XCTAssertTrue(try store.events.loadAll().contains { $0.id == "after-preview" })
        let fresh = try send(["--dry-run"])
        let freshPlan = try JSONDecoder().decode(StateRestorePlan.self, from: Data(fresh.standardOutput.utf8))
        let restored = try send(["--confirm-restore", freshPlan.confirmationToken])
        XCTAssertEqual(restored.exitCode, 0, restored.standardError)
        XCTAssertFalse(try store.events.loadAll().contains { $0.id == "after-preview" })
        XCTAssertEqual(maintenance.integrity().health, .healthy)
    }

    func testDockerEnvelopeCannotSmuggleCommandsThroughBootstrapTransport() throws {
        for arguments in [["daemon", "stop"], ["state", "backup"], ["capabilities"]] {
            let route = try CLIControlRoute.docker(
                operation: "capabilities", endpoint: "version", arguments: arguments
            )
            let request = ControlRequestEnvelope(
                requestID: "bootstrap-docker-smuggling", operation: route.operation,
                timeoutMilliseconds: 1_000, body: route.requestBody()
            )
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "hostwright-bootstrap-rejection-\(UUID().uuidString)", isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: root) }
            var environment = try daemonEnvironment(home: root)
            let isolatedController = environment.daemonLifecycleController
            environment.daemonLifecycleController = {
                XCTFail("A Docker envelope must not reach daemon lifecycle execution")
                return isolatedController()
            }
            environment.localPathResolution = { _ in
                XCTFail("A Docker envelope must not resolve or access local state")
                throw HostwrightDiagnostic(code: .daemonDenied, message: "unexpected state access")
            }
            XCTAssertThrowsError(try CLIControlRoute.validate(
                request: request, expectedTransport: .bootstrapAPI
            ))
            let response = try decode(BootstrapControlAPI.run(
                requestData: try ControlPlaneCanonicalJSON.encode(request), environment: environment
            ))
            XCTAssertEqual(response.status, .rejected)
            XCTAssertEqual(response.reasonCode, .invalidRequest)
            XCTAssertEqual(response.error?.code, "HW-API-001")
        }
    }

    func testEmptyRequestIsRejectedAndMalformedRequestMapsToSafeInternalFailure() throws {
        let empty = try decode(BootstrapControlAPI.run(requestData: Data()))
        XCTAssertEqual(empty.requestID, "bootstrap-invalid")
        XCTAssertEqual(empty.status, .rejected)
        XCTAssertEqual(empty.reasonCode, .invalidRequest)

        let malformed = try decode(BootstrapControlAPI.run(requestData: Data("not-json".utf8)))
        XCTAssertEqual(malformed.requestID, "bootstrap-invalid")
        XCTAssertEqual(malformed.status, .error)
        XCTAssertEqual(malformed.reasonCode, .internalError)
        XCTAssertEqual(malformed.error?.code, "HW-API-003")
    }

    func testPersistentRouteIsRejectedBeforeAnyCommandExecution() throws {
        let persistentRoute = try CLIControlRoute.classify(arguments: ["capabilities"])
        let request = ControlRequestEnvelope(
            requestID: "bootstrap-1",
            operation: persistentRoute.operation,
            timeoutMilliseconds: 1_000,
            body: persistentRoute.requestBody()
        )

        let response = try decode(BootstrapControlAPI.run(
            requestData: try ControlPlaneCanonicalJSON.encode(request)
        ))
        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.status, .rejected)
        XCTAssertEqual(response.reasonCode, .invalidRequest)
        XCTAssertEqual(response.error?.code, "HW-API-001")
    }

    func testBootstrapRepairAndUninstallPreserveDirectCLIResults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-bootstrap-parity-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let cases = [
            [
                "daemon", "install",
                "--daemon-executable", root.appendingPathComponent("missing-hostwrightd").path,
                "--config", root.appendingPathComponent("missing-hostwright.yaml").path,
            ],
            ["daemon", "repair"],
            ["daemon", "repair", "--json"],
            ["daemon", "uninstall"],
            ["daemon", "uninstall", "--json"],
        ]
        for (index, arguments) in cases.enumerated() {
            let directEnvironment = try daemonEnvironment(
                home: root.appendingPathComponent("direct-\(index)", isDirectory: true)
            )
            let bootstrapEnvironment = try daemonEnvironment(
                home: root.appendingPathComponent("bootstrap-\(index)", isDirectory: true)
            )
            let direct = HostwrightCLI.run(
                arguments: arguments,
                environment: directEnvironment
            )
            let route = try CLIControlRoute.classify(arguments: arguments)
                .withWorkingDirectory(root.path)
            let request = ControlRequestEnvelope(
                requestID: "bootstrap-parity-\(index)",
                operation: route.operation,
                timeoutMilliseconds: 1_000,
                idempotencyKey: "bootstrap-parity-\(index)",
                body: route.requestBody()
            )
            let response = try decode(BootstrapControlAPI.run(
                requestData: try ControlPlaneCanonicalJSON.encode(request),
                environment: bootstrapEnvironment
            ))

            XCTAssertEqual(
                try CLIControlResultContract.result(from: response),
                direct,
                arguments.joined(separator: " ")
            )
        }
    }

    private func decode(_ data: Data) throws -> ControlResponseEnvelope {
        try JSONDecoder().decode(ControlResponseEnvelope.self, from: data)
    }

    private func daemonEnvironment(home: URL) throws -> CLIEnvironment {
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard let resolved = realpath(home.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        let layout = DaemonLifecycleLayout(
            homeDirectory: String(cString: resolved),
            userID: UInt32(geteuid())
        )
        let resolution = try HostwrightLocalPathResolver.resolve(
            explicitStateDatabasePath: home.appendingPathComponent("state.sqlite").path,
            homeDirectory: home.path,
            environment: [:]
        )
        return CLIEnvironment(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            readTextFile: { try String(contentsOfFile: $0, encoding: .utf8) },
            writeTextFile: { path, text in
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            },
            executablePath: { _ in nil },
            localPathResolution: { _ in resolution },
            swiftVersion: { "Swift bootstrap parity" },
            platformSnapshot: {
                PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64")
            },
            operatingSystemDescription: { "macOS bootstrap parity" },
            daemonLifecycleController: {
                DaemonLifecycleController(
                    layout: layout,
                    dependencies: DaemonLifecycleDependencies(
                        runLaunchctl: { _, _ in .notFound },
                        processInventory: { [] },
                        timestamp: { "2026-08-03T00:00:00Z" },
                        operationID: { "00000000-0000-4000-8000-000000000009" }
                    )
                )
            },
            observabilitySink: DisabledHostwrightLogSink(),
            observabilityCorrelationID: { "bootstrap-parity" }
        )
    }
}
