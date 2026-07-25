import CryptoKit
import Foundation
import HostwrightCore
@testable import HostwrightRegistry
import XCTest

final class OCIImageArchiveSBOMGeneratorTests: XCTestCase {
    func testGeneratesSPDXAndCycloneDXFromExactOCIArchive() throws {
        let fixture = try makeArchive(
            packageDatabase:
                "Package: curl\nVersion: 8.10.0\nArchitecture: arm64\n\n"
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let generator = OCIImageArchiveSBOMGenerator()

        let inventory = try generator.inspect(
            archivePath: fixture.path,
            expectedSubjectDigest: fixture.subject
        )
        XCTAssertEqual(inventory.layers.count, 1)
        XCTAssertEqual(inventory.packages.map(\.name), ["curl"])
        XCTAssertEqual(inventory.operatingSystem, "linux")
        XCTAssertEqual(inventory.architecture, "arm64")
        XCTAssertEqual(
            inventory.subjectDescriptor.digest,
            fixture.subject
        )
        XCTAssertNotEqual(
            inventory.subjectDescriptor.digest,
            fixture.configuration
        )

        for format in ImageSBOMFormat.allCases {
            let generated = try generator.generate(
                archivePath: fixture.path,
                expectedSubjectDigest: fixture.subject,
                format: format,
                createdAt: "2026-07-24T20:00:00Z"
            )
            let parsed = try ImageSBOMDocument.parse(
                generated.payload,
                expectedSubjectDigest: fixture.subject,
                expectedFormat: format
            )
            XCTAssertTrue(
                parsed.components.contains {
                    $0.name == "curl" &&
                        $0.version == "8.10.0"
                }
            )
        }
    }

    func testRejectsDigestMismatchTraversalAndSymlinkEntries() throws {
        let fixture = try makeArchive(packageDatabase: nil)
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        XCTAssertThrowsError(
            try OCIImageArchiveSBOMGenerator().inspect(
                archivePath: fixture.path,
                expectedSubjectDigest: try OCIContentDigest(
                    "sha256:" + String(repeating: "f", count: 64)
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageSBOMError,
                .subjectDigestMismatch
            )
        }

        for (path, type) in [("../escape", UInt8(48)), ("link", UInt8(50))] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "hostwright-unsafe-\(UUID().uuidString).tar"
                )
            try tar(entries: [(path, Data(), type)]).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertThrowsError(
                try OCIImageArchiveSBOMGenerator().inspect(
                    archivePath: url.path,
                    expectedSubjectDigest: fixture.subject
                )
            )
        }
    }

