import Foundation
import HostwrightRuntime

public struct DiagnosticsManifestSummary: Equatable, Sendable {
    public let path: String
    public let projectName: String?
    public let serviceNames: [String]
    public let manifestHash: String

    public init(path: String, projectName: String?, serviceNames: [String], manifestHash: String) {
        self.path = path
        self.projectName = projectName
        self.serviceNames = serviceNames
        self.manifestHash = manifestHash
    }
}

public struct DiagnosticsExportQuery: Equatable, Sendable {
    public let projectID: String?
    public let manifest: DiagnosticsManifestSummary?
    public let generatedAt: String

    public init(projectID: String?, manifest: DiagnosticsManifestSummary?, generatedAt: String) {
        self.projectID = projectID
        self.manifest = manifest
        self.generatedAt = generatedAt
    }
}

public struct DiagnosticsObservedSnapshot: Equatable, Sendable {
    public let snapshot: ObservedRuntimeSnapshotRecord
    public let services: [ObservedServiceRecord]

    public init(snapshot: ObservedRuntimeSnapshotRecord, services: [ObservedServiceRecord]) {
        self.snapshot = snapshot
        self.services = services
    }
}

public struct DiagnosticsExport: Equatable, Sendable {
    public let generatedAt: String
    public let telemetryPolicy: String
    public let projectID: String?
    public let schemaVersion: Int
    public let manifest: DiagnosticsManifestSummary?
    public let events: [EventRecord]
    public let operations: [OperationRecord]
    public let operationGroups: [OperationGroupRecord]
    public let operationGroupSteps: [OperationGroupStepRecord]
    public let healthResults: [HealthCheckResultRecord]
    public let restartPolicyStates: [RestartPolicyStateRecord]
    public let restartRecoveryRecords: [RestartRecoveryRecord]
    public let ownershipRecords: [OwnershipRecord]
    public let observedSnapshots: [DiagnosticsObservedSnapshot]

    public init(
        generatedAt: String,
        telemetryPolicy: String,
        projectID: String?,
        schemaVersion: Int,
        manifest: DiagnosticsManifestSummary?,
        events: [EventRecord],
        operations: [OperationRecord],
        operationGroups: [OperationGroupRecord],
        operationGroupSteps: [OperationGroupStepRecord],
        healthResults: [HealthCheckResultRecord],
        restartPolicyStates: [RestartPolicyStateRecord],
        restartRecoveryRecords: [RestartRecoveryRecord],
        ownershipRecords: [OwnershipRecord],
        observedSnapshots: [DiagnosticsObservedSnapshot]
    ) {
        self.generatedAt = generatedAt
        self.telemetryPolicy = telemetryPolicy
        self.projectID = projectID
        self.schemaVersion = schemaVersion
        self.manifest = manifest
        self.events = events
        self.operations = operations
        self.operationGroups = operationGroups
        self.operationGroupSteps = operationGroupSteps
        self.healthResults = healthResults
        self.restartPolicyStates = restartPolicyStates
        self.restartRecoveryRecords = restartRecoveryRecords
        self.ownershipRecords = ownershipRecords
        self.observedSnapshots = observedSnapshots
    }

    public func jsonString() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: jsonObject(), options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8)! + "\n"
    }

    public func jsonObject() -> [String: Any] {
        [
            "kind": "diagnostics",
            "generatedAt": generatedAt,
            "telemetryPolicy": telemetryPolicy,
            "projectID": projectID as Any,
            "schemaVersion": schemaVersion,
            "manifest": manifest.map(manifestObject) as Any,
            "summary": [
                "events": events.count,
                "operations": operations.count,
                "operationGroups": operationGroups.count,
                "operationGroupSteps": operationGroupSteps.count,
                "healthResults": healthResults.count,
                "restartPolicyStates": restartPolicyStates.count,
                "restartRecoveryRecords": restartRecoveryRecords.count,
                "ownershipRecords": ownershipRecords.count,
                "observedSnapshots": observedSnapshots.count
            ],
            "events": events.map(eventObject),
            "operations": operations.map(operationObject),
            "operationGroups": operationGroups.map(operationGroupObject),
            "operationGroupSteps": operationGroupSteps.map(operationGroupStepObject),
            "healthResults": healthResults.map(healthResultObject),
            "restartPolicyStates": restartPolicyStates.map(restartPolicyObject),
            "restartRecoveryRecords": restartRecoveryRecords.map(restartRecoveryObject),
            "ownershipRecords": ownershipRecords.map(ownershipObject),
            "observedSnapshots": observedSnapshots.map(observedSnapshotObject)
        ].compactNilValues()
    }
}

