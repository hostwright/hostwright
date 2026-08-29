import CryptoKit
import Foundation

public enum ClusterMembershipError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidClusterID(String)
    case invalidNodeID(String)
    case epochOverflow
    case invalidToken(String)
    case staleJoinToken
    case duplicateJoinToken
    case duplicateNodeIdentity(ClusterNodeID)
    case duplicateEndpoint(String)
    case invalidTopology(String)
    case quorumLoss
    case staleEpoch(expected: ClusterMembershipEpoch, actual: ClusterMembershipEpoch)
    case replayConflict
    case invalidTransition(String)
    case cancelled

    public var description: String {
        switch self {
        case .invalidClusterID: "Cluster ID is not a lowercase canonical UUID."
        case .invalidNodeID: "Cluster node ID is not a lowercase canonical UUID."
        case .epochOverflow: "Cluster membership epoch cannot advance past UInt64.max."
        case .invalidToken: "Cluster join token is invalid."
        case .staleJoinToken: "Cluster join token is stale or not yet valid."
        case .duplicateJoinToken: "Cluster join token has already been consumed."
        case .duplicateNodeIdentity: "Cluster membership contains a duplicate node identity."
        case .duplicateEndpoint: "Cluster membership contains a duplicate endpoint."
        case .invalidTopology: "Cluster membership topology is invalid."
        case .quorumLoss: "The membership change would lose the current quorum."
        case .staleEpoch: "Cluster membership epoch is stale."
        case .replayConflict: "Cluster membership replay conflicts with the stored intent."
        case .invalidTransition: "Cluster membership transition is invalid."
        case .cancelled: "Cluster membership planning was cancelled."
        }
    }
}

public struct ClusterID: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard let uuid = UUID(uuidString: rawValue),
              uuid.uuidString.lowercased() == rawValue else {
            throw ClusterMembershipError.invalidClusterID(rawValue)
        }
        self.rawValue = rawValue
    }

    public init(rawValue: String) throws {
        try self.init(rawValue)
    }

    public init(uuid: UUID) {
        self.rawValue = uuid.uuidString.lowercased()
    }

    public static func generate() -> Self {
        Self(uuid: UUID())
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

public struct ClusterNodeID: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard let uuid = UUID(uuidString: rawValue),
              uuid.uuidString.lowercased() == rawValue else {
            throw ClusterMembershipError.invalidNodeID(rawValue)
        }
        self.rawValue = rawValue
    }

    public init(rawValue: String) throws {
        try self.init(rawValue)
    }

    public init(uuid: UUID) {
        self.rawValue = uuid.uuidString.lowercased()
    }

    public static func generate() -> Self {
        Self(uuid: UUID())
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

public struct ClusterMembershipEpoch: Codable, Hashable, Comparable, Sendable {
    public let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }

    public static let initial = Self(0)

    public func advanced() throws -> Self {
        guard value < UInt64.max else {
            throw ClusterMembershipError.epochOverflow
        }
        return Self(value + 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}

public enum ClusterMemberRole: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case learner
    case voter
}

public struct ClusterMembershipMember: Codable, Equatable, Hashable, Sendable {
    public let nodeID: ClusterNodeID
    public let role: ClusterMemberRole
    public let peerEndpoint: String
    public let clientEndpoint: String

    public init(
        nodeID: ClusterNodeID,
        role: ClusterMemberRole,
        peerEndpoint: String,
        clientEndpoint: String? = nil
    ) throws {
        self.nodeID = nodeID
        self.role = role
        self.peerEndpoint = try ClusterMembershipValidation.endpoint(peerEndpoint)
        self.clientEndpoint = try ClusterMembershipValidation.endpoint(clientEndpoint ?? peerEndpoint)
    }

    public init(
        nodeID: ClusterNodeID,
        role: ClusterMemberRole,
        endpoint: String
    ) throws {
        try self.init(
            nodeID: nodeID,
            role: role,
            peerEndpoint: endpoint,
            clientEndpoint: endpoint
        )
    }

    public var endpoint: String { peerEndpoint }

    public func validate() throws {
        _ = try ClusterMembershipValidation.endpoint(peerEndpoint)
        _ = try ClusterMembershipValidation.endpoint(clientEndpoint)
    }

    private enum CodingKeys: String, CodingKey {
        case nodeID
        case role
        case peerEndpoint
        case clientEndpoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nodeID: container.decode(ClusterNodeID.self, forKey: .nodeID),
            role: container.decode(ClusterMemberRole.self, forKey: .role),
            peerEndpoint: container.decode(String.self, forKey: .peerEndpoint),
            clientEndpoint: container.decode(String.self, forKey: .clientEndpoint)
        )
    }
}

public struct ClusterMembershipPolicy: Codable, Equatable, Sendable {
    public let maximumVoters: Int
    public let maximumMembers: Int

    public init(maximumVoters: Int = 5, maximumMembers: Int = 9) throws {
        guard (1...99).contains(maximumVoters),
              maximumMembers >= maximumVoters,
              maximumMembers <= 199 else {
            throw ClusterMembershipError.invalidTopology("membership policy bounds are invalid")
        }
        self.maximumVoters = maximumVoters
        self.maximumMembers = maximumMembers
    }

    public func validate() throws {
        guard (1...99).contains(maximumVoters),
              maximumMembers >= maximumVoters,
              maximumMembers <= 199 else {
            throw ClusterMembershipError.invalidTopology("membership policy bounds are invalid")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case maximumVoters
        case maximumMembers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumVoters: container.decode(Int.self, forKey: .maximumVoters),
            maximumMembers: container.decode(Int.self, forKey: .maximumMembers)
        )
    }

