import Foundation

public enum ContentCacheKind: String, Codable, CaseIterable, Sendable {
    case runtimeImage = "runtime-image"
    case ociCacheObject = "oci-cache-object"
}

public enum ContentCachePinPolicy: String, Codable, CaseIterable, Sendable {
    case unpinned
    case operatorManaged = "operator"
    case policyManaged = "policy"
}

public enum ContentCacheLeaseMode: String, Codable, CaseIterable, Sendable {
    case shared
    case exclusiveDelete = "exclusive-delete"
}

public struct ContentCacheRecord: Codable, Equatable, Sendable {
    public let providerScope: String
    public let digest: String
    public let kind: ContentCacheKind
    public let sizeBytes: Int64
    public let pinPolicy: ContentCachePinPolicy
    public let createdAt: String
    public let observedAt: String
    public let lastUsedAt: String

    public init(
        providerScope: String,
        digest: String,
        kind: ContentCacheKind,
        sizeBytes: Int64,
        pinPolicy: ContentCachePinPolicy = .unpinned,
        createdAt: String,
        observedAt: String,
        lastUsedAt: String
    ) {
        self.providerScope = providerScope
        self.digest = digest
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.pinPolicy = pinPolicy
        self.createdAt = createdAt
        self.observedAt = observedAt
        self.lastUsedAt = lastUsedAt
    }
}

public struct ContentCacheReferenceRecord: Codable, Equatable, Sendable {
    public let id: String
    public let providerScope: String
    public let reference: String
    public let digest: String
    public let ownershipOperationID: String
    public let ownershipProofSHA256: String
    public let createdAt: String
    public let observedAt: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        providerScope: String,
        reference: String,
        digest: String,
        ownershipOperationID: String,
        ownershipProofSHA256: String,
        createdAt: String,
        observedAt: String
    ) {
        self.id = id
        self.providerScope = providerScope
        self.reference = reference
        self.digest = digest
        self.ownershipOperationID = ownershipOperationID
        self.ownershipProofSHA256 = ownershipProofSHA256
        self.createdAt = createdAt
        self.observedAt = observedAt
    }
}

public struct ContentCacheLeaseRecord: Codable, Equatable, Sendable {
    public let id: String
    public let providerScope: String
    public let digest: String
    public let reference: String?
    public let mode: ContentCacheLeaseMode
    public let ownerID: String
    public let purpose: String
    public let fencingToken: String
    public let acquiredAt: String
    public let expiresAt: String
    public let releasedAt: String?

    public init(
        id: String,
        providerScope: String,
        digest: String,
        reference: String?,
        mode: ContentCacheLeaseMode,
        ownerID: String,
        purpose: String,
        fencingToken: String,
        acquiredAt: String,
        expiresAt: String,
        releasedAt: String?
    ) {
        self.id = id
        self.providerScope = providerScope
        self.digest = digest
        self.reference = reference
        self.mode = mode
        self.ownerID = ownerID
        self.purpose = purpose
        self.fencingToken = fencingToken
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
        self.releasedAt = releasedAt
    }
}

public struct ContentCacheSnapshot: Codable, Equatable, Sendable {
    public let contents: [ContentCacheRecord]
    public let references: [ContentCacheReferenceRecord]
    public let activeLeases: [ContentCacheLeaseRecord]
    public let totalBytes: Int64
    public let pinnedBytes: Int64

    public init(
        contents: [ContentCacheRecord],
        references: [ContentCacheReferenceRecord],
        activeLeases: [ContentCacheLeaseRecord],
        totalBytes: Int64,
        pinnedBytes: Int64
    ) {
        self.contents = contents
        self.references = references
        self.activeLeases = activeLeases
        self.totalBytes = totalBytes
        self.pinnedBytes = pinnedBytes
    }
}
