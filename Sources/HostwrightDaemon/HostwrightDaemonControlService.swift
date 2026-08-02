import Darwin
import Dispatch
import Foundation
import HostwrightControl
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightControlTransport
import HostwrightDaemonCore
import HostwrightState

final class HostwrightDaemonControlService: DaemonControlServing, @unchecked Sendable {
  private let configuration: DaemonConfiguration
  private let lock = NSLock()
  private var listener: ControlUnixSocketListener?
  private var stopped = false
  private var connections = Set<Int32>()
  private let connectionGroup = DispatchGroup()
  private let acceptQueue = DispatchQueue(label: "dev.hostwright.control.accept")
  private let connectionQueue = DispatchQueue(
    label: "dev.hostwright.control.connections",
    attributes: .concurrent
  )

  private init(configuration: DaemonConfiguration) {
    self.configuration = configuration
  }

  static func make(configuration: DaemonConfiguration) throws -> any DaemonControlServing {
    HostwrightDaemonControlService(configuration: configuration)
  }

  func start() throws {
    guard let resolution = configuration.stateStoreConfiguration.localPathResolution else {
      throw PersistentControlServerError.unsafeSocketPath
    }
    let store = SQLiteStateStore(configuration: configuration.stateStoreConfiguration)
    let identityAdapter = try SQLiteControlIdentitySecurityAdapter(
      store: store,
      sessionLifetime: 8 * 60 * 60
    )
    let pinnedHashes = Set(
      try store.controlIdentities.listIdentities().compactMap { record in
        record.codeIdentity.validationMode == .pinnedAdHoc
          ? record.codeIdentity.codeDirectoryHash : nil
      }
    )
    let authenticator = ControlPeerAuthenticator(
      policy: try ControlPeerTrustPolicy(
        expectedUserID: UInt32(geteuid()),
        pinnedAdHocCodeDirectoryHashes: pinnedHashes
      ),
      subjectResolver: identityAdapter,
      sessionStore: identityAdapter
    )
    let listener = try ControlUnixSocketListener(
      path: resolution.layout.controlSocket,
      recoverStaleSocket: true
    )
    let localAPI = LocalControlAPI(
      configuration: LocalControlConfiguration(
        manifestPath: configuration.configPath,
        stateDatabasePath: configuration.stateDatabasePath
      )
    )
    let server = try PersistentControlConnectionServer(
      authenticator: authenticator,
      requestRepository: ControlRequestRepository(store: store),
      daemonGeneration: UInt64.random(in: 1...UInt64.max),
      socketIdentity: listener.identity,
      mutatingOperations: [
        "up", "down", "run", "start", "stop", "restart", "rm", "update",
        "image", "registry", "volume",
      ],
      handler: { _, request, _ in
        try Self.handle(request: request, localAPI: localAPI)
      }
    )
    lock.lock()
    self.listener = listener
    stopped = false
    lock.unlock()
    acceptQueue.async { [weak self] in
      self?.acceptLoop(listener: listener, server: server)
    }
  }

  func stop() {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    stopped = true
    let listener = self.listener
    self.listener = nil
    lock.unlock()
    listener?.closeAndRemoveOwnedSocket()
    _ = connectionGroup.wait(timeout: .now() + 5)
    lock.lock()
    let descriptors = connections
    for descriptor in descriptors {
      _ = shutdown(descriptor, SHUT_RDWR)
    }
    lock.unlock()
  }

  private func acceptLoop(
    listener: ControlUnixSocketListener,
    server: PersistentControlConnectionServer
  ) {
    while !isStopped {
      guard let descriptor = try? listener.accept(timeoutMilliseconds: 250) else {
        continue
      }
      guard register(descriptor) else {
        _ = Darwin.close(descriptor)
        continue
      }
      let group = connectionGroup
      group.enter()
      connectionQueue.async { [weak self] in
        defer {
          _ = Darwin.close(descriptor)
          self?.unregister(descriptor)
          group.leave()
        }
        try? server.serve(descriptor: descriptor)
      }
    }
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  private func register(_ descriptor: Int32) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped, connections.count < ControlPlaneContract.maximumOutstandingUnary else {
      return false
    }
    connections.insert(descriptor)
    return true
  }

  private func unregister(_ descriptor: Int32) {
    lock.lock()
    connections.remove(descriptor)
    lock.unlock()
  }

  private static func handle(
    request: ControlRequestEnvelope,
    localAPI: LocalControlAPI
  ) throws -> ControlResponseEnvelope {
    var payload: [String: ControlPlaneJSONValue] = [
      "apiVersion": .integer(Int64(request.apiVersion)),
      "requestID": .string(request.requestID),
      "operation": .string(request.operation),
    ]
    if let body = request.body {
      guard case .object(let fields) = body else {
        return failure(
          requestID: request.requestID,
          reason: .invalidRequest,
          code: "invalidBody",
          message: "The request body must be an object."
        )
      }
      for (key, value) in fields where payload[key] == nil {
        payload[key] = value
      }
    }
    let result = localAPI.run(requestData: try ControlPlaneCanonicalJSON.encode(payload))
    guard result.exitCode == 0,
      let local = try? JSONDecoder().decode(
        LocalControlResponse.self,
        from: result.standardOutput
      ),
      local.success
    else {
      return failure(
        requestID: request.requestID,
        reason: result.exitCode == LocalControlExitCode.invalidRequest.rawValue
          ? .invalidRequest : .internalError,
        code: "controlOperationFailed",
        message: "The control operation did not complete."
      )
    }
    let responseResult: ControlPlaneJSONValue?
    if let value = local.result {
      responseResult = try JSONDecoder().decode(
        ControlPlaneJSONValue.self,
        from: JSONEncoder().encode(value)
      )
    } else {
      responseResult = nil
    }
    return ControlResponseEnvelope(
      requestID: request.requestID,
      status: .completed,
      reasonCode: .completed,
      result: responseResult
    )
  }

  private static func failure(
    requestID: String,
    reason: ControlReasonCode,
    code: String,
    message: String
  ) -> ControlResponseEnvelope {
    ControlResponseEnvelope(
      requestID: requestID,
      status: reason == .invalidRequest ? .rejected : .error,
      reasonCode: reason,
      error: SanitizedError(code: code, message: message)
    )
  }
}
