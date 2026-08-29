import Foundation
import XCTest

@testable import HostwrightDaemon
@testable import HostwrightHealth
@testable import HostwrightScheduler
@testable import HostwrightState
@testable import HostwrightControlPlane

final class SchedulerPressureAuthorityCoordinatorTests: XCTestCase {
  private let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!

  func testStartupAndReopenRecoverVersionedHysteresis() throws {
    try withStore { store in
      let t0 = date(0)
      let first = try coordinator(
        store: store,
        sample: HostPressureSample(observedAt: t0),
        now: t0
      ).refresh(nodeIDs: [nodeID])
      XCTAssertEqual(first[nodeID]?.pressure, .nominal)
      XCTAssertEqual(try store.schedulerAdmissions.hostPressure(nodeID: nodeID)?.generation, 1)

      let critical = try coordinator(
        store: store,
        sample: HostPressureSample(systemMemoryPressure: .critical, observedAt: date(1)),
        now: date(1)
      ).refresh(nodeIDs: [nodeID])
      XCTAssertEqual(critical[nodeID]?.pressure, .critical)

      let reopened = SQLiteStateStore(path: store.path)
      let persisted = try XCTUnwrap(
        reopened.schedulerAdmissions.hostPressure(nodeID: nodeID)
      )
      XCTAssertEqual(persisted.generation, 2)
      XCTAssertEqual(persisted.policyState.version, 1)
      XCTAssertEqual(
        persisted.policyState.nextHysteresisState.posture,
        .blocked
      )

      let recovering = try coordinator(
        store: reopened,
        sample: HostPressureSample(thermalState: .serious, observedAt: date(2)),
        now: date(2)
      ).refresh(nodeIDs: [nodeID])
      XCTAssertEqual(recovering[nodeID]?.pressure, .critical)
      XCTAssertEqual(
        try reopened.schedulerAdmissions.hostPressure(nodeID: nodeID)?
          .policyState.reasonCodes,
        [.hysteresisRecovery]
      )

      let recovered = try coordinator(
        store: reopened,
        sample: HostPressureSample(thermalState: .serious, observedAt: date(3)),
        now: date(3)
      ).refresh(nodeIDs: [nodeID])
      XCTAssertEqual(recovered[nodeID]?.pressure, .elevated)
    }
  }

  func testWarningCriticalAndUnavailableAreDurableAdmissionPostures() throws {
    try withStore { store in
      let warning = try coordinator(
        store: store,
        sample: HostPressureSample(
          systemMemoryPressure: .warning,
          observedAt: date(10)
        ),
        now: date(10)
      ).refresh(nodeIDs: [nodeID])
      XCTAssertEqual(warning[nodeID]?.pressure, .elevated)
      XCTAssertEqual(warning[nodeID]?.energy, .balanced)

      let unavailable = try coordinator(
        store: store,
        sample: HostPressureSample(
          availability: .unknown,
          observedAt: date(11)
        ),
        now: date(11)
      ).refresh(nodeIDs: [nodeID])
      XCTAssertEqual(unavailable[nodeID]?.pressure, .unavailable)
      XCTAssertEqual(unavailable[nodeID]?.energy, .unknown)
      XCTAssertEqual(
        try store.schedulerAdmissions.hostPressure(nodeID: nodeID)?.policyState.reasonCodes,
        [.hostUnavailable]
      )
    }
  }

