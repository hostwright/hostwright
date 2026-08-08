import Foundation
import XCTest

final class MutationCheckpointQualificationScriptTests: XCTestCase {
    func testContractIsSerialResumableAndNonDisruptive() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-mutation-checkpoint-qualification.sh"
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "contract"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertTrue(
            text.contains(
                "Phase 08 mutation checkpoint qualification contract v1 is valid."
            )
        )
        for fragment in [
            "Cells run serially",
            "exact source digest",
            "LifecycleProcessRecoveryIntegrationTests",
            "HostwrightDaemonCoreTests",
            "RuntimeQualificationRecoveryDriverTests",
            "RuntimeQualificationProcessControlTests",
            "ServiceTunnelLifecycleManagerTests",
            "StoragePruneProcessRecoveryIntegrationTests",
            "SQLiteHardeningTests",
            "StorageAttachmentCoordinatorTests",
            "StateMaintenanceTests",
            "RuntimeProviderMigrationTests",
            "DaemonLifecycleContractTests",
            "DistributionDurableLifecycleTests",
            "HostwrightCLITests",
            "MutationCheckpointQualificationScriptTests"
        ] {
            XCTAssertTrue(text.contains(fragment), "Missing cell: \(fragment)")
        }
        XCTAssertTrue(script.contains("active-run-v1"))
        XCTAssertTrue(script.contains("grep -Fqx"))
        XCTAssertTrue(
            script.contains(
                "rmdir \"$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT/active-run-v1\""
            )
        )
        XCTAssertTrue(script.contains("cell-${index}.log.XXXXXX"))
        XCTAssertTrue(script.contains("umask 022 && swift test"))
        XCTAssertFalse(script.contains("swift test &"))
        XCTAssertFalse(script.contains("rm -rf"))
        XCTAssertFalse(script.contains("/sbin/reboot"))
        XCTAssertFalse(script.contains("/sbin/shutdown"))
        XCTAssertFalse(script.contains("launchctl"))
        XCTAssertFalse(script.contains("gh "))
    }

    func testAggregateSoakContractIsFixedPrivateAndNonDisruptive() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "contract"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        for fragment in [
            "Phase 08 aggregate soak qualification contract v2 is valid.",
            "cumulative qualifying duration is exactly 259200 seconds",
            "864 durable 300-second samples",
            "resumes from its last validated checkpoint instead of sequence zero",
            "predecessor-hashed",
            "physical host",
            "Gaps and partial samples never count",
            "no other Hostwright-managed runtime",
            "writable internal non-removable storage",
            "timestamp-bound real sleep then wake",
            "never forces either transition",
            "confirmation-bound owned-only cleanup",
            "No CI, GitHub"
        ] {
            XCTAssertTrue(text.contains(fragment), "Missing soak contract: \(fragment)")
        }
        for fragment in [
            "readonly duration_seconds=259200",
            "readonly sample_interval_seconds=300",
            "expected_samples=864",
            "compaction_attempt_limit=5",
            "power_evidence_version=1",
            "qualification_schema_version=2",
            "checkpoint_schema_version=1",
            "resource_uuid_pattern=",
            "resource_identifier_pattern=",
            "phase08-gate16-soak-",
            "active-run-v2",
            "checkpoints-v1",
            "segments-v1.tsv",
            "samples-v2.tsv",
            "commit_checkpoint",
            "validate_checkpoint_chain",
            "run_checkpointed_fault",
            "resume)",
            "status)",
            "progressPercent=",
            "preflight)",
            "source_digest",
            "current_host_identity",
            "HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT",
            ".configuration.descriptor.digest",
            "require_internal_persistent_path",
            "RemovableMediaOrExternalDevice",
            "find_sleep_wake_pair",
            "powerEvidenceVersion",
            "metrics snapshot",
            "traces inspect",
            "diagnostics support preview",
            "state compact",
            "compaction-stale-plan",
            "compaction-daemon-quiesce-requested",
            "compaction-daemon-quiesced",
            "compaction-daemon-resumed",
            "runner-exit-classified",
            "verify_exclusive_runtime_inventory",
            "runtimeInventorySHA256",
            "RuntimeQualificationRecoveryDriverTests",
            "RuntimeQualificationProcessControlTests",
            "container stop",
            "--interval 4 --jitter 1",
            "final-rm-plan.json",
            "evidence-v2.sha256",
            "next_sample=$((last_sample_epoch + sample_interval_seconds))"
        ] {
            XCTAssertTrue(script.contains(fragment), "Missing soak behavior: \(fragment)")
        }
        XCTAssertFalse(script.contains("duration_seconds=${"))
        XCTAssertFalse(script.contains("sample_interval_seconds=${"))
        XCTAssertFalse(script.contains("pmset_count"))
        XCTAssertFalse(script.contains("rm -rf"))
        XCTAssertFalse(script.contains("sleepnow"))
        XCTAssertFalse(script.contains("container system stop"))
        XCTAssertFalse(script.contains("launchctl"))
        XCTAssertFalse(script.contains("/sbin/reboot"))
        XCTAssertFalse(script.contains("/sbin/shutdown"))
        XCTAssertFalse(script.contains("gh "))
    }

    func testAggregateSoakRefusesExternalOrRemovableStorage() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let path = FileManager.default.temporaryDirectory.path
        let internalStorage = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Internal</key><true/>
        <key>RemovableMediaOrExternalDevice</key><false/>
        <key>WritableVolume</key><true/>
        <key>MountPoint</key><string>/System/Volumes/Data</string>
        </dict></plist>
        """#
        let externalStorage = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Internal</key><false/>
        <key>RemovableMediaOrExternalDevice</key><true/>
        <key>WritableVolume</key><true/>
        <key>MountPoint</key><string>/Volumes/T9</string>
        </dict></plist>
        """#
        let source = #"""
        source "$1"
        storage_properties() { printf '%s' "$HOSTWRIGHT_TEST_STORAGE_PLIST"; }
        require_internal_persistent_path "$2" 'The test path'
        """#

        let internalResult = try runBash(
            source,
            arguments: [scriptURL.path, path],
            environment: ["HOSTWRIGHT_TEST_STORAGE_PLIST": internalStorage]
        )
        XCTAssertEqual(internalResult.status, 0, internalResult.output)

        let externalResult = try runBash(
            source,
            arguments: [scriptURL.path, path],
            environment: ["HOSTWRIGHT_TEST_STORAGE_PLIST": externalStorage]
        )
        XCTAssertEqual(externalResult.status, 77, externalResult.output)
        XCTAssertTrue(
            externalResult.output.contains("writable internal non-removable storage")
        )
    }

    func testAggregateSoakRequiresOrderedInWindowSleepWakePair() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let source = #"""
        source "$1"
        start_epoch="$(LC_ALL=C /bin/date -j -f '%Y-%m-%d %H:%M:%S %z' "$HOSTWRIGHT_TEST_START" '+%s')"
        end_epoch="$(LC_ALL=C /bin/date -j -f '%Y-%m-%d %H:%M:%S %z' "$HOSTWRIGHT_TEST_END" '+%s')"
        printf '%s\n' "$HOSTWRIGHT_TEST_PMSET_LOG" | find_sleep_wake_pair "$start_epoch" "$end_epoch"
        """#
        let environment = [
            "HOSTWRIGHT_TEST_START": "2026-08-03 07:30:00 -0400",
            "HOSTWRIGHT_TEST_END": "2026-08-03 09:30:00 -0400"
        ]
        let validLog = """
        2026-08-02 03:00:00 -0400 Sleep               \tEntering Sleep state due to 'Idle Sleep'
        2026-08-02 03:10:00 -0400 Wake                \tWake from Normal Sleep
        2026-08-03 07:33:23 -0400 Sleep               \tEntering Sleep state due to 'Low Power Sleep':TCPKeepAlive=active Using Batt (Charge:1%)
        2026-08-03 08:00:00 -0400 DarkWake            \tDarkWake from Deep Idle [CDNP]
        2026-08-03 09:11:19 -0400 Wake                \tWake from Hibernate [CDNVA] : due to EC.LidOpen/UserActivity Using AC (Charge:3%)
        """
        let validResult = try runBash(
            source,
            arguments: [scriptURL.path],
            environment: environment.merging(["HOSTWRIGHT_TEST_PMSET_LOG": validLog]) {
                _, value in value
            }
        )
        XCTAssertEqual(validResult.status, 0, validResult.output)
        XCTAssertEqual(
            validResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\t").count,
            2
        )

        let rejectedLogs = [
            """
            2026-08-03 07:40:00 -0400 Wake                \tWake from Hibernate
            2026-08-03 08:00:00 -0400 Sleep               \tEntering Sleep state due to 'Low Power Sleep'
            """,
            """
            2026-08-03 08:00:00 -0400 Sleep               \tEntering Sleep state due to 'Low Power Sleep'
            2026-08-03 08:10:00 -0400 DarkWake            \tDarkWake from Deep Idle [CDNP]
            """,
            """
            2026-08-03 07:00:00 -0400 Sleep               \tEntering Sleep state due to 'Idle Sleep'
            2026-08-03 07:10:00 -0400 Wake                \tWake from Normal Sleep
            2026-08-03 09:40:00 -0400 Sleep               \tEntering Sleep state due to 'Idle Sleep'
            2026-08-03 09:50:00 -0400 Wake                \tWake from Normal Sleep
            """
        ]
        for log in rejectedLogs {
            let result = try runBash(
                source,
                arguments: [scriptURL.path],
                environment: environment.merging(["HOSTWRIGHT_TEST_PMSET_LOG": log]) {
                    _, value in value
                }
            )
            XCTAssertEqual(result.status, 1, result.output)
        }
    }

    func testAggregateSoakSleepWakeProofCannotCrossCheckpointedSegments() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-power-segments-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let second = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let firstStart = try epoch("2026-08-03 07:30:00 -0400")
        let firstCheckpoint = try epoch("2026-08-03 08:00:00 -0400")
        let secondStart = try epoch("2026-08-03 09:00:00 -0400")
        let secondCheckpoint = try epoch("2026-08-03 09:30:00 -0400")
        let source = #"""
        source "$1"
        segment_file="$2/segments-v1.tsv"
        sample_file="$2/samples-v2.tsv"
        printf 'segmentID\tevent\tepoch\tsequence\tqualifiedSeconds\tcheckpointSHA256\tdetail1\tdetail2\n' > "$segment_file"
        printf '%s\tstart\t%s\t0\t0\t%s\tgapSeconds=0\tsourceCommit=x\n' "$3" "$5" "$genesis_checkpoint_sha256" >> "$segment_file"
        printf '%s\tstart\t%s\t1\t300\t%s\tgapSeconds=3600\tsourceCommit=x\n' "$4" "$7" "$genesis_checkpoint_sha256" >> "$segment_file"
        printf '%b\n' "$checkpoint_header" > "$sample_file"
        printf '1\tq\t%s\t1\t%s\n' "$3" "$6" >> "$sample_file"
        printf '2\tq\t%s\t1\t%s\n' "$4" "$8" >> "$sample_file"
        printf '%s\n' "$HOSTWRIGHT_TEST_PMSET_LOG" | {
          temporary_log="$2/pmset.log"
          cat > "$temporary_log"
          find_qualified_sleep_wake_pair "$temporary_log"
        }
        """#
        let arguments = [
            scriptURL.path,
            root.path,
            first,
            second,
            String(firstStart),
            String(firstCheckpoint),
            String(secondStart),
            String(secondCheckpoint)
        ]
        let crossing = """
        2026-08-03 07:50:00 -0400 Sleep               \tEntering Sleep state due to 'Idle Sleep'
        2026-08-03 09:10:00 -0400 Wake                \tWake from Normal Sleep
        """
        let crossingResult = try runBash(
            source,
            arguments: arguments,
            environment: ["HOSTWRIGHT_TEST_PMSET_LOG": crossing]
        )
        XCTAssertEqual(crossingResult.status, 1, crossingResult.output)

        let valid = """
        2026-08-03 09:05:00 -0400 Sleep               \tEntering Sleep state due to 'Idle Sleep'
        2026-08-03 09:15:00 -0400 Wake                \tWake from Normal Sleep
        """
        let validResult = try runBash(
            source,
            arguments: arguments,
            environment: ["HOSTWRIGHT_TEST_PMSET_LOG": valid]
        )
        XCTAssertEqual(validResult.status, 0, validResult.output)
    }

    func testAggregateSoakRetriesFreshCompactionPlansOnlyForStaleConfirmation() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-compaction-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = root.appendingPathComponent("counter")
        let fakeHostwright = root.appendingPathComponent("hostwright")
        try Data("0\n".utf8).write(to: counter)
        try Data(
            #"""
            #!/usr/bin/env bash
            set -euo pipefail
            dry_run=false
            token=''
            while [[ "$#" -gt 0 ]]; do
              case "$1" in
                --dry-run) dry_run=true ;;
                --confirm-compact) shift; token="$1" ;;
              esac
              shift
            done
            if [[ "$dry_run" == true ]]; then
              attempt="$(( $(<"$HOSTWRIGHT_TEST_COUNTER") + 1 ))"
              printf '%s\n' "$attempt" > "$HOSTWRIGHT_TEST_COUNTER"
              printf '{"executable":true,"confirmationToken":"token-%s"}\n' "$attempt"
              exit 0
            fi
            case "$token" in
              token-1|token-2)
                printf '{"code":"HW-CLI-003","exitCode":70,"kind":"error"}\n' >&2
                exit 70
                ;;
              token-3)
                printf '{"integrityHealth":"healthy"}\n'
                exit 0
                ;;
              *) exit 64 ;;
            esac
            """#.utf8
        ).write(to: fakeHostwright)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeHostwright.path
        )

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT="$3"
            evidence_file="$2/evidence-v1.log"
            daemon_pid='daemon-before'
            stop_daemon() {
              printf 'stop\n' >> "$HOSTWRIGHT_TEST_LIFECYCLE"
              daemon_pid=''
            }
            start_daemon() {
              printf 'start\n' >> "$HOSTWRIGHT_TEST_LIFECYCLE"
              daemon_pid='daemon-after'
            }
            verify_running() {
              [[ "$daemon_pid" == daemon-after ]]
            }
            : > "$evidence_file"
            compact_state 12
            """#,
            arguments: [scriptURL.path, root.path, fakeHostwright.path],
            environment: [
                "HOSTWRIGHT_TEST_COUNTER": counter.path,
                "HOSTWRIGHT_TEST_LIFECYCLE": root.appendingPathComponent("lifecycle").path
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8), "3\n")
        let evidence = try String(
            contentsOf: root.appendingPathComponent("evidence-v1.log"),
            encoding: .utf8
        )
        XCTAssertTrue(evidence.contains("compaction-stale-plan sequence=12 attempt=1"))
        XCTAssertTrue(evidence.contains("compaction-stale-plan sequence=12 attempt=2"))
        XCTAssertTrue(evidence.contains("compaction-pass sequence=12 attempt=3"))
        for attempt in 1 ... 3 {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "compaction-12-attempt-\(attempt)-plan.json"
                    ).path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "compaction-12-attempt-\(attempt)-result.error"
                    ).path
                )
            )
        }
        let resultPayload = try String(
            contentsOf: root.appendingPathComponent(
                "compaction-12-attempt-3-result.json"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(resultPayload.contains(#""integrityHealth":"healthy""#))
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("lifecycle"), encoding: .utf8),
            "stop\nstart\n"
        )
    }

    func testAggregateSoakCompactionBoundsPersistentStalePlanChurnAndResumesDaemon() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-compaction-stale-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = root.appendingPathComponent("counter")
        let fakeHostwright = root.appendingPathComponent("hostwright")
        try Data("0\n".utf8).write(to: counter)
        try Data(
            #"""
            #!/usr/bin/env bash
            set -euo pipefail
            dry_run=false
            token=''
            while [[ "$#" -gt 0 ]]; do
              case "$1" in
                --dry-run) dry_run=true ;;
                --confirm-compact) shift; token="$1" ;;
              esac
              shift
            done
            if [[ "$dry_run" == true ]]; then
              attempt="$(( $(<"$HOSTWRIGHT_TEST_COUNTER") + 1 ))"
              printf '%s\n' "$attempt" > "$HOSTWRIGHT_TEST_COUNTER"
              printf '{"executable":true,"confirmationToken":"token-%s"}\n' "$attempt"
              exit 0
            fi
            printf '{"code":"HW-CLI-003","exitCode":70,"kind":"error"}\n' >&2
            exit 70
            """#.utf8
        ).write(to: fakeHostwright)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeHostwright.path
        )

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT="$3"
            evidence_file="$2/evidence-v1.log"
            daemon_pid='daemon-before'
            stop_daemon() {
              printf 'stop\n' >> "$HOSTWRIGHT_TEST_LIFECYCLE"
              daemon_pid=''
            }
            start_daemon() {
              printf 'start\n' >> "$HOSTWRIGHT_TEST_LIFECYCLE"
              daemon_pid='daemon-after'
            }
            verify_running() {
              [[ "$daemon_pid" == daemon-after ]]
            }
            : > "$evidence_file"
            compact_state 24
            """#,
            arguments: [scriptURL.path, root.path, fakeHostwright.path],
            environment: [
                "HOSTWRIGHT_TEST_COUNTER": counter.path,
                "HOSTWRIGHT_TEST_LIFECYCLE": root.appendingPathComponent("lifecycle").path
            ]
        )

        XCTAssertEqual(result.status, 70, result.output)
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8), "5\n")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("lifecycle"), encoding: .utf8),
            "stop\nstart\n"
        )
        let evidence = try String(
            contentsOf: root.appendingPathComponent("evidence-v1.log"),
            encoding: .utf8
        )
        XCTAssertTrue(evidence.contains("compaction-daemon-quiesced sequence=24"))
        XCTAssertTrue(evidence.contains("compaction-daemon-resumed sequence=24"))
        XCTAssertTrue(evidence.contains("Soak compaction exhausted 5 fresh confirmation attempts"))
    }

    func testAggregateSoakCompactionRestoresDaemonAfterConfirmationFailure() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-compaction-cancel-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeHostwright = root.appendingPathComponent("hostwright")
        try Data(
            #"""
            #!/usr/bin/env bash
            set -euo pipefail
            dry_run=false
            while [[ "$#" -gt 0 ]]; do
              case "$1" in
                --dry-run) dry_run=true ;;
              esac
              shift
            done
            if [[ "$dry_run" == true ]]; then
              printf '{"executable":true,"confirmationToken":"token-cancel"}\n'
              exit 0
            fi
            printf '{"code":"HW-CLI-999","exitCode":75,"kind":"error"}\n' >&2
            exit 75
            """#.utf8
        ).write(to: fakeHostwright)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeHostwright.path
        )

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT="$3"
            evidence_file="$2/evidence-v1.log"
            daemon_pid='daemon-before'
            stop_daemon() {
              printf 'stop\n' >> "$HOSTWRIGHT_TEST_LIFECYCLE"
              daemon_pid=''
            }
            start_daemon() {
              printf 'start\n' >> "$HOSTWRIGHT_TEST_LIFECYCLE"
              daemon_pid='daemon-after'
            }
            verify_running() {
              [[ "$daemon_pid" == daemon-after ]]
            }
            : > "$evidence_file"
            compact_state 36
            """#,
            arguments: [scriptURL.path, root.path, fakeHostwright.path],
            environment: [
                "HOSTWRIGHT_TEST_LIFECYCLE": root.appendingPathComponent("lifecycle").path
            ]
        )

        XCTAssertEqual(result.status, 75, result.output)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("lifecycle"), encoding: .utf8),
            "stop\nstart\n"
        )
        let evidence = try String(
            contentsOf: root.appendingPathComponent("evidence-v1.log"),
            encoding: .utf8
        )
        XCTAssertTrue(evidence.contains("compaction-daemon-resumed sequence=36"))
        XCTAssertTrue(evidence.contains("confirmation failed at sequence 36 attempt 1"))
    }

    func testAggregateSoakUnexpectedExitDurablyMarksResumable() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-exit-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            state_file="$2/state-v1.tsv"
            evidence_file="$2/evidence-v1.log"
            daemon_pid=''
            printf 'phase\trunning\n' > "$state_file"
            : > "$evidence_file"
            trap runner_exit EXIT
            false
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 1)
        let state = try String(
            contentsOf: root.appendingPathComponent("state-v1.tsv"),
            encoding: .utf8
        )
        XCTAssertTrue(state.contains("phase\tresumable"))
        XCTAssertTrue(state.contains("runnerExitCode\t1"))
        XCTAssertTrue(
            try String(
                contentsOf: root.appendingPathComponent("evidence-v1.log"),
                encoding: .utf8
            ).contains("runner-exit-classified status=1")
        )
    }

    func testAggregateSoakReapsCleanlyExitedDaemonWithoutFalseTimeout() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-reap-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            state_file="$2/state-v2.tsv"
            evidence_file="$2/evidence-v2.log"
            printf 'schemaVersion\t2\n' > "$state_file"
            : > "$evidence_file"
            daemon_generation=1
            /bin/bash -c 'trap "exit 0" TERM; while :; do sleep 1; done' &
            daemon_pid=$!
            sleep 0.1
            stop_daemon
            printf 'reaped\n'
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("reaped"))
        XCTAssertTrue(
            try String(
                contentsOf: root.appendingPathComponent("evidence-v2.log"),
                encoding: .utf8
            ).contains("daemon-stopped generation=1")
        )
    }

    func testAggregateSoakRebuildsAndValidatesCumulativeCheckpointChain() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-checkpoints-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let setup = try runBash(
            checkpointFixtureSource(validate: true),
            arguments: [scriptURL.path, root.path]
        )
        XCTAssertEqual(setup.status, 0, setup.output)
        XCTAssertTrue(setup.output.contains("samples=2 seconds=600 rows=3"))
        XCTAssertTrue(setup.output.contains("readOnlyRows=1"))

        let partialRecovery = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            evidence_file="$2/evidence-v2.log"
            checkpoint_root="$2/checkpoints-v1"
            cumulative_samples=2
            printf 'partial\n' > "$2/checkpoints-v1/sequence-0003.tsv.next.999"
            printf 'partial\n' > "$2/fault-checkpoints-v1/sequence-0003-pressure.tsv.next.999"
            printf 'partial\n' > "$2/hostwright.yaml.next"
            dd if=/dev/zero of="$2/pressure-v1.bin" bs=1048576 count=64 >/dev/null 2>&1
            printf '{"sequence":3}\n' > "$2/runtime-inventory-v1/sequence-0003.json"
            recover_uncommitted_artifacts
            count="$(find "$2/recovered-partials-v1" -type f | wc -l | tr -d ' ')"
            printf 'preserved=%s\n' "$count"
            """#,
            arguments: [scriptURL.path, root.path]
        )
        XCTAssertEqual(partialRecovery.status, 0, partialRecovery.output)
        XCTAssertTrue(partialRecovery.output.contains("preserved=5"))

        try Data("tampered\n".utf8).write(
            to: root.appendingPathComponent("runtime-inventory-v1/sequence-0002.json")
        )
        let rejected = try runBash(
            checkpointFixtureSource(validate: false),
            arguments: [scriptURL.path, root.path]
        )
        XCTAssertEqual(rejected.status, 75, rejected.output)
        XCTAssertTrue(rejected.output.contains("runtime inventory hash changed"))
    }

    func testAggregateSoakReusesCompletedFaultReceiptExactlyOnce() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-fault-receipt-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            evidence_file="$2/evidence-v2.log"
            qualification_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            hostwright_sha='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            daemon_sha='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
            host_identity_sha='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
            resource_identifier='hostwright-v2-p08-soa-web-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            resource_uuid='cccccccc-cccc-8ccc-8ccc-cccccccccccc'
            project_name='p08-soak-test'
            previous_checkpoint_sha256="$genesis_checkpoint_sha256"
            mkdir "$2/fault-checkpoints-v1"
            : > "$evidence_file"
            printf 'fixture\n' > "$2/hostwright.yaml"
            printf '0\n' > "$2/counter"
            test_root="$2"
            perform_fault() {
              printf '%s\n' "$(( $(<"$test_root/counter") + 1 ))" > "$test_root/counter"
            }
            run_checkpointed_fault 72 pressure perform_fault
            run_checkpointed_fault 72 pressure perform_fault
            printf 'count=%s\n' "$(<"$2/counter")"
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("count=1"))
        XCTAssertTrue(
            try String(
                contentsOf: root.appendingPathComponent("evidence-v2.log"),
                encoding: .utf8
            ).contains("fault-receipt-reused sequence=72 label=pressure")
        )
    }

    func testAggregateSoakRecoversPowerLossMarkerWithoutLosingCheckpoints() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-stale-marker-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            state_file="$2/state-v2.tsv"
            evidence_file="$2/evidence-v2.log"
            segment_file="$2/segments-v1.tsv"
            active_run_root="$2/active-run-v2"
            cumulative_samples=2
            cumulative_seconds=600
            last_sample_epoch=1600
            previous_checkpoint_sha256='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            prior_segment='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
            printf 'phase\trunning\n' > "$state_file"
            : > "$evidence_file"
            printf 'segmentID\tevent\tepoch\tsequence\tqualifiedSeconds\tcheckpointSHA256\tdetail1\tdetail2\n' > "$segment_file"
            mkdir "$active_run_root"
            chmod 700 "$active_run_root"
            {
              printf 'schemaVersion\t1\n'
              printf 'pid\t999999\n'
              printf 'bootIdentity\t%s\n' "$(boot_identity)"
              printf 'segmentID\t%s\n' "$prior_segment"
              printf 'startEpoch\t1000\n'
              printf 'startSequence\t0\n'
              printf 'startCheckpointSHA256\t%s\n' "$genesis_checkpoint_sha256"
              printf 'gapSeconds\t0\n'
            } > "$active_run_root/owner-v1.tsv"
            chmod 600 "$active_run_root/owner-v1.tsv"
            recover_active_run_marker
            validate_segment_ledger
            [[ ! -e "$active_run_root" ]]
            printf 'rows=%s phase=%s samples=%s seconds=%s\n' \
              "$(wc -l < "$segment_file" | tr -d ' ')" \
              "$(latest_state_value phase)" "$cumulative_samples" "$cumulative_seconds"
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("rows=3 phase=resumable samples=2 seconds=600"))
    }

    func testAggregateSoakRefusesForeignManagedRuntimeInventory() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-inventory-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let exactID = "hostwright-v2-p08-soa-web-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let exactUUID = "646e5e79-7d1b-8bed-8bba-f18324262911"
        let image = "docker.io/library/python@sha256:\(String(repeating: "a", count: 64))"
        let exact = runtimeFixture(
            id: exactID,
            project: "p08-soak-test",
            resourceUUID: exactUUID,
            image: image
        )
        let foreign = runtimeFixture(
            id: "hostwright-v2-phase09-probe-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            project: "phase09-probe",
            resourceUUID: "746e5e79-7d1b-8bed-8bba-f18324262912",
            image: image
        )
        let inventory = "[\(exact),\(foreign)]"

        let exactResult = try runBash(
            #"""
            source "$1"
            resource_identifier="$HOSTWRIGHT_TEST_EXACT_ID"
            project_name='p08-soak-test'
            HOSTWRIGHT_PHASE08_SOAK_IMAGE="$HOSTWRIGHT_TEST_IMAGE"
            container() { printf '%s\n' "$HOSTWRIGHT_TEST_INVENTORY"; }
            verify_exclusive_runtime_inventory "$2/runtime-exact.json"
            printf '%s\n' "$resource_uuid"
            """#,
            arguments: [scriptURL.path, root.path],
            environment: [
                "HOSTWRIGHT_TEST_EXACT_ID": exactID,
                "HOSTWRIGHT_TEST_IMAGE": image,
                "HOSTWRIGHT_TEST_INVENTORY": "[\(exact)]"
            ]
        )
        XCTAssertEqual(exactResult.status, 0, exactResult.output)
        XCTAssertTrue(exactResult.output.contains(exactUUID))

        let result = try runBash(
            #"""
            source "$1"
            resource_identifier="$HOSTWRIGHT_TEST_EXACT_ID"
            project_name='p08-soak-test'
            HOSTWRIGHT_PHASE08_SOAK_IMAGE="$HOSTWRIGHT_TEST_IMAGE"
            container() { printf '%s\n' "$HOSTWRIGHT_TEST_INVENTORY"; }
            verify_exclusive_runtime_inventory "$2/runtime-foreign.json"
            """#,
            arguments: [scriptURL.path, root.path],
            environment: [
                "HOSTWRIGHT_TEST_EXACT_ID": exactID,
                "HOSTWRIGHT_TEST_IMAGE": image,
                "HOSTWRIGHT_TEST_INVENTORY": inventory
            ]
        )

        XCTAssertEqual(result.status, 75)
        XCTAssertTrue(result.output.contains("foreign, ambiguous, or changed"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("runtime-foreign.json").path
            )
        )
    }

    private func runtimeFixture(
        id: String,
        project: String,
        resourceUUID: String,
        image: String
    ) -> String {
        """
        {
          "id":"\(id)",
          "configuration":{
            "id":"\(id)",
            "image":{"reference":"\(image)"},
            "labels":{
              "dev.hostwright.managed":"true",
              "dev.hostwright.identity-version":"2",
              "dev.hostwright.provider-id":"apple-container-cli",
              "dev.hostwright.project":"\(project)",
              "dev.hostwright.resource-id":"\(id)",
              "dev.hostwright.resource-uuid":"\(resourceUUID)"
            }
          },
          "status":{"state":"running"}
        }
        """
    }

    private func checkpointFixtureSource(validate: Bool) -> String {
        let setup = #"""
        source "$1"
        HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
        HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        state_file="$2/state-v2.tsv"
        evidence_file="$2/evidence-v2.log"
        sample_file="$2/samples-v2.tsv"
        checkpoint_root="$2/checkpoints-v1"
        segment_file="$2/segments-v1.tsv"
        qualification_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        segment_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        project_name='p08-soak-test'
        resource_identifier='hostwright-v2-p08-soa-web-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        resource_uuid='cccccccc-cccc-8ccc-8ccc-cccccccccccc'
        hostwright_sha='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        daemon_sha='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
        template_sha='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
        host_identity_sha='9999999999999999999999999999999999999999999999999999999999999999'
        previous_checkpoint_sha256="$genesis_checkpoint_sha256"
        mkdir -p "$checkpoint_root" "$2/runtime-inventory-v1" "$2/fault-checkpoints-v1"
        : > "$evidence_file"
        printf 'schemaVersion\t2\n' > "$state_file"
        printf 'segmentID\tevent\tepoch\tsequence\tqualifiedSeconds\tcheckpointSHA256\tdetail1\tdetail2\n' > "$segment_file"
        printf '%s\tstart\t1000\t0\t0\t%s\tgapSeconds=0\tsourceCommit=%s\n' \
          "$segment_id" "$genesis_checkpoint_sha256" "$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT" >> "$segment_file"
        printf '%b\n' "$checkpoint_header" > "$sample_file"
        if [[ ! -e "$checkpoint_root/sequence-0001.tsv" ]]; then
          for sequence in 1 2; do
            printf '{"sequence":%s}\n' "$sequence" > "$2/runtime-inventory-v1/sequence-$(printf '%04d' "$sequence").json"
            chmod 600 "$2/runtime-inventory-v1/sequence-$(printf '%04d' "$sequence").json"
            inventory_sha="$(sha256 "$2/runtime-inventory-v1/sequence-$(printf '%04d' "$sequence").json")"
            printf -v material '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
              "$sequence" "$qualification_id" "$segment_id" "$sequence" "$((1000 + sequence * 300))" "$((sequence * 300))" \
              123 1024 12 4096 10 0 20 2 0 1 "$inventory_sha" \
              eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
              ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
              "$resource_identifier" "$resource_uuid" "$project_name" "$hostwright_sha" \
              "$daemon_sha" "$template_sha" "$host_identity_sha" \
              "$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT" \
              "$previous_checkpoint_sha256"
            commit_checkpoint "$sequence" "$material"
          done
          printf '%b\n' "$checkpoint_header" > "$sample_file"
        fi
        """#
        if validate {
            return setup + "\n" + #"""
            validate_checkpoint_chain read-only
            printf 'readOnlyRows=%s\n' "$(wc -l < "$sample_file" | tr -d ' ')"
            validate_checkpoint_chain
            printf 'samples=%s seconds=%s rows=%s\n' \
              "$cumulative_samples" "$cumulative_seconds" "$(wc -l < "$sample_file" | tr -d ' ')"
            """#
        }
        return setup + "\n" + #"""
        validate_checkpoint_chain
        """#
    }

    private func runBash(
        _ source: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", source, "phase08-soak-test"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) {
            _, value in value
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    private func epoch(_ timestamp: String) throws -> Int {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        guard let date = formatter.date(from: timestamp) else {
            throw NSError(domain: "MutationCheckpointQualificationScriptTests", code: 1)
        }
        return Int(date.timeIntervalSince1970)
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
