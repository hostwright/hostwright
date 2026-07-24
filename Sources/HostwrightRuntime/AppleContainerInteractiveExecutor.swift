import Darwin
import Foundation
import HostwrightCore

public struct RuntimeRawStreamChunk: Equatable, Sendable {
    public let stream: RuntimeStreamName
    public let data: Data

    public init(stream: RuntimeStreamName, data: Data) throws {
        guard !data.isEmpty, data.count <= RuntimeStreamEnvelope.maximumChunkBytes else {
            throw RuntimeInteractiveError.invalidStreamFrame
        }
        self.stream = stream
        self.data = data
    }
}

public final class RuntimeInteractiveProcessControl: @unchecked Sendable {
    public static let maximumQueuedInputBytes = 1 * 1_024 * 1_024
    public static let maximumPendingSignals = 64

    private let lock = NSLock()
    private var input = Data()
    private var inputFinished = false
    private var cancelled = false
    private var resize: (columns: UInt16, rows: UInt16)?
    private var signals: [Int32] = []

    public init() {}

    @discardableResult
    public func sendInput(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= RuntimeStreamEnvelope.maximumChunkBytes else {
            return false
        }
        return lock.withLock {
            guard !inputFinished,
                  !cancelled,
                  input.count + data.count <= Self.maximumQueuedInputBytes else {
                return false
            }
            input.append(data)
            return true
        }
    }

    public func finishInput() {
        lock.withLock { inputFinished = true }
    }

    @discardableResult
    public func resizeTTY(columns: UInt16, rows: UInt16) -> Bool {
        guard columns > 0, rows > 0, columns <= 1_000, rows <= 1_000 else {
            return false
        }
        lock.withLock { resize = (columns, rows) }
        return true
    }

    @discardableResult
    public func forward(signal: Int32) -> Bool {
        guard Self.allowedSignals.contains(signal) else { return false }
        return lock.withLock {
            guard signals.count < Self.maximumPendingSignals else { return false }
            signals.append(signal)
            return true
        }
    }

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    internal func inputPrefix(maximumBytes: Int) -> Data {
        lock.withLock {
            Data(input.prefix(maximumBytes))
        }
    }

    internal func consumeInput(_ count: Int) {
        lock.withLock {
            input.removeFirst(min(count, input.count))
        }
    }

    internal var shouldCloseInput: Bool {
        lock.withLock { inputFinished && input.isEmpty }
    }

    internal func takeResize() -> (columns: UInt16, rows: UInt16)? {
        lock.withLock {
            defer { resize = nil }
            return resize
        }
    }

    internal func takeSignals() -> [Int32] {
        lock.withLock {
            defer { signals.removeAll(keepingCapacity: true) }
            return signals
        }
    }

    internal static let allowedSignals: Set<Int32> = [
        SIGHUP,
        SIGINT,
        SIGQUIT,
        SIGTERM,
        SIGWINCH
    ]
}

public struct RuntimeInteractiveProcessRequest: Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
    public let workingDirectoryDescriptor: Int32?
    public let inheritedDescriptors: [RuntimeInteractiveDescriptorBinding]
    public let interactive: Bool
    public let tty: Bool
    public let timeoutMilliseconds: Int
    public let onLaunch: (@Sendable (pid_t) -> Void)?

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = SecureSubprocessEnvironment.currentUser,
        workingDirectory: String = "/",
        workingDirectoryDescriptor: Int32? = nil,
        inheritedDescriptors: [RuntimeInteractiveDescriptorBinding] = [],
        interactive: Bool,
        tty: Bool,
        timeoutMilliseconds: Int,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.workingDirectoryDescriptor = workingDirectoryDescriptor
        self.inheritedDescriptors = inheritedDescriptors
        self.interactive = interactive
        self.tty = tty
        self.timeoutMilliseconds = timeoutMilliseconds
        self.onLaunch = onLaunch
    }
}

public struct RuntimeInteractiveProcessResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let terminationSignal: Int32?
    public let standardErrorTail: String

    public init(exitStatus: Int32, terminationSignal: Int32?, standardErrorTail: String) {
        self.exitStatus = exitStatus
        self.terminationSignal = terminationSignal
        self.standardErrorTail = standardErrorTail
    }
}

public protocol RuntimeInteractiveProcessRunning: Sendable {
    func run(
        _ request: RuntimeInteractiveProcessRequest,
        control: RuntimeInteractiveProcessControl,
        sink: @escaping @Sendable (RuntimeRawStreamChunk) throws -> Void
    ) async throws -> RuntimeInteractiveProcessResult
}

public struct POSIXRuntimeInteractiveProcessRunner: RuntimeInteractiveProcessRunning {
    public init() {}

