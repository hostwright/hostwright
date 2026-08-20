import Foundation
import XCTest

final class Phase09Gate10QualificationHarnessTests: XCTestCase {
  private let wasmSDKIdentifier = "swift-6.3.3-RELEASE_wasm"
  private let wasmSDKChecksum = "cabfa08b73bb8ac783927ecd15fa386e99d0c139c5f232445067bcf58379cae7"
  private let wasmSDKBundleDigest = "ef888f82c39bc4d1f9202842547252699321868fcc1751e6a33acbd4507d9f5a"

  private var repository: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var harness: URL {
    repository.appendingPathComponent("scripts/phase09-gate10-qualification.sh")
  }

  func testContractFixesGateTenWASIQualificationAndSixSerialCells() throws {
    let result = try run(["contract"])
    XCTAssertEqual(result.status, 0, result.stderr)
    XCTAssertTrue(result.stdout.contains("Gate 10 — 62.50%"))
    XCTAssertTrue(result.stdout.contains("Exactly one Gate 10 qualification"))
    XCTAssertTrue(result.stdout.contains("WASI"))

    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("for n in 1 2 3 4 5 6"))
    XCTAssertTrue(source.contains("U"))
    XCTAssertTrue(source.contains("I"))
    XCTAssertTrue(source.contains("L"))
    XCTAssertTrue(source.contains("M"))
    XCTAssertTrue(source.contains("S"))
    XCTAssertTrue(source.contains("R"))
    XCTAssertTrue(source.contains("WasmKit"))
    XCTAssertTrue(source.contains("WasmKitWASI"))
    XCTAssertTrue(source.contains("fresh-instance"))
    XCTAssertTrue(source.contains("no preopened"))
    XCTAssertTrue(source.contains("ambient"))
    XCTAssertTrue(source.contains("conformance"))
    XCTAssertTrue(source.contains("adversarial"))
  }

  func testPrepareBindsCleanSourceAndRecordsPinnedExternalPrerequisites() throws {
    try withRoot { root, environment in
      let result = try run(["prepare", "10"], environment: environment)
      XCTAssertEqual(result.status, 0, result.stderr)

      let manifest = try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("manifest-v1.json"))) as? [String: Any]
      XCTAssertEqual(manifest?["schema"] as? String, "hostwright.phase09.gate10.qualification.manifest.v1")
      XCTAssertEqual(manifest?["gate"] as? Int, 10)
      XCTAssertEqual(manifest?["status"] as? String, "prepared")
      XCTAssertEqual(manifest?["cellOrder"] as? [Int], [1, 2, 3, 4, 5, 6])
      XCTAssertEqual(try permissions(root), 0o700)
      XCTAssertEqual(try permissions(root.appendingPathComponent("manifest-v1.json")), 0o600)
      XCTAssertEqual((manifest?["sourceDigest"] as? String)?.count, 64)
      XCTAssertEqual((manifest?["configDigest"] as? String)?.count, 64)
      XCTAssertEqual((manifest?["toolchainDigest"] as? String)?.count, 64)

      let prerequisites = try XCTUnwrap(manifest?["externalPrerequisites"] as? [String: Any])
      XCTAssertEqual(prerequisites["swiftExecutable"] as? String, "/Users/dev/.swiftly/bin/swift")
      XCTAssertEqual(prerequisites["swiftVersion"] as? String, "6.3.3")
      XCTAssertEqual(prerequisites["wasmSDKIdentifier"] as? String, wasmSDKIdentifier)
      XCTAssertEqual(prerequisites["wasmSDKChecksum"] as? String, wasmSDKChecksum)
      XCTAssertEqual(prerequisites["wasmSDKBundleDigest"] as? String, wasmSDKBundleDigest)

      let ledger = try String(contentsOf: root.appendingPathComponent("ownership-v1.tsv"), encoding: .utf8)
      XCTAssertTrue(ledger.hasPrefix("recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity\n"))
    }

    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("git diff --quiet"))
    XCTAssertTrue(source.contains("git diff --cached --quiet"))
    XCTAssertTrue(source.contains("git status --porcelain"))
    XCTAssertTrue(source.contains("source must be clean"))
    XCTAssertTrue(source.contains("/Users/dev/.swiftly/bin/swift"))
    XCTAssertTrue(source.contains("swift-6.3.3-RELEASE_wasm"))
    XCTAssertTrue(source.contains(wasmSDKChecksum))
    XCTAssertTrue(source.contains(wasmSDKBundleDigest))
    XCTAssertTrue(source.contains("expanded_sdk_digest"))
  }

  func testOnlyGateTenAndPrivateCanonicalEvidenceRootsAreAccepted() throws {
    let wrongGate = try run(["prepare", "9"])
    XCTAssertNotEqual(wrongGate.status, 0)
    XCTAssertTrue(wrongGate.stderr.contains("only prepare 10"))

    try withRoot { root, environment in
      var escaped = environment
      escaped["HOSTWRIGHT_PHASE09_GATE_ROOT"] = root.deletingLastPathComponent().path
      let result = try run(["prepare", "10"], environment: escaped)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("private canonical"), result.stderr)
    }

    try withRoot { _, environment in
      let result = try run(
        ["prepare", "10"], environment: environment,
        currentDirectory: URL(fileURLWithPath: "/Users/dev/Documents/hostwright"))
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("requires branch"), result.stderr)
    }
  }

  func testFailureFreezesProgressPreservesBothLocksAndDoesNotStartNextCell() throws {
    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "10"], environment: environment).status, 0)
      let wrappers = root.deletingLastPathComponent().appendingPathComponent("swift-wrapper")
      try FileManager.default.createDirectory(at: wrappers, withIntermediateDirectories: false)
      try writeExecutable(
        "#!/bin/bash\nif [[ \"${1:-}\" == test ]]; then exit 47; fi\nexec /usr/bin/swift \"$@\"\n",
        named: "swift", in: wrappers)
      var failing = environment
      failing["PATH"] = wrappers.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")

      let result = try run(["run", "10"], environment: failing)
      XCTAssertEqual(result.status, 47, result.stderr)
      XCTAssertTrue(result.stderr.contains("cell 1 failed"), result.stderr)
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("failure-v1.tsv").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(
        atPath: root.deletingLastPathComponent().appendingPathComponent(".phase09-gate10-active-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-02.stdout.log").path))
    }
  }

  func testExistingGateLockRejectsDuplicateQualificationBeforeAnyCell() throws {
    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "10"], environment: environment).status, 0)
      let lock = root.deletingLastPathComponent().appendingPathComponent(".phase09-gate10-active-v1")
      try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: lock) }

      let result = try run(["run", "10"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("active Gate 10 qualification"), result.stderr)
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-01.stdout.log").path))
    }
  }

  func testDependencyDriftAndCompletedEvidenceRefuseReruns() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("revalidate_dependencies"))
    XCTAssertTrue(source.contains("source_digest_value"))
    XCTAssertTrue(source.contains("config_digest_value"))
    XCTAssertTrue(source.contains("toolchain_digest_value"))
    XCTAssertTrue(source.contains("prepared evidence dependencies changed; preserve this root."))
    XCTAssertTrue(source.contains("completed evidence is incomplete or changed; preserve this root and do not rerun."))
    XCTAssertTrue(source.contains("Gate 10 evidence is valid and reused; no cells were rerun."))
    XCTAssertTrue(source.contains("! -L \"$root/evidence-v1.sha256\""))
    XCTAssertTrue(source.contains("security cms -S"))
  }

  func testOwnedOnlyWorkerAndGuestCleanupIsPinnedToTheLedger() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("record_root"))
    XCTAssertTrue(source.contains("record_process"))
    XCTAssertTrue(source.contains("--process-identity"))
    XCTAssertTrue(source.contains("--expected-executable"))
    XCTAssertTrue(source.contains("\"$current_identity\" == \"$identity\""))
    XCTAssertTrue(source.contains("stat -f '%d' \"$path\""))
    XCTAssertTrue(source.contains("stat -f '%i' \"$path\""))
    XCTAssertFalse(source.contains("ps -p"))
    XCTAssertTrue(source.contains("provider-worker"))
    XCTAssertTrue(source.contains("guest"))
    XCTAssertTrue(source.contains("cleanup"))
    XCTAssertTrue(source.contains("identity changed; cleanup is refused"))
    XCTAssertTrue(source.contains("/bin/unlink"))
    XCTAssertTrue(source.contains("root_lock_created=0; gate_lock_created=0"))
    XCTAssertFalse(source.contains("rm -rf"))
    XCTAssertFalse(source.contains("HOSTWRIGHT_NOTARY_PROFILE"))
    XCTAssertFalse(source.contains("gh pr"))
  }

  private func withRoot(_ body: (URL, [String: String]) throws -> Void) throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-phase09-gate10-harness-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("phase09-gate10-\(UUID().uuidString.lowercased())", isDirectory: true)
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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/realpath")
    process.arguments = [url.path]
    let stdout = Pipe(); process.standardOutput = stdout
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "Gate10Harness", code: 1) }
    return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .newlines)
  }

  private func permissions(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
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
