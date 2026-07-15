import CryptoKit
import Darwin
import Foundation

struct StateFileFingerprint: Equatable {
    let sha256: String
    let bytes: UInt64
    let device: UInt64
    let inode: UInt64
}

enum StateMaintenanceFileSupport {
    static func fingerprint(_ path: String) throws -> StateFileFingerprint {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw StateMaintenanceError.io(path: path, message: String(cString: strerror(errno)))
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw StateMaintenanceError.io(path: path, message: String(cString: strerror(errno)))
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == S_IRUSR | S_IWUSR else {
            throw StateMaintenanceError.io(
                path: path,
                message: "expected a singly linked invoking-user regular file with mode 0600"
            )
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw StateMaintenanceError.io(path: path, message: String(cString: strerror(errno)))
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return StateFileFingerprint(
            sha256: digest,
            bytes: UInt64(metadata.st_size),
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    static func token(_ components: [String]) -> String {
        let digest = SHA256.hash(data: Data(components.joined(separator: "\u{1f}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return digest
    }

    static func exists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }

    static func validateBackupID(_ backupID: String) throws {
        guard backupID.range(
            of: "^[a-z0-9][a-z0-9._-]{0,127}$",
            options: .regularExpression
        ) != nil,
        backupID != ".",
        backupID != "..",
        !backupID.hasPrefix(".partial-") else {
            throw StateMaintenanceError.invalidBackupID(backupID)
        }
    }

    static func synchronizeDirectory(_ path: String) throws {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw StateMaintenanceError.io(path: path, message: String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw StateMaintenanceError.io(path: path, message: String(cString: strerror(errno)))
        }
    }

    static func copyExactSensitiveFile(
        from sourcePath: String,
        to destinationPath: String,
        expectedSHA256: String,
        expectedBytes: UInt64,
        sourceChanged: (String) -> any Error
    ) throws {
        let before = try fingerprint(sourcePath)
        guard before.sha256 == expectedSHA256, before.bytes == expectedBytes else {
            throw sourceChanged("the source digest or size changed before copying")
        }
        try SecureStatePathManager().validateSensitiveRegularFile(destinationPath)

        let source = open(sourcePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else {
            throw StateMaintenanceError.io(
                path: sourcePath,
                message: String(cString: strerror(errno))
            )
        }
        defer { close(source) }
        let destination = open(destinationPath, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard destination >= 0 else {
            throw StateMaintenanceError.io(
                path: destinationPath,
                message: String(cString: strerror(errno))
            )
        }
        defer { close(destination) }

        var sourceMetadata = stat()
        var destinationMetadata = stat()
        guard fstat(source, &sourceMetadata) == 0 else {
            throw StateMaintenanceError.io(
                path: sourcePath,
                message: String(cString: strerror(errno))
            )
        }
        guard UInt64(sourceMetadata.st_dev) == before.device,
              UInt64(sourceMetadata.st_ino) == before.inode,
              sourceMetadata.st_mode & S_IFMT == S_IFREG,
              sourceMetadata.st_uid == geteuid(),
              sourceMetadata.st_nlink == 1,
              sourceMetadata.st_mode & 0o7777 == S_IRUSR | S_IWUSR,
              UInt64(sourceMetadata.st_size) == expectedBytes else {
            throw sourceChanged("the source identity or security metadata changed while opening it")
        }
        guard fstat(destination, &destinationMetadata) == 0 else {
            throw StateMaintenanceError.io(
                path: destinationPath,
                message: String(cString: strerror(errno))
            )
        }
        guard destinationMetadata.st_mode & S_IFMT == S_IFREG,
              destinationMetadata.st_uid == geteuid(),
              destinationMetadata.st_nlink == 1,
              destinationMetadata.st_mode & 0o7777 == S_IRUSR | S_IWUSR,
              destinationMetadata.st_size == 0 else {
            throw StateMaintenanceError.io(
                path: destinationPath,
                message: "exact copy descriptors do not match the verified private source and empty owned destination"
            )
        }

        var copied: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw StateMaintenanceError.io(
                    path: sourcePath,
                    message: String(cString: strerror(errno))
                )
            }
            if count == 0 { break }
            copied += UInt64(count)
            guard copied <= expectedBytes else {
                throw sourceChanged("the source grew while it was being copied")
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destination,
                        bytes.baseAddress!.advanced(by: offset),
                        count - offset
                    )
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw StateMaintenanceError.io(
                        path: destinationPath,
                        message: String(cString: strerror(errno))
                    )
                }
                offset += written
            }
        }
        guard copied == expectedBytes else {
            throw sourceChanged("the source was truncated while it was being copied")
        }
        guard fsync(destination) == 0 else {
            throw StateMaintenanceError.io(
                path: destinationPath,
                message: String(cString: strerror(errno))
            )
        }

        let sourceAfter: StateFileFingerprint
        do {
            sourceAfter = try fingerprint(sourcePath)
        } catch {
            throw sourceChanged("the source could not be revalidated after copying")
        }
        let destinationAfter = try fingerprint(destinationPath)
        guard sourceAfter == before else {
            throw sourceChanged("the source changed while its copied bytes were being verified")
        }
        guard destinationAfter.sha256 == expectedSHA256,
              destinationAfter.bytes == expectedBytes else {
            throw StateMaintenanceError.io(
                path: destinationPath,
                message: "the copied file does not match the verified source digest and size"
            )
        }
    }

    static func unlinkSensitiveFile(_ path: String, allowMissing: Bool = false) throws {
        if !exists(path), allowMissing { return }
        try SecureStatePathManager().validateSensitiveRegularFile(path)
        guard unlink(path) == 0 else {
            throw StateMaintenanceError.io(path: path, message: String(cString: strerror(errno)))
        }
        try synchronizeDirectory((path as NSString).deletingLastPathComponent)
    }
}

struct StateStrictJSONError: Error, Equatable {
    let reason: String
}

enum StateStrictJSONObject {
    static func validate(
        _ data: Data,
        allowedKeys: Set<String>,
        requiredKeys: Set<String>
    ) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw StateStrictJSONError(reason: "invalid JSON")
        }
        guard let object = value as? [String: Any] else {
            throw StateStrictJSONError(reason: "expected one JSON object")
        }
        let keys = try topLevelKeys(data)
        var seen = Set<String>()
        guard keys.allSatisfy({ seen.insert($0).inserted }) else {
            throw StateStrictJSONError(reason: "duplicate top-level fields are forbidden")
        }
        let actual = Set(object.keys)
        guard actual.isSubset(of: allowedKeys) else {
            throw StateStrictJSONError(reason: "unsupported top-level fields are forbidden")
        }
        guard requiredKeys.isSubset(of: actual) else {
            throw StateStrictJSONError(reason: "required top-level fields are missing")
        }
    }

    private static func topLevelKeys(_ data: Data) throws -> [String] {
        let bytes = Array(data)
        var index = skipWhitespace(bytes, from: 0)
        guard index < bytes.count, bytes[index] == ascii("{") else {
            throw StateStrictJSONError(reason: "expected one JSON object")
        }
        index += 1
        var keys: [String] = []
        while true {
            index = skipWhitespace(bytes, from: index)
            guard index < bytes.count else {
                throw StateStrictJSONError(reason: "truncated JSON object")
            }
            if bytes[index] == ascii("}") {
                index += 1
                break
            }
            let key = try parseString(bytes, from: index)
            keys.append(key.value)
            index = skipWhitespace(bytes, from: key.nextIndex)
            guard index < bytes.count, bytes[index] == ascii(":") else {
                throw StateStrictJSONError(reason: "invalid JSON object field")
            }
            index = try skipValue(bytes, from: index + 1)
            index = skipWhitespace(bytes, from: index)
            guard index < bytes.count else {
                throw StateStrictJSONError(reason: "truncated JSON object")
            }
            if bytes[index] == ascii(",") {
                index += 1
                continue
            }
            if bytes[index] == ascii("}") {
                index += 1
                break
            }
            throw StateStrictJSONError(reason: "invalid JSON object delimiter")
        }
        guard skipWhitespace(bytes, from: index) == bytes.count else {
            throw StateStrictJSONError(reason: "trailing JSON content is forbidden")
        }
        return keys
    }

    private static func parseString(
        _ bytes: [UInt8],
        from start: Int
    ) throws -> (value: String, nextIndex: Int) {
        guard start < bytes.count, bytes[start] == ascii("\"") else {
            throw StateStrictJSONError(reason: "JSON object keys must be strings")
        }
        var index = start + 1
        var escaped = false
        while index < bytes.count {
            if escaped {
                escaped = false
            } else if bytes[index] == ascii("\\") {
                escaped = true
            } else if bytes[index] == ascii("\"") {
                let literal = Data(bytes[start...index])
                guard let value = try? JSONDecoder().decode(String.self, from: literal) else {
                    throw StateStrictJSONError(reason: "invalid JSON object key")
                }
                return (value, index + 1)
            }
            index += 1
        }
        throw StateStrictJSONError(reason: "unterminated JSON object key")
    }

    private static func skipValue(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = skipWhitespace(bytes, from: start)
        var objectDepth = 0
        var arrayDepth = 0
        var inString = false
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == ascii("\\") {
                    escaped = true
                } else if byte == ascii("\"") {
                    inString = false
                }
                index += 1
                continue
            }
            switch byte {
            case ascii("\""):
                inString = true
            case ascii("{"):
                objectDepth += 1
            case ascii("}"):
                if objectDepth == 0, arrayDepth == 0 { return index }
                objectDepth -= 1
            case ascii("["):
                arrayDepth += 1
            case ascii("]"):
                arrayDepth -= 1
            case ascii(",") where objectDepth == 0 && arrayDepth == 0:
                return index
            default:
                break
            }
            guard objectDepth >= 0, arrayDepth >= 0 else {
                throw StateStrictJSONError(reason: "invalid nested JSON value")
            }
            index += 1
        }
        throw StateStrictJSONError(reason: "truncated JSON value")
    }

    private static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }
}
