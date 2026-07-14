import Foundation
import HostwrightCore

public struct StateStoreConfiguration: Equatable, Sendable {
    public let databasePath: String
    public let origin: HostwrightStatePathOrigin
    public let localPathResolution: HostwrightLocalPathResolution?

    public init(explicitDatabasePath databasePath: String) {
        self.databasePath = databasePath
        self.origin = .explicit
        self.localPathResolution = nil
    }

    public init(localPathResolution: HostwrightLocalPathResolution) {
        self.databasePath = localPathResolution.stateDatabasePath
        self.origin = localPathResolution.statePathOrigin
        self.localPathResolution = localPathResolution
    }

    public func validate() throws {
        if databasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw StateStoreError.invalidPath(databasePath)
        }
        do {
            _ = try HostwrightLocalPathResolver.normalizedAbsolutePath(databasePath, role: "state database")
        } catch {
            throw StateStoreError.pathPolicyViolation(path: databasePath, message: String(describing: error))
        }
    }

    func prepare(createIfNeeded: Bool) throws {
        try validate()
        do {
            try SecureStatePathManager().prepare(configuration: self, createIfNeeded: createIfNeeded)
        } catch let error as StateStoreError {
            throw error
        } catch {
            throw StateStoreError.pathPolicyViolation(path: databasePath, message: String(describing: error))
        }
    }

    public func prepareRuntimeSupport() throws {
        try validate()
        guard let resolution = localPathResolution else { return }
        do {
            try SecureStatePathManager().prepareRuntimeSupport(resolution.layout)
        } catch let error as StateStoreError {
            throw error
        } catch {
            throw StateStoreError.pathPolicyViolation(path: databasePath, message: String(describing: error))
        }
    }

    public func validateExistingPath() throws {
        try prepare(createIfNeeded: false)
    }

    public func validateProspectivePath() throws {
        try validate()
        do {
            try SecureStatePathManager().validateProspective(configuration: self)
        } catch let error as StateStoreError {
            throw error
        } catch {
            throw StateStoreError.pathPolicyViolation(
                path: databasePath,
                message: String(describing: error)
            )
        }
    }
}
