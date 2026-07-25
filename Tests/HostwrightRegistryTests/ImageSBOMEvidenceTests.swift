import Foundation
@testable import HostwrightRegistry
import XCTest

final class ImageSBOMEvidenceTests: XCTestCase {
    func testExtractsOnlyVerifiedExactSubjectSBOMRoots() throws {
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "a", count: 64)
        )
        let payload = try spdx(subject: subject)
        let artifact = try ImageSBOMArtifact.make(
            documentPayload: payload,
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

        let evidence = try ImageSBOMEvidenceExtractor.extract(
            from: artifact.graph,
            expectedSubjectDigest: subject,
            allowedFormats: [.spdxJSON]
        )

        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence[0].documentPayload, payload)
        XCTAssertEqual(
            evidence[0].rootDescriptor.digest,
            artifact.rootDescriptor.digest
        )
    }

    func testRejectsWrongSubjectAndDisallowedFormat() throws {
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "b", count: 64)
        )
        let artifact = try ImageSBOMArtifact.make(
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
            repository: try OCIRepositoryName("team/image")
        )
        XCTAssertThrowsError(
            try ImageSBOMEvidenceExtractor.extract(
                from: artifact.graph,
                expectedSubjectDigest: try OCIContentDigest(
                    "sha256:" + String(repeating: "c", count: 64)
                ),
                allowedFormats: [.spdxJSON]
            )
        )
        XCTAssertThrowsError(
            try ImageSBOMEvidenceExtractor.extract(
                from: artifact.graph,
                expectedSubjectDigest: subject,
                allowedFormats: [.cyclonedxJSON]
            )
        ) {
            XCTAssertEqual($0 as? ImageSBOMError, .unsupportedFormat)
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
