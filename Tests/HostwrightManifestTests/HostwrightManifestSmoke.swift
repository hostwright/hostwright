import Foundation
import XCTest
@testable import HostwrightManifest

final class HostwrightManifestTests: XCTestCase {
    func testValidManifestParsesAndValidates() throws {
        let manifest = try ManifestValidator.validated(Self.validManifest)

        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.effectiveVersion, 1)
        XCTAssertEqual(manifest.project, "api-local")
        XCTAssertEqual(manifest.services.count, 1)
        XCTAssertEqual(manifest.services[0].name, "api")
        XCTAssertEqual(manifest.services[0].ports, ["8080:8080"])
        XCTAssertEqual(manifest.services[0].health?.interval, "10s")
        XCTAssertEqual(manifest.services[0].restart?.policy, "on-failure")
    }

    func testVersionlessManifestRemainsLegacyCurrentVersion() throws {
        let manifest = try ManifestValidator.validated(
            """
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
            """
        )

        XCTAssertNil(manifest.version)
        XCTAssertEqual(manifest.effectiveVersion, HostwrightManifest.currentVersion)
    }

    func testExplicitOlderAndNewerManifestVersionsFailClosed() {
        assertManifestFailure(
            """
            version: 0
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            code: "HW-MANIFEST-003",
            contains: "older than supported version 1"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            code: "HW-MANIFEST-003",
            contains: "newer than supported version 1"
        )
    }

    func testInvalidManifestVersionShapeFailsValidation() {
        assertManifestFailure(
            """
            version: v1
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            code: "HW-MANIFEST-002",
            contains: "Manifest version must be an integer"
        )
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

    func testEnvironmentKeysAndUnsafeVolumesFailValidation() {
        assertManifestFailure(
            """
            version: 1
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                env:
                  1TOKEN: value
            """,
            contains: "environment key"
        )

        assertManifestFailure(
            """
            version: 1
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                env:
                  API-TOKEN: value
            """,
            contains: "environment key"
        )

        for rootEquivalent in ["/:/host:ro", "//:/host:ro", "/./:/host:ro", "/data/..:/host:ro"] {
            assertManifestFailure(
                """
                version: 1
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    volumes:
                      - "\(rootEquivalent)"
                """,
                contains: "must not mount the host root"
            )
        }

        assertManifestFailure(
            """
            version: 1
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                volumes:
                  - "../data:/data:ro"
            """,
            contains: "parent-directory traversal"
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

    func testUnsupportedFieldsFailClosedWithContext() {
        assertManifestFailure(
            """
            apiVersion: hostwright.dev/v1
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            code: "HW-MANIFEST-003",
            contains: "Unsupported top-level manifest field 'apiVersion'"
        )

        assertManifestFailure(
            """
            version: 1
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                build: .
            """,
            code: "HW-MANIFEST-003",
            contains: "Unsupported service field 'build'"
        )

        assertManifestFailure(
            """
            version: 1
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                health:
                  command: ["curl", "-f", "http://localhost:8080/health"]
                  timeout: 5s
            """,
            code: "HW-MANIFEST-003",
            contains: "Unsupported health field 'timeout'"
        )

        assertManifestFailure(
            """
            version: 1
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                restart:
                  policy: on-failure
                  maxAttempts: 3
            """,
            code: "HW-MANIFEST-003",
            contains: "Unsupported restart field 'maxAttempts'"
        )
    }

    func testUnsupportedNetworkingAndDiscoveryFieldsFailClosed() {
        for field in ["dns", "hostname", "network_mode", "expose", "extra_hosts"] {
            assertManifestFailure(
                """
                version: 1
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    \(field): unsupported
                """,
                code: "HW-MANIFEST-003",
                contains: "DNS, service discovery"
            )
        }
    }

    func testExamplesAndSchemaStayAlignedWithSupportedManifestSubset() throws {
        let root = try packageRoot()
        let examplePaths = [
            "examples/single-service/hostwright.yaml",
            "examples/api-redis/hostwright.yaml",
            "examples/app-suite/hostwright.yaml"
        ]
        let schema = try read("schemas/hostwright-yaml.schema.json", root: root)
        let schemaJSON = try jsonObject(schema)

        for examplePath in examplePaths {
            let manifestText = try read(examplePath, root: root)
            let manifest = try ManifestValidator.validated(manifestText)
            XCTAssertEqual(manifest.version, 1, examplePath)
            XCTAssertFalse(manifestText.contains("apiVersion"), examplePath)
            XCTAssertFalse(manifestText.contains("depends_on"), examplePath)
            XCTAssertFalse(manifestText.contains("deploy:"), examplePath)
        }

        XCTAssertFalse(schema.contains(#""apiVersion""#))
        let properties = try XCTUnwrap(schemaJSON["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["version", "project", "services"])
        let required = try XCTUnwrap(schemaJSON["required"] as? [String])
        XCTAssertEqual(required, ["project", "services"])
        let version = try XCTUnwrap(properties["version"] as? [String: Any])
        XCTAssertEqual(version["const"] as? Int, HostwrightManifest.currentVersion)
        let project = try XCTUnwrap(properties["project"] as? [String: Any])
        XCTAssertEqual(project["pattern"] as? String, #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#)
        let services = try XCTUnwrap(properties["services"] as? [String: Any])
        XCTAssertEqual(services["minProperties"] as? Int, 1)

        let definitions = try XCTUnwrap(schemaJSON["$defs"] as? [String: Any])
        let service = try XCTUnwrap(definitions["service"] as? [String: Any])
        XCTAssertEqual(service["required"] as? [String], ["image"])
        XCTAssertEqual(service["additionalProperties"] as? Bool, false)
        let serviceProperties = try XCTUnwrap(service["properties"] as? [String: Any])
        XCTAssertEqual(Set(serviceProperties.keys), ["image", "command", "env", "ports", "volumes", "health", "restart"])
        let image = try XCTUnwrap(serviceProperties["image"] as? [String: Any])
        XCTAssertEqual(image["minLength"] as? Int, 1)
        XCTAssertEqual(image["pattern"] as? String, #"^[^-\s][^\s]*$"#)
        let command = try XCTUnwrap(serviceProperties["command"] as? [String: Any])
        let commandItems = try XCTUnwrap(command["items"] as? [String: Any])
        XCTAssertEqual(commandItems["pattern"] as? String, #"^[^-].*$"#)
        let env = try XCTUnwrap(serviceProperties["env"] as? [String: Any])
        let envPropertyNames = try XCTUnwrap(env["propertyNames"] as? [String: Any])
        XCTAssertEqual(envPropertyNames["pattern"] as? String, #"^[A-Za-z_][A-Za-z0-9_]*$"#)
        let ports = try XCTUnwrap(serviceProperties["ports"] as? [String: Any])
        let portItems = try XCTUnwrap(ports["items"] as? [String: Any])
        XCTAssertEqual(portItems["pattern"] as? String, #"^[0-9]{1,5}:[0-9]{1,5}$"#)
        let volumes = try XCTUnwrap(serviceProperties["volumes"] as? [String: Any])
        let volumeItems = try XCTUnwrap(volumes["items"] as? [String: Any])
        XCTAssertEqual(volumeItems["pattern"] as? String, #"^(?!/+(?:\./*)*:)(?![^:]*(?:^|/)\.\.(?:/|:)).+:/[^:]+(:ro|:rw)?$"#)
        let healthRef = try XCTUnwrap(serviceProperties["health"] as? [String: Any])
        XCTAssertEqual(healthRef["$ref"] as? String, "#/$defs/health")
        let restartRef = try XCTUnwrap(serviceProperties["restart"] as? [String: Any])
        XCTAssertEqual(restartRef["$ref"] as? String, "#/$defs/restart")

        let health = try XCTUnwrap(definitions["health"] as? [String: Any])
        XCTAssertEqual(health["required"] as? [String], ["command"])
        XCTAssertEqual(health["additionalProperties"] as? Bool, false)
        let healthProperties = try XCTUnwrap(health["properties"] as? [String: Any])
        let healthCommand = try XCTUnwrap(healthProperties["command"] as? [String: Any])
        XCTAssertEqual(healthCommand["minItems"] as? Int, 1)
        let healthInterval = try XCTUnwrap(healthProperties["interval"] as? [String: Any])
        XCTAssertEqual(healthInterval["pattern"] as? String, #"^[1-9][0-9]*s$"#)

        let restart = try XCTUnwrap(definitions["restart"] as? [String: Any])
        XCTAssertEqual(restart["required"] as? [String], ["policy"])
        XCTAssertEqual(restart["additionalProperties"] as? Bool, false)
        let restartProperties = try XCTUnwrap(restart["properties"] as? [String: Any])
        let restartPolicy = try XCTUnwrap(restartProperties["policy"] as? [String: Any])
        XCTAssertEqual(restartPolicy["enum"] as? [String], ["no", "on-failure", "unless-stopped"])
    }

    private func assertManifestFailure(_ text: String, code expectedCode: String? = nil, contains expectedText: String) {
        XCTAssertThrowsError(try ManifestValidator.validated(text)) { error in
            guard let manifestError = error as? ManifestParseError else {
                return XCTFail("Expected ManifestParseError, got \(error).")
            }
            XCTAssertTrue(
                manifestError.issues.contains { issue in
                    (expectedCode == nil || issue.code.rawValue == expectedCode) && issue.message.contains(expectedText)
                },
                "Expected issue containing '\(expectedText)' with code \(expectedCode ?? "<any>"), got \(manifestError.issues)."
            )
        }
    }

    private static let validManifest = """
    version: 1
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

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
