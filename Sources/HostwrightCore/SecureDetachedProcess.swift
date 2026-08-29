import Darwin
import Foundation

/// A long-lived child launched through the same bounded executable, environment,
/// working-directory, session, and descriptor rules as `SecureSubprocessRunner`.
public final class SecureDetachedProcess: @unchecked Sendable {
    public let processID: Int32

    private let lock = NSLock()
    private var reaped = false

    fileprivate init(processID: Int32) {
        self.processID = processID
    }

    public var isRunning: Bool {
        lock.withLock { pollUnlocked() }
    }

    public func terminate(graceMilliseconds: Int) {
        guard (10...5_000).contains(graceMilliseconds) else { return }
        lock.withLock {
            guard !reaped, pollUnlocked() else { return }
            _ = kill(-processID, SIGTERM)
            let deadline = DispatchTime.now().uptimeNanoseconds +
                UInt64(graceMilliseconds) * 1_000_000
            while pollUnlocked(), DispatchTime.now().uptimeNanoseconds < deadline {
                usleep(20_000)
            }
            if pollUnlocked() {
                _ = kill(-processID, SIGKILL)
            }
            reapUnlocked()
        }
    }

    deinit {
        terminate(graceMilliseconds: 1_000)
    }

    private func pollUnlocked() -> Bool {
        guard !reaped else { return false }
        var status: Int32 = 0
        let result = waitpid(processID, &status, WNOHANG)
        if result == processID {
            reaped = true
            return false
        }
        if result < 0, errno == ECHILD || errno == ESRCH {
            reaped = true
            return false
        }
        return result == 0 || result < 0
    }

    private func reapUnlocked() {
        guard !reaped else { return }
        var status: Int32 = 0
        while true {
            let result = waitpid(processID, &status, 0)
            if result == processID || (result < 0 && errno == ECHILD) {
                reaped = true
                return
            }
            if result < 0, errno == EINTR { continue }
            reaped = true
            return
        }
    }
}

public extension SecureSubprocessRunner {
    /// Launches a supervised process without waiting for its natural exit.
    /// Standard streams are pinned to `/dev/null`; callers retain only the
    /// process-group handle and must explicitly terminate it.
    func launchDetached(
        _ request: SecureSubprocessRequest,
        standardInput: Int32? = nil,
        standardOutput: Int32? = nil,
        standardError: Int32? = nil
    ) throws -> SecureDetachedProcess {
        try Self.validate(request)
        guard request.standardInput == nil,
              [standardInput, standardOutput, standardError].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw SecureSubprocessError.invalidRequest(.invalidInputLimit)
        }

        let executable: SecureExecutableIdentity
        do {
            executable = try SecureExecutableResolver.verify(path: request.executablePath)
        } catch let error as SecureExecutableValidationError {
            throw SecureSubprocessError.executableRejected(error)
        }
        let workingDirectory: (path: String, descriptor: Int32)
        do {
            workingDirectory = try SecureExecutableResolver.openWorkingDirectory(
                path: request.workingDirectory
            )
        } catch let error as SecureExecutableValidationError {
            throw SecureSubprocessError.workingDirectoryRejected(error)
        }
        defer { close(workingDirectory.descriptor) }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw SecureSubprocessError.spawnSetupFailed(errno)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw SecureSubprocessError.spawnSetupFailed(errno)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let nullDevice = "/dev/null"
        guard addStandardDescriptor(
            standardInput,
            target: STDIN_FILENO,
            nullDevice: nullDevice,
            flags: O_RDONLY,
            fileActions: &fileActions
        ), addStandardDescriptor(
            standardOutput,
            target: STDOUT_FILENO,
            nullDevice: nullDevice,
            flags: O_WRONLY,
            fileActions: &fileActions
        ), addStandardDescriptor(
            standardError,
            target: STDERR_FILENO,
            nullDevice: nullDevice,
            flags: O_WRONLY,
            fileActions: &fileActions
        ),
            posix_spawn_file_actions_addfchdir(&fileActions, workingDirectory.descriptor) == 0,
            posix_spawn_file_actions_addclose(&fileActions, workingDirectory.descriptor) == 0 else {
            throw SecureSubprocessError.spawnSetupFailed(errno)
        }

        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        guard posix_spawnattr_setsigmask(&attributes, &signalMask) == 0 else {
            throw SecureSubprocessError.spawnSetupFailed(errno)
        }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGALRM, SIGHUP, SIGINT, SIGPIPE, SIGQUIT, SIGTERM] {
            sigaddset(&defaultSignals, signal)
        }
        guard posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0 else {
            throw SecureSubprocessError.spawnSetupFailed(errno)
        }
        let flags = Int16(
            POSIX_SPAWN_SETSID |
                POSIX_SPAWN_CLOEXEC_DEFAULT |
                POSIX_SPAWN_SETSIGMASK |
                POSIX_SPAWN_SETSIGDEF |
                POSIX_SPAWN_START_SUSPENDED
        )
        guard posix_spawnattr_setflags(&attributes, flags) == 0 else {
            throw SecureSubprocessError.spawnSetupFailed(errno)
        }

        var arguments = try allocateCStringVector([executable.path] + request.arguments)
        defer { freeCStringVector(&arguments) }
        var environment = try allocateCStringVector(
            request.environment.map { "\($0.key)=\($0.value)" }.sorted()
        )
        defer { freeCStringVector(&environment) }

        var processID: pid_t = 0
        let launchCode = arguments.withUnsafeMutableBufferPointer { argumentBuffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processID,
                    executable.path,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress!,
                    environmentBuffer.baseAddress!
                )
            }
        }
        guard launchCode == 0 else {
            throw SecureSubprocessError.launchFailed(launchCode)
        }

        do {
            try SecureExecutableResolver.verifyUnchanged(executable)
        } catch {
            terminateDetachedProcess(processID)
            throw SecureSubprocessError.executableChanged
        }
        guard kill(processID, SIGCONT) == 0 else {
            let code = errno
            terminateDetachedProcess(processID)
            throw SecureSubprocessError.launchFailed(code)
        }
        return SecureDetachedProcess(processID: processID)
    }
}

private func addStandardDescriptor(
    _ descriptor: Int32?,
    target: Int32,
    nullDevice: String,
    flags: Int32,
    fileActions: inout posix_spawn_file_actions_t?
) -> Bool {
    guard let descriptor else {
        return posix_spawn_file_actions_addopen(&fileActions, target, nullDevice, flags, 0) == 0
    }
    if descriptor == target {
        return true
    }
    return posix_spawn_file_actions_adddup2(&fileActions, descriptor, target) == 0 &&
        posix_spawn_file_actions_addclose(&fileActions, descriptor) == 0
}

private func allocateCStringVector(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
    var result: [UnsafeMutablePointer<CChar>?] = []
    result.reserveCapacity(strings.count + 1)
    for string in strings {
        guard let pointer = strdup(string) else {
            freeCStringVector(&result)
            throw SecureSubprocessError.spawnSetupFailed(ENOMEM)
        }
        result.append(pointer)
    }
    result.append(nil)
    return result
}

private func freeCStringVector(_ vector: inout [UnsafeMutablePointer<CChar>?]) {
    for pointer in vector {
        if let pointer { free(pointer) }
    }
    vector.removeAll(keepingCapacity: false)
}

private func terminateDetachedProcess(_ processID: pid_t) {
    _ = kill(-processID, SIGKILL)
    var status: Int32 = 0
    while waitpid(processID, &status, 0) < 0, errno == EINTR {}
}
