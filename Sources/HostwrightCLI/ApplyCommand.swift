import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightSecrets
import HostwrightState

struct ApplyCommandRunner {
    let manifestPath: String
    let stateDatabasePath: String
    let confirmedPlanHash: String
    let environment: CLIEnvironment

    func run() -> CLIRunResult {
        do {
            let configuration = StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
            try configuration.validate()

            let manifestText = try environment.readTextFile(manifestPath)
            let manifest = try ManifestValidator.validated(manifestText)
            let mapping = ManifestRuntimeMapper.map(manifest)
            let store = SQLiteStateStore(path: configuration.databasePath)
            try store.migrate()
            let timestamp = hostwrightTimestamp()
            let projectName = mapping.desiredState.projectName
            let projectID = "project-\(projectName)"
            let observationDesiredState = try hostwrightDesiredStateWithOwnershipHints(
                mapping.desiredState,
                store: store,
                projectID: projectID
            )
            let restartPolicyStates = try hostwrightRestartPolicyStateMap(store: store, projectID: projectID, projectName: projectName)
            let adapter = environment.runtimeAdapter()
            let observed: ObservedRuntimeState
            do {
                observed = try waitForAsync {
                    try await adapter.observe(desiredState: observationDesiredState)
                }
            } catch {
                return failure(code: .runtimeUnavailable, message: "Runtime observation failed: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))")
            }
            let observedForPlanning = try hostwrightPlanningObservedState(
                observed: observed,
                desiredState: mapping.desiredState,
                store: store,
                projectID: projectID,
                currentTimestamp: timestamp
            )
            guard let observedRuntimeAdapter = observedForPlanning.adapterMetadata?.adapterName,
                  !observedRuntimeAdapter.isEmpty
            else {
                return failure(
                    code: .runtimeUnavailable,
                    message: "Runtime observation did not include adapter metadata. No mutation was attempted."
                )
            }
            let plan = ReconciliationPlanner().plan(
                manifest: manifest,
                observedState: observedForPlanning,
                restartPolicyStates: restartPolicyStates,
                currentTimestamp: timestamp
            )

            guard plan.planHash == confirmedPlanHash else {
                return failure(
                    code: .confirmationMismatch,
                    message: "Confirmed plan hash does not match current observed plan. expected=\(plan.planHash) provided=\(confirmedPlanHash)\n\n\(PlanRenderer.render(plan))"
                )
            }

            guard !plan.includesBlockers else {
                return failure(
                    code: .unsafeExposure,
                    message: "Current plan has blocker issues. No mutation was attempted.\n\n\(PlanRenderer.render(plan))"
                )
            }

            let executableActions = plan.actions.filter {
                $0.executionAvailability == .availableForCreateMissingService ||
                $0.executionAvailability == .availableForStartManagedService ||
                $0.executionAvailability == .availableForRestartManagedService
            }
            guard !executableActions.isEmpty else {
                return failure(
                    code: .runtimeMutationNotImplemented,
                    message: "No executable createMissingService, startManagedService, or restartManagedService action exists in the current plan. No mutation was attempted.\n\n\(PlanRenderer.render(plan))"
                )
            }
            guard executableActions.count == 1, let action = executableActions.first else {
                return failure(
                    code: .commandUsage,
                    message: "Apply supports exactly one executable action. Current executable action count: \(executableActions.count). No mutation was attempted.\n\n\(PlanRenderer.render(plan))"
                )
            }

            let desiredByIdentity = Dictionary(uniqueKeysWithValues: mapping.desiredState.services.map { ($0.identity, $0) })
            let desiredService = desiredByIdentity[action.identity]
            guard let desiredService else {
                return failure(code: .runtimeMutationNotImplemented, message: "Could not find desired service for \(action.identity.displayName). No mutation was attempted.")
            }

            let idempotencyKey = "\(plan.planHash):\(action.kind.rawValue):\(action.identity.displayName)"
            if let existingOperation = try blockingOperation(store: store, idempotencyKey: idempotencyKey) {
                return failure(
                    code: .commandUsage,
                    message: "Operation with the same idempotency key is already \(existingOperation.status.rawValue). No mutation was attempted."
                )
            }

            let executionDesiredService: DesiredRuntimeService
            if action.executionAvailability == .availableForCreateMissingService {
                do {
                    executionDesiredService = try resolveSecretReferences(in: desiredService)
                } catch {
                    return failure(
                        code: .unsafeExposure,
                        message: "Secret reference resolution failed before mutation: \(RuntimeRedactionPolicy.default.redact(String(describing: error))). No mutation was attempted."
                    )
                }
                if let safeSubsetFailure = validateCreateOnlyApplySubset(executionDesiredService) {
                    return failure(code: .unsafeExposure, message: "\(safeSubsetFailure) No mutation was attempted.")
                }
            } else {
                executionDesiredService = desiredService
            }
            if action.executionAvailability == .availableForStartManagedService ||
                action.executionAvailability == .availableForRestartManagedService {
                if let ownershipGateFailure = try validateManagedOwnershipGate(
                    action: action,
                    observed: observedForPlanning,
                    store: store,
                    projectID: projectID,
                    runtimeAdapter: observedRuntimeAdapter
                ) {
                    return failure(code: .unsafeExposure, message: "\(ownershipGateFailure) No mutation was attempted.")
                }
            }
            if action.executionAvailability == .availableForRestartManagedService {
                if let restartGateFailure = try validateManagedRestartGate(
                    action: action,
                    desiredService: executionDesiredService,
                    observed: observedForPlanning,
                    store: store,
                    projectID: projectID,
                    currentTimestamp: timestamp
                ) {
                    return failure(code: .unsafeExposure, message: "\(restartGateFailure) No mutation was attempted.")
                }
            }

            let operationID = hostwrightUniqueID(prefix: "operation-apply")
            let operationGroupID = hostwrightUniqueID(prefix: "operation-group")
            let groupAcquire = try store.operationGroups.acquire(
                operationGroup(
                    id: operationGroupID,
                    operationID: operationID,
                    action: action,
                    idempotencyKey: idempotencyKey,
                    planHash: plan.planHash,
                    projectID: projectID,
                    timestamp: timestamp,
                    status: .active,
                    checkpoint: "prepared",
                    lockOwner: "hostwright-cli:\(operationID)",
                    lockExpiresAt: hostwrightTimestampAdding(seconds: 600, to: timestamp),
                    manualRecoveryHint: manualRecoveryHint(
                        status: .active,
                        checkpoint: "prepared",
                        action: action
                    )
                )
            )
            if let existing = groupAcquire.existingActive {
                return failure(
                    code: .commandUsage,
                    message: "Operation group with the same idempotency key is already active at checkpoint \(existing.checkpoint). No mutation was attempted. Run recovery --state-db <path> to inspect manual recovery guidance."
                )
            }
            do {
                try recordRollbackUnsupportedStep(
                    store: store,
                    groupID: operationGroupID,
                    action: action,
                    idempotencyKey: idempotencyKey,
                    timestamp: timestamp
                )

                try persistPreMutationState(
                    store: store,
                    manifest: manifest,
                    manifestText: manifestText,
                    observed: observedForPlanning,
                    plan: plan,
                    action: action,
                    operationID: operationID,
                    idempotencyKey: idempotencyKey,
                    projectID: projectID,
                    timestamp: timestamp,
                    runtimeAdapter: observedRuntimeAdapter
                )
                try recordOperationGroupStep(
                    store: store,
                    groupID: operationGroupID,
                    action: action,
                    stepKey: "runtime-execute",
                    direction: .forward,
                    status: .started,
                    idempotencyKey: idempotencyKey,
                    timestamp: timestamp,
                    resourceIdentifier: action.resourceIdentifier,
                    error: nil,
                    hint: "Runtime mutation started for \(action.identity.displayName). If this process is interrupted, inspect the exact runtime resource and rerun apply only after confirming the current plan."
                )
            } catch {
                try? finishOperationGroup(
                    store: store,
                    groupID: operationGroupID,
                    status: .interrupted,
                    checkpoint: "pre-runtime-state-incomplete",
                    action: action,
                    timestamp: timestamp,
                    metadata: [
                        "error": RuntimeRedactionPolicy.default.redact(String(describing: error)),
                        "runtimeMutation": "not-attempted",
                        "rollback": "unsupported"
                    ]
                )
                return failure(
                    code: .stateStoreUnavailable,
                    message: "Apply operation group was recorded, but pre-runtime state persistence failed before mutation: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))"
                )
            }

            let runtimeAction = runtimeAction(for: action, desiredService: executionDesiredService)

            let event: RuntimeEvent
            do {
                event = try waitForAsync {
                    try await adapter.execute(
                        runtimeAction,
                        confirmation: RuntimeMutationConfirmation(
                            confirmed: true,
                            reason: "Confirmed Hostwright plan \(plan.planHash)",
                            planHash: plan.planHash
                        )
                    )
                }
            } catch {
                let runtimeErrorDescription = RuntimeRedactionPolicy.default.redact(String(describing: error))
                do {
                    if restartStopSucceededBeforeFailure(error) {
                        try recordOperationGroupStep(
                            store: store,
                            groupID: operationGroupID,
                            action: action,
                            stepKey: "restart-stop",
                            direction: .forward,
                            status: .succeeded,
                            idempotencyKey: idempotencyKey,
                            timestamp: timestamp,
                            resourceIdentifier: action.resourceIdentifier,
                            error: nil,
                            hint: "Managed restart stop completed for \(action.identity.displayName); start did not complete."
                        )
                        try recordRestartRecoveryIfNeeded(
                            store: store,
                            action: action,
                            operationID: operationID,
                            planHash: plan.planHash,
                            projectID: projectID,
                            timestamp: timestamp,
                            status: .stopSucceeded
                        )
                    }
                    try recordOperationGroupStep(
                        store: store,
                        groupID: operationGroupID,
                        action: action,
                        stepKey: "runtime-execute",
                        direction: .forward,
                        status: .failed,
                        idempotencyKey: idempotencyKey,
                        timestamp: timestamp,
                        resourceIdentifier: action.resourceIdentifier,
                        error: runtimeErrorDescription,
                        hint: manualRecoveryHint(status: .failed, checkpoint: "runtime-failed", action: action)
                    )
                    try persistFailure(
                        store: store,
                        error: error,
                        action: action,
                        operationID: operationID,
                        idempotencyKey: idempotencyKey,
                        planHash: plan.planHash,
                        projectID: projectID,
                        timestamp: timestamp
                    )
                    try recordManagedStartAttempt(
                        store: store,
                        action: action,
                        desiredService: desiredService,
                        projectID: projectID,
                        timestamp: timestamp,
                        outcome: "failed"
                    )
                    try finishOperationGroup(
                        store: store,
                        groupID: operationGroupID,
                        status: .failed,
                        checkpoint: "runtime-failed",
                        action: action,
                        timestamp: timestamp,
                        metadata: [
                            "error": runtimeErrorDescription,
                            "rollback": "unsupported"
                        ]
                    )
                } catch {
                    try? finishOperationGroup(
                        store: store,
                        groupID: operationGroupID,
                        status: .failed,
                        checkpoint: "runtime-failed",
                        action: action,
                        timestamp: timestamp,
                        metadata: [
                            "error": runtimeErrorDescription,
                            "persistenceError": RuntimeRedactionPolicy.default.redact(String(describing: error)),
                            "rollback": "unsupported"
                        ]
                    )
                    return failure(
                        code: .runtimeUnavailable,
                        message: "Runtime mutation failed after operation intent was recorded: \(runtimeErrorDescription). Failure state persistence also failed: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))"
                    )
                }
                return failure(code: .runtimeUnavailable, message: "Runtime mutation failed after operation intent was recorded: \(runtimeErrorDescription)")
            }

            do {
                try recordOperationGroupStep(
                    store: store,
                    groupID: operationGroupID,
                    action: action,
                    stepKey: "runtime-execute",
                    direction: .forward,
                    status: .succeeded,
                    idempotencyKey: idempotencyKey,
                    timestamp: timestamp,
                    resourceIdentifier: event.resourceIdentifier ?? action.resourceIdentifier,
                    error: nil,
                    hint: "Runtime mutation completed for \(action.identity.displayName)."
                )
                try persistSuccess(
                    store: store,
                    event: event,
                    action: action,
                    operationID: operationID,
                    idempotencyKey: idempotencyKey,
                    planHash: plan.planHash,
                    projectID: projectID,
                    timestamp: timestamp,
                    runtimeAdapter: observedRuntimeAdapter
                )
                try recordManagedStartAttempt(
                    store: store,
                    action: action,
                    desiredService: desiredService,
                    projectID: projectID,
                    timestamp: timestamp,
                    outcome: "succeeded"
                )
                try finishOperationGroup(
                    store: store,
                    groupID: operationGroupID,
                    status: .succeeded,
                    checkpoint: "completed",
                    action: action,
                    timestamp: timestamp,
                    metadata: [
                        "rollback": "unsupported",
                        "runtimeEventSeverity": event.severity.rawValue
                    ]
                )

                return CLIRunResult(
                    standardOutput: """
                    Hostwright apply
                    Plan hash: \(plan.planHash)
                    Applied action: \(action.kind.rawValue) \(action.identity.displayName)
                    Resource: \(action.resourceIdentifier)
                    Runtime event: \(RuntimeRedactionPolicy.default.redact(event.message))
                    State DB: \(stateDatabasePath)

                    """
                )
            } catch {
                try? finishOperationGroup(
                    store: store,
                    groupID: operationGroupID,
                    status: .interrupted,
                    checkpoint: "runtime-finished-state-incomplete",
                    action: action,
                    timestamp: timestamp,
                    metadata: [
                        "error": RuntimeRedactionPolicy.default.redact(String(describing: error)),
                        "rollback": "unsupported"
                    ]
                )
                return failure(
                    code: .stateStoreUnavailable,
                    message: "Runtime mutation succeeded but success state persistence failed: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))"
                )
            }
        } catch let error as ManifestParseError {
            return CLIRunResult(standardError: error.issues.map(\.rendered).joined(separator: "\n") + "\n", exitCode: CLIExitCode.validation.rawValue)
        } catch {
            return failure(code: .stateStoreUnavailable, message: RuntimeRedactionPolicy.default.redact(String(describing: error)))
        }
    }

