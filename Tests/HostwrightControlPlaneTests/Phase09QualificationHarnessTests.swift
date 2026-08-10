import Foundation
import XCTest

final class Phase09QualificationHarnessTests: XCTestCase {
  private var repository: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var harness: URL {
    repository.appendingPathComponent("scripts/phase09-gate-qualification.sh")
  }

  func testContractDeclaresAllGatesAndEvidenceRules() throws {
    let result = try run(arguments: ["contract"])
    XCTAssertEqual(result.status, 0, result.stderr)
    XCTAssertTrue(result.stdout.contains("Phase 09 qualification harness contract v1"))
    for gate in 1...16 {
      XCTAssertTrue(result.stdout.contains("Gate \(gate)"), "missing Gate \(gate)")
    }
    XCTAssertTrue(result.stdout.contains("6.25%"))
    XCTAssertTrue(result.stdout.contains("100.00%"))
    XCTAssertTrue(result.stdout.contains("U/I/L/M/S/R"))
    XCTAssertTrue(result.stdout.lowercased().contains("one active qualification"))
  }

  func testPrepareWritesDigestBoundPrivateEvidenceSkeleton() throws {
    try withEvidenceRoot(gate: 1) { root, environment in
      let prepared = try run(arguments: ["prepare", "1"], environment: environment)
      XCTAssertEqual(prepared.status, 0, prepared.stderr)

      let manifest = try data(at: root.appendingPathComponent("manifest-v1.json"))
      let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
      XCTAssertEqual(object?["schema"] as? String, "hostwright.phase09.qualification.manifest.v1")
      XCTAssertEqual(object?["gate"] as? Int, 1)
      XCTAssertEqual(object?["status"] as? String, "prepared")
      XCTAssertEqual((object?["sourceDigest"] as? String)?.count, 64)
      XCTAssertEqual((object?["configDigest"] as? String)?.count, 64)
      XCTAssertEqual((object?["toolchainDigest"] as? String)?.count, 64)
      let evidenceByCell = object?["evidenceByCell"] as? [[String: Any]]
      XCTAssertEqual(evidenceByCell?.count, 6)
      XCTAssertEqual(evidenceByCell?.first?["evidenceClasses"] as? [String], ["U", "I", "M", "S", "R"])
      XCTAssertEqual(evidenceByCell?.last?["evidenceClasses"] as? [String], ["L"])
      XCTAssertEqual(try permissions(of: root.appendingPathComponent("manifest-v1.json")), 0o600)
      XCTAssertEqual(try permissions(of: root.appendingPathComponent("ownership-v1.tsv")), 0o600)
      XCTAssertTrue(
        try String(contentsOf: root.appendingPathComponent("toolchain-v1.txt"), encoding: .utf8)
          .contains("ProductName:"))
      XCTAssertEqual(
        try String(contentsOf: root.appendingPathComponent("ownership-v1.tsv"), encoding: .utf8),
        "recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity\n")
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("state-v1.tsv").path))
    }
  }

  func testMalformedGateAndRootFailClosedWithoutEvidence() throws {
    try withEvidenceRoot(gate: 1) { root, environment in
      let mismatch = try run(arguments: ["prepare", "2"], environment: environment)
      XCTAssertNotEqual(mismatch.status, 0)
      XCTAssertTrue(mismatch.stderr.contains("Gate 2 has no configured qualification cells"))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest-v1.json").path))
    }

    let bad = try run(arguments: ["prepare", "0"])
    XCTAssertNotEqual(bad.status, 0)
    XCTAssertTrue(bad.stderr.contains("gate must be an integer from 1 through 16"))
  }

  func testDedicatedGateRoutingCoversGatesThirteenThroughSixteen() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("is_dedicated_gate"))
    XCTAssertTrue(source.contains("dedicated_gate_script"))
    XCTAssertTrue(source.contains("dispatch_dedicated_gate"))
    for gate in 13...16 {
      let name = String(format: "scripts/phase09-gate%02d-qualification.sh", gate)
      XCTAssertTrue(source.contains(name), "missing dedicated routing for Gate \(gate)")
    }
    XCTAssertTrue(source.contains("dispatch_dedicated_gate prepare \"$gate\""))
    XCTAssertTrue(source.contains("dispatch_dedicated_gate run \"$gate\""))
    XCTAssertTrue(source.contains("dispatch_dedicated_gate status \"$gate\""))
    XCTAssertTrue(source.contains("dispatch_dedicated_gate finalize \"$gate\" \"${3:-}\""))
    XCTAssertTrue(source.contains("\"$#\" == 2 || \"$#\" == 3"))
    XCTAssertFalse(source.contains("find-identity"))
    XCTAssertTrue(source.contains("no identity-list query is evidence"))

    let gate16 = try String(contentsOf: repository.appendingPathComponent("scripts/phase09-gate16-qualification.sh"), encoding: .utf8)
    XCTAssertTrue(gate16.contains("run()"))
    XCTAssertTrue(gate16.contains("status()"))
    XCTAssertTrue(gate16.contains("mode:\"read-only\""))
    XCTAssertTrue(gate16.contains("finalizationRequiresExplicitReceipts:true"))

    let routedRun = try run(arguments: ["run", "16"], environment: ["HOSTWRIGHT_PHASE09_GATE_ROOT": ""])
    XCTAssertEqual(routedRun.status, 0, routedRun.stderr)
    XCTAssertTrue(routedRun.stdout.contains("hostwright.phase09.gate16.status.v1"), routedRun.stdout)
    let routedStatus = try run(arguments: ["status", "16"], environment: ["HOSTWRIGHT_PHASE09_GATE_ROOT": ""])
    XCTAssertEqual(routedStatus.status, 0, routedStatus.stderr)
    XCTAssertTrue(routedStatus.stdout.contains("\"operation\":\"status\""), routedStatus.stdout)

    let unexpected = try run(arguments: ["diagnose", "12"])
    XCTAssertNotEqual(unexpected.status, 0)
    XCTAssertTrue(unexpected.stderr.contains("no diagnostic dispatcher"), unexpected.stderr)
  }

  func testRouterDispatchesMissingGate16ReceiptToTheGate16FreezeTrap() throws {
    try withEvidenceParent { parent, parentEnvironment in
      let root = try makeEvidenceRoot(parent: parent, gate: 16)
      let gate16Environment = try environment(
        for: root, parent: parent, parentEnvironment: parentEnvironment)
      try writeJSON(["status": "prepared"], to: root.appendingPathComponent("manifest-v1.json"))

      let result = try run(arguments: ["finalize", "16"], environment: gate16Environment)
      XCTAssertNotEqual(result.status, 0, result.stderr)
      XCTAssertTrue(result.stderr.contains("usage: finalize 16"), result.stderr)
      XCTAssertEqual(try manifestStatus(at: root), "failed")
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("finalization-frozen-v1").path))
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("failure-v1.tsv").path))

      let invalidRoot = try makeEvidenceRoot(parent: parent, gate: 16)
      let invalidEnvironment = try environment(
        for: invalidRoot, parent: parent, parentEnvironment: parentEnvironment)
      try writeJSON(["status": "prepared"], to: invalidRoot.appendingPathComponent("manifest-v1.json"))
      let invalid = try run(
        arguments: ["finalize", "16", parent.appendingPathComponent("missing-receipts.json").path],
        environment: invalidEnvironment)
      XCTAssertNotEqual(invalid.status, 0, invalid.stderr)
      XCTAssertTrue(invalid.stderr.contains("canonical regular files"), invalid.stderr)
      XCTAssertEqual(try manifestStatus(at: invalidRoot), "failed")
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: invalidRoot.appendingPathComponent("finalization-frozen-v1").path))
    }
  }

  func testRouterUsesItsCanonicalRepositoryBoundaryForContractDispatch() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    for required in [
      "router_repository_path", "router_protected_repository_path", "validate_router_boundary",
      "router_script_path", "router_repo_root", "git -C \"$router_repo_root\"",
      "cd \"$router_repo_root\"", "! -L \"$script\"",
    ] {
      XCTAssertTrue(source.contains(required), "missing router boundary invariant: \(required)")
    }

    let outsideRepository = FileManager.default.temporaryDirectory
    let result = try run(arguments: ["contract"], currentDirectory: outsideRepository)
    XCTAssertEqual(result.status, 0, result.stderr)
    XCTAssertTrue(result.stdout.contains("Phase 09 qualification harness contract v1"))
  }

  func testOwnershipRecordingIsLedgerOnlyAndCleanupIsAPlan() throws {
    try withEvidenceRoot(gate: 1) { root, environment in
      XCTAssertEqual(try run(arguments: ["prepare", "1"], environment: environment).status, 0)
      let owned = root.appendingPathComponent("owned-root", isDirectory: true)
      try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
      try setPermissions(of: owned, to: 0o700)
      let recorded = try run(
        arguments: [
          "record-owned", "1", "temporary-root", "gate1-owned", try canonicalPath(owned),
          "path=owned-root;sha256=\(String(repeating: "a", count: 64))",
        ], environment: environment)
      XCTAssertEqual(recorded.status, 0, recorded.stderr)
      let container = try run(
        arguments: [
          "record-owned", "1", "container", "phase09-gate1", "-",
          "digest=sha256:\(String(repeating: "b", count: 64))",
        ], environment: environment)
      XCTAssertEqual(container.status, 0, container.stderr)
      let plan = try run(arguments: ["cleanup-plan", "1"], environment: environment)
      XCTAssertEqual(plan.status, 0, plan.stderr)
      XCTAssertTrue(plan.stdout.contains("cleanup plan only"))
      XCTAssertTrue(plan.stdout.contains("gate1-owned"))

      let invalid = try run(
        arguments: ["record-owned", "1", "pid", "not-a-pid", "-", "pid=1"],
        environment: environment)
      XCTAssertNotEqual(invalid.status, 0)
      XCTAssertTrue(invalid.stderr.contains("invalid ownership identifier"))

      let secret = try run(
        arguments: ["record-owned", "1", "container", "phase09-secret", "-", "token=never-record"],
        environment: environment)
      XCTAssertNotEqual(secret.status, 0)
      XCTAssertTrue(secret.stderr.contains("must not contain secret material"))
    }
  }

  func testExistingActiveRunLockPreventsAnyCellExecution() throws {
    try withEvidenceRoot(gate: 1) { root, environment in
      XCTAssertEqual(try run(arguments: ["prepare", "1"], environment: environment).status, 0)
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("active-run-v1"), withIntermediateDirectories: false)
      let result = try run(arguments: ["run", "1"], environment: environment)
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.stderr.contains("active qualification lock"))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-01.stdout.log").path))
    }
  }

  func testFailureLedgerFreezesBothEvidenceRootsAndPreservesBothLocks() throws {
    try withEvidenceParent { parent, parentEnvironment in
      let first = try makeEvidenceRoot(parent: parent, gate: 1)
      let second = try makeEvidenceRoot(parent: parent, gate: 1)
      let firstEnvironment = try environment(for: first, parent: parent, parentEnvironment: parentEnvironment)
      let secondEnvironment = try environment(for: second, parent: parent, parentEnvironment: parentEnvironment)
      XCTAssertEqual(try run(arguments: ["prepare", "1"], environment: firstEnvironment).status, 0)
      XCTAssertEqual(try run(arguments: ["prepare", "1"], environment: secondEnvironment).status, 0)

      let wrappers = parent.appendingPathComponent("swift-wrapper", isDirectory: true)
      try FileManager.default.createDirectory(at: wrappers, withIntermediateDirectories: false)
      let wrapper = wrappers.appendingPathComponent("swift")
      try Data("#!/bin/bash\nif [[ \"${1:-}\" == test ]]; then exit 47; fi\nexec /usr/bin/swift \"$@\"\n".utf8)
        .write(to: wrapper)
      try setPermissions(of: wrapper, to: 0o755)
      var failingEnvironment = firstEnvironment
      failingEnvironment["PATH"] = wrappers.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")

      let failed = try run(arguments: ["run", "1"], environment: failingEnvironment)
      XCTAssertEqual(failed.status, 47, failed.stderr)
      XCTAssertTrue(failed.stderr.contains("cell 1 failed"))
      XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("failure-v1.tsv").path))
      XCTAssertTrue(
        try String(contentsOf: first.appendingPathComponent("failure-v1.tsv"), encoding: .utf8)
          .contains("\t1\t1\t47\t"))
      XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("cell-02.stdout.log").path))
      XCTAssertEqual(
        try manifestStatus(at: first),
        "failed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("active-run-v1").path))
      let gateLock = parent.appendingPathComponent(".phase09-gate01-active-v1", isDirectory: true)
      XCTAssertTrue(FileManager.default.fileExists(atPath: gateLock.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: gateLock.appendingPathComponent("info-v1.tsv").path))

      let retry = try run(arguments: ["run", "1"], environment: failingEnvironment)
      XCTAssertNotEqual(retry.status, 0)
      XCTAssertTrue(retry.stderr.contains("active qualification lock"))
      let blocked = try run(arguments: ["run", "1"], environment: secondEnvironment)
      XCTAssertNotEqual(blocked.status, 0)
      XCTAssertTrue(blocked.stderr.contains("gate-wide active qualification lock"))
      let completedLedger = try run(
        arguments: ["record-owned", "1", "container", "phase09-after-failure", "-", "digest=sha256:abc"],
        environment: failingEnvironment)
      XCTAssertNotEqual(completedLedger.status, 0)
      XCTAssertTrue(completedLedger.stderr.contains("only while evidence is prepared"))
    }
  }

  func testHarnessHasOnlyTheFrozenSerialCellsAndNoPublicOrDestructiveOperations() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    for command in [
      "swift test --filter HostwrightControlPlaneTests",
      "swift build --target HostwrightControlPlane",
      "scripts/lint.sh",
      "git diff --check",
      "scripts/check-docs.sh",
      "run_prerequisite_probe",
    ] {
      XCTAssertTrue(source.contains(command), "missing frozen cell \(command)")
    }
    XCTAssertTrue(source.contains("run_gate1_cell"))
    XCTAssertFalse(source.contains("eval "))
    for forbidden in ["\\bgh\\s", "tmux", "launchctl", "\\bkill\\s", "pkill", "\\brm\\s", "Phase08"] {
      XCTAssertNil(
        source.range(of: forbidden, options: .regularExpression),
        "unexpected unsafe operation \(forbidden)")
    }
  }

  private func withEvidenceRoot(
    gate: Int,
    _ body: (URL, [String: String]) throws -> Void
  ) throws {
    try withEvidenceParent { parent, parentEnvironment in
      let root = try makeEvidenceRoot(parent: parent, gate: gate)
      try body(root, try environment(for: root, parent: parent, parentEnvironment: parentEnvironment))
    }
  }

  private func withEvidenceParent(
    _ body: (URL, [String: String]) throws -> Void
  ) throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("hostwright-phase09-harness-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try setPermissions(of: parent, to: 0o700)
    defer { try? FileManager.default.removeItem(at: parent) }
    try body(parent, [
      "HOSTWRIGHT_PHASE09_HARNESS_TESTING": "1",
      "HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT": try canonicalPath(parent),
    ])
  }

  private func makeEvidenceRoot(parent: URL, gate: Int) throws -> URL {
    let root = parent.appendingPathComponent(
      String(format: "phase09-gate%02d-%@", gate, UUID().uuidString.lowercased()), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try setPermissions(of: root, to: 0o700)
    return root
  }

  private func environment(
    for root: URL,
    parent: URL,
    parentEnvironment: [String: String]
  ) throws -> [String: String] {
    var environment = parentEnvironment
    environment["HOSTWRIGHT_PHASE09_GATE_ROOT"] = try canonicalPath(root)
    environment["HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT"] = try canonicalPath(parent)
    return environment
  }

  private func manifestStatus(at root: URL) throws -> String? {
    let manifest = try data(at: root.appendingPathComponent("manifest-v1.json"))
    return (try JSONSerialization.jsonObject(with: manifest) as? [String: Any])?["status"] as? String
  }

  private func run(
    arguments: [String], environment: [String: String] = [:], currentDirectory: URL? = nil
  ) throws -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [harness.path] + arguments
    var values = ProcessInfo.processInfo.environment
    environment.forEach { values[$0.key] = $0.value }
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

  private func data(at url: URL) throws -> Data {
    try Data(contentsOf: url)
  }

  private func writeJSON(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    try setPermissions(of: url, to: 0o600)
  }

  private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
  }

  private func setPermissions(of url: URL, to permissions: Int) throws {
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
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
      throw NSError(domain: "Phase09QualificationHarnessTests", code: Int(process.terminationStatus))
    }
    return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .newlines)
  }
}

private struct ShellResult {
  let status: Int32
  let stdout: String
  let stderr: String
}
