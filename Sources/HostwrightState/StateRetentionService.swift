import Darwin
import Foundation
import HostwrightObservability

public struct StateRetentionService {
    public static let maximumCandidatesPerRun = 1_000
    private static let databaseTableAllowlist: Set<String> = [
        "operation_ledger", "operation_groups", "observed_runtime_snapshots", "health_check_results",
        "event_ledger", "network_attachments", "network_port_reservations",
        "network_certificates", "network_resources"
    ]

    public let store: SQLiteStateStore
    public let maintenance: StateMaintenanceService
    public let paths: StateMaintenancePaths

    private var journalPath: String { paths.journalPath + ".retention-v1" }

    public init(store: SQLiteStateStore) throws {
        self.store = store
        self.maintenance = try StateMaintenanceService(store: store)
        self.paths = try store.configuration.maintenancePaths()
    }

    public func status(
        policy: StateRetentionPolicy,
        at date: Date = Date()
    ) throws -> StateRetentionStatus {
        let snapshot: StateRetentionSnapshot
        if StateMaintenanceFileSupport.exists(journalPath) {
            snapshot = try StateUpgradeService(store: store).withExclusiveLifecycleFence(
                allowPendingMaintenance: true
            ) {
                try makeSnapshotUnderFence(policy: policy, at: date)
            }
        } else {
            snapshot = try makeSnapshot(policy: policy, at: date)
        }
        return StateRetentionStatus(
            policySHA256: snapshot.policySHA256,
            databaseSHA256: snapshot.database.sha256,
            databaseBytes: snapshot.database.bytes,
            pressure: snapshot.pressure,
            classes: snapshot.classStatuses,
            blockers: snapshot.blockers,
            pendingCompactionPlanSHA256: try pendingPlanSHA256()
        )
    }

    public func compactionPlan(
        policy: StateRetentionPolicy,
        at date: Date = Date()
    ) throws -> StateCompactionPlan {
        let snapshot = try makeSnapshot(
            policy: policy,
            at: canonicalEvaluationDate(date)
        )
        return publicPlan(snapshot)
    }

    public func compact(
        policy: StateRetentionPolicy,
        confirmationToken: String,
        evaluatedAt: String
    ) throws -> StateCompactionResult {
        try compactInternal(
            policy: policy,
            confirmationToken: confirmationToken,
            at: try evaluationDate(evaluatedAt),
            interruptAfter: nil
        )
    }

    public func compact(
        policy: StateRetentionPolicy,
        confirmationToken: String,
        at date: Date = Date()
    ) throws -> StateCompactionResult {
        try compactInternal(
            policy: policy,
            confirmationToken: confirmationToken,
            at: canonicalEvaluationDate(date),
            interruptAfter: nil
        )
    }

    func compactForTesting(
        policy: StateRetentionPolicy,
        confirmationToken: String,
        at date: Date,
        interruptAfter checkpoint: StateRetentionInterruptionCheckpoint
    ) throws -> StateCompactionResult {
        try compactInternal(
            policy: policy,
            confirmationToken: confirmationToken,
            at: date,
            interruptAfter: checkpoint
        )
    }

    private func compactInternal(
        policy: StateRetentionPolicy,
        confirmationToken: String,
        at date: Date,
        interruptAfter: StateRetentionInterruptionCheckpoint?
    ) throws -> StateCompactionResult {
        try Task.checkCancellation()
        try validateConfirmation(confirmationToken)
        if StateMaintenanceFileSupport.exists(journalPath) {
            return try StateUpgradeService(store: store).withExclusiveLifecycleFence(
                allowPendingMaintenance: true
            ) {
                let journal = try readJournal()
                guard journal.confirmationToken == confirmationToken,
                      journal.policySHA256 == policySHA256(policy) else {
                    throw StateMaintenanceError.confirmationMismatch
                }
                return try resume(journal: journal, resumed: true, interruptAfter: nil)
            }
        }

        let initial = try makeSnapshot(policy: policy, at: date)
        let plan = publicPlan(initial)
        guard plan.confirmationToken == confirmationToken else {
            throw StateMaintenanceError.confirmationMismatch
        }
        guard plan.executable else {
            throw StateMaintenanceError.unsafeCompaction(
                plan.blockers.isEmpty ? "the plan has no eligible records" : plan.blockers.joined(separator: "; ")
            )
        }
        try Task.checkCancellation()
        let preBackup = try maintenance.createBackup()
        guard preBackup.restorable else {
            throw StateMaintenanceError.unsafeCompaction("the pre-compaction backup is not restorable")
        }

        return try StateUpgradeService(store: store).withExclusiveLifecycleFence {
            guard !StateMaintenanceFileSupport.exists(paths.journalPath),
                  !StateMaintenanceFileSupport.exists(journalPath) else {
                throw StateMaintenanceError.operationInProgress(
                    StateMaintenanceFileSupport.exists(paths.journalPath) ? paths.journalPath : journalPath
                )
            }
            let revalidated = try makeSnapshotUnderFence(
                policy: policy,
                at: date,
                excludingBackupID: preBackup.backupID
            )
            guard publicPlan(revalidated).confirmationToken == confirmationToken else {
                throw StateMaintenanceError.confirmationMismatch
            }
            let journal = StateRetentionJournal(
                schemaVersion: 1,
                phase: .prepared,
                confirmationToken: confirmationToken,
                policySHA256: revalidated.policySHA256,
                sourceDatabaseSHA256: revalidated.database.sha256,
                sourceDatabaseBytes: revalidated.database.bytes,
                preCompactionBackupID: preBackup.backupID,
                candidates: revalidated.candidates,
                deletedRecords: [:],
                stagedBackupIDs: []
            )
            try writeNewJournal(journal)
            try inject(.prepared, requested: interruptAfter)
            return try StateUpgradeService(store: store).withExclusiveLifecycleFence(
                allowPendingMaintenance: true
            ) {
                try resume(journal: journal, resumed: false, interruptAfter: interruptAfter)
            }
        }
    }

