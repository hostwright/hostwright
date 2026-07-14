import CryptoKit
import Darwin
import Foundation

public enum HostwrightStatePathOrigin: String, Codable, Equatable, Sendable {
    case explicit
    case environment
    case applicationSupportDefault = "application-support-default"
}

public enum HostwrightLocalPathReadiness: String, Codable, Equatable, Sendable {
    case ready
    case needsCreation = "needs-creation"
    case migrationRequired = "migration-required"
    case blockedConflict = "blocked-conflict"
    case blockedPolicy = "blocked-policy"
}

public struct HostwrightLocalPathLayout: Codable, Equatable, Sendable {
    public let applicationSupportDirectory: String
    public let configurationDirectory: String
    public let stateDirectory: String
    public let runtimeDirectory: String
    public let metadataDirectory: String
    public let backupsDirectory: String
    public let cacheDirectory: String
    public let logDirectory: String
    public let stateDatabase: String
    public let daemonLock: String
    public let controlSocket: String

    public init(
        applicationSupportDirectory: String,
        configurationDirectory: String,
        stateDirectory: String,
        runtimeDirectory: String,
        metadataDirectory: String,
        backupsDirectory: String,
        cacheDirectory: String,
        logDirectory: String,
        stateDatabase: String,
        daemonLock: String,
        controlSocket: String
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.configurationDirectory = configurationDirectory
        self.stateDirectory = stateDirectory
        self.runtimeDirectory = runtimeDirectory
        self.metadataDirectory = metadataDirectory
        self.backupsDirectory = backupsDirectory
        self.cacheDirectory = cacheDirectory
        self.logDirectory = logDirectory
        self.stateDatabase = stateDatabase
        self.daemonLock = daemonLock
        self.controlSocket = controlSocket
    }

    public var ownedDirectories: [String] {
        [
            applicationSupportDirectory,
            configurationDirectory,
            stateDirectory,
            runtimeDirectory,
            metadataDirectory,
            backupsDirectory,
            cacheDirectory,
            logDirectory
        ]
    }
}

public struct HostwrightLocalPathResolution: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let layout: HostwrightLocalPathLayout
    public let stateDatabasePath: String
    public let statePathOrigin: HostwrightStatePathOrigin
    public let legacyRootDirectory: String
    public let legacyStateDatabase: String

    public init(
        schemaVersion: Int = 1,
        layout: HostwrightLocalPathLayout,
        stateDatabasePath: String,
        statePathOrigin: HostwrightStatePathOrigin,
        legacyRootDirectory: String,
        legacyStateDatabase: String
    ) {
        self.schemaVersion = schemaVersion
        self.layout = layout
        self.stateDatabasePath = stateDatabasePath
        self.statePathOrigin = statePathOrigin
        self.legacyRootDirectory = legacyRootDirectory
        self.legacyStateDatabase = legacyStateDatabase
    }

    public var usesApplicationSupportState: Bool {
        statePathOrigin == .applicationSupportDefault
    }

    public var legacyStateMigrationJournal: String {
        URL(fileURLWithPath: layout.metadataDirectory, isDirectory: true)
            .appendingPathComponent("legacy-state-migration.json")
            .path
    }

    public func daemonLockPath(explicitLockPath: String? = nil) throws -> String {
        if let explicitLockPath {
            return try HostwrightLocalPathResolver.normalizedAbsolutePath(
                explicitLockPath,
                role: "daemon lock override"
            )
        }
        if usesApplicationSupportState {
            return layout.daemonLock
        }
        let digest = SHA256.hash(data: Data(stateDatabasePath.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return URL(fileURLWithPath: layout.runtimeDirectory, isDirectory: true)
            .appendingPathComponent("hostwrightd-\(digest).lock")
            .path
    }
}

public enum HostwrightLocalPathError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidPath(role: String, path: String, reason: String)
    case invalidEnvironmentOverride(name: String, reason: String)

    public var description: String {
        switch self {
        case .invalidPath(let role, let path, let reason):
            return "Invalid \(role) path \(path): \(reason)"
        case .invalidEnvironmentOverride(let name, let reason):
            return "Invalid \(name) override: \(reason)"
        }
    }
}

public enum HostwrightLocalPathResolver {
    public static let applicationSupportOverride = "HOSTWRIGHT_APPLICATION_SUPPORT_DIR"
    public static let cacheOverride = "HOSTWRIGHT_CACHE_DIR"
    public static let logOverride = "HOSTWRIGHT_LOG_DIR"
    public static let stateDatabaseOverride = "HOSTWRIGHT_STATE_DB"

