import Foundation
import Network
import Security

let rpcPayload = Data((0..<32).map(UInt8.init))
let bulkPayload = Data(repeating: 0xA5, count: 16 * 1024)
let loopback = NWEndpoint.Host("127.0.0.1")
let benchmarkQueue = DispatchQueue(label: "dev.hostwright.spike.v391", qos: .userInitiated)

struct BenchmarkError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0

    var value: Int { lock.withLock { bytes } }

    func add(_ count: Int) {
        lock.withLock { bytes += count }
    }
}

struct BenchmarkMeasurement {
    let samples: Int
    let p50Milliseconds: Double
    let p99Milliseconds: Double
    let seconds: Double
    let receivedBytes: Int
    let progressIntervals: Int

    var output: String {
        String(
            format: "samples=%d p50_ms=%.3f p99_ms=%.3f seconds=%.3f received_bytes=%lld bulk_MiB_s=%.2f progress_intervals=%d/%d",
            samples, p50Milliseconds, p99Milliseconds, seconds, Int64(receivedBytes),
            Double(receivedBytes) / seconds / 1_048_576, progressIntervals, samples
        )
    }
}

func measure(bulkReceived: ByteCounter, ping: () async throws -> Void) async throws -> BenchmarkMeasurement {
    try await pollFor("bulk receiver to warm up") { bulkReceived.value >= bulkPayload.count }
    let clock = ContinuousClock()
    let beginning = clock.now
    let initialBytes = bulkReceived.value
    var previousBytes = initialBytes
    var progress = 0
    var samples: [Double] = []
    for _ in 0..<500 {
        let start = clock.now
        try await ping()
        samples.append(elapsedSeconds(start.duration(to: clock.now)) * 1_000)
        try await Task.sleep(for: .milliseconds(2))
        let currentBytes = bulkReceived.value
        if currentBytes > previousBytes { progress += 1 }
        previousBytes = currentBytes
    }
    let end = clock.now
    let receivedBytes = bulkReceived.value - initialBytes
    guard receivedBytes > bulkPayload.count, progress >= samples.count / 2 else {
        throw BenchmarkError("Bulk traffic did not keep progressing during the RPC sample. Progress: \(progress)/\(samples.count).")
    }
    let ordered = samples.sorted()
    return BenchmarkMeasurement(
        samples: samples.count,
        p50Milliseconds: ordered[Int(ceil(Double(samples.count) * 0.50)) - 1],
        p99Milliseconds: ordered[Int(ceil(Double(samples.count) * 0.99)) - 1],
        seconds: elapsedSeconds(beginning.duration(to: end)),
        receivedBytes: receivedBytes,
        progressIntervals: progress
    )
}

func pollFor(_ operation: String, timeout: Duration = .seconds(8), _ predicate: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while try !predicate() {
        guard ContinuousClock.now < deadline else { throw BenchmarkError("Timed out waiting for \(operation).") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

func elapsedSeconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

final class BenchmarkCredentials: @unchecked Sendable {
    private let keychain: IsolatedKeychain
    private let worker: SpikeIdentity
    private let control: SpikeIdentity
    let workerVerifications = ByteCounter()
    let controlVerifications = ByteCounter()

    init() throws {
        let keychain = try IsolatedKeychain()
        self.keychain = keychain
        worker = try keychain.identity(named: "V3-91 Worker")
        control = try keychain.identity(named: "V3-91 Control")
    }

    func localIdentity(server: Bool) throws -> sec_identity_t {
        guard let identity = sec_identity_create(server ? worker.identity : control.identity) else {
            throw BenchmarkError("Could not convert the isolated SecIdentity.")
        }
        return identity
    }

    func validator(server: Bool) -> @Sendable (sec_trust_t) -> Bool {
        let pinnedCertificate = SecCertificateCopyData(server ? control.certificate : worker.certificate) as Data
        let count = server ? workerVerifications : controlVerifications
        return { wireTrust in
            let trust = sec_trust_copy_ref(wireTrust).takeRetainedValue()
            guard
                let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                let leaf = certificates.first,
                SecCertificateCopyData(leaf) as Data == pinnedCertificate
            else { return false }
            count.add(1)
            return true
        }
    }

    func tlsOptions(server: Bool, alpn: String, includeIdentity: Bool = true) throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_tls_resumption_enabled(security, false)
        sec_protocol_options_add_tls_application_protocol(security, alpn)
        if includeIdentity {
            sec_protocol_options_set_local_identity(security, try localIdentity(server: server))
        }
        let verify = validator(server: server)
        sec_protocol_options_set_verify_block(security, { _, trust, completion in
            completion(verify(trust))
        }, benchmarkQueue)
        return options
    }
}

@main
enum LinkTransportBenchmark {
    static func main() async {
        let candidates = ["quic", "http2", "mux"]
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 1, let candidate = arguments.first, candidates.contains(candidate) else {
            print("Usage: v391-link-transport quic|http2|mux")
            exit(64)
        }
        do {
            let credentials = try BenchmarkCredentials()
            let measurement: BenchmarkMeasurement
            switch candidate {
            case "quic":
                measurement = try await runQUIC(credentials)
            case "http2":
                measurement = try await runHTTP2(credentials)
            case "mux":
                measurement = try await runTLSMux(credentials)
            default:
                throw BenchmarkError("Unsupported benchmark candidate.")
            }
            guard credentials.workerVerifications.value > 0, credentials.controlVerifications.value > 0 else {
                throw BenchmarkError("Both peer verifiers must confirm the pinned certificates.")
            }
            print("transport=\(candidate) \(measurement.output)")
            print("pinned_mutual_auth=pass worker_verifications=\(credentials.workerVerifications.value) control_verifications=\(credentials.controlVerifications.value)")
        } catch {
            FileHandle.standardError.write(Data("transport=\(candidate) error=\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
