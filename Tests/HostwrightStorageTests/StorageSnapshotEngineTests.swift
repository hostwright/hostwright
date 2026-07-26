import XCTest
@testable import HostwrightStorage

final class StorageSnapshotEngineTests: XCTestCase {
    func testCreateListInspectAndRestorePreserveBytes() async throws {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 32 * 1_024 * 1_024
        )
        let identity = LocalStorageTestIdentity()
        let created = try await createVolume(
            provider: provider,
            identity: identity,
            key: "snapshot-create"
        )
        try writeTree(
            root: URL(fileURLWithPath: created.dataPath, isDirectory: true),
            files: [
                "one.txt": "alpha",
                "nested/two.txt": "beta"
            ]
        )

        let engine = try StorageSnapshotEngine(
            provider: provider,
            snapshotRootURL: harness.containerRoot.appendingPathComponent("snapshots", isDirectory: true)
        )
        let snapshotID = UUID().uuidString.lowercased()
        let snapshot = try engine.create(
            snapshotID: snapshotID,
            name: "daily",
            volumeID: created.volumeID,
            expectedGeneration: created.generation,
            expectedFencingToken: created.fencingToken,
            consistency: .crashConsistent
        )

        XCTAssertEqual(try engine.list().map(\.snapshotID), [snapshotID])
        let inspected = try engine.inspect(snapshotID: snapshotID)
        XCTAssertEqual(inspected.snapshotID, snapshot.snapshotID)
        XCTAssertEqual(inspected.name, snapshot.name)
        XCTAssertEqual(inspected.consistencyClass, snapshot.consistencyClass)
        XCTAssertEqual(inspected.source, snapshot.source)
        XCTAssertEqual(inspected.parentContentTreeSHA256, snapshot.parentContentTreeSHA256)
        XCTAssertEqual(inspected.snapshotContentTreeSHA256, snapshot.snapshotContentTreeSHA256)
        XCTAssertEqual(inspected.retainedBy, snapshot.retainedBy)
        XCTAssertEqual(inspected.references, snapshot.references)
        XCTAssertEqual(inspected.lineage, snapshot.lineage)

