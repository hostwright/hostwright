import Darwin
import Dispatch
import Foundation
import Network
import Security

enum VMQUICProbe {
    static func listen(_ host: NWEndpoint.Host, _ port: NWEndpoint.Port, certificate: URL) throws -> Never {
        try VMQUICListener(host: host, port: port, certificate: certificate).run()
    }

    static func readCertificate(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let bytes = try file.read(upToCount: 16_385), bytes.count <= 16_384,
              SecCertificateCreateWithData(nil, bytes as CFData) != nil else {
            throw ProbeFailure("Expected a DER-encoded QUIC reference certificate of at most 16 KiB")
        }
        return bytes
    }

    static func dialParameters(
        pin: Data, queue: DispatchQueue, onRejected: @escaping @Sendable () -> Void
    ) -> NWParameters {
        let options = quicOptions()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_verify_block(security, { _, wireTrust, complete in
            let trust = sec_trust_copy_ref(wireTrust).takeRetainedValue()
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
            let peer = chain?.first.map { SecCertificateCopyData($0) as Data }
            let matches = peer == pin
            complete(matches)
            if !matches {
                onRejected()
            }
        }, queue)
        return NWParameters(quic: options)
    }

    fileprivate static func quicOptions() -> NWProtocolQUIC.Options {
        let options = NWProtocolQUIC.Options(alpn: ["hostwright-v314-vm/1"])
        options.direction = .bidirectional
        options.idleTimeout = 15_000
        options.initialMaxData = 65_536
        options.initialMaxStreamDataBidirectionalLocal = 8_192
        options.initialMaxStreamDataBidirectionalRemote = 8_192
        options.initialMaxStreamsBidirectional = 8
        options.initialMaxStreamsUnidirectional = 0
        sec_protocol_options_set_tls_resumption_enabled(options.securityProtocolOptions, false)
        return options
    }
}

private final class VMQUICListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.hostwright.v314.quic-listen")
    private let listener: NWListener
    private var keychain: IsolatedKeychain?
    private var groups: [ObjectIdentifier: NWConnectionGroup] = [:]
    private var stopSignals: [DispatchSourceSignal] = []

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, certificate: URL) throws {
        let keychain = try IsolatedKeychain()
        let server = try keychain.identity(named: "hostwright-v314-quic-listener")
        guard let identity = sec_identity_create(server.identity) else {
            throw ProbeFailure("Could not create the QUIC reference identity")
        }
        let options = VMQUICProbe.quicOptions()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_local_identity(security, identity)
        sec_protocol_options_set_peer_authentication_required(security, false)
        let parameters = NWParameters(quic: options)
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        listener = try NWListener(using: parameters)
        self.keychain = keychain
        try (SecCertificateCopyData(server.certificate) as Data).write(to: certificate, options: .withoutOverwriting)
    }

    func run() -> Never {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [self] in stop(status: 0) }
            source.resume()
            stopSignals.append(source)
        }
        listener.newConnectionGroupHandler = { [self] group in
            let identifier = ObjectIdentifier(group)
            groups[identifier] = group
            group.newConnectionHandler = { [queue] stream in
                VMProbe.respond(to: stream, on: queue, prefix: "quic ", keepOpen: true)
            }
            group.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.groups.removeValue(forKey: identifier)
                default:
                    break
                }
            }
            group.start(queue: queue)
        }
        listener.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard let port = listener.port else {
                    VMProbe.record("quic listen failed missing bound port")
                    stop(status: 1)
                }
                VMProbe.record("quic listen ready port=\(port.rawValue) certificate=written")
            case .failed(let error):
                VMProbe.record("quic listen failed error=\(error)")
                stop(status: 1)
            default:
                break
            }
        }
        listener.start(queue: queue)
        dispatchMain()
    }

    private func stop(status: Int32) -> Never {
        listener.cancel()
        for group in groups.values {
            group.cancel()
        }
        keychain = nil
        exit(status)
    }
}