    private func resume(
        journal initialJournal: StateRetentionJournal,
        resumed: Bool,
        interruptAfter: StateRetentionInterruptionCheckpoint?
    ) throws -> StateCompactionResult {
        var journal = initialJournal
        guard journal.schemaVersion == 1 else {
            throw StateMaintenanceError.recoveryFailed("unsupported retention journal schema")
        }
        let catalog = try maintenance.backupCatalog()
        guard catalog.backups.contains(where: {
            $0.backupID == journal.preCompactionBackupID && $0.restorable
        }) else {
            throw StateMaintenanceError.recoveryFailed(
                "the verified pre-compaction backup is missing; preserve the retention journal"
            )
        }

        if journal.phase == .prepared {
            let databaseCandidates = journal.candidates.filter { $0.table != StateRetentionCandidate.backupTable }
            try Task.checkCancellation()
            let disposition = try databaseCandidateDisposition(
                databaseCandidates,
                planSHA256: journal.confirmationToken
            )
            switch disposition {
            case .present:
                let current = try StateMaintenanceFileSupport.fingerprint(store.path)
                guard current.sha256 == journal.sourceDatabaseSHA256 else {
                    throw StateMaintenanceError.recoveryFailed(
                        "authoritative state changed before the prepared compaction transaction"
                    )
                }
                let deleted = try deleteDatabaseCandidates(
                    databaseCandidates,
                    planSHA256: journal.confirmationToken
                )
                try inject(.databaseTransactionCommitted, requested: interruptAfter)
                journal = journal.replacing(phase: .databaseCommitted, deletedRecords: deleted)
            case .committed(let deleted):
                journal = journal.replacing(phase: .databaseCommitted, deletedRecords: deleted)
            case .ambiguous:
                throw StateMaintenanceError.recoveryFailed(
                    "the prepared compaction has a mixed or unproven database result; preserve the retention journal"
                )
            }
            try replaceJournal(journal)
            try inject(.databaseCommitted, requested: interruptAfter)
        }

        if journal.phase == .databaseCommitted {
            try Task.checkCancellation()
            journal = journal.replacing(phase: .backupsStaged)
            try replaceJournal(journal)
            try inject(.backupsStaged, requested: interruptAfter)
        }

        if journal.phase == .backupsStaged {
            try Task.checkCancellation()
            let backupIDs = journal.candidates
                .filter { $0.table == StateRetentionCandidate.backupTable }
                .map(\.id)
                .sorted()
            let staged = try stageAndDeleteBackups(
                backupIDs,
                planSHA256: journal.confirmationToken,
                journal: &journal
            )
            if !staged.isEmpty {
                var counts = journal.deletedRecords
                counts[.backups, default: 0] += staged.count
                journal = journal.replacing(
                    phase: .backupsDeleted,
                    deletedRecords: counts,
                    stagedBackupIDs: staged
                )
            } else {
                journal = journal.replacing(phase: .backupsDeleted)
            }
            try replaceJournal(journal)
            try inject(.backupsDeleted, requested: interruptAfter)
        }

        if journal.phase == .backupsDeleted {
            try Task.checkCancellation()
            if journal.sourceDatabaseBytes > 0,
               journal.candidates.contains(where: { $0.table != StateRetentionCandidate.backupTable }) {
                try store.withValidatedConnection { connection in
                    try connection.vacuumAuthoritativeDatabase()
                }
            }
            journal = journal.replacing(phase: .vacuumComplete)
            try replaceJournal(journal)
            try inject(.vacuumComplete, requested: interruptAfter)
        }

        let report = maintenance.integrity()
        guard report.health == .healthy else {
            throw StateMaintenanceError.recoveryFailed(
                "post-compaction integrity failed; restore backup \(journal.preCompactionBackupID) and preserve \(journalPath)"
            )
        }
        try verifyTerminalEffects(journal)
        let after = try StateMaintenanceFileSupport.fingerprint(store.path)
        let result = StateCompactionResult(
            planSHA256: journal.confirmationToken,
            preCompactionBackupID: journal.preCompactionBackupID,
            deletedRecords: journal.deletedRecords,
            databaseBytesBefore: journal.sourceDatabaseBytes,
            databaseBytesAfter: after.bytes,
            integrityHealth: report.health,
            resumed: resumed
        )
        try Task.checkCancellation()
        try removeJournal()
        return result
    }

    private func makeSnapshot(
        policy: StateRetentionPolicy,
        at date: Date
    ) throws -> StateRetentionSnapshot {
        try validate(policy)
        let catalog = try maintenance.backupCatalog()
        return try store.withValidatedConnection(readOnly: true) { connection in
            try snapshot(policy: policy, at: date, catalog: catalog, connection: connection)
        }
    }

    private func makeSnapshotUnderFence(
        policy: StateRetentionPolicy,
        at date: Date,
        excludingBackupID: String? = nil
    ) throws -> StateRetentionSnapshot {
        try validate(policy)
        let catalog = try maintenance.backupCatalog()
        return try store.withValidatedConnection(readOnly: true) { connection in
            try snapshot(
                policy: policy,
                at: date,
                catalog: catalog,
                connection: connection,
                excludingBackupID: excludingBackupID
            )
        }
    }

