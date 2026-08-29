import Foundation
import XCTest

final class Phase09Gate02QualificationHarnessTests: XCTestCase {
  private var repository: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var harness: URL {
    repository.appendingPathComponent("scripts/phase09-gate02-qualification.sh")
  }

  func testContractFixesGateAndSixSerialEvidenceCells() throws {
    let result = try run(["contract"])
    XCTAssertEqual(result.status, 0, result.stderr)
    XCTAssertTrue(result.stdout.contains("Gate 2 — 12.50%"))
    XCTAssertTrue(result.stdout.contains("Exactly one Gate 2 qualification"))
    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("for cell in 1 2 3 4 5 6"))
    XCTAssertTrue(source.contains("run_live_qualification"))
    XCTAssertTrue(source.contains("swift test --filter HostwrightControlSecurityTests"))
  }

  func testRejectsWrongGateProtectedWorktreeAndUnsafeEvidenceRoot() throws {
    let wrongGate = try run(["prepare", "1"])
    XCTAssertNotEqual(wrongGate.status, 0)
    XCTAssertTrue(wrongGate.stderr.contains("only prepare 2"))

    try withRoot { root, environment in
      var protected = environment
      protected["PATH"] = ProcessInfo.processInfo.environment["PATH"]
      let result = try run(
        ["prepare", "2"], environment: protected,
        currentDirectory: repository.deletingLastPathComponent())
      XCTAssertNotEqual(result.status, 0)
      XCTAssertFalse(result.stderr.isEmpty)
      XCTAssertTrue(try String(contentsOf: harness, encoding: .utf8).contains("'/Users/dev/Documents/hostwright'"))

      var unsafe = environment
      unsafe["HOSTWRIGHT_PHASE09_GATE_ROOT"] = root.deletingLastPathComponent().path
      let invalid = try run(["prepare", "2"], environment: unsafe)
      XCTAssertNotEqual(invalid.status, 0)
      XCTAssertTrue(invalid.stderr.contains("evidence root"))
    }
  }

  func testPrepareIsPrivateDigestBoundAndRequiresCleanCommittedTree() throws {
    try withRoot { root, environment in
      let result = try run(["prepare", "2"], environment: environment)
      XCTAssertEqual(result.status, 0, result.stderr)
      let manifest =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: root.appendingPathComponent("manifest-v1.json"))) as? [String: Any]
      XCTAssertEqual(
        manifest?["schema"] as? String, "hostwright.phase09.gate02.qualification.manifest.v1")
      XCTAssertEqual(manifest?["gate"] as? Int, 2)
      XCTAssertEqual(manifest?["status"] as? String, "prepared")
      XCTAssertEqual((manifest?["cellOrder"] as? [Int]), [1, 2, 3, 4, 5, 6])
      XCTAssertEqual(try permissions(root.appendingPathComponent("manifest-v1.json")), 0o600)
      XCTAssertEqual(try permissions(root), 0o700)
      XCTAssertEqual((manifest?["sourceDigest"] as? String)?.count, 64)
    }
  }

  func testStaticLiveSigningAndCleanupStayStrictlyOwned() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB"))
    XCTAssertTrue(source.contains("--identifier \"$signing_identifier\""))
    XCTAssertTrue(source.contains("codesign --force --sign -"))
    XCTAssertTrue(source.contains("record_temporary_root"))
    XCTAssertTrue(source.contains("record_socket_root"))
    XCTAssertTrue(source.contains("socket_root=\"$socket_parent/.hwp09g2-$socket_suffix\""))
    XCTAssertTrue(source.contains("record_live_artifact_inventory"))
    XCTAssertEqual(
      source.components(separatedBy: "record_live_artifact_inventory \"$runtime\"").count - 1,
      1
    )
    XCTAssertTrue(source.contains("state.sqlite-wal"))
    XCTAssertTrue(source.contains("state.sqlite-shm"))
    XCTAssertTrue(source.contains("state-access-lock"))
    XCTAssertTrue(source.contains("state-access-writer"))
    XCTAssertTrue(source.contains("tool_status=$?"))
    XCTAssertTrue(source.contains("live qualification executable failed"))
    XCTAssertTrue(source.contains("live qualification executable returned an empty result"))
    XCTAssertTrue(source.contains("(set -e; run_cell \"$cell\")"))
    XCTAssertTrue(source.contains("validate_owned_runtime_file"))
    XCTAssertTrue(source.contains("owned live artifact escaped the recorded runtime root"))
    XCTAssertTrue(source.contains("live runtime contains an unledgered child; cleanup is refused"))
    XCTAssertTrue(
      source.contains("live runtime must contain exactly the frozen seven-artifact allowlist"))
    XCTAssertTrue(
      source.contains("live socket root is not empty after the tool exited; cleanup is refused"))
    XCTAssertTrue(source.contains("printf '%s\\n' \"$result\""))
    XCTAssertTrue(source.contains("owned live runtime identity changed; cleanup is refused"))
    XCTAssertTrue(source.contains("/bin/unlink"))
    XCTAssertFalse(source.contains("rm -rf"))
    XCTAssertFalse(source.contains("HOSTWRIGHT_NOTARY_PROFILE"))
    XCTAssertFalse(source.contains("gh pr"))
  }

  func testFailurePreservesRootAndLocksWithoutDuplicateCells() throws {
    try withRoot { root, environment in
      let prepared = try run(["prepare", "2"], environment: environment)
      XCTAssertEqual(prepared.status, 0, prepared.stderr)
      let wrapperDirectory = root.deletingLastPathComponent().appendingPathComponent(
        "swift-wrapper", isDirectory: true)
      try FileManager.default.createDirectory(
        at: wrapperDirectory, withIntermediateDirectories: false)
      let wrapper = wrapperDirectory.appendingPathComponent("swift")
      try Data(
        "#!/bin/bash\nif [[ \"${1:-}\" == test ]]; then exit 47; fi\nexec /usr/bin/swift \"$@\"\n"
          .utf8
      ).write(to: wrapper)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
      var failing = environment
      failing["PATH"] =
        wrapperDirectory.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
      let failure = try run(["run", "2"], environment: failing)
      XCTAssertEqual(failure.status, 47, failure.stderr)
      XCTAssertTrue(failure.stderr.contains("cell 1 failed"))
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("failure-v1.tsv").path))
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: root.deletingLastPathComponent().appendingPathComponent(
            ".phase09-gate02-active-v1"
          ).path))
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent("cell-02.stdout.log").path))
      let rerun = try run(["run", "2"], environment: failing)
      XCTAssertNotEqual(rerun.status, 0)
      XCTAssertTrue(rerun.stderr.contains("active qualification lock"))
    }
  }

  private func withRoot(_ body: (URL, [String: String]) throws -> Void) throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-phase09-harness-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent(
      "phase09-gate02-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try body(
      root,
      [
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
    for (key, value) in environment {
      values[key] = value
    }
    process.environment = values
    process.currentDirectoryURL = currentDirectory ?? repository
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

  private func canonicalPath(_ url: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/realpath")
    process.arguments = [url.path]
    let stdout = Pipe()
    process.standardOutput = stdout
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "Phase09Gate02QualificationHarnessTests", code: 1)
    }
    return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .newlines)
  }

  private func permissions(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
      .intValue ?? 0
  }
}

private struct ShellResult {
  let status: Int32
  let stdout: String
  let stderr: String
}
