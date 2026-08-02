import Foundation
import XCTest
@testable import HostwrightObservability
@testable import HostwrightRuntime
@testable import HostwrightState

final class StateRetentionTests: XCTestCase {
    func testTraceRowsHaveAnExactIndependentRetentionClass() throws {
        try withStore { store, _ in
            let span = try HostwrightTraceSpanRecord(
                traceID: "11111111-1111-4111-8111-111111111111",
                spanID: "22222222-2222-4222-8222-222222222222",
                parentSpanID: nil,
                processCorrelationID: "33333333-3333-4333-8333-333333333333",
                name: .cliRequest,
                status: .succeeded,
                startedAt: "2026-01-01T00:00:00Z",
                endedAt: "2026-01-01T00:00:01Z",
                durationMilliseconds: 1_000,
                depth: 0,
                attributes: [
                    try HostwrightTraceAttribute(key: .sampling, value: "all"),
                    try HostwrightTraceAttribute(key: .droppedSpans, value: "0")
                ]
            )
            XCTAssertEqual(StateTraceSink(store: store).record(span).status, .persisted)
            let service = try StateRetentionService(store: store)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
            let plan = try service.compactionPlan(policy: policy(), at: now)
            XCTAssertEqual(status(.traces, in: plan).currentRecords, 1)
            XCTAssertEqual(status(.traces, in: plan).candidateRecords, 1)
            XCTAssertEqual(status(.events, in: plan).currentRecords, 0)
            let result = try service.compact(
                policy: policy(),
                confirmationToken: plan.confirmationToken,
                at: now
            )
            XCTAssertEqual(result.deletedRecords[.traces], 1)
            XCTAssertThrowsError(try store.traces.inspect(
                traceID: "11111111-1111-4111-8111-111111111111",
                limit: 1
            ))
        }
    }

    func testPlanIsDeterministicAndPreservesHoldsRecoveryAndUnavailableProducers() throws {
        try withStore { store, _ in
            try appendEvent(id: "delete-event", timestamp: "2026-01-01T00:00:00Z", type: "runtime.changed", to: store)
            try appendEvent(id: "held-event", timestamp: "2026-01-01T00:00:01Z", type: "runtime.changed", to: store)
            try appendEvent(id: "recent-event", timestamp: "2026-08-01T11:59:30Z", type: "runtime.changed", to: store)
            try appendEvent(id: "future-event", timestamp: "2026-08-01T12:01:00Z", type: "runtime.changed", to: store)
            try appendEvent(id: "audit-event", timestamp: "2026-01-01T00:00:00Z", type: "security.audit", to: store)
            try insertOperation(id: "active-operation", status: "planned", store: store)

            let service = try StateRetentionService(store: store)
            var boundedClasses = policy().classes
            boundedClasses[.events] = StateRetentionClassPolicy(
                maxAgeSeconds: 3_600,
                maxRecords: 1,
                minimumRecords: 0
            )
            let policy = StateRetentionPolicy(
                recoveryHorizonSeconds: 60,
                maximumDatabaseBytes: 1_099_511_627_776,
                targetDatabaseBytes: 1_099_511_627_776,
                classes: boundedClasses,
                holds: [
                StateRetentionHold(
                    id: "incident",
                    retentionClass: .events,
                    selector: "held-event",
                    reason: "Preserve exact incident evidence"
                )
                ]
            )
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
            let first = try service.compactionPlan(policy: policy, at: now)
            let second = try service.compactionPlan(policy: policy, at: now)

            XCTAssertEqual(first, second)
            XCTAssertEqual(status(.events, in: first).candidateRecords, 1)
            XCTAssertEqual(status(.events, in: first).heldRecords, 1)
            XCTAssertEqual(status(.events, in: first).recoveryCriticalRecords, 1)
            XCTAssertEqual(status(.audits, in: first).candidateRecords, 1)
            XCTAssertEqual(status(.operations, in: first).candidateRecords, 0)
            XCTAssertEqual(status(.operations, in: first).recoveryCriticalRecords, 1)
            XCTAssertFalse(status(.logs, in: first).producerAvailable)
            XCTAssertTrue(status(.metrics, in: first).producerAvailable)
            XCTAssertEqual(status(.metrics, in: first).currentRecords, 0)
            XCTAssertEqual(
                status(.metrics, in: first).note,
                "read-only projection; authoritative source rows retain under their owning classes"
            )
            XCTAssertTrue(first.executable)
        }
    }

