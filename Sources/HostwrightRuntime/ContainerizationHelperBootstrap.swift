import CryptoKit
import Darwin
import Foundation
import HostwrightCore

struct ContainerizationHelperBootstrapAssetLock: Equatable, Sendable {
    struct File: Equatable, Sendable {
        let name: String
        let sha256: String
        let size: Int64
    }

    let frameworkVersion: String
    let kernel: File
    let initImageReference: String
    let initImageIndex: File
    let initImageVariant: File
    let initImageConfiguration: File
    let initImageLayer: File

    var initImageDescriptorDigest: String { "sha256:\(initImageIndex.sha256)" }
    var initImageVariantDigest: String { "sha256:\(initImageVariant.sha256)" }

    static let pinned = ContainerizationHelperBootstrapAssetLock(
        frameworkVersion: ContainerizationRuntimeAssetContract.frameworkVersion,
        kernel: File(
            name: ContainerizationRuntimeAssetContract.kernelFileName,
            sha256: ContainerizationRuntimeAssetContract.kernelSHA256,
            size: ContainerizationRuntimeAssetContract.kernelSize
        ),
        initImageReference: ContainerizationRuntimeAssetContract.initImageReference,
        initImageIndex: File(
            name: ContainerizationRuntimeAssetContract.initImageIndexDigest,
            sha256: ContainerizationRuntimeAssetContract.initImageIndexDigest,
            size: ContainerizationRuntimeAssetContract.initImageIndexSize
        ),
        initImageVariant: File(
            name: ContainerizationRuntimeAssetContract.initImageVariantDigest,
            sha256: ContainerizationRuntimeAssetContract.initImageVariantDigest,
            size: ContainerizationRuntimeAssetContract.initImageVariantSize
        ),
        initImageConfiguration: File(
            name: ContainerizationRuntimeAssetContract.initImageConfigurationDigest,
            sha256: ContainerizationRuntimeAssetContract.initImageConfigurationDigest,
            size: ContainerizationRuntimeAssetContract.initImageConfigurationSize
        ),
        initImageLayer: File(
            name: ContainerizationRuntimeAssetContract.initImageLayerDigest,
            sha256: ContainerizationRuntimeAssetContract.initImageLayerDigest,
            size: ContainerizationRuntimeAssetContract.initImageLayerSize
        )
    )
}

enum ContainerizationHelperBootstrap {
    private static let configurationFileName = "containerization-helper.json"
    private static let rootfsSizeBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024

    static func prepare(
        configuration: ContainerizationHelperClientConfiguration,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        expectedUserID: uid_t = geteuid(),
        assetLock: ContainerizationHelperBootstrapAssetLock = .pinned
    ) throws {
        let paths = try installedPaths(
            configuration: configuration,
            homeDirectoryURL: homeDirectoryURL
        )
        try validateInstalledExecutableAndAssets(
            paths: paths,
            expectedUserID: expectedUserID,
            assetLock: assetLock
        )

        let document = ContainerizationHelperBootstrapDocument(
            schema: 1,
            framework: assetLock.frameworkVersion,
            dataRootPath: paths.dataRootURL.path,
            runtimeDirectoryPath: configuration.runtimeDirectoryURL.path,
            kernelPath: paths.kernelURL.path,
            kernelSHA256: assetLock.kernel.sha256,
            initImageLayoutPath: paths.initImageLayoutURL.path,
            initImageReference: assetLock.initImageReference,
            initImageDescriptorDigest: assetLock.initImageDescriptorDigest,
            initImageVariantDigest: assetLock.initImageVariantDigest,
            rootfsSizeBytes: rootfsSizeBytes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard !data.isEmpty, data.count <= 64 * 1_024 else {
            throw ContainerizationHelperClientError.unsafeConfiguration
        }

        try persist(
            data,
            configuration: configuration,
            homeDirectoryURL: homeDirectoryURL,
            expectedUserID: expectedUserID
        )
    }

    private struct InstalledPaths {
        let prefixURL: URL
        let dataRootURL: URL
        let kernelURL: URL
        let initImageLayoutURL: URL
    }

    private static func installedPaths(
        configuration: ContainerizationHelperClientConfiguration,
        homeDirectoryURL: URL
    ) throws -> InstalledPaths {
        try requireNormalizedAbsolute(homeDirectoryURL)
        let binURL = configuration.executableURL.deletingLastPathComponent()
        guard binURL.lastPathComponent == "bin" else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
        let prefixURL = binURL.deletingLastPathComponent()
        guard prefixURL.path != "/" else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }

        let supportURL = homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Hostwright", isDirectory: true)
        let expectedConfigurationURL = supportURL
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(configurationFileName, isDirectory: false)
        let expectedRuntimeURL = supportURL
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("helper", isDirectory: true)
        guard configuration.configurationURL.path == expectedConfigurationURL.path,
              configuration.runtimeDirectoryURL.path == expectedRuntimeURL.path else {
            throw ContainerizationHelperClientError.unsafeConfiguration
        }

        let assetRootURL = prefixURL
            .appendingPathComponent(
                ContainerizationRuntimeAssetContract.installationRelativeRoot,
                isDirectory: true
            )
        return InstalledPaths(
            prefixURL: prefixURL,
            dataRootURL: supportURL
                .appendingPathComponent("data", isDirectory: true)
                .appendingPathComponent("containerization-helper", isDirectory: true),
            kernelURL: assetRootURL
                .appendingPathComponent("kernel", isDirectory: true)
                .appendingPathComponent(
                    ContainerizationRuntimeAssetContract.kernelFileName,
                    isDirectory: false
                ),
            initImageLayoutURL: assetRootURL
                .appendingPathComponent("vminit", isDirectory: true)
        )
    }

