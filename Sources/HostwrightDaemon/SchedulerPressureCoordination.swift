import CryptoKit
import Dispatch
import Foundation
import HostwrightHealth
import HostwrightScheduler
import HostwrightState
import os

public enum SchedulerPressureCoordinationInputError: String, Error, Codable, Equatable, Sendable {
  case invalidPressureObservation = "invalid-pressure-observation"
  case invalidReclamationObservation = "invalid-reclamation-observation"
  case missingReclamationAuthority = "missing-reclamation-authority"
  case invalidReclamationAuthority = "invalid-reclamation-authority"
  case overlappingReclamationWindow = "overlapping-reclamation-window"
  case staleReclamationWindow = "stale-reclamation-window"
  case tooManyReclamationResults = "too-many-reclamation-results"
  case duplicateReclamationVM = "duplicate-reclamation-vm"
  case reclaimedBytesOverflow = "reclaimed-bytes-overflow"
}

/// A daemon-authoritative host-memory observation window. VM results are
/// evidence only; this ledger is the sole authority that bounds any aggregate
/// credit and prevents overlapping VM windows from being counted twice.
public struct SchedulerReclamationObservationLedger: Codable, Equatable, Sendable {
  public let generation: Int64
  public let baselineAvailableBytes: UInt64
  public let observedAvailableBytes: UInt64
  public let observedAt: Date

  public init(
    generation: Int64,
    baselineAvailableBytes: UInt64,
    observedAvailableBytes: UInt64,
    observedAt: Date
  ) throws {
    guard generation >= 1,
          observedAvailableBytes >= baselineAvailableBytes,
          observedAt.timeIntervalSince1970.isFinite else {
      throw SchedulerPressureCoordinationInputError.invalidReclamationAuthority
    }
    self.generation = generation
    self.baselineAvailableBytes = baselineAvailableBytes
    self.observedAvailableBytes = observedAvailableBytes
    self.observedAt = observedAt
  }
}

public struct SchedulerPressureCoordinationInput: Codable, Equatable, Sendable {
  public static let maximumReclamationResults = 1_024

  public let pressureDecision: HostPressurePolicyDecision
  public let reclamationResults: [VMReclamationResult]
  public let reclamationLedger: SchedulerReclamationObservationLedger?

  private enum CodingKeys: String, CodingKey {
    case pressureDecision
    case reclamationResults
    case reclamationLedger
  }