    private func snapshot(
        policy: StateRetentionPolicy,
        at date: Date,
        catalog: StateBackupCatalog,
        connection: SQLiteConnection,
        excludingBackupID: String? = nil
    ) throws -> StateRetentionSnapshot {
        let database = try StateMaintenanceFileSupport.fingerprint(store.path)
        let policyDigest = policySHA256(policy)
        let activeHolds = policy.holds.filter { hold in
            guard let expiry = hold.expiresAt else { return true }
            return parseTimestamp(expiry).map { $0 > date } ?? true
        }
        var allCandidates: [StateRetentionCandidate] = []
        var statuses: [StateRetentionClassStatus] = []
        var blockers: [String] = []

        for retentionClass in StateRetentionClass.allCases {
            guard let classPolicy = policy.classes[retentionClass] else { continue }
            let rows: [StateRetentionRow]
            let available: Bool
            switch retentionClass {
            case .operations:
                rows = try operationRows(connection, at: date)
                available = true
            case .observations:
                rows = try observationRows(connection)
                available = true
            case .events:
                rows = try eventRows(connection, audits: false)
                available = true
            case .audits:
                rows = try eventRows(connection, audits: true)
                available = true
            case .backups:
                rows = backupRows(catalog, excludingBackupID: excludingBackupID)
                available = true
            case .tombstones:
                rows = try tombstoneRows(connection, at: date)
                available = true
            case .metrics:
                rows = []
                available = true
            case .traces:
                rows = try traceRows(connection)
                available = true
            case .supportEvidence:
                rows = try supportEvidenceRows(connection)
                available = true
            case .logs:
                rows = []
                available = false
            }

            let selection = select(
                rows: rows,
                retentionClass: retentionClass,
                policy: classPolicy,
                recoveryHorizon: policy.recoveryHorizonSeconds,
                holds: activeHolds,
                at: date,
                remainingCapacity: Self.maximumCandidatesPerRun - allCandidates.count
            )
            allCandidates += selection.candidates
            statuses.append(StateRetentionClassStatus(
                retentionClass: retentionClass,
                producerAvailable: available,
                currentRecords: rows.count,
                candidateRecords: selection.candidates.count,
                heldRecords: selection.held,
                recoveryCriticalRecords: selection.recoveryCritical,
                candidateIdentitySHA256: candidateDigest(selection.candidates),
                note: retentionClass == .metrics
                    ? "read-only projection; authoritative source rows retain under their owning classes"
                    : available
                    ? (selection.truncated ? "bounded candidate page; repeat with a fresh exact plan" : "producer available")
                    : "producer unavailable until its owning Phase 08 gate"
            ))
        }

        let candidateBytes = allCandidates.reduce(UInt64(0)) { $0 + $1.bytes }
        let pressure: StateRetentionPressure
        if database.bytes <= policy.maximumDatabaseBytes {
            pressure = .normal
        } else if allCandidates.isEmpty ||
                    candidateBytes < database.bytes - policy.targetDatabaseBytes {
            pressure = .held
            blockers.append("safe eligible records cannot prove reduction to the configured database target")
        } else {
            pressure = .eligible
        }
        let digest = candidateDigest(allCandidates)
        let safetyDigest = StateMaintenanceFileSupport.token(
            ["hostwright-retention-safety-v1"] + statuses
                .filter { $0.retentionClass != .backups }
                .sorted { $0.retentionClass.rawValue < $1.retentionClass.rawValue }
                .flatMap {
                    [
                        $0.retentionClass.rawValue,
                        String($0.producerAvailable),
                        String($0.currentRecords),
                        String($0.candidateRecords),
                        String($0.heldRecords),
                        String($0.recoveryCriticalRecords),
                        $0.candidateIdentitySHA256
                    ]
                }
        )
        let token = StateMaintenanceFileSupport.token([
            "hostwright-state-compaction-v2",
            evaluationTimestamp(date),
            policyDigest,
            database.sha256,
            String(database.bytes),
            digest,
            safetyDigest,
            blockers.sorted().joined(separator: "|")
        ])
        return StateRetentionSnapshot(
            evaluatedAt: evaluationTimestamp(date),
            policySHA256: policyDigest,
            database: database,
            pressure: pressure,
            classStatuses: statuses.sorted { $0.retentionClass.rawValue < $1.retentionClass.rawValue },
            candidates: allCandidates,
            candidateBytes: candidateBytes,
            blockers: blockers.sorted(),
            confirmationToken: token
        )
    }

    private func select(
        rows: [StateRetentionRow],
        retentionClass: StateRetentionClass,
        policy: StateRetentionClassPolicy,
        recoveryHorizon: Int,
        holds: [StateRetentionHold],
        at date: Date,
        remainingCapacity: Int
    ) -> StateRetentionSelection {
        let ordered = rows.sorted {
            if $0.date == $1.date { return $0.id > $1.id }
            return ($0.date ?? .distantFuture) > ($1.date ?? .distantFuture)
        }
        let maxAgeBoundary = date.addingTimeInterval(TimeInterval(-policy.maxAgeSeconds))
        let recoveryBoundary = date.addingTimeInterval(TimeInterval(-recoveryHorizon))
        var candidates: [StateRetentionCandidate] = []
        var held = 0
        var recoveryCritical = 0
        var eligibleSeen = 0
        var truncated = false
        for (index, row) in ordered.enumerated() {
            guard row.safe, let rowDate = row.date else {
                recoveryCritical += 1
                continue
            }
            let ageEligible = rowDate <= maxAgeBoundary
            let quotaEligible = index >= policy.maxRecords
            guard ageEligible || quotaEligible else { continue }
            guard index >= policy.minimumRecords, rowDate <= recoveryBoundary else {
                recoveryCritical += 1
                continue
            }
            if holds.contains(where: {
                $0.retentionClass == retentionClass && ($0.selector == "*" || $0.selector == row.id)
            }) {
                held += 1
                continue
            }
            eligibleSeen += 1
            if candidates.count < max(0, remainingCapacity) {
                candidates.append(StateRetentionCandidate(
                    retentionClass: retentionClass,
                    table: row.table,
                    id: row.id,
                    timestamp: row.timestamp,
                    identitySHA256: row.identitySHA256,
                    bytes: row.bytes
                ))
            } else {
                truncated = true
            }
        }
        if eligibleSeen > candidates.count { truncated = true }
        return StateRetentionSelection(
            candidates: candidates,
            held: held,
            recoveryCritical: recoveryCritical,
            truncated: truncated
        )
    }

