import Foundation
import HostwrightScheduler

extension Phase10SchedulerQualification {
    struct Evaluation {
        let decision: SchedulerDecision?
        let inputDigest: String
        let issues: [Issue]
        let oracle: Phase10SchedulerQualificationExactOracle.Result?
        private let provenance: Phase10SchedulerQualificationEvaluationProvenance?

        fileprivate init(
            decision: SchedulerDecision?,
            inputDigest: String,
            issues: [Issue],
            oracle: Phase10SchedulerQualificationExactOracle.Result?
        ) {
            self.decision = decision
            self.inputDigest = inputDigest
            self.issues = issues
            self.oracle = oracle
            provenance = Phase10SchedulerQualificationEvaluationProvenance()
        }

        var isVerifierProduced: Bool { provenance != nil }

        var failures: [Issue] {
            issues.filter { $0.severity == .failure }
        }

        func addingIssue(_ issue: Issue) -> Evaluation {
            Evaluation(
                decision: decision,
                inputDigest: inputDigest,
                issues: issues + [issue],
                oracle: oracle
            )
        }
    }
}

private final class Phase10SchedulerQualificationEvaluationProvenance {}

enum Phase10SchedulerQualificationVerifier {
    static func evaluate(
        _ scenario: Phase10SchedulerQualification.Scenario
    ) -> Phase10SchedulerQualification.Evaluation {
        let decision: SchedulerDecision
        do {
            decision = try SchedulerEngine().plan(scenario.input)
        } catch {
            return Phase10SchedulerQualification.Evaluation(
                decision: nil,
                inputDigest: scenario.input.inputDigest,
                issues: [
                    Phase10SchedulerQualification.Issue(
                        kind: .engineError,
                        severity: .failure,
                        message: "SchedulerEngine.plan threw for \(scenario.label): \(String(describing: error))"
                    )
                ],
                oracle: nil
            )
        }

        var issues: [Phase10SchedulerQualification.Issue] = []
        do {
            issues.append(contentsOf: try canonicalCodableReplay(
                input: scenario.input,
                decision: decision
            ))
        } catch {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Canonical JSON replay threw for \(scenario.label): \(String(describing: error))"
                )
            )
        }
        do {
            issues.append(contentsOf: try Phase10SchedulerQualificationInvariantChecker.check(
                input: scenario.input,
                decision: decision
            ))
        } catch {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .harnessError,
                    severity: .failure,
                    message: "Invariant checker threw for \(scenario.label): \(String(describing: error))"
                )
            )
        }

        do {
            let replay = try SchedulerEngine().plan(scenario.input)
            if replay != decision {
                issues.append(
                    Phase10SchedulerQualification.Issue(
                        kind: .determinism,
                        severity: .failure,
                        message: "Replay changed the decision for \(scenario.label)."
                    )
                )
            }
            let reordered = try reorderedInput(from: scenario.input)
            let reorderedDecision = try SchedulerEngine().plan(reordered)
            if reorderedDecision != decision {
                issues.append(
                    Phase10SchedulerQualification.Issue(
                        kind: .determinism,
                        severity: .failure,
                        message: "Collection reordering changed the decision for \(scenario.label)."
                    )
                )
            }
        } catch {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Replay or reordered plan threw for \(scenario.label): \(String(describing: error))"
                )
            )
        }

        guard scenario.oracleMode != .none else {
            return Phase10SchedulerQualification.Evaluation(
                decision: decision,
                inputDigest: scenario.input.inputDigest,
                issues: issues,
                oracle: nil
            )
        }
        do {
            let comparison = try Phase10SchedulerQualificationExactOracle.compare(
                input: scenario.input,
                decision: decision,
                mode: scenario.oracleMode
            )
            issues.append(contentsOf: comparison.issues)
            return Phase10SchedulerQualification.Evaluation(
                decision: decision,
                inputDigest: scenario.input.inputDigest,
                issues: issues,
                oracle: comparison.result
            )
        } catch {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .harnessError,
                    severity: .failure,
                    message: "Exact oracle threw for \(scenario.label): \(String(describing: error))"
                )
            )
            return Phase10SchedulerQualification.Evaluation(
                decision: decision,
                inputDigest: scenario.input.inputDigest,
                issues: issues,
                oracle: nil
            )
        }
    }

    private static func canonicalCodableReplay(
        input: SchedulerEngineInput,
        decision: SchedulerDecision
    ) throws -> [Phase10SchedulerQualification.Issue] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        var issues: [Phase10SchedulerQualification.Issue] = []

        let encodedInput = try encoder.encode(input)
        let decodedInput = try decoder.decode(SchedulerEngineInput.self, from: encodedInput)
        if decodedInput != input {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Canonical JSON input decode changed SchedulerEngineInput."
                )
            )
        }
        if try encoder.encode(decodedInput) != encodedInput {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Canonical JSON input re-encode was not stable."
                )
            )
        }

        let encodedDecision = try encoder.encode(decision)
        let decodedDecision = try decoder.decode(SchedulerDecision.self, from: encodedDecision)
        if decodedDecision != decision {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Canonical JSON decision decode changed SchedulerDecision."
                )
            )
        }
        if try encoder.encode(decodedDecision) != encodedDecision {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Canonical JSON decision re-encode was not stable."
                )
            )
        }

        let canonicalDecision = try SchedulerEngine().plan(decodedInput)
        if canonicalDecision != decision {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Planning the canonical JSON-decoded input changed the decision."
                )
            )
        }
        let simulatedDecision = try SchedulerEngine().simulate(decodedInput)
        if simulatedDecision != decision {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Simulating the canonical JSON-decoded input changed the planned SchedulerDecision."
                )
            )
        }
        return issues
    }

    private static func reorderedInput(
        from input: SchedulerEngineInput
    ) throws -> SchedulerEngineInput {
        let ratios = input.overcommitRatios.keys.sorted(by: >).reduce(into: [String: SchedulerResourceRatio]()) {
            result, key in
            result[key] = input.overcommitRatios[key]
        }
        return try SchedulerEngineInput(
            pendingWorkloads: input.pendingWorkloads.reversed(),
            nodes: input.nodes.reversed(),
            fairnessStates: input.fairnessStates.reversed(),
            existingPlacements: input.existingPlacements.reversed(),
            victimAllocations: input.victimAllocations.reversed(),
            disruptionBudgets: input.disruptionBudgets.reversed(),
            antiChurnThresholdBasisPoints: input.antiChurnThresholdBasisPoints,
            scoringWeights: input.scoringWeights,
            overcommitRatios: ratios,
            preemptionPolicy: input.preemptionPolicy,
            queuePolicy: input.queuePolicy,
            stabilityPolicy: input.stabilityPolicy,
            snapshotQuality: input.snapshotQuality,
            limits: input.limits
        )
    }
}

