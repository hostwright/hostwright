import CryptoKit
import Foundation
@preconcurrency import Security
import X509

public enum ClusterCertificateError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidGeneration
    case generationOverflow
    case invalidIdentityURI
    case invalidCertificate
    case invalidCertificateAuthority
    case invalidTrustBundle
    case clusterMismatch
    case rotationGenerationMismatch
    case rotationAlreadyInProgress
    case rotationNotInProgress
    case trustAnchorNotFound
    case certificateRevoked
    case certificateNotYetValid
    case certificateExpired
    case certificateUsageMismatch
    case certificateIdentityMismatch
    case certificateKeyRejected
    case certificateTrustRejected

    public var description: String {
        switch self {
        case .invalidGeneration: "Cluster certificate generation is invalid."
        case .generationOverflow: "Cluster certificate generation cannot advance."
        case .invalidIdentityURI: "Cluster certificate identity URI is invalid."
        case .invalidCertificate: "Cluster peer certificate is invalid."
        case .invalidCertificateAuthority: "Cluster certificate authority is invalid."
        case .invalidTrustBundle: "Cluster certificate trust bundle is invalid."
        case .clusterMismatch: "Cluster certificate belongs to another cluster."
        case .rotationGenerationMismatch: "Cluster certificate rotation generation is not sequential."
        case .rotationAlreadyInProgress: "Cluster certificate rotation already has an overlap."
        case .rotationNotInProgress: "Cluster certificate rotation has no retiring authority."
        case .trustAnchorNotFound: "Cluster certificate trust anchor is unavailable."
        case .certificateRevoked: "Cluster peer certificate is revoked."
        case .certificateNotYetValid: "Cluster peer certificate is not yet valid."
        case .certificateExpired: "Cluster peer certificate has expired."
        case .certificateUsageMismatch: "Cluster peer certificate usage is not authorized."
        case .certificateIdentityMismatch: "Cluster peer certificate identity does not match."
        case .certificateKeyRejected: "Cluster peer certificate key is unsupported."
        case .certificateTrustRejected: "Cluster peer certificate trust was rejected."
        }
    }
}

public enum ClusterCertificateContract {
    public static let identityScheme = "spiffe"
    public static let identityHost = "hostwright.internal"
    public static let maximumIdentityURIBytes = 512
    public static let maximumCertificateBytes = 64 * 1_024
    public static let maximumAuthorities = 2
    public static let maximumRevokedCertificates = 4_096
}

