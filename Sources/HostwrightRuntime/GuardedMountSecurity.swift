import Darwin
import Foundation
import HostwrightCore

public enum GuardedMountSecurityError: Error, Equatable, Sendable {
    case pathMustBeAbsolute
    case hostRootForbidden
    case parentTraversalForbidden
    case pathNotFound
    case symlinkForbidden
    case unsupportedFileType
    case unsafeOwnership
    case openFailed(Int32)
    case identityChanged
}

public struct GuardedMountIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let fileType: mode_t
}

public struct GuardedMountPathComponent: Equatable, Sendable {
    public let path: String
    public let identity: GuardedMountIdentity
}

public final class GuardedMountLease {
    public let path: String
    public let descriptor: Int32
    public let identity: GuardedMountIdentity
    public let pathComponents: [GuardedMountPathComponent]

    init(
        path: String,
        descriptor: Int32,
        identity: GuardedMountIdentity,
        pathComponents: [GuardedMountPathComponent]
    ) {
        self.path = path
        self.descriptor = descriptor
        self.identity = identity
        self.pathComponents = pathComponents
    }

    deinit {
        Darwin.close(descriptor)
    }
}

public enum GuardedMountSecurity {
    public static func openBindSource(_ path: String) throws -> GuardedMountLease {
        guard path.hasPrefix("/") else {
            throw GuardedMountSecurityError.pathMustBeAbsolute
        }
        if HostwrightPathPolicy.isHostRootMountSource(path) {
            throw GuardedMountSecurityError.hostRootForbidden
        }
        if HostwrightPathPolicy.containsParentDirectoryTraversal(path) {
            throw GuardedMountSecurityError.parentTraversalForbidden
        }

        let components = path.split(separator: "/").map(String.init)
        let rootDescriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            throw GuardedMountSecurityError.openFailed(errno)
        }

        var currentDescriptor = rootDescriptor
        var currentPath = ""
        var pathComponents: [GuardedMountPathComponent] = []
        for component in components.dropLast() {
            currentPath += "/\(component)"
            let next = openat(currentDescriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                let error = errno
                if currentDescriptor != rootDescriptor { Darwin.close(currentDescriptor) }
                Darwin.close(rootDescriptor)
                switch error {
                case ENOENT:
                    throw GuardedMountSecurityError.pathNotFound
                case ELOOP:
                    throw GuardedMountSecurityError.symlinkForbidden
                case ENOTDIR:
                    var metadata = stat()
                    if lstat(currentPath, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFLNK {
                        throw GuardedMountSecurityError.symlinkForbidden
                    }
                    throw GuardedMountSecurityError.openFailed(error)
                default:
                    throw GuardedMountSecurityError.openFailed(error)
                }
            }
            var metadata = stat()
            guard fstat(next, &metadata) == 0 else {
                let error = errno
                Darwin.close(next)
                if currentDescriptor != rootDescriptor { Darwin.close(currentDescriptor) }
                Darwin.close(rootDescriptor)
                throw GuardedMountSecurityError.openFailed(error)
            }
            guard isDirectory(metadata.st_mode) else {
                Darwin.close(next)
                if currentDescriptor != rootDescriptor { Darwin.close(currentDescriptor) }
                Darwin.close(rootDescriptor)
                throw GuardedMountSecurityError.unsupportedFileType
            }
            guard ownershipIsSafe(metadata) else {
                Darwin.close(next)
                if currentDescriptor != rootDescriptor { Darwin.close(currentDescriptor) }
                Darwin.close(rootDescriptor)
                throw GuardedMountSecurityError.unsafeOwnership
            }
            pathComponents.append(
                GuardedMountPathComponent(
                    path: currentPath,
                    identity: identity(from: metadata)
                )
            )
            if currentDescriptor != rootDescriptor { Darwin.close(currentDescriptor) }
            currentDescriptor = next
        }

        guard let finalComponent = components.last else {
            Darwin.close(rootDescriptor)
            throw GuardedMountSecurityError.pathNotFound
        }

        let descriptor = openat(currentDescriptor, finalComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        let openError = errno
        let closeCurrent = currentDescriptor
        if closeCurrent != rootDescriptor { Darwin.close(closeCurrent) }
        Darwin.close(rootDescriptor)
        guard descriptor >= 0 else {
            switch openError {
            case ENOENT:
                throw GuardedMountSecurityError.pathNotFound
            case ELOOP:
                throw GuardedMountSecurityError.symlinkForbidden
            default:
                throw GuardedMountSecurityError.openFailed(openError)
            }
        }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw GuardedMountSecurityError.openFailed(error)
        }
        guard isRegularOrDirectory(opened.st_mode) else {
            Darwin.close(descriptor)
            throw GuardedMountSecurityError.unsupportedFileType
        }
        guard ownershipIsSafe(opened) else {
            Darwin.close(descriptor)
            throw GuardedMountSecurityError.unsafeOwnership
        }

        var beforeMetadata = stat()
        guard lstat(path, &beforeMetadata) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw error == ENOENT ? GuardedMountSecurityError.pathNotFound : .openFailed(error)
        }
        guard (beforeMetadata.st_mode & S_IFMT) != S_IFLNK else {
            Darwin.close(descriptor)
            throw GuardedMountSecurityError.symlinkForbidden
        }