    public static let `default`: Self = {
        // These are the supported 1/3/5 voter topologies for this contract.
        try! Self(maximumVoters: 5, maximumMembers: 9)
    }()
}

public struct ClusterJoinToken: Codable, Equatable, Hashable, Sendable {
    public let tokenID: String
    public let clusterID: ClusterID
    public let nodeID: ClusterNodeID
    public let issuedEpoch: ClusterMembershipEpoch
    public let expiresAtEpoch: ClusterMembershipEpoch?
    public let secretSHA256: String

    public init(
        tokenID: String,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        issuedEpoch: ClusterMembershipEpoch,
        expiresAtEpoch: ClusterMembershipEpoch? = nil,
        secretSHA256: String
    ) throws {
        guard ClusterMembershipValidation.safeOpaqueID(tokenID) else {
            throw ClusterMembershipError.invalidToken("token ID")
        }
        guard secretSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw ClusterMembershipError.invalidToken("token proof digest")
        }
        if let expiresAtEpoch, expiresAtEpoch < issuedEpoch {
            throw ClusterMembershipError.invalidToken("token expiry precedes issuance")
        }
        self.tokenID = tokenID
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.issuedEpoch = issuedEpoch
        self.expiresAtEpoch = expiresAtEpoch
        self.secretSHA256 = secretSHA256
    }

    public init(
        tokenID: String,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        issuedEpoch: ClusterMembershipEpoch,
        expiresAtEpoch: ClusterMembershipEpoch? = nil,
        secret: String
    ) throws {
        try self.init(
            tokenID: tokenID,
            clusterID: clusterID,
            nodeID: nodeID,
            issuedEpoch: issuedEpoch,
            expiresAtEpoch: expiresAtEpoch,
            secretSHA256: ClusterMembershipValidation.sha256(secret)
        )
    }

    public func isExpired(at epoch: ClusterMembershipEpoch) -> Bool {
        if let expiresAtEpoch {
            return epoch > expiresAtEpoch
        }
        return false
    }

    public func validate() throws {
        guard ClusterMembershipValidation.safeOpaqueID(tokenID) else {
            throw ClusterMembershipError.invalidToken("token ID")
        }
        guard secretSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw ClusterMembershipError.invalidToken("token proof digest")
        }
        if let expiresAtEpoch, expiresAtEpoch < issuedEpoch {
            throw ClusterMembershipError.invalidToken("token expiry precedes issuance")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tokenID
        case clusterID
        case nodeID
        case issuedEpoch
        case expiresAtEpoch
        case secretSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            tokenID: container.decode(String.self, forKey: .tokenID),
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            nodeID: container.decode(ClusterNodeID.self, forKey: .nodeID),
            issuedEpoch: container.decode(ClusterMembershipEpoch.self, forKey: .issuedEpoch),
            expiresAtEpoch: container.decodeIfPresent(ClusterMembershipEpoch.self, forKey: .expiresAtEpoch),
            secretSHA256: container.decode(String.self, forKey: .secretSHA256)
        )
    }
}

public struct ClusterJoinRequest: Codable, Equatable, Sendable {
    public let nodeID: ClusterNodeID
    public let token: ClusterJoinToken
    public let peerEndpoint: String
    public let clientEndpoint: String

    public init(
        nodeID: ClusterNodeID,
        token: ClusterJoinToken,
        peerEndpoint: String,
        clientEndpoint: String? = nil
    ) throws {
        guard token.nodeID == nodeID else {
            throw ClusterMembershipError.invalidToken("token node identity does not match join request")
        }
        self.nodeID = nodeID
        self.token = token
        self.peerEndpoint = try ClusterMembershipValidation.endpoint(peerEndpoint)
        self.clientEndpoint = try ClusterMembershipValidation.endpoint(clientEndpoint ?? peerEndpoint)
    }

    public func validate() throws {
        guard token.nodeID == nodeID else {
            throw ClusterMembershipError.invalidToken("token node identity does not match join request")
        }
        try token.validate()
        _ = try ClusterMembershipValidation.endpoint(peerEndpoint)
        _ = try ClusterMembershipValidation.endpoint(clientEndpoint)
    }

    private enum CodingKeys: String, CodingKey {
        case nodeID
        case token
        case peerEndpoint
        case clientEndpoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nodeID: container.decode(ClusterNodeID.self, forKey: .nodeID),
            token: container.decode(ClusterJoinToken.self, forKey: .token),
            peerEndpoint: container.decode(String.self, forKey: .peerEndpoint),
            clientEndpoint: container.decode(String.self, forKey: .clientEndpoint)
        )
    }
}

public struct ClusterMembershipIntent: Codable, Equatable, Sendable {
    public let clusterID: ClusterID
    public let epoch: ClusterMembershipEpoch
    public let members: [ClusterMembershipMember]
    public let consumedJoinTokenIDs: [String]
    public let appliedPlanIDs: [String]

    public init(
        clusterID: ClusterID,
        epoch: ClusterMembershipEpoch,
        members: [ClusterMembershipMember],
        consumedJoinTokenIDs: [String] = [],
        appliedPlanIDs: [String] = []
    ) throws {
        self.clusterID = clusterID
        self.epoch = epoch
        self.members = members.sorted { $0.nodeID < $1.nodeID }
        self.consumedJoinTokenIDs = consumedJoinTokenIDs.sorted()
        self.appliedPlanIDs = appliedPlanIDs.sorted()
        try validate()
    }

    public static func empty(clusterID: ClusterID) throws -> Self {
        try Self(clusterID: clusterID, epoch: .initial, members: [])
    }

    public var voters: [ClusterMembershipMember] {
        members.filter { $0.role == .voter }
    }

