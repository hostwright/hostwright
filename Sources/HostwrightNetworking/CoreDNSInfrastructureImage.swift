import Foundation

public enum CoreDNSInfrastructureImageError: Error, Equatable, Sendable {
    case imageUnavailable
    case mutableReference
    case digestMismatch
    case unsupportedPlatform
    case unverifiedSupplyChain
    case invalidEvidenceDigest
}

public struct CoreDNSInfrastructureImageEvidence: Codable, Equatable, Sendable {
    public let resolvedReference: String
    public let descriptorDigest: String
    public let variantDigest: String
    public let operatingSystem: String
    public let architecture: String
    public let localImageAvailable: Bool
    public let phase05PolicyAccepted: Bool
    public let evidenceSHA256: String

    public init(
        resolvedReference: String,
        descriptorDigest: String,
        variantDigest: String,
        operatingSystem: String,
        architecture: String,
        localImageAvailable: Bool,
        phase05PolicyAccepted: Bool,
        evidenceSHA256: String
    ) {
        self.resolvedReference = resolvedReference
        self.descriptorDigest = descriptorDigest
        self.variantDigest = variantDigest
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.localImageAvailable = localImageAvailable
        self.phase05PolicyAccepted = phase05PolicyAccepted
        self.evidenceSHA256 = evidenceSHA256
    }
}

public enum CoreDNSInfrastructureImage {
    public static let version = "1.14.6"
    public static let repository = "docker.io/coredns/coredns"
    public static let linuxARM64Digest =
        "sha256:d5cc132a34e034ecfd2d4c73c5bf341e5d8af9a0ba46bd7619d9448beb27e7a2"
    public static let immutableLinuxARM64Reference =
        "\(repository)@\(linuxARM64Digest)"

    public static func validate(
        _ evidence: CoreDNSInfrastructureImageEvidence
    ) throws {
        guard evidence.localImageAvailable else {
            throw CoreDNSInfrastructureImageError.imageUnavailable
        }
        guard evidence.resolvedReference.contains("@sha256:"),
              !evidence.resolvedReference.contains(":1.14.6@") else {
            throw CoreDNSInfrastructureImageError.mutableReference
        }
        guard evidence.resolvedReference == immutableLinuxARM64Reference,
              isOCIDigest(evidence.descriptorDigest),
              evidence.variantDigest == linuxARM64Digest else {
            throw CoreDNSInfrastructureImageError.digestMismatch
        }
        guard evidence.operatingSystem == "linux",
              evidence.architecture == "arm64" else {
            throw CoreDNSInfrastructureImageError.unsupportedPlatform
        }
        guard evidence.phase05PolicyAccepted else {
            throw CoreDNSInfrastructureImageError.unverifiedSupplyChain
        }
        guard isSHA256(evidence.evidenceSHA256) else {
            throw CoreDNSInfrastructureImageError.invalidEvidenceDigest
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func isOCIDigest(_ value: String) -> Bool {
        value.hasPrefix("sha256:") &&
            isSHA256(String(value.dropFirst("sha256:".count)))
    }
}