private enum Phase10SchedulerQualificationInvariantChecker {
    private struct FairnessLedger {
        var usage: ResourceVector
        let quota: ResourceVector?
    }

    static func check(
        input: SchedulerEngineInput,
        decision: SchedulerDecision
    ) throws -> [Phase10SchedulerQualification.Issue] {
        var issues: [Phase10SchedulerQualification.Issue] = []
        let expectedWorkloadIDs = input.pendingWorkloads.map(\.workloadID)
        let actualWorkloadIDs = decision.workloadDecisions.map(\.workloadID)
        if Set(actualWorkloadIDs) != Set(expectedWorkloadIDs)
            || actualWorkloadIDs.count != expectedWorkloadIDs.count
            || decision.orderedWorkloadIDs != actualWorkloadIDs {
            issues.append(issue(
                .decisionIdentity,
                "Decision workload identities do not exactly match the input workload set."
            ))
        }

        let workloads = Dictionary(uniqueKeysWithValues: input.pendingWorkloads.map {
            ($0.workloadID, $0)
        })
        let nodes = Dictionary(uniqueKeysWithValues: input.nodes.map { ($0.nodeID, $0) })
        let existing = Dictionary(uniqueKeysWithValues: input.existingPlacements.map {
            ($0.workloadID, $0)
        })
        var allocations = Dictionary(uniqueKeysWithValues: input.nodes.map {
            ($0.nodeID, $0.allocation)
        })
        var fairness = Dictionary(uniqueKeysWithValues: input.fairnessStates.map { state in
            (fairnessKey(state.subjectID, state.projectID), FairnessLedger(
                usage: state.usage,
                quota: state.quota
            ))
        })
        let victims = Dictionary(uniqueKeysWithValues: input.victimAllocations.map {
            ($0.workloadID, $0)
        })
        let budgets = Dictionary(uniqueKeysWithValues: input.disruptionBudgets.map {
            ($0.budgetID, $0)
        })
        var topologyObservations: [UUID: HardTopologySpreadObservation] = [:]
        for placement in input.existingPlacements {
            topologyObservations[placement.workloadID] = try HardTopologySpreadObservation(
                workloadID: placement.workloadID,
                nodeID: placement.nodeID,
                groupID: placement.topologyGroupID
            )
        }
        for victim in input.victimAllocations where topologyObservations[victim.workloadID] == nil {
            topologyObservations[victim.workloadID] = try HardTopologySpreadObservation(
                workloadID: victim.workloadID,
                nodeID: victim.nodeID,
                groupID: victim.topologyGroupID
            )
        }
        var plannedVictimIDs = Set<UUID>()
        var plannedBudgetCounts: [String: Int] = [:]
        var plannedBudgetCosts: [String: Int64] = [:]

        for workloadDecision in decision.workloadDecisions {
            guard let workload = workloads[workloadDecision.workloadID] else {
                issues.append(issue(
                    .decisionIdentity,
                    "Decision references unknown workload \(workloadDecision.workloadID.uuidString)."
                ))
                continue
            }

            if let placement = existing[workload.workloadID],
               let allocation = allocations[placement.nodeID] {
                if placement.allocation.fits(in: allocation) {
                    allocations[placement.nodeID] = try allocation.subtracting(placement.allocation)
                } else {
                    issues.append(issue(
                        .capacity,
                        "Existing placement \(workload.workloadID.uuidString) cannot be removed from its recorded node allocation."
                    ))
                }
                let key = fairnessKey(workload.subjectID, workload.projectID)
                if var record = fairness[key], placement.allocation.fits(in: record.usage) {
                    record.usage = try record.usage.subtracting(placement.allocation)
                    fairness[key] = record
                }
            }

            guard workloadDecision.outcome == .placed
                || workloadDecision.outcome == .retainedExistingPlacement else {
                if workloadDecision.outcome == .preemptionProposed {
                    issues.append(contentsOf: try preemptionIssues(
                        workload: workload,
                        decision: workloadDecision,
                        input: input,
                        victims: victims,
                        budgets: budgets,
                        plannedVictimIDs: &plannedVictimIDs,
                        plannedBudgetCounts: &plannedBudgetCounts,
                        plannedBudgetCosts: &plannedBudgetCosts
                    ))
                }
                continue
            }
            guard let nodeID = workloadDecision.chosenNodeID,
                  let node = nodes[nodeID],
                  let charge = workloadDecision.capacityExplanation?.chargedCapacity else {
                issues.append(issue(
                    .hardPolicy,
                    "Placed workload \(workload.workloadID.uuidString) is missing a node or charged-capacity explanation."
                ))
                continue
            }
            guard let allocation = allocations[nodeID] else {
                issues.append(issue(
                    .decisionIdentity,
                    "Placed workload \(workload.workloadID.uuidString) selected an unknown node \(nodeID.uuidString)."
                ))
                continue
            }

            let postAllocation: ResourceVector
            do {
                postAllocation = try allocation.adding(charge)
            } catch {
                issues.append(issue(
                    .capacity,
                    "Capacity arithmetic failed for \(workload.workloadID.uuidString): \(String(describing: error))."
                ))
                continue
            }
            if !postAllocation.fits(in: node.capacity) {
                issues.append(issue(
                    .capacity,
                    "Placement of \(workload.workloadID.uuidString) exceeds node \(nodeID.uuidString) schedulable capacity."
                ))
                continue
            }
            let topologyContext = try HardTopologySpreadContext(
                nodeTopologyDomains: input.nodes.reduce(into: [UUID: [String: String]]()) {
                    result, inputNode in
                    result[inputNode.nodeID] = inputNode.topologyDomains
                },
                observations: topologyObservations.values
                    .filter { $0.workloadID != workload.workloadID }
                    .sorted {
                        SchedulerOrdering.uuidPrecedes($0.workloadID, $1.workloadID)
                    }
            )
            issues.append(contentsOf: try hardPolicyIssues(
                workload: workload,
                charge: charge,
                node: node,
                allocation: allocation,
                topologyContext: topologyContext
            ))
            allocations[nodeID] = postAllocation
            topologyObservations[workload.workloadID] = try HardTopologySpreadObservation(
                workloadID: workload.workloadID,
                nodeID: nodeID,
                groupID: workload.topology.groupID
            )

            let key = fairnessKey(workload.subjectID, workload.projectID)
            if var record = fairness[key] {
                record.usage = try record.usage.adding(charge)
                if let quota = record.quota, !record.usage.fits(in: quota) {
                    issues.append(issue(
                        .quota,
                        "Placement of \(workload.workloadID.uuidString) exceeds its subject/project quota."
                    ))
                }
                fairness[key] = record
            }
        }
        issues.append(contentsOf: starvationIssues(input: input, decision: decision, workloads: workloads))
        issues.append(contentsOf: churnIssues(input: input, decision: decision, existing: existing))
        return issues
    }

