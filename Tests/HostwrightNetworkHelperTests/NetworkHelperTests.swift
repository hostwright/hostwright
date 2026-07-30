import Darwin
import Foundation
import HostwrightNetworking
import HostwrightRuntime
import XCTest
@testable import HostwrightNetworkHelperCore

final class NetworkHelperTests: XCTestCase {
    private struct TestCertificateIssuer:
        NetworkHelperCertificateIssuer,
        @unchecked Sendable
    {
        let identifier = "external"
        let issueBody:
            @Sendable (
                ProjectCertificateRequestBinding,
                Date
            ) throws -> NetworkHelperIssuedCertificate

        func issue(
            binding: ProjectCertificateRequestBinding,
            now: Date
        ) throws -> NetworkHelperIssuedCertificate {
            try issueBody(binding, now)
        }
    }
    private final class CountingCertificateIssuer:
        NetworkHelperCertificateIssuer,
        @unchecked Sendable
    {
        let identifier = "external"
        private let lock = NSLock()
        private var issuanceCount = 0

        var count: Int {
            lock.withLock { issuanceCount }
        }

        func issue(
            binding: ProjectCertificateRequestBinding,
            now: Date
        ) throws -> NetworkHelperIssuedCertificate {
            lock.withLock { issuanceCount += 1 }
            throw NetworkHelperError.certificateUnavailable
        }
    }
    private let projectUUID = "11111111-1111-4111-8111-111111111111"
    private let dnsUUID = "22222222-2222-4222-8222-222222222222"
    private let firstFence = "33333333-3333-4333-8333-333333333333"
    private let secondFence = "44444444-4444-4444-8444-444444444444"
    private let thirdFence = "55555555-5555-4555-8555-555555555555"
    private static let certificateTestNow = Date(
        timeIntervalSince1970: 2_000_000_000
    )

    func testCertificateConfigurationPersistsRecoversAndQuarantinesTampering() throws {
        try withStore { store, root in
            let binding = certificateBinding()
            let applied = try store.apply(identity: identity(), corefile: corefile(), certificateBindings: [binding])
            let digest = try XCTUnwrap(applied.certificateSHA256)
            XCTAssertEqual(try store.activeCertificateConfigurations(), [NetworkHelperPersistedCertificateConfiguration(identity: identity(), bindings: [binding], sha256: digest)])
            let restarted = try NetworkHelperStateStore(rootURL: root)
            XCTAssertEqual(try restarted.activeCertificateConfigurations().first?.bindings, [binding])
            let file = generationURL(root: root, generation: 1).appendingPathComponent("Certificate.json")
            try Data("tampered".utf8).write(to: file)
            XCTAssertEqual(try restarted.status(identity: identity()).disposition, .quarantined)
        }
    }

    func testUniqueUnsortedCertificateSANsCanonicalizeBeforeRecovery()
        throws
    {
        try withStore { store, root in
            var encoded = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(certificateBinding())
                ) as? [String: Any]
            )
            encoded["dnsNames"] = [
                "z.example.test",
                "api.example.test",
            ]
            let binding = try JSONDecoder().decode(
                ProjectCertificateRequestBinding.self,
                from: JSONSerialization.data(
                    withJSONObject: encoded,
                    options: [.sortedKeys]
                )
            )
            XCTAssertEqual(
                binding.dnsNames,
                ["z.example.test", "api.example.test"]
            )

            _ = try store.apply(
                identity: identity(),
                corefile: corefile(),
                certificateBindings: [binding]
            )
            let canonicalDNSNames = [
                "api.example.test",
                "z.example.test",
            ]
            XCTAssertEqual(
                try store.activeCertificateConfigurations()
                    .first?.bindings.first?.dnsNames,
                canonicalDNSNames
            )

