import XCTest
@testable import HostwrightNetworking

final class CoreDNSInfrastructureImageTests: XCTestCase {
    func testExactLinuxARM64EvidencePasses() throws {
        XCTAssertNoThrow(
            try CoreDNSInfrastructureImage.validate(validEvidence())
        )
    }

    func testMutableOrMismatchedImageFailsBeforeUse() {
        XCTAssertThrowsError(
            try CoreDNSInfrastructureImage.validate(
                evidence(
                    reference: "docker.io/coredns/coredns:1.14.6",
                    digest: CoreDNSInfrastructureImage.linuxARM64Digest
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreDNSInfrastructureImageError,
                .mutableReference
            )
        }
        XCTAssertThrowsError(
            try CoreDNSInfrastructureImage.validate(
                evidence(
                    reference:
                        "docker.io/coredns/coredns@sha256:\(String(repeating: "0", count: 64))",
                    digest: "sha256:\(String(repeating: "0", count: 64))"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreDNSInfrastructureImageError,
                .digestMismatch
            )
        }
    }

    func testMissingLocalImageOrSupplyChainEvidenceFails() {
        XCTAssertThrowsError(
            try CoreDNSInfrastructureImage.validate(
                validEvidence(localImageAvailable: false)
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreDNSInfrastructureImageError,
                .imageUnavailable
            )
        }
        XCTAssertThrowsError(
            try CoreDNSInfrastructureImage.validate(
                validEvidence(phase05PolicyAccepted: false)
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreDNSInfrastructureImageError,
                .unverifiedSupplyChain
            )
        }
    }

    func testWrongPlatformAndMalformedEvidenceDigestFail() {
        XCTAssertThrowsError(
            try CoreDNSInfrastructureImage.validate(
                validEvidence(architecture: "amd64")
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreDNSInfrastructureImageError,
                .unsupportedPlatform
            )
        }
        XCTAssertThrowsError(
            try CoreDNSInfrastructureImage.validate(
                validEvidence(evidenceSHA256: "not-a-digest")
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreDNSInfrastructureImageError,
                .invalidEvidenceDigest
            )
        }
    }

    private func validEvidence(
        localImageAvailable: Bool = true,
        phase05PolicyAccepted: Bool = true,
        architecture: String = "arm64",
        evidenceSHA256: String = String(repeating: "a", count: 64)
    ) -> CoreDNSInfrastructureImageEvidence {
        evidence(
            reference:
                CoreDNSInfrastructureImage.immutableLinuxARM64Reference,
            digest: CoreDNSInfrastructureImage.linuxARM64Digest,
            localImageAvailable: localImageAvailable,
            phase05PolicyAccepted: phase05PolicyAccepted,
            architecture: architecture,
            evidenceSHA256: evidenceSHA256
        )
    }

    private func evidence(
        reference: String,
        digest: String,
        localImageAvailable: Bool = true,
        phase05PolicyAccepted: Bool = true,
        architecture: String = "arm64",
        evidenceSHA256: String = String(repeating: "a", count: 64)
    ) -> CoreDNSInfrastructureImageEvidence {
        CoreDNSInfrastructureImageEvidence(
            resolvedReference: reference,
            descriptorDigest:
                "sha256:\(String(repeating: "d", count: 64))",
            variantDigest: digest,
            operatingSystem: "linux",
            architecture: architecture,
            localImageAvailable: localImageAvailable,
            phase05PolicyAccepted: phase05PolicyAccepted,
            evidenceSHA256: evidenceSHA256
        )
    }
}
