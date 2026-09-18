import Darwin
import Foundation
import XCTest
@testable import HostwrightCLI
import HostwrightCore
import HostwrightDaemonCore

final class DaemonLifecycleCLITests: XCTestCase {
    func testManagedInstallUpgradeAndRepairValidateIdentityPathsWithoutBootstrapping() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-managed-bootstrap-\(UUID().uuidString)", isDirectory: true
        )
        let controller = DaemonLifecycleController(
            layout: DaemonLifecycleLayout(homeDirectory: root.path, userID: UInt32(geteuid())),
            dependencies: DaemonLifecycleDependencies(
                runLaunchctl: { _, _ in
                    XCTFail("Invalid identity paths must precede launchctl")
                    return .notFound
                },
                processInventory: {
                    XCTFail("Invalid identity paths must precede service inspection")
                    return []
                },
                timestamp: { "2026-09-13T17:00:00Z" },
                operationID: { "00000000-0000-4000-8000-000000000001" }
            )
        )
        for operation in [DaemonLifecycleOperation.install, .upgrade, .repair] {
            var selectedModes: [Bool] = []
            let runner = DaemonLifecycleCommandRunner(
                options: DaemonCLIOptions(
                    action: .lifecycle(operation), daemonExecutablePath: "/opt/hostwright/bin/hostwrightd",
                    configPath: "/Users/example/hostwright.yaml", output: .json
                ),
                controller: controller,
                controlIdentityBootstrap: { managed in
                    selectedModes.append(managed)
                    XCTFail("Rejected paths must not bootstrap identities")
                },
                controlIdentityPathValidation: {
                    throw HostwrightDiagnostic(code: .daemonDenied, message: "isolated path")
                }
            )
            XCTAssertThrowsError(try runner.run()) { error in
                XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .daemonDenied)
            }
            XCTAssertTrue(selectedModes.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testIdentityBootstrapParsesWithoutManagedServiceInputs() throws {
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["daemon", "bootstrap-identities", "--json"]),
            .daemon(options: DaemonCLIOptions(
                action: .bootstrapIdentities, daemonExecutablePath: nil,
                configPath: nil, output: .json
            ))
        )
        for flag in ["--config", "--daemon-executable"] {
            XCTAssertThrowsError(try CLICommand.parse(arguments: [
                "daemon", "bootstrap-identities", flag, "/absolute/path",
            ]))
        }
    }

    func testIdentityOnlyBootstrapDoesNotInspectOrMutateManagedService() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-identity-only-\(UUID().uuidString)", isDirectory: true
        )
        let controller = DaemonLifecycleController(
            layout: DaemonLifecycleLayout(homeDirectory: root.path, userID: UInt32(geteuid())),
            dependencies: DaemonLifecycleDependencies(
                runLaunchctl: { _, _ in
                    XCTFail("Identity-only bootstrap must not operate launchctl")
                    return .notFound
                },
                processInventory: {
                    XCTFail("Identity-only bootstrap must not inspect managed processes")
                    return []
                },
                timestamp: { "2026-09-13T17:00:00Z" },
                operationID: { "00000000-0000-4000-8000-000000000001" }
            )
        )
        var selectedModes: [Bool] = []
        let result = try DaemonLifecycleCommandRunner(
            options: DaemonCLIOptions(
                action: .bootstrapIdentities, daemonExecutablePath: nil,
                configPath: nil, output: .json
            ),
            controller: controller,
            controlIdentityBootstrap: { selectedModes.append($0) }
        ).run()
        XCTAssertEqual(selectedModes, [false])
        XCTAssertEqual(result.exitCode, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(result.standardOutput.utf8)
        ) as? [String: Any])
        XCTAssertEqual(object["operation"] as? String, "daemon.bootstrap-identities")
        XCTAssertEqual(object["status"] as? String, "succeeded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testParserExposesExactDaemonLifecycleSurface() throws {
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["daemon", "status", "--json"]),
            .daemon(
                options: DaemonCLIOptions(
                    action: .status,
                    daemonExecutablePath: nil,
                    configPath: nil,
                    output: .json
                )
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(
                arguments: [
                    "daemon",
                    "install",
                    "--daemon-executable",
                    "/opt/hostwright/bin/hostwrightd",
                    "--config",
                    "/Users/example/hostwright.yaml",
                    "--output",
                    "text"
                ]
            ),
            .daemon(
                options: DaemonCLIOptions(
                    action: .lifecycle(.install),
                    daemonExecutablePath: "/opt/hostwright/bin/hostwrightd",
                    configPath: "/Users/example/hostwright.yaml",
                    output: .text
                )
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(
                arguments: [
                    "daemon",
                    "upgrade",
                    "--daemon-executable",
                    "/opt/hostwright/bin/hostwrightd",
                    "--config",
                    "/Users/example/hostwright.yaml",
                    "--json"
                ]
            ),
            .daemon(
                options: DaemonCLIOptions(
                    action: .lifecycle(.upgrade),
                    daemonExecutablePath: "/opt/hostwright/bin/hostwrightd",
                    configPath: "/Users/example/hostwright.yaml",
                    output: .json
                )
            )
        )
        let inputlessOperations: [(String, DaemonLifecycleOperation)] = [
            ("validate", .validate),
            ("bootstrap", .bootstrap),
            ("start", .start),
            ("stop", .stop),
            ("kickstart", .kickstart),
            ("rollback", .rollback),
            ("disable", .disable),
            ("repair", .repair),
            ("uninstall", .uninstall)
        ]
        for (verb, operation) in inputlessOperations {
            XCTAssertEqual(
                try CLICommand.parse(arguments: ["daemon", verb, "--json"]),
                .daemon(
                    options: DaemonCLIOptions(
                        action: .lifecycle(operation),
                        daemonExecutablePath: nil,
                        configPath: nil,
                        output: .json
                    )
                ),
                "daemon \(verb)"
            )
        }
    }

    func testParserRejectsMissingOrUnexpectedLifecycleInputs() {
        XCTAssertThrowsError(
            try CLICommand.parse(arguments: ["daemon", "install"])
        )
        XCTAssertThrowsError(
            try CLICommand.parse(
                arguments: [
                    "daemon",
                    "upgrade",
                    "--daemon-executable",
                    "hostwrightd",
                    "--config",
                    "/Users/example/hostwright.yaml"
                ]
            )
        )
        XCTAssertThrowsError(
            try CLICommand.parse(
                arguments: [
                    "daemon",
                    "uninstall",
                    "--config",
                    "/Users/example/hostwright.yaml"
                ]
            )
        )
        XCTAssertThrowsError(
            try CLICommand.parse(
                arguments: ["daemon", "status", "--json", "--output", "text"]
            )
        )
    }

    func testStatusRendersVersionedTextAndJSON() throws {
        let requestedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-phase08-daemon-cli-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: requestedHome,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: requestedHome) }
        guard let resolved = realpath(requestedHome.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        let layout = DaemonLifecycleLayout(
            homeDirectory: String(cString: resolved),
            userID: UInt32(geteuid())
        )
        let controller = DaemonLifecycleController(
            layout: layout,
            dependencies: DaemonLifecycleDependencies(
                runLaunchctl: { arguments, _ in
                    arguments.first == "print-disabled" ? .success() : .notFound
                },
                processInventory: { [] },
                timestamp: { "2026-07-31T20:00:00Z" },
                operationID: { "00000000-0000-4000-8000-000000000001" }
            )
        )

        let text = try DaemonLifecycleCommandRunner(
            options: DaemonCLIOptions(
                action: .status,
                daemonExecutablePath: nil,
                configPath: nil,
                output: .text
            ),
            controller: controller
        ).run()
        XCTAssertEqual(text.exitCode, 0)
        XCTAssertTrue(text.standardOutput.contains("Hostwright daemon lifecycle v1"))
        XCTAssertTrue(text.standardOutput.contains("Readiness: not-installed"))
        XCTAssertTrue(text.standardOutput.contains("Installation ID: none"))

        let json = try DaemonLifecycleCommandRunner(
            options: DaemonCLIOptions(
                action: .status,
                daemonExecutablePath: nil,
                configPath: nil,
                output: .json
            ),
            controller: controller
        ).run()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.standardOutput.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["operation"] as? String, "status")
        XCTAssertEqual(
            (object["status"] as? [String: Any])?["readiness"] as? String,
            "not-installed"
        )
    }

    func testOwnershipConflictUsesTheStableConflictDiagnostic() throws {
        let requestedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-phase08-daemon-cli-conflict-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: requestedHome,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: requestedHome) }
        guard let resolved = realpath(requestedHome.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        let layout = DaemonLifecycleLayout(
            homeDirectory: String(cString: resolved),
            userID: UInt32(geteuid())
        )
        let propertyListURL = URL(fileURLWithPath: layout.propertyListPath)
        try FileManager.default.createDirectory(
            at: propertyListURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("foreign".utf8).write(to: propertyListURL)
        XCTAssertEqual(chmod(propertyListURL.path, 0o600), 0)
        let runner = DaemonLifecycleCommandRunner(
            options: DaemonCLIOptions(
                action: .status,
                daemonExecutablePath: nil,
                configPath: nil,
                output: .json
            ),
            controller: DaemonLifecycleController(
                layout: layout,
                dependencies: DaemonLifecycleDependencies(
                    runLaunchctl: { _, _ in .notFound },
                    processInventory: { [] },
                    timestamp: { "2026-07-31T20:00:00Z" },
                    operationID: { "00000000-0000-4000-8000-000000000001" }
                )
            )
        )

        XCTAssertThrowsError(try runner.run()) { error in
            XCTAssertEqual(
                error as? HostwrightDiagnostic,
                HostwrightDiagnostic(
                    code: .daemonConflict,
                    message: "Daemon lifecycle ownership conflict: the managed plist path exists without an ownership record"
                )
            )
        }
    }
}
