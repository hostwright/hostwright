import Foundation
import HostwrightScheduler

enum Phase10SchedulerQualificationExactOracle {
    static let domain = "multi-resource(cpu,memory,disk)-hard-capacity-feasibility"

    struct Result: Codable, Equatable {
        let inputFingerprint: String
        let domain: String
        let maxPlaced: Int
        let canonicalAssignment: [String: String]
    }

    struct Comparison {
        let result: Result
        let issues: [Phase10SchedulerQualification.Issue]
    }

    static func compare(
        input: SchedulerEngineInput,
        decision: SchedulerDecision,
        mode: Phase10SchedulerQualification.OracleMode
    ) throws -> Comparison {
        let result = try enumerate(input: input)
        let actualPlaced = decision.workloadDecisions.filter {
            $0.outcome == .placed || $0.outcome == .retainedExistingPlacement
        }.count
        var issues: [Phase10SchedulerQualification.Issue] = []
        if actualPlaced > result.maxPlaced {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .exactSafetyMismatch,
                    severity: .failure,
                    message: "Scheduler placed \(actualPlaced) workloads but the exact feasibility oracle found at most \(result.maxPlaced)."
                )
            )
        } else if actualPlaced < result.maxPlaced {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .intentionalOptimizationGap,
                    severity: .diagnostic,
                    message: "Scheduler placed \(actualPlaced) workloads while the exact oracle found a feasible assignment for \(result.maxPlaced); recorded as an optimization gap, not a safety mismatch."
                )
            )
        }
        let actualNodeID: UUID? = decision.workloadDecisions.first?.chosenNodeID ?? nil
        if mode == .lockedTieBreak,
           let expectedAssignment = result.canonicalAssignment[
               input.pendingWorkloads.sorted(by: { uuidPrecedes($0.workloadID, $1.workloadID) })
                   .first?.workloadID.uuidString ?? ""
           ],
           actualNodeID?.uuidString.lowercased() != expectedAssignment {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .exactTieBreakMismatch,
                    severity: .failure,
                    message: "Exact score tie selected \(actualNodeID?.uuidString ?? "nil") instead of the oracle canonical node \(expectedAssignment)."
                )
            )
        }
        return Comparison(result: result, issues: issues)
    }

    private static func enumerate(input: SchedulerEngineInput) throws -> Result {
        guard isMultiResourceFeasibilityDomain(input) else {
            throw ExactOracleDomainError.unsupportedInput
        }
        let workloads = input.pendingWorkloads.sorted { uuidPrecedes($0.workloadID, $1.workloadID) }
        let nodes = input.nodes.sorted { uuidPrecedes($0.nodeID, $1.nodeID) }
        let initialRemaining = try nodes.map {
            try $0.schedulableCapacity.subtracting($0.allocation)
        }
        var bestPlaced = -1
        var bestKey: String?
        var bestAssignment: [String: String] = [:]

        func visit(
            _ index: Int,
            remaining: [ResourceVector],
            assignments: [String: String],
            placed: Int
        ) throws {
            if index == workloads.count {
                let key = workloads.map { workload in
                    workload.workloadID.uuidString.lowercased() + "=" + (assignments[workload.workloadID.uuidString] ?? "~")
                }.joined(separator: "|")
                if placed > bestPlaced || (placed == bestPlaced && (bestKey == nil || key < bestKey!)) {
                    bestPlaced = placed
                    bestKey = key
                    bestAssignment = assignments
                }
                return
            }
            let workload = workloads[index]
            let workloadKey = workload.workloadID.uuidString
            var unplaced = assignments
            unplaced[workloadKey] = "~"
            try visit(index + 1, remaining: remaining, assignments: unplaced, placed: placed)
            for nodeIndex in nodes.indices where workload.request.fits(in: remaining[nodeIndex]) {
                var nextRemaining = remaining
                nextRemaining[nodeIndex] = try nextRemaining[nodeIndex].subtracting(workload.request)
                var nextAssignments = assignments
                nextAssignments[workloadKey] = nodes[nodeIndex].nodeID.uuidString.lowercased()
                try visit(
                    index + 1,
                    remaining: nextRemaining,
                    assignments: nextAssignments,
                    placed: placed + 1
                )
            }
        }

        try visit(0, remaining: initialRemaining, assignments: [:], placed: 0)
        return Result(
            inputFingerprint: input.inputDigest,
            domain: Self.domain,
            maxPlaced: max(bestPlaced, 0),
            canonicalAssignment: bestAssignment
        )
    }

    private static func isMultiResourceFeasibilityDomain(_ input: SchedulerEngineInput) -> Bool {
        let requiredResources = ["cpu", "disk", "memory"]
        return input.fairnessStates.isEmpty
            && input.existingPlacements.isEmpty
            && input.victimAllocations.isEmpty
            && input.disruptionBudgets.isEmpty
            && input.overcommitRatios.isEmpty
            && input.scoringWeights.fragmentation == 1
            && input.scoringWeights.fairness == 0
            && input.scoringWeights.topology == 0
            && input.scoringWeights.locality == 0
            && input.scoringWeights.hostPressureEnergy == 0
            && input.scoringWeights.disruption == 0
            && input.queuePolicy == .standard
            && input.stabilityPolicy == .standard
            && input.preemptionPolicy == .standard
            && input.snapshotQuality == .standard
            && input.nodes.allSatisfy {
                $0.schedulableCapacity.resourceNames == requiredResources
                    && $0.allocation.isEmpty
                    && $0.reservation.isEmpty
                    && $0.snapshot.acceleratorAvailability.isEmpty
                    && $0.snapshot.health == .healthy
                    && $0.snapshot.maintenance == .available
                    && $0.topologyDomains.isEmpty
                    && $0.posture.pressure == .nominal
                    && $0.posture.energy == .balanced
            }
            && input.pendingWorkloads.allSatisfy {
                $0.request.resourceNames == requiredResources
                    && $0.requirements.limit == nil
                    && $0.requirements.requiredArchitectures.isEmpty
                    && $0.requirements.requiredRuntime == nil
                    && $0.requirements.requiredProvider == nil
                    && $0.requirements.requiredCapabilities.isEmpty
                    && $0.requirements.affinity == .none
                    && $0.requirements.tolerations.isEmpty
                    && $0.requirements.acceleratorRequirements.isEmpty
                    && $0.topology == .none
                    && $0.locality == .none
                    && $0.constraints == .none
                    && $0.overhead.isEmpty
                    && $0.safetyMargin.isEmpty
            }
    }

    private enum ExactOracleDomainError: Error {
        case unsupportedInput
    }

    private static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }
}