        let before = identity(from: beforeMetadata)
        let after = identity(from: opened)
        guard before == after else {
            Darwin.close(descriptor)
            throw GuardedMountSecurityError.identityChanged
        }
        pathComponents.append(
            GuardedMountPathComponent(
                path: path,
                identity: after
            )
        )

        return GuardedMountLease(
            path: path,
            descriptor: descriptor,
            identity: after,
            pathComponents: pathComponents
        )
    }

    public static func revalidate(_ lease: GuardedMountLease) throws {
        for component in lease.pathComponents {
            var pathMetadata = stat()
            guard lstat(component.path, &pathMetadata) == 0 else {
                let error = errno
                throw error == ENOENT ? GuardedMountSecurityError.identityChanged : .openFailed(error)
            }
            guard (pathMetadata.st_mode & S_IFMT) != S_IFLNK else {
                throw GuardedMountSecurityError.identityChanged
            }
            let currentPathIdentity = identity(from: pathMetadata)
            guard currentPathIdentity == component.identity else {
                throw GuardedMountSecurityError.identityChanged
            }
            guard ownershipIsSafe(pathMetadata) else {
                throw GuardedMountSecurityError.unsafeOwnership
            }
            guard isRegularOrDirectory(pathMetadata.st_mode) else {
                throw GuardedMountSecurityError.unsupportedFileType
            }
        }

        var metadata = stat()
        guard fstat(lease.descriptor, &metadata) == 0 else {
            throw GuardedMountSecurityError.openFailed(errno)
        }
        let current = identity(from: metadata)
        guard current == lease.identity else {
            throw GuardedMountSecurityError.identityChanged
        }
        guard ownershipIsSafe(metadata) else {
            throw GuardedMountSecurityError.unsafeOwnership
        }
        guard isRegularOrDirectory(metadata.st_mode) else {
            throw GuardedMountSecurityError.unsupportedFileType
        }
    }

    private static func identity(from metadata: stat) -> GuardedMountIdentity {
        GuardedMountIdentity(
            device: UInt64(bitPattern: Int64(metadata.st_dev)),
            inode: UInt64(bitPattern: Int64(metadata.st_ino)),
            fileType: metadata.st_mode & S_IFMT
        )
    }

    private static func isRegularOrDirectory(_ mode: mode_t) -> Bool {
        isDirectory(mode) || (mode & S_IFMT) == S_IFREG
    }

    private static func isDirectory(_ mode: mode_t) -> Bool {
        (mode & S_IFMT) == S_IFDIR
    }

    private static func ownershipIsSafe(_ metadata: stat) -> Bool {
        let owner = metadata.st_uid
        let euid = geteuid()
        guard owner == 0 || owner == euid else {
            return false
        }
        let groupWritable = (metadata.st_mode & S_IWGRP) != 0
        let otherWritable = (metadata.st_mode & S_IWOTH) != 0
        return !(groupWritable || otherWritable)
    }
}
