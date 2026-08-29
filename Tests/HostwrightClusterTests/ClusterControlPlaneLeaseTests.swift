import Foundation
import XCTest
@testable import HostwrightCluster

// These are source-level unit-contract checks for an immutable transition classifier. They do
// not exercise etcd, campaigns, sessions, durability, quorum, failover, partitions, or hosts.
final class ClusterControlPlaneLeaseTests: XCTestCase {
    func testAcquireRenewReplayAndExpiryBoundaryReplacementAreDeterministic() throws {
        let evaluator = ClusterControlPlaneLeaseDecisionEvaluator()
        let first = try makeRecord(
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 1_100
        )
        let firstAuthority = try makeAuthority()
        let acquire = try ClusterControlPlaneLeaseProposal(
            expectation: .absent,
            next: first
        )

        XCTAssertEqual(
            try evaluator.decide(
                current: nil,
                proposal: acquire,
                authority: firstAuthority,
                nowMilliseconds: 1_000
            ),
            .acquire(first)
        )
        XCTAssertFalse(first.isExpired(atMilliseconds: 1_099))
        XCTAssertTrue(first.isExpired(atMilliseconds: 1_100))

        let renewed = try makeRecord(
            term: 1,
            sequence: 2,
            issuedAtMilliseconds: 1_050,
            expiresAtMilliseconds: 1_150,
            predecessorRecordSHA256: try first.canonicalSHA256()
        )
        let renew = try proposal(after: first, next: renewed)
        XCTAssertEqual(
            try evaluator.decide(
                current: first,
                proposal: renew,
                authority: firstAuthority,
                nowMilliseconds: 1_050
            ),
            .renew(renewed)
        )
        XCTAssertEqual(
            try evaluator.decide(
                current: renewed,
                proposal: renew,
                authority: firstAuthority,
                nowMilliseconds: 1_100
            ),
            .exactReplay(renewed)
        )

        let replacementNodeID = try otherNodeID()
        let replaced = try makeRecord(
            leaderNodeID: replacementNodeID,
            fencingToken: 12,
            term: 2,
            sequence: 1,
            issuedAtMilliseconds: 1_150,
            expiresAtMilliseconds: 1_250,
            predecessorRecordSHA256: try renewed.canonicalSHA256()
        )
        let replacement = try proposal(after: renewed, next: replaced)
        let replacementAuthority = try makeAuthority(
            nodeID: replacementNodeID,
            fencingToken: 12
        )
        XCTAssertEqual(
            try evaluator.decide(
                current: renewed,
                proposal: replacement,
                authority: replacementAuthority,
                nowMilliseconds: 1_150
            ),
            .replaceExpired(replaced)
        )
        XCTAssertEqual(
            try evaluator.decide(
                current: replaced,
                proposal: replacement,
                authority: replacementAuthority,
                nowMilliseconds: 1_200
            ),
            .exactReplay(replaced)
        )
    }

    func testActiveNonHolderCannotTakeOverAndExpiredTermCannotBeRenewed() throws {
        let evaluator = ClusterControlPlaneLeaseDecisionEvaluator()
        let current = try makeRecord(
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 1_100
        )
        let replacementNodeID = try otherNodeID()
        let replacement = try makeRecord(
            leaderNodeID: replacementNodeID,
            fencingToken: 8,
            term: 2,
            sequence: 1,
            issuedAtMilliseconds: 1_099,
            expiresAtMilliseconds: 1_200,
            predecessorRecordSHA256: try current.canonicalSHA256()
        )
        let replacementProposal = try proposal(after: current, next: replacement)
        let replacementAuthority = try makeAuthority(
            nodeID: replacementNodeID,
            fencingToken: 8
        )

        assertError(.activeLeaseHeldByOther(current.leaderNodeID)) {
            try evaluator.decide(
                current: current,
                proposal: replacementProposal,
                authority: replacementAuthority,
                nowMilliseconds: 1_099
            )
        }

        let expiredRenewal = try makeRecord(
            term: 1,
            sequence: 2,
            issuedAtMilliseconds: 1_100,
            expiresAtMilliseconds: 1_200,
            predecessorRecordSHA256: try current.canonicalSHA256()
        )
        assertError(.termGap(expected: 2, actual: 1)) {
            try evaluator.decide(
                current: current,
                proposal: try proposal(after: current, next: expiredRenewal),
                authority: try makeAuthority(),
                nowMilliseconds: 1_100
            )
        }
    }

