import Dispatch
import Foundation
import Network
import Security
import os

// Match the V3-14 label. Exporter values stay in memory.
private let exporterLabel = "EXPORTER-Hostwright-V3-14-Channel-Binding"
private let exporterLength = 32
private let unmatchedALPN = "hostwright-spike-alpn-mismatch/1"

func runSecurityProbes() async throws {
    for transport in SecurityProbeTransport.allCases {
        let credentials = try BenchmarkCredentials()
        let first = try await runSecurityProbe(transport, credentials: credentials, test: .pinned)
        let second = try await runSecurityProbe(transport, credentials: credentials, test: .pinned)
        guard let first = first.exporter, let second = second.exporter, first != second else {
            throw BenchmarkError("Two independent \(transport.rawValue) handshakes must yield distinct exporters.")
        }
        print("transport=\(transport.rawValue) exporter_sessions=2 distinct=yes")

        let control = try await runSecurityProbe(transport, credentials: credentials, test: .alpnMismatch)
        for test in [SecurityProbeCase.missing, .different] {
            let refusal = try await runSecurityProbe(transport, credentials: credentials, test: test)
            let worker = distinctErrors(refusal.observation.workerFailure.value, control.observation.workerFailure.value)
            let dialer = distinctErrors(refusal.observation.controlFailure.value, control.observation.controlFailure.value)
            print(
                "transport=\(transport.rawValue) case=\(test.rawValue) control=alpn_mismatch "
                    + "worker_error_distinct=\(worker) dialer_error_distinct=\(dialer)"
            )
        }
    }
}

private func distinctErrors(_ refusal: NWError?, _ control: NWError?) -> String {
    guard let refusal, let control else { return "unavailable" }
    return refusal == control ? "no" : "yes"
}

private func runSecurityProbe(
    _ transport: SecurityProbeTransport, credentials: BenchmarkCredentials, test: SecurityProbeCase
) async throws -> (exporter: Data?, observation: SecurityProbeObservation) {
    let observation = SecurityProbeObservation()
    let exporter: Data?
    switch transport {
    case .quic:
        exporter = try await probeQUIC(credentials, test: test, observation: observation)
    case .mux:
        exporter = try await probeMuxTLS(credentials, test: test, observation: observation)
    }
    return (exporter, observation)
}

private enum SecurityProbeTransport: String, CaseIterable {
    case quic, mux
}

private enum SecurityProbeCase: String {
    case pinned, missing, different
    case alpnMismatch = "alpn_mismatch"

    var clientIdentity: ProbeClientIdentity {
        switch self {
        case .pinned, .alpnMismatch: .pinned
        case .missing: .missing
        case .different: .different
        }
    }
}

private final class SecurityProbeObservation: Sendable {
    let controlReady = FirstValue<Bool>()
    let controlFailure = FirstValue<NWError>()
    let controlPinDecision = FirstValue<Bool>()
    let workerFailure = FirstValue<NWError>()
    let workerPinDecision = FirstValue<Bool>()
    let workerBytes = ByteCounter()
    let echo = FirstValue<Bool>()
    let quicWorkerStates = OSAllocatedUnfairLock(initialState: [NWConnectionGroup.State]())
    let quicDialerStates = OSAllocatedUnfairLock(initialState: [NWConnectionGroup.State]())
    let quicWorkerStreams = ByteCounter()

