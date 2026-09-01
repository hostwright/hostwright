import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightDaemon
@testable import HostwrightScheduler
@testable import HostwrightState

final class SchedulerControlOperationsTests: XCTestCase {
  func testPlanAndSimulationArePureAndReplayable() throws {
    let input = try SchedulerEngineInput(pendingWorkloads: [], nodes: [])
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("hostwright-scheduler-read-(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: storeRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = SQLiteStateStore(path: storeRoot.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    XCTAssertNil(try store.schedulerAdmissions.nodeCapacity(nodeID: nodeID))

    let plan = try XCTUnwrap(
      SchedulerControlOperations.handle(
        request: try schedulerRequest(operation: "scheduler.plan", input: input)))
    let simulation = try XCTUnwrap(
      SchedulerControlOperations.handle(
        request: try schedulerRequest(operation: "scheduler.simulate", input: input)))

    XCTAssertEqual(plan.status, .rejected)
    XCTAssertEqual(plan.reasonCode, .internalError)
    XCTAssertEqual(plan.error?.code, "schedulerAuthorityUnavailable")
    XCTAssertEqual(plan.protocolRevision, .current)
    XCTAssertEqual(simulation.status, .completed)
    XCTAssertEqual(simulation.protocolRevision, .current)
    let simulationDecision = try decodeDecision(from: simulation)
    XCTAssertEqual(simulationDecision.inputDigest, input.inputDigest)
    XCTAssertFalse(SchedulerControlOperations.isReadOnly(operation: "scheduler.plan"))
    XCTAssertTrue(SchedulerControlOperations.isReadOnly(operation: "scheduler.simulate"))
    XCTAssertFalse(SchedulerControlOperations.mutatingOperations.isEmpty)
    XCTAssertTrue(SchedulerControlOperations.mutatingOperations.contains("scheduler.plan"))
    XCTAssertTrue(SchedulerControlOperations.mutatingOperations.contains("scheduler.apply"))
    XCTAssertTrue(SchedulerControlOperations.mutatingOperations.contains("scheduler.release"))

    // The read path has no state repository or runtime dependency. The
    // sentinel state remains empty before and after both pure operations.
    XCTAssertNil(try store.schedulerAdmissions.nodeCapacity(nodeID: nodeID))
    XCTAssertEqual(try store.schedulerAdmissions.reservations(nodeID: nodeID), [])
  }

  func testProjectScopeRejectsCrossProjectEntitiesAndBudgets() throws {
    let node = try makeNode()
    let crossProjectWorkload = try SchedulerWorkload(
      requirements: try WorkloadPlacementRequirements(
        workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        request: try ResourceVector(["cpu": 1])
      ),
      priority: 1,
      subjectID: "subject",
      projectID: "project-b"
    )
    let crossProjectInput = try SchedulerEngineInput(
      pendingWorkloads: [crossProjectWorkload], nodes: [node])
    let crossProjectResponse = try XCTUnwrap(
      SchedulerControlOperations.handle(
        request: try schedulerRequest(operation: "scheduler.simulate", input: crossProjectInput)))
    assertSafeScopeRejection(crossProjectResponse)

    let crossProjectFairness = try SchedulerFairnessState(
      subjectID: "subject", projectID: "project-b")
    let fairnessInput = try SchedulerEngineInput(
      pendingWorkloads: [], nodes: [node], fairnessStates: [crossProjectFairness])
    let fairnessResponse = try XCTUnwrap(
      SchedulerControlOperations.handle(
        request: try schedulerRequest(operation: "scheduler.simulate", input: fairnessInput)))
    assertSafeScopeRejection(fairnessResponse)

    let budget = try SchedulerDisruptionBudget(
      budgetID: "budget-a", projectID: "project-b", remainingVictimCount: 1,
      remainingDisruptionCostBasisPoints: 100)
    let budgetInput = try SchedulerEngineInput(
      pendingWorkloads: [], nodes: [node], disruptionBudgets: [budget])
    let budgetResponse = try XCTUnwrap(
      SchedulerControlOperations.handle(
        request: try schedulerRequest(operation: "scheduler.simulate", input: budgetInput)))
    assertSafeScopeRejection(budgetResponse)

    let inputValue = try encodedValue(crossProjectInput)
    let missingProject = ControlRequestEnvelope(
      protocolRevision: .current,
      requestID: "scheduler-missing-project",
      operation: "scheduler.simulate",
      timeoutMilliseconds: 1_000,
      body: .object(["input": inputValue])
    )
    let missingProjectResponse = try XCTUnwrap(
      SchedulerControlOperations.handle(request: missingProject))
    assertSafeScopeRejection(missingProjectResponse)
  }

  func testReleasePersistsIntentRequiresAbsenceEvidenceAndReplays() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-scheduler-release-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let projectUUID = "00000000-0000-0000-0000-0000000000a1"
    let createdAt = "2026-08-31T12:00:00Z"
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "subject",
        userID: 501,
        codeIdentity: CodeIdentity(
          teamIdentifier: "993YC3JY4Q",
          signingIdentifier: "hostwright-scheduler-release-tests",
          codeDirectoryHash: String(repeating: "a", count: 40),
          validationMode: .installedRequirement
        ),
        declaredBySubjectID: "subject",
        declaredAt: createdAt,
        updatedAt: createdAt
      )
    )
    try store.withValidatedConnection { connection in
      try connection.run(
        """
        INSERT INTO projects (
          id, name, manifest_path, manifest_hash, created_at, updated_at,
          resource_uuid, manifest_version, mutation_provider, provider_generation
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text("project-a"), .text("project-a"), .null,
          .text(String(repeating: "a", count: 64)), .text(createdAt),
          .text(createdAt), .text(projectUUID), .int(1), .null, .int(0),
        ]
      )
    }
    let repository = store.schedulerAdmissions
    let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let workloadID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    let decisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    let inputDigest = String(repeating: "1", count: 64)
    let capacity = try SchedulerNodeCapacitySnapshot(
      nodeID: nodeID,
      capacity: try ResourceVector(["cpu": 2]),
      generation: 1,
      observedAt: createdAt
    )
    _ = try repository.recordNodeCapacity(snapshot: capacity)
    let decision = try SchedulerDecision(
      decisionID: decisionID,
      inputDigest: inputDigest,
      orderedWorkloadIDs: [workloadID],
      workloadDecisions: [
        try SchedulerWorkloadDecision(
          workloadID: workloadID,
          outcome: .placed,
          chosenNodeID: nodeID,
          scoreComponents: .zero,
          feasibleAlternatives: [],
          filterFailures: [],
          preemption: nil,
          explanation: try SchedulerDecisionExplanation(
            code: .placed,
            summary: "release qualification placement"
          )
        ),
      ]
    )
    let artifactBinding = try SchedulerDecisionWorkloadBinding(
      workloadID: workloadID,
      nodeID: nodeID,
      resources: try ResourceVector(["cpu": 1]),
      capacityDigest: capacity.capacityDigest,
      capacityGeneration: capacity.generation,
      ownerSubjectID: "subject",
      projectUUID: projectUUID
    )
    _ = try repository.recordDecisionArtifact(
      decision: decision,
      workloadBindings: [artifactBinding],
      projectUUID: projectUUID,
      configDigest: String(repeating: "2", count: 64),
      profileDigest: String(repeating: "3", count: 64),
      lifecyclePlanDigest: String(repeating: "4", count: 64),
      createdAt: createdAt,
      updatedAt: createdAt
    )
    let reservation = try repository.reserve(
      binding: try SchedulerAdmissionBinding(
        decisionID: decisionID,
        workloadID: workloadID,
        nodeID: nodeID,
        resources: artifactBinding.resources,
        nodeCapacityDigest: capacity.capacityDigest,
        nodeCapacityGeneration: capacity.generation,
        inputDigest: inputDigest,
        configDigest: String(repeating: "2", count: 64),
        profileDigest: String(repeating: "3", count: 64),
        lifecyclePlanDigest: String(repeating: "4", count: 64),
        ownerSubjectID: "subject",
        projectUUID: projectUUID,
        createdAt: createdAt,
        expiresAt: "2026-08-31T12:05:00Z"
      ),
      authority: try SchedulerAdmissionAuthority(
        nodeCapacityDigest: capacity.capacityDigest,
        nodeCapacityGeneration: capacity.generation,
        inputDigest: inputDigest,
        configDigest: String(repeating: "2", count: 64),
        profileDigest: String(repeating: "3", count: 64),
        lifecyclePlanDigest: String(repeating: "4", count: 64),
        expectedNodeEpoch: 1
      )
    )
    _ = try repository.commit(
      reservationID: reservation.reservationID,
      expectedToken: reservation.fencingToken,
      updatedAt: "2026-08-31T12:01:00Z"
    )
    let request = ControlRequestEnvelope(
      protocolRevision: .current,
      requestID: "scheduler-release-request",
      operation: SchedulerControlOperation.release.rawValue,
      timeoutMilliseconds: 1_000,
      body: .object([
        "projectID": .string("project-a"),
        "decisionID": .string(decisionID.uuidString.lowercased()),
        "workloadID": .string(workloadID.uuidString.lowercased()),
        "expectedInputDigest": .string(inputDigest),
      ])
    )
    let failed = try XCTUnwrap(SchedulerControlOperations.handle(
      request: request,
      repository: repository,
      subjectID: "subject",
      now: { "2026-08-31T12:02:00Z" },
      runtimeRelease: { _ in
        throw SchedulerControlOperationError.runtimeMutationFailed
      }
    ))
    XCTAssertEqual(failed.status, .rejected)
    XCTAssertEqual(failed.reasonCode, .internalError)
    XCTAssertEqual(failed.error?.code, "schedulerRuntimeMutationFailed")
    XCTAssertEqual(
      try repository.reservation(id: reservation.reservationID)?.status,
      .releasePending
    )
    XCTAssertEqual(try repository.availableCapacity(nodeID: nodeID).values, ["cpu": 1])

    let completed = try XCTUnwrap(SchedulerControlOperations.handle(
      request: request,
      repository: repository,
      subjectID: "subject",
      now: { "2026-08-31T12:03:00Z" },
      runtimeRelease: { releasing in
        guard releasing.status == .releasePending else {
          throw SchedulerAdmissionError.invalidBinding(field: "release-status")
        }
        return SchedulerControlOperations.ReleaseExecutionResult(
          mutation: .object(["status": .string("absent")]),
          evidenceDigest: String(repeating: "5", count: 64),
          verifiedAt: "2026-08-31T12:04:00Z"
        )
      }
    ))
    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(
      try repository.reservation(id: reservation.reservationID)?.status,
      .released
    )
    XCTAssertEqual(try repository.availableCapacity(nodeID: nodeID).values, ["cpu": 2])

    let replay = try XCTUnwrap(SchedulerControlOperations.handle(
      request: request,
      repository: repository,
      subjectID: "subject",
      now: { "2026-08-31T12:05:00Z" },
      runtimeRelease: { _ in
        throw SchedulerControlOperationError.runtimeMutationFailed
      }
    ))
    XCTAssertEqual(replay.status, .completed)
    XCTAssertEqual(
      try repository.reservation(id: reservation.reservationID)?.status,
      .released
    )
  }

  private func schedulerRequest(
    operation: String,
    input: SchedulerEngineInput,
    projectID: String = "project-a"
  ) throws -> ControlRequestEnvelope {
    ControlRequestEnvelope(
      protocolRevision: .current,
      requestID: "(operation)-request",
      operation: operation,
      timeoutMilliseconds: 1_000,
      body: .object([
        "projectID": .string(projectID),
        "input": try encodedValue(input),
      ])
    )
  }

  private func encodedValue<T: Encodable>(_ value: T) throws -> ControlPlaneJSONValue {
    try JSONDecoder().decode(
      ControlPlaneJSONValue.self,
      from: try ControlPlaneCanonicalJSON.encode(value)
    )
  }

  private func decodeDecision(from response: ControlResponseEnvelope) throws -> SchedulerDecision {
    try JSONDecoder().decode(
      SchedulerDecision.self,
      from: try ControlPlaneCanonicalJSON.encode(try XCTUnwrap(response.result))
    )
  }

  private func assertSafeScopeRejection(
    _ response: ControlResponseEnvelope,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(response.status, .rejected, file: file, line: line)
    XCTAssertEqual(response.reasonCode, .invalidRequest, file: file, line: line)
    XCTAssertEqual(response.error?.code, "schedulerInvalidRequest", file: file, line: line)
    XCTAssertFalse(response.error?.message.contains("project-b") == true, file: file, line: line)
  }

  private func makeNode() throws -> SchedulerNode {
    try SchedulerNode(
      snapshot: try NodePlacementSnapshot(
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
        capacity: try ResourceVector(["cpu": 2]),
        allocation: .zero,
        architecture: "arm64",
        runtime: "linux-vm",
        provider: "provider"
      )
    )
  }
}
