import Foundation
import HostwrightControlPlane
import HostwrightCore
import HostwrightScheduler
import HostwrightState

struct SchedulerControlAuthoritySnapshot: Sendable {
  let projectUUID: String
  let configDigest: String
  let profileDigest: String
  let lifecyclePlanDigest: String
  let workloadBindings: [SchedulerDecisionWorkloadBinding]
  let currentAuthorities: [UUID: SchedulerAdmissionCurrentAuthority]
}

enum SchedulerControlOperations {
  typealias RuntimeMutation = @Sendable (
    SchedulerReservationRecord,
    SchedulerPreemptionIntentRecord?
  ) throws -> ControlPlaneJSONValue
  struct PreemptionExecutionResult: Sendable {
    let fenceEvidence: [SchedulerFenceEvidence]
    let mutation: ControlPlaneJSONValue
  }
  typealias PreemptionMutation = @Sendable (
    SchedulerPreemptionIntentRecord
  ) throws -> PreemptionExecutionResult
  typealias AuthorityProvider = @Sendable (
    String,
    SchedulerDecision,
    SchedulerEngineInput?
  ) throws -> SchedulerControlAuthoritySnapshot
  typealias ProjectResolver = @Sendable (String) throws -> String?
  typealias PressureRefresher = @Sendable (SchedulerEngineInput) throws -> SchedulerEngineInput

  static let readOperations: Set<String> = Set(
    SchedulerControlOperation.allCases.filter { !$0.isMutating }.map(\.rawValue)
  )
  static let mutatingOperations: Set<String> = [
    SchedulerControlOperation.plan.rawValue,
    SchedulerControlOperation.apply.rawValue,
  ]

  static func isReadOnly(operation: String) -> Bool {
    readOperations.contains(operation) && !mutatingOperations.contains(operation)
  }

  static func handle(
    request: ControlRequestEnvelope
  ) -> ControlResponseEnvelope? {
    guard let operation = SchedulerControlOperation(rawValue: request.operation) else {
      return nil
    }
    guard operation == .simulate else {
      return failure(
        requestID: request.requestID,
        protocolRevision: request.protocolRevision,
        code: "schedulerAuthorityUnavailable",
        reason: .internalError
      )
    }
    return handlePlanOrSimulation(
      request: request,
      operation: operation,
      repository: nil,
      now: nil,
      authorityProvider: nil,
      projectResolver: nil,
      pressureRefresher: nil
    )
  }

