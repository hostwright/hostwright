import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightDaemon
@testable import HostwrightScheduler
@testable import HostwrightState

final class SchedulerProjectPreemptionControlTests: XCTestCase {
  private let projectID = "project-a"
  private let otherProjectID = "project-b"
  private let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
  private let pendingWorkloadID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
  private let victimWorkloadID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
  private let budgetID = "budget-a"
  private let projectUUID = "00000000-0000-0000-0000-0000000000a1"
  private let fixedNow = "2026-08-05T12:00:00Z"
  private let digest = String(repeating: "a", count: 64)

  func testProjectScopedRealPreemptionPlanAndSimulateAllow() throws {
    // UUID-scoped input makes the pure simulation and durable plan use the
    // same canonical engine snapshot. Human-facing project IDs are exercised
    // by the scope rejection tests below.
    let input = try preemptionInput(
      workloadProjectID: projectUUID,
      victimProjectID: projectUUID,
      budgetProjectID: projectUUID)
    let fixedNow = self.fixedNow
    let simulation = try XCTUnwrap(
      SchedulerControlOperations.handle(
        request: try schedulerRequest(
          operation: .simulate,
          input: input,
          projectID: projectUUID)))
    let simulationDecision = try decodeDecision(from: simulation)

    let planDecision = try withRepository { repository in
      let response = try XCTUnwrap(
        SchedulerControlOperations.handle(
          request: try schedulerRequest(
            operation: .plan,
            input: input,
            projectID: projectUUID),
          repository: repository,
          now: { fixedNow },
          authorityProvider: authorityProvider()))
      XCTAssertEqual(response.status, .completed)
      XCTAssertEqual(response.reasonCode, .completed)
      return try decodeDecision(from: response)
    }

    XCTAssertEqual(planDecision, simulationDecision)
    let workloadDecision = try XCTUnwrap(planDecision.workloadDecisions.first)
    XCTAssertEqual(workloadDecision.workloadID, pendingWorkloadID)
    XCTAssertEqual(workloadDecision.outcome, .preemptionProposed)
    XCTAssertNil(workloadDecision.chosenNodeID)
    let proposal = try XCTUnwrap(workloadDecision.preemption)
    XCTAssertEqual(proposal.targetWorkloadID, pendingWorkloadID)
    XCTAssertEqual(proposal.nodeID, nodeID)
    XCTAssertEqual(proposal.victimWorkloadIDs, [victimWorkloadID])
    XCTAssertEqual(proposal.victims.map(\.projectID), [projectUUID])
    XCTAssertEqual(proposal.victims.compactMap(\.budgetID), [budgetID])
    XCTAssertTrue(proposal.requiresFence)
  }

  func testCrossProjectVictimAndBudgetAreRejectedForPlanAndSimulate() throws {
    let crossProjectVictim = try preemptionInput(
      victimProjectID: otherProjectID,
      budgetProjectID: otherProjectID)
    let crossProjectBudget = try preemptionInput(
      victimBudgetID: nil,
      budgetProjectID: otherProjectID)
    let fixedNow = self.fixedNow

    let victimSimulation = try XCTUnwrap(
      SchedulerControlOperations.handle(
        request: try schedulerRequest(operation: .simulate, input: crossProjectVictim)))
    assertRedactedInvalidRequest(victimSimulation)
    let budgetSimulation = try XCTUnwrap(
      SchedulerControlOperations.handle(
        request: try schedulerRequest(operation: .simulate, input: crossProjectBudget)))
    assertRedactedInvalidRequest(budgetSimulation)

    try withRepository { repository in
      let victimPlan = try XCTUnwrap(
        SchedulerControlOperations.handle(
          request: try schedulerRequest(operation: .plan, input: crossProjectVictim),
          repository: repository,
          now: { fixedNow },
          authorityProvider: authorityProvider()))
      assertRedactedInvalidRequest(victimPlan)
      let budgetPlan = try XCTUnwrap(
        SchedulerControlOperations.handle(
          request: try schedulerRequest(operation: .plan, input: crossProjectBudget),
          repository: repository,
          now: { fixedNow },
          authorityProvider: authorityProvider()))
      assertRedactedInvalidRequest(budgetPlan)
    }
  }

  func testStrictReplayOfProjectPreemptionDecisionIsDeterministic() throws {
    let input = try preemptionInput(
      workloadProjectID: projectUUID,
      victimProjectID: projectUUID,
      budgetProjectID: projectUUID)
    let fixedNow = self.fixedNow
    let request = try schedulerRequest(
      operation: .plan,
      input: input,
      requestID: "scheduler-preemption-replay")

    try withRepository { repository in
      let first = try XCTUnwrap(
        SchedulerControlOperations.handle(
          request: request,
          repository: repository,
          now: { fixedNow },
          authorityProvider: authorityProvider()))
      let replay = try XCTUnwrap(
        SchedulerControlOperations.handle(
          request: request,
          repository: repository,
          now: { "2026-08-05T12:03:00Z" },
          authorityProvider: authorityProvider()))

      XCTAssertEqual(first, replay)
      XCTAssertEqual(
        try ControlPlaneCanonicalJSON.encode(first),
        try ControlPlaneCanonicalJSON.encode(replay))
      XCTAssertEqual(try decodeDecision(from: first), try decodeDecision(from: replay))
    }
  }

