import Darwin
import Foundation

public final class GuestAgentDispatcher: @unchecked Sendable {
    public static let advertisedCapabilities: [GuestAgentCapability] = [
        .podSandboxLifecycle,
        .restartRecovery,
        .cancellation,
        .streamCredit,
        .strictFraming
    ]

    private let machine: PodSandboxLifecycleStateMachine
    private let authenticationBoundary: any GuestAgentAuthenticationBoundary
    private let lock = NSLock()
    private var cancelledRequestIDs: Set<String> = []

    public init(
        machine: PodSandboxLifecycleStateMachine = PodSandboxLifecycleStateMachine(),
        authenticationBoundary: any GuestAgentAuthenticationBoundary
    ) {
        self.machine = machine
        self.authenticationBoundary = authenticationBoundary
    }

    public func dispatch(_ request: GuestAgentEnvelope) -> GuestAgentEnvelope {
        do {
            try request.validate()
        } catch let error as GuestAgentProtocolError {
            return response(for: request, error: errorCode(for: error))
        } catch {
            return response(for: request, error: .malformed)
        }

        do {
            try authenticationBoundary.authorize(request)
        } catch let error as GuestAgentProtocolError {
            return response(for: request, error: errorCode(for: error))
        } catch {
            return response(for: request, error: .unauthenticated)
        }

        if request.credit == 0 {
            return response(for: request, error: .creditExhausted)
        }

        return lock.withLock {
            if request.operation == .cancel {
                if let target = request.cancellationOfRequestID {
                    cancelledRequestIDs.insert(target)
                }
                let state = machine.snapshot(for: request.sandboxID)?.state ?? .absent
                return response(
                    for: request,
                    state: state,
                    result: .cancelled,
                    credit: request.credit - 1
                )
            }

            if cancelledRequestIDs.contains(request.requestID) {
                return response(
                    for: request,
                    error: .cancelled,
                    credit: request.credit - 1
                )
            }

            do {
                let spec: PodSandboxSpec?
                if request.operation == .create {
                    spec = try PodSandboxSpec(
                        id: request.sandboxID,
                        ownerID: request.ownerID,
                        generation: request.generation,
                        cpuCount: request.cpuCount ?? 1,
                        memoryMiB: request.memoryMiB ?? PodSandboxSpec.minimumMemoryMiB
                    )
                } else {
                    spec = nil
                }
                let outcome = try machine.apply(
                    request.operation,
                    id: request.sandboxID,
                    ownerID: request.ownerID,
                    generation: request.generation,
                    requestID: request.requestID,
                    spec: spec
                )
                let result: GuestAgentResult
                if outcome.cleanupPerformed {
                    result = .teardownComplete
                } else if outcome.replayed {
                    result = .replayed
                } else if request.operation == .recover {
                    result = .recovered
                } else {
                    result = .accepted
                }
                return response(
                    for: request,
                    state: outcome.snapshot.state,
                    result: result,
                    credit: request.credit - 1
                )
            } catch let error as PodSandboxLifecycleError {
                return response(
                    for: request,
                    error: errorCode(for: error),
                    credit: request.credit - 1
                )
            } catch {
                return response(
                    for: request,
                    error: .internalFailure,
                    credit: request.credit - 1
                )
            }
        }
    }

    private func response(
        for request: GuestAgentEnvelope,
        state: PodSandboxState? = nil,
        result: GuestAgentResult? = nil,
        error: GuestAgentErrorCode? = nil,
        credit: Int = 0
    ) -> GuestAgentEnvelope {
        (try? GuestAgentEnvelope.response(
            for: request,
            state: state,
            result: result,
            error: error,
            credit: max(0, credit),
            capabilities: error == nil ? Self.advertisedCapabilities : []
        )) ?? (try! GuestAgentEnvelope(
            kind: .response,
            requestID: request.requestID,
            operation: request.operation,
            sandboxID: request.sandboxID,
            ownerID: request.ownerID,
            generation: request.generation,
            deadlineMilliseconds: request.deadlineMilliseconds,
            credit: 0,
            state: nil,
            result: nil,
            error: .internalFailure
        ))
    }

    private func errorCode(for error: GuestAgentProtocolError) -> GuestAgentErrorCode {
        switch error {
        case .unsupportedVersion: .unsupportedVersion
        case .unauthenticated: .unauthenticated
        case .deadlineExceeded: .deadlineExceeded
        case .cancelled: .cancelled
        case .creditExhausted: .creditExhausted
        default: .malformed
        }
    }

    private func errorCode(for error: PodSandboxLifecycleError) -> GuestAgentErrorCode {
        switch error {
        case .invalidTransition: .invalidTransition
        case .ownershipMismatch: .ownershipMismatch
        case .generationMismatch: .generationMismatch
        case .generationConflict: .generationConflict
        case .replayMismatch, .requestIDConflict: .replayMismatch
        case .sandboxNotFound: .sandboxNotFound
        case .recoveryEvidenceInvalid: .internalFailure
        case .cleanupIncomplete: .cleanupIncomplete
        }
    }
}

public final class GuestAgentServer: @unchecked Sendable {
    private let dispatcher: GuestAgentDispatcher

    public init(dispatcher: GuestAgentDispatcher) {
        self.dispatcher = dispatcher
    }

