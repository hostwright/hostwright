import XCTest
@testable import HostwrightScheduler

final class SchedulerEngineTests: XCTestCase {
    func testPendingWorkloadsUseBestFitDecreasingOrderIndependentOfInputOrder() throws {
        let workloads = [
            try makeWorkload(id: "00000000-0000-0000-0000-000000000003", request: 4),
            try makeWorkload(id: "00000000-0000-0000-0000-000000000001", request: 6),
            try makeWorkload(id: "00000000-0000-0000-0000-000000000002", request: 5)
        ]
        let nodes = [try makeNode(id: "00000000-0000-0000-0000-000000000010", cpu: 10)]

        let forward = try SchedulerEngine().plan(
            makeInput(workloads: workloads, nodes: nodes)
        )
        let reverse = try SchedulerEngine().plan(
            makeInput(
                workloads: Array(workloads.reversed()),
                nodes: Array(nodes.reversed())
            )
        )

        XCTAssertEqual(
            forward.orderedWorkloadIDs,
            [
                UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
            ]
        )
        XCTAssertEqual(forward, reverse)
    }

    func testStableUUIDBreaksDominantAndTotalRequestTies() throws {
        let lower = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000001",
            request: 2
        )
        let higher = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000002",
            request: 2
        )
        let decision = try SchedulerEngine().plan(
            makeInput(
                workloads: [higher, lower],
                nodes: [try makeNode(id: "00000000-0000-0000-0000-000000000010", cpu: 8)]
            )
        )

        XCTAssertEqual(decision.orderedWorkloadIDs, [lower.workloadID, higher.workloadID])
    }

    func testBFDOrdersWithinEqualFairEligibility() throws {
        let larger = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000001",
            request: 3,
            subjectID: "same-tenant"
        )
        let smaller = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000002",
            request: 1,
            subjectID: "same-tenant"
        )
        let decision = try SchedulerEngine().plan(
            makeInput(
                workloads: [smaller, larger],
                nodes: [try makeNode(
                    id: "00000000-0000-0000-0000-000000000010",
                    cpu: 8
                )],
                fairnessStates: [try SchedulerFairnessState(
                    subjectID: "same-tenant",
                    projectID: "project"
                )]
            )
        )

        XCTAssertEqual(decision.orderedWorkloadIDs, [larger.workloadID, smaller.workloadID])
    }

    func testBFDIsCanonicalWithinEqualFairClassBeforeNodeScoring() throws {
        let larger = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000001",
            request: 4,
            subjectID: "tenant-a"
        )
        let smaller = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000002",
            request: 1,
            subjectID: "tenant-b"
        )
        let fairness = try [
            SchedulerFairnessState(subjectID: "tenant-a", projectID: "project"),
            SchedulerFairnessState(subjectID: "tenant-b", projectID: "project"),
        ]
        let decision = try SchedulerEngine().plan(
            makeInput(
                workloads: [smaller, larger],
                nodes: [try makeNode(
                    id: "00000000-0000-0000-0000-000000000010",
                    cpu: 8
                )],
                fairnessStates: fairness
            )
        )

        XCTAssertEqual(decision.orderedWorkloadIDs, [larger.workloadID, smaller.workloadID])
    }

    func testDynamicFairQueueInterleavesTenantsAfterEachPlacement() throws {
        let tenantAFirst = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000001",
            request: 1,
            subjectID: "tenant-a"
        )
        let tenantASecond = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000002",
            request: 1,
            subjectID: "tenant-a"
        )
        let tenantBFirst = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000003",
            request: 1,
            subjectID: "tenant-b"
        )
        let tenantBSecond = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000004",
            request: 1,
            subjectID: "tenant-b"
        )
        let workloads = [tenantBSecond, tenantASecond, tenantBFirst, tenantAFirst]
        let fairness = try [
            SchedulerFairnessState(subjectID: "tenant-a", projectID: "project"),
            SchedulerFairnessState(subjectID: "tenant-b", projectID: "project")
        ]
        let nodes = [try makeNode(
            id: "00000000-0000-0000-0000-000000000010",
            cpu: 4
        )]

        let forward = try SchedulerEngine().plan(
            makeInput(workloads: workloads, nodes: nodes, fairnessStates: fairness)
        )
        let reverse = try SchedulerEngine().plan(
            makeInput(
                workloads: Array(workloads.reversed()),
                nodes: Array(nodes.reversed()),
                fairnessStates: Array(fairness.reversed())
            )
        )

        XCTAssertEqual(
            forward.orderedWorkloadIDs,
            [
                tenantAFirst.workloadID,
                tenantBFirst.workloadID,
                tenantASecond.workloadID,
                tenantBSecond.workloadID
            ]
        )
        XCTAssertEqual(forward, reverse)
    }

    func testPendingDemandDoesNotPenalizeCurrentDRFShare() throws {
        let demandHeavy = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000001",
            request: 1,
            subjectID: "demand-heavy"
        )
        let demandLight = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000002",
            request: 1,
            subjectID: "demand-light"
        )
        let decision = try SchedulerEngine().plan(
            makeInput(
                workloads: [demandLight, demandHeavy],
                nodes: [try makeNode(
                    id: "00000000-0000-0000-0000-000000000010",
                    cpu: 1
                )],
                fairnessStates: [
                    try SchedulerFairnessState(
                        subjectID: "demand-heavy",
                        projectID: "project",
                        pendingDemand: try ResourceVector(["cpu": 1])
                    ),
                    try SchedulerFairnessState(
                        subjectID: "demand-light",
                        projectID: "project"
                    )
                ]
            )
        )

        XCTAssertEqual(decision.orderedWorkloadIDs, [
            demandHeavy.workloadID,
            demandLight.workloadID
        ])
        XCTAssertEqual(decision.workloadDecisions[0].outcome, .placed)
        XCTAssertEqual(decision.workloadDecisions[1].outcome, .unschedulable)
    }

    func testLowerDominantShareTenantWinsTheOneRemainingPlacement() throws {
        let highShareWorkload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000001",
            request: 2,
            subjectID: "high-share"
        )
        let lowShareWorkload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000002",
            request: 1,
            subjectID: "low-share"
        )
        let fairness = try [
            SchedulerFairnessState(
                subjectID: "high-share",
                projectID: "project",
                usage: try ResourceVector(["cpu": 3])
            ),
            SchedulerFairnessState(
                subjectID: "low-share",
                projectID: "project"
            )
        ]
        let decision = try SchedulerEngine().plan(
            makeInput(
                workloads: [highShareWorkload, lowShareWorkload],
                nodes: [try makeNode(
                    id: "00000000-0000-0000-0000-000000000010",
                    cpu: 4,
                    allocation: 2
                )],
                fairnessStates: fairness
            )
        )

        XCTAssertEqual(
            decision.orderedWorkloadIDs,
            [lowShareWorkload.workloadID, highShareWorkload.workloadID]
        )
        XCTAssertEqual(decision.workloadDecisions[0].outcome, .placed)
        XCTAssertEqual(decision.workloadDecisions[1].outcome, .unschedulable)
    }

    func testHardFiltersRemainAuthoritativeBeforeScoring() throws {
        let workload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000001",
            request: 1,
            architecture: "arm64"
        )
        let rejected = try makeNode(
            id: "00000000-0000-0000-0000-000000000001",
            cpu: 8,
            architecture: "x86_64"
        )
        let accepted = try makeNode(
            id: "00000000-0000-0000-0000-000000000002",
            cpu: 8,
            architecture: "arm64"
        )

        let result = try SchedulerEngine().plan(
            makeInput(workloads: [workload], nodes: [rejected, accepted])
        ).workloadDecisions[0]

        XCTAssertEqual(result.chosenNodeID, accepted.nodeID)
        XCTAssertEqual(result.filterFailures.count, 1)
        XCTAssertEqual(result.filterFailures[0].code, .architectureMismatch)
        XCTAssertTrue(result.feasibleAlternatives.allSatisfy { $0.nodeID != rejected.nodeID })
    }

    func testCriticalUnknownAndUnavailablePressureAreHardFilterFailures() throws {
        let workload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000001",
            request: 1
        )
        let critical = try makeNode(
            id: "00000000-0000-0000-0000-000000000002",
            cpu: 2,
            posture: SchedulerHostPosture(pressure: .critical)
        )
        let unknown = try makeNode(
            id: "00000000-0000-0000-0000-000000000003",
            cpu: 2,
            posture: SchedulerHostPosture(pressure: .unknown)
        )
        let unavailable = try makeNode(
            id: "00000000-0000-0000-0000-000000000004",
            cpu: 2,
            posture: SchedulerHostPosture(pressure: .unavailable)
        )
        let nominal = try makeNode(
            id: "00000000-0000-0000-0000-000000000005",
            cpu: 2
        )

        let result = try SchedulerEngine().plan(
            makeInput(workloads: [workload], nodes: [critical, unknown, unavailable, nominal])
        ).workloadDecisions[0]

        XCTAssertEqual(result.chosenNodeID, nominal.nodeID)
        XCTAssertEqual(
            result.filterFailures.filter { $0.code == .pressureUnavailable }.count,
            3
        )
        XCTAssertTrue(result.explanation.detailKeys.contains("pressure-unavailable"))
    }

    func testTopologySpreadPrefersTheLessOccupiedDomain() throws {
        let east = try makeNode(
            id: "00000000-0000-0000-0000-000000000001",
            cpu: 8,
            allocation: 1,
            topology: ["zone": "east"]
        )
        let west = try makeNode(
            id: "00000000-0000-0000-0000-000000000002",
            cpu: 8,
            topology: ["zone": "west"]
        )
        let workload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000010",
            request: 1,
            topology: SchedulerTopologyPreference(
                groupID: "web",
                spreadKey: "zone"
            )
        )
        let existing = try SchedulerVictimAllocation(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            nodeID: east.nodeID,
            allocation: try ResourceVector(["cpu": 1]),
            subjectID: "existing",
            projectID: "project",
            priority: 0,
            disruptionCostBasisPoints: 0,
            preemptible: false,
            topologyGroupID: "web"
        )

        let result = try SchedulerEngine().plan(
            makeInput(
                workloads: [workload],
                nodes: [east, west],
                victimAllocations: [existing],
                weights: SchedulerScoreWeights(
                    fragmentation: 0,
                    fairness: 0,
                    topology: 10,
                    locality: 0,
                    hostPressureEnergy: 0,
                    disruption: 0
                )
            )
        ).workloadDecisions[0]

        XCTAssertEqual(result.chosenNodeID, west.nodeID)
        XCTAssertGreaterThan(
            result.scoreComponents?.topologyBasisPoints ?? 0,
            result.feasibleAlternatives.first { $0.nodeID == east.nodeID }?.scoreComponents.topologyBasisPoints ?? 0
        )
    }

    func testFairnessScoreRewardsAStarvingSubjectAndBorrowsUnusedGuarantee() throws {
        let node = try makeNode(id: "00000000-0000-0000-0000-000000000001", cpu: 10)
        let starving = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000002",
            request: 1,
            subjectID: "starving"
        )
        let saturated = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000003",
            request: 1,
            subjectID: "saturated"
        )
        let states = [
            try SchedulerFairnessState(
                subjectID: "starving",
                projectID: "project",
                usage: ResourceVector.zero,
                guarantee: try ResourceVector(["cpu": 5])
            ),
            try SchedulerFairnessState(
                subjectID: "saturated",
                projectID: "project",
                usage: try ResourceVector(["cpu": 8]),
                guarantee: try ResourceVector(["cpu": 5])
            )
        ]

        let starvingResult = try SchedulerEngine().plan(
            makeInput(workloads: [starving], nodes: [node], fairnessStates: states)
        ).workloadDecisions[0]
        let saturatedResult = try SchedulerEngine().plan(
            makeInput(workloads: [saturated], nodes: [node], fairnessStates: states)
        ).workloadDecisions[0]

        XCTAssertGreaterThan(
            starvingResult.scoreComponents?.fairnessBasisPoints ?? 0,
            saturatedResult.scoreComponents?.fairnessBasisPoints ?? 0
        )
    }

    func testBorrowingDoesNotConsumeAGuaranteeActivelyDemandedByItsOwner() throws {
        let borrower = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000010",
            request: 1,
            subjectID: "borrower"
        )
        let node = try makeNode(
            id: "00000000-0000-0000-0000-000000000011",
            cpu: 10
        )
        let borrowerState = try SchedulerFairnessState(
            subjectID: "borrower",
            projectID: "project",
            usage: try ResourceVector(["cpu": 8]),
            guarantee: try ResourceVector(["cpu": 5])
        )
        let ownerWithoutDemand = try SchedulerFairnessState(
            subjectID: "owner",
            projectID: "project",
            guarantee: try ResourceVector(["cpu": 5])
        )
        let ownerWithDemand = try SchedulerFairnessState(
            subjectID: "owner",
            projectID: "project",
            guarantee: try ResourceVector(["cpu": 5]),
            pendingDemand: try ResourceVector(["cpu": 5])
        )

        let borrowerWithoutDemand = try SchedulerEngine().plan(
            makeInput(
                workloads: [borrower],
                nodes: [node],
                fairnessStates: [borrowerState, ownerWithoutDemand]
            )
        ).workloadDecisions[0]
        let borrowerWithDemand = try SchedulerEngine().plan(
            makeInput(
                workloads: [borrower],
                nodes: [node],
                fairnessStates: [borrowerState, ownerWithDemand]
            )
        ).workloadDecisions[0]

        XCTAssertEqual(
            borrowerWithoutDemand.fairnessExplanation?.borrowingBasisPoints,
            4_000
        )
        XCTAssertEqual(
            borrowerWithDemand.fairnessExplanation?.borrowingBasisPoints,
            0
        )
    }

    func testAntiChurnRetainsAValidPlacementUntilImprovementExceedsThreshold() throws {
        let current = try makeNode(
            id: "00000000-0000-0000-0000-000000000001",
            cpu: 10,
            allocation: 2
        )
        let alternative = try makeNode(
            id: "00000000-0000-0000-0000-000000000002",
            cpu: 10,
            allocation: 8
        )
        let workload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000010",
            request: 2,
            disruption: SchedulerDisruptionProfile(movementCostBasisPoints: 0)
        )
        let placement = try SchedulerExistingPlacement(
            workloadID: workload.workloadID,
            nodeID: current.nodeID,
            allocation: try ResourceVector(["cpu": 2])
        )
        let fragmentationOnly = try SchedulerScoreWeights(
            fragmentation: 1,
            fairness: 0,
            topology: 0,
            locality: 0,
            hostPressureEnergy: 0,
            disruption: 0
        )

        let retained = try SchedulerEngine().plan(
            makeInput(
                workloads: [workload],
                nodes: [current, alternative],
                existingPlacements: [placement],
                antiChurnThresholdBasisPoints: 10_000,
                weights: fragmentationOnly
            )
        ).workloadDecisions[0]
        let eligibleToMove = try SchedulerEngine().plan(
            makeInput(
                workloads: [workload],
                nodes: [current, alternative],
                existingPlacements: [placement],
                antiChurnThresholdBasisPoints: 0,
                weights: fragmentationOnly
            )
        ).workloadDecisions[0]

        XCTAssertEqual(retained.chosenNodeID, current.nodeID)
        XCTAssertEqual(eligibleToMove.chosenNodeID, alternative.nodeID)
    }

    func testPreemptionIsLowerPriorityBudgetRespectingAndFencedWithoutMutation() throws {
        let node = try makeNode(
            id: "00000000-0000-0000-0000-000000000001",
            cpu: 4,
            allocation: 4
        )
        let workload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000010",
            request: 2,
            priority: 10,
            preemptionEligibility: .eligible
        )
        let victim = try SchedulerVictimAllocation(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            nodeID: node.nodeID,
            allocation: try ResourceVector(["cpu": 2]),
            subjectID: "victim",
            projectID: "project",
            priority: 1,
            disruptionCostBasisPoints: 100,
            budgetID: "budget"
        )
        let budget = try SchedulerDisruptionBudget(
            budgetID: "budget",
            projectID: "project",
            remainingVictimCount: 1,
            remainingDisruptionCostBasisPoints: 100
        )

        let input = try makeInput(
            workloads: [workload],
            nodes: [node],
            victimAllocations: [victim],
            disruptionBudgets: [budget],
            preemptionPolicy: try authorizedPreemptionPolicy()
        )
        let result = try SchedulerEngine().plan(input).workloadDecisions[0]

        XCTAssertEqual(result.outcome, .preemptionProposed)
        XCTAssertNil(result.chosenNodeID)
        XCTAssertEqual(result.preemption?.victimWorkloadIDs, [victim.workloadID])
        XCTAssertEqual(result.preemption?.projectID, workload.projectID)
        XCTAssertEqual(result.preemption?.victims.first?.subjectID, victim.subjectID)
        XCTAssertEqual(result.preemption?.victims.first?.projectID, victim.projectID)
        XCTAssertTrue(result.preemption?.requiresFence == true)
        XCTAssertEqual(result.preemption?.intentDigest, input.inputDigest)
        XCTAssertEqual(input.nodes[0].allocation, node.allocation)
    }

    func testPreemptionCannotBypassAZeroBudgetOrAHighPriorityVictim() throws {
        let node = try makeNode(
            id: "00000000-0000-0000-0000-000000000001",
            cpu: 2,
            allocation: 2
        )
        let workload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000010",
            request: 2,
            priority: 10,
            preemptionEligibility: .eligible
        )
        let victim = try SchedulerVictimAllocation(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            nodeID: node.nodeID,
            allocation: try ResourceVector(["cpu": 2]),
            subjectID: "victim",
            projectID: "project",
            priority: 10,
            disruptionCostBasisPoints: 1,
            budgetID: "budget"
        )
        let budget = try SchedulerDisruptionBudget(
            budgetID: "budget",
            projectID: "project",
            remainingVictimCount: 0,
            remainingDisruptionCostBasisPoints: 1_000
        )

        let result = try SchedulerEngine().plan(
            makeInput(
                workloads: [workload],
                nodes: [node],
                victimAllocations: [victim],
                disruptionBudgets: [budget]
            )
        ).workloadDecisions[0]

        XCTAssertEqual(result.outcome, .unschedulable)
        XCTAssertNil(result.preemption)
    }

    func testSimulationIsPureAndMatchesPlanning() throws {
        let workload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000001",
            request: 1
        )
        let input = try makeInput(
            workloads: [workload],
            nodes: [try makeNode(id: "00000000-0000-0000-0000-000000000002", cpu: 2)]
        )
        let before = input

        let engine = SchedulerEngine()
        let planned = try engine.plan(input)
        let simulated = try engine.simulate(input)

        XCTAssertEqual(planned, simulated)
        XCTAssertEqual(input, before)
    }

    func testSequentialPlacementsConsumeCapacityAndUpdateTopologyAndFairness() throws {
        let east = try makeNode(
            id: "00000000-0000-0000-0000-000000000001",
            cpu: 3,
            topology: ["zone": "east"]
        )
        let west = try makeNode(
            id: "00000000-0000-0000-0000-000000000002",
            cpu: 3,
            topology: ["zone": "west"]
        )
        let first = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000010",
            request: 2,
            subjectID: "subject-a",
            topology: SchedulerTopologyPreference(groupID: "web", spreadKey: "zone")
        )
        let second = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000011",
            request: 2,
            subjectID: "subject-a",
            topology: SchedulerTopologyPreference(groupID: "web", spreadKey: "zone")
        )

        let decision = try SchedulerEngine().plan(
            makeInput(
                workloads: [first, second],
                nodes: [east, west],
                weights: SchedulerScoreWeights(
                    fragmentation: 0,
                    fairness: 3,
                    topology: 3,
                    locality: 0,
                    hostPressureEnergy: 0,
                    disruption: 0
                )
            )
        )

        XCTAssertEqual(decision.workloadDecisions.count, 2)
        XCTAssertNotEqual(
            decision.workloadDecisions[0].chosenNodeID,
            decision.workloadDecisions[1].chosenNodeID
        )
        XCTAssertTrue(decision.workloadDecisions[1].filterFailures.contains {
            $0.code == .insufficientCapacity
        })
        XCTAssertNotEqual(
            decision.workloadDecisions[0].scoreComponents?.topologyBasisPoints,
            decision.workloadDecisions[1].scoreComponents?.topologyBasisPoints
        )
    }

    func testMultiResourceBestFitOrderingIgnoresResourceAndInputDictionaryOrder() throws {
        let first = try SchedulerWorkload(
            requirements: try WorkloadPlacementRequirements(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                request: try ResourceVector(["memory": 8, "cpu": 2])
            ),
            priority: 1,
            subjectID: "subject",
            projectID: "project"
        )
        let second = try SchedulerWorkload(
            requirements: try WorkloadPlacementRequirements(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                request: try ResourceVector(["cpu": 3, "memory": 4])
            ),
            priority: 1,
            subjectID: "subject",
            projectID: "project"
        )
        let nodes = try [
            makeNode(id: "00000000-0000-0000-0000-000000000010", cpu: 8, memory: 16),
            makeNode(id: "00000000-0000-0000-0000-000000000011", cpu: 8, memory: 16)
        ]

        let firstDecision = try SchedulerEngine().plan(
            makeInput(workloads: [second, first], nodes: nodes)
        )
        let secondDecision = try SchedulerEngine().plan(
            makeInput(workloads: [first, second], nodes: Array(nodes.reversed()))
        )

        XCTAssertEqual(firstDecision, secondDecision)
        XCTAssertEqual(firstDecision.orderedWorkloadIDs, [first.workloadID, second.workloadID])
    }

    func testPreemptionChoosesDeterministicMinimumDisruptionVictimsAcrossBudgets() throws {
        let node = try makeNode(
            id: "00000000-0000-0000-0000-000000000001",
            cpu: 10,
            allocation: 10
        )
        let workload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000010",
            request: 5,
            priority: 10,
            preemptionEligibility: .eligible
        )
        let firstVictim = try SchedulerVictimAllocation(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            nodeID: node.nodeID,
            allocation: try ResourceVector(["cpu": 2]),
            subjectID: "victim-a",
            projectID: "project",
            priority: 1,
            disruptionCostBasisPoints: 2,
            budgetID: "budget-a"
        )
        let secondVictim = try SchedulerVictimAllocation(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            nodeID: node.nodeID,
            allocation: try ResourceVector(["cpu": 3]),
            subjectID: "victim-b",
            projectID: "project",
            priority: 1,
            disruptionCostBasisPoints: 3,
            budgetID: "budget-b"
        )
        let expensiveVictim = try SchedulerVictimAllocation(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            nodeID: node.nodeID,
            allocation: try ResourceVector(["cpu": 5]),
            subjectID: "victim-c",
            projectID: "project",
            priority: 1,
            disruptionCostBasisPoints: 10,
            budgetID: "budget-c"
        )
        let budgets = try [
            SchedulerDisruptionBudget(
                budgetID: "budget-a",
                projectID: "project",
                remainingVictimCount: 1,
                remainingDisruptionCostBasisPoints: 2
            ),
            SchedulerDisruptionBudget(
                budgetID: "budget-b",
                projectID: "project",
                remainingVictimCount: 1,
                remainingDisruptionCostBasisPoints: 3
            ),
            SchedulerDisruptionBudget(
                budgetID: "budget-c",
                projectID: "project",
                remainingVictimCount: 1,
                remainingDisruptionCostBasisPoints: 10
            )
        ]

        let forward = try SchedulerEngine().plan(
            makeInput(
                workloads: [workload],
                nodes: [node],
                victimAllocations: [expensiveVictim, secondVictim, firstVictim],
                disruptionBudgets: budgets,
                preemptionPolicy: try authorizedPreemptionPolicy()
            )
        )
        let reverse = try SchedulerEngine().plan(
            makeInput(
                workloads: [workload],
                nodes: [node],
                victimAllocations: [firstVictim, secondVictim, expensiveVictim],
                disruptionBudgets: Array(budgets.reversed()),
                preemptionPolicy: try authorizedPreemptionPolicy()
            )
        )

        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(
            forward.workloadDecisions[0].preemption?.victimWorkloadIDs,
            [firstVictim.workloadID, secondVictim.workloadID]
        )
        XCTAssertEqual(
            forward.workloadDecisions[0].preemption?.disruptionCostBasisPoints,
            5
        )
    }

    func testExactPreemptionFindsCheaperMultiResourceSubsetAcrossBudgets() throws {
        let node = try makeNode(
            id: "00000000-0000-0000-0000-000000000001",
            cpu: 12,
            allocation: 12,
            memory: 11,
            allocationMemory: 11
        )
        let workload = try SchedulerWorkload(
            requirements: try WorkloadPlacementRequirements(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                request: try ResourceVector(["cpu": 6, "memory": 6])
            ),
            priority: 10,
            subjectID: "subject",
            projectID: "project",
            preemptionEligibility: .eligible
        )
        let cpuVictim = try SchedulerVictimAllocation(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            nodeID: node.nodeID,
            allocation: try ResourceVector(["cpu": 6]),
            subjectID: "victim-cpu",
            projectID: "project",
            priority: 1,
            disruptionCostBasisPoints: 5,
            budgetID: "budget-a"
        )
        let memoryVictim = try SchedulerVictimAllocation(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            nodeID: node.nodeID,
            allocation: try ResourceVector(["memory": 6]),
            subjectID: "victim-memory",
            projectID: "project",
            priority: 1,
            disruptionCostBasisPoints: 5,
            budgetID: "budget-b"
        )
        let overlappingVictim = try SchedulerVictimAllocation(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            nodeID: node.nodeID,
            allocation: try ResourceVector(["cpu": 6, "memory": 5]),
            subjectID: "victim-overlap",
            projectID: "project",
            priority: 1,
            disruptionCostBasisPoints: 8,
            budgetID: "budget-c"
        )
        let budgets = try [
            SchedulerDisruptionBudget(
                budgetID: "budget-a",
                projectID: "project",
                remainingVictimCount: 1,
                remainingDisruptionCostBasisPoints: 5
            ),
            SchedulerDisruptionBudget(
                budgetID: "budget-b",
                projectID: "project",
                remainingVictimCount: 1,
                remainingDisruptionCostBasisPoints: 5
            ),
            SchedulerDisruptionBudget(
                budgetID: "budget-c",
                projectID: "project",
                remainingVictimCount: 1,
                remainingDisruptionCostBasisPoints: 8
            )
        ]

        let result = try SchedulerEngine().plan(
            makeInput(
                workloads: [workload],
                nodes: [node],
                victimAllocations: [overlappingVictim, memoryVictim, cpuVictim],
                disruptionBudgets: budgets,
                preemptionPolicy: try authorizedPreemptionPolicy()
            )
        ).workloadDecisions[0]

        XCTAssertEqual(result.outcome, .preemptionProposed)
        XCTAssertEqual(
            result.preemption?.victimWorkloadIDs,
            [cpuVictim.workloadID, memoryVictim.workloadID]
        )
        XCTAssertEqual(result.preemption?.disruptionCostBasisPoints, 10)
    }

    func testPreemptionFailsClosedWhenExactVictimBoundIsExceeded() throws {
        let node = try makeNode(
            id: "00000000-0000-0000-0000-000000000001",
            cpu: 2,
            allocation: 2
        )
        let workload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000010",
            request: 2,
            priority: 10,
            preemptionEligibility: .eligible
        )
        let victims = try (0..<2).map { offset in
            try SchedulerVictimAllocation(
                workloadID: UUID(uuidString: String(format: "00000000-0000-0000-0000-00000000001%d", offset + 1))!,
                nodeID: node.nodeID,
                allocation: try ResourceVector(["cpu": 1]),
                subjectID: "victim",
                projectID: "project",
                priority: 1,
                disruptionCostBasisPoints: 1
            )
        }
        let limits = try SchedulerEngineLimits(maxExactPreemptionVictimsPerNode: 1)
        let result = try SchedulerEngine().plan(
            makeInput(
                workloads: [workload],
                nodes: [node],
                victimAllocations: victims,
                preemptionPolicy: try authorizedPreemptionPolicy(),
                limits: limits
            )
        ).workloadDecisions[0]

        XCTAssertEqual(result.outcome, .unschedulable)
        XCTAssertNil(result.preemption)
        XCTAssertTrue(result.filterFailures.contains {
            $0.code == .preemptionSearchBoundExceeded
        })
        XCTAssertTrue(result.explanation.detailKeys.contains("preemption-search-bound-exceeded"))
    }

    func testPreemptionFailsClosedWhenExactSearchStateBudgetIsExhausted() throws {
        let node = try makeNode(
            id: "00000000-0000-0000-0000-000000000020",
            cpu: 4,
            allocation: 4
        )
        let workload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000030",
            request: 5,
            priority: 10,
            preemptionEligibility: .eligible
        )
        let victims = try [
            SchedulerVictimAllocation(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
                nodeID: node.nodeID,
                allocation: try ResourceVector(["cpu": 1]),
                subjectID: "victim-a",
                projectID: "project",
                priority: 1,
                disruptionCostBasisPoints: 1
            ),
            SchedulerVictimAllocation(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!,
                nodeID: node.nodeID,
                allocation: try ResourceVector(["cpu": 1]),
                subjectID: "victim-b",
                projectID: "project",
                priority: 1,
                disruptionCostBasisPoints: 1
            ),
            SchedulerVictimAllocation(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!,
                nodeID: node.nodeID,
                allocation: try ResourceVector(["cpu": 1]),
                subjectID: "victim-c",
                projectID: "project",
                priority: 1,
                disruptionCostBasisPoints: 1
            ),
            SchedulerVictimAllocation(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000034")!,
                nodeID: node.nodeID,
                allocation: try ResourceVector(["cpu": 1]),
                subjectID: "victim-d",
                projectID: "project",
                priority: 1,
                disruptionCostBasisPoints: 1
            )
        ]
        let limits = try SchedulerEngineLimits(
            maxExactPreemptionVictimsPerNode: 4,
            maxExactPreemptionSearchStates: 7
        )

        let forward = try SchedulerEngine().plan(
            makeInput(
                workloads: [workload],
                nodes: [node],
                victimAllocations: victims,
                preemptionPolicy: try authorizedPreemptionPolicy(),
                limits: limits
            )
        )
        let reverse = try SchedulerEngine().plan(
            makeInput(
                workloads: [workload],
                nodes: [node],
                victimAllocations: Array(victims.reversed()),
                preemptionPolicy: try authorizedPreemptionPolicy(),
                limits: limits
            )
        )
        let result = forward.workloadDecisions[0]

        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(result.outcome, .unschedulable)
        XCTAssertNil(result.preemption)
        XCTAssertTrue(result.filterFailures.contains {
            $0.code == .preemptionSearchBoundExceeded
                && $0.stableDetailKey.hasPrefix("preemption-search-bound:states:7:")
        })
    }

    func testVolumePortAndNetworkConstraintsHaveActionableReasons() throws {
        let workload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000001",
            request: 1,
            constraints: try SchedulerAdditionalPlacementConstraints(
                requiredVolumes: ["volume-a"],
                requiredPorts: [8080],
                requiredNetworks: ["network-a"]
            )
        )
        let node = try makeNode(
            id: "00000000-0000-0000-0000-000000000002",
            cpu: 2,
            volumes: [],
            ports: [],
            networks: []
        )

        let result = try SchedulerEngine().plan(
            makeInput(workloads: [workload], nodes: [node])
        ).workloadDecisions[0]

        XCTAssertEqual(result.outcome, .unschedulable)
        XCTAssertEqual(
            Set(result.filterFailures.map(\.code)),
            [.volumeUnavailable, .portUnavailable, .networkUnavailable]
        )
        XCTAssertTrue(result.explanation.detailKeys.contains("volume-unavailable"))
        XCTAssertTrue(result.explanation.detailKeys.contains("port-unavailable"))
        XCTAssertTrue(result.explanation.detailKeys.contains("network-unavailable"))
    }

    func testBorrowedUsageMustRemainExplicitlyPreemptible() throws {
        XCTAssertThrowsError(
            try SchedulerVictimAllocation(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                allocation: try ResourceVector(["cpu": 1]),
                subjectID: "victim",
                projectID: "project",
                priority: 1,
                disruptionCostBasisPoints: 1,
                preemptible: false,
                reclaimableBorrowed: true
            )
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .invalidDecision("borrowed-victim-must-be-preemptible")
            )
        }
    }

    private func makeInput(
        workloads: [SchedulerWorkload],
        nodes: [SchedulerNode],
        fairnessStates: [SchedulerFairnessState] = [],
        existingPlacements: [SchedulerExistingPlacement] = [],
        victimAllocations: [SchedulerVictimAllocation] = [],
        disruptionBudgets: [SchedulerDisruptionBudget] = [],
        antiChurnThresholdBasisPoints: Int64 = 250,
        weights: SchedulerScoreWeights = .default,
        preemptionPolicy: SchedulerPreemptionPolicy = .standard,
        queuePolicy: SchedulerQueuePolicy = .standard,
        limits: SchedulerEngineLimits = .default
    ) throws -> SchedulerEngineInput {
        try SchedulerEngineInput(
            inputDigest: nil,
            pendingWorkloads: workloads,
            nodes: nodes,
            fairnessStates: fairnessStates,
            existingPlacements: existingPlacements,
            victimAllocations: victimAllocations,
            disruptionBudgets: disruptionBudgets,
            antiChurnThresholdBasisPoints: antiChurnThresholdBasisPoints,
            scoringWeights: weights,
            preemptionPolicy: preemptionPolicy,
            queuePolicy: queuePolicy,
            limits: limits
        )
    }

    private func authorizedPreemptionPolicy() throws -> SchedulerPreemptionPolicy {
        try SchedulerPreemptionPolicy(
            preemptionAuthorized: true,
            authorizationReference: "scheduler-test-authorization"
        )
    }

    private func makeWorkload(
        id: String,
        request: Int64,
        priority: Int64 = 0,
        architecture: String = "arm64",
        subjectID: String = "subject",
        topology: SchedulerTopologyPreference = .none,
        locality: SchedulerLocalityPreference = .none,
        disruption: SchedulerDisruptionProfile = .default,
        constraints: SchedulerAdditionalPlacementConstraints = .none,
        preemptionEligibility: SchedulerWorkloadPreemptionEligibility = .nonPreempting
    ) throws -> SchedulerWorkload {
        try SchedulerWorkload(
            requirements: try WorkloadPlacementRequirements(
                workloadID: UUID(uuidString: id)!,
                request: try ResourceVector(["cpu": request]),
                requiredArchitectures: [architecture]
            ),
            priority: priority,
            subjectID: subjectID,
            projectID: "project",
            topology: topology,
            locality: locality,
            disruption: disruption,
            constraints: constraints,
            preemptionEligibility: preemptionEligibility
        )
    }

    private func makeNode(
        id: String,
        cpu: Int64,
        allocation: Int64 = 0,
        memory: Int64? = nil,
        allocationMemory: Int64? = nil,
        architecture: String = "arm64",
        topology: [String: String] = [:],
        posture: SchedulerHostPosture = SchedulerHostPosture(),
        volumes: [String] = [],
        ports: [Int] = [],
        networks: [String] = []
    ) throws -> SchedulerNode {
        try SchedulerNode(
            snapshot: try NodePlacementSnapshot(
                nodeID: UUID(uuidString: id)!,
                capacity: try ResourceVector(
                    memory.map { ["cpu": cpu, "memory": $0] } ?? ["cpu": cpu]
                ),
                allocation: try ResourceVector(
                    [
                        "cpu": allocation,
                        "memory": allocationMemory ?? 0
                    ]
                ),
                architecture: architecture,
                runtime: "linux-vm",
                provider: "provider"
            ),
            topologyDomains: topology,
            posture: posture,
            availableVolumeIDs: volumes,
            availablePorts: ports,
            availableNetworkIDs: networks
        )
    }
}