    public var learners: [ClusterMembershipMember] {
        members.filter { $0.role == .learner }
    }

    public var quorum: Int {
        ClusterMembershipValidation.quorum(forVoterCount: voters.count)
    }

    public func validate(policy: ClusterMembershipPolicy = .default) throws {
        guard members.count <= policy.maximumMembers else {
            throw ClusterMembershipError.invalidTopology("member count exceeds policy")
        }
        if members.isEmpty {
            guard epoch == .initial,
                  consumedJoinTokenIDs.isEmpty,
                  appliedPlanIDs.isEmpty else {
                throw ClusterMembershipError.invalidTopology("only the initial intent may be empty")
            }
            return
        }
        let voterCount = voters.count
        guard voterCount > 0 else {
            throw ClusterMembershipError.invalidTopology("a non-empty cluster requires a voter")
        }
        guard voterCount <= policy.maximumVoters else {
            throw ClusterMembershipError.invalidTopology("voter count exceeds policy")
        }

        var nodeIDs = Set<ClusterNodeID>()
        var endpoints = Set<String>()
        for member in members {
            try member.validate()
            guard nodeIDs.insert(member.nodeID).inserted else {
                throw ClusterMembershipError.duplicateNodeIdentity(member.nodeID)
            }
            for endpoint in Set([member.peerEndpoint, member.clientEndpoint]) {
                guard endpoints.insert(endpoint).inserted else {
                    throw ClusterMembershipError.duplicateEndpoint(endpoint)
                }
            }
        }
        try ClusterMembershipValidation.validateUniqueOpaqueIDs(
            consumedJoinTokenIDs,
            label: "consumed join token"
        )
        try ClusterMembershipValidation.validateUniqueDigests(appliedPlanIDs, label: "applied plan")
        guard members == members.sorted(by: { $0.nodeID < $1.nodeID }) else {
            throw ClusterMembershipError.invalidTopology("members are not in canonical node order")
        }
        guard consumedJoinTokenIDs == consumedJoinTokenIDs.sorted(),
              appliedPlanIDs == appliedPlanIDs.sorted() else {
            throw ClusterMembershipError.invalidTopology("intent collections are not canonical")
        }
    }

    public func canonicalJSON() throws -> Data {
        try ClusterMembershipValidation.canonicalJSON(self)
    }

    public var canonicalSHA256: String {
        (try? ClusterMembershipValidation.sha256(canonicalJSON())) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case clusterID
        case epoch
        case members
        case consumedJoinTokenIDs
        case appliedPlanIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            epoch: container.decode(ClusterMembershipEpoch.self, forKey: .epoch),
            members: container.decode([ClusterMembershipMember].self, forKey: .members),
            consumedJoinTokenIDs: container.decodeIfPresent([String].self, forKey: .consumedJoinTokenIDs) ?? [],
            appliedPlanIDs: container.decodeIfPresent([String].self, forKey: .appliedPlanIDs) ?? []
        )
    }
}

public enum ClusterMembershipOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case bootstrap
    case joinLearner
    case promoteLearner
    case removeVoter
    case replaceVoter
}

public struct ClusterMembershipChange: Codable, Equatable, Sendable {
    public let operation: ClusterMembershipOperation
    public let nodeID: ClusterNodeID
    public let replacementNodeID: ClusterNodeID?
    public let joinTokenID: String?
    public let peerEndpoint: String?
    public let clientEndpoint: String?

    public init(
        operation: ClusterMembershipOperation,
        nodeID: ClusterNodeID,
        replacementNodeID: ClusterNodeID? = nil,
        joinTokenID: String? = nil,
        peerEndpoint: String? = nil,
        clientEndpoint: String? = nil
    ) {
        self.operation = operation
        self.nodeID = nodeID
        self.replacementNodeID = replacementNodeID
        self.joinTokenID = joinTokenID
        self.peerEndpoint = peerEndpoint
        self.clientEndpoint = clientEndpoint
    }

    public func validate() throws {
        switch operation {
        case .bootstrap:
            guard replacementNodeID == nil,
                  joinTokenID == nil,
                  let peerEndpoint,
                  let clientEndpoint else {
                throw ClusterMembershipError.invalidTransition("bootstrap change fields are invalid")
            }
            _ = try ClusterMembershipValidation.endpoint(peerEndpoint)
            _ = try ClusterMembershipValidation.endpoint(clientEndpoint)
        case .joinLearner:
            guard replacementNodeID == nil,
                  let joinTokenID,
                  let peerEndpoint,
                  let clientEndpoint,
                  ClusterMembershipValidation.safeOpaqueID(joinTokenID) else {
                throw ClusterMembershipError.invalidTransition("join change fields are invalid")
            }
            _ = try ClusterMembershipValidation.endpoint(peerEndpoint)
            _ = try ClusterMembershipValidation.endpoint(clientEndpoint)
        case .promoteLearner, .removeVoter:
            guard replacementNodeID == nil,
                  joinTokenID == nil,
                  peerEndpoint == nil,
                  clientEndpoint == nil else {
                throw ClusterMembershipError.invalidTransition("membership change fields are invalid")
            }
        case .replaceVoter:
            guard let replacementNodeID,
                  replacementNodeID != nodeID,
                  let joinTokenID,
                  ClusterMembershipValidation.safeOpaqueID(joinTokenID),
                  let peerEndpoint,
                  let clientEndpoint else {
                throw ClusterMembershipError.invalidTransition("replacement change fields are invalid")
            }
            _ = try ClusterMembershipValidation.endpoint(peerEndpoint)
            _ = try ClusterMembershipValidation.endpoint(clientEndpoint)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case operation
        case nodeID
        case replacementNodeID
        case joinTokenID
        case peerEndpoint
        case clientEndpoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try container.decode(ClusterMembershipOperation.self, forKey: .operation)
        let nodeID = try container.decode(ClusterNodeID.self, forKey: .nodeID)
        let replacementNodeID = try container.decodeIfPresent(ClusterNodeID.self, forKey: .replacementNodeID)
        let joinTokenID = try container.decodeIfPresent(String.self, forKey: .joinTokenID)
        let peerEndpoint = try container.decodeIfPresent(String.self, forKey: .peerEndpoint)
        let clientEndpoint = try container.decodeIfPresent(String.self, forKey: .clientEndpoint)
        self.init(
            operation: operation,
            nodeID: nodeID,
            replacementNodeID: replacementNodeID,
            joinTokenID: joinTokenID,
            peerEndpoint: peerEndpoint,
            clientEndpoint: clientEndpoint
        )
        try validate()
    }
}

public struct ClusterMembershipTransitionRecord: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let operation: ClusterMembershipOperation
    public let planID: String
    public let fromEpoch: ClusterMembershipEpoch
    public let toEpoch: ClusterMembershipEpoch
    public let beforeSHA256: String
    public let afterSHA256: String