    func refusal(
        transport: SecurityProbeTransport, test: SecurityProbeCase,
        quicDialerState: NWConnectionGroup.State? = nil, quicClose: String? = nil
    ) throws -> String {
        try requireNoApplication(transport: transport)
        guard let workerError = workerFailure.value else {
            throw BenchmarkError("No conclusive \(transport.rawValue) worker failure for \(test.rawValue).")
        }
        switch test {
        case .different:
            guard controlPinDecision.value == true, workerPinDecision.value == false else {
                throw BenchmarkError("The dialer must verify the pinned worker and the worker must reject the different certificate.")
            }
        case .missing:
            guard controlPinDecision.value == true, workerPinDecision.value == nil else {
                throw BenchmarkError("The dialer must verify the worker, and the absent certificate must leave the worker pin callback uncalled.")
            }
        case .alpnMismatch:
            guard workerPinDecision.value != false, controlPinDecision.value != false else {
                throw BenchmarkError("The ALPN control encountered a certificate pin rejection.")
            }
        case .pinned:
            throw BenchmarkError("The authenticated probe is not a refusal case.")
        }
        let controlError = controlFailure.value.map(String.init(describing:)) ?? "none reported"
        let quicEvidence: String
        if let quicDialerState, let quicClose {
            quicEvidence = " worker_history=[\(quicHistory(quicWorkerStates))]"
                + " dialer_history=[\(quicHistory(quicDialerStates))] dialer_state=[\(quicDialerState)]"
                + " worker_ready=no worker_streams=0 quic_application_close=[\(quicClose)]"
        } else {
            quicEvidence = ""
        }
        return "transport=\(transport.rawValue) case=\(test.rawValue) client_cert=\(test.clientIdentity) refusal=pre_application "
            + "worker_pin=\(pinDescription(workerPinDecision.value)) dialer_pin=\(pinDescription(controlPinDecision.value)) "
            + "dialer_ready_before_refusal=\(controlReady.value == true ? "yes" : "no") worker_application_bytes=0 echo=none "
            + "worker_error=[\(workerError)] control_error=[\(controlError)]\(quicEvidence)"
    }

    func awaitHandshakeRefusal(transport: SecurityProbeTransport, test: SecurityProbeCase) async throws {
        do {
            try await pollFor("\(transport.rawValue) handshake refusal", timeout: .seconds(12)) {
                try requireNoApplication(transport: transport)
                return workerFailure.value != nil && (test == .alpnMismatch || controlFailure.value != nil)
            }
        } catch {
            if transport == .quic {
                throw BenchmarkError(
                    "\(error.localizedDescription) Worker QUIC group history: [\(quicHistory(quicWorkerStates))]. "
                        + "Dialer QUIC group history: [\(quicHistory(quicDialerStates))]."
                )
            }
            throw error
        }
    }

    func awaitEcho(transport: SecurityProbeTransport) async throws {
        try await pollFor("\(transport.rawValue) authenticated echo") {
            if let error = workerFailure.value ?? controlFailure.value { throw error }
            return echo.value != nil
        }
        guard echo.value == true, workerBytes.value == rpcPayload.count, bothPinsVerified else {
            throw BenchmarkError("Both pinned certificate checks and the authenticated echo must succeed.")
        }
    }

    var bothPinsVerified: Bool { workerPinDecision.value == true && controlPinDecision.value == true }

    private func quicHistory(_ history: OSAllocatedUnfairLock<[NWConnectionGroup.State]>) -> String {
        let states = history.withLock { $0 }
        return states.isEmpty ? "no_state_callbacks" : states.map(String.init(describing:)).joined(separator: " -> ")
    }

    private func requireNoApplication(transport: SecurityProbeTransport) throws {
        guard workerBytes.value == 0, echo.value == nil,
              !quicWorkerStates.withLock({ $0.contains(.ready) }), quicWorkerStreams.value == 0 else {
            throw BenchmarkError("Unexpected application or worker readiness in the \(transport.rawValue) refusal probe.")
        }
    }

    private func pinDescription(_ decision: Bool?) -> String {
        switch decision {
        case true?: "verified"
        case false?: "rejected"
        case nil: "not_called"
        }
    }
}

