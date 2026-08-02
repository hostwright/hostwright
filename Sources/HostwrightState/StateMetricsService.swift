import CryptoKit
import Foundation
import HostwrightObservability

public struct StateMetricsService: Sendable {
    private struct Projection {
        var series: [HostwrightMetricSeries]
        var slos: [HostwrightSLOResult]
    }

    private struct SnapshotIdentity: Codable {
        let schemaVersion: Int
        let kind: String
        let source: HostwrightMetricsSource
        let series: [HostwrightMetricSeries]
        let slos: [HostwrightSLOResult]
        let retention: HostwrightMetricsRetention
    }

    private let store: SQLiteStateStore
    private let date: @Sendable () -> Date

    public init(
        store: SQLiteStateStore,
        date: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.date = date
    }

    public func snapshot() throws -> HostwrightMetricsSnapshot {
        let result = try store.withValidatedConnection(readOnly: true) { connection in
            let before = try StateMaintenanceFileSupport.fingerprint(store.path)
            let dataVersionBefore = try requiredUInt64(
                connection.query("PRAGMA data_version").first?.first ?? nil,
                context: "SQLite data version"
            )
            let projection = try connection.transaction {
                try project(connection)
            }
            let dataVersionAfter = try requiredUInt64(
                connection.query("PRAGMA data_version").first?.first ?? nil,
                context: "SQLite data version"
            )
            let after = try StateMaintenanceFileSupport.fingerprint(store.path)
            guard before == after, dataVersionBefore == dataVersionAfter else {
                throw StateStoreError.transactionOutcomeUncertain(
                    path: store.path,
                    message: "the authoritative database changed during the metrics snapshot"
                )
            }
            return (before, projection)
        }

        let source = HostwrightMetricsSource(
            schemaVersion: MigrationRunner.latestSchemaVersion,
            databaseSHA256: result.0.sha256,
            databaseBytes: result.0.bytes
        )
        let retention = HostwrightMetricsRetention()
        let identity = SnapshotIdentity(
            schemaVersion: HostwrightMetricCatalog.schemaVersion,
            kind: "hostwright.metrics.snapshot",
            source: source,
            series: result.1.series,
            slos: result.1.slos,
            retention: retention
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(identity))
            .map { String(format: "%02x", $0) }
            .joined()
        return HostwrightMetricsSnapshot(
            generatedAt: ISO8601DateFormatter().string(from: date()),
            source: source,
            series: result.1.series,
            slos: result.1.slos,
            retention: retention,
            snapshotSHA256: digest
        )
    }

