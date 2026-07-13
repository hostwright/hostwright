import Darwin
import Foundation

public enum SecureSubprocessRequestError: Error, Equatable, Sendable {
    case invalidTimeout
    case invalidTerminationGrace
    case invalidOutputLimit
    case invalidInputLimit
    case invalidArgument
    case argumentDataTooLarge
    case invalidEnvironment
    case unsafeEnvironment
    case environmentDataTooLarge
}

public struct SecureSubprocessRequest: Equatable, Sendable {
    public static let defaultMaximumOutputBytes = 8 * 1_024 * 1_024
    public static let defaultMaximumInputBytes = 1 * 1_024 * 1_024

    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
    public let standardInput: Data?
    public let timeoutMilliseconds: Int
    public let terminationGraceMilliseconds: Int
    public let maximumStandardOutputBytes: Int
    public let maximumStandardErrorBytes: Int
    public let maximumStandardInputBytes: Int

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = SecureSubprocessEnvironment.minimal,
        workingDirectory: String = "/",
        standardInput: Data? = nil,
        timeoutMilliseconds: Int = 30_000,
        terminationGraceMilliseconds: Int = 1_000,
        maximumStandardOutputBytes: Int = SecureSubprocessRequest.defaultMaximumOutputBytes,
        maximumStandardErrorBytes: Int = SecureSubprocessRequest.defaultMaximumOutputBytes,
        maximumStandardInputBytes: Int = SecureSubprocessRequest.defaultMaximumInputBytes
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
        self.timeoutMilliseconds = timeoutMilliseconds
        self.terminationGraceMilliseconds = terminationGraceMilliseconds
        self.maximumStandardOutputBytes = maximumStandardOutputBytes
        self.maximumStandardErrorBytes = maximumStandardErrorBytes
        self.maximumStandardInputBytes = maximumStandardInputBytes
    }
}

public struct SecureSubprocessResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let terminationSignal: Int32?
    public let standardOutput: Data
    public let standardError: Data
    public let durationMilliseconds: Int
    public let standardOutputTruncated: Bool
    public let standardErrorTruncated: Bool

    public init(
        exitStatus: Int32,
        terminationSignal: Int32?,
        standardOutput: Data,
        standardError: Data,
        durationMilliseconds: Int,
        standardOutputTruncated: Bool,
        standardErrorTruncated: Bool
    ) {
        self.exitStatus = exitStatus
        self.terminationSignal = terminationSignal
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.durationMilliseconds = durationMilliseconds
        self.standardOutputTruncated = standardOutputTruncated
        self.standardErrorTruncated = standardErrorTruncated
    }
}

public enum SecureSubprocessError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidRequest(SecureSubprocessRequestError)
    case executableRejected(SecureExecutableValidationError)
    case workingDirectoryRejected(SecureExecutableValidationError)
    case spawnSetupFailed(Int32)
    case launchFailed(Int32)
    case executableChanged
    case timedOut(SecureSubprocessResult)
    case cancelled(SecureSubprocessResult)
    case outputLimitExceeded(SecureSubprocessResult)
    case inputWriteFailed(SecureSubprocessResult)
    case outputReadFailed(SecureSubprocessResult)
    case waitFailed(SecureSubprocessResult)
    case descendantProcessDetected(SecureSubprocessResult)
    case processTreeCleanupFailed(SecureSubprocessResult)

    public var description: String {
        switch self {
        case .invalidRequest: "Subprocess request is invalid."
        case .executableRejected(let error): "Subprocess executable was rejected: \(error.description)"
        case .workingDirectoryRejected(let error): "Subprocess working directory was rejected: \(error.description)"
        case .spawnSetupFailed(let code): "Subprocess spawn setup failed with system error \(code)."
        case .launchFailed(let code): "Subprocess launch failed with system error \(code)."
        case .executableChanged: "Subprocess executable identity changed before execution."
        case .timedOut: "Subprocess timed out and its process group was terminated."
        case .cancelled: "Subprocess was cancelled and its process group was terminated."
        case .outputLimitExceeded: "Subprocess exceeded a bounded output limit and was terminated."
        case .inputWriteFailed: "Subprocess closed its bounded input before the request was delivered."
        case .outputReadFailed: "Subprocess output could not be read safely."
        case .waitFailed: "Subprocess exit status could not be collected safely."
        case .descendantProcessDetected: "Subprocess leader exited while descendants remained; the process group was terminated."
        case .processTreeCleanupFailed: "Subprocess process-tree cleanup did not converge within the bounded window."
        }
    }
}