    public func run(
        _ request: RuntimeInteractiveProcessRequest,
        control: RuntimeInteractiveProcessControl,
        sink: @escaping @Sendable (RuntimeRawStreamChunk) throws -> Void
    ) async throws -> RuntimeInteractiveProcessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(
                            returning: try runBlocking(
                                request,
                                control: control,
                                sink: sink
                            )
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            control.cancel()
        }
    }

    private func runBlocking(
        _ request: RuntimeInteractiveProcessRequest,
        control: RuntimeInteractiveProcessControl,
        sink: @escaping @Sendable (RuntimeRawStreamChunk) throws -> Void
    ) throws -> RuntimeInteractiveProcessResult {
        guard (1...86_400_000).contains(request.timeoutMilliseconds),
              request.arguments.count <= 4_096,
              request.arguments.allSatisfy({ !$0.contains("\0") }),
              request.arguments.reduce(0, { $0 + $1.utf8.count + 1 }) <= 1 * 1_024 * 1_024,
              Self.validEnvironment(request.environment) else {
            throw RuntimeInteractiveError.invalidProcessArguments
        }

        let executable: SecureExecutableIdentity
        let workingDirectory: String?
        do {
            executable = try SecureExecutableResolver.verify(path: request.executablePath)
            if let descriptor = request.workingDirectoryDescriptor {
                var metadata = stat()
                guard descriptor > STDERR_FILENO,
                      fstat(descriptor, &metadata) == 0,
                      (metadata.st_mode & S_IFMT) == S_IFDIR else {
                    throw RuntimeInteractiveError.invalidProcessArguments
                }
                workingDirectory = nil
            } else {
                workingDirectory = try SecureExecutableResolver.verifyWorkingDirectory(
                    path: request.workingDirectory
                )
            }
            let targetDescriptors = request.inheritedDescriptors.map(\.targetDescriptor)
            guard Set(targetDescriptors).count == targetDescriptors.count,
                  request.inheritedDescriptors.allSatisfy({
                      $0.sourceDescriptor > STDERR_FILENO &&
                          $0.targetDescriptor > STDERR_FILENO &&
                          $0.targetDescriptor <= 1_024 &&
                          fcntl($0.sourceDescriptor, F_GETFD) >= 0
                  }) else {
                throw RuntimeInteractiveError.invalidProcessArguments
            }
        } catch {
            throw RuntimeInteractiveError.invalidProcessArguments
        }

        var inputPipe = try DescriptorPair.make()
        var outputPipe: DescriptorPair?
        var errorPipe: DescriptorPair?
        var terminal: PseudoTerminal?
        if request.tty {
            terminal = try PseudoTerminal.make()
        } else {
            outputPipe = try DescriptorPair.make()
            errorPipe = try DescriptorPair.make()
        }
        defer {
            inputPipe.closeBoth()
            outputPipe?.closeBoth()
            errorPipe?.closeBoth()
            terminal?.closeBoth()
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw RuntimeInteractiveError.processLaunchFailed(errno)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let standardInputDescriptor = request.tty ? terminal!.slave : inputPipe.read
        let standardOutputDescriptor = request.tty ? terminal!.slave : outputPipe!.write
        let standardErrorDescriptor = request.tty ? terminal!.slave : errorPipe!.write
        guard posix_spawn_file_actions_adddup2(
                  &actions,
                  standardInputDescriptor,
                  STDIN_FILENO
              ) == 0,
              posix_spawn_file_actions_adddup2(
                  &actions,
                  standardOutputDescriptor,
                  STDOUT_FILENO
              ) == 0,
              posix_spawn_file_actions_adddup2(
                  &actions,
                  standardErrorDescriptor,
                  STDERR_FILENO
              ) == 0 else {
            throw RuntimeInteractiveError.processLaunchFailed(errno)
        }
        for binding in request.inheritedDescriptors {
            guard posix_spawn_file_actions_adddup2(
                &actions,
                binding.sourceDescriptor,
                binding.targetDescriptor
            ) == 0 else {
                throw RuntimeInteractiveError.processLaunchFailed(errno)
            }
        }
        if let descriptor = request.workingDirectoryDescriptor {
            guard posix_spawn_file_actions_addfchdir(&actions, descriptor) == 0 else {
                throw RuntimeInteractiveError.processLaunchFailed(errno)
            }
        } else if let workingDirectory {
            guard posix_spawn_file_actions_addchdir(&actions, workingDirectory) == 0 else {
                throw RuntimeInteractiveError.processLaunchFailed(errno)
            }
        }

        for descriptor in Set([
            inputPipe.read,
            inputPipe.write,
            outputPipe?.read ?? -1,
            outputPipe?.write ?? -1,
            errorPipe?.read ?? -1,
            errorPipe?.write ?? -1,
            terminal?.master ?? -1,
            terminal?.slave ?? -1
        ]) where descriptor > STDERR_FILENO {
            guard posix_spawn_file_actions_addclose(&actions, descriptor) == 0 else {
                throw RuntimeInteractiveError.processLaunchFailed(errno)
            }
        }

        let flags = Int16(
            POSIX_SPAWN_SETPGROUP |
                POSIX_SPAWN_START_SUSPENDED |
                POSIX_SPAWN_CLOEXEC_DEFAULT
        )
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw RuntimeInteractiveError.processLaunchFailed(errno)
        }

        let arguments = [executable.path] + request.arguments
        var argumentPointers = arguments.map { strdup($0) }
        var environmentPointers = request.environment
            .sorted(by: { $0.key < $1.key })
            .map { strdup("\($0.key)=\($0.value)") }
        argumentPointers.append(nil)
        environmentPointers.append(nil)
        defer {
            argumentPointers.compactMap { $0 }.forEach { free($0) }
            environmentPointers.compactMap { $0 }.forEach { free($0) }
        }

        var processID: pid_t = 0
        let spawnResult = posix_spawn(
            &processID,
            executable.path,
            &actions,
            &attributes,
            &argumentPointers,
            &environmentPointers
        )
        guard spawnResult == 0 else {
            throw RuntimeInteractiveError.processLaunchFailed(spawnResult)
        }
        do {
            try SecureExecutableResolver.verifyUnchanged(executable)
        } catch {
            terminate(processID)
            throw RuntimeInteractiveError.processLaunchFailed(ESTALE)
        }
        guard kill(processID, SIGCONT) == 0 else {
            terminate(processID)
            throw RuntimeInteractiveError.processLaunchFailed(errno)
        }

        request.onLaunch?(processID)
        inputPipe.closeRead()
        if request.tty {
            inputPipe.closeWrite()
            terminal?.closeSlave()
            try terminal?.setNonBlockingMaster()
        } else {
            outputPipe?.closeWrite()
            errorPipe?.closeWrite()
            try outputPipe?.setNonBlockingRead()
            try errorPipe?.setNonBlockingRead()
        }
        try inputPipe.setNonBlockingWrite()
        if !request.interactive && !request.tty {
            inputPipe.closeWrite()
        }

        return try monitor(
            processID: processID,
            request: request,
            control: control,
            inputPipe: &inputPipe,
            outputPipe: &outputPipe,
            errorPipe: &errorPipe,
            terminal: &terminal,
            sink: sink
        )
    }

    private func monitor(
        processID: pid_t,
        request: RuntimeInteractiveProcessRequest,
        control: RuntimeInteractiveProcessControl,
        inputPipe: inout DescriptorPair,
        outputPipe: inout DescriptorPair?,
        errorPipe: inout DescriptorPair?,
        terminal: inout PseudoTerminal?,
        sink: @escaping @Sendable (RuntimeRawStreamChunk) throws -> Void
    ) throws -> RuntimeInteractiveProcessResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started + UInt64(request.timeoutMilliseconds) * 1_000_000
        var leaderStatus: Int32?
        var terminationStarted: UInt64?
        var standardErrorTail = Data()
        var ignoredTail = Data()
        var terminalOpen = request.tty
        var outputOpen = !request.tty
        var errorOpen = !request.tty
        var failure: RuntimeInteractiveError?
        var terminalInputFinished = false

        while true {
            do {
                if request.tty, terminalOpen, let master = terminal?.master {
                    terminalOpen = try drain(
                        descriptor: master,
                        stream: .standardOutput,
                        tail: &ignoredTail,
                        captureTail: false,
                        sink: sink
                    )
                } else {
                    if outputOpen, let descriptor = outputPipe?.read {
                        outputOpen = try drain(
                            descriptor: descriptor,
                            stream: .standardOutput,
                            tail: &ignoredTail,
                            captureTail: false,
                            sink: sink
                        )
                    }
                    if errorOpen, let descriptor = errorPipe?.read {
                        errorOpen = try drain(
                            descriptor: descriptor,
                            stream: .standardError,
                            tail: &standardErrorTail,
                            captureTail: true,
                            sink: sink
                        )
                    }
                }
            } catch let error as RuntimeInteractiveError {
                failure = error
            } catch {
                failure = .processIOFailed(EIO)
            }

            if let resize = control.takeResize() {
                if request.tty {
                    terminal?.resize(columns: resize.columns, rows: resize.rows)
                } else if failure == nil {
                    failure = .invalidProcessArguments
                }
            }
            for signal in control.takeSignals() {
                signalGroup(processID, signal: signal)
            }

            if request.interactive || request.tty {
                do {
                    try writePendingInput(
                        control: control,
                        descriptor: request.tty ? terminal?.master : inputPipe.write
                    )
                    if control.shouldCloseInput {
                        if request.tty, !terminalInputFinished {
                            let endOfTransmission = Data([0x04])
                            let written = endOfTransmission.withUnsafeBytes { bytes in
                                Darwin.write(
                                    terminal?.master ?? -1,
                                    bytes.baseAddress,
                                    endOfTransmission.count
                                )
                            }
                            if written == endOfTransmission.count {
                                terminalInputFinished = true
                            } else if written < 0,
                                      errno != EINTR,
                                      errno != EAGAIN,
                                      errno != EWOULDBLOCK {
                                throw RuntimeInteractiveError.processIOFailed(errno)
                            }
                        } else {
                            inputPipe.closeWrite()
                        }
                    }
                } catch let error as RuntimeInteractiveError {
                    failure = error
                } catch {
                    failure = .processIOFailed(EIO)
                }
            }

            let now = DispatchTime.now().uptimeNanoseconds
            if control.isCancelled, failure == nil {
                failure = .processCancelled
            } else if now >= deadline, failure == nil {
                failure = .processTimedOut
            }
            if failure != nil, terminationStarted == nil {
                signalGroup(processID, signal: SIGTERM)
                terminationStarted = now
            }
            if let terminationStarted,
               now >= terminationStarted + 1_000_000_000 {
                signalGroup(processID, signal: SIGKILL)
            }

            if leaderStatus == nil {
                var status: Int32 = 0
                let result = waitpid(processID, &status, WNOHANG)
                if result == processID {
                    leaderStatus = status
                } else if result < 0, errno != EINTR {
                    failure = failure ?? .processIOFailed(errno)
                    leaderStatus = -1
                }
            }

            if leaderStatus != nil {
                let streamsClosed = request.tty
                    ? !terminalOpen
                    : !outputOpen && !errorOpen
                if streamsClosed {
                    if processGroupExists(processID) {
                        signalGroup(processID, signal: SIGKILL)
                        if !waitForProcessGroupExit(processID) {
                            throw RuntimeInteractiveError.processTreeCleanupFailed
                        }
                        if failure == nil {
                            failure = .processTreeCleanupFailed
                        }
                    }
                    break
                }
            }
            if let terminationStarted,
               now >= terminationStarted + 3_000_000_000 {
                signalGroup(processID, signal: SIGKILL)
                throw RuntimeInteractiveError.processTreeCleanupFailed
            }
            usleep(5_000)
        }

        if let failure {
            throw failure
        }
        let decoded = decodeWaitStatus(leaderStatus)
        let diagnostic = RuntimeRedactionPolicy.default.redact(
            boundedDiagnostic(standardErrorTail)
        )
        guard decoded.exitStatus == 0 else {
            throw RuntimeInteractiveError.processFailed(
                exitStatus: decoded.exitStatus,
                diagnostic: diagnostic
            )
        }
        return RuntimeInteractiveProcessResult(
            exitStatus: decoded.exitStatus,
            terminationSignal: decoded.signal,
            standardErrorTail: diagnostic
        )
    }

    private func drain(
        descriptor: Int32,
        stream: RuntimeStreamName,
        tail: inout Data,
        captureTail: Bool,
        sink: @escaping @Sendable (RuntimeRawStreamChunk) throws -> Void
    ) throws -> Bool {
        var buffer = [UInt8](
            repeating: 0,
            count: RuntimeStreamEnvelope.maximumChunkBytes
        )
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer.prefix(count))
                if captureTail {
                    tail.append(data)
                    if tail.count > RuntimeNormalizedFailure.maximumDiagnosticBytes {
                        tail.removeFirst(
                            tail.count - RuntimeNormalizedFailure.maximumDiagnosticBytes
                        )
                    }
                }
                try sink(RuntimeRawStreamChunk(stream: stream, data: data))
                continue
            }
            if count == 0 {
                return false
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return true }
            if errno == EIO, stream == .standardOutput { return false }
            throw RuntimeInteractiveError.processIOFailed(errno)
        }
        return true
    }

    private func writePendingInput(
        control: RuntimeInteractiveProcessControl,
        descriptor: Int32?
    ) throws {
        guard let descriptor, descriptor >= 0 else { return }
        let pending = control.inputPrefix(
            maximumBytes: RuntimeStreamEnvelope.maximumChunkBytes
        )
        guard !pending.isEmpty else { return }
        let written: Int = pending.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return 0 }
            return Darwin.write(descriptor, address, pending.count)
        }
        if written > 0 {
            control.consumeInput(written)
            return
        }
        if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
            return
        }
        throw RuntimeInteractiveError.processIOFailed(written < 0 ? errno : EIO)
    }

    private func boundedDiagnostic(_ data: Data) -> String {
        guard data.count > RuntimeNormalizedFailure.maximumDiagnosticBytes else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(
            decoding: data.suffix(RuntimeNormalizedFailure.maximumDiagnosticBytes),
            as: UTF8.self
        )
    }

    private func decodeWaitStatus(_ rawStatus: Int32?) -> (exitStatus: Int32, signal: Int32?) {
        guard let rawStatus, rawStatus >= 0 else { return (-1, nil) }
        let lowBits = rawStatus & 0x7f
        if lowBits == 0 {
            return ((rawStatus >> 8) & 0xff, nil)
        }
        return (128 + lowBits, lowBits)
    }

    private func signalGroup(_ processID: pid_t, signal: Int32) {
        if kill(-processID, signal) != 0, errno == ESRCH {
            _ = kill(processID, signal)
        }
    }

    private func terminate(_ processID: pid_t) {
        signalGroup(processID, signal: SIGKILL)
        var status: Int32 = 0
        while waitpid(processID, &status, 0) < 0, errno == EINTR {}
    }

    private func processGroupExists(_ processID: pid_t) -> Bool {
        if kill(-processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private func waitForProcessGroupExit(_ processID: pid_t) -> Bool {
        for _ in 0..<200 {
            if !processGroupExists(processID) { return true }
            usleep(5_000)
        }
        return !processGroupExists(processID)
    }

    private static func validEnvironment(_ environment: [String: String]) -> Bool {
        guard environment.count <= 512,
              environment["PATH"] == SecureSubprocessEnvironment.trustedSystemPath else {
            return false
        }
        let forbiddenNames: Set<String> = [
            "BASH_ENV",
            "CDPATH",
            "ENV",
            "GIT_EXEC_PATH",
            "NODE_OPTIONS",
            "PERL5LIB",
            "PYTHONHOME",
            "PYTHONPATH",
            "RUBYLIB",
            "SHELLOPTS",
            "SWIFT_EXEC",
            "ZDOTDIR"
        ]
        var byteCount = 0
        for (name, value) in environment {
            guard let first = name.utf8.first,
                  first == 95 || asciiLetter(first),
                  name.utf8.dropFirst().allSatisfy({
                      $0 == 95 || asciiLetter($0) || (48...57).contains($0)
                  }),
                  !value.contains("\0") else {
                return false
            }
            let uppercased = name.uppercased()
            guard !uppercased.hasPrefix("DYLD_"),
                  !uppercased.hasPrefix("LD_"),
                  !forbiddenNames.contains(uppercased) else {
                return false
            }
            byteCount += name.utf8.count + value.utf8.count + 2
            guard byteCount <= 256 * 1_024 else { return false }
        }
        return true
    }

    private static func asciiLetter(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (97...122).contains(value)
    }
}

public struct AppleContainerInteractiveInvocation: Sendable {
    public let arguments: [String]
    public let interactive: Bool
    public let tty: Bool
    public let confinedPaths: [RuntimeConfinedHostPath]
    public let exportedArchivePath: RuntimeConfinedHostPath?
    public let copiedOutputPath: RuntimeConfinedHostPath?
    public let workingDirectoryDescriptor: Int32?
    public let inheritedDescriptors: [RuntimeInteractiveDescriptorBinding]

    public init(operation: RuntimeInteractiveOperation) throws {
        guard RuntimeManagedResourceIdentity.isCurrentIdentifier(
            operation.resourceIdentifier
        ) else {
            throw RuntimeInteractiveError.invalidResourceIdentifier
        }
        let identifier = operation.resourceIdentifier
        switch operation {
        case .exec(_, let processArguments, let interactive, let tty, let workingDirectory):
            guard !processArguments.isEmpty,
                  processArguments.count <= 1_024,
                  processArguments.allSatisfy({
                      !$0.contains("\0") && $0.utf8.count <= 64 * 1_024
                  }) else {
                throw RuntimeInteractiveError.invalidProcessArguments
            }
            if let workingDirectory {
                try RuntimeContainerPathPolicy.validate(workingDirectory)
            }
            var arguments = ["exec"]
            if interactive { arguments.append("--interactive") }
            if tty { arguments.append("--tty") }
            if let workingDirectory {
                arguments += ["--workdir", workingDirectory]
            }
            arguments.append(identifier)
            arguments += processArguments
            self.init(
                arguments: arguments,
                interactive: interactive,
                tty: tty,
                confinedPaths: [],
                exportedArchivePath: nil
            )
        case .attach:
            throw RuntimeInteractiveError.capabilityUnavailable(
                operation: .attach,
                reason:
                    "Apple container 1.0/1.1 cannot attach to a running container; start --attach would mutate lifecycle state outside the Hostwright saga."
            )
        case .copyIn(_, let root, let relativePath, let destination):
            try RuntimeContainerPathPolicy.validate(destination)
            let source = try RuntimeConfinedHostPath(
                root: root,
                relativePath: relativePath,
                intent: .readExisting
            )
            self.init(
                arguments: [
                    "copy",
                    source.invocationPath,
                    "\(identifier):\(destination)"
                ],
                interactive: false,
                tty: false,
                confinedPaths: [source],
                exportedArchivePath: nil,
                workingDirectoryDescriptor: source.workingDirectoryDescriptor,
                inheritedDescriptors: source.descriptorBindings
            )
        case .copyOut(_, let source, let root, let relativePath):
            try RuntimeContainerPathPolicy.validate(source)
            let destination = try RuntimeConfinedHostPath(
                root: root,
                relativePath: relativePath,
                intent: .writeDestination
            )
            self.init(
                arguments: ["copy", "\(identifier):\(source)", destination.invocationPath],
                interactive: false,
                tty: false,
                confinedPaths: [destination],
                exportedArchivePath: nil,
                copiedOutputPath: destination,
                workingDirectoryDescriptor: destination.workingDirectoryDescriptor,
                inheritedDescriptors: destination.descriptorBindings
            )
        case .export(_, let root, let relativePath):
            let destination = try RuntimeConfinedHostPath(
                root: root,
                relativePath: relativePath,
                intent: .writeFile
            )
            self.init(
                arguments: [
                    "export",
                    "--output",
                    destination.invocationPath,
                    identifier
                ],
                interactive: false,
                tty: false,
                confinedPaths: [destination],
                exportedArchivePath: destination,
                workingDirectoryDescriptor: destination.workingDirectoryDescriptor,
                inheritedDescriptors: destination.descriptorBindings
            )
        case .inspect:
            self.init(
                arguments: ["inspect", identifier],
                interactive: false,
                tty: false,
                confinedPaths: [],
                exportedArchivePath: nil
            )
        case .stats:
            self.init(
                arguments: ["stats", identifier, "--no-stream", "--format", "json"],
                interactive: false,
                tty: false,
                confinedPaths: [],
                exportedArchivePath: nil
            )
        case .logsFollow(_, let tail):
            self.init(
                arguments: [
                    "logs",
                    "--follow",
                    "-n",
                    String(min(max(0, tail), 10_000)),
                    identifier
                ],
                interactive: false,
                tty: false,
                confinedPaths: [],
                exportedArchivePath: nil
            )
        }
    }

    private init(
        arguments: [String],
        interactive: Bool,
        tty: Bool,
        confinedPaths: [RuntimeConfinedHostPath],
        exportedArchivePath: RuntimeConfinedHostPath?,
        copiedOutputPath: RuntimeConfinedHostPath? = nil,
        workingDirectoryDescriptor: Int32? = nil,
        inheritedDescriptors: [RuntimeInteractiveDescriptorBinding] = []
    ) {
        self.arguments = arguments
        self.interactive = interactive
        self.tty = tty
        self.confinedPaths = confinedPaths
        self.exportedArchivePath = exportedArchivePath
        self.copiedOutputPath = copiedOutputPath
        self.workingDirectoryDescriptor = workingDirectoryDescriptor
        self.inheritedDescriptors = inheritedDescriptors
    }
}

public struct RuntimeInteractiveExecutionResult: Equatable, Sendable {
    public let operation: RuntimeInteractiveOperationKind
    public let exitStatus: Int32
    public let emittedFrameCount: Int
    public let standardErrorTail: String

    public init(
        operation: RuntimeInteractiveOperationKind,
        exitStatus: Int32,
        emittedFrameCount: Int,
        standardErrorTail: String
    ) {
        self.operation = operation
        self.exitStatus = exitStatus
        self.emittedFrameCount = emittedFrameCount
        self.standardErrorTail = standardErrorTail
    }
}

protocol AppleContainerInteractiveStructuredReading: Sendable {
    func inventory() async throws -> RuntimeInventory
    func resourceUsage(
        for resourceIdentifier: String
    ) async throws -> RuntimeResourceUsageSnapshot
}

extension AppleContainerReadOnlyAdapter:
    AppleContainerInteractiveStructuredReading {}

public struct AppleContainerInteractiveExecutor: Sendable {
    public let executableResolver: RuntimeExecutableResolving
    public let processRunner: RuntimeInteractiveProcessRunning
    private let structuredReader:
        (any AppleContainerInteractiveStructuredReading)?

    public init(
        executableResolver: RuntimeExecutableResolving = RuntimeExecutableResolver(),
        processRunner: RuntimeInteractiveProcessRunning = POSIXRuntimeInteractiveProcessRunner()
    ) {
        self.executableResolver = executableResolver
        self.processRunner = processRunner
        structuredReader = nil
    }

    init(
        executableResolver: RuntimeExecutableResolving,
        processRunner: RuntimeInteractiveProcessRunning,
        structuredReader: any AppleContainerInteractiveStructuredReading
    ) {
        self.executableResolver = executableResolver
        self.processRunner = processRunner
        self.structuredReader = structuredReader
    }

    public func execute(
        _ operation: RuntimeInteractiveOperation,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        timeoutMilliseconds: Int,
        control: RuntimeInteractiveProcessControl = RuntimeInteractiveProcessControl(),
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) async throws -> RuntimeInteractiveExecutionResult {
        guard capabilitySnapshot.descriptor.providerID == .appleContainerCLI else {
            throw RuntimeInteractiveError.capabilityUnavailable(
                operation: operation.kind,
                reason: "The Apple container CLI executor cannot operate the selected provider."
            )
        }
        try RuntimeInteractiveCapabilityContract(snapshot: capabilitySnapshot)
            .require(operation.kind)
        guard RuntimeManagedResourceIdentity.isCurrentIdentifier(
            operation.resourceIdentifier
        ) else {
            throw RuntimeInteractiveError.invalidResourceIdentifier
        }
        guard (1...86_400_000).contains(timeoutMilliseconds) else {
            throw RuntimeInteractiveError.invalidProcessArguments
        }
        if operation.kind == .inspect || operation.kind == .stats {
            return try await executeStructuredRead(
                operation,
                capabilitySnapshot: capabilitySnapshot,
                control: control,
                sink: sink
            )
        }
        let invocation = try AppleContainerInteractiveInvocation(operation: operation)
        guard let executable = try executableResolver.resolveExecutable(
            named: AppleContainerCommand.executableName
        ) else {
            throw RuntimeInteractiveError.capabilityUnavailable(
                operation: operation.kind,
                reason: "Apple container CLI is unavailable."
            )
        }

        let sequence = StreamSequence()
        let hasStructuredOutput = operation.kind == .inspect || operation.kind == .stats
        let structuredOutput = LockedDataAccumulator(
            enabled: hasStructuredOutput,
            operation: operation
        )
        let delivery = RuntimeStreamDelivery(control: control, sink: sink)
        delivery.start()
        do {
            let result = try await processRunner.run(
                RuntimeInteractiveProcessRequest(
                    executablePath: executable.path,
                    arguments: invocation.arguments,
                    workingDirectoryDescriptor: invocation.workingDirectoryDescriptor,
                    inheritedDescriptors: invocation.inheritedDescriptors,
                    interactive: invocation.interactive,
                    tty: invocation.tty,
                    timeoutMilliseconds: timeoutMilliseconds
                ),
                control: control
            ) { chunk in
                structuredOutput.append(chunk)
                if !hasStructuredOutput || chunk.stream != .standardOutput {
                    let envelopeCount = RuntimeStreamEnvelope.chunkCount(for: chunk.data)
                    for envelope in try RuntimeStreamEnvelope.chunks(
                        chunk.data,
                        stream: chunk.stream,
                        startingAt: sequence.reserve(count: envelopeCount)
                    ) {
                        try delivery.enqueue(envelope)
                    }
                }
            }

            if let archive = invocation.exportedArchivePath {
                try archive.validateArchiveOutput()
                try archive.finalizeOutput()
            }
            if let copiedOutput = invocation.copiedOutputPath {
                try copiedOutput.validateCopyOutput()
                try copiedOutput.finalizeOutput()
            }
            if hasStructuredOutput {
                let redactedJSON = try structuredOutput.canonicalRedactedJSON()
                let envelopeCount = RuntimeStreamEnvelope.chunkCount(for: redactedJSON)
                for envelope in try RuntimeStreamEnvelope.chunks(
                    redactedJSON,
                    stream: .standardOutput,
                    startingAt: sequence.reserve(count: envelopeCount)
                ) {
                    try delivery.enqueue(envelope)
                }
            }

            try delivery.enqueue(
                RuntimeStreamEnvelope(
                    sequence: sequence.reserve(count: 1),
                    stream: .standardOutput,
                    payload: Data(),
                    endOfStream: true
                )
            )
            if !invocation.tty {
                try delivery.enqueue(
                    RuntimeStreamEnvelope(
                        sequence: sequence.reserve(count: 1),
                        stream: .standardError,
                        payload: Data(),
                        endOfStream: true
                    )
                )
            }
            try delivery.finish()

            return RuntimeInteractiveExecutionResult(
                operation: operation.kind,
                exitStatus: result.exitStatus,
                emittedFrameCount: sequence.value,
                standardErrorTail: result.standardErrorTail
            )
        } catch {
            delivery.abort()
            throw error
        }
    }

    private func executeStructuredRead(
        _ operation: RuntimeInteractiveOperation,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        control: RuntimeInteractiveProcessControl,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) async throws -> RuntimeInteractiveExecutionResult {
        guard !control.isCancelled else {
            throw RuntimeInteractiveError.processCancelled
        }
        let reader: any AppleContainerInteractiveStructuredReading
        if let structuredReader {
            reader = structuredReader
        } else {
            reader = AppleContainerReadOnlyAdapter(
                executableResolver: executableResolver
            )
        }

        let data: Data
        do {
            switch operation {
            case .inspect(let resourceIdentifier):
                let inventory = try await reader.inventory()
                let matches = inventory.containers.filter {
                    $0.runtimeID == resourceIdentifier ||
                        $0.name == resourceIdentifier
                }
                guard matches.count == 1,
                      let container = matches.first,
                      container.runtimeID == resourceIdentifier,
                      container.name == resourceIdentifier,
                      container.ownership?.providerID == .appleContainerCLI else {
                    throw RuntimeInteractiveError.invalidStructuredOutput
                }
                data = try Self.canonicalStructuredJSON(
                    RuntimeInteractiveInspectOutput(
                        providerID: .appleContainerCLI,
                        capabilitySHA256: capabilitySnapshot.canonicalSHA256,
                        inventorySHA256: inventory.semanticSHA256,
                        container: container
                    )
                )

            case .stats(let resourceIdentifier):
                let usage = try await reader.resourceUsage(
                    for: resourceIdentifier
                )
                guard usage.resourceIdentifier == resourceIdentifier else {
                    throw RuntimeInteractiveError.invalidStructuredOutput
                }
                data = try Self.canonicalStructuredJSON(
                    RuntimeInteractiveStatsOutput(
                        providerID: .appleContainerCLI,
                        capabilitySHA256: capabilitySnapshot.canonicalSHA256,
                        usage: usage
                    )
                )

            default:
                throw RuntimeInteractiveError.invalidStructuredOutput
            }
        } catch is CancellationError {
            throw RuntimeInteractiveError.processCancelled
        } catch let error as RuntimeInteractiveError {
            throw error
        } catch let error as RuntimeAdapterError {
            throw Self.structuredReadError(error, operation: operation.kind)
        } catch {
            throw RuntimeInteractiveError.invalidStructuredOutput
        }
        guard !control.isCancelled else {
            throw RuntimeInteractiveError.processCancelled
        }

        let sequence = StreamSequence()
        let delivery = RuntimeStreamDelivery(control: control, sink: sink)
        delivery.start()
        do {
            let envelopeCount = RuntimeStreamEnvelope.chunkCount(for: data)
            for envelope in try RuntimeStreamEnvelope.chunks(
                data,
                stream: .standardOutput,
                startingAt: sequence.reserve(count: envelopeCount)
            ) {
                try delivery.enqueue(envelope)
            }
            try delivery.enqueue(
                RuntimeStreamEnvelope(
                    sequence: sequence.reserve(count: 1),
                    stream: .standardOutput,
                    payload: Data(),
                    endOfStream: true
                )
            )
            try delivery.enqueue(
                RuntimeStreamEnvelope(
                    sequence: sequence.reserve(count: 1),
                    stream: .standardError,
                    payload: Data(),
                    endOfStream: true
                )
            )
            try delivery.finish()
            return RuntimeInteractiveExecutionResult(
                operation: operation.kind,
                exitStatus: 0,
                emittedFrameCount: sequence.value,
                standardErrorTail: ""
            )
        } catch {
            delivery.abort()
            throw error
        }
    }

    private static func canonicalStructuredJSON<Output: Encodable>(
        _ output: Output
    ) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(output)
            guard data.count <= RuntimeStreamEnvelope.maximumFrameBytes else {
                throw RuntimeInteractiveError.invalidStructuredOutput
            }
            return data
        } catch let error as RuntimeInteractiveError {
            throw error
        } catch {
            throw RuntimeInteractiveError.invalidStructuredOutput
        }
    }

    private static func structuredReadError(
        _ error: RuntimeAdapterError,
        operation: RuntimeInteractiveOperationKind
    ) -> RuntimeInteractiveError {
        switch error {
        case .runtimeUnavailable, .executableNotFound, .unsupportedRuntime,
             .capabilityUnavailable:
            return .capabilityUnavailable(
                operation: operation,
                reason: "Apple container structured observation is unavailable."
            )
        case .commandTimedOut:
            return .processTimedOut
        case .commandCancelled:
            return .processCancelled
        case .commandOutputLimitExceeded:
            return .streamFrameTooLarge
        case .commandProcessTreeViolation:
            return .processTreeCleanupFailed
        default:
            return .invalidStructuredOutput
        }
    }
}

