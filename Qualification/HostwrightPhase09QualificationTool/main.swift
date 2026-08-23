import CryptoKit
import Darwin
import Foundation
import HostwrightCore

public struct Gate15QualificationError: Error, Equatable, CustomStringConvertible {
  public let code: String
  public let message: String

  public init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }

  public var description: String { "\(code): \(message)" }
}

public struct Gate15Contract: Codable, Equatable, Sendable {
  public let schema: String
  public let gate: Int
  public let durationSeconds: UInt64
  public let intervalSeconds: UInt64
  public let requiredIntervals: UInt64
  public let awakeToleranceSeconds: UInt64
  public let cells: [String]

  public init(
    durationSeconds: UInt64 = 14_400,
    intervalSeconds: UInt64 = 300,
    requiredIntervals: UInt64 = 48,
    awakeToleranceSeconds: UInt64 = 30,
    cells: [String] = ["U", "I", "L", "M", "S", "R"]
  ) {
    self.schema = "hostwright.phase09.gate15.continuity.v1"
    self.gate = 15
    self.durationSeconds = durationSeconds
    self.intervalSeconds = intervalSeconds
    self.requiredIntervals = requiredIntervals
    self.awakeToleranceSeconds = awakeToleranceSeconds
    self.cells = cells
  }

  public static let frozen = Gate15Contract()

  public var requiredSampleCount: Int {
    let (count, overflowed) = requiredIntervals.addingReportingOverflow(1)
    guard requiredIntervals < UInt64(Int.max), !overflowed else {
      return Int.max
    }
    return Int(count)
  }

  public var requiredSampleCountOverflowed: Bool {
    requiredIntervals.addingReportingOverflow(1).overflow
  }

  public func isFrozen() -> Bool {
    self == .frozen
  }
}

public struct Gate15ClockReading: Codable, Equatable, Sendable {
  public let continuousTicks: UInt64
  public let wallClockUTC: String
  public let bootSessionID: String

  public init(continuousTicks: UInt64, wallClockUTC: String, bootSessionID: String) {
    self.continuousTicks = continuousTicks
    self.wallClockUTC = wallClockUTC
    self.bootSessionID = bootSessionID
  }
}

public protocol Gate15Clock {
  var ticksPerSecond: UInt64 { get }
  func reading() throws -> Gate15ClockReading
  func wait(until ticks: UInt64) throws
}

public protocol Gate15RationalClock: Gate15Clock {
  var timebase: Gate15Timebase { get }
}

/// The mach timebase is a rational number of nanoseconds per continuous tick.
/// All qualification decisions use this value; `ticksPerSecond` is retained
/// only as a compatibility convenience for test clocks.
public struct Gate15Timebase: Codable, Equatable, Sendable {
  public let numer: UInt64
  public let denom: UInt64

  public init(numer: UInt64, denom: UInt64) throws {
    guard numer > 0, denom > 0 else {
      throw Gate15QualificationError("invalidClock", "mach_timebase_info returned a zero rational component.")
    }
    self.numer = numer
    self.denom = denom
  }

  public func ticks(forSeconds seconds: UInt64) throws -> UInt64 {
    let (nanoseconds, firstOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !firstOverflow else {
      throw Gate15QualificationError("clockOverflow", "the requested duration overflowed nanoseconds.")
    }
    let (scaled, secondOverflow) = nanoseconds.multipliedReportingOverflow(by: denom)
    guard !secondOverflow else {
      throw Gate15QualificationError("clockOverflow", "the requested duration overflowed the mach timebase.")
    }
    let quotient = scaled / numer
    let remainder = scaled % numer
    let (rounded, roundingOverflow) = quotient.addingReportingOverflow(remainder == 0 ? 0 : 1)
    guard !roundingOverflow, rounded > 0 || seconds == 0 else {
      throw Gate15QualificationError("clockOverflow", "the requested duration has no representable tick target.")
    }
    return rounded
  }

  public func durationAtLeast(ticks: UInt64, seconds: UInt64) throws -> Bool {
    let (tickNanoseconds, firstOverflow) = ticks.multipliedReportingOverflow(by: numer)
    guard !firstOverflow else {
      throw Gate15QualificationError("clockOverflow", "sample ticks overflowed the mach timebase numerator.")
    }
    let (nanoseconds, secondOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !secondOverflow else {
      throw Gate15QualificationError("clockOverflow", "duration nanoseconds overflowed the bounded rational.")
    }
    let (required, thirdOverflow) = nanoseconds.multipliedReportingOverflow(by: denom)
    guard !thirdOverflow else {
      throw Gate15QualificationError("clockOverflow", "duration scaling overflowed the bounded rational.")
    }
    return tickNanoseconds >= required
  }

  public func durationSecondsFloor(ticks: UInt64) throws -> UInt64 {
    let (scaled, overflowed) = ticks.multipliedReportingOverflow(by: numer)
    guard !overflowed else {
      throw Gate15QualificationError("clockOverflow", "elapsed ticks overflowed the mach timebase numerator.")
    }
    let nanos = scaled / denom
    return nanos / 1_000_000_000
  }

  public func nanoseconds(forTicks ticks: UInt64) throws -> UInt64 {
    let (scaled, overflowed) = ticks.multipliedReportingOverflow(by: numer)
    guard !overflowed else {
      throw Gate15QualificationError("clockOverflow", "elapsed ticks overflowed the mach timebase numerator.")
    }
    return scaled / denom
  }
}

public struct Gate15ProcessIdentity: Codable, Equatable, Sendable {
  public let pid: Int32
  public let startIdentity: String

  public init(pid: Int32, startIdentity: String) {
    self.pid = pid
    self.startIdentity = startIdentity
  }
}

public protocol Gate15ProcessIdentityProvider {
  func current() throws -> Gate15ProcessIdentity
  func lookup(pid: Int32) throws -> Gate15ProcessIdentity
}

public struct Gate15DaemonIdentity: Codable, Equatable, Sendable {
  public let pid: Int32
  public let generation: UInt64
  public let startIdentity: String

  public init(pid: Int32, generation: UInt64, startIdentity: String) {
    self.pid = pid
    self.generation = generation
    self.startIdentity = startIdentity
  }
}

public struct Gate15SignedExecutableIdentity: Codable, Equatable, Sendable {
  public let sha256: String
  public let cdHash: String
  public let teamID: String
  public let identifier: String

  public init(sha256: String, cdHash: String, teamID: String, identifier: String) {
    self.sha256 = sha256
    self.cdHash = cdHash
    self.teamID = teamID
    self.identifier = identifier
  }
}

public struct Gate15StateDatabaseIdentity: Codable, Equatable, Sendable {
  public let identityDigest: String
  public let sizeBytes: UInt64
  public let integrity: String
  public let schema: UInt64

  public init(identityDigest: String, sizeBytes: UInt64, integrity: String, schema: UInt64) {
    self.identityDigest = identityDigest
    self.sizeBytes = sizeBytes
    self.integrity = integrity
    self.schema = schema
  }
}

public struct Gate15RuntimeIdentity: Codable, Equatable, Sendable {
  public let runtimeUUID: String
  public let project: String
  public let imageDigest: String
  public let inventoryDigest: String

  public init(runtimeUUID: String, project: String, imageDigest: String, inventoryDigest: String) {
    self.runtimeUUID = runtimeUUID
    self.project = project
    self.imageDigest = imageDigest
    self.inventoryDigest = inventoryDigest
  }
}

public struct Gate15Metrics: Codable, Equatable, Sendable {
  public let rssBytes: UInt64
  public let fileDescriptorCount: UInt64
  public let operationCount: UInt64
  public let activeMutationGroups: UInt64
  public let retryCount: UInt64

  public init(
    rssBytes: UInt64,
    fileDescriptorCount: UInt64,
    operationCount: UInt64,
    activeMutationGroups: UInt64,
    retryCount: UInt64
  ) {
    self.rssBytes = rssBytes
    self.fileDescriptorCount = fileDescriptorCount
    self.operationCount = operationCount
    self.activeMutationGroups = activeMutationGroups
    self.retryCount = retryCount
  }
}

public struct Gate15DaemonRestart: Codable, Equatable, Sendable {
  public let previous: Gate15DaemonIdentity
  public let current: Gate15DaemonIdentity
  public let recoveryWithinBound: Bool

  public init(
    previous: Gate15DaemonIdentity,
    current: Gate15DaemonIdentity,
    recoveryWithinBound: Bool
  ) {
    self.previous = previous
    self.current = current
    self.recoveryWithinBound = recoveryWithinBound
  }
}

public struct Gate15FaultObservation: Codable, Equatable, Sendable {
  public let scheduledMarker: String
  public let recoveryResult: String
  public let recoveryWithinBound: Bool
  public let plannedDaemonRestart: Bool
  public let daemonRestart: Gate15DaemonRestart?

  public init(
    scheduledMarker: String,
    recoveryResult: String,
    recoveryWithinBound: Bool,
    plannedDaemonRestart: Bool = false,
    daemonRestart: Gate15DaemonRestart? = nil
  ) {
    self.scheduledMarker = scheduledMarker
    self.recoveryResult = recoveryResult
    self.recoveryWithinBound = recoveryWithinBound
    self.plannedDaemonRestart = plannedDaemonRestart
    self.daemonRestart = daemonRestart
  }

  public static let none = Gate15FaultObservation(
    scheduledMarker: "none",
    recoveryResult: "none",
    recoveryWithinBound: true
  )
}

public struct Gate15SleepWakeInterval: Codable, Equatable, Sendable {
  public let sleepStartUTC: String
  public let wakeUTC: String
  public let continuousStartTicks: UInt64
  public let continuousEndTicks: UInt64
  public let sleepEventID: String
  public let wakeEventID: String
  public let source: String
  public let observerIdentity: String
  public let sleepObserverReceiptDigest: String
  public let wakeObserverReceiptDigest: String
  public let authenticationDigest: String

  public init(
    sleepStartUTC: String,
    wakeUTC: String,
    continuousStartTicks: UInt64,
    continuousEndTicks: UInt64,
    sleepEventID: String = "fixture-sleep",
    wakeEventID: String = "fixture-wake",
    source: String = "fixture",
    observerIdentity: String = "fixture-observer",
    sleepObserverReceiptDigest: String = "fixture",
    wakeObserverReceiptDigest: String = "fixture",
    authenticationDigest: String = "fixture"
  ) {
    self.sleepStartUTC = sleepStartUTC
    self.wakeUTC = wakeUTC
    self.continuousStartTicks = continuousStartTicks
    self.continuousEndTicks = continuousEndTicks
    self.sleepEventID = sleepEventID
    self.wakeEventID = wakeEventID
    self.source = source
    self.observerIdentity = observerIdentity
    self.sleepObserverReceiptDigest = sleepObserverReceiptDigest
    self.wakeObserverReceiptDigest = wakeObserverReceiptDigest
    self.authenticationDigest = authenticationDigest
  }

  public func observerReceiptDigestValue(kind: String) throws -> String {
    let input = Gate15SleepWakeObserverReceiptAuthenticationInput(
      observerIdentity: observerIdentity,
      eventID: kind == "sleep" ? sleepEventID : wakeEventID,
      kind: kind,
      observedAtUTC: kind == "sleep" ? sleepStartUTC : wakeUTC,
      continuousTicks: kind == "sleep" ? continuousStartTicks : continuousEndTicks
    )
    return "sha256:\(Gate15JSON.sha256Hex(try Gate15JSON.encoder.encode(input)))"
  }

  public func authenticationDigestValue() throws -> String {
    let input = Gate15SleepWakeIntervalAuthenticationInput(interval: self)
    return "sha256:\(Gate15JSON.sha256Hex(try Gate15JSON.encoder.encode(input)))"
  }
}

private struct Gate15SleepWakeIntervalAuthenticationInput: Codable {
  let sleepStartUTC: String
  let wakeUTC: String
  let continuousStartTicks: UInt64
  let continuousEndTicks: UInt64
  let sleepEventID: String
  let wakeEventID: String
  let source: String
  let observerIdentity: String
  let sleepObserverReceiptDigest: String
  let wakeObserverReceiptDigest: String

  init(interval: Gate15SleepWakeInterval) {
    sleepStartUTC = interval.sleepStartUTC
    wakeUTC = interval.wakeUTC
    continuousStartTicks = interval.continuousStartTicks
    continuousEndTicks = interval.continuousEndTicks
    sleepEventID = interval.sleepEventID
    wakeEventID = interval.wakeEventID
    source = interval.source
    observerIdentity = interval.observerIdentity
    sleepObserverReceiptDigest = interval.sleepObserverReceiptDigest
    wakeObserverReceiptDigest = interval.wakeObserverReceiptDigest
  }
}

private struct Gate15SleepWakeObserverReceiptAuthenticationInput: Codable {
  let observerIdentity: String
  let eventID: String
  let kind: String
  let observedAtUTC: String
  let continuousTicks: UInt64
}

public struct Gate15SleepWakeEvent: Codable, Equatable, Sendable {
  public let eventID: String
  public let kind: String
  public let observedAtUTC: String
  public let continuousTicks: UInt64
  public let bootSessionID: String
  public let source: String
  public let observerIdentity: String
  public let observerReceiptDigest: String
  public let authenticationDigest: String

  public init(
    eventID: String,
    kind: String,
    observedAtUTC: String,
    continuousTicks: UInt64,
    bootSessionID: String,
    source: String,
    observerIdentity: String = "fixture-observer",
    observerReceiptDigest: String = "fixture",
    authenticationDigest: String
  ) {
    self.eventID = eventID
    self.kind = kind
    self.observedAtUTC = observedAtUTC
    self.continuousTicks = continuousTicks
    self.bootSessionID = bootSessionID
    self.source = source
    self.observerIdentity = observerIdentity
    self.observerReceiptDigest = observerReceiptDigest
    self.authenticationDigest = authenticationDigest
  }

  public static let authenticatedSource = "macos-iokit-power-events-v1"

  public func authenticationDigestValue() throws -> String {
    let input = Gate15SleepWakeEventAuthenticationInput(event: self)
    return Gate15JSON.sha256Hex(try Gate15JSON.encoder.encode(input))
  }

  public func observerReceiptDigestValue() throws -> String {
    let input = Gate15SleepWakeObserverReceiptAuthenticationInput(
      observerIdentity: observerIdentity,
      eventID: eventID,
      kind: kind,
      observedAtUTC: observedAtUTC,
      continuousTicks: continuousTicks
    )
    return "sha256:\(Gate15JSON.sha256Hex(try Gate15JSON.encoder.encode(input)))"
  }
}

private struct Gate15SleepWakeEventAuthenticationInput: Codable {
  let eventID: String
  let kind: String
  let observedAtUTC: String
  let continuousTicks: UInt64
  let bootSessionID: String
  let source: String
  let observerIdentity: String

  init(event: Gate15SleepWakeEvent) {
    eventID = event.eventID
    kind = event.kind
    observedAtUTC = event.observedAtUTC
    continuousTicks = event.continuousTicks
    bootSessionID = event.bootSessionID
    source = event.source
    observerIdentity = event.observerIdentity
  }
}

public protocol Gate15SleepWakeEventProvider {
  func events(from start: Gate15ClockReading, to end: Gate15ClockReading) throws -> [Gate15SleepWakeEvent]
}

public struct Gate15IndependentObservationReceipt: Codable, Equatable, Sendable {
  public static let authenticatedSource = "hostwright.live-wrapper.system-observation-receipt-v1"

  public let source: String
  public let observerIdentity: String
  public let inventoryDigest: String
  public let daemonStateDigest: String
  public let executableIdentityDigest: String
  public let executableReceiptDigest: String
  public let daemonReceiptDigest: String
  public let stateReceiptDigest: String
  public let containerReceiptDigest: String
  public let runtimeReceiptDigest: String
  public let receiptDigest: String
  public let authorizationDigest: String

  public init(
    source: String = Gate15IndependentObservationReceipt.authenticatedSource,
    observerIdentity: String = "",
    inventoryDigest: String = "",
    daemonStateDigest: String = "",
    executableIdentityDigest: String = "",
    executableReceiptDigest: String = "",
    daemonReceiptDigest: String = "",
    stateReceiptDigest: String = "",
    containerReceiptDigest: String = "",
    runtimeReceiptDigest: String = "",
    receiptDigest: String = "",
    authorizationDigest: String = ""
  ) {
    self.source = source
    self.observerIdentity = observerIdentity
    self.inventoryDigest = inventoryDigest
    self.daemonStateDigest = daemonStateDigest
    self.executableIdentityDigest = executableIdentityDigest
    self.executableReceiptDigest = executableReceiptDigest
    self.daemonReceiptDigest = daemonReceiptDigest
    self.stateReceiptDigest = stateReceiptDigest
    self.containerReceiptDigest = containerReceiptDigest
    self.runtimeReceiptDigest = runtimeReceiptDigest
    self.receiptDigest = receiptDigest
    self.authorizationDigest = authorizationDigest
  }

  public static let empty = Gate15IndependentObservationReceipt()

  public func receiptDigestValue() throws -> String {
    let input = Gate15IndependentObservationReceiptAuthenticationInput(receipt: self)
    return "sha256:\(Gate15JSON.sha256Hex(try Gate15JSON.encoder.encode(input)))"
  }
}

private struct Gate15IndependentObservationReceiptAuthenticationInput: Codable {
  let source: String
  let observerIdentity: String
  let inventoryDigest: String
  let daemonStateDigest: String
  let executableIdentityDigest: String
  let executableReceiptDigest: String
  let daemonReceiptDigest: String
  let stateReceiptDigest: String
  let containerReceiptDigest: String
  let runtimeReceiptDigest: String

  init(receipt: Gate15IndependentObservationReceipt) {
    source = receipt.source
    observerIdentity = receipt.observerIdentity
    inventoryDigest = receipt.inventoryDigest
    daemonStateDigest = receipt.daemonStateDigest
    executableIdentityDigest = receipt.executableIdentityDigest
    executableReceiptDigest = receipt.executableReceiptDigest
    daemonReceiptDigest = receipt.daemonReceiptDigest
    stateReceiptDigest = receipt.stateReceiptDigest
    containerReceiptDigest = receipt.containerReceiptDigest
    runtimeReceiptDigest = receipt.runtimeReceiptDigest
  }
}

public struct Gate15BoundaryBinding: Codable, Equatable, Sendable {
  public let sourceDigest: String
  public let configDigest: String
  public let toolchainDigest: String
  public let dependencyEvidenceDigest: String
  public let executablePinsetDigest: String

  public init(
    sourceDigest: String,
    configDigest: String,
    toolchainDigest: String,
    dependencyEvidenceDigest: String,
    executablePinsetDigest: String
  ) {
    self.sourceDigest = sourceDigest
    self.configDigest = configDigest
    self.toolchainDigest = toolchainDigest
    self.dependencyEvidenceDigest = dependencyEvidenceDigest
    self.executablePinsetDigest = executablePinsetDigest
  }
}

public struct Gate15Observation: Codable, Equatable, Sendable {
  public let observedAtUTC: String
  public let continuousTicks: UInt64
  public let bootSessionID: String
  public let runner: Gate15ProcessIdentity
  public let daemon: Gate15DaemonIdentity
  public let executable: Gate15SignedExecutableIdentity
  public let stateDatabase: Gate15StateDatabaseIdentity
  public let runtime: Gate15RuntimeIdentity
  public let metrics: Gate15Metrics
  public let fault: Gate15FaultObservation
  public let sleepWakeCoverage: [Gate15SleepWakeInterval]
  public let boundaryBinding: Gate15BoundaryBinding?
  public let independentReceipt: Gate15IndependentObservationReceipt?

  public init(
    observedAtUTC: String,
    continuousTicks: UInt64,
    bootSessionID: String,
    runner: Gate15ProcessIdentity,
    daemon: Gate15DaemonIdentity,
    executable: Gate15SignedExecutableIdentity,
    stateDatabase: Gate15StateDatabaseIdentity,
    runtime: Gate15RuntimeIdentity,
    metrics: Gate15Metrics,
    fault: Gate15FaultObservation = .none,
    sleepWakeCoverage: [Gate15SleepWakeInterval] = [],
    boundaryBinding: Gate15BoundaryBinding? = nil,
    independentReceipt: Gate15IndependentObservationReceipt? = nil
  ) {
    self.observedAtUTC = observedAtUTC
    self.continuousTicks = continuousTicks
    self.bootSessionID = bootSessionID
    self.runner = runner
    self.daemon = daemon
    self.executable = executable
    self.stateDatabase = stateDatabase
    self.runtime = runtime
    self.metrics = metrics
    self.fault = fault
    self.sleepWakeCoverage = sleepWakeCoverage
    self.boundaryBinding = boundaryBinding
    self.independentReceipt = independentReceipt
  }

  public func with(
    sleepWakeCoverage: [Gate15SleepWakeInterval],
    boundaryBinding: Gate15BoundaryBinding? = nil,
    independentReceipt: Gate15IndependentObservationReceipt? = nil
  ) -> Gate15Observation {
    Gate15Observation(
      observedAtUTC: observedAtUTC,
      continuousTicks: continuousTicks,
      bootSessionID: bootSessionID,
      runner: runner,
      daemon: daemon,
      executable: executable,
      stateDatabase: stateDatabase,
      runtime: runtime,
      metrics: metrics,
      fault: fault,
      sleepWakeCoverage: sleepWakeCoverage,
      boundaryBinding: boundaryBinding ?? self.boundaryBinding,
      independentReceipt: independentReceipt ?? self.independentReceipt
    )
  }
}

private struct Gate15ContainerObservationReceipt: Codable {
  let runtimeUUID: String
  let project: String
  let imageDigest: String
}

private enum Gate15ObservationReceiptDigests {
  static func executable(_ observation: Gate15Observation) throws -> String {
    try digest(observation.executable)
  }

  static func daemon(_ observation: Gate15Observation) throws -> String {
    try digest(observation.daemon)
  }

  static func state(_ observation: Gate15Observation) throws -> String {
    try digest(observation.stateDatabase)
  }

  static func container(_ observation: Gate15Observation) throws -> String {
    try digest(Gate15ContainerObservationReceipt(
      runtimeUUID: observation.runtime.runtimeUUID,
      project: observation.runtime.project,
      imageDigest: observation.runtime.imageDigest
    ))
  }

  static func runtime(_ observation: Gate15Observation) throws -> String {
    try digest(observation.runtime)
  }

  private static func digest<T: Encodable>(_ value: T) throws -> String {
    "sha256:\(Gate15JSON.sha256Hex(try Gate15JSON.encoder.encode(value)))"
  }
}

public extension Gate15IndependentObservationReceipt {
  static func make(for observation: Gate15Observation, observerIdentity: String) throws -> Self {
    let executableReceiptDigest = try Gate15ObservationReceiptDigests.executable(observation)
    let daemonReceiptDigest = try Gate15ObservationReceiptDigests.daemon(observation)
    let stateReceiptDigest = try Gate15ObservationReceiptDigests.state(observation)
    let containerReceiptDigest = try Gate15ObservationReceiptDigests.container(observation)
    let runtimeReceiptDigest = try Gate15ObservationReceiptDigests.runtime(observation)
    let unsigned = Self(
      observerIdentity: observerIdentity,
      inventoryDigest: observation.runtime.inventoryDigest,
      daemonStateDigest: observation.stateDatabase.identityDigest,
      executableIdentityDigest: observation.executable.sha256,
      executableReceiptDigest: executableReceiptDigest,
      daemonReceiptDigest: daemonReceiptDigest,
      stateReceiptDigest: stateReceiptDigest,
      containerReceiptDigest: containerReceiptDigest,
      runtimeReceiptDigest: runtimeReceiptDigest
    )
    return Self(
      observerIdentity: unsigned.observerIdentity,
      inventoryDigest: unsigned.inventoryDigest,
      daemonStateDigest: unsigned.daemonStateDigest,
      executableIdentityDigest: unsigned.executableIdentityDigest,
      executableReceiptDigest: unsigned.executableReceiptDigest,
      daemonReceiptDigest: unsigned.daemonReceiptDigest,
      stateReceiptDigest: unsigned.stateReceiptDigest,
      containerReceiptDigest: unsigned.containerReceiptDigest,
      runtimeReceiptDigest: unsigned.runtimeReceiptDigest,
      receiptDigest: try unsigned.receiptDigestValue()
    )
  }
}

public struct Gate15Sample: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let observedAtUTC: String
  public let continuousTicks: UInt64
  public let bootSessionID: String
  public let runner: Gate15ProcessIdentity
  public let daemon: Gate15DaemonIdentity
  public let executable: Gate15SignedExecutableIdentity
  public let stateDatabase: Gate15StateDatabaseIdentity
  public let runtime: Gate15RuntimeIdentity
  public let metrics: Gate15Metrics
  public let fault: Gate15FaultObservation
  public let sleepWakeCoverage: [Gate15SleepWakeInterval]
  public let boundaryBinding: Gate15BoundaryBinding?
  public let independentReceipt: Gate15IndependentObservationReceipt?
  public let previousSampleSHA256: String?
  public let sampleSHA256: String

  public init(
    sequence: UInt64,
    observation: Gate15Observation,
    previousSampleSHA256: String?,
    sampleSHA256: String
  ) {
    self.sequence = sequence
    self.observedAtUTC = observation.observedAtUTC
    self.continuousTicks = observation.continuousTicks
    self.bootSessionID = observation.bootSessionID
    self.runner = observation.runner
    self.daemon = observation.daemon
    self.executable = observation.executable
    self.stateDatabase = observation.stateDatabase
    self.runtime = observation.runtime
    self.metrics = observation.metrics
    self.fault = observation.fault
    self.sleepWakeCoverage = observation.sleepWakeCoverage
    self.boundaryBinding = observation.boundaryBinding
    self.independentReceipt = observation.independentReceipt
    self.previousSampleSHA256 = previousSampleSHA256
    self.sampleSHA256 = sampleSHA256
  }

  public var observation: Gate15Observation {
    Gate15Observation(
      observedAtUTC: observedAtUTC,
      continuousTicks: continuousTicks,
      bootSessionID: bootSessionID,
      runner: runner,
      daemon: daemon,
      executable: executable,
      stateDatabase: stateDatabase,
      runtime: runtime,
      metrics: metrics,
      fault: fault,
      sleepWakeCoverage: sleepWakeCoverage,
      boundaryBinding: boundaryBinding,
      independentReceipt: independentReceipt
    )
  }

  public func canonicalJSON() throws -> Data {
    try Gate15JSON.encoder.encode(self)
  }

  public static func hash(for sample: Gate15Sample) throws -> String {
    let input = Gate15SampleHashInput(sample: sample)
    let data = try Gate15JSON.encoder.encode(input)
    return Gate15JSON.sha256Hex(data)
  }
}

private struct Gate15SampleHashInput: Codable {
  let sequence: UInt64
  let observedAtUTC: String
  let continuousTicks: UInt64
  let bootSessionID: String
  let runner: Gate15ProcessIdentity
  let daemon: Gate15DaemonIdentity
  let executable: Gate15SignedExecutableIdentity
  let stateDatabase: Gate15StateDatabaseIdentity
  let runtime: Gate15RuntimeIdentity
  let metrics: Gate15Metrics
  let fault: Gate15FaultObservation
  let sleepWakeCoverage: [Gate15SleepWakeInterval]
  let boundaryBinding: Gate15BoundaryBinding?
  let independentReceipt: Gate15IndependentObservationReceipt?
  let previousSampleSHA256: String?

