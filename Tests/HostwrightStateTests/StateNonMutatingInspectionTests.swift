import Darwin
import Foundation
import XCTest
@testable import HostwrightState

final class StateNonMutatingInspectionTests: XCTestCase {
    func testIntegrityInspectionCreatesNoCoordinationOrSQLiteArtifacts() throws {
        try withTemporaryStore { store, directory in
            try store.migrate()
            let paths = try store.configuration.maintenancePaths()
            for path in [paths.accessLockPath, paths.accessLockPath + ".writer"] {
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
            }
            let before = try directorySnapshot(directory)

            let report = try StateIntegrityService(store: store).inspectNonMutating()

            XCTAssertEqual(report.health, .healthy)
            XCTAssertEqual(try directorySnapshot(directory), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.accessLockPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.accessLockPath + ".writer"))
        }
    }

    func testIntegrityInspectionUsesExistingFenceWithoutChangingIt() throws {
        try withTemporaryStore { store, directory in
            try store.migrate()
            let paths = try store.configuration.maintenancePaths()
            let before = try fileIdentity(paths.accessLockPath)
            let directoryBefore = try directorySnapshot(directory)

            let report = try StateIntegrityService(store: store).inspectNonMutating()

            XCTAssertEqual(report.health, .healthy)
            XCTAssertEqual(try fileIdentity(paths.accessLockPath), before)
            XCTAssertEqual(try directorySnapshot(directory), directoryBefore)
        }
    }

    func testIntegrityInspectionRefusesActiveWALWithoutChangingIt() throws {
        try withTemporaryStore { store, directory in
            try store.migrate()
            let writer = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                profile: .authoritativeState
            )
            defer { try? writer.close() }
            try writer.execute(
                "CREATE TABLE doctor_wal_probe (id INTEGER PRIMARY KEY, value TEXT NOT NULL)"
            )
            try writer.execute("BEGIN IMMEDIATE TRANSACTION")
            try writer.run(
                "INSERT INTO doctor_wal_probe (id, value) VALUES (1, 'uncommitted')"
            )
            let before = try directorySnapshot(directory)

            XCTAssertThrowsError(
                try StateIntegrityService(store: store).inspectNonMutating()
            ) { error in
                guard case StateStoreError.databaseLocked(_, let message) = error else {
                    return XCTFail("Expected databaseLocked, got \(error).")
                }
                XCTAssertTrue(message.contains("nonempty WAL"))
            }
            XCTAssertEqual(try directorySnapshot(directory), before)
        }
    }

    func testIntegrityInspectionRefusesExistingExclusiveFenceWithoutChangingIt() throws {
        try withTemporaryStore { store, directory in
            try store.migrate()
            let paths = try store.configuration.maintenancePaths()
            let descriptor = open(paths.accessLockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
            }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            let before = try directorySnapshot(directory)

            XCTAssertThrowsError(
                try StateIntegrityService(store: store).inspectNonMutating()
            ) { error in
                guard case StateStoreError.databaseLocked(_, let message) = error else {
                    return XCTFail("Expected databaseLocked, got \(error).")
                }
                XCTAssertTrue(message.contains("state-access fence"))
            }
            XCTAssertEqual(try directorySnapshot(directory), before)
        }
    }

    private func withTemporaryStore(
        _ body: (SQLiteStateStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-state-doctor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(
            SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path),
            directory
        )
    }

    private func directorySnapshot(_ directory: URL) throws -> [String: FileSnapshot] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        return try Dictionary(uniqueKeysWithValues: names.map { name in
            let path = directory.appendingPathComponent(name).path
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            return (
                name,
                FileSnapshot(
                    bytes: data,
                    permissions: metadata.st_mode & 0o7777,
                    device: metadata.st_dev,
                    inode: metadata.st_ino
                )
            )
        })
    }

    private func fileIdentity(_ path: String) throws -> FileIdentity {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private struct FileSnapshot: Equatable {
        let bytes: Data
        let permissions: mode_t
        let device: dev_t
        let inode: ino_t
    }
}
