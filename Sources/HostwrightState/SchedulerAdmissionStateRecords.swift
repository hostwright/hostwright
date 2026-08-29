import CryptoKit
import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightScheduler

public enum SchedulerAdmissionStatus: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case pending
    case committed
    case releasePending = "release-pending"
    case fenced
    case released

    public var reservesCapacity: Bool {
        switch self {
        case .pending, .committed, .releasePending, .fenced:
            return true
        case .released:
            return false
        }
    }
}

public struct SchedulerFencingToken: Codable, Equatable, Hashable, Sendable {
    public let nodeEpoch: Int64
    public let reservationSequence: Int64

    private enum CodingKeys: String, CodingKey {
        case nodeEpoch
        case reservationSequence
    }

    public init(nodeEpoch: Int64, reservationSequence: Int64) throws {
        guard nodeEpoch >= 1 else {
            throw SchedulerAdmissionError.invalidBinding(field: "node-epoch")
        }
        guard reservationSequence >= 1 else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "reservation-sequence"
            )
        }
        self.nodeEpoch = nodeEpoch
        self.reservationSequence = reservationSequence
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nodeEpoch: values.decode(Int64.self, forKey: .nodeEpoch),
            reservationSequence: values.decode(
                Int64.self,
                forKey: .reservationSequence
            )
        )
    }

    public var stableKey: String {
        "\(nodeEpoch):\(reservationSequence)"
    }
}

public struct SchedulerFenceStateSnapshot: Codable, Equatable, Hashable, Sendable {
    public let nodeID: UUID
    public let nodeEpoch: Int64
    public let nextReservationSequence: Int64
    public let updatedAt: String
    public let recoveryEvidenceDigest: String?
    public let recoveryEvidenceAt: String?

    private enum CodingKeys: String, CodingKey {
        case nodeID
        case nodeEpoch
        case nextReservationSequence
        case updatedAt
        case recoveryEvidenceDigest
        case recoveryEvidenceAt
    }

    public init(
        nodeID: UUID,
        nodeEpoch: Int64,
        nextReservationSequence: Int64,
        updatedAt: String,
        recoveryEvidenceDigest: String?,
        recoveryEvidenceAt: String?
    ) throws {
        guard nodeEpoch >= 1 else {
            throw SchedulerAdmissionError.invalidBinding(field: "node-epoch")
        }
        guard nextReservationSequence >= 1 else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "next-reservation-sequence"
            )
        }
        let updatedDate = try SchedulerAdmissionValidation.timestamp(
            updatedAt,
            field: "updated-at"
        )
        guard (recoveryEvidenceDigest == nil) == (recoveryEvidenceAt == nil) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "recovery-evidence-pair"
            )
        }
        if let recoveryEvidenceDigest, let recoveryEvidenceAt {
            try SchedulerAdmissionValidation.evidenceDigest(
                recoveryEvidenceDigest,
                field: "recovery-evidence-digest"
            )
            let recoveryDate = try SchedulerAdmissionValidation.timestamp(
                recoveryEvidenceAt,
                field: "recovery-evidence-at"
            )
            guard recoveryDate >= updatedDate else {
                throw SchedulerAdmissionError.invalidBinding(
                    field: "recovery-evidence-order"
                )
            }
        }
        self.nodeID = nodeID
        self.nodeEpoch = nodeEpoch
        self.nextReservationSequence = nextReservationSequence
        self.updatedAt = updatedAt
        self.recoveryEvidenceDigest = recoveryEvidenceDigest
        self.recoveryEvidenceAt = recoveryEvidenceAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nodeID: values.decode(UUID.self, forKey: .nodeID),
            nodeEpoch: values.decode(Int64.self, forKey: .nodeEpoch),
            nextReservationSequence: values.decode(
                Int64.self,
                forKey: .nextReservationSequence
            ),
            updatedAt: values.decode(String.self, forKey: .updatedAt),
            recoveryEvidenceDigest: values.decodeIfPresent(
                String.self,
                forKey: .recoveryEvidenceDigest
            ),
            recoveryEvidenceAt: values.decodeIfPresent(
                String.self,
                forKey: .recoveryEvidenceAt
            )
        )
    }
}

public struct SchedulerNodeRecoveryEvidence: Codable, Equatable, Hashable, Sendable {
    public let nodeID: UUID
    public let expectedNodeEpoch: Int64
    public let newNodeEpoch: Int64
    public let evidenceDigest: String
    public let verifiedAt: String

    private enum CodingKeys: String, CodingKey {
        case nodeID
        case expectedNodeEpoch
        case newNodeEpoch
        case evidenceDigest
        case verifiedAt
    }

    public init(
        nodeID: UUID,
        expectedNodeEpoch: Int64,
        newNodeEpoch: Int64,
        evidenceDigest: String,
        verifiedAt: String
    ) throws {
        guard expectedNodeEpoch >= 1 else {
            throw SchedulerAdmissionError.invalidEvidence("expected-node-epoch")
        }
        guard newNodeEpoch > expectedNodeEpoch else {
            throw SchedulerAdmissionError.invalidEvidence(
                "recovery-epoch-not-newer"
            )
        }
        try SchedulerAdmissionValidation.evidenceDigest(
            evidenceDigest,
            field: "recovery-evidence-digest"
        )
        try SchedulerAdmissionValidation.timestamp(
            verifiedAt,
            field: "recovery-evidence-at"
        )
        self.nodeID = nodeID
        self.expectedNodeEpoch = expectedNodeEpoch
        self.newNodeEpoch = newNodeEpoch
        self.evidenceDigest = evidenceDigest
        self.verifiedAt = verifiedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nodeID: values.decode(UUID.self, forKey: .nodeID),
            expectedNodeEpoch: values.decode(
                Int64.self,
                forKey: .expectedNodeEpoch
            ),
            newNodeEpoch: values.decode(Int64.self, forKey: .newNodeEpoch),
            evidenceDigest: values.decode(String.self, forKey: .evidenceDigest),
            verifiedAt: values.decode(String.self, forKey: .verifiedAt)
        )
    }
}

public struct SchedulerNodeCapacitySnapshot: Codable, Equatable, Hashable, Sendable {
    public let nodeID: UUID
    public let capacity: ResourceVector
    public let capacityDigest: String
    public let generation: Int64
    public let observedAt: String

    private enum CodingKeys: String, CodingKey {
        case nodeID
        case capacity
        case capacityDigest
        case generation
        case observedAt
    }

    public init(
        nodeID: UUID,
        capacity: ResourceVector,
        capacityDigest: String,
        generation: Int64,
        observedAt: String
    ) throws {
        guard capacityDigest == Self.digest(for: capacity) else {
            throw SchedulerAdmissionError.invalidBinding(field: "node-capacity-digest")
        }
        guard generation >= 1 else {
            throw SchedulerAdmissionError.invalidBinding(field: "node-capacity-generation")
        }
        try SchedulerAdmissionValidation.timestamp(observedAt, field: "node-capacity-observed-at")
        self.nodeID = nodeID
        self.capacity = capacity
        self.capacityDigest = capacityDigest
        self.generation = generation
        self.observedAt = observedAt
    }

    public init(
        nodeID: UUID,
        capacity: ResourceVector,
        generation: Int64,
        observedAt: String
    ) throws {
        try self.init(
            nodeID: nodeID,
            capacity: capacity,
            capacityDigest: Self.digest(for: capacity),
            generation: generation,
            observedAt: observedAt
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nodeID: values.decode(UUID.self, forKey: .nodeID),
            capacity: values.decode(ResourceVector.self, forKey: .capacity),
            capacityDigest: values.decode(String.self, forKey: .capacityDigest),
            generation: values.decode(Int64.self, forKey: .generation),
            observedAt: values.decode(String.self, forKey: .observedAt)
        )
    }

    public static func digest(for capacity: ResourceVector) -> String {
        let data = SchedulerAdmissionCanonicalJSON.vectorData(capacity)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SchedulerAdmissionErrorCode: String, Codable, Equatable, Hashable, Sendable {
    case invalidBinding = "invalid-binding"
    case staleInput = "stale-input"
    case conflictingReplay = "conflicting-replay"
    case duplicateActiveWorkload = "duplicate-active-workload"
    case insufficientCapacity = "insufficient-capacity"
    case staleFence = "stale-fence"
    case staleNodeEpoch = "stale-node-epoch"
    case notFound = "not-found"
    case invalidTransition = "invalid-transition"
    case invalidEvidence = "invalid-evidence"
    case releaseEvidenceRequired = "release-evidence-required"
    case stateInvariant = "state-invariant"
    case fencingTokenExhausted = "fencing-token-exhausted"
    case resourceArithmetic = "resource-arithmetic"
}

public enum SchedulerAdmissionError:
    Error,
    Equatable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    case invalidBinding(field: String)
    case staleInput(field: String)
    case conflictingReplay(decisionID: UUID)
    case duplicateActiveWorkload(workloadID: UUID, decisionID: UUID)
    case insufficientCapacity(
        nodeID: UUID,
        requested: ResourceVector,
        available: ResourceVector
    )
    case staleFence(
        nodeID: UUID,
        expected: SchedulerFencingToken,
        actual: SchedulerFencingToken
    )
    case staleNodeEpoch(nodeID: UUID, expected: Int64, actual: Int64)
    case notFound(kind: String, id: UUID)
    case invalidTransition(reservationID: UUID, status: SchedulerAdmissionStatus)
    case invalidEvidence(String)
    case releaseEvidenceRequired(reservationID: UUID)
    case stateInvariant(String)
    case fencingTokenExhausted(nodeID: UUID)
    case resourceArithmetic(resource: String)

    public var code: SchedulerAdmissionErrorCode {
        switch self {
        case .invalidBinding:
            .invalidBinding
        case .staleInput:
            .staleInput
        case .conflictingReplay:
            .conflictingReplay
        case .duplicateActiveWorkload:
            .duplicateActiveWorkload
        case .insufficientCapacity:
            .insufficientCapacity
        case .staleFence:
            .staleFence
        case .staleNodeEpoch:
            .staleNodeEpoch
        case .notFound:
            .notFound
        case .invalidTransition:
            .invalidTransition
        case .invalidEvidence:
            .invalidEvidence
        case .releaseEvidenceRequired:
            .releaseEvidenceRequired
        case .stateInvariant:
            .stateInvariant
        case .fencingTokenExhausted:
            .fencingTokenExhausted
        case .resourceArithmetic:
            .resourceArithmetic
        }
    }

    public var stableKey: String {
        switch self {
        case .invalidBinding(let field):
            return "\(code.rawValue):\(field)"
        case .staleInput(let field):
            return "\(code.rawValue):\(field)"
        case .conflictingReplay(let decisionID):
            return "\(code.rawValue):\(decisionID.uuidString.lowercased())"
        case .duplicateActiveWorkload(let workloadID, let decisionID):
            return "\(code.rawValue):\(workloadID.uuidString.lowercased()):\(decisionID.uuidString.lowercased())"
        case .insufficientCapacity(let nodeID, _, _):
            return "\(code.rawValue):\(nodeID.uuidString.lowercased())"
        case .staleFence(let nodeID, let expected, let actual):
            return "\(code.rawValue):\(nodeID.uuidString.lowercased()):\(expected.stableKey):\(actual.stableKey)"
        case .staleNodeEpoch(let nodeID, let expected, let actual):
            return "\(code.rawValue):\(nodeID.uuidString.lowercased()):\(expected):\(actual)"
        case .notFound(let kind, let id):
            return "\(code.rawValue):\(kind):\(id.uuidString.lowercased())"
        case .invalidTransition(let reservationID, let status):
            return "\(code.rawValue):\(reservationID.uuidString.lowercased()):\(status.rawValue)"
        case .invalidEvidence(let detail):
            return "\(code.rawValue):\(detail)"
        case .releaseEvidenceRequired(let reservationID):
            return "\(code.rawValue):\(reservationID.uuidString.lowercased())"
        case .stateInvariant(let detail):
            return "\(code.rawValue):\(detail)"
        case .fencingTokenExhausted(let nodeID):
            return "\(code.rawValue):\(nodeID.uuidString.lowercased())"
        case .resourceArithmetic(let resource):
            return "\(code.rawValue):\(resource)"
        }
    }

    public var description: String {
        stableKey
    }
}

public struct SchedulerAdmissionBinding: Codable, Equatable, Hashable, Sendable {
    public let decisionID: UUID
    public let workloadID: UUID
    public let nodeID: UUID
    public let resources: ResourceVector
    public let nodeCapacityDigest: String
    public let nodeCapacityGeneration: Int64
    public let inputDigest: String
    public let configDigest: String
    public let profileDigest: String
    public let lifecyclePlanDigest: String
    public let ownerSubjectID: String
    public let projectUUID: String
    public let createdAt: String
    public let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case decisionID
        case workloadID
        case nodeID
        case resources
        case nodeCapacityDigest
        case nodeCapacityGeneration
        case inputDigest
        case configDigest
        case profileDigest
        case lifecyclePlanDigest
        case ownerSubjectID
        case projectUUID
        case createdAt
        case expiresAt
    }

