import XCTest
@testable import HostwrightScheduler

final class SchedulerEngineContractTests: XCTestCase {
    func testFairnessGuaranteeCannotExceedQuotaOnAnyResource() throws {
        let expected = SchedulerEngineValidationError.invalidDecision(
            "fairness-guarantee-exceeds-quota"
        )
        XCTAssertThrowsError(
            try SchedulerFairnessState(
                subjectID: "subject",
                projectID: "project",
                guarantee: try ResourceVector(["cpu": 3, "memory": 1]),
                quota: try ResourceVector(["cpu": 2])
            )
        ) { error in
            XCTAssertEqual(error as? SchedulerEngineValidationError, expected)
        }

        let hostilePayload = Data(
            """
            {
              "subjectID": "subject",
              "projectID": "project",
              "guarantee": {"cpu": 3, "memory": 1},
              "quota": {"cpu": 2}
            }
            """.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(SchedulerFairnessState.self, from: hostilePayload)
        ) { error in
            XCTAssertEqual(error as? SchedulerEngineValidationError, expected)
        }
    }

    func testFiniteCountLimitsRejectBeforePlanning() throws {
        XCTAssertThrowsError(
            try SchedulerEngineLimits(maxExactPreemptionSearchStates: 0)
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .invalidCount(field: "exact-preemption-search-states", value: 0)
            )
        }

        let limits = try SchedulerEngineLimits(
            maxWorkloadCount: 1,
            maxNodeCount: 4,
            maxVictimCount: 4,
            maxAlternativeCount: 2,
            maxStringBytes: 64,
            maxDigestBytes: 128
        )
        let workloads = try [
            makeWorkload("00000000-0000-0000-0000-000000000001"),
            makeWorkload("00000000-0000-0000-0000-000000000002")
        ]