    func testReplayRequiresExactDurablePredecessorTermAndDigest() throws {
        let evaluator = ClusterControlPlaneLeaseDecisionEvaluator()
        let genesis = try makeRecord()
        let genesisProposal = try ClusterControlPlaneLeaseProposal(
            expectation: .absent,
            next: genesis
        )
        XCTAssertEqual(
            try evaluator.decide(
                current: genesis,
                proposal: genesisProposal,
                authority: try makeAuthority(),
                nowMilliseconds: 1_050
            ),
            .exactReplay(genesis)
        )

        let renewed = try makeRecord(
            sequence: 2,
            issuedAtMilliseconds: 1_050,
            expiresAtMilliseconds: 1_150,
            predecessorRecordSHA256: try genesis.canonicalSHA256()
        )
        let wrongTerm = try ClusterControlPlaneLeaseProposal(
            expectation: .record(
                term: 2,
                recordSHA256: try genesis.canonicalSHA256()
            ),
            next: renewed
        )
        assertError(.forgedReplay) {
            try evaluator.decide(
                current: renewed,
                proposal: wrongTerm,
                authority: try makeAuthority(),
                nowMilliseconds: 1_100
            )
        }

        let wrongDigest = try ClusterControlPlaneLeaseProposal(
            expectation: .record(term: 1, recordSHA256: digest("f")),
            next: renewed
        )
        assertError(.forgedReplay) {
            try evaluator.decide(
                current: renewed,
                proposal: wrongDigest,
                authority: try makeAuthority(),
                nowMilliseconds: 1_100
            )
        }

        let replacementNodeID = try otherNodeID()
        let replaced = try makeRecord(
            leaderNodeID: replacementNodeID,
            fencingToken: 8,
            term: 2,
            sequence: 1,
            issuedAtMilliseconds: 1_150,
            expiresAtMilliseconds: 1_250,
            predecessorRecordSHA256: try renewed.canonicalSHA256()
        )
        let forgedReplacementReplay = try ClusterControlPlaneLeaseProposal(
            expectation: .record(
                term: 2,
                recordSHA256: try renewed.canonicalSHA256()
            ),
            next: replaced
        )
        assertError(.forgedReplay) {
            try evaluator.decide(
                current: replaced,
                proposal: forgedReplacementReplay,
                authority: try makeAuthority(
                    nodeID: replacementNodeID,
                    fencingToken: 8
                ),
                nowMilliseconds: 1_200
            )
        }
    }

    func testAuthorityMustMatchExactClusterEpochFenceAndLeaderIdentity() throws {
        let evaluator = ClusterControlPlaneLeaseDecisionEvaluator()
        let current = try makeRecord(
            membershipEpoch: 5,
            fencingToken: 8,
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 1_100
        )
        let next = try makeRecord(
            membershipEpoch: 5,
            fencingToken: 8,
            sequence: 2,
            issuedAtMilliseconds: 1_050,
            expiresAtMilliseconds: 1_150,
            predecessorRecordSHA256: try current.canonicalSHA256()
        )
        let validProposal = try proposal(after: current, next: next)

        let otherCluster = try ClusterID("33333333-3333-4333-8333-333333333333")
        assertError(.clusterMismatch) {
            try evaluator.decide(
                current: current,
                proposal: validProposal,
                authority: try makeAuthority(
                    clusterID: otherCluster,
                    membershipEpoch: 5,
                    fencingToken: 8
                ),
                nowMilliseconds: 1_050
            )
        }

        assertError(
            .membershipEpochMismatch(
                expected: ClusterMembershipEpoch(6),
                actual: ClusterMembershipEpoch(5)
            )
        ) {
            try evaluator.decide(
                current: current,
                proposal: validProposal,
                authority: try makeAuthority(membershipEpoch: 6, fencingToken: 8),
                nowMilliseconds: 1_050
            )
        }

        let staleEpochNext = try makeRecord(
            membershipEpoch: 4,
            fencingToken: 8,
            sequence: 2,
            issuedAtMilliseconds: 1_050,
            expiresAtMilliseconds: 1_150,
            predecessorRecordSHA256: try current.canonicalSHA256()
        )
        assertError(.membershipEpochRegression) {
            try evaluator.decide(
                current: current,
                proposal: try proposal(after: current, next: staleEpochNext),
                authority: try makeAuthority(membershipEpoch: 4, fencingToken: 8),
                nowMilliseconds: 1_050
            )
        }

        assertError(.fencingTokenMismatch(expected: 9, actual: 8)) {
            try evaluator.decide(
                current: current,
                proposal: validProposal,
                authority: try makeAuthority(membershipEpoch: 5, fencingToken: 9),
                nowMilliseconds: 1_050
            )
        }

        let staleFenceNext = try makeRecord(
            membershipEpoch: 5,
            fencingToken: 7,
            sequence: 2,
            issuedAtMilliseconds: 1_050,
            expiresAtMilliseconds: 1_150,
            predecessorRecordSHA256: try current.canonicalSHA256()
        )
        assertError(.staleFencingToken) {
            try evaluator.decide(
                current: current,
                proposal: try proposal(after: current, next: staleFenceNext),
                authority: try makeAuthority(membershipEpoch: 5, fencingToken: 7),
                nowMilliseconds: 1_050
            )
        }

        let alternateNodeID = try otherNodeID()
        assertError(
            .leaderNodeMismatch(expected: alternateNodeID, actual: next.leaderNodeID)
        ) {
            try evaluator.decide(
                current: current,
                proposal: validProposal,
                authority: try makeAuthority(
                    nodeID: alternateNodeID,
                    membershipEpoch: 5,
                    fencingToken: 8
                ),
                nowMilliseconds: 1_050
            )
        }
    }

