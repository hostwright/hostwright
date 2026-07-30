import CryptoKit
import Foundation
import HostwrightNetworking
@preconcurrency import Network
@preconcurrency import Security

enum HostwrightTunnelSocketError: Error, Equatable {
    case invalidCredentials
    case deadlineExceeded
    case cancelled
    case connectionFailed
    case backpressure
    case malformedFrame
    case replay
    case drained
}

final class HostwrightTunnelCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.withLock { value }
    }

    func cancel() {
        lock.withLock { value = true }
    }
}

struct HostwrightTunnelServerPeerVerifier: @unchecked Sendable {
    let policy: NetworkHelperMutualTLSPolicy
}

struct HostwrightTunnelClientPeerVerifier: @unchecked Sendable {
    let trustAnchors: [SecCertificate]
    let dnsName: String
    let certificateSHA256: String
}

enum HostwrightTunnelPeerVerifier: @unchecked Sendable {
    case client(HostwrightTunnelClientPeerVerifier)
    case server(HostwrightTunnelServerPeerVerifier)
}

struct HostwrightTunnelTLSCredentials: @unchecked Sendable {
    let localIdentity: CertificateIdentityHandle
    let peerVerifier: HostwrightTunnelPeerVerifier
}

struct HostwrightTunnelLoopbackCredentials: @unchecked Sendable {
    let client: HostwrightTunnelTLSCredentials
    let server: HostwrightTunnelTLSCredentials
}

/// Narrow adapter over the existing certificate coordinator. It exposes only
/// the already-activated server identity, managed tunnel peer identity, and
/// exact mutual-TLS policy needed by this transport.
struct HostwrightTunnelCertificateCoordinatorAdapter {
    let coordinator: NetworkHelperCertificateCoordinator

    func loopbackCredentials(
        identity: NetworkHelperDNSIdentity,
        bindingName: String,
        peerIdentityURI: String
    ) throws -> HostwrightTunnelLoopbackCredentials {
        guard
            let activation = coordinator.activation(identity: identity),
            let server = activation.identities[bindingName],
            let client = activation.peerIdentities[
                "\(bindingName)/\(peerIdentityURI)"
            ],
            let serverPolicy =
                activation.currentMutualTLSPolicies[bindingName],
            let trustAnchor = server.certificateChain.last,
            let dnsName = server.metadata.dnsNames.first,
            !dnsName.isEmpty
        else {
            throw HostwrightTunnelSocketError.invalidCredentials
        }
        return HostwrightTunnelLoopbackCredentials(
            client: HostwrightTunnelTLSCredentials(
                localIdentity: client,
                peerVerifier: .client(
                    HostwrightTunnelClientPeerVerifier(
                        trustAnchors: [trustAnchor],
                        dnsName: dnsName,
                        certificateSHA256:
                            server.metadata.certificateSHA256
                    )
                )
            ),
            server: HostwrightTunnelTLSCredentials(
                localIdentity: server,
                peerVerifier: .server(
                    HostwrightTunnelServerPeerVerifier(
                        policy: serverPolicy
                    )
                )
            )
        )
    }
}

private enum HostwrightTunnelWireKind: UInt8 {
    case data = 1
    case ping = 2
    case pong = 3
    case drain = 4
}

private struct HostwrightTunnelWireMessage {
    let kind: HostwrightTunnelWireKind
    let routeUUID: String
    let generation: Int64
    let fencingToken: String
    let channel: Int
    let sequence: UInt64
    let payload: Data
}

private enum HostwrightTunnelFrameCodec {
    static let maximumWireBytes =
        HostwrightTunnelFrame.maximumPayloadBytes + 128
    private static let fixedBodyBytes = 56

    static func encode(
        _ message: HostwrightTunnelWireMessage
    ) throws -> Data {
        guard
            let route = UUID(uuidString: message.routeUUID),
            route.uuidString.lowercased() == message.routeUUID,
            let fence = UUID(uuidString: message.fencingToken),
            fence.uuidString.lowercased() == message.fencingToken,
            message.generation > 0,
            (0..<HostwrightTunnelFrame.maximumChannels)
                .contains(message.channel),
            message.payload.count <=
                HostwrightTunnelFrame.maximumPayloadBytes,
            message.kind != .data || !message.payload.isEmpty,
            message.kind == .data || message.payload.isEmpty
        else {
            throw HostwrightTunnelSocketError.malformedFrame
        }

        var body = Data()
        body.reserveCapacity(fixedBodyBytes + message.payload.count)
        body.append(1)
        body.append(message.kind.rawValue)
        appendUUID(route, to: &body)
        append(UInt64(bitPattern: message.generation), to: &body)
        appendUUID(fence, to: &body)
        append(UInt16(message.channel), to: &body)
        append(message.sequence, to: &body)
        append(UInt32(message.payload.count), to: &body)
        body.append(message.payload)
        guard body.count <= maximumWireBytes else {
            throw HostwrightTunnelSocketError.malformedFrame
        }
        var wire = Data()
        append(UInt32(body.count), to: &wire)
        wire.append(body)
        return wire
    }