private final class RuntimeStreamDelivery: @unchecked Sendable {
    private let queue = RuntimeStreamBackpressureQueue()
    private let control: RuntimeInteractiveProcessControl
    private let sink: @Sendable (RuntimeStreamEnvelope) throws -> Void
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var consumerError: Error?
    private var started = false

    init(
        control: RuntimeInteractiveProcessControl,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) {
        self.control = control
        self.sink = sink
    }

    func start() {
        let shouldStart = lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }
            do {
                while let envelope = try queue.dequeue() {
                    try sink(envelope)
                }
            } catch {
                lock.withLock { consumerError = error }
                control.cancel()
                queue.cancel()
            }
        }
    }

    func enqueue(_ envelope: RuntimeStreamEnvelope) throws {
        if let error = lock.withLock({ consumerError }) {
            throw error
        }
        try queue.enqueueWithoutWaiting(envelope)
    }

    func finish() throws {
        queue.close()
        group.wait()
        if let error = lock.withLock({ consumerError }) {
            throw error
        }
    }

    func abort() {
        control.cancel()
        queue.cancel()
        group.wait()
    }
}

private final class StreamSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt64 = 0

    func reserve(count: Int) -> UInt64 {
        lock.withLock {
            defer { next += UInt64(count) }
            return next
        }
    }

    var value: Int {
        lock.withLock { Int(next) }
    }
}