    func testCASRejectsWrongExpectationPredecessorAndSamePositionConflict() throws {
        let evaluator = ClusterControlPlaneLeaseDecisionEvaluator()
        let current = try makeRecord()
        let next = try makeRecord(
            sequence: 2,
            issuedAtMilliseconds: 1_050,
            expiresAtMilliseconds: 1_150,
            predecessorRecordSHA256: try current.canonicalSHA256()
        )

        let wrongTerm = try ClusterControlPlaneLeaseProposal(
            expectation: .record(
                term: 2,
                recordSHA256: try current.canonicalSHA256()
            ),
            next: next
        )
        assertError(.staleCAS) {
            try evaluator.decide(
                current: current,
                proposal: wrongTerm,
                authority: try makeAuthority(),
                nowMilliseconds: 1_050
            )
        }

        let wrongDigest = try ClusterControlPlaneLeaseProposal(
            expectation: .record(term: 1, recordSHA256: digest("e")),
            next: next
        )
        assertError(.staleCAS) {
            try evaluator.decide(
                current: current,
                proposal: wrongDigest,
                authority: try makeAuthority(),
                nowMilliseconds: 1_050
            )
        }

        let wrongPredecessor = try makeRecord(
            sequence: 2,
            issuedAtMilliseconds: 1_050,
            expiresAtMilliseconds: 1_150,
            predecessorRecordSHA256: digest("d")
        )
        assertError(.staleCAS) {
            try evaluator.decide(
                current: current,
                proposal: try proposal(after: current, next: wrongPredecessor),
                authority: try makeAuthority(),
                nowMilliseconds: 1_050
            )
        }

        let currentRenewal = try makeRecord(
            sequence: 2,
            issuedAtMilliseconds: 1_010,
            expiresAtMilliseconds: 1_110,
            predecessorRecordSHA256: digest("c")
        )
        let samePosition = try makeRecord(
            sequence: 2,
            issuedAtMilliseconds: 1_050,
            expiresAtMilliseconds: 1_150,
            predecessorRecordSHA256: try currentRenewal.canonicalSHA256()
        )
        assertError(.samePositionConflict) {
            try evaluator.decide(
                current: currentRenewal,
                proposal: try proposal(after: currentRenewal, next: samePosition),
                authority: try makeAuthority(),
                nowMilliseconds: 1_050
            )
        }
    }