public struct DiagnosticsExportRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func loadExport(query: DiagnosticsExportQuery) throws -> DiagnosticsExport {
        let projectID = query.projectID
        let snapshots = try store.observedStates.loadSnapshots(projectID: projectID)
        let observed = try snapshots.map { snapshot in
            DiagnosticsObservedSnapshot(
                snapshot: snapshot,
                services: try store.observedStates.loadObservedServices(snapshotID: snapshot.id).map { $0.redactedForDiagnostics() }
            )
        }
        let operationGroups = try store.operationGroups.loadAll()
            .filter { projectID == nil || $0.projectID == projectID }
            .map { $0.redacted() }
        let operationGroupIDs = Set(operationGroups.map(\.id))

        return DiagnosticsExport(
            generatedAt: query.generatedAt,
            telemetryPolicy: "local-only; no upload",
            projectID: projectID,
            schemaVersion: try store.schemaVersion(),
            manifest: query.manifest,
            events: try store.events.loadAll()
                .filter { projectID == nil || $0.projectID == projectID }
                .map { $0.redacted() },
            operations: try store.operations.loadAll()
                .filter { projectID == nil || $0.projectID == projectID }
                .map { $0.redacted() },
            operationGroups: operationGroups,
            operationGroupSteps: try store.operationGroupSteps.loadAll()
                .filter { projectID == nil || operationGroupIDs.contains($0.groupID) }
                .map { $0.redacted() },
            healthResults: try store.healthResults.loadAll()
                .filter { projectID == nil || $0.projectID == projectID }
                .map { $0.redacted() },
            restartPolicyStates: try store.restartPolicies.loadAll()
                .filter { projectID == nil || $0.projectID == projectID }
                .map { $0.redacted() },
            restartRecoveryRecords: try store.restartRecovery.loadAll()
                .filter { projectID == nil || $0.projectID == projectID }
                .map { $0.redacted() },
            ownershipRecords: try store.ownership.loadAll()
                .filter { projectID == nil || $0.projectID == projectID }
                .map { $0.redacted() },
            observedSnapshots: observed
        )
    }
}

private func manifestObject(_ manifest: DiagnosticsManifestSummary) -> [String: Any] {
    [
        "path": RuntimeRedactionPolicy.default.redact(manifest.path),
        "projectName": manifest.projectName.map(RuntimeRedactionPolicy.default.redact) as Any,
        "serviceNames": manifest.serviceNames.map(RuntimeRedactionPolicy.default.redact),
        "manifestHash": manifest.manifestHash
    ].compactNilValues()
}

private func eventObject(_ event: EventRecord) -> [String: Any] {
    [
        "id": event.id,
        "timestamp": event.timestamp,
        "severity": event.severity.rawValue,
        "type": event.type,
        "source": event.source,
        "projectID": event.projectID as Any,
        "serviceName": event.serviceName as Any,
        "runtimeAdapter": event.runtimeAdapter as Any,
        "message": RuntimeRedactionPolicy.default.redact(event.message),
        "payloadJSONRedacted": RuntimeRedactionPolicy.default.redact(event.payloadJSONRedacted)
    ].compactNilValues()
}

private func operationObject(_ operation: OperationRecord) -> [String: Any] {
    [
        "id": operation.id,
        "createdAt": operation.createdAt,
        "updatedAt": operation.updatedAt,
        "plannedActionType": operation.plannedActionType,
        "projectID": operation.projectID as Any,
        "serviceName": operation.serviceName as Any,
        "status": operation.status.rawValue,
        "idempotencyKey": operation.idempotencyKey,
        "planHash": operation.planHash,
        "payloadJSONRedacted": RuntimeRedactionPolicy.default.redact(operation.payloadJSONRedacted)
    ].compactNilValues()
}