  func testDeweightedRecoveryPersistsIntermediateHysteresisState() throws {
    try withStore { store in
      let warning = try coordinator(
        store: store,
        sample: HostPressureSample(systemMemoryPressure: .warning, observedAt: date(20)),
        now: date(20)
      ).refresh(nodeIDs: [nodeID])
      XCTAssertEqual(warning[nodeID]?.pressure, .elevated)

      let firstClear = try coordinator(
        store: store,
        sample: HostPressureSample(observedAt: date(21)),
        now: date(21)
      ).refresh(nodeIDs: [nodeID])
      XCTAssertEqual(firstClear[nodeID]?.pressure, .elevated)
      let intermediate = try XCTUnwrap(
        store.schedulerAdmissions.hostPressure(nodeID: nodeID)
      )
      XCTAssertEqual(intermediate.policyState.reasonCodes, [.hysteresisRecovery])
      XCTAssertEqual(
        intermediate.policyState.nextHysteresisState.consecutiveClearObservations,
        1
      )

      let secondClear = try coordinator(
        store: store,
        sample: HostPressureSample(observedAt: date(22)),
        now: date(22)
      ).refresh(nodeIDs: [nodeID])
      XCTAssertEqual(secondClear[nodeID]?.pressure, .nominal)

      let reopened = SQLiteStateStore(path: store.path)
      let recovered = try XCTUnwrap(
        reopened.schedulerAdmissions.hostPressure(nodeID: nodeID)
      )
      XCTAssertEqual(recovered.generation, 3)
      XCTAssertEqual(recovered.policyState.reasonCodes, [.allowed])
      XCTAssertEqual(recovered.policyState.nextHysteresisState.posture, .allowed)
    }
  }

