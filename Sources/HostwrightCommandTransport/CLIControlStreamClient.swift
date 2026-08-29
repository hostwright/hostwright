import Darwin
import Foundation
import HostwrightCLI
import HostwrightControlPlane
import HostwrightControlTransport
import HostwrightCore
import HostwrightRuntime
import HostwrightState

public struct CLIControlStreamClient: @unchecked Sendable {
    public typealias OutputWriter = @Sendable (Data, Int32) throws -> Void
    typealias SessionFactory = @Sendable (String) throws -> PersistentControlClientSession

    public let socketPath: String
    private let outputWriter: OutputWriter
    private let inputDescriptor: Int32
    private let sessionFactory: SessionFactory

    public init(
        socketPath: String,
        inputDescriptor: Int32 = STDIN_FILENO,
        outputWriter: @escaping OutputWriter = Self.writeAll
    ) {
        self.socketPath = socketPath
        self.inputDescriptor = inputDescriptor
        self.outputWriter = outputWriter
        self.sessionFactory = { path in
            try PersistentControlClient(socketPath: path).connectSession()
        }
    }

    init(
        socketPath: String,
        inputDescriptor: Int32 = STDIN_FILENO,
        outputWriter: @escaping OutputWriter = Self.writeAll,
        sessionFactory: @escaping SessionFactory
    ) {
        self.socketPath = socketPath
        self.inputDescriptor = inputDescriptor
        self.outputWriter = outputWriter
        self.sessionFactory = sessionFactory
    }

