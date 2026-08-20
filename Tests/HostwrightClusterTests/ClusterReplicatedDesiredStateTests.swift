import Foundation
import XCTest
@testable import HostwrightCluster

final class ClusterReplicatedDesiredStateTests: XCTestCase {
    func testCreateAndUpdateUseCASAndReplayOnlyWithDurablePredecessorProof() throws {
        let authority = try makeAuthority(epoch: 5, fencingToken: 7)
        let first = try makeState(
            revision: 1,
            desiredGeneration: 1,
            content: "a",
            manifest: "b",
            epoch: 5,
            fencingToken: 7,
            operationID: "operation-create",
            publishedAtMilliseconds: 1_000
        )
        let create = try ClusterReplicatedDesiredStateProposal(
            expectation: .absent,
            next: first
        )
        let publisher = ClusterReplicatedDesiredStatePublisher()

        XCTAssertEqual(
            try publisher.decide(current: nil, proposal: create, authority: authority),
            .created(first)
        )
        XCTAssertEqual(
            try publisher.decide(current: first, proposal: create, authority: authority),
            .replayed(first)
        )

        let second = try makeState(
            revision: 2,
            desiredGeneration: 2,
            predecessorRecordSHA256: try first.canonicalSHA256(),
            content: "c",
            manifest: "d",
            epoch: 5,
            fencingToken: 7,
            operationID: "operation-update",
            publishedAtMilliseconds: 1_001
        )
        let update = try ClusterReplicatedDesiredStateProposal(
            expectation: .record(
                revision: first.revision,
                recordSHA256: try first.canonicalSHA256()
            ),
            next: second
        )

        XCTAssertEqual(
            try publisher.decide(current: first, proposal: update, authority: authority),
            .updated(second)
        )
        XCTAssertEqual(
            try publisher.decide(current: second, proposal: update, authority: authority),
            .replayed(second)
        )

        let forgedReplay = try ClusterReplicatedDesiredStateProposal(
            expectation: .record(
                revision: first.revision,
                recordSHA256: digest("z")
            ),
            next: second
        )
        assertError(.staleCAS) {
            try publisher.decide(
                current: second,
                proposal: forgedReplay,
                authority: authority
            )
        }
    }

    func testCASRejectsStaleExpectationGapsAndOverflow() throws {
        let authority = try makeAuthority(epoch: 2, fencingToken: 4)
        let current = try makeState(epoch: 2, fencingToken: 4)
        let publisher = ClusterReplicatedDesiredStatePublisher()

        let next = try makeState(
            revision: 2,
            desiredGeneration: 2,
            predecessorRecordSHA256: try current.canonicalSHA256(),
            content: "c",
            manifest: "d",
            epoch: 2,
            fencingToken: 4,
            operationID: "operation-2",
            publishedAtMilliseconds: 2
        )
        let staleRevision = try ClusterReplicatedDesiredStateProposal(
            expectation: .record(
                revision: 2,
                recordSHA256: try current.canonicalSHA256()
            ),
            next: next
        )
        assertError(.staleCAS) {
            try publisher.decide(
                current: current,
                proposal: staleRevision,
                authority: authority
            )
        }

        let staleDigest = try ClusterReplicatedDesiredStateProposal(
            expectation: .record(
                revision: current.revision,
                recordSHA256: digest("f")
            ),
            next: next
        )
        assertError(.staleCAS) {
            try publisher.decide(current: current, proposal: staleDigest, authority: authority)
        }

        let wrongPredecessor = try makeState(
            revision: 2,
            desiredGeneration: 2,
            predecessorRecordSHA256: digest("e"),
            content: "c",
            manifest: "d",
            epoch: 2,
            fencingToken: 4,
            operationID: "operation-wrong-predecessor",
            publishedAtMilliseconds: 2
        )
        assertError(.staleCAS) {
            try publisher.decide(
                current: current,
                proposal: try proposal(after: current, next: wrongPredecessor),
                authority: authority
            )
        }

        let malformedReplay = try ClusterReplicatedDesiredStateProposal(
            expectation: .record(
                revision: current.revision,
                recordSHA256: try current.canonicalSHA256()
            ),
            next: current
        )
        assertError(.staleCAS) {
            try publisher.decide(
                current: current,
                proposal: malformedReplay,
                authority: authority
            )
        }

        let revisionGap = try makeState(
            revision: 3,
            desiredGeneration: 2,
            predecessorRecordSHA256: try current.canonicalSHA256(),
            epoch: 2,
            fencingToken: 4,
            operationID: "operation-gap",
            publishedAtMilliseconds: 2
        )
        assertError(.revisionGap(expected: 2, actual: 3)) {
            try publisher.decide(
                current: current,
                proposal: try proposal(after: current, next: revisionGap),
                authority: authority
            )
        }

        let generationGap = try makeState(
            revision: 2,
            desiredGeneration: 3,
            predecessorRecordSHA256: try current.canonicalSHA256(),
            epoch: 2,
            fencingToken: 4,
            operationID: "operation-generation-gap",
            publishedAtMilliseconds: 2
        )
        assertError(.generationGap(expected: 2, actual: 3)) {
            try publisher.decide(
                current: current,
                proposal: try proposal(after: current, next: generationGap),
                authority: authority
            )
        }

        let exhausted = try makeState(
            revision: .max,
            desiredGeneration: .max,
            predecessorRecordSHA256: digest("e"),
            epoch: 2,
            fencingToken: 4
        )
        let impossible = try makeState(
            revision: .max,
            desiredGeneration: .max,
            predecessorRecordSHA256: try exhausted.canonicalSHA256(),
            content: "c",
            epoch: 2,
            fencingToken: 4,
            operationID: "operation-overflow",
            publishedAtMilliseconds: 2
        )
        assertError(.counterOverflow) {
            try publisher.decide(
                current: exhausted,
                proposal: try proposal(after: exhausted, next: impossible),
                authority: authority
            )
        }
    }