  static func handle(
    request: ControlRequestEnvelope,
    repository: SchedulerAdmissionRepository,
    subjectID: String? = nil,
    now: @escaping @Sendable () -> String,
    authorityProvider: AuthorityProvider? = nil,
    projectResolver: ProjectResolver? = nil,
    runtimeMutation: RuntimeMutation? = nil,
    pressureRefresher: PressureRefresher? = nil,
    preemptionMutation: PreemptionMutation? = nil
  ) -> ControlResponseEnvelope? {
    guard let operation = SchedulerControlOperation(rawValue: request.operation) else {
      return nil
    }
    guard request.protocolRevision == .current else {
      return revisionFailure(requestID: request.requestID, protocolRevision: request.protocolRevision)
    }

    let resolver: ProjectResolver = projectResolver ?? { projectID in
      if HostwrightResourceUUID.isValid(projectID) {
        return projectID.lowercased()
      }
      return try repository.projectResourceUUID(forProjectID: projectID)
    }

    switch operation {
    case .plan, .simulate:
      return handlePlanOrSimulation(
        request: request,
        operation: operation,
        repository: repository,
        now: now,
        authorityProvider: authorityProvider,
        projectResolver: resolver,
        pressureRefresher: pressureRefresher
      )
    case .status, .explain:
      do {
        let reference = try SchedulerControlWireContract.decisionReference(from: request.body)
        let projectUUID = try resolvedProjectID(reference.projectID, using: resolver)
        guard let snapshot = try repository.decisionState(
          id: reference.decisionID,
          projectUUID: projectUUID
        ) else {
          return failure(
            requestID: request.requestID,
            protocolRevision: request.protocolRevision,
            code: "schedulerDecisionUnavailable",
            reason: .invalidRequest
          )
        }
        let result = try statusResult(
          snapshot: snapshot,
          includeExplanation: operation == .explain
        )
        return completed(
          requestID: request.requestID,
          protocolRevision: request.protocolRevision,
          result: result
        )
      } catch let error as SchedulerControlOperationError {
        return failure(
          requestID: request.requestID,
          protocolRevision: request.protocolRevision,
          code: error.code,
          reason: error.reason
        )
      } catch is SchedulerPressureAuthorityError {
        return failure(
          requestID: request.requestID,
          protocolRevision: request.protocolRevision,
          code: "schedulerPressureUnavailable",
          reason: .internalError
        )
      } catch {
        return failure(
          requestID: request.requestID,
          protocolRevision: request.protocolRevision,
          code: "schedulerDecisionUnavailable",
          reason: .invalidRequest
        )
      }
    case .apply:
      guard let runtimeMutation, let authorityProvider else {
        return failure(
          requestID: request.requestID,
          protocolRevision: request.protocolRevision,
          code: "schedulerAuthorityUnavailable",
          reason: .internalError
        )
      }
      do {
        let applied = try apply(
          request: request,
          repository: repository,
          subjectID: subjectID,
          now: now,
          authorityProvider: authorityProvider,
          projectResolver: resolver,
          runtimeMutation: runtimeMutation,
          preemptionMutation: preemptionMutation
        )
        return completed(
          requestID: request.requestID,
          protocolRevision: request.protocolRevision,
          result: applied
        )
      } catch let error as SchedulerControlOperationError {
        return failure(
          requestID: request.requestID,
          protocolRevision: request.protocolRevision,
          code: error.code,
          reason: error.reason
        )
      } catch is SchedulerPressureAuthorityError {
        return failure(
          requestID: request.requestID,
          protocolRevision: request.protocolRevision,
          code: "schedulerPressureUnavailable",
          reason: .internalError
        )
      } catch {
        return failure(
          requestID: request.requestID,
          protocolRevision: request.protocolRevision,
          code: "schedulerApplyRejected",
          reason: .invalidRequest
        )
      }
    }
  }

  private static func handlePlanOrSimulation(
    request: ControlRequestEnvelope,
    operation: SchedulerControlOperation,
    repository: SchedulerAdmissionRepository?,
    now: (@Sendable () -> String)?,
    authorityProvider: AuthorityProvider?,
    projectResolver: ProjectResolver?,
    pressureRefresher: PressureRefresher?
  ) -> ControlResponseEnvelope {
    guard request.protocolRevision == .current else {
      return revisionFailure(requestID: request.requestID, protocolRevision: request.protocolRevision)
    }

    do {
      let scoped = try SchedulerControlWireContract.scopedInputData(from: request.body)
      let input = try Phase09StrictDecoder.decode(
        SchedulerEngineInput.self,
        from: scoped.inputData,
        allowedKeys: SchedulerControlWireContract.inputKeys,
        requiredKeys: ["pendingWorkloads", "nodes"]
      )
      var schedulingInput: SchedulerEngineInput
      var canonicalProjectUUID: String?
      if repository != nil {
        let projectUUID = try resolvedProjectID(scoped.projectID, using: projectResolver)
        canonicalProjectUUID = projectUUID
        try validateProjectScope(
          projectID: scoped.projectID,
          canonicalProjectID: projectUUID,
          input: input
        )
        schedulingInput = try canonicalizedInput(
          input,
          sourceProjectID: scoped.projectID,
          canonicalProjectID: projectUUID
        )
      } else {
        try validateProjectScope(
          projectID: scoped.projectID,
          canonicalProjectID: nil,
          input: input
        )
        schedulingInput = input
      }
      if operation == .plan, let pressureRefresher {
        schedulingInput = try pressureRefresher(schedulingInput)
      }
      let decision: SchedulerDecision
      switch operation {
      case .plan:
        decision = try SchedulerEngine().plan(schedulingInput)
      case .simulate:
        decision = try SchedulerEngine().simulate(schedulingInput)
      default:
        throw SchedulerControlOperationError.invalidBody
      }

      if operation == .plan {
        guard let repository, let now, let authorityProvider else {
          throw SchedulerControlOperationError.authorityUnavailable
        }
        let authority = try authorityProvider(
          scoped.projectID,
          decision,
          schedulingInput
        )
        guard let canonicalProjectUUID,
              authority.projectUUID.lowercased() == canonicalProjectUUID else {
          throw SchedulerControlScopeError.crossProjectEntity
        }
        let createdAt = now()
        _ = try repository.recordDecisionArtifact(
          decision: decision,
          workloadBindings: authority.workloadBindings,
          projectUUID: authority.projectUUID,
          configDigest: authority.configDigest,
          profileDigest: authority.profileDigest,
          lifecyclePlanDigest: authority.lifecyclePlanDigest,
          createdAt: createdAt,
          updatedAt: createdAt
        )
      }

      let resultData = try ControlPlaneCanonicalJSON.encode(decision)
      guard resultData.count <= ControlPlaneContract.maximumResponseOrFrameBytes else {
        return failure(
          requestID: request.requestID,
          protocolRevision: request.protocolRevision,
          code: "schedulerResultTooLarge",
          reason: .internalError
        )
      }
      let result = try JSONDecoder().decode(ControlPlaneJSONValue.self, from: resultData)
      return completed(
        requestID: request.requestID,
        protocolRevision: request.protocolRevision,
        result: result
      )
    } catch let error as SchedulerControlOperationError {
      return failure(
        requestID: request.requestID,
        protocolRevision: request.protocolRevision,
        code: error.code,
        reason: error.reason
      )
    } catch is SchedulerPressureAuthorityError {
      return failure(
        requestID: request.requestID,
        protocolRevision: request.protocolRevision,
        code: "schedulerPressureUnavailable",
        reason: .internalError
      )
    } catch {
      return failure(
        requestID: request.requestID,
        protocolRevision: request.protocolRevision,
        code: "schedulerInvalidRequest",
        reason: .invalidRequest
      )
    }
  }

