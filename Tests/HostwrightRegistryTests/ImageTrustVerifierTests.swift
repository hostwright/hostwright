import CryptoKit
import Darwin
import Foundation
import HostwrightCore
@testable import HostwrightRegistry
import XCTest

final class ImageTrustVerifierTests: XCTestCase {
    func testThresholdCountsDistinctActiveAuthoritiesAndCleansBundleFiles() throws {
        let subject = Data(#"{"schemaVersion":2}"#.utf8)
        let subjectDigest = digest(subject)
        let bundleA = try bundle(signature: "a", signedContent: subject)
        let bundleB = try bundle(signature: "b", signedContent: subject)
        let unrelatedBundle = try bundle(
            signature: "ignored",
            signedContent: Data("different-subject".utf8)
        )
        let keyA = try materialFile(contents: "a")
        let keyB = try materialFile(contents: "b")
        let keyC = try materialFile(contents: "c")
        defer {
            try? FileManager.default.removeItem(atPath: keyA)
            try? FileManager.default.removeItem(atPath: keyB)
            try? FileManager.default.removeItem(atPath: keyC)
        }
        let recorder = CommandRecorder()
        let verifier = try CosignImageTrustVerifier(
            executablePath: "/usr/bin/true"
        ) { request, _ in
            recorder.record(request)
            if request.arguments == ["version", "--json"] {
                return success(
                    #"{"gitVersion":"v3.1.2","platform":"darwin/arm64"}"#
                )
            }
            let bundleIndex = try XCTUnwrap(
                request.arguments.firstIndex(of: "--bundle")
            )
            let keyIndex = try XCTUnwrap(
                request.arguments.firstIndex(of: "--key")
            )
            let payload = try Data(
                contentsOf: URL(
                    fileURLWithPath: request.arguments[bundleIndex + 1]
                )
            )
            let signature = (
                try JSONSerialization.jsonObject(with: payload)
                    as? [String: Any]
            )?["messageSignature"] as? [String: Any]
            let expected = try String(
                contentsOfFile: request.arguments[keyIndex + 1],
                encoding: .utf8
            )
            return signature?["signature"] as? String == expected
                ? success("Verified OK")
                : failure()
        }
        let policy = try ImageTrustVerificationPolicy(
            threshold: 2,
            trustedRootPath: nil,
            authorities: [
                try ImageTrustAuthority(
                    id: "release-a",
                    kind: .keyed,
                    publicKeyPath: keyA
                ),
                try ImageTrustAuthority(
                    id: "release-b",
                    kind: .keyed,
                    publicKeyPath: keyB
                ),
                try ImageTrustAuthority(
                    id: "revoked",
                    kind: .keyed,
                    publicKeyPath: keyC,
                    revokedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )

        let result = try verifier.verify(
            subjectManifest: subject,
            subjectDigest: subjectDigest,
            bundles: [bundleA, unrelatedBundle, bundleB],
            policy: policy,
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(result.matchedAuthorityIDs, ["release-a", "release-b"])
        XCTAssertEqual(result.threshold, 2)
        XCTAssertEqual(result.verifierVersion, "v3.1.2")
        XCTAssertEqual(result.verifierSHA256.count, 64)
        XCTAssertNil(result.trustedRootSHA256)
        XCTAssertEqual(
            result.bundleDigests,
            [bundleA.digest, bundleB.digest].sorted()
        )
        for path in recorder.bundlePaths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
        XCTAssertTrue(
            recorder.requests
                .filter { $0.arguments.first == "verify-blob" }
                .allSatisfy {
                    $0.standardInput == subject &&
                        $0.environment == SecureSubprocessEnvironment.minimal &&
                        !$0.arguments.contains(where: {
                            $0.contains("password") || $0.contains("token")
                        })
                }
        )
    }

    func testThresholdFailureIsStructuredAndDoesNotAdoptExpiredAuthority() throws {
        let subject = Data("subject".utf8)
        let key = try materialFile(contents: "expired")
        defer { try? FileManager.default.removeItem(atPath: key) }
        let verifier = try CosignImageTrustVerifier(
            executablePath: "/usr/bin/true"
        ) { request, _ in
            request.arguments == ["version", "--json"]
                ? success(
                    #"{"gitVersion":"v3.0.6","platform":"darwin/arm64"}"#
                )
                : failure()
        }
        let policy = try ImageTrustVerificationPolicy(
            threshold: 1,
            trustedRootPath: nil,
            authorities: [
                try ImageTrustAuthority(
                    id: "expired",
                    kind: .keyed,
                    publicKeyPath: key,
                    notAfter: Date(timeIntervalSince1970: 10)
                )
            ]
        )

        let result = try verifier.verify(
            subjectManifest: subject,
            subjectDigest: digest(subject),
            bundles: [try bundle(signature: "x")],
            policy: policy,
            at: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(result.outcome, .thresholdNotMet)
        XCTAssertEqual(result.matchedAuthorityIDs, [])
    }

    func testRejectsSubjectDigestMismatchBeforeInvokingVerifier() throws {
        let recorder = CommandRecorder()
        let verifier = try CosignImageTrustVerifier(
            executablePath: "/usr/bin/true"
        ) { request, _ in
            recorder.record(request)
            return success("")
        }
        let policy = try ImageTrustVerificationPolicy(
            threshold: 1,
            trustedRootPath: nil,
            authorities: [
                try ImageTrustAuthority(
                    id: "release",
                    kind: .keyed,
                    publicKeyPath: "/tmp/key.pub"
                )
            ]
        )

        XCTAssertThrowsError(
            try verifier.verify(
                subjectManifest: Data("subject".utf8),
                subjectDigest:
                    "sha256:\(String(repeating: "0", count: 64))",
                bundles: [try bundle(signature: "x")],
                policy: policy
            )
        ) {
            XCTAssertEqual($0 as? ImageTrustVerifierError, .invalidSubject)
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testRejectsUnsupportedOrMalformedBundleAndVerifierContracts() throws {
        let payload = Data(
            #"{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json","mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json","messageSignature":{},"verificationMaterial":{}}"#.utf8
        )
        XCTAssertThrowsError(
            try SigstoreBundleEvidence(
                digest: digest(payload),
                payload: payload
            )
        ) {
            XCTAssertEqual($0 as? ImageTrustVerifierError, .invalidBundle)
        }

        let subject = Data("subject".utf8)
        let verifier = try CosignImageTrustVerifier(
            executablePath: "/usr/bin/true"
        ) { request, _ in
            request.arguments == ["version", "--json"]
                ? success(
                    #"{"gitVersion":"v3.0.3","platform":"darwin/arm64"}"#
                )
                : success("Verified OK")
        }
        let policy = try ImageTrustVerificationPolicy(
            threshold: 1,
            trustedRootPath: nil,
            authorities: [
                try ImageTrustAuthority(
                    id: "release",
                    kind: .keyed,
                    publicKeyPath: "/tmp/key.pub"
                )
            ]
        )
        XCTAssertThrowsError(
            try verifier.verify(
                subjectManifest: subject,
                subjectDigest: digest(subject),
                bundles: [try bundle(signature: "x")],
                policy: policy
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageTrustVerifierError,
                .unsupportedVerifier
            )
        }
    }

    func testKeylessPolicyRequiresExplicitTrustedRootAndExactIdentity() throws {
        XCTAssertThrowsError(
            try ImageTrustVerificationPolicy(
                threshold: 1,
                trustedRootPath: nil,
                authorities: [
                    try ImageTrustAuthority(
                        id: "release",
                        kind: .keyless,
                        issuer: "https://accounts.google.com",
                        identity: "release@example.com"
                    )
                ]
            )
        ) {
            XCTAssertEqual($0 as? ImageTrustVerifierError, .invalidPolicy)
        }
        XCTAssertThrowsError(
            try ImageTrustAuthority(
                id: "release",
                kind: .keyless,
                issuer: "http://accounts.google.com",
                identity: "release@example.com"
            )
        ) {
            XCTAssertEqual($0 as? ImageTrustVerifierError, .invalidPolicy)
        }
    }

    func testExtractsOnlyExactV03BundleBlobFromVerifiedReferrerGraph() throws {
        let signedContent = Data("subject".utf8)
        let bundle = try bundle(
            signature: "release",
            signedContent: signedContent
        )
        let bundleDigest = try OCIContentDigest(bundle.digest)
        let bundleDescriptor = try OCIContentDescriptor(
            mediaType: SigstoreBundleEvidence.mediaType,
            digest: bundleDigest,
            size: bundle.payload.count
        )
        let rootPayload = Data("root".utf8)
        let rootDigest = try OCIContentDigest.sha256(of: rootPayload)
        let rootDescriptor = try OCIReferrerDescriptor(
            mediaType: OCIReferrerDescriptor.manifestMediaType,
            digest: rootDigest,
            size: rootPayload.count,
            artifactType: try OCIArtifactType(
                SigstoreBundleEvidence.mediaType
            ),
            annotations: [:]
        )
        let subjectDigest = try OCIContentDigest.sha256(of: signedContent)
        let discovery = OCIReferrerDiscoveryResult(
            endpoint: try RegistryEndpoint("https://registry.example.com"),
            repository: try OCIRepositoryName("team/app"),
            subjectDigest: subjectDigest,
            artifactType: nil,
            mode: .native,
            serverFilterApplied: false,
            pageCount: 1,
            descriptors: [rootDescriptor],
            etag: nil
        )
        let graph = try OCIReferrerGraph(
            discovery: discovery,
            verifiedReferrers: [rootDescriptor],
            objects: [
                try OCIReferrerFetchedObject(
                    digest: rootDigest,
                    mediaType: OCIReferrerDescriptor.manifestMediaType,
                    size: rootPayload.count,
                    kind: .manifest,
                    payload: rootPayload,
                    childDescriptors: [bundleDescriptor]
                ),
                try OCIReferrerFetchedObject(
                    digest: bundleDigest,
                    mediaType: SigstoreBundleEvidence.mediaType,
                    size: bundle.payload.count,
                    kind: .blob,
                    payload: bundle.payload,
                    childDescriptors: []
                )
            ]
        )

        XCTAssertEqual(
            try ImageTrustEvidenceExtractor.bundles(from: graph),
            [bundle]
        )
    }

    private func bundle(
        signature: String,
        signedContent: Data = Data("subject".utf8)
    ) throws -> SigstoreBundleEvidence {
        let messageDigest = Data(SHA256.hash(data: signedContent))
            .base64EncodedString()
        let payload = Data(
            """
            {"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json","messageSignature":{"messageDigest":{"algorithm":"SHA2_256","digest":"\(messageDigest)"},"signature":"\(signature)"},"verificationMaterial":{}}
            """.utf8
        )
        return try SigstoreBundleEvidence(
            digest: digest(payload),
            payload: payload
        )
    }

    private func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func materialFile(contents: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-trust-test-\(UUID().uuidString.lowercased())"
            ).path
        try Data(contents.utf8).write(
            to: URL(fileURLWithPath: path),
            options: .withoutOverwriting
        )
        XCTAssertEqual(chmod(path, S_IRUSR | S_IWUSR), 0)
        return path
    }
}

private final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SecureSubprocessRequest] = []

    var requests: [SecureSubprocessRequest] {
        lock.withLock { storage }
    }

    var bundlePaths: [String] {
        requests.compactMap { request in
            guard let index = request.arguments.firstIndex(of: "--bundle"),
                  request.arguments.indices.contains(index + 1) else {
                return nil
            }
            return request.arguments[index + 1]
        }
    }

    func record(_ request: SecureSubprocessRequest) {
        lock.withLock { storage.append(request) }
    }
}

private func success(_ output: String) -> SecureSubprocessResult {
    SecureSubprocessResult(
        exitStatus: 0,
        terminationSignal: nil,
        standardOutput: Data(output.utf8),
        standardError: Data(),
        durationMilliseconds: 1,
        standardOutputTruncated: false,
        standardErrorTruncated: false
    )
}

private func failure() -> SecureSubprocessResult {
    SecureSubprocessResult(
        exitStatus: 1,
        terminationSignal: nil,
        standardOutput: Data(),
        standardError: Data("verification failed".utf8),
        durationMilliseconds: 1,
        standardOutputTruncated: false,
        standardErrorTruncated: false
    )
}
