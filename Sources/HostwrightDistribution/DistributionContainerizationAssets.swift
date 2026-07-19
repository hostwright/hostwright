import CryptoKit
import Darwin
import Foundation
import HostwrightCore

public struct DistributionContainerizationAssetBundle: Sendable {
    let filesByPayloadPath: [String: URL]

    init(validatedFilesByPayloadPath: [String: URL]) {
        self.filesByPayloadPath = validatedFilesByPayloadPath
    }
}

public enum DistributionContainerizationAssets {
    public static let environmentVariable = "HOSTWRIGHT_CONTAINERIZATION_ASSET_ROOT"
    public static let frameworkVersion = ContainerizationRuntimeAssetContract.frameworkVersion
    public static let frameworkRevision = ContainerizationRuntimeAssetContract.frameworkRevision
    public static let initImageReference = ContainerizationRuntimeAssetContract.initImageReference
    public static let initImageDescriptorDigest =
        ContainerizationRuntimeAssetContract.initImageDescriptorDigest
    public static let initImageVariantDigest =
        "sha256:\(ContainerizationRuntimeAssetContract.initImageVariantDigest)"
    public static let kernelFileName = ContainerizationRuntimeAssetContract.kernelFileName
    public static let kernelSHA256 = ContainerizationRuntimeAssetContract.kernelSHA256
    public static let kernelArchiveURL = ContainerizationRuntimeAssetContract.kernelArchiveURL
    public static let kernelArchiveSHA256 = ContainerizationRuntimeAssetContract.kernelArchiveSHA256
    public static let kernelArchiveMember = ContainerizationRuntimeAssetContract.kernelArchiveMember

    static let initIndexDigest = ContainerizationRuntimeAssetContract.initImageIndexDigest
    static let initVariantDigest = ContainerizationRuntimeAssetContract.initImageVariantDigest
    static let initConfigurationDigest =
        ContainerizationRuntimeAssetContract.initImageConfigurationDigest
    static let initLayerDigest = ContainerizationRuntimeAssetContract.initImageLayerDigest

    public static let payloadModes: [String: Int] = [
        "share/hostwright/containerization/kernel/\(kernelFileName)": 0o644,
        "share/hostwright/containerization/vminit/oci-layout": 0o644,
        "share/hostwright/containerization/vminit/index.json": 0o644,
        "share/hostwright/containerization/vminit/blobs/sha256/\(initIndexDigest)": 0o644,
        "share/hostwright/containerization/vminit/blobs/sha256/\(initVariantDigest)": 0o644,
        "share/hostwright/containerization/vminit/blobs/sha256/\(initConfigurationDigest)": 0o644,
        "share/hostwright/containerization/vminit/blobs/sha256/\(initLayerDigest)": 0o644
    ]

    static let rootRelativePathsByPayloadPath: [String: String] = [
        "share/hostwright/containerization/kernel/\(kernelFileName)":
            "kernel/\(kernelFileName)",
        "share/hostwright/containerization/vminit/oci-layout": "vminit/oci-layout",
        "share/hostwright/containerization/vminit/index.json": "vminit/index.json",
        "share/hostwright/containerization/vminit/blobs/sha256/\(initIndexDigest)":
            "vminit/blobs/sha256/\(initIndexDigest)",
        "share/hostwright/containerization/vminit/blobs/sha256/\(initVariantDigest)":
            "vminit/blobs/sha256/\(initVariantDigest)",
        "share/hostwright/containerization/vminit/blobs/sha256/\(initConfigurationDigest)":
            "vminit/blobs/sha256/\(initConfigurationDigest)",
        "share/hostwright/containerization/vminit/blobs/sha256/\(initLayerDigest)":
            "vminit/blobs/sha256/\(initLayerDigest)"
    ]

    static let expectedSHA256ByPayloadPath: [String: String] = [
        "share/hostwright/containerization/kernel/\(kernelFileName)": kernelSHA256,
        "share/hostwright/containerization/vminit/blobs/sha256/\(initIndexDigest)": initIndexDigest,
        "share/hostwright/containerization/vminit/blobs/sha256/\(initVariantDigest)": initVariantDigest,
        "share/hostwright/containerization/vminit/blobs/sha256/\(initConfigurationDigest)":
            initConfigurationDigest,
        "share/hostwright/containerization/vminit/blobs/sha256/\(initLayerDigest)": initLayerDigest
    ]

    static let expectedSizeByPayloadPath: [String: Int64] = [
        "share/hostwright/containerization/kernel/\(kernelFileName)":
            ContainerizationRuntimeAssetContract.kernelSize,
        "share/hostwright/containerization/vminit/blobs/sha256/\(initIndexDigest)":
            ContainerizationRuntimeAssetContract.initImageIndexSize,
        "share/hostwright/containerization/vminit/blobs/sha256/\(initVariantDigest)":
            ContainerizationRuntimeAssetContract.initImageVariantSize,
        "share/hostwright/containerization/vminit/blobs/sha256/\(initConfigurationDigest)":
            ContainerizationRuntimeAssetContract.initImageConfigurationSize,
        "share/hostwright/containerization/vminit/blobs/sha256/\(initLayerDigest)":
            ContainerizationRuntimeAssetContract.initImageLayerSize
    ]

