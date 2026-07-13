import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightRuntime

func projectRecord(from row: [String?]) throws -> StateProjectRecord {
    guard row.count == 10,
          let id = row[0],
          let name = row[1],
          let manifestHash = row[3],
          let createdAt = row[4],
          let updatedAt = row[5],
          let resourceUUID = row[6],
          HostwrightResourceUUID.isValid(resourceUUID),
          let manifestVersionText = row[7],
          let manifestVersion = Int(manifestVersionText),
          (HostwrightManifest.legacyVersion...HostwrightManifest.currentVersion).contains(manifestVersion),
          row[8].map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
          let providerGenerationText = row[9],
          let providerGeneration = Int(providerGenerationText),
          providerGeneration >= 0
    else {
        throw StateStoreError.invalidRecord("Could not decode project row.")
    }

    return StateProjectRecord(
        id: id,
        name: name,
        manifestPath: row[2],
        manifestHash: manifestHash,
        createdAt: createdAt,
        updatedAt: updatedAt,
        resourceUUID: resourceUUID,
        manifestVersion: manifestVersion,
        mutationProvider: row[8],
        providerGeneration: providerGeneration
    )
}

func desiredServiceRecord(from row: [String?]) throws -> DesiredServiceRecord {
    guard row.count == 15,
          let id = row[0],
          let projectID = row[1],
          let serviceName = row[2],
          let image = row[3],
          let commandJSON = row[4],
          let portsJSON = row[5],
          let mountsJSON = row[6],
          let envJSON = row[7],
          let manifestHash = row[8],
          let desiredGenerationText = row[9],
          let desiredGeneration = Int(desiredGenerationText),
          desiredGeneration > 0,
          let createdAt = row[10],
          let updatedAt = row[11],
          let resourceUUID = row[12],
          HostwrightResourceUUID.isValid(resourceUUID),
          let resourceGenerationText = row[13],
          let resourceGeneration = Int(resourceGenerationText),
          resourceGeneration > 0,
          row[14].map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true
    else {
        throw StateStoreError.invalidRecord("Could not decode desired service row.")
    }

    return DesiredServiceRecord(
        id: id,
        projectID: projectID,
        serviceName: serviceName,
        image: image,
        commandJSON: commandJSON,
        portsJSON: portsJSON,
        mountsJSON: mountsJSON,
        environmentJSONRedacted: envJSON,
        manifestHash: manifestHash,
        desiredGeneration: desiredGeneration,
        createdAt: createdAt,
        updatedAt: updatedAt,
        resourceUUID: resourceUUID,
        resourceGeneration: resourceGeneration,
        mutationProvider: row[14]
    )
}

func observedSnapshotRecord(from row: [String?]) throws -> ObservedRuntimeSnapshotRecord {
    guard row.count == 10,
          let id = row[0],
          let runtimeAdapter = row[2],
          let runtimeName = row[3],
          let observedAt = row[5],
          let parserVersion = row[6],
          let redactedSummary = row[8],
          let capabilitiesJSON = row[9]
    else {
        throw StateStoreError.invalidRecord("Could not decode observed runtime snapshot row.")
    }

    return ObservedRuntimeSnapshotRecord(
        id: id,
        projectID: row[1] ?? "",
        runtimeAdapter: runtimeAdapter,
        runtimeName: runtimeName,
        runtimeVersion: row[4],
        observedAt: observedAt,
        parserVersion: parserVersion,
        rawOutputHash: row[7],
        redactedSummary: redactedSummary,
        capabilitiesJSON: capabilitiesJSON
    )
}

