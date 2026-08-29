import CryptoKit
import Foundation
import HostwrightControlPlane

public enum ClusterControlPlaneLeaseError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidTerm
    case invalidSequence
    case invalidPredecessor
    case invalidFencingToken
    case invalidTimestamp
    case invalidLifetime
    case invalidExpectation
    case wirePayloadOutOfBounds(actualBytes: Int)
    case staleCAS
    case clusterMismatch
    case membershipEpochMismatch(
        expected: ClusterMembershipEpoch,
        actual: ClusterMembershipEpoch
    )
    case membershipEpochRegression
    case fencingTokenMismatch(expected: UInt64, actual: UInt64)
    case staleFencingToken
    case fencingTokenDidNotAdvance
    case leaderNodeMismatch(expected: ClusterNodeID, actual: ClusterNodeID)
    case activeLeaseHeldByOther(ClusterNodeID)
    case termGap(expected: UInt64, actual: UInt64)
    case sequenceGap(expected: UInt64, actual: UInt64)
    case counterOverflow
    case samePositionConflict
    case timestampRegression
    case issuedAtMismatch(expected: UInt64, actual: UInt64)
    case expiryDidNotAdvance
    case forgedReplay
}

/// Source-only validation limits, not an executable election or failover contract.
public enum ClusterControlPlaneLeaseContract {
    public static let schemaVersion = 1
    public static let maximumLifetimeMilliseconds: UInt64 = 15_000
    public static let maximumWireBytes = 4_096
}

public struct ClusterControlPlaneLeaseRecord: Codable, Equatable, Hashable, Sendable {
    public let clusterID: ClusterID
    public let leaderNodeID: ClusterNodeID
    public let membershipEpoch: ClusterMembershipEpoch
    public let fencingToken: UInt64
    public let term: UInt64
    public let sequence: UInt64
    public let issuedAtMilliseconds: UInt64
    public let expiresAtMilliseconds: UInt64
    public let predecessorRecordSHA256: String?

    public var schemaVersion: Int {
        ClusterControlPlaneLeaseContract.schemaVersion
    }

    public init(
        clusterID: ClusterID,
        leaderNodeID: ClusterNodeID,
        membershipEpoch: ClusterMembershipEpoch,
        fencingToken: UInt64,
        term: UInt64,
        sequence: UInt64,
        issuedAtMilliseconds: UInt64,
        expiresAtMilliseconds: UInt64,
        predecessorRecordSHA256: String?
    ) throws {
        guard term > 0 else {
            throw ClusterControlPlaneLeaseError.invalidTerm
        }
        guard sequence > 0 else {
            throw ClusterControlPlaneLeaseError.invalidSequence
        }
        let isInitialRecord = term == 1 && sequence == 1
        if isInitialRecord {
            guard predecessorRecordSHA256 == nil else {
                throw ClusterControlPlaneLeaseError.invalidPredecessor
            }
        } else {
            guard let predecessorRecordSHA256,
                  ClusterControlPlaneLeaseValidation.isSHA256(
                    predecessorRecordSHA256
                  ) else {
                throw ClusterControlPlaneLeaseError.invalidPredecessor
            }
        }
        guard fencingToken > 0 else {
            throw ClusterControlPlaneLeaseError.invalidFencingToken
        }
        guard issuedAtMilliseconds > 0,
              expiresAtMilliseconds > issuedAtMilliseconds else {
            throw ClusterControlPlaneLeaseError.invalidTimestamp
        }
        let lifetime = expiresAtMilliseconds - issuedAtMilliseconds
        guard lifetime <= ClusterControlPlaneLeaseContract.maximumLifetimeMilliseconds else {
            throw ClusterControlPlaneLeaseError.invalidLifetime
        }

        self.clusterID = clusterID
        self.leaderNodeID = leaderNodeID
        self.membershipEpoch = membershipEpoch
        self.fencingToken = fencingToken
        self.term = term
        self.sequence = sequence
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.predecessorRecordSHA256 = predecessorRecordSHA256
    }

    /// Expiry is a half-open boundary: the record is expired when `now >= expiresAt`.
    /// The scalar is supplied by the caller; this comparison does not establish clock trust
    /// or synchronization between processes or hosts.
    public func isExpired(atMilliseconds nowMilliseconds: UInt64) -> Bool {
        nowMilliseconds >= expiresAtMilliseconds
    }

