import Darwin
import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightHealth
@testable import HostwrightRuntime
@testable import HostwrightState

extension HostwrightCLITests {
    func testPathsJSONReportsDefaultLayoutWithoutCreatingIt() throws {
        try withCLITestDirectory(prefix: "hostwright-cli-xctest") { home in
            let files = FileBox()
            let result = HostwrightCLI.run(
                arguments: ["paths", "--json"],
                environment: environment(
                    files: files,
                    localPathResolution: { explicitPath in
                        try HostwrightLocalPathResolver.resolve(
                            explicitStateDatabasePath: explicitPath,
                            homeDirectory: home.path,
                            environment: [:]
                        )
                    }
                )
            )

            XCTAssertEqual(result.exitCode, 0)
            let json = try jsonObject(result.standardOutput)
            XCTAssertEqual(json["kind"] as? String, "localPaths")
            XCTAssertEqual(json["statePathOrigin"] as? String, "application-support-default")
            XCTAssertEqual(json["readiness"] as? String, "needs-creation")
            XCTAssertEqual(json["migrationJournalExists"] as? Bool, false)
            let layout = try XCTUnwrap(json["layout"] as? [String: Any])
            XCTAssertEqual(
                layout["stateDatabase"] as? String,
                home.appendingPathComponent("Library/Application Support/Hostwright/state/state.sqlite").path
            )
            XCTAssertEqual(json["daemonLockPath"] as? String, layout["daemonLock"] as? String)
            XCTAssertEqual(
                json["migrationJournalPath"] as? String,
                home
                    .appendingPathComponent(
                        "Library/Application Support/Hostwright/metadata/legacy-state-migration.json"
                    )
                    .path
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: home.appendingPathComponent("Library/Application Support/Hostwright").path
                )
            )

            let explicitState = home.appendingPathComponent("custom/state.sqlite").path
            let explicit = HostwrightCLI.run(
                arguments: ["paths", "--state-db", explicitState, "--json"],
                environment: environment(
                    files: files,
                    localPathResolution: { explicitPath in
                        try HostwrightLocalPathResolver.resolve(
                            explicitStateDatabasePath: explicitPath,
                            homeDirectory: home.path,
                            environment: [:]
                        )
                    }
                )
            )
            let explicitJSON = try jsonObject(explicit.standardOutput)
            XCTAssertEqual(explicitJSON["statePathOrigin"] as? String, "explicit")
            XCTAssertEqual(explicitJSON["stateDatabasePath"] as? String, explicitState)
            XCTAssertEqual(explicitJSON["readiness"] as? String, "blocked-policy")
            XCTAssertTrue(
                (explicitJSON["daemonLockPath"] as? String)?.contains("/run/hostwrightd-") == true
            )
        }
    }

    func testPathsAndDoctorReportUnsafeExistingDefaultState() throws {
        try withCLITestDirectory(prefix: "hostwright-cli-xctest") { home in
            let resolution = try HostwrightLocalPathResolver.resolve(homeDirectory: home.path, environment: [:])
            try FileManager.default.createDirectory(
                atPath: resolution.layout.stateDirectory,
                withIntermediateDirectories: true
            )
            for directory in [resolution.layout.applicationSupportDirectory, resolution.layout.stateDirectory] {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            }
            try Data().write(to: URL(fileURLWithPath: resolution.stateDatabasePath))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: resolution.stateDatabasePath
            )

            var testEnvironment = environment(
                files: FileBox(),
                localPathResolution: { _ in resolution }
            )
            testEnvironment.fileExists = { FileManager.default.fileExists(atPath: $0) }

            let paths = HostwrightCLI.run(arguments: ["paths", "--json"], environment: testEnvironment)
            XCTAssertEqual(paths.exitCode, 0)
            let pathsJSON = try jsonObject(paths.standardOutput)
            XCTAssertEqual(pathsJSON["readiness"] as? String, "blocked-policy")
            XCTAssertTrue((pathsJSON["policyError"] as? String)?.contains("0600") == true)

            let doctor = HostwrightCLI.run(
                arguments: ["doctor", "--output", "json"],
                environment: testEnvironment
            )
            XCTAssertEqual(doctor.exitCode, CLIExitCode.validation.rawValue)
            let doctorJSON = try jsonObject(doctor.standardOutput)
            let checks = try XCTUnwrap(doctorJSON["checks"] as? [[String: Any]])
            XCTAssertTrue(
                checks.contains {
                    $0["identifier"] as? String == "statePathPolicy" &&
                        $0["status"] as? String == "blocked" &&
                        (($0["details"] as? [String: Any])?["readiness"] as? String) == "blocked-policy"
                }
            )
        }

        try withCLITestDirectory(prefix: "hostwright-cli-xctest") { home in
            let resolution = try HostwrightLocalPathResolver.resolve(
                homeDirectory: home.path,
                environment: [:]
            )
            try FileManager.default.createDirectory(
                atPath: resolution.layout.applicationSupportDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: resolution.layout.applicationSupportDirectory
            )
            var testEnvironment = environment(
                files: FileBox(),
                localPathResolution: { _ in resolution }
            )
            testEnvironment.fileExists = { FileManager.default.fileExists(atPath: $0) }

            let paths = HostwrightCLI.run(
                arguments: ["paths", "--json"],
                environment: testEnvironment
            )
            XCTAssertEqual(paths.exitCode, 0)
            let pathsJSON = try jsonObject(paths.standardOutput)
            XCTAssertEqual(pathsJSON["readiness"] as? String, "blocked-policy")
            XCTAssertTrue((pathsJSON["policyError"] as? String)?.contains("0700") == true)

            let doctor = HostwrightCLI.run(
                arguments: ["doctor", "--output", "json"],
                environment: testEnvironment
            )
            XCTAssertEqual(doctor.exitCode, CLIExitCode.validation.rawValue)
        }
    }

    func testPathsReportsPendingPostRenameJournalAsMigrationRequired() throws {
        try withCLITestDirectory(prefix: "hostwright-cli-xctest") { home in
            let resolution = try HostwrightLocalPathResolver.resolve(
                homeDirectory: home.path,
                environment: [:]
            )
            try FileManager.default.createDirectory(
                atPath: resolution.legacyRootDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: resolution.legacyRootDirectory
            )
            try SQLiteStateStore(path: resolution.legacyStateDatabase).migrate()
            let checkpoint = try SQLiteConnection(
                path: resolution.legacyStateDatabase,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            try checkpoint.close()
            XCTAssertFalse(FileManager.default.fileExists(atPath: resolution.legacyStateDatabase + "-wal"))
            let checkpointSharedMemory = resolution.legacyStateDatabase + "-shm"
            if FileManager.default.fileExists(atPath: checkpointSharedMemory) {
                try FileManager.default.removeItem(atPath: checkpointSharedMemory)
            }
            for directory in resolution.layout.ownedDirectories {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory
                )
            }

            let attributes = try FileManager.default.attributesOfItem(
                atPath: resolution.legacyStateDatabase
            )
            let device = try XCTUnwrap(attributes[.systemNumber] as? NSNumber)
            let inode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)
            try FileManager.default.moveItem(
                atPath: resolution.legacyStateDatabase,
                toPath: resolution.stateDatabasePath
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: resolution.stateDatabasePath
            )
            let journal = try JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": 1,
                    "source": resolution.legacyStateDatabase,
                    "destination": resolution.stateDatabasePath,
                    "sourceDevice": device.uint64Value,
                    "sourceInode": inode.uint64Value
                ],
                options: [.sortedKeys]
            )
            try journal.write(
                to: URL(fileURLWithPath: resolution.legacyStateMigrationJournal)
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: resolution.legacyStateMigrationJournal
            )

            var testEnvironment = environment(
                files: FileBox(),
                localPathResolution: { _ in resolution }
            )
            testEnvironment.fileExists = { FileManager.default.fileExists(atPath: $0) }
            let result = HostwrightCLI.run(
                arguments: ["paths", "--json"],
                environment: testEnvironment
            )

            XCTAssertEqual(result.exitCode, 0)
            let json = try jsonObject(result.standardOutput)
            XCTAssertEqual(json["readiness"] as? String, "migration-required")
            XCTAssertEqual(json["stateDatabaseExists"] as? Bool, true)
            XCTAssertEqual(json["legacyStateExists"] as? Bool, false)
            XCTAssertEqual(json["migrationJournalExists"] as? Bool, true)
            XCTAssertNil(json["policyError"])
        }
    }

    func testPathResolutionErrorsUseStableStateFailure() throws {
        var testEnvironment = environment(files: FileBox())
        testEnvironment.localPathResolution = { _ in
            throw HostwrightLocalPathError.invalidEnvironmentOverride(
                name: HostwrightLocalPathResolver.stateDatabaseOverride,
                reason: "invalid test override"
            )
        }

        let result = HostwrightCLI.run(arguments: ["paths", "--json"], environment: testEnvironment)

        XCTAssertEqual(result.exitCode, CLIExitCode.stateUnavailable.rawValue)
        let json = try jsonObject(result.standardError)
        XCTAssertEqual(json["code"] as? String, HostwrightErrorCode.stateStoreUnavailable.rawValue)
    }

    func testDoctorReportsMissingAppleContainerAsExternalConstraint() {
        let result = HostwrightCLI.run(arguments: ["doctor"], environment: environment(files: FileBox()))

        XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
        XCTAssertTrue(result.standardOutput.contains("Readiness: externally-constrained"))
        XCTAssertTrue(result.standardOutput.contains("[externally-constrained] appleContainerCLI"))
        XCTAssertTrue(result.standardOutput.contains("Remediation:"))
    }

    func testDoctorJSONOutputIncludesChecks() throws {
        let result = HostwrightCLI.run(arguments: ["doctor", "--output", "json"], environment: environment(files: FileBox()))

        XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
        let json = try jsonObject(result.standardOutput)
        XCTAssertEqual(json["kind"] as? String, "doctor")
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
        XCTAssertEqual(json["readiness"] as? String, "externally-constrained")
        XCTAssertEqual(json["hasFailures"] as? Bool, false)
        XCTAssertEqual(json["hasExternalConstraints"] as? Bool, true)
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        XCTAssertTrue(checks.contains { $0["identifier"] as? String == "appleContainerCLI" && $0["status"] as? String == "externally-constrained" })
        XCTAssertTrue(checks.contains { $0["identifier"] as? String == "telemetryPolicy" && $0["status"] as? String == "ready" })
        XCTAssertTrue(checks.contains { $0["identifier"] as? String == "statePathPolicy" && $0["status"] as? String == "ready" })
        XCTAssertTrue(checks.contains { $0["identifier"] as? String == "stateIntegrity" && $0["status"] as? String == "degraded" })
        XCTAssertTrue(checks.contains { $0["identifier"] as? String == "resourceIntelligence" && $0["status"] as? String == "degraded" })
        XCTAssertTrue(checks.allSatisfy { $0["remediation"] != nil || $0["status"] as? String == "ready" })
        XCTAssertNil(json["resourceReport"])
    }

    func testDoctorJSONOutputUsesReadinessWithoutRuntimeInventoryObservation() throws {
        let adapter = ScriptedApplyRuntimeAdapter(observeError: .runtimeUnavailable("doctor should not observe runtime"))
        let result = HostwrightCLI.run(
            arguments: ["doctor", "--output", "json"],
            environment: environment(
                files: FileBox(),
                containerPath: "/usr/local/bin/container",
                runtimeAdapter: adapter,
                resourceSnapshot: phase26ResourceSnapshot()
            )
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(adapter.observedDesiredStates.isEmpty)
        let json = try jsonObject(result.standardOutput)
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        XCTAssertTrue(checks.contains { $0["identifier"] as? String == "appleContainerService" && $0["status"] as? String == "ready" })
        XCTAssertTrue(checks.contains { $0["identifier"] as? String == "resourceIntelligence" && $0["status"] as? String == "ready" })
        let report = try XCTUnwrap(json["resourceReport"] as? [String: Any])
        XCTAssertEqual(report["measurementMethod"] as? String, "fixture")
        let hardware = try XCTUnwrap(report["hardware"] as? [String: Any])
        XCTAssertEqual(hardware["architecture"] as? String, "arm64")
        XCTAssertEqual(hardware["physicalMemoryBytes"] as? Int, 68_719_476_736)
        let appleContainer = try XCTUnwrap(report["appleContainer"] as? [String: Any])
        XCTAssertEqual(appleContainer["version"] as? String, "container 1.0.0")
        let memoryPressure = try XCTUnwrap(report["memoryPressure"] as? [String: Any])
        XCTAssertEqual(memoryPressure["status"] as? String, "unmeasured")
        let bootLatency = try XCTUnwrap(report["bootLatency"] as? [String: Any])
        XCTAssertEqual(bootLatency["status"] as? String, "unmeasured")
        let warnings = try XCTUnwrap(report["architectureWarnings"] as? [[String: Any]])
        XCTAssertEqual(warnings.first?["reportedArchitecture"] as? String, "linux/amd64")
        XCTAssertTrue((warnings.first?["message"] as? String ?? "").contains("Rosetta"))
        let limits = try XCTUnwrap(report["limits"] as? [String])
        XCTAssertTrue(limits.contains("No production density or capacity guarantee."))
        XCTAssertTrue(limits.contains("No telemetry upload; reports are local diagnostics only."))

        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let reportText = try XCTUnwrap(String(data: reportData, encoding: .utf8))
        let decodedReport = try ResourceIntelligenceReportParser.parseReport(reportText)
        XCTAssertEqual(decodedReport.measurementMethod, .fixture)
        XCTAssertEqual(decodedReport.appleContainer.version, "container 1.0.0")
        XCTAssertEqual(decodedReport.architectureWarnings.first?.reportedArchitecture, "linux/amd64")
    }

    func testDoctorCompatibilityFailureUsesValidationExitCode() throws {
        let result = HostwrightCLI.run(
            arguments: ["doctor", "--output", "json"],
            environment: environment(files: FileBox(), platform: PlatformSnapshot(macOSMajorVersion: 25, architecture: "x86_64"))
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.validation.rawValue)
        let json = try jsonObject(result.standardOutput)
        XCTAssertEqual(json["hasFailures"] as? Bool, true)
        XCTAssertEqual(json["readiness"] as? String, "unsupported")
    }

    func testDoctorMapsStoppedRuntimeToExternalConstraint() throws {
        let adapter = ScriptedApplyRuntimeAdapter(
            readinessReport: RuntimeReadinessReport(
                runtimeName: "fake-runtime",
                cliVersion: "1.1.0",
                serviceState: .notRunning,
                serviceVersion: nil,
                serviceBuild: nil
            )
        )

        let result = HostwrightCLI.run(
            arguments: ["doctor", "--json"],
            environment: environment(
                files: FileBox(),
                containerPath: "/usr/local/bin/container",
                runtimeAdapter: adapter
            )
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
        let json = try jsonObject(result.standardOutput)
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let service = try XCTUnwrap(checks.first {
            $0["identifier"] as? String == "appleContainerService"
        })
        XCTAssertEqual(service["status"] as? String, "externally-constrained")
        XCTAssertTrue((service["remediation"] as? String)?.contains("container system start") == true)
    }

    func testDoctorBoundsAndRedactsRuntimeProbeFailure() throws {
        let adapter = ScriptedApplyRuntimeAdapter(
            readinessError: .runtimeUnavailable(
                "token=\(fakeSecret) " + String(repeating: "x", count: 4_096)
            )
        )
        let result = HostwrightCLI.run(
            arguments: ["doctor", "--json"],
            environment: environment(
                files: FileBox(),
                containerPath: "/usr/local/bin/container",
                runtimeAdapter: adapter
            )
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
        XCTAssertFalse(result.standardOutput.contains(fakeSecret))
        let json = try jsonObject(result.standardOutput)
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let service = try XCTUnwrap(checks.first {
            $0["identifier"] as? String == "appleContainerService"
        })
        XCTAssertLessThanOrEqual((service["message"] as? String)?.count ?? .max, 512)
    }

    func testDoctorInspectsExistingStateWithoutChangingItsFileSet() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let parent = (databasePath as NSString).deletingLastPathComponent
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: parent
            )
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            let resolution = try HostwrightLocalPathResolver.resolve(
                explicitStateDatabasePath: databasePath,
                homeDirectory: parent,
                environment: [:]
            )
            let before = try doctorFileSetSnapshot(directory: parent)
            var testEnvironment = environment(
                files: FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest]),
                containerPath: "/usr/local/bin/container",
                localPathResolution: { _ in resolution }
            )
            testEnvironment.fileExists = { FileManager.default.fileExists(atPath: $0) }

            let result = HostwrightCLI.run(
                arguments: ["doctor", "--state-db", databasePath, "--json"],
                environment: testEnvironment
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.success.rawValue)
            let json = try jsonObject(result.standardOutput)
            let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
            let state = try XCTUnwrap(checks.first {
                $0["identifier"] as? String == "stateIntegrity"
            })
            XCTAssertEqual(state["status"] as? String, "ready")
            XCTAssertEqual(
                (state["details"] as? [String: Any])?["stateSchemaVersion"] as? String,
                String(HostwrightContractVersions.stateSchema)
            )
            XCTAssertEqual(try doctorFileSetSnapshot(directory: parent), before)
        }
    }

    func testDoctorReportsActiveStateWriteAsRetryableInspectionFailure() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let parent = (databasePath as NSString).deletingLastPathComponent
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: parent
            )
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            let writer = try SQLiteConnection(
                path: databasePath,
                createIfNeeded: false,
                profile: .authoritativeState
            )
            defer { try? writer.close() }
            try writer.execute(
                "CREATE TABLE doctor_active_write (id INTEGER PRIMARY KEY, value TEXT NOT NULL)"
            )
            try writer.execute("BEGIN IMMEDIATE TRANSACTION")
            try writer.run(
                "INSERT INTO doctor_active_write (id, value) VALUES (1, 'uncommitted')"
            )
            let resolution = try HostwrightLocalPathResolver.resolve(
                explicitStateDatabasePath: databasePath,
                homeDirectory: parent,
                environment: [:]
            )
            let before = try doctorFileSetSnapshot(directory: parent)
            var testEnvironment = environment(
                files: FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest]),
                containerPath: "/usr/local/bin/container",
                localPathResolution: { _ in resolution }
            )
            testEnvironment.fileExists = { FileManager.default.fileExists(atPath: $0) }

            let result = HostwrightCLI.run(
                arguments: ["doctor", "--state-db", databasePath, "--json"],
                environment: testEnvironment
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.stateUnavailable.rawValue)
            let json = try jsonObject(result.standardOutput)
            let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
            let state = try XCTUnwrap(checks.first {
                $0["identifier"] as? String == "stateIntegrity"
            })
            XCTAssertEqual(state["status"] as? String, "blocked")
            XCTAssertEqual(
                (state["details"] as? [String: Any])?["availability"] as? String,
                "inspection-failed"
            )
            XCTAssertTrue((state["remediation"] as? String)?.contains("Wait for the active state operation") == true)
            XCTAssertEqual(try doctorFileSetSnapshot(directory: parent), before)

            testEnvironment.platformSnapshot = {
                PlatformSnapshot(macOSMajorVersion: 25, architecture: "x86_64")
            }
            let unsupported = HostwrightCLI.run(
                arguments: ["doctor", "--state-db", databasePath, "--json"],
                environment: testEnvironment
            )
            XCTAssertEqual(unsupported.exitCode, CLIExitCode.validation.rawValue)
            XCTAssertEqual(
                try jsonObject(unsupported.standardOutput)["readiness"] as? String,
                "unsupported"
            )
            XCTAssertEqual(try doctorFileSetSnapshot(directory: parent), before)
        }
    }
}