    private static func preemptionIssues(
        workload: SchedulerWorkload,
        decision: SchedulerWorkloadDecision,
        input: SchedulerEngineInput,
        victims: [UUID: SchedulerVictimAllocation],
        budgets: [String: SchedulerDisruptionBudget],
        plannedVictimIDs: inout Set<UUID>,
        plannedBudgetCounts: inout [String: Int],
        plannedBudgetCosts: inout [String: Int64]
    ) throws -> [Phase10SchedulerQualification.Issue] {
        guard let proposal = decision.preemption else {
            return [issue(
                .preemption,
                "Preemption outcome for \(workload.workloadID.uuidString) is missing its proposal."
            )]
        }
        var issues: [Phase10SchedulerQualification.Issue] = []
        if !proposal.requiresFence || proposal.intentDigest != input.inputDigest {
            issues.append(issue(
                .preemption,
                "Preemption proposal for \(workload.workloadID.uuidString) is not correctly fenced to this input digest."
            ))
        }
        if proposal.targetWorkloadID != workload.workloadID
            || proposal.policy != input.preemptionPolicy
            || input.preemptionPolicy.incomingNonPreempting
            || !input.preemptionPolicy.preemptionAuthorized {
            issues.append(issue(
                .preemption,
                "Preemption proposal for \(workload.workloadID.uuidString) violates the input preemption policy."
            ))
        }
        guard let proposalNode = input.nodes.first(where: { $0.nodeID == proposal.nodeID }) else {
            issues.append(issue(
                .preemption,
                "Preemption proposal for \(workload.workloadID.uuidString) targets an unknown node."
            ))
            return issues
        }
        guard let chargedCapacity = decision.capacityExplanation?.chargedCapacity else {
            issues.append(issue(
                .preemption,
                "Preemption proposal for \(workload.workloadID.uuidString) is missing incoming charged capacity."
            ))
            return issues
        }
        let sortedVictimIDs = proposal.victims.map(\.workloadID).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        if proposal.victimWorkloadIDs != sortedVictimIDs {
            issues.append(issue(
                .preemption,
                "Preemption proposal victim IDs do not match its canonical victim list."
            ))
        }
        if proposal.victims.isEmpty {
            issues.append(issue(
                .preemption,
                "Preemption proposal contains no victims and cannot reclaim capacity."
            ))
        }

        var reclaimed = ResourceVector.zero
        var localVictimIDs = Set<UUID>()
        var calculatedCost: Int64 = 0
        for proposedVictim in proposal.victims {
            guard let inputVictim = victims[proposedVictim.workloadID], inputVictim == proposedVictim else {
                issues.append(issue(
                    .preemption,
                    "Preemption proposal references a victim not present in the input snapshot."
                ))
                continue
            }
            if !localVictimIDs.insert(inputVictim.workloadID).inserted {
                issues.append(issue(
                    .preemption,
                    "Victim \(inputVictim.workloadID.uuidString) was duplicated in the proposal."
                ))
            }
            if inputVictim.subjectID.isEmpty || inputVictim.projectID.isEmpty {
                issues.append(issue(
                    .preemption,
                    "Preemption victim \(inputVictim.workloadID.uuidString) is missing subject/project identity."
                ))
            }
            if inputVictim.nodeID != proposal.nodeID
                || inputVictim.workloadID == workload.workloadID
                || inputVictim.allocation.isEmpty
                || !inputVictim.preemptible
                || inputVictim.priority >= workload.priority
                || workload.priority - inputVictim.priority < input.preemptionPolicy.minimumPriorityGap
                || (input.preemptionPolicy.protectedVictimStarvationAgeUnits > 0
                    && inputVictim.starvationAgeUnits
                        >= input.preemptionPolicy.protectedVictimStarvationAgeUnits) {
                issues.append(issue(
                    .preemption,
                    "Preemption proposal includes an ineligible victim \(inputVictim.workloadID.uuidString)."
                ))
            }
            if inputVictim.nodeID == proposal.nodeID,
               inputVictim.workloadID != workload.workloadID,
               !inputVictim.allocation.isEmpty {
                do {
                    reclaimed = try reclaimed.adding(inputVictim.allocation)
                } catch {
                    issues.append(issue(
                        .preemption,
                        "Preemption victim reclamation arithmetic failed: \(String(describing: error))."
                    ))
                }
            }
            if !plannedVictimIDs.insert(inputVictim.workloadID).inserted {
                issues.append(issue(
                    .preemption,
                    "Victim \(inputVictim.workloadID.uuidString) was proposed more than once in one scheduling decision."
                ))
            }
            let (nextCost, overflow) = calculatedCost.addingReportingOverflow(
                inputVictim.disruptionCostBasisPoints
            )
            if overflow {
                issues.append(issue(.preemption, "Preemption disruption cost overflowed."))
            } else {
                calculatedCost = nextCost
            }
            if let budgetID = inputVictim.budgetID {
                guard let budget = budgets[budgetID] else {
                    issues.append(issue(.preemption, "Preemption proposal references an unknown budget \(budgetID)."))
                    continue
                }
                if budget.projectID != inputVictim.projectID {
                    issues.append(issue(
                        .preemption,
                        "Preemption proposal uses budget \(budgetID) outside victim project \(inputVictim.projectID)."
                    ))
                }
                plannedBudgetCounts[budgetID, default: 0] += 1
                plannedBudgetCosts[budgetID, default: 0] += inputVictim.disruptionCostBasisPoints
                if plannedBudgetCounts[budgetID, default: 0] > budget.remainingVictimCount
                    || plannedBudgetCosts[budgetID, default: 0]
                        > budget.remainingDisruptionCostBasisPoints {
                    issues.append(issue(
                        .preemption,
                        "Preemption proposal exceeds disruption budget \(budgetID)."
                    ))
                }
            }
        }
        do {
            guard reclaimed.fits(in: proposalNode.allocation) else {
                issues.append(issue(
                    .preemption,
                    "Preemption victims reclaim more resource than the proposal node currently allocates."
                ))
                return issues
            }
            let postVictimAllocation = try proposalNode.allocation.subtracting(reclaimed)
            let postVictimRemaining = try proposalNode.schedulableCapacity.subtracting(
                postVictimAllocation
            )
            if !chargedCapacity.fits(in: postVictimRemaining) {
                issues.append(issue(
                    .preemption,
                    "Preemption victims do not reclaim enough reservation-adjusted capacity for the incoming charged request."
                ))
            }
        } catch {
            issues.append(issue(
                .preemption,
                "Preemption capacity proof failed for node \(proposal.nodeID.uuidString): \(String(describing: error))."
            ))
        }
        if calculatedCost != proposal.disruptionCostBasisPoints {
            issues.append(issue(
                .preemption,
                "Preemption proposal cost does not equal the sum of selected victim costs."
            ))
        }
        return issues
    }

