import HostwrightCore
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

extension ApplyCommandRunner {
    func failure(code: HostwrightErrorCode, message: String) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: code)
        let redactedMessage = RuntimeRedactionPolicy.default.redact(message)
        return CLIRunResult(standardError: "\(code.rawValue): \(redactedMessage)\n", exitCode: exitCode.rawValue)
    }

    func activeOperationConflictMessage(
        _ group: OperationGroupRecord,
        hasRecordedIntent: Bool
    ) -> String {
        let owner = RuntimeRedactionPolicy.default.redact(group.lockOwner ?? "unknown")
        let expiry = group.lockExpiresAt ?? "unknown"
        let recovery: String
        if hasRecordedIntent {
            recovery = "An operation intent is recorded, so automatic retry remains blocked after expiry until recovery and the exact runtime state are inspected."
        } else {
            recovery = "If the prior process was interrupted, retry after lease expiry; acquisition will mark the expired group interrupted."
        }
        return "Operation group with the same idempotency key is already active at checkpoint \(group.checkpoint), owner \(owner); lease expires at \(expiry). No mutation was attempted. \(recovery) Run recovery --state-db <path> to inspect manual recovery guidance."
    }

    func blockingOperation(store: SQLiteStateStore, idempotencyKey: String) throws -> OperationRecord? {
        guard let latest = try store.operations.latest(idempotencyKey: idempotencyKey) else {
            return nil
        }

        switch latest.status {
        case .planned, .recorded:
            let group = try store.operationGroups.latest(groupIdempotencyKey: idempotencyKey)
            // This checkpoint is written only before RuntimeAdapter execution begins.
            if group?.status == .interrupted,
               group?.checkpoint == Self.preRuntimeStateIncompleteCheckpoint {
                return nil
            }
            return latest
        case .succeeded:
            return latest
        case .failed, .abandoned:
            return nil
        }
    }

    func recordManagedStartAttempt(
        store: SQLiteStateStore,
        action: PlannedAction,
        desiredService: DesiredRuntimeService,
        projectID: String,
        timestamp: String,
        outcome: String
    ) throws {
        guard action.executionAvailability == .availableForStartManagedService else {
            if action.executionAvailability != .availableForRestartManagedService {
                return
            }
            return try recordManagedRecoveryAttempt(
                store: store,
                action: action,
                desiredService: desiredService,
                projectID: projectID,
                timestamp: timestamp,
                outcome: outcome
            )
        }

        try recordManagedRecoveryAttempt(
            store: store,
            action: action,
            desiredService: desiredService,
            projectID: projectID,
            timestamp: timestamp,
            outcome: outcome
        )
    }

    func recordManagedRecoveryAttempt(
        store: SQLiteStateStore,
        action: PlannedAction,
        desiredService: DesiredRuntimeService,
        projectID: String,
        timestamp: String,
        outcome: String
    ) throws {
        guard action.executionAvailability == .availableForStartManagedService ||
              action.executionAvailability == .availableForRestartManagedService else {
            return
        }

        let previous = try store.restartPolicies.load(projectID: projectID, serviceName: action.identity.serviceName)
        let maxAttempts = previous?.maxAttempts ?? RestartPolicyStateDefaults.maxAttempts
        let backoffSeconds = previous?.backoffSeconds ?? RestartPolicyStateDefaults.backoffSeconds
        let didFail = outcome == "failed"
        let attemptCount = didFail ? (previous?.attemptCount ?? 0) + 1 : 0
        let status: RestartPolicyStateStatus
        if didFail {
            status = attemptCount >= maxAttempts ? .crashLoopBlocked : .backingOff
        } else {
            status = .active
        }
        let backoffUntil = status == .backingOff ? hostwrightTimestampAdding(seconds: backoffSeconds, to: timestamp) : nil

        try store.restartPolicies.upsert(
            RestartPolicyStateRecord(
                id: hostwrightUniqueID(prefix: "restart-policy"),
                projectID: projectID,
                serviceName: action.identity.serviceName,
                policy: desiredService.restartPolicy,
                status: status,
                attemptCount: attemptCount,
                maxAttempts: maxAttempts,
                backoffSeconds: backoffSeconds,
                backoffUntil: backoffUntil,
                lastFailureAt: didFail ? timestamp : nil,
                updatedAt: timestamp,
                metadataJSONRedacted: jsonPayload([
                    "outcome": outcome,
                    "planAction": action.kind.rawValue,
                    "operatorActionRequired": status == .crashLoopBlocked
                ])
            )
        )

        let eventType: String
        let severity: StateEventSeverity
        let message: String
        switch status {
        case .active:
            eventType = "restart.policy.active"
            severity = .info
            message = "\(managedRestartSentenceLabel(for: action)) succeeded for \(action.identity.displayName); restart attempt budget is reset."
        case .crashLoopBlocked:
            eventType = "restart.policy.crash-loop-blocked"
            severity = .error
            message = "\(managedRestartSentenceLabel(for: action)) attempts reached \(attemptCount)/\(maxAttempts); operator action is required before another attempt."
        case .backingOff:
            eventType = "restart.policy.backoff"
            severity = .warning
            message = "\(managedRestartSentenceLabel(for: action)) attempt \(attemptCount)/\(maxAttempts) failed; restart backoff active until \(backoffUntil ?? "operator reset")."
        case .operatorHold:
            eventType = "restart.policy.operator-hold"
            severity = .warning
            message = "Managed start is held by operator policy."
        case .manualDisabled:
            eventType = "restart.policy.manual-disabled"
            severity = .warning
            message = "Managed start is disabled by restart policy."
        }

        try store.events.append([
            EventRecord(
                id: hostwrightUniqueID(prefix: "event-restart-policy"),
                timestamp: timestamp,
                severity: severity,
                type: eventType,
                source: "hostwright-cli",
                projectID: projectID,
                serviceName: action.identity.serviceName,
                runtimeAdapter: nil,
                message: message,
                payloadJSONRedacted: jsonPayload([
                    "attemptCount": attemptCount,
                    "backoffUntil": backoffUntil ?? "",
                    "maxAttempts": maxAttempts,
                    "outcome": outcome,
                    "status": status.rawValue
                ])
            )
        ])
    }

    func validateManagedRestartGate(
        action: PlannedAction,
        desiredService: DesiredRuntimeService,
        observed: ObservedRuntimeState,
        store: SQLiteStateStore,
        projectID: String,
        currentTimestamp: String
    ) throws -> String? {
        guard desiredService.restartPolicy.allowsManagedStart else {
            return "Managed restart requires a restart policy that allows Hostwright-managed recovery."
        }

        let observedMatches = observed.services.filter {
            $0.identity == action.identity && $0.resourceIdentifier == action.resourceIdentifier
        }
        guard observedMatches.count == 1, let observedService = observedMatches.first else {
            return "Managed restart requires exactly one observed service for \(action.identity.displayName)."
        }
        guard observedService.lifecycleState == .running else {
            return "Managed restart requires observed running state for \(action.identity.displayName)."
        }
        guard observedService.healthState == .unhealthy else {
            return "Managed restart is available only for unhealthy running services."
        }
        guard let healthCheck = desiredService.healthCheck else {
            return "Managed restart requires a configured health check for \(action.identity.displayName)."
        }
        let freshHealth = try hostwrightFreshHealthResult(
            store: store,
            projectID: projectID,
            serviceName: action.identity.serviceName,
            healthCheck: healthCheck,
            currentTimestamp: currentTimestamp
        )
        guard freshHealth?.status == .unhealthy else {
            return "Managed restart requires a fresh persisted unhealthy health result for \(action.identity.displayName)."
        }

        return nil
    }

    func validateManagedOwnershipGate(
        action: PlannedAction,
        observed: ObservedRuntimeState,
        store: SQLiteStateStore,
        projectID: String,
        runtimeAdapter: String
    ) throws -> String? {
        let observedMatches = observed.services.filter {
            $0.identity == action.identity && $0.resourceIdentifier == action.resourceIdentifier
        }
        guard observedMatches.count == 1 else {
            return "Managed lifecycle mutation requires exactly one observed service with exact identifier \(action.resourceIdentifier)."
        }

        let ownership = try store.ownership.loadAll().first { record in
            let identityBindingMatches = (record.identityVersion == 1 &&
                action.resourceIdentifier == action.identity.legacyManagedResourceIdentifier) ||
                (record.identityVersion == RuntimeManagedResourceIdentity.currentVersion &&
                    action.resourceIdentifier == action.identity.managedResourceIdentifier)
            return record.resourceType == "container" &&
            record.resourceIdentifier == action.resourceIdentifier &&
            record.projectID == projectID &&
            record.serviceName == action.identity.serviceName &&
            record.runtimeAdapter == runtimeAdapter &&
            identityBindingMatches
        }
        guard ownership != nil else {
            return "Managed lifecycle mutation requires a canonical Hostwright ownership record for exact container \(action.resourceIdentifier)."
        }
        return nil
    }

    func intentEventType(for action: PlannedAction) -> String {
        switch action.executionAvailability {
        case .availableForCreateMissingService:
            return "apply.create-intent-recorded"
        case .availableForStartManagedService:
            return "apply.start-intent-recorded"
        case .availableForRestartManagedService:
            return "apply.restart-intent-recorded"
        case .unavailable:
            return "apply.intent-recorded"
        }
    }

    func successEventType(for action: PlannedAction) -> String {
        switch action.executionAvailability {
        case .availableForCreateMissingService:
            return "apply.created-service"
        case .availableForStartManagedService:
            return "apply.started-service"
        case .availableForRestartManagedService:
            return "apply.restarted-service"
        case .unavailable:
            return "apply.succeeded"
        }
    }

    func operationGroup(
        id: String,
        operationID: String,
        action: PlannedAction,
        idempotencyKey: String,
        planHash: String,
        projectID: String,
        timestamp: String,
        status: OperationGroupStatus,
        checkpoint: String,
        lockOwner: String?,
        lockExpiresAt: String?,
        manualRecoveryHint: String,
        runtimeAdapter: String,
        mutationContext: RuntimeMutationContext
    ) -> OperationGroupRecord {
        return OperationGroupRecord(
            id: id,
            operationID: operationID,
            groupKind: "apply",
            projectID: projectID,
            serviceName: action.identity.serviceName,
            plannedActionType: action.kind.rawValue,
            status: status,
            groupIdempotencyKey: idempotencyKey,
            planHash: planHash,
            checkpoint: checkpoint,
            lockOwner: lockOwner,
            lockExpiresAt: lockExpiresAt,
            rollbackAvailable: false,
            manualRecoveryHintRedacted: manualRecoveryHint,
            createdAt: timestamp,
            updatedAt: timestamp,
            metadataJSONRedacted: jsonPayload([
                "executionAvailability": action.executionAvailability.rawValue,
                "identity": action.identity.displayName,
                "resourceIdentifier": action.resourceIdentifier,
                "rollback": "unsupported"
            ]),
            fencingToken: mutationContext.fencingToken,
            intentJSONRedacted: jsonPayload([
                "action": action.kind.rawValue,
                "planHash": planHash,
                "projectID": projectID,
                "projectGeneration": mutationContext.projectGeneration,
                "projectResourceUUID": mutationContext.projectResourceUUID,
                "provider": runtimeAdapter,
                "providerAPIVersion": HostwrightContractVersions.runtimeProviderAPI,
                "providerGeneration": mutationContext.providerGeneration,
                "resourceIdentifier": action.resourceIdentifier,
                "resourceGeneration": mutationContext.resourceGeneration,
                "resourceUUID": mutationContext.resourceUUID
            ]),
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: jsonPayload([
                "postcondition": "exact runtime observation",
                "status": "pending"
            ])
        )
    }

    func finishOperationGroup(
        store: SQLiteStateStore,
        groupID: String,
        status: OperationGroupStatus,
        checkpoint: String,
        action: PlannedAction,
        timestamp: String,
        metadata: [String: Any]
    ) throws {
        try store.operationGroups.finish(
            groupID: groupID,
            status: status,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted: manualRecoveryHint(status: status, checkpoint: checkpoint, action: action),
            updatedAt: timestamp,
            metadataJSONRedacted: jsonPayload(metadata)
        )
    }

    func recordRollbackUnsupportedStep(
        store: SQLiteStateStore,
        groupID: String,
        action: PlannedAction,
        idempotencyKey: String,
        timestamp: String
    ) throws {
        try recordOperationGroupStep(
            store: store,
            groupID: groupID,
            action: action,
            stepKey: "rollback",
            direction: .rollback,
            status: .unsupported,
            idempotencyKey: idempotencyKey,
            timestamp: timestamp,
            resourceIdentifier: action.resourceIdentifier,
            error: nil,
            hint: "Rollback is unavailable for \(action.identity.displayName) because no safe inverse operation is proven. Use status, events, logs, and manual inspection before retrying."
        )
    }

    func recordOperationGroupStep(
        store: SQLiteStateStore,
        groupID: String,
        action: PlannedAction,
        stepKey: String,
        direction: OperationGroupStepDirection,
        status: OperationGroupStepStatus,
        idempotencyKey: String,
        timestamp: String,
        resourceIdentifier: String?,
        error: String?,
        hint: String
    ) throws {
        try store.operationGroupSteps.append(
            OperationGroupStepRecord(
                id: hostwrightUniqueID(prefix: "operation-step"),
                groupID: groupID,
                stepKey: stepKey,
                direction: direction,
                plannedActionType: action.kind.rawValue,
                serviceName: action.identity.serviceName,
                resourceIdentifier: resourceIdentifier,
                stepIdempotencyKey: "\(idempotencyKey):\(direction.rawValue):\(stepKey)",
                status: status,
                startedAt: status == .started ? timestamp : nil,
                updatedAt: timestamp,
                finishedAt: status == .succeeded || status == .failed || status == .unsupported ? timestamp : nil,
                lastErrorRedacted: error,
                manualRecoveryHintRedacted: hint,
                metadataJSONRedacted: jsonPayload([
                    "identity": action.identity.displayName,
                    "rollback": direction == .rollback ? "unsupported" : "not-attempted",
                    "status": status.rawValue
                ])
            )
        )
    }

    func manualRecoveryHint(status: OperationGroupStatus, checkpoint: String, action: PlannedAction) -> String {
        switch status {
        case .active:
            return "Apply operation for \(action.identity.displayName) is active at checkpoint \(checkpoint). If the process was interrupted, inspect the current runtime state before retrying."
        case .succeeded:
            return "Apply operation for \(action.identity.displayName) completed. No manual recovery is required. Rollback remains unavailable."
        case .failed:
            return "Apply operation for \(action.identity.displayName) failed at checkpoint \(checkpoint). Recovery is manual: inspect status, events, logs, and the exact Hostwright-owned resource before retrying with a fresh confirmed plan."
        case .interrupted:
            return "Apply operation for \(action.identity.displayName) reached checkpoint \(checkpoint), but state persistence did not complete. Recovery is manual; Hostwright will not roll back automatically."
        }
    }

    func recordRestartRecoveryIfNeeded(
        store: SQLiteStateStore,
        action: PlannedAction,
        operationID: String,
        planHash: String,
        projectID: String,
        timestamp: String,
        status: RestartRecoveryStatus
    ) throws {
        guard action.executionAvailability == .availableForRestartManagedService else {
            return
        }

        try store.restartRecovery.append(
            RestartRecoveryRecord(
                id: hostwrightUniqueID(prefix: "restart-recovery"),
                operationID: operationID,
                projectID: projectID,
                serviceName: action.identity.serviceName,
                resourceIdentifier: action.resourceIdentifier,
                planHash: planHash,
                status: status,
                completedStepsJSONRedacted: completedStepsJSON(for: status),
                manualRecoveryHintRedacted: manualRecoveryHint(for: status, identity: action.identity),
                createdAt: timestamp,
                updatedAt: timestamp,
                metadataJSONRedacted: jsonPayload([
                    "planAction": action.kind.rawValue,
                    "status": status.rawValue
                ])
            )
        )
    }

    func completedStepsJSON(for status: RestartRecoveryStatus) -> String {
        switch status {
        case .prepared, .failed:
            return #"[]"#
        case .stopSucceeded:
            return #"["stop"]"#
        case .succeeded:
            return #"["stop","start"]"#
        }
    }

    func manualRecoveryHint(for status: RestartRecoveryStatus, identity: RuntimeServiceIdentity) -> String {
        switch status {
        case .prepared:
            return "Managed restart prepared for \(identity.displayName). If interrupted before runtime mutation, rerun apply with a fresh plan."
        case .stopSucceeded:
            return "Managed restart stopped \(identity.displayName). If start does not complete, inspect the exact Hostwright-owned container before retrying."
        case .succeeded:
            return "Managed restart completed for \(identity.displayName). No manual recovery is required."
        case .failed:
            return "Managed restart failed or was interrupted for \(identity.displayName). Inspect the exact Hostwright-owned container; if it is stopped, review logs and rerun apply only after confirming the current plan."
        }
    }

    func managedRestartSentenceLabel(for action: PlannedAction) -> String {
        action.executionAvailability == .availableForRestartManagedService ? "Managed restart" : "Managed start"
    }

    func restartStopSucceededBeforeFailure(_ error: Error) -> Bool {
        guard let runtimeError = error as? RuntimeAdapterError else {
            return false
        }
        if case .managedRestartStartFailedAfterStop = runtimeError {
            return true
        }
        return false
    }
}
