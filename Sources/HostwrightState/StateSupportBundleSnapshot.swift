import Foundation
import HostwrightObservability
import HostwrightRuntime

public struct StateSupportBundleSnapshot: Equatable, Sendable {
    public let integrity: HostwrightSupportStateIntegrity
    public let events: [HostwrightSupportEventRecord]
    public let droppedEvents: Int
    public let metrics: HostwrightMetricsSnapshot
    public let traces: [HostwrightTraceView]
    public let droppedTraces: Int
    public let operations: [HostwrightSupportOperationRecord]
    public let droppedOperations: Int
    public let evidence: [HostwrightSupportEvidenceRecord]
    public let droppedEvidence: Int

    public init(
        integrity: HostwrightSupportStateIntegrity,
        events: [HostwrightSupportEventRecord],
        droppedEvents: Int,
        metrics: HostwrightMetricsSnapshot,
        traces: [HostwrightTraceView],
        droppedTraces: Int,
        operations: [HostwrightSupportOperationRecord],
        droppedOperations: Int,
        evidence: [HostwrightSupportEvidenceRecord],
        droppedEvidence: Int
    ) {
        self.integrity = integrity
        self.events = events
        self.droppedEvents = droppedEvents
        self.metrics = metrics
        self.traces = traces
        self.droppedTraces = droppedTraces
        self.operations = operations
        self.droppedOperations = droppedOperations
        self.evidence = evidence
        self.droppedEvidence = droppedEvidence
    }
}

public struct StateSupportBundleSnapshotService: Sendable {
    private let store: SQLiteStateStore
    private let date: @Sendable () -> Date

    public init(store: SQLiteStateStore, date: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.date = date
    }

    public func collect(projectID: String?) throws -> StateSupportBundleSnapshot {
        try store.withValidatedConnection(readOnly: true) { connection in
            let before = try StateMaintenanceFileSupport.fingerprint(store.path)
            let dataVersionBefore = try dataVersion(connection)
            let integrity = try supportIntegrity(
                StateIntegrityService(store: store).inspect(
                    connection: connection,
                    fingerprint: before
                )
            )
            let events = try loadEvents(projectID: projectID, evidence: false)
            let operations = try loadOperations(projectID: projectID)
            let evidence = try loadEvents(projectID: projectID, evidence: true)
            let rawMetrics = try StateMetricsService(store: store, date: date).snapshot()
            let metrics = HostwrightMetricsSnapshot(
                generatedAt: "1970-01-01T00:00:00Z",
                source: rawMetrics.source,
                series: rawMetrics.series,
                slos: rawMetrics.slos,
                retention: rawMetrics.retention,
                snapshotSHA256: rawMetrics.snapshotSHA256
            )
            let tracePage = try StateTraceService(store: store, date: date).inspect(
                traceID: nil,
                limit: HostwrightSupportBundleContract.maximumTraces
            )
            let dataVersionAfter = try dataVersion(connection)
            let after = try StateMaintenanceFileSupport.fingerprint(store.path)
            guard before == after, dataVersionBefore == dataVersionAfter else {
                throw StateStoreError.databaseLocked(
                    path: store.path,
                    message: "state changed while collecting one support-bundle snapshot"
                )
            }
            return StateSupportBundleSnapshot(
                integrity: integrity,
                events: events.records.map {
                    HostwrightSupportEventRecord(
                        id: $0.id,
                        timestamp: $0.timestamp,
                        severity: $0.severity,
                        type: $0.type,
                        source: $0.source
                    )
                },
                droppedEvents: events.dropped,
                metrics: metrics,
                traces: tracePage.traces,
                droppedTraces: max(0, tracePage.retainedTraceCount - tracePage.traces.count),
                operations: operations.records,
                droppedOperations: operations.dropped,
                evidence: evidence.records.map {
                    HostwrightSupportEvidenceRecord(
                        id: $0.id,
                        timestamp: $0.timestamp,
                        severity: $0.severity,
                        type: $0.type,
                        source: $0.source
                    )
                },
                droppedEvidence: evidence.dropped
            )
        }
    }

    private func dataVersion(_ connection: SQLiteConnection) throws -> UInt64 {
        guard let value = try connection.query("PRAGMA data_version").first?.first ?? nil,
              let version = UInt64(value) else {
            throw StateStoreError.invalidRecord("SQLite data version is invalid.")
        }
        return version
    }

    private func supportIntegrity(_ report: StateIntegrityReport) throws -> HostwrightSupportStateIntegrity {
        guard let databaseSHA256 = report.databaseSHA256,
              HostwrightSupportBundleContract.isValidSHA256(databaseSHA256),
              let databaseBytes = report.databaseBytes,
              let stateSchemaVersion = report.stateSchemaVersion else {
            throw StateStoreError.invalidRecord("Support-bundle integrity evidence is incomplete.")
        }
        return HostwrightSupportStateIntegrity(
            health: report.health.rawValue,
            databaseSHA256: databaseSHA256,
            databaseBytes: databaseBytes,
            stateSchemaVersion: stateSchemaVersion,
            checks: report.checks.prefix(128).map {
                HostwrightSupportIntegrityCheck(identifier: safeField($0.identifier), status: $0.status.rawValue)
            }
        )
    }

