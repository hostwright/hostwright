import Foundation
import Security
import XCTest
@testable import HostwrightNetworkHelperCore

final class CertificateIdentityStoreTests: XCTestCase {
    private let projectUUID = "11111111-1111-4111-8111-111111111111"
    private let certificateUUID =
        "22222222-2222-4222-8222-222222222222"

    func testScopeRequiresCanonicalUUIDsAndPositiveGeneration() throws {
        let scope = try makeScope(generation: 7)

        XCTAssertEqual(scope.projectUUID, projectUUID)
        XCTAssertEqual(scope.certificateUUID, certificateUUID)
        XCTAssertEqual(scope.generation, 7)
        XCTAssertEqual(
            scope.keychainLocator,
            "\(projectUUID).\(certificateUUID).g7"
        )

        XCTAssertThrowsError(
            try CertificateIdentityScope(
                projectUUID:
                    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                    .uppercased(),
                certificateUUID: certificateUUID,
                generation: 1
            )
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .invalidScope
            )
        }
        XCTAssertThrowsError(
            try CertificateIdentityScope(
                projectUUID: projectUUID,
                certificateUUID: certificateUUID,
                generation: 0
            )
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .invalidScope
            )
        }
    }

    func testFingerprintsMustAlreadyBeLowercaseCanonicalSHA256()
        throws
    {
        let lowercase = String(repeating: "ab", count: 32)
        XCTAssertEqual(
            try CertificateIdentityStore.canonicalFingerprint(lowercase),
            lowercase
        )

        for invalid in [
            lowercase.uppercased(),
            String(repeating: "a", count: 63),
            String(repeating: "z", count: 64),
        ] {
            XCTAssertThrowsError(
                try CertificateIdentityStore.canonicalFingerprint(invalid)
            ) {
                XCTAssertEqual(
                    $0 as? CertificateIdentityStoreError,
                    .invalidFingerprint
                )
            }
        }
    }

    func testImportedAndManagedResolutionRejectUppercaseBeforeKeychainAccess()
        throws
    {
        let store = CertificateIdentityStore()
        let scope = try makeScope()
        let uppercase = String(repeating: "AB", count: 32)
        let lowercase = String(repeating: "ab", count: 32)

        XCTAssertThrowsError(
            try store.resolveImportedIdentity(
                certificateSHA256: uppercase
            )
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .invalidFingerprint
            )
        }
        XCTAssertThrowsError(
            try store.resolveManagedIdentity(
                scope: scope,
                expectedLeafSHA256: uppercase,
                expectedIssuerSHA256: lowercase
            )
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .invalidFingerprint
            )
        }
        XCTAssertThrowsError(
            try store.cleanupManagedIdentity(
                scope: scope,
                expectedLeafSHA256: lowercase,
                expectedIssuerSHA256: uppercase
            )
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .invalidFingerprint
            )
        }
    }

    func testDNSNamesAreCanonicalizedAndSortedForExactComparison()
        throws
    {
        XCTAssertEqual(
            try CertificateIdentityStore.canonicalDNSNames([
                "Z.EXAMPLE.test",
                "api.example.test",
            ]),
            ["api.example.test", "z.example.test"]
        )
        XCTAssertThrowsError(
            try CertificateIdentityStore.canonicalDNSNames([
                "api.example.test",
                "API.EXAMPLE.TEST",
            ])
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .invalidDNSName
            )
        }
        XCTAssertThrowsError(
            try CertificateIdentityStore.canonicalDNSNames([
                "bad name"
            ])
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .invalidDNSName
            )
        }
    }

    func testValidityAllowsManifestMaximumAndRejectsOutsideBounds()
        throws
    {
        XCTAssertNoThrow(
            try CertificateIdentityStore.validateValidity(
                CertificateIdentityStore.maximumLeafValidity
            )
        )
        XCTAssertThrowsError(
            try CertificateIdentityStore.validateValidity(0)
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .invalidValidity
            )
        }
        XCTAssertThrowsError(
            try CertificateIdentityStore.validateValidity(
                CertificateIdentityStore.maximumLeafValidity + 1
            )
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .invalidValidity
            )
        }
    }

    func testKeychainStatusesMapToDistinctSafeErrors() {
        XCTAssertEqual(
            CertificateIdentityStore.mapKeychainStatus(
                errSecItemNotFound
            ),
            .notFound
        )
        XCTAssertEqual(
            CertificateIdentityStore.mapKeychainStatus(
                errSecDuplicateItem
            ),
            .duplicate
        )
        XCTAssertEqual(
            CertificateIdentityStore.mapKeychainStatus(
                errSecInteractionNotAllowed
            ),
            .keychainLocked
        )
        XCTAssertEqual(
            CertificateIdentityStore.mapKeychainStatus(errSecAuthFailed),
            .accessDenied
        )
        XCTAssertEqual(
            CertificateIdentityStore.mapKeychainStatus(errSecUserCanceled),
            .cancelled
        )
    }

    func testInvalidGenerationInputsDoNotReachKeychain() throws {
        let store = CertificateIdentityStore()
        let scope = try makeScope()

        XCTAssertThrowsError(
            try store.generateLocalIdentity(scope: scope, dnsNames: [])
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .invalidDNSName
            )
        }
        XCTAssertThrowsError(
            try store.generateLocalIdentity(
                scope: scope,
                dnsNames: ["service.hostwright.test"],
                validity:
                    CertificateIdentityStore.maximumLeafValidity + 1
            )
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .invalidValidity
            )
        }
    }

    func testMetadataDoesNotInventRevocationStatus() {
        let metadata = CertificateIdentityMetadata(
            certificateSHA256: String(repeating: "a", count: 64),
            dnsNames: ["service.hostwright.test"],
            notValidBefore: .distantPast,
            notValidAfter: .distantFuture
        )

        XCTAssertEqual(metadata.revocationStatus, .unavailable)
        XCTAssertNil(metadata.issuerCertificateSHA256)
    }

    func testManagedMetadataCarriesIssuerFingerprintEvidence() {
        let issuerSHA256 = String(repeating: "b", count: 64)
        let metadata = CertificateIdentityMetadata(
            certificateSHA256: String(repeating: "a", count: 64),
            dnsNames: ["service.hostwright.test"],
            notValidBefore: .distantPast,
            notValidAfter: .distantFuture,
            issuerCertificateSHA256: issuerSHA256
        )

        XCTAssertEqual(
            metadata.issuerCertificateSHA256,
            issuerSHA256
        )
    }

    func testManagedEvidenceLookupForAbsentExactScopeIsNoninteractive()
        throws
    {
        let store = CertificateIdentityStore()
        let absentScope = try CertificateIdentityScope(
            projectUUID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            certificateUUID: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            generation: Int.max
        )

        XCTAssertThrowsError(
            try store.managedIdentityEvidence(scope: absentScope)
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .notFound
            )
        }
    }

    func testManagedIdentityGenerateResolveAndExactCleanup() throws {
        let store = CertificateIdentityStore()
        let scope = try CertificateIdentityScope(
            projectUUID: UUID(),
            certificateUUID: UUID(),
            generation: 1
        )
        var fingerprints: (leaf: String, issuer: String)?
        defer {
            if let fingerprints {
                try? store.cleanupManagedIdentity(
                    scope: scope,
                    expectedLeafSHA256: fingerprints.leaf,
                    expectedIssuerSHA256: fingerprints.issuer
                )
            }
        }

        let generated = try store.generateLocalIdentity(
            scope: scope,
            dnsNames: ["api.internal"],
            validity: 3_600
        )
        let issuerSHA256 = try XCTUnwrap(
            generated.metadata.issuerCertificateSHA256
        )
        fingerprints = (
            generated.metadata.certificateSHA256,
            issuerSHA256
        )
        var privateKey: SecKey?
        XCTAssertEqual(
            SecIdentityCopyPrivateKey(generated.identity, &privateKey),
            errSecSuccess
        )
        var exportError: Unmanaged<CFError>?
        let exportedPrivateKey = SecKeyCopyExternalRepresentation(
            try XCTUnwrap(privateKey),
            &exportError
        )
        XCTAssertNil(exportedPrivateKey)
        XCTAssertNotNil(exportError?.takeRetainedValue())

        let message = Data("hostwright identity proof".utf8)
        var signingError: Unmanaged<CFError>?
        let signature = try XCTUnwrap(
            SecKeyCreateSignature(
                try XCTUnwrap(privateKey),
                .ecdsaSignatureMessageX962SHA256,
                message as CFData,
                &signingError
            ) as Data?
        )
        XCTAssertNil(signingError)
        let publicKey = try XCTUnwrap(
            SecKeyCopyPublicKey(try XCTUnwrap(privateKey))
        )
        var verificationError: Unmanaged<CFError>?
        XCTAssertTrue(
            SecKeyVerifySignature(
                publicKey,
                .ecdsaSignatureMessageX962SHA256,
                message as CFData,
                signature as CFData,
                &verificationError
            )
        )
        XCTAssertNil(verificationError)

        let recovered = try store.managedIdentityEvidence(scope: scope)
        XCTAssertEqual(
            recovered.handle.metadata.certificateSHA256,
            generated.metadata.certificateSHA256
        )
        XCTAssertEqual(
            recovered.issuerCertificateSHA256,
            issuerSHA256
        )
        XCTAssertEqual(recovered.handle.certificateChain.count, 1)

        try store.cleanupManagedIdentity(
            scope: scope,
            expectedLeafSHA256: generated.metadata.certificateSHA256,
            expectedIssuerSHA256: issuerSHA256
        )
        fingerprints = nil
        XCTAssertThrowsError(
            try store.managedIdentityEvidence(scope: scope)
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .notFound
            )
        }
    }

    func testPersistentRefRestart() throws {
        let store = CertificateIdentityStore()
        let scope = try CertificateIdentityScope(
            projectUUID: UUID(), certificateUUID: UUID(), generation: 1
        )
        let generated = try store.generateLocalIdentity(
            scope: scope, dnsNames: ["api.internal"], validity: 3_600
        )
        let issuer = try XCTUnwrap(generated.metadata.issuerCertificateSHA256)
        defer {
            try? store.cleanupManagedIdentity(
                scope: scope,
                expectedLeafSHA256: generated.metadata.certificateSHA256,
                expectedIssuerSHA256: issuer
            )
        }
        let references = try XCTUnwrap(generated.persistentReferences)
        let recovered = try store.resolveManagedIdentity(
            scope: scope,
            persistentReferences: references,
            expectedLeafSHA256: generated.metadata.certificateSHA256,
            expectedIssuerSHA256: issuer
        )
        XCTAssertEqual(
            recovered.metadata.certificateSHA256,
            generated.metadata.certificateSHA256
        )
    }

    func testManagedCleanupRetriesAfterLeafCertificateWasDeleted()
        throws
    {
        let store = CertificateIdentityStore()
        let scope = try CertificateIdentityScope(
            projectUUID: UUID(),
            certificateUUID: UUID(),
            generation: 1
        )
        defer {
            deleteManagedArtifacts(scope: scope)
        }
        let generated = try store.generateLocalIdentity(
            scope: scope,
            dnsNames: ["partial-certificate.internal"],
            validity: 3_600
        )
        let issuerSHA256 = try XCTUnwrap(
            generated.metadata.issuerCertificateSHA256
        )

        XCTAssertEqual(
            SecItemDelete(
                managedCertificateQuery(scope: scope, role: "leaf")
                    as CFDictionary
            ),
            errSecSuccess
        )
        try store.cleanupManagedIdentity(
            scope: scope,
            expectedLeafSHA256: generated.metadata.certificateSHA256,
            expectedIssuerSHA256: issuerSHA256
        )
        try store.cleanupManagedIdentity(
            scope: scope,
            expectedLeafSHA256: generated.metadata.certificateSHA256,
            expectedIssuerSHA256: issuerSHA256
        )
        assertManagedArtifactsAbsent(scope: scope)
    }

    func testManagedCleanupRetriesAfterLeafKeyWasDeletedAndFailsClosed()
        throws
    {
        let store = CertificateIdentityStore()
        let scope = try CertificateIdentityScope(
            projectUUID: UUID(),
            certificateUUID: UUID(),
            generation: 1
        )
        defer {
            deleteManagedArtifacts(scope: scope)
        }
        let generated = try store.generateLocalIdentity(
            scope: scope,
            dnsNames: ["partial-key.internal"],
            validity: 3_600
        )
        let issuerSHA256 = try XCTUnwrap(
            generated.metadata.issuerCertificateSHA256
        )

        XCTAssertEqual(
            SecItemDelete(
                managedKeyQuery(scope: scope, role: "leaf")
                    as CFDictionary
            ),
            errSecSuccess
        )
        XCTAssertThrowsError(
            try store.cleanupManagedIdentity(
                scope: scope,
                expectedLeafSHA256: String(repeating: "0", count: 64),
                expectedIssuerSHA256: issuerSHA256
            )
        ) {
            XCTAssertEqual(
                $0 as? CertificateIdentityStoreError,
                .tampered
            )
        }
        XCTAssertEqual(
            managedItemStatus(
                managedCertificateQuery(scope: scope, role: "leaf")
            ),
            errSecSuccess
        )
        XCTAssertEqual(
            managedItemStatus(
                managedCertificateQuery(scope: scope, role: "issuer")
            ),
            errSecSuccess
        )
        XCTAssertEqual(
            managedItemStatus(
                managedKeyQuery(scope: scope, role: "issuer")
            ),
            errSecSuccess
        )

        try store.cleanupManagedIdentity(
            scope: scope,
            expectedLeafSHA256: generated.metadata.certificateSHA256,
            expectedIssuerSHA256: issuerSHA256
        )
        try store.cleanupManagedIdentity(
            scope: scope,
            expectedLeafSHA256: generated.metadata.certificateSHA256,
            expectedIssuerSHA256: issuerSHA256
        )
        assertManagedArtifactsAbsent(scope: scope)
    }

    func testImportedIdentityResolvesExactFingerprintWithoutTakingOwnership()
        throws
    {
        let store = CertificateIdentityStore()
        let scope = try CertificateIdentityScope(
            projectUUID: UUID(),
            certificateUUID: UUID(),
            generation: 1
        )
        var fingerprints: (leaf: String, issuer: String)?
        defer {
            if let fingerprints {
                try? store.cleanupManagedIdentity(
                    scope: scope,
                    expectedLeafSHA256: fingerprints.leaf,
                    expectedIssuerSHA256: fingerprints.issuer
                )
            }
        }

        let generated = try store.generateLocalIdentity(
            scope: scope,
            dnsNames: ["imported.internal"],
            validity: 3_600
        )
        fingerprints = (
            generated.metadata.certificateSHA256,
            try XCTUnwrap(
                generated.metadata.issuerCertificateSHA256
            )
        )

        let imported = try store.resolveImportedIdentity(
            certificateSHA256:
                generated.metadata.certificateSHA256
        )
        XCTAssertEqual(
            imported.metadata.certificateSHA256,
            generated.metadata.certificateSHA256
        )
        XCTAssertNil(imported.managedScope)
        XCTAssertNoThrow(
            try store.managedIdentityEvidence(scope: scope)
        )
    }

    private func managedKeyQuery(
        scope: CertificateIdentityScope,
        role: String
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: Data(
                "\(CertificateIdentityStore.applicationTagPrefix)."
                    .appending(scope.keychainLocator)
                    .appending(".\(role)")
                    .utf8
            ),
            kSecAttrLabel:
                "Hostwright Certificate Identity v1 "
                + "\(scope.keychainLocator) \(role)",
            kSecAttrSynchronizable: false,
        ]
    }

    private func managedCertificateQuery(
        scope: CertificateIdentityScope,
        role: String
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel:
                "Hostwright Certificate Identity v1 "
                + "\(scope.keychainLocator) \(role)",
        ]
    }

    private func managedItemStatus(
        _ baseQuery: [CFString: Any]
    ) -> OSStatus {
        var query = baseQuery
        query[kSecReturnRef] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result)
    }

    private func assertManagedArtifactsAbsent(
        scope: CertificateIdentityScope,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for role in ["issuer", "leaf"] {
            XCTAssertEqual(
                managedItemStatus(
                    managedCertificateQuery(scope: scope, role: role)
                ),
                errSecItemNotFound,
                file: file,
                line: line
            )
            XCTAssertEqual(
                managedItemStatus(
                    managedKeyQuery(scope: scope, role: role)
                ),
                errSecItemNotFound,
                file: file,
                line: line
            )
        }
    }

    private func deleteManagedArtifacts(
        scope: CertificateIdentityScope
    ) {
        for role in ["issuer", "leaf"] {
            _ = SecItemDelete(
                managedCertificateQuery(scope: scope, role: role)
                    as CFDictionary
            )
            _ = SecItemDelete(
                managedKeyQuery(scope: scope, role: role)
                    as CFDictionary
            )
        }
    }

    private func makeScope(
        generation: Int = 1
    ) throws -> CertificateIdentityScope {
        try CertificateIdentityScope(
            projectUUID: projectUUID,
            certificateUUID: certificateUUID,
            generation: generation
        )
    }
}