  init(sample: Gate15Sample) {
    sequence = sample.sequence
    observedAtUTC = sample.observedAtUTC
    continuousTicks = sample.continuousTicks
    bootSessionID = sample.bootSessionID
    runner = sample.runner
    daemon = sample.daemon
    executable = sample.executable
    stateDatabase = sample.stateDatabase
    runtime = sample.runtime
    metrics = sample.metrics
    fault = sample.fault
    sleepWakeCoverage = sample.sleepWakeCoverage
    boundaryBinding = sample.boundaryBinding
    independentReceipt = sample.independentReceipt
    previousSampleSHA256 = sample.previousSampleSHA256
  }
}

public protocol Gate15ObservationProvider {
  func observation(
    for reading: Gate15ClockReading,
    runner: Gate15ProcessIdentity
  ) throws -> Gate15Observation
}

public struct Gate15TrustedObservation: Codable, Equatable, Sendable {
  public static let authenticatedSource = Gate15IndependentObservationReceipt.authenticatedSource

  public let observation: Gate15Observation
  public let source: String
  public let inventoryDigest: String
  public let daemonStateDigest: String
  public let executableIdentityDigest: String
  public let receipt: Gate15IndependentObservationReceipt
  public let authorizationDigest: String

  public init(
    observation: Gate15Observation,
    source: String = Gate15TrustedObservation.authenticatedSource,
    inventoryDigest: String,
    daemonStateDigest: String,
    executableIdentityDigest: String,
    receipt: Gate15IndependentObservationReceipt = .empty,
    authorizationDigest: String
  ) {
    self.observation = observation
    self.source = source
    self.inventoryDigest = inventoryDigest
    self.daemonStateDigest = daemonStateDigest
    self.executableIdentityDigest = executableIdentityDigest
    self.receipt = receipt
    self.authorizationDigest = authorizationDigest
  }

  public func authorizationDigestValue() throws -> String {
    let input = Gate15TrustedObservationAuthenticationInput(observation: self)
    return "sha256:\(Gate15JSON.sha256Hex(try Gate15JSON.encoder.encode(input)))"
  }
}

private struct Gate15TrustedObservationAuthenticationInput: Codable {
  let observation: Gate15Observation
  let source: String
  let inventoryDigest: String
  let daemonStateDigest: String
  let executableIdentityDigest: String
  let receipt: Gate15IndependentObservationReceiptAuthenticationInput

  init(observation: Gate15TrustedObservation) {
    self.observation = observation.observation
    self.source = observation.source
    self.inventoryDigest = observation.inventoryDigest
    self.daemonStateDigest = observation.daemonStateDigest
    self.executableIdentityDigest = observation.executableIdentityDigest
    self.receipt = Gate15IndependentObservationReceiptAuthenticationInput(receipt: observation.receipt)
  }
}

public protocol Gate15TrustedObservationProvider {
  func trustedObservation(
    for reading: Gate15ClockReading,
    runner: Gate15ProcessIdentity
  ) throws -> Gate15TrustedObservation
}

public protocol Gate15AuthorizedExecutableBinding {
  func validateAuthorizedExecutable(for authorization: Gate15LaunchAuthorization) throws
}

public enum Gate15ObservationBinding {
  public static func validate(
    provider: Gate15Observation,
    trusted: Gate15TrustedObservation,
    reading: Gate15ClockReading,
    runner: Gate15ProcessIdentity,
    expectedBoundaryBinding: Gate15BoundaryBinding,
    providerIdentity: String? = nil,
    toolIdentity: String? = nil
  ) throws {
    let trustedObservation = trusted.observation
    guard provider.independentReceipt == nil,
          trustedObservation.independentReceipt == nil else {
      throw Gate15QualificationError("providerSelfAttestation", "formal providers may not supply their own observation receipt or sleep proof.")
    }
    let receipt = trusted.receipt
    let observerIdentityPattern = "^macos-system-observer-v1:[A-Za-z0-9._:-]{1,256}$"
    guard trusted.source == Gate15TrustedObservation.authenticatedSource,
          receipt.source == Gate15IndependentObservationReceipt.authenticatedSource,
          receipt.observerIdentity.range(of: observerIdentityPattern, options: .regularExpression) != nil,
          providerIdentity != receipt.observerIdentity,
          toolIdentity != receipt.observerIdentity,
          trusted.inventoryDigest == trustedObservation.runtime.inventoryDigest,
          trusted.daemonStateDigest == trustedObservation.stateDatabase.identityDigest,
          trusted.executableIdentityDigest == trustedObservation.executable.sha256,
          receipt.inventoryDigest == trusted.inventoryDigest,
          receipt.daemonStateDigest == trusted.daemonStateDigest,
          receipt.executableIdentityDigest == trusted.executableIdentityDigest,
          receipt.executableReceiptDigest == (try Gate15ObservationReceiptDigests.executable(trustedObservation)),
          receipt.daemonReceiptDigest == (try Gate15ObservationReceiptDigests.daemon(trustedObservation)),
          receipt.stateReceiptDigest == (try Gate15ObservationReceiptDigests.state(trustedObservation)),
          receipt.containerReceiptDigest == (try Gate15ObservationReceiptDigests.container(trustedObservation)),
          receipt.runtimeReceiptDigest == (try Gate15ObservationReceiptDigests.runtime(trustedObservation)),
          receipt.receiptDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
          receipt.authorizationDigest == trusted.authorizationDigest,
          receipt.receiptDigest == (try receipt.receiptDigestValue()),
          trusted.authorizationDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
          trusted.authorizationDigest == (try trusted.authorizationDigestValue()) else {
      throw Gate15QualificationError("trustedObservationUnauthenticated", "the independent live-wrapper observation receipt is not pinned to its exact executable, daemon, state, container, and runtime fields.")
    }
    guard provider.sleepWakeCoverage.isEmpty,
          trustedObservation.sleepWakeCoverage.isEmpty else {
      throw Gate15QualificationError("sleepEventSelfAttestation", "observation providers may not supply or backfill sleep/wake coverage.")
    }
    guard provider.runner == runner,
          provider.continuousTicks == reading.continuousTicks,
          provider.observedAtUTC == reading.wallClockUTC,
          provider.bootSessionID == reading.bootSessionID,
          trustedObservation.runner == runner,
          trustedObservation.continuousTicks == reading.continuousTicks,
          trustedObservation.observedAtUTC == reading.wallClockUTC,
          trustedObservation.bootSessionID == reading.bootSessionID,
          provider.boundaryBinding == expectedBoundaryBinding,
          trustedObservation.boundaryBinding == expectedBoundaryBinding else {
      throw Gate15QualificationError("observationMismatch", "provider data is not bound to the authoritative clock, runner, or immutable dependency binding.")
    }
    guard provider == trustedObservation,
          try Gate15JSON.encoder.encode(provider) == Gate15JSON.encoder.encode(trustedObservation) else {
      throw Gate15QualificationError("trustedObservationMismatch", "provider executable, daemon, state, runtime, metric, and fault data does not byte-match the independently captured live-wrapper observation.")
    }
  }
}

public protocol Gate15BoundaryValidator {
  func validate() throws
  func bind(to authorization: Gate15LaunchAuthorization) throws
}

public protocol Gate15DependencyValidator {
  func validate() throws
  func bind(to authorization: Gate15LaunchAuthorization) throws
}

public extension Gate15BoundaryValidator {
  func bind(to authorization: Gate15LaunchAuthorization) throws {}
}

public extension Gate15DependencyValidator {
  func bind(to authorization: Gate15LaunchAuthorization) throws {}
}

public struct Gate15LaunchAuthorization: Codable, Equatable, Sendable {
  public let schema: String
  public let root: String
  public let rootLockPath: String
  public let rootLockDevice: UInt64
  public let rootLockInode: UInt64
  public let gateLockPath: String
  public let gateLockDevice: UInt64
  public let gateLockInode: UInt64
  public let runnerPID: Int32
  public let runnerStartIdentity: String
  public let bootSessionID: String
  public let nonce: String
  public let sourceCommit: String
  public let sourceDigest: String
  public let configDigest: String
  public let toolchainDigest: String
  public let dependencyEvidenceDigest: String
  public let executablePinsetDigest: String
  public let dependencyValidatorPath: String
  public let dependencyValidatorDevice: UInt64
  public let dependencyValidatorInode: UInt64
  public let dependencyValidatorDigest: String
  public let boundaryValidatorPath: String
  public let boundaryValidatorDevice: UInt64
  public let boundaryValidatorInode: UInt64
  public let boundaryValidatorDigest: String
  public let executablePinsetPath: String
  public let executablePinsetDevice: UInt64
  public let executablePinsetInode: UInt64
  public let runStartedDigest: String
  public let manifestDigest: String
  public let toolPath: String
  public let toolDevice: UInt64
  public let toolInode: UInt64
  public let toolMode: UInt16
  public let toolDigest: String
  public let toolBuildIdentity: String
  public let invocation: String
  public let observationProviderPath: String
  public let observationProviderDevice: UInt64
  public let observationProviderInode: UInt64
  public let observationProviderDigest: String
  public let trustedObservationProviderPath: String
  public let trustedObservationProviderDevice: UInt64
  public let trustedObservationProviderInode: UInt64
  public let trustedObservationProviderDigest: String
  public let sleepWakeProviderPath: String
  public let sleepWakeProviderDevice: UInt64
  public let sleepWakeProviderInode: UInt64
  public let sleepWakeProviderDigest: String
  public let signingIdentity: String
  public let signingFingerprint: String
  public let certificateFingerprint: String
  public let teamID: String
  public let createdAtUTC: String

  public init(
    root: String,
    rootLockPath: String,
    rootLockDevice: UInt64,
    rootLockInode: UInt64,
    gateLockPath: String,
    gateLockDevice: UInt64,
    gateLockInode: UInt64,
    runnerPID: Int32,
    runnerStartIdentity: String,
    bootSessionID: String,
    nonce: String,
    sourceCommit: String,
    sourceDigest: String,
    configDigest: String,
    toolchainDigest: String,
    dependencyEvidenceDigest: String,
    executablePinsetDigest: String,
    dependencyValidatorPath: String,
    dependencyValidatorDevice: UInt64,
    dependencyValidatorInode: UInt64,
    dependencyValidatorDigest: String,
    boundaryValidatorPath: String,
    boundaryValidatorDevice: UInt64,
    boundaryValidatorInode: UInt64,
    boundaryValidatorDigest: String,
    executablePinsetPath: String,
    executablePinsetDevice: UInt64,
    executablePinsetInode: UInt64,
    runStartedDigest: String,
    manifestDigest: String,
    signingIdentity: String,
    signingFingerprint: String,
    certificateFingerprint: String,
    teamID: String,
    createdAtUTC: String,
    toolPath: String = "",
    toolDevice: UInt64 = 0,
    toolInode: UInt64 = 0,
    toolMode: UInt16 = 0,
    toolDigest: String = "",
    toolBuildIdentity: String = "",
    invocation: String = "",
    observationProviderPath: String = "",
    observationProviderDevice: UInt64 = 0,
    observationProviderInode: UInt64 = 0,
    observationProviderDigest: String = "",
    trustedObservationProviderPath: String = "",
    trustedObservationProviderDevice: UInt64 = 0,
    trustedObservationProviderInode: UInt64 = 0,
    trustedObservationProviderDigest: String = "",
    sleepWakeProviderPath: String = "",
    sleepWakeProviderDevice: UInt64 = 0,
    sleepWakeProviderInode: UInt64 = 0,
    sleepWakeProviderDigest: String = ""
  ) {
    self.schema = "hostwright.phase09.gate15.launch-authorization.v1"
    self.root = root
    self.rootLockPath = rootLockPath
    self.rootLockDevice = rootLockDevice
    self.rootLockInode = rootLockInode
    self.gateLockPath = gateLockPath
    self.gateLockDevice = gateLockDevice
    self.gateLockInode = gateLockInode
    self.runnerPID = runnerPID
    self.runnerStartIdentity = runnerStartIdentity
    self.bootSessionID = bootSessionID
    self.nonce = nonce
    self.sourceCommit = sourceCommit
    self.sourceDigest = sourceDigest
    self.configDigest = configDigest
    self.toolchainDigest = toolchainDigest
    self.dependencyEvidenceDigest = dependencyEvidenceDigest
    self.executablePinsetDigest = executablePinsetDigest
    self.dependencyValidatorPath = dependencyValidatorPath
    self.dependencyValidatorDevice = dependencyValidatorDevice
    self.dependencyValidatorInode = dependencyValidatorInode
    self.dependencyValidatorDigest = dependencyValidatorDigest
    self.boundaryValidatorPath = boundaryValidatorPath
    self.boundaryValidatorDevice = boundaryValidatorDevice
    self.boundaryValidatorInode = boundaryValidatorInode
    self.boundaryValidatorDigest = boundaryValidatorDigest
    self.executablePinsetPath = executablePinsetPath
    self.executablePinsetDevice = executablePinsetDevice
    self.executablePinsetInode = executablePinsetInode
    self.runStartedDigest = runStartedDigest
    self.manifestDigest = manifestDigest
    self.toolPath = toolPath
    self.toolDevice = toolDevice
    self.toolInode = toolInode
    self.toolMode = toolMode
    self.toolDigest = toolDigest
    self.toolBuildIdentity = toolBuildIdentity
    self.invocation = invocation
    self.observationProviderPath = observationProviderPath
    self.observationProviderDevice = observationProviderDevice
    self.observationProviderInode = observationProviderInode
    self.observationProviderDigest = observationProviderDigest
    self.trustedObservationProviderPath = trustedObservationProviderPath
    self.trustedObservationProviderDevice = trustedObservationProviderDevice
    self.trustedObservationProviderInode = trustedObservationProviderInode
    self.trustedObservationProviderDigest = trustedObservationProviderDigest
    self.sleepWakeProviderPath = sleepWakeProviderPath
    self.sleepWakeProviderDevice = sleepWakeProviderDevice
    self.sleepWakeProviderInode = sleepWakeProviderInode
    self.sleepWakeProviderDigest = sleepWakeProviderDigest
    self.signingIdentity = signingIdentity
    self.signingFingerprint = signingFingerprint
    self.certificateFingerprint = certificateFingerprint
    self.teamID = teamID
    self.createdAtUTC = createdAtUTC
  }

