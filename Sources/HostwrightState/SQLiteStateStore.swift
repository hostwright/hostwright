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
                message: "SQLite state store requires an explicit local database path. No default user database path is used."
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
        try configuration.validate()
        let connection = try SQLiteConnection(path: configuration.databasePath, createIfNeeded: createIfNeeded, readOnly: readOnly)
        return try body(connection)
    }

    func withValidatedConnection<T>(readOnly: Bool = false, _ body: (SQLiteConnection) throws -> T) throws -> T {
        try configuration.validate()
        let connection = try SQLiteConnection(path: configuration.databasePath, createIfNeeded: false, readOnly: readOnly)
        try MigrationRunner().validateAppliedSchema(on: connection)
        return try body(connection)
    }
}
