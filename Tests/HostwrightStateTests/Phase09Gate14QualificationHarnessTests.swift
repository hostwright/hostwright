import Foundation
import XCTest

final class Phase09Gate14QualificationHarnessTests: XCTestCase {
  private var repository: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var harness: URL {
    repository.appendingPathComponent("scripts/phase09-gate14-qualification.sh")
  }

  private var matrix: URL {
    repository.appendingPathComponent("contracts/v0.0.2/phase09-gate14-aggregate-matrix-v1.json")
  }

  private var gate13Matrix: URL {
    repository.appendingPathComponent("contracts/v0.0.2/phase09-gate13-compatibility-matrix-v1.json")
  }

  private let signerIdentity = "Hostwright Phase09 Test CMS Signer (P09TEST001)"
  private let signerFingerprint = "C0DEC0DEC0DEC0DEC0DEC0DEC0DEC0DEC0DEC0DE"
  private let signerTeam = "P09TEST001"
  private let signerCertificate = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  func testContractAndMatrixFreezeFiveHundredProductExecutions() throws {
    let contract = try run(["contract"])
    XCTAssertEqual(contract.status, 0, contract.stderr)
    XCTAssertTrue(contract.stdout.contains("Gate 14 — 87.50%"))
    XCTAssertTrue(contract.stdout.contains("exactly 500 executions"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: matrix)) as? [String: Any])
    XCTAssertEqual(object["productTestCount"] as? Int, 500)
    XCTAssertEqual((object["structuredResult"] as? [String: Any])?["format"] as? String, "xunit-v1")
    XCTAssertEqual((object["structuredResult"] as? [String: Any])?["selectorBinding"] as? String, "testcase-classname-and-name")
    let cells = try XCTUnwrap(object["cells"] as? [[String: Any]])
    XCTAssertEqual(cells.compactMap { $0["expectedTests"] as? Int }.reduce(0, +), 500)
    XCTAssertEqual(cells.count, 6)
    let testcases = cells.flatMap { ($0["testcases"] as? [[String: Any]]) ?? [] }
    XCTAssertEqual(testcases.count, 500)
    XCTAssertEqual(Set(testcases.compactMap { $0["id"] as? String }).count, 500)
    let identifiers = testcases.compactMap { item -> String? in
      guard let classname = item["classname"] as? String, let name = item["name"] as? String else { return nil }
      return "\(classname)/\(name)"
    }
    XCTAssertEqual(Set(identifiers).count, 500)
    XCTAssertTrue(testcases.allSatisfy {
      guard let classname = $0["classname"] as? String, let name = $0["name"] as? String else { return false }
      return classname.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil &&
        name.range(of: "^test[A-Za-z0-9_]+$", options: .regularExpression) != nil &&
        !classname.contains("Phase09") && !classname.contains("QualificationHarness")
    })
  }

  func testDiagnoseClaimsNoneAndUsesStructuredResults() throws {
    let parent = try makeTemporaryDirectory(prefix: "gate14-diagnose")
    defer { try? FileManager.default.removeItem(at: parent) }
    try installSwiftWrapper(in: parent)
    let result = try run(["diagnose"], environment: testEnvironment(parent: parent))
    XCTAssertEqual(result.status, 0, result.stderr)
    let diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(diagnostic["claim"] as? String, "none")
    XCTAssertEqual(diagnostic["qualifying"] as? Bool, false)
    XCTAssertEqual(diagnostic["expectedTests"] as? Int, 500)
    XCTAssertEqual(diagnostic["observedTests"] as? Int, 500)
    XCTAssertEqual(diagnostic["exactCount"] as? Bool, true)
  }

  func testWrongSignerIsRejectedBeforePreparation() throws {
    try withPrerequisites { fixture, base in
      var environment = base
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_SIGNING_FINGERPRINT"] = "0000000000000000000000000000000000000000"
      let result = try run(["prepare", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }
  }

  func testGate13DependencyDigestAndCMSTamperFailClosed() throws {
    try withPrerequisites { fixture, environment in
      var recordData = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.dependencyFile)) as? [String: Any])
      var records = try XCTUnwrap(recordData["records"] as? [[String: Any]])
      records[0]["manifestDigest"] = String(repeating: "0", count: 64)
      recordData["records"] = records
      try writeJSON(recordData, to: fixture.dependencyFile)
      let digestResult = try run(["prepare", "14"], environment: environment)
      XCTAssertNotEqual(digestResult.status, 0)
    }
    try withPrerequisites { fixture, environment in
      let cms = fixture.gate13Root.appendingPathComponent("evidence-v1.cms")
      var data = try Data(contentsOf: cms)
      data.append(Data("tamper".utf8))
      try data.write(to: cms)
      let cmsResult = try run(["prepare", "14"], environment: environment)
      XCTAssertNotEqual(cmsResult.status, 0)
    }
  }

  func testSignedGate13DependencyCopyMismatchFailsClosed() throws {
    try withPrerequisites { fixture, environment in
      let dependency = fixture.gate13Root.appendingPathComponent("dependency-evidence-v1.json")
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dependency)) as? [String: Any])
      var records = try XCTUnwrap(object["records"] as? [[String: Any]])
      records[0]["sourceDigest"] = String(repeating: "f", count: 64)
      object["records"] = records
      try writeJSON(object, to: dependency)
      try setPrivate(dependency)
      let result = try run(["prepare", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("dependency") || result.stderr.contains("CMS") || result.stderr.contains("checksum"), result.stderr)
    }
  }

  func testGate13ChecksumOrderTamperFailsClosedBeforeGate14Reuse() throws {
    try withPrerequisites { fixture, environment in
      let checksum = fixture.gate13Root.appendingPathComponent("evidence-v1.sha256")
      var lines = try String(contentsOf: checksum, encoding: .utf8).split(separator: "\n").map(String.init)
      lines.reverse()
      let tampered = lines.joined(separator: "\n") + "\n"
      try Data(tampered.utf8).write(to: checksum)
      try setPrivate(checksum)
      let cms = fixture.gate13Root.appendingPathComponent("evidence-v1.cms")
      try writeCMS(payload: tampered, to: cms)

      var dependency = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.dependencyFile)) as? [String: Any])
      var records = try XCTUnwrap(dependency["records"] as? [[String: Any]])
      records[0]["checksumManifestDigest"] = try sha256(checksum)
      records[0]["cmsDigest"] = try sha256(cms)
      dependency["records"] = records
      try writeJSON(dependency, to: fixture.dependencyFile)
      try setPrivate(fixture.dependencyFile)

      let result = try run(["prepare", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertTrue(result.stderr.contains("inventory") || result.stderr.contains("checksum"), result.stderr)
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }
  }

  func testActualGate13CMSCertificateMismatchIsRejectedForSameNameSigner() throws {
    try withPrerequisites { fixture, environment in
      let cms = fixture.gate13Root.appendingPathComponent("evidence-v1.cms")
      var cmsText = try String(contentsOf: cms, encoding: .utf8)
      let alternateCertificate = String(repeating: "a", count: 64)
      cmsText = cmsText.replacingOccurrences(of: "certificate-sha256=\(signerCertificate)", with: "certificate-sha256=\(alternateCertificate)")
      try Data(cmsText.utf8).write(to: cms)
      var dependency = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.dependencyFile)) as? [String: Any])
      var records = try XCTUnwrap(dependency["records"] as? [[String: Any]])
      records[0]["cmsDigest"] = try sha256(cms)
      dependency["records"] = records
      try writeJSON(dependency, to: fixture.dependencyFile)
      try setPrivate(fixture.dependencyFile)
      let result = try run(["prepare", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("CMS") || result.stderr.contains("signer"), result.stderr)
    }
  }

  func testActualGate13CMSFingerprintMismatchIsRejectedForSameNameSigner() throws {
    try withPrerequisites { fixture, environment in
      let cms = fixture.gate13Root.appendingPathComponent("evidence-v1.cms")
      var cmsText = try String(contentsOf: cms, encoding: .utf8)
      cmsText = cmsText.replacingOccurrences(of: "fingerprint=\(signerFingerprint)", with: "fingerprint=DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF")
      try Data(cmsText.utf8).write(to: cms)
      var dependency = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.dependencyFile)) as? [String: Any])
      var records = try XCTUnwrap(dependency["records"] as? [[String: Any]])
      records[0]["cmsDigest"] = try sha256(cms)
      dependency["records"] = records
      try writeJSON(dependency, to: fixture.dependencyFile)
      try setPrivate(fixture.dependencyFile)
      let result = try run(["prepare", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("CMS") || result.stderr.contains("signer"), result.stderr)
    }
  }

  func testGate13ReceiptSidecarTamperFailsClosed() throws {
    for name in ["phase08-completion-receipt-v1.sha256", "phase08-completion-receipt-v1.cms"] {
      try withPrerequisites { fixture, environment in
        let sidecar = fixture.gate13Root.appendingPathComponent(name)
        var data = try Data(contentsOf: sidecar)
        data.append(Data("tamper".utf8))
        try data.write(to: sidecar)
        let result = try run(["prepare", "14"], environment: environment)
        XCTAssertNotEqual(result.status, 0, name)
        XCTAssertTrue(result.stderr.contains("receipt") || result.stderr.contains("checksum") || result.stderr.contains("CMS"), result.stderr)
      }
    }
  }

  func testSelfConsistentButFalseGate13DependencyDigestFailsAgainstActualCopy() throws {
    try withPrerequisites { fixture, environment in
      let dependency = fixture.gate13Root.appendingPathComponent("dependency-evidence-v1.json")
      var descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dependency)) as? [String: Any])
      var transitiveRecords = try XCTUnwrap(descriptor["records"] as? [[String: Any]])
      transitiveRecords[0]["cmsDigest"] = String(repeating: "f", count: 64)
      descriptor["records"] = transitiveRecords
      try writeJSON(descriptor, to: dependency)
      try setPrivate(dependency)

      let checksum = fixture.gate13Root.appendingPathComponent("evidence-v1.sha256")
      var checksumLines = try String(contentsOf: checksum, encoding: .utf8).split(separator: "\n").map(String.init)
      let dependencyLine = "\(try sha256(dependency))  dependency-evidence-v1.json"
      checksumLines = checksumLines.map { $0.hasSuffix("  dependency-evidence-v1.json") ? dependencyLine : $0 }
      let checksumText = checksumLines.sorted().joined(separator: "\n") + "\n"
      try Data(checksumText.utf8).write(to: checksum)
      try setPrivate(checksum)
      try writeCMS(payload: checksumText, to: fixture.gate13Root.appendingPathComponent("evidence-v1.cms"))

      var outer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.dependencyFile)) as? [String: Any])
      var outerRecords = try XCTUnwrap(outer["records"] as? [[String: Any]])
      outerRecords[0]["checksumManifestDigest"] = try sha256(checksum)
      outerRecords[0]["cmsDigest"] = try sha256(fixture.gate13Root.appendingPathComponent("evidence-v1.cms"))
      outer["records"] = outerRecords
      try writeJSON(outer, to: fixture.dependencyFile)
      try setPrivate(fixture.dependencyFile)

      let result = try run(["prepare", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("actual Gate 13 dependency descriptor digest"), result.stderr)
    }
  }

  func testActualGate13CMSTeamMismatchIsRejected() throws {
    try withPrerequisites { fixture, environment in
      let cms = fixture.gate13Root.appendingPathComponent("evidence-v1.cms")
      var cmsText = try String(contentsOf: cms, encoding: .utf8)
      cmsText = cmsText.replacingOccurrences(of: "team-id=\(signerTeam)", with: "team-id=ALTTTEAM01")
      try Data(cmsText.utf8).write(to: cms)
      var dependency = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.dependencyFile)) as? [String: Any])
      var records = try XCTUnwrap(dependency["records"] as? [[String: Any]])
      records[0]["cmsDigest"] = try sha256(cms)
      dependency["records"] = records
      try writeJSON(dependency, to: fixture.dependencyFile)
      try setPrivate(fixture.dependencyFile)
      let result = try run(["prepare", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("CMS") || result.stderr.contains("signer"), result.stderr)
    }
  }

  func testStructuredMissingDuplicateAndExtraResultsFailClosed() throws {
    for variant in ["missing", "duplicate", "extra", "zero", "empty", "arbitrary"] {
      try withPrepared { fixture, environment in
        var failing = environment
        failing["HOSTWRIGHT_PHASE09_HARNESS_TEST_RESULT_VARIANT"] = variant
        let result = try run(["run", "14"], environment: failing)
        XCTAssertNotEqual(result.status, 0, variant)
        XCTAssertEqual(try manifestStatus(fixture.root), "failed", variant)
      }
    }
  }

  func testSymlinkedFixedSealTemporaryFailsAndFreezesRoot() throws {
    try withPrepared { fixture, environment in
      let temp = fixture.root.appendingPathComponent(".evidence-v1.cms.tmp")
      try FileManager.default.createSymbolicLink(at: temp, withDestinationURL: fixture.parent.appendingPathComponent("sentinel"))
      let result = try run(["run", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate14-active-v1").path))
      let rerun = try run(["run", "14"], environment: environment)
      XCTAssertNotEqual(rerun.status, 0)
      XCTAssertTrue(rerun.stderr.contains("frozen after failure"), rerun.stderr)
    }
  }

  func testCMSSealFailureLeavesFailedManifestAndBothLocks() throws {
    try withPrepared { fixture, base in
      var environment = base
      environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_FAIL"] = "1"
      let result = try run(["run", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate14-active-v1").path))
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
      let result = try run(["run", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: output.path), sentinel.path)
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate14-active-v1").path))
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
      let result = try run(["run", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("gate-active-run-v1-info.tsv").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate14-active-v1").path))
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
      let result = try run(["run", "14"], environment: base)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate14-active-v1").path))
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
      let result = try run(["run", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate14-active-v1").path))
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
      let result = try run(["run", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "failed")
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate14-active-v1").path))
    }
  }

  func testReusableRejectsNoncanonicalChecksumInventoryWithValidPinnedCMS() throws {
    for variant in ["missing", "duplicate", "extra", "reordered", "renamed"] {
      try withPrepared { fixture, environment in
        let passed = try run(["run", "14"], environment: environment)
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
        let reused = try run(["run", "14"], environment: environment)
        XCTAssertNotEqual(reused.status, 0, variant)
        XCTAssertTrue(reused.stderr.contains("incomplete or changed"), "\(variant): \(reused.stderr)")
        XCTAssertEqual(try manifestStatus(fixture.root), "passed")
      }
    }
  }

  func testSuccessfulTestModeSealingAndExactReuseInventory() throws {
    try withPrepared { fixture, environment in
      let passed = try run(["run", "14"], environment: environment)
      XCTAssertEqual(passed.status, 0, passed.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "passed")
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-run-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate14-active-v1").path))
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count, 26)
      let stateLines = try String(contentsOf: fixture.root.appendingPathComponent("state-v1.tsv"), encoding: .utf8).split(separator: "\n")
      XCTAssertEqual(stateLines.count, 7)
      XCTAssertTrue(stateLines.first?.hasPrefix("gate\tcell\tstatus\t") == true)
      XCTAssertEqual(stateLines.dropFirst().filter { $0.split(separator: "\t").count > 2 && $0.split(separator: "\t")[2] == "pass" }.count, 6)
      let unexpected = fixture.root.appendingPathComponent("unexpected.txt")
      try Data("unexpected".utf8).write(to: unexpected)
      try setPrivate(unexpected)
      let reused = try run(["run", "14"], environment: environment)
      XCTAssertNotEqual(reused.status, 0)
      XCTAssertTrue(reused.stderr.contains("incomplete or changed"), reused.stderr)
    }
  }

  func testPassedRootWithBothFinalSealsDeletedIsFrozen() throws {
    try withPrepared { fixture, environment in
      let passed = try run(["run", "14"], environment: environment)
      XCTAssertEqual(passed.status, 0, passed.stderr)
      try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("evidence-v1.sha256"))
      try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("evidence-v1.cms"))
      let refused = try run(["run", "14"], environment: environment)
      XCTAssertNotEqual(refused.status, 0)
      XCTAssertTrue(refused.stderr.contains("missing one or both final seal files"), refused.stderr)
      XCTAssertEqual(try manifestStatus(fixture.root), "passed")
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(".phase09-gate14-active-v1").path))
    }
  }

  func testPreparationSymlinkFailsClosedAndPreservesSentinel() throws {
    try withPrerequisites { fixture, environment in
      let sentinel = fixture.parent.appendingPathComponent("prepare-symlink-sentinel")
      try Data("unchanged".utf8).write(to: sentinel)
      try setPrivate(sentinel)
      let destination = fixture.root.appendingPathComponent("dependency-evidence-v1.json")
      try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: sentinel)
      let result = try run(["prepare", "14"], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), sentinel.path)
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
    }
  }

  func testSourceContainsPinnedCMSStructuredInventoryAndNoCrossPhaseAccess() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    for required in ["cms -M", "cms -D -u 9", "cms -S -N", "validate_staged_digest", "compare_inventory", "validate_structured_results", "claim none", "O_CREAT | O_EXCL | O_NOFOLLOW", "RENAME_NOFOLLOW_ANY", "atomic_run_outputs", "atomic_publish", "atomic_copy", "create-dir", "replace-log", "path_parent"] {
      XCTAssertTrue(source.contains(required), required)
    }
    XCTAssertFalse(source.contains("O_APPEND"))
    XCTAssertFalse(source.contains("git -C"))
    XCTAssertFalse(source.contains("rm " + "-rf"))
    XCTAssertFalse(source.contains("kil" + "l "))
    XCTAssertFalse(source.contains("gh " + "pr"))
  }

  private struct Fixture {
    let parent: URL
    let root: URL
    let dependencyFile: URL
    let gate13Root: URL
  }

  private func withPrepared(_ body: (Fixture, [String: String]) throws -> Void) throws {
    try withPrerequisites { fixture, environment in
      let prepared = try run(["prepare", "14"], environment: environment)
      XCTAssertEqual(prepared.status, 0, prepared.stderr)
      try body(fixture, environment)
    }
  }

  private func withPrerequisites(_ body: (Fixture, [String: String]) throws -> Void) throws {
    let parent = try makeTemporaryDirectory(prefix: "gate14-harness")
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("phase09-gate14-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let head = try currentCommit()
    let dependencyFile = parent.appendingPathComponent("gate14-dependencies.json")
    let gate13Root = parent.appendingPathComponent("phase09-gate13-\(UUID().uuidString.lowercased())")
    try makeGate13Root(at: gate13Root, sourceCommit: head)
    let gate13Manifest = gate13Root.appendingPathComponent("manifest-v1.json")
    let gate13Checksum = gate13Root.appendingPathComponent("evidence-v1.sha256")
    let gate13CMS = gate13Root.appendingPathComponent("evidence-v1.cms")
    let gate13ManifestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: gate13Manifest)) as? [String: Any])
    try writeJSON([
      "schema": "hostwright.phase09.dependency-evidence.v1",
      "records": [[
        "cmsCertificateSHA256": signerCertificate,
        "cmsDigest": try sha256(gate13CMS),
        "cmsFingerprint": signerFingerprint,
        "cmsIdentity": signerIdentity,
        "cmsTeamID": signerTeam,
        "checksumManifestDigest": try sha256(gate13Checksum),
        "configDigest": try XCTUnwrap(gate13ManifestObject["configDigest"] as? String),
        "dependencyEvidenceCanonicalDigest": try XCTUnwrap(gate13ManifestObject["dependencyEvidenceCanonicalDigest"] as? String),
        "dependencyEvidenceDigest": try XCTUnwrap(gate13ManifestObject["dependencyEvidenceDigest"] as? String),
        "gate": 13,
        "manifestDigest": try sha256(gate13Manifest),
        "matrixDigest": try XCTUnwrap(gate13ManifestObject["matrixDigest"] as? String),
        "rootBasename": gate13Root.lastPathComponent,
        "sourceCommit": head,
        "sourceDigest": try XCTUnwrap(gate13ManifestObject["sourceDigest"] as? String),
        "status": "passed",
        "toolchainDigest": try XCTUnwrap(gate13ManifestObject["toolchainDigest"] as? String)
      ]]
    ], to: dependencyFile)
    try setPrivate(dependencyFile)
    try installSecurityWrapper(at: parent.appendingPathComponent("security"))
    try installSwiftWrapper(in: parent)
    var environment = testEnvironment(parent: parent)
    environment["HOSTWRIGHT_PHASE09_GATE_ROOT"] = root.path
    environment["HOSTWRIGHT_PHASE09_GATE14_DEPENDENCY_EVIDENCE"] = dependencyFile.path
    try body(Fixture(parent: parent, root: root, dependencyFile: dependencyFile, gate13Root: gate13Root), environment)
  }

  private func makeGate13Root(at root: URL, sourceCommit: String) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let dependency = root.appendingPathComponent("dependency-evidence-v1.json")
    let sourceDigest = try currentSourceDigest()
    let configDigest = String(repeating: "a", count: 64)
    let toolchainDigest = String(repeating: "b", count: 64)
    let transitiveRecords: [[String: Any]] = (8...12).map { gate in
      [
        "cmsCertificateSHA256": signerCertificate,
        "cmsDigest": String(repeating: "c", count: 64),
        "cmsFingerprint": signerFingerprint,
        "cmsIdentity": signerIdentity,
        "cmsTeamID": signerTeam,
        "checksumManifestDigest": String(repeating: "d", count: 64),
        "configDigest": configDigest,
        "gate": gate,
        "manifestDigest": String(repeating: "e", count: 64),
        "rootBasename": String(format: "phase09-gate%02d-%@", gate, UUID().uuidString.lowercased()),
        "sourceCommit": sourceCommit,
        "sourceDigest": sourceDigest,
        "status": "passed",
        "toolchainDigest": toolchainDigest
      ]
    }
    try writeJSON(["schema": "hostwright.phase09.dependency-evidence.v1", "records": transitiveRecords], to: dependency)
    try setPrivate(dependency)
    let receipt = root.appendingPathComponent("phase08-completion-receipt-v1.json")
    try writeJSON([
      "cmsVerified": true,
      "finalEvidenceCMSCertificateSHA256": signerCertificate,
      "finalEvidenceCMSDigest": String(repeating: "a", count: 64),
      "finalEvidenceCMSFingerprint": signerFingerprint,
      "finalEvidenceCMSIdentity": signerIdentity,
      "finalEvidenceCMSTeamID": signerTeam,
      "finalEvidenceDigest": String(repeating: "a", count: 64),
      "schema": "hostwright.phase09.phase08-completion-receipt.v1",
      "sourceCommit": sourceCommit,
      "status": "passed"
    ], to: receipt)
    try setPrivate(receipt)
    let receiptChecksum = root.appendingPathComponent("phase08-completion-receipt-v1.sha256")
    let receiptText = "\(try sha256(receipt))  phase08-completion-receipt-v1.json\n"
    try Data(receiptText.utf8).write(to: receiptChecksum)
    try setPrivate(receiptChecksum)
    let receiptCMS = root.appendingPathComponent("phase08-completion-receipt-v1.cms")
    try writeCMS(payload: receiptText, to: receiptCMS)
    let state = root.appendingPathComponent("state-v1.tsv")
    try Data("state\n".utf8).write(to: state)
    try setPrivate(state)
    let ownership = root.appendingPathComponent("ownership-v1.tsv")
    try Data("ownership\n".utf8).write(to: ownership)
    try setPrivate(ownership)
    let toolchain = root.appendingPathComponent("toolchain-v1.txt")
    try Data("toolchain\n".utf8).write(to: toolchain)
    try setPrivate(toolchain)
    let activeInfo = root.appendingPathComponent("gate-active-run-v1-info.tsv")
    try Data("info\n".utf8).write(to: activeInfo)
    try setPrivate(activeInfo)
    for cell in 1...6 {
      let stdout = root.appendingPathComponent(String(format: "cell-%02d.stdout.log", cell))
      let stderr = root.appendingPathComponent(String(format: "cell-%02d.stderr.log", cell))
      try Data("output\n".utf8).write(to: stdout)
      try Data("".utf8).write(to: stderr)
      try setPrivate(stdout); try setPrivate(stderr)
      try writeGate13Result(cell: cell, to: root.appendingPathComponent(String(format: "cell-%02d.xunit.xml", cell)))
    }
    let manifest = root.appendingPathComponent("manifest-v1.json")
    try writeJSON([
      "cellOrder": [1, 2, 3, 4, 5, 6],
      "cmsSigner": ["certificateSHA256": signerCertificate, "fingerprint": signerFingerprint, "teamID": signerTeam, "identity": signerIdentity],
      "completedAt": "2026-08-05T00:00:00Z",
      "configDigest": configDigest,
      "dependencyEvidenceCanonicalDigest": try canonicalDigest(dependency),
      "dependencyEvidenceDigest": try sha256(dependency),
      "evidenceClasses": ["U", "I", "L", "M", "S", "R"],
      "formalClaim": false,
      "gate": 13,
      "matrixDigest": try sha256(gate13Matrix),
      "phase08CompletionReceiptCMSDigest": try sha256(root.appendingPathComponent("phase08-completion-receipt-v1.cms")),
      "phase08CompletionReceiptChecksumDigest": try sha256(receiptChecksum),
      "phase08CompletionReceiptDigest": try sha256(receipt),
      "preparedAt": "2026-08-05T00:00:00Z",
      "schema": "hostwright.phase09.gate13.qualification.manifest.v1",
      "sourceCommit": sourceCommit,
      "sourceDigest": sourceDigest,
      "status": "passed",
      "testMode": true,
      "toolchainDigest": toolchainDigest
    ], to: manifest)
    try setPrivate(manifest)
    let names = (1...6).flatMap { [String(format: "cell-%02d.stderr.log", $0), String(format: "cell-%02d.stdout.log", $0), String(format: "cell-%02d.xunit.xml", $0)] } +
      ["dependency-evidence-v1.json", "gate-active-run-v1-info.tsv", "manifest-v1.json", "ownership-v1.tsv", "phase08-completion-receipt-v1.cms", "phase08-completion-receipt-v1.json", "phase08-completion-receipt-v1.sha256", "state-v1.tsv", "toolchain-v1.txt"]
    let digestText = try names.map { "\(try sha256(root.appendingPathComponent($0)))  \($0)" }.joined(separator: "\n") + "\n"
    let checksum = root.appendingPathComponent("evidence-v1.sha256")
    try Data(digestText.utf8).write(to: checksum)
    try setPrivate(checksum)
    try writeCMS(payload: digestText, to: root.appendingPathComponent("evidence-v1.cms"))
  }

  private func writeGate13Result(cell: Int, to url: URL) throws {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: gate13Matrix)) as? [String: Any])
    let tests = try XCTUnwrap(object["tests"] as? [[String: Any]])
      .filter { ($0["cell"] as? Int) == cell }
    let cases = tests.compactMap { ($0["selector"] as? String)?.split(separator: "/", maxSplits: 1).map(String.init) }
    let xml = "<testsuites><testsuite tests=\"\(cases.count)\" failures=\"0\" errors=\"0\" skipped=\"0\">" +
      cases.map { "<testcase classname=\"\($0[0])\" name=\"\($0[1])\"/>" }.joined() + "</testsuite></testsuites>"
    try Data(xml.utf8).write(to: url)
    try setPrivate(url)
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
      /usr/bin/python3 -c 'import html,json,os,sys; base,raw,expected=sys.argv[1:]; selectors=json.loads(raw); n=int(expected); cases=[tuple(s.split("/",1)) for s in selectors] if selectors and "/" in selectors[0] else [(s,"test%03d"%(i+1)) for i,s in enumerate(selectors) for _ in range(max(1,n//max(1,len(selectors))))]; cases=(cases+[(selectors[len(cases)%len(selectors)],"test%03d"%(len(cases)+1)) for _ in range(max(0,n-len(cases)))])[:n]; variant=os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TEST_RESULT_VARIANT",""); race=os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TEST_RACE_OUTPUT"); race and os.symlink(os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TEST_RACE_TARGET",""),race); cases=cases[:-1] if variant=="missing" else cases; cases=cases+([cases[0]] if variant=="duplicate" else []); cases=cases+([( "UnexpectedSelector","testExtra")] if variant=="extra" else []); cases=[] if variant=="zero" else cases; cases=([(cases[0][0],"")] + cases[1:]) if variant=="empty" and cases else cases; cases=([(cases[0][0],"arbitrary")] + cases[1:]) if variant=="arbitrary" and cases else cases; q=chr(34); header="<testsuites><testsuite tests="+q+str(len(cases))+q+" failures="+q+"0"+q+" errors="+q+"0"+q+" skipped="+q+"0"+q+">"; xml=header+"".join("<testcase classname="+q+html.escape(c)+q+" name="+q+html.escape(t)+q+"/>" for c,t in cases)+"</testsuite></testsuites>"; open(base+"-swift-testing.xml","w").write(xml)' "$base" "$HOSTWRIGHT_PHASE09_EXPECTED_TESTCASES_JSON" "$HOSTWRIGHT_PHASE09_EXPECTED_TESTS"
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
    values["HOSTWRIGHT_PHASE09_HARNESS_TESTING"] = "1"
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

  private func canonicalDigest(_ file: URL) throws -> String {
    let canonicalizer = Process()
    canonicalizer.executableURL = URL(fileURLWithPath: "/usr/bin/jq")
    canonicalizer.arguments = ["-cS", ".", file.path]
    let canonicalOutput = Pipe()
    canonicalizer.standardOutput = canonicalOutput
    try canonicalizer.run()
    canonicalizer.waitUntilExit()
    XCTAssertEqual(canonicalizer.terminationStatus, 0)
    let hasher = Process()
    hasher.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    hasher.arguments = ["-a", "256"]
    let input = Pipe()
    let output = Pipe()
    hasher.standardInput = input
    hasher.standardOutput = output
    try hasher.run()
    input.fileHandleForWriting.write(canonicalOutput.fileHandleForReading.readDataToEndOfFile())
    try input.fileHandleForWriting.close()
    hasher.waitUntilExit()
    XCTAssertEqual(hasher.terminationStatus, 0)
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