    func testTermSequenceAndCounterBoundariesFailClosed() throws {
        let evaluator = ClusterControlPlaneLeaseDecisionEvaluator()
        let current = try makeRecord()

        let sequenceGap = try makeRecord(
            sequence: 3,
            issuedAtMilliseconds: 1_050,
            expiresAtMilliseconds: 1_150,
            predecessorRecordSHA256: try current.canonicalSHA256()
        )
        assertError(.sequenceGap(expected: 2, actual: 3)) {
            try evaluator.decide(
                current: current,
                proposal: try proposal(after: current, next: sequenceGap),
                authority: try makeAuthority(),
                nowMilliseconds: 1_050
            )
        }

        let activeTermGap = try makeRecord(
            fencingToken: 8,
            term: 2,
            sequence: 1,
            issuedAtMilliseconds: 1_050,
            expiresAtMilliseconds: 1_150,
            predecessorRecordSHA256: try current.canonicalSHA256()
        )
        assertError(.termGap(expected: 1, actual: 2)) {
            try evaluator.decide(
                current: current,
                proposal: try proposal(after: current, next: activeTermGap),
                authority: try makeAuthority(fencingToken: 8),
                nowMilliseconds: 1_050
            )
        }

        let expired = try makeRecord(
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 1_100
        )
        let replacementTermGap = try makeRecord(
            leaderNodeID: try otherNodeID(),
            fencingToken: 9,
            term: 3,
            sequence: 1,
            issuedAtMilliseconds: 1_100,
            expiresAtMilliseconds: 1_200,
            predecessorRecordSHA256: try expired.canonicalSHA256()
        )
        assertError(.termGap(expected: 2, actual: 3)) {
            try evaluator.decide(
                current: expired,
                proposal: try proposal(after: expired, next: replacementTermGap),
                authority: try makeAuthority(
                    nodeID: try otherNodeID(),
                    fencingToken: 9
                ),
                nowMilliseconds: 1_100
            )
        }

        let replacementSequenceGap = try makeRecord(
            leaderNodeID: try otherNodeID(),
            fencingToken: 9,
            term: 2,
            sequence: 2,
            issuedAtMilliseconds: 1_100,
            expiresAtMilliseconds: 1_200,
            predecessorRecordSHA256: try expired.canonicalSHA256()
        )
        assertError(.sequenceGap(expected: 1, actual: 2)) {
            try evaluator.decide(
                current: expired,
                proposal: try proposal(after: expired, next: replacementSequenceGap),
                authority: try makeAuthority(
                    nodeID: try otherNodeID(),
                    fencingToken: 9
                ),
                nowMilliseconds: 1_100
            )
        }

        let maximumSequence = try makeRecord(
            sequence: UInt64.max,
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 1_100,
            predecessorRecordSHA256: digest("a")
        )
        let impossibleRenewal = try makeRecord(
            sequence: 2,
            issuedAtMilliseconds: 1_050,
            expiresAtMilliseconds: 1_150,
            predecessorRecordSHA256: try maximumSequence.canonicalSHA256()
        )
        assertError(.counterOverflow) {
            try evaluator.decide(
                current: maximumSequence,
                proposal: try proposal(after: maximumSequence, next: impossibleRenewal),
                authority: try makeAuthority(),
                nowMilliseconds: 1_050
            )
        }

        let maximumTerm = try makeRecord(
            fencingToken: UInt64.max - 1,
            term: UInt64.max,
            sequence: 2,
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 1_100,
            predecessorRecordSHA256: digest("b")
        )
        let impossibleReplacement = try makeRecord(
            leaderNodeID: try otherNodeID(),
            fencingToken: UInt64.max,
            term: UInt64.max,
            sequence: 1,
            issuedAtMilliseconds: 1_100,
            expiresAtMilliseconds: 1_200,
            predecessorRecordSHA256: try maximumTerm.canonicalSHA256()
        )
        assertError(.counterOverflow) {
            try evaluator.decide(
                current: maximumTerm,
                proposal: try proposal(after: maximumTerm, next: impossibleReplacement),
                authority: try makeAuthority(
                    nodeID: try otherNodeID(),
                    fencingToken: UInt64.max
                ),
                nowMilliseconds: 1_100
            )
        }
    }

