import XCTest
import HostwrightScheduler

final class SchedulerOptimizationEquivalenceTests: XCTestCase {
    func testIndexedFairnessMatchesReferenceQueueAcrossGeneratedReordering() throws {
        for seed in 0..<32 {
            let scenario = try makeGeneratedScenario(seed: seed)
            let expected = referenceQueueOrder(
                workloads: scenario.workloads,
                fairnessStates: scenario.fairnessStates,
                nodeCapacity: 100
            )
            let forward = try SchedulerEngine().plan(scenario.input)
            let reordered = try SchedulerEngine().plan(
                try SchedulerEngineInput(
                    pendingWorkloads: Array(scenario.workloads.reversed()),
                    nodes: Array(scenario.nodes.reversed()),
                    fairnessStates: Array(scenario.fairnessStates.reversed())
                )
            )

            XCTAssertEqual(forward.orderedWorkloadIDs, expected, "seed=\(seed)")
            XCTAssertEqual(forward, reordered, "input reordering changed seed=\(seed)")
        }
    }

    func testIndexedTopologyMatchesCanonicalSpreadAndAffinityChoices() throws {
        let existingID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let pendingID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let eastID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let westID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let spread = try SchedulerTopologyPreference(
            groupID: "web",
            spreadKey: "zone"
        )
        let affinity = try SchedulerTopologyPreference(
            affinityWorkloadIDs: [existingID]
        )
        let hardSpread = try SchedulerHardTopologySpread(
            topologyKey: "zone",
            maxSkew: 1,
            groupID: "web"
        )
        let existing = try SchedulerExistingPlacement(
            workloadID: existingID,
            nodeID: eastID,
            allocation: try ResourceVector(["cpu": 1]),
            topologyGroupID: "web"
        )
        let pendingSpread = try makeWorkload(
            id: pendingID.uuidString,
            request: 1,
            topology: spread
        )
        let existingWorkload = try makeWorkload(
            id: existingID.uuidString,
            request: 1,
            topology: spread
        )
        let pendingAffinity = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000003",
            request: 1,
            topology: affinity
        )
        let pendingHardSpread = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000004",
            request: 1,
            affinity: try NodeAffinity(topologySpreads: [hardSpread])
        )
        let nodes = [
            try makeNode(id: eastID.uuidString, cpu: 4, allocation: 1, topology: ["zone": "east"]),
            try makeNode(id: westID.uuidString, cpu: 4, topology: ["zone": "west"])
        ]

        let spreadInput = try SchedulerEngineInput(
            pendingWorkloads: [existingWorkload, pendingSpread],
            nodes: nodes,
            existingPlacements: [existing]
        )
        let spreadDecision = try SchedulerEngine().plan(spreadInput)
        XCTAssertEqual(
            spreadDecision.workloadDecisions.first { $0.workloadID == pendingID }?.chosenNodeID,
            westID
        )
        XCTAssertEqual(
            spreadDecision,
            try SchedulerEngine().plan(
                SchedulerEngineInput(
                    pendingWorkloads: [existingWorkload, pendingSpread],
                    nodes: Array(nodes.reversed()),
                    existingPlacements: [existing]
                )
            )
        )

        let affinityInput = try SchedulerEngineInput(
            pendingWorkloads: [existingWorkload, pendingAffinity],
            nodes: nodes,
            existingPlacements: [existing]
        )
        let affinityDecision = try SchedulerEngine().plan(affinityInput)
        XCTAssertEqual(
            affinityDecision.workloadDecisions.first { $0.workloadID == pendingAffinity.workloadID }?.chosenNodeID,
            eastID
        )
        XCTAssertEqual(
            affinityDecision,
            try SchedulerEngine().plan(
                SchedulerEngineInput(
                    pendingWorkloads: [existingWorkload, pendingAffinity],
                    nodes: Array(nodes.reversed()),
                    existingPlacements: [existing]
                )
            )
        )

        let hardSpreadInput = try SchedulerEngineInput(
            pendingWorkloads: [existingWorkload, pendingHardSpread],
            nodes: nodes,
            existingPlacements: [existing]
        )
        let hardSpreadDecision = try SchedulerEngine().plan(hardSpreadInput)
        let reorderedHardSpreadDecision = try SchedulerEngine().plan(
            SchedulerEngineInput(
                pendingWorkloads: [pendingHardSpread, existingWorkload],
                nodes: Array(nodes.reversed()),
                existingPlacements: [existing]
            )
        )
        XCTAssertEqual(
            hardSpreadDecision.workloadDecisions.first {
                $0.workloadID == pendingHardSpread.workloadID
            }?.chosenNodeID,
            westID
        )
        XCTAssertEqual(
            hardSpreadDecision,
            reorderedHardSpreadDecision
        )
        XCTAssertEqual(
            hardSpreadDecision.workloadDecisions.first {
                $0.workloadID == pendingHardSpread.workloadID
            }?.filterFailures.map(\.orderingKey),
            reorderedHardSpreadDecision.workloadDecisions.first {
                $0.workloadID == pendingHardSpread.workloadID
            }?.filterFailures.map(\.orderingKey),
            "Hard topology filter reasons must retain canonical order under input reordering."
        )
    }

    private struct GeneratedScenario {
        let workloads: [SchedulerWorkload]
        let nodes: [SchedulerNode]
        let fairnessStates: [SchedulerFairnessState]
        let input: SchedulerEngineInput
    }

    private struct ReferenceTenant {
        var usage: Int64
        let guarantee: Int64
        let pendingDemand: Bool
        let weight: Int64
        let starvationAgeUnits: Int64
    }

    private func makeGeneratedScenario(seed: Int) throws -> GeneratedScenario {
        let nodes = try (0..<3).map { offset in
            try makeNode(
                id: String(format: "00000000-0000-0000-0000-%012x", 0x100 + offset),
                cpu: 100
            )
        }
        let workloads = try (0..<12).map { offset in
            let subject = "tenant-\((offset + seed) % 4)"
            return try makeWorkload(
                id: String(format: "00000000-0000-0000-0000-%012x", 0x1000 + seed * 32 + offset),
                request: Int64(1 + ((offset * 3 + seed) % 4)),
                priority: Int64((offset + seed) % 3),
                subjectID: subject
            )
        }
        let fairnessStates = try (0..<4).map { offset in
            try SchedulerFairnessState(
                subjectID: "tenant-\(offset)",
                projectID: "project",
                usage: try ResourceVector(["cpu": Int64((seed + offset * 2) % 12)]),
                guarantee: try ResourceVector(["cpu": Int64((offset + 1) * 3)]),
                pendingDemand: (offset + seed).isMultiple(of: 5)
                    ? try ResourceVector(["cpu": 1])
                    : .zero,
                starvationAgeUnits: Int64((seed + offset) % 4),
                weight: Int64(1 + ((seed + offset) % 3))
            )
        }
        return GeneratedScenario(
            workloads: workloads,
            nodes: nodes,
            fairnessStates: fairnessStates,
            input: try SchedulerEngineInput(
                pendingWorkloads: workloads,
                nodes: nodes,
                fairnessStates: fairnessStates
            )
        )
    }

    private func referenceQueueOrder(
        workloads: [SchedulerWorkload],
        fairnessStates: [SchedulerFairnessState],
        nodeCapacity: Int64
    ) -> [UUID] {
        var remaining = workloads
        var tenants = Dictionary(uniqueKeysWithValues: fairnessStates.map {
            ("\($0.subjectID)|\($0.projectID)", ReferenceTenant(
                usage: $0.usage["cpu"],
                guarantee: $0.guarantee["cpu"],
                pendingDemand: !$0.pendingDemand.resourceNames.isEmpty,
                weight: $0.weight,
                starvationAgeUnits: $0.starvationAgeUnits
            ))
        })
        var result: [UUID] = []
        while !remaining.isEmpty {
            let selected = remaining.min { lhs, rhs in
                referencePrecedes(lhs, rhs, tenants: tenants, nodeCapacity: nodeCapacity)
            }!
            result.append(selected.workloadID)
            remaining.removeAll { $0.workloadID == selected.workloadID }
            let key = "\(selected.subjectID)|\(selected.projectID)"
            var tenant = tenants[key] ?? ReferenceTenant(
                usage: 0,
                guarantee: 0,
                pendingDemand: false,
                weight: 1,
                starvationAgeUnits: 0
            )
            tenant.usage += selected.requirements.request["cpu"]
            tenants[key] = tenant
        }
        return result
    }

    private func referencePrecedes(
        _ lhs: SchedulerWorkload,
        _ rhs: SchedulerWorkload,
        tenants: [String: ReferenceTenant],
        nodeCapacity: Int64
    ) -> Bool {
        let lhsTenant = tenants["\(lhs.subjectID)|\(lhs.projectID)"] ?? ReferenceTenant(
            usage: 0,
            guarantee: 0,
            pendingDemand: false,
            weight: 1,
            starvationAgeUnits: 0
        )
        let rhsTenant = tenants["\(rhs.subjectID)|\(rhs.projectID)"] ?? ReferenceTenant(
            usage: 0,
            guarantee: 0,
            pendingDemand: false,
            weight: 1,
            starvationAgeUnits: 0
        )
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        let lhsShare = referenceShare(
            lhsTenant,
            key: "\(lhs.subjectID)|\(lhs.projectID)",
            tenants: tenants,
            nodeCapacity: nodeCapacity
        )
        let rhsShare = referenceShare(
            rhsTenant,
            key: "\(rhs.subjectID)|\(rhs.projectID)",
            tenants: tenants,
            nodeCapacity: nodeCapacity
        )
        if lhsShare != rhsShare {
            return lhsShare < rhsShare
        }
        if lhsTenant.starvationAgeUnits != rhsTenant.starvationAgeUnits {
            return lhsTenant.starvationAgeUnits > rhsTenant.starvationAgeUnits
        }
        let lhsRequest = lhs.requirements.request["cpu"]
        let rhsRequest = rhs.requirements.request["cpu"]
        if lhsRequest != rhsRequest {
            return lhsRequest > rhsRequest
        }
        return SchedulerOrdering.uuidKey(lhs.workloadID) < SchedulerOrdering.uuidKey(rhs.workloadID)
    }

    private func referenceShare(
        _ tenant: ReferenceTenant,
        key: String,
        tenants: [String: ReferenceTenant],
        nodeCapacity: Int64
    ) -> Int64 {
        let projected = min(10_000, tenant.usage * 10_000 / nodeCapacity)
        let guarantee = min(10_000, tenant.guarantee * 10_000 / nodeCapacity)
        let unusedGuarantee = tenants.reduce(Int64(0)) { total, entry in
            guard entry.key != key else { return total }
            let other = entry.value
            guard !other.pendingDemand else { return total }
            let usage = min(10_000, other.usage * 10_000 / nodeCapacity)
            let guarantee = min(10_000, other.guarantee * 10_000 / nodeCapacity)
            return total + max(0, guarantee - usage)
        }
        let effective = projected - min(max(0, projected - guarantee), unusedGuarantee)
        return (effective + tenant.weight - 1) / tenant.weight
    }

    private func makeWorkload(
        id: String,
        request: Int64,
        priority: Int64 = 0,
        subjectID: String = "subject",
        topology: SchedulerTopologyPreference = .none,
        affinity: NodeAffinity = .none
    ) throws -> SchedulerWorkload {
        try SchedulerWorkload(
            requirements: try WorkloadPlacementRequirements(
                workloadID: UUID(uuidString: id)!,
                request: try ResourceVector(["cpu": request]),
                requiredArchitectures: ["arm64"],
                affinity: affinity
            ),
            priority: priority,
            subjectID: subjectID,
            projectID: "project",
            topology: topology
        )
    }

    private func makeNode(
        id: String,
        cpu: Int64,
        allocation: Int64 = 0,
        topology: [String: String] = [:]
    ) throws -> SchedulerNode {
        try SchedulerNode(
            snapshot: try NodePlacementSnapshot(
                nodeID: UUID(uuidString: id)!,
                capacity: try ResourceVector(["cpu": cpu]),
                allocation: try ResourceVector(["cpu": allocation]),
                architecture: "arm64",
                runtime: "linux-vm",
                provider: "provider"
            ),
            topologyDomains: topology
        )
    }
}
