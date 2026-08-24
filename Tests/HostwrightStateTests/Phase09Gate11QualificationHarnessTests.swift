import Foundation
import XCTest

final class Phase09Gate11QualificationHarnessTests: XCTestCase {
  private var repository: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var qualificationHarness: URL {
    repository.appendingPathComponent("scripts/phase09-gate11-qualification.sh")
  }

  private var liveHarness: URL {
    repository.appendingPathComponent("scripts/phase09-gate11-live.sh")
  }

  private var entitlements: URL {
    repository.appendingPathComponent("scripts/phase09-xpc-provider.entitlements")
  }

  func testQualificationHarnessFixesSingleGateElevenRunAndSixSerialEvidenceCells() throws {
    let source = try String(contentsOf: qualificationHarness, encoding: .utf8)
    XCTAssertTrue(source.contains("readonly gate=11"))
    XCTAssertTrue(source.contains("Gate 11"))
    XCTAssertTrue(source.contains("for n in 1 2 3 4 5 6"))
    XCTAssertTrue(source.contains("U"))
    XCTAssertTrue(source.contains("I"))
    XCTAssertTrue(source.contains("L"))
    XCTAssertTrue(source.contains("M"))
    XCTAssertTrue(source.contains("S"))
    XCTAssertTrue(source.contains("R"))
    XCTAssertTrue(source.contains("cell_command"))
    XCTAssertTrue(source.contains("run_cell"))
    XCTAssertTrue(source.contains("phase09-gate11-live.sh"))
  }

  func testQualificationHarnessRejectsDuplicateGateAndRootRunsBeforeExecutingCells() throws {
    let source = try String(contentsOf: qualificationHarness, encoding: .utf8)
    XCTAssertTrue(source.contains(".phase09-gate11-active-v1"))
    XCTAssertTrue(source.contains("$root/active-run-v1"))
    XCTAssertTrue(source.contains("mkdir \"$lock\""))
    XCTAssertTrue(source.contains("mkdir \"$root/active-run-v1\""))
    XCTAssertTrue(source.contains("An active Gate 11 qualification already exists; do not duplicate it."))
    XCTAssertTrue(source.contains("progress is frozen and locks are preserved"))
    XCTAssertTrue(source.contains("Cell logs already exist; preserve this root and do not rerun."))
  }

  func testQualificationHarnessBindsSourceConfigurationAndToolchainAndRefusesInvalidReuse() throws {
    let source = try String(contentsOf: qualificationHarness, encoding: .utf8)
    for required in [
      "source_digest", "config_digest", "toolchain_digest", "revalidate_dependencies",
      "prepared evidence dependencies changed; preserve this root.",
      "completed evidence is incomplete or changed; preserve this root and do not rerun.",
      "Gate 11 evidence is valid and reused; no cells were rerun.",
      "source must be clean and committed", "manifest-v1.json", "state-v1.tsv",
      "ownership-v1.tsv", "cellOrder:[1,2,3,4,5,6]",
    ] {
      XCTAssertTrue(source.contains(required), "missing Gate 11 dependency/reuse invariant: \(required)")
    }
  }

  func testQualificationHarnessSealsEvidenceWithCMSAndCleansOnlyPinnedOwnedArtifacts() throws {
    let source = try String(contentsOf: qualificationHarness, encoding: .utf8)
    for required in [
      "evidence-v1.sha256", "evidence-v1.cms", "security cms -S", "security cms -D",
      "record_root", "record_artifact", "ownership-v1.tsv", "cleanup",
      "identity changed; cleanup is refused", "/bin/unlink", "/bin/rmdir",
    ] {
      XCTAssertTrue(source.contains(required), "missing Gate 11 evidence/cleanup invariant: \(required)")
    }
    XCTAssertFalse(source.contains("rm -rf"))
    XCTAssertFalse(source.contains("gh pr"))
  }

