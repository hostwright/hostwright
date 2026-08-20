import CryptoKit
import Foundation
import XCTest
@testable import HostwrightCluster

// Source-only admission tests. They do not contact a node, execute a command, stream bytes,
// persist state, retry an operation, or prove multi-host behavior.
final class ClusterRemoteOperationAdmissionTests: XCTestCase {
    func testExactAuthorityProducesDigestOnlyAdmissionRecord() throws {
        let fixture = try makeFixture()

        let decision = ClusterRemoteOperationAdmissionEvaluator().evaluate(
            intent: fixture.intent,
            sessionHandoff: fixture.handoff,
            desiredState: fixture.desired,
            mutationProof: fixture.proof,
            nowMilliseconds: 150
        )

        guard case let .accepted(record) = decision else {
            return XCTFail("expected accepted admission, got \(decision)")
        }
        XCTAssertEqual(record.intent, fixture.intent)
        XCTAssertEqual(record.clusterID, fixture.desired.clusterID)
        XCTAssertEqual(record.targetNodeID, fixture.handoff.nodeID)
        XCTAssertEqual(record.membershipEpoch, fixture.desired.membershipEpoch)
        XCTAssertEqual(record.fencingToken, fixture.desired.fencingToken)
        XCTAssertEqual(record.sessionHandoffSHA256, sha256(try fixture.handoff.canonicalData()))
        XCTAssertEqual(record.desiredStateSHA256, try fixture.desired.canonicalSHA256())
        XCTAssertEqual(record.mutationProofSHA256, try fixture.proof.canonicalSHA256())
        XCTAssertEqual(record.payloadDisclosure, .sha256Only)
        XCTAssertFalse(record.executesOperation)
        XCTAssertFalse(record.provesRemoteDelivery)
    }

    func testSessionAndDeadlineWindowsFailClosed() throws {
        let fixture = try makeFixture()
        let evaluator = ClusterRemoteOperationAdmissionEvaluator()

        XCTAssertEqual(
            evaluator.evaluate(
                intent: fixture.intent,
                sessionHandoff: fixture.handoff,
                desiredState: fixture.desired,
                mutationProof: fixture.proof,
                nowMilliseconds: 99
            ),
            .rejected(.sessionNotYetValid)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                intent: fixture.intent,
                sessionHandoff: fixture.handoff,
                desiredState: fixture.desired,
                mutationProof: fixture.proof,
                nowMilliseconds: 500
            ),
            .rejected(.sessionExpired)
        )

        let expiredIntent = try makeIntent(deadlineAtMilliseconds: 150)
        let expiredProof = try ClusterMutationProof(
            mutationID: expiredIntent.operationID,
            mutationSHA256: expiredIntent.canonicalSHA256(),
            replicatedDesiredState: fixture.desired
        )
        XCTAssertEqual(
            evaluator.evaluate(
                intent: expiredIntent,
                sessionHandoff: fixture.handoff,
                desiredState: fixture.desired,
                mutationProof: expiredProof,
                nowMilliseconds: 150
            ),
            .rejected(.deadlineExpired)
        )