  private static func apply(
    request: ControlRequestEnvelope,
    repository: SchedulerAdmissionRepository,
    subjectID: String?,
    now: @escaping @Sendable () -> String,
    authorityProvider: AuthorityProvider,
    projectResolver: ProjectResolver?,
    runtimeMutation: RuntimeMutation,
    preemptionMutation: PreemptionMutation?
  ) throws -> ControlPlaneJSONValue {
    let data = try SchedulerControlWireContract.applyData(from: request.body)
    let projectUUID = try resolvedProjectID(data.projectID, using: projectResolver)
    guard let artifact = try repository.decisionArtifact(
      id: data.decisionID,
      projectUUID: projectUUID
    ),
          artifact.inputDigest == data.expectedInputDigest else {
      throw SchedulerControlOperationError.staleDecision
    }
    guard let workloadDecision = artifact.decision.workloadDecisions.first(
      where: { $0.workloadID == data.workloadID }
    ), workloadDecision.outcome != .unschedulable else {
      throw SchedulerControlOperationError.invalidBody
    }
    guard let storedBinding = artifact.binding(for: data.workloadID) else {
      throw SchedulerControlOperationError.invalidBody
    }
    let authority = try authorityProvider(data.projectID, artifact.decision, nil)
    guard authority.projectUUID == artifact.projectUUID,
          let current = authority.currentAuthorities[data.workloadID],
          subjectID == nil || subjectID == storedBinding.ownerSubjectID else {
      throw SchedulerControlOperationError.staleAuthority
    }

    let applied = try repository.applyDecision(
      decisionID: artifact.decisionID,
      projectUUID: artifact.projectUUID,
      workloadID: data.workloadID,
      expectedInputDigest: data.expectedInputDigest,
      currentAuthority: current
    )
    var effective = applied
    var victimMutation: ControlPlaneJSONValue?
    if let proposedIntent = applied.preemptionIntent,
       applied.reservation == nil {
      guard let preemptionMutation else {
        throw SchedulerControlOperationError.preemptionExecutionUnavailable
      }
      let execution: PreemptionExecutionResult
      do {
        execution = try preemptionMutation(proposedIntent)
      } catch {
        // Victim execution is an internal daemon boundary.  Preserve the
        // durable proposed intent and report an internal failure rather than
        // misclassifying a runtime/death error as caller input.
        throw SchedulerControlOperationError.runtimeMutationFailed
      }
      let refreshedAuthority = try authorityProvider(
        data.projectID,
        artifact.decision,
        nil
      )
      guard refreshedAuthority.projectUUID == artifact.projectUUID,
            let refreshed = refreshedAuthority.currentAuthorities[data.workloadID] else {
        throw SchedulerControlOperationError.staleAuthority
      }
      effective = try repository.completePreemptionDecision(
        decisionID: artifact.decisionID,
        projectUUID: artifact.projectUUID,
        workloadID: data.workloadID,
        expectedInputDigest: data.expectedInputDigest,
        currentAuthority: refreshed,
        fenceEvidence: execution.fenceEvidence,
        transitionAt: now()
      )
      victimMutation = execution.mutation
    }
    guard let reserved = effective.reservation else {
      throw SchedulerControlOperationError.preemptionExecutionUnavailable
    }
    let intent = effective.preemptionIntent

    if reserved.status == .committed {
      if let intent, intent.status == .fenced {
        let appliedIntent = try repository.transitionPreemptionIntent(
          intentID: intent.intentID,
          expectedRecordDigest: intent.recordDigest,
          to: .applied,
          updatedAt: now()
        )
        effective = try SchedulerAdmissionApplyResult(
          decisionID: effective.decisionID,
          inputDigest: effective.inputDigest,
          reservation: reserved,
          preemptionIntent: appliedIntent
        )
      }
      return try jsonValue(effective)
    }

    // Runtime mutation is intentionally outside the durable state transaction.
    let mutation: ControlPlaneJSONValue
    do {
      mutation = try runtimeMutation(reserved, intent)
    } catch {
      // Leave the pending reservation and fenced intent durable for recovery;
      // the runtime boundary must never turn its failure into a release.
      throw SchedulerControlOperationError.runtimeMutationFailed
    }
    let committed = try repository.commit(
      reservationID: reserved.reservationID,
      expectedToken: reserved.fencingToken,
      updatedAt: now()
    )
    if let intent, intent.status == .fenced {
      let appliedIntent = try repository.transitionPreemptionIntent(
        intentID: intent.intentID,
        expectedRecordDigest: intent.recordDigest,
        to: .applied,
        updatedAt: now()
      )
      effective = try SchedulerAdmissionApplyResult(
        decisionID: effective.decisionID,
        inputDigest: effective.inputDigest,
        reservation: committed,
        preemptionIntent: appliedIntent
      )
    } else {
      effective = try SchedulerAdmissionApplyResult(
        decisionID: effective.decisionID,
        inputDigest: effective.inputDigest,
        reservation: committed,
        preemptionIntent: intent
      )
    }
    var result: [String: ControlPlaneJSONValue] = [
      "apply": try jsonValue(
        effective
      ),
      "mutation": mutation,
    ]
    if let victimMutation {
      result["victimMutation"] = victimMutation
    }
    if let finalIntent = effective.preemptionIntent {
      result["preemptionIntent"] = try jsonValue(finalIntent)
    }
    return .object(result)
  }