    func testTimestampLifetimeAndFenceTransitionBoundariesFailClosed() throws {
        let evaluator = ClusterControlPlaneLeaseDecisionEvaluator()
        let current = try makeRecord(
            fencingToken: 8,
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 1_100
        )

        let regressed = try makeRecord(
            fencingToken: 8,
            sequence: 2,
            issuedAtMilliseconds: 999,
            expiresAtMilliseconds: 1_101,
            predecessorRecordSHA256: try current.canonicalSHA256()
        )
        assertError(.timestampRegression) {
            try evaluator.decide(
                current: current,
                proposal: try proposal(after: current, next: regressed),
                authority: try makeAuthority(fencingToken: 8),
                nowMilliseconds: 999
            )
        }

        let mismatchedIssueTime = try makeRecord(
            fencingToken: 8,
            sequence: 2,
            issuedAtMilliseconds: 1_049,
            expiresAtMilliseconds: 1_150,
            predecessorRecordSHA256: try current.canonicalSHA256()
        )
        assertError(.issuedAtMismatch(expected: 1_050, actual: 1_049)) {
            try evaluator.decide(
                current: current,
                proposal: try proposal(after: current, next: mismatchedIssueTime),
                authority: try makeAuthority(fencingToken: 8),
                nowMilliseconds: 1_050
            )
        }

        let shorterExpiry = try makeRecord(
            fencingToken: 8,
            sequence: 2,
            issuedAtMilliseconds: 1_050,
            expiresAtMilliseconds: 1_090,
            predecessorRecordSHA256: try current.canonicalSHA256()
        )
        assertError(.expiryDidNotAdvance) {
            try evaluator.decide(
                current: current,
                proposal: try proposal(after: current, next: shorterExpiry),
                authority: try makeAuthority(fencingToken: 8),
                nowMilliseconds: 1_050
            )
        }

        let expiredSameFence = try makeRecord(
            leaderNodeID: try otherNodeID(),
            fencingToken: 8,
            term: 2,
            sequence: 1,
            issuedAtMilliseconds: 1_100,
            expiresAtMilliseconds: 1_200,
            predecessorRecordSHA256: try current.canonicalSHA256()
        )
        assertError(.fencingTokenDidNotAdvance) {
            try evaluator.decide(
                current: current,
                proposal: try proposal(after: current, next: expiredSameFence),
                authority: try makeAuthority(
                    nodeID: try otherNodeID(),
                    fencingToken: 8
                ),
                nowMilliseconds: 1_100
            )
        }

        XCTAssertNoThrow(
            try makeRecord(
                issuedAtMilliseconds: 1,
                expiresAtMilliseconds:
                    1 + ClusterControlPlaneLeaseContract.maximumLifetimeMilliseconds
            )
        )
        assertError(.invalidLifetime) {
            try makeRecord(
                issuedAtMilliseconds: 1,
                expiresAtMilliseconds:
                    2 + ClusterControlPlaneLeaseContract.maximumLifetimeMilliseconds
            )
        }
    }

    func testRecordConstructionRejectsMalformedCountersPredecessorFenceAndTime() throws {
        assertError(.invalidTerm) {
            try makeRecord(term: 0)
        }
        assertError(.invalidSequence) {
            try makeRecord(sequence: 0)
        }
        assertError(.invalidPredecessor) {
            try makeRecord(predecessorRecordSHA256: digest("a"))
        }
        assertError(.invalidPredecessor) {
            try makeRecord(sequence: 2)
        }
        assertError(.invalidPredecessor) {
            try makeRecord(sequence: 2, predecessorRecordSHA256: digest("A"))
        }
        assertError(.invalidFencingToken) {
            try makeRecord(fencingToken: 0)
        }
        assertError(.invalidTimestamp) {
            try makeRecord(issuedAtMilliseconds: 0, expiresAtMilliseconds: 1)
        }
        assertError(.invalidTimestamp) {
            try makeRecord(issuedAtMilliseconds: 1_000, expiresAtMilliseconds: 1_000)
        }
        assertError(.invalidExpectation) {
            _ = try ClusterControlPlaneLeaseProposal(
                expectation: .record(term: 0, recordSHA256: digest("a")),
                next: try makeRecord()
            )
        }
        assertError(.invalidExpectation) {
            _ = try ClusterControlPlaneLeaseProposal(
                expectation: .record(term: 1, recordSHA256: digest("A")),
                next: try makeRecord()
            )
        }
    }