        try writeTree(
            root: URL(fileURLWithPath: created.dataPath, isDirectory: true),
            files: ["live.txt": "changed"]
        )
        let restored = try engine.restore(
            snapshotID: snapshotID,
            toVolumeID: created.volumeID,
            expectedGeneration: created.generation,
            expectedFencingToken: created.fencingToken,
            referenceID: "restore-a"
        )
        XCTAssertEqual(restored.snapshot.snapshotID, snapshotID)
        XCTAssertEqual(
            try treeDigest(URL(fileURLWithPath: created.dataPath, isDirectory: true)),
            snapshot.snapshotContentTreeSHA256
        )
    }

    func testSnapshotExportAndRestorePreserveModesAndHashModeChanges()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 32 * 1_024 * 1_024
        )
        let identity = LocalStorageTestIdentity()
        let created = try await createVolume(
            provider: provider,
            identity: identity,
            key: "snapshot-modes"
        )
        let dataRoot = URL(
            fileURLWithPath: created.dataPath,
            isDirectory: true
        )
        let nested = dataRoot.appendingPathComponent(
            "private",
            isDirectory: true
        )
        let file = nested.appendingPathComponent(
            "config.txt",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o750]
        )
        try Data("secret".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o640), 0)
        XCTAssertEqual(chmod(nested.path, 0o750), 0)

        let engine = try StorageSnapshotEngine(
            provider: provider,
            snapshotRootURL: harness.containerRoot.appendingPathComponent(
                "snapshots",
                isDirectory: true
            )
        )
        let snapshotID = UUID().uuidString.lowercased()
        let snapshot = try engine.create(
            snapshotID: snapshotID,
            name: "modes",
            volumeID: created.volumeID,
            expectedGeneration: created.generation,
            expectedFencingToken: created.fencingToken,
            consistency: .crashConsistent
        )
        let snapshotData = harness.containerRoot
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(snapshotID, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
        XCTAssertEqual(
            try posixPermissions(
                snapshotData.appendingPathComponent(
                    "private",
                    isDirectory: true
                )
            ),
            0o750
        )
        XCTAssertEqual(
            try posixPermissions(
                snapshotData.appendingPathComponent(
                    "private/config.txt",
                    isDirectory: false
                )
            ),
            0o640
        )

        let exports = harness.containerRoot.appendingPathComponent(
            "exports",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: exports,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let exported = exports.appendingPathComponent(
            "snapshot",
            isDirectory: true
        )
        try engine.exportSnapshot(
            snapshotID: snapshotID,
            to: exported
        )
        XCTAssertEqual(
            try posixPermissions(
                exported.appendingPathComponent(
                    "data/private",
                    isDirectory: true
                )
            ),
            0o750
        )
        XCTAssertEqual(
            try posixPermissions(
                exported.appendingPathComponent(
                    "data/private/config.txt",
                    isDirectory: false
                )
            ),
            0o640
        )

        XCTAssertEqual(chmod(nested.path, 0o700), 0)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        _ = try engine.restore(
            snapshotID: snapshotID,
            toVolumeID: created.volumeID,
            expectedGeneration: created.generation,
            expectedFencingToken: created.fencingToken,
            referenceID: "restore-modes"
        )
        XCTAssertEqual(
            try posixPermissions(
                dataRoot.appendingPathComponent(
                    "private",
                    isDirectory: true
                )
            ),
            0o750
        )
        let restoredFile = dataRoot.appendingPathComponent(
            "private/config.txt",
            isDirectory: false
        )
        XCTAssertEqual(try posixPermissions(restoredFile), 0o640)
        XCTAssertEqual(
            try treeDigest(dataRoot),
            snapshot.snapshotContentTreeSHA256
        )

        XCTAssertEqual(chmod(restoredFile.path, 0o600), 0)
        XCTAssertNotEqual(
            try treeDigest(dataRoot),
            snapshot.snapshotContentTreeSHA256
        )
    }

    func testApplicationConsistentSnapshotUsesHooksAndThawsOnceAfterFailure()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 32 * 1_024 * 1_024
        )
        let identity = LocalStorageTestIdentity()
        let volume = try await createVolume(
            provider: provider,
            identity: identity,
            key: "snapshot-application-consistent"
        )
        let dataRoot = URL(
            fileURLWithPath: volume.dataPath,
            isDirectory: true
        )
        try writeTree(
            root: dataRoot,
            files: ["database/store.bin": "committed"]
        )
        let expectedDigest = try treeDigest(dataRoot)
        let engine = try StorageSnapshotEngine(
            provider: provider,
            snapshotRootURL: harness.containerRoot
                .appendingPathComponent(
                    "snapshots",
                    isDirectory: true
                )
        )
        let events = SnapshotHookEvents()
        let hooks = StorageSnapshotQuiesceHooks(
            preQuiesce: { events.append("freeze") },
            postQuiesce: { events.append("thaw") }
        )
        let snapshot = try engine.create(
            snapshotID: UUID().uuidString.lowercased(),
            name: "application-consistent",
            volumeID: volume.volumeID,
            expectedGeneration: volume.generation,
            expectedFencingToken: volume.fencingToken,
            consistency: .applicationConsistent,
            quiesceHooks: hooks
        )
        XCTAssertEqual(events.values, ["freeze", "thaw"])
        XCTAssertEqual(
            snapshot.consistencyClass,
            .applicationConsistent
        )
        XCTAssertEqual(
            snapshot.parentContentTreeSHA256,
            expectedDigest
        )
        XCTAssertEqual(
            snapshot.snapshotContentTreeSHA256,
            expectedDigest
        )
        XCTAssertEqual(
            snapshot.lineage,
            ["volume:\(volume.volumeID)@\(volume.generation)"]
        )

        events.reset()
        let fault = OneShotSnapshotFault(
            point: .createMetadataPrepared
        )
        XCTAssertThrowsError(
            try engine.create(
                snapshotID: UUID().uuidString.lowercased(),
                name: "failure-after-thaw",
                volumeID: volume.volumeID,
                expectedGeneration: volume.generation,
                expectedFencingToken: volume.fencingToken,
                consistency: .applicationConsistent,
                quiesceHooks: hooks,
                hooks: StorageSnapshotHooks(
                    faultInjector: fault.injector
                )
            )
        )
        XCTAssertEqual(events.values, ["freeze", "thaw"])
    }

    func testTamperDetectedBeforeExportAndRestore() async throws {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 32 * 1_024 * 1_024
        )
        let identity = LocalStorageTestIdentity()
        let created = try await createVolume(
            provider: provider,
            identity: identity,
            key: "snapshot-tamper"
        )
        try writeTree(
            root: URL(fileURLWithPath: created.dataPath, isDirectory: true),
            files: ["a.txt": "one"]
        )
        let engine = try StorageSnapshotEngine(
            provider: provider,
            snapshotRootURL: harness.containerRoot.appendingPathComponent("snapshots", isDirectory: true)
        )
        let snapshotID = UUID().uuidString.lowercased()
        _ = try engine.create(
            snapshotID: snapshotID,
            name: "tamper",
            volumeID: created.volumeID,
            expectedGeneration: created.generation,
            expectedFencingToken: created.fencingToken,
            consistency: .crashConsistent
        )
        let snapshotData = harness.containerRoot
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(snapshotID, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("a.txt", isDirectory: false)
        try "tampered".data(using: .utf8)?.write(to: snapshotData)

        XCTAssertThrowsError(
            try engine.exportSnapshot(
                snapshotID: snapshotID,
                to: harness.containerRoot.appendingPathComponent("exported", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual(error as? StorageSnapshotError, .integrityMismatch)
        }
        XCTAssertThrowsError(
            try engine.restore(
                snapshotID: snapshotID,
                toVolumeID: created.volumeID,
                expectedGeneration: created.generation,
                expectedFencingToken: created.fencingToken,
                referenceID: "restore-b"
            )
        ) { error in
            XCTAssertEqual(error as? StorageSnapshotError, .integrityMismatch)
        }
    }

    func testInterruptedCopyCleansPendingDirectory() async throws {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 32 * 1_024 * 1_024
        )
        let identity = LocalStorageTestIdentity()
        let created = try await createVolume(
            provider: provider,
            identity: identity,
            key: "snapshot-interrupt"
        )
        try writeTree(
            root: URL(fileURLWithPath: created.dataPath, isDirectory: true),
            files: ["a.txt": String(repeating: "x", count: 256 * 1_024)]
        )
        let engine = try StorageSnapshotEngine(
            provider: provider,
            snapshotRootURL: harness.containerRoot.appendingPathComponent("snapshots", isDirectory: true)
        )

        XCTAssertThrowsError(
            try engine.create(
                snapshotID: UUID().uuidString.lowercased(),
                name: "cancelled",
                volumeID: created.volumeID,
                expectedGeneration: created.generation,
                expectedFencingToken: created.fencingToken,
                consistency: .crashConsistent,
                hooks: StorageSnapshotHooks(isCancelled: { true })
            )
        ) { error in
            XCTAssertEqual(error as? StorageSnapshotError, .cancelled)
        }

        let pending = harness.containerRoot
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(".pending", isDirectory: true)
        let remaining = try FileManager.default.contentsOfDirectory(
            at: pending,
            includingPropertiesForKeys: nil,
            options: []
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    func testStaleFenceRetainedDeleteReferencedDeleteAndRollback() async throws {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 32 * 1_024 * 1_024
        )
        let identity = LocalStorageTestIdentity()
        let created = try await createVolume(
            provider: provider,
            identity: identity,
            key: "snapshot-constraints"
        )
        try writeTree(
            root: URL(fileURLWithPath: created.dataPath, isDirectory: true),
            files: ["a.txt": "stable"]
        )
        let engine = try StorageSnapshotEngine(
            provider: provider,
            snapshotRootURL: harness.containerRoot.appendingPathComponent("snapshots", isDirectory: true)
        )
        let snapshotID = UUID().uuidString.lowercased()

        XCTAssertThrowsError(
            try engine.create(
                snapshotID: snapshotID,
                name: "wrong-fence",
                volumeID: created.volumeID,
                expectedGeneration: created.generation,
                expectedFencingToken: UUID().uuidString.lowercased(),
                consistency: .crashConsistent
            )
        ) { error in
            XCTAssertEqual(error as? StorageSnapshotError, .fencingConflict)
        }

        _ = try engine.create(
            snapshotID: snapshotID,
            name: "stable",
            volumeID: created.volumeID,
            expectedGeneration: created.generation,
            expectedFencingToken: created.fencingToken,
            consistency: .crashConsistent
        )
        _ = try engine.retain(snapshotID: snapshotID, retainerID: "keep")
        XCTAssertThrowsError(try engine.delete(snapshotID: snapshotID)) { error in
            XCTAssertEqual(error as? StorageSnapshotError, .snapshotRetained)
        }

        let unretainedID = UUID().uuidString.lowercased()
        _ = try engine.create(
            snapshotID: unretainedID,
            name: "restore-source",
            volumeID: created.volumeID,
            expectedGeneration: created.generation,
            expectedFencingToken: created.fencingToken,
            consistency: .crashConsistent
        )
        try writeTree(
            root: URL(fileURLWithPath: created.dataPath, isDirectory: true),
            files: ["live.txt": "new"]
        )
        _ = try engine.restore(
            snapshotID: unretainedID,
            toVolumeID: created.volumeID,
            expectedGeneration: created.generation,
            expectedFencingToken: created.fencingToken,
            referenceID: "active-restore"
        )
        XCTAssertThrowsError(try engine.delete(snapshotID: unretainedID)) { error in
            XCTAssertEqual(error as? StorageSnapshotError, .snapshotReferenced)
        }

        try writeTree(
            root: URL(fileURLWithPath: created.dataPath, isDirectory: true),
            files: ["rollback.txt": "must-survive"]
        )
        let before = try fileContents(
            URL(fileURLWithPath: created.dataPath, isDirectory: true)
                .appendingPathComponent("rollback.txt", isDirectory: false)
        )
        let fault = OneShotSnapshotFault(point: .restoreBackupPrepared)
        XCTAssertThrowsError(
            try engine.restore(
                snapshotID: unretainedID,
                toVolumeID: created.volumeID,
                expectedGeneration: created.generation,
                expectedFencingToken: created.fencingToken,
                referenceID: "rollback-check",
                hooks: StorageSnapshotHooks(
                    faultInjector: fault.injector
                )
            )
        )
        XCTAssertEqual(
            try fileContents(
                URL(fileURLWithPath: created.dataPath, isDirectory: true)
                    .appendingPathComponent("rollback.txt", isDirectory: false)
            ),
            before
        )
    }

    func testSymlinkAndWrongParentAreRejected() async throws {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 32 * 1_024 * 1_024
        )
        let identity = LocalStorageTestIdentity()
        let created = try await createVolume(
            provider: provider,
            identity: identity,
            key: "snapshot-symlink"
        )
        let dataRoot = URL(fileURLWithPath: created.dataPath, isDirectory: true)
        let regular = dataRoot.appendingPathComponent("safe.txt", isDirectory: false)
        try "safe".data(using: .utf8)?.write(to: regular)
        let link = dataRoot.appendingPathComponent("bad-link", isDirectory: false)
        XCTAssertEqual(symlink("/etc/passwd", link.path), 0)

        let engine = try StorageSnapshotEngine(
            provider: provider,
            snapshotRootURL: harness.containerRoot.appendingPathComponent("snapshots", isDirectory: true)
        )
        XCTAssertThrowsError(
            try engine.create(
                snapshotID: UUID().uuidString.lowercased(),
                name: "bad",
                volumeID: created.volumeID,
                expectedGeneration: created.generation,
                expectedFencingToken: created.fencingToken,
                consistency: .crashConsistent
            )
        ) { error in
            XCTAssertEqual(error as? StorageSnapshotError, .unsafePath)
        }

        try? FileManager.default.removeItem(at: link)
        let snapshotID = UUID().uuidString.lowercased()
        _ = try engine.create(
            snapshotID: snapshotID,
            name: "good",
            volumeID: created.volumeID,
            expectedGeneration: created.generation,
            expectedFencingToken: created.fencingToken,
            consistency: .crashConsistent
        )

        let realParent = harness.containerRoot.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let aliasedParent = harness.containerRoot.appendingPathComponent("exports-alias", isDirectory: true)
        XCTAssertEqual(symlink(realParent.path, aliasedParent.path), 0)
        XCTAssertThrowsError(
            try engine.exportSnapshot(
                snapshotID: snapshotID,
                to: aliasedParent.appendingPathComponent("bad-export", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual(error as? StorageSnapshotError, .wrongParent)
        }
    }

    private func createVolume(
        provider: LocalStorageProvider,
        identity: LocalStorageTestIdentity,
        key: String
    ) async throws -> LocalStorageVolumeObservation {
        let request = LocalStorageProviderTestRequest(
            operation: .create,
            context: identity.context(resourceGeneration: 1),
            idempotencyKey: key,
            payload: LocalStorageCreatePayload(
                name: "volume-\(identity.volumeID.prefix(8))",
                capacityBytes: 1_024 * 1_024,
                retention: .retain
            )
        )
        let response = try await provider.invoke(canonicalRequest: request.canonical())
        let result = try StorageProviderCanonicalJSON.decodeResult(
            LocalStorageMutationResult.self,
            from: response
        ).result
        return try XCTUnwrap(result.volume)
    }

    private func writeTree(
        root: URL,
        files: [String: String]
    ) throws {
        for (relative, contents) in files {
            let file = root.appendingPathComponent(relative, isDirectory: false)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try contents.data(using: .utf8)?.write(to: file)
        }
    }

    private func treeDigest(_ root: URL) throws -> String {
        try StorageSnapshotFilesystem.hashTree(
            at: root,
            hooks: StorageSnapshotHooks()
        ).sha256
    }

    private func fileContents(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func posixPermissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        ).intValue
    }
}

private final class OneShotSnapshotFault: @unchecked Sendable {
    private let point: StorageSnapshotCheckpoint
    private let lock = NSLock()
    private var fired = false

    init(point: StorageSnapshotCheckpoint) {
        self.point = point
    }

    var injector: StorageSnapshotFaultInjector {
        StorageSnapshotFaultInjector { [self] candidate in
            lock.lock()
            defer { lock.unlock() }
            if candidate == point, !fired {
                fired = true
                throw StorageSnapshotError.ioFailure
            }
        }
    }
}

private final class SnapshotHookEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        events = []
        lock.unlock()
    }
}
