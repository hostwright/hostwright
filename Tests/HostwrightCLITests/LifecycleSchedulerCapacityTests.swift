import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightScheduler
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class LifecycleSchedulerCapacityTests: XCTestCase {
    private let project = "00000000-0000-0000-0000-0000000000a1"
    private let mib: Int64 = 1_024 * 1_024

    func testSDKAllocationChargesVMOverheadAndKeepsServiceRequestSeparate() throws {
        let service = try workload()
        let sdk = try LifecycleSchedulerWorkloads.providerWorkload(service, providerID: .appleContainerization)
        XCTAssertEqual(sdk.request, service.request)
        XCTAssertEqual(try sdk.capacityCharge(), try ResourceVector(["cpu": 2, "memory": 640 * mib]))
        XCTAssertEqual(try LifecycleSchedulerWorkloads.providerWorkload(sdk, providerID: .appleContainerization), sdk)
        XCTAssertEqual(try LifecycleSchedulerWorkloads.providerWorkload(service, providerID: .appleContainerCLI), service)
        XCTAssertEqual(try service.capacityCharge(), try ResourceVector(["cpu": 1, "memory": 512 * mib]))
    }

    func testSDKBatchAndExistingReservationCannotOverAdmitAndExplanationMatches() throws {
        let sdk = try LifecycleSchedulerWorkloads.providerWorkload(workload(), providerID: .appleContainerization)
        let sibling = try LifecycleSchedulerWorkloads.bind(
            workload: sdk, workloadID: UUID(), subjectID: "owner", projectID: project
        )
        let capacity = try sdk.capacityCharge()
        let nodeID = UUID()
        func node(allocation: ResourceVector) throws -> SchedulerNode {
            try SchedulerNode(snapshot: NodePlacementSnapshot(
                nodeID: nodeID, capacity: capacity, allocation: allocation,
                architecture: "arm64", runtime: "linux-vm", provider: RuntimeProviderID.appleContainerization.rawValue
            ))
        }
        let decision = try SchedulerEngine().plan(SchedulerEngineInput(
            pendingWorkloads: [sdk, sibling], nodes: [node(allocation: .zero)]
        ))
        XCTAssertEqual(decision.workloadDecisions.filter { $0.outcome == .placed }.count, 1)
        XCTAssertEqual(decision.workloadDecisions.filter { $0.outcome == .unschedulable }.count, 1)
        let explanation = try XCTUnwrap(decision.workloadDecisions.first?.capacityExplanation)
        XCTAssertEqual(explanation.rawRequest, sdk.request)
        XCTAssertEqual(explanation.overhead, sdk.overhead)
        XCTAssertEqual(explanation.chargedCapacity, capacity)
        let occupied = try SchedulerEngine().plan(SchedulerEngineInput(
            pendingWorkloads: [sibling], nodes: [node(allocation: capacity)]
        ))
        XCTAssertEqual(occupied.workloadDecisions.first?.outcome, .unschedulable)
    }

    func testRebindAndDurableDecisionReloadPreserveOverheadSafetyAndCharge() throws {
        let ownership = try SchedulerRuntimeOwnershipBinding(
            resourceIdentifier: RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier,
            resourceType: "container", resourceUUID: UUID().uuidString, resourceGeneration: 1,
            projectUUID: project, projectName: "demo", projectGeneration: 1,
            serviceName: "api", instanceName: nil, identityVersion: RuntimeManagedResourceIdentity.currentVersion,
            providerID: .appleContainerization, providerAPIVersion: HostwrightContractVersions.runtimeProviderAPI,
            providerVersion: "0.0.2-dev", providerGeneration: 1, fencingToken: UUID().uuidString
        )
        let sdk = try LifecycleSchedulerWorkloads.providerWorkload(
            workload(safety: ResourceVector(["memory": mib])), providerID: .appleContainerization
        )
        let bound = try LifecycleSchedulerWorkloads.bind(
            workload: sdk, workloadID: ownership.lifecycleWorkloadID, subjectID: "owner", projectID: project
        )
        XCTAssertEqual(bound.overhead, sdk.overhead)
        XCTAssertEqual(bound.safetyMargin, sdk.safetyMargin)
        XCTAssertEqual(bound.locality, sdk.locality)
        XCTAssertEqual(bound.disruption, sdk.disruption)
        XCTAssertEqual(bound.constraints, sdk.constraints)
        XCTAssertEqual(bound.binClass, sdk.binClass)
        XCTAssertEqual(bound.preemptionEligibility, sdk.preemptionEligibility)
        func binding(resources: ResourceVector) throws -> SchedulerDecisionWorkloadBinding {
            try SchedulerDecisionWorkloadBinding(
                workloadID: bound.workloadID, nodeID: UUID(), resources: resources,
                capacityDigest: String(repeating: "a", count: 64), capacityGeneration: 1,
                ownerSubjectID: "owner", projectUUID: project, runtimeOwnership: ownership, lifecycleWorkload: bound
            )
        }
        XCTAssertThrowsError(try binding(resources: bound.request))
        let original = try binding(resources: bound.capacityCharge())
        let restored = try JSONDecoder().decode(SchedulerDecisionWorkloadBinding.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.resources, try ResourceVector(["cpu": 2, "memory": 641 * mib]))
    }

    func testSharedCapacityChargeMatchesEngineLimitOvercommitAndCheckedOverflow() throws {
        let workload = try SchedulerWorkload(
            requirements: WorkloadPlacementRequirements(
                workloadID: UUID(), request: ResourceVector(["cpu": 1, "memory": 128 * mib]),
                limit: ResourceVector(["cpu": 4, "memory": 512 * mib])
            ), priority: 0, subjectID: "owner", projectID: project,
            overhead: ResourceVector(["cpu": 1, "memory": 128 * mib]),
            safetyMargin: ResourceVector(["memory": mib])
        )
        let ratios = ["cpu": try SchedulerResourceRatio(numerator: 2, denominator: 1)]
        let charge = try workload.capacityCharge(overcommitRatios: ratios)
        XCTAssertEqual(charge, try ResourceVector(["cpu": 3, "memory": 641 * mib]))
        let decision = try SchedulerEngine().plan(SchedulerEngineInput(
            pendingWorkloads: [workload], nodes: [SchedulerNode(snapshot: NodePlacementSnapshot(
                nodeID: UUID(), capacity: charge, allocation: .zero,
                architecture: "arm64", runtime: "linux-vm", provider: RuntimeProviderID.appleContainerization.rawValue
            ))], overcommitRatios: ratios
        ))
        XCTAssertEqual(decision.workloadDecisions.first?.outcome, .placed)
        XCTAssertEqual(decision.workloadDecisions.first?.capacityExplanation?.chargedCapacity, charge)
        let overflowing = try SchedulerWorkload(
            requirements: WorkloadPlacementRequirements(workloadID: UUID(), request: ResourceVector(["cpu": Int64.max])),
            priority: 0, subjectID: "owner", projectID: project, overhead: ResourceVector(["cpu": 1])
        )
        XCTAssertThrowsError(try overflowing.capacityCharge())
    }

    private func workload(safety: ResourceVector = .zero) throws -> SchedulerWorkload {
        try SchedulerWorkload(
            requirements: WorkloadPlacementRequirements(
                workloadID: UUID(), request: ResourceVector(["cpu": 1, "memory": 512 * mib])
            ), priority: 0, subjectID: "owner", projectID: project, safetyMargin: safety
        )
    }
}