    static func next(
        from buffer: inout Data
    ) throws -> HostwrightTunnelWireMessage? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(readUInt32(buffer, at: 0))
        guard length >= fixedBodyBytes,
              length <= maximumWireBytes else {
            throw HostwrightTunnelSocketError.malformedFrame
        }
        guard buffer.count >= length + 4 else { return nil }
        let body = buffer.subdata(in: 4..<(length + 4))
        buffer.removeSubrange(0..<(length + 4))
        guard body[0] == 1,
              let kind = HostwrightTunnelWireKind(rawValue: body[1]),
              let route = readUUID(body, at: 2),
              let fence = readUUID(body, at: 26) else {
            throw HostwrightTunnelSocketError.malformedFrame
        }
        let generationBits = readUInt64(body, at: 18)
        let generation = Int64(bitPattern: generationBits)
        let channel = Int(readUInt16(body, at: 42))
        let sequence = readUInt64(body, at: 44)
        let payloadLength = Int(readUInt32(body, at: 52))
        guard generation > 0,
              (0..<HostwrightTunnelFrame.maximumChannels)
                .contains(channel),
              payloadLength <=
                HostwrightTunnelFrame.maximumPayloadBytes,
              body.count == fixedBodyBytes + payloadLength else {
            throw HostwrightTunnelSocketError.malformedFrame
        }
        let payload = body.subdata(
            in: fixedBodyBytes..<body.count
        )
        guard kind != .data || !payload.isEmpty,
              kind == .data || payload.isEmpty else {
            throw HostwrightTunnelSocketError.malformedFrame
        }
        return HostwrightTunnelWireMessage(
            kind: kind,
            routeUUID: route.uuidString.lowercased(),
            generation: generation,
            fencingToken: fence.uuidString.lowercased(),
            channel: channel,
            sequence: sequence,
            payload: payload
        )
    }

    private static func appendUUID(
        _ value: UUID,
        to data: inout Data
    ) {
        var bytes = value.uuid
        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
    }

    private static func readUUID(
        _ data: Data,
        at offset: Int
    ) -> UUID? {
        guard data.count >= offset + 16 else { return nil }
        var bytes: uuid_t = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
        _ = withUnsafeMutableBytes(of: &bytes) {
            data.copyBytes(
                to: $0,
                from: offset..<(offset + 16)
            )
        }
        return UUID(uuid: bytes)
    }

    private static func append<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) {
            data.append(contentsOf: $0)
        }
    }

    private static func readUInt16(
        _ data: Data,
        at offset: Int
    ) -> UInt16 {
        read(data, at: offset, as: UInt16.self)
    }

    private static func readUInt32(
        _ data: Data,
        at offset: Int
    ) -> UInt32 {
        read(data, at: offset, as: UInt32.self)
    }

    private static func readUInt64(
        _ data: Data,
        at offset: Int
    ) -> UInt64 {
        read(data, at: offset, as: UInt64.self)
    }

    private static func read<T: FixedWidthInteger>(
        _ data: Data,
        at offset: Int,
        as type: T.Type
    ) -> T {
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) {
            data.copyBytes(
                to: $0,
                from: offset..<(offset + MemoryLayout<T>.size)
            )
        }
        return T(bigEndian: value)
    }
}

final class HostwrightServiceTunnelConnection: @unchecked Sendable {
    static let maximumOutstandingBytes = 1_048_576
    static let maximumOutstandingFrames = 128

    private enum State: Equatable {
        case active
        case draining
        case closed
    }

