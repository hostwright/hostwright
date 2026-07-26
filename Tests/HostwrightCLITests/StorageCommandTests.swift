import CryptoKit
import Foundation
import HostwrightCLI
import HostwrightCore
import HostwrightSecrets
import HostwrightState
import HostwrightStorage
import XCTest

final class StorageCommandTests: XCTestCase {
    private let volume1 =
        "11111111-1111-4111-8111-111111111111"
    private let volume2 =
        "22222222-2222-4222-8222-222222222222"
    private let volume3 =
        "88888888-8888-4888-8888-888888888888"
    private let volume4 =
        "99999999-9999-4999-8999-999999999999"
    private let snapshot =
        "33333333-3333-4333-8333-333333333333"
    private let backup =
        "44444444-4444-4444-8444-444444444444"
    private let reference =
        "55555555-5555-4555-8555-555555555555"
    private let deletableSnapshot =
        "66666666-6666-4666-8666-666666666666"
    private let deletableBackup =
        "77777777-7777-4777-8777-777777777777"
    private let confirmation = String(repeating: "a", count: 64)

    func testEveryVolumeOperationHasOneStrictCLIShape() throws {
        let commands: [[String]] = [
            ["volume", "list", "--project", "project-a", "--json"],
            ["volume", "inspect", volume1, "--json"],
            ["volume", "capacity", "--json"],
            ["volume", "health", "--json"],
            [
                "volume", "recover", volume1,
                "--idempotency-key", "operation-a", "--json",
            ],
            ["volume", "delete", volume1, "--dry-run", "--json"],
            [
                "volume", "prune", "--confirm-plan",
                confirmation, "--json",
            ],
            [
                "volume", "snapshot", "create", volume1,
                "--snapshot-id", snapshot,
                "--name", "daily", "--json",
            ],
            ["volume", "snapshot", "list", volume1, "--json"],
            [
                "volume", "snapshot", "inspect",
                volume1, snapshot, "--json",
            ],
            [
                "volume", "snapshot", "retain",
                volume1, snapshot, "--owner", "policy-a", "--json",
            ],
            [
                "volume", "snapshot", "export",
                volume1, snapshot,
                "--output", "/private/tmp/export", "--json",
            ],
            [
                "volume", "snapshot", "restore", snapshot,
                "--source-volume", volume1,
                "--to-volume", volume2,
                "--reference-id", reference,
                "--dry-run", "--json",
            ],
            [
                "volume", "snapshot", "delete",
                volume1, snapshot, "--dry-run", "--json",
            ],
            [
                "volume", "backup", "create",
                "--volume", volume1,
                "--volume", volume2,
                "--backup-id", backup,
                "--name", "nightly",
                "--key-ref", "keychain://hostwright/backup",
                "--json",
            ],
            ["volume", "backup", "list", volume1, "--json"],
            [
                "volume", "backup", "inspect",
                volume1, backup, "--json",
            ],
            [
                "volume", "backup", "verify",
                volume1, backup,
                "--key-ref", "keychain://hostwright/backup",
                "--json",
            ],
            [
                "volume", "backup", "retain",
                volume1, backup, "--owner", "policy-a", "--json",
            ],
            [
                "volume", "backup", "restore", backup,
                "--key-ref", "keychain://hostwright/backup",
                "--target", "\(volume1)=\(volume2)",
                "--dry-run", "--json",
            ],
            [
                "volume", "backup", "delete",
                volume1, backup, "--confirm-plan",
                confirmation, "--json",
            ],
        ]

        for arguments in commands {
            guard case .volume = try CLICommand.parse(
                arguments: arguments
            ) else {
                return XCTFail(
                    "Expected volume command for \(arguments)."
                )
            }
        }
    }