    func testConfirmedCompactionCreatesVerifiedBackupDeletesExactCandidatesAndRetainsAudit() throws {
        try withStore { store, _ in
            try appendEvent(id: "delete-event", timestamp: "2026-01-01T00:00:00Z", type: "runtime.changed", to: store)
            try appendEvent(id: "held-event", timestamp: "2026-01-01T00:00:01Z", type: "runtime.changed", to: store)
            let service = try StateRetentionService(store: store)
            let policy = policy(holds: [
                StateRetentionHold(
                    id: "legal",
                    retentionClass: .events,
                    selector: "held-event",
                    reason: "Legal hold"
                )
            ])
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
            let plan = try service.compactionPlan(policy: policy, at: now)
            let result = try service.compact(
                policy: policy,
                confirmationToken: plan.confirmationToken,
                at: now
            )

            XCTAssertEqual(result.integrityHealth, .healthy)
            XCTAssertEqual(result.deletedRecords[.events], 1)
            XCTAssertFalse(result.resumed)
            let events = try store.events.loadAll()
            XCTAssertFalse(events.contains { $0.id == "delete-event" })
            XCTAssertTrue(events.contains { $0.id == "held-event" })
            XCTAssertTrue(events.contains { $0.type == "state.retention.compaction" })
            XCTAssertTrue(try service.maintenance.backupCatalog().backups.contains {
                $0.backupID == result.preCompactionBackupID && $0.restorable
            })
            XCTAssertFalse(FileManager.default.fileExists(atPath: service.paths.journalPath + ".retention-v1"))
        }
    }

    func testSecurityAndOperatorEvidenceUsesTheAuditRetentionClass() throws {
        try withStore { store, _ in
            let protectedTypes = [
                "image.provenance.lifecycle.authorized",
                "image.sbom.lifecycle.authorized",
                "image.trust.exception.used",
                "image.vulnerability.exception.granted",
                "restart.policy.manual-release",
                "secret.rotate.succeeded",
                "team.approval.recorded",
                "team.profile.selected"
            ]
            for (index, type) in protectedTypes.enumerated() {
                try appendEvent(
                    id: "protected-\(index)",
                    timestamp: "2026-01-01T00:00:00Z",
                    type: type,
                    to: store
                )
            }
            try appendEvent(
                id: "ordinary",
                timestamp: "2026-01-01T00:00:00Z",
                type: "runtime.changed",
                to: store
            )
            var classes = policy().classes
            classes[.audits] = StateRetentionClassPolicy(
                maxAgeSeconds: 315_360_000,
                maxRecords: 10_000,
                minimumRecords: 0
            )
            let retention = StateRetentionPolicy(
                recoveryHorizonSeconds: 60,
                maximumDatabaseBytes: 1_099_511_627_776,
                targetDatabaseBytes: 1_099_511_627_776,
                classes: classes
            )
            let service = try StateRetentionService(store: store)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
            let plan = try service.compactionPlan(policy: retention, at: now)

            XCTAssertEqual(status(.events, in: plan).currentRecords, 1)
            XCTAssertEqual(status(.events, in: plan).candidateRecords, 1)
            XCTAssertEqual(status(.audits, in: plan).currentRecords, protectedTypes.count)
            XCTAssertEqual(status(.audits, in: plan).candidateRecords, 0)
        }
    }

