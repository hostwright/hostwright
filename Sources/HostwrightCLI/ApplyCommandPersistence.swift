import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

extension ApplyCommandRunner {
    func persistPreMutationState(
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

    func persistSuccess(
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

    func persistFailure(
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
}
