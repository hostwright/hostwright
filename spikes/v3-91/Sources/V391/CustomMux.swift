import Foundation
import Network
import Security

private enum MuxKind: UInt8 {
    case open = 1
    case data = 2
    case window = 3
    case cancel = 4
    case heartbeat = 5
    case heartbeatAck = 6
}

private enum MuxStream: UInt8 {
    case rpc = 1
    case bulk = 2
}

private struct MuxFrame {
    let kind: MuxKind
    let stream: UInt8
    let payload: Data

    init(_ kind: MuxKind, _ stream: UInt8, _ payload: Data = Data()) {
        self.kind = kind
        self.stream = stream
        self.payload = payload
    }

    var encoded: Data {
        let length = UInt16(payload.count)
        return Data([kind.rawValue, stream, UInt8(length >> 8), UInt8(truncatingIfNeeded: length)]) + payload
    }

    static func read(from connection: NWConnection) async throws -> MuxFrame {
        let head = try await receiveExact(4, from: connection)
        let count = Int(head[2]) * 256 + Int(head[3])
        guard let kind = MuxKind(rawValue: head[0]), count <= bulkPayload.count else {
            throw BenchmarkError("Invalid or oversized mux frame.")
        }
        let payload = count == 0 ? Data() : try await receiveExact(count, from: connection)
        return MuxFrame(kind, head[1], payload)
    }
}

private actor MuxWriter {
    private struct Pending {
        let bytes: Data
        let highPriority: Bool
        let completion: CheckedContinuation<Void, Error>
    }

    private let connection: NWConnection
    private let priorityEnabled: Bool
    private var queue: [Pending] = []
    private var draining = false
    private(set) var prioritySelections = 0

    init(_ connection: NWConnection, priorityEnabled: Bool) {
        self.connection = connection
        self.priorityEnabled = priorityEnabled
    }

    func send(_ frame: MuxFrame, highPriority: Bool = true) async throws {
        guard frame.payload.count <= bulkPayload.count else { throw BenchmarkError("Oversized outgoing mux frame.") }
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            guard queue.lazy.filter({ $0.highPriority == highPriority }).count < 8 else {
                completion.resume(throwing: BenchmarkError("Mux writer queue exhausted."))
                return
            }
            queue.append(Pending(bytes: frame.encoded, highPriority: highPriority, completion: completion))
            if !draining {
                draining = true
                Task { await drain() }
            }
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let index = priorityEnabled ? queue.firstIndex(where: \.highPriority) ?? 0 : 0
            if index > 0 { prioritySelections += 1 }
            let frame = queue.remove(at: index)
            do {
                try await sendTCP(frame.bytes, over: connection)
                frame.completion.resume()
            } catch {
                frame.completion.resume(throwing: error)
            }
        }
        draining = false
    }
}

