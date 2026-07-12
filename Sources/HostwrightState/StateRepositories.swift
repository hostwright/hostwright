import Foundation
import HostwrightManifest
import HostwrightRuntime

public struct DesiredStateRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func saveManifestSnapshot(
        projectID: String,
        manifestPath: String?,
        manifestHash: String,
        desiredGeneration: Int,
        manifest: HostwrightManifest,
        timestamp: String
    ) throws {
        guard let projectName = manifest.project, !projectName.isEmpty else {
            throw StateStoreError.invalidRecord("Manifest snapshot requires a project name.")
        }

        let project = StateProjectRecord(
            id: projectID,
            name: projectName,
            manifestPath: manifestPath,
            manifestHash: manifestHash,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        let services = try manifest.services.map { service in
            try desiredServiceRecord(
                projectID: projectID,
                manifestHash: manifestHash,
                desiredGeneration: desiredGeneration,
                service: service,
                timestamp: timestamp
            )
        }

        try store.withValidatedConnection { connection in
            try connection.transaction {
                try upsert(project, on: connection)
                for service in services {
                    try upsert(service, on: connection)
                }
            }
        }
    }

    public func loadProject(id: String) throws -> StateProjectRecord {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, name, manifest_path, manifest_hash, created_at, updated_at
                FROM projects
                WHERE id = ?
                """,
                bindings: [.text(id)]
            )
            guard let row = rows.first else {
                throw StateStoreError.notFound("Project \(id)")
            }
            return try projectRecord(from: row)
        }
    }

    public func loadDesiredServices(projectID: String) throws -> [DesiredServiceRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, service_name, image, command_json, ports_json, mounts_json,
                       env_json_redacted, manifest_hash, desired_generation, created_at, updated_at
                FROM desired_services
                WHERE project_id = ?
                ORDER BY desired_generation ASC, service_name ASC
                """,
                bindings: [.text(projectID)]
            )
            return try rows.map(desiredServiceRecord(from:))
        }
    }

    private func desiredServiceRecord(
        projectID: String,
        manifestHash: String,
        desiredGeneration: Int,
        service: HostwrightService,
        timestamp: String
    ) throws -> DesiredServiceRecord {
        guard let image = service.image, !image.isEmpty else {
            throw StateStoreError.invalidRecord("Desired service \(service.name) requires an image.")
        }

        var redactedEnvironment = RuntimeRedactionPolicy.default.redact(environment: service.env)
        for key in service.secretEnv.keys {
            redactedEnvironment[key] = RuntimeRedactionPolicy.default.replacement
        }

        return DesiredServiceRecord(
            id: "\(projectID):\(service.name):\(desiredGeneration)",
            projectID: projectID,
            serviceName: service.name,
            image: image,
            commandJSON: try StateJSON.encodeStringArray(service.command),
            portsJSON: try StateJSON.encodeStringArray(service.ports),
            mountsJSON: try StateJSON.encodeStringArray(service.volumes),
            environmentJSONRedacted: try StateJSON.encode(redactedEnvironment),
            manifestHash: manifestHash,
            desiredGeneration: desiredGeneration,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func upsert(_ project: StateProjectRecord, on connection: SQLiteConnection) throws {
        try connection.run(
            """
            INSERT INTO projects (id, name, manifest_path, manifest_hash, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                manifest_path = excluded.manifest_path,
                manifest_hash = excluded.manifest_hash,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(project.id),
                .text(project.name),
                optionalText(project.manifestPath),
                .text(project.manifestHash),
                .text(project.createdAt),
                .text(project.updatedAt)
            ]
        )
    }

    private func upsert(_ service: DesiredServiceRecord, on connection: SQLiteConnection) throws {
        try connection.run(
            """
            INSERT INTO desired_services (
                id, project_id, service_name, image, command_json, ports_json, mounts_json,
                env_json_redacted, manifest_hash, desired_generation, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(project_id, service_name, desired_generation) DO UPDATE SET
                image = excluded.image,
                command_json = excluded.command_json,
                ports_json = excluded.ports_json,
                mounts_json = excluded.mounts_json,
                env_json_redacted = excluded.env_json_redacted,
                manifest_hash = excluded.manifest_hash,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(service.id),
                .text(service.projectID),
                .text(service.serviceName),
                .text(service.image),
                .text(service.commandJSON),
                .text(service.portsJSON),
                .text(service.mountsJSON),
                .text(service.environmentJSONRedacted),
                .text(service.manifestHash),
                .int(service.desiredGeneration),
                .text(service.createdAt),
                .text(service.updatedAt)
            ]
        )
    }
}

public struct ObservedStateRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func saveSnapshot(
        snapshotID: String,
        projectID: String?,
        observedState: ObservedRuntimeState,
        runtimeAdapter: String,
        parserVersion: String,
        rawOutputHash: String?,
        redactedSummary: String,
        observedAt: String
    ) throws {
        let metadata = observedState.adapterMetadata
        let capabilities = metadata?.capabilities.map(\.rawValue).sorted() ?? []
        let snapshot = ObservedRuntimeSnapshotRecord(
            id: snapshotID,
            projectID: projectID ?? "",
            runtimeAdapter: runtimeAdapter,
            runtimeName: metadata?.runtimeName ?? "unknown",
            runtimeVersion: metadata?.runtimeVersion,
            observedAt: observedAt,
            parserVersion: parserVersion,
            rawOutputHash: rawOutputHash,
            redactedSummary: RuntimeRedactionPolicy.default.redact(redactedSummary),
            capabilitiesJSON: try StateJSON.encodeStringArray(capabilities)
        )

        let services = try observedState.services
            .sorted { $0.identity.displayName < $1.identity.displayName }
            .map { service in
                try observedServiceRecord(snapshotID: snapshotID, service: service)
            }

        try store.withValidatedConnection { connection in
            try connection.transaction {
                try insert(snapshot, projectID: projectID, on: connection)
                for service in services {
                    try insert(service, on: connection)
                }
            }
        }
    }

    public func loadSnapshots(projectID: String?) throws -> [ObservedRuntimeSnapshotRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows: [[String?]]
            if let projectID {
                rows = try connection.query(
                    """
                    SELECT id, project_id, runtime_adapter, runtime_name, runtime_version, observed_at,
                           parser_version, raw_output_hash, redacted_summary, capabilities_json
                    FROM observed_runtime_snapshots
                    WHERE project_id = ?
                    ORDER BY observed_at ASC, id ASC
                    """,
                    bindings: [.text(projectID)]
                )
            } else {
                rows = try connection.query(
                    """
                    SELECT id, project_id, runtime_adapter, runtime_name, runtime_version, observed_at,
                           parser_version, raw_output_hash, redacted_summary, capabilities_json
                    FROM observed_runtime_snapshots
                    ORDER BY observed_at ASC, id ASC
                    """
                )
            }
            return try rows.map(observedSnapshotRecord(from:))
        }
    }

    public func loadObservedServices(snapshotID: String) throws -> [ObservedServiceRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, snapshot_id, project_name, service_name, instance_name, resource_identifier,
                       image, lifecycle_state, health_state, ports_json, networks_json, mounts_json,
                       runtime_identifiers_json
                FROM observed_services
                WHERE snapshot_id = ?
                ORDER BY service_name ASC, instance_name ASC
                """,
                bindings: [.text(snapshotID)]
            )
            return try rows.map(observedServiceRecord(from:))
        }
    }

    private func observedServiceRecord(snapshotID: String, service: ObservedRuntimeService) throws -> ObservedServiceRecord {
        ObservedServiceRecord(
            id: "\(snapshotID):\(service.identity.displayName)",
            snapshotID: snapshotID,
            projectName: service.identity.projectName,
            serviceName: service.identity.serviceName,
            instanceName: service.identity.instanceName,
            resourceIdentifier: service.resourceIdentifier,
            image: service.image,
            lifecycleState: service.lifecycleState,
            healthState: service.healthState,
            portsJSON: try StateJSON.encode(service.ports.map(portJSON)),
            networksJSON: try StateJSON.encode(service.networks.map(networkJSON)),
            mountsJSON: try StateJSON.encode(service.mounts.map(mountJSON)),
            runtimeIdentifiersJSON: try StateJSON.encode([
                "displayName": service.identity.displayName,
                "observedAt": service.observedAt ?? ""
            ])
        )
    }

    private func insert(_ snapshot: ObservedRuntimeSnapshotRecord, projectID: String?, on connection: SQLiteConnection) throws {
        try connection.run(
            """
            INSERT INTO observed_runtime_snapshots (
                id, project_id, runtime_adapter, runtime_name, runtime_version, observed_at,
                parser_version, raw_output_hash, redacted_summary, capabilities_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(snapshot.id),
                optionalText(projectID),
                .text(snapshot.runtimeAdapter),
                .text(snapshot.runtimeName),
                optionalText(snapshot.runtimeVersion),
                .text(snapshot.observedAt),
                .text(snapshot.parserVersion),
                optionalText(snapshot.rawOutputHash),
                .text(snapshot.redactedSummary),
                .text(snapshot.capabilitiesJSON)
            ]
        )
    }

    private func insert(_ service: ObservedServiceRecord, on connection: SQLiteConnection) throws {
        try connection.run(
            """
            INSERT INTO observed_services (
                id, snapshot_id, project_name, service_name, instance_name, resource_identifier,
                image, lifecycle_state, health_state, ports_json, networks_json, mounts_json,
                runtime_identifiers_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(service.id),
                .text(service.snapshotID),
                .text(service.projectName),
                .text(service.serviceName),
                optionalText(service.instanceName),
                .text(service.resourceIdentifier),
                optionalText(service.image),
                .text(service.lifecycleState.rawValue),
                .text(service.healthState.rawValue),
                .text(service.portsJSON),
                .text(service.networksJSON),
                .text(service.mountsJSON),
                .text(service.runtimeIdentifiersJSON)
            ]
        )
    }
}

public struct EventLedger: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func append(_ events: [EventRecord]) throws {
        let redactedEvents = events.map { $0.redacted() }
        try store.withValidatedConnection { connection in
            try connection.transaction {
                for event in redactedEvents {
                    try connection.run(
                        """
                        INSERT INTO event_ledger (
                            id, timestamp, severity, type, source, project_id, service_name,
                            runtime_adapter, message, payload_json_redacted
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(event.id),
                            .text(event.timestamp),
                            .text(event.severity.rawValue),
                            .text(event.type),
                            .text(event.source),
                            optionalText(event.projectID),
                            optionalText(event.serviceName),
                            optionalText(event.runtimeAdapter),
                            .text(event.message),
                            .text(event.payloadJSONRedacted)
                        ]
                    )
                }
            }
        }
    }

    public func loadAll() throws -> [EventRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, timestamp, severity, type, source, project_id, service_name,
                       runtime_adapter, message, payload_json_redacted
                FROM event_ledger
                ORDER BY timestamp ASC, rowid ASC
                """
            )
            return try rows.map(eventRecord(from:))
        }
    }
}

public struct OperationLedger: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func record(_ operation: OperationRecord) throws {
        let redacted = operation.redacted()
        try store.withValidatedConnection { connection in
            try connection.transaction {
                try connection.run(
                    """
                    INSERT INTO operation_ledger (
                        id, created_at, updated_at, planned_action_type, project_id, service_name,
                        status, idempotency_key, plan_hash, payload_json_redacted
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(redacted.id),
                        .text(redacted.createdAt),
                        .text(redacted.updatedAt),
                        .text(redacted.plannedActionType),
                        optionalText(redacted.projectID),
                        optionalText(redacted.serviceName),
                        .text(redacted.status.rawValue),
                        .text(redacted.idempotencyKey),
                        .text(redacted.planHash),
                        .text(redacted.payloadJSONRedacted)
                    ]
                )
            }
        }
    }

    public func loadAll() throws -> [OperationRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, created_at, updated_at, planned_action_type, project_id, service_name,
                       status, idempotency_key, plan_hash, payload_json_redacted
                FROM operation_ledger
                ORDER BY created_at ASC, rowid ASC
                """
            )
            return try rows.map(operationRecord(from:))
        }
    }

    public func latest(idempotencyKey: String) throws -> OperationRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, created_at, updated_at, planned_action_type, project_id, service_name,
                       status, idempotency_key, plan_hash, payload_json_redacted
                FROM operation_ledger
                WHERE idempotency_key = ?
                ORDER BY updated_at DESC, created_at DESC, rowid DESC
                LIMIT 1
                """,
                bindings: [.text(idempotencyKey)]
            )
            return try rows.first.map(operationRecord(from:))
        }
    }
}

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
        let redactedHint = RuntimeRedactionPolicy.default.redact(manualRecoveryHintRedacted)
        let redactedMetadata = RuntimeRedactionPolicy.default.redact(metadataJSONRedacted)
        try store.withValidatedConnection { connection in
            try connection.transaction {
                try connection.run(
                    """
                    UPDATE operation_groups
                    SET status = ?, checkpoint = ?, lock_owner = NULL, lock_expires_at = NULL,
                        manual_recovery_hint_redacted = ?, updated_at = ?, metadata_json_redacted = ?
                    WHERE id = ?
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

    public func loadAll() throws -> [OperationGroupRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, operation_id, group_kind, project_id, service_name, planned_action_type,
                       status, group_idempotency_key, plan_hash, checkpoint, lock_owner, lock_expires_at,
                       rollback_available, manual_recovery_hint_redacted, created_at, updated_at,
                       metadata_json_redacted
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
                       metadata_json_redacted
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
                       metadata_json_redacted
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
                       metadata_json_redacted
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
                   metadata_json_redacted
            FROM operation_groups
            WHERE group_idempotency_key = ? AND status = 'active'
            ORDER BY updated_at DESC, created_at DESC, rowid DESC
            LIMIT 1
            """,
            bindings: [.text(groupIdempotencyKey)]
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
        let metadata = RuntimeRedactionPolicy.default.redact(
            #"{"expiredLock":"true","previousCheckpoint":"\#(group.checkpoint)","previousStatus":"\#(group.status.rawValue)"}"#
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
                metadata_json_redacted
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                .text(group.metadataJSONRedacted)
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

public struct HealthCheckResultRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func append(_ results: [HealthCheckResultRecord]) throws {
        let redactedResults = results.map { $0.redacted() }
        try store.withValidatedConnection { connection in
            try connection.transaction {
                for result in redactedResults {
                    try connection.run(
                        """
                        INSERT INTO health_check_results (
                            id, project_id, service_name, checked_at, status, exit_status, timed_out,
                            command_json_redacted, stdout_redacted, stderr_redacted, metadata_json_redacted
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(result.id),
                            optionalText(result.projectID),
                            .text(result.serviceName),
                            .text(result.checkedAt),
                            .text(result.status.rawValue),
                            optionalInt32(result.exitStatus),
                            .bool(result.timedOut),
                            .text(result.commandJSONRedacted),
                            .text(result.stdoutRedacted),
                            .text(result.stderrRedacted),
                            .text(result.metadataJSONRedacted)
                        ]
                    )
                }
            }
        }
    }

    public func loadAll() throws -> [HealthCheckResultRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, service_name, checked_at, status, exit_status, timed_out,
                       command_json_redacted, stdout_redacted, stderr_redacted, metadata_json_redacted
                FROM health_check_results
                ORDER BY checked_at ASC, rowid ASC
                """
            )
            return try rows.map(healthCheckResultRecord(from:))
        }
    }

    public func loadProject(projectID: String) throws -> [HealthCheckResultRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, service_name, checked_at, status, exit_status, timed_out,
                       command_json_redacted, stdout_redacted, stderr_redacted, metadata_json_redacted
                FROM health_check_results
                WHERE project_id = ?
                ORDER BY checked_at ASC, rowid ASC
                """,
                bindings: [.text(projectID)]
            )
            return try rows.map(healthCheckResultRecord(from:))
        }
    }

    public func latest(projectID: String, serviceName: String) throws -> HealthCheckResultRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, service_name, checked_at, status, exit_status, timed_out,
                       command_json_redacted, stdout_redacted, stderr_redacted, metadata_json_redacted
                FROM health_check_results
                WHERE project_id = ? AND service_name = ?
                ORDER BY checked_at DESC, rowid DESC
                LIMIT 1
                """,
                bindings: [.text(projectID), .text(serviceName)]
            )
            return try rows.first.map(healthCheckResultRecord(from:))
        }
    }
}

public struct RestartPolicyStateRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func upsert(_ state: RestartPolicyStateRecord) throws {
        let redacted = state.redacted()
        try store.withValidatedConnection { connection in
            try connection.transaction {
                try connection.run(
                    """
                    INSERT INTO restart_policy_state (
                        id, project_id, service_name, policy, status, attempt_count, max_attempts,
                        backoff_seconds, backoff_until, last_failure_at, updated_at, metadata_json_redacted
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(project_id, service_name) DO UPDATE SET
                        id = excluded.id,
                        policy = excluded.policy,
                        status = excluded.status,
                        attempt_count = excluded.attempt_count,
                        max_attempts = excluded.max_attempts,
                        backoff_seconds = excluded.backoff_seconds,
                        backoff_until = excluded.backoff_until,
                        last_failure_at = excluded.last_failure_at,
                        updated_at = excluded.updated_at,
                        metadata_json_redacted = excluded.metadata_json_redacted
                    """,
                    bindings: [
                        .text(redacted.id),
                        .text(redacted.projectID),
                        .text(redacted.serviceName),
                        .text(redacted.policy.rawValue),
                        .text(redacted.status.rawValue),
                        .int(redacted.attemptCount),
                        .int(redacted.maxAttempts),
                        .int(redacted.backoffSeconds),
                        optionalText(redacted.backoffUntil),
                        optionalText(redacted.lastFailureAt),
                        .text(redacted.updatedAt),
                        .text(redacted.metadataJSONRedacted)
                    ]
                )
            }
        }
    }

    public func load(projectID: String, serviceName: String) throws -> RestartPolicyStateRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, service_name, policy, status, attempt_count, max_attempts,
                       backoff_seconds, backoff_until, last_failure_at, updated_at, metadata_json_redacted
                FROM restart_policy_state
                WHERE project_id = ? AND service_name = ?
                LIMIT 1
                """,
                bindings: [.text(projectID), .text(serviceName)]
            )
            return try rows.first.map(restartPolicyStateRecord(from:))
        }
    }

    public func loadProject(projectID: String) throws -> [RestartPolicyStateRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, service_name, policy, status, attempt_count, max_attempts,
                       backoff_seconds, backoff_until, last_failure_at, updated_at, metadata_json_redacted
                FROM restart_policy_state
                WHERE project_id = ?
                ORDER BY service_name ASC
                """,
                bindings: [.text(projectID)]
            )
            return try rows.map(restartPolicyStateRecord(from:))
        }
    }

    public func loadAll() throws -> [RestartPolicyStateRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, service_name, policy, status, attempt_count, max_attempts,
                       backoff_seconds, backoff_until, last_failure_at, updated_at, metadata_json_redacted
                FROM restart_policy_state
                ORDER BY project_id ASC, service_name ASC
                """
            )
            return try rows.map(restartPolicyStateRecord(from:))
        }
    }
}

public struct RestartRecoveryRecordRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func append(_ record: RestartRecoveryRecord) throws {
        let redacted = record.redacted()
        try store.withValidatedConnection { connection in
            try connection.transaction {
                try connection.run(
                    """
                    INSERT INTO restart_recovery_records (
                        id, operation_id, project_id, service_name, resource_identifier, plan_hash,
                        status, completed_steps_json_redacted, manual_recovery_hint_redacted,
                        created_at, updated_at, metadata_json_redacted
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(redacted.id),
                        .text(redacted.operationID),
                        optionalText(redacted.projectID),
                        .text(redacted.serviceName),
                        .text(redacted.resourceIdentifier),
                        .text(redacted.planHash),
                        .text(redacted.status.rawValue),
                        .text(redacted.completedStepsJSONRedacted),
                        .text(redacted.manualRecoveryHintRedacted),
                        .text(redacted.createdAt),
                        .text(redacted.updatedAt),
                        .text(redacted.metadataJSONRedacted)
                    ]
                )
            }
        }
    }

    public func loadAll() throws -> [RestartRecoveryRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, operation_id, project_id, service_name, resource_identifier, plan_hash,
                       status, completed_steps_json_redacted, manual_recovery_hint_redacted,
                       created_at, updated_at, metadata_json_redacted
                FROM restart_recovery_records
                ORDER BY created_at ASC, rowid ASC
                """
            )
            return try rows.map(restartRecoveryRecord(from:))
        }
    }

    public func load(operationID: String) throws -> [RestartRecoveryRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, operation_id, project_id, service_name, resource_identifier, plan_hash,
                       status, completed_steps_json_redacted, manual_recovery_hint_redacted,
                       created_at, updated_at, metadata_json_redacted
                FROM restart_recovery_records
                WHERE operation_id = ?
                ORDER BY created_at ASC, rowid ASC
                """,
                bindings: [.text(operationID)]
            )
            return try rows.map(restartRecoveryRecord(from:))
        }
    }

    public func latest(operationID: String) throws -> RestartRecoveryRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, operation_id, project_id, service_name, resource_identifier, plan_hash,
                       status, completed_steps_json_redacted, manual_recovery_hint_redacted,
                       created_at, updated_at, metadata_json_redacted
                FROM restart_recovery_records
                WHERE operation_id = ?
                ORDER BY updated_at DESC, created_at DESC, rowid DESC
                LIMIT 1
                """,
                bindings: [.text(operationID)]
            )
            return try rows.first.map(restartRecoveryRecord(from:))
        }
    }
}

public struct OwnershipRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func upsert(_ ownership: OwnershipRecord) throws {
        let redacted = ownership.redacted()
        try store.withValidatedConnection { connection in
            try connection.transaction {
                try connection.run(
                    """
                    INSERT INTO ownership_records (
                        id, resource_identifier, resource_type, project_id, service_name, runtime_adapter,
                        created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(resource_identifier, runtime_adapter) DO UPDATE SET
                        resource_type = excluded.resource_type,
                        project_id = excluded.project_id,
                        service_name = excluded.service_name,
                        observed_at = excluded.observed_at,
                        cleanup_eligible = excluded.cleanup_eligible,
                        metadata_json_redacted = excluded.metadata_json_redacted,
                        identity_version = excluded.identity_version
                    """,
                    bindings: [
                        .text(redacted.id),
                        .text(redacted.resourceIdentifier),
                        .text(redacted.resourceType),
                        optionalText(redacted.projectID),
                        optionalText(redacted.serviceName),
                        .text(redacted.runtimeAdapter),
                        .text(redacted.createdAt),
                        .text(redacted.observedAt),
                        .bool(redacted.cleanupEligible),
                        .text(redacted.metadataJSONRedacted),
                        .int(redacted.identityVersion)
                    ]
                )
            }
        }
    }

    public func loadAll() throws -> [OwnershipRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, resource_identifier, resource_type, project_id, service_name, runtime_adapter,
                       created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version
                FROM ownership_records
                ORDER BY resource_identifier ASC, runtime_adapter ASC
                """
            )
            return try rows.map(ownershipRecord(from:))
        }
    }

    public func runtimeHints(projectID: String, projectName: String) throws -> [RuntimeOwnedResourceHint] {
        try loadAll().compactMap { record in
            guard record.resourceType == "container",
                  record.projectID == projectID,
                  record.runtimeAdapter == "AppleContainerApplyAdapter",
                  let serviceName = record.serviceName,
                  (record.identityVersion == 1 || record.identityVersion == RuntimeManagedResourceIdentity.currentVersion),
                  RuntimeManagedResourceIdentity.isSupportedIdentifier(record.resourceIdentifier) else {
                return nil
            }
            return RuntimeOwnedResourceHint(
                resourceIdentifier: record.resourceIdentifier,
                identity: RuntimeServiceIdentity(projectName: projectName, serviceName: serviceName),
                identityVersion: record.identityVersion
            )
        }.sorted { $0.resourceIdentifier < $1.resourceIdentifier }
    }

    public func markCleanupCompleted(
        resourceIdentifier: String,
        runtimeAdapter: String,
        observedAt: String,
        metadataJSONRedacted: String
    ) throws {
        let redactedMetadata = RuntimeRedactionPolicy.default.redact(metadataJSONRedacted)
        try store.withValidatedConnection { connection in
            try connection.transaction {
                try connection.run(
                    """
                    UPDATE ownership_records
                    SET observed_at = ?, cleanup_eligible = 0, metadata_json_redacted = ?
                    WHERE resource_identifier = ? AND runtime_adapter = ?
                    """,
                    bindings: [
                        .text(observedAt),
                        .text(redactedMetadata),
                        .text(resourceIdentifier),
                        .text(runtimeAdapter)
                    ]
                )
            }
        }
    }
}