    private func validateCreateOnlyApplySubset(_ service: DesiredRuntimeService) -> String? {
        if !service.mounts.isEmpty {
            return "Create-only apply rejects volumes and mounts."
        }
        if service.ports.contains(where: { ($0.hostPort ?? 0) < 1_024 }) {
            return "Create-only apply rejects privileged host ports."
        }
        if service.ports.contains(where: { $0.bindAddress == "0.0.0.0" || $0.bindAddress == "::" }) {
            return "Create-only apply rejects broad bind addresses."
        }
        if service.image.hasPrefix("-") {
            return "Create-only apply rejects image values beginning with '-'."
        }
        if service.command.contains(where: { $0.hasPrefix("-") }) {
            return "Create-only apply rejects command tokens beginning with '-'."
        }
        if service.environment.contains(where: { $0.secretReference != nil }) {
            return "Create-only apply rejects unresolved secret references."
        }
        return nil
    }

    private func resolveSecretReferences(in service: DesiredRuntimeService) throws -> DesiredRuntimeService {
        guard service.environment.contains(where: { $0.secretReference != nil }) else {
            return service
        }

        let store = environment.secretStore()
        let resolvedEnvironment = try service.environment.map { value in
            guard let reference = value.secretReference else {
                return value
            }

            return RuntimeEnvironmentValue(
                name: value.name,
                value: try store.readString(reference: reference),
                isSensitive: true
            )
        }

        return DesiredRuntimeService(
            identity: service.identity,
            image: service.image,
            command: service.command,
            environment: resolvedEnvironment,
            ports: service.ports,
            mounts: service.mounts,
            healthCheck: service.healthCheck,
            restartPolicy: service.restartPolicy
        )
    }