    public init(
        decisionID: UUID,
        workloadID: UUID,
        nodeID: UUID,
        resources: ResourceVector,
        nodeCapacityDigest: String,
        nodeCapacityGeneration: Int64,
        inputDigest: String,
        configDigest: String,
        profileDigest: String,
        lifecyclePlanDigest: String,
        ownerSubjectID: String,
        projectUUID: String,
        createdAt: String,
        expiresAt: String
    ) throws {
        try SchedulerAdmissionValidation.digest(
            nodeCapacityDigest,
            field: "node-capacity-digest"
        )
        guard nodeCapacityGeneration >= 1 else {
            throw SchedulerAdmissionError.invalidBinding(field: "node-capacity-generation")
        }
        try SchedulerAdmissionValidation.digest(inputDigest, field: "input-digest")
        try SchedulerAdmissionValidation.digest(configDigest, field: "config-digest")
        try SchedulerAdmissionValidation.digest(profileDigest, field: "profile-digest")
        try SchedulerAdmissionValidation.digest(
            lifecyclePlanDigest,
            field: "lifecycle-plan-digest"
        )
        try SchedulerAdmissionValidation.subject(ownerSubjectID)
        guard HostwrightResourceUUID.isValid(projectUUID) else {
            throw SchedulerAdmissionError.invalidBinding(field: "project-uuid")
        }
        let createdDate = try SchedulerAdmissionValidation.timestamp(
            createdAt,
            field: "created-at"
        )
        let expiresDate = try SchedulerAdmissionValidation.timestamp(
            expiresAt,
            field: "expires-at"
        )
        guard expiresDate > createdDate else {
            throw SchedulerAdmissionError.invalidBinding(field: "expiry-order")
        }

        self.decisionID = decisionID
        self.workloadID = workloadID
        self.nodeID = nodeID
        self.resources = resources
        self.nodeCapacityDigest = nodeCapacityDigest
        self.nodeCapacityGeneration = nodeCapacityGeneration
        self.inputDigest = inputDigest
        self.configDigest = configDigest
        self.profileDigest = profileDigest
        self.lifecyclePlanDigest = lifecyclePlanDigest
        self.ownerSubjectID = ownerSubjectID
        self.projectUUID = projectUUID.lowercased()
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            decisionID: values.decode(UUID.self, forKey: .decisionID),
            workloadID: values.decode(UUID.self, forKey: .workloadID),
            nodeID: values.decode(UUID.self, forKey: .nodeID),
            resources: values.decode(ResourceVector.self, forKey: .resources),
            nodeCapacityDigest: values.decode(
                String.self,
                forKey: .nodeCapacityDigest
            ),
            nodeCapacityGeneration: values.decode(
                Int64.self,
                forKey: .nodeCapacityGeneration
            ),
            inputDigest: values.decode(String.self, forKey: .inputDigest),
            configDigest: values.decode(String.self, forKey: .configDigest),
            profileDigest: values.decode(String.self, forKey: .profileDigest),
            lifecyclePlanDigest: values.decode(
                String.self,
                forKey: .lifecyclePlanDigest
            ),
            ownerSubjectID: values.decode(String.self, forKey: .ownerSubjectID),
            projectUUID: values.decode(String.self, forKey: .projectUUID),
            createdAt: values.decode(String.self, forKey: .createdAt),
            expiresAt: values.decode(String.self, forKey: .expiresAt)
        )
    }

}

public struct SchedulerAdmissionAuthority: Codable, Equatable, Hashable, Sendable {
    public let nodeCapacityDigest: String
    public let nodeCapacityGeneration: Int64
    public let inputDigest: String
    public let configDigest: String
    public let profileDigest: String
    public let lifecyclePlanDigest: String
    public let expectedNodeEpoch: Int64

    private enum CodingKeys: String, CodingKey {
        case nodeCapacityDigest
        case nodeCapacityGeneration
        case inputDigest
        case configDigest
        case profileDigest
        case lifecyclePlanDigest
        case expectedNodeEpoch
    }

    public init(
        nodeCapacityDigest: String,
        nodeCapacityGeneration: Int64,
        inputDigest: String,
        configDigest: String,
        profileDigest: String,
        lifecyclePlanDigest: String,
        expectedNodeEpoch: Int64 = 1
    ) throws {
        try SchedulerAdmissionValidation.digest(
            nodeCapacityDigest,
            field: "node-capacity-digest"
        )
        guard nodeCapacityGeneration >= 1 else {
            throw SchedulerAdmissionError.invalidBinding(field: "node-capacity-generation")
        }
        try SchedulerAdmissionValidation.digest(inputDigest, field: "input-digest")
        try SchedulerAdmissionValidation.digest(configDigest, field: "config-digest")
        try SchedulerAdmissionValidation.digest(profileDigest, field: "profile-digest")
        try SchedulerAdmissionValidation.digest(
            lifecyclePlanDigest,
            field: "lifecycle-plan-digest"
        )
        guard expectedNodeEpoch >= 1 else {
            throw SchedulerAdmissionError.invalidBinding(field: "expected-node-epoch")
        }
        self.nodeCapacityDigest = nodeCapacityDigest
        self.nodeCapacityGeneration = nodeCapacityGeneration
        self.inputDigest = inputDigest
        self.configDigest = configDigest
        self.profileDigest = profileDigest
        self.lifecyclePlanDigest = lifecyclePlanDigest
        self.expectedNodeEpoch = expectedNodeEpoch
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nodeCapacityDigest: values.decode(
                String.self,
                forKey: .nodeCapacityDigest
            ),
            nodeCapacityGeneration: values.decode(
                Int64.self,
                forKey: .nodeCapacityGeneration
            ),
            inputDigest: values.decode(String.self, forKey: .inputDigest),
            configDigest: values.decode(String.self, forKey: .configDigest),
            profileDigest: values.decode(String.self, forKey: .profileDigest),
            lifecyclePlanDigest: values.decode(
                String.self,
                forKey: .lifecyclePlanDigest
            ),
            expectedNodeEpoch: values.decode(Int64.self, forKey: .expectedNodeEpoch)
        )
    }

}

public struct SchedulerFenceEvidence: Codable, Equatable, Hashable, Sendable {
    public let token: SchedulerFencingToken
    public let reservationID: UUID
    public let workloadID: UUID
    public let evidenceDigest: String
    public let verifiedAt: String

    private enum CodingKeys: String, CodingKey {
        case token
        case reservationID
        case workloadID
        case evidenceDigest
        case verifiedAt
    }

    public init(
        token: SchedulerFencingToken,
        reservationID: UUID,
        workloadID: UUID,
        evidenceDigest: String,
        verifiedAt: String
    ) throws {
        try SchedulerAdmissionValidation.fencingToken(token, field: "fencing-token")
        try SchedulerAdmissionValidation.evidenceDigest(
            evidenceDigest,
            field: "fence-evidence-digest"
        )
        try SchedulerAdmissionValidation.timestamp(
            verifiedAt,
            field: "fence-evidence-at"
        )
        self.token = token
        self.reservationID = reservationID
        self.workloadID = workloadID
        self.evidenceDigest = evidenceDigest
        self.verifiedAt = verifiedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            token: values.decode(SchedulerFencingToken.self, forKey: .token),
            reservationID: values.decode(UUID.self, forKey: .reservationID),
            workloadID: values.decode(UUID.self, forKey: .workloadID),
            evidenceDigest: values.decode(String.self, forKey: .evidenceDigest),
            verifiedAt: values.decode(String.self, forKey: .verifiedAt)
        )
    }
}

public enum SchedulerReleaseEvidence: Codable, Equatable, Hashable, Sendable {
    case verifiedRuntimeAbsence(evidenceDigest: String, verifiedAt: String)
    case authoritativeFence(
        token: SchedulerFencingToken,
        reservationID: UUID,
        workloadID: UUID,
        evidenceDigest: String,
        verifiedAt: String
    )

    private enum CodingKeys: String, CodingKey {
        case verifiedRuntimeAbsence
        case authoritativeFence
    }

    private enum RuntimeAbsenceKeys: String, CodingKey {
        case evidenceDigest
        case verifiedAt
    }

    private enum AuthoritativeFenceKeys: String, CodingKey {
        case token
        case reservationID
        case workloadID
        case evidenceDigest
        case verifiedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.allKeys.count == 1 else {
            throw SchedulerAdmissionError.invalidEvidence("release-evidence-case")
        }
        if values.contains(.verifiedRuntimeAbsence) {
            let nested = try values.nestedContainer(
                keyedBy: RuntimeAbsenceKeys.self,
                forKey: .verifiedRuntimeAbsence
            )
            let digest = try nested.decode(
                String.self,
                forKey: .evidenceDigest
            )
            let verifiedAt = try nested.decode(String.self, forKey: .verifiedAt)
            try SchedulerAdmissionValidation.evidenceDigest(
                digest,
                field: "release-evidence-digest"
            )
            try SchedulerAdmissionValidation.timestamp(
                verifiedAt,
                field: "release-evidence-at"
            )
            self = .verifiedRuntimeAbsence(
                evidenceDigest: digest,
                verifiedAt: verifiedAt
            )
            return
        }
        if values.contains(.authoritativeFence) {
            let nested = try values.nestedContainer(
                keyedBy: AuthoritativeFenceKeys.self,
                forKey: .authoritativeFence
            )
            let digest = try nested.decode(
                String.self,
                forKey: .evidenceDigest
            )
            let verifiedAt = try nested.decode(String.self, forKey: .verifiedAt)
            try SchedulerAdmissionValidation.evidenceDigest(
                digest,
                field: "release-evidence-digest"
            )
            try SchedulerAdmissionValidation.timestamp(
                verifiedAt,
                field: "release-evidence-at"
            )
            self = .authoritativeFence(
                token: try nested.decode(SchedulerFencingToken.self, forKey: .token),
                reservationID: try nested.decode(UUID.self, forKey: .reservationID),
                workloadID: try nested.decode(UUID.self, forKey: .workloadID),
                evidenceDigest: digest,
                verifiedAt: verifiedAt
            )
            return
        }
        throw SchedulerAdmissionError.invalidEvidence("release-evidence-case")
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .verifiedRuntimeAbsence(let evidenceDigest, let verifiedAt):
            var nested = values.nestedContainer(
                keyedBy: RuntimeAbsenceKeys.self,
                forKey: .verifiedRuntimeAbsence
            )
            try nested.encode(evidenceDigest, forKey: .evidenceDigest)
            try nested.encode(verifiedAt, forKey: .verifiedAt)
        case .authoritativeFence(
            let token,
            let reservationID,
            let workloadID,
            let evidenceDigest,
            let verifiedAt
        ):
            var nested = values.nestedContainer(
                keyedBy: AuthoritativeFenceKeys.self,
                forKey: .authoritativeFence
            )
            try nested.encode(token, forKey: .token)
            try nested.encode(reservationID, forKey: .reservationID)
            try nested.encode(workloadID, forKey: .workloadID)
            try nested.encode(evidenceDigest, forKey: .evidenceDigest)
            try nested.encode(verifiedAt, forKey: .verifiedAt)
        }
    }
}

