import CryptoKit
import Foundation
import Security
import X509
import XCTest

@testable import HostwrightCluster

final class ClusterCertificateTrustTests: XCTestCase {
    private let clusterID = try! ClusterID("11111111-1111-4111-8111-111111111111")
    private let nodeID = try! ClusterNodeID("22222222-2222-4222-8222-222222222222")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTrustedPeerCertificateFeedsSessionCredentialWithoutPrivateMaterial() throws {
        let generation = try ClusterCertificateGeneration(1)
        let authorityFixture = try makeAuthority(generation: generation)
        let identity = try ClusterCertificateIdentity(
            clusterID: clusterID,
            nodeID: nodeID,
            role: .nodeAgentClient,
            generation: generation
        )
        let peerFixture = try makePeer(authority: authorityFixture, identity: identity)
        let bundle = try ClusterCertificateTrustBundle(
            clusterID: clusterID,
            activeGeneration: generation,
            authorities: [authorityFixture.authority]
        )

        let peer = try ClusterMutualTLSVerifier(trustBundle: bundle).verify(
            peerCertificateDER: peerFixture.der,
            expectedIdentity: identity,
            nowMilliseconds: milliseconds(now)
        )

        XCTAssertEqual(peer.identity, identity)
        XCTAssertEqual(peer.certificateSHA256, sha256(peerFixture.der))
        XCTAssertEqual(
            peer.authorityCertificateSHA256,
            authorityFixture.authority.certificateSHA256
        )
        XCTAssertEqual(
            peer.p256X963PublicKey,
            Data(peerFixture.certificate.publicKey.subjectPublicKeyInfoBytes)
        )

        let credential = try peer.sessionCredential()
        XCTAssertEqual(credential.nodeID, nodeID)
        XCTAssertEqual(credential.p256X963PublicKey, peer.p256X963PublicKey)
        XCTAssertEqual(
            credential.credentialID,
            "x509-sha256:\(peer.certificateSHA256)"
        )
        XCTAssertEqual(
            credential.x509Binding,
            try ClusterSessionX509CredentialBinding(
                identity: identity,
                leafCertificateSHA256: peer.certificateSHA256,
                authorityCertificateSHA256: peer.authorityCertificateSHA256
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ClusterSessionCredential.self,
                from: JSONEncoder().encode(credential)
            ),
            credential
        )

        let missingGenerationAuthority = try ClusterSessionAuthority(
            clusterID: clusterID,
            nodeID: nodeID,
            credentials: ClusterSessionCredentialCatalog([credential])
        )
        XCTAssertThrowsError(try missingGenerationAuthority.issueChallenge(
            credentialID: credential.credentialID,
            nowMilliseconds: 1_000
        )) { error in
            XCTAssertEqual(
                error as? ClusterSessionError,
                .credentialGenerationAuthorityUnavailable
            )
        }

        let sessionAuthority = try ClusterSessionAuthority(
            clusterID: clusterID,
            nodeID: nodeID,
            credentials: ClusterSessionCredentialCatalog([credential]),
            credentialGenerationAuthorizer: ExactCredentialGenerationAuthorizer(
                credential: credential
            )
        )
        let challenge = try sessionAuthority.issueChallenge(
            credentialID: credential.credentialID,
            nowMilliseconds: 1_000
        )
        let signature = try sign(
            challenge.canonicalData(),
            with: peerFixture.privateKey
        )
        let session = try sessionAuthority.authenticate(
            challenge,
            proof: ClusterSessionProof(
                credentialID: credential.credentialID,
                signatureDERBase64: signature.base64EncodedString()
            ),
            nowMilliseconds: 1_001
        )
        XCTAssertEqual(session.nodeID, identity.nodeID)
    }