  public init(
    pressureDecision: HostPressurePolicyDecision,
    reclamationResults: [VMReclamationResult] = [],
    reclamationLedger: SchedulerReclamationObservationLedger? = nil
  ) throws {
    guard pressureDecision.observedAt.timeIntervalSince1970.isFinite else {
      throw SchedulerPressureCoordinationInputError.invalidPressureObservation
    }
    guard reclamationResults.count <= Self.maximumReclamationResults else {
      throw SchedulerPressureCoordinationInputError.tooManyReclamationResults
    }

    var vmIDs = Set<UUID>()
    for result in reclamationResults {
      // Duplicate VM identity is the specific, deterministic fault even when
      // the duplicate also happens to reuse an overlapping observation window.
      guard vmIDs.insert(result.intent.vmID).inserted else {
        throw SchedulerPressureCoordinationInputError.duplicateReclamationVM
      }
    }
    var verifiedReclaimedBytes: UInt64 = 0
    let verifiedResults = reclamationResults.filter {
      SchedulerPressureCoordination.contributesVerifiedReclamation($0)
    }
    // A ledger generation represents one host-wide available-memory delta.
    // Without per-byte allocation metadata, two successful VM windows are
    // ambiguous even when their reported sums happen to fit the delta. Keep
    // the production authority serialized until the durable ledger can split
    // a generation into disjoint byte ranges.
    guard verifiedResults.count <= 1 else {
      throw SchedulerPressureCoordinationInputError.overlappingReclamationWindow
    }
    if let ledger = reclamationLedger {
      guard ledger.observedAt <= pressureDecision.observedAt else {
        throw SchedulerPressureCoordinationInputError.staleReclamationWindow
      }
    }
    for result in reclamationResults {
      guard result.observedAt.timeIntervalSince1970.isFinite else {
        throw SchedulerPressureCoordinationInputError.invalidReclamationObservation
      }
      guard SchedulerPressureCoordination.contributesVerifiedReclamation(result) else {
        continue
      }
      guard let ledger = reclamationLedger else {
        continue
      }
      guard
            result.intent.beforeSample.availableBytes == ledger.baselineAvailableBytes,
            let lastSample = result.intent.lastMemorySample,
            lastSample.availableBytes >= result.intent.beforeSample.availableBytes,
            lastSample.availableBytes <= ledger.observedAvailableBytes,
            lastSample.observedAt <= ledger.observedAt,
            result.measuredReclaimedBytes
              <= lastSample.availableBytes - result.intent.beforeSample.availableBytes else {
        throw SchedulerPressureCoordinationInputError.staleReclamationWindow
      }
      let (nextBytes, overflow) = verifiedReclaimedBytes.addingReportingOverflow(
        result.measuredReclaimedBytes
      )
      guard !overflow else {
        throw SchedulerPressureCoordinationInputError.reclaimedBytesOverflow
      }
      verifiedReclaimedBytes = nextBytes
    }
    if let ledger = reclamationLedger {
      let globalDelta = ledger.observedAvailableBytes - ledger.baselineAvailableBytes
      guard verifiedReclaimedBytes <= globalDelta else {
        throw SchedulerPressureCoordinationInputError.overlappingReclamationWindow
      }
    }
    if !verifiedResults.isEmpty, reclamationLedger == nil {
      throw SchedulerPressureCoordinationInputError.missingReclamationAuthority
    }

    self.pressureDecision = pressureDecision
    self.reclamationResults = reclamationResults.sorted {
      SchedulerOrdering.uuidKey($0.intent.vmID) < SchedulerOrdering.uuidKey($1.intent.vmID)
    }
    self.reclamationLedger = reclamationLedger
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      pressureDecision: container.decode(
        HostPressurePolicyDecision.self,
        forKey: .pressureDecision
      ),
      reclamationResults: container.decodeIfPresent(
        [VMReclamationResult].self,
        forKey: .reclamationResults
      ) ?? [],
      reclamationLedger: container.decodeIfPresent(
        SchedulerReclamationObservationLedger.self,
        forKey: .reclamationLedger
      )
    )
  }
}

public struct SchedulerPressureCoordinationStatus: Codable, Equatable, Sendable {
  public let pressureDecision: HostPressurePolicyDecision
  public let schedulerHostPosture: SchedulerHostPosture
  public let reclamationResults: [VMReclamationResult]
  public let verifiedReclaimedBytes: UInt64
  /// Always zero in the scheduler adapter. Reclamation evidence is not
  /// reusable capacity until an authoritative capacity ledger consumes it.
  public let reusableCapacityBytes: UInt64
  public let pressureObservedAt: Date

  public var isAdmissionAllowed: Bool {
    pressureDecision.posture != .blocked
  }

  fileprivate init(
    pressureDecision: HostPressurePolicyDecision,
    schedulerHostPosture: SchedulerHostPosture,
    reclamationResults: [VMReclamationResult],
    verifiedReclaimedBytes: UInt64,
    reusableCapacityBytes: UInt64 = 0
  ) {
    self.pressureDecision = pressureDecision
    self.schedulerHostPosture = schedulerHostPosture
    self.reclamationResults = reclamationResults
    self.verifiedReclaimedBytes = verifiedReclaimedBytes
    self.reusableCapacityBytes = reusableCapacityBytes
    self.pressureObservedAt = pressureDecision.observedAt
  }
}

public enum SchedulerPressureCoordination {
  public static let maximumReclamationResults =
    SchedulerPressureCoordinationInput.maximumReclamationResults

  private static let unavailablePressureReasons: [HostPressureReasonCode] = [
    .hysteresisVersionMismatch,
    .hysteresisStateInvalid,
    .hostUnavailable,
    .thermalUnavailable,
    .memoryUnavailable,
    .sleepUnavailable,
    .maintenanceUnavailable,
    .diskUnavailable,
    .powerSourceUnavailable,
    .batteryLevelUnavailable,
  ]

