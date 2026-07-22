import Darwin
import Foundation
import HostwrightCore
import HostwrightRuntime

enum RuntimeQualificationHelperTiming {
    static let normalRequestTimeoutMilliseconds: Int64 = 30_000
    static let injectedTimeoutMilliseconds: Int64 = 500
    static let finalShutdownTimeoutMilliseconds: Int64 = 2_000
}

final class RuntimeQualificationLaunchObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: pid_t?

    func record(_ processID: pid_t) {
        lock.withLock { value = processID }
    }

    var processID: pid_t? {
        lock.withLock { value }
    }
}

enum RuntimeQualificationInjectedPartialEffect: Error, Equatable {
    case afterRuntimeMutation
}

final class RuntimeQualificationPartialEffectFaultController: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var activated = false

    func arm() {
        lock.withLock {
            armed = true
            activated = false
        }
    }

    func failAfterRuntimeMutation() throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false
            activated = true
            return true
        }
        guard shouldFail else { return }
        throw RuntimeQualificationInjectedPartialEffect.afterRuntimeMutation
    }

    var didActivate: Bool {
        lock.withLock { activated }
    }
}

struct RuntimeQualificationRecordingProcessRunner: RuntimeProcessRunning {
    let recorder: RuntimeQualificationCommandRecorder
    private let delegate = SecureRuntimeProcessRunner()

    func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
        do {
            let result = try await delegate.run(spec)
            await recorder.record(
                arguments: [spec.executablePath] + spec.redacted().arguments,
                exitStatus: Int(result.exitStatus)
            )
            return result
        } catch {
            await recorder.record(
                arguments: [spec.executablePath] + spec.redacted().arguments,
                exitStatus: Self.exitStatus(error)
            )
            throw error
        }
    }

    private static func exitStatus(_ error: Error) -> Int {
        guard let error = error as? RuntimeAdapterError else { return -1 }
        switch error {
        case .commandFailed(let status, _, _): return Int(status)
        case .commandTimedOut, .commandCancelled, .commandOutputLimitExceeded,
             .commandProcessTreeViolation, .managedRestartStartFailedAfterStop:
            return -1
        default:
            return -1
        }
    }
}

final class RuntimeQualificationHelperProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var currentLease: ContainerizationHelperProcessLease?

    func launcher() -> ContainerizationHelperProcessLauncher {
        ContainerizationHelperProcessLauncher { [self] configuration in
            let lease = try ContainerizationHelperProcessLauncher.system.launch(
                configuration: configuration
            )
            lock.withLock { currentLease = lease }
            return lease
        }
    }

    func terminateCurrent() -> Bool {
        lock.withLock {
            guard let currentLease else { return false }
            currentLease.terminate()
            let deadline = Date().addingTimeInterval(2)
            while currentLease.isRunning, Date() < deadline { usleep(10_000) }
            return !currentLease.isRunning
        }
    }

    func currentProcessID() -> pid_t? {
        lock.withLock { currentLease?.processID }
    }

    func waitUntilStoppedAndSocketRemoved(
        socketURL: URL,
        timeoutMilliseconds: Int64
    ) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(1, timeoutMilliseconds)) * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if currentStoppedAndSocketRemoved(socketURL: socketURL) { return true }
            usleep(10_000)
        }
        return currentStoppedAndSocketRemoved(socketURL: socketURL)
    }

    private func currentStoppedAndSocketRemoved(socketURL: URL) -> Bool {
        let stopped = lock.withLock { currentLease?.isRunning != true }
        var metadata = stat()
        errno = 0
        let socketRemoved = lstat(socketURL.path, &metadata) != 0 && errno == ENOENT
        return stopped && socketRemoved
    }
}

final class RuntimeQualificationHelperFaultController: @unchecked Sendable {
    enum Mode: Sendable {
        case none
        case timedOut(deadlineMilliseconds: Int64)
        case cancelled
        case crashed
    }

    private let lock = NSLock()
    private let registry: RuntimeQualificationHelperProcessRegistry
    private let socketURL: URL
    private var nextMode: Mode = .none
    private var activated = false
    private var terminated = false
    private var deadlineEnforced = false

    init(registry: RuntimeQualificationHelperProcessRegistry, socketURL: URL) {
        self.registry = registry
        self.socketURL = socketURL
    }

