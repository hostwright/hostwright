import Foundation
import XCTest

import HostwrightDaemon
import HostwrightHealth
import HostwrightScheduler

final class SchedulerPressureCoordinationTests: XCTestCase {
  func testAllowedAndDeweightedHealthDecisionsMapToReadOnlySchedulerPosture() throws {
    let allowedDecision = HostPressurePolicy().evaluate(
      sample: HostPressureSample(observedAt: date(0))
    )
    let deweightedDecision = HostPressurePolicy().evaluate(
      sample: HostPressureSample(
        thermalState: .serious,
        isLowPowerModeEnabled: true,
        battery: HostBatterySnapshot(
          chargePercent: 50,
          powerSource: .battery,
          isCharging: false
        ),
        powerSourceAvailability: .available,
        observedAt: date(1)
      )
    )

    let allowed = SchedulerPressureCoordination.status(
      for: try SchedulerPressureCoordinationInput(
        pressureDecision: allowedDecision
      )
    )
    let deweighted = SchedulerPressureCoordination.status(
      for: try SchedulerPressureCoordinationInput(
        pressureDecision: deweightedDecision
      )
    )

    XCTAssertEqual(allowed.pressureDecision, allowedDecision)
    XCTAssertEqual(allowed.schedulerHostPosture.pressure, .nominal)
    XCTAssertEqual(allowed.schedulerHostPosture.energy, .balanced)
    XCTAssertTrue(allowed.isAdmissionAllowed)

    XCTAssertEqual(deweighted.pressureDecision, deweightedDecision)
    XCTAssertEqual(deweighted.pressureDecision.posture, .deweighted)
    XCTAssertEqual(deweighted.schedulerHostPosture.pressure, .elevated)
    XCTAssertEqual(deweighted.schedulerHostPosture.energy, .constrained)
    XCTAssertTrue(deweighted.isAdmissionAllowed)
    XCTAssertEqual(
      deweighted.pressureObservedAt,
      date(1)
    )
  }

  func testUnavailableBlockedHealthDecisionFailsClosedForScheduler() throws {
    let decision = HostPressurePolicy().evaluate(
      sample: HostPressureSample(
        systemMemoryPressure: .unknown,
        observedAt: date(2)
      )
    )
    let input = try SchedulerPressureCoordinationInput(
      pressureDecision: decision
    )

    let status = SchedulerPressureCoordination.status(for: input)

    XCTAssertEqual(decision.posture, .blocked)
    XCTAssertEqual(decision.reasonCodes, [.memoryUnavailable])
    XCTAssertEqual(status.schedulerHostPosture.pressure, .unavailable)
    XCTAssertEqual(status.schedulerHostPosture.energy, .unknown)
    XCTAssertFalse(status.isAdmissionAllowed)
    XCTAssertEqual(status.verifiedReclaimedBytes, 0)
  }

  func testReclaimedCapacityUsesOnlyCompletedHostwrightHealthTransitions() throws {
    let completed = try makeReclamationResult(
      vmID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      requestedBytes: 1_000,
      availableBytes: 7_200,
      stabilitySampleCount: 1
    )
    let held = try makeHeldReclamationResult(
      vmID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      requestedBytes: 2_000
    )
    let rejectedUnmanaged = try makeUnmanagedReclamationResult(
      vmID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    )

    let input = try SchedulerPressureCoordinationInput(
      pressureDecision: allowedDecision(at: 10),
      reclamationResults: [completed, rejectedUnmanaged, held],
      reclamationLedger: try SchedulerReclamationObservationLedger(
        generation: 1,
        baselineAvailableBytes: 6_000,
        observedAvailableBytes: 7_200,
        observedAt: date(10)
      )
    )
    let status = SchedulerPressureCoordination.status(for: input)

    XCTAssertEqual(
      status.reclamationResults.map { $0.intent.vmID.uuidString.lowercased() },
      [
        "00000000-0000-0000-0000-000000000001",
        "00000000-0000-0000-0000-000000000002",
        "00000000-0000-0000-0000-000000000003",
      ]
    )
    XCTAssertEqual(status.verifiedReclaimedBytes, 1_000)
    XCTAssertEqual(status.reusableCapacityBytes, 0)
    XCTAssertEqual(
      status.reclamationResults.first?.state,
      .held
    )
    XCTAssertEqual(
      status.reclamationResults.last?.errorCode,
      .unmanagedOwnership
    )
  }