  private static let constrainedEnergyReasons: [HostPressureReasonCode] = [
    .lowPowerMode,
    .batteryPowerSource,
    .batteryLow,
  ]

  public static func status(
    for input: SchedulerPressureCoordinationInput
  ) -> SchedulerPressureCoordinationStatus {
    let pressure = schedulerPressure(for: input.pressureDecision)
    let energy = schedulerEnergy(for: input.pressureDecision)
    let verifiedReclaimedBytes = input.reclamationResults.reduce(into: UInt64(0)) {
      total, result in
      guard contributesVerifiedReclamation(result) else {
        return
      }
      total += result.measuredReclaimedBytes
    }

    return SchedulerPressureCoordinationStatus(
      pressureDecision: input.pressureDecision,
      schedulerHostPosture: SchedulerHostPosture(
        pressure: pressure,
        energy: energy
      ),
      reclamationResults: input.reclamationResults,
      verifiedReclaimedBytes: verifiedReclaimedBytes,
      reusableCapacityBytes: 0
    )
  }

  fileprivate static func contributesVerifiedReclamation(
    _ result: VMReclamationResult
  ) -> Bool {
    result.state == .reclaimed
      && result.intent.state == .reclaimed
      && result.intent.ownership == .hostwrightOwned
      && result.reasonCode == .reclaimed
      && result.errorCode == nil
      && result.measuredReclaimedBytes > 0
  }

  private static func schedulerPressure(
    for decision: HostPressurePolicyDecision
  ) -> SchedulerPressurePosture {
    switch decision.posture {
    case .allowed:
      return .nominal
    case .deweighted:
      return .elevated
    case .blocked:
      return decision.reasonCodes.contains(where: unavailablePressureReasons.contains)
        ? .unavailable
        : .critical
    }
  }

  private static func schedulerEnergy(
    for decision: HostPressurePolicyDecision
  ) -> SchedulerEnergyPosture {
    if decision.reasonCodes.contains(where: unavailablePressureReasons.contains) {
      return .unknown
    }
    if decision.reasonCodes.contains(where: constrainedEnergyReasons.contains) {
      return .constrained
    }
    return .balanced
  }
}

public enum SchedulerPressureAuthorityError: String, Error, Codable, Equatable, Sendable {
  case invalidProbeObservation = "invalid-probe-observation"
  case invalidPolicyState = "invalid-policy-state"
  case unknownNode = "unknown-node"
  case staleGeneration = "stale-generation"
  case persistenceFailed = "persistence-failed"
}

/// Owns the public Dispatch memory-pressure source and turns each synchronous
/// probe sample into a durable scheduler authority. The source starts unknown;
/// admission therefore remains fail-closed until Dispatch delivers an actual
/// memory-pressure observation.
public struct SchedulerMacOSHostPressureProbe: HostPressureProbe, Sendable {
  private let memoryPressure: OSAllocatedUnfairLock<HostPressureLevel>
  private let source: any DispatchSourceMemoryPressure
  private let volumeURL: URL
  private let sleepWakeState: HostSleepWakeState
  private let maintenanceState: HostMaintenanceState
  private let availability: HostAvailability
  private let diskPressureThresholds: HostDiskPressureThresholds
  private let processInfoReader: any HostProcessInfoReader
  private let diskFactsReader: any HostDiskFactsReader
  private let powerSourceReader: any HostPowerSourceReader

