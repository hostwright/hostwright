import XCTest
@testable import HostwrightManifest

final class ManifestMigrationTests: XCTestCase {
    func testCheckedInManifestV3GoldenParsesAndValidates() throws {
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

    func testManifestV3IsTheCurrentBreakingContract() {
        XCTAssertEqual(HostwrightManifest.currentVersion, 3)
        XCTAssertEqual(HostwrightManifest.legacyVersion, 1)
    }

    func testPreviewMigratesExplicitV1WithoutMutatingTheInput() throws {
        let source = """
        version: 1
        project: demo
        services:
          api:
            image: local/demo:latest
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}

        """

        let preview = try ManifestMigrator.previewV3(source)

        XCTAssertEqual(preview.sourceVersion, 1)
        XCTAssertEqual(preview.targetVersion, 3)
        XCTAssertEqual(preview.migratedManifest, source.replacingOccurrences(of: "version: 1", with: "version: 3"))
        XCTAssertEqual(preview.changes, [.replaceVersion(from: 1, to: 3)])
        XCTAssertEqual(try ManifestValidator.validated(preview.migratedManifest).version, 3)
        XCTAssertTrue(source.hasPrefix("version: 1"))
    }

    func testPreviewMakesLegacyImplicitVersionExplicit() throws {
        let source = """
        project: demo
        services:
          api:
            image: local/demo:latest
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}

        """

        let preview = try ManifestMigrator.previewV3(source)

        XCTAssertEqual(preview.sourceVersion, 1)
        XCTAssertEqual(preview.changes, [.insertVersion(3)])
        XCTAssertTrue(preview.migratedManifest.hasPrefix("version: 3\nproject: demo"))
        XCTAssertEqual(try ManifestValidator.validated(preview.migratedManifest).version, 3)
    }

    func testPreviewIsIdempotentForV3AndRejectsFutureVersions() throws {
        let current = """
        version: 3
        project: demo
        services:
          api:
            image: local/demo:latest
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}

        """

        let preview = try ManifestMigrator.previewV3(current)
        XCTAssertEqual(preview.sourceVersion, 3)
        XCTAssertEqual(preview.migratedManifest, current)
        XCTAssertEqual(preview.changes, [])

        XCTAssertThrowsError(try ManifestMigrator.previewV3(current.replacingOccurrences(of: "version: 3", with: "version: 4")))
    }

    func testPreviewConvertsV2FlatResourcesToBothRequestAndLimit() throws {
        let source = """
        version: 2
        project: demo
        services:
          api:
            image: local/demo:latest
            resources: {cpus: 2, memory: 512MiB}
        """

        let preview = try ManifestMigrator.previewV3(source)

        XCTAssertEqual(preview.sourceVersion, 2)
        XCTAssertEqual(preview.targetVersion, 3)
        XCTAssertEqual(
            preview.changes,
            [.replaceVersion(from: 2, to: 3), .migrateLegacyResources]
        )
        let migrated = try ManifestValidator.validated(preview.migratedManifest)
        let resources = try XCTUnwrap(migrated.services.first?.resources)
        XCTAssertEqual(resources.requests, HostwrightResourceSet(cpus: 2, memory: "512MiB"))
        XCTAssertEqual(resources.limits, HostwrightResourceSet(cpus: 2, memory: "512MiB"))
    }

    func testPreviewConvertsVersionlessFlatResourcesWithoutInventingCapacity() throws {
        let source = """
        project: demo
        services:
          api:
            image: local/demo:latest
            resources: {cpus: 2, memory: 512MiB}
        """

        let preview = try ManifestMigrator.previewV3(source)

        XCTAssertEqual(preview.sourceVersion, 1)
        XCTAssertEqual(preview.targetVersion, 3)
        XCTAssertEqual(
            preview.changes,
            [.insertVersion(3), .migrateLegacyResources]
        )
        let migrated = try ManifestValidator.validated(preview.migratedManifest)
        let resources = try XCTUnwrap(migrated.services.first?.resources)
        XCTAssertEqual(resources.requests, HostwrightResourceSet(cpus: 2, memory: "512MiB"))
        XCTAssertEqual(resources.limits, HostwrightResourceSet(cpus: 2, memory: "512MiB"))
    }

    func testCurrentNestedInlineResourcesRemainIdempotent() throws {
        let source = """
        version: 3
        project: demo
        services:
          api:
            image: local/demo:latest
            resources: {requests: {cpus: 1, memory: 512MiB}, limits: {cpus: 2, memory: 1GiB}}
        """

        let preview = try ManifestMigrator.previewV3(source)

        XCTAssertEqual(preview.sourceVersion, 3)
        XCTAssertEqual(preview.targetVersion, 3)
        XCTAssertEqual(preview.migratedManifest, source)
        XCTAssertEqual(preview.changes, [])
    }

    func testPreviewUsesStructuralResourceMetadataForCurrentNestedAndFlatForms() throws {
        let nested = """
        version: 3
        project: demo
        services:
          api:
            image: local/demo:latest
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 2, memory: 1GiB}
        """
        let nestedPreview = try ManifestMigrator.previewV3(nested)
        XCTAssertEqual(nestedPreview.migratedManifest, nested)
        XCTAssertEqual(nestedPreview.changes, [])

        let flat = """
        version: 3
        project: demo
        services:
          api:
            image: local/demo:latest
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
            # odd placement and comments must not confuse structural detection
            resources: {cpus: 2, memory: 1GiB}
        """
        XCTAssertThrowsError(try ManifestMigrator.previewV3(flat))
    }

    func testCurrentV3FlatResourcesHaveStableMigrationReasonAndPath() {
        let source = """
        version: 3
        project: demo
        services:
          api:
            image: local/demo:latest
            resources: {cpus: 2, memory: 1GiB}
        """

        XCTAssertThrowsError(try ManifestMigrator.previewV3(source)) { error in
            guard case let .failed(issues) = error as? ManifestParseError else {
                return XCTFail("expected ManifestParseError.failed")
            }
            XCTAssertEqual(issues, [
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest version 3 must use nested resources.requests and resources.limits; flat resources are legacy input only.",
                    path: "$.services.api.resources"
                )
            ])
        }
    }

