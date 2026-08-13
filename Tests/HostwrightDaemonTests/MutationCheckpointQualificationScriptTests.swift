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
            "workload_recovery_attempt_limit=72",
            "workload_recovery_sleep_seconds=5",
            "workload_recovery_release_generation_limit=2",
            "running_status_failure_limit=3",
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
            "sqlite_query_with_retry",
            "PRAGMA busy_timeout=5000",
            "result=\"$(printf '%s\\n' \"$output\" | tail -n 1)\"",
            "returned no result",
            "oslog_count_with_retry",
            "no persisted Hostwright records after retries",
            "daemon_observation_with_retry",
            "foreground process identity",
            "run_checkpointed_fault",
            "resume)",
            "status)",
            "progressPercent=",
            "preflight)",
            "source_digest",
            "current_host_identity",
            "HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT",
            "append_state hostwrightSHA256",
            "append_state daemonSHA256",
            ".configuration.descriptor.digest",
            "require_internal_persistent_path",
            "RemovableMediaOrExternalDevice",
            "find_sleep_wake_pair",
            "powerEvidenceVersion",
            "metrics snapshot",
            "traces inspect",
            "diagnostics support preview",
            "state compact",
            "--evaluated-at",
            ".evaluatedAt",
            "compaction-stale-plan",
            "compaction-daemon-quiesce-requested",
            "compaction-daemon-quiesced",
            "compaction-daemon-resumed",
            "daemon-stop-reap-escalated",
            "runner-exit-classified",
            "verify_exclusive_runtime_inventory",
            "runtimeInventorySHA256",
            "RuntimeQualificationRecoveryDriverTests",
            "RuntimeQualificationProcessControlTests",
            "container stop",
            "restart-budget release",
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

    func testAggregateSoakReleasesOnlyExactExpectedWorkloadHoldOnce() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-workload-hold-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeHostwright = root.appendingPathComponent("hostwright")
        try Data(
            #"""
            #!/usr/bin/env bash
            set -euo pipefail
            case "$1" in
              status)
                if [[ -f "$HOSTWRIGHT_TEST_RELEASED" ]]; then
                  printf '%s\n' '{"actions":[],"services":[{"observed":{"lifecycle":"running","resourceIdentifier":"hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834"}}]}'
                else
                  printf '%s\n' '{"actions":[{"executionAvailability":"unavailable","kind":"proposeStartStoppedService","reason":"Observed service is not running; crash-loop protection blocks managed start after 3/3 attempts.","resourceIdentifier":"hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834"}],"services":[{"observed":{"lifecycle":"exited","resourceIdentifier":"hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834"}}]}'
                fi
                ;;
              restart-budget)
                case "$2" in
                  status)
                    /usr/bin/jq -cn --arg db "$HOSTWRIGHT_TEST_ROOT/state.sqlite" '{released:false,restartBudgets:[{attemptCount:3,holdToken:"8fa82fd543ce2f58953212a98758568f1d4aa95732fd092ee5dbf103989de986",maxAttempts:3,projectAttemptCount:0,projectID:"project-p08-soak-d785738e",projectMaxAttempts:10,reasonClass:"process-exit",releaseGeneration:0,serviceName:"web",status:"crashLoopBlocked"}],schemaVersion:1,stateDatabasePath:$db}'
                    ;;
                  release)
                    [[ " $* " == *" --project project-p08-soak-d785738e "* ]]
                    [[ " $* " == *" --service web "* ]]
                    [[ " $* " == *" --confirm-hold 8fa82fd543ce2f58953212a98758568f1d4aa95732fd092ee5dbf103989de986 "* ]]
                    [[ ! -e "$HOSTWRIGHT_TEST_RELEASED" ]]
                    printf 'release\n' >> "$HOSTWRIGHT_TEST_LIFECYCLE"
                    : > "$HOSTWRIGHT_TEST_RELEASED"
                    /usr/bin/jq -cn --arg db "$HOSTWRIGHT_TEST_ROOT/state.sqlite" '{released:true,restartBudgets:[{attemptCount:0,maxAttempts:3,projectAttemptCount:0,projectID:"project-p08-soak-d785738e",projectMaxAttempts:10,reasonClass:"operator-request",releaseGeneration:1,serviceName:"web",status:"active"}],schemaVersion:1,stateDatabasePath:$db}'
                    ;;
                  *) exit 64 ;;
                esac
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
            evidence_file="$2/evidence-v2.log"
            : > "$evidence_file"
            : > "$2/state.sqlite"
            resource_identifier='hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834'
            resource_uuid='5a2ecf85-5730-82c6-ba84-8693f4df0a1d'
            project_name='p08-soak-d785738e'
            daemon_pid=''
            container() {
              [[ "$1" == stop && "$2" == "$resource_identifier" ]]
              printf 'stop\n' >> "$HOSTWRIGHT_TEST_LIFECYCLE"
            }
            verify_exclusive_runtime_inventory() { :; }
            sleep() { :; }
            inject_workload_fault 648
            """#,
            arguments: [scriptURL.path, root.path, fakeHostwright.path],
            environment: [
                "HOSTWRIGHT_TEST_LIFECYCLE": root.appendingPathComponent("lifecycle").path,
                "HOSTWRIGHT_TEST_RELEASED": root.appendingPathComponent("released").path,
                "HOSTWRIGHT_TEST_ROOT": root.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("lifecycle"), encoding: .utf8),
            "stop\nrelease\n"
        )
        let evidence = try String(
            contentsOf: root.appendingPathComponent("evidence-v2.log"),
            encoding: .utf8
        )
        XCTAssertTrue(
            evidence.contains(
                "workload-restart-hold-release-consumed sequence=648 project=project-p08-soak-d785738e service=web"
            )
        )
        XCTAssertTrue(
            evidence.contains(
                "workload-restart-hold-released sequence=648 project=project-p08-soak-d785738e service=web releaseGeneration=1"
            )
        )
        XCTAssertTrue(
            evidence.contains(
                "workload-recovered resource=hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834"
            )
        )
    }

    func testAggregateSoakRecognizesOnlyAnUnrecoveredWorkloadFaultForResume() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-pending-workload-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            evidence_file="$2/evidence-v2.log"
            resource_identifier='hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834'
            printf '%s\n' \
              $'2026-08-10T23:11:07Z\tworkload-stop-injected resource=hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834' \
              $'2026-08-10T23:11:16Z\tworkload-recovered resource=hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834' \
              $'2026-08-11T08:54:57Z\tworkload-stop-injected resource=hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834' \
              $'2026-08-11T08:58:32Z\tfailure\tThe exact soak workload did not converge to running within three minutes.' \
              > "$evidence_file"
            has_pending_expected_workload_fault 648
            printf '%s\n' $'2026-08-11T09:00:00Z\tfailure\tThe exact soak workload status could not be read during running verification.' \
              >> "$evidence_file"
            if has_pending_expected_workload_fault 648; then
              exit 75
            fi
            printf '%s\n' $'2026-08-11T09:01:00Z\tfailure\tThe exact soak workload did not converge during its bounded intentional-fault recovery window.' \
              >> "$evidence_file"
            has_pending_expected_workload_fault 648
            printf '%s\n' $'2026-08-11T09:02:00Z\tfailure\tA later unrelated harness failure.' \
              $'2026-08-11T09:02:01Z\tworkload-resume-recovery-ready sequence=648 resource=hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834' \
              >> "$evidence_file"
            has_pending_expected_workload_fault 648
            printf '%s\n' $'2026-08-11T09:05:00Z\tworkload-recovered resource=hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834' \
              >> "$evidence_file"
            if has_pending_expected_workload_fault 648; then
              exit 75
            fi
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testAggregateSoakDerivesPendingWorkloadSequenceAfterCheckpointValidation() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-pending-workload-sequence-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT='/usr/bin/true'
            project_name='p08-soak-test'
            last_config_sha256='fixture-config'
            test_root="$2"
            validate_root() { :; }
            configure_authority_paths() { :; }
            load_qualification_state() { cumulative_samples=0; }
            latest_state_value() {
              [[ "$1" == phase ]]
              printf 'resumable\n'
            }
            validate_checkpoint_chain() {
              cumulative_samples=719
              cumulative_seconds=215700
              previous_checkpoint_sha256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            }
            has_pending_expected_workload_fault() {
              printf '%s\n' "$1" > "$test_root/pending-sequence"
              return 0
            }
            recover_uncommitted_artifacts() { :; }
            write_manifest() { :; }
            sha256() { printf 'fixture-config\n'; }
            validate_inputs() { :; }
            commit_source_transition() { :; }
            record() { :; }
            : > "$2/hostwright.yaml"
            prepare_resume
            [[ "$(<"$2/pending-sequence")" == 720 ]]
            [[ "$resume_expected_workload_fault" == 1 ]]
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testAggregateSoakDoesNotReleaseASecondHoldAfterInterruptedRecovery() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-consumed-hold-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeHostwright = root.appendingPathComponent("hostwright")
        try Data(
            #"""
            #!/usr/bin/env bash
            set -euo pipefail
            case "$1" in
              status)
                printf '%s\n' '{"actions":[{"executionAvailability":"unavailable","kind":"proposeStartStoppedService","reason":"Observed service is not running; crash-loop protection blocks managed start after 3/3 attempts.","resourceIdentifier":"hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834"}],"services":[{"observed":{"lifecycle":"exited","resourceIdentifier":"hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834"}}]}'
                ;;
              restart-budget)
                case "$2" in
                  status)
                    /usr/bin/jq -cn --arg db "$HOSTWRIGHT_TEST_ROOT/state.sqlite" '{released:false,restartBudgets:[{attemptCount:3,holdToken:"8fa82fd543ce2f58953212a98758568f1d4aa95732fd092ee5dbf103989de986",maxAttempts:3,projectAttemptCount:0,projectID:"project-p08-soak-d785738e",projectMaxAttempts:10,reasonClass:"process-exit",releaseGeneration:0,serviceName:"web",status:"crashLoopBlocked"}],schemaVersion:1,stateDatabasePath:$db}'
                    ;;
                  release)
                    printf 'unexpected restart-budget release\n' >> "$HOSTWRIGHT_TEST_LIFECYCLE"
                    exit 75
                    ;;
                  *) exit 64 ;;
                esac
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
            evidence_file="$2/evidence-v2.log"
            resource_identifier='hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834'
            resource_uuid='5a2ecf85-5730-82c6-ba84-8693f4df0a1d'
            project_name='p08-soak-d785738e'
            daemon_pid=''
            printf '%s\n' \
              $'2026-08-11T09:00:00Z\tworkload-stop-injected resource=hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834 sequence=648' \
              $'2026-08-11T09:03:15Z\tworkload-restart-hold-release-consumed sequence=648 project=project-p08-soak-d785738e service=web holdTokenSHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa releaseGeneration=1' \
              $'2026-08-11T09:06:00Z\tfailure\tThe exact soak workload did not converge during its bounded intentional-fault recovery window.' \
              > "$evidence_file"
            sleep() { :; }
            verify_running workload-fault 648
            """#,
            arguments: [scriptURL.path, root.path, fakeHostwright.path],
            environment: [
                "HOSTWRIGHT_TEST_LIFECYCLE": root.appendingPathComponent("lifecycle").path,
                "HOSTWRIGHT_TEST_ROOT": root.path
            ]
        )

        XCTAssertEqual(result.status, 75, result.output)
        XCTAssertTrue(result.output.contains("already consumed its one release"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("lifecycle").path
            )
        )
    }

    func testAggregateSoakReleasesOneNewHoldGenerationDuringResumedRecovery() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-next-hold-generation-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeHostwright = root.appendingPathComponent("hostwright")
        try Data(
            #"""
            #!/usr/bin/env bash
            set -euo pipefail
            case "$1" in
              status)
                if [[ -f "$HOSTWRIGHT_TEST_RELEASED" ]]; then
                  printf '%s\n' '{"actions":[],"services":[{"observed":{"lifecycle":"running","resourceIdentifier":"hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834"}}]}'
                else
                  printf '%s\n' '{"actions":[{"executionAvailability":"unavailable","kind":"proposeStartStoppedService","reason":"Observed service is not running; crash-loop protection blocks managed start after 3/3 attempts.","resourceIdentifier":"hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834"}],"services":[{"observed":{"lifecycle":"exited","resourceIdentifier":"hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834"}}]}'
                fi
                ;;
              restart-budget)
                case "$2" in
                  status)
                    /usr/bin/jq -cn --arg db "$HOSTWRIGHT_TEST_ROOT/state.sqlite" '{released:false,restartBudgets:[{attemptCount:3,holdToken:"9fa82fd543ce2f58953212a98758568f1d4aa95732fd092ee5dbf103989de987",maxAttempts:3,projectAttemptCount:0,projectID:"project-p08-soak-d785738e",projectMaxAttempts:10,reasonClass:"process-exit",releaseGeneration:1,serviceName:"web",status:"crashLoopBlocked"}],schemaVersion:1,stateDatabasePath:$db}'
                    ;;
                  release)
                    [[ " $* " == *" --confirm-hold 9fa82fd543ce2f58953212a98758568f1d4aa95732fd092ee5dbf103989de987 "* ]]
                    [[ ! -e "$HOSTWRIGHT_TEST_RELEASED" ]]
                    printf 'release\n' > "$HOSTWRIGHT_TEST_LIFECYCLE"
                    : > "$HOSTWRIGHT_TEST_RELEASED"
                    /usr/bin/jq -cn --arg db "$HOSTWRIGHT_TEST_ROOT/state.sqlite" '{released:true,restartBudgets:[{attemptCount:0,maxAttempts:3,projectAttemptCount:0,projectID:"project-p08-soak-d785738e",projectMaxAttempts:10,reasonClass:"operator-request",releaseGeneration:2,serviceName:"web",status:"active"}],schemaVersion:1,stateDatabasePath:$db}'
                    ;;
                  *) exit 64 ;;
                esac
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
            evidence_file="$2/evidence-v2.log"
            resource_identifier='hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834'
            resource_uuid='5a2ecf85-5730-82c6-ba84-8693f4df0a1d'
            project_name='p08-soak-d785738e'
            daemon_pid=''
            printf '%s\n' \
              $'2026-08-13T04:21:01Z\tworkload-stop-injected resource=hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834 sequence=864' \
              $'2026-08-13T04:24:28Z\tworkload-restart-hold-release-consumed sequence=864 project=project-p08-soak-d785738e service=web holdTokenSHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa releaseGeneration=1' \
              $'2026-08-13T04:24:28Z\tworkload-restart-hold-released sequence=864 project=project-p08-soak-d785738e service=web releaseGeneration=1' \
              $'2026-08-13T04:28:16Z\tfailure\tThe exact soak workload did not converge during its bounded intentional-fault recovery window.' \
              > "$evidence_file"
            verify_exclusive_runtime_inventory() { :; }
            sleep() { :; }
            verify_running workload-fault 864
            grep -F 'workload-restart-hold-release-consumed sequence=864 project=project-p08-soak-d785738e service=web' "$evidence_file" \
              | grep -Fq 'releaseGeneration=2'
            grep -Fq 'workload-restart-hold-released sequence=864 project=project-p08-soak-d785738e service=web releaseGeneration=2' "$evidence_file"
            """#,
            arguments: [scriptURL.path, root.path, fakeHostwright.path],
            environment: [
                "HOSTWRIGHT_TEST_LIFECYCLE": root.appendingPathComponent("lifecycle").path,
                "HOSTWRIGHT_TEST_RELEASED": root.appendingPathComponent("released").path,
                "HOSTWRIGHT_TEST_ROOT": root.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("lifecycle"), encoding: .utf8),
            "release\n"
        )
    }

    func testAggregateSoakBoundsIntentionalWorkloadRecoveryPolling() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-workload-window-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeHostwright = root.appendingPathComponent("hostwright")
        try Data(
            #"""
            #!/usr/bin/env bash
            set -euo pipefail
            [[ "$1" == status ]]
            printf '%s\n' '{"actions":[],"services":[{"observed":{"lifecycle":"exited","resourceIdentifier":"hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834"}}]}'
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
            evidence_file="$2/evidence-v2.log"
            : > "$evidence_file"
            resource_identifier='hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834'
            daemon_pid=''
            sleep() { printf 'sleep\n' >> "$HOSTWRIGHT_TEST_SLEEPS"; }
            verify_running workload-fault 648
            """#,
            arguments: [scriptURL.path, root.path, fakeHostwright.path],
            environment: [
                "HOSTWRIGHT_TEST_SLEEPS": root.appendingPathComponent("sleeps").path
            ]
        )

        XCTAssertEqual(result.status, 70, result.output)
        XCTAssertTrue(
            result.output.contains(
                "did not converge during its bounded intentional-fault recovery window"
            )
        )
        let sleeps = try String(
            contentsOf: root.appendingPathComponent("sleeps"),
            encoding: .utf8
        ).split(separator: "\n")
        XCTAssertEqual(sleeps.count, 72)
    }

    func testAggregateSoakRecordsAndSecuresFaultCellFailure() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-fault-cell-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            evidence_file="$2/evidence-v2.log"
            : > "$evidence_file"
            swift() {
              printf 'focused failure\n'
              return 42
            }
            status=0
            run_fault_cell 'Selector.testFailure' 'focused-fault' || status=$?
            [[ "$status" == 42 ]]
            [[ "$(stat -f '%Lp' "$2/focused-fault.log")" == 600 ]]
            grep -Fqx 'focused failure' "$2/focused-fault.log"
            grep -Fq $'focused-fault-fail selector=Selector.testFailure status=42' "$evidence_file"
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
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
            evaluated_at=''
            while [[ "$#" -gt 0 ]]; do
              case "$1" in
                --dry-run) dry_run=true ;;
                --confirm-compact) shift; token="$1" ;;
                --evaluated-at) shift; evaluated_at="$1" ;;
              esac
              shift
            done
            if [[ "$dry_run" == true ]]; then
              attempt="$(( $(<"$HOSTWRIGHT_TEST_COUNTER") + 1 ))"
              printf '%s\n' "$attempt" > "$HOSTWRIGHT_TEST_COUNTER"
              printf '{"evaluatedAt":"2026-08-12T11:30:00Z","executable":true,"confirmationToken":"token-%s"}\n' "$attempt"
              exit 0
            fi
            [[ "$evaluated_at" == 2026-08-12T11:30:00Z ]] || exit 64
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
                        "compaction-12-segment-unbound-attempt-\(attempt)-plan.json"
                    ).path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "compaction-12-segment-unbound-attempt-\(attempt)-result.error"
                    ).path
                )
            )
        }
        let resultPayload = try String(
            contentsOf: root.appendingPathComponent(
                "compaction-12-segment-unbound-attempt-3-result.json"
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
            evaluated_at=''
            while [[ "$#" -gt 0 ]]; do
              case "$1" in
                --dry-run) dry_run=true ;;
                --confirm-compact) shift; token="$1" ;;
                --evaluated-at) shift; evaluated_at="$1" ;;
              esac
              shift
            done
            if [[ "$dry_run" == true ]]; then
              attempt="$(( $(<"$HOSTWRIGHT_TEST_COUNTER") + 1 ))"
              printf '%s\n' "$attempt" > "$HOSTWRIGHT_TEST_COUNTER"
              printf '{"evaluatedAt":"2026-08-12T11:30:00Z","executable":true,"confirmationToken":"token-%s"}\n' "$attempt"
              exit 0
            fi
            [[ "$evaluated_at" == 2026-08-12T11:30:00Z ]] || exit 64
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

    func testAggregateSoakCompactionRefusesToOverwriteSealedSegmentArtifact() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-compaction-sealed-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let sealedPlan = root.appendingPathComponent(
            "compaction-48-segment-unbound-attempt-1-plan.json"
        )
        try Data("sealed\n".utf8).write(to: sealedPlan)

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT="$2/unused-hostwright"
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
            compact_state 48
            """#,
            arguments: [scriptURL.path, root.path],
            environment: [
                "HOSTWRIGHT_TEST_LIFECYCLE": root.appendingPathComponent("lifecycle").path
            ]
        )

        XCTAssertEqual(result.status, 75, result.output)
        XCTAssertEqual(try String(contentsOf: sealedPlan, encoding: .utf8), "sealed\n")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("lifecycle"), encoding: .utf8),
            "stop\nstart\n"
        )
        let evidence = try String(
            contentsOf: root.appendingPathComponent("evidence-v1.log"),
            encoding: .utf8
        )
        XCTAssertTrue(evidence.contains("compaction-daemon-resumed sequence=48"))
        XCTAssertTrue(evidence.contains("A sealed compaction artifact already exists"))
    }

    func testAggregateSoakSourceTransitionRebindsExecutableHashes() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-source-transition-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("new-hostwright\n".utf8).write(
            to: root.appendingPathComponent("hostwright")
        )
        try Data("new-daemon\n".utf8).write(
            to: root.appendingPathComponent("hostwrightd")
        )

        let result = try runBash(
            #"""
            source "$1"
            state_file="$2/state-v2.tsv"
            evidence_file="$2/evidence-v2.log"
            : > "$state_file"
            : > "$evidence_file"
            HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT="$2/hostwright"
            HOSTWRIGHT_PHASE08_SOAK_DAEMON="$2/hostwrightd"
            HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            checkpoint_source_commit='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            source_commit_history="$checkpoint_source_commit"
            source_transition_required=1
            hostwright_sha='old-hostwright'
            daemon_sha='old-daemon'
            validate_source_transition() { :; }
            source_digest() { printf '%s\n' 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'; }
            commit_source_transition
            printf '%s\n%s\n%s\n' "$source_sha" "$hostwright_sha" "$daemon_sha"
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        let values = result.output.split(separator: "\n").map(String.init)
        XCTAssertEqual(values.count, 3, result.output)
        XCTAssertEqual(values[0], String(repeating: "c", count: 64))
        XCTAssertNotEqual(values[1], "old-hostwright")
        XCTAssertNotEqual(values[2], "old-daemon")
        let state = try String(
            contentsOf: root.appendingPathComponent("state-v2.tsv"),
            encoding: .utf8
        )
        XCTAssertTrue(state.contains("sourceCommit\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n"))
        XCTAssertTrue(state.contains("sourceDigest\t\(values[0])\n"))
        XCTAssertTrue(state.contains("hostwrightSHA256\t\(values[1])\n"))
        XCTAssertTrue(state.contains("daemonSHA256\t\(values[2])\n"))
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
            evaluated_at=''
            while [[ "$#" -gt 0 ]]; do
              case "$1" in
                --dry-run) dry_run=true ;;
                --evaluated-at) shift; evaluated_at="$1" ;;
              esac
              shift
            done
            if [[ "$dry_run" == true ]]; then
              printf '{"evaluatedAt":"2026-08-12T11:30:00Z","executable":true,"confirmationToken":"token-cancel"}\n'
              exit 0
            fi
            [[ "$evaluated_at" == 2026-08-12T11:30:00Z ]] || exit 64
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

    func testAggregateSoakReapsLingeringDaemonAfterLoggedCleanShutdown() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-lingering-reap-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            state_file="$2/state-v2.tsv"
            evidence_file="$2/evidence-v2.log"
            lifecycle="$2/lifecycle.log"
            printf 'schemaVersion\t2\n' > "$state_file"
            : > "$evidence_file"
            : > "$lifecycle"
            daemon_generation=61
            daemon_pid=424242
            daemon_mock_running=true
            printf '%s\n' \
              'hostwrightd foreground-dev loop stopped' \
              'Iterations: 192' \
              'Successful: 183' \
              'Failed: 9' \
              'Shutdown requested: true' \
              > "$2/daemon-61.log"
            daemon_process_running() {
              [[ "$daemon_mock_running" == true ]]
            }
            kill() {
              case "$1" in
                -0) return 0 ;;
                -TERM) printf 'TERM\n' >> "$lifecycle" ;;
                -KILL)
                  printf 'KILL\n' >> "$lifecycle"
                  daemon_mock_running=false
                  ;;
                *) return 64 ;;
              esac
            }
            sleep() { :; }
            wait() {
              printf 'WAIT\n' >> "$lifecycle"
              return 137
            }
            stop_daemon
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("lifecycle.log"), encoding: .utf8),
            "TERM\nKILL\nWAIT\n"
        )
        let evidence = try String(
            contentsOf: root.appendingPathComponent("evidence-v2.log"),
            encoding: .utf8
        )
        XCTAssertTrue(
            evidence.contains(
                "daemon-stop-reap-escalated generation=61 pid=424242 signal=KILL reason=clean-loop-stop"
            )
        )
        XCTAssertTrue(evidence.contains("daemon-stopped generation=61 pid=424242"))
    }

    func testAggregateSoakWaitsForDelayedCleanShutdownProofBeforeEscalating() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-delayed-proof-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            state_file="$2/state-v2.tsv"
            evidence_file="$2/evidence-v2.log"
            lifecycle="$2/lifecycle.log"
            printf 'schemaVersion\t2\n' > "$state_file"
            : > "$evidence_file"
            : > "$lifecycle"
            daemon_generation=63
            daemon_pid=444444
            daemon_mock_running=true
            sleep_count=0
            daemon_log="$2/daemon-63.log"
            printf '%s\n' 'hostwrightd foreground-dev loop stopped' > "$daemon_log"
            daemon_process_running() {
              [[ "$daemon_mock_running" == true ]]
            }
            kill() {
              case "$1" in
                -0) return 0 ;;
                -TERM) printf 'TERM\n' >> "$lifecycle" ;;
                -KILL)
                  printf 'KILL\n' >> "$lifecycle"
                  daemon_mock_running=false
                  ;;
                *) return 64 ;;
              esac
            }
            sleep() {
              sleep_count=$((sleep_count + 1))
              if [[ "$sleep_count" -eq $((daemon_stop_grace_attempts + 10)) ]]; then
                printf '%s\n' 'Shutdown requested: true' >> "$daemon_log"
              fi
            }
            wait() {
              printf 'WAIT\n' >> "$lifecycle"
              return 137
            }
            stop_daemon
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("lifecycle.log"), encoding: .utf8),
            "TERM\nKILL\nWAIT\n"
        )
        let evidence = try String(
            contentsOf: root.appendingPathComponent("evidence-v2.log"),
            encoding: .utf8
        )
        XCTAssertTrue(
            evidence.contains(
                "daemon-stop-reap-escalated generation=63 pid=444444 signal=KILL reason=clean-loop-stop"
            )
        )
        XCTAssertTrue(evidence.contains("daemon-stopped generation=63 pid=444444"))
    }

    func testAggregateSoakRefusesToEscalateLingeringDaemonWithoutCleanShutdownProof() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-unsafe-reap-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            state_file="$2/state-v2.tsv"
            evidence_file="$2/evidence-v2.log"
            lifecycle="$2/lifecycle.log"
            printf 'schemaVersion\t2\n' > "$state_file"
            : > "$evidence_file"
            : > "$lifecycle"
            daemon_generation=62
            daemon_pid=434343
            daemon_mock_running=true
            printf '%s\n' 'hostwrightd foreground-dev loop stopped' > "$2/daemon-62.log"
            daemon_process_running() {
              [[ "$daemon_mock_running" == true ]]
            }
            kill() {
              case "$1" in
                -0) return 0 ;;
                -TERM) printf 'TERM\n' >> "$lifecycle" ;;
                -KILL)
                  printf 'KILL\n' >> "$lifecycle"
                  daemon_mock_running=false
                  ;;
                *) return 64 ;;
              esac
            }
            sleep() { :; }
            wait() {
              printf 'WAIT\n' >> "$lifecycle"
              return 137
            }
            stop_daemon
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 70, result.output)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("lifecycle.log"), encoding: .utf8),
            "TERM\n"
        )
        XCTAssertTrue(
            result.output.contains(
                "The exact foreground daemon did not stop after its bounded clean-shutdown reap."
            )
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

    func testAggregateSoakValidatesExecutableIdentityBySourceEpoch() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-checkpoint-epochs-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            checkpointFixtureSource(validate: true, includesExecutableTransition: true),
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("samples=2 seconds=600 rows=3"))
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
            prior_source='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            current_source='eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
            HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT="$prior_source"
            source_commit_history="$prior_source"
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
            HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT="$current_source"
            source_commit_history="$prior_source,$current_source"
            run_checkpointed_fault 72 pressure perform_fault
            source_commit_history="$current_source"
            if fault_receipt_valid 72 pressure; then
              exit 75
            fi
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

    func testAggregateSoakFinalizesResumedWorkloadWithoutInjectingItAgain() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-resumed-workload-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT='eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
            source_commit_history='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
            evidence_file="$2/evidence-v2.log"
            qualification_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            hostwright_sha='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            daemon_sha='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
            host_identity_sha='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
            resource_identifier='hostwright-v2-p08-soa-web-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            resource_uuid='cccccccc-cccc-8ccc-8ccc-cccccccccccc'
            project_name='p08-soak-test'
            previous_checkpoint_sha256="$genesis_checkpoint_sha256"
            cumulative_samples=647
            resume_expected_workload_fault=1
            mkdir "$2/fault-checkpoints-v1"
            : > "$evidence_file"
            printf 'fixture\n# soak-generation=648\n' > "$2/hostwright.yaml"
            printf '0\n' > "$2/verify-count"
            test_root="$2"
            verify_running() {
              printf '%s\n' "$(( $(<"$test_root/verify-count") + 1 ))" > "$test_root/verify-count"
            }
            inject_workload_fault() {
              printf 'duplicate\n' > "$test_root/duplicate-stop"
              return 75
            }
            run_workload_fault_checkpoint 648
            run_workload_fault_checkpoint 648
            [[ "$(<"$2/verify-count")" == 1 ]]
            [[ ! -e "$2/duplicate-stop" ]]
            [[ -f "$2/fault-checkpoints-v1/sequence-0648-workload.tsv" ]]
            grep -Fq 'workload-recovered resource=hostwright-v2-p08-soa-web-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa sequence=648 resumed=true' "$evidence_file"
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
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

    func testAggregateSoakSupervisorRefusesConcurrentOwner() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-supervisor-owner-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            validate_root() { :; }
            cumulative_samples=0
            latest_state_value() { printf 'prepared\n'; }
            supervisor_configure_paths
            mkdir "$supervisor_lock_dir"
            chmod 700 "$supervisor_lock_dir"
            printf 'schemaVersion\t1\n' > "$supervisor_lock_owner_file"
            chmod 600 "$supervisor_lock_owner_file"
            supervisor_lock_is_live() { return 0; }
            supervisor_acquire_lock
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 75, result.output)
        XCTAssertTrue(result.output.contains("supervisor is already active"))
    }

    func testAggregateSoakSupervisorPreservesStaleOwnerWhenReclaiming() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-supervisor-reclaim-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            validate_root() { :; }
            cumulative_samples=0
            latest_state_value() { printf 'prepared\n'; }
            supervisor_configure_paths
            mkdir "$supervisor_lock_dir"
            chmod 700 "$supervisor_lock_dir"
            printf 'stale-owner-evidence\n' > "$supervisor_lock_owner_file"
            chmod 600 "$supervisor_lock_owner_file"
            supervisor_lock_is_live() { return 1; }
            supervisor_acquire_lock
            supervisor_lock_owned
            grep -R -Fq 'stale-owner-evidence' "$supervisor_root"/reclaimed-*
            supervisor_release_lock
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testAggregateSoakSupervisorRejectsCorruptReceiptLedger() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-supervisor-receipt-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            validate_root() { :; }
            supervisor_configure_paths
            printf 'truncated\treceipt\n' > "$supervisor_receipt_file"
            chmod 600 "$supervisor_receipt_file"
            supervisor_initialize_receipts
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 75, result.output)
        XCTAssertTrue(result.output.contains("receipt"))
    }

    func testAggregateSoakSupervisorRestoresProgressResetAcrossRestart() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-supervisor-reset-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            validate_root() { :; }
            supervisor_configure_paths
            {
              printf 'epoch\tevent\tattempt\tsequence\tphase\tsignature\tdetail\n'
              printf '2026-08-12T00:00:00Z\tresumable-exit\t1\t10\tresumable\texit70-seq10\tcount=1\n'
              printf '2026-08-12T00:05:00Z\tfailure-memory-reset\t1\t11\trunning\tnone\tvalidated-durable-progress\n'
            } > "$supervisor_receipt_file"
            chmod 600 "$supervisor_receipt_file"
            supervisor_last_failure_signature='stale'
            supervisor_identical_failure_count=9
            supervisor_restore_failure_memory
            [[ -z "$supervisor_last_failure_signature" ]]
            [[ "$supervisor_identical_failure_count" == 0 ]]
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testAggregateSoakSupervisorCircuitBreaksRepeatedNoProgressFailure() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-supervisor-breaker-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            validate_root() { :; }
            supervisor_configure_paths
            supervisor_initialize_receipts
            cumulative_samples=20
            latest_state_value() { printf 'resumable\n'; }
            supervisor_note_failure 'exit70-sequence20'
            supervisor_note_failure 'exit70-sequence20'
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 75, result.output)
        XCTAssertTrue(result.output.contains("circuit breaker"))
        let receipts = try String(
            contentsOf: root.appendingPathComponent("supervisor-v1/receipts-v1.tsv"),
            encoding: .utf8
        )
        XCTAssertTrue(receipts.contains("\tsupervisor-circuit-breaker\t"))
        XCTAssertTrue(receipts.contains("\tcount=2\n"))
    }

    func testAggregateSoakSupervisorPersistsNormalizedRealFailureSignature() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-supervisor-signature-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            validate_root() { :; }
            supervisor_configure_paths
            supervisor_initialize_receipts
            cumulative_samples=42
            evidence_file="$2/evidence-v2.log"
            printf '2026-08-12T00:00:00Z\tfailure\tforeground daemon did not stop after SIGTERM (status 70).\n' > "$evidence_file"
            latest_state_value() {
              case "$1" in
                runnerExitCode) printf '70\n' ;;
                phase) printf 'resumable\n' ;;
              esac
            }
            signature="$(supervisor_failure_signature)"
            [[ "$signature" =~ ^70\|42\|[a-f0-9]{64}$ ]]
            supervisor_note_failure "$signature"
            supervisor_validate_receipts
            supervisor_last_failure_signature=''
            supervisor_identical_failure_count=0
            supervisor_restore_failure_memory
            [[ "$supervisor_last_failure_signature" == "$signature" ]]
            [[ "$supervisor_identical_failure_count" == 1 ]]
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testAggregateSoakSupervisorAcknowledgesOnlyValidatedCheckpoint() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-supervisor-checkpoint-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let passing = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            test_root="$2"
            supervisor_checkpoint_wait_seconds=1
            supervisor_poll_seconds=1
            latest_state_value() {
              case "$1" in
                lastSequence) printf '11\n' ;;
                phase) printf 'running\n' ;;
              esac
            }
            supervisor_validate_observation() {
              [[ "$1" == 11 ]]
              printf 'validated\n' > "$test_root/validated"
            }
            supervisor_receipt() { printf '%s\n' "$1" >> "$test_root/events"; }
            supervisor_wait_for_first_checkpoint 10
            grep -Fqx validated "$2/validated"
            grep -Fqx first-checkpoint-acknowledged "$2/events"
            """#,
            arguments: [scriptURL.path, root.path]
        )
        XCTAssertEqual(passing.status, 0, passing.output)

        let failing = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            test_root="$2"
            supervisor_checkpoint_wait_seconds=1
            supervisor_poll_seconds=1
            latest_state_value() {
              case "$1" in
                lastSequence) printf '11\n' ;;
                phase) printf 'running\n' ;;
              esac
            }
            supervisor_validate_observation() { die 'synthetic checkpoint conflict' 75; }
            supervisor_receipt() { printf '%s\n' "$1" >> "$test_root/rejected-events"; }
            supervisor_wait_for_first_checkpoint 10
            """#,
            arguments: [scriptURL.path, root.path]
        )
        XCTAssertEqual(failing.status, 75, failing.output)
        let rejectedEvents = root.appendingPathComponent("rejected-events")
        if FileManager.default.fileExists(atPath: rejectedEvents.path) {
            XCTAssertFalse(
                try String(contentsOf: rejectedEvents, encoding: .utf8)
                    .contains("first-checkpoint-acknowledged")
            )
        }
    }

    func testAggregateSoakSupervisorAcceptsOnlyStableMonotonicObservation() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-supervisor-monotonic-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let passing = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            state_file="$2/state-v2.tsv"
            test_root="$2"
            printf '0\n' > "$test_root/snapshot-count"
            validate_root() { :; }
            configure_authority_paths() { :; }
            load_qualification_state() { :; }
            validate_checkpoint_chain() {
              cumulative_samples=11
              cumulative_seconds=3300
              previous_checkpoint_sha256='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            }
            supervisor_checkpoint_state_snapshot() {
              count="$(cat "$test_root/snapshot-count")"
              count=$((count + 1))
              printf '%s\n' "$count" > "$test_root/snapshot-count"
              if [[ "$count" == 1 ]]; then
                printf '10\t3000\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trunning\n'
              else
                printf '11\t3300\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trunning\n'
              fi
            }
            container() { printf '[]\n'; }
            managed_runtime_count() { printf '1\n'; }
            verify_resume_runtime_inventory() { :; }
            supervisor_validate_sqlite() { :; }
            supervisor_validate_guard() { :; }
            supervisor_validate_observation 10
            [[ "$cumulative_samples" == 11 ]]
            [[ "$(cat "$test_root/snapshot-count")" -ge 4 ]]
            """#,
            arguments: [scriptURL.path, root.path]
        )
        XCTAssertEqual(passing.status, 0, passing.output)

        let failing = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            state_file="$2/state-v2.tsv"
            validate_root() { :; }
            configure_authority_paths() { :; }
            load_qualification_state() { :; }
            validate_checkpoint_chain() {
              cumulative_samples=11
              cumulative_seconds=3300
              previous_checkpoint_sha256='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            }
            supervisor_checkpoint_state_snapshot() {
              printf '11\t3300\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trunning\n'
            }
            container() { printf '[]\n'; }
            managed_runtime_count() { printf '1\n'; }
            verify_resume_runtime_inventory() { :; }
            supervisor_validate_sqlite() { :; }
            supervisor_validate_guard() { :; }
            supervisor_validate_observation 12
            """#,
            arguments: [scriptURL.path, root.path]
        )
        XCTAssertEqual(failing.status, 75, failing.output)
        XCTAssertTrue(failing.output.contains("checkpoint sequence regression"))
    }

    func testAggregateSoakSupervisorDoesNotLaunchAcrossIntegrityConflict() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-supervisor-integrity-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
            cumulative_samples=10
            validate_root() { :; }
            configure_authority_paths() { :; }
            load_qualification_state() { :; }
            validate_checkpoint_chain() { :; }
            latest_state_value() {
              case "$1" in
                phase) printf 'resumable\n' ;;
                *) printf '10\n' ;;
              esac
            }
            supervisor_runner_state() { return 1; }
            supervisor_validate_guard() { :; }
            supervisor_validate_sqlite() { die 'synthetic SQLite integrity conflict' 75; }
            supervisor_validate_observation() { :; }
            validate_inputs() { :; }
            supervisor_receipt() { :; }
            supervisor_launch_resume() { printf 'launched\n' > "$2/launched"; }
            supervisor_validate_before_resume
            supervisor_launch_resume
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 75, result.output)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path)
        )
    }

    func testAggregateSoakSupervisorDoesNotTrustStaleTmuxName() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-supervisor-stale-tmux-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runBash(
            #"""
            source "$1"
            active_run_root="$2/active-run-v2"
            supervisor_runner_session='hostwright-p08-soak-test'
            supervisor_startup_deadline=$(( $(date +%s) + 60 ))
            tmux() {
              case "$1" in
                has-session) return 0 ;;
                display-message) printf '999999\n' ;;
              esac
            }
            if supervisor_runner_state; then
              exit 90
            fi
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testAggregateSoakSupervisorRecoversDeadDifferentBootGapWithoutReset() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-soak-qualification.sh"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-soak-supervisor-wake-gap-\(UUID().uuidString.lowercased())",
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
            supervisor_runner_session='hostwright-p08-soak-nonexistent-test'
            cumulative_samples=3
            cumulative_seconds=900
            last_sample_epoch=1900
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
              printf 'bootIdentity\t%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
              printf 'segmentID\t%s\n' "$prior_segment"
              printf 'startEpoch\t1000\n'
              printf 'startSequence\t0\n'
              printf 'startCheckpointSHA256\t%s\n' "$genesis_checkpoint_sha256"
              printf 'gapSeconds\t0\n'
            } > "$active_run_root/owner-v1.tsv"
            chmod 600 "$active_run_root/owner-v1.tsv"
            if supervisor_runner_state; then
              exit 91
            fi
            recover_active_run_marker
            [[ "$(latest_state_value phase)" == resumable ]]
            [[ "$cumulative_samples" == 3 ]]
            [[ "$cumulative_seconds" == 900 ]]
            [[ ! -e "$active_run_root" ]]
            """#,
            arguments: [scriptURL.path, root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
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

    private func checkpointFixtureSource(
        validate: Bool,
        includesExecutableTransition: Bool = false
    ) -> String {
        let transitionMode = includesExecutableTransition ? "1" : "0"
        let setup = #"""
        source "$1"
        HOSTWRIGHT_PHASE08_SOAK_ROOT="$2"
        transition_mode='\#(transitionMode)'
        prior_source='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        current_source='7777777777777777777777777777777777777777'
        prior_hostwright_sha='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        prior_daemon_sha='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
        current_hostwright_sha='1111111111111111111111111111111111111111111111111111111111111111'
        current_daemon_sha='2222222222222222222222222222222222222222222222222222222222222222'
        HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT="$prior_source"
        checkpoint_source_commit="$prior_source"
        source_commit_history="$prior_source"
        state_file="$2/state-v2.tsv"
        evidence_file="$2/evidence-v2.log"
        sample_file="$2/samples-v2.tsv"
        checkpoint_root="$2/checkpoints-v1"
        segment_file="$2/segments-v1.tsv"
        qualification_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        segment_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        next_segment_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd'
        project_name='p08-soak-test'
        resource_identifier='hostwright-v2-p08-soa-web-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        resource_uuid='cccccccc-cccc-8ccc-8ccc-cccccccccccc'
        hostwright_sha="$prior_hostwright_sha"
        daemon_sha="$prior_daemon_sha"
        template_sha='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
        host_identity_sha='9999999999999999999999999999999999999999999999999999999999999999'
        previous_checkpoint_sha256="$genesis_checkpoint_sha256"
        mkdir -p "$checkpoint_root" "$2/runtime-inventory-v1" "$2/fault-checkpoints-v1"
        : > "$evidence_file"
        printf 'schemaVersion\t2\n' > "$state_file"
        printf 'segmentID\tevent\tepoch\tsequence\tqualifiedSeconds\tcheckpointSHA256\tdetail1\tdetail2\n' > "$segment_file"
        printf '%s\tstart\t1000\t0\t0\t%s\tgapSeconds=0\tsourceCommit=%s\n' \
          "$segment_id" "$genesis_checkpoint_sha256" "$prior_source" >> "$segment_file"
        printf '%b\n' "$checkpoint_header" > "$sample_file"
        if [[ ! -e "$checkpoint_root/sequence-0001.tsv" ]]; then
          for sequence in 1 2; do
            row_segment_id="$segment_id"
            row_segment_sample="$sequence"
            row_source_commit="$prior_source"
            row_hostwright_sha="$prior_hostwright_sha"
            row_daemon_sha="$prior_daemon_sha"
            if [[ "$transition_mode" == 1 && "$sequence" == 2 ]]; then
              printf '%s\tfinish\t1400\t1\t300\t%s\tpassed\t0\n' \
                "$segment_id" "$previous_checkpoint_sha256" >> "$segment_file"
              printf '%s\tstart\t1500\t1\t300\t%s\tgapSeconds=0\tsourceCommit=%s\n' \
                "$next_segment_id" "$previous_checkpoint_sha256" "$current_source" >> "$segment_file"
              row_segment_id="$next_segment_id"
              row_segment_sample=1
              row_source_commit="$current_source"
              row_hostwright_sha="$current_hostwright_sha"
              row_daemon_sha="$current_daemon_sha"
            fi
            printf '{"sequence":%s}\n' "$sequence" > "$2/runtime-inventory-v1/sequence-$(printf '%04d' "$sequence").json"
            chmod 600 "$2/runtime-inventory-v1/sequence-$(printf '%04d' "$sequence").json"
            inventory_sha="$(sha256 "$2/runtime-inventory-v1/sequence-$(printf '%04d' "$sequence").json")"
            printf -v material '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
              "$sequence" "$qualification_id" "$row_segment_id" "$row_segment_sample" "$((1000 + sequence * 300))" "$((sequence * 300))" \
              123 1024 12 4096 10 0 20 2 0 1 "$inventory_sha" \
              eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
              ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
              "$resource_identifier" "$resource_uuid" "$project_name" "$row_hostwright_sha" \
              "$row_daemon_sha" "$template_sha" "$host_identity_sha" \
              "$row_source_commit" \
              "$previous_checkpoint_sha256"
            commit_checkpoint "$sequence" "$material"
          done
          printf '%b\n' "$checkpoint_header" > "$sample_file"
        fi
        if [[ "$transition_mode" == 1 ]]; then
          HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT="$current_source"
          checkpoint_source_commit="$current_source"
          source_commit_history="$prior_source,$current_source"
          hostwright_sha="$current_hostwright_sha"
          daemon_sha="$current_daemon_sha"
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
