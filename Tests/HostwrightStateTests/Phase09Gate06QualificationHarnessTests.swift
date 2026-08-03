import Foundation
import XCTest

final class Phase09Gate06QualificationHarnessTests: XCTestCase {
  private var repository: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var harness: URL {
    repository.appendingPathComponent("scripts/phase09-gate06-qualification.sh")
  }

  func testContractFixesGateAndAllSixAdmissionEvidenceCells() throws {
    let result = try run(["contract"])
    XCTAssertEqual(result.status, 0, result.stderr)
    XCTAssertTrue(result.stdout.contains("Gate 6 — 37.50%"))
    XCTAssertTrue(result.stdout.contains("Exactly one Gate 6 qualification"))
    XCTAssertTrue(result.stdout.contains("signed local admission\nqualification executable"))
    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("for cell in 1 2 3 4 5 6"))
    XCTAssertTrue(source.contains("AdmissionPolicyEngineTests|AdmissionRepositoryTests|AdmissionAdministrationServiceTests"))
    XCTAssertTrue(source.contains("AdmissionControlOperationsTests|PersistentControlAdmissionIntegrationTests"))
    XCTAssertTrue(source.contains("hostwright-admission-qualification"))
    XCTAssertTrue(source.contains("RBACSchemaV20MigrationTests|StateUpgradeTests"))
    XCTAssertTrue(source.contains("testConflictingMutationsDenyWithoutChoosingAWriter"))
    XCTAssertTrue(source.contains("testPolicyDocumentsCannotMutateApprovalBindingFields"))
    XCTAssertTrue(source.contains("testIdempotencyBindsOriginalRequestAndAdmissionEffectiveIntent"))
    XCTAssertTrue(source.contains("testAuditFailureFailsClosedForMutationWhileReadOnlyOperationRemainsCallable"))
  }

  func testPrepareBindsPrivateRootToGateDependenciesAndLedger() throws {
    try withRoot { root, environment in
      let result = try run(["prepare", "6"], environment: environment)
      XCTAssertEqual(result.status, 0, result.stderr)
      let manifest = try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("manifest-v1.json"))) as? [String: Any]
      XCTAssertEqual(manifest?["schema"] as? String, "hostwright.phase09.gate06.qualification.manifest.v1")
      XCTAssertEqual(manifest?["gate"] as? Int, 6)
      XCTAssertEqual(manifest?["status"] as? String, "prepared")
      XCTAssertEqual(manifest?["cellOrder"] as? [Int], [1, 2, 3, 4, 5, 6])
      XCTAssertEqual(try permissions(root), 0o700)
      XCTAssertEqual(try permissions(root.appendingPathComponent("manifest-v1.json")), 0o600)
      XCTAssertEqual((manifest?["sourceDigest"] as? String)?.count, 64)
      XCTAssertEqual((manifest?["configDigest"] as? String)?.count, 64)
      XCTAssertEqual((manifest?["toolchainDigest"] as? String)?.count, 64)
      let ledger = try String(
        contentsOf: root.appendingPathComponent("ownership-v1.tsv"), encoding: .utf8)
      XCTAssertTrue(ledger.hasPrefix("recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity\n"))
    }
  }

  func testWrongGateAndProtectedWorktreeAreRejected() throws {
    let wrongGate = try run(["prepare", "5"])
    XCTAssertNotEqual(wrongGate.status, 0)
    XCTAssertTrue(wrongGate.stderr.contains("only prepare 6"))

    try withRoot { _, environment in
      let protected = try run(
        ["prepare", "6"], environment: environment,
        currentDirectory: URL(fileURLWithPath: "/Users/dev/Documents/hostwright"))
      XCTAssertNotEqual(protected.status, 0)
      XCTAssertTrue(protected.stderr.contains("requires branch"))
    }
  }

  func testFailurePreservesBothLocksAndDoesNotRunNextCell() throws {
    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "6"], environment: environment).status, 0)
      let wrapperDirectory = root.deletingLastPathComponent().appendingPathComponent("swift-wrapper")
      try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: false)
      let wrapper = wrapperDirectory.appendingPathComponent("swift")
      try Data("#!/bin/bash\nif [[ \"${1:-}\" == test ]]; then exit 47; fi\nexec /usr/bin/swift \"$@\"\n".utf8)
        .write(to: wrapper)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
      var failing = environment
      failing["PATH"] = wrapperDirectory.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
      let failed = try run(["run", "6"], environment: failing)
      XCTAssertEqual(failed.status, 47, failed.stderr)
      XCTAssertTrue(failed.stderr.contains("cell 1 failed"))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("failure-v1.tsv").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(
        atPath: root.deletingLastPathComponent().appendingPathComponent(".phase09-gate06-active-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-02.stdout.log").path))
      let rerun = try run(["run", "6"], environment: failing)
      XCTAssertNotEqual(rerun.status, 0)
      XCTAssertTrue(rerun.stderr.contains("active Gate 6 qualification"))
    }
  }

  func testReuseRequiresCompleteCMSVerifiedEvidenceAndNeverRerunsCells() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("all_reusable"))
    XCTAssertTrue(source.contains("verify_evidence_digest"))
    XCTAssertTrue(source.contains("security cms -S"))
    XCTAssertTrue(source.contains("Gate 6 evidence is valid and reused; no cells were rerun."))
    XCTAssertTrue(source.contains("completed evidence is incomplete or changed; preserve this root and do not rerun."))
  }

  func testLiveRuntimeUsesSignedArtifactAndExactOwnedOnlyCleanup() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB"))
    XCTAssertTrue(source.contains("--identifier \"$signing_identifier\""))
    XCTAssertTrue(source.contains("record_live_root"))
    XCTAssertTrue(source.contains("record_live_inventory"))
    XCTAssertTrue(source.contains("signed-admission-tool|state.sqlite|state.sqlite-wal|state.sqlite-shm"))
    XCTAssertTrue(source.contains("live artifact identity changed; cleanup is refused"))
    XCTAssertTrue(source.contains("/bin/unlink"))
    XCTAssertFalse(source.contains("rm -rf"))
    XCTAssertFalse(source.contains("HOSTWRIGHT_NOTARY_PROFILE"))
    XCTAssertFalse(source.contains("gh pr"))
  }

  private func withRoot(_ body: (URL, [String: String]) throws -> Void) throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-phase09-harness-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("phase09-gate06-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try body(root, [
      "HOSTWRIGHT_PHASE09_HARNESS_TESTING": "1",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT": try canonicalPath(parent),
      "HOSTWRIGHT_PHASE09_GATE_ROOT": try canonicalPath(root),
    ])
  }

  private func run(
    _ arguments: [String], environment: [String: String] = [:], currentDirectory: URL? = nil
  ) throws -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [harness.path] + arguments
    var values = ProcessInfo.processInfo.environment
    for (key, value) in environment { values[key] = value }
    process.environment = values
    process.currentDirectoryURL = currentDirectory ?? repository
    let stdout = Pipe(); let stderr = Pipe()
    process.standardOutput = stdout; process.standardError = stderr
    try process.run(); process.waitUntilExit()
    return ShellResult(
      status: process.terminationStatus,
      stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
  }

  private func canonicalPath(_ url: URL) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/realpath")
    process.arguments = [url.path]; let stdout = Pipe(); process.standardOutput = stdout
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "Gate06Harness", code: 1) }
    return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .newlines)
  }

  private func permissions(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
  }
}

private struct ShellResult { let status: Int32; let stdout: String; let stderr: String }
