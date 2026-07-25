import Foundation
@testable import HostwrightRegistry
import XCTest

final class ImageSBOMArtifactTests: XCTestCase {
    func testBuildsDigestVerifiedOCIArtifactBoundToImageAndProvenance() throws {
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "a", count: 64)
        )
        let provenanceDescriptor = try OCIContentDigest(
            "sha256:" + String(repeating: "b", count: 64)
        )
        let provenanceReferrer = try OCIContentDigest(
            "sha256:" + String(repeating: "c", count: 64)
        )
        let document = try spdx(subject: subject)

        let artifact = try ImageSBOMArtifact.make(
            documentPayload: document,
            expectedFormat: .spdxJSON,
            subjectDescriptor: try OCIContentDescriptor(
                mediaType:
                    OCIReferrerDescriptor.manifestMediaType,
                digest: subject,
                size: 512
            ),
            endpoint: try RegistryEndpoint(
                "https://registry.example.test"
            ),
            repository: try OCIRepositoryName("team/image"),
            provenanceDescriptorDigest: provenanceDescriptor,
            provenanceReferrerDigest: provenanceReferrer
        )

        XCTAssertEqual(
            artifact.graph.discovery.subjectDigest,
            subject
        )
        XCTAssertEqual(
            artifact.rootDescriptor.artifactType?.value,
            ImageSBOMFormat.spdxJSON.artifactType
        )
        XCTAssertEqual(artifact.graph.objects.count, 3)
        XCTAssertEqual(
            artifact.rootDescriptor.annotations[
                "org.hostwright.provenance.referrer-digest"
            ],
            provenanceReferrer.canonicalValue
        )
        for object in artifact.graph.objects {
            XCTAssertTrue(try object.digest.matches(object.payload))
            XCTAssertEqual(object.size, object.payload.count)
        }
        let root = try XCTUnwrap(
            artifact.graph.objects.first {
                $0.digest == artifact.rootDescriptor.digest
            }
        )
        let parsed = try OCIParsedDocument.parse(root.payload)
        XCTAssertEqual(parsed.subject?.digest, subject)
        XCTAssertEqual(
            parsed.effectiveArtifactType?.value,
            ImageSBOMFormat.spdxJSON.artifactType
        )
    }

    func testRejectsIncompleteProvenanceBindingAndSubjectMismatch() throws {
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "d", count: 64)
        )
        XCTAssertThrowsError(
            try ImageSBOMArtifact.make(
                documentPayload: try spdx(subject: subject),
                expectedFormat: .spdxJSON,
                subjectDescriptor: try OCIContentDescriptor(
                    mediaType:
                        OCIReferrerDescriptor.manifestMediaType,
                    digest: subject,
                    size: 12
                ),
                endpoint: try RegistryEndpoint(
                    "https://registry.example.test"
                ),
                repository: try OCIRepositoryName("team/image"),
                provenanceDescriptorDigest: subject
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageSBOMError,
                .invalidDocument
            )
        }

        let other = try OCIContentDigest(
            "sha256:" + String(repeating: "e", count: 64)
        )
        XCTAssertThrowsError(
            try ImageSBOMArtifact.make(
                documentPayload: try spdx(subject: other),
                expectedFormat: .spdxJSON,
                subjectDescriptor: try OCIContentDescriptor(
                    mediaType:
                        OCIReferrerDescriptor.manifestMediaType,
                    digest: subject,
                    size: 12
                ),
                endpoint: try RegistryEndpoint(
                    "https://registry.example.test"
                ),
                repository: try OCIRepositoryName("team/image")
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageSBOMError,
                .subjectDigestMismatch
            )
        }

        XCTAssertThrowsError(
            try ImageSBOMArtifact.make(
                documentPayload: try spdx(subject: subject),
                expectedFormat: .spdxJSON,
                subjectDescriptor: try OCIContentDescriptor(
                    mediaType:
                        "application/vnd.oci.image.config.v1+json",
                    digest: subject,
                    size: 12
                ),
                endpoint: try RegistryEndpoint(
                    "https://registry.example.test"
                ),
                repository: try OCIRepositoryName("team/image")
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageSBOMError,
                .invalidDocument
            )
        }
    }

    private func spdx(subject: OCIContentDigest) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "spdxVersion": "SPDX-2.3",
                "dataLicense": "CC0-1.0",
                "SPDXID": "SPDXRef-DOCUMENT",
                "name": "image sbom",
                "documentNamespace": "urn:hostwright:test",
                "creationInfo": [
                    "created": "2026-07-24T00:00:00Z",
                    "creators": ["Tool: tests"]
                ],
                "packages": [[
                    "name": "image",
                    "SPDXID": "SPDXRef-image",
                    "checksums": [[
                        "algorithm": "SHA256",
                        "checksumValue": subject.encoded
                    ]]
                ]]
            ],
            options: [.sortedKeys]
        )
    }
}