    func testAuthorityRejectsEpochFenceAndAuthorMismatchButAllowsEqualFence() throws {
        let current = try makeState(epoch: 4, fencingToken: 9)
        let validNext = try makeState(
            revision: 2,
            desiredGeneration: 2,
            predecessorRecordSHA256: try current.canonicalSHA256(),
            epoch: 4,
            fencingToken: 9,
            operationID: "operation-2",
            publishedAtMilliseconds: 2
        )
        let publisher = ClusterReplicatedDesiredStatePublisher()

        XCTAssertEqual(
            try publisher.decide(
                current: current,
                proposal: try proposal(after: current, next: validNext),
                authority: try makeAuthority(epoch: 4, fencingToken: 9)
            ),
            .updated(validNext)
        )

        let wrongEpoch = try makeState(
            revision: 2,
            desiredGeneration: 2,
            predecessorRecordSHA256: try current.canonicalSHA256(),
            epoch: 3,
            fencingToken: 9,
            operationID: "operation-wrong-epoch",
            publishedAtMilliseconds: 2
        )
        assertError(
            .membershipEpochMismatch(expected: ClusterMembershipEpoch(4), actual: ClusterMembershipEpoch(3))
        ) {
            try publisher.decide(
                current: current,
                proposal: try proposal(after: current, next: wrongEpoch),
                authority: try makeAuthority(epoch: 4, fencingToken: 9)
            )
        }

        assertError(.membershipEpochRegression) {
            try publisher.decide(
                current: current,
                proposal: try proposal(after: current, next: wrongEpoch),
                authority: try makeAuthority(epoch: 3, fencingToken: 9)
            )
        }

        let wrongFence = try makeState(
            revision: 2,
            desiredGeneration: 2,
            predecessorRecordSHA256: try current.canonicalSHA256(),
            epoch: 4,
            fencingToken: 8,
            operationID: "operation-wrong-fence",
            publishedAtMilliseconds: 2
        )
        assertError(.fencingTokenMismatch(expected: 9, actual: 8)) {
            try publisher.decide(
                current: current,
                proposal: try proposal(after: current, next: wrongFence),
                authority: try makeAuthority(epoch: 4, fencingToken: 9)
            )
        }

        assertError(.staleFencingToken) {
            try publisher.decide(
                current: current,
                proposal: try proposal(after: current, next: wrongFence),
                authority: try makeAuthority(epoch: 4, fencingToken: 8)
            )
        }

        let otherAuthor = try ClusterNodeID("33333333-3333-4333-8333-333333333333")
        assertError(.authorNodeMismatch) {
            try publisher.decide(
                current: current,
                proposal: try proposal(after: current, next: validNext),
                authority: try makeAuthority(
                    epoch: 4,
                    fencingToken: 9,
                    authorNodeID: otherAuthor
                )
            )
        }
    }