    func testSessionCredentialDecodeRejectsUnboundX509ShapeAndLegacyRemainsUsable() throws {
        let generation = try ClusterCertificateGeneration(1)
        let authorityFixture = try makeAuthority(generation: generation)
        let identity = try ClusterCertificateIdentity(
            clusterID: clusterID,
            nodeID: nodeID,
            role: .nodeAgentClient,
            generation: generation
        )
        let peerFixture = try makePeer(authority: authorityFixture, identity: identity)
        let credential = try ClusterMutualTLSVerifier(
            trustBundle: ClusterCertificateTrustBundle(
                clusterID: clusterID,
                activeGeneration: generation,
                authorities: [authorityFixture.authority]
            )
        ).verify(
            peerCertificateDER: peerFixture.der,
            expectedIdentity: identity,
            nowMilliseconds: milliseconds(now)
        ).sessionCredential()
        var unbound = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(credential)
            ) as? [String: Any]
        )
        unbound.removeValue(forKey: "kind")
        unbound.removeValue(forKey: "x509Binding")
        for payload in [
            unbound,
            unbound.merging(["subjectID": "node-agent-legacy"]) { _, new in new },
            unbound.merging(["credentialID": "legacy-node-agent"]) { _, new in new },
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(
                ClusterSessionCredential.self,
                from: JSONSerialization.data(withJSONObject: payload)
            )) { error in
                XCTAssertEqual(error as? ClusterSessionError, .invalidCredentialMaterial)
            }
        }

        let legacyKey = P256.Signing.PrivateKey()
        let legacy = try ClusterSessionCredential(
            credentialID: "legacy-node-agent",
            subjectID: "node-agent-legacy",
            nodeID: nodeID,
            p256X963PublicKey: legacyKey.publicKey.x963Representation
        )
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(legacy)
            ) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "kind")
        XCTAssertEqual(
            try JSONDecoder().decode(
                ClusterSessionCredential.self,
                from: JSONSerialization.data(withJSONObject: legacyObject)
            ),
            legacy
        )
        let legacyAuthority = try ClusterSessionAuthority(
            clusterID: clusterID,
            nodeID: nodeID,
            credentials: ClusterSessionCredentialCatalog([legacy])
        )
        XCTAssertNoThrow(try legacyAuthority.issueChallenge(
            credentialID: legacy.credentialID,
            nowMilliseconds: 1_000
        ))
    }

    func testPeerIdentityAndUsageMustMatchExactly() throws {
        let generation = try ClusterCertificateGeneration(1)
        let authorityFixture = try makeAuthority(generation: generation)
        let identity = try ClusterCertificateIdentity(
            clusterID: clusterID,
            nodeID: nodeID,
            role: .etcdPeer,
            generation: generation
        )
        let bundle = try ClusterCertificateTrustBundle(
            clusterID: clusterID,
            activeGeneration: generation,
            authorities: [authorityFixture.authority]
        )
        let verifier = ClusterMutualTLSVerifier(trustBundle: bundle)

        let wrongNode = try ClusterCertificateIdentity(
            clusterID: clusterID,
            nodeID: try ClusterNodeID("33333333-3333-4333-8333-333333333333"),
            role: .etcdPeer,
            generation: generation
        )
        let wrongNodePeer = try makePeer(authority: authorityFixture, identity: wrongNode)
        XCTAssertThrowsError(
            try verifier.verify(
                peerCertificateDER: wrongNodePeer.der,
                expectedIdentity: identity,
                nowMilliseconds: milliseconds(now)
            )
        ) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .certificateIdentityMismatch)
        }

        let wrongUsagePeer = try makePeer(
            authority: authorityFixture,
            identity: identity,
            extendedKeyUsages: [.clientAuth]
        )
        XCTAssertThrowsError(
            try verifier.verify(
                peerCertificateDER: wrongUsagePeer.der,
                expectedIdentity: identity,
                nowMilliseconds: milliseconds(now)
            )
        ) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .certificateUsageMismatch)
        }
    }

    func testWrongAuthorityAndRevokedPeerFailClosed() throws {
        let generation = try ClusterCertificateGeneration(1)
        let authorityFixture = try makeAuthority(generation: generation)
        let otherAuthority = try makeAuthority(generation: generation)
        let identity = try ClusterCertificateIdentity(
            clusterID: clusterID,
            nodeID: nodeID,
            role: .etcdClient,
            generation: generation
        )
        let peerFixture = try makePeer(authority: authorityFixture, identity: identity)
        let wrongBundle = try ClusterCertificateTrustBundle(
            clusterID: clusterID,
            activeGeneration: generation,
            authorities: [otherAuthority.authority]
        )

        XCTAssertThrowsError(
            try ClusterMutualTLSVerifier(trustBundle: wrongBundle).verify(
                peerCertificateDER: peerFixture.der,
                expectedIdentity: identity,
                nowMilliseconds: milliseconds(now)
            )
        ) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .certificateTrustRejected)
        }

        let trustedBundle = try ClusterCertificateTrustBundle(
            clusterID: clusterID,
            activeGeneration: generation,
            authorities: [authorityFixture.authority]
        )
        let revokedBundle = try trustedBundle.revokingCertificate(
            sha256(peerFixture.der)
        )
        XCTAssertThrowsError(
            try ClusterMutualTLSVerifier(trustBundle: revokedBundle).verify(
                peerCertificateDER: peerFixture.der,
                expectedIdentity: identity,
                nowMilliseconds: milliseconds(now)
            )
        ) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .certificateRevoked)
        }
        XCTAssertThrowsError(
            try trustedBundle.revokingCertificate(
                authorityFixture.authority.certificateSHA256
            )
        ) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .invalidTrustBundle)
        }
    }

    func testRotationAllowsOneSequentialOverlapThenRetiresOldAuthority() throws {
        let generationOne = try ClusterCertificateGeneration(1)
        let generationTwo = try ClusterCertificateGeneration(2)
        let generationThree = try ClusterCertificateGeneration(3)
        let authorityOne = try makeAuthority(generation: generationOne)
        let authorityTwo = try makeAuthority(generation: generationTwo)
        let authorityThree = try makeAuthority(generation: generationThree)
        let bundle = try ClusterCertificateTrustBundle(
            clusterID: clusterID,
            activeGeneration: generationOne,
            authorities: [authorityOne.authority]
        )
        let overlapping = try bundle.beginRotation(to: authorityTwo.authority)

        XCTAssertEqual(overlapping.activeGeneration, generationTwo)
        XCTAssertEqual(overlapping.authorities.map(\.generation), [generationOne, generationTwo])
        XCTAssertThrowsError(try overlapping.beginRotation(to: authorityThree.authority)) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .rotationAlreadyInProgress)
        }

        let oldIdentity = try ClusterCertificateIdentity(
            clusterID: clusterID,
            nodeID: nodeID,
            role: .nodeAgentServer,
            generation: generationOne
        )
        let newIdentity = try ClusterCertificateIdentity(
            clusterID: clusterID,
            nodeID: nodeID,
            role: .nodeAgentServer,
            generation: generationTwo
        )
        let oldPeer = try makePeer(authority: authorityOne, identity: oldIdentity)
        let newPeer = try makePeer(authority: authorityTwo, identity: newIdentity)
        let overlappingVerifier = ClusterMutualTLSVerifier(trustBundle: overlapping)
        XCTAssertNoThrow(try overlappingVerifier.verify(
            peerCertificateDER: oldPeer.der,
            expectedIdentity: oldIdentity,
            nowMilliseconds: milliseconds(now)
        ))
        XCTAssertNoThrow(try overlappingVerifier.verify(
            peerCertificateDER: newPeer.der,
            expectedIdentity: newIdentity,
            nowMilliseconds: milliseconds(now)
        ))

        let completed = try overlapping.completeRotation(retiring: generationOne)
        XCTAssertEqual(completed.authorities.map(\.generation), [generationTwo])
        XCTAssertThrowsError(
            try ClusterMutualTLSVerifier(trustBundle: completed).verify(
                peerCertificateDER: oldPeer.der,
                expectedIdentity: oldIdentity,
                nowMilliseconds: milliseconds(now)
            )
        ) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .trustAnchorNotFound)
        }
        XCTAssertNoThrow(try completed.beginRotation(to: authorityThree.authority))
    }

    func testTrustBundleRoundTripsCanonicallyAndRejectsTamperedDecode() throws {
        let generation = try ClusterCertificateGeneration(1)
        let authorityFixture = try makeAuthority(generation: generation)
        let bundle = try ClusterCertificateTrustBundle(
            clusterID: clusterID,
            activeGeneration: generation,
            authorities: [authorityFixture.authority],
            revokedCertificateSHA256: [String(repeating: "a", count: 64)]
        )
        let data = try JSONEncoder().encode(bundle)
        XCTAssertEqual(try JSONDecoder().decode(
            ClusterCertificateTrustBundle.self,
            from: data
        ), bundle)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["activeGeneration"] = 2
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ClusterCertificateTrustBundle.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        ) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .invalidTrustBundle)
        }

        let emptyBundle = try ClusterCertificateTrustBundle(
            clusterID: clusterID,
            activeGeneration: generation,
            authorities: [authorityFixture.authority]
        )
        var emptyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(emptyBundle)
            ) as? [String: Any]
        )
        emptyObject.removeValue(forKey: "revokedCertificateSHA256")
        XCTAssertEqual(
            try JSONDecoder().decode(
                ClusterCertificateTrustBundle.self,
                from: JSONSerialization.data(withJSONObject: emptyObject)
            ),
            emptyBundle
        )
    }

    func testAuthorityCriticalExtensionsFailClosed() throws {
        let generation = try ClusterCertificateGeneration(1)
        XCTAssertThrowsError(
            try makeAuthority(
                generation: generation,
                basicConstraintsCritical: false
            )
        ) { error in
            XCTAssertEqual(
                error as? ClusterCertificateError,
                .invalidCertificateAuthority
            )
        }
        XCTAssertThrowsError(
            try makeAuthority(
                generation: generation,
                keyUsageCritical: false
            )
        ) { error in
            XCTAssertEqual(
                error as? ClusterCertificateError,
                .invalidCertificateAuthority
            )
        }
        XCTAssertThrowsError(
            try makeAuthority(
                generation: generation,
                includeUnsupportedCriticalExtension: true
            )
        ) { error in
            XCTAssertEqual(
                error as? ClusterCertificateError,
                .invalidCertificateAuthority
            )
        }
    }

    func testOnlyNodeAgentClientPeerCanBecomeSessionCredential() throws {
        let generation = try ClusterCertificateGeneration(1)
        let authorityFixture = try makeAuthority(generation: generation)
        let identity = try ClusterCertificateIdentity(
            clusterID: clusterID,
            nodeID: nodeID,
            role: .etcdClient,
            generation: generation
        )
        let peerFixture = try makePeer(authority: authorityFixture, identity: identity)
        let bundle = try ClusterCertificateTrustBundle(
            clusterID: clusterID,
            activeGeneration: generation,
            authorities: [authorityFixture.authority]
        )
        let peer = try ClusterMutualTLSVerifier(trustBundle: bundle).verify(
            peerCertificateDER: peerFixture.der,
            expectedIdentity: identity,
            nowMilliseconds: milliseconds(now)
        )
        XCTAssertThrowsError(try peer.sessionCredential()) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .certificateUsageMismatch)
        }
    }

    func testCertificateValidityErrorsAreStable() throws {
        let generation = try ClusterCertificateGeneration(1)
        let authorityFixture = try makeAuthority(generation: generation)
        let identity = try ClusterCertificateIdentity(
            clusterID: clusterID,
            nodeID: nodeID,
            role: .etcdClient,
            generation: generation
        )
        let bundle = try ClusterCertificateTrustBundle(
            clusterID: clusterID,
            activeGeneration: generation,
            authorities: [authorityFixture.authority]
        )
        let verifier = ClusterMutualTLSVerifier(trustBundle: bundle)
        let futurePeer = try makePeer(
            authority: authorityFixture,
            identity: identity,
            notValidBefore: now.addingTimeInterval(60),
            notValidAfter: now.addingTimeInterval(3_600)
        )
        XCTAssertThrowsError(
            try verifier.verify(
                peerCertificateDER: futurePeer.der,
                expectedIdentity: identity,
                nowMilliseconds: milliseconds(now)
            )
        ) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .certificateNotYetValid)
        }

        let expiredPeer = try makePeer(
            authority: authorityFixture,
            identity: identity,
            notValidBefore: now.addingTimeInterval(-3_600),
            notValidAfter: now.addingTimeInterval(-1)
        )
        XCTAssertThrowsError(
            try verifier.verify(
                peerCertificateDER: expiredPeer.der,
                expectedIdentity: identity,
                nowMilliseconds: milliseconds(now)
            )
        ) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .certificateExpired)
        }
    }

    func testMalformedGenerationIdentityAuthorityAndLeafAreRejected() throws {
        XCTAssertThrowsError(try ClusterCertificateGeneration(0)) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .invalidGeneration)
        }

        let generation = try ClusterCertificateGeneration(1)
        let identity = try ClusterCertificateIdentity(
            clusterID: clusterID,
            nodeID: nodeID,
            role: .nodeAgentClient,
            generation: generation
        )
        XCTAssertEqual(try ClusterCertificateIdentity(uri: identity.uri), identity)
        XCTAssertThrowsError(
            try ClusterCertificateIdentity(uri: identity.uri + "?admin=true")
        ) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .invalidIdentityURI)
        }

        let authorityFixture = try makeAuthority(generation: generation)
        let leaf = try makePeer(authority: authorityFixture, identity: identity)
        XCTAssertThrowsError(
            try ClusterCertificateAuthority(
                clusterID: clusterID,
                generation: generation,
                certificateDER: leaf.der
            )
        ) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .invalidCertificateAuthority)
        }

        let bundle = try ClusterCertificateTrustBundle(
            clusterID: clusterID,
            activeGeneration: generation,
            authorities: [authorityFixture.authority]
        )
        XCTAssertThrowsError(
            try ClusterMutualTLSVerifier(trustBundle: bundle).verify(
                peerCertificateDER: Data("not a certificate".utf8),
                expectedIdentity: identity,
                nowMilliseconds: milliseconds(now)
            )
        ) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .invalidCertificate)
        }
    }

    private struct AuthorityFixture {
        let authority: ClusterCertificateAuthority
        let certificate: Certificate
        let privateKey: Certificate.PrivateKey
    }

    private struct PeerFixture {
        let certificate: Certificate
        let der: Data
        let privateKey: SecKey
    }

    private struct TestKey {
        let certificateKey: Certificate.PrivateKey
        let securityKey: SecKey
    }

    private func makeAuthority(
        generation: ClusterCertificateGeneration,
        clusterID: ClusterID? = nil,
        basicConstraintsCritical: Bool = true,
        keyUsageCritical: Bool = true,
        includeUnsupportedCriticalExtension: Bool = false
    ) throws -> AuthorityFixture {
        let clusterID = clusterID ?? self.clusterID
        let key = try makePrivateKey()
        let name = try DistinguishedName {
            OrganizationName("Hostwright")
            CommonName("Hostwright Cluster CA \(generation.value)")
        }
        var extensions = [
            try Certificate.Extension(
                BasicConstraints.isCertificateAuthority(maxPathLength: 0),
                critical: basicConstraintsCritical
            ),
            try Certificate.Extension(
                KeyUsage(keyCertSign: true, cRLSign: true),
                critical: keyUsageCritical
            ),
            try Certificate.Extension(
                SubjectAlternativeNames([
                    .uniformResourceIdentifier(
                        ClusterCertificateAuthority.identityURI(
                            clusterID: clusterID,
                            generation: generation
                        )
                    )
                ]),
                critical: false
            ),
            try Certificate.Extension(
                SubjectKeyIdentifier(hash: key.certificateKey.publicKey),
                critical: false
            )
        ]
        if includeUnsupportedCriticalExtension {
            extensions.append(
                try Certificate.Extension(
                    AuthorityInformationAccess([
                        .init(
                            method: .ocspServer,
                            location: .uniformResourceIdentifier(
                                "https://hostwright.invalid/ocsp"
                            )
                        )
                    ]),
                    critical: true
                )
            )
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.certificateKey.publicKey,
            notValidBefore: now.addingTimeInterval(-3_600),
            notValidAfter: now.addingTimeInterval(86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions(extensions),
            issuerPrivateKey: key.certificateKey
        )
        let der = try certificateDER(certificate)
        return AuthorityFixture(
            authority: try ClusterCertificateAuthority(
                clusterID: clusterID,
                generation: generation,
                certificateDER: der
            ),
            certificate: certificate,
            privateKey: key.certificateKey
        )
    }

    private func makePeer(
        authority: AuthorityFixture,
        identity: ClusterCertificateIdentity,
        extendedKeyUsages: [ExtendedKeyUsage.Usage]? = nil,
        notValidBefore: Date? = nil,
        notValidAfter: Date? = nil
    ) throws -> PeerFixture {
        let key = try makePrivateKey()
        let authorityKeyIdentifier = try XCTUnwrap(
            authority.certificate.extensions.subjectKeyIdentifier?.keyIdentifier
        )
        let usages = extendedKeyUsages ?? keyUsages(for: identity.role)
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.certificateKey.publicKey,
            notValidBefore: notValidBefore ?? now.addingTimeInterval(-60),
            notValidAfter: notValidAfter ?? now.addingTimeInterval(3_600),
            issuer: authority.certificate.subject,
            subject: try DistinguishedName {
                OrganizationName("Hostwright")
                CommonName("Hostwright Cluster Peer")
            },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage(usages)
                SubjectAlternativeNames([
                    .uniformResourceIdentifier(identity.uri)
                ])
                SubjectKeyIdentifier(hash: key.certificateKey.publicKey)
                AuthorityKeyIdentifier(keyIdentifier: authorityKeyIdentifier)
            },
            issuerPrivateKey: authority.privateKey
        )
        return PeerFixture(
            certificate: certificate,
            der: try certificateDER(certificate),
            privateKey: key.securityKey
        )
    }

    private func keyUsages(
        for role: ClusterCertificateRole
    ) -> [ExtendedKeyUsage.Usage] {
        switch role {
        case .etcdPeer:
            [.serverAuth, .clientAuth]
        case .etcdClient, .nodeAgentClient:
            [.clientAuth]
        case .nodeAgentServer:
            [.serverAuth]
        }
    }

    private func makePrivateKey() throws -> TestKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        return TestKey(
            certificateKey: try Certificate.PrivateKey(key),
            securityKey: key
        )
    }

    private func certificateDER(_ certificate: Certificate) throws -> Data {
        let securityCertificate = try SecCertificate.makeWithCertificate(certificate)
        return SecCertificateCopyData(securityCertificate) as Data
    }

    private func milliseconds(_ date: Date) -> UInt64 {
        UInt64(date.timeIntervalSince1970 * 1_000)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sign(_ data: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) else {
            throw error!.takeRetainedValue()
        }
        return signature as Data
    }
}

private struct ExactCredentialGenerationAuthorizer:
    ClusterSessionCredentialGenerationAuthorizing
{
    let credential: ClusterSessionCredential

    func permits(
        _ credential: ClusterSessionCredential,
        nowMilliseconds: UInt64
    ) throws -> Bool {
        _ = nowMilliseconds
        return credential == self.credential
    }
}
