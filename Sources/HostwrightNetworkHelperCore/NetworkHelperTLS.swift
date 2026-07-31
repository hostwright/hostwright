import CryptoKit
import Darwin
import Foundation
import HostwrightNetworking
@preconcurrency import Network
@preconcurrency import Security

private final class NetworkHelperLockedValue<Value>:
  @unchecked Sendable
{
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func read() -> Value {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func update<Result>(
    _ body: (inout Value) -> Result
  ) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}

struct NetworkHelperTLSPreparedIdentity: @unchecked Sendable {
  let handle: CertificateIdentityHandle
  let wireIdentity: sec_identity_t
  let certificateSHA256: String
}

private final class NetworkHelperTLSIdentityProvider:
  @unchecked Sendable
{
  private let lock = NSLock()
  private var prepared: NetworkHelperTLSPreparedIdentity

  init(_ prepared: NetworkHelperTLSPreparedIdentity) {
    self.prepared = prepared
  }

  var certificateSHA256: String {
    lock.lock()
    defer { lock.unlock() }
    return prepared.certificateSHA256
  }

  func wireIdentity() -> sec_identity_t {
    lock.lock()
    defer { lock.unlock() }
    return prepared.wireIdentity
  }

  func replace(_ replacement: NetworkHelperTLSPreparedIdentity) {
    lock.lock()
    prepared = replacement
    lock.unlock()
  }
}

enum NetworkHelperTLS {
  static func prepareIdentities(
    bindings: [ProjectIngressListenerBinding],
    identities: [String: CertificateIdentityHandle],
    now: Date = Date()
  ) throws -> [String: NetworkHelperTLSPreparedIdentity] {
    let referencedNames = Set(bindings.compactMap(\.certificate))
    guard referencedNames == Set(identities.keys) else {
      throw NetworkHelperError.certificateUnavailable
    }
    var prepared: [String: NetworkHelperTLSPreparedIdentity] = [:]
    for name in referencedNames.sorted() {
      guard let handle = identities[name] else {
        throw NetworkHelperError.certificateUnavailable
      }
      let requiredDNSNames = Set(
        bindings
          .filter { $0.certificate == name }
          .flatMap { $0.routes.map(\.hostname) }
      )
      prepared[name] = try prepareIdentity(
        handle,
        requiredDNSNames: requiredDNSNames,
        now: now
      )
    }
    return prepared
  }

  static func prepareIdentity(
    _ handle: CertificateIdentityHandle,
    requiredDNSNames: Set<String>,
    now: Date = Date()
  ) throws -> NetworkHelperTLSPreparedIdentity {
    let metadata = handle.metadata
    guard
      metadata.certificateSHA256.utf8.count == 64,
      metadata.certificateSHA256.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      }),
      metadata.notValidBefore <= now.addingTimeInterval(300),
      metadata.notValidAfter >= now.addingTimeInterval(-300),
      metadata.revocationStatus != .suppliedRevoked,
      requiredDNSNames.isSubset(of: Set(metadata.dnsNames)),
      !requiredDNSNames.isEmpty
    else {
      throw NetworkHelperError.invalidCertificate
    }

    var leaf: SecCertificate?
    guard
      SecIdentityCopyCertificate(handle.identity, &leaf)
        == errSecSuccess,
      let leaf,
      sha256(SecCertificateCopyData(leaf) as Data)
        == metadata.certificateSHA256
    else {
      throw NetworkHelperError.invalidCertificate
    }

    var seen = Set([metadata.certificateSHA256])
    for certificate in handle.certificateChain {
      let fingerprint = sha256(
        SecCertificateCopyData(certificate) as Data
      )
      guard seen.insert(fingerprint).inserted else {
        throw NetworkHelperError.invalidCertificate
      }
    }
    let wireIdentity: sec_identity_t?
    if handle.certificateChain.isEmpty {
      wireIdentity = sec_identity_create(handle.identity)
    } else {
      wireIdentity = sec_identity_create_with_certificates(
        handle.identity,
        handle.certificateChain as CFArray
      )
    }
    guard let wireIdentity else {
      throw NetworkHelperError.invalidCertificate
    }
    return NetworkHelperTLSPreparedIdentity(
      handle: handle,
      wireIdentity: wireIdentity,
      certificateSHA256: metadata.certificateSHA256
    )
  }

  static func identityDigest(
    _ identities: [String: NetworkHelperTLSPreparedIdentity]
  ) -> String {
    let canonical = identities.keys.sorted().map {
      "\($0)=\(identities[$0]!.certificateSHA256)"
    }.joined(separator: "\n")
    return sha256(Data(canonical.utf8))
  }

  fileprivate static func parameters(
    identityProvider: NetworkHelperTLSIdentityProvider,
    peerPolicyProvider: NetworkHelperMutualTLSPolicyProvider?,
    binding: ProjectIngressListenerBinding
  ) throws -> NWParameters {
    guard
      (1...65_535).contains(binding.port),
      !NetworkBindAddressPolicy.isBroadBindAddress(
        binding.bindAddress
      ),
      let port = NWEndpoint.Port(
        rawValue: UInt16(binding.port)
      )
    else {
      throw NetworkHelperError.invalidCertificate
    }

    let options = NWProtocolTLS.Options()
    let challengeQueue = DispatchQueue(
      label: "dev.hostwright.ingress.tls-identity"
    )
    sec_protocol_options_set_challenge_block(
      options.securityProtocolOptions,
      { _, completion in
        completion(identityProvider.wireIdentity())
      },
      challengeQueue
    )
    if binding.exposure.authentication == .mutualTLS {
      guard let peerPolicyProvider else {
        throw NetworkHelperError.invalidCertificate
      }
      let verifyQueue = DispatchQueue(
        label: "dev.hostwright.ingress.tls-peer-verify",
        qos: .userInitiated
      )
      sec_protocol_options_set_peer_authentication_required(
        options.securityProtocolOptions,
        true
      )
      sec_protocol_options_set_verify_block(
      options.securityProtocolOptions,
        { metadata, wireTrust, completion in
          let trust = sec_trust_copy_ref(wireTrust)
            .takeRetainedValue()
          completion(
            peerPolicyProvider.evaluate(
              trust,
              metadata: metadata
            )
          )
        },
        verifyQueue
      )
    } else if peerPolicyProvider != nil {
      throw NetworkHelperError.invalidCertificate
    }
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
      "http/1.1"
    )

    let parameters = NWParameters(
      tls: options,
      tcp: NWProtocolTCP.Options()
    )
    parameters.requiredLocalEndpoint = .hostPort(
      host: NWEndpoint.Host(binding.bindAddress),
      port: port
    )
    parameters.allowLocalEndpointReuse = false
    parameters.acceptLocalOnly =
      NetworkBindAddressPolicy.isLocalhost(
        binding.bindAddress
      )
    return parameters
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

