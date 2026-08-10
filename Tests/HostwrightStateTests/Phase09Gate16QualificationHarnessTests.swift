import Foundation
import XCTest

final class Phase09Gate16QualificationHarnessTests: XCTestCase {
  private var repository: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var harness: URL {
    repository.appendingPathComponent("scripts/phase09-gate16-qualification.sh")
  }

  func testContractAndDiagnoseAreExplicitlyNonQualifying() throws {
    let contract = try run(["contract"])
    XCTAssertEqual(contract.status, 0, contract.stderr)
    XCTAssertTrue(contract.stdout.contains("Gate 16 local closure harness contract v4"))
    XCTAssertTrue(contract.stdout.contains("claim:\"none\""))
    XCTAssertTrue(contract.stdout.contains("structured ownership absence receipts"))
    XCTAssertTrue(contract.stdout.contains("pinned certificate fingerprint"))
    XCTAssertTrue(contract.stdout.contains("cannot be retried"))
    XCTAssertTrue(contract.stdout.contains("run 16 and status 16 are read-only"))
    XCTAssertTrue(contract.stdout.contains("Every final-v1 JSON record directly binds"))

    let diagnosis = try run(["diagnose"])
    XCTAssertEqual(diagnosis.status, 0, diagnosis.stderr)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(diagnosis.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(object["schema"] as? String, "hostwright.phase09.gate16.diagnostic.v1")
    XCTAssertEqual(object["claim"] as? String, "none")
    XCTAssertEqual(object["formalPassage"] as? Bool, false)
    XCTAssertEqual(object["publicActionsPerformed"] as? Bool, false)
    XCTAssertEqual((object["sourceDigest"] as? String)?.count, 64)
    XCTAssertEqual((object["configDigest"] as? String)?.count, 64)
    XCTAssertEqual((object["toolchainDigest"] as? String)?.count, 64)
  }

  func testPrepareRefusesMissingGate15DependencyWithoutWritingRoot() throws {
    try withPrivateRoot { root, environment in
      var missing = environment
      missing.removeValue(forKey: "HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT")
      let result = try run(["prepare", "16"], environment: missing)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT"), result.stderr)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
  }

  func testPrepareRefusesIncompleteGate15DependencyBeforeFormalEvidence() throws {
    try withPrivateParent { parent, baseEnvironment in
      let root = try makeRoot(parent: parent)
      let gate15 = parent.appendingPathComponent("phase09-gate15-\(UUID().uuidString.lowercased())")
      try FileManager.default.createDirectory(at: gate15, withIntermediateDirectories: false)
      try setPermissions(gate15, 0o700)
      var environment = baseEnvironment
      environment["HOSTWRIGHT_PHASE09_GATE_ROOT"] = try canonicalPath(root)
      environment["HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT"] = try canonicalPath(gate15)

      let result = try run(["prepare", "16"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("canonical regular files") || result.stderr.contains("Gate 16"), result.stderr)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
  }

  func testLedgerAndReceiptTrustBoundariesAreExplicit() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    for required in [
      "ownership_header",
      "NR > 1",
      "unknown resource kind",
      "absenceReceipts",
      "discoveryPerformed == false",
      "pullRequests | type == \"array\" and length == 1",
      "source identity does not match prepared evidence",
      "phase09Issues | map(.number) | sort",
      "object IDs are missing or duplicated",
      "git rev-list --parents -n 1",
      "git rev-list \"$merge_commit\"",
      "certificateFingerprint",
      "prepared-evidence-v1.cms",
      "final-v1",
      "cmp -s -",
      "security cms -V",
      "security cms -S",
      "finalization-frozen-v1",
      "validate_receipt_formality",
      "validate_transitive_manifest_formality",
      "validate_final_marker_set",
      "finalization-committed-v1",
      "cleanup_finalization_marker_before_publication",
      "HOSTWRIGHT_PHASE09_TEST_CLEANUP_FAILURE",
      "formalClaim",
      "testMode",
      "qualifying",
      "sealed",
      "HOSTWRIGHT_PHASE09_TEST_STAGED_BINDING_TAMPER",
      "test-passed",
    ] {
      XCTAssertTrue(source.contains(required), "missing Gate16 invariant: \(required)")
    }
  }

  func testTestModeCompletesEveryFinalizationStageWithoutFormalEvidence() throws {
    try withPreparedFixture { fixture in
      let result = try run(
        ["finalize", "16", fixture.receipts.path], environment: fixture.environment)
      XCTAssertEqual(result.status, 0, result.stderr + result.stdout)
      XCTAssertTrue(result.stdout.contains("test-only finalization completed"))
      XCTAssertEqual(try manifestStatus(at: fixture.root), "prepared")
      XCTAssertEqual(try publishedManifestStatus(at: fixture.root), "test-passed")
      let finalRoot = fixture.root.appendingPathComponent("final-v1", isDirectory: true)
      let manifest = try jsonObject(at: finalRoot.appendingPathComponent("manifest-v1.json"))
      XCTAssertEqual(manifest["claim"] as? String, "none")
      XCTAssertEqual(manifest["formal"] as? Bool, false)
      XCTAssertEqual(manifest["formalClaim"] as? Bool, false)
      XCTAssertEqual(manifest["testMode"] as? Bool, true)
      XCTAssertEqual(manifest["testOnly"] as? Bool, true)
      XCTAssertEqual(manifest["qualifying"] as? Bool, false)
      XCTAssertEqual(manifest["sealed"] as? Bool, true)
      XCTAssertTrue(FileManager.default.fileExists(atPath: finalRoot.appendingPathComponent("preseal-index-v1.json").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: finalRoot.appendingPathComponent("hard-stop-v1.json").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: finalRoot.appendingPathComponent("seal-v1.json").path))
      let preseal = try jsonObject(at: finalRoot.appendingPathComponent("preseal-index-v1.json"))
      let presealArtifacts = try XCTUnwrap(preseal["artifacts"] as? [[String: Any]])
      XCTAssertTrue(presealArtifacts.contains { $0["name"] as? String == "hard-stop-v1.json" })
      XCTAssertTrue(presealArtifacts.contains { $0["name"] as? String == "cms-signer-v1.json" })
      let seal = try jsonObject(at: finalRoot.appendingPathComponent("seal-v1.json"))
      XCTAssertEqual(seal["status"] as? String, "test-sealed")
      XCTAssertEqual(seal["formal"] as? Bool, false)
      XCTAssertEqual(seal["formalClaim"] as? Bool, false)
      XCTAssertEqual(seal["testMode"] as? Bool, true)
      XCTAssertEqual(seal["testOnly"] as? Bool, true)
      XCTAssertEqual(seal["qualifying"] as? Bool, false)
      XCTAssertEqual(seal["sealed"] as? Bool, true)
      let signer = try XCTUnwrap(seal["cmsSigner"] as? [String: Any])
      XCTAssertEqual(signer["identity"] as? String, "testing-cms-signer")
      XCTAssertEqual(signer["fingerprint"] as? String, "testing-cms-fingerprint")
      XCTAssertEqual(signer["certificateFingerprint"] as? String, "testing-cms-certificate")
      XCTAssertEqual(signer["teamID"] as? String, "testing")
      let cms = try jsonObject(at: finalRoot.appendingPathComponent("evidence-v1.cms"))
      XCTAssertEqual(cms["testOnly"] as? Bool, true)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-frozen-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-active-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-committed-v1/info-v1.tsv").path))
    }
  }

  func testDuplicateAndWrongParentReceiptsFreezeRootsPermanently() throws {
    try withPreparedFixture { fixture in
      var duplicate = fixture.receiptObject
      duplicate["pullRequests"] = [fixture.receiptObject["pullRequests"] as Any, fixture.receiptObject["pullRequests"] as Any]
      let duplicateURL = fixture.parent.appendingPathComponent("duplicate-receipts.json")
      try writeJSON(duplicate, to: duplicateURL)
      let failed = try run(["finalize", "16", duplicateURL.path], environment: fixture.environment)
      XCTAssertNotEqual(failed.status, 0)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-frozen-v1").path))
      let retry = try run(["finalize", "16", fixture.receipts.path], environment: fixture.environment)
      XCTAssertNotEqual(retry.status, 0)
      XCTAssertTrue(retry.stderr.contains("frozen"), retry.stderr)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("evidence-v1.cms").path))
    }

    try withPreparedFixture { fixture in
      var wrongParent = fixture.receiptObject
      var proof = try XCTUnwrap(wrongParent["mergeProof"] as? [String: Any])
      proof["parents"] = [String(repeating: "3", count: 40), fixture.source]
      wrongParent["mergeProof"] = proof
      let wrongURL = fixture.parent.appendingPathComponent("wrong-parent-receipts.json")
      try writeJSON(wrongParent, to: wrongURL)
      let failed = try run(["finalize", "16", wrongURL.path], environment: fixture.environment)
      XCTAssertNotEqual(failed.status, 0)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-frozen-v1").path))
    }
  }

  func testMissingAndInvalidReceiptArgumentsFreezeAValidPreparedRoot() throws {
    try withPreparedFixture { fixture in
      let missing = try run(["finalize", "16"], environment: fixture.environment)
      XCTAssertNotEqual(missing.status, 0)
      XCTAssertTrue(missing.stderr.contains("usage: finalize 16"), missing.stderr)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-frozen-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("failure-v1.tsv").path))
    }

