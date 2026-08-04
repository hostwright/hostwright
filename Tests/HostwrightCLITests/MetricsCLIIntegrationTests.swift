import Darwin
import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightObservability
@testable import HostwrightState

final class MetricsCLIIntegrationTests: XCTestCase {
    func testParserAcceptsOnlyTheVersionedSnapshotAndConfirmedExportSurfaces() throws {
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["metrics", "snapshot", "--state-db", "/tmp/state.sqlite", "--output", "json"]),
            .metrics(options: MetricsCLIOptions(
                action: .snapshot,
                stateDatabasePath: "/tmp/state.sqlite",
                output: .json
            ))
        )
        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "metrics", "export", "--output-path", "/tmp/metrics.json",
                "--confirm-snapshot", digest
            ]),
            .metrics(options: MetricsCLIOptions(
                action: .export(outputPath: "/tmp/metrics.json", confirmationSHA256: digest),
                stateDatabasePath: nil,
                output: .text
            ))
        )
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["metrics", "export"]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "metrics", "export", "--output-path", "relative.json", "--confirm-snapshot", digest
        ]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "metrics", "snapshot", "--state-db", "/tmp/one", "--state-db", "/tmp/two"
        ]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "metrics", "export", "--output-path", "/tmp/metrics.json",
            "--confirm-snapshot", String(repeating: "A", count: 64)
        ]))
    }

    func testSnapshotAndConfirmedExportUseExistingStateAndPrivateExactFile() throws {
        try withStore { root, store in
            var environment = CLIEnvironment.live
            environment.metricsDate = {
                ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!
            }
            let snapshotResult = try HostwrightCLI.run(
                command: .metrics(options: MetricsCLIOptions(
                    action: .snapshot,
                    stateDatabasePath: store.path,
                    output: .json
                )),
                environment: environment
            )
            let snapshot = try JSONDecoder().decode(
                HostwrightMetricsSnapshot.self,
                from: Data(snapshotResult.standardOutput.utf8)
            )
            XCTAssertEqual(snapshot.schemaVersion, 1)
            XCTAssertEqual(snapshot.source.schemaVersion, MigrationRunner.latestSchemaVersion)
            XCTAssertEqual(snapshot.series.count, 59)

            let outputPath = root.appendingPathComponent("metrics-v1.json").path
            let exportResult = try HostwrightCLI.run(
                command: .metrics(options: MetricsCLIOptions(
                    action: .export(
                        outputPath: outputPath,
                        confirmationSHA256: snapshot.snapshotSHA256
                    ),
                    stateDatabasePath: store.path,
                    output: .json
                )),
                environment: environment
            )
            let receipt = try JSONDecoder().decode(
                HostwrightMetricsExportReceipt.self,
                from: Data(exportResult.standardOutput.utf8)
            )
            XCTAssertEqual(receipt.snapshotSHA256, snapshot.snapshotSHA256)
            XCTAssertFalse(receipt.automaticUpload)
            XCTAssertEqual(receipt.ownership, "operator-owned")
            let exported = try Data(contentsOf: URL(fileURLWithPath: outputPath))
            let decoded = try JSONDecoder().decode(HostwrightMetricsSnapshot.self, from: exported)
            XCTAssertEqual(decoded.snapshotSHA256, snapshot.snapshotSHA256)
            let attributes = try FileManager.default.attributesOfItem(atPath: outputPath)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertThrowsError(try HostwrightCLI.run(
                command: .metrics(options: MetricsCLIOptions(
                    action: .export(
                        outputPath: outputPath,
                        confirmationSHA256: snapshot.snapshotSHA256
                    ),
                    stateDatabasePath: store.path,
                    output: .text
                )),
                environment: environment
            ))
        }
    }

    func testChangedConfirmationCancellationAndSymlinkParentsLeaveNoArtifact() throws {
        try withStore { root, store in
            var environment = CLIEnvironment.live
            let stalePath = root.appendingPathComponent("stale.json").path
            XCTAssertThrowsError(try HostwrightCLI.run(
                command: .metrics(options: MetricsCLIOptions(
                    action: .export(
                        outputPath: stalePath,
                        confirmationSHA256: String(repeating: "0", count: 64)
                    ),
                    stateDatabasePath: store.path,
                    output: .text
                )),
                environment: environment
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: stalePath))

            let snapshot = try StateMetricsService(store: store).snapshot()
            environment.metricsCancelled = { true }
            let cancelledPath = root.appendingPathComponent("cancelled.json").path
            XCTAssertThrowsError(try HostwrightCLI.run(
                command: .metrics(options: MetricsCLIOptions(
                    action: .export(
                        outputPath: cancelledPath,
                        confirmationSHA256: snapshot.snapshotSHA256
                    ),
                    stateDatabasePath: store.path,
                    output: .text
                )),
                environment: environment
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledPath))

            var cancellationChecks = 0
            environment.metricsCancelled = {
                cancellationChecks += 1
                return cancellationChecks >= 4
            }
            let lateCancelledPath = root.appendingPathComponent("late-cancelled.json").path
            XCTAssertThrowsError(try HostwrightCLI.run(
                command: .metrics(options: MetricsCLIOptions(
                    action: .export(
                        outputPath: lateCancelledPath,
                        confirmationSHA256: snapshot.snapshotSHA256
                    ),
                    stateDatabasePath: store.path,
                    output: .text
                )),
                environment: environment
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: lateCancelledPath))

            let linkedParent = root.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: root)
            environment.metricsCancelled = { false }
            let linkedPath = linkedParent.appendingPathComponent("metrics.json").path
            XCTAssertThrowsError(try HostwrightCLI.run(
                command: .metrics(options: MetricsCLIOptions(
                    action: .export(
                        outputPath: linkedPath,
                        confirmationSHA256: snapshot.snapshotSHA256
                    ),
                    stateDatabasePath: store.path,
                    output: .text
                )),
                environment: environment
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("metrics.json").path
            ))
        }
    }

    func testMissingDatabaseIsNotCreated() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("missing.sqlite").path
        XCTAssertThrowsError(try HostwrightCLI.run(
            command: .metrics(options: MetricsCLIOptions(
                action: .snapshot,
                stateDatabasePath: path,
                output: .json
            ))
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testMetricsCommandFamilyIsPublicButDoesNotLogPaths() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("secret-project-state.sqlite").path
        let sink = MetricsLogCapture()
        var environment = CLIEnvironment.live
        environment.observabilitySink = sink
        environment.observabilityCorrelationID = {
            "12345678-1234-4234-8234-123456789abc"
        }

        let result = HostwrightCLI.run(
            arguments: ["metrics", "snapshot", "--state-db", missing, "--output", "json"],
            environment: environment
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(sink.records.map(\.reason), [.cliStarted, .cliFailed])
        XCTAssertEqual(
            sink.records.last?.fields.first { $0.name == .command }?.value,
            "metrics"
        )
        XCTAssertTrue(sink.records.allSatisfy {
            !$0.canonicalMessage.contains("secret-project-state")
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    func testProjectsTenThousandRowsAndCleansAFileLimitFailure() throws {
        try withStore { root, store in
            try seedReconciliationRows(count: 10_000, store: store)
            var environment = CLIEnvironment.live
            environment.metricsDate = {
                ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!
            }
            let snapshotResult = try HostwrightCLI.run(
                command: .metrics(options: MetricsCLIOptions(
                    action: .snapshot,
                    stateDatabasePath: store.path,
                    output: .json
                )),
                environment: environment
            )
            let snapshot = try JSONDecoder().decode(
                HostwrightMetricsSnapshot.self,
                from: Data(snapshotResult.standardOutput.utf8)
            )
            XCTAssertEqual(snapshot.series.count, 59)
            XCTAssertEqual(
                snapshot.series.first {
                    $0.name == "hostwright_reconciliation_duration_seconds"
                }?.summary?.count,
                10_000
            )

            let outputPath = root.appendingPathComponent("subprocess-metrics.json").path
            _ = try HostwrightCLI.run(
                command: .metrics(options: MetricsCLIOptions(
                    action: .export(
                        outputPath: outputPath,
                        confirmationSHA256: snapshot.snapshotSHA256
                    ),
                    stateDatabasePath: store.path,
                    output: .json
                )),
                environment: environment
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))

            let limitedPath = root.appendingPathComponent("limited-metrics.json").path
            environment.metricsExport = { data, path, maximumBytes, isCancelled in
                let receipt = try SecureLocalExportWriter.write(
                    data,
                    to: path,
                    maximumBytes: maximumBytes,
                    isCancelled: isCancelled,
                    unsafeError: HostwrightMetricsError.unsafeExportPath,
                    afterWrite: { written in
                        XCTAssertGreaterThan(written, 0)
                        XCTAssertLessThan(written, data.count)
                        throw POSIXError(.ENOSPC)
                    },
                    maximumWriteChunkBytes: 32
                )
                return (receipt.outputSHA256, receipt.outputBytes)
            }
            XCTAssertThrowsError(try HostwrightCLI.run(
                command: .metrics(options: MetricsCLIOptions(
                    action: .export(
                        outputPath: limitedPath,
                        confirmationSHA256: snapshot.snapshotSHA256
                    ),
                    stateDatabasePath: store.path,
                    output: .json
                )),
                environment: environment
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: limitedPath))
        }
    }

    func testBuiltCLIRequiresAuthenticatedPersistentControlAPI() throws {
        try withStore { root, store in
            let executable = try hostwrightExecutable()
            let isolatedApplicationSupport = root.appendingPathComponent(
                "application-support",
                isDirectory: true
            ).path
            let process = try runProcess(
                executable: executable,
                arguments: [
                    "metrics", "snapshot", "--state-db", store.path,
                    "--output", "json"
                ],
                environment: [
                    "HOSTWRIGHT_APPLICATION_SUPPORT_DIR": isolatedApplicationSupport
                ]
            )

            XCTAssertEqual(process.status, 66, process.error)
            XCTAssertTrue(process.output.isEmpty)
            XCTAssertTrue(process.error.contains("HW-API-002"))
            XCTAssertFalse(process.error.contains(store.path))
        }
    }

    private func seedReconciliationRows(count: Int, store: SQLiteStateStore) throws {
        try store.withValidatedConnection { connection in
            try connection.transaction {
                for index in 0..<count {
                    try connection.run(
                        """
                        INSERT INTO operation_ledger (
                            id, created_at, updated_at, planned_action_type, project_id,
                            service_name, status, idempotency_key, plan_hash,
                            payload_json_redacted
                        ) VALUES (?, '2026-08-01T00:00:00Z', '2026-08-01T00:00:01Z',
                                  'daemon.reconcile', NULL, NULL, 'succeeded', ?, ?,
                                  '{"durationMilliseconds":1000}')
                        """,
                        bindings: [
                            .text("metrics-cli-daemon-\(index)"),
                            .text("metrics-cli-daemon-\(index)"),
                            .text(String(format: "%064llx", UInt64(index)))
                        ]
                    )
                }
            }
        }
    }

    private func hostwrightExecutable() throws -> URL {
        let candidate = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("hostwright")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw XCTSkip("The built hostwright executable is unavailable.")
        }
        return candidate
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        environment overrides: [String: String] = [:]
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        var environment = [
            "HOME": NSHomeDirectory(),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        for (name, value) in overrides {
            environment[name] = value
        }
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func withStore(
        _ body: (URL, SQLiteStateStore) throws -> Void
    ) throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try body(root, store)
    }

    private func privateRoot() throws -> URL {
        let raw = FileManager.default.temporaryDirectory.path
        let base = raw.hasPrefix("/var/") ? "/private\(raw)" : raw
        let root = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("hostwright-metrics-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }
}

private final class MetricsLogCapture: HostwrightLogSinking, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostwrightLogRecord] = []

    var records: [HostwrightLogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func emit(_ record: HostwrightLogRecord) -> HostwrightLogEmission {
        lock.lock()
        storage.append(record)
        lock.unlock()
        return HostwrightLogEmission(status: .emitted)
    }
}