    let route: HostwrightTunnelRoute
    let transport: HostwrightTunnelTransport
    private let connection: NetworkHelperTLSConnection
    private let stateLock = NSLock()
    private let sendLock = NSLock()
    private let receiveLock = NSLock()
    private var state = State.active
    private var sendSequence: [Int: UInt64] = [:]
    private var receiveSequence: [Int: UInt64] = [:]
    private var outstandingBytes = 0
    private var outstandingFrames = 0
    private var receiveBuffer = Data()
    private var keepaliveTimer: DispatchSourceTimer?

    init(
        route: HostwrightTunnelRoute,
        transport: HostwrightTunnelTransport,
        connection: NetworkHelperTLSConnection
    ) {
        self.route = route
        self.transport = transport
        self.connection = connection
    }

    deinit {
        cancel()
    }

    @discardableResult
    func send(
        channel: Int,
        payload: Data,
        deadlineUnixMilliseconds: Int64,
        cancellation: HostwrightTunnelCancellation? = nil
    ) throws -> HostwrightTunnelFrame {
        try check(
            deadlineUnixMilliseconds: deadlineUnixMilliseconds,
            cancellation: cancellation
        )
        guard
            (0..<HostwrightTunnelFrame.maximumChannels)
                .contains(channel),
            !payload.isEmpty,
            payload.count <=
                HostwrightTunnelFrame.maximumPayloadBytes
        else {
            throw HostwrightTunnelSocketError.malformedFrame
        }
        return try sendLock.withLock {
            let sequence = (sendSequence[channel] ?? 0) + 1
            let frame = try HostwrightTunnelFrame(
                routeUUID: route.routeUUID,
                generation: route.generation,
                fencingToken: route.fencingToken,
                channel: channel,
                sequence: sequence,
                payload: payload
            )
            let wire = try HostwrightTunnelFrameCodec.encode(
                HostwrightTunnelWireMessage(
                    kind: .data,
                    routeUUID: frame.routeUUID,
                    generation: frame.generation,
                    fencingToken: frame.fencingToken,
                    channel: frame.channel,
                    sequence: frame.sequence,
                    payload: frame.payload
                )
            )
            try reserve(wire.count)
            defer { release(wire.count) }
            let timeout = try remaining(
                deadlineUnixMilliseconds,
                cancellation: cancellation
            )
            guard connection.send(
                wire,
                timeoutMilliseconds: timeout
            ) else {
                cancel()
                throw HostwrightTunnelSocketError.connectionFailed
            }
            sendSequence[channel] = sequence
            return frame
        }
    }

    func receive(
        deadlineUnixMilliseconds: Int64,
        cancellation: HostwrightTunnelCancellation? = nil
    ) throws -> HostwrightTunnelFrame? {
        try receiveLock.withLock {
            while true {
                try check(
                    deadlineUnixMilliseconds:
                        deadlineUnixMilliseconds,
                    cancellation: cancellation
                )
                if let message = try HostwrightTunnelFrameCodec.next(
                    from: &receiveBuffer
                ) {
                    guard
                        message.routeUUID == route.routeUUID,
                        message.generation == route.generation,
                        message.fencingToken == route.fencingToken
                    else {
                        cancel()
                        throw HostwrightTunnelSocketError.replay
                    }
                    switch message.kind {
                    case .ping:
                        // A peer may have sent its final drain immediately
                        // after this ping. A failed pong must not discard the
                        // already-authenticated drain frame buffered behind it.
                        try? sendControl(
                            .pong,
                            deadlineUnixMilliseconds:
                                deadlineUnixMilliseconds,
                            cancellation: cancellation
                        )
                        continue
                    case .pong:
                        continue
                    case .drain:
                        stateLock.withLock {
                            if state != .closed {
                                state = .draining
                            }
                        }
                        return nil
                    case .data:
                        if let prior =
                            receiveSequence[message.channel],
                           message.sequence <= prior {
                            cancel()
                            throw HostwrightTunnelSocketError.replay
                        }
                        let frame = try HostwrightTunnelFrame(
                            routeUUID: message.routeUUID,
                            generation: message.generation,
                            fencingToken: message.fencingToken,
                            channel: message.channel,
                            sequence: message.sequence,
                            payload: message.payload
                        )
                        receiveSequence[message.channel] =
                            message.sequence
                        return frame
                    }
                }
                let timeout = try remaining(
                    deadlineUnixMilliseconds,
                    cancellation: cancellation
                )
                guard let chunk = connection.receive(
                    maximumLength:
                        HostwrightTunnelFrameCodec.maximumWireBytes,
                    timeoutMilliseconds: timeout
                ) else {
                    cancel()
                    throw HostwrightTunnelSocketError.connectionFailed
                }
                if chunk.isEmpty { continue }
                guard receiveBuffer.count + chunk.count <=
                    HostwrightTunnelFrameCodec.maximumWireBytes * 2
                else {
                    cancel()
                    throw HostwrightTunnelSocketError.backpressure
                }
                receiveBuffer.append(chunk)
            }
        }
    }