    public static func configuredRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard let path = environment[environmentVariable],
              path.hasPrefix("/"),
              !path.contains("\0"),
              path.utf8.count <= Int(PATH_MAX) else {
            throw DistributionError.invalidArguments(
                "\(environmentVariable) must identify the verified Containerization 0.35.0 asset root."
            )
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard root.path == path, root.standardizedFileURL.path == path else {
            throw DistributionError.invalidArguments(
                "\(environmentVariable) must be one normalized absolute path."
            )
        }
        return root
    }

    public static func load(
        root: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionContainerizationAssetBundle {
        guard root.path.hasPrefix("/"),
              root.standardizedFileURL.path == root.path else {
            throw DistributionError.unsafePath(
                "Containerization asset root must be one normalized non-symlink absolute path."
            )
        }
        let rootDescriptor = try openRoot(root.path)
        defer { close(rootDescriptor) }
        let expectedOwner = geteuid()
        let rootIdentity = try validateDirectory(
            descriptor: rootDescriptor,
            path: root.path,
            expectedOwner: expectedOwner,
            role: "root"
        )

        var files: [String: URL] = [:]
        var metadataFiles: [String: Data] = [:]
        for payloadPath in rootRelativePathsByPayloadPath.keys.sorted() {
            guard !cancellation.isCancelled else {
                throw DistributionError.commandCancelled("Containerization asset verification")
            }
            guard let relativePath = rootRelativePathsByPayloadPath[payloadPath] else {
                throw DistributionError.invalidArtifact("Containerization asset lock is incomplete.")
            }
            let url = root.appendingPathComponent(relativePath, isDirectory: false)
            try withParentDirectory(
                rootDescriptor: rootDescriptor,
                rootPath: root.path,
                relativePath: relativePath,
                expectedOwner: expectedOwner,
                rootIdentity: rootIdentity
            ) { parentDescriptor, name, directoryIdentities in
                let descriptor = openat(
                    parentDescriptor,
                    name,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    throw DistributionError.invalidArtifact(
                        "Containerization asset is missing or not a regular non-symlink file: \(relativePath)"
                    )
                }
                defer { close(descriptor) }
                var openedMetadata = stat()
                try validateFile(
                    descriptor: descriptor,
                    path: url.path,
                    expectedOwner: expectedOwner,
                    metadata: &openedMetadata
                )
                if let expectedSize = expectedSizeByPayloadPath[payloadPath],
                   Int64(openedMetadata.st_size) != expectedSize {
                    throw DistributionError.invalidArtifact(
                        "Containerization asset size differs: \(relativePath)"
                    )
                }
                if let maximumSize = metadataMaximumSize(payloadPath: payloadPath) {
                    guard openedMetadata.st_size <= maximumSize else {
                        throw DistributionError.invalidArtifact(
                            "Containerization asset metadata is oversized: \(relativePath)"
                        )
                    }
                    metadataFiles[payloadPath] = try readData(
                        descriptor: descriptor,
                        size: Int(openedMetadata.st_size),
                        cancellation: cancellation
                    )
                } else if let expectedDigest = expectedSHA256ByPayloadPath[payloadPath],
                          try sha256(
                            descriptor: descriptor,
                            cancellation: cancellation
                          ) != expectedDigest {
                    throw DistributionError.checksumMismatch(relativePath)
                }

                var finalMetadata = stat()
                var namedMetadata = stat()
                guard fstat(descriptor, &finalMetadata) == 0,
                      fstatat(
                        parentDescriptor,
                        name,
                        &namedMetadata,
                        AT_SYMLINK_NOFOLLOW
                      ) == 0,
                      namedMetadata.st_mode & S_IFMT == S_IFREG,
                      DistributionValidatedSourceIdentity(metadata: openedMetadata)
                        == DistributionValidatedSourceIdentity(metadata: finalMetadata),
                      DistributionValidatedSourceIdentity(metadata: finalMetadata)
                        == DistributionValidatedSourceIdentity(metadata: namedMetadata) else {
                    throw DistributionError.invalidArtifact(
                        "Containerization asset changed during verification: \(relativePath)"
                    )
                }
                files[payloadPath] = try DistributionFileSystem.bindValidatedSource(
                    url,
                    metadata: finalMetadata,
                    directoryIdentities: directoryIdentities
                )
            }
        }

        try validateLayoutMetadata(metadataFiles)
        guard Set(files.keys) == Set(payloadModes.keys) else {
            throw DistributionError.invalidArtifact("Containerization asset payload is incomplete.")
        }
        return DistributionContainerizationAssetBundle(validatedFilesByPayloadPath: files)
    }

    private static func validateLayoutMetadata(_ files: [String: Data]) throws {
        let layoutPath = "share/hostwright/containerization/vminit/oci-layout"
        let indexPath = "share/hostwright/containerization/vminit/index.json"
        guard let layoutData = files[layoutPath], let indexData = files[indexPath] else {
            throw DistributionError.invalidArtifact("Containerization OCI layout metadata is missing.")
        }
        guard layoutData.count <= 4_096,
              let layout = try JSONSerialization.jsonObject(with: layoutData) as? [String: Any],
              layout.count == 1,
              layout["imageLayoutVersion"] as? String == "1.0.0" else {
            throw DistributionError.invalidArtifact("Containerization OCI layout version is invalid.")
        }

        guard indexData.count <= 64 * 1_024,
              let index = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              index["schemaVersion"] as? Int == 2,
              let manifests = index["manifests"] as? [[String: Any]],
              manifests.count == 1,
              let descriptor = manifests.first,
              descriptor["mediaType"] as? String == "application/vnd.oci.image.index.v1+json",
              descriptor["digest"] as? String == initImageDescriptorDigest,
              descriptor["size"] as? Int == 306,
              let annotations = descriptor["annotations"] as? [String: String],
              annotations["org.opencontainers.image.ref.name"] == initImageReference else {
            throw DistributionError.invalidArtifact("Containerization OCI image descriptor is invalid.")
        }
    }

    private static func withParentDirectory<T>(
        rootDescriptor: Int32,
        rootPath: String,
        relativePath: String,
        expectedOwner: uid_t,
        rootIdentity: DistributionValidatedSourceIdentity,
        body: (Int32, String, [DistributionValidatedSourceIdentity]) throws -> T
    ) throws -> T {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count >= 2,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DistributionError.invalidArtifact(
                "Containerization asset lock contains an invalid relative path."
            )
        }
        var descriptors: [Int32] = []
        defer { descriptors.reversed().forEach { close($0) } }
        var currentDescriptor = rootDescriptor
        var currentPath = rootPath
        var directoryIdentities = [rootIdentity]
        for component in components.dropLast() {
            let descriptor = openat(
                currentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw DistributionError.unsafePath(
                    "Containerization asset directory is missing or unsafe: \(component)"
                )
            }
            descriptors.append(descriptor)
            currentPath += "/\(component)"
            directoryIdentities.append(try validateDirectory(
                descriptor: descriptor,
                path: currentPath,
                expectedOwner: expectedOwner,
                role: component
            ))
            currentDescriptor = descriptor
        }
        return try body(currentDescriptor, components.last!, directoryIdentities)
    }

