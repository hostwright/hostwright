import CryptoKit
import Foundation
import HostwrightControlPlane

public enum ClusterMutationFenceError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidMutationID
    case invalidDigest(String)
    case invalidFencingToken
    case missingPredecessorAuthority
    case sourceBindingMismatch(String)
    case wirePayloadOutOfBounds(actualBytes: Int)
}

/// Source-only bounds for the immutable mutation-authority envelope.
public enum ClusterMutationFenceContract {
    public static let schemaVersion = 1
    public static let maximumMutationIDBytes = 128
    public static let maximumWireBytes = 4_096
}

/// Names the namespace of an authority digest so a desired-state predecessor cannot be
/// accidentally treated as a lease-record digest merely because its bytes happen to match.
public enum ClusterMutationAuthorityDigestKind: String, Codable, CaseIterable, Hashable,
    Sendable
{
    case predecessorRecord = "predecessor-record-v1"
    case leaseRecord = "lease-record-v1"
}

/// An immutable, caller-supplied view of the authority that must fence one mutation.
///
/// A snapshot validates and binds scalar identities only. It does not establish membership,
/// elect a leader, prove quorum, validate a live lease, authorize a runtime effect, or persist
/// anything. Callers must obtain the source records from a durable authority before using it.
public struct ClusterMutationAuthoritySnapshot: Codable, Equatable, Hashable, Comparable,
    Sendable
{
    public let clusterID: ClusterID
    public let membershipEpoch: ClusterMembershipEpoch
    public let actorNodeID: ClusterNodeID
    public let fencingToken: UInt64
    public let authorityDigestKind: ClusterMutationAuthorityDigestKind
    public let authorityRecordSHA256: String

    public var schemaVersion: Int {
        ClusterMutationFenceContract.schemaVersion
    }

    public init(
        clusterID: ClusterID,
        membershipEpoch: ClusterMembershipEpoch,
        actorNodeID: ClusterNodeID,
        fencingToken: UInt64,
        authorityDigestKind: ClusterMutationAuthorityDigestKind,
        authorityRecordSHA256: String
    ) throws {
        guard fencingToken > 0 else {
            throw ClusterMutationFenceError.invalidFencingToken
        }
        guard ClusterMutationFenceValidation.isSHA256(authorityRecordSHA256) else {
            throw ClusterMutationFenceError.invalidDigest("authorityRecordSHA256")
        }
        self.clusterID = clusterID
        self.membershipEpoch = membershipEpoch
        self.actorNodeID = actorNodeID
        self.fencingToken = fencingToken
        self.authorityDigestKind = authorityDigestKind
        self.authorityRecordSHA256 = authorityRecordSHA256
    }

    /// Derives session authority only when the credential-free handoff and lease record bind
    /// the exact same cluster, node, membership epoch, and fencing token.
    public init(
        sessionHandoff: ClusterSessionHandoff,
        authorityLease: ClusterControlPlaneLeaseRecord
    ) throws {
        try sessionHandoff.validate()
        try ClusterMutationFenceValidation.requireAlignment(
            clusterID: sessionHandoff.clusterID,
            actorNodeID: sessionHandoff.nodeID,
            membershipEpoch: sessionHandoff.membershipEpoch,
            fencingToken: sessionHandoff.fencingToken,
            lease: authorityLease
        )
        try self.init(
            clusterID: sessionHandoff.clusterID,
            membershipEpoch: sessionHandoff.membershipEpoch,
            actorNodeID: sessionHandoff.nodeID,
            fencingToken: sessionHandoff.fencingToken,
            authorityDigestKind: .leaseRecord,
            authorityRecordSHA256: authorityLease.canonicalSHA256()
        )
    }

    /// Derives a predecessor-bound desired-state snapshot. Genesis records deliberately fail
    /// closed because they contain no durable predecessor authority.
    public init(replicatedDesiredState state: ClusterReplicatedDesiredState) throws {
        guard let predecessorRecordSHA256 = state.predecessorRecordSHA256 else {
            throw ClusterMutationFenceError.missingPredecessorAuthority
        }
        try self.init(
            clusterID: state.clusterID,
            membershipEpoch: state.membershipEpoch,
            actorNodeID: state.authorNodeID,
            fencingToken: state.fencingToken,
            authorityDigestKind: .predecessorRecord,
            authorityRecordSHA256: predecessorRecordSHA256
        )
    }

    /// Derives authority from the exact canonical lease record supplied by the caller.
    public init(controlPlaneLease lease: ClusterControlPlaneLeaseRecord) throws {
        try self.init(
            clusterID: lease.clusterID,
            membershipEpoch: lease.membershipEpoch,
            actorNodeID: lease.leaderNodeID,
            fencingToken: lease.fencingToken,
            authorityDigestKind: .leaseRecord,
            authorityRecordSHA256: lease.canonicalSHA256()
        )
    }

    public func canonicalJSON() throws -> Data {
        try ClusterMutationFenceWireContract.encodeSnapshot(self)
    }

    public func canonicalSHA256() throws -> String {
        ClusterMutationFenceValidation.sha256(try canonicalJSON())
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.clusterID != rhs.clusterID { return lhs.clusterID < rhs.clusterID }
        if lhs.membershipEpoch != rhs.membershipEpoch {
            return lhs.membershipEpoch < rhs.membershipEpoch
        }
        if lhs.actorNodeID != rhs.actorNodeID { return lhs.actorNodeID < rhs.actorNodeID }
        if lhs.fencingToken != rhs.fencingToken { return lhs.fencingToken < rhs.fencingToken }
        if lhs.authorityDigestKind != rhs.authorityDigestKind {
            return lhs.authorityDigestKind.rawValue < rhs.authorityDigestKind.rawValue
        }
        return lhs.authorityRecordSHA256 < rhs.authorityRecordSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case clusterID
        case membershipEpoch
        case actorNodeID
        case fencingToken
        case authorityDigestKind
        case authorityRecordSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == ClusterMutationFenceContract.schemaVersion else {
            throw ClusterMutationFenceError.unsupportedSchemaVersion(schemaVersion)
        }
        try self.init(
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            membershipEpoch: ClusterMembershipEpoch(
                container.decode(UInt64.self, forKey: .membershipEpoch)
            ),
            actorNodeID: container.decode(ClusterNodeID.self, forKey: .actorNodeID),
            fencingToken: container.decode(UInt64.self, forKey: .fencingToken),
            authorityDigestKind: container.decode(
                ClusterMutationAuthorityDigestKind.self,
                forKey: .authorityDigestKind
            ),
            authorityRecordSHA256: container.decode(
                String.self,
                forKey: .authorityRecordSHA256
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(clusterID, forKey: .clusterID)
        try container.encode(membershipEpoch.value, forKey: .membershipEpoch)
        try container.encode(actorNodeID, forKey: .actorNodeID)
        try container.encode(fencingToken, forKey: .fencingToken)
        try container.encode(authorityDigestKind, forKey: .authorityDigestKind)
        try container.encode(authorityRecordSHA256, forKey: .authorityRecordSHA256)
    }
}

public enum ClusterMutationProofSource: String, Codable, CaseIterable, Hashable, Sendable {
    case sessionHandoff = "session-handoff-v1"
    case replicatedDesiredState = "replicated-desired-state-v1"
    case controlPlaneLease = "control-plane-lease-v1"
}

/// A caller-derived binding to the exact canonical source record expected for one proof.
/// Only the typed source-record initializers can create this value; arbitrary digest strings
/// are not accepted as source context.
public struct ClusterMutationSourceRecordBinding: Equatable, Hashable, Sendable {
    public let source: ClusterMutationProofSource
    public let sourceRecordSHA256: String

    public init(sessionHandoff: ClusterSessionHandoff) throws {
        try sessionHandoff.validate()
        self.init(
            source: .sessionHandoff,
            sourceRecordSHA256: ClusterMutationFenceValidation.sha256(
                try sessionHandoff.canonicalData()
            )
        )
    }

    public init(replicatedDesiredState state: ClusterReplicatedDesiredState) throws {
        self.init(
            source: .replicatedDesiredState,
            sourceRecordSHA256: try state.canonicalSHA256()
        )
    }

    public init(controlPlaneLease lease: ClusterControlPlaneLeaseRecord) throws {
        self.init(
            source: .controlPlaneLease,
            sourceRecordSHA256: try lease.canonicalSHA256()
        )
    }

    private init(
        source: ClusterMutationProofSource,
        sourceRecordSHA256: String
    ) {
        self.source = source
        self.sourceRecordSHA256 = sourceRecordSHA256
    }
}

/// A redacted immutable proof that one mutation was bound to one source record and one
/// authority snapshot. It contains no certificate, secret, runtime handle, or raw payload.
public struct ClusterMutationProof: Codable, Equatable, Hashable, Comparable, Sendable {
    public let source: ClusterMutationProofSource
    public let sourceRecordSHA256: String
    public let mutationID: String
    public let mutationSHA256: String
    public let authority: ClusterMutationAuthoritySnapshot

    public var schemaVersion: Int {
        ClusterMutationFenceContract.schemaVersion
    }

    public init(
        mutationID: String,
        mutationSHA256: String,
        sessionHandoff: ClusterSessionHandoff,
        authorityLease: ClusterControlPlaneLeaseRecord
    ) throws {
        let authority = try ClusterMutationAuthoritySnapshot(
            sessionHandoff: sessionHandoff,
            authorityLease: authorityLease
        )
        try self.init(
            source: .sessionHandoff,
            sourceRecordSHA256: ClusterMutationFenceValidation.sha256(
                try sessionHandoff.canonicalData()
            ),
            mutationID: mutationID,
            mutationSHA256: mutationSHA256,
            authority: authority
        )
    }

    public init(
        mutationID: String,
        mutationSHA256: String,
        replicatedDesiredState state: ClusterReplicatedDesiredState
    ) throws {
        try self.init(
            source: .replicatedDesiredState,
            sourceRecordSHA256: state.canonicalSHA256(),
            mutationID: mutationID,
            mutationSHA256: mutationSHA256,
            authority: ClusterMutationAuthoritySnapshot(replicatedDesiredState: state)
        )
    }

    public init(
        mutationID: String,
        mutationSHA256: String,
        controlPlaneLease lease: ClusterControlPlaneLeaseRecord
    ) throws {
        let recordSHA256 = try lease.canonicalSHA256()
        try self.init(
            source: .controlPlaneLease,
            sourceRecordSHA256: recordSHA256,
            mutationID: mutationID,
            mutationSHA256: mutationSHA256,
            authority: ClusterMutationAuthoritySnapshot(controlPlaneLease: lease)
        )
    }

    private init(
        source: ClusterMutationProofSource,
        sourceRecordSHA256: String,
        mutationID: String,
        mutationSHA256: String,
        authority: ClusterMutationAuthoritySnapshot
    ) throws {
        guard ClusterMutationFenceValidation.isSHA256(sourceRecordSHA256) else {
            throw ClusterMutationFenceError.invalidDigest("sourceRecordSHA256")
        }
        guard ClusterMutationFenceValidation.isMutationID(mutationID) else {
            throw ClusterMutationFenceError.invalidMutationID
        }
        guard ClusterMutationFenceValidation.isSHA256(mutationSHA256) else {
            throw ClusterMutationFenceError.invalidDigest("mutationSHA256")
        }
        switch source {
        case .sessionHandoff:
            guard authority.authorityDigestKind == .leaseRecord else {
                throw ClusterMutationFenceError.sourceBindingMismatch(
                    "authorityDigestKind"
                )
            }
        case .replicatedDesiredState:
            guard authority.authorityDigestKind == .predecessorRecord else {
                throw ClusterMutationFenceError.sourceBindingMismatch(
                    "authorityDigestKind"
                )
            }
        case .controlPlaneLease:
            guard authority.authorityDigestKind == .leaseRecord,
                  sourceRecordSHA256 == authority.authorityRecordSHA256 else {
                throw ClusterMutationFenceError.sourceBindingMismatch(
                    "leaseRecordSHA256"
                )
            }
        }
        self.source = source
        self.sourceRecordSHA256 = sourceRecordSHA256
        self.mutationID = mutationID
        self.mutationSHA256 = mutationSHA256
        self.authority = authority
    }

    public func canonicalJSON() throws -> Data {
        try ClusterMutationFenceWireContract.encodeProof(self)
    }

    public func canonicalSHA256() throws -> String {
        ClusterMutationFenceValidation.sha256(try canonicalJSON())
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.mutationID != rhs.mutationID { return lhs.mutationID < rhs.mutationID }
        if lhs.authority != rhs.authority { return lhs.authority < rhs.authority }
        if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
        if lhs.sourceRecordSHA256 != rhs.sourceRecordSHA256 {
            return lhs.sourceRecordSHA256 < rhs.sourceRecordSHA256
        }
        return lhs.mutationSHA256 < rhs.mutationSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case source
        case sourceRecordSHA256
        case mutationID
        case mutationSHA256
        case clusterID
        case membershipEpoch
        case actorNodeID
        case fencingToken
        case authorityDigestKind
        case authorityRecordSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == ClusterMutationFenceContract.schemaVersion else {
            throw ClusterMutationFenceError.unsupportedSchemaVersion(schemaVersion)
        }
        let authority = try ClusterMutationAuthoritySnapshot(
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            membershipEpoch: ClusterMembershipEpoch(
                container.decode(UInt64.self, forKey: .membershipEpoch)
            ),
            actorNodeID: container.decode(ClusterNodeID.self, forKey: .actorNodeID),
            fencingToken: container.decode(UInt64.self, forKey: .fencingToken),
            authorityDigestKind: container.decode(
                ClusterMutationAuthorityDigestKind.self,
                forKey: .authorityDigestKind
            ),
            authorityRecordSHA256: container.decode(
                String.self,
                forKey: .authorityRecordSHA256
            )
        )
        try self.init(
            source: container.decode(ClusterMutationProofSource.self, forKey: .source),
            sourceRecordSHA256: container.decode(String.self, forKey: .sourceRecordSHA256),
            mutationID: container.decode(String.self, forKey: .mutationID),
            mutationSHA256: container.decode(String.self, forKey: .mutationSHA256),
            authority: authority
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(source, forKey: .source)
        try container.encode(sourceRecordSHA256, forKey: .sourceRecordSHA256)
        try container.encode(mutationID, forKey: .mutationID)
        try container.encode(mutationSHA256, forKey: .mutationSHA256)
        try container.encode(authority.clusterID, forKey: .clusterID)
        try container.encode(authority.membershipEpoch.value, forKey: .membershipEpoch)
        try container.encode(authority.actorNodeID, forKey: .actorNodeID)
        try container.encode(authority.fencingToken, forKey: .fencingToken)
        try container.encode(authority.authorityDigestKind, forKey: .authorityDigestKind)
        try container.encode(authority.authorityRecordSHA256, forKey: .authorityRecordSHA256)
    }
}

public enum ClusterMutationFenceRejection: Equatable, Sendable {
    case invalidProofEncoding
    case missingSourceRecordBinding
    case sourceRecordKindMismatch(
        expected: ClusterMutationProofSource,
        actual: ClusterMutationProofSource
    )
    case sourceRecordDigestMismatch(expectedSHA256: String, actualSHA256: String)
    case wrongCluster(expected: ClusterID, actual: ClusterID)
    case staleMembershipEpoch(
        expected: ClusterMembershipEpoch,
        actual: ClusterMembershipEpoch
    )
    case newerMembershipEpochAmbiguous(
        expected: ClusterMembershipEpoch,
        actual: ClusterMembershipEpoch
    )
    case staleFencingToken(expected: UInt64, actual: UInt64)
    case wrongFencingToken(expected: UInt64, actual: UInt64)
    case wrongActor(expected: ClusterNodeID, actual: ClusterNodeID)
    case authorityDigestMismatch(
        expectedKind: ClusterMutationAuthorityDigestKind,
        expectedSHA256: String,
        actualKind: ClusterMutationAuthorityDigestKind,
        actualSHA256: String
    )
    case fencingTokenReplayConflict(
        currentMutationID: String,
        proposedMutationID: String
    )
}

public enum ClusterMutationFenceDecision: Equatable, Sendable {
    case accepted(ClusterMutationProof)
    case exactReplay(ClusterMutationProof)
    case rejected(ClusterMutationFenceRejection)
}

/// Pure classification for one already-derived proof against one caller-supplied authority and
/// one binding derived from the exact expected source record.
///
/// This evaluator does not elect, persist, replicate, contact etcd, authorize a network peer,
/// invoke a provider, execute a mutation, or prove distributed fencing. Acceptance only means
/// that the immutable values passed to this function agree exactly.
public struct ClusterMutationFenceEvaluator: Sendable {
    public init() {}

    public func evaluate(
        current: ClusterMutationProof?,
        proposed: ClusterMutationProof,
        expectedAuthority: ClusterMutationAuthoritySnapshot,
        expectedSourceRecord: ClusterMutationSourceRecordBinding?
    ) -> ClusterMutationFenceDecision {
        guard let expectedSourceRecord else {
            return .rejected(.missingSourceRecordBinding)
        }
        guard proposed.source == expectedSourceRecord.source else {
            return .rejected(
                .sourceRecordKindMismatch(
                    expected: expectedSourceRecord.source,
                    actual: proposed.source
                )
            )
        }
        guard proposed.sourceRecordSHA256 == expectedSourceRecord.sourceRecordSHA256 else {
            return .rejected(
                .sourceRecordDigestMismatch(
                    expectedSHA256: expectedSourceRecord.sourceRecordSHA256,
                    actualSHA256: proposed.sourceRecordSHA256
                )
            )
        }

        let actual = proposed.authority
        guard actual.clusterID == expectedAuthority.clusterID else {
            return .rejected(
                .wrongCluster(
                    expected: expectedAuthority.clusterID,
                    actual: actual.clusterID
                )
            )
        }
        if actual.membershipEpoch < expectedAuthority.membershipEpoch {
            return .rejected(
                .staleMembershipEpoch(
                    expected: expectedAuthority.membershipEpoch,
                    actual: actual.membershipEpoch
                )
            )
        }
        if actual.membershipEpoch > expectedAuthority.membershipEpoch {
            return .rejected(
                .newerMembershipEpochAmbiguous(
                    expected: expectedAuthority.membershipEpoch,
                    actual: actual.membershipEpoch
                )
            )
        }
        if actual.fencingToken < expectedAuthority.fencingToken {
            return .rejected(
                .staleFencingToken(
                    expected: expectedAuthority.fencingToken,
                    actual: actual.fencingToken
                )
            )
        }
        guard actual.fencingToken == expectedAuthority.fencingToken else {
            return .rejected(
                .wrongFencingToken(
                    expected: expectedAuthority.fencingToken,
                    actual: actual.fencingToken
                )
            )
        }
        guard actual.actorNodeID == expectedAuthority.actorNodeID else {
            return .rejected(
                .wrongActor(
                    expected: expectedAuthority.actorNodeID,
                    actual: actual.actorNodeID
                )
            )
        }
        guard actual.authorityDigestKind == expectedAuthority.authorityDigestKind,
              actual.authorityRecordSHA256 == expectedAuthority.authorityRecordSHA256 else {
            return .rejected(
                .authorityDigestMismatch(
                    expectedKind: expectedAuthority.authorityDigestKind,
                    expectedSHA256: expectedAuthority.authorityRecordSHA256,
                    actualKind: actual.authorityDigestKind,
                    actualSHA256: actual.authorityRecordSHA256
                )
            )
        }
        if let current, current.authority == expectedAuthority {
            if current == proposed {
                return .exactReplay(proposed)
            }
            return .rejected(
                .fencingTokenReplayConflict(
                    currentMutationID: current.mutationID,
                    proposedMutationID: proposed.mutationID
                )
            )
        }
        return .accepted(proposed)
    }

    public func evaluate(
        current: ClusterMutationProof?,
        encodedProposed: Data,
        expectedAuthority: ClusterMutationAuthoritySnapshot,
        expectedSourceRecord: ClusterMutationSourceRecordBinding?
    ) -> ClusterMutationFenceDecision {
        guard let proposed = try? ClusterMutationFenceWireContract.decodeProof(
            encodedProposed
        ) else {
            return .rejected(.invalidProofEncoding)
        }
        return evaluate(
            current: current,
            proposed: proposed,
            expectedAuthority: expectedAuthority,
            expectedSourceRecord: expectedSourceRecord
        )
    }
}

/// Strict, bounded JSON entry points. Untrusted proof bytes must use these decoders rather than
/// a bare `JSONDecoder`, whose normal behavior is to ignore unknown object keys.
public enum ClusterMutationFenceWireContract {
    public static let snapshotAllowedKeys: Set<String> = [
        "schemaVersion", "clusterID", "membershipEpoch", "actorNodeID",
        "fencingToken", "authorityDigestKind", "authorityRecordSHA256",
    ]
    public static let proofAllowedKeys: Set<String> = snapshotAllowedKeys.union([
        "source", "sourceRecordSHA256", "mutationID", "mutationSHA256",
    ])

    public static func encodeSnapshot(
        _ snapshot: ClusterMutationAuthoritySnapshot
    ) throws -> Data {
        try bounded(encoder().encode(snapshot))
    }

    public static func encodeProof(_ proof: ClusterMutationProof) throws -> Data {
        try bounded(encoder().encode(proof))
    }

    public static func decodeSnapshot(
        _ data: Data
    ) throws -> ClusterMutationAuthoritySnapshot {
        let boundedData = try bounded(data)
        return try Phase09StrictDecoder.decode(
            ClusterMutationAuthoritySnapshot.self,
            from: boundedData,
            allowedKeys: snapshotAllowedKeys,
            requiredKeys: snapshotAllowedKeys
        )
    }

    public static func decodeProof(_ data: Data) throws -> ClusterMutationProof {
        let boundedData = try bounded(data)
        return try Phase09StrictDecoder.decode(
            ClusterMutationProof.self,
            from: boundedData,
            allowedKeys: proofAllowedKeys,
            requiredKeys: proofAllowedKeys
        )
    }

    private static func bounded(_ data: Data) throws -> Data {
        guard !data.isEmpty,
              data.count <= ClusterMutationFenceContract.maximumWireBytes else {
            throw ClusterMutationFenceError.wirePayloadOutOfBounds(
                actualBytes: data.count
            )
        }
        return data
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private enum ClusterMutationFenceValidation {
    static func requireAlignment(
        clusterID: ClusterID,
        actorNodeID: ClusterNodeID,
        membershipEpoch: ClusterMembershipEpoch,
        fencingToken: UInt64,
        lease: ClusterControlPlaneLeaseRecord
    ) throws {
        guard clusterID == lease.clusterID else {
            throw ClusterMutationFenceError.sourceBindingMismatch("clusterID")
        }
        guard actorNodeID == lease.leaderNodeID else {
            throw ClusterMutationFenceError.sourceBindingMismatch("actorNodeID")
        }
        guard membershipEpoch == lease.membershipEpoch else {
            throw ClusterMutationFenceError.sourceBindingMismatch("membershipEpoch")
        }
        guard fencingToken == lease.fencingToken else {
            throw ClusterMutationFenceError.sourceBindingMismatch("fencingToken")
        }
    }

    static func isMutationID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...ClusterMutationFenceContract.maximumMutationIDBytes)
            .contains(bytes.count) else {
            return false
        }
        return bytes.allSatisfy { byte in
            isAlphaNumeric(byte) || byte == 45 || byte == 46 || byte == 95
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }
}
