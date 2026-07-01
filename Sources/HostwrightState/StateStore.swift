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
    func migrate() throws
    func schemaVersion() throws -> Int
}