    private func operationRows(
        _ connection: SQLiteConnection,
        at date: Date
    ) throws -> [StateRetentionRow] {
        let ledger: [StateRetentionRow] = try connection.query(
            """
            SELECT o.id, o.updated_at, o.status, o.plan_hash,
                   length(o.payload_json_redacted),
                   CASE WHEN o.status IN ('succeeded','failed','abandoned')
                         AND NOT EXISTS (SELECT 1 FROM operation_groups g WHERE g.operation_id = o.id)
                        THEN '1' ELSE '0' END
            FROM operation_ledger o
            ORDER BY o.updated_at DESC, o.rowid DESC
            """
        ).compactMap { row in
            guard row.count == 6, let id = row[0], let timestamp = row[1],
                  let status = row[2], let planHash = row[3] else { return nil }
            return retentionRow(
                table: "operation_ledger", id: id, timestamp: timestamp,
                identity: [status, planHash], bytes: row[4], safe: row[5] == "1"
            )
        }
        let referenceTables = [
            "image_digest_locks", "image_provenance_records", "image_sbom_records",
            "image_trust_verifications", "image_vulnerability_decisions",
            "image_vulnerability_exceptions", "image_vulnerability_reports",
            "network_attachments", "network_certificates", "network_dns_instances",
            "network_port_reservations", "network_resources", "oci_referrer_publications",
            "service_tunnel_sessions", "storage_attachments", "storage_backups",
            "storage_capacity_samples", "storage_holds", "storage_orphans",
            "storage_quotas", "storage_snapshots", "storage_volumes"
        ]
        let unreferenced = referenceTables.map {
            "NOT EXISTS (SELECT 1 FROM \($0) r WHERE r.operation_group_id = g.id)"
        }.joined(separator: " AND ")
        let groups: [StateRetentionRow] = try connection.query(
            """
            SELECT g.id, g.updated_at, g.status, g.operation_id, g.group_kind,
                   g.plan_hash, g.fencing_token, COALESCE(g.lock_owner, ''),
                   COALESCE(g.lock_expires_at, ''), COUNT(s.id),
                   COALESCE(group_concat(
                       s.id || ':' || s.status || ':' || s.updated_at,
                       '|' ORDER BY s.id
                   ), ''),
                   CASE WHEN g.status = 'succeeded'
                              AND (g.lock_owner IS NULL OR julianday(g.lock_expires_at) <= julianday(?))
                              AND \(unreferenced)
                        THEN '1' ELSE '0' END
            FROM operation_groups g
            LEFT JOIN operation_group_steps s ON s.group_id = g.id
            GROUP BY g.id
            ORDER BY g.updated_at DESC, g.rowid DESC
            """,
            bindings: [.text(ISO8601DateFormatter().string(from: date))]
        ).compactMap { row in
            guard row.count == 12, let id = row[0], let timestamp = row[1],
                  let status = row[2], let operationID = row[3], let groupKind = row[4],
                  let planHash = row[5], let fence = row[6], let lockOwner = row[7],
                  let lockExpiry = row[8], let stepCount = row[9],
                  let stepIdentity = row[10] else { return nil }
            return retentionRow(
                table: "operation_groups",
                id: id,
                timestamp: timestamp,
                identity: [
                    status, operationID, groupKind, planHash, fence, lockOwner,
                    lockExpiry, stepCount, stepIdentity
                ],
                bytes: nil,
                safe: row[11] == "1"
            )
        }
        return ledger + groups
    }

    private func observationRows(_ connection: SQLiteConnection) throws -> [StateRetentionRow] {
        let snapshots = try connection.query(
            """
            SELECT id, observed_at, runtime_adapter, parser_version,
                   length(redacted_summary) + length(capabilities_json)
            FROM observed_runtime_snapshots
            ORDER BY observed_at DESC, rowid DESC
            """
        ).compactMap { row -> StateRetentionRow? in
            guard row.count == 5, let id = row[0], let timestamp = row[1],
                  let adapter = row[2], let parser = row[3] else { return nil }
            return retentionRow(
                table: "observed_runtime_snapshots", id: id, timestamp: timestamp,
                identity: [adapter, parser], bytes: row[4], safe: true
            )
        }
        let health = try connection.query(
            """
            SELECT id, checked_at, status, service_name,
                   length(metadata_json_redacted) + length(stdout_redacted) + length(stderr_redacted)
            FROM health_check_results
            ORDER BY checked_at DESC, rowid DESC
            """
        ).compactMap { row -> StateRetentionRow? in
            guard row.count == 5, let id = row[0], let timestamp = row[1],
                  let status = row[2], let service = row[3] else { return nil }
            return retentionRow(
                table: "health_check_results", id: id, timestamp: timestamp,
                identity: [status, service], bytes: row[4], safe: true
            )
        }
        return snapshots + health
    }

    private func eventRows(
        _ connection: SQLiteConnection,
        audits: Bool
    ) throws -> [StateRetentionRow] {
        try connection.query(
            """
            SELECT id, timestamp, type, source,
                   length(message) + length(payload_json_redacted)
            FROM event_ledger
            WHERE NOT (type = ? AND source = ?)
              AND source != ?
            ORDER BY timestamp DESC, rowid DESC
            """,
            bindings: [
                .text(HostwrightTraceContract.eventType),
                .text(HostwrightTraceContract.source),
                .text(HostwrightSupportBundleContract.source)
            ]
        ).compactMap { row in
            guard row.count == 5, let id = row[0], let timestamp = row[1],
                  let type = row[2], let source = row[3] else { return nil }
            let audit = EventAuditClassifier.isAudit(type: type, source: source)
            guard audit == audits else { return nil }
            return retentionRow(
                table: "event_ledger", id: id, timestamp: timestamp,
                identity: [type, source], bytes: row[4], safe: true
            )
        }
    }

    private func supportEvidenceRows(_ connection: SQLiteConnection) throws -> [StateRetentionRow] {
        try connection.query(
            """
            SELECT id, timestamp, type, source,
                   length(message) + length(payload_json_redacted)
            FROM event_ledger
            WHERE source = ?
              AND type IN (?, ?, ?)
            ORDER BY timestamp DESC, rowid DESC
            """,
            bindings: [
                .text(HostwrightSupportBundleContract.source),
                .text(HostwrightSupportBundleContract.createdEventType),
                .text(HostwrightSupportBundleContract.deletedEventType),
                .text(HostwrightSupportBundleContract.failedEventType)
            ]
        ).compactMap { row in
            guard row.count == 5, let id = row[0], let timestamp = row[1],
                  let type = row[2], let source = row[3] else { return nil }
            return retentionRow(
                table: "event_ledger", id: id, timestamp: timestamp,
                identity: [type, source], bytes: row[4], safe: true
            )
        }
    }

    private func traceRows(_ connection: SQLiteConnection) throws -> [StateRetentionRow] {
        try connection.query(
            """
            SELECT id, timestamp, type, source,
                   length(message) + length(payload_json_redacted)
            FROM event_ledger
            WHERE type = ? AND source = ?
            ORDER BY timestamp DESC, rowid DESC
            """,
            bindings: [
                .text(HostwrightTraceContract.eventType),
                .text(HostwrightTraceContract.source)
            ]
        ).compactMap { row in
            guard row.count == 5, let id = row[0], let timestamp = row[1],
                  let type = row[2], let source = row[3] else { return nil }
            return retentionRow(
                table: "event_ledger", id: id, timestamp: timestamp,
                identity: [type, source], bytes: row[4], safe: true
            )
        }
    }