public final class SecureSubprocessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

public struct SecureSubprocessRunner: Sendable {
    public init() {}

    public func run(
        _ request: SecureSubprocessRequest,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> SecureSubprocessResult {
        try validate(request)
        if cancellation.isCancelled {
            throw SecureSubprocessError.cancelled(preLaunchCancellationResult())
        }

        let executable: SecureExecutableIdentity
        do {
            executable = try SecureExecutableResolver.verify(path: request.executablePath)
        } catch let error as SecureExecutableValidationError {
            throw SecureSubprocessError.executableRejected(error)
        }
        let workingDirectory: (path: String, descriptor: Int32)
        do {
            workingDirectory = try SecureExecutableResolver.openWorkingDirectory(path: request.workingDirectory)
        } catch let error as SecureExecutableValidationError {
            throw SecureSubprocessError.workingDirectoryRejected(error)
        }
        defer { close(workingDirectory.descriptor) }

        var inputPipe = request.standardInput == nil ? nil : try makePipe()
        defer { inputPipe?.closeBoth() }
        var outputPipe = try makePipe()
        defer { outputPipe.closeBoth() }
        var errorPipe = try makePipe()
        defer { errorPipe.closeBoth() }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try requireSpawnSuccess(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try requireSpawnSuccess(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        if let inputPipe {
            try requireSpawnSuccess(posix_spawn_file_actions_adddup2(&fileActions, inputPipe.readDescriptor, STDIN_FILENO))
            try requireSpawnSuccess(posix_spawn_file_actions_addclose(&fileActions, inputPipe.readDescriptor))
            try requireSpawnSuccess(posix_spawn_file_actions_addclose(&fileActions, inputPipe.writeDescriptor))
        } else {
            try requireSpawnSuccess(posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        }
        try requireSpawnSuccess(posix_spawn_file_actions_adddup2(&fileActions, outputPipe.writeDescriptor, STDOUT_FILENO))
        try requireSpawnSuccess(posix_spawn_file_actions_addclose(&fileActions, outputPipe.readDescriptor))
        try requireSpawnSuccess(posix_spawn_file_actions_addclose(&fileActions, outputPipe.writeDescriptor))
        try requireSpawnSuccess(posix_spawn_file_actions_adddup2(&fileActions, errorPipe.writeDescriptor, STDERR_FILENO))
        try requireSpawnSuccess(posix_spawn_file_actions_addclose(&fileActions, errorPipe.readDescriptor))
        try requireSpawnSuccess(posix_spawn_file_actions_addclose(&fileActions, errorPipe.writeDescriptor))
        try requireSpawnSuccess(
            posix_spawn_file_actions_addfchdir(&fileActions, workingDirectory.descriptor)
        )
        try requireSpawnSuccess(
            posix_spawn_file_actions_addclose(&fileActions, workingDirectory.descriptor)
        )

        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try requireSpawnSuccess(posix_spawnattr_setsigmask(&attributes, &signalMask))
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGALRM, SIGHUP, SIGINT, SIGPIPE, SIGQUIT, SIGTERM] {
            sigaddset(&defaultSignals, signal)
        }
        try requireSpawnSuccess(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
        let flags = Int16(
            POSIX_SPAWN_SETSID |
                POSIX_SPAWN_CLOEXEC_DEFAULT |
                POSIX_SPAWN_SETSIGMASK |
                POSIX_SPAWN_SETSIGDEF |
                POSIX_SPAWN_START_SUSPENDED
        )
        try requireSpawnSuccess(posix_spawnattr_setflags(&attributes, flags))

        var arguments = try allocateCStringVector([executable.path] + request.arguments)
        defer { freeCStringVector(&arguments) }
        let environmentStrings = request.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var environment = try allocateCStringVector(environmentStrings)
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

        inputPipe?.closeRead()
        outputPipe.closeWrite()
        errorPipe.closeWrite()
        do {
            try SecureExecutableResolver.verifyUnchanged(executable)
        } catch {
            terminateSuspendedProcess(processID)
            throw SecureSubprocessError.executableChanged
        }
        guard kill(processID, SIGCONT) == 0 else {
            let code = errno
            terminateSuspendedProcess(processID)
            throw SecureSubprocessError.launchFailed(code)
        }

        do {
            try setNonBlocking(outputPipe.readDescriptor)
            try setNonBlocking(errorPipe.readDescriptor)
            if let inputPipe {
                try setNonBlocking(inputPipe.writeDescriptor)
                guard fcntl(inputPipe.writeDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                    throw SecureSubprocessError.spawnSetupFailed(errno)
                }
            }
        } catch {
            terminateRunningProcess(processID)
            throw error
        }

        return try monitor(
            processID: processID,
            request: request,
            cancellation: cancellation,
            inputPipe: &inputPipe,
            outputPipe: &outputPipe,
            errorPipe: &errorPipe
        )
    }

    public func runAsync(_ request: SecureSubprocessRequest) async throws -> SecureSubprocessResult {
        let cancellation = SecureSubprocessCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try run(request, cancellation: cancellation))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func monitor(
        processID: pid_t,
        request: SecureSubprocessRequest,
        cancellation: SecureSubprocessCancellation,
        inputPipe: inout DescriptorPipe?,
        outputPipe: inout DescriptorPipe,
        errorPipe: inout DescriptorPipe
    ) throws -> SecureSubprocessResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let timeoutAt = started + UInt64(request.timeoutMilliseconds) * 1_000_000
        let graceNanoseconds = UInt64(request.terminationGraceMilliseconds) * 1_000_000
        let cleanupNanoseconds: UInt64 = 2_000_000_000
        var output = BoundedSubprocessData(maximumBytes: request.maximumStandardOutputBytes)
        var errors = BoundedSubprocessData(maximumBytes: request.maximumStandardErrorBytes)
        var inputOffset = 0
        var leaderStatus: Int32?
        var leaderExitObserved = false
        var leaderObservationFailed = false
        var cause: SubprocessTerminationCause?
        var terminationSentAt: UInt64?
        var killSentAt: UInt64?
        var leaderExitedAt: UInt64?

        while true {
            if let readError = drain(pipe: &outputPipe, into: &output), cause == nil {
                cause = .outputReadFailed(readError)
            }
            if let readError = drain(pipe: &errorPipe, into: &errors), cause == nil {
                cause = .outputReadFailed(readError)
            }
            if let writeError = writeInput(request.standardInput, offset: &inputOffset, pipe: &inputPipe), cause == nil {
                cause = .inputWriteFailed(writeError)
            }

            let now = DispatchTime.now().uptimeNanoseconds
            if !leaderExitObserved, leaderStatus == nil {
                switch observeLeaderExit(processID) {
                case .running:
                    break
                case .exited:
                    leaderExitObserved = true
                    leaderExitedAt = now
                    if let input = request.standardInput, inputOffset < input.count, cause == nil {
                        cause = .inputWriteFailed(EPIPE)
                    }
                    inputPipe?.closeWrite()
                case .failed(let code):
                    if cause == nil { cause = .waitFailed(code) }
                    leaderObservationFailed = true
                    leaderExitObserved = true
                    leaderStatus = -1
                    leaderExitedAt = now
                    inputPipe?.closeWrite()
                }
            }

            if cause == nil {
                if cancellation.isCancelled {
                    cause = .cancelled
                } else if output.overflowed || errors.overflowed {
                    cause = .outputLimitExceeded
                } else if now >= timeoutAt {
                    cause = .timedOut
                }
            }

            if cause != nil,
               terminationSentAt == nil,
               leaderStatus == nil,
               !leaderExitObserved {
                inputPipe?.closeWrite()
                signalOwnedProcessGroup(processID, signal: SIGTERM, leaderIsUnreaped: true)
                terminationSentAt = now
            }
            if let terminationSentAt,
               killSentAt == nil,
               now >= terminationSentAt + graceNanoseconds,
               leaderStatus == nil,
               !leaderExitObserved {
                signalOwnedProcessGroup(processID, signal: SIGKILL, leaderIsUnreaped: true)
                killSentAt = now
            }

            if leaderExitObserved,
               !leaderObservationFailed,
               leaderStatus == nil {
                if killSentAt == nil {
                    signalOwnedProcessGroup(processID, signal: SIGSTOP, leaderIsUnreaped: true)
                }
                do {
                    leaderStatus = try reapExitedLeader(processID)
                } catch let error as POSIXError {
                    if cause == nil { cause = .waitFailed(error.code.rawValue) }
                    leaderStatus = -1
                    leaderObservationFailed = true
                } catch {
                    if cause == nil { cause = .waitFailed(ECHILD) }
                    leaderStatus = -1
                    leaderObservationFailed = true
                }
            }

            let groupExists: Bool
            if leaderStatus == nil {
                groupExists = true
            } else if leaderObservationFailed {
                groupExists = false
            } else {
                groupExists = processGroupExists(processID)
                if groupExists, killSentAt == nil {
                    if cause == nil { cause = .descendantProcessDetected }
                    signalOwnedProcessGroup(processID, signal: SIGKILL, leaderIsUnreaped: false)
                    killSentAt = now
                }
            }
            if leaderStatus != nil, !groupExists, outputPipe.readDescriptor < 0, errorPipe.readDescriptor < 0 {
                break
            }
            if let leaderExitedAt,
               !groupExists,
               now >= leaderExitedAt + 250_000_000,
               (outputPipe.readDescriptor >= 0 || errorPipe.readDescriptor >= 0) {
                outputPipe.closeRead()
                errorPipe.closeRead()
                if cause == nil { cause = .outputReadFailed(ETIMEDOUT) }
            }
            if let killSentAt, now >= killSentAt + cleanupNanoseconds {
                inputPipe?.closeWrite()
                outputPipe.closeRead()
                errorPipe.closeRead()
                if leaderStatus == nil { scheduleReap(processID) }
                let result = makeResult(
                    leaderStatus: leaderStatus,
                    output: output,
                    errors: errors,
                    started: started
                )
                throw SecureSubprocessError.processTreeCleanupFailed(result)
            }

            usleep(5_000)
        }

        let result = makeResult(
            leaderStatus: leaderStatus,
            output: output,
            errors: errors,
            started: started
        )
        switch cause {
        case nil:
            return result
        case .timedOut:
            throw SecureSubprocessError.timedOut(result)
        case .cancelled:
            throw SecureSubprocessError.cancelled(result)
        case .outputLimitExceeded:
            throw SecureSubprocessError.outputLimitExceeded(result)
        case .inputWriteFailed:
            throw SecureSubprocessError.inputWriteFailed(result)
        case .outputReadFailed:
            throw SecureSubprocessError.outputReadFailed(result)
        case .waitFailed:
            throw SecureSubprocessError.waitFailed(result)
        case .descendantProcessDetected:
            throw SecureSubprocessError.descendantProcessDetected(result)
        }
    }

    private func validate(_ request: SecureSubprocessRequest) throws {
        guard (1...86_400_000).contains(request.timeoutMilliseconds) else {
            throw SecureSubprocessError.invalidRequest(.invalidTimeout)
        }
        guard (10...5_000).contains(request.terminationGraceMilliseconds) else {
            throw SecureSubprocessError.invalidRequest(.invalidTerminationGrace)
        }
        guard (1...(64 * 1_024 * 1_024)).contains(request.maximumStandardOutputBytes),
              (1...(64 * 1_024 * 1_024)).contains(request.maximumStandardErrorBytes) else {
            throw SecureSubprocessError.invalidRequest(.invalidOutputLimit)
        }
        guard (0...(16 * 1_024 * 1_024)).contains(request.maximumStandardInputBytes),
              (request.standardInput?.count ?? 0) <= request.maximumStandardInputBytes else {
            throw SecureSubprocessError.invalidRequest(.invalidInputLimit)
        }
        guard request.arguments.count <= 4_096 else {
            throw SecureSubprocessError.invalidRequest(.argumentDataTooLarge)
        }
        var argumentBytes = 0
        for argument in request.arguments {
            guard !argument.contains("\0") else {
                throw SecureSubprocessError.invalidRequest(.invalidArgument)
            }
            argumentBytes += argument.utf8.count + 1
            guard argumentBytes <= 1 * 1_024 * 1_024 else {
                throw SecureSubprocessError.invalidRequest(.argumentDataTooLarge)
            }
        }

        guard request.environment.count <= 512,
              request.environment["PATH"] == SecureSubprocessEnvironment.trustedSystemPath else {
            throw SecureSubprocessError.invalidRequest(.unsafeEnvironment)
        }
        let forbiddenEnvironmentNames: Set<String> = [
            "BASH_ENV", "CDPATH", "ENV", "GIT_EXEC_PATH", "NODE_OPTIONS", "PERL5LIB",
            "PYTHONHOME", "PYTHONPATH", "RUBYLIB", "SHELLOPTS", "SWIFT_EXEC", "ZDOTDIR"
        ]
        var environmentBytes = 0
        for (name, value) in request.environment {
            guard isValidEnvironmentName(name), !value.contains("\0") else {
                throw SecureSubprocessError.invalidRequest(.invalidEnvironment)
            }
            let uppercased = name.uppercased()
            guard !uppercased.hasPrefix("DYLD_"),
                  !uppercased.hasPrefix("LD_"),
                  !forbiddenEnvironmentNames.contains(uppercased) else {
                throw SecureSubprocessError.invalidRequest(.unsafeEnvironment)
            }
            if uppercased == "HOME", !SecureExecutableResolver.isValidAbsolutePath(value) {
                throw SecureSubprocessError.invalidRequest(.unsafeEnvironment)
            }
            environmentBytes += name.utf8.count + value.utf8.count + 2
            guard environmentBytes <= 256 * 1_024 else {
                throw SecureSubprocessError.invalidRequest(.environmentDataTooLarge)
            }
        }
    }

    private func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.utf8.first,
              first == 95 || isASCIIAlpha(first) else {
            return false
        }
        return name.utf8.dropFirst().allSatisfy { byte in
            byte == 95 || isASCIIAlpha(byte) || (48...57).contains(byte)
        }
    }

    private func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private func preLaunchCancellationResult() -> SecureSubprocessResult {
        SecureSubprocessResult(
            exitStatus: -1,
            terminationSignal: nil,
            standardOutput: Data(),
            standardError: Data(),
            durationMilliseconds: 0,
            standardOutputTruncated: false,
            standardErrorTruncated: false
        )
    }

    private func drain(
        pipe: inout DescriptorPipe,
        into destination: inout BoundedSubprocessData
    ) -> Int32? {
        guard pipe.readDescriptor >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        for _ in 0..<64 {
            let count = Darwin.read(pipe.readDescriptor, &buffer, buffer.count)
            if count > 0 {
                destination.consume(buffer, count: count)
                continue
            }
            if count == 0 {
                pipe.closeRead()
                return nil
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
            let code = errno
            pipe.closeRead()
            return code
        }
        return nil
    }

    private func writeInput(
        _ input: Data?,
        offset: inout Int,
        pipe: inout DescriptorPipe?
    ) -> Int32? {
        guard let input, var currentPipe = pipe, currentPipe.writeDescriptor >= 0 else { return nil }
        if offset >= input.count {
            currentPipe.closeWrite()
            pipe = currentPipe
            return nil
        }
        let result: Int = input.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return Darwin.write(
                currentPipe.writeDescriptor,
                baseAddress.advanced(by: offset),
                input.count - offset
            )
        }
        if result > 0 {
            offset += result
            if offset == input.count { currentPipe.closeWrite() }
            pipe = currentPipe
            return nil
        }
        if result < 0, errno == EINTR { return nil }
        if result < 0, errno == EAGAIN || errno == EWOULDBLOCK { return nil }
        let code = result < 0 ? errno : EIO
        currentPipe.closeWrite()
        pipe = currentPipe
        return code
    }

    private func makeResult(
        leaderStatus: Int32?,
        output: BoundedSubprocessData,
        errors: BoundedSubprocessData,
        started: UInt64
    ) -> SecureSubprocessResult {
        let decoded = decodeWaitStatus(leaderStatus)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        return SecureSubprocessResult(
            exitStatus: decoded.exitStatus,
            terminationSignal: decoded.signal,
            standardOutput: output.data,
            standardError: errors.data,
            durationMilliseconds: Int(clamping: elapsed / 1_000_000),
            standardOutputTruncated: output.overflowed,
            standardErrorTruncated: errors.overflowed
        )
    }

    private func decodeWaitStatus(_ rawStatus: Int32?) -> (exitStatus: Int32, signal: Int32?) {
        guard let rawStatus, rawStatus >= 0 else { return (-1, nil) }
        let lowBits = rawStatus & 0x7f
        if lowBits == 0 {
            return ((rawStatus >> 8) & 0xff, nil)
        }
        if lowBits == 0x7f {
            return (-1, nil)
        }
        return (128 + lowBits, lowBits)
    }

    private func requireSpawnSuccess(_ code: Int32) throws {
        guard code == 0 else { throw SecureSubprocessError.spawnSetupFailed(code) }
    }

    private func setNonBlocking(_ descriptor: Int32) throws {
        guard descriptor >= 0 else { return }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SecureSubprocessError.spawnSetupFailed(errno)
        }
    }

    private func processGroupExists(_ processID: pid_t) -> Bool {
        if kill(-processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private func signalOwnedProcessGroup(
        _ processID: pid_t,
        signal: Int32,
        leaderIsUnreaped: Bool
    ) {
        if kill(-processID, signal) != 0, errno == ESRCH, leaderIsUnreaped {
            _ = kill(processID, signal)
        }
    }

    private func terminateSuspendedProcess(_ processID: pid_t) {
        signalOwnedProcessGroup(processID, signal: SIGKILL, leaderIsUnreaped: true)
        reap(processID)
    }

    private func terminateRunningProcess(_ processID: pid_t) {
        signalOwnedProcessGroup(processID, signal: SIGTERM, leaderIsUnreaped: true)
        usleep(50_000)
        signalOwnedProcessGroup(processID, signal: SIGKILL, leaderIsUnreaped: true)
        reap(processID)
    }

    private func observeLeaderExit(_ processID: pid_t) -> LeaderExitObservation {
        while true {
            var information = siginfo_t()
            let result = waitid(
                P_PID,
                id_t(processID),
                &information,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result == 0 {
                return information.si_pid == processID ? .exited : .running
            }
            if errno == EINTR { continue }
            return .failed(errno)
        }
    }

    private func reapExitedLeader(_ processID: pid_t) throws -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(processID, &status, 0)
            if result == processID { return status }
            if result < 0, errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
        }
    }

    private func scheduleReap(_ processID: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0, errno == EINTR {}
        }
    }

    private func reap(_ processID: pid_t) {
        var status: Int32 = 0
        while waitpid(processID, &status, 0) < 0, errno == EINTR {}
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
}

private enum SubprocessTerminationCause {
    case timedOut
    case cancelled
    case outputLimitExceeded
    case inputWriteFailed(Int32)
    case outputReadFailed(Int32)
    case waitFailed(Int32)
    case descendantProcessDetected
}

private enum LeaderExitObservation {
    case running
    case exited
    case failed(Int32)
}

private struct BoundedSubprocessData {
    let maximumBytes: Int
    private(set) var data = Data()
    private(set) var overflowed = false

    mutating func consume(_ bytes: [UInt8], count: Int) {
        let remaining = max(0, maximumBytes - data.count)
        if remaining > 0 {
            data.append(contentsOf: bytes.prefix(min(remaining, count)))
        }
        if count > remaining { overflowed = true }
    }
}

private struct DescriptorPipe {
    var readDescriptor: Int32
    var writeDescriptor: Int32

    mutating func closeRead() {
        guard readDescriptor >= 0 else { return }
        close(readDescriptor)
        readDescriptor = -1
    }

    mutating func closeWrite() {
        guard writeDescriptor >= 0 else { return }
        close(writeDescriptor)
        writeDescriptor = -1
    }

    mutating func closeBoth() {
        closeRead()
        closeWrite()
    }
}

private func makePipe() throws -> DescriptorPipe {
    var descriptors = [Int32](repeating: -1, count: 2)
    let result = descriptors.withUnsafeMutableBufferPointer { buffer in
        Darwin.pipe(buffer.baseAddress!)
    }
    guard result == 0 else {
        throw SecureSubprocessError.spawnSetupFailed(errno)
    }
    do {
        descriptors[0] = try promoteDescriptor(descriptors[0])
        descriptors[1] = try promoteDescriptor(descriptors[1])
        for descriptor in descriptors {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw SecureSubprocessError.spawnSetupFailed(errno)
            }
        }
        return DescriptorPipe(readDescriptor: descriptors[0], writeDescriptor: descriptors[1])
    } catch {
        for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
        throw error
    }
}

private func promoteDescriptor(_ descriptor: Int32) throws -> Int32 {
    guard descriptor <= STDERR_FILENO else { return descriptor }
    let promoted = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
    guard promoted >= 0 else {
        throw SecureSubprocessError.spawnSetupFailed(errno)
    }
    close(descriptor)
    return promoted
}