    func testClusterProjectTimestampAndOperationBindingsFailClosed() throws {
        let current = try makeState(
            epoch: 2,
            fencingToken: 2,
            publishedAtMilliseconds: 10
        )
        let authority = try makeAuthority(epoch: 2, fencingToken: 2)
        let publisher = ClusterReplicatedDesiredStatePublisher()
        let otherCluster = try ClusterID("44444444-4444-4444-8444-444444444444")

        let crossCluster = try makeState(
            clusterID: otherCluster,
            revision: 2,
            desiredGeneration: 2,
            predecessorRecordSHA256: try current.canonicalSHA256(),
            epoch: 2,
            fencingToken: 2,
            operationID: "operation-cross-cluster",
            publishedAtMilliseconds: 11
        )
        assertError(.clusterMismatch) {
            try publisher.decide(
                current: current,
                proposal: try proposal(after: current, next: crossCluster),
                authority: authority
            )
        }

        let crossProject = try makeState(
            projectID: "project-other",
            revision: 2,
            desiredGeneration: 2,
            predecessorRecordSHA256: try current.canonicalSHA256(),
            epoch: 2,
            fencingToken: 2,
            operationID: "operation-cross-project",
            publishedAtMilliseconds: 11
        )
        assertError(.projectMismatch) {
            try publisher.decide(
                current: current,
                proposal: try proposal(after: current, next: crossProject),
                authority: authority
            )
        }

        let timestampRollback = try makeState(
            revision: 2,
            desiredGeneration: 2,
            predecessorRecordSHA256: try current.canonicalSHA256(),
            epoch: 2,
            fencingToken: 2,
            operationID: "operation-time",
            publishedAtMilliseconds: 9
        )
        assertError(.timestampRegression) {
            try publisher.decide(
                current: current,
                proposal: try proposal(after: current, next: timestampRollback),
                authority: authority
            )
        }

        let operationReplay = try makeState(
            revision: 2,
            desiredGeneration: 2,
            predecessorRecordSHA256: try current.canonicalSHA256(),
            epoch: 2,
            fencingToken: 2,
            operationID: current.operationID,
            publishedAtMilliseconds: 11
        )
        assertError(.operationReplayConflict) {
            try publisher.decide(
                current: current,
                proposal: try proposal(after: current, next: operationReplay),
                authority: authority
            )
        }
    }

    func testRecordBoundaryRejectsInvalidIdentifiersDigestsCountersAndFence() throws {
        assertError(.invalidProjectID("other")) {
            _ = try ClusterReplicatedProjectID("other")
        }
        assertError(.invalidProjectID("project-a/escape")) {
            _ = try ClusterReplicatedProjectID("project-a/escape")
        }
        assertError(.invalidDigest("contentSHA256")) {
            _ = try makeState(contentSHA256: digest("A"))
        }
        assertError(.invalidDigest("manifestSHA256")) {
            _ = try makeState(manifestSHA256: "sha256:" + digest("a"))
        }
        assertError(.invalidRevision) {
            _ = try makeState(revision: 0)
        }
        assertError(.invalidGeneration) {
            _ = try makeState(desiredGeneration: 0)
        }
        assertError(.invalidPredecessor) {
            _ = try makeState(predecessorRecordSHA256: digest("f"))
        }
        assertError(.invalidPredecessor) {
            _ = try makeState(revision: 2, desiredGeneration: 2)
        }
        assertError(.invalidDigest("predecessorRecordSHA256")) {
            _ = try makeState(
                revision: 2,
                desiredGeneration: 2,
                predecessorRecordSHA256: digest("A")
            )
        }
        assertError(.invalidFencingToken) {
            _ = try makeState(fencingToken: 0)
        }
        assertError(.invalidOperationID) {
            _ = try makeState(operationID: "operation/escape")
        }
        assertError(.invalidTimestamp) {
            _ = try makeState(publishedAtMilliseconds: 0)
        }
    }

