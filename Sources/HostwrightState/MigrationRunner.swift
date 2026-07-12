public struct SchemaMigration: Equatable, Sendable {
    public let version: Int
    public let description: String
    public let checksum: String
    public let legacyChecksums: [String]
    let statements: [String]

    public init(version: Int, description: String, legacyChecksums: [String] = [], statements: [String]) {
        self.version = version
        self.description = description
        self.checksum = Self.computeChecksum(version: version, description: description, statements: statements)
        self.legacyChecksums = legacyChecksums
        self.statements = statements
    }

    public init(version: Int, description: String, checksum: String, legacyChecksums: [String] = [], statements: [String]) {
        self.version = version
        self.description = description
        self.checksum = checksum
        self.legacyChecksums = legacyChecksums
        self.statements = statements
    }

    func accepts(recordedChecksum: String) -> Bool {
        recordedChecksum == checksum || legacyChecksums.contains(recordedChecksum)
    }

    private static func computeChecksum(version: Int, description: String, statements: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let input = ([String(version), description] + statements).joined(separator: "\u{1f}")
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "fnv1a64:\(String(hash, radix: 16))"
    }
}

public struct MigrationRunner: Sendable {
    public static let latestSchemaVersion = 6

    public init() {}

    public func apply(to store: SQLiteStateStore) throws {
        try store.withConnection { connection in
            try apply(on: connection, throughVersion: Self.latestSchemaVersion)
        }
    }

    func apply(to store: SQLiteStateStore, throughVersion: Int) throws {
        try store.withConnection { connection in
            try apply(on: connection, throughVersion: throughVersion)
        }
    }

