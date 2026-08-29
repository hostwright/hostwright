import Darwin
import Foundation
import Security
import XCTest

@testable import HostwrightCluster

final class ClusterCertificateLifecycleTests: XCTestCase {
    private let clusterID = try! ClusterID("11111111-1111-4111-8111-111111111111")
    private let nodeID = try! ClusterNodeID("22222222-2222-4222-8222-222222222222")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testKeyTypeAttributeValidationFailsClosed() {
        XCTAssertTrue(
            ClusterCertificateKeychainStore.hasExpectedKeyType(
                kSecAttrKeyTypeECSECPrimeRandom
            )
        )
        XCTAssertFalse(
            ClusterCertificateKeychainStore.hasExpectedKeyType("unknown-key-type")
        )
        XCTAssertFalse(
            ClusterCertificateKeychainStore.hasExpectedKeyType(NSNumber(value: 42))
        )
        XCTAssertFalse(ClusterCertificateKeychainStore.hasExpectedKeyType(nil))
    }

    func testBootstrapPersistsOnlyPublicEvidenceAndReturnsNonExportableIdentity() throws {
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

        XCTAssertEqual(metadata.revision, 1)
        XCTAssertEqual(metadata.currentGeneration.value, 1)
        XCTAssertNil(metadata.retiringGeneration)
        XCTAssertEqual(
            metadata.roles,
            [.nodeAgentClient, .nodeAgentServer].sorted { $0.rawValue < $1.rawValue }
        )
        XCTAssertEqual(metadata.generations.count, 1)
        for (reference, itemClass) in references(
            in: try XCTUnwrap(metadata.generations.first)
        ) {
            XCTAssertEqual(
                copyStatus(
                    reference: reference,
                    itemClass: itemClass,
                    keychain: fixture.keychain
                ),
                errSecSuccess
            )
        }

        let handle = try lifecycle.identity(role: .nodeAgentClient, now: now)
        XCTAssertEqual(handle.credential.identity.role, .nodeAgentClient)
        XCTAssertEqual(handle.certificateChain.count, 1)
        var privateKey: SecKey?
        XCTAssertEqual(
            SecIdentityCopyPrivateKey(handle.identity, &privateKey),
            errSecSuccess
        )
        let key = try XCTUnwrap(privateKey)
        var exportError: Unmanaged<CFError>?
        XCTAssertNil(SecKeyCopyExternalRepresentation(key, &exportError))

        let stateData = try Data(
            contentsOf: fixture.metadataRoot.appendingPathComponent(
                "certificate-lifecycle.json"
            )
        )
        XCTAssertFalse(stateData.isEmpty)
        XCTAssertNil(stateData.range(of: Data("PRIVATE KEY".utf8)))
        XCTAssertNil(stateData.range(of: Data("privateKey".utf8)))
        try assertMode(fixture.metadataRoot.path, equals: 0o700, kind: S_IFDIR)
        try assertMode(
            fixture.metadataRoot
                .appendingPathComponent("certificate-lifecycle.json").path,
            equals: 0o600,
            kind: S_IFREG
        )

        let restarted = try fixture.lifecycle()
        XCTAssertEqual(try restarted.metadata(now: now), metadata)
        XCTAssertEqual(
            try restarted.identity(role: .nodeAgentServer, now: now)
                .credential.identity.role,
            .nodeAgentServer
        )
    }

