import Darwin
import Foundation
import HostwrightCore

struct SecureStatePathManager {
    private let effectiveUserID: uid_t

    init(effectiveUserID: uid_t = geteuid()) {
        self.effectiveUserID = effectiveUserID
    }

    func prepare(configuration: StateStoreConfiguration, createIfNeeded: Bool) throws {
        if let resolution = configuration.localPathResolution,
           resolution.usesApplicationSupportState {
            if createIfNeeded {
                try validateProspective(configuration: configuration)
                try prepareDefaultLayout(resolution.layout)
                try migrateLegacyStateIfNeeded(resolution)
            } else {
                try validateDefaultLayoutForRead(resolution)
            }
        }

        let parent = (configuration.databasePath as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != configuration.databasePath else {
            throw StateStoreError.pathPolicyViolation(
                path: configuration.databasePath,
                message: "a database filename beneath a secure parent directory is required"
            )
        }
        try validateDirectoryChain(parent)
        try prepareDatabaseFile(configuration.databasePath, createIfNeeded: createIfNeeded)
    }

    func prepareRuntimeSupport(_ layout: HostwrightLocalPathLayout) throws {
        let applicationSupportParent = (layout.applicationSupportDirectory as NSString).deletingLastPathComponent
        try ensureDirectory(applicationSupportParent, privateLeaf: false)
        try ensureDirectory(layout.applicationSupportDirectory, privateLeaf: true)
        try ensureDirectory(layout.runtimeDirectory, privateLeaf: true)
    }

    func validateProspective(configuration: StateStoreConfiguration) throws {
        let hasPendingMigrationJournal: Bool
        if let resolution = configuration.localPathResolution,
           resolution.usesApplicationSupportState {
            hasPendingMigrationJournal = pathExists(resolution.legacyStateMigrationJournal)
            try validateDefaultLayoutProspective(resolution.layout)
            try validateLegacyMigrationReadiness(resolution)
        } else {
            hasPendingMigrationJournal = false
            try validateDirectoryChain(databaseParent(configuration.databasePath))
        }

        if pathExists(configuration.databasePath), !hasPendingMigrationJournal {
            _ = try validateRegularFile(configuration.databasePath, requirePrivateMode: true)
        }
    }

    private func prepareDefaultLayout(_ layout: HostwrightLocalPathLayout) throws {
        let applicationSupportParent = (layout.applicationSupportDirectory as NSString).deletingLastPathComponent
        let cacheParent = (layout.cacheDirectory as NSString).deletingLastPathComponent
        let logParent = (layout.logDirectory as NSString).deletingLastPathComponent

        try ensureDirectory(applicationSupportParent, privateLeaf: false)
        try ensureDirectory(layout.applicationSupportDirectory, privateLeaf: true)
        for directory in [
            layout.configurationDirectory,
            layout.stateDirectory,
            layout.runtimeDirectory,
            layout.metadataDirectory,
            layout.backupsDirectory
        ] {
            try ensureDirectory(directory, privateLeaf: true)
        }
        try ensureDirectory(cacheParent, privateLeaf: false)
        try ensureDirectory(layout.cacheDirectory, privateLeaf: true)
        try ensureDirectory(logParent, privateLeaf: false)
        try ensureDirectory(layout.logDirectory, privateLeaf: true)
    }

    private func validateDefaultLayoutForRead(_ resolution: HostwrightLocalPathResolution) throws {
        if pathExists(resolution.stateDatabasePath) {
            try validateDirectoryChain((resolution.stateDatabasePath as NSString).deletingLastPathComponent)
            return
        }
        if pathExists(resolution.legacyStateDatabase) {
            throw StateStoreError.legacyPathMigrationFailed(
                source: resolution.legacyStateDatabase,
                destination: resolution.stateDatabasePath,
                message: "a state-writing command must complete the journaled migration before this read-only operation"
            )
        }
    }

    private func validateDefaultLayoutProspective(_ layout: HostwrightLocalPathLayout) throws {
        let ownedDirectories = Set(layout.ownedDirectories)
        for directory in ownedDirectories.sorted() {
            try validateExistingDirectoryPrefix(
                directory,
                ownedDirectories: ownedDirectories
            )
        }
    }

    private func validateExistingDirectoryPrefix(
        _ path: String,
        ownedDirectories: Set<String>
    ) throws {
        let normalized = try normalized(path)
        try validateRootDirectory()
        var currentPath = ""
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            currentPath += "/\(component)"
            var metadata = stat()
            if lstat(currentPath, &metadata) != 0 {
                if errno == ENOENT {
                    return
                }
                throw pathError(currentPath, String(cString: strerror(errno)))
            }
            try validateDirectoryMetadata(
                metadata,
                path: currentPath,
                requirePrivateMode: ownedDirectories.contains(currentPath)
            )
        }
    }

