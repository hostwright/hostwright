import XCTest
@testable import HostwrightScheduler

final class SchedulerContractsTests: XCTestCase {
    func testWorkloadRequestAndLimitAreImmutableAndValidated() throws {
        let request = try ResourceVector(["cpu": 2, "memory": 1_024])
        let limit = try ResourceVector(["cpu": 4, "memory": 2_048])
        let snapshot = try WorkloadResourceSnapshot(
            request: request,
            limit: limit
        )

        XCTAssertEqual(snapshot.request, request)
        XCTAssertEqual(snapshot.limit, limit)
        XCTAssertEqual(snapshot.requestedResources, request)

        let invalidLimit = try ResourceVector(["cpu": 1])
        XCTAssertThrowsError(
            try WorkloadResourceSnapshot(request: request, limit: invalidLimit)
        ) { error in
            XCTAssertEqual(
                error as? SchedulerValidationError,
                .limitBelowRequest(resource: "cpu")
            )
        }
    }

    func testNodeResourceSnapshotDerivesAvailableCapacity() throws {
        let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let capacity = try ResourceVector(["cpu": 8, "memory": 16_384])
        let allocation = try ResourceVector(["cpu": 3, "memory": 4_096])
        let snapshot = try NodeResourceSnapshot(
            nodeID: nodeID,
            capacity: capacity,
            allocation: allocation
        )

        XCTAssertEqual(snapshot.nodeID, nodeID)
        XCTAssertEqual(snapshot.capacity, capacity)
        XCTAssertEqual(snapshot.allocation, allocation)
        XCTAssertEqual(
            snapshot.available,
            try ResourceVector(["cpu": 5, "memory": 12_288])
        )

        let invalidAllocation = try ResourceVector(["cpu": 9])
        XCTAssertThrowsError(
            try NodeResourceSnapshot(
                nodeID: nodeID,
                capacity: capacity,
                allocation: invalidAllocation
            )
        ) { error in
            XCTAssertEqual(
                error as? SchedulerValidationError,
                .allocationExceedsCapacity(resource: "cpu")
            )
        }
    }

    func testPlacementRequirementsCanonicalizeCapabilitiesArchitecturesAndAffinity() throws {
        let resources = try WorkloadResourceSnapshot(
            request: ResourceVector(["cpu": 1])
        )
        let affinity = try NodeAffinity(
            requiredLabels: ["zone": "east"],
            forbiddenLabels: ["tier": "batch"]
        )
        let toleration = try PlacementToleration(
            key: "dedicated",
            value: "batch",
            effect: .noSchedule,
            matching: .equals
        )
        let requirements = try WorkloadPlacementRequirements(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            resources: resources,
            requiredArchitectures: ["x86_64", "arm64", "arm64"],
            requiredRuntime: "linux-vm",
            requiredProvider: "provider-b",
            requiredCapabilities: ["network", "storage", "network"],
            affinity: affinity,
            tolerations: [toleration],
            acceleratorRequirements: ResourceVector(["metal.gpu": 1])
        )

        XCTAssertEqual(requirements.requiredArchitectures, ["arm64", "x86_64"])
        XCTAssertEqual(requirements.requiredCapabilities, ["network", "storage"])
        XCTAssertEqual(requirements.requiredRuntime, "linux-vm")
        XCTAssertEqual(requirements.requiredProvider, "provider-b")
        XCTAssertEqual(requirements.request, resources.request)
        XCTAssertEqual(requirements.limit, nil)
        XCTAssertEqual(requirements.affinity.requiredLabels, ["zone": "east"])
    }

    func testInvalidAffinityAndTolerationAreStable() throws {
        XCTAssertThrowsError(
            try NodeAffinity(
                requiredLabels: ["zone": "east"],
                forbiddenLabels: ["zone": "east"]
            )
        ) { error in
            XCTAssertEqual(
                error as? SchedulerValidationError,
                .invalidAffinity("conflicting-label:zone")
            )
        }

        XCTAssertThrowsError(
            try PlacementToleration(
                key: "dedicated",
                value: "batch",
                effect: .noSchedule,
                matching: .exists
            )
        ) { error in
            XCTAssertEqual(
                error as? SchedulerValidationError,
                .invalidToleration("exists-requires-no-value")
            )
        }
    }

    func testNodeSnapshotCodableRoundTripPreservesDerivedAvailability() throws {
        let resources = try NodeResourceSnapshot(
            nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            capacity: ResourceVector(["cpu": 4]),
            allocation: ResourceVector(["cpu": 1])
        )
        let node = try NodePlacementSnapshot(
            resources: resources,
            architecture: "arm64",
            runtime: "linux-vm",
            provider: "provider-a",
            capabilities: ["network"],
            health: .healthy,
            maintenance: .available,
            labels: ["zone": "east"],
            taints: [],
            acceleratorAvailability: ResourceVector(["metal.gpu": 1])
        )

        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(NodePlacementSnapshot.self, from: data)
        XCTAssertEqual(decoded, node)
        XCTAssertEqual(decoded.available, try ResourceVector(["cpu": 3]))
    }
}
