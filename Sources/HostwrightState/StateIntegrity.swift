import Foundation
import HostwrightCore

public struct StateIntegrityService: Sendable {
    public let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func inspect() -> StateIntegrityReport {
        var fingerprint: StateFileFingerprint?
        do {
            return try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
                fingerprint = try StateMaintenanceFileSupport.fingerprint(connection.path)
                return try inspect(
                    connection: connection,
                    fingerprint: fingerprint
                )
            }
        } catch {
            return StateIntegrityReport(
                health: .unrecoverable,
                databaseSHA256: fingerprint?.sha256,
                databaseBytes: fingerprint?.bytes,
                stateSchemaVersion: nil,
                checks: [
                    StateIntegrityCheck(
                        identifier: "state.open",
                        status: .failed,
                        message: String(describing: error)
                    )
                ],
                repairableProjectionTables: [],
                recommendedAction: "Restore a verified backup or run state recovery if a maintenance journal is pending."
            )
        }
    }

    func inspect(
        connection: SQLiteConnection,
        fingerprint: StateFileFingerprint? = nil
    ) throws -> StateIntegrityReport {
        let currentFingerprint = try fingerprint ?? StateMaintenanceFileSupport.fingerprint(connection.path)
        var checks: [StateIntegrityCheck] = []
        var unrecoverable = false
        var repairableTables = Set<String>()

        let integrityRows = try connection.query("PRAGMA integrity_check(100)")
            .compactMap { $0.first ?? nil }
        if integrityRows == ["ok"] {
            checks.append(.init(identifier: "sqlite.integrity", status: .passed, message: "SQLite integrity_check returned ok."))
        } else {
            unrecoverable = true
            checks.append(.init(
                identifier: "sqlite.integrity",
                status: .failed,
                message: integrityRows.prefix(10).joined(separator: "; "),
                affectedRows: integrityRows.count
            ))
        }

        let foreignKeyRows = try connection.query("PRAGMA foreign_key_check")
        if foreignKeyRows.isEmpty {
            checks.append(.init(identifier: "sqlite.foreign-keys", status: .passed, message: "No foreign-key violations were found."))
        } else {
            unrecoverable = true
            checks.append(.init(
                identifier: "sqlite.foreign-keys",
                status: .failed,
                message: "Foreign-key violations affect authoritative or projection relationships.",
                affectedRows: foreignKeyRows.count
            ))
        }

        var stateSchemaVersion: Int?
        do {
            try MigrationRunner().validateAppliedSchema(on: connection)
            stateSchemaVersion = try connection.query("SELECT MAX(version) FROM schema_migrations")
                .first?.first.flatMap { $0 }.flatMap(Int.init)
            checks.append(.init(identifier: "hostwright.migrations", status: .passed, message: "Migration ledger and checksums match state schema v\(stateSchemaVersion ?? 0)."))
        } catch {
            unrecoverable = true
            checks.append(.init(identifier: "hostwright.migrations", status: .failed, message: String(describing: error)))
        }

        let presentTables = Set(
            try connection.query(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            ).compactMap { $0.first ?? nil }
        )
        let missingTables = Self.requiredTables.filter { !presentTables.contains($0) }
        let presentIndexes = Set(
            try connection.query(
                "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'"
            ).compactMap { $0.first ?? nil }
        )
        let missingIndexes = Self.requiredIndexes.filter { !presentIndexes.contains($0) }
        if missingTables.isEmpty, missingIndexes.isEmpty {
            checks.append(.init(
                identifier: "hostwright.schema-objects",
                status: .passed,
                message: "All required state tables and indexes are present."
            ))
        } else {
            unrecoverable = true
            let missing = (missingTables.map { "table:\($0)" }
                + missingIndexes.map { "index:\($0)" }).joined(separator: ", ")
            checks.append(.init(
                identifier: "hostwright.schema-objects",
                status: .failed,
                message: "Missing required schema object(s): \(missing).",
                affectedRows: missingTables.count + missingIndexes.count
            ))
        }

        if missingTables.isEmpty, missingIndexes.isEmpty {
            let sqlAuthoritativeProblems = try count(
                connection,
                sql: """
                SELECT
                    (SELECT COUNT(*) FROM projects
                     WHERE id = '' OR name = '' OR manifest_hash = '' OR created_at = '' OR updated_at = ''
                        OR resource_uuid IS NULL OR resource_uuid = '' OR manifest_version < 1
                        OR provider_generation < 0
                        OR (mutation_provider IS NOT NULL AND mutation_provider = ''))
                  + (SELECT COUNT(*) FROM desired_services
                     WHERE id = '' OR project_id = '' OR service_name = '' OR image = ''
                        OR manifest_hash = '' OR created_at = '' OR updated_at = ''
                        OR json_type(CASE WHEN json_valid(command_json) THEN command_json ELSE 'null' END) != 'array'
                        OR json_type(CASE WHEN json_valid(ports_json) THEN ports_json ELSE 'null' END) != 'array'
                        OR json_type(CASE WHEN json_valid(mounts_json) THEN mounts_json ELSE 'null' END) != 'array'
                        OR json_type(CASE WHEN json_valid(env_json_redacted) THEN env_json_redacted ELSE 'null' END) != 'object'
                        OR desired_generation < 1 OR resource_uuid IS NULL OR resource_uuid = ''
                        OR resource_generation < 1
                        OR (mutation_provider IS NOT NULL AND mutation_provider = ''))
                  + (SELECT COUNT(*) FROM event_ledger
                     WHERE id = '' OR timestamp = '' OR type = '' OR source = '' OR message = ''
                        OR severity NOT IN ('info', 'warning', 'error')
                        OR json_type(CASE WHEN json_valid(payload_json_redacted) THEN payload_json_redacted ELSE 'null' END) != 'object')
                  + (SELECT COUNT(*) FROM operation_ledger
                     WHERE id = '' OR created_at = '' OR updated_at = '' OR planned_action_type = ''
                        OR status NOT IN ('planned', 'recorded', 'succeeded', 'failed', 'abandoned')
                        OR idempotency_key = '' OR plan_hash = ''
                        OR json_type(CASE WHEN json_valid(payload_json_redacted) THEN payload_json_redacted ELSE 'null' END) != 'object')
                  + (SELECT COUNT(*) FROM ownership_records
                     WHERE id = '' OR resource_identifier = '' OR resource_type = '' OR runtime_adapter = ''
                        OR created_at = '' OR observed_at = '' OR cleanup_eligible NOT IN (0, 1)
                        OR identity_version < 1 OR resource_uuid IS NULL OR resource_uuid = ''
                        OR resource_generation < 1 OR project_generation < 0 OR provider_generation < 0
                        OR fencing_token = ''
                        OR json_type(CASE WHEN json_valid(metadata_json_redacted) THEN metadata_json_redacted ELSE 'null' END) != 'object')
                  + (SELECT COUNT(*) FROM restart_policy_state
                     WHERE id = '' OR project_id = '' OR service_name = '' OR updated_at = ''
                        OR policy NOT IN ('no', 'onFailure', 'unlessStopped')
                        OR status NOT IN ('active', 'backingOff', 'operatorHold', 'manualDisabled', 'crashLoopBlocked')
                        OR attempt_count < 0 OR max_attempts < 1 OR backoff_seconds < 1
                        OR json_type(CASE WHEN json_valid(metadata_json_redacted) THEN metadata_json_redacted ELSE 'null' END) != 'object')
                  + (SELECT COUNT(*) FROM restart_recovery_records
                     WHERE id = '' OR operation_id = '' OR service_name = '' OR resource_identifier = ''
                        OR plan_hash = '' OR created_at = '' OR updated_at = ''
                        OR status NOT IN ('prepared', 'stopSucceeded', 'succeeded', 'failed')
                        OR json_type(CASE WHEN json_valid(completed_steps_json_redacted) THEN completed_steps_json_redacted ELSE 'null' END) != 'array'
                        OR json_type(CASE WHEN json_valid(metadata_json_redacted) THEN metadata_json_redacted ELSE 'null' END) != 'object')
                  + (SELECT COUNT(*) FROM operation_groups
                     WHERE id = '' OR operation_id = '' OR group_kind = '' OR planned_action_type = ''
                        OR status NOT IN ('active', 'succeeded', 'failed', 'interrupted')
                        OR group_idempotency_key = '' OR plan_hash = '' OR checkpoint = ''
                        OR rollback_available NOT IN (0, 1) OR created_at = '' OR updated_at = ''
                        OR fencing_token = ''
                        OR (lock_owner IS NULL) != (lock_expires_at IS NULL)
                        OR (project_id IS NOT NULL AND NOT EXISTS (
                            SELECT 1 FROM projects WHERE projects.id = operation_groups.project_id
                        ))
                        OR json_type(CASE WHEN json_valid(metadata_json_redacted) THEN metadata_json_redacted ELSE 'null' END) != 'object'
                        OR json_type(CASE WHEN json_valid(intent_json_redacted) THEN intent_json_redacted ELSE 'null' END) != 'object'
                        OR json_type(CASE WHEN json_valid(compensation_json_redacted) THEN compensation_json_redacted ELSE 'null' END) != 'array'
                        OR json_type(CASE WHEN json_valid(verification_json_redacted) THEN verification_json_redacted ELSE 'null' END) != 'object')
                  + (SELECT COUNT(*) FROM operation_group_steps
                     WHERE id = '' OR group_id = '' OR step_key = '' OR planned_action_type = ''
                        OR direction NOT IN ('forward', 'rollback')
                        OR status NOT IN ('planned', 'started', 'succeeded', 'failed', 'unsupported')
                        OR step_idempotency_key = '' OR updated_at = ''
                        OR NOT EXISTS (
                            SELECT 1 FROM operation_groups WHERE operation_groups.id = operation_group_steps.group_id
                        )
                        OR json_type(CASE WHEN json_valid(metadata_json_redacted) THEN metadata_json_redacted ELSE 'null' END) != 'object')
                """
            )
            let invalidIdentityProblems = try invalidIdentityCount(connection)
            let authoritativeProblems = sqlAuthoritativeProblems + invalidIdentityProblems
            if authoritativeProblems == 0 {
                checks.append(.init(identifier: "hostwright.authoritative-records", status: .passed, message: "Authoritative state records satisfy the v7 logical contract."))
            } else {
                unrecoverable = true
                checks.append(.init(
                    identifier: "hostwright.authoritative-records",
                    status: .failed,
                    message: "Authoritative state contains invalid identities, generations, statuses, or JSON. Automatic repair is forbidden.",
                    affectedRows: authoritativeProblems
                ))
            }

            let observedSnapshotProblems = try count(
                connection,
                sql: """
                SELECT COUNT(*) FROM observed_runtime_snapshots
                WHERE id = '' OR runtime_adapter = '' OR runtime_name = '' OR observed_at = ''
                   OR parser_version = '' OR redacted_summary = ''
                   OR json_type(CASE WHEN json_valid(capabilities_json) THEN capabilities_json ELSE 'null' END) != 'array'
                """
            )
            let observedServiceProblems = try count(
                connection,
                sql: """
                SELECT COUNT(*) FROM observed_services
                WHERE id = '' OR snapshot_id = '' OR project_name = '' OR service_name = ''
                   OR resource_identifier = ''
                   OR lifecycle_state NOT IN ('unknown', 'missing', 'created', 'running', 'stopped', 'exited', 'failed')
                   OR health_state NOT IN ('unknown', 'notConfigured', 'starting', 'healthy', 'unhealthy')
                   OR json_type(CASE WHEN json_valid(ports_json) THEN ports_json ELSE 'null' END) != 'array'
                   OR json_type(CASE WHEN json_valid(networks_json) THEN networks_json ELSE 'null' END) != 'array'
                   OR json_type(CASE WHEN json_valid(mounts_json) THEN mounts_json ELSE 'null' END) != 'array'
                   OR json_type(CASE WHEN json_valid(runtime_identifiers_json) THEN runtime_identifiers_json ELSE 'null' END) != 'object'
                """
            )
            let observedProblems = observedSnapshotProblems + observedServiceProblems
            if observedProblems == 0 {
                checks.append(.init(identifier: "hostwright.observed-projection", status: .passed, message: "Observed runtime projections satisfy the logical contract."))
            } else {
                repairableTables.formUnion(["observed_services", "observed_runtime_snapshots"])
                checks.append(.init(
                    identifier: "hostwright.observed-projection",
                    status: .warning,
                    message: "Observed runtime projections are invalid and can be reconstructed from the runtime.",
                    affectedRows: observedProblems
                ))
            }

            let healthProblems = try count(
                connection,
                sql: """
                SELECT COUNT(*) FROM health_check_results
                WHERE id = '' OR service_name = '' OR checked_at = ''
                   OR status NOT IN ('notConfigured', 'skipped', 'healthy', 'unhealthy', 'unknown')
                   OR timed_out NOT IN (0, 1)
                   OR json_type(CASE WHEN json_valid(command_json_redacted) THEN command_json_redacted ELSE 'null' END) != 'array'
                   OR json_type(CASE WHEN json_valid(metadata_json_redacted) THEN metadata_json_redacted ELSE 'null' END) != 'object'
                """
            )
            if healthProblems == 0 {
                checks.append(.init(identifier: "hostwright.health-projection", status: .passed, message: "Health-result projections satisfy the logical contract."))
            } else {
                repairableTables.insert("health_check_results")
                checks.append(.init(
                    identifier: "hostwright.health-projection",
                    status: .warning,
                    message: "Health-result projections are invalid and can be reconstructed by health checks.",
                    affectedRows: healthProblems
                ))
            }
        }

        let health: StateIntegrityHealth
        let action: String
        if unrecoverable {
            health = .unrecoverable
            action = "Restore a verified backup. Hostwright will not invent or delete authoritative state."
        } else if repairableTables.isEmpty {
            health = .healthy
            action = "No action is required."
        } else {
            health = .degraded
            action = "Run 'hostwright state repair --dry-run', inspect the exact projection rows, then confirm the bound token."
        }

        return StateIntegrityReport(
            health: health,
            databaseSHA256: currentFingerprint.sha256,
            databaseBytes: currentFingerprint.bytes,
            stateSchemaVersion: stateSchemaVersion,
            checks: checks,
            repairableProjectionTables: repairableTables.sorted(),
            recommendedAction: action
        )
    }

    private func count(_ connection: SQLiteConnection, sql: String) throws -> Int {
        guard let value = try connection.query(sql).first?.first ?? nil,
              let count = Int(value) else {
            throw StateMaintenanceError.sqlite(message: "logical integrity query did not return an integer count")
        }
        return count
    }

    private func invalidIdentityCount(_ connection: SQLiteConnection) throws -> Int {
        let identities = try connection.query(
            """
            SELECT resource_uuid FROM projects
            UNION ALL SELECT resource_uuid FROM desired_services
            UNION ALL SELECT resource_uuid FROM ownership_records
            UNION ALL SELECT project_resource_uuid FROM ownership_records
                      WHERE project_resource_uuid IS NOT NULL
            UNION ALL SELECT fencing_token FROM ownership_records
            UNION ALL SELECT fencing_token FROM operation_groups
            """
        ).compactMap { $0.first ?? nil }
        return identities.filter { !HostwrightResourceUUID.isValid($0) }.count
    }

    private static let requiredTables = [
        "schema_migrations",
        "projects",
        "desired_services",
        "observed_runtime_snapshots",
        "observed_services",
        "event_ledger",
        "operation_ledger",
        "ownership_records",
        "health_check_results",
        "restart_policy_state",
        "restart_recovery_records",
        "operation_groups",
        "operation_group_steps"
    ]

    private static let requiredIndexes = [
        "desired_services_project_idx",
        "observed_services_snapshot_idx",
        "event_ledger_timestamp_idx",
        "operation_ledger_project_idx",
        "ownership_records_project_idx",
        "health_check_results_project_idx",
        "health_check_results_checked_at_idx",
        "restart_policy_state_project_idx",
        "restart_recovery_operation_idx",
        "restart_recovery_project_idx",
        "operation_groups_operation_idx",
        "operation_groups_project_idx",
        "operation_groups_idempotency_idx",
        "operation_groups_active_idempotency_idx",
        "operation_groups_lock_idx",
        "operation_group_steps_group_idx",
        "operation_group_steps_idempotency_idx",
        "projects_resource_uuid_idx",
        "desired_services_resource_uuid_idx",
        "ownership_resource_uuid_idx",
        "ownership_project_resource_uuid_idx",
        "operation_groups_fencing_token_idx"
    ]
}
