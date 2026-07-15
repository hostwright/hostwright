import CryptoKit
import Foundation
import HostwrightCore

@available(*, deprecated, renamed: "HostwrightStatePathOrigin")
public typealias StateStorePathOrigin = HostwrightStatePathOrigin

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

    @discardableResult
    func prepare(createIfNeeded: Bool) throws -> FileIdentity? {
        try validate()
        do {
            return try SecureStatePathManager().prepare(
                configuration: self,
                createIfNeeded: createIfNeeded
            )
        } catch let error as StateStoreError {
            throw error
        } catch {
            throw StateStoreError.pathPolicyViolation(path: databasePath, message: String(describing: error))
        }
    }

    func validateSQLiteFileSet() throws -> FileIdentity? {
        try validate()
        do {
            return try SecureStatePathManager().validateSQLiteFileSet(databasePath)
        } catch let error as StateStoreError {
            throw error
        } catch {
            throw StateStoreError.pathPolicyViolation(
                path: databasePath,
                message: String(describing: error)
            )
        }
    }

    func prepareStateAccessFoundation() throws {
        try validate()
        do {
            try SecureStatePathManager().prepareStateAccessFoundation(self)
        } catch let error as StateStoreError {
            throw error
        } catch {
            throw StateStoreError.pathPolicyViolation(
                path: databasePath,
                message: String(describing: error)
            )
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

    public func maintenancePaths() throws -> StateMaintenancePaths {
        try validate()
        if let resolution = localPathResolution, resolution.usesApplicationSupportState {
            return StateMaintenancePaths(
                backupDirectory: resolution.layout.backupsDirectory,
                journalPath: URL(
                    fileURLWithPath: resolution.layout.metadataDirectory,
                    isDirectory: true
                ).appendingPathComponent("state-maintenance-v1.json").path,
                accessLockPath: URL(
                    fileURLWithPath: resolution.layout.metadataDirectory,
                    isDirectory: true
                ).appendingPathComponent("state-access-v1.lock").path
            )
        }

        let parent = (databasePath as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != databasePath else {
            throw StateStoreError.pathPolicyViolation(
                path: databasePath,
                message: "a database filename beneath a secure parent directory is required"
            )
        }
        let digest = SHA256.hash(data: Data(databasePath.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return StateMaintenancePaths(
            backupDirectory: URL(fileURLWithPath: parent, isDirectory: true)
                .appendingPathComponent(".hostwright-\(digest)-backups", isDirectory: true)
                .path,
            journalPath: URL(fileURLWithPath: parent, isDirectory: true)
                .appendingPathComponent(".hostwright-\(digest)-maintenance-v1.json")
                .path,
            accessLockPath: URL(fileURLWithPath: parent, isDirectory: true)
                .appendingPathComponent(".hostwright-\(digest)-access-v1.lock")
                .path
        )
    }
}
