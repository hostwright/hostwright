import Foundation
@preconcurrency import Security

public enum ClusterNodeAgentTransportSecurityError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case clusterMismatch
    case localIdentityMismatch
    case localIdentityStale
    case localCertificateMismatch
    case peerGenerationUnavailable
    case authenticationRoleMismatch
    case localCertificateRejected(ClusterCertificateError)
    case peerCertificateRejected(ClusterCertificateError)
    case handoffIdentityMismatch
    case handoffAuthorizationFailed(ClusterSessionError)

    public var description: String {
        switch self {
        case .clusterMismatch:
            "Node-agent transport security belongs to another cluster."
        case .localIdentityMismatch:
            "Node-agent transport local certificate identity does not match its endpoint."
        case .localIdentityStale:
            "Node-agent transport local certificate generation is not active."
        case .localCertificateMismatch:
            "Node-agent transport local identity handle does not match its public evidence."
        case .peerGenerationUnavailable:
            "Node-agent transport peer certificate generation is not trusted."
        case .authenticationRoleMismatch:
            "Node-agent transport peer authentication was requested for the wrong endpoint role."
        case .localCertificateRejected:
            "Node-agent transport local certificate was rejected."
        case .peerCertificateRejected:
            "Node-agent transport peer certificate was rejected."
        case .handoffIdentityMismatch:
            "Node-agent transport handoff does not match the authenticated client identity."
        case .handoffAuthorizationFailed:
            "Node-agent transport handoff authorization was rejected."
        }
    }
}

public enum ClusterNodeAgentTransportSecuritySide: String, Equatable, Sendable {
    case client
    case server

    fileprivate var localCertificateRole: ClusterCertificateRole {
        switch self {
        case .client:
            .nodeAgentClient
        case .server:
            .nodeAgentServer
        }
    }

    fileprivate var peerCertificateRole: ClusterCertificateRole {
        switch self {
        case .client:
            .nodeAgentServer
        case .server:
            .nodeAgentClient
        }
    }
}

/// The opaque Keychain identity and public chain prepared for a future TLS
/// transport. No private-key representation or persistent reference is exposed.
public struct ClusterNodeAgentTransportIdentity: @unchecked Sendable {
    public let certificateIdentity: ClusterCertificateIdentity
    public let certificateSHA256: String
    public let securityIdentity: SecIdentity
    public let certificateChain: [SecCertificate]

    fileprivate init(
        certificateIdentity: ClusterCertificateIdentity,
        certificateSHA256: String,
        securityIdentity: SecIdentity,
        certificateChain: [SecCertificate]
    ) {
        self.certificateIdentity = certificateIdentity
        self.certificateSHA256 = certificateSHA256
        self.securityIdentity = securityIdentity
        self.certificateChain = certificateChain
    }
}

/// A verified node-agent client bound to the exact public credential used by
/// the cluster session challenge/proof and handoff contracts.
public struct ClusterNodeAgentAuthenticatedClient: Equatable, Sendable {
    public let peer: ClusterCertificatePeer
    public let sessionCredential: ClusterSessionCredential

    fileprivate init(
        peer: ClusterCertificatePeer,
        sessionCredential: ClusterSessionCredential
    ) {
        self.peer = peer
        self.sessionCredential = sessionCredential
    }

    public func authorize(
        _ handoff: ClusterSessionHandoff,
        using authorizer: any ClusterSessionHandoffAuthorizing,
        nowMilliseconds: UInt64
    ) throws {
        guard handoff.clusterID == peer.identity.clusterID,
              handoff.nodeID == peer.identity.nodeID,
              handoff.subjectID == sessionCredential.subjectID else {
            throw ClusterNodeAgentTransportSecurityError.handoffIdentityMismatch
        }
        do {
            try authorizer.authorize(
                handoff,
                subjectID: sessionCredential.subjectID,
                nowMilliseconds: nowMilliseconds
            )
        } catch let error as ClusterSessionError {
            throw ClusterNodeAgentTransportSecurityError
                .handoffAuthorizationFailed(error)
        }
    }
}

/// Source-only mTLS boundary preparation for a node-agent client or server.
/// The adapter opens no listener or connection. Callers construct one from a
/// current lifecycle identity and trust-bundle snapshot for each transport
/// security configuration, then provide the peer leaf observed by TLS.
public struct ClusterNodeAgentTransportSecurityAdapter: @unchecked Sendable {
    public let side: ClusterNodeAgentTransportSecuritySide
    public let clusterID: ClusterID
    public let localNodeID: ClusterNodeID
    public let peerNodeID: ClusterNodeID
    public let peerGeneration: ClusterCertificateGeneration
    public let localIdentity: ClusterNodeAgentTransportIdentity
    public let expectedPeerIdentity: ClusterCertificateIdentity

    private let verifier: ClusterMutualTLSVerifier
    private let localCertificateDER: Data

