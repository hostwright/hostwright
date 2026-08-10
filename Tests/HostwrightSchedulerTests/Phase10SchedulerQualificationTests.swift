import Dispatch
import XCTest
import HostwrightScheduler

final class Phase10SchedulerQualificationTests: XCTestCase {
    func testPhase10SchedulerQualificationConfigurationAcceptsQualificationMaximums() throws {
        let configuration = try Phase10SchedulerQualification.Configuration(
            generatedCount: 1_000_000,
            exactCount: 10_000
        )

        XCTAssertEqual(configuration.generatedCount, 1_000_000)
        XCTAssertEqual(configuration.exactCount, 10_000)
    }

    func testPhase10SchedulerQualificationEnvironmentMaximumsResolveExactLoopBounds() throws {
        let configuration = try Phase10SchedulerQualification.Configuration.current(
            environment: [
                Phase10SchedulerQualification.Configuration.generatedCountEnvironment: "1000000",
                Phase10SchedulerQualification.Configuration.exactCountEnvironment: "10000",
                Phase10SchedulerQualification.Configuration.seedEnvironment: "0x10209214"
            ]
        )

        XCTAssertEqual(configuration.generatedCount, 1_000_000)
        XCTAssertEqual(configuration.exactCount, 10_000)
        XCTAssertEqual((0..<configuration.generatedCount).count, 1_000_000)
        XCTAssertEqual((0..<configuration.exactCount).count, 10_000)

        let firstGenerated = try Phase10SchedulerQualificationGenerator.generatedScenario(
            index: 0,
            seed: configuration.seed
        )
        let lastGenerated = try Phase10SchedulerQualificationGenerator.generatedScenario(
            index: configuration.generatedCount - 1,
            seed: configuration.seed
        )
        XCTAssertEqual(firstGenerated.seed, configuration.seed)
        XCTAssertEqual(
            lastGenerated.seed,
            configuration.seed &+ UInt64(configuration.generatedCount - 1)
        )

        let firstExact = try Phase10SchedulerQualificationGenerator.exactScenario(
            index: 0,
            seed: configuration.seed
        )
        let lastExact = try Phase10SchedulerQualificationGenerator.exactScenario(
            index: configuration.exactCount - 1,
            seed: configuration.seed
        )
        XCTAssertEqual(firstExact.seed, configuration.seed)
        XCTAssertEqual(
            lastExact.seed,
            configuration.seed &+ UInt64(configuration.exactCount - 1)
        )
    }

    func testPhase10SchedulerQualificationSeededInvariantSmoke() throws {
        let configuration = try Phase10SchedulerQualification.Configuration.current()
        let testName = "testPhase10SchedulerQualificationSeededInvariantSmoke"
        var receiptBuilder = Phase10SchedulerQualificationRunReceiptBuilder(
            cell: .generatedInvariant,
            testName: testName,
            seed: configuration.seed,
            caseCount: configuration.generatedCount,
            configuration: configuration
        )
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<configuration.generatedCount {
            let scenario = try Phase10SchedulerQualificationGenerator.generatedScenario(
                index: index,
                seed: configuration.seed
            )
            let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
            let metrics = try assertQualificationPasses(
                scenario,
                configuration: configuration,
                evaluation: evaluation,
                caseIndex: index
            )
            try receiptBuilder.append(
                index: index,
                scenario: scenario,
                evaluation: evaluation,
                metrics: metrics
            )
        }
        try emitQualificationReceiptIfConfigured(
            &receiptBuilder,
            configuration: configuration,
            elapsedSeconds: elapsedSeconds(since: started)
        )
    }

    func testPhase10SchedulerQualificationExactMultiResourceFeasibilityOracleSmoke() throws {
        let configuration = try Phase10SchedulerQualification.Configuration.current()
        let testName = "testPhase10SchedulerQualificationExactMultiResourceFeasibilityOracleSmoke"
        var receiptBuilder = Phase10SchedulerQualificationRunReceiptBuilder(
            cell: .exactOracle,
            testName: testName,
            seed: configuration.seed,
            caseCount: configuration.exactCount,
            configuration: configuration
        )
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<configuration.exactCount {
            let scenario = try Phase10SchedulerQualificationGenerator.exactScenario(
                index: index,
                seed: configuration.seed
            )
            let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
            let expectedOracleDomain = "multi-resource(cpu,memory,disk)-hard-capacity-feasibility"
            let evaluationForReceipt: Phase10SchedulerQualification.Evaluation
            if evaluation.oracle?.domain == expectedOracleDomain {
                evaluationForReceipt = evaluation
            } else {
                evaluationForReceipt = evaluation.addingIssue(
                    Phase10SchedulerQualification.Issue(
                        kind: .exactSafetyMismatch,
                        severity: .failure,
                        message: "Exact oracle declared an unexpected domain; expected (expectedOracleDomain)."
                    )
                )
                XCTFail(
                    "Exact oracle must declare its deterministic CPU/memory/disk hard-capacity domain."
                )
            }
            let metrics = try assertQualificationPasses(
                scenario,
                configuration: configuration,
                evaluation: evaluationForReceipt,
                caseIndex: index
            )
            try receiptBuilder.append(
                index: index,
                scenario: scenario,
                evaluation: evaluationForReceipt,
                metrics: metrics
            )
        }
        try emitQualificationReceiptIfConfigured(
            &receiptBuilder,
            configuration: configuration,
            elapsedSeconds: elapsedSeconds(since: started)
        )
    }

    func testPhase10SchedulerQualificationCanonicalCodableReplaySmoke() throws {
        let configuration = try Phase10SchedulerQualification.Configuration(
            generatedCount: 1,
            exactCount: 1
        )
        let scenario = try Phase10SchedulerQualificationGenerator.generatedScenario(
            index: 0,
            seed: configuration.seed
        )
        let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
        XCTAssertFalse(
            evaluation.issues.contains { $0.kind == .determinism },
            "Canonical SchedulerEngineInput/SchedulerDecision JSON replay must be stable."
        )
        try assertQualificationPasses(
            scenario,
            configuration: configuration,
            evaluation: evaluation
        )
    }

    func testPhase10SchedulerQualificationStatefulFairnessAndAntiChurnTraces() throws {
        let starvationAges: [Int64] = [3, 4, 5, 6, 7]
        let residenceUnits: [Int64] = [0, 2, 4, 6, 8]
        let fairnessTrace = try Phase10SchedulerQualificationGenerator.statefulFairnessTrace(
            seed: Phase10SchedulerQualification.defaultSeed,
            starvationAges: starvationAges
        )
        let antiChurnTrace = try Phase10SchedulerQualificationGenerator.statefulAntiChurnTrace(
            seed: Phase10SchedulerQualification.defaultSeed &+ 1,
            residenceUnits: residenceUnits
        )
        // These epochs carry caller-supplied counters; the harness does not
        // evolve production fairness or placement state.
        let configuration = try Phase10SchedulerQualification.Configuration(
            generatedCount: 1,
            exactCount: 1
        )

        XCTAssertEqual(
            fairnessTrace.epochs.map { epoch in
                epoch.input.fairnessStates.first {
                    $0.subjectID == "protected"
                }?.starvationAgeUnits
            },
            starvationAges.map(Optional.some)
        )
        XCTAssertEqual(
            antiChurnTrace.epochs.compactMap { epoch in
                epoch.input.existingPlacements.first?.stability.residenceUnits
            },
            residenceUnits
        )

        for trace in [fairnessTrace, antiChurnTrace] {
            var moves = 0
            for epoch in trace.epochs {
                let evaluation = Phase10SchedulerQualificationVerifier.evaluate(epoch)
                try assertQualificationPasses(
                    epoch,
                    configuration: configuration,
                    evaluation: evaluation
                )
                guard let decision = evaluation.decision,
                      let protectedDecision = decision.workloadDecisions.first(where: {
                          $0.workloadID == trace.protectedWorkloadID
                      }) else {
                    XCTFail("Stateful trace \(trace.label) lost its protected workload decision.")
                    continue
                }
                if trace.protectedWorkMustBeFirst {
                    XCTAssertEqual(
                        decision.workloadDecisions.first?.workloadID,
                        trace.protectedWorkloadID,
                        "Protected starvation work must not be bypassed in \(epoch.label)."
                    )
                }
                if protectedDecision.chosenNodeID != trace.expectedNodeID {
                    moves += 1
                }
            }
            XCTAssertLessThanOrEqual(
                moves,
                trace.maxMoves,
                "Stateful trace \(trace.label) exceeded its explicit movement bound."
            )
        }
    }

    func testPhase10SchedulerQualificationHardSelectorsAndTopologySpreadReplay() throws {
        let seed = Phase10SchedulerQualification.defaultSeed &+ 0x800
        let hardCase = try Phase10SchedulerQualificationGenerator.hardSelectorTopologyCase(
            seed: seed
        )
        let selector = try XCTUnwrap(
            hardCase.workload.affinity.requiredSelectors.first {
                $0.key == "class" && $0.operator == .notIn
            }
        )
        XCTAssertTrue(selector.matches(["class": "cpu"]))
        XCTAssertFalse(
            selector.matches([:]),
            "not-in must not match when its label key is absent."
        )

        let evaluator = HardPlacementFilterEvaluator()
        func results(
            _ nodes: [SchedulerNode],
            context: HardTopologySpreadContext
        ) -> [UUID: PlacementFilterResult] {
            Dictionary(uniqueKeysWithValues: nodes.map { node in
                (
                    node.nodeID,
                    evaluator.evaluate(
                        workload: hardCase.workload,
                        on: node.snapshot,
                        topologyContext: context
                    )
                )
            })
        }

        let originalResults = results(hardCase.nodes, context: hardCase.context)
        XCTAssertTrue(originalResults[hardCase.passingNodeID]?.passed == true)
        let absentResult = try XCTUnwrap(originalResults[hardCase.absentNotInNodeID])
        XCTAssertFalse(absentResult.passed)
        XCTAssertEqual(
            Set(absentResult.reasons).count,
            absentResult.reasons.count,
            "hard selector reasons must not be duplicated"
        )
        XCTAssertTrue(
            absentResult.reasons.contains {
                $0.stableDetailKey.contains("required-selector:class")
            },
            "an absent key must fail the required not-in selector"
        )
        let skewedResult = try XCTUnwrap(originalResults[hardCase.skewedTopologyNodeID])
        XCTAssertFalse(skewedResult.passed)
        XCTAssertEqual(
            Set(skewedResult.reasons).count,
            skewedResult.reasons.count,
            "hard topology reasons must not be duplicated"
        )
        XCTAssertTrue(
            skewedResult.reasons.contains {
                $0.stableDetailKey.contains("topology-spread:zone:max-skew:1")
            }
        )

        let reorderedContext = try HardTopologySpreadContext(
            nodeTopologyDomains: Dictionary(
                uniqueKeysWithValues: hardCase.context.nodeTopologyDomains.reversed()
            ),
            observations: Array(hardCase.context.observations.reversed())
        )
        XCTAssertEqual(hardCase.context, reorderedContext)
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            try canonicalEncoder.encode(hardCase.context),
            try canonicalEncoder.encode(reorderedContext)
        )
        XCTAssertEqual(
            originalResults,
            results(Array(hardCase.nodes.reversed()), context: reorderedContext),
            "hard selector/topology results must not depend on input collection order"
        )

        let encodedCase = try canonicalEncoder.encode(hardCase)
        let decodedCase = try JSONDecoder().decode(
            Phase10SchedulerQualification.HardSelectorTopologyCase.self,
            from: encodedCase
        )
        XCTAssertEqual(decodedCase, hardCase)

