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
import HostwrightHealth
import HostwrightPolicy
import HostwrightRegistry
import HostwrightRuntime
import HostwrightScheduler
import HostwrightState
import Synchronization

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
    let schedulerRepository = store.schedulerAdmissions
    let schedulerPressureCoordinator = SchedulerPressureAuthorityCoordinator(
      probe: SchedulerMacOSHostPressureProbe(),
      repository: schedulerRepository,
      clock: { Date() }
    )
    let schedulerRuntimeMetadata = try Self.waitForSchedulerRuntime {
      await commandEnvironment.runtimeAdapter().metadata()
    }
    let schedulerRuntimeVersion = try Self.waitForSchedulerRuntime {
      try await commandEnvironment.runtimeAdapter().runtimeVersion()
    }
    let schedulerAuthorityProvider = Self.makeSchedulerAuthorityProvider(
      store: store,
      repository: schedulerRepository,
      configPath: configuration.configPath,
      pressureCoordinator: schedulerPressureCoordinator,
      runtimeMetadata: schedulerRuntimeMetadata,
      runtimeVersion: schedulerRuntimeVersion
    )
    let schedulerLifecycleReconciler = UnattendedLifecycleReconciler(
      environment: commandEnvironment
    )
    let schedulerManifestPath = configuration.configPath
    let schedulerStateDatabasePath = configuration.stateDatabasePath
    let schedulerMaximumParallelism = configuration.maximumParallelism
    let schedulerRuntimeMutation: SchedulerControlOperations.RuntimeMutation = {
      reservation,
      preemptionIntent in
      let result = try Self.waitForSchedulerRuntime {
        try await schedulerLifecycleReconciler
          .executeAuthorizedSchedulerReservation(
            manifestPath: schedulerManifestPath,
            stateDatabasePath: schedulerStateDatabasePath,
            reservation: reservation,
            preemptionIntent: preemptionIntent,
            maximumParallelism: schedulerMaximumParallelism
          )
      }
      guard result.status.isSuccessfulIteration else {
        throw SchedulerControlOperationError.runtimeMutationFailed
      }
      return try Self.controlPlaneValue(result)
    }
    let schedulerPreemptionMutation: SchedulerControlOperations.PreemptionMutation = {
      intent in
      let reservations = try intent.proposal.victims.map { victim in
        guard let reservation = try schedulerRepository.activeReservation(
          workloadID: victim.workloadID,
          projectUUID: intent.projectID
        ) else {
          throw SchedulerControlOperationError.preemptionExecutionUnavailable
        }
        guard reservation.nodeID == victim.nodeID,
              reservation.resources == victim.allocation,
              reservation.ownerSubjectID == victim.subjectID else {
          throw SchedulerControlOperationError.preemptionExecutionUnavailable
        }
        return reservation
      }
      let result = try Self.waitForSchedulerRuntime {
        try await schedulerLifecycleReconciler
          .executeAuthorizedSchedulerVictims(
            manifestPath: schedulerManifestPath,
            stateDatabasePath: schedulerStateDatabasePath,
            intent: intent,
            reservations: reservations,
            maximumParallelism: schedulerMaximumParallelism
          )
      }
      guard result.status.isSuccessfulIteration else {
        throw SchedulerControlOperationError.runtimeMutationFailed
      }
      let inventory = try Self.waitForSchedulerRuntime {
        try await commandEnvironment.runtimeAdapter().inventory()
      }
      let evidence = try Self.schedulerPreemptionFenceEvidence(
        intent: intent,
        reservations: reservations,
        inventory: inventory,
        verifiedAt: ISO8601DateFormatter().string(from: Date()),
        planSHA256: result.planSHA256
      )
      return SchedulerControlOperations.PreemptionExecutionResult(
        fenceEvidence: evidence,
        mutation: try Self.controlPlaneValue(result)
      )
    }
    let schedulerRuntimeInventoryCache = SchedulerRuntimeInventoryCache()
    let schedulerRuntimeObservation: SchedulerStartupRecoveryCoordinator.RuntimeObservationProvider = {
      reservation in
      let inventory = try schedulerRuntimeInventoryCache.load {
        try Self.waitForSchedulerRuntime {
          try await commandEnvironment.runtimeAdapter().inventory()
        }
      }
      return try Self.schedulerRuntimeObservation(
        reservation: reservation,
        inventory: inventory
      )
    }
    _ = try SchedulerStartupRecoveryCoordinator(
      repository: schedulerRepository,
      observe: schedulerRuntimeObservation,
      now: { ISO8601DateFormatter().string(from: Date()) }
    ).recover()
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
        wasiOwnershipLedgerURL: providerOwnershipLedgerURL),
      trustedSignerCertificates: try PluginTrustedSignerAuthority.load())
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
      .union(SchedulerControlOperations.mutatingOperations)
    let mutationClassifier: PersistentControlConnectionServer.MutationClassifier = { request in
      if SchedulerControlOperations.isReadOnly(operation: request.operation) {
        return false
      }
      if try CLIControlRoute.validateStreamPreparation(request: request) != nil {
        return false
      }
      if let route = try CLIControlRoute.validate(request: request) {
        return route.mutating
      }
      return mutatingOperations.contains(request.operation)
    }
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
      unaryRequestCoordinator: { request, operation in
        let lockWaitMilliseconds = min(request.timeoutMilliseconds ?? 30_000, 30_000)
        return try StateUpgradeService(store: store).withBoundedStateAccessWait(
          lockWaitMilliseconds: lockWaitMilliseconds
        ) {
          guard try mutationClassifier(request) else { return try operation() }
          return try StateUpgradeService(store: store).withSerializedLifecycleMutation(
            lockWaitMilliseconds: lockWaitMilliseconds,
            operation
          )
        }
      },
      mutationClassifier: mutationClassifier,
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
          pluginRuntime: pluginRuntime,
          schedulerRepository: schedulerRepository,
          schedulerAuthorityProvider: schedulerAuthorityProvider,
          schedulerPressureCoordinator: schedulerPressureCoordinator,
          schedulerRuntimeMutation: schedulerRuntimeMutation,
          schedulerPreemptionMutation: schedulerPreemptionMutation)
      }
    )
    lock.lock()
    self.listener = listener
    stopped = false
    lock.unlock()
    let connectionStateStoreConfiguration = configuration.stateStoreConfiguration
    acceptQueue.async { [weak self] in
      self?.acceptLoop(
        listener: listener,
        server: server,
        stateStoreConfiguration: connectionStateStoreConfiguration
      )
    }
  }

  private static func makeSchedulerAuthorityProvider(
    store: SQLiteStateStore,
    repository: SchedulerAdmissionRepository,
    configPath: String,
    pressureCoordinator: SchedulerPressureAuthorityCoordinator,
    runtimeMetadata: RuntimeAdapterMetadata,
    runtimeVersion: String
  ) -> SchedulerControlOperations.AuthorityProvider {
    { projectIdentifier, decision, input in
      let project: SchedulerProjectAuthoritySnapshot
      if HostwrightResourceUUID.isValid(projectIdentifier) {
        guard let resolved = try repository.projectAuthority(
          forResourceUUID: projectIdentifier
        ) else {
          throw SchedulerControlOperationError.authorityUnavailable
        }
        project = resolved
      } else {
        guard let resolved = try repository.projectAuthority(
          forProjectID: projectIdentifier
        ) else {
          throw SchedulerControlOperationError.authorityUnavailable
        }
        project = resolved
      }
      let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
      let configDigest = SHA256.hash(data: configData)
        .map { String(format: "%02x", $0) }.joined()
      let profileDigest = SHA256.hash(
        data: try ControlPlaneCanonicalJSON.encode(store.workloadProfiles.listProfiles())
      ).map { String(format: "%02x", $0) }.joined()
      let lifecyclePlanDigest = project.manifestDigest
      let formatter = ISO8601DateFormatter()
      let now = Date()
      let createdAt = formatter.string(from: now)
      let expiresAt = formatter.string(from: now.addingTimeInterval(300))

      let bindings: [SchedulerDecisionWorkloadBinding]
      if let input {
        let workloads = Dictionary(uniqueKeysWithValues: input.pendingWorkloads.map {
          ($0.workloadID, $0)
        })
        bindings = try decision.workloadDecisions
          .filter { $0.outcome != .unschedulable }
          .map { workloadDecision in
            guard let workload = workloads[workloadDecision.workloadID],
                  let nodeID = workloadDecision.chosenNodeID
                    ?? workloadDecision.preemption?.nodeID else {
              throw SchedulerControlOperationError.authorityUnavailable
            }
            guard let capacity = try repository.nodeCapacity(nodeID: nodeID) else {
              throw SchedulerControlOperationError.authorityUnavailable
            }
            guard let pressure = try repository.hostPressure(nodeID: nodeID) else {
              throw SchedulerControlOperationError.pressureUnavailable
            }
            guard ![.critical, .unknown, .unavailable]
              .contains(pressure.posture.pressure) else {
              throw SchedulerControlOperationError.pressureUnavailable
            }
            guard let ownership = try store.ownership.loadAll().first(where: {
              $0.resourceType == "container" &&
                $0.resourceUUID == workload.workloadID.uuidString.lowercased() &&
                $0.projectResourceUUID == project.resourceUUID.lowercased() &&
                $0.projectID == project.projectID &&
                $0.projectGeneration == project.manifestVersion &&
                RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) ==
                  runtimeMetadata.providerID &&
                $0.serviceName != nil &&
                RuntimeManagedResourceIdentity.isSupportedIdentifier($0.resourceIdentifier) &&
                HostwrightResourceUUID.isValid($0.resourceUUID) &&
                HostwrightResourceUUID.isValid($0.fencingToken)
            }),
              let serviceName = ownership.serviceName,
              let ownershipProjectUUID = ownership.projectResourceUUID else {
              throw SchedulerControlOperationError.authorityUnavailable
            }
            let runtimeOwnership = try SchedulerRuntimeOwnershipBinding(
              resourceIdentifier: ownership.resourceIdentifier,
              resourceType: ownership.resourceType,
              resourceUUID: ownership.resourceUUID,
              resourceGeneration: Int64(ownership.resourceGeneration),
              projectUUID: ownershipProjectUUID,
              projectName: project.projectName,
              projectGeneration: Int64(ownership.projectGeneration),
              serviceName: serviceName,
              instanceName: nil,
              identityVersion: ownership.identityVersion,
              providerID: runtimeMetadata.providerID,
              providerAPIVersion: runtimeMetadata.providerAPIVersion,
              providerVersion: runtimeVersion,
              providerGeneration: Int64(ownership.providerGeneration),
              fencingToken: ownership.fencingToken
            )
            return try SchedulerDecisionWorkloadBinding(
              workloadID: workload.workloadID,
              nodeID: nodeID,
              resources: workloadDecision.capacityExplanation?.chargedCapacity
                ?? workload.requirements.request,
              capacityDigest: capacity.capacityDigest,
              capacityGeneration: capacity.generation,
              ownerSubjectID: workload.subjectID,
              projectUUID: project.resourceUUID,
              runtimeOwnership: runtimeOwnership
            )
          }
      } else {
        guard let artifact = try repository.decisionArtifact(id: decision.decisionID) else {
          throw SchedulerControlOperationError.authorityUnavailable
        }
        bindings = artifact.workloadBindings
      }

      if input == nil {
        _ = try pressureCoordinator.refresh(
          nodeIDs: bindings.map(\.nodeID)
        )
      }

      let authorities = try Dictionary(uniqueKeysWithValues: bindings.map { binding in
        guard let pressure = try repository.hostPressure(nodeID: binding.nodeID) else {
          throw SchedulerControlOperationError.pressureUnavailable
        }
        guard ![.critical, .unknown, .unavailable]
          .contains(pressure.posture.pressure) else {
          throw SchedulerControlOperationError.pressureUnavailable
        }
        guard let capacity = try repository.nodeCapacity(nodeID: binding.nodeID) else {
          throw SchedulerControlOperationError.authorityUnavailable
        }
        let fence = try repository.fencingState(nodeID: binding.nodeID)
        let authority = try SchedulerAdmissionCurrentAuthority(
          nodeCapacityDigest: capacity.capacityDigest,
          nodeCapacityGeneration: capacity.generation,
          configDigest: configDigest,
          profileDigest: profileDigest,
          lifecyclePlanDigest: lifecyclePlanDigest,
          expectedNodeEpoch: fence.nodeEpoch,
          expectedPressureGeneration: pressure.generation,
          expectedPressureEvidenceDigest: pressure.evidenceDigest,
          expectedPressurePosture: pressure.posture.pressure,
          leaseCreatedAt: createdAt,
          leaseExpiresAt: expiresAt
        )
        return (binding.workloadID, authority)
      })
      return SchedulerControlAuthoritySnapshot(
        projectUUID: project.resourceUUID.lowercased(),
        configDigest: configDigest,
        profileDigest: profileDigest,
        lifecyclePlanDigest: lifecyclePlanDigest,
        workloadBindings: bindings,
        currentAuthorities: authorities
      )
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
    server: PersistentControlConnectionServer,
    stateStoreConfiguration: StateStoreConfiguration
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
          let connectionStore = SQLiteStateStore(configuration: stateStoreConfiguration)
          try StateUpgradeService(store: connectionStore)
            .withBoundedStateAccessWait(
              lockWaitMilliseconds:
                ControlPlaneContract.maximumAuthenticationHandshakeMilliseconds
            ) {
              try server.serve(descriptor: descriptor)
            }
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
    pluginRuntime: PluginControlRuntime,
    schedulerRepository: SchedulerAdmissionRepository,
    schedulerAuthorityProvider: @escaping SchedulerControlOperations.AuthorityProvider,
    schedulerPressureCoordinator: SchedulerPressureAuthorityCoordinator,
    schedulerRuntimeMutation: @escaping SchedulerControlOperations.RuntimeMutation,
    schedulerPreemptionMutation: @escaping SchedulerControlOperations.PreemptionMutation
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
    if let response = SchedulerControlOperations.handle(
      request: request,
      repository: schedulerRepository,
      subjectID: peer.binding.subject.identifier,
      now: { ISO8601DateFormatter().string(from: Date()) },
      authorityProvider: schedulerAuthorityProvider,
      projectResolver: { projectID in
        if HostwrightResourceUUID.isValid(projectID) {
          return projectID.lowercased()
        }
        return try schedulerRepository.projectResourceUUID(forProjectID: projectID)
      },
      runtimeMutation: schedulerRuntimeMutation,
      pressureRefresher: { input in
        try schedulerPressureCoordinator.refresh(input: input)
      },
      preemptionMutation: schedulerPreemptionMutation
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
    let local = try? JSONDecoder().decode(
      LocalControlResponse.self,
      from: result.standardOutput
    )
    guard result.exitCode == 0, let local, local.success else {
      let diagnostic = sanitizedLocalControlFailure(local)
      return failure(
        requestID: request.requestID,
        reason: result.exitCode == LocalControlExitCode.invalidRequest.rawValue
          ? .invalidRequest : .internalError,
        code: diagnostic.code,
        message: diagnostic.message
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

  static func sanitizedLocalControlFailure(
    _ response: LocalControlResponse?
  ) -> (code: String, message: String) {
    let fallback = (
      code: "controlOperationFailed",
      message: "The control operation did not complete."
    )
    guard let error = response?.error,
      case .object(let fields) = error
    else { return fallback }

    let code: String
    if case .string(let candidate) = fields["code"],
      candidate.range(
        of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$",
        options: .regularExpression
      ) != nil
    {
      code = candidate
    } else {
      code = fallback.code
    }

    guard case .string(let candidate) = fields["message"] else {
      return (code, fallback.message)
    }
    let redacted = RuntimeRedactionPolicy.default.redact(candidate)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !redacted.isEmpty else { return (code, fallback.message) }
    var bounded = redacted
    while bounded.utf8.count > 256 {
      bounded.removeLast()
    }
    return (code, bounded)
  }

  private static func controlPlaneValue<T: Encodable>(
    _ value: T
  ) throws -> ControlPlaneJSONValue {
    try JSONDecoder().decode(
      ControlPlaneJSONValue.self,
      from: JSONEncoder().encode(value)
    )
  }

  private static func schedulerDigest(_ fields: [String]) -> String {
    SHA256.hash(data: Data(fields.joined(separator: "\u{1f}").utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func schedulerRuntimeFenceToken(
    _ reservation: SchedulerReservationRecord
  ) -> String {
    let operationKey = SHA256.hash(
      data: Data([
        "scheduler-up",
        reservation.decisionID.uuidString.lowercased(),
        reservation.reservationID.uuidString.lowercased(),
        reservation.fencingToken.stableKey,
      ].joined(separator: "|").utf8)
    )
    .map { String(format: "%02x", $0) }
    .joined()
    return HostwrightResourceUUID.legacy(
      kind: "lifecycle-fencing",
      identifier: operationKey
    )
  }

  static func schedulerRuntimeObservation(
    reservation: SchedulerReservationRecord,
    inventory: RuntimeInventory
  ) throws -> SchedulerRuntimeObservation {
    let digest = inventory.semanticSHA256
    guard let expected = reservation.runtimeOwnership,
          inventory.isAuthoritative,
          inventory.machine.state == .running,
          !inventory.machine.operatingSystem.isEmpty,
          !inventory.machine.architecture.isEmpty,
          !inventory.machine.runtimeVersion.isEmpty,
          !inventory.machine.services.isEmpty,
          inventory.machine.services.allSatisfy({
            !$0.required && $0.state != .unknown ||
              ($0.required && $0.state == .running)
          }),
          inventory.machine.services.contains(where: {
            $0.required && $0.state == .running
          }) else {
      return try SchedulerRuntimeObservation(
        state: .unknown,
        evidenceDigest: digest
      )
    }

    let expectedResourceUUID = expected.resourceUUID.lowercased()
    let expectedIdentifier = expected.resourceIdentifier
    let candidates = inventory.containers.filter { container in
      let labels = Dictionary(uniqueKeysWithValues: container.labels.map {
        ($0.key, $0.value)
      })
      return container.name == expectedIdentifier ||
        labels[RuntimeManagedResourceIdentity.resourceIdentifierLabel] == expectedIdentifier ||
        labels[RuntimeManagedResourceIdentity.resourceUUIDLabel]?.lowercased() ==
          expectedResourceUUID ||
        container.ownership?.resourceUUID.lowercased() == expectedResourceUUID
    }
    guard candidates.count <= 1 else {
      return try SchedulerRuntimeObservation(
        state: .unknown,
        evidenceDigest: digest
      )
    }
    guard let candidate = candidates.first else {
      return try SchedulerRuntimeObservation(
        state: .absent,
        evidenceDigest: digest
      )
    }
    let labels = Dictionary(uniqueKeysWithValues: candidate.labels.map {
      ($0.key, $0.value)
    })
    let identity = RuntimeManagedResourceIdentity.identity(from: labels)
    let lifecycleFence = Self.schedulerRuntimeFenceToken(reservation)
    guard candidate.ownership?.resourceUUID.lowercased() == expectedResourceUUID,
          candidate.ownership?.projectUUID.lowercased() == expected.projectUUID,
          candidate.ownership?.resourceGeneration == Int(expected.resourceGeneration),
          candidate.ownership?.projectGeneration == Int(expected.projectGeneration),
          candidate.ownership?.providerID == expected.providerID,
          candidate.ownership?.providerGeneration == Int(expected.providerGeneration),
          labels[RuntimeManagedResourceIdentity.managedLabel] == "true",
          labels[RuntimeManagedResourceIdentity.identityVersionLabel] ==
            String(expected.identityVersion),
          identity?.projectName == expected.projectName,
          identity?.serviceName == expected.serviceName,
          identity?.instanceName == expected.instanceName,
          labels[RuntimeManagedResourceIdentity.resourceIdentifierLabel] == expectedIdentifier,
          labels[RuntimeManagedResourceIdentity.resourceUUIDLabel]?.lowercased() == expectedResourceUUID,
          labels[RuntimeManagedResourceIdentity.projectUUIDLabel]?.lowercased() == expected.projectUUID,
          labels[RuntimeManagedResourceIdentity.resourceGenerationLabel] ==
            String(expected.resourceGeneration),
          labels[RuntimeManagedResourceIdentity.projectGenerationLabel] ==
            String(expected.projectGeneration),
          labels[RuntimeManagedResourceIdentity.providerIDLabel] == expected.providerID.rawValue,
          labels[RuntimeManagedResourceIdentity.providerGenerationLabel] ==
            String(expected.providerGeneration),
          labels[RuntimeManagedResourceIdentity.fencingTokenLabel] == lifecycleFence,
          candidate.ownership?.fencingToken == lifecycleFence,
          inventory.machine.runtimeVersion == expected.providerVersion else {
      return try SchedulerRuntimeObservation(
        state: .unknown,
        evidenceDigest: digest
      )
    }
    let state: SchedulerRuntimeObservationState
    switch candidate.lifecycle {
    case .running:
      guard candidate.health.availability == .available,
            candidate.health.state == .healthy else {
        return try SchedulerRuntimeObservation(
          state: .unknown,
          evidenceDigest: digest
        )
      }
      state = .present
    case .missing:
      state = .absent
    case .created, .stopped, .exited, .failed, .unknown:
      state = .unknown
    }
    return try SchedulerRuntimeObservation(
      state: state,
      evidenceDigest: digest
    )
  }

  static func schedulerPreemptionFenceEvidence(
    intent: SchedulerPreemptionIntentRecord,
    reservations: [SchedulerReservationRecord],
    inventory: RuntimeInventory,
    verifiedAt: String,
    planSHA256: String
  ) throws -> [SchedulerFenceEvidence] {
    let ordered = reservations.sorted {
      ($0.workloadID.uuidString.lowercased(),
       $0.reservationID.uuidString.lowercased()) <
      ($1.workloadID.uuidString.lowercased(),
       $1.reservationID.uuidString.lowercased())
    }
    guard ordered.count == intent.proposal.victims.count,
          Set(ordered.map(\.workloadID)) ==
            Set(intent.proposal.victims.map(\.workloadID)) else {
      throw SchedulerControlOperationError.preemptionExecutionUnavailable
    }

    var evidence: [SchedulerFenceEvidence] = []
    evidence.reserveCapacity(ordered.count)
    for reservation in ordered {
      let observation = try schedulerRuntimeObservation(
        reservation: reservation,
        inventory: inventory
      )
      guard observation.state == .absent else {
        throw SchedulerControlOperationError.preemptionExecutionUnavailable
      }
      let evidenceDigest = schedulerDigest([
        "scheduler-victim-absence",
        intent.intentID.uuidString.lowercased(),
        reservation.reservationID.uuidString.lowercased(),
        reservation.workloadID.uuidString.lowercased(),
        reservation.fencingToken.stableKey,
        verifiedAt,
        planSHA256,
        observation.evidenceDigest,
      ])
      evidence.append(
        try SchedulerFenceEvidence(
          token: reservation.fencingToken,
          reservationID: reservation.reservationID,
          workloadID: reservation.workloadID,
          evidenceDigest: evidenceDigest,
          verifiedAt: verifiedAt
        )
      )
    }
    return evidence
  }

  static func waitForSchedulerRuntime<T: Sendable>(
    timeoutNanoseconds: UInt64 = schedulerRuntimeMaximumWaitNanoseconds,
    pollNanoseconds: UInt64 = schedulerRuntimePollNanoseconds,
    _ operation: @escaping @Sendable () async throws -> T
  ) throws -> T {
    guard timeoutNanoseconds > 0,
          timeoutNanoseconds <= schedulerRuntimeMaximumWaitNanoseconds,
          pollNanoseconds > 0,
          pollNanoseconds <= timeoutNanoseconds else {
      throw SchedulerRuntimeWaitError.invalidLimit
    }
    let semaphore = DispatchSemaphore(value: 0)
    let box = SchedulerRuntimeResultBox<T>()
    let child = Task {
      do {
        box.store(.success(try await operation()))
      } catch {
        box.store(.failure(error))
      }
      semaphore.signal()
    }
    let start = DispatchTime.now().uptimeNanoseconds
    let (deadline, overflow) = start.addingReportingOverflow(timeoutNanoseconds)
    guard !overflow else {
      child.cancel()
      throw SchedulerRuntimeWaitError.invalidLimit
    }
    while true {
      if Task.isCancelled {
        child.cancel()
        throw SchedulerRuntimeWaitError.cancelled
      }
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else {
        child.cancel()
        throw SchedulerRuntimeWaitError.timedOut
      }
      let remaining = deadline - now
      let waitNanoseconds = min(remaining, pollNanoseconds)
      if semaphore.wait(
        timeout: .now() + .nanoseconds(Int(waitNanoseconds))
      ) == .success {
        guard let result = box.load() else {
          throw SchedulerRuntimeWaitError.missingResult
        }
        return try result.get()
      }
    }
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

let schedulerRuntimeMaximumWaitNanoseconds: UInt64 = 30_000_000_000
let schedulerRuntimePollNanoseconds: UInt64 = 5_000_000

enum SchedulerRuntimeWaitError: Error, Equatable {
  case cancelled
  case timedOut
  case invalidLimit
  case missingResult
  case runtimeUnavailable
}

private final class SchedulerRuntimeResultBox<T: Sendable>: Sendable {
  private let result = Mutex<Result<T, Error>?>(nil)

  func store(_ result: Result<T, Error>) {
    self.result.withLock { value in
      value = result
    }
  }

  func load() -> Result<T, Error>? {
    result.withLock { $0 }
  }
}

private final class SchedulerRuntimeInventoryCache: Sendable {
  private enum State: Sendable {
    case idle
    case loading
    case loaded(RuntimeInventory)
    case failed
  }

  private let state = Mutex<State>(.idle)

  func load(_ loader: () throws -> RuntimeInventory) throws -> RuntimeInventory {
    let mode = state.withLock { state -> State in
      switch state {
      case .idle:
        state = .loading
        return .loading
      case .loading, .failed, .loaded:
        return state
      }
    }
    switch mode {
    case .loaded(let inventory):
      return inventory
    case .loading:
      break
    case .idle, .failed:
      throw SchedulerRuntimeWaitError.runtimeUnavailable
    }

    do {
      let value = try loader()
      state.withLock { $0 = .loaded(value) }
      return value
    } catch {
      state.withLock { $0 = .failed }
      throw error
    }
  }
}
