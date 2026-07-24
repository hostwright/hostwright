import Foundation
import XCTest
@testable import HostwrightManifest
@testable import HostwrightSecrets

final class HostwrightManifestTests: XCTestCase {
    func testValidManifestParsesAndValidates() throws {
        let manifest = try ManifestValidator.validated(Self.validManifest)

        XCTAssertEqual(manifest.version, 2)
        XCTAssertEqual(manifest.effectiveVersion, 2)
        XCTAssertNil(manifest.imagePolicy)
        XCTAssertEqual(manifest.effectiveImagePolicy, .allowTags)
        XCTAssertEqual(manifest.project, "api-local")
        XCTAssertEqual(manifest.services.count, 1)
        XCTAssertEqual(manifest.services[0].name, "api")
        XCTAssertEqual(manifest.services[0].ports, ["8080:8080"])
        XCTAssertEqual(manifest.services[0].health?.interval, "10s")
        XCTAssertEqual(manifest.services[0].restart?.policy, "on-failure")
    }

    func testSecretEnvironmentReferencesParseAndValidate() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                env:
                  APP_ENV: development
                secretEnv:
                  API_TOKEN: keychain://hostwright.api/api-token
            """
        )

        XCTAssertEqual(manifest.services[0].env["APP_ENV"], "development")
        let reference = try XCTUnwrap(manifest.services[0].secretEnv["API_TOKEN"])
        XCTAssertEqual(reference.service, "hostwright.api")
        XCTAssertEqual(reference.account, "api-token")
    }

    func testQuotedScalarsAndInlineArraysPreserveCommasAndEscapes() throws {
        let manifest = try ManifestValidator.validated(
            #"""
            version: 2
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                command: ["python", "print(a,b)"]
                env:
                  JSON_DOC: '{"a":1}'
                  NOTE: "a\\b\"c"
                health:
                  command: ["curl", "http://localhost:8080/a,b"]
                  interval: 10s
            """#
        )

        let service = manifest.services[0]
        XCTAssertEqual(service.command, ["python", "print(a,b)"])
        XCTAssertEqual(service.env["JSON_DOC"], #"{"a":1}"#)
        XCTAssertEqual(service.env["NOTE"], #"a\b"c"#)
        XCTAssertEqual(service.health?.command, ["curl", "http://localhost:8080/a,b"])
    }

    func testVersionlessManifestIsRecognizedAsLegacyButRequiresMigration() throws {
        let text = """
        project: api-local
        services:
          api:
            image: ghcr.io/example/api:latest
        """
        let parsed = try ManifestParser.parse(text)

        XCTAssertNil(parsed.version)
        XCTAssertEqual(parsed.effectiveVersion, HostwrightManifest.legacyVersion)
        assertManifestFailure(text, code: "HW-MANIFEST-003", contains: "must declare version: 2")
    }

    func testExplicitOlderAndNewerManifestVersionsFailClosed() {
        assertManifestFailure(
            """
            version: 1
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            code: "HW-MANIFEST-003",
            contains: "older than supported version 2"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            code: "HW-MANIFEST-003",
            contains: "newer than supported version 2"
        )
    }

    func testImagePolicyRequiresDigestPinnedImagesWhenConfigured() throws {
        let digest = String(repeating: "a", count: 64)
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            services:
              api:
                image: ghcr.io/example/api@sha256:\(digest)
            """
        )

        XCTAssertEqual(manifest.imagePolicy, .requireDigest)
        XCTAssertEqual(manifest.effectiveImagePolicy, .requireDigest)
        XCTAssertEqual(manifest.services[0].image, "ghcr.io/example/api@sha256:\(digest)")

        XCTAssertNoThrow(
            try ManifestValidator.validated(
                """
                version: 2
                project: api-local
                imagePolicy: allow-tags
                services:
                  api:
                    image: ghcr.io/example/api:latest
                """
            )
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            contains: "requires image 'ghcr.io/example/api:latest' to be digest-pinned"
        )
    }

    func testImageDigestSyntaxFailsClosedWithoutRegistryLookup() {
        assertManifestFailure(
            """
            version: 2
            project: api-local
            services:
              api:
                image: ghcr.io/example/api@sha512:abcdef
            """,
            contains: "image digest must use @sha256:<64 lowercase hex characters>"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            services:
              api:
                image: ghcr.io/example/api@sha256:ABCDEF
            """,
            contains: "image digest must use @sha256:<64 lowercase hex characters>"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            services:
              api:
                image: https://ghcr.io/example/api:latest
            """,
            contains: "must be an OCI-style image reference"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: content-trust
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            contains: "imagePolicy must be one of"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imagePolicy: allow-tags
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imagePolicy must be declared at most once"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: content-trust
            imagePolicy: require-digest
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imagePolicy must be declared at most once"
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
            version: 2
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
            version: 2
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

    func testFlagLikeImagesFailWhileCommandArgumentsRemainExecutable() throws {
        assertManifestFailure(
            """
            version: 2
            project: api-local
            services:
              api:
                image: --mount=src=/,dst=/host
            """,
            contains: "image must not begin"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            services:
              api:
                image: -bad
            """,
            contains: "image must not begin"
        )

        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                command: ["--flag"]
            """
        )
        XCTAssertEqual(manifest.services[0].command, ["--flag"])
    }

    func testEnvironmentKeysAndUnsafeVolumesFailValidation() {
        XCTAssertNoThrow(
            try ManifestValidator.validated(
                """
                version: 2
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    env:
                      AUTH_MODE: local
                      KEYCLOAK_URL: http://localhost:8080
                      PUBLIC_KEY_PATH: ./public.pem
                      MONKEY_PATCH: disabled
                """
            )
        )

        assertManifestFailure(
            """
            version: 2
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
            version: 2
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                env:
                  API-TOKEN: value
            """,
            contains: "environment key"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                env:
                  API_TOKEN: token=plaintext
            """,
            contains: "plaintext sensitive values must use secretEnv"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                env:
                  API_TOKEN: keychain://hostwright.api/api-token
            """,
            contains: "move it to secretEnv"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                env:
                  API_TOKEN: literal
                secretEnv:
                  API_TOKEN: keychain://hostwright.api/api-token
            """,
            contains: "must not appear in both env and secretEnv"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                secretEnv:
                  API_TOKEN: env://hostwright.api/api-token
            """,
            contains: "keychain://<service>/<account>"
        )

        for rootEquivalent in ["/:/host:ro", "//:/host:ro", "/./:/host:ro", "/data/..:/host:ro"] {
            assertManifestFailure(
                """
                version: 2
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
            version: 2
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
            version: 2
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
            version: 2
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
            version: 2
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
            version: 2
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
        for field in ["dns", "dns_search", "domainname", "hostname", "network_mode", "networks", "aliases", "expose", "extra_hosts"] {
            assertManifestFailure(
                """
                version: 2
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
        let digest = String(repeating: "a", count: 64)

        for examplePath in examplePaths {
            let manifestText = try read(examplePath, root: root)
            let manifest = try ManifestValidator.validated(manifestText)
            XCTAssertEqual(manifest.version, 2, examplePath)
            XCTAssertFalse(manifestText.contains("apiVersion"), examplePath)
            XCTAssertFalse(manifestText.contains("depends_on"), examplePath)
            XCTAssertFalse(manifestText.contains("deploy:"), examplePath)
        }

        XCTAssertFalse(schema.contains(#""apiVersion""#))
        let allOf = try XCTUnwrap(schemaJSON["allOf"] as? [[String: Any]])
        XCTAssertEqual(allOf.count, 1)
        let imagePolicyRule = try XCTUnwrap(allOf.first)
        let ruleCondition = try XCTUnwrap(imagePolicyRule["if"] as? [String: Any])
        XCTAssertEqual(ruleCondition["required"] as? [String], ["imagePolicy"])
        let conditionProperties = try XCTUnwrap(ruleCondition["properties"] as? [String: Any])
        let conditionImagePolicy = try XCTUnwrap(conditionProperties["imagePolicy"] as? [String: Any])
        XCTAssertEqual(conditionImagePolicy["const"] as? String, "require-digest")
        let ruleThen = try XCTUnwrap(imagePolicyRule["then"] as? [String: Any])
        let thenProperties = try XCTUnwrap(ruleThen["properties"] as? [String: Any])
        let thenServices = try XCTUnwrap(thenProperties["services"] as? [String: Any])
        let thenAdditionalProperties = try XCTUnwrap(thenServices["additionalProperties"] as? [String: Any])
        let thenAllOf = try XCTUnwrap(thenAdditionalProperties["allOf"] as? [[String: Any]])
        XCTAssertEqual(thenAllOf.first?["$ref"] as? String, "#/$defs/service")
        let digestServiceOverlay = try XCTUnwrap(thenAllOf.last)
        let digestServiceProperties = try XCTUnwrap(digestServiceOverlay["properties"] as? [String: Any])
        let digestImage = try XCTUnwrap(digestServiceProperties["image"] as? [String: Any])
        let requireDigestPattern = try XCTUnwrap(digestImage["pattern"] as? String)
        XCTAssertTrue(matches("ghcr.io/example/api@sha256:\(digest)", pattern: requireDigestPattern))
        XCTAssertFalse(matches("ghcr.io/example/api:latest", pattern: requireDigestPattern))
        XCTAssertFalse(matches("ghcr.io/example/api@sha512:\(digest)", pattern: requireDigestPattern))

        let properties = try XCTUnwrap(schemaJSON["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["version", "project", "imagePolicy", "services"])
        let required = try XCTUnwrap(schemaJSON["required"] as? [String])
        XCTAssertEqual(required, ["version", "project", "services"])
        let version = try XCTUnwrap(properties["version"] as? [String: Any])
        XCTAssertEqual(version["const"] as? Int, HostwrightManifest.currentVersion)
        let project = try XCTUnwrap(properties["project"] as? [String: Any])
        XCTAssertEqual(project["$ref"] as? String, "#/$defs/name")
        let imagePolicy = try XCTUnwrap(properties["imagePolicy"] as? [String: Any])
        XCTAssertEqual(imagePolicy["enum"] as? [String], ["allow-tags", "require-digest"])
        let services = try XCTUnwrap(properties["services"] as? [String: Any])
        XCTAssertEqual(services["minProperties"] as? Int, 1)

        let definitions = try XCTUnwrap(schemaJSON["$defs"] as? [String: Any])
        let service = try XCTUnwrap(definitions["service"] as? [String: Any])
        XCTAssertEqual(service["required"] as? [String], ["image"])
        XCTAssertEqual(service["additionalProperties"] as? Bool, false)
        let serviceProperties = try XCTUnwrap(service["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(serviceProperties.keys),
            [
                "image", "replicas", "platform", "resources", "user", "group", "workdir",
                "entrypoint", "command", "init", "dependsOn", "env", "secretEnv", "labels",
                "ports", "volumes", "health", "probes", "restart", "update", "hooks",
                "rosetta", "virtualization", "readOnlyRootFilesystem", "shmSize"
            ]
        )
        let image = try XCTUnwrap(serviceProperties["image"] as? [String: Any])
        XCTAssertEqual(image["minLength"] as? Int, 1)
        let imagePattern = try XCTUnwrap(image["pattern"] as? String)
        XCTAssertEqual(imagePattern, #"^(?!-)(?!.*://)(?:[^@\s]+|[^@\s]+@sha256:[a-f0-9]{64})$"#)
        XCTAssertTrue(matches("ghcr.io/example/api:latest", pattern: imagePattern))
        XCTAssertTrue(matches("ghcr.io/example/api@sha256:\(digest)", pattern: imagePattern))
        XCTAssertFalse(matches("ghcr.io/example/api@sha512:\(digest)", pattern: imagePattern))
        XCTAssertFalse(matches("https://ghcr.io/example/api:latest", pattern: imagePattern))
        XCTAssertFalse(matches("-bad", pattern: imagePattern))
        let command = try XCTUnwrap(serviceProperties["command"] as? [String: Any])
        XCTAssertEqual(command["$ref"] as? String, "#/$defs/stringArray")
        let env = try XCTUnwrap(serviceProperties["env"] as? [String: Any])
        XCTAssertEqual(env["$ref"] as? String, "#/$defs/environment")
        let secretEnv = try XCTUnwrap(serviceProperties["secretEnv"] as? [String: Any])
        let secretEnvPropertyNames = try XCTUnwrap(secretEnv["propertyNames"] as? [String: Any])
        XCTAssertEqual(secretEnvPropertyNames["pattern"] as? String, #"^[A-Za-z_][A-Za-z0-9_]*$"#)
        let secretEnvValues = try XCTUnwrap(secretEnv["additionalProperties"] as? [String: Any])
        XCTAssertEqual(secretEnvValues["pattern"] as? String, #"^keychain://[A-Za-z0-9._:@-]+/[A-Za-z0-9._:@-]+$"#)
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
        let probesRef = try XCTUnwrap(serviceProperties["probes"] as? [String: Any])
        XCTAssertEqual(probesRef["$ref"] as? String, "#/$defs/probes")
        let updateRef = try XCTUnwrap(serviceProperties["update"] as? [String: Any])
        XCTAssertEqual(updateRef["$ref"] as? String, "#/$defs/update")
        let hooksRef = try XCTUnwrap(serviceProperties["hooks"] as? [String: Any])
        XCTAssertEqual(hooksRef["$ref"] as? String, "#/$defs/hooks")

        let health = try XCTUnwrap(definitions["health"] as? [String: Any])
        XCTAssertEqual(health["required"] as? [String], ["command"])
        XCTAssertEqual(health["additionalProperties"] as? Bool, false)
        let healthProperties = try XCTUnwrap(health["properties"] as? [String: Any])
        let healthCommand = try XCTUnwrap(healthProperties["command"] as? [String: Any])
        XCTAssertEqual(healthCommand["$ref"] as? String, "#/$defs/stringArray")
        let healthInterval = try XCTUnwrap(healthProperties["interval"] as? [String: Any])
        XCTAssertEqual(healthInterval["pattern"] as? String, #"^[1-9][0-9]*s$"#)

        let restart = try XCTUnwrap(definitions["restart"] as? [String: Any])
        XCTAssertEqual(restart["required"] as? [String], ["policy"])
        XCTAssertEqual(restart["additionalProperties"] as? Bool, false)
        let restartProperties = try XCTUnwrap(restart["properties"] as? [String: Any])
        let restartPolicy = try XCTUnwrap(restartProperties["policy"] as? [String: Any])
        XCTAssertEqual(restartPolicy["enum"] as? [String], ["no", "on-failure", "unless-stopped"])

        let probe = try XCTUnwrap(definitions["probe"] as? [String: Any])
        XCTAssertEqual(probe["additionalProperties"] as? Bool, false)
        XCTAssertEqual((probe["oneOf"] as? [[String: Any]])?.count, 3)
        let update = try XCTUnwrap(definitions["update"] as? [String: Any])
        XCTAssertEqual(update["additionalProperties"] as? Bool, false)
        let hooks = try XCTUnwrap(definitions["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["additionalProperties"] as? Bool, false)
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
    version: 2
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

    private func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
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