    func testReplicaApplicationIsDeterministicAndRejectsForksAndOlderSnapshots() throws {
        let first = try makeState()
        let second = try makeState(
            revision: 2,
            desiredGeneration: 2,
            predecessorRecordSHA256: try first.canonicalSHA256(),
            content: "c",
            manifest: "d",
            operationID: "operation-2",
            publishedAtMilliseconds: 2
        )
        let replica = ClusterReplicatedDesiredStateReplica()

        XCTAssertEqual(try replica.apply(first, to: nil), .applied(first))
        XCTAssertEqual(try replica.apply(first, to: first), .replayed(first))
        XCTAssertEqual(try replica.apply(second, to: first), .applied(second))

        let wrongPredecessor = try makeState(
            revision: 2,
            desiredGeneration: 2,
            predecessorRecordSHA256: digest("e"),
            content: "c",
            manifest: "d",
            operationID: "operation-wrong-predecessor",
            publishedAtMilliseconds: 2
        )
        assertError(.staleCAS) {
            try replica.apply(wrongPredecessor, to: first)
        }

        let fork = try makeState(content: "f")
        assertError(.sameRevisionConflict) {
            try replica.apply(fork, to: first)
        }
        assertError(.staleSnapshot) {
            try replica.apply(first, to: second)
        }

        let gap = try makeState(
            revision: 3,
            desiredGeneration: 3,
            predecessorRecordSHA256: try first.canonicalSHA256(),
            operationID: "operation-3",
            publishedAtMilliseconds: 3
        )
        assertError(.revisionGap(expected: 2, actual: 3)) {
            try replica.apply(gap, to: first)
        }
    }

    func testStrictWireBoundaryRejectsUnknownDuplicateMissingAndMalformedFields() throws {
        let state = try makeState()
        let encoded = try ClusterReplicatedDesiredStateWireContract.encode(state)
        XCTAssertEqual(
            state,
            try ClusterReplicatedDesiredStateWireContract.decodeState(encoded)
        )
        XCTAssertEqual(encoded, try ClusterReplicatedDesiredStateWireContract.encode(state))

        var unknown = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        unknown["unexpected"] = true
        XCTAssertThrowsError(
            try ClusterReplicatedDesiredStateWireContract.decodeState(
                JSONSerialization.data(withJSONObject: unknown)
            )
        )

        let text = String(decoding: encoded, as: UTF8.self)
        let duplicate = "{\"schemaVersion\":1," + String(text.dropFirst())
        XCTAssertThrowsError(
            try ClusterReplicatedDesiredStateWireContract.decodeState(Data(duplicate.utf8))
        )

        unknown.removeValue(forKey: "unexpected")
        unknown.removeValue(forKey: "manifestSHA256")
        XCTAssertThrowsError(
            try ClusterReplicatedDesiredStateWireContract.decodeState(
                JSONSerialization.data(withJSONObject: unknown)
            )
        )

        var missingPredecessor = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        missingPredecessor.removeValue(forKey: "predecessorRecordSHA256")
        assertError(.invalidPredecessor) {
            try JSONDecoder().decode(
                ClusterReplicatedDesiredState.self,
                from: JSONSerialization.data(withJSONObject: missingPredecessor)
            )
        }

        var unsupported = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        unsupported["schemaVersion"] = 2
        assertError(.unsupportedSchemaVersion(2)) {
            try ClusterReplicatedDesiredStateWireContract.decodeState(
                JSONSerialization.data(withJSONObject: unsupported)
            )
        }

        XCTAssertThrowsError(
            try ClusterReplicatedDesiredStateWireContract.decodeState(
                Data(text.dropLast().utf8)
            )
        )
    }

