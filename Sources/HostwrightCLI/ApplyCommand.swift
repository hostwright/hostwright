import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
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
            let timestamp = isoTimestamp()
            let projectName = mapping.desiredState.projectName
            let projectID = "project-\(projectName)"
            let restartPolicyStates = try restartPolicyStateMap(store: store, projectID: projectID, projectName: projectName)
            let adapter = environment.runtimeAdapter()
            let observed: ObservedRuntimeState
            do {
                observed = try waitForAsync {
                    try await adapter.observe(desiredState: mapping.desiredState)
                }
            } catch {
                return failure(code: .runtimeUnavailable, message: "Runtime observation failed: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))")
            }
            let plan = ReconciliationPlanner().plan(
                manifest: manifest,
                observedState: observed,
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
                $0.executionAvailability == .availableForStartManagedService
            }
            guard !executableActions.isEmpty else {
                return failure(
                    code: .runtimeMutationNotImplemented,
                    message: "No executable createMissingService or startManagedService action exists in the current plan. No mutation was attempted.\n\n\(PlanRenderer.render(plan))"
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
            if action.executionAvailability == .availableForCreateMissingService {
                if let safeSubsetFailure = validateCreateOnlyApplySubset(desiredService) {
                    return failure(code: .unsafeExposure, message: "\(safeSubsetFailure) No mutation was attempted.")
                }
            }

            let idempotencyKey = "\(plan.planHash):\(action.kind.rawValue):\(action.identity.displayName)"
            if let existingOperation = try blockingOperation(store: store, idempotencyKey: idempotencyKey) {
                return failure(
                    code: .commandUsage,
                    message: "Operation with the same idempotency key is already \(existingOperation.status.rawValue). No mutation was attempted."
                )
            }
            let operationID = hostwrightUniqueID(prefix: "operation-apply")

            try persistPreMutationState(
                store: store,
                manifest: manifest,
                manifestText: manifestText,
                observed: observed,
                plan: plan,
                action: action,
                operationID: operationID,
                idempotencyKey: idempotencyKey,
                projectID: projectID,
                timestamp: timestamp
            )

            let runtimeAction = runtimeAction(for: action, desiredService: desiredService)

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
                } catch {
                    return failure(
                        code: .runtimeUnavailable,
                        message: "Runtime mutation failed after operation intent was recorded: \(runtimeErrorDescription). Failure state persistence also failed: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))"
                    )
                }
                return failure(code: .runtimeUnavailable, message: "Runtime mutation failed after operation intent was recorded: \(runtimeErrorDescription)")
            }

            do {
                try persistSuccess(
                    store: store,
                    event: event,
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
                    outcome: "succeeded"
                )

                return CLIRunResult(
                    standardOutput: """
                    Hostwright apply
                    Plan hash: \(plan.planHash)
                    Applied action: \(action.kind.rawValue) \(action.identity.displayName)
                    Runtime event: \(RuntimeRedactionPolicy.default.redact(event.message))
                    State DB: \(stateDatabasePath)

                    """
                )
            } catch {
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
        return nil
    }

    private func runtimeAction(for action: PlannedAction, desiredService: DesiredRuntimeService?) -> PlannedRuntimeAction {
        switch action.executionAvailability {
        case .availableForCreateMissingService:
            return PlannedRuntimeAction(
                kind: .create,
                identity: action.identity,
                isDestructive: false,
                summary: "Create missing service \(action.identity.displayName).",
                desiredService: desiredService
            )
        case .availableForStartManagedService:
            return PlannedRuntimeAction(
                kind: .start,
                identity: action.identity,
                isDestructive: false,
                summary: "Start managed service \(action.identity.displayName)."
            )
        case .unavailable:
            return PlannedRuntimeAction(
                kind: .noOp,
                identity: action.identity,
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
        timestamp: String
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
            runtimeAdapter: observed.adapterMetadata?.adapterName ?? "runtime-adapter",
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
                payloadJSONRedacted: #"{"action":"\#(action.kind.rawValue)","identity":"\#(action.identity.displayName)"}"#
            )
        )
        try store.events.append([
            EventRecord(
                id: hostwrightUniqueID(prefix: "event-apply-started"),
                timestamp: timestamp,
                severity: .info,
                type: action.executionAvailability == .availableForStartManagedService ? "apply.start-intent-recorded" : "apply.create-intent-recorded",
                source: "hostwright-cli",
                projectID: projectID,
                serviceName: action.identity.serviceName,
                runtimeAdapter: observed.adapterMetadata?.adapterName,
                message: "Apply intent recorded for \(action.identity.displayName).",
                payloadJSONRedacted: #"{"planHash":"\#(plan.planHash)"}"#
            )
        ])
    }

    private func persistSuccess(
        store: SQLiteStateStore,
        event: RuntimeEvent,
        action: PlannedAction,
        operationID: String,
        idempotencyKey: String,
        planHash: String,
        projectID: String,
        timestamp: String
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
                type: action.executionAvailability == .availableForStartManagedService ? "apply.started-service" : "apply.created-service",
                source: "hostwright-cli",
                projectID: projectID,
                serviceName: action.identity.serviceName,
                runtimeAdapter: nil,
                message: event.message,
                payloadJSONRedacted: #"{"planHash":"\#(planHash)"}"#
            )
        ])

        if action.executionAvailability == .availableForCreateMissingService, let resourceIdentifier = event.resourceIdentifier {
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "ownership-\(operationID)",
                    resourceIdentifier: resourceIdentifier,
                    resourceType: "container",
                    projectID: projectID,
                    serviceName: action.identity.serviceName,
                    runtimeAdapter: "runtime-adapter",
                    createdAt: timestamp,
                    observedAt: timestamp,
                    cleanupEligible: action.executionAvailability == .availableForCreateMissingService,
                    metadataJSONRedacted: #"{"planHash":"\#(planHash)"}"#
                )
            )
        }
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

    private func restartPolicyStateMap(
        store: SQLiteStateStore,
        projectID: String,
        projectName: String
    ) throws -> [RuntimeServiceIdentity: RestartPolicyStateRecord] {
        let states = try store.restartPolicies.loadProject(projectID: projectID)
        return Dictionary(states.map { state in
            (
                RuntimeServiceIdentity(projectName: projectName, serviceName: state.serviceName),
                state
            )
        }, uniquingKeysWith: { first, _ in first })
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
        let backoffUntil = status == .backingOff ? isoTimestampAdding(seconds: backoffSeconds, to: timestamp) : nil

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
            message = "Managed start succeeded for \(action.identity.displayName); restart attempt budget is reset."
        case .crashLoopBlocked:
            eventType = "restart.policy.crash-loop-blocked"
            severity = .error
            message = "Managed start attempts reached \(attemptCount)/\(maxAttempts); operator action is required before another start."
        case .backingOff:
            eventType = "restart.policy.backoff"
            severity = .warning
            message = "Managed start attempt \(attemptCount)/\(maxAttempts) failed; restart backoff active until \(backoffUntil ?? "operator reset")."
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

private func isoTimestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func isoTimestampAdding(seconds: Int, to timestamp: String) -> String {
    let formatter = ISO8601DateFormatter()
    let date = formatter.date(from: timestamp) ?? Date()
    return formatter.string(from: date.addingTimeInterval(TimeInterval(seconds)))
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
