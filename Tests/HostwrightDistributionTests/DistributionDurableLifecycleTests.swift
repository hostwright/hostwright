import Darwin
import Foundation
import HostwrightCore
@testable import HostwrightState
@testable import HostwrightDistribution
import XCTest

final class DistributionDurableLifecycleTests: XCTestCase {
    private let baselineCommit = String(repeating: "a", count: 40)
    private let candidateCommit = String(repeating: "b", count: 40)

    func testPackageLifecycleUsesExistingRepairUpgradeRollbackAndDowngradeRules() throws {
        try withTemporaryRoot { root in
            let baseline = try makeVerifiedArtifact(
                root: root,
                name: "package-baseline",
                version: "0.0.2-dev.1",
                commit: baselineCommit
            )
            let candidate = try makeVerifiedArtifact(
                root: root,
                name: "package-candidate",
                version: "0.0.2-dev.2",
                commit: candidateCommit
            )
            let prefix = root.appendingPathComponent("package-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let lifecycle = DistributionInstalledLifecycle()
            let baselineOrigin = DistributionPackageOrigin(
                packageIdentifier: DistributionLayout.packageIdentifier,
                packageVersion: "0.0.2.1",
                mostRecentPackageReceiptVersion: "0.0.2.1"
            )
            let candidateOrigin = DistributionPackageOrigin(
                packageIdentifier: DistributionLayout.packageIdentifier,
                packageVersion: "0.0.2.2",
                mostRecentPackageReceiptVersion: "0.0.2.2"
            )

            let installed = try lifecycle.installPackage(
                manifest: baseline.manifest,
                sourceRoot: baseline.extractedRoot,
                prefix: prefix,
                requiredOperation: .install,
                packageOrigin: baselineOrigin,
                cancellation: SecureSubprocessCancellation()
            )
            XCTAssertEqual(installed.packageOrigin, baselineOrigin)

            let repaired = try lifecycle.install(
                artifact: baseline,
                prefix: prefix,
                requiredOperation: .repair,
                cancellation: SecureSubprocessCancellation()
            )
            XCTAssertEqual(repaired.generation, 2)
            XCTAssertEqual(repaired.packageOrigin, baselineOrigin)

            XCTAssertThrowsError(
                try lifecycle.install(
                    artifact: candidate,
                    prefix: prefix,
                    requiredOperation: .upgrade
                )
            ) { error in
                guard case let DistributionError.versionConflict(message) = error else {
                    return XCTFail("expected package upgrade fence, received \(error)")
                }
                XCTAssertTrue(message.contains("hostwright-dist package-apply"))
            }

            let upgraded = try lifecycle.installPackage(
                manifest: candidate.manifest,
                sourceRoot: candidate.extractedRoot,
                prefix: prefix,
                requiredOperation: .upgrade,
                packageOrigin: candidateOrigin,
                cancellation: SecureSubprocessCancellation()
            )
            XCTAssertEqual(upgraded.generation, 3)
            XCTAssertEqual(upgraded.packageOrigin, candidateOrigin)

            let rolledBack = try lifecycle.rollback(prefix: prefix)
            XCTAssertEqual(rolledBack.installedManifest.packageVersion, "0.0.2-dev.1")
            XCTAssertEqual(rolledBack.packageVersion, "0.0.2.1")
            XCTAssertEqual(rolledBack.mostRecentPackageReceiptVersion, "0.0.2.2")

            let upgradedAgain = try lifecycle.installPackage(
                manifest: candidate.manifest,
                sourceRoot: candidate.extractedRoot,
                prefix: prefix,
                requiredOperation: .upgrade,
                packageOrigin: candidateOrigin,
                cancellation: SecureSubprocessCancellation()
            )
            XCTAssertEqual(upgradedAgain.installedManifest.packageVersion, "0.0.2-dev.2")
            XCTAssertThrowsError(
                try lifecycle.installPackage(
                    manifest: baseline.manifest,
                    sourceRoot: baseline.extractedRoot,
                    prefix: prefix,
                    requiredOperation: .upgrade,
                    packageOrigin: baselineOrigin,
                    cancellation: SecureSubprocessCancellation()
                )
            ) { error in
                XCTAssertEqual(
                    error as? DistributionError,
                    .downgradeRefused(
                        installed: "0.0.2-dev.2",
                        candidate: "0.0.2-dev.1"
                    )
                )
            }
            XCTAssertThrowsError(
                try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
            ) { error in
                guard case let DistributionError.versionConflict(message) = error else {
                    return XCTFail("expected package uninstall fence, received \(error)")
                }
                XCTAssertTrue(message.contains("hostwright-dist package-uninstall"))
            }
        }
    }

    func testPackageUninstallPersistsReceiptCleanupAndRecoverRetriesExactly() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "package-uninstall",
                version: "0.0.2-dev.2",
                commit: candidateCommit
            )
            let prefix = root.appendingPathComponent("package-uninstall-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let staging = root.appendingPathComponent("InstallerPayload", isDirectory: true)
            try makePackageStaging(artifact: artifact, at: staging)

            let receiptMarker = root.appendingPathComponent("receipt-present")
            let failForgetMarker = root.appendingPathComponent("fail-forget")
            let blockReceiptMarker = root.appendingPathComponent("block-receipt")
            try Data().write(to: receiptMarker, options: .withoutOverwriting)
            try Data().write(to: failForgetMarker, options: .withoutOverwriting)
            let pkgutil = root.appendingPathComponent("pkgutil-fixture")
            let pkgutilSource = root.appendingPathComponent("pkgutil-fixture.swift")
            let program = """
            import Foundation
            let arguments = Array(CommandLine.arguments.dropFirst())
            let receipt = "\(receiptMarker.path)"
            let failForget = "\(failForgetMarker.path)"
            let blockReceipt = "\(blockReceiptMarker.path)"
            switch arguments.first {
            case "--pkgs":
                if FileManager.default.fileExists(atPath: blockReceipt) {
                    Thread.sleep(forTimeInterval: 5)
                }
                if FileManager.default.fileExists(atPath: receipt) {
                    print("dev.hostwright.cli")
                }
            case "--pkg-info-plist":
                print("<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><plist version=\\\"1.0\\\"><dict><key>pkgid</key><string>dev.hostwright.cli</string><key>pkg-version</key><string>0.0.2.2</string><key>install-location</key><string>/</string><key>volume</key><string>/</string></dict></plist>")
            case "--forget":
                if FileManager.default.fileExists(atPath: failForget) {
                    exit(1)
                }
                try FileManager.default.removeItem(atPath: receipt)
            default:
                exit(64)
            }
            """ + "\n"
            try Data(program.utf8).write(to: pkgutilSource, options: .withoutOverwriting)
            let compile = Process()
            compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compile.arguments = ["swiftc", pkgutilSource.path, "-o", pkgutil.path]
            try compile.run()
            compile.waitUntilExit()
            XCTAssertEqual(compile.terminationStatus, 0)

            let owner = geteuid()
            let receipts = DistributionPackageReceiptController(
                executablePath: pkgutil.path,
                stagingRoot: staging,
                stagingOwnerUID: owner
            )
            let lifecycle = DistributionInstalledLifecycle(
                packageReceiptController: receipts
            )
            let packageLifecycle = DistributionPackageLifecycle(
                receiptController: receipts,
                lifecycle: lifecycle,
                expectedPrefix: prefix,
                expectedStagingRoot: staging,
                expectedOwnerUID: owner,
                effectiveUserID: 0,
                verifyExecutableSignatures: false
            )
            XCTAssertThrowsError(
                try packageLifecycle.apply(
                    stagedRoot: staging,
                    prefix: prefix,
                    packageIdentifier: DistributionLayout.packageIdentifier,
                    packageVersion: "0.0.2.2",
                    teamIdentifier: "TOO-SHORT"
                )
            ) { error in
                XCTAssertEqual(
                    error as? DistributionError,
                    .invalidArguments(
                        "package-apply requires an exact 10-character Developer Team ID."
                    )
                )
            }
            XCTAssertThrowsError(
                try packageLifecycle.apply(
                    stagedRoot: staging,
                    prefix: prefix,
                    packageIdentifier: DistributionLayout.packageIdentifier,
                    packageVersion: "0.0.2.2",
                    teamIdentifier: "OTHERTEAM1"
                )
            ) { error in
                XCTAssertEqual(
                    error as? DistributionError,
                    .invalidArtifact(
                        "staged executable signer team does not match the package trust policy"
                    )
                )
            }
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .notInstalled)
            let applied = try packageLifecycle.apply(
                stagedRoot: staging,
                prefix: prefix,
                packageIdentifier: DistributionLayout.packageIdentifier,
                packageVersion: "0.0.2.2",
                teamIdentifier: "TESTTEAM01"
            )
            XCTAssertEqual(applied.operation, .install)
            XCTAssertEqual(applied.signerTeamIdentifier, "TESTTEAM01")
            XCTAssertEqual(applied.status.packageVersion, "0.0.2.2")