    public init(
        side: ClusterNodeAgentTransportSecuritySide,
        clusterID: ClusterID,
        localNodeID: ClusterNodeID,
        peerNodeID: ClusterNodeID,
        peerGeneration: ClusterCertificateGeneration,
        localIdentity handle: ClusterCertificateIdentityHandle,
        trustBundle: ClusterCertificateTrustBundle,
        nowMilliseconds: UInt64
    ) throws {
        guard trustBundle.clusterID == clusterID else {
            throw ClusterNodeAgentTransportSecurityError.clusterMismatch
        }
        let localCertificateIdentity = handle.credential.identity
        guard localCertificateIdentity.clusterID == clusterID,
              localCertificateIdentity.nodeID == localNodeID,
              localCertificateIdentity.role == side.localCertificateRole else {
            throw ClusterNodeAgentTransportSecurityError.localIdentityMismatch
        }
        guard localCertificateIdentity.generation == trustBundle.activeGeneration else {
            throw ClusterNodeAgentTransportSecurityError.localIdentityStale
        }
        guard trustBundle.authorities.contains(where: {
            $0.generation == peerGeneration
        }) else {
            throw ClusterNodeAgentTransportSecurityError.peerGenerationUnavailable
        }

        let expectedPeerIdentity = try ClusterCertificateIdentity(
            clusterID: clusterID,
            nodeID: peerNodeID,
            role: side.peerCertificateRole,
            generation: peerGeneration
        )
        let verifier = ClusterMutualTLSVerifier(trustBundle: trustBundle)
        let preparedIdentity = try Self.prepareLocalIdentity(
            handle,
            verifier: verifier,
            activeGeneration: trustBundle.activeGeneration,
            nowMilliseconds: nowMilliseconds
        )

        self.side = side
        self.clusterID = clusterID
        self.localNodeID = localNodeID
        self.peerNodeID = peerNodeID
        self.peerGeneration = peerGeneration
        self.localIdentity = preparedIdentity
        self.expectedPeerIdentity = expectedPeerIdentity
        self.verifier = verifier
        self.localCertificateDER = handle.credential.certificateDER
    }

    public func authenticateServer(
        certificateDER: Data,
        nowMilliseconds: UInt64
    ) throws -> ClusterCertificatePeer {
        guard side == .client else {
            throw ClusterNodeAgentTransportSecurityError.authenticationRoleMismatch
        }
        try validateLocalCertificate(nowMilliseconds: nowMilliseconds)
        return try verifyPeer(
            certificateDER: certificateDER,
            nowMilliseconds: nowMilliseconds
        )
    }

    public func authenticateClient(
        certificateDER: Data,
        nowMilliseconds: UInt64
    ) throws -> ClusterNodeAgentAuthenticatedClient {
        guard side == .server else {
            throw ClusterNodeAgentTransportSecurityError.authenticationRoleMismatch
        }
        try validateLocalCertificate(nowMilliseconds: nowMilliseconds)
        let peer = try verifyPeer(
            certificateDER: certificateDER,
            nowMilliseconds: nowMilliseconds
        )
        do {
            return ClusterNodeAgentAuthenticatedClient(
                peer: peer,
                sessionCredential: try peer.sessionCredential()
            )
        } catch let error as ClusterCertificateError {
            throw ClusterNodeAgentTransportSecurityError
                .peerCertificateRejected(error)
        }
    }

    private func validateLocalCertificate(nowMilliseconds: UInt64) throws {
        do {
            _ = try verifier.verify(
                peerCertificateDER: localCertificateDER,
                expectedIdentity: localIdentity.certificateIdentity,
                nowMilliseconds: nowMilliseconds
            )
        } catch let error as ClusterCertificateError {
            throw ClusterNodeAgentTransportSecurityError
                .localCertificateRejected(error)
        }
    }

    private func verifyPeer(
        certificateDER: Data,
        nowMilliseconds: UInt64
    ) throws -> ClusterCertificatePeer {
        do {
            return try verifier.verify(
                peerCertificateDER: certificateDER,
                expectedIdentity: expectedPeerIdentity,
                nowMilliseconds: nowMilliseconds
            )
        } catch let error as ClusterCertificateError {
            throw ClusterNodeAgentTransportSecurityError
                .peerCertificateRejected(error)
        }
    }

    private static func prepareLocalIdentity(
        _ handle: ClusterCertificateIdentityHandle,
        verifier: ClusterMutualTLSVerifier,
        activeGeneration: ClusterCertificateGeneration,
        nowMilliseconds: UInt64
    ) throws -> ClusterNodeAgentTransportIdentity {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(handle.identity, &certificate) == errSecSuccess,
              let certificate,
              SecCertificateCopyData(certificate) as Data
                == handle.credential.certificateDER,
              handle.certificateChain.count == 1,
              let authority = verifier.trustBundle.authorities.first(where: {
                  $0.generation == activeGeneration
              }),
              SecCertificateCopyData(handle.certificateChain[0]) as Data
                == authority.certificateDER else {
            throw ClusterNodeAgentTransportSecurityError.localCertificateMismatch
        }
        do {
            let verified = try verifier.verify(
                peerCertificateDER: handle.credential.certificateDER,
                expectedIdentity: handle.credential.identity,
                nowMilliseconds: nowMilliseconds
            )
            guard verified.certificateSHA256 == handle.credential.certificateSHA256 else {
                throw ClusterNodeAgentTransportSecurityError.localCertificateMismatch
            }
        } catch let error as ClusterNodeAgentTransportSecurityError {
            throw error
        } catch let error as ClusterCertificateError {
            throw ClusterNodeAgentTransportSecurityError
                .localCertificateRejected(error)
        }
        return ClusterNodeAgentTransportIdentity(
            certificateIdentity: handle.credential.identity,
            certificateSHA256: handle.credential.certificateSHA256,
            securityIdentity: handle.identity,
            certificateChain: handle.certificateChain
        )
    }
}