    private func runtimeAction(for action: PlannedAction, desiredService: DesiredRuntimeService?) -> PlannedRuntimeAction {
        switch action.executionAvailability {
        case .availableForCreateMissingService:
            return PlannedRuntimeAction(
                kind: .create,
                identity: action.identity,
                resourceIdentifier: action.resourceIdentifier,
                isDestructive: false,
                summary: "Create missing service \(action.identity.displayName).",
                desiredService: desiredService
            )
        case .availableForStartManagedService:
            return PlannedRuntimeAction(
                kind: .start,
                identity: action.identity,
                resourceIdentifier: action.resourceIdentifier,
                isDestructive: false,
                summary: "Start managed service \(action.identity.displayName)."
            )
        case .availableForRestartManagedService:
            return PlannedRuntimeAction(
                kind: .restart,
                identity: action.identity,
                resourceIdentifier: action.resourceIdentifier,
                isDestructive: true,
                summary: "Restart unhealthy Hostwright-owned running service \(action.identity.displayName)."
            )
        case .unavailable:
            return PlannedRuntimeAction(
                kind: .noOp,
                identity: action.identity,
                resourceIdentifier: action.resourceIdentifier,
                isDestructive: false,
                summary: "No runtime action is available."
            )
        }
    }

    private func persistPreMutationState(
        store: SQLiteStateStore,
        manifest: HostwrightManifest,
        manifestText: String,
        observed: ObservedRuntimeState,
        plan: ReconciliationPlan,
        action: PlannedAction,
        operationID: String,
        idempotencyKey: String,
        projectID: String,
        timestamp: String,
        runtimeAdapter: String
    ) throws {
        try store.desiredStates.saveManifestSnapshot(
            projectID: projectID,
            manifestPath: manifestPath,
            manifestHash: stableHash(manifestText),
            desiredGeneration: 1,
            manifest: manifest,
            timestamp: timestamp
        )
        try store.observedStates.saveSnapshot(
            snapshotID: hostwrightUniqueID(prefix: "snapshot-apply"),
            projectID: projectID,
            observedState: observed,
            runtimeAdapter: runtimeAdapter,
            parserVersion: "confirmed-apply-v1",
            rawOutputHash: nil,
            redactedSummary: PlanRenderer.render(plan, mode: .compact),
            observedAt: timestamp
        )
        try store.operations.record(
            OperationRecord(
                id: "\(operationID)-recorded",
                createdAt: timestamp,
                updatedAt: timestamp,
                plannedActionType: action.kind.rawValue,
                projectID: projectID,
                serviceName: action.identity.serviceName,
                status: .recorded,
                idempotencyKey: idempotencyKey,
                planHash: plan.planHash,
                payloadJSONRedacted: jsonPayload([
                    "action": action.kind.rawValue,
                    "identity": action.identity.displayName,
                    "resourceIdentifier": action.resourceIdentifier
                ])
            )
        )
        try store.events.append([
            EventRecord(
                id: hostwrightUniqueID(prefix: "event-apply-started"),
                timestamp: timestamp,
                severity: .info,
                type: intentEventType(for: action),
                source: "hostwright-cli",
                projectID: projectID,
                serviceName: action.identity.serviceName,
                runtimeAdapter: runtimeAdapter,
                message: "Apply intent recorded for \(action.identity.displayName).",
                payloadJSONRedacted: #"{"planHash":"\#(plan.planHash)"}"#
            )
        ])
        try recordRestartRecoveryIfNeeded(
            store: store,
            action: action,
            operationID: operationID,
            planHash: plan.planHash,
            projectID: projectID,
            timestamp: timestamp,
            status: .prepared
        )
    }

