import Foundation
import Network
import Security

func probeModernQUIC(_ credentials: BenchmarkCredentials) async throws {
    let alpn = "hostwright-spike-quic/1"

    func options(server: Bool) throws -> QUIC {
        let verify = credentials.validator(server: server)
        return try QUIC(alpn: [alpn])
            .idleTimeout(10_000)
            .initialMaxData(1_048_576)
            .initialMaxStreamDataBidirectionalLocal(262_144)
            .initialMaxStreamDataBidirectionalRemote(262_144)
            .initialMaxBidirectionalStreams(8)
            .initialMaxUnidirectionalStreams(0)
            .tls.localIdentity(credentials.localIdentity(server: server))
            .tls.peerAuthentication(.required)
            .tls.certificateValidator { _, trust in verify(trust) }
    }

    let listening = ByteCounter()
    let accepted = ByteCounter()
    let echoed = ByteCounter()
    let listenerError = FirstValue<Error>()
    let clientError = FirstValue<Error>()
    let serverOptions = try options(server: true)
    let bind = NWParameters()
    bind.requiredLocalEndpoint = .hostPort(host: loopback, port: .any)
    bind.requiredInterfaceType = .loopback
    bind.acceptLocalOnly = true
    let listener = try NetworkListener<QUIC>(using: .parameters(initialParameters: bind) { serverOptions })
    listener.onStateUpdate { _, state in
        print("modern_quic_listener_state=\(state)")
        if state == .ready { listening.add(1) }
        if case .failed(let error) = state { listenerError.record(error) }
    }
    let serving = Task {
        do {
            try await listener.run { connection in
                accepted.add(1)
                try await connection.inboundStreams { stream in
                    let request = try await stream.receive(exactly: rpcPayload.count)
                    guard request.content == rpcPayload else { throw BenchmarkError("Modern QUIC request mismatch.") }
                    try await stream.send(request.content, endOfStream: true)
                }
            }
        } catch { listenerError.record(error) }
    }
    defer { serving.cancel() }

    try await pollFor("modern QUIC listener readiness") {
        if let error = listenerError.value { throw error }
        return listening.value > 0
    }
    guard let port = listener.port else { throw BenchmarkError("Modern QUIC listener has no port.") }
    let clientOptions = try options(server: false)
    let client = NetworkConnection(to: .hostPort(host: loopback, port: port)) { clientOptions }
    client.onStateUpdate { _, state in
        print("modern_quic_client_state=\(state)")
        if case .failed(let error) = state { clientError.record(error) }
    }
    _ = client.start()
    let probe = Task {
        do {
            let stream = try await client.openStream()
            try await stream.send(rpcPayload, endOfStream: true)
            let response = try await stream.receive(exactly: rpcPayload.count)
            guard response.content == rpcPayload else { throw BenchmarkError("Modern QUIC response mismatch.") }
            echoed.add(1)
        } catch { clientError.record(error) }
    }
    defer { probe.cancel() }

    let deadline = ContinuousClock.now + .seconds(8)
    while echoed.value == 0 {
        if let error = clientError.value ?? listenerError.value {
            throw BenchmarkError("Modern QUIC error: \(error); client=\(client.state); accepted=\(accepted.value).")
        }
        guard ContinuousClock.now < deadline else {
            throw BenchmarkError(
                "Modern QUIC 8 s watchdog expired; client=\(client.state); accepted=\(accepted.value); "
                + "worker_verifications=\(credentials.workerVerifications.value); control_verifications=\(credentials.controlVerifications.value)."
            )
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    guard credentials.workerVerifications.value > 0, credentials.controlVerifications.value > 0 else {
        throw BenchmarkError("Modern QUIC echo ran without both pinned certificate checks.")
    }
    print("modern_quic_probe=pass accepted=\(accepted.value) echo_bytes=\(rpcPayload.count) pinned_mutual_auth=pass")
}