    private static func starvationIssues(
        input: SchedulerEngineInput,
        decision: SchedulerDecision,
        workloads: [UUID: SchedulerWorkload]
    ) -> [Phase10SchedulerQualification.Issue] {
        let threshold = input.queuePolicy.starvationAgeThresholdUnits
        guard threshold > 0 else {
            return []
        }
        let ages = Dictionary(uniqueKeysWithValues: input.fairnessStates.map {
            (fairnessKey($0.subjectID, $0.projectID), $0.starvationAgeUnits)
        })
        let protectedIndexes = decision.workloadDecisions.enumerated().compactMap { index, item -> Int? in
            guard let workload = workloads[item.workloadID] else {
                return nil
            }
            return (ages[fairnessKey(workload.subjectID, workload.projectID)] ?? 0) >= threshold
                ? index
                : nil
        }
        guard let lastProtected = protectedIndexes.max() else {
            return []
        }
        let firstUnprotected = decision.workloadDecisions.enumerated().first { index, item in
            guard let workload = workloads[item.workloadID] else {
                return false
            }
            return (ages[fairnessKey(workload.subjectID, workload.projectID)] ?? 0) < threshold
        }?.offset
        if let firstUnprotected, firstUnprotected < lastProtected {
            return [issue(
                .starvationBound,
                "A starvation-protected workload was ordered after an unprotected workload."
            )]
        }
        return []
    }