        let excessiveIntent = try makeIntent(deadlineAtMilliseconds: 501)
        let excessiveProof = try ClusterMutationProof(
            mutationID: excessiveIntent.operationID,
            mutationSHA256: excessiveIntent.canonicalSHA256(),
            replicatedDesiredState: fixture.desired
        )
        XCTAssertEqual(
            evaluator.evaluate(
                intent: excessiveIntent,
                sessionHandoff: fixture.handoff,
                desiredState: fixture.desired,
                mutationProof: excessiveProof,
                nowMilliseconds: 150
            ),
            .rejected(.deadlineExceedsSession)
        )
    }

    func testIntentDesiredStateAndSessionBindingsRejectEveryMismatch() throws {
        let fixture = try makeFixture()
        let evaluator = ClusterRemoteOperationAdmissionEvaluator()

        let cases: [(ClusterRemoteOperationIntent, ClusterSessionHandoff,
            ClusterReplicatedDesiredState, ClusterRemoteOperationAdmissionRejection)] = [
            (
                try makeIntent(targetNodeID: otherNodeID()),
                fixture.handoff,
                fixture.desired,
                .targetNodeMismatch
            ),
            (
                try makeIntent(projectID: "project-other"),
                fixture.handoff,
                fixture.desired,
                .projectMismatch
            ),
            (
                try makeIntent(desiredRevision: 3),
                fixture.handoff,
                fixture.desired,
                .desiredRevisionMismatch
            ),
            (
                try makeIntent(desiredGeneration: 8),
                fixture.handoff,
                fixture.desired,
                .desiredGenerationMismatch
            ),
            (
                fixture.intent,
                try makeHandoff(clusterID: otherClusterID()),
                fixture.desired,
                .clusterMismatch
            ),
            (
                fixture.intent,
                try makeHandoff(membershipEpoch: 8),
                fixture.desired,
                .membershipEpochMismatch
            ),
            (
                fixture.intent,
                try makeHandoff(fencingToken: 12),
                fixture.desired,
                .fencingTokenMismatch
            ),
        ]

        for (intent, handoff, desired, rejection) in cases {
            let proof = try ClusterMutationProof(
                mutationID: intent.operationID,
                mutationSHA256: intent.canonicalSHA256(),
                replicatedDesiredState: desired
            )
            XCTAssertEqual(
                evaluator.evaluate(
                    intent: intent,
                    sessionHandoff: handoff,
                    desiredState: desired,
                    mutationProof: proof,
                    nowMilliseconds: 150
                ),
                .rejected(rejection)
            )
        }
    }

    func testMutationProofMustBindExactIntentAndDesiredRecord() throws {
        let fixture = try makeFixture()
        let evaluator = ClusterRemoteOperationAdmissionEvaluator()
        let wrongID = try ClusterMutationProof(
            mutationID: "operation-other",
            mutationSHA256: fixture.intent.canonicalSHA256(),
            replicatedDesiredState: fixture.desired
        )
        let wrongDigest = try ClusterMutationProof(
            mutationID: fixture.intent.operationID,
            mutationSHA256: digest("f"),
            replicatedDesiredState: fixture.desired
        )
        let otherDesired = try makeDesired(contentSHA256: digest("9"))
        let wrongSource = try ClusterMutationProof(
            mutationID: fixture.intent.operationID,
            mutationSHA256: fixture.intent.canonicalSHA256(),
            replicatedDesiredState: otherDesired
        )

        XCTAssertEqual(
            evaluate(fixture, proof: wrongID, evaluator: evaluator),
            .rejected(.operationIDMismatch)
        )
        XCTAssertEqual(
            evaluate(fixture, proof: wrongDigest, evaluator: evaluator),
            .rejected(.operationDigestMismatch)
        )
        XCTAssertEqual(
            evaluate(fixture, proof: wrongSource, evaluator: evaluator),
            .rejected(.mutationFenceRejected)
        )
    }

    func testIntentWireContractIsCanonicalClosedBoundedAndDuplicateSafe() throws {
        let intent = try makeIntent()
        let encoded = try ClusterRemoteOperationIntentWireContract.encode(intent)
        XCTAssertEqual(try ClusterRemoteOperationIntentWireContract.decode(encoded), intent)
        XCTAssertEqual(try ClusterRemoteOperationIntentWireContract.encode(intent), encoded)
        XCTAssertFalse(isDirectlyDecodable(ClusterRemoteOperationIntent.self))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["future"] = true
        XCTAssertThrowsError(try decode(object))
        object.removeValue(forKey: "future")
        object.removeValue(forKey: "deadlineAtMilliseconds")
        XCTAssertThrowsError(try decode(object))

        let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let fragment = #""schemaVersion":1"#
        let range = try XCTUnwrap(source.range(of: fragment))
        let duplicate = source.replacingCharacters(in: range, with: fragment + "," + fragment)
        XCTAssertThrowsError(
            try ClusterRemoteOperationIntentWireContract.decode(Data(duplicate.utf8))
        )
        XCTAssertThrowsError(
            try ClusterRemoteOperationIntentWireContract.decode(
                Data(repeating: 32, count: ClusterRemoteOperationContract.maximumWireBytes + 1)
            )
        )

        let noncanonical = Data(" \n\(source)\n".utf8)
        XCTAssertThrowsError(try ClusterRemoteOperationIntentWireContract.decode(noncanonical))
    }

    func testIntentRejectsRawOrAmbiguousBoundaryValues() throws {
        XCTAssertThrowsError(try makeIntent(operationID: "bad operation"))
        XCTAssertThrowsError(try makeIntent(payloadSHA256: String(repeating: "A", count: 64)))
        XCTAssertThrowsError(try makeIntent(deadlineAtMilliseconds: 0))
    }

    private struct Fixture {
        let intent: ClusterRemoteOperationIntent
        let handoff: ClusterSessionHandoff
        let desired: ClusterReplicatedDesiredState
        let proof: ClusterMutationProof
    }

    private func makeFixture() throws -> Fixture {
        let intent = try makeIntent()
        let desired = try makeDesired()
        return Fixture(
            intent: intent,
            handoff: makeHandoff(),
            desired: desired,
            proof: ClusterMutationProof(
                mutationID: intent.operationID,
                mutationSHA256: intent.canonicalSHA256(),
                replicatedDesiredState: desired
            )
        )
    }

    private func makeIntent(
        operationID: String = "operation-1",
        projectID: String = "project-a",
        targetNodeID: ClusterNodeID? = nil,
        desiredRevision: UInt64 = 2,
        desiredGeneration: UInt64 = 7,
        payloadSHA256: String = String(repeating: "4", count: 64),
        deadlineAtMilliseconds: UInt64 = 400
    ) throws -> ClusterRemoteOperationIntent {
        try ClusterRemoteOperationIntent(
            operationID: operationID,
            projectID: ClusterReplicatedProjectID(projectID),
            targetNodeID: targetNodeID ?? nodeID(),
            desiredRevision: desiredRevision,
            desiredGeneration: desiredGeneration,
            kind: .exec,
            payloadSHA256: payloadSHA256,
            deadlineAtMilliseconds: deadlineAtMilliseconds
        )
    }

    private func makeHandoff(
        clusterID: ClusterID? = nil,
        membershipEpoch: UInt64 = 7,
        fencingToken: UInt64 = 11
    ) throws -> ClusterSessionHandoff {
        try ClusterSessionHandoff(
            sessionID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            clusterID: clusterID ?? self.clusterID(),
            nodeID: nodeID(),
            membershipEpoch: ClusterMembershipEpoch(membershipEpoch),
            subjectID: "node-agent",
            fencingToken: fencingToken,
            issuedAtMilliseconds: 100,
            expiresAtMilliseconds: 500
        )
    }

    private func makeDesired(
        contentSHA256: String = String(repeating: "2", count: 64)
    ) throws -> ClusterReplicatedDesiredState {
        try ClusterReplicatedDesiredState(
            clusterID: clusterID(),
            projectID: ClusterReplicatedProjectID("project-a"),
            revision: 2,
            desiredGeneration: 7,
            predecessorRecordSHA256: digest("1"),
            contentSHA256: contentSHA256,
            manifestSHA256: digest("3"),
            membershipEpoch: ClusterMembershipEpoch(7),
            fencingToken: 11,
            authorNodeID: authorNodeID(),
            operationID: "desired-operation",
            publishedAtMilliseconds: 90
        )
    }

    private func evaluate(
        _ fixture: Fixture,
        proof: ClusterMutationProof,
        evaluator: ClusterRemoteOperationAdmissionEvaluator
    ) -> ClusterRemoteOperationAdmissionDecision {
        evaluator.evaluate(
            intent: fixture.intent,
            sessionHandoff: fixture.handoff,
            desiredState: fixture.desired,
            mutationProof: proof,
            nowMilliseconds: 150
        )
    }

    private func decode(_ object: [String: Any]) throws -> ClusterRemoteOperationIntent {
        try ClusterRemoteOperationIntentWireContract.decode(
            JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private func clusterID() -> ClusterID {
        try! ClusterID("11111111-1111-1111-1111-111111111111")
    }

    private func otherClusterID() -> ClusterID {
        try! ClusterID("99999999-9999-9999-9999-999999999999")
    }

    private func nodeID() -> ClusterNodeID {
        try! ClusterNodeID("22222222-2222-2222-2222-222222222222")
    }

    private func otherNodeID() -> ClusterNodeID {
        try! ClusterNodeID("88888888-8888-8888-8888-888888888888")
    }

    private func authorNodeID() -> ClusterNodeID {
        try! ClusterNodeID("33333333-3333-3333-3333-333333333333")
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func sha256(_ data: Data) -> String {
        // Keep the expected value independent of the admission implementation.
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isDirectlyDecodable<T>(_: T.Type) -> Bool { false }
    private func isDirectlyDecodable<T: Decodable>(_: T.Type) -> Bool { true }
}