    public func appliedVersions(in store: SQLiteStateStore) throws -> [Int] {
        try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
            guard try migrationTableExists(on: connection) else {
                return []
            }
            let applied = try appliedMigrations(on: connection)
            try validateCompatibility(applied, requireLatest: false)
            return applied.keys.sorted()
        }
    }

    public func validateAppliedSchema(in store: SQLiteStateStore) throws {
        try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
            try validateAppliedSchema(on: connection)
        }
    }

    func apply(on connection: SQLiteConnection) throws {
        try apply(on: connection, throughVersion: Self.latestSchemaVersion)
    }

    func apply(on connection: SQLiteConnection, throughVersion: Int) throws {
        precondition((1...Self.latestSchemaVersion).contains(throughVersion))
        try connection.transaction {
            try ensureDatabaseIsMigratable(on: connection)
            let applied = try appliedMigrations(on: connection)
            try validateCompatibility(applied, requireLatest: false)

            for migration in Self.migrations where migration.version <= throughVersion {
                if let checksum = applied[migration.version] {
                    if !migration.accepts(recordedChecksum: checksum) {
                        throw StateStoreError.migrationFailed(
                            version: migration.version,
                            message: "Recorded checksum \(checksum) does not match expected checksum \(migration.checksum)."
                        )
                    }
                    continue
                }

                for statement in migration.statements {
                    try connection.execute(statement)
                }

                try connection.run(
                    """
                    INSERT INTO schema_migrations (version, description, checksum, applied_at)
                    VALUES (?, ?, ?, datetime('now'))
                    """,
                    bindings: [
                        .int(migration.version),
                        .text(migration.description),
                        .text(migration.checksum)
                    ]
                )
            }
        }
    }

    private func ensureDatabaseIsMigratable(on connection: SQLiteConnection) throws {
        if try migrationTableExists(on: connection) {
            return
        }

        let existingTables = try userTables(on: connection)
        guard existingTables.isEmpty else {
            throw StateStoreError.incompatibleSchema(
                foundVersion: nil,
                latestSupported: Self.latestSchemaVersion,
                message: "Database has existing non-Hostwright tables without schema_migrations: \(existingTables.joined(separator: ", ")). Refusing implicit migration."
            )
        }

        try ensureMigrationTable(on: connection)
    }

    func validateAppliedSchema(on connection: SQLiteConnection) throws {
        guard try migrationTableExists(on: connection) else {
            let existingTables = try userTables(on: connection)
            if existingTables.isEmpty {
                throw StateStoreError.incompatibleSchema(
                    foundVersion: 0,
                    latestSupported: Self.latestSchemaVersion,
                    message: "State database has not been migrated. Run the explicit migration path before reading or writing state."
                )
            }

            throw StateStoreError.incompatibleSchema(
                foundVersion: nil,
                latestSupported: Self.latestSchemaVersion,
                message: "Database has existing non-Hostwright tables without schema_migrations: \(existingTables.joined(separator: ", "))."
            )
        }

        let applied = try appliedMigrations(on: connection)
        try validateCompatibility(applied, requireLatest: true)
    }

    private func ensureMigrationTable(on connection: SQLiteConnection) throws {
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                description TEXT NOT NULL,
                checksum TEXT NOT NULL,
                applied_at TEXT NOT NULL
            )
            """
        )
    }

    private func migrationTableExists(on connection: SQLiteConnection) throws -> Bool {
        let rows = try connection.query(
            """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table' AND name = 'schema_migrations'
            """
        )
        return !rows.isEmpty
    }

    private func userTables(on connection: SQLiteConnection) throws -> [String] {
        let rows = try connection.query(
            """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table'
              AND name NOT LIKE 'sqlite_%'
            ORDER BY name ASC
            """
        )
        return rows.compactMap { $0.first ?? nil }
    }

    private func appliedMigrations(on connection: SQLiteConnection) throws -> [Int: String] {
        let rows = try connection.query(
            """
            SELECT version, checksum
            FROM schema_migrations
            ORDER BY version ASC
            """
        )

        var applied: [Int: String] = [:]
        for row in rows {
            guard row.count == 2,
                  let versionText = row[0],
                  let version = Int(versionText),
                  let checksum = row[1]
            else {
                throw StateStoreError.migrationFailed(version: 0, message: "Could not read migration table.")
            }
            applied[version] = checksum
        }
        return applied
    }

    private func validateCompatibility(_ applied: [Int: String], requireLatest: Bool) throws {
        let knownMigrations = Dictionary(uniqueKeysWithValues: Self.migrations.map { ($0.version, $0) })

        for (version, checksum) in applied.sorted(by: { $0.key < $1.key }) {
            guard let migration = knownMigrations[version] else {
                if version > Self.latestSchemaVersion {
                    throw StateStoreError.incompatibleSchema(
                        foundVersion: version,
                        latestSupported: Self.latestSchemaVersion,
                        message: "Database was migrated by a newer Hostwright release. Upgrade this binary before opening it."
                    )
                }

                throw StateStoreError.incompatibleSchema(
                    foundVersion: version,
                    latestSupported: Self.latestSchemaVersion,
                    message: "Database records an unknown migration version."
                )
            }

            if !migration.accepts(recordedChecksum: checksum) {
                throw StateStoreError.migrationFailed(
                    version: version,
                    message: "Recorded checksum \(checksum) does not match expected checksum \(migration.checksum)."
                )
            }
        }

        if let highestAppliedVersion = applied.keys.max() {
            let missingVersions = (1...highestAppliedVersion).filter { applied[$0] == nil }
            if !missingVersions.isEmpty {
                let missing = missingVersions.map(String.init).joined(separator: ", ")
                throw StateStoreError.incompatibleSchema(
                    foundVersion: highestAppliedVersion,
                    latestSupported: Self.latestSchemaVersion,
                    message: "Database has a non-contiguous Hostwright migration history. Missing applied version(s): \(missing). Refusing to infer or replay out-of-order migrations."
                )
            }
        }

        if requireLatest, (applied.keys.max() ?? 0) < Self.latestSchemaVersion {
            throw StateStoreError.incompatibleSchema(
                foundVersion: applied.keys.max() ?? 0,
                latestSupported: Self.latestSchemaVersion,
                message: "State database requires an explicit migration before this Hostwright release can read or write it."
            )
        }
    }

    private static let migrations: [SchemaMigration] = [
        SchemaMigration(
            version: 1,
            description: "Initial Hostwright state ledger schema",
            legacyChecksums: ["state-ledger-v1"],
            statements: [
                """
                CREATE TABLE IF NOT EXISTS projects (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    manifest_path TEXT,
                    manifest_hash TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS desired_services (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    service_name TEXT NOT NULL,
                    image TEXT NOT NULL,
                    command_json TEXT NOT NULL,
                    ports_json TEXT NOT NULL,
                    mounts_json TEXT NOT NULL,
                    env_json_redacted TEXT NOT NULL,
                    manifest_hash TEXT NOT NULL,
                    desired_generation INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(project_id, service_name, desired_generation)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS observed_runtime_snapshots (
                    id TEXT PRIMARY KEY,
                    project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
                    runtime_adapter TEXT NOT NULL,
                    runtime_name TEXT NOT NULL,
                    runtime_version TEXT,
                    observed_at TEXT NOT NULL,
                    parser_version TEXT NOT NULL,
                    raw_output_hash TEXT,
                    redacted_summary TEXT NOT NULL,
                    capabilities_json TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS observed_services (
                    id TEXT PRIMARY KEY,
                    snapshot_id TEXT NOT NULL REFERENCES observed_runtime_snapshots(id) ON DELETE CASCADE,
                    project_name TEXT NOT NULL,
                    service_name TEXT NOT NULL,
                    instance_name TEXT,
                    image TEXT,
                    lifecycle_state TEXT NOT NULL,
                    health_state TEXT NOT NULL,
                    ports_json TEXT NOT NULL,
                    mounts_json TEXT NOT NULL,
                    runtime_identifiers_json TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS event_ledger (
                    id TEXT PRIMARY KEY,
                    timestamp TEXT NOT NULL,
                    severity TEXT NOT NULL,
                    type TEXT NOT NULL,
                    source TEXT NOT NULL,
                    project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
                    service_name TEXT,
                    runtime_adapter TEXT,
                    message TEXT NOT NULL,
                    payload_json_redacted TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS operation_ledger (
                    id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    planned_action_type TEXT NOT NULL,
                    project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
                    service_name TEXT,
                    status TEXT NOT NULL,
                    idempotency_key TEXT NOT NULL,
                    plan_hash TEXT NOT NULL,
                    payload_json_redacted TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS ownership_records (
                    id TEXT PRIMARY KEY,
                    resource_identifier TEXT NOT NULL,
                    resource_type TEXT NOT NULL,
                    project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
                    service_name TEXT,
                    runtime_adapter TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    observed_at TEXT NOT NULL,
                    cleanup_eligible INTEGER NOT NULL DEFAULT 0,
                    metadata_json_redacted TEXT NOT NULL,
                    UNIQUE(resource_identifier, runtime_adapter)
                )
                """,
                "CREATE INDEX IF NOT EXISTS desired_services_project_idx ON desired_services(project_id)",
                "CREATE INDEX IF NOT EXISTS observed_services_snapshot_idx ON observed_services(snapshot_id)",
                "CREATE INDEX IF NOT EXISTS event_ledger_timestamp_idx ON event_ledger(timestamp)",
                "CREATE INDEX IF NOT EXISTS operation_ledger_project_idx ON operation_ledger(project_id)",
                "CREATE INDEX IF NOT EXISTS ownership_records_project_idx ON ownership_records(project_id)"
            ]
        ),
        SchemaMigration(
            version: 2,
            description: "Health results and restart policy state",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS health_check_results (
                    id TEXT PRIMARY KEY,
                    project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
                    service_name TEXT NOT NULL,
                    checked_at TEXT NOT NULL,
                    status TEXT NOT NULL,
                    exit_status INTEGER,
                    timed_out INTEGER NOT NULL DEFAULT 0,
                    command_json_redacted TEXT NOT NULL,
                    stdout_redacted TEXT NOT NULL,
                    stderr_redacted TEXT NOT NULL,
                    metadata_json_redacted TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS restart_policy_state (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    service_name TEXT NOT NULL,
                    policy TEXT NOT NULL,
                    status TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL,
                    max_attempts INTEGER NOT NULL,
                    backoff_seconds INTEGER NOT NULL,
                    backoff_until TEXT,
                    last_failure_at TEXT,
                    updated_at TEXT NOT NULL,
                    metadata_json_redacted TEXT NOT NULL,
                    UNIQUE(project_id, service_name)
                )
                """,
                "CREATE INDEX IF NOT EXISTS health_check_results_project_idx ON health_check_results(project_id, service_name)",
                "CREATE INDEX IF NOT EXISTS health_check_results_checked_at_idx ON health_check_results(checked_at)",
                "CREATE INDEX IF NOT EXISTS restart_policy_state_project_idx ON restart_policy_state(project_id, service_name)"
            ]
        ),
        SchemaMigration(
            version: 3,
            description: "Managed restart recovery records",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS restart_recovery_records (
                    id TEXT PRIMARY KEY,
                    operation_id TEXT NOT NULL,
                    project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
                    service_name TEXT NOT NULL,
                    resource_identifier TEXT NOT NULL,
                    plan_hash TEXT NOT NULL,
                    status TEXT NOT NULL,
                    completed_steps_json_redacted TEXT NOT NULL,
                    manual_recovery_hint_redacted TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    metadata_json_redacted TEXT NOT NULL
                )
                """,
                "CREATE INDEX IF NOT EXISTS restart_recovery_operation_idx ON restart_recovery_records(operation_id)",
                "CREATE INDEX IF NOT EXISTS restart_recovery_project_idx ON restart_recovery_records(project_id, service_name)"
            ]
        ),
        SchemaMigration(
            version: 4,
            description: "Operation recovery groups and checkpoints",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS operation_groups (
                    id TEXT PRIMARY KEY,
                    operation_id TEXT NOT NULL,
                    group_kind TEXT NOT NULL,
                    project_id TEXT,
                    service_name TEXT,
                    planned_action_type TEXT NOT NULL,
                    status TEXT NOT NULL,
                    group_idempotency_key TEXT NOT NULL,
                    plan_hash TEXT NOT NULL,
                    checkpoint TEXT NOT NULL,
                    lock_owner TEXT,
                    lock_expires_at TEXT,
                    rollback_available INTEGER NOT NULL DEFAULT 0,
                    manual_recovery_hint_redacted TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    metadata_json_redacted TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS operation_group_steps (
                    id TEXT PRIMARY KEY,
                    group_id TEXT NOT NULL,
                    step_key TEXT NOT NULL,
                    direction TEXT NOT NULL,
                    planned_action_type TEXT NOT NULL,
                    service_name TEXT,
                    resource_identifier TEXT,
                    step_idempotency_key TEXT NOT NULL,
                    status TEXT NOT NULL,
                    started_at TEXT,
                    updated_at TEXT NOT NULL,
                    finished_at TEXT,
                    last_error_redacted TEXT,
                    manual_recovery_hint_redacted TEXT NOT NULL,
                    metadata_json_redacted TEXT NOT NULL
                )
                """,
                "CREATE INDEX IF NOT EXISTS operation_groups_operation_idx ON operation_groups(operation_id)",
                "CREATE INDEX IF NOT EXISTS operation_groups_project_idx ON operation_groups(project_id, service_name)",
                "CREATE INDEX IF NOT EXISTS operation_groups_idempotency_idx ON operation_groups(group_idempotency_key)",
                "CREATE UNIQUE INDEX IF NOT EXISTS operation_groups_active_idempotency_idx ON operation_groups(group_idempotency_key) WHERE status = 'active'",
                "CREATE INDEX IF NOT EXISTS operation_groups_lock_idx ON operation_groups(lock_owner, lock_expires_at)",
                "CREATE INDEX IF NOT EXISTS operation_group_steps_group_idx ON operation_group_steps(group_id)",
                "CREATE INDEX IF NOT EXISTS operation_group_steps_idempotency_idx ON operation_group_steps(step_idempotency_key)"
            ]
        ),
        SchemaMigration(
            version: 5,
            description: "Backfill legacy ownership runtime adapter names",
            statements: [
                """
                DELETE FROM ownership_records
                WHERE runtime_adapter = 'runtime-adapter'
                  AND EXISTS (
                    SELECT 1
                    FROM ownership_records AS canonical
                    WHERE canonical.resource_identifier = ownership_records.resource_identifier
                      AND canonical.runtime_adapter = 'AppleContainerApplyAdapter'
                  )
                """,
                """
                UPDATE ownership_records
                SET runtime_adapter = 'AppleContainerApplyAdapter'
                WHERE runtime_adapter = 'runtime-adapter'
                """
            ]
        ),
        SchemaMigration(
            version: 6,
            description: "Versioned runtime identity and exact observation records",
            statements: [
                "ALTER TABLE observed_services ADD COLUMN resource_identifier TEXT NOT NULL DEFAULT ''",
                """
                UPDATE observed_services
                SET resource_identifier = 'hostwright-' || project_name || '-' || service_name
                WHERE resource_identifier = ''
                """,
                "ALTER TABLE observed_services ADD COLUMN networks_json TEXT NOT NULL DEFAULT '[]'",
                "ALTER TABLE ownership_records ADD COLUMN identity_version INTEGER NOT NULL DEFAULT 1"
            ]
        )
    ]
}