private actor MuxPeer {
    private let isWorker: Bool
    private let connection: NWConnection
    private let writer: MuxWriter
    private let bulkReceived: [UInt8: ByteCounter]
    private var streams: [UInt8: MuxStream] = [:]
    private var pendingReplies: [UInt8: CheckedContinuation<Data, Error>] = [:]
    private var replies: [UInt8: Data] = [:]
    private var credits: [UInt8: Int] = [:]
    private var creditWaiters: [UInt8: CheckedContinuation<Void, Error>] = [:]
    private var terminalError: Error?
    private(set) var heartbeatReplies = 0

    private static let maximumStreams = 8
    private static let initialCredit = 16

    init(_ connection: NWConnection, isWorker: Bool, bulkReceived: [UInt8: ByteCounter], priorityEnabled: Bool) {
        self.connection = connection
        self.writer = MuxWriter(connection, priorityEnabled: priorityEnabled)
        self.isWorker = isWorker
        self.bulkReceived = bulkReceived
    }

    var prioritySelections: Int {
        get async { await writer.prioritySelections }
    }

    func readFrames() async {
        do {
            while !Task.isCancelled {
                try await handle(MuxFrame.read(from: connection))
            }
        } catch {
            terminalError = error
            for continuation in pendingReplies.values { continuation.resume(throwing: error) }
            for continuation in creditWaiters.values { continuation.resume(throwing: error) }
            pendingReplies.removeAll()
            creditWaiters.removeAll()
        }
    }

    func open(_ id: UInt8, as mode: MuxStream) async throws {
        guard owns(id) else { throw BenchmarkError("Wrong parity for mux stream opener.") }
        try addStream(id, as: mode)
        try await writer.send(MuxFrame(.open, id, Data([mode.rawValue])))
    }

    func sendBulk(on id: UInt8) async throws {
        guard owns(id), streams[id] == .bulk else { throw BenchmarkError("Expected a local mux bulk stream.") }
        if let terminalError { throw terminalError }
        if credits[id] == 0 {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                guard creditWaiters[id] == nil else {
                    waiter.resume(throwing: BenchmarkError("Concurrent writers on a single mux bulk stream."))
                    return
                }
                creditWaiters[id] = waiter
            }
        } else {
            credits[id, default: 0] -= 1
        }
        try Task.checkCancellation()
        try await writer.send(MuxFrame(.data, id, bulkPayload), highPriority: false)
    }

    func ping(on id: UInt8) async throws {
        guard owns(id), streams[id] == .rpc else { throw BenchmarkError("Expected a local mux RPC stream.") }
        try await writer.send(MuxFrame(.data, id, rpcPayload))
        if let terminalError { throw terminalError }
        let response: Data
        if let queued = replies.removeValue(forKey: id) {
            response = queued
        } else {
            response = try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Data, Error>) in
                guard pendingReplies[id] == nil else {
                    waiter.resume(throwing: BenchmarkError("Concurrent RPCs on one mux stream."))
                    return
                }
                pendingReplies[id] = waiter
            }
        }
        guard response == rpcPayload else { throw BenchmarkError("Mux RPC echo mismatch.") }
    }

    func cancel(_ id: UInt8) async throws {
        try removeStream(id)
        try await writer.send(MuxFrame(.cancel, id))
    }

    func sendHeartbeat() async throws {
        try await writer.send(MuxFrame(.heartbeat, 0))
    }

    func hasStream(_ id: UInt8) -> Bool {
        streams[id] != nil
    }

    private func owns(_ id: UInt8) -> Bool {
        id != 0 && (id % 2 == 0) == isWorker
    }

    private func addStream(_ id: UInt8, as mode: MuxStream) throws {
        guard id != 0, streams[id] == nil, streams.count < Self.maximumStreams else {
            throw BenchmarkError("Mux stream ID reused or stream limit exceeded.")
        }
        streams[id] = mode
        if mode == .bulk, owns(id) { credits[id] = Self.initialCredit }
    }

    private func removeStream(_ id: UInt8) throws {
        guard streams.removeValue(forKey: id) != nil else { throw BenchmarkError("Unknown mux stream cancellation.") }
        replies.removeValue(forKey: id)
        credits.removeValue(forKey: id)
        let error = BenchmarkError("Mux stream cancelled.")
        pendingReplies.removeValue(forKey: id)?.resume(throwing: error)
        creditWaiters.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func handle(_ frame: MuxFrame) async throws {
        let id = frame.stream
        switch frame.kind {
        case .open:
            guard !owns(id), frame.payload.count == 1, let mode = MuxStream(rawValue: frame.payload[0]) else {
                throw BenchmarkError("Invalid mux stream open.")
            }
            try addStream(id, as: mode)
        case .data:
            switch streams[id] {
            case .rpc:
                guard frame.payload == rpcPayload else { throw BenchmarkError("Invalid mux RPC payload.") }
                if owns(id) {
                    if let waiter = pendingReplies.removeValue(forKey: id) {
                        waiter.resume(returning: frame.payload)
                    } else {
                        guard replies[id] == nil else { throw BenchmarkError("Mux RPC reply buffer exhausted.") }
                        replies[id] = frame.payload
                    }
                } else {
                    try await writer.send(MuxFrame(.data, id, frame.payload))
                }
            case .bulk:
                guard !owns(id), frame.payload.count == bulkPayload.count, let counter = bulkReceived[id] else {
                    throw BenchmarkError("Invalid mux bulk frame.")
                }
                counter.add(frame.payload.count)
                try await writer.send(MuxFrame(.window, id))
            case nil:
                throw BenchmarkError("Mux data arrived for an unknown stream.")
            }
        case .window:
            guard let credit = credits[id], credit < Self.initialCredit, frame.payload.isEmpty else {
                throw BenchmarkError("Invalid mux credit update.")
            }
            if let waiter = creditWaiters.removeValue(forKey: id) {
                waiter.resume()
            } else {
                credits[id] = credit + 1
            }
        case .cancel:
            guard frame.payload.isEmpty else { throw BenchmarkError("Invalid mux cancellation payload.") }
            try removeStream(id)
        case .heartbeat, .heartbeatAck:
            guard id == 0, frame.payload.isEmpty else { throw BenchmarkError("Invalid mux heartbeat.") }
            if frame.kind == .heartbeat {
                try await writer.send(MuxFrame(.heartbeatAck, 0))
            } else {
                heartbeatReplies += 1
            }
        }
    }
}