    private func project(_ connection: SQLiteConnection) throws -> Projection {
        var dropped = Dictionary(
            uniqueKeysWithValues: HostwrightMetricCatalog.droppedReasons.map { ($0, UInt64(0)) }
        )
        let groupOutcomes = try groupedCounts(
            connection,
            sql: """
            SELECT CASE
                     WHEN status IN ('active','failed','interrupted','succeeded') THEN status
                     ELSE 'invalid-record'
                   END, COUNT(*)
            FROM operation_groups
            GROUP BY 1
            ORDER BY 1
            """
        )
        let apiOutcomes = consume(
            groupOutcomes,
            allowed: Set(HostwrightMetricCatalog.outcomes),
            dropped: &dropped
        )
        let runtimeOutcomes = consume(
            try groupedCounts(
                connection,
                sql: """
                SELECT CASE
                         WHEN status IN ('active','failed','interrupted','succeeded') THEN status
                         ELSE 'invalid-record'
                       END, COUNT(*)
                FROM operation_groups
                WHERE group_kind IN ('apply','legacy-restart','lifecycle-v1')
                GROUP BY 1
                ORDER BY 1
                """
            ),
            allowed: Set(HostwrightMetricCatalog.outcomes),
            dropped: &dropped
        )

        let reconciliationOutcomes = consume(
            try groupedCounts(
                connection,
                sql: """
                SELECT CASE
                         WHEN status IN ('succeeded','failed') THEN status
                         ELSE 'invalid-record'
                       END, COUNT(*)
                FROM operation_ledger
                WHERE planned_action_type = 'daemon.reconcile'
                GROUP BY 1
                ORDER BY 1
                """
            ),
            allowed: ["failed", "succeeded"],
            dropped: &dropped
        )

        var scheduling = consume(
            try groupedCounts(
                connection,
                sql: """
                SELECT CASE
                         WHEN decision IN ('admitted','denied','hold','stable-reset','manual-release','failed') THEN decision
                         ELSE 'invalid-record'
                       END, COUNT(*)
                FROM restart_attempt_history
                GROUP BY 1
                ORDER BY 1
                """
            ),
            allowed: Set(HostwrightMetricCatalog.schedulingDecisions),
            dropped: &dropped
        )
        let maintenanceScheduling = consume(
            try groupedCounts(
                connection,
                sql: """
                SELECT CASE
                         WHEN json_extract(payload_json_redacted, '$.state') IN
                              ('admitted','cancelled','deferred','failed','override-authorized','superseded')
                           THEN json_extract(payload_json_redacted, '$.state')
                         ELSE 'invalid-record'
                       END, COUNT(*)
                FROM operation_ledger
                WHERE planned_action_type = 'maintenance.deferral'
                GROUP BY 1
                ORDER BY 1
                """
            ),
            allowed: Set(HostwrightMetricCatalog.schedulingDecisions),
            dropped: &dropped
        )
        merge(maintenanceScheduling, into: &scheduling, dropped: &dropped)

        let health = consume(
            try groupedCounts(
                connection,
                sql: """
                SELECT CASE
                         WHEN status IN ('healthy','notConfigured','skipped','unhealthy','unknown') THEN status
                         ELSE 'invalid-record'
                       END, COUNT(*)
                FROM health_check_results
                GROUP BY 1
                ORDER BY 1
                """
            ),
            allowed: Set(HostwrightMetricCatalog.healthStatuses),
            dropped: &dropped
        )
        let retries = consume(
            try groupedCounts(
                connection,
                sql: """
                SELECT CASE
                         WHEN decision IN ('admitted','denied','hold','stable-reset','manual-release','failed') THEN decision
                         ELSE 'invalid-record'
                       END, COUNT(*)
                FROM restart_attempt_history
                GROUP BY 1
                ORDER BY 1
                """
            ),
            allowed: Set(HostwrightMetricCatalog.retryDecisions),
            dropped: &dropped
        )
        let gc = [
            "planned": try count(
                connection,
                "SELECT COUNT(*) FROM event_ledger WHERE type = 'cleanup.planned'"
            ),
            "succeeded": try count(
                connection,
                "SELECT COUNT(*) FROM event_ledger WHERE type IN ('cleanup.deleted','state.retention.compaction') AND severity != 'error'"
            ),
            "failed": try count(
                connection,
                "SELECT COUNT(*) FROM event_ledger WHERE type = 'cleanup.failed' OR (type = 'state.retention.compaction' AND severity = 'error')"
            )
        ]

        var errors = Dictionary(
            uniqueKeysWithValues: HostwrightMetricCatalog.components.map { ($0, UInt64(0)) }
        )
        merge(try errorEventCounts(connection), into: &errors, dropped: &dropped)
        merge(
            [
                "api": apiOutcomes["failed", default: 0]
                    + apiOutcomes["interrupted", default: 0]
            ],
            into: &errors,
            dropped: &dropped
        )
        merge(
            ["runtime": runtimeOutcomes["failed", default: 0]],
            into: &errors,
            dropped: &dropped
        )
        merge(
            ["reconciliation": reconciliationOutcomes["failed", default: 0]],
            into: &errors,
            dropped: &dropped
        )

        let operationDurations = try durationHistogram(connection, dropped: &dropped)
        let reconciliationDurations = try reconciliationSummary(connection, dropped: &dropped)

        var series: [HostwrightMetricSeries] = []
        appendCounter(
            "hostwright_api_requests_total",
            label: "outcome",
            values: HostwrightMetricCatalog.outcomes,
            counts: apiOutcomes,
            to: &series
        )
        appendCounter(
            "hostwright_reconciliation_iterations_total",
            label: "outcome",
            values: ["failed", "succeeded"],
            counts: reconciliationOutcomes,
            to: &series
        )
        appendCounter(
            "hostwright_scheduling_decisions_total",
            label: "decision",
            values: HostwrightMetricCatalog.schedulingDecisions,
            counts: scheduling,
            to: &series
        )
        appendCounter(
            "hostwright_runtime_actions_total",
            label: "outcome",
            values: HostwrightMetricCatalog.outcomes,
            counts: runtimeOutcomes,
            to: &series
        )
        appendCounter(
            "hostwright_health_checks_total",
            label: "status",
            values: HostwrightMetricCatalog.healthStatuses,
            counts: health,
            to: &series
        )
        appendCounter(
            "hostwright_retries_total",
            label: "decision",
            values: HostwrightMetricCatalog.retryDecisions,
            counts: retries,
            to: &series
        )
        appendCounter(
            "hostwright_gc_decisions_total",
            label: "outcome",
            values: ["failed", "planned", "succeeded"],
            counts: gc,
            to: &series
        )
        appendCounter(
            "hostwright_errors_total",
            label: "component",
            values: HostwrightMetricCatalog.components,
            counts: errors,
            to: &series
        )

        let storage = [
            "backup": try count(connection, "SELECT COUNT(*) FROM storage_backups"),
            "snapshot": try count(connection, "SELECT COUNT(*) FROM storage_snapshots"),
            "volume": try count(connection, "SELECT COUNT(*) FROM storage_volumes")
        ]
        appendGauge(
            "hostwright_storage_resources",
            label: "resource",
            values: ["backup", "snapshot", "volume"],
            counts: storage,
            to: &series
        )
        let network = [
            "attachment": try count(connection, "SELECT COUNT(*) FROM network_attachments"),
            "network": try count(connection, "SELECT COUNT(*) FROM network_resources"),
            "port-reservation": try count(connection, "SELECT COUNT(*) FROM network_port_reservations")
        ]
        appendGauge(
            "hostwright_network_resources",
            label: "resource",
            values: ["attachment", "network", "port-reservation"],
            counts: network,
            to: &series
        )
        let managed = [
            "health-result": try count(connection, "SELECT COUNT(*) FROM health_check_results"),
            "operation-group": try count(connection, "SELECT COUNT(*) FROM operation_groups"),
            "ownership": try count(connection, "SELECT COUNT(*) FROM ownership_records")
        ]
        appendGauge(
            "hostwright_managed_resources",
            label: "resource",
            values: ["health-result", "operation-group", "ownership"],
            counts: managed,
            to: &series
        )
        series.append(HostwrightMetricSeries(
            name: "hostwright_state_database_bytes",
            type: .gauge,
            value: try StateMaintenanceFileSupport.fingerprint(store.path).bytes
        ))
        series.append(HostwrightMetricSeries(
            name: "hostwright_operation_duration_seconds",
            type: .histogram,
            histogram: operationDurations.histogram
        ))
        series.append(HostwrightMetricSeries(
            name: "hostwright_reconciliation_duration_seconds",
            type: .summary,
            summary: reconciliationDurations.summary
        ))
        appendCounter(
            "hostwright_metrics_dropped_samples_total",
            label: "reason",
            values: HostwrightMetricCatalog.droppedReasons,
            counts: dropped,
            to: &series
        )
        series.sort(by: seriesSort)
        try HostwrightMetricCatalog.validate(series)

        return Projection(
            series: series,
            slos: slos(
                reconciliation: reconciliationOutcomes,
                runtime: runtimeOutcomes,
                durationCount: reconciliationDurations.summary.count,
                durationBuckets: reconciliationDurations.cumulativeCounts,
                durationMaximum: reconciliationDurations.summary.maximum
            )
        )
    }

