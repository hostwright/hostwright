import CryptoKit
import Foundation
import HostwrightControlPlane

public enum ClusterSessionError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidIdentifier(String)
    case invalidCredentialMaterial
    case duplicateCredential
    case credentialNotFound
    case credentialRevoked
    case credentialGenerationAuthorityUnavailable
    case challengeCapacityExceeded
    case invalidChallenge(String)
    case challengeNotIssued
    case challengeConsumed
    case challengeMismatch
    case challengeExpired
    case challengeNotYetValid
    case challengeContextMismatch
    case credentialIDMismatch
    case credentialProofMalformed
    case credentialProofRejected
    case sessionNotFound
    case sessionBindingMismatch
    case handoffBindingMismatch
    case sessionNotYetValid
    case sessionExpired
    case sessionClosed
    case sessionFenced
    case sessionIdentityMismatch
    case membershipEpochMismatch(expected: ClusterMembershipEpoch, actual: ClusterMembershipEpoch)
    case membershipEpochRegression
    case fenceMismatch
    case fenceOverflow
    case timestampOverflow
    case invalidLifetime

    public var description: String {
        switch self {
        case .invalidIdentifier(let field): "Cluster session identifier is invalid: \(field)."
        case .invalidCredentialMaterial: "Cluster session credential material is invalid."
        case .duplicateCredential: "Cluster session credential is duplicated."
        case .credentialNotFound: "Cluster session credential is unavailable."
        case .credentialRevoked: "Cluster session credential is revoked."
        case .credentialGenerationAuthorityUnavailable:
            "Cluster session certificate-generation authority is unavailable."
        case .challengeCapacityExceeded: "Cluster session challenge capacity is exhausted."
        case .invalidChallenge(let field): "Cluster session challenge is invalid: \(field)."
        case .challengeNotIssued: "Cluster session challenge was not issued by this authority."
        case .challengeConsumed: "Cluster session challenge has already been consumed."
        case .challengeMismatch: "Cluster session challenge does not match its issued record."
        case .challengeExpired: "Cluster session challenge has expired."
        case .challengeNotYetValid: "Cluster session challenge is not yet valid."
        case .challengeContextMismatch: "Cluster session challenge is bound to another cluster context."
        case .credentialIDMismatch: "Cluster session proof credential does not match the challenge."
        case .credentialProofMalformed: "Cluster session credential proof is malformed."
        case .credentialProofRejected: "Cluster session credential proof was rejected."
        case .sessionNotFound: "Cluster session is unknown to this authority."
        case .sessionBindingMismatch: "Cluster session binding does not match the authority record."
        case .handoffBindingMismatch: "Cluster session handoff does not match the authority record."
        case .sessionNotYetValid: "Cluster session is not yet valid."
        case .sessionExpired: "Cluster session has expired."
        case .sessionClosed: "Cluster session is closed."
        case .sessionFenced: "Cluster session has been fenced."
        case .sessionIdentityMismatch: "Cluster session subject identity does not match the request."
        case .membershipEpochMismatch: "Cluster session membership epoch is stale."
        case .membershipEpochRegression: "Cluster session membership epoch cannot move backwards or repeat."
        case .fenceMismatch: "Cluster session fencing token is stale."
        case .fenceOverflow: "Cluster session fencing token cannot advance."
        case .timestampOverflow: "Cluster session timestamp cannot advance safely."
        case .invalidLifetime: "Cluster session lifetime is outside the supported bound."
        }
    }
}

public enum ClusterSessionContract {
    public static let apiVersion = 1
    public static let protocolLabel = "hostwright-cluster-session-v1"
    public static let handoffProtocolLabel = "hostwright-cluster-session-handoff-v1"
    public static let nonceByteCount = 32
    public static let maximumIdentifierBytes = 128
    public static let maximumCredentialCount = 256
    public static let maximumPendingChallenges = 512
    public static let maximumChallengeLifetimeMilliseconds: UInt64 = 30_000
    public static let maximumSessionLifetimeMilliseconds: UInt64 = 86_400_000
}

public struct ClusterSessionX509CredentialBinding: Codable, Equatable, Hashable, Sendable {
    public let identity: ClusterCertificateIdentity
    public let leafCertificateSHA256: String
    public let authorityCertificateSHA256: String

    public init(
        identity: ClusterCertificateIdentity,
        leafCertificateSHA256: String,
        authorityCertificateSHA256: String
    ) throws {
        self.identity = identity
        self.leafCertificateSHA256 = leafCertificateSHA256
        self.authorityCertificateSHA256 = authorityCertificateSHA256
        try validate()
    }

    public func validate() throws {
        guard identity.role == .nodeAgentClient,
              Self.isCanonicalSHA256(leafCertificateSHA256),
              Self.isCanonicalSHA256(authorityCertificateSHA256) else {
            throw ClusterSessionError.invalidCredentialMaterial
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: container.decode(ClusterCertificateIdentity.self, forKey: .identity),
            leafCertificateSHA256: container.decode(
                String.self,
                forKey: .leafCertificateSHA256
            ),
            authorityCertificateSHA256: container.decode(
                String.self,
                forKey: .authorityCertificateSHA256
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identity, forKey: .identity)
        try container.encode(leafCertificateSHA256, forKey: .leafCertificateSHA256)
        try container.encode(
            authorityCertificateSHA256,
            forKey: .authorityCertificateSHA256
        )
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case leafCertificateSHA256
        case authorityCertificateSHA256
    }
}

public enum ClusterSessionCredentialProvenance: Equatable, Hashable, Sendable {
    case legacy
    case x509(ClusterSessionX509CredentialBinding)
}

public struct ClusterSessionCredential: Codable, Equatable, Hashable, Sendable {
    public let credentialID: String
    public let subjectID: String
    public let nodeID: ClusterNodeID
    public let p256X963PublicKey: Data
    public let provenance: ClusterSessionCredentialProvenance

