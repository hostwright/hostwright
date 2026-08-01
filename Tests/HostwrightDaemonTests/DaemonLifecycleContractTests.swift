import Darwin
import Foundation
import HostwrightCore
import XCTest
@testable import HostwrightDaemonCore

final class DaemonLifecycleContractTests: XCTestCase {
    func testCurrentUserLayoutUsesOneExactPhaseEightLaunchAgent() {
        let layout = DaemonLifecycleLayout(
            homeDirectory: "/Users/example",
            userID: 501
        )

        XCTAssertEqual(layout.schemaVersion, 1)
        XCTAssertEqual(layout.label, "dev.hostwright.daemon")
        XCTAssertEqual(layout.domain, "gui/501")
        XCTAssertEqual(
            layout.propertyListPath,
            "/Users/example/Library/LaunchAgents/dev.hostwright.daemon.plist"
        )
        XCTAssertEqual(
            layout.lifecycleDirectory,
            "/Users/example/Library/Application Support/Hostwright/daemon"
        )
        XCTAssertEqual(
            layout.standardOutputPath,
            "/Users/example/Library/Logs/Hostwright/hostwrightd.log"
        )
        XCTAssertEqual(
            layout.standardErrorPath,
            "/Users/example/Library/Logs/Hostwright/hostwrightd.error.log"
        )
        XCTAssertEqual(layout.homebrewLabel, "homebrew.mxcl.hostwright")
        XCTAssertEqual(
            layout.homebrewPropertyListPath,
            "/Users/example/Library/LaunchAgents/homebrew.mxcl.hostwright.plist"
        )
    }

    func testControllerRejectsDecodedLayoutPathSubstitution() throws {
        let exact = DaemonLifecycleLayout(
            homeDirectory: "/Users/example",
            userID: UInt32(geteuid())
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(exact))
                as? [String: Any]
        )
        object["propertyListPath"] = "/Users/example/Library/LaunchAgents/foreign.plist"
        let substituted = try JSONDecoder().decode(
            DaemonLifecycleLayout.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        let controller = DaemonLifecycleController(
            layout: substituted,
            dependencies: DaemonLifecycleDependencies(
                runLaunchctl: { _, _ in
                    XCTFail("layout validation must fail before launchctl")
                    return .notFound
                },
                processInventory: {
                    XCTFail("layout validation must fail before process inventory")
                    return []
                },
                timestamp: { "2026-07-31T20:00:00Z" },
                operationID: { "00000000-0000-4000-8000-000000000001" }
            )
        )

        XCTAssertThrowsError(try controller.status())
    }