private final class LockedDataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let enabled: Bool
    private let operation: RuntimeInteractiveOperation
    private var data = Data()
    private var overflowed = false

    init(enabled: Bool, operation: RuntimeInteractiveOperation) {
        self.enabled = enabled
        self.operation = operation
    }

    func append(_ chunk: RuntimeRawStreamChunk) {
        guard enabled, chunk.stream == .standardOutput else { return }
        lock.withLock {
            guard !overflowed else { return }
            if data.count + chunk.data.count > RuntimeStreamEnvelope.maximumFrameBytes {
                data.removeAll()
                overflowed = true
                return
            }
            data.append(chunk.data)
        }
    }

    func canonicalRedactedJSON(
        using redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> Data {
        let snapshot = lock.withLock { (data, overflowed) }
        guard !snapshot.1, !snapshot.0.isEmpty else {
            throw RuntimeInteractiveError.invalidStructuredOutput
        }
        do {
            let value = try AppleContainerInteractiveStructuredOutput.validate(
                snapshot.0,
                operation: operation
            )
            return try JSONSerialization.data(
                withJSONObject: redactJSON(value, using: redactionPolicy),
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch let error as RuntimeInteractiveError {
            throw error
        } catch {
            throw RuntimeInteractiveError.invalidStructuredOutput
        }
    }

    private func redactJSON(
        _ value: Any,
        key: String? = nil,
        using redactionPolicy: RuntimeRedactionPolicy
    ) -> Any {
        if let key, redactionPolicy.isSensitiveKey(key) {
            return redactionPolicy.replacement
        }
        if let object = value as? [String: Any] {
            return Dictionary(
                uniqueKeysWithValues: object.map { field, nestedValue in
                    (
                        field,
                        redactJSON(
                            nestedValue,
                            key: field,
                            using: redactionPolicy
                        )
                    )
                }
            )
        }
        if let array = value as? [Any] {
            return array.map {
                redactJSON($0, using: redactionPolicy)
            }
        }
        if let string = value as? String {
            return redactionPolicy.redact(string)
        }
        return value
    }
}

private enum AppleContainerInteractiveStructuredOutput {
    static func validate(
        _ data: Data,
        operation: RuntimeInteractiveOperation
    ) throws -> Any {
        guard let output = String(data: data, encoding: .utf8) else {
            throw RuntimeInteractiveError.invalidStructuredOutput
        }
        let validated: Data
        do {
            validated = try AppleContainerStructuredOutput.validatedJSONData(
                output,
                operation: "Apple container \(operation.kind.rawValue)",
                maximumBytes: RuntimeStreamEnvelope.maximumFrameBytes
            )
        } catch {
            throw RuntimeInteractiveError.invalidStructuredOutput
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: validated)
        } catch {
            throw RuntimeInteractiveError.invalidStructuredOutput
        }

        switch operation {
        case .inspect(let resourceIdentifier):
            try validateInspect(value, resourceIdentifier: resourceIdentifier)
        case .stats(let resourceIdentifier):
            try validateStats(value, resourceIdentifier: resourceIdentifier)
        default:
            throw RuntimeInteractiveError.invalidStructuredOutput
        }
        return value
    }

    private static func validateInspect(
        _ value: Any,
        resourceIdentifier: String
    ) throws {
        guard let containers = value as? [Any],
              containers.count == 1,
              let container = containers[0] as? [String: Any],
              container["id"] as? String == resourceIdentifier,
              let configuration = container["configuration"] as? [String: Any],
              configuration["id"] as? String == resourceIdentifier,
              let status = container["status"] as? [String: Any],
              let state = status["state"] as? String,
              ["unknown", "stopped", "running", "stopping"].contains(state) else {
            throw RuntimeInteractiveError.invalidStructuredOutput
        }
    }

    private static func validateStats(
        _ value: Any,
        resourceIdentifier: String
    ) throws {
        guard let snapshots = value as? [Any],
              snapshots.count == 1,
              let snapshot = snapshots[0] as? [String: Any],
              snapshot["id"] as? String == resourceIdentifier else {
            throw RuntimeInteractiveError.invalidStructuredOutput
        }
        let metricKeys = [
            "memoryUsageBytes",
            "memoryLimitBytes",
            "cpuUsageUsec",
            "networkRxBytes",
            "networkTxBytes",
            "blockReadBytes",
            "blockWriteBytes",
            "numProcesses"
        ]
        for key in metricKeys {
            guard let metric = snapshot[key] else { continue }
            guard metric is NSNull || isUnsignedInteger(metric) else {
                throw RuntimeInteractiveError.invalidStructuredOutput
            }
        }
    }

    private static func isUnsignedInteger(_ value: Any) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return false
        }
        let double = number.doubleValue
        return double.isFinite &&
            double >= 0 &&
            double.rounded(.towardZero) == double &&
            double <= Double(UInt64.max)
    }
}