    private static func churnIssues(
        input: SchedulerEngineInput,
        decision: SchedulerDecision,
        existing: [UUID: SchedulerExistingPlacement]
    ) -> [Phase10SchedulerQualification.Issue] {
        var issues: [Phase10SchedulerQualification.Issue] = []
        let nodes = Dictionary(uniqueKeysWithValues: input.nodes.map { ($0.nodeID, $0) })
        for item in decision.workloadDecisions {
            guard let placement = existing[item.workloadID],
                  let selectedNodeID = item.chosenNodeID,
                  let currentAlternative = item.feasibleAlternatives.first(where: {
                      $0.nodeID == placement.nodeID
                  }),
                  let selectedScore = item.scoreComponents,
                  let currentNode = nodes[placement.nodeID] else {
                continue
            }
            let pressureOverridesStability: Bool
            switch currentNode.posture.pressure {
            case .critical, .unknown, .unavailable:
                pressureOverridesStability = input.stabilityPolicy.pressureSafetyOverride
            case .nominal, .elevated:
                pressureOverridesStability = false
            }
            let stability = placement.stability
            let protected = stability.residenceUnits < input.stabilityPolicy.minimumResidenceUnits
                || stability.cooldownRemainingUnits > input.stabilityPolicy.cooldownUnitsToRetain
                || stability.recoveryDelayRemainingUnits
                    > input.stabilityPolicy.recoveryDelayUnitsToRetain
                || stability.rolloutProtected
            if protected && !pressureOverridesStability && selectedNodeID != placement.nodeID {
                issues.append(issue(
                    .churnBound,
                    "Protected existing placement \(placement.workloadID.uuidString) moved before its stability gate expired."
                ))
                continue
            }
            let improvement = selectedScore.totalBasisPoints - currentAlternative.scoreComponents.totalBasisPoints
            if selectedNodeID != placement.nodeID && improvement <= input.antiChurnThresholdBasisPoints {
                issues.append(issue(
                    .churnBound,
                    "Existing placement \(placement.workloadID.uuidString) moved without exceeding its anti-churn threshold."
                ))
            }
        }
        return issues
    }