  public var boundaryBinding: Gate15BoundaryBinding {
    Gate15BoundaryBinding(
      sourceDigest: sourceDigest,
      configDigest: configDigest,
      toolchainDigest: toolchainDigest,
      dependencyEvidenceDigest: dependencyEvidenceDigest,
      executablePinsetDigest: executablePinsetDigest
    )
  }
}

public enum Gate15CanonicalRoot {
  public static let parent = "/Volumes/T9/hostwright/qualification"

  public static func isFixedT9Root(path: String, canonicalPath: String) -> Bool {
    path.hasPrefix(parent + "/")
      && canonicalPath == path
      && path.range(
        of: "^/Volumes/T9/hostwright/qualification/phase09-gate15-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$",
        options: .regularExpression
      ) != nil
  }
}

public enum Gate15CanonicalValidators {
  public static let dependency = "/Users/dev/Documents/hostwright-phase09/scripts/phase09-gate15-qualification.sh"
  public static let boundary = "/Users/dev/Documents/hostwright-phase09/scripts/phase09-gate15-live.sh"
}

public enum Gate15CanonicalTool {
  public static let path = "/Users/dev/Documents/hostwright-phase09/.build/release/HostwrightPhase09QualificationTool"
}

public enum Gate15ExecutableBindingIdentity {
  public static func value(path: String, device: UInt64, inode: UInt64, digest: String) -> String {
    "path=\(path);device=\(device);inode=\(inode);digest=\(digest)"
  }
}

private struct Gate15LaunchRequest: Codable {
  let schema: String
  let root: String
  let runnerPID: Int32
  let runnerStartIdentity: String
  let bootSessionID: String
  let nonce: String
  let requestedAtUTC: String
}

private struct Gate15RunStartedMarker: Codable {
  let schema: String
  let root: String
  let status: String
  let rootLockPath: String
  let rootLockDevice: UInt64
  let rootLockInode: UInt64
  let gateLockPath: String
  let gateLockDevice: UInt64
  let gateLockInode: UInt64
  let rootLockInfoPath: String
  let gateLockInfoPath: String
  let gateLockInfoDevice: UInt64
  let gateLockInfoInode: UInt64
  let runnerPID: Int32
  let runnerStartIdentity: String
  let sourceCommit: String
  let sourceDigest: String
  let configDigest: String
  let toolchainDigest: String
  let dependencyEvidenceDigest: String
  let executablePinsetDigest: String
  let manifestDigest: String
  let dependencyValidatorPath: String
  let dependencyValidatorDevice: UInt64
  let dependencyValidatorInode: UInt64
  let dependencyValidatorDigest: String
  let boundaryValidatorPath: String
  let boundaryValidatorDevice: UInt64
  let boundaryValidatorInode: UInt64
  let boundaryValidatorDigest: String
  let executablePinsetPath: String
  let executablePinsetDevice: UInt64
  let executablePinsetInode: UInt64
  let toolPath: String
  let toolDevice: UInt64
  let toolInode: UInt64
  let toolMode: UInt16
  let toolDigest: String
  let toolBuildIdentity: String
  let invocation: String
  let observationProviderPath: String
  let observationProviderDevice: UInt64
  let observationProviderInode: UInt64
  let observationProviderDigest: String
  let trustedObservationProviderPath: String
  let trustedObservationProviderDevice: UInt64
  let trustedObservationProviderInode: UInt64
  let trustedObservationProviderDigest: String
  let sleepWakeProviderPath: String
  let sleepWakeProviderDevice: UInt64
  let sleepWakeProviderInode: UInt64
  let sleepWakeProviderDigest: String
  let startedAtUTC: String
}

public protocol Gate15LaunchAuthorizationValidator {
  func consumeAndValidate(
    root: URL,
    runner: Gate15ProcessIdentity,
    reading: Gate15ClockReading
  ) throws -> Gate15LaunchAuthorization
}

public struct Gate15ContinuityLedger {
  public let contract: Gate15Contract
  public let ticksPerSecond: UInt64
  public let timebase: Gate15Timebase
  public private(set) var samples: [Gate15Sample] = []
  private var sleepWakeEventIDs = Set<String>()

  public init(
    contract: Gate15Contract = .frozen,
    ticksPerSecond: UInt64,
    timebase: Gate15Timebase? = nil
  ) throws {
    guard ticksPerSecond > 0 else {
      throw Gate15QualificationError("invalidClock", "ticksPerSecond must be positive.")
    }
    guard contract.intervalSeconds > 0, contract.requiredIntervals > 0,
          !contract.requiredSampleCountOverflowed,
          contract.requiredSampleCount < Int.max else {
      throw Gate15QualificationError("invalidContract", "duration, cadence, and requiredIntervals + 1 must be representable.")
    }
    self.contract = contract
    self.ticksPerSecond = ticksPerSecond
    if let timebase {
      self.timebase = timebase
    } else {
      self.timebase = try Gate15Timebase(numer: 1_000_000_000, denom: ticksPerSecond)
    }
  }

  @discardableResult
  public mutating func append(_ observation: Gate15Observation) throws -> Gate15Sample {
    try validateObservationShape(observation)
    var proposedSleepWakeEventIDs = sleepWakeEventIDs
    try validateGlobalSleepWakeEventIDs(observation.sleepWakeCoverage, into: &proposedSleepWakeEventIDs)
    let sequence = UInt64(samples.count)
    let previousHash = samples.last?.sampleSHA256
    let provisional = Gate15Sample(
      sequence: sequence,
      observation: observation,
      previousSampleSHA256: previousHash,
      sampleSHA256: ""
    )
    let sample = Gate15Sample(
      sequence: sequence,
      observation: observation,
      previousSampleSHA256: previousHash,
      sampleSHA256: try Gate15Sample.hash(for: provisional)
    )
    try validate(sample: sample, previous: samples.last)
    samples.append(sample)
    sleepWakeEventIDs = proposedSleepWakeEventIDs
    return sample
  }

  public func validatePersisted(_ persisted: [Gate15Sample]) throws {
    try validatePersisted(persisted, formal: false)
  }

  public func validatePersisted(_ persisted: [Gate15Sample], formal: Bool) throws {
    guard !persisted.isEmpty else {
      throw Gate15QualificationError("missingSample", "the append-only sample ledger is empty.")
    }
    var previous: Gate15Sample?
    var persistedSleepWakeEventIDs = Set<String>()
    for sample in persisted {
      try validateObservationShape(sample.observation, formal: formal)
      try validateGlobalSleepWakeEventIDs(sample.sleepWakeCoverage, into: &persistedSleepWakeEventIDs)
      guard sample.sampleSHA256 == (try Gate15Sample.hash(for: sample)) else {
        throw Gate15QualificationError("hashChainMismatch", "sample \(sample.sequence) has an invalid SHA-256.")
      }
      try validate(sample: sample, previous: previous, formal: formal)
      previous = sample
    }
  }

  public func validateComplete(formal: Bool = false) throws {
    try validatePersisted(samples, formal: formal)
    guard !contract.requiredSampleCountOverflowed else {
      throw Gate15QualificationError("invalidContract", "requiredIntervals + 1 overflowed the bounded sample count.")
    }
    guard samples.count == contract.requiredSampleCount else {
      throw Gate15QualificationError(
        "missingSample",
        "expected \(contract.requiredSampleCount) samples, found \(samples.count)."
      )
    }
    guard let first = samples.first, let last = samples.last else {
      throw Gate15QualificationError("missingSample", "the sample ledger is empty.")
    }
    let (elapsedTicks, elapsedOverflowed) = last.continuousTicks.subtractingReportingOverflow(first.continuousTicks)
    guard !elapsedOverflowed,
          try timebase.durationAtLeast(ticks: elapsedTicks, seconds: contract.durationSeconds) else {
      throw Gate15QualificationError("durationIncomplete", "continuous elapsed time is below the bounded 14400-second requirement.")
    }
    if formal && !contract.isFrozen() {
      throw Gate15QualificationError("contractMismatch", "formal qualification may use only the frozen Gate 15 contract.")
    }
  }

  public func finalLedgerDigest() throws -> String {
    try validateComplete(formal: true)
    var data = Data()
    for sample in samples {
      data.append(try sample.canonicalJSON())
      data.append(10)
    }
    return Gate15JSON.sha256Hex(data)
  }

  private func validateObservationShape(_ observation: Gate15Observation, formal: Bool = false) throws {
    guard observation.bootSessionID.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil,
          observation.observedAtUTC.count <= 40,
          observation.runner.pid > 0,
          observation.daemon.pid > 0,
          observation.runner.startIdentity.range(
            of: "^v1\\.[a-f0-9]{64}\\.[a-f0-9]{64}\\.[0-9]+\\.[0-9]+$",
            options: .regularExpression
          ) != nil,
          observation.daemon.startIdentity.range(
            of: "^v1\\.[a-f0-9]{64}\\.[a-f0-9]{64}\\.[0-9]+\\.[0-9]+$",
            options: .regularExpression
          ) != nil else {
      throw Gate15QualificationError("invalidIdentity", "process and boot identities must be present and bounded.")
    }
    guard observation.executable.sha256.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
          observation.executable.cdHash.range(of: "^[0-9a-f]{40}([0-9a-f]{24})?$", options: .regularExpression) != nil,
          observation.executable.teamID.range(of: "^[A-Za-z0-9]{1,32}$", options: .regularExpression) != nil,
          observation.executable.identifier.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
      throw Gate15QualificationError("invalidExecutableIdentity", "signed executable identity is not in the frozen bounded form.")
    }
    guard observation.stateDatabase.identityDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
          observation.stateDatabase.sizeBytes > 0,
          observation.stateDatabase.integrity == "verified",
          observation.stateDatabase.schema == UInt64(HostwrightContractVersions.stateSchema),
          observation.runtime.imageDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
          observation.runtime.inventoryDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
          !observation.runtime.runtimeUUID.contains("/"),
          observation.runtime.project.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
      throw Gate15QualificationError("invalidRuntimeIdentity", "state and runtime identities are incomplete or unsafe.")
    }
    guard observation.fault.recoveryWithinBound,
          !observation.fault.scheduledMarker.contains("\n"),
          !observation.fault.recoveryResult.contains("\n") else {
      throw Gate15QualificationError("faultRecoveryUnbounded", "fault recovery evidence is missing or unbounded.")
    }
    if formal {
      guard let binding = observation.boundaryBinding,
            isDigest(binding.sourceDigest),
            isDigest(binding.configDigest),
            isDigest(binding.toolchainDigest),
            isDigest(binding.dependencyEvidenceDigest),
            isDigest(binding.executablePinsetDigest) else {
        throw Gate15QualificationError("boundaryBindingMissing", "formal samples must bind every immutable dependency digest.")
      }
      guard let receipt = observation.independentReceipt else {
        throw Gate15QualificationError("independentReceiptMissing", "formal samples must carry the independently captured live-wrapper observation receipt.")
      }
      try validateIndependentReceipt(receipt, observation: observation)
      try validateSleepWakeIntervals(observation.sleepWakeCoverage, formal: true)
    }
  }

  private func validateIndependentReceipt(
    _ receipt: Gate15IndependentObservationReceipt,
    observation: Gate15Observation
  ) throws {
    guard receipt.source == Gate15IndependentObservationReceipt.authenticatedSource,
          receipt.observerIdentity.range(of: "^macos-system-observer-v1:[A-Za-z0-9._:-]{1,256}$", options: .regularExpression) != nil,
          receipt.inventoryDigest == observation.runtime.inventoryDigest,
          receipt.daemonStateDigest == observation.stateDatabase.identityDigest,
          receipt.executableIdentityDigest == observation.executable.sha256,
          receipt.executableReceiptDigest == (try Gate15ObservationReceiptDigests.executable(observation)),
          receipt.daemonReceiptDigest == (try Gate15ObservationReceiptDigests.daemon(observation)),
          receipt.stateReceiptDigest == (try Gate15ObservationReceiptDigests.state(observation)),
          receipt.containerReceiptDigest == (try Gate15ObservationReceiptDigests.container(observation)),
          receipt.runtimeReceiptDigest == (try Gate15ObservationReceiptDigests.runtime(observation)),
          receipt.receiptDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
          receipt.authorizationDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
          receipt.receiptDigest == (try receipt.receiptDigestValue()) else {
      throw Gate15QualificationError("independentReceiptInvalid", "the formal sample observation receipt does not exactly digest the executable, daemon, state, container, and runtime fields.")
    }
  }

  private func validate(sample: Gate15Sample, previous: Gate15Sample?, formal: Bool = false) throws {
    let expectedSequence: UInt64
    if let previous {
      guard previous.sequence < UInt64.max else {
        throw Gate15QualificationError("missingSample", "sample sequence overflowed the bounded ledger.")
      }
      expectedSequence = previous.sequence + 1
    } else {
      expectedSequence = 0
    }
    guard sample.sequence == expectedSequence else {
      throw Gate15QualificationError("missingSample", "sample sequence is not contiguous.")
    }
    if let previous {
      guard sample.previousSampleSHA256 == previous.sampleSHA256 else {
        throw Gate15QualificationError("hashChainMismatch", "sample chain does not reference the immediately previous sample.")
      }
      guard sample.bootSessionID == previous.bootSessionID else {
        throw Gate15QualificationError("bootSessionChanged", "boot-session identity changed during the run.")
      }
      guard sample.runner == previous.runner else {
        throw Gate15QualificationError("runnerReplaced", "the Gate 15 runner process identity changed.")
      }
      let previousDate = try parseUTC(previous.observedAtUTC)
      let currentDate = try parseUTC(sample.observedAtUTC)
      guard currentDate >= previousDate else {
        throw Gate15QualificationError("wallClockRollback", "wall-clock UTC moved backwards.")
      }
      guard sample.continuousTicks > previous.continuousTicks else {
        throw Gate15QualificationError("continuousTimeRegression", "mach_continuous_time regressed or stopped.")
      }
      try validateDaemonTransition(previous: previous, current: sample)
      try validateCadence(previous: previous, current: sample, formal: formal)
    } else {
      guard sample.previousSampleSHA256 == nil else {
        throw Gate15QualificationError("hashChainMismatch", "the initial sample cannot reference a previous sample.")
      }
      _ = try parseUTC(sample.observedAtUTC)
    }
  }

  private func validateDaemonTransition(previous: Gate15Sample, current: Gate15Sample) throws {
    guard current.daemon != previous.daemon else {
      guard !current.fault.plannedDaemonRestart, current.fault.daemonRestart == nil else {
        throw Gate15QualificationError("unexpectedDaemonTransition", "a restart marker was recorded without a daemon identity transition.")
      }
      return
    }
    guard current.fault.plannedDaemonRestart,
          let restart = current.fault.daemonRestart,
          restart.previous == previous.daemon,
          restart.current == current.daemon,
          previous.daemon.generation < UInt64.max,
          current.daemon.generation == previous.daemon.generation + 1,
          restart.recoveryWithinBound,
          current.fault.recoveryWithinBound else {
      throw Gate15QualificationError("unexpectedDaemonReplacement", "daemon replacement was not a planned bounded fault point.")
    }
  }

  private func validateCadence(previous: Gate15Sample, current: Gate15Sample, formal: Bool) throws {
    let (deltaTicks, deltaOverflowed) = current.continuousTicks.subtractingReportingOverflow(previous.continuousTicks)
    guard !deltaOverflowed else {
      throw Gate15QualificationError("continuousTimeRegression", "mach_continuous_time regressed or overflowed.")
    }
    let lowerSeconds = max(
      UInt64(1),
      contract.intervalSeconds > contract.awakeToleranceSeconds
        ? contract.intervalSeconds - contract.awakeToleranceSeconds
        : 0
    )
    let (upperSeconds, upperOverflowed) = contract.intervalSeconds.addingReportingOverflow(contract.awakeToleranceSeconds)
    guard !upperOverflowed else {
      throw Gate15QualificationError("clockOverflow", "the frozen cadence upper bound overflowed.")
    }
    let lowerTicks = try timebase.ticks(forSeconds: lowerSeconds)
    let upperTicks = try timebase.ticks(forSeconds: upperSeconds)
    if deltaTicks < lowerTicks {
      throw Gate15QualificationError("sampleTooEarly", "sample cadence is earlier than the frozen awake tolerance.")
    }
    if deltaTicks <= upperTicks {
      guard current.sleepWakeCoverage.isEmpty else {
        throw Gate15QualificationError("sleepCoverageInvalid", "sleep/wake coverage is present without an extended sample interval.")
      }
      return
    }

    guard !current.sleepWakeCoverage.isEmpty else {
      throw Gate15QualificationError("awakeCadenceViolation", "an extended interval lacks exact ordered sleep/wake coverage.")
    }
    try validateSleepWakeIntervals(current.sleepWakeCoverage, formal: formal)
    var previousEnd: UInt64?
    var previousWakeDate: Date?
    var coveredTicks: UInt64 = 0
    let previousDate = try parseUTC(previous.observedAtUTC)
    let currentDate = try parseUTC(current.observedAtUTC)
    for interval in current.sleepWakeCoverage {
      if let previousEnd {
        guard interval.continuousStartTicks == previousEnd else {
          throw Gate15QualificationError("sleepCoverageInvalid", "sleep/wake coverage has a gap or overlap.")
        }
      }
      let sleepDate = try parseUTC(interval.sleepStartUTC)
      let wakeDate = try parseUTC(interval.wakeUTC)
      guard interval.continuousStartTicks >= previous.continuousTicks,
            interval.continuousEndTicks <= current.continuousTicks,
            sleepDate > previousDate,
            formal ? wakeDate < currentDate : wakeDate <= currentDate,
            wakeDate > sleepDate else {
        throw Gate15QualificationError("sleepCoverageInvalid", "sleep/wake coverage is outside the sample interval.")
      }
      if let previousWakeDate {
        guard sleepDate >= previousWakeDate else {
          throw Gate15QualificationError("sleepCoverageInvalid", "sleep/wake timestamps are not ordered.")
        }
      }
      let (intervalTicks, intervalUnderflowed) = interval.continuousEndTicks.subtractingReportingOverflow(interval.continuousStartTicks)
      guard !intervalUnderflowed, intervalTicks > 0 else {
        throw Gate15QualificationError("sleepCoverageInvalid", "sleep/wake coverage has a non-positive interval.")
      }
      let (newCoveredTicks, overflowed) = coveredTicks.addingReportingOverflow(intervalTicks)
      guard !overflowed else {
        throw Gate15QualificationError("sleepCoverageInvalid", "sleep/wake coverage overflowed the bounded ledger.")
      }
      coveredTicks = newCoveredTicks
      previousEnd = interval.continuousEndTicks
      previousWakeDate = wakeDate
    }
    let scheduledTicks = try timebase.ticks(forSeconds: contract.intervalSeconds)
    guard deltaTicks >= scheduledTicks else {
      throw Gate15QualificationError("sleepCoverageInvalid", "the extended interval is shorter than its frozen cadence.")
    }
    let (expectedExtraTicks, expectedUnderflowed) = deltaTicks.subtractingReportingOverflow(scheduledTicks)
    guard !expectedUnderflowed else {
      throw Gate15QualificationError("sleepCoverageInvalid", "sleep/wake coverage underflowed its expected interval.")
    }
    guard coveredTicks == expectedExtraTicks else {
      throw Gate15QualificationError("sleepCoverageInvalid", "sleep/wake coverage does not exactly account for the extended interval.")
    }
  }

  private func validateSleepWakeIntervals(_ intervals: [Gate15SleepWakeInterval], formal: Bool) throws {
    var seen = Set<String>()
    for interval in intervals {
      guard interval.continuousEndTicks > interval.continuousStartTicks,
            interval.sleepEventID.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil,
            interval.wakeEventID.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil,
            seen.insert(interval.sleepEventID).inserted,
            seen.insert(interval.wakeEventID).inserted else {
        throw Gate15QualificationError("sleepCoverageInvalid", "sleep/wake events are duplicated or malformed.")
      }
      if formal {
        guard interval.source == Gate15SleepWakeEvent.authenticatedSource,
              interval.observerIdentity.range(of: "^macos-system-observer-v1:[A-Za-z0-9._:-]{1,256}$", options: .regularExpression) != nil,
              interval.sleepObserverReceiptDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
              interval.wakeObserverReceiptDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
              interval.sleepObserverReceiptDigest == (try interval.observerReceiptDigestValue(kind: "sleep")),
              interval.wakeObserverReceiptDigest == (try interval.observerReceiptDigestValue(kind: "wake")),
              interval.authenticationDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
              interval.authenticationDigest == (try interval.authenticationDigestValue()) else {
          throw Gate15QualificationError("sleepEventUnauthenticated", "formal sleep/wake coverage must use OS-generated observer receipts, not provider self-attestation or backfill.")
        }
      }
    }
  }

  private func validateGlobalSleepWakeEventIDs(
    _ intervals: [Gate15SleepWakeInterval],
    into seen: inout Set<String>
  ) throws {
    for interval in intervals {
      for eventID in [interval.sleepEventID, interval.wakeEventID] {
        guard eventID.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil,
              seen.insert(eventID).inserted else {
          throw Gate15QualificationError("sleepCoverageInvalid", "sleep/wake event IDs must be globally unique across the complete ledger.")
        }
      }
    }
  }

  private func isDigest(_ value: String) -> Bool {
    value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
  }

  private func parseUTC(_ value: String) throws -> Date {
    guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$", options: .regularExpression) != nil else {
      throw Gate15QualificationError("invalidTimestamp", "timestamp must be canonical UTC RFC3339 with a Z endpoint.")
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
      throw Gate15QualificationError("invalidTimestamp", "timestamp is not canonical UTC RFC3339.")
    }
    return date
  }
}

