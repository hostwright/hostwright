import HostwrightCore
import HostwrightRuntime

public struct StateProjectRecord: Equatable, Sendable {
    public let id: String
    public let name: String
    public let manifestPath: String?
    public let manifestHash: String
    public let createdAt: String
    public let updatedAt: String
    public let resourceUUID: String
    public let manifestVersion: Int
    public let mutationProvider: String?
    public let providerGeneration: Int

    public init(
        id: String,
        name: String,
        manifestPath: String?,
        manifestHash: String,
        createdAt: String,
        updatedAt: String,
        resourceUUID: String? = nil,
        manifestVersion: Int = 1,
        mutationProvider: String? = nil,
        providerGeneration: Int = 0
    ) {
        self.id = id
        self.name = name
        self.manifestPath = manifestPath
        self.manifestHash = manifestHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resourceUUID = resourceUUID ?? HostwrightResourceUUID.legacy(kind: "project", identifier: id)
        self.manifestVersion = manifestVersion
        self.mutationProvider = mutationProvider
        self.providerGeneration = providerGeneration
    }
}

public struct DesiredServiceRecord: Equatable, Sendable {
    public let id: String
    public let projectID: String
    public let serviceName: String
    public let image: String
    public let commandJSON: String
    public let portsJSON: String
    public let mountsJSON: String
    public let environmentJSONRedacted: String
    public let manifestHash: String
    public let desiredGeneration: Int
    public let createdAt: String
    public let updatedAt: String
    public let resourceUUID: String
    public let resourceGeneration: Int
    public let mutationProvider: String?

    public init(
        id: String,
        projectID: String,
        serviceName: String,
        image: String,
        commandJSON: String,
        portsJSON: String,
        mountsJSON: String,
        environmentJSONRedacted: String,
        manifestHash: String,
        desiredGeneration: Int,
        createdAt: String,
        updatedAt: String,
        resourceUUID: String? = nil,
        resourceGeneration: Int = 1,
        mutationProvider: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.serviceName = serviceName
        self.image = image
        self.commandJSON = commandJSON
        self.portsJSON = portsJSON
        self.mountsJSON = mountsJSON
        self.environmentJSONRedacted = environmentJSONRedacted
        self.manifestHash = manifestHash
        self.desiredGeneration = desiredGeneration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resourceUUID = resourceUUID ?? HostwrightResourceUUID.legacy(
            kind: "service",
            identifier: "\(projectID):\(serviceName)"
        )
        self.resourceGeneration = resourceGeneration
        self.mutationProvider = mutationProvider
    }
}

public struct ObservedRuntimeSnapshotRecord: Equatable, Sendable {
    public let id: String
    public let projectID: String
    public let runtimeAdapter: String
    public let runtimeName: String
    public let runtimeVersion: String?
    public let observedAt: String
    public let parserVersion: String
    public let rawOutputHash: String?
    public let redactedSummary: String
    public let capabilitiesJSON: String

    public init(
        id: String,
        projectID: String,
        runtimeAdapter: String,
        runtimeName: String,
        runtimeVersion: String?,
        observedAt: String,
        parserVersion: String,
        rawOutputHash: String?,
        redactedSummary: String,
        capabilitiesJSON: String
    ) {
        self.id = id
        self.projectID = projectID
        self.runtimeAdapter = runtimeAdapter
        self.runtimeName = runtimeName
        self.runtimeVersion = runtimeVersion
        self.observedAt = observedAt
        self.parserVersion = parserVersion
        self.rawOutputHash = rawOutputHash
        self.redactedSummary = redactedSummary
        self.capabilitiesJSON = capabilitiesJSON
    }
}

public struct ObservedServiceRecord: Equatable, Sendable {
    public let id: String
    public let snapshotID: String
    public let projectName: String
    public let serviceName: String
    public let instanceName: String?
    public let resourceIdentifier: String
    public let image: String?
    public let lifecycleState: RuntimeLifecycleState
    public let healthState: RuntimeHealthState
    public let portsJSON: String
    public let networksJSON: String
    public let mountsJSON: String
    public let runtimeIdentifiersJSON: String

