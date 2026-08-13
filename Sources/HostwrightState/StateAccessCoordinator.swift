import Darwin
import Foundation
import HostwrightCore

enum StateAccessMode {
    case shared
    case write
    case exclusive
}

private final class StateLifecycleFenceLease: @unchecked Sendable {
    let accessLockPath: String
    let allowsPendingMaintenanceRecovery: Bool
    private let lock = NSLock()
    private var active = true

    init(accessLockPath: String, allowsPendingMaintenanceRecovery: Bool) {
        self.accessLockPath = accessLockPath
        self.allowsPendingMaintenanceRecovery = allowsPendingMaintenanceRecovery
    }

    func recoveryPermission(for path: String) -> Bool? {
        lock.withLock {
            guard active, accessLockPath == path else { return nil }
            return allowsPendingMaintenanceRecovery
        }
    }

    func invalidate() {
        lock.withLock { active = false }
    }
}

private final class StateLifecycleMutationLease: @unchecked Sendable {
    let lockPath: String
    private let lock = NSLock()
    private var active = true

    init(lockPath: String) {
        self.lockPath = lockPath
    }

    func applies(to path: String) -> Bool {
        lock.withLock { active && lockPath == path }
    }

    func invalidate() {
        lock.withLock { active = false }
    }
}

private enum StateAccessExecutionContext {
    @TaskLocal static var lifecycleFence: StateLifecycleFenceLease?
    @TaskLocal static var lifecycleMutationFence: StateLifecycleMutationLease?
    @TaskLocal static var waitTimeoutNanoseconds: UInt64?
}