    public init(
        sequence: UInt64,
        operation: ClusterMembershipOperation,
        planID: String,
        fromEpoch: ClusterMembershipEpoch,
        toEpoch: ClusterMembershipEpoch,
        beforeSHA256: String,
        afterSHA256: String
    ) throws {
        guard sequence > 0,
              fromEpoch < toEpoch,
              ClusterMembershipValidation.isSHA256(beforeSHA256),
              ClusterMembershipValidation.isSHA256(afterSHA256),
              ClusterMembershipValidation.isSHA256(planID) else {
            throw ClusterMembershipError.invalidTransition("transition record fields are invalid")
        }
        self.sequence = sequence
        self.operation = operation
        self.planID = planID
        self.fromEpoch = fromEpoch
        self.toEpoch = toEpoch
        self.beforeSHA256 = beforeSHA256
        self.afterSHA256 = afterSHA256
    }

    public func validate() throws {
        guard sequence > 0,
              fromEpoch < toEpoch,
              ClusterMembershipValidation.isSHA256(beforeSHA256),
              ClusterMembershipValidation.isSHA256(afterSHA256),
              ClusterMembershipValidation.isSHA256(planID) else {
            throw ClusterMembershipError.invalidTransition("transition record fields are invalid")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case operation
        case planID
        case fromEpoch
        case toEpoch
        case beforeSHA256
        case afterSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sequence: container.decode(UInt64.self, forKey: .sequence),
            operation: container.decode(ClusterMembershipOperation.self, forKey: .operation),
            planID: container.decode(String.self, forKey: .planID),
            fromEpoch: container.decode(ClusterMembershipEpoch.self, forKey: .fromEpoch),
            toEpoch: container.decode(ClusterMembershipEpoch.self, forKey: .toEpoch),
            beforeSHA256: container.decode(String.self, forKey: .beforeSHA256),
            afterSHA256: container.decode(String.self, forKey: .afterSHA256)
        )
    }
}

public struct ClusterMembershipRecoveryRecord: Codable, Equatable, Sendable {
    public let planID: String
    public let clusterID: ClusterID
    public let targetEpoch: ClusterMembershipEpoch
    public let nextStep: UInt64
    public let totalSteps: UInt64
    public let transitionSHA256: String

    public init(
        planID: String,
        clusterID: ClusterID,
        targetEpoch: ClusterMembershipEpoch,
        nextStep: UInt64,
        totalSteps: UInt64,
        transitionSHA256: String
    ) throws {
        guard ClusterMembershipValidation.isSHA256(planID),
              ClusterMembershipValidation.isSHA256(transitionSHA256),
              totalSteps > 0,
              nextStep <= totalSteps else {
            throw ClusterMembershipError.invalidTransition("recovery record fields are invalid")
        }
        self.planID = planID
        self.clusterID = clusterID
        self.targetEpoch = targetEpoch
        self.nextStep = nextStep
        self.totalSteps = totalSteps
        self.transitionSHA256 = transitionSHA256
    }

    public var isComplete: Bool { nextStep == totalSteps }

    public func validate() throws {
        guard ClusterMembershipValidation.isSHA256(planID),
              ClusterMembershipValidation.isSHA256(transitionSHA256),
              totalSteps > 0,
              nextStep <= totalSteps else {
            throw ClusterMembershipError.invalidTransition("recovery record fields are invalid")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case planID
        case clusterID
        case targetEpoch
        case nextStep
        case totalSteps
        case transitionSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            planID: container.decode(String.self, forKey: .planID),
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            targetEpoch: container.decode(ClusterMembershipEpoch.self, forKey: .targetEpoch),
            nextStep: container.decode(UInt64.self, forKey: .nextStep),
            totalSteps: container.decode(UInt64.self, forKey: .totalSteps),
            transitionSHA256: container.decode(String.self, forKey: .transitionSHA256)
        )
    }

    public func advancing() throws -> Self {
        guard nextStep < totalSteps else {
            throw ClusterMembershipError.invalidTransition("recovery record is already complete")
        }
        return try Self(
            planID: planID,
            clusterID: clusterID,
            targetEpoch: targetEpoch,
            nextStep: nextStep + 1,
            totalSteps: totalSteps,
            transitionSHA256: transitionSHA256
        )
    }

    public func canonicalJSON() throws -> Data {
        try ClusterMembershipValidation.canonicalJSON(self)
    }
}