    public init(
        id: String,
        snapshotID: String,
        projectName: String,
        serviceName: String,
        instanceName: String?,
        resourceIdentifier: String,
        image: String?,
        lifecycleState: RuntimeLifecycleState,
        healthState: RuntimeHealthState,
        portsJSON: String,
        networksJSON: String = "[]",
        mountsJSON: String,
        runtimeIdentifiersJSON: String
    ) {
        self.id = id
        self.snapshotID = snapshotID
        self.projectName = projectName
        self.serviceName = serviceName
        self.instanceName = instanceName
        self.resourceIdentifier = resourceIdentifier
        self.image = image
        self.lifecycleState = lifecycleState
        self.healthState = healthState
        self.portsJSON = portsJSON
        self.networksJSON = networksJSON
        self.mountsJSON = mountsJSON
        self.runtimeIdentifiersJSON = runtimeIdentifiersJSON
    }
}

public enum StateEventSeverity: String, Equatable, Sendable {
    case info
    case warning
    case error
}

public struct EventRecord: Equatable, Sendable {
    public let id: String
    public let timestamp: String
    public let severity: StateEventSeverity
    public let type: String
    public let source: String
    public let projectID: String?
    public let serviceName: String?
    public let runtimeAdapter: String?
    public let message: String
    public let payloadJSONRedacted: String

    public init(
        id: String,
        timestamp: String,
        severity: StateEventSeverity,
        type: String,
        source: String,
        projectID: String?,
        serviceName: String?,
        runtimeAdapter: String?,
        message: String,
        payloadJSONRedacted: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.type = type
        self.source = source
        self.projectID = projectID
        self.serviceName = serviceName
        self.runtimeAdapter = runtimeAdapter
        self.message = message
        self.payloadJSONRedacted = payloadJSONRedacted
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> EventRecord {
        EventRecord(
            id: id,
            timestamp: timestamp,
            severity: severity,
            type: type,
            source: source,
            projectID: projectID,
            serviceName: serviceName,
            runtimeAdapter: runtimeAdapter,
            message: policy.redact(message),
            payloadJSONRedacted: policy.redact(payloadJSONRedacted)
        )
    }
}

public enum OperationStatus: String, Equatable, Sendable {
    case planned
    case recorded
    case succeeded
    case failed
    case abandoned
}

public struct OperationRecord: Equatable, Sendable {
    public let id: String
    public let createdAt: String
    public let updatedAt: String
    public let plannedActionType: String
    public let projectID: String?
    public let serviceName: String?
    public let status: OperationStatus
    public let idempotencyKey: String
    public let planHash: String
    public let payloadJSONRedacted: String

    public init(
        id: String,
        createdAt: String,
        updatedAt: String,
        plannedActionType: String,
        projectID: String?,
        serviceName: String?,
        status: OperationStatus,
        idempotencyKey: String,
        planHash: String,
        payloadJSONRedacted: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.plannedActionType = plannedActionType
        self.projectID = projectID
        self.serviceName = serviceName
        self.status = status
        self.idempotencyKey = idempotencyKey
        self.planHash = planHash
        self.payloadJSONRedacted = payloadJSONRedacted
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> OperationRecord {
        OperationRecord(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            plannedActionType: plannedActionType,
            projectID: projectID,
            serviceName: serviceName,
            status: status,
            idempotencyKey: idempotencyKey,
            planHash: planHash,
            payloadJSONRedacted: policy.redact(payloadJSONRedacted)
        )
    }
}

public enum OperationGroupStatus: String, Equatable, Sendable {
    case active
    case succeeded
    case failed
    case interrupted
}

public struct OperationGroupRecord: Equatable, Sendable {
    public let id: String
    public let operationID: String
    public let groupKind: String
    public let projectID: String?
    public let serviceName: String?
    public let plannedActionType: String
    public let status: OperationGroupStatus
    public let groupIdempotencyKey: String
    public let planHash: String
    public let checkpoint: String
    public let lockOwner: String?
    public let lockExpiresAt: String?
    public let rollbackAvailable: Bool
    public let manualRecoveryHintRedacted: String
    public let createdAt: String
    public let updatedAt: String
    public let metadataJSONRedacted: String
    public let fencingToken: String
    public let intentJSONRedacted: String
    public let compensationJSONRedacted: String
    public let verificationJSONRedacted: String

