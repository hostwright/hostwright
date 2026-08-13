import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightRuntime
import HostwrightState

struct StateMaintenanceCommandRunner {
    let stateStoreConfiguration: StateStoreConfiguration
    let action: StateCLIAction
    let output: CLIOutputFormat
    let environment: CLIEnvironment

    func run() -> CLIRunResult {
        do {
            let store = SQLiteStateStore(configuration: stateStoreConfiguration)
            let maintenance = try StateMaintenanceService(store: store)
            switch action {
            case .integrity:
                let report = maintenance.integrity()
                let rendered = output == .json
                    ? CLIJSON.codable(report)
                    : render(report)
                guard report.health == .healthy else {
                    return stateFailure(
                        message: report.recommendedAction,
                        standardOutput: rendered
                    )
                }
                return CLIRunResult(standardOutput: rendered)
            case .backup:
                let record = try maintenance.createBackup()
                return CLIRunResult(
                    standardOutput: output == .json
                        ? CLIJSON.codable(record)
                        : render(record)
                )
            case .backups:
                let catalog = try maintenance.backupCatalog()
                return CLIRunResult(
                    standardOutput: output == .json
                        ? CLIJSON.codable(catalog)
                        : render(catalog)
                )
            case .restore(let backupID, let confirmation):
                switch confirmation {
                case .dryRun:
                    let plan = try maintenance.restorePlan(backupID: backupID)
                    return CLIRunResult(
                        standardOutput: output == .json
                            ? CLIJSON.codable(plan)
                            : render(plan)
                    )
                case .confirmed(let token):
                    let result = try maintenance.restore(
                        backupID: backupID,
                        confirmationToken: token
                    )
                    return CLIRunResult(
                        standardOutput: output == .json
                            ? CLIJSON.codable(result)
                            : render(result)
                    )
                }
            case .repair(let confirmation):
                switch confirmation {
                case .dryRun:
                    let plan = try maintenance.repairPlan()
                    return CLIRunResult(
                        standardOutput: output == .json
                            ? CLIJSON.codable(plan)
                            : render(plan)
                    )
                case .confirmed(let token):
                    let result = try maintenance.repair(confirmationToken: token)
                    return CLIRunResult(
                        standardOutput: output == .json
                            ? CLIJSON.codable(result)
                            : render(result)
                    )
                }
            case .recover:
                let result = try maintenance.recover()
                return CLIRunResult(
                    standardOutput: output == .json
                        ? CLIJSON.codable(result)
                        : render(result)
                )
            case .retention(let manifestPath):
                let policy = try retentionPolicy(manifestPath)
                let report = try StateRetentionService(store: store).status(policy: policy)
                return CLIRunResult(
                    standardOutput: output == .json
                        ? CLIJSON.codable(report)
                        : render(report)
                )
            case .compact(let manifestPath, let confirmation, let evaluatedAt):
                let policy = try retentionPolicy(manifestPath)
                switch confirmation {
                case .dryRun:
                    let plan = try StateRetentionService(store: store).compactionPlan(policy: policy)
                    return CLIRunResult(
                        standardOutput: output == .json
                            ? CLIJSON.codable(plan)
                            : render(plan)
                    )
                case .confirmed(let token):
                    guard let evaluatedAt else {
                        return failure(
                            code: .commandUsage,
                            message: "Confirmed state compaction requires its exact dry-run evaluation time."
                        )
                    }
                    let result = try StateRetentionService(store: store).compact(
                        policy: policy,
                        confirmationToken: token,
                        evaluatedAt: evaluatedAt
                    )
                    return CLIRunResult(
                        standardOutput: output == .json
                            ? CLIJSON.codable(result)
                            : render(result)
                    )
                }
            }
        } catch StateMaintenanceError.confirmationMismatch {
            return failure(
                code: .confirmationMismatch,
                message: StateMaintenanceError.confirmationMismatch.description
            )
        } catch let error as StateMaintenanceError {
            switch error {
            case .unsafeRepair, .unsafeCompaction:
                return failure(code: .unsafeExposure, message: error.description)
            default:
                return failure(code: .stateStoreUnavailable, message: error.description)
            }
        } catch {
            return failure(
                code: .stateStoreUnavailable,
                message: String(describing: error)
            )
        }
    }

