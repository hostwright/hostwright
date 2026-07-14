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