public struct SchedulerDecisionRecord: Codable, Equatable, Sendable {
    public let decisionID: UUID
    public let reservationID: UUID
    public let workloadID: UUID
    public let nodeID: UUID
    public let resources: ResourceVector
    public let capacityDigest: String
    public let capacityGeneration: Int64
    public let inputDigest: String
    public let configDigest: String
    public let profileDigest: String
    public let lifecyclePlanDigest: String
    public let ownerSubjectID: String
    public let projectUUID: String
    public let status: SchedulerAdmissionStatus
    public let createdAt: String
    public let updatedAt: String
    public let expiresAt: String
    public let fencingToken: SchedulerFencingToken
    public let fenceEvidence: SchedulerFenceEvidence?
    public let releaseEvidence: SchedulerReleaseEvidence?

    private enum CodingKeys: String, CodingKey {
        case decisionID
        case reservationID
        case workloadID
        case nodeID
        case resources
        case capacityDigest
        case capacityGeneration
        case inputDigest
        case configDigest
        case profileDigest
        case lifecyclePlanDigest
        case ownerSubjectID
        case projectUUID
        case status
        case createdAt
        case updatedAt
        case expiresAt
        case fencingToken
        case fenceEvidence
        case releaseEvidence
    }

    init(
        decisionID: UUID,
        reservationID: UUID,
        workloadID: UUID,
        nodeID: UUID,
        resources: ResourceVector,
        capacityDigest: String,
        capacityGeneration: Int64,
        inputDigest: String,
        configDigest: String,
        profileDigest: String,
        lifecyclePlanDigest: String,
        ownerSubjectID: String,
        projectUUID: String,
        status: SchedulerAdmissionStatus,
        createdAt: String,
        updatedAt: String,
        expiresAt: String,
        fencingToken: SchedulerFencingToken,
        fenceEvidence: SchedulerFenceEvidence?,
        releaseEvidence: SchedulerReleaseEvidence?
    ) {
        self.decisionID = decisionID
        self.reservationID = reservationID
        self.workloadID = workloadID
        self.nodeID = nodeID
        self.resources = resources
        self.capacityDigest = capacityDigest
        self.capacityGeneration = capacityGeneration
        self.inputDigest = inputDigest
        self.configDigest = configDigest
        self.profileDigest = profileDigest
        self.lifecyclePlanDigest = lifecyclePlanDigest
        self.ownerSubjectID = ownerSubjectID
        self.projectUUID = projectUUID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.fencingToken = fencingToken
        self.fenceEvidence = fenceEvidence
        self.releaseEvidence = releaseEvidence
    }

    public init(from decoder: Decoder) throws {
        let decoded = try SchedulerAdmissionRecordCoding.decode(from: decoder)
        self.decisionID = decoded.decisionID
        self.reservationID = decoded.reservationID
        self.workloadID = decoded.workloadID
        self.nodeID = decoded.nodeID
        self.resources = decoded.resources
        self.capacityDigest = decoded.capacityDigest
        self.capacityGeneration = decoded.capacityGeneration
        self.inputDigest = decoded.inputDigest
        self.configDigest = decoded.configDigest
        self.profileDigest = decoded.profileDigest
        self.lifecyclePlanDigest = decoded.lifecyclePlanDigest
        self.ownerSubjectID = decoded.ownerSubjectID
        self.projectUUID = decoded.projectUUID
        self.status = decoded.status
        self.createdAt = decoded.createdAt
        self.updatedAt = decoded.updatedAt
        self.expiresAt = decoded.expiresAt
        self.fencingToken = decoded.fencingToken
        self.fenceEvidence = decoded.fenceEvidence
        self.releaseEvidence = decoded.releaseEvidence
    }
}

public struct SchedulerReservationRecord: Codable, Equatable, Sendable {
    public let reservationID: UUID
    public let decisionID: UUID
    public let workloadID: UUID
    public let nodeID: UUID
    public let resources: ResourceVector
    public let capacityDigest: String
    public let capacityGeneration: Int64
    public let inputDigest: String
    public let configDigest: String
    public let profileDigest: String
    public let lifecyclePlanDigest: String
    public let ownerSubjectID: String
    public let projectUUID: String
    public let status: SchedulerAdmissionStatus
    public let createdAt: String
    public let updatedAt: String
    public let expiresAt: String
    public let fencingToken: SchedulerFencingToken
    public let fenceEvidence: SchedulerFenceEvidence?
    public let releaseEvidence: SchedulerReleaseEvidence?
    /// Hydrated from the immutable decision binding. It is nil for legacy or
    /// incomplete rows and must therefore produce unknown recovery evidence.
    public let runtimeOwnership: SchedulerRuntimeOwnershipBinding?

    private enum CodingKeys: String, CodingKey {
        case reservationID
        case decisionID
        case workloadID
        case nodeID
        case resources
        case capacityDigest
        case capacityGeneration
        case inputDigest
        case configDigest
        case profileDigest
        case lifecyclePlanDigest
        case ownerSubjectID
        case projectUUID
        case status
        case createdAt
        case updatedAt
        case expiresAt
        case fencingToken
        case fenceEvidence
        case releaseEvidence
        case runtimeOwnership
    }

    init(
        reservationID: UUID,
        decisionID: UUID,
        workloadID: UUID,
        nodeID: UUID,
        resources: ResourceVector,
        capacityDigest: String,
        capacityGeneration: Int64,
        inputDigest: String,
        configDigest: String,
        profileDigest: String,
        lifecyclePlanDigest: String,
        ownerSubjectID: String,
        projectUUID: String,
        status: SchedulerAdmissionStatus,
        createdAt: String,
        updatedAt: String,
        expiresAt: String,
        fencingToken: SchedulerFencingToken,
        fenceEvidence: SchedulerFenceEvidence?,
        releaseEvidence: SchedulerReleaseEvidence?,
        runtimeOwnership: SchedulerRuntimeOwnershipBinding? = nil
    ) {
        self.reservationID = reservationID
        self.decisionID = decisionID
        self.workloadID = workloadID
        self.nodeID = nodeID
        self.resources = resources
        self.capacityDigest = capacityDigest
        self.capacityGeneration = capacityGeneration
        self.inputDigest = inputDigest
        self.configDigest = configDigest
        self.profileDigest = profileDigest
        self.lifecyclePlanDigest = lifecyclePlanDigest
        self.ownerSubjectID = ownerSubjectID
        self.projectUUID = projectUUID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.fencingToken = fencingToken
        self.fenceEvidence = fenceEvidence
        self.releaseEvidence = releaseEvidence
        self.runtimeOwnership = runtimeOwnership
    }

    public init(from decoder: Decoder) throws {
        let decoded = try SchedulerAdmissionRecordCoding.decode(from: decoder)
        self.reservationID = decoded.reservationID
        self.decisionID = decoded.decisionID
        self.workloadID = decoded.workloadID
        self.nodeID = decoded.nodeID
        self.resources = decoded.resources
        self.capacityDigest = decoded.capacityDigest
        self.capacityGeneration = decoded.capacityGeneration
        self.inputDigest = decoded.inputDigest
        self.configDigest = decoded.configDigest
        self.profileDigest = decoded.profileDigest
        self.lifecyclePlanDigest = decoded.lifecyclePlanDigest
        self.ownerSubjectID = decoded.ownerSubjectID
        self.projectUUID = decoded.projectUUID
        self.status = decoded.status
        self.createdAt = decoded.createdAt
        self.updatedAt = decoded.updatedAt
        self.expiresAt = decoded.expiresAt
        self.fencingToken = decoded.fencingToken
        self.fenceEvidence = decoded.fenceEvidence
        self.releaseEvidence = decoded.releaseEvidence
        self.runtimeOwnership = decoded.runtimeOwnership
    }

    func hydrated(with runtimeOwnership: SchedulerRuntimeOwnershipBinding?) -> SchedulerReservationRecord {
        SchedulerReservationRecord(
            reservationID: reservationID,
            decisionID: decisionID,
            workloadID: workloadID,
            nodeID: nodeID,
            resources: resources,
            capacityDigest: capacityDigest,
            capacityGeneration: capacityGeneration,
            inputDigest: inputDigest,
            configDigest: configDigest,
            profileDigest: profileDigest,
            lifecyclePlanDigest: lifecyclePlanDigest,
            ownerSubjectID: ownerSubjectID,
            projectUUID: projectUUID,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            expiresAt: expiresAt,
            fencingToken: fencingToken,
            fenceEvidence: fenceEvidence,
            releaseEvidence: releaseEvidence,
            runtimeOwnership: runtimeOwnership
        )
    }

}

private struct SchedulerAdmissionRecordDecodedValues {
    let decisionID: UUID
    let reservationID: UUID
    let workloadID: UUID
    let nodeID: UUID
    let resources: ResourceVector
    let capacityDigest: String
    let capacityGeneration: Int64
    let inputDigest: String
    let configDigest: String
    let profileDigest: String
    let lifecyclePlanDigest: String
    let ownerSubjectID: String
    let projectUUID: String
    let status: SchedulerAdmissionStatus
    let createdAt: String
    let updatedAt: String
    let expiresAt: String
    let fencingToken: SchedulerFencingToken
    let fenceEvidence: SchedulerFenceEvidence?
    let releaseEvidence: SchedulerReleaseEvidence?
    let runtimeOwnership: SchedulerRuntimeOwnershipBinding?
}

private enum SchedulerAdmissionRecordCoding {
    private enum CodingKeys: String, CodingKey {
        case decisionID
        case reservationID
        case workloadID
        case nodeID
        case resources
        case capacityDigest
        case capacityGeneration
        case inputDigest
        case configDigest
        case profileDigest
        case lifecyclePlanDigest
        case ownerSubjectID
        case projectUUID
        case status
        case createdAt
        case updatedAt
        case expiresAt
        case fencingToken
        case fenceEvidence
        case releaseEvidence
        case runtimeOwnership
    }

