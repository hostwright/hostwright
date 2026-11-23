import Dispatch
import Foundation
import Network
import Security

enum ExporterProbe {
    static func run() throws {
        let keychain = try IsolatedKeychain()
        try withExtendedLifetime(keychain) {
            let server = try keychain.identity(named: "localhost-spike-server")
            let client = try keychain.identity(named: "localhost-spike-client")
            let session = LoopbackSession()
            let outcome = try session.run(server: server, client: client)
            log("transport=Network.framework TCP 127.0.0.1 TLS 1.3")
            log("peer_authentication=exact ephemeral certificate pin verified by both peers")
            log("private_key_export=denied for both identities in an isolated temporary keychain")
            log("exporter_api=sec_protocol_metadata_create_secret")
            log("exporter_length_server=\(outcome.server?.count ?? 0) exporter_length_client=\(outcome.client?.count ?? 0)")
            if let server = outcome.server, let client = outcome.client, server.count == 32, server == client {
                log("exporter_match=yes D8_channel_binding=TLS_exporter")
            } else {
                log("exporter_match=no D8_channel_binding=MAC_over_transcript_with_both_certificate_SHA256_fingerprints")
            }
        }
    }
}

private final class LoopbackSession: @unchecked Sendable {
    struct Outcome {
        let server: Data?
        let client: Data?
    }

    private enum Side: Hashable {
        case server
        case client
    }

    // Network state is changed only on queue. The semaphore publishes the terminal result.
    private let queue = DispatchQueue(label: "dev.hostwright.v314.tls")
    private let done = DispatchSemaphore(value: 0)
    private var verified: Set<Side> = []
    private var ready: Set<Side> = []
    private var secrets: [Side: Data] = [:]
    private var result: Result<Outcome, ProbeFailure>?
    private var listener: NWListener?
    private var serverConnection: NWConnection?
    private var clientConnection: NWConnection?

    func run(server: SpikeIdentity, client: SpikeIdentity) throws -> Outcome {
        let loopback = NWEndpoint.Host("127.0.0.1")
        let serverParameters = try parameters(own: server, peer: client, side: .server)
        let clientParameters = try parameters(own: client, peer: server, side: .client)
        serverParameters.requiredLocalEndpoint = .hostPort(host: loopback, port: .any)
        serverParameters.acceptLocalOnly = true
        let listener = try NWListener(using: serverParameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.serverConnection == nil else {
                connection.cancel()
                return
            }
            self.serverConnection = connection
            self.start(connection, as: .server)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                guard let port = listener.port else {
                    self.finish(.failure(ProbeFailure("Listener has no assigned loopback port")))
                    return
                }
                let connection = NWConnection(host: loopback, port: port, using: clientParameters)
                self.clientConnection = connection
                self.start(connection, as: .client)
            case .failed(let error):
                self.finish(.failure(ProbeFailure("Loopback listener failed (\(error))")))
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.finish(.failure(ProbeFailure("Timed out before both peers completed mutual TLS")))
        }
        listener.start(queue: queue)
        done.wait()
        return try result!.get()
    }

    private func parameters(own: SpikeIdentity, peer: SpikeIdentity, side: Side) throws -> NWParameters {
        guard let identity = sec_identity_create(own.identity) else {
            throw ProbeFailure("sec_identity_create rejected the keychain identity")
        }
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(security, "hostwright-v314/1")
        sec_protocol_options_set_local_identity(security, identity)
        sec_protocol_options_set_peer_authentication_required(security, true)
        let expected = SecCertificateCopyData(peer.certificate) as Data
        sec_protocol_options_set_verify_block(security, { [weak self] _, wireTrust, complete in
            let trust = sec_trust_copy_ref(wireTrust).takeRetainedValue()
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
            let pinned = chain?.first.map { SecCertificateCopyData($0) as Data } == expected
            if pinned {
                self?.verified.insert(side)
            }
            complete(pinned)
        }, queue)
        return NWParameters(tls: options, tcp: NWProtocolTCP.Options())
    }

    private func start(_ connection: NWConnection, as side: Side) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
                    self.finish(.failure(ProbeFailure("Network.framework did not expose the negotiated TLS metadata")))
                    return
                }
                let security = metadata.securityProtocolMetadata
                guard sec_protocol_metadata_get_negotiated_tls_protocol_version(security) == .TLSv13 else {
                    self.finish(.failure(ProbeFailure("The connection did not negotiate TLS 1.3")))
                    return
                }
                let label = "EXPORTER-Hostwright-V3-14-Channel-Binding"
                if let secret = label.withCString({ sec_protocol_metadata_create_secret(security, label.utf8.count, $0, 32) }) {
                    self.secrets[side] = Data(secret as DispatchData)
                }
                self.ready.insert(side)
                if self.ready.count == 2 {
                    guard self.verified.count == 2 else {
                        self.finish(.failure(ProbeFailure("Both peers did not verify the pinned certificate")))
                        return
                    }
                    self.finish(.success(Outcome(server: self.secrets[.server], client: self.secrets[.client])))
                }
            case .failed(let error):
                self.finish(.failure(ProbeFailure("TLS \(side) connection failed (\(error))")))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func finish(_ terminalResult: Result<Outcome, ProbeFailure>) {
        guard result == nil else { return }
        result = terminalResult
        listener?.cancel()
        serverConnection?.cancel()
        clientConnection?.cancel()
        done.signal()
    }
}