    private func durationHistogram(
        _ connection: SQLiteConnection,
        dropped: inout [String: UInt64]
    ) throws -> (histogram: HostwrightMetricHistogram, cumulativeCounts: [UInt64]) {
        let duration = "((julianday(updated_at) - julianday(created_at)) * 86400.0)"
        let bucketSQL = HostwrightMetricCatalog.histogramBoundaries.map {
            "COALESCE(SUM(CASE WHEN \(duration) BETWEEN 0 AND \($0) THEN 1 ELSE 0 END), 0)"
        }.joined(separator: ", ")
        let row = try connection.query(
            """
            SELECT COUNT(CASE WHEN \(duration) BETWEEN 0 AND 86400 THEN 1 END),
                   COALESCE(SUM(CASE WHEN \(duration) BETWEEN 0 AND 86400 THEN \(duration) ELSE 0 END), 0),
                   \(bucketSQL),
                   COALESCE(SUM(CASE WHEN \(duration) IS NULL OR \(duration) < 0 OR \(duration) > 86400 THEN 1 ELSE 0 END), 0)
            FROM operation_groups
            WHERE status != 'active'
            """
        ).first ?? []
        guard row.count == HostwrightMetricCatalog.histogramBoundaries.count + 3 else {
            throw StateStoreError.invalidRecord("The operation-duration aggregate shape is invalid.")
        }
        let count = try requiredUInt64(row[0], context: "operation duration count")
        let sum = try requiredDouble(row[1], context: "operation duration sum")
        let buckets = try row[2..<(2 + HostwrightMetricCatalog.histogramBoundaries.count)]
            .map { try requiredUInt64($0, context: "operation duration bucket") }
        let invalid = try requiredUInt64(row.last ?? nil, context: "operation duration invalid count")
        add(invalid, to: "unsupported-duration", in: &dropped)
        return (
            HostwrightMetricHistogram(
                boundaries: HostwrightMetricCatalog.histogramBoundaries,
                cumulativeCounts: buckets,
                count: count,
                sum: sum
            ),
            buckets
        )
    }

