import Darwin
import Foundation
import HostwrightCore

enum StateAccessMode {
    case shared
    case write
    case exclusive
}

struct StateAccessCoordinator {
    let configuration: StateStoreConfiguration

    private static let lifecycleFenceThreadKey =
        "dev.hostwright.state-access.exclusive-lifecycle-fence"

    func withLock<T>(
        _ mode: StateAccessMode,
        allowPendingMaintenance: Bool = false,
        _ body: () throws -> T
    ) throws -> T {
        let paths = try configuration.maintenancePaths()
        if Thread.current.threadDictionary[Self.lifecycleFenceThreadKey] as? String
            == paths.accessLockPath {
            if !allowPendingMaintenance, pathExists(paths.journalPath) {
                throw StateStoreError.maintenanceRecoveryRequired(journalPath: paths.journalPath)
            }
            return try body()
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        let accessDescriptor = try openSecureLock(paths.accessLockPath)
        var writerDescriptor: Int32?
        defer {
            if let writerDescriptor {
                _ = flock(writerDescriptor, LOCK_UN)
                close(writerDescriptor)
            }
            _ = flock(accessDescriptor, LOCK_UN)
            close(accessDescriptor)
        }

        try acquire(
            accessDescriptor,
            operation: mode == .exclusive ? LOCK_EX : LOCK_SH,
            deadline: deadline,
            role: "state-access fence"
        )
        if mode == .write {
            let descriptor = try openSecureLock(paths.accessLockPath + ".writer")
            writerDescriptor = descriptor
            try acquire(
                descriptor,
                operation: LOCK_EX,
                deadline: deadline,
                role: "state-writer fence"
            )
        }

        if !allowPendingMaintenance, pathExists(paths.journalPath) {
            throw StateStoreError.maintenanceRecoveryRequired(journalPath: paths.journalPath)
        }
        return try body()
    }

    func withExclusiveLifecycleFence<T>(_ body: () throws -> T) throws -> T {
        let paths = try configuration.maintenancePaths()
        return try withLock(.exclusive) {
            let dictionary = Thread.current.threadDictionary
            let previous = dictionary[Self.lifecycleFenceThreadKey]
            dictionary[Self.lifecycleFenceThreadKey] = paths.accessLockPath
            defer {
                if let previous {
                    dictionary[Self.lifecycleFenceThreadKey] = previous
                } else {
                    dictionary.removeObject(forKey: Self.lifecycleFenceThreadKey)
                }
            }
            return try body()
        }
    }

    func withExistingSharedLockIfPresent<T>(
        allowPendingMaintenance: Bool = false,
        _ body: () throws -> T
    ) throws -> T {
        let paths = try configuration.maintenancePaths()
        let descriptor = try openExistingSecureLock(paths.accessLockPath)
        defer {
            if let descriptor {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }

        if let descriptor {
            try acquire(
                descriptor,
                operation: LOCK_SH,
                deadline: DispatchTime.now().uptimeNanoseconds + 250_000_000,
                role: "state-access fence"
            )
        }
        if !allowPendingMaintenance, pathExists(paths.journalPath) {
            throw StateStoreError.maintenanceRecoveryRequired(journalPath: paths.journalPath)
        }
        return try body()
    }

    private func acquire(
        _ descriptor: Int32,
        operation: Int32,
        deadline: UInt64,
        role: String
    ) throws {
        while flock(descriptor, operation | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw StateStoreError.databaseLocked(
                    path: configuration.databasePath,
                    message: String(cString: strerror(errno))
                )
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw StateStoreError.databaseLocked(
                    path: configuration.databasePath,
                    message: "timed out waiting for the Hostwright \(role)"
                )
            }
            usleep(10_000)
        }
    }

    private func openSecureLock(_ path: String) throws -> Int32 {
        let (descriptor, created) = try openLockWithoutMutatingExistingFile(path)
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw StateStoreError.pathPolicyViolation(
                    path: path,
                    message: String(cString: strerror(errno))
                )
            }
            guard metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == geteuid(),
                  metadata.st_nlink == 1 else {
                throw StateStoreError.pathPolicyViolation(
                    path: path,
                    message: "the state-access fence must be a singly linked invoking-user regular file"
                )
            }
            if created {
                guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                    throw StateStoreError.pathPolicyViolation(
                        path: path,
                        message: String(cString: strerror(errno))
                    )
                }
                guard fstat(descriptor, &metadata) == 0 else {
                    throw StateStoreError.pathPolicyViolation(
                        path: path,
                        message: String(cString: strerror(errno))
                    )
                }
            }
            guard metadata.st_mode & 0o7777 == S_IRUSR | S_IWUSR else {
                throw StateStoreError.pathPolicyViolation(
                    path: path,
                    message: "the state-access fence must have mode 0600"
                )
            }
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                fileDescriptor: descriptor,
                path: path,
                role: "state-access fence"
            )
            try validatePathStillNamesDescriptor(path, descriptorMetadata: metadata)
            if created {
                guard fsync(descriptor) == 0 else {
                    throw StateStoreError.pathPolicyViolation(
                        path: path,
                        message: String(cString: strerror(errno))
                    )
                }
                try StateMaintenanceFileSupport.synchronizeDirectory(
                    (path as NSString).deletingLastPathComponent
                )
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func openExistingSecureLock(_ path: String) throws -> Int32? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw StateStoreError.pathPolicyViolation(
                path: path,
                message: String(cString: strerror(errno))
            )
        }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw StateStoreError.pathPolicyViolation(
                    path: path,
                    message: String(cString: strerror(errno))
                )
            }
            guard metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == geteuid(),
                  metadata.st_nlink == 1,
                  metadata.st_mode & 0o7777 == S_IRUSR | S_IWUSR else {
                throw StateStoreError.pathPolicyViolation(
                    path: path,
                    message: "the existing state-access fence must be a singly linked invoking-user regular file with mode 0600"
                )
            }
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                fileDescriptor: descriptor,
                path: path,
                role: "state-access fence"
            )
            try validatePathStillNamesDescriptor(path, descriptorMetadata: metadata)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func openLockWithoutMutatingExistingFile(_ path: String) throws -> (Int32, Bool) {
        while true {
            let created = open(
                path,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            if created >= 0 {
                return (created, true)
            }
            guard errno == EEXIST else {
                throw StateStoreError.pathPolicyViolation(
                    path: path,
                    message: String(cString: strerror(errno))
                )
            }

            let existing = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            if existing >= 0 {
                return (existing, false)
            }
            if errno == ENOENT {
                continue
            }
            throw StateStoreError.pathPolicyViolation(
                path: path,
                message: String(cString: strerror(errno))
            )
        }
    }

    private func validatePathStillNamesDescriptor(
        _ path: String,
        descriptorMetadata: stat
    ) throws {
        var pathMetadata = stat()
        guard lstat(path, &pathMetadata) == 0,
              pathMetadata.st_mode & S_IFMT == S_IFREG,
              pathMetadata.st_dev == descriptorMetadata.st_dev,
              pathMetadata.st_ino == descriptorMetadata.st_ino else {
            throw StateStoreError.pathPolicyViolation(
                path: path,
                message: "the state-access fence path changed while it was being validated"
            )
        }
    }

    private func pathExists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }
}
