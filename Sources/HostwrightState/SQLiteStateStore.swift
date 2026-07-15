public struct SQLiteStateStore: StateStore {
    public let configuration: StateStoreConfiguration

    public var path: String {
        configuration.databasePath
    }

    public var desiredStates: DesiredStateRepository {
        DesiredStateRepository(store: self)
    }

    public var observedStates: ObservedStateRepository {
        ObservedStateRepository(store: self)
    }

    public var events: EventLedger {
        EventLedger(store: self)
    }

    public var operations: OperationLedger {
        OperationLedger(store: self)
    }

    public var operationGroups: OperationGroupRepository {
        OperationGroupRepository(store: self)
    }

    public var operationGroupSteps: OperationGroupStepRepository {
        OperationGroupStepRepository(store: self)
    }

    public var healthResults: HealthCheckResultRepository {
        HealthCheckResultRepository(store: self)
    }

    public var restartPolicies: RestartPolicyStateRepository {
        RestartPolicyStateRepository(store: self)
    }

    public var restartRecovery: RestartRecoveryRecordRepository {
        RestartRecoveryRecordRepository(store: self)
    }

    public var ownership: OwnershipRepository {
        OwnershipRepository(store: self)
    }

    public var diagnostics: DiagnosticsExportRepository {
        DiagnosticsExportRepository(store: self)
    }

    public init(path: String) {
        self.configuration = StateStoreConfiguration(explicitDatabasePath: path)
    }

    public init(configuration: StateStoreConfiguration) {
        self.configuration = configuration
    }

    public func describe() async -> StateStoreDescription {
        StateStoreDescription(
            backend: .sqlite,
            isImplemented: true,
            message: "SQLite state uses a secure explicit override or the macOS Application Support default."
        )
    }

    public func migrate() throws {
        try configuration.validate()
        try MigrationRunner().apply(to: self)
    }

    public func validateSchema() throws {
        try configuration.validate()
        try withConnection(createIfNeeded: false, readOnly: true) { connection in
            try MigrationRunner().validateAppliedSchema(on: connection)
        }
    }

    public func schemaVersion() throws -> Int {
        try configuration.validate()
        let versions = try MigrationRunner().appliedVersions(in: self)
        return versions.max() ?? 0
    }

    func withConnection<T>(createIfNeeded: Bool = true, readOnly: Bool = false, _ body: (SQLiteConnection) throws -> T) throws -> T {
        try configuration.prepareStateAccessFoundation()
        let accessMode: StateAccessMode = readOnly ? .shared : .write
        return try StateAccessCoordinator(configuration: configuration).withLock(accessMode) {
            let databaseExisted = StateMaintenanceFileSupport.exists(configuration.databasePath)
            let expectedIdentity = try configuration.prepare(createIfNeeded: createIfNeeded)
            if !readOnly, databaseExisted {
                try preflightExistingDatabaseForWrite(
                    expectedIdentity: expectedIdentity,
                    requireLatestSchema: false
                )
            }
            let connection = try SQLiteConnection(
                path: configuration.databasePath,
                createIfNeeded: createIfNeeded,
                readOnly: readOnly,
                profile: .authoritativeState
            )
            defer { try? connection.close() }
            let openedIdentity = try configuration.validateSQLiteFileSet()
            guard expectedIdentity == openedIdentity else {
                throw StateStoreError.pathPolicyViolation(
                    path: configuration.databasePath,
                    message: "the state database identity changed while SQLite was opening it"
                )
            }
            let result = try body(connection)
            try connection.close()
            return result
        }
    }

    func withValidatedConnection<T>(readOnly: Bool = false, _ body: (SQLiteConnection) throws -> T) throws -> T {
        try configuration.prepareStateAccessFoundation()
        let accessMode: StateAccessMode = readOnly ? .shared : .write
        return try StateAccessCoordinator(configuration: configuration).withLock(accessMode) {
            let expectedIdentity = try configuration.prepare(createIfNeeded: false)
            if !readOnly {
                try preflightExistingDatabaseForWrite(
                    expectedIdentity: expectedIdentity,
                    requireLatestSchema: true
                )
            }
            let connection = try SQLiteConnection(
                path: configuration.databasePath,
                createIfNeeded: false,
                readOnly: readOnly,
                profile: .authoritativeState
            )
            defer { try? connection.close() }
            let openedIdentity = try configuration.validateSQLiteFileSet()
            guard expectedIdentity == openedIdentity else {
                throw StateStoreError.pathPolicyViolation(
                    path: configuration.databasePath,
                    message: "the state database identity changed while SQLite was opening it"
                )
            }
            try MigrationRunner().validateAppliedSchema(on: connection)
            let result = try body(connection)
            try connection.close()
            return result
        }
    }

    private func preflightExistingDatabaseForWrite(
        expectedIdentity: FileIdentity?,
        requireLatestSchema: Bool
    ) throws {
        let connection = try SQLiteConnection(
            path: configuration.databasePath,
            createIfNeeded: false,
            readOnly: true,
            profile: .authoritativeState
        )
        defer { try? connection.close() }
        let openedIdentity = try configuration.validateSQLiteFileSet()
        guard expectedIdentity == openedIdentity else {
            throw StateStoreError.pathPolicyViolation(
                path: configuration.databasePath,
                message: "the state database identity changed during the non-mutating compatibility preflight"
            )
        }
        if requireLatestSchema {
            try MigrationRunner().validateAppliedSchema(on: connection)
        } else {
            _ = try MigrationRunner().compatibleSchemaVersion(on: connection)
        }
        try connection.close()
        let closedIdentity = try configuration.validateSQLiteFileSet()
        guard expectedIdentity == closedIdentity else {
            throw StateStoreError.pathPolicyViolation(
                path: configuration.databasePath,
                message: "the state database identity changed while completing the non-mutating compatibility preflight"
            )
        }
    }
}