    func testRemoteBackupDestinationHasStrictParityAcrossMutations() throws {
        let remote = [
            "--remote-s3-endpoint", "https://s3.example.test",
            "--remote-s3-bucket", "hostwright-backups",
            "--remote-s3-region", "us-test-1",
            "--remote-s3-prefix", "phase06/project-a",
            "--remote-s3-access-key-ref",
            "keychain://hostwright/s3-access",
            "--remote-s3-secret-key-ref",
            "keychain://hostwright/s3-secret",
        ]
        let commands = [
            [
                "volume", "backup", "create",
                "--volume", volume1,
                "--backup-id", backup,
                "--name", "nightly",
                "--key-ref", "keychain://hostwright/backup",
            ] + remote,
            [
                "volume", "backup", "verify",
                volume1, backup,
                "--key-ref", "keychain://hostwright/backup",
            ] + remote,
            [
                "volume", "backup", "retain",
                volume1, backup,
                "--owner", "policy-a",
            ] + remote,
            [
                "volume", "backup", "restore", backup,
                "--key-ref", "keychain://hostwright/backup",
                "--target", "\(volume1)=\(volume2)",
                "--dry-run",
            ] + remote,
            [
                "volume", "backup", "delete",
                volume1, backup, "--dry-run",
            ] + remote,
        ]

        for arguments in commands {
            let destination = try remoteDestination(
                arguments: arguments
            )
            XCTAssertEqual(
                destination.endpoint,
                "https://s3.example.test"
            )
            XCTAssertEqual(
                destination.objectPrefix,
                "phase06/project-a"
            )
            XCTAssertFalse(
                destination.redactedDescription.contains(
                    "s3-access"
                )
            )
            XCTAssertFalse(
                destination.redactedDescription.contains(
                    "s3-secret"
                )
            )
        }
    }

    func testRemoteBackupDestinationRejectsPartialOrUnsafeConfiguration() {
        let invalid = [
            [
                "volume", "backup", "create",
                "--volume", volume1,
                "--backup-id", backup,
                "--name", "nightly",
                "--key-ref", "keychain://hostwright/backup",
                "--remote-s3-endpoint", "https://s3.example.test",
            ],
            [
                "volume", "backup", "create",
                "--volume", volume1,
                "--backup-id", backup,
                "--name", "nightly",
                "--key-ref", "keychain://hostwright/backup",
                "--remote-s3-endpoint", "http://s3.example.test",
                "--remote-s3-bucket", "hostwright-backups",
                "--remote-s3-region", "us-test-1",
                "--remote-s3-access-key-ref",
                "keychain://hostwright/s3-access",
                "--remote-s3-secret-key-ref",
                "keychain://hostwright/s3-secret",
            ],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(
                try CLICommand.parse(arguments: arguments)
            )
        }
    }

    func testDestructiveOperationsRequireExactlyOnePlanMode() throws {
        guard case .volume(let dryRun) = try CLICommand.parse(
            arguments: [
                "volume", "delete", volume1, "--dry-run",
            ]
        ), case .delete(_, let dryRunConfirmation) =
            dryRun.action else {
            return XCTFail("Expected volume delete dry-run.")
        }
        XCTAssertTrue(dryRunConfirmation.dryRun)
        XCTAssertNil(
            dryRunConfirmation.confirmationPlanSHA256
        )

        guard case .volume(let confirmed) = try CLICommand.parse(
            arguments: [
                "volume", "prune",
                "--confirm-plan", confirmation,
            ]
        ), case .prune(let confirmedPlan) = confirmed.action else {
            return XCTFail("Expected confirmed volume prune.")
        }
        XCTAssertEqual(
            confirmedPlan.confirmationPlanSHA256,
            confirmation
        )
    }

