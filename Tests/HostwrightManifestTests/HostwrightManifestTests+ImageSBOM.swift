import Foundation
import XCTest
@testable import HostwrightManifest

extension HostwrightManifestTests {
    func testImageSBOMParsesValidatesAndRoundTripsCanonically() throws {
        let digest = String(repeating: "a", count: 64)
        let manifest = try ManifestValidator.validated(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
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
            version: 3
            project: api-local
            imageSBOM:
              requirement: optional
              formats:
                - spdx-json
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imageSBOM requires imagePolicy require-digest"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            imagePolicy: require-digest
            imageSBOM:
              version: 3
              requirement: optional
              formats:
                - spdx-json
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imageSBOM.version must be 1"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            imagePolicy: require-digest
            imageSBOM:
              requirement: required
              formats: []
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imageSBOM.formats must contain between 1 and 2 unique formats"
        )

        assertManifestFailure(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imageSBOM.formats must contain between 1 and 2 unique formats"
        )
    }

    func testImageSBOMParserRejectsDuplicateUnknownAndInvalidEnums() {
        assertManifestFailure(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imageSBOM must be declared at most once"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            imagePolicy: require-digest
            imageSBOM:
              requirement: maybe
              formats:
                - spdx-json
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imageSBOM.requirement must be one of: optional, required"
        )

        assertManifestFailure(
            """
            version: 3
            project: api-local
            imagePolicy: require-digest
            imageSBOM:
              requirement: optional
              formats:
                - syft-json
            services:
              api:
                image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imageSBOM.formats must be one of: spdx-json, cyclonedx-json"
        )

        assertManifestFailure(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "Unsupported manifest field 'extra'"
        )
    }
}
