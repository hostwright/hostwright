import XCTest
@testable import HostwrightManifest

final class ManifestMigrationTests: XCTestCase {
    func testCheckedInManifestV2GoldenParsesAndValidates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/v0.0.2/manifest.yaml")
        let manifest = try ManifestParser.parse(try String(contentsOf: root, encoding: .utf8))

        XCTAssertEqual(manifest.version, HostwrightManifest.currentVersion)
        XCTAssertEqual(manifest.project, "golden-contract")
        XCTAssertEqual(ManifestValidator.validate(manifest), [])
    }

    func testManifestV2IsTheCurrentBreakingContract() {
        XCTAssertEqual(HostwrightManifest.currentVersion, 2)
        XCTAssertEqual(HostwrightManifest.legacyVersion, 1)
    }

    func testPreviewMigratesExplicitV1WithoutMutatingTheInput() throws {
        let source = """
        version: 1
        project: demo
        services:
          api:
            image: local/demo:latest

        """

        let preview = try ManifestMigrator.previewV2(source)

        XCTAssertEqual(preview.sourceVersion, 1)
        XCTAssertEqual(preview.targetVersion, 2)
        XCTAssertEqual(preview.migratedManifest, source.replacingOccurrences(of: "version: 1", with: "version: 2"))
        XCTAssertEqual(preview.changes, [.replaceVersion(from: 1, to: 2)])
        XCTAssertEqual(try ManifestValidator.validated(preview.migratedManifest).version, 2)
        XCTAssertTrue(source.hasPrefix("version: 1"))
    }

    func testPreviewMakesLegacyImplicitVersionExplicit() throws {
        let source = """
        project: demo
        services:
          api:
            image: local/demo:latest

        """

        let preview = try ManifestMigrator.previewV2(source)

        XCTAssertEqual(preview.sourceVersion, 1)
        XCTAssertEqual(preview.changes, [.insertVersion(2)])
        XCTAssertTrue(preview.migratedManifest.hasPrefix("version: 2\nproject: demo"))
        XCTAssertEqual(try ManifestValidator.validated(preview.migratedManifest).version, 2)
    }

    func testPreviewIsIdempotentForV2AndRejectsFutureVersions() throws {
        let current = """
        version: 2
        project: demo
        services:
          api:
            image: local/demo:latest

        """

        let preview = try ManifestMigrator.previewV2(current)
        XCTAssertEqual(preview.sourceVersion, 2)
        XCTAssertEqual(preview.migratedManifest, current)
        XCTAssertEqual(preview.changes, [])

        XCTAssertThrowsError(try ManifestMigrator.previewV2(current.replacingOccurrences(of: "version: 2", with: "version: 3")))
    }

    func testPreviewRejectsUnknownOlderVersionsAndDuplicateDeclarations() {
        let unknown = "version: 0\nproject: demo\nservices:\n  api:\n    image: local/demo:latest\n"
        let duplicate = "version: 1\nversion: 1\nproject: demo\nservices:\n  api:\n    image: local/demo:latest\n"

        XCTAssertThrowsError(try ManifestMigrator.previewV2(unknown))
        XCTAssertThrowsError(try ManifestMigrator.previewV2(duplicate))
    }

    func testPreviewPreservesCRLFAndDoesNotReplaceCommentText() throws {
        let source = "# version: 1\r\nversion: 1\r\nproject: demo\r\nservices:\r\n  api:\r\n    image: local/demo:latest\r\n"

        let preview = try ManifestMigrator.previewV2(source)

        XCTAssertEqual(
            preview.migratedManifest,
            "# version: 1\r\nversion: 2\r\nproject: demo\r\nservices:\r\n  api:\r\n    image: local/demo:latest\r\n"
        )

        let implicit = "project: demo\r\nservices:\r\n  api:\r\n    image: local/demo:latest\r\n"
        XCTAssertEqual(
            try ManifestMigrator.previewV2(implicit).migratedManifest,
            "version: 2\r\n" + implicit
        )
    }

    func testEveryExecutableExampleHasDeterministicV2MigrationPreview() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let examples = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("examples"),
            includingPropertiesForKeys: nil
        ).map { $0.appendingPathComponent("hostwright.yaml") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        XCTAssertFalse(examples.isEmpty)
        for path in examples {
            let source = try String(contentsOf: path, encoding: .utf8)
            let preview = try ManifestMigrator.previewV2(source)
            XCTAssertEqual(preview.sourceVersion, 2, path.path)
            XCTAssertEqual(preview.targetVersion, 2, path.path)
            if source.contains("\n    health:") {
                XCTAssertEqual(preview.changes, [.migrateLegacyHealth], path.path)
                XCTAssertFalse(preview.migratedManifest.contains("\n    health:"), path.path)
                XCTAssertTrue(preview.migratedManifest.contains("\n    probes:"), path.path)
                XCTAssertEqual(
                    try ManifestValidator.validated(preview.migratedManifest),
                    try ManifestValidator.validated(source),
                    path.path
                )
            } else {
                XCTAssertEqual(preview.migratedManifest, source, path.path)
                XCTAssertEqual(preview.changes, [], path.path)
            }
        }
    }
}