    private static func openRoot(_ path: String) throws -> Int32 {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            throw DistributionError.unsafePath(
                "Containerization asset root must not be the filesystem root."
            )
        }
        var currentDescriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard currentDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for component in components {
            let childDescriptor = openat(
                currentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            close(currentDescriptor)
            guard childDescriptor >= 0 else {
                throw DistributionError.unsafePath(
                    "Containerization asset root path contains a symlink or unsafe directory."
                )
            }
            currentDescriptor = childDescriptor
        }
        return currentDescriptor
    }

    private static func validateDirectory(
        descriptor: Int32,
        path: String,
        expectedOwner: uid_t,
        role: String
    ) throws -> DistributionValidatedSourceIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == expectedOwner,
              metadata.st_mode & 0o7777 == 0o700 else {
            throw DistributionError.unsafePath(
                "Containerization asset \(role) must be current-user owned with mode 0700."
            )
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                fileDescriptor: descriptor,
                path: path,
                role: "Containerization asset \(role)"
            )
        } catch {
            throw DistributionError.unsafePath(
                "Containerization asset \(role) must not grant access through an ACL."
            )
        }
        return DistributionValidatedSourceIdentity(metadata: metadata)
    }

    private static func validateFile(
        descriptor: Int32,
        path: String,
        expectedOwner: uid_t,
        metadata: inout stat
    ) throws {
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == expectedOwner,
              metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == 0o644,
              metadata.st_size > 0 else {
            throw DistributionError.invalidArtifact(
                "Containerization asset must be a current-user owned 0644 single-link regular file."
            )
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                fileDescriptor: descriptor,
                path: path,
                role: "Containerization asset file"
            )
        } catch {
            throw DistributionError.invalidArtifact(
                "Containerization asset file must not grant access through an ACL."
            )
        }
    }

    private static func metadataMaximumSize(payloadPath: String) -> off_t? {
        switch payloadPath {
        case "share/hostwright/containerization/vminit/oci-layout": 4_096
        case "share/hostwright/containerization/vminit/index.json": 64 * 1_024
        default: nil
        }
    }

    private static func readData(
        descriptor: Int32,
        size: Int,
        cancellation: SecureSubprocessCancellation
    ) throws -> Data {
        var data = Data()
        data.reserveCapacity(size)
        var buffer = [UInt8](repeating: 0, count: min(size, 64 * 1_024))
        while data.count < size {
            guard !cancellation.isCancelled else {
                throw DistributionError.commandCancelled("Containerization asset verification")
            }
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, size - data.count))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw DistributionError.invalidArtifact(
                    "Containerization asset changed while metadata was read."
                )
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    private static func sha256(
        descriptor: Int32,
        cancellation: SecureSubprocessCancellation
    ) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            guard !cancellation.isCancelled else {
                throw DistributionError.commandCancelled("Containerization asset verification")
            }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