    private func backupRows(
        _ catalog: StateBackupCatalog,
        excludingBackupID: String?
    ) -> [StateRetentionRow] {
        catalog.backups.filter { $0.backupID != excludingBackupID }.map { backup in
            retentionRow(
                table: StateRetentionCandidate.backupTable,
                id: backup.backupID,
                timestamp: backup.createdAt ?? "",
                identity: [
                    backup.databaseSHA256 ?? "invalid",
                    String(backup.databaseBytes ?? 0),
                    String(backup.stateSchemaVersion ?? 0)
                ],
                bytes: backup.databaseBytes.map(String.init),
                safe: backup.restorable && backup.createdAt != nil && backup.databaseSHA256 != nil
            )
        }
    }

    private func tombstoneRows(
        _ connection: SQLiteConnection,
        at date: Date
    ) throws -> [StateRetentionRow] {
        let specifications: [(String, String, String, [String])] = [
            (
                "network_attachments",
                "lifecycle_state = 'detached' AND finalizer_state = 'released'",
                "updated_at",
                ["project_uuid", "resource_uuid", "network_uuid", "provider_id", "operation_group_id"]
            ),
            (
                "network_port_reservations",
                "lifecycle_state = 'released' AND finalizer_state = 'released'",
                "updated_at",
                ["project_uuid", "resource_uuid", "provider_id", "operation_group_id"]
            ),
            (
                "network_certificates",
                "lifecycle_state = 'deleted' AND finalizer_state = 'released'",
                "updated_at",
                ["project_uuid", "provider_id", "operation_group_id", "ownership_kind"]
            ),
            (
                "network_resources",
                "lifecycle_state = 'deleted' AND finalizer_state = 'released'",
                "updated_at",
                ["project_uuid", "provider_id", "operation_group_id"]
            )
        ]
        var rows: [StateRetentionRow] = []
        for (table, terminal, timestampColumn, authorityColumns) in specifications {
            let authoritySelection = authorityColumns.map { "t.\($0)" }.joined(separator: ", ")
            let selected = try connection.query(
                """
                SELECT t.id, t.\(timestampColumn), t.lifecycle_state, t.finalizer_state,
                       t.generation, t.provider_generation, t.fencing_token,
                       \(authoritySelection),
                       g.status, COALESCE(g.lock_owner, ''), COALESCE(g.lock_expires_at, ''),
                       CASE WHEN \(terminal.replacingOccurrences(of: "lifecycle_state", with: "t.lifecycle_state").replacingOccurrences(of: "finalizer_state", with: "t.finalizer_state"))
                                  AND g.status = 'succeeded'
                                  AND (g.lock_owner IS NULL OR julianday(g.lock_expires_at) <= julianday(?))
                            THEN '1' ELSE '0' END
                FROM \(table) t
                JOIN operation_groups g ON g.id = t.operation_group_id
                ORDER BY t.\(timestampColumn) DESC, t.rowid DESC
                """,
                bindings: [.text(ISO8601DateFormatter().string(from: date))]
            )
            rows += selected.compactMap { row in
                let groupOffset = 7 + authorityColumns.count
                guard row.count == groupOffset + 4, let id = row[0], let timestamp = row[1],
                      let lifecycle = row[2], let finalizer = row[3],
                      let generation = row[4], let providerGeneration = row[5],
                      let fence = row[6],
                      row[7..<groupOffset].allSatisfy({ $0 != nil }),
                      let groupStatus = row[groupOffset],
                      let lockOwner = row[groupOffset + 1],
                      let lockExpiry = row[groupOffset + 2] else { return nil }
                return retentionRow(
                    table: table, id: id, timestamp: timestamp,
                    identity: [
                        lifecycle, finalizer, generation, providerGeneration, fence
                    ] + row[7..<groupOffset].compactMap { $0 } + [
                        groupStatus, lockOwner, lockExpiry
                    ],
                    bytes: nil, safe: row[groupOffset + 3] == "1"
                )
            }
        }
        return rows
    }

    private func retentionRow(
        table: String,
        id: String,
        timestamp: String,
        identity: [String],
        bytes: String?,
        safe: Bool
    ) -> StateRetentionRow {
        StateRetentionRow(
            table: table,
            id: id,
            timestamp: timestamp,
            date: parseTimestamp(timestamp),
            identitySHA256: StateMaintenanceFileSupport.token([table, id, timestamp] + identity),
            bytes: UInt64(bytes ?? "") ?? 0,
            safe: safe
        )
    }

    private func deleteDatabaseCandidates(
        _ candidates: [StateRetentionCandidate],
        planSHA256: String
    ) throws -> [StateRetentionClass: Int] {
        var counts: [StateRetentionClass: Int] = [:]
        try store.withValidatedConnection { connection in
            try connection.transaction {
                for candidate in candidates.sorted(by: deletionOrder) {
                    try Task.checkCancellation()
                    guard Self.databaseTableAllowlist.contains(candidate.table) else {
                        throw StateMaintenanceError.unsafeCompaction("candidate table is not in the exact compaction allowlist")
                    }
                    if candidate.table == "operation_groups" {
                        try connection.run(
                            "DELETE FROM operation_group_steps WHERE group_id = ?",
                            bindings: [.text(candidate.id)]
                        )
                    }
                    try connection.run(
                        "DELETE FROM \(candidate.table) WHERE id = ?",
                        bindings: [.text(candidate.id)]
                    )
                    let changed = try connection.query("SELECT changes()").first?.first ?? nil
                    guard changed == "1" else {
                        throw StateMaintenanceError.confirmationMismatch
                    }
                    counts[candidate.retentionClass, default: 0] += 1
                }
                try Task.checkCancellation()
                let timestamp = ISO8601DateFormatter().string(from: Date())
                try connection.run(
                    """
                    INSERT INTO event_ledger (
                        id, timestamp, severity, type, source, project_id, service_name,
                        runtime_adapter, message, payload_json_redacted
                    ) VALUES (?, ?, 'info', 'state.retention.compaction', 'state-maintenance',
                              NULL, NULL, NULL, 'State compaction decision committed.', ?)
                    """,
                    bindings: [
                        .text(UUID().uuidString.lowercased()),
                        .text(timestamp),
                        .text("{\"planSHA256\":\"\(planSHA256)\",\"deletedRecords\":\(candidates.count)}")
                    ]
                )
            }
        }
        return counts
    }

