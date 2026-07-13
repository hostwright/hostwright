import Darwin
import Foundation

public enum SecureExecutableOwnershipPolicy: Equatable, Sendable {
    case rootOnly
    case rootOrCurrentUser
}

public struct SecureExecutableIdentity: Equatable, Sendable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    public let ownerUserID: UInt32
    public let mode: UInt16
    public let sizeBytes: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    public let ownershipPolicy: SecureExecutableOwnershipPolicy

    public init(
        path: String,
        device: UInt64,
        inode: UInt64,
        ownerUserID: UInt32,
        mode: UInt16,
        sizeBytes: UInt64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64,
        changedSeconds: Int64,
        changedNanoseconds: Int64,
        ownershipPolicy: SecureExecutableOwnershipPolicy
    ) {
        self.path = path
        self.device = device
        self.inode = inode
        self.ownerUserID = ownerUserID
        self.mode = mode
        self.sizeBytes = sizeBytes
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds
        self.changedNanoseconds = changedNanoseconds
        self.ownershipPolicy = ownershipPolicy
    }
}

public enum SecureExecutableValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidName
    case invalidPath
    case pathDoesNotExist
    case unsafeOwnership
    case unsafePermissions
    case unsupportedFileType
    case notExecutable
    case setIDExecutable
    case interpreterExecutable
    case metadataChanged
    case systemFailure(Int32)

    public var description: String {
        switch self {
        case .invalidName: "Executable name is invalid."
        case .invalidPath: "Executable path is invalid."
        case .pathDoesNotExist: "Executable path does not exist."
        case .unsafeOwnership: "Executable path ownership is unsafe."
        case .unsafePermissions: "Executable path permissions are unsafe."
        case .unsupportedFileType: "Executable path is not a supported regular file."
        case .notExecutable: "Executable path is not executable by the current user."
        case .setIDExecutable: "Set-user-ID and set-group-ID executables are refused."
        case .interpreterExecutable: "Shell and environment-dispatch executables are refused."
        case .metadataChanged: "Executable identity changed before launch."
        case .systemFailure(let code): "Executable validation failed with system error \(code)."
        }
    }
}

public enum SecureExecutableResolver {
    private static let refusedExecutableNames: Set<String> = [
        "bash", "csh", "dash", "env", "fish", "ksh", "sh", "tcsh", "zsh"
    ]

