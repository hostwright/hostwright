import Foundation
import XCTest
import HostwrightControlPlane

@testable import HostwrightCore
@testable import HostwrightScheduler
@testable import HostwrightState

final class SchedulerAdmissionPreemptionStateTests: XCTestCase {
    private let projectUUID = "00000000-0000-0000-0000-000000000905"
    private let decisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000906")!

    func testAuthorityRecordsRoundTripWithStableDigests() throws {
        let fairness = try SchedulerFairnessState(
            subjectID: "subject-a",
            projectID: "project-a",
            usage: try ResourceVector(["cpu": 2]),
            guarantee: try ResourceVector(["cpu": 1]),
            reclaimableBorrowedUsage: try ResourceVector(["cpu": 1]),
            quota: try ResourceVector(["cpu": 4]),
            pendingDemand: try ResourceVector(["cpu": 1]),
            starvationAgeUnits: 2,
            weight: 1
        )
        let fairnessRecord = try SchedulerFairnessAccountingRecord(
            state: fairness,
            generation: 1,
            updatedAt: timestamp(0)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                SchedulerFairnessAccountingRecord.self,
                from: JSONEncoder().encode(fairnessRecord)
            ),
            fairnessRecord
        )

        let budgetRecord = try SchedulerDisruptionBudgetRecord(
            budget: SchedulerDisruptionBudget(
                budgetID: "budget-a",
                projectID: "project-a",
                remainingVictimCount: 2,
                remainingDisruptionCostBasisPoints: 100
            ),
            generation: 1,
            updatedAt: timestamp(0)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                SchedulerDisruptionBudgetRecord.self,
                from: JSONEncoder().encode(budgetRecord)
            ),
            budgetRecord
        )

        let pressureRecord = try SchedulerHostPressureRecord(
            nodeID: nodeID,
            posture: SchedulerHostPosture(
                pressure: .elevated,
                energy: .constrained
            ),
            generation: 1,
            observedAt: timestamp(0),
            evidenceDigest: digest("e"),
            policyState: try pressurePolicyState(
                reasonCodes: [.lowPowerMode],
                nextPosture: .deweighted
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                SchedulerHostPressureRecord.self,
                from: JSONEncoder().encode(pressureRecord)
            ),
            pressureRecord
        )

        let intent = try makeIntent()
        XCTAssertEqual(
            try JSONDecoder().decode(
                SchedulerPreemptionIntentRecord.self,
                from: JSONEncoder().encode(intent)
            ),
            intent
        )
    }

    func testAuthorityRecordCodableRejectsTamperedDigestsAndMissingIdentity() throws {
        let budgetRecord = try SchedulerDisruptionBudgetRecord(
            budget: SchedulerDisruptionBudget(
                budgetID: "budget-a",
                projectID: "project-a",
                remainingVictimCount: 1,
                remainingDisruptionCostBasisPoints: 10
            ),
            generation: 1,
            updatedAt: timestamp(0)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(budgetRecord))
                as? [String: Any]
        )
        object["budgetDigest"] = digest("f")
        XCTAssertThrowsError(try JSONDecoder().decode(
            SchedulerDisruptionBudgetRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))

        let victim = try makeVictim()
        let proposal = try makeProposal(victim: victim)
        let intent = try SchedulerPreemptionIntentRecord(
            decisionID: decisionID,
            intentID: SchedulerAdmissionStableIdentifier.preemptionIntentID(
                decisionID: decisionID,
                targetWorkloadID: proposal.targetWorkloadID
            ),
            proposal: proposal,
            createdAt: timestamp(0),
            updatedAt: timestamp(0)
        )
        let data = try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(intent))
                    as? [String: Any]
            ).filter { $0.key != "recordDigest" }
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(SchedulerPreemptionIntentRecord.self, from: data)
        )
    }

    func testPreemptionIntentRejectsCrossProjectVictimsAndHasBoundedTransitions() throws {
        let victim = try makeVictim(projectID: "project-b")
        let proposal = try makeProposal(victim: victim)
        XCTAssertThrowsError(
            try SchedulerPreemptionIntentRecord(
                decisionID: decisionID,
                intentID: SchedulerAdmissionStableIdentifier.preemptionIntentID(
                    decisionID: decisionID,
                    targetWorkloadID: proposal.targetWorkloadID
                ),
                proposal: proposal,
                createdAt: timestamp(0),
                updatedAt: timestamp(0)
            )
        )

        let valid = try makeIntent()
        XCTAssertTrue(valid.status.canTransition(to: .fencePending))
        XCTAssertFalse(valid.status.canTransition(to: .applied))
        XCTAssertTrue(SchedulerPreemptionIntentStatus.fenced.canTransition(to: .applied))
        XCTAssertFalse(SchedulerPreemptionIntentStatus.recovered.canTransition(to: .applied))
    }

    func testRepositoryAuthorityApisAreAvailableAfterTheV22AuthorityAppend() throws {
        try withTemporaryStore { store in
            let authorityTables = try store.withConnection(
                createIfNeeded: false,
                readOnly: true
            ) { connection in
                Set(
                    try connection.query(
                        """
                        SELECT name FROM sqlite_master
                        WHERE type = 'table' AND name IN (
                            'scheduler_fairness_accounting',
                            'scheduler_disruption_budgets',
                            'scheduler_preemption_intents',
                            'scheduler_host_pressure'
                        )
                        """
                    ).compactMap { $0.first ?? nil }
                )
            }
            guard authorityTables.count == 4 else {
                throw XCTSkip(
                    "Pending coordinated v22 authority-table migration append."
                )
            }
            try insertProject(in: store)

            let fairness = try SchedulerFairnessState(
                subjectID: "subject-a",
                projectID: "project-a",
                usage: try ResourceVector(["cpu": 1])
            )
            let firstFairness = try store.schedulerAdmissions.recordFairnessAccounting(
                state: fairness,
                generation: 1,
                updatedAt: timestamp(0)
            )
            XCTAssertEqual(
                try store.schedulerAdmissions.fairnessAccounting(
                    subjectID: "subject-a",
                    projectID: "project-a"
                ),
                firstFairness
            )
            XCTAssertThrowsError(
                try store.schedulerAdmissions.recordFairnessAccounting(
                    state: fairness,
                    generation: 1,
                    updatedAt: timestamp(1)
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .staleInput(field: "fairness-generation")
                )
            }

            let budget = try SchedulerDisruptionBudget(
                budgetID: "budget-a",
                projectID: projectUUID,
                remainingVictimCount: 1,
                remainingDisruptionCostBasisPoints: 20
            )
            _ = try store.schedulerAdmissions.recordDisruptionBudget(
                budget: budget,
                generation: 1,
                updatedAt: timestamp(0)
            )
            XCTAssertEqual(
                try store.schedulerAdmissions.disruptionBudgets(projectID: projectUUID)
                    .map(\.budgetID),
                ["budget-a"]
            )

            let nodeSnapshot = try SchedulerNodeCapacitySnapshot(
                nodeID: nodeID,
                capacity: try ResourceVector(["cpu": 2]),
                generation: 1,
                observedAt: timestamp(0)
            )
            _ = try store.schedulerAdmissions.recordNodeCapacity(snapshot: nodeSnapshot)
            let pressure = try SchedulerHostPressureRecord(
                nodeID: nodeID,
                posture: SchedulerHostPosture(pressure: .nominal, energy: .balanced),
                generation: 1,
                observedAt: timestamp(0),
                evidenceDigest: digest("a"),
                policyState: try pressurePolicyState(
                    reasonCodes: [.allowed],
                    nextPosture: .allowed
                )
            )
            XCTAssertEqual(
                try store.schedulerAdmissions.recordHostPressure(record: pressure),
                pressure
            )

            let proposal = try makeProposal(
                victim: try makeVictim(projectID: projectUUID),
                projectID: projectUUID
            )
            let decisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000904")!
            let decisionWorkload = try SchedulerWorkloadDecision(
                workloadID: targetWorkloadID,
                outcome: .preemptionProposed,
                chosenNodeID: nil,
                scoreComponents: nil,
                feasibleAlternatives: [],
                filterFailures: [],
                preemption: proposal,
                explanation: try SchedulerDecisionExplanation(
                    code: .preemptionProposed,
                    summary: "canonical preemption intent"
                )
            )
            let decision = try SchedulerDecision(
                decisionID: decisionID,
                inputDigest: digest("b"),
                orderedWorkloadIDs: [targetWorkloadID],
                workloadDecisions: [decisionWorkload]
            )
            let binding = try SchedulerDecisionWorkloadBinding(
                workloadID: targetWorkloadID,
                nodeID: nodeID,
                resources: try ResourceVector(["cpu": 1]),
                capacityDigest: nodeSnapshot.capacityDigest,
                capacityGeneration: nodeSnapshot.generation,
                ownerSubjectID: "subject-a",
                projectUUID: projectUUID
            )
            _ = try store.schedulerAdmissions.recordDecisionArtifact(
                decision: decision,
                workloadBindings: [binding],
                projectUUID: projectUUID,
                configDigest: digest("c"),
                profileDigest: digest("d"),
                lifecyclePlanDigest: digest("e"),
                createdAt: timestamp(0),
                updatedAt: timestamp(0)
            )
            let authority = try SchedulerAdmissionCurrentAuthority(
                nodeCapacityDigest: nodeSnapshot.capacityDigest,
                nodeCapacityGeneration: nodeSnapshot.generation,
                configDigest: digest("c"),
                profileDigest: digest("d"),
                lifecyclePlanDigest: digest("e"),
                expectedNodeEpoch: 1,
                expectedPressureGeneration: 1,
                expectedPressureEvidenceDigest: digest("a"),
                expectedPressurePosture: .nominal,
                leaseCreatedAt: timestamp(0),
                leaseExpiresAt: timestamp(4)
            )
            let applied = try store.schedulerAdmissions.applyDecision(
                decisionID: decisionID,
                projectUUID: projectUUID,
                workloadID: targetWorkloadID,
                expectedInputDigest: decision.inputDigest,
                currentAuthority: authority
            )
            let storedIntent = try XCTUnwrap(applied.preemptionIntent)
            XCTAssertEqual(
                try store.schedulerAdmissions.preemptionIntents(projectID: "project-a"),
                []
            )
            XCTAssertEqual(
                try store.schedulerAdmissions.preemptionIntents(projectID: projectUUID),
                [storedIntent]
            )
            let transitioned = try store.schedulerAdmissions.transitionPreemptionIntent(
                intentID: storedIntent.intentID,
                expectedRecordDigest: storedIntent.recordDigest,
                to: .fencePending,
                updatedAt: timestamp(1)
            )
            XCTAssertEqual(transitioned.status, .fencePending)
        }
    }

    func testDecisionArtifactIsIndependentFromReservationsAndReplayKeepsFirstTimestamps() throws {
        try withRepository { repository, store in
            let fixture = try makePlacedFixture()
            _ = try store.schedulerAdmissions.recordNodeCapacity(
                snapshot: fixture.nodeSnapshot
            )
            let first = try repository.recordDecisionArtifact(
                decision: fixture.artifact.decision,
                workloadBindings: fixture.artifact.workloadBindings,
                projectUUID: fixture.artifact.projectUUID,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                createdAt: fixture.artifact.createdAt,
                updatedAt: fixture.artifact.updatedAt
            )
            XCTAssertEqual(try repository.decisionArtifact(id: first.decisionID), first)
            XCTAssertNil(try repository.decision(id: first.decisionID))

            let replay = try repository.recordDecisionArtifact(
                decision: fixture.artifact.decision,
                workloadBindings: fixture.artifact.workloadBindings,
                projectUUID: fixture.artifact.projectUUID,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                createdAt: timestamp(2),
                updatedAt: timestamp(3)
            )
            XCTAssertEqual(replay, first)
            XCTAssertEqual(replay.createdAt, timestamp(0))
            XCTAssertEqual(replay.updatedAt, timestamp(1))
            let artifactJSON = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(first)
            ) as? [String: Any]
            let bindingJSON = try XCTUnwrap(
                (artifactJSON?["workloadBindings"] as? [[String: Any]])?.first
            )
            XCTAssertNil(bindingJSON["createdAt"])
            XCTAssertNil(bindingJSON["expiresAt"])

            let columns = try store.withConnection(createIfNeeded: false, readOnly: true) {
                connection in
                Set(
                    try connection.query("PRAGMA table_info(scheduler_decisions)")
                        .compactMap { $0.count > 1 ? $0[1] : nil }
                )
            }
            XCTAssertFalse(columns.contains("reservation_id"))
            XCTAssertTrue(columns.contains("workload_bindings_json"))
            let reservationCount = try store.withConnection(
                createIfNeeded: false,
                readOnly: true
            ) { connection in
                try connection.query("SELECT COUNT(*) FROM scheduler_reservations")
                    .first?.first
            }
            XCTAssertEqual(reservationCount, "0")
        }
    }

    func testApplyReloadsArtifactAndCreatesOnlyPendingReservation() throws {
        try withRepository { repository, store in
            let fixture = try makePlacedFixture()
            _ = try repository.recordDecisionArtifact(
                decision: fixture.artifact.decision,
                workloadBindings: fixture.artifact.workloadBindings,
                projectUUID: fixture.artifact.projectUUID,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                createdAt: fixture.artifact.createdAt,
                updatedAt: fixture.artifact.updatedAt
            )
            _ = try repository.recordNodeCapacity(snapshot: fixture.nodeSnapshot)

            let applied = try repository.applyDecision(
                decisionID: fixture.artifact.decisionID,
                projectUUID: fixture.artifact.projectUUID,
                workloadID: fixture.binding.workloadID,
                expectedInputDigest: fixture.artifact.inputDigest,
                currentAuthority: fixture.currentAuthority
            )
            let reservation = try XCTUnwrap(applied.reservation)
            XCTAssertEqual(reservation.status, .pending)
            XCTAssertNil(applied.preemptionIntent)
            XCTAssertNil(reservation.fenceEvidence)
            XCTAssertEqual(
                try repository.applyDecision(
                    decisionID: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID,
                    workloadID: fixture.binding.workloadID,
                    expectedInputDigest: fixture.artifact.inputDigest,
                    currentAuthority: try SchedulerAdmissionCurrentAuthority(
                        nodeCapacityDigest: fixture.nodeSnapshot.capacityDigest,
                        nodeCapacityGeneration: fixture.nodeSnapshot.generation,
                        configDigest: fixture.artifact.configDigest,
                        profileDigest: fixture.artifact.profileDigest,
                        lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                        expectedNodeEpoch: 1,
                        expectedPressureGeneration: 1,
                        expectedPressureEvidenceDigest: digest("a"),
                        expectedPressurePosture: .nominal,
                        leaseCreatedAt: timestamp(3),
                        leaseExpiresAt: timestamp(5)
                    )
                ),
                applied
            )
            let snapshot = try XCTUnwrap(
                repository.decisionState(
                    id: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID
                )
            )
            XCTAssertEqual(snapshot.artifact, fixture.artifact)
            XCTAssertEqual(snapshot.reservations, [reservation])
            XCTAssertThrowsError(
                try repository.applyDecision(
                    decisionID: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID,
                    workloadID: fixture.binding.workloadID,
                    expectedInputDigest: digest("e"),
                    currentAuthority: fixture.currentAuthority
                )
            )
            _ = store
        }
    }

    func testApplyPressureGenerationCASFailsClosedAndAllowsOnlyNominalOrElevated() throws {
        try withRepository { repository, store in
            let fixture = try makePlacedFixture()
            _ = try repository.recordDecisionArtifact(
                decision: fixture.artifact.decision,
                workloadBindings: fixture.artifact.workloadBindings,
                projectUUID: fixture.artifact.projectUUID,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                createdAt: fixture.artifact.createdAt,
                updatedAt: fixture.artifact.updatedAt
            )
            _ = try repository.recordNodeCapacity(snapshot: fixture.nodeSnapshot)

            let critical = try SchedulerHostPressureRecord(
                nodeID: fixture.binding.nodeID,
                posture: SchedulerHostPosture(
                    pressure: .critical,
                    energy: .balanced
                ),
                generation: 2,
                observedAt: timestamp(1),
                evidenceDigest: digest("b"),
                policyState: try pressurePolicyState(
                    reasonCodes: [.memoryCritical],
                    nextPosture: .blocked
                )
            )
            _ = try repository.recordHostPressure(record: critical)

            XCTAssertThrowsError(
                try repository.applyDecision(
                    decisionID: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID,
                    workloadID: fixture.binding.workloadID,
                    expectedInputDigest: fixture.artifact.inputDigest,
                    currentAuthority: fixture.currentAuthority
                )
            ) { error in
                XCTAssertEqual(
                    (error as? SchedulerAdmissionError)?.stableKey,
                    "stale-input:pressure-snapshot"
                )
            }

            let criticalAuthority = try SchedulerAdmissionCurrentAuthority(
                nodeCapacityDigest: fixture.nodeSnapshot.capacityDigest,
                nodeCapacityGeneration: fixture.nodeSnapshot.generation,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                expectedNodeEpoch: 1,
                expectedPressureGeneration: critical.generation,
                expectedPressureEvidenceDigest: critical.evidenceDigest,
                expectedPressurePosture: .critical,
                leaseCreatedAt: timestamp(2),
                leaseExpiresAt: timestamp(4)
            )
            XCTAssertThrowsError(
                try repository.applyDecision(
                    decisionID: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID,
                    workloadID: fixture.binding.workloadID,
                    expectedInputDigest: fixture.artifact.inputDigest,
                    currentAuthority: criticalAuthority
                )
            ) { error in
                XCTAssertEqual(
                    (error as? SchedulerAdmissionError)?.stableKey,
                    "invalid-binding:pressure-not-admissible"
                )
            }

            let elevated = try SchedulerHostPressureRecord(
                nodeID: fixture.binding.nodeID,
                posture: SchedulerHostPosture(
                    pressure: .elevated,
                    energy: .balanced
                ),
                generation: 3,
                observedAt: timestamp(2),
                evidenceDigest: digest("e"),
                policyState: try pressurePolicyState(
                    reasonCodes: [.memoryWarning],
                    nextPosture: .deweighted
                )
            )
            _ = try repository.recordHostPressure(record: elevated)
            let elevatedAuthority = try SchedulerAdmissionCurrentAuthority(
                nodeCapacityDigest: fixture.nodeSnapshot.capacityDigest,
                nodeCapacityGeneration: fixture.nodeSnapshot.generation,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                expectedNodeEpoch: 1,
                expectedPressureGeneration: elevated.generation,
                expectedPressureEvidenceDigest: elevated.evidenceDigest,
                expectedPressurePosture: .elevated,
                leaseCreatedAt: timestamp(3),
                leaseExpiresAt: timestamp(5)
            )
            XCTAssertNotNil(
                try repository.applyDecision(
                    decisionID: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID,
                    workloadID: fixture.binding.workloadID,
                    expectedInputDigest: fixture.artifact.inputDigest,
                    currentAuthority: elevatedAuthority
                ).reservation
            )
            _ = store
        }
    }

    func testPreemptionApplyPersistsProjectScopedIntentWithoutClientFenceProof() throws {
        try withRepository { repository, _ in
            let placed = try makePlacedFixture()
            let victim = try SchedulerVictimAllocation(
                workloadID: victimWorkloadID,
                nodeID: placed.binding.nodeID,
                allocation: try ResourceVector(["cpu": 1]),
                subjectID: "owner",
                projectID: projectUUID,
                priority: 1,
                disruptionCostBasisPoints: 10,
                budgetID: "budget-apply"
            )
            _ = try repository.recordNodeCapacity(snapshot: placed.nodeSnapshot)
            _ = try repository.recordDisruptionBudget(
                budget: try SchedulerDisruptionBudget(
                    budgetID: "budget-apply",
                    projectID: projectUUID,
                    remainingVictimCount: 1,
                    remainingDisruptionCostBasisPoints: 10
                ),
                generation: 1,
                updatedAt: timestamp(0)
            )
            let proposal = try SchedulerPreemptionProposal(
                intentDigest: placed.artifact.inputDigest,
                targetWorkloadID: placed.binding.workloadID,
                projectID: projectUUID,
                nodeID: placed.binding.nodeID,
                victims: [victim],
                disruptionCostBasisPoints: 10,
                explanation: try SchedulerPreemptionExplanation(
                    summary: "project-scoped victim intent",
                    victimCount: 1,
                    disruptionCostBasisPoints: 10,
                    budgetIDs: ["budget-apply"]
                )
            )
            let workloadDecision = try SchedulerWorkloadDecision(
                workloadID: placed.binding.workloadID,
                outcome: .preemptionProposed,
                chosenNodeID: nil,
                scoreComponents: nil,
                feasibleAlternatives: [],
                filterFailures: [],
                preemption: proposal,
                explanation: try SchedulerDecisionExplanation(
                    code: .preemptionProposed,
                    summary: "preemption intent"
                )
            )
            let decision = try SchedulerDecision(
                decisionID: placed.artifact.decisionID,
                inputDigest: placed.artifact.inputDigest,
                orderedWorkloadIDs: [placed.binding.workloadID],
                workloadDecisions: [workloadDecision]
            )
            let artifact = try SchedulerDecisionArtifactRecord(
                decision: decision,
                workloadBindings: [placed.binding],
                projectUUID: projectUUID,
                configDigest: placed.artifact.configDigest,
                profileDigest: placed.artifact.profileDigest,
                lifecyclePlanDigest: placed.artifact.lifecyclePlanDigest,
                createdAt: timestamp(0),
                updatedAt: timestamp(1)
            )
            _ = try repository.recordDecisionArtifact(
                decision: artifact.decision,
                workloadBindings: artifact.workloadBindings,
                projectUUID: artifact.projectUUID,
                configDigest: artifact.configDigest,
                profileDigest: artifact.profileDigest,
                lifecyclePlanDigest: artifact.lifecyclePlanDigest,
                createdAt: artifact.createdAt,
                updatedAt: artifact.updatedAt
            )
            let result = try repository.applyDecision(
                decisionID: artifact.decisionID,
                projectUUID: projectUUID,
                workloadID: placed.binding.workloadID,
                expectedInputDigest: artifact.inputDigest,
                currentAuthority: placed.currentAuthority
            )
            XCTAssertNil(result.reservation)
            XCTAssertEqual(result.preemptionIntent?.status, .proposed)
            XCTAssertEqual(result.preemptionIntent?.proposal, proposal)
            let storedIntent = try XCTUnwrap(result.preemptionIntent)
            XCTAssertEqual(
                storedIntent.intentID,
                SchedulerAdmissionStableIdentifier.preemptionIntentID(
                    decisionID: artifact.decisionID,
                    targetWorkloadID: placed.binding.workloadID
                )
            )
            XCTAssertEqual(
                try repository.preemptionIntent(
                    decisionID: artifact.decisionID,
                    targetWorkloadID: placed.binding.workloadID,
                    projectUUID: projectUUID
                ),
                storedIntent
            )
            XCTAssertEqual(
                try repository.applyDecision(
                    decisionID: artifact.decisionID,
                    projectUUID: projectUUID,
                    workloadID: placed.binding.workloadID,
                    expectedInputDigest: artifact.inputDigest,
                    currentAuthority: placed.currentAuthority
                ).preemptionIntent,
                storedIntent
            )
            XCTAssertEqual(
                try XCTUnwrap(
                    repository.disruptionBudget(
                        budgetID: "budget-apply",
                        projectID: projectUUID
                    )
                ).budget.remainingVictimCount,
                1
            )
            XCTAssertEqual(
                try XCTUnwrap(
                    repository.decisionState(
                        id: artifact.decisionID,
                        projectUUID: projectUUID
                    )
                ).reservations,
                []
            )
        }
    }

    func testPreemptionCompletionFencesReleasesVictimAndReplaysTargetLease() throws {
        try withRepository { repository, _ in
            let victimFixture = try makePlacedFixture(
                workloadID: victimWorkloadID,
                capacity: try ResourceVector(["cpu": 1])
            )
            let targetFixture = try makePlacedFixture(
                workloadID: targetWorkloadID,
                capacity: try ResourceVector(["cpu": 1])
            )
            _ = try repository.recordNodeCapacity(snapshot: victimFixture.nodeSnapshot)

            _ = try repository.recordDecisionArtifact(
                decision: victimFixture.artifact.decision,
                workloadBindings: victimFixture.artifact.workloadBindings,
                projectUUID: victimFixture.artifact.projectUUID,
                configDigest: victimFixture.artifact.configDigest,
                profileDigest: victimFixture.artifact.profileDigest,
                lifecyclePlanDigest: victimFixture.artifact.lifecyclePlanDigest,
                createdAt: victimFixture.artifact.createdAt,
                updatedAt: victimFixture.artifact.updatedAt
            )
            let victimPending = try XCTUnwrap(
                try repository.applyDecision(
                    decisionID: victimFixture.artifact.decisionID,
                    projectUUID: projectUUID,
                    workloadID: victimFixture.binding.workloadID,
                    expectedInputDigest: victimFixture.artifact.inputDigest,
                    currentAuthority: victimFixture.currentAuthority
                ).reservation
            )
            _ = try repository.commit(
                reservationID: victimPending.reservationID,
                expectedToken: victimPending.fencingToken,
                updatedAt: timestamp(3)
            )

            _ = try repository.recordDisruptionBudget(
                budget: try SchedulerDisruptionBudget(
                    budgetID: "budget-complete",
                    projectID: projectUUID,
                    remainingVictimCount: 1,
                    remainingDisruptionCostBasisPoints: 10
                ),
                generation: 1,
                updatedAt: timestamp(0)
            )
            let victim = try SchedulerVictimAllocation(
                workloadID: victimPending.workloadID,
                nodeID: victimPending.nodeID,
                allocation: victimPending.resources,
                subjectID: victimPending.ownerSubjectID,
                projectID: projectUUID,
                priority: 1,
                disruptionCostBasisPoints: 10,
                budgetID: "budget-complete"
            )
            let proposal = try SchedulerPreemptionProposal(
                intentDigest: targetFixture.artifact.inputDigest,
                targetWorkloadID: targetFixture.binding.workloadID,
                projectID: projectUUID,
                nodeID: targetFixture.binding.nodeID,
                victims: [victim],
                disruptionCostBasisPoints: 10,
                explanation: try SchedulerPreemptionExplanation(
                    summary: "one durable victim transition",
                    victimCount: 1,
                    disruptionCostBasisPoints: 10,
                    budgetIDs: ["budget-complete"]
                )
            )
            let targetWorkloadDecision = try SchedulerWorkloadDecision(
                workloadID: targetFixture.binding.workloadID,
                outcome: .preemptionProposed,
                chosenNodeID: nil,
                scoreComponents: nil,
                feasibleAlternatives: [],
                filterFailures: [],
                preemption: proposal,
                explanation: try SchedulerDecisionExplanation(
                    code: .preemptionProposed,
                    summary: "durable victim transition"
                )
            )
            let targetDecision = try SchedulerDecision(
                decisionID: targetFixture.artifact.decisionID,
                inputDigest: targetFixture.artifact.inputDigest,
                orderedWorkloadIDs: [targetFixture.binding.workloadID],
                workloadDecisions: [targetWorkloadDecision]
            )
            let targetArtifact = try SchedulerDecisionArtifactRecord(
                decision: targetDecision,
                workloadBindings: targetFixture.artifact.workloadBindings,
                projectUUID: projectUUID,
                configDigest: targetFixture.artifact.configDigest,
                profileDigest: targetFixture.artifact.profileDigest,
                lifecyclePlanDigest: targetFixture.artifact.lifecyclePlanDigest,
                createdAt: timestamp(0),
                updatedAt: timestamp(1)
            )
            _ = try repository.recordDecisionArtifact(
                decision: targetArtifact.decision,
                workloadBindings: targetArtifact.workloadBindings,
                projectUUID: targetArtifact.projectUUID,
                configDigest: targetArtifact.configDigest,
                profileDigest: targetArtifact.profileDigest,
                lifecyclePlanDigest: targetArtifact.lifecyclePlanDigest,
                createdAt: targetArtifact.createdAt,
                updatedAt: targetArtifact.updatedAt
            )
            let proposed = try repository.applyDecision(
                decisionID: targetArtifact.decisionID,
                projectUUID: projectUUID,
                workloadID: targetFixture.binding.workloadID,
                expectedInputDigest: targetArtifact.inputDigest,
                currentAuthority: targetFixture.currentAuthority
            )
            XCTAssertNil(proposed.reservation)
            XCTAssertEqual(proposed.preemptionIntent?.status, .proposed)

            _ = try repository.recoverNode(
                evidence: SchedulerNodeRecoveryEvidence(
                    nodeID: victimPending.nodeID,
                    expectedNodeEpoch: 1,
                    newNodeEpoch: 2,
                    evidenceDigest: digest("c"),
                    verifiedAt: timestamp(4)
                )
            )
            let fenceEvidence = try SchedulerFenceEvidence(
                token: try SchedulerFencingToken(
                    nodeEpoch: 2,
                    reservationSequence: victimPending.fencingToken.reservationSequence
                ),
                reservationID: victimPending.reservationID,
                workloadID: victimPending.workloadID,
                evidenceDigest: digest("d"),
                verifiedAt: timestamp(4)
            )
            let refreshedAuthority = try SchedulerAdmissionCurrentAuthority(
                nodeCapacityDigest: targetFixture.nodeSnapshot.capacityDigest,
                nodeCapacityGeneration: targetFixture.nodeSnapshot.generation,
                configDigest: targetArtifact.configDigest,
                profileDigest: targetArtifact.profileDigest,
                lifecyclePlanDigest: targetArtifact.lifecyclePlanDigest,
                expectedNodeEpoch: 2,
                expectedPressureGeneration: 1,
                expectedPressureEvidenceDigest: digest("a"),
                expectedPressurePosture: .nominal,
                leaseCreatedAt: timestamp(5),
                leaseExpiresAt: timestamp(7)
            )
            let completed = try repository.completePreemptionDecision(
                decisionID: targetArtifact.decisionID,
                projectUUID: projectUUID,
                workloadID: targetFixture.binding.workloadID,
                expectedInputDigest: targetArtifact.inputDigest,
                currentAuthority: refreshedAuthority,
                fenceEvidence: [fenceEvidence],
                transitionAt: timestamp(6)
            )
            let targetPending = try XCTUnwrap(completed.reservation)
            XCTAssertEqual(targetPending.status, .pending)
            XCTAssertEqual(completed.preemptionIntent?.status, .fenced)
            let releasedVictim = try XCTUnwrap(
                repository.reservation(id: victimPending.reservationID)
            )
            XCTAssertEqual(releasedVictim.status, .released)
            XCTAssertEqual(releasedVictim.updatedAt, timestamp(4))
            XCTAssertEqual(releasedVictim.fenceEvidence?.token, fenceEvidence.token)
            XCTAssertEqual(
                releasedVictim.releaseEvidence,
                .authoritativeFence(
                    token: fenceEvidence.token,
                    reservationID: victimPending.reservationID,
                    workloadID: victimPending.workloadID,
                    evidenceDigest: fenceEvidence.evidenceDigest,
                    verifiedAt: fenceEvidence.verifiedAt
                )
            )
            let consumedBudget = try XCTUnwrap(
                repository.disruptionBudget(
                    budgetID: "budget-complete",
                    projectID: projectUUID
                )
            )
            XCTAssertEqual(consumedBudget.generation, 2)
            XCTAssertEqual(consumedBudget.budget.remainingVictimCount, 0)
            XCTAssertEqual(
                consumedBudget.budget.remainingDisruptionCostBasisPoints,
                0
            )

            let committed = try repository.commit(
                reservationID: targetPending.reservationID,
                expectedToken: targetPending.fencingToken,
                updatedAt: timestamp(7)
            )
            XCTAssertEqual(committed.status, .committed)
            let appliedIntent = try XCTUnwrap(completed.preemptionIntent)
            _ = try repository.transitionPreemptionIntent(
                intentID: appliedIntent.intentID,
                expectedRecordDigest: appliedIntent.recordDigest,
                to: .applied,
                updatedAt: timestamp(7)
            )
            let replay = try repository.completePreemptionDecision(
                decisionID: targetArtifact.decisionID,
                projectUUID: projectUUID,
                workloadID: targetFixture.binding.workloadID,
                expectedInputDigest: targetArtifact.inputDigest,
                currentAuthority: refreshedAuthority,
                fenceEvidence: [fenceEvidence],
                transitionAt: timestamp(7)
            )
            XCTAssertEqual(replay, try SchedulerAdmissionApplyResult(
                decisionID: targetArtifact.decisionID,
                inputDigest: targetArtifact.inputDigest,
                reservation: committed,
                preemptionIntent: try XCTUnwrap(
                    repository.preemptionIntent(
                        decisionID: targetArtifact.decisionID,
                        targetWorkloadID: targetFixture.binding.workloadID,
                        projectUUID: projectUUID
                    )
                )
            ))
            XCTAssertEqual(
                try XCTUnwrap(
                    repository.disruptionBudget(
                        budgetID: "budget-complete",
                        projectID: projectUUID
                    )
                ).generation,
                2
            )
        }
    }

    func testSelectivePreemptionKeepsSiblingReservationValidAcrossRollbackAndReopen() throws {
        try withRepository { repository, store in
            let victimFixture = try makePlacedFixture(
                workloadID: victimWorkloadID,
                nodeID: nodeID,
                capacity: try ResourceVector(["cpu": 2])
            )
            let siblingFixture = try makePlacedFixture(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000904")!,
                nodeID: nodeID,
                capacity: try ResourceVector(["cpu": 2])
            )
            let targetFixture = try makePlacedFixture(
                workloadID: targetWorkloadID,
                nodeID: nodeID,
                capacity: try ResourceVector(["cpu": 2])
            )
            _ = try repository.recordNodeCapacity(snapshot: victimFixture.nodeSnapshot)

            func admitPending(
                _ fixture: PlacedFixture
            ) throws -> SchedulerReservationRecord {
                _ = try repository.recordDecisionArtifact(
                    decision: fixture.artifact.decision,
                    workloadBindings: fixture.artifact.workloadBindings,
                    projectUUID: fixture.artifact.projectUUID,
                    configDigest: fixture.artifact.configDigest,
                    profileDigest: fixture.artifact.profileDigest,
                    lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                    createdAt: fixture.artifact.createdAt,
                    updatedAt: fixture.artifact.updatedAt
                )
                let pending = try XCTUnwrap(
                    try repository.applyDecision(
                        decisionID: fixture.artifact.decisionID,
                        projectUUID: projectUUID,
                        workloadID: fixture.binding.workloadID,
                        expectedInputDigest: fixture.artifact.inputDigest,
                        currentAuthority: fixture.currentAuthority
                    ).reservation
                )
                return pending
            }

            func admitCommitted(
                _ fixture: PlacedFixture
            ) throws -> SchedulerReservationRecord {
                let pending = try admitPending(fixture)
                return try repository.commit(
                    reservationID: pending.reservationID,
                    expectedToken: pending.fencingToken,
                    updatedAt: timestamp(3)
                )
            }

            let victimPending = try admitCommitted(victimFixture)
            let sibling = try admitPending(siblingFixture)

            _ = try repository.recordDisruptionBudget(
                budget: try SchedulerDisruptionBudget(
                    budgetID: "budget-sibling",
                    projectID: projectUUID,
                    remainingVictimCount: 1,
                    remainingDisruptionCostBasisPoints: 10
                ),
                generation: 1,
                updatedAt: timestamp(0)
            )
            let victim = try SchedulerVictimAllocation(
                workloadID: victimPending.workloadID,
                nodeID: victimPending.nodeID,
                allocation: victimPending.resources,
                subjectID: victimPending.ownerSubjectID,
                projectID: projectUUID,
                priority: 1,
                disruptionCostBasisPoints: 10,
                budgetID: "budget-sibling"
            )
            let proposal = try SchedulerPreemptionProposal(
                intentDigest: targetFixture.artifact.inputDigest,
                targetWorkloadID: targetFixture.binding.workloadID,
                projectID: projectUUID,
                nodeID: targetFixture.binding.nodeID,
                victims: [victim],
                disruptionCostBasisPoints: 10,
                explanation: try SchedulerPreemptionExplanation(
                    summary: "same-node selective victim removal",
                    victimCount: 1,
                    disruptionCostBasisPoints: 10,
                    budgetIDs: ["budget-sibling"]
                )
            )
            let targetDecision = try SchedulerDecision(
                decisionID: targetFixture.artifact.decisionID,
                inputDigest: targetFixture.artifact.inputDigest,
                orderedWorkloadIDs: [targetFixture.binding.workloadID],
                workloadDecisions: [try SchedulerWorkloadDecision(
                    workloadID: targetFixture.binding.workloadID,
                    outcome: .preemptionProposed,
                    chosenNodeID: nil,
                    scoreComponents: nil,
                    feasibleAlternatives: [],
                    filterFailures: [],
                    preemption: proposal,
                    explanation: try SchedulerDecisionExplanation(
                        code: .preemptionProposed,
                        summary: "same-node selective victim removal"
                    )
                )]
            )
            let targetArtifact = try SchedulerDecisionArtifactRecord(
                decision: targetDecision,
                workloadBindings: targetFixture.artifact.workloadBindings,
                projectUUID: projectUUID,
                configDigest: targetFixture.artifact.configDigest,
                profileDigest: targetFixture.artifact.profileDigest,
                lifecyclePlanDigest: targetFixture.artifact.lifecyclePlanDigest,
                createdAt: timestamp(0),
                updatedAt: timestamp(1)
            )
            _ = try repository.recordDecisionArtifact(
                decision: targetArtifact.decision,
                workloadBindings: targetArtifact.workloadBindings,
                projectUUID: targetArtifact.projectUUID,
                configDigest: targetArtifact.configDigest,
                profileDigest: targetArtifact.profileDigest,
                lifecyclePlanDigest: targetArtifact.lifecyclePlanDigest,
                createdAt: targetArtifact.createdAt,
                updatedAt: targetArtifact.updatedAt
            )
            let proposed = try repository.applyDecision(
                decisionID: targetArtifact.decisionID,
                projectUUID: projectUUID,
                workloadID: targetFixture.binding.workloadID,
                expectedInputDigest: targetArtifact.inputDigest,
                currentAuthority: targetFixture.currentAuthority
            )
            let proposedIntent = try XCTUnwrap(proposed.preemptionIntent)

            let invalidEvidence = try SchedulerFenceEvidence(
                token: victimPending.fencingToken,
                reservationID: victimPending.reservationID,
                workloadID: victimPending.workloadID,
                evidenceDigest: digest("d"),
                verifiedAt: timestamp(2)
            )
            XCTAssertThrowsError(
                try repository.completePreemptionDecision(
                    decisionID: targetArtifact.decisionID,
                    projectUUID: projectUUID,
                    workloadID: targetFixture.binding.workloadID,
                    expectedInputDigest: targetArtifact.inputDigest,
                    currentAuthority: targetFixture.currentAuthority,
                    fenceEvidence: [invalidEvidence],
                    transitionAt: timestamp(4)
                )
            )
            XCTAssertEqual(
                try repository.preemptionIntent(intentID: proposedIntent.intentID)?.status,
                .proposed
            )
            XCTAssertEqual(
                try repository.reservation(id: victimPending.reservationID)?.status,
                .committed
            )
            XCTAssertEqual(try repository.fencingState(nodeID: nodeID).nodeEpoch, 1)

            let fenceEvidence = try SchedulerFenceEvidence(
                token: victimPending.fencingToken,
                reservationID: victimPending.reservationID,
                workloadID: victimPending.workloadID,
                evidenceDigest: digest("e"),
                verifiedAt: timestamp(4)
            )
            let completed = try repository.completePreemptionDecision(
                decisionID: targetArtifact.decisionID,
                projectUUID: projectUUID,
                workloadID: targetFixture.binding.workloadID,
                expectedInputDigest: targetArtifact.inputDigest,
                currentAuthority: targetFixture.currentAuthority,
                fenceEvidence: [fenceEvidence],
                transitionAt: timestamp(4)
            )
            let targetPending = try XCTUnwrap(completed.reservation)
            XCTAssertEqual(try repository.fencingState(nodeID: nodeID).nodeEpoch, 1)
            let releasedVictim = try XCTUnwrap(
                repository.reservation(id: victimPending.reservationID)
            )
            XCTAssertEqual(releasedVictim.status, .released)
            XCTAssertNil(releasedVictim.fenceEvidence)
            XCTAssertEqual(
                releasedVictim.releaseEvidence,
                .verifiedRuntimeAbsence(
                    evidenceDigest: fenceEvidence.evidenceDigest,
                    verifiedAt: fenceEvidence.verifiedAt
                )
            )

            let committedSibling = try repository.commit(
                reservationID: sibling.reservationID,
                expectedToken: sibling.fencingToken,
                updatedAt: timestamp(5)
            )
            XCTAssertEqual(committedSibling.status, .committed)
            let releasedSibling = try repository.release(
                reservationID: committedSibling.reservationID,
                expectedToken: sibling.fencingToken,
                evidence: .verifiedRuntimeAbsence(
                    evidenceDigest: digest("f"),
                    verifiedAt: timestamp(6)
                )
            )
            XCTAssertEqual(releasedSibling.status, .released)

            let reopened = SQLiteStateStore(path: store.path).schedulerAdmissions
            XCTAssertEqual(
                try reopened.fencingState(nodeID: nodeID).nodeEpoch,
                1
            )
            XCTAssertEqual(
                try reopened.reservation(id: sibling.reservationID)?.status,
                .released
            )
            let replayed = try reopened.completePreemptionDecision(
                decisionID: targetArtifact.decisionID,
                projectUUID: projectUUID,
                workloadID: targetFixture.binding.workloadID,
                expectedInputDigest: targetArtifact.inputDigest,
                currentAuthority: targetFixture.currentAuthority,
                fenceEvidence: [fenceEvidence],
                transitionAt: timestamp(8)
            )
            XCTAssertEqual(replayed.decisionID, targetArtifact.decisionID)
            XCTAssertEqual(
                replayed.preemptionIntent?.intentID,
                proposedIntent.intentID
            )
            XCTAssertEqual(replayed.preemptionIntent?.status, .fenced)
            XCTAssertEqual(
                try reopened.disruptionBudget(
                    budgetID: "budget-sibling",
                    projectID: projectUUID
                )?.budget.remainingVictimCount,
                0
            )
            let committedTarget = try reopened.commit(
                reservationID: targetPending.reservationID,
                expectedToken: targetPending.fencingToken,
                updatedAt: timestamp(9)
            )
            XCTAssertEqual(committedTarget.status, .committed)
            XCTAssertEqual(
                try reopened.activeCapacity(nodeID: nodeID),
                try ResourceVector(["cpu": 1])
            )
        }
    }

    func testPreemptionApplyUsesIndependentTargetScopedIntentIDs() throws {
        try withRepository { repository, _ in
            let first = try makePlacedFixture(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000921")!
            )
            let second = try makePlacedFixture(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000922")!
            )
            _ = try repository.recordNodeCapacity(snapshot: first.nodeSnapshot)
            _ = try repository.recordDisruptionBudget(
                budget: try SchedulerDisruptionBudget(
                    budgetID: "budget-multiple",
                    projectID: projectUUID,
                    remainingVictimCount: 2,
                    remainingDisruptionCostBasisPoints: 20
                ),
                generation: 1,
                updatedAt: timestamp(0)
            )

            let firstVictim = try SchedulerVictimAllocation(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000923")!,
                nodeID: first.binding.nodeID,
                allocation: try ResourceVector(["cpu": 1]),
                subjectID: "owner",
                projectID: projectUUID,
                priority: 1,
                disruptionCostBasisPoints: 10,
                budgetID: "budget-multiple"
            )
            let secondVictim = try SchedulerVictimAllocation(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000924")!,
                nodeID: second.binding.nodeID,
                allocation: try ResourceVector(["cpu": 1]),
                subjectID: "owner",
                projectID: projectUUID,
                priority: 1,
                disruptionCostBasisPoints: 10,
                budgetID: "budget-multiple"
            )
            let firstProposal = try SchedulerPreemptionProposal(
                intentDigest: first.artifact.inputDigest,
                targetWorkloadID: first.binding.workloadID,
                projectID: projectUUID,
                nodeID: first.binding.nodeID,
                victims: [firstVictim],
                disruptionCostBasisPoints: 10,
                explanation: try SchedulerPreemptionExplanation(
                    summary: "first target",
                    victimCount: 1,
                    disruptionCostBasisPoints: 10,
                    budgetIDs: ["budget-multiple"]
                )
            )
            let secondProposal = try SchedulerPreemptionProposal(
                intentDigest: first.artifact.inputDigest,
                targetWorkloadID: second.binding.workloadID,
                projectID: projectUUID,
                nodeID: second.binding.nodeID,
                victims: [secondVictim],
                disruptionCostBasisPoints: 10,
                explanation: try SchedulerPreemptionExplanation(
                    summary: "second target",
                    victimCount: 1,
                    disruptionCostBasisPoints: 10,
                    budgetIDs: ["budget-multiple"]
                )
            )
            let firstDecision = try SchedulerWorkloadDecision(
                workloadID: first.binding.workloadID,
                outcome: .preemptionProposed,
                chosenNodeID: nil,
                scoreComponents: nil,
                feasibleAlternatives: [],
                filterFailures: [],
                preemption: firstProposal,
                explanation: try SchedulerDecisionExplanation(
                    code: .preemptionProposed,
                    summary: "first target intent"
                )
            )
            let secondDecision = try SchedulerWorkloadDecision(
                workloadID: second.binding.workloadID,
                outcome: .preemptionProposed,
                chosenNodeID: nil,
                scoreComponents: nil,
                feasibleAlternatives: [],
                filterFailures: [],
                preemption: secondProposal,
                explanation: try SchedulerDecisionExplanation(
                    code: .preemptionProposed,
                    summary: "second target intent"
                )
            )
            let decision = try SchedulerDecision(
                decisionID: first.artifact.decisionID,
                inputDigest: first.artifact.inputDigest,
                orderedWorkloadIDs: [
                    first.binding.workloadID,
                    second.binding.workloadID,
                ],
                workloadDecisions: [firstDecision, secondDecision]
            )
            let artifact = try SchedulerDecisionArtifactRecord(
                decision: decision,
                workloadBindings: [first.binding, second.binding],
                projectUUID: projectUUID,
                configDigest: first.artifact.configDigest,
                profileDigest: first.artifact.profileDigest,
                lifecyclePlanDigest: first.artifact.lifecyclePlanDigest,
                createdAt: timestamp(0),
                updatedAt: timestamp(1)
            )
            _ = try repository.recordDecisionArtifact(
                decision: artifact.decision,
                workloadBindings: artifact.workloadBindings,
                projectUUID: artifact.projectUUID,
                configDigest: artifact.configDigest,
                profileDigest: artifact.profileDigest,
                lifecyclePlanDigest: artifact.lifecyclePlanDigest,
                createdAt: artifact.createdAt,
                updatedAt: artifact.updatedAt
            )

            let firstResult = try repository.applyDecision(
                decisionID: artifact.decisionID,
                projectUUID: projectUUID,
                workloadID: first.binding.workloadID,
                expectedInputDigest: artifact.inputDigest,
                currentAuthority: first.currentAuthority
            )
            let secondResult = try repository.applyDecision(
                decisionID: artifact.decisionID,
                projectUUID: projectUUID,
                workloadID: second.binding.workloadID,
                expectedInputDigest: artifact.inputDigest,
                currentAuthority: second.currentAuthority
            )
            let firstIntent = try XCTUnwrap(firstResult.preemptionIntent)
            let secondIntent = try XCTUnwrap(secondResult.preemptionIntent)
            XCTAssertNotEqual(firstIntent.intentID, secondIntent.intentID)
            XCTAssertEqual(
                firstIntent.intentID,
                SchedulerAdmissionStableIdentifier.preemptionIntentID(
                    decisionID: artifact.decisionID,
                    targetWorkloadID: first.binding.workloadID
                )
            )
            XCTAssertEqual(
                secondIntent.intentID,
                SchedulerAdmissionStableIdentifier.preemptionIntentID(
                    decisionID: artifact.decisionID,
                    targetWorkloadID: second.binding.workloadID
                )
            )
            XCTAssertEqual(
                try repository.preemptionIntent(
                    decisionID: artifact.decisionID,
                    targetWorkloadID: first.binding.workloadID,
                    projectUUID: projectUUID
                ),
                firstIntent
            )
            XCTAssertEqual(
                try repository.preemptionIntent(
                    decisionID: artifact.decisionID,
                    targetWorkloadID: second.binding.workloadID,
                    projectUUID: projectUUID
                ),
                secondIntent
            )
            XCTAssertEqual(
                try repository.applyDecision(
                    decisionID: artifact.decisionID,
                    projectUUID: projectUUID,
                    workloadID: first.binding.workloadID,
                    expectedInputDigest: artifact.inputDigest,
                    currentAuthority: first.currentAuthority
                ).preemptionIntent,
                firstIntent
            )
        }
    }

    func testProjectResolverAndProjectScopedArtifactLookupAreExplicit() throws {
        try withRepository { repository, _ in
            XCTAssertEqual(
                try repository.projectResourceUUID(forProjectID: "project-a"),
                projectUUID
            )
            XCTAssertEqual(
                try repository.projectAuthority(forProjectID: "project-a")?.resourceUUID,
                projectUUID
            )
            XCTAssertEqual(
                try repository.projectAuthority(forResourceUUID: projectUUID)?.projectID,
                "project-a"
            )
            XCTAssertNil(try repository.projectResourceUUID(forProjectID: "missing-project"))
            let fixture = try makePlacedFixture()
            _ = try repository.recordDecisionArtifact(
                decision: fixture.artifact.decision,
                workloadBindings: fixture.artifact.workloadBindings,
                projectUUID: fixture.artifact.projectUUID,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                createdAt: fixture.artifact.createdAt,
                updatedAt: fixture.artifact.updatedAt
            )
            XCTAssertThrowsError(
                try repository.decisionArtifact(
                    id: fixture.artifact.decisionID,
                    projectUUID: "00000000-0000-0000-0000-000000000906"
                )
            )
        }
    }

    func testFenceReleaseRoundTripUsesReservationLineageAndExactEvidenceTimes() throws {
        try withRepository { repository, _ in
            let fixture = try makePlacedFixture()
            _ = try repository.recordNodeCapacity(snapshot: fixture.nodeSnapshot)
            _ = try repository.recordDecisionArtifact(
                decision: fixture.artifact.decision,
                workloadBindings: fixture.artifact.workloadBindings,
                projectUUID: fixture.artifact.projectUUID,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                createdAt: fixture.artifact.createdAt,
                updatedAt: fixture.artifact.updatedAt
            )
            let pending = try XCTUnwrap(
                try repository.applyDecision(
                    decisionID: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID,
                    workloadID: fixture.binding.workloadID,
                    expectedInputDigest: fixture.artifact.inputDigest,
                    currentAuthority: fixture.currentAuthority
                ).reservation
            )
            _ = try repository.recoverNode(
                evidence: SchedulerNodeRecoveryEvidence(
                    nodeID: pending.nodeID,
                    expectedNodeEpoch: 1,
                    newNodeEpoch: 2,
                    evidenceDigest: digest("c"),
                    verifiedAt: timestamp(2)
                )
            )
            let fenceEvidence = try SchedulerFenceEvidence(
                token: SchedulerFencingToken(
                    nodeEpoch: 2,
                    reservationSequence: pending.fencingToken.reservationSequence
                ),
                reservationID: pending.reservationID,
                workloadID: pending.workloadID,
                evidenceDigest: digest("f"),
                verifiedAt: timestamp(2)
            )
            let fenced = try repository.fence(
                reservationID: pending.reservationID,
                evidence: fenceEvidence
            )
            XCTAssertEqual(fenced.status, .fenced)
            XCTAssertEqual(fenced.updatedAt, fenceEvidence.verifiedAt)
            let reopenedFenced = try XCTUnwrap(
                repository.reservation(id: pending.reservationID)
            )
            XCTAssertEqual(reopenedFenced, fenced)

            let released = try repository.release(
                reservationID: pending.reservationID,
                expectedToken: pending.fencingToken,
                evidence: .authoritativeFence(
                    token: fenceEvidence.token,
                    reservationID: pending.reservationID,
                    workloadID: pending.workloadID,
                    evidenceDigest: digest("d"),
                    verifiedAt: timestamp(3)
                )
            )
            XCTAssertEqual(released.status, .released)
            XCTAssertEqual(released.updatedAt, timestamp(3))
            XCTAssertLessThanOrEqual(
                ISO8601DateFormatter().date(from: fenceEvidence.verifiedAt)!,
                ISO8601DateFormatter().date(from: released.updatedAt)!
            )
            XCTAssertEqual(
                try JSONDecoder().decode(
                    SchedulerReservationRecord.self,
                    from: JSONEncoder().encode(released)
                ),
                released
            )

            let reopenedFixture = try makePlacedFixture(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000913")!,
                nodeID: pending.nodeID
            )
            _ = try repository.recordDecisionArtifact(
                decision: reopenedFixture.artifact.decision,
                workloadBindings: reopenedFixture.artifact.workloadBindings,
                projectUUID: reopenedFixture.artifact.projectUUID,
                configDigest: reopenedFixture.artifact.configDigest,
                profileDigest: reopenedFixture.artifact.profileDigest,
                lifecyclePlanDigest: reopenedFixture.artifact.lifecyclePlanDigest,
                createdAt: reopenedFixture.artifact.createdAt,
                updatedAt: reopenedFixture.artifact.updatedAt
            )
            let currentEpochAuthority = try SchedulerAdmissionCurrentAuthority(
                nodeCapacityDigest: reopenedFixture.nodeSnapshot.capacityDigest,
                nodeCapacityGeneration: reopenedFixture.nodeSnapshot.generation,
                configDigest: reopenedFixture.artifact.configDigest,
                profileDigest: reopenedFixture.artifact.profileDigest,
                lifecyclePlanDigest: reopenedFixture.artifact.lifecyclePlanDigest,
                expectedNodeEpoch: 2,
                expectedPressureGeneration: 1,
                expectedPressureEvidenceDigest: digest("a"),
                expectedPressurePosture: .nominal,
                leaseCreatedAt: timestamp(5),
                leaseExpiresAt: timestamp(6)
            )
            let reopened = try XCTUnwrap(
                try repository.applyDecision(
                    decisionID: reopenedFixture.artifact.decisionID,
                    projectUUID: projectUUID,
                    workloadID: reopenedFixture.binding.workloadID,
                    expectedInputDigest: reopenedFixture.artifact.inputDigest,
                    currentAuthority: currentEpochAuthority
                ).reservation
            )
            let verifiedAbsence = try repository.release(
                reservationID: reopened.reservationID,
                expectedToken: reopened.fencingToken,
                evidence: .verifiedRuntimeAbsence(
                    evidenceDigest: digest("d"),
                    verifiedAt: timestamp(6)
                )
            )
            XCTAssertEqual(verifiedAbsence.status, .released)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    SchedulerReservationRecord.self,
                    from: JSONEncoder().encode(verifiedAbsence)
                ),
                verifiedAbsence
            )
        }
    }

    func testFencedIntentAggregatesBudgetUsageAndReplayDoesNotDoubleConsume() throws {
        try withRepository { repository, store in
            let first = try makePlacedFixture(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000911")!,
                nodeID: nodeID
            )
            let second = try makePlacedFixture(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000912")!,
                nodeID: nodeID
            )
            _ = try repository.recordNodeCapacity(snapshot: first.nodeSnapshot)
            for fixture in [first, second] {
                _ = try repository.recordDecisionArtifact(
                    decision: fixture.artifact.decision,
                    workloadBindings: fixture.artifact.workloadBindings,
                    projectUUID: fixture.artifact.projectUUID,
                    configDigest: fixture.artifact.configDigest,
                    profileDigest: fixture.artifact.profileDigest,
                    lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                    createdAt: fixture.artifact.createdAt,
                    updatedAt: fixture.artifact.updatedAt
                )
            }
            let budget = try SchedulerDisruptionBudget(
                budgetID: "budget-fenced",
                projectID: projectUUID,
                remainingVictimCount: 2,
                remainingDisruptionCostBasisPoints: 20
            )
            _ = try repository.recordDisruptionBudget(
                budget: budget,
                generation: 1,
                updatedAt: timestamp(0)
            )
            let firstPending = try XCTUnwrap(
                try repository.applyDecision(
                    decisionID: first.artifact.decisionID,
                    projectUUID: projectUUID,
                    workloadID: first.binding.workloadID,
                    expectedInputDigest: first.artifact.inputDigest,
                    currentAuthority: first.currentAuthority
                ).reservation
            )
            let secondPending = try XCTUnwrap(
                try repository.applyDecision(
                    decisionID: second.artifact.decisionID,
                    projectUUID: projectUUID,
                    workloadID: second.binding.workloadID,
                    expectedInputDigest: second.artifact.inputDigest,
                    currentAuthority: second.currentAuthority
                ).reservation
            )
            _ = try repository.recoverNode(
                evidence: SchedulerNodeRecoveryEvidence(
                    nodeID: nodeID,
                    expectedNodeEpoch: 1,
                    newNodeEpoch: 2,
                    evidenceDigest: digest("b"),
                    verifiedAt: timestamp(2)
                )
            )
            let firstFence = try SchedulerFenceEvidence(
                token: try SchedulerFencingToken(
                    nodeEpoch: 2,
                    reservationSequence: firstPending.fencingToken.reservationSequence
                ),
                reservationID: firstPending.reservationID,
                workloadID: firstPending.workloadID,
                evidenceDigest: digest("a"),
                verifiedAt: timestamp(2)
            )
            let secondFence = try SchedulerFenceEvidence(
                token: try SchedulerFencingToken(
                    nodeEpoch: 2,
                    reservationSequence: secondPending.fencingToken.reservationSequence
                ),
                reservationID: secondPending.reservationID,
                workloadID: secondPending.workloadID,
                evidenceDigest: digest("b"),
                verifiedAt: timestamp(2)
            )
            _ = try repository.fence(
                reservationID: firstPending.reservationID,
                evidence: firstFence
            )
            _ = try repository.fence(
                reservationID: secondPending.reservationID,
                evidence: secondFence
            )
            let firstVictim = try SchedulerVictimAllocation(
                workloadID: firstPending.workloadID,
                nodeID: nodeID,
                allocation: firstPending.resources,
                subjectID: "owner",
                projectID: projectUUID,
                priority: 1,
                disruptionCostBasisPoints: 10,
                budgetID: "budget-fenced"
            )
            let secondVictim = try SchedulerVictimAllocation(
                workloadID: secondPending.workloadID,
                nodeID: nodeID,
                allocation: secondPending.resources,
                subjectID: "owner",
                projectID: projectUUID,
                priority: 1,
                disruptionCostBasisPoints: 10,
                budgetID: "budget-fenced"
            )
            let proposal = try SchedulerPreemptionProposal(
                intentDigest: digest("f"),
                targetWorkloadID: targetWorkloadID,
                projectID: projectUUID,
                nodeID: nodeID,
                victims: [firstVictim, secondVictim],
                disruptionCostBasisPoints: 20,
                explanation: try SchedulerPreemptionExplanation(
                    summary: "two fenced victims",
                    victimCount: 2,
                    disruptionCostBasisPoints: 20,
                    budgetIDs: ["budget-fenced"]
                )
            )
            let targetDecisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000915")!
            let targetDecisionWorkload = try SchedulerWorkloadDecision(
                workloadID: targetWorkloadID,
                outcome: .preemptionProposed,
                chosenNodeID: nil,
                scoreComponents: nil,
                feasibleAlternatives: [],
                filterFailures: [],
                preemption: proposal,
                explanation: try SchedulerDecisionExplanation(
                    code: .preemptionProposed,
                    summary: "two-victim preemption"
                )
            )
            let targetDecision = try SchedulerDecision(
                decisionID: targetDecisionID,
                inputDigest: digest("e"),
                orderedWorkloadIDs: [targetWorkloadID],
                workloadDecisions: [targetDecisionWorkload]
            )
            let targetBinding = try SchedulerDecisionWorkloadBinding(
                workloadID: targetWorkloadID,
                nodeID: nodeID,
                resources: try ResourceVector(["cpu": 2]),
                capacityDigest: first.nodeSnapshot.capacityDigest,
                capacityGeneration: first.nodeSnapshot.generation,
                ownerSubjectID: "owner",
                projectUUID: projectUUID
            )
            _ = try repository.recordDecisionArtifact(
                decision: targetDecision,
                workloadBindings: [targetBinding],
                projectUUID: projectUUID,
                configDigest: digest("c"),
                profileDigest: digest("a"),
                lifecyclePlanDigest: digest("d"),
                createdAt: timestamp(0),
                updatedAt: timestamp(1)
            )
            let targetAuthority = try SchedulerAdmissionCurrentAuthority(
                nodeCapacityDigest: first.nodeSnapshot.capacityDigest,
                nodeCapacityGeneration: first.nodeSnapshot.generation,
                configDigest: digest("c"),
                profileDigest: digest("a"),
                lifecyclePlanDigest: digest("d"),
                expectedNodeEpoch: 2,
                expectedPressureGeneration: 1,
                expectedPressureEvidenceDigest: digest("a"),
                expectedPressurePosture: .nominal,
                leaseCreatedAt: timestamp(3),
                leaseExpiresAt: timestamp(4)
            )
            let applied = try repository.applyDecision(
                decisionID: targetDecisionID,
                projectUUID: projectUUID,
                workloadID: targetWorkloadID,
                expectedInputDigest: targetDecision.inputDigest,
                currentAuthority: targetAuthority
            )
            let proposedIntent = try XCTUnwrap(applied.preemptionIntent)
            let completed = try repository.completePreemptionDecision(
                decisionID: targetDecisionID,
                projectUUID: projectUUID,
                workloadID: targetWorkloadID,
                expectedInputDigest: targetDecision.inputDigest,
                currentAuthority: targetAuthority,
                fenceEvidence: [firstFence, secondFence],
                transitionAt: timestamp(3)
            )
            let targetPending = try XCTUnwrap(completed.reservation)
            XCTAssertEqual(completed.preemptionIntent?.status, .fenced)
            XCTAssertEqual(
                completed.preemptionIntent?.intentID,
                proposedIntent.intentID
            )
            let recovery = try XCTUnwrap(
                repository.recoverablePreemptionIntents().first
            )
            XCTAssertEqual(recovery.intent, try XCTUnwrap(completed.preemptionIntent))
            XCTAssertEqual(recovery.artifact.decisionID, targetDecisionID)
            XCTAssertEqual(recovery.targetBinding, targetBinding)
            XCTAssertEqual(
                recovery.victimReservations.map(\.workloadID),
                [firstPending.workloadID, secondPending.workloadID].sorted {
                    SchedulerOrdering.uuidKey($0) < SchedulerOrdering.uuidKey($1)
                }
            )

            struct StoredIntentPayload: Codable {
                let decisionID: UUID
                let intentID: UUID
                let proposal: SchedulerPreemptionProposal
            }
            func replaceIntent(_ record: SchedulerPreemptionIntentRecord) throws {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let payload = try String(
                    decoding: encoder.encode(
                        StoredIntentPayload(
                            decisionID: record.decisionID,
                            intentID: record.intentID,
                            proposal: record.proposal
                        )
                    ),
                    as: UTF8.self
                )
                try store.withValidatedConnection { connection in
                    try connection.run(
                        """
                        UPDATE scheduler_preemption_intents
                        SET proposal_json = ?, intent_digest = ?, record_digest = ?
                        WHERE intent_id = ?
                        """,
                        bindings: [
                            .text(payload),
                            .text(record.proposal.intentDigest),
                            .text(record.recordDigest),
                            .text(record.intentID.uuidString.lowercased()),
                        ]
                    )
                }
            }
            let fencedIntent = try XCTUnwrap(completed.preemptionIntent)
            func assertForgedProposalRejected(
                _ forgedProposal: SchedulerPreemptionProposal
            ) throws {
                let forged = try SchedulerPreemptionIntentRecord(
                    decisionID: targetDecisionID,
                    intentID: fencedIntent.intentID,
                    proposal: forgedProposal,
                    status: .fenced,
                    createdAt: fencedIntent.createdAt,
                    updatedAt: fencedIntent.updatedAt
                )
                try replaceIntent(forged)
                XCTAssertThrowsError(try repository.recoverablePreemptionIntents())
                try replaceIntent(fencedIntent)
            }
            let originalVictim = try XCTUnwrap(proposal.victims.first)
            try assertForgedProposalRejected(
                try SchedulerPreemptionProposal(
                    intentDigest: proposal.intentDigest,
                    targetWorkloadID: proposal.targetWorkloadID,
                    projectID: proposal.projectID,
                    nodeID: proposal.nodeID,
                    victims: [try SchedulerVictimAllocation(
                        workloadID: originalVictim.workloadID,
                        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000999")!,
                        allocation: originalVictim.allocation,
                        subjectID: originalVictim.subjectID,
                        projectID: originalVictim.projectID,
                        priority: originalVictim.priority,
                        disruptionCostBasisPoints: originalVictim.disruptionCostBasisPoints,
                        budgetID: originalVictim.budgetID
                    ), secondVictim],
                    disruptionCostBasisPoints: proposal.disruptionCostBasisPoints,
                    explanation: proposal.explanation
                )
            )
            try assertForgedProposalRejected(
                try SchedulerPreemptionProposal(
                    intentDigest: proposal.intentDigest,
                    targetWorkloadID: proposal.targetWorkloadID,
                    projectID: proposal.projectID,
                    nodeID: proposal.nodeID,
                    victims: [try SchedulerVictimAllocation(
                        workloadID: originalVictim.workloadID,
                        nodeID: originalVictim.nodeID,
                        allocation: try ResourceVector(["cpu": 2]),
                        subjectID: originalVictim.subjectID,
                        projectID: originalVictim.projectID,
                        priority: originalVictim.priority,
                        disruptionCostBasisPoints: originalVictim.disruptionCostBasisPoints,
                        budgetID: originalVictim.budgetID
                    ), secondVictim],
                    disruptionCostBasisPoints: proposal.disruptionCostBasisPoints,
                    explanation: proposal.explanation
                )
            )
            try assertForgedProposalRejected(
                try SchedulerPreemptionProposal(
                    intentDigest: proposal.intentDigest,
                    targetWorkloadID: proposal.targetWorkloadID,
                    projectID: proposal.projectID,
                    nodeID: proposal.nodeID,
                    victims: [try SchedulerVictimAllocation(
                        workloadID: originalVictim.workloadID,
                        nodeID: originalVictim.nodeID,
                        allocation: originalVictim.allocation,
                        subjectID: "foreign-owner",
                        projectID: originalVictim.projectID,
                        priority: originalVictim.priority,
                        disruptionCostBasisPoints: originalVictim.disruptionCostBasisPoints,
                        budgetID: originalVictim.budgetID
                    ), secondVictim],
                    disruptionCostBasisPoints: proposal.disruptionCostBasisPoints,
                    explanation: proposal.explanation
                )
            )
            let foreignDecisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000916")!
            let foreignIntent = try SchedulerPreemptionIntentRecord(
                decisionID: foreignDecisionID,
                intentID: SchedulerAdmissionStableIdentifier.preemptionIntentID(
                    decisionID: foreignDecisionID,
                    targetWorkloadID: proposal.targetWorkloadID
                ),
                proposal: proposal,
                status: .fenced,
                createdAt: fencedIntent.createdAt,
                updatedAt: fencedIntent.updatedAt
            )
            let foreignPayloadEncoder = JSONEncoder()
            foreignPayloadEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let foreignPayload = try String(
                decoding: foreignPayloadEncoder.encode(
                    StoredIntentPayload(
                        decisionID: foreignIntent.decisionID,
                        intentID: foreignIntent.intentID,
                        proposal: foreignIntent.proposal
                    )
                ),
                as: UTF8.self
            )
            try store.withValidatedConnection { connection in
                try connection.run(
                    """
                    INSERT INTO scheduler_preemption_intents (
                        intent_id, project_id, proposal_json, intent_digest,
                        status, created_at, updated_at, record_digest
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(foreignIntent.intentID.uuidString.lowercased()),
                        .text(foreignIntent.projectID),
                        .text(foreignPayload),
                        .text(foreignIntent.proposal.intentDigest),
                        .text(foreignIntent.status.rawValue),
                        .text(foreignIntent.createdAt),
                        .text(foreignIntent.updatedAt),
                        .text(foreignIntent.recordDigest),
                    ]
                )
            }
            XCTAssertThrowsError(try repository.recoverablePreemptionIntents())
            try store.withValidatedConnection { connection in
                try connection.run(
                    "DELETE FROM scheduler_preemption_intents WHERE intent_id = ?",
                    bindings: [.text(foreignIntent.intentID.uuidString.lowercased())]
                )
            }
            let consumed = try XCTUnwrap(
                repository.disruptionBudget(
                    budgetID: "budget-fenced",
                    projectID: projectUUID
                )
            )
            XCTAssertEqual(consumed.generation, 2)
            XCTAssertEqual(consumed.budget.remainingVictimCount, 0)
            XCTAssertEqual(consumed.budget.remainingDisruptionCostBasisPoints, 0)
            XCTAssertEqual(
                try repository.reservation(id: firstPending.reservationID)?.status,
                .released
            )
            XCTAssertEqual(
                try repository.reservation(id: secondPending.reservationID)?.status,
                .released
            )
            _ = try repository.commit(
                reservationID: targetPending.reservationID,
                expectedToken: targetPending.fencingToken,
                updatedAt: timestamp(4)
            )
            _ = try repository.transitionPreemptionIntent(
                intentID: fencedIntent.intentID,
                expectedRecordDigest: fencedIntent.recordDigest,
                to: .applied,
                updatedAt: timestamp(4)
            )
            let replay = try repository.completePreemptionDecision(
                decisionID: targetDecisionID,
                projectUUID: projectUUID,
                workloadID: targetWorkloadID,
                expectedInputDigest: targetDecision.inputDigest,
                currentAuthority: targetAuthority,
                fenceEvidence: [secondFence, firstFence],
                transitionAt: timestamp(5)
            )
            XCTAssertEqual(replay.reservation?.status, .committed)
            XCTAssertEqual(replay.preemptionIntent?.status, .applied)
            XCTAssertEqual(
                try XCTUnwrap(
                    repository.disruptionBudget(
                        budgetID: "budget-fenced",
                        projectID: projectUUID
                    )
                ).generation,
                2
            )
        }
    }

    private struct PlacedFixture {
        let artifact: SchedulerDecisionArtifactRecord
        let binding: SchedulerDecisionWorkloadBinding
        let nodeSnapshot: SchedulerNodeCapacitySnapshot
        let currentAuthority: SchedulerAdmissionCurrentAuthority
    }

    private func makePlacedFixture(
        workloadID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000902")!,
        nodeID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
        capacity: ResourceVector? = nil
    ) throws -> PlacedFixture {
        let workload = try SchedulerWorkload(
            requirements: try WorkloadPlacementRequirements(
                workloadID: workloadID,
                request: try ResourceVector(["cpu": 1]),
                requiredArchitectures: ["arm64"]
            ),
            priority: 10,
            subjectID: "owner",
            projectID: "project-a"
        )
        let nodeCapacity: ResourceVector
        if let capacity {
            nodeCapacity = capacity
        } else {
            nodeCapacity = try ResourceVector(["cpu": 4])
        }
        let node = try SchedulerNode(
            snapshot: try NodePlacementSnapshot(
                nodeID: nodeID,
                capacity: nodeCapacity,
                allocation: try ResourceVector(["cpu": 0]),
                architecture: "arm64",
                runtime: "linux-vm",
                provider: "provider"
            )
        )
        let decision = try SchedulerEngine().plan(
            SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [node]
            )
        )
        let selected = try XCTUnwrap(decision.workloadDecisions.first)
        let selectedNodeID = try XCTUnwrap(selected.chosenNodeID)
        let nodeSnapshot = try SchedulerNodeCapacitySnapshot(
            nodeID: nodeID,
            capacity: nodeCapacity,
            generation: 1,
            observedAt: timestamp(0)
        )
        let binding = try SchedulerDecisionWorkloadBinding(
            workloadID: workloadID,
            nodeID: selectedNodeID,
            resources: workload.request,
            capacityDigest: nodeSnapshot.capacityDigest,
            capacityGeneration: nodeSnapshot.generation,
            ownerSubjectID: "owner",
            projectUUID: projectUUID
        )
        let artifact = try SchedulerDecisionArtifactRecord(
            decision: decision,
            workloadBindings: [binding],
            projectUUID: projectUUID,
            configDigest: digest("c"),
            profileDigest: digest("a"),
            lifecyclePlanDigest: digest("d"),
            createdAt: timestamp(0),
            updatedAt: timestamp(1)
        )
        let currentAuthority = try SchedulerAdmissionCurrentAuthority(
            nodeCapacityDigest: nodeSnapshot.capacityDigest,
            nodeCapacityGeneration: nodeSnapshot.generation,
            configDigest: artifact.configDigest,
            profileDigest: artifact.profileDigest,
            lifecyclePlanDigest: artifact.lifecyclePlanDigest,
            expectedNodeEpoch: 1,
            expectedPressureGeneration: 1,
            expectedPressureEvidenceDigest: digest("a"),
            expectedPressurePosture: .nominal,
            leaseCreatedAt: timestamp(2),
            leaseExpiresAt: timestamp(4)
        )
        return PlacedFixture(
            artifact: artifact,
            binding: binding,
            nodeSnapshot: nodeSnapshot,
            currentAuthority: currentAuthority
        )
    }

    private func withRepository(
        _ body: (SchedulerAdmissionRepository, SQLiteStateStore) throws -> Void
    ) throws {
        try withTemporaryStore { store in
            try insertProject(in: store)
            try store.controlIdentities.bootstrap(
                ControlPeerIdentityRecord(
                    subjectID: "owner",
                    userID: 501,
                    codeIdentity: CodeIdentity(
                        teamIdentifier: "993YC3JY4Q",
                        signingIdentifier: "hostwright",
                        codeDirectoryHash: String(repeating: "a", count: 40),
                        validationMode: .installedRequirement
                    ),
                    declaredBySubjectID: "owner",
                    declaredAt: timestamp(0),
                    updatedAt: timestamp(0)
                )
            )
            _ = try store.schedulerAdmissions.recordHostPressure(
                record: try SchedulerHostPressureRecord(
                    nodeID: nodeID,
                    posture: SchedulerHostPosture(
                        pressure: .nominal,
                        energy: .balanced
                    ),
                    generation: 1,
                    observedAt: timestamp(0),
                    evidenceDigest: digest("a"),
                    policyState: try pressurePolicyState(
                        reasonCodes: [.allowed],
                        nextPosture: .allowed
                    )
                )
            )
            try body(store.schedulerAdmissions, store)
        }
    }

    private func makeIntent() throws -> SchedulerPreemptionIntentRecord {
        let proposal = try makeProposal(victim: makeVictim())
        return try SchedulerPreemptionIntentRecord(
            decisionID: decisionID,
            intentID: SchedulerAdmissionStableIdentifier.preemptionIntentID(
                decisionID: decisionID,
                targetWorkloadID: proposal.targetWorkloadID
            ),
            proposal: proposal,
            createdAt: timestamp(0),
            updatedAt: timestamp(0)
        )
    }

    private func makeProposal(
        victim: SchedulerVictimAllocation,
        projectID: String = "project-a"
    ) throws -> SchedulerPreemptionProposal {
        try SchedulerPreemptionProposal(
            intentDigest: digest("f"),
            targetWorkloadID: targetWorkloadID,
            projectID: projectID,
            nodeID: nodeID,
            victims: [victim],
            disruptionCostBasisPoints: victim.disruptionCostBasisPoints,
            explanation: try SchedulerPreemptionExplanation(
                summary: "bounded preemption intent",
                victimCount: 1,
                disruptionCostBasisPoints: victim.disruptionCostBasisPoints,
                budgetIDs: ["budget-a"]
            )
        )
    }

    private func makeVictim(projectID: String = "project-a") throws -> SchedulerVictimAllocation {
        try SchedulerVictimAllocation(
            workloadID: victimWorkloadID,
            nodeID: nodeID,
            allocation: try ResourceVector(["cpu": 1]),
            subjectID: "subject-a",
            projectID: projectID,
            priority: 1,
            disruptionCostBasisPoints: 10,
            budgetID: "budget-a"
        )
    }

    private func withTemporaryStore(_ body: (SQLiteStateStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-scheduler-authority-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        // The v22 authority append is covered by the dedicated migration
        // tests; repository behavior must reopen against the current v23
        // production schema.
        try MigrationRunner().apply(
            to: store,
            throughVersion: MigrationRunner.latestSchemaVersion
        )
        try body(store)
    }

    private func insertProject(in store: SQLiteStateStore) throws {
        try store.withConnection { connection in
            try connection.run(
                """
                INSERT INTO projects (
                    id, name, manifest_path, manifest_hash, created_at, updated_at,
                    resource_uuid, manifest_version, mutation_provider, provider_generation
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text("project-a"),
                    .text("project-a"),
                    .null,
                    .text(String(repeating: "a", count: 64)),
                    .text(timestamp(0)),
                    .text(timestamp(0)),
                    .text("00000000-0000-0000-0000-000000000905"),
                    .int(1),
                    .null,
                    .int(0),
                ]
            )
        }
    }

    private func pressurePolicyState(
        reasonCodes: [SchedulerHostPressureReasonCode],
        nextPosture: SchedulerHostPressurePolicyPosture,
        clearObservations: Int = 0
    ) throws -> SchedulerHostPressurePolicyState {
        try SchedulerHostPressurePolicyState(
            version: SchedulerHostPressurePolicyState.currentVersion,
            reasonCodes: reasonCodes,
            nextHysteresisState: try SchedulerHostPressureHysteresisState(
                posture: nextPosture,
                consecutiveClearObservations: clearObservations,
                version: SchedulerHostPressurePolicyState.currentVersion
            )
        )
    }

    private func timestamp(_ offset: Int) -> String {
        "2026-08-05T12:0\(offset):00Z"
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private var nodeID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
    }

    private var targetWorkloadID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000902")!
    }

    private var victimWorkloadID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000903")!
    }

}
