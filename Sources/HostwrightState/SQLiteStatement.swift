import SQLite3

enum SQLiteValue {
    case null
    case text(String)
    case int(Int)
    case int64(Int64)
    case bool(Bool)
}

enum SQLiteStepResult {
    case row
    case done
}

final class SQLiteStatement {
    let rawPointer: OpaquePointer
    private let connection: SQLiteConnection

    init(statement: OpaquePointer, connection: SQLiteConnection) {
        self.rawPointer = statement
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(rawPointer)
    }

    func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            try bind(value, at: Int32(offset + 1))
        }
    }

    func step() throws -> SQLiteStepResult {
        let result = sqlite3_step(rawPointer)
        switch result {
        case SQLITE_ROW:
            return .row
        case SQLITE_DONE:
            return .done
        default:
            throw StateStoreError.stepFailed(message: connection.lastErrorMessage)
        }
    }

    func columnText(_ index: Int32) -> String? {
        guard let value = sqlite3_column_text(rawPointer, index) else {
            return nil
        }
        return String(cString: value)
    }

    private func bind(_ value: SQLiteValue, at index: Int32) throws {
        let result: Int32
        switch value {
        case .null:
            result = sqlite3_bind_null(rawPointer, index)
        case .text(let text):
            result = sqlite3_bind_text(rawPointer, index, text, -1, sqliteTransient)
        case .int(let int):
            result = sqlite3_bind_int(rawPointer, index, Int32(int))
        case .int64(let int64):
            result = sqlite3_bind_int64(rawPointer, index, int64)
        case .bool(let bool):
            result = sqlite3_bind_int(rawPointer, index, bool ? 1 : 0)
        }

        if result != SQLITE_OK {
            throw StateStoreError.bindFailed(index: index, message: connection.lastErrorMessage)
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
