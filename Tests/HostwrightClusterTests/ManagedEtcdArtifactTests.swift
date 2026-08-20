import CryptoKit
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
        XCTAssertEqual(linux.sha256, "d7e25e08f694b6ed7792fc7b7a891fe2c3f3d3dccfe2f3bfdb1545b8200c75b6da")
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
}