    public static func resolve(
        explicitStateDatabasePath: String? = nil,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> HostwrightLocalPathResolution {
        let home = try normalizedAbsolutePath(homeDirectory, role: "home directory")
        let defaultApplicationSupport = try normalizedAbsolutePath(
            URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Library/Application Support/Hostwright", isDirectory: true)
                .path,
            role: "default Application Support directory"
        )
        let defaultCache = try normalizedAbsolutePath(
            URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Library/Caches/Hostwright", isDirectory: true)
                .path,
            role: "default cache directory"
        )
        let defaultLogs = try normalizedAbsolutePath(
            URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Library/Logs/Hostwright", isDirectory: true)
                .path,
            role: "default log directory"
        )

        let applicationSupport = try directoryOverride(
            applicationSupportOverride,
            environment: environment,
            fallback: defaultApplicationSupport
        )
        let cache = try directoryOverride(cacheOverride, environment: environment, fallback: defaultCache)
        let logs = try directoryOverride(logOverride, environment: environment, fallback: defaultLogs)

        let configuration = try derivedPath(
            parent: applicationSupport,
            component: "config",
            role: "configuration directory"
        )
        let state = try derivedPath(
            parent: applicationSupport,
            component: "state",
            role: "state directory"
        )
        let runtime = try derivedPath(
            parent: applicationSupport,
            component: "run",
            role: "runtime directory"
        )
        let metadata = try derivedPath(
            parent: applicationSupport,
            component: "metadata",
            role: "metadata directory"
        )
        let backups = try derivedPath(
            parent: applicationSupport,
            component: "backups",
            role: "backups directory"
        )
        let defaultStateDatabase = try derivedPath(
            parent: state,
            component: "state.sqlite",
            role: "default state database"
        )
        let daemonLock = try derivedPath(
            parent: runtime,
            component: "hostwrightd.lock",
            role: "default daemon lock"
        )
        let controlSocket = try derivedPath(
            parent: runtime,
            component: "control-v2.sock",
            role: "default control socket"
        )

        let selectedStatePath: String
        let stateOrigin: HostwrightStatePathOrigin
        if let explicit = explicitStateDatabasePath {
            selectedStatePath = try normalizedAbsolutePath(explicit, role: "state database")
            stateOrigin = .explicit
        } else if let override = try pathOverride(
            stateDatabaseOverride,
            role: "state database environment override",
            environment: environment
        ) {
            selectedStatePath = override
            stateOrigin = .environment
        } else {
            selectedStatePath = defaultStateDatabase
            stateOrigin = .applicationSupportDefault
        }

        let layout = HostwrightLocalPathLayout(
            applicationSupportDirectory: applicationSupport,
            configurationDirectory: configuration,
            stateDirectory: state,
            runtimeDirectory: runtime,
            metadataDirectory: metadata,
            backupsDirectory: backups,
            cacheDirectory: cache,
            logDirectory: logs,
            stateDatabase: defaultStateDatabase,
            daemonLock: daemonLock,
            controlSocket: controlSocket
        )
        let legacyRoot = try derivedPath(
            parent: home,
            component: ".hostwright",
            role: "legacy Hostwright directory"
        )
        let legacyState = try derivedPath(
            parent: legacyRoot,
            component: "state.sqlite",
            role: "legacy state database"
        )
        return HostwrightLocalPathResolution(
            layout: layout,
            stateDatabasePath: selectedStatePath,
            statePathOrigin: stateOrigin,
            legacyRootDirectory: legacyRoot,
            legacyStateDatabase: legacyState
        )
    }

    public static func normalizedAbsolutePath(_ rawPath: String, role: String) throws -> String {
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HostwrightLocalPathError.invalidPath(role: role, path: rawPath, reason: "the path is empty")
        }
        guard rawPath == rawPath.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw HostwrightLocalPathError.invalidPath(
                role: role,
                path: rawPath,
                reason: "leading or trailing whitespace is not allowed"
            )
        }
        let path = rawPath
        guard path.utf8.count < Int(PATH_MAX) else {
            throw HostwrightLocalPathError.invalidPath(
                role: role,
                path: path,
                reason: "the path exceeds \(PATH_MAX) bytes"
            )
        }
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\0") else {
            throw HostwrightLocalPathError.invalidPath(role: role, path: path, reason: "an absolute normalized path is required")
        }
        guard path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            throw HostwrightLocalPathError.invalidPath(role: role, path: path, reason: "control characters are not allowed")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("."), !components.contains("..") else {
            throw HostwrightLocalPathError.invalidPath(role: role, path: path, reason: "dot and parent traversal components are not allowed")
        }
        guard components.allSatisfy({ $0.utf8.count <= Int(NAME_MAX) }) else {
            throw HostwrightLocalPathError.invalidPath(
                role: role,
                path: path,
                reason: "a path component exceeds \(NAME_MAX) bytes"
            )
        }
        let normalized = "/" + components.joined(separator: "/")
        guard normalized == path else {
            throw HostwrightLocalPathError.invalidPath(
                role: role,
                path: path,
                reason: "duplicate or trailing separators are not allowed"
            )
        }
        return normalized
    }

    private static func directoryOverride(
        _ name: String,
        environment: [String: String],
        fallback: String
    ) throws -> String {
        try pathOverride(
            name,
            role: "\(name) directory override",
            environment: environment
        ) ?? fallback
    }

    private static func derivedPath(
        parent: String,
        component: String,
        role: String
    ) throws -> String {
        try normalizedAbsolutePath(
            URL(fileURLWithPath: parent, isDirectory: true)
                .appendingPathComponent(component)
                .path,
            role: role
        )
    }

    private static func pathOverride(
        _ name: String,
        role: String,
        environment: [String: String]
    ) throws -> String? {
        guard let value = environment[name] else { return nil }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HostwrightLocalPathError.invalidEnvironmentOverride(
                name: name,
                reason: "the value is empty"
            )
        }
        do {
            return try normalizedAbsolutePath(value, role: role)
        } catch {
            throw HostwrightLocalPathError.invalidEnvironmentOverride(name: name, reason: String(describing: error))
        }
    }
}

