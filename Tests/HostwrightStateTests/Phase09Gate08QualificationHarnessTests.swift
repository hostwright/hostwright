import Foundation
import XCTest
import Darwin

final class Phase09Gate08QualificationHarnessTests: XCTestCase {
  private var repository: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var harness: URL {
    repository.appendingPathComponent("scripts/phase09-gate08-qualification.sh")
  }

  func testContractFixesGateAndAllSixStreamEvidenceCells() throws {
    let result = try run(["contract"])
    XCTAssertEqual(result.status, 0, result.stderr)
    XCTAssertTrue(result.stdout.contains("Gate 8 — 50.00%"))
    XCTAssertTrue(result.stdout.contains("Exactly one Gate 8 qualification"))
    XCTAssertTrue(result.stdout.contains("owned pinned Apple-container runtime probe"))
    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("for n in 1 2 3 4 5 6"))
    XCTAssertTrue(source.contains("ControlStreamFrameContractTests|ControlStreamSessionStateTests|ControlStreamCursorTests"))
    XCTAssertTrue(source.contains("PersistentControlStreamIntegrationTests|DaemonControlStreamSourcesTests"))
    XCTAssertTrue(source.contains("ControlIdentitySecurityAdapterTests"))
    XCTAssertTrue(source.contains("daemon-2.stderr.log"))
    XCTAssertTrue(source.contains("hostwright-stream-qualification"))
    XCTAssertTrue(source.contains("EventStreamTests|StateUpgradeTests|ControlStreamCursorTests"))
    XCTAssertTrue(source.contains("testInactiveSessionClosesTheActiveStreamConnection"))
    XCTAssertTrue(source.contains("HostwrightDaemonControlServiceTests"))
    XCTAssertTrue(source.contains("ContainerizationHelperInteractiveExecutorTests"))
    XCTAssertTrue(source.contains("signed-hostwrightd"))
    XCTAssertTrue(source.contains("--live --root"))
    XCTAssertTrue(source.contains("--resume --root"))
    XCTAssertTrue(source.contains("--interval 5 --jitter 0 --parallelism 1"))
    XCTAssertTrue(source.contains("container delete --force"))
    XCTAssertTrue(source.contains("heartbeatWhileCreditExhausted==true"))
    XCTAssertTrue(source.contains("fullDuplexInputAcknowledged==true"))
    XCTAssertTrue(source.contains("cancellationDurabilityVerified==true"))
    XCTAssertTrue(source.contains("docker.io/library/python@sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92"))
  }

  func testPrepareBindsPrivateRootToGateEightDependenciesAndLedger() throws {
    try withRoot { root, environment in
      let result = try run(["prepare", "8"], environment: environment)
      XCTAssertEqual(result.status, 0, result.stderr)
      let manifest = try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("manifest-v1.json"))) as? [String: Any]
      XCTAssertEqual(manifest?["schema"] as? String, "hostwright.phase09.gate08.qualification.manifest.v1")
      XCTAssertEqual(manifest?["gate"] as? Int, 8)
      XCTAssertEqual(manifest?["status"] as? String, "prepared")
      XCTAssertEqual(manifest?["cellOrder"] as? [Int], [1, 2, 3, 4, 5, 6])
      XCTAssertEqual(try permissions(root), 0o700)
      XCTAssertEqual(try permissions(root.appendingPathComponent("manifest-v1.json")), 0o600)
      XCTAssertEqual((manifest?["sourceDigest"] as? String)?.count, 64)
      XCTAssertEqual((manifest?["configDigest"] as? String)?.count, 64)
      XCTAssertEqual((manifest?["toolchainDigest"] as? String)?.count, 64)
      let ledger = try String(contentsOf: root.appendingPathComponent("ownership-v1.tsv"), encoding: .utf8)
      XCTAssertTrue(ledger.hasPrefix("recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity\n"))
    }
  }

  func testWrongGateAndProtectedWorktreeAreRejected() throws {
    let wrongGate = try run(["prepare", "6"])
    XCTAssertNotEqual(wrongGate.status, 0)
    XCTAssertTrue(wrongGate.stderr.contains("only prepare 8"))

    try withRoot { _, environment in
      let protected = try run(
        ["prepare", "8"], environment: environment,
        currentDirectory: URL(fileURLWithPath: "/Users/dev/Documents/hostwright"))
      XCTAssertNotEqual(protected.status, 0)
      XCTAssertTrue(protected.stderr.contains("requires branch"))
    }
  }

  func testFailurePreservesLocksAndDoesNotRunNextCell() throws {
    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "8"], environment: environment).status, 0)
      let wrapperDirectory = root.deletingLastPathComponent().appendingPathComponent("swift-wrapper")
      try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: false)
      let wrapper = wrapperDirectory.appendingPathComponent("swift")
      try Data("#!/bin/bash\nif [[ \"${1:-}\" == test ]]; then exit 47; fi\nexec /usr/bin/swift \"$@\"\n".utf8)
        .write(to: wrapper)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
      var failing = environment
      failing["PATH"] = wrapperDirectory.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
      let failed = try run(["run", "8"], environment: failing)
      XCTAssertEqual(failed.status, 47, failed.stderr)
      XCTAssertTrue(failed.stderr.contains("cell 1 failed"))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("failure-v1.tsv").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(
        atPath: root.deletingLastPathComponent().appendingPathComponent(".phase09-gate08-active-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-02.stdout.log").path))
    }
  }

  func testCellOneFailureDoesNotInspectOrDeleteAnUnledgeredMatchingContainer() throws {
    try withRoot { root, environment in
      let parent = root.deletingLastPathComponent()
      let wrappers = parent.appendingPathComponent("gate08-prelive-failure-wrappers")
      let containerState = parent.appendingPathComponent("unrelated-matching-container.state")
      let containerCalls = parent.appendingPathComponent("unrelated-matching-container.calls")
      try FileManager.default.createDirectory(at: wrappers, withIntermediateDirectories: false)
      try Data("present".utf8).write(to: containerState)
      try writeExecutable(
        """
        #!/bin/bash
        if [[ "${1:-}" == "test" ]]; then exit 47; fi
        exec /usr/bin/swift "$@"
        """, named: "swift", in: wrappers)
      try writeExecutable(
        """
        #!/bin/bash
        set -euo pipefail
        state="${HOSTWRIGHT_PHASE09_MOCK_CONTAINER_STATE:?}"
        calls="${HOSTWRIGHT_PHASE09_MOCK_CONTAINER_CALLS:?}"
        digest='sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92'
        resource='hostwright-v2-p09-unrelated-live'
        case "${1:-}" in
          --version)
            exec /usr/local/bin/container --version
            ;;
          list)
            printf 'list\\n' >> "$calls"
            if [[ -f "$state" ]]; then
              printf '[{"id":"%s","configuration":{"image":{"descriptor":{"digest":"%s"}},"labels":{"dev.hostwright.project":"phase09-gate08-live","dev.hostwright.service":"probe"}}}]\\n' "$resource" "$digest"
            else
              printf '[]\\n'
            fi
            ;;
          delete)
            printf 'delete\\n' >> "$calls"
            /bin/unlink "$state"
            ;;
          *) exit 92 ;;
        esac
        """, named: "container", in: wrappers)

      var failing = environment
      failing["PATH"] = wrappers.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
      failing["HOSTWRIGHT_PHASE09_MOCK_CONTAINER_STATE"] = containerState.path
      failing["HOSTWRIGHT_PHASE09_MOCK_CONTAINER_CALLS"] = containerCalls.path
      XCTAssertEqual(try run(["prepare", "8"], environment: failing).status, 0)
      let result = try run(["run", "8"], environment: failing)

      XCTAssertEqual(result.status, 47, result.stderr)
      XCTAssertTrue(result.stderr.contains("cell 1 failed"), result.stderr)
      XCTAssertTrue(FileManager.default.fileExists(atPath: containerState.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: containerCalls.path), "pre-live cleanup must not query container inventory")
      XCTAssertFalse(FileManager.default.fileExists(atPath: try liveRuntime(for: root).path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("failure-v1.tsv").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".phase09-gate08-active-v1").path))
    }
  }

  func testForcedMidLiveFailureCleansOnlyLedgeredRuntimeArtifacts() throws {
    try withRoot { root, environment in
      let wrapperDirectory = root.deletingLastPathComponent().appendingPathComponent("gate08-live-failure-wrappers")
      try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: false)
      let containerState = root.deletingLastPathComponent().appendingPathComponent("mock-container-state.json")
      try writeExecutable(
        """
        #!/bin/bash
        if [[ "${1:-}" == "test" ]]; then exit 0; fi
        exec /usr/bin/swift "$@"
        """, named: "swift", in: wrapperDirectory)
      try writeExecutable(
        """
        #!/bin/bash
        set -euo pipefail
        state="${HOSTWRIGHT_PHASE09_MOCK_CONTAINER_STATE:?}"
        digest='sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92'
        resource='hostwright-v2-p09-test-live'
        json() {
          if [[ -f "$state" ]]; then
            printf '[{"id":"%s","configuration":{"image":{"descriptor":{"digest":"%s"}},"labels":{"dev.hostwright.project":"phase09-gate08-live","dev.hostwright.service":"probe"}}}]\\n' "$resource" "$digest"
          else
            printf '[]\\n'
          fi
        }
        case "${1:-}" in
          --version)
            exec /usr/local/bin/container --version
            ;;
          phase09-test-create)
            [[ "${2:-}" == "$resource" ]]
            : > "$state"
            ;;
          list)
            [[ "${2:-}" == "--all" && "${3:-}" == "--format" && "${4:-}" == "json" ]]
            json
            ;;
          delete)
            [[ "${2:-}" == "--force" && "${3:-}" == "$resource" ]]
            /bin/unlink "$state"
            ;;
          *)
            printf 'unexpected container invocation: %s\\n' "$*" >&2
            exit 92
            ;;
        esac
        """, named: "container", in: wrapperDirectory)

      var failing = environment
      failing["PATH"] = wrapperDirectory.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
      failing["HOSTWRIGHT_PHASE09_HARNESS_TEST_FORCE_LIVE_FAILURE"] = "1"
      failing["HOSTWRIGHT_PHASE09_MOCK_CONTAINER_STATE"] = containerState.path
      XCTAssertEqual(try run(["prepare", "8"], environment: failing).status, 0)
      let result = try run(["run", "8"], environment: failing)
      XCTAssertEqual(result.status, 47, result.stderr)
      XCTAssertTrue(result.stderr.contains("cell 3 failed"), result.stderr)

      let ledger = try String(contentsOf: root.appendingPathComponent("ownership-v1.tsv"), encoding: .utf8)
      let process = try XCTUnwrap(ledger.split(separator: "\n").first(where: { $0.contains("\tprocess\t") }))
      let processFields = process.split(separator: "\t", omittingEmptySubsequences: false)
      let executable = try XCTUnwrap(processFields.indices.contains(3) ? String(processFields[3]) : nil)
      let pid = try XCTUnwrap(process.split(separator: "\t").last?.split(separator: ";").first?.split(separator: "=").last)
      let expectedExecutable = try liveRuntime(for: root)
        .appendingPathComponent("signed-hostwrightd").path
      XCTAssertEqual(executable, expectedExecutable)
      XCTAssertFalse(isRunning(Int32(String(pid)) ?? 0), "ledgered test sleep must be stopped by EXIT cleanup")

      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-01.stdout.log").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-02.stdout.log").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-03.stdout.log").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-04.stdout.log").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("failure-v1.tsv").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent(".phase09-gate08-active-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: executable), "the ledgered runtime-local executable must be removed")
      XCTAssertFalse(FileManager.default.fileExists(atPath: try liveRuntime(for: root).path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: containerState.path))
    }
  }

  func testTamperedProcessLedgerRefusesContainerAndRuntimeCleanup() throws {
    try withRoot { root, environment in
      let parent = root.deletingLastPathComponent()
      let wrappers = parent.appendingPathComponent("gate08-tampered-ledger-wrappers")
      let containerState = parent.appendingPathComponent("tampered-ledger-container.state")
      let containerCalls = parent.appendingPathComponent("tampered-ledger-container.calls")
      try FileManager.default.createDirectory(at: wrappers, withIntermediateDirectories: false)
      try writeExecutable(
        """
        #!/bin/bash
        if [[ "${1:-}" == "test" ]]; then exit 0; fi
        exec /usr/bin/swift "$@"
        """, named: "swift", in: wrappers)
      try writeExecutable(
        """
        #!/bin/bash
        set -euo pipefail
        state="${HOSTWRIGHT_PHASE09_MOCK_CONTAINER_STATE:?}"
        calls="${HOSTWRIGHT_PHASE09_MOCK_CONTAINER_CALLS:?}"
        ledger="${HOSTWRIGHT_PHASE09_GATE_ROOT:?}/ownership-v1.tsv"
        digest='sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92'
        resource='hostwright-v2-p09-test-live'
        json() {
          if [[ -f "$state" ]]; then
            printf '[{"id":"%s","configuration":{"image":{"descriptor":{"digest":"%s"}},"labels":{"dev.hostwright.project":"phase09-gate08-live","dev.hostwright.service":"probe"}}}]\\n' "$resource" "$digest"
          else
            printf '[]\\n'
          fi
        }
        case "${1:-}" in
          --version)
            exec /usr/local/bin/container --version
            ;;
          phase09-test-create)
            [[ "${2:-}" == "$resource" ]]
            : > "$state"
            tmp="${ledger}.tampered"
            /usr/bin/awk -F '\t' 'BEGIN{OFS=FS} $2=="process"{$5="0"} {print}' "$ledger" > "$tmp"
            chmod 600 "$tmp"
            /bin/mv "$tmp" "$ledger"
            ;;
          list)
            printf 'list\\n' >> "$calls"
            json
            ;;
          delete)
            printf 'delete\\n' >> "$calls"
            /bin/unlink "$state"
            ;;
          *) exit 92 ;;
        esac
        """, named: "container", in: wrappers)

      var failing = environment
      failing["PATH"] = wrappers.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
      failing["HOSTWRIGHT_PHASE09_HARNESS_TEST_FORCE_LIVE_FAILURE"] = "1"
      failing["HOSTWRIGHT_PHASE09_MOCK_CONTAINER_STATE"] = containerState.path
      failing["HOSTWRIGHT_PHASE09_MOCK_CONTAINER_CALLS"] = containerCalls.path
      XCTAssertEqual(try run(["prepare", "8"], environment: failing).status, 0)
      let result = try run(["run", "8"], environment: failing)
      let ledger = try String(contentsOf: root.appendingPathComponent("ownership-v1.tsv"), encoding: .utf8)
      let process = try XCTUnwrap(ledger.split(separator: "\n").first(where: { $0.contains("\tprocess\t") }))
      let processFields = process.split(separator: "\t", omittingEmptySubsequences: false)
      let executable = try XCTUnwrap(processFields.indices.contains(3) ? String(processFields[3]) : nil)
      let pidText = try XCTUnwrap(process.split(separator: "\t").last?.split(separator: ";").first?.split(separator: "=").last)
      let pid = Int32(String(pidText)) ?? 0
      defer {
        stopExactProcess(pid)
        try? FileManager.default.removeItem(at: containerState)
        try? FileManager.default.removeItem(at: containerCalls)
      }

      XCTAssertEqual(result.status, 47, result.stderr)
      XCTAssertTrue(result.stderr.contains("cell 3 failed"), result.stderr)
      let expectedExecutable = try liveRuntime(for: root)
        .appendingPathComponent("signed-hostwrightd").path
      XCTAssertEqual(executable, expectedExecutable)
      XCTAssertTrue(FileManager.default.fileExists(atPath: executable), "tampered identity must preserve the runtime-local executable")
      XCTAssertTrue(process.split(separator: "\t").dropFirst(4).first == "0", "test must corrupt the recorded device identity")
      XCTAssertTrue(FileManager.default.fileExists(atPath: containerState.path), "container deletion must be refused after process identity mismatch")
      XCTAssertTrue(FileManager.default.fileExists(atPath: try liveRuntime(for: root).path), "runtime deletion must be refused after process identity mismatch")
      let calls = (try? String(contentsOf: containerCalls, encoding: .utf8)) ?? ""
      XCTAssertFalse(calls.contains("delete"), calls)
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("failure-v1.tsv").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".phase09-gate08-active-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-04.stdout.log").path))
    }
  }

  func testReuseCMSAndOwnedOnlyCleanupAreFrozen() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("reusable"))
    XCTAssertTrue(source.contains("security cms -S"))
    XCTAssertTrue(source.contains("Gate 8 evidence is valid and reused; no cells were rerun."))
    XCTAssertTrue(source.contains("completed evidence is incomplete or changed; preserve this root and do not rerun."))
    XCTAssertTrue(source.contains("root_lock_created=0; gate_lock_created=0"))
    XCTAssertTrue(source.contains("A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB"))
    XCTAssertTrue(source.contains("record_root"))
    XCTAssertTrue(source.contains("short_live_runtime"))
    XCTAssertTrue(source.contains("macOS Unix-domain path limit"))
    XCTAssertTrue(source.contains("inventory"))
    XCTAssertTrue(source.contains("live artifact identity changed; cleanup is refused"))
    XCTAssertTrue(source.contains("emergency_live_cleanup"))
    XCTAssertTrue(source.contains("record_process"))
    XCTAssertTrue(source.contains("record_container"))
    XCTAssertTrue(source.contains("keychain_namespace"))
    XCTAssertTrue(source.contains("record_keychain_item"))
    XCTAssertTrue(source.contains("record_keychain_items"))
    XCTAssertTrue(source.contains("cleanup_keychain_items"))
    XCTAssertTrue(source.contains("require_keychain_absent"))
    XCTAssertTrue(source.contains("^dev\\.hostwright\\.(audit|stream-cursor)\\.v1\\.[a-f0-9]{32}$"))
    XCTAssertTrue(source.contains("active-key-id"))
    XCTAssertTrue(source.contains("chain-head-v1"))
    XCTAssertTrue(source.contains("signing-key:p256:"))
    XCTAssertTrue(source.contains(
      "service=%s;account=%s;marker=hostwright-audit-owned-v1;scope=gate08-live"))
    XCTAssertTrue(source.contains(
      "/usr/bin/security delete-generic-password -s \"$service\" -a \"$account\""))
    XCTAssertTrue(source.contains(
      "/usr/bin/security find-generic-password -s \"$service\" -a \"$account\" >/dev/null 2>&1"))
    XCTAssertTrue(source.contains(
      "require_keychain_absent \"$service\" \"$account\""))
    XCTAssertTrue(source.contains(
      "require_keychain_absent \"$expected_audit\""))
    XCTAssertTrue(source.contains(
      "require_keychain_absent \"$expected_cursor\""))
    XCTAssertTrue(source.contains("[[ \"$status\" == 44 ]] || die 'Gate 8 Keychain absence verification failed.'"))
    XCTAssertFalse(source.contains("--cleanup --root"))
    XCTAssertTrue(source.contains("kill -TERM -- \"-$pgid\""))
    XCTAssertTrue(source.contains("HOSTWRIGHT_PHASE09_HARNESS_TEST_FORCE_LIVE_FAILURE"))
    XCTAssertTrue(source.contains("! -L \"$root/evidence-v1.sha256\""))
    XCTAssertTrue(source.contains("prepared evidence headers are invalid"))
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
    let root = parent.appendingPathComponent("phase09-gate08-\(UUID().uuidString.lowercased())", isDirectory: true)
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
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [harness.path] + arguments
    var values = ProcessInfo.processInfo.environment
    for (key, value) in environment { values[key] = value }
    process.environment = values; process.currentDirectoryURL = currentDirectory ?? repository
    let stdout = Pipe(); let stderr = Pipe(); process.standardOutput = stdout; process.standardError = stderr
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
    guard process.terminationStatus == 0 else { throw NSError(domain: "Gate08Harness", code: 1) }
    return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .newlines)
  }

  private func liveRuntime(for root: URL) throws -> URL {
    let canonicalRoot = URL(fileURLWithPath: try canonicalPath(root))
    let prefix = "phase09-gate08-"
    XCTAssertTrue(canonicalRoot.lastPathComponent.hasPrefix(prefix))
    let suffix = canonicalRoot.lastPathComponent.dropFirst(prefix.count).prefix(17)
    return canonicalRoot.deletingLastPathComponent()
      .appendingPathComponent(".p09g8-\(suffix)", isDirectory: true)
  }

  private func permissions(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
  }

  private func writeExecutable(_ text: String, named name: String, in directory: URL) throws {
    let file = directory.appendingPathComponent(name)
    try Data(text.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
  }

  private func isRunning(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
  }

  private func stopExactProcess(_ pid: Int32) {
    guard pid > 0, isRunning(pid) else { return }
    _ = kill(pid, SIGTERM)
    for _ in 0..<50 {
      if !isRunning(pid) { return }
      usleep(10_000)
    }
    _ = kill(pid, SIGKILL)
  }
}

private struct ShellResult { let status: Int32; let stdout: String; let stderr: String }
