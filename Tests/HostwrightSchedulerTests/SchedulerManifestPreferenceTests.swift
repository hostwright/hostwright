import XCTest
@testable import HostwrightScheduler

final class SchedulerManifestPreferenceTests: XCTestCase {
    func testWeightedPreferredSelectorsPreserveOperatorsAndAffectTopologyScore() throws {
        let eastSelector = try SchedulerLabelSelector(
            key: "zone",
            operator: .equals,
            values: ["east"]
        )
        let westSelector = try SchedulerLabelSelector(
            key: "zone",
            operator: .notEquals,
            values: ["east"]
        )
        let affinity = try SchedulerWeightedLabelSelectorPreference(
            weight: 10,
            selector: eastSelector
        )
        let antiAffinity = try SchedulerWeightedLabelSelectorPreference(
            weight: 2,
            selector: westSelector
        )
        let topology = try SchedulerTopologyPreference(
            preferredAffinity: [affinity],
            preferredAntiAffinity: [antiAffinity]
        )
        let workload = try SchedulerWorkload(
            requirements: try WorkloadPlacementRequirements(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                request: try ResourceVector(["cpu": 1])
            ),
            priority: 1,
            subjectID: "subject",
            projectID: "project",
            topology: topology
        )
        let east = try node(
            "00000000-0000-0000-0000-000000000001",
            labels: ["zone": "east"]
        )
        let west = try node(
            "00000000-0000-0000-0000-000000000002",
            labels: ["zone": "west"]
        )
        let input = try SchedulerEngineInput(
            inputDigest: nil,
            pendingWorkloads: [workload],
            nodes: [west, east],
            scoringWeights: try SchedulerScoreWeights(
                fragmentation: 0,
                fairness: 0,
                topology: 1,
                locality: 0,
                hostPressureEnergy: 0,
                disruption: 0
            )
        )

        let decision = try SchedulerEngine().plan(input).workloadDecisions[0]
        XCTAssertEqual(decision.chosenNodeID, east.nodeID)
        XCTAssertTrue(decision.explanation.detailKeys.contains {
            $0.hasPrefix("preferred-affinity:") && $0.contains("equals")
        })
        XCTAssertTrue(decision.explanation.detailKeys.contains {
            $0.hasPrefix("preferred-anti-affinity:") && $0.contains("not-equals")
        })

        let encoded = try JSONEncoder().encode(topology)
        let decoded = try JSONDecoder().decode(
            SchedulerTopologyPreference.self,
            from: encoded
        )
        XCTAssertEqual(decoded, topology)
        XCTAssertEqual(decoded.preferredAffinity[0].selector, eastSelector)
        XCTAssertEqual(decoded.preferredAntiAffinity[0].selector, westSelector)
    }

    func testPreferredSelectorInputOrderAndDuplicateSelectorsAreDeterministic() throws {
        let first = try SchedulerWeightedLabelSelectorPreference(
            weight: 2,
            selector: try SchedulerLabelSelector(
                key: "rack",
                operator: .in,
                values: ["b", "a"]
            )
        )
        let second = try SchedulerWeightedLabelSelectorPreference(
            weight: 5,
            selector: try SchedulerLabelSelector(
                key: "zone",
                operator: .doesNotExist
            )
        )
        let lhs = try SchedulerTopologyPreference(preferredAffinity: [first, second])
        let rhs = try SchedulerTopologyPreference(preferredAffinity: [second, first])
        XCTAssertEqual(lhs, rhs)

        XCTAssertThrowsError(
            try SchedulerTopologyPreference(preferredAffinity: [first, first])
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .duplicateIdentifier(field: "preferred-selector")
            )
        }
    }

    func testPreemptionRequiresWorkloadOptInAndDaemonAuthorization() throws {
        let node = try node(
            "00000000-0000-0000-0000-000000000020",
            allocation: 2
        )
        let victim = try SchedulerVictimAllocation(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            nodeID: node.nodeID,
            allocation: try ResourceVector(["cpu": 2]),
            subjectID: "victim",
            projectID: "project",
            priority: -1,
            disruptionCostBasisPoints: 1,
            budgetID: "budget"
        )
        let budget = try SchedulerDisruptionBudget(
            budgetID: "budget",
            projectID: "project",
            remainingVictimCount: 1,
            remainingDisruptionCostBasisPoints: 1
        )

        let nonPreempting = try workload(
            "00000000-0000-0000-0000-000000000022",
            eligibility: .nonPreempting
        )
        let blocked = try SchedulerEngine().plan(
            try SchedulerEngineInput(
                inputDigest: nil,
                pendingWorkloads: [nonPreempting],
                nodes: [node],
                victimAllocations: [victim],
                disruptionBudgets: [budget]
            )
        ).workloadDecisions[0]
        XCTAssertEqual(blocked.outcome, .unschedulable)
        XCTAssertTrue(blocked.filterFailures.contains {
            $0.code == .preemptionWorkloadNotEligible
        })

        let authorizedWorkload = try workload(
            "00000000-0000-0000-0000-000000000023",
            eligibility: .eligible
        )
        let unauthorized = try SchedulerEngine().plan(
            try SchedulerEngineInput(
                inputDigest: nil,
                pendingWorkloads: [authorizedWorkload],
                nodes: [node],
                victimAllocations: [victim],
                disruptionBudgets: [budget],
                preemptionPolicy: try SchedulerPreemptionPolicy(
                    preemptionAuthorized: false
                )
            )
        ).workloadDecisions[0]
        XCTAssertEqual(unauthorized.outcome, .unschedulable)
        XCTAssertTrue(unauthorized.filterFailures.contains {
            $0.code == .preemptionAuthorizationRequired
        })
    }

    func testSignedPriorityRangeMatchesManifestContract() throws {
        _ = try workload(
            "00000000-0000-0000-0000-000000000030",
            priority: -1_000_000
        )
        _ = try workload(
            "00000000-0000-0000-0000-000000000031",
            priority: 1_000_000
        )
        XCTAssertThrowsError(
            try workload(
                "00000000-0000-0000-0000-000000000032",
                priority: -1_000_001
            )
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .invalidValue(field: "workload-priority", value: -1_000_001)
            )
        }
    }

    private func workload(
        _ id: String,
        priority: Int64 = 10,
        eligibility: SchedulerWorkloadPreemptionEligibility = .nonPreempting
    ) throws -> SchedulerWorkload {
        try SchedulerWorkload(
            requirements: try WorkloadPlacementRequirements(
                workloadID: UUID(uuidString: id)!,
                request: try ResourceVector(["cpu": 2])
            ),
            priority: priority,
            subjectID: "subject",
            projectID: "project",
            preemptionEligibility: eligibility
        )
    }

    private func node(
        _ id: String,
        allocation: Int64 = 0,
        labels: [String: String] = [:]
    ) throws -> SchedulerNode {
        try SchedulerNode(
            snapshot: try NodePlacementSnapshot(
                nodeID: UUID(uuidString: id)!,
                capacity: try ResourceVector(["cpu": 2]),
                allocation: try ResourceVector(["cpu": allocation]),
                architecture: "arm64",
                runtime: "linux-vm",
                provider: "provider",
                labels: labels
            )
        )
    }
}