            let restarted = try NetworkHelperStateStore(rootURL: root)
            XCTAssertEqual(
                try restarted.status(identity: identity()).disposition,
                .active
            )
            XCTAssertEqual(
                try restarted.activeCertificateConfigurations()
                    .first?.bindings.first?.dnsNames,
                canonicalDNSNames
            )
        }
    }

    func testCertificateRequestRejectsInvalidSourceAndNonLowercaseSAN() {
        let invalid = ProjectCertificateRequestBinding(name: "cert", certificateUUID: dnsUUID, source: .imported, issuer: "issuer", renewBeforeSeconds: 3_600, validitySeconds: 86_400, statusPolicy: .ifAvailable, dnsNames: ["API.example.test"])
        XCTAssertThrowsError(try NetworkHelperCertificateValidation.validated([invalid])) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidCertificate)
        }
    }

    func testCertificateEvidencePersistsRecoversAndQuarantinesTampering()
        throws
    {
        try withStore { store, root in
            let binding = certificateBinding()
            _ = try store.apply(
                identity: identity(),
                corefile: corefile(),
                certificateBindings: [binding]
            )
            let recorded = try XCTUnwrap(
                store.recordCertificateEvidence(
                    identity: identity(),
                    certificates: [
                        certificateEvidence(binding: binding),
                    ]
                )
            )
            XCTAssertEqual(recorded.identity, identity())
            XCTAssertEqual(recorded.certificates.count, 1)

            let restarted = try NetworkHelperStateStore(rootURL: root)
            XCTAssertEqual(
                try restarted.certificateEvidence(
                    identity: identity()
                ),
                recorded
            )

            let evidenceURL = root
                .appendingPathComponent(projectUUID)
                .appendingPathComponent(dnsUUID)
                .appendingPathComponent(
                    "certificate-evidence.json"
                )
            try Data("tampered".utf8).write(to: evidenceURL)
            XCTAssertEqual(
                try restarted.status(identity: identity()).disposition,
                .quarantined
            )
        }
    }

    func testCertificateEvidenceSurvivesGenerationReplacementUntilCleared()
        throws
    {
        try withStore { store, _ in
            let binding = certificateBinding()
            let first = identity()
            _ = try store.apply(
                identity: first,
                corefile: corefile(),
                certificateBindings: [binding]
            )
            let firstEvidence = try XCTUnwrap(
                store.recordCertificateEvidence(
                    identity: first,
                    certificates: [
                        certificateEvidence(binding: binding),
                    ]
                )
            )

            let second = identity(
                generation: 2,
                fence: secondFence
            )
            _ = try store.apply(
                identity: second,
                corefile: corefile(ttl: 10),
                certificateBindings: [binding],
                predecessorFencingToken: firstFence
            )
            XCTAssertNil(
                try store.certificateEvidence(identity: second)
            )
            XCTAssertEqual(
                try store.retiredCertificateEvidence(
                    identity: second
                ),
                firstEvidence
            )

            _ = try store.recordCertificateEvidence(
                identity: second,
                certificates: [
                    certificateEvidence(
                        binding: binding,
                        leaf: String(repeating: "c", count: 64),
                        issuer: String(repeating: "d", count: 64)
                    ),
                ]
            )
            try store.clearRetiredCertificateEvidence(
                identity: second,
                expected: firstEvidence
            )
            XCTAssertNil(
                try store.retiredCertificateEvidence(
                    identity: second
                )
            )
            XCTAssertEqual(
                try store.certificateEvidence(
                    identity: second
                )?.identity,
                second
            )
        }
    }

    func testCertificateEvidenceRetirementRollsBackBeforePointerAdvance()
        throws
    {
        try withStore { store, root in
            let binding = certificateBinding()
            _ = try store.apply(
                identity: identity(),
                corefile: corefile(),
                certificateBindings: [binding]
            )
            let evidence = try XCTUnwrap(
                store.recordCertificateEvidence(
                    identity: identity(),
                    certificates: [
                        certificateEvidence(binding: binding),
                    ]
                )
            )
            let dnsRoot = root
                .appendingPathComponent(projectUUID)
                .appendingPathComponent(dnsUUID)
            XCTAssertEqual(
                rename(
                    dnsRoot
                        .appendingPathComponent(
                            "certificate-evidence.json"
                        ).path,
                    dnsRoot
                        .appendingPathComponent(
                            "certificate-retired.json"
                        ).path
                ),
                0
            )

            let restarted = try NetworkHelperStateStore(rootURL: root)
            XCTAssertEqual(
                try restarted.certificateEvidence(
                    identity: identity()
                ),
                evidence
            )
            XCTAssertNil(
                try restarted.retiredCertificateEvidence(
                    identity: identity()
                )
            )
        }
    }

    func testInterruptedRotationRecovers() throws {
        try withStore { store, root in
            let binding = certificateBinding()
            _ = try store.apply(
                identity: identity(),
                corefile: corefile(),
                certificateBindings: [binding]
            )
            let pending = try store.beginCertificateReplacement(
                identity: identity()
            )
            XCTAssertEqual(pending.phase, .intent)
            XCTAssertNil(pending.replacement)

            let restarted = try NetworkHelperStateStore(rootURL: root)
            XCTAssertEqual(
                try restarted.pendingCertificateReplacement(
                    identity: identity()
                ),
                pending
            )
            XCTAssertNil(
                try restarted.certificateEvidence(
                    identity: identity()
                )
            )
        }
    }

    func testGenerationAdvanceIntentCrashRestoresPriorGeneration()
        throws
    {
        try withStore { store, root in
            let binding = certificateBinding()
            let first = identity()
            _ = try store.apply(
                identity: first,
                corefile: corefile(),
                certificateBindings: [binding]
            )
            let priorEvidence = try XCTUnwrap(
                store.recordCertificateEvidence(
                    identity: first,
                    certificates: [
                        certificateEvidence(binding: binding),
                    ]
                )
            )
            let second = identity(
                generation: 2,
                fence: secondFence
            )
            _ = try store.apply(
                identity: second,
                corefile: corefile(),
                certificateBindings: [binding],
                predecessorFencingToken: firstFence
            )
            _ = try store.beginCertificateReplacement(
                identity: second
            )

            let restarted = try NetworkHelperStateStore(
                rootURL: root
            )

            XCTAssertEqual(
                try restarted.status(identity: first).disposition,
                .active
            )
            XCTAssertEqual(
                try restarted.status(identity: second).disposition,
                .conflict
            )
            XCTAssertEqual(
                try restarted.certificateEvidence(
                    identity: first
                ),
                priorEvidence
            )
            XCTAssertNil(
                try restarted.pendingCertificateReplacement(
                    identity: first
                )
            )
            XCTAssertNil(
                try restarted.retiredCertificateEvidence(
                    identity: first
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: generationURL(
                        root: root,
                        generation: 2
                    ).path
                )
            )
        }
    }

    func testExactCleanup() throws {
        try withStore { store, _ in
            let binding = certificateBinding()
            _ = try store.apply(
                identity: identity(),
                corefile: corefile(),
                certificateBindings: [binding]
            )
            let prior = try XCTUnwrap(
                store.recordCertificateEvidence(
                    identity: identity(),
                    certificates: [
                        certificateEvidence(binding: binding),
                    ]
                )
            )
            _ = try store.beginCertificateReplacement(
                identity: identity()
            )
            XCTAssertNil(
                try store.rollbackPendingCertificateReplacement(
                    identity: identity()
                )
            )
            XCTAssertEqual(
                try store.certificateEvidence(identity: identity()),
                prior
            )
            XCTAssertNil(
                try store.pendingCertificateReplacement(
                    identity: identity()
                )
            )
        }
    }

    func testProviderCertificateReturnsTypedUnavailableAndRemainsRemovable()
        throws
    {
        try withStore { store, _ in
            let provider = ProjectCertificateRequestBinding(
                name: "provider",
                certificateUUID: dnsUUID,
                source: .provider,
                issuer: "external",
                renewBeforeSeconds: 3_600,
                validitySeconds: 86_400,
                statusPolicy: .ifAvailable,
                dnsNames: ["api.example.test"]
            )
            let dispatcher = NetworkHelperDispatcher(store: store)
            let applied = try dispatch(
                dispatcher,
                NetworkHelperRequest(
                    operation: .apply,
                    identity: identity(),
                    corefile: corefile(),
                    certificateBindings: [provider]
                )
            )
            XCTAssertEqual(
                applied.error?.code,
                .certificateUnavailable
            )
            XCTAssertEqual(
                try store.status(identity: identity()).disposition,
                .active
            )

            let removed = try dispatch(
                dispatcher,
                NetworkHelperRequest(
                    operation: .remove,
                    identity: identity()
                )
            )
            XCTAssertEqual(removed.status?.disposition, .absent)
        }
    }

    func testCertificateCoordinatorMapsLockedAndTamperedIdentityFailures() {
        XCTAssertEqual(
            NetworkHelperCertificateCoordinator
                .mappedIdentityStoreError(
                    CertificateIdentityStoreError.keychainLocked
                ),
            .certificateUnavailable
        )
        XCTAssertEqual(
            NetworkHelperCertificateCoordinator
                .mappedIdentityStoreError(
                    CertificateIdentityStoreError.tampered
                ),
            .invalidCertificate
        )
    }

    func testLockedKeychainPreservesPrior() throws {
        try assertReplacementFailurePreservesPrior(
            expected: .certificateUnavailable
        ) { _, _, _ in
            TestCertificateIssuer { _, _ in
                throw CertificateIdentityStoreError.keychainLocked
            }
        }
    }

    func testWrongSANPreservesPrior() throws {
        try assertReplacementFailurePreservesPrior(
            expected: .invalidCertificate
        ) { store, identity, binding in
            let handle = try store.generateLocalIdentity(
                scope: try CertificateIdentityScope(
                    projectUUID: identity.projectUUID,
                    certificateUUID: binding.certificateUUID,
                    generation: identity.generation
                ),
                dnsNames: ["wrong.example.test"],
                validity: 86_400,
                now: Self.certificateTestNow
            )
            return TestCertificateIssuer { _, _ in
                NetworkHelperIssuedCertificate(
                    identity: handle,
                    verifiedRevocationStatus: .suppliedGood
                )
            }
        }
    }

    func testExpiredReplacementPreservesPrior() throws {
        try assertReplacementFailurePreservesPrior(
            expected: .invalidCertificate
        ) { store, identity, binding in
            let handle = try store.generateLocalIdentity(
                scope: try CertificateIdentityScope(
                    projectUUID: identity.projectUUID,
                    certificateUUID: binding.certificateUUID,
                    generation: identity.generation
                ),
                dnsNames: binding.dnsNames,
                validity: 3_600,
                now: Self.certificateTestNow
                    .addingTimeInterval(-7_200)
            )
            return TestCertificateIssuer { _, _ in
                NetworkHelperIssuedCertificate(
                    identity: handle,
                    verifiedRevocationStatus: .suppliedGood
                )
            }
        }
    }

    func testRevokedIssuerRejected() throws {
        try assertReplacementFailurePreservesPrior(
            expected: .invalidCertificate
        ) { store, identity, binding in
            let handle = try store.generateLocalIdentity(
                scope: try CertificateIdentityScope(
                    projectUUID: identity.projectUUID,
                    certificateUUID: binding.certificateUUID,
                    generation: identity.generation
                ),
                dnsNames: binding.dnsNames,
                validity: 86_400,
                now: Self.certificateTestNow
            )
            return TestCertificateIssuer { _, _ in
                NetworkHelperIssuedCertificate(
                    identity: handle,
                    verifiedRevocationStatus: .suppliedRevoked
                )
            }
        }
    }

    func testIssuerOutagePreservesPrior() throws {
        try assertReplacementFailurePreservesPrior(
            expected: .certificateUnavailable
        ) { _, _, _ in
            TestCertificateIssuer { _, _ in
                throw NetworkHelperError.certificateUnavailable
            }
        }
    }

    func testIssuanceCancellationRollsBack() throws {
        try assertReplacementFailurePreservesPrior(
            expected: .certificateUnavailable
        ) { _, _, _ in
            TestCertificateIssuer { _, _ in
                throw CancellationError()
            }
        }
    }

    func testStatusDoesNotReissueProviderCertificate() throws {
        try withStore { store, _ in
            let binding = ProjectCertificateRequestBinding(
                name: "provider",
                certificateUUID: dnsUUID,
                source: .provider,
                issuer: "external",
                renewBeforeSeconds: 3_600,
                validitySeconds: 86_400,
                statusPolicy: .ifAvailable,
                dnsNames: ["api.example.test"]
            )
            _ = try store.apply(
                identity: identity(),
                corefile: corefile(),
                certificateBindings: [binding]
            )
            _ = try store.recordCertificateEvidence(
                identity: identity(),
                certificates: [
                    certificateEvidence(binding: binding),
                ]
            )
            let issuer = CountingCertificateIssuer()
            let response = try dispatch(
                NetworkHelperDispatcher(
                    store: store,
                    certificateCoordinator:
                        NetworkHelperCertificateCoordinator(
                            certificateIssuers: [issuer]
                        )
                ),
                NetworkHelperRequest(
                    operation: .status,
                    identity: identity()
                )
            )
            XCTAssertEqual(
                response.error?.code,
                .certificateUnavailable
            )
            XCTAssertEqual(issuer.count, 0)
        }
    }

    func testCertificateCoordinatorNeverDeletesImportedIdentity() throws {
        let coordinator = NetworkHelperCertificateCoordinator()
        let imported = NetworkHelperPersistedCertificateEvidence(
            identity: identity(),
            requestSHA256: String(repeating: "e", count: 64),
            certificates: [
                NetworkHelperCertificateEvidence(
                    name: "imported",
                    certificateUUID: dnsUUID,
                    source: .imported,
                    certificateSHA256:
                        String(repeating: "f", count: 64),
                    issuerCertificateSHA256: nil,
                    dnsNames: ["api.example.test"],
                    notValidBefore:
                        Date(timeIntervalSince1970: 1_000),
                    notValidAfter:
                        Date(timeIntervalSince1970: 100_000),
                    revocationStatus:
                        CertificateRevocationStatus.unavailable.rawValue
                ),
            ]
        )
        XCTAssertNoThrow(
            try coordinator.cleanup(
                identity: identity(),
                evidence: imported
            )
        )
        XCTAssertFalse(coordinator.hasActiveCertificates)
    }

    func testDispatcherActivatesRecoversAndRemovesLocalCertificate()
        throws
    {
        try withStore { store, root in
            let project = UUID().uuidString.lowercased()
            let dns = UUID().uuidString.lowercased()
            let certificate = UUID().uuidString.lowercased()
            let activeIdentity = NetworkHelperDNSIdentity(
                projectUUID: project,
                dnsUUID: dns,
                generation: 1,
                fencingToken: UUID().uuidString.lowercased()
            )
            let binding = ProjectCertificateRequestBinding(
                name: "local",
                certificateUUID: certificate,
                source: .localCA,
                renewBeforeSeconds: 3_600,
                validitySeconds: 86_400,
                statusPolicy: .ifAvailable,
                dnsNames: ["api.example.test"]
            )
            let scope = try CertificateIdentityScope(
                projectUUID: project,
                certificateUUID: certificate,
                generation: 1
            )
            let identityStore = CertificateIdentityStore()
            var cleanupEvidence:
                NetworkHelperPersistedCertificateEvidence?
            defer {
                if let certificate =
                    cleanupEvidence?.certificates.first,
                   let issuer =
                    certificate.issuerCertificateSHA256 {
                    try? identityStore.cleanupManagedIdentity(
                        scope: scope,
                        expectedLeafSHA256:
                            certificate.certificateSHA256,
                        expectedIssuerSHA256: issuer
                    )
                }
            }

            let applied = try dispatch(
                NetworkHelperDispatcher(store: store),
                NetworkHelperRequest(
                    operation: .apply,
                    identity: activeIdentity,
                    corefile: corefile(),
                    certificateBindings: [binding]
                )
            )
            XCTAssertNil(applied.error)
            XCTAssertEqual(applied.status?.certificateActive, true)
            XCTAssertEqual(
                applied.status?.certificateSummaries?.map(\.name),
                ["local"]
            )
            cleanupEvidence = try XCTUnwrap(
                store.certificateEvidence(identity: activeIdentity)
            )

            let restartedStore = try NetworkHelperStateStore(
                rootURL: root
            )
            let restarted = NetworkHelperDispatcher(
                store: restartedStore
            )
            let recovered = try dispatch(
                restarted,
                NetworkHelperRequest(
                    operation: .status,
                    identity: activeIdentity
                )
            )
            XCTAssertNil(recovered.error)
            XCTAssertEqual(recovered.status?.certificateActive, true)
            XCTAssertEqual(
                recovered.status?.certificateEvidenceSHA256,
                applied.status?.certificateEvidenceSHA256
            )

            let removed = try dispatch(
                restarted,
                NetworkHelperRequest(
                    operation: .remove,
                    identity: activeIdentity
                )
            )
            XCTAssertEqual(removed.status?.disposition, .absent)
            XCTAssertThrowsError(
                try identityStore.managedIdentityEvidence(
                    scope: scope
                )
            ) {
                XCTAssertEqual(
                    $0 as? CertificateIdentityStoreError,
                    .notFound
                )
            }
            cleanupEvidence = nil
        }
    }

    func testHostAccessConfigurationPersistsAndRecoversExactly()
        throws
    {
        try withStore { store, root in
            let binding = hostAccessBinding()
            let applied = try store.apply(
                identity: identity(),
                corefile: corefile(),
                hostAccessBindings: [binding]
            )
            let expected = try XCTUnwrap(
                applied.hostAccessSHA256
            )
            XCTAssertEqual(expected.count, 64)
            XCTAssertEqual(
                try store.activeHostAccessConfigurations(),
                [
                    NetworkHelperPersistedHostAccessConfiguration(
                        identity: identity(),
                        bindings: [binding],
                        sha256: expected
                    ),
                ]
            )

            let restarted = try NetworkHelperStateStore(
                rootURL: root
            )
            XCTAssertEqual(
                try restarted.status(identity: identity()),
                applied
            )
            XCTAssertEqual(
                try restarted
                    .activeHostAccessConfigurations()
                    .first?.bindings,
                [binding]
            )
            _ = try restarted.remove(identity: identity())
            XCTAssertTrue(
                try restarted
                    .activeHostAccessConfigurations()
                    .isEmpty
            )
        }
    }

    func testIngressConfigurationPersistsRefreshesAndQuarantinesTampering()
        throws
    {
        try withStore { store, root in
            let first = identity()
            let ingress = ingressBinding()
            let applied = try store.apply(
                identity: first,
                corefile: corefile(),
                ingressBindings: [ingress]
            )
            let digest = try XCTUnwrap(applied.ingressSHA256)
            XCTAssertEqual(
                try store.activeIngressConfigurations(),
                [NetworkHelperPersistedIngressConfiguration(
                    identity: first,
                    bindings: [ingress],
                    sha256: digest
                )]
            )

            let restarted = try NetworkHelperStateStore(rootURL: root)
            XCTAssertEqual(
                try restarted.activeIngressConfigurations().first?.bindings,
                [ingress]
            )

            let second = identity(generation: 2, fence: secondFence)
            _ = try restarted.apply(
                identity: second,
                corefile: corefile(ttl: 10),
                predecessorFencingToken: firstFence
            )
            XCTAssertTrue(try restarted.activeIngressConfigurations().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: generationURL(root: root, generation: 1)
                    .appendingPathComponent("Ingress.json").path
            ))

            let third = identity(generation: 3, fence: thirdFence)
            _ = try restarted.apply(
                identity: third,
                corefile: corefile(ttl: 20),
                ingressBindings: [ingress],
                predecessorFencingToken: secondFence
            )
            let ingressURL = generationURL(root: root, generation: 3)
                .appendingPathComponent("Ingress.json")
            let handle = try FileHandle(forWritingTo: ingressURL)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("tampered".utf8))
            try handle.close()
            XCTAssertEqual(
                try restarted.status(identity: third).disposition,
                .quarantined
            )
            XCTAssertThrowsError(try restarted.remove(identity: third)) {
                XCTAssertEqual($0 as? NetworkHelperError, .quarantined)
            }
        }
    }

    func testPolicyConfigurationPersistsRecoversAndQuarantinesTampering()
        throws
    {
        try withStore { store, root in
            let plan = try policyPlan()
            let applied = try store.apply(
                identity: identity(),
                corefile: corefile(),
                policyPlan: plan
            )
            XCTAssertEqual(applied.policySHA256, plan.sha256)
            XCTAssertEqual(
                try store.activePolicyConfigurations(),
                [NetworkHelperPersistedPolicyConfiguration(
                    identity: identity(), plan: plan, sha256: plan.sha256
                )]
            )

            let restarted = try NetworkHelperStateStore(rootURL: root)
            XCTAssertEqual(
                try restarted.activePolicyConfigurations().first?.plan,
                plan
            )
            let policyURL = generationURL(root: root, generation: 1)
                .appendingPathComponent("Policy.json")
            try Data("tampered".utf8).write(to: policyURL)
            XCTAssertEqual(
                try restarted.status(identity: identity()).disposition,
                .quarantined
            )
        }
    }

    func testPolicyBrokerRestoresExactGenerationAndReplacesOldPolicy()
        throws
    {
        try withStore { store, _ in
            let first = identity()
            let firstPlan = try policyPlan(generation: 1, dns: "old.example.test")
            let firstBroker = NetworkHelperPolicyBroker()
            let firstDispatcher = NetworkHelperDispatcher(
                store: store,
                policyBroker: firstBroker
            )
            let applied = try dispatch(
                firstDispatcher,
                NetworkHelperRequest(
                    operation: .apply,
                    identity: first,
                    corefile: corefile(),
                    policyPlan: firstPlan
                )
            )
            XCTAssertEqual(applied.status?.policySHA256, firstPlan.sha256)
            XCTAssertEqual(applied.status?.policyActive, true)

            let restartedBroker = NetworkHelperPolicyBroker()
            let restartedDispatcher = NetworkHelperDispatcher(
                store: store,
                policyBroker: restartedBroker
            )
            let restored = try dispatch(
                restartedDispatcher,
                NetworkHelperRequest(operation: .status, identity: first)
            )
            XCTAssertEqual(restored.status?.policyActive, true)
            XCTAssertTrue(
                restartedBroker.allows(identity: first, flow: policyFlow(dns: "old.example.test"))
            )

            let second = identity(generation: 2, fence: secondFence)
            let secondPlan = try policyPlan(generation: 2, dns: "new.example.test")
            let replacement = try dispatch(
                restartedDispatcher,
                NetworkHelperRequest(
                    operation: .apply,
                    identity: second,
                    corefile: corefile(ttl: 10),
                    policyPlan: secondPlan,
                    predecessorFencingToken: firstFence
                )
            )
            XCTAssertEqual(replacement.status?.policyActive, true)
            XCTAssertNil(restartedBroker.sha256(identity: first))
            XCTAssertFalse(
                restartedBroker.allows(identity: second, flow: policyFlow(dns: "old.example.test"))
            )
            XCTAssertTrue(
                restartedBroker.allows(identity: second, flow: policyFlow(dns: "new.example.test"))
            )
        }
    }

    func testHostAccessBrokerForwardsOnlyTheExactTCPBinding()
        throws
    {
        guard let interfaceAddress = firstActiveNonLoopbackIPv4()
        else {
            throw XCTSkip(
                "No active non-loopback IPv4 interface is available."
            )
        }
        let target = try makeLoopbackTCPServer()
        defer { Darwin.close(target.descriptor) }
        let binding = ProjectDNSHostAccessBinding(
            hostname: "host-api.internal",
            protocolName: .tcp,
            addressClass: .loopback,
            listenAddress: interfaceAddress,
            clientCIDR: "\(interfaceAddress)/32",
            targetAddress: "127.0.0.1",
            port: target.port
        )
        let targetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { targetFinished.signal() }
            guard waitReadable(
                target.descriptor,
                milliseconds: 5_000
            ) else {
                return
            }
            let connection = Darwin.accept(
                target.descriptor,
                nil,
                nil
            )
            guard connection >= 0 else { return }
            defer { Darwin.close(connection) }
            var bytes = [UInt8](repeating: 0, count: 16)
            let count = Darwin.read(
                connection,
                &bytes,
                bytes.count
            )
            guard count == 4,
                  String(decoding: bytes[0..<count], as: UTF8.self)
                    == "ping" else {
                return
            }
            _ = Darwin.write(
                connection,
                Array("pong".utf8),
                4
            )
        }

        let broker = NetworkHelperHostAccessBroker()
        XCTAssertNotNil(
            try broker.apply(
                identity: identity(),
                bindings: [binding]
            )
        )
        defer { broker.remove(identity: identity()) }

        let client = try connectTCP(
            address: interfaceAddress,
            port: target.port
        )
        defer { Darwin.close(client) }
        XCTAssertEqual(
            Darwin.write(client, Array("ping".utf8), 4),
            4
        )
        XCTAssertTrue(
            waitReadable(client, milliseconds: 5_000)
        )
        var response = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(
            Darwin.read(client, &response, response.count),
            4
        )
        XCTAssertEqual(
            String(decoding: response, as: UTF8.self),
            "pong"
        )
        XCTAssertEqual(
            targetFinished.wait(timeout: .now() + 5),
            .success
        )
    }

    func testHostAccessBrokerForwardsOnlyTheExactUDPBinding()
        throws
    {
        guard let interfaceAddress = firstActiveNonLoopbackIPv4()
        else {
            throw XCTSkip(
                "No active non-loopback IPv4 interface is available."
            )
        }
        let target = try makeLoopbackUDPServer()
        defer { Darwin.close(target.descriptor) }
        let binding = ProjectDNSHostAccessBinding(
            hostname: "host-dns.internal",
            protocolName: .udp,
            addressClass: .loopback,
            listenAddress: interfaceAddress,
            clientCIDR: "\(interfaceAddress)/32",
            targetAddress: "127.0.0.1",
            port: target.port
        )
        let targetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { targetFinished.signal() }
            guard waitReadable(
                target.descriptor,
                milliseconds: 5_000
            ) else {
                return
            }
            var peer = sockaddr_in()
            var peerLength = socklen_t(
                MemoryLayout<sockaddr_in>.size
            )
            var bytes = [UInt8](repeating: 0, count: 16)
            let count = withUnsafeMutablePointer(to: &peer) {
                pointer in
                pointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) {
                    Darwin.recvfrom(
                        target.descriptor,
                        &bytes,
                        bytes.count,
                        0,
                        $0,
                        &peerLength
                    )
                }
            }
            guard count == 4,
                  String(
                    decoding: bytes[0..<count],
                    as: UTF8.self
                  ) == "ping" else {
                return
            }
            var mutablePeer = peer
            _ = withUnsafePointer(to: &mutablePeer) {
                pointer in
                pointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) {
                    Darwin.sendto(
                        target.descriptor,
                        Array("pong".utf8),
                        4,
                        0,
                        $0,
                        peerLength
                    )
                }
            }
        }

        let broker = NetworkHelperHostAccessBroker()
        XCTAssertNotNil(
            try broker.apply(
                identity: identity(),
                bindings: [binding]
            )
        )
        defer { broker.remove(identity: identity()) }

        XCTAssertEqual(
            try udpRoundTrip(
                address: interfaceAddress,
                port: target.port,
                payload: Data("ping".utf8)
            ),
            Data("pong".utf8)
        )
        XCTAssertEqual(
            targetFinished.wait(timeout: .now() + 5),
            .success
        )
    }

    func testHostAccessValidationRejectsEscapesAndDuplicateListeners()
        throws
    {
        let valid = hostAccessBinding()
        let invalid = [
            ProjectDNSHostAccessBinding(
                hostname: "metadata",
                protocolName: .tcp,
                addressClass: .loopback,
                listenAddress: valid.listenAddress,
                clientCIDR: valid.clientCIDR,
                targetAddress: valid.targetAddress,
                port: valid.port
            ),
            ProjectDNSHostAccessBinding(
                hostname: valid.hostname,
                protocolName: .tcp,
                addressClass: .loopback,
                listenAddress: valid.listenAddress,
                clientCIDR: "192.168.65.0/24",
                targetAddress: valid.targetAddress,
                port: valid.port
            ),
            ProjectDNSHostAccessBinding(
                hostname: valid.hostname,
                protocolName: .tcp,
                addressClass: .loopback,
                listenAddress: valid.listenAddress,
                clientCIDR: valid.clientCIDR,
                targetAddress: "192.168.64.10",
                port: valid.port
            ),
        ]
        for binding in invalid {
            XCTAssertThrowsError(
                try NetworkHelperHostAccessValidation
                    .validated([binding])
            ) {
                XCTAssertEqual(
                    $0 as? NetworkHelperError,
                    .invalidRequest
                )
            }
        }
        let duplicateListener =
            ProjectDNSHostAccessBinding(
                hostname: "host-api-two.internal",
                protocolName: valid.protocolName,
                addressClass: valid.addressClass,
                listenAddress: valid.listenAddress,
                clientCIDR: valid.clientCIDR,
                targetAddress: valid.targetAddress,
                port: valid.port
            )
        XCTAssertThrowsError(
            try NetworkHelperHostAccessValidation.validated(
                [valid, duplicateListener]
            )
        ) {
            XCTAssertEqual(
                $0 as? NetworkHelperError,
                .invalidRequest
            )
        }
        let secondPort = ProjectDNSHostAccessBinding(
            hostname: valid.hostname,
            protocolName: valid.protocolName,
            addressClass: valid.addressClass,
            listenAddress: valid.listenAddress,
            clientCIDR: valid.clientCIDR,
            targetAddress: valid.targetAddress,
            port: valid.port + 1
        )
        XCTAssertEqual(
            try NetworkHelperHostAccessValidation.validated(
                [secondPort, valid]
            ),
            [valid, secondPort]
        )
    }

    func testCanonicalFramingRoundTripsAndRejectsNonCanonicalJSON() throws {
        let request = NetworkHelperRequest(
            requestID: UUID(uuidString:
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            operation: .apply,
            identity: identity(),
            corefile: corefile()
        )
        let frame = try NetworkHelperCanonicalJSON.frame(request)
        XCTAssertEqual(
            try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperRequest.self,
                from: frame
            ),
            request
        )

        let canonical = try NetworkHelperCanonicalJSON.encode(request)
        let nonCanonical = Data(" \(String(decoding: canonical, as: UTF8.self))".utf8)
        let nonCanonicalFrame = try ContainerizationHelperFraming.frame(
            nonCanonical
        )
        XCTAssertThrowsError(
            try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperRequest.self,
                from: nonCanonicalFrame
            )
        ) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidFrame)
        }
    }

    func testIngressAccessLogRoundTripsAsBoundedMachineStatus() throws {
        let entry = NetworkHelperIngressAccessLogEntry(
            timestampUnixMilliseconds: 1_234,
            listenerName: "api",
            method: "GET",
            routeHostname: "api.internal",
            routePathPrefix: "/v1",
            protocolName: .http,
            targetServiceUUID: projectUUID,
            outcome: .forwarded,
            durationMilliseconds: 5
        )
        let mutualTLSAudit = NetworkHelperMutualTLSAuditEntry(
            timestamp: Date(timeIntervalSince1970: 2),
            listenerName: "api",
            allowed: false,
            reason: .identityRejected,
            identityURI: nil,
            certificateSHA256: String(
                repeating: "c",
                count: 64
            )
        )
        let response = NetworkHelperResponse(
            requestID: UUID().uuidString.lowercased(),
            operation: .status,
            status: NetworkHelperStatus(
                disposition: .active,
                identity: identity(),
                corefileSHA256: String(repeating: "a", count: 64),
                ingressSHA256: String(repeating: "b", count: 64),
                ingressActive: true,
                ingressAccessLog: [entry],
                mutualTLSAudit: [mutualTLSAudit],
                reason: nil
            )
        )

        let decoded = try NetworkHelperCanonicalJSON.decodeFrame(
            NetworkHelperResponse.self,
            from: NetworkHelperCanonicalJSON.frame(response)
        )
        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.status?.ingressAccessLog, [entry])
        XCTAssertEqual(
            decoded.status?.mutualTLSAudit,
            [mutualTLSAudit]
        )
    }

    func testRequestValidationRejectsInvalidIdentityAndOversizedCorefile() {
        let invalidIdentity = NetworkHelperRequest(
            operation: .apply,
            identity: NetworkHelperDNSIdentity(
                projectUUID: "not-a-uuid",
                dnsUUID: dnsUUID,
                generation: 1,
                fencingToken: firstFence
            ),
            corefile: corefile()
        )
        XCTAssertThrowsError(try invalidIdentity.validated()) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidIdentity)
        }

        let oversized = NetworkHelperRequest(
            operation: .apply,
            identity: identity(),
            corefile: String(
                repeating: "a",
                count: NetworkHelperProtocolV1.maximumCorefileBytes + 1
            )
        )
        XCTAssertThrowsError(try oversized.validated()) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidCorefile)
        }

        let invalidPredecessor = NetworkHelperRequest(
            operation: .apply,
            identity: identity(),
            corefile: corefile(),
            predecessorFencingToken: "not-a-uuid"
        )
        XCTAssertThrowsError(try invalidPredecessor.validated()) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidIdentity)
        }

        let statusWithPredecessor = NetworkHelperRequest(
            operation: .status,
            identity: identity(),
            predecessorFencingToken: firstFence
        )
        XCTAssertThrowsError(try statusWithPredecessor.validated()) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidRequest)
        }

        let invalidIngress = NetworkHelperRequest(
            operation: .apply,
            identity: identity(),
            corefile: corefile(),
            ingressBindings: [ingressBinding(port: 0)]
        )
        XCTAssertThrowsError(try invalidIngress.validated()) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidRequest)
        }

        let missingTargetIdentity = NetworkHelperRequest(
            operation: .apply,
            identity: identity(),
            corefile: corefile(),
            ingressBindings: [
                ProjectIngressListenerBinding(
                    name: "api",
                    bindAddress: "127.0.0.1",
                    port: 8_443,
                    exposure: .localhost,
                    routes: [
                        ProjectIngressRouteBinding(
                            hostname: "api.internal",
                            pathPrefix: "/",
                            methods: ["GET"],
                            protocolName: .http,
                            targetServiceName: "api",
                            targetServiceUUIDs: [],
                            targetPort: 8_080,
                            backends: []
                        ),
                    ]
                ),
            ]
        )
        XCTAssertThrowsError(try missingTargetIdentity.validated()) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidRequest)
        }

        let oversizedIngress = NetworkHelperRequest(
            operation: .apply,
            identity: identity(),
            corefile: corefile(),
            ingressBindings: Array(
                repeating: ingressBinding(),
                count: HostwrightIngressListener.maximumListeners + 1
            )
        )
        XCTAssertThrowsError(try oversizedIngress.validated()) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidRequest)
        }
    }

    func testApplyStatusGenerationReplacementAndExactRemove() throws {
        try withStore { store, root in
            let first = identity()
            let applied = try store.apply(
                identity: first,
                corefile: corefile()
            )
            XCTAssertEqual(applied.disposition, .active)
            XCTAssertEqual(try store.status(identity: first), applied)
            XCTAssertEqual(
                try store.apply(identity: first, corefile: corefile()),
                applied
            )

            let second = identity(generation: 2, fence: secondFence)
            XCTAssertThrowsError(
                try store.apply(
                    identity: second,
                    corefile: corefile(ttl: 10)
                )
            ) {
                XCTAssertEqual($0 as? NetworkHelperError, .conflict)
            }
            XCTAssertThrowsError(
                try store.apply(
                    identity: second,
                    corefile: corefile(ttl: 10),
                    predecessorFencingToken: thirdFence
                )
            ) {
                XCTAssertEqual($0 as? NetworkHelperError, .conflict)
            }
            XCTAssertEqual(
                try store.status(identity: first).disposition,
                .active
            )
            XCTAssertEqual(
                try store.apply(
                    identity: second,
                    corefile: corefile(ttl: 10),
                    predecessorFencingToken: firstFence
                )
                    .disposition,
                .active
            )
            let third = identity(generation: 3, fence: thirdFence)
            XCTAssertThrowsError(
                try store.apply(
                    identity: third,
                    corefile: corefile(ttl: 20),
                    predecessorFencingToken: firstFence
                )
            ) {
                XCTAssertEqual($0 as? NetworkHelperError, .conflict)
            }
            XCTAssertEqual(
                try store.status(identity: second).disposition,
                .active
            )
            XCTAssertEqual(
                try store.status(identity: first).disposition,
                .conflict
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: generationURL(root: root, generation: 1).path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: generationURL(root: root, generation: 2).path
                )
            )

            XCTAssertThrowsError(try store.remove(identity: first)) {
                XCTAssertEqual($0 as? NetworkHelperError, .conflict)
            }
            XCTAssertEqual(
                try store.remove(identity: second).disposition,
                .absent
            )
            XCTAssertEqual(
                try store.status(identity: second).disposition,
                .absent
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root
                        .appendingPathComponent(projectUUID)
                        .path
                )
            )
        }
    }

    func testSameGenerationWithDifferentFenceCannotReplaceOwnership() throws {
        try withStore { store, _ in
            _ = try store.apply(identity: identity(), corefile: corefile())
            XCTAssertThrowsError(
                try store.apply(
                    identity: identity(fence: secondFence),
                    corefile: corefile()
                )
            ) {
                XCTAssertEqual($0 as? NetworkHelperError, .conflict)
            }
        }
    }

    func testActiveDirectoryRemainsStableAcrossRefreshAndRestart() throws {
        try withStore { store, root in
            let first = identity()
            _ = try store.apply(identity: first, corefile: corefile())
            let active = root
                .appendingPathComponent(projectUUID)
                .appendingPathComponent(dnsUUID)
                .appendingPathComponent("active")
            let directoryDescriptor = open(
                active.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
            defer { Darwin.close(directoryDescriptor) }
            var before = stat()
            XCTAssertEqual(fstat(directoryDescriptor, &before), 0)

            let second = identity(generation: 2, fence: secondFence)
            let refreshedCorefile = corefile(ttl: 17)
            _ = try store.apply(
                identity: second,
                corefile: refreshedCorefile,
                predecessorFencingToken: firstFence
            )
            var after = stat()
            XCTAssertEqual(lstat(active.path, &after), 0)
            XCTAssertEqual(before.st_dev, after.st_dev)
            XCTAssertEqual(before.st_ino, after.st_ino)

            let activeCorefileDescriptor = openat(
                directoryDescriptor,
                "Corefile",
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            XCTAssertGreaterThanOrEqual(activeCorefileDescriptor, 0)
            XCTAssertEqual(
                try readAll(descriptor: activeCorefileDescriptor),
                Data(refreshedCorefile.utf8)
            )

            let recovered = try NetworkHelperStateStore(rootURL: root)
            XCTAssertEqual(
                try recovered.status(identity: second).disposition,
                .active
            )
            var restarted = stat()
            XCTAssertEqual(lstat(active.path, &restarted), 0)
            XCTAssertEqual(before.st_dev, restarted.st_dev)
            XCTAssertEqual(before.st_ino, restarted.st_ino)

            _ = try recovered.remove(identity: second)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: active.path)
            )
        }
    }

    func testTamperedCorefileIsQuarantinedAndCannotBeRemoved() throws {
        try withStore { store, root in
            let identity = identity()
            _ = try store.apply(identity: identity, corefile: corefile())
            let corefileURL = generationURL(root: root, generation: 1)
                .appendingPathComponent("Corefile")
            let handle = try FileHandle(forWritingTo: corefileURL)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("tampered\n".utf8))
            try handle.close()

            XCTAssertEqual(
                try store.status(identity: identity).disposition,
                .quarantined
            )
            XCTAssertThrowsError(try store.remove(identity: identity)) {
                XCTAssertEqual($0 as? NetworkHelperError, .quarantined)
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: corefileURL.path)
            )
        }
    }

    func testSymlinkedCurrentPointerFailsClosedWithoutDeletingState() throws {
        try withStore { store, root in
            let identity = identity()
            _ = try store.apply(identity: identity, corefile: corefile())
            let dnsRoot = root
                .appendingPathComponent(projectUUID)
                .appendingPathComponent(dnsUUID)
            let current = dnsRoot.appendingPathComponent("current.json")
            XCTAssertEqual(unlink(current.path), 0)
            XCTAssertEqual(
                symlink(
                    generationURL(root: root, generation: 1)
                        .appendingPathComponent("Corefile")
                        .path,
                    current.path
                ),
                0
            )

            XCTAssertThrowsError(try store.status(identity: identity)) {
                XCTAssertEqual($0 as? NetworkHelperError, .unsafePath)
            }
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: generationURL(root: root, generation: 1)
                        .appendingPathComponent("Corefile")
                        .path
                )
            )
        }
    }

    func testRestartRecoveryRemovesIncompleteOwnedPendingGeneration() throws {
        try withStore { store, root in
            let identity = identity()
            _ = try store.apply(identity: identity, corefile: corefile())
            let pending = root
                .appendingPathComponent(projectUUID)
                .appendingPathComponent(dnsUUID)
                .appendingPathComponent("generations")
                .appendingPathComponent(
                    ".pending-55555555-5555-4555-8555-555555555555"
                )
            XCTAssertEqual(mkdir(pending.path, 0o700), 0)
            XCTAssertEqual(chmod(pending.path, 0o700), 0)

            let recovered = try NetworkHelperStateStore(rootURL: root)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: pending.path)
            )
            XCTAssertEqual(
                try recovered.status(identity: identity).disposition,
                .active
            )
        }
    }

    func testDispatcherReturnsTypedConflictWithoutChangingState() throws {
        try withStore { store, _ in
            let dispatcher = NetworkHelperDispatcher(store: store)
            let first = NetworkHelperRequest(
                operation: .apply,
                identity: identity(),
                corefile: corefile()
            )
            let firstResponse = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(first)
                )
            )
            XCTAssertEqual(firstResponse.status?.disposition, .active)

            let conflicting = NetworkHelperRequest(
                operation: .apply,
                identity: identity(fence: secondFence),
                corefile: corefile()
            )
            let conflictResponse = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(conflicting)
                )
            )
            XCTAssertEqual(conflictResponse.error?.code, .conflict)
            XCTAssertNil(conflictResponse.status)
            XCTAssertEqual(
                try store.status(identity: identity()).disposition,
                .active
            )
        }
    }

    func testDispatcherStaleRemoveKeepsActiveHostAccessBindings() throws {
        guard let interfaceAddress = firstActiveNonLoopbackIPv4()
        else {
            throw XCTSkip("No active non-loopback IPv4 interface is available.")
        }
        let target = try makeLoopbackTCPServer()
        defer { Darwin.close(target.descriptor) }

        try withStore { store, _ in
            let broker = NetworkHelperHostAccessBroker()
            let dispatcher = NetworkHelperDispatcher(
                store: store,
                hostAccessBroker: broker
            )
            let binding = ProjectDNSHostAccessBinding(
                hostname: "host-api.internal",
                protocolName: .tcp,
                addressClass: .loopback,
                listenAddress: interfaceAddress,
                clientCIDR: "\(interfaceAddress)/32",
                targetAddress: "127.0.0.1",
                port: target.port
            )
            let first = identity()
            let second = identity(generation: 2, fence: secondFence)

            _ = try dispatcher.dispatch(
                frame: try NetworkHelperCanonicalJSON.frame(
                    NetworkHelperRequest(
                        operation: .apply,
                        identity: first,
                        corefile: corefile(),
                        hostAccessBindings: [binding]
                    )
                )
            )
            let applied = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(
                        NetworkHelperRequest(
                            operation: .apply,
                            identity: second,
                            corefile: corefile(),
                            hostAccessBindings: [binding],
                            predecessorFencingToken: firstFence
                        )
                    )
                )
            )
            let staleRemove = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(
                        NetworkHelperRequest(
                            operation: .remove,
                            identity: first
                        )
                    )
                )
            )

            XCTAssertEqual(staleRemove.error?.code, .conflict)
            XCTAssertEqual(
                broker.sha256(identity: second),
                applied.status?.hostAccessSHA256
            )
            XCTAssertTrue(broker.hasActiveBindings)
        }
    }

    func testDispatcherStagesInactiveExactHostAccessBindingForRetryAndRemoval()
        throws
    {
        try withStore { store, _ in
            let broker = NetworkHelperHostAccessBroker()
            let dispatcher = NetworkHelperDispatcher(
                store: store,
                hostAccessBroker: broker
            )
            let binding = ProjectDNSHostAccessBinding(
                hostname: "host-api.internal",
                protocolName: .tcp,
                addressClass: .loopback,
                listenAddress: "192.0.2.1",
                clientCIDR: "192.0.2.0/24",
                targetAddress: "127.0.0.1",
                port: 6_508
            )
            let identity = identity()

            let applied = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(
                        NetworkHelperRequest(
                            operation: .apply,
                            identity: identity,
                            corefile: corefile(),
                            hostAccessBindings: [binding]
                        )
                    )
                )
            )
            let digest = try XCTUnwrap(applied.status?.hostAccessSHA256)
            XCTAssertEqual(applied.status?.disposition, .active)
            XCTAssertEqual(digest.count, 64)
            XCTAssertEqual(applied.status?.hostAccessActive, false)
            XCTAssertFalse(broker.hasActiveBindings)

            let staged = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(
                        NetworkHelperRequest(
                            operation: .status,
                            identity: identity
                        )
                    )
                )
            )
            XCTAssertEqual(staged.status?.disposition, .active)
            XCTAssertEqual(staged.status?.hostAccessSHA256, digest)
            XCTAssertEqual(staged.status?.hostAccessActive, false)
            XCTAssertFalse(broker.hasActiveBindings)

            let removed = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(
                        NetworkHelperRequest(
                            operation: .remove,
                            identity: identity
                        )
                    )
                )
            )
            XCTAssertEqual(removed.status?.disposition, .absent)
            XCTAssertFalse(broker.hasActiveBindings)
            XCTAssertTrue(
                try store.activeHostAccessConfigurations().isEmpty
            )
        }
    }

    func testDispatcherStagesInactiveIngressConflictAndRemovesExactState()
        throws
    {
        let occupied = try makeLoopbackTCPServer()
        defer { Darwin.close(occupied.descriptor) }

        try withStore { store, root in
            let broker = NetworkHelperIngressBroker()
            let dispatcher = NetworkHelperDispatcher(
                store: store,
                ingressBroker: broker
            )
            let binding = ingressBinding(port: occupied.port)
            let activeIdentity = identity()

            let applied = try dispatch(
                dispatcher,
                NetworkHelperRequest(
                    operation: .apply,
                    identity: activeIdentity,
                    corefile: corefile(),
                    ingressBindings: [binding]
                )
            )
            let digest = try XCTUnwrap(applied.status?.ingressSHA256)
            XCTAssertEqual(applied.status?.disposition, .active)
            XCTAssertEqual(digest.count, 64)
            XCTAssertEqual(applied.status?.ingressActive, false)
            XCTAssertFalse(broker.hasActiveBindings)

            let status = try dispatch(
                dispatcher,
                NetworkHelperRequest(
                    operation: .status,
                    identity: activeIdentity
                )
            )
            XCTAssertEqual(status.status?.ingressSHA256, digest)
            XCTAssertEqual(status.status?.ingressActive, false)

            let removed = try dispatch(
                dispatcher,
                NetworkHelperRequest(
                    operation: .remove,
                    identity: activeIdentity
                )
            )
            XCTAssertEqual(removed.status?.disposition, .absent)
            XCTAssertFalse(broker.hasActiveBindings)
            XCTAssertTrue(try store.activeIngressConfigurations().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent(projectUUID)
                    .appendingPathComponent(dnsUUID)
                    .path
            ))
        }
    }

    func testDispatcherStatusReplaysPersistedIngressAfterBrokerRestart()
        throws
    {
        try withStore { store, _ in
            let activeIdentity = identity()
            let binding = ingressBinding()
            let firstBroker = NetworkHelperIngressBroker()
            let firstDispatcher = NetworkHelperDispatcher(
                store: store,
                ingressBroker: firstBroker
            )
            let applied = try dispatch(
                firstDispatcher,
                NetworkHelperRequest(
                    operation: .apply,
                    identity: activeIdentity,
                    corefile: corefile(),
                    ingressBindings: [binding]
                )
            )
            let digest = try XCTUnwrap(applied.status?.ingressSHA256)
            XCTAssertEqual(applied.status?.ingressActive, true)

            firstBroker.remove(identity: activeIdentity)
            let restartedBroker = NetworkHelperIngressBroker()
            let restartedDispatcher = NetworkHelperDispatcher(
                store: store,
                ingressBroker: restartedBroker
            )
            let recovered = try dispatch(
                restartedDispatcher,
                NetworkHelperRequest(
                    operation: .status,
                    identity: activeIdentity
                )
            )
            XCTAssertEqual(recovered.status?.ingressSHA256, digest)
            XCTAssertEqual(recovered.status?.ingressActive, true)
            XCTAssertEqual(restartedBroker.sha256(identity: activeIdentity), digest)

            _ = try dispatch(
                restartedDispatcher,
                NetworkHelperRequest(
                    operation: .remove,
                    identity: activeIdentity
                )
            )
            XCTAssertFalse(restartedBroker.hasActiveBindings)
        }
    }

    func testRuntimeDirectorySocketModesAndSameUIDAuthentication() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runtimeURL = parent.appendingPathComponent(
            "runtime",
            isDirectory: true
        )
        let runtime =
            try ContainerizationHelperRuntimeDirectory.prepare(
                at: runtimeURL,
                socketName: "network-helper.sock"
            )
        XCTAssertEqual(mode(at: runtimeURL), 0o700)
        let lease = try runtime.makeListeningSocket()
        XCTAssertEqual(mode(at: runtime.socketURL), 0o600)

        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(
            socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors),
            0
        )
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }
        XCTAssertNoThrow(
            try NetworkHelperPeerSecurity.validateSameUser(
                connectionDescriptor: descriptors[0]
            )
        )
        XCTAssertThrowsError(
            try NetworkHelperPeerSecurity.validateSameUser(
                connectionDescriptor: descriptors[0],
                expectedUserID: geteuid() &+ 1
            )
        ) {
            XCTAssertEqual(
                $0 as? NetworkHelperCodeIdentityError,
                .userMismatch
            )
        }

        try lease.closeAndRemove()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: runtime.socketURL.path)
        )
    }

    func testConnectionHandlerAppliesOneBoundedCanonicalFrame() async throws {
        try await withAsyncStore { store, _ in
            var descriptors = [Int32](repeating: -1, count: 2)
            XCTAssertEqual(
                socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors),
                0
            )
            let server = descriptors[0]
            let client = descriptors[1]
            defer {
                Darwin.close(server)
                Darwin.close(client)
            }

            let request = NetworkHelperRequest(
                operation: .apply,
                identity: identity(),
                corefile: corefile()
            )
            let requestFrame = try NetworkHelperCanonicalJSON.frame(request)
            let task = Task.detached {
                try NetworkHelperConnectionHandler.handle(
                    descriptor: server,
                    dispatcher: NetworkHelperDispatcher(store: store)
                )
            }
            let written = requestFrame.withUnsafeBytes {
                Darwin.write(client, $0.baseAddress, $0.count)
            }
            XCTAssertEqual(written, requestFrame.count)
            let responseFrame = try NetworkHelperConnectionHandler.readFrame(
                descriptor: client
            )
            try await task.value

            let response = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: responseFrame
            )
            XCTAssertEqual(response.requestID, request.requestID)
            XCTAssertEqual(response.status?.disposition, .active)
            XCTAssertNil(response.error)
        }
    }

    func testConnectionHandlerRejectsFrameLargerThanEightMiB() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(
            socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors),
            0
        )
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }
        let oversizedHeader = Data([0, 128, 0, 1])
        let written = oversizedHeader.withUnsafeBytes {
            Darwin.write(descriptors[1], $0.baseAddress, $0.count)
        }
        XCTAssertEqual(written, oversizedHeader.count)
        XCTAssertThrowsError(
            try NetworkHelperConnectionHandler.readFrame(
                descriptor: descriptors[0]
            )
        ) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidFrame)
        }
    }

    private func identity(
        generation: Int = 1,
        fence: String? = nil
    ) -> NetworkHelperDNSIdentity {
        NetworkHelperDNSIdentity(
            projectUUID: projectUUID,
            dnsUUID: dnsUUID,
            generation: generation,
            fencingToken: fence ?? firstFence
        )
    }

    private func policyPlan(
        generation: Int = 1,
        dns: String = "old.example.test"
    ) throws -> NetworkPolicyPlan {
        try NetworkPolicyCompiler.compile(
            projectName: "demo",
            projectUUID: projectUUID,
            generation: generation,
            services: [(
                name: "api",
                resourceUUID: dnsUUID,
                policy: HostwrightServiceNetworkPolicy(egress: [
                    HostwrightNetworkPolicyRule(
                        protocolName: .tcp,
                        port: 443,
                        dns: dns
                    ),
                ])
            )]
        )
    }

    private func policyFlow(dns: String) -> NetworkPolicyFlow {
        NetworkPolicyFlow(
            direction: .egress,
            sourceProject: "demo",
            sourceService: "api",
            destinationProject: "external",
            destinationService: "https",
            protocolName: .tcp,
            port: 443,
            dns: dns
        )
    }

    private func hostAccessBinding()
        -> ProjectDNSHostAccessBinding
    {
        ProjectDNSHostAccessBinding(
            hostname: "host-api.internal",
            protocolName: .tcp,
            addressClass: .loopback,
            listenAddress: "192.168.64.1",
            clientCIDR: "192.168.64.0/24",
            targetAddress: "127.0.0.1",
            port: 6_508
        )
    }

    private func ingressBinding(
        port: Int = 8_443
    ) -> ProjectIngressListenerBinding {
        ProjectIngressListenerBinding(
            name: "api",
            bindAddress: "127.0.0.1",
            port: port,
            exposure: .localhost,
            routes: [ProjectIngressRouteBinding(
                hostname: "api.internal",
                pathPrefix: "/",
                methods: ["GET"],
                protocolName: .http,
                targetServiceName: "api",
                targetServiceUUIDs: [projectUUID],
                targetPort: 8_080,
                backends: [ProjectIngressBackend(
                    serviceUUID: projectUUID,
                    address: "127.0.0.1",
                    port: 8_080
                )]
            )]
        )
    }

    private func certificateBinding() -> ProjectCertificateRequestBinding {
        ProjectCertificateRequestBinding(
            name: "local",
            certificateUUID: dnsUUID,
            source: .localCA,
            renewBeforeSeconds: 3_600,
            validitySeconds: 86_400,
            statusPolicy: .ifAvailable,
            dnsNames: ["api.example.test"]
        )
    }

    private func assertReplacementFailurePreservesPrior(
        expected: NetworkHelperError,
        makeIssuer: (
            CertificateIdentityStore,
            NetworkHelperDNSIdentity,
            ProjectCertificateRequestBinding
        ) throws -> any NetworkHelperCertificateIssuer
    ) throws {
        try withStore { stateStore, _ in
            let project = UUID().uuidString.lowercased()
            let dns = UUID().uuidString.lowercased()
            let first = NetworkHelperDNSIdentity(
                projectUUID: project,
                dnsUUID: dns,
                generation: 1,
                fencingToken: UUID().uuidString.lowercased()
            )
            let second = NetworkHelperDNSIdentity(
                projectUUID: project,
                dnsUUID: dns,
                generation: 2,
                fencingToken: UUID().uuidString.lowercased()
            )
            let priorBinding = ProjectCertificateRequestBinding(
                name: "prior",
                certificateUUID: UUID().uuidString.lowercased(),
                source: .localCA,
                renewBeforeSeconds: 3_600,
                validitySeconds: 86_400,
                statusPolicy: .ifAvailable,
                dnsNames: ["api.example.test"]
            )
            let replacementBinding =
                ProjectCertificateRequestBinding(
                    name: "replacement",
                    certificateUUID:
                        UUID().uuidString.lowercased(),
                    source: .provider,
                    issuer: "external",
                    renewBeforeSeconds: 3_600,
                    validitySeconds: 86_400,
                    statusPolicy: .ifAvailable,
                    dnsNames: ["api.example.test"]
                )
            let identityStore = CertificateIdentityStore()
            let issuer = try makeIssuer(
                identityStore,
                second,
                replacementBinding
            )
            let coordinator = NetworkHelperCertificateCoordinator(
                identityStore: identityStore,
                certificateIssuers: [issuer],
                now: { Self.certificateTestNow }
            )

            _ = try stateStore.apply(
                identity: first,
                corefile: corefile(),
                certificateBindings: [priorBinding]
            )
            let priorActivation = try coordinator.apply(
                identity: first,
                bindings: [priorBinding]
            )
            let priorEvidence = try XCTUnwrap(
                stateStore.recordCertificateEvidence(
                    identity: first,
                    certificates: priorActivation.evidence
                )
            )
            defer {
                try? coordinator.cleanup(
                    identity: first,
                    evidence: priorEvidence
                )
            }
            let priorFingerprint = try XCTUnwrap(
                priorActivation.identities["prior"]?
                    .metadata.certificateSHA256
            )

            _ = try stateStore.apply(
                identity: second,
                corefile: corefile(ttl: 10),
                certificateBindings: [replacementBinding],
                predecessorFencingToken: first.fencingToken
            )
            XCTAssertThrowsError(
                try coordinator.applyCertificateReplacement(
                    identity: second,
                    bindings: [replacementBinding],
                    stateStore: stateStore,
                    overlapEvidence: priorEvidence
                )
            ) {
                XCTAssertEqual($0 as? NetworkHelperError, expected)
            }
            XCTAssertEqual(
                coordinator.activation(identity: first)?
                    .identities["prior"]?
                    .metadata.certificateSHA256,
                priorFingerprint
            )
            XCTAssertNil(coordinator.activation(identity: second))
            XCTAssertNil(
                try stateStore.pendingCertificateReplacement(
                    identity: second
                )
            )
            XCTAssertEqual(
                try stateStore.retiredCertificateEvidence(
                    identity: second
                ),
                priorEvidence
            )
            let replacementScope = try CertificateIdentityScope(
                projectUUID: project,
                certificateUUID:
                    replacementBinding.certificateUUID,
                generation: second.generation
            )
            XCTAssertThrowsError(
                try identityStore.managedIdentityEvidence(
                    scope: replacementScope,
                    now: Self.certificateTestNow
                )
            ) {
                XCTAssertEqual(
                    $0 as? CertificateIdentityStoreError,
                    .notFound
                )
            }
        }
    }

    private func certificateEvidence(
        binding: ProjectCertificateRequestBinding,
        leaf: String = String(repeating: "a", count: 64),
        issuer: String = String(repeating: "b", count: 64)
    ) -> NetworkHelperCertificateEvidence {
        NetworkHelperCertificateEvidence(
            name: binding.name,
            certificateUUID: binding.certificateUUID,
            source: binding.source,
            certificateSHA256: leaf,
            issuerCertificateSHA256: issuer,
            dnsNames: binding.dnsNames,
            notValidBefore: Date(timeIntervalSince1970: 1_000),
            notValidAfter: Date(timeIntervalSince1970: 100_000),
            revocationStatus:
                CertificateRevocationStatus.unavailable.rawValue
        )
    }

    private func dispatch(
        _ dispatcher: NetworkHelperDispatcher,
        _ request: NetworkHelperRequest
    ) throws -> NetworkHelperResponse {
        try NetworkHelperCanonicalJSON.decodeFrame(
            NetworkHelperResponse.self,
            from: dispatcher.dispatch(
                frame: try NetworkHelperCanonicalJSON.frame(request)
            )
        )
    }

    private func corefile(ttl: Int = 5) -> String {
        """
        \(projectUUID).hostwright.internal {
            cache \(ttl)
            hosts {
                192.0.2.10 api.\(projectUUID).hostwright.internal
                fallthrough
            }
        }
        """
    }

    private func generationURL(root: URL, generation: Int) -> URL {
        root
            .appendingPathComponent(projectUUID)
            .appendingPathComponent(dnsUUID)
            .appendingPathComponent("generations")
            .appendingPathComponent(String(generation))
    }

    private func withStore(
        _ body: (
            NetworkHelperStateStore,
            URL
        ) throws -> Void
    ) throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("state", isDirectory: true)
        let store = try NetworkHelperStateStore(rootURL: root)
        try body(store, root)
    }

    private func withAsyncStore(
        _ body: (
            NetworkHelperStateStore,
            URL
        ) async throws -> Void
    ) async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("state", isDirectory: true)
        let store = try NetworkHelperStateStore(rootURL: root)
        try await body(store, root)
    }

    private func makePrivateParent() throws -> URL {
        let identifier = UUID().uuidString
            .lowercased()
            .prefix(8)
        let url = URL(
            fileURLWithPath: "/private/tmp/hwnh-\(identifier)",
            isDirectory: true
        )
        XCTAssertEqual(mkdir(url.path, 0o700), 0)
        XCTAssertEqual(chmod(url.path, 0o700), 0)
        return url
    }

    private func mode(at url: URL) -> mode_t {
        var metadata = stat()
        XCTAssertEqual(lstat(url.path, &metadata), 0)
        return metadata.st_mode & mode_t(0o7777)
    }

    private func readAll(descriptor: Int32) throws -> Data {
        defer { Darwin.close(descriptor) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = Darwin.read(
                descriptor,
                &buffer,
                buffer.count
            )
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw NetworkHelperError.ioFailure
            }
            if count == 0 { return result }
            result.append(contentsOf: buffer[0..<count])
        }
    }
}

