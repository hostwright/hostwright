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

public enum OperationGroupLeaseRecoveryResult: Equatable, Sendable {
    case reclaimed(OperationGroupRecord)
    case activeUnexpired(OperationGroupRecord)
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
                    "SELECT status, lock_owner, lock_expires_at FROM operation_groups WHERE id = ? LIMIT 1",
                    bindings: [.text(groupID)]
                )
                guard let currentStatus = rows.first?.first ?? nil else {
                    throw StateStoreError.notFound("Operation group '\(groupID)' does not exist.")
                }
                guard currentStatus == OperationGroupStatus.active.rawValue else {
                    throw StateStoreError.invalidRecord("Operation group '\(groupID)' is already terminal with status '\(currentStatus)'.")
                }
                try rebindOwnershipLeases(
                    groupID: groupID,
                    expectedOwner: rows[0][1],
                    expectedExpiry: rows[0][2],
                    newOwner: nil,
                    newExpiry: nil,
                    updatedAt: updatedAt,
                    on: connection
                )
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

    public func finishExactLease(
        groupID: String,
        expectedFencingToken: String,
        expectedLockOwner: String,
        expectedLockExpiresAt: String,
        status: OperationGroupStatus,
        checkpoint: String,
        manualRecoveryHintRedacted: String,
        updatedAt: String,
        metadataJSONRedacted: String
    ) throws {
        guard status != .active,
              HostwrightResourceUUID.isValid(expectedFencingToken),
              !expectedLockOwner.isEmpty,
              !expectedLockExpiresAt.isEmpty,
              !checkpoint.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              StateJSON.isObject(metadataJSONRedacted) else {
            throw StateStoreError.invalidRecord(
                "Exact operation-group finish requires a terminal state, fence, finite lease, checkpoint, and metadata object."
            )
        }
        let owner = RuntimeRedactionPolicy.default.redact(
            expectedLockOwner
        )
        let hint = RuntimeRedactionPolicy.default.redact(
            manualRecoveryHintRedacted
        )
        let metadata = try StateJSON.redactedJSON(metadataJSONRedacted)
        try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT status, fencing_token, lock_owner, lock_expires_at
                    FROM operation_groups
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(groupID)]
                )
                guard rows.count == 1,
                      rows[0][0] == OperationGroupStatus.active.rawValue,
                      rows[0][1] == expectedFencingToken.lowercased(),
                      rows[0][2] == owner,
                      rows[0][3] == expectedLockExpiresAt else {
                    throw StateStoreError.invalidRecord(
                        "Operation-group finish lost the exact fenced lease owner or expiry."
                    )
                }
                try rebindOwnershipLeases(
                    groupID: groupID,
                    expectedOwner: owner,
                    expectedExpiry: expectedLockExpiresAt,
                    newOwner: nil,
                    newExpiry: nil,
                    updatedAt: updatedAt,
                    on: connection
                )
                try connection.run(
                    """
                    UPDATE operation_groups
                    SET status = ?, checkpoint = ?, lock_owner = NULL,
                        lock_expires_at = NULL,
                        manual_recovery_hint_redacted = ?, updated_at = ?,
                        metadata_json_redacted = ?
                    WHERE id = ? AND status = 'active'
                      AND fencing_token = ? AND lock_owner = ?
                      AND lock_expires_at = ?
                    """,
                    bindings: [
                        .text(status.rawValue),
                        .text(checkpoint),
                        .text(hint),
                        .text(updatedAt),
                        .text(metadata),
                        .text(groupID),
                        .text(expectedFencingToken.lowercased()),
                        .text(owner),
                        .text(expectedLockExpiresAt)
                    ]
                )
                let updated = try connection.query(
                    """
                    SELECT status, lock_owner, lock_expires_at
                    FROM operation_groups
                    WHERE id = ? AND fencing_token = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(groupID),
                        .text(expectedFencingToken.lowercased())
                    ]
                )
                guard updated.count == 1,
                      updated[0][0] == status.rawValue,
                      updated[0][1] == nil,
                      updated[0][2] == nil else {
                    throw StateStoreError.invalidRecord(
                        "Exact operation-group finish lost its terminal compare-and-swap."
                    )
                }
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

    public func recordCheckpointRenewingLease(
        groupID: String,
        expectedFencingToken: String,
        expectedLockOwner: String,
        checkpoint: String,
        verificationJSONRedacted: String,
        lockExpiresAt: String,
        updatedAt: String
    ) throws {
        guard HostwrightResourceUUID.isValid(expectedFencingToken),
              !expectedLockOwner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !checkpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              StateJSON.isObject(verificationJSONRedacted),
              lockExpiresAt > updatedAt else {
            throw StateStoreError.invalidRecord(
                "Operation group checkpoint lease renewal requires an exact owner, fence, checkpoint, verification object, and future expiry."
            )
        }
        let owner = RuntimeRedactionPolicy.default.redact(expectedLockOwner)
        let verification = try StateJSON.redactedJSON(verificationJSONRedacted)
        try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT status, fencing_token, lock_owner, lock_expires_at
                    FROM operation_groups
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(groupID)]
                )
                guard rows.count == 1,
                      rows[0][0] == OperationGroupStatus.active.rawValue,
                      rows[0][1] == expectedFencingToken.lowercased(),
                      rows[0][2] == owner,
                      let existingExpiry = rows[0][3],
                      existingExpiry > updatedAt else {
                    throw StateStoreError.invalidRecord(
                        "Operation group checkpoint lease was expired, missing, or no longer owned by the exact fenced executor."
                    )
                }
                try connection.run(
                    """
                    UPDATE operation_groups
                    SET checkpoint = ?, verification_json_redacted = ?,
                        lock_expires_at = ?, updated_at = ?
                    WHERE id = ? AND status = 'active' AND fencing_token = ?
                      AND lock_owner = ? AND lock_expires_at = ?
                    """,
                    bindings: [
                        .text(checkpoint),
                        .text(verification),
                        .text(lockExpiresAt),
                        .text(updatedAt),
                        .text(groupID),
                        .text(expectedFencingToken.lowercased()),
                        .text(owner),
                        .text(existingExpiry)
                    ]
                )
                try rebindOwnershipLeases(
                    groupID: groupID,
                    expectedOwner: owner,
                    expectedExpiry: existingExpiry,
                    newOwner: owner,
                    newExpiry: lockExpiresAt,
                    updatedAt: updatedAt,
                    on: connection
                )
                let updated = try connection.query(
                    """
                    SELECT checkpoint, lock_expires_at
                    FROM operation_groups
                    WHERE id = ? AND status = 'active' AND fencing_token = ?
                      AND lock_owner = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(groupID),
                        .text(expectedFencingToken.lowercased()),
                        .text(owner)
                    ]
                )
                guard updated.count == 1,
                      updated[0][0] == checkpoint,
                      updated[0][1] == lockExpiresAt else {
                    throw StateStoreError.invalidRecord(
                        "Operation group checkpoint lease renewal lost its exact fenced owner."
                    )
                }
            }
        }
    }

    public func reclaimExpiredActive(
        groupID: String,
        expectedPlanHash: String,
        expectedFencingToken: String,
        lockOwner: String,
        lockExpiresAt: String,
        currentTimestamp: String
    ) throws -> OperationGroupLeaseRecoveryResult {
        guard !groupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !expectedPlanHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              HostwrightResourceUUID.isValid(expectedFencingToken),
              !lockOwner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              lockExpiresAt > currentTimestamp else {
            throw StateStoreError.invalidRecord(
                "Expired operation recovery requires the exact group, plan, fence, owner, and a future replacement lease."
            )
        }
        let owner = RuntimeRedactionPolicy.default.redact(lockOwner)
        if let current = try load(id: groupID),
           current.status == .active,
           current.planHash == expectedPlanHash,
           current.fencingToken == expectedFencingToken.lowercased(),
           let currentExpiry = current.lockExpiresAt,
           currentExpiry > currentTimestamp,
           try !isHandedOffControllerClaim(
               group: current,
               claimant: owner
           ) {
            return .activeUnexpired(current)
        }
        let mutationFence = try store.acquireOperationMutationFence(
            groupID: groupID
        )
        defer { mutationFence.release() }
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT id, operation_id, group_kind, project_id, service_name,
                           planned_action_type, status, group_idempotency_key, plan_hash,
                           checkpoint, lock_owner, lock_expires_at, rollback_available,
                           manual_recovery_hint_redacted, created_at, updated_at,
                           metadata_json_redacted, fencing_token, intent_json_redacted,
                           compensation_json_redacted, verification_json_redacted
                    FROM operation_groups
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(groupID)]
                )
                guard let existing = try rows.first.map(operationGroupRecord(from:)),
                      existing.status == .active,
                      existing.planHash == expectedPlanHash,
                      existing.fencingToken == expectedFencingToken.lowercased() else {
                    throw StateStoreError.invalidRecord(
                        "Only the exact active operation group, plan, and fence can be reclaimed."
                    )
                }
                guard let existingExpiry = existing.lockExpiresAt else {
                    throw StateStoreError.invalidRecord(
                        "Legacy active operation groups without a finite lease cannot be reclaimed automatically."
                    )
                }
                guard existingExpiry <= currentTimestamp else {
                    if try isHandedOffControllerClaim(
                        group: existing,
                        claimant: owner
                    ) {
                        try connection.run(
                            """
                            UPDATE operation_groups
                            SET lock_owner = ?, lock_expires_at = ?,
                                updated_at = ?
                            WHERE id = ? AND status = 'active'
                              AND plan_hash = ? AND fencing_token = ?
                              AND lock_owner = ? AND lock_expires_at = ?
                            """,
                            bindings: [
                                .text(owner),
                                .text(lockExpiresAt),
                                .text(currentTimestamp),
                                .text(groupID),
                                .text(expectedPlanHash),
                                .text(expectedFencingToken.lowercased()),
                                .text(existing.lockOwner ?? ""),
                                .text(existingExpiry)
                            ]
                        )
                        try rebindOwnershipLeases(
                            groupID: groupID,
                            expectedOwner: existing.lockOwner,
                            expectedExpiry: existingExpiry,
                            newOwner: owner,
                            newExpiry: lockExpiresAt,
                            updatedAt: currentTimestamp,
                            on: connection
                        )
                        guard let claimed = try load(
                            id: groupID,
                            on: connection
                        ), claimed.lockOwner == owner,
                           claimed.lockExpiresAt == lockExpiresAt else {
                            throw StateStoreError.invalidRecord(
                                "Handed-off operation lease claim lost its single-winner compare-and-swap."
                            )
                        }
                        return .reclaimed(claimed)
                    }
                    return .activeUnexpired(existing)
                }
                try connection.run(
                    """
                    UPDATE operation_groups
                    SET lock_owner = ?, lock_expires_at = ?, updated_at = ?
                    WHERE id = ? AND status = 'active' AND plan_hash = ?
                      AND fencing_token = ? AND lock_expires_at = ?
                    """,
                    bindings: [
                        .text(owner),
                        .text(lockExpiresAt),
                        .text(currentTimestamp),
                        .text(groupID),
                        .text(expectedPlanHash),
                        .text(expectedFencingToken.lowercased()),
                        .text(existingExpiry)
                    ]
                )
                try rebindOwnershipLeases(
                    groupID: groupID,
                    expectedOwner: existing.lockOwner,
                    expectedExpiry: existingExpiry,
                    newOwner: owner,
                    newExpiry: lockExpiresAt,
                    updatedAt: currentTimestamp,
                    on: connection
                )
                let loaded = try connection.query(
                    """
                    SELECT id, operation_id, group_kind, project_id, service_name,
                           planned_action_type, status, group_idempotency_key, plan_hash,
                           checkpoint, lock_owner, lock_expires_at, rollback_available,
                           manual_recovery_hint_redacted, created_at, updated_at,
                           metadata_json_redacted, fencing_token, intent_json_redacted,
                           compensation_json_redacted, verification_json_redacted
                    FROM operation_groups
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(groupID)]
                )
                guard let reclaimed = try loaded.first.map(operationGroupRecord(from:)),
                      reclaimed.status == .active,
                      reclaimed.planHash == expectedPlanHash,
                      reclaimed.fencingToken == expectedFencingToken.lowercased(),
                      reclaimed.lockOwner == owner,
                      reclaimed.lockExpiresAt == lockExpiresAt else {
                    throw StateStoreError.invalidRecord(
                        "Expired operation recovery lost the exact fenced lease race."
                    )
                }
                return .reclaimed(reclaimed)
            }
        }
    }

    public func handoffExpiredActive(
        groupID: String,
        expectedPlanHash: String,
        expectedFencingToken: String,
        expectedLockOwner: String,
        expectedLockExpiresAt: String,
        newLockOwner: String,
        newLockExpiresAt: String,
        currentTimestamp: String
    ) throws -> OperationGroupRecord {
        let allowedTargets = Set([
            "hostwright-recovery-resume",
            "hostwright-recovery-rollback"
        ])
        guard HostwrightResourceUUID.isValid(groupID),
              expectedPlanHash.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil,
              HostwrightResourceUUID.isValid(expectedFencingToken),
              !expectedLockOwner.isEmpty,
              expectedLockOwner.utf8.count <= 128,
              allowedTargets.contains(newLockOwner),
              expectedLockOwner != newLockOwner,
              expectedLockExpiresAt <= currentTimestamp,
              newLockExpiresAt > currentTimestamp else {
            throw StateStoreError.invalidRecord(
                "Operation handoff requires an expired exact group, plan, fence, prior lease, and a bounded recovery controller lease."
            )
        }
        let mutationFence = try store.acquireOperationMutationFence(
            groupID: groupID
        )
        defer { mutationFence.release() }
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                guard let current = try load(id: groupID, on: connection),
                      current.status == .active,
                      current.planHash == expectedPlanHash,
                      current.fencingToken ==
                        expectedFencingToken.lowercased(),
                      current.lockOwner == expectedLockOwner,
                      current.lockExpiresAt == expectedLockExpiresAt else {
                    throw StateStoreError.invalidRecord(
                        "Operation handoff lost the exact active owner, expiry, plan, or fence."
                    )
                }
                guard current.groupKind == "lifecycle-v1" else {
                    throw StateStoreError.invalidRecord(
                        "Operation handoff is unavailable for a mutation kind without a compatible local recovery claimant."
                    )
                }
                let ownershipRows = try connection.query(
                    """
                    SELECT id, resource_identifier, resource_type, project_id,
                           service_name, runtime_adapter, created_at, observed_at,
                           cleanup_eligible, metadata_json_redacted,
                           identity_version, resource_uuid, resource_generation,
                           project_resource_uuid, project_generation,
                           provider_generation, fencing_token
                    FROM ownership_records
                    ORDER BY resource_identifier ASC, runtime_adapter ASC
                    """
                )
                var ownershipMetadataUpdates: [(
                    id: String,
                    priorMetadata: String,
                    nextMetadata: String,
                    fencingToken: String
                )] = []
                for row in ownershipRows {
                    let ownership = try ownershipRecord(from: row)
                    guard let authority = try OwnershipAuthorityMetadata.decode(
                        from: ownership.metadataJSONRedacted
                    ), authority.operationGroupID == groupID else {
                        continue
                    }
                    try authority.validate(for: ownership)
                    guard authority.leaseOwner != nil else { continue }
                    guard authority.leaseOwner == expectedLockOwner else {
                        throw StateStoreError.invalidRecord(
                            "Operation handoff found ownership bound to a different lease controller."
                        )
                    }
                    let rebound = OwnershipAuthorityRecord(
                        controllerID: authority.controllerID,
                        providerID: authority.providerID,
                        ownershipProofSHA256:
                            authority.ownershipProofSHA256,
                        resourceUUID: authority.resourceUUID,
                        resourceGeneration: authority.resourceGeneration,
                        projectResourceUUID:
                            authority.projectResourceUUID,
                        projectGeneration: authority.projectGeneration,
                        providerGeneration: authority.providerGeneration,
                        fencingToken: authority.fencingToken,
                        finalizers: authority.finalizers,
                        deletionTimestamp: authority.deletionTimestamp,
                        operationGroupID: authority.operationGroupID,
                        leaseOwner: newLockOwner,
                        leaseExpiresAt: newLockExpiresAt,
                        handoffGeneration:
                            authority.handoffGeneration + 1
                    )
                    try rebound.validate(for: ownership)
                    ownershipMetadataUpdates.append((
                        id: ownership.id,
                        priorMetadata: ownership.metadataJSONRedacted,
                        nextMetadata: try OwnershipAuthorityMetadata.encode(
                            rebound,
                            into: ownership.metadataJSONRedacted
                        ),
                        fencingToken: ownership.fencingToken
                    ))
                }
                let metadata = try handoffMetadata(
                    current.metadataJSONRedacted,
                    from: expectedLockOwner,
                    to: newLockOwner,
                    at: currentTimestamp
                )
                try connection.run(
                    """
                    UPDATE operation_groups
                    SET lock_owner = ?, lock_expires_at = ?,
                        updated_at = ?, metadata_json_redacted = ?
                    WHERE id = ? AND status = 'active'
                      AND plan_hash = ? AND fencing_token = ?
                      AND lock_owner = ? AND lock_expires_at = ?
                    """,
                    bindings: [
                        .text(newLockOwner),
                        .text(newLockExpiresAt),
                        .text(currentTimestamp),
                        .text(metadata),
                        .text(groupID.lowercased()),
                        .text(expectedPlanHash),
                        .text(expectedFencingToken.lowercased()),
                        .text(expectedLockOwner),
                        .text(expectedLockExpiresAt)
                    ]
                )
                for update in ownershipMetadataUpdates {
                    try connection.run(
                        """
                        UPDATE ownership_records
                        SET metadata_json_redacted = ?
                        WHERE id = ? AND fencing_token = ?
                          AND metadata_json_redacted = ?
                        """,
                        bindings: [
                            .text(update.nextMetadata),
                            .text(update.id),
                            .text(update.fencingToken),
                            .text(update.priorMetadata)
                        ]
                    )
                    let reboundRows = try connection.query(
                        """
                        SELECT metadata_json_redacted
                        FROM ownership_records
                        WHERE id = ? AND fencing_token = ?
                        LIMIT 1
                        """,
                        bindings: [
                            .text(update.id),
                            .text(update.fencingToken)
                        ]
                    )
                    guard reboundRows.first?.first ==
                            update.nextMetadata else {
                        throw StateStoreError.invalidRecord(
                            "Operation handoff lost an exact ownership authority compare-and-swap."
                        )
                    }
                }
                guard let handedOff = try load(
                    id: groupID.lowercased(),
                    on: connection
                ),
                handedOff.lockOwner == newLockOwner,
                handedOff.lockExpiresAt == newLockExpiresAt,
                handedOff.metadataJSONRedacted == metadata else {
                    throw StateStoreError.invalidRecord(
                        "Operation handoff lost its single-winner compare-and-swap."
                    )
                }
                return handedOff
            }
        }
    }

    private func handoffMetadata(
        _ metadataJSON: String,
        from priorController: String,
        to controller: String,
        at timestamp: String
    ) throws -> String {
        guard let data = metadataJSON.data(using: .utf8),
              var object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw StateStoreError.invalidRecord(
                "Operation handoff metadata must be a JSON object."
            )
        }
        let previous = object["localLeaseAuthority"]
            as? [String: Any]
        let generation = (previous?["handoffGeneration"] as? Int ?? 0) + 1
        object["localLeaseAuthority"] = [
            "schemaVersion": 1,
            "controllerID": controller,
            "priorControllerID": priorController,
            "handoffGeneration": generation,
            "handoffTimestamp": timestamp
        ]
        let encoded = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard encoded.count <= 1_048_576,
              let result = String(data: encoded, encoding: .utf8) else {
            throw StateStoreError.invalidRecord(
                "Operation handoff metadata exceeds its bounded JSON contract."
            )
        }
        return try StateJSON.redactedJSON(result)
    }

    private func isHandedOffControllerClaim(
        group: OperationGroupRecord,
        claimant: String
    ) throws -> Bool {
        guard let controller = group.lockOwner,
              [
                  "hostwright-recovery-resume",
                  "hostwright-recovery-rollback"
              ].contains(controller),
              claimant.hasPrefix(controller + ":"),
              HostwrightResourceUUID.isValid(
                  String(claimant.dropFirst(controller.count + 1))
              ),
              let data = group.metadataJSONRedacted.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let authority = object["localLeaseAuthority"]
                as? [String: Any],
              authority["schemaVersion"] as? Int == 1,
              authority["controllerID"] as? String == controller else {
            return false
        }
        return true
    }

    public func resumeInterrupted(
        groupID: String,
        expectedFencingToken: String,
        lockOwner: String,
        lockExpiresAt: String?,
        updatedAt: String
    ) throws -> OperationGroupRecord {
        guard HostwrightResourceUUID.isValid(expectedFencingToken),
              !lockOwner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StateStoreError.invalidRecord(
                "Operation group resume requires a valid fence and lock owner."
            )
        }
        let redactedOwner = RuntimeRedactionPolicy.default.redact(lockOwner)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT status, fencing_token, project_id, group_idempotency_key
                    FROM operation_groups
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(groupID)]
                )
                guard rows.count == 1,
                      rows[0][0] == OperationGroupStatus.interrupted.rawValue,
                      rows[0][1] == expectedFencingToken.lowercased(),
                      let groupIdempotencyKey = rows[0][3] else {
                    throw StateStoreError.invalidRecord(
                        "Only the exact fenced interrupted operation group can be resumed."
                    )
                }
                let idempotencyConflicts = try connection.query(
                    """
                    SELECT id
                    FROM operation_groups
                    WHERE group_idempotency_key = ? AND status = 'active' AND id != ?
                    LIMIT 1
                    """,
                    bindings: [.text(groupIdempotencyKey), .text(groupID)]
                )
                guard idempotencyConflicts.isEmpty else {
                    throw StateStoreError.invalidRecord(
                        "Another operation with the same idempotency key is active."
                    )
                }
                if let projectID = rows[0][2] {
                    let conflicts = try connection.query(
                        """
                        SELECT id
                        FROM operation_groups
                        WHERE project_id = ? AND status = 'active' AND id != ?
                        LIMIT 1
                        """,
                        bindings: [.text(projectID), .text(groupID)]
                    )
                    guard conflicts.isEmpty else {
                        throw StateStoreError.invalidRecord(
                            "Another mutating operation is active for this project."
                        )
                    }
                }
                try connection.run(
                    """
                    UPDATE operation_groups
                    SET status = 'active', lock_owner = ?, lock_expires_at = ?, updated_at = ?
                    WHERE id = ? AND status = 'interrupted' AND fencing_token = ?
                    """,
                    bindings: [
                        .text(redactedOwner),
                        optionalText(lockExpiresAt),
                        .text(updatedAt),
                        .text(groupID),
                        .text(expectedFencingToken.lowercased())
                    ]
                )
                try rebindOwnershipLeases(
                    groupID: groupID,
                    expectedOwner: nil,
                    expectedExpiry: nil,
                    newOwner: redactedOwner,
                    newExpiry: lockExpiresAt,
                    updatedAt: updatedAt,
                    on: connection
                )
                let loaded = try connection.query(
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
                    bindings: [.text(groupID)]
                )
                guard let record = try loaded.first.map(operationGroupRecord(from:)) else {
                    throw StateStoreError.notFound("Operation group '\(groupID)' does not exist.")
                }
                return record
            }
        }
    }

    public func resumeFailedSafeHold(
        groupID: String,
        expectedPlanHash: String,
        expectedFencingToken: String,
        lockOwner: String,
        lockExpiresAt: String?,
        updatedAt: String
    ) throws -> OperationGroupRecord {
        guard expectedPlanHash.range(
            of: "^[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil,
        HostwrightResourceUUID.isValid(expectedFencingToken),
        !lockOwner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StateStoreError.invalidRecord(
                "Safe-hold resume requires an exact plan, fence, and lock owner."
            )
        }
        let redactedOwner = RuntimeRedactionPolicy.default.redact(lockOwner)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT status, fencing_token, project_id, group_idempotency_key,
                           plan_hash, checkpoint, metadata_json_redacted
                    FROM operation_groups
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(groupID)]
                )
                guard rows.count == 1,
                      rows[0][0] == OperationGroupStatus.failed.rawValue,
                      rows[0][1] == expectedFencingToken.lowercased(),
                      rows[0][4] == expectedPlanHash,
                      rows[0][5] != "compensated",
                      let groupIdempotencyKey = rows[0][3],
                      let metadata = rows[0][6]?.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: metadata)
                        as? [String: Any],
                      object["result"] as? String == "safe-hold",
                      object["planSHA256"] as? String == expectedPlanHash else {
                    throw StateStoreError.invalidRecord(
                        "Only the exact fenced failed safe-hold can be resumed."
                    )
                }
                let idempotencyConflicts = try connection.query(
                    """
                    SELECT id
                    FROM operation_groups
                    WHERE group_idempotency_key = ? AND status = 'active' AND id != ?
                    LIMIT 1
                    """,
                    bindings: [.text(groupIdempotencyKey), .text(groupID)]
                )
                guard idempotencyConflicts.isEmpty else {
                    throw StateStoreError.invalidRecord(
                        "Another operation with the same idempotency key is active."
                    )
                }
                if let projectID = rows[0][2] {
                    let conflicts = try connection.query(
                        """
                        SELECT id
                        FROM operation_groups
                        WHERE project_id = ? AND status = 'active' AND id != ?
                        LIMIT 1
                        """,
                        bindings: [.text(projectID), .text(groupID)]
                    )
                    guard conflicts.isEmpty else {
                        throw StateStoreError.invalidRecord(
                            "Another mutating operation is active for this project."
                        )
                    }
                }
                try connection.run(
                    """
                    UPDATE operation_groups
                    SET status = 'active', lock_owner = ?, lock_expires_at = ?, updated_at = ?
                    WHERE id = ? AND status = 'failed' AND plan_hash = ?
                      AND fencing_token = ?
                    """,
                    bindings: [
                        .text(redactedOwner),
                        optionalText(lockExpiresAt),
                        .text(updatedAt),
                        .text(groupID),
                        .text(expectedPlanHash),
                        .text(expectedFencingToken.lowercased())
                    ]
                )
                try rebindOwnershipLeases(
                    groupID: groupID,
                    expectedOwner: nil,
                    expectedExpiry: nil,
                    newOwner: redactedOwner,
                    newExpiry: lockExpiresAt,
                    updatedAt: updatedAt,
                    on: connection
                )
                let loaded = try connection.query(
                    """
                    SELECT id, operation_id, group_kind, project_id, service_name,
                           planned_action_type, status, group_idempotency_key, plan_hash,
                           checkpoint, lock_owner, lock_expires_at, rollback_available,
                           manual_recovery_hint_redacted, created_at, updated_at,
                           metadata_json_redacted, fencing_token, intent_json_redacted,
                           compensation_json_redacted, verification_json_redacted
                    FROM operation_groups
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(groupID)]
                )
                guard let record = try loaded.first.map(operationGroupRecord(from:)),
                      record.status == .active else {
                    throw StateStoreError.invalidRecord(
                        "Failed safe-hold resume lost the exact fenced transition."
                    )
                }
                return record
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

    private func load(
        id: String,
        on connection: SQLiteConnection
    ) throws -> OperationGroupRecord? {
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

    private func rebindOwnershipLeases(
        groupID: String,
        expectedOwner: String?,
        expectedExpiry: String?,
        newOwner: String?,
        newExpiry: String?,
        updatedAt: String,
        on connection: SQLiteConnection
    ) throws {
        guard (newOwner == nil) == (newExpiry == nil) else {
            throw StateStoreError.invalidRecord(
                "Ownership lease transition requires paired replacement owner and expiry values."
            )
        }
        let rows = try connection.query(
            """
            SELECT id, resource_identifier, resource_type, project_id,
                   service_name, runtime_adapter, created_at, observed_at,
                   cleanup_eligible, metadata_json_redacted,
                   identity_version, resource_uuid, resource_generation,
                   project_resource_uuid, project_generation,
                   provider_generation, fencing_token
            FROM ownership_records
            ORDER BY resource_identifier ASC, runtime_adapter ASC
            """
        )
        for row in rows {
            let ownership = try ownershipRecord(from: row)
            guard let authority = try OwnershipAuthorityMetadata.decode(
                from: ownership.metadataJSONRedacted
            ), authority.operationGroupID == groupID else {
                continue
            }
            try authority.validate(for: ownership)
            if authority.leaseOwner == nil, expectedOwner != nil {
                continue
            }
            guard authority.leaseOwner == expectedOwner,
                  authority.leaseExpiresAt == expectedExpiry else {
                throw StateStoreError.invalidRecord(
                    "Ownership authority lost the exact operation-group lease transition."
                )
            }
            let rebound = OwnershipAuthorityRecord(
                controllerID: authority.controllerID,
                providerID: authority.providerID,
                ownershipProofSHA256: authority.ownershipProofSHA256,
                resourceUUID: authority.resourceUUID,
                resourceGeneration: authority.resourceGeneration,
                projectResourceUUID: authority.projectResourceUUID,
                projectGeneration: authority.projectGeneration,
                providerGeneration: authority.providerGeneration,
                fencingToken: authority.fencingToken,
                finalizers: authority.finalizers,
                deletionTimestamp: authority.deletionTimestamp,
                operationGroupID: authority.operationGroupID,
                leaseOwner: newOwner,
                leaseExpiresAt: newExpiry,
                handoffGeneration: authority.handoffGeneration +
                    ((newOwner != nil && newOwner != expectedOwner) ? 1 : 0)
            )
            try rebound.validate(for: ownership)
            let metadata = try OwnershipAuthorityMetadata.encode(
                rebound,
                into: ownership.metadataJSONRedacted
            )
            try connection.run(
                """
                UPDATE ownership_records
                SET metadata_json_redacted = ?, observed_at = ?
                WHERE id = ? AND fencing_token = ?
                  AND metadata_json_redacted = ?
                """,
                bindings: [
                    .text(metadata),
                    .text(updatedAt),
                    .text(ownership.id),
                    .text(ownership.fencingToken),
                    .text(ownership.metadataJSONRedacted)
                ]
            )
            let updated = try connection.query(
                """
                SELECT metadata_json_redacted
                FROM ownership_records
                WHERE id = ? AND fencing_token = ?
                LIMIT 1
                """,
                bindings: [
                    .text(ownership.id),
                    .text(ownership.fencingToken)
                ]
            )
            guard updated.first?.first == metadata else {
                throw StateStoreError.invalidRecord(
                    "Ownership lease transition lost its exact metadata compare-and-swap."
                )
            }
        }
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
        try rebindOwnershipLeases(
            groupID: group.id,
            expectedOwner: group.lockOwner,
            expectedExpiry: group.lockExpiresAt,
            newOwner: nil,
            newExpiry: nil,
            updatedAt: currentTimestamp,
            on: connection
        )
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
        try appendValidated(
            step,
            expectedFencingToken: nil,
            expectedLockOwner: nil
        )
    }

    public func append(
        _ step: OperationGroupStepRecord,
        expectedFencingToken: String
    ) throws {
        guard HostwrightResourceUUID.isValid(expectedFencingToken) else {
            throw StateStoreError.invalidRecord(
                "Operation group step append requires a valid fencing token."
            )
        }
        try appendValidated(
            step,
            expectedFencingToken: expectedFencingToken.lowercased(),
            expectedLockOwner: nil
        )
    }

    public func append(
        _ step: OperationGroupStepRecord,
        expectedFencingToken: String,
        expectedLockOwner: String
    ) throws {
        guard HostwrightResourceUUID.isValid(expectedFencingToken),
              !expectedLockOwner.isEmpty,
              expectedLockOwner.utf8.count <= 128 else {
            throw StateStoreError.invalidRecord(
                "Operation group step append requires a valid fence and exact lease owner."
            )
        }
        try appendValidated(
            step,
            expectedFencingToken: expectedFencingToken.lowercased(),
            expectedLockOwner:
                RuntimeRedactionPolicy.default.redact(expectedLockOwner)
        )
    }

    private func appendValidated(
        _ step: OperationGroupStepRecord,
        expectedFencingToken: String?,
        expectedLockOwner: String?
    ) throws {
        guard StateJSON.isObject(step.metadataJSONRedacted) else {
            throw StateStoreError.invalidRecord("Operation group step metadata must be a JSON object.")
        }
        let redacted = step.redacted()
        try store.withValidatedConnection { connection in
            try connection.transaction {
                if let expectedFencingToken {
                    let groups = try connection.query(
                        """
                        SELECT status, fencing_token, lock_owner,
                               lock_expires_at
                        FROM operation_groups
                        WHERE id = ?
                        LIMIT 1
                        """,
                        bindings: [.text(redacted.groupID)]
                    )
                    guard groups.count == 1,
                          groups[0][0] == OperationGroupStatus.active.rawValue,
                          groups[0][1] == expectedFencingToken,
                          expectedLockOwner.map({ groups[0][2] == $0 }) ?? true,
                          expectedLockOwner == nil || groups[0][3] != nil else {
                        throw StateStoreError.invalidRecord(
                            "Operation group step fence was lost or the group is no longer active."
                        )
                    }
                }
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