    private func persistSuccess(
        store: SQLiteStateStore,
        event: RuntimeEvent,
        action: PlannedAction,
        operationID: String,
        idempotencyKey: String,
        planHash: String,
        projectID: String,
        timestamp: String,
        runtimeAdapter: String
    ) throws {
        try store.operations.record(
            OperationRecord(
                id: "\(operationID)-succeeded",
                createdAt: timestamp,
                updatedAt: timestamp,
                plannedActionType: action.kind.rawValue,
                projectID: projectID,
                serviceName: action.identity.serviceName,
                status: .succeeded,
                idempotencyKey: idempotencyKey,
                planHash: planHash,
                payloadJSONRedacted: #"{"result":"succeeded"}"#
            )
        )
        try store.events.append([
            EventRecord(
                id: hostwrightUniqueID(prefix: "event-apply-succeeded"),
                timestamp: timestamp,
                severity: .info,
                type: successEventType(for: action),
                source: "hostwright-cli",
                projectID: projectID,
                serviceName: action.identity.serviceName,
                runtimeAdapter: nil,
                message: event.message,
                payloadJSONRedacted: #"{"planHash":"\#(planHash)"}"#
            )
        ])

        if action.executionAvailability == .availableForCreateMissingService, let resourceIdentifier = event.resourceIdentifier {
            guard resourceIdentifier == action.resourceIdentifier else {
                throw StateStoreError.invalidRecord(
                    "Runtime create returned identifier \(resourceIdentifier), expected exact planned identifier \(action.resourceIdentifier)."
                )
            }
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "ownership-\(operationID)",
                    resourceIdentifier: resourceIdentifier,
                    resourceType: "container",
                    projectID: projectID,
                    serviceName: action.identity.serviceName,
                    runtimeAdapter: runtimeAdapter,
                    createdAt: timestamp,
                    observedAt: timestamp,
                    cleanupEligible: action.executionAvailability == .availableForCreateMissingService,
                    metadataJSONRedacted: #"{"planHash":"\#(planHash)"}"#,
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion
                )
            )
        }
        try recordRestartRecoveryIfNeeded(
            store: store,
            action: action,
            operationID: operationID,
            planHash: planHash,
            projectID: projectID,
            timestamp: timestamp,
            status: .succeeded
        )
    }

    private func persistFailure(
        store: SQLiteStateStore,
        error: Error,
        action: PlannedAction,
        operationID: String,
        idempotencyKey: String,
        planHash: String,
        projectID: String,
        timestamp: String
    ) throws {
        let redactedError = RuntimeRedactionPolicy.default.redact(String(describing: error))
        try store.operations.record(
            OperationRecord(
                id: "\(operationID)-failed",
                createdAt: timestamp,
                updatedAt: timestamp,
                plannedActionType: action.kind.rawValue,
                projectID: projectID,
                serviceName: action.identity.serviceName,
                status: .failed,
                idempotencyKey: idempotencyKey,
                planHash: planHash,
                payloadJSONRedacted: #"{"error":"\#(redactedError)"}"#
            )
        )
        try store.events.append([
            EventRecord(
                id: hostwrightUniqueID(prefix: "event-apply-failed"),
                timestamp: timestamp,
                severity: .error,
                type: "apply.failed",
                source: "hostwright-cli",
                projectID: projectID,
                serviceName: action.identity.serviceName,
                runtimeAdapter: nil,
                message: "Apply failed for \(action.identity.displayName): \(redactedError)",
                payloadJSONRedacted: #"{"planHash":"\#(planHash)"}"#
            )
        ])
        try recordRestartRecoveryIfNeeded(
            store: store,
            action: action,
            operationID: operationID,
            planHash: planHash,
            projectID: projectID,
            timestamp: timestamp,
            status: .failed
        )
    }

    private func failure(code: HostwrightErrorCode, message: String) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: code)
        return CLIRunResult(standardError: "\(code.rawValue): \(message)\n", exitCode: exitCode.rawValue)
    }

    private func blockingOperation(store: SQLiteStateStore, idempotencyKey: String) throws -> OperationRecord? {
        guard let latest = try store.operations.latest(idempotencyKey: idempotencyKey) else {
            return nil
        }

        switch latest.status {
        case .planned, .recorded, .succeeded:
            return latest
        case .failed, .abandoned:
            return nil
        }
    }

    private func recordManagedStartAttempt(
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

    private func recordManagedRecoveryAttempt(
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

    private func validateManagedRestartGate(
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

    private func validateManagedOwnershipGate(
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

    private func intentEventType(for action: PlannedAction) -> String {
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

    private func successEventType(for action: PlannedAction) -> String {
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

    private func operationGroup(
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
        manualRecoveryHint: String
    ) -> OperationGroupRecord {
        OperationGroupRecord(
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
            ])
        )
    }

    private func finishOperationGroup(
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

    private func recordRollbackUnsupportedStep(
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

    private func recordOperationGroupStep(
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

    private func manualRecoveryHint(status: OperationGroupStatus, checkpoint: String, action: PlannedAction) -> String {
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

    private func recordRestartRecoveryIfNeeded(
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

    private func completedStepsJSON(for status: RestartRecoveryStatus) -> String {
        switch status {
        case .prepared, .failed:
            return #"[]"#
        case .stopSucceeded:
            return #"["stop"]"#
        case .succeeded:
            return #"["stop","start"]"#
        }
    }

    private func manualRecoveryHint(for status: RestartRecoveryStatus, identity: RuntimeServiceIdentity) -> String {
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

    private func managedRestartSentenceLabel(for action: PlannedAction) -> String {
        action.executionAvailability == .availableForRestartManagedService ? "Managed restart" : "Managed start"
    }

    private func restartStopSucceededBeforeFailure(_ error: Error) -> Bool {
        guard let runtimeError = error as? RuntimeAdapterError else {
            return false
        }
        if case .managedRestartStartFailedAfterStop = runtimeError {
            return true
        }
        return false
    }
}

private func waitForAsync<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncResultBox<T>()

    Task.detached {
        do {
            box.result = Result.success(try await operation())
        } catch {
            box.result = Result.failure(error)
        }
        semaphore.signal()
    }

    semaphore.wait()
    return try box.result!.get()
}

private final class AsyncResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private func stableHash(_ value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return String(format: "%016llx", hash)
}

private func jsonPayload(_ object: [String: Any]) -> String {
    let redacted = object.mapValues { value -> Any in
        if let string = value as? String {
            return RuntimeRedactionPolicy.default.redact(string)
        }
        return value
    }
    let data = try! JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}
