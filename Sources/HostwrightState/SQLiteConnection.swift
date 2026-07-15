import Foundation
import HostwrightSQLiteSupport
import SQLite3
import Darwin

enum SQLiteConnectionProfile: String, Sendable {
    case authoritativeState
    case portableArtifact
    case nonMutatingInspection
}

struct SQLiteConnectionPolicyReport: Equatable, Sendable {
    let libraryVersion: String
    let profile: SQLiteConnectionProfile
    let readOnly: Bool
    let journalMode: String
    let synchronous: Int
    let foreignKeys: Bool
    let trustedSchema: Bool
    let defensive: Bool
    let fullFSync: Bool
    let checkpointFullFSync: Bool
    let secureDelete: Int
    let cellSizeCheck: Bool
    let queryOnly: Bool
    let tempStore: Int
    let memoryMappedBytes: Int64
    let busyTimeoutMilliseconds: Int32
    let noFollow: Bool

    var usesLegacyJournalMode: Bool {
        profile == .authoritativeState && journalMode != "wal"
    }
}

final class SQLiteConnection {
    static let busyTimeoutMilliseconds: Int32 = 250
    static let maximumValueBytes: Int32 = 16 * 1_024 * 1_024
    static let maximumSQLBytes: Int32 = 1 * 1_024 * 1_024
    static let maximumColumns: Int32 = 256
    static let maximumAttachedDatabases: Int32 = 0
    static let walAutoCheckpointPages = 1_000
    static let journalSizeLimitBytes: Int64 = 64 * 1_024 * 1_024

    let path: String
    let profile: SQLiteConnectionProfile
    let readOnly: Bool

    private var handle: OpaquePointer?
    private var managedTransactionActive = false
    private var permitsInternalTransactionControl = false
    private let defaultCancellation = SQLiteCancellationContext(check: sqliteCurrentTaskIsCancelled)

