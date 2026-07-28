import CryptoKit
import Darwin
import Foundation
import HostwrightCore

struct RuntimeUnixSocketPublicationLease: Equatable, Sendable {
    let publication: RuntimeUnixSocketPublication
    let markerName: String
    let ownership: RuntimeUnixSocketOwnershipMarker
}

struct RuntimeUnixSocketOwnershipMarker:
    Codable,
    Equatable,
    Sendable
{
    let schemaVersion: Int
    let hostPath: String
    let containerPath: String
    let mode: String
    let resourceIdentifier: String
    let resourceUUID: String
    let resourceGeneration: Int
    let projectUUID: String
    let projectGeneration: Int
    let providerID: String
    let providerGeneration: Int
    let fencingToken: String
    let socketDevice: UInt64?
    let socketInode: UInt64?

    func matchesStableIdentity(
        _ other: RuntimeUnixSocketOwnershipMarker
    ) -> Bool {
        schemaVersion == other.schemaVersion &&
            hostPath == other.hostPath &&
            containerPath == other.containerPath &&
            mode == other.mode &&
            resourceIdentifier == other.resourceIdentifier &&
            resourceUUID == other.resourceUUID &&
            resourceGeneration == other.resourceGeneration &&
            projectUUID == other.projectUUID &&
            projectGeneration == other.projectGeneration &&
            providerID == other.providerID &&
            providerGeneration == other.providerGeneration
    }

    var hasCompleteSocketIdentity: Bool {
        socketDevice != nil && socketInode != nil
    }

    func matchesSocket(_ metadata: stat) -> Bool {
        guard let socketDevice,
              let socketInode else {
            return false
        }
        return socketDevice == UInt64(metadata.st_dev) &&
            socketInode == UInt64(metadata.st_ino)
    }

    func bindingSocket(_ metadata: stat) -> Self {
        replacingSocketIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    func withoutSocketIdentity() -> Self {
        replacingSocketIdentity(device: nil, inode: nil)
    }

    private func replacingSocketIdentity(
        device: UInt64?,
        inode: UInt64?
    ) -> Self {
        RuntimeUnixSocketOwnershipMarker(
            schemaVersion: schemaVersion,
            hostPath: hostPath,
            containerPath: containerPath,
            mode: mode,
            resourceIdentifier: resourceIdentifier,
            resourceUUID: resourceUUID,
            resourceGeneration: resourceGeneration,
            projectUUID: projectUUID,
            projectGeneration: projectGeneration,
            providerID: providerID,
            providerGeneration: providerGeneration,
            fencingToken: fencingToken,
            socketDevice: device,
            socketInode: inode
        )
    }
}

enum RuntimeUnixSocketPublicationSecurity {
    private static let markerSchemaVersion = 1
    private static let maximumMarkerBytes = 8 * 1_024

    static func prepareForCreate(
        _ publications: [RuntimeUnixSocketPublication],
        context: RuntimeMutationContext,
        resourceIdentifier: String,
        rootDirectory: String? = nil
    ) throws -> [RuntimeUnixSocketPublicationLease] {
        guard !publications.isEmpty else { return [] }
        let root = try expectedRoot(rootDirectory)
        let directory = try openSecureRoot(root)
        defer { Darwin.close(directory) }

        let ordered = publications.sorted(by: socketOrder)
        guard Set(ordered.map(\.hostPath)).count == ordered.count else {
            throw rejected(
                "Unix socket publications contain duplicate host paths."
            )
        }

        var leases: [RuntimeUnixSocketPublicationLease] = []
        var createdMarkers: [String] = []
        do {
            for publication in ordered {
                let lease = try lease(
                    publication,
                    context: context,
                    resourceIdentifier: resourceIdentifier,
                    root: root
                )
                let existingMarker = try readMarkerIfPresent(
                    named: lease.markerName,
                    directory: directory
                )
                if let existingMarker {
                    guard existingMarker.matchesStableIdentity(
                        lease.ownership
                    ) else {
                        throw rejected(
                            "Unix socket ownership metadata conflicts with the exact confirmed lifecycle generation."
                        )
                    }
                }

                let socketName = try fileName(
                    for: publication,
                    root: root
                )
                switch try entry(
                    named: socketName,
                    directory: directory
                ) {
                case .absent:
                    break
                case .socket:
                    let metadata = try requiredSocketMetadata(
                        named: socketName,
                        directory: directory
                    )
                    guard let existingMarker,
                          existingMarker.matchesSocket(metadata) else {
                        throw rejected(
                            "Unix socket host path lacks exact durable device and inode ownership evidence."
                        )
                    }
                    try unlink(
                        named: socketName,
                        directory: directory
                    )
                case .other:
                    throw rejected(
                        "Unix socket host path conflicts with an unmanaged filesystem entry."
                    )
                }

                if existingMarker == nil {
                    try createMarker(
                        lease.ownership,
                        named: lease.markerName,
                        directory: directory
                    )
                    createdMarkers.append(lease.markerName)
                } else if existingMarker != lease.ownership {
                    try replaceMarker(
                        lease.ownership,
                        named: lease.markerName,
                        directory: directory
                    )
                }
                leases.append(lease)
            }
            return leases
        } catch {
            for marker in createdMarkers.reversed() {
                try? unlinkIfPresent(
                    named: marker,
                    directory: directory
                )
            }
            throw error
        }
    }

    static func verifyCreated(
        _ leases: [RuntimeUnixSocketPublicationLease],
        requireSocket: Bool = true,
        rootDirectory: String? = nil
    ) throws {
        guard !leases.isEmpty else { return }
        let root = try expectedRoot(rootDirectory)
        let directory = try openSecureRoot(root)
        defer { Darwin.close(directory) }

        for lease in leases.sorted(by: leaseOrder) {
            guard let marker = try readMarkerIfPresent(
                named: lease.markerName,
                directory: directory
            ), marker.matchesStableIdentity(lease.ownership) else {
                throw rejected(
                    "Unix socket ownership metadata changed during runtime creation."
                )
            }
            let name = try fileName(
                for: lease.publication,
                root: root
            )
            let existing = try entry(
                named: name,
                directory: directory
            )
            if existing == .absent, !requireSocket {
                continue
            }
            guard existing == .socket else {
                throw rejected(
                    "Runtime did not publish the exact owned Unix socket."
                )
            }
            let before = try requiredSocketMetadata(
                named: name,
                directory: directory
            )
            guard fchmodat(
                directory,
                name,
                mode_t(lease.publication.mode.fileMode),
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw rejected(
                    "Unix socket permissions could not be applied safely."
                )
            }
            let after = try requiredSocketMetadata(
                named: name,
                directory: directory
            )
            guard before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino,
                  after.st_uid == getuid(),
                  after.st_mode & 0o777 ==
                    mode_t(lease.publication.mode.fileMode) else {
                throw rejected(
                    "Unix socket identity or permissions changed during verification."
                )
            }
            try bindMarker(
                existing: marker,
                expected: lease.ownership,
                to: after,
                named: lease.markerName,
                socketName: name,
                directory: directory
            )
        }
    }

    static func cleanupNoEffect(
        _ leases: [RuntimeUnixSocketPublicationLease],
        rootDirectory: String? = nil
    ) throws {
        guard !leases.isEmpty else { return }
        let root = try expectedRoot(rootDirectory)
        let directory = try openSecureRoot(root)
        defer { Darwin.close(directory) }

        for lease in leases.sorted(by: leaseOrder) {
            guard case .absent = try entry(
                named: fileName(for: lease.publication, root: root),
                directory: directory
            ) else {
                continue
            }
            guard try readMarkerIfPresent(
                named: lease.markerName,
                directory: directory
            ) == lease.ownership else {
                throw rejected(
                    "Unix socket cleanup refused mismatched ownership metadata."
                )
            }
            try unlinkIfPresent(
                named: lease.markerName,
                directory: directory
            )
        }
    }

    static func verifyExisting(
        _ publications: [RuntimeUnixSocketPublication],
        context: RuntimeMutationContext,
        resourceIdentifier: String,
        rootDirectory: String? = nil
    ) throws {
        guard !publications.isEmpty else { return }
        let root = try expectedRoot(rootDirectory)
        let directory = try openSecureRoot(root)
        defer { Darwin.close(directory) }

        for publication in publications.sorted(by: socketOrder) {
            let expected = try lease(
                publication,
                context: context,
                resourceIdentifier: resourceIdentifier,
                root: root
            )
            guard let marker = try readMarkerIfPresent(
                named: expected.markerName,
                directory: directory
            ), marker.matchesStableIdentity(expected.ownership) else {
                throw rejected(
                    "Unix socket verification requires exact Hostwright ownership metadata."
                )
            }
            let name = try fileName(for: publication, root: root)
            let before = try requiredSocketMetadata(
                named: name,
                directory: directory
            )
            guard fchmodat(
                directory,
                name,
                mode_t(publication.mode.fileMode),
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw rejected(
                    "Unix socket permissions could not be applied safely."
                )
            }
            let after = try requiredSocketMetadata(
                named: name,
                directory: directory
            )
            guard before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino,
                  after.st_mode & 0o777 ==
                    mode_t(publication.mode.fileMode) else {
                throw rejected(
                    "Unix socket verification found changed identity or unsafe permissions."
                )
            }
            try bindMarker(
                existing: marker,
                expected: expected.ownership,
                to: after,
                named: expected.markerName,
                socketName: name,
                directory: directory
            )
        }
    }

    static func prepareForActivation(
        _ publications: [RuntimeUnixSocketPublication],
        context: RuntimeMutationContext,
        resourceIdentifier: String,
        rootDirectory: String? = nil
    ) throws {
        guard !publications.isEmpty else { return }
        let root = try expectedRoot(rootDirectory)
        let directory = try openSecureRoot(root)
        defer { Darwin.close(directory) }

        for publication in publications.sorted(by: socketOrder) {
            let expected = try lease(
                publication,
                context: context,
                resourceIdentifier: resourceIdentifier,
                root: root
            )
            guard let marker = try readMarkerIfPresent(
                named: expected.markerName,
                directory: directory
            ), marker.matchesStableIdentity(expected.ownership) else {
                throw rejected(
                    "Unix socket activation requires exact Hostwright ownership metadata."
                )
            }
            let name = try fileName(for: publication, root: root)
            switch try entry(named: name, directory: directory) {
            case .absent:
                break
            case .socket:
                let metadata = try requiredSocketMetadata(
                    named: name,
                    directory: directory
                )
                guard marker.matchesSocket(metadata) else {
                    throw rejected(
                        "Unix socket activation refused a path without exact durable device and inode ownership."
                    )
                }
                try unlink(named: name, directory: directory)
            case .other:
                throw rejected(
                    "Unix socket activation found an unmanaged filesystem entry."
                )
            }
            if marker != expected.ownership {
                try replaceMarker(
                    expected.ownership,
                    named: expected.markerName,
                    directory: directory
                )
            }
        }
    }

    static func prepareForDelete(
        _ publications: [RuntimeUnixSocketPublication],
        context: RuntimeMutationContext,
        resourceIdentifier: String,
        rootDirectory: String? = nil
    ) throws -> [RuntimeUnixSocketPublicationLease] {
        guard !publications.isEmpty else { return [] }
        let root = try expectedRoot(rootDirectory)
        let directory = try openSecureRoot(root)
        defer { Darwin.close(directory) }

        return try publications.sorted(by: socketOrder).map { publication in
            let lease = try lease(
                publication,
                context: context,
                resourceIdentifier: resourceIdentifier,
                root: root
            )
            guard let existing = try readMarkerIfPresent(
                named: lease.markerName,
                directory: directory
            ), existing.matchesStableIdentity(lease.ownership) else {
                throw rejected(
                    "Unix socket deletion requires exact Hostwright ownership metadata."
                )
            }
            let socketName = try fileName(
                for: publication,
                root: root
            )
            let existingEntry = try entry(
                named: socketName,
                directory: directory
            )
            guard existingEntry != .other else {
                throw rejected(
                    "Unix socket deletion found an unmanaged host path."
                )
            }
            let deletionOwnership: RuntimeUnixSocketOwnershipMarker
            if existingEntry == .socket {
                let metadata = try requiredSocketMetadata(
                    named: socketName,
                    directory: directory
                )
                guard existing.matchesSocket(metadata) else {
                    throw rejected(
                        "Unix socket deletion refused a replaced or untracked socket inode."
                    )
                }
                deletionOwnership =
                    lease.ownership.bindingSocket(metadata)
            } else {
                deletionOwnership = lease.ownership
            }
            if existing != deletionOwnership {
                try replaceMarker(
                    deletionOwnership,
                    named: lease.markerName,
                    directory: directory
                )
            }
            return RuntimeUnixSocketPublicationLease(
                publication: publication,
                markerName: lease.markerName,
                ownership: deletionOwnership
            )
        }
    }

    static func finalizeDelete(
        _ leases: [RuntimeUnixSocketPublicationLease],
        rootDirectory: String? = nil
    ) throws {
        guard !leases.isEmpty else { return }
        let root = try expectedRoot(rootDirectory)
        let directory = try openSecureRoot(root)
        defer { Darwin.close(directory) }

        for lease in leases.sorted(by: leaseOrder) {
            guard try readMarkerIfPresent(
                named: lease.markerName,
                directory: directory
            ) == lease.ownership else {
                throw rejected(
                    "Unix socket cleanup refused changed ownership metadata."
                )
            }
            let name = try fileName(
                for: lease.publication,
                root: root
            )
            switch try entry(named: name, directory: directory) {
            case .absent:
                break
            case .socket:
                let metadata = try requiredSocketMetadata(
                    named: name,
                    directory: directory
                )
                guard lease.ownership.matchesSocket(metadata) else {
                    throw rejected(
                        "Unix socket cleanup refused a replaced or untracked socket inode."
                    )
                }
                try unlink(named: name, directory: directory)
            case .other:
                throw rejected(
                    "Unix socket cleanup refused an unmanaged filesystem entry."
                )
            }
            try unlink(
                named: lease.markerName,
                directory: directory
            )
        }
    }

    private static func lease(
        _ publication: RuntimeUnixSocketPublication,
        context: RuntimeMutationContext,
        resourceIdentifier: String,
        root: String
    ) throws -> RuntimeUnixSocketPublicationLease {
        _ = try fileName(for: publication, root: root)
        guard RuntimeManagedResourceIdentity.isSupportedIdentifier(
            resourceIdentifier
        ), context.validationIssue == nil else {
            throw rejected(
                "Unix socket publication requires exact runtime identity and fencing context."
            )
        }
        let marker = RuntimeUnixSocketOwnershipMarker(
            schemaVersion: markerSchemaVersion,
            hostPath: publication.hostPath,
            containerPath: publication.containerPath,
            mode: publication.mode.rawValue,
            resourceIdentifier: resourceIdentifier,
            resourceUUID: context.resourceUUID,
            resourceGeneration: context.resourceGeneration,
            projectUUID: context.projectResourceUUID,
            projectGeneration: context.projectGeneration,
            providerID: context.providerID.rawValue,
            providerGeneration: context.providerGeneration,
            fencingToken: context.fencingToken,
            socketDevice: nil,
            socketInode: nil
        )
        let digest = SHA256.hash(
            data: Data(publication.hostPath.utf8)
        ).prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
        return RuntimeUnixSocketPublicationLease(
            publication: publication,
            markerName: ".hostwright-\(digest).owner",
            ownership: marker
        )
    }

    private static func expectedRoot(
        _ override: String?
    ) throws -> String {
        if let override {
            return try HostwrightLocalPathResolver.normalizedAbsolutePath(
                override,
                role: "published socket root"
            )
        }
        return try HostwrightLocalPathResolver.resolve()
            .layout.publishedSocketDirectory
    }

    private static func openSecureRoot(_ root: String) throws -> Int32 {
        let parent = URL(
            fileURLWithPath: root,
            isDirectory: true
        ).deletingLastPathComponent().path
        let parentDescriptor = Darwin.open(
            parent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw rejected(
                "Hostwright runtime directory is unavailable or unsafe."
            )
        }
        defer { Darwin.close(parentDescriptor) }
        try validateDirectory(
            parentDescriptor,
            expectedMode: nil
        )
        try HostwrightLocalFilesystemPolicy
            .validateNoAccessGrantingACL(
                fileDescriptor: parentDescriptor,
                path: parent,
                role: "Hostwright runtime directory"
            )

        let name = URL(fileURLWithPath: root).lastPathComponent
        if mkdirat(parentDescriptor, name, 0o700) != 0,
           errno != EEXIST {
            throw rejected(
                "Hostwright private Unix socket root could not be created."
            )
        }
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw rejected(
                "Hostwright private Unix socket root is unsafe."
            )
        }
        do {
            try validateDirectory(descriptor, expectedMode: 0o700)
            try HostwrightLocalFilesystemPolicy
                .validateNoAccessGrantingACL(
                    fileDescriptor: descriptor,
                    path: root,
                    role: "Hostwright published socket directory"
                )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateDirectory(
        _ descriptor: Int32,
        expectedMode: mode_t?
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o022 == 0,
              expectedMode == nil ||
                metadata.st_mode & 0o777 == expectedMode else {
            throw rejected(
                "Hostwright Unix socket directory ownership or permissions are unsafe."
            )
        }
    }

    private enum EntryKind: Equatable {
        case absent
        case socket
        case other
    }

    private static func entry(
        named name: String,
        directory: Int32
    ) throws -> EntryKind {
        var metadata = stat()
        if fstatat(
            directory,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            return metadata.st_mode & S_IFMT == S_IFSOCK
                ? .socket
                : .other
        }
        guard errno == ENOENT else {
            throw rejected(
                "Unix socket host path metadata could not be inspected."
            )
        }
        return .absent
    }

    private static func requiredSocketMetadata(
        named name: String,
        directory: Int32
    ) throws -> stat {
        var metadata = stat()
        guard fstatat(
            directory,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_uid == getuid() else {
            throw rejected(
                "Runtime did not publish the exact owned Unix socket."
            )
        }
        return metadata
    }

    private static func fileName(
        for publication: RuntimeUnixSocketPublication,
        root: String
    ) throws -> String {
        let normalizedRoot = try HostwrightLocalPathResolver
            .normalizedAbsolutePath(
                root,
                role: "published socket root"
            )
        let normalizedPath = try HostwrightLocalPathResolver
            .normalizedAbsolutePath(
                publication.hostPath,
                role: "published socket host path"
            )
        let url = URL(fileURLWithPath: normalizedPath)
        guard url.deletingLastPathComponent().path == normalizedRoot,
              normalizedPath.hasPrefix(normalizedRoot + "/"),
              !normalizedPath.contains(":"),
              normalizedPath.utf8.count <= 103,
              publication.containerPath.hasPrefix("/"),
              !publication.containerPath.contains(":"),
              publication.containerPath.utf8.count <= 107 else {
            throw rejected(
                "Unix socket paths must remain inside Hostwright's private socket root and platform limits."
            )
        }
        return url.lastPathComponent
    }

    private static func createMarker(
        _ marker: RuntimeUnixSocketOwnershipMarker,
        named name: String,
        directory: Int32
    ) throws {
        let data = try markerData(marker)
        let descriptor = openat(
            directory,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw rejected(
                "Unix socket ownership metadata could not be created atomically."
            )
        }
        var shouldRemove = true
        defer {
            Darwin.close(descriptor)
            if shouldRemove {
                _ = unlinkat(directory, name, 0)
            }
        }
        try writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0,
              fsync(directory) == 0 else {
            throw rejected(
                "Unix socket ownership metadata could not be persisted."
            )
        }
        shouldRemove = false
    }

    private static func replaceMarker(
        _ marker: RuntimeUnixSocketOwnershipMarker,
        named name: String,
        directory: Int32
    ) throws {
        let data = try markerData(marker)
        let temporaryName =
            ".\(name).\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(
            directory,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw rejected(
                "Unix socket ownership metadata replacement could not be created."
            )
        }
        var shouldRemove = true
        defer {
            Darwin.close(descriptor)
            if shouldRemove {
                _ = unlinkat(directory, temporaryName, 0)
            }
        }
        try writeAll(data, descriptor: descriptor)
        guard fchmod(descriptor, 0o600) == 0,
              fsync(descriptor) == 0,
              renameat(
                  directory,
                  temporaryName,
                  directory,
                  name
              ) == 0,
              fsync(directory) == 0 else {
            throw rejected(
                "Unix socket ownership metadata could not be replaced atomically."
            )
        }
        shouldRemove = false
    }

    private static func bindMarker(
        existing marker: RuntimeUnixSocketOwnershipMarker,
        expected: RuntimeUnixSocketOwnershipMarker,
        to metadata: stat,
        named markerName: String,
        socketName: String,
        directory: Int32
    ) throws {
        guard marker.matchesStableIdentity(expected) else {
            throw rejected(
                "Unix socket ownership metadata changed before durable binding."
            )
        }
        if marker.hasCompleteSocketIdentity,
           !marker.matchesSocket(metadata) {
            throw rejected(
                "Unix socket ownership metadata identifies a different device or inode."
            )
        }
        let bound = expected.bindingSocket(metadata)
        if bound != marker {
            try replaceMarker(
                bound,
                named: markerName,
                directory: directory
            )
        }
        let current = try requiredSocketMetadata(
            named: socketName,
            directory: directory
        )
        guard bound.matchesSocket(current) else {
            throw rejected(
                "Unix socket identity changed while durable ownership was recorded."
            )
        }
    }

    private static func readMarkerIfPresent(
        named name: String,
        directory: Int32
    ) throws -> RuntimeUnixSocketOwnershipMarker? {
        let descriptor = openat(
            directory,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw rejected(
                "Unix socket ownership metadata is unsafe or unreadable."
            )
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_size > 0,
              metadata.st_size <= maximumMarkerBytes else {
            throw rejected(
                "Unix socket ownership metadata has unsafe type, ownership, mode, or size."
            )
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(
                descriptor,
                &buffer,
                buffer.count
            )
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw rejected(
                    "Unix socket ownership metadata could not be read."
                )
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= maximumMarkerBytes else {
                throw rejected(
                    "Unix socket ownership metadata exceeds its bounded size."
                )
            }
        }
        let object = try JSONSerialization.jsonObject(with: data)
        let requiredKeys: Set<String> = [
            "schemaVersion", "hostPath", "containerPath",
            "mode", "resourceIdentifier", "resourceUUID",
            "resourceGeneration", "projectUUID",
            "projectGeneration", "providerID",
            "providerGeneration", "fencingToken"
        ]
        let allowedKeys = requiredKeys.union([
            "socketDevice", "socketInode"
        ])
        guard let dictionary = object as? [String: Any],
              requiredKeys.isSubset(of: Set(dictionary.keys)),
              Set(dictionary.keys).isSubset(of: allowedKeys) else {
            throw rejected(
                "Unix socket ownership metadata has an unsupported shape."
            )
        }
        let marker = try JSONDecoder().decode(
            RuntimeUnixSocketOwnershipMarker.self,
            from: data
        )
        guard (marker.socketDevice == nil) ==
                (marker.socketInode == nil),
              try markerData(marker) == data else {
            throw rejected(
                "Unix socket ownership metadata is not canonical."
            )
        }
        return marker
    }

    private static func markerData(
        _ marker: RuntimeUnixSocketOwnershipMarker
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(marker)
        guard data.count <= maximumMarkerBytes else {
            throw rejected(
                "Unix socket ownership metadata exceeds its bounded size."
            )
        }
        return data
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    throw rejected(
                        "Unix socket ownership metadata could not be written."
                    )
                }
                offset += count
            }
        }
    }

    private static func unlink(
        named name: String,
        directory: Int32
    ) throws {
        guard unlinkat(directory, name, 0) == 0,
              fsync(directory) == 0 else {
            throw rejected(
                "Unix socket owned cleanup could not remove the exact path."
            )
        }
    }

    private static func unlinkIfPresent(
        named name: String,
        directory: Int32
    ) throws {
        if unlinkat(directory, name, 0) == 0 {
            guard fsync(directory) == 0 else {
                throw rejected(
                    "Unix socket owned cleanup could not persist ownership metadata removal."
                )
            }
        } else if errno != ENOENT {
            throw rejected(
                "Unix socket owned cleanup could not remove ownership metadata."
            )
        }
    }

    private static func socketOrder(
        _ lhs: RuntimeUnixSocketPublication,
        _ rhs: RuntimeUnixSocketPublication
    ) -> Bool {
        (lhs.hostPath, lhs.containerPath, lhs.mode.rawValue) <
            (rhs.hostPath, rhs.containerPath, rhs.mode.rawValue)
    }

    private static func leaseOrder(
        _ lhs: RuntimeUnixSocketPublicationLease,
        _ rhs: RuntimeUnixSocketPublicationLease
    ) -> Bool {
        socketOrder(lhs.publication, rhs.publication)
    }

    private static func rejected(_ message: String)
        -> RuntimeAdapterError {
        .commandRejected(
            classification: .mutating,
            message: message
        )
    }
}
