import CryptoKit
import Foundation
import XCTest
@testable import HostwrightCluster

final class ClusterSessionTests: XCTestCase {
    func testCanonicalChallengeProofAuthenticatesAndValidates() throws {
        let fixture = try makeFixture()
        let challenge = try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 1_000
        )

        let encoded = try challenge.canonicalData()
        XCTAssertEqual(challenge, try JSONDecoder().decode(ClusterSessionChallenge.self, from: encoded))
        XCTAssertEqual(challenge, try ClusterSessionWireContract.decodeChallenge(encoded))
        XCTAssertEqual(encoded, try challenge.canonicalData())

        let session = try authenticate(
            fixture,
            challenge: challenge,
            nowMilliseconds: 1_250
        )
        XCTAssertEqual(session.membershipEpoch, .initial)
        XCTAssertEqual(session.fencingToken, 1)
        XCTAssertNoThrow(try fixture.authority.validate(session, nowMilliseconds: 1_500))
        XCTAssertNoThrow(
            try fixture.authority.authorize(
                session,
                subjectID: fixture.credential.subjectID,
                nowMilliseconds: 1_500
            )
        )
        XCTAssertEqual(session, try JSONDecoder().decode(
            ClusterAuthenticatedSession.self,
            from: JSONEncoder().encode(session)
        ))
        XCTAssertEqual(
            session,
            try ClusterSessionWireContract.decodeSession(JSONEncoder().encode(session))
        )

        let sessionProof = try proof(for: challenge, key: fixture.privateKey)
        XCTAssertEqual(
            sessionProof,
            try ClusterSessionWireContract.decodeProof(JSONEncoder().encode(sessionProof))
        )