  func testLiveHarnessRequiresPinnedOwnedRootLedgerAndExactSandboxSigningInputs() throws {
    let source = try String(contentsOf: liveHarness, encoding: .utf8)
    let entitlementSource = try String(contentsOf: entitlements, encoding: .utf8)

    XCTAssertTrue(source.contains("dev.hostwright.xpc-provider"))
    XCTAssertTrue(source.contains("Developer ID Application: Dev Trivedi (993YC3JY4Q)"))
    XCTAssertTrue(source.contains("HOSTWRIGHT_XPC_LIVE_ROOT is required"))
    XCTAssertTrue(source.contains("HOSTWRIGHT_XPC_OWNERSHIP_LEDGER is required"))
    XCTAssertTrue(source.contains("HOSTWRIGHT_XPC_HOST_BIN is required"))
    XCTAssertTrue(source.contains("== 700"))
    XCTAssertTrue(source.contains("== 600"))
    XCTAssertTrue(source.contains("--entitlements \"$signing_entitlements\""))
    XCTAssertTrue(source.contains("The XPC service entitlement set is not the frozen sandbox-only contract."))
    XCTAssertTrue(source.contains("--identifier \"$service_id\""))
    XCTAssertTrue(source.contains("record_launchd"))
    XCTAssertTrue(source.contains("record_pid"))
    XCTAssertTrue(source.contains("cleanup is frozen"))
    XCTAssertFalse(source.contains("rm -rf"))

    XCTAssertTrue(entitlementSource.contains("<key>com.apple.security.app-sandbox</key>"))
    XCTAssertTrue(entitlementSource.contains("<true/>"))
    XCTAssertFalse(entitlementSource.contains("com.apple.security.network"))
    XCTAssertFalse(entitlementSource.contains("com.apple.security.files"))
    XCTAssertFalse(entitlementSource.contains("com.apple.security.keychain"))
  }

  func testLiveHarnessFailsClosedForNotarizationAndExercisesSignedBoundaryFailures() throws {
    let source = try String(contentsOf: liveHarness, encoding: .utf8)
    for required in [
      "HOSTWRIGHT_XPC_REQUIRE_NOTARY:-1", "HOSTWRIGHT_NOTARY_PROFILE is required for Gate 11 notarization",
      "xcrun notarytool submit", "xcrun stapler staple", "xcrun stapler validate",
      "spctl --assess", "wrong-identifier", "wrong-entitlement", "wrong-team", "wrong-client",
      "over-entitled", "over-entitled-malformed", "hang-timeout", "hang-cancel", "hang-revoke",
      "oversized", "malformed", "crash",
    ] {
      XCTAssertTrue(source.contains(required), "missing Gate 11 live fail-closed/adversarial contract: \(required)")
    }
  }

  func testGateElevenHarnessesCannotReferenceOrMutatePhaseEight() throws {
    let qualification = try String(contentsOf: qualificationHarness, encoding: .utf8)
    let live = try String(contentsOf: liveHarness, encoding: .utf8)
    let combined = qualification + "\n" + live
    for forbidden in ["phase08", "Phase 08", "hostwright-p08", "30476", "4c458005"] {
      XCTAssertFalse(combined.contains(forbidden), "Gate 11 must not inspect or mutate Phase 08: \(forbidden)")
    }
  }

  func testLiveHarnessStagesLaunchdJobsUnderOwnedInternalRoot() throws {
    let source = try String(contentsOf: liveHarness, encoding: .utf8)
    XCTAssertTrue(source.contains("HOSTWRIGHT_XPC_STAGING_ROOT is required"))
    XCTAssertTrue(source.contains("The XPC staging root is unsafe."))
    XCTAssertTrue(source.contains("The XPC staging root must be empty."))
    XCTAssertTrue(source.contains("record_staged"))
    XCTAssertTrue(source.contains("$staging_root/$name"))
    XCTAssertTrue(source.contains("Add :ProgramArguments:0 string $staged_service"))
    XCTAssertTrue(source.contains("/bin/cp -R \"$xpc\" \"$staged_xpc\""))
    XCTAssertTrue(source.contains("codesign --verify --strict \"$staged_xpc\""))
    XCTAssertTrue(source.contains("The staged $name XPC service binary is missing."))
    XCTAssertFalse(source.contains("Add :ProgramArguments:0 string $service\""))
  }