    func testVolumeGrammarRejectsUnsafeAndAmbiguousInput() {
        let invalid: [[String]] = [
            ["volume"],
            ["volume", "inspect", "not-a-uuid"],
            ["volume", "capacity", "unexpected"],
            ["volume", "health", "--timeout", "901"],
            ["volume", "recover", volume1],
            ["volume", "delete", volume1],
            [
                "volume", "delete", volume1,
                "--dry-run", "--confirm-plan", confirmation,
            ],
            [
                "volume", "snapshot", "create", volume1,
                "--snapshot-id", snapshot,
            ],
            [
                "volume", "snapshot", "export",
                volume1, snapshot,
                "--output", "relative",
            ],
            [
                "volume", "snapshot", "restore", snapshot,
                "--source-volume", volume1,
                "--to-volume", volume2,
                "--reference-id", reference,
            ],
            [
                "volume", "backup", "create",
                "--volume", volume1,
                "--backup-id", backup,
                "--name", "nightly",
                "--key-ref", "plaintext",
            ],
            [
                "volume", "backup", "restore", backup,
                "--key-ref", "keychain://hostwright/backup",
                "--target", "\(volume1)=\(volume2)",
            ],
            [
                "volume", "backup", "restore", backup,
                "--key-ref", "keychain://hostwright/backup",
                "--target", "\(volume1)=\(volume2)",
                "--target", "\(volume1)=\(volume1)",
                "--dry-run",
            ],
            [
                "volume", "prune", "--confirm-plan",
                String(repeating: "A", count: 64),
            ],
        ]

        for arguments in invalid {
            XCTAssertThrowsError(
                try CLICommand.parse(arguments: arguments),
                "Expected rejection for \(arguments)."
            )
        }
    }

    func testReadOnlyVolumeCommandsUseTheSharedProviderContract() throws {
        let temporaryPath =
            FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath =
            temporaryPath.hasPrefix("/var/")
                ? "/private\(temporaryPath)"
                : temporaryPath
        let containerRoot = URL(
            fileURLWithPath: canonicalTemporaryPath,
            isDirectory: true
        )
            .appendingPathComponent(
                "hostwright-volume-cli-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: containerRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: containerRoot)
        }
        let root = containerRoot.appendingPathComponent(
            "provider",
            isDirectory: true
        )
        let provider = try LocalStorageProvider(
            rootURL: root,
            totalCapacityBytes: 16 * 1_024 * 1_024
        )
        let environment = CLIEnvironment(
            fileExists: { _ in false },
            readTextFile: { _ in "" },
            writeTextFile: { _, _ in },
            executablePath: { _ in nil },
            storageProvider: { provider },
            storageProviderRootURL: { root },
            swiftVersion: { nil },
            platformSnapshot: {
                PlatformSnapshot(
                    macOSMajorVersion: 26,
                    architecture: "arm64"
                )
            },
            operatingSystemDescription: { "test" }
        )

        for arguments in [
            ["volume", "list", "--json"],
            ["volume", "capacity", "--json"],
            ["volume", "health", "--json"],
        ] {
            let result = HostwrightCLI.run(
                arguments: arguments,
                environment: environment
            )
            XCTAssertEqual(result.exitCode, 0, result.standardError)
            XCTAssertTrue(result.standardError.isEmpty)
            XCTAssertTrue(result.standardOutput.hasPrefix("{"))
        }
    }