    public init(
        credentialID: String,
        subjectID: String,
        nodeID: ClusterNodeID,
        p256X963PublicKey: Data
    ) throws {
        self.credentialID = credentialID
        self.subjectID = subjectID
        self.nodeID = nodeID
        self.p256X963PublicKey = p256X963PublicKey
        self.provenance = .legacy
        try validate()
    }

    public init(
        credentialID: String,
        subjectID: String,
        nodeID: ClusterNodeID,
        p256X963PublicKey: Data,
        x509Binding: ClusterSessionX509CredentialBinding
    ) throws {
        self.credentialID = credentialID
        self.subjectID = subjectID
        self.nodeID = nodeID
        self.p256X963PublicKey = p256X963PublicKey
        self.provenance = .x509(x509Binding)
        try validate()
    }

    public init(
        x509Binding: ClusterSessionX509CredentialBinding,
        p256X963PublicKey: Data
    ) throws {
        try self.init(
            credentialID: Self.x509CredentialID(
                leafCertificateSHA256: x509Binding.leafCertificateSHA256
            ),
            subjectID: Self.x509SubjectID(identity: x509Binding.identity),
            nodeID: x509Binding.identity.nodeID,
            p256X963PublicKey: p256X963PublicKey,
            x509Binding: x509Binding
        )
    }

    public var x509Binding: ClusterSessionX509CredentialBinding? {
        guard case .x509(let binding) = provenance else { return nil }
        return binding
    }

    public static func x509CredentialID(
        leafCertificateSHA256: String
    ) -> String {
        "x509-sha256:\(leafCertificateSHA256)"
    }

    public static func x509SubjectID(
        identity: ClusterCertificateIdentity
    ) -> String {
        "cluster:\(identity.clusterID.rawValue)"
            + ":node:\(identity.nodeID.rawValue):g\(identity.generation.value)"
    }

    private static func resemblesX509Subject(_ value: String) -> Bool {
        value.hasPrefix("cluster:")
            && value.contains(":node:")
            && value.range(of: ":g", options: .backwards) != nil
    }

    private static func isCanonicalX509CredentialID(_ value: String) -> Bool {
        value.hasPrefix("x509-sha256:")
    }

    private init(
        credentialID: String,
        subjectID: String,
        nodeID: ClusterNodeID,
        p256X963PublicKey: Data,
        provenance: ClusterSessionCredentialProvenance
    ) throws {
        self.credentialID = credentialID
        self.subjectID = subjectID
        self.nodeID = nodeID
        self.p256X963PublicKey = p256X963PublicKey
        self.provenance = provenance
        try validate()
    }

