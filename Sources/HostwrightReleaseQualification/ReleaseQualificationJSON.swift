import CryptoKit
import Darwin
import Foundation

public enum ReleaseQualificationJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        if let validating = value as? any ReleaseQualificationValidating {
            try validating.validate()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= ReleaseQualificationLimits.maximumJSONBytes else {
            throw ReleaseQualificationContractError.oversizedInput
        }
        return data
    }

    public static func decode<T: Decodable & Encodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty, data.count <= ReleaseQualificationLimits.maximumJSONBytes else {
            throw ReleaseQualificationContractError.oversizedInput
        }
        let decoder = JSONDecoder()
        let value = try decoder.decode(type, from: data)
        if let validating = value as? any ReleaseQualificationValidating {
            try validating.validate()
        }
        guard try encode(value) == data else {
            throw ReleaseQualificationContractError.nonCanonicalJSON
        }
        return value
    }

    public static func decode<T: Decodable & Encodable>(
        _ type: T.Type,
        from url: URL
    ) throws -> T {
        guard ReleaseQualificationPath.isNormalizedAbsolute(url.path),
              try ReleaseQualificationFile.isRegularNonSymlink(url) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0,
              size <= ReleaseQualificationLimits.maximumJSONBytes else {
            throw ReleaseQualificationContractError.oversizedInput
        }
        return try decode(type, from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func writeCanonical<T: Encodable>(
        _ value: T,
        to url: URL,
        mode: Int16 = 0o600,
        replaceExisting: Bool = false
    ) throws {
        let data = try encode(value)
        try ReleaseQualificationFile.writeAtomically(
            data: data,
            to: url,
            mode: mode,
            createParent: false,
            replaceExisting: replaceExisting
        )
    }
}

public enum ReleaseQualificationHash {
    public static func sha256(data: Data) -> ReleaseQualificationSHA256 {
        ReleaseQualificationSHA256(data: data)
    }

    public static func sha256(fileURL: URL) throws -> ReleaseQualificationSHA256 {
        sha256(data: try ReleaseQualificationFile.readBoundedRegularFile(fileURL))
    }
}

public enum ReleaseQualificationFile {
    public static func readBoundedRegularFile(
        _ url: URL,
        maximumBytes: Int = ReleaseQualificationLimits.maximumSourceFileBytes
    ) throws -> Data {
        guard ReleaseQualificationPath.isNormalizedAbsolute(url.path),
              (0...ReleaseQualificationLimits.maximumSourceFileBytes).contains(maximumBytes) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ReleaseQualificationContractError.unsafePath
        }
        defer { Darwin.close(descriptor) }

        return try readBoundedRegularFile(
            descriptor: descriptor,
            maximumBytes: maximumBytes
        ) { named in
            Darwin.lstat(url.path, &named)
        }
    }

    public static func readBoundedRegularFile(
        relativePath: String,
        under rootURL: URL,
        maximumBytes: Int = ReleaseQualificationLimits.maximumSourceFileBytes
    ) throws -> Data {
        guard ReleaseQualificationPath.isNormalizedAbsolute(rootURL.path),
              ReleaseQualificationPath.isSafeRelative(relativePath),
              (0...ReleaseQualificationLimits.maximumSourceFileBytes).contains(maximumBytes) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        let components = relativePath.split(separator: "/").map(String.init)
        guard let finalName = components.last else {
            throw ReleaseQualificationContractError.unsafePath
        }
        var directory = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw ReleaseQualificationContractError.unsafePath
        }
        defer { Darwin.close(directory) }

        for component in components.dropLast() {
            let child = component.withCString {
                Darwin.openat(
                    directory,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard child >= 0 else {
                throw ReleaseQualificationContractError.unsafePath
            }
            var metadata = stat()
            guard Darwin.fstat(child, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR else {
                Darwin.close(child)
                throw ReleaseQualificationContractError.unsafePath
            }
            Darwin.close(directory)
            directory = child
        }

        let descriptor = finalName.withCString {
            Darwin.openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ReleaseQualificationContractError.unsafePath
        }
        defer { Darwin.close(descriptor) }
        return try readBoundedRegularFile(
            descriptor: descriptor,
            maximumBytes: maximumBytes
        ) { named in
            finalName.withCString {
                Darwin.fstatat(directory, $0, &named, AT_SYMLINK_NOFOLLOW)
            }
        }
    }

    private static func readBoundedRegularFile(
        descriptor: Int32,
        maximumBytes: Int,
        namedMetadata: (inout stat) -> Int32
    ) throws -> Data {

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG else {
            throw ReleaseQualificationContractError.unsafePath
        }
        guard before.st_size >= 0,
              before.st_size <= Int64(maximumBytes) else {
            throw ReleaseQualificationContractError.oversizedInput
        }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ReleaseQualificationContractError.unsafePath
            }
            guard data.count + count <= maximumBytes else {
                throw ReleaseQualificationContractError.oversizedInput
            }
            data.append(buffer, count: count)
        }

        var after = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              namedMetadata(&named) == 0,
              sameIdentity(before, after),
              sameIdentity(after, named),
              Int64(data.count) == after.st_size else {
            throw ReleaseQualificationContractError.tamperedEvidence
        }
        return data
    }

    public static func isRegularNonSymlink(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                return false
            }
            throw ReleaseQualificationContractError.invalid(
                field: "file",
                reason: "file metadata could not be read"
            )
        }
        return metadata.st_mode & S_IFMT == S_IFREG
    }

    public static func isDirectory(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                return false
            }
            throw ReleaseQualificationContractError.invalid(
                field: "directory",
                reason: "directory metadata could not be read"
            )
        }
        return metadata.st_mode & S_IFMT == S_IFDIR
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_mode & S_IFMT == S_IFREG &&
            rhs.st_mode & S_IFMT == S_IFREG &&
            lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_uid == rhs.st_uid &&
            lhs.st_nlink == rhs.st_nlink &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    public static func validatePrivateDirectory(_ url: URL) throws {
        guard ReleaseQualificationPath.isNormalizedAbsolute(url.path),
              try isDirectory(url) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
              permissions & 0o777 == 0o700,
              owner == UInt32(geteuid()) else {
            throw ReleaseQualificationContractError.unsafePath
        }
    }

    public static func writeAtomically(
        data: Data,
        to url: URL,
        mode: Int16,
        createParent: Bool,
        replaceExisting: Bool = false
    ) throws {
        guard ReleaseQualificationPath.isNormalizedAbsolute(url.path),
              data.count <= ReleaseQualificationLimits.maximumJSONBytes else {
            throw ReleaseQualificationContractError.unsafePath
        }
        let parent = url.deletingLastPathComponent()
        if createParent, !(try isDirectory(parent)) {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try validateParent(parent)
        if !replaceExisting {
            var existing = stat()
            guard lstat(url.path, &existing) != 0, errno == ENOENT else {
                throw ReleaseQualificationContractError.invalid(
                    field: "output",
                    reason: "atomic output already exists"
                )
            }
        } else {
            var existing = stat()
            if lstat(url.path, &existing) == 0 {
                guard existing.st_mode & S_IFMT == S_IFREG else {
                    throw ReleaseQualificationContractError.unsafePath
                }
            } else {
                guard errno == ENOENT else {
                    throw ReleaseQualificationContractError.unsafePath
                }
            }
        }

        let temporary = parent.appendingPathComponent(
            ".hostwright-release-qualification.tmp.\(UUID().uuidString.lowercased())"
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(mode)
        )
        guard descriptor >= 0 else {
            throw ReleaseQualificationContractError.invalid(
                field: "output",
                reason: "temporary evidence file could not be created"
            )
        }
        var committed = false
        defer {
            Darwin.close(descriptor)
            if !committed {
                _ = Darwin.unlink(temporary.path)
            }
        }

        guard fchmod(descriptor, mode_t(mode)) == 0 else {
            throw ReleaseQualificationContractError.invalid(
                field: "output",
                reason: "temporary evidence permissions could not be set"
            )
        }
        try writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else {
            throw ReleaseQualificationContractError.invalid(
                field: "output",
                reason: "temporary evidence could not be synchronized"
            )
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw ReleaseQualificationContractError.invalid(
                field: "output",
                reason: "atomic evidence publication failed"
            )
        }
        committed = true
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if parentDescriptor >= 0 {
            _ = fsync(parentDescriptor)
            Darwin.close(parentDescriptor)
        }
    }

    private static func validateParent(_ parent: URL) throws {
        guard ReleaseQualificationPath.isNormalizedAbsolute(parent.path),
              try isDirectory(parent) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        let values = try parent.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ReleaseQualificationContractError.unsafePath
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else {
                    throw ReleaseQualificationContractError.invalid(
                        field: "output",
                        reason: "evidence write was incomplete"
                    )
                }
                offset += amount
            }
        }
    }
}
