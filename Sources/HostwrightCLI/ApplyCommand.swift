import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightSecrets
import HostwrightState

struct ApplyCommandRunner {
    static let preRuntimeStateIncompleteCheckpoint = "pre-runtime-state-incomplete"

    let manifestPath: String
    let stateDatabasePath: String
    let confirmedPlanHash: String
    let environment: CLIEnvironment

    func run() -> CLIRunResult {
        do {
            let configuration = StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
            try configuration.validate()

            let manifestText = try hostwrightReadManifestText(path: manifestPath, environment: environment)
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
                if let existingGroup = try store.operationGroups.latest(groupIdempotencyKey: idempotencyKey),
                   existingGroup.status == .active {
                    return failure(
                        code: .commandUsage,
                        message: activeOperationConflictMessage(existingGroup, hasRecordedIntent: true)
                    )
                }
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
                    message: activeOperationConflictMessage(existing, hasRecordedIntent: false)
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
                    checkpoint: Self.preRuntimeStateIncompleteCheckpoint,
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
        } catch let error as HostwrightDiagnostic {
            return failure(code: error.code, message: error.message)
        } catch let error as ManifestParseError {
            return CLIRunResult(standardError: error.issues.map(\.rendered).joined(separator: "\n") + "\n", exitCode: CLIExitCode.validation.rawValue)
        } catch {
            return failure(code: .stateStoreUnavailable, message: RuntimeRedactionPolicy.default.redact(String(describing: error)))
        }
    }
}
