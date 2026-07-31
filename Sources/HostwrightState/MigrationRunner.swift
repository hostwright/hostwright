import HostwrightCore
import HostwrightRuntime

public struct SchemaMigration: Equatable, Sendable {
    public let version: Int
    public let description: String
    public let checksum: String
    public let legacyChecksums: [String]
    public let implementationRevision: String?
    let statements: [String]
    let finalizationStatements: [String]

    public init(
        version: Int,
        description: String,
        legacyChecksums: [String] = [],
        implementationRevision: String? = nil,
        statements: [String],
        finalizationStatements: [String] = []
    ) {
        self.version = version
        self.description = description
        self.implementationRevision = implementationRevision
        var checksumInputs = statements + finalizationStatements
        if let implementationRevision {
            checksumInputs.append("hostwright:migration-implementation:\(implementationRevision)")
        }
        self.checksum = Self.computeChecksum(
            version: version,
            description: description,
            statements: checksumInputs
        )
        self.legacyChecksums = legacyChecksums
        self.statements = statements
        self.finalizationStatements = finalizationStatements
    }

    public init(
        version: Int,
        description: String,
        checksum: String,
        legacyChecksums: [String] = [],
        implementationRevision: String? = nil,
        statements: [String],
        finalizationStatements: [String] = []
    ) {
        self.version = version
        self.description = description
        self.checksum = checksum
        self.legacyChecksums = legacyChecksums
        self.implementationRevision = implementationRevision
        self.statements = statements
        self.finalizationStatements = finalizationStatements
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
    public static let latestSchemaVersion =
        HostwrightContractVersions.stateSchema
    static let applicationID = 0x48575254

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

    public func compatibleSchemaVersion(in store: SQLiteStateStore) throws -> Int {
        try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
            try compatibleSchemaVersion(on: connection)
        }
    }

    func compatibleSchemaVersion(on connection: SQLiteConnection) throws -> Int {
        try validateApplicationIdentity(on: connection, allowUnclaimed: true)
        try ensureDatabaseIsMigratable(on: connection)
        guard try migrationTableExists(on: connection) else { return 0 }
        let applied = try appliedMigrations(on: connection)
        try validateCompatibility(applied, requireLatest: false)
        return applied.keys.max() ?? 0
    }

    func apply(on connection: SQLiteConnection) throws {
        try apply(on: connection, throughVersion: Self.latestSchemaVersion)
    }