    public func canonicalJSON() throws -> Data {
        try ClusterControlPlaneLeaseWireContract.encode(self)
    }

    public func canonicalSHA256() throws -> String {
        ClusterControlPlaneLeaseValidation.sha256(try canonicalJSON())
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case clusterID
        case leaderNodeID
        case membershipEpoch
        case fencingToken
        case term
        case sequence
        case issuedAtMilliseconds
        case expiresAtMilliseconds
        case predecessorRecordSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == ClusterControlPlaneLeaseContract.schemaVersion else {
            throw ClusterControlPlaneLeaseError.unsupportedSchemaVersion(schemaVersion)
        }
        guard container.contains(.predecessorRecordSHA256) else {
            throw ClusterControlPlaneLeaseError.invalidPredecessor
        }
        try self.init(
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            leaderNodeID: container.decode(ClusterNodeID.self, forKey: .leaderNodeID),
            membershipEpoch: ClusterMembershipEpoch(
                container.decode(UInt64.self, forKey: .membershipEpoch)
            ),
            fencingToken: container.decode(UInt64.self, forKey: .fencingToken),
            term: container.decode(UInt64.self, forKey: .term),
            sequence: container.decode(UInt64.self, forKey: .sequence),
            issuedAtMilliseconds: container.decode(
                UInt64.self,
                forKey: .issuedAtMilliseconds
            ),
            expiresAtMilliseconds: container.decode(
                UInt64.self,
                forKey: .expiresAtMilliseconds
            ),
            predecessorRecordSHA256: container.decodeIfPresent(
                String.self,
                forKey: .predecessorRecordSHA256
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(clusterID, forKey: .clusterID)
        try container.encode(leaderNodeID, forKey: .leaderNodeID)
        try container.encode(membershipEpoch.value, forKey: .membershipEpoch)
        try container.encode(fencingToken, forKey: .fencingToken)
        try container.encode(term, forKey: .term)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(issuedAtMilliseconds, forKey: .issuedAtMilliseconds)
        try container.encode(expiresAtMilliseconds, forKey: .expiresAtMilliseconds)
        if let predecessorRecordSHA256 {
            try container.encode(
                predecessorRecordSHA256,
                forKey: .predecessorRecordSHA256
            )
        } else {
            try container.encodeNil(forKey: .predecessorRecordSHA256)
        }
    }
}

public enum ClusterControlPlaneLeaseExpectation: Equatable, Hashable, Sendable {
    case absent
    case record(term: UInt64, recordSHA256: String)
}

public struct ClusterControlPlaneLeaseProposal: Codable, Equatable, Hashable, Sendable {
    public let expectation: ClusterControlPlaneLeaseExpectation
    public let next: ClusterControlPlaneLeaseRecord

    public init(
        expectation: ClusterControlPlaneLeaseExpectation,
        next: ClusterControlPlaneLeaseRecord
    ) throws {
        if case .record(let term, let recordSHA256) = expectation {
            guard term > 0,
                  ClusterControlPlaneLeaseValidation.isSHA256(recordSHA256) else {
                throw ClusterControlPlaneLeaseError.invalidExpectation
            }
        }
        self.expectation = expectation
        self.next = next
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case expectedTerm
        case expectedRecordSHA256
        case clusterID
        case leaderNodeID
        case membershipEpoch
        case fencingToken
        case term
        case sequence
        case issuedAtMilliseconds
        case expiresAtMilliseconds
        case predecessorRecordSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == ClusterControlPlaneLeaseContract.schemaVersion else {
            throw ClusterControlPlaneLeaseError.unsupportedSchemaVersion(schemaVersion)
        }
        guard container.contains(.expectedTerm),
              container.contains(.expectedRecordSHA256),
              container.contains(.predecessorRecordSHA256) else {
            throw ClusterControlPlaneLeaseError.invalidExpectation
        }

        let expectedTerm = try container.decodeIfPresent(UInt64.self, forKey: .expectedTerm)
        let expectedRecordSHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .expectedRecordSHA256
        )
        let expectation: ClusterControlPlaneLeaseExpectation
        switch (expectedTerm, expectedRecordSHA256) {
        case (nil, nil):
            expectation = .absent
        case (.some(let term), .some(let digest)):
            expectation = .record(term: term, recordSHA256: digest)
        default:
            throw ClusterControlPlaneLeaseError.invalidExpectation
        }

        let next = try ClusterControlPlaneLeaseRecord(
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            leaderNodeID: container.decode(ClusterNodeID.self, forKey: .leaderNodeID),
            membershipEpoch: ClusterMembershipEpoch(
                container.decode(UInt64.self, forKey: .membershipEpoch)
            ),
            fencingToken: container.decode(UInt64.self, forKey: .fencingToken),
            term: container.decode(UInt64.self, forKey: .term),
            sequence: container.decode(UInt64.self, forKey: .sequence),
            issuedAtMilliseconds: container.decode(
                UInt64.self,
                forKey: .issuedAtMilliseconds
            ),
            expiresAtMilliseconds: container.decode(
                UInt64.self,
                forKey: .expiresAtMilliseconds
            ),
            predecessorRecordSHA256: container.decodeIfPresent(
                String.self,
                forKey: .predecessorRecordSHA256
            )
        )
        try self.init(expectation: expectation, next: next)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(next.schemaVersion, forKey: .schemaVersion)
        switch expectation {
        case .absent:
            try container.encodeNil(forKey: .expectedTerm)
            try container.encodeNil(forKey: .expectedRecordSHA256)
        case .record(let term, let recordSHA256):
            try container.encode(term, forKey: .expectedTerm)
            try container.encode(recordSHA256, forKey: .expectedRecordSHA256)
        }
        try container.encode(next.clusterID, forKey: .clusterID)
        try container.encode(next.leaderNodeID, forKey: .leaderNodeID)
        try container.encode(next.membershipEpoch.value, forKey: .membershipEpoch)
        try container.encode(next.fencingToken, forKey: .fencingToken)
        try container.encode(next.term, forKey: .term)
        try container.encode(next.sequence, forKey: .sequence)
        try container.encode(
            next.issuedAtMilliseconds,
            forKey: .issuedAtMilliseconds
        )
        try container.encode(
            next.expiresAtMilliseconds,
            forKey: .expiresAtMilliseconds
        )
        if let predecessorRecordSHA256 = next.predecessorRecordSHA256 {
            try container.encode(
                predecessorRecordSHA256,
                forKey: .predecessorRecordSHA256
            )
        } else {
            try container.encodeNil(forKey: .predecessorRecordSHA256)
        }
    }
}

/// A caller-supplied authority snapshot. Constructing this value does not prove membership,
/// quorum, an etcd lease, an election result, or permission to mutate cluster state.
public struct ClusterControlPlaneLeaseAuthority: Equatable, Hashable, Sendable {
    public let clusterID: ClusterID
    public let nodeID: ClusterNodeID
    public let membershipEpoch: ClusterMembershipEpoch
    public let fencingToken: UInt64