    private func databaseCandidateDisposition(
        _ candidates: [StateRetentionCandidate],
        planSHA256: String
    ) throws -> StateRetentionDatabaseDisposition {
        try store.withValidatedConnection(readOnly: true) { connection in
            var present = 0
            var absent = 0
            for candidate in candidates {
                guard Self.databaseTableAllowlist.contains(candidate.table) else {
                    return .ambiguous
                }
                let rows = try connection.query(
                    "SELECT id FROM \(candidate.table) WHERE id = ?",
                    bindings: [.text(candidate.id)]
                )
                if rows.isEmpty {
                    absent += 1
                } else if rows.count == 1, rows[0].first == candidate.id {
                    present += 1
                } else {
                    return .ambiguous
                }
            }
            if absent == 0, !candidates.isEmpty { return .present }
            guard present == 0 else { return .ambiguous }

            let payload = "{\"planSHA256\":\"\(planSHA256)\",\"deletedRecords\":\(candidates.count)}"
            let audit = try connection.query(
                """
                SELECT COUNT(*) FROM event_ledger
                WHERE type = 'state.retention.compaction'
                  AND source = 'state-maintenance'
                  AND message = 'State compaction decision committed.'
                  AND payload_json_redacted = ?
                """,
                bindings: [.text(payload)]
            ).first?.first ?? nil
            if candidates.isEmpty, audit == "0" { return .present }
            guard audit == "1" else { return .ambiguous }
            return .committed(Dictionary(grouping: candidates, by: \.retentionClass).mapValues(\.count))
        }
    }

    private func verifyTerminalEffects(_ journal: StateRetentionJournal) throws {
        let databaseCandidates = journal.candidates.filter {
            $0.table != StateRetentionCandidate.backupTable
        }
        guard case .committed(let databaseCounts) = try databaseCandidateDisposition(
            databaseCandidates,
            planSHA256: journal.confirmationToken
        ) else {
            throw StateMaintenanceError.recoveryFailed(
                "the terminal compaction database effects are not exactly proven"
            )
        }
        for (retentionClass, count) in databaseCounts {
            guard journal.deletedRecords[retentionClass] == count else {
                throw StateMaintenanceError.recoveryFailed(
                    "the terminal compaction deletion counts do not match durable effects"
                )
            }
        }
        let backupIDs = Set(journal.candidates.filter {
            $0.table == StateRetentionCandidate.backupTable
        }.map(\.id))
        let catalogIDs = Set(try maintenance.backupCatalog().backups.map(\.backupID))
        guard backupIDs.isDisjoint(with: catalogIDs),
              backupIDs.allSatisfy({
                  !StateMaintenanceFileSupport.exists(backupDirectory($0)) &&
                  !StateMaintenanceFileSupport.exists(
                      stagedBackupDirectory($0, planSHA256: journal.confirmationToken)
                  )
              }) else {
            throw StateMaintenanceError.recoveryFailed(
                "the terminal compaction backup effects are not exactly proven"
            )
        }
    }

    private func stageAndDeleteBackups(
        _ backupIDs: [String],
        planSHA256: String,
        journal: inout StateRetentionJournal
    ) throws -> [String] {
        guard !backupIDs.contains(journal.preCompactionBackupID) else {
            throw StateMaintenanceError.unsafeCompaction("the pre-compaction backup cannot be a pruning candidate")
        }
        guard !backupIDs.isEmpty else { return [] }
        try SecureStatePathManager().validatePrivateMaintenanceDirectory(paths.backupDirectory)
        for backupID in backupIDs {
            try Task.checkCancellation()
            try StateMaintenanceFileSupport.validateBackupID(backupID)
            let source = backupDirectory(backupID)
            let staged = stagedBackupDirectory(backupID, planSHA256: planSHA256)
            if !StateMaintenanceFileSupport.exists(source),
               StateMaintenanceFileSupport.exists(staged) {
                guard renamex_np(staged, source, UInt32(RENAME_EXCL)) == 0 else {
                    throw StateMaintenanceError.io(path: staged, message: String(cString: strerror(errno)))
                }
                try StateMaintenanceFileSupport.synchronizeDirectory(paths.backupDirectory)
            }
            let catalog = try maintenance.backupCatalog()
            guard catalog.backups.contains(where: { $0.backupID == backupID && $0.restorable }) else {
                throw StateMaintenanceError.confirmationMismatch
            }
            if StateMaintenanceFileSupport.exists(source) {
                guard !StateMaintenanceFileSupport.exists(staged),
                      renamex_np(source, staged, UInt32(RENAME_EXCL)) == 0 else {
                    throw StateMaintenanceError.io(path: source, message: String(cString: strerror(errno)))
                }
                try StateMaintenanceFileSupport.synchronizeDirectory(paths.backupDirectory)
            }
            journal = journal.replacing(
                phase: .backupsStaged,
                stagedBackupIDs: Array(Set(journal.stagedBackupIDs + [backupID])).sorted()
            )
            try replaceJournal(journal)
            try deleteStagedBackup(staged)
        }
        return backupIDs
    }

