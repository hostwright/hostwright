import Dispatch
import Foundation
import Network

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
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: request.count, maximumLength: request.count) { received, _, _, error in
                guard error == nil, received == request else {
                    connection.cancel()
                    return
                }
                connection.send(content: reply, completion: .contentProcessed { error in
                    if error == nil {
                        record("listen reply=ok")
                    }
                    connection.cancel()
                })
            }
            queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
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

    static func dial(_ host: NWEndpoint.Host, _ port: NWEndpoint.Port, once: Bool) throws -> Never {
        guard port != .any else { throw ProbeFailure("Dial requires a nonzero port") }
        VMProbeDialer(host: host, port: port, once: once).start()
        dispatchMain()
    }

    static func record(_ event: String) {
        log("\(Date().ISO8601Format()) build=\(version) \(event)")
    }
}

private final class VMProbeDialer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.hostwright.v314.dial")
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let once: Bool
    private var active: NWConnection?

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, once: Bool) {
        self.host = host
        self.port = port
        self.once = once
    }

    func start() {
        queue.async { self.connect() }
    }

    // The queue owns the connection and serializes completion, timeout and retry.
    private func connect() {
        let connection = NWConnection(host: host, port: port, using: .tcp)
        active = connection
        VMProbe.record("dial start")
        connection.stateUpdateHandler = { [self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .waiting(let error):
                let reason = connection.currentPath.flatMap { path in
                    path.status == .unsatisfied ? String(describing: path.unsatisfiedReason) : nil
                } ?? "unavailable"
                VMProbe.record("dial waiting error=\(error) path_reason=\(reason)")
            case .ready:
                VMProbe.record("dial ready")
                exchange(on: connection)
            case .failed(let error):
                finish(connection, result: "failed error=\(error)", success: false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 20) { [self, weak connection] in
            if let connection {
                finish(connection, result: "timeout", success: false)
            }
        }
    }

    private func exchange(on connection: NWConnection) {
        connection.send(content: VMProbe.request, completion: .contentProcessed { [self] error in
            if let error {
                finish(connection, result: "send_failed error=\(error)", success: false)
                return
            }
            connection.receive(minimumIncompleteLength: VMProbe.reply.count, maximumLength: VMProbe.reply.count) {
                [self] received, _, _, error in
                let success = error == nil && received == VMProbe.reply
                finish(connection, result: success ? "reply=ok" : "reply=invalid", success: success)
            }
        })
    }

    private func finish(_ connection: NWConnection, result: String, success: Bool) {
        guard active === connection else { return }
        active = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        VMProbe.record("dial \(result)")
        if once {
            exit(success ? 0 : 1)
        }
        queue.asyncAfter(deadline: .now() + 3) { self.connect() }
    }
}
