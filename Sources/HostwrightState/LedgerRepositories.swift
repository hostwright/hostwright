import HostwrightRuntime

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
