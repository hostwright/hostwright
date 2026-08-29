import CryptoKit
import Foundation
import HostwrightControlPlane

public enum ClusterRemoteOperationAdmissionError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidOperationID
    case invalidDigest
    case invalidRevision
    case invalidGeneration
    case invalidDeadline
    case wirePayloadOutOfBounds(actualBytes: Int)
    case noncanonicalWireEncoding
}

public enum ClusterRemoteOperationContract {
    public static let schemaVersion = 1
    public static let maximumOperationIDBytes = 128
    public static let maximumWireBytes = 4_096
}

/// The bounded operation classes whose immutable authority can be admitted by this source seam.
/// This enum does not imply that any transport or executor exists.
public enum ClusterRemoteOperationKind: String, Codable, CaseIterable, Sendable {
    case exec
    case attach
    case logs
    case copy
    case stats
    case diagnostics
    case recovery
}

/// A redacted operation intent. Raw commands, paths, environment, credentials, stdin, output,
/// and file bytes are deliberately excluded; callers bind those bytes only by SHA-256.
public struct ClusterRemoteOperationIntent: Equatable, Hashable, Sendable {
    public let operationID: String
    public let projectID: ClusterReplicatedProjectID
    public let targetNodeID: ClusterNodeID
    public let desiredRevision: UInt64
    public let desiredGeneration: UInt64
    public let kind: ClusterRemoteOperationKind
    public let payloadSHA256: String
    public let deadlineAtMilliseconds: UInt64

    public var schemaVersion: Int { ClusterRemoteOperationContract.schemaVersion }

    public init(
        operationID: String,
        projectID: ClusterReplicatedProjectID,
        targetNodeID: ClusterNodeID,
        desiredRevision: UInt64,
        desiredGeneration: UInt64,
        kind: ClusterRemoteOperationKind,
        payloadSHA256: String,
        deadlineAtMilliseconds: UInt64
    ) throws {
        guard ClusterRemoteOperationValidation.isOperationID(operationID) else {
            throw ClusterRemoteOperationAdmissionError.invalidOperationID
        }
        guard desiredRevision > 0 else {
            throw ClusterRemoteOperationAdmissionError.invalidRevision
        }
        guard desiredGeneration > 0 else {
            throw ClusterRemoteOperationAdmissionError.invalidGeneration
        }
        guard ClusterRemoteOperationValidation.isSHA256(payloadSHA256) else {
            throw ClusterRemoteOperationAdmissionError.invalidDigest
        }
        guard deadlineAtMilliseconds > 0,
              deadlineAtMilliseconds <= UInt64(Int64.max) else {
            throw ClusterRemoteOperationAdmissionError.invalidDeadline
        }
        self.operationID = operationID
        self.projectID = projectID
        self.targetNodeID = targetNodeID
        self.desiredRevision = desiredRevision
        self.desiredGeneration = desiredGeneration
        self.kind = kind
        self.payloadSHA256 = payloadSHA256
        self.deadlineAtMilliseconds = deadlineAtMilliseconds
    }

    public func canonicalJSON() throws -> Data {
        try ClusterRemoteOperationIntentWireContract.encode(self)
    }

    public func canonicalSHA256() throws -> String {
        ClusterRemoteOperationValidation.sha256(try canonicalJSON())
    }
}

public enum ClusterRemoteOperationPayloadDisclosure: String, Codable, Sendable {
    case sha256Only = "sha256-only"
}

/// The immutable output of pure admission. It is neither a dispatch request nor evidence that
/// a node received, executed, persisted, retried, resumed, cancelled, or observed an operation.
public struct ClusterRemoteOperationAdmissionRecord: Equatable, Sendable {
    public let intent: ClusterRemoteOperationIntent
    public let clusterID: ClusterID
    public let targetNodeID: ClusterNodeID
    public let membershipEpoch: ClusterMembershipEpoch
    public let fencingToken: UInt64
    public let sessionHandoffSHA256: String
    public let desiredStateSHA256: String
    public let mutationProofSHA256: String
    public let payloadDisclosure: ClusterRemoteOperationPayloadDisclosure

