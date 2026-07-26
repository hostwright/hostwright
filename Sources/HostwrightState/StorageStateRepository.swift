import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightStorage

public struct StorageStateRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    @discardableResult
    public func saveVolume(
        _ record: StorageStateVolumeRecord,
        replacing expected: StorageStateExpectedVersion? = nil
    ) throws -> StorageStateVolumeRecord {
        try Self.validate(record)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.validateOperationGroup(
                    id: record.operationGroupID,
                    fencingToken: record.fencingToken,
                    on: connection
                )
                if let existing = try Self.loadVolume(
                    id: record.id,
                    on: connection
                ) {
                    if existing == record { return record }
                    try Self.validateReplacement(
                        existingGeneration: existing.generation,
                        existingFence: existing.fencingToken,
                        existingCreatedAt: existing.createdAt,
                        incomingGeneration: record.generation,
                        incomingCreatedAt: record.createdAt,
                        expected: expected,
                        label: "volume"
                    )
                    try connection.run(
                        """
                        UPDATE storage_volumes
                        SET name = ?, provider_id = ?,
                            provider_volume_id = ?,
                            topology_node_id = ?, generation = ?,
                            fencing_token = ?, capacity_bytes = ?,
                            lifecycle_state = ?, reclaim_policy = ?,
                            access_mode = ?, source_kind = ?,
                            source_id = ?, operation_group_id = ?,
                            updated_at = ?
                        WHERE id = ? AND generation = ?
                          AND fencing_token = ?
                        """,
                        bindings: [
                            .text(record.name), .text(record.providerID),
                            .text(record.providerVolumeID),
                            .text(record.topologyNodeID),
                            .int(Int(record.generation)),
                            .text(record.fencingToken),
                            .int64(record.capacityBytes),
                            .text(record.lifecycleState.rawValue),
                            .text(record.reclaimPolicy.rawValue),
                            .text(record.accessMode.rawValue),
                            optionalText(record.sourceKind?.rawValue),
                            optionalText(record.sourceID),
                            .text(record.operationGroupID),
                            .text(record.updatedAt), .text(record.id),
                            .int(Int(expected!.generation)),
                            .text(expected!.fencingToken)
                        ]
                    )
                } else {
                    try Self.validateCreation(
                        generation: record.generation,
                        expected: expected,
                        label: "volume"
                    )
                    try connection.run(
                        """
                        INSERT INTO storage_volumes (
                            id, project_id, name, provider_id,
                            provider_volume_id,
                            topology_node_id, generation, fencing_token,
                            capacity_bytes, lifecycle_state,
                            reclaim_policy, access_mode, source_kind,
                            source_id, operation_group_id,
                            created_at, updated_at
                        ) VALUES (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                        )
                        """,
                        bindings: [
                            .text(record.id), .text(record.projectID),
                            .text(record.name),
                            .text(record.providerID),
                            .text(record.providerVolumeID),
                            .text(record.topologyNodeID),
                            .int(Int(record.generation)),
                            .text(record.fencingToken),
                            .int64(record.capacityBytes),
                            .text(record.lifecycleState.rawValue),
                            .text(record.reclaimPolicy.rawValue),
                            .text(record.accessMode.rawValue),
                            optionalText(record.sourceKind?.rawValue),
                            optionalText(record.sourceID),
                            .text(record.operationGroupID),
                            .text(record.createdAt),
                            .text(record.updatedAt)
                        ]
                    )
                }
                return record
            }
        }
    }

    public func loadVolume(id: String) throws -> StorageStateVolumeRecord? {
        try Self.validateUUID(id, label: "volume id")
        return try store.withValidatedConnection(readOnly: true) {
            try Self.loadVolume(id: id, on: $0)
        }
    }

    public func loadVolumes(
        projectID: String? = nil,
        topologyNodeID: String? = nil
    ) throws -> [StorageStateVolumeRecord] {
        if let projectID {
            try Self.validateIdentifier(
                projectID,
                maximumBytes: 256,
                label: "volume project id"
            )
        }
        if let topologyNodeID {
            try Self.validateIdentifier(
                topologyNodeID,
                maximumBytes: 128,
                label: "topology node id"
            )
        }
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            var sql = Self.volumeSelect
            var bindings: [SQLiteValue] = []
            var predicates: [String] = []
            if let projectID {
                predicates.append("project_id = ?")
                bindings.append(.text(projectID))
            }
            if let topologyNodeID {
                predicates.append("topology_node_id = ?")
                bindings.append(.text(topologyNodeID))
            }
            if !predicates.isEmpty {
                sql += " WHERE " + predicates.joined(separator: " AND ")
            }
            sql += " ORDER BY name, id"
            return try connection.query(
                sql,
                bindings: bindings
            ).map(Self.volume(from:))
        }
    }

    @discardableResult
    public func saveAttachment(
        _ record: StorageStateAttachmentRecord,
        replacing expected: StorageStateExpectedVersion? = nil
    ) throws -> StorageStateAttachmentRecord {
        try Self.validate(record)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.validateOperationGroup(
                    id: record.operationGroupID,
                    fencingToken: record.fencingToken,
                    on: connection
                )
                guard let volume = try Self.loadVolume(
                    id: record.volumeID,
                    on: connection
                ),
                volume.lifecycleState != .deleted else {
                    throw StateStoreError.notFound(
                        "Storage attachment volume is unavailable."
                    )
                }
                guard volume.accessMode == record.accessMode else {
                    throw StateStoreError.invalidRecord(
                        "Storage attachment access mode must match its volume authority."
                    )
                }
                try Self.validateAttachmentConflicts(
                    record,
                    on: connection
                )
                if let existing = try Self.loadAttachment(
                    id: record.id,
                    on: connection
                ) {
                    if existing == record { return record }
                    try Self.validateAttachmentReplacement(
                        existing: existing,
                        incoming: record,
                        expected: expected,
                        on: connection
                    )
                    try connection.run(
                        """
                        UPDATE storage_attachments
                        SET volume_id = ?, node_id = ?, node_uuid = ?,
                            workload_uuid = ?, attachment_kind = ?,
                            path = ?, staging_path = ?,
                            access_mode = ?, read_only = ?,
                            generation = ?, fencing_token = ?,
                            lifecycle_state = ?, checkpoint = ?,
                            lease_renewed_at = ?,
                            lease_expires_at = ?, operation_id = ?,
                            idempotency_key = ?,
                            provider_observation_sha256 = ?,
                            force_detach_authorization_sha256 = ?,
                            ambiguous_hold_reason_redacted = ?,
                            operation_group_id = ?, updated_at = ?
                        WHERE id = ? AND generation = ?
                          AND fencing_token = ?
                        """,
                        bindings: [
                            .text(record.volumeID), .text(record.nodeID),
                            .text(record.nodeUUID),
                            .text(record.workloadUUID),
                            .text(record.kind.rawValue),
                            .text(record.path),
                            optionalText(record.stagingPath),
                            .text(record.accessMode.rawValue),
                            .bool(record.readOnly),
                            .int(Int(record.generation)),
                            .text(record.fencingToken),
                            .text(record.lifecycleState.rawValue),
                            .text(record.checkpoint.rawValue),
                            .text(record.leaseRenewedAt),
                            .text(record.leaseExpiresAt),
                            .text(record.operationID),
                            .text(record.idempotencyKey),
                            optionalText(
                                record.providerObservationSHA256
                            ),
                            optionalText(
                                record
                                    .forceDetachAuthorizationSHA256
                            ),
                            optionalText(
                                record
                                    .ambiguousHoldReasonRedacted
                            ),
                            .text(record.operationGroupID),
                            .text(record.updatedAt), .text(record.id),
                            .int(Int(expected!.generation)),
                            .text(expected!.fencingToken)
                        ]
                    )
                } else {
                    try Self.validateCreation(
                        generation: record.generation,
                        expected: expected,
                        label: "attachment"
                    )
                    guard record.checkpoint ==
                            .attachIntentPersisted,
                          record.lifecycleState == .attaching,
                          record.providerObservationSHA256 == nil,
                          record.forceDetachAuthorizationSHA256 == nil,
                          record.ambiguousHoldReasonRedacted == nil else {
                        throw StateStoreError.invalidRecord(
                            "New storage attachment state must begin with durable attach intent."
                        )
                    }
                    try connection.run(
                        """
                        INSERT INTO storage_attachments (
                            id, volume_id, node_id, node_uuid,
                            workload_uuid, attachment_kind, path,
                            staging_path, access_mode, read_only,
                            generation, fencing_token, lifecycle_state,
                            checkpoint, lease_renewed_at,
                            lease_expires_at, operation_id,
                            idempotency_key,
                            provider_observation_sha256,
                            force_detach_authorization_sha256,
                            ambiguous_hold_reason_redacted,
                            operation_group_id, created_at, updated_at
                        ) VALUES (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                        )
                        """,
                        bindings: [
                            .text(record.id), .text(record.volumeID),
                            .text(record.nodeID),
                            .text(record.nodeUUID),
                            .text(record.workloadUUID),
                            .text(record.kind.rawValue),
                            .text(record.path),
                            optionalText(record.stagingPath),
                            .text(record.accessMode.rawValue),
                            .bool(record.readOnly),
                            .int(Int(record.generation)),
                            .text(record.fencingToken),
                            .text(record.lifecycleState.rawValue),
                            .text(record.checkpoint.rawValue),
                            .text(record.leaseRenewedAt),
                            .text(record.leaseExpiresAt),
                            .text(record.operationID),
                            .text(record.idempotencyKey),
                            optionalText(
                                record.providerObservationSHA256
                            ),
                            optionalText(
                                record
                                    .forceDetachAuthorizationSHA256
                            ),
                            optionalText(
                                record
                                    .ambiguousHoldReasonRedacted
                            ),
                            .text(record.operationGroupID),
                            .text(record.createdAt),
                            .text(record.updatedAt)
                        ]
                    )
                }
                return record
            }
        }
    }

    public func loadAttachments(
        volumeID: String
    ) throws -> [StorageStateAttachmentRecord] {
        try Self.validateUUID(volumeID, label: "attachment volume id")
        return try store.withValidatedConnection(readOnly: true) {
            try $0.query(
                Self.attachmentSelect + """
                 WHERE volume_id = ?
                 ORDER BY node_id, attachment_kind, path, id
                """,
                bindings: [.text(volumeID)]
            ).map(Self.attachment(from:))
        }
    }

    public func loadAttachment(
        id: String
    ) throws -> StorageStateAttachmentRecord? {
        try Self.validateUUID(id, label: "attachment id")
        return try store.withValidatedConnection(readOnly: true) {
            try Self.loadAttachment(id: id, on: $0)
        }
    }

    public func loadStaleAttachments(
        at timestamp: String
    ) throws -> [StorageStateAttachmentRecord] {
        try Self.validateTimestamp(
            timestamp,
            label: "stale attachment query timestamp"
        )
        return try store.withValidatedConnection(readOnly: true) {
            try $0.query(
                Self.attachmentSelect + """
                 WHERE lifecycle_state != 'detached'
                   AND julianday(lease_expires_at)
                     <= julianday(?)
                 ORDER BY julianday(lease_expires_at), volume_id, id
                """,
                bindings: [.text(timestamp)]
            ).map(Self.attachment(from:))
        }
    }

    @discardableResult
    public func removeDetachedAttachment(
        id: String,
        expected: StorageStateExpectedVersion
    ) throws -> Bool {
        try Self.validateUUID(id, label: "attachment id")
        try Self.validateVersion(
            generation: expected.generation,
            fencingToken: expected.fencingToken,
            label: "attachment cleanup authority"
        )
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                guard let record = try Self.loadAttachment(
                    id: id,
                    on: connection
                ) else {
                    return false
                }
                guard record.generation == expected.generation,
                      record.fencingToken ==
                        expected.fencingToken,
                      record.lifecycleState == .detached,
                      record.checkpoint == .detachedCommitted else {
                    throw StateStoreError.invalidRecord(
                        "Storage attachment cleanup requires exact detached authority."
                    )
                }
                try connection.run(
                    """
                    DELETE FROM storage_attachments
                    WHERE id = ? AND generation = ?
                      AND fencing_token = ?
                      AND lifecycle_state = 'detached'
                      AND checkpoint = 'detached-committed'
                    """,
                    bindings: [
                        .text(id),
                        .int(Int(expected.generation)),
                        .text(expected.fencingToken),
                    ]
                )
                return true
            }
        }
    }

    @discardableResult
    public func saveSnapshot(
        _ record: StorageStateSnapshotRecord,
        replacing expected: StorageStateExpectedVersion? = nil
    ) throws -> StorageStateSnapshotRecord {
        try Self.validate(record)
        let lineageJSON = try Self.encodeLineage(record.lineage)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.validateOperationGroup(
                    id: record.operationGroupID,
                    fencingToken: record.fencingToken,
                    on: connection
                )
                guard try Self.loadVolume(
                    id: record.sourceVolumeID,
                    on: connection
                ) != nil else {
                    throw StateStoreError.notFound(
                        "Storage snapshot source volume is unavailable."
                    )
                }
                if let existing = try Self.loadSnapshot(
                    id: record.id,
                    on: connection
                ) {
                    if existing == record { return record }
                    try Self.validateReplacement(
                        existingGeneration: existing.generation,
                        existingFence: existing.fencingToken,
                        existingCreatedAt: existing.createdAt,
                        incomingGeneration: record.generation,
                        incomingCreatedAt: record.createdAt,
                        expected: expected,
                        label: "snapshot"
                    )
                    try connection.run(
                        """
                        UPDATE storage_snapshots
                        SET name = ?, source_volume_id = ?,
                            provider_id = ?, provider_snapshot_id = ?,
                            consistency_class = ?,
                            parent_content_tree_sha256 = ?,
                            content_tree_sha256 = ?,
                            lineage_json = ?, generation = ?,
                            fencing_token = ?, size_bytes = ?,
                            lifecycle_state = ?,
                            operation_group_id = ?, updated_at = ?
                        WHERE id = ? AND generation = ?
                          AND fencing_token = ?
                        """,
                        bindings: [
                            .text(record.name),
                            .text(record.sourceVolumeID),
                            .text(record.providerID),
                            .text(record.providerSnapshotID),
                            .text(record.consistencyClass.rawValue),
                            .text(record.parentContentTreeSHA256),
                            .text(record.contentTreeSHA256),
                            .text(lineageJSON),
                            .int(Int(record.generation)),
                            .text(record.fencingToken),
                            .int64(record.sizeBytes),
                            .text(record.lifecycleState.rawValue),
                            .text(record.operationGroupID),
                            .text(record.updatedAt), .text(record.id),
                            .int(Int(expected!.generation)),
                            .text(expected!.fencingToken)
                        ]
                    )
                } else {
                    try Self.validateCreation(
                        generation: record.generation,
                        expected: expected,
                        label: "snapshot"
                    )
                    try connection.run(
                        """
                        INSERT INTO storage_snapshots (
                            id, name, source_volume_id, provider_id,
                            provider_snapshot_id, consistency_class,
                            parent_content_tree_sha256,
                            content_tree_sha256, lineage_json,
                            generation, fencing_token, size_bytes,
                            lifecycle_state, operation_group_id,
                            created_at, updated_at
                        ) VALUES (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?
                        )
                        """,
                        bindings: [
                            .text(record.id), .text(record.name),
                            .text(record.sourceVolumeID),
                            .text(record.providerID),
                            .text(record.providerSnapshotID),
                            .text(record.consistencyClass.rawValue),
                            .text(record.parentContentTreeSHA256),
                            .text(record.contentTreeSHA256),
                            .text(lineageJSON),
                            .int(Int(record.generation)),
                            .text(record.fencingToken),
                            .int64(record.sizeBytes),
                            .text(record.lifecycleState.rawValue),
                            .text(record.operationGroupID),
                            .text(record.createdAt),
                            .text(record.updatedAt)
                        ]
                    )
                }
                return record
            }
        }
    }

    public func loadSnapshots(
        sourceVolumeID: String
    ) throws -> [StorageStateSnapshotRecord] {
        try Self.validateUUID(
            sourceVolumeID,
            label: "snapshot source volume id"
        )
        return try store.withValidatedConnection(readOnly: true) {
            try $0.query(
                Self.snapshotSelect + """
                 WHERE source_volume_id = ?
                 ORDER BY created_at, id
                """,
                bindings: [.text(sourceVolumeID)]
            ).map(Self.snapshot(from:))
        }
    }

    @discardableResult
    public func saveBackup(
        _ record: StorageStateBackupRecord,
        replacing expected: StorageStateExpectedVersion? = nil
    ) throws -> StorageStateBackupRecord {
        try Self.validate(record)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.validateOperationGroup(
                    id: record.operationGroupID,
                    fencingToken: record.fencingToken,
                    on: connection
                )
                guard try Self.loadVolume(
                    id: record.volumeID,
                    on: connection
                ) != nil else {
                    throw StateStoreError.notFound(
                        "Storage backup volume is unavailable."
                    )
                }
                if let snapshotID = record.snapshotID,
                   try Self.loadSnapshot(
                       id: snapshotID,
                       on: connection
                   ) == nil {
                    throw StateStoreError.notFound(
                        "Storage backup snapshot is unavailable."
                    )
                }
                if let existing = try Self.loadBackup(
                    id: record.id,
                    on: connection
                ) {
                    if existing == record { return record }
                    try Self.validateReplacement(
                        existingGeneration: existing.generation,
                        existingFence: existing.fencingToken,
                        existingCreatedAt: existing.createdAt,
                        incomingGeneration: record.generation,
                        incomingCreatedAt: record.createdAt,
                        expected: expected,
                        label: "backup"
                    )
                    try connection.run(
                        """
                        UPDATE storage_backups
                        SET volume_id = ?, snapshot_id = ?,
                            destination_redacted = ?,
                            content_sha256 = ?, size_bytes = ?,
                            generation = ?, fencing_token = ?,
                            lifecycle_state = ?,
                            operation_group_id = ?, updated_at = ?
                        WHERE id = ? AND generation = ?
                          AND fencing_token = ?
                        """,
                        bindings: [
                            .text(record.volumeID),
                            optionalText(record.snapshotID),
                            .text(record.destinationRedacted),
                            .text(record.contentSHA256),
                            .int64(record.sizeBytes),
                            .int(Int(record.generation)),
                            .text(record.fencingToken),
                            .text(record.lifecycleState.rawValue),
                            .text(record.operationGroupID),
                            .text(record.updatedAt), .text(record.id),
                            .int(Int(expected!.generation)),
                            .text(expected!.fencingToken)
                        ]
                    )
                } else {
                    try Self.validateCreation(
                        generation: record.generation,
                        expected: expected,
                        label: "backup"
                    )
                    try connection.run(
                        """
                        INSERT INTO storage_backups (
                            id, volume_id, snapshot_id,
                            destination_redacted, content_sha256,
                            size_bytes, generation, fencing_token,
                            lifecycle_state, operation_group_id,
                            created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(record.id), .text(record.volumeID),
                            optionalText(record.snapshotID),
                            .text(record.destinationRedacted),
                            .text(record.contentSHA256),
                            .int64(record.sizeBytes),
                            .int(Int(record.generation)),
                            .text(record.fencingToken),
                            .text(record.lifecycleState.rawValue),
                            .text(record.operationGroupID),
                            .text(record.createdAt),
                            .text(record.updatedAt)
                        ]
                    )
                }
                return record
            }
        }
    }

    public func loadBackups(
        volumeID: String
    ) throws -> [StorageStateBackupRecord] {
        try Self.validateUUID(volumeID, label: "backup volume id")
        return try store.withValidatedConnection(readOnly: true) {
            try $0.query(
                Self.backupSelect + """
                 WHERE volume_id = ?
                 ORDER BY created_at, id
                """,
                bindings: [.text(volumeID)]
            ).map(Self.backup(from:))
        }
    }

    public func loadBackup(
        id: String
    ) throws -> StorageStateBackupRecord? {
        try Self.validateUUID(id, label: "backup id")
        return try store.withValidatedConnection(readOnly: true) {
            try Self.loadBackup(id: id, on: $0)
        }
    }

    @discardableResult
    public func saveHold(
        _ record: StorageStateHoldRecord,
        replacing expected: StorageStateExpectedVersion? = nil
    ) throws -> StorageStateHoldRecord {
        try Self.validate(record)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.validateOperationGroup(
                    id: record.operationGroupID,
                    fencingToken: record.fencingToken,
                    on: connection
                )
                try Self.validateHoldTarget(record, on: connection)
                if let existing = try Self.loadHold(
                    id: record.id,
                    on: connection
                ) {
                    if existing == record { return record }
                    try Self.validateReplacement(
                        existingGeneration: existing.generation,
                        existingFence: existing.fencingToken,
                        existingCreatedAt: existing.createdAt,
                        incomingGeneration: record.generation,
                        incomingCreatedAt: record.createdAt,
                        expected: expected,
                        label: "hold"
                    )
                    try connection.run(
                        """
                        UPDATE storage_holds
                        SET resource_kind = ?, resource_id = ?,
                            reason_redacted = ?, generation = ?,
                            fencing_token = ?, operation_group_id = ?,
                            expires_at = ?, released_at = ?
                        WHERE id = ? AND generation = ?
                          AND fencing_token = ?
                        """,
                        bindings: [
                            .text(record.resourceKind.rawValue),
                            .text(record.resourceID),
                            .text(record.reasonRedacted),
                            .int(Int(record.generation)),
                            .text(record.fencingToken),
                            .text(record.operationGroupID),
                            optionalText(record.expiresAt),
                            optionalText(record.releasedAt),
                            .text(record.id),
                            .int(Int(expected!.generation)),
                            .text(expected!.fencingToken)
                        ]
                    )
                } else {
                    try Self.validateCreation(
                        generation: record.generation,
                        expected: expected,
                        label: "hold"
                    )
                    try connection.run(
                        """
                        INSERT INTO storage_holds (
                            id, resource_kind, resource_id,
                            reason_redacted, generation, fencing_token,
                            operation_group_id, created_at,
                            expires_at, released_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(record.id),
                            .text(record.resourceKind.rawValue),
                            .text(record.resourceID),
                            .text(record.reasonRedacted),
                            .int(Int(record.generation)),
                            .text(record.fencingToken),
                            .text(record.operationGroupID),
                            .text(record.createdAt),
                            optionalText(record.expiresAt),
                            optionalText(record.releasedAt)
                        ]
                    )
                }
                return record
            }
        }
    }

    public func activeHolds(
        resourceKind: StorageHoldResourceKind,
        resourceID: String,
        at timestamp: String
    ) throws -> [StorageStateHoldRecord] {
        try Self.validateUUID(resourceID, label: "held resource id")
        try Self.validateTimestamp(timestamp, label: "hold query timestamp")
        return try store.withValidatedConnection(readOnly: true) {
            try $0.query(
                Self.holdSelect + """
                 WHERE resource_kind = ? AND resource_id = ?
                   AND released_at IS NULL
                   AND (expires_at IS NULL OR expires_at > ?)
                 ORDER BY created_at, id
                """,
                bindings: [
                    .text(resourceKind.rawValue),
                    .text(resourceID),
                    .text(timestamp)
                ]
            ).map(Self.hold(from:))
        }
    }

    @discardableResult
    public func saveOrphan(
        _ record: StorageStateOrphanRecord,
        replacing expected: StorageStateExpectedVersion? = nil
    ) throws -> StorageStateOrphanRecord {
        try Self.validate(record)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.validateOperationGroup(
                    id: record.operationGroupID,
                    fencingToken: record.fencingToken,
                    on: connection
                )
                if let existing = try Self.loadOrphan(
                    id: record.id,
                    on: connection
                ) {
                    if existing == record { return record }
                    try Self.validateReplacement(
                        existingGeneration: existing.generation,
                        existingFence: existing.fencingToken,
                        existingCreatedAt: existing.discoveredAt,
                        incomingGeneration: record.generation,
                        incomingCreatedAt: record.discoveredAt,
                        expected: expected,
                        label: "orphan"
                    )
                    try connection.run(
                        """
                        UPDATE storage_orphans
                        SET provider_id = ?, resource_kind = ?,
                            provider_resource_id_hash = ?,
                            ownership_proof_sha256 = ?,
                            generation = ?, fencing_token = ?,
                            lifecycle_state = ?,
                            operation_group_id = ?, resolved_at = ?
                        WHERE id = ? AND generation = ?
                          AND fencing_token = ?
                        """,
                        bindings: [
                            .text(record.providerID),
                            .text(record.resourceKind.rawValue),
                            .text(record.providerResourceIDHash),
                            optionalText(record.ownershipProofSHA256),
                            .int(Int(record.generation)),
                            .text(record.fencingToken),
                            .text(record.lifecycleState.rawValue),
                            .text(record.operationGroupID),
                            optionalText(record.resolvedAt),
                            .text(record.id),
                            .int(Int(expected!.generation)),
                            .text(expected!.fencingToken)
                        ]
                    )
                } else {
                    try Self.validateCreation(
                        generation: record.generation,
                        expected: expected,
                        label: "orphan"
                    )
                    try connection.run(
                        """
                        INSERT INTO storage_orphans (
                            id, provider_id, resource_kind,
                            provider_resource_id_hash,
                            ownership_proof_sha256, generation,
                            fencing_token, lifecycle_state,
                            operation_group_id, discovered_at,
                            resolved_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(record.id),
                            .text(record.providerID),
                            .text(record.resourceKind.rawValue),
                            .text(record.providerResourceIDHash),
                            optionalText(record.ownershipProofSHA256),
                            .int(Int(record.generation)),
                            .text(record.fencingToken),
                            .text(record.lifecycleState.rawValue),
                            .text(record.operationGroupID),
                            .text(record.discoveredAt),
                            optionalText(record.resolvedAt)
                        ]
                    )
                }
                return record
            }
        }
    }

    public func loadOrphans(
        providerID: String
    ) throws -> [StorageStateOrphanRecord] {
        try Self.validateIdentifier(
            providerID,
            maximumBytes: 256,
            label: "orphan provider id"
        )
        return try store.withValidatedConnection(readOnly: true) {
            try $0.query(
                Self.orphanSelect + """
                 WHERE provider_id = ?
                 ORDER BY discovered_at, resource_kind,
                          provider_resource_id_hash, id
                """,
                bindings: [.text(providerID)]
            ).map(Self.orphan(from:))
        }
    }

    @discardableResult
    public func saveCapacitySample(
        _ record: StorageStateCapacitySampleRecord
    ) throws -> StorageStateCapacitySampleRecord {
        try Self.validate(record)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.validateOperationGroup(
                    id: record.operationGroupID,
                    fencingToken: record.fencingToken,
                    on: connection
                )
                if let existing = try Self.loadCapacitySample(
                    id: record.sample.id,
                    on: connection
                ) {
                    guard existing == record else {
                        throw StateStoreError.invalidRecord(
                            "Capacity sample identity cannot be reused with different accounting."
                        )
                    }
                    return record
                }
                let sample = record.sample
                try connection.run(
                    """
                    INSERT INTO storage_capacity_samples (
                        id, provider_id, topology_node_id, source,
                        requested_bytes, reserved_bytes, used_bytes,
                        reclaimable_bytes, available_bytes,
                        total_bytes, requested_inodes,
                        reserved_inodes, used_inodes,
                        reclaimable_inodes, available_inodes,
                        total_inodes, quota_enforcement_mode,
                        quota_evidence_sha256, pressure_level,
                        sample_digest_sha256, captured_at_ms,
                        valid_until_ms, fencing_token,
                        operation_group_id, created_at
                    ) VALUES (
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                    )
                    """,
                    bindings: [
                        .text(sample.id),
                        .text(sample.providerID),
                        .text(sample.topologyNodeID),
                        .text(sample.source.rawValue),
                        .int64(sample.requestedBytes),
                        .int64(sample.reservedBytes),
                        .int64(sample.usedBytes),
                        .int64(sample.reclaimableBytes),
                        .int64(sample.availableBytes),
                        .int64(sample.totalBytes),
                        .int64(sample.requestedInodes),
                        .int64(sample.reservedInodes),
                        .int64(sample.usedInodes),
                        .int64(sample.reclaimableInodes),
                        .int64(sample.availableInodes),
                        .int64(sample.totalInodes),
                        .text(sample.quotaCapability.mode.rawValue),
                        optionalText(
                            sample.quotaCapability.evidenceSHA256
                        ),
                        .text(record.pressureLevel.rawValue),
                        .text(sample.digestSHA256),
                        .int64(sample.capturedAtUnixMilliseconds),
                        .int64(sample.validUntilUnixMilliseconds),
                        .text(record.fencingToken),
                        .text(record.operationGroupID),
                        .text(record.createdAt),
                    ]
                )
                return record
            }
        }
    }

    public func loadCapacitySample(
        id: String
    ) throws -> StorageStateCapacitySampleRecord? {
        try Self.validateUUID(id, label: "capacity sample id")
        return try store.withValidatedConnection(readOnly: true) {
            try Self.loadCapacitySample(id: id, on: $0)
        }
    }

    public func latestCapacitySample(
        providerID: String,
        topologyNodeID: String
    ) throws -> StorageStateCapacitySampleRecord? {
        try Self.validateIdentifier(
            providerID,
            maximumBytes: 256,
            label: "capacity provider id"
        )
        try Self.validateIdentifier(
            topologyNodeID,
            maximumBytes: 128,
            label: "capacity topology node id"
        )
        return try store.withValidatedConnection(readOnly: true) {
            try $0.query(
                Self.capacitySampleSelect + """
                 WHERE provider_id = ? AND topology_node_id = ?
                 ORDER BY captured_at_ms DESC, id DESC
                 LIMIT 1
                """,
                bindings: [
                    .text(providerID),
                    .text(topologyNodeID),
                ]
            ).first.map(Self.capacitySample(from:))
        }
    }

    @discardableResult
    public func saveQuota(
        _ record: StorageStateQuotaRecord,
        replacing expected: StorageStateExpectedVersion? = nil
    ) throws -> StorageStateQuotaRecord {
        try Self.validate(record)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.validateOperationGroup(
                    id: record.operationGroupID,
                    fencingToken: record.fencingToken,
                    on: connection
                )
                if let existing = try Self.loadQuota(
                    id: record.id,
                    on: connection
                ) {
                    if existing == record { return record }
                    try Self.validateReplacement(
                        existingGeneration: existing.generation,
                        existingFence: existing.fencingToken,
                        existingCreatedAt: existing.createdAt,
                        incomingGeneration: record.generation,
                        incomingCreatedAt: record.createdAt,
                        expected: expected,
                        label: "quota"
                    )
                    try connection.run(
                        """
                        UPDATE storage_quotas
                        SET resource_id = ?, provider_id = ?,
                            byte_limit = ?, inode_limit = ?,
                            enforcement_mode = ?,
                            enforcement_evidence_sha256 = ?,
                            generation = ?, fencing_token = ?,
                            lifecycle_state = ?, retry_attempt = ?,
                            recovery_checkpoint = ?,
                            operation_id = ?, idempotency_key = ?,
                            operation_group_id = ?, updated_at = ?
                        WHERE id = ? AND generation = ?
                          AND fencing_token = ?
                        """,
                        bindings: [
                            .text(record.resourceID),
                            .text(record.providerID),
                            optionalInt64(record.byteLimit),
                            optionalInt64(record.inodeLimit),
                            .text(record.enforcementMode.rawValue),
                            optionalText(
                                record
                                    .enforcementEvidenceSHA256
                            ),
                            .int64(record.generation),
                            .text(record.fencingToken),
                            .text(record.lifecycleState.rawValue),
                            .int(record.retryAttempt),
                            .text(
                                record.recoveryCheckpoint.rawValue
                            ),
                            .text(record.operationID),
                            .text(record.idempotencyKey),
                            .text(record.operationGroupID),
                            .text(record.updatedAt),
                            .text(record.id),
                            .int64(expected!.generation),
                            .text(expected!.fencingToken),
                        ]
                    )
                } else {
                    try Self.validateCreation(
                        generation: record.generation,
                        expected: expected,
                        label: "quota"
                    )
                    try connection.run(
                        """
                        INSERT INTO storage_quotas (
                            id, resource_id, provider_id, byte_limit,
                            inode_limit, enforcement_mode,
                            enforcement_evidence_sha256, generation,
                            fencing_token, lifecycle_state,
                            retry_attempt, recovery_checkpoint,
                            operation_id, idempotency_key,
                            operation_group_id, created_at, updated_at
                        ) VALUES (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?
                        )
                        """,
                        bindings: [
                            .text(record.id),
                            .text(record.resourceID),
                            .text(record.providerID),
                            optionalInt64(record.byteLimit),
                            optionalInt64(record.inodeLimit),
                            .text(record.enforcementMode.rawValue),
                            optionalText(
                                record
                                    .enforcementEvidenceSHA256
                            ),
                            .int64(record.generation),
                            .text(record.fencingToken),
                            .text(record.lifecycleState.rawValue),
                            .int(record.retryAttempt),
                            .text(
                                record.recoveryCheckpoint.rawValue
                            ),
                            .text(record.operationID),
                            .text(record.idempotencyKey),
                            .text(record.operationGroupID),
                            .text(record.createdAt),
                            .text(record.updatedAt),
                        ]
                    )
                }
                return record
            }
        }
    }

    public func loadQuota(
        id: String
    ) throws -> StorageStateQuotaRecord? {
        try Self.validateUUID(id, label: "quota id")
        return try store.withValidatedConnection(readOnly: true) {
            try Self.loadQuota(id: id, on: $0)
        }
    }

    @discardableResult
    public func saveCapacityAdmission(
        _ record: StorageStateCapacityAdmissionRecord
    ) throws -> StorageStateCapacityAdmissionRecord {
        try Self.validate(record)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.validateOperationGroup(
                    id: record.operationGroupID,
                    fencingToken: record.fencingToken,
                    on: connection
                )
                guard let sample = try Self.loadCapacitySample(
                    id: record.sampleID,
                    on: connection
                ),
                sample.sample.digestSHA256 ==
                    record.sampleDigestSHA256 else {
                    throw StateStoreError.invalidRecord(
                        "Capacity admission requires the exact persisted sample digest."
                    )
                }
                if let existing = try Self.loadCapacityAdmission(
                    id: record.id,
                    on: connection
                ) {
                    guard existing == record else {
                        throw StateStoreError.invalidRecord(
                            "Capacity admission identity cannot be reused with different evidence."
                        )
                    }
                    return record
                }
                let prior = try connection.query(
                    Self.capacityAdmissionSelect + """
                     WHERE operation_id = ? AND attempt = ?
                     LIMIT 1
                    """,
                    bindings: [
                        .text(record.result.operationID),
                        .int(record.result.attempt),
                    ]
                ).first.map(Self.capacityAdmission(from:))
                guard prior == nil else {
                    if prior == record { return record }
                    throw StateStoreError.invalidRecord(
                        "Capacity admission attempt already contains different evidence."
                    )
                }
                if record.result.attempt > 1 {
                    let previous = try connection.query(
                        Self.capacityAdmissionSelect + """
                         WHERE operation_id = ? AND attempt = ?
                         LIMIT 1
                        """,
                        bindings: [
                            .text(record.result.operationID),
                            .int(record.result.attempt - 1),
                        ]
                    ).first.map(Self.capacityAdmission(from:))
                    guard let previous,
                          previous.result.idempotencyKey ==
                            record.result.idempotencyKey,
                          previous.maximumAttempts ==
                            record.maximumAttempts,
                          previous.result.retryDisposition !=
                            .never else {
                        throw StateStoreError.invalidRecord(
                            "Capacity admission retry requires the exact retryable previous attempt."
                        )
                    }
                }
                let result = record.result
                try connection.run(
                    """
                    INSERT INTO storage_capacity_admissions (
                        id, sample_id, sample_digest_sha256, action,
                        additional_bytes, additional_inodes,
                        writable, operation_id, idempotency_key,
                        disposition, reason, pressure_level,
                        retry_disposition, recovery_checkpoint,
                        attempt, maximum_attempts,
                        effective_available_bytes,
                        effective_available_inodes, fencing_token,
                        operation_group_id, created_at
                    ) VALUES (
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?, ?
                    )
                    """,
                    bindings: [
                        .text(record.id),
                        .text(record.sampleID),
                        .text(record.sampleDigestSHA256),
                        .text(record.action.rawValue),
                        .int64(record.additionalBytes),
                        .int64(record.additionalInodes),
                        .bool(record.writable),
                        .text(result.operationID),
                        .text(result.idempotencyKey),
                        .text(result.disposition.rawValue),
                        .text(result.reason.rawValue),
                        .text(result.pressure.rawValue),
                        .text(result.retryDisposition.rawValue),
                        .text(result.checkpoint.rawValue),
                        .int(result.attempt),
                        .int(record.maximumAttempts),
                        .int64(result.effectiveAvailableBytes),
                        .int64(result.effectiveAvailableInodes),
                        .text(record.fencingToken),
                        .text(record.operationGroupID),
                        .text(record.createdAt),
                    ]
                )
                return record
            }
        }
    }

    public func loadCapacityAdmissions(
        operationID: String
    ) throws -> [StorageStateCapacityAdmissionRecord] {
        try Self.validateUUID(
            operationID,
            label: "capacity admission operation id"
        )
        return try store.withValidatedConnection(readOnly: true) {
            try $0.query(
                Self.capacityAdmissionSelect + """
                 WHERE operation_id = ?
                 ORDER BY attempt, id
                """,
                bindings: [.text(operationID)]
            ).map(Self.capacityAdmission(from:))
        }
    }

    public func latestCapacityAdmission(
        operationID: String
    ) throws -> StorageStateCapacityAdmissionRecord? {
        try Self.validateUUID(
            operationID,
            label: "capacity admission operation id"
        )
        return try store.withValidatedConnection(readOnly: true) {
            try $0.query(
                Self.capacityAdmissionSelect + """
                 WHERE operation_id = ?
                 ORDER BY attempt DESC, id DESC
                 LIMIT 1
                """,
                bindings: [.text(operationID)]
            ).first.map(Self.capacityAdmission(from:))
        }
    }

    public func allocatedCapacityBytes(
        topologyNodeID: String
    ) throws -> Int64 {
        try Self.validateIdentifier(
            topologyNodeID,
            maximumBytes: 128,
            label: "capacity topology node id"
        )
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            let value = try connection.query(
                """
                SELECT COALESCE(SUM(capacity_bytes), 0)
                FROM storage_volumes
                WHERE topology_node_id = ?
                  AND lifecycle_state != 'deleted'
                """,
                bindings: [.text(topologyNodeID)]
            ).first?.first ?? nil
            guard let value, let capacity = Int64(value), capacity >= 0 else {
                throw StateStoreError.invalidRecord(
                    "Storage allocated capacity could not be decoded."
                )
            }
            return capacity
        }
    }

    static func invalidStoredRecordCount(
        on connection: SQLiteConnection
    ) throws -> Int {
        let queries = [
            """
            SELECT COUNT(*) FROM storage_volumes
            WHERE project_id = '' OR generation < 1
               OR capacity_bytes < 1
               OR created_at = '' OR updated_at = ''
               OR NOT EXISTS (
                    SELECT 1 FROM operation_groups
                    WHERE operation_groups.id =
                        storage_volumes.operation_group_id
                      AND operation_groups.fencing_token =
                        storage_volumes.fencing_token
               )
            """,
            """
            SELECT COUNT(*) FROM storage_attachments
            WHERE generation < 1
               OR julianday(lease_renewed_at) IS NULL
               OR julianday(lease_expires_at) IS NULL
               OR julianday(lease_expires_at)
                    <= julianday(lease_renewed_at)
               OR (
                    julianday(lease_expires_at)
                      - julianday(lease_renewed_at)
                  ) * 86400.0 > 900.001
               OR julianday(updated_at)
                    < julianday(lease_renewed_at)
               OR (
                    lifecycle_state = 'ambiguous-hold'
                    AND ambiguous_hold_reason_redacted IS NULL
               )
               OR (
                    lifecycle_state != 'ambiguous-hold'
                    AND ambiguous_hold_reason_redacted IS NOT NULL
               )
               OR NOT (
                    lifecycle_state = 'ambiguous-hold'
                    OR (
                        checkpoint IN (
                            'attach-intent-persisted',
                            'attach-fence-acquired',
                            'attach-provider-effect-requested',
                            'attach-provider-observed'
                        )
                        AND lifecycle_state IN (
                            'attaching', 'faulted'
                        )
                    )
                    OR (
                        checkpoint = 'attached-committed'
                        AND lifecycle_state IN (
                            'attached', 'faulted'
                        )
                    )
                    OR (
                        checkpoint IN (
                            'detach-intent-persisted',
                            'detach-fence-acquired',
                            'detach-provider-effect-requested',
                            'detach-provider-absent-observed'
                        )
                        AND lifecycle_state IN (
                            'detaching', 'faulted'
                        )
                    )
                    OR (
                        checkpoint = 'detached-committed'
                        AND lifecycle_state = 'detached'
                    )
               )
               OR (
                    checkpoint IN (
                        'attach-provider-observed',
                        'attached-committed',
                        'detach-provider-absent-observed',
                        'detached-committed'
                    )
                    AND provider_observation_sha256 IS NULL
               )
               OR (
                    force_detach_authorization_sha256 IS NOT NULL
                    AND checkpoint LIKE 'attach-%'
               )
               OR EXISTS (
                    SELECT 1 FROM storage_attachments AS conflict
                    WHERE conflict.id != storage_attachments.id
                      AND conflict.volume_id =
                        storage_attachments.volume_id
                      AND conflict.lifecycle_state != 'detached'
                      AND storage_attachments.lifecycle_state
                        != 'detached'
                      AND (
                        conflict.read_only = 0
                        OR storage_attachments.read_only = 0
                      )
               )
               OR EXISTS (
                    SELECT 1 FROM storage_attachments AS conflict
                    WHERE conflict.id != storage_attachments.id
                      AND conflict.volume_id =
                        storage_attachments.volume_id
                      AND conflict.node_uuid =
                        storage_attachments.node_uuid
                      AND conflict.workload_uuid =
                        storage_attachments.workload_uuid
                      AND conflict.lifecycle_state != 'detached'
                      AND storage_attachments.lifecycle_state
                        != 'detached'
               )
               OR NOT EXISTS (
                    SELECT 1 FROM storage_volumes
                    WHERE storage_volumes.id =
                        storage_attachments.volume_id
                      AND storage_volumes.access_mode =
                        storage_attachments.access_mode
               )
               OR NOT EXISTS (
                    SELECT 1 FROM operation_groups
                    WHERE operation_groups.id =
                        storage_attachments.operation_group_id
                      AND operation_groups.fencing_token =
                        storage_attachments.fencing_token
               )
            """,
            """
            SELECT COUNT(*) FROM storage_snapshots
            WHERE generation < 1 OR size_bytes < 0
               OR NOT EXISTS (
                    SELECT 1 FROM storage_volumes
                    WHERE storage_volumes.id =
                        storage_snapshots.source_volume_id
               )
               OR NOT EXISTS (
                    SELECT 1 FROM operation_groups
                    WHERE operation_groups.id =
                        storage_snapshots.operation_group_id
                      AND operation_groups.fencing_token =
                        storage_snapshots.fencing_token
               )
            """,
            """
            SELECT COUNT(*) FROM storage_backups
            WHERE generation < 1 OR size_bytes < 0
               OR NOT EXISTS (
                    SELECT 1 FROM storage_volumes
                    WHERE storage_volumes.id =
                        storage_backups.volume_id
               )
               OR (
                    snapshot_id IS NOT NULL
                    AND NOT EXISTS (
                        SELECT 1 FROM storage_snapshots
                        WHERE storage_snapshots.id =
                            storage_backups.snapshot_id
                    )
               )
               OR NOT EXISTS (
                    SELECT 1 FROM operation_groups
                    WHERE operation_groups.id =
                        storage_backups.operation_group_id
                      AND operation_groups.fencing_token =
                        storage_backups.fencing_token
               )
            """,
            """
            SELECT COUNT(*) FROM storage_holds
            WHERE generation < 1
               OR NOT EXISTS (
                    SELECT 1 FROM operation_groups
                    WHERE operation_groups.id =
                        storage_holds.operation_group_id
                      AND operation_groups.fencing_token =
                        storage_holds.fencing_token
               )
            """,
            """
            SELECT COUNT(*) FROM storage_orphans
            WHERE generation < 1
               OR (
                    lifecycle_state = 'reclaimed'
                    AND ownership_proof_sha256 IS NULL
               )
               OR (
                    lifecycle_state IN ('discovered', 'held')
                    AND resolved_at IS NOT NULL
               )
               OR (
                    lifecycle_state IN ('reclaimed', 'ignored')
                    AND resolved_at IS NULL
               )
               OR NOT EXISTS (
                    SELECT 1 FROM operation_groups
                    WHERE operation_groups.id =
                        storage_orphans.operation_group_id
                      AND operation_groups.fencing_token =
                        storage_orphans.fencing_token
               )
            """,
            """
            SELECT COUNT(*) FROM storage_capacity_samples
            WHERE used_bytes > total_bytes - available_bytes
               OR used_inodes > total_inodes - available_inodes
               OR reclaimable_bytes > used_bytes
               OR reclaimable_inodes > used_inodes
               OR valid_until_ms <= captured_at_ms
               OR valid_until_ms - captured_at_ms > 900000
               OR (
                    quota_enforcement_mode = 'hard'
                    AND quota_evidence_sha256 IS NULL
               )
               OR NOT EXISTS (
                    SELECT 1 FROM operation_groups
                    WHERE operation_groups.id =
                        storage_capacity_samples.operation_group_id
                      AND operation_groups.fencing_token =
                        storage_capacity_samples.fencing_token
               )
            """,
            """
            SELECT COUNT(*) FROM storage_quotas
            WHERE generation < 1 OR retry_attempt NOT BETWEEN 1 AND 3
               OR (byte_limit IS NULL AND inode_limit IS NULL)
               OR (
                    enforcement_mode = 'hard'
                    AND enforcement_evidence_sha256 IS NULL
               )
               OR NOT EXISTS (
                    SELECT 1 FROM operation_groups
                    WHERE operation_groups.id =
                        storage_quotas.operation_group_id
                      AND operation_groups.fencing_token =
                        storage_quotas.fencing_token
               )
            """,
            """
            SELECT COUNT(*) FROM storage_capacity_admissions
            WHERE attempt NOT BETWEEN 1 AND maximum_attempts
               OR maximum_attempts NOT BETWEEN 1 AND 3
               OR NOT EXISTS (
                    SELECT 1 FROM storage_capacity_samples
                    WHERE storage_capacity_samples.id =
                        storage_capacity_admissions.sample_id
                      AND storage_capacity_samples.sample_digest_sha256 =
                        storage_capacity_admissions.sample_digest_sha256
               )
               OR NOT EXISTS (
                    SELECT 1 FROM operation_groups
                    WHERE operation_groups.id =
                        storage_capacity_admissions.operation_group_id
                      AND operation_groups.fencing_token =
                        storage_capacity_admissions.fencing_token
               )
            """
        ]
        return try queries.reduce(0) { total, sql in
            let value = try connection.query(sql).first?.first ?? nil
            guard let value, let count = Int(value), count >= 0 else {
                throw StateStoreError.invalidRecord(
                    "Storage state integrity count could not be decoded."
                )
            }
            return total + count
        }
    }

    private static let volumeSelect = """
        SELECT id, project_id, name, provider_id,
               provider_volume_id, topology_node_id,
               generation, fencing_token,
               capacity_bytes, lifecycle_state, reclaim_policy,
               access_mode, source_kind, source_id,
               operation_group_id, created_at, updated_at
        FROM storage_volumes
        """

    private static let attachmentSelect = """
        SELECT id, volume_id, node_id, node_uuid, workload_uuid,
               attachment_kind, path, staging_path, access_mode,
               read_only, generation, fencing_token,
               lifecycle_state, checkpoint, lease_renewed_at,
               lease_expires_at, operation_id, idempotency_key,
               provider_observation_sha256,
               force_detach_authorization_sha256,
               ambiguous_hold_reason_redacted, operation_group_id,
               created_at, updated_at
        FROM storage_attachments
        """

    private static let snapshotSelect = """
        SELECT id, name, source_volume_id, provider_id,
               provider_snapshot_id, consistency_class,
               parent_content_tree_sha256, content_tree_sha256,
               lineage_json, generation, fencing_token, size_bytes,
               lifecycle_state, operation_group_id, created_at,
               updated_at
        FROM storage_snapshots
        """

    private static let backupSelect = """
        SELECT id, volume_id, snapshot_id, destination_redacted,
               content_sha256, size_bytes, generation,
               fencing_token, lifecycle_state, operation_group_id,
               created_at, updated_at
        FROM storage_backups
        """

    private static let holdSelect = """
        SELECT id, resource_kind, resource_id, reason_redacted,
               generation, fencing_token, operation_group_id,
               created_at, expires_at, released_at
        FROM storage_holds
        """

    private static let orphanSelect = """
        SELECT id, provider_id, resource_kind,
               provider_resource_id_hash, ownership_proof_sha256,
               generation, fencing_token, lifecycle_state,
               operation_group_id, discovered_at, resolved_at
        FROM storage_orphans
        """

    private static let capacitySampleSelect = """
        SELECT id, provider_id, topology_node_id, source,
               requested_bytes, reserved_bytes, used_bytes,
               reclaimable_bytes, available_bytes, total_bytes,
               requested_inodes, reserved_inodes, used_inodes,
               reclaimable_inodes, available_inodes, total_inodes,
               quota_enforcement_mode, quota_evidence_sha256,
               pressure_level, sample_digest_sha256,
               captured_at_ms, valid_until_ms, fencing_token,
               operation_group_id, created_at
        FROM storage_capacity_samples
        """

    private static let quotaSelect = """
        SELECT id, resource_id, provider_id, byte_limit,
               inode_limit, enforcement_mode,
               enforcement_evidence_sha256, generation,
               fencing_token, lifecycle_state, retry_attempt,
               recovery_checkpoint, operation_id,
               idempotency_key, operation_group_id,
               created_at, updated_at
        FROM storage_quotas
        """

    private static let capacityAdmissionSelect = """
        SELECT id, sample_id, sample_digest_sha256, action,
               additional_bytes, additional_inodes, writable,
               operation_id, idempotency_key, disposition, reason,
               pressure_level, retry_disposition,
               recovery_checkpoint, attempt, maximum_attempts,
               effective_available_bytes,
               effective_available_inodes, fencing_token,
               operation_group_id, created_at
        FROM storage_capacity_admissions
        """

    private static func loadVolume(
        id: String,
        on connection: SQLiteConnection
    ) throws -> StorageStateVolumeRecord? {
        try connection.query(
            volumeSelect + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)]
        ).first.map(volume(from:))
    }

    private static func loadAttachment(
        id: String,
        on connection: SQLiteConnection
    ) throws -> StorageStateAttachmentRecord? {
        try connection.query(
            attachmentSelect + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)]
        ).first.map(attachment(from:))
    }

    private static func loadSnapshot(
        id: String,
        on connection: SQLiteConnection
    ) throws -> StorageStateSnapshotRecord? {
        try connection.query(
            snapshotSelect + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)]
        ).first.map(snapshot(from:))
    }

    private static func loadBackup(
        id: String,
        on connection: SQLiteConnection
    ) throws -> StorageStateBackupRecord? {
        try connection.query(
            backupSelect + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)]
        ).first.map(backup(from:))
    }

    private static func loadHold(
        id: String,
        on connection: SQLiteConnection
    ) throws -> StorageStateHoldRecord? {
        try connection.query(
            holdSelect + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)]
        ).first.map(hold(from:))
    }

    private static func loadOrphan(
        id: String,
        on connection: SQLiteConnection
    ) throws -> StorageStateOrphanRecord? {
        try connection.query(
            orphanSelect + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)]
        ).first.map(orphan(from:))
    }

    private static func loadCapacitySample(
        id: String,
        on connection: SQLiteConnection
    ) throws -> StorageStateCapacitySampleRecord? {
        try connection.query(
            capacitySampleSelect + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)]
        ).first.map(capacitySample(from:))
    }

    private static func loadQuota(
        id: String,
        on connection: SQLiteConnection
    ) throws -> StorageStateQuotaRecord? {
        try connection.query(
            quotaSelect + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)]
        ).first.map(quota(from:))
    }

    private static func loadCapacityAdmission(
        id: String,
        on connection: SQLiteConnection
    ) throws -> StorageStateCapacityAdmissionRecord? {
        try connection.query(
            capacityAdmissionSelect + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)]
        ).first.map(capacityAdmission(from:))
    }

    private static func volume(
        from row: [String?]
    ) throws -> StorageStateVolumeRecord {
        guard row.count == 17,
              let id = row[0], let projectID = row[1],
              let name = row[2],
              let providerID = row[3],
              let providerVolumeID = row[4],
              let topologyNodeID = row[5],
              let generationText = row[6],
              let generation = Int64(generationText),
              let fencingToken = row[7],
              let capacityText = row[8],
              let capacityBytes = Int64(capacityText),
              let stateText = row[9],
              let state = StorageVolumeLifecycleState(
                  rawValue: stateText
              ),
              let reclaimText = row[10],
              let reclaim = StorageReclaimPolicy(
                  rawValue: reclaimText
              ),
              let accessText = row[11],
              let access = StorageAccessMode(rawValue: accessText),
              let operationGroupID = row[14],
              let createdAt = row[15],
              let updatedAt = row[16] else {
            throw StateStoreError.invalidRecord(
                "Could not decode storage volume state."
            )
        }
        let record = StorageStateVolumeRecord(
            id: id, projectID: projectID, name: name,
            providerID: providerID,
            providerVolumeID: providerVolumeID,
            topologyNodeID: topologyNodeID,
            generation: generation, fencingToken: fencingToken,
            capacityBytes: capacityBytes, lifecycleState: state,
            reclaimPolicy: reclaim, accessMode: access,
            sourceKind: row[12].flatMap(
                StorageHoldResourceKind.init(rawValue:)
            ),
            sourceID: row[13],
            operationGroupID: operationGroupID,
            createdAt: createdAt, updatedAt: updatedAt
        )
        try validate(record)
        return record
    }

    private static func attachment(
        from row: [String?]
    ) throws -> StorageStateAttachmentRecord {
        guard row.count == 24,
              let id = row[0], let volumeID = row[1],
              let nodeID = row[2], let nodeUUID = row[3],
              let workloadUUID = row[4],
              let kindText = row[5],
              let kind = StorageAttachmentKind(rawValue: kindText),
              let path = row[6], let accessText = row[8],
              let accessMode = StorageAccessMode(
                  rawValue: accessText
              ),
              let readOnlyText = row[9],
              let readOnlyInt = Int(readOnlyText),
              let generationText = row[10],
              let generation = Int64(generationText),
              let fencingToken = row[11],
              let stateText = row[12],
              let state = StorageAttachmentLifecycleState(
                  rawValue: stateText
              ),
              let checkpointText = row[13],
              let checkpoint = StorageAttachmentCheckpoint(
                  rawValue: checkpointText
              ),
              let leaseRenewedAt = row[14],
              let leaseExpiresAt = row[15],
              let operationID = row[16],
              let idempotencyKey = row[17],
              let operationGroupID = row[21],
              let createdAt = row[22],
              let updatedAt = row[23] else {
            throw StateStoreError.invalidRecord(
                "Could not decode storage attachment state."
            )
        }
        let record = StorageStateAttachmentRecord(
            id: id, volumeID: volumeID, nodeID: nodeID,
            nodeUUID: nodeUUID, workloadUUID: workloadUUID,
            kind: kind, path: path, stagingPath: row[7],
            accessMode: accessMode, readOnly: readOnlyInt == 1,
            generation: generation,
            fencingToken: fencingToken, lifecycleState: state,
            checkpoint: checkpoint,
            leaseRenewedAt: leaseRenewedAt,
            leaseExpiresAt: leaseExpiresAt,
            operationID: operationID,
            idempotencyKey: idempotencyKey,
            providerObservationSHA256: row[18],
            forceDetachAuthorizationSHA256: row[19],
            ambiguousHoldReasonRedacted: row[20],
            operationGroupID: operationGroupID,
            createdAt: createdAt, updatedAt: updatedAt
        )
        try validate(record)
        return record
    }

    private static func snapshot(
        from row: [String?]
    ) throws -> StorageStateSnapshotRecord {
        guard row.count == 16,
              let id = row[0], let name = row[1],
              let volumeID = row[2], let providerID = row[3],
              let providerSnapshotID = row[4],
              let consistencyText = row[5],
              let consistency =
                StorageSnapshotConsistencyClass(
                    rawValue: consistencyText
                ),
              let parentContentTreeSHA256 = row[6],
              let contentTreeSHA256 = row[7],
              let lineageJSON = row[8],
              let lineage = try? decodeLineage(lineageJSON),
              let generationText = row[9],
              let generation = Int64(generationText),
              let fencingToken = row[10],
              let sizeText = row[11],
              let sizeBytes = Int64(sizeText),
              let stateText = row[12],
              let state = StorageSnapshotLifecycleState(
                  rawValue: stateText
              ),
              let operationGroupID = row[13],
              let createdAt = row[14],
              let updatedAt = row[15] else {
            throw StateStoreError.invalidRecord(
                "Could not decode storage snapshot state."
            )
        }
        let record = StorageStateSnapshotRecord(
            id: id, name: name, sourceVolumeID: volumeID,
            providerID: providerID,
            providerSnapshotID: providerSnapshotID,
            consistencyClass: consistency,
            parentContentTreeSHA256:
                parentContentTreeSHA256,
            contentTreeSHA256: contentTreeSHA256,
            lineage: lineage,
            generation: generation, fencingToken: fencingToken,
            sizeBytes: sizeBytes, lifecycleState: state,
            operationGroupID: operationGroupID,
            createdAt: createdAt, updatedAt: updatedAt
        )
        try validate(record)
        return record
    }

    private static func backup(
        from row: [String?]
    ) throws -> StorageStateBackupRecord {
        guard row.count == 12,
              let id = row[0], let volumeID = row[1],
              let destination = row[3],
              let contentSHA256 = row[4],
              let sizeText = row[5],
              let sizeBytes = Int64(sizeText),
              let generationText = row[6],
              let generation = Int64(generationText),
              let fencingToken = row[7],
              let stateText = row[8],
              let state = StorageBackupLifecycleState(
                  rawValue: stateText
              ),
              let operationGroupID = row[9],
              let createdAt = row[10],
              let updatedAt = row[11] else {
            throw StateStoreError.invalidRecord(
                "Could not decode storage backup state."
            )
        }
        let record = StorageStateBackupRecord(
            id: id, volumeID: volumeID, snapshotID: row[2],
            destinationRedacted: destination,
            contentSHA256: contentSHA256,
            sizeBytes: sizeBytes, generation: generation,
            fencingToken: fencingToken, lifecycleState: state,
            operationGroupID: operationGroupID,
            createdAt: createdAt, updatedAt: updatedAt
        )
        try validate(record)
        return record
    }

    private static func hold(
        from row: [String?]
    ) throws -> StorageStateHoldRecord {
        guard row.count == 10,
              let id = row[0], let kindText = row[1],
              let kind = StorageHoldResourceKind(rawValue: kindText),
              let resourceID = row[2], let reason = row[3],
              let generationText = row[4],
              let generation = Int64(generationText),
              let fencingToken = row[5],
              let operationGroupID = row[6],
              let createdAt = row[7] else {
            throw StateStoreError.invalidRecord(
                "Could not decode storage hold state."
            )
        }
        let record = StorageStateHoldRecord(
            id: id, resourceKind: kind,
            resourceID: resourceID, reasonRedacted: reason,
            generation: generation, fencingToken: fencingToken,
            operationGroupID: operationGroupID,
            createdAt: createdAt, expiresAt: row[8],
            releasedAt: row[9]
        )
        try validate(record)
        return record
    }

    private static func orphan(
        from row: [String?]
    ) throws -> StorageStateOrphanRecord {
        guard row.count == 11,
              let id = row[0], let providerID = row[1],
              let kindText = row[2],
              let kind = StorageOrphanResourceKind(
                  rawValue: kindText
              ),
              let resourceHash = row[3],
              let generationText = row[5],
              let generation = Int64(generationText),
              let fencingToken = row[6],
              let stateText = row[7],
              let state = StorageOrphanLifecycleState(
                  rawValue: stateText
              ),
              let operationGroupID = row[8],
              let discoveredAt = row[9] else {
            throw StateStoreError.invalidRecord(
                "Could not decode storage orphan state."
            )
        }
        let record = StorageStateOrphanRecord(
            id: id, providerID: providerID,
            resourceKind: kind,
            providerResourceIDHash: resourceHash,
            ownershipProofSHA256: row[4],
            generation: generation, fencingToken: fencingToken,
            lifecycleState: state,
            operationGroupID: operationGroupID,
            discoveredAt: discoveredAt,
            resolvedAt: row[10]
        )
        try validate(record)
        return record
    }

    private static func capacitySample(
        from row: [String?]
    ) throws -> StorageStateCapacitySampleRecord {
        guard row.count == 25,
              let id = row[0],
              let providerID = row[1],
              let topologyNodeID = row[2],
              let sourceText = row[3],
              let source = StorageCapacitySampleSource(
                  rawValue: sourceText
              ),
              let requestedBytes = row[4].flatMap(Int64.init),
              let reservedBytes = row[5].flatMap(Int64.init),
              let usedBytes = row[6].flatMap(Int64.init),
              let reclaimableBytes = row[7].flatMap(Int64.init),
              let availableBytes = row[8].flatMap(Int64.init),
              let totalBytes = row[9].flatMap(Int64.init),
              let requestedInodes = row[10].flatMap(Int64.init),
              let reservedInodes = row[11].flatMap(Int64.init),
              let usedInodes = row[12].flatMap(Int64.init),
              let reclaimableInodes = row[13].flatMap(Int64.init),
              let availableInodes = row[14].flatMap(Int64.init),
              let totalInodes = row[15].flatMap(Int64.init),
              let quotaModeText = row[16],
              let quotaMode = StorageQuotaEnforcementMode(
                  rawValue: quotaModeText
              ),
              let pressureText = row[18],
              let pressure = StoragePressureLevel(
                  rawValue: pressureText
              ),
              let storedDigest = row[19],
              let capturedAt = row[20].flatMap(Int64.init),
              let validUntil = row[21].flatMap(Int64.init),
              let fencingToken = row[22],
              let operationGroupID = row[23],
              let createdAt = row[24] else {
            throw StateStoreError.invalidRecord(
                "Could not decode storage capacity sample."
            )
        }
        let quota = try StorageQuotaCapability(
            mode: quotaMode,
            evidenceSHA256: row[17]
        )
        let sample = try StorageCapacitySample(
            id: id,
            providerID: providerID,
            topologyNodeID: topologyNodeID,
            source: source,
            requestedBytes: requestedBytes,
            reservedBytes: reservedBytes,
            usedBytes: usedBytes,
            reclaimableBytes: reclaimableBytes,
            availableBytes: availableBytes,
            totalBytes: totalBytes,
            requestedInodes: requestedInodes,
            reservedInodes: reservedInodes,
            usedInodes: usedInodes,
            reclaimableInodes: reclaimableInodes,
            availableInodes: availableInodes,
            totalInodes: totalInodes,
            quotaCapability: quota,
            capturedAtUnixMilliseconds: capturedAt,
            validUntilUnixMilliseconds: validUntil
        )
        guard sample.digestSHA256 == storedDigest else {
            throw StateStoreError.invalidRecord(
                "Storage capacity sample digest does not match its accounting."
            )
        }
        let record = StorageStateCapacitySampleRecord(
            sample: sample,
            pressureLevel: pressure,
            fencingToken: fencingToken,
            operationGroupID: operationGroupID,
            createdAt: createdAt
        )
        try validate(record)
        return record
    }

    private static func quota(
        from row: [String?]
    ) throws -> StorageStateQuotaRecord {
        guard row.count == 17,
              let id = row[0],
              let resourceID = row[1],
              let providerID = row[2],
              let enforcementText = row[5],
              let enforcementMode = StorageQuotaEnforcementMode(
                  rawValue: enforcementText
              ),
              let generation = row[7].flatMap(Int64.init),
              let fencingToken = row[8],
              let lifecycleText = row[9],
              let lifecycle = StorageQuotaLifecycleState(
                  rawValue: lifecycleText
              ),
              let retryAttempt = row[10].flatMap(Int.init),
              let checkpointText = row[11],
              let checkpoint = StorageCapacityRecoveryCheckpoint(
                  rawValue: checkpointText
              ),
              let operationID = row[12],
              let idempotencyKey = row[13],
              let operationGroupID = row[14],
              let createdAt = row[15],
              let updatedAt = row[16] else {
            throw StateStoreError.invalidRecord(
                "Could not decode storage quota."
            )
        }
        let record = StorageStateQuotaRecord(
            id: id,
            resourceID: resourceID,
            providerID: providerID,
            byteLimit: row[3].flatMap(Int64.init),
            inodeLimit: row[4].flatMap(Int64.init),
            enforcementMode: enforcementMode,
            enforcementEvidenceSHA256: row[6],
            generation: generation,
            fencingToken: fencingToken,
            lifecycleState: lifecycle,
            retryAttempt: retryAttempt,
            recoveryCheckpoint: checkpoint,
            operationID: operationID,
            idempotencyKey: idempotencyKey,
            operationGroupID: operationGroupID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        try validate(record)
        return record
    }

    private static func capacityAdmission(
        from row: [String?]
    ) throws -> StorageStateCapacityAdmissionRecord {
        guard row.count == 21,
              let id = row[0],
              let sampleID = row[1],
              let sampleDigest = row[2],
              let actionText = row[3],
              let action = StorageCapacityAction(
                  rawValue: actionText
              ),
              let additionalBytes = row[4].flatMap(Int64.init),
              let additionalInodes = row[5].flatMap(Int64.init),
              let writableInt = row[6].flatMap(Int.init),
              let operationID = row[7],
              let idempotencyKey = row[8],
              let dispositionText = row[9],
              let disposition = StorageAdmissionDisposition(
                  rawValue: dispositionText
              ),
              let reasonText = row[10],
              let reason = StorageCapacityReason(
                  rawValue: reasonText
              ),
              let pressureText = row[11],
              let pressure = StoragePressureLevel(
                  rawValue: pressureText
              ),
              let retryText = row[12],
              let retry = StorageCapacityRetryDisposition(
                  rawValue: retryText
              ),
              let checkpointText = row[13],
              let checkpoint = StorageCapacityRecoveryCheckpoint(
                  rawValue: checkpointText
              ),
              let attempt = row[14].flatMap(Int.init),
              let maximumAttempts = row[15].flatMap(Int.init),
              let effectiveBytes = row[16].flatMap(Int64.init),
              let effectiveInodes = row[17].flatMap(Int64.init),
              let fencingToken = row[18],
              let operationGroupID = row[19],
              let createdAt = row[20] else {
            throw StateStoreError.invalidRecord(
                "Could not decode storage capacity admission."
            )
        }
        let result = StorageCapacityAdmissionResult(
            operationID: operationID,
            idempotencyKey: idempotencyKey,
            disposition: disposition,
            reason: reason,
            pressure: pressure,
            retryDisposition: retry,
            checkpoint: checkpoint,
            attempt: attempt,
            effectiveAvailableBytes: effectiveBytes,
            effectiveAvailableInodes: effectiveInodes
        )
        let record = StorageStateCapacityAdmissionRecord(
            id: id,
            sampleID: sampleID,
            sampleDigestSHA256: sampleDigest,
            action: action,
            additionalBytes: additionalBytes,
            additionalInodes: additionalInodes,
            writable: writableInt == 1,
            result: result,
            maximumAttempts: maximumAttempts,
            fencingToken: fencingToken,
            operationGroupID: operationGroupID,
            createdAt: createdAt
        )
        try validate(record)
        return record
    }

    private static func validateOperationGroup(
        id: String,
        fencingToken: String,
        on connection: SQLiteConnection
    ) throws {
        let rows = try connection.query(
            """
            SELECT fencing_token
            FROM operation_groups
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(id)]
        )
        guard rows.count == 1,
              rows[0][0] == fencingToken else {
            throw StateStoreError.invalidRecord(
                "Storage state requires an operation group with the exact fencing token."
            )
        }
    }

    private static func validateCreation(
        generation: Int64,
        expected: StorageStateExpectedVersion?,
        label: String
    ) throws {
        guard expected == nil, generation == 1 else {
            throw StateStoreError.invalidRecord(
                "New storage \(label) state must begin at generation 1 without replacement evidence."
            )
        }
    }

    private static func validateReplacement(
        existingGeneration: Int64,
        existingFence: String,
        existingCreatedAt: String,
        incomingGeneration: Int64,
        incomingCreatedAt: String,
        expected: StorageStateExpectedVersion?,
        label: String
    ) throws {
        guard let expected,
              expected.generation == existingGeneration,
              expected.fencingToken == existingFence else {
            throw StateStoreError.invalidRecord(
                "Storage \(label) replacement lost its exact generation or fence."
            )
        }
        guard incomingGeneration == existingGeneration + 1,
              incomingCreatedAt == existingCreatedAt else {
            throw StateStoreError.invalidRecord(
                "Storage \(label) replacement must advance exactly one generation while preserving creation identity."
            )
        }
    }

    private static func validateAttachmentReplacement(
        existing: StorageStateAttachmentRecord,
        incoming: StorageStateAttachmentRecord,
        expected: StorageStateExpectedVersion?,
        on connection: SQLiteConnection
    ) throws {
        guard let expected,
              expected.generation == existing.generation,
              expected.fencingToken == existing.fencingToken else {
            throw StateStoreError.invalidRecord(
                "Storage attachment replacement lost its exact generation or fence."
            )
        }
        guard incoming.id == existing.id,
              incoming.volumeID == existing.volumeID,
              incoming.nodeID == existing.nodeID,
              incoming.nodeUUID == existing.nodeUUID,
              incoming.workloadUUID == existing.workloadUUID,
              incoming.kind == existing.kind,
              incoming.path == existing.path,
              incoming.stagingPath == existing.stagingPath,
              incoming.accessMode == existing.accessMode,
              incoming.readOnly == existing.readOnly,
              incoming.createdAt == existing.createdAt,
              date(incoming.updatedAt) >=
                date(existing.updatedAt) else {
            throw StateStoreError.invalidRecord(
                "Storage attachment holder and creation identity are immutable."
            )
        }

        if incoming.generation == existing.generation {
            guard incoming.fencingToken == existing.fencingToken,
                  incoming.operationID == existing.operationID,
                  incoming.idempotencyKey ==
                    existing.idempotencyKey,
                  incoming.operationGroupID ==
                    existing.operationGroupID,
                  date(incoming.leaseRenewedAt) >=
                    date(existing.leaseRenewedAt),
                  date(incoming.leaseExpiresAt) >=
                    date(existing.leaseExpiresAt),
                  validAttachmentCheckpointTransition(
                      from: existing,
                      to: incoming
                  ),
                  validAttachmentEvidenceTransition(
                      from: existing,
                      to: incoming
                  ) else {
                throw StateStoreError.invalidRecord(
                    "Storage attachment checkpoint update lost authority or moved out of order."
                )
            }
        } else {
            let successor = existing.generation.addingReportingOverflow(1)
            guard !successor.overflow,
                  incoming.generation == successor.partialValue,
                  incoming.fencingToken != existing.fencingToken,
                  incoming.providerObservationSHA256 == nil,
                  incoming.ambiguousHoldReasonRedacted == nil,
                  (
                    incoming.checkpoint == .detachIntentPersisted ||
                    (
                        existing.checkpoint == .detachedCommitted &&
                        incoming.checkpoint ==
                            .attachIntentPersisted
                    )
                  ) else {
                throw StateStoreError.invalidRecord(
                    "Storage attachment authority must advance one generation with a new fence and durable intent."
                )
            }
        }

        let current = try loadAttachment(
            id: existing.id,
            on: connection
        )
        guard current?.generation == expected.generation,
              current?.fencingToken == expected.fencingToken else {
            throw StateStoreError.invalidRecord(
                "Storage attachment compare-and-swap authority changed before persistence."
            )
        }
    }

    private static func validAttachmentCheckpointTransition(
        from existing: StorageStateAttachmentRecord,
        to incoming: StorageStateAttachmentRecord
    ) -> Bool {
        if incoming.checkpoint == existing.checkpoint {
            if incoming.lifecycleState == .ambiguousHold {
                return existing.checkpoint
                    .providerEffectMayBeAmbiguous
            }
            if existing.lifecycleState == .ambiguousHold {
                return incoming.lifecycleState == .ambiguousHold
            }
            return incoming.lifecycleState ==
                existing.lifecycleState
        }
        if existing.checkpoint.next == incoming.checkpoint {
            return true
        }
        if existing.lifecycleState == .ambiguousHold {
            switch (existing.checkpoint, incoming.checkpoint) {
            case (
                .attachProviderEffectRequested,
                .attachFenceAcquired
            ),
            (
                .attachProviderEffectRequested,
                .attachProviderObserved
            ),
            (
                .detachProviderEffectRequested,
                .detachFenceAcquired
            ),
            (
                .detachProviderEffectRequested,
                .detachProviderAbsentObserved
            ):
                return incoming.lifecycleState != .ambiguousHold
            default:
                return false
            }
        }
        return false
    }

    private static func validAttachmentEvidenceTransition(
        from existing: StorageStateAttachmentRecord,
        to incoming: StorageStateAttachmentRecord
    ) -> Bool {
        guard incoming.forceDetachAuthorizationSHA256 ==
                existing.forceDetachAuthorizationSHA256 else {
            return false
        }
        if incoming.checkpoint == existing.checkpoint {
            if incoming.lifecycleState == .ambiguousHold,
               existing.lifecycleState != .ambiguousHold {
                return incoming.providerObservationSHA256 ==
                    existing.providerObservationSHA256
            }
            return incoming.providerObservationSHA256 ==
                    existing.providerObservationSHA256 &&
                incoming.ambiguousHoldReasonRedacted ==
                    existing.ambiguousHoldReasonRedacted
        }
        if existing.lifecycleState == .ambiguousHold {
            return incoming.lifecycleState != .ambiguousHold &&
                incoming.ambiguousHoldReasonRedacted == nil &&
                incoming.providerObservationSHA256 != nil
        }
        guard incoming.ambiguousHoldReasonRedacted == nil else {
            return false
        }
        if incoming.checkpoint == .attachProviderObserved ||
            incoming.checkpoint ==
                .detachProviderAbsentObserved {
            return incoming.providerObservationSHA256 != nil
        }
        return incoming.providerObservationSHA256 ==
            existing.providerObservationSHA256
    }

    private static func validateAttachmentConflicts(
        _ record: StorageStateAttachmentRecord,
        on connection: SQLiteConnection
    ) throws {
        guard record.lifecycleState != .detached else { return }
        let writerConflicts = try connection.query(
            """
            SELECT COUNT(*) FROM storage_attachments
            WHERE id != ? AND volume_id = ?
              AND lifecycle_state != 'detached'
              AND (read_only = 0 OR ? = 0)
            """,
            bindings: [
                .text(record.id),
                .text(record.volumeID),
                .bool(record.readOnly),
            ]
        ).first?.first ?? nil
        let holderConflicts = try connection.query(
            """
            SELECT COUNT(*) FROM storage_attachments
            WHERE id != ? AND volume_id = ?
              AND node_uuid = ? AND workload_uuid = ?
              AND lifecycle_state != 'detached'
            """,
            bindings: [
                .text(record.id),
                .text(record.volumeID),
                .text(record.nodeUUID),
                .text(record.workloadUUID),
            ]
        ).first?.first ?? nil
        guard writerConflicts == "0" else {
            throw StateStoreError.invalidRecord(
                "Storage single-writer attachment conflict."
            )
        }
        guard holderConflicts == "0" else {
            throw StateStoreError.invalidRecord(
                "Storage attachment holder already owns an active generation."
            )
        }
    }

    private static func validate(
        _ record: StorageStateVolumeRecord
    ) throws {
        try validateUUID(record.id, label: "volume id")
        try validateIdentifier(
            record.projectID,
            maximumBytes: 256,
            label: "volume project id"
        )
        try validateIdentifier(
            record.name,
            maximumBytes: 128,
            label: "volume name"
        )
        try validateIdentifier(
            record.providerID,
            maximumBytes: 256,
            label: "volume provider id"
        )
        try validatePrintable(
            record.providerVolumeID,
            maximumBytes: 512,
            label: "provider volume id"
        )
        try validateIdentifier(
            record.topologyNodeID,
            maximumBytes: 128,
            label: "volume topology node id"
        )
        try validateVersion(
            generation: record.generation,
            fencingToken: record.fencingToken,
            label: "volume"
        )
        guard (1...1_125_899_906_842_624)
            .contains(record.capacityBytes),
              (record.sourceKind == nil) ==
                (record.sourceID == nil) else {
            throw StateStoreError.invalidRecord(
                "Storage volume capacity or source identity is invalid."
            )
        }
        if let sourceID = record.sourceID {
            try validateUUID(sourceID, label: "volume source id")
        }
        try validateUUID(
            record.operationGroupID,
            label: "volume operation group id"
        )
        try validateTimestamps(
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            label: "volume"
        )
    }

    private static func validate(
        _ record: StorageStateAttachmentRecord
    ) throws {
        try validateUUID(record.id, label: "attachment id")
        try validateUUID(record.volumeID, label: "attachment volume id")
        try validateIdentifier(
            record.nodeID,
            maximumBytes: 128,
            label: "attachment node id"
        )
        try validateUUID(
            record.nodeUUID,
            label: "attachment node UUID"
        )
        try validateUUID(
            record.workloadUUID,
            label: "attachment workload UUID"
        )
        try validatePath(record.path, label: "attachment path")
        if record.kind == .stage {
            guard record.stagingPath == nil, !record.readOnly else {
                throw StateStoreError.invalidRecord(
                    "A stage record cannot contain publish-only fields."
                )
            }
        } else {
            guard let stagingPath = record.stagingPath else {
                throw StateStoreError.invalidRecord(
                    "A publish record requires its exact staging path."
                )
            }
            try validatePath(
                stagingPath,
                label: "attachment staging path"
            )
        }
        guard record.accessMode != .readOnlyMany ||
            record.readOnly else {
            throw StateStoreError.invalidRecord(
                "A read-only-many attachment cannot be published read-write."
            )
        }
        try validateVersion(
            generation: record.generation,
            fencingToken: record.fencingToken,
            label: "attachment"
        )
        try validateUUID(
            record.operationID,
            label: "attachment operation id"
        )
        try validateSHA256(
            record.idempotencyKey,
            label: "attachment idempotency key"
        )
        if let digest = record.providerObservationSHA256 {
            try validateSHA256(
                digest,
                label: "attachment provider observation"
            )
        }
        if let digest = record.forceDetachAuthorizationSHA256 {
            try validateSHA256(
                digest,
                label: "attachment force-detach authorization"
            )
            guard !record.checkpoint.isAttach else {
                throw StateStoreError.invalidRecord(
                    "Force-detach authorization is valid only for a detach checkpoint."
                )
            }
        }
        if let reason = record.ambiguousHoldReasonRedacted {
            try validatePrintable(
                reason,
                maximumBytes: 512,
                label: "attachment ambiguous hold reason"
            )
            guard RuntimeRedactionPolicy.default.redact(reason) ==
                reason else {
                throw StateStoreError.invalidRecord(
                    "Attachment ambiguous hold reason must already be redacted."
                )
            }
        }
        guard (
            record.lifecycleState == .ambiguousHold
        ) == (
            record.ambiguousHoldReasonRedacted != nil
        ),
        record.lifecycleState != .ambiguousHold ||
            record.checkpoint.providerEffectMayBeAmbiguous,
        ![
            StorageAttachmentCheckpoint.attachProviderObserved,
            .attachedCommitted,
            .detachProviderAbsentObserved,
            .detachedCommitted,
        ].contains(record.checkpoint) ||
            record.providerObservationSHA256 != nil,
        attachmentLifecycleMatchesCheckpoint(record) else {
            throw StateStoreError.invalidRecord(
                "Attachment lifecycle, checkpoint, observation, or ambiguous hold is inconsistent."
            )
        }
        try validateUUID(
            record.operationGroupID,
            label: "attachment operation group id"
        )
        try validateTimestamps(
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            label: "attachment"
        )
        try validateTimestamp(
            record.leaseRenewedAt,
            label: "attachment leaseRenewedAt"
        )
        try validateTimestamp(
            record.leaseExpiresAt,
            label: "attachment leaseExpiresAt"
        )
        guard date(record.leaseRenewedAt) >=
            date(record.createdAt),
            date(record.leaseRenewedAt) <=
                date(record.updatedAt),
            date(record.leaseExpiresAt) >
                date(record.leaseRenewedAt),
            date(record.leaseExpiresAt).timeIntervalSince(
                date(record.leaseRenewedAt)
            ) <= 900.001 else {
            throw StateStoreError.invalidRecord(
                "Attachment lease timestamps are not monotonic."
            )
        }
    }

    private static func attachmentLifecycleMatchesCheckpoint(
        _ record: StorageStateAttachmentRecord
    ) -> Bool {
        if record.lifecycleState == .ambiguousHold {
            return record.checkpoint
                .providerEffectMayBeAmbiguous
        }
        switch record.checkpoint {
        case .attachIntentPersisted,
             .attachFenceAcquired,
             .attachProviderEffectRequested,
             .attachProviderObserved:
            return record.lifecycleState == .attaching ||
                record.lifecycleState == .faulted
        case .attachedCommitted:
            return record.lifecycleState == .attached ||
                record.lifecycleState == .faulted
        case .detachIntentPersisted,
             .detachFenceAcquired,
             .detachProviderEffectRequested,
             .detachProviderAbsentObserved:
            return record.lifecycleState == .detaching ||
                record.lifecycleState == .faulted
        case .detachedCommitted:
            return record.lifecycleState == .detached
        }
    }

    private static func validate(
        _ record: StorageStateSnapshotRecord
    ) throws {
        try validateUUID(record.id, label: "snapshot id")
        try validateIdentifier(
            record.name,
            maximumBytes: 128,
            label: "snapshot name"
        )
        try validateUUID(
            record.sourceVolumeID,
            label: "snapshot source volume id"
        )
        try validateIdentifier(
            record.providerID,
            maximumBytes: 256,
            label: "snapshot provider id"
        )
        try validatePrintable(
            record.providerSnapshotID,
            maximumBytes: 512,
            label: "provider snapshot id"
        )
        try validateSHA256(
            record.parentContentTreeSHA256,
            label: "snapshot parent content digest"
        )
        try validateSHA256(
            record.contentTreeSHA256,
            label: "snapshot content digest"
        )
        guard !record.lineage.isEmpty,
              record.lineage.count <= 64,
              record.lineage == record.lineage.sorted(),
              Set(record.lineage).count == record.lineage.count else {
            throw StateStoreError.invalidRecord(
                "Storage snapshot lineage is not canonical."
            )
        }
        for item in record.lineage {
            try validatePrintable(
                item,
                maximumBytes: 512,
                label: "snapshot lineage item"
            )
        }
        guard (0...1_125_899_906_842_624)
            .contains(record.sizeBytes) else {
            throw StateStoreError.invalidRecord(
                "Storage snapshot size is out of bounds."
            )
        }
        try validateVersion(
            generation: record.generation,
            fencingToken: record.fencingToken,
            label: "snapshot"
        )
        try validateUUID(
            record.operationGroupID,
            label: "snapshot operation group id"
        )
        try validateTimestamps(
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            label: "snapshot"
        )
    }

    private static func encodeLineage(
        _ lineage: [String]
    ) throws -> String {
        let data = try JSONEncoder().encode(lineage)
        guard let value = String(data: data, encoding: .utf8),
              value.utf8.count <= 16_384 else {
            throw StateStoreError.invalidRecord(
                "Storage snapshot lineage cannot be encoded."
            )
        }
        return value
    }

    private static func decodeLineage(
        _ value: String
    ) throws -> [String] {
        guard let data = value.data(using: .utf8) else {
            throw StateStoreError.invalidRecord(
                "Storage snapshot lineage is not UTF-8."
            )
        }
        return try JSONDecoder().decode([String].self, from: data)
    }

    private static func validate(
        _ record: StorageStateBackupRecord
    ) throws {
        try validateUUID(record.id, label: "backup id")
        try validateUUID(record.volumeID, label: "backup volume id")
        if let snapshotID = record.snapshotID {
            try validateUUID(snapshotID, label: "backup snapshot id")
        }
        try validatePrintable(
            record.destinationRedacted,
            maximumBytes: 1024,
            label: "backup destination"
        )
        guard RuntimeRedactionPolicy.default.redact(
            record.destinationRedacted
        ) == record.destinationRedacted else {
            throw StateStoreError.invalidRecord(
                "Storage backup destination must already be redacted."
            )
        }
        try validateSHA256(
            record.contentSHA256,
            label: "backup content SHA256"
        )
        guard (0...1_125_899_906_842_624)
            .contains(record.sizeBytes) else {
            throw StateStoreError.invalidRecord(
                "Storage backup size is out of bounds."
            )
        }
        try validateVersion(
            generation: record.generation,
            fencingToken: record.fencingToken,
            label: "backup"
        )
        try validateUUID(
            record.operationGroupID,
            label: "backup operation group id"
        )
        try validateTimestamps(
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            label: "backup"
        )
    }

    private static func validate(
        _ record: StorageStateHoldRecord
    ) throws {
        try validateUUID(record.id, label: "hold id")
        try validateUUID(record.resourceID, label: "hold resource id")
        try validatePrintable(
            record.reasonRedacted,
            maximumBytes: 512,
            label: "hold reason"
        )
        guard RuntimeRedactionPolicy.default.redact(
            record.reasonRedacted
        ) == record.reasonRedacted else {
            throw StateStoreError.invalidRecord(
                "Storage hold reason must already be redacted."
            )
        }
        try validateVersion(
            generation: record.generation,
            fencingToken: record.fencingToken,
            label: "hold"
        )
        try validateUUID(
            record.operationGroupID,
            label: "hold operation group id"
        )
        try validateTimestamp(record.createdAt, label: "hold createdAt")
        if let expiresAt = record.expiresAt {
            try validateTimestamp(expiresAt, label: "hold expiresAt")
            guard date(expiresAt) > date(record.createdAt) else {
                throw StateStoreError.invalidRecord(
                    "Storage hold expiry must follow creation."
                )
            }
        }
        if let releasedAt = record.releasedAt {
            try validateTimestamp(
                releasedAt,
                label: "hold releasedAt"
            )
            guard date(releasedAt) >= date(record.createdAt) else {
                throw StateStoreError.invalidRecord(
                    "Storage hold release cannot predate creation."
                )
            }
        }
    }

    private static func validate(
        _ record: StorageStateOrphanRecord
    ) throws {
        try validateUUID(record.id, label: "orphan id")
        try validateIdentifier(
            record.providerID,
            maximumBytes: 256,
            label: "orphan provider id"
        )
        try validateSHA256(
            record.providerResourceIDHash,
            label: "orphan provider resource hash"
        )
        if let proof = record.ownershipProofSHA256 {
            try validateSHA256(proof, label: "orphan ownership proof")
        }
        guard record.lifecycleState != .reclaimed ||
            record.ownershipProofSHA256 != nil else {
            throw StateStoreError.invalidRecord(
                "Storage orphan reclamation requires exact ownership proof."
            )
        }
        try validateVersion(
            generation: record.generation,
            fencingToken: record.fencingToken,
            label: "orphan"
        )
        try validateUUID(
            record.operationGroupID,
            label: "orphan operation group id"
        )
        try validateTimestamp(
            record.discoveredAt,
            label: "orphan discoveredAt"
        )
        if let resolvedAt = record.resolvedAt {
            try validateTimestamp(
                resolvedAt,
                label: "orphan resolvedAt"
            )
            guard date(resolvedAt) >= date(record.discoveredAt) else {
                throw StateStoreError.invalidRecord(
                    "Storage orphan resolution cannot predate discovery."
                )
            }
        }
        switch record.lifecycleState {
        case .discovered, .held:
            guard record.resolvedAt == nil else {
                throw StateStoreError.invalidRecord(
                    "Unresolved storage orphan state cannot contain a resolution timestamp."
                )
            }
        case .reclaimed, .ignored:
            guard record.resolvedAt != nil else {
                throw StateStoreError.invalidRecord(
                    "Resolved storage orphan state requires a resolution timestamp."
                )
            }
        }
    }

    private static func validate(
        _ record: StorageStateCapacitySampleRecord
    ) throws {
        try validateUUID(
            record.sample.id,
            label: "capacity sample id"
        )
        try validateIdentifier(
            record.sample.providerID,
            maximumBytes: 256,
            label: "capacity provider id"
        )
        try validateIdentifier(
            record.sample.topologyNodeID,
            maximumBytes: 128,
            label: "capacity topology node id"
        )
        try validateSHA256(
            record.sample.digestSHA256,
            label: "capacity sample digest"
        )
        try validateUUID(
            record.fencingToken,
            label: "capacity sample fencing token"
        )
        try validateUUID(
            record.operationGroupID,
            label: "capacity sample operation group id"
        )
        try validateTimestamp(
            record.createdAt,
            label: "capacity sample createdAt"
        )
    }

    private static func validate(
        _ record: StorageStateQuotaRecord
    ) throws {
        try validateUUID(record.id, label: "quota id")
        try validateUUID(
            record.resourceID,
            label: "quota resource id"
        )
        try validateIdentifier(
            record.providerID,
            maximumBytes: 256,
            label: "quota provider id"
        )
        guard record.byteLimit != nil || record.inodeLimit != nil,
              record.byteLimit == nil ||
                (0...StorageCapacityLimits.maximumBytes)
                    .contains(record.byteLimit!),
              record.inodeLimit == nil ||
                (0...StorageCapacityLimits.maximumInodes)
                    .contains(record.inodeLimit!),
              record.retryAttempt >= 1,
              record.retryAttempt <=
                StorageCapacityLimits.maximumRetryAttempts,
              record.enforcementMode != .hard ||
                record.enforcementEvidenceSHA256 != nil else {
            throw StateStoreError.invalidRecord(
                "Storage quota limits, enforcement evidence, or retry bound are invalid."
            )
        }
        if let evidence = record.enforcementEvidenceSHA256 {
            try validateSHA256(
                evidence,
                label: "quota enforcement evidence"
            )
        }
        try validateVersion(
            generation: record.generation,
            fencingToken: record.fencingToken,
            label: "quota"
        )
        try validateUUID(
            record.operationID,
            label: "quota operation id"
        )
        try validateSHA256(
            record.idempotencyKey,
            label: "quota idempotency key"
        )
        try validateUUID(
            record.operationGroupID,
            label: "quota operation group id"
        )
        try validateTimestamps(
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            label: "quota"
        )
    }

    private static func validate(
        _ record: StorageStateCapacityAdmissionRecord
    ) throws {
        try validateUUID(
            record.id,
            label: "capacity admission id"
        )
        try validateUUID(
            record.sampleID,
            label: "capacity admission sample id"
        )
        try validateSHA256(
            record.sampleDigestSHA256,
            label: "capacity admission sample digest"
        )
        try validateUUID(
            record.result.operationID,
            label: "capacity admission operation id"
        )
        try validateSHA256(
            record.result.idempotencyKey,
            label: "capacity admission idempotency key"
        )
        guard (0...StorageCapacityLimits.maximumBytes)
                .contains(record.additionalBytes),
              (0...StorageCapacityLimits.maximumInodes)
                .contains(record.additionalInodes),
              record.action.canGrowStorage ||
                (
                    record.additionalBytes == 0 &&
                    record.additionalInodes == 0
                ),
              record.result.attempt >= 1,
              record.maximumAttempts >= 1,
              record.maximumAttempts <=
                StorageCapacityLimits.maximumRetryAttempts,
              record.result.attempt <= record.maximumAttempts,
              (0...StorageCapacityLimits.maximumBytes)
                .contains(
                    record.result.effectiveAvailableBytes
                ),
              (0...StorageCapacityLimits.maximumInodes)
                .contains(
                    record.result.effectiveAvailableInodes
                ),
              capacityAdmissionCheckpointMatches(record.result)
        else {
            throw StateStoreError.invalidRecord(
                "Storage capacity admission contains invalid bounds, retry state, or recovery checkpoint."
            )
        }
        try validateUUID(
            record.fencingToken,
            label: "capacity admission fencing token"
        )
        try validateUUID(
            record.operationGroupID,
            label: "capacity admission operation group id"
        )
        try validateTimestamp(
            record.createdAt,
            label: "capacity admission createdAt"
        )
    }

    private static func capacityAdmissionCheckpointMatches(
        _ result: StorageCapacityAdmissionResult
    ) -> Bool {
        switch result.disposition {
        case .admit:
            return result.checkpoint == .admitted &&
                result.retryDisposition == .never
        case .throttle:
            return result.checkpoint == .throttled &&
                result.retryDisposition == .afterFreshSample
        case .cancelled:
            return result.checkpoint == .cancelled &&
                result.retryDisposition == .never
        case .recoveryRequired:
            return result.checkpoint == .observationRequired &&
                result.retryDisposition == .resumeFromCheckpoint
        case .reject:
            return [
                StorageCapacityRecoveryCheckpoint.admissionPending,
                .rejected,
            ].contains(result.checkpoint)
        }
    }

    private static func validateHoldTarget(
        _ record: StorageStateHoldRecord,
        on connection: SQLiteConnection
    ) throws {
        let table: String
        switch record.resourceKind {
        case .volume:
            table = "storage_volumes"
        case .snapshot:
            table = "storage_snapshots"
        case .backup:
            table = "storage_backups"
        }
        guard try connection.query(
            "SELECT 1 FROM \(table) WHERE id = ? LIMIT 1",
            bindings: [.text(record.resourceID)]
        ).count == 1 else {
            throw StateStoreError.notFound(
                "Storage hold target is unavailable."
            )
        }
    }

    private static func validateVersion(
        generation: Int64,
        fencingToken: String,
        label: String
    ) throws {
        guard generation >= 1 else {
            throw StateStoreError.invalidRecord(
                "Storage \(label) generation must be positive."
            )
        }
        try validateUUID(
            fencingToken,
            label: "\(label) fencing token"
        )
    }

    private static func validateUUID(
        _ value: String,
        label: String
    ) throws {
        guard HostwrightResourceUUID.isValid(value) else {
            throw StateStoreError.invalidRecord(
                "Storage \(label) must be a canonical UUID."
            )
        }
    }

    private static func validateSHA256(
        _ value: String,
        label: String
    ) throws {
        guard value.utf8.count == 64,
              value.allSatisfy({
                  ("0"..."9").contains($0) ||
                      ("a"..."f").contains($0)
              }) else {
            throw StateStoreError.invalidRecord(
                "Storage \(label) must be lowercase SHA256."
            )
        }
    }

    private static func validateIdentifier(
        _ value: String,
        maximumBytes: Int,
        label: String
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value.range(
                  of: "^[A-Za-z0-9](?:[A-Za-z0-9._:/-]*[A-Za-z0-9])?$",
                  options: .regularExpression
              ) != nil else {
            throw StateStoreError.invalidRecord(
                "Storage \(label) is not a bounded stable identifier."
            )
        }
    }

    private static func validatePrintable(
        _ value: String,
        maximumBytes: Int,
        label: String
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value.unicodeScalars.allSatisfy({
                  (0x20...0x7e).contains($0.value)
              }) else {
            throw StateStoreError.invalidRecord(
                "Storage \(label) is not bounded printable text."
            )
        }
    }

    private static func validatePath(
        _ value: String,
        label: String
    ) throws {
        guard !value.isEmpty, value.utf8.count <= 4096,
              value.hasPrefix("/"),
              !value.split(
                  separator: "/",
                  omittingEmptySubsequences: false
              ).contains(".."),
              URL(fileURLWithPath: value).standardizedFileURL.path ==
                value else {
            throw StateStoreError.invalidRecord(
                "Storage \(label) must be an absolute normalized path."
            )
        }
    }

    private static func validateTimestamps(
        createdAt: String,
        updatedAt: String,
        label: String
    ) throws {
        try validateTimestamp(createdAt, label: "\(label) createdAt")
        try validateTimestamp(updatedAt, label: "\(label) updatedAt")
        guard date(updatedAt) >= date(createdAt) else {
            throw StateStoreError.invalidRecord(
                "Storage \(label) updatedAt cannot predate creation."
            )
        }
    }

    private static func validateTimestamp(
        _ value: String,
        label: String
    ) throws {
        guard value.utf8.count <= 64,
              date(value) != .distantPast else {
            throw StateStoreError.invalidRecord(
                "Storage \(label) must be an ISO-8601 timestamp."
            )
        }
    }

    private static func date(_ value: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ??
            whole.date(from: value) ?? .distantPast
    }
}

public extension SQLiteStateStore {
    var storage: StorageStateRepository {
        StorageStateRepository(store: self)
    }
}

private func optionalInt64(_ value: Int64?) -> SQLiteValue {
    value.map(SQLiteValue.int64) ?? .null
}
