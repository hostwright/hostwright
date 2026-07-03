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
            let adapter = environment.runtimeAdapter()
            let observed = try waitForAsync {
                try await adapter.observe(desiredState: mapping.desiredState)
            }
            let plan = ReconciliationPlanner().plan(manifest: manifest, observedState: observed)

            guard plan.planHash == confirmedPlanHash else {
                return failure(
                    code: .commandUsage,
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
            if action.executionAvailability == .availableForCreateMissingService {
                guard let desiredService else {
                    return failure(code: .runtimeMutationNotImplemented, message: "Could not find desired service for \(action.identity.displayName). No mutation was attempted.")
                }
                if let safeSubsetFailure = validateCreateOnlyApplySubset(desiredService) {
                    return failure(code: .unsafeExposure, message: "\(safeSubsetFailure) No mutation was attempted.")
                }
            }

            let store = SQLiteStateStore(path: configuration.databasePath)
            try store.migrate()
            let timestamp = isoTimestamp()
            let projectID = "project-\(plan.projectName)"
            let operationID = "operation-\(plan.planHash)-\(action.identity.serviceName)"
            let idempotencyKey = "\(plan.planHash):\(action.kind.rawValue):\(action.identity.displayName)"

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

            do {
                let event = try waitForAsync {
                    try await adapter.execute(
                        runtimeAction,
                        confirmation: RuntimeMutationConfirmation(
                            confirmed: true,
                            reason: "Confirmed Hostwright plan \(plan.planHash)",
                            planHash: plan.planHash
                        )
                    )
                }

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
                return failure(code: .runtimeUnavailable, message: "Runtime mutation failed after operation intent was recorded: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))")
            }
        } catch let error as ManifestParseError {
            return CLIRunResult(standardError: error.issues.map(\.rendered).joined(separator: "\n") + "\n", exitCode: 1)
        } catch {
            return failure(code: .stateStoreUnavailable, message: RuntimeRedactionPolicy.default.redact(String(describing: error)))
        }
    }

    private func validateCreateOnlyApplySubset(_ service: DesiredRuntimeService) -> String? {
        if !service.mounts.isEmpty {
            return "Create-only apply rejects volumes and mounts."
        }
        if service.environment.contains(where: { $0.isSensitive || $0.value == RuntimeRedactionPolicy.default.replacement }) {
            return "Create-only apply rejects sensitive environment values until secret handling is designed."
        }
        if service.ports.contains(where: { ($0.hostPort ?? 0) < 1_024 }) {
            return "Create-only apply rejects privileged host ports."
        }
        if service.ports.contains(where: { $0.bindAddress == "0.0.0.0" || $0.bindAddress == "::" }) {
            return "Create-only apply rejects broad bind addresses."
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
            snapshotID: "snapshot-\(plan.planHash)",
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
                id: operationID,
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
                id: "event-\(operationID)-started",
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
                id: operationID,
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
                id: "event-\(operationID)-succeeded",
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
                id: operationID,
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
                id: "event-\(operationID)-failed",
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
        CLIRunResult(standardError: "\(code.rawValue): \(message)\n", exitCode: 1)
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