func observedServiceRecord(from row: [String?]) throws -> ObservedServiceRecord {
    guard row.count == 13,
          let id = row[0],
          let snapshotID = row[1],
          let projectName = row[2],
          let serviceName = row[3],
          let resourceIdentifier = row[5],
          let lifecycleText = row[7],
          let healthText = row[8],
          let lifecycleState = RuntimeLifecycleState(rawValue: lifecycleText),
          let healthState = RuntimeHealthState(rawValue: healthText),
          let portsJSON = row[9],
          let networksJSON = row[10],
          let mountsJSON = row[11],
          let runtimeIdentifiersJSON = row[12]
    else {
        throw StateStoreError.invalidRecord("Could not decode observed service row.")
    }

    return ObservedServiceRecord(
        id: id,
        snapshotID: snapshotID,
        projectName: projectName,
        serviceName: serviceName,
        instanceName: row[4],
        resourceIdentifier: resourceIdentifier,
        image: row[6],
        lifecycleState: lifecycleState,
        healthState: healthState,
        portsJSON: portsJSON,
        networksJSON: networksJSON,
        mountsJSON: mountsJSON,
        runtimeIdentifiersJSON: runtimeIdentifiersJSON
    )
}

func eventRecord(from row: [String?]) throws -> EventRecord {
    guard row.count == 10,
          let id = row[0],
          let timestamp = row[1],
          let severityText = row[2],
          let severity = StateEventSeverity(rawValue: severityText),
          let type = row[3],
          let source = row[4],
          let message = row[8],
          let payloadJSON = row[9]
    else {
        throw StateStoreError.invalidRecord("Could not decode event row.")
    }

    return EventRecord(
        id: id,
        timestamp: timestamp,
        severity: severity,
        type: type,
        source: source,
        projectID: row[5],
        serviceName: row[6],
        runtimeAdapter: row[7],
        message: message,
        payloadJSONRedacted: payloadJSON
    )
}

func operationRecord(from row: [String?]) throws -> OperationRecord {
    guard row.count == 10,
          let id = row[0],
          let createdAt = row[1],
          let updatedAt = row[2],
          let plannedActionType = row[3],
          let statusText = row[6],
          let status = OperationStatus(rawValue: statusText),
          let idempotencyKey = row[7],
          let planHash = row[8],
          let payloadJSON = row[9]
    else {
        throw StateStoreError.invalidRecord("Could not decode operation row.")
    }

    return OperationRecord(
        id: id,
        createdAt: createdAt,
        updatedAt: updatedAt,
        plannedActionType: plannedActionType,
        projectID: row[4],
        serviceName: row[5],
        status: status,
        idempotencyKey: idempotencyKey,
        planHash: planHash,
        payloadJSONRedacted: payloadJSON
    )
}

func operationGroupRecord(from row: [String?]) throws -> OperationGroupRecord {
    guard row.count == 21,
          let id = row[0],
          let operationID = row[1],
          let groupKind = row[2],
          let plannedActionType = row[5],
          let statusText = row[6],
          let status = OperationGroupStatus(rawValue: statusText),
          let groupIdempotencyKey = row[7],
          let planHash = row[8],
          let checkpoint = row[9],
          let rollbackAvailableText = row[12],
          let manualRecoveryHint = row[13],
          let createdAt = row[14],
          let updatedAt = row[15],
          let metadataJSON = row[16],
          StateJSON.isObject(metadataJSON),
          let fencingToken = row[17],
          HostwrightResourceUUID.isValid(fencingToken),
          let intentJSON = row[18],
          StateJSON.isObject(intentJSON),
          let compensationJSON = row[19],
          StateJSON.isArray(compensationJSON),
          let verificationJSON = row[20],
          StateJSON.isObject(verificationJSON)
    else {
        throw StateStoreError.invalidRecord("Could not decode operation group row.")
    }

    return OperationGroupRecord(
        id: id,
        operationID: operationID,
        groupKind: groupKind,
        projectID: row[3],
        serviceName: row[4],
        plannedActionType: plannedActionType,
        status: status,
        groupIdempotencyKey: groupIdempotencyKey,
        planHash: planHash,
        checkpoint: checkpoint,
        lockOwner: row[10],
        lockExpiresAt: row[11],
        rollbackAvailable: rollbackAvailableText == "1",
        manualRecoveryHintRedacted: manualRecoveryHint,
        createdAt: createdAt,
        updatedAt: updatedAt,
        metadataJSONRedacted: metadataJSON,
        fencingToken: fencingToken,
        intentJSONRedacted: intentJSON,
        compensationJSONRedacted: compensationJSON,
        verificationJSONRedacted: verificationJSON
    )
}

