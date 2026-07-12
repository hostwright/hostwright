import CryptoKit
import Darwin
import Foundation
import HostwrightCore

struct StagedExtensionExecutable {
    let executableURL: URL
    let directoryURL: URL
    let sha256: String

    func cleanup() throws {
        if unlink(executableURL.path) != 0, errno != ENOENT {
            throw HostwrightDiagnostic(
                code: .extensionExecutionFailed,
                message: "Could not remove the staged extension executable after the handshake."
            )
        }
        if rmdir(directoryURL.path) != 0, errno != ENOENT {
            throw HostwrightDiagnostic(
                code: .extensionExecutionFailed,
                message: "Could not remove the private extension staging directory after the handshake."
            )
        }
    }
}

enum ExtensionFileSecurity {
    static let maximumExecutableBytes = 256 * 1_024 * 1_024

    static func readDeclaration(at url: URL) throws -> Data {
        guard url.path.hasPrefix("/") else {
            throw invalid("The executable extension declaration path must be absolute.")
        }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw invalid("Could not open the executable extension declaration as a regular non-symlink file.")
        }
        defer { close(descriptor) }

        let metadata = try validatedMetadata(
            descriptor: descriptor,
            role: "executable extension declaration",
            requireOwnerExecute: false,
            maximumBytes: ExecutableExtensionDocumentParser.maximumDocumentBytes
        )
        guard metadata.st_size > 0 else {
            throw invalid("The executable extension declaration must not be empty.")
        }
        return try readAll(
            descriptor: descriptor,
            maximumBytes: ExecutableExtensionDocumentParser.maximumDocumentBytes,
            role: "executable extension declaration"
        )
    }

    static func stageExecutable(at sourceURL: URL, rootURL: URL) throws -> StagedExtensionExecutable {
        guard sourceURL.path.hasPrefix("/"), rootURL.path.hasPrefix("/") else {
            throw invalid("The executable extension and staging paths must be absolute.")
        }

        let sourceDescriptor = open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw invalid("Could not open the extension executable as a regular non-symlink file.")
        }
        defer { close(sourceDescriptor) }

        let metadata = try validatedMetadata(
            descriptor: sourceDescriptor,
            role: "extension executable",
            requireOwnerExecute: true,
            maximumBytes: maximumExecutableBytes
        )
        guard metadata.st_size > 0 else {
            throw invalid("The extension executable must not be empty.")
        }

        let directoryURL = try createPrivateStagingDirectory(rootURL: rootURL)
        let executableURL = directoryURL.appendingPathComponent("extension", isDirectory: false)
        var destinationDescriptor: Int32 = -1
        do {
            destinationDescriptor = open(
                executableURL.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(S_IRUSR | S_IXUSR)
            )
            guard destinationDescriptor >= 0 else {
                throw executionFailed("Could not create the private staged extension executable.")
            }
            guard fchmod(destinationDescriptor, mode_t(S_IRUSR | S_IXUSR)) == 0 else {
                throw executionFailed("Could not restrict permissions on the staged extension executable.")
            }

            var hasher = SHA256()
            var total = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let count = Darwin.read(sourceDescriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else {
                    throw invalid("Could not read the extension executable.")
                }
                if count == 0 { break }
                total += count
                guard total <= maximumExecutableBytes else {
                    throw invalid("The extension executable exceeds the 256 MiB host limit.")
                }

                let chunk = Data(buffer[0..<count])
                hasher.update(data: chunk)
                try writeAll(descriptor: destinationDescriptor, data: chunk)
            }
            guard fsync(destinationDescriptor) == 0 else {
                throw executionFailed("Could not synchronize the staged extension executable.")
            }
            close(destinationDescriptor)
            destinationDescriptor = -1

            return StagedExtensionExecutable(
                executableURL: executableURL,
                directoryURL: directoryURL,
                sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
            )
        } catch {
            if destinationDescriptor >= 0 {
                close(destinationDescriptor)
            }
            let fileCleanupSucceeded = unlink(executableURL.path) == 0 || errno == ENOENT
            let directoryCleanupSucceeded = rmdir(directoryURL.path) == 0 || errno == ENOENT
            guard fileCleanupSucceeded, directoryCleanupSucceeded else {
                throw executionFailed("Extension staging failed and exact staging cleanup also failed.")
            }
            throw error
        }
    }

    private static func validatedMetadata(
        descriptor: Int32,
        role: String,
        requireOwnerExecute: Bool,
        maximumBytes: Int
    ) throws -> stat {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw invalid("The \(role) must be a regular non-symlink file.")
        }
        guard metadata.st_uid == geteuid() else {
            throw blocked("The \(role) must be owned by the invoking user.")
        }
        guard metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw blocked("The \(role) must not be group-writable or world-writable.")
        }
        guard metadata.st_mode & (S_ISUID | S_ISGID) == 0 else {
            throw blocked("The \(role) must not carry set-user-ID or set-group-ID mode bits.")
        }
        if requireOwnerExecute, metadata.st_mode & S_IXUSR == 0 {
            throw invalid("The extension executable must have owner execute permission.")
        }
        guard metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
            throw invalid("The \(role) exceeds the allowed size.")
        }
        return metadata
    }

    private static func readAll(descriptor: Int32, maximumBytes: Int, role: String) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw invalid("Could not read the \(role).")
            }
            if count == 0 { break }
            guard result.count + count <= maximumBytes else {
                throw invalid("The \(role) exceeds the allowed size.")
            }
            result.append(contentsOf: buffer[0..<count])
        }
        return result
    }

    private static func writeAll(descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw executionFailed("Could not write the private staged extension executable.")
                }
                offset += count
            }
        }
    }

    private static func createPrivateStagingDirectory(rootURL: URL) throws -> URL {
        var rootMetadata = stat()
        guard lstat(rootURL.path, &rootMetadata) == 0,
              (rootMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw executionFailed("The extension staging root must be an existing directory.")
        }
        guard rootMetadata.st_uid == geteuid(),
              rootMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw executionFailed("The extension staging root must be caller-owned and private.")
        }

        var template = Array(rootURL.appendingPathComponent("hostwright-extension.XXXXXX").path.utf8CString)
        guard let path = mkdtemp(&template) else {
            throw executionFailed("Could not create a private extension staging directory.")
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private static func invalid(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionInvalid, message: message)
    }

    private static func blocked(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionBlocked, message: message)
    }

    private static func executionFailed(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionExecutionFailed, message: message)
    }
}