  func testSchedulerControlErrorsAreRedacted() throws {
    let sensitiveProject = "project-secret-tenant"
    let malformedInput: ControlPlaneJSONValue = .object([
      "pendingWorkloads": .array([
        .object(["projectID": .string(sensitiveProject)])
      ]),
      "nodes": .array([]),
      "unexpected": .string("victim-budget-secret")
    ])
    let request = ControlRequestEnvelope(
      protocolRevision: .current,
      requestID: "scheduler-redaction",
      operation: SchedulerControlOperation.simulate.rawValue,
      timeoutMilliseconds: 1_000,
      body: .object([
        "projectID": .string(projectID),
        "input": malformedInput
      ])
    )

    let response = try XCTUnwrap(SchedulerControlOperations.handle(request: request))
    assertRedactedInvalidRequest(response)
    XCTAssertFalse(response.error?.message.contains(sensitiveProject) == true)
    XCTAssertFalse(response.error?.message.contains("victim-budget-secret") == true)
  }

  private func preemptionInput(
    workloadProjectID: String = "project-a",
    victimProjectID: String = "project-a",
    victimBudgetID: String? = "budget-a",
    budgetProjectID: String = "project-a"
  ) throws -> SchedulerEngineInput {
    let node = try SchedulerNode(
      snapshot: try NodePlacementSnapshot(
        nodeID: nodeID,
        capacity: try ResourceVector(["cpu": 4]),
        allocation: try ResourceVector(["cpu": 4]),
        architecture: "arm64",
        runtime: "linux-vm",
        provider: "provider"
      )
    )
    let pending = try SchedulerWorkload(
      requirements: try WorkloadPlacementRequirements(
        workloadID: pendingWorkloadID,
        request: try ResourceVector(["cpu": 2])
      ),
      priority: 10,
      subjectID: "incoming-subject",
      projectID: workloadProjectID,
      preemptionEligibility: .eligible
    )
    let victim = try SchedulerVictimAllocation(
      workloadID: victimWorkloadID,
      nodeID: nodeID,
      allocation: try ResourceVector(["cpu": 2]),
      subjectID: "victim-subject",
      projectID: victimProjectID,
      priority: 1,
      disruptionCostBasisPoints: 100,
      budgetID: victimBudgetID
    )
    let budget = try SchedulerDisruptionBudget(
      budgetID: budgetID,
      projectID: budgetProjectID,
      remainingVictimCount: 1,
      remainingDisruptionCostBasisPoints: 100
    )

    return try SchedulerEngineInput(
      pendingWorkloads: [pending],
      nodes: [node],
      victimAllocations: [victim],
      disruptionBudgets: [budget],
      preemptionPolicy: try SchedulerPreemptionPolicy(
        preemptionAuthorized: true,
        authorizationReference: "control-project-plan")
    )
  }

  private func schedulerRequest(
    operation: SchedulerControlOperation,
    input: SchedulerEngineInput,
    requestID: String = "scheduler-preemption-control",
    projectID: String? = nil
  ) throws -> ControlRequestEnvelope {
    ControlRequestEnvelope(
      protocolRevision: .current,
      requestID: requestID,
      operation: operation.rawValue,
      timeoutMilliseconds: 1_000,
      body: .object([
        "projectID": .string(projectID ?? self.projectID),
        "input": try encodedValue(input)
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

  private func assertRedactedInvalidRequest(
    _ response: ControlResponseEnvelope,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(response.status, .rejected, file: file, line: line)
    XCTAssertEqual(response.reasonCode, .invalidRequest, file: file, line: line)
    XCTAssertEqual(
      response.error,
      SanitizedError(
        code: "schedulerInvalidRequest",
        message: "The scheduler operation was rejected safely."
      ),
      file: file,
      line: line
    )
    XCTAssertNil(response.result, file: file, line: line)
  }

  private func authorityProvider() -> SchedulerControlOperations.AuthorityProvider {
    let nodeID = self.nodeID
    let workloadID = self.pendingWorkloadID
    let projectUUID = self.projectUUID
    let digest = self.digest
    return { _, _, _ in
      let binding = try SchedulerDecisionWorkloadBinding(
        workloadID: workloadID,
        nodeID: nodeID,
        resources: try ResourceVector(["cpu": 2]),
        capacityDigest: SchedulerNodeCapacitySnapshot.digest(
          for: try ResourceVector(["cpu": 4])),
        capacityGeneration: 1,
        ownerSubjectID: "incoming-subject",
        projectUUID: projectUUID)
      return SchedulerControlAuthoritySnapshot(
        projectUUID: projectUUID,
        configDigest: digest,
        profileDigest: digest,
        lifecyclePlanDigest: digest,
        workloadBindings: [binding],
        currentAuthorities: [:])
    }
  }

  private func withRepository<T>(
    _ body: (SchedulerAdmissionRepository) throws -> T
  ) throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-scheduler-control-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }

    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.withValidatedConnection { connection in
      try connection.run(
        """
        INSERT INTO projects (
          id, name, manifest_path, manifest_hash, created_at, updated_at,
          resource_uuid, manifest_version, mutation_provider, provider_generation
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(projectID), .text(projectID), .null,
          .text(digest), .text(fixedNow), .text(fixedNow),
          .text(projectUUID), .int(1), .null, .int(0),
        ])
    }
    return try body(SchedulerAdmissionRepository(store: store))
  }
}