public struct ClusterMembershipPlan: Codable, Equatable, Sendable {
    public let planID: String
    public let clusterID: ClusterID
    public let operation: ClusterMembershipOperation
    public let change: ClusterMembershipChange
    public let before: ClusterMembershipIntent
    public let after: ClusterMembershipIntent
    public let transitions: [ClusterMembershipTransitionRecord]
    public let recovery: ClusterMembershipRecoveryRecord

    public var from: ClusterMembershipIntent { before }
    public var to: ClusterMembershipIntent { after }

    init(
        planID: String,
        clusterID: ClusterID,
        operation: ClusterMembershipOperation,
        change: ClusterMembershipChange,
        before: ClusterMembershipIntent,
        after: ClusterMembershipIntent,
        transitions: [ClusterMembershipTransitionRecord],
        recovery: ClusterMembershipRecoveryRecord
    ) {
        self.planID = planID
        self.clusterID = clusterID
        self.operation = operation
        self.change = change
        self.before = before
        self.after = after
        self.transitions = transitions
        self.recovery = recovery
    }

    public func validate(policy: ClusterMembershipPolicy = .default) throws {
        guard !transitions.isEmpty else {
            throw ClusterMembershipError.invalidTransition("plan must contain at least one transition")
        }
        try change.validate()
        let expectedPlanID = ClusterMembershipValidation.sha256(
            [
                operation.rawValue,
                before.canonicalSHA256,
                try ClusterMembershipValidation.canonicalJSONString(change)
            ].joined(separator: "|")
        )
        guard ClusterMembershipValidation.isSHA256(planID),
              planID == expectedPlanID,
              operation == change.operation,
              clusterID == before.clusterID,
              clusterID == after.clusterID,
              before.epoch < after.epoch,
              transitions.count == recovery.totalSteps,
              transitions.enumerated().allSatisfy({ $0.element.sequence == UInt64($0.offset + 1) }) else {
            throw ClusterMembershipError.invalidTransition("plan envelope is invalid")
        }
        try before.validate(policy: policy)
        try after.validate(policy: policy)
        try recovery.validate()
        let expectedAppliedPlanIDs = (before.appliedPlanIDs + [planID]).sorted()
        guard after.appliedPlanIDs == expectedAppliedPlanIDs else {
            throw ClusterMembershipError.invalidTransition("plan application history is invalid")
        }
        let expectedConsumedTokenIDs: [String]
        switch operation {
        case .joinLearner, .replaceVoter:
            guard let joinTokenID = change.joinTokenID else {
                throw ClusterMembershipError.invalidTransition("membership change is missing its join token")
            }
            expectedConsumedTokenIDs = (before.consumedJoinTokenIDs + [joinTokenID]).sorted()
        case .bootstrap, .promoteLearner, .removeVoter:
            expectedConsumedTokenIDs = before.consumedJoinTokenIDs
        }
        guard after.consumedJoinTokenIDs == expectedConsumedTokenIDs else {
            throw ClusterMembershipError.invalidTransition("plan token history is invalid")
        }
        guard recovery.planID == planID,
              recovery.clusterID == clusterID,
              recovery.targetEpoch == after.epoch,
              transitions.first?.fromEpoch == before.epoch,
              transitions.last?.toEpoch == after.epoch else {
            throw ClusterMembershipError.invalidTransition("plan recovery does not match transitions")
        }
        var previousEpoch = before.epoch
        var previousDigest = before.canonicalSHA256
        for (index, transition) in transitions.enumerated() {
            try transition.validate()
            guard transition.planID == planID,
                  transition.operation == operation,
                  transition.sequence == UInt64(index + 1),
                  transition.fromEpoch == previousEpoch,
                  transition.beforeSHA256 == previousDigest,
                  transition.fromEpoch < transition.toEpoch else {
                throw ClusterMembershipError.invalidTransition("transition sequence is invalid")
            }
            previousEpoch = transition.toEpoch
            previousDigest = transition.afterSHA256
        }
        guard previousEpoch == after.epoch,
              previousDigest == after.canonicalSHA256 else {
            throw ClusterMembershipError.invalidTransition("transition chain does not terminate at the plan intent")
        }
        let transitionSeed = try transitions
            .map { try ClusterMembershipValidation.canonicalJSONString($0) }
            .joined(separator: "|")
        guard recovery.transitionSHA256 == ClusterMembershipValidation.sha256(transitionSeed) else {
            throw ClusterMembershipError.invalidTransition("recovery digest does not match transitions")
        }
        try validateFinalIntent()
    }