    private func reconciliationSummary(
        _ connection: SQLiteConnection,
        dropped: inout [String: UInt64]
    ) throws -> (summary: HostwrightMetricSummary, cumulativeCounts: [UInt64]) {
        let duration = "(CAST(json_extract(payload_json_redacted, '$.durationMilliseconds') AS REAL) / 1000.0)"
        let valid = "json_type(payload_json_redacted, '$.durationMilliseconds') IN ('integer','real') AND \(duration) BETWEEN 0 AND 86400"
        let bucketSQL = HostwrightMetricCatalog.histogramBoundaries.map {
            "COALESCE(SUM(CASE WHEN \(valid) AND \(duration) <= \($0) THEN 1 ELSE 0 END), 0)"
        }.joined(separator: ", ")
        let row = try connection.query(
            """
            SELECT COALESCE(SUM(CASE WHEN \(valid) THEN 1 ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN \(valid) THEN \(duration) ELSE 0 END), 0),
                   MIN(CASE WHEN \(valid) THEN \(duration) END),
                   MAX(CASE WHEN \(valid) THEN \(duration) END),
                   \(bucketSQL),
                   COALESCE(SUM(CASE WHEN \(valid) THEN 0 ELSE 1 END), 0)
            FROM operation_ledger
            WHERE planned_action_type = 'daemon.reconcile'
            """
        ).first ?? []
        guard row.count == HostwrightMetricCatalog.histogramBoundaries.count + 5 else {
            throw StateStoreError.invalidRecord("The reconciliation-duration aggregate shape is invalid.")
        }
        let count = try requiredUInt64(row[0], context: "reconciliation duration count")
        let sum = try requiredDouble(row[1], context: "reconciliation duration sum")
        let minimum = try optionalDouble(row[2], context: "reconciliation duration minimum")
        let maximum = try optionalDouble(row[3], context: "reconciliation duration maximum")
        let buckets = try row[4..<(4 + HostwrightMetricCatalog.histogramBoundaries.count)]
            .map { try requiredUInt64($0, context: "reconciliation duration bucket") }
        let invalid = try requiredUInt64(row.last ?? nil, context: "reconciliation duration invalid count")
        add(invalid, to: "unsupported-duration", in: &dropped)
        return (
            HostwrightMetricSummary(
                count: count,
                sum: sum,
                minimum: minimum,
                maximum: maximum,
                mean: count == 0 ? nil : sum / Double(count)
            ),
            buckets
        )
    }