    static func decode(
        from decoder: Decoder
    ) throws -> SchedulerAdmissionRecordDecodedValues {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decisionID = try values.decode(UUID.self, forKey: .decisionID)
        let reservationID = try values.decode(UUID.self, forKey: .reservationID)
        let workloadID = try values.decode(UUID.self, forKey: .workloadID)
        let nodeID = try values.decode(UUID.self, forKey: .nodeID)
        let resources = try values.decode(ResourceVector.self, forKey: .resources)
        let capacityDigest = try values.decode(String.self, forKey: .capacityDigest)
        let capacityGeneration = try values.decode(
            Int64.self,
            forKey: .capacityGeneration
        )
        let inputDigest = try values.decode(String.self, forKey: .inputDigest)
        let configDigest = try values.decode(String.self, forKey: .configDigest)
        let profileDigest = try values.decode(String.self, forKey: .profileDigest)
        let lifecyclePlanDigest = try values.decode(
            String.self,
            forKey: .lifecyclePlanDigest
        )
        let ownerSubjectID = try values.decode(String.self, forKey: .ownerSubjectID)
        let projectUUID = try values.decode(String.self, forKey: .projectUUID)
        let status = try values.decode(SchedulerAdmissionStatus.self, forKey: .status)
        let createdAt = try values.decode(String.self, forKey: .createdAt)
        let updatedAt = try values.decode(String.self, forKey: .updatedAt)
        let expiresAt = try values.decode(String.self, forKey: .expiresAt)
        let fencingToken = try values.decode(
            SchedulerFencingToken.self,
            forKey: .fencingToken
        )
        let fenceEvidence = try values.decodeIfPresent(
            SchedulerFenceEvidence.self,
            forKey: .fenceEvidence
        )
        let releaseEvidence = try values.decodeIfPresent(
            SchedulerReleaseEvidence.self,
            forKey: .releaseEvidence
        )
        let runtimeOwnership = try values.decodeIfPresent(
            SchedulerRuntimeOwnershipBinding.self,
            forKey: .runtimeOwnership
        )

        try SchedulerAdmissionValidation.digest(
            capacityDigest,
            field: "capacity-digest"
        )
        try SchedulerAdmissionValidation.digest(inputDigest, field: "input-digest")
        try SchedulerAdmissionValidation.digest(configDigest, field: "config-digest")
        try SchedulerAdmissionValidation.digest(profileDigest, field: "profile-digest")
        try SchedulerAdmissionValidation.digest(
            lifecyclePlanDigest,
            field: "lifecycle-plan-digest"
        )
        try SchedulerAdmissionValidation.subject(ownerSubjectID)
        let createdDate = try SchedulerAdmissionValidation.timestamp(
            createdAt,
            field: "created-at"
        )
        let updatedDate = try SchedulerAdmissionValidation.timestamp(
            updatedAt,
            field: "updated-at"
        )
        let expiresDate = try SchedulerAdmissionValidation.timestamp(
            expiresAt,
            field: "expires-at"
        )
        guard capacityGeneration >= 1,
              updatedDate >= createdDate,
              expiresDate > createdDate,
              HostwrightResourceUUID.isValid(projectUUID) else {
            throw SchedulerAdmissionError.stateInvariant("scheduler-record-binding")
        }
        if let runtimeOwnership {
            guard runtimeOwnership.projectUUID == projectUUID.lowercased(),
                  runtimeOwnership.resourceUUID == workloadID.uuidString.lowercased() else {
                throw SchedulerAdmissionError.stateInvariant(
                    "scheduler-runtime-ownership-binding"
                )
            }
        }
        _ = try SchedulerAdmissionBinding(
            decisionID: decisionID,
            workloadID: workloadID,
            nodeID: nodeID,
            resources: resources,
            nodeCapacityDigest: capacityDigest,
            nodeCapacityGeneration: capacityGeneration,
            inputDigest: inputDigest,
            configDigest: configDigest,
            profileDigest: profileDigest,
            lifecyclePlanDigest: lifecyclePlanDigest,
            ownerSubjectID: ownerSubjectID,
            projectUUID: projectUUID,
            createdAt: createdAt,
            expiresAt: expiresAt
        )

        switch status {
        case .pending, .committed, .releasePending:
            guard fenceEvidence == nil, releaseEvidence == nil else {
                throw SchedulerAdmissionError.stateInvariant(
                    "unreleased-record-with-proof"
                )
            }
        case .fenced:
            guard let fenceEvidence, releaseEvidence == nil else {
                throw SchedulerAdmissionError.stateInvariant(
                    "fenced-record-proof-shape"
                )
            }
            try validateFenceEvidence(
                fenceEvidence,
                reservationID: reservationID,
                workloadID: workloadID,
                fencingToken: fencingToken,
                currentDate: updatedDate,
                createdDate: createdDate
            )
        case .released:
            guard let releaseEvidence else {
                throw SchedulerAdmissionError.stateInvariant(
                    "released-without-proof"
                )
            }
            let releaseDate = try SchedulerAdmissionValidation.timestamp(
                evidenceTimestamp(releaseEvidence),
                field: "release-evidence-at"
            )
            guard releaseDate >= createdDate, releaseDate == updatedDate else {
                throw SchedulerAdmissionError.stateInvariant("release-proof-order")
            }
            if let fenceEvidence {
                try validateFenceEvidence(
                    fenceEvidence,
                    reservationID: reservationID,
                    workloadID: workloadID,
                    fencingToken: fencingToken,
                    currentDate: nil,
                    createdDate: createdDate
                )
                guard try SchedulerAdmissionValidation.timestamp(fenceEvidence.verifiedAt, field: "fence-evidence-at") <= releaseDate else {
                    throw SchedulerAdmissionError.stateInvariant("fence-proof-order")
                }
            }
            if case .authoritativeFence(
                let token,
                let evidenceReservationID,
                let evidenceWorkloadID,
                _,
                _
            ) = releaseEvidence {
                guard evidenceReservationID == reservationID,
                      evidenceWorkloadID == workloadID,
                      token.reservationSequence == fencingToken.reservationSequence,
                      token.nodeEpoch > fencingToken.nodeEpoch else {
                    throw SchedulerAdmissionError.stateInvariant("release-lineage")
                }
                if let fenceEvidence {
                    guard token.reservationSequence
                        == fenceEvidence.token.reservationSequence,
                          evidenceReservationID == fenceEvidence.reservationID,
                          evidenceWorkloadID == fenceEvidence.workloadID,
                          token.nodeEpoch >= fenceEvidence.token.nodeEpoch else {
                        throw SchedulerAdmissionError.stateInvariant(
                            "fence-release-token-mismatch"
                        )
                    }
                }
            }
        }

        return SchedulerAdmissionRecordDecodedValues(
            decisionID: decisionID,
            reservationID: reservationID,
            workloadID: workloadID,
            nodeID: nodeID,
            resources: resources,
            capacityDigest: capacityDigest,
            capacityGeneration: capacityGeneration,
            inputDigest: inputDigest,
            configDigest: configDigest,
            profileDigest: profileDigest,
            lifecyclePlanDigest: lifecyclePlanDigest,
            ownerSubjectID: ownerSubjectID,
            projectUUID: projectUUID.lowercased(),
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            expiresAt: expiresAt,
            fencingToken: fencingToken,
            fenceEvidence: fenceEvidence,
            releaseEvidence: releaseEvidence,
            runtimeOwnership: runtimeOwnership
        )
    }

    private static func validateFenceEvidence(
        _ evidence: SchedulerFenceEvidence,
        reservationID: UUID,
        workloadID: UUID,
        fencingToken: SchedulerFencingToken,
        currentDate: Date?,
        createdDate: Date
    ) throws {
        guard evidence.reservationID == reservationID,
              evidence.workloadID == workloadID,
              evidence.token.reservationSequence == fencingToken.reservationSequence,
              evidence.token.nodeEpoch > fencingToken.nodeEpoch else {
            throw SchedulerAdmissionError.stateInvariant("fence-proof-order")
        }
        let evidenceDate = try SchedulerAdmissionValidation.timestamp(
            evidence.verifiedAt,
            field: "fence-evidence-at"
        )
        guard evidenceDate >= createdDate else {
            throw SchedulerAdmissionError.stateInvariant("fence-proof-order")
        }
        if let currentDate {
            guard evidenceDate == currentDate else {
                throw SchedulerAdmissionError.stateInvariant("fence-proof-order")
            }
        }
    }

    private static func evidenceTimestamp(
        _ evidence: SchedulerReleaseEvidence
    ) -> String {
        switch evidence {
        case .verifiedRuntimeAbsence(_, let verifiedAt):
            verifiedAt
        case .authoritativeFence(_, _, _, _, let verifiedAt):
            verifiedAt
        }
    }
}

enum SchedulerAdmissionCanonicalJSON {
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw SchedulerAdmissionError.stateInvariant("canonical-encoding")
        }
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try data(value), as: UTF8.self)
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try data(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func vectorData(_ vector: ResourceVector) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try! encoder.encode(vector)
    }

    static func vectorJSON(_ vector: ResourceVector) -> String {
        String(decoding: vectorData(vector), as: UTF8.self)
    }

    static func vector(from json: String) throws -> ResourceVector {
        guard let data = json.data(using: .utf8) else {
            throw SchedulerAdmissionError.stateInvariant("resource-vector-encoding")
        }
        do {
            let vector = try JSONDecoder().decode(ResourceVector.self, from: data)
            guard vectorJSON(vector) == json else {
                throw SchedulerAdmissionError.stateInvariant("resource-vector-canonicality")
            }
            return vector
        } catch let error as SchedulerAdmissionError {
            throw error
        } catch {
            throw SchedulerAdmissionError.stateInvariant("resource-vector-shape")
        }
    }
}

public enum SchedulerHostPressurePolicyPosture: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case allowed
    case deweighted
    case blocked
}

public enum SchedulerHostPressureReasonCode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case allowed
    case hysteresisRecovery = "hysteresis-recovery"
    case hysteresisVersionMismatch = "hysteresis-version-mismatch"
    case hysteresisStateInvalid = "hysteresis-state-invalid"
    case lowPowerMode = "low-power-mode"
    case batteryPowerSource = "battery-power-source"
    case batteryLow = "battery-low"
    case diskWarning = "disk-warning"
    case diskFair = "disk-fair"
    case diskSerious = "disk-serious"
    case thermalWarning = "thermal-warning"
    case thermalFair = "thermal-fair"
    case thermalSerious = "thermal-serious"
    case memoryWarning = "memory-warning"
    case memoryFair = "memory-fair"
    case memorySerious = "memory-serious"
    case hostUnavailable = "host-unavailable"
    case thermalCritical = "thermal-critical"
    case thermalUnavailable = "thermal-unavailable"
    case memoryCritical = "memory-critical"
    case memoryUnavailable = "memory-unavailable"
    case sleeping
    case sleepUnavailable = "sleep-unavailable"
    case maintenance
    case maintenanceUnavailable = "maintenance-unavailable"
    case diskCritical = "disk-critical"
    case diskUnavailable = "disk-unavailable"
    case powerSourceUnavailable = "power-source-unavailable"
    case batteryLevelUnavailable = "battery-level-unavailable"

    fileprivate var deterministicRank: Int {
        switch self {
        case .hysteresisVersionMismatch: 0
        case .hysteresisStateInvalid: 1
        case .hysteresisRecovery: 2
        case .allowed: 3
        case .hostUnavailable: 10
        case .thermalWarning: 20
        case .thermalFair: 21
        case .thermalSerious: 22
        case .thermalCritical: 23
        case .thermalUnavailable: 24
        case .memoryWarning: 30
        case .memoryFair: 31
        case .memorySerious: 32
        case .memoryCritical: 33
        case .memoryUnavailable: 34
        case .sleeping: 40
        case .sleepUnavailable: 41
        case .maintenance: 42
        case .maintenanceUnavailable: 43
        case .diskWarning: 50
        case .diskFair: 51
        case .diskSerious: 52
        case .diskCritical: 53
        case .diskUnavailable: 54
        case .lowPowerMode: 60
        case .batteryPowerSource: 61
        case .batteryLow: 62
        case .powerSourceUnavailable: 63
        case .batteryLevelUnavailable: 64
        }
    }

    fileprivate var isDeweightingReason: Bool {
        switch self {
        case .lowPowerMode,
             .batteryPowerSource,
             .batteryLow,
             .diskWarning,
             .diskFair,
             .diskSerious,
             .thermalWarning,
             .thermalFair,
             .thermalSerious,
             .memoryWarning,
             .memoryFair,
             .memorySerious:
            true
        default:
            false
        }
    }

    fileprivate var isBlockingReason: Bool {
        switch self {
        case .hostUnavailable,
             .thermalCritical,
             .thermalUnavailable,
             .memoryCritical,
             .memoryUnavailable,
             .sleeping,
             .sleepUnavailable,
             .maintenance,
             .maintenanceUnavailable,
             .diskCritical,
             .diskUnavailable,
             .powerSourceUnavailable,
             .batteryLevelUnavailable:
            true
        default:
            false
        }
    }
}

private struct SchedulerAdmissionAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func schedulerAdmissionAllKeys(from decoder: Decoder) throws -> Set<String> {
    Set(try decoder.container(keyedBy: SchedulerAdmissionAnyCodingKey.self)
        .allKeys
        .map(\.stringValue))
}

