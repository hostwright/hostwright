import HostwrightCore
import HostwrightRuntime
import HostwrightState

struct RecoveryCommandRunner {
    let stateDatabasePath: String
    let projectName: String?
    let output: CLIOutputFormat

    func run() -> CLIRunResult {
        do {
            let configuration = StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
            try configuration.validate()
            let store = SQLiteStateStore(configuration: configuration)
            let projectID = projectName.map { "project-\($0)" }
            let groups = try store.operationGroups.loadAll()
                .filter { group in projectID == nil || group.projectID == projectID }
                .map { $0.redacted() }
            var records = try groups.map { group in
                RecoveryRecord(
                    group: group,
                    steps: try store.operationGroupSteps.load(groupID: group.id).map { $0.redacted() }
                )
            }
            let groupedOperationIDs = Set(groups.map(\.operationID))
            let legacyRestartRecords = try store.restartRecovery.loadAll()
                .filter { record in
                    (projectID == nil || record.projectID == projectID) && !groupedOperationIDs.contains(record.operationID)
                }
                .map { $0.redacted() }
            records.append(contentsOf: legacyRestartRecords.map(RecoveryRecord.legacyRestart))

            if output == .json {
                return CLIRunResult(standardOutput: CLIJSON.recovery(stateDatabasePath: stateDatabasePath, projectName: projectName, records: records))
            }

            var lines = [
                "Hostwright recovery",
                "State DB: \(stateDatabasePath)"
            ]
            if let projectName {
                lines.append("Project: \(projectName)")
            }
            lines.append("")

            if records.isEmpty {
                lines.append("- none")
            } else {
                for record in records {
                    let group = record.group
                    let mode = recoveryMode(for: group)
                    lines.append("- \(group.updatedAt) \(group.plannedActionType) \(group.serviceName ?? "project") status=\(group.status.rawValue) checkpoint=\(group.checkpoint)")
                    lines.append("  recovery: automatic=\(mode.automatic) manual=\(mode.manual) rollback=\(mode.rollback)")
                    lines.append("  hint: \(RuntimeRedactionPolicy.default.redact(group.manualRecoveryHintRedacted))")
                    for step in record.steps {
                        lines.append("  step: \(step.direction.rawValue)/\(step.stepKey) status=\(step.status.rawValue) hint=\(RuntimeRedactionPolicy.default.redact(step.manualRecoveryHintRedacted))")
                    }
                }
            }
            lines.append("")
            return CLIRunResult(standardOutput: lines.joined(separator: "\n"))
        } catch {
            let exitCode = CLIExitCode.stateUnavailable
            let message = RuntimeRedactionPolicy.default.redact(String(describing: error))
            if output == .json {
                return CLIRunResult(standardError: CLIJSON.error(code: .stateStoreUnavailable, message: message, exitCode: exitCode), exitCode: exitCode.rawValue)
            }
            return CLIRunResult(standardError: "\(HostwrightErrorCode.stateStoreUnavailable.rawValue): \(message)\n", exitCode: exitCode.rawValue)
        }
    }
}

struct RecoveryRecord: Equatable, Sendable {
    let group: OperationGroupRecord
    let steps: [OperationGroupStepRecord]

    static func legacyRestart(_ record: RestartRecoveryRecord) -> RecoveryRecord {
        let groupStatus: OperationGroupStatus
        let stepStatus: OperationGroupStepStatus
        let stepKey: String
        switch record.status {
        case .prepared:
            groupStatus = .interrupted
            stepStatus = .planned
            stepKey = "restart-prepared"
        case .stopSucceeded:
            groupStatus = .failed
            stepStatus = .succeeded
            stepKey = "restart-stop"
        case .succeeded:
            groupStatus = .succeeded
            stepStatus = .succeeded
            stepKey = "runtime-execute"
        case .failed:
            groupStatus = .failed
            stepStatus = .failed
            stepKey = "runtime-execute"
        }

        let group = OperationGroupRecord(
            id: "legacy-restart-\(record.id)",
            operationID: record.operationID,
            groupKind: "legacy-restart",
            projectID: record.projectID,
            serviceName: record.serviceName,
            plannedActionType: "restartManagedService",
            status: groupStatus,
            groupIdempotencyKey: "\(record.planHash):restartManagedService:\(record.serviceName):legacy:\(record.operationID)",
            planHash: record.planHash,
            checkpoint: "legacy-\(record.status.rawValue)",
            lockOwner: nil,
            lockExpiresAt: nil,
            rollbackAvailable: false,
            manualRecoveryHintRedacted: record.manualRecoveryHintRedacted,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            metadataJSONRedacted: record.metadataJSONRedacted
        )
        let step = OperationGroupStepRecord(
            id: "legacy-step-\(record.id)",
            groupID: group.id,
            stepKey: stepKey,
            direction: .forward,
            plannedActionType: "restartManagedService",
            serviceName: record.serviceName,
            resourceIdentifier: record.resourceIdentifier,
            stepIdempotencyKey: "\(group.groupIdempotencyKey):forward:\(stepKey)",
            status: stepStatus,
            startedAt: nil,
            updatedAt: record.updatedAt,
            finishedAt: stepStatus == .planned ? nil : record.updatedAt,
            lastErrorRedacted: nil,
            manualRecoveryHintRedacted: record.manualRecoveryHintRedacted,
            metadataJSONRedacted: record.completedStepsJSONRedacted
        )
        return RecoveryRecord(group: group.redacted(), steps: [step.redacted()])
    }
}

func recoveryMode(for group: OperationGroupRecord) -> (automatic: String, manual: String, rollback: String) {
    switch group.status {
    case .succeeded:
        return ("none-required", "not-required", group.rollbackAvailable ? "available" : "unsupported")
    case .active:
        return ("none", "inspect-active-operation", group.rollbackAvailable ? "available" : "unsupported")
    case .failed:
        return ("none", "required", group.rollbackAvailable ? "available" : "unsupported")
    case .interrupted:
        return ("none", "required-interrupted", group.rollbackAvailable ? "available" : "unsupported")
    }
}
