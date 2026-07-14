import SQLite3

final class SQLiteConnection {
    static let busyTimeoutMilliseconds: Int32 = 250

    let path: String
    private var handle: OpaquePointer?

    init(path: String, createIfNeeded: Bool = true, readOnly: Bool = false) throws {
        self.path = path

        var database: OpaquePointer?
        let accessFlag = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        let createFlag = createIfNeeded && !readOnly ? SQLITE_OPEN_CREATE : 0
        let flags = accessFlag | createFlag | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite open error"
            if let database {
                sqlite3_close(database)
            }
            throw StateStoreError.openFailed(path: path, message: message)
        }

        sqlite3_extended_result_codes(database, 1)
        let timeoutResult = sqlite3_busy_timeout(database, Self.busyTimeoutMilliseconds)
        guard timeoutResult == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(database))
            sqlite3_close(database)
            throw StateStoreError.openFailed(path: path, message: message)
        }

        self.handle = database
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        try? close()
    }

    func close() throws {
        guard let handle else { return }
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else {
            throw classifySQLiteError(
                result: result,
                defaultError: .closeFailed(path: path, message: lastErrorMessage)
            )
        }
        self.handle = nil
    }

    var lastErrorMessage: String {
        guard let handle else {
            return "SQLite database is closed"
        }
        return String(cString: sqlite3_errmsg(handle))
    }

    func execute(_ sql: String) throws {
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

    func transaction<T>(_ body: () throws -> T) throws -> T {
        do {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            if let stateError = error as? StateStoreError {
                throw stateError
            }
            throw StateStoreError.transactionFailed(message: String(describing: error))
        }
    }

    func onlineBackup(
        to destinationPath: String,
        destinationMaximumPages: Int32? = nil,
        shouldCancel: () -> Bool = { false }
    ) throws {
        guard let sourceHandle = handle else {
            throw StateMaintenanceError.sqlite(message: "the source database is closed")
        }
        let destination = try SQLiteConnection(
            path: destinationPath,
            createIfNeeded: false,
            readOnly: false
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

    private func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else {
            throw StateStoreError.prepareFailed(sql: sql, message: "SQLite database is closed.")
        }

        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            let message = lastErrorMessage
            throw classifySQLiteError(result: result, defaultError: .prepareFailed(sql: sql, message: message))
        }

        return SQLiteStatement(statement: statement, connection: self)
    }

    func classifySQLiteError(result: Int32, defaultError: StateStoreError) -> StateStoreError {
        guard let handle else {
            return defaultError
        }

        let extended = sqlite3_extended_errcode(handle)
        let primary = extended & 0xff
        let message = lastErrorMessage

        if primary == SQLITE_BUSY || primary == SQLITE_LOCKED {
            return .databaseLocked(path: path, message: message)
        }

        if primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB {
            return .corruptDatabase(path: path, message: message)
        }

        return defaultError
    }
}