    init(
        path: String,
        createIfNeeded: Bool = true,
        readOnly: Bool = false,
        profile: SQLiteConnectionProfile = .portableArtifact
    ) throws {
        self.path = path
        self.profile = profile
        self.readOnly = readOnly

        guard profile != .nonMutatingInspection || (readOnly && !createIfNeeded) else {
            throw StateStoreError.openFailed(
                path: path,
                message: "non-mutating SQLite inspection requires an existing read-only database"
            )
        }

        let openPath = try Self.canonicalOpenPath(path)
        if createIfNeeded, !readOnly {
            try Self.prepareSecureDatabaseCreation(at: openPath, reportedPath: path)
        }
        let expectedIdentity = try Self.validatedFileIdentity(
            at: openPath,
            reportedPath: path
        )

        var database: OpaquePointer?
        let accessFlag = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        let createFlag = createIfNeeded && !readOnly ? SQLITE_OPEN_CREATE : 0
        let flags = accessFlag
            | createFlag
            | SQLITE_OPEN_FULLMUTEX
            | SQLITE_OPEN_NOFOLLOW
            | SQLITE_OPEN_EXRESCODE
        let sqlitePath: String
        let uriFlag: Int32
        if profile == .nonMutatingInspection {
            sqlitePath = URL(fileURLWithPath: openPath).absoluteString + "?mode=ro&immutable=1"
            uriFlag = SQLITE_OPEN_URI
        } else {
            sqlitePath = openPath
            uriFlag = 0
        }
        let result = sqlite3_open_v2(sqlitePath, &database, flags | uriFlag, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown SQLite open error"
            if let database {
                sqlite3_close(database)
            }
            throw StateStoreError.openFailed(path: path, message: message)
        }

        do {
            let openedIdentity = try Self.validatedFileIdentity(
                at: openPath,
                reportedPath: path
            )
            guard expectedIdentity == openedIdentity else {
                throw StateStoreError.pathPolicyViolation(
                    path: path,
                    message: "the database identity changed while SQLite was opening it"
                )
            }
        } catch {
            sqlite3_close(database)
            throw error
        }

        self.handle = database
        installProgressHandler(defaultCancellation)
        let authorizerResult = sqlite3_set_authorizer(
            database,
            sqliteManagedTransactionAuthorizer,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard authorizerResult == SQLITE_OK else {
            sqlite3_progress_handler(database, 0, nil, nil)
            self.handle = nil
            sqlite3_close(database)
            throw StateStoreError.openFailed(
                path: path,
                message: "SQLite transaction authorizer could not be installed"
            )
        }
        do {
            try configure(database)
            _ = try policyReport()
        } catch {
            sqlite3_progress_handler(database, 0, nil, nil)
            self.handle = nil
            sqlite3_close(database)
            throw error
        }
    }

    deinit {
        try? close()
    }

    func close() throws {
        guard let handle else { return }
        sqlite3_progress_handler(handle, 0, nil, nil)

        var rollbackError: StateStoreError?
        if sqlite3_get_autocommit(handle) == 0 {
            do {
                try executeInternalTransactionControl("ROLLBACK")
            } catch {
                rollbackError = error as? StateStoreError
                    ?? .transactionFailed(message: String(describing: error))
            }
        }
        managedTransactionActive = false

        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else {
            installProgressHandler(defaultCancellation)
            throw classifySQLiteError(
                result: result,
                defaultError: .closeFailed(path: path, message: lastErrorMessage)
            )
        }
        self.handle = nil
        if let rollbackError {
            throw rollbackError
        }
    }

    var lastErrorMessage: String {
        guard let handle else {
            return "SQLite database is closed"
        }
        return String(cString: sqlite3_errmsg(handle))
    }

    func execute(_ sql: String) throws {
        try rejectManagedTransactionControl(sql)
        try executeRaw(sql)
    }

    func run(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        while true {
            switch try statement.step() {
            case .row:
                continue
            case .done:
                return
            }
        }
    }

    func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[String?]] {
        let statement = try prepare(sql)
        try statement.bind(bindings)

        var rows: [[String?]] = []
        while true {
            switch try statement.step() {
            case .row:
                let columnCount = sqlite3_column_count(statement.rawPointer)
                var row: [String?] = []
                for index in 0..<columnCount {
                    row.append(statement.columnText(index))
                }
                rows.append(row)
            case .done:
                return rows
            }
        }
    }