final class NetworkHelperTLSConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var closed = false

  init(
    connection: NWConnection,
    label: String
  ) {
    self.connection = connection
    queue = DispatchQueue(
      label: "dev.hostwright.ingress.tls.\(label)",
      qos: .userInitiated
    )
  }

  func start(timeoutMilliseconds: Int64) -> Bool {
    guard timeoutMilliseconds > 0 else { return false }
    let completed = DispatchSemaphore(value: 0)
    let result = NetworkHelperLockedValue<Bool?>(nil)
    connection.stateUpdateHandler = { state in
      let resolved: Bool?
      switch state {
      case .ready:
        resolved = true
      case .failed, .cancelled:
        resolved = false
      case .setup, .waiting, .preparing:
        resolved = nil
      @unknown default:
        resolved = false
      }
      guard let resolved else { return }
      let first = result.update {
        guard $0 == nil else { return false }
        $0 = resolved
        return true
      }
      if first {
        completed.signal()
      }
    }
    connection.start(queue: queue)
    guard
      completed.wait(
        timeout: .now() + .milliseconds(Int(timeoutMilliseconds))
      ) == .success
    else {
      cancel()
      return false
    }
    let ready = result.read() == true
    if !ready {
      cancel()
    }
    return ready
  }

  func receive(
    maximumLength: Int,
    timeoutMilliseconds: Int64
  ) -> Data? {
    guard maximumLength > 0,
      timeoutMilliseconds > 0,
      !isClosed
    else {
      return nil
    }
    let completed = DispatchSemaphore(value: 0)
    let result = NetworkHelperLockedValue<Data?>(nil)
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: maximumLength
    ) { data, _, isComplete, error in
      if error == nil,
        let data,
        !data.isEmpty
      {
        result.update { $0 = data }
      } else if error == nil, !isComplete {
        result.update { $0 = Data() }
      }
      completed.signal()
    }
    guard
      completed.wait(
        timeout: .now() + .milliseconds(Int(timeoutMilliseconds))
      ) == .success
    else {
      cancel()
      return nil
    }
    return result.read()
  }

  func send(
    _ data: Data,
    timeoutMilliseconds: Int64
  ) -> Bool {
    guard timeoutMilliseconds > 0, !isClosed else {
      return false
    }
    if data.isEmpty {
      return true
    }
    let completed = DispatchSemaphore(value: 0)
    let succeeded = NetworkHelperLockedValue(false)
    connection.send(
      content: data,
      completion: .contentProcessed { error in
        succeeded.update { $0 = error == nil }
        completed.signal()
      }
    )
    guard
      completed.wait(
        timeout: .now() + .milliseconds(Int(timeoutMilliseconds))
      ) == .success
    else {
      cancel()
      return false
    }
    return succeeded.read()
  }

  func finishSending(timeoutMilliseconds: Int64) -> Bool {
    guard timeoutMilliseconds > 0, !isClosed else {
      return false
    }
    let completed = DispatchSemaphore(value: 0)
    let succeeded = NetworkHelperLockedValue(false)
    connection.send(
      content: nil,
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { error in
        succeeded.update { $0 = error == nil }
        completed.signal()
      }
    )
    guard
      completed.wait(
        timeout: .now() + .milliseconds(Int(timeoutMilliseconds))
      ) == .success
    else {
      cancel()
      return false
    }
    return succeeded.read()
  }

  func cancel() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    lock.unlock()
    connection.forceCancel()
  }

  private var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }

  func authenticatedPeerIdentity(
    using provider: NetworkHelperMutualTLSPolicyProvider
  ) -> String? {
    guard
      let metadata = connection.metadata(
        definition: NWProtocolTLS.definition
      ) as? NWProtocolTLS.Metadata
    else {
      return nil
    }
    return provider.consumeAuthenticatedIdentity(
      metadata: metadata.securityProtocolMetadata
    )
  }
}

