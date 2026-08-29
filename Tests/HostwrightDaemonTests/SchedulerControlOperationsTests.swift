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
