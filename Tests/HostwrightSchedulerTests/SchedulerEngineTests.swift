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