    private func validateLegacyMigrationReadiness(
        _ resolution: HostwrightLocalPathResolution
    ) throws {
        let source = resolution.legacyStateDatabase
        let destination = resolution.stateDatabasePath
        let journal = resolution.legacyStateMigrationJournal
        if pathExists(journal) {
            let record = try readMigrationRecord(
                journalPath: journal,
                expectedSource: source,
                expectedDestination: destination
            )
            _ = try validateMigrationRecordState(record)
            return
        }

        guard pathExists(source) else { return }
        guard !pathExists(destination) else {
            throw migrationError(
                source,
                destination,
                "both legacy and destination databases exist; Hostwright will not choose one"
            )
        }
        try validateDirectoryChain(resolution.legacyRootDirectory)
        let identity = try validateRegularFile(source, requirePrivateMode: false)
        try validateNoSQLiteSidecars(source, destination: destination)
        try validateLegacyHostwrightDatabase(source)
        let destinationAncestor = try existingDirectoryIdentity(
            atOrAbove: databaseParent(destination)
        )
        guard identity.device == destinationAncestor.device else {
            throw migrationError(
                source,
                destination,
                "source and destination are on different filesystems, so an atomic rename is unavailable"
            )
        }
    }

    private func readMigrationRecord(
        journalPath: String,
        expectedSource: String,
        expectedDestination: String
    ) throws -> LegacyStateMigrationRecord {
        let data = try readSensitiveFile(journalPath, maximumBytes: 64 * 1_024)
        let record: LegacyStateMigrationRecord
        do {
            record = try JSONDecoder().decode(LegacyStateMigrationRecord.self, from: data)
        } catch {
            throw migrationError(expectedSource, expectedDestination, "the migration journal is invalid")
        }
        guard record.schemaVersion == 1,
              record.source == expectedSource,
              record.destination == expectedDestination else {
            throw migrationError(
                expectedSource,
                expectedDestination,
                "the migration journal does not match the current path contract"
            )
        }
        return record
    }

    private func validateMigrationRecordState(
        _ record: LegacyStateMigrationRecord
    ) throws -> Bool {
        let sourceExists = pathExists(record.source)
        let destinationExists = pathExists(record.destination)
        guard sourceExists != destinationExists else {
            let state = sourceExists
                ? "both source and destination exist"
                : "both source and destination are missing"
            throw migrationError(record.source, record.destination, state)
        }

        let currentPath = sourceExists ? record.source : record.destination
        try validateDirectoryChain(databaseParent(currentPath))
        let identity = try validateRegularFile(currentPath, requirePrivateMode: false)
        guard UInt64(identity.device) == record.sourceDevice,
              UInt64(identity.inode) == record.sourceInode else {
            throw migrationError(
                record.source,
                record.destination,
                "the \(sourceExists ? "legacy database" : "destination") identity does not match the migration journal"
            )
        }

        try validateNoSQLiteSidecars(record.source, destination: record.destination)
        try validateLegacyHostwrightDatabase(currentPath)

        if sourceExists {
            let destinationAncestor = try existingDirectoryIdentity(
                atOrAbove: databaseParent(record.destination)
            )
            guard identity.device == destinationAncestor.device else {
                throw migrationError(
                    record.source,
                    record.destination,
                    "source and destination are on different filesystems, so an atomic rename is unavailable"
                )
            }
        }
        return sourceExists
    }