private func probeQUIC(
    _ credentials: BenchmarkCredentials, test: SecurityProbeCase, observation: SecurityProbeObservation
) async throws -> Data? {
    let serverParameters = try quicParameters(
        credentials, server: true, onPeerDecision: { observation.workerPinDecision.record($0) }
    )
    let listener = try NWListener(using: serverParameters)
    let worker = FirstValue<NWConnectionGroup>()
    let workerStream = FirstValue<NWConnection>()
    listener.newConnectionGroupHandler = { group in
        guard worker.value == nil else {
            group.cancel()
            return
        }
        worker.record(group)
        group.stateUpdateHandler = { state in
            observation.quicWorkerStates.withLock { $0.append(state) }
            if case .failed(let error) = state { observation.workerFailure.record(error) }
        }
        group.newConnectionHandler = { stream in
            observation.quicWorkerStreams.add(1)
            guard workerStream.value == nil else {
                stream.cancel()
                return
            }
            workerStream.record(stream)
            stream.start(queue: benchmarkQueue)
            receiveAndEcho(stream, observation: observation)
        }
        group.start(queue: benchmarkQueue)
    }
    listener.start(queue: benchmarkQueue)
    defer {
        workerStream.value?.cancel()
        worker.value?.cancel()
        listener.cancel()
    }
    let port = try await securityListenerPort(listener)
    let control = NWConnectionGroup(
        with: NWMultiplexGroup(to: .hostPort(host: loopback, port: port)),
        using: try quicParameters(
            credentials, server: false, clientIdentity: test.clientIdentity,
            alpn: test == .alpnMismatch ? unmatchedALPN : nil,
            onPeerDecision: { observation.controlPinDecision.record($0) }
        )
    )
    control.stateUpdateHandler = { state in
        observation.quicDialerStates.withLock { $0.append(state) }
        if case .ready = state { observation.controlReady.record(true) }
        if case .failed(let error) = state { observation.controlFailure.record(error) }
    }
    control.newConnectionHandler = { $0.cancel() }
    control.start(queue: benchmarkQueue)
    defer { control.cancel() }
    try await pollFor("QUIC dialer readiness or refusal", timeout: .seconds(12)) {
        control.state == .ready || observation.controlFailure.value != nil || observation.workerFailure.value != nil
    }
    if test != .pinned {
        let stream = control.state == .ready ? NWConnection(from: control) : nil
        if let stream {
            stream.start(queue: benchmarkQueue)
            sendAndReceiveEcho(stream, observation: observation)
        }
        defer { stream?.cancel() }
        try await observation.awaitHandshakeRefusal(transport: .quic, test: test)
        print(try observation.refusal(
            transport: .quic, test: test, quicDialerState: control.state,
            quicClose: "worker=\(quicApplicationClose(worker.value)) dialer=\(quicApplicationClose(control))"
        ))
        return nil
    }
    try await pollFor("QUIC mutual authentication on both endpoints") {
        if let error = observation.workerFailure.value ?? observation.controlFailure.value { throw error }
        return control.state == .ready && worker.value?.state == .ready
    }
    guard observation.bothPinsVerified else {
        throw BenchmarkError("Both QUIC peers must verify the pinned certificate before comparing exporters.")
    }
    guard let workerGroup = worker.value,
          let workerMetadata = workerGroup.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata,
          let controlMetadata = control.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata else {
        throw BenchmarkError("QUIC did not provide security metadata for both authenticated endpoints.")
    }
    return try checkExporter(
        transport: .quic, worker: workerMetadata.securityProtocolMetadata,
        control: controlMetadata.securityProtocolMetadata, applicationEcho: false
    )
}

private func probeMuxTLS(
    _ credentials: BenchmarkCredentials, test: SecurityProbeCase, observation: SecurityProbeObservation
) async throws -> Data? {
    let alpn = "hostwright-spike-mux/1"
    let workerTLS = try credentials.tlsOptions(
        server: true, alpn: alpn, onPeerDecision: { observation.workerPinDecision.record($0) }
    )
    let parameters = NWParameters(tls: workerTLS, tcp: muxTCPOptions())
    parameters.requiredLocalEndpoint = .hostPort(host: loopback, port: .any)
    parameters.acceptLocalOnly = true
    let listener = try NWListener(using: parameters)
    let worker = FirstValue<NWConnection>()
    listener.newConnectionHandler = { connection in
        guard worker.value == nil else {
            connection.cancel()
            return
        }
        worker.record(connection)
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state { observation.workerFailure.record(error) }
        }
        receiveAndEcho(connection, observation: observation)
        connection.start(queue: benchmarkQueue)
    }
    listener.start(queue: benchmarkQueue)
    defer {
        worker.value?.cancel()
        listener.cancel()
    }

    let port = try await securityListenerPort(listener)
    let controlTLS = try credentials.tlsOptions(
        server: false, alpn: test == .alpnMismatch ? unmatchedALPN : alpn,
        clientIdentity: test.clientIdentity, onPeerDecision: { observation.controlPinDecision.record($0) }
    )
    let control = NWConnection(host: loopback, port: port, using: NWParameters(tls: controlTLS, tcp: muxTCPOptions()))
    control.stateUpdateHandler = { state in
        if case .ready = state { observation.controlReady.record(true) }
        if case .failed(let error) = state { observation.controlFailure.record(error) }
    }
    sendAndReceiveEcho(control, observation: observation)
    control.start(queue: benchmarkQueue)
    defer { control.cancel() }

    if test != .pinned {
        try await observation.awaitHandshakeRefusal(transport: .mux, test: test)
        print(try observation.refusal(transport: .mux, test: test))
        return nil
    }
    try await observation.awaitEcho(transport: .mux)
    guard let workerMetadata = worker.value?.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
          let controlMetadata = control.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
        throw BenchmarkError("TLS mux did not provide security metadata for both authenticated endpoints.")
    }
    return try checkExporter(
        transport: .mux, worker: workerMetadata.securityProtocolMetadata,
        control: controlMetadata.securityProtocolMetadata, applicationEcho: true
    )
}