public struct SchedulerHostPressureHysteresisState: Codable, Equatable, Hashable, Sendable {
    public static let maximumObservationCount = 1_024

    public let version: Int
    public let posture: SchedulerHostPressurePolicyPosture
    public let consecutiveClearObservations: Int

    public init(
        posture: SchedulerHostPressurePolicyPosture,
        consecutiveClearObservations: Int,
        version: Int
    ) throws {
        guard version == SchedulerHostPressurePolicyState.currentVersion else {
            throw SchedulerAdmissionError.invalidBinding(field: "pressure-policy-version")
        }
        guard (0...Self.maximumObservationCount).contains(consecutiveClearObservations) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "pressure-hysteresis-observation-count"
            )
        }
        self.version = version
        self.posture = posture
        self.consecutiveClearObservations = consecutiveClearObservations
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case posture
        case consecutiveClearObservations
    }

    public init(from decoder: Decoder) throws {
        guard try schedulerAdmissionAllKeys(from: decoder)
            == Set(CodingKeys.allCases.map(\.stringValue)) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "pressure-hysteresis-unknown-key"
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys.map(\.stringValue))
            == Set(CodingKeys.allCases.map(\.stringValue)) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "pressure-hysteresis-unknown-key"
            )
        }
        try self.init(
            posture: container.decode(
                SchedulerHostPressurePolicyPosture.self,
                forKey: .posture
            ),
            consecutiveClearObservations: container.decode(
                Int.self,
                forKey: .consecutiveClearObservations
            ),
            version: container.decode(Int.self, forKey: .version)
        )
    }
}

public struct SchedulerHostPressurePolicyState: Codable, Equatable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let maximumReasonCodeCount = 64

    public let version: Int
    public let reasonCodes: [SchedulerHostPressureReasonCode]
    public let nextHysteresisState: SchedulerHostPressureHysteresisState

    public init(
        version: Int,
        reasonCodes: [SchedulerHostPressureReasonCode],
        nextHysteresisState: SchedulerHostPressureHysteresisState
    ) throws {
        guard version == Self.currentVersion,
              nextHysteresisState.version == version else {
            throw SchedulerAdmissionError.invalidBinding(field: "pressure-policy-version")
        }
        guard (1...Self.maximumReasonCodeCount).contains(reasonCodes.count),
              reasonCodes == reasonCodes.sorted(by: {
                  $0.deterministicRank < $1.deterministicRank
              }),
              Set(reasonCodes).count == reasonCodes.count else {
            throw SchedulerAdmissionError.invalidBinding(field: "pressure-reason-codes")
        }
        self.version = version
        self.reasonCodes = reasonCodes
        self.nextHysteresisState = nextHysteresisState
    }

    public func validate(for posture: SchedulerHostPosture) throws {
        let effectivePosture: SchedulerHostPressurePolicyPosture
        switch posture.pressure {
        case .nominal:
            effectivePosture = .allowed
        case .elevated:
            effectivePosture = .deweighted
        case .critical, .unknown, .unavailable:
            effectivePosture = .blocked
        }
        let valid: Bool
        switch effectivePosture {
        case .allowed:
            valid = reasonCodes == [.allowed]
        case .deweighted:
            valid = reasonCodes == [.hysteresisRecovery]
                || reasonCodes.allSatisfy(\.isDeweightingReason)
        case .blocked:
            valid = reasonCodes == [.hysteresisRecovery]
                || reasonCodes == [.hysteresisVersionMismatch]
                || reasonCodes == [.hysteresisStateInvalid]
                || reasonCodes.allSatisfy(\.isBlockingReason)
        }
        guard valid else {
            throw SchedulerAdmissionError.invalidBinding(field: "pressure-reason-posture")
        }

        let unavailableReasons: Set<SchedulerHostPressureReasonCode> = [
            .hysteresisVersionMismatch,
            .hysteresisStateInvalid,
            .hostUnavailable,
            .thermalUnavailable,
            .memoryUnavailable,
            .sleepUnavailable,
            .maintenanceUnavailable,
            .diskUnavailable,
            .powerSourceUnavailable,
            .batteryLevelUnavailable,
        ]
        let constrainedReasons: Set<SchedulerHostPressureReasonCode> = [
            .lowPowerMode,
            .batteryPowerSource,
            .batteryLow,
        ]
        let expectedEnergy: SchedulerEnergyPosture
        if reasonCodes.contains(where: unavailableReasons.contains) {
            expectedEnergy = .unknown
        } else if reasonCodes.contains(where: constrainedReasons.contains) {
            expectedEnergy = .constrained
        } else {
            expectedEnergy = .balanced
        }
        guard posture.energy == expectedEnergy else {
            throw SchedulerAdmissionError.invalidBinding(field: "pressure-energy-posture")
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case reasonCodes
        case nextHysteresisState
    }

    public init(from decoder: Decoder) throws {
        guard try schedulerAdmissionAllKeys(from: decoder)
            == Set(CodingKeys.allCases.map(\.stringValue)) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "pressure-policy-unknown-key"
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys.map(\.stringValue))
            == Set(CodingKeys.allCases.map(\.stringValue)) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "pressure-policy-unknown-key"
            )
        }
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            reasonCodes: container.decode(
                [SchedulerHostPressureReasonCode].self,
                forKey: .reasonCodes
            ),
            nextHysteresisState: container.decode(
                SchedulerHostPressureHysteresisState.self,
                forKey: .nextHysteresisState
            )
        )
    }
}

enum SchedulerAdmissionValidation {
    static func digest(_ value: String, field: String) throws {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 97 && scalar.value <= 102)
              }) else {
            throw SchedulerAdmissionError.invalidBinding(field: field)
        }
    }

    static func subject(_ value: String) throws {
        guard (1...128).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) }) else {
            throw SchedulerAdmissionError.invalidBinding(field: "owner-subject-id")
        }
    }

    static func scopedIdentifier(
        _ value: String,
        field: String,
        maximumBytes: Int = SchedulerAdmissionStateLimits.maximumIdentifierBytes
    ) throws {
        guard (1...maximumBytes).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) }) else {
            throw SchedulerAdmissionError.invalidBinding(field: field)
        }
    }

    static func generation(_ value: Int64, field: String = "generation") throws {
        guard value >= 1 else {
            throw SchedulerAdmissionError.invalidBinding(field: field)
        }
    }

    @discardableResult
    static func timestamp(_ value: String, field: String) throws -> Date {
        do {
            return try RBACStateValidation.timestamp(value, named: field)
        } catch {
            throw SchedulerAdmissionError.invalidBinding(field: field)
        }
    }

    static func evidenceDigest(_ value: String, field: String) throws {
        try digest(value, field: field)
    }

    static func fencingToken(
        _ value: SchedulerFencingToken,
        field: String
    ) throws {
        guard value.nodeEpoch >= 1, value.reservationSequence >= 1 else {
            throw SchedulerAdmissionError.invalidEvidence(field)
        }
    }
}

public enum SchedulerAdmissionStateLimits {
    public static let maximumIdentifierBytes = 128
    public static let maximumRecordJSONBytes = 1 * 1_024 * 1_024
    public static let maximumDecisionArtifactCount = 4_096
    public static let maximumDecisionWorkloadCount = 4_096
    public static let maximumFenceEvidenceCount = 256
    public static let maximumFairnessRecordCount = 4_096
    public static let maximumDisruptionBudgetCount = 4_096
    public static let maximumPreemptionIntentCount = 4_096
    public static let maximumHostPressureRecordCount = 4_096
    public static let maximumRecoverableReservationCount = 4_096
    public static let reservationLeaseDurationSeconds: Int64 = 300
}

public enum SchedulerAdmissionStableIdentifier {
    public static func preemptionIntentID(
        decisionID: UUID,
        targetWorkloadID: UUID
    ) -> UUID {
        UUID(
            uuidString: HostwrightResourceUUID.legacy(
                kind: "scheduler-preemption-intent",
                identifier: "\(decisionID.uuidString.lowercased()):\(targetWorkloadID.uuidString.lowercased())"
            )
        )!
    }
}

/// The immutable runtime identity captured with a scheduler plan.  A missing
/// value is intentional fail-closed state: recovery may not infer a runtime
/// owner from a workload UUID alone.
public struct SchedulerRuntimeOwnershipBinding:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let resourceIdentifier: String
    public let resourceType: String
    public let resourceUUID: String
    public let resourceGeneration: Int64
    public let projectUUID: String
    public let projectName: String
    public let projectGeneration: Int64
    public let serviceName: String
    public let instanceName: String?
    public let identityVersion: Int
    public let providerID: RuntimeProviderID
    public let providerAPIVersion: Int
    public let providerVersion: String
    public let providerGeneration: Int64
    public let fencingToken: String

    public init(
        resourceIdentifier: String,
        resourceType: String,
        resourceUUID: String,
        resourceGeneration: Int64,
        projectUUID: String,
        projectName: String,
        projectGeneration: Int64,
        serviceName: String,
        instanceName: String?,
        identityVersion: Int,
        providerID: RuntimeProviderID,
        providerAPIVersion: Int,
        providerVersion: String,
        providerGeneration: Int64,
        fencingToken: String
    ) throws {
        guard RuntimeManagedResourceIdentity.isSupportedIdentifier(resourceIdentifier),
              resourceType == "container",
              HostwrightResourceUUID.isValid(resourceUUID),
              resourceGeneration >= 1,
              HostwrightResourceUUID.isValid(projectUUID),
              Self.isName(projectName),
              projectGeneration >= 1,
              Self.isName(serviceName),
              instanceName.map(Self.isName) ?? true,
              identityVersion == RuntimeManagedResourceIdentity.currentVersion,
              RuntimeProviderID.knownValues.contains(providerID),
              providerAPIVersion == HostwrightContractVersions.runtimeProviderAPI,
              !providerVersion.isEmpty,
              providerVersion.utf8.count <= 256,
              providerVersion.rangeOfCharacter(from: .controlCharacters) == nil,
              providerGeneration >= 1,
              HostwrightResourceUUID.isValid(fencingToken) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "runtime-ownership-binding"
            )
        }
        self.resourceIdentifier = resourceIdentifier
        self.resourceType = resourceType
        self.resourceUUID = resourceUUID.lowercased()
        self.resourceGeneration = resourceGeneration
        self.projectUUID = projectUUID.lowercased()
        self.projectName = projectName
        self.projectGeneration = projectGeneration
        self.serviceName = serviceName
        self.instanceName = instanceName
        self.identityVersion = identityVersion
        self.providerID = providerID
        self.providerAPIVersion = providerAPIVersion
        self.providerVersion = providerVersion
        self.providerGeneration = providerGeneration
        self.fencingToken = fencingToken.lowercased()
    }

    private static func isName(_ value: String) -> Bool {
        value.utf8.count <= RuntimeManagedResourceIdentity.maximumIdentifierLength &&
            value.range(
                of: "^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$",
                options: .regularExpression
            ) != nil
    }
}

