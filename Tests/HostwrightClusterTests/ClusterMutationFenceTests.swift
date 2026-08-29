import Foundation
import XCTest
@testable import HostwrightCluster

// These checks cover only immutable source-record binding and pure classification. They do not
// exercise etcd, quorum, elections, persistence, replication, network authorization, provider
// mutation, failover, or a physical multi-host fence.
final class ClusterMutationFenceTests: XCTestCase {
    func testAllSourceDerivationsBindExactAuthorityWithoutCrossNamespaceConfusion() throws {
        let lease = try makeLease()
        let handoff = try makeHandoff()
        let sessionAuthority = try ClusterMutationAuthoritySnapshot(
            sessionHandoff: handoff,
            authorityLease: lease
        )
        let leaseAuthority = try ClusterMutationAuthoritySnapshot(
            controlPlaneLease: lease
        )

        XCTAssertEqual(sessionAuthority, leaseAuthority)
        XCTAssertEqual(sessionAuthority.authorityDigestKind, .leaseRecord)
        XCTAssertEqual(
            sessionAuthority.authorityRecordSHA256,
            try lease.canonicalSHA256()
        )

        let sessionProof = try ClusterMutationProof(
            mutationID: "mutation-session",
            mutationSHA256: digest("1"),
            sessionHandoff: handoff,
            authorityLease: lease
        )
        let leaseProof = try ClusterMutationProof(
            mutationID: "mutation-lease",
            mutationSHA256: digest("2"),
            controlPlaneLease: lease
        )
        XCTAssertEqual(sessionProof.authority, leaseProof.authority)
        XCTAssertEqual(sessionProof.source, .sessionHandoff)
        XCTAssertEqual(leaseProof.source, .controlPlaneLease)
        XCTAssertNotEqual(sessionProof.sourceRecordSHA256, leaseProof.sourceRecordSHA256)

        let predecessor = digest("a")
        let desired = try makeDesiredState(predecessorRecordSHA256: predecessor)
        let desiredAuthority = try ClusterMutationAuthoritySnapshot(
            replicatedDesiredState: desired
        )
        let desiredProof = try ClusterMutationProof(
            mutationID: "mutation-desired",
            mutationSHA256: digest("3"),
            replicatedDesiredState: desired
        )
        XCTAssertEqual(desiredProof.authority, desiredAuthority)
        XCTAssertEqual(desiredProof.source, .replicatedDesiredState)
        XCTAssertEqual(desiredAuthority.authorityDigestKind, .predecessorRecord)
        XCTAssertEqual(desiredAuthority.authorityRecordSHA256, predecessor)
        XCTAssertNotEqual(desiredAuthority, leaseAuthority)

        let genesis = try makeDesiredState(
            revision: 1,
            desiredGeneration: 1,
            predecessorRecordSHA256: nil
        )
        assertError(.missingPredecessorAuthority) {
            _ = try ClusterMutationAuthoritySnapshot(replicatedDesiredState: genesis)
        }
        assertError(.missingPredecessorAuthority) {
            _ = try ClusterMutationProof(
                mutationID: "mutation-genesis",
                mutationSHA256: digest("4"),
                replicatedDesiredState: genesis
            )
        }
    }

    func testSessionLeaseDerivationRejectsEveryMisalignedAuthorityField() throws {
        let lease = try makeLease()

        assertError(.sourceBindingMismatch("clusterID")) {
            _ = try ClusterMutationAuthoritySnapshot(
                sessionHandoff: makeHandoff(clusterID: otherClusterID()),
                authorityLease: lease
            )
        }
        assertError(.sourceBindingMismatch("actorNodeID")) {
            _ = try ClusterMutationAuthoritySnapshot(
                sessionHandoff: makeHandoff(nodeID: otherNodeID()),
                authorityLease: lease
            )
        }
        assertError(.sourceBindingMismatch("membershipEpoch")) {
            _ = try ClusterMutationAuthoritySnapshot(
                sessionHandoff: makeHandoff(membershipEpoch: 6),
                authorityLease: lease
            )
        }
        assertError(.sourceBindingMismatch("fencingToken")) {
            _ = try ClusterMutationAuthoritySnapshot(
                sessionHandoff: makeHandoff(fencingToken: 11),
                authorityLease: lease
            )
        }
    }

