import XCTest
@testable import HostwrightScheduler

final class HardPlacementFiltersTests: XCTestCase {
    func testAllHardFiltersProduceStableBlockingReasons() throws {
        let workload = try makeWorkload(
            request: ["cpu": 4],
            requiredArchitectures: ["arm64"],
            requiredRuntime: "linux-vm",
            requiredProvider: "provider-a",
            requiredCapabilities: ["network", "storage"],
            affinity: try NodeAffinity(
                requiredLabels: ["zone": "east"],
                forbiddenLabels: ["tier": "batch"]
            ),
            tolerations: [],
            accelerators: ["metal.gpu": 2]
        )
        let node = try makeNode(
            id: "00000000-0000-0000-0000-000000000010",
            capacity: ["cpu": 4],
            allocation: ["cpu": 2],
            architecture: "x86_64",
            runtime: "other-runtime",
            provider: "provider-b",
            capabilities: ["network"],
            health: .degraded,
            maintenance: .draining,
            labels: ["zone": "west", "tier": "batch"],
            taints: [
                try NodeTaint(key: "dedicated", value: "batch", effect: .noSchedule)
            ],
            accelerators: ["metal.gpu": 1]
        )

        let result = HardPlacementFilterEvaluator().evaluate(
            workload: workload,
            on: node
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(
            result.reasons.map(\.code),
            [
                .insufficientCapacity,
                .architectureMismatch,
                .runtimeMismatch,
                .providerMismatch,
                .missingCapability,
                .nodeNotHealthy,
                .nodeUnavailableForMaintenance,
                .requiredLabelMismatch,
                .forbiddenLabelPresent,
                .untoleratedTaint,
                .acceleratorUnavailable
            ]
        )
        XCTAssertEqual(
            result.reasons.map(\.filter),
            [
                .capacity,
                .architecture,
                .runtimeProvider,
                .runtimeProvider,
                .capabilities,
                .healthMaintenance,
                .healthMaintenance,
                .labelsAffinity,
                .labelsAffinity,
                .taintsTolerations,
                .acceleratorAvailability
            ]
        )
        XCTAssertEqual(
            result.reasons,
            result.reasons.sorted { $0.orderingKey < $1.orderingKey }
        )
    }

    func testMatchingNodePassesEveryHardFilter() throws {
        let toleration = try PlacementToleration(
            key: "dedicated",
            value: "batch",
            effect: .noSchedule,
            matching: .equals
        )
        let workload = try makeWorkload(
            request: ["cpu": 2],
            requiredArchitectures: ["arm64"],
            requiredRuntime: "linux-vm",
            requiredProvider: "provider-a",
            requiredCapabilities: ["network", "storage"],
            affinity: try NodeAffinity(
                requiredLabels: ["zone": "east"],
                forbiddenLabels: ["tier": "batch"]
            ),
            tolerations: [toleration],
            accelerators: ["metal.gpu": 1]
        )
        let node = try makeNode(
            id: "00000000-0000-0000-0000-000000000011",
            capacity: ["cpu": 4],
            allocation: ["cpu": 1],
            architecture: "arm64",
            runtime: "linux-vm",
            provider: "provider-a",
            capabilities: ["storage", "network"],
            health: .healthy,
            maintenance: .available,
            labels: ["zone": "east", "tier": "service"],
            taints: [
                try NodeTaint(key: "dedicated", value: "batch", effect: .noSchedule)
            ],
            accelerators: ["metal.gpu": 1]
        )

        let result = HardPlacementFilterEvaluator().evaluate(
            workload: workload,
            on: node
        )

        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.reasons.isEmpty)
    }

    func testNodesAreReturnedInStableUUIDOrderRegardlessOfInputOrder() throws {
        let workload = try makeWorkload(request: ["cpu": 1])
        let first = try makeNode(
            id: "00000000-0000-0000-0000-000000000020",
            capacity: ["cpu": 2]
        )
        let second = try makeNode(
            id: "00000000-0000-0000-0000-000000000001",
            capacity: ["cpu": 2]
        )
        let evaluator = HardPlacementFilterEvaluator()

        let forward = evaluator.evaluate(
            workload: workload,
            against: [first, second]
        )
        let reverse = evaluator.evaluate(
            workload: workload,
            against: [second, first]
        )

        XCTAssertEqual(
            forward.map(\.nodeID),
            [second.nodeID, first.nodeID]
        )
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(
            forward.map(\.orderingKey),
            forward.map(\.orderingKey).sorted()
        )
    }

    func testHealthMaintenanceAndAcceleratorFiltersRemainIndependent() throws {
        let workload = try makeWorkload(
            request: ["cpu": 1],
            accelerators: ["ane": 1]
        )
        let node = try makeNode(
            id: "00000000-0000-0000-0000-000000000030",
            capacity: ["cpu": 2],
            health: .healthy,
            maintenance: .available,
            accelerators: [:]
        )

        let result = HardPlacementFilterEvaluator().evaluate(
            workload: workload,
            on: node
        )

        XCTAssertTrue(result.passed == false)
        XCTAssertEqual(result.reasons.map(\.filter), [.acceleratorAvailability])
        XCTAssertEqual(result.reasons.first?.code, .acceleratorUnavailable)
    }

    private func makeWorkload(
        request: [String: Int64],
        requiredArchitectures: [String] = [],
        requiredRuntime: String? = nil,
        requiredProvider: String? = nil,
        requiredCapabilities: [String] = [],
        affinity: NodeAffinity = .none,
        tolerations: [PlacementToleration] = [],
        accelerators: [String: Int64] = [:]
    ) throws -> WorkloadPlacementRequirements {
        try WorkloadPlacementRequirements(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
            resources: WorkloadResourceSnapshot(
                request: ResourceVector(request)
            ),
            requiredArchitectures: requiredArchitectures,
            requiredRuntime: requiredRuntime,
            requiredProvider: requiredProvider,
            requiredCapabilities: requiredCapabilities,
            affinity: affinity,
            tolerations: tolerations,
            acceleratorRequirements: ResourceVector(accelerators)
        )
    }

    private func makeNode(
        id: String,
        capacity: [String: Int64],
        allocation: [String: Int64] = [:],
        architecture: String = "arm64",
        runtime: String = "linux-vm",
        provider: String = "provider-a",
        capabilities: [String] = [],
        health: SchedulerNodeHealth = .healthy,
        maintenance: SchedulerNodeMaintenance = .available,
        labels: [String: String] = [:],
        taints: [NodeTaint] = [],
        accelerators: [String: Int64] = [:]
    ) throws -> NodePlacementSnapshot {
        try NodePlacementSnapshot(
            resources: NodeResourceSnapshot(
                nodeID: UUID(uuidString: id)!,
                capacity: ResourceVector(capacity),
                allocation: ResourceVector(allocation)
            ),
            architecture: architecture,
            runtime: runtime,
            provider: provider,
            capabilities: capabilities,
            health: health,
            maintenance: maintenance,
            labels: labels,
            taints: taints,
            acceleratorAvailability: ResourceVector(accelerators)
        )
    }
}