/// Immutable apply metadata captured with a plan. Lease timestamps are not
/// plan data: the daemon derives them from its current apply snapshot.
public struct SchedulerDecisionWorkloadBinding:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let workloadID: UUID
    public let nodeID: UUID
    public let resources: ResourceVector
    public let capacityDigest: String
    public let capacityGeneration: Int64
    public let ownerSubjectID: String
    public let projectUUID: String
    public let runtimeOwnership: SchedulerRuntimeOwnershipBinding?

    public init(
        workloadID: UUID,
        nodeID: UUID,
        resources: ResourceVector,
        capacityDigest: String,
        capacityGeneration: Int64,
        ownerSubjectID: String,
        projectUUID: String,
        runtimeOwnership: SchedulerRuntimeOwnershipBinding? = nil
    ) throws {
        try SchedulerAdmissionValidation.digest(
            capacityDigest,
            field: "decision-binding-capacity-digest"
        )
        try SchedulerAdmissionValidation.generation(
            capacityGeneration,
            field: "decision-binding-capacity-generation"
        )
        try SchedulerAdmissionValidation.subject(
            ownerSubjectID
        )
        guard HostwrightResourceUUID.isValid(projectUUID) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "decision-binding-project-uuid"
            )
        }
        if let runtimeOwnership {
            guard runtimeOwnership.projectUUID == projectUUID.lowercased(),
                  runtimeOwnership.resourceUUID == workloadID.uuidString.lowercased() else {
                throw SchedulerAdmissionError.invalidBinding(
                    field: "decision-binding-runtime-ownership"
                )
            }
        }
        self.workloadID = workloadID
        self.nodeID = nodeID
        self.resources = resources
        self.capacityDigest = capacityDigest
        self.capacityGeneration = capacityGeneration
        self.ownerSubjectID = ownerSubjectID
        self.projectUUID = projectUUID.lowercased()
        self.runtimeOwnership = runtimeOwnership
    }

    private enum CodingKeys: String, CodingKey {
        case workloadID
        case nodeID
        case resources
        case capacityDigest
        case capacityGeneration
        case ownerSubjectID
        case projectUUID
        case runtimeOwnership
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            workloadID: values.decode(UUID.self, forKey: .workloadID),
            nodeID: values.decode(UUID.self, forKey: .nodeID),
            resources: values.decode(ResourceVector.self, forKey: .resources),
            capacityDigest: values.decode(String.self, forKey: .capacityDigest),
            capacityGeneration: values.decode(
                Int64.self,
                forKey: .capacityGeneration
            ),
            ownerSubjectID: values.decode(String.self, forKey: .ownerSubjectID),
            projectUUID: values.decode(String.self, forKey: .projectUUID),
            runtimeOwnership: values.decodeIfPresent(
                SchedulerRuntimeOwnershipBinding.self,
                forKey: .runtimeOwnership
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(workloadID, forKey: .workloadID)
        try values.encode(nodeID, forKey: .nodeID)
        try values.encode(resources, forKey: .resources)
        try values.encode(capacityDigest, forKey: .capacityDigest)
        try values.encode(capacityGeneration, forKey: .capacityGeneration)
        try values.encode(ownerSubjectID, forKey: .ownerSubjectID)
        try values.encode(projectUUID, forKey: .projectUUID)
        try values.encodeIfPresent(runtimeOwnership, forKey: .runtimeOwnership)
    }
}

/// The result of the repository's apply seam. A persisted plan may produce a
/// pending reservation, a proposed preemption intent, or both for a compound
/// apply transaction; callers cannot supply fence evidence to this API.
public struct SchedulerAdmissionApplyResult:
    Codable,
    Equatable,
    Sendable
{
    public let decisionID: UUID
    public let inputDigest: String
    public let reservation: SchedulerReservationRecord?
    public let preemptionIntent: SchedulerPreemptionIntentRecord?

    public init(
        decisionID: UUID,
        inputDigest: String,
        reservation: SchedulerReservationRecord?,
        preemptionIntent: SchedulerPreemptionIntentRecord?
    ) throws {
        try SchedulerAdmissionValidation.digest(
            inputDigest,
            field: "apply-input-digest"
        )
        guard reservation != nil || preemptionIntent != nil else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "apply-result-shape"
            )
        }
        if let reservation {
            guard reservation.decisionID == decisionID,
                  reservation.inputDigest == inputDigest else {
                throw SchedulerAdmissionError.stateInvariant(
                    "apply-result-reservation-binding"
                )
            }
        }
        if let preemptionIntent {
            guard preemptionIntent.decisionID == decisionID,
                  preemptionIntent.intentID == SchedulerAdmissionStableIdentifier.preemptionIntentID(
                decisionID: decisionID,
                targetWorkloadID: preemptionIntent.proposal.targetWorkloadID
            ),
                  preemptionIntent.proposal.intentDigest.count == 64 else {
                throw SchedulerAdmissionError.stateInvariant(
                    "apply-result-intent-binding"
                )
            }
        }
        self.decisionID = decisionID
        self.inputDigest = inputDigest
        self.reservation = reservation
        self.preemptionIntent = preemptionIntent
    }

    private enum CodingKeys: String, CodingKey {
        case decisionID
        case inputDigest
        case reservation
        case preemptionIntent
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            decisionID: values.decode(UUID.self, forKey: .decisionID),
            inputDigest: values.decode(String.self, forKey: .inputDigest),
            reservation: values.decodeIfPresent(
                SchedulerReservationRecord.self,
                forKey: .reservation
            ),
            preemptionIntent: values.decodeIfPresent(
                SchedulerPreemptionIntentRecord.self,
                forKey: .preemptionIntent
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(decisionID, forKey: .decisionID)
        try values.encode(inputDigest, forKey: .inputDigest)
        try values.encodeIfPresent(reservation, forKey: .reservation)
        try values.encodeIfPresent(preemptionIntent, forKey: .preemptionIntent)
    }
}

/// Daemon-owned apply observations. This is intentionally separate from the
/// wire `SchedulerAdmissionAuthority`: the control client supplies only a
/// decision ID and expected input digest; the daemon constructs this value
/// from its current state snapshots immediately before apply.
public struct SchedulerAdmissionCurrentAuthority:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let nodeCapacityDigest: String
    public let nodeCapacityGeneration: Int64
    public let configDigest: String
    public let profileDigest: String
    public let lifecyclePlanDigest: String
    public let expectedNodeEpoch: Int64
    public let expectedPressureGeneration: Int64
    public let expectedPressureEvidenceDigest: String
    public let expectedPressurePosture: SchedulerPressurePosture
    public let leaseCreatedAt: String
    public let leaseExpiresAt: String

    public init(
        nodeCapacityDigest: String,
        nodeCapacityGeneration: Int64,
        configDigest: String,
        profileDigest: String,
        lifecyclePlanDigest: String,
        expectedNodeEpoch: Int64,
        expectedPressureGeneration: Int64,
        expectedPressureEvidenceDigest: String,
        expectedPressurePosture: SchedulerPressurePosture,
        leaseCreatedAt: String,
        leaseExpiresAt: String
    ) throws {
        try SchedulerAdmissionValidation.digest(
            nodeCapacityDigest,
            field: "current-node-capacity-digest"
        )
        try SchedulerAdmissionValidation.generation(
            nodeCapacityGeneration,
            field: "current-node-capacity-generation"
        )
        try SchedulerAdmissionValidation.digest(
            configDigest,
            field: "current-config-digest"
        )
        try SchedulerAdmissionValidation.digest(
            profileDigest,
            field: "current-profile-digest"
        )
        try SchedulerAdmissionValidation.digest(
            lifecyclePlanDigest,
            field: "current-lifecycle-plan-digest"
        )
        guard expectedNodeEpoch >= 1 else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "current-expected-node-epoch"
            )
        }
        try SchedulerAdmissionValidation.generation(
            expectedPressureGeneration,
            field: "current-pressure-generation"
        )
        try SchedulerAdmissionValidation.digest(
            expectedPressureEvidenceDigest,
            field: "current-pressure-evidence-digest"
        )
        let leaseCreatedDate = try SchedulerAdmissionValidation.timestamp(
            leaseCreatedAt,
            field: "current-lease-created-at"
        )
        let leaseExpiresDate = try SchedulerAdmissionValidation.timestamp(
            leaseExpiresAt,
            field: "current-lease-expires-at"
        )
        guard leaseExpiresDate > leaseCreatedDate,
              leaseExpiresDate.timeIntervalSince(leaseCreatedDate)
                <= TimeInterval(SchedulerAdmissionStateLimits.reservationLeaseDurationSeconds) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "current-lease-duration"
            )
        }
        self.nodeCapacityDigest = nodeCapacityDigest
        self.nodeCapacityGeneration = nodeCapacityGeneration
        self.configDigest = configDigest
        self.profileDigest = profileDigest
        self.lifecyclePlanDigest = lifecyclePlanDigest
        self.expectedNodeEpoch = expectedNodeEpoch
        self.expectedPressureGeneration = expectedPressureGeneration
        self.expectedPressureEvidenceDigest = expectedPressureEvidenceDigest
        self.expectedPressurePosture = expectedPressurePosture
        self.leaseCreatedAt = leaseCreatedAt
        self.leaseExpiresAt = leaseExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case nodeCapacityDigest
        case nodeCapacityGeneration
        case configDigest
        case profileDigest
        case lifecyclePlanDigest
        case expectedNodeEpoch
        case expectedPressureGeneration
        case expectedPressureEvidenceDigest
        case expectedPressurePosture
        case leaseCreatedAt
        case leaseExpiresAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nodeCapacityDigest: values.decode(String.self, forKey: .nodeCapacityDigest),
            nodeCapacityGeneration: values.decode(
                Int64.self,
                forKey: .nodeCapacityGeneration
            ),
            configDigest: values.decode(String.self, forKey: .configDigest),
            profileDigest: values.decode(String.self, forKey: .profileDigest),
            lifecyclePlanDigest: values.decode(
                String.self,
                forKey: .lifecyclePlanDigest
            ),
            expectedNodeEpoch: values.decode(Int64.self, forKey: .expectedNodeEpoch),
            expectedPressureGeneration: values.decode(
                Int64.self,
                forKey: .expectedPressureGeneration
            ),
            expectedPressureEvidenceDigest: values.decode(
                String.self,
                forKey: .expectedPressureEvidenceDigest
            ),
            expectedPressurePosture: values.decode(
                SchedulerPressurePosture.self,
                forKey: .expectedPressurePosture
            ),
            leaseCreatedAt: values.decode(String.self, forKey: .leaseCreatedAt),
            leaseExpiresAt: values.decode(String.self, forKey: .leaseExpiresAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(nodeCapacityDigest, forKey: .nodeCapacityDigest)
        try values.encode(nodeCapacityGeneration, forKey: .nodeCapacityGeneration)
        try values.encode(configDigest, forKey: .configDigest)
        try values.encode(profileDigest, forKey: .profileDigest)
        try values.encode(lifecyclePlanDigest, forKey: .lifecyclePlanDigest)
        try values.encode(expectedNodeEpoch, forKey: .expectedNodeEpoch)
        try values.encode(expectedPressureGeneration, forKey: .expectedPressureGeneration)
        try values.encode(
            expectedPressureEvidenceDigest,
            forKey: .expectedPressureEvidenceDigest
        )
        try values.encode(expectedPressurePosture, forKey: .expectedPressurePosture)
        try values.encode(leaseCreatedAt, forKey: .leaseCreatedAt)
        try values.encode(leaseExpiresAt, forKey: .leaseExpiresAt)
    }
}