    func transaction<T>(
        shouldCancel: @escaping () -> Bool = sqliteCurrentTaskIsCancelled,
        rollbackForTesting: (() throws -> Void)? = nil,
        _ body: () throws -> T
    ) throws -> T {
        guard let handle else {
            throw StateStoreError.transactionFailed(message: "SQLite database is closed.")
        }
        guard sqlite3_get_autocommit(handle) != 0, !managedTransactionActive else {
            throw StateStoreError.transactionInvariantViolation(
                message: "nested or externally opened transactions are rejected"
            )
        }
        if shouldCancel() {
            throw StateStoreError.operationCancelled(path: path)
        }

        let cancellation = SQLiteCancellationContext(check: shouldCancel)
        installProgressHandler(cancellation)
        defer { installProgressHandler(defaultCancellation) }

        var began = false
        var commitAttempted = false
        do {
            try executeInternalTransactionControl("BEGIN IMMEDIATE TRANSACTION")
            began = true
            managedTransactionActive = true
            guard sqlite3_get_autocommit(handle) == 0 else {
                throw StateStoreError.transactionInvariantViolation(
                    message: "BEGIN IMMEDIATE did not establish a write transaction"
                )
            }

            let value = try body()
            guard sqlite3_get_autocommit(handle) == 0 else {
                throw StateStoreError.transactionInvariantViolation(
                    message: "the transaction body ended Hostwright's managed transaction"
                )
            }
            if shouldCancel() {
                throw StateStoreError.operationCancelled(path: path)
            }

            commitAttempted = true
            try executeInternalTransactionControl("COMMIT")
            began = false
            managedTransactionActive = false
            guard sqlite3_get_autocommit(handle) != 0 else {
                throw StateStoreError.transactionInvariantViolation(
                    message: "COMMIT returned without closing the write transaction"
                )
            }
            return value
        } catch {
            let original = error
            sqlite3_progress_handler(handle, 0, nil, nil)
            var rollbackFailure: Error?
            if began, sqlite3_get_autocommit(handle) == 0 {
                do {
                    if let rollbackForTesting {
                        try rollbackForTesting()
                    } else {
                        try executeInternalTransactionControl("ROLLBACK")
                    }
                    began = false
                } catch {
                    rollbackFailure = error
                }
            }
            managedTransactionActive = false

            if let rollbackFailure {
                throw StateStoreError.transactionOutcomeUncertain(
                    path: path,
                    message: "operation failed with \(original); mandatory rollback also failed with \(rollbackFailure)"
                )
            }
            if began, sqlite3_get_autocommit(handle) != 0, commitAttempted {
                throw StateStoreError.transactionOutcomeUncertain(
                    path: path,
                    message: "operation failed with \(original), but SQLite ended the transaction before Hostwright observed a successful commit or rollback"
                )
            }
            guard sqlite3_get_autocommit(handle) != 0 else {
                throw StateStoreError.transactionOutcomeUncertain(
                    path: path,
                    message: "operation failed with \(original), and the connection did not return to autocommit mode after rollback"
                )
            }
            if let stateError = original as? StateStoreError {
                throw stateError
            }
            throw StateStoreError.transactionFailed(message: String(describing: original))
        }
    }

    func interrupt() {
        if let handle {
            sqlite3_interrupt(handle)
        }
    }

    func policyReport() throws -> SQLiteConnectionPolicyReport {
        let journalMode = try requiredTextPragma("journal_mode").lowercased()
        let synchronous = try requiredIntPragma("synchronous")
        let foreignKeys = try requiredIntPragma("foreign_keys") == 1
        let trustedSchema = try requiredIntPragma("trusted_schema") == 1
        let fullFSync = try requiredIntPragma("fullfsync") == 1
        let checkpointFullFSync = try requiredIntPragma("checkpoint_fullfsync") == 1
        let secureDelete = try requiredIntPragma("secure_delete")
        let cellSizeCheck = try requiredIntPragma("cell_size_check") == 1
        let queryOnly = try requiredIntPragma("query_only") == 1
        let tempStore = try requiredIntPragma("temp_store")
        let memoryMappedBytes = try requiredInt64Pragma("mmap_size")
        let timeout = try requiredIntPragma("busy_timeout")
        let defensive = try databaseConfigValue(SQLITE_DBCONFIG_DEFENSIVE) == 1

        let expectedSynchronous = profile == .portableArtifact ? 3 : 2
        let allowedJournalModes: Set<String>
        if readOnly {
            allowedJournalModes = ["delete", "wal"]
        } else {
            allowedJournalModes = [profile == .authoritativeState ? "wal" : "delete"]
        }
        guard allowedJournalModes.contains(journalMode),
              synchronous == expectedSynchronous,
              foreignKeys,
              !trustedSchema,
              defensive,
              fullFSync,
              checkpointFullFSync,
              secureDelete == 1,
              cellSizeCheck,
              queryOnly == readOnly,
              tempStore == 2,
              memoryMappedBytes == 0,
              timeout == Int(Self.busyTimeoutMilliseconds) else {
            throw StateStoreError.openFailed(
                path: path,
                message: "SQLite connection policy verification failed"
            )
        }

        return SQLiteConnectionPolicyReport(
            libraryVersion: String(cString: sqlite3_libversion()),
            profile: profile,
            readOnly: readOnly,
            journalMode: journalMode,
            synchronous: synchronous,
            foreignKeys: foreignKeys,
            trustedSchema: trustedSchema,
            defensive: defensive,
            fullFSync: fullFSync,
            checkpointFullFSync: checkpointFullFSync,
            secureDelete: secureDelete,
            cellSizeCheck: cellSizeCheck,
            queryOnly: queryOnly,
            tempStore: tempStore,
            memoryMappedBytes: memoryMappedBytes,
            busyTimeoutMilliseconds: Int32(timeout),
            noFollow: true
        )
    }