public struct Gate15RunResult: Codable, Equatable, Sendable {
  public let status: String
  public let claim: String
  public let sampleCount: Int
  public let elapsedSeconds: UInt64

  public init(status: String, claim: String, sampleCount: Int, elapsedSeconds: UInt64) {
    self.status = status
    self.claim = claim
    self.sampleCount = sampleCount
    self.elapsedSeconds = elapsedSeconds
  }
}

public final class Gate15QualificationRunner {
  private let root: URL
  private let contract: Gate15Contract
  private let clock: Gate15Clock
  private let identities: Gate15ProcessIdentityProvider
  private let observations: Gate15ObservationProvider
  private let trustedObservations: Gate15TrustedObservationProvider?
  private let boundaryValidator: Gate15BoundaryValidator?
  private let dependencyValidator: Gate15DependencyValidator?
  private let sleepWakeProvider: Gate15SleepWakeEventProvider?
  private let launchAuthorizationValidator: Gate15LaunchAuthorizationValidator?
  private let testing: Bool
  private var sleepWakeEventIDs = Set<String>()

  public init(
    root: URL,
    contract: Gate15Contract = .frozen,
    clock: Gate15Clock,
    identities: Gate15ProcessIdentityProvider,
    observations: Gate15ObservationProvider,
    boundaryValidator: Gate15BoundaryValidator? = nil,
    dependencyValidator: Gate15DependencyValidator? = nil,
    sleepWakeProvider: Gate15SleepWakeEventProvider? = nil,
    launchAuthorizationValidator: Gate15LaunchAuthorizationValidator? = nil,
    trustedObservations: Gate15TrustedObservationProvider? = nil,
    testing: Bool = false
  ) {
    self.root = root
    self.contract = contract
    self.clock = clock
    self.identities = identities
    self.observations = observations
    self.trustedObservations = trustedObservations
    self.boundaryValidator = boundaryValidator
    self.dependencyValidator = dependencyValidator
    self.sleepWakeProvider = sleepWakeProvider
    self.launchAuthorizationValidator = launchAuthorizationValidator
    self.testing = testing
  }

  public func run() throws -> Gate15RunResult {
    sleepWakeEventIDs.removeAll(keepingCapacity: true)
    guard !testing else {
      throw Gate15QualificationError("testModeCannotQualify", "test mode cannot manufacture or claim a formal bounded Gate 15 passage.")
    }
    guard contract.isFrozen() else {
      throw Gate15QualificationError("contractMismatch", "formal Gate 15 runs require the frozen contract.")
    }
    try validateRoot()
    let runner = try identities.current()
    let initialReading = try clock.reading()
    guard let launchAuthorizationValidator else {
      throw Gate15QualificationError("missingLaunchAuthorization", "formal Swift runs require a one-time shell-created CMS launch authorization.")
    }
    guard let dependencyValidator else {
      throw Gate15QualificationError("missingDependencyValidator", "formal Swift runs require immutable dependency revalidation.")
    }
    guard let boundaryValidator else {
      throw Gate15QualificationError("missingBoundaryValidator", "formal Swift runs require live-boundary revalidation.")
    }
    guard let sleepWakeProvider else {
      throw Gate15QualificationError("missingSleepWakeProvider", "formal Swift runs require authenticated ordered macOS sleep/wake events.")
    }
    guard let trustedObservations else {
      throw Gate15QualificationError("missingTrustedObservationProvider", "formal Swift runs require an independently captured live-wrapper observation for every sample.")
    }
    let authorization = try launchAuthorizationValidator.consumeAndValidate(
      root: root,
      runner: runner,
      reading: initialReading
    )
    guard let authorizedObservationProvider = observations as? Gate15AuthorizedExecutableBinding,
          let authorizedTrustedObservationProvider = trustedObservations as? Gate15AuthorizedExecutableBinding,
          let authorizedSleepWakeProvider = sleepWakeProvider as? Gate15AuthorizedExecutableBinding else {
      throw Gate15QualificationError("providerBindingMissing", "formal observation and sleep/wake providers must implement signed executable binding.")
    }
    try authorizedObservationProvider.validateAuthorizedExecutable(for: authorization)
    try authorizedTrustedObservationProvider.validateAuthorizedExecutable(for: authorization)
    try authorizedSleepWakeProvider.validateAuthorizedExecutable(for: authorization)
    try dependencyValidator.bind(to: authorization)
    try boundaryValidator.bind(to: authorization)
    try validateRunBinding(authorization: authorization, runner: runner)
    try dependencyValidator.validate()
    try boundaryValidator.validate()
    let initialTrustedObservation = try trustedObservations.trustedObservation(for: initialReading, runner: runner)
    let initialObservation = try observations.observation(for: initialReading, runner: runner)
    let boundInitialObservation = try bind(
      initialObservation,
      trustedObservation: initialTrustedObservation,
      reading: initialReading,
      runner: runner,
      authorization: authorization,
      events: [],
      startReading: initialReading
    )
    let timebase = (clock as? Gate15RationalClock)?.timebase
    var ledger = try Gate15ContinuityLedger(
      contract: contract,
      ticksPerSecond: clock.ticksPerSecond,
      timebase: timebase
    )
    try append(sample: ledger.append(boundInitialObservation))
    try validateRunBinding(authorization: authorization, runner: runner)
    try dependencyValidator.validate()
    try boundaryValidator.validate()
    let startTicks = initialReading.continuousTicks
    try writeState(
      status: "running",
      runner: runner,
      startTicks: startTicks,
      sampleCount: ledger.samples.count,
      authorization: authorization,
      ledger: ledger
    )

    var previousReading = initialReading
    while ledger.samples.count < contract.requiredSampleCount {
      try validateRunBinding(authorization: authorization, runner: runner)
      try dependencyValidator.validate()
      try boundaryValidator.validate()
      let sequence = UInt64(ledger.samples.count)
      let intervalTicks = try ledger.timebase.ticks(forSeconds: contract.intervalSeconds)
      let (sequenceTicks, sequenceOverflowed) = sequence.multipliedReportingOverflow(by: intervalTicks)
      guard !sequenceOverflowed else {
        throw Gate15QualificationError("clockOverflow", "the sample target overflowed the continuous-time tick range.")
      }
      let (target, targetOverflowed) = startTicks.addingReportingOverflow(sequenceTicks)
      guard !targetOverflowed else {
        throw Gate15QualificationError("clockOverflow", "the sample target exceeded the continuous-time tick range.")
      }
      try clock.wait(until: target)
      let identity = try identities.current()
      guard identity == runner else {
        throw Gate15QualificationError("runnerReplaced", "the qualifying runner process was replaced.")
      }
      let reading = try clock.reading()
      guard reading.bootSessionID == initialReading.bootSessionID else {
        throw Gate15QualificationError("bootSessionChanged", "boot-session identity changed during qualification.")
      }
      let trustedObservation = try trustedObservations.trustedObservation(for: reading, runner: runner)
      let rawObservation = try observations.observation(for: reading, runner: runner)
      let events = try sleepWakeProvider.events(from: previousReading, to: reading)
      let observation = try bind(
        rawObservation,
        trustedObservation: trustedObservation,
        reading: reading,
        runner: runner,
        authorization: authorization,
        events: events,
        startReading: previousReading
      )
      try append(sample: ledger.append(observation))
      previousReading = reading
      try validateRunBinding(authorization: authorization, runner: runner)
      try dependencyValidator.validate()
      try boundaryValidator.validate()
      try writeState(
        status: "running",
        runner: runner,
        startTicks: startTicks,
        sampleCount: ledger.samples.count,
        authorization: authorization,
        ledger: ledger
      )
    }
    guard try identities.current() == runner else {
      throw Gate15QualificationError("runnerReplaced", "the qualifying runner process changed before finalization.")
    }
    try validateRunBinding(authorization: authorization, runner: runner)
    try dependencyValidator.validate()
    try boundaryValidator.validate()
    let persisted = try loadPersistedSamples()
    try ledger.validatePersisted(persisted)
    guard persisted == ledger.samples else {
      throw Gate15QualificationError("hashChainMismatch", "the append-only sample ledger changed during qualification.")
    }
    try ledger.validateComplete(formal: true)
    guard let first = ledger.samples.first, let last = ledger.samples.last else {
      throw Gate15QualificationError("missingSample", "the completed sample ledger is empty.")
    }
    let (elapsedTicks, elapsedOverflowed) = last.continuousTicks.subtractingReportingOverflow(first.continuousTicks)
    guard !elapsedOverflowed else {
      throw Gate15QualificationError("clockOverflow", "final elapsed ticks overflowed.")
    }
    let finalLedgerDigest = try ledger.finalLedgerDigest()
    try writeState(
      status: "finalizing",
      runner: runner,
      startTicks: startTicks,
      sampleCount: ledger.samples.count,
      authorization: authorization,
      ledger: ledger,
      finalLedgerDigest: finalLedgerDigest
    )
    try validateRunBinding(authorization: authorization, runner: runner)
    return Gate15RunResult(
      status: "finalizing",
      claim: "pre-pass",
      sampleCount: ledger.samples.count,
      elapsedSeconds: try ledger.timebase.durationSecondsFloor(ticks: elapsedTicks)
    )
  }

  private func validateRunBinding(
    authorization: Gate15LaunchAuthorization,
    runner: Gate15ProcessIdentity
  ) throws {
    try Gate15RunBinding.validate(root: root, authorization: authorization, runner: runner)
  }

  private func bind(
    _ observation: Gate15Observation,
    trustedObservation: Gate15TrustedObservation,
    reading: Gate15ClockReading,
    runner: Gate15ProcessIdentity,
    authorization: Gate15LaunchAuthorization,
    events: [Gate15SleepWakeEvent],
    startReading: Gate15ClockReading
  ) throws -> Gate15Observation {
    try Gate15ObservationBinding.validate(
      provider: observation,
      trusted: trustedObservation,
      reading: reading,
      runner: runner,
      expectedBoundaryBinding: authorization.boundaryBinding,
      providerIdentity: Gate15ExecutableBindingIdentity.value(
        path: authorization.observationProviderPath,
        device: authorization.observationProviderDevice,
        inode: authorization.observationProviderInode,
        digest: authorization.observationProviderDigest
      ),
      toolIdentity: Gate15ExecutableBindingIdentity.value(
        path: authorization.toolPath,
        device: authorization.toolDevice,
        inode: authorization.toolInode,
        digest: authorization.toolDigest
      )
    )
    let coverage = try makeCoverage(
      events: events,
      start: startReading,
      end: reading,
      disallowedObserverIdentities: [
        Gate15ExecutableBindingIdentity.value(
          path: authorization.sleepWakeProviderPath,
          device: authorization.sleepWakeProviderDevice,
          inode: authorization.sleepWakeProviderInode,
          digest: authorization.sleepWakeProviderDigest
        ),
        Gate15ExecutableBindingIdentity.value(
          path: authorization.toolPath,
          device: authorization.toolDevice,
          inode: authorization.toolInode,
          digest: authorization.toolDigest
        )
      ]
    )
    return observation.with(
      sleepWakeCoverage: coverage,
      boundaryBinding: authorization.boundaryBinding,
      independentReceipt: trustedObservation.receipt
    )
  }

  private func makeCoverage(
    events: [Gate15SleepWakeEvent],
    start: Gate15ClockReading,
    end: Gate15ClockReading,
    disallowedObserverIdentities: [String]
  ) throws -> [Gate15SleepWakeInterval] {
    guard events.isEmpty || events.count.isMultiple(of: 2) else {
      throw Gate15QualificationError("sleepEventOrdering", "macOS sleep/wake events must arrive as ordered pairs.")
    }
    var intervals: [Gate15SleepWakeInterval] = []
    var previousEventTicks = start.continuousTicks
    var seen = Set<String>()
    for pairStart in stride(from: 0, to: events.count, by: 2) {
      let sleep = events[pairStart]
      let wake = events[pairStart + 1]
      guard sleep.kind == "sleep", wake.kind == "wake",
            sleep.source == Gate15SleepWakeEvent.authenticatedSource,
            wake.source == Gate15SleepWakeEvent.authenticatedSource,
            sleep.observerIdentity == wake.observerIdentity,
            !disallowedObserverIdentities.contains(sleep.observerIdentity),
            sleep.observerReceiptDigest == (try sleep.observerReceiptDigestValue()),
            wake.observerReceiptDigest == (try wake.observerReceiptDigestValue()),
            sleep.bootSessionID == start.bootSessionID,
            wake.bootSessionID == start.bootSessionID,
            sleep.continuousTicks > previousEventTicks,
            wake.continuousTicks > sleep.continuousTicks,
            wake.continuousTicks <= end.continuousTicks,
            seen.insert(sleep.eventID).inserted,
            seen.insert(wake.eventID).inserted,
            sleepWakeEventIDs.insert(sleep.eventID).inserted,
            sleepWakeEventIDs.insert(wake.eventID).inserted,
            sleep.authenticationDigest == (try sleep.authenticationDigestValue()),
            wake.authenticationDigest == (try wake.authenticationDigestValue()) else {
        throw Gate15QualificationError("sleepEventUnauthenticated", "ordered sleep/wake events failed source, tick, boot, or proof validation.")
      }
      let unsignedInterval = Gate15SleepWakeInterval(
        sleepStartUTC: sleep.observedAtUTC,
        wakeUTC: wake.observedAtUTC,
        continuousStartTicks: sleep.continuousTicks,
        continuousEndTicks: wake.continuousTicks,
        sleepEventID: sleep.eventID,
        wakeEventID: wake.eventID,
        source: Gate15SleepWakeEvent.authenticatedSource,
        observerIdentity: sleep.observerIdentity,
        sleepObserverReceiptDigest: sleep.observerReceiptDigest,
        wakeObserverReceiptDigest: wake.observerReceiptDigest,
        authenticationDigest: ""
      )
      let authenticationDigest = try unsignedInterval.authenticationDigestValue()
      intervals.append(Gate15SleepWakeInterval(
        sleepStartUTC: unsignedInterval.sleepStartUTC,
        wakeUTC: unsignedInterval.wakeUTC,
        continuousStartTicks: unsignedInterval.continuousStartTicks,
        continuousEndTicks: unsignedInterval.continuousEndTicks,
        sleepEventID: unsignedInterval.sleepEventID,
        wakeEventID: unsignedInterval.wakeEventID,
        source: unsignedInterval.source,
        observerIdentity: unsignedInterval.observerIdentity,
        sleepObserverReceiptDigest: unsignedInterval.sleepObserverReceiptDigest,
        wakeObserverReceiptDigest: unsignedInterval.wakeObserverReceiptDigest,
        authenticationDigest: authenticationDigest
      ))
      previousEventTicks = wake.continuousTicks
    }
    return intervals
  }

  private func append(sample: Gate15Sample) throws {
    let path = root.appendingPathComponent("samples-v1.ndjson").path
    var information = stat()
    let descriptor: Int32
    if lstat(path, &information) == 0 {
      guard (information.st_mode & S_IFMT) == S_IFREG,
            information.st_uid == getuid(),
            information.st_nlink == 1,
            (information.st_mode & 0o777) == 0o600 else {
        throw Gate15QualificationError("evidenceWriteFailed", "the append-only sample ledger is not a private regular file.")
      }
      descriptor = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW)
    } else if errno == ENOENT {
      descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    } else {
      throw Gate15QualificationError("evidenceWriteFailed", "could not inspect the append-only sample ledger.")
    }
    guard descriptor >= 0 else {
      throw Gate15QualificationError("evidenceWriteFailed", "could not open the append-only sample ledger.")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    try handle.write(contentsOf: sample.canonicalJSON() + Data([10]))
    try handle.synchronize()
  }

  private func loadPersistedSamples() throws -> [Gate15Sample] {
    let path = root.appendingPathComponent("samples-v1.ndjson").path
    try Gate15FileIdentity.requirePrivateFile(path, mode: 0o600, code: "evidenceReadFailed")
    guard let data = FileManager.default.contents(atPath: path), data.last == 10 else {
      throw Gate15QualificationError("evidenceReadFailed", "the append-only sample ledger is incomplete.")
    }
    let lines = data.split(separator: 10, omittingEmptySubsequences: false)
    guard lines.last?.isEmpty == true else {
      throw Gate15QualificationError("evidenceReadFailed", "the append-only sample ledger is not newline terminated.")
    }
    var samples: [Gate15Sample] = []
    samples.reserveCapacity(lines.count - 1)
    for line in lines.dropLast() {
      guard !line.isEmpty else {
        throw Gate15QualificationError("evidenceReadFailed", "the append-only sample ledger contains a blank record.")
      }
      do {
        let lineData = Data(line)
        let sample = try Gate15JSON.decoder.decode(Gate15Sample.self, from: lineData)
        guard try sample.canonicalJSON() == lineData else {
          throw Gate15QualificationError("evidenceReadFailed", "the append-only sample ledger is not canonical JSON.")
        }
        samples.append(sample)
      } catch let error as Gate15QualificationError {
        throw error
      } catch {
        throw Gate15QualificationError("evidenceReadFailed", "the append-only sample ledger contains invalid JSON.")
      }
    }
    return samples
  }

