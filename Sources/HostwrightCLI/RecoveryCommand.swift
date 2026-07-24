import HostwrightCore
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

struct RecoveryCommandRunner {
    let stateStoreConfiguration: StateStoreConfiguration
    let action: RecoveryCLIAction
    let projectName: String?
    let output: CLIOutputFormat
    let environment: CLIEnvironment

    func run() -> CLIRunResult {
        switch action {
        case .inspect:
            inspect()
        case .resume(let groupID, let confirmationPlanSHA256, let timeoutSeconds):
            execute(
                action: .resume,
                groupID: groupID,
                confirmationPlanSHA256: confirmationPlanSHA256,
                timeoutSeconds: timeoutSeconds
            )
        case .rollback(let groupID, let confirmationPlanSHA256, let timeoutSeconds):
            execute(
                action: .rollback,
                groupID: groupID,
                confirmationPlanSHA256: confirmationPlanSHA256,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    private func inspect() -> CLIRunResult {
        do {
            let stateDatabasePath = stateStoreConfiguration.databasePath
            let store = SQLiteStateStore(configuration: stateStoreConfiguration)
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
                    lines.append(
                        "- \(group.updatedAt) \(group.plannedActionType) " +
                            "\(group.serviceName ?? "project") status=\(group.status.rawValue) " +
                            "checkpoint=\(group.checkpoint)"
                    )
                    lines.append("  group: \(group.id)")
                    lines.append("  plan: \(group.planHash)")
                    if group.lockOwner != nil || group.lockExpiresAt != nil {
                        lines.append("  lock: owner=\(RuntimeRedactionPolicy.default.redact(group.lockOwner ?? "unknown")) expiresAt=\(group.lockExpiresAt ?? "unknown")")
                    }
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

    private func execute(
        action: LifecyclePersistedRecoveryAction,
        groupID: String,
        confirmationPlanSHA256: String,
        timeoutSeconds: Int
    ) -> CLIRunResult {
        do {
            let store = SQLiteStateStore(configuration: stateStoreConfiguration)
            guard let group = try store.operationGroups.load(id: groupID) else {
                return failure(
                    HostwrightDiagnostic(
                        code: .stateStoreUnavailable,
                        message:
                            "Lifecycle operation group '\(groupID)' does not exist. " +
                            "No runtime mutation was attempted."
                    )
                )
            }
            if let projectName,
               group.projectID != "project-\(projectName)" {
                return failure(
                    HostwrightDiagnostic(
                        code: .confirmationMismatch,
                        message:
                            "Lifecycle operation group '\(groupID)' does not belong to project " +
                            "'\(projectName)'. No runtime mutation was attempted."
                    )
                )
            }

            let result = try LifecyclePersistedRecoveryDriver(
                environment: environment
            ).execute(
                LifecyclePersistedRecoveryRequest(
                    action: action,
                    groupID: groupID,
                    confirmationPlanSHA256: confirmationPlanSHA256,
                    stateStoreConfiguration: stateStoreConfiguration,
                    timeoutSeconds: timeoutSeconds
                )
            )
            if output == .json {
                return CLIRunResult(
                    standardOutput: CLIJSON.recoveryExecution(
                        action: action,
                        stateDatabasePath: stateStoreConfiguration.databasePath,
                        result: result
                    )
                )
            }
            let title = action == .resume ? "resume" : "rollback"
            let completed = result.completedNodeKeys.isEmpty
                ? "none"
                : result.completedNodeKeys.joined(separator: ",")
            return CLIRunResult(
                standardOutput: [
                    "Hostwright recovery \(title)",
                    "State DB: \(stateStoreConfiguration.databasePath)",
                    "Operation group: \(result.groupID)",
                    "Operation: \(result.operationID)",
                    "Plan: \(result.planSHA256)",
                    "Status: \(result.status.rawValue)",
                    "Checkpoint: \(result.checkpoint)",
                    "Completed nodes: \(completed)",
                    "Recovery: \(RuntimeRedactionPolicy.default.redact(result.recoveryHintRedacted))",
                    ""
                ].joined(separator: "\n")
            )
        } catch let error as LifecycleCommandRunnerError {
            return failure(error.diagnostic)
        } catch let error as LifecyclePersistedRecoveryError {
            switch error {
            case .invalidRequest(let message):
                return failure(
                    HostwrightDiagnostic(code: .commandUsage, message: message)
                )
            case .confirmationMismatch:
                return failure(
                    HostwrightDiagnostic(
                        code: .confirmationMismatch,
                        message:
                            "Recovery confirmation does not match the exact persisted " +
                            "lifecycle plan. No runtime mutation was attempted."
                    )
                )
            case .unavailable(let message):
                return failure(
                    HostwrightDiagnostic(code: .runtimeUnavailable, message: message)
                )
            case .safeHold(let hold):
                return safeHoldFailure(hold)
            }
        } catch let diagnostic as HostwrightDiagnostic {
            return failure(diagnostic)
        } catch let error as StateStoreError {
            return failure(
                HostwrightDiagnostic(
                    code: .stateStoreUnavailable,
                    message:
                        "\(RuntimeRedactionPolicy.default.redact(String(describing: error))). " +
                        "No runtime mutation was attempted."
                )
            )
        } catch let error as RuntimeAdapterError {
            return failure(
                HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "\(RuntimeRedactionPolicy.default.redact(String(describing: error))). " +
                        "Recovery did not report success."
                )
            )
        } catch {
            return failure(
                HostwrightDiagnostic(
                    code: .partialFailure,
                    message: RuntimeRedactionPolicy.default.redact(String(describing: error))
                )
            )
        }
    }

    private func failure(_ diagnostic: HostwrightDiagnostic) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: diagnostic.code)
        if output == .json {
            return CLIRunResult(
                standardError: CLIJSON.error(
                    code: diagnostic.code,
                    message: diagnostic.message,
                    exitCode: exitCode
                ),
                exitCode: exitCode.rawValue
            )
        }
        return CLIRunResult(
            standardError: "\(diagnostic.code.rawValue): \(diagnostic.message)\n",
            exitCode: exitCode.rawValue
        )
    }

    private func safeHoldFailure(
        _ hold: LifecycleRecoverySafeHold
    ) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: .partialFailure)
        let message =
            "\(RuntimeRedactionPolicy.default.redact(hold.reason)) " +
            "Recovery remains in safe hold."
        let affectedNodeKeys = hold.affectedNodeKeys.sorted()
        let operatorCommands = hold.operatorCommands.sorted()
        if output == .json {
            return CLIRunResult(
                standardError: CLIJSON.render([
                    "kind": "error",
                    "code": HostwrightErrorCode.partialFailure.rawValue,
                    "exitCode": Int(exitCode.rawValue),
                    "message": message,
                    "affectedNodeKeys": affectedNodeKeys,
                    "operatorCommands": operatorCommands
                ]),
                exitCode: exitCode.rawValue
            )
        }
        var lines = [
            "\(HostwrightErrorCode.partialFailure.rawValue): \(message)",
            "Affected nodes: \(affectedNodeKeys.isEmpty ? "none" : affectedNodeKeys.joined(separator: ","))",
            "Operator commands:"
        ]
        lines.append(
            contentsOf: operatorCommands.isEmpty
                ? ["- none"]
                : operatorCommands.map { "- \($0)" }
        )
        return CLIRunResult(
            standardError: lines.joined(separator: "\n") + "\n",
            exitCode: exitCode.rawValue
        )
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
