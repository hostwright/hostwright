import Foundation

public enum StateStorePathOrigin: String, Equatable, Sendable {
    case explicit
}

public struct StateStoreConfiguration: Equatable, Sendable {
    public let databasePath: String
    public let origin: StateStorePathOrigin

    public init(explicitDatabasePath databasePath: String) {
        self.databasePath = databasePath
        self.origin = .explicit
    }

    public func validate() throws {
        if databasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw StateStoreError.invalidPath(databasePath)
        }
    }
}