    func startKeepalive(
        intervalMilliseconds: Int64 = 15_000
    ) throws {
        guard intervalMilliseconds >= 1_000 else {
            throw HostwrightTunnelSocketError.deadlineExceeded
        }
        stateLock.lock()
        guard state == .active, keepaliveTimer == nil else {
            stateLock.unlock()
            throw HostwrightTunnelSocketError.drained
        }
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(
                label: "dev.hostwright.service-tunnel.keepalive"
            )
        )
        keepaliveTimer = timer
        stateLock.unlock()
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                try sendControl(
                    .ping,
                    deadlineUnixMilliseconds:
                        Self.nowMilliseconds()
                        + intervalMilliseconds / 2,
                    cancellation: nil
                )
            } catch {
                cancel()
            }
        }
        timer.schedule(
            deadline: .now()
                + .milliseconds(Int(intervalMilliseconds)),
            repeating: .milliseconds(Int(intervalMilliseconds))
        )
        timer.activate()
    }

    func drain(
        deadlineUnixMilliseconds: Int64
    ) throws {
        let shouldDrain = stateLock.withLock {
            guard state == .active else { return false }
            state = .draining
            return true
        }
        guard shouldDrain else { return }
        try sendControl(
            .drain,
            deadlineUnixMilliseconds: deadlineUnixMilliseconds,
            cancellation: nil,
            allowDraining: true
        )
        let timeout = try remaining(
            deadlineUnixMilliseconds,
            cancellation: nil
        )
        guard connection.finishSending(
            timeoutMilliseconds: timeout
        ) else {
            cancel()
            throw HostwrightTunnelSocketError.connectionFailed
        }
    }

    func cancel() {
        let timer = stateLock.withLock { () -> DispatchSourceTimer? in
            guard state != .closed else { return nil }
            state = .closed
            let timer = keepaliveTimer
            keepaliveTimer = nil
            return timer
        }
        timer?.cancel()
        connection.cancel()
    }

    private func sendControl(
        _ kind: HostwrightTunnelWireKind,
        deadlineUnixMilliseconds: Int64,
        cancellation: HostwrightTunnelCancellation?,
        allowDraining: Bool = false
    ) throws {
        try sendLock.withLock {
            try check(
                deadlineUnixMilliseconds:
                    deadlineUnixMilliseconds,
                cancellation: cancellation,
                allowDraining: allowDraining
            )
            let wire = try HostwrightTunnelFrameCodec.encode(
                HostwrightTunnelWireMessage(
                    kind: kind,
                    routeUUID: route.routeUUID,
                    generation: route.generation,
                    fencingToken: route.fencingToken,
                    channel: 0,
                    sequence: 0,
                    payload: Data()
                )
            )
            try reserve(wire.count)
            defer { release(wire.count) }
            guard connection.send(
                wire,
                timeoutMilliseconds: try remaining(
                    deadlineUnixMilliseconds,
                    cancellation: cancellation
                )
            ) else {
                throw HostwrightTunnelSocketError.connectionFailed
            }
        }
    }

    private func reserve(_ bytes: Int) throws {
        try stateLock.withLock {
            guard outstandingFrames <
                    Self.maximumOutstandingFrames,
                  outstandingBytes <=
                    Self.maximumOutstandingBytes - bytes else {
                throw HostwrightTunnelSocketError.backpressure
            }
            outstandingFrames += 1
            outstandingBytes += bytes
        }
    }

    private func release(_ bytes: Int) {
        stateLock.withLock {
            outstandingFrames -= 1
            outstandingBytes -= bytes
        }
    }

    private func check(
        deadlineUnixMilliseconds: Int64,
        cancellation: HostwrightTunnelCancellation?,
        allowDraining: Bool = false
    ) throws {
        if cancellation?.isCancelled == true {
            cancel()
            throw HostwrightTunnelSocketError.cancelled
        }
        guard Self.nowMilliseconds() <
                deadlineUnixMilliseconds else {
            throw HostwrightTunnelSocketError.deadlineExceeded
        }
        let usable = stateLock.withLock {
            state == .active
                || (allowDraining && state == .draining)
        }
        guard usable else {
            throw HostwrightTunnelSocketError.drained
        }
    }

    private func remaining(
        _ deadline: Int64,
        cancellation: HostwrightTunnelCancellation?
    ) throws -> Int64 {
        if cancellation?.isCancelled == true {
            cancel()
            throw HostwrightTunnelSocketError.cancelled
        }
        let value = deadline - Self.nowMilliseconds()
        guard value > 0 else {
            throw HostwrightTunnelSocketError.deadlineExceeded
        }
        return value
    }

    static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

