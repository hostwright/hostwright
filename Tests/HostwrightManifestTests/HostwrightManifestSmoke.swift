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
}