final class NetworkHelperTLSIngressListener: @unchecked Sendable {
  private static let maximumConnections = 128
  private static let maximumChunkBytes = 64 * 1_024
  private static let handshakeTimeoutMilliseconds: Int64 = 5_000
  private static let idleTimeoutMilliseconds: Int64 = 30_000

  private struct ActiveConnection {
    let connection: NetworkHelperTLSConnection
    var bridgeDescriptor: Int32?
  }

  private let identityProvider: NetworkHelperTLSIdentityProvider
  let authentication: NetworkExposureAuthentication
  private let peerPolicyProvider: NetworkHelperMutualTLSPolicyProvider?
  private let listener: NWListener
  private let handler: NetworkHelperIngressListener
  private let queue: DispatchQueue
  private let lock = NSLock()
  private let stopped = DispatchSemaphore(value: 0)
  private let connections = DispatchGroup()
  private var running = false
  private var published = false
  private var closed = false
  private var nextConnectionID: UInt64 = 1
  private var active: [UInt64: ActiveConnection] = [:]

  init(
    binding: ProjectIngressListenerBinding,
    endpoint: String,
    configuration: NetworkHelperIngressConfiguration,
    preparedIdentity: NetworkHelperTLSPreparedIdentity,
    peerPolicy: NetworkHelperMutualTLSPolicy? = nil,
    accessLogger:
      @escaping @Sendable (
        NetworkHelperIngressAccessLogEntry
      ) -> Void
  ) throws {
    authentication = binding.exposure.authentication
    identityProvider = NetworkHelperTLSIdentityProvider(
      preparedIdentity
    )
    peerPolicyProvider = peerPolicy.map(
      {
        NetworkHelperMutualTLSPolicyProvider(
          $0,
          listenerName: binding.name
        )
      }
    )
    handler = NetworkHelperIngressListener(
      bridgedBinding: binding,
      endpoint: endpoint,
      configuration: configuration,
      accessLogger: accessLogger
    )
    queue = DispatchQueue(
      label:
        "dev.hostwright.ingress.tls-listener."
        + "\(binding.name).\(binding.port)",
      qos: .userInitiated
    )
    listener = try NWListener(
      using: NetworkHelperTLS.parameters(
        identityProvider: identityProvider,
        peerPolicyProvider: peerPolicyProvider,
        binding: binding
      )
    )
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
  }

  var identitySHA256: String {
    identityProvider.certificateSHA256
  }

  func replaceIdentity(
    _ replacement: NetworkHelperTLSPreparedIdentity
  ) {
    identityProvider.replace(replacement)
  }

  func replacePeerPolicy(
    _ replacement: NetworkHelperMutualTLSPolicy
  ) throws {
    guard let peerPolicyProvider else {
      throw NetworkHelperError.invalidCertificate
    }
    peerPolicyProvider.replace(replacement)
  }