private struct DescriptorPair {
    var read: Int32
    var write: Int32

    static func make() throws -> DescriptorPair {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw RuntimeInteractiveError.processLaunchFailed(errno)
        }
        return DescriptorPair(read: descriptors[0], write: descriptors[1])
    }

    mutating func setNonBlockingRead() throws {
        try setNonBlocking(read)
    }

    mutating func setNonBlockingWrite() throws {
        try setNonBlocking(write)
    }

    mutating func closeRead() {
        if read >= 0 {
            Darwin.close(read)
            read = -1
        }
    }

    mutating func closeWrite() {
        if write >= 0 {
            Darwin.close(write)
            write = -1
        }
    }

    mutating func closeBoth() {
        closeRead()
        closeWrite()
    }

    private func setNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw RuntimeInteractiveError.processLaunchFailed(errno)
        }
    }
}

private struct PseudoTerminal {
    var master: Int32
    var slave: Int32

    static func make() throws -> PseudoTerminal {
        var master: Int32 = -1
        var slave: Int32 = -1
        var window = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &window) == 0 else {
            throw RuntimeInteractiveError.processLaunchFailed(errno)
        }
        return PseudoTerminal(master: master, slave: slave)
    }

    mutating func setNonBlockingMaster() throws {
        let flags = fcntl(master, F_GETFL)
        guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw RuntimeInteractiveError.processLaunchFailed(errno)
        }
    }

    mutating func resize(columns: UInt16, rows: UInt16) {
        var window = winsize(
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(master, TIOCSWINSZ, &window)
    }

    mutating func closeSlave() {
        if slave >= 0 {
            Darwin.close(slave)
            slave = -1
        }
    }

    mutating func closeBoth() {
        if master >= 0 {
            Darwin.close(master)
            master = -1
        }
        closeSlave()
    }
}