    private func migrateLegacyStateIfNeeded(_ resolution: HostwrightLocalPathResolution) throws {
        let source = resolution.legacyStateDatabase
        let destination = resolution.stateDatabasePath
        let journal = resolution.legacyStateMigrationJournal

        if pathExists(journal) {
            try resumeLegacyMigration(journalPath: journal, expectedSource: source, expectedDestination: destination)
        }
        guard pathExists(source) else { return }
        guard !pathExists(destination) else {
            throw migrationError(source, destination, "both legacy and destination databases exist; Hostwright will not choose one")
        }
        try validateNoSQLiteSidecars(source, destination: destination)

        try validateDirectoryChain(resolution.legacyRootDirectory)
        let identity = try validateRegularFile(source, requirePrivateMode: false)
        try validateLegacyHostwrightDatabase(source)
        let targetParent = (destination as NSString).deletingLastPathComponent
        let targetParentIdentity = try directoryIdentity(targetParent)
        guard identity.device == targetParentIdentity.device else {
            throw migrationError(source, destination, "source and destination are on different filesystems, so an atomic rename is unavailable")
        }

        let record = LegacyStateMigrationRecord(
            schemaVersion: 1,
            source: source,
            destination: destination,
            sourceDevice: UInt64(identity.device),
            sourceInode: UInt64(identity.inode)
        )
        try writeSensitiveJSON(record, to: journal)
        try moveLegacyRecord(record, journalPath: journal)
    }

    private func resumeLegacyMigration(
        journalPath: String,
        expectedSource: String,
        expectedDestination: String
    ) throws {
        let record = try readMigrationRecord(
            journalPath: journalPath,
            expectedSource: expectedSource,
            expectedDestination: expectedDestination
        )
        try moveLegacyRecord(record, journalPath: journalPath)
    }

    private func moveLegacyRecord(_ record: LegacyStateMigrationRecord, journalPath: String) throws {
        let sourceExists = try validateMigrationRecordState(record)

        if sourceExists {
            let identity = try validateRegularFile(record.source, requirePrivateMode: false)
            guard UInt64(identity.device) == record.sourceDevice,
                  UInt64(identity.inode) == record.sourceInode else {
                throw migrationError(record.source, record.destination, "the legacy database identity changed after migration intent was recorded")
            }
            try withExclusiveSQLiteLock(record.source) { connection in
                let lockedIdentity = try validateRegularFile(
                    record.source,
                    requirePrivateMode: false
                )
                guard UInt64(lockedIdentity.device) == record.sourceDevice,
                      UInt64(lockedIdentity.inode) == record.sourceInode else {
                    throw migrationError(
                        record.source,
                        record.destination,
                        "the legacy database identity changed while acquiring the exclusive SQLite lock"
                    )
                }
                try validateNoSQLiteSidecars(record.source, destination: record.destination)
                do {
                    try MigrationRunner().validateMigrationLedger(on: connection)
                } catch {
                    throw migrationError(
                        record.source,
                        record.destination,
                        "the legacy migration ledger changed before the exclusive rename checkpoint: \(error)"
                    )
                }
                guard renamex_np(
                    record.source,
                    record.destination,
                    UInt32(RENAME_EXCL)
                ) == 0 else {
                    throw migrationError(record.source, record.destination, String(cString: strerror(errno)))
                }
                try synchronizeDirectory((record.source as NSString).deletingLastPathComponent)
                try synchronizeDirectory((record.destination as NSString).deletingLastPathComponent)
            }
        }

        try validateNoSQLiteSidecars(record.source, destination: record.destination)
        let migratedIdentity = try validateRegularFile(record.destination, requirePrivateMode: false)
        guard UInt64(migratedIdentity.device) == record.sourceDevice,
              UInt64(migratedIdentity.inode) == record.sourceInode else {
            throw migrationError(record.source, record.destination, "the destination identity does not match the recorded legacy database")
        }
        guard chmod(record.destination, S_IRUSR | S_IWUSR) == 0 else {
            throw migrationError(record.source, record.destination, "could not apply mode 0600 to the migrated database")
        }
        _ = try validateRegularFile(record.destination, requirePrivateMode: true)
        guard unlink(journalPath) == 0 else {
            throw migrationError(record.source, record.destination, "could not remove the completed migration journal")
        }
        try synchronizeDirectory((journalPath as NSString).deletingLastPathComponent)
        removeDirectoryIfEmpty((record.source as NSString).deletingLastPathComponent)
    }

