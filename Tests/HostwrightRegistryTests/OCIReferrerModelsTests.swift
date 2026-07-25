import Foundation
@testable import HostwrightRegistry
import XCTest

final class OCIReferrerModelsTests: XCTestCase {
    func testDigestValidationAndFallbackTagAreCanonical() throws {
        let value = "sha256:" + String(repeating: "a", count: 64)
        let digest = try OCIContentDigest(value)

        XCTAssertEqual(digest.algorithm, "sha256")
        XCTAssertEqual(digest.encoded, String(repeating: "a", count: 64))
        XCTAssertEqual(digest.canonicalValue, value)
        XCTAssertEqual(
            digest.referrersTag,
            "sha256-" + String(repeating: "a", count: 64)
        )
        XCTAssertTrue(
            try OCIContentDigest.sha256(of: Data("payload".utf8))
                .matches(Data("payload".utf8))
        )
    }

    func testOnlySHA256HasAnExactFallbackTag() throws {
        let sha256 = try OCIContentDigest(
            "sha256:" + String(repeating: "a", count: 64)
        )
        let sha512A = try OCIContentDigest(
            "sha512:" + String(repeating: "a", count: 128)
        )
        let sha512B = try OCIContentDigest(
            "sha512:" + String(repeating: "a", count: 64) +
                String(repeating: "b", count: 64)
        )

        XCTAssertEqual(sha256.exactReferrersTag, sha256.referrersTag)
        XCTAssertNil(sha512A.exactReferrersTag)
        XCTAssertNil(sha512B.exactReferrersTag)
        XCTAssertEqual(sha512A.referrersTag, sha512B.referrersTag)
    }

    func testDigestRejectsNonCanonicalOrUnsupportedValues() {
        let rejected = [
            "SHA256:" + String(repeating: "a", count: 64),
            "sha256:" + String(repeating: "A", count: 64),
            "sha256:" + String(repeating: "a", count: 63),
            "md5:" + String(repeating: "a", count: 32),
            "sha256:" + String(repeating: "a", count: 64) + "?secret=1"
        ]
        for value in rejected {
            XCTAssertThrowsError(try OCIContentDigest(value), value)
        }
    }

    func testReferrerIndexParsesBoundedOpaqueDescriptors() throws {
        let subject = "sha256:" + String(repeating: "1", count: 64)
        let first = "sha256:" + String(repeating: "2", count: 64)
        let second = "sha256:" + String(repeating: "3", count: 64)
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "mediaType": "application/vnd.oci.image.index.v1+json",
              "manifests": [
                {
                  "mediaType": "application/vnd.oci.image.manifest.v1+json",
                  "digest": "\(second)",
                  "size": 21,
                  "artifactType": "application/vnd.example.sbom.v1+json",
                  "annotations": {"org.example.kind": "opaque"}
                },
                {
                  "mediaType": "application/vnd.oci.image.manifest.v1+json",
                  "digest": "\(first)",
                  "size": 12,
                  "artifactType": "application/vnd.example.signature.v1+json"
                }
              ]
            }
            """.utf8
        )

        let index = try OCIReferrerIndex.parse(
            data,
            subjectDigest: OCIContentDigest(subject)
        )

        XCTAssertEqual(index.schemaVersion, 2)
        XCTAssertEqual(index.subjectDigest.canonicalValue, subject)
        XCTAssertEqual(
            index.descriptors.map(\.digest.canonicalValue),
            [first, second]
        )
        XCTAssertEqual(
            index.descriptors[1].annotations,
            ["org.example.kind": "opaque"]
        )
    }

    func testReferrerIndexRejectsDuplicateFieldsAndConflictingDescriptors() {
        let subject = try! OCIContentDigest(
            "sha256:" + String(repeating: "1", count: 64)
        )
        let digest = "sha256:" + String(repeating: "2", count: 64)
        let duplicateField = Data(
            """
            {"schemaVersion":2,"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}
            """.utf8
        )
        XCTAssertThrowsError(
            try OCIReferrerIndex.parse(
                duplicateField,
                subjectDigest: subject
            )
        )

        let conflicting = Data(
            """
            {
              "schemaVersion":2,
              "mediaType":"application/vnd.oci.image.index.v1+json",
              "manifests":[
                {"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\(digest)","size":12},
                {"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\(digest)","size":13}
              ]
            }
            """.utf8
        )
        XCTAssertThrowsError(
            try OCIReferrerIndex.parse(
                conflicting,
                subjectDigest: subject
            )
        )
    }

    func testReferrerIndexRejectsMalformedMediaAnnotationsAndLimits() {
        let subject = try! OCIContentDigest(
            "sha256:" + String(repeating: "1", count: 64)
        )
        let digest = "sha256:" + String(repeating: "2", count: 64)
        let malformed = [
            """
            {"schemaVersion":1,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}
            """,
            """
            {"schemaVersion":2,"mediaType":"text/plain","manifests":[]}
            """,
            """
            {"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\(digest)","size":-1}]}
            """,
            """
            {"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\(digest)","size":12,"artifactType":"invalid","annotations":{"bad\\nkey":"value"}}]}
            """
        ]
        for value in malformed {
            XCTAssertThrowsError(
                try OCIReferrerIndex.parse(
                    Data(value.utf8),
                    subjectDigest: subject
                ),
                value
            )
        }
    }

    func testRepositoryNameAndArtifactFilterRejectCredentialLikeInput() throws {
        XCTAssertEqual(
            try OCIRepositoryName("team/service").value,
            "team/service"
        )
        XCTAssertEqual(
            try OCIArtifactType("application/vnd.example.attestation.v1+json")
                .value,
            "application/vnd.example.attestation.v1+json"
        )

        for value in [
            "Team/service",
            "user:secret@team/service",
            "../service",
            "team//service"
        ] {
            XCTAssertThrowsError(try OCIRepositoryName(value))
        }
        XCTAssertThrowsError(try OCIArtifactType("text/plain"))
        XCTAssertThrowsError(
            try OCIArtifactType("application/example\nAuthorization: secret")
        )
    }
}