    public var executesOperation: Bool { false }
    public var provesRemoteDelivery: Bool { false }
}

public enum ClusterRemoteOperationAdmissionRejection: Equatable, Sendable {
    case invalidInput
    case sessionNotYetValid
    case sessionExpired
    case deadlineExpired
    case deadlineExceedsSession
    case clusterMismatch
    case targetNodeMismatch
    case membershipEpochMismatch
    case fencingTokenMismatch
    case projectMismatch
    case desiredRevisionMismatch
    case desiredGenerationMismatch
    case desiredStateFromFuture
    case operationIDMismatch
    case operationDigestMismatch
    case mutationFenceRejected
}

public enum ClusterRemoteOperationAdmissionDecision: Equatable, Sendable {
    case accepted(ClusterRemoteOperationAdmissionRecord)
    case rejected(ClusterRemoteOperationAdmissionRejection)
}

/// Pure classification over caller-supplied immutable records. Acceptance is local agreement
/// only; it does not authorize a network peer or perform any runtime effect.
public struct ClusterRemoteOperationAdmissionEvaluator: Sendable {
    public init() {}

    public func evaluate(
        intent: ClusterRemoteOperationIntent,
        sessionHandoff: ClusterSessionHandoff,
        desiredState: ClusterReplicatedDesiredState,
        mutationProof: ClusterMutationProof,
        nowMilliseconds: UInt64
    ) -> ClusterRemoteOperationAdmissionDecision {
        guard (try? sessionHandoff.validate()) != nil,
              (try? intent.canonicalJSON()) != nil,
              (try? desiredState.canonicalJSON()) != nil,
              (try? mutationProof.canonicalJSON()) != nil,
              nowMilliseconds <= UInt64(Int64.max) else {
            return .rejected(.invalidInput)
        }
        guard nowMilliseconds >= sessionHandoff.issuedAtMilliseconds else {
            return .rejected(.sessionNotYetValid)
        }
        guard nowMilliseconds < sessionHandoff.expiresAtMilliseconds else {
            return .rejected(.sessionExpired)
        }
        guard intent.deadlineAtMilliseconds > nowMilliseconds else {
            return .rejected(.deadlineExpired)
        }
        guard intent.deadlineAtMilliseconds <= sessionHandoff.expiresAtMilliseconds else {
            return .rejected(.deadlineExceedsSession)
        }
        guard sessionHandoff.clusterID == desiredState.clusterID else {
            return .rejected(.clusterMismatch)
        }
        guard intent.targetNodeID == sessionHandoff.nodeID else {
            return .rejected(.targetNodeMismatch)
        }
        guard sessionHandoff.membershipEpoch == desiredState.membershipEpoch else {
            return .rejected(.membershipEpochMismatch)
        }
        guard sessionHandoff.fencingToken == desiredState.fencingToken else {
            return .rejected(.fencingTokenMismatch)
        }
        guard intent.projectID == desiredState.projectID else {
            return .rejected(.projectMismatch)
        }
        guard intent.desiredRevision == desiredState.revision else {
            return .rejected(.desiredRevisionMismatch)
        }
        guard intent.desiredGeneration == desiredState.desiredGeneration else {
            return .rejected(.desiredGenerationMismatch)
        }
        guard desiredState.publishedAtMilliseconds <= nowMilliseconds else {
            return .rejected(.desiredStateFromFuture)
        }
        guard mutationProof.mutationID == intent.operationID else {
            return .rejected(.operationIDMismatch)
        }
        guard mutationProof.mutationSHA256 == (try? intent.canonicalSHA256()) else {
            return .rejected(.operationDigestMismatch)
        }

        guard let authority = try? ClusterMutationAuthoritySnapshot(
            replicatedDesiredState: desiredState
        ), let sourceRecord = try? ClusterMutationSourceRecordBinding(
            replicatedDesiredState: desiredState
        ) else {
            return .rejected(.mutationFenceRejected)
        }
        let fenceDecision = ClusterMutationFenceEvaluator().evaluate(
            current: nil,
            proposed: mutationProof,
            expectedAuthority: authority,
            expectedSourceRecord: sourceRecord
        )
        guard case .accepted = fenceDecision else {
            return .rejected(.mutationFenceRejected)
        }

        guard let handoffSHA256 = try? ClusterRemoteOperationValidation.sha256(
            sessionHandoff.canonicalData()
        ), let desiredSHA256 = try? desiredState.canonicalSHA256(),
              let proofSHA256 = try? mutationProof.canonicalSHA256() else {
            return .rejected(.invalidInput)
        }
        return .accepted(
            ClusterRemoteOperationAdmissionRecord(
                intent: intent,
                clusterID: desiredState.clusterID,
                targetNodeID: sessionHandoff.nodeID,
                membershipEpoch: desiredState.membershipEpoch,
                fencingToken: desiredState.fencingToken,
                sessionHandoffSHA256: handoffSHA256,
                desiredStateSHA256: desiredSHA256,
                mutationProofSHA256: proofSHA256,
                payloadDisclosure: .sha256Only
            )
        )
    }
}