        var unknownField = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        unknownField["unexpected"] = true
        XCTAssertThrowsError(
            try ClusterSessionWireContract.decodeChallenge(
                JSONSerialization.data(withJSONObject: unknownField)
            )
        )
    }

    func testConsumerHandoffIsStrictCredentialFreeAndReauthorized() throws {
        let fixture = try makeFixture()
        let challenge = try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 1_000
        )
        let session = try authenticate(fixture, challenge: challenge, nowMilliseconds: 1_001)
        let handoff = try fixture.authority.bootstrapConsumer(
            from: session,
            subjectID: fixture.credential.subjectID,
            nowMilliseconds: 1_002
        )

        let encoded = try handoff.canonicalData()
        XCTAssertEqual(handoff, try JSONDecoder().decode(ClusterSessionHandoff.self, from: encoded))
        XCTAssertEqual(handoff, try ClusterSessionWireContract.decodeHandoff(encoded))
        XCTAssertEqual(
            Set(try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys),
            ClusterSessionWireContract.handoffAllowedKeys
        )
        XCTAssertNoThrow(
            try fixture.authority.authorize(
                handoff,
                subjectID: fixture.credential.subjectID,
                nowMilliseconds: 1_003
            )
        )

        var unknownField = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        unknownField["credentialID"] = fixture.credential.credentialID
        XCTAssertThrowsError(
            try ClusterSessionWireContract.decodeHandoff(
                JSONSerialization.data(withJSONObject: unknownField)
            )
        )
    }

    func testConsumerHandoffFailsClosedForExpiryRevocationEpochAndFencing() throws {
        let expiryFixture = try makeFixture(sessionLifetimeMilliseconds: 10)
        let expiryChallenge = try expiryFixture.authority.issueChallenge(
            credentialID: expiryFixture.credential.credentialID,
            nowMilliseconds: 100
        )
        let expirySession = try authenticate(expiryFixture, challenge: expiryChallenge, nowMilliseconds: 101)
        let expiredHandoff = try expiryFixture.authority.bootstrapConsumer(
            from: expirySession,
            subjectID: expiryFixture.credential.subjectID,
            nowMilliseconds: 102
        )
        XCTAssertThrowsError(
            try expiryFixture.authority.authorize(
                expiredHandoff,
                subjectID: expiryFixture.credential.subjectID,
                nowMilliseconds: 111
            )
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .sessionExpired)
        }

        let revocationFixture = try makeFixture()
        let revocationChallenge = try revocationFixture.authority.issueChallenge(
            credentialID: revocationFixture.credential.credentialID,
            nowMilliseconds: 200
        )
        let revocationSession = try authenticate(
            revocationFixture,
            challenge: revocationChallenge,
            nowMilliseconds: 201
        )
        let revokedHandoff = try revocationFixture.authority.bootstrapConsumer(
            from: revocationSession,
            subjectID: revocationFixture.credential.subjectID,
            nowMilliseconds: 202
        )
        try revocationFixture.authority.revokeCredential(revocationFixture.credential.credentialID)
        XCTAssertThrowsError(
            try revocationFixture.authority.authorize(
                revokedHandoff,
                subjectID: revocationFixture.credential.subjectID,
                nowMilliseconds: 203
            )
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .sessionFenced)
        }

        let epochFixture = try makeFixture()
        let epochChallenge = try epochFixture.authority.issueChallenge(
            credentialID: epochFixture.credential.credentialID,
            nowMilliseconds: 300
        )
        let epochSession = try authenticate(epochFixture, challenge: epochChallenge, nowMilliseconds: 301)
        let staleEpochHandoff = try epochFixture.authority.bootstrapConsumer(
            from: epochSession,
            subjectID: epochFixture.credential.subjectID,
            nowMilliseconds: 302
        )
        try epochFixture.authority.advanceMembershipEpoch(to: ClusterMembershipEpoch(2))
        XCTAssertThrowsError(
            try epochFixture.authority.authorize(
                staleEpochHandoff,
                subjectID: epochFixture.credential.subjectID,
                nowMilliseconds: 303
            )
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .sessionFenced)
        }

        let fenceFixture = try makeFixture()
        let firstChallenge = try fenceFixture.authority.issueChallenge(
            credentialID: fenceFixture.credential.credentialID,
            nowMilliseconds: 400
        )
        let firstSession = try authenticate(fenceFixture, challenge: firstChallenge, nowMilliseconds: 401)
        let staleFenceHandoff = try fenceFixture.authority.bootstrapConsumer(
            from: firstSession,
            subjectID: fenceFixture.credential.subjectID,
            nowMilliseconds: 402
        )
        let secondChallenge = try fenceFixture.authority.issueChallenge(
            credentialID: fenceFixture.credential.credentialID,
            nowMilliseconds: 403
        )
        _ = try authenticate(fenceFixture, challenge: secondChallenge, nowMilliseconds: 404)
        XCTAssertThrowsError(
            try fenceFixture.authority.authorize(
                staleFenceHandoff,
                subjectID: fenceFixture.credential.subjectID,
                nowMilliseconds: 405
            )
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .sessionFenced)
        }
    }

    func testConsumerHandoffRejectsMalformedAndAlteredBindings() throws {
        let fixture = try makeFixture()
        let challenge = try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 1_000
        )
        let session = try authenticate(fixture, challenge: challenge, nowMilliseconds: 1_001)
        let handoff = try fixture.authority.bootstrapConsumer(
            from: session,
            subjectID: fixture.credential.subjectID,
            nowMilliseconds: 1_002
        )
        let altered = try ClusterSessionHandoff(
            sessionID: handoff.sessionID,
            clusterID: handoff.clusterID,
            nodeID: handoff.nodeID,
            membershipEpoch: handoff.membershipEpoch,
            subjectID: handoff.subjectID,
            fencingToken: handoff.fencingToken + 1,
            issuedAtMilliseconds: handoff.issuedAtMilliseconds,
            expiresAtMilliseconds: handoff.expiresAtMilliseconds
        )
        XCTAssertThrowsError(
            try fixture.authority.authorize(
                altered,
                subjectID: fixture.credential.subjectID,
                nowMilliseconds: 1_003
            )
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .handoffBindingMismatch)
        }

        var malformed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: handoff.canonicalData()) as? [String: Any]
        )
        malformed["sessionID"] = "not-a-uuid"
        XCTAssertThrowsError(
            try ClusterSessionWireContract.decodeHandoff(
                JSONSerialization.data(withJSONObject: malformed)
            )
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .invalidIdentifier("sessionID"))
        }
    }

    func testInvalidProofIsConsumedAndReplayFailsClosed() throws {
        let fixture = try makeFixture()
        let challenge = try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 100
        )
        let otherKey = P256.Signing.PrivateKey()
        let invalidSignature = try otherKey.signature(for: challenge.canonicalData())
        let invalidProof = try ClusterSessionProof(
            credentialID: fixture.credential.credentialID,
            signatureDERBase64: invalidSignature.derRepresentation.base64EncodedString()
        )

        XCTAssertThrowsError(
            try fixture.authority.authenticate(
                challenge,
                proof: invalidProof,
                nowMilliseconds: 101
            )
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .credentialProofRejected)
        }

        let validProof = try proof(for: challenge, key: fixture.privateKey)
        XCTAssertThrowsError(
            try fixture.authority.authenticate(
                challenge,
                proof: validProof,
                nowMilliseconds: 101
            )
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .challengeConsumed)
        }
    }

    func testChallengeExpiryAndContextAreDeterministic() throws {
        let fixture = try makeFixture(challengeLifetimeMilliseconds: 10)
        let challenge = try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 200
        )
        let proof = try proof(for: challenge, key: fixture.privateKey)
        XCTAssertThrowsError(
            try fixture.authority.authenticate(challenge, proof: proof, nowMilliseconds: 210)
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .challengeExpired)
        }

        let foreignCluster = try ClusterID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let foreignChallenge = try ClusterSessionChallenge(
            challengeID: challenge.challengeID,
            clusterID: foreignCluster,
            nodeID: challenge.nodeID,
            membershipEpoch: challenge.membershipEpoch,
            subjectID: challenge.subjectID,
            credentialID: challenge.credentialID,
            nonceBase64: challenge.nonceBase64,
            issuedAtMilliseconds: challenge.issuedAtMilliseconds,
            expiresAtMilliseconds: challenge.expiresAtMilliseconds
        )
        XCTAssertThrowsError(
            try fixture.authority.authenticate(foreignChallenge, proof: proof, nowMilliseconds: 201)
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .challengeContextMismatch)
        }
    }

    func testNewAuthenticationFencesPriorSubjectSession() throws {
        let fixture = try makeFixture()
        let firstChallenge = try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 1_000
        )
        let first = try authenticate(fixture, challenge: firstChallenge, nowMilliseconds: 1_001)

        let secondChallenge = try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 1_100
        )
        let second = try authenticate(fixture, challenge: secondChallenge, nowMilliseconds: 1_101)
        XCTAssertEqual(second.fencingToken, 2)
        XCTAssertEqual(try fixture.authority.state(of: first), .fenced)
        XCTAssertThrowsError(try fixture.authority.validate(first, nowMilliseconds: 1_102)) { error in
            XCTAssertEqual(error as? ClusterSessionError, .sessionFenced)
        }
        XCTAssertNoThrow(try fixture.authority.validate(second, nowMilliseconds: 1_102))
    }

    func testMembershipEpochAndCredentialRevocationFenceSessions() throws {
        let fixture = try makeFixture()
        let firstChallenge = try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 1_000
        )
        let first = try authenticate(fixture, challenge: firstChallenge, nowMilliseconds: 1_001)

        try fixture.authority.advanceMembershipEpoch(to: ClusterMembershipEpoch(2))
        XCTAssertEqual(fixture.authority.currentMembershipEpoch, ClusterMembershipEpoch(2))
        XCTAssertEqual(try fixture.authority.state(of: first), .fenced)
        XCTAssertThrowsError(try fixture.authority.validate(first, nowMilliseconds: 1_002)) { error in
            XCTAssertEqual(error as? ClusterSessionError, .sessionFenced)
        }
        XCTAssertThrowsError(
            try fixture.authority.advanceMembershipEpoch(to: ClusterMembershipEpoch(2))
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .membershipEpochRegression)
        }

        let secondChallenge = try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 1_100
        )
        let second = try authenticate(fixture, challenge: secondChallenge, nowMilliseconds: 1_101)
        try fixture.authority.revokeCredential(fixture.credential.credentialID)
        XCTAssertEqual(try fixture.authority.state(of: second), .fenced)
        XCTAssertThrowsError(try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 1_102
        )) { error in
            XCTAssertEqual(error as? ClusterSessionError, .credentialRevoked)
        }
    }

    func testCloseIsIdempotentAndAuthorizationBindsSubject() throws {
        let fixture = try makeFixture()
        let challenge = try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 1_000
        )
        let session = try authenticate(fixture, challenge: challenge, nowMilliseconds: 1_001)

        XCTAssertThrowsError(
            try fixture.authority.authorize(session, subjectID: "different-subject", nowMilliseconds: 1_002)
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .sessionIdentityMismatch)
        }
        let closed = try fixture.authority.close(session)
        XCTAssertEqual(closed.state, .closed)
        XCTAssertFalse(closed.replayed)
        let replayed = try fixture.authority.close(session)
        XCTAssertEqual(replayed.state, .closed)
        XCTAssertTrue(replayed.replayed)
        XCTAssertThrowsError(try fixture.authority.validate(session, nowMilliseconds: 1_003)) { error in
            XCTAssertEqual(error as? ClusterSessionError, .sessionClosed)
        }
    }

    func testMalformedCredentialAndChallengeBoundariesAreRejected() throws {
        XCTAssertThrowsError(
            try ClusterSessionCredential(
                credentialID: "credential-1",
                subjectID: "node-agent-1",
                nodeID: try ClusterNodeID("22222222-2222-4222-8222-222222222222"),
                p256X963PublicKey: Data(repeating: 0, count: 64)
            )
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .invalidCredentialMaterial)
        }

        let clusterID = try ClusterID("11111111-1111-4111-8111-111111111111")
        let nodeID = try ClusterNodeID("22222222-2222-4222-8222-222222222222")
        XCTAssertThrowsError(
            try ClusterSessionChallenge(
                challengeID: "not-a-uuid",
                clusterID: clusterID,
                nodeID: nodeID,
                membershipEpoch: .initial,
                subjectID: "node-agent-1",
                credentialID: "credential-1",
                nonceBase64: Data(repeating: 0, count: 31).base64EncodedString(),
                issuedAtMilliseconds: 1,
                expiresAtMilliseconds: 2
            )
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .invalidIdentifier("challengeID"))
        }
    }

    func testPendingChallengeCapacityIsBoundedAndExpiredEntriesRecover() throws {
        let fixture = try makeFixture(challengeLifetimeMilliseconds: 100)
        for _ in 0..<ClusterSessionContract.maximumPendingChallenges {
            _ = try fixture.authority.issueChallenge(
                credentialID: fixture.credential.credentialID,
                nowMilliseconds: 1_000
            )
        }
        XCTAssertThrowsError(
            try fixture.authority.issueChallenge(
                credentialID: fixture.credential.credentialID,
                nowMilliseconds: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? ClusterSessionError, .challengeCapacityExceeded)
        }
        XCTAssertNoThrow(
            try fixture.authority.issueChallenge(
                credentialID: fixture.credential.credentialID,
                nowMilliseconds: 1_100
            )
        )
    }

    private struct Fixture {
        let authority: ClusterSessionAuthority
        let privateKey: P256.Signing.PrivateKey
        let credential: ClusterSessionCredential
    }

    private func makeFixture(
        challengeLifetimeMilliseconds: UInt64 = 5_000,
        sessionLifetimeMilliseconds: UInt64 = 300_000
    ) throws -> Fixture {
        let privateKey = P256.Signing.PrivateKey()
        let credential = try ClusterSessionCredential(
            credentialID: "credential-1",
            subjectID: "node-agent-1",
            nodeID: try ClusterNodeID("22222222-2222-4222-8222-222222222222"),
            p256X963PublicKey: privateKey.publicKey.x963Representation
        )
        let catalog = try ClusterSessionCredentialCatalog([credential])
        let authority = try ClusterSessionAuthority(
            clusterID: try ClusterID("11111111-1111-4111-8111-111111111111"),
            nodeID: credential.nodeID,
            credentials: catalog,
            challengeLifetimeMilliseconds: challengeLifetimeMilliseconds,
            sessionLifetimeMilliseconds: sessionLifetimeMilliseconds
        )
        return Fixture(authority: authority, privateKey: privateKey, credential: credential)
    }

    private func authenticate(
        _ fixture: Fixture,
        challenge: ClusterSessionChallenge,
        nowMilliseconds: UInt64
    ) throws -> ClusterAuthenticatedSession {
        try fixture.authority.authenticate(
            challenge,
            proof: proof(for: challenge, key: fixture.privateKey),
            nowMilliseconds: nowMilliseconds
        )
    }

    private func proof(
        for challenge: ClusterSessionChallenge,
        key: P256.Signing.PrivateKey
    ) throws -> ClusterSessionProof {
        let signature = try key.signature(for: challenge.canonicalData())
        return try ClusterSessionProof(
            credentialID: challenge.credentialID,
            signatureDERBase64: signature.derRepresentation.base64EncodedString()
        )
    }
}