package enum HostwrightLocalFilesystemPolicy {
    package static func validateNoAccessGrantingACL(
        atPath path: String,
        role: String
    ) throws {
        errno = 0
        guard let accessControlList = acl_get_file(path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP { return }
            throw HostwrightLocalPathError.invalidPath(
                role: role,
                path: path,
                reason: "the extended ACL could not be inspected: \(String(cString: strerror(errno)))"
            )
        }
        defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
        try validate(
            accessControlList,
            path: path,
            role: role
        )
    }

    package static func validateNoAccessGrantingACL(
        fileDescriptor: Int32,
        path: String,
        role: String
    ) throws {
        errno = 0
        guard let accessControlList = acl_get_fd_np(fileDescriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP { return }
            throw HostwrightLocalPathError.invalidPath(
                role: role,
                path: path,
                reason: "the extended ACL could not be inspected: \(String(cString: strerror(errno)))"
            )
        }
        defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
        try validate(
            accessControlList,
            path: path,
            role: role
        )
    }

    package static func canonicalExistingPath(
        _ path: String,
        role: String
    ) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw HostwrightLocalPathError.invalidPath(
                role: role,
                path: path,
                reason: "the canonical path could not be resolved: \(String(cString: strerror(errno)))"
            )
        }
        defer { free(resolved) }
        return try HostwrightLocalPathResolver.normalizedAbsolutePath(
            String(cString: resolved),
            role: role
        )
    }

    private static func validate(
        _ accessControlList: acl_t,
        path: String,
        role: String
    ) throws {
        var entry: acl_entry_t?
        var entryID = ACL_FIRST_ENTRY.rawValue
        while true {
            errno = 0
            let result = acl_get_entry(accessControlList, entryID, &entry)
            if result != 0 {
                if errno == EINVAL { return }
                throw HostwrightLocalPathError.invalidPath(
                    role: role,
                    path: path,
                    reason: "the extended ACL entries could not be inspected: \(String(cString: strerror(errno)))"
                )
            }
            guard let entry else {
                throw HostwrightLocalPathError.invalidPath(
                    role: role,
                    path: path,
                    reason: "the extended ACL returned an invalid entry"
                )
            }

            var tag = acl_tag_t(0)
            guard acl_get_tag_type(entry, &tag) == 0 else {
                throw HostwrightLocalPathError.invalidPath(
                    role: role,
                    path: path,
                    reason: "the extended ACL tag could not be inspected: \(String(cString: strerror(errno)))"
                )
            }
            guard tag == ACL_EXTENDED_DENY else {
                throw HostwrightLocalPathError.invalidPath(
                    role: role,
                    path: path,
                    reason: "access-granting or unrecognized extended ACL entries are rejected"
                )
            }
            entryID = ACL_NEXT_ENTRY.rawValue
        }
    }
}
