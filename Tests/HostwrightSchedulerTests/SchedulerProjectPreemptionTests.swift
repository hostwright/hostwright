import Foundation
import XCTest
@testable import HostwrightScheduler

final class SchedulerProjectPreemptionTests: XCTestCase {
    func testVictimAllocationConstructorCarriesRequiredSubjectAndProjectIDs() throws {
        let victim = try makeVictim(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            projectID: "project-a",
            budgetID: "budget-a"
        )

        XCTAssertEqual(victim.subjectID, "victim-subject")
        XCTAssertEqual(victim.projectID, "project-a")
    }

    func testVictimAllocationCodableRequiresSubjectIDAndProjectID() throws {
        let victim = try makeVictim(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            projectID: "project-a",
            budgetID: "budget-a"
        )

        let decoded = try JSONDecoder().decode(
            SchedulerVictimAllocation.self,
            from: JSONEncoder().encode(victim)
        )
        XCTAssertEqual(decoded, victim)

        for key in ["subjectID", "projectID"] {
            let data = try jsonDataRemovingKey(key, from: victim)
            XCTAssertThrowsError(
                try JSONDecoder().decode(SchedulerVictimAllocation.self, from: data),
                "Decoding a victim without \(key) must fail"
            )
        }
    }

    func testDisruptionBudgetConstructorCarriesProjectIDAndCodableRequiresIt() throws {
        let budget = try SchedulerDisruptionBudget(
            budgetID: "budget-a",
            projectID: "project-a",
            remainingVictimCount: 1,
            remainingDisruptionCostBasisPoints: 10
        )

        XCTAssertEqual(budget.projectID, "project-a")
        let decoded = try JSONDecoder().decode(
            SchedulerDisruptionBudget.self,
            from: JSONEncoder().encode(budget)
        )
        XCTAssertEqual(decoded, budget)

        let data = try jsonDataRemovingKey("projectID", from: budget)
        XCTAssertThrowsError(
            try JSONDecoder().decode(SchedulerDisruptionBudget.self, from: data)
        )
    }

    func testEngineRejectsVictimWithMissingBudgetProjectReference() throws {
        let victim = try makeVictim(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            projectID: "project-a",
            budgetID: "missing-budget"
        )

        XCTAssertThrowsError(
            try makeInput(victims: [victim])
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .unknownStringReference(field: "victim-budget", value: "missing-budget")
            )
        }
    }

    func testEngineRejectsVictimWhenBudgetProjectDoesNotMatch() throws {
        let victim = try makeVictim(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            projectID: "project-a",
            budgetID: "budget-a"
        )
        let budget = try makeBudget(budgetID: "budget-a", projectID: "project-b")

        XCTAssertThrowsError(
            try makeInput(victims: [victim], budgets: [budget])
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .invalidDecision("victim-budget-project-mismatch")
            )
        }
    }

    func testEngineRejectsAmbiguousBudgetProjectAssociation() throws {
        let budgets = try [
            makeBudget(budgetID: "budget-a", projectID: "project-a"),
            makeBudget(budgetID: "budget-a", projectID: "project-b")
        ]

        XCTAssertThrowsError(
            try makeInput(budgets: budgets)
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .invalidDecision("disruption-budget-project-ambiguous")
            )
        }
    }

    func testEngineCanonicalizesVictimAndBudgetOrderWithoutChangingDigest() throws {
        let firstVictim = try makeVictim(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            projectID: "project-a",
            budgetID: "budget-b"
        )
        let secondVictim = try makeVictim(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            projectID: "project-a",
            budgetID: "budget-a"
        )
        let firstBudget = try makeBudget(budgetID: "budget-b", projectID: "project-a")
        let secondBudget = try makeBudget(budgetID: "budget-a", projectID: "project-a")

        let forward = try makeInput(
            victims: [firstVictim, secondVictim],
            budgets: [firstBudget, secondBudget]
        )
        let reversed = try makeInput(
            victims: [secondVictim, firstVictim],
            budgets: [secondBudget, firstBudget]
        )

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.inputDigest, reversed.inputDigest)
        XCTAssertEqual(
            forward.victimAllocations.map(\.workloadID),
            [secondVictim.workloadID, firstVictim.workloadID]
        )
        XCTAssertEqual(
            forward.disruptionBudgets.map(\.budgetID),
            [secondBudget.budgetID, firstBudget.budgetID]
        )
    }

    func testEngineDigestBindsVictimAndBudgetProjectIDs() throws {
        let projectAVictim = try makeVictim(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            projectID: "project-a",
            budgetID: "budget-a"
        )
        let projectBVictim = try makeVictim(
            workloadID: projectAVictim.workloadID,
            projectID: "project-b",
            budgetID: "budget-a"
        )
        let projectAInput = try makeInput(
            victims: [projectAVictim],
            budgets: [try makeBudget(budgetID: "budget-a", projectID: "project-a")]
        )
        let projectBInput = try makeInput(
            victims: [projectBVictim],
            budgets: [try makeBudget(budgetID: "budget-a", projectID: "project-b")]
        )

        XCTAssertNotEqual(projectAInput.inputDigest, projectBInput.inputDigest)
    }

    private func makeInput(
        victims: [SchedulerVictimAllocation] = [],
        budgets: [SchedulerDisruptionBudget] = []
    ) throws -> SchedulerEngineInput {
        try SchedulerEngineInput(
            inputDigest: nil,
            pendingWorkloads: [makeWorkload()],
            nodes: [makeNode()],
            victimAllocations: victims,
            disruptionBudgets: budgets
        )
    }

    private func makeWorkload() throws -> SchedulerWorkload {
        try SchedulerWorkload(
            requirements: try WorkloadPlacementRequirements(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                request: try ResourceVector(["cpu": 1]),
                requiredArchitectures: ["arm64"]
            ),
            priority: 10,
            subjectID: "requester",
            projectID: "project-a"
        )
    }

    private func makeNode() throws -> SchedulerNode {
        try SchedulerNode(
            snapshot: try NodePlacementSnapshot(
                nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                capacity: try ResourceVector(["cpu": 4]),
                allocation: try ResourceVector(["cpu": 4]),
                architecture: "arm64",
                runtime: "linux-vm",
                provider: "provider"
            )
        )
    }

    private func makeVictim(
        workloadID: UUID,
        projectID: String,
        budgetID: String?
    ) throws -> SchedulerVictimAllocation {
        try SchedulerVictimAllocation(
            workloadID: workloadID,
            nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            allocation: try ResourceVector(["cpu": 1]),
            subjectID: "victim-subject",
            projectID: projectID,
            priority: 1,
            disruptionCostBasisPoints: 1,
            budgetID: budgetID
        )
    }

    private func makeBudget(
        budgetID: String,
        projectID: String
    ) throws -> SchedulerDisruptionBudget {
        try SchedulerDisruptionBudget(
            budgetID: budgetID,
            projectID: projectID,
            remainingVictimCount: 1,
            remainingDisruptionCostBasisPoints: 10
        )
    }

    private func jsonDataRemovingKey<T: Encodable>(
        _ key: String,
        from value: T
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
        object.removeValue(forKey: key)
        return try JSONSerialization.data(withJSONObject: object)
    }
}