    func testSucceededUnreferencedOperationGroupCompactsWithItsSteps() throws {
        try withStore { store, _ in
            let groupID = "96000000-0000-4000-8000-000000000001"
            let fence = "97000000-0000-4000-8000-000000000001"
            _ = try store.operationGroups.acquire(OperationGroupRecord(
                id: groupID,
                operationID: "retention-success-operation",
                groupKind: "lifecycle",
                projectID: nil,
                serviceName: nil,
                plannedActionType: "apply",
                status: .active,
                groupIdempotencyKey: "retention-success-group",
                planHash: digest("7"),
                checkpoint: "intent-persisted",
                lockOwner: "retention-test",
                lockExpiresAt: "2026-01-01T00:10:00Z",
                rollbackAvailable: true,
                manualRecoveryHintRedacted: "",
                createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z",
                metadataJSONRedacted: "{}",
                fencingToken: fence,
                intentJSONRedacted: "{}"
            ))
            try store.operationGroupSteps.append(
                OperationGroupStepRecord(
                    id: "98000000-0000-4000-8000-000000000001",
                    groupID: groupID,
                    stepKey: "verify",
                    direction: .forward,
                    plannedActionType: "verify",
                    serviceName: nil,
                    resourceIdentifier: nil,
                    stepIdempotencyKey: "retention-success-step",
                    status: .succeeded,
                    startedAt: "2026-01-01T00:00:01Z",
                    updatedAt: "2026-01-01T00:00:02Z",
                    finishedAt: "2026-01-01T00:00:02Z",
                    lastErrorRedacted: nil,
                    manualRecoveryHintRedacted: "",
                    metadataJSONRedacted: "{}"
                ),
                expectedFencingToken: fence,
                expectedLockOwner: "retention-test"
            )
            try store.operationGroups.finish(
                groupID: groupID,
                status: .succeeded,
                checkpoint: "verified",
                manualRecoveryHintRedacted: "",
                updatedAt: "2026-01-01T00:00:03Z",
                metadataJSONRedacted: "{}"
            )

            let service = try StateRetentionService(store: store)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
            let plan = try service.compactionPlan(policy: policy(), at: now)
            XCTAssertEqual(status(.operations, in: plan).candidateRecords, 1)
            let result = try service.compact(
                policy: policy(),
                confirmationToken: plan.confirmationToken,
                at: now
            )
            XCTAssertEqual(result.deletedRecords[.operations], 1)
            XCTAssertFalse(try store.operationGroups.loadAll().contains { $0.id == groupID })
            XCTAssertFalse(try store.operationGroupSteps.loadAll().contains { $0.groupID == groupID })
        }
    }

    @MainActor
    func testCancellationBeforeMutationLeavesNoBackupJournalOrDeletion() async throws {
        try await withStoreAsync { store, _ in
            try appendEvent(
                id: "cancel-target",
                timestamp: "2026-01-01T00:00:00Z",
                type: "runtime.changed",
                to: store
            )
            let service = try StateRetentionService(store: store)
            let policy = policy()
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
            let plan = try service.compactionPlan(policy: policy, at: now)
            let task = Task {
                try service.compact(
                    policy: policy,
                    confirmationToken: plan.confirmationToken,
                    at: now
                )
            }
            task.cancel()

            switch await task.result {
            case .success:
                XCTFail("cancelled compaction unexpectedly succeeded")
            case .failure(let error):
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertTrue(try store.events.loadAll().contains { $0.id == "cancel-target" })
            XCTAssertTrue(try service.maintenance.backupCatalog().backups.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: service.paths.journalPath + ".retention-v1"
            ))
        }
    }

    func testConfirmationRefusesChangedCandidateSetWithoutDeletingRecords() throws {
        try withStore { store, _ in
            try appendEvent(id: "first", timestamp: "2026-01-01T00:00:00Z", type: "runtime.changed", to: store)
            let service = try StateRetentionService(store: store)
            let policy = policy()
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
            let plan = try service.compactionPlan(policy: policy, at: now)
            try appendEvent(id: "second", timestamp: "2026-01-02T00:00:00Z", type: "runtime.changed", to: store)

            XCTAssertThrowsError(
                try service.compact(policy: policy, confirmationToken: plan.confirmationToken, at: now)
            ) { error in
                XCTAssertEqual(error as? StateMaintenanceError, .confirmationMismatch)
            }
            XCTAssertEqual(Set(try store.events.loadAll().map(\.id)), ["first", "second"])
        }
    }