    func testCapacityStatusIncludesPersistedPressureAccounting()
        async throws
    {
        let harness = try await StorageDataProtectionCLIHarness.make(
            volumeID: volume1
        )
        defer { harness.cleanup() }

        let result = harness.run(["volume", "capacity"])
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(result.standardOutput.utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(object["pressureLevel"] as? String, "warning")
        let sample = try XCTUnwrap(
            object["latestSample"] as? [String: Any]
        )
        XCTAssertEqual(sample["requestedBytes"] as? Int, 2_097_152)
        XCTAssertEqual(sample["reclaimableBytes"] as? Int, 524_288)
        XCTAssertEqual(sample["requestedInodes"] as? Int, 200)
        XCTAssertEqual(sample["reclaimableInodes"] as? Int, 50)
    }


    func testSnapshotCommandsPersistProtectionStateAndEnforceHolds()
        async throws
    {
        let harness = try await StorageDataProtectionCLIHarness.make(
            volumeID: volume1
        )
        defer { harness.cleanup() }

        let created = harness.run([
            "volume", "snapshot", "create", volume1,
            "--snapshot-id", snapshot,
            "--name", "retained-snapshot",
        ])
        XCTAssertEqual(created.exitCode, 0, created.standardError)
        let record = try XCTUnwrap(
            try harness.state.loadSnapshots(
                sourceVolumeID: volume1
            ).first(where: { $0.id == snapshot })
        )
        XCTAssertEqual(record.lifecycleState, .ready)
        XCTAssertEqual(
            record.consistencyClass,
            .crashConsistent
        )
        XCTAssertEqual(
            record.parentContentTreeSHA256,
            record.contentTreeSHA256
        )
        XCTAssertEqual(
            record.lineage,
            ["volume:\(volume1)@1"]
        )

        for arguments in [
            ["volume", "snapshot", "list", volume1],
            [
                "volume", "snapshot", "inspect",
                volume1, snapshot,
            ],
        ] {
            let result = harness.run(arguments)
            XCTAssertEqual(result.exitCode, 0, result.standardError)
            XCTAssertTrue(result.standardOutput.contains(snapshot))
            XCTAssertTrue(
                result.standardOutput.contains(
                    record.parentContentTreeSHA256
                )
            )
            XCTAssertTrue(
                result.standardOutput.contains(
                    record.contentTreeSHA256
                )
            )
            XCTAssertTrue(
                result.standardOutput.contains(
                    "volume:\\/\(volume1)@1"
                ) ||
                    result.standardOutput.contains(
                        "volume:\(volume1)@1"
                    )
            )
        }

        let retained = harness.run([
            "volume", "snapshot", "retain",
            volume1, snapshot,
            "--owner", "policy-a",
        ])
        XCTAssertEqual(retained.exitCode, 0, retained.standardError)
        let retainedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(retained.standardOutput.utf8)
            ) as? [String: Any]
        )
        let retainedResult = try XCTUnwrap(
            retainedObject["result"] as? [String: Any]
        )
        XCTAssertEqual(
            retainedResult["consistencyClass"] as? String,
            StorageSnapshotConsistencyClass
                .crashConsistent.rawValue
        )
        XCTAssertEqual(
            retainedResult["parentContentTreeSHA256"]
                as? String,
            record.parentContentTreeSHA256
        )
        XCTAssertEqual(
            retainedResult["contentTreeSHA256"] as? String,
            record.contentTreeSHA256
        )
        XCTAssertEqual(
            retainedResult["lineage"] as? [String],
            record.lineage
        )
        XCTAssertEqual(
            try harness.activeHolds(
                kind: .snapshot,
                id: snapshot
            ).count,
            1
        )

