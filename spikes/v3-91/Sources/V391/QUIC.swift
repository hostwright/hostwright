import Foundation
import Network
import Security

private let quicALPN = "hostwright-spike-quic/1"
private let streamCancellationCode: UInt64 = 0x17

private enum StreamRole: UInt8 {
    case rpc = 1
    case bulk = 2
    case cancellation = 3
}

final class FirstValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? { lock.withLock { stored } }

    func record(_ value: Value) {
        lock.withLock {
            if stored == nil { stored = value }
        }
    }
}

private func quicParameters(
    _ credentials: BenchmarkCredentials, server: Bool
) throws -> NWParameters {
    let quic = NWProtocolQUIC.Options(alpn: [quicALPN])
    quic.direction = .bidirectional
    quic.idleTimeout = 10_000
    quic.initialMaxData = 1_048_576
    quic.initialMaxStreamDataBidirectionalLocal = 262_144
    quic.initialMaxStreamDataBidirectionalRemote = 262_144
    quic.initialMaxStreamsBidirectional = 8
    quic.initialMaxStreamsUnidirectional = 0
    let security = quic.securityProtocolOptions
    sec_protocol_options_set_local_identity(security, try credentials.localIdentity(server: server))
    sec_protocol_options_set_peer_authentication_required(security, true)
    let verify = credentials.validator(server: server)
    sec_protocol_options_set_verify_block(security, { _, trust, reply in
        reply(verify(trust))
    }, benchmarkQueue)
    let parameters = NWParameters(quic: quic)
    if server {
        parameters.requiredLocalEndpoint = .hostPort(host: loopback, port: .any)
        parameters.acceptLocalOnly = true
    }
    return parameters
}

func runQUIC(_ credentials: BenchmarkCredentials) async throws -> BenchmarkMeasurement {
    let received = ByteCounter()
    let cancellation = ByteCounter()
    let backgroundError = FirstValue<Error>()
    let workerGroup = FirstValue<NWConnectionGroup>()
    let listener = try NWListener(using: quicParameters(credentials, server: true))
    listener.newConnectionGroupHandler = { group in
        workerGroup.record(group)
        startGroup(group, received: received, cancellation: cancellation, errors: backgroundError)
    }
    listener.start(queue: benchmarkQueue)
    defer {
        listener.cancel()
        workerGroup.value?.cancel()
    }

    try await pollFor("QUIC loopback listener") {
        if case .failed(let error) = listener.state { throw error }
        return listener.state == .ready
    }
    guard let port = listener.port else { throw BenchmarkError("QUIC listener has no bound port.") }
    let control = NWConnectionGroup(
        with: NWMultiplexGroup(to: .hostPort(host: loopback, port: port)),
        using: try quicParameters(credentials, server: false)
    )
    startGroup(control, received: received, cancellation: cancellation, errors: backgroundError)
    let connectionDeadline = DispatchWorkItem {
        control.cancel()
        workerGroup.value?.cancel()
    }
    benchmarkQueue.asyncAfter(deadline: .now() + .seconds(45), execute: connectionDeadline)
    defer {
        connectionDeadline.cancel()
        control.cancel()
    }
    try await pollFor("QUIC mutual TLS group handshake") {
        if case .failed(let error) = control.state { throw error }
        if let error = backgroundError.value { throw error }
        return control.state == .ready && workerGroup.value?.state == .ready
    }
    guard let worker = workerGroup.value else { throw BenchmarkError("QUIC listener did not accept the group.") }
    let controlMetadata = try quicMetadata(control)
    let workerMetadata = try quicMetadata(worker)
    for metadata in [controlMetadata, workerMetadata] {
        guard metadata.negotiatedALPN == quicALPN,
              sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv13,
              metadata.remoteIdleTimeout == 10_000,
              metadata.remoteMaxStreamsBidirectional == 8,
              metadata.remoteMaxStreamsUnidirectional == 0 else {
            throw BenchmarkError("QUIC did not negotiate TLS 1.3, the spike ALPN, and the configured stream limits.")
        }
        metadata.keepAlive = .seconds(2)
    }

    let reverse = try await openQUICStream(on: worker, role: .rpc)
    defer { reverse.cancel() }
    guard let reverseID = (reverse.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata)?.streamIdentifier,
          reverseID & 3 == 1 else {
        let metadata = reverse.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
        throw BenchmarkError("First worker-originated stream ID did not identify a server bidirectional stream: \(String(describing: metadata?.streamIdentifier)).")
    }
    traceQUIC("worker stream opened: \(reverseID)")
    try await pingQUIC(reverse)
    traceQUIC("worker echo received")

    let stopped = try await openQUICStream(on: control, role: .cancellation)
    defer { stopped.cancel() }
    traceQUIC("cancellation stream opened")
    try await pingQUIC(stopped)
    traceQUIC("cancellation stream echo received")
    let stoppedMetadata = stopped.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
    stoppedMetadata?.streamApplicationErrorCode = streamCancellationCode
    stopped.cancel()
    try await pollFor("peer QUIC stream cancellation") {
        if let error = backgroundError.value { throw error }
        return cancellation.value == 1
    }
    traceQUIC("peer cancellation observed")
    try await Task.sleep(for: .seconds(11))
    try await pingQUIC(reverse)

    let bulk = try await openQUICStream(on: control, role: .bulk)
    defer { bulk.cancel() }
    let producer = Task {
        while !Task.isCancelled { try await sendQUIC(bulkPayload, on: bulk, priority: 0) }
    }
    defer { producer.cancel() }
    let rpc = try await openQUICStream(on: control, role: .rpc)
    defer { rpc.cancel() }
    let result = try await measure(bulkReceived: received) {
        if let error = backgroundError.value { throw error }
        try await pingQUIC(rpc)
    }

    print("quic TLSv1.3 and ALPN matched; worker-originated stream ID \(reverseID) and control-originated RPC echoed; peer cancelled one stream without closing group; peer advertised 8 bidirectional, 0 unidirectional streams; configured per-stream window=262144; echoed after 11 s idle with 10 s peer timeout and 2 s keepalive")
    return result
}