    private static func hardPolicyIssues(
        workload: SchedulerWorkload,
        charge: ResourceVector,
        node: SchedulerNode,
        allocation: ResourceVector,
        topologyContext: HardTopologySpreadContext
    ) throws -> [Phase10SchedulerQualification.Issue] {
        var issues: [Phase10SchedulerQualification.Issue] = []
        switch node.posture.pressure {
        case .critical, .unknown, .unavailable:
            issues.append(issue(
                .hardPolicy,
                "Placement of \(workload.workloadID.uuidString) used pressure-ineligible node \(node.nodeID.uuidString)."
            ))
        case .nominal, .elevated:
            break
        }
        let dynamicRequirements = try WorkloadPlacementRequirements(
            workloadID: workload.workloadID,
            request: charge,
            requiredArchitectures: workload.requirements.requiredArchitectures,
            requiredRuntime: workload.requirements.requiredRuntime,
            requiredProvider: workload.requirements.requiredProvider,
            requiredCapabilities: workload.requirements.requiredCapabilities,
            affinity: workload.requirements.affinity,
            tolerations: workload.requirements.tolerations,
            acceleratorRequirements: workload.requirements.acceleratorRequirements
        )
        let dynamicSnapshot = try NodePlacementSnapshot(
            nodeID: node.nodeID,
            capacity: node.capacity,
            allocation: allocation,
            architecture: node.snapshot.architecture,
            runtime: node.snapshot.runtime,
            provider: node.snapshot.provider,
            capabilities: node.snapshot.capabilities,
            health: node.snapshot.health,
            maintenance: node.snapshot.maintenance,
            labels: node.snapshot.labels,
            taints: node.snapshot.taints,
            acceleratorAvailability: node.snapshot.acceleratorAvailability
        )
        let filters = HardPlacementFilterEvaluator().evaluate(
            workload: dynamicRequirements,
            on: dynamicSnapshot,
            topologyContext: topologyContext
        )
        if !filters.passed {
            issues.append(issue(
                .hardPolicy,
                "Placement of \(workload.workloadID.uuidString) bypassed hard filters: \(filters.reasons.map(\.code.rawValue).joined(separator: ","))."
            ))
        }
        if !Set(workload.constraints.requiredVolumes).isSubset(of: Set(node.availableVolumeIDs))
            || !Set(workload.constraints.requiredPorts).isSubset(of: Set(node.availablePorts))
            || !Set(workload.constraints.requiredNetworks).isSubset(of: Set(node.availableNetworkIDs)) {
            issues.append(issue(
                .hardPolicy,
                "Placement of \(workload.workloadID.uuidString) bypassed a volume, port, or network constraint."
            ))
        }
        return issues
    }

    private static func fairnessKey(_ subject: String, _ project: String) -> String {
        subject + "\u{1F}" + project
    }

    private static func issue(
        _ kind: Phase10SchedulerQualification.IssueKind,
        _ message: String
    ) -> Phase10SchedulerQualification.Issue {
        Phase10SchedulerQualification.Issue(kind: kind, severity: .failure, message: message)
    }
}
