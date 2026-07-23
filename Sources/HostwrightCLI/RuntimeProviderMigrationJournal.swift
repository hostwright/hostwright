import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

actor SQLiteRuntimeProviderMigrationJournal: RuntimeProviderMigrationJournaling {
    private let store: SQLiteStateStore
    private let plan: RuntimeProviderMigrationPlan
    private let request: RuntimeProviderMigrationRequest
    private let projectID: String

    init(
        store: SQLiteStateStore,
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest
    ) {
        self.store = store
        self.plan = plan
        self.request = request
        self.projectID = "project-\(plan.projectName)"
    }

    func beginOrResume(
        _ intent: RuntimeProviderMigrationIntent
    ) async throws -> RuntimeProviderMigrationAcquireResult {
        guard intent.confirmationToken == plan.confirmationToken,
              intent.projectUUID == plan.projectUUID,
              intent.projectGeneration == plan.projectGeneration,
              intent.sourceProviderID == plan.sourceProviderID,
              intent.sourceProviderGeneration == plan.sourceProviderGeneration,
              intent.targetProviderID == plan.targetProviderID,
              intent.targetProviderGeneration == plan.targetProviderGeneration else {
            throw RuntimeProviderMigrationError.planChanged
        }
        let groupID = Self.groupID(operationID: intent.operationID)
        let timestamp = hostwrightTimestamp()
        let encodedPlan = try Self.encodedPlan(plan)
        let group = OperationGroupRecord(
            id: groupID,
            operationID: intent.operationID,
            groupKind: "runtime-provider-migration",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: "migrateRuntimeProvider",
            status: .active,
            groupIdempotencyKey: intent.confirmationToken,
            planHash: intent.confirmationToken,
            checkpoint: Self.checkpointName(.intentPersisted),
            lockOwner: "hostwright-cli:\(intent.operationID)",
            lockExpiresAt: hostwrightTimestampAdding(seconds: 900, to: timestamp),
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "Re-run the exact confirmed runtime migration to resume from its durable checkpoint.",
            createdAt: timestamp,
            updatedAt: timestamp,
            metadataJSONRedacted: jsonPayload([
                "sourceProvider": intent.sourceProviderID.rawValue,
                "targetProvider": intent.targetProviderID.rawValue
            ]),
            fencingToken: intent.fencingToken,
            intentJSONRedacted: jsonPayload([
                "confirmationToken": intent.confirmationToken,
                "planJSON": encodedPlan,
                "projectGeneration": intent.projectGeneration,
                "projectUUID": intent.projectUUID,
                "sourceProvider": intent.sourceProviderID.rawValue,
                "sourceProviderGeneration": intent.sourceProviderGeneration,
                "targetProvider": intent.targetProviderID.rawValue,
                "targetProviderGeneration": intent.targetProviderGeneration
            ]),
            compensationJSONRedacted: jsonPayloadArray(
                plan.rollbackActions.map {
                    [
                        "kind": $0.kind.rawValue,
                        "provider": $0.providerID.rawValue,
                        "resourceUUID": $0.resourceUUID
                    ]
                }
            ),
            verificationJSONRedacted: jsonPayload(["status": "pending"])
        )
        let acquired = try store.operationGroups.acquire(group)
        if let existing = acquired.existingActive {
            guard existing.operationID == intent.operationID,
                  existing.fencingToken == intent.fencingToken,
                  existing.groupIdempotencyKey == intent.confirmationToken else {
                return .conflict(activeOperationID: existing.operationID)
            }
            guard let checkpoint = Self.checkpoint(named: existing.checkpoint) else {
                throw RuntimeProviderMigrationError.planChanged
            }
            return .resumed(
                RuntimeProviderMigrationLease(
                    operationID: intent.operationID,
                    fencingToken: intent.fencingToken,
                    confirmationToken: intent.confirmationToken,
                    checkpoint: checkpoint
                )
            )
        }
        guard acquired.acquired?.id == groupID else {
            throw RuntimeProviderMigrationError.fenceLost
        }
        return .acquired(
            RuntimeProviderMigrationLease(
                operationID: intent.operationID,
                fencingToken: intent.fencingToken,
                confirmationToken: intent.confirmationToken,
                checkpoint: .intentPersisted
            )
        )
    }

    func verifyFence(operationID: String, fencingToken: String) async throws -> Bool {
        guard let group = try store.operationGroups.load(id: Self.groupID(operationID: operationID)) else {
            return false
        }
        return group.status == .active && group.fencingToken == fencingToken
    }

    func recordCheckpoint(
        operationID: String,
        fencingToken: String,
        checkpoint: RuntimeProviderMigrationCheckpoint,
        verificationSHA256: String
    ) async throws {
        let timestamp = hostwrightTimestamp()
        let checkpointName = Self.checkpointName(checkpoint)
        try store.operationGroups.recordCheckpoint(
            groupID: Self.groupID(operationID: operationID),
            expectedFencingToken: fencingToken,
            checkpoint: checkpointName,
            verificationJSONRedacted: jsonPayload([
                "checkpoint": checkpointName,
                "verification": verificationSHA256
            ]),
            updatedAt: timestamp
        )
        try store.operationGroupSteps.append(
            OperationGroupStepRecord(
                id: "migration-step-\(operationID)-\(checkpoint.rawValue)",
                groupID: Self.groupID(operationID: operationID),
                stepKey: checkpointName,
                direction: .forward,
                plannedActionType: "migrateRuntimeProvider",
                serviceName: nil,
                resourceIdentifier: nil,
                stepIdempotencyKey: "\(plan.confirmationToken):\(checkpoint.rawValue)",
                status: .succeeded,
                startedAt: timestamp,
                updatedAt: timestamp,
                finishedAt: timestamp,
                lastErrorRedacted: nil,
                manualRecoveryHintRedacted: "Resume from the latest verified runtime migration checkpoint.",
                metadataJSONRedacted: jsonPayload(["verification": verificationSHA256])
            )
        )
    }

    func commitProviderBinding(
        _ commit: RuntimeProviderMigrationBindingCommit
    ) async throws -> RuntimeProviderMigrationBindingCommitResult {
        guard commit.confirmationToken == plan.confirmationToken,
              commit.projectUUID == plan.projectUUID,
              commit.projectGeneration == plan.projectGeneration,
              commit.expectedSourceProviderID == plan.sourceProviderID,
              commit.expectedSourceProviderGeneration == plan.sourceProviderGeneration,
              commit.targetProviderID == plan.targetProviderID,
              commit.targetProviderGeneration == plan.targetProviderGeneration,
              try await verifyFence(
                  operationID: commit.operationID,
                  fencingToken: commit.fencingToken
              ) else {
            throw RuntimeProviderMigrationError.fenceLost
        }
        let requestByUUID = Dictionary(uniqueKeysWithValues: request.resources.map {
            ($0.ownership.resourceUUID, $0)
        })
        let stateResources = try plan.resources.map { resource -> RuntimeProviderMigrationStateResource in
            guard let requested = requestByUUID[resource.resourceUUID] else {
                throw RuntimeProviderMigrationError.planChanged
            }
            let identityVersion = resource.resourceIdentifier == requested.desiredService.identity.legacyManagedResourceIdentifier
                ? 1
                : RuntimeManagedResourceIdentity.currentVersion
            return RuntimeProviderMigrationStateResource(
                resourceIdentifier: resource.resourceIdentifier,
                serviceName: requested.desiredService.identity.serviceName,
                identityVersion: identityVersion,
                resourceUUID: resource.resourceUUID,
                resourceGeneration: requested.ownership.resourceGeneration
            )
        }
        let result = try store.desiredStates.commitRuntimeProviderMigration(
            projectResourceUUID: commit.projectUUID,
            projectGeneration: commit.projectGeneration,
            expectedSourceProviderID: commit.expectedSourceProviderID,
            expectedSourceProviderGeneration: commit.expectedSourceProviderGeneration,
            targetProviderID: commit.targetProviderID,
            targetProviderGeneration: commit.targetProviderGeneration,
            targetFencingToken: commit.fencingToken,
            resources: stateResources,
            timestamp: hostwrightTimestamp()
        )
        switch result {
        case .committed:
            return .committed
        case .alreadyCommitted:
            return .alreadyCommitted
        }
    }

    func finish(
        operationID: String,
        fencingToken: String,
        status: RuntimeProviderMigrationTerminalStatus,
        checkpoint: RuntimeProviderMigrationCheckpoint
    ) async throws {
        guard try await verifyFence(operationID: operationID, fencingToken: fencingToken) else {
            throw RuntimeProviderMigrationError.fenceLost
        }
        let stateStatus: OperationGroupStatus
        switch status {
        case .succeeded:
            stateStatus = .succeeded
        case .failed:
            stateStatus = .failed
        case .cancelled:
            stateStatus = .interrupted
        }
        try store.operationGroups.finish(
            groupID: Self.groupID(operationID: operationID),
            status: stateStatus,
            checkpoint: Self.checkpointName(checkpoint),
            manualRecoveryHintRedacted: status == .succeeded
                ? "Runtime provider migration completed and the new project generation is authoritative."
                : "Inspect the verified compensation state before retrying the migration.",
            updatedAt: hostwrightTimestamp(),
            metadataJSONRedacted: jsonPayload([
                "checkpoint": Self.checkpointName(checkpoint),
                "status": status.rawValue
            ])
        )
    }

    static func resumableIdentity(
        store: SQLiteStateStore,
        projectID: String,
        confirmationToken: String
    ) throws -> (operationID: String, fencingToken: String)? {
        let matching = try store.operationGroups.loadProject(projectID: projectID).filter {
            $0.groupKind == "runtime-provider-migration" &&
                $0.groupIdempotencyKey == confirmationToken &&
                $0.status == .active
        }
        guard matching.count <= 1 else {
            throw StateStoreError.invalidRecord("Multiple active runtime migrations share one confirmation token.")
        }
        return matching.first.map { ($0.operationID, $0.fencingToken) }
    }

    static func resumableRecord(
        store: SQLiteStateStore,
        projectID: String,
        confirmationToken: String
    ) throws -> (operationID: String, fencingToken: String, plan: RuntimeProviderMigrationPlan)? {
        let matching = try store.operationGroups.loadProject(projectID: projectID).filter {
            $0.groupKind == "runtime-provider-migration" &&
                $0.groupIdempotencyKey == confirmationToken &&
                $0.status == .active
        }
        guard matching.count <= 1 else {
            throw StateStoreError.invalidRecord("Multiple active runtime migrations share one confirmation token.")
        }
        guard let group = matching.first,
              let data = group.intentJSONRedacted.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let planJSON = object["planJSON"] as? String,
              let planData = planJSON.data(using: .utf8) else {
            return nil
        }
        let plan = try JSONDecoder().decode(RuntimeProviderMigrationPlan.self, from: planData)
        guard plan.confirmationToken == confirmationToken else {
            throw StateStoreError.invalidRecord("Stored runtime migration plan token does not match its operation group.")
        }
        return (group.operationID, group.fencingToken, plan)
    }

    private static func groupID(operationID: String) -> String {
        "runtime-provider-migration-\(operationID)"
    }

    private static func checkpointName(_ checkpoint: RuntimeProviderMigrationCheckpoint) -> String {
        switch checkpoint {
        case .intentPersisted: "migration-intent-persisted"
        case .sourceQuiesced: "migration-source-quiesced"
        case .sourceVerified: "migration-source-verified"
        case .targetCreated: "migration-target-created"
        case .targetVerified: "migration-target-verified"
        case .targetRunningRestored: "migration-target-running-restored"
        case .bindingCommitted: "migration-binding-committed"
        case .sourceRetired: "migration-source-retired"
        }
    }

    private static func checkpoint(named name: String) -> RuntimeProviderMigrationCheckpoint? {
        RuntimeProviderMigrationCheckpoint.allCases.first { checkpointName($0) == name }
    }

    private static func encodedPlan(_ plan: RuntimeProviderMigrationPlan) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(plan), as: UTF8.self)
    }
}

private func jsonPayloadArray(_ values: [[String: Any]]) -> String {
    let redacted = values.map { value in
        redactJSONValue(value) as? [String: Any] ?? [:]
    }
    guard JSONSerialization.isValidJSONObject(redacted),
          let data = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return text
}
