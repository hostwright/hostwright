import Darwin
import CryptoKit
import Dispatch
import Foundation
import HostwrightCLI
import HostwrightControl
import HostwrightCommandTransport
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightControlTransport
import HostwrightCore
import HostwrightDaemonCore
import HostwrightExtensions
import HostwrightPolicy
import HostwrightRegistry
import HostwrightState

final class HostwrightDaemonControlService: DaemonControlServing, @unchecked Sendable {
  private let configuration: DaemonConfiguration
  private let lock = NSLock()
  private var listener: ControlUnixSocketListener?
  private var stopped = false
  private var connections = Set<Int32>()
  private let connectionGroup = DispatchGroup()
  private let acceptQueue = DispatchQueue(label: "dev.hostwright.control.accept")
  private let acceptQueueKey = DispatchSpecificKey<Void>()
  private let connectionQueue = DispatchQueue(
    label: "dev.hostwright.control.connections",
    attributes: .concurrent
  )

  private init(configuration: DaemonConfiguration) {
    self.configuration = configuration
    acceptQueue.setSpecific(key: acceptQueueKey, value: ())
  }

  static func make(configuration: DaemonConfiguration) throws -> any DaemonControlServing {
    HostwrightDaemonControlService(configuration: configuration)
  }

  static func recoverInterruptedUnaryRequests(
    repository: ControlRequestRepository,
    auditRecorder: any ControlSecurityAuditRecording,
    now: () -> Date
  ) throws -> Int {
    let interrupted = try repository.interruptedUnaryRequests()
    for request in interrupted {
      try auditRecorder.record(ControlSecurityAuditEvent(
        subjectID: request.subjectID,
        requestID: request.requestID,
        target: "control.unary",
        action: .operation,
        outcome: "error",
        reasonCode: "operation.interrupted-by-daemon-restart",
        operationRef: request.operationReference,
        payloadDigest: "sha256:\(request.requestDigestSHA256)",
        deduplicationKey: "control:\(request.requestID):restart-recovery"
      ))
      _ = try repository.markInterruptedUnaryRequest(
        requestID: request.requestID,
        operationReference: request.operationReference!,
        updatedAt: ISO8601DateFormatter().string(from: now())
      )
    }
    return interrupted.count
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
    let localAPI = LocalControlAPI(
      configuration: LocalControlConfiguration(
        manifestPath: configuration.configPath,
        stateDatabasePath: configuration.stateDatabasePath
      )
    )
    let authoritativeStatePath = configuration.stateDatabasePath
    var mutableCommandEnvironment = CLIEnvironment.live
    mutableCommandEnvironment.localPathResolution = { explicitPath in
      if let explicitPath {
        let normalized = try HostwrightLocalPathResolver.normalizedAbsolutePath(
          explicitPath,
          role: "Control API state database"
        )
        guard normalized == authoritativeStatePath else {
          throw HostwrightLocalPathError.invalidPath(
            role: "Control API state database",
            path: explicitPath,
            reason: "the path does not match the daemon's configured state authority"
          )
        }
      }
      return resolution
    }
    let commandEnvironment = mutableCommandEnvironment
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
    _ = try Self.recoverInterruptedUnaryRequests(
      repository: requestRepository,
      auditRecorder: auditTrail,
      now: Date.init
    )
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
    let providerOwnershipLedgerURL: URL
    if resolution.usesApplicationSupportState {
      providerOwnershipLedgerURL = URL(
        fileURLWithPath: resolution.layout.metadataDirectory,
        isDirectory: true
      ).appendingPathComponent("plugin-provider-workers.jsonl")
    } else {
      let stateAuthority = SHA256.hash(data: Data(configuration.stateDatabasePath.utf8))
        .prefix(8)
        .map { String(format: "%02x", $0) }
        .joined()
      providerOwnershipLedgerURL = URL(fileURLWithPath: configuration.stateDatabasePath)
        .deletingLastPathComponent()
        .appendingPathComponent(
          ".hostwright-\(stateAuthority)-plugin-provider-workers-v1.jsonl")
    }
    try Self.prepareProviderOwnershipLedger(providerOwnershipLedgerURL)
    let pluginRuntime = PluginControlRuntime(
      repository: store.plugins,
      immutableStore: try PluginImmutableStore(
        rootURL: URL(
          fileURLWithPath: resolution.layout.applicationSupportDirectory,
          isDirectory: true
        ).appendingPathComponent("plugins-v1", isDirectory: true)),
      healthChecker: try PluginProviderHealthChecker(
        wasiOwnershipLedgerURL: providerOwnershipLedgerURL),
      registryTransport: SynchronousURLSessionRegistryTransport(
        maximumResponseBodyBytes: PluginPackageVerifier.maximumContentFileBytes),
      activeProviders: try ActivePluginProviderRuntime(
        repository: store.plugins,
        wasiOwnershipLedgerURL: providerOwnershipLedgerURL))
    let interruptedPluginOperations = try pluginRuntime.repository.incompleteRollbackOperations()
    if !interruptedPluginOperations.isEmpty {
      let recoveryTimestamp = ISO8601DateFormatter().string(from: Date())
      for interrupted in interruptedPluginOperations {
        try auditTrail.record(ControlSecurityAuditEvent(
          subjectID: interrupted.requestedBySubjectID,
          requestID: interrupted.operationID,
          target: "plugin.lifecycle",
          action: .operation,
          outcome: "started",
          reasonCode: "plugin.lifecycle-recovery-started",
          operationRef: interrupted.operationID,
          payloadDigest: interrupted.toPackageDigest,
          deduplicationKey: "plugin:\(interrupted.operationID):restart-recovery-started"
        ))
        try pluginRuntime.immutableStore.recoverInterruptedOperation(
          interrupted, repository: pluginRuntime.repository,
          timestamp: recoveryTimestamp)
        guard let recovered = try pluginRuntime.repository.rollback(
          operationID: interrupted.operationID),
          ["recovery-success-audit", "recovery-failure-audit"].contains(recovered.stage)
        else { throw PersistentControlServerError.persistenceFailed }
        try auditTrail.record(ControlSecurityAuditEvent(
          subjectID: interrupted.requestedBySubjectID,
          requestID: interrupted.operationID,
          target: "plugin.lifecycle",
          action: .operation,
          outcome: recovered.stage == "recovery-success-audit" ? "success" : "error",
          reasonCode: recovered.stage == "recovery-success-audit"
            ? "plugin.lifecycle-recovered" : "plugin.lifecycle-interrupted",
          operationRef: interrupted.operationID,
          payloadDigest: interrupted.toPackageDigest,
          deduplicationKey: "plugin:\(interrupted.operationID):restart-recovery"
        ))
        _ = try pluginRuntime.immutableStore.finalizeRecoveredOperation(
          operationID: interrupted.operationID, repository: pluginRuntime.repository,
          timestamp: recoveryTimestamp)
      }
    }
    let listener = try ControlUnixSocketListener(
      path: resolution.layout.controlSocket,
      recoverStaleSocket: true
    )
    let mutatingOperations = Set([
      "up", "down", "run", "start", "stop", "restart", "rm", "update",
      "image", "registry", "volume",
      "audit.export",
      "rbac.role.create", "rbac.role.update", "rbac.role.delete",
      "rbac.binding.create", "rbac.binding.delete",
      "rbac.delegation.create", "rbac.delegation.revoke",
      "admission.policy.create", "admission.policy.set-enabled",
      "admission.policy.delete", "admission.exception.create",
      "admission.exception.delete",
    ]).union(WorkloadProfileControlOperations.mutatingOperations)
      .union(PluginControlOperations.mutatingOperations)
    let server = try PersistentControlConnectionServer(
      authenticator: authenticator,
      requestRepository: requestRepository,
      daemonGeneration: UInt64.random(in: 1...UInt64(Int64.max)),
      socketIdentity: listener.identity,
      mutatingOperations: mutatingOperations,
      requestPreparer: { peer, request in
        if let prepared = try CLIControlCommandExecutor.prepare(
          request: request,
          environment: commandEnvironment,
          streamPreparation: true
        ) {
          return try PersistentControlPreparedRequest(
            request: prepared.request,
            execution: { _, _ in
              let preparation = try streamSources.prepare(
                peer: peer,
                route: prepared.route,
                environment: prepared.environment
              )
              return ControlResponseEnvelope(
                requestID: request.requestID,
                status: .completed,
                reasonCode: .completed,
                result: try Self.controlPlaneValue(preparation)
              )
            }
          )
        }
        if let prepared = try CLIControlCommandExecutor.prepare(
          request: request,
          environment: commandEnvironment
        ) {
          return try PersistentControlPreparedRequest(
            request: prepared.request,
            execution: { _, _ in
              try CLIControlCommandExecutor.execute(prepared: prepared)
            }
          )
        }
        return try PersistentControlPreparedRequest(request: request)
      },
      unaryRequestCoordinator: { _, operation in
        try StateUpgradeService(store: store).withExclusiveLifecycleFence(
          lockWaitMilliseconds: 5_000,
          operation
        )
      },
      mutationClassifier: { request in
        if try CLIControlRoute.validateStreamPreparation(request: request) != nil {
          return false
        }
        if let route = try CLIControlRoute.validate(request: request) {
          return route.mutating
        }
        return mutatingOperations.contains(request.operation)
      },
      auditRecorder: auditTrail,
      authorizer: { peer, request, at in
        let scope = try CLIControlRoute.validateStreamPreparation(request: request)?
          .authorizationScope ?? CLIControlRoute.validate(request: request)?.authorizationScope
        return try rbacAuthorizer.authorize(
          subject: peer.binding.subject,
          request: request,
          authoritativeProjectIdentifier: scope?.projectIdentifier,
          authoritativeResourceIdentifier: scope?.resourceIdentifier,
          at: at
        )
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
          peer: peer, request: request, localAPI: localAPI,
          commandEnvironment: commandEnvironment, streamSources: streamSources,
          auditTrail: auditTrail,
          rbacRepository: store.rbac, rbacAdministration: rbacAdministration,
          rbacAuthorizer: rbacAuthorizer, admissionRepository: store.admission,
          admissionAdministration: admissionAdministration,
          admissionEngine: admissionEngine, profileRepository: store.workloadProfiles,
          profileAdministration: profileAdministration, profileEngine: profileEngine,
          pluginRuntime: pluginRuntime)
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

  private static func prepareProviderOwnershipLedger(_ url: URL) throws {
    let descriptor = open(
      url.path, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR)
    if descriptor >= 0 {
      defer { close(descriptor) }
      let header = Data("recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity\n".utf8)
      let written = header.withUnsafeBytes { bytes in
        Darwin.write(descriptor, bytes.baseAddress, bytes.count)
      }
      guard written == header.count, fsync(descriptor) == 0 else {
        throw PersistentControlServerError.persistenceFailed
      }
      return
    }
    guard errno == EEXIST else { throw PersistentControlServerError.persistenceFailed }
    let existing = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard existing >= 0 else { throw PersistentControlServerError.persistenceFailed }
    defer { close(existing) }
    var metadata = stat()
    guard fstat(existing, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & 0o777 == 0o600, metadata.st_size >= 0,
      metadata.st_size <= 16 * 1_024 * 1_024
    else { throw PersistentControlServerError.persistenceFailed }
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
    if DispatchQueue.getSpecific(key: acceptQueueKey) == nil {
      acceptQueue.sync {}
    }
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
    _ = connectionGroup.wait(timeout: .now() + 5)
  }

  private func acceptLoop(
    listener: ControlUnixSocketListener,
    server: PersistentControlConnectionServer
  ) {
    while isCurrent(listener) {
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
        do {
          try server.serve(descriptor: descriptor)
        } catch {
          let reason = (error as? ControlPeerAuthenticationError)
            .map { "; reason=\(String(describing: $0))" } ?? ""
          let diagnostic = "control connection failed safely"
            + " (errorType=\(String(reflecting: type(of: error)))\(reason)).\n"
          FileHandle.standardError.write(Data(diagnostic.utf8))
        }
      }
    }
  }

  private func isCurrent(_ listener: ControlUnixSocketListener) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !stopped && self.listener === listener
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
    commandEnvironment: CLIEnvironment,
    streamSources: DaemonControlStreamSourceFactory,
    auditTrail: TamperEvidentAuditTrail,
    rbacRepository: RBACRepository,
    rbacAdministration: RBACAdministrationService,
    rbacAuthorizer: RBACAuthorizationEngine,
    admissionRepository: AdmissionRepository,
    admissionAdministration: AdmissionAdministrationService,
    admissionEngine: AdmissionPolicyEngine,
    profileRepository: WorkloadProfileRepository,
    profileAdministration: WorkloadProfileAdministrationService,
    profileEngine: WorkloadProfilePolicyEngine,
    pluginRuntime: PluginControlRuntime
  ) throws -> ControlResponseEnvelope {
    if let route = try CLIControlRoute.validateStreamPreparation(request: request) {
      let preparation = try streamSources.prepare(
        peer: peer,
        route: route,
        environment: commandEnvironment
      )
      return ControlResponseEnvelope(
        requestID: request.requestID,
        status: .completed,
        reasonCode: .completed,
        result: try controlPlaneValue(preparation)
      )
    }
    if let response = try CLIControlCommandExecutor.execute(
      request: request,
      environment: commandEnvironment
    ) {
      return response
    }
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
    if let response = PluginControlOperations.handle(
      peer: peer, request: request, runtime: pluginRuntime)
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
