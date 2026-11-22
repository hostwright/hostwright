import Foundation
import Security
import XCTest

@testable import HostwrightCluster

final class ClusterNodeAgentTransportSecurityTests: XCTestCase {
    private let clusterID = try! ClusterID("11111111-1111-4111-8111-111111111111")
    private let nodeID = try! ClusterNodeID("22222222-2222-4222-8222-222222222222")
    private let otherNodeID = try! ClusterNodeID("33333333-3333-4333-8333-333333333333")
    private let otherClusterID = try! ClusterID("44444444-4444-4444-8444-444444444444")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAdaptersBindOpaqueLifecycleIdentityPeerCertificateAndSessionHandoff() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        let metadata = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient, .nodeAgentServer],
            authorityValidity: 86_400,
            leafValidity: 3_600,
            now: now
        )
        let bundle = try metadata.trustBundle()
        let clientHandle = try lifecycle.identity(role: .nodeAgentClient, now: now)
        let serverHandle = try lifecycle.identity(role: .nodeAgentServer, now: now)
        let generation = metadata.currentGeneration

        let clientAdapter = try makeAdapter(
            side: .client,
            localIdentity: clientHandle,
            peerNodeID: nodeID,
            peerGeneration: generation,
            trustBundle: bundle
        )
        XCTAssertEqual(
            clientAdapter.localIdentity.certificateIdentity,
            clientHandle.credential.identity
        )
        XCTAssertEqual(
            clientAdapter.localIdentity.certificateSHA256,
            clientHandle.credential.certificateSHA256
        )
        XCTAssertEqual(clientAdapter.localIdentity.certificateChain.count, 1)
        var privateKey: SecKey?
        XCTAssertEqual(
            SecIdentityCopyPrivateKey(
                clientAdapter.localIdentity.securityIdentity,
                &privateKey
            ),
            errSecSuccess
        )
        var exportError: Unmanaged<CFError>?
        XCTAssertNil(
            SecKeyCopyExternalRepresentation(
                try XCTUnwrap(privateKey),
                &exportError
            )
        )

        let authenticatedServer = try clientAdapter.authenticateServer(
            certificateDER: serverHandle.credential.certificateDER,
            nowMilliseconds: milliseconds(now)
        )
        XCTAssertEqual(authenticatedServer.identity.role, .nodeAgentServer)
        XCTAssertEqual(authenticatedServer.identity.nodeID, nodeID)

        let serverAdapter = try makeAdapter(
            side: .server,
            localIdentity: serverHandle,
            peerNodeID: nodeID,
            peerGeneration: generation,
            trustBundle: bundle
        )
        let authenticatedClient = try serverAdapter.authenticateClient(
            certificateDER: clientHandle.credential.certificateDER,
            nowMilliseconds: milliseconds(now)
        )
        XCTAssertEqual(authenticatedClient.peer.identity.role, .nodeAgentClient)
        XCTAssertEqual(authenticatedClient.sessionCredential.nodeID, nodeID)
        XCTAssertEqual(
            authenticatedClient.sessionCredential.credentialID,
            "x509-sha256:\(clientHandle.credential.certificateSHA256)"
        )

        let authority = try ClusterSessionAuthority(
            clusterID: clusterID,
            nodeID: nodeID,
            credentials: ClusterSessionCredentialCatalog([
                authenticatedClient.sessionCredential
            ]),
            credentialGenerationAuthorizer: lifecycle
        )
        let sessionNow = milliseconds(now)
        let challenge = try authority.issueChallenge(
            credentialID: authenticatedClient.sessionCredential.credentialID,
            nowMilliseconds: sessionNow
        )
        let proof = try ClusterSessionProof(
            credentialID: authenticatedClient.sessionCredential.credentialID,
            signatureDERBase64: sign(
                challenge.canonicalData(),
                with: clientHandle.identity
            ).base64EncodedString()
        )
        let session = try authority.authenticate(
            challenge,
            proof: proof,
            nowMilliseconds: sessionNow + 1
        )
        let handoff = try authority.bootstrapConsumer(
            from: session,
            subjectID: authenticatedClient.sessionCredential.subjectID,
            nowMilliseconds: sessionNow + 2
        )

        XCTAssertNoThrow(try authenticatedClient.authorize(
            handoff,
            using: authority,
            nowMilliseconds: sessionNow + 3
        ))

        let wrongNodeHandoff = try ClusterSessionHandoff(
            sessionID: handoff.sessionID,
            clusterID: handoff.clusterID,
            nodeID: otherNodeID,
            membershipEpoch: handoff.membershipEpoch,
            subjectID: handoff.subjectID,
            fencingToken: handoff.fencingToken,
            issuedAtMilliseconds: handoff.issuedAtMilliseconds,
            expiresAtMilliseconds: handoff.expiresAtMilliseconds
        )
        XCTAssertThrowsError(try authenticatedClient.authorize(
            wrongNodeHandoff,
            using: authority,
            nowMilliseconds: sessionNow + 3
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .handoffIdentityMismatch
            )
        }

        try authority.revokeCredential(
            authenticatedClient.sessionCredential.credentialID
        )
        XCTAssertThrowsError(try authenticatedClient.authorize(
            handoff,
            using: authority,
            nowMilliseconds: sessionNow + 3
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .handoffAuthorizationFailed(.sessionFenced)
            )
        }
    }

    func testAdapterRejectsClusterNodeRoleAndStaleLocalIdentityBindings() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        let initial = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient, .nodeAgentServer],
            authorityValidity: 86_400,
            leafValidity: 3_600,
            now: now
        )
        let clientHandle = try lifecycle.identity(role: .nodeAgentClient, now: now)
        let bundle = try initial.trustBundle()

        XCTAssertThrowsError(try ClusterNodeAgentTransportSecurityAdapter(
            side: .client,
            clusterID: otherClusterID,
            localNodeID: nodeID,
            peerNodeID: nodeID,
            peerGeneration: initial.currentGeneration,
            localIdentity: clientHandle,
            trustBundle: bundle,
            nowMilliseconds: milliseconds(now)
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .clusterMismatch
            )
        }
        XCTAssertThrowsError(try ClusterNodeAgentTransportSecurityAdapter(
            side: .client,
            clusterID: clusterID,
            localNodeID: otherNodeID,
            peerNodeID: nodeID,
            peerGeneration: initial.currentGeneration,
            localIdentity: clientHandle,
            trustBundle: bundle,
            nowMilliseconds: milliseconds(now)
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .localIdentityMismatch
            )
        }
        XCTAssertThrowsError(try ClusterNodeAgentTransportSecurityAdapter(
            side: .server,
            clusterID: clusterID,
            localNodeID: nodeID,
            peerNodeID: nodeID,
            peerGeneration: initial.currentGeneration,
            localIdentity: clientHandle,
            trustBundle: bundle,
            nowMilliseconds: milliseconds(now)
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .localIdentityMismatch
            )
        }

        let overlapping = try lifecycle.beginRotation(
            authorityValidity: 86_400,
            leafValidity: 3_600,
            now: now.addingTimeInterval(60)
        )
        XCTAssertThrowsError(try ClusterNodeAgentTransportSecurityAdapter(
            side: .client,
            clusterID: clusterID,
            localNodeID: nodeID,
            peerNodeID: nodeID,
            peerGeneration: overlapping.currentGeneration,
            localIdentity: clientHandle,
            trustBundle: overlapping.trustBundle(),
            nowMilliseconds: milliseconds(now.addingTimeInterval(60))
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .localIdentityStale
            )
        }
    }

    func testPeerAuthenticationRejectsWrongRoleNodeAndRevocation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        let metadata = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient, .nodeAgentServer],
            authorityValidity: 86_400,
            leafValidity: 3_600,
            now: now
        )
        let clientHandle = try lifecycle.identity(role: .nodeAgentClient, now: now)
        let serverHandle = try lifecycle.identity(role: .nodeAgentServer, now: now)
        let bundle = try metadata.trustBundle()
        let serverAdapter = try makeAdapter(
            side: .server,
            localIdentity: serverHandle,
            peerNodeID: nodeID,
            peerGeneration: metadata.currentGeneration,
            trustBundle: bundle
        )

        XCTAssertThrowsError(try serverAdapter.authenticateClient(
            certificateDER: serverHandle.credential.certificateDER,
            nowMilliseconds: milliseconds(now)
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .peerCertificateRejected(.certificateIdentityMismatch)
            )
        }

        let wrongNodeAdapter = try makeAdapter(
            side: .server,
            localIdentity: serverHandle,
            peerNodeID: otherNodeID,
            peerGeneration: metadata.currentGeneration,
            trustBundle: bundle
        )
        XCTAssertThrowsError(try wrongNodeAdapter.authenticateClient(
            certificateDER: clientHandle.credential.certificateDER,
            nowMilliseconds: milliseconds(now)
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .peerCertificateRejected(.certificateIdentityMismatch)
            )
        }

        let revokedBundle = try bundle.revokingCertificate(
            clientHandle.credential.certificateSHA256
        )
        let revokedPeerAdapter = try makeAdapter(
            side: .server,
            localIdentity: serverHandle,
            peerNodeID: nodeID,
            peerGeneration: metadata.currentGeneration,
            trustBundle: revokedBundle
        )
        XCTAssertThrowsError(try revokedPeerAdapter.authenticateClient(
            certificateDER: clientHandle.credential.certificateDER,
            nowMilliseconds: milliseconds(now)
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .peerCertificateRejected(.certificateRevoked)
            )
        }
        XCTAssertThrowsError(try makeAdapter(
            side: .client,
            localIdentity: clientHandle,
            peerNodeID: nodeID,
            peerGeneration: metadata.currentGeneration,
            trustBundle: revokedBundle
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .localCertificateRejected(.certificateRevoked)
            )
        }

        let clientAdapter = try makeAdapter(
            side: .client,
            localIdentity: clientHandle,
            peerNodeID: nodeID,
            peerGeneration: metadata.currentGeneration,
            trustBundle: bundle
        )
        XCTAssertThrowsError(try clientAdapter.authenticateClient(
            certificateDER: clientHandle.credential.certificateDER,
            nowMilliseconds: milliseconds(now)
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .authenticationRoleMismatch
            )
        }
    }

    func testAdapterAcceptsRetiringGenerationPeerDuringRotationOverlap() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        _ = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient, .nodeAgentServer],
            authorityValidity: 600,
            leafValidity: 120,
            now: now
        )
        let overlapNow = now.addingTimeInterval(30)
        let overlapping = try lifecycle.beginRotation(
            authorityValidity: 600,
            leafValidity: 120,
            now: overlapNow
        )
        let retiringGeneration = try XCTUnwrap(overlapping.retiringGeneration)
        let retiringClient = try lifecycle.identity(
            role: .nodeAgentClient,
            generation: retiringGeneration,
            now: overlapNow
        )
        let currentServer = try lifecycle.identity(
            role: .nodeAgentServer,
            now: overlapNow
        )
        let adapter = try ClusterNodeAgentTransportSecurityAdapter(
            side: .server,
            clusterID: clusterID,
            localNodeID: nodeID,
            peerNodeID: nodeID,
            peerGeneration: retiringGeneration,
            localIdentity: currentServer,
            trustBundle: overlapping.trustBundle(),
            nowMilliseconds: milliseconds(overlapNow)
        )

        let authenticated = try adapter.authenticateClient(
            certificateDER: retiringClient.credential.certificateDER,
            nowMilliseconds: milliseconds(overlapNow)
        )

        XCTAssertEqual(
            adapter.localIdentity.certificateIdentity.generation,
            overlapping.currentGeneration
        )
        XCTAssertEqual(adapter.peerGeneration, retiringGeneration)
        XCTAssertEqual(authenticated.peer.identity, retiringClient.credential.identity)
        XCTAssertEqual(authenticated.sessionCredential.nodeID, nodeID)
    }

    func testCompletedRotationFencesRetiringSessionRejectsRenamedCredentialAndPersistsAdmission()
        throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        let initial = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient, .nodeAgentServer],
            authorityValidity: 600,
            leafValidity: 600,
            now: now
        )
        let retiringHandle = try lifecycle.identity(
            role: .nodeAgentClient,
            generation: initial.currentGeneration,
            now: now
        )
        let overlapNow = now.addingTimeInterval(30)
        let overlapping = try lifecycle.beginRotation(
            authorityValidity: 600,
            leafValidity: 600,
            now: overlapNow
        )
        let currentHandle = try lifecycle.identity(
            role: .nodeAgentClient,
            generation: overlapping.currentGeneration,
            now: overlapNow
        )
        let verifier = ClusterMutualTLSVerifier(
            trustBundle: try overlapping.trustBundle()
        )
        let retiringCredential = try verifier.verify(
            peerCertificateDER: retiringHandle.credential.certificateDER,
            expectedIdentity: retiringHandle.credential.identity,
            nowMilliseconds: milliseconds(overlapNow)
        ).sessionCredential()
        let currentCredential = try verifier.verify(
            peerCertificateDER: currentHandle.credential.certificateDER,
            expectedIdentity: currentHandle.credential.identity,
            nowMilliseconds: milliseconds(overlapNow)
        ).sessionCredential()
        let retiringBinding = try XCTUnwrap(retiringCredential.x509Binding)
        XCTAssertThrowsError(try ClusterSessionCredential(
            credentialID: "renamed-retiring-certificate",
            subjectID: retiringCredential.subjectID,
            nodeID: retiringCredential.nodeID,
            p256X963PublicKey: retiringCredential.p256X963PublicKey,
            x509Binding: retiringBinding
        )) { error in
            XCTAssertEqual(error as? ClusterSessionError, .invalidCredentialMaterial)
        }
        XCTAssertThrowsError(try ClusterSessionCredential(
            credentialID: retiringCredential.credentialID,
            subjectID: "node-agent-legacy-subject",
            nodeID: retiringCredential.nodeID,
            p256X963PublicKey: retiringCredential.p256X963PublicKey,
            x509Binding: retiringBinding
        )) { error in
            XCTAssertEqual(error as? ClusterSessionError, .invalidCredentialMaterial)
        }
        let catalog = try ClusterSessionCredentialCatalog([
            retiringCredential,
            currentCredential
        ])
        let authority = try ClusterSessionAuthority(
            clusterID: clusterID,
            nodeID: nodeID,
            credentials: catalog,
            credentialGenerationAuthorizer: lifecycle
        )
        let overlapMilliseconds = milliseconds(overlapNow)

        let retiringChallenge = try authority.issueChallenge(
            credentialID: retiringCredential.credentialID,
            nowMilliseconds: overlapMilliseconds
        )
        let retiringSession = try authority.authenticate(
            retiringChallenge,
            proof: try ClusterSessionProof(
                credentialID: retiringCredential.credentialID,
                signatureDERBase64: sign(
                    retiringChallenge.canonicalData(),
                    with: retiringHandle.identity
                ).base64EncodedString()
            ),
            nowMilliseconds: overlapMilliseconds + 1
        )
        let retiringHandoff = try authority.bootstrapConsumer(
            from: retiringSession,
            subjectID: retiringCredential.subjectID,
            nowMilliseconds: overlapMilliseconds + 2
        )
        XCTAssertNoThrow(try authority.authorize(
            retiringHandoff,
            subjectID: retiringCredential.subjectID,
            nowMilliseconds: overlapMilliseconds + 3
        ))

        let generationMismatch = try ClusterSessionCredential(
            x509Binding: ClusterSessionX509CredentialBinding(
                identity: try XCTUnwrap(currentCredential.x509Binding).identity,
                leafCertificateSHA256: retiringBinding.leafCertificateSHA256,
                authorityCertificateSHA256: retiringBinding.authorityCertificateSHA256
            ),
            p256X963PublicKey: retiringCredential.p256X963PublicKey
        )
        let generationMismatchAuthority = try ClusterSessionAuthority(
            clusterID: clusterID,
            nodeID: nodeID,
            credentials: ClusterSessionCredentialCatalog([generationMismatch]),
            credentialGenerationAuthorizer: lifecycle
        )
        XCTAssertThrowsError(try generationMismatchAuthority.issueChallenge(
            credentialID: generationMismatch.credentialID,
            nowMilliseconds: overlapMilliseconds + 4
        )) { error in
            XCTAssertEqual(error as? ClusterSessionError, .credentialRevoked)
        }

        let authorityMismatch = try ClusterSessionCredential(
            x509Binding: ClusterSessionX509CredentialBinding(
                identity: retiringBinding.identity,
                leafCertificateSHA256: retiringBinding.leafCertificateSHA256,
                authorityCertificateSHA256: String(repeating: "a", count: 64)
            ),
            p256X963PublicKey: retiringCredential.p256X963PublicKey
        )
        let authorityMismatchAuthority = try ClusterSessionAuthority(
            clusterID: clusterID,
            nodeID: nodeID,
            credentials: ClusterSessionCredentialCatalog([authorityMismatch]),
            credentialGenerationAuthorizer: lifecycle
        )
        XCTAssertThrowsError(try authorityMismatchAuthority.issueChallenge(
            credentialID: authorityMismatch.credentialID,
            nowMilliseconds: overlapMilliseconds + 4
        )) { error in
            XCTAssertEqual(error as? ClusterSessionError, .credentialRevoked)
        }

        let currentChallenge = try authority.issueChallenge(
            credentialID: currentCredential.credentialID,
            nowMilliseconds: overlapMilliseconds + 10
        )
        let currentSession = try authority.authenticate(
            currentChallenge,
            proof: try ClusterSessionProof(
                credentialID: currentCredential.credentialID,
                signatureDERBase64: sign(
                    currentChallenge.canonicalData(),
                    with: currentHandle.identity
                ).base64EncodedString()
            ),
            nowMilliseconds: overlapMilliseconds + 11
        )
        let currentHandoff = try authority.bootstrapConsumer(
            from: currentSession,
            subjectID: currentCredential.subjectID,
            nowMilliseconds: overlapMilliseconds + 12
        )

        let completedNow = now.addingTimeInterval(60)
        let completedMilliseconds = milliseconds(completedNow)
        _ = try lifecycle.completeRotation(now: completedNow)

        XCTAssertThrowsError(try authority.authorize(
            retiringHandoff,
            subjectID: retiringCredential.subjectID,
            nowMilliseconds: completedMilliseconds
        )) { error in
            XCTAssertEqual(error as? ClusterSessionError, .sessionFenced)
        }
        XCTAssertEqual(try authority.state(of: retiringSession), .fenced)
        XCTAssertNoThrow(try authority.authorize(
            currentHandoff,
            subjectID: currentCredential.subjectID,
            nowMilliseconds: completedMilliseconds
        ))

        let restartedLifecycle = try fixture.lifecycle()
        let restartedAuthority = try ClusterSessionAuthority(
            clusterID: clusterID,
            nodeID: nodeID,
            credentials: catalog,
            credentialGenerationAuthorizer: restartedLifecycle
        )
        XCTAssertThrowsError(try restartedAuthority.issueChallenge(
            credentialID: retiringCredential.credentialID,
            nowMilliseconds: completedMilliseconds
        )) { error in
            XCTAssertEqual(error as? ClusterSessionError, .credentialRevoked)
        }
        XCTAssertNoThrow(try restartedAuthority.issueChallenge(
            credentialID: currentCredential.credentialID,
            nowMilliseconds: completedMilliseconds
        ))
    }

    func testExpiredAndRetiredPeerMaterialFailsClosedDuringRotation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        let initial = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient, .nodeAgentServer],
            authorityValidity: 600,
            leafValidity: 120,
            now: now
        )
        let oldClient = try lifecycle.identity(role: .nodeAgentClient, now: now)
        let oldServer = try lifecycle.identity(role: .nodeAgentServer, now: now)
        let expiringLocalAdapter = try makeAdapter(
            side: .client,
            localIdentity: oldClient,
            peerNodeID: nodeID,
            peerGeneration: initial.currentGeneration,
            trustBundle: initial.trustBundle()
        )
        let overlapping = try lifecycle.beginRotation(
            authorityValidity: 600,
            leafValidity: 600,
            now: now.addingTimeInterval(30)
        )
        let currentServer = try lifecycle.identity(
            role: .nodeAgentServer,
            now: now.addingTimeInterval(30)
        )
        let overlapAdapter = try ClusterNodeAgentTransportSecurityAdapter(
            side: .server,
            clusterID: clusterID,
            localNodeID: nodeID,
            peerNodeID: nodeID,
            peerGeneration: initial.currentGeneration,
            localIdentity: currentServer,
            trustBundle: overlapping.trustBundle(),
            nowMilliseconds: milliseconds(now.addingTimeInterval(30))
        )

        XCTAssertThrowsError(try expiringLocalAdapter.authenticateServer(
            certificateDER: oldServer.credential.certificateDER,
            nowMilliseconds: milliseconds(now.addingTimeInterval(180))
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .localCertificateRejected(.certificateExpired)
            )
        }

        XCTAssertThrowsError(try overlapAdapter.authenticateClient(
            certificateDER: oldClient.credential.certificateDER,
            nowMilliseconds: milliseconds(now.addingTimeInterval(180))
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .peerCertificateRejected(.certificateExpired)
            )
        }

        let completed = try lifecycle.completeRotation(
            now: now.addingTimeInterval(181)
        )
        XCTAssertThrowsError(try ClusterNodeAgentTransportSecurityAdapter(
            side: .server,
            clusterID: clusterID,
            localNodeID: nodeID,
            peerNodeID: nodeID,
            peerGeneration: initial.currentGeneration,
            localIdentity: currentServer,
            trustBundle: completed.trustBundle(),
            nowMilliseconds: milliseconds(now.addingTimeInterval(181))
        )) { error in
            XCTAssertEqual(
                error as? ClusterNodeAgentTransportSecurityError,
                .peerGenerationUnavailable
            )
        }
    }

    private func makeAdapter(
        side: ClusterNodeAgentTransportSecuritySide,
        localIdentity: ClusterCertificateIdentityHandle,
        peerNodeID: ClusterNodeID,
        peerGeneration: ClusterCertificateGeneration,
        trustBundle: ClusterCertificateTrustBundle
    ) throws -> ClusterNodeAgentTransportSecurityAdapter {
        try ClusterNodeAgentTransportSecurityAdapter(
            side: side,
            clusterID: clusterID,
            localNodeID: nodeID,
            peerNodeID: peerNodeID,
            peerGeneration: peerGeneration,
            localIdentity: localIdentity,
            trustBundle: trustBundle,
            nowMilliseconds: milliseconds(now)
        )
    }

    private func sign(_ data: Data, with identity: SecIdentity) throws -> Data {
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let privateKey else {
            throw ClusterCertificateLifecycleError.tampered
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) else {
            throw error!.takeRetainedValue()
        }
        return signature as Data
    }

    private func milliseconds(_ date: Date) -> UInt64 {
        UInt64(date.timeIntervalSince1970 * 1_000)
    }

    private final class Fixture {
        let keychain: SecKeychain
        let password: Data
        let root: URL
        let metadataRoot: URL
        private var cleaned = false

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "hostwright-cluster-transport-security-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            metadataRoot = root.appendingPathComponent("metadata", isDirectory: true)
            let fixturePassword = Data(
                "hostwright-\(UUID().uuidString.lowercased())".utf8
            )
            password = fixturePassword
            let keychainURL = root.appendingPathComponent("isolated.keychain-db")
            var created: SecKeychain?
            let status = keychainURL.path.withCString { path in
                fixturePassword.withUnsafeBytes { bytes in
                    SecKeychainCreate(
                        path,
                        UInt32(bytes.count),
                        bytes.baseAddress,
                        false,
                        nil,
                        &created
                    )
                }
            }
            guard status == errSecSuccess, let created else {
                try? FileManager.default.removeItem(at: root)
                throw ClusterCertificateLifecycleError.keychainFailure(status)
            }
            keychain = created
            let unlockStatus = unlock()
            guard unlockStatus == errSecSuccess else {
                _ = SecKeychainDelete(created)
                try? FileManager.default.removeItem(at: root)
                throw ClusterCertificateLifecycleError.keychainFailure(unlockStatus)
            }
        }

        func lifecycle() throws -> ClusterCertificateLifecycle {
            try ClusterCertificateLifecycle(
                metadataDirectory: metadataRoot,
                keychain: keychain
            )
        }

        func unlock() -> OSStatus {
            password.withUnsafeBytes { bytes in
                SecKeychainUnlock(
                    keychain,
                    UInt32(bytes.count),
                    bytes.baseAddress,
                    true
                )
            }
        }

        func cleanup() {
            guard !cleaned else { return }
            cleaned = true
            _ = unlock()
            _ = SecKeychainDelete(keychain)
            try? FileManager.default.removeItem(at: root)
        }

        deinit {
            cleanup()
        }
    }
}
