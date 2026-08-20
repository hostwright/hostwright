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
        guard try ReleaseQualificationFile.isRegularNonSymlink(fileURL) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue,
              size >= 0,
              size <= ReleaseQualificationLimits.maximumSourceFileBytes else {
            throw ReleaseQualificationContractError.oversizedInput
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while true {
            let chunk = try handle.read(upToCount: 1 * 1_024 * 1_024) ?? Data()
            guard !chunk.isEmpty else { break }
            total += chunk.count
            guard total <= ReleaseQualificationLimits.maximumSourceFileBytes else {
                throw ReleaseQualificationContractError.oversizedInput
            }
            hasher.update(data: chunk)
        }
        return ReleaseQualificationSHA256(
            validatedValue: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }
}

public enum ReleaseQualificationFile {
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
