import Foundation
import Darwin
import XCTest

@testable import HostwrightPhase09QualificationTool

final class HostwrightPhase09QualificationToolTests: XCTestCase {
  private let contract = Gate15Contract(
    durationSeconds: 10,
    intervalSeconds: 5,
    requiredIntervals: 2,
    awakeToleranceSeconds: 1
  )

  func testFrozenContractUsesMachContinuousTimeAndExactSampleCount() {
    XCTAssertEqual(Gate15Contract.frozen.durationSeconds, 259_200)
    XCTAssertEqual(Gate15Contract.frozen.intervalSeconds, 300)
    XCTAssertEqual(Gate15Contract.frozen.requiredIntervals, 864)
    XCTAssertEqual(Gate15Contract.frozen.requiredSampleCount, 865)
    XCTAssertEqual(Gate15Contract.frozen.cells, ["U", "I", "L", "M", "S", "R"])
  }

  func testCanonicalFixedT9RootAcceptsOnlyExactRootAndCanonicalTarget() {
    let root = "/Volumes/T9/hostwright/qualification/phase09-gate15-01234567-89ab-cdef-0123-456789abcdef"
    XCTAssertTrue(Gate15CanonicalRoot.isFixedT9Root(path: root, canonicalPath: root))

    let wrongParent = "/Volumes/T9/hostwright/shadow/phase09-gate15-01234567-89ab-cdef-0123-456789abcdef"
    XCTAssertFalse(Gate15CanonicalRoot.isFixedT9Root(path: wrongParent, canonicalPath: wrongParent))

    let symlinkShadow = "/Volumes/T9/hostwright/qualification/phase09-gate15-01234567-89ab-cdef-0123-456789abcdef"
    XCTAssertFalse(Gate15CanonicalRoot.isFixedT9Root(
      path: symlinkShadow,
      canonicalPath: "/Volumes/T9/hostwright/qualification/real-gate15-root"
    ))
    let source = try! String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/HostwrightPhase09QualificationTool/main.swift"),
      encoding: .utf8
    )
    XCTAssertFalse(source.contains("hasPrefix(\"(parent)/\")"))
  }

  func testRequiredIntervalsPlusOneAndRationalTimebaseFailClosedOnOverflow() throws {
    XCTAssertThrowsError(try Gate15ContinuityLedger(
      contract: Gate15Contract(requiredIntervals: UInt64(Int.max)),
      ticksPerSecond: 1
    )) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "invalidContract")
    }
    let timebase = try Gate15Timebase(numer: 3, denom: 2)
    XCTAssertEqual(try timebase.ticks(forSeconds: 3), 2_000_000_000)
    XCTAssertTrue(try timebase.durationAtLeast(ticks: 2_000_000_000, seconds: 3))
    XCTAssertThrowsError(try timebase.ticks(forSeconds: UInt64.max)) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "clockOverflow")
    }
    XCTAssertThrowsError(try timebase.durationAtLeast(ticks: UInt64.max, seconds: UInt64.max)) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "clockOverflow")
    }
  }

  func testCompleteLedgerUsesAppendOnlyCanonicalHashChain() throws {
    var ledger = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    _ = try ledger.append(observation(at: 0, seconds: 0))
    _ = try ledger.append(observation(at: 5, seconds: 5))
    _ = try ledger.append(observation(at: 10, seconds: 10))

    try ledger.validateComplete()
    XCTAssertEqual(ledger.samples.count, 3)
    XCTAssertEqual(ledger.samples[1].previousSampleSHA256, ledger.samples[0].sampleSHA256)
    XCTAssertEqual(ledger.samples[2].previousSampleSHA256, ledger.samples[1].sampleSHA256)
    let canonical = try ledger.samples[0].canonicalJSON()
    XCTAssertEqual(canonical, try ledger.samples[0].canonicalJSON())
  }

  func testReplacementIsRejected() throws {
    var ledger = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    _ = try ledger.append(observation(at: 0, seconds: 0))
    var replacement = observation(at: 5, seconds: 5)
    replacement = Gate15Observation(
      observedAtUTC: replacement.observedAtUTC,
      continuousTicks: replacement.continuousTicks,
      bootSessionID: replacement.bootSessionID,
      runner: Gate15ProcessIdentity(pid: 303, startIdentity: "runner-replacement"),
      daemon: replacement.daemon,
      executable: replacement.executable,
      stateDatabase: replacement.stateDatabase,
      runtime: replacement.runtime,
      metrics: replacement.metrics,
      fault: replacement.fault,
      sleepWakeCoverage: replacement.sleepWakeCoverage
    )
    XCTAssertThrowsError(try ledger.append(replacement)) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "runnerReplaced")
    }
  }

  func testRebootAndContinuousTimeRegressionAreRejected() throws {
    var rebootLedger = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    _ = try rebootLedger.append(observation(at: 0, seconds: 0))
    var reboot = observation(at: 5, seconds: 5)
    reboot = Gate15Observation(
      observedAtUTC: reboot.observedAtUTC,
      continuousTicks: reboot.continuousTicks,
      bootSessionID: "new-boot-session",
      runner: reboot.runner,
      daemon: reboot.daemon,
      executable: reboot.executable,
      stateDatabase: reboot.stateDatabase,
      runtime: reboot.runtime,
      metrics: reboot.metrics,
      fault: reboot.fault,
      sleepWakeCoverage: reboot.sleepWakeCoverage
    )
    XCTAssertThrowsError(try rebootLedger.append(reboot)) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "bootSessionChanged")
    }

    var regressionLedger = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    _ = try regressionLedger.append(observation(at: 5, seconds: 5))
    XCTAssertThrowsError(try regressionLedger.append(observation(at: 4, seconds: 5))) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "continuousTimeRegression")
    }
  }

  func testSampleGapFailsAndExactSleepCoveragePasses() throws {
    var gapLedger = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    _ = try gapLedger.append(observation(at: 0, seconds: 0))
    XCTAssertThrowsError(try gapLedger.append(observation(at: 8, seconds: 8))) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "awakeCadenceViolation")
    }

    var sleepLedger = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    _ = try sleepLedger.append(observation(at: 0, seconds: 0))
    let covered = observation(
      at: 8,
      seconds: 8,
      coverage: [Gate15SleepWakeInterval(
        sleepStartUTC: timestamp(5),
        wakeUTC: timestamp(8),
        continuousStartTicks: 5,
        continuousEndTicks: 8
      )]
    )
    _ = try sleepLedger.append(covered)
  }

  func testSleepWakeEventIDsMustBeGloballyUniqueAcrossTheFormalLedger() throws {
    let binding = Gate15BoundaryBinding(
      sourceDigest: String(repeating: "a", count: 64),
      configDigest: String(repeating: "b", count: 64),
      toolchainDigest: String(repeating: "c", count: 64),
      dependencyEvidenceDigest: String(repeating: "d", count: 64),
      executablePinsetDigest: String(repeating: "e", count: 64)
    )
    var ledger = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    _ = try ledger.append(try formalObservation(at: 0, seconds: 0, binding: binding))
    let firstCoverage = try formalCoverage(start: 5, end: 8, sleepID: "global-sleep", wakeID: "global-wake")
    let firstCovered = try formalObservation(at: 8, seconds: 8, coverage: firstCoverage, binding: binding)
    let firstSample = try ledger.append(firstCovered)
    let duplicateObservation = try formalObservation(
      at: 16,
      seconds: 16,
      coverage: try formalCoverage(start: 13, end: 16, sleepID: "global-sleep", wakeID: "global-wake"),
      binding: binding
    )
    XCTAssertThrowsError(try ledger.append(duplicateObservation)) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "sleepCoverageInvalid")
    }

    let provisional = Gate15Sample(
      sequence: 2,
      observation: duplicateObservation,
      previousSampleSHA256: firstSample.sampleSHA256,
      sampleSHA256: ""
    )
    let duplicateSample = Gate15Sample(
      sequence: provisional.sequence,
      observation: duplicateObservation,
      previousSampleSHA256: provisional.previousSampleSHA256,
      sampleSHA256: try Gate15Sample.hash(for: provisional)
    )
    XCTAssertThrowsError(try ledger.validatePersisted(ledger.samples + [duplicateSample], formal: true)) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "sleepCoverageInvalid")
    }
  }

  func testHashTamperAndCoverageOrderingFailClosed() throws {
    var ledger = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    _ = try ledger.append(observation(at: 0, seconds: 0))
    _ = try ledger.append(observation(at: 5, seconds: 5))
    var persisted = ledger.samples
    let original = persisted[1]
    persisted[1] = Gate15Sample(
      sequence: original.sequence,
      observation: original.observation,
      previousSampleSHA256: original.previousSampleSHA256,
      sampleSHA256: String(repeating: "0", count: 64)
    )
    XCTAssertThrowsError(try ledger.validatePersisted(persisted)) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "hashChainMismatch")
    }

    var coverageLedger = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    _ = try coverageLedger.append(observation(at: 0, seconds: 0))
    let unordered = observation(
      at: 8,
      seconds: 8,
      coverage: [
        Gate15SleepWakeInterval(
          sleepStartUTC: timestamp(6),
          wakeUTC: timestamp(7),
          continuousStartTicks: 6,
          continuousEndTicks: 7
        ),
        Gate15SleepWakeInterval(
          sleepStartUTC: timestamp(4),
          wakeUTC: timestamp(6),
          continuousStartTicks: 4,
          continuousEndTicks: 6
        )
      ]
    )
    XCTAssertThrowsError(try coverageLedger.append(unordered)) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "sleepCoverageInvalid")
    }
  }

  func testFormalBoundaryAndSleepCoverageAuthenticationAreRequired() throws {
    let binding = Gate15BoundaryBinding(
      sourceDigest: String(repeating: "a", count: 64),
      configDigest: String(repeating: "b", count: 64),
      toolchainDigest: String(repeating: "c", count: 64),
      dependencyEvidenceDigest: String(repeating: "d", count: 64),
      executablePinsetDigest: String(repeating: "e", count: 64)
    )
    var missingBinding = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    _ = try missingBinding.append(observation(at: 0, seconds: 0))
    _ = try missingBinding.append(observation(at: 5, seconds: 5))
    _ = try missingBinding.append(observation(at: 10, seconds: 10))
    XCTAssertThrowsError(try missingBinding.validateComplete(formal: true)) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "boundaryBindingMissing")
    }

    var formal = try Gate15ContinuityLedger(contract: .frozen, ticksPerSecond: 1)
    try appendFrozenFormalSamples(to: &formal, binding: binding, forgedAuthenticationDigest: nil)
    XCTAssertNoThrow(try formal.validateComplete(formal: true))

    var tampered = try Gate15ContinuityLedger(contract: .frozen, ticksPerSecond: 1)
    try appendFrozenFormalSamples(
      to: &tampered,
      binding: binding,
      forgedAuthenticationDigest: "sha256:" + String(repeating: "0", count: 64)
    )
    XCTAssertThrowsError(try tampered.validateComplete(formal: true)) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "sleepEventUnauthenticated")
    }
  }

  func testIndependentObservationBindingRejectsProviderRuntimeDaemonExecutableAndSleepMismatches() throws {
    let binding = Gate15BoundaryBinding(
      sourceDigest: String(repeating: "a", count: 64),
      configDigest: String(repeating: "b", count: 64),
      toolchainDigest: String(repeating: "c", count: 64),
      dependencyEvidenceDigest: String(repeating: "d", count: 64),
      executablePinsetDigest: String(repeating: "e", count: 64)
    )
    let reading = Gate15ClockReading(
      continuousTicks: 5,
      wallClockUTC: timestamp(5),
      bootSessionID: "boot-session-1"
    )
    let base = observation(at: 5, seconds: 5, binding: binding)
    let trusted = try trustedObservation(for: base)

    XCTAssertNoThrow(try Gate15ObservationBinding.validate(
      provider: base,
      trusted: trusted,
      reading: reading,
      runner: base.runner,
      expectedBoundaryBinding: binding
    ))

    let runtimeMismatch = Gate15Observation(
      observedAtUTC: base.observedAtUTC,
      continuousTicks: base.continuousTicks,
      bootSessionID: base.bootSessionID,
      runner: base.runner,
      daemon: base.daemon,
      executable: base.executable,
      stateDatabase: base.stateDatabase,
      runtime: Gate15RuntimeIdentity(
        runtimeUUID: base.runtime.runtimeUUID,
        project: base.runtime.project,
        imageDigest: "sha256:" + String(repeating: "f", count: 64),
        inventoryDigest: base.runtime.inventoryDigest
      ),
      metrics: base.metrics,
      fault: base.fault,
      boundaryBinding: binding
    )
    XCTAssertThrowsError(try Gate15ObservationBinding.validate(
      provider: runtimeMismatch,
      trusted: trusted,
      reading: reading,
      runner: base.runner,
      expectedBoundaryBinding: binding
    )) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "trustedObservationMismatch")
    }

    let daemonStateMismatch = try trustedObservation(
      for: base,
      daemonStateDigest: "sha256:" + String(repeating: "f", count: 64)
    )
    XCTAssertThrowsError(try Gate15ObservationBinding.validate(
      provider: base,
      trusted: daemonStateMismatch,
      reading: reading,
      runner: base.runner,
      expectedBoundaryBinding: binding
    )) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "trustedObservationUnauthenticated")
    }

    let executableMismatch = Gate15Observation(
      observedAtUTC: base.observedAtUTC,
      continuousTicks: base.continuousTicks,
      bootSessionID: base.bootSessionID,
      runner: base.runner,
      daemon: base.daemon,
      executable: Gate15SignedExecutableIdentity(
        sha256: "sha256:" + String(repeating: "f", count: 64),
        cdHash: base.executable.cdHash,
        teamID: base.executable.teamID,
        identifier: base.executable.identifier
      ),
      stateDatabase: base.stateDatabase,
      runtime: base.runtime,
      metrics: base.metrics,
      fault: base.fault,
      boundaryBinding: binding
    )
    XCTAssertThrowsError(try Gate15ObservationBinding.validate(
      provider: executableMismatch,
      trusted: trusted,
      reading: reading,
      runner: base.runner,
      expectedBoundaryBinding: binding
    )) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "trustedObservationMismatch")
    }

    let providerSleepCoverage = base.with(
      sleepWakeCoverage: [Gate15SleepWakeInterval(
        sleepStartUTC: timestamp(1),
        wakeUTC: timestamp(2),
        continuousStartTicks: 1,
        continuousEndTicks: 2
      )],
      boundaryBinding: binding
    )
    XCTAssertThrowsError(try Gate15ObservationBinding.validate(
      provider: providerSleepCoverage,
      trusted: trusted,
      reading: reading,
      runner: base.runner,
      expectedBoundaryBinding: binding
    )) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "sleepEventSelfAttestation")
    }
  }

  func testNonUTCAndNonContiguousCoverageAreRejected() throws {
    var timestampLedger = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    XCTAssertThrowsError(try timestampLedger.append(observation(at: 0, seconds: 0, timestampOverride: "2026-08-05T00:00:00+00:00"))) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "invalidTimestamp")
    }
    var coverageLedger = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    _ = try coverageLedger.append(observation(at: 0, seconds: 0))
    let gap = observation(
      at: 10,
      seconds: 10,
      coverage: [
        Gate15SleepWakeInterval(sleepStartUTC: timestamp(5), wakeUTC: timestamp(6), continuousStartTicks: 5, continuousEndTicks: 6),
        Gate15SleepWakeInterval(sleepStartUTC: timestamp(7), wakeUTC: timestamp(8), continuousStartTicks: 7, continuousEndTicks: 10)
      ]
    )
    XCTAssertThrowsError(try coverageLedger.append(gap)) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "sleepCoverageInvalid")
    }
  }

  func testPlannedDaemonRestartRequiresOldAndNewIdentityAndBoundedRecovery() throws {
    var ledger = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    let first = observation(at: 0, seconds: 0)
    _ = try ledger.append(first)
    let nextDaemon = Gate15DaemonIdentity(pid: 404, generation: 2, startIdentity: "daemon-2")
    let restart = Gate15DaemonRestart(
      previous: first.daemon,
      current: nextDaemon,
      recoveryWithinBound: true
    )
    let planned = Gate15Observation(
      observedAtUTC: timestamp(5),
      continuousTicks: 5,
      bootSessionID: first.bootSessionID,
      runner: first.runner,
      daemon: nextDaemon,
      executable: first.executable,
      stateDatabase: first.stateDatabase,
      runtime: first.runtime,
      metrics: first.metrics,
      fault: Gate15FaultObservation(
        scheduledMarker: "daemon-restart-144",
        recoveryResult: "bounded-recovery",
        recoveryWithinBound: true,
        plannedDaemonRestart: true,
        daemonRestart: restart
      )
    )
    _ = try ledger.append(planned)

    var unplannedLedger = try Gate15ContinuityLedger(contract: contract, ticksPerSecond: 1)
    _ = try unplannedLedger.append(first)
    let unplanned = Gate15Observation(
      observedAtUTC: timestamp(5),
      continuousTicks: 5,
      bootSessionID: first.bootSessionID,
      runner: first.runner,
      daemon: nextDaemon,
      executable: first.executable,
      stateDatabase: first.stateDatabase,
      runtime: first.runtime,
      metrics: first.metrics
    )
    XCTAssertThrowsError(try unplannedLedger.append(unplanned)) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "unexpectedDaemonReplacement")
    }
  }

  func testTestModeCannotManufacturePassage() throws {
    let runner = Gate15QualificationRunner(
      root: URL(fileURLWithPath: "/var/empty-gate15-root", isDirectory: true),
      contract: .frozen,
      clock: FakeClock(),
      identities: FakeIdentityProvider(),
      observations: FakeObservationProvider(),
      testing: true
    )
    XCTAssertThrowsError(try runner.run()) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "testModeCannotQualify")
    }
  }

  func testToolCommandHasNoElapsedResumeAndDiagnoseIsNonQualifying() throws {
    XCTAssertEqual(try Gate15ToolCommand.parse(["contract"]), .contract)
    XCTAssertEqual(try Gate15ToolCommand.parse(["diagnose"]), .diagnose)
    XCTAssertEqual(try Gate15ToolCommand.parse(["prepare"]), .prepare)
    XCTAssertThrowsError(try Gate15ToolCommand.parse(["resume", "--root", "/var/root"]))
    let diagnostic = try Gate15QualificationTool.execute(.diagnose)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: diagnostic) as? [String: Any])
    XCTAssertEqual(json["claim"] as? String, "none")
    XCTAssertEqual(json["formal"] as? Bool, false)
  }

  func testStatusOnlyAttachesToTheSameRunnerStartIdentity() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("hostwright-phase09-gate15-status-\(UUID().uuidString)")
    let rootPath = parent.appendingPathComponent("phase09-gate15-status-root")
    try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootPath.path)
    let root = try canonical(rootPath)
    let lockURL = root.appendingPathComponent("active-run-v1")
    try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockURL.path)
    defer { try? FileManager.default.removeItem(at: parent) }
    let identity = try Gate15SystemProcessIdentityProviderForTests.current()
    let state: [String: Any] = [
      "schema": "hostwright.phase09.gate15.runner-state.v1",
      "status": "running",
      "runnerPID": identity.pid,
      "runnerStartIdentity": identity.startIdentity,
    ]
    let stateURL = root.appendingPathComponent("runner-state-v1.json")
    try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stateURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    let status = try Gate15QualificationTool.execute(
      .status(root: root),
      environment: ["HOSTWRIGHT_PHASE09_HARNESS_TESTING": "1"]
    )
    let statusJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: status) as? [String: Any])
    XCTAssertEqual(statusJSON["readOnly"] as? Bool, true)

    var replaced = state
    replaced["runnerStartIdentity"] = "replacement-start"
    try JSONSerialization.data(withJSONObject: replaced, options: [.sortedKeys]).write(to: stateURL)
    XCTAssertThrowsError(try Gate15QualificationTool.execute(
      .status(root: root),
      environment: ["HOSTWRIGHT_PHASE09_HARNESS_TESTING": "1"]
    )) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "runnerReplaced")
    }
  }

  func testFormalRunRequiresObservationPrerequisite() throws {
    XCTAssertThrowsError(try Gate15QualificationTool.execute(
      .run(root: URL(fileURLWithPath: "/var/empty-gate15-root", isDirectory: true)),
      environment: [:]
    )) { error in
      XCTAssertEqual((error as? Gate15QualificationError)?.code, "missingLaunchAuthorization")
    }
  }

  private func observation(
    at ticks: UInt64,
    seconds: Int,
    coverage: [Gate15SleepWakeInterval] = [],
    binding: Gate15BoundaryBinding? = nil,
    timestampOverride: String? = nil
  ) -> Gate15Observation {
    Gate15Observation(
      observedAtUTC: timestampOverride ?? timestamp(seconds),
      continuousTicks: ticks,
      bootSessionID: "boot-session-1",
      runner: Gate15ProcessIdentity(pid: 101, startIdentity: "runner-1"),
      daemon: Gate15DaemonIdentity(pid: 202, generation: 1, startIdentity: "daemon-1"),
      executable: Gate15SignedExecutableIdentity(
        sha256: "sha256:" + String(repeating: "a", count: 64),
        cdHash: String(repeating: "b", count: 40),
        teamID: "TEAMID",
        identifier: "dev.hostwright.gate15"
      ),
      stateDatabase: Gate15StateDatabaseIdentity(
        identityDigest: "sha256:" + String(repeating: "c", count: 64),
        sizeBytes: 1024,
        integrity: "verified",
        schema: 21
      ),
      runtime: Gate15RuntimeIdentity(
        runtimeUUID: "runtime-uuid-1",
        project: "phase09-gate15",
        imageDigest: "sha256:" + String(repeating: "d", count: 64),
        inventoryDigest: "sha256:" + String(repeating: "e", count: 64)
      ),
      metrics: Gate15Metrics(
        rssBytes: 1024,
        fileDescriptorCount: 12,
        operationCount: UInt64(max(seconds, 0)),
        activeMutationGroups: 0,
        retryCount: 0
      ),
      sleepWakeCoverage: coverage,
      boundaryBinding: binding
    )
  }

  private func timestamp(_ seconds: Int) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let base = try! XCTUnwrap(formatter.date(from: "2026-08-05T00:00:00Z"))
    return formatter.string(from: base.addingTimeInterval(TimeInterval(seconds)))
  }

  private func formalObservation(
    at ticks: UInt64,
    seconds: Int,
    coverage: [Gate15SleepWakeInterval] = [],
    binding: Gate15BoundaryBinding
  ) throws -> Gate15Observation {
    let base = observation(at: ticks, seconds: seconds, coverage: coverage, binding: binding)
    return base.with(
      sleepWakeCoverage: coverage,
      boundaryBinding: binding,
      independentReceipt: try trustedObservation(for: base).receipt
    )
  }

  private func formalCoverage(
    start: UInt64,
    end: UInt64,
    sleepID: String,
    wakeID: String
  ) throws -> [Gate15SleepWakeInterval] {
    let unsigned = Gate15SleepWakeInterval(
      sleepStartUTC: timestamp(Int(start)),
      wakeUTC: timestamp(Int(end)),
      continuousStartTicks: start,
      continuousEndTicks: end,
      sleepEventID: sleepID,
      wakeEventID: wakeID,
      source: Gate15SleepWakeEvent.authenticatedSource,
      observerIdentity: "macos-system-observer-v1:formal-fixture",
      sleepObserverReceiptDigest: "",
      wakeObserverReceiptDigest: ""
    )
    let withReceipts = Gate15SleepWakeInterval(
      sleepStartUTC: unsigned.sleepStartUTC,
      wakeUTC: unsigned.wakeUTC,
      continuousStartTicks: unsigned.continuousStartTicks,
      continuousEndTicks: unsigned.continuousEndTicks,
      sleepEventID: unsigned.sleepEventID,
      wakeEventID: unsigned.wakeEventID,
      source: unsigned.source,
      observerIdentity: unsigned.observerIdentity,
      sleepObserverReceiptDigest: try unsigned.observerReceiptDigestValue(kind: "sleep"),
      wakeObserverReceiptDigest: try unsigned.observerReceiptDigestValue(kind: "wake")
    )
    return [Gate15SleepWakeInterval(
      sleepStartUTC: withReceipts.sleepStartUTC,
      wakeUTC: withReceipts.wakeUTC,
      continuousStartTicks: withReceipts.continuousStartTicks,
      continuousEndTicks: withReceipts.continuousEndTicks,
      sleepEventID: withReceipts.sleepEventID,
      wakeEventID: withReceipts.wakeEventID,
      source: withReceipts.source,
      observerIdentity: withReceipts.observerIdentity,
      sleepObserverReceiptDigest: withReceipts.sleepObserverReceiptDigest,
      wakeObserverReceiptDigest: withReceipts.wakeObserverReceiptDigest,
      authenticationDigest: try withReceipts.authenticationDigestValue()
    )]
  }

  private func appendFrozenFormalSamples(
    to ledger: inout Gate15ContinuityLedger,
    binding: Gate15BoundaryBinding,
    forgedAuthenticationDigest: String?
  ) throws {
    for sequence in 0..<Gate15Contract.frozen.requiredSampleCount {
      let index = UInt64(sequence)
      let ticks = index.multipliedReportingOverflow(by: 300).partialValue
        &+ (sequence == 0 ? 0 : 300)
      var coverage: [Gate15SleepWakeInterval] = []
      if sequence == 1 {
        let unsigned = Gate15SleepWakeInterval(
          sleepStartUTC: timestamp(300),
          wakeUTC: timestamp(599),
          continuousStartTicks: 300,
          continuousEndTicks: 600,
          sleepEventID: "sleep-1",
          wakeEventID: "wake-1",
          source: Gate15SleepWakeEvent.authenticatedSource,
          observerIdentity: "macos-system-observer-v1:formal-fixture",
          sleepObserverReceiptDigest: "",
          wakeObserverReceiptDigest: ""
        )
        let sleepObserverReceiptDigest = try unsigned.observerReceiptDigestValue(kind: "sleep")
        let wakeObserverReceiptDigest = try unsigned.observerReceiptDigestValue(kind: "wake")
        let withObserverReceipts = Gate15SleepWakeInterval(
          sleepStartUTC: unsigned.sleepStartUTC,
          wakeUTC: unsigned.wakeUTC,
          continuousStartTicks: unsigned.continuousStartTicks,
          continuousEndTicks: unsigned.continuousEndTicks,
          sleepEventID: unsigned.sleepEventID,
          wakeEventID: unsigned.wakeEventID,
          source: unsigned.source,
          observerIdentity: unsigned.observerIdentity,
          sleepObserverReceiptDigest: sleepObserverReceiptDigest,
          wakeObserverReceiptDigest: wakeObserverReceiptDigest
        )
        let authenticationDigest: String
        if let forgedAuthenticationDigest {
          authenticationDigest = forgedAuthenticationDigest
        } else {
          authenticationDigest = try withObserverReceipts.authenticationDigestValue()
        }
        coverage = [Gate15SleepWakeInterval(
          sleepStartUTC: withObserverReceipts.sleepStartUTC,
          wakeUTC: withObserverReceipts.wakeUTC,
          continuousStartTicks: withObserverReceipts.continuousStartTicks,
          continuousEndTicks: withObserverReceipts.continuousEndTicks,
          sleepEventID: withObserverReceipts.sleepEventID,
          wakeEventID: withObserverReceipts.wakeEventID,
          source: withObserverReceipts.source,
          observerIdentity: withObserverReceipts.observerIdentity,
          sleepObserverReceiptDigest: withObserverReceipts.sleepObserverReceiptDigest,
          wakeObserverReceiptDigest: withObserverReceipts.wakeObserverReceiptDigest,
          authenticationDigest: authenticationDigest
        )]
      }
      let sampleObservation = observation(
        at: ticks,
        seconds: Int(ticks),
        coverage: coverage,
        binding: binding
      )
      let unsignedReceipt = try Gate15IndependentObservationReceipt.make(
        for: sampleObservation,
        observerIdentity: "macos-system-observer-v1:formal-fixture"
      )
      let receipt = Gate15IndependentObservationReceipt(
        source: unsignedReceipt.source,
        observerIdentity: unsignedReceipt.observerIdentity,
        inventoryDigest: unsignedReceipt.inventoryDigest,
        daemonStateDigest: unsignedReceipt.daemonStateDigest,
        executableIdentityDigest: unsignedReceipt.executableIdentityDigest,
        executableReceiptDigest: unsignedReceipt.executableReceiptDigest,
        daemonReceiptDigest: unsignedReceipt.daemonReceiptDigest,
        stateReceiptDigest: unsignedReceipt.stateReceiptDigest,
        containerReceiptDigest: unsignedReceipt.containerReceiptDigest,
        runtimeReceiptDigest: unsignedReceipt.runtimeReceiptDigest,
        receiptDigest: unsignedReceipt.receiptDigest,
        authorizationDigest: "sha256:" + String(repeating: "0", count: 64)
      )
      _ = try ledger.append(sampleObservation.with(
        sleepWakeCoverage: coverage,
        boundaryBinding: binding,
        independentReceipt: receipt
      ))
    }
  }

  private func trustedObservation(
    for observation: Gate15Observation,
    inventoryDigest: String? = nil,
    daemonStateDigest: String? = nil,
    executableIdentityDigest: String? = nil
  ) throws -> Gate15TrustedObservation {
    let receipt = try Gate15IndependentObservationReceipt.make(
      for: observation,
      observerIdentity: "macos-system-observer-v1:test-fixture"
    )
    let unsigned = Gate15TrustedObservation(
      observation: observation,
      inventoryDigest: inventoryDigest ?? observation.runtime.inventoryDigest,
      daemonStateDigest: daemonStateDigest ?? observation.stateDatabase.identityDigest,
      executableIdentityDigest: executableIdentityDigest ?? observation.executable.sha256,
      receipt: receipt,
      authorizationDigest: ""
    )
    let authorizationDigest = try unsigned.authorizationDigestValue()
    let authenticatedReceipt = Gate15IndependentObservationReceipt(
      source: receipt.source,
      observerIdentity: receipt.observerIdentity,
      inventoryDigest: receipt.inventoryDigest,
      daemonStateDigest: receipt.daemonStateDigest,
      executableIdentityDigest: receipt.executableIdentityDigest,
      executableReceiptDigest: receipt.executableReceiptDigest,
      daemonReceiptDigest: receipt.daemonReceiptDigest,
      stateReceiptDigest: receipt.stateReceiptDigest,
      containerReceiptDigest: receipt.containerReceiptDigest,
      runtimeReceiptDigest: receipt.runtimeReceiptDigest,
      receiptDigest: receipt.receiptDigest,
      authorizationDigest: authorizationDigest
    )
    return Gate15TrustedObservation(
      observation: observation,
      inventoryDigest: unsigned.inventoryDigest,
      daemonStateDigest: unsigned.daemonStateDigest,
      executableIdentityDigest: unsigned.executableIdentityDigest,
      receipt: authenticatedReceipt,
      authorizationDigest: authorizationDigest
    )
  }

  private func canonical(_ url: URL) throws -> URL {
    guard let pointer = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer), isDirectory: url.hasDirectoryPath)
  }
}

private struct FakeClock: Gate15Clock {
  let ticksPerSecond: UInt64 = 1

  func reading() throws -> Gate15ClockReading {
    Gate15ClockReading(continuousTicks: 0, wallClockUTC: "2026-08-05T00:00:00Z", bootSessionID: "test")
  }

  func wait(until ticks: UInt64) throws {}
}

private struct FakeIdentityProvider: Gate15ProcessIdentityProvider {
  func current() throws -> Gate15ProcessIdentity { Gate15ProcessIdentity(pid: 1, startIdentity: "test") }
  func lookup(pid: Int32) throws -> Gate15ProcessIdentity { try current() }
}

private struct FakeObservationProvider: Gate15ObservationProvider {
  func observation(for reading: Gate15ClockReading, runner: Gate15ProcessIdentity) throws -> Gate15Observation {
    throw Gate15QualificationError("unused", "test provider must not run in test mode.")
  }
}

private enum Gate15SystemProcessIdentityProviderForTests {
  static func current() throws -> Gate15ProcessIdentity {
    try Gate15SystemProcessIdentityProvider().current()
  }
}
