import Foundation
import HostwrightScheduler

private struct Phase10SchedulerQualificationPRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func integer(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    mutating func boolean() -> Bool {
        next() & 1 == 1
    }
}

enum Phase10SchedulerQualificationGenerator {
    static func canonicalScenario(
        cell: Phase10SchedulerQualificationRunCell,
        index: Int,
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        switch cell {
        case .generatedInvariant:
            return try generatedScenario(index: index, seed: seed)
        case .exactOracle:
            return try exactScenario(index: index, seed: seed)
        }
    }

    static func generatedScenario(index: Int, seed: UInt64) throws -> Phase10SchedulerQualification.Scenario {
        let scenarioSeed = seed &+ UInt64(index)
        switch index % 12 {
        case 0:
            return try mixedScenario(index: index, seed: scenarioSeed)
        case 1:
            return try quotaAndBorrowingScenario(seed: scenarioSeed)
        case 2:
            return try topologyConflictScenario(seed: scenarioSeed)
        case 3:
            return try antiChurnScenario(seed: scenarioSeed)
        case 4:
            return try preemptionScenario(seed: scenarioSeed)
        case 5:
            return try disruptionExhaustionScenario(seed: scenarioSeed)
        case 6:
            return try exactSearchBoundScenario(seed: scenarioSeed)
        case 7:
            return try exactTieScenario(seed: scenarioSeed)
        case 8:
            return try hardSelectorTopologyScenario(seed: scenarioSeed)
        case 9:
            return try preemptionOverlapScenario(seed: scenarioSeed)
        case 10:
            return try exactPreemptionHardTopologyScenario(seed: scenarioSeed)
        default:
            return try weightedSelectorScenario(seed: scenarioSeed)
        }
    }

    static func hostileScenarios(
        seed: UInt64
    ) throws -> [Phase10SchedulerQualification.Scenario] {
        try [
            emptyFeasibilityScenario(seed: seed &+ 1),
            exactTieScenario(seed: seed &+ 2),
            quotaAndBorrowingScenario(seed: seed &+ 3),
            topologyConflictScenario(seed: seed &+ 4),
            antiChurnScenario(seed: seed &+ 5),
            preemptionScenario(seed: seed &+ 6),
            disruptionExhaustionScenario(seed: seed &+ 7),
            exactSearchBoundScenario(seed: seed &+ 8),
            hardSelectorTopologyScenario(seed: seed &+ 9),
            preemptionOverlapScenario(seed: seed &+ 10),
            exactPreemptionHardTopologyScenario(seed: seed &+ 11),
            weightedSelectorScenario(seed: seed &+ 12)
        ]
    }