final class HostwrightServiceTunnelDialer: Sendable {
    private static let directAttemptBudgetMilliseconds:
        Int64 = 1_000
    typealias CredentialsProvider = @Sendable (
        HostwrightTunnelRoute,
        HostwrightTunnelEndpoint,
        HostwrightTunnelTransport
    ) throws -> HostwrightTunnelTLSCredentials

    private let credentials: CredentialsProvider

    init(credentials: @escaping CredentialsProvider) {
        self.credentials = credentials
    }

    func connect(
        route: HostwrightTunnelRoute,
        directCandidates: [HostwrightTunnelEndpoint]? = nil,
        deadlineUnixMilliseconds: Int64,
        cancellation: HostwrightTunnelCancellation? = nil
    ) throws -> HostwrightServiceTunnelConnection {
        let declared = Set(route.authenticatedEndpoints)
        let direct = (directCandidates ?? route.authenticatedEndpoints)
            .filter { declared.contains($0) }
        for endpoint in direct {
            if cancellation?.isCancelled == true {
                throw HostwrightTunnelSocketError.cancelled
            }
            if let result = try? connect(
                route: route,
                endpoint: endpoint,
                transport: .direct,
                deadlineUnixMilliseconds:
                    min(
                        deadlineUnixMilliseconds,
                        HostwrightServiceTunnelConnection
                            .nowMilliseconds()
                            + Self
                                .directAttemptBudgetMilliseconds
                    ),
                cancellation: cancellation
            ) {
                return result
            }
        }
        if let relay = route.relayEndpoint {
            return try connect(
                route: route,
                endpoint: relay,
                transport: .relay,
                deadlineUnixMilliseconds:
                    deadlineUnixMilliseconds,
                cancellation: cancellation
            )
        }
        if cancellation?.isCancelled == true {
            throw HostwrightTunnelSocketError.cancelled
        }
        guard HostwrightServiceTunnelConnection.nowMilliseconds()
                < deadlineUnixMilliseconds else {
            throw HostwrightTunnelSocketError.deadlineExceeded
        }
        throw HostwrightTunnelSocketError.connectionFailed
    }

    private func connect(
        route: HostwrightTunnelRoute,
        endpoint: HostwrightTunnelEndpoint,
        transport: HostwrightTunnelTransport,
        deadlineUnixMilliseconds: Int64,
        cancellation: HostwrightTunnelCancellation?
    ) throws -> HostwrightServiceTunnelConnection {
        guard
            let port = NWEndpoint.Port(
                rawValue: UInt16(endpoint.port)
            )
        else {
            throw HostwrightTunnelSocketError.connectionFailed
        }
        let credentials = try credentials(
            route,
            endpoint,
            transport
        )
        let parameters = try HostwrightTunnelTLS.parameters(
            credentials: credentials,
            localEndpoint: nil
        )
        let raw = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: parameters
        )
        let connection = NetworkHelperTLSConnection(
            connection: raw,
            label: "service-tunnel-client"
        )
        if cancellation?.isCancelled == true {
            connection.cancel()
            throw HostwrightTunnelSocketError.cancelled
        }
        let remaining = deadlineUnixMilliseconds
            - HostwrightServiceTunnelConnection.nowMilliseconds()
        let cancellationWatcher = cancellation.map { token in
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(
                    label:
                        "dev.hostwright.service-tunnel.cancellation"
                )
            )
            timer.setEventHandler {
                if token.isCancelled {
                    connection.cancel()
                }
            }
            timer.schedule(
                deadline: .now(),
                repeating: .milliseconds(10)
            )
            timer.activate()
            return timer
        }
        defer { cancellationWatcher?.cancel() }
        guard remaining > 0,
              connection.start(
                timeoutMilliseconds: remaining
              ) else {
            connection.cancel()
            if cancellation?.isCancelled == true {
                throw HostwrightTunnelSocketError.cancelled
            }
            throw HostwrightTunnelSocketError.connectionFailed
        }
        return HostwrightServiceTunnelConnection(
            route: route,
            transport: transport,
            connection: connection
        )
    }
}