    private func render(_ report: StateIntegrityReport) -> String {
        var lines = [
            "Hostwright state integrity",
            "Health: \(report.health.rawValue)",
            "State schema: \(report.stateSchemaVersion.map(String.init) ?? "unknown")",
            "Database bytes: \(report.databaseBytes.map(String.init) ?? "unknown")",
            "Database SHA-256: \(report.databaseSHA256 ?? "unavailable")",
            ""
        ]
        lines += report.checks.map {
            "- \($0.status.rawValue) \($0.identifier): \($0.message)\($0.affectedRows > 0 ? " (rows=\($0.affectedRows))" : "")"
        }
        if !report.repairableProjectionTables.isEmpty {
            lines.append("Repairable projections: \(report.repairableProjectionTables.joined(separator: ", "))")
        }
        lines.append("Recommended action: \(report.recommendedAction)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func render(_ record: StateBackupRecord) -> String {
        """
        Hostwright state backup
        Backup ID: \(record.backupID)
        Created at: \(record.createdAt ?? "unknown")
        Restorable: \(record.restorable)
        State schema: \(record.stateSchemaVersion.map(String.init) ?? "unknown")
        Database bytes: \(record.databaseBytes.map(String.init) ?? "unknown")
        Database SHA-256: \(record.databaseSHA256 ?? "unavailable")
        Verification: \(record.verificationMessage)

        """
    }

    private func render(_ catalog: StateBackupCatalog) -> String {
        var lines = ["Hostwright state backups", ""]
        if catalog.backups.isEmpty {
            lines.append("- none")
        } else {
            lines += catalog.backups.map {
                "- \($0.backupID) restorable=\($0.restorable) created=\($0.createdAt ?? "unknown") verification=\($0.verificationMessage)"
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func render(_ plan: StateRestorePlan) -> String {
        var lines = [
            "Hostwright state restore dry-run",
            "Backup ID: \(plan.backup.backupID)",
            "Current health: \(plan.currentHealth.rawValue)",
            "Effects:"
        ]
        lines += plan.effects.map { "- \($0)" }
        lines.append("Confirmation token: \(plan.confirmationToken)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func render(_ result: StateRestoreResult) -> String {
        let counts = result.clearedProjectionRows.keys.sorted()
            .map { "\($0)=\(result.clearedProjectionRows[$0] ?? 0)" }
            .joined(separator: ", ")
        return """
        Hostwright state restore complete
        Backup ID: \(result.backupID)
        Pre-restore backup ID: \(result.preRestoreBackupID ?? "none")
        Quarantined original: \(result.quarantinedDatabasePath ?? "none")
        Cleared projections: \(counts)
        Health: \(result.health.rawValue)

        """
    }

    private func render(_ plan: StateRepairPlan) -> String {
        let counts = plan.tables.keys.sorted()
            .map { "\($0)=\(plan.tables[$0] ?? 0)" }
            .joined(separator: ", ")
        return """
        Hostwright state repair dry-run
        Current health: \(plan.health.rawValue)
        Rebuildable projection rows: \(counts)
        Confirmation token: \(plan.confirmationToken)

        """
    }

    private func render(_ result: StateRepairResult) -> String {
        let counts = result.clearedRows.keys.sorted()
            .map { "\($0)=\(result.clearedRows[$0] ?? 0)" }
            .joined(separator: ", ")
        return """
        Hostwright state repair complete
        Pre-repair backup ID: \(result.preRepairBackupID)
        Cleared projection rows: \(counts)
        Health: \(result.health.rawValue)

        """
    }

    private func render(_ result: StateRecoveryResult) -> String {
        """
        Hostwright state recovery
        Recovered: \(result.recovered)
        Action: \(result.action)
        Health: \(result.health?.rawValue ?? "unknown")

        """
    }

    private func retentionPolicy(_ manifestPath: String) throws -> StateRetentionPolicy {
        let manifest = try ManifestValidator.validated(environment.readTextFile(manifestPath))
        guard let retention = manifest.retention else {
            throw StateMaintenanceError.unsafeCompaction(
                "the validated manifest does not declare a retention policy"
            )
        }
        let classes = Dictionary(uniqueKeysWithValues: retention.classes.map { key, value in
            (
                StateRetentionClass(rawValue: key.rawValue)!,
                StateRetentionClassPolicy(
                    maxAgeSeconds: value.maxAge,
                    maxRecords: value.maxRecords,
                    minimumRecords: value.minimumRecords
                )
            )
        })
        return StateRetentionPolicy(
            recoveryHorizonSeconds: retention.recoveryHorizon,
            maximumDatabaseBytes: UInt64(retention.maximumDatabaseBytes),
            targetDatabaseBytes: UInt64(retention.targetDatabaseBytes),
            classes: classes,
            holds: retention.holds.map {
                StateRetentionHold(
                    id: $0.id,
                    retentionClass: StateRetentionClass(rawValue: $0.retentionClass.rawValue)!,
                    selector: $0.selector,
                    reason: $0.reason,
                    expiresAt: $0.expiresAt
                )
            }
        )
    }

    private func render(_ report: StateRetentionStatus) -> String {
        var lines = [
            "Hostwright state retention",
            "Policy SHA-256: \(report.policySHA256)",
            "Database bytes: \(report.databaseBytes)",
            "Pressure: \(report.pressure.rawValue)",
            ""
        ]
        lines += report.classes.map {
            "- \($0.retentionClass.rawValue): available=\($0.producerAvailable) current=\($0.currentRecords) candidates=\($0.candidateRecords) held=\($0.heldRecords) recoveryCritical=\($0.recoveryCriticalRecords)"
        }
        lines += report.blockers.map { "Blocker: \($0)" }
        if let pending = report.pendingCompactionPlanSHA256 {
            lines.append("Pending compaction: \(pending)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func render(_ plan: StateCompactionPlan) -> String {
        var lines = [
            "Hostwright state compaction dry-run",
            "Evaluated at: \(plan.evaluatedAt)",
            "Policy SHA-256: \(plan.policySHA256)",
            "Database bytes: \(plan.databaseBytes)",
            "Pressure: \(plan.pressure.rawValue)",
            "Candidate records: \(plan.candidateRecords)",
            "Candidate bytes: \(plan.candidateBytes)",
            "Executable: \(plan.executable)"
        ]
        lines += plan.blockers.map { "Blocker: \($0)" }
        lines.append("Confirmation token: \(plan.confirmationToken)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func render(_ result: StateCompactionResult) -> String {
        let counts = result.deletedRecords.keys.sorted(by: { $0.rawValue < $1.rawValue })
            .map { "\($0.rawValue)=\(result.deletedRecords[$0] ?? 0)" }
            .joined(separator: ", ")
        return """
        Hostwright state compaction complete
        Plan SHA-256: \(result.planSHA256)
        Pre-compaction backup: \(result.preCompactionBackupID)
        Deleted records: \(counts)
        Database bytes: \(result.databaseBytesBefore) -> \(result.databaseBytesAfter)
        Integrity: \(result.integrityHealth.rawValue)
        Resumed: \(result.resumed)

        """
    }

    private func stateFailure(message: String, standardOutput: String) -> CLIRunResult {
        let exitCode = CLIExitCode.stateUnavailable
        let redacted = RuntimeRedactionPolicy.default.redact(message)
        let error = output == .json
            ? CLIJSON.error(code: .stateStoreUnavailable, message: redacted, exitCode: exitCode)
            : "\(HostwrightErrorCode.stateStoreUnavailable.rawValue): \(redacted)\n"
        return CLIRunResult(
            standardOutput: standardOutput,
            standardError: error,
            exitCode: exitCode.rawValue
        )
    }

    private func failure(code: HostwrightErrorCode, message: String) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: code)
        let redacted = RuntimeRedactionPolicy.default.redact(message)
        if output == .json {
            return CLIRunResult(
                standardError: CLIJSON.error(code: code, message: redacted, exitCode: exitCode),
                exitCode: exitCode.rawValue
            )
        }
        return CLIRunResult(
            standardError: "\(code.rawValue): \(redacted)\n",
            exitCode: exitCode.rawValue
        )
    }
}