        let exportPath = harness.root
            .appendingPathComponent(
                "snapshot-export",
                isDirectory: true
            ).path
        let exported = harness.run([
            "volume", "snapshot", "export",
            volume1, snapshot,
            "--output", exportPath,
        ])
        XCTAssertEqual(exported.exitCode, 0, exported.standardError)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: exportPath)
        )

        let retainedDelete = harness.run([
            "volume", "snapshot", "delete",
            volume1, snapshot, "--dry-run",
        ])
        XCTAssertNotEqual(retainedDelete.exitCode, 0)
        XCTAssertTrue(
            retainedDelete.standardError.contains(
                "active retention holds"
            )
        )

        let secondCreate = harness.run([
            "volume", "snapshot", "create", volume1,
            "--snapshot-id", deletableSnapshot,
            "--name", "deletable-snapshot",
        ])
        XCTAssertEqual(
            secondCreate.exitCode,
            0,
            secondCreate.standardError
        )
        let dryRun = harness.run([
            "volume", "snapshot", "delete",
            volume1, deletableSnapshot, "--dry-run",
        ])
        XCTAssertEqual(dryRun.exitCode, 0, dryRun.standardError)
        let plan = try planSHA256(from: dryRun.standardOutput)
        let deleted = harness.run([
            "volume", "snapshot", "delete",
            volume1, deletableSnapshot,
            "--confirm-plan", plan,
        ])
        XCTAssertEqual(deleted.exitCode, 0, deleted.standardError)
        XCTAssertEqual(
            try harness.state.loadSnapshots(
                sourceVolumeID: volume1
            ).first(where: { $0.id == deletableSnapshot })?
                .lifecycleState,
            .deleted
        )
        let deletedRecord = try XCTUnwrap(
            try harness.state.loadSnapshots(
                sourceVolumeID: volume1
            ).first(where: { $0.id == deletableSnapshot })
        )
        XCTAssertEqual(
            deletedRecord.consistencyClass,
            .crashConsistent
        )
        XCTAssertEqual(
            deletedRecord.parentContentTreeSHA256,
            deletedRecord.contentTreeSHA256
        )
        XCTAssertEqual(
            deletedRecord.lineage,
            ["volume:\(volume1)@1"]
        )
    }

    func testRejectedSnapshotExportReleasesProjectFence()
        async throws
    {
        let harness = try await StorageDataProtectionCLIHarness.make(
            volumeID: volume1
        )
        defer { harness.cleanup() }
        let created = harness.run([
            "volume", "snapshot", "create", volume1,
            "--snapshot-id", snapshot,
            "--name", "export-recovery",
        ])
        XCTAssertEqual(created.exitCode, 0, created.standardError)

        let unsafePath =
            "/private/tmp/hostwright-storage-export-\(UUID().uuidString)"
        let rejected = harness.run([
            "volume", "snapshot", "export",
            volume1, snapshot,
            "--output", unsafePath,
        ])
        XCTAssertNotEqual(rejected.exitCode, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: unsafePath)
        )

        let safePath = harness.root.appendingPathComponent(
            "safe-export",
            isDirectory: true
        ).path
        let retried = harness.run([
            "volume", "snapshot", "export",
            volume1, snapshot,
            "--output", safePath,
        ])
        XCTAssertEqual(retried.exitCode, 0, retried.standardError)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: safePath)
        )
    }

    func testBackupCommandsPersistProtectionStateAndEnforceHolds()
        async throws
    {
        let harness = try await StorageDataProtectionCLIHarness.make(
            volumeID: volume1
        )
        defer { harness.cleanup() }
        let keyReference = "keychain://hostwright/backup"

        let created = harness.run([
            "volume", "backup", "create",
            "--volume", volume1,
            "--backup-id", backup,
            "--name", "retained-backup",
            "--key-ref", keyReference,
        ])
        XCTAssertEqual(created.exitCode, 0, created.standardError)
        XCTAssertEqual(
            try harness.state.loadBackups(
                volumeID: volume1
            ).first(where: { $0.id == backup })?
                .lifecycleState,
            .ready
        )

        for arguments in [
            ["volume", "backup", "list", volume1],
            [
                "volume", "backup", "inspect",
                volume1, backup,
            ],
            [
                "volume", "backup", "verify",
                volume1, backup,
                "--key-ref", keyReference,
            ],
        ] {
            let result = harness.run(arguments)
            XCTAssertEqual(result.exitCode, 0, result.standardError)
            XCTAssertTrue(result.standardOutput.contains(backup))
        }

        let retained = harness.run([
            "volume", "backup", "retain",
            volume1, backup,
            "--owner", "policy-a",
        ])
        XCTAssertEqual(retained.exitCode, 0, retained.standardError)
        XCTAssertEqual(
            try harness.activeHolds(
                kind: .backup,
                id: backup
            ).count,
            1
        )
        let retainedDelete = harness.run([
            "volume", "backup", "delete",
            volume1, backup, "--dry-run",
        ])
        XCTAssertNotEqual(retainedDelete.exitCode, 0)
        XCTAssertTrue(
            retainedDelete.standardError.contains(
                "active retention holds"
            )
        )

        let secondCreate = harness.run([
            "volume", "backup", "create",
            "--volume", volume1,
            "--backup-id", deletableBackup,
            "--name", "deletable-backup",
            "--key-ref", keyReference,
        ])
        XCTAssertEqual(
            secondCreate.exitCode,
            0,
            secondCreate.standardError
        )
        let dryRun = harness.run([
            "volume", "backup", "delete",
            volume1, deletableBackup, "--dry-run",
        ])
        XCTAssertEqual(dryRun.exitCode, 0, dryRun.standardError)
        let plan = try planSHA256(from: dryRun.standardOutput)
        let deleted = harness.run([
            "volume", "backup", "delete",
            volume1, deletableBackup,
            "--confirm-plan", plan,
        ])
        XCTAssertEqual(deleted.exitCode, 0, deleted.standardError)
        XCTAssertEqual(
            try harness.state.loadBackups(
                volumeID: volume1
            ).first(where: { $0.id == deletableBackup })?
                .lifecycleState,
            .deleted
        )
    }

    func testMultiVolumeBackupRestoreUsesRecordedSourceSet()
        async throws
    {
        let harness = try await StorageDataProtectionCLIHarness.make(
            volumeIDs: [volume1, volume2, volume3, volume4]
        )
        defer { harness.cleanup() }
        let keyReference = "keychain://hostwright/backup"

        let created = harness.run([
            "volume", "backup", "create",
            "--volume", volume1,
            "--volume", volume2,
            "--backup-id", backup,
            "--name", "multi-volume",
            "--key-ref", keyReference,
        ])
        XCTAssertEqual(created.exitCode, 0, created.standardError)

        let dryRun = harness.run([
            "volume", "backup", "restore", backup,
            "--key-ref", keyReference,
            "--target", "\(volume1)=\(volume3)",
            "--target", "\(volume2)=\(volume4)",
            "--dry-run",
        ])
        XCTAssertEqual(dryRun.exitCode, 0, dryRun.standardError)
        let plan = try planSHA256(from: dryRun.standardOutput)
        let restored = harness.run([
            "volume", "backup", "restore", backup,
            "--key-ref", keyReference,
            "--target", "\(volume1)=\(volume3)",
            "--target", "\(volume2)=\(volume4)",
            "--confirm-plan", plan,
        ])
        XCTAssertEqual(restored.exitCode, 0, restored.standardError)
    }

    private func planSHA256(from output: String) throws -> String {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(output.utf8)
            ) as? [String: Any]
        )
        return try XCTUnwrap(object["planSHA256"] as? String)
    }

    private func remoteDestination(
        arguments: [String]
    ) throws -> StorageBackupRemoteDestination {
        guard case .volume(let options) =
                try CLICommand.parse(arguments: arguments),
              case .backup(let action) = options.action else {
            throw NSError(domain: "test", code: 1)
        }
        let destination: StorageBackupRemoteDestination?
        switch action {
        case .create(_, _, _, _, let value):
            destination = value
        case .verify(_, _, _, let value):
            destination = value
        case .retain(_, _, _, let value):
            destination = value
        case .restore(_, _, _, let value, _):
            destination = value
        case .delete(_, _, let value, _):
            destination = value
        case .list, .inspect:
            destination = nil
        }
        guard let destination else {
            throw NSError(domain: "test", code: 2)
        }
        return destination
    }
}

