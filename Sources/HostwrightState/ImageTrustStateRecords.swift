import Foundation
import HostwrightCore

public struct ImageTrustVerificationRecord:
    Codable,
    Equatable,
    Sendable
{
    public let projectID: String
    public let serviceName: String
    public let descriptorDigest: String
    public let policySHA256: String
    public let evidenceGraphSHA256: String
    public let evidenceDiscoveryID: String
    public let trustedRootSHA256: String
    public let verifierVersion: String
    public let matchedAuthorityIDs: [String]
    public let threshold: Int
    public let outcome: String
    public let exceptionID: String?
    public let operationGroupID: String
    public let createdAt: String

    public init(
        projectID: String,
        serviceName: String,
        descriptorDigest: String,
        policySHA256: String,
        evidenceGraphSHA256: String,
        evidenceDiscoveryID: String,
        trustedRootSHA256: String,
        verifierVersion: String,
        matchedAuthorityIDs: [String],
        threshold: Int,
        outcome: String,
        exceptionID: String? = nil,
        operationGroupID: String,
        createdAt: String
    ) {
        self.projectID = projectID
        self.serviceName = serviceName
        self.descriptorDigest = descriptorDigest
        self.policySHA256 = policySHA256
        self.evidenceGraphSHA256 = evidenceGraphSHA256
        self.evidenceDiscoveryID = evidenceDiscoveryID
        self.trustedRootSHA256 = trustedRootSHA256
        self.verifierVersion = verifierVersion
        self.matchedAuthorityIDs = matchedAuthorityIDs
        self.threshold = threshold
        self.outcome = outcome
        self.exceptionID = exceptionID
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
    }
}

public struct ImageTrustExceptionRecord:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let projectID: String
    public let serviceName: String
    public let descriptorDigest: String
    public let policySHA256: String
    public let reason: String
    public let approver: String
    public let approvedAt: String
    public let expiresAt: String
    public let revokedAt: String?
    public let idempotencyKey: String

    public init(
        projectID: String,
        serviceName: String,
        descriptorDigest: String,
        policySHA256: String,
        reason: String,
        approver: String,
        approvedAt: String,
        expiresAt: String,
        revokedAt: String? = nil,
        idempotencyKey: String
    ) {
        let canonicalKey = idempotencyKey.lowercased()
        self.id = HostwrightResourceUUID.legacy(
            kind: "image-trust-exception",
            identifier: canonicalKey
        )
        self.projectID = projectID
        self.serviceName = serviceName
        self.descriptorDigest = descriptorDigest
        self.policySHA256 = policySHA256
        self.reason = reason
        self.approver = approver
        self.approvedAt = approvedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.idempotencyKey = canonicalKey
    }
}

public struct ImageTrustSubjectManifestRecord:
    Equatable,
    Sendable
{
    public let registryEndpoint: String
    public let repository: String
    public let descriptorDigest: String
    public let payload: Data
    public let payloadSHA256: String
    public let observedAt: String

    public init(
        registryEndpoint: String,
        repository: String,
        descriptorDigest: String,
        payload: Data,
        payloadSHA256: String,
        observedAt: String
    ) {
        self.registryEndpoint = registryEndpoint
        self.repository = repository
        self.descriptorDigest = descriptorDigest
        self.payload = payload
        self.payloadSHA256 = payloadSHA256
        self.observedAt = observedAt
    }
}
