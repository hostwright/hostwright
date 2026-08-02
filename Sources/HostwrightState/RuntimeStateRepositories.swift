import Foundation
import HostwrightCore
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
            try saveRestartPolicyState(redacted, on: connection)
        }
    }

    public func recordAttempt(
        state: RestartPolicyStateRecord,
        history: RestartAttemptHistoryRecord
    ) throws {
        let redactedState = state.redacted()
        let redactedHistory = history.redacted()
        guard redactedState.projectID == redactedHistory.projectID,
              redactedState.serviceName == redactedHistory.serviceName,
              redactedState.policySHA256 == redactedHistory.policySHA256,
              redactedHistory.admitted else {
            throw StateStoreError.invalidRecord(
                "Restart attempt state and history require the same admitted workload policy identity."
            )
        }
        try store.withValidatedConnection { connection in
            try connection.transaction {
                try requireCurrentRestartReleaseGeneration(
                    redactedState,
                    on: connection
                )
                try saveRestartPolicyState(redactedState, on: connection)
                try insertRestartAttempt(redactedHistory, on: connection)
            }
        }
    }

    public func recordTransition(
        state: RestartPolicyStateRecord,
        history: RestartAttemptHistoryRecord
    ) throws {
        let redactedState = state.redacted()
        let redactedHistory = history.redacted()
        guard redactedState.projectID == redactedHistory.projectID,
              redactedState.serviceName == redactedHistory.serviceName,
              redactedState.policySHA256 == redactedHistory.policySHA256,
              !redactedHistory.admitted else {
            throw StateStoreError.invalidRecord(
                "Restart transition state and history require the same non-admitted workload policy identity."
            )
        }
        try store.withValidatedConnection { connection in
            try connection.transaction {
                try requireCurrentRestartReleaseGeneration(
                    redactedState,
                    on: connection
                )
                try saveRestartPolicyState(redactedState, on: connection)
                try insertRestartAttempt(redactedHistory, on: connection)
            }
        }
    }

    public func load(projectID: String, serviceName: String) throws -> RestartPolicyStateRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, service_name, policy, status, attempt_count, max_attempts,
                       backoff_seconds, backoff_until, last_failure_at, updated_at, metadata_json_redacted,
                       reason_class, window_started_at, window_seconds, initial_backoff_seconds,
                       maximum_backoff_seconds, jitter_seconds, stable_run_seconds, stable_since,
                       priority, project_max_attempts, project_window_seconds, hold_token,
                       release_generation, policy_sha256
                FROM restart_policy_state
                WHERE project_id = ? AND service_name = ?
                LIMIT 1
                """,
                bindings: [.text(projectID), .text(serviceName)]
            )
            return try rows.first.map(restartPolicyStateRecord(from:))
        }
    }

    public func releaseHold(
        projectID: String,
        serviceName: String,
        expectedHoldToken: String,
        timestamp: String,
        historyID: String,
        eventID: String? = nil
    ) throws -> RestartPolicyStateRecord? {
        guard expectedHoldToken.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              HostwrightResourceUUID.isValid(historyID),
              eventID.map(HostwrightResourceUUID.isValid) ?? true else {
            throw StateStoreError.invalidRecord(
                "Restart hold release requires an exact SHA-256 hold token and canonical evidence UUIDs."
            )
        }
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT id, project_id, service_name, policy, status, attempt_count, max_attempts,
                           backoff_seconds, backoff_until, last_failure_at, updated_at, metadata_json_redacted,
                           reason_class, window_started_at, window_seconds, initial_backoff_seconds,
                           maximum_backoff_seconds, jitter_seconds, stable_run_seconds, stable_since,
                           priority, project_max_attempts, project_window_seconds, hold_token,
                           release_generation, policy_sha256
                    FROM restart_policy_state
                    WHERE project_id = ? AND service_name = ? AND hold_token = ?
                      AND status IN ('crashLoopBlocked', 'operatorHold')
                    LIMIT 1
                    """,
                    bindings: [.text(projectID), .text(serviceName), .text(expectedHoldToken)]
                )
                guard let row = rows.first else { return nil }
                let current = try restartPolicyStateRecord(from: row)
                let generation = current.releaseGeneration + 1
                let updated = RestartPolicyStateRecord(
                    id: current.id,
                    projectID: current.projectID,
                    serviceName: current.serviceName,
                    policy: current.policy,
                    status: .active,
                    attemptCount: 0,
                    maxAttempts: current.maxAttempts,
                    backoffSeconds: current.initialBackoffSeconds,
                    backoffUntil: nil,
                    lastFailureAt: nil,
                    reasonClass: .operatorRequest,
                    windowStartedAt: nil,
                    windowSeconds: current.windowSeconds,
                    initialBackoffSeconds: current.initialBackoffSeconds,
                    maximumBackoffSeconds: current.maximumBackoffSeconds,
                    jitterSeconds: current.jitterSeconds,
                    stableRunSeconds: current.stableRunSeconds,
                    stableSince: nil,
                    priority: current.priority,
                    projectMaxAttempts: current.projectMaxAttempts,
                    projectWindowSeconds: current.projectWindowSeconds,
                    holdToken: nil,
                    releaseGeneration: generation,
                    policySHA256: current.policySHA256,
                    updatedAt: timestamp,
                    metadataJSONRedacted: "{\"releaseGeneration\":\(generation),\"status\":\"active\"}"
                )
                let history = RestartAttemptHistoryRecord(
                    id: historyID,
                    projectID: current.projectID,
                    serviceName: current.serviceName,
                    reasonClass: .operatorRequest,
                    decision: .manualRelease,
                    attemptNumber: current.attemptCount,
                    projectAttemptNumber: 0,
                    admitted: false,
                    holdToken: expectedHoldToken,
                    releaseGeneration: generation,
                    occurredAt: timestamp,
                    policySHA256: current.policySHA256,
                    metadataJSONRedacted: "{\"releaseGeneration\":\(generation),\"status\":\"manual-release\"}"
                )
                try saveRestartPolicyState(updated, on: connection)
                try insertRestartAttempt(history, on: connection)
                if let eventID {
                    try connection.run(
                        """
                        INSERT INTO event_ledger (
                            id, timestamp, severity, type, source, project_id, service_name,
                            runtime_adapter, message, payload_json_redacted
                        )
                        VALUES (?, ?, 'info', 'restart.policy.manual-release', 'hostwright-cli', ?, ?, NULL, ?, ?)
                        """,
                        bindings: [
                            .text(eventID),
                            .text(timestamp),
                            .text(projectID),
                            .text(serviceName),
                            .text("The exact confirmed restart hold was released without starting or restarting the workload."),
                            .text("{\"releaseGeneration\":\(generation),\"status\":\"manual-release\"}")
                        ]
                    )
                }
                return updated
            }
        }
    }

    public func loadProject(projectID: String) throws -> [RestartPolicyStateRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, service_name, policy, status, attempt_count, max_attempts,
                       backoff_seconds, backoff_until, last_failure_at, updated_at, metadata_json_redacted,
                       reason_class, window_started_at, window_seconds, initial_backoff_seconds,
                       maximum_backoff_seconds, jitter_seconds, stable_run_seconds, stable_since,
                       priority, project_max_attempts, project_window_seconds, hold_token,
                       release_generation, policy_sha256
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
                       backoff_seconds, backoff_until, last_failure_at, updated_at, metadata_json_redacted,
                       reason_class, window_started_at, window_seconds, initial_backoff_seconds,
                       maximum_backoff_seconds, jitter_seconds, stable_run_seconds, stable_since,
                       priority, project_max_attempts, project_window_seconds, hold_token,
                       release_generation, policy_sha256
                FROM restart_policy_state
                ORDER BY project_id ASC, service_name ASC
                """
            )
            return try rows.map(restartPolicyStateRecord(from:))
        }
    }
}

public struct RestartAttemptHistoryRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func append(_ record: RestartAttemptHistoryRecord) throws {
        let redacted = record.redacted()
        try store.withValidatedConnection { connection in
            try insertRestartAttempt(redacted, on: connection)
        }
    }

    public func loadProject(_ projectID: String, since: String? = nil) throws -> [RestartAttemptHistoryRecord] {
        try load(projectID: projectID, serviceName: nil, since: since)
    }

    public func loadWorkload(
        projectID: String,
        serviceName: String,
        since: String? = nil
    ) throws -> [RestartAttemptHistoryRecord] {
        try load(projectID: projectID, serviceName: serviceName, since: since)
    }

    public func admittedCount(
        projectID: String,
        serviceName: String? = nil,
        since: String
    ) throws -> Int {
        try store.withValidatedConnection(readOnly: true) { connection in
            let serviceClause = serviceName == nil ? "" : " AND service_name = ?"
            var bindings: [SQLiteValue] = [.text(projectID), .text(since)]
            if let serviceName { bindings.append(.text(serviceName)) }
            let rows = try connection.query(
                """
                SELECT COUNT(*) FROM restart_attempt_history
                WHERE project_id = ? AND admitted = 1 AND occurred_at >= ?\(serviceClause)
                """,
                bindings: bindings
            )
            guard let value = rows.first?.first ?? nil, let count = Int(value) else {
                throw StateStoreError.invalidRecord("Could not count restart attempt history.")
            }
            return count
        }
    }

    private func load(
        projectID: String,
        serviceName: String?,
        since: String?
    ) throws -> [RestartAttemptHistoryRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            var clauses = ["project_id = ?"]
            var bindings: [SQLiteValue] = [.text(projectID)]
            if let serviceName {
                clauses.append("service_name = ?")
                bindings.append(.text(serviceName))
            }
            if let since {
                clauses.append("occurred_at >= ?")
                bindings.append(.text(since))
            }
            let rows = try connection.query(
                """
                SELECT id, project_id, service_name, reason_class, decision, attempt_number,
                       project_attempt_number, admitted, hold_token, release_generation,
                       operation_id, occurred_at, backoff_until, policy_sha256,
                       metadata_json_redacted
                FROM restart_attempt_history
                WHERE \(clauses.joined(separator: " AND "))
                ORDER BY occurred_at ASC, id ASC
                """,
                bindings: bindings
            )
            return try rows.map(restartAttemptHistoryRecord(from:))
        }
    }
}

private func saveRestartPolicyState(
    _ state: RestartPolicyStateRecord,
    on connection: SQLiteConnection
) throws {
    try connection.run(
        """
        INSERT INTO restart_policy_state (
            id, project_id, service_name, policy, status, attempt_count, max_attempts,
            backoff_seconds, backoff_until, last_failure_at, updated_at, metadata_json_redacted,
            reason_class, window_started_at, window_seconds, initial_backoff_seconds,
            maximum_backoff_seconds, jitter_seconds, stable_run_seconds, stable_since,
            priority, project_max_attempts, project_window_seconds, hold_token,
            release_generation, policy_sha256
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(project_id, service_name) DO UPDATE SET
            id = excluded.id, policy = excluded.policy, status = excluded.status,
            attempt_count = excluded.attempt_count, max_attempts = excluded.max_attempts,
            backoff_seconds = excluded.backoff_seconds, backoff_until = excluded.backoff_until,
            last_failure_at = excluded.last_failure_at, reason_class = excluded.reason_class,
            window_started_at = excluded.window_started_at, window_seconds = excluded.window_seconds,
            initial_backoff_seconds = excluded.initial_backoff_seconds,
            maximum_backoff_seconds = excluded.maximum_backoff_seconds,
            jitter_seconds = excluded.jitter_seconds, stable_run_seconds = excluded.stable_run_seconds,
            stable_since = excluded.stable_since, priority = excluded.priority,
            project_max_attempts = excluded.project_max_attempts,
            project_window_seconds = excluded.project_window_seconds,
            hold_token = excluded.hold_token, release_generation = excluded.release_generation,
            policy_sha256 = excluded.policy_sha256, updated_at = excluded.updated_at,
            metadata_json_redacted = excluded.metadata_json_redacted
        """,
        bindings: [
            .text(state.id), .text(state.projectID), .text(state.serviceName),
            .text(state.policy.rawValue), .text(state.status.rawValue),
            .int(state.attemptCount), .int(state.maxAttempts), .int(state.backoffSeconds),
            optionalText(state.backoffUntil), optionalText(state.lastFailureAt),
            .text(state.updatedAt), .text(state.metadataJSONRedacted),
            .text(state.reasonClass.rawValue), optionalText(state.windowStartedAt),
            .int(state.windowSeconds), .int(state.initialBackoffSeconds),
            .int(state.maximumBackoffSeconds), .int(state.jitterSeconds),
            .int(state.stableRunSeconds), optionalText(state.stableSince), .int(state.priority),
            .int(state.projectMaxAttempts), .int(state.projectWindowSeconds),
            optionalText(state.holdToken), .int(state.releaseGeneration), .text(state.policySHA256)
        ]
    )
}

private func requireCurrentRestartReleaseGeneration(
    _ state: RestartPolicyStateRecord,
    on connection: SQLiteConnection
) throws {
    let rows = try connection.query(
        """
        SELECT release_generation
        FROM restart_policy_state
        WHERE project_id = ? AND service_name = ?
        LIMIT 1
        """,
        bindings: [.text(state.projectID), .text(state.serviceName)]
    )
    if rows.isEmpty, state.releaseGeneration == 0 { return }
    guard let value = rows.first?.first ?? nil,
          let releaseGeneration = Int(value),
          releaseGeneration == state.releaseGeneration else {
        throw StateStoreError.invalidRecord(
            "Restart state update was fenced by a newer manual release generation."
        )
    }
}

private func insertRestartAttempt(
    _ record: RestartAttemptHistoryRecord,
    on connection: SQLiteConnection
) throws {
    try connection.run(
        """
        INSERT INTO restart_attempt_history (
            id, project_id, service_name, reason_class, decision, attempt_number,
            project_attempt_number, admitted, hold_token, release_generation,
            operation_id, occurred_at, backoff_until, policy_sha256,
            metadata_json_redacted
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
            .text(record.id), .text(record.projectID), .text(record.serviceName),
            .text(record.reasonClass.rawValue), .text(record.decision.rawValue),
            .int(record.attemptNumber), .int(record.projectAttemptNumber),
            .bool(record.admitted), optionalText(record.holdToken),
            .int(record.releaseGeneration), optionalText(record.operationID),
            .text(record.occurredAt), optionalText(record.backoffUntil),
            .text(record.policySHA256), .text(record.metadataJSONRedacted)
        ]
    )
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
        guard HostwrightResourceUUID.isValid(redacted.resourceUUID),
              redacted.projectResourceUUID.map(HostwrightResourceUUID.isValid) ?? true,
              HostwrightResourceUUID.isValid(redacted.fencingToken),
              redacted.resourceGeneration > 0,
              redacted.projectGeneration >= 0,
              redacted.providerGeneration >= 0 else {
            throw StateStoreError.invalidRecord("Ownership identity, generation, or fencing fields are invalid.")
        }
        let incomingAuthority = try OwnershipAuthorityMetadata.decode(
            from: redacted.metadataJSONRedacted
        )
        try incomingAuthority?.validate(for: redacted)
        try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT id, resource_identifier, resource_type, project_id, service_name, runtime_adapter,
                           created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version,
                           resource_uuid, resource_generation, project_resource_uuid, project_generation,
                           provider_generation, fencing_token
                    FROM ownership_records
                    WHERE resource_identifier = ? AND runtime_adapter = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(redacted.resourceIdentifier),
                        .text(redacted.runtimeAdapter)
                    ]
                )
                if let existing = try rows.first.map(ownershipRecord(from:)) {
                    try validateTransition(
                        from: existing,
                        to: redacted,
                        incomingAuthority: incomingAuthority
                    )
                    try connection.run(
                        """
                        UPDATE ownership_records
                        SET observed_at = ?, cleanup_eligible = ?,
                            metadata_json_redacted = ?, resource_generation = ?,
                            project_generation = ?, provider_generation = ?
                        WHERE id = ? AND resource_identifier = ?
                          AND runtime_adapter = ? AND resource_uuid = ?
                          AND project_resource_uuid IS ? AND fencing_token = ?
                        """,
                        bindings: [
                            .text(redacted.observedAt),
                            .bool(redacted.cleanupEligible),
                            .text(redacted.metadataJSONRedacted),
                            .int(redacted.resourceGeneration),
                            .int(redacted.projectGeneration),
                            .int(redacted.providerGeneration),
                            .text(existing.id),
                            .text(existing.resourceIdentifier),
                            .text(existing.runtimeAdapter),
                            .text(existing.resourceUUID),
                            optionalText(existing.projectResourceUUID),
                            .text(existing.fencingToken)
                        ]
                    )
                } else {
                    try connection.run(
                        """
                        INSERT INTO ownership_records (
                            id, resource_identifier, resource_type, project_id, service_name, runtime_adapter,
                            created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version,
                            resource_uuid, resource_generation, project_resource_uuid, project_generation,
                            provider_generation, fencing_token
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                            .int(redacted.identityVersion),
                            .text(redacted.resourceUUID),
                            .int(redacted.resourceGeneration),
                            optionalText(redacted.projectResourceUUID),
                            .int(redacted.projectGeneration),
                            .int(redacted.providerGeneration),
                            .text(redacted.fencingToken)
                        ]
                    )
                }
            }
        }
    }

    private func validateTransition(
        from existing: OwnershipRecord,
        to incoming: OwnershipRecord,
        incomingAuthority: OwnershipAuthorityRecord?
    ) throws {
        let existingAuthority = try OwnershipAuthorityMetadata.decode(
            from: existing.metadataJSONRedacted
        )
        try existingAuthority?.validate(for: existing)
        guard incoming.id == existing.id,
              incoming.resourceIdentifier == existing.resourceIdentifier,
              incoming.resourceType == existing.resourceType,
              incoming.projectID == existing.projectID,
              incoming.serviceName == existing.serviceName,
              incoming.runtimeAdapter == existing.runtimeAdapter,
              incoming.createdAt == existing.createdAt,
              incoming.identityVersion == existing.identityVersion,
              incoming.resourceUUID == existing.resourceUUID,
              incoming.projectResourceUUID == existing.projectResourceUUID,
              incoming.fencingToken == existing.fencingToken,
              incoming.resourceGeneration >= existing.resourceGeneration,
              incoming.projectGeneration >= existing.projectGeneration,
              incoming.providerGeneration >= existing.providerGeneration,
              incoming.observedAt >= existing.observedAt,
              existing.cleanupEligible || !incoming.cleanupEligible else {
            throw StateStoreError.invalidRecord(
                "Ownership update lost its exact immutable identity, fence, generation ordering, or cleanup authority."
            )
        }
        switch (existingAuthority, incomingAuthority) {
        case (nil, nil), (nil, .some):
            return
        case (.some, nil):
            throw StateStoreError.invalidRecord(
                "Versioned ownership authority cannot be removed by an update."
            )
        case let (.some(previous), .some(next)):
            let beginsDeletion = previous.deletionTimestamp == nil &&
                next.deletionTimestamp != nil &&
                Set(previous.finalizers.map(\.state)) == [.active] &&
                Set(next.finalizers.map(\.state)) == [.releasing]
            let rebindsLiveLease = previous.deletionTimestamp == nil &&
                next.deletionTimestamp == nil &&
                Set(previous.finalizers.map(\.state)) == [.active] &&
                Set(next.finalizers.map(\.state)) == [.active]
            let changesOperation = previous.operationGroupID !=
                next.operationGroupID
            let changesLeaseAuthority =
                previous.leaseOwner != next.leaseOwner &&
                next.leaseOwner != nil
            let validAuthorityHandoff = changesOperation
                ? (beginsDeletion || rebindsLiveLease)
                : (changesLeaseAuthority
                    ? previous.deletionTimestamp == next.deletionTimestamp
                    : true)
            guard previous.controllerID == next.controllerID,
                  validAuthorityHandoff,
                  ((changesOperation || changesLeaseAuthority)
                    ?
                        next.handoffGeneration ==
                            previous.handoffGeneration + 1
                    : next.handoffGeneration ==
                        previous.handoffGeneration),
                  previous.deletionTimestamp == nil ||
                    previous.deletionTimestamp == next.deletionTimestamp,
                  finalizerTransition(
                      from: previous.finalizers,
                      to: next.finalizers
                  ) else {
                throw StateStoreError.invalidRecord(
                    "Ownership authority controller, operation, deletion, handoff, or finalizer transition is stale or invalid."
                )
            }
        }
    }

    private func finalizerTransition(
        from previous: [OwnershipFinalizerRecord],
        to next: [OwnershipFinalizerRecord]
    ) -> Bool {
        guard previous.map(\.name) == next.map(\.name) else { return false }
        let order: [OwnershipFinalizerState: Int] = [
            .active: 0,
            .releasing: 1,
            .released: 2,
            .quarantined: 2
        ]
        return zip(previous, next).allSatisfy {
            (order[$0.state] ?? -1) <= (order[$1.state] ?? -1)
        }
    }

    public func loadAll() throws -> [OwnershipRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, resource_identifier, resource_type, project_id, service_name, runtime_adapter,
                       created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version,
                       resource_uuid, resource_generation, project_resource_uuid, project_generation,
                       provider_generation, fencing_token
                FROM ownership_records
                ORDER BY resource_identifier ASC, runtime_adapter ASC
                """
            )
            return try rows.map(ownershipRecord(from:))
        }
    }

    public func advanceFencingToken(
        resourceIdentifier: String,
        runtimeAdapter: String,
        expectedResourceUUID: String,
        expectedFencingToken: String,
        newFencingToken: String,
        observedAt: String
    ) throws -> OwnershipRecord? {
        guard HostwrightResourceUUID.isValid(expectedResourceUUID),
              HostwrightResourceUUID.isValid(expectedFencingToken),
              HostwrightResourceUUID.isValid(newFencingToken),
              expectedFencingToken != newFencingToken else {
            throw StateStoreError.invalidRecord("Ownership fencing compare-and-swap requires valid distinct UUID tokens.")
        }
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let currentRows = try connection.query(
                    """
                    SELECT id, resource_identifier, resource_type, project_id, service_name, runtime_adapter,
                           created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version,
                           resource_uuid, resource_generation, project_resource_uuid, project_generation,
                           provider_generation, fencing_token
                    FROM ownership_records
                    WHERE resource_identifier = ? AND runtime_adapter = ?
                      AND resource_uuid = ? AND fencing_token = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(resourceIdentifier),
                        .text(runtimeAdapter),
                        .text(expectedResourceUUID.lowercased()),
                        .text(expectedFencingToken.lowercased())
                    ]
                )
                guard let current = try currentRows.first.map(
                    ownershipRecord(from:)
                ) else {
                    return nil
                }
                var metadataJSON = current.metadataJSONRedacted
                if let authority = try OwnershipAuthorityMetadata.decode(
                    from: metadataJSON
                ) {
                    try authority.validate(for: current)
                    let projected = OwnershipRecord(
                        id: current.id,
                        resourceIdentifier: current.resourceIdentifier,
                        resourceType: current.resourceType,
                        projectID: current.projectID,
                        serviceName: current.serviceName,
                        runtimeAdapter: current.runtimeAdapter,
                        createdAt: current.createdAt,
                        observedAt: observedAt,
                        cleanupEligible: current.cleanupEligible,
                        metadataJSONRedacted: current.metadataJSONRedacted,
                        identityVersion: current.identityVersion,
                        resourceUUID: current.resourceUUID,
                        resourceGeneration: current.resourceGeneration,
                        projectResourceUUID: current.projectResourceUUID,
                        projectGeneration: current.projectGeneration,
                        providerGeneration: current.providerGeneration,
                        fencingToken: newFencingToken.lowercased()
                    )
                    let rebound = OwnershipAuthorityRecord(
                        controllerID: authority.controllerID,
                        providerID: authority.providerID,
                        ownershipProofSHA256:
                            OwnershipAuthorityRecord.proofSHA256(
                                ownership: projected,
                                controllerID: authority.controllerID,
                                providerID: authority.providerID,
                                fencingToken: newFencingToken.lowercased()
                            ),
                        resourceUUID: authority.resourceUUID,
                        resourceGeneration: authority.resourceGeneration,
                        projectResourceUUID: authority.projectResourceUUID,
                        projectGeneration: authority.projectGeneration,
                        providerGeneration: authority.providerGeneration,
                        fencingToken: newFencingToken.lowercased(),
                        finalizers: authority.finalizers,
                        deletionTimestamp: authority.deletionTimestamp,
                        operationGroupID: authority.operationGroupID,
                        leaseOwner: authority.leaseOwner,
                        leaseExpiresAt: authority.leaseExpiresAt,
                        handoffGeneration: authority.handoffGeneration
                    )
                    try rebound.validate(for: projected)
                    metadataJSON = try OwnershipAuthorityMetadata.encode(
                        rebound,
                        into: metadataJSON
                    )
                }
                try connection.run(
                    """
                    UPDATE ownership_records
                    SET fencing_token = ?, observed_at = ?,
                        metadata_json_redacted = ?
                    WHERE resource_identifier = ?
                      AND runtime_adapter = ?
                      AND resource_uuid = ?
                      AND fencing_token = ?
                    """,
                    bindings: [
                        .text(newFencingToken.lowercased()),
                        .text(observedAt),
                        .text(metadataJSON),
                        .text(resourceIdentifier),
                        .text(runtimeAdapter),
                        .text(expectedResourceUUID.lowercased()),
                        .text(expectedFencingToken.lowercased())
                    ]
                )
                let rows = try connection.query(
                    """
                    SELECT id, resource_identifier, resource_type, project_id, service_name, runtime_adapter,
                           created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version,
                           resource_uuid, resource_generation, project_resource_uuid, project_generation,
                           provider_generation, fencing_token
                    FROM ownership_records
                    WHERE resource_identifier = ? AND runtime_adapter = ? AND resource_uuid = ? AND fencing_token = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(resourceIdentifier),
                        .text(runtimeAdapter),
                        .text(expectedResourceUUID.lowercased()),
                        .text(newFencingToken.lowercased())
                    ]
                )
                return try rows.first.map(ownershipRecord(from:))
            }
        }
    }

    public func runtimeHints(
        projectID: String,
        projectName: String,
        providerID: RuntimeProviderID = .appleContainerCLI
    ) throws -> [RuntimeOwnedResourceHint] {
        try loadAll().compactMap { record in
            guard record.resourceType == "container",
                  record.projectID == projectID,
                  RuntimeProviderBinding.stableID(for: record.runtimeAdapter) == providerID,
                  let serviceName = record.serviceName,
                  let projectResourceUUID = record.projectResourceUUID,
                  HostwrightResourceUUID.isValid(record.resourceUUID),
                  HostwrightResourceUUID.isValid(projectResourceUUID),
                  HostwrightResourceUUID.isValid(record.fencingToken),
                  record.resourceGeneration > 0,
                  record.projectGeneration > 0,
                  record.providerGeneration > 0,
                  let identity = runtimeHintIdentity(
                      for: record,
                      projectName: projectName,
                      serviceName: serviceName
                  ) else {
                return nil
            }
            return RuntimeOwnedResourceHint(
                resourceIdentifier: record.resourceIdentifier,
                identity: identity,
                identityVersion: record.identityVersion,
                ownership: RuntimeInventoryOwnershipEvidence(
                    resourceUUID: record.resourceUUID,
                    projectUUID: projectResourceUUID,
                    resourceGeneration: record.resourceGeneration,
                    projectGeneration: record.projectGeneration,
                    providerID: providerID,
                    providerGeneration: record.providerGeneration,
                    fencingToken: record.fencingToken
                )
            )
        }.sorted { $0.resourceIdentifier < $1.resourceIdentifier }
    }

    private func runtimeHintIdentity(
        for record: OwnershipRecord,
        projectName: String,
        serviceName: String
    ) -> RuntimeServiceIdentity? {
        let primaryIdentity = RuntimeServiceIdentity(
            projectName: projectName,
            serviceName: serviceName
        )
        if record.identityVersion == 1 {
            return record.resourceIdentifier == primaryIdentity.legacyManagedResourceIdentifier
                ? primaryIdentity
                : nil
        }
        guard record.identityVersion == RuntimeManagedResourceIdentity.currentVersion else {
            return nil
        }

        if let metadata = lifecycleIdentityMetadata(from: record.metadataJSONRedacted),
           metadata.schemaVersion == 1,
           metadata.projectName == projectName,
           metadata.serviceName == serviceName {
            let recordedIdentity = RuntimeServiceIdentity(
                projectName: metadata.projectName,
                serviceName: metadata.serviceName,
                instanceName: metadata.instanceName
            )
            guard record.resourceIdentifier == recordedIdentity.managedResourceIdentifier else {
                return nil
            }
            return recordedIdentity
        }

        return record.resourceIdentifier == primaryIdentity.managedResourceIdentifier
            ? primaryIdentity
            : nil
    }

    private func lifecycleIdentityMetadata(
        from metadataJSONRedacted: String
    ) -> OwnershipLifecycleIdentityMetadata? {
        guard metadataJSONRedacted.utf8.count <= 1_048_576,
              let data = metadataJSONRedacted.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(
            OwnershipLifecycleIdentityMetadata.self,
            from: data
        )
    }

    public func markCleanupCompleted(
        resourceIdentifier: String,
        runtimeAdapter: String,
        expectedResourceUUID: String,
        expectedFencingToken: String,
        expectedOperationGroupID: String,
        expectedLeaseOwner: String,
        expectedLeaseExpiresAt: String,
        observedAt: String
    ) throws -> OwnershipRecord {
        guard HostwrightResourceUUID.isValid(expectedResourceUUID),
              HostwrightResourceUUID.isValid(expectedFencingToken),
              HostwrightResourceUUID.isValid(expectedOperationGroupID),
              !expectedLeaseOwner.isEmpty,
              !expectedLeaseExpiresAt.isEmpty,
              let current = try loadAll().first(where: {
                  $0.resourceIdentifier == resourceIdentifier &&
                      $0.runtimeAdapter == runtimeAdapter &&
                      $0.resourceUUID == expectedResourceUUID.lowercased() &&
                      $0.fencingToken == expectedFencingToken.lowercased()
              }),
              let authority = try OwnershipAuthorityMetadata.decode(
                  from: current.metadataJSONRedacted
              ) else {
            throw StateStoreError.invalidRecord(
                "Cleanup finalization requires exact versioned ownership, UUID, fence, and operation identity."
            )
        }
        try authority.validate(for: current)
        guard authority.operationGroupID == expectedOperationGroupID.lowercased(),
              authority.leaseOwner == expectedLeaseOwner,
              authority.leaseExpiresAt == expectedLeaseExpiresAt,
              authority.deletionTimestamp != nil,
              Set(authority.finalizers.map(\.state)) == [.releasing] else {
            throw StateStoreError.invalidRecord(
                "Cleanup finalization requires the exact releasing ownership finalizers."
            )
        }
        let released = OwnershipAuthorityRecord(
            controllerID: authority.controllerID,
            providerID: authority.providerID,
            ownershipProofSHA256: authority.ownershipProofSHA256,
            resourceUUID: authority.resourceUUID,
            resourceGeneration: authority.resourceGeneration,
            projectResourceUUID: authority.projectResourceUUID,
            projectGeneration: authority.projectGeneration,
            providerGeneration: authority.providerGeneration,
            fencingToken: authority.fencingToken,
            finalizers: authority.finalizers.map {
                OwnershipFinalizerRecord(name: $0.name, state: .released)
            },
            deletionTimestamp: authority.deletionTimestamp,
            operationGroupID: authority.operationGroupID,
            leaseOwner: nil,
            leaseExpiresAt: nil,
            handoffGeneration: authority.handoffGeneration
        )
        try released.validate(for: current)
        let metadata = try OwnershipAuthorityMetadata.encode(
            released,
            into: current.metadataJSONRedacted
        )
        let updated = OwnershipRecord(
            id: current.id,
            resourceIdentifier: current.resourceIdentifier,
            resourceType: current.resourceType,
            projectID: current.projectID,
            serviceName: current.serviceName,
            runtimeAdapter: current.runtimeAdapter,
            createdAt: current.createdAt,
            observedAt: observedAt,
            cleanupEligible: false,
            metadataJSONRedacted: metadata,
            identityVersion: current.identityVersion,
            resourceUUID: current.resourceUUID,
            resourceGeneration: current.resourceGeneration,
            projectResourceUUID: current.projectResourceUUID,
            projectGeneration: current.projectGeneration,
            providerGeneration: current.providerGeneration,
            fencingToken: current.fencingToken
        )
        try store.withValidatedConnection { connection in
            try connection.transaction {
                let groups = try connection.query(
                    """
                    SELECT status, fencing_token, lock_owner, lock_expires_at
                    FROM operation_groups
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(expectedOperationGroupID.lowercased())]
                )
                guard groups.count == 1,
                      groups[0][0] == OperationGroupStatus.active.rawValue,
                      groups[0][1] == expectedFencingToken.lowercased(),
                      groups[0][2] == expectedLeaseOwner,
                      groups[0][3] == expectedLeaseExpiresAt else {
                    throw StateStoreError.invalidRecord(
                        "Cleanup finalization lost the exact active operation lease."
                    )
                }
                let matches = try connection.query(
                    """
                    SELECT id FROM ownership_records
                    WHERE id = ? AND resource_identifier = ?
                      AND runtime_adapter = ? AND resource_uuid = ?
                      AND fencing_token = ? AND metadata_json_redacted = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(current.id),
                        .text(current.resourceIdentifier),
                        .text(current.runtimeAdapter),
                        .text(current.resourceUUID),
                        .text(current.fencingToken),
                        .text(current.metadataJSONRedacted)
                    ]
                )
                guard matches.count == 1 else {
                    throw StateStoreError.invalidRecord(
                        "Cleanup finalization lost its exact ownership compare-and-swap."
                    )
                }
                try connection.run(
                    """
                    UPDATE ownership_records
                    SET observed_at = ?, cleanup_eligible = 0,
                        metadata_json_redacted = ?
                    WHERE id = ? AND resource_identifier = ?
                      AND runtime_adapter = ? AND resource_uuid = ?
                      AND fencing_token = ? AND metadata_json_redacted = ?
                    """,
                    bindings: [
                        .text(observedAt),
                        .text(metadata),
                        .text(current.id),
                        .text(current.resourceIdentifier),
                        .text(current.runtimeAdapter),
                        .text(current.resourceUUID),
                        .text(current.fencingToken),
                        .text(current.metadataJSONRedacted)
                    ]
                )
                try connection.run(
                    """
                    DELETE FROM ownership_records
                    WHERE id = ? AND resource_identifier = ?
                      AND runtime_adapter = ? AND resource_uuid = ?
                      AND fencing_token = ? AND cleanup_eligible = 0
                      AND metadata_json_redacted = ?
                    """,
                    bindings: [
                        .text(current.id),
                        .text(current.resourceIdentifier),
                        .text(current.runtimeAdapter),
                        .text(current.resourceUUID),
                        .text(current.fencingToken),
                        .text(metadata)
                    ]
                )
                let remaining = try connection.query(
                    "SELECT id FROM ownership_records WHERE id = ? LIMIT 1",
                    bindings: [.text(current.id)]
                )
                guard remaining.isEmpty else {
                    throw StateStoreError.invalidRecord(
                        "Cleanup finalizer could not remove the exact released ownership row."
                    )
                }
            }
        }
        return updated
    }

    public func releaseMutationLease(
        resourceIdentifier: String,
        runtimeAdapter: String,
        expectedResourceUUID: String,
        expectedFencingToken: String,
        expectedOperationGroupID: String,
        expectedLeaseOwner: String,
        expectedLeaseExpiresAt: String,
        observedAt: String
    ) throws {
        guard HostwrightResourceUUID.isValid(expectedResourceUUID),
              HostwrightResourceUUID.isValid(expectedFencingToken),
              HostwrightResourceUUID.isValid(expectedOperationGroupID),
              !expectedLeaseOwner.isEmpty,
              !expectedLeaseExpiresAt.isEmpty else {
            throw StateStoreError.invalidRecord(
                "Ownership lease release requires exact UUID, fence, group, owner, and expiry."
            )
        }
        try store.withValidatedConnection { connection in
            try connection.transaction {
                let groups = try connection.query(
                    """
                    SELECT status, fencing_token, lock_owner, lock_expires_at
                    FROM operation_groups
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(expectedOperationGroupID.lowercased())]
                )
                guard groups.count == 1,
                      groups[0][0] == OperationGroupStatus.active.rawValue,
                      groups[0][1] == expectedFencingToken.lowercased(),
                      groups[0][2] == expectedLeaseOwner,
                      groups[0][3] == expectedLeaseExpiresAt else {
                    throw StateStoreError.invalidRecord(
                        "Ownership lease release lost the exact active operation lease."
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
                    WHERE resource_identifier = ? AND runtime_adapter = ?
                      AND resource_uuid = ? AND fencing_token = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(resourceIdentifier),
                        .text(runtimeAdapter),
                        .text(expectedResourceUUID.lowercased()),
                        .text(expectedFencingToken.lowercased())
                    ]
                )
                guard let ownership = try rows.first.map(
                    ownershipRecord(from:)
                ), let authority = try OwnershipAuthorityMetadata.decode(
                    from: ownership.metadataJSONRedacted
                ) else {
                    throw StateStoreError.invalidRecord(
                        "Ownership lease release requires exact versioned authority."
                    )
                }
                try authority.validate(for: ownership)
                guard authority.operationGroupID ==
                        expectedOperationGroupID.lowercased(),
                      authority.leaseOwner == expectedLeaseOwner,
                      authority.leaseExpiresAt == expectedLeaseExpiresAt,
                      authority.deletionTimestamp == nil,
                      Set(authority.finalizers.map(\.state)) == [.active] else {
                    throw StateStoreError.invalidRecord(
                        "Ownership lease release found stale or deleting authority."
                    )
                }
                let released = OwnershipAuthorityRecord(
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
                    deletionTimestamp: nil,
                    operationGroupID: authority.operationGroupID,
                    leaseOwner: nil,
                    leaseExpiresAt: nil,
                    handoffGeneration: authority.handoffGeneration
                )
                try released.validate(for: ownership)
                let metadata = try OwnershipAuthorityMetadata.encode(
                    released,
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
                        .text(observedAt),
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
                        "Ownership lease release lost its exact compare-and-swap."
                    )
                }
            }
        }
    }

    public func removeExact(
        resourceIdentifier: String,
        runtimeAdapter: String,
        expectedResourceUUID: String,
        expectedFencingToken: String
    ) throws -> Bool {
        guard HostwrightResourceUUID.isValid(expectedResourceUUID),
              HostwrightResourceUUID.isValid(expectedFencingToken) else {
            throw StateStoreError.invalidRecord(
                "Ownership removal requires exact valid resource and fencing UUIDs."
            )
        }
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let matches = try connection.query(
                    """
                    SELECT id, resource_identifier, resource_type, project_id, service_name, runtime_adapter,
                           created_at, observed_at, cleanup_eligible, metadata_json_redacted, identity_version,
                           resource_uuid, resource_generation, project_resource_uuid, project_generation,
                           provider_generation, fencing_token
                    FROM ownership_records
                    WHERE resource_identifier = ?
                      AND runtime_adapter = ?
                      AND resource_uuid = ?
                      AND fencing_token = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(resourceIdentifier),
                        .text(runtimeAdapter),
                        .text(expectedResourceUUID.lowercased()),
                        .text(expectedFencingToken.lowercased())
                    ]
                )
                guard let record = try matches.first.map(
                    ownershipRecord(from:)
                ),
                let authority = try OwnershipAuthorityMetadata.decode(
                    from: record.metadataJSONRedacted
                ) else {
                    return false
                }
                try authority.validate(for: record)
                guard authority.deletionTimestamp != nil,
                      Set(authority.finalizers.map(\.state)) == [.released],
                      authority.leaseOwner == nil,
                      authority.leaseExpiresAt == nil else {
                    return false
                }
                try connection.run(
                    """
                    DELETE FROM ownership_records
                    WHERE resource_identifier = ?
                      AND runtime_adapter = ?
                      AND resource_uuid = ?
                      AND fencing_token = ?
                    """,
                    bindings: [
                        .text(resourceIdentifier),
                        .text(runtimeAdapter),
                        .text(expectedResourceUUID.lowercased()),
                        .text(expectedFencingToken.lowercased())
                    ]
                )
                return true
            }
        }
    }
}

private struct OwnershipLifecycleIdentityMetadata: Decodable {
    let schemaVersion: Int
    let projectName: String
    let serviceName: String
    let instanceName: String?
}