    public func run(
        inputDescriptor: Int32 = STDIN_FILENO,
        outputDescriptor: Int32 = STDOUT_FILENO
    ) throws {
        try configureDescriptor(inputDescriptor)
        try configureDescriptor(outputDescriptor)
        while true {
            let deadline = try GuestAgentDeadline(
                timeoutMilliseconds: GuestAgentProtocolV1.maximumDeadlineMilliseconds
            )
            let payload: Data
            do {
                payload = try GuestAgentFrameCodec.read(
                    kind: .request,
                    descriptor: inputDescriptor,
                    deadline: deadline
                )
            } catch GuestAgentProtocolError.peerClosed {
                return
            }
            let request = try GuestAgentEnvelopeCodec.decode(payload, expectedKind: .request)
            guard request.kind == .request else {
                throw GuestAgentProtocolError.invalidEnvelope("request kind")
            }
            let response = dispatcher.dispatch(request)
            let responsePayload = try GuestAgentEnvelopeCodec.encode(response)
            let responseDeadline = try GuestAgentDeadline(
                timeoutMilliseconds: request.deadlineMilliseconds
            )
            try GuestAgentFrameCodec.write(
                responsePayload,
                kind: .response,
                descriptor: outputDescriptor,
                deadline: responseDeadline
            )
        }
    }

    private func configureDescriptor(_ descriptor: Int32) throws {
        guard descriptor >= 0 else {
            throw GuestAgentProtocolError.transportFailure
        }
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw GuestAgentProtocolError.transportFailure
        }
    }
}

public final class GuestAgentProcessTransport: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private var inputDescriptor: Int32 = -1
    private var outputDescriptor: Int32 = -1
    private var closed = false

    public init(executableURL: URL, arguments: [String] = []) throws {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
            throw GuestAgentProtocolError.transportFailure
        }
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public var isRunning: Bool {
        lock.withLock { process?.isRunning == true }
    }

    public func send(
        _ request: GuestAgentEnvelope,
        cancellation: GuestAgentCancellation? = nil
    ) throws -> GuestAgentEnvelope {
        try lock.withLock {
            guard !closed else { throw GuestAgentProtocolError.peerClosed }
            try request.validate()
            if cancellation?.isCancelled == true {
                throw GuestAgentProtocolError.cancelled
            }
            try startLocked()
            let requestPayload = try GuestAgentEnvelopeCodec.encode(request)
            let deadline = try GuestAgentDeadline(
                timeoutMilliseconds: request.deadlineMilliseconds
            )
            try GuestAgentFrameCodec.write(
                requestPayload,
                kind: .request,
                descriptor: inputDescriptor,
                deadline: deadline,
                cancellation: cancellation
            )
            let responsePayload = try GuestAgentFrameCodec.read(
                kind: .response,
                descriptor: outputDescriptor,
                deadline: deadline,
                cancellation: cancellation
            )
            let response = try GuestAgentEnvelopeCodec.decode(responsePayload, expectedKind: .response)
            guard response.kind == .response,
                  response.requestID == request.requestID,
                  response.operation == request.operation,
                  response.sandboxID == request.sandboxID,
                  response.ownerID == request.ownerID,
                  response.generation == request.generation else {
                throw GuestAgentProtocolError.requestIDMismatch
            }
            return response
        }
    }

    public func close() {
        lock.withLock {
            if inputDescriptor >= 0 {
                _ = Darwin.close(inputDescriptor)
                inputDescriptor = -1
            }
            if outputDescriptor >= 0 {
                _ = Darwin.close(outputDescriptor)
                outputDescriptor = -1
            }
            if let process {
                if process.isRunning {
                    process.terminate()
                    for _ in 0..<50 {
                        if !process.isRunning { break }
                        usleep(10_000)
                    }
                    if process.isRunning {
                        _ = kill(process.processIdentifier, SIGKILL)
                    }
                    process.waitUntilExit()
                }
            }
            process = nil
            closed = true
        }
    }

    deinit {
        close()
    }

    private func startLocked() throws {
        guard process == nil else {
            guard process?.isRunning == true else {
                throw GuestAgentProtocolError.peerClosed
            }
            return
        }
        var inputPair: [Int32] = [-1, -1]
        var outputPair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &inputPair) == 0,
              socketpair(AF_UNIX, SOCK_STREAM, 0, &outputPair) == 0 else {
            if inputPair[0] >= 0 { _ = Darwin.close(inputPair[0]) }
            if inputPair[1] >= 0 { _ = Darwin.close(inputPair[1]) }
            throw GuestAgentProtocolError.transportFailure
        }

        var childProcess: Process?
        do {
            let childInput = FileHandle(fileDescriptor: inputPair[1], closeOnDealloc: false)
            let childOutput = FileHandle(fileDescriptor: outputPair[1], closeOnDealloc: false)
            let childError = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
            let child = Process()
            child.executableURL = executableURL
            child.arguments = ["--stdio"] + arguments
            child.environment = [
                "PATH": "/usr/bin:/bin",
                "LANG": "C",
                "LC_ALL": "C"
            ]
            child.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
            child.standardInput = childInput
            child.standardOutput = childOutput
            child.standardError = childError
            try child.run()
            childProcess = child
            _ = Darwin.close(inputPair[1])
            inputPair[1] = -1
            _ = Darwin.close(outputPair[1])
            outputPair[1] = -1
            try GuestAgentFrameCodec.configureConnectedSocket(descriptor: inputPair[0])
            try GuestAgentFrameCodec.configureConnectedSocket(descriptor: outputPair[0])
            inputDescriptor = inputPair[0]
            outputDescriptor = outputPair[0]
            inputPair[0] = -1
            outputPair[0] = -1
            process = child
        } catch {
            if let childProcess, childProcess.isRunning {
                childProcess.terminate()
                childProcess.waitUntilExit()
            }
            for descriptor in inputPair + outputPair where descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
            throw error as? GuestAgentProtocolError ?? GuestAgentProtocolError.transportFailure
        }
    }
}