private func projectRecord(from row: [String?]) throws -> StateProjectRecord {
    guard row.count == 6,
          let id = row[0],
          let name = row[1],
          let manifestHash = row[3],
          let createdAt = row[4],
          let updatedAt = row[5]
    else {
        throw StateStoreError.invalidRecord("Could not decode project row.")
    }

    return StateProjectRecord(
        id: id,
        name: name,
        manifestPath: row[2],
        manifestHash: manifestHash,
        createdAt: createdAt,
        updatedAt: updatedAt
    )
}

private func desiredServiceRecord(from row: [String?]) throws -> DesiredServiceRecord {
    guard row.count == 12,
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
          let createdAt = row[10],
          let updatedAt = row[11]
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
        updatedAt: updatedAt
    )
}

private func observedSnapshotRecord(from row: [String?]) throws -> ObservedRuntimeSnapshotRecord {
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

private func observedServiceRecord(from row: [String?]) throws -> ObservedServiceRecord {
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

private func eventRecord(from row: [String?]) throws -> EventRecord {
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

private func operationRecord(from row: [String?]) throws -> OperationRecord {
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

private func operationGroupRecord(from row: [String?]) throws -> OperationGroupRecord {
    guard row.count == 17,
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
          let metadataJSON = row[16]
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
        metadataJSONRedacted: metadataJSON
    )
}

private func operationGroupStepRecord(from row: [String?]) throws -> OperationGroupStepRecord {
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
          let metadataJSON = row[14]
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

private func healthCheckResultRecord(from row: [String?]) throws -> HealthCheckResultRecord {
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

private func restartPolicyStateRecord(from row: [String?]) throws -> RestartPolicyStateRecord {
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

private func restartRecoveryRecord(from row: [String?]) throws -> RestartRecoveryRecord {
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

private func ownershipRecord(from row: [String?]) throws -> OwnershipRecord {
    guard row.count == 11,
          let id = row[0],
          let resourceIdentifier = row[1],
          let resourceType = row[2],
          let runtimeAdapter = row[5],
          let createdAt = row[6],
          let observedAt = row[7],
          let cleanupEligibleText = row[8],
          let metadataJSON = row[9],
          let identityVersionText = row[10],
          let identityVersion = Int(identityVersionText)
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
        identityVersion: identityVersion
    )
}

private func optionalText(_ value: String?) -> SQLiteValue {
    value.map(SQLiteValue.text) ?? .null
}

private func optionalInt32(_ value: Int32?) -> SQLiteValue {
    value.map { SQLiteValue.int(Int($0)) } ?? .null
}

private func portJSON(_ port: RuntimePortMapping) -> [String: Any] {
    [
        "hostPort": port.hostPort.map { $0 as Any } ?? NSNull(),
        "containerPort": port.containerPort,
        "protocol": port.protocolName.rawValue,
        "bindAddress": port.bindAddress ?? NSNull()
    ]
}

private func networkJSON(_ network: RuntimeNetworkAttachment) -> [String: Any] {
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

private func mountJSON(_ mount: RuntimeMountReference) -> [String: Any] {
    [
        "source": mount.source,
        "target": mount.target,
        "access": mount.access.rawValue
    ]
}
