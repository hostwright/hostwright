import Darwin
import Foundation
import HostwrightCore

public enum RegistryCredentialDocumentLoader {
    public static func loadDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) throws -> [DockerCredentialConfigurationDocument] {
        var candidates: [(String, RegistryCredentialLookupSource)] = []
        if let dockerConfiguration = environment["DOCKER_CONFIG"] {
            guard dockerConfiguration.hasPrefix("/") else {
                throw RegistryCredentialLookupError.invalidConfiguration
            }
            candidates.append(
                (
                    URL(fileURLWithPath: dockerConfiguration, isDirectory: true)
                        .appendingPathComponent("config.json")
                        .path,
                    .dockerAuthFile
                )
            )
        } else {
            candidates.append(
                (
                    URL(fileURLWithPath: homeDirectory, isDirectory: true)
                        .appendingPathComponent(".docker/config.json")
                        .path,
                    .dockerAuthFile
                )
            )
        }

        if let registryAuthFile = environment["REGISTRY_AUTH_FILE"] {
            guard registryAuthFile.hasPrefix("/") else {
                throw RegistryCredentialLookupError.invalidConfiguration
            }
            candidates.append((registryAuthFile, .ociAuthFile))
        } else {
            candidates.append(
                (
                    URL(fileURLWithPath: homeDirectory, isDirectory: true)
                        .appendingPathComponent(".config/containers/auth.json")
                        .path,
                    .ociAuthFile
                )
            )
        }

        var documents: [DockerCredentialConfigurationDocument] = []
        for (path, source) in candidates {
            var metadata = stat()
            if lstat(path, &metadata) != 0 {
                if errno == ENOENT || errno == ENOTDIR {
                    continue
                }
                throw RegistryCredentialLookupError.invalidConfiguration
            }
            documents.append(
                DockerCredentialConfigurationDocument(
                    data: try readGuarded(path),
                    source: source
                )
            )
        }
        return documents
    }

    private static func readGuarded(_ path: String) throws -> Data {
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard path.hasPrefix("/"), !components.isEmpty else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }

        var directory = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        defer { Darwin.close(directory) }
        try validateDirectory(directory)

        for component in components.dropLast() {
            let child = component.withCString {
                Darwin.openat(
                    directory,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard child >= 0 else {
                throw RegistryCredentialLookupError.invalidConfiguration
            }
            do {
                try validateDirectory(child)
            } catch {
                Darwin.close(child)
                throw error
            }
            Darwin.close(directory)
            directory = child
        }

        let finalName = components[components.count - 1]
        let descriptor = finalName.withCString {
            Darwin.openat(
                directory,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == Darwin.geteuid(),
              before.st_nlink == 1,
              before.st_mode & 0o077 == 0,
              before.st_size > 0,
              before.st_size <= DockerRegistryCredentialLookup.maximumConfigurationBytes else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        try validateNoAccessGrantingACL(descriptor)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw RegistryCredentialLookupError.invalidConfiguration
            }
            guard data.count + count <=
                    DockerRegistryCredentialLookup.maximumConfigurationBytes else {
                throw RegistryCredentialLookupError.configurationTooLarge
            }
            data.append(buffer, count: count)
        }

        var after = stat()
        var named = stat()
        let namedStatus = finalName.withCString {
            Darwin.fstatat(directory, $0, &named, AT_SYMLINK_NOFOLLOW)
        }
        guard Darwin.fstat(descriptor, &after) == 0,
              namedStatus == 0,
              identity(before) == identity(after),
              identity(before) == identity(named),
              Int64(data.count) == after.st_size else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        return data
    }

    private static func validateDirectory(_ descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == 0 || metadata.st_uid == Darwin.geteuid() else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        let writableByOthers = metadata.st_mode & 0o022 != 0
        let protectedSharedDirectory =
            metadata.st_uid == 0 && metadata.st_mode & mode_t(S_ISVTX) != 0
        guard !writableByOthers || protectedSharedDirectory else {
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        try validateNoAccessGrantingACL(descriptor)
    }

    private static func validateNoAccessGrantingACL(_ descriptor: Int32) throws {
        errno = 0
        guard let accessControlList = acl_get_fd_np(
            descriptor,
            ACL_TYPE_EXTENDED
        ) else {
            if errno == ENOENT || errno == ENOTSUP {
                return
            }
            throw RegistryCredentialLookupError.invalidConfiguration
        }
        defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }

        var entry: acl_entry_t?
        var entryID = ACL_FIRST_ENTRY.rawValue
        while true {
            errno = 0
            let result = acl_get_entry(accessControlList, entryID, &entry)
            if result != 0 {
                if errno == EINVAL {
                    return
                }
                throw RegistryCredentialLookupError.invalidConfiguration
            }
            guard let entry else {
                throw RegistryCredentialLookupError.invalidConfiguration
            }
            var tag = acl_tag_t(0)
            guard acl_get_tag_type(entry, &tag) == 0,
                  tag == ACL_EXTENDED_DENY else {
                throw RegistryCredentialLookupError.invalidConfiguration
            }
            entryID = ACL_NEXT_ENTRY.rawValue
        }
    }

    private static func identity(_ metadata: stat) -> FileIdentity {
        FileIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            mode: UInt16(metadata.st_mode),
            owner: UInt32(metadata.st_uid),
            links: UInt16(metadata.st_nlink),
            size: Int64(metadata.st_size),
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        )
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt16
        let owner: UInt32
        let links: UInt16
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }
}

public struct SecureDockerCredentialHelperResolver:
    DockerCredentialHelperResolving,
    Sendable
{
    private let searchPath: String?

    public init(
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"]
    ) {
        self.searchPath = searchPath
    }

    public func executableURL(for helperName: String) -> URL? {
        guard let identity = try? SecureExecutableResolver.resolve(
            named: "docker-credential-\(helperName)",
            searchPath: searchPath,
            ownershipPolicy: .rootOrCurrentUser
        ) else {
            return nil
        }
        return URL(fileURLWithPath: identity.path)
    }
}