    public init(
        id: String,
        operationID: String,
        groupKind: String,
        projectID: String?,
        serviceName: String?,
        plannedActionType: String,
        status: OperationGroupStatus,
        groupIdempotencyKey: String,
        planHash: String,
        checkpoint: String,
        lockOwner: String?,
        lockExpiresAt: String?,
        rollbackAvailable: Bool,
        manualRecoveryHintRedacted: String,
        createdAt: String,
        updatedAt: String,
        metadataJSONRedacted: String,
        fencingToken: String? = nil,
        intentJSONRedacted: String = "{}",
        compensationJSONRedacted: String = "[]",
        verificationJSONRedacted: String = "{}"
    ) {
        self.id = id
        self.operationID = operationID
        self.groupKind = groupKind
        self.projectID = projectID
        self.serviceName = serviceName
        self.plannedActionType = plannedActionType
        self.status = status
        self.groupIdempotencyKey = groupIdempotencyKey
        self.planHash = planHash
        self.checkpoint = checkpoint
        self.lockOwner = lockOwner
        self.lockExpiresAt = lockExpiresAt
        self.rollbackAvailable = rollbackAvailable
        self.manualRecoveryHintRedacted = manualRecoveryHintRedacted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadataJSONRedacted = metadataJSONRedacted
        self.fencingToken = fencingToken ?? HostwrightResourceUUID.legacy(kind: "operation-fence", identifier: id)
        self.intentJSONRedacted = intentJSONRedacted
        self.compensationJSONRedacted = compensationJSONRedacted
        self.verificationJSONRedacted = verificationJSONRedacted
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> OperationGroupRecord {
        OperationGroupRecord(
            id: id,
            operationID: operationID,
            groupKind: groupKind,
            projectID: projectID,
            serviceName: serviceName,
            plannedActionType: plannedActionType,
            status: status,
            groupIdempotencyKey: groupIdempotencyKey,
            planHash: planHash,
            checkpoint: checkpoint,
            lockOwner: lockOwner.map(policy.redact),
            lockExpiresAt: lockExpiresAt,
            rollbackAvailable: rollbackAvailable,
            manualRecoveryHintRedacted: policy.redact(manualRecoveryHintRedacted),
            createdAt: createdAt,
            updatedAt: updatedAt,
            metadataJSONRedacted: (try? StateJSON.redactedJSON(metadataJSONRedacted, using: policy)) ?? "{}",
            fencingToken: fencingToken,
            intentJSONRedacted: (try? StateJSON.redactedJSON(intentJSONRedacted, using: policy)) ?? "{}",
            compensationJSONRedacted: (try? StateJSON.redactedJSON(compensationJSONRedacted, using: policy)) ?? "[]",
            verificationJSONRedacted: (try? StateJSON.redactedJSON(verificationJSONRedacted, using: policy)) ?? "{}"
        )
    }
}

public enum OperationGroupStepDirection: String, Equatable, Sendable {
    case forward
    case rollback
}

public enum OperationGroupStepStatus: String, Equatable, Sendable {
    case planned
    case started
    case succeeded
    case failed
    case unsupported
}

public struct OperationGroupStepRecord: Equatable, Sendable {
    public let id: String
    public let groupID: String
    public let stepKey: String
    public let direction: OperationGroupStepDirection
    public let plannedActionType: String
    public let serviceName: String?
    public let resourceIdentifier: String?
    public let stepIdempotencyKey: String
    public let status: OperationGroupStepStatus
    public let startedAt: String?
    public let updatedAt: String
    public let finishedAt: String?
    public let lastErrorRedacted: String?
    public let manualRecoveryHintRedacted: String
    public let metadataJSONRedacted: String

    public init(
        id: String,
        groupID: String,
        stepKey: String,
        direction: OperationGroupStepDirection,
        plannedActionType: String,
        serviceName: String?,
        resourceIdentifier: String?,
        stepIdempotencyKey: String,
        status: OperationGroupStepStatus,
        startedAt: String?,
        updatedAt: String,
        finishedAt: String?,
        lastErrorRedacted: String?,
        manualRecoveryHintRedacted: String,
        metadataJSONRedacted: String
    ) {
        self.id = id
        self.groupID = groupID
        self.stepKey = stepKey
        self.direction = direction
        self.plannedActionType = plannedActionType
        self.serviceName = serviceName
        self.resourceIdentifier = resourceIdentifier
        self.stepIdempotencyKey = stepIdempotencyKey
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.lastErrorRedacted = lastErrorRedacted
        self.manualRecoveryHintRedacted = manualRecoveryHintRedacted
        self.metadataJSONRedacted = metadataJSONRedacted
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> OperationGroupStepRecord {
        OperationGroupStepRecord(
            id: id,
            groupID: groupID,
            stepKey: stepKey,
            direction: direction,
            plannedActionType: plannedActionType,
            serviceName: serviceName,
            resourceIdentifier: resourceIdentifier.map(policy.redact),
            stepIdempotencyKey: stepIdempotencyKey,
            status: status,
            startedAt: startedAt,
            updatedAt: updatedAt,
            finishedAt: finishedAt,
            lastErrorRedacted: lastErrorRedacted.map(policy.redact),
            manualRecoveryHintRedacted: policy.redact(manualRecoveryHintRedacted),
            metadataJSONRedacted: (try? StateJSON.redactedJSON(metadataJSONRedacted, using: policy)) ?? "{}"
        )
    }
}

public struct HealthCheckResultRecord: Equatable, Sendable {
    public let id: String
    public let projectID: String?
    public let serviceName: String
    public let checkedAt: String
    public let status: RuntimeHealthCheckStatus
    public let exitStatus: Int32?
    public let timedOut: Bool
    public let commandJSONRedacted: String
    public let stdoutRedacted: String
    public let stderrRedacted: String
    public let metadataJSONRedacted: String