private func operationGroupObject(_ group: OperationGroupRecord) -> [String: Any] {
    [
        "id": group.id,
        "operationID": group.operationID,
        "groupKind": group.groupKind,
        "projectID": group.projectID as Any,
        "serviceName": group.serviceName as Any,
        "plannedActionType": group.plannedActionType,
        "status": group.status.rawValue,
        "checkpoint": group.checkpoint,
        "planHash": group.planHash,
        "rollbackAvailable": group.rollbackAvailable,
        "manualRecoveryHintRedacted": RuntimeRedactionPolicy.default.redact(group.manualRecoveryHintRedacted),
        "createdAt": group.createdAt,
        "updatedAt": group.updatedAt,
        "metadataJSONRedacted": RuntimeRedactionPolicy.default.redact(group.metadataJSONRedacted)
    ].compactNilValues()
}

private func operationGroupStepObject(_ step: OperationGroupStepRecord) -> [String: Any] {
    [
        "id": step.id,
        "groupID": step.groupID,
        "stepKey": step.stepKey,
        "direction": step.direction.rawValue,
        "plannedActionType": step.plannedActionType,
        "serviceName": step.serviceName as Any,
        "resourceIdentifier": step.resourceIdentifier as Any,
        "status": step.status.rawValue,
        "startedAt": step.startedAt as Any,
        "updatedAt": step.updatedAt,
        "finishedAt": step.finishedAt as Any,
        "lastErrorRedacted": step.lastErrorRedacted.map(RuntimeRedactionPolicy.default.redact) as Any,
        "manualRecoveryHintRedacted": RuntimeRedactionPolicy.default.redact(step.manualRecoveryHintRedacted),
        "metadataJSONRedacted": RuntimeRedactionPolicy.default.redact(step.metadataJSONRedacted)
    ].compactNilValues()
}

private func healthResultObject(_ result: HealthCheckResultRecord) -> [String: Any] {
    [
        "id": result.id,
        "projectID": result.projectID as Any,
        "serviceName": result.serviceName,
        "checkedAt": result.checkedAt,
        "status": result.status.rawValue,
        "exitStatus": result.exitStatus as Any,
        "timedOut": result.timedOut,
        "commandJSONRedacted": RuntimeRedactionPolicy.default.redact(result.commandJSONRedacted),
        "stdoutRedacted": RuntimeRedactionPolicy.default.redact(result.stdoutRedacted),
        "stderrRedacted": RuntimeRedactionPolicy.default.redact(result.stderrRedacted),
        "metadataJSONRedacted": RuntimeRedactionPolicy.default.redact(result.metadataJSONRedacted)
    ].compactNilValues()
}

private func restartPolicyObject(_ state: RestartPolicyStateRecord) -> [String: Any] {
    [
        "id": state.id,
        "projectID": state.projectID,
        "serviceName": state.serviceName,
        "policy": state.policy.rawValue,
        "status": state.status.rawValue,
        "attemptCount": state.attemptCount,
        "maxAttempts": state.maxAttempts,
        "backoffSeconds": state.backoffSeconds,
        "backoffUntil": state.backoffUntil as Any,
        "lastFailureAt": state.lastFailureAt as Any,
        "updatedAt": state.updatedAt,
        "metadataJSONRedacted": RuntimeRedactionPolicy.default.redact(state.metadataJSONRedacted)
    ].compactNilValues()
}

