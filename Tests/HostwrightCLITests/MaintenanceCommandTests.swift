import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightManifest
@testable import HostwrightState

final class MaintenanceCommandTests: XCTestCase {
    func testParserRecognizesStrictMaintenanceSurface() throws {
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "maintenance", "preview", "hostwright.yaml",
                "--action", "create", "--action", "start",
                "--at", "2026-08-02T04:00:00Z", "--json"
            ]),
            .maintenance(options: MaintenanceCLIOptions(
                action: .preview(
                    manifestPath: "hostwright.yaml",
                    actions: ["create", "start"],
                    at: "2026-08-02T04:00:00Z"
                ),
                stateDatabasePath: nil,
                output: .json
            ))
        )
        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "maintenance", "override", "--project", "project-demo",
            "--confirm-deferral", String(repeating: "a", count: 64)
        ]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "maintenance", "preview", "hostwright.yaml", "--action", "recovery"
        ]))
    }

    func testPreviewJSONIsReadOnlyAndVersioned() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try MaintenanceCommandRunner(
            options: MaintenanceCLIOptions(
                action: .preview(
                    manifestPath: fixture.manifestPath,
                    actions: ["create"],
                    at: "2026-08-02T04:05:00Z"
                ),
                stateDatabasePath: fixture.databasePath,
                output: .json
            ),
            stateStoreConfiguration: StateStoreConfiguration(explicitDatabasePath: fixture.databasePath),
            environment: .live
        ).run()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let decision = try XCTUnwrap(object["decision"] as? [String: Any])
        XCTAssertEqual(decision["admitted"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.databasePath))
    }

    func testStatusCancelAndOverrideRequireExactCurrentToken() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = SQLiteStateStore(path: fixture.databasePath)
        try store.migrate()
        let pending = try store.maintenanceDeferrals.deferPlan(
            projectID: "project-demo",
            planSHA256: String(repeating: "a", count: 64),
            policySHA256: String(repeating: "b", count: 64),
            actionClasses: [.create],
            firstDeferredAt: "2026-08-01T12:00:00Z",
            deadlineAt: "2026-08-02T12:00:00Z",
            reasonRedacted: "outside window"
        )
        let configuration = StateStoreConfiguration(explicitDatabasePath: fixture.databasePath)
        let status = try MaintenanceCommandRunner(
            options: MaintenanceCLIOptions(
                action: .status(projectID: "project-demo"),
                stateDatabasePath: fixture.databasePath,
                output: .json
            ),
            stateStoreConfiguration: configuration,
            environment: .live
        ).run()
        XCTAssertTrue(status.standardOutput.contains(pending.confirmationToken))

        XCTAssertThrowsError(try MaintenanceCommandRunner(
            options: MaintenanceCLIOptions(
                action: .cancel(projectID: "project-demo", confirmationToken: String(repeating: "c", count: 64)),
                stateDatabasePath: fixture.databasePath,
                output: .json
            ),
            stateStoreConfiguration: configuration,
            environment: .live
        ).run())

        let override = try MaintenanceCommandRunner(
            options: MaintenanceCLIOptions(
                action: .override(
                    projectID: "project-demo",
                    confirmationToken: pending.confirmationToken,
                    reason: "urgent owned-service repair"
                ),
                stateDatabasePath: fixture.databasePath,
                output: .json
            ),
            stateStoreConfiguration: configuration,
            environment: .live
        ).run()
        XCTAssertTrue(override.standardOutput.contains("override-authorized"))
        XCTAssertThrowsError(try MaintenanceCommandRunner(
            options: MaintenanceCLIOptions(
                action: .override(
                    projectID: "project-demo",
                    confirmationToken: pending.confirmationToken,
                    reason: "duplicate"
                ),
                stateDatabasePath: fixture.databasePath,
                output: .json
            ),
            stateStoreConfiguration: configuration,
            environment: .live
        ).run())
    }
}

private struct Fixture {
    let root: URL
    let manifestPath: String
    let databasePath: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        manifestPath = root.appendingPathComponent("hostwright.yaml").path
        databasePath = root.appendingPathComponent("state.sqlite").path
        try """
        version: 3
        project: demo
        maintenance:
          timezone: UTC
          windows:
            - id: release
              actions:
                - create
              oneShot:
                startsAt: "2026-08-02T04:00:00Z"
                duration: 1800s
        services:
          api:
            image: local/api:latest
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
        """.write(toFile: manifestPath, atomically: true, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
