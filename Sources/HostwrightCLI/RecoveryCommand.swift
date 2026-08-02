import CryptoKit
import Foundation
import HostwrightCore
import HostwrightObservability
import HostwrightReconciler
import HostwrightRuntime
import HostwrightSecrets
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
                    let checkpoint = group.groupKind == "lifecycle-v1"
                        ? LifecycleMutationCheckpointRecord(
                            checkpoint: group.checkpoint
                        ) : nil
                    lines.append(
                        "- \(group.updatedAt) \(group.plannedActionType) " +
                            "\(group.serviceName ?? "project") status=\(group.status.rawValue) " +
                            "checkpoint=\(group.checkpoint)"
                    )
                    lines.append("  group: \(group.id)")
                    lines.append("  plan: \(group.planHash)")
                    if let checkpoint {
                        lines.append(
                            "  checkpoint-contract: v\(checkpoint.schemaVersion) " +
                                "class=\(checkpoint.classification.rawValue) " +
                                "recovery=\(checkpoint.recovery.rawValue)"
                        )
                    }
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
            HostwrightTraceContext.session?.attach(StateTraceSink(store: store))
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

            let request = LifecyclePersistedRecoveryRequest(
                action: action,
                groupID: groupID,
                confirmationPlanSHA256: confirmationPlanSHA256,
                stateStoreConfiguration: stateStoreConfiguration,
                timeoutSeconds: timeoutSeconds
            )
            let result: LifecycleSagaExecutionResult
            if group.groupKind == SecretPersistedRecoveryDriver.groupKind {
                result = try SecretPersistedRecoveryDriver(
                    environment: environment
                ).execute(request, sourceGroup: group)
            } else if group.groupKind == ImageOwnershipLedger.groupKind {
                result = try ImagePersistedRecoveryDriver(
                    environment: environment
                ).execute(request, sourceGroup: group)
            } else {
                result = try LifecyclePersistedRecoveryDriver(
                    environment: environment
                ).execute(request)
            }
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
        } catch let error as SecretStoreError {
            return failure(secretRecoveryDiagnostic(for: error))
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
                    "schemaVersion": hold.schemaVersion,
                    "code": HostwrightErrorCode.partialFailure.rawValue,
                    "reasonCode": hold.reasonCode.rawValue,
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
            "Reason: \(hold.reasonCode.rawValue)",
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

private struct SecretPersistedRecoveryDriver {
    static let groupKind = "secret-mutation"

    let environment: CLIEnvironment

    func execute(
        _ request: LifecyclePersistedRecoveryRequest,
        sourceGroup: OperationGroupRecord
    ) throws -> LifecycleSagaExecutionResult {
        guard HostwrightResourceUUID.isValid(request.groupID),
              request.groupID == sourceGroup.id,
              sourceGroup.groupKind == Self.groupKind,
              sourceGroup.projectID == nil,
              (1...RuntimeCommandTimeout.maximumSeconds).contains(
                  request.timeoutSeconds
              ) else {
            throw LifecyclePersistedRecoveryError.invalidRequest(
                "Secret recovery requires the exact secret-mutation group UUID and bounded timeout."
            )
        }
        guard sourceGroup.planHash == request.confirmationPlanSHA256 else {
            throw LifecyclePersistedRecoveryError.confirmationMismatch
        }

        let intent = try SecretRecoveryIntent.decode(
            group: sourceGroup
        )
        guard intent.planSHA256 == sourceGroup.planHash,
              sourceGroup.plannedActionType == intent.operation,
              sourceGroup.rollbackAvailable == (intent.operation == "create") else {
            throw LifecyclePersistedRecoveryError.confirmationMismatch
        }
        if request.action == .rollback,
           !sourceGroup.rollbackAvailable {
            throw LifecyclePersistedRecoveryError.unavailable(
                "This secret mutation has no value-safe inverse action."
            )
        }

        if sourceGroup.status == .succeeded {
            guard request.action == .resume else {
                throw LifecyclePersistedRecoveryError.unavailable(
                    "A completed secret mutation cannot be rolled back."
                )
            }
            return result(
                status: .alreadySucceeded,
                group: sourceGroup,
                checkpoint: sourceGroup.checkpoint,
                completedNodeKeys: [],
                hint: "The persisted secret mutation is already complete."
            )
        }
        if sourceGroup.status == .failed,
           sourceGroup.checkpoint == "keychain-recovery-compensated",
           request.action == .rollback {
            return result(
                status: .alreadySucceeded,
                group: sourceGroup,
                checkpoint: sourceGroup.checkpoint,
                completedNodeKeys: [],
                hint: "Exact Keychain compensation is already verified."
            )
        }

        let store = SQLiteStateStore(
            configuration: request.stateStoreConfiguration
        )
        try store.migrate()
        let activeGroup = try acquireRecoveryLease(
            group: sourceGroup,
            timeoutSeconds: request.timeoutSeconds,
            store: store
        )
        let mutationFence = try hostwrightAcquireExactOperationMutationFence(
            store: store,
            group: activeGroup
        )
        defer { mutationFence.release() }
        let manager = environment.secretManager()
        let observed = try observation(
            matching: intent.referenceSHA256,
            manager: manager
        )
        try store.operationGroups.recordCheckpoint(
            groupID: activeGroup.id,
            expectedFencingToken: activeGroup.fencingToken,
            checkpoint: "keychain-reobserved",
            verificationJSONRedacted: verificationJSON(
                intent: intent,
                observed: observed,
                status: "reobserved"
            ),
            updatedAt: hostwrightTimestamp()
        )

        switch request.action {
        case .resume:
            return try resume(
                intent: intent,
                observed: observed,
                group: activeGroup,
                manager: manager,
                store: store
            )
        case .rollback:
            return try rollback(
                intent: intent,
                observed: observed,
                group: activeGroup,
                manager: manager,
                store: store
            )
        }
    }

    private func resume(
        intent: SecretRecoveryIntent,
        observed: SecretMetadata?,
        group: OperationGroupRecord,
        manager: any SecretManager,
        store: SQLiteStateStore
    ) throws -> LifecycleSagaExecutionResult {
        if matchesTarget(intent: intent, observed: observed) {
            return try complete(
                status: .alreadySucceeded,
                terminalGroupStatus: .succeeded,
                checkpoint: "keychain-effect-verified",
                stepKey: "keychain-effect-reobserved",
                direction: .forward,
                intent: intent,
                observed: observed,
                group: group,
                store: store,
                hint: "The intended managed Keychain metadata is already verified."
            )
        }

        guard intent.operation == "delete",
              let expectedItemID = intent.expectedItemID,
              observed?.itemID == expectedItemID,
              observed?.version == intent.expectedVersion,
              let reference = observed?.reference else {
            try enterSafeHold(
                intent: intent,
                observed: observed,
                group: group,
                store: store,
                reason:
                    "The intended Keychain effect is not verified and secret bytes are not persisted for replay."
            )
        }

        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: "keychain-delete-resume-planned",
            verificationJSONRedacted: verificationJSON(
                intent: intent,
                observed: observed,
                status: "delete-resume-planned"
            ),
            updatedAt: hostwrightTimestamp()
        )
        do {
            try manager.delete(
                reference: reference,
                expectedItemID: expectedItemID
            )
        } catch {
            // The exact post-mutation observation below is authoritative. A
            // reported failure can still have completed the external effect.
        }
        let after = try observation(
            matching: intent.referenceSHA256,
            manager: manager
        )
        guard after == nil else {
            try enterSafeHold(
                intent: intent,
                observed: after,
                group: group,
                store: store,
                reason:
                    "The exact managed Keychain item remains after the confirmed delete recovery attempt."
            )
        }
        return try complete(
            status: .succeeded,
            terminalGroupStatus: .succeeded,
            checkpoint: "keychain-effect-verified",
            stepKey: "keychain-delete-resumed",
            direction: .forward,
            intent: intent,
            observed: nil,
            group: group,
            store: store,
            hint: "The resumed delete and exact managed-item absence are verified."
        )
    }

    private func rollback(
        intent: SecretRecoveryIntent,
        observed: SecretMetadata?,
        group: OperationGroupRecord,
        manager: any SecretManager,
        store: SQLiteStateStore
    ) throws -> LifecycleSagaExecutionResult {
        guard intent.operation == "create", group.rollbackAvailable else {
            try enterSafeHold(
                intent: intent,
                observed: observed,
                group: group,
                store: store,
                reason:
                    "This secret mutation has no value-safe inverse action."
            )
        }

        if observed == nil {
            return try complete(
                status: .compensated,
                terminalGroupStatus: .failed,
                checkpoint: "keychain-recovery-compensated",
                stepKey: "keychain-create-absence-verified",
                direction: .rollback,
                intent: intent,
                observed: nil,
                group: group,
                store: store,
                hint: "The managed Keychain create effect is absent; compensation is complete."
            )
        }
        guard let targetItemID = intent.targetItemID,
              observed?.itemID == targetItemID,
              observed?.version == intent.targetVersion,
              let reference = observed?.reference else {
            try enterSafeHold(
                intent: intent,
                observed: observed,
                group: group,
                store: store,
                reason:
                    "The managed Keychain metadata no longer matches the exact create effect."
            )
        }

        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: "keychain-create-compensation-planned",
            verificationJSONRedacted: verificationJSON(
                intent: intent,
                observed: observed,
                status: "compensation-planned"
            ),
            updatedAt: hostwrightTimestamp()
        )
        do {
            try manager.delete(
                reference: reference,
                expectedItemID: targetItemID
            )
        } catch {
            // Verify the external state before deciding whether compensation
            // occurred; never retry deletion blindly.
        }
        let after = try observation(
            matching: intent.referenceSHA256,
            manager: manager
        )
        guard after == nil else {
            try enterSafeHold(
                intent: intent,
                observed: after,
                group: group,
                store: store,
                reason:
                    "Exact Keychain create compensation could not be verified."
            )
        }
        return try complete(
            status: .compensated,
            terminalGroupStatus: .failed,
            checkpoint: "keychain-recovery-compensated",
            stepKey: "keychain-create-compensated",
            direction: .rollback,
            intent: intent,
            observed: nil,
            group: group,
            store: store,
            hint: "The exact managed Keychain create effect was removed and absence is verified."
        )
    }

    private func acquireRecoveryLease(
        group: OperationGroupRecord,
        timeoutSeconds: Int,
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        let now = hostwrightTimestamp()
        let owner = "hostwright-secret-recovery:\(UUID().uuidString.lowercased())"
        let expiry = hostwrightTimestampAdding(
            seconds: timeoutSeconds,
            to: now
        )
        switch group.status {
        case .interrupted:
            do {
                return try store.operationGroups.resumeInterrupted(
                    groupID: group.id,
                    expectedFencingToken: group.fencingToken,
                    lockOwner: owner,
                    lockExpiresAt: expiry,
                    updatedAt: now
                )
            } catch StateStoreError.invalidRecord(let message)
                where message == "Another operation with the same idempotency key is active." {
                throw SecretStoreError.concurrentMutation(
                    "Another mutation for the same managed secret is active."
                )
            }
        case .active:
            switch try store.operationGroups.reclaimExpiredActive(
                groupID: group.id,
                expectedPlanHash: group.planHash,
                expectedFencingToken: group.fencingToken,
                lockOwner: owner,
                lockExpiresAt: expiry,
                currentTimestamp: now
            ) {
            case .reclaimed(let reclaimed):
                return reclaimed
            case .activeUnexpired:
                throw LifecyclePersistedRecoveryError.unavailable(
                    "The exact secret mutation lease is still active."
                )
            }
        case .failed:
            throw LifecyclePersistedRecoveryError.unavailable(
                "A rejected secret mutation has no ambiguous external effect to recover."
            )
        case .succeeded:
            throw LifecyclePersistedRecoveryError.unavailable(
                "The secret mutation is already complete."
            )
        }
    }

    private func observation(
        matching referenceSHA256: String,
        manager: any SecretManager
    ) throws -> SecretMetadata? {
        let matches = try manager.listMetadata().filter {
            secretRecoverySHA256($0.reference.rawValue) == referenceSHA256
        }
        guard matches.count <= 1 else {
            throw LifecyclePersistedRecoveryError.safeHold(
                LifecycleRecoverySafeHold(
                    reason:
                        "More than one managed Keychain item matched the durable secret identity.",
                    affectedNodeKeys: ["keychain-effect"],
                    operatorCommands: [
                        "hostwright secret list --output json",
                        "hostwright recovery --output json"
                    ]
                )
            )
        }
        return matches.first
    }

    private func matchesTarget(
        intent: SecretRecoveryIntent,
        observed: SecretMetadata?
    ) -> Bool {
        switch intent.operation {
        case "create", "update":
            return observed?.itemID == intent.targetItemID &&
                observed?.version == intent.targetVersion
        case "delete":
            return observed == nil
        default:
            return false
        }
    }

    private func complete(
        status: LifecycleSagaExecutionStatus,
        terminalGroupStatus: OperationGroupStatus,
        checkpoint: String,
        stepKey: String,
        direction: OperationGroupStepDirection,
        intent: SecretRecoveryIntent,
        observed: SecretMetadata?,
        group: OperationGroupRecord,
        store: SQLiteStateStore,
        hint: String
    ) throws -> LifecycleSagaExecutionResult {
        let timestamp = hostwrightTimestamp()
        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: checkpoint,
            verificationJSONRedacted: verificationJSON(
                intent: intent,
                observed: observed,
                status: status.rawValue
            ),
            updatedAt: timestamp
        )
        try store.operationGroupSteps.append(
            OperationGroupStepRecord(
                id: HostwrightResourceUUID.generate(),
                groupID: group.id,
                stepKey: stepKey,
                direction: direction,
                plannedActionType: group.plannedActionType,
                serviceName: nil,
                resourceIdentifier: nil,
                stepIdempotencyKey: "\(group.planHash):\(direction.rawValue):\(stepKey)",
                status: .succeeded,
                startedAt: timestamp,
                updatedAt: timestamp,
                finishedAt: timestamp,
                lastErrorRedacted: nil,
                manualRecoveryHintRedacted: hint,
                metadataJSONRedacted: verificationJSON(
                    intent: intent,
                    observed: observed,
                    status: status.rawValue
                )
            ),
            expectedFencingToken: group.fencingToken
        )
        try store.operationGroups.finish(
            groupID: group.id,
            status: terminalGroupStatus,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted: hint,
            updatedAt: timestamp,
            metadataJSONRedacted: verificationJSON(
                intent: intent,
                observed: observed,
                status: status.rawValue
            )
        )
        return result(
            status: status,
            group: group,
            checkpoint: checkpoint,
            completedNodeKeys: [stepKey],
            hint: hint
        )
    }

    private func enterSafeHold(
        intent: SecretRecoveryIntent,
        observed: SecretMetadata?,
        group: OperationGroupRecord,
        store: SQLiteStateStore,
        reason: String
    ) throws -> Never {
        let timestamp = hostwrightTimestamp()
        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: "keychain-recovery-safe-hold",
            verificationJSONRedacted: verificationJSON(
                intent: intent,
                observed: observed,
                status: "safe-hold"
            ),
            updatedAt: timestamp
        )
        try store.operationGroups.finish(
            groupID: group.id,
            status: .interrupted,
            checkpoint: "keychain-recovery-safe-hold",
            manualRecoveryHintRedacted:
                "Inspect managed Keychain metadata, then resume the exact confirmed plan.",
            updatedAt: timestamp,
            metadataJSONRedacted: verificationJSON(
                intent: intent,
                observed: observed,
                status: "safe-hold"
            )
        )
        throw LifecyclePersistedRecoveryError.safeHold(
            LifecycleRecoverySafeHold(
                reason: reason,
                affectedNodeKeys: ["keychain-effect"],
                operatorCommands: [
                    "hostwright secret list --output json",
                    "hostwright recovery --output json"
                ]
            )
        )
    }

    private func verificationJSON(
        intent: SecretRecoveryIntent,
        observed: SecretMetadata?,
        status: String
    ) -> String {
        jsonPayload([
            "observedItemID": observed?.itemID.uuidString.lowercased()
                as Any? ?? NSNull(),
            "observedVersion": observed?.version as Any? ?? NSNull(),
            "secretReferenceSHA256": intent.referenceSHA256,
            "status": status
        ])
    }

    private func result(
        status: LifecycleSagaExecutionStatus,
        group: OperationGroupRecord,
        checkpoint: String,
        completedNodeKeys: [String],
        hint: String
    ) -> LifecycleSagaExecutionResult {
        LifecycleSagaExecutionResult(
            status: status,
            operationID: group.operationID,
            groupID: group.id,
            planSHA256: group.planHash,
            checkpoint: checkpoint,
            completedNodeKeys: completedNodeKeys,
            recoveryHintRedacted: hint
        )
    }
}