    public init(
        id: String,
        projectID: String?,
        serviceName: String,
        checkedAt: String,
        status: RuntimeHealthCheckStatus,
        exitStatus: Int32?,
        timedOut: Bool,
        commandJSONRedacted: String,
        stdoutRedacted: String,
        stderrRedacted: String,
        metadataJSONRedacted: String
    ) {
        self.id = id
        self.projectID = projectID
        self.serviceName = serviceName
        self.checkedAt = checkedAt
        self.status = status
        self.exitStatus = exitStatus
        self.timedOut = timedOut
        self.commandJSONRedacted = commandJSONRedacted
        self.stdoutRedacted = stdoutRedacted
        self.stderrRedacted = stderrRedacted
        self.metadataJSONRedacted = metadataJSONRedacted
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> HealthCheckResultRecord {
        HealthCheckResultRecord(
            id: id,
            projectID: projectID,
            serviceName: serviceName,
            checkedAt: checkedAt,
            status: status,
            exitStatus: exitStatus,
            timedOut: timedOut,
            commandJSONRedacted: policy.redact(commandJSONRedacted),
            stdoutRedacted: policy.redact(stdoutRedacted),
            stderrRedacted: policy.redact(stderrRedacted),
            metadataJSONRedacted: policy.redact(metadataJSONRedacted)
        )
    }
}

public enum RestartPolicyStateStatus: String, Equatable, Sendable {
    case active
    case backingOff
    case operatorHold
    case manualDisabled
    case crashLoopBlocked
}

public enum RestartPolicyStateDefaults {
    public static let maxAttempts = 3
    public static let backoffSeconds = 60
}

public struct RestartPolicyStateRecord: Equatable, Sendable {
    public let id: String
    public let projectID: String
    public let serviceName: String
    public let policy: RuntimeRestartPolicy
    public let status: RestartPolicyStateStatus
    public let attemptCount: Int
    public let maxAttempts: Int
    public let backoffSeconds: Int
    public let backoffUntil: String?
    public let lastFailureAt: String?
    public let updatedAt: String
    public let metadataJSONRedacted: String

    public init(
        id: String,
        projectID: String,
        serviceName: String,
        policy: RuntimeRestartPolicy,
        status: RestartPolicyStateStatus,
        attemptCount: Int,
        maxAttempts: Int = RestartPolicyStateDefaults.maxAttempts,
        backoffSeconds: Int = RestartPolicyStateDefaults.backoffSeconds,
        backoffUntil: String? = nil,
        lastFailureAt: String? = nil,
        updatedAt: String,
        metadataJSONRedacted: String
    ) {
        self.id = id
        self.projectID = projectID
        self.serviceName = serviceName
        self.policy = policy
        self.status = status
        self.attemptCount = max(0, attemptCount)
        self.maxAttempts = max(1, maxAttempts)
        self.backoffSeconds = max(1, backoffSeconds)
        self.backoffUntil = backoffUntil
        self.lastFailureAt = lastFailureAt
        self.updatedAt = updatedAt
        self.metadataJSONRedacted = metadataJSONRedacted
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> RestartPolicyStateRecord {
        RestartPolicyStateRecord(
            id: id,
            projectID: projectID,
            serviceName: serviceName,
            policy: self.policy,
            status: status,
            attemptCount: attemptCount,
            maxAttempts: maxAttempts,
            backoffSeconds: backoffSeconds,
            backoffUntil: backoffUntil,
            lastFailureAt: lastFailureAt,
            updatedAt: updatedAt,
            metadataJSONRedacted: policy.redact(metadataJSONRedacted)
        )
    }
}

public enum RestartRecoveryStatus: String, Equatable, Sendable {
    case prepared
    case stopSucceeded
    case succeeded
    case failed
}

public struct RestartRecoveryRecord: Equatable, Sendable {
    public let id: String
    public let operationID: String
    public let projectID: String?
    public let serviceName: String
    public let resourceIdentifier: String
    public let planHash: String
    public let status: RestartRecoveryStatus
    public let completedStepsJSONRedacted: String
    public let manualRecoveryHintRedacted: String
    public let createdAt: String
    public let updatedAt: String
    public let metadataJSONRedacted: String