    func testPreCancelledGenerationStopsBeforeArchiveEffects() throws {
        let fixture = try makeArchive(packageDatabase: nil)
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let cancellation = SecureSubprocessCancellation()
        cancellation.cancel()

        XCTAssertThrowsError(
            try OCIImageArchiveSBOMGenerator().generate(
                archivePath: fixture.path,
                expectedSubjectDigest: fixture.subject,
                format: .spdxJSON,
                createdAt: "2026-07-24T20:00:00Z",
                cancellation: cancellation
            )
        ) {
            XCTAssertEqual($0 as? ImageSBOMError, .cancelled)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.path)
        )
    }

    func testBindsMultiPlatformArchiveToRootIndexAndMergesComponents()
        throws
    {
        let fixture = try makeArchive(
            packageDatabase:
                "Package: curl\nVersion: 8.10.0\nArchitecture: arm64\n\n",
            additionalPackageDatabase:
                "Package: openssl\nVersion: 3.5.1\nArchitecture: amd64\n\n"
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }

        let inventory = try OCIImageArchiveSBOMGenerator().inspect(
            archivePath: fixture.path,
            expectedSubjectDigest: fixture.subject
        )

        XCTAssertEqual(
            inventory.subjectDescriptor.digest,
            fixture.subject
        )
        XCTAssertEqual(inventory.layers.count, 2)
        XCTAssertEqual(
            inventory.packages.map(\.name),
            ["curl", "openssl"]
        )
        XCTAssertEqual(inventory.operatingSystem, "linux")
        XCTAssertNil(inventory.architecture)
    }

    private func makeArchive(
        packageDatabase: String?,
        additionalPackageDatabase: String? = nil
    ) throws -> (
        path: String,
        subject: OCIContentDigest,
        configuration: OCIContentDigest
    ) {
        let config = try JSONSerialization.data(
            withJSONObject: [
                "architecture": "arm64",
                "os": "linux",
                "rootfs": ["type": "layers", "diff_ids": []]
            ],
            options: [.sortedKeys]
        )
        let configDigest = digest(config)
        let layer = packageLayer(packageDatabase)
        let layerDigest = digest(layer)
        let manifest = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "mediaType":
                    OCIReferrerDescriptor.manifestMediaType,
                "config": [
                    "mediaType":
                        "application/vnd.oci.image.config.v1+json",
                    "digest": configDigest.canonicalValue,
                    "size": config.count
                ],
                "layers": [[
                    "mediaType":
                        "application/vnd.oci.image.layer.v1.tar",
                    "digest": layerDigest.canonicalValue,
                    "size": layer.count
                ]]
            ],
            options: [.sortedKeys]
        )
        let manifestDigest = digest(manifest)
        var blobs: [(String, Data, UInt8)] = [
            (
                "blobs/sha256/\(manifestDigest.encoded)",
                manifest,
                48
            ),
            (
                "blobs/sha256/\(configDigest.encoded)",
                config,
                48
            ),
            (
                "blobs/sha256/\(layerDigest.encoded)",
                layer,
                48
            )
        ]
        let rootDescriptor: [String: Any]
        let subject: OCIContentDigest
        if let additionalPackageDatabase {
            let additionalConfig = try JSONSerialization.data(
                withJSONObject: [
                    "architecture": "amd64",
                    "os": "linux",
                    "rootfs": [
                        "type": "layers",
                        "diff_ids": []
                    ]
                ],
                options: [.sortedKeys]
            )
            let additionalConfigDigest = digest(
                additionalConfig
            )
            let additionalLayer = packageLayer(
                additionalPackageDatabase
            )
            let additionalLayerDigest = digest(
                additionalLayer
            )
            let additionalManifest = try JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": 2,
                    "mediaType":
                        OCIReferrerDescriptor.manifestMediaType,
                    "config": [
                        "mediaType":
                            "application/vnd.oci.image.config.v1+json",
                        "digest":
                            additionalConfigDigest.canonicalValue,
                        "size": additionalConfig.count
                    ],
                    "layers": [[
                        "mediaType":
                            "application/vnd.oci.image.layer.v1.tar",
                        "digest":
                            additionalLayerDigest.canonicalValue,
                        "size": additionalLayer.count
                    ]]
                ],
                options: [.sortedKeys]
            )
            let additionalManifestDigest = digest(
                additionalManifest
            )
            let imageIndex = try JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": 2,
                    "mediaType":
                        OCIReferrerDescriptor.indexMediaType,
                    "manifests": [
                        [
                            "mediaType":
                                OCIReferrerDescriptor.manifestMediaType,
                            "digest":
                                manifestDigest.canonicalValue,
                            "size": manifest.count,
                            "platform": [
                                "architecture": "arm64",
                                "os": "linux"
                            ]
                        ],
                        [
                            "mediaType":
                                OCIReferrerDescriptor.manifestMediaType,
                            "digest":
                                additionalManifestDigest
                                    .canonicalValue,
                            "size": additionalManifest.count,
                            "platform": [
                                "architecture": "amd64",
                                "os": "linux"
                            ]
                        ]
                    ]
                ],
                options: [.sortedKeys]
            )
            subject = digest(imageIndex)
            rootDescriptor = [
                "mediaType":
                    OCIReferrerDescriptor.indexMediaType,
                "digest": subject.canonicalValue,
                "size": imageIndex.count
            ]
            blobs += [
                (
                    "blobs/sha256/\(subject.encoded)",
                    imageIndex,
                    48
                ),
                (
                    "blobs/sha256/\(additionalManifestDigest.encoded)",
                    additionalManifest,
                    48
                ),
                (
                    "blobs/sha256/\(additionalConfigDigest.encoded)",
                    additionalConfig,
                    48
                ),
                (
                    "blobs/sha256/\(additionalLayerDigest.encoded)",
                    additionalLayer,
                    48
                )
            ]
        } else {
            subject = manifestDigest
            rootDescriptor = [
                "mediaType":
                    OCIReferrerDescriptor.manifestMediaType,
                "digest": manifestDigest.canonicalValue,
                "size": manifest.count
            ]
        }
        let index = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "mediaType": OCIReferrerDescriptor.indexMediaType,
                "manifests": [rootDescriptor]
            ],
            options: [.sortedKeys]
        )
        let outer = tar(entries: [
            ("oci-layout", Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8), 48),
            ("index.json", index, 48)
        ] + blobs)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-oci-\(UUID().uuidString).tar"
            )
        try outer.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return (url.path, subject, configDigest)
    }

    private func packageLayer(_ packageDatabase: String?) -> Data {
        if let packageDatabase {
            return tar(entries: [
                (
                    "var/lib/dpkg/status",
                    Data(packageDatabase.utf8),
                    48
                )
            ])
        }
        return tar(entries: [("empty", Data(), 48)])
    }

    private func digest(_ data: Data) -> OCIContentDigest {
        try! OCIContentDigest(
            "sha256:" + SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private func tar(
        entries: [(String, Data, UInt8)]
    ) -> Data {
        var result = Data()
        for (path, payload, type) in entries {
            var header = Data(repeating: 0, count: 512)
            put(path, into: &header, range: 0..<100)
            put("0000600", into: &header, range: 100..<108)
            put("0000000", into: &header, range: 108..<116)
            put("0000000", into: &header, range: 116..<124)
            put(
                String(format: "%011o", payload.count),
                into: &header,
                range: 124..<136
            )
            put("00000000000", into: &header, range: 136..<148)
            for index in 148..<156 { header[index] = 32 }
            header[156] = type
            put("ustar", into: &header, range: 257..<263)
            let checksum = header.reduce(0) { $0 + Int($1) }
            put(
                String(format: "%06o", checksum),
                into: &header,
                range: 148..<154
            )
            header[154] = 0
            header[155] = 32
            result.append(header)
            result.append(payload)
            let padding = (512 - payload.count % 512) % 512
            result.append(Data(repeating: 0, count: padding))
        }
        result.append(Data(repeating: 0, count: 1_024))
        return result
    }

    private func put(
        _ value: String,
        into data: inout Data,
        range: Range<Int>
    ) {
        for (offset, byte) in value.utf8.prefix(range.count).enumerated() {
            data[range.lowerBound + offset] = byte
        }
    }
}