private struct SecretRecoveryIntent {
    let operation: String
    let referenceSHA256: String
    let expectedItemID: UUID?
    let targetItemID: UUID?
    let expectedVersion: Int?
    let targetVersion: Int?

    var planSHA256: String {
        secretRecoverySHA256([
            operation,
            referenceSHA256,
            expectedItemID.map { $0.uuidString.lowercased() } ?? "none",
            targetItemID.map { $0.uuidString.lowercased() } ?? "none",
            expectedVersion.map(String.init) ?? "none",
            targetVersion.map(String.init) ?? "none"
        ].joined(separator: "\n"))
    }

    static func decode(
        group: OperationGroupRecord
    ) throws -> SecretRecoveryIntent {
        guard let data = group.intentJSONRedacted.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(object.keys) == Set([
                  "expectedItemID",
                  "expectedVersion",
                  "secretReferenceSHA256",
                  "targetItemID",
                  "targetVersion"
              ]),
              let referenceSHA256 = object["secretReferenceSHA256"] as? String,
              referenceSHA256.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil,
              let expectedItemID = optionalItemID(
                  object["expectedItemID"]
              ),
              let expectedVersion = optionalVersion(
                  object["expectedVersion"]
              ),
              let targetItemID = optionalItemID(
                  object["targetItemID"]
              ),
              let targetVersion = optionalVersion(
                  object["targetVersion"]
              ) else {
            throw LifecyclePersistedRecoveryError.confirmationMismatch
        }

        let intent = SecretRecoveryIntent(
            operation: group.plannedActionType,
            referenceSHA256: referenceSHA256,
            expectedItemID: expectedItemID,
            targetItemID: targetItemID,
            expectedVersion: expectedVersion,
            targetVersion: targetVersion
        )
        switch intent.operation {
        case "create":
            guard intent.expectedItemID == nil,
                  intent.expectedVersion == nil,
                  intent.targetItemID != nil,
                  intent.targetVersion == 1 else {
                throw LifecyclePersistedRecoveryError.confirmationMismatch
            }
        case "update":
            guard let expectedItemID = intent.expectedItemID,
                  intent.targetItemID == expectedItemID,
                  let expected = intent.expectedVersion,
                  expected < Int.max,
                  intent.targetVersion == expected + 1 else {
                throw LifecyclePersistedRecoveryError.confirmationMismatch
            }
        case "delete":
            guard intent.expectedItemID != nil,
                  intent.expectedVersion != nil,
                  intent.targetItemID == nil,
                  intent.targetVersion == nil else {
                throw LifecyclePersistedRecoveryError.confirmationMismatch
            }
        default:
            throw LifecyclePersistedRecoveryError.confirmationMismatch
        }
        return intent
    }

