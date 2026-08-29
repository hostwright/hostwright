import Foundation
import XCTest

final class Phase09Gate12QualificationHarnessTests: XCTestCase {
  private var repository: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var qualificationHarness: URL {
    repository.appendingPathComponent("scripts/phase09-gate12-qualification.sh")
  }

  func testQualificationHarnessFixesSingleGateTwelveRunAndSixSerialEvidenceCells() throws {
    let source = try String(contentsOf: qualificationHarness, encoding: .utf8)
    for required in [
      "readonly gate=12", "Gate 12", "for n in 1 2 3 4 5 6", "U, I, L, M, S, and R",
      "cell_command", "run_cell", "--jobs 1", "PluginSchemaV21MigrationTests",
      "PluginControlOperationsTests", "live_lifecycle",
    ] {
      XCTAssertTrue(source.contains(required), "missing Gate 12 cell contract: \(required)")
    }
  }

  func testQualificationHarnessRejectsDuplicateGateAndRootRunsBeforeExecutingCells() throws {
    let source = try String(contentsOf: qualificationHarness, encoding: .utf8)
    for required in [
      ".phase09-gate12-active-v1", "$root/active-run-v1", "mkdir \"$lock\"",
      "mkdir \"$root/active-run-v1\"", "An active Gate 12 qualification already exists; do not duplicate it.",
      "progress is frozen and locks are preserved", "Cell logs already exist; preserve this root and do not rerun.",
    ] {
      XCTAssertTrue(source.contains(required), "missing Gate 12 lock invariant: \(required)")
    }
  }

  func testQualificationHarnessBindsCommittedSourceConfigurationAndToolchainAndRejectsInvalidReuse() throws {
    let source = try String(contentsOf: qualificationHarness, encoding: .utf8)
    for required in [
      "clean_source", "source must be clean and committed", "source_digest", "config_digest",
      "toolchain_digest", "revalidate_dependencies", "manifest-v1.json", "state-v1.tsv",
      "ownership-v1.tsv", "cellOrder:[1,2,3,4,5,6]",
      "prepared evidence dependencies changed; preserve this root.",
      "completed evidence is incomplete or changed; preserve this root and do not rerun.",
      "Gate 12 evidence is valid and reused; no cells were rerun.",
    ] {
      XCTAssertTrue(source.contains(required), "missing Gate 12 dependency/reuse invariant: \(required)")
    }
    XCTAssertTrue(source.contains("/Volumes/T9/hostwright/qualification"))
    XCTAssertTrue(source.contains("HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT"))
    XCTAssertTrue(source.contains("phase09-gate12-[a-f0-9]{8}"))
  }

  func testQualificationHarnessSealsEvidenceWithCMSAndCleansOnlyPinnedOwnedArtifacts() throws {
    let source = try String(contentsOf: qualificationHarness, encoding: .utf8)
    for required in [
      "evidence-v1.sha256", "evidence-v1.cms", "security cms -S", "security cms -D",
      "record_root", "record_artifact", "ownership-v1.tsv", "identity changed; cleanup is refused",
      "cleanup is frozen", "/bin/unlink", "/bin/rmdir", "Developer ID Application: Dev Trivedi",
    ] {
      XCTAssertTrue(source.contains(required), "missing Gate 12 evidence/cleanup invariant: \(required)")
    }
    XCTAssertFalse(source.contains("rm -rf"))
  }

  func testQualificationHarnessCoversPluginLifecycleMigrationAndAdversarialBoundaries() throws {
    let source = try String(contentsOf: qualificationHarness, encoding: .utf8)
    for required in [
      "PluginImmutableStoreTests", "HTTPSPluginPackageSourceTests", "PluginCLIOptionsTests",
      "PluginControlRoutingTests", "PluginControlOperationsTests", "PluginLifecycleRepositoryTests",
      "v20→v21 verified backup restore and compatibility", "SecurePluginPackageTests",
      "VersionSubstitutionIsRejected", "PackageAndSignerRevocationUpdatePackagesGrantsAndActivation",
      "QuarantineMarksPackageAndActivationUnhealthy", "InstallFailureCleansStageAndPersistsFailedRollbackAcrossReopen",
      "swift build --jobs 1 --product hostwright", "swift build --jobs 1 --product hostwrightd",
      "scripts/lint.sh", "scripts/check-docs.sh",
    ] {
      XCTAssertTrue(source.contains(required), "missing Gate 12 lifecycle cell evidence: \(required)")
    }
  }

  func testGateTwelveHarnessUsesSerialSwiftPMAndOwnedOnlyCleanup() throws {
    let source = try String(contentsOf: qualificationHarness, encoding: .utf8)
    XCTAssertFalse(source.contains("swift test --parallel"))
    XCTAssertFalse(source.contains("swift build --parallel"))
    XCTAssertFalse(source.contains("rm -rf"))
    for required in ["revalidate_dependencies", "record_root", "record_artifact", "cleanup"] {
      XCTAssertTrue(source.contains(required), "missing Gate 12 serial ownership guard: \(required)")
    }
  }
}