    static func hardSelectorTopologyCase(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.HardSelectorTopologyCase {
        let passingNodeID = identifier(seed: seed, slot: 8_000)
        let absentNotInNodeID = identifier(seed: seed, slot: 8_001)
        let skewedTopologyNodeID = identifier(seed: seed, slot: 8_002)
        let workloadID = identifier(seed: seed, slot: 8_003)
        let observedWorkloadID = identifier(seed: seed, slot: 8_004)
        let unrelatedWorkloadID = identifier(seed: seed, slot: 8_005)
        let affinity = try NodeAffinity(
            requiredSelectors: [
                try SchedulerLabelSelector(
                    key: "class",
                    operator: .notIn,
                    values: ["gpu"]
                ),
                try SchedulerLabelSelector(key: "rack", operator: .exists),
                try SchedulerLabelSelector(
                    key: "zone",
                    operator: .in,
                    values: ["east", "west"]
                )
            ],
            forbiddenSelectors: [
                try SchedulerLabelSelector(key: "spot", operator: .doesNotExist)
            ],
            topologySpreads: [
                try SchedulerHardTopologySpread(
                    topologyKey: "zone",
                    maxSkew: 1,
                    whenUnsatisfiable: .doNotSchedule,
                    groupID: "phase10-hard"
                )
            ]
        )
        let schedulerWorkload = try workload(
            id: workloadID,
            cpu: 1,
            memory: 1,
            priority: 5,
            subject: "hard-selector",
            project: "phase10",
            affinity: affinity
        )
        let passingNode = try node(
            id: passingNodeID,
            capacity: vector(cpu: 4, memory: 4),
            topology: ["zone": "west"],
            labels: [
                "pool": "general",
                "zone": "west",
                "class": "cpu",
                "rack": "r1",
                "spot": "false"
            ]
        )
        let absentNotInNode = try node(
            id: absentNotInNodeID,
            capacity: vector(cpu: 4, memory: 4),
            topology: ["zone": "west"],
            labels: ["pool": "general", "zone": "west", "rack": "r2"]
        )
        let skewedTopologyNode = try node(
            id: skewedTopologyNodeID,
            capacity: vector(cpu: 4, memory: 4),
            topology: ["zone": "east"],
            labels: [
                "pool": "general",
                "zone": "east",
                "class": "cpu",
                "rack": "r1",
                "spot": "false"
            ]
        )
        let context = try HardTopologySpreadContext(
            nodeTopologyDomains: [
                passingNodeID: ["zone": "west"],
                absentNotInNodeID: ["zone": "west"],
                skewedTopologyNodeID: ["zone": "east"]
            ],
            observations: [
                try HardTopologySpreadObservation(
                    workloadID: observedWorkloadID,
                    nodeID: skewedTopologyNodeID,
                    groupID: "phase10-hard"
                ),
                try HardTopologySpreadObservation(
                    workloadID: unrelatedWorkloadID,
                    nodeID: passingNodeID,
                    groupID: "other-group"
                )
            ]
        )
        return Phase10SchedulerQualification.HardSelectorTopologyCase(
            workload: schedulerWorkload.requirements,
            nodes: [skewedTopologyNode, absentNotInNode, passingNode],
            context: context,
            passingNodeID: passingNodeID,
            absentNotInNodeID: absentNotInNodeID,
            skewedTopologyNodeID: skewedTopologyNodeID
        )
    }

    static func hardSelectorTopologyScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let hardCase = try hardSelectorTopologyCase(seed: seed)
        let schedulerWorkload = try SchedulerWorkload(
            requirements: hardCase.workload,
            priority: 5,
            subjectID: "hard-selector",
            projectID: "phase10"
        )
        return Phase10SchedulerQualification.Scenario(
            label: "hard-selector-topology",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [schedulerWorkload],
                nodes: hardCase.nodes
            ),
            oracleMode: .none
        )
    }

    static func weightedSelectorScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let preferredNode = try node(
            id: identifier(seed: seed, slot: 8_100),
            capacity: vector(cpu: 4, memory: 4),
            labels: [
                "class": "cpu",
                "tier": "on-demand",
                "rack": "r1",
                "debug": "true"
            ]
        )
        let alternativeNode = try node(
            id: identifier(seed: seed, slot: 8_101),
            capacity: vector(cpu: 4, memory: 4),
            labels: [
                "class": "gpu",
                "tier": "spot",
                "rack-avoid": "r2",
                "ephemeral": "true"
            ]
        )
        let preferredAffinity = try [
            SchedulerWeightedLabelSelectorPreference(
                weight: 4,
                selector: try SchedulerLabelSelector(
                    key: "class",
                    operator: .in,
                    values: ["cpu"]
                )
            ),
            SchedulerWeightedLabelSelectorPreference(
                weight: 3,
                selector: try SchedulerLabelSelector(
                    key: "tier",
                    operator: .notIn,
                    values: ["spot"]
                )
            ),
            SchedulerWeightedLabelSelectorPreference(
                weight: 2,
                selector: try SchedulerLabelSelector(key: "rack", operator: .exists)
            ),
            SchedulerWeightedLabelSelectorPreference(
                weight: 1,
                selector: try SchedulerLabelSelector(
                    key: "ephemeral",
                    operator: .doesNotExist
                )
            )
        ]
        let preferredAntiAffinity = try [
            SchedulerWeightedLabelSelectorPreference(
                weight: 4,
                selector: try SchedulerLabelSelector(
                    key: "class",
                    operator: .in,
                    values: ["gpu"]
                )
            ),
            SchedulerWeightedLabelSelectorPreference(
                weight: 3,
                selector: try SchedulerLabelSelector(
                    key: "tier",
                    operator: .notIn,
                    values: ["on-demand"]
                )
            ),
            SchedulerWeightedLabelSelectorPreference(
                weight: 2,
                selector: try SchedulerLabelSelector(key: "rack-avoid", operator: .exists)
            ),
            SchedulerWeightedLabelSelectorPreference(
                weight: 1,
                selector: try SchedulerLabelSelector(
                    key: "debug",
                    operator: .doesNotExist
                )
            )
        ]
        let topology = try SchedulerTopologyPreference(
            preferredAffinity: preferredAffinity,
            preferredAntiAffinity: preferredAntiAffinity
        )
        let workload = try workload(
            id: identifier(seed: seed, slot: 8_102),
            cpu: 1,
            memory: 1,
            priority: 5,
            subject: "weighted-selector",
            project: "phase10-weighted-selector",
            topology: topology
        )
        let weights = try SchedulerScoreWeights(
            fragmentation: 0,
            fairness: 0,
            topology: 1,
            locality: 0,
            hostPressureEnergy: 0,
            disruption: 0
        )
        return Phase10SchedulerQualification.Scenario(
            label: "weighted-selector",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [alternativeNode, preferredNode],
                scoringWeights: weights
            ),
            oracleMode: .none
        )
    }

    static func exactScenario(
        index: Int,
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        var random = Phase10SchedulerQualificationPRNG(seed: seed &+ UInt64(index))
        let caseSeed = seed &+ UInt64(index)
        let nodeCount = random.integer(2...3)
        let workloadCount = random.integer(1...4)
        let nodes = try (0..<nodeCount).map { offset in
            try node(
                id: identifier(seed: caseSeed, slot: 1_000 + offset),
                capacity: vector(
                    cpu: Int64(random.integer(2...5)),
                    memory: Int64(random.integer(3...8)),
                    disk: Int64(random.integer(4...10))
                )
            )
        }
        let workloads = try (0..<workloadCount).map { offset in
            try exactResourceWorkload(
                id: identifier(seed: caseSeed, slot: 2_000 + offset),
                cpu: Int64(random.integer(1...3)),
                memory: Int64(random.integer(1...5)),
                disk: Int64(random.integer(1...6))
            )
        }
        let weights = try SchedulerScoreWeights(
            fragmentation: 1,
            fairness: 0,
            topology: 0,
            locality: 0,
            hostPressureEnergy: 0,
            disruption: 0
        )
        return Phase10SchedulerQualification.Scenario(
            label: "exact-multi-resource-feasibility-\(index)",
            seed: caseSeed,
            input: try SchedulerEngineInput(
                pendingWorkloads: workloads.reversed(),
                nodes: nodes.reversed(),
                scoringWeights: weights
            ),
            oracleMode: .feasibility
        )
    }

    static func priorityOptimizationGapScenario() throws -> Phase10SchedulerQualification.Scenario {
        let seed = Phase10SchedulerQualification.defaultSeed
        let capacity = try node(
            id: identifier(seed: seed, slot: 1_000),
            capacity: vector(cpu: 2, memory: 2, disk: 2)
        )
        let workloads = try (0..<3).map { index in
            try exactResourceWorkload(
                id: identifier(seed: seed, slot: 2_000 + index),
                cpu: index == 0 ? 2 : 1,
                memory: index == 0 ? 2 : 1,
                disk: index == 0 ? 2 : 1,
                priority: index == 0 ? 100 : 0
            )
        }
        return Phase10SchedulerQualification.Scenario(
            label: "priority-before-placement-count",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: workloads,
                nodes: [capacity],
                scoringWeights: SchedulerScoreWeights(
                    fragmentation: 1, fairness: 0, topology: 0,
                    locality: 0, hostPressureEnergy: 0, disruption: 0
                )
            ),
            oracleMode: .feasibility
        )
    }

    static func performanceInput(seed: UInt64) throws -> SchedulerEngineInput {
        let nodes = try (0..<100).map { offset in
            try node(
                id: identifier(seed: seed, slot: 10_000 + offset),
                capacity: vector(cpu: 20, memory: 20),
                topology: ["zone": offset.isMultiple(of: 2) ? "east" : "west"]
            )
        }
        let workloads = try (0..<1_000).map { offset in
            try workload(
                id: identifier(seed: seed, slot: 20_000 + offset),
                cpu: 1,
                memory: 1,
                priority: 0,
                subject: "perf-\(offset % 10)",
                project: "qualification"
            )
        }
        return try SchedulerEngineInput(
            pendingWorkloads: workloads,
            nodes: nodes,
            snapshotQuality: SchedulerSnapshotQuality(
                confidenceBasisPoints: 10_000,
                stalenessUnits: 0,
                sourceGeneration: "phase10-performance"
            )
        )
    }

    private static func mixedScenario(
        index: Int,
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        var random = Phase10SchedulerQualificationPRNG(seed: seed)
        let nodeCount = random.integer(2...4)
        var nodes: [SchedulerNode] = []
        for offset in 0..<nodeCount {
            let cpu = Int64(random.integer(5...10))
            let memory = Int64(random.integer(10...24))
            let reservation = try vector(
                cpu: Int64(random.integer(0...1)),
                memory: Int64(random.integer(0...2))
            )
            let pressure: SchedulerPressurePosture = offset == 0 && random.boolean() ? .elevated : .nominal
            nodes.append(
                try node(
                    id: identifier(seed: seed, slot: 100 + offset),
                    capacity: vector(cpu: cpu, memory: memory),
                    reservation: reservation,
                    architecture: offset.isMultiple(of: 2) ? "arm64" : "x86_64",
                    topology: ["zone": offset.isMultiple(of: 2) ? "east" : "west"],
                    posture: SchedulerHostPosture(
                        pressure: pressure,
                        energy: offset.isMultiple(of: 2) ? .efficient : .balanced
                    ),
                    acceleratorAvailability: try vector(gpu: offset.isMultiple(of: 2) ? 1 : 0)
                )
            )
        }

        let workloadCount = random.integer(2...4)
        let workloadIDs = (0..<workloadCount).map {
            identifier(seed: seed, slot: 300 + $0)
        }
        var workloads: [SchedulerWorkload] = []
        for offset in 0..<workloadCount {
            let topology: SchedulerTopologyPreference
            if offset == 0 {
                topology = try SchedulerTopologyPreference(
                    groupID: "mixed-web",
                    spreadKey: "zone",
                    preferredDomainValues: ["east"]
                )
            } else if offset.isMultiple(of: 2) {
                topology = try SchedulerTopologyPreference(
                    groupID: "mixed-web",
                    spreadKey: "zone",
                    affinityWorkloadIDs: [workloadIDs[offset - 1]]
                )
            } else {
                topology = try SchedulerTopologyPreference(
                    groupID: "mixed-web",
                    spreadKey: "zone",
                    antiAffinityWorkloadIDs: [workloadIDs[offset - 1]]
                )
            }
            let localNode = nodes[offset % nodes.count].nodeID
            let requiredArchitecture = offset.isMultiple(of: 3)
                ? [nodes.first!.snapshot.architecture]
                : []
            let constraints = offset.isMultiple(of: 2)
                ? try SchedulerAdditionalPlacementConstraints(
                    requiredVolumes: ["volume-\(offset % 2)"],
                    requiredPorts: [8_080 + offset],
                    requiredNetworks: ["network-\(offset % 2)"]
                )
                : .none
            workloads.append(
                try workload(
                    id: workloadIDs[offset],
                    cpu: Int64(random.integer(1...3)),
                    memory: Int64(random.integer(1...5)),
                    priority: Int64(random.integer(0...5)),
                    subject: "tenant-\(offset % 2)",
                    project: "mixed",
                    requiredArchitectures: requiredArchitecture,
                    acceleratorGPU: offset.isMultiple(of: 3) ? 1 : 0,
                    topology: topology,
                    locality: try SchedulerLocalityPreference(preferredNodeIDs: [localNode]),
                    constraints: constraints,
                    overhead: try vector(cpu: offset.isMultiple(of: 2) ? 1 : 0),
                    safetyMargin: try vector(memory: offset.isMultiple(of: 3) ? 1 : 0)
                )
            )
        }
        let fairness = try [
            SchedulerFairnessState(
                subjectID: "tenant-0",
                projectID: "mixed",
                usage: vector(cpu: 1, memory: 1),
                guarantee: vector(cpu: 3, memory: 4),
                quota: vector(cpu: 12, memory: 24),
                pendingDemand: vector(cpu: 1),
                starvationAgeUnits: 5,
                weight: 1
            ),
            SchedulerFairnessState(
                subjectID: "tenant-1",
                projectID: "mixed",
                usage: vector(cpu: 2, memory: 1),
                guarantee: vector(cpu: 4, memory: 4),
                quota: vector(cpu: 12, memory: 24),
                pendingDemand: vector(cpu: 1),
                starvationAgeUnits: 0,
                weight: 2
            )
        ]
        return Phase10SchedulerQualification.Scenario(
            label: "mixed-\(index)",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: workloads.reversed(),
                nodes: nodes.reversed(),
                fairnessStates: fairness.reversed(),
                antiChurnThresholdBasisPoints: 250,
                queuePolicy: SchedulerQueuePolicy(
                    priorityPrecedesFairness: true,
                    starvationAgeThresholdUnits: 4
                ),
                snapshotQuality: SchedulerSnapshotQuality(
                    confidenceBasisPoints: 9_000,
                    stalenessUnits: 1,
                    sourceGeneration: "phase10-mixed"
                )
            ),
            oracleMode: .none
        )
    }

    private static func emptyFeasibilityScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let nodeID = identifier(seed: seed, slot: 1)
        let workloadID = identifier(seed: seed, slot: 2)
        let node = try node(
            id: nodeID,
            capacity: vector(cpu: 2, memory: 2),
            health: .unhealthy
        )
        let workload = try workload(
            id: workloadID,
            cpu: 1,
            memory: 1,
            priority: 1,
            subject: "empty",
            project: "boundary"
        )
        return Phase10SchedulerQualification.Scenario(
            label: "empty-feasibility",
            seed: seed,
            input: try SchedulerEngineInput(pendingWorkloads: [workload], nodes: [node]),
            oracleMode: .none
        )
    }

    private static func exactTieScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let lowerID = identifier(seed: seed, slot: 10)
        let higherID = identifier(seed: seed, slot: 11)
        let workloadID = identifier(seed: seed, slot: 12)
        let nodes = try [
            node(id: higherID, capacity: vector(cpu: 4, memory: 4, disk: 4)),
            node(id: lowerID, capacity: vector(cpu: 4, memory: 4, disk: 4))
        ]
        let workload = try exactResourceWorkload(
            id: workloadID,
            cpu: 1,
            memory: 1,
            disk: 1
        )
        let weights = try SchedulerScoreWeights(
            fragmentation: 1,
            fairness: 0,
            topology: 0,
            locality: 0,
            hostPressureEnergy: 0,
            disruption: 0
        )
        return Phase10SchedulerQualification.Scenario(
            label: "exact-tie",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: nodes,
                scoringWeights: weights
            ),
            oracleMode: .lockedTieBreak
        )
    }

    private static func quotaAndBorrowingScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let node = try node(
            id: identifier(seed: seed, slot: 20),
            capacity: vector(cpu: 10, memory: 10)
        )
        let workload = try workload(
            id: identifier(seed: seed, slot: 21),
            cpu: 1,
            memory: 1,
            priority: 1,
            subject: "borrower",
            project: "fairness"
        )
        let borrower = try SchedulerFairnessState(
            subjectID: "borrower",
            projectID: "fairness",
            usage: vector(cpu: 2, memory: 2),
            guarantee: vector(cpu: 2, memory: 2),
            quota: vector(cpu: 8, memory: 8),
            pendingDemand: vector(cpu: 1, memory: 1),
            starvationAgeUnits: 4
        )
        let owner = try SchedulerFairnessState(
            subjectID: "owner",
            projectID: "fairness",
            usage: vector(cpu: 1, memory: 1),
            guarantee: vector(cpu: 8, memory: 8),
            quota: vector(cpu: 8, memory: 8),
            pendingDemand: .zero
        )
        return Phase10SchedulerQualification.Scenario(
            label: "quota-guarantee-borrowing",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [node],
                fairnessStates: [owner, borrower],
                queuePolicy: SchedulerQueuePolicy(
                    priorityPrecedesFairness: true,
                    starvationAgeThresholdUnits: 3
                )
            ),
            oracleMode: .none
        )
    }

    private static func topologyConflictScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let east = try node(
            id: identifier(seed: seed, slot: 30),
            capacity: vector(cpu: 4, memory: 4),
            topology: ["zone": "east"]
        )
        let west = try node(
            id: identifier(seed: seed, slot: 31),
            capacity: vector(cpu: 4, memory: 4),
            topology: ["zone": "west"]
        )
        let firstID = identifier(seed: seed, slot: 32)
        let secondID = identifier(seed: seed, slot: 33)
        let first = try workload(
            id: firstID,
            cpu: 1,
            memory: 1,
            priority: 10,
            subject: "topology",
            project: "boundary",
            topology: try SchedulerTopologyPreference(groupID: "web", spreadKey: "zone")
        )
        let second = try workload(
            id: secondID,
            cpu: 1,
            memory: 1,
            priority: 1,
            subject: "topology",
            project: "boundary",
            topology: try SchedulerTopologyPreference(
                groupID: "web",
                spreadKey: "zone",
                antiAffinityWorkloadIDs: [firstID]
            )
        )
        return Phase10SchedulerQualification.Scenario(
            label: "topology-conflict",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [second, first],
                nodes: [west, east]
            ),
            oracleMode: .none
        )
    }

    private static func antiChurnScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let currentNodeID = identifier(seed: seed, slot: 40)
        let betterNodeID = identifier(seed: seed, slot: 41)
        let workloadID = identifier(seed: seed, slot: 42)
        let allocation = try vector(cpu: 2, memory: 2)
        let current = try node(
            id: currentNodeID,
            capacity: vector(cpu: 8, memory: 8),
            allocation: allocation,
            topology: ["zone": "east"]
        )
        let better = try node(
            id: betterNodeID,
            capacity: vector(cpu: 8, memory: 8),
            topology: ["zone": "west"]
        )
        let workload = try workload(
            id: workloadID,
            cpu: 2,
            memory: 2,
            priority: 1,
            subject: "stable",
            project: "boundary",
            locality: try SchedulerLocalityPreference(preferredNodeIDs: [betterNodeID])
        )
        let existing = try SchedulerExistingPlacement(
            workloadID: workloadID,
            nodeID: currentNodeID,
            allocation: allocation,
            stability: SchedulerPlacementStabilitySnapshot(residenceUnits: 0)
        )
        return Phase10SchedulerQualification.Scenario(
            label: "anti-churn",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [better, current],
                existingPlacements: [existing],
                antiChurnThresholdBasisPoints: 250,
                stabilityPolicy: SchedulerStabilityPolicy(minimumResidenceUnits: 10)
            ),
            oracleMode: .none
        )
    }

    private static func preemptionScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let nodeID = identifier(seed: seed, slot: 50)
        let workloadID = identifier(seed: seed, slot: 51)
        let victimID = identifier(seed: seed, slot: 52)
        let victimAllocation = try vector(cpu: 2, memory: 2, disk: 2)
        let node = try node(
            id: nodeID,
            capacity: vector(cpu: 5, memory: 5, disk: 5),
            allocation: victimAllocation,
            reservation: vector(cpu: 1, memory: 1, disk: 1)
        )
        let workload = try workload(
            id: workloadID,
            cpu: 4,
            memory: 4,
            disk: 4,
            priority: 10,
            subject: "incoming",
            project: "preemption",
            preemptionEligibility: .eligible
        )
        let victim = try SchedulerVictimAllocation(
            workloadID: victimID,
            nodeID: nodeID,
            allocation: victimAllocation,
            subjectID: "incoming",
            projectID: "preemption",
            priority: 0,
            disruptionCostBasisPoints: 2,
            budgetID: "budget-a"
        )
        let budget = try SchedulerDisruptionBudget(
            budgetID: "budget-a",
            projectID: "preemption",
            remainingVictimCount: 1,
            remainingDisruptionCostBasisPoints: 2
        )
        return Phase10SchedulerQualification.Scenario(
            label: "preemption",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [node],
                victimAllocations: [victim],
                disruptionBudgets: [budget],
                preemptionPolicy: SchedulerPreemptionPolicy(
                    incomingNonPreempting: false,
                    preemptionAuthorized: true,
                    minimumPriorityGap: 1,
                    authorizationReference: "phase10-qualification"
                )
            ),
            oracleMode: .none
        )
    }

    private static func disruptionExhaustionScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let scenario = try preemptionScenario(seed: seed)
        let exhaustedBudget = try SchedulerDisruptionBudget(
            budgetID: "budget-a",
            projectID: "preemption",
            remainingVictimCount: 0,
            remainingDisruptionCostBasisPoints: 0
        )
        return Phase10SchedulerQualification.Scenario(
            label: "disruption-exhaustion",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: scenario.input.pendingWorkloads,
                nodes: scenario.input.nodes,
                victimAllocations: scenario.input.victimAllocations,
                disruptionBudgets: [exhaustedBudget],
                preemptionPolicy: scenario.input.preemptionPolicy
            ),
            oracleMode: .none
        )
    }

    private static func preemptionOverlapScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let nodeID = identifier(seed: seed, slot: 70)
        let victimID = identifier(seed: seed, slot: 71)
        let firstWorkloadID = identifier(seed: seed, slot: 72)
        let secondWorkloadID = identifier(seed: seed, slot: 73)
        let victimAllocation = try vector(cpu: 2, memory: 2)
        let node = try node(
            id: nodeID,
            capacity: vector(cpu: 3, memory: 3),
            allocation: victimAllocation
        )
        let firstWorkload = try workload(
            id: firstWorkloadID,
            cpu: 2,
            memory: 2,
            priority: 10,
            subject: "incoming",
            project: "preemption-overlap",
            preemptionEligibility: .eligible
        )
        let secondWorkload = try workload(
            id: secondWorkloadID,
            cpu: 2,
            memory: 2,
            priority: 9,
            subject: "incoming",
            project: "preemption-overlap",
            preemptionEligibility: .eligible
        )
        let victim = try SchedulerVictimAllocation(
            workloadID: victimID,
            nodeID: nodeID,
            allocation: victimAllocation,
            subjectID: "victim",
            projectID: "preemption-overlap",
            priority: 0,
            disruptionCostBasisPoints: 1,
            budgetID: "budget-overlap"
        )
        let budget = try SchedulerDisruptionBudget(
            budgetID: "budget-overlap",
            projectID: "preemption-overlap",
            remainingVictimCount: 1,
            remainingDisruptionCostBasisPoints: 1
        )
        return Phase10SchedulerQualification.Scenario(
            label: "preemption-overlap",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [secondWorkload, firstWorkload],
                nodes: [node],
                victimAllocations: [victim],
                disruptionBudgets: [budget],
                preemptionPolicy: SchedulerPreemptionPolicy(
                    incomingNonPreempting: false,
                    preemptionAuthorized: true,
                    minimumPriorityGap: 1,
                    authorizationReference: "phase10-overlap"
                )
            ),
            oracleMode: .none
        )
    }

    static func exactPreemptionHardTopologyScenario(
        seed: UInt64,
        maxSkew: Int = 1,
        remainingVictimCount: Int = 1,
        remainingDisruptionCostBasisPoints: Int64 = 3
    ) throws -> Phase10SchedulerQualification.Scenario {
        let eastNodeID = identifier(seed: seed, slot: 8_200)
        let westNodeID = identifier(seed: seed, slot: 8_201)
        let workloadID = identifier(seed: seed, slot: 8_202)
        let targetVictimID = identifier(seed: seed, slot: 8_203)
        let anchorVictimIDs = (0..<3).map {
            identifier(seed: seed, slot: 8_204 + $0)
        }
        let topologyGroupID = "phase10-exact-preemption"
        let hardAffinity = try NodeAffinity(
            topologySpreads: [
                try SchedulerHardTopologySpread(
                    topologyKey: "zone",
                    maxSkew: maxSkew,
                    whenUnsatisfiable: .doNotSchedule,
                    groupID: topologyGroupID
                )
            ]
        )
        let workload = try workload(
            id: workloadID,
            cpu: 3,
            memory: 0,
            priority: 10,
            subject: "incoming",
            project: "exact-preemption",
            affinity: hardAffinity,
            preemptionEligibility: .eligible
        )
        let eastNode = try node(
            id: eastNodeID,
            capacity: vector(cpu: 4),
            allocation: vector(cpu: 3),
            topology: ["zone": "east"]
        )
        let westNode = try node(
            id: westNodeID,
            capacity: vector(cpu: 4),
            allocation: vector(cpu: 4),
            topology: ["zone": "west"]
        )
        let targetVictim = try SchedulerVictimAllocation(
            workloadID: targetVictimID,
            nodeID: eastNodeID,
            allocation: vector(cpu: 3),
            subjectID: "victim",
            projectID: "exact-preemption",
            priority: 0,
            disruptionCostBasisPoints: 3,
            budgetID: "budget-exact",
            topologyGroupID: topologyGroupID
        )
        let anchorVictims = try anchorVictimIDs.map { victimID in
            try SchedulerVictimAllocation(
                workloadID: victimID,
                nodeID: westNodeID,
                allocation: .zero,
                subjectID: "anchor",
                projectID: "exact-preemption",
                priority: 0,
                disruptionCostBasisPoints: 0,
                preemptible: false,
                topologyGroupID: topologyGroupID
            )
        }
        let budget = try SchedulerDisruptionBudget(
            budgetID: "budget-exact",
            projectID: "exact-preemption",
            remainingVictimCount: remainingVictimCount,
            remainingDisruptionCostBasisPoints: remainingDisruptionCostBasisPoints
        )
        return Phase10SchedulerQualification.Scenario(
            label: "exact-preemption-hard-topology",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [westNode, eastNode],
                victimAllocations: [targetVictim] + anchorVictims,
                disruptionBudgets: [budget],
                preemptionPolicy: SchedulerPreemptionPolicy(
                    incomingNonPreempting: false,
                    preemptionAuthorized: true,
                    minimumPriorityGap: 1,
                    authorizationReference: "phase10-exact-preemption"
                )
            ),
            oracleMode: .none
        )
    }

    private static func exactSearchBoundScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let nodeID = identifier(seed: seed, slot: 60)
        let workloadID = identifier(seed: seed, slot: 61)
        let victimOneID = identifier(seed: seed, slot: 62)
        let victimTwoID = identifier(seed: seed, slot: 63)
        let unit = try vector(cpu: 1, memory: 1)
        let node = try node(
            id: nodeID,
            capacity: vector(cpu: 3, memory: 3),
            allocation: try vector(cpu: 2, memory: 2)
        )
        let workload = try workload(
            id: workloadID,
            cpu: 3,
            memory: 3,
            priority: 10,
            subject: "incoming",
            project: "search-bound",
            preemptionEligibility: .eligible
        )
        let victims = try [
            SchedulerVictimAllocation(
                workloadID: victimOneID,
                nodeID: nodeID,
                allocation: unit,
                subjectID: "incoming",
                projectID: "search-bound",
                priority: 0,
                disruptionCostBasisPoints: 1
            ),
            SchedulerVictimAllocation(
                workloadID: victimTwoID,
                nodeID: nodeID,
                allocation: unit,
                subjectID: "incoming",
                projectID: "search-bound",
                priority: 0,
                disruptionCostBasisPoints: 1
            )
        ]
        let limits = try SchedulerEngineLimits(
            maxExactPreemptionVictimsPerNode: 2,
            maxExactPreemptionSearchStates: 1
        )
        return Phase10SchedulerQualification.Scenario(
            label: "exact-search-bound-exhaustion",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [node],
                victimAllocations: victims,
                preemptionPolicy: SchedulerPreemptionPolicy(
                    incomingNonPreempting: false,
                    preemptionAuthorized: true,
                    minimumPriorityGap: 1,
                    authorizationReference: "phase10-search-bound"
                ),
                limits: limits
            ),
            oracleMode: .none
        )
    }

    private static func identifier(seed: UInt64, slot: Int) -> UUID {
        let value = ((seed & 0x0000_FFFF_FFFF) << 16) | UInt64(slot & 0xFFFF)
        let suffix = String(value, radix: 16)
        let padded = String(repeating: "0", count: max(0, 12 - suffix.count)) + suffix
        return UUID(uuidString: "00000000-0000-0000-0000-\(padded)")!
    }

    private static func vector(
        cpu: Int64 = 0,
        memory: Int64 = 0,
        disk: Int64 = 0,
        gpu: Int64 = 0
    ) throws -> ResourceVector {
        var values: [String: Int64] = [:]
        if cpu > 0 { values["cpu"] = cpu }
        if memory > 0 { values["memory"] = memory }
        if disk > 0 { values["disk"] = disk }
        if gpu > 0 { values["gpu"] = gpu }
        return try ResourceVector(values)
    }

    private static func node(
        id: UUID,
        capacity: ResourceVector,
        allocation: ResourceVector = .zero,
        reservation: ResourceVector = .zero,
        architecture: String = "arm64",
        topology: [String: String] = [:],
        labels: [String: String]? = nil,
        posture: SchedulerHostPosture = SchedulerHostPosture(),
        health: SchedulerNodeHealth = .healthy,
        acceleratorAvailability: ResourceVector = .zero
    ) throws -> SchedulerNode {
        try SchedulerNode(
            snapshot: NodePlacementSnapshot(
                nodeID: id,
                capacity: capacity,
                allocation: allocation,
                architecture: architecture,
                runtime: "linux-vm",
                provider: "provider",
                capabilities: ["network", "storage"],
                health: health,
                labels: labels ?? ["pool": "general", "zone": topology["zone"] ?? "none"],
                acceleratorAvailability: acceleratorAvailability
            ),
            topologyDomains: topology,
            posture: posture,
            reservation: reservation,
            availableVolumeIDs: ["volume-0", "volume-1"],
            availablePorts: [8_080, 8_081, 8_082, 8_083],
            availableNetworkIDs: ["network-0", "network-1"]
        )
    }

    private static func workload(
        id: UUID,
        cpu: Int64,
        memory: Int64,
        disk: Int64 = 0,
        priority: Int64,
        subject: String,
        project: String,
        requiredArchitectures: [String] = [],
        acceleratorGPU: Int64 = 0,
        affinity: NodeAffinity = .none,
        topology: SchedulerTopologyPreference = .none,
        locality: SchedulerLocalityPreference = .none,
        constraints: SchedulerAdditionalPlacementConstraints = .none,
        overhead: ResourceVector = .zero,
        safetyMargin: ResourceVector = .zero,
        preemptionEligibility: SchedulerWorkloadPreemptionEligibility = .nonPreempting
    ) throws -> SchedulerWorkload {
        try SchedulerWorkload(
            requirements: WorkloadPlacementRequirements(
                workloadID: id,
                request: vector(cpu: cpu, memory: memory, disk: disk),
                requiredArchitectures: requiredArchitectures,
                requiredRuntime: "linux-vm",
                requiredProvider: "provider",
                requiredCapabilities: ["network"],
                affinity: affinity,
                acceleratorRequirements: vector(gpu: acceleratorGPU)
            ),
            priority: priority,
            subjectID: subject,
            projectID: project,
            topology: topology,
            locality: locality,
            constraints: constraints,
            overhead: overhead,
            safetyMargin: safetyMargin,
            preemptionEligibility: preemptionEligibility
        )
    }

    private static func exactResourceWorkload(
        id: UUID,
        cpu: Int64,
        memory: Int64,
        disk: Int64,
        priority: Int64 = 0,
        subject: String = "exact",
        project: String = "oracle"
    ) throws -> SchedulerWorkload {
        try SchedulerWorkload(
            requirements: WorkloadPlacementRequirements(
                workloadID: id,
                request: vector(cpu: cpu, memory: memory, disk: disk)
            ),
            priority: priority,
            subjectID: subject,
            projectID: project
        )
    }
}