    func testEvaluatorAcceptsExactAuthorityAndClassifiesReplayWithoutMutation() throws {
        let lease = try makeLease()
        let expected = try ClusterMutationAuthoritySnapshot(controlPlaneLease: lease)
        let proof = try ClusterMutationProof(
            mutationID: "mutation-1",
            mutationSHA256: digest("1"),
            controlPlaneLease: lease
        )
        let evaluator = ClusterMutationFenceEvaluator()
        let expectedSourceRecord = try ClusterMutationSourceRecordBinding(
            controlPlaneLease: lease
        )

        XCTAssertEqual(
            evaluator.evaluate(
                current: nil,
                proposed: proof,
                expectedAuthority: expected,
                expectedSourceRecord: expectedSourceRecord
            ),
            .accepted(proof)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                current: proof,
                proposed: proof,
                expectedAuthority: expected,
                expectedSourceRecord: expectedSourceRecord
            ),
            .exactReplay(proof)
        )

        let conflict = try ClusterMutationProof(
            mutationID: proof.mutationID,
            mutationSHA256: digest("2"),
            controlPlaneLease: lease
        )
        XCTAssertEqual(
            evaluator.evaluate(
                current: proof,
                proposed: conflict,
                expectedAuthority: expected,
                expectedSourceRecord: expectedSourceRecord
            ),
            .rejected(
                .fencingTokenReplayConflict(
                    currentMutationID: proof.mutationID,
                    proposedMutationID: conflict.mutationID
                )
            )
        )