    func testEveryDurableCheckpointResumesExactPlanWithoutDuplicateDeletion() throws {
        for checkpoint in StateRetentionInterruptionCheckpoint.allCases {
            try withStore { store, _ in
                try appendEvent(
                    id: "delete-\(checkpoint.rawValue)",
                    timestamp: "2026-01-01T00:00:00Z",
                    type: "runtime.changed",
                    to: store
                )
                let service = try StateRetentionService(store: store)
                let policy = policy()
                let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
                let plan = try service.compactionPlan(policy: policy, at: now)

                XCTAssertThrowsError(try service.compactForTesting(
                    policy: policy,
                    confirmationToken: plan.confirmationToken,
                    at: now,
                    interruptAfter: checkpoint
                )) { error in
                    XCTAssertEqual(
                        error as? StateRetentionInjectedInterruption,
                        StateRetentionInjectedInterruption(checkpoint: checkpoint)
                    )
                }
                XCTAssertThrowsError(try store.events.loadAll())
                let pending = try service.status(policy: policy, at: now)
                XCTAssertEqual(pending.pendingCompactionPlanSHA256, plan.confirmationToken)

                let resumed = try service.compact(
                    policy: policy,
                    confirmationToken: plan.confirmationToken,
                    at: now
                )
                XCTAssertTrue(resumed.resumed)
                XCTAssertEqual(resumed.deletedRecords[.events], 1)
                XCTAssertFalse(try store.events.loadAll().contains {
                    $0.id == "delete-\(checkpoint.rawValue)"
                })
                XCTAssertEqual(
                    try store.events.loadAll().filter { $0.type == "state.retention.compaction" }.count,
                    1
                )
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: service.paths.journalPath + ".retention-v1"
                ))
            }
        }
    }

    func testPressureUsesOnlyAlreadyEligibleRecordsAndHoldFailsClosed() throws {
        try withStore { store, _ in
            try appendEvent(
                id: "large-old-event",
                timestamp: "2026-01-01T00:00:00Z",
                type: "runtime.changed",
                payload: String(repeating: "x", count: 2 * 1_024 * 1_024),
                to: store
            )
            let service = try StateRetentionService(store: store)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
            let eligiblePolicy = pressurePolicy()
            let eligible = try service.compactionPlan(policy: eligiblePolicy, at: now)
            XCTAssertEqual(eligible.pressure, .eligible)
            XCTAssertTrue(eligible.executable)

            let heldPolicy = pressurePolicy(holds: [
                StateRetentionHold(
                    id: "legal",
                    retentionClass: .events,
                    selector: "*",
                    reason: "Preserve all event evidence"
                )
            ])
            let held = try service.compactionPlan(policy: heldPolicy, at: now)
            XCTAssertEqual(held.pressure, .held)
            XCTAssertFalse(held.executable)
            XCTAssertTrue(held.blockers.contains { $0.contains("cannot prove reduction") })
        }
    }

    func testCandidatePageIsBoundedWithoutLosingDeterminism() throws {
        try withStore { store, _ in
            try insertEvents(count: StateRetentionService.maximumCandidatesPerRun + 5, store: store)
            let service = try StateRetentionService(store: store)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
            let plan = try service.compactionPlan(policy: policy(), at: now)
            XCTAssertEqual(plan.candidateRecords, StateRetentionService.maximumCandidatesPerRun)
            XCTAssertTrue(status(.events, in: plan).note.contains("bounded candidate page"))
            XCTAssertTrue(plan.executable)
        }
    }

    func testVerifiedBackupCandidatesAreStagedExactlyAndPreCompactionBackupIsPreserved() throws {
        try withStore { store, _ in
            let maintenance = try StateMaintenanceService(store: store)
            let first = try maintenance.createBackup()
            let second = try maintenance.createBackup()
            var classes = policy().classes
            classes[.backups] = StateRetentionClassPolicy(
                maxAgeSeconds: 60,
                maxRecords: 1,
                minimumRecords: 0
            )
            let policy = StateRetentionPolicy(
                recoveryHorizonSeconds: 60,
                maximumDatabaseBytes: 1_099_511_627_776,
                targetDatabaseBytes: 1_099_511_627_776,
                classes: classes
            )
            let service = try StateRetentionService(store: store)
            let future = try XCTUnwrap(ISO8601DateFormatter().date(from: "2030-08-01T12:00:00Z"))
            let plan = try service.compactionPlan(policy: policy, at: future)
            XCTAssertEqual(status(.backups, in: plan).candidateRecords, 2)

            let result = try service.compact(
                policy: policy,
                confirmationToken: plan.confirmationToken,
                at: future
            )
            XCTAssertEqual(result.deletedRecords[.backups], 2)
            let remaining = try maintenance.backupCatalog().backups
            XCTAssertFalse(remaining.contains { $0.backupID == first.backupID })
            XCTAssertFalse(remaining.contains { $0.backupID == second.backupID })
            XCTAssertEqual(remaining.map(\.backupID), [result.preCompactionBackupID])
        }
    }

    func testTombstoneRequiresCompletedFinalizersAndExpiredGroupLeaseBeforeExactDeletion() throws {
        try withStore { store, _ in
            try seedProject(store)
            let group = try portOperationGroup(store)
            let reserved = portRecord(
                generation: 1,
                fence: group.fence,
                lifecycle: .reserved,
                finalizer: .active,
                observed: nil,
                groupID: group.id
            )
            _ = try store.networkPorts.save(reserved)
            let active = portRecord(
                generation: 1,
                fence: group.fence,
                lifecycle: .active,
                finalizer: .active,
                observed: digest("b"),
                groupID: group.id
            )
            _ = try store.networkPorts.save(active, replacing: reserved.expectedVersion)
            let releasing = portRecord(
                generation: 2,
                fence: group.fence,
                lifecycle: .releasing,
                finalizer: .releasing,
                observed: digest("b"),
                groupID: group.id
            )
            _ = try store.networkPorts.save(releasing, replacing: active.expectedVersion)
            let released = portRecord(
                generation: 2,
                fence: group.fence,
                lifecycle: .released,
                finalizer: .released,
                observed: digest("c"),
                groupID: group.id
            )
            _ = try store.networkPorts.save(released, replacing: releasing.expectedVersion)

            let service = try StateRetentionService(store: store)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
            let held = try service.compactionPlan(policy: policy(), at: now)
            XCTAssertEqual(status(.tombstones, in: held).candidateRecords, 0)
            XCTAssertEqual(status(.tombstones, in: held).recoveryCriticalRecords, 1)

            try store.operationGroups.finish(
                groupID: group.id,
                status: .succeeded,
                checkpoint: "verified",
                manualRecoveryHintRedacted: "",
                updatedAt: "2026-07-26T12:30:00Z",
                metadataJSONRedacted: "{}"
            )
            let plan = try service.compactionPlan(policy: policy(), at: now)
            XCTAssertEqual(status(.tombstones, in: plan).candidateRecords, 1)
            XCTAssertEqual(status(.operations, in: plan).candidateRecords, 0)
            XCTAssertEqual(status(.operations, in: plan).recoveryCriticalRecords, 1)
            let result = try service.compact(
                policy: policy(),
                confirmationToken: plan.confirmationToken,
                at: now
            )
            XCTAssertEqual(result.deletedRecords[.tombstones], 1)
            XCTAssertTrue(try store.networkPorts.loadProject(
                projectUUID: projectUUID,
                includeReleased: true
            ).isEmpty)
        }
    }

    func testTamperedRetentionJournalFailsClosedAndPreservesEvidence() throws {
        try withStore { store, _ in
            try appendEvent(
                id: "tamper-target",
                timestamp: "2026-01-01T00:00:00Z",
                type: "runtime.changed",
                to: store
            )
            let service = try StateRetentionService(store: store)
            let policy = policy()
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
            let plan = try service.compactionPlan(policy: policy, at: now)
            XCTAssertThrowsError(try service.compactForTesting(
                policy: policy,
                confirmationToken: plan.confirmationToken,
                at: now,
                interruptAfter: .prepared
            ))

            let journalPath = service.paths.journalPath + ".retention-v1"
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: journalPath)))
                    as? [String: Any]
            )
            object["unsafe"] = true
            let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                + Data("\n".utf8)
            try tampered.write(to: URL(fileURLWithPath: journalPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalPath)

            XCTAssertThrowsError(try service.compact(
                policy: policy,
                confirmationToken: plan.confirmationToken,
                at: now
            ))
            XCTAssertTrue(FileManager.default.fileExists(atPath: journalPath))
            XCTAssertThrowsError(try store.events.loadAll())
        }
    }

    func testTamperedTerminalPhaseCannotSkipUnperformedDeletion() throws {
        try withStore { store, _ in
            try appendEvent(
                id: "phase-target",
                timestamp: "2026-01-01T00:00:00Z",
                type: "runtime.changed",
                to: store
            )
            let service = try StateRetentionService(store: store)
            let policy = policy()
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
            let plan = try service.compactionPlan(policy: policy, at: now)
            XCTAssertThrowsError(try service.compactForTesting(
                policy: policy,
                confirmationToken: plan.confirmationToken,
                at: now,
                interruptAfter: .prepared
            ))

            let journalPath = service.paths.journalPath + ".retention-v1"
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: journalPath)))
                    as? [String: Any]
            )
            object["phase"] = "vacuumComplete"
            object["deletedRecords"] = ["events", 1]
            let tampered = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ) + Data("\n".utf8)
            try tampered.write(to: URL(fileURLWithPath: journalPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalPath)

            XCTAssertThrowsError(try service.compact(
                policy: policy,
                confirmationToken: plan.confirmationToken,
                at: now
            )) { error in
                XCTAssertTrue(String(describing: error).contains("terminal compaction database effects"))
            }
            let connection = try SQLiteConnection(path: store.path, createIfNeeded: false, readOnly: true)
            defer { try? connection.close() }
            XCTAssertEqual(
                try connection.query(
                    "SELECT COUNT(*) FROM event_ledger WHERE id = 'phase-target'"
                ).first?.first ?? nil,
                "1"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: journalPath))
        }
    }

    private func policy(holds: [StateRetentionHold] = []) -> StateRetentionPolicy {
        let classPolicy = StateRetentionClassPolicy(
            maxAgeSeconds: 3_600,
            maxRecords: 10_000,
            minimumRecords: 0
        )
        return StateRetentionPolicy(
            recoveryHorizonSeconds: 60,
            maximumDatabaseBytes: 1_099_511_627_776,
            targetDatabaseBytes: 1_099_511_627_776,
            classes: Dictionary(uniqueKeysWithValues: StateRetentionClass.allCases.map { ($0, classPolicy) }),
            holds: holds
        )
    }

    private func pressurePolicy(holds: [StateRetentionHold] = []) -> StateRetentionPolicy {
        let base = policy(holds: holds)
        return StateRetentionPolicy(
            recoveryHorizonSeconds: base.recoveryHorizonSeconds,
            maximumDatabaseBytes: 1_048_576,
            targetDatabaseBytes: 1_048_576,
            classes: base.classes,
            holds: holds
        )
    }

    private func status(
        _ retentionClass: StateRetentionClass,
        in plan: StateCompactionPlan
    ) -> StateRetentionClassStatus {
        plan.classes.first { $0.retentionClass == retentionClass }!
    }

    private func withStore(_ body: (SQLiteStateStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-state-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try body(store, directory)
    }

    @MainActor
    private func withStoreAsync(
        _ body: (SQLiteStateStore, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-state-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try await body(store, directory)
    }

    private func appendEvent(
        id: String,
        timestamp: String,
        type: String,
        payload: String = "{}",
        to store: SQLiteStateStore
    ) throws {
        try store.events.append([EventRecord(
            id: id,
            timestamp: timestamp,
            severity: .info,
            type: type,
            source: "runtime-tests",
            projectID: nil,
            serviceName: nil,
            runtimeAdapter: nil,
            message: "bounded event",
            payloadJSONRedacted: payload
        )])
    }

    private func insertEvents(count: Int, store: SQLiteStateStore) throws {
        let connection = try SQLiteConnection(path: store.path, createIfNeeded: false)
        defer { try? connection.close() }
        try connection.transaction {
            for index in 0..<count {
                try connection.run(
                    """
                    INSERT INTO event_ledger (
                        id, timestamp, severity, type, source, project_id, service_name,
                        runtime_adapter, message, payload_json_redacted
                    ) VALUES (?, '2026-01-01T00:00:00Z', 'info', 'runtime.changed',
                              'runtime-tests', NULL, NULL, NULL, 'bounded event', '{}')
                    """,
                    bindings: [.text(String(format: "event-%04d", index))]
                )
            }
        }
    }

    private func insertOperation(id: String, status: String, store: SQLiteStateStore) throws {
        let connection = try SQLiteConnection(path: store.path, createIfNeeded: false)
        defer { try? connection.close() }
        try connection.run(
            """
            INSERT INTO operation_ledger (
                id, created_at, updated_at, planned_action_type, project_id, service_name,
                status, idempotency_key, plan_hash, payload_json_redacted
            ) VALUES (?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'apply',
                      NULL, NULL, ?, ?, ?, '{}')
            """,
            bindings: [
                .text(id), .text(status), .text("key-\(id)"),
                .text(String(repeating: "a", count: 64))
            ]
        )
    }

    private let projectID = "retention-project"
    private let projectUUID = "91000000-0000-4000-8000-000000000001"
    private let resourceUUID = "92000000-0000-4000-8000-000000000001"

    private func seedProject(_ store: SQLiteStateStore) throws {
        try store.withConnection { connection in
            try connection.run(
                """
                INSERT INTO projects (
                    id, name, manifest_path, manifest_hash, created_at, updated_at,
                    resource_uuid, manifest_version, mutation_provider, provider_generation
                ) VALUES (?, 'retention', NULL, ?, '2026-07-26T12:00:00Z',
                          '2026-07-26T12:00:00Z', ?, 2, ?, 1)
                """,
                bindings: [
                    .text(projectID), .text(digest("a")), .text(projectUUID),
                    .text(RuntimeProviderID.appleContainerCLI.rawValue)
                ]
            )
        }
    }

    private func portOperationGroup(
        _ store: SQLiteStateStore
    ) throws -> (id: String, fence: String) {
        let id = "94000000-0000-4000-8000-000000000001"
        let fence = "95000000-0000-4000-8000-000000000001"
        let group = OperationGroupRecord(
            id: id,
            operationID: "retention-port-operation",
            groupKind: "network-port-reservation",
            projectID: projectID,
            serviceName: "api",
            plannedActionType: "release",
            status: .active,
            groupIdempotencyKey: "retention-port",
            planHash: digest("9"),
            checkpoint: "intent-persisted",
            lockOwner: "retention-test",
            lockExpiresAt: "2027-07-26T12:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-26T12:00:00Z",
            updatedAt: "2026-07-26T12:00:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: fence,
            intentJSONRedacted: "{}"
        )
        _ = try store.operationGroups.acquire(group)
        return (id, fence)
    }

    private func portRecord(
        generation: Int64,
        fence: String,
        lifecycle: NetworkPortReservationLifecycle,
        finalizer: NetworkStateFinalizer,
        observed: String?,
        groupID: String
    ) -> NetworkPortReservationRecord {
        NetworkPortReservationRecord(
            id: "93000000-0000-4000-8000-000000000001",
            projectUUID: projectUUID,
            resourceUUID: resourceUUID,
            serviceName: "api",
            generation: generation,
            providerID: RuntimeProviderID.appleContainerCLI.rawValue,
            providerGeneration: 1,
            fencingToken: fence,
            bindAddress: "127.0.0.1",
            hostPort: 58_421,
            containerPort: 8_080,
            protocolName: .tcp,
            allocationKind: .dynamic,
            desiredSHA256: digest("a"),
            observedSHA256: observed,
            lifecycleState: lifecycle,
            finalizerState: finalizer,
            operationGroupID: groupID,
            createdAt: "2026-07-26T12:00:00Z",
            updatedAt: "2026-07-26T12:02:00Z"
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}
