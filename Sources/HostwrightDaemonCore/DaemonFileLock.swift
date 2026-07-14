import Darwin
import Foundation
import HostwrightCore

public final class FileDaemonInstanceLock: DaemonInstanceLock {
    private let path: String
    private var descriptor: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    public func acquire() throws -> Bool {
        if descriptor >= 0 {
            return true
        }

        do {
            _ = try HostwrightLocalPathResolver.normalizedAbsolutePath(
                path,
                role: "daemon lock"
            )
        } catch {
            throw DaemonError.lockFailed(path: path, message: String(describing: error))
        }
        let directory = (path as NSString).deletingLastPathComponent
        try validateDirectoryChain(directory)

        var created = false
        var opened = Darwin.open(
            path,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        if opened < 0, errno == EEXIST {
            opened = Darwin.open(
                path,
                O_RDWR | O_NOFOLLOW | O_CLOEXEC
            )
        } else if opened >= 0 {
            created = true
        }
        guard opened >= 0 else {
            throw DaemonError.lockFailed(path: path, message: String(cString: strerror(errno)))
        }
        var accepted = false
        defer {
            if !accepted {
                Darwin.close(opened)
                if created { unlink(path) }
            }
        }

        if created {
            guard fchmod(opened, S_IRUSR | S_IWUSR) == 0,
                  fsync(opened) == 0 else {
                throw DaemonError.lockFailed(
                    path: path,
                    message: String(cString: strerror(errno))
                )
            }
        }

        var metadata = stat()
        guard fstat(opened, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == S_IRUSR | S_IWUSR else {
            throw DaemonError.lockFailed(
                path: path,
                message: "lock files require invoking-user ownership, one regular link, no symlink, and mode 0600"
            )
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                fileDescriptor: opened,
                path: path,
                role: "daemon lock file"
            )
        } catch {
            throw DaemonError.lockFailed(path: path, message: String(describing: error))
        }

        if created {
            try synchronizeDirectory(directory)
        }

        if flock(opened, LOCK_EX | LOCK_NB) != 0 {
            let lockErrno = errno
            if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
                accepted = true
                Darwin.close(opened)
                return false
            }
            throw DaemonError.lockFailed(path: path, message: String(cString: strerror(lockErrno)))
        }

        accepted = true
        descriptor = opened
        return true
    }

    public func release() {
        guard descriptor >= 0 else {
            return
        }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }

    private func validateDirectoryChain(
        _ directory: String,
        allowRootOwnedAliases: Bool = true
    ) throws {
        guard directory.hasPrefix("/"), !directory.isEmpty else {
            throw DaemonError.lockFailed(path: path, message: "the lock path must have an absolute parent directory")
        }
        try validateRootDirectory()
        var current = ""
        for component in directory.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/\(component)"
            var metadata = stat()
            guard lstat(current, &metadata) == 0 else {
                throw DaemonError.lockFailed(path: path, message: "unsafe lock parent \(current): \(String(cString: strerror(errno)))")
            }
            if metadata.st_mode & S_IFMT == S_IFLNK {
                guard allowRootOwnedAliases, metadata.st_uid == 0 else {
                    throw DaemonError.lockFailed(path: path, message: "user-controlled symlink lock parents are rejected")
                }
                var target = stat()
                let result = current.withCString { pointer in
                    fstatat(AT_FDCWD, pointer, &target, 0)
                }
                guard result == 0,
                      target.st_mode & S_IFMT == S_IFDIR,
                      target.st_uid == 0 || target.st_uid == geteuid(),
                      target.st_mode & (S_ISUID | S_ISGID | S_ISVTX) == 0,
                      target.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
                    throw DaemonError.lockFailed(path: path, message: "root-owned lock alias resolves through an unsafe directory")
                }
                let canonical: String
                do {
                    canonical = try HostwrightLocalFilesystemPolicy.canonicalExistingPath(
                        current,
                        role: "daemon lock root-owned alias"
                    )
                } catch {
                    throw DaemonError.lockFailed(path: path, message: String(describing: error))
                }
                try validateDirectoryChain(canonical, allowRootOwnedAliases: false)
                continue
            }
            let permissions = metadata.st_mode & 0o7777
            guard metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == 0 || metadata.st_uid == geteuid(),
                  permissions & (S_ISUID | S_ISGID | S_ISVTX) == 0,
                  permissions & (S_IWGRP | S_IWOTH) == 0 else {
                throw DaemonError.lockFailed(path: path, message: "lock parent directories must be root/user owned and not group- or other-writable")
            }
            do {
                try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                    atPath: current,
                    role: "daemon lock parent"
                )
            } catch {
                throw DaemonError.lockFailed(path: path, message: String(describing: error))
            }
        }
    }

    private func synchronizeDirectory(_ directory: String) throws {
        let descriptor = Darwin.open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw DaemonError.lockFailed(path: path, message: String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DaemonError.lockFailed(path: path, message: String(cString: strerror(errno)))
        }
    }

    private func validateRootDirectory() throws {
        var metadata = stat()
        guard lstat("/", &metadata) == 0 else {
            throw DaemonError.lockFailed(path: path, message: String(cString: strerror(errno)))
        }
        let permissions = metadata.st_mode & 0o7777
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == 0,
              permissions & (S_ISUID | S_ISGID | S_ISVTX) == 0,
              permissions & (S_IWGRP | S_IWOTH) == 0 else {
            throw DaemonError.lockFailed(path: path, message: "the filesystem root has unsafe ownership or mode")
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                atPath: "/",
                role: "filesystem root"
            )
        } catch {
            throw DaemonError.lockFailed(path: path, message: String(describing: error))
        }
    }
}