private func startGroup(
    _ group: NWConnectionGroup, received: ByteCounter, cancellation: ByteCounter, errors: FirstValue<Error>
) {
    group.newConnectionHandler = { stream in
        stream.start(queue: benchmarkQueue)
        Task {
            do { try await handleQUICStream(stream, received: received, cancellation: cancellation) }
            catch { errors.record(error) }
        }
    }
    group.start(queue: benchmarkQueue)
}

private func quicMetadata(_ group: NWConnectionGroup) throws -> NWProtocolQUIC.Metadata {
    guard let metadata = group.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata else {
        throw BenchmarkError("QUIC metadata missing.")
    }
    return metadata
}

private func openQUICStream(on group: NWConnectionGroup, role: StreamRole) async throws -> NWConnection {
    guard let stream = NWConnection(from: group) else { throw BenchmarkError("Cannot open QUIC stream.") }
    stream.start(queue: benchmarkQueue)
    try await pollFor("QUIC stream ready") {
        if case .failed(let error) = stream.state { throw error }
        return stream.state == .ready
    }
    try await sendQUIC(Data([role.rawValue]), on: stream, priority: 1)
    return stream
}

private func pingQUIC(_ stream: NWConnection) async throws {
    try await sendQUIC(rpcPayload, on: stream, priority: 1)
    let response = try await receiveQUIC(from: stream, minimum: rpcPayload.count, maximum: rpcPayload.count)
    guard response == rpcPayload else { throw BenchmarkError("QUIC RPC echo mismatch.") }
}

private func handleQUICStream(_ stream: NWConnection, received: ByteCounter, cancellation: ByteCounter) async throws {
    defer { stream.cancel() }
    let selector = try await receiveQUIC(from: stream, minimum: 1, maximum: 1)
    guard let roleByte = selector?.first, let role = StreamRole(rawValue: roleByte) else {
        throw BenchmarkError("Unknown QUIC stream role.")
    }
    traceQUIC("entered peer role \(role)")
    switch role {
    case .rpc:
        while let frame = try await receiveQUIC(from: stream, minimum: rpcPayload.count, maximum: rpcPayload.count) {
            guard frame.count == rpcPayload.count else { throw BenchmarkError("Invalid QUIC RPC size.") }
            try await sendQUIC(frame, on: stream, priority: 1)
        }
    case .bulk:
        while let frame = try await receiveQUIC(from: stream, minimum: 1, maximum: bulkPayload.count) {
            received.add(frame.count)
        }
    case .cancellation:
        let frame = try await receiveQUIC(from: stream, minimum: rpcPayload.count, maximum: rpcPayload.count)
        guard frame == rpcPayload else { throw BenchmarkError("QUIC cancellation stream initial echo mismatch.") }
        try await sendQUIC(rpcPayload, on: stream, priority: 1)
        do {
            _ = try await receiveQUIC(from: stream, minimum: 1, maximum: 1)
        } catch {
            let metadata = stream.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
            guard metadata?.streamApplicationErrorCode == streamCancellationCode else { throw error }
            cancellation.add(1)
        }
    }
}

private func sendQUIC(_ data: Data, on stream: NWConnection, priority: Double) async throws {
    let context = NWConnection.ContentContext(identifier: "hostwright-spike", priority: priority)
    try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
        stream.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error { completion.resume(throwing: error) } else { completion.resume() }
        })
    }
}

private func receiveQUIC(from stream: NWConnection, minimum: Int, maximum: Int) async throws -> Data? {
    try await withCheckedThrowingContinuation { completion in
        stream.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, complete, error in
            if let error {
                completion.resume(throwing: error)
            } else if let data, !data.isEmpty {
                completion.resume(returning: data)
            } else if complete {
                completion.resume(returning: nil)
            } else {
                completion.resume(throwing: BenchmarkError("QUIC read produced neither data nor EOF."))
            }
        }
    }
}

private func traceQUIC(_ message: String) {
    guard ProcessInfo.processInfo.environment["V391_TRACE"] == "1" else { return }
    FileHandle.standardError.write(Data("QUIC \(message)\n".utf8))
}
