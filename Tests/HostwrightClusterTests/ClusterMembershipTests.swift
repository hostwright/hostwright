import Foundation
import XCTest
@testable import HostwrightCluster

final class ClusterMembershipTests: XCTestCase {
    func testIDsRequireLowercaseCanonicalUUIDs() throws {
        XCTAssertNoThrow(try ClusterID("11111111-1111-4111-8111-111111111111"))
        XCTAssertNoThrow(try ClusterNodeID("22222222-2222-4222-8222-222222222222"))
        XCTAssertThrowsError(try ClusterID("11111111-1111-4111-8111-11111111111"))
        XCTAssertThrowsError(try ClusterID("a1111111-b111-4111-8111-c11111111111".uppercased()))
        XCTAssertThrowsError(try ClusterNodeID("not-a-uuid"))
    }

    func testBootstrapIsDeterministicAndReplayIsIdempotent() throws {
        let clusterID = try ClusterID("11111111-1111-4111-8111-111111111111")
        let nodeID = try ClusterNodeID("22222222-2222-4222-8222-222222222222")
        let planner = ClusterMembershipPlanner()

        let first = try planner.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            peerEndpoint: "https://node-1.example.test:2380",
            clientEndpoint: "https://node-1.example.test:2379"
        )
        let second = try planner.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            peerEndpoint: "https://node-1.example.test:2380",
            clientEndpoint: "https://node-1.example.test:2379"
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.from.epoch, ClusterMembershipEpoch.initial)
        XCTAssertEqual(first.to.epoch, ClusterMembershipEpoch(1))
        XCTAssertEqual(first.after.voters.count, 1)
        XCTAssertEqual(first.transitions.map(\.sequence), [1])
        XCTAssertEqual(first.recovery.nextStep, 0)
        XCTAssertEqual(first.recovery.totalSteps, 1)

        let applied = try planner.apply(first, to: first.before)
        XCTAssertEqual(applied.disposition, .applied)
        XCTAssertEqual(applied.intent, first.after)

        let replayed = try planner.apply(first, to: first.after)
        XCTAssertEqual(replayed.disposition, .replayed)
        XCTAssertEqual(replayed.intent, first.after)
    }

    func testJoinAddsLearnerAndRejectsStaleDuplicateTokensAndIdentityReuse() throws {
        let clusterID = try ClusterID("11111111-1111-4111-8111-111111111111")
        let firstNode = try ClusterNodeID("22222222-2222-4222-8222-222222222222")
        let joiningNode = try ClusterNodeID("33333333-3333-4333-8333-333333333333")
        let planner = ClusterMembershipPlanner()
        let bootstrap = try planner.bootstrap(
            clusterID: clusterID,
            nodeID: firstNode,
            peerEndpoint: "https://node-1.example.test:2380"
        )
        let current = bootstrap.after
        let token = try ClusterJoinToken(
            tokenID: "join-token-1",
            clusterID: clusterID,
            nodeID: joiningNode,
            issuedEpoch: current.epoch,
            expiresAtEpoch: ClusterMembershipEpoch(4),
            secretSHA256: String(repeating: "a", count: 64)
        )
        let request = try ClusterJoinRequest(
            nodeID: joiningNode,
            token: token,
            peerEndpoint: "https://node-2.example.test:2380"
        )

        let plan = try planner.join(current: current, request: request)
        XCTAssertEqual(plan.operation, .joinLearner)
        XCTAssertEqual(plan.after.learners.map(\.nodeID), [joiningNode])
        XCTAssertEqual(plan.after.consumedJoinTokenIDs, ["join-token-1"])

        var consumed = plan.after
        XCTAssertThrowsError(try planner.join(current: consumed, request: request)) { error in
            XCTAssertEqual(error as? ClusterMembershipError, .duplicateJoinToken)
        }

        consumed = try ClusterMembershipIntent(
            clusterID: current.clusterID,
            epoch: ClusterMembershipEpoch(5),
            members: current.members
        )
        XCTAssertThrowsError(try planner.join(current: consumed, request: request)) { error in
            XCTAssertEqual(error as? ClusterMembershipError, .staleJoinToken)
        }

        let duplicateIdentityToken = try ClusterJoinToken(
            tokenID: "join-token-2",
            clusterID: clusterID,
            nodeID: firstNode,
            issuedEpoch: current.epoch,
            expiresAtEpoch: ClusterMembershipEpoch(4),
            secretSHA256: String(repeating: "b", count: 64)
        )
        let duplicateIdentityRequest = try ClusterJoinRequest(
            nodeID: firstNode,
            token: duplicateIdentityToken,
            peerEndpoint: "https://node-3.example.test:2380"
        )
        XCTAssertThrowsError(try planner.join(current: current, request: duplicateIdentityRequest)) { error in
            XCTAssertEqual(error as? ClusterMembershipError, .duplicateNodeIdentity(firstNode))
        }
    }

    func testPlanAndRecoverySerializationRejectTampering() throws {
        let clusterID = try ClusterID("11111111-1111-4111-8111-111111111111")
        let nodeID = try ClusterNodeID("22222222-2222-4222-8222-222222222222")
        let plan = try ClusterMembershipPlanner().bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            peerEndpoint: "https://node-1.example.test:2380"
        )

        let encoded = try plan.canonicalJSON()
        XCTAssertEqual(plan, try JSONDecoder().decode(ClusterMembershipPlan.self, from: encoded))
        let progressed = try plan.recovery.advancing()
        XCTAssertTrue(progressed.isComplete)
        XCTAssertThrowsError(try progressed.advancing())

        var tamperedPlan = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        tamperedPlan["planID"] = String(repeating: "0", count: 64)
        let tamperedPlanData = try JSONSerialization.data(withJSONObject: tamperedPlan)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ClusterMembershipPlan.self, from: tamperedPlanData)
        )

        let token = try ClusterJoinToken(
            tokenID: "serialization-token",
            clusterID: clusterID,
            nodeID: nodeID,
            issuedEpoch: .initial,
            secretSHA256: String(repeating: "a", count: 64)
        )
        var tamperedToken = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(token)) as? [String: Any]
        )
        tamperedToken["secretSHA256"] = "not-a-digest"
        let tamperedTokenData = try JSONSerialization.data(withJSONObject: tamperedToken)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ClusterJoinToken.self, from: tamperedTokenData)
        )
    }

    func testPromotionRemovalAndReplacementPreserveQuorum() throws {
        let clusterID = try ClusterID("11111111-1111-4111-8111-111111111111")
        let nodeIDs = try [
            ClusterNodeID("22222222-2222-4222-8222-222222222222"),
            ClusterNodeID("33333333-3333-4333-8333-333333333333"),
            ClusterNodeID("44444444-4444-4444-8444-444444444444")
        ]
        let planner = ClusterMembershipPlanner()
        let bootstrap = try planner.bootstrap(
            clusterID: clusterID,
            nodeID: nodeIDs[0],
            peerEndpoint: "https://node-1.example.test:2380"
        )
        let token = try ClusterJoinToken(
            tokenID: "join-token-3",
            clusterID: clusterID,
            nodeID: nodeIDs[1],
            issuedEpoch: bootstrap.after.epoch,
            expiresAtEpoch: ClusterMembershipEpoch(8),
            secretSHA256: String(repeating: "c", count: 64)
        )
        let joined = try planner.join(
            current: bootstrap.after,
            request: try ClusterJoinRequest(
                nodeID: nodeIDs[1],
                token: token,
                peerEndpoint: "https://node-2.example.test:2380"
            )
        )
        let promoted = try planner.promoteLearner(current: joined.after, nodeID: nodeIDs[1])
        XCTAssertEqual(promoted.after.voters.count, 2)
        XCTAssertThrowsError(try planner.removeVoter(current: promoted.after, nodeID: nodeIDs[1])) { error in
            XCTAssertEqual(error as? ClusterMembershipError, .quorumLoss)
        }

        let replacementToken = try ClusterJoinToken(
            tokenID: "join-token-4",
            clusterID: clusterID,
            nodeID: nodeIDs[2],
            issuedEpoch: bootstrap.after.epoch,
            expiresAtEpoch: ClusterMembershipEpoch(12),
            secretSHA256: String(repeating: "d", count: 64)
        )
        let replacement = try planner.replaceVoter(
            current: bootstrap.after,
            nodeID: nodeIDs[0],
            replacement: try ClusterJoinRequest(
                nodeID: nodeIDs[2],
                token: replacementToken,
                peerEndpoint: "https://node-3.example.test:2380"
            )
        )
        XCTAssertEqual(replacement.operation, .replaceVoter)
        XCTAssertEqual(replacement.transitions.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(replacement.after.voters.map(\.nodeID), [nodeIDs[2]])
        XCTAssertEqual(replacement.after.learners.count, 0)
    }

    func testTopologyRejectsDuplicateEndpointsAndMalformedTokenDigest() throws {
        let clusterID = try ClusterID("11111111-1111-4111-8111-111111111111")
        let nodeIDs = try [
            ClusterNodeID("22222222-2222-4222-8222-222222222222"),
            ClusterNodeID("33333333-3333-4333-8333-333333333333")
        ]
        XCTAssertThrowsError(
            try ClusterMembershipIntent(
                clusterID: clusterID,
                epoch: ClusterMembershipEpoch(1),
                members: [
                    try ClusterMembershipMember(
                        nodeID: nodeIDs[0],
                        role: .voter,
                        peerEndpoint: "https://same.example.test:2380"
                    ),
                    try ClusterMembershipMember(
                        nodeID: nodeIDs[1],
                        role: .learner,
                        peerEndpoint: "https://same.example.test:2380"
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(error as? ClusterMembershipError, .duplicateEndpoint("https://same.example.test:2380"))
        }

        XCTAssertThrowsError(
            try ClusterJoinToken(
                tokenID: "join-token-bad",
                clusterID: clusterID,
                nodeID: nodeIDs[0],
                issuedEpoch: .initial,
                expiresAtEpoch: ClusterMembershipEpoch(1),
                secretSHA256: "not-a-digest"
            )
        )
    }

    func testQuorumLossRefusalAcrossOneThreeAndFiveVoterTopologies() throws {
        let clusterID = try ClusterID("55555555-5555-4555-8555-555555555555")
        let nodeIDs = try (1...5).map { index in
            try ClusterNodeID(
                String(format: "%08d-%04d-4%03d-8%03d-%012d", index, index, index, index, index)
            )
        }
        let planner = ClusterMembershipPlanner()

        let one = try ClusterMembershipIntent(
            clusterID: clusterID,
            epoch: ClusterMembershipEpoch(1),
            members: [
                try ClusterMembershipMember(
                    nodeID: nodeIDs[0],
                    role: .voter,
                    peerEndpoint: "https://node-1.example.test:2380"
                )
            ]
        )
        XCTAssertThrowsError(try planner.removeVoter(current: one, nodeID: nodeIDs[0])) { error in
            XCTAssertEqual(error as? ClusterMembershipError, .quorumLoss)
        }

        let three = try ClusterMembershipIntent(
            clusterID: clusterID,
            epoch: ClusterMembershipEpoch(1),
            members: try nodeIDs.prefix(3).enumerated().map { index, nodeID in
                try ClusterMembershipMember(
                    nodeID: nodeID,
                    role: .voter,
                    peerEndpoint: "https://node-" + String(index + 1) + ".example.test:2380"
                )
            }
        )
        let threeAfterRemoval = try planner.removeVoter(current: three, nodeID: nodeIDs[0])
        XCTAssertEqual(threeAfterRemoval.after.voters.count, 2)
        XCTAssertThrowsError(
            try planner.removeVoter(current: threeAfterRemoval.after, nodeID: nodeIDs[1])
        ) { error in
            XCTAssertEqual(error as? ClusterMembershipError, .quorumLoss)
        }

        let five = try ClusterMembershipIntent(
            clusterID: clusterID,
            epoch: ClusterMembershipEpoch(1),
            members: try nodeIDs.enumerated().map { index, nodeID in
                try ClusterMembershipMember(
                    nodeID: nodeID,
                    role: .voter,
                    peerEndpoint: "https://node-" + String(index + 1) + ".example.test:2380"
                )
            }
        )
        let fiveAfterRemoval = try planner.removeVoter(current: five, nodeID: nodeIDs[0])
        XCTAssertEqual(fiveAfterRemoval.after.voters.count, 4)
    }
}