    private func deleteStagedBackup(_ directory: String) throws {
        try SecureStatePathManager().validatePrivateMaintenanceDirectory(directory)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        guard entries == ["manifest.json", "state.sqlite"] else {
            throw StateMaintenanceError.io(
                path: directory,
                message: "staged retention backup has an unexpected exact inventory"
            )
        }
        for name in entries {
            try StateMaintenanceFileSupport.unlinkSensitiveFile(
                URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name).path
            )
        }
        guard rmdir(directory) == 0 else {
            throw StateMaintenanceError.io(path: directory, message: String(cString: strerror(errno)))
        }
        try StateMaintenanceFileSupport.synchronizeDirectory(paths.backupDirectory)
    }

    private func publicPlan(_ snapshot: StateRetentionSnapshot) -> StateCompactionPlan {
        StateCompactionPlan(
            evaluatedAt: snapshot.evaluatedAt,
            policySHA256: snapshot.policySHA256,
            databaseSHA256: snapshot.database.sha256,
            databaseBytes: snapshot.database.bytes,
            pressure: snapshot.pressure,
            classes: snapshot.classStatuses,
            candidateRecords: snapshot.candidates.count,
            candidateBytes: snapshot.candidateBytes,
            blockers: snapshot.blockers,
            executable: !snapshot.candidates.isEmpty && snapshot.blockers.isEmpty,
            confirmationToken: snapshot.confirmationToken
        )
    }

    private func validate(_ policy: StateRetentionPolicy) throws {
        guard Set(policy.classes.keys) == Set(StateRetentionClass.allCases),
              (60...31_536_000).contains(policy.recoveryHorizonSeconds),
              policy.maximumDatabaseBytes >= 1_048_576,
              policy.maximumDatabaseBytes <= 1_099_511_627_776,
              policy.targetDatabaseBytes >= 1_048_576,
              policy.targetDatabaseBytes <= policy.maximumDatabaseBytes,
              policy.holds.count <= 64,
              Set(policy.holds.map(\.id)).count == policy.holds.count else {
            throw StateMaintenanceError.unsafeCompaction("the retention policy is incomplete or outside bounded limits")
        }
        for classPolicy in policy.classes.values {
            guard classPolicy.maxAgeSeconds >= policy.recoveryHorizonSeconds,
                  classPolicy.maxAgeSeconds <= 315_360_000,
                  (1...10_000_000).contains(classPolicy.maxRecords),
                  (0...classPolicy.maxRecords).contains(classPolicy.minimumRecords) else {
                throw StateMaintenanceError.unsafeCompaction("a retention class policy is contradictory or outside bounded limits")
            }
        }
        let formatter = ISO8601DateFormatter()
        for hold in policy.holds {
            guard hold.id.range(
                of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$",
                options: .regularExpression
            ) != nil,
            hold.selector.range(
                of: "^(?:\\*|[A-Za-z0-9][A-Za-z0-9._:/@-]{0,255})$",
                options: .regularExpression
            ) != nil,
            !hold.reason.isEmpty,
            hold.reason.count <= 512,
            hold.reason == hold.reason.trimmingCharacters(in: .whitespacesAndNewlines),
            !hold.reason.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw StateMaintenanceError.unsafeCompaction("a retention hold identity, selector, or reason is unsafe")
            }
            if let expiresAt = hold.expiresAt {
                guard formatter.date(from: expiresAt).map(formatter.string(from:)) == expiresAt else {
                    throw StateMaintenanceError.unsafeCompaction("a retention hold expiry is not canonical RFC3339 UTC")
                }
            }
        }
    }

    private func policySHA256(_ policy: StateRetentionPolicy) -> String {
        var components = [
            "hostwright-retention-policy-v1",
            String(policy.recoveryHorizonSeconds),
            String(policy.maximumDatabaseBytes),
            String(policy.targetDatabaseBytes)
        ]
        for retentionClass in StateRetentionClass.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let value = policy.classes[retentionClass]
            components += [
                retentionClass.rawValue,
                String(value?.maxAgeSeconds ?? -1),
                String(value?.maxRecords ?? -1),
                String(value?.minimumRecords ?? -1)
            ]
        }
        for hold in policy.holds.sorted(by: { $0.id < $1.id }) {
            components += [
                hold.id, hold.retentionClass.rawValue, hold.selector,
                hold.reason, hold.expiresAt ?? "none"
            ]
        }
        return StateMaintenanceFileSupport.token(components)
    }

    private func candidateDigest(_ candidates: [StateRetentionCandidate]) -> String {
        StateMaintenanceFileSupport.token(
            ["hostwright-retention-candidates-v1"] + candidates.sorted(by: candidateOrder).flatMap {
                [$0.retentionClass.rawValue, $0.table, $0.id, $0.timestamp, $0.identitySHA256, String($0.bytes)]
            }
        )
    }

    private func candidateOrder(_ left: StateRetentionCandidate, _ right: StateRetentionCandidate) -> Bool {
        if left.retentionClass != right.retentionClass {
            return left.retentionClass.rawValue < right.retentionClass.rawValue
        }
        if left.table != right.table { return left.table < right.table }
        return left.id < right.id
    }

    private func deletionOrder(_ left: StateRetentionCandidate, _ right: StateRetentionCandidate) -> Bool {
        let ranks = [
            "network_attachments": 0,
            "network_port_reservations": 1,
            "network_certificates": 2,
            "network_resources": 3
        ]
        let leftRank = ranks[left.table] ?? 10
        let rightRank = ranks[right.table] ?? 10
        if leftRank != rightRank { return leftRank < rightRank }
        return candidateOrder(left, right)
    }

    private func parseTimestamp(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private func canonicalEvaluationDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    private func evaluationTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: canonicalEvaluationDate(date))
    }

    private func evaluationDate(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value),
              formatter.string(from: date) == value else {
            throw StateMaintenanceError.confirmationMismatch
        }
        return canonicalEvaluationDate(date)
    }

    private func validateConfirmation(_ value: String) throws {
        guard value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw StateMaintenanceError.confirmationMismatch
        }
    }

    private func inject(
        _ checkpoint: StateRetentionInterruptionCheckpoint,
        requested: StateRetentionInterruptionCheckpoint?
    ) throws {
        if checkpoint == requested {
            throw StateRetentionInjectedInterruption(checkpoint: checkpoint)
        }
    }

    private func pendingPlanSHA256() throws -> String? {
        guard StateMaintenanceFileSupport.exists(journalPath) else { return nil }
        return try readJournal().confirmationToken
    }

    private func writeNewJournal(_ journal: StateRetentionJournal) throws {
        guard !StateMaintenanceFileSupport.exists(journalPath) else {
            throw StateMaintenanceError.operationInProgress(journalPath)
        }
        try SecureStatePathManager().writePrivateJSON(journal, to: journalPath)
    }

    private func replaceJournal(_ journal: StateRetentionJournal) throws {
        try SecureStatePathManager().replacePrivateJSON(journal, at: journalPath)
    }

    private func removeJournal() throws {
        try StateMaintenanceFileSupport.unlinkSensitiveFile(journalPath)
    }

    private func readJournal() throws -> StateRetentionJournal {
        let data = try SecureStatePathManager().readPrivateFile(journalPath, maximumBytes: 8 * 1_024 * 1_024)
        let journal = try JSONDecoder().decode(StateRetentionJournal.self, from: data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(journal) + Data("\n".utf8)
        let candidateKeys = journal.candidates.map { "\($0.table)\u{0}\($0.id)" }
        let databaseCounts = Dictionary(
            grouping: journal.candidates.filter { $0.table != StateRetentionCandidate.backupTable },
            by: \.retentionClass
        ).mapValues(\.count)
        let backupIDs = journal.candidates.filter {
            $0.table == StateRetentionCandidate.backupTable
        }.map(\.id)
        let candidateClassesValid = journal.candidates.allSatisfy { candidate in
            let validClasses: Set<StateRetentionClass>
            switch candidate.table {
            case "operation_ledger": validClasses = [.operations]
            case "operation_groups": validClasses = [.operations]
            case "observed_runtime_snapshots", "health_check_results": validClasses = [.observations]
            case "event_ledger": validClasses = [.events, .audits, .traces, .supportEvidence]
            case "network_attachments", "network_port_reservations", "network_certificates", "network_resources":
                validClasses = [.tombstones]
            case StateRetentionCandidate.backupTable: validClasses = [.backups]
            default: return false
            }
            return validClasses.contains(candidate.retentionClass) &&
                candidate.identitySHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
                !candidate.id.isEmpty && candidate.id.utf8.count <= 512 &&
                parseTimestamp(candidate.timestamp) != nil
        }
        let stagedIDsValid = Set(journal.stagedBackupIDs).count == journal.stagedBackupIDs.count &&
            Set(journal.stagedBackupIDs).isSubset(of: Set(backupIDs))
        let countsValid = journal.deletedRecords.allSatisfy { key, value in
            value >= 0 && value <= journal.candidates.filter { $0.retentionClass == key }.count
        }
        guard journal.schemaVersion == 1,
              canonical == data,
              journal.confirmationToken.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              journal.policySHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              journal.sourceDatabaseSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              journal.candidates.count <= Self.maximumCandidatesPerRun,
              Set(candidateKeys).count == candidateKeys.count,
              candidateClassesValid,
              stagedIDsValid,
              countsValid,
              (journal.phase == .prepared
                  ? journal.deletedRecords.isEmpty && journal.stagedBackupIDs.isEmpty
                  : databaseCounts.allSatisfy { journal.deletedRecords[$0.key] == $0.value }),
              !journal.preCompactionBackupID.isEmpty else {
            throw StateMaintenanceError.recoveryFailed("retention journal identity is invalid")
        }
        do {
            try StateMaintenanceFileSupport.validateBackupID(journal.preCompactionBackupID)
            try backupIDs.forEach(StateMaintenanceFileSupport.validateBackupID)
        } catch {
            throw StateMaintenanceError.recoveryFailed("retention journal backup identity is invalid")
        }
        return journal
    }

    private func backupDirectory(_ backupID: String) -> String {
        URL(fileURLWithPath: paths.backupDirectory, isDirectory: true)
            .appendingPathComponent(backupID, isDirectory: true).path
    }

    private func stagedBackupDirectory(_ backupID: String, planSHA256: String) -> String {
        URL(fileURLWithPath: paths.backupDirectory, isDirectory: true)
            .appendingPathComponent(".retention-\(planSHA256.prefix(16))-\(backupID)", isDirectory: true).path
    }
}