  private func writeState(
    status: String,
    runner: Gate15ProcessIdentity,
    startTicks: UInt64,
    sampleCount: Int,
    authorization: Gate15LaunchAuthorization,
    ledger: Gate15ContinuityLedger? = nil,
    finalLedgerDigest: String = ""
  ) throws {
    let state: [String: Any] = [
      "schema": "hostwright.phase09.gate15.runner-state.v1",
      "status": status,
      "runnerPID": runner.pid,
      "runnerStartIdentity": runner.startIdentity,
      "bootSessionID": authorization.bootSessionID,
      "root": authorization.root,
      "rootLockPath": authorization.rootLockPath,
      "rootLockDevice": authorization.rootLockDevice,
      "rootLockInode": authorization.rootLockInode,
      "gateLockPath": authorization.gateLockPath,
      "gateLockDevice": authorization.gateLockDevice,
      "gateLockInode": authorization.gateLockInode,
      "rootLockInfoPath": root.appendingPathComponent("gate-active-run-v1-info.tsv").path,
      "gateLockInfoPath": root.deletingLastPathComponent().appendingPathComponent(".phase09-gate15-active-v1/info-v1.tsv").path,
      "sourceCommit": authorization.sourceCommit,
      "sourceDigest": authorization.sourceDigest,
      "configDigest": authorization.configDigest,
      "toolchainDigest": authorization.toolchainDigest,
      "dependencyEvidenceDigest": authorization.dependencyEvidenceDigest,
      "executablePinsetDigest": authorization.executablePinsetDigest,
      "dependencyValidatorPath": authorization.dependencyValidatorPath,
      "dependencyValidatorDevice": authorization.dependencyValidatorDevice,
      "dependencyValidatorInode": authorization.dependencyValidatorInode,
      "dependencyValidatorDigest": authorization.dependencyValidatorDigest,
      "boundaryValidatorPath": authorization.boundaryValidatorPath,
      "boundaryValidatorDevice": authorization.boundaryValidatorDevice,
      "boundaryValidatorInode": authorization.boundaryValidatorInode,
      "boundaryValidatorDigest": authorization.boundaryValidatorDigest,
      "executablePinsetPath": authorization.executablePinsetPath,
      "executablePinsetDevice": authorization.executablePinsetDevice,
      "executablePinsetInode": authorization.executablePinsetInode,
      "runStartedDigest": authorization.runStartedDigest,
      "manifestDigest": authorization.manifestDigest,
      "toolPath": authorization.toolPath,
      "toolDevice": authorization.toolDevice,
      "toolInode": authorization.toolInode,
      "toolMode": authorization.toolMode,
      "toolDigest": authorization.toolDigest,
      "toolBuildIdentity": authorization.toolBuildIdentity,
      "invocation": authorization.invocation,
      "observationProviderPath": authorization.observationProviderPath,
      "observationProviderDevice": authorization.observationProviderDevice,
      "observationProviderInode": authorization.observationProviderInode,
      "observationProviderDigest": authorization.observationProviderDigest,
      "trustedObservationProviderPath": authorization.trustedObservationProviderPath,
      "trustedObservationProviderDevice": authorization.trustedObservationProviderDevice,
      "trustedObservationProviderInode": authorization.trustedObservationProviderInode,
      "trustedObservationProviderDigest": authorization.trustedObservationProviderDigest,
      "sleepWakeProviderPath": authorization.sleepWakeProviderPath,
      "sleepWakeProviderDevice": authorization.sleepWakeProviderDevice,
      "sleepWakeProviderInode": authorization.sleepWakeProviderInode,
      "sleepWakeProviderDigest": authorization.sleepWakeProviderDigest,
      "launchNonce": authorization.nonce,
      "startContinuousTicks": startTicks,
      "sampleCount": sampleCount,
      "timebaseNumer": ledger?.timebase.numer ?? 0,
      "timebaseDenom": ledger?.timebase.denom ?? 0,
      "finalLedgerDigest": finalLedgerDigest,
      "updatedAtUTC": Gate15JSON.utcNow()
    ]
    let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    let destination = root.appendingPathComponent("runner-state-v1.json")
    try Gate15FileIdentity.writePrivateAtomically(data: data, to: destination.path, code: "evidenceWriteFailed")
  }

  private func validateRoot() throws {
    var statBuffer = stat()
    let canonicalRoot = Gate15FileIdentity.canonical(root.path)
    guard lstat(root.path, &statBuffer) == 0,
          (statBuffer.st_mode & S_IFMT) == S_IFDIR,
          (statBuffer.st_mode & 0o777) == 0o700,
          statBuffer.st_uid == getuid(),
          Gate15CanonicalRoot.isFixedT9Root(path: root.path, canonicalPath: canonicalRoot) else {
      throw Gate15QualificationError("unsafeRoot", "Gate 15 root must be a current-user-owned mode-0700 directory.")
    }
    guard !Gate15FileIdentity.existsOrSymlink(root.appendingPathComponent("evidence-v1.cms").path) else {
      throw Gate15QualificationError("rootAlreadyCompleted", "a completed root is immutable and cannot be rerun.")
    }
    guard !Gate15FileIdentity.existsOrSymlink(root.appendingPathComponent("samples-v1.ndjson").path) else {
      throw Gate15QualificationError("elapsedResumeForbidden", "a root with samples has already started and cannot be resumed.")
    }
    guard !Gate15FileIdentity.existsOrSymlink(root.appendingPathComponent("runner-state-v1.json").path) else {
      throw Gate15QualificationError("elapsedResumeForbidden", "a root with runner state has already started and cannot be resumed.")
    }
  }
}

public struct Gate15MachContinuousClock: Gate15RationalClock {
  public let ticksPerSecond: UInt64
  public let timebase: Gate15Timebase

  public init() throws {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0, timebase.denom > 0 else {
      throw Gate15QualificationError("clockUnavailable", "mach_continuous_time timebase is unavailable.")
    }
    self.timebase = try Gate15Timebase(numer: UInt64(timebase.numer), denom: UInt64(timebase.denom))
    let ticks = try self.timebase.ticks(forSeconds: 1)
    guard ticks > 0 else {
      throw Gate15QualificationError("clockUnavailable", "mach_continuous_time has an unusable timebase.")
    }
    ticksPerSecond = ticks
  }

  public func reading() throws -> Gate15ClockReading {
    Gate15ClockReading(
      continuousTicks: mach_continuous_time(),
      wallClockUTC: Gate15JSON.utcNow(),
      bootSessionID: try Gate15SystemIdentity.bootSessionID()
    )
  }

  public func wait(until ticks: UInt64) throws {
    while true {
      let current = mach_continuous_time()
      guard current < ticks else { return }
      let (remaining, underflowed) = ticks.subtractingReportingOverflow(current)
      guard !underflowed else {
        throw Gate15QualificationError("clockOverflow", "continuous-time wait target regressed.")
      }
      let nanoseconds = try timebase.nanoseconds(forTicks: remaining)
      let seconds = Double(nanoseconds) / 1_000_000_000
      Thread.sleep(forTimeInterval: min(max(seconds, 0.001), 60.0))
    }
  }
}

public struct Gate15SystemProcessIdentityProvider: Gate15ProcessIdentityProvider {
  public init() {}

  public func current() throws -> Gate15ProcessIdentity {
    try lookup(pid: getpid())
  }

  public func lookup(pid: Int32) throws -> Gate15ProcessIdentity {
    let identity: HostwrightDarwinProcessIdentity
    do {
      identity = try HostwrightDarwinProcessIdentity.lookup(processID: pid)
    } catch {
      throw Gate15QualificationError("processIdentityUnavailable", "the process start identity is unavailable.")
    }
    return Gate15ProcessIdentity(
      pid: pid,
      startIdentity: identity.strongIdentity
    )
  }
}

public struct Gate15CommandObservationProvider: Gate15ObservationProvider, Gate15AuthorizedExecutableBinding {
  public let executable: URL
  public let timeoutSeconds: TimeInterval
  public let expectedBoundaryBinding: Gate15BoundaryBinding?

  public init(
    executable: URL,
    timeoutSeconds: TimeInterval = 20,
    expectedBoundaryBinding: Gate15BoundaryBinding? = nil
  ) throws {
    guard executable.path.hasPrefix("/"), !executable.path.contains("\n"), executable.isFileURL else {
      throw Gate15QualificationError("unsafeProvider", "the observation provider must be an absolute file URL.")
    }
    try Gate15FileIdentity.requireExecutable(executable.path, code: "unsafeProvider")
    self.executable = executable
    self.timeoutSeconds = timeoutSeconds
    self.expectedBoundaryBinding = expectedBoundaryBinding
  }

  public func observation(
    for reading: Gate15ClockReading,
    runner: Gate15ProcessIdentity
  ) throws -> Gate15Observation {
    let process = Process()
    process.executableURL = executable
    process.arguments = [
      "--gate15-sample",
      "--continuous-ticks", String(reading.continuousTicks),
      "--wall-clock-utc", reading.wallClockUTC,
      "--boot-session-id", reading.bootSessionID,
      "--runner-pid", String(runner.pid),
      "--runner-start-identity", runner.startIdentity
    ]
    var arguments = process.arguments ?? []
    if let expectedBoundaryBinding {
      arguments += [
        "--source-digest", expectedBoundaryBinding.sourceDigest,
        "--config-digest", expectedBoundaryBinding.configDigest,
        "--toolchain-digest", expectedBoundaryBinding.toolchainDigest,
        "--dependency-evidence-digest", expectedBoundaryBinding.dependencyEvidenceDigest,
        "--executable-pinset-digest", expectedBoundaryBinding.executablePinsetDigest
      ]
    }
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = FileHandle.nullDevice
    let data: Data
    do {
      data = try Gate15ProcessExecution.run(process, timeout: timeoutSeconds, maximumOutputBytes: 64 * 1024)
    } catch let error as Gate15QualificationError where error.code == "boundedProcessOutput" {
      throw Gate15QualificationError("observationFailed", "the observation provider returned an oversized sample.")
    }
    let observation = try Gate15JSON.decoder.decode(Gate15Observation.self, from: data)
    guard observation.continuousTicks == reading.continuousTicks,
          observation.observedAtUTC == reading.wallClockUTC,
          observation.bootSessionID == reading.bootSessionID,
          observation.runner == runner else {
      throw Gate15QualificationError("observationMismatch", "the provider returned data for a different clock or runner identity.")
    }
    if let expectedBoundaryBinding, observation.boundaryBinding != expectedBoundaryBinding {
      throw Gate15QualificationError("boundaryBindingMismatch", "the observation provider returned stale immutable dependency bindings.")
    }
    return observation
  }

  public func validateAuthorizedExecutable(for authorization: Gate15LaunchAuthorization) throws {
    try Gate15ValidatorBinding.validateAuthorizedExecutable(
      path: executable.path,
      expectedPath: authorization.observationProviderPath,
      device: authorization.observationProviderDevice,
      inode: authorization.observationProviderInode,
      digest: authorization.observationProviderDigest,
      code: "observationProviderChanged"
    )
  }
}

public struct Gate15CommandTrustedObservationProvider: Gate15TrustedObservationProvider, Gate15AuthorizedExecutableBinding {
  public let executable: URL
  public let timeoutSeconds: TimeInterval
  public let expectedBoundaryBinding: Gate15BoundaryBinding

  public init(
    executable: URL,
    expectedBoundaryBinding: Gate15BoundaryBinding,
    timeoutSeconds: TimeInterval = 20
  ) throws {
    guard executable.path.hasPrefix("/"), !executable.path.contains("\n"), executable.isFileURL else {
      throw Gate15QualificationError("unsafeTrustedProvider", "the trusted observation provider must be an absolute file URL.")
    }
    try Gate15FileIdentity.requireExecutable(executable.path, code: "unsafeTrustedProvider")
    self.executable = executable
    self.expectedBoundaryBinding = expectedBoundaryBinding
    self.timeoutSeconds = timeoutSeconds
  }

  public func trustedObservation(
    for reading: Gate15ClockReading,
    runner: Gate15ProcessIdentity
  ) throws -> Gate15TrustedObservation {
    let process = Process()
    process.executableURL = executable
    process.arguments = [
      "--gate15-trusted-sample",
      "--continuous-ticks", String(reading.continuousTicks),
      "--wall-clock-utc", reading.wallClockUTC,
      "--boot-session-id", reading.bootSessionID,
      "--runner-pid", String(runner.pid),
      "--runner-start-identity", runner.startIdentity,
      "--source-digest", expectedBoundaryBinding.sourceDigest,
      "--config-digest", expectedBoundaryBinding.configDigest,
      "--toolchain-digest", expectedBoundaryBinding.toolchainDigest,
      "--dependency-evidence-digest", expectedBoundaryBinding.dependencyEvidenceDigest,
      "--executable-pinset-digest", expectedBoundaryBinding.executablePinsetDigest
    ]
    process.standardOutput = Pipe()
    process.standardError = FileHandle.nullDevice
    let data = try Gate15ProcessExecution.run(process, timeout: timeoutSeconds, maximumOutputBytes: 128 * 1024)
    let trusted: Gate15TrustedObservation
    do {
      trusted = try Gate15JSON.decoder.decode(Gate15TrustedObservation.self, from: data)
    } catch {
      throw Gate15QualificationError("trustedObservationFailed", "the independent live-wrapper observation was malformed.")
    }
    guard try Gate15JSON.encoder.encode(trusted) == data else {
      throw Gate15QualificationError("trustedObservationFailed", "the independent live-wrapper observation was not canonical JSON.")
    }
    let identity = try Gate15FileIdentity.identity(executable.path, code: "unsafeTrustedProvider")
    try Gate15ObservationBinding.validate(
      provider: trusted.observation,
      trusted: trusted,
      reading: reading,
      runner: runner,
      expectedBoundaryBinding: expectedBoundaryBinding,
      providerIdentity: Gate15ExecutableBindingIdentity.value(
        path: executable.path,
        device: identity.device,
        inode: identity.inode,
        digest: try Gate15FileIdentity.sha256Executable(executable.path)
      )
    )
    return trusted
  }

  public func validateAuthorizedExecutable(for authorization: Gate15LaunchAuthorization) throws {
    try Gate15ValidatorBinding.validateAuthorizedExecutable(
      path: executable.path,
      expectedPath: authorization.trustedObservationProviderPath,
      device: authorization.trustedObservationProviderDevice,
      inode: authorization.trustedObservationProviderInode,
      digest: authorization.trustedObservationProviderDigest,
      code: "trustedObservationProviderChanged"
    )
  }
}

private enum Gate15ValidatorBinding {
  static func validateExecutable(
    _ executable: URL,
    expectedPath: String,
    expectedDevice: UInt64,
    expectedInode: UInt64,
    expectedDigest: String
  ) throws {
    guard executable.path == expectedPath, expectedPath == Gate15CanonicalValidators.boundary || expectedPath == Gate15CanonicalValidators.dependency else {
      throw Gate15QualificationError("unsafeValidator", "Gate 15 formal validation requires a canonical repository validator.")
    }
    try Gate15FileIdentity.requireExecutable(executable.path, code: "unsafeValidator")
    let identity = try Gate15FileIdentity.identity(executable.path, code: "unsafeValidator")
    guard identity.device == expectedDevice, identity.inode == expectedInode,
          try Gate15FileIdentity.sha256Executable(executable.path) == expectedDigest else {
      throw Gate15QualificationError("validatorChanged", "the canonical validator path, device, inode, or digest changed.")
    }
  }

  static func validatePinset(_ pinset: URL, authorization: Gate15LaunchAuthorization) throws {
    guard pinset.path == authorization.executablePinsetPath else {
      throw Gate15QualificationError("pinsetChanged", "the executable pinset path changed from the signed launch authorization.")
    }
    try Gate15FileIdentity.requirePrivateFile(pinset.path, mode: 0o600, code: "pinsetChanged")
    let identity = try Gate15FileIdentity.identity(pinset.path, code: "pinsetChanged")
    guard identity.device == authorization.executablePinsetDevice,
          identity.inode == authorization.executablePinsetInode,
          try Gate15FileIdentity.sha256(pinset.path) == authorization.executablePinsetDigest else {
      throw Gate15QualificationError("pinsetChanged", "the executable pinset device, inode, or digest changed.")
    }
  }

  static func validateTool(_ tool: URL, authorization: Gate15LaunchAuthorization) throws {
    guard tool.path == Gate15CanonicalTool.path,
          authorization.toolPath == Gate15CanonicalTool.path,
          authorization.toolMode == 0o755 else {
      throw Gate15QualificationError("unsafeTool", "formal Gate 15 execution requires the canonical built qualification tool and mode 0755.")
    }
    try Gate15FileIdentity.requireExecutable(tool.path, code: "unsafeTool")
    let identity = try Gate15FileIdentity.identity(tool.path, code: "unsafeTool")
    guard identity.device == authorization.toolDevice,
          identity.inode == authorization.toolInode,
          Gate15FileIdentity.mode(tool.path) == authorization.toolMode,
          try Gate15FileIdentity.sha256Executable(tool.path) == authorization.toolDigest else {
      throw Gate15QualificationError("toolChanged", "the canonical built qualification tool path, identity, mode, or digest changed.")
    }
    let buildIdentity = Gate15FileIdentity.toolBuildIdentity(
      path: tool.path,
      mode: authorization.toolMode,
      device: authorization.toolDevice,
      inode: authorization.toolInode,
      digest: authorization.toolDigest,
      sourceCommit: authorization.sourceCommit,
      sourceDigest: authorization.sourceDigest,
      configDigest: authorization.configDigest,
      toolchainDigest: authorization.toolchainDigest
    )
    guard buildIdentity == authorization.toolBuildIdentity else {
      throw Gate15QualificationError("toolBuildMismatch", "the signed qualification tool build/source identity changed.")
    }
    let currentPath = try Gate15FileIdentity.currentExecutablePath()
    guard currentPath == authorization.toolPath else {
      throw Gate15QualificationError("toolBypass", "the formal runner was not launched from the signed canonical qualification tool path.")
    }
  }

  static func validateAuthorizedExecutable(
    path: String,
    expectedPath: String,
    device: UInt64,
    inode: UInt64,
    digest: String,
    code: String
  ) throws {
    guard path == expectedPath else {
      throw Gate15QualificationError(code, "the signed executable path changed from the authorized invocation.")
    }
    try Gate15FileIdentity.requireExecutable(path, code: code)
    let identity = try Gate15FileIdentity.identity(path, code: code)
    guard identity.device == device,
          identity.inode == inode,
          try Gate15FileIdentity.sha256Executable(path) == digest else {
      throw Gate15QualificationError(code, "the signed executable path, identity, or digest changed.")
    }
  }
}

public final class Gate15CommandBoundaryValidator: Gate15BoundaryValidator {
  public let executable: URL
  public let root: URL
  public let timeoutSeconds: TimeInterval
  private var authorization: Gate15LaunchAuthorization?

  public init(executable: URL, root: URL, timeoutSeconds: TimeInterval = 20) throws {
    guard executable.path.hasPrefix("/"), executable.isFileURL,
          root.path.hasPrefix("/"), root.isFileURL else {
      throw Gate15QualificationError("unsafeValidator", "the boundary validator must use absolute executable and root paths.")
    }
    guard executable.path == Gate15CanonicalValidators.boundary else {
      throw Gate15QualificationError("unsafeValidator", "the boundary validator must be the canonical Phase 09 live script.")
    }
    try Gate15FileIdentity.requireExecutable(executable.path, code: "unsafeValidator")
    self.executable = executable
    self.root = root
    self.timeoutSeconds = timeoutSeconds
  }

  public func bind(to authorization: Gate15LaunchAuthorization) throws {
    guard authorization.boundaryValidatorPath == Gate15CanonicalValidators.boundary else {
      throw Gate15QualificationError("unsafeValidator", "the signed boundary validator path is not canonical.")
    }
    try Gate15ValidatorBinding.validateExecutable(
      executable,
      expectedPath: authorization.boundaryValidatorPath,
      expectedDevice: authorization.boundaryValidatorDevice,
      expectedInode: authorization.boundaryValidatorInode,
      expectedDigest: authorization.boundaryValidatorDigest
    )
    self.authorization = authorization
  }

  public func validate() throws {
    guard let authorization else {
      throw Gate15QualificationError("missingValidatorBinding", "the boundary validator must be bound to signed launch authorization before use.")
    }
    try Gate15ValidatorBinding.validateExecutable(
      executable,
      expectedPath: authorization.boundaryValidatorPath,
      expectedDevice: authorization.boundaryValidatorDevice,
      expectedInode: authorization.boundaryValidatorInode,
      expectedDigest: authorization.boundaryValidatorDigest
    )
    let process = Process()
    process.executableURL = executable
    process.arguments = ["revalidate-sample", "--root", root.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
      throw Gate15QualificationError("boundaryValidationTimeout", "live-boundary revalidation exceeded its bounded deadline.")
    }
    guard process.terminationStatus == 0 else {
      throw Gate15QualificationError("boundaryChanged", "live-boundary dependency revalidation failed closed.")
    }
  }
}