func operationGroupStepRecord(from row: [String?]) throws -> OperationGroupStepRecord {
    guard row.count == 15,
          let id = row[0],
          let groupID = row[1],
          let stepKey = row[2],
          let directionText = row[3],
          let direction = OperationGroupStepDirection(rawValue: directionText),
          let plannedActionType = row[4],
          let stepIdempotencyKey = row[7],
          let statusText = row[8],
          let status = OperationGroupStepStatus(rawValue: statusText),
          let updatedAt = row[10],
          let manualRecoveryHint = row[13],
          let metadataJSON = row[14],
          StateJSON.isObject(metadataJSON)
    else {
        throw StateStoreError.invalidRecord("Could not decode operation group step row.")
    }

    return OperationGroupStepRecord(
        id: id,
        groupID: groupID,
        stepKey: stepKey,
        direction: direction,
        plannedActionType: plannedActionType,
        serviceName: row[5],
        resourceIdentifier: row[6],
        stepIdempotencyKey: stepIdempotencyKey,
        status: status,
        startedAt: row[9],
        updatedAt: updatedAt,
        finishedAt: row[11],
        lastErrorRedacted: row[12],
        manualRecoveryHintRedacted: manualRecoveryHint,
        metadataJSONRedacted: metadataJSON
    )
}

func healthCheckResultRecord(from row: [String?]) throws -> HealthCheckResultRecord {
    guard row.count == 11,
          let id = row[0],
          let serviceName = row[2],
          let checkedAt = row[3],
          let statusText = row[4],
          let status = RuntimeHealthCheckStatus(rawValue: statusText),
          let timedOutText = row[6],
          let commandJSON = row[7],
          let stdout = row[8],
          let stderr = row[9],
          let metadataJSON = row[10]
    else {
        throw StateStoreError.invalidRecord("Could not decode health check result row.")
    }

    return HealthCheckResultRecord(
        id: id,
        projectID: row[1],
        serviceName: serviceName,
        checkedAt: checkedAt,
        status: status,
        exitStatus: row[5].flatMap(Int32.init),
        timedOut: timedOutText == "1",
        commandJSONRedacted: commandJSON,
        stdoutRedacted: stdout,
        stderrRedacted: stderr,
        metadataJSONRedacted: metadataJSON
    )
}

func restartPolicyStateRecord(from row: [String?]) throws -> RestartPolicyStateRecord {
    guard row.count == 12,
          let id = row[0],
          let projectID = row[1],
          let serviceName = row[2],
          let policyText = row[3],
          let policy = RuntimeRestartPolicy(rawValue: policyText),
          let statusText = row[4],
          let status = RestartPolicyStateStatus(rawValue: statusText),
          let attemptCountText = row[5],
          let attemptCount = Int(attemptCountText),
          let maxAttemptsText = row[6],
          let maxAttempts = Int(maxAttemptsText),
          let backoffSecondsText = row[7],
          let backoffSeconds = Int(backoffSecondsText),
          let updatedAt = row[10],
          let metadataJSON = row[11]
    else {
        throw StateStoreError.invalidRecord("Could not decode restart policy state row.")
    }

    return RestartPolicyStateRecord(
        id: id,
        projectID: projectID,
        serviceName: serviceName,
        policy: policy,
        status: status,
        attemptCount: attemptCount,
        maxAttempts: maxAttempts,
        backoffSeconds: backoffSeconds,
        backoffUntil: row[8],
        lastFailureAt: row[9],
        updatedAt: updatedAt,
        metadataJSONRedacted: metadataJSON
    )
}