final class HostwrightServiceTunnelListener: @unchecked Sendable {
    private let route: HostwrightTunnelRoute
    private let listener: NWListener
    private let queue = DispatchQueue(
        label: "dev.hostwright.service-tunnel.listener",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private let accepted = DispatchSemaphore(value: 0)
    private var pending:
        [HostwrightServiceTunnelConnection] = []
    private var stopped = false

    init(
        route: HostwrightTunnelRoute,
        credentials: HostwrightTunnelTLSCredentials,
        host: String = "127.0.0.1",
        port: Int = 0
    ) throws {
        guard (0...65_535).contains(port),
              let endpointPort = NWEndpoint.Port(
                rawValue: UInt16(port)
              ) else {
            throw HostwrightTunnelSocketError.connectionFailed
        }
        self.route = route
        listener = try NWListener(
            using: HostwrightTunnelTLS.parameters(
                credentials: credentials,
                localEndpoint: .hostPort(
                    host: NWEndpoint.Host(host),
                    port: endpointPort
                )
            )
        )
        listener.newConnectionHandler = { [weak self] raw in
            self?.accept(raw)
        }
    }

    var port: Int? {
        listener.port.map { Int($0.rawValue) }
    }

    func start(
        deadlineUnixMilliseconds: Int64
    ) throws {
        let completed = DispatchSemaphore(value: 0)
        let result = HostwrightTunnelLockedValue<Bool?>(nil)
        listener.stateUpdateHandler = { state in
            let resolved: Bool?
            switch state {
            case .ready: resolved = true
            case .failed, .cancelled: resolved = false
            case .setup, .waiting: resolved = nil
            @unknown default: resolved = false
            }
            guard let resolved else { return }
            let first = result.update {
                guard $0 == nil else { return false }
                $0 = resolved
                return true
            }
            if first { completed.signal() }
        }
        listener.start(queue: queue)
        let remaining = deadlineUnixMilliseconds
            - HostwrightServiceTunnelConnection.nowMilliseconds()
        guard remaining > 0,
              completed.wait(
                timeout: .now()
                    + .milliseconds(Int(remaining))
              ) == .success,
              result.read() == true else {
            stop()
            throw HostwrightTunnelSocketError.connectionFailed
        }
    }

    func next(
        deadlineUnixMilliseconds: Int64
    ) throws -> HostwrightServiceTunnelConnection {
        let remaining = deadlineUnixMilliseconds
            - HostwrightServiceTunnelConnection.nowMilliseconds()
        guard remaining > 0,
              accepted.wait(
                timeout: .now()
                    + .milliseconds(Int(remaining))
              ) == .success else {
            throw HostwrightTunnelSocketError.deadlineExceeded
        }
        return try lock.withLock {
            guard !pending.isEmpty else {
                throw HostwrightTunnelSocketError.connectionFailed
            }
            return pending.removeFirst()
        }
    }

    func stop() {
        let connections = lock.withLock {
            guard !stopped else {
                return [HostwrightServiceTunnelConnection]()
            }
            stopped = true
            let values = pending
            pending.removeAll()
            return values
        }
        listener.cancel()
        connections.forEach { $0.cancel() }
    }

    private func accept(_ raw: NWConnection) {
        let connection = NetworkHelperTLSConnection(
            connection: raw,
            label: "service-tunnel-server"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            [weak self] in
            guard let self,
                  connection.start(timeoutMilliseconds: 5_000)
            else {
                connection.cancel()
                return
            }
            let wrapped = HostwrightServiceTunnelConnection(
                route: route,
                transport: .direct,
                connection: connection
            )
            let enqueued = lock.withLock {
                guard !stopped, pending.count < 8 else {
                    return false
                }
                pending.append(wrapped)
                return true
            }
            if enqueued {
                accepted.signal()
            } else {
                wrapped.cancel()
            }
        }
    }
}

private enum HostwrightTunnelTLS {
    static func parameters(
        credentials: HostwrightTunnelTLSCredentials,
        localEndpoint: NWEndpoint?
    ) throws -> NWParameters {
        let wireIdentity = try localIdentity(credentials)
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            options.securityProtocolOptions,
            .TLSv13
        )
        sec_protocol_options_set_max_tls_protocol_version(
            options.securityProtocolOptions,
            .TLSv13
        )
        sec_protocol_options_add_tls_application_protocol(
            options.securityProtocolOptions,
            "hostwright-tunnel/1"
        )
        sec_protocol_options_set_local_identity(
            options.securityProtocolOptions,
            wireIdentity
        )
        sec_protocol_options_set_peer_authentication_required(
            options.securityProtocolOptions,
            true
        )
        let queue = DispatchQueue(
            label: "dev.hostwright.service-tunnel.verify",
            qos: .userInitiated
        )
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, wireTrust, completion in
                let trust = sec_trust_copy_ref(wireTrust)
                    .takeRetainedValue()
                switch credentials.peerVerifier {
                case .server(let verifier):
                    completion(verifier.policy.evaluate(trust))
                case .client(let verifier):
                    completion(evaluateServer(
                        trust,
                        verifier: verifier
                    ))
                }
            },
            queue
        )
        let parameters = NWParameters(
            tls: options,
            tcp: NWProtocolTCP.Options()
        )
        parameters.allowLocalEndpointReuse = false
        if let localEndpoint {
            parameters.requiredLocalEndpoint = localEndpoint
            parameters.acceptLocalOnly = true
        }
        return parameters
    }

    private static func evaluateServer(
        _ trust: SecTrust,
        verifier: HostwrightTunnelClientPeerVerifier
    ) -> Bool {
        guard
            !verifier.trustAnchors.isEmpty,
            verifier.certificateSHA256.utf8.count == 64,
            SecTrustSetPolicies(
                trust,
                SecPolicyCreateSSL(
                    true,
                    verifier.dnsName as CFString
                )
            ) == errSecSuccess,
            SecTrustSetAnchorCertificates(
                trust,
                verifier.trustAnchors as CFArray
            ) == errSecSuccess,
            SecTrustSetAnchorCertificatesOnly(
                trust,
                true
            ) == errSecSuccess,
            SecTrustSetNetworkFetchAllowed(
                trust,
                false
            ) == errSecSuccess
        else {
            return false
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error),
              let chain = SecTrustCopyCertificateChain(trust)
                as? [SecCertificate],
              let leaf = chain.first else {
            return false
        }
        let fingerprint = SHA256.hash(
            data: SecCertificateCopyData(leaf) as Data
        ).map {
            String(format: "%02x", $0)
        }.joined()
        return fingerprint == verifier.certificateSHA256
    }

    private static func localIdentity(
        _ credentials: HostwrightTunnelTLSCredentials
    ) throws -> sec_identity_t {
        let handle = credentials.localIdentity
        let metadata = handle.metadata
        let now = Date()
        let requiresServerUsage: Bool
        switch credentials.peerVerifier {
        case .server:
            requiresServerUsage = true
        case .client:
            requiresServerUsage = false
        }
        guard
            metadata.revocationStatus != .suppliedRevoked,
            metadata.notValidBefore <= now,
            metadata.notValidAfter > now,
            requiresServerUsage
                ? metadata.supportsServerAuthentication
                : metadata.supportsClientAuthentication
        else {
            throw HostwrightTunnelSocketError.invalidCredentials
        }
        var certificate: SecCertificate?
        guard
            SecIdentityCopyCertificate(
                handle.identity,
                &certificate
            ) == errSecSuccess,
            let certificate
        else {
            throw HostwrightTunnelSocketError.invalidCredentials
        }
        let fingerprint = SHA256.hash(
            data: SecCertificateCopyData(certificate) as Data
        ).map {
            String(format: "%02x", $0)
        }.joined()
        guard fingerprint == metadata.certificateSHA256 else {
            throw HostwrightTunnelSocketError.invalidCredentials
        }
        let wire: sec_identity_t?
        if handle.certificateChain.isEmpty {
            wire = sec_identity_create(handle.identity)
        } else {
            wire = sec_identity_create_with_certificates(
                handle.identity,
                handle.certificateChain as CFArray
            )
        }
        guard let wire else {
            throw HostwrightTunnelSocketError.invalidCredentials
        }
        return wire
    }
}

private final class HostwrightTunnelLockedValue<Value>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value {
        lock.withLock { value }
    }

    func update<Result>(
        _ body: (inout Value) -> Result
    ) -> Result {
        lock.withLock { body(&value) }
    }
}