private final class StorageDataProtectionCLIHarness {
    let root: URL
    let state: StorageStateRepository

    private let stateDatabasePath: String
    private let environment: CLIEnvironment

    private init(
        root: URL,
        stateDatabasePath: String,
        environment: CLIEnvironment,
        state: StorageStateRepository
    ) {
        self.root = root
        self.stateDatabasePath = stateDatabasePath
        self.environment = environment
        self.state = state
    }

    static func make(
        volumeID: String
    ) async throws -> StorageDataProtectionCLIHarness {
        try await make(volumeIDs: [volumeID])
    }

    static func make(
        volumeIDs: [String]
    ) async throws -> StorageDataProtectionCLIHarness {
        guard !volumeIDs.isEmpty,
              Set(volumeIDs).count == volumeIDs.count else {
            throw StateStoreError.invalidRecord(
                "Storage CLI harness requires unique volumes."
            )
        }
        let rawTemporaryPath =
            FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath =
            rawTemporaryPath.hasPrefix("/var/")
                ? "/private\(rawTemporaryPath)"
                : rawTemporaryPath
        let root = URL(
            fileURLWithPath: canonicalTemporaryPath,
            isDirectory: true
        ).appendingPathComponent(
            "hostwright-storage-cli-protection-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let providerRoot = root.appendingPathComponent(
                "provider",
                isDirectory: true
            )
            let provider = try LocalStorageProvider(
                rootURL: providerRoot,
                totalCapacityBytes: 16 * 1_024 * 1_024,
                backupKeyResolver:
                    StorageDataProtectionCLIKeyResolver()
            )
            let projectUUID = UUID(
                uuidString:
                    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            )!
            let client = try StorageProviderClient(
                provider: provider
            )

            let databasePath = root
                .appendingPathComponent("state.sqlite").path
            let resolution = try HostwrightLocalPathResolver
                .resolve(
                    explicitStateDatabasePath: databasePath,
                    homeDirectory: root.path,
                    environment: [:]
                )
            let store = SQLiteStateStore(
                configuration: StateStoreConfiguration(
                    localPathResolution: resolution
                )
            )
            try store.migrate()
            let state = StorageStateRepository(store: store)
            for (index, volumeID) in volumeIDs.sorted().enumerated() {
                let fence = HostwrightResourceUUID.legacy(
                    kind: "storage-cli-test-volume-fence",
                    identifier: volumeID
                )
                let context = StorageProviderMutationContext(
                    projectUUID: projectUUID,
                    projectGeneration: 1,
                    resourceUUID: UUID(uuidString: volumeID)!,
                    resourceGeneration: 1,
                    fencingToken: UUID(uuidString: fence)!
                )
                let result: LocalStorageMutationResult =
                    try await client.invoke(
                        operation: .create,
                        mutationContext: context,
                        idempotencyKey:
                            "cli-protection-volume-create-\(volumeID)",
                        payload: LocalStorageCreatePayload(
                            name: "protected-volume-\(index)",
                            capacityBytes: 2 * 1_024 * 1_024
                        ),
                        result: LocalStorageMutationResult.self
                    )
                let volume = try XCTUnwrap(result.volume)
                let dataPath = try XCTUnwrap(volume.dataPath)
                try Data(
                    "authoritative data \(volumeID)".utf8
                ).write(
                    to: URL(fileURLWithPath: dataPath)
                        .appendingPathComponent("payload.txt")
                )
                try seedVolume(
                    volume,
                    store: store,
                    state: state
                )
            }
            let environment = CLIEnvironment(
                fileExists: {
                    FileManager.default.fileExists(atPath: $0)
                },
                readTextFile: { _ in "" },
                writeTextFile: { _, _ in },
                executablePath: { _ in nil },
                localPathResolution: { _ in resolution },
                storageProvider: { provider },
                storageProviderRootURL: { providerRoot },
                swiftVersion: { nil },
                platformSnapshot: {
                    PlatformSnapshot(
                        macOSMajorVersion: 26,
                        architecture: "arm64"
                    )
                },
                operatingSystemDescription: { "test" }
            )
            return StorageDataProtectionCLIHarness(
                root: root,
                stateDatabasePath: databasePath,
                environment: environment,
                state: state
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func run(_ arguments: [String]) -> CLIRunResult {
        HostwrightCLI.run(
            arguments: arguments + [
                "--state-db", stateDatabasePath,
                "--json",
            ],
            environment: environment
        )
    }

    func activeHolds(
        kind: StorageHoldResourceKind,
        id: String
    ) throws -> [StorageStateHoldRecord] {
        try state.activeHolds(
            resourceKind: kind,
            resourceID: id,
            at: "2026-07-25T12:00:00Z"
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func seedVolume(
        _ volume: LocalStorageVolumeObservation,
        store: SQLiteStateStore,
        state: StorageStateRepository
    ) throws {
        let operationID = HostwrightResourceUUID.legacy(
            kind: "storage-cli-test-volume-operation",
            identifier: volume.volumeID
        )
        let operation = OperationGroupRecord(
            id: operationID,
            operationID: operationID,
            groupKind: "storage-volume-create",
            projectID: volume.projectID,
            serviceName: nil,
            plannedActionType: "storage-volume-create",
            status: .active,
            groupIdempotencyKey:
                "storage-volume-create:\(volume.volumeID)",
            planHash: String(repeating: "c", count: 64),
            checkpoint: "provider-verified",
            lockOwner: "storage-cli-test",
            lockExpiresAt: "2030-07-25T12:00:00Z",
            rollbackAvailable: false,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-25T12:00:00Z",
            updatedAt: "2026-07-25T12:00:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: volume.fencingToken
        )
        guard try store.operationGroups.acquire(
            operation,
            currentTimestamp: "2026-07-25T12:00:00Z"
        ).acquired != nil else {
            throw StateStoreError.invalidRecord(
                "Failed to seed storage volume authority."
            )
        }
        try state.saveVolume(
            StorageStateVolumeRecord(
                id: volume.volumeID,
                projectID: volume.projectID,
                name: volume.name,
                providerID: volume.providerID,
                providerVolumeID: volume.volumeID,
                topologyNodeID: "test-node",
                generation: Int64(volume.generation),
                fencingToken: volume.fencingToken,
                capacityBytes: volume.capacityBytes,
                lifecycleState: .available,
                reclaimPolicy: .retain,
                accessMode: .readWriteOnce,
                operationGroupID: operation.id,
                createdAt: "2026-07-25T12:00:00Z",
                updatedAt: "2026-07-25T12:00:00Z"
            )
        )
        let sample = try StorageCapacitySample(
            id: HostwrightResourceUUID.legacy(
                kind: "storage-cli-test-capacity-sample",
                identifier: volume.volumeID
            ),
            providerID: LocalStorageProviderContract.providerID,
            topologyNodeID: "local-apple-silicon",
            source: .reconciledState,
            requestedBytes: 2_097_152,
            reservedBytes: 2_097_152,
            usedBytes: 1_048_576,
            reclaimableBytes: 524_288,
            availableBytes: 14_680_064,
            totalBytes: 16_777_216,
            requestedInodes: 200,
            reservedInodes: 200,
            usedInodes: 100,
            reclaimableInodes: 50,
            availableInodes: 900,
            totalInodes: 1_000,
            quotaCapability: try StorageQuotaCapability(
                mode: .logical
            ),
            capturedAtUnixMilliseconds: 1_800_000_000_000,
            validUntilUnixMilliseconds: 1_800_000_060_000
        )
        try state.saveCapacitySample(
            StorageStateCapacitySampleRecord(
                sample: sample,
                pressureLevel: .warning,
                fencingToken: volume.fencingToken,
                operationGroupID: operation.id,
                createdAt: "2026-07-25T12:00:00Z"
            )
        )
        try store.operationGroups.finish(
            groupID: operation.id,
            status: .succeeded,
            checkpoint: "volume-ready",
            manualRecoveryHintRedacted: "",
            updatedAt: "2026-07-25T12:00:01Z",
            metadataJSONRedacted: "{}"
        )
    }

}

private struct StorageDataProtectionCLIKeyResolver:
    StorageBackupKeyResolver
{
    func resolveKey(
        reference: HostwrightSecretReference
    ) throws -> SymmetricKey {
        SymmetricKey(
            data: Data(
                SHA256.hash(
                    data: Data("cli-protection-key".utf8)
                )
            )
        )
    }
}