    func testStrictRecordWireRejectsUnknownDuplicateMissingMalformedAndOversizedInput() throws {
        let record = try makeRecord()
        let encoded = try ClusterControlPlaneLeaseWireContract.encode(record)
        XCTAssertEqual(
            record,
            try ClusterControlPlaneLeaseWireContract.decodeRecord(encoded)
        )
        XCTAssertEqual(encoded, try record.canonicalJSON())

        let canonicalText = String(decoding: encoded, as: UTF8.self)
        XCTAssertEqual(
            canonicalText,
            "{\"clusterID\":\"11111111-1111-4111-8111-111111111111\","
                + "\"expiresAtMilliseconds\":1100,\"fencingToken\":7,"
                + "\"issuedAtMilliseconds\":1000,"
                + "\"leaderNodeID\":\"22222222-2222-4222-8222-222222222222\","
                + "\"membershipEpoch\":4,"
                + "\"predecessorRecordSHA256\":null,\"schemaVersion\":1,"
                + "\"sequence\":1,\"term\":1}"
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["unexpected"] = true
        XCTAssertThrowsError(
            try ClusterControlPlaneLeaseWireContract.decodeRecord(
                JSONSerialization.data(withJSONObject: object)
            )
        )

        let duplicate = "{\"schemaVersion\":1," + String(canonicalText.dropFirst())
        XCTAssertThrowsError(
            try ClusterControlPlaneLeaseWireContract.decodeRecord(Data(duplicate.utf8))
        )

        object.removeValue(forKey: "unexpected")
        object.removeValue(forKey: "expiresAtMilliseconds")
        XCTAssertThrowsError(
            try ClusterControlPlaneLeaseWireContract.decodeRecord(
                JSONSerialization.data(withJSONObject: object)
            )
        )

        var missingPredecessor = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        missingPredecessor.removeValue(forKey: "predecessorRecordSHA256")
        assertError(.invalidPredecessor) {
            try JSONDecoder().decode(
                ClusterControlPlaneLeaseRecord.self,
                from: JSONSerialization.data(withJSONObject: missingPredecessor)
            )
        }

        var unsupported = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        unsupported["schemaVersion"] = 2
        assertError(.unsupportedSchemaVersion(2)) {
            try ClusterControlPlaneLeaseWireContract.decodeRecord(
                JSONSerialization.data(withJSONObject: unsupported)
            )
        }

        XCTAssertThrowsError(
            try ClusterControlPlaneLeaseWireContract.decodeRecord(
                Data(canonicalText.dropLast().utf8)
            )
        )

        var nestedEpoch = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        nestedEpoch["membershipEpoch"] = ["value": 4, "future": true]
        XCTAssertThrowsError(
            try ClusterControlPlaneLeaseWireContract.decodeRecord(
                JSONSerialization.data(withJSONObject: nestedEpoch)
            )
        )
        let duplicateNestedEpoch = canonicalText.replacingOccurrences(
            of: "\"membershipEpoch\":4",
            with: "\"membershipEpoch\":{\"value\":4,\"value\":4}"
        )
        XCTAssertThrowsError(
            try ClusterControlPlaneLeaseWireContract.decodeRecord(
                Data(duplicateNestedEpoch.utf8)
            )
        )

        assertError(.wirePayloadOutOfBounds(actualBytes: 0)) {
            try ClusterControlPlaneLeaseWireContract.decodeRecord(Data())
        }
        let oversizedCount = ClusterControlPlaneLeaseContract.maximumWireBytes + 1
        assertError(.wirePayloadOutOfBounds(actualBytes: oversizedCount)) {
            try ClusterControlPlaneLeaseWireContract.decodeRecord(
                Data(repeating: 32, count: oversizedCount)
            )
        }
    }

    func testProposalWireUsesExplicitAbsenceAndRejectsPartialCAS() throws {
        let record = try makeRecord()
        let acquire = try ClusterControlPlaneLeaseProposal(
            expectation: .absent,
            next: record
        )
        let encoded = try ClusterControlPlaneLeaseWireContract.encode(acquire)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertTrue(object["expectedTerm"] is NSNull)
        XCTAssertTrue(object["expectedRecordSHA256"] is NSNull)
        XCTAssertTrue(object["predecessorRecordSHA256"] is NSNull)
        XCTAssertEqual(
            acquire,
            try ClusterControlPlaneLeaseWireContract.decodeProposal(encoded)
        )

        var partial = object
        partial["expectedRecordSHA256"] = digest("a")
        assertError(.invalidExpectation) {
            try ClusterControlPlaneLeaseWireContract.decodeProposal(
                JSONSerialization.data(withJSONObject: partial)
            )
        }

        for key in ["expectedTerm", "expectedRecordSHA256"] {
            var missing = object
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(
                try ClusterControlPlaneLeaseWireContract.decodeProposal(
                    JSONSerialization.data(withJSONObject: missing)
                )
            )
        }

        var unknown = object
        unknown["backend"] = "etcd"
        XCTAssertThrowsError(
            try ClusterControlPlaneLeaseWireContract.decodeProposal(
                JSONSerialization.data(withJSONObject: unknown)
            )
        )

        let next = try makeRecord(
            sequence: 2,
            issuedAtMilliseconds: 1_050,
            expiresAtMilliseconds: 1_150,
            predecessorRecordSHA256: try record.canonicalSHA256()
        )
        let renewal = try proposal(after: record, next: next)
        let renewalData = try ClusterControlPlaneLeaseWireContract.encode(renewal)
        XCTAssertEqual(
            renewal,
            try ClusterControlPlaneLeaseWireContract.decodeProposal(renewalData)
        )
    }

    func testReorderedWireCanonicalizesToStableBytesAndDigest() throws {
        let record = try makeRecord()
        let reordered = Data(
            ("{\"term\":1,\"sequence\":1,\"schemaVersion\":1,"
                + "\"predecessorRecordSHA256\":null,"
                + "\"membershipEpoch\":4,"
                + "\"leaderNodeID\":\"22222222-2222-4222-8222-222222222222\","
                + "\"issuedAtMilliseconds\":1000,\"fencingToken\":7,"
                + "\"expiresAtMilliseconds\":1100,"
                + "\"clusterID\":\"11111111-1111-4111-8111-111111111111\"}")
                .utf8
        )
        let decoded = try ClusterControlPlaneLeaseWireContract.decodeRecord(reordered)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(try decoded.canonicalJSON(), try record.canonicalJSON())
        XCTAssertEqual(try decoded.canonicalSHA256(), try record.canonicalSHA256())
        XCTAssertNotEqual(
            try record.canonicalSHA256(),
            try makeRecord(
                issuedAtMilliseconds: 1_001,
                expiresAtMilliseconds: 1_101
            ).canonicalSHA256()
        )
    }

    private func makeRecord(
        clusterID: ClusterID? = nil,
        leaderNodeID: ClusterNodeID? = nil,
        membershipEpoch: UInt64 = 4,
        fencingToken: UInt64 = 7,
        term: UInt64 = 1,
        sequence: UInt64 = 1,
        issuedAtMilliseconds: UInt64 = 1_000,
        expiresAtMilliseconds: UInt64 = 1_100,
        predecessorRecordSHA256: String? = nil
    ) throws -> ClusterControlPlaneLeaseRecord {
        try ClusterControlPlaneLeaseRecord(
            clusterID: clusterID
                ?? ClusterID("11111111-1111-4111-8111-111111111111"),
            leaderNodeID: leaderNodeID
                ?? ClusterNodeID("22222222-2222-4222-8222-222222222222"),
            membershipEpoch: ClusterMembershipEpoch(membershipEpoch),
            fencingToken: fencingToken,
            term: term,
            sequence: sequence,
            issuedAtMilliseconds: issuedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds,
            predecessorRecordSHA256: predecessorRecordSHA256
        )
    }

    private func makeAuthority(
        clusterID: ClusterID? = nil,
        nodeID: ClusterNodeID? = nil,
        membershipEpoch: UInt64 = 4,
        fencingToken: UInt64 = 7
    ) throws -> ClusterControlPlaneLeaseAuthority {
        try ClusterControlPlaneLeaseAuthority(
            clusterID: clusterID
                ?? ClusterID("11111111-1111-4111-8111-111111111111"),
            nodeID: nodeID
                ?? ClusterNodeID("22222222-2222-4222-8222-222222222222"),
            membershipEpoch: ClusterMembershipEpoch(membershipEpoch),
            fencingToken: fencingToken
        )
    }

    private func proposal(
        after current: ClusterControlPlaneLeaseRecord,
        next: ClusterControlPlaneLeaseRecord
    ) throws -> ClusterControlPlaneLeaseProposal {
        try ClusterControlPlaneLeaseProposal(
            expectation: .record(
                term: current.term,
                recordSHA256: try current.canonicalSHA256()
            ),
            next: next
        )
    }

    private func otherNodeID() throws -> ClusterNodeID {
        try ClusterNodeID("44444444-4444-4444-8444-444444444444")
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func assertError<T>(
        _ expected: ClusterControlPlaneLeaseError,
        _ operation: () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? ClusterControlPlaneLeaseError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
