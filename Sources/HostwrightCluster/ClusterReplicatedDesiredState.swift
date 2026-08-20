import CryptoKit
import Foundation
import HostwrightControlPlane

public enum ClusterReplicatedDesiredStateError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidProjectID(String)
    case invalidDigest(String)
    case invalidRevision
    case invalidGeneration
    case invalidPredecessor
    case invalidFencingToken
    case invalidOperationID
    case invalidTimestamp
    case invalidExpectation
    case staleCAS
    case clusterMismatch
    case projectMismatch
    case membershipEpochMismatch(
        expected: ClusterMembershipEpoch,
        actual: ClusterMembershipEpoch
    )
    case membershipEpochRegression
    case fencingTokenMismatch(expected: UInt64, actual: UInt64)
    case staleFencingToken
    case authorNodeMismatch
    case revisionGap(expected: UInt64, actual: UInt64)
    case generationGap(expected: UInt64, actual: UInt64)
    case counterOverflow
    case sameRevisionConflict
    case staleSnapshot
    case timestampRegression
    case operationReplayConflict
}

public enum ClusterReplicatedDesiredStateContract {
    public static let schemaVersion = 1
    public static let maximumProjectNameBytes = 128
    public static let maximumOperationIDBytes = 128
}

public struct ClusterReplicatedProjectID: Codable, Hashable, Comparable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard ClusterReplicatedDesiredStateValidation.isProjectID(rawValue) else {
            throw ClusterReplicatedDesiredStateError.invalidProjectID(rawValue)
        }
        self.rawValue = rawValue
    }

    public init(rawValue: String) throws {
        try self.init(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ClusterReplicatedDesiredState: Codable, Equatable, Hashable, Comparable, Sendable {
    public let clusterID: ClusterID
    public let projectID: ClusterReplicatedProjectID
    public let revision: UInt64
    public let desiredGeneration: UInt64
    public let predecessorRecordSHA256: String?
    public let contentSHA256: String
    public let manifestSHA256: String
    public let membershipEpoch: ClusterMembershipEpoch
    public let fencingToken: UInt64
    public let authorNodeID: ClusterNodeID
    public let operationID: String
    public let publishedAtMilliseconds: UInt64

    public var schemaVersion: Int {
        ClusterReplicatedDesiredStateContract.schemaVersion
    }

    public init(
        clusterID: ClusterID,
        projectID: ClusterReplicatedProjectID,
        revision: UInt64,
        desiredGeneration: UInt64,
        predecessorRecordSHA256: String?,
        contentSHA256: String,
        manifestSHA256: String,
        membershipEpoch: ClusterMembershipEpoch,
        fencingToken: UInt64,
        authorNodeID: ClusterNodeID,
        operationID: String,
        publishedAtMilliseconds: UInt64
    ) throws {
        guard revision > 0 else {
            throw ClusterReplicatedDesiredStateError.invalidRevision
        }
        guard desiredGeneration > 0 else {
            throw ClusterReplicatedDesiredStateError.invalidGeneration
        }
        if revision == 1 {
            guard predecessorRecordSHA256 == nil else {
                throw ClusterReplicatedDesiredStateError.invalidPredecessor
            }
        } else {
            guard let digest = predecessorRecordSHA256 else {
                throw ClusterReplicatedDesiredStateError.invalidPredecessor
            }
            guard ClusterReplicatedDesiredStateValidation.isSHA256(digest) else {
                throw ClusterReplicatedDesiredStateError.invalidDigest(
                    "predecessorRecordSHA256"
                )
            }
        }
        guard ClusterReplicatedDesiredStateValidation.isSHA256(contentSHA256) else {
            throw ClusterReplicatedDesiredStateError.invalidDigest("contentSHA256")
        }
        guard ClusterReplicatedDesiredStateValidation.isSHA256(manifestSHA256) else {
            throw ClusterReplicatedDesiredStateError.invalidDigest("manifestSHA256")
        }
        guard fencingToken > 0 else {
            throw ClusterReplicatedDesiredStateError.invalidFencingToken
        }
        guard ClusterReplicatedDesiredStateValidation.isOperationID(operationID) else {
            throw ClusterReplicatedDesiredStateError.invalidOperationID
        }
        guard publishedAtMilliseconds > 0 else {
            throw ClusterReplicatedDesiredStateError.invalidTimestamp
        }
        self.clusterID = clusterID
        self.projectID = projectID
        self.revision = revision
        self.desiredGeneration = desiredGeneration
        self.predecessorRecordSHA256 = predecessorRecordSHA256
        self.contentSHA256 = contentSHA256
        self.manifestSHA256 = manifestSHA256
        self.membershipEpoch = membershipEpoch
        self.fencingToken = fencingToken
        self.authorNodeID = authorNodeID
        self.operationID = operationID
        self.publishedAtMilliseconds = publishedAtMilliseconds
    }

    public func canonicalJSON() throws -> Data {
        try ClusterReplicatedDesiredStateWireContract.encode(self)
    }

    public func canonicalSHA256() throws -> String {
        ClusterReplicatedDesiredStateValidation.sha256(try canonicalJSON())
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.clusterID != rhs.clusterID { return lhs.clusterID < rhs.clusterID }
        if lhs.projectID != rhs.projectID { return lhs.projectID < rhs.projectID }
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
        if lhs.desiredGeneration != rhs.desiredGeneration {
            return lhs.desiredGeneration < rhs.desiredGeneration
        }
        if lhs.predecessorRecordSHA256 != rhs.predecessorRecordSHA256 {
            return (lhs.predecessorRecordSHA256 ?? "")
                < (rhs.predecessorRecordSHA256 ?? "")
        }
        if lhs.contentSHA256 != rhs.contentSHA256 {
            return lhs.contentSHA256 < rhs.contentSHA256
        }
        if lhs.manifestSHA256 != rhs.manifestSHA256 {
            return lhs.manifestSHA256 < rhs.manifestSHA256
        }
        if lhs.membershipEpoch != rhs.membershipEpoch {
            return lhs.membershipEpoch < rhs.membershipEpoch
        }
        if lhs.fencingToken != rhs.fencingToken {
            return lhs.fencingToken < rhs.fencingToken
        }
        if lhs.authorNodeID != rhs.authorNodeID {
            return lhs.authorNodeID < rhs.authorNodeID
        }
        if lhs.operationID != rhs.operationID { return lhs.operationID < rhs.operationID }
        return lhs.publishedAtMilliseconds < rhs.publishedAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case clusterID
        case projectID
        case revision
        case desiredGeneration
        case predecessorRecordSHA256
        case contentSHA256
        case manifestSHA256
        case membershipEpoch
        case fencingToken
        case authorNodeID
        case operationID
        case publishedAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == ClusterReplicatedDesiredStateContract.schemaVersion else {
            throw ClusterReplicatedDesiredStateError.unsupportedSchemaVersion(schemaVersion)
        }
        guard container.contains(.predecessorRecordSHA256) else {
            throw ClusterReplicatedDesiredStateError.invalidPredecessor
        }
        try self.init(
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            projectID: container.decode(ClusterReplicatedProjectID.self, forKey: .projectID),
            revision: container.decode(UInt64.self, forKey: .revision),
            desiredGeneration: container.decode(UInt64.self, forKey: .desiredGeneration),
            predecessorRecordSHA256: container.decodeIfPresent(
                String.self,
                forKey: .predecessorRecordSHA256
            ),
            contentSHA256: container.decode(String.self, forKey: .contentSHA256),
            manifestSHA256: container.decode(String.self, forKey: .manifestSHA256),
            membershipEpoch: container.decode(
                ClusterMembershipEpoch.self,
                forKey: .membershipEpoch
            ),
            fencingToken: container.decode(UInt64.self, forKey: .fencingToken),
            authorNodeID: container.decode(ClusterNodeID.self, forKey: .authorNodeID),
            operationID: container.decode(String.self, forKey: .operationID),
            publishedAtMilliseconds: container.decode(
                UInt64.self,
                forKey: .publishedAtMilliseconds
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(clusterID, forKey: .clusterID)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(revision, forKey: .revision)
        try container.encode(desiredGeneration, forKey: .desiredGeneration)
        if let predecessorRecordSHA256 {
            try container.encode(
                predecessorRecordSHA256,
                forKey: .predecessorRecordSHA256
            )
        } else {
            try container.encodeNil(forKey: .predecessorRecordSHA256)
        }
        try container.encode(contentSHA256, forKey: .contentSHA256)
        try container.encode(manifestSHA256, forKey: .manifestSHA256)
        try container.encode(membershipEpoch, forKey: .membershipEpoch)
        try container.encode(fencingToken, forKey: .fencingToken)
        try container.encode(authorNodeID, forKey: .authorNodeID)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(publishedAtMilliseconds, forKey: .publishedAtMilliseconds)
    }
}

public enum ClusterReplicatedDesiredStateExpectation: Equatable, Hashable, Sendable {
    case absent
    case record(revision: UInt64, recordSHA256: String)
}

public struct ClusterReplicatedDesiredStateProposal: Codable, Equatable, Hashable, Sendable {
    public let expectation: ClusterReplicatedDesiredStateExpectation
    public let next: ClusterReplicatedDesiredState

    public init(
        expectation: ClusterReplicatedDesiredStateExpectation,
        next: ClusterReplicatedDesiredState
    ) throws {
        if case .record(let revision, let recordSHA256) = expectation {
            guard revision > 0,
                  ClusterReplicatedDesiredStateValidation.isSHA256(recordSHA256) else {
                throw ClusterReplicatedDesiredStateError.invalidExpectation
            }
        }
        self.expectation = expectation
        self.next = next
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case expectedRevision
        case expectedRecordSHA256
        case clusterID
        case projectID
        case revision
        case desiredGeneration
        case predecessorRecordSHA256
        case contentSHA256
        case manifestSHA256
        case membershipEpoch
        case fencingToken
        case authorNodeID
        case operationID
        case publishedAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == ClusterReplicatedDesiredStateContract.schemaVersion else {
            throw ClusterReplicatedDesiredStateError.unsupportedSchemaVersion(schemaVersion)
        }
        guard container.contains(.expectedRevision),
              container.contains(.expectedRecordSHA256),
              container.contains(.predecessorRecordSHA256) else {
            throw ClusterReplicatedDesiredStateError.invalidExpectation
        }
        let expectedRevision = try container.decodeIfPresent(
            UInt64.self,
            forKey: .expectedRevision
        )
        let expectedRecordSHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .expectedRecordSHA256
        )
        let expectation: ClusterReplicatedDesiredStateExpectation
        switch (expectedRevision, expectedRecordSHA256) {
        case (nil, nil):
            expectation = .absent
        case (.some(let revision), .some(let digest)):
            expectation = .record(revision: revision, recordSHA256: digest)
        default:
            throw ClusterReplicatedDesiredStateError.invalidExpectation
        }
        let next = try ClusterReplicatedDesiredState(
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            projectID: container.decode(ClusterReplicatedProjectID.self, forKey: .projectID),
            revision: container.decode(UInt64.self, forKey: .revision),
            desiredGeneration: container.decode(UInt64.self, forKey: .desiredGeneration),
            predecessorRecordSHA256: container.decodeIfPresent(
                String.self,
                forKey: .predecessorRecordSHA256
            ),
            contentSHA256: container.decode(String.self, forKey: .contentSHA256),
            manifestSHA256: container.decode(String.self, forKey: .manifestSHA256),
            membershipEpoch: container.decode(
                ClusterMembershipEpoch.self,
                forKey: .membershipEpoch
            ),
            fencingToken: container.decode(UInt64.self, forKey: .fencingToken),
            authorNodeID: container.decode(ClusterNodeID.self, forKey: .authorNodeID),
            operationID: container.decode(String.self, forKey: .operationID),
            publishedAtMilliseconds: container.decode(
                UInt64.self,
                forKey: .publishedAtMilliseconds
            )
        )
        try self.init(expectation: expectation, next: next)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(next.schemaVersion, forKey: .schemaVersion)
        switch expectation {
        case .absent:
            try container.encodeNil(forKey: .expectedRevision)
            try container.encodeNil(forKey: .expectedRecordSHA256)
        case .record(let revision, let recordSHA256):
            try container.encode(revision, forKey: .expectedRevision)
            try container.encode(recordSHA256, forKey: .expectedRecordSHA256)
        }
        try container.encode(next.clusterID, forKey: .clusterID)
        try container.encode(next.projectID, forKey: .projectID)
        try container.encode(next.revision, forKey: .revision)
        try container.encode(next.desiredGeneration, forKey: .desiredGeneration)
        if let predecessorRecordSHA256 = next.predecessorRecordSHA256 {
            try container.encode(
                predecessorRecordSHA256,
                forKey: .predecessorRecordSHA256
            )
        } else {
            try container.encodeNil(forKey: .predecessorRecordSHA256)
        }
        try container.encode(next.contentSHA256, forKey: .contentSHA256)
        try container.encode(next.manifestSHA256, forKey: .manifestSHA256)
        try container.encode(next.membershipEpoch, forKey: .membershipEpoch)
        try container.encode(next.fencingToken, forKey: .fencingToken)
        try container.encode(next.authorNodeID, forKey: .authorNodeID)
        try container.encode(next.operationID, forKey: .operationID)
        try container.encode(
            next.publishedAtMilliseconds,
            forKey: .publishedAtMilliseconds
        )
    }
}

public struct ClusterReplicatedDesiredStateAuthority: Equatable, Hashable, Sendable {
    public let clusterID: ClusterID
    public let membershipEpoch: ClusterMembershipEpoch
    public let fencingToken: UInt64
    public let authorNodeID: ClusterNodeID

    public init(
        clusterID: ClusterID,
        membershipEpoch: ClusterMembershipEpoch,
        fencingToken: UInt64,
        authorNodeID: ClusterNodeID
    ) throws {
        guard fencingToken > 0 else {
            throw ClusterReplicatedDesiredStateError.invalidFencingToken
        }
        self.clusterID = clusterID
        self.membershipEpoch = membershipEpoch
        self.fencingToken = fencingToken
        self.authorNodeID = authorNodeID
    }
}

public enum ClusterReplicatedDesiredStatePublication: Equatable, Sendable {
    case created(ClusterReplicatedDesiredState)
    case updated(ClusterReplicatedDesiredState)
    case replayed(ClusterReplicatedDesiredState)
}

/// This evaluates one immutable CAS proposal. It does not persist, replicate, or reach quorum.
public struct ClusterReplicatedDesiredStatePublisher: Sendable {
    public init() {}

    public func decide(
        current: ClusterReplicatedDesiredState?,
        proposal: ClusterReplicatedDesiredStateProposal,
        authority: ClusterReplicatedDesiredStateAuthority
    ) throws -> ClusterReplicatedDesiredStatePublication {
        let next = proposal.next
        try validate(next: next, against: authority)

        if let current, current == next {
            switch proposal.expectation {
            case .absent where current.revision == 1 && current.desiredGeneration == 1:
                return .replayed(current)
            case .record(let revision, let recordSHA256)
                where current.revision > 1
                    && revision == current.revision - 1
                    && recordSHA256 == current.predecessorRecordSHA256:
                return .replayed(current)
            default:
                throw ClusterReplicatedDesiredStateError.staleCAS
            }
        }

        guard let current else {
            guard proposal.expectation == .absent else {
                throw ClusterReplicatedDesiredStateError.staleCAS
            }
            guard next.revision == 1 else {
                throw ClusterReplicatedDesiredStateError.revisionGap(
                    expected: 1,
                    actual: next.revision
                )
            }
            guard next.desiredGeneration == 1 else {
                throw ClusterReplicatedDesiredStateError.generationGap(
                    expected: 1,
                    actual: next.desiredGeneration
                )
            }
            return .created(next)
        }

        guard current.clusterID == authority.clusterID,
              current.clusterID == next.clusterID else {
            throw ClusterReplicatedDesiredStateError.clusterMismatch
        }
        guard current.projectID == next.projectID else {
            throw ClusterReplicatedDesiredStateError.projectMismatch
        }
        guard authority.membershipEpoch >= current.membershipEpoch else {
            throw ClusterReplicatedDesiredStateError.membershipEpochRegression
        }
        guard authority.fencingToken >= current.fencingToken else {
            throw ClusterReplicatedDesiredStateError.staleFencingToken
        }

        let currentRecordSHA256 = try current.canonicalSHA256()
        guard case .record(let revision, let recordSHA256) = proposal.expectation,
              revision == current.revision,
              recordSHA256 == currentRecordSHA256 else {
            throw ClusterReplicatedDesiredStateError.staleCAS
        }
        guard current.revision < UInt64.max,
              current.desiredGeneration < UInt64.max else {
            throw ClusterReplicatedDesiredStateError.counterOverflow
        }
        if next.revision < current.revision {
            throw ClusterReplicatedDesiredStateError.staleSnapshot
        }
        if next.revision == current.revision {
            throw ClusterReplicatedDesiredStateError.sameRevisionConflict
        }
        let expectedRevision = current.revision + 1
        guard next.revision == expectedRevision else {
            throw ClusterReplicatedDesiredStateError.revisionGap(
                expected: expectedRevision,
                actual: next.revision
            )
        }
        let expectedGeneration = current.desiredGeneration + 1
        guard next.desiredGeneration == expectedGeneration else {
            throw ClusterReplicatedDesiredStateError.generationGap(
                expected: expectedGeneration,
                actual: next.desiredGeneration
            )
        }
        guard next.predecessorRecordSHA256 == currentRecordSHA256 else {
            throw ClusterReplicatedDesiredStateError.staleCAS
        }
        guard next.publishedAtMilliseconds >= current.publishedAtMilliseconds else {
            throw ClusterReplicatedDesiredStateError.timestampRegression
        }
        guard next.operationID != current.operationID else {
            throw ClusterReplicatedDesiredStateError.operationReplayConflict
        }
        return .updated(next)
    }

    private func validate(
        next: ClusterReplicatedDesiredState,
        against authority: ClusterReplicatedDesiredStateAuthority
    ) throws {
        guard next.clusterID == authority.clusterID else {
            throw ClusterReplicatedDesiredStateError.clusterMismatch
        }
        guard next.membershipEpoch == authority.membershipEpoch else {
            throw ClusterReplicatedDesiredStateError.membershipEpochMismatch(
                expected: authority.membershipEpoch,
                actual: next.membershipEpoch
            )
        }
        guard next.fencingToken == authority.fencingToken else {
            throw ClusterReplicatedDesiredStateError.fencingTokenMismatch(
                expected: authority.fencingToken,
                actual: next.fencingToken
            )
        }
        guard next.authorNodeID == authority.authorNodeID else {
            throw ClusterReplicatedDesiredStateError.authorNodeMismatch
        }
    }
}

public enum ClusterReplicatedDesiredStateReplicaDisposition: Equatable, Sendable {
    case applied(ClusterReplicatedDesiredState)
    case replayed(ClusterReplicatedDesiredState)
}

/// This checks one already-authorized adjacent snapshot. It owns no storage or transport.
public struct ClusterReplicatedDesiredStateReplica: Sendable {
    public init() {}

    public func apply(
        _ incoming: ClusterReplicatedDesiredState,
        to current: ClusterReplicatedDesiredState?
    ) throws -> ClusterReplicatedDesiredStateReplicaDisposition {
        guard let current else {
            guard incoming.revision == 1 else {
                throw ClusterReplicatedDesiredStateError.revisionGap(
                    expected: 1,
                    actual: incoming.revision
                )
            }
            guard incoming.desiredGeneration == 1 else {
                throw ClusterReplicatedDesiredStateError.generationGap(
                    expected: 1,
                    actual: incoming.desiredGeneration
                )
            }
            return .applied(incoming)
        }

        if incoming == current {
            return .replayed(current)
        }
        guard incoming.clusterID == current.clusterID else {
            throw ClusterReplicatedDesiredStateError.clusterMismatch
        }
        guard incoming.projectID == current.projectID else {
            throw ClusterReplicatedDesiredStateError.projectMismatch
        }
        if incoming.revision < current.revision {
            throw ClusterReplicatedDesiredStateError.staleSnapshot
        }
        if incoming.revision == current.revision {
            throw ClusterReplicatedDesiredStateError.sameRevisionConflict
        }
        guard current.revision < UInt64.max,
              current.desiredGeneration < UInt64.max else {
            throw ClusterReplicatedDesiredStateError.counterOverflow
        }
        let expectedRevision = current.revision + 1
        guard incoming.revision == expectedRevision else {
            throw ClusterReplicatedDesiredStateError.revisionGap(
                expected: expectedRevision,
                actual: incoming.revision
            )
        }
        let expectedGeneration = current.desiredGeneration + 1
        guard incoming.desiredGeneration == expectedGeneration else {
            throw ClusterReplicatedDesiredStateError.generationGap(
                expected: expectedGeneration,
                actual: incoming.desiredGeneration
            )
        }
        let currentRecordSHA256 = try current.canonicalSHA256()
        guard incoming.predecessorRecordSHA256 == currentRecordSHA256 else {
            throw ClusterReplicatedDesiredStateError.staleCAS
        }
        guard incoming.membershipEpoch >= current.membershipEpoch else {
            throw ClusterReplicatedDesiredStateError.membershipEpochRegression
        }
        guard incoming.fencingToken >= current.fencingToken else {
            throw ClusterReplicatedDesiredStateError.staleFencingToken
        }
        guard incoming.publishedAtMilliseconds >= current.publishedAtMilliseconds else {
            throw ClusterReplicatedDesiredStateError.timestampRegression
        }
        guard incoming.operationID != current.operationID else {
            throw ClusterReplicatedDesiredStateError.operationReplayConflict
        }
        return .applied(incoming)
    }
}

public enum ClusterReplicatedDesiredStateWireContract {
    public static let stateAllowedKeys: Set<String> = [
        "schemaVersion", "clusterID", "projectID", "revision", "desiredGeneration",
        "predecessorRecordSHA256", "contentSHA256", "manifestSHA256",
        "membershipEpoch", "fencingToken",
        "authorNodeID", "operationID", "publishedAtMilliseconds",
    ]
    public static let proposalAllowedKeys: Set<String> = stateAllowedKeys.union([
        "expectedRevision", "expectedRecordSHA256",
    ])

    public static func encode(_ state: ClusterReplicatedDesiredState) throws -> Data {
        try encoder().encode(state)
    }

    public static func encode(_ proposal: ClusterReplicatedDesiredStateProposal) throws -> Data {
        try encoder().encode(proposal)
    }

    public static func decodeState(_ data: Data) throws -> ClusterReplicatedDesiredState {
        try Phase09StrictDecoder.decode(
            ClusterReplicatedDesiredState.self,
            from: data,
            allowedKeys: stateAllowedKeys,
            requiredKeys: stateAllowedKeys
        )
    }

    public static func decodeProposal(
        _ data: Data
    ) throws -> ClusterReplicatedDesiredStateProposal {
        try Phase09StrictDecoder.decode(
            ClusterReplicatedDesiredStateProposal.self,
            from: data,
            allowedKeys: proposalAllowedKeys,
            requiredKeys: proposalAllowedKeys
        )
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private enum ClusterReplicatedDesiredStateValidation {
    static func isProjectID(_ value: String) -> Bool {
        let prefix = "project-"
        guard value.hasPrefix(prefix) else { return false }
        let name = Array(value.dropFirst(prefix.utf8.count).utf8)
        guard (1...ClusterReplicatedDesiredStateContract.maximumProjectNameBytes)
            .contains(name.count),
              let first = name.first,
              let last = name.last,
              isAlphaNumeric(first),
              isAlphaNumeric(last) else {
            return false
        }
        return name.allSatisfy { byte in
            isAlphaNumeric(byte) || byte == 45 || byte == 46 || byte == 95
        }
    }

    static func isOperationID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...ClusterReplicatedDesiredStateContract.maximumOperationIDBytes)
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