  var mutualTLSAudit: [NetworkHelperMutualTLSAuditEntry] {
    peerPolicyProvider?.auditEntries() ?? []
  }

  func publish() {
    lock.lock()
    if running, !closed {
      published = true
    }
    lock.unlock()
  }

  func start() throws {
    lock.lock()
    guard !running, !closed else {
      lock.unlock()
      throw NetworkHelperError.bindingUnavailable
    }
    running = true
    lock.unlock()

    handler.start()
    let completed = DispatchSemaphore(value: 0)
    let ready = NetworkHelperLockedValue<Bool?>(nil)
    listener.stateUpdateHandler = { state in
      let result: Bool?
      switch state {
      case .ready:
        result = true
      case .failed, .cancelled:
        result = false
      case .setup, .waiting:
        result = nil
      @unknown default:
        result = false
      }
      guard let result else { return }
      let first = ready.update {
        guard $0 == nil else { return false }
        $0 = result
        return true
      }
      if first {
        completed.signal()
      }
    }
    listener.start(queue: queue)
    guard
      completed.wait(
        timeout: .now() + .seconds(5)
      ) == .success,
      ready.read() == true
    else {
      stop()
      throw NetworkHelperError.bindingUnavailable
    }
  }

  func stop() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    running = false
    published = false
    let activeSnapshot = Array(active.values)
    lock.unlock()

