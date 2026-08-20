import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import XCTest
@testable import HostwrightCluster

final class ManagedEtcdArtifactTests: XCTestCase {
    func testPinnedArtifactCatalogAndPrivateLayoutAreExact() throws {
        let darwin = ManagedEtcdArtifact.darwinArm64
        XCTAssertEqual(darwin.version, "v3.7.1")
        XCTAssertEqual(darwin.archiveKind, .zip)
        XCTAssertEqual(darwin.sha256, "a3e839d9128e170c299b1592bed92d8327f258eb94923aea24a0ccf923cf27e9")
        XCTAssertEqual(darwin.archiveFileName, "etcd-v3.7.1-darwin-arm64.zip")

        let linux = ManagedEtcdArtifact.linuxArm64
        XCTAssertEqual(linux.archiveKind, .tarGz)
        XCTAssertEqual(linux.sha256, "d7e25e08f694b6ed7792fc7b7a891fe2c3f3d3dccfe2f3bfdb1547b0eb75b6da")
        XCTAssertEqual(linux.archiveFileName, "etcd-v3.7.1-linux-arm64.tar.gz")

        let clusterID = try ClusterID("11111111-1111-4111-8111-111111111111")
        let nodeID = try ClusterNodeID("22222222-2222-4222-8222-222222222222")
        let layout = try ManagedEtcdLayout(
            rootDirectory: "/private/tmp/hostwright-etcd",
            artifact: darwin,
            clusterID: clusterID,
            nodeID: nodeID
        )
        XCTAssertEqual(layout.installDirectory, "/private/tmp/hostwright-etcd/versions/v3.7.1/darwin-arm64")
        XCTAssertEqual(layout.executablePath, layout.installDirectory + "/etcd")
        XCTAssertEqual(layout.dataDirectory, "/private/tmp/hostwright-etcd/data/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(layout.configDirectory, "/private/tmp/hostwright-etcd/config/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(layout.expectedDirectoryMode, 0o700)
        XCTAssertEqual(layout.expectedConfigFileMode, 0o600)
        XCTAssertTrue(layout.ownedCleanupPaths.allSatisfy { $0.hasPrefix("/private/tmp/hostwright-etcd/") })
        XCTAssertFalse(layout.ownedCleanupPaths.contains(layout.rootDirectory))
    }

    func testArchiveEntryValidationRejectsTraversalAndLinks() throws {
        let artifact = ManagedEtcdArtifact.darwinArm64
        let root = artifact.archiveRoot
        let valid = [
            ManagedEtcdArchiveEntry(path: root + "/", type: .directory),
            ManagedEtcdArchiveEntry(path: root + "/etcd", type: .regular, mode: 0o755)
        ]
        XCTAssertNoThrow(try ManagedEtcdArchiveValidator.validate(entries: valid, for: artifact))

        let unsafeEntries = [
            ManagedEtcdArchiveEntry(path: root + "/etcd", type: .regular),
            ManagedEtcdArchiveEntry(path: "../../escape", type: .regular)
        ]
        XCTAssertThrowsError(try ManagedEtcdArchiveValidator.validate(entries: unsafeEntries, for: artifact))

        let linkEntries = [
            ManagedEtcdArchiveEntry(path: root + "/etcd", type: .symbolicLink)
        ]
        XCTAssertThrowsError(try ManagedEtcdArchiveValidator.validate(entries: linkEntries, for: artifact))
    }

    func testChecksumMismatchAndCancellationNeverAcceptAnArchive() throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("hostwright-etcd-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent(ManagedEtcdArtifact.darwinArm64.archiveFileName)
        try Data("not-the-pinned-etcd-archive".utf8).write(to: archive)

        XCTAssertThrowsError(
            try ManagedEtcdArtifactVerifier().accept(
                artifact: .darwinArm64,
                archiveURL: archive
            )
        ) { error in
            guard case .checksumMismatch(let expected, _) = error as? ManagedEtcdError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(expected, ManagedEtcdArtifact.darwinArm64.sha256)
        }

        let cancellation = SecureSubprocessCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(
            try ManagedEtcdArtifactVerifier().accept(
                artifact: .darwinArm64,
                archiveURL: archive,
                cancellation: cancellation
            )
        ) { error in
            XCTAssertEqual(error as? ManagedEtcdError, .cancelled)
        }
    }

    func testProvenanceAndSupervisionConfigurationContainNoSecrets() throws {
        let clusterID = try ClusterID("11111111-1111-4111-8111-111111111111")
        let nodeID = try ClusterNodeID("22222222-2222-4222-8222-222222222222")
        let layout = try ManagedEtcdLayout(
            rootDirectory: "/private/tmp/hostwright-etcd",
            artifact: .darwinArm64,
            clusterID: clusterID,
            nodeID: nodeID
        )
        let provenance = ManagedEtcdProvenanceRecord(
            artifact: .darwinArm64,
            verifierVersion: "hostwright-cluster-contract-v1"
        )
        XCTAssertNoThrow(try provenance.validate())
        let canonical = try provenance.canonicalJSON()
        XCTAssertEqual(canonical, try ManagedEtcdProvenanceRecord.decodeCanonical(canonical).canonicalJSON())

        let configuration = try ManagedEtcdSupervisedProcessConfiguration(
            layout: layout,
            nodeID: nodeID,
            peerEndpoint: "https://node-1.example.test:2380",
            clientEndpoint: "https://node-1.example.test:2379",
            initialCluster: []
        )
        XCTAssertFalse(configuration.arguments.contains { $0.contains("secret") })
        XCTAssertEqual(configuration.secureSubprocessRequest().environment, [
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": SecureSubprocessEnvironment.trustedSystemPath
        ])
        XCTAssertEqual(configuration.executablePath, layout.executablePath)
    }

    func testCodableBoundariesRejectTamperedLayoutProvenanceAndSupervision() throws {
        let clusterID = try ClusterID("11111111-1111-4111-8111-111111111111")
        let nodeID = try ClusterNodeID("22222222-2222-4222-8222-222222222222")
        let layout = try ManagedEtcdLayout(
            rootDirectory: "/private/tmp/hostwright-etcd",
            artifact: .darwinArm64,
            clusterID: clusterID,
            nodeID: nodeID
        )
        let encoder = JSONEncoder()

        var tamperedLayout = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(layout)) as? [String: Any]
        )
        tamperedLayout["rootDirectory"] = "/"
        let tamperedLayoutData = try JSONSerialization.data(withJSONObject: tamperedLayout)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ManagedEtcdLayout.self, from: tamperedLayoutData)
        )

        let provenance = ManagedEtcdProvenanceRecord(
            artifact: .darwinArm64,
            verifierVersion: "hostwright-cluster-contract-v1"
        )
        var tamperedProvenance = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(provenance)) as? [String: Any]
        )
        tamperedProvenance["entryPaths"] = ["../../escape"]
        let tamperedProvenanceData = try JSONSerialization.data(withJSONObject: tamperedProvenance)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ManagedEtcdProvenanceRecord.self, from: tamperedProvenanceData)
        )

        let configuration = try ManagedEtcdSupervisedProcessConfiguration(
            layout: layout,
            nodeID: nodeID,
            peerEndpoint: "https://node-1.example.test:2380",
            clientEndpoint: "https://node-1.example.test:2379",
            initialCluster: []
        )
        var tamperedConfiguration = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(configuration)) as? [String: Any]
        )
        tamperedConfiguration["environment"] = ["PATH": "/tmp"]
        let tamperedConfigurationData = try JSONSerialization.data(withJSONObject: tamperedConfiguration)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ManagedEtcdSupervisedProcessConfiguration.self,
                from: tamperedConfigurationData
            )
        )
    }

    func testSnapshotRestoreAndCleanupPlansStayInsideOwnedBoundaries() throws {
        let clusterID = try ClusterID("11111111-1111-4111-8111-111111111111")
        let nodeID = try ClusterNodeID("22222222-2222-4222-8222-222222222222")
        let layout = try ManagedEtcdLayout(
            rootDirectory: "/private/tmp/hostwright-etcd",
            artifact: .darwinArm64,
            clusterID: clusterID,
            nodeID: nodeID
        )
        let snapshot = try ManagedEtcdSnapshotPlanner().makeSnapshotPlan(layout: layout, snapshotID: "snapshot-1")
        XCTAssertEqual(snapshot.destinationDirectory, layout.snapshotsDirectory + "/snapshot-1")
        let restore = try ManagedEtcdSnapshotPlanner().makeRestorePlan(
            layout: layout,
            snapshotDirectory: snapshot.destinationDirectory
        )
        XCTAssertTrue(restore.requiresQuorumStopped)
        XCTAssertTrue(restore.backupDirectory.hasPrefix(layout.runtimeDirectory + "/"))

        let cleanup = try ManagedEtcdCleanupPlan(layout: layout)
        XCTAssertTrue(cleanup.owns(layout.dataDirectory))
        XCTAssertThrowsError(try cleanup.validateCandidate(layout.rootDirectory + "/unmanaged"))
        XCTAssertNoThrow(try cleanup.validateCandidate(layout.dataDirectory))
    }

    func testPreparationAndCleanupRemoveOnlyExactOwnedDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("hostwright-etcd-cleanup-" + UUID().uuidString, isDirectory: true)
            .path
        defer {
            if FileManager.default.fileExists(atPath: root) {
                try? FileManager.default.removeItem(atPath: root)
            }
        }

        let clusterID = try ClusterID("11111111-1111-4111-8111-111111111111")
        let nodeID = try ClusterNodeID("22222222-2222-4222-8222-222222222222")
        let layout = try ManagedEtcdLayout(
            rootDirectory: root,
            artifact: .darwinArm64,
            clusterID: clusterID,
            nodeID: nodeID
        )
        let preparation = try layout.prepareDirectories()
        XCTAssertTrue(preparation.directories.contains(layout.dataDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.dataDirectory))

        let cleanup = try ManagedEtcdCleanupPlan(layout: layout)
        XCTAssertFalse(cleanup.ownedPaths.contains(root))
        let report = try cleanup.execute()
        XCTAssertEqual(Set(report.removedPaths), Set(layout.ownedCleanupPaths))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.dataDirectory))
        XCTAssertThrowsError(try cleanup.validateCandidate(root))
    }

    func testLinuxDigestUsesOfficialReleaseChecksum() throws {
        XCTAssertEqual(
            ManagedEtcdArtifact.linuxArm64.sha256,
            "d7e25e08f694b6ed7792fc7b7a891fe2c3f3d3dccfe2f3bfdb1547b0eb75b6da"
        )
        XCTAssertEqual(ManagedEtcdArtifact.linuxArm64.sha256.utf8.count, 64)
    }

    func testInstallerReverifiesArchiveBeforeAtomicPublish() throws {
        let root = try makeTemporaryRoot("hostwright-etcd-install")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeLayout(root: root.path)
        let archive = root.appendingPathComponent("untrusted.zip")
        try Data("not-an-etcd-archive".utf8).write(to: archive)
        let artifact = ManagedEtcdArtifact.darwinArm64
        let provenance = ManagedEtcdProvenanceRecord(
            artifact: artifact,
            verifierVersion: "test",
            entryPaths: [artifact.archiveRoot, artifact.executableEntryPath]
        )
        let forged = ManagedEtcdVerifiedArchive(
            artifact: artifact,
            archivePath: archive.path,
            archiveSHA256: artifact.sha256,
            entries: [
                ManagedEtcdArchiveEntry(path: artifact.archiveRoot, type: .directory),
                ManagedEtcdArchiveEntry(path: artifact.executableEntryPath, type: .regular)
            ],
            provenance: provenance
        )

        XCTAssertThrowsError(
            try ManagedEtcdInstaller().install(verifiedArchive: forged, layout: layout)
        ) { error in
            guard case .checksumMismatch(let expected, _) = error as? ManagedEtcdError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(expected, artifact.sha256)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.executablePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.provenancePath))
    }

    func testOfficialDarwinArchiveCanBeVerifiedInstalledAndCleanedWhenExplicitlyProvided() throws {
        guard let archivePath = ProcessInfo.processInfo.environment["HOSTWRIGHT_P11_ETCD_ARCHIVE"],
              !archivePath.isEmpty else {
            throw XCTSkip("set HOSTWRIGHT_P11_ETCD_ARCHIVE to run the official-artifact qualification")
        }

        let archiveURL = URL(fileURLWithPath: archivePath)
        let verified = try ManagedEtcdArtifactVerifier().accept(
            artifact: .darwinArm64,
            archiveURL: archiveURL
        )
        XCTAssertEqual(verified.archiveSHA256, ManagedEtcdArtifact.darwinArm64.sha256)

        let root = try makeTemporaryRoot("hostwright-etcd-official-install")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeLayout(root: root.path)
        let report = try ManagedEtcdInstaller().install(
            verifiedArchive: verified,
            layout: layout
        )
        XCTAssertEqual(report.executablePath, layout.executablePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.executablePath))

        let executable = try SecureExecutableResolver.verify(
            path: report.executablePath,
            ownershipPolicy: .rootOrCurrentUser
        )
        let version = try SecureSubprocessRunner().run(
            SecureSubprocessRequest(
                executablePath: executable.path,
                arguments: ["--version"],
                environment: SecureSubprocessEnvironment.minimal,
                workingDirectory: layout.installDirectory,
                timeoutMilliseconds: 10_000,
                terminationGraceMilliseconds: 1_000,
                maximumStandardOutputBytes: 64 * 1_024,
                maximumStandardErrorBytes: 64 * 1_024
            )
        )
        XCTAssertEqual(version.exitStatus, 0)
        XCTAssertTrue(
            (String(data: version.standardOutput, encoding: .utf8) ?? "").contains("etcd Version: 3.7.1")
        )

        let provenance = try Data(contentsOf: URL(fileURLWithPath: layout.provenancePath))
        XCTAssertNoThrow(try ManagedEtcdProvenanceRecord.decodeCanonical(provenance))

        let cleanup = try ManagedEtcdCleanupPlan(layout: layout)
        let cleanupReport = try cleanup.execute()
        XCTAssertEqual(Set(cleanupReport.removedPaths), Set(layout.ownedCleanupPaths))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.rootDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.installDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.provenancePath))
    }

    func testInstallerRecoveryRemovesOnlyOwnedStagingDirectories() throws {
        let root = try makeTemporaryRoot("hostwright-etcd-install-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeLayout(root: root.path)
        _ = try layout.prepareDirectories()
        let stale = URL(fileURLWithPath: layout.runtimeDirectory)
            .appendingPathComponent("install-stage-stale", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try Data("stale".utf8).write(to: stale.appendingPathComponent("archive"))
        chmod(stale.path, 0o700)

        let recovered = try ManagedEtcdInstaller().recoverStaging(layout: layout)

        XCTAssertEqual(recovered, [stale.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.rootDirectory))
    }

    func testInstallerCancellationLeavesNoPublishOrStagingResidue() throws {
        let root = try makeTemporaryRoot("hostwright-etcd-install-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeLayout(root: root.path)
        let artifact = ManagedEtcdArtifact.darwinArm64
        let provenance = ManagedEtcdProvenanceRecord(
            artifact: artifact,
            verifierVersion: "test",
            entryPaths: [artifact.archiveRoot, artifact.executableEntryPath]
        )
        let forged = ManagedEtcdVerifiedArchive(
            artifact: artifact,
            archivePath: root.appendingPathComponent("archive.zip").path,
            archiveSHA256: artifact.sha256,
            entries: [],
            provenance: provenance
        )
        let cancellation = SecureSubprocessCancellation()
        cancellation.cancel()

        XCTAssertThrowsError(
            try ManagedEtcdInstaller().install(
                verifiedArchive: forged,
                layout: layout,
                cancellation: cancellation
            )
        ) { error in
            XCTAssertEqual(error as? ManagedEtcdError, .cancelled)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.rootDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.executablePath))
    }

    func testSnapshotAndRestoreExecutionAreAtomicAndPrivate() throws {
        let root = try makeTemporaryRoot("hostwright-etcd-snapshot")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeLayout(root: root.path)
        _ = try layout.prepareDirectories()
        let dataFile = URL(fileURLWithPath: layout.dataDirectory).appendingPathComponent("member.db")
        try Data("before".utf8).write(to: dataFile)
        chmod(dataFile.path, 0o600)

        let planner = ManagedEtcdSnapshotPlanner()
        let snapshotPlan = try planner.makeSnapshotPlan(layout: layout, snapshotID: "snapshot-1")
        let executor = ManagedEtcdSnapshotExecutor()
        let snapshot = try executor.createSnapshot(
            plan: snapshotPlan,
            layout: layout,
            processState: .stopped
        )
        XCTAssertEqual(snapshot.destinationDirectory, snapshotPlan.destinationDirectory)
        XCTAssertEqual(
            try String(
                contentsOfFile: snapshotPlan.destinationDirectory + "/member.db",
                encoding: .utf8
            ),
            "before"
        )
        XCTAssertEqual(try fileMode(atPath: snapshotPlan.destinationDirectory), 0o700)
        XCTAssertEqual(try fileMode(atPath: snapshotPlan.destinationDirectory + "/member.db"), 0o600)

        try Data("changed".utf8).write(to: dataFile)
        chmod(dataFile.path, 0o600)
        let restorePlan = try planner.makeRestorePlan(
            layout: layout,
            snapshotDirectory: snapshotPlan.destinationDirectory
        )
        let restored = try executor.restore(
            plan: restorePlan,
            layout: layout,
            processState: .stopped
        )
        XCTAssertEqual(restored.backupDirectory, restorePlan.backupDirectory)
        XCTAssertEqual(try String(contentsOf: dataFile, encoding: .utf8), "before")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restorePlan.backupDirectory))
    }

    func testRestoreRefusesRunningMemberAndCancellationDoesNotCreateSnapshot() throws {
        let root = try makeTemporaryRoot("hostwright-etcd-restore-refusal")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeLayout(root: root.path)
        _ = try layout.prepareDirectories()
        let planner = ManagedEtcdSnapshotPlanner()
        let snapshotPlan = try planner.makeSnapshotPlan(layout: layout, snapshotID: "snapshot-2")
        let restorePlan = try planner.makeRestorePlan(
            layout: layout,
            snapshotDirectory: snapshotPlan.destinationDirectory
        )
        let executor = ManagedEtcdSnapshotExecutor()

        XCTAssertThrowsError(
            try executor.restore(plan: restorePlan, layout: layout, processState: .running)
        ) { error in
            guard case .restoreRefused = error as? ManagedEtcdError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let unverifiedSnapshot = URL(fileURLWithPath: layout.snapshotsDirectory)
            .appendingPathComponent("snapshot-unverified", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unverifiedSnapshot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let unverifiedRestorePlan = try planner.makeRestorePlan(
            layout: layout,
            snapshotDirectory: unverifiedSnapshot.path
        )
        XCTAssertThrowsError(
            try executor.restore(
                plan: unverifiedRestorePlan,
                layout: layout,
                processState: .stopped
            )
        ) { error in
            guard case .restoreRefused = error as? ManagedEtcdError else {
                return XCTFail("unexpected managed etcd error: \(error)")
            }
        }

        let cancellation = SecureSubprocessCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(
            try executor.createSnapshot(
                plan: snapshotPlan,
                layout: layout,
                processState: .stopped,
                cancellation: cancellation
            )
        ) { error in
            XCTAssertEqual(error as? ManagedEtcdError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotPlan.destinationDirectory))
    }

    func testSupervisorFailedStartHealthFailureAndStopAreExplicit() async throws {
        let root = try makeTemporaryRoot("hostwright-etcd-supervisor")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeLayout(root: root.path)
        _ = try layout.prepareDirectories()
        let configuration = try makeProcessConfiguration(layout: layout)
        let supervisor = try ManagedEtcdMemberSupervisor(
            configuration: configuration,
            healthEndpoint: URL(string: "https://127.0.0.1:1/health")!
        )

        do {
            _ = try await supervisor.start()
            XCTFail("a missing etcd executable must not report a successful start")
        } catch let error as ManagedEtcdError {
            guard case .processStartFailed = error else {
                return XCTFail("unexpected managed etcd error: \(error)")
            }
        }
        let failed = await supervisor.status()
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNil(failed.processID)

        do {
            _ = try await supervisor.checkHealth()
            XCTFail("health must not be checked for a stopped member")
        } catch let error as ManagedEtcdError {
            XCTAssertEqual(error, .processNotRunning)
        }
        let stopped = await supervisor.stop()
        XCTAssertEqual(stopped.state, .stopped)
    }

    func testSupervisorTracksRunningAndFailedHealthForNonEtcdFixture() async throws {
        let root = try makeTemporaryRoot("hostwright-etcd-supervisor-health")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeLayout(root: root.path)
        _ = try layout.prepareDirectories()
        let source = try XCTUnwrap(
            Bundle.module.url(
                forResource: "ManagedEtcdSupervisorFixture",
                withExtension: "swift"
            )
        )
        let compiler = try SecureExecutableResolver.verify(path: "/usr/bin/swiftc")
        let result = try SecureSubprocessRunner().run(
            SecureSubprocessRequest(
                executablePath: compiler.path,
                arguments: [source.path, "-o", layout.executablePath],
                environment: SecureSubprocessEnvironment.minimal,
                workingDirectory: "/",
                timeoutMilliseconds: 30_000,
                terminationGraceMilliseconds: 1_000,
                maximumStandardOutputBytes: 1 * 1_024 * 1_024,
                maximumStandardErrorBytes: 1 * 1_024 * 1_024
            )
        )
        XCTAssertEqual(result.exitStatus, 0, String(data: result.standardError, encoding: .utf8) ?? "")
        XCTAssertEqual(chmod(layout.executablePath, 0o700), 0)

        let configuration = try makeProcessConfiguration(layout: layout)
        let supervisor = try ManagedEtcdMemberSupervisor(
            configuration: configuration,
            healthEndpoint: URL(string: "https://127.0.0.1:1/health")!
        )
        let running = try await supervisor.start()
        XCTAssertEqual(running.state, .running)
        XCTAssertNotNil(running.processID)

        do {
            _ = try await supervisor.checkHealth()
            XCTFail("an unavailable health endpoint must not report a healthy member")
        } catch let error as ManagedEtcdError {
            guard case .healthCheckFailed = error else {
                return XCTFail("unexpected managed etcd error: \(error)")
            }
        }
        let unhealthy = await supervisor.status()
        XCTAssertEqual(unhealthy.state, .unhealthy)
        XCTAssertEqual(unhealthy.lastHealthCheckSucceeded, false)

        let stopped = await supervisor.stop()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.processID)
    }

    private func makeLayout(root: String) throws -> ManagedEtcdLayout {
        try ManagedEtcdLayout(
            rootDirectory: root,
            artifact: .darwinArm64,
            clusterID: try ClusterID("11111111-1111-4111-8111-111111111111"),
            nodeID: try ClusterNodeID("22222222-2222-4222-8222-222222222222")
        )
    }

    private func makeProcessConfiguration(
        layout: ManagedEtcdLayout
    ) throws -> ManagedEtcdSupervisedProcessConfiguration {
        try ManagedEtcdSupervisedProcessConfiguration(
            layout: layout,
            nodeID: try XCTUnwrap(layout.nodeID),
            peerEndpoint: "https://127.0.0.1:2380",
            clientEndpoint: "https://127.0.0.1:2379",
            initialCluster: []
        )
    }

    private func makeTemporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + "-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
        return root
    }

    private func fileMode(atPath path: String) throws -> Int {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int(metadata.st_mode & 0o7777)
    }
}
