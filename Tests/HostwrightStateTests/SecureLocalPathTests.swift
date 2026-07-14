import Darwin
import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightState

final class SecureLocalPathTests: XCTestCase {
    func testDefaultStateCreatesPrivateMacOSLayoutAndDatabase() throws {
        try withTemporaryHome { home in
            let resolution = try HostwrightLocalPathResolver.resolve(
                homeDirectory: home.path,
                environment: [:]
            )
            let store = SQLiteStateStore(
                configuration: StateStoreConfiguration(localPathResolution: resolution)
            )

            try store.migrate()

            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
            for directory in resolution.layout.ownedDirectories {
                XCTAssertEqual(try permissions(directory), 0o700, directory)
            }
            XCTAssertEqual(try permissions(resolution.stateDatabasePath), 0o600)
            XCTAssertEqual(store.configuration.origin, .applicationSupportDefault)
        }
    }

    func testPrivateCreationIsIndependentOfARestrictiveUmask() throws {
        try withTemporaryHome { home in
            let previousMask = umask(0o777)
            defer { _ = umask(previousMask) }
            let resolution = try HostwrightLocalPathResolver.resolve(
                homeDirectory: home.path,
                environment: [:]
            )
            let store = SQLiteStateStore(
                configuration: StateStoreConfiguration(localPathResolution: resolution)
            )

            try store.migrate()

            for directory in resolution.layout.ownedDirectories {
                XCTAssertEqual(try permissions(directory), 0o700, directory)
            }
            XCTAssertEqual(try permissions(resolution.stateDatabasePath), 0o600)
        }
    }