    func testProposalWireMakesCreateAbsenceExplicitAndRejectsPartialCAS() throws {
        let state = try makeState()
        let create = try ClusterReplicatedDesiredStateProposal(
            expectation: .absent,
            next: state
        )
        let encoded = try ClusterReplicatedDesiredStateWireContract.encode(create)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertTrue(object["expectedRevision"] is NSNull)
        XCTAssertTrue(object["expectedRecordSHA256"] is NSNull)
        XCTAssertTrue(object["predecessorRecordSHA256"] is NSNull)
        XCTAssertEqual(
            create,
            try ClusterReplicatedDesiredStateWireContract.decodeProposal(encoded)
        )

        var partial = object
        partial["expectedRecordSHA256"] = digest("a")
        assertError(.invalidExpectation) {
            try ClusterReplicatedDesiredStateWireContract.decodeProposal(
                JSONSerialization.data(withJSONObject: partial)
            )
        }

        var unknown = object
        unknown["transport"] = "etcd"
        XCTAssertThrowsError(
            try ClusterReplicatedDesiredStateWireContract.decodeProposal(
                JSONSerialization.data(withJSONObject: unknown)
            )
        )

        var missingPredecessor = object
        missingPredecessor.removeValue(forKey: "predecessorRecordSHA256")
        XCTAssertThrowsError(
            try ClusterReplicatedDesiredStateWireContract.decodeProposal(
                JSONSerialization.data(withJSONObject: missingPredecessor)
            )
        )
        for key in ["expectedRevision", "expectedRecordSHA256"] {
            var missingCASKey = object
            missingCASKey.removeValue(forKey: key)
            assertError(.invalidExpectation) {
                try JSONDecoder().decode(
                    ClusterReplicatedDesiredStateProposal.self,
                    from: JSONSerialization.data(withJSONObject: missingCASKey)
                )
            }
        }
    }

    func testOrderingAndCanonicalEqualityAreStable() throws {
        let a = try makeState(projectID: "project-a")
        let aCopy = try makeState(projectID: "project-a")
        let b = try makeState(projectID: "project-b")
        let next = try makeState(
            projectID: "project-a",
            revision: 2,
            desiredGeneration: 2,
            predecessorRecordSHA256: try a.canonicalSHA256(),
            operationID: "operation-2",
            publishedAtMilliseconds: 2
        )

        XCTAssertEqual(a, aCopy)
        XCTAssertEqual(try a.canonicalSHA256(), try aCopy.canonicalSHA256())
        XCTAssertEqual([next, b, a].sorted(), [a, next, b])
    }

    private func makeState(
        clusterID: ClusterID? = nil,
        projectID: String = "project-alpha",
        revision: UInt64 = 1,
        desiredGeneration: UInt64 = 1,
        predecessorRecordSHA256: String? = nil,
        content: Character = "a",
        manifest: Character = "b",
        contentSHA256: String? = nil,
        manifestSHA256: String? = nil,
        epoch: UInt64 = 1,
        fencingToken: UInt64 = 1,
        authorNodeID: ClusterNodeID? = nil,
        operationID: String = "operation-1",
        publishedAtMilliseconds: UInt64 = 1
    ) throws -> ClusterReplicatedDesiredState {
        try ClusterReplicatedDesiredState(
            clusterID: clusterID
                ?? ClusterID("11111111-1111-4111-8111-111111111111"),
            projectID: ClusterReplicatedProjectID(projectID),
            revision: revision,
            desiredGeneration: desiredGeneration,
            predecessorRecordSHA256: predecessorRecordSHA256,
            contentSHA256: contentSHA256 ?? digest(content),
            manifestSHA256: manifestSHA256 ?? digest(manifest),
            membershipEpoch: ClusterMembershipEpoch(epoch),
            fencingToken: fencingToken,
            authorNodeID: authorNodeID
                ?? ClusterNodeID("22222222-2222-4222-8222-222222222222"),
            operationID: operationID,
            publishedAtMilliseconds: publishedAtMilliseconds
        )
    }

    private func makeAuthority(
        epoch: UInt64,
        fencingToken: UInt64,
        authorNodeID: ClusterNodeID? = nil
    ) throws -> ClusterReplicatedDesiredStateAuthority {
        try ClusterReplicatedDesiredStateAuthority(
            clusterID: ClusterID("11111111-1111-4111-8111-111111111111"),
            membershipEpoch: ClusterMembershipEpoch(epoch),
            fencingToken: fencingToken,
            authorNodeID: authorNodeID
                ?? ClusterNodeID("22222222-2222-4222-8222-222222222222")
        )
    }

    private func proposal(
        after current: ClusterReplicatedDesiredState,
        next: ClusterReplicatedDesiredState
    ) throws -> ClusterReplicatedDesiredStateProposal {
        try ClusterReplicatedDesiredStateProposal(
            expectation: .record(
                revision: current.revision,
                recordSHA256: try current.canonicalSHA256()
            ),
            next: next
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func assertError<T>(
        _ expected: ClusterReplicatedDesiredStateError,
        _ operation: () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? ClusterReplicatedDesiredStateError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