    func apply(on connection: SQLiteConnection, throughVersion: Int) throws {
        precondition((1...Self.latestSchemaVersion).contains(throughVersion))
        try connection.transaction {
            try validateApplicationIdentity(on: connection, allowUnclaimed: true)
            try ensureDatabaseIsMigratable(on: connection)
            let applied = try appliedMigrations(on: connection)
            try validateCompatibility(applied, requireLatest: false)
            try connection.execute("PRAGMA application_id = \(Self.applicationID)")

            for migration in Self.migrations where migration.version <= throughVersion {
                if let checksum = applied[migration.version] {
                    if !migration.accepts(recordedChecksum: checksum) {
                        throw StateStoreError.migrationFailed(
                            version: migration.version,
                            message: "Recorded checksum \(checksum) does not match expected checksum \(migration.checksum)."
                        )
                    }
                    if migration.version == 7, checksum != migration.checksum {
                        try backfillV7ProviderBindings(on: connection)
                        try connection.run(
                            "UPDATE schema_migrations SET checksum = ? WHERE version = 7",
                            bindings: [.text(migration.checksum)]
                        )
                    }
                    continue
                }

                for statement in migration.statements {
                    try connection.execute(statement)
                }

                if migration.version == 7 {
                    try backfillV7IdentityAndFencing(on: connection)
                }

                for statement in migration.finalizationStatements {
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
            try validateApplicationIdentity(on: connection, allowUnclaimed: false)
        }
    }

    func validateMigrationLedger(on connection: SQLiteConnection) throws {
        try validateApplicationIdentity(on: connection, allowUnclaimed: true)
        guard try migrationTableExists(on: connection) else {
            throw StateStoreError.incompatibleSchema(
                foundVersion: nil,
                latestSupported: Self.latestSchemaVersion,
                message: "The Hostwright schema_migrations ledger is missing."
            )
        }
        let applied = try appliedMigrations(on: connection)
        guard !applied.isEmpty else {
            throw StateStoreError.incompatibleSchema(
                foundVersion: 0,
                latestSupported: Self.latestSchemaVersion,
                message: "The Hostwright schema_migrations ledger contains no applied migration."
            )
        }
        try validateCompatibility(applied, requireLatest: false)
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

    private func backfillV7IdentityAndFencing(on connection: SQLiteConnection) throws {
        let projects = try connection.query("SELECT id FROM projects WHERE resource_uuid IS NULL OR resource_uuid = ''")
        for row in projects {
            guard let identifier = row.first ?? nil else {
                throw StateStoreError.migrationFailed(version: 7, message: "Could not backfill project resource UUID from a missing identifier.")
            }
            try connection.run(
                "UPDATE projects SET resource_uuid = ? WHERE id = ?",
                bindings: [
                    .text(HostwrightResourceUUID.legacy(kind: "project", identifier: identifier)),
                    .text(identifier)
                ]
            )
        }

        try backfillV7ProviderBindings(on: connection)

        let desiredServices = try connection.query(
            "SELECT id, project_id, service_name FROM desired_services WHERE resource_uuid IS NULL OR resource_uuid = ''"
        )
        for row in desiredServices {
            guard row.count == 3,
                  let identifier = row[0],
                  let projectID = row[1],
                  let serviceName = row[2] else {
                throw StateStoreError.migrationFailed(version: 7, message: "Could not backfill desired service resource UUID from an incomplete identity.")
            }
            try connection.run(
                "UPDATE desired_services SET resource_uuid = ? WHERE id = ?",
                bindings: [
                    .text(HostwrightResourceUUID.legacy(kind: "service", identifier: "\(projectID):\(serviceName)")),
                    .text(identifier)
                ]
            )
        }

        let ownershipRows = try connection.query(
            "SELECT id, project_id, service_name FROM ownership_records WHERE resource_uuid IS NULL OR resource_uuid = '' ORDER BY id"
        )
        var ownershipIdentityCounts: [String: Int] = [:]
        for row in ownershipRows {
            guard row.count == 3, let projectID = row[1], let serviceName = row[2] else {
                continue
            }
            ownershipIdentityCounts["\(projectID)\u{1f}\(serviceName)", default: 0] += 1
        }
        for row in ownershipRows {
            guard row.count == 3, let identifier = row[0] else {
                throw StateStoreError.migrationFailed(version: 7, message: "Could not backfill ownership resource UUID from a missing identifier.")
            }
            var resourceUUID = HostwrightResourceUUID.legacy(kind: "ownership", identifier: identifier)
            if let projectID = row[1], let serviceName = row[2] {
                let identityKey = "\(projectID)\u{1f}\(serviceName)"
                if ownershipIdentityCounts[identityKey] == 1,
                   let desiredUUID = try connection.query(
                    """
                    SELECT resource_uuid
                    FROM desired_services
                    WHERE project_id = ? AND service_name = ? AND resource_uuid IS NOT NULL AND resource_uuid != ''
                    ORDER BY desired_generation DESC, rowid DESC
                    LIMIT 1
                    """,
                    bindings: [.text(projectID), .text(serviceName)]
                   ).first?.first ?? nil {
                    resourceUUID = desiredUUID
                }
            }
            try connection.run(
                "UPDATE ownership_records SET resource_uuid = ? WHERE id = ?",
                bindings: [.text(resourceUUID), .text(identifier)]
            )
        }

        try connection.execute(
            """
            UPDATE desired_services
            SET mutation_provider = (
                SELECT projects.mutation_provider
                FROM projects
                WHERE projects.id = desired_services.project_id
            )
            WHERE mutation_provider IS NULL
            """
        )

        let ownershipFences = try connection.query("SELECT id FROM ownership_records WHERE fencing_token = ''")
        for row in ownershipFences {
            guard let identifier = row.first ?? nil else {
                throw StateStoreError.migrationFailed(version: 7, message: "Could not backfill ownership fencing from a missing identifier.")
            }
            try connection.run(
                "UPDATE ownership_records SET fencing_token = ? WHERE id = ?",
                bindings: [
                    .text(HostwrightResourceUUID.legacy(kind: "ownership-fence", identifier: identifier)),
                    .text(identifier)
                ]
            )
        }

        try connection.execute(
            """
            UPDATE ownership_records
            SET project_resource_uuid = (
                    SELECT projects.resource_uuid FROM projects WHERE projects.id = ownership_records.project_id
                ),
                project_generation = MAX(1, COALESCE((
                    SELECT MAX(desired_services.desired_generation)
                    FROM desired_services
                    WHERE desired_services.project_id = ownership_records.project_id
                ), 1)),
                provider_generation = MAX(1, COALESCE((
                    SELECT projects.provider_generation FROM projects WHERE projects.id = ownership_records.project_id
                ), 1))
            """
        )

        let groups = try connection.query("SELECT id FROM operation_groups WHERE fencing_token = ''")
        for row in groups {
            guard let identifier = row.first ?? nil else {
                throw StateStoreError.migrationFailed(version: 7, message: "Could not backfill operation fencing from a missing identifier.")
            }
            try connection.run(
                "UPDATE operation_groups SET fencing_token = ? WHERE id = ?",
                bindings: [
                    .text(HostwrightResourceUUID.legacy(kind: "operation-fence", identifier: identifier)),
                    .text(identifier)
                ]
            )
        }
    }

    private func backfillV7ProviderBindings(on connection: SQLiteConnection) throws {
        let rows = try connection.query(
            """
            SELECT project_id, runtime_adapter
            FROM ownership_records
            WHERE project_id IS NOT NULL
            ORDER BY project_id, runtime_adapter, id
            """
        )
        var providersByProject: [String: Set<RuntimeProviderID>] = [:]
        for row in rows {
            guard row.count == 2,
                  let projectID = row[0],
                  !projectID.isEmpty,
                  let runtimeAdapter = row[1],
                  let providerID = RuntimeProviderBinding.stableID(for: runtimeAdapter) else {
                let projectID = row.first.flatMap { $0 } ?? "unknown"
                let runtimeAdapter = row.count > 1 ? row[1] ?? "unknown" : "unknown"
                throw StateStoreError.migrationFailed(
                    version: 7,
                    message: "Could not derive a stable runtime provider for project \(projectID) from ownership adapter \(runtimeAdapter)."
                )
            }
            providersByProject[projectID, default: []].insert(providerID)
        }

        for projectID in providersByProject.keys.sorted() {
            let providers = providersByProject[projectID, default: []]
            guard providers.count == 1, let providerID = providers.first else {
                let values = providers.map(\.rawValue).sorted().joined(separator: ", ")
                throw StateStoreError.migrationFailed(
                    version: 7,
                    message: "Project \(projectID) has conflicting runtime providers: \(values)."
                )
            }
            try connection.run(
                """
                UPDATE projects
                SET mutation_provider = ?, provider_generation = MAX(1, provider_generation)
                WHERE id = ?
                """,
                bindings: [.text(providerID.rawValue), .text(projectID)]
            )
        }
    }

    func validateAppliedSchema(on connection: SQLiteConnection) throws {
        try validateApplicationIdentity(on: connection, allowUnclaimed: true)
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

    func applicationIdentity(on connection: SQLiteConnection) throws -> Int {
        guard let value = try connection.query("PRAGMA application_id").first?.first ?? nil,
              let applicationID = Int(value) else {
            throw StateStoreError.incompatibleSchema(
                foundVersion: nil,
                latestSupported: Self.latestSchemaVersion,
                message: "SQLite application ownership identity could not be read."
            )
        }
        return applicationID
    }

    private func validateApplicationIdentity(
        on connection: SQLiteConnection,
        allowUnclaimed: Bool
    ) throws {
        let applicationID = try applicationIdentity(on: connection)
        guard applicationID == Self.applicationID || (allowUnclaimed && applicationID == 0) else {
            throw StateStoreError.incompatibleSchema(
                foundVersion: nil,
                latestSupported: Self.latestSchemaVersion,
                message: "SQLite application_id \(applicationID) is not owned by Hostwright; refusing to read, claim, or mutate it."
            )
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
        ),
        SchemaMigration(
            version: 7,
            description: "Resource identity, provider binding, and durable saga contracts",
            legacyChecksums: ["fnv1a64:5bf70e7832651a2"],
            implementationRevision: "identity-fencing-provider-binding-backfill-v3",
            statements: [
                "ALTER TABLE projects ADD COLUMN resource_uuid TEXT",
                "ALTER TABLE projects ADD COLUMN manifest_version INTEGER NOT NULL DEFAULT 1",
                "ALTER TABLE projects ADD COLUMN mutation_provider TEXT",
                "ALTER TABLE projects ADD COLUMN provider_generation INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE desired_services ADD COLUMN resource_uuid TEXT",
                "ALTER TABLE desired_services ADD COLUMN resource_generation INTEGER NOT NULL DEFAULT 1",
                "ALTER TABLE desired_services ADD COLUMN mutation_provider TEXT",
                "ALTER TABLE ownership_records ADD COLUMN resource_uuid TEXT",
                "ALTER TABLE ownership_records ADD COLUMN resource_generation INTEGER NOT NULL DEFAULT 1",
                "ALTER TABLE ownership_records ADD COLUMN project_resource_uuid TEXT",
                "ALTER TABLE ownership_records ADD COLUMN project_generation INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE ownership_records ADD COLUMN provider_generation INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE ownership_records ADD COLUMN fencing_token TEXT NOT NULL DEFAULT ''",
                "ALTER TABLE operation_groups ADD COLUMN fencing_token TEXT NOT NULL DEFAULT ''",
                "ALTER TABLE operation_groups ADD COLUMN intent_json_redacted TEXT NOT NULL DEFAULT '{}'",
                "ALTER TABLE operation_groups ADD COLUMN compensation_json_redacted TEXT NOT NULL DEFAULT '[]'",
                "ALTER TABLE operation_groups ADD COLUMN verification_json_redacted TEXT NOT NULL DEFAULT '{}'"
            ],
            finalizationStatements: [
                "CREATE UNIQUE INDEX IF NOT EXISTS projects_resource_uuid_idx ON projects(resource_uuid)",
                "CREATE INDEX IF NOT EXISTS desired_services_resource_uuid_idx ON desired_services(resource_uuid)",
                "CREATE UNIQUE INDEX IF NOT EXISTS ownership_resource_uuid_idx ON ownership_records(resource_uuid)",
                "CREATE INDEX IF NOT EXISTS ownership_project_resource_uuid_idx ON ownership_records(project_resource_uuid)",
                "CREATE UNIQUE INDEX IF NOT EXISTS operation_groups_fencing_token_idx ON operation_groups(fencing_token)"
            ]
        ),
        SchemaMigration(
            version: 8,
            description: "Immutable desired and observed image digest locks",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS image_digest_locks (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    resource_uuid TEXT NOT NULL,
                    service_name TEXT NOT NULL,
                    replica_index INTEGER NOT NULL,
                    state_kind TEXT NOT NULL,
                    lock_schema_version INTEGER NOT NULL,
                    requested_reference TEXT NOT NULL,
                    resolved_reference TEXT NOT NULL,
                    descriptor_digest TEXT NOT NULL,
                    variant_digest TEXT NOT NULL,
                    operating_system TEXT NOT NULL,
                    architecture TEXT NOT NULL,
                    runtime_provider TEXT NOT NULL,
                    provider_generation INTEGER NOT NULL,
                    capability_sha256 TEXT NOT NULL,
                    plan_hash TEXT NOT NULL,
                    operation_group_id TEXT NOT NULL,
                    observation_sha256 TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(plan_hash, resource_uuid, state_kind)
                )
                """,
                "CREATE INDEX IF NOT EXISTS image_digest_locks_project_idx ON image_digest_locks(project_id, service_name, replica_index)",
                "CREATE INDEX IF NOT EXISTS image_digest_locks_resource_idx ON image_digest_locks(resource_uuid, state_kind)",
                "CREATE INDEX IF NOT EXISTS image_digest_locks_plan_idx ON image_digest_locks(plan_hash, state_kind)"
            ]
        ),
        SchemaMigration(
            version: 9,
            description: "Verified OCI referrer graphs and narrow retention",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS oci_referrer_discoveries (
                    id TEXT PRIMARY KEY,
                    registry_endpoint TEXT NOT NULL,
                    repository TEXT NOT NULL,
                    subject_digest TEXT NOT NULL,
                    artifact_type TEXT,
                    discovery_mode TEXT NOT NULL,
                    server_filter_applied INTEGER NOT NULL,
                    page_count INTEGER NOT NULL,
                    descriptor_count INTEGER NOT NULL,
                    graph_sha256 TEXT NOT NULL,
                    etag TEXT,
                    complete INTEGER NOT NULL,
                    observed_at TEXT NOT NULL,
                    UNIQUE(registry_endpoint, repository, subject_digest, graph_sha256)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS oci_referrers (
                    id TEXT PRIMARY KEY,
                    discovery_id TEXT NOT NULL REFERENCES oci_referrer_discoveries(id) ON DELETE CASCADE,
                    registry_endpoint TEXT NOT NULL,
                    repository TEXT NOT NULL,
                    subject_digest TEXT NOT NULL,
                    referrer_digest TEXT NOT NULL,
                    media_type TEXT NOT NULL,
                    artifact_type TEXT,
                    size_bytes INTEGER NOT NULL,
                    annotations_json TEXT NOT NULL,
                    verified_subject INTEGER NOT NULL,
                    observed_at TEXT NOT NULL,
                    UNIQUE(discovery_id, referrer_digest)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS oci_referrer_cache_objects (
                    digest TEXT PRIMARY KEY,
                    media_type TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL,
                    object_kind TEXT NOT NULL,
                    payload_base64 TEXT NOT NULL,
                    payload_sha256 TEXT NOT NULL,
                    children_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    last_accessed_at TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS oci_referrer_graph_objects (
                    discovery_id TEXT NOT NULL REFERENCES oci_referrer_discoveries(id) ON DELETE CASCADE,
                    referrer_digest TEXT NOT NULL,
                    object_digest TEXT NOT NULL REFERENCES oci_referrer_cache_objects(digest) ON DELETE RESTRICT,
                    PRIMARY KEY(discovery_id, referrer_digest, object_digest)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS oci_referrer_retention_leases (
                    id TEXT PRIMARY KEY,
                    discovery_id TEXT NOT NULL REFERENCES oci_referrer_discoveries(id) ON DELETE CASCADE,
                    owner_id TEXT NOT NULL,
                    fencing_token TEXT NOT NULL,
                    acquired_at TEXT NOT NULL,
                    expires_at TEXT NOT NULL,
                    released_at TEXT,
                    UNIQUE(fencing_token)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS oci_referrer_publications (
                    id TEXT PRIMARY KEY,
                    registry_endpoint TEXT NOT NULL,
                    repository TEXT NOT NULL,
                    subject_digest TEXT NOT NULL,
                    referrer_digest TEXT NOT NULL,
                    ownership_proof_sha256 TEXT NOT NULL,
                    operation_group_id TEXT NOT NULL,
                    cleanup_eligible INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    observed_at TEXT NOT NULL,
                    UNIQUE(registry_endpoint, repository, subject_digest, referrer_digest)
                )
                """,
                "CREATE INDEX IF NOT EXISTS oci_referrer_discoveries_subject_idx ON oci_referrer_discoveries(registry_endpoint, repository, subject_digest, observed_at)",
                "CREATE INDEX IF NOT EXISTS oci_referrers_subject_idx ON oci_referrers(registry_endpoint, repository, subject_digest, referrer_digest)",
                "CREATE INDEX IF NOT EXISTS oci_referrer_graph_object_idx ON oci_referrer_graph_objects(object_digest)",
                "CREATE INDEX IF NOT EXISTS oci_referrer_leases_active_idx ON oci_referrer_retention_leases(discovery_id, released_at, expires_at)",
                "CREATE INDEX IF NOT EXISTS oci_referrer_publications_cleanup_idx ON oci_referrer_publications(cleanup_eligible, registry_endpoint, repository, subject_digest)"
            ]
        ),
        SchemaMigration(
            version: 10,
            description: "Exact image trust evidence, exceptions, and subject manifest cache",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS image_trust_exceptions (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    service_name TEXT NOT NULL,
                    descriptor_digest TEXT NOT NULL,
                    policy_sha256 TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    approver TEXT NOT NULL,
                    approved_at TEXT NOT NULL,
                    expires_at TEXT NOT NULL,
                    revoked_at TEXT,
                    idempotency_key TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS image_trust_verifications (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    service_name TEXT NOT NULL,
                    descriptor_digest TEXT NOT NULL,
                    policy_sha256 TEXT NOT NULL,
                    evidence_graph_sha256 TEXT NOT NULL,
                    evidence_discovery_id TEXT NOT NULL REFERENCES oci_referrer_discoveries(id) ON DELETE RESTRICT,
                    trusted_root_sha256 TEXT NOT NULL,
                    verifier_version TEXT NOT NULL,
                    matched_authority_ids_json TEXT NOT NULL,
                    threshold INTEGER NOT NULL,
                    outcome TEXT NOT NULL CHECK (outcome IN ('passed', 'threshold-not-met')),
                    exception_id TEXT REFERENCES image_trust_exceptions(id) ON DELETE RESTRICT,
                    operation_group_id TEXT NOT NULL REFERENCES operation_groups(id) ON DELETE RESTRICT,
                    created_at TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS image_trust_subject_manifests (
                    id TEXT PRIMARY KEY,
                    registry_endpoint TEXT NOT NULL,
                    repository TEXT NOT NULL,
                    descriptor_digest TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL,
                    payload_base64 TEXT NOT NULL,
                    payload_sha256 TEXT NOT NULL,
                    observed_at TEXT NOT NULL
                )
                """,
                "CREATE UNIQUE INDEX IF NOT EXISTS image_trust_exceptions_idempotency_idx ON image_trust_exceptions(idempotency_key)",
                "CREATE INDEX IF NOT EXISTS image_trust_exceptions_active_lookup_idx ON image_trust_exceptions(project_id, service_name, descriptor_digest, policy_sha256, approved_at, expires_at, revoked_at)",
                "CREATE INDEX IF NOT EXISTS image_trust_verifications_lookup_idx ON image_trust_verifications(project_id, service_name, descriptor_digest, created_at)",
                "CREATE INDEX IF NOT EXISTS image_trust_verifications_operation_idx ON image_trust_verifications(operation_group_id, created_at)",
                "CREATE UNIQUE INDEX IF NOT EXISTS image_trust_subject_manifests_lookup_idx ON image_trust_subject_manifests(registry_endpoint, repository, descriptor_digest)"
            ]
        ),
        SchemaMigration(
            version: 11,
            description: "Immutable normalized image SBOM evidence records",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS image_sbom_records (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    service_name TEXT NOT NULL,
                    descriptor_digest TEXT NOT NULL,
                    policy_sha256 TEXT NOT NULL,
                    format TEXT NOT NULL CHECK (
                        format IN ('spdx-json', 'cyclonedx-json')
                    ),
                    document_digest TEXT NOT NULL,
                    document_media_type TEXT NOT NULL,
                    evidence_discovery_id TEXT NOT NULL REFERENCES oci_referrer_discoveries(id) ON DELETE RESTRICT,
                    evidence_graph_sha256 TEXT NOT NULL,
                    sbom_referrer_digest TEXT NOT NULL,
                    provenance_descriptor_digest TEXT,
                    provenance_referrer_digest TEXT,
                    component_count INTEGER NOT NULL,
                    normalized_components_sha256 TEXT NOT NULL,
                    operation_group_id TEXT NOT NULL REFERENCES operation_groups(id) ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    CHECK (
                        (provenance_descriptor_digest IS NULL AND provenance_referrer_digest IS NULL)
                        OR (provenance_descriptor_digest IS NOT NULL AND provenance_referrer_digest IS NOT NULL)
                    )
                )
                """,
                "CREATE INDEX IF NOT EXISTS image_sbom_records_subject_idx ON image_sbom_records(project_id, service_name, descriptor_digest, policy_sha256, created_at)",
                "CREATE INDEX IF NOT EXISTS image_sbom_records_operation_idx ON image_sbom_records(operation_group_id, created_at)",
                "CREATE INDEX IF NOT EXISTS image_sbom_records_sbom_cleanup_idx ON image_sbom_records(evidence_discovery_id, sbom_referrer_digest)",
                "CREATE INDEX IF NOT EXISTS image_sbom_records_provenance_cleanup_idx ON image_sbom_records(evidence_discovery_id, provenance_referrer_digest)"
            ]
        ),
        SchemaMigration(
            version: 12,
            description: "Signed vulnerability reports, explainable decisions, and exact exceptions",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS image_vulnerability_reports (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    service_name TEXT NOT NULL,
                    descriptor_digest TEXT NOT NULL,
                    report_digest TEXT NOT NULL,
                    report_referrer_digest TEXT NOT NULL,
                    evidence_discovery_id TEXT NOT NULL REFERENCES oci_referrer_discoveries(id) ON DELETE RESTRICT,
                    evidence_graph_sha256 TEXT NOT NULL,
                    database_id TEXT NOT NULL,
                    database_version TEXT NOT NULL,
                    database_updated_at TEXT NOT NULL,
                    generated_at TEXT NOT NULL,
                    signature_policy_sha256 TEXT NOT NULL,
                    signature_proof_json TEXT NOT NULL,
                    signature_proof_sha256 TEXT NOT NULL,
                    operation_group_id TEXT NOT NULL REFERENCES operation_groups(id) ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    UNIQUE (
                        project_id, service_name, descriptor_digest,
                        report_digest, report_referrer_digest,
                        evidence_discovery_id, evidence_graph_sha256,
                        signature_policy_sha256
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS image_vulnerability_exceptions (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    service_name TEXT NOT NULL,
                    descriptor_digest TEXT NOT NULL,
                    decision_id TEXT NOT NULL REFERENCES image_vulnerability_decisions(id) ON DELETE RESTRICT,
                    decision_digest TEXT NOT NULL,
                    report_id TEXT NOT NULL REFERENCES image_vulnerability_reports(id) ON DELETE RESTRICT,
                    report_digest TEXT NOT NULL,
                    report_referrer_digest TEXT NOT NULL,
                    policy_sha256 TEXT NOT NULL,
                    signature_policy_sha256 TEXT NOT NULL,
                    database_id TEXT NOT NULL,
                    database_version TEXT NOT NULL,
                    blocked_findings_sha256 TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    approver TEXT NOT NULL,
                    approved_at TEXT NOT NULL,
                    expires_at TEXT NOT NULL,
                    revoked_at TEXT,
                    idempotency_key TEXT NOT NULL,
                    operation_group_id TEXT NOT NULL REFERENCES operation_groups(id) ON DELETE RESTRICT,
                    CHECK (expires_at > approved_at),
                    CHECK (revoked_at IS NULL OR revoked_at >= approved_at)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS image_vulnerability_decisions (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    service_name TEXT NOT NULL,
                    descriptor_digest TEXT NOT NULL,
                    decision_digest TEXT NOT NULL,
                    report_id TEXT REFERENCES image_vulnerability_reports(id) ON DELETE RESTRICT,
                    policy_sha256 TEXT NOT NULL,
                    signature_policy_sha256 TEXT NOT NULL,
                    evaluator_version TEXT NOT NULL,
                    evaluated_at TEXT NOT NULL,
                    freshness TEXT NOT NULL CHECK (
                        freshness IN ('fresh', 'stale', 'unavailable')
                    ),
                    data_age_seconds INTEGER,
                    candidate_findings_json TEXT NOT NULL,
                    candidate_findings_sha256 TEXT NOT NULL,
                    allowlisted_findings_json TEXT NOT NULL,
                    allowlisted_findings_sha256 TEXT NOT NULL,
                    blocking_findings_json TEXT NOT NULL,
                    blocking_findings_sha256 TEXT NOT NULL,
                    outcome TEXT NOT NULL CHECK (
                        outcome IN ('allowed', 'blocked')
                    ),
                    reason_codes_json TEXT NOT NULL,
                    reason_codes_sha256 TEXT NOT NULL,
                    operation_group_id TEXT NOT NULL REFERENCES operation_groups(id) ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    CHECK (
                        (freshness = 'unavailable'
                            AND report_id IS NULL
                            AND data_age_seconds IS NULL)
                        OR
                        (freshness IN ('fresh', 'stale')
                            AND report_id IS NOT NULL
                            AND data_age_seconds >= 0
                            AND data_age_seconds <= 31536000)
                    )
                )
                """,
                "CREATE INDEX IF NOT EXISTS image_vulnerability_reports_subject_idx ON image_vulnerability_reports(project_id, service_name, descriptor_digest, database_id, database_version, created_at)",
                "CREATE INDEX IF NOT EXISTS image_vulnerability_reports_cleanup_idx ON image_vulnerability_reports(evidence_discovery_id, report_referrer_digest)",
                "CREATE UNIQUE INDEX IF NOT EXISTS image_vulnerability_exceptions_idempotency_idx ON image_vulnerability_exceptions(idempotency_key)",
                "CREATE INDEX IF NOT EXISTS image_vulnerability_exceptions_active_idx ON image_vulnerability_exceptions(project_id, service_name, descriptor_digest, decision_id, decision_digest, report_id, report_digest, report_referrer_digest, policy_sha256, signature_policy_sha256, database_id, database_version, blocked_findings_sha256, approved_at, expires_at, revoked_at)",
                "CREATE INDEX IF NOT EXISTS image_vulnerability_decisions_subject_idx ON image_vulnerability_decisions(project_id, service_name, descriptor_digest, policy_sha256, evaluated_at)",
                "CREATE INDEX IF NOT EXISTS image_vulnerability_decisions_report_idx ON image_vulnerability_decisions(report_id, evaluated_at)",
                "CREATE INDEX IF NOT EXISTS image_vulnerability_decisions_operation_idx ON image_vulnerability_decisions(operation_group_id, created_at)"
            ]
        ),
        SchemaMigration(
            version: 13,
            description: "Immutable exact-image build provenance evidence",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS image_provenance_records (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
                    service_name TEXT NOT NULL,
                    descriptor_digest TEXT NOT NULL,
                    policy_sha256 TEXT NOT NULL,
                    statement_digest TEXT NOT NULL,
                    envelope_digest TEXT NOT NULL,
                    referrer_digest TEXT NOT NULL,
                    evidence_discovery_id TEXT NOT NULL REFERENCES oci_referrer_discoveries(id) ON DELETE RESTRICT,
                    evidence_graph_sha256 TEXT NOT NULL,
                    source_uri TEXT NOT NULL,
                    source_digest TEXT NOT NULL,
                    builder_id TEXT NOT NULL,
                    builder_version TEXT NOT NULL,
                    build_type TEXT NOT NULL,
                    invocation_id TEXT NOT NULL,
                    normalized_materials_sha256 TEXT NOT NULL,
                    command_sha256 TEXT NOT NULL,
                    environment_policy_sha256 TEXT NOT NULL,
                    started_at TEXT NOT NULL,
                    finished_at TEXT NOT NULL,
                    reproducibility_status TEXT NOT NULL CHECK (
                        reproducibility_status IN (
                            'verified', 'not-verified'
                        )
                    ),
                    comparison_digest TEXT,
                    signer_id TEXT NOT NULL,
                    signer_public_key_sha256 TEXT NOT NULL,
                    signature_sha256 TEXT NOT NULL,
                    verifier_version TEXT NOT NULL,
                    verified_at TEXT NOT NULL,
                    operation_group_id TEXT NOT NULL REFERENCES operation_groups(id) ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    CHECK (
                        (reproducibility_status = 'verified'
                            AND comparison_digest IS NOT NULL)
                        OR
                        (reproducibility_status = 'not-verified'
                            AND comparison_digest IS NULL)
                    )
                )
                """,
                "CREATE INDEX IF NOT EXISTS image_provenance_records_subject_idx ON image_provenance_records(project_id, service_name, descriptor_digest, policy_sha256, verified_at)",
                "CREATE INDEX IF NOT EXISTS image_provenance_records_operation_idx ON image_provenance_records(operation_group_id, created_at)",
                "CREATE INDEX IF NOT EXISTS image_provenance_records_cleanup_idx ON image_provenance_records(evidence_discovery_id, referrer_digest)",
                "CREATE INDEX IF NOT EXISTS image_provenance_records_statement_idx ON image_provenance_records(statement_digest, envelope_digest, referrer_digest)"
            ]
        ),
        SchemaMigration(
            version: 14,
            description: "Bounded content accounting and fenced cache leases",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS content_cache_objects (
                    provider_scope TEXT NOT NULL,
                    digest TEXT NOT NULL,
                    content_kind TEXT NOT NULL CHECK (
                        content_kind IN (
                            'runtime-image', 'oci-cache-object'
                        )
                    ),
                    size_bytes INTEGER NOT NULL CHECK (
                        size_bytes >= 0
                        AND size_bytes <= 1099511627776
                    ),
                    pin_policy TEXT NOT NULL CHECK (
                        pin_policy IN (
                            'unpinned', 'operator', 'policy'
                        )
                    ),
                    created_at TEXT NOT NULL,
                    observed_at TEXT NOT NULL,
                    last_used_at TEXT NOT NULL,
                    PRIMARY KEY(provider_scope, digest),
                    CHECK (
                        length(provider_scope) BETWEEN 1 AND 256
                        AND provider_scope
                            NOT GLOB '*[^A-Za-z0-9._:/-]*'
                        AND substr(provider_scope, 1, 1)
                            GLOB '[A-Za-z0-9]'
                    ),
                    CHECK (
                        length(digest) = 71
                        AND substr(digest, 1, 7) = 'sha256:'
                        AND substr(digest, 8) NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        created_at != ''
                        AND observed_at != ''
                        AND last_used_at != ''
                        AND julianday(created_at) IS NOT NULL
                        AND julianday(observed_at) IS NOT NULL
                        AND julianday(last_used_at) IS NOT NULL
                        AND julianday(observed_at)
                            >= julianday(created_at)
                        AND julianday(last_used_at)
                            >= julianday(created_at)
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS content_cache_references (
                    id TEXT PRIMARY KEY,
                    provider_scope TEXT NOT NULL,
                    reference TEXT NOT NULL,
                    digest TEXT NOT NULL,
                    ownership_operation_id TEXT NOT NULL,
                    ownership_proof_sha256 TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    observed_at TEXT NOT NULL,
                    FOREIGN KEY(provider_scope, digest)
                        REFERENCES content_cache_objects(
                            provider_scope, digest
                        ) ON DELETE RESTRICT,
                    UNIQUE(provider_scope, reference),
                    CHECK (
                        length(id) = 36
                        AND substr(id, 9, 1) = '-'
                        AND substr(id, 14, 1) = '-'
                        AND substr(id, 19, 1) = '-'
                        AND substr(id, 24, 1) = '-'
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(provider_scope) BETWEEN 1 AND 256
                        AND provider_scope
                            NOT GLOB '*[^A-Za-z0-9._:/-]*'
                        AND substr(provider_scope, 1, 1)
                            GLOB '[A-Za-z0-9]'
                    ),
                    CHECK (
                        length(reference) BETWEEN 1 AND 1024
                    ),
                    CHECK (
                        length(digest) = 71
                        AND substr(digest, 1, 7) = 'sha256:'
                        AND substr(digest, 8) NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(ownership_operation_id) = 36
                        AND substr(
                            ownership_operation_id, 9, 1
                        ) = '-'
                        AND substr(
                            ownership_operation_id, 14, 1
                        ) = '-'
                        AND substr(
                            ownership_operation_id, 19, 1
                        ) = '-'
                        AND substr(
                            ownership_operation_id, 24, 1
                        ) = '-'
                        AND replace(
                            ownership_operation_id, '-', ''
                        ) NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(ownership_proof_sha256) = 64
                        AND ownership_proof_sha256
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        created_at != '' AND observed_at != ''
                        AND julianday(created_at) IS NOT NULL
                        AND julianday(observed_at) IS NOT NULL
                        AND julianday(observed_at)
                            >= julianday(created_at)
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS content_cache_leases (
                    id TEXT PRIMARY KEY,
                    provider_scope TEXT NOT NULL,
                    digest TEXT NOT NULL,
                    reference TEXT,
                    mode TEXT NOT NULL CHECK (
                        mode IN ('shared', 'exclusive-delete')
                    ),
                    owner_id TEXT NOT NULL,
                    purpose TEXT NOT NULL,
                    fencing_token TEXT NOT NULL UNIQUE,
                    acquired_at TEXT NOT NULL,
                    expires_at TEXT NOT NULL,
                    released_at TEXT,
                    CHECK (
                        length(id) = 36
                        AND substr(id, 9, 1) = '-'
                        AND substr(id, 14, 1) = '-'
                        AND substr(id, 19, 1) = '-'
                        AND substr(id, 24, 1) = '-'
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(provider_scope) BETWEEN 1 AND 256
                        AND provider_scope
                            NOT GLOB '*[^A-Za-z0-9._:/-]*'
                        AND substr(provider_scope, 1, 1)
                            GLOB '[A-Za-z0-9]'
                    ),
                    CHECK (
                        length(digest) = 71
                        AND substr(digest, 1, 7) = 'sha256:'
                        AND substr(digest, 8) NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        reference IS NULL
                        OR length(reference) BETWEEN 1 AND 1024
                    ),
                    CHECK (
                        length(owner_id) BETWEEN 1 AND 128
                        AND owner_id NOT GLOB '*[^ -~]*'
                    ),
                    CHECK (
                        length(purpose) BETWEEN 1 AND 128
                        AND purpose NOT GLOB '*[^ -~]*'
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND substr(fencing_token, 9, 1) = '-'
                        AND substr(fencing_token, 14, 1) = '-'
                        AND substr(fencing_token, 19, 1) = '-'
                        AND substr(fencing_token, 24, 1) = '-'
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        acquired_at != ''
                        AND expires_at != ''
                        AND julianday(acquired_at) IS NOT NULL
                        AND julianday(expires_at) IS NOT NULL
                        AND julianday(expires_at)
                            > julianday(acquired_at)
                        AND (
                            julianday(expires_at)
                              - julianday(acquired_at)
                        ) * 86400.0 <= 86400.001
                    ),
                    CHECK (
                        released_at IS NULL OR (
                            julianday(released_at) IS NOT NULL
                            AND julianday(released_at)
                              >= julianday(acquired_at)
                        )
                    )
                )
                """,
                """
                INSERT OR IGNORE INTO content_cache_objects (
                    provider_scope, digest, content_kind, size_bytes,
                    pin_policy, created_at, observed_at, last_used_at
                )
                SELECT
                    'oci-referrer-cache', digest, 'oci-cache-object',
                    size_bytes, 'unpinned', created_at,
                    last_accessed_at, last_accessed_at
                FROM oci_referrer_cache_objects
                """,
                """
                CREATE TRIGGER IF NOT EXISTS
                    content_cache_reference_exclusive_guard
                BEFORE INSERT ON content_cache_references
                WHEN EXISTS (
                    SELECT 1 FROM content_cache_leases
                    WHERE provider_scope = NEW.provider_scope
                      AND mode = 'exclusive-delete'
                      AND released_at IS NULL
                      AND expires_at > NEW.observed_at
                      AND (
                          digest = NEW.digest
                          OR reference = NEW.reference
                      )
                )
                BEGIN
                    SELECT RAISE(
                        ABORT,
                        'active exclusive deletion lease'
                    );
                END
                """,
                """
                CREATE TRIGGER IF NOT EXISTS
                    content_cache_lease_conflict_guard
                BEFORE INSERT ON content_cache_leases
                WHEN (
                    NEW.mode = 'exclusive-delete'
                    AND (
                        EXISTS (
                            SELECT 1 FROM content_cache_objects
                            WHERE provider_scope = NEW.provider_scope
                              AND digest = NEW.digest
                              AND pin_policy != 'unpinned'
                        )
                        OR EXISTS (
                            SELECT 1 FROM content_cache_leases
                            WHERE provider_scope = NEW.provider_scope
                              AND released_at IS NULL
                              AND expires_at > NEW.acquired_at
                              AND (
                                  digest = NEW.digest
                                  OR (
                                      NEW.reference IS NOT NULL
                                      AND reference = NEW.reference
                                  )
                              )
                        )
                    )
                ) OR (
                    NEW.mode = 'shared'
                    AND EXISTS (
                        SELECT 1 FROM content_cache_leases
                        WHERE provider_scope = NEW.provider_scope
                          AND mode = 'exclusive-delete'
                          AND released_at IS NULL
                          AND expires_at > NEW.acquired_at
                          AND (
                              digest = NEW.digest
                              OR (
                                  NEW.reference IS NOT NULL
                                  AND reference = NEW.reference
                              )
                          )
                    )
                )
                BEGIN
                    SELECT RAISE(ABORT, 'content lease conflict');
                END
                """,
                "CREATE INDEX IF NOT EXISTS content_cache_objects_pressure_idx ON content_cache_objects(pin_policy, last_used_at, provider_scope, digest)",
                "CREATE INDEX IF NOT EXISTS content_cache_references_digest_idx ON content_cache_references(provider_scope, digest, reference)",
                "CREATE INDEX IF NOT EXISTS content_cache_references_operation_idx ON content_cache_references(ownership_operation_id, ownership_proof_sha256)",
                "CREATE INDEX IF NOT EXISTS content_cache_leases_digest_active_idx ON content_cache_leases(provider_scope, digest, released_at, expires_at)",
                "CREATE INDEX IF NOT EXISTS content_cache_leases_reference_active_idx ON content_cache_leases(provider_scope, reference, released_at, expires_at)",
                "CREATE INDEX IF NOT EXISTS content_cache_leases_owner_active_idx ON content_cache_leases(owner_id, released_at, expires_at)"
            ]
        ),
        SchemaMigration(
            version: 15,
            description: "Fenced local storage controller and node state",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS storage_volumes (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    provider_id TEXT NOT NULL,
                    provider_volume_id TEXT NOT NULL,
                    topology_node_id TEXT NOT NULL,
                    generation INTEGER NOT NULL CHECK (
                        generation >= 1
                    ),
                    fencing_token TEXT NOT NULL,
                    capacity_bytes INTEGER NOT NULL CHECK (
                        capacity_bytes >= 1
                        AND capacity_bytes <= 1125899906842624
                    ),
                    lifecycle_state TEXT NOT NULL CHECK (
                        lifecycle_state IN (
                            'creating', 'available', 'expanding',
                            'deleting', 'deleted', 'faulted'
                        )
                    ),
                    reclaim_policy TEXT NOT NULL CHECK (
                        reclaim_policy IN (
                            'retain', 'delete',
                            'snapshot-before-delete',
                            'backup-before-delete', 'recycle'
                        )
                    ),
                    access_mode TEXT NOT NULL CHECK (
                        access_mode IN (
                            'read-write-once', 'read-only-many'
                        )
                    ),
                    source_kind TEXT CHECK (
                        source_kind IS NULL
                        OR source_kind IN (
                            'volume', 'snapshot', 'backup'
                        )
                    ),
                    source_id TEXT,
                    operation_group_id TEXT NOT NULL
                        REFERENCES operation_groups(id)
                        ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(provider_id, provider_volume_id),
                    UNIQUE(project_id, name),
                    CHECK (
                        length(id) = 36
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(project_id) BETWEEN 1 AND 256
                        AND project_id
                            NOT GLOB '*[^A-Za-z0-9._:/-]*'
                    ),
                    CHECK (
                        length(name) BETWEEN 1 AND 128
                        AND name NOT GLOB '*[^A-Za-z0-9._-]*'
                    ),
                    CHECK (
                        length(provider_id) BETWEEN 1 AND 256
                        AND provider_id
                            NOT GLOB '*[^A-Za-z0-9._:/-]*'
                    ),
                    CHECK (
                        length(provider_volume_id) BETWEEN 1 AND 512
                        AND provider_volume_id NOT GLOB '*[^ -~]*'
                    ),
                    CHECK (
                        length(topology_node_id) BETWEEN 1 AND 128
                        AND topology_node_id
                            NOT GLOB '*[^A-Za-z0-9._:/-]*'
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        (source_kind IS NULL AND source_id IS NULL)
                        OR (
                            source_kind IS NOT NULL
                            AND length(source_id) = 36
                            AND replace(source_id, '-', '')
                                NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    CHECK (
                        created_at != '' AND updated_at != ''
                        AND julianday(created_at) IS NOT NULL
                        AND julianday(updated_at) IS NOT NULL
                        AND julianday(updated_at)
                            >= julianday(created_at)
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS storage_attachments (
                    id TEXT PRIMARY KEY,
                    volume_id TEXT NOT NULL
                        REFERENCES storage_volumes(id)
                        ON DELETE RESTRICT,
                    node_id TEXT NOT NULL,
                    node_uuid TEXT NOT NULL,
                    workload_uuid TEXT NOT NULL,
                    attachment_kind TEXT NOT NULL CHECK (
                        attachment_kind IN ('stage', 'publish')
                    ),
                    path TEXT NOT NULL,
                    staging_path TEXT,
                    access_mode TEXT NOT NULL CHECK (
                        access_mode IN (
                            'read-write-once', 'read-only-many'
                        )
                    ),
                    read_only INTEGER NOT NULL CHECK (
                        read_only IN (0, 1)
                    ),
                    generation INTEGER NOT NULL CHECK (
                        generation >= 1
                    ),
                    fencing_token TEXT NOT NULL,
                    lifecycle_state TEXT NOT NULL CHECK (
                        lifecycle_state IN (
                            'attaching', 'attached', 'detaching',
                            'detached', 'faulted',
                            'ambiguous-hold'
                        )
                    ),
                    checkpoint TEXT NOT NULL CHECK (
                        checkpoint IN (
                            'attach-intent-persisted',
                            'attach-fence-acquired',
                            'attach-provider-effect-requested',
                            'attach-provider-observed',
                            'attached-committed',
                            'detach-intent-persisted',
                            'detach-fence-acquired',
                            'detach-provider-effect-requested',
                            'detach-provider-absent-observed',
                            'detached-committed'
                        )
                    ),
                    lease_renewed_at TEXT NOT NULL,
                    lease_expires_at TEXT NOT NULL,
                    operation_id TEXT NOT NULL,
                    idempotency_key TEXT NOT NULL,
                    provider_observation_sha256 TEXT,
                    force_detach_authorization_sha256 TEXT,
                    ambiguous_hold_reason_redacted TEXT,
                    operation_group_id TEXT NOT NULL
                        REFERENCES operation_groups(id)
                        ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(
                        volume_id, node_uuid, workload_uuid,
                        attachment_kind, path
                    ),
                    CHECK (
                        length(id) = 36
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(node_id) BETWEEN 1 AND 128
                        AND node_id NOT GLOB '*[^A-Za-z0-9._:/-]*'
                    ),
                    CHECK (
                        length(node_uuid) = 36
                        AND substr(node_uuid, 9, 1) = '-'
                        AND substr(node_uuid, 14, 1) = '-'
                        AND substr(node_uuid, 19, 1) = '-'
                        AND substr(node_uuid, 24, 1) = '-'
                        AND replace(node_uuid, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(workload_uuid) = 36
                        AND substr(workload_uuid, 9, 1) = '-'
                        AND substr(workload_uuid, 14, 1) = '-'
                        AND substr(workload_uuid, 19, 1) = '-'
                        AND substr(workload_uuid, 24, 1) = '-'
                        AND replace(workload_uuid, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(path) BETWEEN 1 AND 4096
                        AND substr(path, 1, 1) = '/'
                        AND path NOT GLOB '*[^ -~]*'
                    ),
                    CHECK (
                        (attachment_kind = 'stage'
                            AND staging_path IS NULL
                            AND read_only = 0)
                        OR
                        (attachment_kind = 'publish'
                            AND staging_path IS NOT NULL
                            AND length(staging_path) BETWEEN 1 AND 4096
                            AND substr(staging_path, 1, 1) = '/')
                    ),
                    CHECK (
                        access_mode != 'read-only-many'
                        OR read_only = 1
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(operation_id) = 36
                        AND substr(operation_id, 9, 1) = '-'
                        AND substr(operation_id, 14, 1) = '-'
                        AND substr(operation_id, 19, 1) = '-'
                        AND substr(operation_id, 24, 1) = '-'
                        AND replace(operation_id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(idempotency_key) = 64
                        AND idempotency_key
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        provider_observation_sha256 IS NULL
                        OR (
                            length(provider_observation_sha256) = 64
                            AND provider_observation_sha256
                                NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    CHECK (
                        force_detach_authorization_sha256 IS NULL
                        OR (
                            length(
                                force_detach_authorization_sha256
                            ) = 64
                            AND force_detach_authorization_sha256
                                NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    CHECK (
                        (
                            lifecycle_state = 'ambiguous-hold'
                            AND ambiguous_hold_reason_redacted
                                IS NOT NULL
                            AND length(
                                ambiguous_hold_reason_redacted
                            ) BETWEEN 1 AND 512
                            AND checkpoint IN (
                                'attach-provider-effect-requested',
                                'detach-provider-effect-requested'
                            )
                        )
                        OR (
                            lifecycle_state != 'ambiguous-hold'
                            AND ambiguous_hold_reason_redacted IS NULL
                        )
                    ),
                    CHECK (
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
                    ),
                    CHECK (
                        checkpoint NOT IN (
                            'attach-provider-observed',
                            'attached-committed',
                            'detach-provider-absent-observed',
                            'detached-committed'
                        )
                        OR provider_observation_sha256 IS NOT NULL
                    ),
                    CHECK (
                        force_detach_authorization_sha256 IS NULL
                        OR checkpoint IN (
                            'detach-intent-persisted',
                            'detach-fence-acquired',
                            'detach-provider-effect-requested',
                            'detach-provider-absent-observed',
                            'detached-committed'
                        )
                    ),
                    CHECK (
                        julianday(lease_renewed_at) IS NOT NULL
                        AND julianday(lease_expires_at) IS NOT NULL
                        AND julianday(lease_expires_at)
                            > julianday(lease_renewed_at)
                        AND (
                            julianday(lease_expires_at)
                              - julianday(lease_renewed_at)
                        ) * 86400.0 <= 900.001
                    ),
                    CHECK (
                        created_at != '' AND updated_at != ''
                        AND julianday(created_at) IS NOT NULL
                        AND julianday(updated_at) IS NOT NULL
                        AND julianday(updated_at)
                            >= julianday(created_at)
                        AND julianday(lease_renewed_at)
                            >= julianday(created_at)
                        AND julianday(lease_renewed_at)
                            <= julianday(updated_at)
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS storage_snapshots (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    source_volume_id TEXT NOT NULL
                        REFERENCES storage_volumes(id)
                        ON DELETE RESTRICT,
                    provider_id TEXT NOT NULL,
                    provider_snapshot_id TEXT NOT NULL,
                    consistency_class TEXT NOT NULL CHECK (
                        consistency_class IN (
                            'crash-consistent',
                            'application-consistent'
                        )
                    ),
                    parent_content_tree_sha256 TEXT NOT NULL,
                    content_tree_sha256 TEXT NOT NULL,
                    lineage_json TEXT NOT NULL,
                    generation INTEGER NOT NULL CHECK (
                        generation >= 1
                    ),
                    fencing_token TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL CHECK (
                        size_bytes >= 0
                        AND size_bytes <= 1125899906842624
                    ),
                    lifecycle_state TEXT NOT NULL CHECK (
                        lifecycle_state IN (
                            'creating', 'ready', 'deleting',
                            'deleted', 'faulted'
                        )
                    ),
                    operation_group_id TEXT NOT NULL
                        REFERENCES operation_groups(id)
                        ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(provider_id, provider_snapshot_id),
                    CHECK (
                        length(id) = 36
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(name) BETWEEN 1 AND 128
                        AND name NOT GLOB '*[^A-Za-z0-9._-]*'
                    ),
                    CHECK (
                        length(provider_id) BETWEEN 1 AND 256
                        AND provider_id
                            NOT GLOB '*[^A-Za-z0-9._:/-]*'
                    ),
                    CHECK (
                        length(provider_snapshot_id) BETWEEN 1 AND 512
                        AND provider_snapshot_id NOT GLOB '*[^ -~]*'
                    ),
                    CHECK (
                        length(parent_content_tree_sha256) = 64
                        AND parent_content_tree_sha256
                            NOT GLOB '*[^0-9a-f]*'
                        AND length(content_tree_sha256) = 64
                        AND content_tree_sha256
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(lineage_json) BETWEEN 2 AND 16384
                        AND lineage_json NOT GLOB '*[^ -~]*'
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        created_at != '' AND updated_at != ''
                        AND julianday(created_at) IS NOT NULL
                        AND julianday(updated_at) IS NOT NULL
                        AND julianday(updated_at)
                            >= julianday(created_at)
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS storage_backups (
                    id TEXT PRIMARY KEY,
                    volume_id TEXT NOT NULL
                        REFERENCES storage_volumes(id)
                        ON DELETE RESTRICT,
                    snapshot_id TEXT
                        REFERENCES storage_snapshots(id)
                        ON DELETE RESTRICT,
                    destination_redacted TEXT NOT NULL,
                    content_sha256 TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL CHECK (
                        size_bytes >= 0
                        AND size_bytes <= 1125899906842624
                    ),
                    generation INTEGER NOT NULL CHECK (
                        generation >= 1
                    ),
                    fencing_token TEXT NOT NULL,
                    lifecycle_state TEXT NOT NULL CHECK (
                        lifecycle_state IN (
                            'creating', 'ready', 'restoring',
                            'deleting', 'deleted', 'faulted'
                        )
                    ),
                    operation_group_id TEXT NOT NULL
                        REFERENCES operation_groups(id)
                        ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    CHECK (
                        length(id) = 36
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(destination_redacted)
                            BETWEEN 1 AND 1024
                        AND destination_redacted NOT GLOB '*[^ -~]*'
                    ),
                    CHECK (
                        length(content_sha256) = 64
                        AND content_sha256
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        created_at != '' AND updated_at != ''
                        AND julianday(created_at) IS NOT NULL
                        AND julianday(updated_at) IS NOT NULL
                        AND julianday(updated_at)
                            >= julianday(created_at)
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS storage_holds (
                    id TEXT PRIMARY KEY,
                    resource_kind TEXT NOT NULL CHECK (
                        resource_kind IN (
                            'volume', 'snapshot', 'backup'
                        )
                    ),
                    resource_id TEXT NOT NULL,
                    reason_redacted TEXT NOT NULL,
                    generation INTEGER NOT NULL CHECK (
                        generation >= 1
                    ),
                    fencing_token TEXT NOT NULL,
                    operation_group_id TEXT NOT NULL
                        REFERENCES operation_groups(id)
                        ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    expires_at TEXT,
                    released_at TEXT,
                    CHECK (
                        length(id) = 36
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(resource_id) = 36
                        AND replace(resource_id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(reason_redacted) BETWEEN 1 AND 512
                        AND reason_redacted NOT GLOB '*[^ -~]*'
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        created_at != ''
                        AND julianday(created_at) IS NOT NULL
                        AND (
                            expires_at IS NULL
                            OR (
                                julianday(expires_at) IS NOT NULL
                                AND julianday(expires_at)
                                    > julianday(created_at)
                            )
                        )
                        AND (
                            released_at IS NULL
                            OR (
                                julianday(released_at) IS NOT NULL
                                AND julianday(released_at)
                                    >= julianday(created_at)
                            )
                        )
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS storage_orphans (
                    id TEXT PRIMARY KEY,
                    provider_id TEXT NOT NULL,
                    resource_kind TEXT NOT NULL CHECK (
                        resource_kind IN (
                            'volume', 'attachment',
                            'snapshot', 'backup'
                        )
                    ),
                    provider_resource_id_hash TEXT NOT NULL,
                    ownership_proof_sha256 TEXT,
                    generation INTEGER NOT NULL CHECK (
                        generation >= 1
                    ),
                    fencing_token TEXT NOT NULL,
                    lifecycle_state TEXT NOT NULL CHECK (
                        lifecycle_state IN (
                            'discovered', 'held',
                            'reclaimed', 'ignored'
                        )
                    ),
                    operation_group_id TEXT NOT NULL
                        REFERENCES operation_groups(id)
                        ON DELETE RESTRICT,
                    discovered_at TEXT NOT NULL,
                    resolved_at TEXT,
                    UNIQUE(
                        provider_id, resource_kind,
                        provider_resource_id_hash
                    ),
                    CHECK (
                        length(id) = 36
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(provider_id) BETWEEN 1 AND 256
                        AND provider_id
                            NOT GLOB '*[^A-Za-z0-9._:/-]*'
                    ),
                    CHECK (
                        length(provider_resource_id_hash) = 64
                        AND provider_resource_id_hash
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        ownership_proof_sha256 IS NULL
                        OR (
                            length(ownership_proof_sha256) = 64
                            AND ownership_proof_sha256
                                NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    CHECK (
                        lifecycle_state != 'reclaimed'
                        OR ownership_proof_sha256 IS NOT NULL
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        discovered_at != ''
                        AND julianday(discovered_at) IS NOT NULL
                        AND (
                            resolved_at IS NULL
                            OR (
                                julianday(resolved_at) IS NOT NULL
                                AND julianday(resolved_at)
                                    >= julianday(discovered_at)
                            )
                        )
                        AND (
                            (
                                lifecycle_state IN (
                                    'discovered', 'held'
                                )
                                AND resolved_at IS NULL
                            )
                            OR (
                                lifecycle_state IN (
                                    'reclaimed', 'ignored'
                                )
                                AND resolved_at IS NOT NULL
                            )
                        )
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS storage_capacity_samples (
                    id TEXT PRIMARY KEY,
                    provider_id TEXT NOT NULL,
                    topology_node_id TEXT NOT NULL,
                    source TEXT NOT NULL CHECK (
                        source IN (
                            'statfs', 'provider',
                            'reconciled-state'
                        )
                    ),
                    requested_bytes INTEGER NOT NULL,
                    reserved_bytes INTEGER NOT NULL,
                    used_bytes INTEGER NOT NULL,
                    reclaimable_bytes INTEGER NOT NULL,
                    available_bytes INTEGER NOT NULL,
                    total_bytes INTEGER NOT NULL,
                    requested_inodes INTEGER NOT NULL,
                    reserved_inodes INTEGER NOT NULL,
                    used_inodes INTEGER NOT NULL,
                    reclaimable_inodes INTEGER NOT NULL,
                    available_inodes INTEGER NOT NULL,
                    total_inodes INTEGER NOT NULL,
                    quota_enforcement_mode TEXT NOT NULL CHECK (
                        quota_enforcement_mode IN (
                            'hard', 'logical', 'unavailable'
                        )
                    ),
                    quota_evidence_sha256 TEXT,
                    pressure_level TEXT NOT NULL CHECK (
                        pressure_level IN (
                            'normal', 'warning',
                            'critical', 'emergency'
                        )
                    ),
                    sample_digest_sha256 TEXT NOT NULL,
                    captured_at_ms INTEGER NOT NULL CHECK (
                        captured_at_ms >= 0
                    ),
                    valid_until_ms INTEGER NOT NULL,
                    fencing_token TEXT NOT NULL,
                    operation_group_id TEXT NOT NULL
                        REFERENCES operation_groups(id)
                        ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    CHECK (
                        length(id) = 36
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(provider_id) BETWEEN 1 AND 256
                        AND provider_id
                            NOT GLOB '*[^A-Za-z0-9._:/-]*'
                    ),
                    CHECK (
                        length(topology_node_id) BETWEEN 1 AND 128
                        AND topology_node_id
                            NOT GLOB '*[^A-Za-z0-9._:/-]*'
                    ),
                    CHECK (
                        requested_bytes BETWEEN 0 AND 1125899906842624
                        AND reserved_bytes BETWEEN 0 AND 1125899906842624
                        AND used_bytes BETWEEN 0 AND 1125899906842624
                        AND reclaimable_bytes BETWEEN 0 AND 1125899906842624
                        AND available_bytes BETWEEN 0 AND 1125899906842624
                        AND total_bytes BETWEEN 1 AND 1125899906842624
                        AND used_bytes <= total_bytes
                        AND available_bytes <= total_bytes
                        AND reclaimable_bytes <= used_bytes
                        AND used_bytes <= total_bytes - available_bytes
                    ),
                    CHECK (
                        requested_inodes BETWEEN 0 AND 9007199254740991
                        AND reserved_inodes BETWEEN 0 AND 9007199254740991
                        AND used_inodes BETWEEN 0 AND 9007199254740991
                        AND reclaimable_inodes BETWEEN 0 AND 9007199254740991
                        AND available_inodes BETWEEN 0 AND 9007199254740991
                        AND total_inodes BETWEEN 1 AND 9007199254740991
                        AND used_inodes <= total_inodes
                        AND available_inodes <= total_inodes
                        AND reclaimable_inodes <= used_inodes
                        AND used_inodes <= total_inodes - available_inodes
                    ),
                    CHECK (
                        (
                            quota_enforcement_mode = 'hard'
                            AND quota_evidence_sha256 IS NOT NULL
                        )
                        OR quota_enforcement_mode != 'hard'
                    ),
                    CHECK (
                        quota_evidence_sha256 IS NULL
                        OR (
                            length(quota_evidence_sha256) = 64
                            AND quota_evidence_sha256
                                NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    CHECK (
                        length(sample_digest_sha256) = 64
                        AND sample_digest_sha256
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        valid_until_ms > captured_at_ms
                        AND valid_until_ms - captured_at_ms
                            <= 900000
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        created_at != ''
                        AND julianday(created_at) IS NOT NULL
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS storage_quotas (
                    id TEXT PRIMARY KEY,
                    resource_id TEXT NOT NULL,
                    provider_id TEXT NOT NULL,
                    byte_limit INTEGER,
                    inode_limit INTEGER,
                    enforcement_mode TEXT NOT NULL CHECK (
                        enforcement_mode IN (
                            'hard', 'logical', 'unavailable'
                        )
                    ),
                    enforcement_evidence_sha256 TEXT,
                    generation INTEGER NOT NULL CHECK (
                        generation >= 1
                    ),
                    fencing_token TEXT NOT NULL,
                    lifecycle_state TEXT NOT NULL CHECK (
                        lifecycle_state IN (
                            'active', 'releasing',
                            'released', 'faulted'
                        )
                    ),
                    retry_attempt INTEGER NOT NULL CHECK (
                        retry_attempt BETWEEN 1 AND 3
                    ),
                    recovery_checkpoint TEXT NOT NULL CHECK (
                        recovery_checkpoint IN (
                            'admission-pending',
                            'sample-validated', 'admitted',
                            'throttled', 'rejected', 'cancelled',
                            'observation-required'
                        )
                    ),
                    operation_id TEXT NOT NULL,
                    idempotency_key TEXT NOT NULL,
                    operation_group_id TEXT NOT NULL
                        REFERENCES operation_groups(id)
                        ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(resource_id, provider_id),
                    CHECK (
                        length(id) = 36
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(resource_id) = 36
                        AND replace(resource_id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(provider_id) BETWEEN 1 AND 256
                        AND provider_id
                            NOT GLOB '*[^A-Za-z0-9._:/-]*'
                    ),
                    CHECK (
                        (byte_limit IS NOT NULL OR inode_limit IS NOT NULL)
                        AND (
                            byte_limit IS NULL
                            OR byte_limit
                                BETWEEN 0 AND 1125899906842624
                        )
                        AND (
                            inode_limit IS NULL
                            OR inode_limit
                                BETWEEN 0 AND 9007199254740991
                        )
                    ),
                    CHECK (
                        (
                            enforcement_mode = 'hard'
                            AND enforcement_evidence_sha256 IS NOT NULL
                        )
                        OR enforcement_mode != 'hard'
                    ),
                    CHECK (
                        enforcement_evidence_sha256 IS NULL
                        OR (
                            length(enforcement_evidence_sha256) = 64
                            AND enforcement_evidence_sha256
                                NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(operation_id) = 36
                        AND replace(operation_id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(idempotency_key) = 64
                        AND idempotency_key
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        created_at != '' AND updated_at != ''
                        AND julianday(created_at) IS NOT NULL
                        AND julianday(updated_at) IS NOT NULL
                        AND julianday(updated_at)
                            >= julianday(created_at)
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS
                    storage_capacity_admissions (
                    id TEXT PRIMARY KEY,
                    sample_id TEXT NOT NULL
                        REFERENCES storage_capacity_samples(id)
                        ON DELETE RESTRICT,
                    sample_digest_sha256 TEXT NOT NULL,
                    action TEXT NOT NULL CHECK (
                        action IN (
                            'create', 'expand', 'attach',
                            'restore', 'snapshot', 'backup',
                            'garbage-collect'
                        )
                    ),
                    additional_bytes INTEGER NOT NULL CHECK (
                        additional_bytes
                            BETWEEN 0 AND 1125899906842624
                    ),
                    additional_inodes INTEGER NOT NULL CHECK (
                        additional_inodes
                            BETWEEN 0 AND 9007199254740991
                    ),
                    writable INTEGER NOT NULL CHECK (
                        writable IN (0, 1)
                    ),
                    operation_id TEXT NOT NULL,
                    idempotency_key TEXT NOT NULL,
                    disposition TEXT NOT NULL CHECK (
                        disposition IN (
                            'admit', 'throttle', 'reject',
                            'cancelled', 'recovery-required'
                        )
                    ),
                    reason TEXT NOT NULL CHECK (
                        reason IN (
                            'admitted', 'warning-pressure',
                            'critical-pressure',
                            'emergency-pressure', 'stale-sample',
                            'bytes-exhausted', 'inodes-exhausted',
                            'quota-exceeded',
                            'hard-quota-unavailable',
                            'retry-exhausted', 'cancelled',
                            'timed-out', 'ambiguous-effect'
                        )
                    ),
                    pressure_level TEXT NOT NULL CHECK (
                        pressure_level IN (
                            'normal', 'warning',
                            'critical', 'emergency'
                        )
                    ),
                    retry_disposition TEXT NOT NULL CHECK (
                        retry_disposition IN (
                            'never', 'after-fresh-sample',
                            'resume-from-checkpoint'
                        )
                    ),
                    recovery_checkpoint TEXT NOT NULL CHECK (
                        recovery_checkpoint IN (
                            'admission-pending',
                            'sample-validated', 'admitted',
                            'throttled', 'rejected', 'cancelled',
                            'observation-required'
                        )
                    ),
                    attempt INTEGER NOT NULL,
                    maximum_attempts INTEGER NOT NULL,
                    effective_available_bytes INTEGER NOT NULL,
                    effective_available_inodes INTEGER NOT NULL,
                    fencing_token TEXT NOT NULL,
                    operation_group_id TEXT NOT NULL
                        REFERENCES operation_groups(id)
                        ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    UNIQUE(operation_id, attempt),
                    CHECK (
                        length(id) = 36
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(sample_digest_sha256) = 64
                        AND sample_digest_sha256
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(operation_id) = 36
                        AND replace(operation_id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(idempotency_key) = 64
                        AND idempotency_key
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        attempt BETWEEN 1 AND 3
                        AND maximum_attempts BETWEEN 1 AND 3
                        AND attempt <= maximum_attempts
                    ),
                    CHECK (
                        effective_available_bytes
                            BETWEEN 0 AND 1125899906842624
                        AND effective_available_inodes
                            BETWEEN 0 AND 9007199254740991
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        created_at != ''
                        AND julianday(created_at) IS NOT NULL
                    )
                )
                """,
                "CREATE INDEX IF NOT EXISTS storage_volumes_provider_idx ON storage_volumes(provider_id, provider_volume_id, lifecycle_state)",
                "CREATE INDEX IF NOT EXISTS storage_volumes_project_idx ON storage_volumes(project_id, lifecycle_state, name)",
                "CREATE INDEX IF NOT EXISTS storage_volumes_topology_idx ON storage_volumes(topology_node_id, lifecycle_state, name)",
                "CREATE INDEX IF NOT EXISTS storage_volumes_operation_idx ON storage_volumes(operation_group_id, updated_at)",
                "CREATE INDEX IF NOT EXISTS storage_attachments_volume_idx ON storage_attachments(volume_id, node_uuid, workload_uuid, attachment_kind, lifecycle_state)",
                "CREATE INDEX IF NOT EXISTS storage_attachments_operation_idx ON storage_attachments(operation_group_id, updated_at)",
                "CREATE INDEX IF NOT EXISTS storage_attachments_lease_idx ON storage_attachments(lease_expires_at, lifecycle_state, volume_id)",
                "CREATE UNIQUE INDEX IF NOT EXISTS storage_attachments_single_writer_idx ON storage_attachments(volume_id) WHERE read_only = 0 AND lifecycle_state != 'detached'",
                "CREATE UNIQUE INDEX IF NOT EXISTS storage_attachments_holder_active_idx ON storage_attachments(volume_id, node_uuid, workload_uuid) WHERE lifecycle_state != 'detached'",
                "CREATE INDEX IF NOT EXISTS storage_snapshots_source_idx ON storage_snapshots(source_volume_id, lifecycle_state, created_at)",
                "CREATE INDEX IF NOT EXISTS storage_snapshots_operation_idx ON storage_snapshots(operation_group_id, updated_at)",
                "CREATE INDEX IF NOT EXISTS storage_backups_volume_idx ON storage_backups(volume_id, snapshot_id, lifecycle_state, created_at)",
                "CREATE INDEX IF NOT EXISTS storage_backups_operation_idx ON storage_backups(operation_group_id, updated_at)",
                "CREATE INDEX IF NOT EXISTS storage_holds_resource_idx ON storage_holds(resource_kind, resource_id, released_at, expires_at)",
                "CREATE UNIQUE INDEX IF NOT EXISTS storage_holds_active_idx ON storage_holds(resource_kind, resource_id) WHERE released_at IS NULL",
                "CREATE INDEX IF NOT EXISTS storage_orphans_provider_idx ON storage_orphans(provider_id, resource_kind, lifecycle_state, discovered_at)",
                "CREATE INDEX IF NOT EXISTS storage_orphans_operation_idx ON storage_orphans(operation_group_id, discovered_at)",
                "CREATE INDEX IF NOT EXISTS storage_capacity_samples_latest_idx ON storage_capacity_samples(provider_id, topology_node_id, captured_at_ms DESC, id)",
                "CREATE INDEX IF NOT EXISTS storage_capacity_samples_operation_idx ON storage_capacity_samples(operation_group_id, created_at)",
                "CREATE INDEX IF NOT EXISTS storage_quotas_resource_idx ON storage_quotas(resource_id, provider_id, lifecycle_state)",
                "CREATE INDEX IF NOT EXISTS storage_quotas_operation_idx ON storage_quotas(operation_group_id, updated_at)",
                "CREATE INDEX IF NOT EXISTS storage_capacity_admissions_operation_idx ON storage_capacity_admissions(operation_id, attempt DESC)",
                "CREATE INDEX IF NOT EXISTS storage_capacity_admissions_sample_idx ON storage_capacity_admissions(sample_id, created_at)"
            ]
        ),
        SchemaMigration(
            version: 16,
            description: "Fenced project network, attachment, DNS, and service tunnel state",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS network_resources (
                    id TEXT PRIMARY KEY,
                    project_uuid TEXT NOT NULL
                        REFERENCES projects(resource_uuid)
                        ON DELETE RESTRICT,
                    name TEXT NOT NULL,
                    runtime_name TEXT NOT NULL,
                    generation INTEGER NOT NULL CHECK (
                        generation >= 1
                    ),
                    provider_id TEXT NOT NULL CHECK (
                        provider_id IN (
                            'apple-container-cli',
                            'apple-containerization'
                        )
                    ),
                    provider_generation INTEGER NOT NULL CHECK (
                        provider_generation >= 1
                    ),
                    fencing_token TEXT NOT NULL,
                    driver TEXT NOT NULL CHECK (
                        driver IN ('nat', 'host-only')
                    ),
                    requested_ipv4 TEXT NOT NULL,
                    requested_ipv6 TEXT NOT NULL,
                    observed_ipv4_json TEXT NOT NULL,
                    observed_ipv6_json TEXT NOT NULL,
                    desired_sha256 TEXT NOT NULL,
                    observed_sha256 TEXT,
                    lifecycle_state TEXT NOT NULL CHECK (
                        lifecycle_state IN (
                            'creating', 'available', 'deleting',
                            'deleted', 'faulted'
                        )
                    ),
                    finalizer_state TEXT NOT NULL CHECK (
                        finalizer_state IN (
                            'pending', 'active', 'releasing',
                            'released', 'quarantined'
                        )
                    ),
                    operation_group_id TEXT NOT NULL
                        REFERENCES operation_groups(id)
                        ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(project_uuid, name),
                    UNIQUE(provider_id, runtime_name),
                    CHECK (
                        length(id) = 36
                        AND substr(id, 9, 1) = '-'
                        AND substr(id, 14, 1) = '-'
                        AND substr(id, 19, 1) = '-'
                        AND substr(id, 24, 1) = '-'
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(project_uuid) = 36
                        AND substr(project_uuid, 9, 1) = '-'
                        AND substr(project_uuid, 14, 1) = '-'
                        AND substr(project_uuid, 19, 1) = '-'
                        AND substr(project_uuid, 24, 1) = '-'
                        AND replace(project_uuid, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(name) BETWEEN 1 AND 63
                        AND name NOT GLOB '*[^a-z0-9-]*'
                        AND substr(name, 1, 1) GLOB '[a-z0-9]'
                        AND substr(name, -1, 1) GLOB '[a-z0-9]'
                    ),
                    CHECK (
                        length(runtime_name) BETWEEN 1 AND 128
                        AND runtime_name
                            NOT GLOB '*[^A-Za-z0-9._-]*'
                        AND substr(runtime_name, 1, 1)
                            GLOB '[A-Za-z0-9]'
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND substr(fencing_token, 9, 1) = '-'
                        AND substr(fencing_token, 14, 1) = '-'
                        AND substr(fencing_token, 19, 1) = '-'
                        AND substr(fencing_token, 24, 1) = '-'
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(requested_ipv4) BETWEEN 3 AND 128
                        AND requested_ipv4 NOT GLOB '*[^ -~]*'
                        AND length(requested_ipv6) BETWEEN 3 AND 128
                        AND requested_ipv6 NOT GLOB '*[^ -~]*'
                    ),
                    CHECK (
                        json_valid(observed_ipv4_json)
                        AND json_type(observed_ipv4_json) = 'array'
                        AND length(observed_ipv4_json) <= 16384
                        AND json_valid(observed_ipv6_json)
                        AND json_type(observed_ipv6_json) = 'array'
                        AND length(observed_ipv6_json) <= 16384
                    ),
                    CHECK (
                        length(desired_sha256) = 64
                        AND desired_sha256
                            NOT GLOB '*[^0-9a-f]*'
                        AND (
                            observed_sha256 IS NULL
                            OR (
                                length(observed_sha256) = 64
                                AND observed_sha256
                                    NOT GLOB '*[^0-9a-f]*'
                            )
                        )
                    ),
                    CHECK (
                        (lifecycle_state = 'creating'
                            AND finalizer_state = 'pending')
                        OR (lifecycle_state = 'available'
                            AND finalizer_state = 'active'
                            AND observed_sha256 IS NOT NULL)
                        OR (lifecycle_state = 'deleting'
                            AND finalizer_state = 'releasing')
                        OR (lifecycle_state = 'deleted'
                            AND finalizer_state = 'released'
                            AND observed_sha256 IS NOT NULL)
                        OR (lifecycle_state = 'faulted'
                            AND finalizer_state IN (
                                'active', 'releasing', 'quarantined'
                            ))
                    ),
                    CHECK (
                        created_at != '' AND updated_at != ''
                        AND julianday(created_at) IS NOT NULL
                        AND julianday(updated_at) IS NOT NULL
                        AND julianday(updated_at)
                            >= julianday(created_at)
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS network_attachments (
                    id TEXT PRIMARY KEY,
                    network_uuid TEXT NOT NULL
                        REFERENCES network_resources(id)
                        ON DELETE RESTRICT,
                    project_uuid TEXT NOT NULL
                        REFERENCES projects(resource_uuid)
                        ON DELETE RESTRICT,
                    resource_uuid TEXT NOT NULL,
                    generation INTEGER NOT NULL CHECK (
                        generation >= 1
                    ),
                    provider_id TEXT NOT NULL CHECK (
                        provider_id IN (
                            'apple-container-cli',
                            'apple-containerization'
                        )
                    ),
                    provider_generation INTEGER NOT NULL CHECK (
                        provider_generation >= 1
                    ),
                    fencing_token TEXT NOT NULL,
                    desired_sha256 TEXT NOT NULL,
                    observed_sha256 TEXT,
                    lifecycle_state TEXT NOT NULL CHECK (
                        lifecycle_state IN (
                            'attaching', 'attached', 'detaching',
                            'detached', 'faulted'
                        )
                    ),
                    finalizer_state TEXT NOT NULL CHECK (
                        finalizer_state IN (
                            'pending', 'active', 'releasing',
                            'released', 'quarantined'
                        )
                    ),
                    operation_group_id TEXT NOT NULL
                        REFERENCES operation_groups(id)
                        ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(network_uuid, resource_uuid),
                    CHECK (
                        length(id) = 36
                        AND substr(id, 9, 1) = '-'
                        AND substr(id, 14, 1) = '-'
                        AND substr(id, 19, 1) = '-'
                        AND substr(id, 24, 1) = '-'
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(network_uuid) = 36
                        AND substr(network_uuid, 9, 1) = '-'
                        AND substr(network_uuid, 14, 1) = '-'
                        AND substr(network_uuid, 19, 1) = '-'
                        AND substr(network_uuid, 24, 1) = '-'
                        AND replace(network_uuid, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(project_uuid) = 36
                        AND substr(project_uuid, 9, 1) = '-'
                        AND substr(project_uuid, 14, 1) = '-'
                        AND substr(project_uuid, 19, 1) = '-'
                        AND substr(project_uuid, 24, 1) = '-'
                        AND replace(project_uuid, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(resource_uuid) = 36
                        AND substr(resource_uuid, 9, 1) = '-'
                        AND substr(resource_uuid, 14, 1) = '-'
                        AND substr(resource_uuid, 19, 1) = '-'
                        AND substr(resource_uuid, 24, 1) = '-'
                        AND replace(resource_uuid, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND substr(fencing_token, 9, 1) = '-'
                        AND substr(fencing_token, 14, 1) = '-'
                        AND substr(fencing_token, 19, 1) = '-'
                        AND substr(fencing_token, 24, 1) = '-'
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(desired_sha256) = 64
                        AND desired_sha256
                            NOT GLOB '*[^0-9a-f]*'
                        AND (
                            observed_sha256 IS NULL
                            OR (
                                length(observed_sha256) = 64
                                AND observed_sha256
                                    NOT GLOB '*[^0-9a-f]*'
                            )
                        )
                    ),
                    CHECK (
                        (lifecycle_state = 'attaching'
                            AND finalizer_state = 'pending')
                        OR (lifecycle_state = 'attached'
                            AND finalizer_state = 'active'
                            AND observed_sha256 IS NOT NULL)
                        OR (lifecycle_state = 'detaching'
                            AND finalizer_state = 'releasing')
                        OR (lifecycle_state = 'detached'
                            AND finalizer_state = 'released'
                            AND observed_sha256 IS NOT NULL)
                        OR (lifecycle_state = 'faulted'
                            AND finalizer_state IN (
                                'active', 'releasing', 'quarantined'
                            ))
                    ),
                    CHECK (
                        created_at != '' AND updated_at != ''
                        AND julianday(created_at) IS NOT NULL
                        AND julianday(updated_at) IS NOT NULL
                        AND julianday(updated_at)
                            >= julianday(created_at)
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS network_dns_instances (
                    id TEXT PRIMARY KEY,
                    project_uuid TEXT NOT NULL
                        REFERENCES projects(resource_uuid)
                        ON DELETE RESTRICT,
                    generation INTEGER NOT NULL CHECK (
                        generation >= 1
                    ),
                    provider_id TEXT NOT NULL CHECK (
                        provider_id IN (
                            'apple-container-cli',
                            'apple-containerization'
                        )
                    ),
                    provider_generation INTEGER NOT NULL CHECK (
                        provider_generation >= 1
                    ),
                    fencing_token TEXT NOT NULL,
                    desired_sha256 TEXT NOT NULL,
                    observed_sha256 TEXT,
                    lifecycle_state TEXT NOT NULL CHECK (
                        lifecycle_state IN (
                            'creating', 'available', 'deleting',
                            'deleted', 'faulted'
                        )
                    ),
                    finalizer_state TEXT NOT NULL CHECK (
                        finalizer_state IN (
                            'pending', 'active', 'releasing',
                            'released', 'quarantined'
                        )
                    ),
                    last_ready_record_sha256 TEXT,
                    operation_group_id TEXT NOT NULL
                        REFERENCES operation_groups(id)
                        ON DELETE RESTRICT,
                    UNIQUE(project_uuid),
                    CHECK (
                        length(id) = 36
                        AND substr(id, 9, 1) = '-'
                        AND substr(id, 14, 1) = '-'
                        AND substr(id, 19, 1) = '-'
                        AND substr(id, 24, 1) = '-'
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(project_uuid) = 36
                        AND substr(project_uuid, 9, 1) = '-'
                        AND substr(project_uuid, 14, 1) = '-'
                        AND substr(project_uuid, 19, 1) = '-'
                        AND substr(project_uuid, 24, 1) = '-'
                        AND replace(project_uuid, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND substr(fencing_token, 9, 1) = '-'
                        AND substr(fencing_token, 14, 1) = '-'
                        AND substr(fencing_token, 19, 1) = '-'
                        AND substr(fencing_token, 24, 1) = '-'
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(desired_sha256) = 64
                        AND desired_sha256
                            NOT GLOB '*[^0-9a-f]*'
                        AND (
                            observed_sha256 IS NULL
                            OR (
                                length(observed_sha256) = 64
                                AND observed_sha256
                                    NOT GLOB '*[^0-9a-f]*'
                            )
                        )
                        AND (
                            last_ready_record_sha256 IS NULL
                            OR (
                                length(last_ready_record_sha256) = 64
                                AND last_ready_record_sha256
                                    NOT GLOB '*[^0-9a-f]*'
                            )
                        )
                    ),
                    CHECK (
                        (lifecycle_state = 'creating'
                            AND finalizer_state = 'pending'
                            AND observed_sha256 IS NULL
                            AND last_ready_record_sha256 IS NULL)
                        OR (lifecycle_state = 'available'
                            AND finalizer_state = 'active'
                            AND observed_sha256 IS NOT NULL
                            AND last_ready_record_sha256 IS NOT NULL)
                        OR (lifecycle_state = 'deleting'
                            AND finalizer_state = 'releasing')
                        OR (lifecycle_state = 'deleted'
                            AND finalizer_state = 'released'
                            AND observed_sha256 IS NOT NULL)
                        OR (lifecycle_state = 'faulted'
                            AND finalizer_state IN (
                                'active', 'releasing', 'quarantined'
                            ))
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS network_port_reservations (
                    id TEXT PRIMARY KEY,
                    project_uuid TEXT NOT NULL
                        REFERENCES projects(resource_uuid)
                        ON DELETE RESTRICT,
                    resource_uuid TEXT NOT NULL,
                    service_name TEXT NOT NULL,
                    generation INTEGER NOT NULL CHECK (
                        generation >= 1
                    ),
                    provider_id TEXT NOT NULL CHECK (
                        provider_id IN (
                            'apple-container-cli',
                            'apple-containerization'
                        )
                    ),
                    provider_generation INTEGER NOT NULL CHECK (
                        provider_generation >= 1
                    ),
                    fencing_token TEXT NOT NULL,
                    bind_address TEXT NOT NULL CHECK (
                        length(bind_address) BETWEEN 2 AND 45
                        AND bind_address NOT GLOB '*[^0-9A-Fa-f:.]*'
                    ),
                    host_port INTEGER NOT NULL CHECK (
                        host_port BETWEEN 1024 AND 65535
                    ),
                    container_port INTEGER NOT NULL CHECK (
                        container_port BETWEEN 1 AND 65535
                    ),
                    protocol TEXT NOT NULL CHECK (
                        protocol IN ('tcp', 'udp')
                    ),
                    allocation_kind TEXT NOT NULL CHECK (
                        allocation_kind IN ('fixed', 'dynamic')
                    ),
                    desired_sha256 TEXT NOT NULL,
                    observed_sha256 TEXT,
                    lifecycle_state TEXT NOT NULL CHECK (
                        lifecycle_state IN (
                            'reserved', 'active', 'releasing',
                            'released', 'faulted'
                        )
                    ),
                    finalizer_state TEXT NOT NULL CHECK (
                        finalizer_state IN (
                            'active', 'releasing', 'released',
                            'quarantined'
                        )
                    ),
                    operation_group_id TEXT NOT NULL
                        REFERENCES operation_groups(id)
                        ON DELETE RESTRICT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    CHECK (
                        length(id) = 36
                        AND substr(id, 9, 1) = '-'
                        AND substr(id, 14, 1) = '-'
                        AND substr(id, 19, 1) = '-'
                        AND substr(id, 24, 1) = '-'
                        AND replace(id, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(project_uuid) = 36
                        AND substr(project_uuid, 9, 1) = '-'
                        AND substr(project_uuid, 14, 1) = '-'
                        AND substr(project_uuid, 19, 1) = '-'
                        AND substr(project_uuid, 24, 1) = '-'
                        AND replace(project_uuid, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(resource_uuid) = 36
                        AND substr(resource_uuid, 9, 1) = '-'
                        AND substr(resource_uuid, 14, 1) = '-'
                        AND substr(resource_uuid, 19, 1) = '-'
                        AND substr(resource_uuid, 24, 1) = '-'
                        AND replace(resource_uuid, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(fencing_token) = 36
                        AND substr(fencing_token, 9, 1) = '-'
                        AND substr(fencing_token, 14, 1) = '-'
                        AND substr(fencing_token, 19, 1) = '-'
                        AND substr(fencing_token, 24, 1) = '-'
                        AND replace(fencing_token, '-', '')
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    CHECK (
                        length(service_name) BETWEEN 1 AND 255
                        AND service_name NOT GLOB '*[^ -~]*'
                    ),
                    CHECK (
                        allocation_kind != 'dynamic'
                        OR host_port BETWEEN 49152 AND 65535
                    ),
                    CHECK (
                        length(desired_sha256) = 64
                        AND desired_sha256
                            NOT GLOB '*[^0-9a-f]*'
                        AND (
                            observed_sha256 IS NULL
                            OR (
                                length(observed_sha256) = 64
                                AND observed_sha256
                                    NOT GLOB '*[^0-9a-f]*'
                            )
                        )
                    ),
                    CHECK (
                        (lifecycle_state = 'reserved'
                            AND finalizer_state = 'active'
                            AND observed_sha256 IS NULL)
                        OR (lifecycle_state = 'active'
                            AND finalizer_state = 'active'
                            AND observed_sha256 IS NOT NULL)
                        OR (lifecycle_state = 'releasing'
                            AND finalizer_state = 'releasing')
                        OR (lifecycle_state = 'released'
                            AND finalizer_state = 'released'
                            AND observed_sha256 IS NOT NULL)
                        OR (lifecycle_state = 'faulted'
                            AND finalizer_state IN (
                                'active', 'releasing', 'quarantined'
                            ))
                    ),
                    CHECK (
                        created_at != '' AND updated_at != ''
                        AND julianday(created_at) IS NOT NULL
                        AND julianday(updated_at) IS NOT NULL
                        AND julianday(updated_at)
                            >= julianday(created_at)
                    )
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS network_certificates (
                    id TEXT PRIMARY KEY, project_uuid TEXT NOT NULL REFERENCES projects(resource_uuid) ON DELETE RESTRICT,
                    manifest_name TEXT NOT NULL, generation INTEGER NOT NULL CHECK (generation >= 1), provider_id TEXT NOT NULL,
                    provider_generation INTEGER NOT NULL CHECK (provider_generation >= 1), fencing_token TEXT NOT NULL,
                    source_kind TEXT NOT NULL CHECK (source_kind IN ('imported','local-ca','provider')),
                    ownership_kind TEXT NOT NULL CHECK (ownership_kind IN ('external','managed')),
                    leaf_sha256 TEXT NOT NULL, issuer_sha256 TEXT,
                    san_json TEXT NOT NULL, eku_json TEXT NOT NULL, not_before TEXT NOT NULL, not_after TEXT NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('creating','available','revoking','revoked','released','faulted')),
                    revocation_status TEXT NOT NULL CHECK (revocation_status IN ('unknown','good','revoked','not-applicable')),
                    status_checked_at TEXT, desired_sha256 TEXT NOT NULL, observed_sha256 TEXT,
                    lifecycle_state TEXT NOT NULL CHECK (lifecycle_state IN ('creating','available','deleting','deleted','faulted')),
                    finalizer_state TEXT NOT NULL CHECK (finalizer_state IN ('pending','active','releasing','released','quarantined')),
                    prior_leaf_sha256 TEXT,
                    operation_group_id TEXT NOT NULL REFERENCES operation_groups(id) ON DELETE RESTRICT,
                    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE(project_uuid, manifest_name),
                    CHECK (length(id) = 36 AND replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'),
                    CHECK (length(project_uuid) = 36 AND replace(project_uuid, '-', '') NOT GLOB '*[^0-9a-f]*'),
                    CHECK (length(fencing_token) = 36 AND replace(fencing_token, '-', '') NOT GLOB '*[^0-9a-f]*'),
                    CHECK (length(manifest_name) BETWEEN 1 AND 63 AND manifest_name NOT GLOB '*[^a-z0-9-]*'),
                    CHECK (length(leaf_sha256) = 64 AND leaf_sha256 NOT GLOB '*[^0-9a-f]*'), CHECK (issuer_sha256 IS NULL OR (length(issuer_sha256) = 64 AND issuer_sha256 NOT GLOB '*[^0-9a-f]*')),
                    CHECK (prior_leaf_sha256 IS NULL OR (length(prior_leaf_sha256) = 64 AND prior_leaf_sha256 NOT GLOB '*[^0-9a-f]*')),
                    CHECK (length(desired_sha256) = 64 AND desired_sha256 NOT GLOB '*[^0-9a-f]*'), CHECK (observed_sha256 IS NULL OR (length(observed_sha256) = 64 AND observed_sha256 NOT GLOB '*[^0-9a-f]*')),
                    CHECK (json_valid(san_json) AND json_type(san_json) = 'array' AND length(san_json) <= 16384), CHECK (json_valid(eku_json) AND json_type(eku_json) = 'array' AND length(eku_json) <= 16384),
                    CHECK (julianday(not_before) IS NOT NULL AND julianday(not_after) IS NOT NULL AND julianday(not_after) > julianday(not_before)), CHECK (status_checked_at IS NULL OR julianday(status_checked_at) IS NOT NULL),
                    CHECK ((source_kind = 'imported' AND ownership_kind = 'external') OR (source_kind IN ('local-ca','provider') AND ownership_kind = 'managed')),
                    CHECK ((lifecycle_state = 'creating' AND finalizer_state = 'pending' AND status = 'creating' AND observed_sha256 IS NULL) OR (lifecycle_state = 'available' AND finalizer_state = 'active' AND status = 'available' AND observed_sha256 IS NOT NULL) OR (lifecycle_state = 'deleting' AND finalizer_state = 'releasing' AND ((ownership_kind = 'external' AND status = 'available') OR (ownership_kind = 'managed' AND status = 'revoking'))) OR (lifecycle_state = 'deleted' AND finalizer_state = 'released' AND ((ownership_kind = 'external' AND status = 'released') OR (ownership_kind = 'managed' AND status = 'revoked'))) OR (lifecycle_state = 'faulted' AND finalizer_state IN ('active','releasing','quarantined') AND status = 'faulted')),
                    CHECK (julianday(created_at) IS NOT NULL AND julianday(updated_at) IS NOT NULL AND julianday(updated_at) >= julianday(created_at))
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS service_tunnel_sessions (
                    id TEXT PRIMARY KEY,
                    project_uuid TEXT NOT NULL REFERENCES projects(resource_uuid) ON DELETE RESTRICT,
                    peer_uuid TEXT NOT NULL,
                    generation INTEGER NOT NULL CHECK (generation >= 1),
                    provider_id TEXT NOT NULL,
                    provider_generation INTEGER NOT NULL CHECK (provider_generation >= 1),
                    fencing_token TEXT NOT NULL,
                    operation_group_id TEXT NOT NULL REFERENCES operation_groups(id) ON DELETE RESTRICT,
                    desired_sha256 TEXT NOT NULL,
                    observed_sha256 TEXT,
                    route_json TEXT NOT NULL,
                    route_json_sha256 TEXT NOT NULL,
                    lifecycle_state TEXT NOT NULL CHECK (lifecycle_state IN ('intended','connecting','active','draining','closed','faulted')),
                    finalizer_state TEXT NOT NULL CHECK (finalizer_state IN ('pending','active','releasing','released','quarantined')),
                    selected_transport TEXT CHECK (selected_transport IS NULL OR selected_transport IN ('direct','relay')),
                    key_epoch INTEGER NOT NULL CHECK (key_epoch >= 1),
                    reconnect_attempt INTEGER NOT NULL CHECK (reconnect_attempt BETWEEN 0 AND 8),
                    created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
                    updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= created_at_ms),
                    CHECK (length(id) = 36 AND replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'),
                    CHECK (length(project_uuid) = 36 AND replace(project_uuid, '-', '') NOT GLOB '*[^0-9a-f]*'),
                    CHECK (length(peer_uuid) = 36 AND replace(peer_uuid, '-', '') NOT GLOB '*[^0-9a-f]*'),
                    CHECK (length(fencing_token) = 36 AND replace(fencing_token, '-', '') NOT GLOB '*[^0-9a-f]*'),
                    CHECK (length(desired_sha256) = 64 AND desired_sha256 NOT GLOB '*[^0-9a-f]*'),
                    CHECK (observed_sha256 IS NULL OR (length(observed_sha256) = 64 AND observed_sha256 NOT GLOB '*[^0-9a-f]*')),
                    CHECK (json_valid(route_json) AND json_type(route_json) = 'object' AND length(route_json) <= 65536),
                    CHECK (length(route_json_sha256) = 64 AND route_json_sha256 NOT GLOB '*[^0-9a-f]*'),
                    CHECK (
                        (lifecycle_state = 'intended' AND finalizer_state = 'pending' AND observed_sha256 IS NULL)
                        OR (lifecycle_state = 'connecting' AND (
                            (finalizer_state = 'pending' AND observed_sha256 IS NULL)
                            OR (finalizer_state = 'active' AND observed_sha256 IS NOT NULL)
                        ))
                        OR (lifecycle_state = 'active' AND finalizer_state = 'active' AND observed_sha256 IS NOT NULL)
                        OR (lifecycle_state = 'draining' AND finalizer_state = 'releasing')
                        OR (lifecycle_state = 'closed' AND finalizer_state = 'released' AND observed_sha256 IS NOT NULL)
                        OR (lifecycle_state = 'faulted' AND finalizer_state = 'quarantined')
                    )
                )
                """,
                "CREATE INDEX IF NOT EXISTS network_resources_project_idx ON network_resources(project_uuid, lifecycle_state, name, id)",
                "CREATE INDEX IF NOT EXISTS network_resources_provider_idx ON network_resources(provider_id, runtime_name, lifecycle_state)",
                "CREATE INDEX IF NOT EXISTS network_resources_operation_idx ON network_resources(operation_group_id, updated_at)",
                "CREATE INDEX IF NOT EXISTS network_attachments_network_idx ON network_attachments(network_uuid, lifecycle_state, resource_uuid, id)",
                "CREATE INDEX IF NOT EXISTS network_attachments_resource_idx ON network_attachments(project_uuid, resource_uuid, lifecycle_state, network_uuid)",
                "CREATE INDEX IF NOT EXISTS network_attachments_operation_idx ON network_attachments(operation_group_id, updated_at)",
                "CREATE INDEX IF NOT EXISTS network_dns_instances_project_idx ON network_dns_instances(project_uuid, lifecycle_state, id)",
                "CREATE INDEX IF NOT EXISTS network_dns_instances_operation_idx ON network_dns_instances(operation_group_id, generation)",
                "CREATE INDEX IF NOT EXISTS network_certificates_project_idx ON network_certificates(project_uuid, lifecycle_state, manifest_name, id)",
                "CREATE INDEX IF NOT EXISTS network_certificates_provider_idx ON network_certificates(provider_id, provider_generation, lifecycle_state)",
                "CREATE INDEX IF NOT EXISTS network_certificates_operation_idx ON network_certificates(operation_group_id, generation)",
                "CREATE UNIQUE INDEX IF NOT EXISTS network_port_reservations_active_idx ON network_port_reservations(bind_address, host_port, protocol) WHERE lifecycle_state != 'released'",
                "CREATE INDEX IF NOT EXISTS network_port_reservations_project_idx ON network_port_reservations(project_uuid, lifecycle_state, service_name, host_port)",
                "CREATE INDEX IF NOT EXISTS network_port_reservations_resource_idx ON network_port_reservations(resource_uuid, lifecycle_state, host_port)",
                "CREATE INDEX IF NOT EXISTS network_port_reservations_operation_idx ON network_port_reservations(operation_group_id, updated_at)",
                "CREATE UNIQUE INDEX IF NOT EXISTS service_tunnel_active_peer_idx ON service_tunnel_sessions(project_uuid, peer_uuid) WHERE lifecycle_state != 'closed'",
                "CREATE INDEX IF NOT EXISTS service_tunnel_operation_idx ON service_tunnel_sessions(operation_group_id, generation)",
                "CREATE INDEX IF NOT EXISTS service_tunnel_recovery_idx ON service_tunnel_sessions(lifecycle_state, updated_at_ms)"
            ]
        )
    ]
}
