public struct SchemaMigration: Equatable, Sendable {
    public let version: Int
    public let description: String
    public let checksum: String
    let statements: [String]

    public init(version: Int, description: String, checksum: String, statements: [String]) {
        self.version = version
        self.description = description
        self.checksum = checksum
        self.statements = statements
    }
}

public struct MigrationRunner: Sendable {
    public static let latestSchemaVersion = 1

    public init() {}

    public func apply(to store: SQLiteStateStore) throws {
        try store.withConnection { connection in
            try apply(on: connection)
        }
    }

    public func appliedVersions(in store: SQLiteStateStore) throws -> [Int] {
        try store.withConnection { connection in
            try ensureMigrationTable(on: connection)
            return try appliedMigrations(on: connection).keys.sorted()
        }
    }

    func apply(on connection: SQLiteConnection) throws {
        try connection.transaction {
            try ensureMigrationTable(on: connection)
            let applied = try appliedMigrations(on: connection)

            for migration in Self.migrations {
                if let checksum = applied[migration.version] {
                    if checksum != migration.checksum {
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

    private static let migrations: [SchemaMigration] = [
        SchemaMigration(
            version: 1,
            description: "Initial Hostwright state ledger schema",
            checksum: "state-ledger-v1",
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
        )
    ]
}