    func testLegacyStateMigratesAtomicallyAndPreservesUnknownLegacyFiles() throws {
        try withTemporaryHome { home in
            let resolution = try HostwrightLocalPathResolver.resolve(homeDirectory: home.path, environment: [:])
            let legacyRoot = URL(fileURLWithPath: resolution.legacyRootDirectory, isDirectory: true)
            try createPrivateDirectory(legacyRoot)
            let legacyStore = SQLiteStateStore(path: resolution.legacyStateDatabase)
            try legacyStore.migrate()
            try legacyStore.events.append([
                EventRecord(
                    id: "legacy-event",
                    timestamp: "2026-07-13T00:00:00Z",
                    severity: .info,
                    type: "legacy.proof",
                    source: "test",
                    projectID: nil,
                    serviceName: nil,
                    runtimeAdapter: nil,
                    message: "preserved",
                    payloadJSONRedacted: "{}"
                )
            ])
            let unrelated = legacyRoot.appendingPathComponent("user-notes.txt")
            try Data("keep me".utf8).write(to: unrelated)

            let migrated = SQLiteStateStore(
                configuration: StateStoreConfiguration(localPathResolution: resolution)
            )
            try migrated.migrate()

            XCTAssertFalse(FileManager.default.fileExists(atPath: resolution.legacyStateDatabase))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
            XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep me")
            XCTAssertEqual(try migrated.events.loadAll().map(\.id), ["legacy-event"])
            XCTAssertEqual(try permissions(resolution.stateDatabasePath), 0o600)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: URL(fileURLWithPath: resolution.layout.metadataDirectory)
                        .appendingPathComponent("legacy-state-migration.json").path
                )
            )
        }
    }

    func testMigrationJournalResumesAfterAtomicRenameCheckpoint() throws {
        try withTemporaryHome { home in
            let resolution = try HostwrightLocalPathResolver.resolve(homeDirectory: home.path, environment: [:])
            let legacyRoot = URL(fileURLWithPath: resolution.legacyRootDirectory, isDirectory: true)
            try createPrivateDirectory(legacyRoot)
            let legacyStore = SQLiteStateStore(path: resolution.legacyStateDatabase)
            try legacyStore.migrate()

            for directory in resolution.layout.ownedDirectories {
                try createPrivateDirectory(URL(fileURLWithPath: directory, isDirectory: true))
            }
            var identity = stat()
            XCTAssertEqual(lstat(resolution.legacyStateDatabase, &identity), 0)
            XCTAssertEqual(rename(resolution.legacyStateDatabase, resolution.stateDatabasePath), 0)

            let journal = URL(fileURLWithPath: resolution.layout.metadataDirectory, isDirectory: true)
                .appendingPathComponent("legacy-state-migration.json")
            let record: [String: Any] = [
                "schemaVersion": 1,
                "source": resolution.legacyStateDatabase,
                "destination": resolution.stateDatabasePath,
                "sourceDevice": UInt64(identity.st_dev),
                "sourceInode": UInt64(identity.st_ino)
            ]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try data.write(to: journal)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)

            let resumed = SQLiteStateStore(
                configuration: StateStoreConfiguration(localPathResolution: resolution)
            )
            try resumed.migrate()

            XCTAssertEqual(try resumed.schemaVersion(), MigrationRunner.latestSchemaVersion)
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
            XCTAssertEqual(try permissions(resolution.stateDatabasePath), 0o600)
        }
    }

    func testLegacyMigrationRefusesAnActiveWriterAndResumesAfterRelease() throws {
        try withTemporaryHome { home in
            let resolution = try HostwrightLocalPathResolver.resolve(homeDirectory: home.path, environment: [:])
            try createPrivateDirectory(URL(fileURLWithPath: resolution.legacyRootDirectory, isDirectory: true))
            let legacyStore = SQLiteStateStore(path: resolution.legacyStateDatabase)
            try legacyStore.migrate()

            let writer = try SQLiteConnection(path: resolution.legacyStateDatabase, createIfNeeded: false)
            try writer.execute("BEGIN IMMEDIATE TRANSACTION")
            let target = SQLiteStateStore(
                configuration: StateStoreConfiguration(localPathResolution: resolution)
            )

            XCTAssertThrowsError(try target.migrate()) { error in
                XCTAssertTrue(String(describing: error).contains("exclusive SQLite migration lock"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolution.legacyStateDatabase))
            XCTAssertFalse(FileManager.default.fileExists(atPath: resolution.stateDatabasePath))

            try writer.execute("ROLLBACK")
            try writer.close()
            try target.migrate()

            XCTAssertFalse(FileManager.default.fileExists(atPath: resolution.legacyStateDatabase))
            XCTAssertEqual(try target.schemaVersion(), MigrationRunner.latestSchemaVersion)
        }
    }

    func testLegacyConflictAndSidecarsFailWithoutChangingEitherDatabase() throws {
        try withTemporaryHome { home in
            let resolution = try HostwrightLocalPathResolver.resolve(homeDirectory: home.path, environment: [:])
            let legacyRoot = URL(fileURLWithPath: resolution.legacyRootDirectory, isDirectory: true)
            try createPrivateDirectory(legacyRoot)
            let legacyStore = SQLiteStateStore(path: resolution.legacyStateDatabase)
            try legacyStore.migrate()

            let target = SQLiteStateStore(
                configuration: StateStoreConfiguration(localPathResolution: resolution)
            )
            for directory in resolution.layout.ownedDirectories {
                try createPrivateDirectory(URL(fileURLWithPath: directory, isDirectory: true))
            }
            let descriptor = open(
                resolution.stateDatabasePath,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            close(descriptor)

            XCTAssertThrowsError(try target.migrate()) { error in
                guard case .legacyPathMigrationFailed = error as? StateStoreError else {
                    return XCTFail("Expected legacyPathMigrationFailed, received \(error)")
                }
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolution.legacyStateDatabase))
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolution.stateDatabasePath))
        }

        try withTemporaryHome { home in
            let resolution = try HostwrightLocalPathResolver.resolve(homeDirectory: home.path, environment: [:])
            try createPrivateDirectory(URL(fileURLWithPath: resolution.legacyRootDirectory, isDirectory: true))
            try SQLiteStateStore(path: resolution.legacyStateDatabase).migrate()
            let sidecar = resolution.legacyStateDatabase + "-wal"
            let descriptor = open(sidecar, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            close(descriptor)

            let target = SQLiteStateStore(
                configuration: StateStoreConfiguration(localPathResolution: resolution)
            )
            XCTAssertThrowsError(try target.migrate()) { error in
                XCTAssertTrue(String(describing: error).contains("sidecar"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolution.legacyStateDatabase))
            XCTAssertFalse(FileManager.default.fileExists(atPath: resolution.stateDatabasePath))
        }
    }

    func testLegacyMigrationRejectsAnInvalidHostwrightLedgerBeforeMove() throws {
        try withTemporaryHome { home in
            let resolution = try HostwrightLocalPathResolver.resolve(homeDirectory: home.path, environment: [:])
            try createPrivateDirectory(URL(fileURLWithPath: resolution.legacyRootDirectory, isDirectory: true))
            let connection = try SQLiteConnection(path: resolution.legacyStateDatabase)
            try connection.execute(
                """
                CREATE TABLE schema_migrations (
                    version INTEGER PRIMARY KEY,
                    description TEXT NOT NULL,
                    checksum TEXT NOT NULL,
                    applied_at TEXT NOT NULL
                )
                """
            )
            try connection.execute(
                "INSERT INTO schema_migrations VALUES (1, 'tampered', 'invalid', '2026-07-13T00:00:00Z')"
            )
            try connection.close()

            let target = SQLiteStateStore(
                configuration: StateStoreConfiguration(localPathResolution: resolution)
            )
            XCTAssertThrowsError(try target.migrate()) { error in
                XCTAssertTrue(String(describing: error).contains("valid compatible Hostwright migration ledger"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolution.legacyStateDatabase))
            XCTAssertFalse(FileManager.default.fileExists(atPath: resolution.stateDatabasePath))
        }
    }

    func testLegacyMigrationRejectsEmptyLedgerAndSpecialPermissionBitsBeforeMove() throws {
        try withTemporaryHome { home in
            let resolution = try HostwrightLocalPathResolver.resolve(
                homeDirectory: home.path,
                environment: [:]
            )
            try createPrivateDirectory(
                URL(fileURLWithPath: resolution.legacyRootDirectory, isDirectory: true)
            )
            let connection = try SQLiteConnection(path: resolution.legacyStateDatabase)
            try connection.execute(
                """
                CREATE TABLE schema_migrations (
                    version INTEGER PRIMARY KEY,
                    description TEXT NOT NULL,
                    checksum TEXT NOT NULL,
                    applied_at TEXT NOT NULL
                )
                """
            )
            try connection.close()

            let target = SQLiteStateStore(
                configuration: StateStoreConfiguration(localPathResolution: resolution)
            )
            XCTAssertThrowsError(try target.migrate()) { error in
                XCTAssertTrue(String(describing: error).contains("contains no applied migration"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolution.legacyStateDatabase))
            XCTAssertFalse(FileManager.default.fileExists(atPath: resolution.stateDatabasePath))
        }

        try withTemporaryHome { home in
            let resolution = try HostwrightLocalPathResolver.resolve(
                homeDirectory: home.path,
                environment: [:]
            )
            try createPrivateDirectory(
                URL(fileURLWithPath: resolution.legacyRootDirectory, isDirectory: true)
            )
            try SQLiteStateStore(path: resolution.legacyStateDatabase).migrate()
            XCTAssertEqual(
                chmod(resolution.legacyStateDatabase, S_IRUSR | S_IWUSR | S_ISUID),
                0
            )

            let target = SQLiteStateStore(
                configuration: StateStoreConfiguration(localPathResolution: resolution)
            )
            XCTAssertThrowsError(try target.migrate()) { error in
                XCTAssertTrue(String(describing: error).contains("special permission bits"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolution.legacyStateDatabase))
            XCTAssertFalse(FileManager.default.fileExists(atPath: resolution.stateDatabasePath))
        }
    }

    func testMigrationResumeRefusesSidecarCreatedAfterIntentThenCompletesSafely() throws {
        try withTemporaryHome { home in
            let resolution = try HostwrightLocalPathResolver.resolve(
                homeDirectory: home.path,
                environment: [:]
            )
            try createPrivateDirectory(
                URL(fileURLWithPath: resolution.legacyRootDirectory, isDirectory: true)
            )
            try SQLiteStateStore(path: resolution.legacyStateDatabase).migrate()
            for directory in resolution.layout.ownedDirectories {
                try createPrivateDirectory(URL(fileURLWithPath: directory, isDirectory: true))
            }

            var identity = stat()
            XCTAssertEqual(lstat(resolution.legacyStateDatabase, &identity), 0)
            try writeMigrationJournal(resolution: resolution, identity: identity)
            let sidecar = resolution.legacyStateDatabase + "-wal"
            let descriptor = open(
                sidecar,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            close(descriptor)

            let target = SQLiteStateStore(
                configuration: StateStoreConfiguration(localPathResolution: resolution)
            )
            XCTAssertThrowsError(try target.migrate()) { error in
                XCTAssertTrue(String(describing: error).contains("sidecar"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolution.legacyStateDatabase))
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: resolution.legacyStateMigrationJournal)
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: resolution.stateDatabasePath))

            try FileManager.default.removeItem(atPath: sidecar)
            try target.migrate()

            XCTAssertFalse(FileManager.default.fileExists(atPath: resolution.legacyStateDatabase))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: resolution.legacyStateMigrationJournal)
            )
            XCTAssertEqual(try target.schemaVersion(), MigrationRunner.latestSchemaVersion)
        }
    }

    func testProspectiveValidationRejectsUnsafeMissingTargetsAndAcceptsResumableRename() throws {
        try withTemporaryHome { home in
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
            XCTAssertThrowsError(
                try StateStoreConfiguration(localPathResolution: resolution)
                    .validateProspectivePath()
            ) { error in
                XCTAssertTrue(String(describing: error).contains("0700"))
            }

            let explicit = StateStoreConfiguration(
                explicitDatabasePath: home
                    .appendingPathComponent("missing/state.sqlite")
                    .path
            )
            XCTAssertThrowsError(try explicit.validateProspectivePath())
            XCTAssertFalse(FileManager.default.fileExists(atPath: explicit.databasePath))
        }

        try withTemporaryHome { home in
            let resolution = try HostwrightLocalPathResolver.resolve(
                homeDirectory: home.path,
                environment: [:]
            )
            try createPrivateDirectory(
                URL(fileURLWithPath: resolution.legacyRootDirectory, isDirectory: true)
            )
            try SQLiteStateStore(path: resolution.legacyStateDatabase).migrate()
            for directory in resolution.layout.ownedDirectories {
                try createPrivateDirectory(URL(fileURLWithPath: directory, isDirectory: true))
            }
            var identity = stat()
            XCTAssertEqual(lstat(resolution.legacyStateDatabase, &identity), 0)
            XCTAssertEqual(
                rename(resolution.legacyStateDatabase, resolution.stateDatabasePath),
                0
            )
            XCTAssertEqual(chmod(resolution.stateDatabasePath, 0o644), 0)
            try writeMigrationJournal(resolution: resolution, identity: identity)

            let configuration = StateStoreConfiguration(localPathResolution: resolution)
            XCTAssertNoThrow(try configuration.validateProspectivePath())
            try SQLiteStateStore(configuration: configuration).migrate()

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: resolution.legacyStateMigrationJournal)
            )
            XCTAssertEqual(try permissions(resolution.stateDatabasePath), 0o600)
        }
    }

    func testUnsafeExplicitParentsSymlinksModesAndOwnersFailBeforeSQLiteUse() throws {
        try withTemporaryHome { home in
            let writable = home.appendingPathComponent("writable", isDirectory: true)
            try FileManager.default.createDirectory(at: writable, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: writable.path)
            XCTAssertThrowsError(try SQLiteStateStore(path: writable.appendingPathComponent("state.sqlite").path).migrate())

            let target = home.appendingPathComponent("target", isDirectory: true)
            try createPrivateDirectory(target)
            let symlink = home.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
            XCTAssertThrowsError(try SQLiteStateStore(path: symlink.appendingPathComponent("state.sqlite").path).migrate())

            let modeFile = home.appendingPathComponent("unsafe-mode.sqlite")
            try Data().write(to: modeFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: modeFile.path)
            XCTAssertThrowsError(try SQLiteStateStore(path: modeFile.path).migrate()) { error in
                XCTAssertTrue(String(describing: error).contains("0600"))
            }

            let configuration = StateStoreConfiguration(
                explicitDatabasePath: home.appendingPathComponent("wrong-owner.sqlite").path
            )
            XCTAssertThrowsError(
                try SecureStatePathManager(effectiveUserID: geteuid() + 1)
                    .prepare(configuration: configuration, createIfNeeded: true)
            ) { error in
                XCTAssertTrue(String(describing: error).contains("owner UID"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.databasePath))
        }
    }

    func testAccessGrantingStateACLIsRejectedBeforeSQLiteUse() throws {
        try withTemporaryHome { home in
            let database = home.appendingPathComponent("state.sqlite")
            let store = SQLiteStateStore(path: database.path)
            try store.migrate()
            try setEveryoneReadACL(on: database.path)

            XCTAssertThrowsError(try store.schemaVersion()) { error in
                XCTAssertTrue(String(describing: error).contains("access-granting"))
            }
        }
    }

    private func withTemporaryHome(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-local-paths-\(UUID().uuidString)", isDirectory: true)
        try createPrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeMigrationJournal(
        resolution: HostwrightLocalPathResolution,
        identity: stat
    ) throws {
        let record: [String: Any] = [
            "schemaVersion": 1,
            "source": resolution.legacyStateDatabase,
            "destination": resolution.stateDatabasePath,
            "sourceDevice": UInt64(identity.st_dev),
            "sourceInode": UInt64(identity.st_ino)
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: resolution.legacyStateMigrationJournal))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: resolution.legacyStateMigrationJournal
        )
    }

    private func setEveryoneReadACL(on path: String) throws {
        let text = """
        !#acl 1
        group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:read

        """
        guard let accessControlList = acl_from_text(text) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
        guard acl_set_file(path, ACL_TYPE_EXTENDED, accessControlList) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func permissions(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