    func testPreviewRejectsUnknownOlderVersionsAndDuplicateDeclarations() {
        let unknown = "version: 0\nproject: demo\nservices:\n  api:\n    image: local/demo:latest\n"
        let duplicate = "version: 1\nversion: 1\nproject: demo\nservices:\n  api:\n    image: local/demo:latest\n"

        XCTAssertThrowsError(try ManifestMigrator.previewV3(unknown))
        XCTAssertThrowsError(try ManifestMigrator.previewV3(duplicate))
    }

    func testPreviewPreservesCRLFAndDoesNotReplaceCommentText() throws {
        let source = "# version: 1\r\nversion: 1\r\nproject: demo\r\nservices:\r\n  api:\r\n    image: local/demo:latest\r\n    resources:\r\n      requests: {cpus: 1, memory: 512MiB}\r\n      limits: {cpus: 1, memory: 512MiB}\r\n"

        let preview = try ManifestMigrator.previewV3(source)

        XCTAssertEqual(
            preview.migratedManifest,
            "# version: 1\r\nversion: 3\r\nproject: demo\r\nservices:\r\n  api:\r\n    image: local/demo:latest\r\n    resources:\r\n      requests: {cpus: 1, memory: 512MiB}\r\n      limits: {cpus: 1, memory: 512MiB}\r\n"
        )

        let implicit = "project: demo\r\nservices:\r\n  api:\r\n    image: local/demo:latest\r\n    resources:\r\n      requests: {cpus: 1, memory: 512MiB}\r\n      limits: {cpus: 1, memory: 512MiB}\r\n"
        XCTAssertEqual(
            try ManifestMigrator.previewV3(implicit).migratedManifest,
            "version: 3\r\n" + implicit
        )
    }

    func testPreviewConvertsCRLFFlatResourcesWithoutUsingSourceIndentation() throws {
        let source = "# resources: {cpus: 99}\r\nversion: 2\r\nproject: demo\r\nservices:\r\n  api:\r\n    image: local/demo:latest\r\n    resources: {cpus: 2, memory: 512MiB}\r\n"

        let preview = try ManifestMigrator.previewV3(source)

        XCTAssertEqual(preview.sourceVersion, 2)
        XCTAssertEqual(
            preview.changes,
            [.replaceVersion(from: 2, to: 3), .migrateLegacyResources]
        )
        XCTAssertTrue(preview.migratedManifest.contains("version: 3\n"))
        XCTAssertFalse(preview.migratedManifest.contains("# resources: {cpus: 99}"))
        let migrated = try ManifestValidator.validated(preview.migratedManifest)
        XCTAssertEqual(migrated.services[0].resources?.requests.cpus, 2)
        XCTAssertEqual(migrated.services[0].resources?.limits?.memory, "512MiB")
    }

    func testEveryExecutableExampleHasDeterministicV3MigrationPreview() throws {
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
            let preview = try ManifestMigrator.previewV3(source)
            XCTAssertEqual(preview.sourceVersion, 3, path.path)
            XCTAssertEqual(preview.targetVersion, 3, path.path)
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