    private static func validateInstalledExecutableAndAssets(
        paths: InstalledPaths,
        expectedUserID: uid_t,
        assetLock: ContainerizationHelperBootstrapAssetLock
    ) throws {
        do {
            let prefix = try BootstrapDirectory.openRoot(
                paths.prefixURL,
                expectedUserID: expectedUserID,
                trustedRootOwner: true
            )
            let bin = try prefix.openDirectory(
                "bin",
                expectedUserID: expectedUserID,
                trustedRootOwner: true
            )
            try bin.requireExecutable(
                "hostwright-containerization-helper",
                expectedUserID: expectedUserID
            )

            let share = try prefix.openDirectory(
                "share",
                expectedUserID: expectedUserID,
                trustedRootOwner: true
            )
            let hostwright = try share.openDirectory(
                "hostwright",
                expectedUserID: expectedUserID,
                trustedRootOwner: true
            )
            let assets = try hostwright.openDirectory(
                "containerization",
                expectedUserID: expectedUserID,
                trustedRootOwner: true
            )
            let kernelDirectory = try assets.openDirectory(
                "kernel",
                expectedUserID: expectedUserID,
                trustedRootOwner: true
            )
            try kernelDirectory.requireFile(
                assetLock.kernel,
                expectedUserID: expectedUserID
            )

            let initImage = try assets.openDirectory(
                "vminit",
                expectedUserID: expectedUserID,
                trustedRootOwner: true
            )
            try validateOCILayout(initImage, assetLock: assetLock, expectedUserID: expectedUserID)
        } catch let error as ContainerizationHelperClientError {
            throw error
        } catch {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
    }

    private static func validateOCILayout(
        _ layout: BootstrapDirectory,
        assetLock: ContainerizationHelperBootstrapAssetLock,
        expectedUserID: uid_t
    ) throws {
        let layoutData = try layout.readBoundedFile(
            "oci-layout",
            maximumBytes: 4 * 1_024,
            expectedUserID: expectedUserID
        )
        guard let layoutObject = try JSONSerialization.jsonObject(with: layoutData) as? [String: Any],
              layoutObject.count == 1,
              layoutObject["imageLayoutVersion"] as? String == "1.0.0" else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }

        let indexData = try layout.readBoundedFile(
            "index.json",
            maximumBytes: 64 * 1_024,
            expectedUserID: expectedUserID
        )
        guard let index = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              index["schemaVersion"] as? Int == 2,
              let manifests = index["manifests"] as? [[String: Any]],
              manifests.count == 1,
              let descriptor = manifests.first,
              descriptor["mediaType"] as? String == "application/vnd.oci.image.index.v1+json",
              descriptor["digest"] as? String == assetLock.initImageDescriptorDigest,
              descriptor["size"] as? Int == Int(assetLock.initImageIndex.size),
              let annotations = descriptor["annotations"] as? [String: String],
              annotations["org.opencontainers.image.ref.name"] == assetLock.initImageReference else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }

        let blobs = try layout.openDirectory(
            "blobs",
            expectedUserID: expectedUserID,
            trustedRootOwner: true
        )
        let sha256 = try blobs.openDirectory(
            "sha256",
            expectedUserID: expectedUserID,
            trustedRootOwner: true
        )
        for requirement in [
            assetLock.initImageIndex,
            assetLock.initImageVariant,
            assetLock.initImageConfiguration,
            assetLock.initImageLayer
        ] {
            try sha256.requireFile(requirement, expectedUserID: expectedUserID)
        }
    }

    private static func persist(
        _ data: Data,
        configuration: ContainerizationHelperClientConfiguration,
        homeDirectoryURL: URL,
        expectedUserID: uid_t
    ) throws {
        do {
            let home = try BootstrapDirectory.openRoot(
                homeDirectoryURL,
                expectedUserID: expectedUserID,
                trustedRootOwner: false
            )
            let library = try home.openOrCreateDirectory(
                "Library",
                expectedUserID: expectedUserID,
                requirePrivateMode: false
            )
            let applicationSupport = try library.openOrCreateDirectory(
                "Application Support",
                expectedUserID: expectedUserID,
                requirePrivateMode: false
            )
            let support = try applicationSupport.openOrCreateDirectory(
                "Hostwright",
                expectedUserID: expectedUserID,
                requirePrivateMode: true
            )
            let config = try support.openOrCreateDirectory(
                "config",
                expectedUserID: expectedUserID,
                requirePrivateMode: true
            )
            let dataParent = try support.openOrCreateDirectory(
                "data",
                expectedUserID: expectedUserID,
                requirePrivateMode: true
            )
            _ = try dataParent.openOrCreateDirectory(
                "containerization-helper",
                expectedUserID: expectedUserID,
                requirePrivateMode: true
            )
            let run = try support.openOrCreateDirectory(
                "run",
                expectedUserID: expectedUserID,
                requirePrivateMode: true
            )
            _ = try run.openOrCreateDirectory(
                "helper",
                expectedUserID: expectedUserID,
                requirePrivateMode: true
            )
            try config.installExclusiveFile(
                configurationFileName,
                data: data,
                expectedUserID: expectedUserID
            )
            try configuration.validateForLaunch(expectedUserID: expectedUserID)
        } catch let error as ContainerizationHelperClientError {
            throw error
        } catch {
            throw ContainerizationHelperClientError.unsafeConfiguration
        }
    }

    private static func requireNormalizedAbsolute(_ url: URL) throws {
        guard url.path.hasPrefix("/"),
              url.standardizedFileURL.path == url.path,
              url.path.utf8.count <= 1_024 else {
            throw ContainerizationHelperClientError.pathNotNormalized
        }
    }
}

private struct ContainerizationHelperBootstrapDocument: Codable, Equatable {
    let schema: Int
    let framework: String
    let dataRootPath: String
    let runtimeDirectoryPath: String
    let kernelPath: String
    let kernelSHA256: String
    let initImageLayoutPath: String
    let initImageReference: String
    let initImageDescriptorDigest: String
    let initImageVariantDigest: String
    let rootfsSizeBytes: UInt64
}

