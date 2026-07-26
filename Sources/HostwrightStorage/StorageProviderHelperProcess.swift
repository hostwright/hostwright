import Darwin
import Foundation
import HostwrightCore

public final class StorageProviderHelperProcessLease: @unchecked Sendable {
    public let processID: pid_t

    private let running: @Sendable () -> Bool
    private let resumeImplementation: @Sendable () throws -> Void
    private let terminateImplementation: @Sendable () -> Void

    public init(
        processID: pid_t,
        isRunning: @escaping @Sendable () -> Bool,
        resume: @escaping @Sendable () throws -> Void = {},
        terminate: @escaping @Sendable () -> Void
    ) {
        self.processID = processID
        running = isRunning
        resumeImplementation = resume
        terminateImplementation = terminate
    }

    public var isRunning: Bool {
        running()
    }

    public func resume() throws {
        try resumeImplementation()
    }

    public func terminate() {
        terminateImplementation()
    }

    deinit {
        terminateImplementation()
    }
}

public struct StorageProviderHelperProcessLauncher: Sendable {
    private let launchImplementation: @Sendable (
        StorageProviderHelperBootstrapConfiguration,
        SecureExecutableIdentity
    ) throws -> StorageProviderHelperProcessLease

    public init(
        launch: @escaping @Sendable (
            StorageProviderHelperBootstrapConfiguration,
            SecureExecutableIdentity
        ) throws -> StorageProviderHelperProcessLease
    ) {
        launchImplementation = launch
    }

    public func launch(
        configuration: StorageProviderHelperBootstrapConfiguration,
        executableIdentity: SecureExecutableIdentity
    ) throws -> StorageProviderHelperProcessLease {
        try launchImplementation(configuration, executableIdentity)
    }

    public static let system = StorageProviderHelperProcessLauncher {
        configuration,
        executableIdentity in
        try StorageProviderHelperPOSIXLauncher.launchSuspended(
            configuration: configuration,
            executableIdentity: executableIdentity
        )
    }
}

private enum StorageProviderHelperPOSIXLauncher {
    static func launchSuspended(
        configuration: StorageProviderHelperBootstrapConfiguration,
        executableIdentity: SecureExecutableIdentity
    ) throws -> StorageProviderHelperProcessLease {
        let rootDirectory = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDirectory >= 0 else {
            throw StorageProviderHelperBootstrapError.launchFailed
        }
        defer { Darwin.close(rootDirectory) }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw StorageProviderHelperBootstrapError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw StorageProviderHelperBootstrapError.launchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }

        try requireSpawnSuccess(
            posix_spawn_file_actions_addfchdir(
                &fileActions,
                rootDirectory
            )
        )
        try requireSpawnSuccess(
            posix_spawn_file_actions_addclose(
                &fileActions,
                rootDirectory
            )
        )
        try requireSpawnSuccess(
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                "/dev/null",
                O_RDONLY,
                0
            )
        )
        try requireSpawnSuccess(
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDOUT_FILENO,
                "/dev/null",
                O_WRONLY,
                0
            )
        )
        try requireSpawnSuccess(
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDERR_FILENO,
                "/dev/null",
                O_WRONLY,
                0
            )
        )

        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try requireSpawnSuccess(
            posix_spawnattr_setsigmask(&attributes, &signalMask)
        )
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGALRM, SIGHUP, SIGINT, SIGPIPE, SIGQUIT, SIGTERM] {
            sigaddset(&defaultSignals, signal)
        }
        try requireSpawnSuccess(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        )
        let flags = Int16(
            POSIX_SPAWN_SETSID |
                POSIX_SPAWN_CLOEXEC_DEFAULT |
                POSIX_SPAWN_SETSIGMASK |
                POSIX_SPAWN_SETSIGDEF |
                POSIX_SPAWN_START_SUSPENDED
        )
        try requireSpawnSuccess(
            posix_spawnattr_setflags(&attributes, flags)
        )

        var arguments = try allocateCStringVector([
            executableIdentity.path,
            "run",
            "--provider",
            LocalStorageProviderContract.providerID,
            "--runtime-dir",
            configuration.runtimeDirectoryURL.path,
            "--provider-root",
            configuration.providerRootURL.path,
            "--capacity-bytes",
            String(configuration.capacityBytes)
        ])
        defer { freeCStringVector(&arguments) }
        var environment = try allocateCStringVector(exactEnvironment())
        defer { freeCStringVector(&environment) }

        var processID = pid_t(0)
        let launchCode = arguments.withUnsafeMutableBufferPointer {
            argumentBuffer in
            environment.withUnsafeMutableBufferPointer {
                environmentBuffer in
                posix_spawn(
                    &processID,
                    executableIdentity.path,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress!,
                    environmentBuffer.baseAddress!
                )
            }
        }
        guard launchCode == 0 else {
            throw StorageProviderHelperBootstrapError.launchFailed
        }

        let launchedProcessID = processID
        let state = StorageProviderHelperPOSIXProcessState(
            processID: launchedProcessID
        )
        return StorageProviderHelperProcessLease(
            processID: launchedProcessID,
            isRunning: { state.isRunning },
            resume: {
                let result = kill(launchedProcessID, SIGCONT)
                guard result == 0 else {
                    state.terminate()
                    throw StorageProviderHelperBootstrapError.launchFailed
                }
                guard state.startObservation() else {
                    state.terminate()
                    throw StorageProviderHelperBootstrapError.launchFailed
                }
            },
            terminate: {
                state.terminate()
            }
        )
    }

    private static func exactEnvironment() -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let temporaryDirectory =
            safeAbsoluteEnvironmentPath(environment["TMPDIR"]) ?? "/tmp"
        let homeDirectory =
            safeAbsoluteEnvironmentPath(
                FileManager.default.homeDirectoryForCurrentUser.path
            ) ?? "/var/empty"
        return [
            "HOME=\(homeDirectory)",
            "LANG=C",
            "LC_ALL=C",
            "TMPDIR=\(temporaryDirectory)"
        ]
    }

    private static func safeAbsoluteEnvironmentPath(
        _ value: String?
    ) -> String? {
        guard let value,
              value.hasPrefix("/"),
              !value.contains("\0"),
              value.utf8.count <= Int(PATH_MAX),
              value.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value != 0x7f
              }) else {
            return nil
        }
        return value
    }

    private static func requireSpawnSuccess(_ code: Int32) throws {
        guard code == 0 else {
            throw StorageProviderHelperBootstrapError.launchFailed
        }
    }

    private static func allocateCStringVector(
        _ strings: [String]
    ) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for string in strings {
            guard !string.contains("\0"),
                  let pointer = strdup(string) else {
                freeCStringVector(&result)
                throw StorageProviderHelperBootstrapError.launchFailed
            }
            result.append(pointer)
        }
        result.append(nil)
        return result
    }

    private static func freeCStringVector(
        _ vector: inout [UnsafeMutablePointer<CChar>?]
    ) {
        for pointer in vector {
            if let pointer {
                free(pointer)
            }
        }
        vector.removeAll(keepingCapacity: false)
    }
}