public final class Gate15CommandDependencyValidator: Gate15DependencyValidator {
  public let executable: URL
  public let root: URL
  public let pinset: URL
  public let timeoutSeconds: TimeInterval
  private var authorization: Gate15LaunchAuthorization?

  public init(executable: URL, root: URL, pinset: URL, timeoutSeconds: TimeInterval = 20) throws {
    guard executable.path.hasPrefix("/"), executable.isFileURL,
          root.path.hasPrefix("/"), root.isFileURL,
          pinset.path.hasPrefix("/"), pinset.isFileURL else {
      throw Gate15QualificationError("unsafeValidator", "the dependency validator must use canonical absolute paths.")
    }
    guard executable.path == Gate15CanonicalValidators.dependency else {
      throw Gate15QualificationError("unsafeValidator", "the dependency validator must be the canonical Phase 09 qualification harness.")
    }
    try Gate15FileIdentity.requireExecutable(executable.path, code: "unsafeValidator")
    try Gate15FileIdentity.requirePrivateFile(pinset.path, mode: 0o600, code: "unsafeValidator")
    self.executable = executable
    self.root = root
    self.pinset = pinset
    self.timeoutSeconds = timeoutSeconds
  }

  public func bind(to authorization: Gate15LaunchAuthorization) throws {
    guard authorization.dependencyValidatorPath == Gate15CanonicalValidators.dependency else {
      throw Gate15QualificationError("unsafeValidator", "the signed dependency validator path is not canonical.")
    }
    try Gate15ValidatorBinding.validateExecutable(
      executable,
      expectedPath: authorization.dependencyValidatorPath,
      expectedDevice: authorization.dependencyValidatorDevice,
      expectedInode: authorization.dependencyValidatorInode,
      expectedDigest: authorization.dependencyValidatorDigest
    )
    try Gate15ValidatorBinding.validatePinset(pinset, authorization: authorization)
    self.authorization = authorization
  }

  public func validate() throws {
    guard let authorization else {
      throw Gate15QualificationError("missingValidatorBinding", "the dependency validator must be bound to signed launch authorization before use.")
    }
    try Gate15ValidatorBinding.validateExecutable(
      executable,
      expectedPath: authorization.dependencyValidatorPath,
      expectedDevice: authorization.dependencyValidatorDevice,
      expectedInode: authorization.dependencyValidatorInode,
      expectedDigest: authorization.dependencyValidatorDigest
    )
    try Gate15ValidatorBinding.validatePinset(pinset, authorization: authorization)
    let process = Process()
    process.executableURL = executable
    process.arguments = ["revalidate-sample", "--root", root.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    _ = try Gate15ProcessExecution.run(process, timeout: timeoutSeconds, maximumOutputBytes: 1)
  }
}

public struct Gate15CommandSleepWakeEventProvider: Gate15SleepWakeEventProvider, Gate15AuthorizedExecutableBinding {
  public let executable: URL
  public let timeoutSeconds: TimeInterval

  public init(executable: URL, timeoutSeconds: TimeInterval = 20) throws {
    guard executable.path.hasPrefix("/"), executable.isFileURL else {
      throw Gate15QualificationError("unsafeSleepWakeProvider", "the sleep/wake provider must use an absolute path.")
    }
    try Gate15FileIdentity.requireExecutable(executable.path, code: "unsafeSleepWakeProvider")
    self.executable = executable
    self.timeoutSeconds = timeoutSeconds
  }

  public func events(from start: Gate15ClockReading, to end: Gate15ClockReading) throws -> [Gate15SleepWakeEvent] {
    let process = Process()
    process.executableURL = executable
    process.arguments = [
      "--gate15-sleep-wake-events",
      "--from-continuous-ticks", String(start.continuousTicks),
      "--to-continuous-ticks", String(end.continuousTicks),
      "--from-wall-clock-utc", start.wallClockUTC,
      "--to-wall-clock-utc", end.wallClockUTC,
      "--boot-session-id", end.bootSessionID,
      "--no-backfill"
    ]
    process.standardOutput = Pipe()
    process.standardError = FileHandle.nullDevice
    let data = try Gate15ProcessExecution.run(process, timeout: timeoutSeconds, maximumOutputBytes: 64 * 1024)
    do {
      let events = try Gate15JSON.decoder.decode([Gate15SleepWakeEvent].self, from: data)
      guard try Gate15JSON.encoder.encode(events) == data else {
        throw Gate15QualificationError("sleepEventFailed", "the sleep/wake provider returned non-canonical JSON.")
      }
      return events
    } catch let error as Gate15QualificationError {
      throw error
    } catch {
      throw Gate15QualificationError("sleepEventFailed", "the ordered macOS sleep/wake event stream is malformed.")
    }
  }

  public func validateAuthorizedExecutable(for authorization: Gate15LaunchAuthorization) throws {
    try Gate15ValidatorBinding.validateAuthorizedExecutable(
      path: executable.path,
      expectedPath: authorization.sleepWakeProviderPath,
      device: authorization.sleepWakeProviderDevice,
      inode: authorization.sleepWakeProviderInode,
      digest: authorization.sleepWakeProviderDigest,
      code: "sleepWakeProviderChanged"
    )
  }
}

public struct Gate15CommandLaunchAuthorizationValidator: Gate15LaunchAuthorizationValidator {
  public let authorizationURL: URL
  public let requestURL: URL?
  public let expectedSigningIdentity: String
  public let expectedSigningFingerprint: String
  public let expectedCertificateFingerprint: String
  public let expectedTeamID: String

  public init(
    authorizationURL: URL,
    requestURL: URL? = nil,
    expectedSigningIdentity: String,
    expectedSigningFingerprint: String,
    expectedCertificateFingerprint: String,
    expectedTeamID: String
  ) throws {
    guard authorizationURL.path.hasPrefix("/"), authorizationURL.isFileURL else {
      throw Gate15QualificationError("unsafeAuthorization", "launch authorization must use an absolute file URL.")
    }
    self.authorizationURL = authorizationURL
    self.requestURL = requestURL
    self.expectedSigningIdentity = expectedSigningIdentity
    self.expectedSigningFingerprint = expectedSigningFingerprint
    self.expectedCertificateFingerprint = expectedCertificateFingerprint
    self.expectedTeamID = expectedTeamID
  }

  public func consumeAndValidate(
    root: URL,
    runner: Gate15ProcessIdentity,
    reading: Gate15ClockReading
  ) throws -> Gate15LaunchAuthorization {
    let expectedAuthorization = root.appendingPathComponent("launch-authorization-v1.cms")
    guard authorizationURL.path == expectedAuthorization.path else {
      throw Gate15QualificationError("unsafeAuthorization", "launch authorization is not the canonical Gate 15 root artifact.")
    }
    if !Gate15FileIdentity.existsOrSymlink(authorizationURL.path), let requestURL {
      try publishRequest(root: root, runner: runner, reading: reading, to: requestURL)
      var found = false
      for _ in 0..<120 {
        if Gate15FileIdentity.existsOrSymlink(authorizationURL.path) {
          found = true
          break
        }
        Thread.sleep(forTimeInterval: 0.25)
      }
      guard found else {
        throw Gate15QualificationError("launchAuthorizationTimeout", "the shell did not create one-time launch authorization.")
      }
    }
    try Gate15FileIdentity.requirePrivateFile(authorizationURL.path, mode: 0o600, code: "missingLaunchAuthorization")
    let before = try Gate15FileIdentity.identity(authorizationURL.path, code: "unsafeAuthorization")
    let (decoded, decodedData) = try verifyAndDecodeCMS()
    guard try Gate15JSON.encoder.encode(decoded) == decodedData else {
      throw Gate15QualificationError("launchAuthorizationInvalid", "launch authorization is not canonical JSON.")
    }
    try validate(decoded, root: root, runner: runner, reading: reading)
    let consumedURL = root.appendingPathComponent("launch-authorization-v1.consumed.cms")
    guard !Gate15FileIdentity.existsOrSymlink(consumedURL.path) else {
      throw Gate15QualificationError("launchAuthorizationReplay", "the one-time Gate 15 launch authorization was already consumed.")
    }
    let after = try Gate15FileIdentity.identity(authorizationURL.path, code: "unsafeAuthorization")
    guard before == after else {
      throw Gate15QualificationError("launchAuthorizationRace", "launch authorization changed while it was being verified.")
    }
    guard renameatx_np(AT_FDCWD, authorizationURL.path, AT_FDCWD, consumedURL.path, UInt32(RENAME_EXCL)) == 0 else {
      throw Gate15QualificationError("launchAuthorizationRace", "launch authorization could not be consumed with an exclusive atomic rename.")
    }
    try Gate15FileIdentity.requirePrivateFile(consumedURL.path, mode: 0o600, code: "launchAuthorizationRace")
    guard try Gate15FileIdentity.identity(consumedURL.path, code: "launchAuthorizationRace") == before else {
      throw Gate15QualificationError("launchAuthorizationRace", "launch authorization identity changed during consumption.")
    }
    return decoded
  }

  public func verifyConsumed(
    root: URL,
    runner: Gate15ProcessIdentity,
    reading: Gate15ClockReading,
    requireActiveLocks: Bool = true,
    allowPassedManifest: Bool = false
  ) throws -> Gate15LaunchAuthorization {
    let expectedConsumed = root.appendingPathComponent("launch-authorization-v1.consumed.cms")
    guard authorizationURL.path == expectedConsumed.path else {
      throw Gate15QualificationError("statusUnavailable", "status requires the canonical consumed authorization artifact.")
    }
    try Gate15FileIdentity.requirePrivateFile(authorizationURL.path, mode: 0o600, code: "statusUnavailable")
    let (authorization, data) = try verifyAndDecodeCMS()
    guard try Gate15JSON.encoder.encode(authorization) == data else {
      throw Gate15QualificationError("statusUnavailable", "the consumed authorization payload is not canonical JSON.")
    }
    try validate(
      authorization,
      root: root,
      runner: runner,
      reading: reading,
      requireActiveLocks: requireActiveLocks,
      allowPassedManifest: allowPassedManifest
    )
    return authorization
  }

  private func verifyAndDecodeCMS() throws -> (Gate15LaunchAuthorization, Data) {
    guard expectedSigningIdentity == "Developer ID Application: Dev Trivedi (993YC3JY4Q)",
          expectedSigningFingerprint == "A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB",
          expectedCertificateFingerprint == "A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB",
          expectedTeamID == "993YC3JY4Q" ||
            (expectedSigningIdentity == "testing-cms-signer" &&
             expectedSigningFingerprint == "testing-cms-fingerprint" &&
             expectedCertificateFingerprint == "testing-cms-certificate" &&
             expectedTeamID == "testing") else {
      throw Gate15QualificationError("launchAuthorizationSignerMismatch", "the launch authorization verifier is not using the fixed signer pinset.")
    }
    let verify = Process()
    verify.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    verify.arguments = ["cms", "-V", "-N", expectedSigningIdentity, "-u", "9", "-i", authorizationURL.path]
    verify.standardOutput = FileHandle.nullDevice
    verify.standardError = FileHandle.nullDevice
    _ = try Gate15ProcessExecution.run(verify, timeout: 20, maximumOutputBytes: 1)

    let parent = (authorizationURL.path as NSString).deletingLastPathComponent
    let cmsOutputDirectory = try Gate15FileIdentity.makePrivateTemporaryDirectory(
      in: parent,
      prefix: "cms-output",
      code: "launchAuthorizationSignerMismatch"
    )
    let signerCertificate = "\(cmsOutputDirectory)/signer.der"
    let verifiedPayload = "\(cmsOutputDirectory)/payload.bin"
    defer {
      _ = unlink(signerCertificate)
      _ = unlink(verifiedPayload)
      _ = rmdir(cmsOutputDirectory)
    }
    let opensslVerify = Process()
    opensslVerify.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    opensslVerify.arguments = ["cms", "-verify", "-inform", "DER", "-binary", "-noverify", "-in", authorizationURL.path, "-signer", signerCertificate, "-out", verifiedPayload]
    opensslVerify.standardOutput = FileHandle.nullDevice
    opensslVerify.standardError = FileHandle.nullDevice
    _ = try Gate15ProcessExecution.run(opensslVerify, timeout: 20, maximumOutputBytes: 1)
    try Gate15FileIdentity.requirePrivateFile(signerCertificate, mode: 0o600, code: "launchAuthorizationSignerMismatch")
    let certificateInfo = Process()
    certificateInfo.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    certificateInfo.arguments = ["x509", "-in", signerCertificate, "-noout", "-fingerprint", "-sha1", "-subject", "-nameopt", "RFC2253"]
    certificateInfo.standardOutput = Pipe()
    certificateInfo.standardError = FileHandle.nullDevice
    let certificateData = try Gate15ProcessExecution.run(certificateInfo, timeout: 20, maximumOutputBytes: 64 * 1024)
    guard let certificateOutput = String(data: certificateData, encoding: .utf8) else {
      throw Gate15QualificationError("launchAuthorizationSignerMismatch", "the CMS signer certificate could not be decoded.")
    }
    let fingerprint = certificateOutput.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
      .first(where: { $0.localizedCaseInsensitiveContains("fingerprint=") })
      .flatMap { $0.split(separator: "=", maxSplits: 1).last }
      .map { $0.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    let subject = certificateOutput.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
      .first(where: { String($0).lowercased().hasPrefix("subject=") })
      .map { String($0.dropFirst("subject=".count)) } ?? ""
    func certificateComponent(_ name: String) -> String? {
      subject.split(separator: ",").first(where: { $0.hasPrefix("\(name)=") }).map { String($0.dropFirst(name.count + 1)) }
    }
    let expectedCommonName = expectedSigningIdentity.replacingOccurrences(of: " (\(expectedTeamID))", with: "")
    guard fingerprint == expectedCertificateFingerprint.uppercased(),
          fingerprint == expectedSigningFingerprint.uppercased(),
          certificateComponent("CN") == expectedCommonName,
          certificateComponent("OU") == expectedTeamID else {
      throw Gate15QualificationError("launchAuthorizationSignerMismatch", "the actual CMS signer certificate fingerprint, Team ID, and identity do not match the fixed pins.")
    }

    let decode = Process()
    decode.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    decode.arguments = ["cms", "-D", "-N", expectedSigningIdentity, "-u", "9", "-i", authorizationURL.path]
    decode.standardOutput = Pipe()
    decode.standardError = FileHandle.nullDevice
    let decodedData = try Gate15ProcessExecution.run(decode, timeout: 20, maximumOutputBytes: 64 * 1024)
    do {
      return (try Gate15JSON.decoder.decode(Gate15LaunchAuthorization.self, from: decodedData), decodedData)
    } catch {
      throw Gate15QualificationError("launchAuthorizationInvalid", "the CMS launch authorization payload is malformed.")
    }
  }

  private func validate(
    _ authorization: Gate15LaunchAuthorization,
    root: URL,
    runner: Gate15ProcessIdentity,
    reading: Gate15ClockReading,
    requireActiveLocks: Bool = true,
    allowPassedManifest: Bool = false
  ) throws {
    guard authorization.schema == "hostwright.phase09.gate15.launch-authorization.v1",
          authorization.root == root.path,
          authorization.runnerPID == runner.pid,
          authorization.runnerStartIdentity == runner.startIdentity,
          authorization.bootSessionID == reading.bootSessionID,
          authorization.bootSessionID.range(of: "^[A-Fa-f0-9-]{36}$", options: .regularExpression) != nil,
          authorization.rootLockDevice > 0,
          authorization.rootLockInode > 0,
          authorization.gateLockDevice > 0,
          authorization.gateLockInode > 0,
          authorization.dependencyValidatorPath == Gate15CanonicalValidators.dependency,
          authorization.boundaryValidatorPath == Gate15CanonicalValidators.boundary,
          authorization.dependencyValidatorDevice > 0,
          authorization.dependencyValidatorInode > 0,
          authorization.boundaryValidatorDevice > 0,
          authorization.boundaryValidatorInode > 0,
          authorization.executablePinsetPath.hasPrefix("/"),
          authorization.executablePinsetDevice > 0,
          authorization.executablePinsetInode > 0,
          authorization.signingIdentity == expectedSigningIdentity,
          authorization.signingFingerprint == expectedSigningFingerprint,
          authorization.certificateFingerprint == expectedCertificateFingerprint,
          authorization.teamID == expectedTeamID,
          authorization.nonce.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.sourceCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
          authorization.sourceDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.configDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.toolchainDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.dependencyEvidenceDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.executablePinsetDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.dependencyValidatorDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.boundaryValidatorDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.runStartedDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.manifestDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.toolPath == Gate15CanonicalTool.path,
          authorization.toolDevice > 0,
          authorization.toolInode > 0,
          authorization.toolMode == 0o755,
          authorization.toolDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.toolBuildIdentity.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.invocation == "run --root \(root.path)",
          authorization.observationProviderPath.hasPrefix("/"),
          authorization.observationProviderDevice > 0,
          authorization.observationProviderInode > 0,
          authorization.observationProviderDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.trustedObservationProviderPath.hasPrefix("/"),
          authorization.trustedObservationProviderDevice > 0,
          authorization.trustedObservationProviderInode > 0,
          authorization.trustedObservationProviderDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.sleepWakeProviderPath.hasPrefix("/"),
          authorization.sleepWakeProviderDevice > 0,
          authorization.sleepWakeProviderInode > 0,
          authorization.sleepWakeProviderDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          authorization.createdAtUTC.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$", options: .regularExpression) != nil else {
      throw Gate15QualificationError("launchAuthorizationMismatch", "launch authorization is not bound to the exact runner, boot, signer, or dependency digests.")
    }
    try Gate15FileIdentity.requireCanonicalGate15Root(root.path)
    let expectedRootLock = root.appendingPathComponent("active-run-v1").path
    let expectedGateLock = root.deletingLastPathComponent().appendingPathComponent(".phase09-gate15-active-v1").path
    if requireActiveLocks {
      try validateLock(
        path: authorization.rootLockPath,
        expectedPath: expectedRootLock,
        device: authorization.rootLockDevice,
        inode: authorization.rootLockInode
      )
      try validateLock(
        path: authorization.gateLockPath,
        expectedPath: expectedGateLock,
        device: authorization.gateLockDevice,
        inode: authorization.gateLockInode
      )
    } else {
      guard authorization.rootLockPath == expectedRootLock,
            authorization.gateLockPath == expectedGateLock,
            !Gate15FileIdentity.existsOrSymlink(expectedRootLock),
            !Gate15FileIdentity.existsOrSymlink(expectedGateLock) else {
        throw Gate15QualificationError("launchAuthorizationMismatch", "passed status requires the exact released Gate 15 lock paths.")
      }
    }
    let manifestURL = root.appendingPathComponent("manifest-v1.json")
    try Gate15FileIdentity.requirePrivateFile(manifestURL.path, mode: 0o600, code: "launchAuthorizationMismatch")
    let manifestDigest = try Gate15FileIdentity.sha256(manifestURL.path)
    guard let manifestData = FileManager.default.contents(atPath: manifestURL.path),
          let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
          manifest["schema"] as? String == "hostwright.phase09.gate15.qualification.manifest.v1",
          manifest["gate"] as? Int == 15,
          let manifestStatus = manifest["status"] as? String,
          manifestStatus == "prepared" || manifestStatus == "passed",
          manifest["sourceCommit"] as? String == authorization.sourceCommit,
          manifest["sourceDigest"] as? String == authorization.sourceDigest,
          manifest["configDigest"] as? String == authorization.configDigest,
          manifest["toolchainDigest"] as? String == authorization.toolchainDigest,
          manifest["dependencyEvidenceDigest"] as? String == authorization.dependencyEvidenceDigest,
          manifest["executablePinsetDigest"] as? String == authorization.executablePinsetDigest else {
      throw Gate15QualificationError("launchAuthorizationMismatch", "the authenticated launch is not bound to the exact Gate 15 manifest fields.")
    }
    guard manifestDigest == authorization.manifestDigest || (allowPassedManifest && manifestStatus == "passed") else {
      throw Gate15QualificationError("launchAuthorizationMismatch", "the authenticated manifest digest changed outside the approved post-pass transition.")
    }
    try Gate15RunBinding.validate(
      root: root,
      authorization: authorization,
      runner: runner,
      requireActiveLocks: requireActiveLocks
    )
  }