    private func slos(
        reconciliation: [String: UInt64],
        runtime: [String: UInt64],
        durationCount: UInt64,
        durationBuckets: [UInt64],
        durationMaximum: Double?
    ) -> [HostwrightSLOResult] {
        let reconciliationSucceeded = reconciliation["succeeded", default: 0]
        let reconciliationTotal = reconciliationSucceeded + reconciliation["failed", default: 0]
        let runtimeSucceeded = runtime["succeeded", default: 0]
        let runtimeTotal = runtimeSucceeded
            + runtime["failed", default: 0]
            + runtime["interrupted", default: 0]
        let durationP95: Double?
        if durationCount >= 20 {
            let threshold = UInt64(ceil(Double(durationCount) * 0.95))
            durationP95 = zip(HostwrightMetricCatalog.histogramBoundaries, durationBuckets)
                .first(where: { $0.1 >= threshold })?.0 ?? durationMaximum
        } else {
            durationP95 = nil
        }
        return [
            ratioSLO(
                name: "reconciliation-success-ratio",
                numerator: reconciliationSucceeded,
                denominator: reconciliationTotal,
                target: 0.99
            ),
            ratioSLO(
                name: "runtime-action-success-ratio",
                numerator: runtimeSucceeded,
                denominator: runtimeTotal,
                target: 0.99
            ),
            HostwrightSLOResult(
                name: "reconciliation-duration-p95",
                status: durationP95.map { $0 <= 5 ? .met : .notMet } ?? .insufficientData,
                comparison: "<=",
                target: 5,
                observed: durationP95,
                sampleCount: durationCount,
                unit: "seconds"
            )
        ].sorted { $0.name < $1.name }
    }

    private func ratioSLO(
        name: String,
        numerator: UInt64,
        denominator: UInt64,
        target: Double
    ) -> HostwrightSLOResult {
        let observed = denominator >= 20 ? Double(numerator) / Double(denominator) : nil
        return HostwrightSLOResult(
            name: name,
            status: observed.map { $0 >= target ? .met : .notMet } ?? .insufficientData,
            comparison: ">=",
            target: target,
            observed: observed,
            sampleCount: denominator,
            numerator: numerator,
            denominator: denominator,
            unit: "ratio"
        )
    }