    public func run(
        route: CLIControlRoute,
        preparationRequestID: String
    ) throws -> CLIRunResult {
        guard case .stream(let expectedSource) = route.execution else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The CLI stream client requires a classified stream command."
            )
        }
        let session = try sessionFactory(socketPath)
        defer { session.close() }
        let preparationResponse = try session.send(
            CLIControlStreamPreparationContract.request(
                route: route,
                requestID: preparationRequestID
            )
        )
        let preparation = try CLIControlStreamPreparation.decode(preparationResponse)
        guard preparation.source == expectedSource else {
            throw HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message: "The daemon prepared a different stream source than the CLI requested."
            )
        }
        let streamID = "cli:\(UUID().uuidString.lowercased())"
        let streamRequestID = "\(preparationRequestID):stream"
        let mutationIdentity = expectedSource == .exec || expectedSource == .attach
        let open = ControlStreamOpenRequest(
            source: preparation.source,
            target: preparation.target,
            filter: preparation.filter,
            requestID: mutationIdentity ? streamRequestID : nil,
            idempotencyKey: mutationIdentity ? streamRequestID : nil
        )
        try session.openStream(
            streamID: streamID,
            request: open,
            cursor: preparation.cursor,
            initialCredit: 16
        )

        let command = try CLICommand.parse(arguments: route.arguments)
        var eventRecords: [HostwrightEventStreamRecord] = []
        var eventTimedOut = false
        var eventRetentionGap: HostwrightEventRetentionGap?
        var interactiveExitStatus: Int32 = 0
        var ioSession: CLIControlStreamIOSession?
        let started = DispatchTime.now().uptimeNanoseconds
        let absoluteDeadline = started + UInt64(preparation.timeoutMilliseconds) * 1_000_000

        streamLoop: while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < absoluteDeadline else {
                try? session.cancel(streamID: streamID)
                if case .events(_, _, _, let stream, _) = command, stream.watch {
                    eventTimedOut = true
                    break streamLoop
                }
                throw HostwrightDiagnostic(
                    code: .controlAPIUnavailable,
                    message: "The CLI stream exceeded its bounded deadline."
                )
            }
            let remaining = Int(min(
                UInt64(ControlPlaneContract.maximumUnaryDeadlineMilliseconds),
                max(1, (absoluteDeadline - now) / 1_000_000)
            ))
            let frame: StreamFrame
            do {
                frame = try session.nextFrame(
                    streamID: streamID,
                    timeoutMilliseconds: remaining
                )
            } catch PersistentControlClientError.deadlineExceeded {
                try? session.cancel(streamID: streamID)
                if case .events(_, _, _, let stream, _) = command, stream.watch {
                    eventTimedOut = true
                    break streamLoop
                }
                throw HostwrightDiagnostic(
                    code: .controlAPIUnavailable,
                    message: "The CLI stream exceeded its bounded deadline."
                )
            }
            switch frame.kind {
            case .open:
                if case .interactive(let options) = command {
                    let standardIO = try CLIControlStreamIOSession(
                        session: session,
                        streamID: streamID,
                        inputDescriptor: inputDescriptor,
                        terminal: options.terminal,
                        forwardsStandardInput: options.forwardsStandardInput,
                        supportsRuntimeControl: expectedSource == .exec || expectedSource == .attach
                    )
                    try standardIO.start()
                    ioSession = standardIO
                    if !options.forwardsStandardInput,
                       (expectedSource == .exec || expectedSource == .attach) {
                        try session.finishStreamInput(streamID: streamID)
                    }
                } else if expectedSource == .exec || expectedSource == .attach {
                    try session.finishStreamInput(streamID: streamID)
                }
            case .data:
                guard let payload = frame.payload else {
                    throw invalidStream()
                }
                switch expectedSource {
                case .events:
                    eventRecords.append(try Self.eventRecord(payload))
                case .logs:
                    if case .interactive(let options) = command,
                       options.command == .logsFollow {
                        let envelope = try Self.runtimeEnvelope(payload)
                        if envelope.stream == .control {
                            interactiveExitStatus = try runtimeExitStatus(envelope)
                        } else {
                            try writeRuntimeEnvelope(envelope, output: preparation.outputFormat)
                        }
                    } else {
                        try writeLogPayload(payload)
                    }
                case .exec, .attach:
                    let envelope = try Self.runtimeEnvelope(payload)
                    if envelope.stream == .control {
                        interactiveExitStatus = try runtimeExitStatus(envelope)
                    } else {
                        try writeRuntimeEnvelope(envelope, output: preparation.outputFormat)
                    }
                case .metrics, .traces, .operation, .state:
                    throw invalidStream()
                }
                try session.acknowledge(streamID: streamID, credit: 1, cursor: frame.cursor)
            case .heartbeat, .ack:
                continue
            case .end:
                ioSession?.stop()
                try ioSession?.throwIfFailed()
                return try result(
                    command: command,
                    eventRecords: eventRecords,
                    eventTimedOut: eventTimedOut,
                    eventRetentionGap: eventRetentionGap,
                    interactiveExitStatus: interactiveExitStatus
                )
            case .gap:
                let gap = try frame.payload.map(ControlStreamFrameContract.decodeGap)
                if case .events(_, _, _, let stream, _) = command,
                   let requestedCursor = stream.cursor,
                   gap?.reason == "retention.compacted" {
                    eventRetentionGap = HostwrightEventRetentionGap(
                        requestedCursor: requestedCursor,
                        earliestAvailableCursor: gap?.earliestCursor,
                        latestAvailableCursor: gap?.latestCursor
                    )
                    break streamLoop
                }
                ioSession?.stop()
                throw HostwrightDiagnostic(
                    code: .controlAPIUnavailable,
                    message: "The stream cursor has a recoverable gap: \(gap?.reason ?? "unknown")."
                )
            case .error:
                ioSession?.stop()
                throw HostwrightDiagnostic(
                    code: .controlAPIExecutionFailed,
                    message: frame.error?.message ?? "The daemon stream failed safely."
                )
            case .cancel:
                throw invalidStream()
            }
        }
        ioSession?.stop()
        try ioSession?.throwIfFailed()
        return try result(
            command: command,
            eventRecords: eventRecords,
            eventTimedOut: eventTimedOut,
            eventRetentionGap: eventRetentionGap,
            interactiveExitStatus: interactiveExitStatus
        )
    }

    private func result(
        command: CLICommand,
        eventRecords: [HostwrightEventStreamRecord],
        eventTimedOut: Bool,
        eventRetentionGap: HostwrightEventRetentionGap?,
        interactiveExitStatus: Int32
    ) throws -> CLIRunResult {
        if case .events(
            let stateDatabasePath,
            let projectName,
            let filters,
            let stream,
            let output
        ) = command {
            let pageSize = filters.limit ?? HostwrightEventStreamPage.defaultPageSize
            let moreAvailable = eventRecords.count > pageSize
            let selected = Array(eventRecords.prefix(pageSize))
            let page = HostwrightEventStreamPage(
                status: eventRetentionGap == nil
                    ? (eventTimedOut ? .timeout : .ready)
                    : .retentionGap,
                events: selected,
                nextCursor: selected.last?.cursor,
                moreAvailable: moreAvailable,
                retentionGap: eventRetentionGap
            )
            let path = try HostwrightLocalPathResolver.resolve(
                explicitStateDatabasePath: stateDatabasePath
            ).stateDatabasePath
            return HostwrightCLI.renderControlEventStream(
                stateDatabasePath: path,
                projectName: projectName,
                filters: filters,
                stream: stream,
                output: output,
                page: page
            )
        }
        return CLIRunResult(exitCode: interactiveExitStatus)
    }

    static func eventRecord(_ value: ControlPlaneJSONValue) throws
        -> HostwrightEventStreamRecord
    {
        guard case .object(let fields) = value,
              Set(fields.keys) == [
                "eventReference", "id", "message", "operationReferences",
                "payloadJSONRedacted", "position", "projectID", "runtimeAdapter",
                "serviceName", "severity", "source", "timestamp", "type",
              ],
              case .integer(let rawPosition)? = fields["position"], rawPosition >= 0,
              case .string(let id)? = fields["id"],
              case .string(let timestamp)? = fields["timestamp"],
              case .string(let rawSeverity)? = fields["severity"],
              let severity = StateEventSeverity(rawValue: rawSeverity),
              case .string(let type)? = fields["type"],
              case .string(let source)? = fields["source"],
              case .string(let message)? = fields["message"],
              case .string(let payloadJSONRedacted)? = fields["payloadJSONRedacted"] else {
            throw invalidStream()
        }
        func optionalString(_ key: String) throws -> String? {
            guard let value = fields[key] else { return nil }
            switch value {
            case .null: return nil
            case .string(let string): return string
            default: throw invalidStream()
            }
        }
        let event = EventRecord(
            id: id,
            timestamp: timestamp,
            severity: severity,
            type: type,
            source: source,
            projectID: try optionalString("projectID"),
            serviceName: try optionalString("serviceName"),
            runtimeAdapter: try optionalString("runtimeAdapter"),
            message: message,
            payloadJSONRedacted: payloadJSONRedacted
        )
        return try HostwrightEventStreamRecord(
            position: UInt64(rawPosition),
            event: event
        )
    }

    private func writeLogPayload(_ value: ControlPlaneJSONValue) throws {
        try outputWriter(try Self.logPayload(value), STDOUT_FILENO)
    }

    static func logPayload(_ value: ControlPlaneJSONValue) throws -> Data {
        guard case .object(let fields) = value,
              Set(fields.keys) == ["encoding", "ordinal", "payload"],
              case .string("base64")? = fields["encoding"],
              case .integer(let ordinal)? = fields["ordinal"], ordinal >= 0,
              case .string(let encoded)? = fields["payload"],
              let data = Data(base64Encoded: encoded),
              data.base64EncodedString() == encoded else {
            throw invalidStream()
        }
        return data
    }

    static func runtimeEnvelope(_ value: ControlPlaneJSONValue) throws
        -> RuntimeStreamEnvelope
    {
        do {
            return try RuntimeStreamEnvelope.decodeNDJSONLine(
                ControlPlaneCanonicalJSON.encode(value)
            )
        } catch {
            throw invalidStream()
        }
    }

    private func writeRuntimeEnvelope(
        _ envelope: RuntimeStreamEnvelope,
        output: CLIOutputFormat
    ) throws {
        if output == .json {
            try outputWriter(try envelope.ndjsonLine(), STDOUT_FILENO)
        } else if !envelope.endOfStream, !envelope.payload.isEmpty {
            try outputWriter(
                envelope.payload,
                envelope.stream == .standardError ? STDERR_FILENO : STDOUT_FILENO
            )
        }
    }

    private func runtimeExitStatus(_ envelope: RuntimeStreamEnvelope) throws -> Int32 {
        guard let object = try JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any],
              Set(object.keys) == ["exitStatus", "kind", "schemaVersion"],
              object["kind"] as? String == "cli-stream-result",
              object["schemaVersion"] as? Int == 1,
              let raw = object["exitStatus"] as? Int,
              Int(Int32.min)...Int(Int32.max) ~= raw else {
            throw invalidStream()
        }
        return Int32(raw)
    }

    private static func invalidStream() -> HostwrightDiagnostic {
        HostwrightDiagnostic(
            code: .controlAPIExecutionFailed,
            message: "The daemon returned an invalid CLI stream payload."
        )
    }

    private func invalidStream() -> HostwrightDiagnostic { Self.invalidStream() }

    public static func writeAll(_ data: Data, _ descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if count > 0 { offset += count; continue }
            if count < 0, errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private final class CLIControlStreamIOSession: @unchecked Sendable {
    private static let forwardedSignals = [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGWINCH]

    private let session: PersistentControlClientSession
    private let streamID: String
    private let inputDescriptor: Int32
    private let terminalDescriptor: Int32
    private let terminal: Bool
    private let supportsRuntimeControl: Bool
    private let queue = DispatchQueue(label: "dev.hostwright.cli.control-input")
    private let signalQueue = DispatchQueue(label: "dev.hostwright.cli.control-signals")
    private let inputGroup = DispatchGroup()
    private let lock = NSLock()
    private var signalSources: [DispatchSourceSignal] = []
    private var previousSignalHandlers: [(Int32, sig_t?)] = []
    private var savedTerminalAttributes: termios?
    private var failure: Error?
    private var started = false
    private var stopped = false

    init(
        session: PersistentControlClientSession,
        streamID: String,
        inputDescriptor: Int32,
        terminal: Bool,
        forwardsStandardInput: Bool,
        supportsRuntimeControl: Bool
    ) throws {
        self.session = session
        self.streamID = streamID
        self.terminalDescriptor = inputDescriptor
        self.terminal = terminal
        self.supportsRuntimeControl = supportsRuntimeControl
        if forwardsStandardInput {
            let duplicate = dup(inputDescriptor)
            guard duplicate >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            self.inputDescriptor = duplicate
        } else {
            self.inputDescriptor = -1
        }
    }

    deinit { stop() }

    func start() throws {
        let mayStart = lock.withLock { () -> Bool in
            guard !started, !stopped else { return false }
            started = true
            return true
        }
        guard mayStart else { return }
        previousSignalHandlers.append((SIGPIPE, Darwin.signal(SIGPIPE, SIG_IGN)))
        for signalNumber in Self.forwardedSignals {
            previousSignalHandlers.append((signalNumber, Darwin.signal(signalNumber, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
            source.setEventHandler { [weak self] in self?.handle(signal: signalNumber) }
            source.resume()
            signalSources.append(source)
        }
        if terminal, isatty(terminalDescriptor) == 1 {
            var current = termios()
            guard tcgetattr(terminalDescriptor, &current) == 0 else {
                stop()
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var raw = current
            cfmakeraw(&raw)
            guard tcsetattr(terminalDescriptor, TCSANOW, &raw) == 0 else {
                stop()
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            savedTerminalAttributes = current
            try sendTerminalSize()
        }
        if inputDescriptor >= 0 {
            inputGroup.enter()
            queue.async { [self] in
                run()
                inputGroup.leave()
            }
        }
    }

    func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        for source in signalSources {
            source.setEventHandler {}
            source.cancel()
        }
        signalSources.removeAll()
        for (signalNumber, handler) in previousSignalHandlers.reversed() {
            Darwin.signal(signalNumber, handler)
        }
        previousSignalHandlers.removeAll()
        if var savedTerminalAttributes {
            _ = tcsetattr(terminalDescriptor, TCSANOW, &savedTerminalAttributes)
            self.savedTerminalAttributes = nil
        }
        if inputDescriptor >= 0 {
            _ = inputGroup.wait(timeout: .now() + 1)
            close(inputDescriptor)
        }
    }

    func throwIfFailed() throws {
        if let failure = lock.withLock({ failure }) { throw failure }
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: ControlPlaneContract.maximumStreamInputBytes)
        while !isStopped {
            var state = pollfd(fd: inputDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = poll(&state, 1, 100)
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { fail(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)); return }
            if result == 0 { continue }
            if state.revents & Int16(POLLNVAL) != 0 { return }
            let count = Darwin.read(inputDescriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                try? session.finishStreamInput(streamID: streamID)
                return
            }
            do {
                try send(ControlStreamClientInput(
                    kind: .stdin,
                    payloadBase64: Data(buffer[0..<count]).base64EncodedString()
                ))
            } catch {
                if !isStopped { fail(error) }
                return
            }
        }
    }

    private func handle(signal signalNumber: Int32) {
        do {
            guard supportsRuntimeControl else {
                try session.cancel(streamID: streamID)
                return
            }
            if signalNumber == SIGWINCH, terminal {
                try sendTerminalSize()
            } else {
                try send(ControlStreamClientInput(kind: .signal, signal: signalNumber))
            }
        } catch {
            fail(error)
            try? session.cancel(streamID: streamID)
        }
    }

    private func sendTerminalSize() throws {
        var window = winsize()
        guard ioctl(terminalDescriptor, TIOCGWINSZ, &window) == 0,
              window.ws_col > 0, window.ws_row > 0 else { return }
        try send(ControlStreamClientInput(
            kind: .resize,
            columns: Int(window.ws_col),
            rows: Int(window.ws_row)
        ))
    }

    private func send(_ input: ControlStreamClientInput) throws {
        try session.sendStreamInputWhenCreditAvailable(
            streamID: streamID,
            payload: try ControlStreamFrameContract.value(input)
        )
    }

    private func fail(_ error: Error) {
        lock.withLock {
            if failure == nil { failure = error }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}