    listener.cancel()
    handler.stop()
    for item in activeSnapshot {
      if let descriptor = item.bridgeDescriptor {
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
      }
      item.connection.cancel()
    }
    _ = connections.wait(timeout: .now() + .seconds(3))
    stopped.signal()
  }

  private func accept(_ rawConnection: NWConnection) {
    let connection = NetworkHelperTLSConnection(
      connection: rawConnection,
      label: "accepted"
    )
    lock.lock()
    guard running,
      published,
      !closed,
      active.count < Self.maximumConnections
    else {
      lock.unlock()
      connection.cancel()
      return
    }
    let connectionID = nextConnectionID
    nextConnectionID &+= 1
    active[connectionID] = ActiveConnection(
      connection: connection,
      bridgeDescriptor: nil
    )
    connections.enter()
    lock.unlock()

    DispatchQueue.global(qos: .userInitiated).async {
      [weak self] in
      guard let self else { return }
      defer { finish(connectionID) }
      guard
        connection.start(
          timeoutMilliseconds:
            Self.handshakeTimeoutMilliseconds
        )
      else {
        peerPolicyProvider?.recordHandshakeFailure()
        return
      }
      let peerIdentity = peerPolicyProvider.flatMap {
        connection.authenticatedPeerIdentity(using: $0)
      }

      var pair: [Int32] = [-1, -1]
      guard
        Darwin.socketpair(
          AF_UNIX,
          SOCK_STREAM,
          0,
          &pair
        ) == 0,
        Self.configure(pair[0]),
        Self.configure(pair[1])
      else {
        if pair[0] >= 0 { Darwin.close(pair[0]) }
        if pair[1] >= 0 { Darwin.close(pair[1]) }
        return
      }
      guard
        setBridgeDescriptor(
          pair[1],
          connectionID: connectionID
        )
      else {
        Darwin.close(pair[0])
        Darwin.close(pair[1])
        return
      }
      guard handler.acceptBridgedConnection(
        pair[0],
        peerAddress: Self.remoteAddress(of: rawConnection),
        peerIdentity: peerIdentity
      ) else {
        clearBridgeDescriptor(
          connectionID: connectionID
        )
        Darwin.close(pair[0])
        Darwin.close(pair[1])
        return
      }
      Self.bridge(connection, descriptor: pair[1])
      clearBridgeDescriptor(connectionID: connectionID)
      Darwin.close(pair[1])
    }
  }

  private func setBridgeDescriptor(
    _ descriptor: Int32,
    connectionID: UInt64
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard running,
      !closed,
      var connection = active[connectionID]
    else {
      return false
    }
    connection.bridgeDescriptor = descriptor
    active[connectionID] = connection
    return true
  }

  private func clearBridgeDescriptor(
    connectionID: UInt64
  ) {
    lock.lock()
    if var connection = active[connectionID] {
      connection.bridgeDescriptor = nil
      active[connectionID] = connection
    }
    lock.unlock()
  }

  private func finish(_ connectionID: UInt64) {
    lock.lock()
    let connection = active.removeValue(
      forKey: connectionID
    )?.connection
    lock.unlock()
    connection?.cancel()
    connections.leave()
  }

  private static func bridge(
    _ connection: NetworkHelperTLSConnection,
    descriptor: Int32
  ) {
    let stopped = NetworkHelperLockedValue(false)
    let activity = NetworkHelperLockedValue(
      monotonicMilliseconds()
    )
    let completed = DispatchSemaphore(value: 0)
    let workers = DispatchGroup()

    workers.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer {
        stopped.update { $0 = true }
        completed.signal()
        workers.leave()
      }
      while !stopped.read() {
        guard
          let data = connection.receive(
            maximumLength: maximumChunkBytes,
            timeoutMilliseconds: idleTimeoutMilliseconds
          )
        else {
          return
        }
        if data.isEmpty {
          continue
        }
        guard writeAll(descriptor, data: data) else {
          return
        }
        activity.update { $0 = monotonicMilliseconds() }
      }
    }

    workers.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer {
        stopped.update { $0 = true }
        completed.signal()
        workers.leave()
      }
      var buffer = [UInt8](
        repeating: 0,
        count: maximumChunkBytes
      )
      while !stopped.read() {
        if monotonicMilliseconds() - activity.read() >= idleTimeoutMilliseconds {
          return
        }
        var value = pollfd(
          fd: descriptor,
          events: Int16(POLLIN),
          revents: 0
        )
        let result = Darwin.poll(&value, 1, 100)
        if result < 0 {
          if errno == EINTR { continue }
          return
        }
        if result == 0 { continue }
        guard value.revents & Int16(POLLIN) != 0 else {
          _ = connection.finishSending(
            timeoutMilliseconds:
              idleTimeoutMilliseconds
          )
          return
        }
        let count = Darwin.recv(
          descriptor,
          &buffer,
          buffer.count,
          0
        )
        guard count > 0 else {
          _ = connection.finishSending(
            timeoutMilliseconds:
              idleTimeoutMilliseconds
          )
          return
        }
        guard
          connection.send(
            Data(buffer[0..<count]),
            timeoutMilliseconds:
              idleTimeoutMilliseconds
          )
        else {
          return
        }
        activity.update { $0 = monotonicMilliseconds() }
      }
    }

    _ = completed.wait(
      timeout: .now() + .milliseconds(Int(idleTimeoutMilliseconds) + 1_000)
    )
    stopped.update { $0 = true }
    _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    if workers.wait(
      timeout: .now() + .seconds(1)
    ) == .timedOut {
      connection.cancel()
      _ = workers.wait(timeout: .now() + .seconds(1))
    }
    connection.cancel()
  }

  private static func configure(_ descriptor: Int32) -> Bool {
    guard
      fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
    else {
      return false
    }
    let flags = fcntl(descriptor, F_GETFL)
    guard
      flags >= 0,
      fcntl(
        descriptor,
        F_SETFL,
        flags | O_NONBLOCK
      ) == 0
    else {
      return false
    }
    var enabled: Int32 = 1
    return setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &enabled,
      socklen_t(MemoryLayout<Int32>.size)
    ) == 0
  }

  private static func writeAll(
    _ descriptor: Int32,
    data: Data
  ) -> Bool {
    let deadline = monotonicMilliseconds() + idleTimeoutMilliseconds
    var offset = 0
    return data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else {
        return data.isEmpty
      }
      while offset < data.count {
        guard monotonicMilliseconds() < deadline else {
          return false
        }
        var value = pollfd(
          fd: descriptor,
          events: Int16(POLLOUT),
          revents: 0
        )
        let result = Darwin.poll(&value, 1, 100)
        if result < 0 {
          if errno == EINTR { continue }
          return false
        }
        if result == 0 { continue }
        let count = Darwin.send(
          descriptor,
          base.advanced(by: offset),
          data.count - offset,
          0
        )
        if count < 0,
          errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR
        {
          continue
        }
        guard count > 0 else { return false }
        offset += count
      }
      return true
    }
  }

  private static func monotonicMilliseconds() -> Int64 {
    var value = timespec()
    clock_gettime(CLOCK_MONOTONIC, &value)
    return Int64(value.tv_sec) * 1_000 + Int64(value.tv_nsec) / 1_000_000
  }

  private static func remoteAddress(
    of connection: NWConnection
  ) -> String? {
    switch connection.endpoint {
    case .hostPort(let host, _):
      return "\(host)"
    default:
      return nil
    }
  }
}