    func testMutationRefusesACompetingLifecycleControllerLock() throws {
        try withLifecycleFixture { fixture in
            let descriptor = open(
                fixture.layout.homeDirectory,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            defer { _ = flock(descriptor, LOCK_UN) }
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )

            XCTAssertThrowsError(
                try controller.perform(
                    .install,
                    daemonExecutablePath: fixture.daemonPath,
                    configPath: fixture.configPath
                )
            ) { error in
                XCTAssertEqual(
                    error as? DaemonLifecycleError,
                    .conflict("another daemon lifecycle controller is active")
                )
            }
            XCTAssertTrue(system.commands.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.journalPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.propertyListPath))
        }
    }

    func testDeletedExecutableFallbackParsesOnlyBoundedAbsoluteKernelPath() {
        var argc: Int32 = 3
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        data.append(Data("/private/var/tmp/orphan/hostwrightd".utf8))
        data.append(0)
        data.append(Data("--foreground".utf8))
        data.append(0)

        XCTAssertEqual(
            DaemonLifecycleDependencies.processExecutablePath(
                fromProcArguments: data
            ),
            "/private/var/tmp/orphan/hostwrightd"
        )

        var unsafe = withUnsafeBytes(of: &argc) { Data($0) }
        unsafe.append(Data("relative/hostwrightd".utf8))
        unsafe.append(0)
        XCTAssertNil(
            DaemonLifecycleDependencies.processExecutablePath(
                fromProcArguments: unsafe
            )
        )
    }

    func testProcessInventoryUsesPOSIXCanonicalPathForExistingExecutable() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ).appendingPathComponent(
            "hostwright-daemon-process-path-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("hostwrightd")
        try Data("fixture".utf8).write(to: executable, options: .withoutOverwriting)

        guard let resolved = realpath(executable.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }

        XCTAssertEqual(
            DaemonLifecycleDependencies.canonicalProcessExecutablePath(
                executable.path
            ),
            String(cString: resolved)
        )
    }

    func testDisabledStateParserAcceptsCurrentLaunchctlVocabulary() throws {
        let disabled = """
        disabled services = {
            "dev.hostwright.daemon" => disabled
        }
        """
        let enabled = """
        disabled services = {
            "dev.hostwright.daemon" => enabled
        }
        """

        XCTAssertEqual(
            try DaemonLifecycleDependencies.launchdDisabledState(
                label: "dev.hostwright.daemon",
                output: disabled
            ),
            true
        )
        XCTAssertEqual(
            try DaemonLifecycleDependencies.launchdDisabledState(
                label: "dev.hostwright.daemon",
                output: enabled
            ),
            false
        )
        XCTAssertNil(
            try DaemonLifecycleDependencies.launchdDisabledState(
                label: "dev.hostwright.daemon",
                output: "disabled services = {\n}\n"
            )
        )
        XCTAssertThrowsError(
            try DaemonLifecycleDependencies.launchdDisabledState(
                label: "dev.hostwright.daemon",
                output: "\"dev.hostwright.daemon\" => maybe\n"
            )
        )
    }

    func testLaunchAgentPropertyListHasExactMinimalManagedContract() throws {
        let layout = DaemonLifecycleLayout(
            homeDirectory: "/Users/example",
            userID: 501
        )
        let specification = try DaemonLaunchAgentSpecification(
            layout: layout,
            daemonExecutablePath: "/opt/hostwright/bin/hostwrightd",
            configPath: "/Users/example/.config/hostwright/hostwright.yaml"
        )

        let data = try specification.propertyListData()
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            [
                "Label",
                "ProgramArguments",
                "RunAtLoad",
                "KeepAlive",
                "ThrottleInterval",
                "ProcessType",
                "Umask",
                "StandardOutPath",
                "StandardErrorPath"
            ]
        )
        XCTAssertEqual(object["Label"] as? String, "dev.hostwright.daemon")
        XCTAssertEqual(
            object["ProgramArguments"] as? [String],
            [
                "/opt/hostwright/bin/hostwrightd",
                "--service",
                "--config",
                "/Users/example/.config/hostwright/hostwright.yaml"
            ]
        )
        XCTAssertEqual(object["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(object["KeepAlive"] as? Bool, true)
        XCTAssertEqual(object["ThrottleInterval"] as? Int, 10)
        XCTAssertEqual(object["ProcessType"] as? String, "Background")
        XCTAssertEqual(object["Umask"] as? String, "0077")
        XCTAssertEqual(
            object["StandardOutPath"] as? String,
            "/Users/example/Library/Logs/Hostwright/hostwrightd.log"
        )
        XCTAssertEqual(
            object["StandardErrorPath"] as? String,
            "/Users/example/Library/Logs/Hostwright/hostwrightd.error.log"
        )
        XCTAssertNil(object["EnvironmentVariables"])
        XCTAssertNil(object["Disabled"])
    }

    func testLaunchAgentSpecificationRejectsRelativeOrNonCanonicalPaths() {
        let layout = DaemonLifecycleLayout(
            homeDirectory: "/Users/example",
            userID: 501
        )

        XCTAssertThrowsError(
            try DaemonLaunchAgentSpecification(
                layout: layout,
                daemonExecutablePath: "bin/hostwrightd",
                configPath: "/Users/example/hostwright.yaml"
            )
        )
        XCTAssertThrowsError(
            try DaemonLaunchAgentSpecification(
                layout: layout,
                daemonExecutablePath: "/opt/hostwright/../bin/hostwrightd",
                configPath: "/Users/example/hostwright.yaml"
            )
        )
        XCTAssertThrowsError(
            try DaemonLaunchAgentSpecification(
                layout: layout,
                daemonExecutablePath: "/opt/hostwright/bin/hostwrightd",
                configPath: "hostwright.yaml"
            )
        )
    }

    func testDaemonParserKeepsForegroundAndAddsManagedServiceMode() throws {
        let inheritedOverrides = [
            HostwrightLocalPathResolver.applicationSupportOverride:
                "/Users/example/untrusted-application-support",
            HostwrightLocalPathResolver.stateDatabaseOverride:
                "/Users/example/untrusted-state.sqlite"
        ]
        let foreground = try DaemonCommand.parse(
            arguments: ["--foreground", "--config", "/tmp/hostwright.yaml"],
            homeDirectory: "/Users/example",
            environment: inheritedOverrides
        )
        let service = try DaemonCommand.parse(
            arguments: ["--service", "--config", "/tmp/hostwright.yaml"],
            homeDirectory: "/Users/example",
            environment: inheritedOverrides
        )

        guard case .run(let foregroundConfiguration) = foreground,
              case .run(let serviceConfiguration) = service else {
            return XCTFail("Expected runnable daemon configurations.")
        }
        XCTAssertEqual(foregroundConfiguration.mode, .foregroundDev)
        XCTAssertEqual(serviceConfiguration.mode, .managedService)
        XCTAssertEqual(
            foregroundConfiguration.stateStoreConfiguration.databasePath,
            "/Users/example/untrusted-state.sqlite"
        )
        XCTAssertEqual(
            serviceConfiguration.stateStoreConfiguration.databasePath,
            "/Users/example/Library/Application Support/Hostwright/state/state.sqlite"
        )
        let expectedManagedEnvironment = [
            "HOME": "/Users/example",
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": SecureSubprocessEnvironment.trustedSystemPath
        ]
        XCTAssertEqual(
            DaemonCommand.managedServiceEnvironment(homeDirectory: "/Users/example"),
            expectedManagedEnvironment
        )
        XCTAssertFalse(
            DaemonCommand.managedServiceEnvironmentRequiresReexec(
                inheritedEnvironment: expectedManagedEnvironment,
                homeDirectory: "/Users/example"
            )
        )
        XCTAssertTrue(
            DaemonCommand.managedServiceEnvironmentRequiresReexec(
                inheritedEnvironment: expectedManagedEnvironment.merging(
                    ["SSH_AUTH_SOCK": "/private/tmp/untrusted-agent"],
                    uniquingKeysWith: { _, new in new }
                ),
                homeDirectory: "/Users/example"
            )
        )
        XCTAssertTrue(
            DaemonCommand.managedServiceEnvironmentRequiresReexec(
                inheritedEnvironment: [
                    "HOME": "/Users/example",
                    "PATH": SecureSubprocessEnvironment.trustedSystemPath
                ],
                homeDirectory: "/Users/example"
            )
        )
        XCTAssertThrowsError(
            try DaemonCommand.parse(
                arguments: [
                    "--foreground",
                    "--service",
                    "--config",
                    "/tmp/hostwright.yaml"
                ],
                homeDirectory: "/Users/example",
                environment: [:]
            )
        )
    }

    func testInstallValidateAndStatusUseDurableExactOwnership() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )

            let installed = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )

            XCTAssertTrue(installed.changed)
            XCTAssertEqual(installed.reasonCode, .installed)
            XCTAssertEqual(installed.status.readiness, .running)
            XCTAssertEqual(installed.status.generation, 1)
            XCTAssertEqual(installed.status.daemonExecutablePath, fixture.daemonPath)
            XCTAssertEqual(installed.status.configPath, fixture.configPath)
            XCTAssertEqual(system.commands.filter { $0.first == "bootstrap" }.count, 1)
            XCTAssertEqual(system.commands.filter { $0.first == "kickstart" }.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.statusPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.journalPath))

            var metadata = stat()
            XCTAssertEqual(lstat(fixture.layout.propertyListPath, &metadata), 0)
            XCTAssertEqual(metadata.st_uid, geteuid())
            XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
            XCTAssertEqual(metadata.st_nlink, 1)

            let validated = try controller.perform(.validate)
            XCTAssertFalse(validated.changed)
            XCTAssertEqual(validated.reasonCode, .validated)
            XCTAssertEqual(validated.status.readiness, .running)
            XCTAssertEqual(try controller.status(), validated.status)
        }
    }

    func testStartStopBootstrapAndKickstartPreserveOwnedGeneration() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            let installed = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            let installationID = try XCTUnwrap(installed.status.installationID)

            let stopped = try controller.perform(.stop)
            XCTAssertEqual(stopped.operation, .stop)
            XCTAssertEqual(stopped.reasonCode, .stopped)
            XCTAssertEqual(stopped.status.readiness, .stopped)

            let bootstrapped = try controller.perform(.bootstrap)
            XCTAssertEqual(bootstrapped.operation, .bootstrap)
            XCTAssertEqual(bootstrapped.reasonCode, .bootstrapped)
            XCTAssertEqual(bootstrapped.status.readiness, .running)

            _ = try controller.perform(.stop)
            let started = try controller.perform(.start)
            XCTAssertEqual(started.operation, .start)
            XCTAssertEqual(started.reasonCode, .started)
            XCTAssertEqual(started.status.readiness, .running)

            let kickstarted = try controller.perform(.kickstart)
            XCTAssertEqual(kickstarted.operation, .kickstart)
            XCTAssertEqual(kickstarted.reasonCode, .kickstarted)
            XCTAssertEqual(kickstarted.status.readiness, .running)
            for result in [stopped, bootstrapped, started, kickstarted] {
                XCTAssertEqual(result.status.installationID, installationID)
                XCTAssertEqual(result.status.generation, 1)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.journalPath))
            }
        }
    }

    func testInstallRefusesLoadedHomebrewServiceAndUnmanagedDaemon() throws {
        try withLifecycleFixture { fixture in
            let homebrew = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            homebrew.homebrewLoaded = true
            XCTAssertThrowsError(
                try DaemonLifecycleController(
                    layout: fixture.layout,
                    dependencies: homebrew.dependencies
                ).perform(
                    .install,
                    daemonExecutablePath: fixture.daemonPath,
                    configPath: fixture.configPath
                )
            ) { error in
                XCTAssertEqual(
                    error as? DaemonLifecycleError,
                    .externalServiceConflict(fixture.layout.homebrewServiceTarget)
                )
            }

            homebrew.homebrewLoaded = false
            homebrew.unmanagedDaemonPaths = ["/private/var/tmp/orphan/hostwrightd"]
            XCTAssertThrowsError(
                try DaemonLifecycleController(
                    layout: fixture.layout,
                    dependencies: homebrew.dependencies
                ).perform(
                    .install,
                    daemonExecutablePath: fixture.daemonPath,
                    configPath: fixture.configPath
                )
            ) { error in
                XCTAssertEqual(
                    error as? DaemonLifecycleError,
                    .unmanagedDaemonProcess("/private/var/tmp/orphan/hostwrightd")
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.propertyListPath))

            homebrew.unmanagedDaemonPaths = []
            homebrew.disabled = true
            XCTAssertThrowsError(
                try DaemonLifecycleController(
                    layout: fixture.layout,
                    dependencies: homebrew.dependencies
                ).perform(
                    .install,
                    daemonExecutablePath: fixture.daemonPath,
                    configPath: fixture.configPath
                )
            )
            XCTAssertFalse(homebrew.commands.contains { $0.first == "enable" })
        }
    }

    func testUpgradeAndRollbackRestoreExactPriorGeneration() throws {
        try withLifecycleFixture { fixture in
            let upgradedDaemon = fixture.root.appendingPathComponent("bin-v2/hostwrightd").path
            let upgradedConfig = fixture.root.appendingPathComponent("config/hostwright-v2.yaml").path
            try makeExecutable(at: upgradedDaemon, marker: 2)
            try makeConfig(at: upgradedConfig, project: "upgraded")
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )

            let upgraded = try controller.perform(
                .upgrade,
                daemonExecutablePath: upgradedDaemon,
                configPath: upgradedConfig
            )
            XCTAssertEqual(upgraded.status.generation, 2)
            XCTAssertEqual(upgraded.status.daemonExecutablePath, upgradedDaemon)
            XCTAssertEqual(upgraded.status.configPath, upgradedConfig)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.rollbackPath))

            let rolledBack = try controller.perform(.rollback)
            XCTAssertEqual(rolledBack.reasonCode, .rolledBack)
            XCTAssertEqual(rolledBack.status.generation, 1)
            XCTAssertEqual(rolledBack.status.daemonExecutablePath, fixture.daemonPath)
            XCTAssertEqual(rolledBack.status.configPath, fixture.configPath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.rollbackPath))
            XCTAssertEqual(try controller.status().readiness, .running)
        }
    }

    func testCancellationLeavesRepairableJournalAndRepairCompletesForward() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let interrupted = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies,
                cancelAfter: .propertyListPublished
            )

            XCTAssertThrowsError(
                try interrupted.perform(
                    .install,
                    daemonExecutablePath: fixture.daemonPath,
                    configPath: fixture.configPath
                )
            ) { error in
                XCTAssertEqual(error as? DaemonLifecycleError, .cancelled)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.journalPath))
            XCTAssertEqual(try interrupted.status().readiness, .recoveryRequired)

            let repaired = try DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            ).perform(.repair)
            XCTAssertEqual(repaired.reasonCode, .recovered)
            XCTAssertEqual(repaired.status.readiness, .running)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.journalPath))
        }
    }

    func testDisablePersistsAndUninstallRemovesOnlyExactLifecycleArtifacts() throws {
        try withLifecycleFixture { fixture in
            let launchAgents = URL(fileURLWithPath: fixture.layout.propertyListPath)
                .deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: launchAgents,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let homebrew = fixture.layout.homebrewPropertyListPath
            try Data("external-homebrew-record".utf8).write(to: URL(fileURLWithPath: homebrew))
            try chmodPath(homebrew, mode: 0o600)
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            let unrelated = URL(fileURLWithPath: fixture.layout.lifecycleDirectory)
                .appendingPathComponent("unrelated-user-file").path
            try Data("preserve".utf8).write(to: URL(fileURLWithPath: unrelated))

            let disabled = try controller.perform(.disable)
            XCTAssertEqual(disabled.status.readiness, .disabled)
            XCTAssertTrue(system.disabled)
            XCTAssertEqual(try controller.status().reasonCode, .disabled)

            let uninstalled = try controller.perform(.uninstall)
            XCTAssertEqual(uninstalled.reasonCode, .uninstalled)
            XCTAssertEqual(uninstalled.status.readiness, .notInstalled)
            XCTAssertFalse(system.disabled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.propertyListPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.statusPath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: homebrew))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.daemonPath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.configPath))
        }
    }

    func testValidateRequiresInstallationAndRepairRebuildsMissingOwnedPlist() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            XCTAssertThrowsError(try controller.perform(.validate)) { error in
                XCTAssertEqual(error as? DaemonLifecycleError, .notInstalled)
            }
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            XCTAssertEqual(unlink(fixture.layout.propertyListPath), 0)
            XCTAssertEqual(try controller.status().readiness, .recoveryRequired)

            let repaired = try controller.perform(.repair)
            XCTAssertEqual(repaired.reasonCode, .repaired)
            XCTAssertEqual(repaired.status.readiness, .running)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.propertyListPath))
        }
    }

    func testSecureInputsAndChangedManagedPlistFailBeforeUnsafeMutation() throws {
        try withLifecycleFixture { fixture in
            let linkedConfig = fixture.root.appendingPathComponent("config-linked.yaml").path
            XCTAssertEqual(symlink(fixture.configPath, linkedConfig), 0)
            let linkedSystem = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            XCTAssertThrowsError(
                try DaemonLifecycleController(
                    layout: fixture.layout,
                    dependencies: linkedSystem.dependencies
                ).perform(
                    .install,
                    daemonExecutablePath: fixture.daemonPath,
                    configPath: linkedConfig
                )
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.propertyListPath))

            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: linkedSystem.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            try Data("changed-unmanaged-content".utf8).write(
                to: URL(fileURLWithPath: fixture.layout.propertyListPath)
            )
            XCTAssertThrowsError(try controller.perform(.uninstall))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.propertyListPath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.statusPath))
        }
    }

    func testUninstallRefusesSymlinkAndHardLinkLogSubstitution() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            let foreign = fixture.root.appendingPathComponent("foreign-symlink-target.log")
            let foreignData = Data("preserve-symlink-target\n".utf8)
            try foreignData.write(to: foreign, options: .withoutOverwriting)
            try chmodPath(foreign.path, mode: 0o600)
            XCTAssertEqual(unlink(fixture.layout.standardOutputPath), 0)
            XCTAssertEqual(symlink(foreign.path, fixture.layout.standardOutputPath), 0)

            XCTAssertThrowsError(try controller.perform(.uninstall))
            XCTAssertEqual(try Data(contentsOf: foreign), foreignData)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.journalPath))
            XCTAssertEqual(try controller.status().readiness, .recoveryRequired)
            var metadata = stat()
            XCTAssertEqual(lstat(fixture.layout.standardOutputPath, &metadata), 0)
            XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFLNK)
        }

        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            let foreign = fixture.root.appendingPathComponent("foreign-hard-link-target.log")
            let foreignData = Data("preserve-hard-link-target\n".utf8)
            try foreignData.write(to: foreign, options: .withoutOverwriting)
            try chmodPath(foreign.path, mode: 0o600)
            XCTAssertEqual(unlink(fixture.layout.standardErrorPath), 0)
            XCTAssertEqual(link(foreign.path, fixture.layout.standardErrorPath), 0)

            XCTAssertThrowsError(try controller.perform(.uninstall))
            XCTAssertEqual(try Data(contentsOf: foreign), foreignData)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.journalPath))
            XCTAssertEqual(try controller.status().readiness, .recoveryRequired)
            var metadata = stat()
            XCTAssertEqual(lstat(fixture.layout.standardErrorPath, &metadata), 0)
            XCTAssertEqual(metadata.st_nlink, 2)
        }
    }

    func testStatusRejectsLaunchAgentsParentSymlinkReplacement() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            let launchAgents = URL(fileURLWithPath: fixture.layout.propertyListPath)
                .deletingLastPathComponent()
            let displaced = fixture.root.appendingPathComponent(
                "LaunchAgents-owned",
                isDirectory: true
            )
            let replacement = fixture.root.appendingPathComponent(
                "LaunchAgents-replacement",
                isDirectory: true
            )
            try FileManager.default.moveItem(at: launchAgents, to: displaced)
            try FileManager.default.createDirectory(
                at: replacement,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.copyItem(
                at: displaced.appendingPathComponent("dev.hostwright.daemon.plist"),
                to: replacement.appendingPathComponent("dev.hostwright.daemon.plist")
            )
            try FileManager.default.createSymbolicLink(
                at: launchAgents,
                withDestinationURL: replacement
            )

            XCTAssertThrowsError(try controller.status())
        }
    }

    func testValidateRechecksExecutableAndConfigurationSecurityWithoutMutation() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            XCTAssertEqual(chmod(fixture.configPath, 0o666), 0)
            let commandsBefore = system.commands.count

            XCTAssertThrowsError(try controller.perform(.validate))
            XCTAssertEqual(system.commands.count, commandsBefore + 3)
            XCTAssertFalse(system.commands[commandsBefore...].contains { command in
                ["bootout", "bootstrap", "kickstart", "enable", "disable"]
                    .contains(command.first)
            })
        }
    }

    func testLoadedServiceIdentityRaceIsRefusedBeforeBootout() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            let bootoutsBefore = system.commands.filter { $0.first == "bootout" }.count
            system.managed?.programPath = "/private/var/tmp/foreign/hostwrightd"

            XCTAssertThrowsError(try controller.perform(.stop))
            XCTAssertEqual(
                system.commands.filter { $0.first == "bootout" }.count,
                bootoutsBefore
            )
            XCTAssertEqual(system.managed?.programPath, "/private/var/tmp/foreign/hostwrightd")
            XCTAssertEqual(try controller.status().readiness, .recoveryRequired)
        }
    }

    func testStopWaitsForAsynchronousLaunchdBootoutConvergence() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            system.bootoutObservationDelay = 2

            let stopped = try controller.perform(.stop)

            XCTAssertEqual(stopped.status.readiness, .stopped)
            XCTAssertNil(system.managed)
            XCTAssertGreaterThanOrEqual(
                system.commands.filter { $0.first == "print" }.count,
                3
            )
        }
    }

    func testLateHomebrewConflictIsRefusedBeforeOwnedServiceMutation() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            let bootoutsBefore = system.commands.filter { $0.first == "bootout" }.count
            system.homebrewLoaded = true

            XCTAssertThrowsError(try controller.perform(.stop)) { error in
                XCTAssertEqual(
                    error as? DaemonLifecycleError,
                    .externalServiceConflict(fixture.layout.homebrewServiceTarget)
                )
            }
            XCTAssertEqual(
                system.commands.filter { $0.first == "bootout" }.count,
                bootoutsBefore
            )
            XCTAssertEqual(try controller.status().readiness, .recoveryRequired)
        }
    }

    func testLaunchInputsAreRevalidatedImmediatelyBeforeBootstrap() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            system.onCommand = { arguments in
                if arguments.first == "enable" {
                    XCTAssertEqual(chmod(fixture.daemonPath, 0o722), 0)
                }
            }
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )

            XCTAssertThrowsError(
                try controller.perform(
                    .install,
                    daemonExecutablePath: fixture.daemonPath,
                    configPath: fixture.configPath
                )
            )
            XCTAssertFalse(system.commands.contains { $0.first == "bootstrap" })
            XCTAssertEqual(try controller.status().readiness, .recoveryRequired)
        }
    }

    func testLaunchdPIDMustMatchTheSingleManagedProcess() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            system.inventoryPIDOverride = 701

            XCTAssertThrowsError(try controller.status()) { error in
                XCTAssertEqual(
                    error as? DaemonLifecycleError,
                    .verificationFailed(
                        "launchd and process inventory disagree on the managed daemon PID"
                    )
                )
            }
        }
    }

    func testVersionedLifecycleRecordsRejectUnknownFieldsBeforeMutation() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            try addUnknownJSONField(at: fixture.layout.statusPath)
            let commandsBefore = system.commands.count

            XCTAssertThrowsError(try controller.perform(.stop))
            XCTAssertEqual(system.commands.count, commandsBefore)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.statusPath))
        }

        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let interrupted = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies,
                cancelAfter: .intentRecorded
            )
            XCTAssertThrowsError(
                try interrupted.perform(
                    .install,
                    daemonExecutablePath: fixture.daemonPath,
                    configPath: fixture.configPath
                )
            )
            try addUnknownJSONField(at: fixture.layout.journalPath)
            let commandsBefore = system.commands.count

            XCTAssertThrowsError(
                try DaemonLifecycleController(
                    layout: fixture.layout,
                    dependencies: system.dependencies
                ).perform(.repair)
            )
            XCTAssertEqual(system.commands.count, commandsBefore)
        }

        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            XCTAssertThrowsError(
                try DaemonLifecycleController(
                    layout: fixture.layout,
                    dependencies: system.dependencies,
                    cancelAfter: .intentRecorded
                ).perform(
                    .install,
                    daemonExecutablePath: fixture.daemonPath,
                    configPath: fixture.configPath
                )
            )
            try replaceJSONField(
                at: fixture.layout.journalPath,
                key: "operation",
                value: "uninstall"
            )
            let commandsBefore = system.commands.count

            XCTAssertThrowsError(
                try DaemonLifecycleController(
                    layout: fixture.layout,
                    dependencies: system.dependencies
                ).perform(.repair)
            )
            XCTAssertEqual(system.commands.count, commandsBefore)
        }

        try withLifecycleFixture { fixture in
            let upgradedDaemon = fixture.root.appendingPathComponent("bin-v2/hostwrightd").path
            let upgradedConfig = fixture.root.appendingPathComponent("config/v2.yaml").path
            try makeExecutable(at: upgradedDaemon, marker: 2)
            try makeConfig(at: upgradedConfig, project: "v2")
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            _ = try controller.perform(
                .upgrade,
                daemonExecutablePath: upgradedDaemon,
                configPath: upgradedConfig
            )
            try addUnknownJSONField(at: fixture.layout.rollbackPath)
            let commandsBefore = system.commands.count

            XCTAssertThrowsError(try controller.perform(.rollback))
            XCTAssertEqual(system.commands.count, commandsBefore)
        }

        try withLifecycleFixture { fixture in
            let upgradedDaemon = fixture.root.appendingPathComponent("bin-v2/hostwrightd").path
            let upgradedConfig = fixture.root.appendingPathComponent("config/v2.yaml").path
            try makeExecutable(at: upgradedDaemon, marker: 2)
            try makeConfig(at: upgradedConfig, project: "v2")
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            _ = try DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            ).perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            XCTAssertThrowsError(
                try DaemonLifecycleController(
                    layout: fixture.layout,
                    dependencies: system.dependencies,
                    cancelAfter: .rollbackPublished
                ).perform(
                    .upgrade,
                    daemonExecutablePath: upgradedDaemon,
                    configPath: upgradedConfig
                )
            )
            try addUnknownJSONField(at: fixture.layout.rollbackPath)
            let commandsBefore = system.commands.count

            XCTAssertThrowsError(
                try DaemonLifecycleController(
                    layout: fixture.layout,
                    dependencies: system.dependencies
                ).perform(.repair)
            )
            XCTAssertEqual(system.commands.count, commandsBefore)
        }
    }

    func testLifecycleRecordsRejectNoncanonicalUUIDIdentitiesBeforeMutation() throws {
        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )
            _ = try controller.perform(
                .install,
                daemonExecutablePath: fixture.daemonPath,
                configPath: fixture.configPath
            )
            try replaceJSONField(
                at: fixture.layout.statusPath,
                key: "installationID",
                value: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
            )
            let commandsBefore = system.commands.count

            XCTAssertThrowsError(try controller.perform(.stop))
            XCTAssertEqual(system.commands.count, commandsBefore)
        }

        try withLifecycleFixture { fixture in
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            XCTAssertThrowsError(
                try DaemonLifecycleController(
                    layout: fixture.layout,
                    dependencies: system.dependencies,
                    cancelAfter: .intentRecorded
                ).perform(
                    .install,
                    daemonExecutablePath: fixture.daemonPath,
                    configPath: fixture.configPath
                )
            )
            try replaceJSONField(
                at: fixture.layout.journalPath,
                key: "operationID",
                value: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
            )
            let commandsBefore = system.commands.count

            XCTAssertThrowsError(
                try DaemonLifecycleController(
                    layout: fixture.layout,
                    dependencies: system.dependencies
                ).perform(.repair)
            )
            XCTAssertEqual(system.commands.count, commandsBefore)
        }
    }

    func testEveryInstallCheckpointLeavesRepairableDurableIntent() throws {
        let checkpoints: [DaemonLifecycleCheckpoint] = [
            .intentRecorded,
            .serviceStopped,
            .propertyListPublished,
            .disabledStatePublished,
            .serviceStarted,
            .verified,
            .statusPublished
        ]
        for checkpoint in checkpoints {
            try withLifecycleFixture { fixture in
                let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
                let interrupted = DaemonLifecycleController(
                    layout: fixture.layout,
                    dependencies: system.dependencies,
                    cancelAfter: checkpoint
                )
                XCTAssertThrowsError(
                    try interrupted.perform(
                        .install,
                        daemonExecutablePath: fixture.daemonPath,
                        configPath: fixture.configPath
                    ),
                    "checkpoint \(checkpoint.rawValue)"
                ) { error in
                    XCTAssertEqual(error as? DaemonLifecycleError, .cancelled)
                }
                XCTAssertEqual(try interrupted.status().readiness, .recoveryRequired)
                let recovered = try DaemonLifecycleController(
                    layout: fixture.layout,
                    dependencies: system.dependencies
                ).perform(.repair)
                XCTAssertEqual(recovered.reasonCode, .recovered)
                XCTAssertEqual(recovered.status.readiness, .running)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.journalPath))
            }
        }
    }

    func testInstallRecoveryDoesNotAdoptAPreexistingLogFile() throws {
        try withLifecycleFixture { fixture in
            let logURL = URL(fileURLWithPath: fixture.layout.standardOutputPath)
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let foreignData = Data("foreign-log\n".utf8)
            try foreignData.write(to: logURL, options: .withoutOverwriting)
            try chmodPath(logURL.path, mode: 0o600)
            let system = ScriptedDaemonLifecycleSystem(layout: fixture.layout)
            let controller = DaemonLifecycleController(
                layout: fixture.layout,
                dependencies: system.dependencies
            )

            XCTAssertThrowsError(
                try controller.perform(
                    .install,
                    daemonExecutablePath: fixture.daemonPath,
                    configPath: fixture.configPath
                )
            )
            XCTAssertEqual(try controller.status().readiness, .recoveryRequired)
            XCTAssertThrowsError(try controller.perform(.repair))
            XCTAssertEqual(try Data(contentsOf: logURL), foreignData)
            XCTAssertNil(system.managed)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fixture.layout.propertyListPath)
            )
        }
    }

    private struct LifecycleFixture {
        let root: URL
        let layout: DaemonLifecycleLayout
        let daemonPath: String
        let configPath: String
    }

    private func withLifecycleFixture(
        _ body: (LifecycleFixture) throws -> Void
    ) throws {
        let requestedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-phase08-daemon-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: requestedRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let root = try canonicalExistingURL(requestedRoot)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let daemonPath = root.appendingPathComponent("bin/hostwrightd").path
        let configPath = root.appendingPathComponent("config/hostwright.yaml").path
        try makeExecutable(at: daemonPath, marker: 1)
        try makeConfig(at: configPath, project: "demo")
        try body(
            LifecycleFixture(
                root: root,
                layout: DaemonLifecycleLayout(
                    homeDirectory: home.path,
                    userID: UInt32(geteuid())
                ),
                daemonPath: daemonPath,
                configPath: configPath
            )
        )
    }

    private func makeExecutable(at path: String, marker: UInt8) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data([0xcf, 0xfa, 0xed, 0xfe, marker]).write(to: url)
        try chmodPath(path, mode: 0o700)
    }

    private func makeConfig(at path: String, project: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("version: 2\nproject: \(project)\nservices: {}\n".utf8).write(to: url)
        try chmodPath(path, mode: 0o600)
    }

    private func chmodPath(_ path: String, mode: mode_t) throws {
        guard chmod(path, mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func addUnknownJSONField(at path: String) throws {
        try replaceJSONField(at: path, key: "futureField", value: true)
    }

    private func replaceJSONField(
        at path: String,
        key: String,
        value: Any
    ) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object[key] = value
        try JSONSerialization.data(withJSONObject: object).write(
            to: URL(fileURLWithPath: path),
            options: .atomic
        )
        try chmodPath(path, mode: 0o600)
    }

    private func canonicalExistingURL(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}

private final class ScriptedDaemonLifecycleSystem: @unchecked Sendable {
    struct ManagedService {
        var propertyListPath: String
        var programPath: String
        var loaded: Bool
        var running: Bool
        var pid: Int32
    }

    let layout: DaemonLifecycleLayout
    var commands: [[String]] = []
    var managed: ManagedService?
    var disabled = false
    var homebrewLoaded = false
    var unmanagedDaemonPaths: [String] = []
    var inventoryPIDOverride: Int32?
    var onCommand: (([String]) -> Void)?
    var bootoutObservationDelay = 0
    private var bootoutPending = false

    init(layout: DaemonLifecycleLayout) {
        self.layout = layout
    }

    var dependencies: DaemonLifecycleDependencies {
        DaemonLifecycleDependencies(
            runLaunchctl: { [unowned self] arguments, _ in
                try self.run(arguments)
            },
            processInventory: { [unowned self] in
                var identities = self.unmanagedDaemonPaths.enumerated().map { index, path in
                    DaemonProcessIdentity(processID: Int32(800 + index), executablePath: path)
                }
                if let managed = self.managed, managed.running {
                    identities.append(
                        DaemonProcessIdentity(
                            processID: self.inventoryPIDOverride ?? managed.pid,
                            executablePath: managed.programPath
                        )
                    )
                }
                return identities
            },
            timestamp: { "2026-07-31T20:00:00Z" },
            operationID: { "00000000-0000-4000-8000-000000000001" }
        )
    }

    private func run(_ arguments: [String]) throws -> DaemonLifecycleProcessResult {
        commands.append(arguments)
        onCommand?(arguments)
        switch arguments.first {
        case "print":
            let target = arguments[1]
            if target == layout.homebrewServiceTarget, homebrewLoaded {
                return .success(
                    "\(target) = {\n\tpath = \(layout.homebrewPropertyListPath)\n\tstate = running\n\tprogram = /opt/homebrew/bin/hostwrightd\n\tpid = 600\n}\n"
                )
            }
            if target == layout.serviceTarget, bootoutPending {
                if bootoutObservationDelay > 0 {
                    bootoutObservationDelay -= 1
                } else {
                    managed = nil
                    bootoutPending = false
                }
            }
            guard target == layout.serviceTarget,
                  let managed,
                  managed.loaded else {
                return .notFound
            }
            return .success(
                "\(target) = {\n\tpath = \(managed.propertyListPath)\n\tstate = \(managed.running ? "running" : "waiting")\n\tprogram = \(managed.programPath)\n\tpid = \(managed.running ? String(managed.pid) : "0")\n}\n"
            )
        case "print-disabled":
            return .success(
                "disabled services = {\n\t\"\(layout.label)\" => \(disabled ? "disabled" : "enabled")\n}\n"
            )
        case "bootstrap":
            let path = arguments[2]
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let object = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any]
            )
            let program = try XCTUnwrap((object["ProgramArguments"] as? [String])?.first)
            managed = ManagedService(
                propertyListPath: path,
                programPath: program,
                loaded: true,
                running: true,
                pid: 700
            )
            return .success()
        case "kickstart":
            guard var current = managed, current.loaded else { return .notFound }
            current.running = true
            managed = current
            return .success("700\n")
        case "bootout":
            if bootoutObservationDelay > 0 {
                bootoutPending = true
            } else {
                managed = nil
            }
            return .success()
        case "disable":
            disabled = true
            return .success()
        case "enable":
            disabled = false
            return .success()
        default:
            return .failure(64, "unsupported scripted launchctl command")
        }
    }
}