public struct ClusterCertificateGeneration:
    Codable,
    Equatable,
    Hashable,
    Comparable,
    Sendable
{
    public let value: UInt64

    public init(_ value: UInt64) throws {
        guard value > 0 else {
            throw ClusterCertificateError.invalidGeneration
        }
        self.value = value
    }

    public func advanced() throws -> Self {
        guard value < UInt64.max else {
            throw ClusterCertificateError.generationOverflow
        }
        return try Self(value + 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(UInt64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum ClusterCertificateRole: String, Codable, CaseIterable, Hashable, Sendable {
    case etcdPeer = "etcd-peer"
    case etcdClient = "etcd-client"
    case nodeAgentServer = "node-agent-server"
    case nodeAgentClient = "node-agent-client"
}

public struct ClusterCertificateIdentity: Codable, Equatable, Hashable, Sendable {
    public let clusterID: ClusterID
    public let nodeID: ClusterNodeID
    public let role: ClusterCertificateRole
    public let generation: ClusterCertificateGeneration

    public init(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        role: ClusterCertificateRole,
        generation: ClusterCertificateGeneration
    ) throws {
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.role = role
        self.generation = generation
        guard uri.utf8.count <= ClusterCertificateContract.maximumIdentityURIBytes else {
            throw ClusterCertificateError.invalidIdentityURI
        }
    }

    public init(uri: String) throws {
        guard uri.utf8.count <= ClusterCertificateContract.maximumIdentityURIBytes,
              let components = URLComponents(string: uri),
              components.scheme == ClusterCertificateContract.identityScheme,
              components.host == ClusterCertificateContract.identityHost,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath == components.path,
              components.string == uri else {
            throw ClusterCertificateError.invalidIdentityURI
        }
        let fields = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard fields.count == 8,
              fields[0] == "clusters",
              fields[2] == "nodes",
              fields[4] == "roles",
              fields[6] == "generations",
              let role = ClusterCertificateRole(rawValue: String(fields[5])),
              let generationValue = UInt64(fields[7]),
              String(generationValue) == fields[7] else {
            throw ClusterCertificateError.invalidIdentityURI
        }
        do {
            try self.init(
                clusterID: ClusterID(String(fields[1])),
                nodeID: ClusterNodeID(String(fields[3])),
                role: role,
                generation: ClusterCertificateGeneration(generationValue)
            )
        } catch {
            throw ClusterCertificateError.invalidIdentityURI
        }
        guard self.uri == uri else {
            throw ClusterCertificateError.invalidIdentityURI
        }
    }

    public var uri: String {
        "\(ClusterCertificateContract.identityScheme)://"
            + "\(ClusterCertificateContract.identityHost)/clusters/\(clusterID.rawValue)"
            + "/nodes/\(nodeID.rawValue)/roles/\(role.rawValue)"
            + "/generations/\(generation.value)"
    }
}

public struct ClusterCertificateAuthority: Codable, Equatable, Sendable {
    public let clusterID: ClusterID
    public let generation: ClusterCertificateGeneration
    public let certificateDER: Data
    public let certificateSHA256: String
    public let notValidBeforeMilliseconds: UInt64
    public let notValidAfterMilliseconds: UInt64

    public init(
        clusterID: ClusterID,
        generation: ClusterCertificateGeneration,
        certificateDER: Data
    ) throws {
        let certificate: Certificate
        do {
            certificate = try ClusterCertificateValidation.certificate(from: certificateDER)
            guard certificate.issuer == certificate.subject,
                  certificate.signatureAlgorithm == .ecdsaWithSHA256,
                  certificate.publicKey.isValidSignature(
                    certificate.signature,
                    for: certificate
                  ),
                  ClusterCertificateValidation.hasAllowedAuthorityCriticalExtensions(
                    in: certificate
                  ),
                  try certificate.extensions.basicConstraints
                    == .isCertificateAuthority(maxPathLength: 0),
                  try certificate.extensions.keyUsage
                    == KeyUsage(keyCertSign: true, cRLSign: true),
                  try certificate.extensions.extendedKeyUsage == nil,
                  try ClusterCertificateValidation.subjectAlternativeNames(
                    in: certificate
                  ) == [
                    .uniformResourceIdentifier(
                        Self.identityURI(clusterID: clusterID, generation: generation)
                    )
                  ],
                  ClusterCertificateValidation.p256X963PublicKey(in: certificate) != nil,
                  let notValidBefore = ClusterCertificateValidation.milliseconds(
                    certificate.notValidBefore
                  ),
                  let notValidAfter = ClusterCertificateValidation.milliseconds(
                    certificate.notValidAfter
                  ),
                  notValidBefore < notValidAfter else {
                throw ClusterCertificateError.invalidCertificateAuthority
            }
            self.notValidBeforeMilliseconds = notValidBefore
            self.notValidAfterMilliseconds = notValidAfter
        } catch let error as ClusterCertificateError {
            throw error == .invalidCertificate
                ? ClusterCertificateError.invalidCertificateAuthority
                : error
        } catch {
            throw ClusterCertificateError.invalidCertificateAuthority
        }
        self.clusterID = clusterID
        self.generation = generation
        self.certificateDER = certificateDER
        self.certificateSHA256 = ClusterCertificateValidation.sha256(certificateDER)
    }

    public static func identityURI(
        clusterID: ClusterID,
        generation: ClusterCertificateGeneration
    ) -> String {
        "\(ClusterCertificateContract.identityScheme)://"
            + "\(ClusterCertificateContract.identityHost)/clusters/\(clusterID.rawValue)"
            + "/ca/generations/\(generation.value)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            generation: container.decode(ClusterCertificateGeneration.self, forKey: .generation),
            certificateDER: container.decode(Data.self, forKey: .certificateDER)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clusterID, forKey: .clusterID)
        try container.encode(generation, forKey: .generation)
        try container.encode(certificateDER, forKey: .certificateDER)
    }

    private enum CodingKeys: String, CodingKey {
        case clusterID
        case generation
        case certificateDER
    }
}

public struct ClusterCertificateTrustBundle: Codable, Equatable, Sendable {
    public let clusterID: ClusterID
    public let activeGeneration: ClusterCertificateGeneration
    public let authorities: [ClusterCertificateAuthority]
    public let revokedCertificateSHA256: [String]

    public init(
        clusterID: ClusterID,
        activeGeneration: ClusterCertificateGeneration,
        authorities: [ClusterCertificateAuthority],
        revokedCertificateSHA256: [String] = []
    ) throws {
        let authorities = authorities.sorted { $0.generation < $1.generation }
        guard (1...ClusterCertificateContract.maximumAuthorities).contains(authorities.count),
              authorities.allSatisfy({ $0.clusterID == clusterID }),
              Set(authorities.map(\.generation)).count == authorities.count,
              Set(authorities.map(\.certificateSHA256)).count == authorities.count,
              authorities.contains(where: { $0.generation == activeGeneration }),
              authorities.last?.generation == activeGeneration,
              revokedCertificateSHA256.count
                <= ClusterCertificateContract.maximumRevokedCertificates else {
            throw ClusterCertificateError.invalidTrustBundle
        }
        if authorities.count == 2 {
            guard try authorities[0].generation.advanced() == activeGeneration else {
                throw ClusterCertificateError.invalidTrustBundle
            }
        }
        let revoked = Set(revokedCertificateSHA256)
        guard revoked.count == revokedCertificateSHA256.count,
              revoked.allSatisfy(ClusterCertificateValidation.isCanonicalSHA256),
              revoked.isDisjoint(with: Set(authorities.map(\.certificateSHA256))) else {
            throw ClusterCertificateError.invalidTrustBundle
        }
        self.clusterID = clusterID
        self.activeGeneration = activeGeneration
        self.authorities = authorities
        self.revokedCertificateSHA256 = revoked.sorted()
    }

    public func beginRotation(
        to authority: ClusterCertificateAuthority
    ) throws -> Self {
        guard authorities.count == 1 else {
            throw ClusterCertificateError.rotationAlreadyInProgress
        }
        guard authority.clusterID == clusterID else {
            throw ClusterCertificateError.clusterMismatch
        }
        guard authority.generation == (try activeGeneration.advanced()) else {
            throw ClusterCertificateError.rotationGenerationMismatch
        }
        return try Self(
            clusterID: clusterID,
            activeGeneration: authority.generation,
            authorities: authorities + [authority],
            revokedCertificateSHA256: revokedCertificateSHA256
        )
    }

    private enum CodingKeys: String, CodingKey {
        case clusterID
        case activeGeneration
        case authorities
        case revokedCertificateSHA256
    }

    public func completeRotation(
        retiring generation: ClusterCertificateGeneration
    ) throws -> Self {
        guard authorities.count == 2 else {
            throw ClusterCertificateError.rotationNotInProgress
        }
        guard generation != activeGeneration,
              authorities.contains(where: { $0.generation == generation }) else {
            throw ClusterCertificateError.rotationGenerationMismatch
        }
        return try Self(
            clusterID: clusterID,
            activeGeneration: activeGeneration,
            authorities: authorities.filter { $0.generation != generation },
            revokedCertificateSHA256: revokedCertificateSHA256
        )
    }

    public func revokingCertificate(_ certificateSHA256: String) throws -> Self {
        guard ClusterCertificateValidation.isCanonicalSHA256(certificateSHA256),
              !authorities.contains(where: {
                $0.certificateSHA256 == certificateSHA256
              }) else {
            throw ClusterCertificateError.invalidTrustBundle
        }
        if revokedCertificateSHA256.contains(certificateSHA256) {
            return self
        }
        return try Self(
            clusterID: clusterID,
            activeGeneration: activeGeneration,
            authorities: authorities,
            revokedCertificateSHA256: revokedCertificateSHA256 + [certificateSHA256]
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            activeGeneration: container.decode(
                ClusterCertificateGeneration.self,
                forKey: .activeGeneration
            ),
            authorities: container.decode(
                [ClusterCertificateAuthority].self,
                forKey: .authorities
            ),
            revokedCertificateSHA256: try container.decodeIfPresent(
                [String].self,
                forKey: .revokedCertificateSHA256
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clusterID, forKey: .clusterID)
        try container.encode(activeGeneration, forKey: .activeGeneration)
        try container.encode(authorities, forKey: .authorities)
        try container.encode(
            revokedCertificateSHA256,
            forKey: .revokedCertificateSHA256
        )
    }

    fileprivate func authority(
        for generation: ClusterCertificateGeneration
    ) -> ClusterCertificateAuthority? {
        authorities.first { $0.generation == generation }
    }
}

public struct ClusterCertificatePeer: Equatable, Sendable {
    public let identity: ClusterCertificateIdentity
    public let certificateSHA256: String
    public let authorityCertificateSHA256: String
    public let p256X963PublicKey: Data
    public let notValidBeforeMilliseconds: UInt64
    public let notValidAfterMilliseconds: UInt64

    public func sessionCredential() throws -> ClusterSessionCredential {
        guard identity.role == .nodeAgentClient else {
            throw ClusterCertificateError.certificateUsageMismatch
        }
        return try ClusterSessionCredential(
            x509Binding: ClusterSessionX509CredentialBinding(
                identity: identity,
                leafCertificateSHA256: certificateSHA256,
                authorityCertificateSHA256: authorityCertificateSHA256
            ),
            p256X963PublicKey: p256X963PublicKey
        )
    }
}

public struct ClusterMutualTLSVerifier: Sendable {
    public let trustBundle: ClusterCertificateTrustBundle

    public init(trustBundle: ClusterCertificateTrustBundle) {
        self.trustBundle = trustBundle
    }

    public func verify(
        peerCertificateDER: Data,
        expectedIdentity: ClusterCertificateIdentity,
        nowMilliseconds: UInt64
    ) throws -> ClusterCertificatePeer {
        guard expectedIdentity.clusterID == trustBundle.clusterID else {
            throw ClusterCertificateError.clusterMismatch
        }
        guard let authority = trustBundle.authority(for: expectedIdentity.generation) else {
            throw ClusterCertificateError.trustAnchorNotFound
        }
        guard nowMilliseconds >= authority.notValidBeforeMilliseconds,
              nowMilliseconds <= authority.notValidAfterMilliseconds else {
            throw ClusterCertificateError.certificateTrustRejected
        }
        let certificate = try ClusterCertificateValidation.certificate(
            from: peerCertificateDER
        )
        let fingerprint = ClusterCertificateValidation.sha256(peerCertificateDER)
        guard !trustBundle.revokedCertificateSHA256.contains(fingerprint) else {
            throw ClusterCertificateError.certificateRevoked
        }
        guard let notValidBefore = ClusterCertificateValidation.milliseconds(
            certificate.notValidBefore
        ),
              let notValidAfter = ClusterCertificateValidation.milliseconds(
                certificate.notValidAfter
              ) else {
            throw ClusterCertificateError.invalidCertificate
        }
        guard nowMilliseconds >= notValidBefore else {
            throw ClusterCertificateError.certificateNotYetValid
        }
        guard nowMilliseconds <= notValidAfter else {
            throw ClusterCertificateError.certificateExpired
        }
        guard expectedIdentity.generation == authority.generation,
              try ClusterCertificateValidation.subjectAlternativeNames(
                in: certificate
              ) == [.uniformResourceIdentifier(expectedIdentity.uri)] else {
            throw ClusterCertificateError.certificateIdentityMismatch
        }
        guard try certificate.extensions.basicConstraints
                == .notCertificateAuthority,
              try certificate.extensions.keyUsage
                == KeyUsage(digitalSignature: true),
              try ClusterCertificateValidation.extendedKeyUsages(in: certificate)
                == expectedIdentity.role.requiredExtendedKeyUsages else {
            throw ClusterCertificateError.certificateUsageMismatch
        }
        guard certificate.signatureAlgorithm == .ecdsaWithSHA256,
              let publicKey = ClusterCertificateValidation.p256X963PublicKey(
                in: certificate
              ) else {
            throw ClusterCertificateError.certificateKeyRejected
        }
        guard ClusterCertificateValidation.isTrusted(
            leafDER: peerCertificateDER,
            authorityDER: authority.certificateDER,
            nowMilliseconds: nowMilliseconds
        ) else {
            throw ClusterCertificateError.certificateTrustRejected
        }
        return ClusterCertificatePeer(
            identity: expectedIdentity,
            certificateSHA256: fingerprint,
            authorityCertificateSHA256: authority.certificateSHA256,
            p256X963PublicKey: publicKey,
            notValidBeforeMilliseconds: notValidBefore,
            notValidAfterMilliseconds: notValidAfter
        )
    }
}

private extension ClusterCertificateRole {
    var requiredExtendedKeyUsages: Set<ExtendedKeyUsage.Usage> {
        switch self {
        case .etcdPeer:
            [.serverAuth, .clientAuth]
        case .etcdClient, .nodeAgentClient:
            [.clientAuth]
        case .nodeAgentServer:
            [.serverAuth]
        }
    }
}

private enum ClusterCertificateValidation {
    static func hasAllowedAuthorityCriticalExtensions(
        in certificate: Certificate
    ) -> Bool {
        guard certificate.extensions[
            oid: .X509ExtensionID.basicConstraints
        ]?.critical == true,
              certificate.extensions[
                oid: .X509ExtensionID.keyUsage
              ]?.critical == true else {
            return false
        }
        return certificate.extensions.allSatisfy { certificateExtension in
            !certificateExtension.critical
                || certificateExtension.oid == .X509ExtensionID.basicConstraints
                || certificateExtension.oid == .X509ExtensionID.keyUsage
        }
    }

    static func certificate(from data: Data) throws -> Certificate {
        guard !data.isEmpty,
              data.count <= ClusterCertificateContract.maximumCertificateBytes else {
            throw ClusterCertificateError.invalidCertificate
        }
        do {
            return try Certificate(derEncoded: Array(data))
        } catch {
            throw ClusterCertificateError.invalidCertificate
        }
    }

    static func subjectAlternativeNames(
        in certificate: Certificate
    ) throws -> [GeneralName] {
        guard let names = try certificate.extensions.subjectAlternativeNames else {
            return []
        }
        return Array(names)
    }

    static func extendedKeyUsages(
        in certificate: Certificate
    ) throws -> Set<ExtendedKeyUsage.Usage> {
        guard let usages = try certificate.extensions.extendedKeyUsage else {
            return []
        }
        return Set(usages)
    }

    static func p256X963PublicKey(in certificate: Certificate) -> Data? {
        let representation = Data(certificate.publicKey.subjectPublicKeyInfoBytes)
        guard representation.count == 65,
              (try? P256.Signing.PublicKey(x963Representation: representation)) != nil else {
            return nil
        }
        return representation
    }

    static func milliseconds(_ date: Date) -> UInt64? {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= Double(UInt64.max) else {
            return nil
        }
        return UInt64(milliseconds.rounded(.down))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func isTrusted(
        leafDER: Data,
        authorityDER: Data,
        nowMilliseconds: UInt64
    ) -> Bool {
        guard let leaf = SecCertificateCreateWithData(nil, leafDER as CFData),
              let authority = SecCertificateCreateWithData(nil, authorityDER as CFData) else {
            return false
        }
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(leaf, policy, &trust) == errSecSuccess,
              let trust,
              SecTrustSetAnchorCertificates(trust, [authority] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustSetVerifyDate(
                trust,
                Date(
                    timeIntervalSince1970: Double(nowMilliseconds) / 1_000
                ) as CFDate
              ) == errSecSuccess else {
            return false
        }
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              chain.count == 2 else {
            return false
        }
        return SecCertificateCopyData(chain[0]) as Data == leafDER
            && SecCertificateCopyData(chain[1]) as Data == authorityDER
    }
}