    try withPreparedFixture { fixture in
      let invalid = fixture.parent.appendingPathComponent("missing-receipts.json")
      let result = try run(["finalize", "16", invalid.path], environment: fixture.environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("canonical regular files"), result.stderr)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-frozen-v1").path))
    }
  }

  func testUnexpectedFinalizeExitUsesExitTrapAndFreezesRoot() throws {
    try withPreparedFixture { fixture in
      var environment = fixture.environment
      environment["HOSTWRIGHT_PHASE09_TEST_UNEXPECTED_FINALIZE_EXIT"] = "1"
      let result = try run(["finalize", "16", fixture.receipts.path], environment: environment)
      XCTAssertEqual(result.status, 74, result.stderr)
      XCTAssertTrue(result.stderr.contains("unexpected finalization exit 74"), result.stderr)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-frozen-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("final-v1").path))
    }
  }

  func testSignerTamperAndSealInterruptionFreezeWithoutAFormalClaim() throws {
    try withPrivateParent { parent, baseEnvironment in
      let root = try makeRoot(parent: parent)
      var environment = baseEnvironment
      environment["HOSTWRIGHT_PHASE09_GATE_ROOT"] = try canonicalPath(root)
      let fixture = try makeGate15Fixture(parent: parent, environment: environment)
      var tampered = try jsonObject(at: fixture.manifest)
      tampered["signingFingerprint"] = "testing-tampered"
      try writeJSON(tampered, to: fixture.manifest)
      let result = try run(["prepare", "16"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    try withPreparedFixture { fixture in
      var interrupted = fixture.environment
      interrupted["HOSTWRIGHT_PHASE09_TEST_SEAL_INTERRUPT"] = "1"
      let result = try run(["finalize", "16", fixture.receipts.path], environment: interrupted)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-frozen-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("final-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("seal-v1.json").path))
    }
  }

  func testPreparedBindingTamperFreezesBeforePublication() throws {
    try withPreparedFixture { fixture in
      var binding = try jsonObject(at: fixture.root.appendingPathComponent("prepared-binding-v1.json"))
      binding["sourceDigest"] = String(repeating: "f", count: 64)
      try writeJSON(binding, to: fixture.root.appendingPathComponent("prepared-binding-v1.json"))
      let result = try run(["finalize", "16", fixture.receipts.path], environment: fixture.environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("failure-v1.tsv").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("final-v1").path))
    }
  }

  func testReceiptBodyCommentAndHeadMismatchesFreezeBeforePublication() throws {
    try withPreparedFixture { fixture in
      var receipt = fixture.receiptObject
      var pr = try XCTUnwrap(receipt["pullRequests"] as? [[String: Any]])[0]
      let tamperedBody = (pr["body"] as? String ?? "") + "\nTampered.\n"
      pr["body"] = tamperedBody
      pr["bodyDigest"] = try sha256String(tamperedBody)
      receipt["pullRequests"] = [pr]
      let url = fixture.parent.appendingPathComponent("body-mismatch.json")
      try writeJSON(receipt, to: url)
      let result = try run(["finalize", "16", url.path], environment: fixture.environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
    }

    try withPreparedFixture { fixture in
      var receipt = fixture.receiptObject
      var comment = try XCTUnwrap(receipt["evidenceComment"] as? [String: Any])
      let tamperedComment = (comment["body"] as? String ?? "") + "\nTampered.\n"
      comment["body"] = tamperedComment
      comment["bodyDigest"] = try sha256String(tamperedComment)
      receipt["evidenceComment"] = comment
      let url = fixture.parent.appendingPathComponent("comment-mismatch.json")
      try writeJSON(receipt, to: url)
      let result = try run(["finalize", "16", url.path], environment: fixture.environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
    }

    try withPreparedFixture { fixture in
      var receipt = fixture.receiptObject
      var pr = try XCTUnwrap(receipt["pullRequests"] as? [[String: Any]])[0]
      pr["headCommit"] = String(repeating: "3", count: 40)
      receipt["pullRequests"] = [pr]
      let url = fixture.parent.appendingPathComponent("head-mismatch.json")
      try writeJSON(receipt, to: url)
      let result = try run(["finalize", "16", url.path], environment: fixture.environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
    }
  }

  func testPartialPublicationCrashLeavesNoFinalDirectoryAndBlocksRetry() throws {
    try withPreparedFixture { fixture in
      var environment = fixture.environment
      environment["HOSTWRIGHT_PHASE09_TEST_PARTIAL_PUBLICATION"] = "1"
      let result = try run(["finalize", "16", fixture.receipts.path], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-frozen-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("final-v1").path))
      let retry = try run(["finalize", "16", fixture.receipts.path], environment: fixture.environment)
      XCTAssertNotEqual(retry.status, 0)
      XCTAssertTrue(retry.stderr.contains("frozen"), retry.stderr)
    }
  }

  func testCleanupFailureBeforePublicationLeavesNoPassedFinalAndFreezesRoot() throws {
    try withPreparedFixture { fixture in
      var environment = fixture.environment
      environment["HOSTWRIGHT_PHASE09_TEST_CLEANUP_FAILURE"] = "1"
      let result = try run(["finalize", "16", fixture.receipts.path], environment: environment)
      XCTAssertEqual(result.status, 75, result.stderr)
      XCTAssertTrue(result.stderr.contains("pre-publication cleanup failure"), result.stderr)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("final-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-frozen-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-committed-v1/info-v1.tsv").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-active-v1").path))

      let status = try run(["status", "16"], environment: fixture.environment)
      XCTAssertEqual(status.status, 0, status.stderr)
      XCTAssertTrue(status.stdout.contains("\"status\":\"failed\""), status.stdout)
      XCTAssertTrue(status.stdout.contains("\"finalizationCompleted\":false"), status.stdout)

      let retry = try run(["finalize", "16", fixture.receipts.path], environment: fixture.environment)
      XCTAssertNotEqual(retry.status, 0)
      XCTAssertTrue(retry.stderr.contains("frozen"), retry.stderr)
    }
  }

  func testEveryFinalJSONRecordBindsHeadMergeAndPullRequest() throws {
    try withPreparedFixture { fixture in
      let result = try run(["finalize", "16", fixture.receipts.path], environment: fixture.environment)
      XCTAssertEqual(result.status, 0, result.stderr + result.stdout)
      let proof = try XCTUnwrap(fixture.receiptObject["mergeProof"] as? [String: Any])
      let merge = try XCTUnwrap(proof["commit"] as? String)
      let finalRoot = fixture.root.appendingPathComponent("final-v1", isDirectory: true)
      let names = [
        "cleanup-v1.json", "closure-plan-v1.json", "closure-receipts-v1.json", "cms-signer-v1.json",
        "dependency-evidence-v1.json", "governance-event-v1.json", "hard-stop-v1.json", "manifest-v1.json",
        "preseal-index-v1.json", "prepared-binding-v1.json", "prepared-cms-signer-v1.json",
        "prepared-seal-index-v1.json", "seal-v1.json",
      ]
      for name in names {
        let object = try jsonObject(at: finalRoot.appendingPathComponent(name))
        XCTAssertEqual(object["sourceCommit"] as? String, fixture.source, name)
        XCTAssertEqual(object["headCommit"] as? String, fixture.source, name)
        XCTAssertEqual(object["mergeCommit"] as? String, merge, name)
        XCTAssertEqual(object["prNumber"] as? Int, 206, name)
      }
      let seal = try jsonObject(at: finalRoot.appendingPathComponent("seal-v1.json"))
      XCTAssertEqual(seal["manifestDigest"] as? String, try digest(finalRoot.appendingPathComponent("manifest-v1.json")))
      XCTAssertEqual(seal["presealIndexDigest"] as? String, try digest(finalRoot.appendingPathComponent("preseal-index-v1.json")))
    }
  }

  func testFreezeFailureIsSurfacedAndLeavesRetryBlocked() throws {
    try withPreparedFixture { fixture in
      var binding = try jsonObject(at: fixture.root.appendingPathComponent("prepared-binding-v1.json"))
      binding["sourceDigest"] = String(repeating: "e", count: 64)
      try writeJSON(binding, to: fixture.root.appendingPathComponent("prepared-binding-v1.json"))
      var environment = fixture.environment
      environment["HOSTWRIGHT_PHASE09_TEST_FREEZE_FAILURE"] = "1"
      let result = try run(["finalize", "16", fixture.receipts.path], environment: environment)
      XCTAssertEqual(result.status, 75)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-frozen-v1").path))
      XCTAssertTrue(result.stderr.contains("failure freeze failed"), result.stderr)
      let retry = try run(["finalize", "16", fixture.receipts.path], environment: fixture.environment)
      XCTAssertNotEqual(retry.status, 0)
      XCTAssertTrue(retry.stderr.contains("frozen"), retry.stderr)
    }
  }

  func testStagedBindingTamperFreezesBeforePublication() throws {
    try withPreparedFixture { fixture in
      var environment = fixture.environment
      environment["HOSTWRIGHT_PHASE09_TEST_STAGED_BINDING_TAMPER"] = "1"
      let result = try run(["finalize", "16", fixture.receipts.path], environment: environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertTrue(
        result.stderr.contains("prepared-binding") || result.stderr.contains("prepared checksum"),
        result.stderr)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("finalization-frozen-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("final-v1").path))
    }
  }

  func testInvalidAndNonTotalTimestampsFreezeBeforePublication() throws {
    try withPreparedFixture { fixture in
      var receipt = fixture.receiptObject
      var issues = try XCTUnwrap(receipt["phase09Issues"] as? [[String: Any]])
      issues[0]["closedAt"] = "2026-02-30T02:01:01Z"
      receipt["phase09Issues"] = issues
      let url = fixture.parent.appendingPathComponent("invalid-timestamp.json")
      try writeJSON(receipt, to: url)
      let result = try run(["finalize", "16", url.path], environment: fixture.environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
    }

    try withPreparedFixture { fixture in
      var receipt = fixture.receiptObject
      var issues = try XCTUnwrap(receipt["phase09Issues"] as? [[String: Any]])
      issues[1]["closedAt"] = issues[0]["closedAt"]
      receipt["phase09Issues"] = issues
      let url = fixture.parent.appendingPathComponent("non-total-timestamp.json")
      try writeJSON(receipt, to: url)
      let result = try run(["finalize", "16", url.path], environment: fixture.environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(try manifestStatus(at: fixture.root), "failed")
    }
  }

  func testMissingContradictoryNestedAndSealedMarkersAreRejectedDeterministically() throws {
    try withPrivateParent { parent, baseEnvironment in
      let root = try makeRoot(parent: parent)
      var environment = baseEnvironment
      environment["HOSTWRIGHT_PHASE09_GATE_ROOT"] = try canonicalPath(root)
      let gate15 = try makeGate15Fixture(parent: parent, environment: environment)
      var dependency = try jsonObject(at: gate15.root.appendingPathComponent("dependency-evidence-v1.json"))
      dependency["formal"] = true
      dependency["testOnly"] = false
      try writeJSON(dependency, to: gate15.root.appendingPathComponent("dependency-evidence-v1.json"))
      environment["HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT"] = try canonicalPath(gate15.root)
      let result = try run(["prepare", "16"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("all markers are mandatory"), result.stderr)
    }

    try withPrivateParent { parent, baseEnvironment in
      let root = try makeRoot(parent: parent)
      var environment = baseEnvironment
      environment["HOSTWRIGHT_PHASE09_GATE_ROOT"] = try canonicalPath(root)
      let gate15 = try makeGate15Fixture(parent: parent, environment: environment)
      var dependency = try jsonObject(at: gate15.root.appendingPathComponent("dependency-evidence-v1.json"))
      dependency.removeValue(forKey: "formal")
      try writeJSON(dependency, to: gate15.root.appendingPathComponent("dependency-evidence-v1.json"))
      environment["HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT"] = try canonicalPath(gate15.root)
      let result = try run(["prepare", "16"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("all markers are mandatory"), result.stderr)
    }

    try withPrivateParent { parent, baseEnvironment in
      let root = try makeRoot(parent: parent)
      var environment = baseEnvironment
      environment["HOSTWRIGHT_PHASE09_GATE_ROOT"] = try canonicalPath(root)
      let gate15 = try makeGate15Fixture(parent: parent, environment: environment)
      var dependency = try jsonObject(at: gate15.root.appendingPathComponent("dependency-evidence-v1.json"))
      var entries = try XCTUnwrap(dependency["gates"] as? [[String: Any]])
      entries[0]["formalClaim"] = true
      entries[0]["testMode"] = false
      dependency["gates"] = entries
      try writeJSON(dependency, to: gate15.root.appendingPathComponent("dependency-evidence-v1.json"))
      environment["HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT"] = try canonicalPath(gate15.root)
      let result = try run(["prepare", "16"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("all markers are mandatory"), result.stderr)
    }

    try withPrivateParent { parent, baseEnvironment in
      let root = try makeRoot(parent: parent)
      var environment = baseEnvironment
      environment["HOSTWRIGHT_PHASE09_GATE_ROOT"] = try canonicalPath(root)
      let gate15 = try makeGate15Fixture(parent: parent, environment: environment)
      let dependency = try jsonObject(at: gate15.root.appendingPathComponent("dependency-evidence-v1.json"))
      let entry = try XCTUnwrap(dependency["gates"] as? [[String: Any]])[0]
      let transitive = parent.appendingPathComponent(entry["rootBasename"] as? String ?? "missing")
      var manifest = try jsonObject(at: transitive.appendingPathComponent("manifest-v1.json"))
      manifest.removeValue(forKey: "sealed")
      try writeJSON(manifest, to: transitive.appendingPathComponent("manifest-v1.json"))
      environment["HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT"] = try canonicalPath(gate15.root)
      let result = try run(["prepare", "16"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("all markers are mandatory"), result.stderr)
    }
  }

  func testRepositoryScriptHasNoPublicMutationOrProtectedRuntimePath() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    for forbidden in [
      "gh ", "curl", "wget", "git push", "git commit", "git merge", "enforce-closure",
      "rm -rf", "launchctl", "container ", "Phase 10",
    ] {
      XCTAssertFalse(source.contains(forbidden), "unexpected forbidden operation: \(forbidden)")
    }
    for required in [
      "HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT", "closure-plan-v1.json", "prepared-binding-v1.json",
      "preseal-index-v1.json", "proposed-pr-body.md", "proposed-evidence-comment.md", "security cms -S",
      "security cms -V", "security cms -V -N \"$expected_cms_identity\"",
      "security cms -D -N \"$expected_cms_identity\"", "publicActionsPerformed:false", "noNextPhase",
      "Gate 16 local evidence sealed", "certificateFingerprint", "teamID", "prepared-evidence-v1.cms",
      "final-v1", "cmp -s -", "cmsVerified", "ledger-pinned resource to be absent", "discoveryPerformed",
      "on_finalize_exit", "HOSTWRIGHT_PHASE09_TEST_UNEXPECTED_FINALIZE_EXIT", "sourceCommit:$source",
      "headCommit:$head", "mergeCommit:$merge", "prNumber:$pr", "validate_final_bindings",
    ] {
      XCTAssertTrue(source.contains(required), "missing local-only closure invariant: \(required)")
    }
    XCTAssertFalse(source.contains("find-identity"))
  }

  func testInvalidCommandsAndGateNumbersFailClosed() throws {
    let wrongPrepare = try run(["prepare", "15"])
    XCTAssertNotEqual(wrongPrepare.status, 0)
    XCTAssertTrue(wrongPrepare.stderr.contains("only prepare 16"), wrongPrepare.stderr)

    let wrongFinalize = try run(["finalize", "15"])
    XCTAssertNotEqual(wrongFinalize.status, 0)
    XCTAssertTrue(wrongFinalize.stderr.contains("finalize 16"), wrongFinalize.stderr)

    let readOnly = try run(["run", "16"], environment: ["HOSTWRIGHT_PHASE09_GATE_ROOT": ""])
    XCTAssertEqual(readOnly.status, 0, readOnly.stderr)
    XCTAssertTrue(readOnly.stdout.contains("hostwright.phase09.gate16.status.v1"), readOnly.stdout)
    XCTAssertTrue(readOnly.stdout.contains("\"claim\":\"none\""), readOnly.stdout)

    let unknown = try run(["unknown", "16"])
    XCTAssertNotEqual(unknown.status, 0)
    XCTAssertTrue(unknown.stderr.contains("unknown qualification command"), unknown.stderr)
  }

  private struct Gate15Fixture {
    let root: URL
    let manifest: URL
    let ledger: [[String: String]]
    let source: String
  }

  private struct PreparedFixture {
    let parent: URL
    let root: URL
    let receipts: URL
    let receiptObject: [String: Any]
    let environment: [String: String]
    let source: String
  }

  private func withPrivateRoot(
    _ body: (URL, [String: String]) throws -> Void
  ) throws {
    try withPrivateParent { parent, baseEnvironment in
      let root = try makeRoot(parent: parent)
      var environment = baseEnvironment
      environment["HOSTWRIGHT_PHASE09_GATE_ROOT"] = try canonicalPath(root)
      try body(root, environment)
    }
  }

  private func withPrivateParent(
    _ body: (URL, [String: String]) throws -> Void
  ) throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-phase09-gate16-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    try setPermissions(parent, 0o700)
    defer { try? FileManager.default.removeItem(at: parent) }
    let canonicalParent = URL(fileURLWithPath: try canonicalPath(parent), isDirectory: true)
    try body(canonicalParent, [
      "HOSTWRIGHT_PHASE09_HARNESS_TESTING": "1",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT": canonicalParent.path,
    ])
  }

  private func withPreparedFixture(
    _ body: (PreparedFixture) throws -> Void
  ) throws {
    try withPrivateParent { parent, baseEnvironment in
      let root = try makeRoot(parent: parent)
      var environment = baseEnvironment
      environment["HOSTWRIGHT_PHASE09_GATE_ROOT"] = try canonicalPath(root)
      let gate15 = try makeGate15Fixture(parent: parent, environment: environment)
      environment["HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT"] = try canonicalPath(gate15.root)
      let prepared = try run(["prepare", "16"], environment: environment)
      XCTAssertEqual(prepared.status, 0, prepared.stderr)
      let receiptsURL = parent.appendingPathComponent("receipts.json")
      let receipts = try makeReceipts(gate15: gate15, root: root)
      try writeJSON(receipts, to: receiptsURL)
      try body(PreparedFixture(
        parent: parent, root: root, receipts: receiptsURL, receiptObject: receipts,
        environment: environment, source: gate15.source))
    }
  }

  private func makeGate15Fixture(
    parent: URL, environment: [String: String]
  ) throws -> Gate15Fixture {
    // The first local governance probe may materialize ignored/generated state; bind the fixture
    // to the stable digest observed by the second probe and by prepare.
    let preliminaryDiagnosis = try run(["diagnose"], environment: environment)
    XCTAssertEqual(preliminaryDiagnosis.status, 0, preliminaryDiagnosis.stderr)
    let diagnosis = try run(["diagnose"], environment: environment)
    XCTAssertEqual(diagnosis.status, 0, diagnosis.stderr)
    let diagnostic = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(diagnosis.stdout.utf8)) as? [String: Any])
    let source = try gitHead()
    let sourceDigest = try XCTUnwrap(diagnostic["sourceDigest"] as? String)
    let configDigest = try XCTUnwrap(diagnostic["configDigest"] as? String)
    let toolchainDigest = try XCTUnwrap(diagnostic["toolchainDigest"] as? String)
    let gate15 = parent.appendingPathComponent("phase09-gate15-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: gate15, withIntermediateDirectories: false)
    try setPermissions(gate15, 0o700)

    var entries: [[String: Any]] = []
    for gate in 1...14 {
      let transitive = try makeTransitiveRoot(
        parent: parent, gate: gate, source: source, sourceDigest: sourceDigest, configDigest: configDigest,
        toolchainDigest: toolchainDigest)
      entries.append([
        "gate": gate, "rootBasename": transitive.root.lastPathComponent, "status": "passed",
        "claim": "none", "formal": false, "formalClaim": false, "testMode": true,
        "testOnly": true, "qualifying": false, "sealed": true,
        "sourceCommit": source, "sourceDigest": sourceDigest, "configDigest": configDigest,
        "toolchainDigest": toolchainDigest, "dependencyEvidenceDigest": transitive.dependencyEvidenceDigest,
        "manifestDigest": transitive.manifestDigest, "checksumDigest": transitive.checksumDigest,
        "cmsDigest": transitive.cmsDigest, "signingIdentity": "testing-cms-signer",
        "signingFingerprint": "testing-cms-fingerprint", "certificateFingerprint": "testing-cms-certificate",
        "teamID": "testing",
      ])
    }
    let dependencyURL = gate15.appendingPathComponent("dependency-evidence-v1.json")
    try writeJSON([
      "schema": "hostwright.phase09.gate15.dependencies.v1",
      "status": "passed", "claim": "none", "formal": false, "formalClaim": false, "testMode": true,
      "cmsVerified": false, "testOnly": true, "qualifying": false, "sealed": true, "gates": entries,
    ], to: dependencyURL)
    let manifestURL = gate15.appendingPathComponent("manifest-v1.json")
    try writeJSON([
      "schema": "hostwright.phase09.gate15.qualification.manifest.v1", "gate": 15,
      "status": "passed", "claim": "none", "formal": false, "formalClaim": false, "testMode": true,
      "testOnly": true, "qualifying": false, "sealed": true,
      "sourceCommit": source, "sourceDigest": sourceDigest, "configDigest": configDigest,
      "toolchainDigest": toolchainDigest, "dependencyEvidenceDigest": try digest(dependencyURL),
      "signingIdentity": "testing-cms-signer", "signingFingerprint": "testing-cms-fingerprint",
      "certificateFingerprint": "testing-cms-certificate", "teamID": "testing",
    ], to: manifestURL)
    let ledger = makeLedger(parent: parent)
    let ledgerLines = ledger.map {
      [$0["recordedAt"]!, $0["type"]!, $0["identifier"]!, $0["path"]!, $0["device"]!, $0["inode"]!, $0["identity"]!]
        .joined(separator: "\t")
    }
    try writeText(
      "recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity\n" + ledgerLines.joined(separator: "\n") + "\n",
      to: gate15.appendingPathComponent("ownership-v1.tsv"))
    try writeText(
      "path\tsha256\tcdhash\tteamID\tidentifier\ntesting\ttesting\ttesting\ttesting\ttesting\n",
      to: gate15.appendingPathComponent("signed-executables-v1.tsv"))
    let checksumURL = gate15.appendingPathComponent("evidence-v1.sha256")
    try writeChecksum(
      files: ["manifest-v1.json", "dependency-evidence-v1.json", "ownership-v1.tsv", "signed-executables-v1.tsv"],
      root: gate15, to: checksumURL)
    try makeTestCMS(bundle: gate15, checksum: checksumURL)
    return Gate15Fixture(root: gate15, manifest: manifestURL, ledger: ledger, source: source)
  }

  private func makeTransitiveRoot(
    parent: URL, gate: Int, source: String, sourceDigest: String, configDigest: String, toolchainDigest: String
  ) throws -> (root: URL, manifestDigest: String, checksumDigest: String, cmsDigest: String, dependencyEvidenceDigest: String) {
    let root = parent.appendingPathComponent(
      String(format: "phase09-gate%02d-%@", gate, UUID().uuidString.lowercased()), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try setPermissions(root, 0o700)
    let manifest = root.appendingPathComponent("manifest-v1.json")
    let dependencyDigest = String(repeating: "d", count: 64)
    try writeJSON([
      "schema": String(format: "hostwright.phase09.gate%02d.qualification.manifest.v1", gate),
      "gate": gate, "status": "passed", "claim": "none", "formal": false, "formalClaim": false,
      "testMode": true, "testOnly": true, "qualifying": false, "sealed": true, "sourceCommit": source,
      "sourceDigest": sourceDigest, "configDigest": configDigest, "toolchainDigest": toolchainDigest,
      "dependencyEvidenceDigest": dependencyDigest, "signingIdentity": "testing-cms-signer",
      "signingFingerprint": "testing-cms-fingerprint", "certificateFingerprint": "testing-cms-certificate",
      "teamID": "testing",
    ], to: manifest)
    let checksum = root.appendingPathComponent("evidence-v1.sha256")
    try writeChecksum(files: ["manifest-v1.json"], root: root, to: checksum)
    try makeTestCMS(bundle: root, checksum: checksum)
    return (root, try digest(manifest), try digest(checksum), try digest(root.appendingPathComponent("evidence-v1.cms")), dependencyDigest)
  }

  private func makeTestCMS(bundle: URL, checksum: URL) throws {
    let payload = try String(contentsOf: checksum, encoding: .utf8)
    try writeJSON([
      "schema": "hostwright.phase09.test.cms.v1", "payload": payload,
      "payloadDigest": try digest(checksum), "testOnly": true,
      "signer": ["identity": "testing-cms-signer", "fingerprint": "testing-cms-fingerprint",
                  "certificateFingerprint": "testing-cms-certificate", "teamID": "testing"],
    ], to: bundle.appendingPathComponent("evidence-v1.cms"))
    try writeJSON([
      "schema": "hostwright.phase09.test.cms-signer.v1", "identity": "testing-cms-signer",
      "certificateFingerprint": "testing-cms-certificate", "teamID": "testing",
    ], to: bundle.appendingPathComponent("cms-signer-v1.json"))
  }

  private func makeLedger(parent: URL) -> [[String: String]] {
    let pathRoot = parent.appendingPathComponent("absence-resource-root-(UUID().uuidString.lowercased())").path
    let pathFile = parent.appendingPathComponent("absence-resource-file-(UUID().uuidString.lowercased())").path
    let pathSocket = parent.appendingPathComponent("absence-resource-socket-(UUID().uuidString.lowercased())").path
    let pathXPC = parent.appendingPathComponent("absence-resource-xpc-(UUID().uuidString.lowercased())").path
    return [
      ledgerRow("temporary-root", "root-1", pathRoot, "1", "11"),
      ledgerRow("temporary-file", "file-1", pathFile, "1", "12"),
      ledgerRow("socket", "socket-1", pathSocket, "1", "13"),
      ledgerRow("process", "process-1", "-", "-", "-"),
      ledgerRow("container", "container-1", "-", "-", "-"),
      ledgerRow("xpc", "xpc-1", pathXPC, "1", "14"),
      ledgerRow("launchd", "launchd-1", "-", "-", "-"),
      ledgerRow("keychain", "keychain-1", "-", "-", "-"),
    ]
  }

  private func ledgerRow(
    _ type: String, _ identifier: String, _ path: String, _ device: String, _ inode: String
  ) -> [String: String] {
    ["recordedAt": "2026-08-05T00:00:00Z", "type": type, "identifier": identifier,
     "path": path, "device": device, "inode": inode, "identity": "owned=gate15"]
  }

  private func makeReceipts(gate15: Gate15Fixture, root: URL) throws -> [String: Any] {
    let body = try String(contentsOf: root.appendingPathComponent("proposed-pr-body.md"), encoding: .utf8)
    let comment = try String(contentsOf: root.appendingPathComponent("proposed-evidence-comment.md"), encoding: .utf8)
    let merge = String(repeating: "2", count: 40)
    let base = String(repeating: "1", count: 40)
    let checks = [
      "CI / test", "Roadmap governance / pull-request-closure-gate",
      "Documentation and website / core-documentation",
    ].enumerated().map { index, name in
      ["name": name, "conclusion": "success", "prNumber": 206, "headCommit": gate15.source,
       "mergeCommit": merge, "objectId": "check-\(index + 1)", "completedAt": "2026-08-05T01:00:0\(index)Z"] as [String: Any]
    }
    let issues = [195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205].enumerated().map { index, number in
      ["number": number, "state": "closed", "labels": ["status:verification"], "prNumber": 206,
       "headCommit": gate15.source, "mergeCommit": merge, "objectId": "issue-\(number)-\(index)",
       "closedAt": String(format: "2026-08-05T02:01:%02dZ", index + 1)] as [String: Any]
    }
    let absence = gate15.ledger.enumerated().map { index, row in
      ["type": row["type"]!, "identifier": row["identifier"]!, "path": row["path"]!,
       "device": row["device"]!, "inode": row["inode"]!, "identity": row["identity"]!,
       "status": "absent", "observedExists": false, "gate15RootBasename": gate15.root.lastPathComponent,
       "prNumber": 206, "headCommit": gate15.source, "mergeCommit": merge, "objectId": "absence-\(index + 1)",
       "observedAt": String(format: "2026-08-05T02:02:%02dZ", index + 1)] as [String: Any]
    }
    let pr: [String: Any] = [
      "number": 206, "state": "closed", "merged": true, "headCommit": gate15.source,
      "baseCommit": base, "mergeCommit": merge, "headRef": "feat/v0.0.2-phase-09", "baseRef": "main",
      "labels": ["status:verification"], "body": body, "bodyDigest": try sha256String(body),
      "objectId": "pr-206-1", "openedAt": "2026-08-05T00:00:00Z",
      "mergedAt": "2026-08-05T02:00:00Z", "closedAt": "2026-08-05T02:01:00Z",
    ]
    return [
      "schema": "hostwright.phase09.gate16.receipts.v1", "sourceCommit": gate15.source,
      "pullRequests": [pr],
      "mergeProof": ["prNumber": 206, "commit": merge, "baseCommit": base, "headCommit": gate15.source,
                      "parents": [base, gate15.source], "objectId": "merge-proof-1"],
      "checks": checks,
      "reviews": [["prNumber": 206, "headCommit": gate15.source, "mergeCommit": merge, "state": "APPROVED", "reviewer": "maintainer-1",
                   "objectId": "review-1", "submittedAt": "2026-08-05T01:30:00Z"]],
      "phase09Issues": issues,
      "evidenceComment": ["issueNumber": 206, "prNumber": 206, "headCommit": gate15.source, "mergeCommit": merge, "posted": true,
                          "marker": "<!-- hostwright-evidence-gate:v1 -->", "body": comment,
                          "bodyDigest": try sha256String(comment), "objectId": "comment-1",
                          "postedAt": "2026-08-05T02:02:00Z"],
      "cleanup": ["schema": "hostwright.phase09.gate16.cleanup.v1", "status": "passed", "prNumber": 206,
                  "headCommit": gate15.source,
                  "mergeCommit": merge, "gate15RootBasename": gate15.root.lastPathComponent,
                  "worktreeClean": true, "phase09ResourcesAbsent": true, "discoveryPerformed": false,
                  "activeLocks": [], "ownedResources": [], "absenceReceipts": absence,
                  "objectId": "cleanup-1", "recordedAt": "2026-08-05T02:03:00Z"],
      "hardStop": ["schema": "hostwright.phase09.gate16.hard-stop.v1", "status": "passed", "recorded": true,
                   "noNextPhase": true, "phase10Started": false, "tagCreated": false, "releasePublished": false,
                   "publicActionsAfterMerge": 0, "prNumber": 206, "headCommit": gate15.source, "mergeCommit": merge,
                   "objectId": "hard-stop-1", "timestamp": "2026-08-05T02:04:00Z"],
    ]
  }

  private func makeRoot(parent: URL) throws -> URL {
    let root = parent.appendingPathComponent(
      "phase09-gate16-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try setPermissions(root, 0o700)
    return root
  }

  private func run(
    _ arguments: [String], environment: [String: String] = [:]
  ) throws -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [harness.path] + arguments
    var values = ProcessInfo.processInfo.environment
    environment.forEach { values[$0.key] = $0.value }
    process.environment = values
    process.currentDirectoryURL = repository
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return ShellResult(
      status: process.terminationStatus,
      stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
  }

  private func jsonObject(at url: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  private func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: url)
    try setPermissions(url, 0o600)
  }

  private func writeText(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
    try setPermissions(url, 0o600)
  }

  private func writeChecksum(files: [String], root: URL, to url: URL) throws {
    let lines = try files.map { "\(try digest(root.appendingPathComponent($0)))  \($0)" }
    try writeText(lines.joined(separator: "\n") + "\n", to: url)
  }

  private func sha256String(_ string: String) throws -> String {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("gate16-digest-\(UUID().uuidString)")
    try Data(string.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    return try digest(file)
  }

  private func digest(_ url: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", url.path]
    let stdout = Pipe()
    process.standardOutput = stdout
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "Gate16Harness", code: Int(process.terminationStatus))
    }
    return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .split(separator: " ").first.map(String.init) ?? ""
  }

  private func manifestStatus(at root: URL) throws -> String? {
    try jsonObject(at: root.appendingPathComponent("manifest-v1.json"))["status"] as? String
  }

  private func publishedManifestStatus(at root: URL) throws -> String? {
    try jsonObject(at: root.appendingPathComponent("final-v1/manifest-v1.json"))["status"] as? String
  }

  private func canonicalPath(_ url: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/realpath")
    process.arguments = [url.path]
    let stdout = Pipe()
    process.standardOutput = stdout
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "Gate16Harness", code: Int(process.terminationStatus))
    }
    return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .newlines)
  }

  private func setPermissions(_ url: URL, _ permissions: Int) throws {
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
  }

  private func gitHead() throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "HEAD"]
    process.currentDirectoryURL = repository
    let stdout = Pipe()
    process.standardOutput = stdout
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "Gate16Harness", code: Int(process.terminationStatus))
    }
    return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private struct ShellResult {
  let status: Int32
  let stdout: String
  let stderr: String
}
