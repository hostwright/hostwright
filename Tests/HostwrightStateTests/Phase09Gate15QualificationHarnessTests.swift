import Darwin
import Foundation
import XCTest

final class Phase09Gate15QualificationHarnessTests: XCTestCase {
  private var repository: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var qualificationHarness: URL {
    repository.appendingPathComponent("scripts/phase09-gate15-qualification.sh")
  }

  private var liveHarness: URL {
    repository.appendingPathComponent("scripts/phase09-gate15-live.sh")
  }

  func testContractDeclaresFrozenContinuityAndSerialEvidence() throws {
    let result = try run(["contract"])
    XCTAssertEqual(result.status, 0, result.stderr)
    for required in [
      "Gate 15 — 93.75%",
      "mach_continuous_time",
      "259200",
      "300-second",
      "864",
      "U/I/L/M/S/R",
      "canonical SHA-256 chained append-only samples",
      "No elapsed-time resume exists",
    ] {
      XCTAssertTrue(result.stdout.contains(required), "missing Gate 15 contract: \(required)")
    }
  }

  func testPrepareWritesPrivateDigestBoundSkeletonWithoutClaimingPassage() throws {
    try withRoot { root, environment in
      let result = try run(["prepare", "15"], environment: environment)
      XCTAssertEqual(result.status, 0, result.stderr)
      let manifest = try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("manifest-v1.json"))
      ) as? [String: Any]
      XCTAssertEqual(manifest?["schema"] as? String, "hostwright.phase09.gate15.qualification.manifest.v1")
      XCTAssertEqual(manifest?["gate"] as? Int, 15)
      XCTAssertEqual(manifest?["status"] as? String, "prepared")
      XCTAssertEqual(manifest?["claim"] as? String, "none")
      XCTAssertEqual(manifest?["formal"] as? Bool, false)
      XCTAssertEqual(manifest?["testOnly"] as? Bool, true)
      XCTAssertEqual(manifest?["certificateFingerprint"] as? String, "testing-cms-certificate")
      XCTAssertEqual(manifest?["teamID"] as? String, "testing")
      XCTAssertEqual(manifest?["requiredSampleCount"] as? Int, 865)
      XCTAssertEqual(try permissions(root), 0o700)
      for file in [
        "manifest-v1.json", "dependency-evidence-v1.json", "state-v1.tsv",
        "ownership-v1.tsv", "toolchain-v1.txt", "signed-executables-v1.tsv"
      ] {
        XCTAssertEqual(try permissions(root.appendingPathComponent(file)), 0o600, file)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("evidence-v1.cms").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
    }
  }

  func testTestModeCannotManufacture72HourPassageAndPreservesLocks() throws {
    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "15"], environment: environment).status, 0)
      let result = try run(["run", "15"], environment: environment)
      XCTAssertEqual(result.status, 70, result.stderr)
      let cellError = try String(
        contentsOf: root.appendingPathComponent("cell-03.stderr.log"), encoding: .utf8)
      XCTAssertTrue(cellError.contains("test mode cannot manufacture"), cellError)
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("failure-v1.tsv").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("run-started-v1.json").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(
        atPath: root.deletingLastPathComponent().appendingPathComponent(".phase09-gate15-active-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("evidence-v1.cms").path))
    }
  }

  func testForcedCellFailureFreezesRootAndDoesNotRunLaterCells() throws {
    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "15"], environment: environment).status, 0)
      var forced = environment
      forced["HOSTWRIGHT_PHASE09_HARNESS_TEST_FORCE_FAILURE"] = "1"
      let result = try run(["run", "15"], environment: forced)
      XCTAssertEqual(result.status, 47, result.stderr)
      XCTAssertTrue(result.stderr.contains("cell 1 failed"), result.stderr)
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-01.stdout.log").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-02.stdout.log").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("failure-v1.tsv").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
    }
  }

  func testDuplicateRunAndChangedEvidenceAreRejectedBeforeCells() throws {
    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "15"], environment: environment).status, 0)
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("active-run-v1"), withIntermediateDirectories: false)
      let duplicate = try run(["run", "15"], environment: environment)
      XCTAssertNotEqual(duplicate.status, 0)
      XCTAssertTrue(duplicate.stderr.contains("active Gate 15 qualification"), duplicate.stderr)
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-01.stdout.log").path))
    }

    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "15"], environment: environment).status, 0)
      let marker = root.appendingPathComponent("run-started-v1.json")
      let identity = "v1.\(String(repeating: "a", count: 64)).\(String(repeating: "b", count: 64)).1.1"
      try Data("{\"runnerPID\":99999999,\"runnerStartIdentity\":\"\(identity)\",\"status\":\"runner-started\"}\n".utf8).write(to: marker)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
      let stale = try run(["run", "15"], environment: environment)
      XCTAssertEqual(stale.status, 73, stale.stderr)
      XCTAssertTrue(stale.stderr.contains("permanently frozen"), stale.stderr)
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("failure-v1.tsv").path))
      let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest-v1.json"))) as? [String: Any]
      XCTAssertEqual(manifest?["status"] as? String, "failed")
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
    }
  }

  func testLiveRunMarkerRequiresTheKernelDerivedIdentityForTheSamePID() throws {
    let markerIdentity = strongIdentity("a", "b", seconds: 1, microseconds: 2)
    let otherIdentity = strongIdentity("c", "d", seconds: 3, microseconds: 4)

    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "15"], environment: environment).status, 0)
      try seedLiveRun(root: root, processID: getpid(), identity: markerIdentity)
      var matching = environment
      matching["HOSTWRIGHT_PHASE09_HARNESS_TEST_PROCESS_IDENTITY"] = markerIdentity
      let duplicate = try run(["run", "15"], environment: matching)
      XCTAssertEqual(duplicate.status, 75, duplicate.stderr)
      XCTAssertTrue(duplicate.stderr.contains("already live runner"), duplicate.stderr)
    }

    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "15"], environment: environment).status, 0)
      try seedLiveRun(root: root, processID: getpid(), identity: markerIdentity)
      var replaced = environment
      replaced["HOSTWRIGHT_PHASE09_HARNESS_TEST_PROCESS_IDENTITY"] = otherIdentity
      let stale = try run(["run", "15"], environment: replaced)
      XCTAssertEqual(stale.status, 73, stale.stderr)
      XCTAssertTrue(stale.stderr.contains("permanently frozen"), stale.stderr)
      XCTAssertTrue(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("failure-v1.tsv").path))
    }

    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "15"], environment: environment).status, 0)
      try seedLiveRun(
        root: root, processID: getpid(), identity: markerIdentity, toolMode: 0o777)
      var tampered = environment
      tampered["HOSTWRIGHT_PHASE09_HARNESS_TEST_PROCESS_IDENTITY"] = markerIdentity
      let stale = try run(["run", "15"], environment: tampered)
      XCTAssertEqual(stale.status, 73, stale.stderr)
      XCTAssertTrue(stale.stderr.contains("permanently frozen"), stale.stderr)
    }

    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "15"], environment: environment).status, 0)
      try seedLiveRun(
        root: root,
        processID: getpid(),
        identity: markerIdentity,
        toolDigest: "tampered-qualification-tool")
      var tampered = environment
      tampered["HOSTWRIGHT_PHASE09_HARNESS_TEST_PROCESS_IDENTITY"] = markerIdentity
      let stale = try run(["run", "15"], environment: tampered)
      XCTAssertEqual(stale.status, 73, stale.stderr)
      XCTAssertTrue(stale.stderr.contains("permanently frozen"), stale.stderr)
    }

    for stringifiedField in ["toolDevice", "toolInode", "toolMode"] {
      try withRoot { root, environment in
        XCTAssertEqual(try run(["prepare", "15"], environment: environment).status, 0)
        try seedLiveRun(
          root: root,
          processID: getpid(),
          identity: markerIdentity,
          stringifiedToolField: stringifiedField)
        var tampered = environment
        tampered["HOSTWRIGHT_PHASE09_HARNESS_TEST_PROCESS_IDENTITY"] = markerIdentity
        let stale = try run(["run", "15"], environment: tampered)
        XCTAssertEqual(stale.status, 73, "\(stringifiedField): \(stale.stderr)")
        XCTAssertTrue(
          stale.stderr.contains("permanently frozen"),
          "\(stringifiedField): \(stale.stderr)")
      }
    }

    let source = try String(contentsOf: qualificationHarness, encoding: .utf8)
    XCTAssertTrue(source.contains("process-identity --pid \"$pid\""))
    XCTAssertTrue(source.contains("\"$live_start\" == \"$marker_start\""))
    XCTAssertTrue(source.contains(".toolDigest // empty"))
    XCTAssertTrue(source.contains(".toolMode // -1"))
  }

  func testElapsedResumeIsRejectedBeforeCells() throws {
    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "15"], environment: environment).status, 0)
      let samples = root.appendingPathComponent("samples-v1.ndjson")
      try Data("partial-sample\n".utf8).write(to: samples)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: samples.path)

      let result = try run(["run", "15"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("elapsed-time resume"), result.stderr)
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-01.stdout.log").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
    }
  }

  func testStatusIsReadOnlyAndNoGlobalOrCrossPhaseActionRunsInTestMode() throws {
    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "15"], environment: environment).status, 0)
      let before = try Data(contentsOf: root.appendingPathComponent("state-v1.tsv"))
      let result = try run(["status", "15"], environment: environment)
      XCTAssertEqual(result.status, 0, result.stderr)
      XCTAssertTrue(result.stdout.contains("\"readOnly\":true"), result.stdout)
      XCTAssertTrue(result.stdout.contains("\"claim\":\"none\""), result.stdout)
      XCTAssertEqual(before, try Data(contentsOf: root.appendingPathComponent("state-v1.tsv")))

      let hardlink = root.appendingPathComponent("state-v1-hardlink")
      try FileManager.default.linkItem(
        atPath: root.appendingPathComponent("state-v1.tsv").path,
        toPath: hardlink.path
      )
      let hardlinkStatus = try run(["status", "15"], environment: environment)
      XCTAssertNotEqual(hardlinkStatus.status, 0, hardlinkStatus.stdout)
      try FileManager.default.removeItem(at: hardlink)

      let symlink = root.appendingPathComponent("evidence-v1.sha256")
      try FileManager.default.createSymbolicLink(
        atPath: symlink.path,
        withDestinationPath: root.appendingPathComponent("state-v1.tsv").path
      )
      let symlinkRun = try run(["run", "15"], environment: environment)
      XCTAssertNotEqual(symlinkRun.status, 0, symlinkRun.stdout)
    }

    let qualification = try String(contentsOf: qualificationHarness, encoding: .utf8)
    let live = try String(contentsOf: liveHarness, encoding: .utf8)
    let tool = try String(
      contentsOf: repository.appendingPathComponent("Qualification/HostwrightPhase09QualificationTool/main.swift"),
      encoding: .utf8
    )
    let combined = qualification + "\n" + live + "\n" + tool
    for forbidden in ["rm -rf", "gh ", "git push", "git merge", "container system start", "Phase 08", "phase08"] {
      XCTAssertFalse(combined.contains(forbidden), "Gate 15 may not use \(forbidden)")
    }
  }

  func testScriptsFreezeIdentityCoverageAndNoElapsedResume() throws {
    let qualification = try String(contentsOf: qualificationHarness, encoding: .utf8)
    let live = try String(contentsOf: liveHarness, encoding: .utf8)
    let tool = try String(
      contentsOf: repository.appendingPathComponent("Qualification/HostwrightPhase09QualificationTool/main.swift"),
      encoding: .utf8
    )
    for required in [
      "HOSTWRIGHT_NOTARY_PROFILE",
      "HOSTWRIGHT_GATE15_SIGNING_FINGERPRINT",
      "HOSTWRIGHT_GATE15_SIGNED_EXECUTABLES",
      "HOSTWRIGHT_GATE15_RUNTIME_SETUP",
      "dependency-evidence-v1.json",
      "owned-runtime-v1.tsv",
      "gate-active-run-v1-info.tsv",
      "evidence-v1.sha256",
      "evidence-v1.cms",
      "security cms -S",
      "security cms -D",
      "notarization-receipt-v1.json",
      "stapled-receipt-v1.json",
      "certificateFingerprint",
      "revalidate_dependencies",
      "validate_script_boundary",
      "active-run-v1",
      "failure-v1.tsv",
      "for cell in 1 2 3 4 5 6",
      "mach_continuous_time",
      "samples-v1.ndjson",
      "sampleSHA256",
      "sleepWakeCoverage",
      "HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR",
      "HOSTWRIGHT_GATE15_CERTIFICATE_FINGERPRINT",
      "launch-authorization-v1.cms",
      "launch-request-v1.json",
      "kern.bootsessionuuid",
      "O_NOFOLLOW",
      "O_CREAT",
      "O_EXCL",
      "/usr/bin/python3",
      "run-started-v1.json",
      "revalidate-sample",
      "git diff --binary HEAD",
      "git ls-files --others",
      "openssl cms -verify",
      "require_checksum_entry",
      "notarizationReceiptSHA256",
      "runStartedDigest",
      "dependencyValidatorDevice",
      "boundaryValidatorInode",
      "requiredSampleCountOverflowed",
      "no-backfill",
      "systemContainer",
      "owned=gate15",
      "finalizing",
      "finalLedgerDigest",
      "validate_complete_sample_ledger",
      "independentReceipt",
      "observerIdentity",
      "macos-system-observer-v1",
      "sleepObserverReceiptDigest",
      "providerSelfAttestation",
      "atomic_rename_exclusive",
      "renameatx_np",
      "stat -f '%l'",
      "on_signal INT 130",
      "on_signal TERM 143",
      "on_signal HUP 129",
      "status verification refuses to repair",
    ] {
      XCTAssertTrue(
        qualification.contains(required) || live.contains(required) || tool.contains(required),
        "missing Gate 15 guard: \(required)"
      )
    }
    XCTAssertTrue(live.contains("container list --all --format json"))
    XCTAssertTrue(live.contains("container delete --force"))
    XCTAssertTrue(live.contains("dev.hostwright.project"))
    XCTAssertTrue(live.contains("exact pinned runtime"))
    XCTAssertFalse(qualification.contains("--resume"))
    XCTAssertFalse(live.contains("--resume"))
    XCTAssertFalse(qualification.contains("rm -rf"))
    XCTAssertFalse(live.contains("rm -rf"))
  }

  func testSuccessfulLockReleaseVerifiesOwnedInfoBeforeRemovingLocks() throws {
    let qualification = try String(contentsOf: qualificationHarness, encoding: .utf8)
    let verify = try XCTUnwrap(qualification.range(of: "validate_lock_info_identity \"$gate_info\""))
    let unlink = try XCTUnwrap(qualification.range(of: "/bin/unlink \"$gate_info\""))
    let gateRmdir = try XCTUnwrap(qualification.range(of: "/bin/rmdir \"$gate_lock\""))
    let rootRmdir = try XCTUnwrap(qualification.range(of: "/bin/rmdir \"$root/active-run-v1\""))
    XCTAssertLessThan(verify.lowerBound, unlink.lowerBound)
    XCTAssertLessThan(unlink.lowerBound, gateRmdir.lowerBound)
    XCTAssertLessThan(gateRmdir.lowerBound, rootRmdir.lowerBound)
    XCTAssertTrue(qualification.contains("gateLockInfoDevice"))
    XCTAssertTrue(qualification.contains("gateLockInfoInode"))
    XCTAssertTrue(qualification.contains("Gate 15 lock info content identity changed during release"))
    XCTAssertTrue(qualification.contains("final_state_exposed=1"))
    XCTAssertTrue(qualification.contains("locks_released=1"))
    XCTAssertFalse(qualification.contains("/bin/ln "))
  }

  func testCanonicalToolBypassIsRejectedByWrapperAndTool() throws {
    let live = try String(contentsOf: liveHarness, encoding: .utf8)
    let qualification = try String(contentsOf: qualificationHarness, encoding: .utf8)
    let tool = try String(
      contentsOf: repository.appendingPathComponent("Qualification/HostwrightPhase09QualificationTool/main.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(live.contains("readonly canonical_tool_path='/Users/dev/Documents/hostwright-phase09/.build/release/HostwrightPhase09QualificationTool'"))
    XCTAssertTrue(live.contains("HOSTWRIGHT_GATE15_TOOL\" == \"$canonical_tool_path"))
    XCTAssertTrue(live.contains("\"$canonical_tool_path\" run --root \"$root\""))
    XCTAssertFalse(live.contains("\"$HOSTWRIGHT_GATE15_TOOL\" run --root"))
    XCTAssertTrue(qualification.contains("HOSTWRIGHT_GATE15_TOOL=\"${HOSTWRIGHT_GATE15_TOOL:-$canonical_tool_path}\""))
    XCTAssertTrue(tool.contains("environment[\"HOSTWRIGHT_GATE15_TOOL\"] == Gate15CanonicalTool.path"))
    XCTAssertTrue(tool.contains("Gate15ValidatorBinding.validateTool"))
    XCTAssertTrue(tool.contains("currentPath == authorization.toolPath"))
  }

  func testCapturedCellsUseSanitizedPinnedCommandsAgainstPathSpoofing() throws {
    let qualification = try String(contentsOf: qualificationHarness, encoding: .utf8)
    let live = try String(contentsOf: liveHarness, encoding: .utf8)
    XCTAssertTrue(qualification.contains("readonly formal_path='/usr/bin:/bin:/usr/sbin:/sbin'"))
    XCTAssertTrue(qualification.contains("child_env[\"PATH\"] = \"/usr/bin:/bin:/usr/sbin:/sbin\""))
    XCTAssertTrue(qualification.contains("BASH_ENV"))
    XCTAssertTrue(qualification.contains("DYLD_INSERT_LIBRARIES"))
    XCTAssertTrue(qualification.contains("formal_command_snapshot"))
    for command in ["/usr/bin/git", "/usr/bin/stat", "/usr/bin/swift"] {
      XCTAssertTrue(qualification.contains(command), "missing pinned command: \(command)")
    }
    let result = try run(["contract"], environment: ["PATH": "/private/var/folders/path-spoof"])
    XCTAssertEqual(result.status, 0, result.stderr)
    XCTAssertTrue(result.stdout.contains("mach_continuous_time"))
    XCTAssertTrue(live.contains("export PATH=\"$formal_path\""))
  }

  func testProviderRuntimeAndSleepFieldsRequireIndependentTrustedObservation() throws {
    let tool = try String(
      contentsOf: repository.appendingPathComponent("Qualification/HostwrightPhase09QualificationTool/main.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(tool.contains("Gate15ObservationBinding.validate"))
    XCTAssertTrue(tool.contains("provider == trustedObservation"))
    XCTAssertTrue(tool.contains("trustedObservation.runtime.inventoryDigest"))
    XCTAssertTrue(tool.contains("trustedObservation.stateDatabase.identityDigest"))
    XCTAssertTrue(tool.contains("trustedObservation.executable.sha256"))
    XCTAssertTrue(tool.contains("sleepEventSelfAttestation"))
    XCTAssertTrue(tool.contains("Gate15CommandSleepWakeEventProvider"))
    XCTAssertTrue(tool.contains("mach_continuous_time"))
    XCTAssertTrue(tool.contains("no-backfill"))
  }

  func testFailureTrapIsArmedBeforeTheEarliestLockTransition() throws {
    let qualification = try String(contentsOf: qualificationHarness, encoding: .utf8)
    let trap = try XCTUnwrap(qualification.range(of: "trap on_exit EXIT"))
    let attempt = try XCTUnwrap(qualification.range(of: "  write_run_attempt\n  validate_live_boundary"))
    let boundary = try XCTUnwrap(qualification.range(of: "  validate_live_boundary\n  local lock"))
    let lock = try XCTUnwrap(qualification.range(of: "/bin/mkdir \"$lock\""))
    XCTAssertLessThan(trap.lowerBound, attempt.lowerBound)
    XCTAssertLessThan(trap.lowerBound, boundary.lowerBound)
    XCTAssertLessThan(trap.lowerBound, lock.lowerBound)
    XCTAssertTrue(qualification.contains("freeze_interrupted_root"))
    XCTAssertTrue(qualification.contains("run-attempt-v1.json"))
    XCTAssertTrue(qualification.contains("Gate 15 interrupted before final evidence publication"))
    XCTAssertTrue(qualification.contains("final_state_exposed=0"))
    XCTAssertTrue(qualification.contains("trap 'on_signal INT 130' INT"))
    XCTAssertTrue(qualification.contains("trap 'on_signal TERM 143' TERM"))
    XCTAssertTrue(qualification.contains("trap 'on_signal HUP 129' HUP"))
  }

  func testReuseAndFinalPublicationRevalidateBindingsBeforeReleasingLocks() throws {
    let qualification = try String(contentsOf: qualificationHarness, encoding: .utf8)
    let live = try String(contentsOf: liveHarness, encoding: .utf8)
    let tool = try String(
      contentsOf: repository.appendingPathComponent("Qualification/HostwrightPhase09QualificationTool/main.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(qualification.contains("validate_complete_sample_ledger reuse"))
    XCTAssertTrue(qualification.contains("validate_consumed_launch_authorization"))
    XCTAssertTrue(qualification.contains("pass_publication_started=1"))
    XCTAssertTrue(qualification.contains("final_state_exposed=1"))
    XCTAssertTrue(qualification.contains("final_state_exposed\" == 1"))
    let run = try XCTUnwrap(qualification.range(of: "run_qualification() {"))
    let runBody = String(qualification[run.lowerBound...])
    let publish = try XCTUnwrap(runBody.range(of: "publish_sealed_evidence"))
    let release = try XCTUnwrap(runBody.range(of: "release_locks"))
    XCTAssertLessThan(publish.lowerBound, release.lowerBound)
    XCTAssertTrue(qualification.contains("locks remain held until the atomic passed state is exposed"))
    XCTAssertTrue(live.contains("live_tool_pid"))
    XCTAssertTrue(live.contains("live_authorizer_pid"))
    XCTAssertTrue(live.contains("terminate_and_wait_live_children"))
    XCTAssertTrue(live.contains("os.killpg"))
    XCTAssertTrue(live.contains("wait \"$pid\""))
    XCTAssertTrue(tool.contains("requireActiveLocks: Bool = true"))
    XCTAssertTrue(tool.contains("allowPassedManifest: Bool = false"))
    XCTAssertTrue(tool.contains("status == \"passed\""))
  }

  func testCMSPublicationUsesExclusiveNoFollowTemporariesAndAtomicRename() throws {
    let qualification = try String(contentsOf: qualificationHarness, encoding: .utf8)
    let live = try String(contentsOf: liveHarness, encoding: .utf8)
    let tool = try String(
      contentsOf: repository.appendingPathComponent("Qualification/HostwrightPhase09QualificationTool/main.swift"),
      encoding: .utf8
    )
    for source in [qualification, live] {
      XCTAssertTrue(source.contains("os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW"))
      XCTAssertTrue(source.contains("write_private_temp_from_stdin"))
      XCTAssertTrue(source.contains("atomic_rename_exclusive"))
      XCTAssertTrue(source.contains("renameatx_np"))
      XCTAssertTrue(source.contains("stat -f '%l'"))
      XCTAssertFalse(source.contains("/bin/mv"))
      XCTAssertFalse(source.contains("/bin/ln "))
      XCTAssertFalse(source.contains("ln -f"))
      XCTAssertTrue(source.contains("-o /dev/stdout"))
    }
    XCTAssertTrue(tool.contains("O_CREAT | O_EXCL | O_NOFOLLOW"))
    XCTAssertTrue(tool.contains("renameatx_np"))
    XCTAssertTrue(tool.contains("RENAME_EXCL"))
    XCTAssertTrue(tool.contains("makePrivateTemporaryDirectory"))
    XCTAssertFalse(tool.contains(" link("))
    XCTAssertFalse(tool.contains("\nlink("))
  }

  func testQualificationToolIsNotPublishedAsAReleaseProduct() throws {
    let package = try String(contentsOf: repository.appendingPathComponent("Package.swift"), encoding: .utf8)
    let lint = try String(
      contentsOf: repository.appendingPathComponent("scripts/lint.sh"), encoding: .utf8)
    XCTAssertTrue(package.contains("name: \"HostwrightPhase09QualificationTool\""))
    XCTAssertTrue(package.contains("dependencies: [\"HostwrightCore\"]"))
    XCTAssertTrue(package.contains("path: \"Qualification/HostwrightPhase09QualificationTool\""))
    XCTAssertTrue(package.contains("name: \"HostwrightPhase09QualificationToolTests\""))
    XCTAssertFalse(package.contains(".executable(name: \"hostwright-phase09-qualification\""))
    XCTAssertTrue(lint.contains("swift package dump-package | python3 scripts/check-shipped-process-boundary.py"))
    XCTAssertTrue(lint.contains("scripts/check-shipped-process-boundary.py --self-test"))
  }

  private struct Result {
    let status: Int32
    let stdout: String
    let stderr: String
  }

  private func run(
    _ arguments: [String],
    environment: [String: String] = [:]
  ) throws -> Result {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [qualificationHarness.path] + arguments
    process.currentDirectoryURL = repository
    var merged = ProcessInfo.processInfo.environment
    merged.merge(environment) { _, new in new }
    process.environment = merged
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    return Result(
      status: process.terminationStatus,
      stdout: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      stderr: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
  }

  private func withRoot(_ body: (URL, [String: String]) throws -> Void) throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("hostwright-phase09-gate15-harness-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    let root = parent.appendingPathComponent(
      "phase09-gate15-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    defer { try? FileManager.default.removeItem(at: parent) }
    let canonicalParent = try canonical(parent)
    let canonicalRoot = try canonical(root)
    let environment = [
      "HOSTWRIGHT_PHASE09_HARNESS_TESTING": "1",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT": canonicalParent.path,
      "HOSTWRIGHT_PHASE09_GATE_ROOT": canonicalRoot.path,
    ]
    try body(canonicalRoot, environment)
  }

  private func seedLiveRun(
    root: URL,
    processID: Int32,
    identity: String,
    toolMode: Int = 0o755,
    toolDigest: String = "testing-qualification-tool",
    stringifiedToolField: String? = nil
  ) throws {
    let rootLock = root.appendingPathComponent("active-run-v1", isDirectory: true)
    let gateLock = root.deletingLastPathComponent()
      .appendingPathComponent(".phase09-gate15-active-v1", isDirectory: true)
    try FileManager.default.createDirectory(at: rootLock, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: gateLock, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootLock.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gateLock.path)
    var marker: [String: Any] = [
      "schema": "hostwright.phase09.gate15.run-started.v1",
      "runnerPID": Int(processID),
      "runnerStartIdentity": identity,
      "status": "runner-started",
      "root": root.path,
      "toolPath": "/Users/dev/Documents/hostwright-phase09/.build/release/HostwrightPhase09QualificationTool",
      "toolDevice": 0,
      "toolInode": 0,
      "toolMode": toolMode,
      "toolDigest": toolDigest,
    ]
    if let stringifiedToolField {
      marker[stringifiedToolField] = String(describing: marker[stringifiedToolField]!)
    }
    let state: [String: Any] = [
      "runnerPID": Int(processID),
      "runnerStartIdentity": identity,
      "status": "running",
    ]
    for (name, object) in [
      ("run-started-v1.json", marker),
      ("runner-state-v1.json", state),
    ] {
      let path = root.appendingPathComponent(name)
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: path)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
  }

  private func strongIdentity(
    _ path: Character, _ command: Character, seconds: UInt64, microseconds: UInt64
  ) -> String {
    "v1.\(String(repeating: String(path), count: 64)).\(String(repeating: String(command), count: 64)).\(seconds).\(microseconds)"
  }

  private func canonical(_ url: URL) throws -> URL {
    guard let pointer = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer), isDirectory: url.hasDirectoryPath)
  }

  private func permissions(_ url: URL) throws -> UInt16 {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
    return info.st_mode & 0o777
  }
}