        XCTAssertThrowsError(
            try SchedulerEngineInput(
                inputDigest: nil,
                pendingWorkloads: workloads,
                nodes: [makeNode()],
                limits: limits
            )
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .countLimitExceeded(field: "workloads", limit: 1, actual: 2)
            )
        }
    }

    func testDigestAndCallerStringLimitsAreStable() throws {
        let limits = try SchedulerEngineLimits(
            maxWorkloadCount: 4,
            maxNodeCount: 4,
            maxVictimCount: 4,
            maxAlternativeCount: 2,
            maxStringBytes: 8,
            maxDigestBytes: 8
        )
        XCTAssertThrowsError(
            try SchedulerEngineInput(
                inputDigest: "123456789",
                pendingWorkloads: [try makeWorkload("00000000-0000-0000-0000-000000000001")],
                nodes: [try makeNode()],
                limits: limits
            )
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .digestLimitExceeded(limit: 8, actual: 9)
            )
        }

        XCTAssertThrowsError(
            try SchedulerWorkload(
                requirements: try WorkloadPlacementRequirements(
                    workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    request: try ResourceVector(["cpu": 1])
                ),
                priority: 1,
                subjectID: String(repeating: "s", count: 4_097),
                projectID: "project"
            )
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .stringLimitExceeded(
                    field: "subject-id",
                    limit: SchedulerEngineLimits.absoluteMaxStringBytes,
                    actual: 4_097
                )
            )
        }
    }

    func testAlternativeAndExplanationResultsAreBoundedAndReplayable() throws {
        let limits = try SchedulerEngineLimits(
            maxWorkloadCount: 4,
            maxNodeCount: 4,
            maxVictimCount: 4,
            maxAlternativeCount: 1,
            maxStringBytes: 64,
            maxDigestBytes: 128
        )
        let workload = try makeWorkload("00000000-0000-0000-0000-000000000001")
        let nodes = try [
            makeNode("00000000-0000-0000-0000-000000000002"),
            makeNode("00000000-0000-0000-0000-000000000003")
        ]
        let decision = try SchedulerEngine().plan(
            SchedulerEngineInput(
                inputDigest: nil,
                pendingWorkloads: [workload],
                nodes: nodes,
                limits: limits
            )
        )

        XCTAssertLessThanOrEqual(decision.workloadDecisions[0].feasibleAlternatives.count, 1)
        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(SchedulerDecision.self, from: data)
        XCTAssertEqual(decoded, decision)
        XCTAssertNotEqual(
            decision.decisionID,
            UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        )
        XCTAssertEqual(decoded.decisionID, decision.decisionID)
    }

    func testDeclaredLimitIsChargedAtDefaultRatioOne() throws {
        let workload = try SchedulerWorkload(
            requirements: try WorkloadPlacementRequirements(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                resources: WorkloadResourceSnapshot(
                    request: try ResourceVector(["cpu": 2]),
                    limit: try ResourceVector(["cpu": 4])
                )
            ),
            priority: 1,
            subjectID: "subject",
            projectID: "project"
        )
        let node = try makeNode(
            "00000000-0000-0000-0000-000000000002",
            capacity: 2
        )

        let conservative = try SchedulerEngine().plan(
            SchedulerEngineInput(
                inputDigest: nil,
                pendingWorkloads: [workload],
                nodes: [node]
            )
        ).workloadDecisions[0]
        let explicit = try SchedulerEngine().plan(
            SchedulerEngineInput(
                inputDigest: nil,
                pendingWorkloads: [workload],
                nodes: [node],
                overcommitRatios: [
                    "cpu": try SchedulerResourceRatio(numerator: 2, denominator: 1)
                ]
            )
        ).workloadDecisions[0]

        XCTAssertEqual(conservative.outcome, .unschedulable)
        XCTAssertEqual(explicit.outcome, .placed)
        XCTAssertTrue(explicit.explanation.detailKeys.contains("limit-charge:cpu:2"))
    }

    func testUnsupportedLimitDimensionFailsAdmissionWithStableError() throws {
        let workload = try SchedulerWorkload(
            requirements: try WorkloadPlacementRequirements(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                resources: WorkloadResourceSnapshot(
                    request: try ResourceVector(["cpu": 1]),
                    limit: try ResourceVector(["cpu": 1, "memory": 4])
                )
            ),
            priority: 1,
            subjectID: "subject",
            projectID: "project"
        )

        XCTAssertThrowsError(
            try SchedulerEngineInput(
                inputDigest: "digest",
                pendingWorkloads: [workload],
                nodes: [try makeNode()]
            )
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .unsupportedLimit(resource: "memory")
            )
        }
    }

    func testCanonicalDigestBindsNormalizedInputsAndRejectsReuse() throws {
        let workload = try makeWorkload("00000000-0000-0000-0000-000000000001")
        let secondWorkload = try makeWorkload("00000000-0000-0000-0000-000000000002")
        let node = try makeNode("00000000-0000-0000-0000-000000000010")
        let secondNode = try makeNode("00000000-0000-0000-0000-000000000011")
        let fairness = try SchedulerFairnessState(
            subjectID: "subject",
            projectID: "project"
        )
        let secondFairness = try SchedulerFairnessState(
            subjectID: "second-subject",
            projectID: "project"
        )
        let base = try SchedulerEngineInput(
            inputDigest: nil,
            pendingWorkloads: [workload, secondWorkload],
            nodes: [node, secondNode],
            fairnessStates: [fairness, secondFairness]
        )
        let reordered = try SchedulerEngineInput(
            inputDigest: nil,
            pendingWorkloads: [secondWorkload, workload],
            nodes: [secondNode, node],
            fairnessStates: [secondFairness, fairness]
        )
        XCTAssertEqual(base.inputDigest, reordered.inputDigest)

        let changedCapacity = try SchedulerEngineInput(
            inputDigest: nil,
            pendingWorkloads: [workload, secondWorkload],
            nodes: [
                try makeNode("00000000-0000-0000-0000-000000000010", capacity: 3),
                secondNode
            ],
            fairnessStates: [fairness, secondFairness]
        )
        let changedFairness = try SchedulerEngineInput(
            inputDigest: nil,
            pendingWorkloads: [workload, secondWorkload],
            nodes: [node, secondNode],
            fairnessStates: [
                try SchedulerFairnessState(
                    subjectID: "subject",
                    projectID: "project",
                    usage: try ResourceVector(["cpu": 1])
                ),
                secondFairness
            ]
        )
        let changedPreemption = try SchedulerEngineInput(
            inputDigest: nil,
            pendingWorkloads: [workload, secondWorkload],
            nodes: [node, secondNode],
            fairnessStates: [fairness, secondFairness],
            preemptionPolicy: try SchedulerPreemptionPolicy(incomingNonPreempting: true)
        )
        let changedStability = try SchedulerEngineInput(
            inputDigest: nil,
            pendingWorkloads: [workload, secondWorkload],
            nodes: [node, secondNode],
            fairnessStates: [fairness, secondFairness],
            stabilityPolicy: try SchedulerStabilityPolicy(minimumResidenceUnits: 1)
        )
        let changedQueue = try SchedulerEngineInput(
            inputDigest: nil,
            pendingWorkloads: [workload, secondWorkload],
            nodes: [node, secondNode],
            fairnessStates: [fairness, secondFairness],
            queuePolicy: try SchedulerQueuePolicy(
                priorityPrecedesFairness: false,
                starvationAgeThresholdUnits: 1
            )
        )
        let changedSearchBudget = try SchedulerEngineInput(
            inputDigest: nil,
            pendingWorkloads: [workload, secondWorkload],
            nodes: [node, secondNode],
            fairnessStates: [fairness, secondFairness],
            limits: try SchedulerEngineLimits(maxExactPreemptionSearchStates: 32)
        )

        XCTAssertNotEqual(base.inputDigest, changedCapacity.inputDigest)
        XCTAssertNotEqual(base.inputDigest, changedFairness.inputDigest)
        XCTAssertNotEqual(base.inputDigest, changedPreemption.inputDigest)
        XCTAssertNotEqual(base.inputDigest, changedStability.inputDigest)
        XCTAssertNotEqual(base.inputDigest, changedQueue.inputDigest)
        XCTAssertNotEqual(base.inputDigest, changedSearchBudget.inputDigest)

        let acceptedExpectedDigest = try SchedulerEngineInput(
            inputDigest: base.inputDigest,
            pendingWorkloads: [workload, secondWorkload],
            nodes: [node, secondNode],
            fairnessStates: [fairness, secondFairness]
        )
        XCTAssertEqual(acceptedExpectedDigest.inputDigest, base.inputDigest)
        let replayed = try JSONDecoder().decode(
            SchedulerEngineInput.self,
            from: JSONEncoder().encode(base)
        )
        XCTAssertEqual(replayed, base)
        XCTAssertThrowsError(
            try SchedulerEngineInput(
                inputDigest: base.inputDigest,
                pendingWorkloads: [workload, secondWorkload],
                nodes: [try makeNode(
                    "00000000-0000-0000-0000-000000000010",
                    capacity: 3
                ), secondNode],
                fairnessStates: [fairness, secondFairness]
            )
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .invalidDecision("input-digest-mismatch")
            )
        }
    }

    private func makeWorkload(_ id: String) throws -> SchedulerWorkload {
        try SchedulerWorkload(
            requirements: try WorkloadPlacementRequirements(
                workloadID: UUID(uuidString: id)!,
                request: try ResourceVector(["cpu": 1])
            ),
            priority: 1,
            subjectID: "subject",
            projectID: "project"
        )
    }

    private func makeNode(
        _ id: String = "00000000-0000-0000-0000-000000000010",
        capacity: Int64 = 2
    ) throws -> SchedulerNode {
        try SchedulerNode(
            snapshot: try NodePlacementSnapshot(
                nodeID: UUID(uuidString: id)!,
                capacity: try ResourceVector(["cpu": capacity]),
                allocation: .zero,
                architecture: "arm64",
                runtime: "linux-vm",
                provider: "provider"
            )
        )
    }
}