    private static func optionalItemID(_ value: Any?) -> UUID?? {
        if value is NSNull {
            return .some(nil)
        }
        guard let rawValue = value as? String,
              let itemID = UUID(uuidString: rawValue),
              itemID.uuidString.lowercased() == rawValue else {
            return nil
        }
        return .some(itemID)
    }

    private static func optionalVersion(_ value: Any?) -> Int?? {
        if value is NSNull {
            return .some(nil)
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let integer = number.intValue
        guard integer >= 1,
              number.doubleValue == Double(integer) else {
            return nil
        }
        return .some(integer)
    }
}

private func secretRecoverySHA256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func secretRecoveryDiagnostic(
    for error: SecretStoreError
) -> HostwrightDiagnostic {
    let code: HostwrightErrorCode
    switch error {
    case .invalidReference, .invalidValue, .corruptedMetadata:
        code = .secretInvalid
    case .backendUnavailable, .interactionNotAllowed:
        code = .secretUnavailable
    case .notFound:
        code = .secretNotFound
    case .duplicate, .unmanaged, .concurrentMutation:
        code = .secretConflict
    case .permissionDenied:
        code = .secretDenied
    case .cancelled:
        code = .secretCancelled
    case .partialEffect:
        code = .secretPartialEffect
    }
    return HostwrightDiagnostic(
        code: code,
        message: RuntimeRedactionPolicy.default.redact(error.description)
    )
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
