import Foundation
import XCTest
@testable import HostwrightManifest
@testable import HostwrightSecrets

extension HostwrightManifestTests {
    func testValidManifestParsesAndValidates() throws {
        let manifest = try ManifestValidator.validated(Self.validManifest)

        XCTAssertEqual(manifest.version, 3)
        XCTAssertEqual(manifest.effectiveVersion, 3)
        XCTAssertNil(manifest.imagePolicy)
        XCTAssertEqual(manifest.effectiveImagePolicy, .allowTags)
        XCTAssertEqual(manifest.project, "api-local")
        XCTAssertEqual(manifest.services.count, 1)
        XCTAssertEqual(manifest.services[0].name, "api")
        XCTAssertEqual(manifest.services[0].ports, ["8080:8080"])
        XCTAssertEqual(
            manifest.services[0].publishedPorts,
            [
                HostwrightPublishedPort(
                    host: HostwrightPortSpan(start: 8080),
                    target: HostwrightPortSpan(start: 8080),
                    protocolName: .tcp,
                    bindAddress: HostwrightPublishedPort.localhostBindAddress,
                    legacyLiteral: "8080:8080"
                )
            ]
        )
        XCTAssertEqual(manifest.services[0].health?.interval, "10s")
        XCTAssertEqual(manifest.services[0].restart?.policy, "on-failure")
    }

    func testLegacyPortsCanonicalizeToStructuredMappings() throws {
        let manifest = try ManifestValidator.validated(Self.validManifest)
        let canonical = try ManifestCanonicalEncoder.encode(manifest)

        XCTAssertTrue(canonical.contains("ports:\n      - bind: \"127.0.0.1\""))
        XCTAssertTrue(canonical.contains("host: 8080"))
        XCTAssertTrue(canonical.contains("target: 8080"))
        XCTAssertTrue(canonical.contains("protocol: \"tcp\""))
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testStructuredPortsParseAndValidate() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                ports:
                  - bind: 127.0.0.1
                    host: 18080
                    target: 8080
                    protocol: tcp
                  - bind: "::1"
                    host: "19090-19091"
                    target: "9090-9091"
                    protocol: udp
            """
        )

        let publishedPorts = manifest.services[0].publishedPorts
        XCTAssertEqual(publishedPorts.count, 2)
        XCTAssertEqual(publishedPorts[0].hostPort, 18_080)
        XCTAssertEqual(publishedPorts[0].containerPort, 8_080)
        XCTAssertEqual(publishedPorts[0].protocolName, .tcp)
        XCTAssertEqual(publishedPorts[0].effectiveBindAddress, "127.0.0.1")
        XCTAssertEqual(publishedPorts[1].hostPortRange, 19_090 ... 19_091)
        XCTAssertEqual(publishedPorts[1].containerPortRange, 9_090 ... 9_091)
        XCTAssertEqual(publishedPorts[1].protocolName, .udp)
        XCTAssertEqual(publishedPorts[1].effectiveBindAddress, "::1")
        XCTAssertEqual(manifest.services[0].ports, ["18080:8080"])
    }

    func testSecretEnvironmentReferencesParseAndValidate() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                env:
                  APP_ENV: development
                secretEnv:
                  API_TOKEN: keychain://hostwright.api/api-token
                  ENV_VALUE: "env-file:///Users/dev/.config/hostwright/service.env#VALUE"
                  FILE_VALUE: local-file:///Users/dev/.config/hostwright/value
                  EXTERNAL_VALUE: external://vault/service-token
                  PLUGIN_VALUE: plugin://company-vault/service-token
            """
        )

        XCTAssertEqual(manifest.services[0].env["APP_ENV"], "development")
        let references = manifest.services[0].secretEnv
        let keychain = try XCTUnwrap(references["API_TOKEN"])
        XCTAssertEqual(keychain.providerKind, .keychain)
        XCTAssertEqual(keychain.service, "hostwright.api")
        XCTAssertEqual(keychain.account, "api-token")

        let environmentFile = try XCTUnwrap(references["ENV_VALUE"])
        XCTAssertEqual(environmentFile.providerKind, .environmentFile)
        XCTAssertEqual(environmentFile.service, "/Users/dev/.config/hostwright/service.env")
        XCTAssertEqual(environmentFile.account, "VALUE")

        let localFile = try XCTUnwrap(references["FILE_VALUE"])
        XCTAssertEqual(localFile.providerKind, .localFile)
        XCTAssertEqual(localFile.service, "/Users/dev/.config/hostwright/value")
        XCTAssertEqual(localFile.account, "")