  func testOverlappingVMWindowsFailClosedAgainstOneGlobalMemoryDelta() throws {
    let first = try makeReclamationResult(
      vmID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
      requestedBytes: 1_000,
      availableBytes: 7_000,
      stabilitySampleCount: 1
    )
    let second = try makeReclamationResult(
      vmID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
      requestedBytes: 1_000,
      availableBytes: 7_000,
      stabilitySampleCount: 1
    )

    XCTAssertThrowsError(
      try SchedulerPressureCoordinationInput(
        pressureDecision: allowedDecision(at: 10),
        reclamationResults: [first, second],
        reclamationLedger: try SchedulerReclamationObservationLedger(
          generation: 7,
          baselineAvailableBytes: 6_000,
          observedAvailableBytes: 7_000,
          observedAt: date(10)
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? SchedulerPressureCoordinationInputError,
        .overlappingReclamationWindow
      )
    }

    let replay = try SchedulerPressureCoordinationInput(
      pressureDecision: allowedDecision(at: 10),
      reclamationResults: [first],
      reclamationLedger: try SchedulerReclamationObservationLedger(
        generation: 7,
        baselineAvailableBytes: 6_000,
        observedAvailableBytes: 7_000,
        observedAt: date(10)
      )
    )
    XCTAssertEqual(
      SchedulerPressureCoordination.status(for: replay),
      SchedulerPressureCoordination.status(for: replay)
    )
  }

  func testInputIsBoundedAndRejectsAmbiguousOrInvalidEvidence() throws {
    let decision = allowedDecision(at: 20)
    let result = try makeReclamationResult(
      vmID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
      requestedBytes: 1_000,
      availableBytes: 7_000,
      stabilitySampleCount: 1
    )

    XCTAssertThrowsError(
      try SchedulerPressureCoordinationInput(
        pressureDecision: decision,
        reclamationResults: Array(
          repeating: result,
          count: SchedulerPressureCoordination.maximumReclamationResults + 1
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? SchedulerPressureCoordinationInputError,
        .tooManyReclamationResults
      )
    }

    XCTAssertThrowsError(
      try SchedulerPressureCoordinationInput(
        pressureDecision: decision,
        reclamationResults: [result, result]
      )
    ) { error in
      XCTAssertEqual(
        error as? SchedulerPressureCoordinationInputError,
        .duplicateReclamationVM
      )
    }

    let invalidDecision = HostPressurePolicyDecision(
      posture: .allowed,
      reasonCodes: [.allowed],
      observedAt: Date(timeIntervalSince1970: .infinity),
      nextState: .initial
    )
    XCTAssertThrowsError(
      try SchedulerPressureCoordinationInput(
        pressureDecision: invalidDecision
      )
    ) { error in
      XCTAssertEqual(
        error as? SchedulerPressureCoordinationInputError,
        .invalidPressureObservation
      )
    }
  }

  private func allowedDecision(at offset: TimeInterval) -> HostPressurePolicyDecision {
    HostPressurePolicy().evaluate(
      sample: HostPressureSample(observedAt: date(offset))
    )
  }

  private func makeReclamationResult(
    vmID: UUID,
    requestedBytes: UInt64,
    availableBytes: UInt64,
    stabilitySampleCount: Int
  ) throws -> VMReclamationResult {
    let configuration = try VMReclamationConfiguration(
      stabilitySampleCount: stabilitySampleCount
    )
    let intent = try VMReclamationIntent(
      vmID: vmID,
      lifecyclePlanDigest: String(repeating: "a", count: 64),
      fencingToken: 1,
      requestedBytes: requestedBytes,
      beforeSample: VMReclamationMemorySample(
        availableBytes: 6_000,
        totalBytes: 10_000,
        observedAt: date(0)
      ),
      ownership: .hostwrightOwned,
      plannedAt: date(0),
      expiresAt: date(100),
      configuration: configuration
    )
    let machine = VMReclamationStateMachine(configuration: configuration)
    let stopped = machine.transition(
      intent: intent,
      request: request(
        .stopConfirmed,
        vmID: vmID,
        lifecyclePlanDigest: String(repeating: "a", count: 64),
        fencingToken: 1,
        at: 1
      )
    )
    let removed = machine.transition(
      intent: stopped.intent,
      request: request(
        .removeConfirmed,
        vmID: vmID,
        lifecyclePlanDigest: String(repeating: "a", count: 64),
        fencingToken: 1,
        at: 2
      )
    )
    let verifying = machine.transition(
      intent: removed.intent,
      request: request(
        .beginVerification,
        vmID: vmID,
        lifecyclePlanDigest: String(repeating: "a", count: 64),
        fencingToken: 1,
        at: 3
      )
    )
    return machine.transition(
      intent: verifying.intent,
      request: request(
        .memorySample,
        vmID: vmID,
        lifecyclePlanDigest: String(repeating: "a", count: 64),
        fencingToken: 1,
        at: 4,
        sample: VMReclamationMemorySample(
          availableBytes: availableBytes,
          totalBytes: 10_000,
          observedAt: date(4)
        )
      )
    )
  }

  private func makeHeldReclamationResult(
    vmID: UUID,
    requestedBytes: UInt64
  ) throws -> VMReclamationResult {
    let configuration = try VMReclamationConfiguration(stabilitySampleCount: 1)
    let intent = try VMReclamationIntent(
      vmID: vmID,
      lifecyclePlanDigest: String(repeating: "b", count: 64),
      fencingToken: 2,
      requestedBytes: requestedBytes,
      beforeSample: VMReclamationMemorySample(
        availableBytes: 6_000,
        totalBytes: 10_000,
        observedAt: date(0)
      ),
      ownership: .hostwrightOwned,
      plannedAt: date(0),
      expiresAt: date(100),
      configuration: configuration
    )
    let machine = VMReclamationStateMachine(configuration: configuration)
    let verifying = verificationReadyIntent(
      machine: machine,
      intent: intent,
      vmID: vmID
    )
    return machine.transition(
      intent: verifying,
      request: request(
        .memorySample,
        vmID: vmID,
        lifecyclePlanDigest: String(repeating: "b", count: 64),
        fencingToken: 2,
        at: 4,
        sample: VMReclamationMemorySample(
          availableBytes: 6_500,
          totalBytes: 10_000,
          observedAt: date(4)
        )
      )
    )
  }

  private func makeUnmanagedReclamationResult(vmID: UUID) throws -> VMReclamationResult {
    let configuration = VMReclamationConfiguration.standard
    let intent = try VMReclamationIntent(
      vmID: vmID,
      lifecyclePlanDigest: String(repeating: "c", count: 64),
      fencingToken: 3,
      requestedBytes: 1_000,
      beforeSample: VMReclamationMemorySample(
        availableBytes: 6_000,
        totalBytes: 10_000,
        observedAt: date(0)
      ),
      ownership: .unmanaged,
      plannedAt: date(0),
      expiresAt: date(100),
      configuration: configuration
    )
    return VMReclamationStateMachine(configuration: configuration).transition(
      intent: intent,
      request: request(
        .stopConfirmed,
        vmID: vmID,
        lifecyclePlanDigest: String(repeating: "c", count: 64),
        fencingToken: 3,
        at: 1
      )
    )
  }

  private func verificationReadyIntent(
    machine: VMReclamationStateMachine,
    intent: VMReclamationIntent,
    vmID: UUID
  ) -> VMReclamationIntent {
    let stopped = machine.transition(
      intent: intent,
      request: request(
        .stopConfirmed,
        vmID: vmID,
        lifecyclePlanDigest: String(repeating: "b", count: 64),
        fencingToken: 2,
        at: 1
      )
    )
    let removed = machine.transition(
      intent: stopped.intent,
      request: request(
        .removeConfirmed,
        vmID: vmID,
        lifecyclePlanDigest: String(repeating: "b", count: 64),
        fencingToken: 2,
        at: 2
      )
    )
    return machine.transition(
      intent: removed.intent,
      request: request(
        .beginVerification,
        vmID: vmID,
        lifecyclePlanDigest: String(repeating: "b", count: 64),
        fencingToken: 2,
        at: 3
      )
    ).intent
  }

  private func request(
    _ transition: VMReclamationTransition,
    vmID: UUID,
    lifecyclePlanDigest: String,
    fencingToken: UInt64,
    at offset: TimeInterval,
    sample: VMReclamationMemorySample? = nil
  ) -> VMReclamationTransitionRequest {
    VMReclamationTransitionRequest(
      transition: transition,
      context: VMReclamationTransitionContext(
        vmID: vmID,
        lifecyclePlanDigest: lifecyclePlanDigest,
        fencingToken: fencingToken
      ),
      observedAt: date(offset),
      memorySample: sample
    )
  }

  private func date(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: offset)
  }
}