  func testStagedLaunchdMaterialIsDigestAndIdentityBoundToTheLedger() throws {
    let source = try String(contentsOf: liveHarness, encoding: .utf8)
    for required in [
      "sha256=$(sha \"$plist\")",
      "source_commit=$source_commit",
      "config_digest=$config_digest",
      "sha256=$(sha \"$staged_service\")",
      "HOSTWRIGHT_XPC_SOURCE_COMMIT is required",
      "HOSTWRIGHT_XPC_CONFIG_DIGEST is required",
      "The XPC source commit binding is invalid.",
      "The XPC configuration digest binding is invalid.",
    ] {
      XCTAssertTrue(source.contains(required), "missing staged-artifact ledger binding: \(required)")
    }
  }

  func testCleanupDetectsPlistTamperReapsProcessesAndProvesAbsence() throws {
    let source = try String(contentsOf: liveHarness, encoding: .utf8)
    for required in [
      "An owned XPC launchd plist digest changed; cleanup is frozen.",
      "kill -TERM \"$pid\"",
      "kill -KILL \"$pid\"",
      "did not terminate; cleanup is frozen.",
      "survived unlink; cleanup is frozen.",
      "A Gate 11 XPC launchd label remained loaded after cleanup.",
      "was not fully cleaned by ledgered removal.",
      "== 600 ]]",
      "|| die 'An owned XPC launchd plist changed; cleanup is frozen.'",
    ] {
      XCTAssertTrue(source.contains(required), "missing hardened cleanup invariant: \(required)")
    }
    let qualification = try String(contentsOf: qualificationHarness, encoding: .utf8)
    XCTAssertTrue(qualification.contains("gate11-xpc-staging"))
    XCTAssertTrue(qualification.contains("HOSTWRIGHT_XPC_STAGING_ROOT=\"$staging_root\""))
  }

  func testStagingRootValidationRejectsSymlinkPathRacesAndNoOwnerVolumes() throws {
    let source = try String(contentsOf: liveHarness, encoding: .utf8)
    for required in [
      "/bin/realpath \"$staging_root\")\" == \"$staging_root\"",
      "! -L \"$staging_root\"",
      "noowners",
      "launchd jobs cannot be staged there",
      "$staging_root\" != \"$live_root\"",
    ] {
      XCTAssertTrue(source.contains(required), "missing staging path-race/volume guard: \(required)")
    }
  }

  func testInvalidStagingRootsAreRejectedBeforeAnyLaunchdAction() throws {
    let parent = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("hw-g11-staging-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let liveDir = parent.appendingPathComponent("live")
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: liveDir.path)
    let livePath = liveDir.path

    func assertRejected(staging: String, expectedMessage: String) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = [liveHarness.path]
      var env = ProcessInfo.processInfo.environment
      env["HOSTWRIGHT_XPC_LIVE_ROOT"] = livePath
      env["HOSTWRIGHT_XPC_STAGING_ROOT"] = staging
      env["HOSTWRIGHT_XPC_OWNERSHIP_LEDGER"] = parent.appendingPathComponent("ledger.tsv").path
      env["HOSTWRIGHT_XPC_HOST_BIN"] = "/nonexistent-host-bin"
      env["HOSTWRIGHT_XPC_SOURCE_COMMIT"] = String(repeating: "a", count: 40)
      env["HOSTWRIGHT_XPC_CONFIG_DIGEST"] = String(repeating: "b", count: 64)
      process.environment = env
      let errorPipe = Pipe()
      process.standardError = errorPipe
      process.standardOutput = Pipe()
      try process.run()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 66, staging)
      let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      XCTAssertTrue(stderr.contains(expectedMessage), "\(staging): \(stderr)")
    }

    let missing = parent.appendingPathComponent("missing").path
    try assertRejected(staging: missing, expectedMessage: "The XPC staging root is unsafe.")

    let target = parent.appendingPathComponent("real-dir")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let link = parent.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
    try assertRejected(staging: link.path, expectedMessage: "The XPC staging root is unsafe.")

    let loose = parent.appendingPathComponent("loose")
    try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loose.path)
    try assertRejected(staging: parent.appendingPathComponent("loose").resolvingSymlinksInPath().path, expectedMessage: "The XPC staging root is unsafe.")
  }
}
