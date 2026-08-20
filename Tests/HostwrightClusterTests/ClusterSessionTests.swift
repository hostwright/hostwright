import CryptoKit
import Foundation
import HostwrightCore
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

    func testAuthenticatedNodeAgentTransportUsesBackgroundSubprocessSocket() async throws {
        let fixture = try makeFixture()
        let challenge = try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 1_000
        )
        let session = try authenticate(fixture, challenge: challenge, nowMilliseconds: 1_001)
        let (transport, root) = try makeTransport(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await transport.send(
            session: session,
            subjectID: fixture.credential.subjectID,
            operation: "echo",
            payload: Data("node-agent-payload".utf8),
            nowMilliseconds: 1_002
        )
        XCTAssertEqual(result, Data("daolyap-tnega-edon".utf8))
    }

    func testAuthenticatedNodeAgentWireRejectsSensitiveAndVersionMutations() throws {
        let fixture = try makeFixture()
        let challenge = try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 6_000
        )
        let session = try authenticate(fixture, challenge: challenge, nowMilliseconds: 6_001)
        let handoff = try fixture.authority.bootstrapConsumer(
            from: session,
            subjectID: fixture.credential.subjectID,
            nowMilliseconds: 6_002
        )
        let request = try ClusterNodeAgentRequest(
            handoff: handoff,
            operation: "echo",
            payload: Data("wire".utf8)
        )
        let requestData = try request.canonicalData()

        for mutation: (String, Any) in [
            ("apiVersion", 2),
            ("protocolLabel", "wrong-protocol"),
            ("credentialID", fixture.credential.credentialID),
        ] {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestData) as? [String: Any]
            )
            object[mutation.0] = mutation.1
            XCTAssertThrowsError(
                try ClusterNodeAgentWireContract.decodeRequest(
                    JSONSerialization.data(withJSONObject: object)
                ),
                "mutation of \(mutation.0) must be rejected"
            )
        }

        let response = try ClusterNodeAgentResponse(
            requestID: request.requestID,
            status: .completed,
            payload: Data("wire".utf8)
        )
        let responseData = try response.canonicalData()
        var alteredResponse = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        alteredResponse["apiVersion"] = 2
        XCTAssertThrowsError(
            try ClusterNodeAgentWireContract.decodeResponse(
                JSONSerialization.data(withJSONObject: alteredResponse)
            )
        )
    }

    func testAuthenticatedNodeAgentTransportRevalidatesHandoffBeforeLaunch() async throws {
        let fixture = try makeFixture(sessionLifetimeMilliseconds: 10)
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
        let (transport, root) = try makeTransport(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await transport.send(
                handoff: handoff,
                subjectID: fixture.credential.subjectID,
                operation: "echo",
                payload: Data(),
                nowMilliseconds: 1_011
            )
            XCTFail("expired handoff must not launch a subprocess")
        } catch let error as ClusterNodeAgentTransportError {
            XCTAssertEqual(error, .authorizationFailed(.sessionExpired))
        }

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
        do {
            _ = try await transport.send(
                handoff: altered,
                subjectID: fixture.credential.subjectID,
                operation: "echo",
                payload: Data(),
                nowMilliseconds: 1_003
            )
            XCTFail("altered fence must not launch a subprocess")
        } catch let error as ClusterNodeAgentTransportError {
            XCTAssertEqual(error, .authorizationFailed(.handoffBindingMismatch))
        }

        let liveFixture = try makeFixture()
        let liveChallenge = try liveFixture.authority.issueChallenge(
            credentialID: liveFixture.credential.credentialID,
            nowMilliseconds: 2_000
        )
        let liveSession = try authenticate(liveFixture, challenge: liveChallenge, nowMilliseconds: 2_001)
        let liveHandoff = try liveFixture.authority.bootstrapConsumer(
            from: liveSession,
            subjectID: liveFixture.credential.subjectID,
            nowMilliseconds: 2_002
        )
        let (liveTransport, liveRoot) = try makeTransport(fixture: liveFixture)
        defer { try? FileManager.default.removeItem(at: liveRoot) }
        try liveFixture.authority.revokeCredential(liveFixture.credential.credentialID)
        do {
            _ = try await liveTransport.send(
                handoff: liveHandoff,
                subjectID: liveFixture.credential.subjectID,
                operation: "echo",
                payload: Data(),
                nowMilliseconds: 2_003
            )
            XCTFail("revoked handoff must not launch a subprocess")
        } catch let error as ClusterNodeAgentTransportError {
            XCTAssertEqual(error, .authorizationFailed(.sessionFenced))
        }

        let epochFixture = try makeFixture()
        let epochChallenge = try epochFixture.authority.issueChallenge(
            credentialID: epochFixture.credential.credentialID,
            nowMilliseconds: 3_000
        )
        let epochSession = try authenticate(epochFixture, challenge: epochChallenge, nowMilliseconds: 3_001)
        let epochHandoff = try epochFixture.authority.bootstrapConsumer(
            from: epochSession,
            subjectID: epochFixture.credential.subjectID,
            nowMilliseconds: 3_002
        )
        let (epochTransport, epochRoot) = try makeTransport(fixture: epochFixture)
        defer { try? FileManager.default.removeItem(at: epochRoot) }
        try epochFixture.authority.advanceMembershipEpoch(to: ClusterMembershipEpoch(2))
        do {
            _ = try await epochTransport.send(
                handoff: epochHandoff,
                subjectID: epochFixture.credential.subjectID,
                operation: "echo",
                payload: Data(),
                nowMilliseconds: 3_003
            )
            XCTFail("epoch-stale handoff must not launch a subprocess")
        } catch let error as ClusterNodeAgentTransportError {
            XCTAssertEqual(error, .authorizationFailed(.sessionFenced))
        }

        let fenceFixture = try makeFixture()
        let firstChallenge = try fenceFixture.authority.issueChallenge(
            credentialID: fenceFixture.credential.credentialID,
            nowMilliseconds: 4_000
        )
        let firstSession = try authenticate(fenceFixture, challenge: firstChallenge, nowMilliseconds: 4_001)
        let firstHandoff = try fenceFixture.authority.bootstrapConsumer(
            from: firstSession,
            subjectID: fenceFixture.credential.subjectID,
            nowMilliseconds: 4_002
        )
        let secondChallenge = try fenceFixture.authority.issueChallenge(
            credentialID: fenceFixture.credential.credentialID,
            nowMilliseconds: 4_003
        )
        _ = try authenticate(fenceFixture, challenge: secondChallenge, nowMilliseconds: 4_004)
        let (fenceTransport, fenceRoot) = try makeTransport(fixture: fenceFixture)
        defer { try? FileManager.default.removeItem(at: fenceRoot) }
        do {
            _ = try await fenceTransport.send(
                handoff: firstHandoff,
                subjectID: fenceFixture.credential.subjectID,
                operation: "echo",
                payload: Data(),
                nowMilliseconds: 4_005
            )
            XCTFail("monotonic-fence-stale handoff must not launch a subprocess")
        } catch let error as ClusterNodeAgentTransportError {
            XCTAssertEqual(error, .authorizationFailed(.sessionFenced))
        }
    }

    func testAuthenticatedNodeAgentTransportCancellationStopsBackgroundSubprocess() async throws {
        let fixture = try makeFixture()
        let challenge = try fixture.authority.issueChallenge(
            credentialID: fixture.credential.credentialID,
            nowMilliseconds: 5_000
        )
        let session = try authenticate(fixture, challenge: challenge, nowMilliseconds: 5_001)
        let (transport, root) = try makeTransport(
            fixture: fixture,
            program: Self.blockingAgentProgram
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let request = Task {
            try await transport.send(
                session: session,
                subjectID: fixture.credential.subjectID,
                operation: "block",
                payload: Data(),
                nowMilliseconds: 5_002,
                timeoutMilliseconds: 30_000
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("cancelled transport must not return a response")
        } catch let error as ClusterNodeAgentTransportError {
            XCTAssertEqual(error, .cancelled)
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

    private func makeTransport(
        fixture: Fixture,
        program: String = ClusterSessionTests.echoAgentProgram
    ) throws -> (ClusterNodeAgentLocalTransport, URL) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("hostwright-node-agent-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let socketPath = root.appendingPathComponent("agent.sock").path
        let configuration = try ClusterNodeAgentSubprocessConfiguration(
            executablePath: "/usr/bin/python3",
            arguments: ["-c", program],
            environment: SecureSubprocessEnvironment.minimal,
            workingDirectory: "/",
            socketPath: socketPath
        )
        do {
            return (
                try ClusterNodeAgentLocalTransport(
                    authority: fixture.authority,
                    configuration: configuration
                ),
                root
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private static let echoAgentProgram = """
    import base64
    import json
    import os
    import socket
    import struct
    import sys

    socket_path = sys.argv[sys.argv.index("--socket-path") + 1]
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    os.chmod(socket_path, 0o600)
    server.listen(1)
    connection, _ = server.accept()
    def read_exact(count):
        chunks = []
        remaining = count
        while remaining:
            chunk = connection.recv(remaining)
            if not chunk:
                raise RuntimeError("peer closed")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)
    header = read_exact(4)
    size = struct.unpack(">I", header)[0]
    request = json.loads(read_exact(size).decode("utf-8"))
    expected = {"apiVersion", "protocolLabel", "requestID", "handoff", "operation", "payloadBase64"}
    assert set(request) == expected
    forbidden = {"credentialID", "challengeID", "nonceBase64", "signatureDERBase64", "p256X963PublicKey"}
    assert not forbidden.intersection(request["handoff"])
    payload = base64.b64decode(request["payloadBase64"])
    response = {
        "apiVersion": 1,
        "protocolLabel": "hostwright-cluster-node-agent-v1",
        "requestID": request["requestID"],
        "status": "completed",
        "payloadBase64": base64.b64encode(payload[::-1]).decode("ascii"),
        "errorCode": "",
    }
    encoded = json.dumps(response, separators=(",", ":"), sort_keys=True).encode("utf-8")
    connection.sendall(struct.pack(">I", len(encoded)) + encoded)
    connection.close()
    server.close()
    os.unlink(socket_path)
    """

    private static let blockingAgentProgram = """
    import json
    import os
    import socket
    import struct
    import sys
    import time

    socket_path = sys.argv[sys.argv.index("--socket-path") + 1]
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    os.chmod(socket_path, 0o600)
    server.listen(1)
    connection, _ = server.accept()
    def read_exact(count):
        chunks = []
        remaining = count
        while remaining:
            chunk = connection.recv(remaining)
            if not chunk:
                raise RuntimeError("peer closed")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)
    header = read_exact(4)
    size = struct.unpack(">I", header)[0]
    _ = json.loads(read_exact(size).decode("utf-8"))
    time.sleep(30)
    """

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