    public init(
        id: String,
        operationID: String,
        projectID: String?,
        serviceName: String,
        resourceIdentifier: String,
        planHash: String,
        status: RestartRecoveryStatus,
        completedStepsJSONRedacted: String,
        manualRecoveryHintRedacted: String,
        createdAt: String,
        updatedAt: String,
        metadataJSONRedacted: String
    ) {
        self.id = id
        self.operationID = operationID
        self.projectID = projectID
        self.serviceName = serviceName
        self.resourceIdentifier = resourceIdentifier
        self.planHash = planHash
        self.status = status
        self.completedStepsJSONRedacted = completedStepsJSONRedacted
        self.manualRecoveryHintRedacted = manualRecoveryHintRedacted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadataJSONRedacted = metadataJSONRedacted
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> RestartRecoveryRecord {
        RestartRecoveryRecord(
            id: id,
            operationID: operationID,
            projectID: projectID,
            serviceName: serviceName,
            resourceIdentifier: policy.redact(resourceIdentifier),
            planHash: planHash,
            status: status,
            completedStepsJSONRedacted: policy.redact(completedStepsJSONRedacted),
            manualRecoveryHintRedacted: policy.redact(manualRecoveryHintRedacted),
            createdAt: createdAt,
            updatedAt: updatedAt,
            metadataJSONRedacted: policy.redact(metadataJSONRedacted)
        )
    }
}

public struct OwnershipRecord: Equatable, Sendable {
    public let id: String
    public let resourceIdentifier: String
    public let resourceType: String
    public let projectID: String?
    public let serviceName: String?
    public let runtimeAdapter: String
    public let createdAt: String
    public let observedAt: String
    public let cleanupEligible: Bool
    public let metadataJSONRedacted: String
    public let identityVersion: Int
    public let resourceUUID: String
    public let resourceGeneration: Int
    public let projectResourceUUID: String?
    public let projectGeneration: Int
    public let providerGeneration: Int
    public let fencingToken: String

    public init(
        id: String,
        resourceIdentifier: String,
        resourceType: String,
        projectID: String?,
        serviceName: String?,
        runtimeAdapter: String,
        createdAt: String,
        observedAt: String,
        cleanupEligible: Bool,
        metadataJSONRedacted: String,
        identityVersion: Int = 1,
        resourceUUID: String? = nil,
        resourceGeneration: Int = 1,
        projectResourceUUID: String? = nil,
        projectGeneration: Int = 1,
        providerGeneration: Int = 1,
        fencingToken: String? = nil
    ) {
        self.id = id
        self.resourceIdentifier = resourceIdentifier
        self.resourceType = resourceType
        self.projectID = projectID
        self.serviceName = serviceName
        self.runtimeAdapter = runtimeAdapter
        self.createdAt = createdAt
        self.observedAt = observedAt
        self.cleanupEligible = cleanupEligible
        self.metadataJSONRedacted = metadataJSONRedacted
        self.identityVersion = identityVersion
        self.resourceUUID = resourceUUID ?? HostwrightResourceUUID.legacy(
            kind: "ownership",
            identifier: id
        )
        self.resourceGeneration = resourceGeneration
        self.projectResourceUUID = projectResourceUUID ?? projectID.map {
            HostwrightResourceUUID.legacy(kind: "project", identifier: $0)
        }
        self.projectGeneration = projectGeneration
        self.providerGeneration = providerGeneration
        self.fencingToken = fencingToken ?? HostwrightResourceUUID.legacy(kind: "ownership-fence", identifier: id)
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> OwnershipRecord {
        OwnershipRecord(
            id: id,
            resourceIdentifier: resourceIdentifier,
            resourceType: resourceType,
            projectID: projectID,
            serviceName: serviceName,
            runtimeAdapter: runtimeAdapter,
            createdAt: createdAt,
            observedAt: observedAt,
            cleanupEligible: cleanupEligible,
            metadataJSONRedacted: policy.redact(metadataJSONRedacted),
            identityVersion: identityVersion,
            resourceUUID: resourceUUID,
            resourceGeneration: resourceGeneration,
            projectResourceUUID: projectResourceUUID,
            projectGeneration: projectGeneration,
            providerGeneration: providerGeneration,
            fencingToken: fencingToken
        )
    }
}