public final class OperationMutationFence: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var released = false

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public func release() {
        lock.withLock {
            guard !released else { return }
            released = true
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    deinit {
        release()
    }
}

struct StateAccessCoordinator {
    let configuration: StateStoreConfiguration

    private static let lifecycleFenceThreadKey =
        "dev.hostwright.state-access.exclusive-lifecycle-fence"
    private static let lifecycleMutationFenceThreadKey =
        "dev.hostwright.state-access.serialized-lifecycle-mutation"
    private static let pendingMaintenanceRecoveryThreadKey =
        "dev.hostwright.state-access.pending-maintenance-recovery"

    func withLock<T>(
        _ mode: StateAccessMode,
        allowPendingMaintenance: Bool = false,
        waitTimeoutNanoseconds: UInt64? = nil,
        _ body: () throws -> T
    ) throws -> T {
        let paths = try configuration.maintenancePaths()
        if let inheritedRecovery = StateAccessExecutionContext.lifecycleFence?
            .recoveryPermission(for: paths.accessLockPath) {
            if inheritedRecovery || allowPendingMaintenance {
                return try body()
            }
            if let journal = pendingMaintenanceJournal(paths) {
                throw StateStoreError.maintenanceRecoveryRequired(journalPath: journal)
            }
            return try body()
        }
        if Thread.current.threadDictionary[Self.lifecycleFenceThreadKey] as? String
            == paths.accessLockPath {
            if Thread.current.threadDictionary[Self.pendingMaintenanceRecoveryThreadKey] as? Bool == true {
                return try body()
            }
            if !allowPendingMaintenance, let journal = pendingMaintenanceJournal(paths) {
                throw StateStoreError.maintenanceRecoveryRequired(journalPath: journal)
            }
            return try body()
        }
        let wait = max(
            waitTimeoutNanoseconds ?? 250_000_000,
            StateAccessExecutionContext.waitTimeoutNanoseconds ?? 0
        )
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(wait)
        guard wait > 0, !overflow else {
            throw StateStoreError.invalidRecord("state-access wait timeout is invalid")
        }
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
        if mode == .shared || mode == .write {
            let descriptor = try openSecureLock(paths.accessLockPath + ".writer")
            writerDescriptor = descriptor
            try acquire(
                descriptor,
                operation: mode == .write ? LOCK_EX : LOCK_SH,
                deadline: deadline,
                role: "state-writer fence"
            )
        }

        if !allowPendingMaintenance, let journal = pendingMaintenanceJournal(paths) {
            throw StateStoreError.maintenanceRecoveryRequired(journalPath: journal)
        }
        return try body()
    }

    func withExclusiveLifecycleFence<T>(
        allowPendingMaintenance: Bool = false,
        waitTimeoutNanoseconds: UInt64 = 250_000_000,
        _ body: () throws -> T
    ) throws -> T {
        let paths = try configuration.maintenancePaths()
        return try withSerializedLifecycleMutation(
            waitTimeoutNanoseconds: waitTimeoutNanoseconds
        ) {
            try withLock(
                .exclusive,
                allowPendingMaintenance: allowPendingMaintenance,
                waitTimeoutNanoseconds: waitTimeoutNanoseconds
            ) {
                let dictionary = Thread.current.threadDictionary
                let previous = dictionary[Self.lifecycleFenceThreadKey]
                let previousRecovery = dictionary[Self.pendingMaintenanceRecoveryThreadKey]
                dictionary[Self.lifecycleFenceThreadKey] = paths.accessLockPath
                if allowPendingMaintenance {
                    dictionary[Self.pendingMaintenanceRecoveryThreadKey] = true
                }
                defer {
                    if let previous {
                        dictionary[Self.lifecycleFenceThreadKey] = previous
                    } else {
                        dictionary.removeObject(forKey: Self.lifecycleFenceThreadKey)
                    }
                    if let previousRecovery {
                        dictionary[Self.pendingMaintenanceRecoveryThreadKey] = previousRecovery
                    } else {
                        dictionary.removeObject(forKey: Self.pendingMaintenanceRecoveryThreadKey)
                    }
                }
                let lease = StateLifecycleFenceLease(
                    accessLockPath: paths.accessLockPath,
                    allowsPendingMaintenanceRecovery: allowPendingMaintenance
                )
                defer { lease.invalidate() }
                return try StateAccessExecutionContext.$lifecycleFence.withValue(
                    lease,
                    operation: body
                )
            }
        }
    }

    func withExclusiveLifecycleFence<T>(
        allowPendingMaintenance: Bool = false,
        waitTimeoutNanoseconds: UInt64 = 250_000_000,
        _ body: () async throws -> T
    ) async throws -> T {
        let paths = try configuration.maintenancePaths()
        return try await withSerializedLifecycleMutation(
            waitTimeoutNanoseconds: waitTimeoutNanoseconds
        ) {
            if let inheritedRecovery = StateAccessExecutionContext.lifecycleFence?
                .recoveryPermission(for: paths.accessLockPath) {
                if !inheritedRecovery,
                   !allowPendingMaintenance,
                   let journal = pendingMaintenanceJournal(paths) {
                    throw StateStoreError.maintenanceRecoveryRequired(journalPath: journal)
                }
                return try await body()
            }
            let effectiveWaitTimeoutNanoseconds = max(
                waitTimeoutNanoseconds,
                StateAccessExecutionContext.waitTimeoutNanoseconds ?? 0
            )
            let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds
                .addingReportingOverflow(effectiveWaitTimeoutNanoseconds)
            guard effectiveWaitTimeoutNanoseconds > 0, !overflow else {
                throw StateStoreError.invalidRecord("state-access wait timeout is invalid")
            }
            let descriptor = try openSecureLock(paths.accessLockPath)
            defer {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
            }
            try acquire(
                descriptor,
                operation: LOCK_EX,
                deadline: deadline,
                role: "state-access fence"
            )
            if !allowPendingMaintenance, let journal = pendingMaintenanceJournal(paths) {
                throw StateStoreError.maintenanceRecoveryRequired(journalPath: journal)
            }
            let lease = StateLifecycleFenceLease(
                accessLockPath: paths.accessLockPath,
                allowsPendingMaintenanceRecovery: allowPendingMaintenance
            )
            defer { lease.invalidate() }
            return try await StateAccessExecutionContext.$lifecycleFence.withValue(
                lease,
                operation: body
            )
        }
    }

    func withSerializedLifecycleMutation<T>(
        waitTimeoutNanoseconds: UInt64 = 250_000_000,
        _ body: () throws -> T
    ) throws -> T {
        let paths = try configuration.maintenancePaths()
        let lockPath = paths.accessLockPath + ".lifecycle-mutation"
        if StateAccessExecutionContext.lifecycleMutationFence?.applies(to: lockPath) == true
            || Thread.current.threadDictionary[Self.lifecycleMutationFenceThreadKey] as? String
                == lockPath {
            return try body()
        }
        let effectiveWaitTimeoutNanoseconds = max(
            waitTimeoutNanoseconds,
            StateAccessExecutionContext.waitTimeoutNanoseconds ?? 0
        )
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(effectiveWaitTimeoutNanoseconds)
        guard effectiveWaitTimeoutNanoseconds > 0, !overflow else {
            throw StateStoreError.invalidRecord("lifecycle-mutation wait timeout is invalid")
        }
        let descriptor = try openSecureLock(lockPath)
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        try acquire(
            descriptor,
            operation: LOCK_EX,
            deadline: deadline,
            role: "lifecycle-mutation fence"
        )
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[Self.lifecycleMutationFenceThreadKey]
        dictionary[Self.lifecycleMutationFenceThreadKey] = lockPath
        defer {
            if let previous {
                dictionary[Self.lifecycleMutationFenceThreadKey] = previous
            } else {
                dictionary.removeObject(forKey: Self.lifecycleMutationFenceThreadKey)
            }
        }
        let lease = StateLifecycleMutationLease(lockPath: lockPath)
        defer { lease.invalidate() }
        return try StateAccessExecutionContext.$lifecycleMutationFence.withValue(
            lease,
            operation: body
        )
    }

    func withSerializedLifecycleMutation<T>(
        waitTimeoutNanoseconds: UInt64 = 250_000_000,
        _ body: () async throws -> T
    ) async throws -> T {
        let paths = try configuration.maintenancePaths()
        let lockPath = paths.accessLockPath + ".lifecycle-mutation"
        if StateAccessExecutionContext.lifecycleMutationFence?.applies(to: lockPath) == true {
            return try await body()
        }
        let effectiveWaitTimeoutNanoseconds = max(
            waitTimeoutNanoseconds,
            StateAccessExecutionContext.waitTimeoutNanoseconds ?? 0
        )
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(effectiveWaitTimeoutNanoseconds)
        guard effectiveWaitTimeoutNanoseconds > 0, !overflow else {
            throw StateStoreError.invalidRecord("lifecycle-mutation wait timeout is invalid")
        }
        let descriptor = try openSecureLock(lockPath)
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        try acquire(
            descriptor,
            operation: LOCK_EX,
            deadline: deadline,
            role: "lifecycle-mutation fence"
        )
        let lease = StateLifecycleMutationLease(lockPath: lockPath)
        defer { lease.invalidate() }
        return try await StateAccessExecutionContext.$lifecycleMutationFence.withValue(
            lease,
            operation: body
        )
    }

    func withBoundedStateAccessWait<T>(
        waitTimeoutNanoseconds: UInt64,
        _ body: () throws -> T
    ) throws -> T {
        guard waitTimeoutNanoseconds > 0 else {
            throw StateStoreError.invalidRecord("state-access wait timeout is invalid")
        }
        let effectiveWaitTimeoutNanoseconds = max(
            waitTimeoutNanoseconds,
            StateAccessExecutionContext.waitTimeoutNanoseconds ?? 0
        )
        return try StateAccessExecutionContext.$waitTimeoutNanoseconds.withValue(
            effectiveWaitTimeoutNanoseconds,
            operation: body
        )
    }

    func withBoundedStateAccessWait<T>(
        waitTimeoutNanoseconds: UInt64,
        _ body: () async throws -> T
    ) async throws -> T {
        guard waitTimeoutNanoseconds > 0 else {
            throw StateStoreError.invalidRecord("state-access wait timeout is invalid")
        }
        let effectiveWaitTimeoutNanoseconds = max(
            waitTimeoutNanoseconds,
            StateAccessExecutionContext.waitTimeoutNanoseconds ?? 0
        )
        return try await StateAccessExecutionContext.$waitTimeoutNanoseconds.withValue(
            effectiveWaitTimeoutNanoseconds,
            operation: body
        )
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
        if !allowPendingMaintenance, let journal = pendingMaintenanceJournal(paths) {
            throw StateStoreError.maintenanceRecoveryRequired(journalPath: journal)
        }
        return try body()
    }

    func acquireOperationMutationFence(
        groupID: String
    ) throws -> OperationMutationFence {
        guard HostwrightResourceUUID.isValid(groupID) else {
            throw StateStoreError.invalidRecord(
                "Operation mutation fencing requires an exact group UUID."
            )
        }
        let paths = try configuration.maintenancePaths()
        let descriptor = try openSecureLock(
            paths.accessLockPath + ".operation-" + groupID.lowercased()
        )
        do {
            try acquire(
                descriptor,
                operation: LOCK_EX,
                deadline:
                    DispatchTime.now().uptimeNanoseconds + 250_000_000,
                role: "operation mutation fence"
            )
            return OperationMutationFence(descriptor: descriptor)
        } catch {
            close(descriptor)
            throw error
        }
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

    private func pendingMaintenanceJournal(_ paths: StateMaintenancePaths) -> String? {
        if pathExists(paths.journalPath) { return paths.journalPath }
        let retention = paths.journalPath + ".retention-v1"
        return pathExists(retention) ? retention : nil
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
