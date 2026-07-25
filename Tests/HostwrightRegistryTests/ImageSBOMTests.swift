import Foundation
@testable import HostwrightRegistry
import XCTest

final class ImageSBOMTests: XCTestCase {
    func testParsesAndNormalizesSPDXBoundToExactImageDigest() throws {
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "a", count: 64)
        )
        let payload = spdx(
            subject: subject,
            packages: [
                [
                    "name": "zlib",
                    "SPDXID": "SPDXRef-zlib",
                    "versionInfo": "1.3.1",
                    "licenseDeclared": "Zlib",
                    "checksums": [[
                        "algorithm": "SHA256",
                        "checksumValue": subject.encoded
                    ]],
                    "externalRefs": [[
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceType": "purl",
                        "referenceLocator": "pkg:generic/zlib@1.3.1"
                    ]]
                ],
                [
                    "name": "alpine",
                    "SPDXID": "SPDXRef-alpine",
                    "checksums": []
                ]
            ]
        )

        let document = try ImageSBOMDocument.parse(
            payload,
            expectedSubjectDigest: subject,
            expectedFormat: .spdxJSON
        )

        XCTAssertEqual(document.format, .spdxJSON)
        XCTAssertEqual(document.specificationVersion, "2.3")
        XCTAssertEqual(
            document.components.map(\.id),
            ["SPDXRef-alpine", "SPDXRef-zlib"]
        )
        XCTAssertEqual(document.components.last?.licenses, ["Zlib"])
        XCTAssertEqual(
            document.components.last?.packageURL,
            "pkg:generic/zlib@1.3.1"
        )
        XCTAssertEqual(document.normalizedComponentsSHA256.count, 64)
        XCTAssertTrue(try document.documentDigest.matches(payload))
    }

    func testParsesCycloneDXNestedComponentsAndExactRootBinding() throws {
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "b", count: 64)
        )
        let object: [String: Any] = [
            "bomFormat": "CycloneDX",
            "specVersion": "1.6",
            "serialNumber": "urn:uuid:00000000-0000-4000-8000-000000000001",
            "version": 1,
            "metadata": [
                "component": [
                    "type": "container",
                    "bom-ref": "image",
                    "name": "example/image",
                    "hashes": [[
                        "alg": "SHA-256",
                        "content": subject.encoded
                    ]]
                ]
            ],
            "components": [[
                "type": "library",
                "bom-ref": "pkg:generic/lib@1",
                "name": "lib",
                "version": "1",
                "purl": "pkg:generic/lib@1",
                "licenses": [["license": ["id": "MIT"]]],
                "components": [[
                    "type": "library",
                    "bom-ref": "nested",
                    "name": "nested"
                ]]
            ]]
        ]
        let payload = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        let document = try ImageSBOMDocument.parse(
            payload,
            expectedSubjectDigest: subject
        )

        XCTAssertEqual(document.format, .cyclonedxJSON)
        XCTAssertEqual(document.specificationVersion, "1.6")
        XCTAssertEqual(
            document.components.map(\.id),
            ["image", "nested", "pkg:generic/lib@1"]
        )
    }

    func testRejectsMismatchDuplicatesMalformedAndUnsupportedDocuments() throws {
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "c", count: 64)
        )
        let other = try OCIContentDigest(
            "sha256:" + String(repeating: "d", count: 64)
        )
        XCTAssertThrowsError(
            try ImageSBOMDocument.parse(
                spdx(subject: other),
                expectedSubjectDigest: subject
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageSBOMError,
                .subjectDigestMismatch
            )
        }

        let duplicate = [
            [
                "name": "one",
                "SPDXID": "SPDXRef-duplicate",
                "checksums": [[
                    "algorithm": "SHA256",
                    "checksumValue": subject.encoded
                ]]
            ],
            [
                "name": "two",
                "SPDXID": "SPDXRef-duplicate",
                "checksums": []
            ]
        ]
        XCTAssertThrowsError(
            try ImageSBOMDocument.parse(
                spdx(subject: subject, packages: duplicate),
                expectedSubjectDigest: subject
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageSBOMError,
                .duplicateComponent
            )
        }

        let duplicateKey = Data(
            #"{"spdxVersion":"SPDX-2.3","spdxVersion":"SPDX-2.3"}"#.utf8
        )
        XCTAssertThrowsError(
            try ImageSBOMDocument.parse(
                duplicateKey,
                expectedSubjectDigest: subject
            )
        ) {
            XCTAssertEqual($0 as? ImageSBOMError, .invalidDocument)
        }

        let unsupported = try JSONSerialization.data(
            withJSONObject: [
                "bomFormat": "CycloneDX",
                "specVersion": "1.4",
                "version": 1,
                "metadata": ["component": [:]]
            ],
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try ImageSBOMDocument.parse(
                unsupported,
                expectedSubjectDigest: subject
            )
        ) {
            XCTAssertEqual($0 as? ImageSBOMError, .unsupportedFormat)
        }
    }

    func testRejectsOversizedAndExcessivelyNestedDocuments() throws {
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "e", count: 64)
        )
        XCTAssertThrowsError(
            try ImageSBOMDocument.parse(
                Data(
                    repeating: 0x20,
                    count: ImageSBOMLimits.maximumDocumentBytes + 1
                ),
                expectedSubjectDigest: subject
            )
        ) {
            XCTAssertEqual($0 as? ImageSBOMError, .limitExceeded)
        }

        let nested = Data(
            ("{\"x\":" + String(repeating: "[", count: 129) +
             "0" + String(repeating: "]", count: 129) + "}").utf8
        )
        XCTAssertThrowsError(
            try ImageSBOMDocument.parse(
                nested,
                expectedSubjectDigest: subject
            )
        ) {
            XCTAssertEqual($0 as? ImageSBOMError, .invalidDocument)
        }
    }

    private func spdx(
        subject: OCIContentDigest,
        packages: [[String: Any]]? = nil
    ) -> Data {
        let defaultPackages: [[String: Any]] = [[
            "name": "image",
            "SPDXID": "SPDXRef-image",
            "checksums": [[
                "algorithm": "SHA256",
                "checksumValue": subject.encoded
            ]]
        ]]
        return try! JSONSerialization.data(
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
                "packages": packages ?? defaultPackages
            ],
            options: [.sortedKeys]
        )
    }
}
