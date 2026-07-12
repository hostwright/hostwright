import HostwrightRuntime

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