private struct StateRetentionSnapshot {
    let evaluatedAt: String
    let policySHA256: String
    let database: StateFileFingerprint
    let pressure: StateRetentionPressure
    let classStatuses: [StateRetentionClassStatus]
    let candidates: [StateRetentionCandidate]
    let candidateBytes: UInt64
    let blockers: [String]
    let confirmationToken: String
}

private struct StateRetentionRow {
    let table: String
    let id: String
    let timestamp: String
    let date: Date?
    let identitySHA256: String
    let bytes: UInt64
    let safe: Bool
}

private struct StateRetentionSelection {
    let candidates: [StateRetentionCandidate]
    let held: Int
    let recoveryCritical: Int
    let truncated: Bool
}

private struct StateRetentionCandidate: Codable, Equatable {
    static let backupTable = "__state_backup__"

    let retentionClass: StateRetentionClass
    let table: String
    let id: String
    let timestamp: String
    let identitySHA256: String
    let bytes: UInt64
}

private enum StateRetentionJournalPhase: String, Codable {
    case prepared
    case databaseCommitted
    case backupsStaged
    case backupsDeleted
    case vacuumComplete
}

private struct StateRetentionJournal: Codable {
    let schemaVersion: Int
    let phase: StateRetentionJournalPhase
    let confirmationToken: String
    let policySHA256: String
    let sourceDatabaseSHA256: String
    let sourceDatabaseBytes: UInt64
    let preCompactionBackupID: String
    let candidates: [StateRetentionCandidate]
    let deletedRecords: [StateRetentionClass: Int]
    let stagedBackupIDs: [String]

    func replacing(
        phase: StateRetentionJournalPhase? = nil,
        deletedRecords: [StateRetentionClass: Int]? = nil,
        stagedBackupIDs: [String]? = nil
    ) -> StateRetentionJournal {
        StateRetentionJournal(
            schemaVersion: schemaVersion,
            phase: phase ?? self.phase,
            confirmationToken: confirmationToken,
            policySHA256: policySHA256,
            sourceDatabaseSHA256: sourceDatabaseSHA256,
            sourceDatabaseBytes: sourceDatabaseBytes,
            preCompactionBackupID: preCompactionBackupID,
            candidates: candidates,
            deletedRecords: deletedRecords ?? self.deletedRecords,
            stagedBackupIDs: stagedBackupIDs ?? self.stagedBackupIDs
        )
    }
}

enum StateRetentionInterruptionCheckpoint: String, CaseIterable, Equatable {
    case prepared
    case databaseTransactionCommitted
    case databaseCommitted
    case backupsStaged
    case backupsDeleted
    case vacuumComplete
}

private enum StateRetentionDatabaseDisposition {
    case present
    case committed([StateRetentionClass: Int])
    case ambiguous
}

struct StateRetentionInjectedInterruption: Error, Equatable {
    let checkpoint: StateRetentionInterruptionCheckpoint
}