    func testRotationOverlapsSequentialGenerationsThenExactlyDeletesRetiredItems() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        let initial = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient],
            authorityValidity: 172_800,
            leafValidity: 7_200,
            now: now
        )
        let old = try XCTUnwrap(initial.generations.first)

        let overlapping = try lifecycle.beginRotation(
            authorityValidity: 172_800,
            leafValidity: 7_200,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(overlapping.revision, 2)
        XCTAssertEqual(overlapping.currentGeneration.value, 2)
        XCTAssertEqual(overlapping.retiringGeneration?.value, 1)
        XCTAssertEqual(overlapping.generations.map(\.generation.value), [1, 2])
        XCTAssertNoThrow(try lifecycle.identity(
            role: .nodeAgentClient,
            generation: try ClusterCertificateGeneration(1),
            now: now.addingTimeInterval(60)
        ))
        XCTAssertNoThrow(try lifecycle.identity(
            role: .nodeAgentClient,
            generation: try ClusterCertificateGeneration(2),
            now: now.addingTimeInterval(60)
        ))

        let completed = try lifecycle.completeRotation(now: now.addingTimeInterval(60))
        XCTAssertEqual(completed.revision, 3)
        XCTAssertNil(completed.retiringGeneration)
        XCTAssertEqual(completed.generations.map(\.generation.value), [2])
        for (reference, itemClass) in references(in: old) {
            XCTAssertEqual(
                copyStatus(
                    reference: reference,
                    itemClass: itemClass,
                    keychain: fixture.keychain
                ),
                errSecItemNotFound
            )
        }
        XCTAssertThrowsError(try lifecycle.identity(
            role: .nodeAgentClient,
            generation: try ClusterCertificateGeneration(1),
            now: now.addingTimeInterval(60)
        )) { error in
            XCTAssertEqual(error as? ClusterCertificateError, .trustAnchorNotFound)
        }
        XCTAssertNoThrow(try lifecycle.identity(
            role: .nodeAgentClient,
            now: now.addingTimeInterval(60)
        ))
    }

    func testSessionGenerationAdmissionFailsClosedWhenMetadataIsMissing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        let metadata = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient],
            now: now
        )
        let credential = try sessionCredential(
            metadata: metadata,
            lifecycle: lifecycle
        )
        let authority = try ClusterSessionAuthority(
            clusterID: clusterID,
            nodeID: nodeID,
            credentials: ClusterSessionCredentialCatalog([credential]),
            credentialGenerationAuthorizer: lifecycle
        )
        try FileManager.default.removeItem(
            at: fixture.metadataRoot.appendingPathComponent(
                "certificate-lifecycle.json"
            )
        )

        XCTAssertThrowsError(try authority.issueChallenge(
            credentialID: credential.credentialID,
            nowMilliseconds: 1_000
        )) { error in
            XCTAssertEqual(
                error as? ClusterSessionError,
                .credentialGenerationAuthorityUnavailable
            )
        }
    }

    func testSessionGenerationAdmissionUsesOperationTimeForLeafValidity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        let metadata = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient],
            authorityValidity: 600,
            leafValidity: 60,
            now: now
        )
        let credential = try sessionCredential(
            metadata: metadata,
            lifecycle: lifecycle
        )
        let authority = try ClusterSessionAuthority(
            clusterID: clusterID,
            nodeID: nodeID,
            credentials: ClusterSessionCredentialCatalog([credential]),
            credentialGenerationAuthorizer: lifecycle
        )

        XCTAssertNoThrow(try authority.issueChallenge(
            credentialID: credential.credentialID,
            nowMilliseconds: milliseconds(now)
        ))
        XCTAssertThrowsError(try authority.issueChallenge(
            credentialID: credential.credentialID,
            nowMilliseconds: milliseconds(now.addingTimeInterval(61))
        )) { error in
            XCTAssertEqual(error as? ClusterSessionError, .credentialRevoked)
        }
    }

    func testSessionGenerationAdmissionRejectsStaleMetadataWithoutKeychainGeneration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        let initial = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient],
            authorityValidity: 600,
            leafValidity: 600,
            now: now
        )
        let overlapNow = now.addingTimeInterval(30)
        let overlapping = try lifecycle.beginRotation(
            authorityValidity: 600,
            leafValidity: 600,
            now: overlapNow
        )
        let verifier = ClusterMutualTLSVerifier(
            trustBundle: try overlapping.trustBundle()
        )
        let retiringHandle = try lifecycle.identity(
            role: .nodeAgentClient,
            generation: initial.currentGeneration,
            now: overlapNow
        )
        let currentHandle = try lifecycle.identity(
            role: .nodeAgentClient,
            generation: overlapping.currentGeneration,
            now: overlapNow
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
        let authority = try ClusterSessionAuthority(
            clusterID: clusterID,
            nodeID: nodeID,
            credentials: ClusterSessionCredentialCatalog([
                retiringCredential,
                currentCredential,
            ]),
            credentialGenerationAuthorizer: lifecycle
        )

        XCTAssertNoThrow(try authority.issueChallenge(
            credentialID: retiringCredential.credentialID,
            nowMilliseconds: milliseconds(overlapNow)
        ))
        XCTAssertNoThrow(try authority.issueChallenge(
            credentialID: currentCredential.credentialID,
            nowMilliseconds: milliseconds(overlapNow)
        ))

        let completedNow = now.addingTimeInterval(60)
        _ = try lifecycle.completeRotation(now: completedNow)
        try ClusterCertificateLifecycleFileStore(
            rootURL: fixture.metadataRoot
        ).saveMetadata(overlapping)

        XCTAssertThrowsError(try authority.issueChallenge(
            credentialID: retiringCredential.credentialID,
            nowMilliseconds: milliseconds(completedNow)
        )) { error in
            XCTAssertEqual(
                error as? ClusterSessionError,
                .credentialGenerationAuthorityUnavailable
            )
        }
    }

    func testSessionGenerationAdmissionFailsClosedWhenMetadataIsTampered() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        let metadata = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient],
            now: now
        )
        let credential = try sessionCredential(
            metadata: metadata,
            lifecycle: lifecycle
        )
        let authority = try ClusterSessionAuthority(
            clusterID: clusterID,
            nodeID: nodeID,
            credentials: ClusterSessionCredentialCatalog([credential]),
            credentialGenerationAuthorizer: lifecycle
        )
        try Data("tampered-generation-authority".utf8).write(
            to: fixture.metadataRoot.appendingPathComponent(
                "certificate-lifecycle.json"
            )
        )

        XCTAssertThrowsError(try authority.issueChallenge(
            credentialID: credential.credentialID,
            nowMilliseconds: 1_000
        )) { error in
            XCTAssertEqual(
                error as? ClusterSessionError,
                .credentialGenerationAuthorityUnavailable
            )
        }
    }

    func testActivationJournalRecoversPreparedGenerationAfterRestart() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let generation = try ClusterCertificateGeneration(1)
        let operationID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let keychainStore = ClusterCertificateKeychainStore(keychain: fixture.keychain)
        let prepared = try keychainStore.createGeneration(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: operationID,
            roles: [.nodeAgentClient],
            authorityValidity: 86_400,
            leafValidity: 3_600,
            now: now
        )
        let fileStore = try ClusterCertificateLifecycleFileStore(
            rootURL: fixture.metadataRoot
        )
        let creating = try ClusterCertificateLifecycleJournal(
            operationID: operationID,
            stage: .creating,
            expectedRevision: 0,
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient],
            sourceGeneration: nil,
            targetGeneration: generation,
            preparedGeneration: nil,
            retiringCredential: nil,
            startedAtMilliseconds: milliseconds(now)
        )
        try fileStore.saveJournal(creating.activating(prepared))

        let recovered = try XCTUnwrap(try fixture.lifecycle().recover(now: now))
        XCTAssertEqual(recovered.currentGeneration, generation)
        XCTAssertEqual(recovered.generations, [prepared])
        XCTAssertNil(try fileStore.loadJournal())
        XCTAssertNoThrow(
            try fixture.lifecycle().identity(role: .nodeAgentClient, now: now)
        )
    }

    func testCreatingJournalCleansAnEmptyPartialGenerationAndCanRetry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fileStore = try ClusterCertificateLifecycleFileStore(
            rootURL: fixture.metadataRoot
        )
        let journal = try ClusterCertificateLifecycleJournal(
            stage: .creating,
            expectedRevision: 0,
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient],
            sourceGeneration: nil,
            targetGeneration: try ClusterCertificateGeneration(1),
            preparedGeneration: nil,
            retiringCredential: nil,
            startedAtMilliseconds: milliseconds(now)
        )
        try fileStore.saveJournal(journal)

        XCTAssertNil(try fixture.lifecycle().recover(now: now))
        XCTAssertNil(try fileStore.loadJournal())
        XCTAssertEqual(
            try fixture.lifecycle().bootstrap(
                clusterID: clusterID,
                nodeID: nodeID,
                roles: [.nodeAgentClient],
                authorityValidity: 86_400,
                leafValidity: 3_600,
                now: now
            ).currentGeneration.value,
            1
        )
    }

    func testRetirementJournalFinishesAfterExpiredItemsWereAlreadyDeleted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        _ = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient],
            authorityValidity: 120,
            leafValidity: 120,
            now: now
        )
        let overlap = try lifecycle.beginRotation(
            authorityValidity: 600,
            leafValidity: 600,
            now: now.addingTimeInterval(30)
        )
        let retiringGeneration = try XCTUnwrap(overlap.retiringGeneration)
        let retiring = try XCTUnwrap(overlap.generations.first)
        let journal = try ClusterCertificateLifecycleJournal(
            stage: .retiring,
            expectedRevision: overlap.revision,
            clusterID: overlap.clusterID,
            nodeID: overlap.nodeID,
            roles: overlap.roles,
            sourceGeneration: retiringGeneration,
            targetGeneration: overlap.currentGeneration,
            preparedGeneration: nil,
            retiringCredential: retiring,
            startedAtMilliseconds: milliseconds(now.addingTimeInterval(180))
        )
        let files = try ClusterCertificateLifecycleFileStore(rootURL: fixture.metadataRoot)
        try files.saveJournal(journal)
        try ClusterCertificateKeychainStore(keychain: fixture.keychain)
            .cleanupGeneration(retiring)

        let recovered = try XCTUnwrap(
            try fixture.lifecycle().recover(now: now.addingTimeInterval(180))
        )
        XCTAssertEqual(recovered.revision, 3)
        XCTAssertNil(recovered.retiringGeneration)
        XCTAssertEqual(recovered.generations.map(\.generation.value), [2])
        XCTAssertNil(try files.loadJournal())
    }

    func testExpiredCurrentGenerationCanBeginRotationAndExpiredRetiringCanComplete() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        _ = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient],
            authorityValidity: 120,
            leafValidity: 120,
            now: now
        )

        XCTAssertThrowsError(
            try lifecycle.identity(
                role: .nodeAgentClient,
                now: now.addingTimeInterval(180)
            )
        ) { error in
            XCTAssertEqual(
                error as? ClusterCertificateLifecycleError,
                .credentialExpired
            )
        }
        let overlap = try lifecycle.beginRotation(
            authorityValidity: 600,
            leafValidity: 600,
            now: now.addingTimeInterval(180)
        )
        XCTAssertEqual(overlap.retiringGeneration?.value, 1)
        XCTAssertEqual(overlap.currentGeneration.value, 2)
        XCTAssertNoThrow(try lifecycle.identity(
            role: .nodeAgentClient,
            now: now.addingTimeInterval(180)
        ))

        let completed = try lifecycle.completeRotation(
            now: now.addingTimeInterval(181)
        )
        XCTAssertNil(completed.retiringGeneration)
        XCTAssertEqual(completed.generations.map(\.generation.value), [2])
    }

    func testCreatingRecoveryRefusesForeignPostCrashScopeCollisionWithoutDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let files = try ClusterCertificateLifecycleFileStore(
            rootURL: fixture.metadataRoot
        )
        let journal = try ClusterCertificateLifecycleJournal(
            operationID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            stage: .creating,
            expectedRevision: 0,
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient],
            sourceGeneration: nil,
            targetGeneration: try ClusterCertificateGeneration(1),
            preparedGeneration: nil,
            retiringCredential: nil,
            startedAtMilliseconds: milliseconds(now)
        )
        try files.saveJournal(journal)
        let foreignReference = try addExactScopeCollision(
            to: fixture.keychain,
            ownershipID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        )

        XCTAssertThrowsError(try fixture.lifecycle().recover(now: now)) { error in
            XCTAssertEqual(error as? ClusterCertificateLifecycleError, .tampered)
        }
        XCTAssertEqual(
            copyStatus(
                reference: foreignReference,
                itemClass: kSecClassKey,
                keychain: fixture.keychain
            ),
            errSecSuccess
        )
        XCTAssertEqual(try files.loadJournal(), journal)
    }

    func testTamperedMetadataAndExactScopeCollisionFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        _ = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient],
            authorityValidity: 86_400,
            leafValidity: 3_600,
            now: now
        )
        let stateURL = fixture.metadataRoot.appendingPathComponent(
            "certificate-lifecycle.json"
        )
        var data = try Data(contentsOf: stateURL)
        data[data.index(before: data.endIndex)] ^= 1
        try data.write(to: stateURL)
        XCTAssertEqual(chmod(stateURL.path, 0o600), 0)

        XCTAssertThrowsError(try lifecycle.metadata(now: now)) { error in
            XCTAssertEqual(error as? ClusterCertificateLifecycleError, .tampered)
        }

        let collisionFixture = try Fixture()
        defer { collisionFixture.cleanup() }
        _ = try addExactScopeCollision(
            to: collisionFixture.keychain,
            ownershipID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        )
        XCTAssertThrowsError(
            try collisionFixture.lifecycle().bootstrap(
                clusterID: clusterID,
                nodeID: nodeID,
                roles: [.nodeAgentClient],
                authorityValidity: 86_400,
                leafValidity: 3_600,
                now: now
            )
        ) { error in
            XCTAssertTrue(
                error as? ClusterCertificateLifecycleError == .tampered
                    || error as? ClusterCertificateLifecycleError == .collision
            )
        }
    }

    func testLockedIsolatedKeychainFailsWithoutInteraction() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lifecycle = try fixture.lifecycle()
        let metadata = try lifecycle.bootstrap(
            clusterID: clusterID,
            nodeID: nodeID,
            roles: [.nodeAgentClient],
            authorityValidity: 86_400,
            leafValidity: 3_600,
            now: now
        )
        let credential = try sessionCredential(
            metadata: metadata,
            lifecycle: lifecycle
        )
        let authority = try ClusterSessionAuthority(
            clusterID: clusterID,
            nodeID: nodeID,
            credentials: ClusterSessionCredentialCatalog([credential]),
            credentialGenerationAuthorizer: lifecycle
        )
        var priorInteraction = DarwinBoolean(false)
        XCTAssertEqual(
            SecKeychainGetUserInteractionAllowed(&priorInteraction),
            errSecSuccess
        )
        XCTAssertEqual(
            SecKeychainSetUserInteractionAllowed(true),
            errSecSuccess
        )
        defer {
            _ = SecKeychainSetUserInteractionAllowed(priorInteraction.boolValue)
        }
        XCTAssertEqual(SecKeychainLock(fixture.keychain), errSecSuccess)
        defer { _ = fixture.unlock() }

        let lockedOperations: [(String, () throws -> Void)] = [
            ("metadata", { _ = try lifecycle.metadata(now: self.now) }),
            ("recover", { _ = try lifecycle.recover(now: self.now) }),
            (
                "identity",
                {
                    _ = try lifecycle.identity(
                        role: .nodeAgentClient,
                        now: self.now
                    )
                }
            ),
            (
                "beginRotation",
                {
                    _ = try lifecycle.beginRotation(
                        authorityValidity: 86_400,
                        leafValidity: 3_600,
                        now: self.now
                    )
                }
            ),
        ]
        for (operation, invoke) in lockedOperations {
            let startedAt = Date()
            XCTAssertThrowsError(try invoke(), operation) { error in
                XCTAssertEqual(
                    error as? ClusterCertificateLifecycleError,
                    .keychainLocked,
                    operation
                )
            }
            XCTAssertLessThan(
                Date().timeIntervalSince(startedAt),
                5,
                operation
            )
            var interactionAllowed = DarwinBoolean(false)
            XCTAssertEqual(
                SecKeychainGetUserInteractionAllowed(&interactionAllowed),
                errSecSuccess,
                operation
            )
            XCTAssertTrue(interactionAllowed.boolValue, operation)
        }

        let startedAt = Date()
        XCTAssertThrowsError(try authority.issueChallenge(
            credentialID: credential.credentialID,
            nowMilliseconds: milliseconds(now)
        )) { error in
            XCTAssertEqual(
                error as? ClusterSessionError,
                .credentialGenerationAuthorityUnavailable
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
        var interactionAllowed = DarwinBoolean(false)
        XCTAssertEqual(
            SecKeychainGetUserInteractionAllowed(&interactionAllowed),
            errSecSuccess
        )
        XCTAssertTrue(interactionAllowed.boolValue)
    }

    private func references(
        in generation: ClusterCertificateGenerationCredential
    ) -> [(Data, CFString)] {
        [
            (
                generation.authority.references.keyPersistentReference,
                kSecClassKey
            ),
            (
                generation.authority.references.certificatePersistentReference,
                kSecClassCertificate
            ),
        ] + generation.leaves.flatMap {
            [
                ($0.references.keyPersistentReference, kSecClassKey),
                ($0.references.certificatePersistentReference, kSecClassCertificate),
            ]
        }
    }

    private func sessionCredential(
        metadata: ClusterCertificateLifecycleMetadata,
        lifecycle: ClusterCertificateLifecycle
    ) throws -> ClusterSessionCredential {
        let handle = try lifecycle.identity(
            role: .nodeAgentClient,
            now: now
        )
        return try ClusterMutualTLSVerifier(
            trustBundle: metadata.trustBundle()
        ).verify(
            peerCertificateDER: handle.credential.certificateDER,
            expectedIdentity: handle.credential.identity,
            nowMilliseconds: UInt64(now.timeIntervalSince1970 * 1_000)
        ).sessionCredential()
    }

    private func copyStatus(
        reference: Data,
        itemClass: CFString,
        keychain: SecKeychain
    ) -> OSStatus {
        var result: CFTypeRef?
        return SecItemCopyMatching([
            kSecClass: itemClass,
            kSecMatchItemList: [reference],
            kSecMatchSearchList: [keychain],
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
    }

    private func addExactScopeCollision(
        to keychain: SecKeychain,
        ownershipID: String
    ) throws -> Data {
        let tag = Data(
            "\(ClusterCertificateLifecycleContract.keyApplicationTagPrefix)."
                .appending(clusterID.rawValue)
                .appending(".\(nodeID.rawValue).g1.authority")
                .utf8
        )
        let label = "Hostwright Cluster Certificate v1 \(clusterID.rawValue) "
            + "\(nodeID.rawValue) g1 authority \(ownershipID)"
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecUseKeychain: keychain,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: tag,
                kSecAttrLabel: label,
            ] as CFDictionary,
        ] as CFDictionary, &error)
        guard let key else { throw error!.takeRetainedValue() }
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: tag,
            kSecMatchSearchList: [keychain],
            kSecReturnAttributes: true,
            kSecReturnPersistentRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ] as CFDictionary, &result)
        guard status == errSecSuccess,
              let matches = result as? NSArray,
              matches.count == 1,
              let attributes = matches[0] as? NSDictionary,
              attributes[kSecAttrApplicationTag] as? Data == tag,
              attributes[kSecAttrLabel] as? String == label,
              let reference = attributes[kSecValuePersistentRef] as? Data else {
            throw ClusterCertificateLifecycleError.keychainFailure(status)
        }
        _ = key
        return reference
    }

    private func assertMode(
        _ path: String,
        equals expected: mode_t,
        kind: mode_t
    ) throws {
        var metadata = stat()
        XCTAssertEqual(lstat(path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, kind)
        XCTAssertEqual(metadata.st_mode & 0o777, expected)
        XCTAssertEqual(metadata.st_uid, getuid())
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
                "hostwright-cluster-certificates-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            metadataRoot = root.appendingPathComponent("metadata", isDirectory: true)
            let fixturePassword = Data("hostwright-\(UUID().uuidString.lowercased())".utf8)
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
