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
            version: 2
            project: demo
            services:
              api:
                image: local/api:latest
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
            version: 2
            project: api-local
            services:
              api:
                image: ghcr.io/example/api:latest
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
        version: 2
        project: api-local
        services:
          api:
            image: ghcr.io/example/api:latest
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
                version: 2
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
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

    func testImageTrustParsesValidatesAndRoundTripsCanonically() throws {
        let digest = String(repeating: "a", count: 64)
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              version: 1
              threshold: 2
              trustedRoot: /Users/dev/.config/hostwright/fulcio.pem
              authorities:
                - id: z-keyless
                  type: keyless
                  issuer: https://token.actions.githubusercontent.com
                  identity: https://github.com/example/repo/.github/workflows/release.yml@refs/heads/main
                  notBefore: "2026-01-01T00:00:00Z"
                - id: a-keyed
                  type: keyed
                  publicKey: /Users/dev/.config/hostwright/release.pub
            services:
              api:
                image: ghcr.io/example/api@sha256:\(digest)
            """
        )

        let imageTrust = try XCTUnwrap(manifest.imageTrust)
        XCTAssertEqual(imageTrust.version, 1)
        XCTAssertEqual(imageTrust.threshold, 2)
        XCTAssertEqual(imageTrust.trustedRoot, "/Users/dev/.config/hostwright/fulcio.pem")
        XCTAssertEqual(imageTrust.authorities.map(\.id), ["a-keyed", "z-keyless"])

        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertLessThan(
            try XCTUnwrap(canonical.range(of: #"- id: "a-keyed""#)?.lowerBound),
            try XCTUnwrap(canonical.range(of: #"- id: "z-keyless""#)?.lowerBound)
        )
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testImageTrustValidationFailsClosedForCrossFieldAndAuthorityRules() {
        assertManifestFailure(
            """
            version: 2
            project: api-local
            imageTrust:
              threshold: 1
              authorities:
                - id: signer
                  type: keyed
                  publicKey: /Users/dev/.config/hostwright/release.pub
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            contains: "imageTrust requires imagePolicy require-digest"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              threshold: 2
              authorities:
                - id: signer
                  type: keyed
                  publicKey: /Users/dev/.config/hostwright/release.pub
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imageTrust.threshold must not exceed the authority count"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              threshold: 1
              authorities:
                - id: ci
                  type: keyless
                  issuer: https://token.actions.githubusercontent.com
                  identity: https://github.com/example/repo/.github/workflows/release.yml@refs/heads/main
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imageTrust.trustedRoot is required when any keyless authority is declared"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              threshold: 1
              trustedRoot: /Users/dev/.config/hostwright/fulcio.pem
              authorities:
                - id: signer
                  type: keyed
                  issuer: https://token.actions.githubusercontent.com
                - id: signer
                  type: keyless
                  issuer: https://token.actions.githubusercontent.com
                  identity: https://github.com/example/repo/.github/workflows/release.yml@refs/heads/main
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imageTrust authority ids must be unique; duplicate id 'signer'"
        )
    }

    func testImageTrustValidationRejectsTypeSpecificFieldsPathsAndDates() {
        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              threshold: 1
              authorities:
                - id: signer
                  type: keyed
                  publicKey: relative/release.pub
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "publicKey must be a normalized absolute host path"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              threshold: 1
              trustedRoot: /Users/dev/.config/hostwright/fulcio.pem
              authorities:
                - id: ci
                  type: keyless
                  publicKey: /Users/dev/.config/hostwright/release.pub
                  issuer: http://token.actions.githubusercontent.com
                  identity: runner@example
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "must not declare publicKey"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              threshold: 1
              trustedRoot: /Users/dev/.config/hostwright/fulcio.pem
              authorities:
                - id: ci
                  type: keyless
                  issuer: http://token.actions.githubusercontent.com
                  identity: runner@example
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "issuer must be an exact HTTPS URL"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              threshold: 1
              trustedRoot: /Users/dev/.config/hostwright/fulcio.pem
              authorities:
                - id: ci
                  type: keyless
                  issuer: https://token.actions.githubusercontent.com
                  identity: runner@example
                  notBefore: "2026-01-02T00:00:00Z"
                  notAfter: "2026-01-01T00:00:00Z"
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "notBefore must not be after notAfter"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              threshold: 1
              trustedRoot: /Users/dev/.config/hostwright/fulcio.pem
              authorities:
                - id: ci
                  type: keyless
                  issuer: https://token.actions.githubusercontent.com
                  identity: runner@example
                  revokedAt: "not-a-date"
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "revokedAt must be an RFC3339 timestamp"
        )
    }

    func testImageTrustParserRejectsDuplicateAndUnknownTopLevelFields() {
        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              threshold: 1
              authorities:
                - id: signer
                  type: keyed
                  publicKey: /Users/dev/.config/hostwright/release.pub
            imageTrust:
              threshold: 1
              authorities:
                - id: ci
                  type: keyless
                  issuer: https://token.actions.githubusercontent.com
                  identity: runner@example
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imageTrust must be declared at most once"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              threshold: 1
              authorities:
                - id: signer
                  type: keyed
                  publicKey: /Users/dev/.config/hostwright/release.pub
                  extra: unsupported
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "Unsupported manifest field 'extra'"
        )
    }

    func testImageSBOMParsesValidatesAndRoundTripsCanonically() throws {
        let digest = String(repeating: "a", count: 64)
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageSBOM:
              version: 1
              requirement: required
              formats:
                - spdx-json
                - cyclonedx-json
            services:
              api:
                image: ghcr.io/example/api@sha256:\(digest)
            """
        )

        let imageSBOM = try XCTUnwrap(manifest.imageSBOM)
        XCTAssertEqual(imageSBOM.version, 1)
        XCTAssertEqual(imageSBOM.requirement, .required)
        XCTAssertEqual(imageSBOM.formats, [.cyclonedxJSON, .spdxJSON])

        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertLessThan(
            try XCTUnwrap(canonical.range(of: #"- "cyclonedx-json""#)?.lowerBound),
            try XCTUnwrap(canonical.range(of: #"- "spdx-json""#)?.lowerBound)
        )
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testImageSBOMValidationFailsClosedForDigestVersionAndFormats() {
        assertManifestFailure(
            """
            version: 2
            project: api-local
            imageSBOM:
              requirement: optional
              formats:
                - spdx-json
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            contains: "imageSBOM requires imagePolicy require-digest"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageSBOM:
              version: 2
              requirement: optional
              formats:
                - spdx-json
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imageSBOM.version must be 1"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageSBOM:
              requirement: required
              formats: []
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imageSBOM.formats must contain between 1 and 2 unique formats"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageSBOM:
              requirement: required
              formats:
                - spdx-json
                - cyclonedx-json
                - spdx-json
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imageSBOM.formats must contain between 1 and 2 unique formats"
        )
    }

    func testImageSBOMParserRejectsDuplicateUnknownAndInvalidEnums() {
        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageSBOM:
              requirement: required
              formats:
                - spdx-json
            imageSBOM:
              requirement: optional
              formats:
                - cyclonedx-json
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imageSBOM must be declared at most once"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageSBOM:
              requirement: maybe
              formats:
                - spdx-json
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imageSBOM.requirement must be one of: optional, required"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageSBOM:
              requirement: optional
              formats:
                - syft-json
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imageSBOM.formats must be one of: spdx-json, cyclonedx-json"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageSBOM:
              requirement: optional
              formats:
                - spdx-json
              extra: unsupported
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "Unsupported manifest field 'extra'"
        )
    }

    func testImageVulnerabilityParsesValidatesAndRoundTripsCanonically() throws {
        let digest = String(repeating: "a", count: 64)
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              threshold: 1
              authorities:
                - id: release
                  type: keyed
                  publicKey: /Users/dev/.config/hostwright/release.pub
            imageVulnerability:
              version: 1
              severityThreshold: high
              minimumVulnerabilityAgeSeconds: 86400
              exploitability: known-exploited
              fixAvailability: fix-available
              maximumDatabaseAgeSeconds: 604800
              staleAction: fail-closed
              unavailableAction: fail-closed
              exceptionApproval: required
              allowlist:
                - vulnerabilityID: GHSA-zzzz-yyyy-xxxx
                  reason: Awaiting upstream remediation
                  expiresAt: "2027-01-02T03:04:05Z"
                - vulnerabilityID: CVE-2026-0001
                  packagePURL: pkg:swift/example@1.0.0
                  reason: Not reachable in the deployed configuration
                  expiresAt: "2026-12-01T00:00:00Z"
            services:
              api:
                image: ghcr.io/example/api@sha256:\(digest)
            """
        )

        let policy = try XCTUnwrap(manifest.imageVulnerability)
        XCTAssertEqual(policy.version, 1)
        XCTAssertEqual(policy.severityThreshold, .high)
        XCTAssertEqual(policy.minimumVulnerabilityAgeSeconds, 86_400)
        XCTAssertEqual(policy.exploitability, .knownExploited)
        XCTAssertEqual(policy.fixAvailability, .fixAvailable)
        XCTAssertEqual(policy.maximumDatabaseAgeSeconds, 604_800)
        XCTAssertEqual(policy.staleAction, .failClosed)
        XCTAssertEqual(policy.unavailableAction, .failClosed)
        XCTAssertEqual(policy.exceptionApproval, .required)
        XCTAssertEqual(policy.allowlist.map(\.vulnerabilityID), ["CVE-2026-0001", "GHSA-zzzz-yyyy-xxxx"])

        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertLessThan(
            try XCTUnwrap(canonical.range(of: #"vulnerabilityID: "CVE-2026-0001""#)?.lowerBound),
            try XCTUnwrap(canonical.range(of: #"vulnerabilityID: "GHSA-zzzz-yyyy-xxxx""#)?.lowerBound)
        )
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
        XCTAssertEqual(try ManifestCanonicalEncoder.encode(ManifestValidator.validated(canonical)), canonical)
    }

    func testImageVulnerabilityAcceptsExactBoundaryValues() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              threshold: 1
              authorities:
                - id: release
                  type: keyed
                  publicKey: /Users/dev/.config/hostwright/release.pub
            imageVulnerability:
              severityThreshold: low
              minimumVulnerabilityAgeSeconds: 0
              exploitability: any
              fixAvailability: any
              maximumDatabaseAgeSeconds: 60
              staleAction: fail-open
              unavailableAction: fail-open
              exceptionApproval: disabled
              allowlist: []
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """
        )
        let policy = try XCTUnwrap(manifest.imageVulnerability)
        XCTAssertEqual(policy.minimumVulnerabilityAgeSeconds, 0)
        XCTAssertEqual(policy.maximumDatabaseAgeSeconds, 60)
        XCTAssertTrue(policy.allowlist.isEmpty)

        var maximumPolicy = policy
        maximumPolicy.minimumVulnerabilityAgeSeconds =
            HostwrightImageVulnerabilityPolicy.maximumMinimumVulnerabilityAgeSeconds
        maximumPolicy.maximumDatabaseAgeSeconds =
            HostwrightImageVulnerabilityPolicy.maximumMaximumDatabaseAgeSeconds
        let maximumManifest = HostwrightManifest(
            version: 2,
            project: "api-local",
            imagePolicy: .requireDigest,
            imageTrust: manifest.imageTrust,
            imageSBOM: nil,
            imageVulnerability: maximumPolicy,
            services: manifest.services
        )
        XCTAssertTrue(ManifestValidator.validate(maximumManifest).isEmpty)
    }

    func testImageVulnerabilityFailsClosedForRequiredContractsAndBounds() {
        assertManifestFailure(
            """
            version: 1
            project: api-local
            imagePolicy: require-digest
            imageTrust:
              threshold: 1
              authorities:
                - id: release
                  type: keyed
                  publicKey: /Users/dev/.config/hostwright/release.pub
            imageVulnerability:
              severityThreshold: high
              minimumVulnerabilityAgeSeconds: 0
              exploitability: any
              fixAvailability: any
              maximumDatabaseAgeSeconds: 60
              staleAction: fail-closed
              unavailableAction: fail-closed
              exceptionApproval: required
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imageVulnerability is supported only in manifest version 2"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imageVulnerability:
              severityThreshold: high
              minimumVulnerabilityAgeSeconds: 0
              exploitability: any
              fixAvailability: any
              maximumDatabaseAgeSeconds: 60
              staleAction: fail-closed
              unavailableAction: fail-closed
              exceptionApproval: required
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            contains: "imageVulnerability requires imagePolicy require-digest"
        )

        assertManifestFailure(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageVulnerability:
              severityThreshold: high
              minimumVulnerabilityAgeSeconds: 31536001
              exploitability: any
              fixAvailability: any
              maximumDatabaseAgeSeconds: 59
              staleAction: fail-closed
              unavailableAction: fail-closed
              exceptionApproval: required
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imageVulnerability requires imageTrust"
        )

        let trust = HostwrightImageTrustPolicy(
            threshold: 1,
            authorities: [
                HostwrightImageTrustAuthority(
                    id: "release",
                    type: .keyed,
                    publicKey: "/Users/dev/.config/hostwright/release.pub"
                )
            ]
        )
        let entries = (0...HostwrightImageVulnerabilityPolicy.maximumAllowlistEntries).map { index in
            HostwrightImageVulnerabilityAllowlistEntry(
                vulnerabilityID: "CVE-2026-\(String(format: "%04d", index))",
                reason: "Temporary exception",
                expiresAt: "2027-01-01T00:00:00Z"
            )
        }
        let policy = HostwrightImageVulnerabilityPolicy(
            severityThreshold: .critical,
            minimumVulnerabilityAgeSeconds: 31_536_001,
            exploitability: .any,
            fixAvailability: .any,
            maximumDatabaseAgeSeconds: 59,
            staleAction: .failClosed,
            unavailableAction: .failClosed,
            exceptionApproval: .required,
            allowlist: entries
        )
        let manifest = HostwrightManifest(
            version: 2,
            project: "api-local",
            imagePolicy: .requireDigest,
            imageTrust: trust,
            imageSBOM: nil,
            imageVulnerability: policy,
            services: [
                HostwrightService(
                    name: "api",
                    image: "ghcr.io/example/api@sha256:\(String(repeating: "a", count: 64))"
                )
            ]
        )
        let messages = ManifestValidator.validate(manifest).map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("minimumVulnerabilityAgeSeconds must be between") })
        XCTAssertTrue(messages.contains { $0.contains("maximumDatabaseAgeSeconds must be between") })
        XCTAssertTrue(messages.contains { $0.contains("allowlist must contain at most 256 entries") })

        var malformedPolicy = policy
        malformedPolicy.minimumVulnerabilityAgeSeconds = 0
        malformedPolicy.maximumDatabaseAgeSeconds = 60
        malformedPolicy.allowlist = [
            HostwrightImageVulnerabilityAllowlistEntry(
                vulnerabilityID: "invalid id",
                packagePURL: "https://example.invalid/package",
                reason: String(repeating: "r", count: 513),
                expiresAt: "not-a-timestamp"
            )
        ]
        var malformedManifest = manifest
        malformedManifest.imageVulnerability = malformedPolicy
        let malformedMessages = ManifestValidator.validate(malformedManifest).map(\.message)
        XCTAssertTrue(malformedMessages.contains { $0.contains("bounded exact identifier") })
        XCTAssertTrue(malformedMessages.contains { $0.contains("bounded exact package URL") })
        XCTAssertTrue(malformedMessages.contains { $0.contains("bounded non-empty string") })
        XCTAssertTrue(malformedMessages.contains { $0.contains("expiresAt must be an RFC3339 timestamp") })
    }

    func testImageVulnerabilityRejectsInvalidEnumsUnknownFieldsAndDuplicateEntries() {
        let prefix = """
        version: 2
        project: api-local
        imagePolicy: require-digest
        imageTrust:
          threshold: 1
          authorities:
            - id: release
              type: keyed
              publicKey: /Users/dev/.config/hostwright/release.pub
        """
        let suffix = """
        services:
          api:
            image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        """

        assertManifestFailure(
            prefix + "\n" + """
            imageVulnerability:
              severityThreshold: urgent
              minimumVulnerabilityAgeSeconds: 0
              exploitability: any
              fixAvailability: any
              maximumDatabaseAgeSeconds: 60
              staleAction: fail-closed
              unavailableAction: fail-closed
              exceptionApproval: required
            """ + "\n" + suffix,
            contains: "imageVulnerability.severityThreshold must be one of"
        )
        assertManifestFailure(
            prefix + "\n" + """
            imageVulnerability:
              severityThreshold: high
              minimumVulnerabilityAgeSeconds: 0
              exploitability: any
              fixAvailability: any
              maximumDatabaseAgeSeconds: 60
              staleAction: fail-closed
              unavailableAction: fail-closed
              exceptionApproval: required
              extra: unsupported
            """ + "\n" + suffix,
            contains: "Unsupported manifest field 'extra'"
        )
        assertManifestFailure(
            prefix + "\n" + """
            imageVulnerability:
              severityThreshold: high
              minimumVulnerabilityAgeSeconds: 0
              exploitability: any
              fixAvailability: any
              maximumDatabaseAgeSeconds: 60
              staleAction: fail-closed
              unavailableAction: fail-closed
              exceptionApproval: required
              allowlist:
                - vulnerabilityID: CVE-2026-0001
                  packagePURL: pkg:swift/example@1.0.0
                  reason: First approval
                  expiresAt: "2027-01-01T00:00:00Z"
                - vulnerabilityID: CVE-2026-0001
                  packagePURL: pkg:swift/example@1.0.0
                  reason: Conflicting approval
                  expiresAt: invalid
            """ + "\n" + suffix,
            contains: "allowlist entries must be unique"
        )

        assertManifestFailure(
            prefix + "\n" + """
            imageVulnerability:
              severityThreshold: high
              minimumVulnerabilityAgeSeconds: 0
              exploitability: any
              fixAvailability: any
              maximumDatabaseAgeSeconds: 60
              staleAction: fail-closed
              unavailableAction: fail-closed
              exceptionApproval: required
            imageVulnerability:
              severityThreshold: critical
              minimumVulnerabilityAgeSeconds: 0
              exploitability: any
              fixAvailability: any
              maximumDatabaseAgeSeconds: 60
              staleAction: fail-closed
              unavailableAction: fail-closed
              exceptionApproval: disabled
            """ + "\n" + suffix,
            contains: "imageVulnerability must be declared at most once"
        )
    }

    func testImageProvenanceParsesValidatesAndRoundTripsCanonically() throws {
        let digest = String(repeating: "a", count: 64)
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: api-local
            imagePolicy: require-digest
            imageProvenance:
              version: 1
              requirement: required
              builderIDs:
                - urn:hostwright:builder:z
                - https://build.example.com/builders/a
              buildTypes:
                - urn:hostwright:build-type:z
                - https://slsa.dev/provenance/v1
              signers:
                - id: z-release
                  publicKey: /Users/dev/.config/hostwright/z-release.pub
                  notBefore: "2026-01-01T00:00:00Z"
                - id: a-release
                  publicKey: /Users/dev/.config/hostwright/a-release.pub
                  notAfter: "2027-01-01T00:00:00Z"
                  revokedAt: "2027-02-01T00:00:00Z"
              maximumAgeSeconds: 86400
              requireReproducible: true
            services:
              api:
                image: ghcr.io/example/api@sha256:\(digest)
            """
        )

        let policy = try XCTUnwrap(manifest.imageProvenance)
        XCTAssertEqual(policy.version, 1)
        XCTAssertEqual(policy.requirement, .required)
        XCTAssertEqual(
            policy.builderIDs,
            ["https://build.example.com/builders/a", "urn:hostwright:builder:z"]
        )
        XCTAssertEqual(
            policy.buildTypes,
            ["https://slsa.dev/provenance/v1", "urn:hostwright:build-type:z"]
        )
        XCTAssertEqual(policy.signers.map(\.id), ["a-release", "z-release"])
        XCTAssertEqual(policy.maximumAgeSeconds, 86_400)
        XCTAssertTrue(policy.requireReproducible)

        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertLessThan(
            try XCTUnwrap(canonical.range(of: #"- id: "a-release""#)?.lowerBound),
            try XCTUnwrap(canonical.range(of: #"- id: "z-release""#)?.lowerBound)
        )
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
        XCTAssertEqual(
            try ManifestCanonicalEncoder.encode(ManifestValidator.validated(canonical)),
            canonical
        )
    }

    func testImageProvenanceAcceptsExactBoundaryValues() {
        let maximumURI = "urn:" + String(repeating: "a", count: 508)
        let maximumSignerID = "s" + String(repeating: "a", count: 126) + "z"
        let maximumPublicKey = "/" + String(repeating: "k", count: 4_095)
        let policy = HostwrightImageProvenancePolicy(
            requirement: .optional,
            builderIDs: (0..<16).map { "urn:builder:\($0)" },
            buildTypes: (0..<15).map { "https://build.example.com/type/\($0)" } + [maximumURI],
            signers: (0..<7).map {
                HostwrightImageProvenanceSigner(
                    id: "signer-\($0)",
                    publicKey: "/keys/signer-\($0).pub"
                )
            } + [
                HostwrightImageProvenanceSigner(
                    id: maximumSignerID,
                    publicKey: maximumPublicKey,
                    notBefore: "2026-01-01T00:00:00Z",
                    notAfter: "2026-12-01T00:00:00Z",
                    revokedAt: "2027-01-01T00:00:00Z"
                )
            ],
            maximumAgeSeconds: HostwrightImageProvenancePolicy.maximumMaximumAgeSeconds,
            requireReproducible: false
        )
        let manifest = HostwrightManifest(
            version: 2,
            project: "api-local",
            imagePolicy: .requireDigest,
            imageTrust: nil,
            imageSBOM: nil,
            imageVulnerability: nil,
            imageProvenance: policy,
            services: [
                HostwrightService(
                    name: "api",
                    image: "ghcr.io/example/api@sha256:\(String(repeating: "a", count: 64))"
                )
            ]
        )

        XCTAssertTrue(ManifestValidator.validate(manifest).isEmpty)
        var minimumManifest = manifest
        minimumManifest.imageProvenance?.maximumAgeSeconds =
            HostwrightImageProvenancePolicy.minimumMaximumAgeSeconds
        XCTAssertTrue(ManifestValidator.validate(minimumManifest).isEmpty)
    }

    func testImageProvenanceFailsClosedForGatesBoundsAndSignerRules() {
        assertManifestFailure(
            """
            version: 2
            project: api-local
            imageProvenance:
              requirement: required
              builderIDs: [urn:builder:release]
              buildTypes: [https://slsa.dev/provenance/v1]
              signers:
                - id: release
                  publicKey: /keys/release.pub
              maximumAgeSeconds: 60
              requireReproducible: true
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            contains: "imageProvenance requires imagePolicy require-digest"
        )
        assertManifestFailure(
            """
            version: 1
            project: api-local
            imagePolicy: require-digest
            imageProvenance:
              requirement: required
              builderIDs: [urn:builder:release]
              buildTypes: [urn:build-type:release]
              signers:
                - id: release
                  publicKey: /keys/release.pub
              maximumAgeSeconds: 60
              requireReproducible: false
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            """,
            contains: "imageProvenance is supported only in manifest version 2"
        )

        let invalidPolicy = HostwrightImageProvenancePolicy(
            version: 2,
            requirement: .required,
            builderIDs: [],
            buildTypes: ["file:///tmp/build", "file:///tmp/build"],
            signers: [
                HostwrightImageProvenanceSigner(
                    id: "-invalid",
                    publicKey: "relative/key.pub",
                    notBefore: "2027-01-01T00:00:00Z",
                    notAfter: "2026-01-01T00:00:00Z"
                ),
                HostwrightImageProvenanceSigner(
                    id: "-invalid",
                    publicKey: "/keys/other.pub",
                    revokedAt: "invalid"
                )
            ],
            maximumAgeSeconds: 59,
            requireReproducible: true
        )
        let manifest = HostwrightManifest(
            version: 2,
            project: "api-local",
            imagePolicy: .requireDigest,
            imageTrust: nil,
            imageSBOM: nil,
            imageVulnerability: nil,
            imageProvenance: invalidPolicy,
            services: [
                HostwrightService(
                    name: "api",
                    image: "ghcr.io/example/api@sha256:\(String(repeating: "a", count: 64))"
                )
            ]
        )
        let messages = ManifestValidator.validate(manifest).map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("imageProvenance.version must be 1") })
        XCTAssertTrue(messages.contains { $0.contains("builderIDs must contain between 1 and 16 unique") })
        XCTAssertTrue(messages.contains { $0.contains("buildTypes must contain between 1 and 16 unique") })
        XCTAssertTrue(messages.contains { $0.contains("must be a bounded https:// or urn: URI") })
        XCTAssertTrue(messages.contains { $0.contains("signer ids must be unique") })
        XCTAssertTrue(messages.contains { $0.contains("signer id '-invalid' must be a bounded safe identifier") })
        XCTAssertTrue(messages.contains { $0.contains("publicKey must be a bounded normalized absolute host path") })
        XCTAssertTrue(messages.contains { $0.contains("notBefore must not be after notAfter") })
        XCTAssertTrue(messages.contains { $0.contains("revokedAt must be an RFC3339 timestamp") })
        XCTAssertTrue(messages.contains { $0.contains("maximumAgeSeconds must be between 60 and 31536000") })

        var ambiguousPolicy = invalidPolicy
        ambiguousPolicy.version = 1
        ambiguousPolicy.builderIDs = ["https://user@example.com/builder"]
        ambiguousPolicy.buildTypes = ["urn:hostwright:build..type"]
        ambiguousPolicy.signers = [
            HostwrightImageProvenanceSigner(id: "release", publicKey: "/keys/release.pub")
        ]
        ambiguousPolicy.maximumAgeSeconds = 60
        var ambiguousManifest = manifest
        ambiguousManifest.imageProvenance = ambiguousPolicy
        XCTAssertEqual(
            ManifestValidator.validate(ambiguousManifest)
                .filter { $0.message.contains("must be a bounded https:// or urn: URI") }
                .count,
            2
        )

        var oversizedPolicy = invalidPolicy
        oversizedPolicy.version = 1
        oversizedPolicy.builderIDs = (0...16).map { "urn:builder:\($0)" }
        oversizedPolicy.buildTypes = (0...16).map { "urn:build-type:\($0)" }
        oversizedPolicy.signers = (0...8).map {
            HostwrightImageProvenanceSigner(id: "signer-\($0)", publicKey: "/keys/\($0).pub")
        }
        oversizedPolicy.maximumAgeSeconds = 31_536_001
        var oversizedManifest = manifest
        oversizedManifest.imageProvenance = oversizedPolicy
        let oversizedMessages = ManifestValidator.validate(oversizedManifest).map(\.message)
        XCTAssertTrue(oversizedMessages.contains { $0.contains("builderIDs must contain between 1 and 16") })
        XCTAssertTrue(oversizedMessages.contains { $0.contains("buildTypes must contain between 1 and 16") })
        XCTAssertTrue(oversizedMessages.contains { $0.contains("signers must contain between 1 and 8") })
        XCTAssertTrue(oversizedMessages.contains { $0.contains("maximumAgeSeconds must be between") })
    }

    func testImageProvenanceParserRejectsMissingUnknownDuplicateAndAmbiguousFields() {
        let suffix = """
        services:
          api:
            image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        """
        let policy = """
        imageProvenance:
          requirement: required
          builderIDs: [urn:builder:release]
          buildTypes: [urn:build-type:release]
          signers:
            - id: release
              publicKey: /keys/release.pub
          maximumAgeSeconds: 60
          requireReproducible: true
        """
        let prefix = """
        version: 2
        project: api-local
        imagePolicy: require-digest
        """

        assertManifestFailure(
            prefix + "\n" + policy + "\n" + policy + "\n" + suffix,
            contains: "imageProvenance must be declared at most once"
        )
        assertManifestFailure(
            prefix + "\n" + """
            imageProvenance:
              requirement: required
              builderIDs: [urn:builder:release]
              buildTypes: [urn:build-type:release]
              signers:
                - id: release
                  publicKey: /keys/release.pub
                  issuer: https://issuer.example.com
              maximumAgeSeconds: 60
              requireReproducible: true
            """ + "\n" + suffix,
            contains: "Unsupported manifest field 'issuer'"
        )
        assertManifestFailure(
            prefix + "\n" + """
            imageProvenance:
              requirement: required
              buildTypes: [urn:build-type:release]
              signers:
                - id: release
                  publicKey: /keys/release.pub
              maximumAgeSeconds: 60
              requireReproducible: true
            """ + "\n" + suffix,
            contains: "imageProvenance.builderIDs is required"
        )
        assertManifestFailure(
            prefix + "\n" + policy.replacingOccurrences(
                of: "requireReproducible: true",
                with: #"requireReproducible: "true""#
            ) + "\n" + suffix,
            contains: "Expected true or false"
        )
        assertManifestFailure(
            prefix + "\n" + policy.replacingOccurrences(
                of: "requirement: required",
                with: "requirement: maybe"
            ) + "\n" + suffix,
            contains: "imageProvenance.requirement must be one of: optional, required"
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
                  burstLimit: 3
            """,
            code: "HW-MANIFEST-003",
            contains: "Unsupported restart field 'burstLimit'"
        )
    }

    func testPhase08RestartBudgetsParseValidateAndRoundTripCanonically() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: api-local
            restartBudget:
              maxAttempts: 24
              window: 900s
            services:
              api:
                image: ghcr.io/example/api:latest
                restart:
                  policy: on-failure
                  maxAttempts: 7
                  window: 600s
                  backoff: 15s
                  maxBackoff: 120s
                  jitter: 5s
                  stableRun: 90s
                  priority: 20
            """
        )

        XCTAssertEqual(manifest.restartBudget, HostwrightProjectRestartBudget(maxAttempts: 24, window: 900))
        XCTAssertEqual(
            manifest.services[0].restart,
            HostwrightRestart(
                policy: "on-failure",
                maxAttempts: 7,
                window: 600,
                backoff: 15,
                maxBackoff: 120,
                jitter: 5,
                stableRun: 90,
                priority: 20
            )
        )
        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testPhase08RestartBudgetDefaultsPreserveLegacyCanonicalManifest() throws {
        let manifest = try ManifestValidator.validated(Self.validManifest)
        XCTAssertNil(manifest.restartBudget)
        XCTAssertEqual(manifest.services[0].restart, HostwrightRestart(policy: "on-failure"))
        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertFalse(canonical.contains("restartBudget:"))
        XCTAssertFalse(canonical.contains("maxAttempts:"))
    }

    func testPhase08RolloutStableObservationParsesValidatesAndRoundTrips() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: rollout-local
            services:
              api:
                image: ghcr.io/example/api:latest
                probes:
                  readiness:
                    exec: ["/bin/check-ready"]
                    interval: 1s
                update:
                  strategy: rolling
                  maxSurge: 1
                  maxUnavailable: 0
                  progressDeadline: 60s
                  stableObservation: 10s
            """
        )

        XCTAssertEqual(manifest.services[0].update.stableObservation, 10)
        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertTrue(canonical.contains("stableObservation: \"10s\""))
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)

        assertManifestFailure(
            """
            version: 2
            project: rollout-local
            services:
              api:
                image: ghcr.io/example/api:latest
                update:
                  progressDeadline: 60s
                  stableObservation: 10s
            """,
            contains: "stableObservation requires a readiness or liveness probe"
        )
    }

    func testPhase08RestartBudgetsRejectUnsafeAndUnknownValues() {
        let invalidFields = [
            "maxAttempts: 0",
            "window: 0s",
            "backoff: 0s",
            "stableRun: 0s",
            "priority: 101"
        ]
        for fields in invalidFields {
            assertManifestFailure(
                """
                version: 2
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    restart:
                      policy: on-failure
                      \(fields)
                """,
                contains: "restart"
            )
        }
        for fields in [
            "backoff: 60s\n      maxBackoff: 30s",
            "backoff: 60s\n      jitter: 61s"
        ] {
            assertManifestFailure(
                """
                version: 2
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    restart:
                      policy: on-failure
                      \(fields)
                """,
                contains: "restart"
            )
        }
        assertManifestFailure(
            """
            version: 2
            project: api-local
            restartBudget:
              maxAttempts: 1001
            services:
              api:
                image: ghcr.io/example/api:latest
            """,
            contains: "restartBudget.maxAttempts"
        )
    }

    func testUnsupportedNetworkingAndDiscoveryFieldsFailClosed() {
        for field in ["dns", "dns_search", "domainname", "hostname", "network_mode", "aliases", "expose", "extra_hosts"] {
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
                "maintenance", "services"
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
                "image", "replicas", "platform", "resources", "user", "group", "workdir",
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