            XCTAssertThrowsError(
                try packageLifecycle.uninstall(
                    prefix: prefix,
                    dataPolicy: .preserve
                )
            )
            let pending = try lifecycle.inspect(prefix: prefix)
            XCTAssertEqual(pending.readiness, .recoveryRequired)
            XCTAssertEqual(pending.pendingOperation?.operation, .uninstall)
            XCTAssertEqual(pending.status?.pendingReceiptCleanup, true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))

            try FileManager.default.removeItem(at: failForgetMarker)
            try Data().write(to: blockReceiptMarker, options: .withoutOverwriting)
            let cancellation = SecureSubprocessCancellation()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                cancellation.cancel()
            }
            XCTAssertThrowsError(
                try lifecycle.recover(prefix: prefix, cancellation: cancellation)
            ) { error in
                guard case let DistributionError.commandCancelled(command) = error else {
                    return XCTFail("expected receipt cleanup cancellation, received \(error)")
                }
                XCTAssertEqual(command, "list Apple Installer receipts")
            }
            try FileManager.default.removeItem(at: blockReceiptMarker)
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .recoveryRequired)

            let recovered = try lifecycle.recover(prefix: prefix)
            XCTAssertEqual(recovered.action, .completedUninstall)
            XCTAssertFalse(FileManager.default.fileExists(atPath: receiptMarker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: prefix.path).isEmpty)
        }
    }

    func testInterruptedUpgradeRecoversThenUpgradeAndVerifiedRollbackRestoreBinaryAndState() throws {
        try withTemporaryRoot { root in
            let baseline = try makeVerifiedArtifact(
                root: root,
                name: "baseline",
                version: "0.0.1",
                commit: baselineCommit
            )
            let candidate = try makeVerifiedArtifact(
                root: root,
                name: "candidate",
                version: "0.0.2-dev",
                commit: candidateCommit
            )
            let prefix = root.appendingPathComponent("hostwright-dist-prefix-durable", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
            try FileManager.default.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let state = SQLiteStateStore(path: stateDirectory.appendingPathComponent("state.sqlite").path)
            try MigrationRunner().apply(to: state, throughVersion: 6)
            let seed = try SQLiteConnection(path: state.path, createIfNeeded: false)
            try seed.run(
                """
                INSERT INTO event_ledger (
                    id, timestamp, severity, type, source, project_id, service_name,
                    runtime_adapter, message, payload_json_redacted
                ) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?)
                """,
                bindings: [
                    .text("pre-upgrade-authority"),
                    .text("2026-07-14T16:00:00Z"),
                    .text("info"),
                    .text("distribution.upgrade.test"),
                    .text("distribution-tests"),
                    .text("preserve authoritative state across upgrade rollback"),
                    .text("{}")
                ]
            )
            try seed.close()
            let stateDigestV6 = try fileDigest(URL(fileURLWithPath: state.path))

            let lifecycle = DistributionInstalledLifecycle()
            let installed = try lifecycle.install(
                artifact: baseline,
                prefix: prefix,
                stateDatabasePath: state.path
            )
            XCTAssertEqual(installed.generation, 1)
            XCTAssertEqual(installed.installedManifest.packageVersion, "0.0.1")
            XCTAssertNil(installed.rollbackOperationID)
            XCTAssertEqual(try state.schemaVersion(), 6)

            let interruptedLifecycle = DistributionInstalledLifecycle(
                interruptAfter: .payloadPublished
            )
            XCTAssertThrowsError(
                try interruptedLifecycle.install(
                    artifact: candidate,
                    prefix: prefix,
                    stateDatabasePath: state.path
                )
            ) { error in
                XCTAssertEqual(
                    error as? DistributionLifecycleInterruption,
                    .after(.payloadPublished)
                )
            }
            let interrupted = try lifecycle.inspect(prefix: prefix)
            XCTAssertEqual(interrupted.readiness, .recoveryRequired)
            XCTAssertEqual(interrupted.pendingOperation?.operation, .upgrade)

            let recovered = try lifecycle.recover(prefix: prefix)
            XCTAssertEqual(recovered.action, .restoredPriorGeneration)
            XCTAssertEqual(recovered.status?.installedManifest.packageVersion, "0.0.1")
            XCTAssertEqual(try state.schemaVersion(), 6)
            XCTAssertEqual(try fileDigest(URL(fileURLWithPath: state.path)), stateDigestV6)
            XCTAssertEqual(
                try runInstalled(prefix.appendingPathComponent("bin/hostwright"), arguments: ["--version"]),
                "0.0.1\n"
            )

            let upgraded = try lifecycle.install(
                artifact: candidate,
                prefix: prefix,
                stateDatabasePath: state.path
            )
            XCTAssertEqual(upgraded.generation, 2)
            XCTAssertEqual(upgraded.installedManifest.packageVersion, "0.0.2-dev")
            XCTAssertNotNil(upgraded.rollbackOperationID)
            XCTAssertEqual(try state.schemaVersion(), MigrationRunner.latestSchemaVersion)

            XCTAssertThrowsError(
                try lifecycle.install(
                    artifact: baseline,
                    prefix: prefix,
                    stateDatabasePath: state.path
                )
            ) { error in
                XCTAssertEqual(
                    error as? DistributionError,
                    .downgradeRefused(installed: "0.0.2-dev", candidate: "0.0.1")
                )
            }

            let rolledBack = try lifecycle.rollback(prefix: prefix)
            XCTAssertEqual(rolledBack.generation, 3)
            XCTAssertEqual(rolledBack.installedManifest.packageVersion, "0.0.1")
            XCTAssertNil(rolledBack.rollbackOperationID)
            XCTAssertEqual(try state.schemaVersion(), 6)
            XCTAssertTrue(try eventIDs(state.path).contains("pre-upgrade-authority"))
            XCTAssertEqual(
                try runInstalled(prefix.appendingPathComponent("bin/hostwright"), arguments: ["--version"]),
                "0.0.1\n"
            )

            let removed = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
            XCTAssertTrue(removed.removedPaths.contains("bin/hostwright"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
            XCTAssertEqual(try state.schemaVersion(), 6)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), [])
        }
    }

    func testRollbackRefusesStatePresenceMismatch() throws {
        try withTemporaryRoot { root in
            let baseline = try makeVerifiedArtifact(
                root: root,
                name: "rollback-presence-baseline",
                version: "0.0.1",
                commit: baselineCommit
            )
            let candidate = try makeVerifiedArtifact(
                root: root,
                name: "rollback-presence-candidate",
                version: "0.0.2-dev",
                commit: candidateCommit
            )
            let lifecycle = DistributionInstalledLifecycle()

            let presentPrefix = root.appendingPathComponent("rollback-present-prefix", isDirectory: true)
            let presentStateDirectory = root.appendingPathComponent("rollback-present-state", isDirectory: true)
            try FileManager.default.createDirectory(at: presentPrefix, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: presentStateDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let presentState = SQLiteStateStore(
                path: presentStateDirectory.appendingPathComponent("state.sqlite").path
            )
            try MigrationRunner().apply(to: presentState, throughVersion: 6)
            _ = try lifecycle.install(
                artifact: baseline,
                prefix: presentPrefix,
                stateDatabasePath: presentState.path
            )
            let presentUpgrade = try lifecycle.install(
                artifact: candidate,
                prefix: presentPrefix,
                stateDatabasePath: presentState.path
            )
            _ = try StateDatabaseRemovalService(store: presentState).removeVerifiedDatabase()

            XCTAssertThrowsError(try lifecycle.rollback(prefix: presentPrefix)) { error in
                guard case let DistributionError.lifecycleFailed(message) = error else {
                    return XCTFail("Expected lifecycle failure, received \(error)")
                }
                XCTAssertTrue(message.contains("state presence no longer matches"))
            }
            let presentInspection = try lifecycle.inspect(prefix: presentPrefix)
            XCTAssertEqual(presentInspection.readiness, .ready)
            XCTAssertEqual(presentInspection.status, presentUpgrade)
            _ = try lifecycle.uninstall(prefix: presentPrefix, dataPolicy: .preserve)

            let absentPrefix = root.appendingPathComponent("rollback-absent-prefix", isDirectory: true)
            let absentStateDirectory = root.appendingPathComponent("rollback-absent-state", isDirectory: true)
            try FileManager.default.createDirectory(at: absentPrefix, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: absentStateDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let absentState = SQLiteStateStore(
                path: absentStateDirectory.appendingPathComponent("state.sqlite").path
            )
            _ = try lifecycle.install(
                artifact: baseline,
                prefix: absentPrefix,
                stateDatabasePath: absentState.path
            )
            let absentUpgrade = try lifecycle.install(
                artifact: candidate,
                prefix: absentPrefix,
                stateDatabasePath: absentState.path
            )
            try MigrationRunner().apply(to: absentState)

            XCTAssertThrowsError(try lifecycle.rollback(prefix: absentPrefix)) { error in
                guard case let DistributionError.lifecycleFailed(message) = error else {
                    return XCTFail("Expected lifecycle failure, received \(error)")
                }
                XCTAssertTrue(message.contains("state presence no longer matches"))
            }
            let absentInspection = try lifecycle.inspect(prefix: absentPrefix)
            XCTAssertEqual(absentInspection.readiness, .ready)
            XCTAssertEqual(absentInspection.status, absentUpgrade)
            _ = try lifecycle.uninstall(prefix: absentPrefix, dataPolicy: .preserve)
        }
    }

    func testEveryDurableUpgradeCheckpointRecoversOrFinalizesOneConsistentGeneration() throws {
        try withTemporaryRoot { root in
            let baseline = try makeVerifiedArtifact(
                root: root,
                name: "checkpoint-baseline",
                version: "0.0.1",
                commit: baselineCommit
            )
            let candidate = try makeVerifiedArtifact(
                root: root,
                name: "checkpoint-candidate",
                version: "0.0.2-dev",
                commit: candidateCommit
            )
            let checkpoints: [DistributionLifecycleCheckpoint] = [
                .intentRecorded,
                .payloadStaged,
                .priorPayloadBackedUp,
                .stateBackedUp,
                .payloadPublishing,
                .payloadPublished,
                .stateMigrating,
                .stateMigrated,
                .verifying,
                .statusPublished
            ]

            for (index, checkpoint) in checkpoints.enumerated() {
                let prefix = root.appendingPathComponent(
                    "hostwright-dist-prefix-checkpoint-\(index)",
                    isDirectory: true
                )
                let stateDirectory = root.appendingPathComponent("state-checkpoint-\(index)", isDirectory: true)
                try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
                try FileManager.default.createDirectory(
                    at: stateDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let state = SQLiteStateStore(path: stateDirectory.appendingPathComponent("state.sqlite").path)
                try MigrationRunner().apply(to: state, throughVersion: 6)
                let lifecycle = DistributionInstalledLifecycle()
                _ = try lifecycle.install(
                    artifact: baseline,
                    prefix: prefix,
                    stateDatabasePath: state.path
                )

                XCTAssertThrowsError(
                    try DistributionInstalledLifecycle(interruptAfter: checkpoint).install(
                        artifact: candidate,
                        prefix: prefix,
                        stateDatabasePath: state.path
                    ),
                    "checkpoint \(checkpoint.rawValue)"
                ) { error in
                    XCTAssertEqual(
                        error as? DistributionLifecycleInterruption,
                        .after(checkpoint),
                        "checkpoint \(checkpoint.rawValue)"
                    )
                }
                let recovery = try lifecycle.recover(prefix: prefix)
                if checkpoint == .statusPublished {
                    XCTAssertEqual(recovery.action, .completedPublishedGeneration)
                    XCTAssertEqual(recovery.status?.installedManifest.packageVersion, "0.0.2-dev")
                    XCTAssertEqual(try state.schemaVersion(), MigrationRunner.latestSchemaVersion)
                } else {
                    XCTAssertEqual(recovery.action, .restoredPriorGeneration, checkpoint.rawValue)
                    XCTAssertEqual(recovery.status?.installedManifest.packageVersion, "0.0.1")
                    XCTAssertEqual(try state.schemaVersion(), 6)
                }
                XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .ready)
                _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), [])
            }
        }
    }

    func testLegacyManifestAdoptionIsExplicitVerifiedAndRepairMigratesOwnershipSchema() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "legacy-candidate",
                version: "0.0.1",
                commit: String(repeating: "c", count: 40)
            )
            let lifecycle = DistributionInstalledLifecycle()
            let prefix = root.appendingPathComponent("legacy-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            try installLegacyPayload(artifact: artifact, prefix: prefix)

            XCTAssertThrowsError(try lifecycle.inspect(prefix: prefix)) { error in
                guard case let DistributionError.lifecycleFailed(message) = error else {
                    return XCTFail("Expected lifecycle failure, received \(error)")
                }
                XCTAssertTrue(message.contains("adopt-legacy"))
            }
            let adopted = try lifecycle.adoptLegacyInstallation(prefix: prefix)
            XCTAssertEqual(adopted.generation, 1)
            XCTAssertEqual(adopted.installedManifest.schemaVersion, 1)
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .ready)
            XCTAssertFalse(DistributionFileSystem.entryExists(
                prefix.appendingPathComponent("bin/hostwright-dist")
            ))

            let repaired = try lifecycle.install(artifact: artifact, prefix: prefix)
            XCTAssertEqual(repaired.generation, 2)
            XCTAssertEqual(repaired.installedManifest.schemaVersion, 2)
            XCTAssertTrue(try DistributionFileSystem.isRegularNonSymlink(
                prefix.appendingPathComponent("bin/hostwright-dist")
            ))
            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
            for path in DistributionLayout.payloadModes.keys {
                XCTAssertFalse(DistributionFileSystem.entryExists(prefix.appendingPathComponent(path)))
            }

            let tamperedPrefix = root.appendingPathComponent("tampered-legacy-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: tamperedPrefix, withIntermediateDirectories: false)
            try installLegacyPayload(artifact: artifact, prefix: tamperedPrefix)
            let binary = tamperedPrefix.appendingPathComponent("bin/hostwright")
            let writer = try FileHandle(forWritingTo: binary)
            try writer.seekToEnd()
            try writer.write(contentsOf: Data("tampered".utf8))
            try writer.close()
            XCTAssertThrowsError(try lifecycle.adoptLegacyInstallation(prefix: tamperedPrefix)) {
                XCTAssertEqual($0 as? DistributionError, .installOwnershipMismatch("bin/hostwright"))
            }
            XCTAssertFalse(DistributionFileSystem.entryExists(
                tamperedPrefix.appendingPathComponent(DistributionLayout.lifecycleDirectoryName)
            ))
        }
    }

    func testRepairRestoresMissingOwnedFileAndInterruptedRepairRestoresExactMissingState() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "repair-artifact",
                version: "0.0.1",
                commit: String(repeating: "d", count: 40)
            )
            let prefix = root.appendingPathComponent("repair-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let lifecycle = DistributionInstalledLifecycle()
            let baseline = try lifecycle.install(artifact: artifact, prefix: prefix)
            let missing = prefix.appendingPathComponent("share/doc/hostwright/README.md")
            try FileManager.default.removeItem(at: missing)

            let interrupted = DistributionInstalledLifecycle(interruptAfter: .payloadPublished)
            XCTAssertThrowsError(try interrupted.install(artifact: artifact, prefix: prefix)) {
                XCTAssertEqual(
                    $0 as? DistributionLifecycleInterruption,
                    .after(.payloadPublished)
                )
            }
            XCTAssertTrue(DistributionFileSystem.entryExists(missing))
            let recovered = try lifecycle.recover(prefix: prefix)
            XCTAssertEqual(recovered.action, .restoredPriorGeneration)
            XCTAssertEqual(recovered.status, baseline)
            XCTAssertFalse(DistributionFileSystem.entryExists(missing))
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .ready)

            let repaired = try lifecycle.install(artifact: artifact, prefix: prefix)
            XCTAssertEqual(repaired.generation, baseline.generation + 1)
            XCTAssertTrue(try DistributionFileSystem.isRegularNonSymlink(missing))
            XCTAssertEqual(
                try DistributionHash.sha256(fileURL: missing),
                try XCTUnwrap(artifact.manifest.files.first { $0.path == "share/doc/hostwright/README.md" }).sha256
            )
            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
        }
    }

    func testRequiredOperationRejectsLockedStateMismatchWithoutMutation() throws {
        try withTemporaryRoot { root in
            let baseline = try makeVerifiedArtifact(
                root: root,
                name: "required-operation-baseline",
                version: "0.0.1",
                commit: baselineCommit
            )
            let candidate = try makeVerifiedArtifact(
                root: root,
                name: "required-operation-candidate",
                version: "0.0.2-dev",
                commit: candidateCommit
            )
            let prefix = root.appendingPathComponent("required-operation-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let lifecycle = DistributionInstalledLifecycle()

            XCTAssertThrowsError(
                try lifecycle.install(
                    artifact: baseline,
                    prefix: prefix,
                    requiredOperation: .upgrade
                )
            ) { error in
                guard case let DistributionError.versionConflict(message) = error else {
                    return XCTFail("Expected version conflict, received \(error)")
                }
                XCTAssertTrue(message.contains("Requested upgrade"))
                XCTAssertTrue(message.contains("requires install"))
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), [])

            let installed = try lifecycle.install(
                artifact: baseline,
                prefix: prefix,
                requiredOperation: .install
            )
            XCTAssertThrowsError(
                try lifecycle.install(
                    artifact: baseline,
                    prefix: prefix,
                    requiredOperation: .upgrade
                )
            ) { error in
                guard case let DistributionError.versionConflict(message) = error else {
                    return XCTFail("Expected version conflict, received \(error)")
                }
                XCTAssertTrue(message.contains("Requested upgrade"))
                XCTAssertTrue(message.contains("requires repair"))
            }
            XCTAssertThrowsError(
                try lifecycle.install(
                    artifact: candidate,
                    prefix: prefix,
                    requiredOperation: .repair
                )
            ) { error in
                guard case let DistributionError.versionConflict(message) = error else {
                    return XCTFail("Expected version conflict, received \(error)")
                }
                XCTAssertTrue(message.contains("Requested repair"))
                XCTAssertTrue(message.contains("requires upgrade"))
            }
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).status, installed)

            let upgraded = try lifecycle.install(
                artifact: candidate,
                prefix: prefix,
                requiredOperation: .upgrade
            )
            XCTAssertEqual(upgraded.generation, 2)
            XCTAssertEqual(upgraded.installedManifest.packageVersion, "0.0.2-dev")
            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
        }
    }

    func testRemoveDataRequiresCurrentPlanAndInterruptedRemovalRestoresPayloadAndState() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "remove-data-artifact",
                version: "0.0.1",
                commit: String(repeating: "e", count: 40)
            )
            let prefix = root.appendingPathComponent("remove-data-prefix", isDirectory: true)
            let stateDirectory = root.appendingPathComponent("remove-data-state", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let state = SQLiteStateStore(path: stateDirectory.appendingPathComponent("state.sqlite").path)
            try MigrationRunner().apply(to: state)
            let lifecycle = DistributionInstalledLifecycle()
            _ = try lifecycle.install(
                artifact: artifact,
                prefix: prefix,
                stateDatabasePath: state.path
            )

            XCTAssertThrowsError(
                try lifecycle.uninstall(prefix: prefix, dataPolicy: .remove)
            ) { error in
                guard case let DistributionError.lifecycleFailed(message) = error else {
                    return XCTFail("Expected lifecycle failure, received \(error)")
                }
                XCTAssertTrue(message.contains("confirmation token"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .ready)

            let stalePlan = try lifecycle.uninstallPlan(prefix: prefix, dataPolicy: .remove)
            _ = try lifecycle.install(artifact: artifact, prefix: prefix)
            XCTAssertThrowsError(
                try lifecycle.uninstall(
                    prefix: prefix,
                    dataPolicy: .remove,
                    confirmationToken: stalePlan.confirmationToken
                )
            )
            let plan = try lifecycle.uninstallPlan(prefix: prefix, dataPolicy: .remove)
            XCTAssertEqual(plan.stateDatabasePath, state.path)
            XCTAssertEqual(plan.dataPolicy, .remove)

            let interrupted = DistributionInstalledLifecycle(interruptAfter: .stateMigrated)
            XCTAssertThrowsError(
                try interrupted.uninstall(
                    prefix: prefix,
                    dataPolicy: .remove,
                    confirmationToken: plan.confirmationToken
                )
            ) { error in
                XCTAssertEqual(
                    error as? DistributionLifecycleInterruption,
                    .after(.stateMigrated)
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .recoveryRequired)
            let recovered = try lifecycle.recover(prefix: prefix)
            XCTAssertEqual(recovered.action, .restoredPriorGeneration)
            XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
            XCTAssertEqual(try state.schemaVersion(), MigrationRunner.latestSchemaVersion)
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .ready)

            let currentPlan = try lifecycle.uninstallPlan(prefix: prefix, dataPolicy: .remove)
            let removed = try lifecycle.uninstall(
                prefix: prefix,
                dataPolicy: .remove,
                confirmationToken: currentPlan.confirmationToken
            )
            XCTAssertEqual(removed.dataPolicy, .remove)
            XCTAssertTrue(removed.removedStatePaths.contains(state.path))
            XCTAssertNil(removed.preservedStateDatabasePath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), [])
        }
    }

    func testRemovePlanBindsStateRevisionAndRejectsStaleStateContent() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "state-revision-plan-artifact",
                version: "0.0.1",
                commit: String(repeating: "2", count: 40)
            )
            let prefix = root.appendingPathComponent("state-revision-plan-prefix", isDirectory: true)
            let stateDirectory = root.appendingPathComponent("state-revision-plan-state", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let state = SQLiteStateStore(path: stateDirectory.appendingPathComponent("state.sqlite").path)
            try MigrationRunner().apply(to: state)
            let lifecycle = DistributionInstalledLifecycle()
            _ = try lifecycle.install(
                artifact: artifact,
                prefix: prefix,
                stateDatabasePath: state.path
            )

            let stalePlan = try lifecycle.uninstallPlan(prefix: prefix, dataPolicy: .remove)
            let stateURL = URL(fileURLWithPath: state.path)
            XCTAssertEqual(stalePlan.stateDatabasePath, state.path)
            XCTAssertTrue(stalePlan.stateDatabaseExists)
            XCTAssertEqual(stalePlan.stateDatabaseSHA256, try fileDigest(stateURL))
            XCTAssertEqual(stalePlan.stateDatabaseBytes, UInt64(try DistributionFileSystem.size(of: stateURL)))
            XCTAssertEqual(stalePlan.stateSchemaVersion, MigrationRunner.latestSchemaVersion)

            let connection = try SQLiteConnection(path: state.path, createIfNeeded: false)
            try connection.run(
                """
                INSERT INTO event_ledger (
                    id, timestamp, severity, type, source, project_id, service_name,
                    runtime_adapter, message, payload_json_redacted
                ) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?)
                """,
                bindings: [
                    .text("uninstall-plan-state-revision"),
                    .text("2026-07-14T20:00:00Z"),
                    .text("info"),
                    .text("distribution.uninstall-plan.test"),
                    .text("distribution-tests"),
                    .text("invalidate the prior uninstall plan"),
                    .text("{}")
                ]
            )
            try connection.close()

            XCTAssertThrowsError(
                try lifecycle.uninstall(
                    prefix: prefix,
                    dataPolicy: .remove,
                    confirmationToken: stalePlan.confirmationToken
                )
            ) { error in
                guard case let DistributionError.lifecycleFailed(message) = error else {
                    return XCTFail("Expected lifecycle failure, received \(error)")
                }
                XCTAssertTrue(message.contains("exact current uninstall-plan confirmation token"))
            }
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .ready)
            let currentPlan = try lifecycle.uninstallPlan(prefix: prefix, dataPolicy: .remove)
            XCTAssertNotEqual(currentPlan.confirmationToken, stalePlan.confirmationToken)
            XCTAssertNotEqual(currentPlan.stateDatabaseSHA256, stalePlan.stateDatabaseSHA256)
            _ = try lifecycle.uninstall(
                prefix: prefix,
                dataPolicy: .remove,
                confirmationToken: currentPlan.confirmationToken
            )
        }
    }

    func testRemoveDataRefusesInstallationWithoutBoundStatePath() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "unbound-remove-artifact",
                version: "0.0.1",
                commit: String(repeating: "3", count: 40)
            )
            let prefix = root.appendingPathComponent("unbound-remove-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let lifecycle = DistributionInstalledLifecycle()
            let installed = try lifecycle.install(artifact: artifact, prefix: prefix)

            XCTAssertThrowsError(
                try lifecycle.uninstallPlan(prefix: prefix, dataPolicy: .remove)
            ) { error in
                guard case let DistributionError.lifecycleFailed(message) = error else {
                    return XCTFail("Expected lifecycle failure, received \(error)")
                }
                XCTAssertTrue(message.contains("installation-bound state database"))
            }
            XCTAssertThrowsError(
                try lifecycle.uninstall(
                    prefix: prefix,
                    dataPolicy: .remove,
                    confirmationToken: String(repeating: "a", count: 64)
                )
            ) { error in
                guard case let DistributionError.lifecycleFailed(message) = error else {
                    return XCTFail("Expected lifecycle failure, received \(error)")
                }
                XCTAssertTrue(message.contains("installation-bound state database"))
            }
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).status, installed)
            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
        }
    }

    func testPreservePlanDoesNotMutateBoundSQLiteFiles() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "preserve-plan-artifact",
                version: "0.0.1",
                commit: String(repeating: "4", count: 40)
            )
            let prefix = root.appendingPathComponent("preserve-plan-prefix", isDirectory: true)
            let stateDirectory = root.appendingPathComponent("preserve-plan-state", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let state = SQLiteStateStore(path: stateDirectory.appendingPathComponent("state.sqlite").path)
            try MigrationRunner().apply(to: state)
            try EventLedger(store: state).append([
                EventRecord(
                    id: "preserve-plan-state",
                    timestamp: "2026-07-14T20:00:00Z",
                    severity: .info,
                    type: "distribution.uninstall.plan",
                    source: "distribution-tests",
                    projectID: nil,
                    serviceName: nil,
                    runtimeAdapter: nil,
                    message: "preserve plan must not checkpoint state",
                    payloadJSONRedacted: "{}"
                )
            ])
            let lifecycle = DistributionInstalledLifecycle()
            _ = try lifecycle.install(
                artifact: artifact,
                prefix: prefix,
                stateDatabasePath: state.path
            )
            let before = try regularFileContents(in: stateDirectory)

            let plan = try lifecycle.uninstallPlan(prefix: prefix, dataPolicy: .preserve)

            XCTAssertEqual(plan.dataPolicy, .preserve)
            XCTAssertTrue(plan.stateDatabaseExists)
            XCTAssertNil(plan.stateDatabaseSHA256)
            XCTAssertNil(plan.stateDatabaseBytes)
            XCTAssertNil(plan.stateSchemaVersion)
            XCTAssertEqual(try regularFileContents(in: stateDirectory), before)
            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
        }
    }

    func testLifecycleEvidenceUsesStrictUpgradeAndVerifiedRollback() throws {
        try withTemporaryRoot { root in
            _ = try makeVerifiedArtifact(
                root: root,
                name: "evidence-baseline",
                version: "0.0.1",
                commit: baselineCommit
            )
            _ = try makeVerifiedArtifact(
                root: root,
                name: "evidence-candidate",
                version: "0.0.2-dev",
                commit: candidateCommit
            )
            let prefix = root.appendingPathComponent(
                "hostwright-dist-evidence-prefix",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let sentinel = prefix.appendingPathComponent("operator-sentinel")
            try Data("keep".utf8).write(to: sentinel, options: .withoutOverwriting)
            let reportURL = root.appendingPathComponent("lifecycle-evidence.json")
            let report = try DistributionLifecycleRunner().run(
                baselineDirectory: root.appendingPathComponent("evidence-baseline"),
                candidateDirectory: root.appendingPathComponent("evidence-candidate"),
                prefix: prefix,
                reportURL: reportURL
            )
            XCTAssertEqual(report.schemaVersion, 2)
            XCTAssertEqual(
                report.stages.map(\.identifier),
                ["install", "upgrade", "rollback", "uninstall"]
            )
            XCTAssertTrue(report.stages.allSatisfy { $0.status == .passed })
            XCTAssertEqual(report.evidence.cleanup.status, .succeeded)
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
            XCTAssertEqual(try DistributionFileSystem.mode(of: reportURL), 0o600)

            let duplicateStageReport = DistributionLifecycleReport(
                baselineCommit: report.baselineCommit,
                candidateCommit: report.candidateCommit,
                prefix: report.prefix,
                stages: report.stages + [report.stages[0]],
                preservedPaths: report.preservedPaths,
                evidence: report.evidence
            )
            XCTAssertThrowsError(try duplicateStageReport.validate())
        }
    }

    func testPreCancelledLifecycleMutationsCreateNoEffectsAndPreserveInstallation() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "cancelled-artifact",
                version: "0.0.1",
                commit: String(repeating: "f", count: 40)
            )
            let prefix = root.appendingPathComponent("cancelled-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let cancellation = SecureSubprocessCancellation()
            cancellation.cancel()
            XCTAssertThrowsError(
                try DistributionInstalledLifecycle().install(
                    artifact: artifact,
                    prefix: prefix,
                    cancellation: cancellation
                )
            ) { error in
                guard case DistributionError.commandCancelled = error else {
                    return XCTFail("Expected cancellation, received \(error)")
                }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), [])

            let lifecycle = DistributionInstalledLifecycle()
            let status = try lifecycle.install(artifact: artifact, prefix: prefix)
            XCTAssertThrowsError(
                try lifecycle.uninstall(
                    prefix: prefix,
                    dataPolicy: .preserve,
                    cancellation: cancellation
                )
            ) { error in
                guard case DistributionError.commandCancelled = error else {
                    return XCTFail("Expected cancellation, received \(error)")
                }
            }
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).status, status)
            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
        }
    }

    func testRejectedInitialInstallRemovesNewLifecycleFoundation() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "rejected-install-artifact",
                version: "0.0.1",
                commit: baselineCommit
            )
            let prefix = root.appendingPathComponent("rejected-install-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let bin = prefix.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
            let unmanaged = bin.appendingPathComponent("hostwright")
            try Data("operator-owned\n".utf8).write(to: unmanaged, options: .withoutOverwriting)

            XCTAssertThrowsError(
                try DistributionInstalledLifecycle().install(artifact: artifact, prefix: prefix)
            ) { error in
                XCTAssertEqual(
                    error as? DistributionError,
                    .installOwnershipMismatch("bin/hostwright")
                )
            }
            XCTAssertEqual(try String(contentsOf: unmanaged, encoding: .utf8), "operator-owned\n")
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: prefix.path),
                ["bin"]
            )
        }
    }

    func testIntentAndCanonicalStageFailuresLeaveNoOrphanTransaction() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "intent-order-artifact",
                version: "0.0.1",
                commit: String(repeating: "5", count: 40)
            )
            let prefix = root.appendingPathComponent("intent-order-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)

            XCTAssertThrowsError(
                try DistributionInstalledLifecycle(interruptAfter: .intentRecorded)
                    .install(artifact: artifact, prefix: prefix)
            ) { error in
                XCTAssertEqual(
                    error as? DistributionLifecycleInterruption,
                    .after(.intentRecorded)
                )
            }
            let transactionRoot = prefix.appendingPathComponent(
                "\(DistributionLayout.lifecycleDirectoryName)/\(DistributionLayout.lifecycleTransactionsDirectoryName)",
                isDirectory: true
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: transactionRoot.path),
                []
            )
            XCTAssertEqual(
                try DistributionInstalledLifecycle().recover(prefix: prefix).action,
                .removedInterruptedInitialInstall
            )

            let installed = try DistributionInstalledLifecycle().install(
                artifact: artifact,
                prefix: prefix
            )
            XCTAssertThrowsError(
                try DistributionInstalledLifecycle(
                    interruptAfter: nil,
                    interruptAfterCanonicalStageWriteFor:
                        DistributionLayout.lifecycleJournalFileName
                ).install(
                    artifact: artifact,
                    prefix: prefix,
                    requiredOperation: .repair
                )
            ) { error in
                XCTAssertEqual(
                    error as? DistributionLifecycleInterruption,
                    .afterCanonicalStageSynced(DistributionLayout.lifecycleJournalFileName)
                )
            }
            let journalStage = prefix.appendingPathComponent(
                "\(DistributionLayout.lifecycleDirectoryName)/.\(DistributionLayout.lifecycleJournalFileName).next"
            )
            XCTAssertTrue(DistributionFileSystem.entryExists(journalStage))
            let lifecycle = DistributionInstalledLifecycle()
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .recoveryRequired)
            XCTAssertThrowsError(
                try lifecycle.uninstallPlan(prefix: prefix, dataPolicy: .preserve)
            ) { error in
                XCTAssertEqual(
                    error as? DistributionError,
                    .lifecycleFailed(
                        "an incomplete canonical lifecycle write requires hostwright-dist recover before uninstall planning"
                    )
                )
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: journalStage.path
            )
            XCTAssertThrowsError(try lifecycle.recover(prefix: prefix)) { error in
                XCTAssertEqual(
                    error as? DistributionError,
                    .installOwnershipMismatch(journalStage.lastPathComponent)
                )
            }
            XCTAssertTrue(DistributionFileSystem.entryExists(journalStage))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: journalStage.path
            )
            let unrelatedStage = journalStage.deletingLastPathComponent()
                .appendingPathComponent(".operator-owned.next")
            try DistributionFileSystem.writeNewFile(
                Data("operator-owned\n".utf8),
                to: unrelatedStage,
                mode: 0o600
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: transactionRoot.path),
                []
            )
            let recovered = try lifecycle.recover(prefix: prefix)
            XCTAssertEqual(recovered.action, .noAction)
            XCTAssertEqual(recovered.status, installed)
            XCTAssertFalse(DistributionFileSystem.entryExists(journalStage))
            XCTAssertTrue(DistributionFileSystem.entryExists(unrelatedStage))
            try FileManager.default.removeItem(at: unrelatedStage)
            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
        }
    }

    func testStatusCanonicalStageRecoversExactPriorGeneration() throws {
        try withTemporaryRoot { root in
            let baseline = try makeVerifiedArtifact(
                root: root,
                name: "canonical-status-baseline",
                version: "0.0.1",
                commit: baselineCommit
            )
            let candidate = try makeVerifiedArtifact(
                root: root,
                name: "canonical-status-candidate",
                version: "0.0.2-dev",
                commit: candidateCommit
            )
            let prefix = root.appendingPathComponent("canonical-status-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let lifecycle = DistributionInstalledLifecycle()
            let prior = try lifecycle.install(artifact: baseline, prefix: prefix)
            let lifecycleRoot = prefix.appendingPathComponent(
                DistributionLayout.lifecycleDirectoryName,
                isDirectory: true
            )
            let statusURL = lifecycleRoot.appendingPathComponent(
                DistributionLayout.lifecycleStatusFileName
            )
            let manifestURL = prefix.appendingPathComponent(
                DistributionLayout.installManifestFileName
            )
            let executableURL = prefix.appendingPathComponent("bin/hostwright")
            let priorStatus = try Data(contentsOf: statusURL)
            let priorManifest = try Data(contentsOf: manifestURL)
            let priorExecutableDigest = try fileDigest(executableURL)

            XCTAssertThrowsError(
                try DistributionInstalledLifecycle(
                    interruptAfter: nil,
                    interruptAfterCanonicalStageWriteFor:
                        DistributionLayout.lifecycleStatusFileName
                ).install(artifact: candidate, prefix: prefix)
            ) { error in
                XCTAssertEqual(
                    error as? DistributionLifecycleInterruption,
                    .afterCanonicalStageSynced(DistributionLayout.lifecycleStatusFileName)
                )
            }
            let statusStage = lifecycleRoot.appendingPathComponent(
                ".\(DistributionLayout.lifecycleStatusFileName).next"
            )
            XCTAssertTrue(DistributionFileSystem.entryExists(statusStage))
            XCTAssertEqual(try Data(contentsOf: statusURL), priorStatus)
            let pending = try lifecycle.inspect(prefix: prefix)
            XCTAssertEqual(pending.readiness, .recoveryRequired)
            XCTAssertEqual(pending.status, prior)
            XCTAssertEqual(pending.pendingOperation?.checkpoint, .verifying)

            let recovered = try lifecycle.recover(prefix: prefix)
            XCTAssertEqual(recovered.action, .restoredPriorGeneration)
            XCTAssertEqual(recovered.status, prior)
            XCTAssertFalse(DistributionFileSystem.entryExists(statusStage))
            XCTAssertEqual(try Data(contentsOf: statusURL), priorStatus)
            XCTAssertEqual(try Data(contentsOf: manifestURL), priorManifest)
            XCTAssertEqual(try fileDigest(executableURL), priorExecutableDigest)
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .ready)
            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
        }
    }

    func testRecoveryRestoresPriorGenerationWhenStatusWriteOutrunsJournalCheckpoint() throws {
        try withTemporaryRoot { root in
            let baseline = try makeVerifiedArtifact(
                root: root,
                name: "status-window-baseline",
                version: "0.0.1",
                commit: baselineCommit
            )
            let candidate = try makeVerifiedArtifact(
                root: root,
                name: "status-window-candidate",
                version: "0.0.2-dev",
                commit: candidateCommit
            )
            let prefix = root.appendingPathComponent("status-window-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let lifecycle = DistributionInstalledLifecycle()
            let prior = try lifecycle.install(artifact: baseline, prefix: prefix)

            let interrupted = DistributionInstalledLifecycle(
                interruptAfter: nil,
                interruptAfterStatusWrite: true
            )
            XCTAssertThrowsError(try interrupted.install(artifact: candidate, prefix: prefix)) {
                XCTAssertEqual(
                    $0 as? DistributionLifecycleInterruption,
                    .afterStatusWriteBeforeJournal
                )
            }
            let pending = try lifecycle.inspect(prefix: prefix)
            XCTAssertEqual(pending.readiness, .recoveryRequired)
            XCTAssertEqual(pending.pendingOperation?.checkpoint, .verifying)
            XCTAssertEqual(pending.status?.installedManifest.packageVersion, "0.0.2-dev")

            let recovery = try lifecycle.recover(prefix: prefix)
            XCTAssertEqual(recovery.action, .restoredPriorGeneration)
            XCTAssertEqual(recovery.status, prior)
            let ready = try lifecycle.inspect(prefix: prefix)
            XCTAssertEqual(ready.readiness, .ready)
            XCTAssertEqual(ready.status, prior)
            XCTAssertEqual(
                try runInstalled(prefix.appendingPathComponent("bin/hostwright"), arguments: ["--version"]),
                "0.0.1\n"
            )
            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
        }
    }

    func testInterruptedInitialStatusPublicationRemovesLifecycleFoundationOnRecovery() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "initial-status-window-artifact",
                version: "0.0.1",
                commit: baselineCommit
            )
            let prefix = root.appendingPathComponent("initial-status-window-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let interrupted = DistributionInstalledLifecycle(
                interruptAfter: nil,
                interruptAfterStatusWrite: true
            )

            XCTAssertThrowsError(try interrupted.install(artifact: artifact, prefix: prefix)) {
                XCTAssertEqual(
                    $0 as? DistributionLifecycleInterruption,
                    .afterStatusWriteBeforeJournal
                )
            }
            let lifecycle = DistributionInstalledLifecycle()
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .recoveryRequired)

            let recovery = try lifecycle.recover(prefix: prefix)
            XCTAssertEqual(recovery.action, .removedInterruptedInitialInstall)
            XCTAssertNil(recovery.status)
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .notInstalled)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), [])
        }
    }

    func testCompensationCanResumeAfterPartialPayloadRestore() throws {
        try withTemporaryRoot { root in
            let baseline = try makeVerifiedArtifact(
                root: root,
                name: "resumable-compensation-baseline",
                version: "0.0.1",
                commit: baselineCommit
            )
            let candidate = try makeVerifiedArtifact(
                root: root,
                name: "resumable-compensation-candidate",
                version: "0.0.2-dev",
                commit: candidateCommit
            )
            let prefix = root.appendingPathComponent("resumable-compensation-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let lifecycle = DistributionInstalledLifecycle()
            _ = try lifecycle.install(artifact: baseline, prefix: prefix)
            XCTAssertThrowsError(
                try DistributionInstalledLifecycle(interruptAfter: .payloadPublished)
                    .install(artifact: candidate, prefix: prefix)
            )

            XCTAssertThrowsError(
                try DistributionInstalledLifecycle(
                    interruptAfter: nil,
                    interruptAfterCompensationRestoreCount: 1
                ).recover(prefix: prefix)
            ) { error in
                XCTAssertEqual(
                    error as? DistributionLifecycleInterruption,
                    .afterCompensationFilesRestored(1)
                )
            }
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .recoveryRequired)

            let recovered = try lifecycle.recover(prefix: prefix)
            XCTAssertEqual(recovered.action, .restoredPriorGeneration)
            XCTAssertEqual(recovered.status?.installedManifest.packageVersion, "0.0.1")
            XCTAssertEqual(
                try runInstalled(prefix.appendingPathComponent("bin/hostwright"), arguments: ["--version"]),
                "0.0.1\n"
            )
            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
        }
    }

    func testCompensationPublishedRecoveryFinalizesAfterTransactionRemoval() throws {
        try withTemporaryRoot { root in
            let baseline = try makeVerifiedArtifact(
                root: root,
                name: "compensation-finalization-baseline",
                version: "0.0.1",
                commit: baselineCommit
            )
            let candidate = try makeVerifiedArtifact(
                root: root,
                name: "compensation-finalization-candidate",
                version: "0.0.2-dev",
                commit: candidateCommit
            )
            let prefix = root.appendingPathComponent("compensation-finalization-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let lifecycle = DistributionInstalledLifecycle()
            let installed = try lifecycle.install(artifact: baseline, prefix: prefix)
            XCTAssertThrowsError(
                try DistributionInstalledLifecycle(interruptAfter: .payloadPublished)
                    .install(artifact: candidate, prefix: prefix)
            )
            let interrupted = try lifecycle.inspect(prefix: prefix)
            let operationID = try XCTUnwrap(interrupted.pendingOperation?.operationID)

            XCTAssertThrowsError(
                try DistributionInstalledLifecycle(
                    interruptAfter: nil,
                    interruptAfterCompensationTransactionRemoved: true
                ).recover(prefix: prefix)
            ) { error in
                XCTAssertEqual(
                    error as? DistributionLifecycleInterruption,
                    .afterCompensationTransactionRemoved
                )
            }
            let compensationPublished = try lifecycle.inspect(prefix: prefix)
            XCTAssertEqual(compensationPublished.readiness, .recoveryRequired)
            XCTAssertEqual(compensationPublished.pendingOperation?.checkpoint, .compensationPublished)
            let transaction = prefix.appendingPathComponent(
                "\(DistributionLayout.lifecycleDirectoryName)/\(DistributionLayout.lifecycleTransactionsDirectoryName)/\(operationID)",
                isDirectory: true
            )
            XCTAssertFalse(DistributionFileSystem.entryExists(transaction))

            let recovered = try lifecycle.recover(prefix: prefix)
            XCTAssertEqual(recovered.action, .restoredPriorGeneration)
            XCTAssertEqual(recovered.status, installed)
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .ready)
            XCTAssertEqual(
                try runInstalled(prefix.appendingPathComponent("bin/hostwright"), arguments: ["--version"]),
                "0.0.1\n"
            )
            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
        }
    }

    func testCommittedRepairRecoveryCompletesAfterTransactionCleanupInterruption() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "repair-finalization-artifact",
                version: "0.0.1",
                commit: baselineCommit
            )
            let prefix = root.appendingPathComponent("repair-finalization-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let lifecycle = DistributionInstalledLifecycle()
            _ = try lifecycle.install(artifact: artifact, prefix: prefix)

            XCTAssertThrowsError(
                try DistributionInstalledLifecycle(
                    interruptAfter: nil,
                    interruptAfterPublishedTransactionCleanup: true
                ).install(artifact: artifact, prefix: prefix)
            ) { error in
                XCTAssertEqual(
                    error as? DistributionLifecycleInterruption,
                    .afterPublishedTransactionCleanup
                )
            }
            let pending = try lifecycle.inspect(prefix: prefix)
            XCTAssertEqual(pending.readiness, .recoveryRequired)
            XCTAssertEqual(pending.pendingOperation?.operation, .repair)
            XCTAssertEqual(pending.pendingOperation?.checkpoint, .statusPublished)
            XCTAssertEqual(pending.status?.generation, 2)

            let recovered = try lifecycle.recover(prefix: prefix)
            XCTAssertEqual(recovered.action, .completedPublishedGeneration)
            XCTAssertEqual(recovered.status?.generation, 2)
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .ready)
            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
        }
    }

    func testEveryUninstallRemovalCheckpointRestoresManagedPayloadAndState() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "uninstall-checkpoint-artifact",
                version: "0.0.1",
                commit: String(repeating: "1", count: 40)
            )
            let checkpoints: [DistributionLifecycleCheckpoint] = [
                .intentRecorded,
                .priorPayloadBackedUp,
                .stateBackedUp,
                .payloadPublishing,
                .payloadPublished,
                .stateMigrating,
                .stateMigrated,
                .statusPublished
            ]
            for (index, checkpoint) in checkpoints.enumerated() {
                let prefix = root.appendingPathComponent(
                    "uninstall-checkpoint-prefix-\(index)",
                    isDirectory: true
                )
                let stateDirectory = root.appendingPathComponent(
                    "uninstall-checkpoint-state-\(index)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
                try FileManager.default.createDirectory(
                    at: stateDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let state = SQLiteStateStore(path: stateDirectory.appendingPathComponent("state.sqlite").path)
                try MigrationRunner().apply(to: state)
                let lifecycle = DistributionInstalledLifecycle()
                let installed = try lifecycle.install(
                    artifact: artifact,
                    prefix: prefix,
                    stateDatabasePath: state.path
                )
                let plan = try lifecycle.uninstallPlan(prefix: prefix, dataPolicy: .remove)

                XCTAssertThrowsError(
                    try DistributionInstalledLifecycle(interruptAfter: checkpoint).uninstall(
                        prefix: prefix,
                        dataPolicy: .remove,
                        confirmationToken: plan.confirmationToken
                    ),
                    checkpoint.rawValue
                ) { error in
                    XCTAssertEqual(
                        error as? DistributionLifecycleInterruption,
                        .after(checkpoint),
                        checkpoint.rawValue
                    )
                }
                XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .recoveryRequired)
                let recovery = try lifecycle.recover(prefix: prefix)
                if checkpoint == .statusPublished {
                    XCTAssertEqual(recovery.action, .completedUninstall)
                    XCTAssertNil(recovery.status)
                    XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .notInstalled)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), [])
                } else {
                    XCTAssertEqual(recovery.action, .restoredPriorGeneration, checkpoint.rawValue)
                    XCTAssertEqual(recovery.status, installed, checkpoint.rawValue)
                    XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .ready)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: state.path), checkpoint.rawValue)
                    XCTAssertEqual(try state.schemaVersion(), MigrationRunner.latestSchemaVersion)
                    XCTAssertEqual(
                        try runInstalled(prefix.appendingPathComponent("bin/hostwright"), arguments: ["--version"]),
                        "0.0.1\n"
                    )
                    _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
                }
            }
        }
    }

    func testCommittedUninstallRecoversAfterRollbackTransactionsAreRemoved() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "uninstall-finalization-artifact",
                version: "0.0.1",
                commit: baselineCommit
            )
            let prefix = root.appendingPathComponent("uninstall-finalization-prefix", isDirectory: true)
            let stateDirectory = root.appendingPathComponent("uninstall-finalization-state", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let state = SQLiteStateStore(path: stateDirectory.appendingPathComponent("state.sqlite").path)
            try MigrationRunner().apply(to: state)
            let lifecycle = DistributionInstalledLifecycle()
            _ = try lifecycle.install(
                artifact: artifact,
                prefix: prefix,
                stateDatabasePath: state.path
            )
            let plan = try lifecycle.uninstallPlan(prefix: prefix, dataPolicy: .remove)

            XCTAssertThrowsError(
                try DistributionInstalledLifecycle(
                    interruptAfter: nil,
                    interruptAfterUninstallTransactionsRemoved: true
                ).uninstall(
                    prefix: prefix,
                    dataPolicy: .remove,
                    confirmationToken: plan.confirmationToken
                )
            ) { error in
                XCTAssertEqual(
                    error as? DistributionLifecycleInterruption,
                    .afterUninstallTransactionsRemoved
                )
            }
            let pending = try lifecycle.inspect(prefix: prefix)
            XCTAssertEqual(pending.readiness, .recoveryRequired)
            XCTAssertEqual(pending.pendingOperation?.checkpoint, .statusPublished)
            XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))

            let recovered = try lifecycle.recover(prefix: prefix)
            XCTAssertEqual(recovered.action, .completedUninstall)
            XCTAssertNil(recovered.status)
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .notInstalled)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), [])
        }
    }

    func testUninstallResultOmitsCreatedDirectoryPreservedForUnmanagedContent() throws {
        try withTemporaryRoot { root in
            let artifact = try makeVerifiedArtifact(
                root: root,
                name: "uninstall-result-artifact",
                version: "0.0.1",
                commit: baselineCommit
            )
            let prefix = root.appendingPathComponent("uninstall-result-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let lifecycle = DistributionInstalledLifecycle()
            _ = try lifecycle.install(artifact: artifact, prefix: prefix)
            let unmanaged = prefix.appendingPathComponent("bin/operator-tool")
            try Data("operator-owned\n".utf8).write(to: unmanaged, options: .withoutOverwriting)

            let result = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)

            XCTAssertFalse(result.removedPaths.contains("bin"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unmanaged.path))
            XCTAssertEqual(try String(contentsOf: unmanaged, encoding: .utf8), "operator-owned\n")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), ["bin"])
        }
    }

    func testExactExistingLaunchdServiceIsStoppedReplacedRestoredAndRecovered() throws {
        try withTemporaryRoot { root in
            let baseline = try makeVerifiedArtifact(
                root: root,
                name: "service-baseline",
                version: "0.0.1",
                commit: baselineCommit
            )
            let candidate = try makeVerifiedArtifact(
                root: root,
                name: "service-candidate",
                version: "0.0.2-dev",
                commit: candidateCommit
            )
            let prefix = root.appendingPathComponent("service-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let label = "dev.hostwright.lifecycle-tests.\(UUID().uuidString.lowercased())"
            let service = DistributionManagedLaunchdServiceConfiguration(
                domain: "gui/\(geteuid())",
                label: label,
                propertyListURL: root.appendingPathComponent("managed-service.plist")
            )
            let lifecycle = DistributionInstalledLifecycle(managedService: service)
            _ = try lifecycle.install(artifact: baseline, prefix: prefix)

            let config = root.appendingPathComponent("hostwright.yaml")
            try Data("services: {}\n".utf8).write(to: config, options: .withoutOverwriting)
            try writeManagedServicePropertyList(
                service,
                executable: prefix.appendingPathComponent("bin/hostwrightd"),
                config: config
            )
            try launchManagedService(service)
            defer { stopManagedServiceIfLoaded(service) }
            try waitForServiceVersion("0.0.1", config: config)

            let upgraded = try lifecycle.install(artifact: candidate, prefix: prefix)
            XCTAssertEqual(upgraded.service, .running)
            try waitForServiceVersion("0.0.2-dev", config: config)

            let rolledBack = try lifecycle.rollback(prefix: prefix)
            XCTAssertEqual(rolledBack.service, .running)
            try waitForServiceVersion("0.0.1", config: config)

            XCTAssertThrowsError(
                try DistributionInstalledLifecycle(
                    managedService: service,
                    interruptAfter: .serviceStopped
                ).install(artifact: candidate, prefix: prefix)
            ) { error in
                XCTAssertEqual(
                    error as? DistributionLifecycleInterruption,
                    .after(.serviceStopped)
                )
            }
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .recoveryRequired)
            XCTAssertEqual(try lifecycle.recover(prefix: prefix).action, .restoredPriorGeneration)
            try waitForServiceVersion("0.0.1", config: config)

            XCTAssertThrowsError(
                try DistributionInstalledLifecycle(
                    managedService: service,
                    interruptAfter: .serviceRestored
                ).install(artifact: candidate, prefix: prefix)
            ) { error in
                XCTAssertEqual(
                    error as? DistributionLifecycleInterruption,
                    .after(.serviceRestored)
                )
            }
            XCTAssertEqual(try lifecycle.inspect(prefix: prefix).readiness, .recoveryRequired)
            XCTAssertEqual(try lifecycle.recover(prefix: prefix).action, .restoredPriorGeneration)
            try waitForServiceVersion("0.0.1", config: config)

            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
            XCTAssertFalse(isManagedServiceLoaded(service))
            XCTAssertTrue(FileManager.default.fileExists(atPath: service.propertyListURL.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), [])
        }
    }

    func testManagedServiceSymlinkExecutableIsRejectedBeforeLifecycleMutation() throws {
        try withTemporaryRoot { root in
            let baseline = try makeVerifiedArtifact(
                root: root,
                name: "service-symlink-baseline",
                version: "0.0.1",
                commit: baselineCommit
            )
            let candidate = try makeVerifiedArtifact(
                root: root,
                name: "service-symlink-candidate",
                version: "0.0.2-dev",
                commit: candidateCommit
            )
            let prefix = root.appendingPathComponent("service-symlink-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let service = DistributionManagedLaunchdServiceConfiguration(
                domain: "gui/\(geteuid())",
                label: "dev.hostwright.lifecycle-tests.\(UUID().uuidString.lowercased())",
                propertyListURL: root.appendingPathComponent("managed-service-symlink.plist")
            )
            let lifecycle = DistributionInstalledLifecycle(managedService: service)
            let installed = try lifecycle.install(artifact: baseline, prefix: prefix)
            let executableLink = root.appendingPathComponent("hostwrightd-link")
            try FileManager.default.createSymbolicLink(
                at: executableLink,
                withDestinationURL: prefix.appendingPathComponent("bin/hostwrightd")
            )
            let config = root.appendingPathComponent("hostwright.yaml")
            try Data("services: {}\n".utf8).write(to: config, options: .withoutOverwriting)
            try writeManagedServicePropertyList(
                service,
                executable: executableLink,
                config: config
            )

            XCTAssertThrowsError(try lifecycle.install(artifact: candidate, prefix: prefix)) { error in
                guard case .lifecycleFailed(let message) = error as? DistributionError else {
                    return XCTFail("expected exact managed-service path refusal, got \(error)")
                }
                XCTAssertTrue(message.contains("exact managed daemon path"))
            }
            let inspection = try lifecycle.inspect(prefix: prefix)
            XCTAssertEqual(inspection.readiness, .ready)
            XCTAssertEqual(
                inspection.status?.installedManifest.sourceCommit,
                installed.installedManifest.sourceCommit
            )
            XCTAssertEqual(inspection.status?.installedManifest.packageVersion, "0.0.1")
        }
    }

    func testCancellationAtInstallUpgradeRepairAndUninstallCheckpointsRecoversExactly() throws {
        try withTemporaryRoot { root in
            let baseline = try makeVerifiedArtifact(
                root: root,
                name: "cancellation-baseline",
                version: "0.0.1",
                commit: baselineCommit
            )
            let candidate = try makeVerifiedArtifact(
                root: root,
                name: "cancellation-candidate",
                version: "0.0.2-dev",
                commit: candidateCommit
            )
            let lifecycle = DistributionInstalledLifecycle()
            let transitionCheckpoints: [DistributionLifecycleCheckpoint] = [
                .intentRecorded,
                .payloadStaged,
                .priorPayloadBackedUp,
                .stateBackedUp,
                .payloadPublishing,
                .payloadPublished,
                .stateMigrating,
                .stateMigrated,
                .verifying,
                .statusPublished
            ]

            for checkpoint in transitionCheckpoints where checkpoint != .priorPayloadBackedUp
                && checkpoint != .stateBackedUp {
                let prefix = root.appendingPathComponent(
                    "cancel-install-\(checkpoint.rawValue)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
                let cancellation = SecureSubprocessCancellation()
                XCTAssertThrowsError(
                    try DistributionInstalledLifecycle(cancelAfter: checkpoint).install(
                        artifact: baseline,
                        prefix: prefix,
                        cancellation: cancellation
                    )
                ) { self.assertCommandCancelled($0, checkpoint: checkpoint) }
                if try lifecycle.inspect(prefix: prefix).readiness == .recoveryRequired {
                    _ = try lifecycle.recover(prefix: prefix)
                }
                if try lifecycle.inspect(prefix: prefix).readiness == .ready {
                    _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), [])
            }

            for checkpoint in transitionCheckpoints {
                let prefix = root.appendingPathComponent(
                    "cancel-upgrade-\(checkpoint.rawValue)",
                    isDirectory: true
                )
                let stateDirectory = root.appendingPathComponent(
                    "cancel-upgrade-state-\(checkpoint.rawValue)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
                try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: false)
                let state = SQLiteStateStore(path: stateDirectory.appendingPathComponent("state.sqlite").path)
                try MigrationRunner().apply(to: state, throughVersion: 6)
                _ = try lifecycle.install(
                    artifact: baseline,
                    prefix: prefix,
                    stateDatabasePath: state.path
                )
                let cancellation = SecureSubprocessCancellation()
                XCTAssertThrowsError(
                    try DistributionInstalledLifecycle(cancelAfter: checkpoint).install(
                        artifact: candidate,
                        prefix: prefix,
                        stateDatabasePath: state.path,
                        cancellation: cancellation
                    )
                ) { self.assertCommandCancelled($0, checkpoint: checkpoint) }
                if try lifecycle.inspect(prefix: prefix).readiness == .recoveryRequired {
                    _ = try lifecycle.recover(prefix: prefix)
                }
                let status = try XCTUnwrap(lifecycle.inspect(prefix: prefix).status)
                XCTAssertEqual(
                    status.installedManifest.packageVersion,
                    checkpoint == .statusPublished ? "0.0.2-dev" : "0.0.1"
                )
                _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), [])
            }

            for checkpoint in transitionCheckpoints {
                let prefix = root.appendingPathComponent(
                    "cancel-repair-\(checkpoint.rawValue)",
                    isDirectory: true
                )
                let stateDirectory = root.appendingPathComponent(
                    "cancel-repair-state-\(checkpoint.rawValue)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
                try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: false)
                let state = SQLiteStateStore(path: stateDirectory.appendingPathComponent("state.sqlite").path)
                try MigrationRunner().apply(to: state)
                _ = try lifecycle.install(
                    artifact: baseline,
                    prefix: prefix,
                    stateDatabasePath: state.path
                )
                let cancellation = SecureSubprocessCancellation()
                XCTAssertThrowsError(
                    try DistributionInstalledLifecycle(cancelAfter: checkpoint).install(
                        artifact: baseline,
                        prefix: prefix,
                        stateDatabasePath: state.path,
                        cancellation: cancellation
                    )
                ) { self.assertCommandCancelled($0, checkpoint: checkpoint) }
                if try lifecycle.inspect(prefix: prefix).readiness == .recoveryRequired {
                    _ = try lifecycle.recover(prefix: prefix)
                }
                let status = try XCTUnwrap(lifecycle.inspect(prefix: prefix).status)
                XCTAssertEqual(status.generation, checkpoint == .statusPublished ? 2 : 1)
                _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), [])
            }

            let uninstallCheckpoints: [DistributionLifecycleCheckpoint] = [
                .intentRecorded,
                .priorPayloadBackedUp,
                .stateBackedUp,
                .payloadPublishing,
                .payloadPublished,
                .stateMigrating,
                .stateMigrated,
                .statusPublished
            ]
            for checkpoint in uninstallCheckpoints {
                let prefix = root.appendingPathComponent(
                    "cancel-uninstall-\(checkpoint.rawValue)",
                    isDirectory: true
                )
                let stateDirectory = root.appendingPathComponent(
                    "cancel-uninstall-state-\(checkpoint.rawValue)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
                try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: false)
                let state = SQLiteStateStore(path: stateDirectory.appendingPathComponent("state.sqlite").path)
                try MigrationRunner().apply(to: state)
                _ = try lifecycle.install(
                    artifact: baseline,
                    prefix: prefix,
                    stateDatabasePath: state.path
                )
                let plan = try lifecycle.uninstallPlan(prefix: prefix, dataPolicy: .remove)
                let cancellation = SecureSubprocessCancellation()
                XCTAssertThrowsError(
                    try DistributionInstalledLifecycle(cancelAfter: checkpoint).uninstall(
                        prefix: prefix,
                        dataPolicy: .remove,
                        confirmationToken: plan.confirmationToken,
                        cancellation: cancellation
                    )
                ) { self.assertCommandCancelled($0, checkpoint: checkpoint) }
                if try lifecycle.inspect(prefix: prefix).readiness == .recoveryRequired {
                    _ = try lifecycle.recover(prefix: prefix)
                }
                if try lifecycle.inspect(prefix: prefix).readiness == .ready {
                    _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prefix.path), [])
            }
        }
    }

    private func assertCommandCancelled(
        _ error: Error,
        checkpoint: DistributionLifecycleCheckpoint
    ) {
        guard let distributionError = error as? DistributionError,
              case let .commandCancelled(operation) = distributionError else {
            return XCTFail("expected cancellation at \(checkpoint.rawValue), received \(error)")
        }
        XCTAssertTrue(operation.contains(checkpoint.rawValue))
    }

    private func writeManagedServicePropertyList(
        _ service: DistributionManagedLaunchdServiceConfiguration,
        executable: URL,
        config: URL
    ) throws {
        let object: [String: Any] = [
            "Label": service.label,
            "ProgramArguments": [
                executable.path,
                "--foreground",
                "--config",
                config.path
            ],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Background"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
        try data.write(to: service.propertyListURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: service.propertyListURL.path
        )
    }

    private func launchManagedService(
        _ service: DistributionManagedLaunchdServiceConfiguration
    ) throws {
        let runner = DistributionProcessRunner()
        _ = try runner.run(
            executablePath: "/bin/launchctl",
            arguments: ["bootstrap", service.domain, service.propertyListURL.path],
            label: "bootstrap lifecycle test service",
            timeoutSeconds: 30
        )
        _ = try runner.run(
            executablePath: "/bin/launchctl",
            arguments: ["kickstart", "-k", "\(service.domain)/\(service.label)"],
            label: "start lifecycle test service",
            timeoutSeconds: 30
        )
    }

    private func stopManagedServiceIfLoaded(
        _ service: DistributionManagedLaunchdServiceConfiguration
    ) {
        _ = try? DistributionProcessRunner().run(
            executablePath: "/bin/launchctl",
            arguments: ["bootout", "\(service.domain)/\(service.label)"],
            label: "stop lifecycle test service",
            timeoutSeconds: 30
        )
    }

    private func isManagedServiceLoaded(
        _ service: DistributionManagedLaunchdServiceConfiguration
    ) -> Bool {
        (try? DistributionProcessRunner().run(
            executablePath: "/bin/launchctl",
            arguments: ["print", "\(service.domain)/\(service.label)"],
            label: "inspect lifecycle test service",
            timeoutSeconds: 10
        )) != nil
    }

    private func waitForServiceVersion(_ version: String, config: URL) throws {
        let marker = URL(fileURLWithPath: config.path + ".running-version")
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let value = try? String(contentsOf: marker, encoding: .utf8),
               value == "\(version)\n" {
                return
            }
            usleep(50_000)
        }
        XCTFail("managed service did not start expected version \(version)")
    }

    private func makeVerifiedArtifact(
        root: URL,
        name: String,
        version: String,
        commit: String
    ) throws -> VerifiedDistributionArtifact {
        let fixture = root.appendingPathComponent("fixture-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        let source = fixture.appendingPathComponent("main.swift")
        let binary = fixture.appendingPathComponent("hostwright-fixture")
        let program = """
        import Foundation
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--version") {
            print("\(version)")
        } else if arguments.contains("--help") {
            print("Usage: hostwrightd fixture")
            print("does not perform unattended runtime mutation")
        } else if arguments.count == 3,
                  arguments[0] == "--foreground",
                  arguments[1] == "--config" {
            try Data("\(version)\\n".utf8).write(
                to: URL(fileURLWithPath: arguments[2] + ".running-version"),
                options: .atomic
            )
            while true {
                Thread.sleep(forTimeInterval: 0.1)
            }
        } else {
            print("fixture")
        }
        """ + "\n"
        try Data(program.utf8).write(to: source, options: .withoutOverwriting)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", source.path, "-o", binary.path]
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0)

        let repository = repositoryRoot()
        let output = root.appendingPathComponent(name, isDirectory: true)
        _ = try DistributionAssembler().assemble(
            DistributionAssemblyRequest(
                hostwrightBinary: binary,
                hostwrightControlBinary: binary,
                hostwrightDistributionBinary: binary,
                hostwrightDaemonBinary: binary,
                exampleManifestFile: repository.appendingPathComponent("examples/single-service/hostwright.yaml"),
                licenseFile: repository.appendingPathComponent("LICENSE"),
                readmeFile: repository.appendingPathComponent("README.md"),
                outputDirectory: output,
                packageVersion: version,
                sourceCommit: commit,
                sourceDirty: true,
                architecture: "arm64",
                inputStageIdentifier: "prebuilt-validation",
                inputStageDetail: "Compiled a real ARM64 lifecycle fixture for upgrade qualification."
            )
        )
        return try DistributionVerifier().verify(
            distributionDirectory: output,
            extractionDirectory: root.appendingPathComponent(
                "hostwright-dist-\(name)-lifecycle-extract",
                isDirectory: true
            )
        )
    }

    private func makePackageStaging(
        artifact: VerifiedDistributionArtifact,
        at staging: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for file in artifact.manifest.files {
            try DistributionFileSystem.copyRegularFile(
                from: artifact.extractedRoot.appendingPathComponent(file.path),
                to: staging.appendingPathComponent(file.path),
                mode: file.mode
            )
        }
        try DistributionFileSystem.writeNewFile(
            try DistributionJSON.encode(artifact.manifest),
            to: staging.appendingPathComponent(DistributionLayout.manifestFileName),
            mode: 0o644
        )
    }

    private func installLegacyPayload(
        artifact: VerifiedDistributionArtifact,
        prefix: URL
    ) throws {
        let legacyFiles = artifact.manifest.files.filter {
            DistributionLayout.legacyPayloadModesV1[$0.path] != nil
        }
        for file in legacyFiles {
            try DistributionFileSystem.copyRegularFile(
                from: artifact.extractedRoot.appendingPathComponent(file.path),
                to: prefix.appendingPathComponent(file.path),
                mode: file.mode
            )
        }
        let manifest = DistributionInstallManifest(
            schemaVersion: 1,
            artifactID: artifact.manifest.artifactID,
            sourceCommit: artifact.manifest.sourceCommit,
            packageVersion: artifact.manifest.packageVersion,
            files: legacyFiles,
            createdDirectories: []
        )
        try manifest.validate()
        let data = try DistributionJSON.encode(manifest)
        try DistributionFileSystem.writeNewFile(
            data,
            to: prefix.appendingPathComponent(DistributionLayout.installManifestFileName),
            mode: 0o644
        )
    }

    private func runInstalled(_ executable: URL, arguments: [String]) throws -> String {
        let result = try DistributionProcessRunner().run(
            executablePath: executable.path,
            arguments: arguments,
            label: "run installed lifecycle fixture",
            timeoutSeconds: 30
        )
        return result.standardOutput
    }

    private func fileDigest(_ url: URL) throws -> String {
        try DistributionHash.sha256(fileURL: url)
    }

    private func eventIDs(_ path: String) throws -> [String] {
        let connection = try SQLiteConnection(path: path, createIfNeeded: false, readOnly: true)
        defer { try? connection.close() }
        let values = try connection.query("SELECT id FROM event_ledger ORDER BY id")
            .compactMap { $0.first ?? nil }
        try connection.close()
        return values
    }

    private func regularFileContents(in directory: URL) throws -> [String: Data] {
        var contents: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
            let file = directory.appendingPathComponent(name)
            if try DistributionFileSystem.isRegularNonSymlink(file) {
                contents[name] = try Data(contentsOf: file)
            }
        }
        return contents
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func withTemporaryRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-dist-durable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
