import Darwin
import Foundation
import XCTest

final class Phase09Gate09QualificationHarnessTests: XCTestCase {
  private var repository: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var harness: URL {
    repository.appendingPathComponent("Scripts/phase09-gate09-qualification.sh")
  }

  func testContractFreezesGateNineParityAndAllSixEvidenceCells() throws {
    let result = try run(["contract"])
    XCTAssertEqual(result.status, 0, result.stderr)
    XCTAssertTrue(result.stdout.contains("Gate 9 — 56.25%"))
    XCTAssertTrue(result.stdout.contains("Exactly one Gate 9 qualification"))
    XCTAssertTrue(result.stdout.contains("never inspects, stops, or removes"))

    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("for n in 1 2 3 4 5 6"))
    XCTAssertTrue(source.contains("HostwrightCommandTransportTests"))
    XCTAssertTrue(source.contains("CLIControlAuthorizationScopeTests"))
    XCTAssertTrue(source.contains("PersistentControlStreamIntegrationTests"))
    XCTAssertTrue(source.contains("DaemonControlStreamSourcesTests"))
    XCTAssertTrue(source.contains("BootstrapControl"))
    XCTAssertTrue(source.contains("revision 2.0"))
    XCTAssertTrue(source.contains("revision 2.1"))
    XCTAssertTrue(source.contains("no hidden mutation entry point"))
    XCTAssertTrue(source.contains("signed daemon/CLI/control"))
    XCTAssertFalse(source.contains("phase08"))
    XCTAssertFalse(source.contains("p08-soak"))
    XCTAssertFalse(source.contains("tmux list-sessions"))
    XCTAssertTrue(source.contains("for n in 1 2 3 4 5 6"))
    XCTAssertTrue(source.contains("\"$cli\" logs probe \"$config\" --state-db \"$state\" --tail 20"))
    XCTAssertTrue(source.contains("\"$cli\" exec probe --manifest \"$config\" --state-db \"$state\" --no-stdin"))
    XCTAssertTrue(source.contains("short_live_runtime"))
    XCTAssertTrue(source.contains("${#socket} < 104"))
    XCTAssertTrue(source.contains("--identifier hostwright-control \"$bootstrap\""))
    XCTAssertTrue(source.contains("--socket \"$socket\" --client \"$cli\""))
    XCTAssertTrue(source.contains("qualification.plan-v1.json"))
    XCTAssertTrue(source.contains("^[a-f0-9]{16}$"))
    XCTAssertTrue(source.contains("-o -name 'qualification.*.json'"))
    let qualificationTool = try String(
      contentsOf: repository.appendingPathComponent(
        "Sources/HostwrightStreamQualificationTool/main.swift"),
      encoding: .utf8)
    XCTAssertTrue(qualificationTool.contains("qualificationIdentity.signingIdentifier == \"hostwright-control\""))
    XCTAssertTrue(qualificationTool.contains("roleID: DefaultRole.operator.rawValue"))
    XCTAssertFalse(qualificationTool.contains("roleID: DefaultRole.owner.rawValue"))
  }

  func testStreamQualificationBootstrapDeclaresCliAndStreamSubjectsWhenCodeHashesDiffer() throws {
    let source = try String(
      contentsOfFile: "Sources/HostwrightStreamQualificationTool/main.swift",
      encoding: .utf8
    )
    XCTAssertTrue(source.contains("codeIdentity(at:"))
    XCTAssertTrue(source.contains("let ownerIdentity = try clientPath.map { try codeIdentity(at: $0) } ?? qualificationIdentity"))
    XCTAssertTrue(source.contains("ownerIdentity.signingIdentifier == \"hostwright\""))
    XCTAssertTrue(source.contains("qualificationIdentity.signingIdentifier == \"hostwright-control\""))
    XCTAssertTrue(source.contains("\"gate09-owner-\\(ownerIdentity.codeDirectoryHash.prefix(16))\""))
    XCTAssertTrue(source.contains("\"gate09-stream-\\(qualificationIdentity.codeDirectoryHash.prefix(16))\""))
    XCTAssertTrue(source.contains("store.controlIdentities.declare"))
    XCTAssertTrue(source.contains("store.rbac.createBinding(RBACBindingRecord("))
    XCTAssertTrue(source.contains("roleID: DefaultRole.operator.rawValue"))
    XCTAssertTrue(source.contains("Data(ownerSubjectID.utf8).write(to: root.appendingPathComponent(\"subject-id.txt\"))"))
  }

  func testPrepareBindsPrivateRootToGateNineDependenciesAndLedger() throws {
    try withRoot { root, environment in
      let result = try run(["prepare", "9"], environment: environment)
      XCTAssertEqual(result.status, 0, result.stderr)

      let manifest = try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("manifest-v1.json"))) as? [String: Any]
      XCTAssertEqual(manifest?["schema"] as? String, "hostwright.phase09.gate09.qualification.manifest.v1")
      XCTAssertEqual(manifest?["gate"] as? Int, 9)
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
    let wrongGate = try run(["prepare", "8"])
    XCTAssertNotEqual(wrongGate.status, 0)
    XCTAssertTrue(wrongGate.stderr.contains("only prepare 9"))

    try withRoot { _, environment in
      let protected = try run(
        ["prepare", "9"], environment: environment,
        currentDirectory: URL(fileURLWithPath: "/Users/dev/Documents/hostwright"))
      XCTAssertNotEqual(protected.status, 0)
      XCTAssertTrue(protected.stderr.contains("requires branch"))
    }
  }

  func testHarnessNeverInspectsAnotherPhase() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertFalse(source.contains("phase08"))
    XCTAssertFalse(source.contains("p08-soak"))
    XCTAssertFalse(source.contains("tmux list-sessions"))
    XCTAssertFalse(source.contains("pgrep -afil"))
  }

  func testFailurePreservesLocksAndDoesNotRunNextCell() throws {
    try withRoot { root, environment in
      XCTAssertEqual(try run(["prepare", "9"], environment: environment).status, 0)
      let wrappers = root.deletingLastPathComponent().appendingPathComponent("swift-wrapper")
      try FileManager.default.createDirectory(at: wrappers, withIntermediateDirectories: false)
      try writeExecutable(
        "#!/bin/bash\nif [[ \"${1:-}\" == test ]]; then exit 47; fi\nexec /usr/bin/swift \"$@\"\n",
        named: "swift", in: wrappers)
      var failing = environment
      failing["PATH"] = wrappers.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")

      let result = try run(["run", "9"], environment: failing)
      XCTAssertEqual(result.status, 47, result.stderr)
      XCTAssertTrue(result.stderr.contains("cell 1 failed"), result.stderr)
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("failure-v1.tsv").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
      XCTAssertTrue(FileManager.default.fileExists(
        atPath: root.deletingLastPathComponent().appendingPathComponent(".phase09-gate09-active-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-02.stdout.log").path))
    }
  }

  func testForcedLiveFailureCleansOnlyLedgeredArtifacts() throws {
    try withRoot { root, environment in
      let parent = root.deletingLastPathComponent()
      let wrappers = parent.appendingPathComponent("gate09-live-failure-wrappers")
      let containerState = parent.appendingPathComponent("gate09-mock-container-state")
      let unrelatedContainerState = parent.appendingPathComponent("gate09-unrelated-container-state")
      try Data().write(to: unrelatedContainerState)
      try FileManager.default.createDirectory(at: wrappers, withIntermediateDirectories: false)
      try writeExecutable(
        "#!/bin/bash\nif [[ \"${1:-}\" == test ]]; then exit 0; fi\nexec /usr/bin/swift \"$@\"\n",
        named: "swift", in: wrappers)
      try writeExecutable(
        """
        #!/bin/bash
        set -euo pipefail
        state="${HOSTWRIGHT_PHASE09_MOCK_CONTAINER_STATE:?}"
        unrelated="${HOSTWRIGHT_PHASE09_MOCK_UNRELATED_CONTAINER_STATE:?}"
        resource='hostwright-v2-p09-test-live'
        case "${1:-}" in
          --version) exec /usr/local/bin/container --version ;;
          phase09-test-create) [[ "${2:-}" == "$resource" ]]; : > "$state" ;;
          list) if [[ -f "$state" ]]; then printf '[{"id":"%s","configuration":{"image":{"descriptor":{"digest":"sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92"}},"labels":{"dev.hostwright.project":"%s"}}},{"id":"hostwright-v2-unrelated","configuration":{"image":{"descriptor":{"digest":"sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92"}},"labels":{"dev.hostwright.project":"phase09-gate09-other-root"}}}]\\n' "$resource" "$HOSTWRIGHT_PHASE09_LIVE_PROJECT"; elif [[ -f "$unrelated" ]]; then printf '[{"id":"hostwright-v2-unrelated","configuration":{"image":{"descriptor":{"digest":"sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92"}},"labels":{"dev.hostwright.project":"phase09-gate09-other-root"}}}]\\n'; else printf '[]\\n'; fi ;;
          delete) [[ "${2:-}" == "--force" && "${3:-}" == "$resource" && -f "$state" ]]; /bin/unlink "$state" ;;
          *) exit 92 ;;
        esac
        """, named: "container", in: wrappers)
      var failing = environment
      failing["PATH"] = wrappers.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
      failing["HOSTWRIGHT_PHASE09_HARNESS_TEST_FORCE_LIVE_FAILURE"] = "1"
      failing["HOSTWRIGHT_PHASE09_MOCK_CONTAINER_STATE"] = containerState.path
      failing["HOSTWRIGHT_PHASE09_MOCK_UNRELATED_CONTAINER_STATE"] = unrelatedContainerState.path
      XCTAssertEqual(try run(["prepare", "9"], environment: failing).status, 0)
      let result = try run(["run", "9"], environment: failing)
      let cellError = (try? String(
        contentsOf: root.appendingPathComponent("cell-03.stderr.log"),
        encoding: .utf8
      )) ?? ""

      XCTAssertEqual(result.status, 47, result.stderr + cellError)
      XCTAssertTrue(result.stderr.contains("cell 3 failed"), result.stderr)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: containerState.path),
        result.stderr + cellError
      )
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: unrelatedContainerState.path),
        "cleanup must preserve a same-digest container owned by another evidence root"
      )
      let suffix = root.lastPathComponent.replacingOccurrences(of: "phase09-gate09-", with: "")
      let liveRuntime = parent.appendingPathComponent(".p09g9-\(suffix.prefix(17))")
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: liveRuntime.path),
        result.stderr
      )
      let preservedDiagnostic = root.appendingPathComponent(
        "live-failure-diagnostics-v1/daemon.forced.stderr.log")
      XCTAssertEqual(
        try String(contentsOf: preservedDiagnostic, encoding: .utf8),
        "forced Gate 9 live failure diagnostic\n")
      XCTAssertEqual(try permissions(preservedDiagnostic), 0o600)
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("failure-v1.tsv").path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-run-v1").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cell-04.stdout.log").path))
    }
  }

  func testEvidenceReuseAndDependencyInvalidationAreFrozen() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("reusable"))
    XCTAssertTrue(source.contains("revalidate_dependencies"))
    XCTAssertTrue(source.contains("source_digest_value"))
    XCTAssertTrue(source.contains("config_digest_value"))
    XCTAssertTrue(source.contains("toolchain_digest_value"))
    XCTAssertTrue(source.contains("completed evidence is incomplete or changed; preserve this root and do not rerun."))
    XCTAssertTrue(source.contains("Gate 9 evidence is valid and reused; no cells were rerun."))
    XCTAssertTrue(source.contains("security cms -S"))
    XCTAssertTrue(source.contains("! -L \"$root/evidence-v1.sha256\""))
    XCTAssertTrue(source.contains("prepared evidence dependencies changed; preserve this root."))
    XCTAssertTrue(source.contains("root_lock_created=0; gate_lock_created=0"))
  }

  func testEmergencyCleanupRemainsStrictlyOwnedOnly() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    XCTAssertTrue(source.contains("emergency_live_cleanup"))
    XCTAssertTrue(source.contains("record_root"))
    XCTAssertTrue(source.contains("record_process"))
    XCTAssertTrue(source.contains("record_container"))
    XCTAssertTrue(source.contains("live artifact identity changed; cleanup is refused"))
    XCTAssertTrue(source.contains("/bin/unlink"))
    XCTAssertFalse(source.contains("rm -rf"))
    XCTAssertFalse(source.contains("HOSTWRIGHT_NOTARY_PROFILE"))
    XCTAssertFalse(source.contains("gh pr"))
  }

  func testAutonomousConvergenceUsesPendingClaimAndMetricsExportMutation() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    let live = try XCTUnwrap(source.section(named: "live"))
    let pendingClaim = try XCTUnwrap(live.range(of: "record_pending_container_claim"))
    let initialDaemon = try XCTUnwrap(
      live.range(of: "pid=\"$(start_daemon \"$runtime\" \"$daemon\" \"$config\" \"$state\" initial \"$cli\")\"")
    )

    XCTAssertLessThan(pendingClaim.lowerBound, initialDaemon.lowerBound)
    XCTAssertFalse(live.contains("\"$cli\" apply"))
    XCTAssertTrue(live.contains("for n in {1..1200}"))
    XCTAssertTrue(live.contains("resource=\"$(resolve_pending_container_claim)\""))
    XCTAssertTrue(live.contains("owned Gate 9 container was not observed."))
    XCTAssertTrue(live.contains("\"$cli\" metrics export --state-db \"$state\""))
    XCTAssertTrue(live.contains("--confirm-snapshot \"$metrics_hash\""))
    let traceExport = try XCTUnwrap(live.range(of: "traces export --state-db \"$state\""))
    XCTAssertTrue(live.contains("FROM event_ledger"))
    XCTAssertTrue(live.contains("type = 'trace.span.v1'"))
    XCTAssertTrue(live.contains("source = 'hostwright.trace'"))
    XCTAssertFalse(live.contains("FROM trace_spans"))
    XCTAssertTrue(source.contains("process_state=\"$(ps -p \"$pid\" -o state="))
    XCTAssertTrue(source.contains("[[ \"$process_state\" == Z* ]] && return 0"))
    XCTAssertTrue(source.contains("for n in {1..600}; do if ! kill -0 \"$pid\""))
    let quiesce = try XCTUnwrap(live.range(of: "stop_exact_process \"$daemon\""))
    let acquireFence = try XCTUnwrap(live.range(of: "acquire_lifecycle_mutation_fence \"$state\""))
    let releaseFence = try XCTUnwrap(live.range(of: "release_lifecycle_mutation_fence"))
    let socketCleanup = try XCTUnwrap(live.range(of: "remove_owned_socket \"$runtime\" \"$socket\""))
    let metrics = try XCTUnwrap(live.range(of: "# Metrics require the authenticated CLI/daemon path"))
    let restart = try XCTUnwrap(live.range(of: "pid=\"$(start_daemon \"$runtime\" \"$daemon\" \"$config\" \"$state\" restarted \"$cli\")\""))
    XCTAssertLessThan(traceExport.lowerBound, quiesce.lowerBound)
    XCTAssertLessThan(metrics.lowerBound, quiesce.lowerBound)
    XCTAssertLessThan(metrics.lowerBound, acquireFence.lowerBound)
    XCTAssertLessThan(acquireFence.lowerBound, releaseFence.lowerBound)
    XCTAssertTrue(live.contains("one stable read-only observation transaction"))
    XCTAssertLessThan(quiesce.lowerBound, socketCleanup.lowerBound)
    XCTAssertLessThan(socketCleanup.lowerBound, restart.lowerBound)
    XCTAssertLessThan(metrics.lowerBound, restart.lowerBound)
    XCTAssertTrue(live.contains("metrics_exported=0"))
    XCTAssertTrue(live.contains("for n in {1..60}"))
    XCTAssertTrue(live.contains("metrics_snapshot_status=$?"))
    XCTAssertTrue(live.contains("HW-CLI-005"))
    XCTAssertTrue(live.contains("qualification.metrics-snapshot-v1.json"))
    XCTAssertTrue(source.contains("flock($fh, LOCK_EX)"))
    XCTAssertTrue(source.contains("lifecycle-mutation fence identity changed"))
    XCTAssertTrue(live.contains("HW-METRIC-003"))
    XCTAssertTrue(live.contains("HW-CLI-005|authoritative database changed"))
    XCTAssertTrue(live.contains("else\n      metrics_export_status=$?"))
    XCTAssertTrue(live.contains("metrics snapshot remained unstable across bounded retries"))
    XCTAssertTrue(source.contains("\"$cli\" status \"$config\" --state-db \"$state\" --output json"))
    XCTAssertTrue(source.contains("qualification.status-plan-v1.json"))
  }

  func testLiveManifestLivenessAndStatusConvergenceAreExplicitAndBounded() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    let live = try XCTUnwrap(source.section(named: "live"))
    let convergence = try XCTUnwrap(source.section(named: "wait_for_converged_status"))
    let readiness = try XCTUnwrap(source.section(named: "wait_for_authenticated_daemon"))

    XCTAssertTrue(live.contains("liveness:"))
    XCTAssertTrue(live.contains("exec: [\"true\"]"))
    XCTAssertTrue(live.contains("interval: 60s"))
    XCTAssertTrue(live.contains("timeout: 1s"))
    XCTAssertTrue(live.contains("wait_for_converged_status \"$runtime\" \"$cli\" \"$config\" \"$state\" \"$resource\""))
    XCTAssertTrue(live.contains("start_daemon \"$runtime\" \"$daemon\" \"$config\" \"$state\" initial \"$cli\""))
    XCTAssertTrue(live.contains("start_daemon \"$runtime\" \"$daemon\" \"$config\" \"$state\" restarted \"$cli\""))
    XCTAssertTrue(live.contains("if HOSTWRIGHT_APPLICATION_SUPPORT_DIR=\"$runtime/app-support\" \"$cli\" capabilities --json"))
    XCTAssertTrue(live.contains("CLI unexpectedly bypassed the unavailable daemon."))
    XCTAssertTrue(readiness.contains("capabilities --json"))
    XCTAssertTrue(readiness.contains("deadline=$(( $(/bin/date +%s) + 60 ))"))
    XCTAssertTrue(readiness.contains("/bin/sleep 1"))
    XCTAssertTrue(readiness.contains("owned daemon did not pass authenticated readiness"))

    XCTAssertTrue(convergence.contains("deadline_epoch=$(( $(/bin/date +%s) + 300 ))"))
    XCTAssertTrue(convergence.contains("while [[ \"$(/bin/date +%s)\" -lt \"$deadline_epoch\" ]]"))
    XCTAssertTrue(convergence.contains("/bin/sleep 1"))
    XCTAssertFalse(convergence.contains("for n in {1..1200}"))
    XCTAssertTrue(convergence.contains("\"$cli\" status \"$config\" --state-db \"$state\" --output json"))
    XCTAssertTrue(convergence.contains("--arg resource \"$resource\""))
    XCTAssertTrue(convergence.contains(".resourceIdentifier == $resource"))
    XCTAssertTrue(convergence.contains(".lifecycle == \"running\""))
    XCTAssertTrue(convergence.contains(".health == \"healthy\""))
    XCTAssertTrue(convergence.contains("(.actions | length) == 0"))
    XCTAssertTrue(convergence.contains("owned Gate 9 probe did not converge"))
  }

  func testKeychainCleanupIsLedgerOnlyMarkerVerifiedAndBootstrapFree() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    let live = try XCTUnwrap(source.section(named: "live"))
    let emergencyCleanup = try XCTUnwrap(source.section(named: "emergency_live_cleanup"))
    let keychainCleanup = try XCTUnwrap(source.section(named: "cleanup_keychain_items"))
    let absenceVerification = try XCTUnwrap(source.section(named: "verify_keychain_absent"))

    XCTAssertTrue(keychainCleanup.contains("$2==\"keychain-item\""))
    XCTAssertTrue(keychainCleanup.contains("security find-generic-password -s \"$service\" -a \"$account\""))
    XCTAssertTrue(keychainCleanup.contains("hostwright-audit-owned-v1"))
    XCTAssertTrue(keychainCleanup.contains("security delete-generic-password -s \"$service\" -a \"$account\""))
    XCTAssertTrue(source.contains("record_keychain_items_for_service"))
    XCTAssertTrue(source.contains("security dump-keychain 2>/dev/null"))
    XCTAssertFalse(source.contains("security dump-keychain -d"))
    XCTAssertTrue(absenceVerification.contains("security find-generic-password -s \"$service\" -a \"$account\""))
    XCTAssertTrue(absenceVerification.contains("[[ \"$status\" == 44 ]]"))
    XCTAssertTrue(live.contains("cleanup_keychain_items"))
    XCTAssertTrue(emergencyCleanup.contains("cleanup_keychain_items"))
    XCTAssertFalse(live.contains("\"$bootstrap\" --cleanup"))
    XCTAssertFalse(emergencyCleanup.contains("\"$bootstrap\" --cleanup"))
  }

  func testKeychainAccountParserFlushesHeaderDelimitedRecords() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    let parser = try XCTUnwrap(source.section(named: "keychain_accounts_from_dump"))
    XCTAssertTrue(parser.contains("/^keychain:/ { emit(); reset() }"))

    let service = "dev.hostwright.stream-cursor.v1.0123456789abcdef0123456789abcdef"
    let account = "signing-key:p256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    let sample = """
    keychain: \"first\"
    attributes:
        \"svce\"<blob>=\"dev.hostwright.other\"
        \"acct\"<blob>=\"ignored\"
    keychain: \"second\"
    attributes:
        \"svce\"<blob>=\"\(service)\"
        \"acct\"<blob>=\"\(account)\"
    keychain: \"third\"
    attributes:
        \"svce\"<blob>=\"dev.hostwright.other\"
        \"acct\"<blob>=\"ignored-after-target\"
    """
    let input = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-phase09-keychain-dump-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: input) }
    try sample.write(to: input, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", "source \"$1\"; keychain_accounts_from_dump \"$2\"", "parser-test", harness.path, service]
    let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    stdin.fileHandleForWriting.write(try Data(contentsOf: input))
    try stdin.fileHandleForWriting.close()
    process.waitUntilExit()

    XCTAssertEqual(process.terminationStatus, 0, String(
      decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    XCTAssertEqual(
      String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      "\(account)\n")
  }

  func testContainerDeletionIsCentralizedBehindExactLedgerRevalidation() throws {
    let source = try String(contentsOf: harness, encoding: .utf8)
    let identity = try XCTUnwrap(source.section(named: "container_identity_is_exact"))
    let deletion = try XCTUnwrap(source.section(named: "delete_exact_container"))
    let cleanup = try XCTUnwrap(source.section(named: "emergency_live_cleanup"))

    XCTAssertTrue(identity.contains("container list --all --format json"))
    XCTAssertTrue(identity.contains("--arg resource \"$resource\""))
    XCTAssertTrue(identity.contains("--arg digest \"$pinned_image_digest\""))
    XCTAssertTrue(identity.contains("--arg project \"$live_project\""))
    XCTAssertTrue(identity.contains(".id==$resource"))
    XCTAssertTrue(identity.contains(".configuration.image.descriptor.digest==$digest"))
    XCTAssertTrue(identity.contains(".configuration.labels[\"dev.hostwright.project\"]==$project"))
    XCTAssertTrue(deletion.contains("container_identity_is_exact"))
    XCTAssertTrue(deletion.contains("container delete --force \"$resource\""))
    XCTAssertTrue(cleanup.contains("$2==\"container-resource\""))
    XCTAssertTrue(cleanup.contains("delete_exact_container \"$resource\""))

    XCTAssertEqual(source.components(separatedBy: "container delete --force").count, 2)
    XCTAssertTrue(source.contains("live_project=\"phase09-gate09-$(printf '%s' \"${root##*/}\""))
    XCTAssertFalse(source.contains("project='phase09-gate09-live'"))
  }

  private func withRoot(_ body: (URL, [String: String]) throws -> Void) throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-phase09-harness-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("phase09-gate09-\(UUID().uuidString.lowercased())", isDirectory: true)
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
    guard process.terminationStatus == 0 else { throw NSError(domain: "Gate09Harness", code: 1) }
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

private extension String {
  func section(named function: String) -> String? {
    guard let start = range(of: "\(function)(){") else { return nil }
    let remaining = self[start.lowerBound...]
    if let end = remaining.range(of: "\n}") {
      return String(remaining[..<end.lowerBound])
    }
    guard let end = remaining.range(of: "\n") else { return String(remaining) }
    return String(remaining[..<end.lowerBound])
  }
}

private struct Gate09ShellResult {
  let status: Int32
  let stdout: String
  let stderr: String
}

private typealias ShellResult = Gate09ShellResult
