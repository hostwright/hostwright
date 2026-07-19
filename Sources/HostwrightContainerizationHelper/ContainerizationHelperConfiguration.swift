import CryptoKit
import Darwin
import Foundation
import HostwrightCore

enum ContainerizationHelperConfigurationError: Error, Equatable {
    case configurationMissing
    case configurationUnsafe
    case configurationInvalid
    case unsupportedSchema
    case unsupportedFramework
    case unsafePath
    case unsafeAsset
    case assetDigestMismatch
}

struct ContainerizationHelperConfiguration: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let frameworkVersion = ContainerizationRuntimeAssetContract.frameworkVersion

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

    var dataRootURL: URL { URL(fileURLWithPath: dataRootPath, isDirectory: true) }
    var runtimeDirectoryURL: URL {
        URL(fileURLWithPath: runtimeDirectoryPath, isDirectory: true)
    }
    var kernelURL: URL { URL(fileURLWithPath: kernelPath, isDirectory: false) }
    var initImageLayoutURL: URL {
        URL(fileURLWithPath: initImageLayoutPath, isDirectory: true)
    }
    var initfsCacheFileName: String {
        let variant = String(initImageVariantDigest.dropFirst("sha256:".count))
        return "initfs-\(framework)-\(variant).ext4"
    }

    static func defaultConfigurationURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Hostwright/config", isDirectory: true)
            .appendingPathComponent("containerization-helper.json", isDirectory: false)
    }

    static func load(at url: URL) throws -> ContainerizationHelperConfiguration {
        try validateNormalizedAbsolute(url)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT {
                throw ContainerizationHelperConfigurationError.configurationMissing
            }
            throw ContainerizationHelperConfigurationError.configurationUnsafe
        }
        guard isPrivateRegularFile(metadata, expectedOwner: geteuid()),
              metadata.st_size > 0,
              metadata.st_size <= 64 * 1_024 else {
            throw ContainerizationHelperConfigurationError.configurationUnsafe
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let configuration: ContainerizationHelperConfiguration
        do {
            configuration = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw ContainerizationHelperConfigurationError.configurationInvalid
        }
        try configuration.validate()
        return configuration
    }

    func validate() throws {
        guard schema == Self.schemaVersion else {
            throw ContainerizationHelperConfigurationError.unsupportedSchema
        }
        guard framework == Self.frameworkVersion else {
            throw ContainerizationHelperConfigurationError.unsupportedFramework
        }
        try Self.validateNormalizedAbsolute(dataRootURL)
        try Self.validateNormalizedAbsolute(runtimeDirectoryURL)
        try Self.validateNormalizedAbsolute(kernelURL)
        try Self.validateNormalizedAbsolute(initImageLayoutURL)
        guard dataRootURL.path != runtimeDirectoryURL.path,
              dataRootURL.path != initImageLayoutURL.path,
              runtimeDirectoryURL.path != initImageLayoutURL.path,
              Self.validSHA256(kernelSHA256),
              Self.validOCIDigest(initImageDescriptorDigest),
              Self.validOCIDigest(initImageVariantDigest),
              !initImageReference.isEmpty,
              initImageReference.utf8.count <= 4_096,
              initImageReference.rangeOfCharacter(from: .controlCharacters) == nil,
              rootfsSizeBytes >= 256 * 1_024 * 1_024,
              rootfsSizeBytes <= 64 * 1_024 * 1_024 * 1_024 else {
            throw ContainerizationHelperConfigurationError.configurationInvalid
        }

        try Self.requireSafeAsset(kernelURL, expectedDigest: kernelSHA256)
        try Self.requireSafeDirectory(initImageLayoutURL)
    }

    private static func requireSafeAsset(_ url: URL, expectedDigest: String) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              isTrustedRegularFile(metadata),
              metadata.st_size > 0,
              metadata.st_size <= 1 * 1_024 * 1_024 * 1_024 else {
            throw ContainerizationHelperConfigurationError.unsafeAsset
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == expectedDigest else {
            throw ContainerizationHelperConfigurationError.assetDigestMismatch
        }
    }

    private static func requireSafeDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              trustedOwner(metadata.st_uid),
              metadata.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0 else {
            throw ContainerizationHelperConfigurationError.unsafeAsset
        }

        let requiredNames = ["oci-layout", "index.json", "blobs"]
        for name in requiredNames where !FileManager.default.fileExists(
            atPath: url.appendingPathComponent(name).path
        ) {
            throw ContainerizationHelperConfigurationError.unsafeAsset
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            throw ContainerizationHelperConfigurationError.unsafeAsset
        }
        var entryCount = 0
        while let entry = enumerator.nextObject() as? URL {
            entryCount += 1
            guard entryCount <= 100_000 else {
                throw ContainerizationHelperConfigurationError.unsafeAsset
            }
            var entryMetadata = stat()
            guard lstat(entry.path, &entryMetadata) == 0,
                  trustedOwner(entryMetadata.st_uid),
                  entryMetadata.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0 else {
                throw ContainerizationHelperConfigurationError.unsafeAsset
            }
            switch entryMetadata.st_mode & S_IFMT {
            case S_IFDIR:
                continue
            case S_IFREG:
                guard entryMetadata.st_nlink == 1,
                      entryMetadata.st_size >= 0,
                      entryMetadata.st_size <= 8 * 1_024 * 1_024 * 1_024 else {
                    throw ContainerizationHelperConfigurationError.unsafeAsset
                }
            default:
                throw ContainerizationHelperConfigurationError.unsafeAsset
            }
        }
    }

    private static func validateNormalizedAbsolute(_ url: URL) throws {
        guard url.path.hasPrefix("/"),
              url.standardizedFileURL.path == url.path,
              url.path.utf8.count <= 1_024 else {
            throw ContainerizationHelperConfigurationError.unsafePath
        }
    }

    private static func isPrivateRegularFile(_ metadata: stat, expectedOwner: uid_t) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG &&
            metadata.st_uid == expectedOwner &&
            metadata.st_nlink == 1 &&
            metadata.st_mode & (S_IRWXG | S_IRWXO | S_ISUID | S_ISGID | S_ISTXT) == 0 &&
            metadata.st_mode & S_IRUSR != 0
    }

    private static func isTrustedRegularFile(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG &&
            trustedOwner(metadata.st_uid) &&
            metadata.st_nlink == 1 &&
            metadata.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0
    }

    private static func trustedOwner(_ owner: uid_t) -> Bool {
        owner == 0 || owner == geteuid()
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private static func validOCIDigest(_ value: String) -> Bool {
        value.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}
