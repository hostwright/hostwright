import Foundation
import XCTest
@testable import HostwrightManifest

extension HostwrightManifestTests {
    func testImageProvenanceParsesValidatesAndRoundTripsCanonically() throws {
        let digest = String(repeating: "a", count: 64)
        let manifest = try ManifestValidator.validated(
            """
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
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
            version: 3,
            project: "api-local",
            imagePolicy: .requireDigest,
            imageTrust: nil,
            imageSBOM: nil,
            imageVulnerability: nil,
            imageProvenance: policy,
            services: [
                HostwrightService(
                    name: "api",
                    image: "ghcr.io/example/api@sha256:\(String(repeating: "a", count: 64))",
                    resources: HostwrightResources(
                        requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                        limits: HostwrightResourceSet(cpus: 1, memory: "512MiB")
                    )
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
            version: 3
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
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
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "imageProvenance is supported only in manifest version 3"
        )

        let invalidPolicy = HostwrightImageProvenancePolicy(
            version: 3,
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
            version: 3,
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
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
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
        version: 3
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
}