  public init(
    volumeURL: URL = URL(fileURLWithPath: "/"),
    initialMemoryPressure: HostPressureLevel = .unknown,
    sleepWakeState: HostSleepWakeState = .awake,
    maintenanceState: HostMaintenanceState = .inactive,
    availability: HostAvailability = .available,
    diskPressureThresholds: HostDiskPressureThresholds = .standard,
    processInfoReader: any HostProcessInfoReader = MacOSProcessInfoReader(),
    diskFactsReader: any HostDiskFactsReader = MacOSDiskFactsReader(),
    powerSourceReader: any HostPowerSourceReader = MacOSPowerSourceReader()
  ) {
    let memoryPressure = OSAllocatedUnfairLock<HostPressureLevel>(
      uncheckedState: initialMemoryPressure
    )
    self.memoryPressure = memoryPressure
    self.volumeURL = volumeURL
    self.sleepWakeState = sleepWakeState
    self.maintenanceState = maintenanceState
    self.availability = availability
    self.diskPressureThresholds = diskPressureThresholds
    self.processInfoReader = processInfoReader
    self.diskFactsReader = diskFactsReader
    self.powerSourceReader = powerSourceReader
    let source = MacOSHostPressureProbe.makeMemoryPressureSource { level in
      memoryPressure.withLock { state in
        state = level
      }
    }
    self.source = source
    source.activate()
  }

  public func sample(at observationTime: Date) -> HostPressureSample {
    let level = memoryPressure.withLock { $0 }
    return MacOSHostPressureProbe(
      volumeURL: volumeURL,
      systemMemoryPressure: level,
      sleepWakeState: sleepWakeState,
      maintenanceState: maintenanceState,
      availability: availability,
      diskPressureThresholds: diskPressureThresholds,
      processInfoReader: processInfoReader,
      diskFactsReader: diskFactsReader,
      powerSourceReader: powerSourceReader
    ).sample(at: observationTime)
  }
}

/// The daemon boundary for pressure authority. Simulation never calls this
/// type: the control layer injects it only into executable plan/apply paths.
public struct SchedulerPressureAuthorityCoordinator: Sendable {
  public typealias Clock = @Sendable () -> Date

  public static let maximumNodeCount = 4_096

  private let probe: any HostPressureProbe
  private let policy: HostPressurePolicy
  private let repository: SchedulerAdmissionRepository
  private let clock: Clock

  public init(
    probe: any HostPressureProbe,
    policy: HostPressurePolicy = HostPressurePolicy(),
    repository: SchedulerAdmissionRepository,
    clock: @escaping Clock
  ) {
    self.probe = probe
    self.policy = policy
    self.repository = repository
    self.clock = clock
  }

  /// Samples once and persists one authority record for each requested node.
  /// Node IDs are canonicalized before any repository read or write so input
  /// order cannot change either hysteresis or generation assignment.
  @discardableResult
  public func refresh(nodeIDs: [UUID]) throws -> [UUID: SchedulerHostPosture] {
    guard nodeIDs.count <= Self.maximumNodeCount else {
      throw SchedulerPressureAuthorityError.invalidProbeObservation
    }
    let canonicalNodeIDs = Array(Set(nodeIDs)).sorted {
      $0.uuidString.lowercased() < $1.uuidString.lowercased()
    }
    for nodeID in canonicalNodeIDs {
      guard try repository.nodeCapacity(nodeID: nodeID) != nil else {
        throw SchedulerPressureAuthorityError.unknownNode
      }
    }
    let observationTime = clock()
    guard observationTime.timeIntervalSince1970.isFinite else {
      throw SchedulerPressureAuthorityError.invalidProbeObservation
    }
    let sample = probe.sample(at: observationTime)
    guard sample.observedAt.timeIntervalSince1970.isFinite else {
      throw SchedulerPressureAuthorityError.invalidProbeObservation
    }

    var postures: [UUID: SchedulerHostPosture] = [:]
    for nodeID in canonicalNodeIDs {
      let existing = try repository.hostPressure(nodeID: nodeID)
      let previousState = try previousHysteresisState(from: existing)
      let decision = policy.evaluate(sample: sample, previousState: previousState)
      let posture = try SchedulerPressureCoordination.status(
        for: SchedulerPressureCoordinationInput(pressureDecision: decision)
      ).schedulerHostPosture
      let policyState = try schedulerPolicyState(from: decision)
      let generation: Int64
      if let existing {
        guard existing.generation < Int64.max else {
          throw SchedulerPressureAuthorityError.staleGeneration
        }
        generation = existing.generation + 1
      } else {
        generation = 1
      }
      let record = try SchedulerHostPressureRecord(
        nodeID: nodeID,
        posture: posture,
        generation: generation,
        observedAt: iso8601(sample.observedAt),
        evidenceDigest: try evidenceDigest(
          sample: sample,
          decision: decision,
          previousGeneration: existing?.generation
        ),
        policyState: policyState
      )
      do {
        _ = try repository.recordHostPressure(record: record)
      } catch let error as SchedulerAdmissionError
        where error.stableKey == "stale-input:pressure-generation" {
        throw SchedulerPressureAuthorityError.staleGeneration
      } catch {
        throw SchedulerPressureAuthorityError.persistenceFailed
      }
      postures[nodeID] = record.posture
    }
    return postures
  }

