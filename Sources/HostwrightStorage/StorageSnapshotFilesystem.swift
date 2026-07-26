import CryptoKit
import Foundation

struct StorageSnapshotTreeDigest: Equatable, Sendable {
    let sha256: String
    let bytes: Int64
}

enum StorageSnapshotFilesystem {
    static func ensurePrivateRoot(_ url: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try requireDirectory(url)
        try setMode(url, mode: 0o700)
    }

    static func requireDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw StorageSnapshotError.ioFailure
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw StorageSnapshotError.unsafePath
        }
    }

    static func setMode(_ url: URL, mode: mode_t) throws {
        guard chmod(url.path, mode) == 0 else {
            throw StorageSnapshotError.ioFailure
        }
    }

    static func canonicalFileURL(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        return standardized.resolvingSymlinksInPath()
    }

    static func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func atomicMove(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw StorageSnapshotError.ioFailure
        }
    }

    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    static func writeAtomicJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: temporary, options: .atomic)
        try setMode(temporary, mode: 0o600)
        try atomicMove(temporary, to: url)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    static func copyTree(
        from sourceRoot: URL,
        to destinationRoot: URL,
        hooks: StorageSnapshotHooks
    ) throws -> StorageSnapshotTreeDigest {
        try requireDirectory(sourceRoot)
        let rootPermissions = try permissionMode(at: sourceRoot)
        try makeDirectory(destinationRoot)
        let rootFD = try openDirectory(sourceRoot)
        defer { close(rootFD) }
        var hasher = SHA256()
        var totalBytes: Int64 = 0
        try updateHash(
            relativePath: "",
            kind: "dir",
            permissions: rootPermissions,
            contentDigest: "",
            hasher: &hasher
        )
        try walkDirectory(
            directoryFD: rootFD,
            relativePath: "",
            destinationRoot: destinationRoot,
            hasher: &hasher,
            totalBytes: &totalBytes,
            hooks: hooks
        )
        try setDirectoryMode(destinationRoot, mode: rootPermissions)
        return StorageSnapshotTreeDigest(
            sha256: hasher.finalize().hexDigest,
            bytes: totalBytes
        )
    }

    static func hashTree(
        at root: URL,
        hooks: StorageSnapshotHooks
    ) throws -> StorageSnapshotTreeDigest {
        try requireDirectory(root)
        let rootPermissions = try permissionMode(at: root)
        let rootFD = try openDirectory(root)
        defer { close(rootFD) }
        var hasher = SHA256()
        var totalBytes: Int64 = 0
        try updateHash(
            relativePath: "",
            kind: "dir",
            permissions: rootPermissions,
            contentDigest: "",
            hasher: &hasher
        )
        try hashDirectory(
            directoryFD: rootFD,
            relativePath: "",
            hasher: &hasher,
            totalBytes: &totalBytes,
            hooks: hooks
        )
        return StorageSnapshotTreeDigest(
            sha256: hasher.finalize().hexDigest,
            bytes: totalBytes
        )
    }

    static func ensureAbsentPath(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw StorageSnapshotError.destinationExists
        }
    }

    static func ensureSafeParent(_ parent: URL) throws {
        let resolved = try canonicalFileURL(parent)
        try requireDirectory(resolved)
        guard resolved.path == parent.standardizedFileURL.path else {
            throw StorageSnapshotError.wrongParent
        }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw StorageSnapshotError.ioFailure
        }
        return descriptor
    }

    private static func permissionMode(at url: URL) throws -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw StorageSnapshotError.ioFailure
        }
        return metadata.st_mode & 0o7777
    }

    private static func setDirectoryMode(
        _ url: URL,
        mode: mode_t
    ) throws {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw StorageSnapshotError.ioFailure
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode) == 0 else {
            throw StorageSnapshotError.ioFailure
        }
    }

    private static func walkDirectory(
        directoryFD: Int32,
        relativePath: String,
        destinationRoot: URL,
        hasher: inout SHA256,
        totalBytes: inout Int64,
        hooks: StorageSnapshotHooks
    ) throws {
        try checkCancelled(hooks)
        let entries = try listEntries(directoryFD: directoryFD)
        for entry in entries {
            try checkCancelled(hooks)
            var metadata = stat()
            guard fstatat(directoryFD, entry, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw StorageSnapshotError.ioFailure
            }
            let name = stringFromCStringArray(entry)
            let childRelative = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            let kind = metadata.st_mode & S_IFMT
            let permissions = metadata.st_mode & 0o7777
            if kind == S_IFLNK || kind == S_IFCHR || kind == S_IFBLK || kind == S_IFSOCK || kind == S_IFIFO {
                throw StorageSnapshotError.unsafePath
            }
            if kind == S_IFDIR {
                let destination = destinationRoot.appendingPathComponent(childRelative, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try updateHash(
                    relativePath: childRelative,
                    kind: "dir",
                    permissions: permissions,
                    contentDigest: "",
                    hasher: &hasher
                )
                let childFD = openat(directoryFD, entry, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
                guard childFD >= 0 else {
                    throw StorageSnapshotError.ioFailure
                }
                defer { close(childFD) }
                try walkDirectory(
                    directoryFD: childFD,
                    relativePath: childRelative,
                    destinationRoot: destinationRoot,
                    hasher: &hasher,
                    totalBytes: &totalBytes,
                    hooks: hooks
                )
                try setDirectoryMode(destination, mode: permissions)
                continue
            }
            guard kind == S_IFREG, metadata.st_nlink == 1 else {
                throw StorageSnapshotError.unsafePath
            }
            let sourceFD = openat(directoryFD, entry, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard sourceFD >= 0 else {
                throw StorageSnapshotError.ioFailure
            }
            defer { close(sourceFD) }
            let destination = destinationRoot.appendingPathComponent(childRelative, isDirectory: false)
            if let parent = destination.deletingLastPathComponent() as URL? {
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let destinationFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard destinationFD >= 0 else {
                throw StorageSnapshotError.ioFailure
            }
            defer { close(destinationFD) }
            let digest = try copyRegularFile(
                from: sourceFD,
                to: destinationFD,
                permissions: permissions,
                hooks: hooks
            )
            totalBytes += Int64(metadata.st_size)
            try updateHash(
                relativePath: childRelative,
                kind: "file",
                permissions: permissions,
                contentDigest: digest,
                hasher: &hasher
            )
        }
    }

    private static func hashDirectory(
        directoryFD: Int32,
        relativePath: String,
        hasher: inout SHA256,
        totalBytes: inout Int64,
        hooks: StorageSnapshotHooks
    ) throws {
        try checkCancelled(hooks)
        let entries = try listEntries(directoryFD: directoryFD)
        for entry in entries {
            try checkCancelled(hooks)
            var metadata = stat()
            guard fstatat(directoryFD, entry, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw StorageSnapshotError.ioFailure
            }
            let name = stringFromCStringArray(entry)
            let childRelative = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            let kind = metadata.st_mode & S_IFMT
            let permissions = metadata.st_mode & 0o7777
            if kind == S_IFLNK || kind == S_IFCHR || kind == S_IFBLK || kind == S_IFSOCK || kind == S_IFIFO {
                throw StorageSnapshotError.unsafePath
            }
            if kind == S_IFDIR {
                try updateHash(
                    relativePath: childRelative,
                    kind: "dir",
                    permissions: permissions,
                    contentDigest: "",
                    hasher: &hasher
                )
                let childFD = openat(directoryFD, entry, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
                guard childFD >= 0 else {
                    throw StorageSnapshotError.ioFailure
                }
                defer { close(childFD) }
                try hashDirectory(
                    directoryFD: childFD,
                    relativePath: childRelative,
                    hasher: &hasher,
                    totalBytes: &totalBytes,
                    hooks: hooks
                )
                continue
            }
            guard kind == S_IFREG, metadata.st_nlink == 1 else {
                throw StorageSnapshotError.unsafePath
            }
            let fileFD = openat(directoryFD, entry, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fileFD >= 0 else {
                throw StorageSnapshotError.ioFailure
            }
            defer { close(fileFD) }
            let digest = try hashRegularFile(fileFD: fileFD, hooks: hooks)
            totalBytes += Int64(metadata.st_size)
            try updateHash(
                relativePath: childRelative,
                kind: "file",
                permissions: permissions,
                contentDigest: digest,
                hasher: &hasher
            )
        }
    }

    private static func listEntries(directoryFD: Int32) throws -> [[CChar]] {
        let duplicated = dup(directoryFD)
        guard duplicated >= 0 else {
            throw StorageSnapshotError.ioFailure
        }
        guard let directory = fdopendir(duplicated) else {
            close(duplicated)
            throw StorageSnapshotError.ioFailure
        }
        defer { closedir(directory) }
        var names: [[CChar]] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." {
                continue
            }
            names.append(Array(name.utf8CString))
        }
        names.sort { stringFromCStringArray($0) < stringFromCStringArray($1) }
        return names
    }

    private static func hashRegularFile(
        fileFD: Int32,
        hooks: StorageSnapshotHooks
    ) throws -> String {
        guard lseek(fileFD, 0, SEEK_SET) >= 0 else {
            throw StorageSnapshotError.ioFailure
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try checkCancelled(hooks)
            let count = read(fileFD, &buffer, buffer.count)
            if count < 0 {
                throw StorageSnapshotError.ioFailure
            }
            if count == 0 {
                break
            }
            buffer.withUnsafeBytes { bytes in
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(
                        rebasing: bytes[..<count]
                    )
                )
            }
        }
        return hasher.finalize().hexDigest
    }

    private static func copyRegularFile(
        from sourceFD: Int32,
        to destinationFD: Int32,
        permissions: mode_t,
        hooks: StorageSnapshotHooks
    ) throws -> String {
        guard lseek(sourceFD, 0, SEEK_SET) >= 0 else {
            throw StorageSnapshotError.ioFailure
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try checkCancelled(hooks)
            let count = read(sourceFD, &buffer, buffer.count)
            if count < 0 {
                throw StorageSnapshotError.ioFailure
            }
            if count == 0 {
                break
            }
            buffer.withUnsafeBytes { bytes in
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(
                        rebasing: bytes[..<count]
                    )
                )
            }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { bytes in
                    write(destinationFD, bytes.baseAddress!.advanced(by: written), count - written)
                }
                if result < 0 {
                    throw StorageSnapshotError.ioFailure
                }
                written += result
            }
        }
        guard fchmod(destinationFD, permissions) == 0 else {
            throw StorageSnapshotError.ioFailure
        }
        guard fsync(destinationFD) == 0 else {
            throw StorageSnapshotError.ioFailure
        }
        return hasher.finalize().hexDigest
    }

    private static func updateHash(
        relativePath: String,
        kind: String,
        permissions: mode_t,
        contentDigest: String,
        hasher: inout SHA256
    ) throws {
        let mode = String(format: "%04o", UInt32(permissions))
        let line = "\(kind)\t\(relativePath)\t\(mode)\t\(contentDigest)\n"
        hasher.update(data: Data(line.utf8))
    }

    private static func checkCancelled(_ hooks: StorageSnapshotHooks) throws {
        if hooks.isCancelled() {
            throw StorageSnapshotError.cancelled
        }
    }
}

private extension SHA256Digest {
    var hexDigest: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension SHA256 {
    mutating func update(bufferPointer: UnsafeRawBufferPointer) {
        if let baseAddress = bufferPointer.baseAddress, bufferPointer.count > 0 {
            update(data: Data(bytes: baseAddress, count: bufferPointer.count))
        }
    }
}

private func stringFromCStringArray(_ value: [CChar]) -> String {
    value.withUnsafeBufferPointer { pointer in
        String(cString: pointer.baseAddress!)
    }
}
