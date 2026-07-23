import Foundation
import HostwrightCore
import HostwrightRuntime

public struct OperationGroupAcquireResult: Equatable, Sendable {
    public let acquired: OperationGroupRecord?
    public let existingActive: OperationGroupRecord?

    public init(acquired: OperationGroupRecord?, existingActive: OperationGroupRecord?) {
        self.acquired = acquired
        self.existingActive = existingActive
    }
}

public struct OperationGroupRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func acquire(
        _ group: OperationGroupRecord,
        currentTimestamp: String = ISO8601DateFormatter().string(from: Date())
    ) throws -> OperationGroupAcquireResult {
        guard group.status == .active else {
            throw StateStoreError.invalidRecord("Operation group acquire requires active status.")
        }
        guard HostwrightResourceUUID.isValid(group.fencingToken),
              StateJSON.isObject(group.metadataJSONRedacted),
              StateJSON.isObject(group.intentJSONRedacted),
              StateJSON.isArray(group.compensationJSONRedacted),
              StateJSON.isObject(group.verificationJSONRedacted) else {
            throw StateStoreError.invalidRecord("Operation group fencing and saga payloads must use a valid UUID, JSON objects for metadata/intent/verification, and a JSON array for compensation.")
        }
        let redacted = group.redacted()
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                if let existing = try active(groupIdempotencyKey: redacted.groupIdempotencyKey, on: connection) {
                    if isExpired(existing, currentTimestamp: currentTimestamp) {
                        try expire(existing, currentTimestamp: currentTimestamp, on: connection)
                    } else {
                        return OperationGroupAcquireResult(acquired: nil, existingActive: existing)
                    }
                }
                if let projectID = redacted.projectID,
                   let existing = try active(projectID: projectID, on: connection) {
                    if isExpired(existing, currentTimestamp: currentTimestamp) {
                        try expire(existing, currentTimestamp: currentTimestamp, on: connection)
                    } else {
                        return OperationGroupAcquireResult(acquired: nil, existingActive: existing)
                    }
                }
                try insert(redacted, on: connection)
                return OperationGroupAcquireResult(acquired: redacted, existingActive: nil)
            }
        }
    }

    public func finish(
        groupID: String,
        status: OperationGroupStatus,
        checkpoint: String,
        manualRecoveryHintRedacted: String,
        updatedAt: String,
        metadataJSONRedacted: String
    ) throws {
        guard status != .active else {
            throw StateStoreError.invalidRecord("Operation group finish requires a terminal status.")
        }
        guard !checkpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StateStoreError.invalidRecord("Operation group finish requires a checkpoint.")
        }
        guard StateJSON.isObject(metadataJSONRedacted) else {
            throw StateStoreError.invalidRecord("Operation group finish metadata must be a JSON object.")
        }
        let redactedHint = RuntimeRedactionPolicy.default.redact(manualRecoveryHintRedacted)
        let redactedMetadata = try StateJSON.redactedJSON(metadataJSONRedacted)
        try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    "SELECT status FROM operation_groups WHERE id = ? LIMIT 1",
                    bindings: [.text(groupID)]
                )
                guard let currentStatus = rows.first?.first ?? nil else {
                    throw StateStoreError.notFound("Operation group '\(groupID)' does not exist.")
                }
                guard currentStatus == OperationGroupStatus.active.rawValue else {
                    throw StateStoreError.invalidRecord("Operation group '\(groupID)' is already terminal with status '\(currentStatus)'.")
                }
                try connection.run(
                    """
                    UPDATE operation_groups
                    SET status = ?, checkpoint = ?, lock_owner = NULL, lock_expires_at = NULL,
                        manual_recovery_hint_redacted = ?, updated_at = ?, metadata_json_redacted = ?
                    WHERE id = ? AND status = 'active'
                    """,
                    bindings: [
                        .text(status.rawValue),
                        .text(checkpoint),
                        .text(redactedHint),
                        .text(updatedAt),
                        .text(redactedMetadata),
                        .text(groupID)
                    ]
                )
            }
        }
    }

    public func recordCheckpoint(
        groupID: String,
        expectedFencingToken: String,
        checkpoint: String,
        verificationJSONRedacted: String,
        updatedAt: String
    ) throws {
        guard HostwrightResourceUUID.isValid(expectedFencingToken),
              !checkpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              StateJSON.isObject(verificationJSONRedacted) else {
            throw StateStoreError.invalidRecord(
                "Operation group checkpoint requires a valid fence, name, and verification object."
            )
        }
        let verification = try StateJSON.redactedJSON(verificationJSONRedacted)
        try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    "SELECT status, fencing_token FROM operation_groups WHERE id = ? LIMIT 1",
                    bindings: [.text(groupID)]
                )
                guard rows.count == 1,
                      rows[0][0] == OperationGroupStatus.active.rawValue,
                      rows[0][1] == expectedFencingToken.lowercased() else {
                    throw StateStoreError.invalidRecord(
                        "Operation group checkpoint fence was lost or the group is no longer active."
                    )
                }
                try connection.run(
                    """
                    UPDATE operation_groups
                    SET checkpoint = ?, verification_json_redacted = ?, updated_at = ?
                    WHERE id = ? AND status = 'active' AND fencing_token = ?
                    """,
                    bindings: [
                        .text(checkpoint),
                        .text(verification),
                        .text(updatedAt),
                        .text(groupID),
                        .text(expectedFencingToken.lowercased())
                    ]
                )
            }
        }
    }

    public func loadAll() throws -> [OperationGroupRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, operation_id, group_kind, project_id, service_name, planned_action_type,
                       status, group_idempotency_key, plan_hash, checkpoint, lock_owner, lock_expires_at,
                       rollback_available, manual_recovery_hint_redacted, created_at, updated_at,
                       metadata_json_redacted, fencing_token, intent_json_redacted,
                       compensation_json_redacted, verification_json_redacted
                FROM operation_groups
                ORDER BY created_at ASC, rowid ASC
                """
            )
            return try rows.map(operationGroupRecord(from:))
        }
    }

    public func load(id: String) throws -> OperationGroupRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, operation_id, group_kind, project_id, service_name, planned_action_type,
                       status, group_idempotency_key, plan_hash, checkpoint, lock_owner, lock_expires_at,
                       rollback_available, manual_recovery_hint_redacted, created_at, updated_at,
                       metadata_json_redacted, fencing_token, intent_json_redacted,
                       compensation_json_redacted, verification_json_redacted
                FROM operation_groups
                WHERE id = ?
                LIMIT 1
                """,
                bindings: [.text(id)]
            )
            return try rows.first.map(operationGroupRecord(from:))
        }
    }

    public func latest(groupIdempotencyKey: String) throws -> OperationGroupRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, operation_id, group_kind, project_id, service_name, planned_action_type,
                       status, group_idempotency_key, plan_hash, checkpoint, lock_owner, lock_expires_at,
                       rollback_available, manual_recovery_hint_redacted, created_at, updated_at,
                       metadata_json_redacted, fencing_token, intent_json_redacted,
                       compensation_json_redacted, verification_json_redacted
                FROM operation_groups
                WHERE group_idempotency_key = ?
                ORDER BY updated_at DESC, created_at DESC, rowid DESC
                LIMIT 1
                """,
                bindings: [.text(groupIdempotencyKey)]
            )
            return try rows.first.map(operationGroupRecord(from:))
        }
    }

    public func loadProject(projectID: String) throws -> [OperationGroupRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, operation_id, group_kind, project_id, service_name, planned_action_type,
                       status, group_idempotency_key, plan_hash, checkpoint, lock_owner, lock_expires_at,
                       rollback_available, manual_recovery_hint_redacted, created_at, updated_at,
                       metadata_json_redacted, fencing_token, intent_json_redacted,
                       compensation_json_redacted, verification_json_redacted
                FROM operation_groups
                WHERE project_id = ?
                ORDER BY created_at ASC, rowid ASC
                """,
                bindings: [.text(projectID)]
            )
            return try rows.map(operationGroupRecord(from:))
        }
    }

    private func active(groupIdempotencyKey: String, on connection: SQLiteConnection) throws -> OperationGroupRecord? {
        let rows = try connection.query(
            """
            SELECT id, operation_id, group_kind, project_id, service_name, planned_action_type,
                   status, group_idempotency_key, plan_hash, checkpoint, lock_owner, lock_expires_at,
                   rollback_available, manual_recovery_hint_redacted, created_at, updated_at,
                   metadata_json_redacted, fencing_token, intent_json_redacted,
                   compensation_json_redacted, verification_json_redacted
            FROM operation_groups
            WHERE group_idempotency_key = ? AND status = 'active'
            ORDER BY updated_at DESC, created_at DESC, rowid DESC
            LIMIT 1
            """,
            bindings: [.text(groupIdempotencyKey)]
        )
        return try rows.first.map(operationGroupRecord(from:))
    }

    private func active(projectID: String, on connection: SQLiteConnection) throws -> OperationGroupRecord? {
        let rows = try connection.query(
            """
            SELECT id, operation_id, group_kind, project_id, service_name, planned_action_type,
                   status, group_idempotency_key, plan_hash, checkpoint, lock_owner, lock_expires_at,
                   rollback_available, manual_recovery_hint_redacted, created_at, updated_at,
                   metadata_json_redacted, fencing_token, intent_json_redacted,
                   compensation_json_redacted, verification_json_redacted
            FROM operation_groups
            WHERE project_id = ? AND status = 'active'
            ORDER BY updated_at DESC, created_at DESC, rowid DESC
            LIMIT 1
            """,
            bindings: [.text(projectID)]
        )
        return try rows.first.map(operationGroupRecord(from:))
    }

    private func isExpired(_ group: OperationGroupRecord, currentTimestamp: String) -> Bool {
        guard let lockExpiresAt = group.lockExpiresAt else {
            return false
        }
        return lockExpiresAt <= currentTimestamp
    }

    private func expire(_ group: OperationGroupRecord, currentTimestamp: String, on connection: SQLiteConnection) throws {
        let hint = RuntimeRedactionPolicy.default.redact(
            "Operation group lock expired at checkpoint \(group.checkpoint). Recovery is manual: inspect status, events, logs, and the exact Hostwright-owned resource before retrying with a fresh confirmed plan."
        )
        let metadata = try StateJSON.redactedJSON(StateJSON.encode([
            "expiredLock": true,
            "previousCheckpoint": group.checkpoint,
            "previousStatus": group.status.rawValue
        ]))
        try connection.run(
            """
            UPDATE operation_groups
            SET status = ?, checkpoint = ?, lock_owner = NULL, lock_expires_at = NULL,
                manual_recovery_hint_redacted = ?, updated_at = ?, metadata_json_redacted = ?
            WHERE id = ? AND status = 'active'
            """,
            bindings: [
                .text(OperationGroupStatus.interrupted.rawValue),
                .text("lock-expired"),
                .text(hint),
                .text(currentTimestamp),
                .text(metadata),
                .text(group.id)
            ]
        )
    }

    private func insert(_ group: OperationGroupRecord, on connection: SQLiteConnection) throws {
        try connection.run(
            """
            INSERT INTO operation_groups (
                id, operation_id, group_kind, project_id, service_name, planned_action_type,
                status, group_idempotency_key, plan_hash, checkpoint, lock_owner, lock_expires_at,
                rollback_available, manual_recovery_hint_redacted, created_at, updated_at,
                metadata_json_redacted, fencing_token, intent_json_redacted,
                compensation_json_redacted, verification_json_redacted
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(group.id),
                .text(group.operationID),
                .text(group.groupKind),
                optionalText(group.projectID),
                optionalText(group.serviceName),
                .text(group.plannedActionType),
                .text(group.status.rawValue),
                .text(group.groupIdempotencyKey),
                .text(group.planHash),
                .text(group.checkpoint),
                optionalText(group.lockOwner),
                optionalText(group.lockExpiresAt),
                .bool(group.rollbackAvailable),
                .text(group.manualRecoveryHintRedacted),
                .text(group.createdAt),
                .text(group.updatedAt),
                .text(group.metadataJSONRedacted),
                .text(group.fencingToken),
                .text(group.intentJSONRedacted),
                .text(group.compensationJSONRedacted),
                .text(group.verificationJSONRedacted)
            ]
        )
    }
}

public struct OperationGroupStepRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func append(_ step: OperationGroupStepRecord) throws {
        guard StateJSON.isObject(step.metadataJSONRedacted) else {
            throw StateStoreError.invalidRecord("Operation group step metadata must be a JSON object.")
        }
        let redacted = step.redacted()
        try store.withValidatedConnection { connection in
            try connection.transaction {
                try connection.run(
                    """
                    INSERT INTO operation_group_steps (
                        id, group_id, step_key, direction, planned_action_type, service_name,
                        resource_identifier, step_idempotency_key, status, started_at, updated_at,
                        finished_at, last_error_redacted, manual_recovery_hint_redacted,
                        metadata_json_redacted
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(redacted.id),
                        .text(redacted.groupID),
                        .text(redacted.stepKey),
                        .text(redacted.direction.rawValue),
                        .text(redacted.plannedActionType),
                        optionalText(redacted.serviceName),
                        optionalText(redacted.resourceIdentifier),
                        .text(redacted.stepIdempotencyKey),
                        .text(redacted.status.rawValue),
                        optionalText(redacted.startedAt),
                        .text(redacted.updatedAt),
                        optionalText(redacted.finishedAt),
                        optionalText(redacted.lastErrorRedacted),
                        .text(redacted.manualRecoveryHintRedacted),
                        .text(redacted.metadataJSONRedacted)
                    ]
                )
            }
        }
    }

    public func load(groupID: String) throws -> [OperationGroupStepRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, group_id, step_key, direction, planned_action_type, service_name,
                       resource_identifier, step_idempotency_key, status, started_at, updated_at,
                       finished_at, last_error_redacted, manual_recovery_hint_redacted,
                       metadata_json_redacted
                FROM operation_group_steps
                WHERE group_id = ?
                ORDER BY updated_at ASC, rowid ASC
                """,
                bindings: [.text(groupID)]
            )
            return try rows.map(operationGroupStepRecord(from:))
        }
    }

    public func loadAll() throws -> [OperationGroupStepRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, group_id, step_key, direction, planned_action_type, service_name,
                       resource_identifier, step_idempotency_key, status, started_at, updated_at,
                       finished_at, last_error_redacted, manual_recovery_hint_redacted,
                       metadata_json_redacted
                FROM operation_group_steps
                ORDER BY updated_at ASC, rowid ASC
                """
            )
            return try rows.map(operationGroupStepRecord(from:))
        }
    }

    public func latest(groupID: String, stepKey: String) throws -> OperationGroupStepRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, group_id, step_key, direction, planned_action_type, service_name,
                       resource_identifier, step_idempotency_key, status, started_at, updated_at,
                       finished_at, last_error_redacted, manual_recovery_hint_redacted,
                       metadata_json_redacted
                FROM operation_group_steps
                WHERE group_id = ? AND step_key = ?
                ORDER BY updated_at DESC, rowid DESC
                LIMIT 1
                """,
                bindings: [.text(groupID), .text(stepKey)]
            )
            return try rows.first.map(operationGroupStepRecord(from:))
        }
    }
}
