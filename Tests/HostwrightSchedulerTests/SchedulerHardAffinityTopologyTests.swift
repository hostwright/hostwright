import Foundation
import XCTest
@testable import HostwrightScheduler

final class SchedulerHardAffinityTopologyTests: XCTestCase {
    func testManifestSelectorOperatorsAreCanonicalAndDeterministic() throws {
        let selectors = [
            try SchedulerLabelSelector(
                key: "zone",
                operator: .in,
                values: ["west", "east"]
            ),
            try SchedulerLabelSelector(key: "rack", operator: .exists),
            try SchedulerLabelSelector(
                key: "class",
                operator: .notIn,
                values: ["gpu"]
            ),
            try SchedulerLabelSelector(key: "spot", operator: .doesNotExist)
        ]
        let affinity = try NodeAffinity(
            requiredSelectors: selectors.reversed(),
            forbiddenSelectors: [
                try SchedulerLabelSelector(
                    key: "maintenance",
                    operator: .in,
                    values: ["planned"]
                )
            ]
        )

        XCTAssertEqual(affinity.requiredSelectors.map(\.orderingKey), [
            "class|not-in|gpu",
            "rack|exists|",
            "spot|does-not-exist|",
            "zone|in|east|west"
        ])
        XCTAssertTrue(affinity.requiredSelectors[0].matches(["class": "cpu"]))
        XCTAssertFalse(affinity.requiredSelectors[0].matches([:]))
        XCTAssertFalse(affinity.requiredSelectors[3].matches(["zone": "north"]))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(affinity)
        let decoded = try JSONDecoder().decode(NodeAffinity.self, from: encoded)
        XCTAssertEqual(decoded, affinity)
        XCTAssertEqual(try encoder.encode(decoded), encoded)
    }

    func testSelectorOperatorsProduceActionableHardFilterReasons() throws {
        let workload = try WorkloadPlacementRequirements(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            request: ResourceVector(["cpu": 1]),
            affinity: try NodeAffinity(
                requiredSelectors: [
                    try SchedulerLabelSelector(
                        key: "zone",
                        operator: .in,
                        values: ["east"]
                    ),
                    try SchedulerLabelSelector(key: "rack", operator: .exists),
                    try SchedulerLabelSelector(
                        key: "class",
                        operator: .notIn,
                        values: ["gpu"]
                    ),
                    try SchedulerLabelSelector(key: "spot", operator: .doesNotExist)
                ],
                forbiddenSelectors: [
                    try SchedulerLabelSelector(
                        key: "maintenance",
                        operator: .in,
                        values: ["planned"]
                    )
                ]
            )
        )
        let passingNode = try makeNode(
            id: "00000000-0000-0000-0000-000000000201",
            labels: ["zone": "east", "rack": "r1", "class": "cpu"]
        )
        let passing = HardPlacementFilterEvaluator().evaluate(
            workload: workload,
            on: passingNode
        )
        XCTAssertTrue(passing.passed)

        let failingNode = try makeNode(
            id: "00000000-0000-0000-0000-000000000202",
            labels: [
                "zone": "west",
                "class": "gpu",
                "spot": "true",
                "maintenance": "planned"
            ]
        )
        let failing = HardPlacementFilterEvaluator().evaluate(
            workload: workload,
            on: failingNode
        )
        XCTAssertEqual(
            failing.reasons.map(\.code),
            [
                .requiredLabelMissing,
                .requiredLabelMismatch,
                .requiredLabelMismatch,
                .requiredLabelMismatch,
                .forbiddenLabelPresent
            ]
        )
        XCTAssertTrue(
            failing.reasons.contains {
                $0.stableDetailKey.contains("required-selector:zone")
            }
        )
        XCTAssertTrue(
            failing.reasons.contains {
                $0.stableDetailKey.contains("forbidden-selector:maintenance")
            }
        )
    }