    public func validate() throws {
        try ClusterSessionValidation.identifier(credentialID, field: "credentialID")
        try ClusterSessionValidation.identifier(subjectID, field: "subjectID")
        guard p256X963PublicKey.count == 65 else {
            throw ClusterSessionError.invalidCredentialMaterial
        }
        guard (try? P256.Signing.PublicKey(x963Representation: p256X963PublicKey)) != nil else {
            throw ClusterSessionError.invalidCredentialMaterial
        }
        switch provenance {
        case .legacy:
            guard !Self.isCanonicalX509CredentialID(credentialID),
                  !Self.resemblesX509Subject(subjectID) else {
                throw ClusterSessionError.invalidCredentialMaterial
            }
        case .x509(let binding):
            try binding.validate()
            guard credentialID == Self.x509CredentialID(
                leafCertificateSHA256: binding.leafCertificateSHA256
            ),
                  subjectID == Self.x509SubjectID(identity: binding.identity),
                  nodeID == binding.identity.nodeID else {
                throw ClusterSessionError.invalidCredentialMaterial
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let credentialID = try container.decode(String.self, forKey: .credentialID)
        let subjectID = try container.decode(String.self, forKey: .subjectID)
        let nodeID = try container.decode(ClusterNodeID.self, forKey: .nodeID)
        let publicKey = try container.decode(Data.self, forKey: .p256X963PublicKey)
        let kind = try container.decodeIfPresent(CredentialKind.self, forKey: .kind)
        let binding = try container.decodeIfPresent(
            ClusterSessionX509CredentialBinding.self,
            forKey: .x509Binding
        )
        let provenance: ClusterSessionCredentialProvenance
        switch (kind, binding) {
        case (nil, nil), (.some(.legacy), nil):
            provenance = .legacy
        case (.some(.x509), .some(let binding)):
            provenance = .x509(binding)
        default:
            throw ClusterSessionError.invalidCredentialMaterial
        }
        try self.init(
            credentialID: credentialID,
            subjectID: subjectID,
            nodeID: nodeID,
            p256X963PublicKey: publicKey,
            provenance: provenance
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(credentialID, forKey: .credentialID)
        try container.encode(subjectID, forKey: .subjectID)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(p256X963PublicKey, forKey: .p256X963PublicKey)
        switch provenance {
        case .legacy:
            try container.encode(CredentialKind.legacy, forKey: .kind)
        case .x509(let binding):
            try container.encode(CredentialKind.x509, forKey: .kind)
            try container.encode(binding, forKey: .x509Binding)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case credentialID
        case subjectID
        case nodeID
        case p256X963PublicKey
        case kind
        case x509Binding
    }

    private enum CredentialKind: String, Codable {
        case legacy
        case x509
    }
}

public struct ClusterSessionCredentialCatalog: Codable, Equatable, Sendable {
    public let credentials: [ClusterSessionCredential]

    public init(_ credentials: [ClusterSessionCredential]) throws {
        guard credentials.count <= ClusterSessionContract.maximumCredentialCount else {
            throw ClusterSessionError.invalidCredentialMaterial
        }
        var IDs = Set<String>()
        for credential in credentials {
            try credential.validate()
            guard IDs.insert(credential.credentialID).inserted else {
                throw ClusterSessionError.duplicateCredential
            }
        }
        self.credentials = credentials.sorted { $0.credentialID < $1.credentialID }
    }

    public func resolve(credentialID: String) -> ClusterSessionCredential? {
        credentials.first { $0.credentialID == credentialID }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode([ClusterSessionCredential].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(credentials)
    }
}

/// Current-generation admission for certificate-derived session credentials.
/// Implementations must derive their answer from authoritative generation
/// state and the supplied operation time rather than from the caller-supplied
/// credential alone.
public protocol ClusterSessionCredentialGenerationAuthorizing: Sendable {
    func permits(
        _ credential: ClusterSessionCredential,
        nowMilliseconds: UInt64
    ) throws -> Bool
}

public struct ClusterSessionChallenge: Codable, Equatable, Sendable {
    public let apiVersion: Int
    public let protocolLabel: String
    public let challengeID: String
    public let clusterID: ClusterID
    public let nodeID: ClusterNodeID
    public let membershipEpoch: ClusterMembershipEpoch
    public let subjectID: String
    public let credentialID: String
    public let nonceBase64: String
    public let issuedAtMilliseconds: UInt64
    public let expiresAtMilliseconds: UInt64

    public init(
        challengeID: String,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        membershipEpoch: ClusterMembershipEpoch,
        subjectID: String,
        credentialID: String,
        nonceBase64: String,
        issuedAtMilliseconds: UInt64,
        expiresAtMilliseconds: UInt64
    ) throws {
        self.apiVersion = ClusterSessionContract.apiVersion
        self.protocolLabel = ClusterSessionContract.protocolLabel
        self.challengeID = challengeID
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.membershipEpoch = membershipEpoch
        self.subjectID = subjectID
        self.credentialID = credentialID
        self.nonceBase64 = nonceBase64
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        try validate()
    }

    public func validate() throws {
        guard apiVersion == ClusterSessionContract.apiVersion,
              protocolLabel == ClusterSessionContract.protocolLabel else {
            throw ClusterSessionError.invalidChallenge("protocol")
        }
        try ClusterSessionValidation.uuid(challengeID, field: "challengeID")
        try ClusterSessionValidation.identifier(subjectID, field: "subjectID")
        try ClusterSessionValidation.identifier(credentialID, field: "credentialID")
        guard let nonce = Data(base64Encoded: nonceBase64),
              nonce.count == ClusterSessionContract.nonceByteCount,
              nonce.base64EncodedString() == nonceBase64 else {
            throw ClusterSessionError.invalidChallenge("nonce")
        }
        guard issuedAtMilliseconds < expiresAtMilliseconds else {
            throw ClusterSessionError.invalidChallenge("lifetime")
        }
        guard issuedAtMilliseconds <= UInt64(Int64.max),
              expiresAtMilliseconds <= UInt64(Int64.max) else {
            throw ClusterSessionError.invalidChallenge("timestamp")
        }
    }

    public func canonicalData() throws -> Data {
        try validate()
        return try ControlPlaneCanonicalJSON.encode(self)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let apiVersion = try container.decode(Int.self, forKey: .apiVersion)
        let protocolLabel = try container.decode(String.self, forKey: .protocolLabel)
        guard apiVersion == ClusterSessionContract.apiVersion,
              protocolLabel == ClusterSessionContract.protocolLabel else {
            throw ClusterSessionError.invalidChallenge("protocol")
        }
        try self.init(
            challengeID: container.decode(String.self, forKey: .challengeID),
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            nodeID: container.decode(ClusterNodeID.self, forKey: .nodeID),
            membershipEpoch: container.decode(ClusterMembershipEpoch.self, forKey: .membershipEpoch),
            subjectID: container.decode(String.self, forKey: .subjectID),
            credentialID: container.decode(String.self, forKey: .credentialID),
            nonceBase64: container.decode(String.self, forKey: .nonceBase64),
            issuedAtMilliseconds: container.decode(UInt64.self, forKey: .issuedAtMilliseconds),
            expiresAtMilliseconds: container.decode(UInt64.self, forKey: .expiresAtMilliseconds)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case apiVersion
        case protocolLabel
        case challengeID
        case clusterID
        case nodeID
        case membershipEpoch
        case subjectID
        case credentialID
        case nonceBase64
        case issuedAtMilliseconds
        case expiresAtMilliseconds
    }
}

public struct ClusterSessionProof: Codable, Equatable, Sendable {
    public let credentialID: String
    public let signatureDERBase64: String

    public init(credentialID: String, signatureDERBase64: String) throws {
        self.credentialID = credentialID
        self.signatureDERBase64 = signatureDERBase64
        try validate()
    }

    public func validate() throws {
        try ClusterSessionValidation.identifier(credentialID, field: "credentialID")
        guard signatureDERBase64.utf8.count <= 256,
              let signatureData = Data(base64Encoded: signatureDERBase64),
              (8...128).contains(signatureData.count),
              signatureData.base64EncodedString() == signatureDERBase64,
              (try? P256.Signing.ECDSASignature(derRepresentation: signatureData)) != nil else {
            throw ClusterSessionError.credentialProofMalformed
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            credentialID: container.decode(String.self, forKey: .credentialID),
            signatureDERBase64: container.decode(String.self, forKey: .signatureDERBase64)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case credentialID
        case signatureDERBase64
    }
}

public enum ClusterSessionWireContract {
    public static let challengeAllowedKeys: Set<String> = [
        "apiVersion", "protocolLabel", "challengeID", "clusterID", "nodeID",
        "membershipEpoch", "subjectID", "credentialID", "nonceBase64",
        "issuedAtMilliseconds", "expiresAtMilliseconds",
    ]
    public static let proofAllowedKeys: Set<String> = [
        "credentialID", "signatureDERBase64",
    ]
    public static let sessionAllowedKeys: Set<String> = [
        "apiVersion", "protocolLabel", "sessionID", "challengeID", "clusterID", "nodeID",
        "membershipEpoch", "subjectID", "credentialID", "fencingToken",
        "issuedAtMilliseconds", "expiresAtMilliseconds",
    ]
    public static let handoffAllowedKeys: Set<String> = [
        "apiVersion", "protocolLabel", "sessionID", "clusterID", "nodeID",
        "membershipEpoch", "subjectID", "fencingToken", "issuedAtMilliseconds",
        "expiresAtMilliseconds",
    ]

    public static func decodeChallenge(_ data: Data) throws -> ClusterSessionChallenge {
        let value = try Phase09StrictDecoder.decode(
            ClusterSessionChallenge.self,
            from: data,
            allowedKeys: challengeAllowedKeys,
            requiredKeys: challengeAllowedKeys
        )
        try value.validate()
        return value
    }

    public static func decodeProof(_ data: Data) throws -> ClusterSessionProof {
        let value = try Phase09StrictDecoder.decode(
            ClusterSessionProof.self,
            from: data,
            allowedKeys: proofAllowedKeys,
            requiredKeys: proofAllowedKeys
        )
        try value.validate()
        return value
    }

    public static func decodeSession(_ data: Data) throws -> ClusterAuthenticatedSession {
        let value = try Phase09StrictDecoder.decode(
            ClusterAuthenticatedSession.self,
            from: data,
            allowedKeys: sessionAllowedKeys,
            requiredKeys: sessionAllowedKeys
        )
        try value.validate()
        return value
    }

    public static func decodeHandoff(_ data: Data) throws -> ClusterSessionHandoff {
        let value = try Phase09StrictDecoder.decode(
            ClusterSessionHandoff.self,
            from: data,
            allowedKeys: handoffAllowedKeys,
            requiredKeys: handoffAllowedKeys
        )
        try value.validate()
        return value
    }
}

public enum ClusterSessionState: String, Codable, CaseIterable, Equatable, Sendable {
    case active
    case closed
    case fenced
    case expired
}

public struct ClusterAuthenticatedSession: Codable, Equatable, Sendable {
    public let apiVersion: Int
    public let protocolLabel: String
    public let sessionID: String
    public let challengeID: String
    public let clusterID: ClusterID
    public let nodeID: ClusterNodeID
    public let membershipEpoch: ClusterMembershipEpoch
    public let subjectID: String
    public let credentialID: String
    public let fencingToken: UInt64
    public let issuedAtMilliseconds: UInt64
    public let expiresAtMilliseconds: UInt64

    public init(
        sessionID: String,
        challengeID: String,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        membershipEpoch: ClusterMembershipEpoch,
        subjectID: String,
        credentialID: String,
        fencingToken: UInt64,
        issuedAtMilliseconds: UInt64,
        expiresAtMilliseconds: UInt64
    ) throws {
        self.apiVersion = ClusterSessionContract.apiVersion
        self.protocolLabel = ClusterSessionContract.protocolLabel
        self.sessionID = sessionID
        self.challengeID = challengeID
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.membershipEpoch = membershipEpoch
        self.subjectID = subjectID
        self.credentialID = credentialID
        self.fencingToken = fencingToken
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        try validate()
    }

    public func validate() throws {
        guard apiVersion == ClusterSessionContract.apiVersion,
              protocolLabel == ClusterSessionContract.protocolLabel else {
            throw ClusterSessionError.invalidChallenge("protocol")
        }
        try ClusterSessionValidation.uuid(sessionID, field: "sessionID")
        try ClusterSessionValidation.uuid(challengeID, field: "challengeID")
        try ClusterSessionValidation.identifier(subjectID, field: "subjectID")
        try ClusterSessionValidation.identifier(credentialID, field: "credentialID")
        guard fencingToken > 0,
              issuedAtMilliseconds < expiresAtMilliseconds,
              issuedAtMilliseconds <= UInt64(Int64.max),
              expiresAtMilliseconds <= UInt64(Int64.max) else {
            throw ClusterSessionError.invalidChallenge("binding")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let apiVersion = try container.decode(Int.self, forKey: .apiVersion)
        let protocolLabel = try container.decode(String.self, forKey: .protocolLabel)
        guard apiVersion == ClusterSessionContract.apiVersion,
              protocolLabel == ClusterSessionContract.protocolLabel else {
            throw ClusterSessionError.invalidChallenge("protocol")
        }
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            challengeID: container.decode(String.self, forKey: .challengeID),
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            nodeID: container.decode(ClusterNodeID.self, forKey: .nodeID),
            membershipEpoch: container.decode(ClusterMembershipEpoch.self, forKey: .membershipEpoch),
            subjectID: container.decode(String.self, forKey: .subjectID),
            credentialID: container.decode(String.self, forKey: .credentialID),
            fencingToken: container.decode(UInt64.self, forKey: .fencingToken),
            issuedAtMilliseconds: container.decode(UInt64.self, forKey: .issuedAtMilliseconds),
            expiresAtMilliseconds: container.decode(UInt64.self, forKey: .expiresAtMilliseconds)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case apiVersion
        case protocolLabel
        case sessionID
        case challengeID
        case clusterID
        case nodeID
        case membershipEpoch
        case subjectID
        case credentialID
        case fencingToken
        case issuedAtMilliseconds
        case expiresAtMilliseconds
    }
}

/// The credential-free session binding a node agent may hand to a local consumer.
/// It is not independently authoritative: consumers must reauthorize it through
/// `ClusterSessionHandoffAuthorizing` immediately before protected work.
public struct ClusterSessionHandoff: Codable, Equatable, Sendable {
    public let apiVersion: Int
    public let protocolLabel: String
    public let sessionID: String
    public let clusterID: ClusterID
    public let nodeID: ClusterNodeID
    public let membershipEpoch: ClusterMembershipEpoch
    public let subjectID: String
    public let fencingToken: UInt64
    public let issuedAtMilliseconds: UInt64
    public let expiresAtMilliseconds: UInt64

    public init(session: ClusterAuthenticatedSession) throws {
        try session.validate()
        try self.init(
            sessionID: session.sessionID,
            clusterID: session.clusterID,
            nodeID: session.nodeID,
            membershipEpoch: session.membershipEpoch,
            subjectID: session.subjectID,
            fencingToken: session.fencingToken,
            issuedAtMilliseconds: session.issuedAtMilliseconds,
            expiresAtMilliseconds: session.expiresAtMilliseconds
        )
    }

    public init(
        sessionID: String,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        membershipEpoch: ClusterMembershipEpoch,
        subjectID: String,
        fencingToken: UInt64,
        issuedAtMilliseconds: UInt64,
        expiresAtMilliseconds: UInt64
    ) throws {
        self.apiVersion = ClusterSessionContract.apiVersion
        self.protocolLabel = ClusterSessionContract.handoffProtocolLabel
        self.sessionID = sessionID
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.membershipEpoch = membershipEpoch
        self.subjectID = subjectID
        self.fencingToken = fencingToken
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        try validate()
    }

    public func validate() throws {
        guard apiVersion == ClusterSessionContract.apiVersion,
              protocolLabel == ClusterSessionContract.handoffProtocolLabel else {
            throw ClusterSessionError.invalidChallenge("handoffProtocol")
        }
        try ClusterSessionValidation.uuid(sessionID, field: "sessionID")
        try ClusterSessionValidation.identifier(subjectID, field: "subjectID")
        guard fencingToken > 0,
              issuedAtMilliseconds < expiresAtMilliseconds,
              issuedAtMilliseconds <= UInt64(Int64.max),
              expiresAtMilliseconds <= UInt64(Int64.max) else {
            throw ClusterSessionError.invalidChallenge("handoffBinding")
        }
    }

    public func canonicalData() throws -> Data {
        try validate()
        return try ControlPlaneCanonicalJSON.encode(self)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let apiVersion = try container.decode(Int.self, forKey: .apiVersion)
        let protocolLabel = try container.decode(String.self, forKey: .protocolLabel)
        guard apiVersion == ClusterSessionContract.apiVersion,
              protocolLabel == ClusterSessionContract.handoffProtocolLabel else {
            throw ClusterSessionError.invalidChallenge("handoffProtocol")
        }
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            nodeID: container.decode(ClusterNodeID.self, forKey: .nodeID),
            membershipEpoch: container.decode(ClusterMembershipEpoch.self, forKey: .membershipEpoch),
            subjectID: container.decode(String.self, forKey: .subjectID),
            fencingToken: container.decode(UInt64.self, forKey: .fencingToken),
            issuedAtMilliseconds: container.decode(UInt64.self, forKey: .issuedAtMilliseconds),
            expiresAtMilliseconds: container.decode(UInt64.self, forKey: .expiresAtMilliseconds)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case apiVersion
        case protocolLabel
        case sessionID
        case clusterID
        case nodeID
        case membershipEpoch
        case subjectID
        case fencingToken
        case issuedAtMilliseconds
        case expiresAtMilliseconds
    }
}

public struct ClusterSessionTransitionResult: Codable, Equatable, Sendable {
    public let sessionID: String
    public let state: ClusterSessionState
    public let fencingToken: UInt64
    public let replayed: Bool

    fileprivate init(
        sessionID: String,
        state: ClusterSessionState,
        fencingToken: UInt64,
        replayed: Bool
    ) {
        self.sessionID = sessionID
        self.state = state
        self.fencingToken = fencingToken
        self.replayed = replayed
    }
}

public protocol ClusterSessionAuthorizing: Sendable {
    func authorize(
        _ session: ClusterAuthenticatedSession,
        subjectID: String,
        nowMilliseconds: UInt64
    ) throws
}

/// Authority seam for consumers that receive only a credential-free handoff.
public protocol ClusterSessionHandoffAuthorizing: Sendable {
    func authorize(
        _ handoff: ClusterSessionHandoff,
        subjectID: String,
        nowMilliseconds: UInt64
    ) throws
}

public final class ClusterSessionAuthority: @unchecked Sendable, ClusterSessionAuthorizing, ClusterSessionHandoffAuthorizing {
    public let clusterID: ClusterID
    public let nodeID: ClusterNodeID
    public let sessionLifetimeMilliseconds: UInt64
    public let challengeLifetimeMilliseconds: UInt64

    private struct PendingChallenge {
        let challenge: ClusterSessionChallenge
        var consumed: Bool
    }

    private struct SessionRecord {
        let session: ClusterAuthenticatedSession
        var state: ClusterSessionState
    }

    private let credentials: ClusterSessionCredentialCatalog
    private let credentialGenerationAuthorizer:
        (any ClusterSessionCredentialGenerationAuthorizing)?
    private let lock = NSLock()
    private var membershipEpoch: ClusterMembershipEpoch
    private var nextFencingToken: UInt64 = 1
    private var pendingChallenges: [String: PendingChallenge] = [:]
    private var sessions: [String: SessionRecord] = [:]
    private var latestFenceBySubject: [String: UInt64] = [:]
    private var revokedCredentialIDs: Set<String> = []

    public init(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        membershipEpoch: ClusterMembershipEpoch = .initial,
        credentials: ClusterSessionCredentialCatalog,
        credentialGenerationAuthorizer:
            (any ClusterSessionCredentialGenerationAuthorizing)? = nil,
        challengeLifetimeMilliseconds: UInt64 = 5_000,
        sessionLifetimeMilliseconds: UInt64 = 300_000
    ) throws {
        guard (1...ClusterSessionContract.maximumChallengeLifetimeMilliseconds)
            .contains(challengeLifetimeMilliseconds),
            (1...ClusterSessionContract.maximumSessionLifetimeMilliseconds)
            .contains(sessionLifetimeMilliseconds) else {
            throw ClusterSessionError.invalidLifetime
        }
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.membershipEpoch = membershipEpoch
        self.credentials = credentials
        self.credentialGenerationAuthorizer = credentialGenerationAuthorizer
        self.challengeLifetimeMilliseconds = challengeLifetimeMilliseconds
        self.sessionLifetimeMilliseconds = sessionLifetimeMilliseconds
    }

    public var currentMembershipEpoch: ClusterMembershipEpoch {
        lock.lock()
        defer { lock.unlock() }
        return membershipEpoch
    }

    public func issueChallenge(
        credentialID: String,
        nowMilliseconds: UInt64,
        validForMilliseconds: UInt64? = nil
    ) throws -> ClusterSessionChallenge {
        let credential = try credential(
            for: credentialID,
            nowMilliseconds: nowMilliseconds
        )
        let lifetime = validForMilliseconds ?? challengeLifetimeMilliseconds
        guard (1...ClusterSessionContract.maximumChallengeLifetimeMilliseconds)
            .contains(lifetime) else {
            throw ClusterSessionError.invalidLifetime
        }
        let expires = try checkedTimestamp(nowMilliseconds, adding: lifetime)
        let challenge = try ClusterSessionChallenge(
            challengeID: UUID().uuidString.lowercased(),
            clusterID: clusterID,
            nodeID: nodeID,
            membershipEpoch: currentMembershipEpoch,
            subjectID: credential.subjectID,
            credentialID: credential.credentialID,
            nonceBase64: randomNonceBase64(),
            issuedAtMilliseconds: nowMilliseconds,
            expiresAtMilliseconds: expires
        )
        lock.lock()
        if pendingChallenges.count >= ClusterSessionContract.maximumPendingChallenges {
            let removable = pendingChallenges.compactMap { challengeID, pending in
                pending.consumed || pending.challenge.expiresAtMilliseconds <= nowMilliseconds
                    ? challengeID : nil
            }
            for challengeID in removable {
                pendingChallenges.removeValue(forKey: challengeID)
            }
        }
        guard pendingChallenges.count < ClusterSessionContract.maximumPendingChallenges else {
            lock.unlock()
            throw ClusterSessionError.challengeCapacityExceeded
        }
        pendingChallenges[challenge.challengeID] = PendingChallenge(
            challenge: challenge,
            consumed: false
        )
        lock.unlock()
        return challenge
    }

    public func authenticate(
        _ challenge: ClusterSessionChallenge,
        proof: ClusterSessionProof,
        nowMilliseconds: UInt64
    ) throws -> ClusterAuthenticatedSession {
        try challenge.validate()
        try proof.validate()
        guard challenge.clusterID == clusterID, challenge.nodeID == nodeID else {
            throw ClusterSessionError.challengeContextMismatch
        }

        lock.lock()
        defer { lock.unlock() }
        guard challenge.membershipEpoch == membershipEpoch else {
            throw ClusterSessionError.membershipEpochMismatch(
                expected: membershipEpoch,
                actual: challenge.membershipEpoch
            )
        }
        guard var pending = pendingChallenges[challenge.challengeID] else {
            throw ClusterSessionError.challengeNotIssued
        }
        guard pending.challenge == challenge else {
            throw ClusterSessionError.challengeMismatch
        }
        guard !pending.consumed else {
            throw ClusterSessionError.challengeConsumed
        }
        guard nowMilliseconds >= challenge.issuedAtMilliseconds else {
            throw ClusterSessionError.challengeNotYetValid
        }
        guard nowMilliseconds < challenge.expiresAtMilliseconds else {
            throw ClusterSessionError.challengeExpired
        }
        guard proof.credentialID == challenge.credentialID else {
            throw ClusterSessionError.credentialIDMismatch
        }
        guard !revokedCredentialIDs.contains(challenge.credentialID) else {
            throw ClusterSessionError.credentialRevoked
        }
        guard let credential = credentials.resolve(credentialID: challenge.credentialID),
              credential.subjectID == challenge.subjectID,
              credential.nodeID == challenge.nodeID else {
            throw ClusterSessionError.credentialNotFound
        }
        try validateCertificateGeneration(
            for: credential,
            retiredError: .credentialRevoked,
            nowMilliseconds: nowMilliseconds
        )

        pending.consumed = true
        pendingChallenges[challenge.challengeID] = pending

        let publicKey: P256.Signing.PublicKey
        let signature: P256.Signing.ECDSASignature
        guard let signatureData = Data(base64Encoded: proof.signatureDERBase64),
              signatureData.base64EncodedString() == proof.signatureDERBase64 else {
            throw ClusterSessionError.credentialProofMalformed
        }
        do {
            publicKey = try P256.Signing.PublicKey(x963Representation: credential.p256X963PublicKey)
            signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        } catch {
            throw ClusterSessionError.credentialProofMalformed
        }
        guard publicKey.isValidSignature(signature, for: try challenge.canonicalData()) else {
            throw ClusterSessionError.credentialProofRejected
        }

        guard nextFencingToken < UInt64.max else {
            throw ClusterSessionError.fenceOverflow
        }
        let fencingToken = nextFencingToken
        nextFencingToken += 1
        fenceActiveSessions(forSubject: credential.subjectID)
        let expires = try checkedTimestamp(nowMilliseconds, adding: sessionLifetimeMilliseconds)
        let session = try ClusterAuthenticatedSession(
            sessionID: UUID().uuidString.lowercased(),
            challengeID: challenge.challengeID,
            clusterID: clusterID,
            nodeID: nodeID,
            membershipEpoch: membershipEpoch,
            subjectID: credential.subjectID,
            credentialID: credential.credentialID,
            fencingToken: fencingToken,
            issuedAtMilliseconds: nowMilliseconds,
            expiresAtMilliseconds: expires
        )
        sessions[session.sessionID] = SessionRecord(session: session, state: .active)
        latestFenceBySubject[session.subjectID] = fencingToken
        return session
    }

    public func validate(
        _ session: ClusterAuthenticatedSession,
        nowMilliseconds: UInt64
    ) throws {
        try session.validate()
        lock.lock()
        defer { lock.unlock() }
        try validateLocked(session, nowMilliseconds: nowMilliseconds)
    }

    public func authorize(
        _ session: ClusterAuthenticatedSession,
        subjectID: String,
        nowMilliseconds: UInt64
    ) throws {
        try ClusterSessionValidation.identifier(subjectID, field: "subjectID")
        try session.validate()
        lock.lock()
        defer { lock.unlock() }
        try validateLocked(session, nowMilliseconds: nowMilliseconds)
        guard session.subjectID == subjectID else {
            throw ClusterSessionError.sessionIdentityMismatch
        }
    }

    /// Creates a credential-free bootstrap record only after the source session
    /// passes the same active, epoch, revocation, expiry, and fence checks used
    /// for protected operations.
    public func bootstrapConsumer(
        from session: ClusterAuthenticatedSession,
        subjectID: String,
        nowMilliseconds: UInt64
    ) throws -> ClusterSessionHandoff {
        try authorize(session, subjectID: subjectID, nowMilliseconds: nowMilliseconds)
        return try ClusterSessionHandoff(session: session)
    }

    public func authorize(
        _ handoff: ClusterSessionHandoff,
        subjectID: String,
        nowMilliseconds: UInt64
    ) throws {
        try ClusterSessionValidation.identifier(subjectID, field: "subjectID")
        try handoff.validate()
        lock.lock()
        defer { lock.unlock() }
        guard let record = sessions[handoff.sessionID] else {
            throw ClusterSessionError.sessionNotFound
        }
        let expected = try ClusterSessionHandoff(session: record.session)
        guard expected == handoff else {
            throw ClusterSessionError.handoffBindingMismatch
        }
        try validateLocked(record.session, nowMilliseconds: nowMilliseconds)
        guard record.session.subjectID == subjectID else {
            throw ClusterSessionError.sessionIdentityMismatch
        }
    }

    private func validateLocked(
        _ session: ClusterAuthenticatedSession,
        nowMilliseconds: UInt64
    ) throws {
        guard let record = sessions[session.sessionID] else {
            throw ClusterSessionError.sessionNotFound
        }
        guard record.session == session else {
            throw ClusterSessionError.sessionBindingMismatch
        }
        guard session.clusterID == clusterID, session.nodeID == nodeID else {
            throw ClusterSessionError.challengeContextMismatch
        }
        switch record.state {
        case .closed:
            throw ClusterSessionError.sessionClosed
        case .fenced:
            throw ClusterSessionError.sessionFenced
        case .expired:
            throw ClusterSessionError.sessionExpired
        case .active:
            break
        }
        guard session.membershipEpoch == membershipEpoch else {
            throw ClusterSessionError.membershipEpochMismatch(
                expected: membershipEpoch,
                actual: session.membershipEpoch
            )
        }
        guard latestFenceBySubject[session.subjectID] == session.fencingToken else {
            throw ClusterSessionError.fenceMismatch
        }
        guard !revokedCredentialIDs.contains(session.credentialID) else {
            throw ClusterSessionError.sessionFenced
        }
        guard let credential = credentials.resolve(
            credentialID: session.credentialID
        ) else {
            throw ClusterSessionError.sessionFenced
        }
        do {
            try validateCertificateGeneration(
                for: credential,
                retiredError: .sessionFenced,
                nowMilliseconds: nowMilliseconds
            )
        } catch ClusterSessionError.sessionFenced {
            sessions[session.sessionID]?.state = .fenced
            throw ClusterSessionError.sessionFenced
        }
        guard nowMilliseconds >= session.issuedAtMilliseconds else {
            throw ClusterSessionError.sessionNotYetValid
        }
        guard nowMilliseconds < session.expiresAtMilliseconds else {
            sessions[session.sessionID]?.state = .expired
            throw ClusterSessionError.sessionExpired
        }
    }

    @discardableResult
    public func close(
        _ session: ClusterAuthenticatedSession
    ) throws -> ClusterSessionTransitionResult {
        try session.validate()
        lock.lock()
        defer { lock.unlock() }
        guard var record = sessions[session.sessionID] else {
            throw ClusterSessionError.sessionNotFound
        }
        guard record.session == session else {
            throw ClusterSessionError.sessionBindingMismatch
        }
        guard record.state == .active else {
            return ClusterSessionTransitionResult(
                sessionID: session.sessionID,
                state: record.state,
                fencingToken: session.fencingToken,
                replayed: true
            )
        }
        record.state = .closed
        sessions[session.sessionID] = record
        return ClusterSessionTransitionResult(
            sessionID: session.sessionID,
            state: .closed,
            fencingToken: session.fencingToken,
            replayed: false
        )
    }

    @discardableResult
    public func fence(
        _ session: ClusterAuthenticatedSession
    ) throws -> ClusterSessionTransitionResult {
        try session.validate()
        lock.lock()
        defer { lock.unlock() }
        guard var record = sessions[session.sessionID] else {
            throw ClusterSessionError.sessionNotFound
        }
        guard record.session == session else {
            throw ClusterSessionError.sessionBindingMismatch
        }
        guard record.state == .active else {
            return ClusterSessionTransitionResult(
                sessionID: session.sessionID,
                state: record.state,
                fencingToken: session.fencingToken,
                replayed: true
            )
        }
        record.state = .fenced
        sessions[session.sessionID] = record
        return ClusterSessionTransitionResult(
            sessionID: session.sessionID,
            state: .fenced,
            fencingToken: session.fencingToken,
            replayed: false
        )
    }

    public func advanceMembershipEpoch(
        to newEpoch: ClusterMembershipEpoch
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard newEpoch > membershipEpoch else {
            throw ClusterSessionError.membershipEpochRegression
        }
        membershipEpoch = newEpoch
        for sessionID in sessions.keys {
            guard sessions[sessionID]?.state == .active else { continue }
            sessions[sessionID]?.state = .fenced
        }
    }

    public func revokeCredential(_ credentialID: String) throws {
        try ClusterSessionValidation.identifier(credentialID, field: "credentialID")
        lock.lock()
        defer { lock.unlock() }
        guard credentials.resolve(credentialID: credentialID) != nil else {
            throw ClusterSessionError.credentialNotFound
        }
        revokedCredentialIDs.insert(credentialID)
        for sessionID in sessions.keys {
            guard sessions[sessionID]?.session.credentialID == credentialID,
                  sessions[sessionID]?.state == .active else { continue }
            sessions[sessionID]?.state = .fenced
        }
    }

    public func state(
        of session: ClusterAuthenticatedSession
    ) throws -> ClusterSessionState {
        try session.validate()
        lock.lock()
        defer { lock.unlock() }
        guard let record = sessions[session.sessionID] else {
            throw ClusterSessionError.sessionNotFound
        }
        guard record.session == session else {
            throw ClusterSessionError.sessionBindingMismatch
        }
        return record.state
    }

    private func credential(
        for credentialID: String,
        nowMilliseconds: UInt64
    ) throws -> ClusterSessionCredential {
        try ClusterSessionValidation.identifier(credentialID, field: "credentialID")
        lock.lock()
        defer { lock.unlock() }
        guard !revokedCredentialIDs.contains(credentialID) else {
            throw ClusterSessionError.credentialRevoked
        }
        guard let credential = credentials.resolve(credentialID: credentialID) else {
            throw ClusterSessionError.credentialNotFound
        }
        guard credential.nodeID == nodeID else {
            throw ClusterSessionError.credentialNotFound
        }
        try validateCertificateGeneration(
            for: credential,
            retiredError: .credentialRevoked,
            nowMilliseconds: nowMilliseconds
        )
        return credential
    }

    private func validateCertificateGeneration(
        for credential: ClusterSessionCredential,
        retiredError: ClusterSessionError,
        nowMilliseconds: UInt64
    ) throws {
        guard case .x509(let binding) = credential.provenance else {
            return
        }
        guard binding.identity.clusterID == clusterID,
              binding.identity.nodeID == nodeID else {
            throw retiredError
        }
        guard let credentialGenerationAuthorizer else {
            throw ClusterSessionError.credentialGenerationAuthorityUnavailable
        }
        do {
            guard try credentialGenerationAuthorizer.permits(
                credential,
                nowMilliseconds: nowMilliseconds
            ) else {
                throw retiredError
            }
        } catch let error as ClusterSessionError {
            throw error
        } catch {
            throw ClusterSessionError.credentialGenerationAuthorityUnavailable
        }
    }

    private func fenceActiveSessions(forSubject subjectID: String) {
        for sessionID in sessions.keys {
            guard sessions[sessionID]?.session.subjectID == subjectID,
                  sessions[sessionID]?.state == .active else { continue }
            sessions[sessionID]?.state = .fenced
        }
    }

    private func checkedTimestamp(
        _ timestamp: UInt64,
        adding duration: UInt64
    ) throws -> UInt64 {
        let (result, overflow) = timestamp.addingReportingOverflow(duration)
        guard !overflow, result <= UInt64(Int64.max) else {
            throw ClusterSessionError.timestampOverflow
        }
        return result
    }

    private func randomNonceBase64() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<ClusterSessionContract.nonceByteCount).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return Data(bytes).base64EncodedString()
    }
}

private enum ClusterSessionValidation {
    static func identifier(_ value: String, field: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= ClusterSessionContract.maximumIdentifierBytes,
              value.range(of: "^[a-z0-9][a-z0-9._:-]*$", options: .regularExpression) != nil else {
            throw ClusterSessionError.invalidIdentifier(field)
        }
    }

    static func uuid(_ value: String, field: String) throws {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
            throw ClusterSessionError.invalidIdentifier(field)
        }
    }
}
