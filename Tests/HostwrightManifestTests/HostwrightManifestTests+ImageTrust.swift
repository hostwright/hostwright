import Foundation
import XCTest
@testable import HostwrightManifest

extension HostwrightManifestTests {
    func testImageTrustParsesValidatesAndRoundTripsCanonically() throws {
        let digest = String(repeating: "a", count: 64)
        let manifest = try ManifestValidator.validated(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
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
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imageTrust requires imagePolicy require-digest"
        )

        assertManifestFailure(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imageTrust.threshold must not exceed the authority count"
        )

        assertManifestFailure(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imageTrust.trustedRoot is required when any keyless authority is declared"
        )

        assertManifestFailure(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imageTrust authority ids must be unique; duplicate id 'signer'"
        )
    }

    func testImageTrustValidationRejectsTypeSpecificFieldsPathsAndDates() {
        assertManifestFailure(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "publicKey must be a normalized absolute host path"
        )

        assertManifestFailure(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "must not declare publicKey"
        )

        assertManifestFailure(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "issuer must be an exact HTTPS URL"
        )

        assertManifestFailure(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "notBefore must not be after notAfter"
        )

        assertManifestFailure(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "revokedAt must be an RFC3339 timestamp"
        )
    }

    func testImageTrustParserRejectsDuplicateAndUnknownTopLevelFields() {
        assertManifestFailure(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imageTrust must be declared at most once"
        )

        assertManifestFailure(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "Unsupported manifest field 'extra'"
        )
    }
}