    public static func resolve(
        named name: String,
        searchPath: String?,
        ownershipPolicy: SecureExecutableOwnershipPolicy = .rootOnly
    ) throws -> SecureExecutableIdentity? {
        guard isValidExecutableName(name) else {
            throw SecureExecutableValidationError.invalidName
        }
        guard let searchPath else { return nil }

        for rawDirectory in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = String(rawDirectory)
            guard isValidAbsolutePath(directory) else {
                throw SecureExecutableValidationError.invalidPath
            }
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path
            var metadata = stat()
            if lstat(candidate, &metadata) != 0 {
                if errno == ENOENT || errno == ENOTDIR { continue }
                throw SecureExecutableValidationError.systemFailure(errno)
            }
            return try verify(path: candidate, ownershipPolicy: ownershipPolicy)
        }
        return nil
    }

    public static func verify(
        path: String,
        ownershipPolicy: SecureExecutableOwnershipPolicy = .rootOrCurrentUser
    ) throws -> SecureExecutableIdentity {
        guard isValidAbsolutePath(path) else {
            throw SecureExecutableValidationError.invalidPath
        }

        let lexicalPath = path
        try validatePathChain(lexicalPath, ownershipPolicy: ownershipPolicy)

        var originalMetadata = stat()
        guard lstat(lexicalPath, &originalMetadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                throw SecureExecutableValidationError.pathDoesNotExist
            }
            throw SecureExecutableValidationError.systemFailure(errno)
        }
        try validateOwner(originalMetadata.st_uid, ownershipPolicy: ownershipPolicy)
        if (originalMetadata.st_mode & S_IFMT) != S_IFREG,
           (originalMetadata.st_mode & S_IFMT) != S_IFLNK {
            throw SecureExecutableValidationError.unsupportedFileType
        }

        let canonicalPath = try canonicalize(lexicalPath)
        try validatePathChain(canonicalPath, ownershipPolicy: ownershipPolicy)
        if refusedExecutableNames.contains(URL(fileURLWithPath: canonicalPath).lastPathComponent.lowercased()) {
            throw SecureExecutableValidationError.interpreterExecutable
        }

        let descriptor = open(canonicalPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw SecureExecutableValidationError.unsupportedFileType
            }
            throw SecureExecutableValidationError.systemFailure(errno)
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw SecureExecutableValidationError.systemFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_size > 0 else {
            throw SecureExecutableValidationError.unsupportedFileType
        }
        try validateOwner(metadata.st_uid, ownershipPolicy: ownershipPolicy)
        guard metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw SecureExecutableValidationError.unsafePermissions
        }
        guard metadata.st_mode & (S_ISUID | S_ISGID) == 0 else {
            throw SecureExecutableValidationError.setIDExecutable
        }
        guard metadata.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0,
              access(canonicalPath, X_OK) == 0 else {
            throw SecureExecutableValidationError.notExecutable
        }

        var magic = [UInt8](repeating: 0, count: 2)
        let magicCount = pread(descriptor, &magic, magic.count, 0)
        guard magicCount >= 0 else {
            throw SecureExecutableValidationError.systemFailure(errno)
        }
        if magicCount == 2, magic[0] == UInt8(ascii: "#"), magic[1] == UInt8(ascii: "!") {
            throw SecureExecutableValidationError.interpreterExecutable
        }

        return identity(path: canonicalPath, metadata: metadata, ownershipPolicy: ownershipPolicy)
    }

    public static func verifyUnchanged(_ identity: SecureExecutableIdentity) throws {
        let current = try verify(path: identity.path, ownershipPolicy: identity.ownershipPolicy)
        guard current == identity else {
            throw SecureExecutableValidationError.metadataChanged
        }
    }

    public static func verifyWorkingDirectory(path: String) throws -> String {
        let handle = try openWorkingDirectory(path: path)
        defer { close(handle.descriptor) }
        return handle.path
    }

    static func openWorkingDirectory(path: String) throws -> (path: String, descriptor: Int32) {
        guard isValidAbsolutePath(path) else {
            throw SecureExecutableValidationError.invalidPath
        }
        let lexicalPath = path
        try validatePathChain(
            lexicalPath == "/" ? "/placeholder" : lexicalPath + "/placeholder",
            ownershipPolicy: .rootOrCurrentUser
        )
        let canonicalPath = try canonicalize(lexicalPath)
        try validatePathChain(
            canonicalPath == "/" ? "/placeholder" : canonicalPath + "/placeholder",
            ownershipPolicy: .rootOrCurrentUser
        )

        let descriptor = open(canonicalPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SecureExecutableValidationError.systemFailure(errno)
        }
        var accepted = false
        defer { if !accepted { close(descriptor) } }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw SecureExecutableValidationError.systemFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw SecureExecutableValidationError.unsupportedFileType
        }
        try validateOwner(metadata.st_uid, ownershipPolicy: .rootOrCurrentUser)
        if metadata.st_mode & (S_IWGRP | S_IWOTH) != 0 {
            let isRootOwnedStickyDirectory = metadata.st_uid == 0 && metadata.st_mode & S_ISVTX != 0
            guard isRootOwnedStickyDirectory else {
                throw SecureExecutableValidationError.unsafePermissions
            }
        }
        accepted = true
        return (canonicalPath, descriptor)
    }

    private static func isValidExecutableName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), name.utf8.count <= 255 else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x20 && scalar.value != 0x7f
        }
    }

    static func isValidAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= Int(PATH_MAX) else {
            return false
        }
        guard path.unicodeScalars.allSatisfy({ scalar in
            scalar.value >= 0x20 && scalar.value != 0x7f
        }) else { return false }
        if path == "/" { return true }
        guard !path.hasSuffix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first?.isEmpty == true else { return false }
        return components.dropFirst().allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private static func canonicalize(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            if errno == ENOENT || errno == ENOTDIR {
                throw SecureExecutableValidationError.pathDoesNotExist
            }
            throw SecureExecutableValidationError.systemFailure(errno)
        }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        guard isValidAbsolutePath(canonical) else {
            throw SecureExecutableValidationError.invalidPath
        }
        return canonical
    }

    private static func validatePathChain(
        _ path: String,
        ownershipPolicy: SecureExecutableOwnershipPolicy
    ) throws {
        let components = path.split(separator: "/").map(String.init)
        var current = "/"
        try validateDirectoryOrLink(current, ownershipPolicy: ownershipPolicy)
        for component in components.dropLast() {
            current = URL(fileURLWithPath: current, isDirectory: true)
                .appendingPathComponent(component, isDirectory: true)
                .path
            try validateDirectoryOrLink(current, ownershipPolicy: ownershipPolicy)
        }
    }

    private static func validateDirectoryOrLink(
        _ path: String,
        ownershipPolicy: SecureExecutableOwnershipPolicy
    ) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw SecureExecutableValidationError.systemFailure(errno)
        }
        try validateOwner(metadata.st_uid, ownershipPolicy: ownershipPolicy)
        let type = metadata.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFLNK else {
            throw SecureExecutableValidationError.unsupportedFileType
        }
        if type == S_IFDIR, metadata.st_mode & (S_IWGRP | S_IWOTH) != 0 {
            let isRootOwnedStickyDirectory = metadata.st_uid == 0 && metadata.st_mode & S_ISVTX != 0
            guard isRootOwnedStickyDirectory else {
                throw SecureExecutableValidationError.unsafePermissions
            }
        }
    }

    private static func validateOwner(
        _ owner: uid_t,
        ownershipPolicy: SecureExecutableOwnershipPolicy
    ) throws {
        let accepted = switch ownershipPolicy {
        case .rootOnly: owner == 0
        case .rootOrCurrentUser: owner == 0 || owner == geteuid()
        }
        guard accepted else {
            throw SecureExecutableValidationError.unsafeOwnership
        }
    }

    private static func identity(
        path: String,
        metadata: stat,
        ownershipPolicy: SecureExecutableOwnershipPolicy
    ) -> SecureExecutableIdentity {
        SecureExecutableIdentity(
            path: path,
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            ownerUserID: UInt32(metadata.st_uid),
            mode: UInt16(metadata.st_mode & 0o7777),
            sizeBytes: UInt64(metadata.st_size),
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec),
            ownershipPolicy: ownershipPolicy
        )
    }
}

public enum SecureSubprocessEnvironment {
    public static let trustedSystemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public static let minimal: [String: String] = [
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": trustedSystemPath
    ]

    public static var currentUser: [String: String] {
        var environment = minimal
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if home.hasPrefix("/"), !home.contains("\0") {
            environment["HOME"] = home
        }
        return environment
    }
}
