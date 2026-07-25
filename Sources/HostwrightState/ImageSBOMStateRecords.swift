import Foundation

public enum ImageSBOMDocumentFormat:
    String,
    Codable,
    Equatable,
    Sendable
{
    case spdxJSON = "spdx-json"
    case cyclonedxJSON = "cyclonedx-json"
}

public struct ImageSBOMRecord:
    Codable,
    Equatable,
    Sendable
{
    public let projectID: String
    public let serviceName: String
    public let descriptorDigest: String
    public let policySHA256: String
    public let format: ImageSBOMDocumentFormat
    public let documentDigest: String
    public let documentMediaType: String
    public let evidenceDiscoveryID: String
    public let evidenceGraphSHA256: String
    public let sbomReferrerDigest: String
    public let provenanceDescriptorDigest: String?
    public let provenanceReferrerDigest: String?
    public let componentCount: Int
    public let normalizedComponentsSHA256: String
    public let operationGroupID: String
    public let createdAt: String

    public init(
        projectID: String,
        serviceName: String,
        descriptorDigest: String,
        policySHA256: String,
        format: ImageSBOMDocumentFormat,
        documentDigest: String,
        documentMediaType: String,
        evidenceDiscoveryID: String,
        evidenceGraphSHA256: String,
        sbomReferrerDigest: String,
        provenanceDescriptorDigest: String? = nil,
        provenanceReferrerDigest: String? = nil,
        componentCount: Int,
        normalizedComponentsSHA256: String,
        operationGroupID: String,
        createdAt: String
    ) {
        self.projectID = projectID
        self.serviceName = serviceName
        self.descriptorDigest = descriptorDigest
        self.policySHA256 = policySHA256
        self.format = format
        self.documentDigest = documentDigest
        self.documentMediaType = documentMediaType
        self.evidenceDiscoveryID = evidenceDiscoveryID
        self.evidenceGraphSHA256 = evidenceGraphSHA256
        self.sbomReferrerDigest = sbomReferrerDigest
        self.provenanceDescriptorDigest = provenanceDescriptorDigest
        self.provenanceReferrerDigest = provenanceReferrerDigest
        self.componentCount = componentCount
        self.normalizedComponentsSHA256 = normalizedComponentsSHA256
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
    }
}