private final class StorageProviderHelperPOSIXProcessState:
    @unchecked Sendable
{
    private let processID: pid_t
    private let condition = NSCondition()
    private var reaped = false
    private var observationStarted = false
    private var terminationStarted = false

    init(processID: pid_t) {
        self.processID = processID
    }

    func startObservation() -> Bool {
        condition.lock()
        guard !reaped,
              !terminationStarted,
              !observationStarted else {
            condition.unlock()
            return false
        }
        observationStarted = true
        condition.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            observeLeaderExitAndReap()
        }
        return true
    }

    var isRunning: Bool {
        condition.lock()
        defer { condition.unlock() }
        return !reaped
    }

    func terminate() {
        condition.lock()
        let shouldSignal = !reaped && !terminationStarted
        let wasObserved = observationStarted
        if shouldSignal {
            terminationStarted = true
        }
        condition.unlock()

        if shouldSignal {
            guard wasObserved else {
                signalProcessGroup(SIGKILL)
                reapSuspendedLeader()
                return
            }
            signalProcessGroup(SIGTERM)
            if !waitUntilReaped(milliseconds: 100) {
                signalProcessGroup(SIGKILL)
            }
        }
        _ = waitUntilReaped(milliseconds: 2_000)
    }

    private func reapSuspendedLeader() {
        var status: Int32 = 0
        while waitpid(processID, &status, 0) < 0 {
            if errno == EINTR {
                continue
            }
            break
        }
        markReaped()
    }

    private func observeLeaderExitAndReap() {
        var information = siginfo_t()
        while waitid(
            P_PID,
            id_t(processID),
            &information,
            WEXITED | WNOWAIT
        ) != 0 {
            if errno == EINTR {
                continue
            }
            markReaped()
            return
        }
        guard information.si_pid == processID else {
            markReaped()
            return
        }

        _ = kill(-processID, SIGKILL)
        var status: Int32 = 0
        while waitpid(processID, &status, 0) < 0, errno == EINTR {}
        markReaped()
    }

    private func markReaped() {
        condition.lock()
        reaped = true
        condition.broadcast()
        condition.unlock()
    }

    private func waitUntilReaped(milliseconds: Int) -> Bool {
        let deadline = Date(
            timeIntervalSinceNow: Double(milliseconds) / 1_000
        )
        condition.lock()
        while !reaped, condition.wait(until: deadline) {}
        let result = reaped
        condition.unlock()
        return result
    }

    private func signalProcessGroup(_ signal: Int32) {
        if kill(-processID, signal) != 0, errno == ESRCH {
            _ = kill(processID, signal)
        }
    }
}