        XCTAssertEqual(references["EXTERNAL_VALUE"]?.providerKind, .external)
        XCTAssertEqual(references["PLUGIN_VALUE"]?.providerKind, .plugin)

        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertEqual(
            try ManifestValidator.validated(canonical),
            manifest
        )
    }

    func testSecretEnvironmentReferenceFailuresAreRedactedAndListSupportedShapes() {
        let privatePath = "/Users/dev/private/customer-a/secret.env"
        let text = """
        version: 3
        project: api-local
        services:
          api:
            image: ghcr.io/example/api:latest
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
            secretEnv:
              API_TOKEN: "env-file://\(privatePath)#BAD-KEY"
        """

        XCTAssertThrowsError(try ManifestValidator.validated(text)) { error in
            guard let manifestError = error as? ManifestParseError else {
                return XCTFail("Expected ManifestParseError, got \(error).")
            }
            let messages = manifestError.issues.map(\.message).joined(separator: "\n")
            for shape in [
                "keychain://<service>/<account>",
                "env-file:///absolute/path#KEY",
                "local-file:///absolute/path",
                "external://<provider>/<item>",
                "plugin://<provider>/<item>"
            ] {
                XCTAssertTrue(messages.contains(shape), messages)
            }
            XCTAssertFalse(messages.contains(privatePath), messages)
        }
    }

    func testSupportedSecretReferencesCannotBePlacedInLiteralEnvironment() {
        let references = [
            "keychain://hostwright.api/api-token",
            "env-file:///Users/dev/.config/hostwright/service.env#VALUE",
            "local-file:///Users/dev/.config/hostwright/value",
            "external://vault/service-token",
            "plugin://company-vault/service-token"
        ]

        for (index, reference) in references.enumerated() {
            assertManifestFailure(
                """
                version: 3
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    resources:
                      requests: {cpus: 1, memory: 512MiB}
                      limits: {cpus: 1, memory: 512MiB}
                    env:
                      SOURCE_\(index): "\(reference)"
                """,
                contains: "move it to secretEnv"
            )
        }
    }

    func testQuotedScalarsAndInlineArraysPreserveCommasAndEscapes() throws {
        let manifest = try ManifestValidator.validated(
            #"""
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
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
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
        """
        let parsed = try ManifestParser.parse(text)

        XCTAssertNil(parsed.version)
        XCTAssertEqual(parsed.effectiveVersion, HostwrightManifest.legacyVersion)
        assertManifestFailure(text, code: "HW-MANIFEST-003", contains: "must declare version: 3")
    }

    func testExplicitOlderAndNewerManifestVersionsFailClosed() {
        assertManifestFailure(
            """
            version: 1
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            code: "HW-MANIFEST-003",
            contains: "older than supported version 3"
        )

        assertManifestFailure(
            """
            version: 4
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            code: "HW-MANIFEST-003",
            contains: "newer than supported version 3"
        )
    }

    func testImagePolicyRequiresDigestPinnedImagesWhenConfigured() throws {
        let digest = String(repeating: "a", count: 64)
        let manifest = try ManifestValidator.validated(
            """
            version: 3
            project: api-local
            imagePolicy: require-digest
            services:
              api:
                image: ghcr.io/example/api@sha256:\(digest)
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """
        )

        XCTAssertEqual(manifest.imagePolicy, .requireDigest)
        XCTAssertEqual(manifest.effectiveImagePolicy, .requireDigest)
        XCTAssertEqual(manifest.services[0].image, "ghcr.io/example/api@sha256:\(digest)")

        XCTAssertNoThrow(
            try ManifestValidator.validated(
                """
                version: 3
                project: api-local
                imagePolicy: allow-tags
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    resources:
                      requests: {cpus: 1, memory: 512MiB}
                      limits: {cpus: 1, memory: 512MiB}
                """
            )
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            imagePolicy: require-digest
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "requires image 'ghcr.io/example/api:latest' to be digest-pinned"
        )
    }

    func testImageDigestSyntaxFailsClosedWithoutRegistryLookup() {
        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api@sha512:abcdef
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "image digest must use @sha256:<64 lowercase hex characters>"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api@sha256:ABCDEF
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "image digest must use @sha256:<64 lowercase hex characters>"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: https://ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "must be an OCI-style image reference"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            imagePolicy: content-trust
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imagePolicy must be one of"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            imagePolicy: require-digest
            imagePolicy: allow-tags
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imagePolicy must be declared at most once"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            imagePolicy: content-trust
            imagePolicy: require-digest
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "project"
        )
    }

    func testMissingImageFailsValidation() {
        assertManifestFailure(
            """
            version: 3
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
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                ports:
                  - "not-a-port"
            """,
            contains: "host:container"
        )
    }

    func testFlagLikeImagesFailWhileCommandArgumentsRemainExecutable() throws {
        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: --mount=src=/,dst=/host
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "image must not begin"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: -bad
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "image must not begin"
        )

        let manifest = try ManifestValidator.validated(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                command: ["--flag"]
            """
        )
        XCTAssertEqual(manifest.services[0].command, ["--flag"])
    }

    func testEnvironmentKeysAndUnsafeVolumesFailValidation() {
        XCTAssertNoThrow(
            try ManifestValidator.validated(
                """
                version: 3
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    resources:
                      requests: {cpus: 1, memory: 512MiB}
                      limits: {cpus: 1, memory: 512MiB}
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
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                env:
                  1TOKEN: value
            """,
            contains: "environment key"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                env:
                  API-TOKEN: value
            """,
            contains: "environment key"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                env:
                  API_TOKEN: token=plaintext
            """,
            contains: "plaintext sensitive values must use secretEnv"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                env:
                  API_TOKEN: keychain://hostwright.api/api-token
            """,
            contains: "move it to secretEnv"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                env:
                  API_TOKEN: literal
                secretEnv:
                  API_TOKEN: keychain://hostwright.api/api-token
            """,
            contains: "must not appear in both env and secretEnv"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                secretEnv:
                  API_TOKEN: env://hostwright.api/api-token
            """,
            contains: "keychain://<service>/<account>"
        )

        for rootEquivalent in ["/:/host:ro", "//:/host:ro", "/./:/host:ro", "/data/..:/host:ro"] {
            assertManifestFailure(
                """
                version: 3
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    resources:
                      requests: {cpus: 1, memory: 512MiB}
                      limits: {cpus: 1, memory: 512MiB}
                    volumes:
                      - "\(rootEquivalent)"
                """,
                contains: "must not mount the host root"
            )
        }

        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
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
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            code: "HW-MANIFEST-003",
            contains: "Unsupported top-level manifest field 'apiVersion'"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                build: .
            """,
            code: "HW-MANIFEST-003",
            contains: "Unsupported service field 'build'"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                health:
                  command: ["curl", "-f", "http://localhost:8080/health"]
                  timeout: 5s
            """,
            code: "HW-MANIFEST-003",
            contains: "Unsupported health field 'timeout'"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                restart:
                  policy: on-failure
                  burstLimit: 3
            """,
            code: "HW-MANIFEST-003",
            contains: "Unsupported restart field 'burstLimit'"
        )
    }

    func testUnsupportedNetworkingAndDiscoveryFieldsFailClosed() {
        for field in ["dns", "dns_search", "domainname", "hostname", "network_mode", "aliases", "expose", "extra_hosts"] {
            assertManifestFailure(
                """
                version: 3
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    resources:
                      requests: {cpus: 1, memory: 512MiB}
                      limits: {cpus: 1, memory: 512MiB}
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
            XCTAssertEqual(manifest.version, 3, examplePath)
            XCTAssertFalse(manifestText.contains("apiVersion"), examplePath)
            XCTAssertFalse(manifestText.contains("depends_on"), examplePath)
            XCTAssertFalse(manifestText.contains("deploy:"), examplePath)
        }

        XCTAssertFalse(schema.contains(#""apiVersion""#))
        let allOf = try XCTUnwrap(schemaJSON["allOf"] as? [[String: Any]])
        XCTAssertEqual(allOf.count, 5)
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
        let imageTrustRule = try XCTUnwrap(allOf[1])
        let imageTrustCondition = try XCTUnwrap(imageTrustRule["if"] as? [String: Any])
        XCTAssertEqual(imageTrustCondition["required"] as? [String], ["imageTrust"])
        let imageTrustThen = try XCTUnwrap(imageTrustRule["then"] as? [String: Any])
        XCTAssertEqual(imageTrustThen["required"] as? [String], ["imagePolicy"])
        let imageTrustThenProperties = try XCTUnwrap(imageTrustThen["properties"] as? [String: Any])
        let imageTrustThenImagePolicy = try XCTUnwrap(imageTrustThenProperties["imagePolicy"] as? [String: Any])
        XCTAssertEqual(imageTrustThenImagePolicy["const"] as? String, "require-digest")
        let imageSBOMRule = try XCTUnwrap(allOf[2])
        let imageSBOMCondition = try XCTUnwrap(imageSBOMRule["if"] as? [String: Any])
        XCTAssertEqual(imageSBOMCondition["required"] as? [String], ["imageSBOM"])
        let imageSBOMThen = try XCTUnwrap(imageSBOMRule["then"] as? [String: Any])
        XCTAssertEqual(imageSBOMThen["required"] as? [String], ["imagePolicy"])
        let imageSBOMThenProperties = try XCTUnwrap(imageSBOMThen["properties"] as? [String: Any])
        let imageSBOMThenImagePolicy = try XCTUnwrap(imageSBOMThenProperties["imagePolicy"] as? [String: Any])
        XCTAssertEqual(imageSBOMThenImagePolicy["const"] as? String, "require-digest")
        let imageVulnerabilityRule = try XCTUnwrap(allOf[3])
        let imageVulnerabilityCondition = try XCTUnwrap(imageVulnerabilityRule["if"] as? [String: Any])
        XCTAssertEqual(imageVulnerabilityCondition["required"] as? [String], ["imageVulnerability"])
        let imageVulnerabilityThen = try XCTUnwrap(imageVulnerabilityRule["then"] as? [String: Any])
        XCTAssertEqual(
            imageVulnerabilityThen["required"] as? [String],
            ["imagePolicy", "imageTrust"]
        )
        let imageVulnerabilityThenProperties = try XCTUnwrap(
            imageVulnerabilityThen["properties"] as? [String: Any]
        )
        let imageVulnerabilityThenImagePolicy = try XCTUnwrap(
            imageVulnerabilityThenProperties["imagePolicy"] as? [String: Any]
        )
        XCTAssertEqual(imageVulnerabilityThenImagePolicy["const"] as? String, "require-digest")
        let imageProvenanceRule = try XCTUnwrap(allOf[4])
        let imageProvenanceCondition = try XCTUnwrap(
            imageProvenanceRule["if"] as? [String: Any]
        )
        XCTAssertEqual(imageProvenanceCondition["required"] as? [String], ["imageProvenance"])
        let imageProvenanceThen = try XCTUnwrap(
            imageProvenanceRule["then"] as? [String: Any]
        )
        XCTAssertEqual(imageProvenanceThen["required"] as? [String], ["imagePolicy"])
        let imageProvenanceThenProperties = try XCTUnwrap(
            imageProvenanceThen["properties"] as? [String: Any]
        )
        XCTAssertEqual(
            (imageProvenanceThenProperties["imagePolicy"] as? [String: Any])?["const"] as? String,
            "require-digest"
        )

        let properties = try XCTUnwrap(schemaJSON["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(properties.keys),
            [
                "version", "project", "imagePolicy", "imageTrust", "imageSBOM",
                "imageVulnerability", "imageProvenance", "volumes", "networks",
                "certificates", "ingress", "tunnels", "restartBudget",
                "maintenance", "retention", "services"
            ]
        )
        let required = try XCTUnwrap(schemaJSON["required"] as? [String])
        XCTAssertEqual(required, ["version", "project", "services"])
        let version = try XCTUnwrap(properties["version"] as? [String: Any])
        XCTAssertEqual(version["const"] as? Int, HostwrightManifest.currentVersion)
        let project = try XCTUnwrap(properties["project"] as? [String: Any])
        XCTAssertEqual(project["$ref"] as? String, "#/$defs/name")
        let imagePolicy = try XCTUnwrap(properties["imagePolicy"] as? [String: Any])
        XCTAssertEqual(imagePolicy["enum"] as? [String], ["allow-tags", "require-digest"])
        let imageTrust = try XCTUnwrap(properties["imageTrust"] as? [String: Any])
        XCTAssertEqual(imageTrust["$ref"] as? String, "#/$defs/imageTrust")
        let imageSBOM = try XCTUnwrap(properties["imageSBOM"] as? [String: Any])
        XCTAssertEqual(imageSBOM["$ref"] as? String, "#/$defs/imageSBOM")
        let imageVulnerability = try XCTUnwrap(properties["imageVulnerability"] as? [String: Any])
        XCTAssertEqual(imageVulnerability["$ref"] as? String, "#/$defs/imageVulnerability")
        let imageProvenance = try XCTUnwrap(properties["imageProvenance"] as? [String: Any])
        XCTAssertEqual(imageProvenance["$ref"] as? String, "#/$defs/imageProvenance")
        let maintenanceRef = try XCTUnwrap(properties["maintenance"] as? [String: Any])
        XCTAssertEqual(maintenanceRef["$ref"] as? String, "#/$defs/maintenance")
        let retentionRef = try XCTUnwrap(properties["retention"] as? [String: Any])
        XCTAssertEqual(retentionRef["$ref"] as? String, "#/$defs/retention")
        let volumes = try XCTUnwrap(properties["volumes"] as? [String: Any])
        XCTAssertEqual(volumes["$ref"] as? String, "#/$defs/volumeDeclarations")
        let services = try XCTUnwrap(properties["services"] as? [String: Any])
        XCTAssertEqual(services["minProperties"] as? Int, 1)

        let definitions = try XCTUnwrap(schemaJSON["$defs"] as? [String: Any])
        XCTAssertNotNil(definitions["normalizedAbsoluteHostPath"])
        XCTAssertNotNil(definitions["safeAuthorityID"])
        XCTAssertNotNil(definitions["httpsURL"])
        XCTAssertNotNil(definitions["rfc3339Timestamp"])
        XCTAssertNotNil(definitions["provenanceURI"])
        XCTAssertNotNil(definitions["provenanceSignerID"])
        XCTAssertNotNil(definitions["boundedNormalizedAbsoluteHostPath"])
        XCTAssertNotNil(definitions["mount"])
        XCTAssertNotNil(definitions["bindMount"])
        XCTAssertNotNil(definitions["volumeMount"])
        XCTAssertNotNil(definitions["tmpfsMount"])
        XCTAssertNotNil(definitions["providerID"])
        XCTAssertNotNil(definitions["labels"])
        XCTAssertNotNil(definitions["volumeDeclarations"])
        XCTAssertNotNil(definitions["volumeDeclaration"])
        let imageTrustDef = try XCTUnwrap(definitions["imageTrust"] as? [String: Any])
        XCTAssertEqual(imageTrustDef["required"] as? [String], ["threshold", "authorities"])
        XCTAssertEqual(imageTrustDef["additionalProperties"] as? Bool, false)
        let imageTrustProperties = try XCTUnwrap(imageTrustDef["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(imageTrustProperties.keys),
            ["version", "threshold", "trustedRoot", "authorities"]
        )
        let imageTrustVersion = try XCTUnwrap(imageTrustProperties["version"] as? [String: Any])
        XCTAssertEqual(imageTrustVersion["const"] as? Int, 1)
        let imageTrustThreshold = try XCTUnwrap(imageTrustProperties["threshold"] as? [String: Any])
        XCTAssertEqual(imageTrustThreshold["minimum"] as? Int, 1)
        XCTAssertEqual(imageTrustThreshold["maximum"] as? Int, 8)
        let trustedRoot = try XCTUnwrap(imageTrustProperties["trustedRoot"] as? [String: Any])
        XCTAssertEqual(trustedRoot["$ref"] as? String, "#/$defs/normalizedAbsoluteHostPath")
        let authorities = try XCTUnwrap(imageTrustProperties["authorities"] as? [String: Any])
        XCTAssertEqual(authorities["minItems"] as? Int, 1)
        XCTAssertEqual(authorities["maxItems"] as? Int, 8)
        let authorityItems = try XCTUnwrap(authorities["items"] as? [String: Any])
        XCTAssertEqual(authorityItems["$ref"] as? String, "#/$defs/imageTrustAuthority")
        let imageTrustAllOf = try XCTUnwrap(imageTrustDef["allOf"] as? [[String: Any]])
        XCTAssertEqual(imageTrustAllOf.count, 1)
        let keylessTrustedRootRule = try XCTUnwrap(imageTrustAllOf.first)
        let keylessTrustedRootThen = try XCTUnwrap(keylessTrustedRootRule["then"] as? [String: Any])
        XCTAssertEqual(keylessTrustedRootThen["required"] as? [String], ["trustedRoot"])

        let authorityDef = try XCTUnwrap(definitions["imageTrustAuthority"] as? [String: Any])
        XCTAssertEqual(authorityDef["required"] as? [String], ["id", "type"])
        XCTAssertEqual(authorityDef["additionalProperties"] as? Bool, false)
        XCTAssertEqual((authorityDef["oneOf"] as? [[String: Any]])?.count, 2)
        let authorityProperties = try XCTUnwrap(authorityDef["properties"] as? [String: Any])
        XCTAssertEqual(Set(authorityProperties.keys), ["id", "type", "publicKey", "issuer", "identity", "notBefore", "notAfter", "revokedAt"])
        let authorityID = try XCTUnwrap(authorityProperties["id"] as? [String: Any])
        XCTAssertEqual(authorityID["$ref"] as? String, "#/$defs/safeAuthorityID")
        let authorityType = try XCTUnwrap(authorityProperties["type"] as? [String: Any])
        XCTAssertEqual(authorityType["enum"] as? [String], ["keyed", "keyless"])
        let authorityPublicKey = try XCTUnwrap(authorityProperties["publicKey"] as? [String: Any])
        XCTAssertEqual(authorityPublicKey["$ref"] as? String, "#/$defs/normalizedAbsoluteHostPath")
        let authorityIssuer = try XCTUnwrap(authorityProperties["issuer"] as? [String: Any])
        XCTAssertEqual(authorityIssuer["$ref"] as? String, "#/$defs/httpsURL")
        let authorityIdentity = try XCTUnwrap(authorityProperties["identity"] as? [String: Any])
        XCTAssertEqual(authorityIdentity["minLength"] as? Int, 1)
        XCTAssertEqual(authorityIdentity["maxLength"] as? Int, 512)
        let authorityTimestamp = try XCTUnwrap(authorityProperties["notBefore"] as? [String: Any])
        XCTAssertEqual(authorityTimestamp["$ref"] as? String, "#/$defs/rfc3339Timestamp")
        let imageSBOMDef = try XCTUnwrap(definitions["imageSBOM"] as? [String: Any])
        XCTAssertEqual(imageSBOMDef["required"] as? [String], ["requirement", "formats"])
        XCTAssertEqual(imageSBOMDef["additionalProperties"] as? Bool, false)
        let imageSBOMProperties = try XCTUnwrap(imageSBOMDef["properties"] as? [String: Any])
        XCTAssertEqual(Set(imageSBOMProperties.keys), ["version", "requirement", "formats"])
        let imageSBOMVersion = try XCTUnwrap(imageSBOMProperties["version"] as? [String: Any])
        XCTAssertEqual(imageSBOMVersion["const"] as? Int, 1)
        let imageSBOMRequirement = try XCTUnwrap(imageSBOMProperties["requirement"] as? [String: Any])
        XCTAssertEqual(imageSBOMRequirement["enum"] as? [String], ["optional", "required"])
        let imageSBOMFormats = try XCTUnwrap(imageSBOMProperties["formats"] as? [String: Any])
        XCTAssertEqual(imageSBOMFormats["minItems"] as? Int, 1)
        XCTAssertEqual(imageSBOMFormats["maxItems"] as? Int, 2)
        XCTAssertEqual(imageSBOMFormats["uniqueItems"] as? Bool, true)
        let imageSBOMFormatItems = try XCTUnwrap(imageSBOMFormats["items"] as? [String: Any])
        XCTAssertEqual(imageSBOMFormatItems["enum"] as? [String], ["spdx-json", "cyclonedx-json"])
        let imageVulnerabilityDef = try XCTUnwrap(
            definitions["imageVulnerability"] as? [String: Any]
        )
        XCTAssertEqual(
            imageVulnerabilityDef["required"] as? [String],
            [
                "severityThreshold", "minimumVulnerabilityAgeSeconds", "exploitability",
                "fixAvailability", "maximumDatabaseAgeSeconds", "staleAction",
                "unavailableAction", "exceptionApproval"
            ]
        )
        XCTAssertEqual(imageVulnerabilityDef["additionalProperties"] as? Bool, false)
        let imageVulnerabilityProperties = try XCTUnwrap(
            imageVulnerabilityDef["properties"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(imageVulnerabilityProperties.keys),
            [
                "version", "severityThreshold", "minimumVulnerabilityAgeSeconds",
                "exploitability", "fixAvailability", "maximumDatabaseAgeSeconds",
                "staleAction", "unavailableAction", "exceptionApproval", "allowlist"
            ]
        )
        XCTAssertEqual(
            (imageVulnerabilityProperties["version"] as? [String: Any])?["const"] as? Int,
            1
        )
        XCTAssertEqual(
            (imageVulnerabilityProperties["severityThreshold"] as? [String: Any])?["enum"] as? [String],
            ["low", "medium", "high", "critical"]
        )
        XCTAssertEqual(
            (imageVulnerabilityProperties["minimumVulnerabilityAgeSeconds"] as? [String: Any])?["maximum"] as? Int,
            HostwrightImageVulnerabilityPolicy.maximumMinimumVulnerabilityAgeSeconds
        )
        XCTAssertEqual(
            (imageVulnerabilityProperties["maximumDatabaseAgeSeconds"] as? [String: Any])?["minimum"] as? Int,
            HostwrightImageVulnerabilityPolicy.minimumMaximumDatabaseAgeSeconds
        )
        XCTAssertEqual(
            (imageVulnerabilityProperties["maximumDatabaseAgeSeconds"] as? [String: Any])?["maximum"] as? Int,
            HostwrightImageVulnerabilityPolicy.maximumMaximumDatabaseAgeSeconds
        )
        XCTAssertEqual(
            (imageVulnerabilityProperties["staleAction"] as? [String: Any])?["enum"] as? [String],
            ["fail-open", "fail-closed"]
        )
        XCTAssertEqual(
            (imageVulnerabilityProperties["exceptionApproval"] as? [String: Any])?["enum"] as? [String],
            ["required", "disabled"]
        )
        let imageVulnerabilityAllowlist = try XCTUnwrap(
            imageVulnerabilityProperties["allowlist"] as? [String: Any]
        )
        XCTAssertEqual(
            imageVulnerabilityAllowlist["maxItems"] as? Int,
            HostwrightImageVulnerabilityPolicy.maximumAllowlistEntries
        )
        XCTAssertEqual(imageVulnerabilityAllowlist["uniqueItems"] as? Bool, true)
        let imageVulnerabilityAllowlistEntry = try XCTUnwrap(
            definitions["imageVulnerabilityAllowlistEntry"] as? [String: Any]
        )
        XCTAssertEqual(
            imageVulnerabilityAllowlistEntry["required"] as? [String],
            ["vulnerabilityID", "reason", "expiresAt"]
        )
        XCTAssertEqual(imageVulnerabilityAllowlistEntry["additionalProperties"] as? Bool, false)

        let imageProvenanceDef = try XCTUnwrap(
            definitions["imageProvenance"] as? [String: Any]
        )
        XCTAssertEqual(
            imageProvenanceDef["required"] as? [String],
            [
                "requirement", "builderIDs", "buildTypes", "signers",
                "maximumAgeSeconds", "requireReproducible"
            ]
        )
        XCTAssertEqual(imageProvenanceDef["additionalProperties"] as? Bool, false)
        let imageProvenanceProperties = try XCTUnwrap(
            imageProvenanceDef["properties"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(imageProvenanceProperties.keys),
            [
                "version", "requirement", "builderIDs", "buildTypes", "signers",
                "maximumAgeSeconds", "requireReproducible"
            ]
        )
        XCTAssertEqual(
            (imageProvenanceProperties["version"] as? [String: Any])?["const"] as? Int,
            HostwrightImageProvenancePolicy.currentVersion
        )
        XCTAssertEqual(
            (imageProvenanceProperties["requirement"] as? [String: Any])?["enum"] as? [String],
            ["optional", "required"]
        )
        for field in ["builderIDs", "buildTypes"] {
            let values = try XCTUnwrap(
                imageProvenanceProperties[field] as? [String: Any]
            )
            XCTAssertEqual(values["minItems"] as? Int, 1)
            XCTAssertEqual(values["maxItems"] as? Int, 16)
            XCTAssertEqual(values["uniqueItems"] as? Bool, true)
            XCTAssertEqual(
                (values["items"] as? [String: Any])?["$ref"] as? String,
                "#/$defs/provenanceURI"
            )
        }
        let provenanceSigners = try XCTUnwrap(
            imageProvenanceProperties["signers"] as? [String: Any]
        )
        XCTAssertEqual(provenanceSigners["minItems"] as? Int, 1)
        XCTAssertEqual(
            provenanceSigners["maxItems"] as? Int,
            HostwrightImageProvenancePolicy.maximumSigners
        )
        XCTAssertEqual(provenanceSigners["uniqueItems"] as? Bool, true)
        XCTAssertEqual(
            (provenanceSigners["items"] as? [String: Any])?["$ref"] as? String,
            "#/$defs/imageProvenanceSigner"
        )
        let maximumAgeSeconds = try XCTUnwrap(
            imageProvenanceProperties["maximumAgeSeconds"] as? [String: Any]
        )
        XCTAssertEqual(
            maximumAgeSeconds["minimum"] as? Int,
            HostwrightImageProvenancePolicy.minimumMaximumAgeSeconds
        )
        XCTAssertEqual(
            maximumAgeSeconds["maximum"] as? Int,
            HostwrightImageProvenancePolicy.maximumMaximumAgeSeconds
        )
        XCTAssertEqual(
            (imageProvenanceProperties["requireReproducible"] as? [String: Any])?["type"] as? String,
            "boolean"
        )
        let provenanceURI = try XCTUnwrap(definitions["provenanceURI"] as? [String: Any])
        XCTAssertEqual(
            provenanceURI["maxLength"] as? Int,
            HostwrightImageProvenancePolicy.maximumURIUTF8Bytes
        )
        let provenanceURIPattern = try XCTUnwrap(provenanceURI["pattern"] as? String)
        XCTAssertTrue(matches("urn:hostwright:builder:release", pattern: provenanceURIPattern))
        XCTAssertTrue(matches("https://build.example.com/builder", pattern: provenanceURIPattern))
        XCTAssertFalse(matches("https://user@example.com/builder", pattern: provenanceURIPattern))
        XCTAssertFalse(matches("urn:hostwright:build..type", pattern: provenanceURIPattern))
        let provenanceSignerID = try XCTUnwrap(
            definitions["provenanceSignerID"] as? [String: Any]
        )
        XCTAssertEqual(
            provenanceSignerID["maxLength"] as? Int,
            HostwrightImageProvenancePolicy.maximumSignerIDUTF8Bytes
        )
        let provenancePublicKey = try XCTUnwrap(
            definitions["boundedNormalizedAbsoluteHostPath"] as? [String: Any]
        )
        XCTAssertEqual(
            provenancePublicKey["maxLength"] as? Int,
            HostwrightImageProvenancePolicy.maximumPublicKeyUTF8Bytes
        )
        let imageProvenanceSigner = try XCTUnwrap(
            definitions["imageProvenanceSigner"] as? [String: Any]
        )
        XCTAssertEqual(imageProvenanceSigner["required"] as? [String], ["id", "publicKey"])
        XCTAssertEqual(imageProvenanceSigner["additionalProperties"] as? Bool, false)
        let imageProvenanceSignerProperties = try XCTUnwrap(
            imageProvenanceSigner["properties"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(imageProvenanceSignerProperties.keys),
            ["id", "publicKey", "notBefore", "notAfter", "revokedAt"]
        )
        XCTAssertEqual(
            (imageProvenanceSignerProperties["id"] as? [String: Any])?["$ref"] as? String,
            "#/$defs/provenanceSignerID"
        )
        XCTAssertEqual(
            (imageProvenanceSignerProperties["publicKey"] as? [String: Any])?["$ref"] as? String,
            "#/$defs/boundedNormalizedAbsoluteHostPath"
        )
        XCTAssertEqual(
            (imageProvenanceSignerProperties["notBefore"] as? [String: Any])?["$ref"] as? String,
            "#/$defs/rfc3339Timestamp"
        )

        let service = try XCTUnwrap(definitions["service"] as? [String: Any])
        XCTAssertEqual(service["required"] as? [String], ["image"])
        XCTAssertEqual(service["additionalProperties"] as? Bool, false)
        let serviceProperties = try XCTUnwrap(service["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(serviceProperties.keys),
            [
                "image", "replicas", "platform", "resources", "scheduling", "user", "group", "workdir",
                "entrypoint", "command", "init", "dependsOn", "env", "secretEnv", "labels",
                "ports", "hostAccess", "networks", "volumes", "health", "probes",
                "networkPolicy", "restart", "update", "hooks",
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
        XCTAssertEqual(secretEnvValues["$ref"] as? String, "#/$defs/secretReference")
        let secretReference = try XCTUnwrap(definitions["secretReference"] as? [String: Any])
        XCTAssertEqual(secretReference["type"] as? String, "string")
        let secretReferenceChoices = try XCTUnwrap(secretReference["oneOf"] as? [[String: Any]])
        XCTAssertEqual(secretReferenceChoices.count, HostwrightSecretProviderKind.allCases.count)
        let secretReferencePatterns = try secretReferenceChoices.map {
            try XCTUnwrap($0["pattern"] as? String)
        }
        for value in [
            "keychain://hostwright.api/api-token",
            "env-file:///Users/dev/.config/hostwright/service.env#VALUE",
            "local-file:///Users/dev/.config/hostwright/value",
            "external://vault/service-token",
            "plugin://company-vault/service-token"
        ] {
            XCTAssertEqual(
                secretReferencePatterns.filter { matches(value, pattern: $0) }.count,
                1,
                value
            )
        }
        for value in [
            "env://hostwright.api/api-token",
            "keychain://hostwright.api/",
            "env-file:///Users/dev/../private.env#VALUE",
            "env-file:///Users/dev/private.env#BAD-KEY",
            "local-file:///Users/dev/../private-value",
            "external://vault/service/token",
            "external://vault:prod/token",
            "plugin://-provider/token",
            "plugin://company-vault/"
        ] {
            XCTAssertFalse(
                secretReferencePatterns.contains { matches(value, pattern: $0) },
                value
            )
        }
        let ports = try XCTUnwrap(serviceProperties["ports"] as? [String: Any])
        let portItems = try XCTUnwrap(ports["items"] as? [String: Any])
        let portChoices = try XCTUnwrap(portItems["oneOf"] as? [[String: Any]])
        XCTAssertEqual(portChoices.count, 3)
        XCTAssertEqual(portChoices[0]["pattern"] as? String, #"^[0-9]{1,5}:[0-9]{1,5}$"#)
        let structuredPort = portChoices[1]
        XCTAssertEqual(structuredPort["type"] as? String, "object")
        XCTAssertEqual(structuredPort["required"] as? [String], ["target"])
        let structuredPortProperties = try XCTUnwrap(structuredPort["properties"] as? [String: Any])
        XCTAssertEqual((structuredPortProperties["protocol"] as? [String: Any])?["enum"] as? [String], ["tcp", "udp"])
        let unixSocket = portChoices[2]
        XCTAssertEqual(unixSocket["type"] as? String, "object")
        XCTAssertEqual(
            unixSocket["required"] as? [String],
            ["target", "protocol"]
        )
        let unixSocketProperties = try XCTUnwrap(
            unixSocket["properties"] as? [String: Any]
        )
        XCTAssertEqual(
            (unixSocketProperties["protocol"] as? [String: Any])?["const"]
                as? String,
            "unix"
        )
        XCTAssertEqual(
            (unixSocketProperties["mode"] as? [String: Any])?["enum"]
                as? [String],
            ["0600", "0660"]
        )
        let hostAccess = try XCTUnwrap(
            serviceProperties["hostAccess"] as? [String: Any]
        )
        XCTAssertEqual(hostAccess["maxItems"] as? Int, 64)
        XCTAssertEqual(
            (hostAccess["items"] as? [String: Any])?["$ref"] as? String,
            "#/$defs/hostAccessEndpoint"
        )
        let hostAccessEndpoint = try XCTUnwrap(
            definitions["hostAccessEndpoint"] as? [String: Any]
        )
        XCTAssertEqual(
            hostAccessEndpoint["required"] as? [String],
            ["hostname", "protocol", "addressClass", "port"]
        )
        let serviceNetworks = try XCTUnwrap(
            serviceProperties["networks"] as? [String: Any]
        )
        XCTAssertEqual(
            (serviceNetworks["items"] as? [String: Any])?["$ref"] as? String,
            "#/$defs/serviceNetworkAttachment"
        )
        let serviceVolumes = try XCTUnwrap(serviceProperties["volumes"] as? [String: Any])
        let volumeItems = try XCTUnwrap(serviceVolumes["items"] as? [String: Any])
        let volumeChoices = try XCTUnwrap(volumeItems["oneOf"] as? [[String: Any]])
        XCTAssertEqual(volumeChoices.count, 2)
        XCTAssertEqual(volumeChoices[0]["pattern"] as? String, #"^(?!/+(?:\./*)*:)(?![^:]*(?:^|/)\.\.(?:/|:)).+:/[^:]+(:ro|:rw)?$"#)
        XCTAssertEqual(volumeChoices[1]["$ref"] as? String, "#/$defs/mount")
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
        XCTAssertEqual(Set(restartProperties.keys), ["policy", "maxAttempts", "window", "backoff", "maxBackoff", "jitter", "stableRun", "priority"])
        XCTAssertEqual((restartProperties["maxAttempts"] as? [String: Any])?["maximum"] as? Int, 100)
        let restartBudget = try XCTUnwrap(definitions["restartBudget"] as? [String: Any])
        XCTAssertEqual(restartBudget["additionalProperties"] as? Bool, false)
        let maintenance = try XCTUnwrap(definitions["maintenance"] as? [String: Any])
        XCTAssertEqual(maintenance["required"] as? [String], ["timezone", "windows"])
        XCTAssertEqual(maintenance["additionalProperties"] as? Bool, false)
        let maintenanceProperties = try XCTUnwrap(maintenance["properties"] as? [String: Any])
        XCTAssertEqual(Set(maintenanceProperties.keys), ["timezone", "maximumDeferral", "windows"])
        XCTAssertEqual((maintenanceProperties["windows"] as? [String: Any])?["maxItems"] as? Int, 64)
        let maintenanceWindow = try XCTUnwrap(definitions["maintenanceWindow"] as? [String: Any])
        XCTAssertEqual(maintenanceWindow["required"] as? [String], ["id", "actions"])
        XCTAssertEqual(maintenanceWindow["additionalProperties"] as? Bool, false)
        XCTAssertEqual((maintenanceWindow["oneOf"] as? [[String: Any]])?.count, 2)
        let maintenanceWindowProperties = try XCTUnwrap(maintenanceWindow["properties"] as? [String: Any])
        XCTAssertEqual(
            ((maintenanceWindowProperties["actions"] as? [String: Any])?["items"] as? [String: Any])?["enum"] as? [String],
            ["create", "start", "restart", "update", "remove"]
        )
        let recurringMaintenanceWindow = try XCTUnwrap(
            definitions["recurringMaintenanceWindow"] as? [String: Any]
        )
        XCTAssertEqual(recurringMaintenanceWindow["additionalProperties"] as? Bool, false)
        let oneShotMaintenanceWindow = try XCTUnwrap(
            definitions["oneShotMaintenanceWindow"] as? [String: Any]
        )
        XCTAssertEqual(oneShotMaintenanceWindow["additionalProperties"] as? Bool, false)
        let retention = try XCTUnwrap(definitions["retention"] as? [String: Any])
        XCTAssertEqual(
            retention["required"] as? [String],
            ["recoveryHorizon", "maximumDatabaseBytes", "targetDatabaseBytes", "classes"]
        )
        XCTAssertEqual(retention["additionalProperties"] as? Bool, false)
        let retentionClasses = try XCTUnwrap(definitions["retentionClasses"] as? [String: Any])
        XCTAssertEqual((retentionClasses["required"] as? [String])?.count, 10)
        XCTAssertEqual(retentionClasses["additionalProperties"] as? Bool, false)
        let retentionHold = try XCTUnwrap(definitions["retentionHold"] as? [String: Any])
        XCTAssertEqual(retentionHold["required"] as? [String], ["id", "class", "selector", "reason"])
        XCTAssertEqual(retentionHold["additionalProperties"] as? Bool, false)

        let mount = try XCTUnwrap(definitions["mount"] as? [String: Any])
        XCTAssertEqual((mount["oneOf"] as? [[String: Any]])?.count, 3)
        let providerID = try XCTUnwrap(definitions["providerID"] as? [String: Any])
        XCTAssertEqual(providerID["maxLength"] as? Int, 128)
        let labels = try XCTUnwrap(definitions["labels"] as? [String: Any])
        XCTAssertEqual(labels["maxProperties"] as? Int, 256)
        let volumeDeclarations = try XCTUnwrap(definitions["volumeDeclarations"] as? [String: Any])
        XCTAssertEqual((volumeDeclarations["propertyNames"] as? [String: Any])?["$ref"] as? String, "#/$defs/name")
        let volumeDeclarationRef = try XCTUnwrap(volumeDeclarations["additionalProperties"] as? [String: Any])
        XCTAssertEqual(volumeDeclarationRef["$ref"] as? String, "#/$defs/volumeDeclaration")
        let volumeDeclaration = try XCTUnwrap(definitions["volumeDeclaration"] as? [String: Any])
        XCTAssertEqual(volumeDeclaration["required"] as? [String], ["capacity"])
        XCTAssertEqual(volumeDeclaration["additionalProperties"] as? Bool, false)
        let volumeDeclarationProperties = try XCTUnwrap(volumeDeclaration["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(volumeDeclarationProperties.keys),
            ["provider", "capacity", "accessMode", "reclaimPolicy", "labels"]
        )
        XCTAssertEqual(
            (volumeDeclarationProperties["provider"] as? [String: Any])?["$ref"] as? String,
            "#/$defs/providerID"
        )
        XCTAssertEqual(
            (volumeDeclarationProperties["capacity"] as? [String: Any])?["$ref"] as? String,
            "#/$defs/size"
        )
        XCTAssertEqual(
            (volumeDeclarationProperties["accessMode"] as? [String: Any])?["enum"] as? [String],
            ["read-write-once", "read-only-many"]
        )
        XCTAssertEqual(
            (volumeDeclarationProperties["reclaimPolicy"] as? [String: Any])?["enum"] as? [String],
            ["retain", "delete", "snapshot-before-delete", "backup-before-delete", "recycle"]
        )
        XCTAssertEqual(
            (volumeDeclarationProperties["labels"] as? [String: Any])?["$ref"] as? String,
            "#/$defs/labels"
        )
        let bindMount = try XCTUnwrap(definitions["bindMount"] as? [String: Any])
        XCTAssertEqual(bindMount["required"] as? [String], ["type", "source", "target"])
        XCTAssertEqual(bindMount["additionalProperties"] as? Bool, false)
        let volumeMount = try XCTUnwrap(definitions["volumeMount"] as? [String: Any])
        XCTAssertEqual(volumeMount["required"] as? [String], ["type", "source", "target"])
        XCTAssertEqual(volumeMount["additionalProperties"] as? Bool, false)
        let tmpfsMount = try XCTUnwrap(definitions["tmpfsMount"] as? [String: Any])
        XCTAssertEqual(tmpfsMount["required"] as? [String], ["type", "target"])
        XCTAssertEqual(tmpfsMount["additionalProperties"] as? Bool, false)

        let probe = try XCTUnwrap(definitions["probe"] as? [String: Any])
        XCTAssertEqual(probe["additionalProperties"] as? Bool, false)
        XCTAssertEqual((probe["oneOf"] as? [[String: Any]])?.count, 3)
        let update = try XCTUnwrap(definitions["update"] as? [String: Any])
        XCTAssertEqual(update["additionalProperties"] as? Bool, false)
        let hooks = try XCTUnwrap(definitions["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["additionalProperties"] as? Bool, false)
    }
}
