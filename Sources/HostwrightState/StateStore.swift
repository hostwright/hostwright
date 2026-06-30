import HostwrightCore

public enum StateStoreBackend: String, Equatable, Sendable {
    case sqlite
}

public struct StateStoreDescription: Equatable, Sendable {
    public let backend: StateStoreBackend
    public let isImplemented: Bool
    public let message: String

    public init(backend: StateStoreBackend, isImplemented: Bool, message: String) {
        self.backend = backend
        self.isImplemented = isImplemented
        self.message = message
    }
}

public protocol StateStore: Sendable {
    func describe() async -> StateStoreDescription
}

public struct SQLiteStateStore: StateStore {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func describe() async -> StateStoreDescription {
        StateStoreDescription(
            backend: .sqlite,
            isImplemented: false,
            message: "SQLite state store is an interface boundary in Phase 1; no database is opened."
        )
    }
}