public struct SchedulerDecisionStateSnapshot:
    Codable,
    Equatable,
    Sendable
{
    public let artifact: SchedulerDecisionArtifactRecord
    public let reservations: [SchedulerReservationRecord]

    public init(
        artifact: SchedulerDecisionArtifactRecord,
        reservations: [SchedulerReservationRecord]
    ) throws {
        guard reservations.allSatisfy({ $0.decisionID == artifact.decisionID }) else {
            throw SchedulerAdmissionError.stateInvariant(
                "decision-snapshot-reservation-binding"
            )
        }
        self.artifact = artifact
        self.reservations = reservations.sorted {
            if $0.workloadID != $1.workloadID {
                return SchedulerOrdering.uuidKey($0.workloadID)
                    < SchedulerOrdering.uuidKey($1.workloadID)
            }
            return SchedulerOrdering.uuidKey($0.reservationID)
                < SchedulerOrdering.uuidKey($1.reservationID)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case artifact
        case reservations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            artifact: values.decode(
                SchedulerDecisionArtifactRecord.self,
                forKey: .artifact
            ),
            reservations: values.decode(
                [SchedulerReservationRecord].self,
                forKey: .reservations
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(artifact, forKey: .artifact)
        try values.encode(reservations, forKey: .reservations)
    }
}

public struct SchedulerProjectAuthoritySnapshot:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let projectID: String
    public let projectName: String
    public let resourceUUID: String
    public let manifestDigest: String
    public let manifestVersion: Int64
    public let updatedAt: String

    public init(
        projectID: String,
        projectName: String,
        resourceUUID: String,
        manifestDigest: String,
        manifestVersion: Int64,
        updatedAt: String
    ) throws {
        try SchedulerAdmissionValidation.scopedIdentifier(projectID, field: "project-id")
        try SchedulerAdmissionValidation.scopedIdentifier(projectName, field: "project-name")
        guard HostwrightResourceUUID.isValid(resourceUUID) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "project-resource-uuid"
            )
        }
        try SchedulerAdmissionValidation.digest(
            manifestDigest,
            field: "project-manifest-digest"
        )
        try SchedulerAdmissionValidation.generation(
            manifestVersion,
            field: "project-manifest-version"
        )
        _ = try SchedulerAdmissionValidation.timestamp(
            updatedAt,
            field: "project-updated-at"
        )
        self.projectID = projectID
        self.projectName = projectName
        self.resourceUUID = resourceUUID.lowercased()
        self.manifestDigest = manifestDigest
        self.manifestVersion = manifestVersion
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case projectName
        case resourceUUID
        case manifestDigest
        case manifestVersion
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: values.decode(String.self, forKey: .projectID),
            projectName: values.decode(String.self, forKey: .projectName),
            resourceUUID: values.decode(String.self, forKey: .resourceUUID),
            manifestDigest: values.decode(String.self, forKey: .manifestDigest),
            manifestVersion: values.decode(Int64.self, forKey: .manifestVersion),
            updatedAt: values.decode(String.self, forKey: .updatedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(projectID, forKey: .projectID)
        try values.encode(projectName, forKey: .projectName)
        try values.encode(resourceUUID, forKey: .resourceUUID)
        try values.encode(manifestDigest, forKey: .manifestDigest)
        try values.encode(manifestVersion, forKey: .manifestVersion)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct SchedulerFairnessAccountingRecord: Codable, Equatable, Hashable, Sendable {
    public let state: SchedulerFairnessState
    public let generation: Int64
    public let updatedAt: String
    public let accountingDigest: String

    public var subjectID: String { state.subjectID }
    public var projectID: String { state.projectID }

    public init(
        state: SchedulerFairnessState,
        generation: Int64,
        updatedAt: String
    ) throws {
        try SchedulerAdmissionValidation.scopedIdentifier(
            state.subjectID,
            field: "fairness-subject-id"
        )
        try SchedulerAdmissionValidation.scopedIdentifier(
            state.projectID,
            field: "fairness-project-id"
        )
        try SchedulerAdmissionValidation.generation(generation)
        _ = try SchedulerAdmissionValidation.timestamp(
            updatedAt,
            field: "fairness-updated-at"
        )
        self.state = state
        self.generation = generation
        self.updatedAt = updatedAt
        self.accountingDigest = try Self.digest(
            state: state,
            generation: generation,
            updatedAt: updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case generation
        case updatedAt
        case accountingDigest
    }

    private struct DigestPayload: Codable {
        let state: SchedulerFairnessState
        let generation: Int64
        let updatedAt: String
    }

    private static func digest(
        state: SchedulerFairnessState,
        generation: Int64,
        updatedAt: String
    ) throws -> String {
        try SchedulerAdmissionCanonicalJSON.digest(
            DigestPayload(state: state, generation: generation, updatedAt: updatedAt)
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let state = try values.decode(SchedulerFairnessState.self, forKey: .state)
        let generation = try values.decode(Int64.self, forKey: .generation)
        let updatedAt = try values.decode(String.self, forKey: .updatedAt)
        let digest = try values.decode(String.self, forKey: .accountingDigest)
        let expected = try Self(
            state: state,
            generation: generation,
            updatedAt: updatedAt
        ).accountingDigest
        guard digest == expected else {
            throw SchedulerAdmissionError.invalidBinding(field: "fairness-accounting-digest")
        }
        self.state = state
        self.generation = generation
        self.updatedAt = updatedAt
        self.accountingDigest = digest
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state, forKey: .state)
        try values.encode(generation, forKey: .generation)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(accountingDigest, forKey: .accountingDigest)
    }
}

public struct SchedulerDisruptionBudgetRecord: Codable, Equatable, Hashable, Sendable {
    public let budget: SchedulerDisruptionBudget
    public let generation: Int64
    public let updatedAt: String
    public let budgetDigest: String

    public var budgetID: String { budget.budgetID }
    public var projectID: String { budget.projectID }

    public init(
        budget: SchedulerDisruptionBudget,
        generation: Int64,
        updatedAt: String
    ) throws {
        try SchedulerAdmissionValidation.scopedIdentifier(
            budget.budgetID,
            field: "disruption-budget-id"
        )
        try SchedulerAdmissionValidation.scopedIdentifier(
            budget.projectID,
            field: "disruption-budget-project-id"
        )
        try SchedulerAdmissionValidation.generation(generation)
        _ = try SchedulerAdmissionValidation.timestamp(
            updatedAt,
            field: "disruption-budget-updated-at"
        )
        self.budget = budget
        self.generation = generation
        self.updatedAt = updatedAt
        self.budgetDigest = try Self.digest(
            budget: budget,
            generation: generation,
            updatedAt: updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case budget
        case generation
        case updatedAt
        case budgetDigest
    }

    private struct DigestPayload: Codable {
        let budget: SchedulerDisruptionBudget
        let generation: Int64
        let updatedAt: String
    }

    private static func digest(
        budget: SchedulerDisruptionBudget,
        generation: Int64,
        updatedAt: String
    ) throws -> String {
        try SchedulerAdmissionCanonicalJSON.digest(
            DigestPayload(budget: budget, generation: generation, updatedAt: updatedAt)
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let budget = try values.decode(SchedulerDisruptionBudget.self, forKey: .budget)
        let generation = try values.decode(Int64.self, forKey: .generation)
        let updatedAt = try values.decode(String.self, forKey: .updatedAt)
        let digest = try values.decode(String.self, forKey: .budgetDigest)
        let expected = try Self(
            budget: budget,
            generation: generation,
            updatedAt: updatedAt
        ).budgetDigest
        guard digest == expected else {
            throw SchedulerAdmissionError.invalidBinding(field: "disruption-budget-digest")
        }
        self.budget = budget
        self.generation = generation
        self.updatedAt = updatedAt
        self.budgetDigest = digest
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(budget, forKey: .budget)
        try values.encode(generation, forKey: .generation)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(budgetDigest, forKey: .budgetDigest)
    }
}

public enum SchedulerPreemptionIntentStatus: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case proposed
    case fencePending = "fence-pending"
    case fenced
    case applied
    case recovered
    case rejected

    public func canTransition(to next: Self) -> Bool {
        if self == next { return true }
        switch (self, next) {
        case (.proposed, .fencePending), (.proposed, .rejected):
            return true
        case (.fencePending, .fenced), (.fencePending, .rejected), (.fencePending, .recovered):
            return true
        case (.fenced, .applied), (.fenced, .recovered), (.fenced, .rejected):
            return true
        case (.applied, .recovered):
            return true
        default:
            return false
        }
    }
}

public struct SchedulerPreemptionIntentRecord: Codable, Equatable, Hashable, Sendable {
    public let decisionID: UUID
    public let intentID: UUID
    public let proposal: SchedulerPreemptionProposal
    public let status: SchedulerPreemptionIntentStatus
    public let createdAt: String
    public let updatedAt: String
    public let recordDigest: String

    public var projectID: String { proposal.projectID }

    public init(
        decisionID: UUID,
        intentID: UUID,
        proposal: SchedulerPreemptionProposal,
        status: SchedulerPreemptionIntentStatus = .proposed,
        createdAt: String,
        updatedAt: String
    ) throws {
        guard !proposal.victims.isEmpty else {
            throw SchedulerAdmissionError.invalidBinding(field: "preemption-victims")
        }
        guard intentID == SchedulerAdmissionStableIdentifier.preemptionIntentID(
            decisionID: decisionID,
            targetWorkloadID: proposal.targetWorkloadID
        ) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "preemption-intent-lineage"
            )
        }
        try SchedulerAdmissionValidation.scopedIdentifier(
            proposal.projectID,
            field: "preemption-project-id"
        )
        guard proposal.victims.allSatisfy({ $0.projectID == proposal.projectID }) else {
            throw SchedulerAdmissionError.invalidBinding(field: "preemption-project-scope")
        }
        let createdDate = try SchedulerAdmissionValidation.timestamp(
            createdAt,
            field: "preemption-created-at"
        )
        let updatedDate = try SchedulerAdmissionValidation.timestamp(
            updatedAt,
            field: "preemption-updated-at"
        )
        guard updatedDate >= createdDate else {
            throw SchedulerAdmissionError.invalidBinding(field: "preemption-time-order")
        }
        self.decisionID = decisionID
        self.intentID = intentID
        self.proposal = proposal
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recordDigest = try Self.digest(
            decisionID: decisionID,
            intentID: intentID,
            proposal: proposal,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case decisionID
        case intentID
        case proposal
        case status
        case createdAt
        case updatedAt
        case recordDigest
    }

    private struct DigestPayload: Codable {
        let decisionID: UUID
        let intentID: UUID
        let proposal: SchedulerPreemptionProposal
        let status: SchedulerPreemptionIntentStatus
        let createdAt: String
        let updatedAt: String
    }

    private static func digest(
        decisionID: UUID,
        intentID: UUID,
        proposal: SchedulerPreemptionProposal,
        status: SchedulerPreemptionIntentStatus,
        createdAt: String,
        updatedAt: String
    ) throws -> String {
        try SchedulerAdmissionCanonicalJSON.digest(
            DigestPayload(
                decisionID: decisionID,
                intentID: intentID,
                proposal: proposal,
                status: status,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decisionID = try values.decode(UUID.self, forKey: .decisionID)
        let intentID = try values.decode(UUID.self, forKey: .intentID)
        let proposal = try values.decode(SchedulerPreemptionProposal.self, forKey: .proposal)
        let status = try values.decode(SchedulerPreemptionIntentStatus.self, forKey: .status)
        let createdAt = try values.decode(String.self, forKey: .createdAt)
        let updatedAt = try values.decode(String.self, forKey: .updatedAt)
        let digest = try values.decode(String.self, forKey: .recordDigest)
        let expected = try Self(
            decisionID: decisionID,
            intentID: intentID,
            proposal: proposal,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        ).recordDigest
        guard digest == expected else {
            throw SchedulerAdmissionError.invalidBinding(field: "preemption-record-digest")
        }
        self.decisionID = decisionID
        self.intentID = intentID
        self.proposal = proposal
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recordDigest = digest
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(decisionID, forKey: .decisionID)
        try values.encode(intentID, forKey: .intentID)
        try values.encode(proposal, forKey: .proposal)
        try values.encode(status, forKey: .status)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(recordDigest, forKey: .recordDigest)
    }
}

/// A repository-validated, bounded join used by startup recovery. The
/// coordinator must consume this lineage record rather than rediscovering
/// victims by workload ID.
public struct SchedulerPreemptionRecoveryRecord: Equatable, Sendable {
    public let intent: SchedulerPreemptionIntentRecord
    public let artifact: SchedulerDecisionArtifactRecord
    public let targetBinding: SchedulerDecisionWorkloadBinding
    public let targetReservation: SchedulerReservationRecord?
    public let victimReservations: [SchedulerReservationRecord]

    init(
        intent: SchedulerPreemptionIntentRecord,
        artifact: SchedulerDecisionArtifactRecord,
        targetBinding: SchedulerDecisionWorkloadBinding,
        targetReservation: SchedulerReservationRecord?,
        victimReservations: [SchedulerReservationRecord]
    ) {
        self.intent = intent
        self.artifact = artifact
        self.targetBinding = targetBinding
        self.targetReservation = targetReservation
        self.victimReservations = victimReservations
    }
}

public struct SchedulerHostPressureRecord: Codable, Equatable, Hashable, Sendable {
    public let nodeID: UUID
    public let posture: SchedulerHostPosture
    public let generation: Int64
    public let observedAt: String
    public let evidenceDigest: String
    public let policyState: SchedulerHostPressurePolicyState
    public let recordDigest: String

    public init(
        nodeID: UUID,
        posture: SchedulerHostPosture,
        generation: Int64,
        observedAt: String,
        evidenceDigest: String,
        policyState: SchedulerHostPressurePolicyState
    ) throws {
        try SchedulerAdmissionValidation.generation(generation, field: "pressure-generation")
        _ = try SchedulerAdmissionValidation.timestamp(
            observedAt,
            field: "pressure-observed-at"
        )
        try SchedulerAdmissionValidation.evidenceDigest(
            evidenceDigest,
            field: "pressure-evidence-digest"
        )
        try policyState.validate(for: posture)
        self.nodeID = nodeID
        self.posture = posture
        self.generation = generation
        self.observedAt = observedAt
        self.evidenceDigest = evidenceDigest
        self.policyState = policyState
        self.recordDigest = try Self.digest(
            nodeID: nodeID,
            posture: posture,
            generation: generation,
            observedAt: observedAt,
            evidenceDigest: evidenceDigest,
            policyState: policyState
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case nodeID
        case posture
        case generation
        case observedAt
        case evidenceDigest
        case policyState
        case recordDigest
    }

    private struct DigestPayload: Codable {
        let nodeID: UUID
        let posture: SchedulerHostPosture
        let generation: Int64
        let observedAt: String
        let evidenceDigest: String
        let policyState: SchedulerHostPressurePolicyState
    }

    private static func digest(
        nodeID: UUID,
        posture: SchedulerHostPosture,
        generation: Int64,
        observedAt: String,
        evidenceDigest: String,
        policyState: SchedulerHostPressurePolicyState
    ) throws -> String {
        try SchedulerAdmissionCanonicalJSON.digest(
            DigestPayload(
                nodeID: nodeID,
                posture: posture,
                generation: generation,
                observedAt: observedAt,
                evidenceDigest: evidenceDigest,
                policyState: policyState
            )
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(values.allKeys.map(\.stringValue))
            == Set(CodingKeys.allCases.map(\.stringValue)) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "pressure-record-unknown-key"
            )
        }
        let nodeID = try values.decode(UUID.self, forKey: .nodeID)
        let posture = try values.decode(SchedulerHostPosture.self, forKey: .posture)
        let generation = try values.decode(Int64.self, forKey: .generation)
        let observedAt = try values.decode(String.self, forKey: .observedAt)
        let evidenceDigest = try values.decode(String.self, forKey: .evidenceDigest)
        let policyState = try values.decode(
            SchedulerHostPressurePolicyState.self,
            forKey: .policyState
        )
        let digest = try values.decode(String.self, forKey: .recordDigest)
        let expected = try Self(
            nodeID: nodeID,
            posture: posture,
            generation: generation,
            observedAt: observedAt,
            evidenceDigest: evidenceDigest,
            policyState: policyState
        ).recordDigest
        guard digest == expected else {
            throw SchedulerAdmissionError.invalidBinding(field: "pressure-record-digest")
        }
        self.nodeID = nodeID
        self.posture = posture
        self.generation = generation
        self.observedAt = observedAt
        self.evidenceDigest = evidenceDigest
        self.policyState = policyState
        self.recordDigest = digest
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(nodeID, forKey: .nodeID)
        try values.encode(posture, forKey: .posture)
        try values.encode(generation, forKey: .generation)
        try values.encode(observedAt, forKey: .observedAt)
        try values.encode(evidenceDigest, forKey: .evidenceDigest)
        try values.encode(policyState, forKey: .policyState)
        try values.encode(recordDigest, forKey: .recordDigest)
    }
}

/// The durable, immutable plan artifact. A decision may contain many workload
/// outcomes, while reservations are created later for individual outcomes.
public struct SchedulerDecisionArtifactRecord: Codable, Equatable, Hashable, Sendable {
    public let decision: SchedulerDecision
    public let workloadBindings: [SchedulerDecisionWorkloadBinding]
    public let projectUUID: String
    public let configDigest: String
    public let profileDigest: String
    public let lifecyclePlanDigest: String
    public let createdAt: String
    public let updatedAt: String
    public let artifactDigest: String

    public var decisionID: UUID { decision.decisionID }
    public var inputDigest: String { decision.inputDigest }
    public var workloadIDs: [UUID] { decision.orderedWorkloadIDs }

    public func binding(for workloadID: UUID) -> SchedulerDecisionWorkloadBinding? {
        workloadBindings.first { $0.workloadID == workloadID }
    }

    public init(
        decision: SchedulerDecision,
        workloadBindings: [SchedulerDecisionWorkloadBinding],
        projectUUID: String,
        configDigest: String,
        profileDigest: String,
        lifecyclePlanDigest: String,
        createdAt: String,
        updatedAt: String
    ) throws {
        guard HostwrightResourceUUID.isValid(projectUUID) else {
            throw SchedulerAdmissionError.invalidBinding(field: "decision-project-uuid")
        }
        guard decision.orderedWorkloadIDs.count <=
                SchedulerAdmissionStateLimits.maximumDecisionWorkloadCount else {
            throw SchedulerAdmissionError.invalidBinding(field: "decision-workload-count")
        }
        guard Set(workloadBindings.map(\.workloadID)).count == workloadBindings.count,
              workloadBindings.count <= SchedulerAdmissionStateLimits.maximumDecisionWorkloadCount else {
            throw SchedulerAdmissionError.invalidBinding(field: "decision-binding-count")
        }
        let expectedBindingIDs = Set(
            decision.workloadDecisions.compactMap { workloadDecision -> UUID? in
                switch workloadDecision.outcome {
                case .placed, .retainedExistingPlacement, .preemptionProposed:
                    return workloadDecision.workloadID
                case .unschedulable:
                    return nil
                }
            }
        )
        guard Set(workloadBindings.map(\.workloadID)) == expectedBindingIDs else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "decision-binding-workloads"
            )
        }
        guard workloadBindings.allSatisfy({ $0.projectUUID == projectUUID.lowercased() }) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "decision-binding-project-scope"
            )
        }
        for workloadBinding in workloadBindings {
            guard let workloadDecision = decision.workloadDecisions.first(
                where: { $0.workloadID == workloadBinding.workloadID }
            ) else {
                throw SchedulerAdmissionError.invalidBinding(
                    field: "decision-binding-workload"
                )
            }
            switch workloadDecision.outcome {
            case .placed, .retainedExistingPlacement:
                guard workloadDecision.chosenNodeID == workloadBinding.nodeID else {
                    throw SchedulerAdmissionError.invalidBinding(
                        field: "decision-binding-node"
                    )
                }
            case .preemptionProposed:
                guard workloadDecision.preemption?.nodeID == workloadBinding.nodeID else {
                    throw SchedulerAdmissionError.invalidBinding(
                        field: "decision-binding-preemption-node"
                    )
                }
            case .unschedulable:
                throw SchedulerAdmissionError.invalidBinding(
                    field: "decision-binding-unschedulable"
                )
            }
        }
        try SchedulerAdmissionValidation.digest(configDigest, field: "decision-config-digest")
        try SchedulerAdmissionValidation.digest(profileDigest, field: "decision-profile-digest")
        try SchedulerAdmissionValidation.digest(
            lifecyclePlanDigest,
            field: "decision-lifecycle-plan-digest"
        )
        let createdDate = try SchedulerAdmissionValidation.timestamp(
            createdAt,
            field: "decision-created-at"
        )
        let updatedDate = try SchedulerAdmissionValidation.timestamp(
            updatedAt,
            field: "decision-updated-at"
        )
        guard updatedDate >= createdDate else {
            throw SchedulerAdmissionError.invalidBinding(field: "decision-time-order")
        }

        self.decision = decision
        self.workloadBindings = workloadBindings.sorted {
            SchedulerOrdering.uuidKey($0.workloadID) < SchedulerOrdering.uuidKey($1.workloadID)
        }
        self.projectUUID = projectUUID.lowercased()
        self.configDigest = configDigest
        self.profileDigest = profileDigest
        self.lifecyclePlanDigest = lifecyclePlanDigest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.artifactDigest = try Self.digest(
            decision: decision,
            workloadBindings: self.workloadBindings,
            projectUUID: projectUUID.lowercased(),
            configDigest: configDigest,
            profileDigest: profileDigest,
            lifecyclePlanDigest: lifecyclePlanDigest,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case decision
        case workloadBindings
        case projectUUID
        case configDigest
        case profileDigest
        case lifecyclePlanDigest
        case createdAt
        case updatedAt
        case artifactDigest
    }

    private struct DigestPayload: Codable {
        let decision: SchedulerDecision
        let workloadBindings: [SchedulerDecisionWorkloadBinding]
        let projectUUID: String
        let configDigest: String
        let profileDigest: String
        let lifecyclePlanDigest: String
        let createdAt: String
        let updatedAt: String
    }

    private static func digest(
        decision: SchedulerDecision,
        workloadBindings: [SchedulerDecisionWorkloadBinding],
        projectUUID: String,
        configDigest: String,
        profileDigest: String,
        lifecyclePlanDigest: String,
        createdAt: String,
        updatedAt: String
    ) throws -> String {
        try SchedulerAdmissionCanonicalJSON.digest(
            DigestPayload(
                decision: decision,
                workloadBindings: workloadBindings,
                projectUUID: projectUUID,
                configDigest: configDigest,
                profileDigest: profileDigest,
                lifecyclePlanDigest: lifecyclePlanDigest,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decision = try values.decode(SchedulerDecision.self, forKey: .decision)
        let workloadBindings = try values.decode(
            [SchedulerDecisionWorkloadBinding].self,
            forKey: .workloadBindings
        )
        let projectUUID = try values.decode(String.self, forKey: .projectUUID)
        let configDigest = try values.decode(String.self, forKey: .configDigest)
        let profileDigest = try values.decode(String.self, forKey: .profileDigest)
        let lifecyclePlanDigest = try values.decode(String.self, forKey: .lifecyclePlanDigest)
        let createdAt = try values.decode(String.self, forKey: .createdAt)
        let updatedAt = try values.decode(String.self, forKey: .updatedAt)
        let artifactDigest = try values.decode(String.self, forKey: .artifactDigest)
        let expected = try Self(
            decision: decision,
            workloadBindings: workloadBindings,
            projectUUID: projectUUID,
            configDigest: configDigest,
            profileDigest: profileDigest,
            lifecyclePlanDigest: lifecyclePlanDigest,
            createdAt: createdAt,
            updatedAt: updatedAt
        ).artifactDigest
        guard artifactDigest == expected else {
            throw SchedulerAdmissionError.invalidBinding(field: "decision-artifact-digest")
        }
        self.decision = decision
        self.workloadBindings = workloadBindings.sorted {
            SchedulerOrdering.uuidKey($0.workloadID) < SchedulerOrdering.uuidKey($1.workloadID)
        }
        self.projectUUID = projectUUID.lowercased()
        self.configDigest = configDigest
        self.profileDigest = profileDigest
        self.lifecyclePlanDigest = lifecyclePlanDigest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.artifactDigest = artifactDigest
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(decision, forKey: .decision)
        try values.encode(workloadBindings, forKey: .workloadBindings)
        try values.encode(projectUUID, forKey: .projectUUID)
        try values.encode(configDigest, forKey: .configDigest)
        try values.encode(profileDigest, forKey: .profileDigest)
        try values.encode(lifecyclePlanDigest, forKey: .lifecyclePlanDigest)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(artifactDigest, forKey: .artifactDigest)
    }
}