  /// Refreshes the persisted pressure authority and projects it into the
  /// immutable engine input. The new input digest therefore binds the plan to
  /// the persisted pressure posture that was actually admitted.
  public func refresh(input: SchedulerEngineInput) throws -> SchedulerEngineInput {
    let postures = try refresh(nodeIDs: input.nodes.map(\.nodeID))
    let nodes = try input.nodes.map { node in
      try SchedulerNode(
        snapshot: node.snapshot,
        topologyDomains: node.topologyDomains,
        posture: postures[node.nodeID] ?? node.posture,
        allocatable: node.allocatable,
        reservation: node.reservation,
        binClass: node.binClass,
        availableVolumeIDs: node.availableVolumeIDs,
        availablePorts: node.availablePorts,
        availableNetworkIDs: node.availableNetworkIDs
      )
    }
    return try SchedulerEngineInput(
      pendingWorkloads: input.pendingWorkloads,
      nodes: nodes,
      fairnessStates: input.fairnessStates,
      existingPlacements: input.existingPlacements,
      victimAllocations: input.victimAllocations,
      disruptionBudgets: input.disruptionBudgets,
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

  private func previousHysteresisState(
    from record: SchedulerHostPressureRecord?
  ) throws -> HostPressureHysteresisState {
    guard let record else { return .initial }
    guard let posture = HostAdmissionPosture(
      rawValue: record.policyState.nextHysteresisState.posture.rawValue
    ) else {
      throw SchedulerPressureAuthorityError.invalidPolicyState
    }
    do {
      return try HostPressureHysteresisState(
        previousPosture: posture,
        consecutiveClearObservations: record.policyState.nextHysteresisState
          .consecutiveClearObservations,
        version: record.policyState.nextHysteresisState.version
      )
    } catch {
      throw SchedulerPressureAuthorityError.invalidPolicyState
    }
  }

  private func schedulerPolicyState(
    from decision: HostPressurePolicyDecision
  ) throws -> SchedulerHostPressurePolicyState {
    guard let nextPosture = SchedulerHostPressurePolicyPosture(
      rawValue: decision.nextState.posture.rawValue
    ) else {
      throw SchedulerPressureAuthorityError.invalidPolicyState
    }
    let reasonCodes = try decision.reasonCodes.map { reason in
      guard let code = SchedulerHostPressureReasonCode(rawValue: reason.rawValue) else {
        throw SchedulerPressureAuthorityError.invalidPolicyState
      }
      return code
    }
    do {
      return try SchedulerHostPressurePolicyState(
        version: decision.version,
        reasonCodes: reasonCodes,
        nextHysteresisState: try SchedulerHostPressureHysteresisState(
          posture: nextPosture,
          consecutiveClearObservations: decision.nextState.consecutiveClearObservations,
          version: decision.nextState.version
        )
      )
    } catch {
      throw SchedulerPressureAuthorityError.invalidPolicyState
    }
  }

  private func evidenceDigest(
    sample: HostPressureSample,
    decision: HostPressurePolicyDecision,
    previousGeneration: Int64?
  ) throws -> String {
    struct Evidence: Codable {
      let sample: HostPressureSample
      let decision: HostPressurePolicyDecision
      let previousGeneration: Int64?
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      return SHA256.hash(
        data: try encoder.encode(
          Evidence(
            sample: sample,
            decision: decision,
            previousGeneration: previousGeneration
          )
        )
      ).map { String(format: "%02x", $0) }.joined()
    } catch {
      throw SchedulerPressureAuthorityError.invalidProbeObservation
    }
  }

  private func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