func runTLSMux(_ credentials: BenchmarkCredentials, scenario: BenchmarkScenario) async throws -> BenchmarkMeasurement {
    let alpn = "hostwright-spike-mux/1"
    let serverParameters = NWParameters(tls: try credentials.tlsOptions(server: true, alpn: alpn), tcp: muxTCPOptions())
    serverParameters.requiredLocalEndpoint = .hostPort(host: loopback, port: .any)
    serverParameters.acceptLocalOnly = true
    let listener = try NWListener(using: serverParameters)
    let accepted = FirstValue<NWConnection>()
    listener.newConnectionHandler = { connection in
        connection.start(queue: benchmarkQueue)
        accepted.record(connection)
    }
    listener.start(queue: benchmarkQueue)
    defer { listener.cancel() }
    try await pollFor("TLS mux listener") {
        if case .failed(let error) = listener.state { throw error }
        return listener.state == .ready
    }
    guard let port = listener.port else { throw BenchmarkError("TLS mux listener has no bound port.") }
    let clientParameters = NWParameters(tls: try credentials.tlsOptions(server: false, alpn: alpn), tcp: muxTCPOptions())
    let client = NWConnection(host: loopback, port: port, using: clientParameters)
    client.start(queue: benchmarkQueue)
    defer { client.cancel() }
    try await pollFor("TLS 1.3 mux handshake") {
        if case .failed(let error) = client.state { throw error }
        return client.state == .ready && accepted.value?.state == .ready
    }
    guard let server = accepted.value else { throw BenchmarkError("TLS mux worker did not accept the connection.") }
    let connectionDeadline = DispatchWorkItem {
        client.cancel()
        server.cancel()
    }
    benchmarkQueue.asyncAfter(deadline: .now() + .seconds(45), execute: connectionDeadline)
    defer {
        connectionDeadline.cancel()
        server.cancel()
    }
    for connection in [client, server] {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              sec_protocol_metadata_get_negotiated_tls_protocol_version(tls.securityProtocolMetadata) == .TLSv13 else {
            throw BenchmarkError("Mux did not negotiate TLS 1.3.")
        }
    }

    let bulkIDs = (0..<scenario.bulkStreamCount).map { UInt8(3 + 2 * $0) }
    let received = bulkIDs.map { _ in ByteCounter() }
    let counters = Dictionary(uniqueKeysWithValues: zip(bulkIDs, received))
    let control = MuxPeer(client, isWorker: false, bulkReceived: [:], priorityEnabled: scenario.priority == .on)
    let worker = MuxPeer(server, isWorker: true, bulkReceived: counters, priorityEnabled: scenario.priority == .on)
    let controlReader = Task { await control.readFrames() }
    let workerReader = Task { await worker.readFrames() }
    defer {
        controlReader.cancel()
        workerReader.cancel()
    }
    try await worker.open(2, as: .rpc)
    try await worker.ping(on: 2)
    guard await control.hasStream(2) else { throw BenchmarkError("Worker-originated mux stream was not observed.") }
    try await worker.cancel(2)
    try await control.sendHeartbeat()
    let heartbeatDeadline = ContinuousClock.now + .seconds(5)
    while true {
        let heartbeatSeen = await control.heartbeatReplies > 0
        let cancelled = await !control.hasStream(2)
        if heartbeatSeen && cancelled { break }
        guard ContinuousClock.now < heartbeatDeadline else { throw BenchmarkError("Mux cancellation or heartbeat was not observed.") }
        try await Task.sleep(for: .milliseconds(5))
    }
    try await control.open(1, as: .rpc)
    for id in bulkIDs { try await control.open(id, as: .bulk) }
    let producers = bulkIDs.map { id in
        Task {
            while !Task.isCancelled { try await control.sendBulk(on: id) }
        }
    }
    defer { producers.forEach { $0.cancel() } }
    let result = try await measure(bulkStreams: received) { try await control.ping(on: 1) }
    print("mux worker-originated and control-originated RPC echoed; worker cancellation observed; heartbeat echoed; streams=8 frame_bytes=16384 bulk_outstanding_frames=16 priority_preemptions=\(await control.prioritySelections)")
    return result
}

func muxTCPOptions() -> NWProtocolTCP.Options {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 2
    tcp.keepaliveInterval = 1
    return tcp
}

private func sendTCP(_ bytes: Data, over connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
        connection.send(content: bytes, completion: .contentProcessed { error in
            if let error { completion.resume(throwing: error) } else { completion.resume() }
        })
    }
}

private func receiveExact(_ size: Int, from connection: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation { completion in
        connection.receive(minimumIncompleteLength: size, maximumLength: size) { bytes, _, _, error in
            if let error {
                completion.resume(throwing: error)
            } else if let bytes, bytes.count == size {
                completion.resume(returning: bytes)
            } else {
                completion.resume(throwing: BenchmarkError("TLS connection closed mid-frame."))
            }
        }
    }
}
