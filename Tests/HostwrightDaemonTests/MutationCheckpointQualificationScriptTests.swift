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
            "Phase 08 aggregate soak qualification contract v1 is valid.",
            "exactly 259200 seconds",
            "300-second samples",
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
            "resource_uuid_pattern=",
            "phase08-gate16-soak-",
            "active-run-v1",
            "preflight)",
            "source_digest",
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
            "runner-exit-classified",
            "verify_exclusive_runtime_inventory",
            "runtimeInventorySHA256",
            "RuntimeQualificationRecoveryDriverTests",
            "RuntimeQualificationProcessControlTests",
            "container stop",
            "--interval 4 --jitter 1",
            "final-rm-plan.json",
            "evidence-v1.sha256"
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
            : > "$evidence_file"
            compact_state 12
            """#,
            arguments: [scriptURL.path, root.path, fakeHostwright.path],
            environment: ["HOSTWRIGHT_TEST_COUNTER": counter.path]
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
    }

    func testAggregateSoakUnexpectedExitDurablyMarksFailure() throws {
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
        XCTAssertTrue(state.contains("phase\tfailed"))
        XCTAssertTrue(state.contains("runnerExitCode\t1"))
        XCTAssertTrue(
            try String(
                contentsOf: root.appendingPathComponent("evidence-v1.log"),
                encoding: .utf8
            ).contains("runner-exit-classified status=1")
        )
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

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