    public init(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        membershipEpoch: ClusterMembershipEpoch,
        fencingToken: UInt64
    ) throws {
        guard fencingToken > 0 else {
            throw ClusterControlPlaneLeaseError.invalidFencingToken
        }
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.membershipEpoch = membershipEpoch
        self.fencingToken = fencingToken
    }
}

public enum ClusterControlPlaneLeaseDisposition: Equatable, Sendable {
    case acquire(ClusterControlPlaneLeaseRecord)
    case renew(ClusterControlPlaneLeaseRecord)
    case replaceExpired(ClusterControlPlaneLeaseRecord)
    case exactReplay(ClusterControlPlaneLeaseRecord)
}

/// A bounded, immutable classifier for one caller-supplied lease CAS transition.
///
/// This seam does not select a leader, campaign, resign, persist or replicate records, contact
/// etcd, establish quorum, monitor health or watchdogs, fence mutations, detect partitions,
/// fail over, or prove single leadership across processes or hosts. The caller must provide a
/// trustworthy clock sample and durable CAS behavior; this type makes no synchronized-clock or
/// multi-host safety claim.
public struct ClusterControlPlaneLeaseDecisionEvaluator: Sendable {
    public init() {}

    public func decide(
        current: ClusterControlPlaneLeaseRecord?,
        proposal: ClusterControlPlaneLeaseProposal,
        authority: ClusterControlPlaneLeaseAuthority,
        nowMilliseconds: UInt64
    ) throws -> ClusterControlPlaneLeaseDisposition {
        guard nowMilliseconds > 0 else {
            throw ClusterControlPlaneLeaseError.invalidTimestamp
        }

        let next = proposal.next
        try validate(next: next, against: authority)

        if let current {
            guard current.clusterID == authority.clusterID,
                  current.clusterID == next.clusterID else {
                throw ClusterControlPlaneLeaseError.clusterMismatch
            }
            guard authority.membershipEpoch >= current.membershipEpoch else {
                throw ClusterControlPlaneLeaseError.membershipEpochRegression
            }
            guard authority.fencingToken >= current.fencingToken else {
                throw ClusterControlPlaneLeaseError.staleFencingToken
            }
            guard nowMilliseconds >= current.issuedAtMilliseconds else {
                throw ClusterControlPlaneLeaseError.timestampRegression
            }

            if current == next {
                if current.term == 1,
                   current.sequence == 1,
                   current.predecessorRecordSHA256 == nil,
                   proposal.expectation == .absent {
                    return .exactReplay(current)
                }
                return try replay(
                    current: current,
                    expectation: proposal.expectation
                )
            }
        }

        guard next.issuedAtMilliseconds == nowMilliseconds else {
            throw ClusterControlPlaneLeaseError.issuedAtMismatch(
                expected: nowMilliseconds,
                actual: next.issuedAtMilliseconds
            )
        }

        guard let current else {
            guard proposal.expectation == .absent else {
                throw ClusterControlPlaneLeaseError.staleCAS
            }
            guard next.term == 1 else {
                throw ClusterControlPlaneLeaseError.termGap(expected: 1, actual: next.term)
            }
            guard next.sequence == 1 else {
                throw ClusterControlPlaneLeaseError.sequenceGap(
                    expected: 1,
                    actual: next.sequence
                )
            }
            return .acquire(next)
        }

        let currentRecordSHA256 = try current.canonicalSHA256()
        guard case .record(let expectedTerm, let expectedRecordSHA256)
            = proposal.expectation,
              expectedTerm == current.term,
              expectedRecordSHA256 == currentRecordSHA256 else {
            throw ClusterControlPlaneLeaseError.staleCAS
        }
        guard next.predecessorRecordSHA256 == currentRecordSHA256 else {
            throw ClusterControlPlaneLeaseError.staleCAS
        }
        if next.term == current.term && next.sequence == current.sequence {
            throw ClusterControlPlaneLeaseError.samePositionConflict
        }
        guard next.issuedAtMilliseconds >= current.issuedAtMilliseconds else {
            throw ClusterControlPlaneLeaseError.timestampRegression
        }

        if current.isExpired(atMilliseconds: nowMilliseconds) {
            return try replaceExpired(
                current: current,
                next: next
            )
        }
        return try renewActive(
            current: current,
            next: next,
            authority: authority
        )
    }