    private func groupedCounts(
        _ connection: SQLiteConnection,
        sql: String
    ) throws -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for row in try connection.query(sql) {
            guard row.count == 2, let key = row[0] else {
                throw StateStoreError.invalidRecord("A metrics aggregate row has an invalid shape.")
            }
            result[key] = try requiredUInt64(row[1], context: "metric aggregate")
        }
        return result
    }

    private func consume(
        _ source: [String: UInt64],
        allowed: Set<String>,
        dropped: inout [String: UInt64]
    ) -> [String: UInt64] {
        var accepted: [String: UInt64] = [:]
        for (key, value) in source {
            if allowed.contains(key) {
                accepted[key] = value
            } else {
                add(value, to: "invalid-record", in: &dropped)
            }
        }
        return accepted
    }

    private func merge(
        _ source: [String: UInt64],
        into destination: inout [String: UInt64],
        dropped: inout [String: UInt64]
    ) {
        for (key, value) in source {
            let existing = destination[key, default: 0]
            let sum = existing.addingReportingOverflow(value)
            if sum.overflow {
                destination[key] = UInt64.max
                add(1, to: "overflow", in: &dropped)
            } else {
                destination[key] = sum.partialValue
            }
        }
    }

    private func add(
        _ value: UInt64,
        to key: String,
        in counts: inout [String: UInt64]
    ) {
        let result = counts[key, default: 0].addingReportingOverflow(value)
        counts[key] = result.overflow ? UInt64.max : result.partialValue
    }

    private func appendCounter(
        _ name: String,
        label: String,
        values: [String],
        counts: [String: UInt64],
        to series: inout [HostwrightMetricSeries]
    ) {
        for value in values.sorted() {
            series.append(HostwrightMetricSeries(
                name: name,
                type: .counter,
                labels: [label: value],
                value: counts[value, default: 0]
            ))
        }
    }

    private func appendGauge(
        _ name: String,
        label: String,
        values: [String],
        counts: [String: UInt64],
        to series: inout [HostwrightMetricSeries]
    ) {
        for value in values.sorted() {
            series.append(HostwrightMetricSeries(
                name: name,
                type: .gauge,
                labels: [label: value],
                value: counts[value, default: 0]
            ))
        }
    }

    private func count(_ connection: SQLiteConnection, _ sql: String) throws -> UInt64 {
        try requiredUInt64(connection.query(sql).first?.first ?? nil, context: "metric count")
    }

    private func requiredUInt64(_ value: String?, context: String) throws -> UInt64 {
        guard let value, let result = UInt64(value) else {
            throw StateStoreError.invalidRecord("The \(context) is not an unsigned bounded integer.")
        }
        return result
    }

    private func requiredDouble(_ value: String?, context: String) throws -> Double {
        guard let value, let result = Double(value), result.isFinite, result >= 0 else {
            throw StateStoreError.invalidRecord("The \(context) is not a finite non-negative number.")
        }
        return result
    }

    private func optionalDouble(_ value: String?, context: String) throws -> Double? {
        guard let value else { return nil }
        return try requiredDouble(value, context: context)
    }

    private func errorEventCounts(_ connection: SQLiteConnection) throws -> [String: UInt64] {
        try groupedCounts(
            connection,
            sql: """
            SELECT CASE
                     WHEN type GLOB 'control.*' OR type GLOB 'operator.*' THEN 'api'
                     WHEN type GLOB 'cleanup.*' OR type GLOB 'gc.*' OR type GLOB 'state.retention.*' THEN 'gc'
                     WHEN type GLOB 'health.*' THEN 'health'
                     WHEN type GLOB 'network.*' OR type GLOB 'tunnel.*' THEN 'network'
                     WHEN type GLOB 'daemon.reconcile.*' THEN 'reconciliation'
                     WHEN type GLOB 'lifecycle.*' OR type GLOB 'runtime.*' THEN 'runtime'
                     WHEN type GLOB 'maintenance.*' OR type GLOB 'restart.*' THEN 'scheduling'
                     WHEN type GLOB 'storage.*' OR type GLOB 'volume.*' THEN 'storage'
                     ELSE 'state'
                   END, COUNT(*)
            FROM event_ledger
            WHERE severity = 'error'
            GROUP BY 1
            ORDER BY 1
            """
        )
    }

    private func seriesSort(
        _ lhs: HostwrightMetricSeries,
        _ rhs: HostwrightMetricSeries
    ) -> Bool {
        let left = lhs.name + "|" + lhs.labels.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let right = rhs.name + "|" + rhs.labels.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return left < right
    }
}