/// Strict canonical JSON entry point. The public intent deliberately has no direct Decodable
/// conformance so untrusted bytes cannot bypass this closed, duplicate-key-safe contract.
public enum ClusterRemoteOperationIntentWireContract {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "operationID", "projectID", "targetNodeID",
        "desiredRevision", "desiredGeneration", "kind", "payloadSHA256",
        "deadlineAtMilliseconds",
    ]

    public static func encode(_ intent: ClusterRemoteOperationIntent) throws -> Data {
        let data = try ControlPlaneCanonicalJSON.encode(
            ClusterRemoteOperationIntentWire(intent)
        )
        return try bounded(data)
    }

    public static func decode(_ data: Data) throws -> ClusterRemoteOperationIntent {
        let boundedData = try bounded(data)
        let wire = try Phase09StrictDecoder.decode(
            ClusterRemoteOperationIntentWire.self,
            from: boundedData,
            allowedKeys: allowedKeys,
            requiredKeys: allowedKeys
        )
        let intent = try wire.intent()
        guard try encode(intent) == boundedData else {
            throw ClusterRemoteOperationAdmissionError.noncanonicalWireEncoding
        }
        return intent
    }

    private static func bounded(_ data: Data) throws -> Data {
        guard !data.isEmpty,
              data.count <= ClusterRemoteOperationContract.maximumWireBytes else {
            throw ClusterRemoteOperationAdmissionError.wirePayloadOutOfBounds(
                actualBytes: data.count
            )
        }
        return data
    }
}

private struct ClusterRemoteOperationIntentWire: Codable {
    let schemaVersion: Int
    let operationID: String
    let projectID: ClusterReplicatedProjectID
    let targetNodeID: ClusterNodeID
    let desiredRevision: UInt64
    let desiredGeneration: UInt64
    let kind: ClusterRemoteOperationKind
    let payloadSHA256: String
    let deadlineAtMilliseconds: UInt64

    init(_ intent: ClusterRemoteOperationIntent) {
        schemaVersion = intent.schemaVersion
        operationID = intent.operationID
        projectID = intent.projectID
        targetNodeID = intent.targetNodeID
        desiredRevision = intent.desiredRevision
        desiredGeneration = intent.desiredGeneration
        kind = intent.kind
        payloadSHA256 = intent.payloadSHA256
        deadlineAtMilliseconds = intent.deadlineAtMilliseconds
    }

    func intent() throws -> ClusterRemoteOperationIntent {
        guard schemaVersion == ClusterRemoteOperationContract.schemaVersion else {
            throw ClusterRemoteOperationAdmissionError.unsupportedSchemaVersion(schemaVersion)
        }
        return try ClusterRemoteOperationIntent(
            operationID: operationID,
            projectID: projectID,
            targetNodeID: targetNodeID,
            desiredRevision: desiredRevision,
            desiredGeneration: desiredGeneration,
            kind: kind,
            payloadSHA256: payloadSHA256,
            deadlineAtMilliseconds: deadlineAtMilliseconds
        )
    }
}

private enum ClusterRemoteOperationValidation {
    static func isOperationID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...ClusterRemoteOperationContract.maximumOperationIDBytes)
            .contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45 || byte == 46 || byte == 95
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
}
