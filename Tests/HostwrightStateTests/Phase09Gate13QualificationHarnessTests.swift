import Foundation
import XCTest

final class Phase09Gate13QualificationHarnessTests: XCTestCase {
  private var repository: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var harness: URL {
    repository.appendingPathComponent("scripts/phase09-gate13-qualification.sh")
  }

  private var matrix: URL {
    repository.appendingPathComponent("contracts/v0.0.2/phase09-gate13-compatibility-matrix-v1.json")
  }

  private let signerIdentity = "Hostwright Phase09 Test CMS Signer (P09TEST001)"
  private let signerFingerprint = "C0DEC0DEC0DEC0DEC0DEC0DEC0DEC0DEC0DEC0DE"
  private let signerTeam = "P09TEST001"
  private let signerCertificate = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  func testContractAndMatrixFreezeTwentySelectorsAndStructuredEvidence() throws {
    let contract = try run(["contract"])
    XCTAssertEqual(contract.status, 0, contract.stderr)
    XCTAssertTrue(contract.stdout.contains("Gate 13 — 81.25%"))
    XCTAssertTrue(contract.stdout.contains("diagnose is non-qualifying"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: matrix)) as? [String: Any])
    XCTAssertEqual(object["testCount"] as? Int, 20)
    XCTAssertEqual((object["structuredResult"] as? [String: Any])?["format"] as? String, "xunit-v1")
    let tests = try XCTUnwrap(object["tests"] as? [[String: Any]])
    XCTAssertEqual(tests.count, 20)
    XCTAssertEqual(Set(tests.compactMap { $0["id"] as? String }).count, 20)
    XCTAssertEqual(Set(tests.compactMap { $0["selector"] as? String }).count, 20)
    XCTAssertEqual(Set(tests.compactMap { $0["cell"] as? Int }), Set(1...6))
  }

  func testDiagnoseClaimsNoneAndUsesStructuredResults() throws {
    let parent = try makeTemporaryDirectory(prefix: "gate13-diagnose")
    defer { try? FileManager.default.removeItem(at: parent) }
    try installSwiftWrapper(in: parent)
    let environment = testEnvironment(parent: parent)
    let result = try run(["diagnose"], environment: environment)
    XCTAssertEqual(result.status, 0, result.stderr)
    let diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(diagnostic["claim"] as? String, "none")
    XCTAssertEqual(diagnostic["qualifying"] as? Bool, false)
    XCTAssertEqual(diagnostic["expectedTests"] as? Int, 20)
    XCTAssertEqual(diagnostic["observedTests"] as? Int, 20)
    XCTAssertEqual(diagnostic["exactCount"] as? Bool, true)
    XCTAssertNil(environment["HOSTWRIGHT_PHASE09_GATE_ROOT"])
  }

  func testWrongSignerIsRejectedBeforePreparation() throws {
    try withPrerequisites { fixture, base in
      var environment = base
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_SIGNING_IDENTITY"] = "Wrong Signer (BADTEAM)"
      let result = try run(["prepare", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }
  }

  func testActualCMSCertificateMismatchIsRejectedEvenForTheSameIdentity() throws {
    try withPrerequisites { fixture, environment in
      let cms = fixture.dependencyRoot.appendingPathComponent("evidence-v1.cms")
      var cmsText = try String(contentsOf: cms, encoding: .utf8)
      let alternateCertificate = String(repeating: "a", count: 64)
      cmsText = cmsText.replacingOccurrences(of: "certificate-sha256=\(signerCertificate)", with: "certificate-sha256=\(alternateCertificate)")
      try Data(cmsText.utf8).write(to: cms)
      let dependencyURL = URL(fileURLWithPath: environment["HOSTWRIGHT_PHASE09_GATE13_DEPENDENCY_EVIDENCE"]!)
      var dependency = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dependencyURL)) as? [String: Any])
      var records = try XCTUnwrap(dependency["records"] as? [[String: Any]])
      records[0]["cmsDigest"] = try sha256(cms)
      dependency["records"] = records
      try writeJSON(dependency, to: dependencyURL)
      try setPrivate(dependencyURL)
      let result = try run(["prepare", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("CMS") || result.stderr.contains("signer"), result.stderr)
    }
  }

  func testActualCMSTeamMismatchIsRejectedBeforeEvidenceReuse() throws {
    try withPrerequisites { fixture, environment in
      let cms = fixture.receipt.deletingLastPathComponent().appendingPathComponent("phase08-completion-receipt-v1.cms")
      var cmsText = try String(contentsOf: cms, encoding: .utf8)
      cmsText = cmsText.replacingOccurrences(of: "team-id=\(signerTeam)", with: "team-id=ALTTTEAM01")
      try Data(cmsText.utf8).write(to: cms)
      let result = try run(["prepare", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("receipt") || result.stderr.contains("CMS"), result.stderr)
    }
  }

  func testActualCMSFingerprintMismatchIsRejectedBeforeEvidenceReuse() throws {
    try withPrerequisites { fixture, environment in
      let cms = fixture.receipt.deletingLastPathComponent().appendingPathComponent("phase08-completion-receipt-v1.cms")
      var cmsText = try String(contentsOf: cms, encoding: .utf8)
      cmsText = cmsText.replacingOccurrences(of: "fingerprint=\(signerFingerprint)", with: "fingerprint=DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF")
      try Data(cmsText.utf8).write(to: cms)
      let result = try run(["prepare", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("receipt") || result.stderr.contains("CMS") || result.stderr.contains("signer"), result.stderr)
    }
  }

  func testReceiptTamperIsRejectedByChecksumAndStrictSchema() throws {
    try withPrerequisites { fixture, environment in
      var tampered = try Data(contentsOf: fixture.receipt)
      tampered.append(Data("tamper".utf8))
      try tampered.write(to: fixture.receipt)
      let result = try run(["prepare", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("receipt"), result.stderr)
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }
  }

  func testDependencyCMSTamperFailsClosed() throws {
    try withPrerequisites { fixture, environment in
      let cms = fixture.dependencyRoot.appendingPathComponent("evidence-v1.cms")
      var data = try Data(contentsOf: cms)
      data.append(Data("tamper".utf8))
      try data.write(to: cms)
      let result = try run(["prepare", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("evidence digest changed") || result.stderr.contains("CMS"), result.stderr)
    }
  }

  func testCopiedReceiptSidecarTamperingFailsClosed() throws {
    for name in ["phase08-completion-receipt-v1.sha256", "phase08-completion-receipt-v1.cms"] {
      try withPrepared { fixture, environment in
        let sidecar = fixture.root.appendingPathComponent(name)
        var data = try Data(contentsOf: sidecar)
        data.append(Data("tamper".utf8))
        try data.write(to: sidecar)
        let result = try run(["run", "13"], environment: environment)
        XCTAssertNotEqual(result.status, 0, name)
        XCTAssertEqual(try manifestStatus(fixture.root), "prepared", name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate13-active-v1").path), name)
      }
    }
  }

  func testStructuredMissingDuplicateAndExtraResultsFailClosed() throws {
    for variant in ["missing", "duplicate", "extra"] {
      try withPrepared { fixture, environment in
        var failing = environment
        failing["HOSTWRIGHT_PHASE09_HARNESS_TEST_RESULT_VARIANT"] = variant
        let result = try run(["run", "13"], environment: failing)
        XCTAssertNotEqual(result.status, 0, variant)
        XCTAssertEqual(try manifestStatus(fixture.root), "failed", variant)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      }
    }
  }

  func testSymlinkedFixedSealTemporaryFailsAndFreezesRoot() throws {
    try withPrepared { fixture, environment in
      let temp = fixture.root.appendingPathComponent(".evidence-v1.sha256.tmp")
      try FileManager.default.createSymbolicLink(at: temp, withDestinationURL: fixture.parent.appendingPathComponent("sentinel"))
      let result = try run(["run", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate13-active-v1").path))
      let rerun = try run(["run", "13"], environment: environment)
      XCTAssertNotEqual(rerun.status, 0)
      XCTAssertTrue(rerun.stderr.contains("frozen after failure"), rerun.stderr)
    }
  }

  func testCMSSealFailureLeavesFailedManifestAndBothLocks() throws {
    try withPrepared { fixture, base in
      var environment = base
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_FAIL"] = "1"
      let result = try run(["run", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate13-active-v1").path))
    }
  }

  func testCellOutputSymlinkRaceFailsClosedAndPreservesSentinel() throws {
    try withPrepared { fixture, base in
      let sentinel = fixture.parent.appendingPathComponent("output-race-sentinel")
      try Data("unchanged".utf8).write(to: sentinel)
      try setPrivate(sentinel)
      let output = fixture.root.appendingPathComponent("cell-01.stdout.log")
      var environment = base
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_RACE_OUTPUT"] = output.path
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_RACE_TARGET"] = sentinel.path
      let result = try run(["run", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: output.path), sentinel.path)
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate13-active-v1").path))
    }
  }

  func testSourcePublishSymlinkInterpositionFailsClosedAndPreservesSentinel() throws {
    try withPrepared { fixture, base in
      let sentinel = fixture.parent.appendingPathComponent("source-race-sentinel")
      try Data("unchanged".utf8).write(to: sentinel)
      try setPrivate(sentinel)
      var environment = base
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_SOURCE_RACE"] = "1"
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_SOURCE_RACE_TARGET"] = sentinel.path
      let result = try run(["run", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("gate-active-run-v1-info.tsv").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate13-active-v1").path))
    }
  }

  func testSourcePublishRegularFileSwapIsRejectedByBoundIdentity() throws {
    try withPrepared { fixture, base in
      let sentinel = fixture.parent.appendingPathComponent("source-regular-swap-sentinel")
      try Data("unchanged".utf8).write(to: sentinel)
      try setPrivate(sentinel)
      var environment = base
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_SOURCE_RACE"] = "1"
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_SOURCE_RACE_MODE"] = "regular"
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_SOURCE_RACE_TARGET"] = sentinel.path
      let result = try run(["run", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("gate-active-run-v1-info.tsv").path))
    }
  }

  func testHardlinkedPrivateLedgerIsRejectedAndSentinelIsUnchanged() throws {
    try withPrepared { fixture, base in
      let sentinel = fixture.parent.appendingPathComponent("hardlink-sentinel")
      try Data("unchanged".utf8).write(to: sentinel)
      try setPrivate(sentinel)
      let state = fixture.root.appendingPathComponent("state-v1.tsv")
      try FileManager.default.removeItem(at: state)
      try FileManager.default.linkItem(atPath: sentinel.path, toPath: state.path)
      let result = try run(["run", "13"], environment: base)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
    }
  }

  func testDirtyWorkingTreeContentChangesSourceDigestAndRejectsReuse() throws {
    try withPrepared { fixture, base in
      let original = try Data(contentsOf: harness)
      defer { try? original.write(to: harness, options: .atomic) }
      var dirty = original
      dirty.append(Data("\n# deterministic dirty working-tree digest test\n".utf8))
      try dirty.write(to: harness, options: .atomic)
      let result = try run(["run", "13"], environment: base)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertTrue(result.stderr.contains("prepared evidence dependencies changed") || result.stderr.contains("dependencies changed"), result.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "prepared")
    }
  }

  func testDirectorySwapDuringAcquisitionFailsClosedAndRestoresPath() throws {
    try withPrerequisites { fixture, base in
      let sentinel = fixture.parent.appendingPathComponent("directory-swap-sentinel")
      try Data("unchanged".utf8).write(to: sentinel)
      try setPrivate(sentinel)
      var environment = base
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_DIRECTORY_RACE"] = "1"
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_DIRECTORY_RACE_PATH"] = fixture.root.path
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_DIRECTORY_RACE_TARGET"] = sentinel.path
      let result = try run(["prepare", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
      var isDirectory: ObjCBool = false
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.path, isDirectory: &isDirectory))
      XCTAssertTrue(isDirectory.boolValue)
    }
  }

  func testLogReplacementRefusesSymlinkDestinationAndPreservesSentinel() throws {
    try withPrepared { fixture, base in
      let sentinel = fixture.parent.appendingPathComponent("log-race-sentinel")
      try Data("unchanged".utf8).write(to: sentinel)
      try setPrivate(sentinel)
      let state = fixture.root.appendingPathComponent("state-v1.tsv")
      try FileManager.default.removeItem(at: state)
      try FileManager.default.createSymbolicLink(at: state, withDestinationURL: sentinel)
      let result = try run(["run", "13"], environment: base)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate13-active-v1").path))
    }
  }

  func testXUnitOutputSymlinkInterpositionFailsClosedAndPreservesSentinel() throws {
    try withPrepared { fixture, base in
      let sentinel = fixture.parent.appendingPathComponent("xunit-race-sentinel")
      try Data("unchanged".utf8).write(to: sentinel)
      try setPrivate(sentinel)
      var environment = base
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_RACE_XUNIT"] = "1"
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_RACE_XUNIT_TARGET"] = sentinel.path
      let result = try run(["run", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate13-active-v1").path))
    }
  }

  func testCMSOutputSymlinkInterpositionFailsClosedAndPreservesSentinel() throws {
    try withPrepared { fixture, base in
      let sentinel = fixture.parent.appendingPathComponent("cms-race-sentinel")
      try Data("unchanged".utf8).write(to: sentinel)
      try setPrivate(sentinel)
      var environment = base
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_RACE_OUTPUT"] = "1"
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_RACE_TARGET"] = sentinel.path
      let result = try run(["run", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate13-active-v1").path))
    }
  }

  func testReusableRejectsNoncanonicalChecksumInventoryWithValidPinnedCMS() throws {
    for variant in ["missing", "duplicate", "extra", "reordered", "renamed"] {
      try withPrepared { fixture, environment in
        let passed = try run(["run", "13"], environment: environment)
        XCTAssertEqual(passed.status, 0, passed.stderr)
        let checksum = fixture.root.appendingPathComponent("evidence-v1.sha256")
        var lines = try String(contentsOf: checksum, encoding: .utf8).split(separator: "\n").map(String.init)
        switch variant {
        case "missing":
          lines.removeFirst()
        case "duplicate":
          lines.append(lines[0])
        case "extra":
          let extra = fixture.root.appendingPathComponent("checksum-extra.txt")
          try Data("extra".utf8).write(to: extra)
          try setPrivate(extra)
          lines.append("\(try sha256(extra))  checksum-extra.txt")
        case "reordered":
          lines.reverse()
        case "renamed":
          guard let index = lines.firstIndex(where: { $0.hasSuffix("  manifest-v1.json") }) else {
            XCTFail("manifest checksum entry is missing")
            return
          }
          lines[index] = lines[index].replacingOccurrences(of: "  manifest-v1.json", with: "  renamed-entry-v1.json")
        default:
          XCTFail("unexpected variant")
        }
        let text = lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: checksum)
        try setPrivate(checksum)
        try writeCMS(payload: text, to: fixture.root.appendingPathComponent("evidence-v1.cms"))
        let reused = try run(["run", "13"], environment: environment)
        XCTAssertNotEqual(reused.status, 0, variant)
        XCTAssertTrue(reused.stderr.contains("incomplete or changed"), "\(variant): \(reused.stderr)")
        XCTAssertEqual(try manifestStatus(fixture.root), "passed")
      }
    }
  }

  func testSuccessfulTestModeSealingAndExactReuseInventory() throws {
    try withPrepared { fixture, environment in
      let passed = try run(["run", "13"], environment: environment)
      XCTAssertEqual(passed.status, 0, passed.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "passed")
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate13-active-v1").path))
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count, 29)
      let stateLines = try String(contentsOf: fixture.root.appendingPathComponent("state-v1.tsv"), encoding: .utf8).split(separator: "\n")
      XCTAssertEqual(stateLines.count, 7)
      XCTAssertTrue(stateLines.first?.hasPrefix("gate\tcell\tstatus\t") == true)
      XCTAssertEqual(stateLines.dropFirst().filter { $0.split(separator: "\t").count > 2 && $0.split(separator: "\t")[2] == "pass" }.count, 6)
      let unexpected = fixture.root.appendingPathComponent("unexpected.txt")
      try Data("unexpected".utf8).write(to: unexpected)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unexpected.path)
      let reused = try run(["run", "13"], environment: environment)
      XCTAssertNotEqual(reused.status, 0)
      XCTAssertTrue(reused.stderr.contains("incomplete or changed"), reused.stderr)
    }
  }

  func testPassedRootWithBothFinalSealsDeletedIsFrozen() throws {
    try withPrepared { fixture, environment in
      let passed = try run(["run", "13"], environment: environment)
      XCTAssertEqual(passed.status, 0, passed.stderr)
      try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("evidence-v1.sha256"))
      try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("evidence-v1.cms"))
      let refused = try run(["run", "13"], environment: environment)
      XCTAssertNotEqual(refused.status, 0)
      XCTAssertTrue(refused.stderr.contains("missing one or both final seal files"), refused.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "passed")
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate13-active-v1").path))
    }
  }

  func testFormalPrepareFailsClosedWithoutCommitAndReceipt() throws {
    let parent = try makeTemporaryDirectory(prefix: "gate13-missing")
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("phase09-gate13-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    var environment = testEnvironment(parent: parent)
    environment["HOSTWRIGHT_PHASE09_GATE_ROOT"] = root.path
    let result = try run(["prepare", "13"], environment: environment)
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  func testPreparationSymlinkFailsClosedAndPreservesSentinel() throws {
    try withPrerequisites { fixture, environment in
      let sentinel = fixture.parent.appendingPathComponent("prepare-symlink-sentinel")
      try Data("unchanged".utf8).write(to: sentinel)
      try setPrivate(sentinel)
      let destination = fixture.root.appendingPathComponent("dependency-evidence-v1.json")
      try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: sentinel)
      let result = try run(["prepare", "13"], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), sentinel.path)
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
    }
  }

  func testSourceContainsPinnedCMSStructuredInventoryAndNoBroadCleanup() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    for required in ["cms -M", "cms -D -u 9", "cms -S -N", "validate_staged_digest", "compare_inventory", "validate_structured_results", "claim none", "O_CREAT | O_EXCL | O_NOFOLLOW", "RENAME_NOFOLLOW_ANY", "atomic_run_outputs", "atomic_publish", "atomic_copy", "create-dir", "replace-log", "path_parent"] {
      XCTAssertTrue(source.contains(required), required)
    }
    XCTAssertFalse(source.contains("O_APPEND"))
    XCTAssertFalse(source.contains("rm " + "-rf"))
    XCTAssertFalse(source.contains("Executed [0-9]+ tests"))
    XCTAssertFalse(source.contains("git -C"))
    XCTAssertFalse(source.contains("key" + "chain"))
    XCTAssertFalse(source.contains("gh " + "pr"))
  }

  private struct Fixture {
    let parent: URL
    let root: URL
    let receipt: URL
    let dependencyRoot: URL
  }

  private func withPrepared(_ body: (Fixture, [String: String]) throws -> Void) throws {
    try withPrerequisites { fixture, environment in
      let prepared = try run(["prepare", "13"], environment: environment)
      XCTAssertEqual(prepared.status, 0, prepared.stderr)
      try body(fixture, environment)
    }
  }

  private func withPrerequisites(_ body: (Fixture, [String: String]) throws -> Void) throws {
    let parent = try makeTemporaryDirectory(prefix: "gate13-harness")
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("phase09-gate13-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let head = try currentCommit()
    let dependencyFile = parent.appendingPathComponent("gate13-dependencies.json")
    let dependencyRoot = try makePassedDependencies(parent: parent, gates: Array(8...12), sourceCommit: head, output: dependencyFile)
    let receiptDirectory = parent.appendingPathComponent("receipt")
    try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: false)
    let receipt = receiptDirectory.appendingPathComponent("phase08-completion-receipt-v1.json")
    try writeJSON([
      "cmsVerified": true,
      "finalEvidenceCMSCertificateSHA256": signerCertificate,
      "finalEvidenceCMSDigest": String(repeating: "a", count: 64),
      "finalEvidenceCMSFingerprint": signerFingerprint,
      "finalEvidenceCMSIdentity": signerIdentity,
      "finalEvidenceCMSTeamID": signerTeam,
      "finalEvidenceDigest": String(repeating: "a", count: 64),
      "schema": "hostwright.phase09.phase08-completion-receipt.v1",
      "sourceCommit": head,
      "status": "passed"
    ], to: receipt)
    try setPrivate(receipt)
    let receiptChecksum = receiptDirectory.appendingPathComponent("phase08-completion-receipt-v1.sha256")
    let receiptChecksumText = "\(try sha256(receipt))  phase08-completion-receipt-v1.json\n"
    try Data(receiptChecksumText.utf8).write(to: receiptChecksum)
    try setPrivate(receiptChecksum)
    let receiptCMS = receiptDirectory.appendingPathComponent("phase08-completion-receipt-v1.cms")
    try writeCMS(payload: receiptChecksumText, to: receiptCMS)
    let security = parent.appendingPathComponent("security")
    try installSecurityWrapper(at: security)
    try installSwiftWrapper(in: parent)
    var environment = testEnvironment(parent: parent)
    environment["HOSTWRIGHT_PHASE09_GATE_ROOT"] = root.path
    environment["HOSTWRIGHT_PHASE09_PHASE08_COMPLETION_COMMIT"] = head
    environment["HOSTWRIGHT_PHASE09_PHASE08_COMPLETION_RECEIPT"] = receipt.path
    environment["HOSTWRIGHT_PHASE09_GATE13_DEPENDENCY_EVIDENCE"] = dependencyFile.path
    try body(Fixture(parent: parent, root: root, receipt: receipt, dependencyRoot: dependencyRoot), environment)
  }

  private func makePassedDependencies(parent: URL, gates: [Int], sourceCommit: String, output: URL) throws -> URL {
    var records: [[String: Any]] = []
    var firstRoot: URL?
    let sourceDigest = try currentSourceDigest()
    let configDigest = String(repeating: "a", count: 64)
    let toolchainDigest = String(repeating: "b", count: 64)
    for gate in gates {
      let root = parent.appendingPathComponent(String(format: "phase09-gate%02d-%@", gate, UUID().uuidString.lowercased()))
      if firstRoot == nil { firstRoot = root }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
      let manifest = root.appendingPathComponent("manifest-v1.json")
      try writeJSON(["gate": gate, "status": "passed", "sourceCommit": sourceCommit, "sourceDigest": sourceDigest, "configDigest": configDigest, "toolchainDigest": toolchainDigest], to: manifest)
      try setPrivate(manifest)
      let checksum = "\(try sha256(manifest))  manifest-v1.json\n"
      let checksumURL = root.appendingPathComponent("evidence-v1.sha256")
      try Data(checksum.utf8).write(to: checksumURL)
      try setPrivate(checksumURL)
      let cmsURL = root.appendingPathComponent("evidence-v1.cms")
      try writeCMS(payload: checksum, to: cmsURL)
      let manifestDigest = try sha256(manifest)
      records.append([
        "cmsCertificateSHA256": signerCertificate,
        "cmsDigest": try sha256(cmsURL),
        "cmsFingerprint": signerFingerprint,
        "cmsIdentity": signerIdentity,
        "cmsTeamID": signerTeam,
        "checksumManifestDigest": try sha256(checksumURL),
        "configDigest": configDigest,
        "gate": gate,
        "manifestDigest": manifestDigest,
        "rootBasename": root.lastPathComponent,
        "sourceCommit": sourceCommit,
        "sourceDigest": sourceDigest,
        "status": "passed",
        "toolchainDigest": toolchainDigest
      ])
    }
    try writeJSON(["schema": "hostwright.phase09.dependency-evidence.v1", "records": records], to: output)
    try setPrivate(output)
    return try XCTUnwrap(firstRoot)
  }

  private func installSecurityWrapper(at url: URL) throws {
    try writeExecutable("""
      #!/bin/bash
      set -euo pipefail
      mode=""
      input=""
      output=""
      signer=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -S) mode="sign"; shift ;;
          -V) mode="verify"; shift ;;
          -D) mode="decode"; shift ;;
          -M) mode="metadata"; shift ;;
          -N) signer="$2"; shift 2 ;;
          -i) input="$2"; shift 2 ;;
          -o) output="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      [[ -n "$input" && -n "$output" ]]
      if [[ "$mode" == "sign" && "$HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_FAIL" == "1" ]]; then exit 55; fi
      if [[ "$mode" == "sign" && "$HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_RACE_OUTPUT" == "1" ]]; then
        /bin/ln -s "$HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_RACE_TARGET" "$output"
        exit 0
      fi
      if [[ "$mode" != "sign" && "$mode" != "metadata" ]]; then
        [[ "$(/usr/bin/sed -n '5p' "$input")" == "identity=$signer" ]]
        [[ "$(/usr/bin/sed -n '6p' "$input")" == "signer=$signer" ]]
      fi
      case "$mode" in
        sign)
          { printf 'P09FAKECMS\ncertificate-sha256=\(signerCertificate)\nfingerprint=\(signerFingerprint)\nteam-id=\(signerTeam)\nidentity=\(signerIdentity)\nsigner=%s\n' "$signer"; /bin/cat "$input"; } > "$output" ;;
        verify) : > "$output" ;;
        metadata) /usr/bin/sed -n '2,5p' "$input" > "$output" ;;
        decode) /usr/bin/tail -n +7 "$input" > "$output" ;;
        *) exit 56 ;;
      esac
    """, named: "security", in: url.deletingLastPathComponent())
  }

  private func installSwiftWrapper(in parent: URL) throws {
    try writeExecutable("""
      #!/bin/bash
      set -euo pipefail
      if [[ "$1" == "--version" ]]; then echo "Apple Swift version 6.0 (test)"; exit 0; fi
      if [[ "$1" == "build" ]]; then exit 0; fi
      [[ "$1" == "test" ]]
      base=""
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--xunit-output" ]]; then base="$2"; shift 2; else shift; fi
      done
      if [[ "$HOSTWRIGHT_PHASE09_HARNESS_TEST_RACE_XUNIT" == "1" ]]; then
        /bin/ln -s "$HOSTWRIGHT_PHASE09_HARNESS_TEST_RACE_XUNIT_TARGET" "$base-swift-testing.xml"
        exit 0
      fi
      /usr/bin/python3 -c 'import html,json,os,sys; base,raw,expected=sys.argv[1:]; selectors=json.loads(raw); n=int(expected); cases=[tuple(s.split("/",1)) for s in selectors] if selectors and "/" in selectors[0] else [(s,"test%03d"%(i+1)) for i,s in enumerate(selectors) for _ in range(max(1,n//max(1,len(selectors))))]; cases=(cases+[(selectors[len(cases)%len(selectors)],"test%03d"%(len(cases)+1)) for _ in range(max(0,n-len(cases)))])[:n]; variant=os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TEST_RESULT_VARIANT",""); race=os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TEST_RACE_OUTPUT"); race and os.symlink(os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TEST_RACE_TARGET",""),race); cases=cases[:-1] if variant=="missing" else cases; cases=cases+([cases[0]] if variant=="duplicate" else []); cases=cases+([( "UnexpectedSelector","testExtra")] if variant=="extra" else []); q=chr(34); header="<testsuites><testsuite tests="+q+str(len(cases))+q+" failures="+q+"0"+q+" errors="+q+"0"+q+" skipped="+q+"0"+q+">"; xml=header+"".join("<testcase classname="+q+html.escape(c)+q+" name="+q+html.escape(t)+q+"/>" for c,t in cases)+"</testsuite></testsuites>"; open(base+"-swift-testing.xml","w").write(xml)' "$base" "$HOSTWRIGHT_PHASE09_EXPECTED_SELECTORS_JSON" "$HOSTWRIGHT_PHASE09_EXPECTED_TESTS"
    """, named: "swift", in: parent)
  }

  private func testEnvironment(parent: URL) -> [String: String] {
    [
      "HOSTWRIGHT_PHASE09_HARNESS_TESTING": "1",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_FAIL": "0",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_RACE_OUTPUT": "0",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_RACE_TARGET": "",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_SOURCE_RACE_MODE": "symlink",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_DIRECTORY_RACE": "0",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_DIRECTORY_RACE_PATH": "",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_DIRECTORY_RACE_TARGET": "",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_RACE_XUNIT": "0",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_RACE_XUNIT_TARGET": "",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT": parent.path,
      "HOSTWRIGHT_PHASE09_EVIDENCE_PARENT": parent.path,
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_SWIFT": parent.appendingPathComponent("swift").path,
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_SECURITY": parent.appendingPathComponent("security").path
    ]
  }

  private func manifestStatus(_ root: URL) throws -> String {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest-v1.json"))) as? [String: Any])
    return try XCTUnwrap(object["status"] as? String)
  }

  private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-phase09-\(prefix)-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let canonicalizer = Process()
    canonicalizer.executableURL = URL(fileURLWithPath: "/bin/realpath")
    canonicalizer.arguments = [directory.path]
    let output = Pipe()
    canonicalizer.standardOutput = output
    try canonicalizer.run()
    canonicalizer.waitUntilExit()
    XCTAssertEqual(canonicalizer.terminationStatus, 0)
    let canonicalPath = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(fileURLWithPath: canonicalPath)
  }

  private func run(_ arguments: [String], environment: [String: String] = [:]) throws -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [harness.path] + arguments
    var values = ProcessInfo.processInfo.environment
    for (key, value) in environment { values[key] = value }
    process.environment = values
    process.currentDirectoryURL = repository
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return ShellResult(status: process.terminationStatus,
                       stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                       stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
  }

  private func currentCommit() throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "HEAD"]
    process.currentDirectoryURL = repository
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func currentSourceDigest() throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", """
      {
        /usr/bin/git rev-parse HEAD
        while IFS= read -r -d '' path; do
          case \"$path\" in
            tmp|tmp/*|.codex|.codex/*|.claude|.claude/*) continue ;;
          esac
          printf '%s\\0' \"$path\"
          if [[ -f \"$path\" && ! -L \"$path\" ]]; then /usr/bin/shasum -a 256 \"$path\" | /usr/bin/awk '{ print $1 }'; else printf '%s\\n' missing; fi
        done < <({
          /usr/bin/git ls-files --cached -z -- . ':(exclude)tmp' ':(exclude).codex' ':(exclude).claude'
          printf '%s\\0' scripts/phase09-gate13-qualification.sh scripts/phase09-gate14-qualification.sh Tests/HostwrightStateTests/Phase09Gate13QualificationHarnessTests.swift Tests/HostwrightStateTests/Phase09Gate14QualificationHarnessTests.swift
        } | LC_ALL=C /usr/bin/sort -z -u)
        /usr/bin/git submodule status --recursive 2>/dev/null || true
      } | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
      """]
    process.currentDirectoryURL = repository
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func sha256(_ file: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", file.path]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
  }

  private func writeCMS(payload: String, to url: URL) throws {
    try Data("P09FAKECMS\ncertificate-sha256=\(signerCertificate)\nfingerprint=\(signerFingerprint)\nteam-id=\(signerTeam)\nidentity=\(signerIdentity)\nsigner=\(signerIdentity)\n\(payload)".utf8).write(to: url)
    try setPrivate(url)
  }

  private func writeJSON(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
  }

  private func setPrivate(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func writeExecutable(_ text: String, named name: String, in directory: URL) throws {
    let file = directory.appendingPathComponent(name)
    try Data(text.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
  }
}

private struct ShellResult {
  let status: Int32
  let stdout: String
  let stderr: String
}