        let independent = try ClusterMutationProof(
            mutationID: "mutation-2",
            mutationSHA256: digest("2"),
            controlPlaneLease: lease
        )
        XCTAssertEqual(
            evaluator.evaluate(
                current: proof,
                proposed: independent,
                expectedAuthority: expected,
                expectedSourceRecord: expectedSourceRecord
            ),
            .rejected(
                .fencingTokenReplayConflict(
                    currentMutationID: proof.mutationID,
                    proposedMutationID: independent.mutationID
                )
            )
        )
    }

    func testEvaluatorRejectsWrongClusterEpochFenceActorAndAuthorityDigest() throws {
        let evaluator = ClusterMutationFenceEvaluator()
        let lease = try makeLease()
        let expected = try ClusterMutationAuthoritySnapshot(controlPlaneLease: lease)

        let wrongClusterLease = try makeLease(clusterID: otherClusterID())
        XCTAssertEqual(
            evaluate(
                try proof(from: wrongClusterLease),
                against: expected,
                sourceRecord: try ClusterMutationSourceRecordBinding(
                    controlPlaneLease: wrongClusterLease
                )
            ),
            .wrongCluster(
                expected: expected.clusterID,
                actual: wrongClusterLease.clusterID
            )
        )

        let staleEpochLease = try makeLease(membershipEpoch: 4)
        XCTAssertEqual(
            evaluate(
                try proof(from: staleEpochLease),
                against: expected,
                sourceRecord: try ClusterMutationSourceRecordBinding(
                    controlPlaneLease: staleEpochLease
                )
            ),
            .staleMembershipEpoch(
                expected: expected.membershipEpoch,
                actual: staleEpochLease.membershipEpoch
            )
        )

        let futureEpochLease = try makeLease(membershipEpoch: 6)
        XCTAssertEqual(
            evaluate(
                try proof(from: futureEpochLease),
                against: expected,
                sourceRecord: try ClusterMutationSourceRecordBinding(
                    controlPlaneLease: futureEpochLease
                )
            ),
            .newerMembershipEpochAmbiguous(
                expected: expected.membershipEpoch,
                actual: futureEpochLease.membershipEpoch
            )
        )

        let staleFenceLease = try makeLease(fencingToken: 9)
        XCTAssertEqual(
            evaluate(
                try proof(from: staleFenceLease),
                against: expected,
                sourceRecord: try ClusterMutationSourceRecordBinding(
                    controlPlaneLease: staleFenceLease
                )
            ),
            .staleFencingToken(expected: 10, actual: 9)
        )

        let wrongFenceLease = try makeLease(fencingToken: 11)
        XCTAssertEqual(
            evaluate(
                try proof(from: wrongFenceLease),
                against: expected,
                sourceRecord: try ClusterMutationSourceRecordBinding(
                    controlPlaneLease: wrongFenceLease
                )
            ),
            .wrongFencingToken(expected: 10, actual: 11)
        )

        let wrongActorLease = try makeLease(leaderNodeID: otherNodeID())
        XCTAssertEqual(
            evaluate(
                try proof(from: wrongActorLease),
                against: expected,
                sourceRecord: try ClusterMutationSourceRecordBinding(
                    controlPlaneLease: wrongActorLease
                )
            ),
            .wrongActor(
                expected: expected.actorNodeID,
                actual: wrongActorLease.leaderNodeID
            )
        )

        let changedLeaseRecord = try makeLease(
            issuedAtMilliseconds: 1_001,
            expiresAtMilliseconds: 1_101
        )
        let changedProof = try proof(from: changedLeaseRecord)
        XCTAssertEqual(
            evaluate(
                changedProof,
                against: expected,
                sourceRecord: try ClusterMutationSourceRecordBinding(
                    controlPlaneLease: changedLeaseRecord
                )
            ),
            .authorityDigestMismatch(
                expectedKind: .leaseRecord,
                expectedSHA256: expected.authorityRecordSHA256,
                actualKind: .leaseRecord,
                actualSHA256: changedProof.authority.authorityRecordSHA256
            )
        )

        let desired = try makeDesiredState(
            predecessorRecordSHA256: expected.authorityRecordSHA256
        )
        let desiredProof = try ClusterMutationProof(
            mutationID: "mutation-1",
            mutationSHA256: digest("1"),
            replicatedDesiredState: desired
        )
        XCTAssertEqual(
            evaluate(
                desiredProof,
                against: expected,
                sourceRecord: try ClusterMutationSourceRecordBinding(
                    replicatedDesiredState: desired
                )
            ),
            .authorityDigestMismatch(
                expectedKind: .leaseRecord,
                expectedSHA256: expected.authorityRecordSHA256,
                actualKind: .predecessorRecord,
                actualSHA256: expected.authorityRecordSHA256
            )
        )

        let expectedDesiredRecord = try makeDesiredState(
            predecessorRecordSHA256: digest("a")
        )
        let expectedDesired = try ClusterMutationAuthoritySnapshot(
            replicatedDesiredState: expectedDesiredRecord
        )
        let wrongPredecessorRecord = try makeDesiredState(
            predecessorRecordSHA256: digest("b")
        )
        let wrongPredecessorProof = try ClusterMutationProof(
            mutationID: "mutation-1",
            mutationSHA256: digest("1"),
            replicatedDesiredState: wrongPredecessorRecord
        )
        XCTAssertEqual(
            evaluate(
                wrongPredecessorProof,
                against: expectedDesired,
                sourceRecord: try ClusterMutationSourceRecordBinding(
                    replicatedDesiredState: wrongPredecessorRecord
                )
            ),
            .authorityDigestMismatch(
                expectedKind: .predecessorRecord,
                expectedSHA256: digest("a"),
                actualKind: .predecessorRecord,
                actualSHA256: digest("b")
            )
        )

        func evaluate(
            _ proposed: ClusterMutationProof,
            against authority: ClusterMutationAuthoritySnapshot,
            sourceRecord: ClusterMutationSourceRecordBinding
        ) -> ClusterMutationFenceRejection {
            let decision = evaluator.evaluate(
                current: nil,
                proposed: proposed,
                expectedAuthority: authority,
                expectedSourceRecord: sourceRecord
            )
            guard case .rejected(let rejection) = decision else {
                XCTFail("expected rejection, got \(decision)")
                return .invalidProofEncoding
            }
            return rejection
        }
    }

    func testCanonicalIdentityAndOrderingAreStable() throws {
        let lease = try makeLease()
        let first = try ClusterMutationProof(
            mutationID: "mutation-a",
            mutationSHA256: digest("1"),
            controlPlaneLease: lease
        )
        let firstCopy = try ClusterMutationProof(
            mutationID: "mutation-a",
            mutationSHA256: digest("1"),
            controlPlaneLease: lease
        )
        let second = try ClusterMutationProof(
            mutationID: "mutation-b",
            mutationSHA256: digest("2"),
            controlPlaneLease: lease
        )

        XCTAssertEqual(first, firstCopy)
        XCTAssertEqual(try first.canonicalJSON(), try firstCopy.canonicalJSON())
        XCTAssertEqual(try first.canonicalSHA256(), try firstCopy.canonicalSHA256())
        XCTAssertEqual([second, first].sorted(), [first, second])

        let encoded = try first.canonicalJSON()
        let decoded = try ClusterMutationFenceWireContract.decodeProof(encoded)
        XCTAssertEqual(decoded, first)
        XCTAssertEqual(try decoded.canonicalJSON(), encoded)
        XCTAssertEqual(try decoded.canonicalSHA256(), try first.canonicalSHA256())

        let snapshot = first.authority
        XCTAssertEqual(
            snapshot,
            try ClusterMutationFenceWireContract.decodeSnapshot(
                snapshot.canonicalJSON()
            )
        )
    }

    func testStrictSnapshotWireRejectsUnknownMissingDuplicateAndInvalidValues() throws {
        let snapshot = try ClusterMutationAuthoritySnapshot(
            clusterID: clusterID(),
            membershipEpoch: ClusterMembershipEpoch(5),
            actorNodeID: nodeID(),
            fencingToken: 10,
            authorityDigestKind: .leaseRecord,
            authorityRecordSHA256: digest("a")
        )
        let encoded = try ClusterMutationFenceWireContract.encodeSnapshot(snapshot)
        XCTAssertEqual(
            snapshot,
            try ClusterMutationFenceWireContract.decodeSnapshot(encoded)
        )

        var object = try jsonObject(encoded)
        object["unexpected"] = true
        XCTAssertThrowsError(
            try ClusterMutationFenceWireContract.decodeSnapshot(jsonData(object))
        )

        object.removeValue(forKey: "unexpected")
        object.removeValue(forKey: "actorNodeID")
        XCTAssertThrowsError(
            try ClusterMutationFenceWireContract.decodeSnapshot(jsonData(object))
        )

        let text = String(decoding: encoded, as: UTF8.self)
        let duplicate = "{\"schemaVersion\":1," + String(text.dropFirst())
        XCTAssertThrowsError(
            try ClusterMutationFenceWireContract.decodeSnapshot(Data(duplicate.utf8))
        )

        var unsupported = try jsonObject(encoded)
        unsupported["schemaVersion"] = 2
        assertError(.unsupportedSchemaVersion(2)) {
            try ClusterMutationFenceWireContract.decodeSnapshot(jsonData(unsupported))
        }

        var zeroFence = try jsonObject(encoded)
        zeroFence["fencingToken"] = 0
        assertError(.invalidFencingToken) {
            try ClusterMutationFenceWireContract.decodeSnapshot(jsonData(zeroFence))
        }

        var uppercaseDigest = try jsonObject(encoded)
        uppercaseDigest["authorityRecordSHA256"] = digest("A")
        assertError(.invalidDigest("authorityRecordSHA256")) {
            try ClusterMutationFenceWireContract.decodeSnapshot(jsonData(uppercaseDigest))
        }

        assertError(.wirePayloadOutOfBounds(actualBytes: 0)) {
            try ClusterMutationFenceWireContract.decodeSnapshot(Data())
        }
        let oversizedCount = ClusterMutationFenceContract.maximumWireBytes + 1
        assertError(.wirePayloadOutOfBounds(actualBytes: oversizedCount)) {
            try ClusterMutationFenceWireContract.decodeSnapshot(
                Data(repeating: 32, count: oversizedCount)
            )
        }
    }

    func testStrictProofWireAndEvaluatorRejectInvalidCodableInput() throws {
        let lease = try makeLease()
        let proof = try self.proof(from: lease)
        let encoded = try ClusterMutationFenceWireContract.encodeProof(proof)
        let evaluator = ClusterMutationFenceEvaluator()
        let expectedSourceRecord = try ClusterMutationSourceRecordBinding(
            controlPlaneLease: lease
        )

        var unknown = try jsonObject(encoded)
        unknown["credential"] = "must-not-be-carried"
        let unknownData = try jsonData(unknown)
        XCTAssertThrowsError(
            try ClusterMutationFenceWireContract.decodeProof(unknownData)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                current: nil,
                encodedProposed: unknownData,
                expectedAuthority: proof.authority,
                expectedSourceRecord: expectedSourceRecord
            ),
            .rejected(.invalidProofEncoding)
        )

        var missing = try jsonObject(encoded)
        missing.removeValue(forKey: "mutationSHA256")
        XCTAssertThrowsError(
            try ClusterMutationFenceWireContract.decodeProof(jsonData(missing))
        )

        let text = String(decoding: encoded, as: UTF8.self)
        let duplicate = "{\"mutationID\":\"mutation-1\"," + String(text.dropFirst())
        XCTAssertThrowsError(
            try ClusterMutationFenceWireContract.decodeProof(Data(duplicate.utf8))
        )

        var nestedEpoch = try jsonObject(encoded)
        nestedEpoch["membershipEpoch"] = ["value": 5]
        XCTAssertThrowsError(
            try ClusterMutationFenceWireContract.decodeProof(jsonData(nestedEpoch))
        )

        var invalidSource = try jsonObject(encoded)
        invalidSource["source"] = "future-source-v2"
        XCTAssertThrowsError(
            try ClusterMutationFenceWireContract.decodeProof(jsonData(invalidSource))
        )

        var invalidMutationID = try jsonObject(encoded)
        invalidMutationID["mutationID"] = "mutation/unsafe"
        assertError(.invalidMutationID) {
            try ClusterMutationFenceWireContract.decodeProof(jsonData(invalidMutationID))
        }

        var invalidSourceDigest = try jsonObject(encoded)
        invalidSourceDigest["sourceRecordSHA256"] = digest("A")
        assertError(.invalidDigest("sourceRecordSHA256")) {
            try ClusterMutationFenceWireContract.decodeProof(jsonData(invalidSourceDigest))
        }

        var forgedLeaseDigest = try jsonObject(encoded)
        forgedLeaseDigest["sourceRecordSHA256"] = digest("b")
        assertError(.sourceBindingMismatch("leaseRecordSHA256")) {
            try ClusterMutationFenceWireContract.decodeProof(jsonData(forgedLeaseDigest))
        }

        var wrongDigestNamespace = try jsonObject(encoded)
        wrongDigestNamespace["source"] = ClusterMutationProofSource.replicatedDesiredState.rawValue
        assertError(.sourceBindingMismatch("authorityDigestKind")) {
            try ClusterMutationFenceWireContract.decodeProof(jsonData(wrongDigestNamespace))
        }
    }

    func testEvaluatorRequiresExactTypedSourceRecordContextForSessionAndDesiredState()
        throws
    {
        let evaluator = ClusterMutationFenceEvaluator()
        let lease = try makeLease()
        let handoff = try makeHandoff()
        let sessionProof = try ClusterMutationProof(
            mutationID: "mutation-session",
            mutationSHA256: digest("1"),
            sessionHandoff: handoff,
            authorityLease: lease
        )
        let sessionBinding = try ClusterMutationSourceRecordBinding(
            sessionHandoff: handoff
        )
        XCTAssertEqual(
            evaluator.evaluate(
                current: nil,
                proposed: sessionProof,
                expectedAuthority: sessionProof.authority,
                expectedSourceRecord: sessionBinding
            ),
            .accepted(sessionProof)
        )
        var forgedSessionObject = try jsonObject(sessionProof.canonicalJSON())
        forgedSessionObject["sourceRecordSHA256"] = digest("e")
        let forgedSessionData = try jsonData(forgedSessionObject)
        let decodedForgedSession = try ClusterMutationFenceWireContract.decodeProof(
            forgedSessionData
        )
        XCTAssertEqual(decodedForgedSession.sourceRecordSHA256, digest("e"))
        XCTAssertEqual(
            evaluator.evaluate(
                current: nil,
                encodedProposed: forgedSessionData,
                expectedAuthority: sessionProof.authority,
                expectedSourceRecord: sessionBinding
            ),
            .rejected(
                .sourceRecordDigestMismatch(
                    expectedSHA256: sessionBinding.sourceRecordSHA256,
                    actualSHA256: digest("e")
                )
            )
        )

        let desiredState = try makeDesiredState(
            predecessorRecordSHA256: digest("a")
        )
        let desiredProof = try ClusterMutationProof(
            mutationID: "mutation-desired",
            mutationSHA256: digest("2"),
            replicatedDesiredState: desiredState
        )
        let desiredBinding = try ClusterMutationSourceRecordBinding(
            replicatedDesiredState: desiredState
        )
        XCTAssertEqual(
            evaluator.evaluate(
                current: nil,
                proposed: desiredProof,
                expectedAuthority: desiredProof.authority,
                expectedSourceRecord: desiredBinding
            ),
            .accepted(desiredProof)
        )
        var forgedDesiredObject = try jsonObject(desiredProof.canonicalJSON())
        forgedDesiredObject["sourceRecordSHA256"] = digest("f")
        let forgedDesiredData = try jsonData(forgedDesiredObject)
        let decodedForgedDesired = try ClusterMutationFenceWireContract.decodeProof(
            forgedDesiredData
        )
        XCTAssertEqual(decodedForgedDesired.sourceRecordSHA256, digest("f"))
        XCTAssertEqual(
            evaluator.evaluate(
                current: nil,
                encodedProposed: forgedDesiredData,
                expectedAuthority: desiredProof.authority,
                expectedSourceRecord: desiredBinding
            ),
            .rejected(
                .sourceRecordDigestMismatch(
                    expectedSHA256: desiredBinding.sourceRecordSHA256,
                    actualSHA256: digest("f")
                )
            )
        )

        XCTAssertEqual(
            evaluator.evaluate(
                current: nil,
                proposed: sessionProof,
                expectedAuthority: sessionProof.authority,
                expectedSourceRecord: nil
            ),
            .rejected(.missingSourceRecordBinding)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                current: nil,
                proposed: sessionProof,
                expectedAuthority: sessionProof.authority,
                expectedSourceRecord: desiredBinding
            ),
            .rejected(
                .sourceRecordKindMismatch(
                    expected: .replicatedDesiredState,
                    actual: .sessionHandoff
                )
            )
        )
    }

    func testPublicSnapshotValidationRejectsUnsafeScalarInputs() throws {
        assertError(.invalidFencingToken) {
            _ = try ClusterMutationAuthoritySnapshot(
                clusterID: clusterID(),
                membershipEpoch: ClusterMembershipEpoch(5),
                actorNodeID: nodeID(),
                fencingToken: 0,
                authorityDigestKind: .leaseRecord,
                authorityRecordSHA256: digest("a")
            )
        }
        assertError(.invalidDigest("authorityRecordSHA256")) {
            _ = try ClusterMutationAuthoritySnapshot(
                clusterID: clusterID(),
                membershipEpoch: ClusterMembershipEpoch(5),
                actorNodeID: nodeID(),
                fencingToken: 1,
                authorityDigestKind: .leaseRecord,
                authorityRecordSHA256: "not-a-digest"
            )
        }
    }

    private func proof(
        from lease: ClusterControlPlaneLeaseRecord
    ) throws -> ClusterMutationProof {
        try ClusterMutationProof(
            mutationID: "mutation-1",
            mutationSHA256: digest("1"),
            controlPlaneLease: lease
        )
    }

    private func makeLease(
        clusterID: ClusterID? = nil,
        leaderNodeID: ClusterNodeID? = nil,
        membershipEpoch: UInt64 = 5,
        fencingToken: UInt64 = 10,
        issuedAtMilliseconds: UInt64 = 1_000,
        expiresAtMilliseconds: UInt64 = 1_100
    ) throws -> ClusterControlPlaneLeaseRecord {
        try ClusterControlPlaneLeaseRecord(
            clusterID: clusterID ?? self.clusterID(),
            leaderNodeID: leaderNodeID ?? nodeID(),
            membershipEpoch: ClusterMembershipEpoch(membershipEpoch),
            fencingToken: fencingToken,
            term: 1,
            sequence: 1,
            issuedAtMilliseconds: issuedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds,
            predecessorRecordSHA256: nil
        )
    }

    private func makeHandoff(
        clusterID: ClusterID? = nil,
        nodeID: ClusterNodeID? = nil,
        membershipEpoch: UInt64 = 5,
        fencingToken: UInt64 = 10
    ) throws -> ClusterSessionHandoff {
        try ClusterSessionHandoff(
            sessionID: "44444444-4444-4444-8444-444444444444",
            clusterID: clusterID ?? self.clusterID(),
            nodeID: nodeID ?? self.nodeID(),
            membershipEpoch: ClusterMembershipEpoch(membershipEpoch),
            subjectID: "node-agent",
            fencingToken: fencingToken,
            issuedAtMilliseconds: 900,
            expiresAtMilliseconds: 1_200
        )
    }

    private func makeDesiredState(
        revision: UInt64 = 2,
        desiredGeneration: UInt64 = 2,
        predecessorRecordSHA256: String?
    ) throws -> ClusterReplicatedDesiredState {
        try ClusterReplicatedDesiredState(
            clusterID: clusterID(),
            projectID: ClusterReplicatedProjectID("project-alpha"),
            revision: revision,
            desiredGeneration: desiredGeneration,
            predecessorRecordSHA256: predecessorRecordSHA256,
            contentSHA256: digest("c"),
            manifestSHA256: digest("d"),
            membershipEpoch: ClusterMembershipEpoch(5),
            fencingToken: 10,
            authorNodeID: nodeID(),
            operationID: "operation-desired",
            publishedAtMilliseconds: 1_000
        )
    }

    private func clusterID() throws -> ClusterID {
        try ClusterID("11111111-1111-4111-8111-111111111111")
    }

    private func otherClusterID() throws -> ClusterID {
        try ClusterID("99999999-9999-4999-8999-999999999999")
    }

    private func nodeID() throws -> ClusterNodeID {
        try ClusterNodeID("22222222-2222-4222-8222-222222222222")
    }

    private func otherNodeID() throws -> ClusterNodeID {
        try ClusterNodeID("33333333-3333-4333-8333-333333333333")
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func assertError(
        _ expected: ClusterMutationFenceError,
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? ClusterMutationFenceError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