  func testStaleGenerationAndMalformedPolicyEnvelopeFailClosed() throws {
    try withStore { store in
      let posture = SchedulerHostPosture(pressure: .nominal, energy: .balanced)
      let record = try SchedulerHostPressureRecord(
        nodeID: nodeID,
        posture: posture,
        generation: 1,
        observedAt: timestamp(0),
        evidenceDigest: digest("a"),
        policyState: try policyState(
          reasonCodes: [.allowed],
          nextPosture: .allowed
        )
      )
      _ = try store.schedulerAdmissions.recordHostPressure(record: record)
      XCTAssertThrowsError(
        try SchedulerHostPressureRecord(
          nodeID: nodeID,
          posture: SchedulerHostPosture(pressure: .nominal, energy: .unknown),
          generation: 2,
          observedAt: timestamp(1),
          evidenceDigest: digest("d"),
          policyState: try policyState(
            reasonCodes: [.allowed],
            nextPosture: .allowed
          )
        )
      )
      let stale = try SchedulerHostPressureRecord(
        nodeID: nodeID,
        posture: posture,
        generation: 1,
        observedAt: timestamp(1),
        evidenceDigest: digest("b"),
        policyState: try policyState(
          reasonCodes: [.allowed],
          nextPosture: .allowed
        )
      )
      XCTAssertThrowsError(
        try store.schedulerAdmissions.recordHostPressure(record: stale)
      ) { error in
        XCTAssertEqual(
          (error as? SchedulerAdmissionError)?.stableKey,
          "stale-input:pressure-generation"
        )
      }

      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: JSONEncoder().encode(record)
        ) as? [String: Any]
      )
      var policy = try XCTUnwrap(object["policyState"] as? [String: Any])
      policy["futureKey"] = true
      object["policyState"] = policy
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          SchedulerHostPressureRecord.self,
          from: JSONSerialization.data(withJSONObject: object)
        )
      )

      object["policyState"] = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: JSONEncoder().encode(record.policyState)
        ) as? [String: Any]
      )
      object["recordDigest"] = digest("c")
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          SchedulerHostPressureRecord.self,
          from: JSONSerialization.data(withJSONObject: object)
        )
      )
      XCTAssertThrowsError(
        try SchedulerHostPressurePolicyState(
          version: 2,
          reasonCodes: [.allowed],
          nextHysteresisState: try SchedulerHostPressureHysteresisState(
            posture: .allowed,
            consecutiveClearObservations: 0,
            version: 2
          )
        )
      )
    }
  }

  func testSimulationDoesNotInvokePressurePersistence() throws {
    try withStore { store in
      let input = try SchedulerEngineInput(pendingWorkloads: [], nodes: [])
      let request = ControlRequestEnvelope(
        protocolRevision: .current,
        requestID: "pressure-simulation-purity",
        operation: SchedulerControlOperation.simulate.rawValue,
        timeoutMilliseconds: 1_000,
        body: .object([
          "projectID": .string("project-a"),
          "input": try JSONDecoder().decode(
            ControlPlaneJSONValue.self,
            from: ControlPlaneCanonicalJSON.encode(input)
          ),
        ])
      )
      let nowString = timestamp(0)
      let response = try XCTUnwrap(
        SchedulerControlOperations.handle(
          request: request,
          repository: store.schedulerAdmissions,
          now: { nowString },
          projectResolver: { _ in "00000000-0000-0000-0000-000000000702" },
          pressureRefresher: { _ in
            throw SchedulerPressureAuthorityError.persistenceFailed
          }
        )
      )
      XCTAssertEqual(response.status, .completed)
      XCTAssertEqual(try store.schedulerAdmissions.hostPressures(), [])
    }
  }

  func testUnknownClientNodeCannotCreatePressureRows() throws {
    try withStore { store in
      let unknownNode = UUID(uuidString: "00000000-0000-0000-0000-000000000799")!
      XCTAssertThrowsError(
        try coordinator(
          store: store,
          sample: HostPressureSample(observedAt: date(30)),
          now: date(30)
        ).refresh(nodeIDs: [unknownNode])
      ) { error in
        XCTAssertEqual(error as? SchedulerPressureAuthorityError, .unknownNode)
      }
      XCTAssertEqual(try store.schedulerAdmissions.hostPressures(), [])
    }
  }

  func testPlanPressureFailureIsAnAuthorityFailureNotCallerInput() throws {
    try withStore { store in
      let input = try SchedulerEngineInput(pendingWorkloads: [], nodes: [])
      let request = ControlRequestEnvelope(
        protocolRevision: .current,
        requestID: "pressure-plan-failure",
        operation: SchedulerControlOperation.plan.rawValue,
        timeoutMilliseconds: 1_000,
        body: .object([
          "projectID": .string("project-a"),
          "input": try JSONDecoder().decode(
            ControlPlaneJSONValue.self,
            from: ControlPlaneCanonicalJSON.encode(input)
          ),
        ])
      )
      let nowString = timestamp(0)
      let response = try XCTUnwrap(
        SchedulerControlOperations.handle(
          request: request,
          repository: store.schedulerAdmissions,
          now: { nowString },
          projectResolver: { _ in "00000000-0000-0000-0000-000000000702" },
          pressureRefresher: { _ in
            throw SchedulerPressureAuthorityError.persistenceFailed
          }
        )
      )
      XCTAssertEqual(response.status, .rejected)
      XCTAssertEqual(response.reasonCode, .internalError)
      XCTAssertEqual(response.error?.code, "schedulerPressureUnavailable")
    }
  }

  private func coordinator(
    store: SQLiteStateStore,
    sample: HostPressureSample,
    now: Date
  ) -> SchedulerPressureAuthorityCoordinator {
    SchedulerPressureAuthorityCoordinator(
      probe: FixedPressureProbe(sample: sample),
      repository: store.schedulerAdmissions,
      clock: { now }
    )
  }

  private func withStore(
    _ body: (SQLiteStateStore) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-pressure-authority-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteStateStore(
      path: directory.appendingPathComponent("state.sqlite").path
    )
    try store.migrate()
    _ = try store.schedulerAdmissions.recordNodeCapacity(
      snapshot: try SchedulerNodeCapacitySnapshot(
        nodeID: nodeID,
        capacity: try ResourceVector(["cpu": 1]),
        generation: 1,
        observedAt: timestamp(0)
      )
    )
    try body(store)
  }

  private func date(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_785_715_200 + offset)
  }

  private func timestamp(_ offset: TimeInterval) -> String {
    ISO8601DateFormatter().string(from: date(offset))
  }

  private func digest(_ seed: String) -> String {
    String(repeating: seed, count: 64).prefix(64).description
  }

  private func policyState(
    reasonCodes: [SchedulerHostPressureReasonCode],
    nextPosture: SchedulerHostPressurePolicyPosture,
    clearObservations: Int = 0
  ) throws -> SchedulerHostPressurePolicyState {
    try SchedulerHostPressurePolicyState(
      version: SchedulerHostPressurePolicyState.currentVersion,
      reasonCodes: reasonCodes,
      nextHysteresisState: try SchedulerHostPressureHysteresisState(
        posture: nextPosture,
        consecutiveClearObservations: clearObservations,
        version: SchedulerHostPressurePolicyState.currentVersion
      )
    )
  }
}

private struct FixedPressureProbe: HostPressureProbe {
  let sample: HostPressureSample

  func sample(at _: Date) -> HostPressureSample {
    sample
  }
}
