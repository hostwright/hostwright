import Darwin
import Dispatch
import Foundation
import HostwrightControl
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightControlTransport
import HostwrightDaemonCore
import HostwrightPolicy
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
    let auditTrail = TamperEvidentAuditTrail(
      store: store,
      keyStore: try MacOSAuditSigningKeyStore(
        service: MacOSAuditSigningKeyStore.serviceName(
          stateDatabasePath: configuration.stateDatabasePath
        )
      )
    )
    _ = try auditTrail.recoverPendingKeyRotation()
    switch auditTrail.verify().health {
    case .healthy:
      break
    case .recoverableAnchorLag:
      _ = try auditTrail.recoverAnchorAfterVerifiedCrash()
    case .degraded, .tampered:
      throw PersistentControlServerError.persistenceFailed
    }
    let streamCursorCodec = try ControlStreamCursorCodec(
      keyStore: try MacOSAuditSigningKeyStore(
        service: ControlStreamCursorCodec.keychainServiceName(
          stateDatabasePath: configuration.stateDatabasePath
        )
      )
    )
    let streamSources = DaemonControlStreamSourceFactory(
      store: store,
      cursorCodec: streamCursorCodec,
      manifestPath: configuration.configPath,
      stateDatabasePath: configuration.stateDatabasePath,
      auditRecorder: auditTrail
    )
    let requestRepository = ControlRequestRepository(store: store)
    let rbacAuthorizer = RBACAuthorizationEngine(repository: store.rbac)
    let rbacAdministration = RBACAdministrationService(
      repository: store.rbac, authorizer: rbacAuthorizer)
    let profileEngine = WorkloadProfilePolicyEngine(repository: store.workloadProfiles)
    let admissionEngine = AdmissionPolicyEngine(
      repository: store.admission,
      workloadProfileResolver: { try profileEngine.resolve(id: $0) })
    let streamAuthorizationPipeline = DaemonControlStreamAuthorizationPipeline(
      store: store,
      rbacAuthorizer: rbacAuthorizer,
      admissionEngine: admissionEngine,
      requestRepository: requestRepository,
      auditRecorder: auditTrail,
      validateStreamRequest: { try streamSources.validateRequest($0) }
    )
    let admissionAdministration = AdmissionAdministrationService(
      repository: store.admission, authorizer: rbacAuthorizer)
    let profileAdministration = WorkloadProfileAdministrationService(
      repository: store.workloadProfiles, authorizer: rbacAuthorizer)
    let server = try PersistentControlConnectionServer(
      authenticator: authenticator,
      requestRepository: requestRepository,
      daemonGeneration: UInt64.random(in: 1...UInt64.max),
      socketIdentity: listener.identity,
      mutatingOperations: Set([
        "up", "down", "run", "start", "stop", "restart", "rm", "update",
        "image", "registry", "volume",
        "audit.export",
        "rbac.role.create", "rbac.role.update", "rbac.role.delete",
        "rbac.binding.create", "rbac.binding.delete",
        "rbac.delegation.create", "rbac.delegation.revoke",
        "admission.policy.create", "admission.policy.set-enabled",
        "admission.policy.delete", "admission.exception.create",
        "admission.exception.delete",
      ]).union(WorkloadProfileControlOperations.mutatingOperations),
      auditRecorder: auditTrail,
      authorizer: { peer, request, at in
        try rbacAuthorizer.authorize(subject: peer.binding.subject, request: request, at: at)
      },
      admissionEvaluator: { peer, request, at in
        let evaluated = try admissionEngine.evaluate(
          subjectID: peer.binding.subject.identifier, request: request, at: at)
        return try PersistentControlAdmissionEvaluation(
          effectiveRequest: evaluated.effectiveRequest, decisions: evaluated.decisions,
          target: evaluated.target, planHash: evaluated.planHash,
          approvalIdentity: evaluated.approvalIdentity,
          exceptionIDs: evaluated.exceptionIDs, allowed: evaluated.allowed,
          reasonCode: evaluated.reasonCode,
          evaluationDigestSHA256: evaluated.evaluationDigestSHA256,
          dryRun: evaluated.dryRun)
      },
      streamAuthorizer: { peer, streamID, request, at in
        try streamAuthorizationPipeline.authorize(
          peer: peer,
          streamID: streamID,
          request: request,
          at: at
        )
      },
      streamCursorValidator: { peer, request, cursor in
        try streamSources.validateCursor(peer: peer, request: request, cursor: cursor)
      },
      streamReauthorizer: { peer, request, at in
        try streamAuthorizationPipeline.reauthorize(peer: peer, request: request, at: at)
      },
      streamOpener: { peer, request, cursor, sink in
        try streamSources.open(
          peer: peer,
          request: request,
          cursor: cursor,
          preStartAuthorization: {
            try authenticator.validateSession(
              peer.binding,
              daemonGeneration: peer.binding.daemonGeneration
            )
            let decision = try streamAuthorizationPipeline.reauthorize(
              peer: peer,
              request: request,
              at: Date()
            )
            try decision.validate()
            guard decision.effect == .allow else {
              throw ControlStreamAuthorizationError.admissionDenied
            }
          },
          sink: sink
        )
      },
      handler: { peer, request, _ in
        try Self.handle(
          peer: peer, request: request, localAPI: localAPI, auditTrail: auditTrail,
          rbacRepository: store.rbac, rbacAdministration: rbacAdministration,
          rbacAuthorizer: rbacAuthorizer, admissionRepository: store.admission,
          admissionAdministration: admissionAdministration,
          admissionEngine: admissionEngine, profileRepository: store.workloadProfiles,
          profileAdministration: profileAdministration, profileEngine: profileEngine)
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
    lock.lock()
    let drainingDescriptors = connections
    for descriptor in drainingDescriptors {
      _ = shutdown(descriptor, SHUT_RD)
    }
    lock.unlock()
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
    guard !stopped, connections.count < ControlPlaneContract.maximumClientConnections else {
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
    peer: AuthenticatedControlPeer,
    request: ControlRequestEnvelope,
    localAPI: LocalControlAPI,
    auditTrail: TamperEvidentAuditTrail,
    rbacRepository: RBACRepository,
    rbacAdministration: RBACAdministrationService,
    rbacAuthorizer: RBACAuthorizationEngine,
    admissionRepository: AdmissionRepository,
    admissionAdministration: AdmissionAdministrationService,
    admissionEngine: AdmissionPolicyEngine,
    profileRepository: WorkloadProfileRepository,
    profileAdministration: WorkloadProfileAdministrationService,
    profileEngine: WorkloadProfilePolicyEngine
  ) throws -> ControlResponseEnvelope {
    if let response = WorkloadProfileControlOperations.handle(
      peer: peer, request: request, repository: profileRepository,
      administration: profileAdministration, engine: profileEngine, now: Date())
    {
      return response
    }
    if let response = AdmissionControlOperations.handle(
      peer: peer, request: request, repository: admissionRepository,
      administration: admissionAdministration, engine: admissionEngine, now: Date())
    {
      return response
    }
    if let response = RBACControlOperations.handle(
      peer: peer, request: request, repository: rbacRepository,
      administration: rbacAdministration, authorizer: rbacAuthorizer, now: Date())
    {
      return response
    }
    if request.operation == "audit.verify" {
      let report = auditTrail.verify()
      return ControlResponseEnvelope(
        requestID: request.requestID,
        status: report.health == .tampered ? .error : .completed,
        reasonCode: report.health == .tampered ? .internalError : .completed,
        result: try controlPlaneValue(report),
        error: report.health == .tampered
          ? SanitizedError(
            code: "auditVerificationFailed",
            message: "The tamper-evident audit trail did not verify."
          )
          : nil
      )
    }
    if request.operation == "audit.export" {
      let exported = try auditTrail.exportVerified()
      return ControlResponseEnvelope(
        requestID: request.requestID,
        status: .completed,
        reasonCode: .completed,
        result: .object([
          "encoding": .string("base64"),
          "payload": .string(exported.base64EncodedString()),
        ])
      )
    }
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

  private static func controlPlaneValue<T: Encodable>(
    _ value: T
  ) throws -> ControlPlaneJSONValue {
    try JSONDecoder().decode(
      ControlPlaneJSONValue.self,
      from: JSONEncoder().encode(value)
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