  private static func validateProjectScope(
    projectID: String,
    canonicalProjectID: String?,
    input: SchedulerEngineInput
  ) throws {
    let acceptsProjectID: (String) -> Bool = { value in
      guard let canonicalProjectID else { return value == projectID }
      return value == projectID || value == canonicalProjectID
    }
    guard input.pendingWorkloads.allSatisfy({ acceptsProjectID($0.projectID) }),
          input.fairnessStates.allSatisfy({ acceptsProjectID($0.projectID) }) else {
      throw SchedulerControlScopeError.crossProjectEntity
    }

    let workloadsByID = Dictionary(uniqueKeysWithValues: input.pendingWorkloads.map {
      ($0.workloadID, $0)
    })
    guard input.existingPlacements.allSatisfy({ placement in
      guard let workload = workloadsByID[placement.workloadID] else {
        return false
      }
      return acceptsProjectID(workload.projectID)
    }) else {
      throw SchedulerControlScopeError.crossProjectEntity
    }
    guard input.victimAllocations.allSatisfy({ acceptsProjectID($0.projectID) }),
          input.disruptionBudgets.allSatisfy({ acceptsProjectID($0.projectID) }) else {
      throw SchedulerControlScopeError.crossProjectEntity
    }
  }

  private static func statusResult(
    snapshot: SchedulerDecisionStateSnapshot,
    includeExplanation: Bool
  ) throws -> ControlPlaneJSONValue {
    let artifact = snapshot.artifact
    let statuses = Set(snapshot.reservations.map(\.status))
    let status: String
    if statuses.isEmpty {
      status = "planned"
    } else if statuses.contains(.pending) || statuses.contains(.releasePending) {
      status = "pending"
    } else if statuses.contains(.committed) {
      status = "committed"
    } else {
      status = statuses.sorted { $0.rawValue < $1.rawValue }.first?.rawValue ?? "planned"
    }
    var result: [String: ControlPlaneJSONValue] = [
      "artifact": try jsonValue(artifact),
      "decision": try jsonValue(artifact.decision),
      "decisionID": .string(artifact.decisionID.uuidString.lowercased()),
      "inputDigest": .string(artifact.inputDigest),
      "status": .string(status),
      "reservations": try jsonValue(snapshot.reservations),
    ]
    if includeExplanation {
      result["explanation"] = try jsonValue(artifact.decision.workloadDecisions)
    }
    return .object(result)
  }