private final class BootstrapDirectory {
    let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }

    static func openRoot(
        _ url: URL,
        expectedUserID: uid_t,
        trustedRootOwner: Bool
    ) throws -> BootstrapDirectory {
        guard url.path.hasPrefix("/"),
              url.standardizedFileURL.path == url.path,
              url.path.utf8.count <= 1_024 else {
            throw ContainerizationHelperClientError.pathNotNormalized
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ContainerizationHelperClientError.unsafeConfiguration
        }
        do {
            try validateDirectory(
                descriptor,
                expectedUserID: expectedUserID,
                trustedRootOwner: trustedRootOwner,
                requirePrivateMode: false
            )
            return BootstrapDirectory(descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func openDirectory(
        _ name: String,
        expectedUserID: uid_t,
        trustedRootOwner: Bool
    ) throws -> BootstrapDirectory {
        try validateComponent(name)
        let child = openat(
            descriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard child >= 0 else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
        do {
            try Self.validateDirectory(
                child,
                expectedUserID: expectedUserID,
                trustedRootOwner: trustedRootOwner,
                requirePrivateMode: false
            )
            return BootstrapDirectory(descriptor: child)
        } catch {
            Darwin.close(child)
            throw error
        }
    }

    func openOrCreateDirectory(
        _ name: String,
        expectedUserID: uid_t,
        requirePrivateMode: Bool
    ) throws -> BootstrapDirectory {
        try validateComponent(name)
        var child = openat(
            descriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if child < 0 {
            guard errno == ENOENT else {
                throw ContainerizationHelperClientError.unsafeConfiguration
            }
            if mkdirat(descriptor, name, S_IRWXU) != 0, errno != EEXIST {
                throw ContainerizationHelperClientError.unsafeConfiguration
            }
            child = openat(
                descriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard child >= 0 else {
                throw ContainerizationHelperClientError.unsafeConfiguration
            }
            guard fchmod(child, S_IRWXU) == 0,
                  fsync(child) == 0,
                  fsync(descriptor) == 0 else {
                Darwin.close(child)
                throw ContainerizationHelperClientError.unsafeConfiguration
            }
        }
        do {
            try Self.validateDirectory(
                child,
                expectedUserID: expectedUserID,
                trustedRootOwner: false,
                requirePrivateMode: requirePrivateMode
            )
            return BootstrapDirectory(descriptor: child)
        } catch {
            Darwin.close(child)
            throw error
        }
    }

    func requireExecutable(_ name: String, expectedUserID: uid_t) throws {
        let (file, metadata) = try openRegularFile(name, expectedUserID: expectedUserID)
        defer { Darwin.close(file) }
        guard metadata.st_mode & S_IXUSR != 0 else {
            throw ContainerizationHelperClientError.unsafeExecutable
        }
    }

    func requireFile(
        _ requirement: ContainerizationHelperBootstrapAssetLock.File,
        expectedUserID: uid_t
    ) throws {
        let (file, metadata) = try openRegularFile(
            requirement.name,
            expectedUserID: expectedUserID
        )
        defer { Darwin.close(file) }
        guard metadata.st_size == requirement.size,
              try sha256(file) == requirement.sha256 else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
    }

    func readBoundedFile(
        _ name: String,
        maximumBytes: Int,
        expectedUserID: uid_t
    ) throws -> Data {
        let (file, metadata) = try openRegularFile(name, expectedUserID: expectedUserID)
        defer { Darwin.close(file) }
        guard metadata.st_size > 0,
              metadata.st_size <= maximumBytes else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
        return try readAll(file, expectedSize: Int(metadata.st_size))
    }

    func installExclusiveFile(
        _ name: String,
        data: Data,
        expectedUserID: uid_t
    ) throws {
        try validateComponent(name)
        if try existingFileEquals(name, data: data, expectedUserID: expectedUserID) {
            return
        }

        let temporaryName = ".\(name).\(UUID().uuidString.lowercased()).tmp"
        let temporary = openat(
            descriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard temporary >= 0 else {
            throw ContainerizationHelperClientError.unsafeConfiguration
        }
        var installed = false
        defer {
            Darwin.close(temporary)
            if !installed {
                _ = unlinkat(descriptor, temporaryName, 0)
            }
        }
        guard fchmod(temporary, S_IRUSR | S_IWUSR) == 0 else {
            throw ContainerizationHelperClientError.unsafeConfiguration
        }
        try writeAll(temporary, data: data)
        guard fsync(temporary) == 0 else {
            throw ContainerizationHelperClientError.unsafeConfiguration
        }

        if renameatx_np(descriptor, temporaryName, descriptor, name, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST,
                  try existingFileEquals(name, data: data, expectedUserID: expectedUserID) else {
                throw ContainerizationHelperClientError.unsafeConfiguration
            }
            return
        }
        installed = true
        guard fsync(descriptor) == 0 else {
            throw ContainerizationHelperClientError.unsafeConfiguration
        }
    }

    private func existingFileEquals(
        _ name: String,
        data: Data,
        expectedUserID: uid_t
    ) throws -> Bool {
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 {
            guard errno == ENOENT else {
                throw ContainerizationHelperClientError.unsafeConfiguration
            }
            return false
        }
        defer { Darwin.close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == expectedUserID,
              metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == 0o600,
              metadata.st_size == data.count else {
            throw ContainerizationHelperClientError.unsafeConfiguration
        }
        guard try readAll(file, expectedSize: data.count) == data else {
            throw ContainerizationHelperClientError.unsafeConfiguration
        }
        return true
    }

    private func openRegularFile(
        _ name: String,
        expectedUserID: uid_t
    ) throws -> (Int32, stat) {
        try validateComponent(name)
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
        var metadata = stat()
        guard fstat(file, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              (metadata.st_uid == 0 || metadata.st_uid == expectedUserID),
              metadata.st_nlink == 1,
              metadata.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID | S_ISTXT) == 0 else {
            Darwin.close(file)
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
        return (file, metadata)
    }

    private static func validateDirectory(
        _ descriptor: Int32,
        expectedUserID: uid_t,
        trustedRootOwner: Bool,
        requirePrivateMode: Bool
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == expectedUserID || (trustedRootOwner && metadata.st_uid == 0),
              metadata.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID | S_ISTXT) == 0,
              !requirePrivateMode || metadata.st_mode & 0o7777 == 0o700 else {
            throw ContainerizationHelperClientError.unsafeConfiguration
        }
    }

    private func validateComponent(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              name.utf8.count <= 255 else {
            throw ContainerizationHelperClientError.pathNotNormalized
        }
    }

    private func sha256(_ descriptor: Int32) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw ContainerizationHelperClientError.helperLaunchFailed
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func readAll(_ descriptor: Int32, expectedSize: Int) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
        var result = Data()
        result.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: min(max(expectedSize, 1), 64 * 1_024))
        while result.count < expectedSize {
            let count = Darwin.read(
                descriptor,
                &buffer,
                min(buffer.count, expectedSize - result.count)
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw ContainerizationHelperClientError.helperLaunchFailed
            }
            result.append(contentsOf: buffer[0..<count])
        }
        var trailing: UInt8 = 0
        guard Darwin.read(descriptor, &trailing, 1) == 0 else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
        return result
    }

    private func writeAll(_ descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw ContainerizationHelperClientError.unsafeConfiguration
                }
                offset += count
            }
        }
    }
}