func restartRecoveryRecord(from row: [String?]) throws -> RestartRecoveryRecord {
    guard row.count == 12,
          let id = row[0],
          let operationID = row[1],
          let serviceName = row[3],
          let resourceIdentifier = row[4],
          let planHash = row[5],
          let statusText = row[6],
          let status = RestartRecoveryStatus(rawValue: statusText),
          let completedStepsJSON = row[7],
          let manualRecoveryHint = row[8],
          let createdAt = row[9],
          let updatedAt = row[10],
          let metadataJSON = row[11]
    else {
        throw StateStoreError.invalidRecord("Could not decode restart recovery row.")
    }

    return RestartRecoveryRecord(
        id: id,
        operationID: operationID,
        projectID: row[2],
        serviceName: serviceName,
        resourceIdentifier: resourceIdentifier,
        planHash: planHash,
        status: status,
        completedStepsJSONRedacted: completedStepsJSON,
        manualRecoveryHintRedacted: manualRecoveryHint,
        createdAt: createdAt,
        updatedAt: updatedAt,
        metadataJSONRedacted: metadataJSON
    )
}

func ownershipRecord(from row: [String?]) throws -> OwnershipRecord {
    guard row.count == 17,
          let id = row[0],
          let resourceIdentifier = row[1],
          let resourceType = row[2],
          let runtimeAdapter = row[5],
          let createdAt = row[6],
          let observedAt = row[7],
          let cleanupEligibleText = row[8],
          let metadataJSON = row[9],
          let identityVersionText = row[10],
          let identityVersion = Int(identityVersionText),
          let resourceUUID = row[11],
          HostwrightResourceUUID.isValid(resourceUUID),
          let resourceGenerationText = row[12],
          let resourceGeneration = Int(resourceGenerationText),
          resourceGeneration > 0,
          row[13].map({ HostwrightResourceUUID.isValid($0) }) ?? true,
          let projectGenerationText = row[14],
          let projectGeneration = Int(projectGenerationText),
          projectGeneration >= 0,
          let providerGenerationText = row[15],
          let providerGeneration = Int(providerGenerationText),
          providerGeneration >= 0,
          let fencingToken = row[16],
          HostwrightResourceUUID.isValid(fencingToken)
    else {
        throw StateStoreError.invalidRecord("Could not decode ownership row.")
    }

    return OwnershipRecord(
        id: id,
        resourceIdentifier: resourceIdentifier,
        resourceType: resourceType,
        projectID: row[3],
        serviceName: row[4],
        runtimeAdapter: runtimeAdapter,
        createdAt: createdAt,
        observedAt: observedAt,
        cleanupEligible: cleanupEligibleText == "1",
        metadataJSONRedacted: metadataJSON,
        identityVersion: identityVersion,
        resourceUUID: resourceUUID,
        resourceGeneration: resourceGeneration,
        projectResourceUUID: row[13],
        projectGeneration: projectGeneration,
        providerGeneration: providerGeneration,
        fencingToken: fencingToken
    )
}

func optionalText(_ value: String?) -> SQLiteValue {
    value.map(SQLiteValue.text) ?? .null
}

func optionalInt32(_ value: Int32?) -> SQLiteValue {
    value.map { SQLiteValue.int(Int($0)) } ?? .null
}

func portJSON(_ port: RuntimePortMapping) -> [String: Any] {
    [
        "hostPort": port.hostPort.map { $0 as Any } ?? NSNull(),
        "containerPort": port.containerPort,
        "protocol": port.protocolName.rawValue,
        "bindAddress": port.bindAddress ?? NSNull()
    ]
}

func networkJSON(_ network: RuntimeNetworkAttachment) -> [String: Any] {
    [
        "name": network.name,
        "kind": network.kind ?? NSNull(),
        "address": network.address ?? NSNull(),
        "gateway": network.gateway ?? NSNull(),
        "interfaceName": network.interfaceName ?? NSNull(),
        "hostname": network.hostname ?? NSNull(),
        "ipv4Address": network.ipv4Address ?? NSNull(),
        "ipv4Gateway": network.ipv4Gateway ?? NSNull(),
        "ipv6Address": network.ipv6Address ?? NSNull(),
        "macAddress": network.macAddress ?? NSNull(),
        "mtu": network.mtu.map { $0 as Any } ?? NSNull()
    ]
}

func mountJSON(_ mount: RuntimeMountReference) -> [String: Any] {
    [
        "source": mount.source,
        "target": mount.target,
        "access": mount.access.rawValue
    ]
}