  private static func resolvedProjectID(
    _ projectID: String,
    using resolver: ProjectResolver?
  ) throws -> String {
    let resolved = try resolver?(projectID) ?? projectID
    guard HostwrightResourceUUID.isValid(resolved) else {
      throw SchedulerControlOperationError.projectScope
    }
    return resolved.lowercased()
  }

  private static func canonicalizedInput(
    _ input: SchedulerEngineInput,
    sourceProjectID: String,
    canonicalProjectID: String
  ) throws -> SchedulerEngineInput {
    guard HostwrightResourceUUID.isValid(canonicalProjectID) else {
      throw SchedulerControlOperationError.projectScope
    }
    let acceptsProjectID: (String) -> Bool = { value in
      value == sourceProjectID || value == canonicalProjectID
    }
    let workloads = try input.pendingWorkloads.map { workload in
      guard acceptsProjectID(workload.projectID) else {
        throw SchedulerControlScopeError.crossProjectEntity
      }
      return try SchedulerWorkload(
        requirements: workload.requirements,
        priority: workload.priority,
        subjectID: workload.subjectID,
        projectID: canonicalProjectID,
        topology: workload.topology,
        locality: workload.locality,
        disruption: workload.disruption,
        constraints: workload.constraints,
        overhead: workload.overhead,
        safetyMargin: workload.safetyMargin,
        binClass: workload.binClass,
        preemptionEligibility: workload.preemptionEligibility
      )
    }
    let fairness = try input.fairnessStates.map { state in
      guard acceptsProjectID(state.projectID) else {
        throw SchedulerControlScopeError.crossProjectEntity
      }
      return try SchedulerFairnessState(
        subjectID: state.subjectID,
        projectID: canonicalProjectID,
        usage: state.usage,
        guarantee: state.guarantee,
        reclaimableBorrowedUsage: state.reclaimableBorrowedUsage,
        quota: state.quota,
        pendingDemand: state.pendingDemand,
        starvationAgeUnits: state.starvationAgeUnits,
        weight: state.weight
      )
    }
    let victims = try input.victimAllocations.map { victim in
      guard acceptsProjectID(victim.projectID) else {
        throw SchedulerControlScopeError.crossProjectEntity
      }
      return try SchedulerVictimAllocation(
        workloadID: victim.workloadID,
        nodeID: victim.nodeID,
        allocation: victim.allocation,
        subjectID: victim.subjectID,
        projectID: canonicalProjectID,
        priority: victim.priority,
        disruptionCostBasisPoints: victim.disruptionCostBasisPoints,
        budgetID: victim.budgetID,
        preemptible: victim.preemptible,
        reclaimableBorrowed: victim.reclaimableBorrowed,
        starvationAgeUnits: victim.starvationAgeUnits,
        topologyGroupID: victim.topologyGroupID
      )
    }
    let budgets = try input.disruptionBudgets.map { budget in
      guard acceptsProjectID(budget.projectID) else {
        throw SchedulerControlScopeError.crossProjectEntity
      }
      return try SchedulerDisruptionBudget(
        budgetID: budget.budgetID,
        projectID: canonicalProjectID,
        remainingVictimCount: budget.remainingVictimCount,
        remainingDisruptionCostBasisPoints: budget.remainingDisruptionCostBasisPoints
      )
    }
    return try SchedulerEngineInput(
      pendingWorkloads: workloads,
      nodes: input.nodes,
      fairnessStates: fairness,
      existingPlacements: input.existingPlacements,
      victimAllocations: victims,
      disruptionBudgets: budgets,
      antiChurnThresholdBasisPoints: input.antiChurnThresholdBasisPoints,
      scoringWeights: input.scoringWeights,
      overcommitRatios: input.overcommitRatios,
      preemptionPolicy: input.preemptionPolicy,
      queuePolicy: input.queuePolicy,
      stabilityPolicy: input.stabilityPolicy,
      snapshotQuality: input.snapshotQuality,
      limits: input.limits
    )
  }