private func firstActiveNonLoopbackIPv4() -> String? {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0 else { return nil }
    defer { freeifaddrs(pointer) }
    var current = pointer
    while let item = current {
        defer { current = item.pointee.ifa_next }
        guard item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
              item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
              let address = item.pointee.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET) else {
            continue
        }
        var value = UnsafeRawPointer(address)
            .assumingMemoryBound(to: sockaddr_in.self)
            .pointee.sin_addr
        var buffer = [CChar](
            repeating: 0,
            count: Int(INET_ADDRSTRLEN)
        )
        guard inet_ntop(
            AF_INET,
            &value,
            &buffer,
            socklen_t(buffer.count)
        ) != nil else {
            continue
        }
        return buffer.withUnsafeBufferPointer { bytes in
            String(
                decoding: bytes
                    .prefix { $0 != 0 }
                    .map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        }
    }
    return nil
}

private func makeLoopbackTCPServer() throws
    -> (descriptor: Int32, port: Int)
{
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    var succeeded = false
    defer {
        if !succeeded { Darwin.close(descriptor) }
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard "127.0.0.1".withCString({
        inet_pton(AF_INET, $0, &address.sin_addr)
    }) == 1 else {
        throw NetworkHelperError.bindingUnavailable
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    guard bound == 0, Darwin.listen(descriptor, 4) == 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let loaded = withUnsafeMutablePointer(to: &actual) {
        pointer in
        pointer.withMemoryRebound(
            to: sockaddr.self,
            capacity: 1
        ) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard loaded == 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    succeeded = true
    return (
        descriptor,
        Int(in_port_t(bigEndian: actual.sin_port))
    )
}

private func makeLoopbackUDPServer() throws
    -> (descriptor: Int32, port: Int)
{
    let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
    guard descriptor >= 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    var succeeded = false
    defer {
        if !succeeded { Darwin.close(descriptor) }
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard "127.0.0.1".withCString({
        inet_pton(AF_INET, $0, &address.sin_addr)
    }) == 1 else {
        throw NetworkHelperError.bindingUnavailable
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    guard bound == 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let loaded = withUnsafeMutablePointer(to: &actual) {
        pointer in
        pointer.withMemoryRebound(
            to: sockaddr.self,
            capacity: 1
        ) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard loaded == 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    succeeded = true
    return (
        descriptor,
        Int(in_port_t(bigEndian: actual.sin_port))
    )
}

private func connectTCP(address: String, port: Int) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    var succeeded = false
    defer {
        if !succeeded { Darwin.close(descriptor) }
    }
    var target = sockaddr_in()
    target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    target.sin_family = sa_family_t(AF_INET)
    target.sin_port = in_port_t(port).bigEndian
    guard address.withCString({
        inet_pton(AF_INET, $0, &target.sin_addr)
    }) == 1 else {
        throw NetworkHelperError.bindingUnavailable
    }
    let result = withUnsafePointer(to: &target) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    guard result == 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    succeeded = true
    return descriptor
}

private func udpRoundTrip(
    address: String,
    port: Int,
    payload: Data
) throws -> Data {
    let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
    guard descriptor >= 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    defer { Darwin.close(descriptor) }
    var target = sockaddr_in()
    target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    target.sin_family = sa_family_t(AF_INET)
    target.sin_port = in_port_t(port).bigEndian
    guard address.withCString({
        inet_pton(AF_INET, $0, &target.sin_addr)
    }) == 1 else {
        throw NetworkHelperError.bindingUnavailable
    }
    let sent = payload.withUnsafeBytes { bytes in
        withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.sendto(
                    descriptor,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    $0,
                    socklen_t(
                        MemoryLayout<sockaddr_in>.size
                    )
                )
            }
        }
    }
    guard sent == payload.count,
          waitReadable(descriptor, milliseconds: 5_000) else {
        throw NetworkHelperError.bindingUnavailable
    }
    var response = [UInt8](repeating: 0, count: 64 * 1_024)
    let count = Darwin.recv(
        descriptor,
        &response,
        response.count,
        0
    )
    guard count > 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    return Data(response[0..<count])
}

private func waitReadable(
    _ descriptor: Int32,
    milliseconds: Int32
) -> Bool {
    var value = pollfd(
        fd: descriptor,
        events: Int16(POLLIN),
        revents: 0
    )
    return Darwin.poll(&value, 1, milliseconds) > 0
        && value.revents & Int16(POLLIN | POLLHUP) != 0
}
