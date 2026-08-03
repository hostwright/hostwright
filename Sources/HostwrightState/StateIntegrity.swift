import CryptoKit
import Foundation
import HostwrightControlPlane
import HostwrightCore
import HostwrightRegistry

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

    public func inspectNonMutating() throws -> StateIntegrityReport {
        try store.configuration.validateExistingPath()
        return try StateAccessCoordinator(configuration: store.configuration)
            .withExistingSharedLockIfPresent {
                let expectedIdentity = try store.configuration.validateSQLiteFileSet()
                guard expectedIdentity != nil else {
                    throw StateStoreError.openFailed(
                        path: store.path,
                        message: "the selected state database does not exist"
                    )
                }
                let pathManager = SecureStatePathManager()
                try pathManager.validateCheckpointedSQLiteFileSetForNonMutatingRead(store.path)
                let connection = try SQLiteConnection(
                    path: store.path,
                    createIfNeeded: false,
                    readOnly: true,
                    profile: .nonMutatingInspection
                )
                defer { try? connection.close() }
                let openedIdentity = try store.configuration.validateSQLiteFileSet()
                guard expectedIdentity == openedIdentity else {
                    throw StateStoreError.pathPolicyViolation(
                        path: store.path,
                        message: "the state database identity changed while doctor was opening it"
                    )
                }
                let fingerprint = try StateMaintenanceFileSupport.fingerprint(connection.path)
                let report = try inspect(
                    connection: connection,
                    fingerprint: fingerprint
                )
                try connection.close()
                try pathManager.validateCheckpointedSQLiteFileSetForNonMutatingRead(store.path)
                let finalIdentity = try store.configuration.validateSQLiteFileSet()
                let finalFingerprint = try StateMaintenanceFileSupport.fingerprint(store.path)
                guard expectedIdentity == finalIdentity, fingerprint == finalFingerprint else {
                    throw StateStoreError.databaseLocked(
                        path: store.path,
                        message: "state changed during immutable doctor inspection; retry after active state operations finish"
                    )
                }
                return report
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

        let policy = try connection.policyReport()
        let policyMessage: String
        if policy.usesLegacyJournalMode {
            policyMessage = "SQLite \(policy.libraryVersion) uses a compatible legacy journal; the next state-writing migration upgrades it to WAL with FULL synchronization."
        } else if policy.profile == .portableArtifact {
            policyMessage = "SQLite \(policy.libraryVersion) verifies this sidecar-free portable artifact with DELETE/EXTRA durability and macOS full-fsync barriers."
        } else if policy.profile == .nonMutatingInspection {
            policyMessage = "SQLite \(policy.libraryVersion) verifies a checkpointed immutable state snapshot without creating or changing SQLite coordination artifacts."
        } else {
            policyMessage = "SQLite \(policy.libraryVersion) enforces NOFOLLOW, defensive and untrusted-schema modes, bounded waits, private in-memory temporary storage, WAL/FULL durability, and macOS full-fsync barriers."
        }
        checks.append(.init(
            identifier: "sqlite.connection-policy",
            status: policy.usesLegacyJournalMode ? .warning : .passed,
            message: policyMessage
        ))

        let applicationID = try MigrationRunner().applicationIdentity(on: connection)
        if applicationID == MigrationRunner.applicationID {
            checks.append(.init(
                identifier: "hostwright.application-identity",
                status: .passed,
                message: "SQLite application_id is bound to Hostwright ownership."
            ))
        } else if applicationID == 0 {
            checks.append(.init(
                identifier: "hostwright.application-identity",
                status: .warning,
                message: "Legacy unclaimed state is compatible; the next explicit migration records Hostwright ownership."
            ))
        } else {
            unrecoverable = true
            checks.append(.init(
                identifier: "hostwright.application-identity",
                status: .failed,
                message: "SQLite application_id belongs to another application."
            ))
        }

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
        let presentTriggers = Set(
            try connection.query(
                "SELECT name FROM sqlite_master WHERE type = 'trigger'"
            ).compactMap { $0.first ?? nil }
        )
        let missingTriggers = Self.requiredTriggers.filter { !presentTriggers.contains($0) }
        if missingTables.isEmpty, missingIndexes.isEmpty, missingTriggers.isEmpty {
            checks.append(.init(
                identifier: "hostwright.schema-objects",
                status: .passed,
                message: "All required state tables, indexes, and triggers are present."
            ))
        } else {
            unrecoverable = true
            let missing = (missingTables.map { "table:\($0)" }
                + missingIndexes.map { "index:\($0)" }
                + missingTriggers.map { "trigger:\($0)" }).joined(separator: ", ")
            checks.append(.init(
                identifier: "hostwright.schema-objects",
                status: .failed,
                message: "Missing required schema object(s): \(missing).",
                affectedRows: missingTables.count + missingIndexes.count + missingTriggers.count
            ))
        }

        if missingTables.isEmpty, missingIndexes.isEmpty, missingTriggers.isEmpty {
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
                        OR status NOT IN ('active', 'backingOff', 'operatorHold', 'manualDisabled', 'crashLoopBlocked', 'projectBudgetBlocked', 'stablePending')
                        OR attempt_count < 0 OR max_attempts < 1 OR backoff_seconds < 1
                        OR reason_class NOT IN ('process-exit', 'health-failure', 'runtime-failure', 'dependency-failure', 'operator-request', 'unknown')
                        OR window_seconds NOT BETWEEN 1 AND 86400
                        OR initial_backoff_seconds NOT BETWEEN 1 AND 3600
                        OR maximum_backoff_seconds NOT BETWEEN initial_backoff_seconds AND 86400
                        OR jitter_seconds NOT BETWEEN 0 AND initial_backoff_seconds
                        OR stable_run_seconds NOT BETWEEN 1 AND 86400
                        OR priority NOT BETWEEN -100 AND 100
                        OR project_max_attempts NOT BETWEEN 1 AND 1000
                        OR project_window_seconds NOT BETWEEN 1 AND 86400
                        OR release_generation < 0
                        OR length(policy_sha256) != 64 OR policy_sha256 GLOB '*[^0-9a-f]*'
                        OR (hold_token IS NOT NULL AND (length(hold_token) != 64 OR hold_token GLOB '*[^0-9a-f]*'))
                        OR json_type(CASE WHEN json_valid(metadata_json_redacted) THEN metadata_json_redacted ELSE 'null' END) != 'object')
                  + (SELECT COUNT(*) FROM restart_attempt_history
                     WHERE id = '' OR project_id = '' OR service_name = ''
                        OR reason_class NOT IN ('process-exit', 'health-failure', 'runtime-failure', 'dependency-failure', 'operator-request', 'unknown')
                        OR decision NOT IN ('admitted', 'denied', 'hold', 'stable-reset', 'manual-release', 'failed')
                        OR attempt_number < 0 OR project_attempt_number < 0
                        OR admitted NOT IN (0, 1) OR release_generation < 0
                        OR occurred_at = '' OR julianday(occurred_at) IS NULL
                        OR length(policy_sha256) != 64 OR policy_sha256 GLOB '*[^0-9a-f]*'
                        OR (hold_token IS NOT NULL AND (length(hold_token) != 64 OR hold_token GLOB '*[^0-9a-f]*'))
                        OR json_type(CASE WHEN json_valid(metadata_json_redacted) THEN metadata_json_redacted ELSE 'null' END) != 'object')
                  + (SELECT COUNT(*) FROM peer_identities
                     WHERE subject_id = '' OR user_id < 0 OR signing_identifier = '' OR generation < 1
                        OR length(code_directory_hash) NOT IN (40, 64)
                        OR code_directory_hash GLOB '*[^0-9a-f]*'
                        OR validation_mode NOT IN ('installedRequirement', 'pinnedAdHoc')
                        OR (validation_mode = 'installedRequirement' AND team_identifier IS NULL)
                        OR (validation_mode = 'pinnedAdHoc' AND team_identifier IS NOT NULL)
                        OR (credential_id IS NULL) != (credential_public_key_base64 IS NULL)
                        OR julianday(declared_at) IS NULL OR julianday(updated_at) IS NULL)
                  + (SELECT COUNT(*) FROM control_sessions
                     WHERE session_id = '' OR subject_id = '' OR daemon_generation < 1
                        OR length(server_nonce_sha256) != 64 OR server_nonce_sha256 GLOB '*[^0-9a-f]*'
                        OR socket_device < 0 OR socket_inode < 1 OR euid < 0 OR egid < 0
                        OR pid < 1 OR pid_version < 0 OR audit_session_id < 0
                        OR length(code_directory_hash) NOT IN (40, 64)
                        OR code_directory_hash GLOB '*[^0-9a-f]*'
                        OR julianday(created_at) IS NULL OR julianday(expires_at) IS NULL
                        OR julianday(expires_at) <= julianday(created_at) OR julianday(updated_at) IS NULL)
                  + (SELECT COUNT(*) FROM identity_revocations
                     WHERE revocation_id = '' OR target_identifier = '' OR reason = ''
                        OR target_kind NOT IN ('subject', 'credential', 'codeHash', 'session')
                        OR (target_kind = 'codeHash' AND (length(target_identifier) NOT IN (40, 64) OR target_identifier GLOB '*[^0-9a-f]*'))
                        OR actor_subject_id = '' OR julianday(revoked_at) IS NULL)
                  + (SELECT COUNT(*) FROM control_requests
                     WHERE request_id = '' OR subject_id = ''
                        OR length(request_digest_sha256) != 64 OR request_digest_sha256 GLOB '*[^0-9a-f]*'
                        OR status NOT IN ('accepted', 'completed', 'rejected', 'error')
                        OR julianday(created_at) IS NULL OR julianday(updated_at) IS NULL)
                  + (SELECT COUNT(*) FROM idempotency_records
                     WHERE subject_id = '' OR idempotency_key = '' OR request_id = ''
                        OR length(request_digest_sha256) != 64 OR request_digest_sha256 GLOB '*[^0-9a-f]*'
                        OR status NOT IN ('accepted', 'completed', 'rejected', 'error')
                        OR julianday(created_at) IS NULL OR julianday(expires_at) IS NULL
                        OR julianday(expires_at) <= julianday(created_at))
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
                  + (SELECT COUNT(*) FROM image_digest_locks
                     WHERE id = '' OR project_id = '' OR resource_uuid = ''
                        OR service_name = '' OR replica_index < 0
                        OR state_kind NOT IN ('desired', 'observed')
                        OR lock_schema_version != 1
                        OR requested_reference = '' OR resolved_reference = ''
                        OR length(descriptor_digest) != 71
                        OR substr(descriptor_digest, 1, 7) != 'sha256:'
                        OR substr(descriptor_digest, 8) GLOB '*[^0-9a-f]*'
                        OR length(variant_digest) != 71
                        OR substr(variant_digest, 1, 7) != 'sha256:'
                        OR substr(variant_digest, 8) GLOB '*[^0-9a-f]*'
                        OR operating_system != 'linux'
                        OR architecture NOT IN ('arm64', 'amd64')
                        OR runtime_provider NOT IN ('apple-container-cli', 'apple-containerization')
                        OR provider_generation < 1
                        OR length(capability_sha256) != 64
                        OR capability_sha256 GLOB '*[^0-9a-f]*'
                        OR length(plan_hash) != 64
                        OR plan_hash GLOB '*[^0-9a-f]*'
                        OR operation_group_id = '' OR created_at = '' OR updated_at = ''
                        OR (state_kind = 'desired' AND observation_sha256 IS NOT NULL)
                        OR (state_kind = 'observed' AND (
                            observation_sha256 IS NULL
                            OR length(observation_sha256) != 64
                            OR observation_sha256 GLOB '*[^0-9a-f]*'
                        )))
                  + (SELECT COUNT(*) FROM oci_referrer_discoveries
                     WHERE id = '' OR registry_endpoint = ''
                        OR repository = '' OR subject_digest = ''
                        OR discovery_mode NOT IN (
                            'native', 'tag-fallback',
                            'tag-fallback-empty', 'generated'
                        )
                        OR server_filter_applied NOT IN (0, 1)
                        OR page_count < 1 OR page_count > 16
                        OR descriptor_count < 0
                        OR descriptor_count > 512
                        OR length(graph_sha256) != 64
                        OR graph_sha256 GLOB '*[^0-9a-f]*'
                        OR complete != 1 OR observed_at = '')
                  + (SELECT COUNT(*) FROM oci_referrers
                     WHERE id = '' OR discovery_id = ''
                        OR registry_endpoint = '' OR repository = ''
                        OR subject_digest = '' OR referrer_digest = ''
                        OR media_type = '' OR size_bytes < 0
                        OR size_bytes > 8388608
                        OR verified_subject != 1 OR observed_at = ''
                        OR json_type(CASE
                            WHEN json_valid(annotations_json)
                            THEN annotations_json ELSE 'null'
                        END) != 'object')
                  + (SELECT COUNT(*) FROM oci_referrer_cache_objects
                     WHERE digest = '' OR media_type = ''
                        OR size_bytes < 0 OR size_bytes > 8388608
                        OR object_kind NOT IN ('manifest', 'index', 'blob')
                        OR length(payload_sha256) != 64
                        OR payload_sha256 GLOB '*[^0-9a-f]*'
                        OR created_at = '' OR last_accessed_at = ''
                        OR json_type(CASE
                            WHEN json_valid(children_json)
                            THEN children_json ELSE 'null'
                        END) != 'array')
                  + (SELECT COUNT(*) FROM oci_referrer_graph_objects
                     WHERE discovery_id = '' OR referrer_digest = ''
                        OR object_digest = ''
                        OR NOT EXISTS (
                            SELECT 1 FROM oci_referrers
                            WHERE oci_referrers.discovery_id =
                                oci_referrer_graph_objects.discovery_id
                              AND oci_referrers.referrer_digest =
                                oci_referrer_graph_objects.referrer_digest
                        ))
                  + (SELECT COUNT(*) FROM oci_referrer_retention_leases
                     WHERE id = '' OR discovery_id = ''
                        OR owner_id = '' OR fencing_token = ''
                        OR acquired_at = '' OR expires_at = ''
                        OR expires_at <= acquired_at
                        OR (released_at IS NOT NULL
                            AND released_at = ''))
                  + (SELECT COUNT(*) FROM oci_referrer_publications
                     WHERE id = '' OR registry_endpoint = ''
                        OR repository = '' OR subject_digest = ''
                        OR referrer_digest = ''
                        OR length(ownership_proof_sha256) != 64
                        OR ownership_proof_sha256 GLOB '*[^0-9a-f]*'
                        OR operation_group_id = ''
                        OR cleanup_eligible NOT IN (0, 1)
                        OR created_at = '' OR observed_at = ''
                        OR NOT EXISTS (
                            SELECT 1 FROM operation_groups
                            WHERE operation_groups.id =
                                oci_referrer_publications.operation_group_id
                        ))
                  + (SELECT COUNT(*) FROM image_trust_exceptions
                     WHERE id = '' OR project_id = '' OR service_name = ''
                        OR length(descriptor_digest) != 71
                        OR substr(descriptor_digest, 1, 7) != 'sha256:'
                        OR substr(descriptor_digest, 8) GLOB '*[^0-9a-f]*'
                        OR length(policy_sha256) != 64
                        OR policy_sha256 GLOB '*[^0-9a-f]*'
                        OR reason = '' OR approver = ''
                        OR approved_at = '' OR expires_at = ''
                        OR expires_at <= approved_at
                        OR (revoked_at IS NOT NULL AND (
                            revoked_at = '' OR revoked_at < approved_at
                        ))
                        OR idempotency_key = '')
                  + (SELECT COUNT(*) FROM image_trust_verifications
                     WHERE project_id = '' OR service_name = ''
                        OR length(descriptor_digest) != 71
                        OR substr(descriptor_digest, 1, 7) != 'sha256:'
                        OR substr(descriptor_digest, 8) GLOB '*[^0-9a-f]*'
                        OR length(policy_sha256) != 64
                        OR policy_sha256 GLOB '*[^0-9a-f]*'
                        OR length(evidence_graph_sha256) != 64
                        OR evidence_graph_sha256 GLOB '*[^0-9a-f]*'
                        OR evidence_discovery_id = ''
                        OR length(trusted_root_sha256) != 64
                        OR trusted_root_sha256 GLOB '*[^0-9a-f]*'
                        OR verifier_version = ''
                        OR json_type(CASE
                            WHEN json_valid(matched_authority_ids_json)
                            THEN matched_authority_ids_json ELSE 'null'
                        END) != 'array'
                        OR threshold < 1 OR threshold > 8
                        OR outcome = '' OR operation_group_id = ''
                        OR created_at = ''
                        OR (exception_id IS NOT NULL AND exception_id = ''))
                  + (SELECT COUNT(*) FROM image_trust_subject_manifests
                     WHERE id = '' OR registry_endpoint = ''
                        OR repository = ''
                        OR length(descriptor_digest) != 71
                        OR substr(descriptor_digest, 1, 7) != 'sha256:'
                        OR substr(descriptor_digest, 8) GLOB '*[^0-9a-f]*'
                        OR size_bytes < 1 OR size_bytes > 1048576
                        OR payload_base64 = ''
                        OR length(payload_sha256) != 64
                        OR payload_sha256 GLOB '*[^0-9a-f]*'
                        OR observed_at = '')
                  + (SELECT COUNT(*) FROM image_sbom_records
                     WHERE id = '' OR project_id = '' OR service_name = ''
                        OR length(descriptor_digest) != 71
                        OR substr(descriptor_digest, 1, 7) != 'sha256:'
                        OR substr(descriptor_digest, 8) GLOB '*[^0-9a-f]*'
                        OR length(policy_sha256) != 64
                        OR policy_sha256 GLOB '*[^0-9a-f]*'
                        OR format NOT IN ('spdx-json', 'cyclonedx-json')
                        OR document_digest = ''
                        OR document_media_type = ''
                        OR evidence_discovery_id = ''
                        OR length(evidence_graph_sha256) != 64
                        OR evidence_graph_sha256 GLOB '*[^0-9a-f]*'
                        OR sbom_referrer_digest = ''
                        OR ((provenance_descriptor_digest IS NULL) != (provenance_referrer_digest IS NULL))
                        OR (provenance_descriptor_digest IS NOT NULL AND provenance_descriptor_digest = '')
                        OR (provenance_referrer_digest IS NOT NULL AND provenance_referrer_digest = '')
                        OR component_count < 0 OR component_count > 1000000
                        OR length(normalized_components_sha256) != 64
                        OR normalized_components_sha256 GLOB '*[^0-9a-f]*'
                        OR operation_group_id = '' OR created_at = '')
                  + (SELECT COUNT(*) FROM image_provenance_records
                     WHERE id = '' OR project_id = ''
                        OR service_name = ''
                        OR descriptor_digest = ''
                        OR policy_sha256 = ''
                        OR statement_digest = ''
                        OR envelope_digest = ''
                        OR referrer_digest = ''
                        OR evidence_discovery_id = ''
                        OR evidence_graph_sha256 = ''
                        OR source_uri = '' OR source_digest = ''
                        OR builder_id = '' OR builder_version = ''
                        OR build_type = '' OR invocation_id = ''
                        OR normalized_materials_sha256 = ''
                        OR command_sha256 = ''
                        OR environment_policy_sha256 = ''
                        OR started_at = '' OR finished_at = ''
                        OR reproducibility_status NOT IN (
                            'verified', 'not-verified'
                        )
                        OR (
                            reproducibility_status = 'verified'
                            AND comparison_digest IS NULL
                        )
                        OR (
                            reproducibility_status = 'not-verified'
                            AND comparison_digest IS NOT NULL
                        )
                        OR signer_id = ''
                        OR signer_public_key_sha256 = ''
                        OR signature_sha256 = ''
                        OR verifier_version = ''
                        OR verified_at = ''
                        OR operation_group_id = ''
                        OR created_at = '')
                  + (SELECT COUNT(*) FROM content_cache_objects
                     WHERE length(provider_scope) < 1
                        OR length(provider_scope) > 256
                        OR provider_scope GLOB '*[^A-Za-z0-9._:/-]*'
                        OR substr(provider_scope, 1, 1)
                            GLOB '[^A-Za-z0-9]'
                        OR length(digest) != 71
                        OR substr(digest, 1, 7) != 'sha256:'
                        OR substr(digest, 8) GLOB '*[^0-9a-f]*'
                        OR content_kind NOT IN (
                            'runtime-image', 'oci-cache-object'
                        )
                        OR size_bytes < 0
                        OR size_bytes > 1099511627776
                        OR pin_policy NOT IN (
                            'unpinned', 'operator', 'policy'
                        )
                        OR created_at = '' OR observed_at = ''
                        OR last_used_at = ''
                        OR julianday(created_at) IS NULL
                        OR julianday(observed_at) IS NULL
                        OR julianday(last_used_at) IS NULL
                        OR julianday(observed_at) < julianday(created_at)
                        OR julianday(last_used_at) < julianday(created_at))
                  + (SELECT COUNT(*) FROM content_cache_references
                     WHERE length(id) != 36
                        OR substr(id, 9, 1) != '-'
                        OR substr(id, 14, 1) != '-'
                        OR substr(id, 19, 1) != '-'
                        OR substr(id, 24, 1) != '-'
                        OR replace(id, '-', '') GLOB '*[^0-9a-f]*'
                        OR length(provider_scope) < 1
                        OR length(provider_scope) > 256
                        OR provider_scope GLOB '*[^A-Za-z0-9._:/-]*'
                        OR substr(provider_scope, 1, 1)
                            GLOB '[^A-Za-z0-9]'
                        OR length(reference) < 1
                        OR length(reference) > 1024
                        OR length(digest) != 71
                        OR substr(digest, 1, 7) != 'sha256:'
                        OR substr(digest, 8) GLOB '*[^0-9a-f]*'
                        OR length(ownership_operation_id) != 36
                        OR substr(ownership_operation_id, 9, 1) != '-'
                        OR substr(ownership_operation_id, 14, 1) != '-'
                        OR substr(ownership_operation_id, 19, 1) != '-'
                        OR substr(ownership_operation_id, 24, 1) != '-'
                        OR replace(
                            ownership_operation_id, '-', ''
                        ) GLOB '*[^0-9a-f]*'
                        OR length(ownership_proof_sha256) != 64
                        OR ownership_proof_sha256
                            GLOB '*[^0-9a-f]*'
                        OR created_at = '' OR observed_at = ''
                        OR julianday(created_at) IS NULL
                        OR julianday(observed_at) IS NULL
                        OR julianday(observed_at) < julianday(created_at)
                        OR NOT EXISTS (
                            SELECT 1 FROM content_cache_objects
                            WHERE content_cache_objects.provider_scope =
                                content_cache_references.provider_scope
                              AND content_cache_objects.digest =
                                content_cache_references.digest
                        ))
                  + (SELECT COUNT(*) FROM content_cache_leases AS lease
                     WHERE length(lease.id) != 36
                        OR substr(lease.id, 9, 1) != '-'
                        OR substr(lease.id, 14, 1) != '-'
                        OR substr(lease.id, 19, 1) != '-'
                        OR substr(lease.id, 24, 1) != '-'
                        OR replace(lease.id, '-', '')
                            GLOB '*[^0-9a-f]*'
                        OR length(lease.provider_scope) < 1
                        OR length(lease.provider_scope) > 256
                        OR lease.provider_scope
                            GLOB '*[^A-Za-z0-9._:/-]*'
                        OR substr(lease.provider_scope, 1, 1)
                            GLOB '[^A-Za-z0-9]'
                        OR length(lease.digest) != 71
                        OR substr(lease.digest, 1, 7) != 'sha256:'
                        OR substr(lease.digest, 8)
                            GLOB '*[^0-9a-f]*'
                        OR (
                            lease.reference IS NOT NULL
                            AND (
                                length(lease.reference) < 1
                                OR length(lease.reference) > 1024
                            )
                        )
                        OR lease.mode NOT IN (
                            'shared', 'exclusive-delete'
                        )
                        OR length(lease.owner_id) < 1
                        OR length(lease.owner_id) > 128
                        OR length(lease.purpose) < 1
                        OR length(lease.purpose) > 128
                        OR length(lease.fencing_token) != 36
                        OR substr(lease.fencing_token, 9, 1) != '-'
                        OR substr(lease.fencing_token, 14, 1) != '-'
                        OR substr(lease.fencing_token, 19, 1) != '-'
                        OR substr(lease.fencing_token, 24, 1) != '-'
                        OR replace(lease.fencing_token, '-', '')
                            GLOB '*[^0-9a-f]*'
                        OR lease.acquired_at = ''
                        OR lease.expires_at = ''
                        OR julianday(lease.acquired_at) IS NULL
                        OR julianday(lease.expires_at) IS NULL
                        OR julianday(lease.expires_at)
                            <= julianday(lease.acquired_at)
                        OR (
                            julianday(lease.expires_at)
                              - julianday(lease.acquired_at)
                        ) * 86400.0 > 86400.001
                        OR (
                            lease.released_at IS NOT NULL
                            AND (
                                julianday(lease.released_at) IS NULL
                                OR julianday(lease.released_at)
                                  < julianday(lease.acquired_at)
                            )
                        )
                        OR (
                            lease.released_at IS NULL
                            AND NOT EXISTS (
                                SELECT 1 FROM content_cache_objects
                                WHERE content_cache_objects.provider_scope =
                                    lease.provider_scope
                                  AND content_cache_objects.digest =
                                    lease.digest
                            )
                        )
                        OR (
                            lease.mode = 'exclusive-delete'
                            AND lease.released_at IS NULL
                            AND (
                                EXISTS (
                                    SELECT 1
                                    FROM content_cache_objects
                                    WHERE content_cache_objects.provider_scope =
                                        lease.provider_scope
                                      AND content_cache_objects.digest =
                                        lease.digest
                                      AND pin_policy != 'unpinned'
                                )
                            )
                        ))
                """
            )
            let invalidIdentityProblems = try invalidIdentityCount(connection)
            let invalidReferrerContent =
                try invalidOCIReferrerContentCount(connection)
            let invalidImageTrustContent =
                try invalidImageTrustContentCount(connection)
            let invalidImageSBOMContent =
                try invalidImageSBOMContentCount(connection)
            let invalidImageVulnerabilityContent =
                try invalidImageVulnerabilityContentCount(connection)
            let invalidImageProvenanceContent =
                try ImageProvenanceRepository
                    .invalidStoredRecordCount(on: connection)
            let invalidStorageContent =
                try StorageStateRepository
                    .invalidStoredRecordCount(on: connection)
            let invalidNetworkContent =
                try NetworkStateRepository
                    .invalidStoredRecordCount(on: connection)
            let invalidProjectDNSContent =
                try ProjectDNSStateRepository
                    .invalidStoredRecordCount(on: connection)
            let invalidCertificateContent =
                try CertificateStateRepository
                    .invalidStoredRecordCount(on: connection)
            let invalidServiceTunnelContent =
                try ServiceTunnelStateRepository
                    .invalidStoredRecordCount(on: connection)
            let invalidAuditStructure = try count(
                connection,
                sql: """
                SELECT
                    (SELECT COUNT(*)
                     FROM audit_records record
                     JOIN audit_segments segment ON segment.segment_id = record.segment_id
                     WHERE segment.first_sequence != record.sequence
                        OR segment.last_sequence != record.sequence
                        OR segment.record_count != 1
                        OR segment.first_record_digest != record.record_digest
                        OR segment.last_record_digest != record.record_digest
                        OR segment.key_id != record.signing_key_id
                        OR length(record.canonical_json) > 1048576)
                  + (SELECT COUNT(*)
                     FROM audit_segments segment
                     LEFT JOIN audit_records record ON record.segment_id = segment.segment_id
                     WHERE record.record_id IS NULL)
                  + (SELECT CASE WHEN COUNT(*) > 1 THEN COUNT(*) ELSE 0 END
                     FROM audit_key_metadata WHERE status = 'active')
                  + (SELECT COUNT(*)
                     FROM audit_key_metadata
                     WHERE public_key_sha256 != substr(key_id, 6)
                        OR length(public_key_sha256) != 64
                        OR public_key_sha256 GLOB '*[^0-9a-f]*')
                  + (SELECT COUNT(*)
                     FROM audit_retention_anchors
                     WHERE removed_through_ordinal < 1
                        OR length(canonical_json) > 1048576)
                """
            )
            let invalidPolicyProfileStructure = try count(
                connection,
                sql: """
                SELECT
                    (SELECT CASE
                        WHEN (SELECT COUNT(*) FROM peer_identities) = 0 THEN
                            CASE WHEN (SELECT COUNT(*) FROM rbac_bindings WHERE role_id = 'owner' AND scope_kind = 'global') = 0 THEN 0 ELSE 1 END
                        WHEN (SELECT COUNT(*) FROM rbac_bindings WHERE role_id = 'owner' AND scope_kind = 'global') >= 1 THEN 0
                        ELSE 1
                    END)
                  + (SELECT CASE
                        WHEN COUNT(*) = 5
                         AND SUM(CASE WHEN role_id IN ('viewer','operator','maintainer','security-admin','owner') THEN 1 ELSE 0 END) = 5
                        THEN 0 ELSE 1 END
                     FROM rbac_roles WHERE built_in = 1)
                  + (SELECT COUNT(*) FROM rbac_roles
                     WHERE role_id = '' OR built_in NOT IN (0, 1) OR generation < 1
                        OR json_type(CASE WHEN json_valid(rules_json) THEN rules_json ELSE 'null' END) != 'array'
                        OR length(rules_json) > 262144
                        OR julianday(created_at) IS NULL OR julianday(updated_at) IS NULL
                        OR julianday(updated_at) < julianday(created_at))
                  + (SELECT COUNT(*) FROM rbac_bindings
                     WHERE binding_id = '' OR subject_id = '' OR role_id = '' OR generation < 1
                        OR scope_kind NOT IN ('global','project','resource')
                        OR (scope_kind = 'global' AND scope_identifier IS NOT NULL)
                        OR (scope_kind != 'global' AND (scope_identifier IS NULL OR scope_identifier = ''))
                        OR julianday(created_at) IS NULL OR julianday(updated_at) IS NULL
                        OR julianday(updated_at) < julianday(created_at))
                  + (SELECT COUNT(*) FROM rbac_delegations
                     WHERE delegation_id = '' OR delegator_subject_id = '' OR delegate_subject_id = ''
                        OR delegator_subject_id = delegate_subject_id OR generation < 1
                        OR json_type(CASE WHEN json_valid(role_ids_json) THEN role_ids_json ELSE 'null' END) != 'array'
                        OR json_type(CASE WHEN json_valid(delegated_rules_json) THEN delegated_rules_json ELSE 'null' END) != 'array'
                        OR (json_array_length(role_ids_json) = 0 AND json_array_length(delegated_rules_json) = 0)
                        OR EXISTS (SELECT 1 FROM json_each(rbac_delegations.role_ids_json) WHERE value = 'owner')
                        OR julianday(expires_at) <= julianday(created_at)
                        OR (revoked_at IS NOT NULL AND julianday(revoked_at) < julianday(created_at)))
                  + (SELECT COUNT(*) FROM admission_policies
                     WHERE policy_id = '' OR version < 1 OR generation < 1
                        OR source_kind NOT IN ('built-in','extension')
                        OR stage NOT IN ('builtInMutation','extensionMutation','builtInValidation','extensionValidation')
                        OR failure_policy NOT IN ('deny','ignore') OR advisory NOT IN (0, 1)
                        OR mutating NOT IN (0, 1) OR enabled NOT IN (0, 1)
                        OR (failure_policy = 'ignore' AND NOT (source_kind = 'extension' AND stage = 'extensionValidation' AND advisory = 1 AND mutating = 0))
                        OR json_type(CASE WHEN json_valid(document_json) THEN document_json ELSE 'null' END) != 'object'
                        OR length(document_sha256) != 64 OR document_sha256 GLOB '*[^0-9a-f]*')
                  + (SELECT COUNT(*) FROM admission_exceptions
                     WHERE exception_id = '' OR policy_id = '' OR subject_id = '' OR target = ''
                        OR length(plan_hash) != 64 OR plan_hash GLOB '*[^0-9a-f]*'
                        OR approval_identity = '' OR generation < 1
                        OR julianday(expires_at) <= julianday(created_at))
                  + (SELECT COUNT(*) FROM workload_profiles
                     WHERE profile_id = '' OR version != 1 OR generation < 1
                        OR parent_profile_id = profile_id
                        OR json_type(CASE WHEN json_valid(profile_json) THEN profile_json ELSE 'null' END) != 'object'
                        OR length(profile_sha256) != 64 OR profile_sha256 GLOB '*[^0-9a-f]*')
                """
            )
            let invalidFrozenRBACDefaults = try frozenRBACDefaultProblems(connection)
            let invalidAdmissionContent = try admissionContentProblems(connection)
            let authoritativeProblems = sqlAuthoritativeProblems +
                invalidIdentityProblems + invalidReferrerContent +
                invalidImageTrustContent + invalidImageSBOMContent +
                invalidImageVulnerabilityContent +
                invalidImageProvenanceContent +
                invalidStorageContent + invalidNetworkContent
                + invalidProjectDNSContent + invalidCertificateContent
                + invalidServiceTunnelContent + invalidAuditStructure
                + invalidPolicyProfileStructure + invalidFrozenRBACDefaults
                + invalidAdmissionContent
            if authoritativeProblems == 0 {
                checks.append(.init(identifier: "hostwright.authoritative-records", status: .passed, message: "Authoritative state records satisfy the v\(MigrationRunner.latestSchemaVersion) logical contract."))
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
            UNION ALL SELECT resource_uuid FROM image_digest_locks
            UNION ALL SELECT operation_group_id FROM image_digest_locks
            UNION ALL SELECT id FROM oci_referrer_discoveries
            UNION ALL SELECT id FROM oci_referrers
            UNION ALL SELECT id FROM oci_referrer_retention_leases
            UNION ALL SELECT fencing_token FROM oci_referrer_retention_leases
            UNION ALL SELECT id FROM oci_referrer_publications
            UNION ALL SELECT operation_group_id FROM oci_referrer_publications
            UNION ALL SELECT id FROM image_trust_exceptions
            UNION ALL SELECT exception_id FROM image_trust_verifications
                      WHERE exception_id IS NOT NULL
            UNION ALL SELECT operation_group_id FROM image_trust_verifications
            UNION ALL SELECT id FROM image_sbom_records
            UNION ALL SELECT evidence_discovery_id FROM image_sbom_records
            UNION ALL SELECT operation_group_id FROM image_sbom_records
            UNION ALL SELECT id FROM image_vulnerability_reports
            UNION ALL SELECT evidence_discovery_id FROM image_vulnerability_reports
            UNION ALL SELECT operation_group_id FROM image_vulnerability_reports
            UNION ALL SELECT id FROM image_vulnerability_decisions
            UNION ALL SELECT report_id FROM image_vulnerability_decisions
                      WHERE report_id IS NOT NULL
            UNION ALL SELECT operation_group_id FROM image_vulnerability_decisions
            UNION ALL SELECT id FROM image_vulnerability_exceptions
            UNION ALL SELECT decision_id FROM image_vulnerability_exceptions
            UNION ALL SELECT report_id FROM image_vulnerability_exceptions
            UNION ALL SELECT operation_group_id FROM image_vulnerability_exceptions
            UNION ALL SELECT id FROM image_provenance_records
            UNION ALL SELECT evidence_discovery_id FROM image_provenance_records
            UNION ALL SELECT operation_group_id FROM image_provenance_records
            UNION ALL SELECT id FROM network_resources
            UNION ALL SELECT project_uuid FROM network_resources
            UNION ALL SELECT fencing_token FROM network_resources
            UNION ALL SELECT operation_group_id FROM network_resources
            UNION ALL SELECT id FROM network_attachments
            UNION ALL SELECT network_uuid FROM network_attachments
            UNION ALL SELECT project_uuid FROM network_attachments
            UNION ALL SELECT resource_uuid FROM network_attachments
            UNION ALL SELECT fencing_token FROM network_attachments
            UNION ALL SELECT operation_group_id FROM network_attachments
            UNION ALL SELECT id FROM network_dns_instances
            UNION ALL SELECT project_uuid FROM network_dns_instances
            UNION ALL SELECT fencing_token FROM network_dns_instances
            UNION ALL SELECT operation_group_id FROM network_dns_instances
            UNION ALL SELECT id FROM network_port_reservations
            UNION ALL SELECT project_uuid FROM network_port_reservations
            UNION ALL SELECT resource_uuid FROM network_port_reservations
            UNION ALL SELECT fencing_token FROM network_port_reservations
            UNION ALL SELECT operation_group_id FROM network_port_reservations
            UNION ALL SELECT id FROM network_certificates
            UNION ALL SELECT project_uuid FROM network_certificates
            UNION ALL SELECT fencing_token FROM network_certificates
            UNION ALL SELECT operation_group_id FROM network_certificates
            UNION ALL SELECT id FROM service_tunnel_sessions
            UNION ALL SELECT project_uuid FROM service_tunnel_sessions
            UNION ALL SELECT peer_uuid FROM service_tunnel_sessions
            UNION ALL SELECT fencing_token FROM service_tunnel_sessions
            UNION ALL SELECT operation_group_id FROM service_tunnel_sessions
            """
        ).compactMap { $0.first ?? nil }
        return identities.filter { !HostwrightResourceUUID.isValid($0) }.count
    }

    private func invalidOCIReferrerContentCount(
        _ connection: SQLiteConnection
    ) throws -> Int {
        var invalid = 0
        let discoveries = try connection.query(
            """
            SELECT registry_endpoint, repository, subject_digest,
                   artifact_type, discovery_mode
            FROM oci_referrer_discoveries
            """
        )
        for row in discoveries {
            guard row.count == 5,
                  let endpoint = row[0],
                  let repository = row[1],
                  let subject = row[2],
                  let mode = row[4],
                  (try? RegistryEndpoint(endpoint)) != nil,
                  (try? OCIRepositoryName(repository)) != nil,
                  (try? OCIContentDigest(subject)) != nil,
                  row[3].map({
                      (try? OCIArtifactType($0)) != nil
                  }) ?? true,
                  OCIReferrerDiscoveryMode(rawValue: mode) != nil else {
                invalid += 1
                continue
            }
        }

        let descriptors = try connection.query(
            """
            SELECT media_type, referrer_digest, size_bytes,
                   artifact_type, annotations_json, subject_digest
            FROM oci_referrers
            """
        )
        for row in descriptors {
            guard row.count == 6,
                  let mediaType = row[0],
                  let digest = row[1],
                  let sizeText = row[2],
                  let size = Int(sizeText),
                  let annotations = row[4],
                  let subject = row[5],
                  let data = annotations.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(
                      with: data
                  ) as? [String: String],
                  (try? OCIContentDigest(subject)) != nil,
                  (try? OCIReferrerDescriptor(
                      mediaType: mediaType,
                      digest: OCIContentDigest(digest),
                      size: size,
                      artifactType: try row[3].map(
                          OCIArtifactType.init
                      ),
                      annotations: object
                  )) != nil else {
                invalid += 1
                continue
            }
        }

        let objects = try connection.query(
            """
            SELECT digest, media_type, size_bytes, object_kind,
                   payload_base64, payload_sha256, children_json
            FROM oci_referrer_cache_objects
            """
        )
        for row in objects {
            guard row.count == 7,
                  let digestValue = row[0],
                  let mediaType = row[1],
                  let sizeText = row[2],
                  let size = Int(sizeText),
                  let kindValue = row[3],
                  let payloadBase64 = row[4],
                  let payloadProof = row[5],
                  let childrenJSON = row[6],
                  let payload = Data(
                      base64Encoded: payloadBase64
                  ),
                  let kind = OCIReferrerObjectKind(
                      rawValue: kindValue
                  ),
                  let childrenData = childrenJSON.data(
                      using: .utf8
                  ),
                  let children = try? JSONDecoder().decode(
                      [OCIContentDescriptor].self,
                      from: childrenData
                  ),
                  let digest = try? OCIContentDigest(digestValue),
                  sha256(payload) == payloadProof,
                  (try? OCIReferrerFetchedObject(
                      digest: digest,
                      mediaType: mediaType,
                      size: size,
                      kind: kind,
                      payload: payload,
                      childDescriptors: children
                  )) != nil else {
                invalid += 1
                continue
            }
        }
        return invalid
    }

    private func invalidImageTrustContentCount(
        _ connection: SQLiteConnection
    ) throws -> Int {
        var invalid = 0
        let exceptions = try connection.query(
            """
            SELECT id, descriptor_digest, policy_sha256, approver,
                   approved_at, expires_at, revoked_at, idempotency_key
            FROM image_trust_exceptions
            """
        )
        for row in exceptions {
            guard row.count == 8,
                  let id = row[0],
                  let descriptor = row[1],
                  let policy = row[2],
                  let approver = row[3],
                  let approvedAt = row[4],
                  let expiresAt = row[5],
                  let idempotencyKey = row[7],
                  HostwrightResourceUUID.isValid(id),
                  descriptor.range(
                      of: #"^sha256:[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  policy.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  approver.range(
                      of: #"^[A-Za-z0-9][A-Za-z0-9._@:+-]{0,126}$"#,
                      options: .regularExpression
                  ) != nil,
                  idempotencyKey.range(
                      of: #"^[a-z0-9][a-z0-9._+-]{0,126}$"#,
                      options: .regularExpression
                  ) != nil,
                  timestampIsValid(approvedAt),
                  timestampIsValid(expiresAt),
                  expiresAt > approvedAt,
                  row[6].map({
                      timestampIsValid($0) && $0 >= approvedAt
                  }) ?? true else {
                invalid += 1
                continue
            }
        }

        let verifications = try connection.query(
            """
            SELECT descriptor_digest, policy_sha256, evidence_graph_sha256,
                   evidence_discovery_id, trusted_root_sha256,
                   verifier_version, matched_authority_ids_json,
                   threshold, outcome, exception_id,
                   operation_group_id, created_at
            FROM image_trust_verifications
            """
        )
        for row in verifications {
            guard row.count == 12,
                  let descriptor = row[0],
                  let policy = row[1],
                  let evidenceGraph = row[2],
                  let evidenceDiscoveryID = row[3],
                  let trustedRoot = row[4],
                  let verifierVersion = row[5],
                  let authorityIDsJSON = row[6],
                  let thresholdText = row[7],
                  let threshold = Int(thresholdText),
                  let outcome = row[8],
                  let operationGroupID = row[10],
                  let createdAt = row[11],
                  descriptor.range(
                      of: #"^sha256:[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  policy.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  evidenceGraph.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  trustedRoot.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  verifierVersion.range(
                      of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,126}$"#,
                      options: .regularExpression
                  ) != nil,
                  outcome == "passed" ||
                    outcome == "threshold-not-met",
                  (1...8).contains(threshold),
                  HostwrightResourceUUID.isValid(evidenceDiscoveryID),
                  HostwrightResourceUUID.isValid(operationGroupID),
                  row[9].map(HostwrightResourceUUID.isValid) ?? true,
                  timestampIsValid(createdAt),
                  let authorityData = authorityIDsJSON.data(using: .utf8),
                  let authorityIDs = try? JSONSerialization.jsonObject(
                      with: authorityData
                  ) as? [String],
                  authorityIDs.count <= 8,
                  Set(authorityIDs).count == authorityIDs.count,
                  authorityIDs.allSatisfy({
                      $0.range(
                          of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$"#,
                          options: .regularExpression
                      ) != nil
                  }),
                  let discovery = try? connection.query(
                      """
                      SELECT graph_sha256
                      FROM oci_referrer_discoveries
                      WHERE id = ?
                      LIMIT 1
                      """,
                      bindings: [.text(evidenceDiscoveryID)]
                  ),
                  discovery.count == 1,
                  discovery[0][0] == evidenceGraph else {
                invalid += 1
                continue
            }
        }

        let manifests = try connection.query(
            """
            SELECT registry_endpoint, repository, descriptor_digest,
                   payload_base64, payload_sha256
            FROM image_trust_subject_manifests
            """
        )
        for row in manifests {
            guard row.count == 5,
                  let endpoint = row[0],
                  let repository = row[1],
                  let descriptor = row[2],
                  let payloadBase64 = row[3],
                  let payloadSHA256 = row[4],
                  let payload = Data(base64Encoded: payloadBase64),
                  payload.base64EncodedString() == payloadBase64,
                  (try? RegistryEndpoint(endpoint)) != nil,
                  (try? OCIRepositoryName(repository)) != nil,
                  descriptor.range(
                      of: #"^sha256:[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  payloadSHA256.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  sha256(payload) == payloadSHA256,
                  descriptor == "sha256:\(payloadSHA256)" else {
                invalid += 1
                continue
            }
        }
        return invalid
    }

    private func invalidImageSBOMContentCount(
        _ connection: SQLiteConnection
    ) throws -> Int {
        var invalid = 0
        let rows = try connection.query(
            """
            SELECT id, project_id, service_name, descriptor_digest,
                   policy_sha256, format, document_digest,
                   document_media_type, evidence_discovery_id,
                   evidence_graph_sha256, sbom_referrer_digest,
                   provenance_descriptor_digest,
                   provenance_referrer_digest, component_count,
                   normalized_components_sha256, operation_group_id,
                   created_at
            FROM image_sbom_records
            """
        )
        for row in rows {
            guard row.count == 17,
                  let id = row[0],
                  let projectID = row[1],
                  let serviceName = row[2],
                  let descriptorDigest = row[3],
                  let policySHA256 = row[4],
                  let formatValue = row[5],
                  let documentDigest = row[6],
                  let documentMediaType = row[7],
                  let evidenceDiscoveryID = row[8],
                  let evidenceGraphSHA256 = row[9],
                  let sbomReferrerDigest = row[10],
                  let componentCountText = row[13],
                  let componentCount = Int(componentCountText),
                  let normalizedComponentsSHA256 = row[14],
                  let operationGroupID = row[15],
                  let createdAt = row[16],
                  HostwrightResourceUUID.isValid(id),
                  nameIsValid(projectID),
                  nameIsValid(serviceName),
                  descriptorDigest.range(
                      of: #"^sha256:[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  policySHA256.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  ImageSBOMDocumentFormat(rawValue: formatValue) != nil,
                  (try? OCIContentDigest(documentDigest)) != nil,
                  nameIsValidMediaType(documentMediaType),
                  HostwrightResourceUUID.isValid(evidenceDiscoveryID),
                  evidenceGraphSHA256.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  (try? OCIContentDigest(sbomReferrerDigest)) != nil,
                  (0...1_000_000).contains(componentCount),
                  normalizedComponentsSHA256.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  HostwrightResourceUUID.isValid(operationGroupID),
                  timestampIsValid(createdAt) else {
                invalid += 1
                continue
            }

            let provenanceDescriptorDigest = row[11]
            let provenanceReferrerDigest = row[12]
            let provenanceDescriptorValid = provenanceDescriptorDigest.map {
                (try? OCIContentDigest($0)) != nil
            } ?? true
            let provenanceReferrerValid = provenanceReferrerDigest.map {
                (try? OCIContentDigest($0)) != nil
            } ?? true
            guard (provenanceDescriptorDigest == nil) ==
                (provenanceReferrerDigest == nil),
                provenanceDescriptorValid,
                provenanceReferrerValid else {
                invalid += 1
                continue
            }

            let discovery = try connection.query(
                """
                SELECT graph_sha256
                FROM oci_referrer_discoveries
                WHERE id = ?
                LIMIT 1
                """,
                bindings: [.text(evidenceDiscoveryID)]
            )
            guard discovery.count == 1,
                  discovery[0][0] == evidenceGraphSHA256,
                  hasReferrer(
                      discoveryID: evidenceDiscoveryID,
                      referrerDigest: sbomReferrerDigest,
                      on: connection
                  ),
                  hasGraphObject(
                      discoveryID: evidenceDiscoveryID,
                      objectDigest: documentDigest,
                      on: connection
                  ) else {
                invalid += 1
                continue
            }

            if let provenanceDescriptorDigest,
               let provenanceReferrerDigest {
                guard hasReferrer(
                    discoveryID: evidenceDiscoveryID,
                    referrerDigest: provenanceReferrerDigest,
                    on: connection
                ),
                hasGraphObject(
                    discoveryID: evidenceDiscoveryID,
                    objectDigest: provenanceDescriptorDigest,
                    on: connection
                ) else {
                    invalid += 1
                    continue
                }
            }
        }
        return invalid
    }

    private func invalidImageVulnerabilityContentCount(
        _ connection: SQLiteConnection
    ) throws -> Int {
        var invalid = 0
        let reports = try connection.query(
            """
            SELECT id, project_id, service_name, descriptor_digest,
                   report_digest, report_referrer_digest,
                   evidence_discovery_id, evidence_graph_sha256,
                   database_id, database_version, database_updated_at,
                   generated_at, signature_policy_sha256,
                   signature_proof_json, signature_proof_sha256,
                   operation_group_id, created_at
            FROM image_vulnerability_reports
            """
        )
        for row in reports {
            guard row.count == 17,
                  let id = row[0],
                  let projectID = row[1],
                  let serviceName = row[2],
                  let descriptor = row[3],
                  let reportDigest = row[4],
                  let referrerDigest = row[5],
                  let discoveryID = row[6],
                  let graph = row[7],
                  let databaseID = row[8],
                  let databaseVersion = row[9],
                  let databaseUpdatedAt = row[10],
                  let generatedAt = row[11],
                  let signaturePolicy = row[12],
                  let signatureProofJSON = row[13],
                  let signatureProofSHA256 = row[14],
                  let operationGroupID = row[15],
                  let createdAt = row[16],
                  nameIsValid(projectID),
                  nameIsValid(serviceName),
                  HostwrightResourceUUID.isValid(id),
                  descriptor.range(
                      of: #"^sha256:[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  (try? OCIContentDigest(reportDigest)) != nil,
                  (try? OCIContentDigest(referrerDigest)) != nil,
                  HostwrightResourceUUID.isValid(discoveryID),
                  graph.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  !databaseID.isEmpty, databaseID.utf8.count <= 127,
                  !databaseVersion.isEmpty,
                  databaseVersion.utf8.count <= 127,
                  timestampIsValid(databaseUpdatedAt),
                  timestampIsValid(generatedAt),
                  timestampIsValid(createdAt),
                  signaturePolicy.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  signatureProofSHA256.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  let signatureProof = try?
                    ImageVulnerabilitySignatureProof
                        .decodeCanonicalJSONString(
                            signatureProofJSON
                        ),
                  (try? signatureProof.canonicalSHA256()) ==
                    signatureProofSHA256,
                  HostwrightResourceUUID.isValid(operationGroupID),
                  let reconstructed = try?
                    ImageVulnerabilityReportRecord(
                        projectID: projectID,
                        serviceName: serviceName,
                        descriptorDigest: descriptor,
                        reportDigest: reportDigest,
                        reportReferrerDigest: referrerDigest,
                        evidenceDiscoveryID: discoveryID,
                        evidenceGraphSHA256: graph,
                        databaseID: databaseID,
                        databaseVersion: databaseVersion,
                        databaseUpdatedAt: databaseUpdatedAt,
                        generatedAt: generatedAt,
                        signaturePolicySHA256: signaturePolicy,
                        signatureProof: signatureProof,
                        operationGroupID: operationGroupID,
                        createdAt: createdAt
                    ),
                  reconstructed.id == id,
                  let discovery = try? connection.query(
                      """
                      SELECT graph_sha256, subject_digest
                      FROM oci_referrer_discoveries
                      WHERE id = ?
                      LIMIT 1
                      """,
                      bindings: [.text(discoveryID)]
                  ),
                  discovery.count == 1,
                  discovery[0][0] == graph,
                  discovery[0][1] == descriptor,
                  hasExactGraphObject(
                      discoveryID: discoveryID,
                      referrerDigest: referrerDigest,
                      objectDigest: reportDigest,
                      artifactType:
                        ImageVulnerabilityReport.artifactType,
                      objectMediaType:
                        ImageVulnerabilityReport.layerMediaType,
                      on: connection
                  ),
                  signatureProof.bundleDigests.allSatisfy({
                      hasExactSignatureBundle(
                          discoveryID: discoveryID,
                          bundleDigest: $0,
                          reportDigest: reportDigest,
                          on: connection
                      )
                  }),
                  hasReferrer(
                      discoveryID: discoveryID,
                      referrerDigest: referrerDigest,
                      on: connection
                  ) else {
                invalid += 1
                continue
            }
        }

        let decisions = try connection.query(
            """
            SELECT id, project_id, service_name, descriptor_digest,
                   decision_digest, report_id, policy_sha256,
                   signature_policy_sha256, evaluator_version,
                   evaluated_at, freshness, data_age_seconds,
                   candidate_findings_json, candidate_findings_sha256,
                   allowlisted_findings_json,
                   allowlisted_findings_sha256,
                   blocking_findings_json, blocking_findings_sha256,
                   outcome, reason_codes_json, reason_codes_sha256,
                   operation_group_id, created_at
            FROM image_vulnerability_decisions
            """
        )
        for row in decisions {
            guard row.count == 23,
                  let id = row[0],
                  let projectID = row[1],
                  let serviceName = row[2],
                  let descriptor = row[3],
                  let decisionDigest = row[4],
                  let policy = row[6],
                  let signaturePolicy = row[7],
                  let evaluatorVersion = row[8],
                  let evaluatedAt = row[9],
                  let freshnessValue = row[10],
                  let freshness = ImageVulnerabilityFreshness(
                      rawValue: freshnessValue
                  ),
                  let candidatesJSON = row[12],
                  let candidatesHash = row[13],
                  let allowlistedJSON = row[14],
                  let allowlistedHash = row[15],
                  let blockingJSON = row[16],
                  let blockingHash = row[17],
                  let outcomeValue = row[18],
                  let outcome = ImageVulnerabilityDecisionOutcome(
                      rawValue: outcomeValue
                  ),
                  let reasonsJSON = row[19],
                  let reasonsHash = row[20],
                  let operationGroupID = row[21],
                  let createdAt = row[22],
                  let candidateData = candidatesJSON.data(using: .utf8),
                  let candidates = try? JSONDecoder().decode(
                      [ImageVulnerabilityFindingIdentity].self,
                      from: candidateData
                  ),
                  let allowlistedData = allowlistedJSON.data(
                      using: .utf8
                  ),
                  let allowlisted = try? JSONDecoder().decode(
                      [ImageVulnerabilityFindingIdentity].self,
                      from: allowlistedData
                  ),
                  let blockingData = blockingJSON.data(using: .utf8),
                  let blocking = try? JSONDecoder().decode(
                      [ImageVulnerabilityFindingIdentity].self,
                      from: blockingData
                  ),
                  let reasonsData = reasonsJSON.data(using: .utf8),
                  let reasons = try? JSONDecoder().decode(
                      [String].self,
                      from: reasonsData
                  ),
                  HostwrightResourceUUID.isValid(id),
                  nameIsValid(projectID), nameIsValid(serviceName),
                  descriptor.range(
                      of: #"^sha256:[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  (try? OCIContentDigest(decisionDigest)) != nil,
                  policy.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  signaturePolicy.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  !evaluatorVersion.isEmpty,
                  timestampIsValid(evaluatedAt),
                  timestampIsValid(createdAt),
                  HostwrightResourceUUID.isValid(operationGroupID) else {
                invalid += 1
                continue
            }
            let dataAge = row[11].flatMap(Int.init)
            let reconstructed = ImageVulnerabilityDecisionRecord(
                projectID: projectID,
                serviceName: serviceName,
                descriptorDigest: descriptor,
                decisionDigest: decisionDigest,
                reportID: row[5],
                policySHA256: policy,
                signaturePolicySHA256: signaturePolicy,
                evaluatorVersion: evaluatorVersion,
                evaluatedAt: evaluatedAt,
                freshness: freshness,
                dataAgeSeconds: dataAge,
                candidateFindings: candidates,
                allowlistedFindings: allowlisted,
                blockingFindings: blocking,
                outcome: outcome,
                reasonCodes: reasons,
                operationGroupID: operationGroupID,
                createdAt: createdAt
            )
            guard reconstructed.id == id,
                  reconstructed.candidateFindings == candidates,
                  reconstructed.allowlistedFindings == allowlisted,
                  reconstructed.blockingFindings == blocking,
                  reconstructed.reasonCodes == reasons,
                  reconstructed.candidateFindingsSHA256 ==
                    candidatesHash,
                  reconstructed.allowlistedFindingsSHA256 ==
                    allowlistedHash,
                  reconstructed.blockingFindingsSHA256 ==
                    blockingHash,
                  reconstructed.reasonCodesSHA256 == reasonsHash,
                  (freshness == .unavailable) ==
                    (row[5] == nil && dataAge == nil),
                  vulnerabilityDecisionReportIsValid(
                      freshness: freshness,
                      reportID: row[5],
                      dataAgeSeconds: dataAge,
                      projectID: projectID,
                      serviceName: serviceName,
                      descriptorDigest: descriptor,
                      signaturePolicySHA256: signaturePolicy,
                      evaluatedAt: evaluatedAt,
                      on: connection
                  ) else {
                invalid += 1
                continue
            }
        }

        let exceptions = try connection.query(
            """
            SELECT id, decision_id, decision_digest, report_id,
                   report_digest, report_referrer_digest, policy_sha256,
                   signature_policy_sha256, database_id,
                   database_version, blocked_findings_sha256,
                   approved_at, expires_at, revoked_at,
                   idempotency_key, operation_group_id
            FROM image_vulnerability_exceptions
            """
        )
        for row in exceptions {
            guard row.count == 16,
                  let id = row[0],
                  let decisionID = row[1],
                  let decisionDigest = row[2],
                  let reportID = row[3],
                  let reportDigest = row[4],
                  let referrerDigest = row[5],
                  let policy = row[6],
                  let signaturePolicy = row[7],
                  let databaseID = row[8],
                  let databaseVersion = row[9],
                  let blockedHash = row[10],
                  let approvedAt = row[11],
                  let expiresAt = row[12],
                  let idempotencyKey = row[14],
                  let operationGroupID = row[15],
                  HostwrightResourceUUID.isValid(id),
                  HostwrightResourceUUID.isValid(decisionID),
                  (try? OCIContentDigest(decisionDigest)) != nil,
                  HostwrightResourceUUID.isValid(reportID),
                  (try? OCIContentDigest(reportDigest)) != nil,
                  (try? OCIContentDigest(referrerDigest)) != nil,
                  policy.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  signaturePolicy.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  !databaseID.isEmpty, !databaseVersion.isEmpty,
                  blockedHash.range(
                      of: #"^[a-f0-9]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  timestampIsValid(approvedAt),
                  timestampIsValid(expiresAt),
                  row[13].map(timestampIsValid) ?? true,
                  HostwrightResourceUUID.isValid(idempotencyKey),
                  HostwrightResourceUUID.isValid(operationGroupID),
                  let exact = try? connection.query(
                      """
                      SELECT 1
                      FROM image_vulnerability_decisions d
                      JOIN image_vulnerability_reports r
                        ON r.id = d.report_id
                      WHERE d.id = ? AND d.outcome = 'blocked'
                        AND d.decision_digest = ?
                        AND d.report_id = ? AND r.report_digest = ?
                        AND r.report_referrer_digest = ?
                        AND d.policy_sha256 = ?
                        AND d.signature_policy_sha256 = ?
                        AND r.database_id = ?
                        AND r.database_version = ?
                        AND d.blocking_findings_sha256 = ?
                      LIMIT 1
                      """,
                      bindings: [
                          .text(decisionID), .text(decisionDigest),
                          .text(reportID), .text(reportDigest),
                          .text(referrerDigest), .text(policy),
                          .text(signaturePolicy), .text(databaseID),
                          .text(databaseVersion), .text(blockedHash)
                      ]
                  ),
                  exact.count == 1 else {
                invalid += 1
                continue
            }
        }
        return invalid
    }

    private func hasReferrer(
        discoveryID: String,
        referrerDigest: String,
        on connection: SQLiteConnection
    ) -> Bool {
        let rows = (try? connection.query(
            """
            SELECT 1
            FROM oci_referrers
            WHERE discovery_id = ? AND referrer_digest = ?
            LIMIT 1
            """,
            bindings: [
                .text(discoveryID),
                .text(referrerDigest)
            ]
        )) ?? []
        return rows.count == 1
    }

    private func hasExactGraphObject(
        discoveryID: String,
        referrerDigest: String,
        objectDigest: String,
        artifactType: String,
        objectMediaType: String,
        on connection: SQLiteConnection
    ) -> Bool {
        let rows = (try? connection.query(
            """
            SELECT 1
            FROM oci_referrers AS referrer
            JOIN oci_referrer_graph_objects AS graph
              ON graph.discovery_id = referrer.discovery_id
             AND graph.referrer_digest = referrer.referrer_digest
            JOIN oci_referrer_cache_objects AS cache
              ON cache.digest = graph.object_digest
            WHERE referrer.discovery_id = ?
              AND referrer.referrer_digest = ?
              AND graph.object_digest = ?
              AND referrer.artifact_type = ?
              AND cache.media_type = ?
              AND cache.object_kind = 'blob'
            """,
            bindings: [
                .text(discoveryID),
                .text(referrerDigest),
                .text(objectDigest),
                .text(artifactType),
                .text(objectMediaType)
            ]
        )) ?? []
        return rows.count == 1
    }

    private func hasExactSignatureBundle(
        discoveryID: String,
        bundleDigest: String,
        reportDigest: String,
        on connection: SQLiteConnection
    ) -> Bool {
        let rows = (try? connection.query(
            """
            SELECT cache.payload_base64
            FROM oci_referrer_graph_objects AS graph
            JOIN oci_referrers AS referrer
              ON referrer.discovery_id = graph.discovery_id
             AND referrer.referrer_digest = graph.referrer_digest
            JOIN oci_referrer_cache_objects AS cache
              ON cache.digest = graph.object_digest
            WHERE graph.discovery_id = ?
              AND graph.object_digest = ?
              AND referrer.artifact_type = ?
              AND cache.media_type = ?
              AND cache.object_kind = 'blob'
            """,
            bindings: [
                .text(discoveryID),
                .text(bundleDigest),
                .text(SigstoreBundleEvidence.mediaType),
                .text(SigstoreBundleEvidence.mediaType)
            ]
        )) ?? []
        guard rows.count == 1,
              let payloadBase64 = rows[0][0],
              let payload = Data(base64Encoded: payloadBase64),
              let bundle = try? SigstoreBundleEvidence(
                  digest: bundleDigest,
                  payload: payload
              ),
              let reportContentSHA256 =
                (try? OCIContentDigest(reportDigest))?.encoded else {
            return false
        }
        return bundle.signedContentSHA256 == reportContentSHA256
    }

    private func vulnerabilityDecisionReportIsValid(
        freshness: ImageVulnerabilityFreshness,
        reportID: String?,
        dataAgeSeconds: Int?,
        projectID: String,
        serviceName: String,
        descriptorDigest: String,
        signaturePolicySHA256: String,
        evaluatedAt: String,
        on connection: SQLiteConnection
    ) -> Bool {
        if freshness == .unavailable {
            return reportID == nil && dataAgeSeconds == nil
        }
        guard let reportID,
              let dataAgeSeconds,
              let rows = try? connection.query(
                  """
                  SELECT project_id, service_name, descriptor_digest,
                         signature_policy_sha256, database_updated_at
                  FROM image_vulnerability_reports
                  WHERE id = ?
                  LIMIT 1
                  """,
                  bindings: [.text(reportID)]
              ),
              rows.count == 1,
              rows[0][0] == projectID,
              rows[0][1] == serviceName,
              rows[0][2] == descriptorDigest,
              rows[0][3] == signaturePolicySHA256,
              let databaseUpdatedAt = rows[0][4],
              let evaluatedDate = timestampDate(evaluatedAt),
              let databaseDate = timestampDate(databaseUpdatedAt),
              evaluatedDate >= databaseDate else {
            return false
        }
        return Int(
            evaluatedDate.timeIntervalSince(databaseDate)
        ) == dataAgeSeconds
    }

    private func hasGraphObject(
        discoveryID: String,
        objectDigest: String,
        on connection: SQLiteConnection
    ) -> Bool {
        let rows = (try? connection.query(
            """
            SELECT 1
            FROM oci_referrer_graph_objects
            WHERE discovery_id = ? AND object_digest = ?
            LIMIT 1
            """,
            bindings: [
                .text(discoveryID),
                .text(objectDigest)
            ]
        )) ?? []
        return rows.count == 1
    }

    private func nameIsValid(_ value: String) -> Bool {
        value.range(
            of: #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#,
            options: .regularExpression
        ) != nil
    }

    private func nameIsValidMediaType(_ value: String) -> Bool {
        (try? OCIMediaTypePolicy.validate(value)) != nil
    }

    private func timestampIsValid(_ value: String) -> Bool {
        timestampDate(value) != nil
    }

    private func timestampDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        guard value.utf8.count <= 64 else { return nil }
        return fractional.date(from: value) ?? whole.date(from: value)
    }

    private func frozenRBACDefaultProblems(_ connection: SQLiteConnection) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let expected = try Dictionary(
            uniqueKeysWithValues: RBACRepository.defaultRoles(
                timestamp: "2001-01-01T00:00:00Z"
            ).map { role in
                (role.roleID, String(decoding: try encoder.encode(role.rules), as: UTF8.self))
            }
        )
        let stored = try connection.query(
            "SELECT role_id, rules_json FROM rbac_roles WHERE built_in = 1 ORDER BY role_id"
        )
        guard stored.count == expected.count else { return 1 }
        for row in stored {
            guard row.count == 2, let roleID = row[0], let rules = row[1],
                expected[roleID] == rules
            else { return 1 }
        }
        return 0
    }

    private func admissionContentProblems(_ connection: SQLiteConnection) throws -> Int {
        var problems = 0
        for row in try connection.query(
            """
            SELECT policy_id, version, source_kind, stage, failure_policy, advisory, mutating,
                   document_json, document_sha256, enabled, generation,
                   created_by_subject_id, created_at, updated_at
            FROM admission_policies ORDER BY policy_id
            """
        ) {
            do {
                guard row.count == 14, let policyID = row[0],
                    let version = row[1].flatMap(Int.init), let sourceRaw = row[2],
                    let source = AdmissionPolicySourceKind(rawValue: sourceRaw),
                    let stageRaw = row[3], let stage = AdmissionStage(rawValue: stageRaw),
                    let failureRaw = row[4],
                    let failure = AdmissionFailurePolicy(rawValue: failureRaw),
                    let advisory = row[5].flatMap(Int.init),
                    let mutating = row[6].flatMap(Int.init), let documentJSON = row[7],
                    let documentData = documentJSON.data(using: .utf8),
                    let document = try? JSONDecoder().decode(
                        ControlPlaneJSONValue.self, from: documentData),
                    let documentSHA = row[8], let enabled = row[9].flatMap(Int.init),
                    let generation = row[10].flatMap(Int.init), let creator = row[11],
                    let createdAt = row[12], let updatedAt = row[13],
                    [advisory, mutating, enabled].allSatisfy({ $0 == 0 || $0 == 1 })
                else { throw StateStoreError.invalidRecord("Malformed admission policy") }
                _ = try AdmissionPolicyRecord(
                    policyID: policyID, version: version, sourceKind: source, stage: stage,
                    failurePolicy: failure, advisory: advisory == 1, mutating: mutating == 1,
                    document: document, documentSHA256: documentSHA, enabled: enabled == 1,
                    generation: generation, createdBySubjectID: creator,
                    createdAt: createdAt, updatedAt: updatedAt
                ).canonicalized()
                guard String(
                    decoding: try ControlPlaneCanonicalJSON.encode(document), as: UTF8.self
                ) == documentJSON else {
                    throw StateStoreError.invalidRecord("Noncanonical admission policy JSON")
                }
            } catch { problems += 1 }
        }
        for row in try connection.query(
            """
            SELECT exception_id, policy_id, subject_id, target, plan_hash, approval_identity,
                   expires_at, created_by_subject_id, generation, created_at, updated_at
            FROM admission_exceptions ORDER BY exception_id
            """
        ) {
            do {
                guard row.count == 11, let exceptionID = row[0], let policyID = row[1],
                    let subjectID = row[2], let target = row[3], let planHash = row[4],
                    let approval = row[5], let expiresAt = row[6], let creator = row[7],
                    let generation = row[8].flatMap(Int.init), let createdAt = row[9],
                    let updatedAt = row[10]
                else { throw StateStoreError.invalidRecord("Malformed admission exception") }
                _ = try AdmissionExceptionRecord(
                    exceptionID: exceptionID, policyID: policyID, subjectID: subjectID,
                    target: target, planHash: planHash, approvalIdentity: approval,
                    expiresAt: expiresAt, createdBySubjectID: creator,
                    generation: generation, createdAt: createdAt, updatedAt: updatedAt
                ).canonicalized()
            } catch { problems += 1 }
        }
        return problems
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
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
        "restart_attempt_history",
        "restart_recovery_records",
        "operation_groups",
        "operation_group_steps",
        "image_digest_locks",
        "oci_referrer_discoveries",
        "oci_referrers",
        "oci_referrer_cache_objects",
        "oci_referrer_graph_objects",
        "oci_referrer_retention_leases",
        "oci_referrer_publications",
        "image_trust_exceptions",
        "image_trust_verifications",
        "image_trust_subject_manifests",
        "image_sbom_records",
        "image_vulnerability_reports",
        "image_vulnerability_exceptions",
        "image_vulnerability_decisions",
        "image_provenance_records",
        "content_cache_objects",
        "content_cache_references",
        "content_cache_leases",
        "storage_volumes",
        "storage_attachments",
        "storage_snapshots",
        "storage_backups",
        "storage_holds",
        "storage_orphans",
        "storage_capacity_samples",
        "storage_quotas",
        "storage_capacity_admissions",
        "network_resources",
        "network_attachments",
        "network_dns_instances",
        "network_port_reservations",
        "network_certificates",
        "service_tunnel_sessions",
        "peer_identities",
        "control_sessions",
        "identity_revocations",
        "control_requests",
        "idempotency_records",
        "audit_key_metadata",
        "audit_segments",
        "audit_records",
        "audit_retention_anchors",
        "rbac_roles",
        "rbac_bindings",
        "rbac_delegations",
        "admission_policies",
        "admission_exceptions",
        "workload_profiles"
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
        "restart_attempt_history_project_idx",
        "restart_attempt_history_workload_idx",
        "restart_attempt_history_operation_idx",
        "peer_identities_code_hash_idx",
        "peer_identities_active_code_idx",
        "peer_identities_active_credential_idx",
        "control_sessions_subject_idx",
        "control_sessions_code_hash_idx",
        "identity_revocations_target_idx",
        "control_requests_subject_idempotency_idx",
        "control_requests_subject_status_idx",
        "idempotency_records_request_idx",
        "audit_key_metadata_active_idx",
        "audit_segments_key_idx",
        "audit_segments_prior_digest_idx",
        "audit_records_segment_idx",
        "audit_records_subject_idx",
        "audit_records_request_idx",
        "audit_records_deduplication_idx",
        "audit_retention_key_idx",
        "rbac_roles_builtin_idx",
        "rbac_bindings_subject_idx",
        "rbac_bindings_role_idx",
        "rbac_bindings_identity_idx",
        "rbac_delegations_delegate_idx",
        "rbac_delegations_delegator_idx",
        "admission_policies_active_idx",
        "admission_exceptions_lookup_idx",
        "workload_profiles_parent_idx",
        "workload_profiles_digest_idx",
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
        "operation_groups_fencing_token_idx",
        "image_digest_locks_project_idx",
        "image_digest_locks_resource_idx",
        "image_digest_locks_plan_idx",
        "oci_referrer_discoveries_subject_idx",
        "oci_referrers_subject_idx",
        "oci_referrer_graph_object_idx",
        "oci_referrer_leases_active_idx",
        "oci_referrer_publications_cleanup_idx",
        "image_trust_exceptions_idempotency_idx",
        "image_trust_exceptions_active_lookup_idx",
        "image_trust_verifications_lookup_idx",
        "image_trust_verifications_operation_idx",
        "image_trust_subject_manifests_lookup_idx",
        "image_sbom_records_subject_idx",
        "image_sbom_records_operation_idx",
        "image_sbom_records_sbom_cleanup_idx",
        "image_sbom_records_provenance_cleanup_idx",
        "image_vulnerability_reports_subject_idx",
        "image_vulnerability_reports_cleanup_idx",
        "image_vulnerability_exceptions_idempotency_idx",
        "image_vulnerability_exceptions_active_idx",
        "image_vulnerability_decisions_subject_idx",
        "image_vulnerability_decisions_report_idx",
        "image_vulnerability_decisions_operation_idx",
        "image_provenance_records_subject_idx",
        "image_provenance_records_operation_idx",
        "image_provenance_records_cleanup_idx",
        "image_provenance_records_statement_idx",
        "content_cache_objects_pressure_idx",
        "content_cache_references_digest_idx",
        "content_cache_references_operation_idx",
        "content_cache_leases_digest_active_idx",
        "content_cache_leases_reference_active_idx",
        "content_cache_leases_owner_active_idx",
        "storage_volumes_provider_idx",
        "storage_volumes_project_idx",
        "storage_volumes_topology_idx",
        "storage_volumes_operation_idx",
        "storage_attachments_volume_idx",
        "storage_attachments_operation_idx",
        "storage_attachments_lease_idx",
        "storage_attachments_single_writer_idx",
        "storage_attachments_holder_active_idx",
        "storage_snapshots_source_idx",
        "storage_snapshots_operation_idx",
        "storage_backups_volume_idx",
        "storage_backups_operation_idx",
        "storage_holds_resource_idx",
        "storage_holds_active_idx",
        "storage_orphans_provider_idx",
        "storage_orphans_operation_idx",
        "storage_capacity_samples_latest_idx",
        "storage_capacity_samples_operation_idx",
        "storage_quotas_resource_idx",
        "storage_quotas_operation_idx",
        "storage_capacity_admissions_operation_idx",
        "storage_capacity_admissions_sample_idx",
        "network_resources_project_idx",
        "network_resources_provider_idx",
        "network_resources_operation_idx",
        "network_attachments_network_idx",
        "network_attachments_resource_idx",
        "network_attachments_operation_idx",
        "network_dns_instances_project_idx",
        "network_dns_instances_operation_idx",
        "network_port_reservations_active_idx",
        "network_port_reservations_project_idx",
        "network_port_reservations_resource_idx",
        "network_port_reservations_operation_idx",
        "network_certificates_project_idx",
        "network_certificates_provider_idx",
        "network_certificates_operation_idx",
        "service_tunnel_active_peer_idx",
        "service_tunnel_operation_idx",
        "service_tunnel_recovery_idx"
    ]

    private static let requiredTriggers = [
        "rbac_builtin_role_update",
        "rbac_builtin_role_delete",
        "rbac_last_owner_delete",
        "rbac_delegation_owner_insert",
        "rbac_delegation_owner_update",
        "rbac_owner_binding_update"
    ]
}