private func restartRecoveryObject(_ record: RestartRecoveryRecord) -> [String: Any] {
    [
        "id": record.id,
        "operationID": record.operationID,
        "projectID": record.projectID as Any,
        "serviceName": record.serviceName,
        "resourceIdentifier": RuntimeRedactionPolicy.default.redact(record.resourceIdentifier),
        "planHash": record.planHash,
        "status": record.status.rawValue,
        "completedStepsJSONRedacted": RuntimeRedactionPolicy.default.redact(record.completedStepsJSONRedacted),
        "manualRecoveryHintRedacted": RuntimeRedactionPolicy.default.redact(record.manualRecoveryHintRedacted),
        "createdAt": record.createdAt,
        "updatedAt": record.updatedAt,
        "metadataJSONRedacted": RuntimeRedactionPolicy.default.redact(record.metadataJSONRedacted)
    ].compactNilValues()
}

private func ownershipObject(_ record: OwnershipRecord) -> [String: Any] {
    [
        "id": record.id,
        "resourceIdentifier": RuntimeRedactionPolicy.default.redact(record.resourceIdentifier),
        "resourceType": record.resourceType,
        "projectID": record.projectID as Any,
        "serviceName": record.serviceName as Any,
        "runtimeAdapter": record.runtimeAdapter,
        "identityVersion": record.identityVersion,
        "createdAt": record.createdAt,
        "observedAt": record.observedAt,
        "cleanupEligible": record.cleanupEligible,
        "metadataJSONRedacted": RuntimeRedactionPolicy.default.redact(record.metadataJSONRedacted)
    ].compactNilValues()
}

private func observedSnapshotObject(_ observed: DiagnosticsObservedSnapshot) -> [String: Any] {
    [
        "id": observed.snapshot.id,
        "projectID": observed.snapshot.projectID,
        "runtimeAdapter": observed.snapshot.runtimeAdapter,
        "runtimeName": observed.snapshot.runtimeName,
        "runtimeVersion": observed.snapshot.runtimeVersion as Any,
        "observedAt": observed.snapshot.observedAt,
        "parserVersion": observed.snapshot.parserVersion,
        "rawOutputHash": observed.snapshot.rawOutputHash as Any,
        "redactedSummary": RuntimeRedactionPolicy.default.redact(observed.snapshot.redactedSummary),
        "capabilitiesJSON": RuntimeRedactionPolicy.default.redact(observed.snapshot.capabilitiesJSON),
        "services": observed.services.map(observedServiceObject)
    ].compactNilValues()
}

private func observedServiceObject(_ service: ObservedServiceRecord) -> [String: Any] {
    [
        "id": service.id,
        "snapshotID": service.snapshotID,
        "projectName": service.projectName,
        "serviceName": service.serviceName,
        "instanceName": service.instanceName as Any,
        "resourceIdentifier": RuntimeRedactionPolicy.default.redact(service.resourceIdentifier),
        "image": service.image as Any,
        "lifecycleState": service.lifecycleState.rawValue,
        "healthState": service.healthState.rawValue,
        "portsJSON": service.portsJSON,
        "networksJSON": service.networksJSON,
        "mountsJSON": service.mountsJSON,
        "runtimeIdentifiersJSON": RuntimeRedactionPolicy.default.redact(service.runtimeIdentifiersJSON)
    ].compactNilValues()
}

private extension ObservedServiceRecord {
    func redactedForDiagnostics() -> ObservedServiceRecord {
        ObservedServiceRecord(
            id: id,
            snapshotID: snapshotID,
            projectName: projectName,
            serviceName: serviceName,
            instanceName: instanceName,
            resourceIdentifier: resourceIdentifier,
            image: image,
            lifecycleState: lifecycleState,
            healthState: healthState,
            portsJSON: RuntimeRedactionPolicy.default.redact(portsJSON),
            networksJSON: RuntimeRedactionPolicy.default.redact(networksJSON),
            mountsJSON: RuntimeRedactionPolicy.default.redact(mountsJSON),
            runtimeIdentifiersJSON: RuntimeRedactionPolicy.default.redact(runtimeIdentifiersJSON)
        )
    }
}

private extension Dictionary where Key == String, Value == Any {
    func compactNilValues() -> [String: Any] {
        var compacted: [String: Any] = [:]
        for (key, value) in self {
            if let unwrapped = unwrapOptional(value) {
                compacted[key] = unwrapped
            }
        }
        return compacted
    }

    private func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }
        return mirror.children.first?.value
    }
}
