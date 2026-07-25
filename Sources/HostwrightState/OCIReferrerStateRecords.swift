import Foundation

public struct OCIReferrerDiscoveryRecord:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let registryEndpoint: String
    public let repository: String
    public let subjectDigest: String
    public let artifactType: String?
    public let discoveryMode: String
    public let serverFilterApplied: Bool
    public let pageCount: Int
    public let descriptorCount: Int
    public let graphSHA256: String
    public let etag: String?
    public let complete: Bool
    public let observedAt: String
}

public struct OCIReferrerCachedObjectRecord:
    Equatable,
    Sendable
{
    public let digest: String
    public let mediaType: String
    public let size: Int
    public let objectKind: String
    public let payload: Data
    public let payloadSHA256: String
    public let childrenJSON: String
    public let createdAt: String
    public let lastAccessedAt: String
}

public struct OCIReferrerRetentionLeaseRecord:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let discoveryID: String
    public let ownerID: String
    public let fencingToken: String
    public let acquiredAt: String
    public let expiresAt: String
    public let releasedAt: String?
}

public struct OCIReferrerPublicationEvidence:
    Codable,
    Equatable,
    Sendable
{
    public let ownershipProofSHA256: String
    public let operationGroupID: String

    public init(
        ownershipProofSHA256: String,
        operationGroupID: String
    ) {
        self.ownershipProofSHA256 = ownershipProofSHA256
        self.operationGroupID = operationGroupID
    }
}

public struct OCIReferrerPublicationRecord:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let registryEndpoint: String
    public let repository: String
    public let subjectDigest: String
    public let referrerDigest: String
    public let ownershipProofSHA256: String
    public let operationGroupID: String
    public let cleanupEligible: Bool
    public let createdAt: String
    public let observedAt: String
}