  private func validateLock(path: String, expectedPath: String, device: UInt64, inode: UInt64) throws {
    guard path == expectedPath else {
      throw Gate15QualificationError("launchAuthorizationMismatch", "launch authorization names a non-canonical lock path.")
    }
    try Gate15FileIdentity.requirePrivateDirectory(path, code: "launchAuthorizationMismatch")
    let identity = try Gate15FileIdentity.identity(path, code: "launchAuthorizationMismatch")
    guard identity.device == device, identity.inode == inode else {
      throw Gate15QualificationError("launchAuthorizationRace", "a Gate 15 lock changed before launch.")
    }
  }

  private func publishRequest(
    root: URL,
    runner: Gate15ProcessIdentity,
    reading: Gate15ClockReading,
    to requestURL: URL
  ) throws {
    guard requestURL.path == root.appendingPathComponent("launch-request-v1.json").path else {
      throw Gate15QualificationError("unsafeAuthorization", "launch request is not the canonical Gate 15 root artifact.")
    }
    let nonce = Gate15JSON.randomNonce()
    let request = Gate15LaunchRequest(
      schema: "hostwright.phase09.gate15.launch-request.v1",
      root: root.path,
      runnerPID: runner.pid,
      runnerStartIdentity: runner.startIdentity,
      bootSessionID: reading.bootSessionID,
      nonce: nonce,
      requestedAtUTC: reading.wallClockUTC
    )
    try Gate15FileIdentity.writePrivateAtomically(
      data: try Gate15JSON.encoder.encode(request),
      to: requestURL.path,
      code: "launchAuthorizationFailed",
      requireAbsentDestination: true
    )
  }
}

private final class Gate15ProcessCapture: @unchecked Sendable {
  let lock = NSLock()
  var data = Data()
  var oversized = false
}

private enum Gate15ProcessExecution {
  static func run(_ process: Process, timeout: TimeInterval, maximumOutputBytes: Int) throws -> Data {
    let outputPipe = process.standardOutput as? Pipe
    let group = DispatchGroup()
    let capture = Gate15ProcessCapture()
    if let outputPipe {
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        while true {
          let chunk = outputPipe.fileHandleForReading.readData(ofLength: 4 * 1024)
          if chunk.isEmpty { break }
          capture.lock.lock()
          if !capture.oversized {
            if capture.data.count > maximumOutputBytes - min(maximumOutputBytes, chunk.count) {
              capture.oversized = true
            } else {
              capture.data.append(chunk)
            }
          }
          capture.lock.unlock()
        }
        group.leave()
      }
    }
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
      capture.lock.lock()
      let exceeded = capture.oversized
      capture.lock.unlock()
      if exceeded {
        process.terminate()
        break
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
      group.wait()
      throw Gate15QualificationError("boundedProcessTimeout", "a Gate 15 boundary process exceeded its bounded deadline.")
    }
    group.wait()
    capture.lock.lock()
    let result = capture.data
    let exceeded = capture.oversized
    capture.lock.unlock()
    if exceeded {
      throw Gate15QualificationError("boundedProcessOutput", "a Gate 15 boundary process exceeded its bounded output limit.")
    }
    guard process.terminationStatus == 0 else {
      throw Gate15QualificationError("boundaryProcessFailed", "a Gate 15 boundary process failed closed.")
    }
    return result
  }
}

public enum Gate15ToolCommand: Equatable {
  case contract
  case diagnose
  case prepare
  case processIdentity(pid: Int32)
  case run(root: URL)
  case status(root: URL)

  public static func parse(_ arguments: [String]) throws -> Gate15ToolCommand {
    guard let first = arguments.first else {
      throw Gate15QualificationError("usage", "usage: contract|diagnose|prepare|process-identity --pid PID|run --root PATH|status --root PATH")
    }
    switch first {
    case "contract":
      guard arguments.count == 1 else { throw Gate15QualificationError("usage", "contract accepts no arguments.") }
      return .contract
    case "diagnose":
      guard arguments.count == 1 else { throw Gate15QualificationError("usage", "diagnose accepts no arguments.") }
      return .diagnose
    case "prepare":
      guard arguments.count == 1 else { throw Gate15QualificationError("usage", "prepare accepts no arguments.") }
      return .prepare
    case "process-identity":
      guard arguments.count == 3, arguments[1] == "--pid",
            arguments[2].range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil,
            let pid = Int32(arguments[2]), pid > 0 else {
        throw Gate15QualificationError("usage", "process-identity requires --pid PID.")
      }
      return .processIdentity(pid: pid)
    case "run", "status":
      guard arguments.count == 3, arguments[1] == "--root", arguments[2].hasPrefix("/") else {
        throw Gate15QualificationError("usage", "\(first) requires --root PATH.")
      }
      let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
      return first == "run" ? .run(root: root) : .status(root: root)
    default:
      throw Gate15QualificationError("usage", "unknown Gate 15 tool command.")
    }
  }
}

public enum Gate15QualificationTool {
  public static func execute(_ command: Gate15ToolCommand, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Data {
    switch command {
    case .contract:
      return try Gate15JSON.encoder.encode(Gate15Contract.frozen)
    case .diagnose:
      return try Gate15JSON.encoder.encode(Gate15DiagnosticResponse(
        claim: "none",
        gate: 15,
        status: "diagnostic",
        formal: false,
        reason: "diagnose is read-only and non-qualifying"
      ))
    case .prepare:
      return try Gate15JSON.encoder.encode(Gate15DiagnosticResponse(
        claim: "none",
        gate: 15,
        status: "prepare-delegated-to-qualification-harness",
        formal: false,
        reason: "formal root preparation belongs to the shell qualification harness"
      ))
    case .processIdentity(let pid):
      let identity = try Gate15SystemProcessIdentityProvider().lookup(pid: pid)
      return Data(identity.startIdentity.utf8)
    case .status(let root):
      return try status(root: root, environment: environment)
    case .run(let root):
      let testing = environment["HOSTWRIGHT_PHASE09_HARNESS_TESTING"] == "1"
      guard !testing else {
        throw Gate15QualificationError("testModeCannotQualify", "test mode cannot manufacture or claim a formal bounded Gate 15 passage.")
      }
      guard let authorizationPath = environment["HOSTWRIGHT_GATE15_LAUNCH_AUTHORIZATION"] else {
        throw Gate15QualificationError("missingLaunchAuthorization", "HOSTWRIGHT_GATE15_LAUNCH_AUTHORIZATION is required for every direct formal run.")
      }
      guard environment["HOSTWRIGHT_GATE15_TOOL"] == Gate15CanonicalTool.path else {
        throw Gate15QualificationError("toolBypass", "formal runs may execute only the canonical built HostwrightPhase09QualificationTool artifact.")
      }
      guard let signingIdentity = environment["HOSTWRIGHT_GATE15_SIGNING_IDENTITY"],
            let signingFingerprint = environment["HOSTWRIGHT_GATE15_SIGNING_FINGERPRINT"],
            let certificateFingerprint = environment["HOSTWRIGHT_GATE15_CERTIFICATE_FINGERPRINT"],
            let teamID = environment["HOSTWRIGHT_GATE15_TEAM_ID"] else {
        throw Gate15QualificationError("missingSignerPin", "the exact CMS certificate fingerprint, Team ID, and identity are required.")
      }
      guard signingIdentity == "Developer ID Application: Dev Trivedi (993YC3JY4Q)",
            signingFingerprint == "A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB",
            certificateFingerprint == "A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB",
            teamID == "993YC3JY4Q" else {
        throw Gate15QualificationError("missingSignerPin", "the exact pinned CMS certificate fingerprint, Team ID, and identity are required.")
      }
      guard let providerPath = environment["HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER"] else {
        throw Gate15QualificationError("missingObservationProvider", "HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER is required.")
      }
      guard let trustedProviderPath = environment["HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER"] else {
        throw Gate15QualificationError("missingTrustedObservationProvider", "HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER is required.")
      }
      guard environment["HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR"] == Gate15CanonicalValidators.dependency,
            environment["HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR"] == Gate15CanonicalValidators.boundary,
            let pinsetPath = environment["HOSTWRIGHT_GATE15_EXECUTABLE_PINSET"],
            let requestPath = environment["HOSTWRIGHT_GATE15_LAUNCH_REQUEST"],
            requestPath == root.appendingPathComponent("launch-request-v1.json").path else {
        throw Gate15QualificationError("unsafeValidator", "formal runs require the canonical signed Gate 15 validators, pinset, and launch request.")
      }
      guard let sourceDigest = environment["HOSTWRIGHT_GATE15_SOURCE_DIGEST"],
            let configDigest = environment["HOSTWRIGHT_GATE15_CONFIG_DIGEST"],
            let toolchainDigest = environment["HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST"],
            let dependencyDigest = environment["HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST"],
            let pinsetDigest = environment["HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST"],
            [sourceDigest, configDigest, toolchainDigest, dependencyDigest, pinsetDigest].allSatisfy({
              $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
            }) else {
        throw Gate15QualificationError("missingBoundaryBinding", "formal runs require current source, configuration, toolchain, transitive evidence, and pinset digests.")
      }
      let clock = try Gate15MachContinuousClock()
      let provider = try Gate15CommandObservationProvider(
        executable: URL(fileURLWithPath: providerPath),
        expectedBoundaryBinding: Gate15BoundaryBinding(
          sourceDigest: sourceDigest,
          configDigest: configDigest,
          toolchainDigest: toolchainDigest,
          dependencyEvidenceDigest: dependencyDigest,
          executablePinsetDigest: pinsetDigest
        )
      )
      let trustedProvider = try Gate15CommandTrustedObservationProvider(
        executable: URL(fileURLWithPath: trustedProviderPath),
        expectedBoundaryBinding: Gate15BoundaryBinding(
          sourceDigest: sourceDigest,
          configDigest: configDigest,
          toolchainDigest: toolchainDigest,
          dependencyEvidenceDigest: dependencyDigest,
          executablePinsetDigest: pinsetDigest
        )
      )
      guard let validatorPath = environment["HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR"] else {
        throw Gate15QualificationError("missingBoundaryValidator", "HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR is required.")
      }
      let validator = try Gate15CommandBoundaryValidator(
        executable: URL(fileURLWithPath: validatorPath),
        root: root
      )
      guard let dependencyValidatorPath = environment["HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR"] else {
        throw Gate15QualificationError("missingDependencyValidator", "HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR is required.")
      }
      let dependencyValidator = try Gate15CommandDependencyValidator(
        executable: URL(fileURLWithPath: dependencyValidatorPath),
        root: root,
        pinset: URL(fileURLWithPath: pinsetPath)
      )
      guard let sleepWakeProviderPath = environment["HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER"] else {
        throw Gate15QualificationError("missingSleepWakeProvider", "HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER is required.")
      }
      let sleepWakeProvider = try Gate15CommandSleepWakeEventProvider(
        executable: URL(fileURLWithPath: sleepWakeProviderPath)
      )
      let launchAuthorizationValidator = try Gate15CommandLaunchAuthorizationValidator(
        authorizationURL: URL(fileURLWithPath: authorizationPath),
        requestURL: environment["HOSTWRIGHT_GATE15_LAUNCH_REQUEST"].map { URL(fileURLWithPath: $0) },
        expectedSigningIdentity: signingIdentity,
        expectedSigningFingerprint: signingFingerprint,
        expectedCertificateFingerprint: certificateFingerprint,
        expectedTeamID: teamID
      )
      let runner = Gate15QualificationRunner(
        root: root,
        clock: clock,
        identities: Gate15SystemProcessIdentityProvider(),
        observations: provider,
        boundaryValidator: validator,
        dependencyValidator: dependencyValidator,
        sleepWakeProvider: sleepWakeProvider,
        launchAuthorizationValidator: launchAuthorizationValidator,
        trustedObservations: trustedProvider
      )
      let result = try runner.run()
      return try Gate15JSON.encoder.encode(result)
    }
  }

  private static func status(root: URL, environment: [String: String]) throws -> Data {
    if environment["HOSTWRIGHT_PHASE09_HARNESS_TESTING"] == "1" {
      return try testStatus(root: root)
    }
    let stateURL = root.appendingPathComponent("runner-state-v1.json")
    try Gate15FileIdentity.requireCanonicalGate15Root(root.path)
    try Gate15FileIdentity.requirePrivateFile(stateURL.path, mode: 0o600, code: "statusUnavailable")
    guard let data = FileManager.default.contents(atPath: stateURL.path) else {
      throw Gate15QualificationError("statusUnavailable", "Gate 15 runner state is unavailable.")
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard object?["schema"] as? String == "hostwright.phase09.gate15.runner-state.v1",
          object?["root"] as? String == root.path,
          let pidNumber = object?["runnerPID"] as? NSNumber,
          let startIdentity = object?["runnerStartIdentity"] as? String,
          let bootSessionID = object?["bootSessionID"] as? String,
          let sourceCommit = object?["sourceCommit"] as? String,
          sourceCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
          let stateRootLockPath = object?["rootLockPath"] as? String,
          let stateGateLockPath = object?["gateLockPath"] as? String,
          stateRootLockPath == root.appendingPathComponent("active-run-v1").path,
          stateGateLockPath == root.deletingLastPathComponent().appendingPathComponent(".phase09-gate15-active-v1").path,
          let stateSourceDigest = object?["sourceDigest"] as? String,
          let stateConfigDigest = object?["configDigest"] as? String,
          let stateToolchainDigest = object?["toolchainDigest"] as? String,
          let stateDependencyDigest = object?["dependencyEvidenceDigest"] as? String,
          let statePinsetDigest = object?["executablePinsetDigest"] as? String,
          let stateManifestDigest = object?["manifestDigest"] as? String,
          let stateNonce = object?["launchNonce"] as? String,
          stateSourceDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          stateConfigDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          stateToolchainDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          stateDependencyDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          statePinsetDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          stateManifestDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          stateNonce.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          let status = object?["status"] as? String,
          ["running", "finalizing", "pre-pass", "passed"].contains(status),
          pidNumber.intValue > 0 else {
      throw Gate15QualificationError("statusInvalid", "Gate 15 runner state is malformed.")
    }
    guard sourceCommit == environment["HOSTWRIGHT_GATE15_SOURCE_COMMIT"],
          stateSourceDigest == environment["HOSTWRIGHT_GATE15_SOURCE_DIGEST"],
          stateConfigDigest == environment["HOSTWRIGHT_GATE15_CONFIG_DIGEST"],
          stateToolchainDigest == environment["HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST"],
          stateDependencyDigest == environment["HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST"],
          statePinsetDigest == environment["HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST"] else {
      throw Gate15QualificationError("statusStale", "status requires exact current source, configuration, toolchain, dependency, and pinset bindings.")
    }
    let requiresLiveAttachment = status == "running"
    let identity: Gate15ProcessIdentity
    if requiresLiveAttachment {
      let liveIdentity = try Gate15SystemProcessIdentityProvider().lookup(pid: pidNumber.int32Value)
      guard liveIdentity.startIdentity == startIdentity else {
        throw Gate15QualificationError("runnerReplaced", "status refuses to attach to a different runner process.")
      }
      try Gate15FileIdentity.requirePrivateDirectory(
        root.appendingPathComponent("active-run-v1").path,
        code: "statusUnavailable"
      )
      try Gate15FileIdentity.requirePrivateDirectory(
        root.deletingLastPathComponent().appendingPathComponent(".phase09-gate15-active-v1").path,
        code: "statusUnavailable"
      )
      identity = liveIdentity
    } else {
      identity = Gate15ProcessIdentity(pid: pidNumber.int32Value, startIdentity: startIdentity)
    }
    guard try Gate15SystemIdentity.bootSessionID() == bootSessionID else {
      throw Gate15QualificationError("bootSessionChanged", "status refuses a different macOS boot session.")
    }
    guard let authorizationPath = environment["HOSTWRIGHT_GATE15_LAUNCH_AUTHORIZATION"] else {
      throw Gate15QualificationError("statusUnavailable", "status requires the authenticated launch authorization artifact.")
    }
    guard authorizationPath == root.appendingPathComponent("launch-authorization-v1.consumed.cms").path else {
      throw Gate15QualificationError("statusUnavailable", "status requires the canonical consumed launch authorization.")
    }
    guard let signingIdentity = environment["HOSTWRIGHT_GATE15_SIGNING_IDENTITY"],
          let signingFingerprint = environment["HOSTWRIGHT_GATE15_SIGNING_FINGERPRINT"],
          let certificateFingerprint = environment["HOSTWRIGHT_GATE15_CERTIFICATE_FINGERPRINT"],
          let teamID = environment["HOSTWRIGHT_GATE15_TEAM_ID"] else {
      throw Gate15QualificationError("statusUnavailable", "status requires the pinned CMS certificate fingerprint, Team ID, and identity.")
    }
    guard signingIdentity == "Developer ID Application: Dev Trivedi (993YC3JY4Q)",
          signingFingerprint == "A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB",
          certificateFingerprint == "A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB",
          teamID == "993YC3JY4Q" else {
      throw Gate15QualificationError("statusUnavailable", "status requires the exact pinned CMS certificate fingerprint, Team ID, and identity.")
    }
    let verifier = try Gate15CommandLaunchAuthorizationValidator(
      authorizationURL: URL(fileURLWithPath: authorizationPath),
      expectedSigningIdentity: signingIdentity,
      expectedSigningFingerprint: signingFingerprint,
      expectedCertificateFingerprint: certificateFingerprint,
      expectedTeamID: teamID
    )
    let authorization = try verifier.verifyConsumed(
      root: root,
      runner: identity,
      reading: Gate15ClockReading(
        continuousTicks: 0,
        wallClockUTC: Gate15JSON.utcNow(),
        bootSessionID: bootSessionID
      ),
      requireActiveLocks: requiresLiveAttachment || status != "passed",
      allowPassedManifest: status == "passed"
    )
    guard authorization.sourceCommit == sourceCommit,
          authorization.sourceDigest == stateSourceDigest,
          authorization.configDigest == stateConfigDigest,
          authorization.toolchainDigest == stateToolchainDigest,
          authorization.dependencyEvidenceDigest == stateDependencyDigest,
          authorization.executablePinsetDigest == statePinsetDigest,
          authorization.manifestDigest == stateManifestDigest,
          authorization.nonce == stateNonce else {
      throw Gate15QualificationError("statusStale", "status state and consumed authorization are not bound to the same exact launch.")
    }
    let manifestURL = root.appendingPathComponent("manifest-v1.json")
    try Gate15FileIdentity.requirePrivateFile(manifestURL.path, mode: 0o600, code: "statusUnavailable")
    guard let manifestData = FileManager.default.contents(atPath: manifestURL.path),
          let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
          manifest["schema"] as? String == "hostwright.phase09.gate15.qualification.manifest.v1",
          manifest["gate"] as? Int == 15,
          manifest["status"] as? String == "prepared" || manifest["status"] as? String == "passed",
          manifest["sourceCommit"] as? String == sourceCommit,
          manifest["sourceDigest"] as? String == stateSourceDigest,
          manifest["configDigest"] as? String == stateConfigDigest,
          manifest["toolchainDigest"] as? String == stateToolchainDigest,
          manifest["dependencyEvidenceDigest"] as? String == stateDependencyDigest,
          manifest["executablePinsetDigest"] as? String == statePinsetDigest,
          let manifestStatus = manifest["status"] as? String,
          manifestStatus == "prepared" || manifestStatus == "passed" else {
      throw Gate15QualificationError("statusStale", "status requires an authenticated exact Gate 15 manifest.")
    }
    let currentManifestDigest = try Gate15FileIdentity.sha256(manifestURL.path)
    guard (manifestStatus == "prepared" && currentManifestDigest == stateManifestDigest)
      || (status == "passed" && manifestStatus == "passed") else {
      throw Gate15QualificationError("statusStale", "status requires an authenticated exact Gate 15 manifest transition.")
    }
    return try Gate15JSON.encoder.encode(Gate15StatusResponse(
      claim: "none",
      gate: 15,
      status: status,
      runnerPID: pidNumber.intValue,
      runnerStartIdentity: startIdentity,
      readOnly: true,
      formal: false
    ))
  }

  private static func testStatus(root: URL) throws -> Data {
    try Gate15FileIdentity.requirePrivateDirectory(root.path, code: "unsafeRoot")
    try Gate15FileIdentity.requirePrivateDirectory(
      root.appendingPathComponent("active-run-v1").path,
      code: "statusUnavailable"
    )
    let stateURL = root.appendingPathComponent("runner-state-v1.json")
    try Gate15FileIdentity.requirePrivateFile(stateURL.path, mode: 0o600, code: "statusUnavailable")
    guard let data = FileManager.default.contents(atPath: stateURL.path),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["schema"] as? String == "hostwright.phase09.gate15.runner-state.v1",
          let pidNumber = object["runnerPID"] as? NSNumber,
          let startIdentity = object["runnerStartIdentity"] as? String,
          let status = object["status"] as? String else {
      throw Gate15QualificationError("statusInvalid", "Gate 15 test runner state is malformed.")
    }
    let identity = try Gate15SystemProcessIdentityProvider().lookup(pid: pidNumber.int32Value)
    guard identity.pid == pidNumber.int32Value, identity.startIdentity == startIdentity else {
      throw Gate15QualificationError("runnerReplaced", "status refuses to attach to a different runner process.")
    }
    return try Gate15JSON.encoder.encode(Gate15StatusResponse(
      claim: "none",
      gate: 15,
      status: status,
      runnerPID: pidNumber.intValue,
      runnerStartIdentity: startIdentity,
      readOnly: true,
      formal: false
    ))
  }
}

private struct Gate15DiagnosticResponse: Codable {
  let claim: String
  let gate: Int
  let status: String
  let formal: Bool
  let reason: String
}

private struct Gate15StatusResponse: Codable {
  let claim: String
  let gate: Int
  let status: String
  let runnerPID: Int
  let runnerStartIdentity: String
  let readOnly: Bool
  let formal: Bool
}

private enum Gate15JSON {
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  static let decoder = JSONDecoder()

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func utcNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
  }

  static func randomNonce() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
  }
}

