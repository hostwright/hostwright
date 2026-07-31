import Foundation

public enum CertificateSourceKind: String, Codable, CaseIterable, Sendable {
    case imported
    case localCA = "local-ca"
    case provider
}
public enum CertificateOwnershipKind: String, Codable, CaseIterable, Sendable { case external, managed }
public enum CertificateStatus: String, Codable, CaseIterable, Sendable {
    case creating
    case available
    case revoking
    case revoked
    case released
    case faulted
}
public enum CertificateRevocationStatus: String, Codable, CaseIterable, Sendable {
    case unknown, good, revoked
    case notApplicable = "not-applicable"
}

public struct CertificateStateRecord: Codable, Equatable, Sendable {
    public let id, projectUUID, manifestName, providerID, fencingToken: String
    public let generation, providerGeneration: Int64
    public let sourceKind: CertificateSourceKind
    public let ownershipKind: CertificateOwnershipKind
    public let leafSHA256, sanJSON, ekuJSON, notBefore, notAfter: String
    public let issuerSHA256: String?
    public let status: CertificateStatus
    public let revocationStatus: CertificateRevocationStatus
    public let statusCheckedAt: String?
    public let desiredSHA256: String
    public let observedSHA256: String?
    public let lifecycleState: NetworkStateResourceLifecycle
    public let finalizerState: NetworkStateFinalizer
    public let priorLeafSHA256: String?
    public let operationGroupID, createdAt, updatedAt: String

    public init(
        id: String,
        projectUUID: String,
        manifestName: String,
        generation: Int64,
        providerID: String,
        providerGeneration: Int64,
        fencingToken: String,
        sourceKind: CertificateSourceKind,
        ownershipKind: CertificateOwnershipKind,
        leafSHA256: String,
        issuerSHA256: String?,
        sanJSON: String,
        ekuJSON: String,
        notBefore: String,
        notAfter: String,
        status: CertificateStatus,
        revocationStatus: CertificateRevocationStatus,
        statusCheckedAt: String?,
        desiredSHA256: String,
        observedSHA256: String?,
        lifecycleState: NetworkStateResourceLifecycle,
        finalizerState: NetworkStateFinalizer,
        priorLeafSHA256: String? = nil,
        operationGroupID: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.projectUUID = projectUUID
        self.manifestName = manifestName
        self.generation = generation
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.fencingToken = fencingToken
        self.sourceKind = sourceKind
        self.ownershipKind = ownershipKind
        self.leafSHA256 = leafSHA256
        self.issuerSHA256 = issuerSHA256
        self.sanJSON = sanJSON
        self.ekuJSON = ekuJSON
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.status = status
        self.revocationStatus = revocationStatus
        self.statusCheckedAt = statusCheckedAt
        self.desiredSHA256 = desiredSHA256
        self.observedSHA256 = observedSHA256
        self.lifecycleState = lifecycleState
        self.finalizerState = finalizerState
        self.priorLeafSHA256 = priorLeafSHA256
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isStatePurgeable: Bool {
        lifecycleState == .deleted && finalizerState == .released
    }
}