    private func validateFinalIntent() throws {
        switch operation {
        case .bootstrap:
            guard before.members.isEmpty,
                  after.members.count == 1,
                  let peerEndpoint = change.peerEndpoint,
                  let clientEndpoint = change.clientEndpoint,
                  after.members[0] == (try ClusterMembershipMember(
                      nodeID: change.nodeID,
                      role: .voter,
                      peerEndpoint: peerEndpoint,
                      clientEndpoint: clientEndpoint
                  )) else {
                throw ClusterMembershipError.invalidTransition("bootstrap intent does not match its change")
            }
        case .joinLearner:
            guard let peerEndpoint = change.peerEndpoint,
                  let clientEndpoint = change.clientEndpoint,
                  let member = try? ClusterMembershipMember(
                      nodeID: change.nodeID,
                      role: .learner,
                      peerEndpoint: peerEndpoint,
                      clientEndpoint: clientEndpoint
                  ),
                  after.members == (before.members + [member]).sorted(by: { $0.nodeID < $1.nodeID }) else {
                throw ClusterMembershipError.invalidTransition("join intent does not match its change")
            }
        case .promoteLearner:
            guard let beforeMember = before.members.first(where: { $0.nodeID == change.nodeID }),
                  beforeMember.role == .learner,
                  let afterMember = after.members.first(where: { $0.nodeID == change.nodeID }),
                  afterMember.role == .voter,
                  before.members.filter({ $0.nodeID != change.nodeID }) ==
                    after.members.filter({ $0.nodeID != change.nodeID }) else {
                throw ClusterMembershipError.invalidTransition("promotion intent does not match its change")
            }
        case .removeVoter:
            guard before.members.contains(where: { $0.nodeID == change.nodeID && $0.role == .voter }),
                  after.members == before.members.filter({ $0.nodeID != change.nodeID }) else {
                throw ClusterMembershipError.invalidTransition("removal intent does not match its change")
            }
        case .replaceVoter:
            guard let replacementNodeID = change.replacementNodeID,
                  let peerEndpoint = change.peerEndpoint,
                  let clientEndpoint = change.clientEndpoint,
                  before.members.contains(where: { $0.nodeID == change.nodeID && $0.role == .voter }),
                  let replacement = try? ClusterMembershipMember(
                      nodeID: replacementNodeID,
                      role: .voter,
                      peerEndpoint: peerEndpoint,
                      clientEndpoint: clientEndpoint
                  ),
                  after.members == (before.members.filter({ $0.nodeID != change.nodeID }) + [replacement])
                    .sorted(by: { $0.nodeID < $1.nodeID }) else {
                throw ClusterMembershipError.invalidTransition("replacement intent does not match its change")
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case planID
        case clusterID
        case operation
        case change
        case before
        case after
        case transitions
        case recovery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let planID = try container.decode(String.self, forKey: .planID)
        let clusterID = try container.decode(ClusterID.self, forKey: .clusterID)
        let operation = try container.decode(ClusterMembershipOperation.self, forKey: .operation)
        let change = try container.decode(ClusterMembershipChange.self, forKey: .change)
        let before = try container.decode(ClusterMembershipIntent.self, forKey: .before)
        let after = try container.decode(ClusterMembershipIntent.self, forKey: .after)
        let transitions = try container.decode([ClusterMembershipTransitionRecord].self, forKey: .transitions)
        let recovery = try container.decode(ClusterMembershipRecoveryRecord.self, forKey: .recovery)
        self.init(
            planID: planID,
            clusterID: clusterID,
            operation: operation,
            change: change,
            before: before,
            after: after,
            transitions: transitions,
            recovery: recovery
        )
        try validate()
    }

    public func canonicalJSON() throws -> Data {
        try ClusterMembershipValidation.canonicalJSON(self)
    }
}

public enum ClusterMembershipApplyDisposition: String, Codable, Equatable, Sendable {
    case applied
    case replayed
}

public struct ClusterMembershipApplyResult: Codable, Equatable, Sendable {
    public let disposition: ClusterMembershipApplyDisposition
    public let intent: ClusterMembershipIntent

    public init(disposition: ClusterMembershipApplyDisposition, intent: ClusterMembershipIntent) {
        self.disposition = disposition
        self.intent = intent
    }
}

public struct ClusterMembershipPlanner: Sendable {
    public let policy: ClusterMembershipPolicy

    public init(policy: ClusterMembershipPolicy = .default) {
        self.policy = policy
    }

    public func bootstrap(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        peerEndpoint: String,
        clientEndpoint: String? = nil
    ) throws -> ClusterMembershipPlan {
        let before = try ClusterMembershipIntent.empty(clusterID: clusterID)
        let member = try ClusterMembershipMember(
            nodeID: nodeID,
            role: .voter,
            peerEndpoint: peerEndpoint,
            clientEndpoint: clientEndpoint
        )
        return try makePlan(
            before: before,
            operation: .bootstrap,
            change: ClusterMembershipChange(
                operation: .bootstrap,
                nodeID: nodeID,
                peerEndpoint: member.peerEndpoint,
                clientEndpoint: member.clientEndpoint
            ),
            intermediateIntents: [
                try ClusterMembershipIntent(
                    clusterID: clusterID,
                    epoch: try before.epoch.advanced(),
                    members: [member]
                )
            ]
        )
    }

    public func join(
        current: ClusterMembershipIntent,
        request: ClusterJoinRequest
    ) throws -> ClusterMembershipPlan {
        try current.validate(policy: policy)
        try request.validate()
        try validateJoinToken(request.token, for: current)
        if current.consumedJoinTokenIDs.contains(request.token.tokenID) {
            throw ClusterMembershipError.duplicateJoinToken
        }
        guard !current.members.contains(where: { $0.nodeID == request.nodeID }) else {
            throw ClusterMembershipError.duplicateNodeIdentity(request.nodeID)
        }
        let learner = try ClusterMembershipMember(
            nodeID: request.nodeID,
            role: .learner,
            peerEndpoint: request.peerEndpoint,
            clientEndpoint: request.clientEndpoint
        )
        let nextEpoch = try current.epoch.advanced()
        return try makePlan(
            before: current,
            operation: .joinLearner,
            change: ClusterMembershipChange(
                operation: .joinLearner,
                nodeID: request.nodeID,
                joinTokenID: request.token.tokenID,
                peerEndpoint: learner.peerEndpoint,
                clientEndpoint: learner.clientEndpoint
            ),
            intermediateIntents: [
                try ClusterMembershipIntent(
                    clusterID: current.clusterID,
                    epoch: nextEpoch,
                    members: current.members + [learner],
                    consumedJoinTokenIDs: current.consumedJoinTokenIDs + [request.token.tokenID],
                    appliedPlanIDs: current.appliedPlanIDs
                )
            ]
        )
    }

    public func promoteLearner(
        current: ClusterMembershipIntent,
        nodeID: ClusterNodeID
    ) throws -> ClusterMembershipPlan {
        try current.validate(policy: policy)
        guard let learner = current.members.first(where: { $0.nodeID == nodeID }) else {
            throw ClusterMembershipError.invalidTransition("learner does not exist")
        }
        guard learner.role == .learner else {
            throw ClusterMembershipError.invalidTransition("only a learner may be promoted")
        }
        let promoted = try ClusterMembershipMember(
            nodeID: learner.nodeID,
            role: .voter,
            peerEndpoint: learner.peerEndpoint,
            clientEndpoint: learner.clientEndpoint
        )
        let members = current.members.map { $0.nodeID == nodeID ? promoted : $0 }
        return try makePlan(
            before: current,
            operation: .promoteLearner,
            change: ClusterMembershipChange(operation: .promoteLearner, nodeID: nodeID),
            intermediateIntents: [
                try ClusterMembershipIntent(
                    clusterID: current.clusterID,
                    epoch: try current.epoch.advanced(),
                    members: members,
                    consumedJoinTokenIDs: current.consumedJoinTokenIDs,
                    appliedPlanIDs: current.appliedPlanIDs
                )
            ]
        )
    }

    public func removeVoter(
        current: ClusterMembershipIntent,
        nodeID: ClusterNodeID
    ) throws -> ClusterMembershipPlan {
        try current.validate(policy: policy)
        guard let member = current.members.first(where: { $0.nodeID == nodeID }) else {
            throw ClusterMembershipError.invalidTransition("voter does not exist")
        }
        guard member.role == .voter else {
            throw ClusterMembershipError.invalidTransition("only a voter may be removed")
        }
        let oldQuorum = current.quorum
        let remainingVoters = current.voters.count - 1
        guard remainingVoters > 0,
              remainingVoters >= oldQuorum else {
            throw ClusterMembershipError.quorumLoss
        }
        let members = current.members.filter { $0.nodeID != nodeID }
        return try makePlan(
            before: current,
            operation: .removeVoter,
            change: ClusterMembershipChange(operation: .removeVoter, nodeID: nodeID),
            intermediateIntents: [
                try ClusterMembershipIntent(
                    clusterID: current.clusterID,
                    epoch: try current.epoch.advanced(),
                    members: members,
                    consumedJoinTokenIDs: current.consumedJoinTokenIDs,
                    appliedPlanIDs: current.appliedPlanIDs
                )
            ]
        )
    }

    public func replaceVoter(
        current: ClusterMembershipIntent,
        nodeID: ClusterNodeID,
        replacement: ClusterJoinRequest
    ) throws -> ClusterMembershipPlan {
        try current.validate(policy: policy)
        try replacement.validate()
        try validateJoinToken(replacement.token, for: current)
        guard let oldMember = current.members.first(where: { $0.nodeID == nodeID }),
              oldMember.role == .voter else {
            throw ClusterMembershipError.invalidTransition("replacement target is not a voter")
        }
        guard !current.members.contains(where: { $0.nodeID == replacement.nodeID }) else {
            throw ClusterMembershipError.duplicateNodeIdentity(replacement.nodeID)
        }
        guard !current.consumedJoinTokenIDs.contains(replacement.token.tokenID) else {
            throw ClusterMembershipError.duplicateJoinToken
        }

        let learner = try ClusterMembershipMember(
            nodeID: replacement.nodeID,
            role: .learner,
            peerEndpoint: replacement.peerEndpoint,
            clientEndpoint: replacement.clientEndpoint
        )
        let promoted = try ClusterMembershipMember(
            nodeID: replacement.nodeID,
            role: .voter,
            peerEndpoint: replacement.peerEndpoint,
            clientEndpoint: replacement.clientEndpoint
        )
        let joinEpoch = try current.epoch.advanced()
        let promoteEpoch = try joinEpoch.advanced()
        let removeEpoch = try promoteEpoch.advanced()
        let joinedMembers = current.members + [learner]
        let promotedMembers = current.members + [promoted]
        let finalMembers = current.members
            .filter { $0.nodeID != nodeID } + [promoted]
        let consumed = current.consumedJoinTokenIDs + [replacement.token.tokenID]
        return try makePlan(
            before: current,
            operation: .replaceVoter,
            change: ClusterMembershipChange(
                operation: .replaceVoter,
                nodeID: nodeID,
                replacementNodeID: replacement.nodeID,
                joinTokenID: replacement.token.tokenID,
                peerEndpoint: replacement.peerEndpoint,
                clientEndpoint: replacement.clientEndpoint
            ),
            intermediateIntents: [
                try ClusterMembershipIntent(
                    clusterID: current.clusterID,
                    epoch: joinEpoch,
                    members: joinedMembers,
                    consumedJoinTokenIDs: consumed,
                    appliedPlanIDs: current.appliedPlanIDs
                ),
                try ClusterMembershipIntent(
                    clusterID: current.clusterID,
                    epoch: promoteEpoch,
                    members: promotedMembers,
                    consumedJoinTokenIDs: consumed,
                    appliedPlanIDs: current.appliedPlanIDs
                ),
                try ClusterMembershipIntent(
                    clusterID: current.clusterID,
                    epoch: removeEpoch,
                    members: finalMembers,
                    consumedJoinTokenIDs: consumed,
                    appliedPlanIDs: current.appliedPlanIDs
                )
            ]
        )
    }

    public func apply(
        _ plan: ClusterMembershipPlan,
        to current: ClusterMembershipIntent
    ) throws -> ClusterMembershipApplyResult {
        try plan.validate(policy: policy)
        try current.validate(policy: policy)
        guard current.clusterID == plan.clusterID else {
            throw ClusterMembershipError.replayConflict
        }
        if current == plan.after {
            return ClusterMembershipApplyResult(disposition: .replayed, intent: current)
        }
        if current.appliedPlanIDs.contains(plan.planID) {
            throw ClusterMembershipError.replayConflict
        }
        guard current == plan.before else {
            if current.epoch < plan.before.epoch {
                throw ClusterMembershipError.staleEpoch(expected: plan.before.epoch, actual: current.epoch)
            }
            throw ClusterMembershipError.replayConflict
        }
        return ClusterMembershipApplyResult(disposition: .applied, intent: plan.after)
    }

    private func validateJoinToken(
        _ token: ClusterJoinToken,
        for current: ClusterMembershipIntent
    ) throws {
        guard token.clusterID == current.clusterID,
              token.issuedEpoch <= current.epoch,
              !token.isExpired(at: current.epoch) else {
            throw ClusterMembershipError.staleJoinToken
        }
    }

    private func makePlan(
        before: ClusterMembershipIntent,
        operation: ClusterMembershipOperation,
        change: ClusterMembershipChange,
        intermediateIntents: [ClusterMembershipIntent]
    ) throws -> ClusterMembershipPlan {
        guard !intermediateIntents.isEmpty,
              intermediateIntents.allSatisfy({ $0.clusterID == before.clusterID }),
              intermediateIntents.first?.epoch == before.epoch.advancedOrNil,
              intermediateIntents.last!.epoch > before.epoch else {
            throw ClusterMembershipError.invalidTransition("intermediate intents are not monotonic")
        }
        for pair in zip(intermediateIntents, intermediateIntents.dropFirst()) {
            guard pair.0.epoch < pair.1.epoch else {
                throw ClusterMembershipError.invalidTransition("intermediate epochs are not monotonic")
            }
        }
        let seed = [
            operation.rawValue,
            before.canonicalSHA256,
            try ClusterMembershipValidation.canonicalJSONString(change)
        ].joined(separator: "|")
        let planID = ClusterMembershipValidation.sha256(seed)
        let final = intermediateIntents[intermediateIntents.count - 1]
        let after = try ClusterMembershipIntent(
            clusterID: final.clusterID,
            epoch: final.epoch,
            members: final.members,
            consumedJoinTokenIDs: final.consumedJoinTokenIDs,
            appliedPlanIDs: final.appliedPlanIDs + [planID]
        )
        var transitions: [ClusterMembershipTransitionRecord] = []
        var previous = before
        for (index, next) in intermediateIntents.enumerated() {
            let transitionTarget = index == intermediateIntents.count - 1 ? after : next
            transitions.append(
                try ClusterMembershipTransitionRecord(
                    sequence: UInt64(index + 1),
                    operation: operation,
                    planID: planID,
                    fromEpoch: previous.epoch,
                    toEpoch: transitionTarget.epoch,
                    beforeSHA256: previous.canonicalSHA256,
                    afterSHA256: transitionTarget.canonicalSHA256
                )
            )
            previous = transitionTarget
        }
        let transitionSeed = try transitions
            .map { try ClusterMembershipValidation.canonicalJSONString($0) }
            .joined(separator: "|")
        let recovery = try ClusterMembershipRecoveryRecord(
            planID: planID,
            clusterID: before.clusterID,
            targetEpoch: after.epoch,
            nextStep: 0,
            totalSteps: UInt64(transitions.count),
            transitionSHA256: ClusterMembershipValidation.sha256(transitionSeed)
        )
        let plan = ClusterMembershipPlan(
            planID: planID,
            clusterID: before.clusterID,
            operation: operation,
            change: change,
            before: before,
            after: after,
            transitions: transitions,
            recovery: recovery
        )
        try plan.validate(policy: policy)
        return plan
    }
}

private extension ClusterMembershipEpoch {
    var advancedOrNil: ClusterMembershipEpoch? {
        try? advanced()
    }
}

private enum ClusterMembershipValidation {
    static func endpoint(_ value: String) throws -> String {
        guard value.utf8.count <= 512,
              !value.contains("\0"),
              let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let port = components.port,
              (1...65_535).contains(port) else {
            throw ClusterMembershipError.invalidTopology("endpoint must be an https URL with an explicit port")
        }
        return value
    }

    static func safeOpaqueID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 45 || scalar.value == 46 || scalar.value == 95 ||
                (scalar.value >= 48 && scalar.value <= 57) ||
                (scalar.value >= 65 && scalar.value <= 90) ||
                (scalar.value >= 97 && scalar.value <= 122)
        }
    }

    static func validateUniqueOpaqueIDs(_ values: [String], label: String) throws {
        for value in values {
            guard safeOpaqueID(value) else {
                throw ClusterMembershipError.invalidTransition(label + " ID is invalid")
            }
        }
        guard Set(values).count == values.count,
              values == values.sorted() else {
            throw ClusterMembershipError.invalidTransition(label + " IDs are not unique and canonical")
        }
    }

    static func validateUniqueDigests(_ values: [String], label: String) throws {
        for value in values {
            guard isSHA256(value) else {
                throw ClusterMembershipError.invalidTransition(label + " ID is not a SHA256")
            }
        }
        guard Set(values).count == values.count,
              values == values.sorted() else {
            throw ClusterMembershipError.invalidTransition(label + " IDs are not unique and canonical")
        }
    }

    static func quorum(forVoterCount count: Int) -> Int {
        count == 0 ? 0 : (count / 2) + 1
    }

    static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func canonicalJSONString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try canonicalJSON(value), as: UTF8.self)
    }
}