  private static func jsonValue<T: Encodable>(_ value: T) throws -> ControlPlaneJSONValue {
    try JSONDecoder().decode(
      ControlPlaneJSONValue.self,
      from: ControlPlaneCanonicalJSON.encode(value)
    )
  }

  private static func completed(
    requestID: String,
    protocolRevision: ControlProtocolRevision?,
    result: ControlPlaneJSONValue
  ) -> ControlResponseEnvelope {
    ControlResponseEnvelope(
      protocolRevision: protocolRevision ?? .current,
      requestID: requestID,
      status: .completed,
      reasonCode: .completed,
      result: result
    )
  }

  private static func revisionFailure(
    requestID: String,
    protocolRevision: ControlProtocolRevision?
  ) -> ControlResponseEnvelope {
    ControlResponseEnvelope(
      protocolRevision: protocolRevision ?? .current,
      requestID: requestID,
      status: .rejected,
      reasonCode: .unsupportedProtocolRevision,
      error: SanitizedError(
        code: "schedulerProtocolRevisionRequired",
        message: "This scheduler operation requires control protocol revision 2.2."
      )
    )
  }

  private static func failure(
    requestID: String,
    protocolRevision: ControlProtocolRevision?,
    code: String,
    reason: ControlReasonCode
  ) -> ControlResponseEnvelope {
    ControlResponseEnvelope(
      protocolRevision: protocolRevision ?? .current,
      requestID: requestID,
      status: .rejected,
      reasonCode: reason,
      error: SanitizedError(
        code: code,
        message: "The scheduler operation was rejected safely."
      )
    )
  }
}

enum SchedulerControlOperationError: Error {
  case invalidBody
  case projectScope
  case staleDecision
  case staleAuthority
  case authorityUnavailable
  case pressureUnavailable
  case preemptionExecutionUnavailable
  case runtimeMutationFailed

  var code: String {
    switch self {
    case .authorityUnavailable: "schedulerAuthorityUnavailable"
    case .pressureUnavailable: "schedulerPressureUnavailable"
    case .preemptionExecutionUnavailable: "schedulerPreemptionAuthorityUnavailable"
    case .runtimeMutationFailed: "schedulerRuntimeMutationFailed"
    case .staleDecision: "schedulerDecisionStale"
    case .staleAuthority: "schedulerAuthorityStale"
    case .invalidBody, .projectScope: "schedulerInvalidRequest"
    }
  }

  var reason: ControlReasonCode {
    switch self {
    case .authorityUnavailable, .pressureUnavailable, .staleAuthority,
         .preemptionExecutionUnavailable, .runtimeMutationFailed: .internalError
    case .invalidBody, .projectScope, .staleDecision: .invalidRequest
    }
  }
}

private enum SchedulerControlScopeError: Error {
  case crossProjectEntity
}