    func testSelectorBoundsAndOperatorShapesFailClosed() throws {
        XCTAssertThrowsError(
            try SchedulerLabelSelector(key: "zone", operator: .in)
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .invalidValue(field: "selector-values", value: 0)
            )
        }
        XCTAssertThrowsError(
            try SchedulerLabelSelector(
                key: "zone",
                operator: .exists,
                values: ["east"]
            )
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .invalidValue(field: "selector-values", value: 1)
            )
        }
        XCTAssertThrowsError(
            try SchedulerLabelSelector(
                key: "zone",
                operator: .in,
                values: ["east", "east"]
            )
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .duplicateIdentifier(field: "selector-values")
            )
        }
        XCTAssertThrowsError(
            try SchedulerLabelSelector(
                key: "zone",
                operator: .in,
                values: (0...SchedulerLabelSelector.maximumValueCount).map(String.init)
            )
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .countLimitExceeded(
                    field: "selector-values",
                    limit: SchedulerLabelSelector.maximumValueCount,
                    actual: SchedulerLabelSelector.maximumValueCount + 1
                )
            )
        }
        XCTAssertThrowsError(
            try SchedulerHardTopologySpread(topologyKey: "zone", maxSkew: 0)
        ) { error in
            XCTAssertEqual(
                error as? SchedulerEngineValidationError,
                .invalidCount(field: "topology-spread-max-skew", value: 0)
            )
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SchedulerLabelSelector.self,
                from: Data(#"{"key":"zone","operator":"in","values":[]}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SchedulerHardTopologySpread.self,
                from: Data(#"{"topologyKey":"zone","maxSkew":0,"whenUnsatisfiable":"do-not-schedule"}"#.utf8)
            )
        )
    }

    func testHardTopologySpreadUsesContextAndScheduleAnywayRemainsSoft() throws {
        let hardWorkload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000111",
            affinity: try NodeAffinity(
                topologySpreads: [
                    try SchedulerHardTopologySpread(
                        topologyKey: "zone",
                        maxSkew: 1,
                        whenUnsatisfiable: .doNotSchedule,
                        groupID: "project/service"
                    )
                ]
            )
        )
        let east = try makeNode(
            id: "00000000-0000-0000-0000-000000000211"
        )
        let west = try makeNode(
            id: "00000000-0000-0000-0000-000000000212"
        )
        let context = try HardTopologySpreadContext(
            nodeTopologyDomains: [
                west.nodeID: ["zone": "west"],
                east.nodeID: ["zone": "east"]
            ],
            observations: [
                try HardTopologySpreadObservation(
                    workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
                    nodeID: east.nodeID,
                    groupID: "project/service"
                )
            ]
        )

        let evaluator = HardPlacementFilterEvaluator()
        let withoutContext = evaluator.evaluate(
            workload: hardWorkload,
            on: east
        )
        XCTAssertFalse(withoutContext.passed)
        XCTAssertTrue(
            withoutContext.reasons.contains {
                $0.stableDetailKey == "topology-spread:zone:context-unavailable"
            }
        )
        let eastResult = evaluator.evaluate(
            workload: hardWorkload,
            on: east,
            topologyContext: context
        )
        let westResult = evaluator.evaluate(
            workload: hardWorkload,
            on: west,
            topologyContext: context
        )
        XCTAssertFalse(eastResult.passed)
        XCTAssertTrue(
            eastResult.reasons.contains {
                $0.stableDetailKey.contains("topology-spread:zone:max-skew:1")
            }
        )
        XCTAssertTrue(westResult.passed)

        let softWorkload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000112",
            affinity: try NodeAffinity(
                topologySpreads: [
                    try SchedulerHardTopologySpread(
                        topologyKey: "zone",
                        maxSkew: 1,
                        whenUnsatisfiable: .scheduleAnyway,
                        groupID: "project/service"
                    )
                ]
            )
        )
        XCTAssertTrue(
            evaluator.evaluate(
                workload: softWorkload,
                on: east,
                topologyContext: context
            ).passed
        )
    }

    func testTopologyContextAndSchedulerDigestAreStableAcrossInputOrder() throws {
        let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000221")!
        let otherNodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
        let observation = try HardTopologySpreadObservation(
            workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000321")!,
            nodeID: nodeID,
            groupID: "project/service"
        )
        let forward = try HardTopologySpreadContext(
            nodeTopologyDomains: [
                nodeID: ["zone": "east"],
                otherNodeID: ["zone": "west"]
            ],
            observations: [observation]
        )
        let reverse = try HardTopologySpreadContext(
            nodeTopologyDomains: [
                otherNodeID: ["zone": "west"],
                nodeID: ["zone": "east"]
            ],
            observations: [observation]
        )
        XCTAssertEqual(forward, reverse)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(forward), try encoder.encode(reverse))

        let affinity = try NodeAffinity(
            requiredSelectors: [
                try SchedulerLabelSelector(
                    key: "zone",
                    operator: .in,
                    values: ["east", "west"]
                )
            ],
            topologySpreads: [
                try SchedulerHardTopologySpread(
                    topologyKey: "zone",
                    maxSkew: 1,
                    groupID: "project/service"
                )
            ]
        )
        let workload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000121",
            affinity: affinity
        )
        let node = try makeNode(
            id: "00000000-0000-0000-0000-000000000231"
        )
        let input = try SchedulerEngineInput(
            pendingWorkloads: [
                SchedulerWorkload(
                    requirements: workload,
                    priority: 1,
                    subjectID: "subject",
                    projectID: "project"
                )
            ],
            nodes: [SchedulerNode(snapshot: node)]
        )
        let reorderedAffinity = try NodeAffinity(
            requiredSelectors: Array(affinity.requiredSelectors.reversed()),
            topologySpreads: Array(affinity.topologySpreads.reversed())
        )
        let reorderedWorkload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000121",
            affinity: reorderedAffinity
        )
        let reorderedInput = try SchedulerEngineInput(
            pendingWorkloads: [
                SchedulerWorkload(
                    requirements: reorderedWorkload,
                    priority: 1,
                    subjectID: "subject",
                    projectID: "project"
                )
            ],
            nodes: [SchedulerNode(snapshot: node)]
        )
        XCTAssertEqual(input.inputDigest, reorderedInput.inputDigest)

        let changedWorkload = try makeWorkload(
            id: "00000000-0000-0000-0000-000000000121",
            affinity: try NodeAffinity(
                requiredSelectors: [
                    try SchedulerLabelSelector(
                        key: "zone",
                        operator: .in,
                        values: ["east"]
                    )
                ],
                topologySpreads: affinity.topologySpreads
            )
        )
        let changedInput = try SchedulerEngineInput(
            pendingWorkloads: [
                SchedulerWorkload(
                    requirements: changedWorkload,
                    priority: 1,
                    subjectID: "subject",
                    projectID: "project"
                )
            ],
            nodes: [SchedulerNode(snapshot: node)]
        )
        XCTAssertNotEqual(input.inputDigest, changedInput.inputDigest)
    }

    private func makeWorkload(
        id: String,
        affinity: NodeAffinity = .none
    ) throws -> WorkloadPlacementRequirements {
        try WorkloadPlacementRequirements(
            workloadID: UUID(uuidString: id)!,
            request: ResourceVector(["cpu": 1]),
            affinity: affinity
        )
    }

    private func makeNode(
        id: String,
        labels: [String: String] = [:]
    ) throws -> NodePlacementSnapshot {
        try NodePlacementSnapshot(
            nodeID: UUID(uuidString: id)!,
            capacity: ResourceVector(["cpu": 4]),
            allocation: .zero,
            architecture: "arm64",
            runtime: "linux-vm",
            provider: "provider-a",
            labels: labels
        )
    }
}