private enum Gate15SystemIdentity {
  static func bootSessionID() throws -> String {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
      throw Gate15QualificationError("bootSessionUnavailable", "the macOS boot-session UUID is unavailable.")
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
      throw Gate15QualificationError("bootSessionUnavailable", "the macOS boot-session UUID is unavailable.")
    }
    let bytes = buffer.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
  }
}

private enum Gate15FileIdentity {
  struct Identity: Equatable {
    let device: UInt64
    let inode: UInt64
    let nlink: UInt64
  }

  static func existsOrSymlink(_ path: String) -> Bool {
    var information = stat()
    return lstat(path, &information) == 0
  }

  static func requireCanonicalGate15Root(_ path: String) throws {
    let canonicalPath = canonical(path)
    guard Gate15CanonicalRoot.isFixedT9Root(path: path, canonicalPath: canonicalPath) else {
      throw Gate15QualificationError("unsafeRoot", "Gate 15 requires the fixed T9 qualification parent and lowercase UUID root.")
    }
    try requirePrivateDirectory(Gate15CanonicalRoot.parent, code: "unsafeRoot")
    try requirePrivateDirectory(path, code: "unsafeRoot")
  }

  static func canonical(_ path: String) -> String {
    guard let pointer = realpath(path, nil) else { return "" }
    defer { free(pointer) }
    return String(cString: pointer)
  }

  static func requirePrivateDirectory(_ path: String, code: String) throws {
    var information = stat()
    guard lstat(path, &information) == 0,
          path.hasPrefix("/"), !path.contains("\n"),
          (information.st_mode & S_IFMT) == S_IFDIR,
          information.st_uid == getuid(),
          (information.st_mode & 0o777) == 0o700,
          canonical(path) == path else {
      throw Gate15QualificationError(code, "the path must be a current-user-owned mode-0700 directory.")
    }
  }

  static func requirePrivateFile(_ path: String, mode: UInt16, code: String) throws {
    var information = stat()
    guard lstat(path, &information) == 0,
          path.hasPrefix("/"), !path.contains("\n"),
          (information.st_mode & S_IFMT) == S_IFREG,
          information.st_uid == getuid(),
          information.st_nlink == 1,
          (information.st_mode & 0o777) == mode,
          canonical(path) == path else {
      throw Gate15QualificationError(code, "the path must be a current-user-owned private regular file.")
    }
  }

  static func requireExecutable(_ path: String, code: String) throws {
    var information = stat()
    guard lstat(path, &information) == 0,
          path.hasPrefix("/"), !path.contains("\n"),
          (information.st_mode & S_IFMT) == S_IFREG,
          information.st_uid == getuid(),
          information.st_nlink == 1,
          (information.st_mode & 0o777) == 0o755,
          canonical(path) == path else {
      throw Gate15QualificationError(code, "the executable must be a current-user-owned regular non-symlink file.")
    }
  }

  static func mode(_ path: String) -> UInt16 {
    var information = stat()
    guard lstat(path, &information) == 0 else { return 0 }
    return information.st_mode & 0o777
  }

  static func identity(_ path: String, code: String) throws -> Identity {
    var information = stat()
    guard lstat(path, &information) == 0 else {
      throw Gate15QualificationError(code, "the path identity is unavailable.")
    }
    return Identity(
      device: UInt64(information.st_dev),
      inode: UInt64(information.st_ino),
      nlink: UInt64(information.st_nlink)
    )
  }

  static func sha256(_ path: String) throws -> String {
    try requirePrivateFile(path, mode: 0o600, code: "unsafeDigestInput")
    guard let data = FileManager.default.contents(atPath: path) else {
      throw Gate15QualificationError("unsafeDigestInput", "the digest input could not be read.")
    }
    return Gate15JSON.sha256Hex(data)
  }

  static func sha256Executable(_ path: String) throws -> String {
    try requireExecutable(path, code: "unsafeDigestInput")
    guard let data = FileManager.default.contents(atPath: path) else {
      throw Gate15QualificationError("unsafeDigestInput", "the executable digest input could not be read.")
    }
    return Gate15JSON.sha256Hex(data)
  }

  static func currentExecutablePath() throws -> String {
    var size: UInt32 = 4096
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
      throw Gate15QualificationError("toolBypass", "the current qualification executable path is unavailable.")
    }
    let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let canonicalPath = canonical(path)
    guard !canonicalPath.isEmpty else {
      throw Gate15QualificationError("toolBypass", "the current qualification executable could not be canonicalized.")
    }
    return canonicalPath
  }

  static func toolBuildIdentity(
    path: String,
    mode: UInt16,
    device: UInt64,
    inode: UInt64,
    digest: String,
    sourceCommit: String,
    sourceDigest: String,
    configDigest: String,
    toolchainDigest: String
  ) -> String {
    let input = "path=\(path)\nmode=\(mode)\ndevice=\(device)\ninode=\(inode)\ndigest=\(digest)\nsourceCommit=\(sourceCommit)\nsourceDigest=\(sourceDigest)\nconfigDigest=\(configDigest)\ntoolchainDigest=\(toolchainDigest)\n"
    return Gate15JSON.sha256Hex(Data(input.utf8))
  }

  static func makePrivateTemporary(in parent: String, prefix: String, code: String) throws -> String {
    try requirePrivateDirectory(parent, code: code)
    for _ in 0..<64 {
      let path = "\(parent)/.gate15-\(prefix)-\(Gate15JSON.randomNonce())"
      let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      if descriptor >= 0 {
        close(descriptor)
        try requirePrivateFile(path, mode: 0o600, code: code)
        return path
      }
      guard errno == EEXIST else { break }
    }
    throw Gate15QualificationError(code, "the exclusive private temporary could not be created.")
  }

  static func makePrivateTemporaryDirectory(in parent: String, prefix: String, code: String) throws -> String {
    try requirePrivateDirectory(parent, code: code)
    for _ in 0..<64 {
      let path = "\(parent)/.gate15-\(prefix)-\(Gate15JSON.randomNonce())"
      guard mkdir(path, 0o700) == 0 else {
        guard errno == EEXIST else { break }
        continue
      }
      try requirePrivateDirectory(path, code: code)
      return path
    }
    throw Gate15QualificationError(code, "the exclusive private temporary directory could not be created.")
  }

  static func writePrivateAtomically(
    data: Data,
    to destination: String,
    code: String,
    requireAbsentDestination: Bool = false
  ) throws {
    let parent = (destination as NSString).deletingLastPathComponent
    try requirePrivateDirectory(parent, code: code)
    if requireAbsentDestination && existsOrSymlink(destination) {
      throw Gate15QualificationError(code, "the destination already exists or is a symlink.")
    }
    let temporary = "\(parent)/.gate15-atomic-\(Gate15JSON.randomNonce()).next"
    var descriptor: Int32 = -1
    defer {
      if descriptor >= 0 { close(descriptor) }
      if existsOrSymlink(temporary) { unlink(temporary) }
    }
    descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw Gate15QualificationError(code, "the exclusive no-follow temporary could not be created.")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    descriptor = -1
    try requirePrivateFile(temporary, mode: 0o600, code: code)
    let temporaryIdentity = try identity(temporary, code: code)
    guard temporaryIdentity.nlink == 1 else {
      throw Gate15QualificationError(code, "the publication temporary has more than one hard link.")
    }
    if requireAbsentDestination && existsOrSymlink(destination) {
      throw Gate15QualificationError(code, "the destination appeared during atomic publication.")
    }
    if requireAbsentDestination {
      guard renameatx_np(AT_FDCWD, temporary, AT_FDCWD, destination, UInt32(RENAME_EXCL)) == 0 else {
        throw Gate15QualificationError(code, "the private temporary could not be published with an exclusive atomic rename.")
      }
    } else {
      if existsOrSymlink(destination) {
        try requirePrivateFile(destination, mode: 0o600, code: code)
      }
      guard rename(temporary, destination) == 0 else {
        throw Gate15QualificationError(code, "the private temporary could not be atomically published.")
      }
    }
    try requirePrivateFile(destination, mode: 0o600, code: code)
    guard try identity(destination, code: code) == temporaryIdentity else {
      throw Gate15QualificationError(code, "the published artifact changed device, inode, or hard-link identity.")
    }
  }
}

private enum Gate15RunBinding {
  private static let lockInfoHeader = "root\tpid\trunner_start_identity\tstarted_at\tsource_commit\tsource_digest\tconfig_digest\ttoolchain_digest\tdependency_digest\tpinset_digest\tmanifest_digest"

  static func validate(
    root: URL,
    authorization: Gate15LaunchAuthorization,
    runner: Gate15ProcessIdentity,
    requireActiveLocks: Bool = true
  ) throws {
    let markerPath = root.appendingPathComponent("run-started-v1.json").path
    try Gate15FileIdentity.requirePrivateFile(markerPath, mode: 0o600, code: "runStartedMissing")
    guard let data = FileManager.default.contents(atPath: markerPath) else {
      throw Gate15QualificationError("runStartedMissing", "the durable Gate 15 run-started marker is unreadable.")
    }
    let marker: Gate15RunStartedMarker
    do {
      marker = try Gate15JSON.decoder.decode(Gate15RunStartedMarker.self, from: data)
    } catch {
      throw Gate15QualificationError("runStartedInvalid", "the durable Gate 15 run-started marker is malformed.")
    }
    let expectedRootLock = root.appendingPathComponent("active-run-v1").path
    let expectedGateLock = root.deletingLastPathComponent().appendingPathComponent(".phase09-gate15-active-v1").path
    let expectedRootInfo = root.appendingPathComponent("gate-active-run-v1-info.tsv").path
    let expectedGateInfo = URL(fileURLWithPath: expectedGateLock).appendingPathComponent("info-v1.tsv").path
    guard marker.schema == "hostwright.phase09.gate15.run-started.v1",
          marker.status == "runner-started",
          marker.root == root.path,
          marker.rootLockPath == expectedRootLock,
          marker.gateLockPath == expectedGateLock,
          marker.rootLockInfoPath == expectedRootInfo,
          marker.gateLockInfoPath == expectedGateInfo,
          marker.runnerPID == runner.pid,
          marker.runnerStartIdentity == runner.startIdentity,
          marker.runnerPID == authorization.runnerPID,
          marker.runnerStartIdentity == authorization.runnerStartIdentity,
          marker.sourceCommit == authorization.sourceCommit,
          marker.sourceDigest == authorization.sourceDigest,
          marker.configDigest == authorization.configDigest,
          marker.toolchainDigest == authorization.toolchainDigest,
          marker.dependencyEvidenceDigest == authorization.dependencyEvidenceDigest,
          marker.executablePinsetDigest == authorization.executablePinsetDigest,
          marker.manifestDigest == authorization.manifestDigest,
          marker.dependencyValidatorPath == authorization.dependencyValidatorPath,
          marker.dependencyValidatorDevice == authorization.dependencyValidatorDevice,
          marker.dependencyValidatorInode == authorization.dependencyValidatorInode,
          marker.dependencyValidatorDigest == authorization.dependencyValidatorDigest,
          marker.boundaryValidatorPath == authorization.boundaryValidatorPath,
          marker.boundaryValidatorDevice == authorization.boundaryValidatorDevice,
          marker.boundaryValidatorInode == authorization.boundaryValidatorInode,
          marker.boundaryValidatorDigest == authorization.boundaryValidatorDigest,
          marker.executablePinsetPath == authorization.executablePinsetPath,
          marker.executablePinsetDevice == authorization.executablePinsetDevice,
          marker.executablePinsetInode == authorization.executablePinsetInode,
          marker.executablePinsetDigest == authorization.executablePinsetDigest,
          marker.toolPath == authorization.toolPath,
          marker.toolDevice == authorization.toolDevice,
          marker.toolInode == authorization.toolInode,
          marker.toolMode == authorization.toolMode,
          marker.toolDigest == authorization.toolDigest,
          marker.toolBuildIdentity == authorization.toolBuildIdentity,
          marker.invocation == authorization.invocation,
          marker.observationProviderPath == authorization.observationProviderPath,
          marker.observationProviderDevice == authorization.observationProviderDevice,
          marker.observationProviderInode == authorization.observationProviderInode,
          marker.observationProviderDigest == authorization.observationProviderDigest,
          marker.trustedObservationProviderPath == authorization.trustedObservationProviderPath,
          marker.trustedObservationProviderDevice == authorization.trustedObservationProviderDevice,
          marker.trustedObservationProviderInode == authorization.trustedObservationProviderInode,
          marker.trustedObservationProviderDigest == authorization.trustedObservationProviderDigest,
          marker.sleepWakeProviderPath == authorization.sleepWakeProviderPath,
          marker.sleepWakeProviderDevice == authorization.sleepWakeProviderDevice,
          marker.sleepWakeProviderInode == authorization.sleepWakeProviderInode,
          marker.sleepWakeProviderDigest == authorization.sleepWakeProviderDigest else {
      throw Gate15QualificationError("runStartedMismatch", "the durable run-started marker is not bound to this signed runner and source.")
    }
    if requireActiveLocks {
      try validateLock(expectedRootLock, device: marker.rootLockDevice, inode: marker.rootLockInode)
      try validateLock(expectedGateLock, device: marker.gateLockDevice, inode: marker.gateLockInode)
    } else {
      guard !Gate15FileIdentity.existsOrSymlink(expectedRootLock),
            !Gate15FileIdentity.existsOrSymlink(expectedGateLock),
            !Gate15FileIdentity.existsOrSymlink(expectedGateInfo) else {
        throw Gate15QualificationError("runLockChanged", "passed Gate 15 evidence still has an active lock or lock-info artifact.")
      }
    }
    try Gate15ValidatorBinding.validateExecutable(
      URL(fileURLWithPath: authorization.dependencyValidatorPath),
      expectedPath: authorization.dependencyValidatorPath,
      expectedDevice: authorization.dependencyValidatorDevice,
      expectedInode: authorization.dependencyValidatorInode,
      expectedDigest: authorization.dependencyValidatorDigest
    )
    try Gate15ValidatorBinding.validateExecutable(
      URL(fileURLWithPath: authorization.boundaryValidatorPath),
      expectedPath: authorization.boundaryValidatorPath,
      expectedDevice: authorization.boundaryValidatorDevice,
      expectedInode: authorization.boundaryValidatorInode,
      expectedDigest: authorization.boundaryValidatorDigest
    )
    try Gate15ValidatorBinding.validatePinset(
      URL(fileURLWithPath: authorization.executablePinsetPath),
      authorization: authorization
    )
    try Gate15ValidatorBinding.validateTool(
      URL(fileURLWithPath: authorization.toolPath),
      authorization: authorization
    )
    try Gate15ValidatorBinding.validateAuthorizedExecutable(
      path: authorization.observationProviderPath,
      expectedPath: authorization.observationProviderPath,
      device: authorization.observationProviderDevice,
      inode: authorization.observationProviderInode,
      digest: authorization.observationProviderDigest,
      code: "observationProviderChanged"
    )
    try Gate15ValidatorBinding.validateAuthorizedExecutable(
      path: authorization.trustedObservationProviderPath,
      expectedPath: authorization.trustedObservationProviderPath,
      device: authorization.trustedObservationProviderDevice,
      inode: authorization.trustedObservationProviderInode,
      digest: authorization.trustedObservationProviderDigest,
      code: "trustedObservationProviderChanged"
    )
    try Gate15ValidatorBinding.validateAuthorizedExecutable(
      path: authorization.sleepWakeProviderPath,
      expectedPath: authorization.sleepWakeProviderPath,
      device: authorization.sleepWakeProviderDevice,
      inode: authorization.sleepWakeProviderInode,
      digest: authorization.sleepWakeProviderDigest,
      code: "sleepWakeProviderChanged"
    )
    let markerDigest = try Gate15FileIdentity.sha256(markerPath)
    guard markerDigest == authorization.runStartedDigest else {
      throw Gate15QualificationError("runStartedMismatch", "the durable run-started marker digest changed from the signed authorization.")
    }
    try validateLockInfo(expectedRootInfo, marker: marker, authorization: authorization)
    if requireActiveLocks {
      try validateLockInfo(expectedGateInfo, marker: marker, authorization: authorization)
    }
  }

  private static func validateLock(_ path: String, device: UInt64, inode: UInt64) throws {
    try Gate15FileIdentity.requirePrivateDirectory(path, code: "runLockChanged")
    let identity = try Gate15FileIdentity.identity(path, code: "runLockChanged")
    guard identity.device == device, identity.inode == inode, device > 0, inode > 0 else {
      throw Gate15QualificationError("runLockChanged", "the Gate 15 active lock device or inode changed.")
    }
  }

  private static func validateLockInfo(
    _ path: String,
    marker: Gate15RunStartedMarker,
    authorization: Gate15LaunchAuthorization
  ) throws {
    try Gate15FileIdentity.requirePrivateFile(path, mode: 0o600, code: "runLockInfoChanged")
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      throw Gate15QualificationError("runLockInfoChanged", "the Gate 15 active lock info is unreadable.")
    }
    let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
    let expectedRow = [
      authorization.root,
      String(authorization.runnerPID),
      authorization.runnerStartIdentity,
      marker.startedAtUTC,
      authorization.sourceCommit,
      authorization.sourceDigest,
      authorization.configDigest,
      authorization.toolchainDigest,
      authorization.dependencyEvidenceDigest,
      authorization.executablePinsetDigest,
      authorization.manifestDigest
    ].joined(separator: "\t")
    guard lines == [lockInfoHeader, expectedRow] else {
      throw Gate15QualificationError("runLockInfoChanged", "the Gate 15 active lock info is not bound to the same runner and source.")
    }
  }
}

private extension Data {
  static func + (lhs: Data, rhs: Data) -> Data {
    var result = lhs
    result.append(rhs)
    return result
  }
}

private func runGate15Tool() {
  do {
    let command = try Gate15ToolCommand.parse(Array(CommandLine.arguments.dropFirst()))
    let data = try Gate15QualificationTool.execute(command)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
    exit(0)
  } catch let error as Gate15QualificationError {
    FileHandle.standardError.write(Data("phase09 gate15 qualification failed: \(error.code): \(error.message)\n".utf8))
    exit(70)
  } catch {
    FileHandle.standardError.write(Data("phase09 gate15 qualification failed: internalFailure\n".utf8))
    exit(70)
  }
}

runGate15Tool()