    private func loadEvents(
        projectID: String?,
        evidence: Bool
    ) throws -> (records: [HostwrightSupportEventRecord], dropped: Int) {
        let maximum = evidence
            ? HostwrightSupportBundleContract.maximumEvidence
            : HostwrightSupportBundleContract.maximumEvents
        return try store.withValidatedConnection(readOnly: true) { connection in
            let auditPredicate = """
            (
                lower(type) IN (
                    'restart.policy.manual-release',
                    'team.approval.recorded',
                    'team.profile.selected'
                )
                OR lower(type) LIKE 'image.provenance.%'
                OR lower(type) LIKE 'image.sbom.%'
                OR lower(type) LIKE 'image.trust.%'
                OR lower(type) LIKE 'image.vulnerability.%'
                OR lower(type) LIKE 'secret.%'
                OR lower(type) LIKE 'security.%'
                OR lower(type) LIKE 'state.maintenance.%'
                OR lower(type) LIKE 'state.retention.%'
                OR instr(lower(type) || '.' || lower(source), 'audit') > 0
                OR instr(lower(type) || '.' || lower(source), 'security') > 0
                OR instr(lower(type) || '.' || lower(source), 'maintenance') > 0
                OR instr(lower(type) || '.' || lower(source), 'retention') > 0
                OR instr(lower(type) || '.' || lower(source), 'operator') > 0
            )
            """
            let evidencePredicate = "(source = 'hostwright.support-bundle' OR \(auditPredicate))"
            var whereParts = [
                "NOT (type = ? AND source = ?)",
                evidence ? evidencePredicate : "NOT \(evidencePredicate)"
            ]
            var bindings: [SQLiteValue] = [
                .text(HostwrightTraceContract.eventType),
                .text(HostwrightTraceContract.source)
            ]
            if let projectID {
                whereParts.append("project_id = ?")
                bindings.append(.text(projectID))
            }
            let whereSQL = whereParts.joined(separator: " AND ")
            let count = try connection.query(
                "SELECT COUNT(*) FROM event_ledger WHERE \(whereSQL)",
                bindings: bindings
            ).first?.first.flatMap { $0 }.flatMap(Int.init) ?? 0
            var pageBindings = bindings
            pageBindings.append(.int(maximum))
            let rows = try connection.query(
                """
                SELECT id, timestamp, severity, type, source
                FROM event_ledger
                WHERE \(whereSQL)
                ORDER BY timestamp DESC, rowid DESC
                LIMIT ?
                """
                , bindings: pageBindings
            )
            var selected: [HostwrightSupportEventRecord] = []
            for row in rows {
                guard row.count == 5,
                      let id = row[0], let timestamp = row[1], let severity = row[2],
                      let type = row[3], let source = row[4] else {
                    continue
                }
                selected.append(HostwrightSupportEventRecord(
                    id: hashedIdentity(id),
                    timestamp: safeTimestamp(timestamp),
                    severity: ["info", "warning", "error"].contains(severity) ? severity : "invalid",
                    type: safeField(type),
                    source: safeField(source)
                ))
            }
            return (selected, max(0, count - selected.count))
        }
    }

    private func loadOperations(
        projectID: String?
    ) throws -> (records: [HostwrightSupportOperationRecord], dropped: Int) {
        try store.withValidatedConnection(readOnly: true) { connection in
            var whereSQL = ""
            var bindings: [SQLiteValue] = []
            if let projectID {
                whereSQL = " WHERE project_id = ?"
                bindings.append(.text(projectID))
            }
            let count = try connection.query(
                "SELECT COUNT(*) FROM operation_ledger\(whereSQL)",
                bindings: bindings
            ).first?.first.flatMap { $0 }.flatMap(Int.init) ?? 0
            var pageBindings = bindings
            pageBindings.append(.int(HostwrightSupportBundleContract.maximumOperations))
            let rows = try connection.query(
                """
                SELECT id, created_at, updated_at, planned_action_type, status, plan_hash
                FROM operation_ledger
                \(whereSQL)
                ORDER BY updated_at DESC, rowid DESC
                LIMIT ?
                """
                , bindings: pageBindings
            )
            var selected: [HostwrightSupportOperationRecord] = []
            for row in rows {
                guard row.count == 6,
                      let id = row[0], let createdAt = row[1], let updatedAt = row[2],
                      let action = row[3], let status = row[4], let planHash = row[5] else {
                    continue
                }
                selected.append(HostwrightSupportOperationRecord(
                    id: hashedIdentity(id),
                    createdAt: safeTimestamp(createdAt),
                    updatedAt: safeTimestamp(updatedAt),
                    plannedActionType: safeField(action),
                    status: safeField(status),
                    planHash: HostwrightSupportBundleContract.isValidSHA256(planHash) ? planHash : "invalid"
                ))
            }
            return (selected, max(0, count - selected.count))
        }
    }

    private func hashedIdentity(_ value: String) -> String {
        StateMaintenanceFileSupport.token(["hostwright-support-record-v1", value])
    }

    private func safeField(_ value: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) != nil,
              RuntimeRedactionPolicy.default.redact(value) == value,
              value.range(
                of: "(?i)(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{16,})",
                options: .regularExpression
              ) == nil else {
            return "redacted"
        }
        return value
    }

    private func safeTimestamp(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let parsed = formatter.date(from: value), formatter.string(from: parsed) == value else {
            return "invalid"
        }
        return value
    }
}