    private func validate(
        next: ClusterControlPlaneLeaseRecord,
        against authority: ClusterControlPlaneLeaseAuthority
    ) throws {
        guard next.clusterID == authority.clusterID else {
            throw ClusterControlPlaneLeaseError.clusterMismatch
        }
        guard next.membershipEpoch == authority.membershipEpoch else {
            throw ClusterControlPlaneLeaseError.membershipEpochMismatch(
                expected: authority.membershipEpoch,
                actual: next.membershipEpoch
            )
        }
        guard next.fencingToken == authority.fencingToken else {
            throw ClusterControlPlaneLeaseError.fencingTokenMismatch(
                expected: authority.fencingToken,
                actual: next.fencingToken
            )
        }
        guard next.leaderNodeID == authority.nodeID else {
            throw ClusterControlPlaneLeaseError.leaderNodeMismatch(
                expected: authority.nodeID,
                actual: next.leaderNodeID
            )
        }
    }

    private func replay(
        current: ClusterControlPlaneLeaseRecord,
        expectation: ClusterControlPlaneLeaseExpectation
    ) throws -> ClusterControlPlaneLeaseDisposition {
        guard let predecessorRecordSHA256 = current.predecessorRecordSHA256 else {
            throw ClusterControlPlaneLeaseError.forgedReplay
        }

        let predecessorTerm: UInt64
        if current.sequence > 1 {
            predecessorTerm = current.term
        } else {
            guard current.term > 1 else {
                throw ClusterControlPlaneLeaseError.forgedReplay
            }
            predecessorTerm = current.term - 1
        }
        guard case .record(let expectedTerm, let expectedRecordSHA256) = expectation,
              expectedTerm == predecessorTerm,
              expectedRecordSHA256 == predecessorRecordSHA256 else {
            throw ClusterControlPlaneLeaseError.forgedReplay
        }
        return .exactReplay(current)
    }

