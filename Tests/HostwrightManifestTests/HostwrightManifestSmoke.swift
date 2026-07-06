import Foundation
import XCTest
@testable import HostwrightManifest

final class HostwrightManifestTests: XCTestCase {
    func testValidManifestParsesAndValidates() throws {
        let manifest = try ManifestValidator.validated(Self.validManifest)

        XCTAssertEqual(manifest.project, "api-local")
        XCTAssertEqual(manifest.services.count, 1)
        XCTAssertEqual(manifest.services[0].name, "api")
        XCTAssertEqual(manifest.services[0].ports, ["8080:8080"])
        XCTAssertEqual(manifest.services[0].health?.interval, "10s")
        XCTAssertEqual(manifest.services[0].restart?.policy, "on-failure")
    }

    func testMissingProjectFailsValidation() {
        assertManifestFailure(
            """
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            contains: "project"
        )
    }

    func testMissingImageFailsValidation() {
        assertManifestFailure(
            """
            project: api-local
            services:
              api:
                ports:
                  - "8080:8080"
            """,
            contains: "image"
        )
    }

    func testMalformedPortFailsValidation() {
        assertManifestFailure(
            """
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                ports:
                  - "not-a-port"
            """,
            contains: "host:container"
        )
    }

    func testFlagLikeImageAndServiceCommandTokensFailValidation() {
        assertManifestFailure(
            """
            project: api-local
            services:
              api:
                image: --mount=src=/,dst=/host
            """,
            contains: "image must not begin"
        )

        assertManifestFailure(
            """
            project: api-local
            services:
              api:
                image: -bad
            """,
            contains: "image must not begin"
        )

        assertManifestFailure(
            """
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                command: ["--flag"]
            """,
            contains: "command token"
        )
    }

    func testUnsupportedKubernetesStyleYamlFailsClosed() {
        XCTAssertThrowsError(
            try ManifestParser.parse(
                """
                apiVersion: hostwright.dev/v1alpha1
                kind: Stack
                """
            )
        ) { error in
            guard let manifestError = error as? ManifestParseError else {
                return XCTFail("Expected ManifestParseError, got \(error).")
            }
            XCTAssertTrue(manifestError.issues.contains { $0.code.rawValue == "HW-MANIFEST-003" })
        }
    }

    func testExamplesAndSchemaStayAlignedWithSupportedManifestSubset() throws {
        let root = try packageRoot()
        let singleService = try read("examples/single-service/hostwright.yaml", root: root)
        let apiRedis = try read("examples/api-redis/hostwright.yaml", root: root)
        let schema = try read("schemas/hostwright-yaml.schema.json", root: root)

        XCTAssertNoThrow(try ManifestValidator.validated(singleService))
        XCTAssertNoThrow(try ManifestValidator.validated(apiRedis))
        XCTAssertFalse(singleService.contains("apiVersion"))
        XCTAssertFalse(apiRedis.contains("apiVersion"))
        XCTAssertFalse(schema.contains(#""apiVersion""#))
        XCTAssertTrue(schema.contains(#""project""#))
        XCTAssertTrue(schema.contains(#""services""#))
        XCTAssertTrue(schema.contains(#""restart""#))
    }

    private func assertManifestFailure(_ text: String, contains expectedText: String) {
        XCTAssertThrowsError(try ManifestValidator.validated(text)) { error in
            guard let manifestError = error as? ManifestParseError else {
                return XCTFail("Expected ManifestParseError, got \(error).")
            }
            XCTAssertTrue(manifestError.issues.contains { $0.message.contains(expectedText) })
        }
    }

    private static let validManifest = """
    project: api-local

    services:
      api:
        image: ghcr.io/example/api:latest
        ports:
          - "8080:8080"
        health:
          command: ["curl", "-f", "http://localhost:8080/health"]
          interval: 10s
        restart:
          policy: on-failure

    """

    private func read(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: url.appendingPathComponent("README.md").path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                throw NSError(domain: "HostwrightManifestTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not locate package root."])
            }
            url = parent
        }
    }
}
