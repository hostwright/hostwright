import CryptoKit
import Darwin
import Foundation
import HostwrightRuntime

enum ContainerizationGuestPolicyStoreError:
    Error,
    Equatable,
    Sendable
{
    case unavailable
    case invalidIdentifier
    case unsafePath
    case unsafeFile
    case digestMismatch
    case generationConflict
    case operationFailed
}

struct ContainerizationGuestPolicyAsset: Sendable {
    static let guestDirectoryPath = "/run/hostwright"
    static let guestLoaderPath =
        guestDirectoryPath + "/hostwright-netfilter"
    static let guestBootstrapRequestPath =
        guestDirectoryPath + "/bootstrap-policy.json"
    static let guestUpdateRequestPath =
        guestDirectoryPath + "/network-policy.json"

    let data: Data
    let sha256: String

    init?(configuration: ContainerizationHelperConfiguration) throws {
        guard let url = configuration.guestNetworkPolicyLoaderURL,
              let expectedSHA256 =
                configuration.guestNetworkPolicyLoaderSHA256 else {
            return nil
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        guard digest == expectedSHA256 else {
            throw ContainerizationGuestPolicyStoreError.digestMismatch
        }
        self.data = data
        sha256 = digest
    }

    init(validatedData data: Data) {
        self.data = data
        sha256 = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

final class ContainerizationGuestPolicyStore: @unchecked Sendable {
    static let maximumLoaderBytes = 64 * 1_024 * 1_024

    private let rootURL: URL
    private let asset: ContainerizationGuestPolicyAsset

    init(
        rootURL: URL,
        asset: ContainerizationGuestPolicyAsset
    ) throws {
        guard asset.data.count > 0,
              asset.data.count <= Self.maximumLoaderBytes else {
            throw ContainerizationGuestPolicyStoreError.unsafeFile
        }
        self.rootURL = rootURL
        self.asset = asset
        try Self.prepareDirectory(rootURL)
    }

    func prepareShare(
        resourceIdentifier: String,
        request: ContainerizationGuestNetworkPolicyLoaderRequest
    ) throws -> URL {
        let directory = try prepareAssetShare(
            resourceIdentifier: resourceIdentifier
        )
        try writeBootstrapRequest(
            request,
            resourceIdentifier: resourceIdentifier
        )
        try writeRequest(
            request,
            fileName: "network-policy.json",
            resourceIdentifier: resourceIdentifier
        )
        return directory
    }

    func prepareAssetShare(
        resourceIdentifier: String
    ) throws -> URL {
        let directory = try shareURL(
            resourceIdentifier: resourceIdentifier
        )
        try Self.prepareDirectory(directory)
        try installLoader(in: directory)
        return directory
    }

    func writeBootstrapRequest(
        _ request: ContainerizationGuestNetworkPolicyLoaderRequest,
        resourceIdentifier: String
    ) throws {
        try writeRequest(
            request,
            fileName: "bootstrap-policy.json",
            resourceIdentifier: resourceIdentifier
        )
    }

    func writeUpdateRequest(
        _ request: ContainerizationGuestNetworkPolicyLoaderRequest,
        resourceIdentifier: String
    ) throws {
        try writeRequest(
            request,
            fileName: "network-policy.json",
            resourceIdentifier: resourceIdentifier
        )
    }

    private func writeRequest(
        _ request: ContainerizationGuestNetworkPolicyLoaderRequest,
        fileName: String,
        resourceIdentifier: String
    ) throws {
        let directory = try shareURL(
            resourceIdentifier: resourceIdentifier
        )
        try Self.requirePrivateDirectory(directory)
        let destination = directory.appendingPathComponent(
            fileName,
            isDirectory: false
        )
        let data = try request.encoded()
        for existingName in [
            "bootstrap-policy.json",
            "network-policy.json"
        ] {
            let existingURL = directory.appendingPathComponent(
                existingName,
                isDirectory: false
            )
            guard FileManager.default.fileExists(
                atPath: existingURL.path
            ) else {
                continue
            }
            let existing = try Self.readPrivateFile(
                existingURL,
                maximumBytes:
                    ContainerizationGuestNetworkPolicy.maximumEncodedBytes
            )
            if let prior = try? JSONDecoder().decode(
                ContainerizationGuestNetworkPolicyLoaderRequest.self,
                from: existing
            ) {
                guard prior.generation <= request.generation,
                      prior.generation != request.generation ||
                        prior.policyDigest == request.policyDigest else {
                    throw ContainerizationGuestPolicyStoreError
                        .generationConflict
                }
            }
        }
        try Self.replace(
            data,
            at: destination,
            mode: S_IRUSR
        )
    }

    func removeShare(resourceIdentifier: String) throws {
        let directory = try shareURL(
            resourceIdentifier: resourceIdentifier
        )
        var metadata = stat()
        if lstat(directory.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw ContainerizationGuestPolicyStoreError.operationFailed
            }
            return
        }
        try Self.requirePrivateDirectory(directory)
        let expected = Set([
            "bootstrap-policy.json",
            "hostwright-netfilter",
            "network-policy.json"
        ])
        let names = try Set(
            FileManager.default.contentsOfDirectory(
                atPath: directory.path
            )
        )
        guard names.isSubset(of: expected) else {
            throw ContainerizationGuestPolicyStoreError.unsafeFile
        }
        for name in names.sorted() {
            let file = directory.appendingPathComponent(
                name,
                isDirectory: false
            )
            _ = try Self.readPrivateFile(
                file,
                maximumBytes: name == "hostwright-netfilter"
                    ? Self.maximumLoaderBytes
                    : ContainerizationGuestNetworkPolicy
                        .maximumEncodedBytes
            )
            guard unlink(file.path) == 0 else {
                throw ContainerizationGuestPolicyStoreError.operationFailed
            }
        }
        guard rmdir(directory.path) == 0 else {
            throw ContainerizationGuestPolicyStoreError.operationFailed
        }
        try Self.syncDirectory(rootURL)
    }

    func shareURL(resourceIdentifier: String) throws -> URL {
        guard !resourceIdentifier.isEmpty,
              resourceIdentifier.utf8.count <= 1_024,
              resourceIdentifier.rangeOfCharacter(
                from: .controlCharacters
              ) == nil else {
            throw ContainerizationGuestPolicyStoreError.invalidIdentifier
        }
        let digest = SHA256.hash(data: Data(resourceIdentifier.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return rootURL.appendingPathComponent(
            digest,
            isDirectory: true
        )
    }

    private func installLoader(in directory: URL) throws {
        let destination = directory.appendingPathComponent(
            "hostwright-netfilter",
            isDirectory: false
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try Self.readPrivateFile(
                destination,
                maximumBytes: Self.maximumLoaderBytes
            )
            let digest = SHA256.hash(data: existing).map {
                String(format: "%02x", $0)
            }.joined()
            guard digest == asset.sha256 else {
                throw ContainerizationGuestPolicyStoreError.digestMismatch
            }
            return
        }
        try Self.replace(
            asset.data,
            at: destination,
            mode: S_IRUSR | S_IXUSR
        )
    }

    private static func prepareDirectory(_ url: URL) throws {
        guard url.path.hasPrefix("/"),
              url.standardizedFileURL.path == url.path else {
            throw ContainerizationGuestPolicyStoreError.unsafePath
        }
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 {
            try requirePrivateDirectory(url)
            return
        }
        guard errno == ENOENT,
              mkdir(url.path, S_IRWXU) == 0 else {
            throw ContainerizationGuestPolicyStoreError.operationFailed
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func requirePrivateDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode &
                (S_IRWXG | S_IRWXO | S_ISUID | S_ISGID) == 0 else {
            throw ContainerizationGuestPolicyStoreError.unsafePath
        }
    }

    private static func readPrivateFile(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode &
                (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0,
              metadata.st_size > 0,
              metadata.st_size <= maximumBytes else {
            throw ContainerizationGuestPolicyStoreError.unsafeFile
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func replace(
        _ data: Data,
        at destination: URL,
        mode: mode_t
    ) throws {
        let directory = destination.deletingLastPathComponent()
        try requirePrivateDirectory(directory)
        var existing = stat()
        if lstat(destination.path, &existing) == 0 {
            existing = try requirePrivateRegularFile(
                destination,
                exactMode: mode
            )
            let inspector = Darwin.open(
                destination.path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard inspector >= 0 else {
                throw ContainerizationGuestPolicyStoreError.operationFailed
            }
            var restoreMode = false
            defer {
                if restoreMode {
                    _ = fchmod(inspector, mode)
                }
                Darwin.close(inspector)
            }
            var inspected = stat()
            guard fstat(inspector, &inspected) == 0,
                  inspected.st_dev == existing.st_dev,
                  inspected.st_ino == existing.st_ino,
                  inspected.st_uid == existing.st_uid,
                  inspected.st_nlink == existing.st_nlink,
                  inspected.st_mode == existing.st_mode,
                  fchmod(inspector, S_IRUSR | S_IWUSR) == 0 else {
                throw ContainerizationGuestPolicyStoreError.unsafeFile
            }
            restoreMode = true
            let writer = Darwin.open(
                destination.path,
                O_WRONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard writer >= 0 else {
                throw ContainerizationGuestPolicyStoreError.operationFailed
            }
            defer { Darwin.close(writer) }
            var opened = stat()
            guard fstat(writer, &opened) == 0,
                  opened.st_dev == inspected.st_dev,
                  opened.st_ino == inspected.st_ino,
                  opened.st_uid == inspected.st_uid,
                  opened.st_nlink == inspected.st_nlink,
                  opened.st_mode & S_IFMT == S_IFREG,
                  opened.st_mode & 0o777 == (S_IRUSR | S_IWUSR),
                  ftruncate(writer, 0) == 0 else {
                throw ContainerizationGuestPolicyStoreError.operationFailed
            }
            try writeAll(data, to: writer)
            guard fsync(writer) == 0,
                  fchmod(writer, mode) == 0,
                  fsync(writer) == 0 else {
                throw ContainerizationGuestPolicyStoreError.operationFailed
            }
            restoreMode = false
            try syncDirectory(directory)
            return
        }
        guard errno == ENOENT else {
            throw ContainerizationGuestPolicyStoreError.operationFailed
        }
        let temporary = directory.appendingPathComponent(
            ".write-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode
        )
        guard descriptor >= 0 else {
            throw ContainerizationGuestPolicyStoreError.operationFailed
        }
        var removeTemporary = true
        defer {
            Darwin.close(descriptor)
            if removeTemporary {
                _ = unlink(temporary.path)
            }
        }
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0,
              rename(temporary.path, destination.path) == 0 else {
            throw ContainerizationGuestPolicyStoreError.operationFailed
        }
        removeTemporary = false
        try syncDirectory(directory)
    }

    private static func requirePrivateRegularFile(
        _ url: URL,
        exactMode: mode_t
    ) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == exactMode,
              metadata.st_mode &
                (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0 else {
            throw ContainerizationGuestPolicyStoreError.unsafeFile
        }
        return metadata
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: written),
                    bytes.count - written
                )
                guard result > 0 else {
                    throw ContainerizationGuestPolicyStoreError
                        .operationFailed
                }
                written += result
            }
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw ContainerizationGuestPolicyStoreError.operationFailed
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ContainerizationGuestPolicyStoreError.operationFailed
        }
    }
}