    private func prepareDatabaseFile(_ path: String, createIfNeeded: Bool) throws {
        if pathExists(path) {
            _ = try validateRegularFile(path, requirePrivateMode: true)
            return
        }
        guard createIfNeeded else { return }

        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == EEXIST {
                _ = try validateRegularFile(path, requirePrivateMode: true)
                return
            }
            throw StateStoreError.openFailed(path: path, message: String(cString: strerror(errno)))
        }
        var completed = false
        defer {
            close(descriptor)
            if !completed { unlink(path) }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw StateStoreError.openFailed(path: path, message: String(cString: strerror(errno)))
        }
        guard fsync(descriptor) == 0 else {
            throw StateStoreError.openFailed(path: path, message: String(cString: strerror(errno)))
        }
        _ = try validateDescriptor(descriptor, path: path, requirePrivateMode: true, regularFile: true)
        try synchronizeDirectory((path as NSString).deletingLastPathComponent)
        completed = true
    }

    private func validateLegacyHostwrightDatabase(_ path: String) throws {
        do {
            let connection = try SQLiteConnection(path: path, createIfNeeded: false, readOnly: true)
            try MigrationRunner().validateMigrationLedger(on: connection)
            try connection.close()
        } catch {
            throw migrationError(
                path,
                path,
                "the legacy state file does not contain a valid compatible Hostwright migration ledger: \(error)"
            )
        }
    }

    private func withExclusiveSQLiteLock<T>(
        _ path: String,
        _ body: (SQLiteConnection) throws -> T
    ) throws -> T {
        let connection: SQLiteConnection
        do {
            connection = try SQLiteConnection(path: path, createIfNeeded: false)
            try connection.execute("BEGIN EXCLUSIVE TRANSACTION")
        } catch {
            throw migrationError(path, path, "could not acquire an exclusive SQLite migration lock: \(error)")
        }
        defer { try? connection.close() }
        let result: T
        do {
            result = try body(connection)
        } catch {
            throw error
        }
        do {
            // Closing rolls back the read-only transaction and releases the
            // SQLite lock without reopening the database through its old name.
            try connection.close()
        } catch {
            throw migrationError(path, path, "could not release the exclusive SQLite migration lock: \(error)")
        }
        return result
    }

    private func ensureDirectory(_ path: String, privateLeaf: Bool) throws {
        let normalized = try normalized(path)
        try validateRootDirectory()
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var currentPath = ""
        for (index, component) in components.enumerated() {
            currentPath += "/\(component)"
            var metadata = stat()
            var created = false
            if lstat(currentPath, &metadata) != 0 {
                guard errno == ENOENT else {
                    throw pathError(currentPath, String(cString: strerror(errno)))
                }
                if mkdir(currentPath, S_IRWXU) != 0 {
                    if errno != EEXIST {
                        throw pathError(currentPath, String(cString: strerror(errno)))
                    }
                    guard lstat(currentPath, &metadata) == 0 else {
                        throw pathError(currentPath, "the directory changed during creation")
                    }
                } else {
                    created = true
                    guard chmod(currentPath, S_IRWXU) == 0 else {
                        let code = errno
                        _ = rmdir(currentPath)
                        throw pathError(currentPath, String(cString: strerror(code)))
                    }
                }
                guard lstat(currentPath, &metadata) == 0 else {
                    if created { _ = rmdir(currentPath) }
                    throw pathError(currentPath, "could not inspect the created directory")
                }
            }
            let isLeaf = index == components.count - 1
            do {
                try validateDirectoryMetadata(
                    metadata,
                    path: currentPath,
                    requirePrivateMode: privateLeaf && isLeaf
                )
            } catch {
                if created { _ = rmdir(currentPath) }
                throw error
            }
        }
    }

    private func validateDirectoryChain(
        _ path: String,
        allowRootOwnedAliases: Bool = true
    ) throws {
        let normalized = try normalized(path)
        try validateRootDirectory()
        var currentPath = ""
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            currentPath += "/\(component)"
            var metadata = stat()
            guard lstat(currentPath, &metadata) == 0 else {
                throw pathError(currentPath, String(cString: strerror(errno)))
            }
            try validateDirectoryMetadata(
                metadata,
                path: currentPath,
                requirePrivateMode: false,
                allowRootOwnedAliases: allowRootOwnedAliases
            )
        }
    }

    private func validateDirectoryMetadata(
        _ metadata: stat,
        path: String,
        requirePrivateMode: Bool,
        allowRootOwnedAliases: Bool = true
    ) throws {
        if metadata.st_mode & S_IFMT == S_IFLNK {
            guard allowRootOwnedAliases, metadata.st_uid == 0, !requirePrivateMode else {
                throw pathError(path, "user-controlled and Hostwright-owned symlink directories are rejected")
            }
            var target = stat()
            let result = path.withCString { pointer in
                fstatat(AT_FDCWD, pointer, &target, 0)
            }
            guard result == 0, target.st_mode & S_IFMT == S_IFDIR else {
                throw pathError(path, "the root-owned symlink must resolve to a directory")
            }
            guard target.st_uid == 0 || target.st_uid == effectiveUserID,
                  target.st_mode & (S_ISUID | S_ISGID | S_ISVTX) == 0,
                  target.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
                throw pathError(path, "the root-owned symlink resolves through an unsafe writable directory")
            }
            let canonical: String
            do {
                canonical = try HostwrightLocalFilesystemPolicy.canonicalExistingPath(
                    path,
                    role: "state storage root-owned alias"
                )
            } catch {
                throw pathError(path, String(describing: error))
            }
            try validateDirectoryChain(canonical, allowRootOwnedAliases: false)
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw pathError(path, "a real directory is required; symlinks and non-directories are rejected")
        }
        guard metadata.st_uid == 0 || metadata.st_uid == effectiveUserID else {
            throw pathError(path, "owner UID \(metadata.st_uid) is neither root nor the invoking user")
        }
        let permissions = metadata.st_mode & 0o7777
        guard permissions & (S_ISUID | S_ISGID | S_ISVTX) == 0 else {
            throw pathError(path, "special permission bits on sensitive files are rejected")
        }
        guard permissions & (S_IWGRP | S_IWOTH) == 0 else {
            throw pathError(path, "group- or other-writable parent directories are rejected")
        }
        if requirePrivateMode {
            guard metadata.st_uid == effectiveUserID, permissions == S_IRWXU else {
                throw pathError(path, "Hostwright-owned directories require invoking-user ownership and mode 0700")
            }
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                atPath: path,
                role: "state storage directory"
            )
        } catch {
            throw pathError(path, String(describing: error))
        }
    }

    private func validateRootDirectory() throws {
        var metadata = stat()
        guard lstat("/", &metadata) == 0 else {
            throw pathError("/", String(cString: strerror(errno)))
        }
        try validateDirectoryMetadata(
            metadata,
            path: "/",
            requirePrivateMode: false,
            allowRootOwnedAliases: false
        )
    }

    private func validateRegularFile(_ path: String, requirePrivateMode: Bool) throws -> FileIdentity {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw pathError(path, String(cString: strerror(errno))) }
        defer { close(descriptor) }
        return try validateDescriptor(descriptor, path: path, requirePrivateMode: requirePrivateMode, regularFile: true)
    }

    private func validateDescriptor(
        _ descriptor: Int32,
        path: String,
        requirePrivateMode: Bool,
        regularFile: Bool
    ) throws -> FileIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw pathError(path, String(cString: strerror(errno)))
        }
        if regularFile, metadata.st_mode & S_IFMT != S_IFREG {
            throw pathError(path, "a regular non-symlink file is required")
        }
        guard metadata.st_uid == effectiveUserID else {
            throw pathError(path, "the file must be owned by the invoking user")
        }
        guard metadata.st_nlink == 1 else {
            throw pathError(path, "multiply linked sensitive files are rejected")
        }
        let permissions = metadata.st_mode & 0o7777
        guard permissions & (S_ISUID | S_ISGID | S_ISVTX) == 0 else {
            throw pathError(path, "special permission bits on sensitive files are rejected")
        }
        guard permissions & (S_IWGRP | S_IWOTH) == 0 else {
            throw pathError(path, "group- or other-writable sensitive files are rejected")
        }
        if requirePrivateMode, permissions != S_IRUSR | S_IWUSR {
            throw pathError(path, "sensitive state files require mode 0600")
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                fileDescriptor: descriptor,
                path: path,
                role: "sensitive state file"
            )
        } catch {
            throw pathError(path, String(describing: error))
        }
        return FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private func directoryIdentity(_ path: String) throws -> FileIdentity {
        var metadata = stat()
        guard stat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw pathError(path, "a destination directory is required")
        }
        return FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private func existingDirectoryIdentity(atOrAbove path: String) throws -> FileIdentity {
        var candidate = try normalized(path)
        while !pathExists(candidate) {
            let parent = (candidate as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != candidate else {
                throw pathError(path, "no existing destination ancestor could be inspected")
            }
            candidate = parent
        }
        try validateDirectoryChain(candidate)
        return try directoryIdentity(candidate)
    }

    private func validateNoSQLiteSidecars(
        _ source: String,
        destination: String
    ) throws {
        for (role, database) in [("legacy", source), ("destination", destination)] {
            for suffix in ["-journal", "-wal", "-shm"] where pathExists(database + suffix) {
                throw migrationError(
                    source,
                    destination,
                    "\(role) SQLite sidecar \(database + suffix) exists; stop writers and checkpoint the database first"
                )
            }
        }
    }

    private func databaseParent(_ path: String) throws -> String {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else {
            throw pathError(
                path,
                "a database filename beneath a secure parent directory is required"
            )
        }
        return parent
    }

    private func writeSensitiveJSON<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value) + Data("\n".utf8)
        let temporary = "\(path).tmp.\(UUID().uuidString)"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw pathError(temporary, String(cString: strerror(errno))) }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded { unlink(temporary) }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw pathError(temporary, String(cString: strerror(errno)))
        }
        _ = try validateDescriptor(
            descriptor,
            path: temporary,
            requirePrivateMode: true,
            regularFile: true
        )
        try writeAll(data, descriptor: descriptor, path: temporary)
        guard fsync(descriptor) == 0 else { throw pathError(temporary, String(cString: strerror(errno))) }
        guard renamex_np(temporary, path, UInt32(RENAME_EXCL)) == 0 else {
            let reason = errno == EEXIST
                ? "the migration journal already exists"
                : String(cString: strerror(errno))
            throw pathError(path, reason)
        }
        succeeded = true
        try synchronizeDirectory((path as NSString).deletingLastPathComponent)
    }

    private func readSensitiveFile(_ path: String, maximumBytes: Int) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw pathError(path, String(cString: strerror(errno))) }
        defer { close(descriptor) }
        _ = try validateDescriptor(descriptor, path: path, requirePrivateMode: true, regularFile: true)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw pathError(path, String(cString: strerror(errno))) }
            if count == 0 { return data }
            guard data.count + count <= maximumBytes else {
                throw pathError(path, "the migration journal exceeds \(maximumBytes) bytes")
            }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw pathError(path, String(cString: strerror(errno))) }
                offset += count
            }
        }
    }

    private func synchronizeDirectory(_ path: String) throws {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw pathError(path, String(cString: strerror(errno))) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw pathError(path, String(cString: strerror(errno))) }
    }

    private func removeDirectoryIfEmpty(_ path: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path), entries.isEmpty else { return }
        _ = rmdir(path)
    }

    private func pathExists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }

    private func normalized(_ path: String) throws -> String {
        do {
            return try HostwrightLocalPathResolver.normalizedAbsolutePath(path, role: "state storage")
        } catch {
            throw pathError(path, String(describing: error))
        }
    }

    private func pathError(_ path: String, _ message: String) -> StateStoreError {
        .pathPolicyViolation(path: path, message: message)
    }

    private func migrationError(_ source: String, _ destination: String, _ message: String) -> StateStoreError {
        .legacyPathMigrationFailed(source: source, destination: destination, message: message)
    }
}

private struct FileIdentity {
    let device: dev_t
    let inode: ino_t
}

private struct LegacyStateMigrationRecord: Codable, Equatable {
    let schemaVersion: Int
    let source: String
    let destination: String
    let sourceDevice: UInt64
    let sourceInode: UInt64
}