    func transport() -> ContainerizationHelperClientTransport {
        ContainerizationHelperClientTransport { [self] frame, socket, deadline, expectedPID in
            let mode = consumeMode()
            switch mode {
            case .none:
                return try await ContainerizationHelperClientTransport.unix.exchange(
                    frame: frame,
                    socketURL: socket,
                    deadlineUnixMilliseconds: deadline,
                    expectedProcessID: expectedPID
                )
            case .timedOut(let injectedDeadlineMilliseconds):
                let now = Int64(Date().timeIntervalSince1970 * 1_000)
                let wait = max(1, min(injectedDeadlineMilliseconds, deadline - now))
                let started = DispatchTime.now().uptimeNanoseconds
                try await Task.sleep(for: .milliseconds(wait))
                let elapsed = Int64(
                    (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                )
                markDeadlineEnforced(
                    injectedDeadlineMilliseconds > 0 &&
                        injectedDeadlineMilliseconds <= 2_000 &&
                        elapsed >= injectedDeadlineMilliseconds
                )
                markTerminated(registry.terminateCurrent())
                throw ContainerizationHelperClientError.timedOut
            case .cancelled:
                do {
                    try await Task.sleep(for: .seconds(30))
                    throw ContainerizationHelperClientError.invalidResponse
                } catch is CancellationError {
                    markTerminated(registry.terminateCurrent())
                    throw CancellationError()
                }
            case .crashed:
                markTerminated(registry.terminateCurrent())
                throw ContainerizationHelperClientError.helperExited
            }
        }
    }

    func arm(_ mode: Mode) {
        lock.withLock {
            nextMode = mode
            activated = false
            terminated = false
            deadlineEnforced = false
        }
    }

    func evidence() -> (activated: Bool, terminated: Bool, deadlineEnforced: Bool) {
        lock.withLock { (activated, terminated, deadlineEnforced) }
    }

    func verifyFinalShutdown() -> Bool {
        registry.waitUntilStoppedAndSocketRemoved(
            socketURL: socketURL,
            timeoutMilliseconds: RuntimeQualificationHelperTiming.finalShutdownTimeoutMilliseconds
        )
    }

    private func consumeMode() -> Mode {
        lock.withLock {
            let mode = nextMode
            nextMode = .none
            if case .none = mode {} else { activated = true }
            return mode
        }
    }

    private func markTerminated(_ value: Bool) {
        lock.withLock { terminated = value }
    }

    private func markDeadlineEnforced(_ value: Bool) {
        lock.withLock { deadlineEnforced = value }
    }
}

enum RuntimeQualificationSubprocessProbe {
    private static let appleSystemLogArguments = ["system", "logs", "--follow"]

    static func timedOut(
        executable: String,
        arguments: [String] = appleSystemLogArguments
    ) async throws -> Bool {
        let request = request(
            executable: executable,
            arguments: arguments,
            timeoutMilliseconds: 500
        )
        do {
            _ = try await SecureSubprocessRunner().runAsync(request)
            return false
        } catch SecureSubprocessError.timedOut {
            return true
        }
    }

    static func cancelled(
        executable: String,
        arguments: [String] = appleSystemLogArguments
    ) async throws -> Bool {
        let task = Task {
            try await SecureSubprocessRunner().runAsync(
                request(
                    executable: executable,
                    arguments: arguments,
                    timeoutMilliseconds: 30_000
                )
            )
        }
        try await Task.sleep(for: .milliseconds(250))
        task.cancel()
        do {
            _ = try await task.value
            return false
        } catch SecureSubprocessError.cancelled {
            return true
        }
    }

    static func crashed(
        executable: String,
        arguments: [String] = appleSystemLogArguments
    ) async throws -> Bool {
        let observation = RuntimeQualificationLaunchObservation()
        let task = Task {
            try await SecureSubprocessRunner().runAsync(
                request(
                    executable: executable,
                    arguments: arguments,
                    timeoutMilliseconds: 30_000
                ),
                onLaunch: observation.record
            )
        }
        try await Task.sleep(for: .milliseconds(250))
        guard let processID = observation.processID,
              getpgid(processID) == processID else {
            task.cancel()
            _ = try? await task.value
            return false
        }
        errno = 0
        guard Darwin.kill(-processID, SIGKILL) == 0 || errno == ESRCH else {
            task.cancel()
            _ = try? await task.value
            return false
        }
        do {
            let result = try await task.value
            return result.terminationSignal == SIGKILL &&
                waitUntilProcessGroupAbsent(processID, timeoutMilliseconds: 2_000)
        } catch SecureSubprocessError.descendantProcessDetected(let result) {
            return result.terminationSignal == SIGKILL &&
                waitUntilProcessGroupAbsent(processID, timeoutMilliseconds: 2_000)
        } catch SecureSubprocessError.outputReadFailed(let result) {
            return result.terminationSignal == SIGKILL &&
                waitUntilProcessGroupAbsent(processID, timeoutMilliseconds: 2_000)
        }
    }

    private static func waitUntilProcessGroupAbsent(
        _ processGroupID: pid_t,
        timeoutMilliseconds: Int64
    ) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(1, timeoutMilliseconds)) * 1_000_000
        repeat {
            errno = 0
            if Darwin.kill(-processGroupID, 0) == -1 && errno == ESRCH {
                return true
            }
            usleep(10_000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        errno = 0
        return Darwin.kill(-processGroupID, 0) == -1 && errno == ESRCH
    }

    private static func request(
        executable: String,
        arguments: [String],
        timeoutMilliseconds: Int
    ) -> SecureSubprocessRequest {
        SecureSubprocessRequest(
            executablePath: executable,
            arguments: arguments,
            environment: SecureSubprocessEnvironment.currentUser,
            workingDirectory: "/",
            timeoutMilliseconds: timeoutMilliseconds,
            terminationGraceMilliseconds: 100,
            maximumStandardOutputBytes: 1 * 1_024 * 1_024,
            maximumStandardErrorBytes: 1 * 1_024 * 1_024
        )
    }
}
