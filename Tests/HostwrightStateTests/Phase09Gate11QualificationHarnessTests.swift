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
}