    func onlineBackup(
        to destinationPath: String,
        destinationMaximumPages: Int32? = nil,
        shouldCancel: () -> Bool = sqliteCurrentTaskIsCancelled
    ) throws {
        guard let sourceHandle = handle else {
            throw StateMaintenanceError.sqlite(message: "the source database is closed")
        }
        let destination = try SQLiteConnection(
            path: destinationPath,
            createIfNeeded: false,
            readOnly: false,
            profile: .portableArtifact
        )
        defer { try? destination.close() }
        if let destinationMaximumPages {
            guard destinationMaximumPages > 0 else {
                throw StateMaintenanceError.sqlite(message: "destination page limit must be positive")
            }
            try destination.execute("PRAGMA max_page_count = \(destinationMaximumPages)")
        }
        guard let destinationHandle = destination.handle else {
            throw StateMaintenanceError.sqlite(message: "the destination database is closed")
        }
        guard let backup = sqlite3_backup_init(
            destinationHandle,
            "main",
            sourceHandle,
            "main"
        ) else {
            throw StateMaintenanceError.sqlite(message: destination.lastErrorMessage)
        }

        var stepResult: Int32 = SQLITE_OK
        var busyAttempts = 0
        var cancellationRequested = false
        while true {
            if shouldCancel() {
                cancellationRequested = true
                break
            }
            stepResult = sqlite3_backup_step(backup, 128)
            switch stepResult {
            case SQLITE_DONE:
                break
            case SQLITE_OK:
                continue
            case SQLITE_BUSY, SQLITE_LOCKED:
                busyAttempts += 1
                guard busyAttempts <= 25 else { break }
                sqlite3_sleep(10)
                continue
            default:
                break
            }
            break
        }

        let finishResult = sqlite3_backup_finish(backup)
        if cancellationRequested {
            throw StateMaintenanceError.cancelled
        }
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            let code = stepResult == SQLITE_DONE ? finishResult : stepResult
            let message = destination.lastErrorMessage
            if code == SQLITE_BUSY || code == SQLITE_LOCKED {
                throw StateStoreError.databaseLocked(path: path, message: message)
            }
            if code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
                throw StateStoreError.corruptDatabase(path: path, message: message)
            }
            throw StateMaintenanceError.sqlite(
                message: "online backup failed with SQLite code \(code): \(message)"
            )
        }
        let journalMode = try destination.query("PRAGMA journal_mode = DELETE")
            .first?.first ?? nil
        guard journalMode?.lowercased() == "delete" else {
            throw StateMaintenanceError.sqlite(
                message: "the copied database could not be normalized to sidecar-free DELETE journal mode"
            )
        }
        try destination.close()
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = destinationPath + suffix
            if StateMaintenanceFileSupport.exists(sidecar) {
                try StateMaintenanceFileSupport.unlinkSensitiveFile(sidecar)
            }
        }
    }

    private func configure(_ database: OpaquePointer) throws {
        sqlite3_extended_result_codes(database, 1)
        let timeoutResult = sqlite3_busy_timeout(database, Self.busyTimeoutMilliseconds)
        guard timeoutResult == SQLITE_OK else {
            throw StateStoreError.openFailed(path: path, message: lastErrorMessage)
        }

        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, Self.maximumValueBytes)
        sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, Self.maximumSQLBytes)
        sqlite3_limit(database, SQLITE_LIMIT_COLUMN, Self.maximumColumns)
        sqlite3_limit(database, SQLITE_LIMIT_ATTACHED, Self.maximumAttachedDatabases)

        try setDatabaseConfig(SQLITE_DBCONFIG_DEFENSIVE, value: 1)
        try setDatabaseConfig(SQLITE_DBCONFIG_TRUSTED_SCHEMA, value: 0)
        try setDatabaseConfig(SQLITE_DBCONFIG_DQS_DML, value: 0)
        try setDatabaseConfig(SQLITE_DBCONFIG_DQS_DDL, value: 0)
        if sqlite3_compileoption_used("OMIT_LOAD_EXTENSION") == 0 {
            try setDatabaseConfig(SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, value: 0)
        }
        try validateApplicationIdentityBeforePersistentConfiguration()

        try executeRaw("PRAGMA foreign_keys = ON")
        try executeRaw("PRAGMA trusted_schema = OFF")
        try executeRaw("PRAGMA cell_size_check = ON")
        try executeRaw("PRAGMA temp_store = MEMORY")
        try executeRaw("PRAGMA mmap_size = 0")
        try executeRaw("PRAGMA cache_size = -8192")
        try executeRaw("PRAGMA secure_delete = ON")
        try executeRaw("PRAGMA fullfsync = ON")
        try executeRaw("PRAGMA checkpoint_fullfsync = ON")
        try executeRaw("PRAGMA locking_mode = NORMAL")

        if !readOnly {
            let requestedMode = profile == .authoritativeState ? "WAL" : "DELETE"
            let effectiveMode = try query("PRAGMA journal_mode = \(requestedMode)")
                .first?.first ?? nil
            guard effectiveMode?.lowercased() == requestedMode.lowercased() else {
                throw StateStoreError.openFailed(
                    path: path,
                    message: "SQLite refused required \(requestedMode) journal mode"
                )
            }
        }

        let synchronous = profile == .portableArtifact ? "EXTRA" : "FULL"
        try executeRaw("PRAGMA synchronous = \(synchronous)")
        try executeRaw("PRAGMA journal_size_limit = \(Self.journalSizeLimitBytes)")
        if profile == .authoritativeState {
            try executeRaw("PRAGMA wal_autocheckpoint = \(Self.walAutoCheckpointPages)")
        }
        if readOnly {
            try executeRaw("PRAGMA query_only = ON")
        }
    }

    private static func canonicalOpenPath(_ path: String) throws -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let filename = (path as NSString).lastPathComponent
        guard !parent.isEmpty, !filename.isEmpty else {
            throw StateStoreError.openFailed(
                path: path,
                message: "an absolute database path beneath an existing parent is required"
            )
        }
        guard let resolvedPointer = realpath(parent, nil) else {
            throw StateStoreError.openFailed(
                path: path,
                message: String(cString: strerror(errno))
            )
        }
        defer { free(resolvedPointer) }
        let resolvedParent = String(cString: resolvedPointer)
        return URL(fileURLWithPath: resolvedParent, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
            .path
    }

    private static func validatedFileIdentity(
        at openPath: String,
        reportedPath: String
    ) throws -> FileIdentity? {
        do {
            return try SecureStatePathManager().validateSQLiteFileSet(openPath)
        } catch StateStoreError.pathPolicyViolation(let rejectedPath, let message) {
            let reportedRejectedPath: String
            if rejectedPath == openPath {
                reportedRejectedPath = reportedPath
            } else if let suffix = ["-journal", "-wal", "-shm"].first(where: {
                rejectedPath == openPath + $0
            }) {
                reportedRejectedPath = reportedPath + suffix
            } else {
                reportedRejectedPath = rejectedPath
            }
            throw StateStoreError.pathPolicyViolation(
                path: reportedRejectedPath,
                message: message
            )
        }
    }

    private static func prepareSecureDatabaseCreation(
        at openPath: String,
        reportedPath: String
    ) throws {
        let descriptor = open(
            openPath,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        if descriptor < 0 {
            guard errno == EEXIST else {
                throw StateStoreError.openFailed(
                    path: reportedPath,
                    message: String(cString: strerror(errno))
                )
            }
            return
        }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0 else {
            let code = errno
            throw creationFailure(
                openPath: openPath,
                reportedPath: reportedPath,
                originalError: code
            )
        }

        let parent = (openPath as NSString).deletingLastPathComponent
        let parentDescriptor = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            throw creationFailure(
                openPath: openPath,
                reportedPath: reportedPath,
                originalError: errno
            )
        }
        defer { Darwin.close(parentDescriptor) }
        guard fsync(parentDescriptor) == 0 else {
            throw creationFailure(
                openPath: openPath,
                reportedPath: reportedPath,
                originalError: errno,
                parentDescriptor: parentDescriptor
            )
        }
    }

    private static func creationFailure(
        openPath: String,
        reportedPath: String,
        originalError: Int32,
        parentDescriptor: Int32? = nil
    ) -> StateStoreError {
        let originalMessage = String(cString: strerror(originalError))
        guard unlink(openPath) == 0 || errno == ENOENT else {
            return .openFailed(
                path: reportedPath,
                message: "\(originalMessage); cleanup of the unpublished database also failed: \(String(cString: strerror(errno)))"
            )
        }
        if let parentDescriptor {
            _ = fsync(parentDescriptor)
        }
        return .openFailed(path: reportedPath, message: originalMessage)
    }

    private func setDatabaseConfig(_ option: Int32, value: Int32) throws {
        guard let handle else {
            throw StateStoreError.openFailed(path: path, message: "SQLite database is closed")
        }
        var effective: Int32 = -1
        let result = hostwright_sqlite_set_db_config(handle, option, value, &effective)
        guard result == SQLITE_OK, effective == value else {
            throw StateStoreError.openFailed(
                path: path,
                message: "required SQLite database configuration option \(option) is unavailable"
            )
        }
    }

    private func validateApplicationIdentityBeforePersistentConfiguration() throws {
        let applicationID = try requiredIntPragma("application_id")
        guard applicationID == 0 || applicationID == MigrationRunner.applicationID else {
            throw StateStoreError.incompatibleSchema(
                foundVersion: nil,
                latestSupported: MigrationRunner.latestSchemaVersion,
                message: "SQLite application_id \(applicationID) is not owned by Hostwright; refusing to read, claim, or mutate it."
            )
        }
    }

    private func databaseConfigValue(_ option: Int32) throws -> Int32 {
        guard let handle else {
            throw StateStoreError.openFailed(path: path, message: "SQLite database is closed")
        }
        var effective: Int32 = -1
        let result = hostwright_sqlite_set_db_config(handle, option, -1, &effective)
        guard result == SQLITE_OK else {
            throw StateStoreError.openFailed(
                path: path,
                message: "could not inspect SQLite database configuration option \(option)"
            )
        }
        return effective
    }

    private func requiredTextPragma(_ name: String) throws -> String {
        guard let value = try query("PRAGMA \(name)").first?.first ?? nil else {
            throw StateStoreError.openFailed(path: path, message: "PRAGMA \(name) returned no value")
        }
        return value
    }

    private func requiredIntPragma(_ name: String) throws -> Int {
        guard let value = Int(try requiredTextPragma(name)) else {
            throw StateStoreError.openFailed(path: path, message: "PRAGMA \(name) returned a non-integer value")
        }
        return value
    }

    private func requiredInt64Pragma(_ name: String) throws -> Int64 {
        guard let value = Int64(try requiredTextPragma(name)) else {
            throw StateStoreError.openFailed(path: path, message: "PRAGMA \(name) returned a non-integer value")
        }
        return value
    }

    private func executeRaw(_ sql: String) throws {
        guard let handle else {
            throw StateStoreError.executeFailed(message: "SQLite database is closed.")
        }

        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
            throw classifySQLiteError(result: result, defaultError: .executeFailed(message: message))
        }
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
    }

    private func executeInternalTransactionControl(_ sql: String) throws {
        let previous = permitsInternalTransactionControl
        permitsInternalTransactionControl = true
        defer { permitsInternalTransactionControl = previous }
        try executeRaw(sql)
    }

    private func prepare(_ sql: String) throws -> SQLiteStatement {
        try rejectManagedTransactionControl(sql)
        guard let handle else {
            throw StateStoreError.prepareFailed(sql: sql, message: "SQLite database is closed.")
        }

        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            let message = lastErrorMessage
            throw classifySQLiteError(
                result: result,
                defaultError: .prepareFailed(sql: sql, message: message)
            )
        }
        return SQLiteStatement(statement: statement, connection: self)
    }

    private func rejectManagedTransactionControl(_ sql: String) throws {
        guard managedTransactionActive else { return }
        let firstToken = sql
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace || $0 == ";" })
            .first?
            .uppercased()
        if let firstToken,
           ["BEGIN", "COMMIT", "END", "ROLLBACK", "SAVEPOINT", "RELEASE"].contains(firstToken) {
            throw StateStoreError.transactionInvariantViolation(
                message: "transaction control inside a managed transaction is rejected"
            )
        }
    }

    fileprivate func authorizeSQLiteAction(_ action: Int32) -> Int32 {
        guard managedTransactionActive, !permitsInternalTransactionControl else {
            return SQLITE_OK
        }
        if action == SQLITE_TRANSACTION || action == SQLITE_SAVEPOINT {
            return SQLITE_DENY
        }
        return SQLITE_OK
    }

    private func installProgressHandler(_ context: SQLiteCancellationContext) {
        guard let handle else { return }
        sqlite3_progress_handler(
            handle,
            1_000,
            sqliteCancellationProgressHandler,
            Unmanaged.passUnretained(context).toOpaque()
        )
    }

    func classifySQLiteError(result: Int32, defaultError: StateStoreError) -> StateStoreError {
        guard let handle else {
            return defaultError
        }

        let extended = sqlite3_extended_errcode(handle)
        let primary = extended & 0xff
        let message = lastErrorMessage

        switch primary {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return .databaseLocked(path: path, message: message)
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return .corruptDatabase(path: path, message: message)
        case SQLITE_FULL:
            return .storageFull(path: path, message: message)
        case SQLITE_IOERR:
            return .ioFailure(path: path, message: message)
        case SQLITE_AUTH where managedTransactionActive:
            return .transactionInvariantViolation(
                message: "transaction control inside a managed transaction is rejected"
            )
        case SQLITE_READONLY, SQLITE_PERM, SQLITE_AUTH:
            return .readOnlyViolation(path: path, message: message)
        case SQLITE_INTERRUPT:
            return .operationCancelled(path: path)
        default:
            return defaultError
        }
    }
}

private let sqliteManagedTransactionAuthorizer: @convention(c) (
    UnsafeMutableRawPointer?,
    Int32,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
) -> Int32 = { rawConnection, action, _, _, _, _ in
    guard let rawConnection else { return SQLITE_DENY }
    let connection = Unmanaged<SQLiteConnection>
        .fromOpaque(rawConnection)
        .takeUnretainedValue()
    return connection.authorizeSQLiteAction(action)
}

private final class SQLiteCancellationContext {
    let check: () -> Bool

    init(check: @escaping () -> Bool) {
        self.check = check
    }
}

private let sqliteCancellationProgressHandler: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = {
    rawContext in
    guard let rawContext else { return 0 }
    let context = Unmanaged<SQLiteCancellationContext>
        .fromOpaque(rawContext)
        .takeUnretainedValue()
    return context.check() ? 1 : 0
}

func sqliteCurrentTaskIsCancelled() -> Bool {
    var cancelled = false
    withUnsafeCurrentTask { task in
        cancelled = task?.isCancelled ?? false
    }
    return cancelled
}
