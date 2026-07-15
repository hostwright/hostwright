import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightState

final class StateMaintenanceCLITests: XCTestCase {
    func testParserRecognizesCompleteStateMaintenanceSurface() throws {
        let token = String(repeating: "a", count: 64)
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["state", "integrity", "--json"]),
            .state(action: .integrity, stateDatabasePath: nil, output: .json)
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["state", "backup", "--state-db", "/tmp/state.sqlite"]),
            .state(action: .backup, stateDatabasePath: "/tmp/state.sqlite", output: .text)
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["state", "restore", "--backup", "backup-1", "--dry-run"]),
            .state(
                action: .restore(backupID: "backup-1", confirmation: .dryRun),
                stateDatabasePath: nil,
                output: .text
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["state", "repair", "--confirm-repair", token]),
            .state(
                action: .repair(confirmation: .confirmed(token: token)),
                stateDatabasePath: nil,
                output: .text
            )
        )
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["state", "restore", "--backup", "backup-1"]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["state", "repair", "--dry-run", "--confirm-repair", token]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["state", "repair", "--confirm-repair", "token"]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["state", "restore", "--backup", "backup-1", "--confirm-restore", "--json"]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["state", "integrity", "--json", "--output", "text"]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["state", "backup", "--state-db", "/a", "--state-db", "/b"]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["state", "unknown"]))
    }

    func testCLIBackupCatalogDryRunRestoreAndConfirmedRestoreRoundTrip() throws {
        try withStore { store in
            try appendEvent("before-backup", to: store)
            let integrity = HostwrightCLI.run(arguments: stateArguments("integrity", path: store.path))
            XCTAssertEqual(integrity.exitCode, 0)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    StateIntegrityReport.self,
                    from: Data(integrity.standardOutput.utf8)
                ).health,
                .healthy
            )

            let backupResult = HostwrightCLI.run(arguments: stateArguments("backup", path: store.path))
            XCTAssertEqual(backupResult.exitCode, 0, backupResult.standardError)
            let backup = try JSONDecoder().decode(
                StateBackupRecord.self,
                from: Data(backupResult.standardOutput.utf8)
            )
            XCTAssertEqual(backup.kind, "stateBackupRecord")
            XCTAssertTrue(backup.restorable)

            let catalogResult = HostwrightCLI.run(arguments: stateArguments("backups", path: store.path))
            XCTAssertEqual(catalogResult.exitCode, 0)
            let catalog = try JSONDecoder().decode(
                StateBackupCatalog.self,
                from: Data(catalogResult.standardOutput.utf8)
            )
            XCTAssertEqual(catalog.backups.map(\.backupID), [backup.backupID])

            try appendEvent("after-backup", to: store)
            let dryRun = HostwrightCLI.run(arguments: [
                "state", "restore", "--backup", backup.backupID, "--dry-run",
                "--state-db", store.path, "--json"
            ])
            XCTAssertEqual(dryRun.exitCode, 0, dryRun.standardError)
            let plan = try JSONDecoder().decode(
                StateRestorePlan.self,
                from: Data(dryRun.standardOutput.utf8)
            )
            XCTAssertEqual(plan.kind, "stateRestorePlan")

            let confirmed = HostwrightCLI.run(arguments: [
                "state", "restore", "--backup", backup.backupID,
                "--confirm-restore", plan.confirmationToken,
                "--state-db", store.path, "--json"
            ])
            XCTAssertEqual(confirmed.exitCode, 0, confirmed.standardError)
            let result = try JSONDecoder().decode(
                StateRestoreResult.self,
                from: Data(confirmed.standardOutput.utf8)
            )
            XCTAssertEqual(result.health, .healthy)
            let ids = try store.events.loadAll().map(\.id)
            XCTAssertTrue(ids.contains("before-backup"))
            XCTAssertFalse(ids.contains("after-backup"))
        }
    }

    func testCLIRepairDryRunAndConfirmationUseStableJSONContracts() throws {
        try withStore { store in
            let connection = try SQLiteConnection(path: store.path, createIfNeeded: false)
            try connection.run(
                """
                INSERT INTO observed_runtime_snapshots (
                    id, project_id, runtime_adapter, runtime_name, runtime_version,
                    observed_at, parser_version, raw_output_hash, redacted_summary, capabilities_json
                ) VALUES ('cli-invalid', NULL, 'apple-container-cli', 'Apple container CLI',
                          '1.1.0', '2026-07-13T12:00:00Z', 'v1', NULL, 'invalid', 'not-json')
                """
            )
            try connection.close()

            let integrity = HostwrightCLI.run(arguments: stateArguments("integrity", path: store.path))
            XCTAssertEqual(integrity.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertFalse(integrity.standardOutput.isEmpty)
            XCTAssertFalse(integrity.standardError.isEmpty)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    StateIntegrityReport.self,
                    from: Data(integrity.standardOutput.utf8)
                ).health,
                .degraded
            )

            let dryRun = HostwrightCLI.run(arguments: [
                "state", "repair", "--dry-run", "--state-db", store.path, "--json"
            ])
            XCTAssertEqual(dryRun.exitCode, 0, dryRun.standardError)
            let plan = try JSONDecoder().decode(
                StateRepairPlan.self,
                from: Data(dryRun.standardOutput.utf8)
            )
            XCTAssertEqual(plan.tables["observed_runtime_snapshots"], 1)

            let confirmed = HostwrightCLI.run(arguments: [
                "state", "repair", "--confirm-repair", plan.confirmationToken,
                "--state-db", store.path, "--json"
            ])
            XCTAssertEqual(confirmed.exitCode, 0, confirmed.standardError)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    StateRepairResult.self,
                    from: Data(confirmed.standardOutput.utf8)
                ).health,
                .healthy
            )
        }
    }

    func testCLIConfirmationMismatchAndCorruptIntegrityUseStableErrors() throws {
        try withStore { store in
            let maintenance = try StateMaintenanceService(store: store)
            let backup = try maintenance.createBackup()
            let mismatch = HostwrightCLI.run(arguments: [
                "state", "restore", "--backup", backup.backupID,
                "--confirm-restore", String(repeating: "0", count: 64),
                "--state-db", store.path, "--json"
            ])
            XCTAssertEqual(mismatch.exitCode, CLIExitCode.confirmationMismatch.rawValue)
            let mismatchObject = try jsonObject(mismatch.standardError)
            XCTAssertEqual(mismatchObject["code"] as? String, "HW-CLI-003")

            try Data("not sqlite".utf8).write(to: URL(fileURLWithPath: store.path))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)
            let integrity = HostwrightCLI.run(arguments: stateArguments("integrity", path: store.path))
            XCTAssertEqual(integrity.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    StateIntegrityReport.self,
                    from: Data(integrity.standardOutput.utf8)
                ).health,
                .unrecoverable
            )
            let error = try jsonObject(integrity.standardError)
            XCTAssertEqual(error["code"] as? String, "HW-STATE-001")
        }
    }

    func testCLIRecoverIsIdempotentWithoutPendingJournal() throws {
        try withStore { store in
            let result = HostwrightCLI.run(arguments: stateArguments("recover", path: store.path))
            XCTAssertEqual(result.exitCode, 0, result.standardError)
            let recovery = try JSONDecoder().decode(
                StateRecoveryResult.self,
                from: Data(result.standardOutput.utf8)
            )
            XCTAssertFalse(recovery.recovered)
            XCTAssertEqual(recovery.health, .healthy)
        }
    }

    private func withStore(_ body: (SQLiteStateStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-state-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try body(store)
    }

    private func stateArguments(_ operation: String, path: String) -> [String] {
        ["state", operation, "--state-db", path, "--json"]
    }

    private func appendEvent(_ id: String, to store: SQLiteStateStore) throws {
        try store.events.append([
            EventRecord(
                id: id,
                timestamp: "2026-07-13T12:00:00Z",
                severity: .info,
                type: "state.cli.test",
                source: "state-maintenance-cli-tests",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: nil,
                message: "test event",
                payloadJSONRedacted: "{}"
            )
        ])
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }
}
