import Dispatch
import Foundation
import Network

enum VMProbeTransport {
    case tcp
    case quic(Data)

    var prefix: String {
        switch self {
        case .tcp: ""
        case .quic: "quic "
        }
    }
}

enum VMProbe {
    static let version = {
        #if HOSTWRIGHT_V314_BUILD_2
        "2"
        #else
        "1"
        #endif
    }()
    static let request = Data("hostwright-v314\n".utf8)
    static let reply = Data("hostwright-v314-ok\n".utf8)

    static func endpoint(_ address: String, _ portValue: String) throws -> (NWEndpoint.Host, NWEndpoint.Port) {
        guard let address = IPv4Address(address), address != .any,
              let number = UInt16(portValue), let port = NWEndpoint.Port(rawValue: number) else {
            throw ProbeFailure("Expected an explicit IPv4 address and a port from 0 through 65535")
        }
        return (.ipv4(address), port)
    }

    static func listen(_ host: NWEndpoint.Host, _ port: NWEndpoint.Port) throws -> Never {
        let queue = DispatchQueue(label: "dev.hostwright.v314.listen")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { connection in
            respond(to: connection, on: queue)
        }
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready:
                record("listen ready port=\(listener.port?.rawValue ?? 0)")
            case .failed(let error):
                record("listen failed error=\(error)")
                exit(1)
            default:
                break
            }
        }
        listener.start(queue: queue)
        dispatchMain()
    }

    static func respond(
        to connection: NWConnection, on queue: DispatchQueue, prefix: String = "", keepOpen: Bool = false
    ) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: request.count, maximumLength: request.count) { received, _, _, error in
            guard error == nil, received == request else {
                connection.cancel()
                return
            }
            connection.send(content: reply, completion: .contentProcessed { error in
                if error == nil {
                    record("\(prefix)listen reply=ok")
                }
                // Cancelling a QUIC stream immediately can reset it before the peer reads the reply.
                if error != nil || !keepOpen {
                    connection.cancel()
                }
            })
        }
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
    }

    static func dial(
        _ host: NWEndpoint.Host, _ port: NWEndpoint.Port, transport: VMProbeTransport = .tcp, once: Bool
    ) throws -> Never {
        guard port != .any else { throw ProbeFailure("Dial requires a nonzero port") }
        VMProbeDialer(host: host, port: port, transport: transport, once: once).start()
        dispatchMain()
    }

    static func record(_ event: String) {
        log("\(Date().ISO8601Format()) build=\(version) \(event)")
    }
}

private final class VMProbeDialer: @unchecked Sendable {
    private final class Attempt: @unchecked Sendable {
        var connection: NWConnection?

        func cancel() {
            connection?.stateUpdateHandler = nil
            connection?.pathUpdateHandler = nil
            connection?.cancel()
        }
    }

    private let queue = DispatchQueue(label: "dev.hostwright.v314.dial")
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let transport: VMProbeTransport
    private let once: Bool
    private var active: Attempt?

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, transport: VMProbeTransport, once: Bool) {
        self.host = host
        self.port = port
        self.transport = transport
        self.once = once
    }

    func start() {
        queue.async { self.connect() }
    }

    // The queue serializes path, trust, completion, and retry callbacks.
    private func connect() {
        let attempt = Attempt()
        active = attempt
        record("start")
        let parameters: NWParameters
        switch transport {
        case .tcp:
            parameters = .tcp
        case .quic(let pin):
            parameters = VMQUICProbe.dialParameters(pin: pin, queue: queue) { [self, weak attempt] in
                if let attempt {
                    finish(attempt, result: "rejected reference certificate", success: false)
                }
            }
        }

        // The direct QUIC NWConnection exposes the handshake's own path. The listener accepts its stream via a group.
        let connection = NWConnection(host: host, port: port, using: parameters)
        attempt.connection = connection
        if case .quic = transport {
            connection.pathUpdateHandler = { [self, weak attempt] path in
                guard let attempt, active === attempt else { return }
                record("path_update \(pathDetails(path))")
            }
        }
        connection.stateUpdateHandler = { [self, weak attempt, weak connection] state in
            guard let attempt, let connection, active === attempt else { return }
            switch state {
            case .waiting(let error):
                record("waiting error=\(error) \(pathDetails(connection.currentPath))")
            case .ready:
                record("ready \(pathDetails(connection.currentPath))")
                exchange(on: connection, for: attempt)
            case .failed(let error):
                finish(attempt, result: "failed error=\(error)", success: false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 20) { [self, weak attempt] in
            if let attempt {
                finish(attempt, result: "timeout", success: false)
            }
        }
    }

    private func pathDetails(_ path: NWPath?) -> String {
        guard let path else { return "path_status=unavailable path_reason=unavailable" }
        let reason = path.status == .unsatisfied ? String(describing: path.unsatisfiedReason) : "none"
        return "path_status=\(path.status) path_reason=\(reason)"
    }

    private func exchange(on stream: NWConnection, for attempt: Attempt) {
        stream.send(content: VMProbe.request, completion: .contentProcessed { [self] error in
            guard active === attempt else { return }
            if let error {
                finish(attempt, result: "send_failed error=\(error)", success: false)
                return
            }
            stream.receive(minimumIncompleteLength: VMProbe.reply.count, maximumLength: VMProbe.reply.count) {
                [self] received, _, _, error in
                let success = error == nil && received == VMProbe.reply
                finish(attempt, result: success ? "reply=ok" : "reply=invalid", success: success)
            }
        })
    }

    private func finish(_ attempt: Attempt, result: String, success: Bool) {
        guard active === attempt else { return }
        active = nil
        let path = pathDetails(attempt.connection?.currentPath)
        attempt.cancel()
        record("\(result) \(path)")
        if once {
            exit(success ? 0 : 1)
        }
        queue.asyncAfter(deadline: .now() + 3) { self.connect() }
    }

    private func record(_ event: String) {
        VMProbe.record("\(transport.prefix)dial \(event)")
    }
}