    private func renewActive(
        current: ClusterControlPlaneLeaseRecord,
        next: ClusterControlPlaneLeaseRecord,
        authority: ClusterControlPlaneLeaseAuthority
    ) throws -> ClusterControlPlaneLeaseDisposition {
        guard authority.nodeID == current.leaderNodeID else {
            throw ClusterControlPlaneLeaseError.activeLeaseHeldByOther(
                current.leaderNodeID
            )
        }
        guard next.term == current.term else {
            throw ClusterControlPlaneLeaseError.termGap(
                expected: current.term,
                actual: next.term
            )
        }
        guard current.sequence < UInt64.max else {
            throw ClusterControlPlaneLeaseError.counterOverflow
        }
        let expectedSequence = current.sequence + 1
        guard next.sequence == expectedSequence else {
            throw ClusterControlPlaneLeaseError.sequenceGap(
                expected: expectedSequence,
                actual: next.sequence
            )
        }
        guard next.fencingToken == current.fencingToken else {
            throw ClusterControlPlaneLeaseError.fencingTokenMismatch(
                expected: current.fencingToken,
                actual: next.fencingToken
            )
        }
        guard next.expiresAtMilliseconds > current.expiresAtMilliseconds else {
            throw ClusterControlPlaneLeaseError.expiryDidNotAdvance
        }
        return .renew(next)
    }

    private func replaceExpired(
        current: ClusterControlPlaneLeaseRecord,
        next: ClusterControlPlaneLeaseRecord
    ) throws -> ClusterControlPlaneLeaseDisposition {
        guard current.term < UInt64.max else {
            throw ClusterControlPlaneLeaseError.counterOverflow
        }
        let expectedTerm = current.term + 1
        guard next.term == expectedTerm else {
            throw ClusterControlPlaneLeaseError.termGap(
                expected: expectedTerm,
                actual: next.term
            )
        }
        guard next.sequence == 1 else {
            throw ClusterControlPlaneLeaseError.sequenceGap(
                expected: 1,
                actual: next.sequence
            )
        }
        guard next.fencingToken > current.fencingToken else {
            throw ClusterControlPlaneLeaseError.fencingTokenDidNotAdvance
        }
        return .replaceExpired(next)
    }
}

/// The strict JSON boundary for lease records and proposals. Callers decoding untrusted bytes
/// must use these entry points rather than a bare `JSONDecoder`.
public enum ClusterControlPlaneLeaseWireContract {
    public static let recordAllowedKeys: Set<String> = [
        "schemaVersion", "clusterID", "leaderNodeID", "membershipEpoch",
        "fencingToken", "term", "sequence", "issuedAtMilliseconds",
        "expiresAtMilliseconds", "predecessorRecordSHA256",
    ]
    public static let proposalAllowedKeys: Set<String> = recordAllowedKeys.union([
        "expectedTerm", "expectedRecordSHA256",
    ])

    public static func encode(_ record: ClusterControlPlaneLeaseRecord) throws -> Data {
        try bounded(encoder().encode(record))
    }

    public static func encode(_ proposal: ClusterControlPlaneLeaseProposal) throws -> Data {
        try bounded(encoder().encode(proposal))
    }

    public static func decodeRecord(_ data: Data) throws -> ClusterControlPlaneLeaseRecord {
        let boundedData = try bounded(data)
        return try Phase09StrictDecoder.decode(
            ClusterControlPlaneLeaseRecord.self,
            from: boundedData,
            allowedKeys: recordAllowedKeys,
            requiredKeys: recordAllowedKeys
        )
    }

    public static func decodeProposal(
        _ data: Data
    ) throws -> ClusterControlPlaneLeaseProposal {
        let boundedData = try bounded(data)
        return try Phase09StrictDecoder.decode(
            ClusterControlPlaneLeaseProposal.self,
            from: boundedData,
            allowedKeys: proposalAllowedKeys,
            requiredKeys: proposalAllowedKeys
        )
    }

    private static func bounded(_ data: Data) throws -> Data {
        guard !data.isEmpty,
              data.count <= ClusterControlPlaneLeaseContract.maximumWireBytes else {
            throw ClusterControlPlaneLeaseError.wirePayloadOutOfBounds(
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

private enum ClusterControlPlaneLeaseValidation {
    static func isSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