        let scenario = try Phase10SchedulerQualificationGenerator.hardSelectorTopologyScenario(
            seed: seed
        )
        let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
        XCTAssertNil(
            evaluation.oracle,
            "hard selectors/topology are outside the multi-resource exact-oracle domain"
        )
        try assertQualificationPasses(
            scenario,
            configuration: try Phase10SchedulerQualification.Configuration(
                generatedCount: 1,
                exactCount: 1
            ),
            evaluation: evaluation
        )
    }

    func testPhase10SchedulerQualificationWeightedSelectorsAndDuplicateRejection() throws {
        let scenario = try Phase10SchedulerQualificationGenerator.weightedSelectorScenario(
            seed: Phase10SchedulerQualification.defaultSeed &+ 0x810
        )
        let workload = try XCTUnwrap(scenario.input.pendingWorkloads.first)
        let preferredNode = try XCTUnwrap(
            scenario.input.nodes.first { $0.snapshot.labels["class"] == "cpu" }
        )
        let alternativeNode = try XCTUnwrap(
            scenario.input.nodes.first { $0.snapshot.labels["class"] == "gpu" }
        )

        XCTAssertEqual(
            workload.topology.preferredAffinity.map {
                $0.selector.matches(preferredNode.snapshot.labels)
            },
            [true, true, true, true]
        )
        XCTAssertEqual(
            workload.topology.preferredAffinity.map {
                $0.selector.matches(alternativeNode.snapshot.labels)
            },
            [false, false, false, false]
        )
        XCTAssertEqual(
            workload.topology.preferredAntiAffinity.map {
                $0.selector.matches(preferredNode.snapshot.labels)
            },
            [false, false, false, false]
        )
        XCTAssertEqual(
            workload.topology.preferredAntiAffinity.map {
                $0.selector.matches(alternativeNode.snapshot.labels)
            },
            [true, true, true, true]
        )

        let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
        try assertQualificationPasses(
            scenario,
            configuration: try Phase10SchedulerQualification.Configuration(
                generatedCount: 1,
                exactCount: 1
            ),
            evaluation: evaluation
        )
        XCTAssertFalse(evaluation.issues.contains { $0.kind == .determinism })
        let decision = try XCTUnwrap(evaluation.decision)
        let workloadDecision = try XCTUnwrap(decision.workloadDecisions.first)
        XCTAssertEqual(workloadDecision.outcome, .placed)
        XCTAssertEqual(workloadDecision.chosenNodeID, preferredNode.nodeID)

        let selector = try SchedulerLabelSelector(
            key: "class",
            operator: .in,
            values: ["cpu"]
        )
        let lowerWeight = try SchedulerWeightedLabelSelectorPreference(
            weight: 1,
            selector: selector
        )
        let higherWeight = try SchedulerWeightedLabelSelectorPreference(
            weight: 9,
            selector: selector
        )
        XCTAssertThrowsError(
            try SchedulerTopologyPreference(preferredAffinity: [lowerWeight, higherWeight])
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .duplicateIdentifier(field: "preferred-selector")
            )
        }
        XCTAssertThrowsError(
            try SchedulerTopologyPreference(preferredAntiAffinity: [lowerWeight, higherWeight])
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .duplicateIdentifier(field: "preferred-selector")
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decodedInput = try JSONDecoder().decode(
            SchedulerEngineInput.self,
            from: encoder.encode(scenario.input)
        )
        let decodedDecision = try JSONDecoder().decode(
            SchedulerDecision.self,
            from: encoder.encode(decision)
        )
        XCTAssertEqual(decodedInput, scenario.input)
        XCTAssertEqual(decodedDecision, decision)
        XCTAssertEqual(
            decodedInput.pendingWorkloads.first?.topology.preferredAffinity,
            workload.topology.preferredAffinity
        )
        XCTAssertEqual(
            decodedInput.pendingWorkloads.first?.topology.preferredAntiAffinity,
            workload.topology.preferredAntiAffinity
        )
    }

    func testPhase10SchedulerQualificationHostileBoundaries() throws {
        let configuration = try Phase10SchedulerQualification.Configuration.current()
        let scenarios = try Phase10SchedulerQualificationGenerator.hostileScenarios(
            seed: Phase10SchedulerQualification.defaultSeed
        )
        for scenario in scenarios {
            let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
            try assertQualificationPasses(
                scenario,
                configuration: configuration,
                evaluation: evaluation
            )
            guard let decision = evaluation.decision else {
                XCTFail("Hostile scenario \(scenario.label) did not produce a decision.")
                continue
            }
            try assertHostileExpectation(
                scenario: scenario,
                decision: decision,
                evaluation: evaluation,
                configuration: configuration
            )
        }
    }

    func testPhase10SchedulerQualificationPreemptionReclamationProofUsesReservationAdjustedCapacity() throws {
        let scenarios = try Phase10SchedulerQualificationGenerator.hostileScenarios(
            seed: Phase10SchedulerQualification.defaultSeed
        )
        guard let scenario = scenarios.first(where: { $0.label == "preemption" }) else {
            XCTFail("Hostile scenario generator lost the preemption case.")
            return
        }
        let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
        try assertQualificationPasses(
            scenario,
            configuration: try Phase10SchedulerQualification.Configuration(
                generatedCount: 1,
                exactCount: 1
            ),
            evaluation: evaluation
        )
        XCTAssertEqual(scenario.input.nodes.first?.schedulableCapacity["cpu"], 4)
        XCTAssertFalse(evaluation.issues.contains { $0.kind == .preemption })
        XCTAssertEqual(
            evaluation.decision?.workloadDecisions.first?.outcome,
            .preemptionProposed
        )
    }

    func testPhase10SchedulerQualificationPreemptionOverlapDoesNotReuseVictim() throws {
        let scenario = try XCTUnwrap(
            Phase10SchedulerQualificationGenerator.hostileScenarios(
                seed: Phase10SchedulerQualification.defaultSeed
            ).first { $0.label == "preemption-overlap" }
        )
        let configuration = try Phase10SchedulerQualification.Configuration(
            generatedCount: 1,
            exactCount: 1
        )
        let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
        try assertQualificationPasses(
            scenario,
            configuration: configuration,
            evaluation: evaluation
        )
        let decision = try XCTUnwrap(evaluation.decision)
        let proposals = decision.workloadDecisions.filter {
            $0.outcome == .preemptionProposed
        }
        let unschedulable = decision.workloadDecisions.filter {
            $0.outcome == .unschedulable
        }
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(unschedulable.count, 1)
        let proposedVictimIDs = proposals.flatMap { $0.preemption?.victimWorkloadIDs ?? [] }
        XCTAssertEqual(
            Set(proposedVictimIDs).count,
            proposedVictimIDs.count,
            "A victim must not be reclaimed by more than one pending workload."
        )
        XCTAssertFalse(evaluation.issues.contains { $0.kind == .preemption })
    }

    func testPhase10SchedulerQualificationPreemptionRequiresOptInAndAuthorization() throws {
        let scenario = try XCTUnwrap(
            Phase10SchedulerQualificationGenerator.hostileScenarios(
                seed: Phase10SchedulerQualification.defaultSeed
            ).first { $0.label == "preemption" }
        )
        let workload = try XCTUnwrap(scenario.input.pendingWorkloads.first)
        XCTAssertEqual(workload.preemptionEligibility, .eligible)
        XCTAssertTrue(scenario.input.preemptionPolicy.preemptionAuthorized)
        XCTAssertEqual(
            scenario.input.preemptionPolicy.authorizationReference,
            "phase10-qualification"
        )

        let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
        try assertQualificationPasses(
            scenario,
            configuration: try Phase10SchedulerQualification.Configuration(
                generatedCount: 1,
                exactCount: 1
            ),
            evaluation: evaluation
        )
        XCTAssertFalse(evaluation.issues.contains { $0.kind == .determinism })
        let proposal = try XCTUnwrap(
            evaluation.decision?.workloadDecisions.first?.preemption
        )
        XCTAssertTrue(proposal.requiresFence)
        XCTAssertEqual(
            proposal.policy.authorizationReference,
            scenario.input.preemptionPolicy.authorizationReference
        )

        let defaultWorkload = try SchedulerWorkload(
            requirements: workload.requirements,
            priority: workload.priority,
            subjectID: workload.subjectID,
            projectID: workload.projectID,
            topology: workload.topology,
            locality: workload.locality,
            disruption: workload.disruption,
            constraints: workload.constraints,
            overhead: workload.overhead,
            safetyMargin: workload.safetyMargin,
            binClass: workload.binClass
        )
        XCTAssertEqual(defaultWorkload.preemptionEligibility, .nonPreempting)
        let defaultInput = try SchedulerEngineInput(
            pendingWorkloads: [defaultWorkload],
            nodes: scenario.input.nodes,
            victimAllocations: scenario.input.victimAllocations,
            disruptionBudgets: scenario.input.disruptionBudgets,
            preemptionPolicy: scenario.input.preemptionPolicy
        )
        let defaultScenario = Phase10SchedulerQualification.Scenario(
            label: "preemption-default-non-preempting",
            seed: scenario.seed,
            input: defaultInput,
            oracleMode: .none
        )
        let defaultEvaluation = Phase10SchedulerQualificationVerifier.evaluate(defaultScenario)
        try assertQualificationPasses(
            defaultScenario,
            configuration: try Phase10SchedulerQualification.Configuration(
                generatedCount: 1,
                exactCount: 1
            ),
            evaluation: defaultEvaluation
        )
        let defaultDecision = try XCTUnwrap(defaultEvaluation.decision)
        let defaultWorkloadDecision = try XCTUnwrap(
            defaultDecision.workloadDecisions.first
        )
        XCTAssertEqual(defaultWorkloadDecision.outcome, .unschedulable)
        XCTAssertTrue(
            defaultWorkloadDecision.filterFailures.contains {
                $0.code == .preemptionWorkloadNotEligible
            }
        )

        XCTAssertThrowsError(
            try SchedulerPreemptionPolicy(preemptionAuthorized: true)
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .invalidDecision("preemption-authorization-reference-required")
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decodedInput = try JSONDecoder().decode(
            SchedulerEngineInput.self,
            from: encoder.encode(defaultInput)
        )
        XCTAssertEqual(decodedInput, defaultInput)
        XCTAssertEqual(
            decodedInput.preemptionPolicy.authorizationReference,
            "phase10-qualification"
        )
        XCTAssertEqual(
            decodedInput.pendingWorkloads.first?.preemptionEligibility,
            .nonPreempting
        )
        let decodedAuthorizedInput = try JSONDecoder().decode(
            SchedulerEngineInput.self,
            from: encoder.encode(scenario.input)
        )
        XCTAssertEqual(
            decodedAuthorizedInput.pendingWorkloads.first?.preemptionEligibility,
            .eligible
        )
        XCTAssertEqual(
            decodedAuthorizedInput.preemptionPolicy.authorizationReference,
            "phase10-qualification"
        )
    }

    func testPhase10SchedulerQualificationExactPreemptionRespectsHardTopologyAndBudget() throws {
        let seed = Phase10SchedulerQualification.defaultSeed &+ 0x820
        let rejected = try Phase10SchedulerQualificationGenerator
            .exactPreemptionHardTopologyScenario(seed: seed)
        let rejectedEvaluation = Phase10SchedulerQualificationVerifier.evaluate(rejected)
        try assertQualificationPasses(
            rejected,
            configuration: try Phase10SchedulerQualification.Configuration(
                generatedCount: 1,
                exactCount: 1
            ),
            evaluation: rejectedEvaluation
        )
        let rejectedDecision = try XCTUnwrap(rejectedEvaluation.decision?.workloadDecisions.first)
        XCTAssertEqual(rejectedDecision.outcome, .unschedulable)
        XCTAssertNil(
            rejectedDecision.preemption,
            "Exact preemption must not relax a hard topology spread after victim removal."
        )

        let feasible = try Phase10SchedulerQualificationGenerator
            .exactPreemptionHardTopologyScenario(seed: seed &+ 1, maxSkew: 2)
        let feasibleEvaluation = Phase10SchedulerQualificationVerifier.evaluate(feasible)
        try assertQualificationPasses(
            feasible,
            configuration: try Phase10SchedulerQualification.Configuration(
                generatedCount: 1,
                exactCount: 1
            ),
            evaluation: feasibleEvaluation
        )
        let feasibleDecision = try XCTUnwrap(feasibleEvaluation.decision?.workloadDecisions.first)
        XCTAssertEqual(feasibleDecision.outcome, .preemptionProposed)
        let feasibleProposal = try XCTUnwrap(feasibleDecision.preemption)
        XCTAssertEqual(feasibleProposal.victims.count, 1)
        XCTAssertEqual(feasibleProposal.victims.first?.budgetID, "budget-exact")
        XCTAssertEqual(feasibleProposal.disruptionCostBasisPoints, 3)
        XCTAssertFalse(feasibleEvaluation.issues.contains { $0.kind == .preemption })

        let exhausted = try Phase10SchedulerQualificationGenerator
            .exactPreemptionHardTopologyScenario(
                seed: seed &+ 2,
                maxSkew: 2,
                remainingVictimCount: 0,
                remainingDisruptionCostBasisPoints: 0
            )
        let exhaustedEvaluation = Phase10SchedulerQualificationVerifier.evaluate(exhausted)
        try assertQualificationPasses(
            exhausted,
            configuration: try Phase10SchedulerQualification.Configuration(
                generatedCount: 1,
                exactCount: 1
            ),
            evaluation: exhaustedEvaluation
        )
        let exhaustedDecision = try XCTUnwrap(
            exhaustedEvaluation.decision?.workloadDecisions.first
        )
        XCTAssertEqual(exhaustedDecision.outcome, .unschedulable)
        XCTAssertNil(
            exhaustedDecision.preemption,
            "Exact preemption must not bypass an exhausted disruption budget."
        )
    }

    func testPhase10SchedulerQualificationDefaultReplayFixtureIsRetained() throws {
        let configuration = try Phase10SchedulerQualification.Configuration()
        let scenario = try Phase10SchedulerQualificationGenerator.exactScenario(
            index: 0,
            seed: Phase10SchedulerQualification.defaultSeed
        )
        let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
        let receipt = try emitTestReplay(
            scenario: scenario,
            evaluation: evaluation,
            configuration: configuration
        )
        let fileURL = URL(fileURLWithPath: receipt.location)
        let ownedRunDirectory = fileURL.deletingLastPathComponent()
        defer {
            try? FileManager.default.removeItem(at: ownedRunDirectory)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: ownedRunDirectory.path),
                "Only the unique Phase10 run child may be cleaned up."
            )
        }

        XCTAssertFalse(receipt.retained)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(fileURL.path.contains("HostwrightPhase10SchedulerQualification/replays/run-"))
    }

    func testPhase10SchedulerQualificationReplayMetadataIsDeterministicAndRetained() throws {
        let configuration = try Phase10SchedulerQualification.Configuration()
        let scenario = try Phase10SchedulerQualificationGenerator.exactScenario(
            index: 3,
            seed: Phase10SchedulerQualification.defaultSeed
        )
        let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
        let first = try emitTestReplay(
            scenario: scenario,
            evaluation: evaluation,
            configuration: configuration
        )
        let second = try emitTestReplay(
            scenario: scenario,
            evaluation: evaluation,
            configuration: configuration
        )
        let firstURL = URL(fileURLWithPath: first.location)
        let secondURL = URL(fileURLWithPath: second.location)
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let firstData = try Data(contentsOf: firstURL)
        let secondData = try Data(contentsOf: secondURL)
        XCTAssertFalse(first.retained)
        XCTAssertFalse(second.retained)
        XCTAssertEqual(first.byteCount, firstData.count)
        XCTAssertEqual(second.byteCount, secondData.count)
        XCTAssertEqual(firstURL.lastPathComponent, secondURL.lastPathComponent)
        XCTAssertEqual(firstData, secondData)

        let fixture = try JSONDecoder().decode(
            Phase10SchedulerQualificationArtifacts.ReplayFixture.self,
            from: firstData
        )
        XCTAssertEqual(fixture.schema, "hostwright.phase10.scheduler.qualification.replay.v1")
        XCTAssertEqual(fixture.original.seed, scenario.seed)
        XCTAssertEqual(fixture.minimized.seed, scenario.seed)
        XCTAssertEqual(fixture.original.input.inputDigest, scenario.input.inputDigest)
        XCTAssertEqual(fixture.minimized.input.inputDigest, scenario.input.inputDigest)
        XCTAssertEqual(fixture.issue.kind, .harnessError)
    }

    func testPhase10SchedulerQualificationExplicitRootUsesOwnedChild() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Phase10SchedulerQualificationExplicitRoot-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )
        let callerOwnedSentinel = parent.appendingPathComponent("caller-owned.txt")
        try Data("caller-owned".utf8).write(to: callerOwnedSentinel)
        let configuration = try Phase10SchedulerQualification.Configuration(
            explicitOutputRoot: parent
        )
        let scenario = try Phase10SchedulerQualificationGenerator.exactScenario(
            index: 1,
            seed: Phase10SchedulerQualification.defaultSeed
        )
        let receipt = try emitTestReplay(
            scenario: scenario,
            evaluation: Phase10SchedulerQualificationVerifier.evaluate(scenario),
            configuration: configuration
        )
        let fileURL = URL(fileURLWithPath: receipt.location)
        let expectedPrefix = parent
            .appendingPathComponent("Phase10SchedulerQualification", isDirectory: true)
            .path + "/run-"

        XCTAssertTrue(receipt.retained)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(fileURL.path.hasPrefix(expectedPrefix))
        XCTAssertNotEqual(fileURL.deletingLastPathComponent(), parent)

        try FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: callerOwnedSentinel.path),
            "Phase10 cleanup must not remove caller-owned parent contents."
        )
    }

    func testPhase10SchedulerQualificationRejectsDisallowedOutputRoots() {
        for path in [
            "/tmp/evidence",
            "/tmp/hostwright-phase08",
            "/tmp/hostwright-phase09",
            "/Users/dev/Documents/hostwright-phase10/unowned-phase10-output"
        ] {
            XCTAssertThrowsError(
                try Phase10SchedulerQualification.Configuration(
                    explicitOutputRoot: URL(fileURLWithPath: path, isDirectory: true)
                )
            )
        }
    }

    func testPhase10SchedulerQualificationRejectsSymlinkAndMissingOutputRoots() throws {
        let actual = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Phase10SchedulerQualificationActual-\(UUID().uuidString)",
            isDirectory: true
        )
        let symlink = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Phase10SchedulerQualificationSymlink-\(UUID().uuidString)",
            isDirectory: true
        )
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Phase10SchedulerQualificationMissing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("child", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: symlink)
            try? FileManager.default.removeItem(at: actual)
        }
        try FileManager.default.createDirectory(
            at: actual,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: actual
        )
        XCTAssertThrowsError(
            try Phase10SchedulerQualification.Configuration(explicitOutputRoot: symlink)
        )
        XCTAssertThrowsError(
            try Phase10SchedulerQualification.Configuration(explicitOutputRoot: missing)
        )
    }

    func testPhase10SchedulerQualificationAllowsOwnedDurableClosureRoot() throws {
        let configuration = try Phase10SchedulerQualification.Configuration(
            explicitOutputRoot: Phase10SchedulerQualification.Configuration.ownedDurableOutputRoot
        )
        XCTAssertEqual(
            configuration.outputRootIdentity,
            Phase10SchedulerQualification.Configuration.ownedDurableOutputRoot.standardizedFileURL.path
        )
    }

    func testPhase10SchedulerQualificationRejectsNonPrivateTemporaryRoot() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Phase10SchedulerQualificationWorldReadable-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        XCTAssertThrowsError(
            try Phase10SchedulerQualification.Configuration(explicitOutputRoot: parent)
        )
    }

    func testPhase10SchedulerQualificationGeneratedReceiptLeavesOracleDomainNilForMixedCases() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Phase10SchedulerQualificationGeneratedReceipt-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let configuration = try Phase10SchedulerQualification.Configuration(
            generatedCount: 9,
            exactCount: 1,
            explicitOutputRoot: parent
        )
        var builder = Phase10SchedulerQualificationRunReceiptBuilder(
            cell: .generatedInvariant,
            testName: "testPhase10SchedulerQualificationSeededInvariantSmoke",
            seed: configuration.seed,
            caseCount: configuration.generatedCount,
            configuration: configuration
        )
        for index in 0..<configuration.generatedCount {
            let scenario = try Phase10SchedulerQualificationGenerator.generatedScenario(
                index: index,
                seed: configuration.seed
            )
            let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
            let metrics = try assertQualificationPasses(
                scenario,
                configuration: configuration,
                evaluation: evaluation,
                caseIndex: index
            )
            try builder.append(
                index: index,
                scenario: scenario,
                evaluation: evaluation,
                metrics: metrics
            )
        }
        let session = try builder.makePreparedReceipt(elapsedSeconds: 0.1)
        XCTAssertNil(
            session.record.oracleDomain,
            "generated receipts may include per-case oracle diagnostics but must not claim the exact-oracle root domain"
        )
        XCTAssertNoThrow(
            try session.record.validate(
                allowPreCommitReplayPaths: true,
                requirePathIdentities: false
            )
        )
        let receipt = try Phase10SchedulerQualificationArtifacts.emitQualificationReceipt(
            session,
            configuration: configuration
        )
        XCTAssertTrue(receipt.retained)
    }

    func testPhase10SchedulerQualificationCommittedReplayFilenamesRemainCanonicalOrdered() {
        let filenames = (0..<128).map {
            Phase10SchedulerQualificationArtifacts.committedReplayFilename(
                index: $0,
                sourceName: "fixture.json"
            )
        }
        XCTAssertEqual(filenames, filenames.sorted())
        XCTAssertEqual(filenames[2], "replay-00000002-fixture.json")
        XCTAssertEqual(filenames[10], "replay-00000010-fixture.json")
    }

    func testPhase10SchedulerQualificationRunReceiptRoundTripsAndBinds() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Phase10SchedulerQualificationReceipt-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let configuration = try Phase10SchedulerQualification.Configuration(
            seed: Phase10SchedulerQualification.defaultSeed,
            generatedCount: 2,
            exactCount: 1,
            explicitOutputRoot: parent
        )
        let fingerprint = String(repeating: "a", count: 64)
        let fixture = Phase10SchedulerQualificationReplayEntry(
            relativePath: "Phase10SchedulerQualification/run-test/replay.json",
            sha256: fingerprint,
            byteCount: 12,
            issueKind: "intentionalOptimizationGap",
            severity: "diagnostic",
            scenarioSeed: configuration.seed,
            inputFingerprint: fingerprint,
            caseIndex: 0,
            oracleDomain: Phase10SchedulerQualificationExactOracle.domain
        )
        let record = Phase10SchedulerQualificationRunReceipt(
            schema: Phase10SchedulerQualificationRunReceipt.schema,
            cell: .exactOracle,
            testName: "testPhase10SchedulerQualificationExactMultiResourceFeasibilityOracleSmoke",
            seed: configuration.seed,
            caseCount: configuration.exactCount,
            oracleDomain: "multi-resource(cpu,memory,disk)-hard-capacity-feasibility",
            configuration: Phase10SchedulerQualificationReceiptConfiguration(configuration),
            directTest: Phase10SchedulerQualificationDirectTestOutcome(
                status: "passed",
                testCount: 1,
                failedTestCount: 0,
                assertionFailureCount: 0,
                skippedTestCount: 0,
                elapsedSeconds: 0.5
            ),
            sourceFingerprint: fingerprint,
            inputFingerprint: fingerprint,
            buildFingerprint: fingerprint,
            safetyMismatchCount: 0,
            optimizationGapCount: 1,
            caseInputFingerprints: [fingerprint],
            replayFixtures: [fixture],
            outputRootIdentity: configuration.outputRootIdentity,
            runDirectoryIdentity: "Phase10SchedulerQualification/run-test",
            outputRootPathIdentity: Phase10SchedulerQualificationPathIdentity.placeholder(
                path: configuration.outputRootIdentity
            ),
            runDirectoryPathIdentity: Phase10SchedulerQualificationPathIdentity.placeholder(
                path: configuration.outputRootIdentity
                    + "/Phase10SchedulerQualification/run-test"
            ),
            cleanupScopeVerified: true
        )
        try record.validate()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(record)
        let decoded = try JSONDecoder().decode(
            Phase10SchedulerQualificationRunReceipt.self,
            from: encoded
        )
        XCTAssertEqual(encoded, try encoder.encode(decoded))
        try decoded.verifyBinding(
            expectedSourceFingerprint: fingerprint,
            expectedInputFingerprint: fingerprint,
            expectedBuildFingerprint: fingerprint,
            expectedOutputRootIdentity: configuration.outputRootIdentity
        )
    }

    func testPhase10SchedulerQualificationRunReceiptRejectsTamperedBinding() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Phase10SchedulerQualificationReceiptTamper-" + UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let configuration = try Phase10SchedulerQualification.Configuration(
            generatedCount: 1,
            exactCount: 1,
            explicitOutputRoot: parent
        )
        let fingerprint = String(repeating: "b", count: 64)
        let record = Phase10SchedulerQualificationRunReceipt(
            schema: Phase10SchedulerQualificationRunReceipt.schema,
            cell: .generatedInvariant,
            testName: "testPhase10SchedulerQualificationSeededInvariantSmoke",
            seed: configuration.seed,
            caseCount: 1,
            oracleDomain: nil,
            configuration: Phase10SchedulerQualificationReceiptConfiguration(configuration),
            directTest: Phase10SchedulerQualificationDirectTestOutcome(
                status: "passed",
                testCount: 1,
                failedTestCount: 0,
                assertionFailureCount: 0,
                skippedTestCount: 0,
                elapsedSeconds: 0.1
            ),
            sourceFingerprint: fingerprint,
            inputFingerprint: fingerprint,
            buildFingerprint: fingerprint,
            safetyMismatchCount: 0,
            optimizationGapCount: 0,
            caseInputFingerprints: [fingerprint],
            replayFixtures: [],
            outputRootIdentity: configuration.outputRootIdentity,
            runDirectoryIdentity: "Phase10SchedulerQualification/run-test",
            outputRootPathIdentity: Phase10SchedulerQualificationPathIdentity.placeholder(
                path: configuration.outputRootIdentity
            ),
            runDirectoryPathIdentity: Phase10SchedulerQualificationPathIdentity.placeholder(
                path: configuration.outputRootIdentity
                    + "/Phase10SchedulerQualification/run-test"
            ),
            cleanupScopeVerified: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(record)) as? [String: Any]
        )
        object["inputFingerprint"] = "tampered"
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationRunReceipt.decodeStrict(from: tampered)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("fingerprint"),
                error.localizedDescription
            )
        }
    }

    func testPhase10SchedulerQualificationRunReceiptRejectsCrossFieldDrift() throws {
        let configuration = try Phase10SchedulerQualification.Configuration(
            generatedCount: 1,
            exactCount: 1,
            explicitOutputRoot: Phase10SchedulerQualification.Configuration.ownedDurableOutputRoot
        )
        let fingerprint = String(repeating: "c", count: 64)
        let record = Phase10SchedulerQualificationRunReceipt(
            schema: Phase10SchedulerQualificationRunReceipt.schema,
            cell: .generatedInvariant,
            testName: "testPhase10SchedulerQualificationSeededInvariantSmoke",
            seed: configuration.seed,
            caseCount: 1,
            oracleDomain: nil,
            configuration: Phase10SchedulerQualificationReceiptConfiguration(configuration),
            directTest: Phase10SchedulerQualificationDirectTestOutcome(
                status: "passed",
                testCount: 1,
                failedTestCount: 0,
                assertionFailureCount: 0,
                skippedTestCount: 0,
                elapsedSeconds: 0
            ),
            sourceFingerprint: fingerprint,
            inputFingerprint: fingerprint,
            buildFingerprint: fingerprint,
            safetyMismatchCount: 0,
            optimizationGapCount: 0,
            caseInputFingerprints: [fingerprint],
            replayFixtures: [],
            outputRootIdentity: configuration.outputRootIdentity,
            runDirectoryIdentity: "Phase10SchedulerQualification/run-test",
            outputRootPathIdentity: Phase10SchedulerQualificationPathIdentity.placeholder(
                path: configuration.outputRootIdentity
            ),
            runDirectoryPathIdentity: Phase10SchedulerQualificationPathIdentity.placeholder(
                path: configuration.outputRootIdentity
                    + "/Phase10SchedulerQualification/run-test"
            ),
            cleanupScopeVerified: true
        )
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(record)) as? [String: Any]
        )
        object["caseCount"] = 2
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                Phase10SchedulerQualificationRunReceipt.self,
                from: tampered
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("cell, test name, seed"))
        }
    }

    func testPhase10SchedulerQualificationRunReceiptRejectsDuplicateReplayBinding() throws {
        let configuration = try Phase10SchedulerQualification.Configuration(
            generatedCount: 1,
            exactCount: 1,
            explicitOutputRoot: Phase10SchedulerQualification.Configuration.ownedDurableOutputRoot
        )
        let fingerprint = String(repeating: "f", count: 64)
        func entry(_ name: String) -> Phase10SchedulerQualificationReplayEntry {
            Phase10SchedulerQualificationReplayEntry(
                relativePath: "Phase10SchedulerQualification/run-test/\(name)",
                sha256: fingerprint,
                byteCount: 10,
                issueKind: "harnessError",
                severity: "failure",
                scenarioSeed: configuration.seed,
                inputFingerprint: fingerprint,
                caseIndex: 0
            )
        }
        let record = Phase10SchedulerQualificationRunReceipt(
            schema: Phase10SchedulerQualificationRunReceipt.schema,
            cell: .generatedInvariant,
            testName: "testPhase10SchedulerQualificationSeededInvariantSmoke",
            seed: configuration.seed,
            caseCount: 1,
            oracleDomain: nil,
            configuration: Phase10SchedulerQualificationReceiptConfiguration(configuration),
            directTest: Phase10SchedulerQualificationDirectTestOutcome(
                status: "failed",
                testCount: 1,
                failedTestCount: 1,
                assertionFailureCount: 2,
                skippedTestCount: 0,
                elapsedSeconds: 0
            ),
            sourceFingerprint: fingerprint,
            inputFingerprint: fingerprint,
            buildFingerprint: fingerprint,
            safetyMismatchCount: 2,
            optimizationGapCount: 0,
            caseInputFingerprints: [fingerprint],
            replayFixtures: [entry("replay-0.json"), entry("replay-1.json")],
            outputRootIdentity: configuration.outputRootIdentity,
            runDirectoryIdentity: "Phase10SchedulerQualification/run-test",
            outputRootPathIdentity: Phase10SchedulerQualificationPathIdentity.placeholder(
                path: configuration.outputRootIdentity
            ),
            runDirectoryPathIdentity: Phase10SchedulerQualificationPathIdentity.placeholder(
                path: configuration.outputRootIdentity
                    + "/Phase10SchedulerQualification/run-test"
            ),
            cleanupScopeVerified: true
        )
        XCTAssertThrowsError(try record.validate())
    }

    func testPhase10SchedulerQualificationRunReceiptRejectsAbsoluteReplayPath() throws {
        let configuration = try Phase10SchedulerQualification.Configuration(
            generatedCount: 1,
            exactCount: 1,
            explicitOutputRoot: Phase10SchedulerQualification.Configuration.ownedDurableOutputRoot
        )
        let fingerprint = String(repeating: "d", count: 64)
        let fixture = Phase10SchedulerQualificationReplayEntry(
            relativePath: "Phase10SchedulerQualification/run-test/replay.json",
            sha256: fingerprint,
            byteCount: 1,
            issueKind: "harnessError",
            severity: "failure",
            scenarioSeed: configuration.seed,
            inputFingerprint: fingerprint,
            caseIndex: 0
        )
        let record = Phase10SchedulerQualificationRunReceipt(
            schema: Phase10SchedulerQualificationRunReceipt.schema,
            cell: .generatedInvariant,
            testName: "testPhase10SchedulerQualificationSeededInvariantSmoke",
            seed: configuration.seed,
            caseCount: 1,
            oracleDomain: nil,
            configuration: Phase10SchedulerQualificationReceiptConfiguration(configuration),
            directTest: Phase10SchedulerQualificationDirectTestOutcome(
                status: "failed",
                testCount: 1,
                failedTestCount: 1,
                assertionFailureCount: 1,
                skippedTestCount: 0,
                elapsedSeconds: 0
            ),
            sourceFingerprint: fingerprint,
            inputFingerprint: fingerprint,
            buildFingerprint: fingerprint,
            safetyMismatchCount: 1,
            optimizationGapCount: 0,
            caseInputFingerprints: [fingerprint],
            replayFixtures: [fixture],
            outputRootIdentity: configuration.outputRootIdentity,
            runDirectoryIdentity: "Phase10SchedulerQualification/run-test",
            outputRootPathIdentity: Phase10SchedulerQualificationPathIdentity.placeholder(
                path: configuration.outputRootIdentity
            ),
            runDirectoryPathIdentity: Phase10SchedulerQualificationPathIdentity.placeholder(
                path: configuration.outputRootIdentity
                    + "/Phase10SchedulerQualification/run-test"
            ),
            cleanupScopeVerified: true
        )
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(record)) as? [String: Any]
        )
        var fixtures = try XCTUnwrap(object["replayFixtures"] as? [[String: Any]])
        fixtures[0]["relativePath"] = "/tmp/replay.json"
        object["replayFixtures"] = fixtures
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                Phase10SchedulerQualificationRunReceipt.self,
                from: tampered
            )
        ) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testPhase10SchedulerQualificationRunReceiptRechecksReplayHashAndBytes() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Phase10SchedulerQualificationReplayHash-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fixtureURL = parent
            .appendingPathComponent("Phase10SchedulerQualification", isDirectory: true)
            .appendingPathComponent("run-test", isDirectory: true)
            .appendingPathComponent("replay.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: fixtureURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let bytes = Data("actual".utf8)
        try bytes.write(to: fixtureURL)
        let configuration = try Phase10SchedulerQualification.Configuration(
            generatedCount: 1,
            exactCount: 1,
            explicitOutputRoot: parent
        )
        let fingerprint = String(repeating: "e", count: 64)
        let record = Phase10SchedulerQualificationRunReceipt(
            schema: Phase10SchedulerQualificationRunReceipt.schema,
            cell: .generatedInvariant,
            testName: "testPhase10SchedulerQualificationSeededInvariantSmoke",
            seed: configuration.seed,
            caseCount: 1,
            oracleDomain: nil,
            configuration: Phase10SchedulerQualificationReceiptConfiguration(configuration),
            directTest: Phase10SchedulerQualificationDirectTestOutcome(
                status: "failed",
                testCount: 1,
                failedTestCount: 1,
                assertionFailureCount: 1,
                skippedTestCount: 0,
                elapsedSeconds: 0
            ),
            sourceFingerprint: fingerprint,
            inputFingerprint: fingerprint,
            buildFingerprint: fingerprint,
            safetyMismatchCount: 1,
            optimizationGapCount: 0,
            caseInputFingerprints: [fingerprint],
            replayFixtures: [
                Phase10SchedulerQualificationReplayEntry(
                    relativePath: "Phase10SchedulerQualification/run-test/replay.json",
                    sha256: fingerprint,
                    byteCount: bytes.count,
                    issueKind: "harnessError",
                    severity: "failure",
                    scenarioSeed: configuration.seed,
                    inputFingerprint: fingerprint,
                    caseIndex: 0
                )
            ],
            outputRootIdentity: configuration.outputRootIdentity,
            runDirectoryIdentity: "Phase10SchedulerQualification/run-test",
            outputRootPathIdentity: Phase10SchedulerQualificationPathIdentity.placeholder(
                path: configuration.outputRootIdentity
            ),
            runDirectoryPathIdentity: Phase10SchedulerQualificationPathIdentity.placeholder(
                path: configuration.outputRootIdentity
                    + "/Phase10SchedulerQualification/run-test"
            ),
            cleanupScopeVerified: true
        )
        try record.validate()
        XCTAssertThrowsError(try record.verifyReplayFiles(at: parent)) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testPhase10SchedulerQualificationRunInputFingerprintIsDeterministic() throws {
        let first = try Phase10SchedulerQualificationGenerator.generatedScenario(
            index: 0,
            seed: Phase10SchedulerQualification.defaultSeed
        )
        let second = try Phase10SchedulerQualificationGenerator.generatedScenario(
            index: 1,
            seed: Phase10SchedulerQualification.defaultSeed
        )
        var left = Phase10SchedulerQualificationInputFingerprintAccumulator(
            cell: .generatedInvariant,
            seed: Phase10SchedulerQualification.defaultSeed,
            caseCount: 2
        )
        try left.append(index: 0, scenario: first)
        try left.append(index: 1, scenario: second)
        let leftDigest = left.finalize()
        var right = Phase10SchedulerQualificationInputFingerprintAccumulator(
            cell: .generatedInvariant,
            seed: Phase10SchedulerQualification.defaultSeed,
            caseCount: 2
        )
        try right.append(index: 0, scenario: first)
        try right.append(index: 1, scenario: second)
        XCTAssertEqual(leftDigest, right.finalize())
    }

    func testPhase10SchedulerQualificationReferenceGateRequiresRetainedOutputRoot() throws {
        XCTAssertThrowsError(
            try Phase10SchedulerQualification.Configuration(
                performanceEnabled: true,
                referenceMacGateEnabled: true,
                referenceMacID: "reference-mac"
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("explicit retained Phase 10 output root"))
        }

        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Phase10SchedulerQualificationReferenceRoot-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertThrowsError(
            try Phase10SchedulerQualification.Configuration(
                performanceEnabled: false,
                referenceMacGateEnabled: true,
                referenceMacID: "reference-mac",
                explicitOutputRoot: parent
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("performance cell"))
        }
        XCTAssertThrowsError(
            try Phase10SchedulerQualification.Configuration(
                referenceMacID: "orphan-reference-mac",
                explicitOutputRoot: parent
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("disabled reference-Mac"))
        }
        let configuration = try Phase10SchedulerQualification.Configuration(
            performanceEnabled: true,
            referenceMacGateEnabled: true,
            referenceMacID: "reference-mac",
            explicitOutputRoot: parent
        )
        XCTAssertTrue(configuration.hasQualifiedReferenceMacGate)
        XCTAssertEqual(configuration.explicitOutputRoot, parent)

        let receiptConfiguration = Phase10SchedulerQualificationReceiptConfiguration(configuration)
        try receiptConfiguration.validate()
        let encoder = JSONEncoder()
        var disabledPerformance = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(receiptConfiguration))
                as? [String: Any]
        )
        disabledPerformance["performanceEnabled"] = false
        let decodedDisabled = try JSONDecoder().decode(
            Phase10SchedulerQualificationReceiptConfiguration.self,
            from: JSONSerialization.data(
                withJSONObject: disabledPerformance,
                options: [.sortedKeys]
            )
        )
        XCTAssertThrowsError(try decodedDisabled.validate())

        var orphanIdentifier = disabledPerformance
        orphanIdentifier["performanceEnabled"] = true
        orphanIdentifier["referenceMacGateEnabled"] = false
        let decodedOrphan = try JSONDecoder().decode(
            Phase10SchedulerQualificationReceiptConfiguration.self,
            from: JSONSerialization.data(
                withJSONObject: orphanIdentifier,
                options: [.sortedKeys]
            )
        )
        XCTAssertThrowsError(try decodedOrphan.validate())
    }

    func testPhase10SchedulerQualificationPerformanceRecordCarriesReferenceIdentity() throws {
        let identity = "clean-reference-mac-2026-08-05"
        let sourceFingerprint = String(repeating: "a", count: 64)
        let inputFingerprint = String(repeating: "b", count: 64)
        let buildFingerprint = String(repeating: "c", count: 64)
        let record = Phase10SchedulerQualificationPerformance.Record(
            schema: Phase10SchedulerQualificationPerformance.recordSchema,
            hardware: "Mac15,7",
            operatingSystem: "macOS 26.0",
            swiftVersion: "Swift 6.2",
            seed: Phase10SchedulerQualification.defaultSeed,
            pendingWorkloads: 1_000,
            nodes: 100,
            repeats: 7,
            samplesSeconds: [0.25, 0.26, 0.24, 0.27, 0.25, 0.23, 0.22],
            p95Seconds: 0.27,
            referenceMacGateEnabled: true,
            referenceMacID: identity,
            thresholdEnforced: true,
            sourceFingerprint: sourceFingerprint,
            inputFingerprint: inputFingerprint,
            buildFingerprint: buildFingerprint
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(record)
        let decoded = try JSONDecoder().decode(
            Phase10SchedulerQualificationPerformance.Record.self,
            from: encoded
        )
        XCTAssertEqual(encoded, try encoder.encode(decoded))

        XCTAssertEqual(decoded.referenceMacID, identity)
        XCTAssertTrue(decoded.referenceMacGateEnabled)
        XCTAssertTrue(decoded.thresholdEnforced)
        XCTAssertEqual(decoded.hardware, "Mac15,7")
        XCTAssertEqual(decoded.operatingSystem, "macOS 26.0")
        XCTAssertEqual(decoded.swiftVersion, "Swift 6.2")
        XCTAssertEqual(decoded.sourceFingerprint, sourceFingerprint)
        XCTAssertEqual(decoded.inputFingerprint, inputFingerprint)
        XCTAssertEqual(decoded.buildFingerprint, buildFingerprint)
        try decoded.verifyBinding(
            expectedInputFingerprint: inputFingerprint,
            expectedSourceFingerprint: sourceFingerprint,
            expectedBuildFingerprint: buildFingerprint
        )

        let orphanIdentifier = Phase10SchedulerQualificationPerformance.Record(
            schema: Phase10SchedulerQualificationPerformance.recordSchema,
            hardware: "Mac15,7",
            operatingSystem: "macOS 26.0",
            swiftVersion: "Swift 6.2",
            seed: Phase10SchedulerQualification.defaultSeed,
            pendingWorkloads: 1_000,
            nodes: 100,
            repeats: 7,
            samplesSeconds: [0.25, 0.26, 0.24, 0.27, 0.25, 0.23, 0.22],
            p95Seconds: 0.27,
            referenceMacGateEnabled: false,
            referenceMacID: identity,
            thresholdEnforced: false,
            sourceFingerprint: sourceFingerprint,
            inputFingerprint: inputFingerprint,
            buildFingerprint: buildFingerprint
        )
        XCTAssertThrowsError(try orphanIdentifier.validate())
    }

    func testPhase10SchedulerQualificationPerformanceDecodeRechecksCurrentBinding() throws {
        let input = try Phase10SchedulerQualificationGenerator.performanceInput(
            seed: Phase10SchedulerQualification.defaultSeed
        )
        let operatingSystem = Phase10SchedulerQualificationPerformance.currentOperatingSystemDescription()
        let swiftVersion = Phase10SchedulerQualificationPerformance.swiftDescriptionForReceipt()
        let sourceFingerprint = try Phase10SchedulerQualificationPerformance.Fingerprints.sourceFingerprint()
        let buildFingerprint = try Phase10SchedulerQualificationPerformance.Fingerprints.buildFingerprint(
            swiftVersion: swiftVersion,
            operatingSystem: operatingSystem
        )
        let record = Phase10SchedulerQualificationPerformance.Record(
            schema: Phase10SchedulerQualificationPerformance.recordSchema,
            hardware: Phase10SchedulerQualificationPerformance.currentHardwareDescription(),
            operatingSystem: operatingSystem,
            swiftVersion: swiftVersion,
            seed: Phase10SchedulerQualification.defaultSeed,
            pendingWorkloads: 1_000,
            nodes: 100,
            repeats: 7,
            samplesSeconds: [0.25, 0.26, 0.24, 0.27, 0.25, 0.23, 0.22],
            p95Seconds: 0.27,
            referenceMacGateEnabled: false,
            referenceMacID: nil,
            thresholdEnforced: false,
            sourceFingerprint: sourceFingerprint,
            inputFingerprint: input.inputDigest,
            buildFingerprint: buildFingerprint
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(record)
        XCTAssertNoThrow(
            try Phase10SchedulerQualificationPerformance.Record.decodeStrict(from: encoded)
        )

        for (field, value) in [
            ("sourceFingerprint", String(repeating: "1", count: 64)),
            ("inputFingerprint", String(repeating: "2", count: 64)),
            ("buildFingerprint", String(repeating: "3", count: 64)),
            ("hardware", "forged-hardware")
        ] {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            object[field] = value
            let tampered = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            XCTAssertThrowsError(
                try Phase10SchedulerQualificationPerformance.Record.decodeStrict(from: tampered),
                "decodeStrict must recompute the current (field) binding"
            )
        }

        var orphanIdentifier = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        orphanIdentifier["referenceMacID"] = "orphan-reference-mac"
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationPerformance.Record.decodeStrict(
                from: JSONSerialization.data(
                    withJSONObject: orphanIdentifier,
                    options: [.sortedKeys]
                )
            )
        )
    }

    func testPhase10SchedulerQualificationPerformanceCommittedArtifactBindsMeasurementTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Phase10SchedulerQualificationPerformanceCommit-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let input = try Phase10SchedulerQualificationGenerator.performanceInput(
            seed: Phase10SchedulerQualification.defaultSeed
        )
        let operatingSystem = Phase10SchedulerQualificationPerformance.currentOperatingSystemDescription()
        let swiftVersion = Phase10SchedulerQualificationPerformance.swiftDescriptionForReceipt()
        let sourceFingerprint = try Phase10SchedulerQualificationPerformance.Fingerprints.sourceFingerprint()
        let buildFingerprint = try Phase10SchedulerQualificationPerformance.Fingerprints.buildFingerprint(
            swiftVersion: swiftVersion,
            operatingSystem: operatingSystem
        )
        let record = Phase10SchedulerQualificationPerformance.Record(
            schema: Phase10SchedulerQualificationPerformance.recordSchema,
            hardware: Phase10SchedulerQualificationPerformance.currentHardwareDescription(),
            operatingSystem: operatingSystem,
            swiftVersion: swiftVersion,
            seed: Phase10SchedulerQualification.defaultSeed,
            pendingWorkloads: 1_000,
            nodes: 100,
            repeats: 7,
            samplesSeconds: [0.25, 0.26, 0.24, 0.27, 0.25, 0.23, 0.22],
            p95Seconds: 0.27,
            referenceMacGateEnabled: false,
            referenceMacID: nil,
            thresholdEnforced: false,
            sourceFingerprint: sourceFingerprint,
            inputFingerprint: input.inputDigest,
            buildFingerprint: buildFingerprint
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let recordData = try encoder.encode(record)
        let transcript = Phase10SchedulerQualificationPerformance.MeasurementTranscript(
            record: record,
            samplesSeconds: record.samplesSeconds
        )
        let transcriptData = try encoder.encode(transcript)
        let runDirectory = root
            .appendingPathComponent("Phase10SchedulerQualification", isDirectory: true)
            .appendingPathComponent("run-commit-test", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let recordURL = runDirectory.appendingPathComponent("performance.json", isDirectory: false)
        try recordData.write(to: recordURL, options: .atomic)
        let transcriptURL = runDirectory.appendingPathComponent(
            "performance-transcript.json",
            isDirectory: false
        )
        try transcriptData.write(to: transcriptURL, options: .atomic)
        let manifest = Phase10SchedulerQualificationPerformance.CommittedArtifactManifest(
            recordPath: "Phase10SchedulerQualification/run-commit-test/performance.json",
            recordSha256: Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: recordData),
            recordByteCount: recordData.count,
            transcriptPath: "Phase10SchedulerQualification/run-commit-test/performance-transcript.json",
            transcriptSha256: Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: transcriptData),
            transcriptByteCount: transcriptData.count,
            outputRootIdentity: root.standardizedFileURL.path,
            runDirectoryIdentity: "Phase10SchedulerQualification/run-commit-test",
            outputRootPathIdentity: try Phase10SchedulerQualificationPathIdentity.capture(root),
            runDirectoryPathIdentity: try Phase10SchedulerQualificationPathIdentity.capture(runDirectory)
        )
        let manifestURL = runDirectory.appendingPathComponent("performance-manifest.json", isDirectory: false)
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)
        let commitText = "hostwright.phase10.scheduler.qualification.performance.commit.v1\n"
            + "record=performance.json\n"
            + "recordSha256=\(Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: recordData))\n"
            + "transcript=performance-transcript.json\n"
            + "transcriptSha256=\(Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: transcriptData))\n"
            + "manifest=performance-manifest.json\n"
            + "manifestSha256=\(Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: manifestData))\n"
        try Data(commitText.utf8).write(
            to: runDirectory.appendingPathComponent("COMMITTED", isDirectory: false),
            options: .atomic
        )
        XCTAssertNoThrow(
            try Phase10SchedulerQualificationPerformance.verifyCommittedArtifact(
                at: recordURL,
                root: root
            )
        )

        var promotedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: recordData) as? [String: Any]
        )
        promotedObject["referenceMacGateEnabled"] = true
        promotedObject["referenceMacID"] = Phase10SchedulerQualificationPerformance.currentHardwareDescription()
        promotedObject["thresholdEnforced"] = true
        let promotedData = try JSONSerialization.data(
            withJSONObject: promotedObject,
            options: [.sortedKeys]
        )
        XCTAssertNoThrow(
            try Phase10SchedulerQualificationPerformance.Record.decodeStrict(from: promotedData),
            "gate-field promotion remains structurally valid while the transcript must reject it"
        )
        var promotedManifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        promotedManifestObject["recordSha256"] = Phase10SchedulerQualificationPerformance.Fingerprints.digest(
            data: promotedData
        )
        let promotedManifestData = try JSONSerialization.data(
            withJSONObject: promotedManifestObject,
            options: [.sortedKeys]
        )
        let promotedCommitText = "hostwright.phase10.scheduler.qualification.performance.commit.v1\n"
            + "record=performance.json\n"
            + "recordSha256=\(Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: promotedData))\n"
            + "transcript=performance-transcript.json\n"
            + "transcriptSha256=\(Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: transcriptData))\n"
            + "manifest=performance-manifest.json\n"
            + "manifestSha256=\(Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: promotedManifestData))\n"
        try promotedData.write(to: recordURL, options: .atomic)
        try promotedManifestData.write(to: manifestURL, options: .atomic)
        try Data(promotedCommitText.utf8).write(
            to: runDirectory.appendingPathComponent("COMMITTED", isDirectory: false),
            options: .atomic
        )
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationPerformance.verifyCommittedArtifact(
                at: recordURL,
                root: root
            )
        )

        promotedObject["samplesSeconds"] = [1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 1.2]
        promotedObject["p95Seconds"] = 1.2
        let overThresholdPromotion = try JSONSerialization.data(
            withJSONObject: promotedObject,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationPerformance.Record.decodeStrict(from: overThresholdPromotion),
            "a reference-gated record must not accept a p95 at or above one second"
        )

        var tamperedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: recordData) as? [String: Any]
        )
        tamperedObject["samplesSeconds"] = [0.28, 0.26, 0.24, 0.28, 0.25, 0.23, 0.22]
        tamperedObject["p95Seconds"] = 0.28
        let tamperedData = try JSONSerialization.data(
            withJSONObject: tamperedObject,
            options: [.sortedKeys]
        )
        XCTAssertNoThrow(
            try Phase10SchedulerQualificationPerformance.Record.decodeStrict(from: tamperedData),
            "the record remains structurally/currently valid; the committed hash must catch the swap"
        )
        var tamperedManifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        tamperedManifestObject["recordSha256"] = Phase10SchedulerQualificationPerformance.Fingerprints.digest(
            data: tamperedData
        )
        let tamperedManifestData = try JSONSerialization.data(
            withJSONObject: tamperedManifestObject,
            options: [.sortedKeys]
        )
        let tamperedCommitText = "hostwright.phase10.scheduler.qualification.performance.commit.v1\n"
            + "record=performance.json\n"
            + "recordSha256=\(Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: tamperedData))\n"
            + "transcript=performance-transcript.json\n"
            + "transcriptSha256=\(Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: transcriptData))\n"
            + "manifest=performance-manifest.json\n"
            + "manifestSha256=\(Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: tamperedManifestData))\n"
        try tamperedData.write(to: recordURL, options: .atomic)
        try tamperedManifestData.write(to: manifestURL, options: .atomic)
        try Data(tamperedCommitText.utf8).write(
            to: runDirectory.appendingPathComponent("COMMITTED", isDirectory: false),
            options: .atomic
        )
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationPerformance.verifyCommittedArtifact(
                at: recordURL,
                root: root
            )
        )
    }

    func testPhase10SchedulerQualificationStrictJSONRejectsUnknownAndDuplicateKeys() throws {
        let unknown = Data("{\"unknown\":1}".utf8)
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationRunReceipt.decodeStrict(from: unknown)
        )
        let duplicate = Data("{\"schema\":\"a\",\"schema\":\"b\"}".utf8)
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationRunReceipt.decodeStrict(from: duplicate)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate JSON key"))
        }

        XCTAssertThrowsError(
            try Phase10SchedulerQualificationPerformance.Record.decodeStrict(
                from: Data("{\"unknown\":1}".utf8)
            )
        )
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationPerformance.Record.decodeStrict(
                from: Data("{\"schema\":\"a\",\"schema\":\"b\"}".utf8)
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate JSON key"))
        }
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationReplayManifest.decodeStrict(
                from: Data("{\"unknown\":1}".utf8)
            )
        )
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationReplayManifest.decodeStrict(
                from: Data("{\"schema\":\"a\",\"schema\":\"b\"}".utf8)
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate JSON key"))
        }
    }

    func testPhase10SchedulerQualificationBuilderRejectsEvaluationReuseAcrossScenarioDigests() throws {
        let first = try Phase10SchedulerQualificationGenerator.generatedScenario(
            index: 0,
            seed: Phase10SchedulerQualification.defaultSeed
        )
        let second = try Phase10SchedulerQualificationGenerator.generatedScenario(
            index: 1,
            seed: Phase10SchedulerQualification.defaultSeed
        )
        let reusedScenario = Phase10SchedulerQualification.Scenario(
            label: "reused-evaluation",
            seed: first.seed,
            input: second.input,
            oracleMode: .none
        )
        let evaluation = Phase10SchedulerQualificationVerifier.evaluate(first)
        var builder = Phase10SchedulerQualificationRunReceiptBuilder(
            cell: .generatedInvariant,
            testName: "testPhase10SchedulerQualificationSeededInvariantSmoke",
            seed: first.seed,
            caseCount: 1,
            configuration: try Phase10SchedulerQualification.Configuration(
                generatedCount: 1,
                exactCount: 1
            )
        )
        XCTAssertThrowsError(
            try builder.append(
                index: 0,
                scenario: reusedScenario,
                evaluation: evaluation,
                metrics: Phase10SchedulerQualificationEvaluationMetrics()
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("case 0"))
        }
    }

    func testPhase10SchedulerQualificationReplayStrictDecodeRejectsNestedUnknownKeys() throws {
        let scenario = try Phase10SchedulerQualificationGenerator.generatedScenario(
            index: 0,
            seed: Phase10SchedulerQualification.defaultSeed
        )
        let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
        let issue = Phase10SchedulerQualification.Issue(
            kind: .harnessError,
            severity: .failure,
            message: "nested-key-negative"
        )
        let fixture = Phase10SchedulerQualificationArtifacts.ReplayFixture(
            schema: "hostwright.phase10.scheduler.qualification.replay.v1",
            issue: issue,
            original: scenario,
            minimized: scenario,
            originalIssues: evaluation.issues,
            minimizedIssues: evaluation.issues,
            originalDecision: evaluation.decision,
            minimizedDecision: evaluation.decision,
            oracle: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(fixture)) as? [String: Any]
        )
        var original = try XCTUnwrap(object["original"] as? [String: Any])
        var input = try XCTUnwrap(original["input"] as? [String: Any])
        input["unexpectedNestedKey"] = true
        original["input"] = input
        object["original"] = original
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationArtifacts.ReplayFixture.decodeStrict(
                from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        )
    }

    func testPhase10SchedulerQualificationReplayStrictDecodeAndSemanticBinding() throws {
        var selected: (
            index: Int,
            scenario: Phase10SchedulerQualification.Scenario,
            evaluation: Phase10SchedulerQualification.Evaluation,
            issue: Phase10SchedulerQualification.Issue
        )?
        for index in 0..<24 {
            let candidate = try Phase10SchedulerQualificationGenerator.exactScenario(
                index: index,
                seed: Phase10SchedulerQualification.defaultSeed
            )
            let candidateEvaluation = Phase10SchedulerQualificationVerifier.evaluate(candidate)
            if let issue = candidateEvaluation.issues.first {
                selected = (index, candidate, candidateEvaluation, issue)
                break
            }
        }
        guard let selected else {
            throw XCTSkip("No deterministic exact-oracle diagnostic was available for replay binding.")
        }
        let scenario = selected.scenario
        let evaluation = selected.evaluation
        let issue = selected.issue
        let fixture = Phase10SchedulerQualificationArtifacts.ReplayFixture(
            schema: "hostwright.phase10.scheduler.qualification.replay.v1",
            issue: issue,
            original: scenario,
            minimized: scenario,
            originalIssues: evaluation.issues,
            minimizedIssues: evaluation.issues,
            originalDecision: evaluation.decision,
            minimizedDecision: evaluation.decision,
            oracle: evaluation.oracle
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(fixture)
        let decoded = try Phase10SchedulerQualificationArtifacts.ReplayFixture.decodeStrict(
            from: encoded
        )
        let fingerprint = String(repeating: "a", count: 64)
        let entry = Phase10SchedulerQualificationReplayEntry(
            relativePath: "Phase10SchedulerQualification/run-test/replay.json",
            sha256: fingerprint,
            byteCount: encoded.count,
            issueKind: issue.kind.rawValue,
            severity: issue.severity.rawValue,
            scenarioSeed: scenario.seed,
            inputFingerprint: scenario.input.inputDigest,
            caseIndex: selected.index,
            oracleDomain: Phase10SchedulerQualificationExactOracle.domain
        )
        XCTAssertNoThrow(
            try Phase10SchedulerQualificationRunReceipt.verifyReplaySemantics(
                decoded,
                manifestEntry: entry
            )
        )

        var unknown = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        unknown["unexpected"] = true
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationArtifacts.ReplayFixture.decodeStrict(
                from: JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys])
            )
        )
        var nestedUnknown = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var originalObject = try XCTUnwrap(nestedUnknown["original"] as? [String: Any])
        var inputObject = try XCTUnwrap(originalObject["input"] as? [String: Any])
        inputObject["unexpectedNestedKey"] = true
        originalObject["input"] = inputObject
        nestedUnknown["original"] = originalObject
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationArtifacts.ReplayFixture.decodeStrict(
                from: JSONSerialization.data(
                    withJSONObject: nestedUnknown,
                    options: [.sortedKeys]
                )
            )
        )
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationArtifacts.ReplayFixture.decodeStrict(
                from: Data(#"{"schema":"a","schema":"b"}"#.utf8)
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate JSON key"))
        }

        var tampered = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        tampered["originalDecision"] = NSNull()
        let tamperedFixture = try Phase10SchedulerQualificationArtifacts.ReplayFixture.decodeStrict(
            from: JSONSerialization.data(withJSONObject: tampered, options: [.sortedKeys])
        )
        XCTAssertThrowsError(
            try Phase10SchedulerQualificationRunReceipt.verifyReplaySemantics(
                tamperedFixture,
                manifestEntry: entry
            )
        )
    }

    func testPhase10SchedulerQualificationPathIdentityRejectsSameTextReplacement() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Phase10SchedulerQualificationIdentity-(UUID().uuidString)",
            isDirectory: true
        )
        let runDirectory = parent
            .appendingPathComponent("Phase10SchedulerQualification", isDirectory: true)
            .appendingPathComponent("run-test", isDirectory: true)
        let backup = parent.deletingLastPathComponent()
            .appendingPathComponent(parent.lastPathComponent + "-old", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let rootIdentity = try Phase10SchedulerQualificationPathIdentity.capture(parent)
        let runIdentity = try Phase10SchedulerQualificationPathIdentity.capture(runDirectory)
        XCTAssertFalse(rootIdentity.resolvedPath.isEmpty)
        XCTAssertGreaterThan(rootIdentity.inode, 0)
        XCTAssertGreaterThan(runIdentity.inode, 0)
        try FileManager.default.moveItem(at: runDirectory, to: backup)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertNoThrow(try rootIdentity.verify(at: parent))
        XCTAssertThrowsError(try runIdentity.verify(at: runDirectory))
    }

    func testPhase10SchedulerQualificationCommittedMarkerRejectsUnknownAndDuplicateKeys() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Phase10SchedulerQualificationCommitMarker-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let configuration = try Phase10SchedulerQualification.Configuration(
            generatedCount: 1,
            exactCount: 1,
            explicitOutputRoot: parent
        )
        let testName = "testPhase10SchedulerQualificationExactMultiResourceFeasibilityOracleSmoke"
        var builder = Phase10SchedulerQualificationRunReceiptBuilder(
            cell: .exactOracle,
            testName: testName,
            seed: configuration.seed,
            caseCount: 1,
            configuration: configuration
        )
        let scenario = try Phase10SchedulerQualificationGenerator.exactScenario(
            index: 0,
            seed: configuration.seed
        )
        let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
        let metrics = try assertQualificationPasses(
            scenario,
            configuration: configuration,
            evaluation: evaluation
        )
        try builder.append(
            index: 0,
            scenario: scenario,
            evaluation: evaluation,
            metrics: metrics
        )
        let session = try builder.makePreparedReceipt(elapsedSeconds: 0.1)
        let receipt = try Phase10SchedulerQualificationArtifacts.emitQualificationReceipt(
            session,
            configuration: configuration
        )
        let receiptURL = URL(fileURLWithPath: receipt.location)
        let record = try Phase10SchedulerQualificationRunReceipt.decodeStrict(
            from: Data(contentsOf: receiptURL)
        )
        XCTAssertNotNil(record.outputRootPathIdentity)
        XCTAssertNotNil(record.runDirectoryPathIdentity)
        try record.verifyReplayFiles(at: parent)
        let markerURL = receiptURL.deletingLastPathComponent()
            .appendingPathComponent("COMMITTED", isDirectory: false)
        let validReceiptData = try Data(contentsOf: receiptURL)
        var tamperedReceipt = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validReceiptData) as? [String: Any]
        )
        tamperedReceipt["inputFingerprint"] = String(repeating: "0", count: 64)
        let tamperedReceiptData = try JSONSerialization.data(
            withJSONObject: tamperedReceipt,
            options: [.sortedKeys]
        )
        let tamperedRecord = try Phase10SchedulerQualificationRunReceipt.decodeStrict(
            from: tamperedReceiptData
        )
        try tamperedReceiptData.write(to: receiptURL)
        XCTAssertThrowsError(try tamperedRecord.verifyReplayFiles(at: parent))
        try validReceiptData.write(to: receiptURL)
        let validMarker = try String(contentsOf: markerURL, encoding: .utf8)
        for tampered in [
            validMarker + "unknown=value\n",
            validMarker + "receipt=\(receiptURL.lastPathComponent)\n"
        ] {
            try Data(tampered.utf8).write(to: markerURL)
            XCTAssertThrowsError(
                try record.verifyReplayFiles(at: parent)
            )
        }
        try Data(validMarker.utf8).write(to: markerURL)
    }

    func testPhase10SchedulerQualificationPerformanceReceiptRejectsFingerprintDrift() throws {
        let sourceFingerprint = String(repeating: "a", count: 64)
        let inputFingerprint = String(repeating: "b", count: 64)
        let buildFingerprint = String(repeating: "c", count: 64)
        let record = Phase10SchedulerQualificationPerformance.Record(
            schema: Phase10SchedulerQualificationPerformance.recordSchema,
            hardware: "Mac16,8",
            operatingSystem: "macOS 26.5.2",
            swiftVersion: "Swift 6.3.3",
            seed: Phase10SchedulerQualification.defaultSeed,
            pendingWorkloads: 1_000,
            nodes: 100,
            repeats: 7,
            samplesSeconds: [0.25, 0.26, 0.24, 0.27, 0.25, 0.23, 0.22],
            p95Seconds: 0.27,
            referenceMacGateEnabled: true,
            referenceMacID: "Mac16,8",
            thresholdEnforced: true,
            sourceFingerprint: sourceFingerprint,
            inputFingerprint: inputFingerprint,
            buildFingerprint: buildFingerprint
        )

        for (field, expectedSource, expectedInput, expectedBuild) in [
            ("source", String(repeating: "d", count: 64), inputFingerprint, buildFingerprint),
            ("input", sourceFingerprint, String(repeating: "e", count: 64), buildFingerprint),
            ("build", sourceFingerprint, inputFingerprint, String(repeating: "f", count: 64))
        ] {
            XCTAssertThrowsError(
                try record.verifyBinding(
                    expectedInputFingerprint: expectedInput,
                    expectedSourceFingerprint: expectedSource,
                    expectedBuildFingerprint: expectedBuild
                )
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("\(field) fingerprint mismatch")
                )
            }
        }
    }

    func testPhase10SchedulerQualificationPerformanceReceiptRejectsInvalidFingerprintOnDecode() throws {
        let valid = String(repeating: "a", count: 64)
        let record = Phase10SchedulerQualificationPerformance.Record(
            schema: Phase10SchedulerQualificationPerformance.recordSchema,
            hardware: "Mac16,8",
            operatingSystem: "macOS 26.5.2",
            swiftVersion: "Swift 6.3.3",
            seed: Phase10SchedulerQualification.defaultSeed,
            pendingWorkloads: 1_000,
            nodes: 100,
            repeats: 7,
            samplesSeconds: [0.25, 0.26, 0.24, 0.27, 0.25, 0.23, 0.22],
            p95Seconds: 0.27,
            referenceMacGateEnabled: true,
            referenceMacID: "Mac16,8",
            thresholdEnforced: true,
            sourceFingerprint: valid,
            inputFingerprint: valid,
            buildFingerprint: valid
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(record)) as? [String: Any]
        )
        object["sourceFingerprint"] = "not-a-sha256"
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                Phase10SchedulerQualificationPerformance.Record.self,
                from: tampered
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("source fingerprint"))
        }
    }

    func testPhase10SchedulerQualificationPerformanceReceiptRejectsShapeAndP95Drift() throws {
        let valid = String(repeating: "a", count: 64)
        let shape = Phase10SchedulerQualificationPerformance.Record(
            schema: Phase10SchedulerQualificationPerformance.recordSchema,
            hardware: "Mac16,8",
            operatingSystem: "macOS 26.5.2",
            swiftVersion: "Swift 6.3.3",
            seed: Phase10SchedulerQualification.defaultSeed,
            pendingWorkloads: 999,
            nodes: 100,
            repeats: 7,
            samplesSeconds: [0.25, 0.26, 0.24, 0.27, 0.25, 0.23, 0.22],
            p95Seconds: 0.27,
            referenceMacGateEnabled: true,
            referenceMacID: "Mac16,8",
            thresholdEnforced: true,
            sourceFingerprint: valid,
            inputFingerprint: valid,
            buildFingerprint: valid
        )
        XCTAssertThrowsError(try shape.validate()) { error in
            XCTAssertTrue(error.localizedDescription.contains("1,000 workloads"))
        }
        let p95 = Phase10SchedulerQualificationPerformance.Record(
            schema: Phase10SchedulerQualificationPerformance.recordSchema,
            hardware: "Mac16,8",
            operatingSystem: "macOS 26.5.2",
            swiftVersion: "Swift 6.3.3",
            seed: Phase10SchedulerQualification.defaultSeed,
            pendingWorkloads: 1_000,
            nodes: 100,
            repeats: 7,
            samplesSeconds: [0.25, 0.26, 0.24, 0.27, 0.25, 0.23, 0.22],
            p95Seconds: 0.26,
            referenceMacGateEnabled: true,
            referenceMacID: "Mac16,8",
            thresholdEnforced: true,
            sourceFingerprint: valid,
            inputFingerprint: valid,
            buildFingerprint: valid
        )
        XCTAssertThrowsError(try p95.validate()) { error in
            XCTAssertTrue(error.localizedDescription.contains("p95 must equal"))
        }
    }

    func testPhase10SchedulerQualificationPerformanceReceiptBindsCanonicalSchedulerInputDigest() throws {
        let input = try Phase10SchedulerQualificationGenerator.generatedScenario(
            index: 0,
            seed: Phase10SchedulerQualification.defaultSeed
        ).input
        let sourceFingerprint = String(repeating: "a", count: 64)
        let buildFingerprint = String(repeating: "c", count: 64)
        let record = Phase10SchedulerQualificationPerformance.Record(
            schema: Phase10SchedulerQualificationPerformance.recordSchema,
            hardware: "Mac16,8",
            operatingSystem: "macOS 26.5.2",
            swiftVersion: "Swift 6.3.3",
            seed: Phase10SchedulerQualification.defaultSeed,
            pendingWorkloads: 1_000,
            nodes: 100,
            repeats: 7,
            samplesSeconds: [0.25, 0.26, 0.24, 0.27, 0.25, 0.23, 0.22],
            p95Seconds: 0.27,
            referenceMacGateEnabled: true,
            referenceMacID: "Mac16,8",
            thresholdEnforced: true,
            sourceFingerprint: sourceFingerprint,
            inputFingerprint: input.inputDigest,
            buildFingerprint: buildFingerprint
        )

        try record.verifyBinding(
            for: input,
            sourceFingerprint: sourceFingerprint,
            buildFingerprint: buildFingerprint
        )

        let differentInput = try Phase10SchedulerQualificationGenerator.generatedScenario(
            index: 1,
            seed: Phase10SchedulerQualification.defaultSeed
        ).input
        XCTAssertNotEqual(input.inputDigest, differentInput.inputDigest)
        XCTAssertThrowsError(
            try record.verifyBinding(
                for: differentInput,
                sourceFingerprint: sourceFingerprint,
                buildFingerprint: buildFingerprint
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("input fingerprint mismatch"))
        }
    }

    func testPhase10SchedulerQualificationPerformanceFingerprintsAreDeterministic() throws {
        let sourceFirst = try Phase10SchedulerQualificationPerformance.Fingerprints.sourceFingerprint()
        let sourceSecond = try Phase10SchedulerQualificationPerformance.Fingerprints.sourceFingerprint()
        XCTAssertEqual(sourceFirst, sourceSecond)
        let buildFirst = try Phase10SchedulerQualificationPerformance.Fingerprints.buildFingerprint(
            swiftVersion: "qualification-swift",
            operatingSystem: "qualification-os"
        )
        let buildSecond = try Phase10SchedulerQualificationPerformance.Fingerprints.buildFingerprint(
            swiftVersion: "qualification-swift",
            operatingSystem: "qualification-os"
        )
        XCTAssertEqual(buildFirst, buildSecond)
    }

    func testPhase10SchedulerQualificationTopologyHostileGuardHandlesShortPlacementList() {
        let onlyNode = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        XCTAssertNotNil(
            Phase10SchedulerQualificationHostileExpectations.topologyConflictFailure(
                placedNodeIDs: [onlyNode]
            )
        )
    }

    func testPhase10SchedulerQualificationPerformanceCell() throws {
        let configuration = try Phase10SchedulerQualification.Configuration.current()
        guard configuration.performanceEnabled else {
            throw XCTSkip(
                "Set \(Phase10SchedulerQualification.Configuration.performanceEnvironment)=1 to run the 1,000-workload x 100-node performance cell."
            )
        }
        let session = try Phase10SchedulerQualificationPerformance.measure(configuration: configuration)
        let record = session.record
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rendered = String(data: try encoder.encode(record), encoding: .utf8) ?? "{}"
        let receipt = try Phase10SchedulerQualificationArtifacts.emitPerformance(
            session,
            configuration: configuration
        )
        print("P10-G3G8-QUAL performance \(rendered)")
        print("P10-G3G8-QUAL performance record: \(receipt.location); bytes=\(receipt.byteCount); retained=\(receipt.retained)")
        if record.thresholdEnforced {
            XCTAssertLessThan(
                record.p95Seconds,
                1.0,
                "Qualified reference-Mac p95 must remain below one second."
            )
        }
    }

    private func elapsedSeconds(since started: UInt64) -> Double {
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        return Double(elapsed) / 1_000_000_000
    }

    private func emitQualificationReceiptIfConfigured(
        _ builder: inout Phase10SchedulerQualificationRunReceiptBuilder,
        configuration: Phase10SchedulerQualification.Configuration,
        elapsedSeconds: Double
    ) throws {
        guard configuration.explicitOutputRoot != nil else {
            return
        }
        let session = try builder.makePreparedReceipt(elapsedSeconds: elapsedSeconds)
        let receipt = try Phase10SchedulerQualificationArtifacts.emitQualificationReceipt(
            session,
            configuration: configuration
        )
        let record = session.record
        let summary = "P10-G3G8-QUAL receipt cell=\(record.cell.rawValue); cases=\(record.caseCount); "
            + "seed=\(record.seed); safety=\(record.safetyMismatchCount); "
            + "optimizationGaps=\(record.optimizationGapCount); fixtures=\(record.replayFixtures.count); "
            + "source=\(record.sourceFingerprint); input=\(record.inputFingerprint); "
            + "build=\(record.buildFingerprint); location=\(receipt.location); "
            + "sha256=\(receipt.sha256); retained=\(receipt.retained)"
        print(summary)
    }

    private func assertHostileExpectation(
        scenario: Phase10SchedulerQualification.Scenario,
        decision: SchedulerDecision,
        evaluation: Phase10SchedulerQualification.Evaluation,
        configuration: Phase10SchedulerQualification.Configuration
    ) throws {
        let failure: String?
        let uniqueDecisionCount = Set(decision.workloadDecisions.map(\.workloadID)).count
        if uniqueDecisionCount != decision.workloadDecisions.count {
            failure = "Hostile scenario emitted duplicate workload decisions."
        } else {
            switch scenario.label {
        case "empty-feasibility":
            failure = decision.workloadDecisions.first?.outcome == .unschedulable
                ? nil
                : "Empty-feasibility case was expected to be unschedulable."
        case "exact-tie":
            failure = decision.workloadDecisions.first?.outcome == .placed
                ? nil
                : "Exact-tie case was expected to place its workload."
        case "quota-guarantee-borrowing":
            failure = (decision.workloadDecisions.first?.fairnessExplanation?.borrowingBasisPoints ?? 0) > 0
                ? nil
                : "Quota/guarantee/borrowing case did not report borrowing."
        case "topology-conflict":
            let placed = decision.workloadDecisions.filter {
                $0.outcome == .placed || $0.outcome == .retainedExistingPlacement
            }
            failure = Phase10SchedulerQualificationHostileExpectations.topologyConflictFailure(
                placedNodeIDs: placed.map(\.chosenNodeID)
            )
        case "anti-churn":
            failure = decision.workloadDecisions.first?.outcome == .retainedExistingPlacement
                ? nil
                : "Anti-churn case did not retain the protected placement."
        case "preemption":
            failure = decision.workloadDecisions.first?.outcome == .preemptionProposed
                && decision.workloadDecisions.first?.preemption?.requiresFence == true
                ? nil
                : "Preemption case did not emit a fenced proposal."
        case "preemption-overlap":
            let proposals = decision.workloadDecisions.filter {
                $0.outcome == .preemptionProposed
            }
            let unschedulable = decision.workloadDecisions.filter {
                $0.outcome == .unschedulable
            }
            let victimIDs = proposals.flatMap { $0.preemption?.victimWorkloadIDs ?? [] }
            failure = proposals.count == 1
                && unschedulable.count == 1
                && Set(victimIDs).count == victimIDs.count
                ? nil
                : "Preemption overlap reused a victim or produced an unexpected outcome set."
        case "disruption-exhaustion":
            failure = decision.workloadDecisions.first?.outcome == .unschedulable
                && decision.workloadDecisions.first?.preemption == nil
                ? nil
                : "Disruption exhaustion case should remain unschedulable without a proposal."
        case "exact-search-bound-exhaustion":
            failure = decision.workloadDecisions.first?.outcome == .unschedulable
                && decision.workloadDecisions.first?.filterFailures.contains {
                    $0.code == .preemptionSearchBoundExceeded
                } == true
                ? nil
                : "Exact-search-bound case did not report bounded-search exhaustion."
        case "hard-selector-topology":
            let item = decision.workloadDecisions.first
            let contextUnavailable = item?.filterFailures.contains {
                $0.stableDetailKey == "topology-spread:zone:context-unavailable"
            } == true
            failure = item?.outcome == .placed && !contextUnavailable
                ? nil
                : "Hard selector/topology case did not use the node-domain topology context for a permitted placement."
        case "exact-preemption-hard-topology":
            failure = decision.workloadDecisions.first?.outcome == .unschedulable
                && decision.workloadDecisions.first?.preemption == nil
                ? nil
                : "Exact preemption must not relax a hard topology spread."
        case "weighted-selector":
            failure = decision.workloadDecisions.first?.outcome == .placed
                ? nil
                : "Weighted selector case did not produce a placement."
        default:
            failure = "Unknown hostile qualification scenario \(scenario.label)."
            }
        }
        if let failure {
            try recordHostileFailure(
                failure,
                scenario: scenario,
                evaluation: evaluation,
                configuration: configuration
            )
        }
    }

    private func recordHostileFailure(
        _ message: String,
        scenario: Phase10SchedulerQualification.Scenario,
        evaluation: Phase10SchedulerQualification.Evaluation,
        configuration: Phase10SchedulerQualification.Configuration
    ) throws {
        let issue = Phase10SchedulerQualification.Issue(
            kind: .hostileExpectation,
            severity: .failure,
            message: message
        )
        let boundEvaluation = evaluation.addingIssue(issue)
        let minimized: Phase10SchedulerQualification.Scenario
        do {
            minimized = try Phase10SchedulerQualificationShrinker.minimize(
                scenario,
                preserving: issue.kind
            )
        } catch {
            minimized = scenario
        }
        let receipt = try Phase10SchedulerQualificationArtifacts.emitReplay(
            original: scenario,
            minimized: minimized,
            issue: issue,
            originalEvaluation: boundEvaluation,
            minimizedEvaluation: Phase10SchedulerQualificationVerifier.evaluate(minimized)
                .addingIssue(issue),
            configuration: configuration
        )
        XCTFail("P10-G3G8-QUAL \(message); fixture=\(receipt.location)")
    }

    private func emitTestReplay(
        scenario: Phase10SchedulerQualification.Scenario,
        evaluation: Phase10SchedulerQualification.Evaluation,
        configuration: Phase10SchedulerQualification.Configuration
    ) throws -> Phase10SchedulerQualificationArtifacts.Receipt {
        try Phase10SchedulerQualificationArtifacts.emitReplay(
            original: scenario,
            minimized: scenario,
            issue: Phase10SchedulerQualification.Issue(
                kind: .harnessError,
                severity: .failure,
                message: "fixture-retention-test"
            ),
            originalEvaluation: evaluation.addingIssue(
                Phase10SchedulerQualification.Issue(
                    kind: .harnessError,
                    severity: .failure,
                    message: "fixture-retention-test"
                )
            ),
            minimizedEvaluation: evaluation.addingIssue(
                Phase10SchedulerQualification.Issue(
                    kind: .harnessError,
                    severity: .failure,
                    message: "fixture-retention-test"
                )
            ),
            configuration: configuration
        )
    }

    @discardableResult
    private func assertQualificationPasses(
        _ scenario: Phase10SchedulerQualification.Scenario,
        configuration: Phase10SchedulerQualification.Configuration,
        evaluation: Phase10SchedulerQualification.Evaluation? = nil,
        caseIndex: Int? = nil
    ) throws -> Phase10SchedulerQualificationEvaluationMetrics {
        let resolved = evaluation ?? Phase10SchedulerQualificationVerifier.evaluate(scenario)
        var failures: [String] = []
        var metrics = Phase10SchedulerQualificationEvaluationMetrics()
        for issue in resolved.issues {
            let minimized: Phase10SchedulerQualification.Scenario
            do {
                minimized = try Phase10SchedulerQualificationShrinker.minimize(
                    scenario,
                    preserving: issue.kind
                )
            } catch {
                minimized = scenario
                print(
                    "P10-G3G8-QUAL shrink fallback [\(scenario.label)]: \(String(describing: error))"
                )
            }
            let minimizedEvaluation = Phase10SchedulerQualificationVerifier.evaluate(minimized)
            let receipt = try Phase10SchedulerQualificationArtifacts.emitReplay(
                original: scenario,
                minimized: minimized,
                issue: issue,
                originalEvaluation: resolved,
                minimizedEvaluation: minimizedEvaluation,
                configuration: configuration
            )
            let artifact = "fixture=\(receipt.location); bytes=\(receipt.byteCount); retained=\(receipt.retained)"
            metrics.ingest(
                issue: issue,
                scenario: scenario,
                receipt: receipt,
                caseIndex: caseIndex ?? -1
            )
            if issue.severity == .diagnostic {
                print("P10-G3G8-QUAL diagnostic [\(scenario.label)]: \(issue.message); \(artifact)")
            } else {
                failures.append("\(issue.message); \(artifact)")
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "P10-G3G8-QUAL \(scenario.label) failed:\n\(failures.joined(separator: "\n"))"
        )
        return metrics
    }
}