private func quicApplicationClose(_ group: NWConnectionGroup?) -> String {
    guard let metadata = group?.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata else {
        return "unavailable"
    }
    let close = metadata.applicationError
    guard close.code != 0 || close.reason != nil else { return "unavailable" }
    return "\(close.code) reason=\(close.reason ?? "none")"
}

private func securityListenerPort(_ listener: NWListener) async throws -> NWEndpoint.Port {
    try await pollFor("security probe listener") {
        if case .failed(let error) = listener.state { throw error }
        return listener.state == .ready
    }
    guard let port = listener.port else { throw BenchmarkError("The security probe has no bound loopback port.") }
    return port
}

private func receiveAndEcho(_ connection: NWConnection, observation: SecurityProbeObservation) {
    connection.receive(minimumIncompleteLength: rpcPayload.count, maximumLength: rpcPayload.count) {
        [weak connection] data, _, _, _ in
        guard let data, !data.isEmpty else { return }
        observation.workerBytes.add(data.count)
        connection?.send(
            content: data, contentContext: .init(identifier: "hostwright-spike-security"),
            isComplete: true, completion: .contentProcessed { _ in }
        )
    }
}

private func sendAndReceiveEcho(_ connection: NWConnection, observation: SecurityProbeObservation) {
    connection.send(
        content: rpcPayload, contentContext: .init(identifier: "hostwright-spike-security"),
        isComplete: true, completion: .contentProcessed { _ in }
    )
    connection.receive(minimumIncompleteLength: rpcPayload.count, maximumLength: rpcPayload.count) { data, _, _, _ in
        if let data, !data.isEmpty { observation.echo.record(data == rpcPayload) }
    }
}

private func checkExporter(
    transport: SecurityProbeTransport, worker: sec_protocol_metadata_t, control: sec_protocol_metadata_t,
    applicationEcho: Bool
) throws -> Data {
    guard sec_protocol_metadata_get_negotiated_tls_protocol_version(worker) == .TLSv13,
          sec_protocol_metadata_get_negotiated_tls_protocol_version(control) == .TLSv13 else {
        throw BenchmarkError("The \(transport.rawValue) probe did not negotiate TLS 1.3 on both sides.")
    }
    guard let workerSecret = exporter(worker), let controlSecret = exporter(control),
          workerSecret.count == exporterLength, workerSecret == controlSecret else {
        throw BenchmarkError("The \(transport.rawValue) exporter did not match.")
    }
    let echo = applicationEcho ? "matched" : "not_checked"
    print(
        "transport=\(transport.rawValue) client_cert=pinned tls=1.3 mutual_pins=verified echo=\(echo) "
            + "exporter_api=sec_protocol_metadata_create_secret label=\(exporterLabel) "
            + "worker_bytes=\(workerSecret.count) control_bytes=\(controlSecret.count) match=yes"
    )
    return workerSecret
}

private func exporter(_ metadata: sec_protocol_metadata_t) -> Data? {
    exporterLabel.withCString { label in
        sec_protocol_metadata_create_secret(metadata, exporterLabel.utf8.count, label, exporterLength)
            .map { Data($0 as DispatchData) }
    }
}
