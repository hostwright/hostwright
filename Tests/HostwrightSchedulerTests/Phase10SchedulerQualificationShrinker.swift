import Foundation
import HostwrightScheduler

enum Phase10SchedulerQualificationShrinker {
    static func minimize(
        _ scenario: Phase10SchedulerQualification.Scenario,
        preserving kind: Phase10SchedulerQualification.IssueKind
    ) throws -> Phase10SchedulerQualification.Scenario {
        var current = scenario

        func preserves(_ candidate: Phase10SchedulerQualification.Scenario) -> Bool {
            Phase10SchedulerQualificationVerifier.evaluate(candidate).issues.contains {
                $0.kind == kind
            }
        }

        for workload in current.input.pendingWorkloads {
            let remaining = current.input.pendingWorkloads.filter {
                $0.workloadID != workload.workloadID
            }
            let candidate = try rebuildingScenario(with: current, pendingWorkloads: remaining)
            if preserves(candidate) {
                current = candidate
            }
        }
        for node in current.input.nodes {
            let remaining = current.input.nodes.filter { $0.nodeID != node.nodeID }
            let candidate = try rebuildingScenario(with: current, nodes: remaining)
            if preserves(candidate) {
                current = candidate
            }
        }
        for state in current.input.fairnessStates {
            let remaining = current.input.fairnessStates.filter {
                !($0.subjectID == state.subjectID && $0.projectID == state.projectID)
            }
            let candidate = try rebuildingScenario(with: current, fairnessStates: remaining)
            if preserves(candidate) {
                current = candidate
            }
        }
        for placement in current.input.existingPlacements {
            let remaining = current.input.existingPlacements.filter {
                $0.workloadID != placement.workloadID
            }
            let candidate = try rebuildingScenario(with: current, existingPlacements: remaining)
            if preserves(candidate) {
                current = candidate
            }
        }
        for victim in current.input.victimAllocations {
            let remaining = current.input.victimAllocations.filter {
                $0.workloadID != victim.workloadID
            }
            let candidate = try rebuildingScenario(with: current, victimAllocations: remaining)
            if preserves(candidate) {
                current = candidate
            }
        }
        for budget in current.input.disruptionBudgets {
            let remaining = current.input.disruptionBudgets.filter { $0.budgetID != budget.budgetID }
            let candidate = try rebuildingScenario(with: current, disruptionBudgets: remaining)
            if preserves(candidate) {
                current = candidate
            }
        }
        return current
    }

    private static func rebuildingScenario(
        with original: Phase10SchedulerQualification.Scenario,
        pendingWorkloads: [SchedulerWorkload]? = nil,
        nodes: [SchedulerNode]? = nil,
        fairnessStates: [SchedulerFairnessState]? = nil,
        existingPlacements: [SchedulerExistingPlacement]? = nil,
        victimAllocations: [SchedulerVictimAllocation]? = nil,
        disruptionBudgets: [SchedulerDisruptionBudget]? = nil
    ) throws -> Phase10SchedulerQualification.Scenario {
        let input = original.input
        let selectedWorkloads = pendingWorkloads ?? input.pendingWorkloads
        let selectedNodes = nodes ?? input.nodes
        let selectedFairness = fairnessStates ?? input.fairnessStates
        let selectedExisting = existingPlacements ?? input.existingPlacements
        let selectedVictims = victimAllocations ?? input.victimAllocations
        let selectedBudgets = disruptionBudgets ?? input.disruptionBudgets
        let workloadIDs = Set(selectedWorkloads.map(\.workloadID))
        let nodeIDs = Set(selectedNodes.map(\.nodeID))
        let budgetIDs = Set(selectedBudgets.map(\.budgetID))
        let validVictims = selectedVictims.filter {
            nodeIDs.contains($0.nodeID) && ($0.budgetID == nil || budgetIDs.contains($0.budgetID!))
        }
        let validExisting = selectedExisting.filter {
            workloadIDs.contains($0.workloadID) && nodeIDs.contains($0.nodeID)
        }
        let usedBudgetIDs = Set(validVictims.compactMap(\.budgetID))
        let validBudgets = selectedBudgets.filter { usedBudgetIDs.contains($0.budgetID) }
        return Phase10SchedulerQualification.Scenario(
            label: original.label + "-minimized",
            seed: original.seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: selectedWorkloads,
                nodes: selectedNodes,
                fairnessStates: selectedFairness,
                existingPlacements: validExisting,
                victimAllocations: validVictims,
                disruptionBudgets: validBudgets,
                antiChurnThresholdBasisPoints: input.antiChurnThresholdBasisPoints,
                scoringWeights: input.scoringWeights,
                overcommitRatios: input.overcommitRatios,
                preemptionPolicy: input.preemptionPolicy,
                queuePolicy: input.queuePolicy,
                stabilityPolicy: input.stabilityPolicy,
                snapshotQuality: input.snapshotQuality,
                limits: input.limits
            ),
            oracleMode: original.oracleMode
        )
    }
}
