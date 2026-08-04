import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightCore
import HostwrightExtensions
import HostwrightState
import XCTest

final class PluginImmutableStoreTests: XCTestCase {
    private let createdAt = "2026-08-04T12:00:00Z"
    private let updatedAt = "2026-08-04T12:01:00Z"

    func testInstallPersistsDigestAddressedStagedPackageSucceededRollbackAndLedgerAcrossReopen() throws {
        let environment = try makeEnvironment()
        let fixture = try makeVerifiedPackageFixture()
        let request = PluginInstallRequest(
            operationID: "install-alpha",
            idempotencyKey: "install-alpha-key",
            actorSubjectID: "owner",
            timestamp: createdAt
        )

        let stored = try environment.immutableStore.install(
            verified: fixture.verified,
            request: request,
            repository: environment.store.plugins
        )

        let packageURL = environment.immutableStore.packageURL(digest: stored.packageDigest)
        XCTAssertEqual(stored.lifecycleState, .staged)
        XCTAssertEqual(stored.storagePath, packageURL.path)
        XCTAssertEqual(try environment.store.plugins.package(digest: stored.packageDigest), stored)

        let rollback = try XCTUnwrap(environment.store.plugins.rollback(operationID: request.operationID))
        XCTAssertEqual(rollback.stage, "complete")
        XCTAssertEqual(rollback.status, "succeeded")
        XCTAssertEqual(rollback.toPackageDigest, stored.packageDigest)
        XCTAssertEqual(rollback.ownershipEffects, stored.ownershipLedger)

        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.storageRoot.appendingPathComponent("staging/install-alpha").path
            )
        )

        let paths = Set(stored.ownershipLedger.map(\.path))
        XCTAssertEqual(
            paths,
            [
                packageURL.path,
                packageURL.appendingPathComponent("Resources", isDirectory: true).path,
                packageURL.appendingPathComponent(PluginPackageVerifier.manifestFileName).path,
                packageURL.appendingPathComponent("Resources/config.json").path,
                packageURL.appendingPathComponent("plugin.wasm").path,
            ]
        )
        for artifact in stored.ownershipLedger {
            let metadata = try lstatMetadata(artifact.path)
            XCTAssertEqual(metadata.st_uid, geteuid())
            if artifact.kind == .directory {
                XCTAssertEqual(metadata.st_mode & mode_t(0o777), mode_t(0o700))
                XCTAssertNil(artifact.sha256Digest)
            } else {
                XCTAssertEqual(metadata.st_mode & mode_t(0o777), mode_t(0o400))
                XCTAssertNotNil(artifact.sha256Digest)
            }
        }

        let reopened = SQLiteStateStore(path: environment.store.path)
        XCTAssertEqual(try reopened.plugins.package(digest: stored.packageDigest), stored)
        XCTAssertEqual(try reopened.plugins.rollback(operationID: request.operationID), rollback)
    }

    func testUninstallCleanupRemovesExactOwnedTreeAfterRepositoryTransition() throws {
        let environment = try makeEnvironment()
        let fixture = try makeVerifiedPackageFixture()
        let request = PluginInstallRequest(
            operationID: "install-beta",
            idempotencyKey: "install-beta-key",
            actorSubjectID: "owner",
            timestamp: createdAt
        )

        let stored = try environment.immutableStore.install(
            verified: fixture.verified,
            request: request,
            repository: environment.store.plugins
        )
        let uninstalled = try environment.store.plugins.transitionPackage(
            digest: stored.packageDigest,
            to: .uninstalled,
            expectedGeneration: stored.generation,
            actorSubjectID: "owner",
            updatedAt: updatedAt
        )

        try environment.immutableStore.removeInstalledPackage(uninstalled)

        XCTAssertFalse(FileManager.default.fileExists(atPath: uninstalled.storagePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.storageRoot.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.storageRoot.appendingPathComponent("packages", isDirectory: true).path
            )
        )
    }

    func testInstallFailureCleansStageAndPersistsFailedRollbackAcrossReopen() throws {
        let environment = try makeEnvironment()
        let fixture = try makeVerifiedPackageFixture()
        let request = PluginInstallRequest(
            operationID: "install-gamma",
            idempotencyKey: "install-gamma-key",
            actorSubjectID: "owner",
            timestamp: createdAt
        )
        let manifestURL = fixture.sourceRoot.appendingPathComponent(PluginPackageVerifier.manifestFileName)
        try Data("tampered".utf8).write(to: manifestURL)

        XCTAssertThrowsError(
            try environment.immutableStore.install(
                verified: fixture.verified,
                request: request,
                repository: environment.store.plugins
            )
        ) { error in
            guard let diagnostic = error as? HostwrightDiagnostic else {
                return XCTFail("Expected HostwrightDiagnostic, got \(error)")
            }
            XCTAssertEqual(diagnostic.code, .extensionBlocked)
            XCTAssertTrue(diagnostic.message.contains("manifest changed after verification"))
        }

        let packageURL = environment.immutableStore.packageURL(digest: fixture.verified.packageDigest)
        let stageURL = environment.storageRoot.appendingPathComponent("staging/install-gamma", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stageURL.path))
        XCTAssertNil(try environment.store.plugins.package(digest: fixture.verified.packageDigest))

        let rollback = try XCTUnwrap(environment.store.plugins.rollback(operationID: request.operationID))
        XCTAssertEqual(rollback.stage, "install-intent")
        XCTAssertEqual(rollback.status, "failed")
        XCTAssertEqual(rollback.failureReasonCode, "plugin.install-failed")
        XCTAssertEqual(rollback.ownershipEffects, [])

        let reopened = SQLiteStateStore(path: environment.store.path)
        XCTAssertEqual(try reopened.plugins.rollback(operationID: request.operationID), rollback)
    }

    func testContentChangeAfterVerificationCleansPartiallyCopiedStage() throws {
        let environment = try makeEnvironment()
        let fixture = try makeVerifiedPackageFixture()
        let request = PluginInstallRequest(
            operationID: "install-partial",
            idempotencyKey: "install-partial-key",
            actorSubjectID: "owner",
            timestamp: createdAt
        )
        try Data("changed-after-verification".utf8).write(
            to: fixture.sourceRoot.appendingPathComponent("plugin.wasm"))

        XCTAssertThrowsError(try environment.immutableStore.install(
            verified: fixture.verified, request: request,
            repository: environment.store.plugins)) { error in
            XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .extensionBlocked)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: environment.storageRoot.appendingPathComponent("staging/install-partial").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: environment.immutableStore.packageURL(
                digest: fixture.verified.packageDigest).path))
        let rollback = try XCTUnwrap(
            environment.store.plugins.rollback(operationID: request.operationID))
        XCTAssertEqual(rollback.status, "failed")
    }

    func testRestartRecoveryCleansPinnedStagingWithoutFollowingEscapingSymlink() throws {
        let environment = try makeEnvironment()
        let fixture = try makeVerifiedPackageFixture()
        let operationID = "recover-staging-symlink"
        _ = try environment.store.plugins.beginRollback(PluginRollbackRecord(
            operationID: operationID,
            pluginIdentifier: fixture.verified.manifest.identifier,
            fromPackageDigest: nil,
            toPackageDigest: fixture.verified.packageDigest,
            stage: "install-intent",
            status: "pending",
            idempotencyKey: operationID + "-key",
            ownershipEffects: [],
            failureReasonCode: nil,
            requestedBySubjectID: "owner",
            generation: 1,
            createdAt: createdAt,
            updatedAt: createdAt
        ))

        let stageURL = environment.storageRoot
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(operationID, isDirectory: true)
        XCTAssertEqual(mkdir(stageURL.path, 0o700), 0)
        let safeDirectory = stageURL.appendingPathComponent("safe", isDirectory: true)
        XCTAssertEqual(mkdir(safeDirectory.path, 0o700), 0)
        let safeFile = safeDirectory.appendingPathComponent("copied-plugin.wasm")
        try Data("safe-staged-content".utf8).write(to: safeFile)
        XCTAssertEqual(chmod(safeFile.path, 0o400), 0)

        let outsideFile = environment.root.appendingPathComponent("outside-secret")
        let outsideContent = Data("must-survive-staging-cleanup".utf8)
        try outsideContent.write(to: outsideFile)
        XCTAssertEqual(chmod(outsideFile.path, 0o600), 0)
        let escapingLink = stageURL.appendingPathComponent("outside-link")
        XCTAssertEqual(symlink(outsideFile.path, escapingLink.path), 0)

        XCTAssertEqual(
            try environment.immutableStore.recoverInterruptedOperations(
                repository: environment.store.plugins,
                timestamp: updatedAt
            ),
            1
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stageURL.path))
        XCTAssertEqual(try Data(contentsOf: outsideFile), outsideContent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
        let operation = try XCTUnwrap(environment.store.plugins.rollback(operationID: operationID))
        XCTAssertEqual(operation.stage, "recovery-failure-audit")
        XCTAssertEqual(operation.status, "running")
    }

    func testInstallRefusesPreexistingDigestStorageAndLeavesFailedRollback() throws {
        let environment = try makeEnvironment()
        let fixture = try makeVerifiedPackageFixture()
        let request = PluginInstallRequest(
            operationID: "install-delta",
            idempotencyKey: "install-delta-key",
            actorSubjectID: "owner",
            timestamp: createdAt
        )
        let finalURL = environment.immutableStore.packageURL(digest: fixture.verified.packageDigest)
        try FileManager.default.createDirectory(
            at: finalURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        XCTAssertThrowsError(
            try environment.immutableStore.install(
                verified: fixture.verified,
                request: request,
                repository: environment.store.plugins
            )
        ) { error in
            guard let diagnostic = error as? HostwrightDiagnostic else {
                return XCTFail("Expected HostwrightDiagnostic, got \(error)")
            }
            XCTAssertEqual(diagnostic.code, .extensionBlocked)
            XCTAssertTrue(diagnostic.message.contains("already exists"))
        }

        XCTAssertNil(try environment.store.plugins.package(digest: fixture.verified.packageDigest))
        let rollback = try XCTUnwrap(environment.store.plugins.rollback(operationID: request.operationID))
        XCTAssertEqual(rollback.status, "failed")
        XCTAssertEqual(rollback.stage, "install-intent")
    }

    func testCleanupRefusesChangedIdentityOrContent() throws {
        let environment = try makeEnvironment()
        let fixture = try makeVerifiedPackageFixture()
        let request = PluginInstallRequest(
            operationID: "install-epsilon",
            idempotencyKey: "install-epsilon-key",
            actorSubjectID: "owner",
            timestamp: createdAt
        )

        let stored = try environment.immutableStore.install(
            verified: fixture.verified,
            request: request,
            repository: environment.store.plugins
        )
        let uninstalled = try environment.store.plugins.transitionPackage(
            digest: stored.packageDigest,
            to: .uninstalled,
            expectedGeneration: stored.generation,
            actorSubjectID: "owner",
            updatedAt: updatedAt
        )

        let entrypoint = URL(fileURLWithPath: uninstalled.storagePath, isDirectory: true)
            .appendingPathComponent("plugin.wasm")
        XCTAssertEqual(unlink(entrypoint.path), 0)
        try Data("valid-wasm-module".utf8).write(to: entrypoint)
        XCTAssertEqual(chmod(entrypoint.path, 0o400), 0)

        XCTAssertThrowsError(try environment.immutableStore.removeInstalledPackage(uninstalled)) { error in
            guard let diagnostic = error as? HostwrightDiagnostic else {
                return XCTFail("Expected HostwrightDiagnostic, got \(error)")
            }
            XCTAssertEqual(diagnostic.code, .extensionBlocked)
            XCTAssertTrue(diagnostic.message.contains("identity changed"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: uninstalled.storagePath))
    }

    func testCleanupRefusesUnownedDeletionAndChangedContent() throws {
        let environment = try makeEnvironment()
        let fixture = try makeVerifiedPackageFixture()
        let request = PluginInstallRequest(
            operationID: "install-zeta",
            idempotencyKey: "install-zeta-key",
            actorSubjectID: "owner",
            timestamp: createdAt
        )

        let stored = try environment.immutableStore.install(
            verified: fixture.verified,
            request: request,
            repository: environment.store.plugins
        )
        let uninstalled = try environment.store.plugins.transitionPackage(
            digest: stored.packageDigest,
            to: .uninstalled,
            expectedGeneration: stored.generation,
            actorSubjectID: "owner",
            updatedAt: updatedAt
        )

        let rogue = URL(fileURLWithPath: uninstalled.storagePath, isDirectory: true)
            .appendingPathComponent("rogue.txt")
        try Data("rogue".utf8).write(to: rogue)
        XCTAssertEqual(chmod(rogue.path, 0o400), 0)

        XCTAssertThrowsError(try environment.immutableStore.removeInstalledPackage(uninstalled)) { error in
            guard let diagnostic = error as? HostwrightDiagnostic else {
                return XCTFail("Expected HostwrightDiagnostic, got \(error)")
            }
            XCTAssertEqual(diagnostic.code, .extensionBlocked)
            XCTAssertTrue(diagnostic.message.contains("unowned package artifacts"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rogue.path))

        try FileManager.default.removeItem(at: rogue)
        let config = URL(fileURLWithPath: uninstalled.storagePath, isDirectory: true)
            .appendingPathComponent("Resources/config.json")
        XCTAssertEqual(chmod(config.path, 0o600), 0)
        try Data(#"{"mode":"tampered"}"#.utf8).write(to: config)
        XCTAssertEqual(chmod(config.path, 0o400), 0)

        XCTAssertThrowsError(try environment.immutableStore.removeInstalledPackage(uninstalled)) { error in
            guard let diagnostic = error as? HostwrightDiagnostic else {
                return XCTFail("Expected HostwrightDiagnostic, got \(error)")
            }
            XCTAssertEqual(diagnostic.code, .extensionBlocked)
            XCTAssertTrue(diagnostic.message.contains("content changed"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
    }

    func testRestartRecoveryAfterInstallRenameWithoutPackageCleansOwnedTreeAndFailsTerminal() throws {
        let environment = try makeEnvironment()
        let fixture = try makeVerifiedPackageFixture()
        let finalURL = environment.immutableStore.packageURL(digest: fixture.verified.packageDigest)
        let ledger = try publishVerifiedPackage(fixture.verified, to: finalURL)
        let operation = try beginInterruptedInstall(
            operationID: "recover-install-renamed",
            package: fixture.verified,
            ownershipLedger: ledger,
            repository: environment.store.plugins
        )

        let reopenedStore = SQLiteStateStore(path: environment.store.path)
        let restarted = try PluginImmutableStore(rootURL: environment.storageRoot)
        XCTAssertEqual(
            try restarted.recoverInterruptedOperations(
                repository: reopenedStore.plugins,
                timestamp: updatedAt
            ),
            1
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertNil(try reopenedStore.plugins.package(digest: fixture.verified.packageDigest))
        let awaitingAudit = try XCTUnwrap(
            reopenedStore.plugins.rollback(operationID: operation.operationID)
        )
        XCTAssertEqual(awaitingAudit.stage, "recovery-failure-audit")
        XCTAssertEqual(awaitingAudit.status, "running")
        XCTAssertNil(awaitingAudit.failureReasonCode)
        XCTAssertEqual(awaitingAudit.ownershipEffects, ledger)
        XCTAssertEqual(
            try reopenedStore.plugins.incompleteRollbackOperations(),
            [awaitingAudit]
        )
        let terminal = try restarted.finalizeRecoveredOperation(
            operationID: operation.operationID,
            repository: reopenedStore.plugins,
            timestamp: updatedAt
        )
        XCTAssertEqual(terminal.stage, "recovery-failure-audit")
        XCTAssertEqual(terminal.status, "failed")
        XCTAssertEqual(terminal.failureReasonCode, "plugin.lifecycle-interrupted")
        XCTAssertEqual(terminal.ownershipEffects, ledger)
        XCTAssertTrue(try reopenedStore.plugins.incompleteRollbackOperations().isEmpty)
    }

    func testRestartRecoveryAfterPackagePersistenceValidatesOwnedTreeAndSucceedsTerminal() throws {
        let environment = try makeEnvironment()
        let fixture = try makeVerifiedPackageFixture()
        let finalURL = environment.immutableStore.packageURL(digest: fixture.verified.packageDigest)
        let ledger = try publishVerifiedPackage(fixture.verified, to: finalURL)
        let operation = try beginInterruptedInstall(
            operationID: "recover-install-persisted",
            package: fixture.verified,
            ownershipLedger: ledger,
            repository: environment.store.plugins
        )
        let package = try PluginPackageRecord(
            packageDigest: fixture.verified.packageDigest,
            manifest: fixture.verified.manifest,
            storagePath: finalURL.path,
            ownershipLedger: ledger,
            lifecycleState: .staged,
            createdBySubjectID: "owner",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        XCTAssertEqual(try environment.store.plugins.persistVerifiedPackage(package), package)

        let reopenedStore = SQLiteStateStore(path: environment.store.path)
        let restarted = try PluginImmutableStore(rootURL: environment.storageRoot)
        XCTAssertEqual(
            try restarted.recoverInterruptedOperations(
                repository: reopenedStore.plugins,
                timestamp: updatedAt
            ),
            1
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertEqual(try reopenedStore.plugins.package(digest: package.packageDigest), package)
        let awaitingAudit = try XCTUnwrap(
            reopenedStore.plugins.rollback(operationID: operation.operationID)
        )
        XCTAssertEqual(awaitingAudit.stage, "recovery-success-audit")
        XCTAssertEqual(awaitingAudit.status, "running")
        XCTAssertNil(awaitingAudit.failureReasonCode)
        XCTAssertEqual(awaitingAudit.ownershipEffects, ledger)
        XCTAssertEqual(
            try reopenedStore.plugins.incompleteRollbackOperations(),
            [awaitingAudit]
        )
        let terminal = try restarted.finalizeRecoveredOperation(
            operationID: operation.operationID,
            repository: reopenedStore.plugins,
            timestamp: updatedAt
        )
        XCTAssertEqual(terminal.stage, "complete")
        XCTAssertEqual(terminal.status, "succeeded")
        XCTAssertNil(terminal.failureReasonCode)
        XCTAssertEqual(terminal.ownershipEffects, ledger)
        XCTAssertTrue(try reopenedStore.plugins.incompleteRollbackOperations().isEmpty)
    }

    func testRestartRecoveryWhenRollbackActivationAlreadySwitchedSucceedsTerminal() throws {
        let environment = try makeEnvironment()
        let priorFixture = try makeVerifiedPackageFixture(
            packageVersion: "1.0.0",
            moduleData: Data("prior-wasm-module".utf8)
        )
        let prior = try environment.immutableStore.install(
            verified: priorFixture.verified,
            request: PluginInstallRequest(
                operationID: "install-prior-before-rollback-recovery",
                idempotencyKey: "install-prior-before-rollback-recovery-key",
                actorSubjectID: "owner",
                timestamp: createdAt
            ),
            repository: environment.store.plugins
        )
        let firstActivation = try environment.store.plugins.activate(
            digest: prior.packageDigest,
            expectedActivationGeneration: nil,
            actorSubjectID: "owner",
            timestamp: updatedAt
        )
        let currentFixture = try makeVerifiedPackageFixture(
            packageVersion: "2.0.0",
            moduleData: Data("current-wasm-module".utf8)
        )
        let current = try environment.immutableStore.install(
            verified: currentFixture.verified,
            request: PluginInstallRequest(
                operationID: "install-current-before-rollback-recovery",
                idempotencyKey: "install-current-before-rollback-recovery-key",
                actorSubjectID: "owner",
                timestamp: createdAt
            ),
            repository: environment.store.plugins
        )
        let secondActivation = try environment.store.plugins.activate(
            digest: current.packageDigest,
            expectedActivationGeneration: firstActivation.generation,
            actorSubjectID: "owner",
            timestamp: updatedAt
        )
        _ = try environment.store.plugins.activate(
            digest: prior.packageDigest,
            expectedActivationGeneration: secondActivation.generation,
            actorSubjectID: "owner",
            timestamp: updatedAt
        )
        let pending = try environment.store.plugins.beginRollback(PluginRollbackRecord(
            operationID: "recover-rollback-activated",
            pluginIdentifier: prior.manifest.identifier,
            fromPackageDigest: current.packageDigest,
            toPackageDigest: prior.packageDigest,
            stage: "rollback-intent",
            status: "pending",
            idempotencyKey: "recover-rollback-activated-key",
            ownershipEffects: [],
            failureReasonCode: nil,
            requestedBySubjectID: "owner",
            generation: 1,
            createdAt: createdAt,
            updatedAt: createdAt
        ))
        let operation = try environment.store.plugins.advanceRollback(
            operationID: pending.operationID,
            expectedGeneration: pending.generation,
            stage: "activation",
            status: "running",
            updatedAt: updatedAt
        )

        let reopenedStore = SQLiteStateStore(path: environment.store.path)
        let restarted = try PluginImmutableStore(rootURL: environment.storageRoot)
        XCTAssertEqual(
            try restarted.recoverInterruptedOperations(
                repository: reopenedStore.plugins,
                timestamp: updatedAt
            ),
            1
        )

        XCTAssertEqual(
            try reopenedStore.plugins.activation(identifier: prior.manifest.identifier)?
                .activePackageDigest,
            prior.packageDigest
        )
        let awaitingAudit = try XCTUnwrap(
            reopenedStore.plugins.rollback(operationID: operation.operationID)
        )
        XCTAssertEqual(awaitingAudit.stage, "recovery-success-audit")
        XCTAssertEqual(awaitingAudit.status, "running")
        XCTAssertEqual(
            try reopenedStore.plugins.incompleteRollbackOperations(),
            [awaitingAudit]
        )
        let terminal = try restarted.finalizeRecoveredOperation(
            operationID: operation.operationID,
            repository: reopenedStore.plugins,
            timestamp: updatedAt
        )
        XCTAssertEqual(terminal.stage, "complete")
        XCTAssertEqual(terminal.status, "succeeded")
        XCTAssertNil(terminal.failureReasonCode)
        XCTAssertTrue(try reopenedStore.plugins.incompleteRollbackOperations().isEmpty)
    }

    func testRestartRecoveryAfterUninstallStateMutationCleansOwnedTreeAndSucceedsTerminal() throws {
        let environment = try makeEnvironment()
        let fixture = try makeVerifiedPackageFixture()
        let installed = try environment.immutableStore.install(
            verified: fixture.verified,
            request: PluginInstallRequest(
                operationID: "install-before-uninstall-recovery",
                idempotencyKey: "install-before-uninstall-recovery-key",
                actorSubjectID: "owner",
                timestamp: createdAt
            ),
            repository: environment.store.plugins
        )
        let pending = try environment.store.plugins.beginRollback(PluginRollbackRecord(
            operationID: "recover-uninstall-cleanup",
            pluginIdentifier: installed.manifest.identifier,
            fromPackageDigest: nil,
            toPackageDigest: installed.packageDigest,
            stage: "uninstall-intent",
            status: "pending",
            idempotencyKey: "recover-uninstall-cleanup-key",
            ownershipEffects: installed.ownershipLedger,
            failureReasonCode: nil,
            requestedBySubjectID: "owner",
            generation: 1,
            createdAt: createdAt,
            updatedAt: createdAt
        ))
        let uninstalled = try environment.store.plugins.uninstall(
            digest: installed.packageDigest,
            expectedGeneration: installed.generation,
            actorSubjectID: "owner",
            timestamp: updatedAt
        )
        let operation = try environment.store.plugins.advanceRollback(
            operationID: pending.operationID,
            expectedGeneration: pending.generation,
            stage: "cleanup",
            status: "running",
            ownershipEffects: uninstalled.ownershipLedger,
            updatedAt: updatedAt
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: uninstalled.storagePath))

        let reopenedStore = SQLiteStateStore(path: environment.store.path)
        let restarted = try PluginImmutableStore(rootURL: environment.storageRoot)
        XCTAssertEqual(
            try restarted.recoverInterruptedOperations(
                repository: reopenedStore.plugins,
                timestamp: updatedAt
            ),
            1
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: uninstalled.storagePath))
        XCTAssertEqual(
            try reopenedStore.plugins.package(digest: installed.packageDigest)?.lifecycleState,
            .uninstalled
        )
        let awaitingAudit = try XCTUnwrap(
            reopenedStore.plugins.rollback(operationID: operation.operationID)
        )
        XCTAssertEqual(awaitingAudit.stage, "recovery-success-audit")
        XCTAssertEqual(awaitingAudit.status, "running")
        XCTAssertEqual(awaitingAudit.ownershipEffects, installed.ownershipLedger)
        XCTAssertEqual(
            try reopenedStore.plugins.incompleteRollbackOperations(),
            [awaitingAudit]
        )
        let terminal = try restarted.finalizeRecoveredOperation(
            operationID: operation.operationID,
            repository: reopenedStore.plugins,
            timestamp: updatedAt
        )
        XCTAssertEqual(terminal.stage, "complete")
        XCTAssertEqual(terminal.status, "succeeded")
        XCTAssertEqual(terminal.ownershipEffects, installed.ownershipLedger)
        XCTAssertTrue(try reopenedStore.plugins.incompleteRollbackOperations().isEmpty)
    }

    func testRestartRecoveryRefusesChangedOwnershipIdentityAndLeavesOperationIncomplete() throws {
        let environment = try makeEnvironment()
        let fixture = try makeVerifiedPackageFixture()
        let finalURL = environment.immutableStore.packageURL(digest: fixture.verified.packageDigest)
        let ledger = try publishVerifiedPackage(fixture.verified, to: finalURL)
        let operation = try beginInterruptedInstall(
            operationID: "recover-install-unsafe-ownership",
            package: fixture.verified,
            ownershipLedger: ledger,
            repository: environment.store.plugins
        )
        let entrypoint = finalURL.appendingPathComponent(fixture.verified.manifest.entrypoint)
        XCTAssertEqual(unlink(entrypoint.path), 0)
        try Data("valid-wasm-module".utf8).write(to: entrypoint)
        XCTAssertEqual(chmod(entrypoint.path, 0o400), 0)

        let reopenedStore = SQLiteStateStore(path: environment.store.path)
        let restarted = try PluginImmutableStore(rootURL: environment.storageRoot)
        XCTAssertThrowsError(
            try restarted.recoverInterruptedOperations(
                repository: reopenedStore.plugins,
                timestamp: updatedAt
            )
        ) { error in
            let diagnostic = error as? HostwrightDiagnostic
            XCTAssertEqual(diagnostic?.code, .extensionBlocked)
            XCTAssertTrue(diagnostic?.message.contains("identity changed") == true)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertEqual(
            try reopenedStore.plugins.rollback(operationID: operation.operationID),
            operation
        )
        XCTAssertEqual(
            try reopenedStore.plugins.incompleteRollbackOperations(),
            [operation]
        )
    }

    private func beginInterruptedInstall(
        operationID: String,
        package: VerifiedPluginPackage,
        ownershipLedger: [PluginOwnedArtifact],
        repository: PluginLifecycleRepository
    ) throws -> PluginRollbackRecord {
        let pending = try repository.beginRollback(PluginRollbackRecord(
            operationID: operationID,
            pluginIdentifier: package.manifest.identifier,
            fromPackageDigest: nil,
            toPackageDigest: package.packageDigest,
            stage: "install-intent",
            status: "pending",
            idempotencyKey: operationID + "-key",
            ownershipEffects: [],
            failureReasonCode: nil,
            requestedBySubjectID: "owner",
            generation: 1,
            createdAt: createdAt,
            updatedAt: createdAt
        ))
        return try repository.advanceRollback(
            operationID: operationID,
            expectedGeneration: pending.generation,
            stage: "staged",
            status: "running",
            ownershipEffects: ownershipLedger,
            updatedAt: updatedAt
        )
    }

    private func publishVerifiedPackage(
        _ package: VerifiedPluginPackage,
        to destination: URL
    ) throws -> [PluginOwnedArtifact] {
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let paths = [PluginPackageVerifier.manifestFileName] + package.manifest.contentDigests.map(\.path)
        for path in paths {
            let destinationURL = destination.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = path == PluginPackageVerifier.manifestFileName
                ? package.manifestData
                : try Data(contentsOf: package.sourceDirectoryURL.appendingPathComponent(path))
            try data.write(to: destinationURL)
            XCTAssertEqual(chmod(destinationURL.path, 0o400), 0)
        }
        let artifactURLs = [destination] + (try FileManager.default.subpathsOfDirectory(
            atPath: destination.path
        )).map { destination.appendingPathComponent($0) }
        return try artifactURLs.map { url in
            let metadata = try lstatMetadata(url.path)
            if metadata.st_mode & S_IFMT == S_IFDIR {
                XCTAssertEqual(chmod(url.path, 0o700), 0)
                return try PluginOwnedArtifact(
                    path: url.path,
                    kind: .directory,
                    deviceID: UInt64(metadata.st_dev),
                    inode: UInt64(metadata.st_ino)
                )
            }
            return try PluginOwnedArtifact(
                path: url.path,
                deviceID: UInt64(metadata.st_dev),
                inode: UInt64(metadata.st_ino),
                sha256Digest: digest(try Data(contentsOf: url))
            )
        }.sorted { $0.path < $1.path }
    }

    private func makeEnvironment() throws -> TestEnvironment {
        let root = try temporaryRoot(prefix: "hostwright-plugin-immutable-store")
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try store.controlIdentities.bootstrap(identity("owner"))
        let storageRoot = root.appendingPathComponent("immutable-store", isDirectory: true)
        let immutableStore = try PluginImmutableStore(rootURL: storageRoot)
        return TestEnvironment(root: root, storageRoot: storageRoot, store: store, immutableStore: immutableStore)
    }

    private func makeVerifiedPackageFixture(
        packageVersion: String = "1.0.0",
        moduleData: Data = Data("valid-wasm-module".utf8)
    ) throws -> VerifiedPackageFixture {
        let sourceRoot = try temporaryRoot(prefix: "hostwright-plugin-source")
        let signer = try TestCMSSigner(commonName: "Hostwright Plugin Test")
        let expectedSource = PluginSource(kind: .localDirectory, locator: sourceRoot.path)
        let files: [String: Data] = [
            "Resources/config.json": Data(#"{"mode":"test"}"#.utf8),
            "plugin.wasm": moduleData,
        ]
        let contentDigests = try files.keys.sorted().map { path in
            let data = try XCTUnwrap(files[path])
            try writePrivateFile(root: sourceRoot, relativePath: path, data: data)
            return PluginContentDigest(path: path, digest: digest(data))
        }
        let packageDigest = try PluginPackageVerifier.packageDigest(contentDigests: contentDigests)
        let signerIdentifier = "dev.hostwright.plugin-signer"
        let provenance = PluginProvenance(
            checksum: packageDigest,
            signature: try signer.sign(Data(packageDigest.utf8)).base64EncodedString(),
            signerIdentifier: signerIdentifier,
            source: expectedSource
        )
        let unsignedManifest = PluginPackageManifest(
            identifier: "dev.hostwright.plugin",
            packageVersion: packageVersion,
            hostwrightCompatibility: ">=1.0.0",
            providerKind: .wasi,
            entrypoint: "plugin.wasm",
            grants: [PluginGrant(capability: .diagnostics, scope: "read")],
            artifactDigest: try XCTUnwrap(contentDigests.first(where: { $0.path == "plugin.wasm" })?.digest),
            contentDigests: contentDigests,
            provenance: provenance,
            cmsSignature: Data("placeholder".utf8).base64EncodedString(),
            signerIdentifier: signerIdentifier
        )
        let manifest = PluginPackageManifest(
            abiVersion: unsignedManifest.abiVersion,
            identifier: unsignedManifest.identifier,
            packageVersion: unsignedManifest.packageVersion,
            hostwrightCompatibility: unsignedManifest.hostwrightCompatibility,
            providerKind: unsignedManifest.providerKind,
            entrypoint: unsignedManifest.entrypoint,
            grants: unsignedManifest.grants,
            artifactDigest: unsignedManifest.artifactDigest,
            contentDigests: unsignedManifest.contentDigests,
            provenance: unsignedManifest.provenance,
            cmsSignature: try signer.sign(
                PluginPackageVerifier.manifestSigningPayload(unsignedManifest)
            ).base64EncodedString(),
            signerIdentifier: unsignedManifest.signerIdentifier
        )
        let manifestData = try ControlPlaneCanonicalJSON.encode(manifest)
        try manifestData.write(
            to: sourceRoot.appendingPathComponent(PluginPackageVerifier.manifestFileName)
        )
        XCTAssertEqual(
            chmod(
                sourceRoot.appendingPathComponent(PluginPackageVerifier.manifestFileName).path,
                0o600
            ),
            0
        )
        let verifier = try PluginPackageVerifier(
            trustedSignerCertificates: [signerIdentifier: signer.certificateDER]
        )
        let verified = try verifier.verifyMaterializedPackage(at: sourceRoot, expectedSource: expectedSource)
        return VerifiedPackageFixture(sourceRoot: sourceRoot, verified: verified)
    }

    private func writePrivateFile(root: URL, relativePath: String, data: Data) throws {
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL)
        XCTAssertEqual(chmod(fileURL.path, 0o600), 0)
    }

    private func temporaryRoot(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func lstatMetadata(_ path: String) throws -> stat {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw POSIXError(.ENOENT)
        }
        return metadata
    }

    private func identity(_ subject: String) -> ControlPeerIdentityRecord {
        ControlPeerIdentityRecord(
            subjectID: subject,
            userID: 501,
            codeIdentity: CodeIdentity(
                teamIdentifier: "993YC3JY4Q",
                signingIdentifier: "hostwright",
                codeDirectoryHash: String(repeating: "a", count: 40),
                validationMode: .installedRequirement
            ),
            declaredBySubjectID: subject,
            declaredAt: createdAt,
            updatedAt: createdAt
        )
    }
}

private struct TestEnvironment {
    let root: URL
    let storageRoot: URL
    let store: SQLiteStateStore
    let immutableStore: PluginImmutableStore
}

private struct VerifiedPackageFixture {
    let sourceRoot: URL
    let verified: VerifiedPluginPackage
}

private final class TestCMSSigner {
    let certificateDER: Data
    private let root: URL
    private let keyURL: URL
    private let certificateURL: URL

    init(commonName: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-plugin-cms-\(UUID().uuidString)", isDirectory: true)
        keyURL = root.appendingPathComponent("key.pem")
        certificateURL = root.appendingPathComponent("certificate.pem")
        let certificateDERURL = root.appendingPathComponent("certificate.der")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            try Self.runOpenSSL(
                [
                    "req",
                    "-new",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-nodes",
                    "-keyout",
                    keyURL.path,
                    "-out",
                    certificateURL.path,
                    "-subj",
                    "/CN=\(commonName)",
                    "-days",
                    "1",
                    "-sha256"
                ]
            )
            try Self.runOpenSSL(
                [
                    "x509",
                    "-in",
                    certificateURL.path,
                    "-outform",
                    "DER",
                    "-out",
                    certificateDERURL.path
                ]
            )
            certificateDER = try Data(contentsOf: certificateDERURL)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func sign(_ content: Data) throws -> Data {
        let contentURL = root.appendingPathComponent("content-\(UUID().uuidString).bin")
        let signatureURL = root.appendingPathComponent("signature-\(UUID().uuidString).der")
        defer {
            try? FileManager.default.removeItem(at: contentURL)
            try? FileManager.default.removeItem(at: signatureURL)
        }
        try content.write(to: contentURL)
        try Self.runOpenSSL(
            [
                "smime",
                "-sign",
                "-binary",
                "-in",
                contentURL.path,
                "-signer",
                certificateURL.path,
                "-inkey",
                keyURL.path,
                "-outform",
                "DER",
                "-out",
                signatureURL.path
            ]
        )
        return try Data(contentsOf: signatureURL)
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw TestCMSError.opensslFailed
        }
    }
}

private enum TestCMSError: Error {
    case opensslFailed
}

private func digest(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
