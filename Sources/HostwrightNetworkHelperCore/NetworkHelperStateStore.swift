import CryptoKit
import Darwin
import Foundation
import HostwrightNetworking

private let networkHelperPermissionBits = mode_t(
    S_ISUID | S_ISGID | S_ISTXT | S_IRWXU | S_IRWXG | S_IRWXO
)

private struct NetworkHelperFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64

    init(_ metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
    }
}

private struct NetworkHelperPersistedMetadata: Codable, Equatable {
    let schemaVersion: Int
    let identity: NetworkHelperDNSIdentity
    let corefileSHA256: String
    let hostAccessSHA256: String?
    let ingressSHA256: String?
    let certificateSHA256: String?
    let policySHA256: String?

    init(
        identity: NetworkHelperDNSIdentity,
        corefileSHA256: String,
        hostAccessSHA256: String?,
        ingressSHA256: String?,
        certificateSHA256: String? = nil,
        policySHA256: String? = nil
    ) {
        schemaVersion = policySHA256 == nil ? (certificateSHA256 == nil ? (ingressSHA256 == nil
            ? (hostAccessSHA256 == nil ? 1 : 2) : 3) : 4) : 5
        self.identity = identity
        self.corefileSHA256 = corefileSHA256
        self.hostAccessSHA256 = hostAccessSHA256
        self.ingressSHA256 = ingressSHA256
        self.certificateSHA256 = certificateSHA256
        self.policySHA256 = policySHA256
    }
}

private struct NetworkHelperCurrentPointer: Codable, Equatable {
    let schemaVersion: Int
    let identity: NetworkHelperDNSIdentity
    let corefileSHA256: String
    let hostAccessSHA256: String?
    let ingressSHA256: String?
    let certificateSHA256: String?
    let policySHA256: String?

    init(metadata: NetworkHelperPersistedMetadata) {
        schemaVersion = metadata.schemaVersion
        identity = metadata.identity
        corefileSHA256 = metadata.corefileSHA256
        hostAccessSHA256 = metadata.hostAccessSHA256
        ingressSHA256 = metadata.ingressSHA256
        certificateSHA256 = metadata.certificateSHA256
        policySHA256 = metadata.policySHA256
    }
}

private extension NetworkHelperPersistedMetadata {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, identity, corefileSHA256, hostAccessSHA256
        case ingressSHA256, certificateSHA256, policySHA256
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        identity = try values.decode(NetworkHelperDNSIdentity.self, forKey: .identity)
        corefileSHA256 = try values.decode(String.self, forKey: .corefileSHA256)
        hostAccessSHA256 = try values.decodeIfPresent(String.self, forKey: .hostAccessSHA256)
        ingressSHA256 = try values.decodeIfPresent(String.self, forKey: .ingressSHA256)
        certificateSHA256 = try values.decodeIfPresent(String.self, forKey: .certificateSHA256)
        policySHA256 = try values.decodeIfPresent(String.self, forKey: .policySHA256)
    }
}

private extension NetworkHelperCurrentPointer {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, identity, corefileSHA256, hostAccessSHA256
        case ingressSHA256, certificateSHA256, policySHA256
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        identity = try values.decode(NetworkHelperDNSIdentity.self, forKey: .identity)
        corefileSHA256 = try values.decode(String.self, forKey: .corefileSHA256)
        hostAccessSHA256 = try values.decodeIfPresent(String.self, forKey: .hostAccessSHA256)
        ingressSHA256 = try values.decodeIfPresent(String.self, forKey: .ingressSHA256)
        certificateSHA256 = try values.decodeIfPresent(String.self, forKey: .certificateSHA256)
        policySHA256 = try values.decodeIfPresent(String.self, forKey: .policySHA256)
    }
}

private struct NetworkHelperRemovalMarker: Codable, Equatable {
    let schemaVersion: Int
    let projectUUID: String
    let dnsUUID: String

    init(identity: NetworkHelperDNSIdentity) {
        schemaVersion = 1
        projectUUID = identity.projectUUID
        dnsUUID = identity.dnsUUID
    }
}

struct NetworkHelperPersistedHostAccessConfiguration:
    Equatable,
    Sendable
{
    let identity: NetworkHelperDNSIdentity
    let bindings: [ProjectDNSHostAccessBinding]
    let sha256: String
}

struct NetworkHelperPersistedIngressConfiguration: Equatable, Sendable {
    let identity: NetworkHelperDNSIdentity
    let bindings: [ProjectIngressListenerBinding]
    let sha256: String
}

struct NetworkHelperPersistedCertificateConfiguration: Equatable, Sendable {
    let identity: NetworkHelperDNSIdentity
    let bindings: [ProjectCertificateRequestBinding]
    let sha256: String
}

struct NetworkHelperPersistedPolicyConfiguration: Equatable, Sendable {
    let identity: NetworkHelperDNSIdentity
    let plan: NetworkPolicyPlan
    let sha256: String
}

struct NetworkHelperPeerCertificateEvidence:
    Codable,
    Equatable,
    Sendable
{
    let identity: HostwrightMutualTLSIdentity
    let certificateSHA256: String
    let issuerCertificateSHA256: String
    let notValidBefore: Date
    let notValidAfter: Date
    let revocationStatus: String

    static func canonicalPrecedes(
        _ lhs: Self,
        _ rhs: Self
    ) -> Bool {
        lhs.identity.uriSAN < rhs.identity.uriSAN
    }
}

/// Bounded opaque Keychain references. These are evidence, not credentials.
struct NetworkHelperCertificateKeychainReferences: Codable, Equatable, Sendable {
    static let maximumReferenceBytes = 4_096
    let leafCertificate: Data
    let leafKey: Data
    let issuerCertificate: Data?
    let issuerKey: Data?

    init?(_ references: CertificateIdentityPersistentReferences?) {
        guard let references,
              references.leafCertificate.count <= Self.maximumReferenceBytes,
              references.leafKey.count <= Self.maximumReferenceBytes,
              references.issuerCertificate?.count ?? 0 <= Self.maximumReferenceBytes,
              references.issuerKey?.count ?? 0 <= Self.maximumReferenceBytes else {
            return nil
        }
        leafCertificate = references.leafCertificate
        leafKey = references.leafKey
        issuerCertificate = references.issuerCertificate
        issuerKey = references.issuerKey
    }

    var persistentReferences: CertificateIdentityPersistentReferences {
        CertificateIdentityPersistentReferences(
            leafCertificate: leafCertificate,
            leafKey: leafKey,
            issuerCertificate: issuerCertificate,
            issuerKey: issuerKey
        )
    }
}

struct NetworkHelperCertificateEvidence: Codable, Equatable, Sendable {
    let name: String
    let certificateUUID: String
    let source: HostwrightCertificateSourceKind
    let certificateSHA256: String
    let issuerCertificateSHA256: String?
    let dnsNames: [String]
    let uriNames: [String]
    let supportsServerAuthentication: Bool
    let managed: Bool
    let peers: [NetworkHelperPeerCertificateEvidence]
    let notValidBefore: Date
    let notValidAfter: Date
    let revocationStatus: String
    let keychainReferences: NetworkHelperCertificateKeychainReferences?

    init(
        name: String,
        certificateUUID: String,
        source: HostwrightCertificateSourceKind,
        certificateSHA256: String,
        issuerCertificateSHA256: String?,
        dnsNames: [String],
        uriNames: [String] = [],
        supportsServerAuthentication: Bool = true,
        managed: Bool = false,
        peers: [NetworkHelperPeerCertificateEvidence] = [],
        notValidBefore: Date,
        notValidAfter: Date,
        revocationStatus: String,
        keychainReferences: NetworkHelperCertificateKeychainReferences? = nil
    ) {
        self.name = name
        self.certificateUUID = certificateUUID
        self.source = source
        self.certificateSHA256 = certificateSHA256
        self.issuerCertificateSHA256 = issuerCertificateSHA256
        self.dnsNames = dnsNames.sorted()
        self.uriNames = uriNames.sorted()
        self.supportsServerAuthentication =
            supportsServerAuthentication
        self.managed = managed
        self.peers = peers.sorted(
            by: NetworkHelperPeerCertificateEvidence.canonicalPrecedes
        )
        self.notValidBefore = notValidBefore
        self.notValidAfter = notValidAfter
        self.revocationStatus = revocationStatus
        self.keychainReferences = keychainReferences
    }

    static func canonicalPrecedes(
        _ lhs: Self,
        _ rhs: Self
    ) -> Bool {
        (lhs.name, lhs.certificateUUID) <
            (rhs.name, rhs.certificateUUID)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case certificateUUID
        case source
        case certificateSHA256
        case issuerCertificateSHA256
        case dnsNames
        case uriNames
        case supportsServerAuthentication
        case managed
        case peers
        case notValidBefore
        case notValidAfter
        case revocationStatus
        case keychainReferences
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try values.decode(String.self, forKey: .name),
            certificateUUID: try values.decode(
                String.self,
                forKey: .certificateUUID
            ),
            source: try values.decode(
                HostwrightCertificateSourceKind.self,
                forKey: .source
            ),
            certificateSHA256: try values.decode(
                String.self,
                forKey: .certificateSHA256
            ),
            issuerCertificateSHA256: try values.decodeIfPresent(
                String.self,
                forKey: .issuerCertificateSHA256
            ),
            dnsNames: try values.decode(
                [String].self,
                forKey: .dnsNames
            ),
            uriNames: try values.decodeIfPresent(
                [String].self,
                forKey: .uriNames
            ) ?? [],
            supportsServerAuthentication: try values.decodeIfPresent(
                Bool.self,
                forKey: .supportsServerAuthentication
            ) ?? true,
            managed: try values.decodeIfPresent(
                Bool.self,
                forKey: .managed
            ) ?? false,
            peers: try values.decodeIfPresent(
                [NetworkHelperPeerCertificateEvidence].self,
                forKey: .peers
            ) ?? [],
            notValidBefore: try values.decode(
                Date.self,
                forKey: .notValidBefore
            ),
            notValidAfter: try values.decode(
                Date.self,
                forKey: .notValidAfter
            ),
            revocationStatus: try values.decode(
                String.self,
                forKey: .revocationStatus
            ),
            keychainReferences: try values.decodeIfPresent(
                NetworkHelperCertificateKeychainReferences.self,
                forKey: .keychainReferences
            )
        )
    }
}

struct NetworkHelperPersistedCertificateEvidence:
    Codable,
    Equatable,
    Sendable
{
    let schemaVersion: Int
    let identity: NetworkHelperDNSIdentity
    let requestSHA256: String
    let certificates: [NetworkHelperCertificateEvidence]

    init(
        identity: NetworkHelperDNSIdentity,
        requestSHA256: String,
        certificates: [NetworkHelperCertificateEvidence]
    ) {
        schemaVersion = 1
        self.identity = identity
        self.requestSHA256 = requestSHA256
        self.certificates = certificates.sorted(
            by: NetworkHelperCertificateEvidence.canonicalPrecedes
        )
    }
}

enum NetworkHelperCertificateReplacementPhase:
    String,
    Codable,
    Equatable,
    Sendable
{
    case intent
    case verified
}

/// Durable, bounded certificate replacement state. The intent is written
/// before an issuer or Keychain mutation. Verified evidence is added only
/// after the exact replacement has passed the certificate boundary.
struct NetworkHelperPendingCertificateReplacement:
    Codable,
    Equatable,
    Sendable
{
    let schemaVersion: Int
    let identity: NetworkHelperDNSIdentity
    let requestSHA256: String
    let phase: NetworkHelperCertificateReplacementPhase
    let priorEvidenceSHA256: String?
    let replacement: NetworkHelperPersistedCertificateEvidence?

    init(
        identity: NetworkHelperDNSIdentity,
        requestSHA256: String,
        phase: NetworkHelperCertificateReplacementPhase,
        priorEvidenceSHA256: String?,
        replacement: NetworkHelperPersistedCertificateEvidence?
    ) {
        schemaVersion = 1
        self.identity = identity
        self.requestSHA256 = requestSHA256
        self.phase = phase
        self.priorEvidenceSHA256 = priorEvidenceSHA256
        self.replacement = replacement
    }
}

final class NetworkHelperStateStore: @unchecked Sendable {
    let rootURL: URL
    private let owner: uid_t
    private let fileManager: FileManager
    private let lock = NSLock()
    private let rootIdentity: NetworkHelperFileIdentity

    private static func schemaVersion(
        hostAccessSHA256: String?,
        ingressSHA256: String?,
        certificateSHA256: String?,
        policySHA256: String?
    ) -> Int {
        if policySHA256 != nil { return 5 }
        if certificateSHA256 != nil { return 4 }
        if ingressSHA256 != nil { return 3 }
        return hostAccessSHA256 == nil ? 1 : 2
    }

    init(
        rootURL: URL,
        owner: uid_t = geteuid(),
        fileManager: FileManager = .default
    ) throws {
        self.rootURL = rootURL
        self.owner = owner
        self.fileManager = fileManager
        try Self.preparePrivateDirectory(
            rootURL,
            owner: owner,
            requireSafeParent: true
        )
        var metadata = stat()
        guard lstat(rootURL.path, &metadata) == 0 else {
            throw NetworkHelperError.unsafePath
        }
        rootIdentity = NetworkHelperFileIdentity(metadata)
        try recover()
    }

    func apply(
        identity: NetworkHelperDNSIdentity,
        corefile: String,
        hostAccessBindings: [ProjectDNSHostAccessBinding] = [],
        ingressBindings: [ProjectIngressListenerBinding] = [],
        certificateBindings: [ProjectCertificateRequestBinding] = [],
        policyPlan: NetworkPolicyPlan? = nil,
        predecessorFencingToken: String? = nil
    ) throws -> NetworkHelperStatus {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        guard !corefile.isEmpty,
              !corefile.utf8.contains(0),
              corefile.lengthOfBytes(using: .utf8)
                <= NetworkHelperProtocolV1.maximumCorefileBytes else {
            throw NetworkHelperError.invalidCorefile
        }
        let validatedBindings =
            try NetworkHelperHostAccessValidation.validated(
                hostAccessBindings
            )
        let hostAccessData = validatedBindings.isEmpty
            ? nil
            : try NetworkHelperCanonicalJSON.encode(validatedBindings)
        let hostAccessSHA256 = hostAccessData.map(Self.sha256)
        let validatedIngress = try NetworkHelperIngressValidation.validated(
            ingressBindings
        )
        let ingressData = validatedIngress.isEmpty
            ? nil
            : try NetworkHelperCanonicalJSON.encode(validatedIngress)
        let ingressSHA256 = ingressData.map(Self.sha256)
        let validatedCertificates = try NetworkHelperCertificateValidation.validated(certificateBindings)
        let certificateData = validatedCertificates.isEmpty ? nil : try NetworkHelperCanonicalJSON.encode(validatedCertificates)
        let certificateSHA256 = certificateData.map(Self.sha256)
        if let policyPlan {
            try NetworkHelperPolicyBroker.validated(
                plan: policyPlan,
                identity: identity
            )
        }
        let policyData: Data?
        if let policyPlan {
            policyData = try NetworkHelperCanonicalJSON.encode(policyPlan)
        } else {
            policyData = nil
        }
        let policySHA256 = policyPlan?.sha256

        try recoverLocked()
        let dnsRoot = try ensureDNSRoot(for: identity)
        guard !fileManager.fileExists(
            atPath: preparedRemovalURL(dnsRoot: dnsRoot).path
        ) else {
            throw NetworkHelperError.conflict
        }
        let current = try currentStatusLocked(
            requestedIdentity: identity,
            dnsRoot: dnsRoot
        )
        let retainsPriorGenerationForCertificateReplacement =
            current.identity != nil &&
            (
                current.identity != identity ||
                current.certificateSHA256 != certificateSHA256
            )
        switch current.disposition {
        case .active:
            let digest = Self.sha256(Data(corefile.utf8))
            guard current.corefileSHA256 == digest,
                  current.hostAccessSHA256 == hostAccessSHA256,
                  current.ingressSHA256 == ingressSHA256,
                  current.certificateSHA256 == certificateSHA256,
                  current.policySHA256 == policySHA256 else {
                throw NetworkHelperError.conflict
            }
            return current
        case .conflict:
            guard let active = current.identity,
                  active.projectUUID == identity.projectUUID,
                  active.dnsUUID == identity.dnsUUID,
                  identity.generation > active.generation,
                  predecessorFencingToken ==
                    active.fencingToken else {
                throw NetworkHelperError.conflict
            }
        case .quarantined:
            throw NetworkHelperError.quarantined
        case .absent:
            guard predecessorFencingToken == nil else {
                throw NetworkHelperError.conflict
            }
        }
        if current.identity != identity ||
            current.certificateSHA256 != certificateSHA256 {
            let currentEvidence = certificateEvidenceURL(
                dnsRoot: dnsRoot
            )
            let retiredEvidence = retiredCertificateEvidenceURL(
                dnsRoot: dnsRoot
            )
            if fileManager.fileExists(atPath: currentEvidence.path),
               fileManager.fileExists(atPath: retiredEvidence.path) {
                throw NetworkHelperError.conflict
            }
        }

        try validateGenerationDirectoryContents(
            at: dnsRoot,
            projectUUID: identity.projectUUID,
            dnsUUID: identity.dnsUUID
        )

        let metadata = NetworkHelperPersistedMetadata(
            identity: identity,
            corefileSHA256: Self.sha256(Data(corefile.utf8)),
            hostAccessSHA256: hostAccessSHA256,
            ingressSHA256: ingressSHA256,
            certificateSHA256: certificateSHA256,
            policySHA256: policySHA256
        )
        try stageGeneration(
            metadata: metadata,
            corefile: Data(corefile.utf8),
            hostAccess: hostAccessData,
            ingress: ingressData,
            certificates: certificateData,
            policy: policyData,
            dnsRoot: dnsRoot
        )
        if current.identity != identity ||
            current.certificateSHA256 != certificateSHA256 {
            try retireCertificateEvidenceIfPresent(dnsRoot: dnsRoot)
        }
        try replaceCurrentPointer(
            NetworkHelperCurrentPointer(metadata: metadata),
            dnsRoot: dnsRoot
        )
        try refreshActiveCorefile(
            pointer: NetworkHelperCurrentPointer(metadata: metadata),
            dnsRoot: dnsRoot
        )
        if !retainsPriorGenerationForCertificateReplacement {
            try removeSupersededGenerations(
                dnsRoot: dnsRoot,
                keeping: identity.generation,
                projectUUID: identity.projectUUID,
                dnsUUID: identity.dnsUUID
            )
        }
        return NetworkHelperStatus(
            disposition: .active,
            identity: identity,
            corefileSHA256: metadata.corefileSHA256,
            hostAccessSHA256: metadata.hostAccessSHA256,
            ingressSHA256: metadata.ingressSHA256,
            certificateSHA256: metadata.certificateSHA256,
            policySHA256: metadata.policySHA256,
            reason: nil
        )
    }

    func status(identity: NetworkHelperDNSIdentity) throws -> NetworkHelperStatus {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        do {
            try recoverLocked()
        } catch let error as NetworkHelperError {
            if error == .unsafePath {
                throw error
            }
            return quarantinedStatus(
                "persisted DNS metadata is invalid"
            )
        } catch {
            return quarantinedStatus("persisted DNS metadata is invalid")
        }
        let dnsRoot = dnsRootURL(for: identity)
        guard fileManager.fileExists(atPath: dnsRoot.path) else {
            return NetworkHelperStatus(
                disposition: .absent,
                identity: nil,
                corefileSHA256: nil,
                reason: nil
            )
        }
        return try currentStatusLocked(
            requestedIdentity: identity,
            dnsRoot: dnsRoot
        )
    }

    func prepareRemoval(identity: NetworkHelperDNSIdentity) throws {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        guard fileManager.fileExists(atPath: dnsRoot.path) else {
            return
        }

        let status = try currentStatusLocked(
            requestedIdentity: identity,
            dnsRoot: dnsRoot
        )
        guard status.disposition == .active else {
            if status.disposition == .quarantined {
                throw NetworkHelperError.quarantined
            }
            throw NetworkHelperError.conflict
        }
        try validateGenerationDirectoryContents(
            at: dnsRoot,
            projectUUID: identity.projectUUID,
            dnsUUID: identity.dnsUUID
        )

        let markerURL = preparedRemovalURL(dnsRoot: dnsRoot)
        if fileManager.fileExists(atPath: markerURL.path) {
            let marker: NetworkHelperRemovalMarker = try loadCanonical(
                NetworkHelperRemovalMarker.self,
                from: markerURL
            )
            guard marker.schemaVersion == 1,
                  marker.projectUUID == identity.projectUUID,
                  marker.dnsUUID == identity.dnsUUID else {
                throw NetworkHelperError.quarantined
            }
            return
        }
        try writeExclusive(
            try NetworkHelperCanonicalJSON.encode(
                NetworkHelperRemovalMarker(identity: identity)
            ),
            to: markerURL
        )
        try synchronizeDirectory(dnsRoot)
    }

    func hasPreparedRemoval(
        identity: NetworkHelperDNSIdentity
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        guard fileManager.fileExists(atPath: dnsRoot.path) else {
            return false
        }
        let markerURL = preparedRemovalURL(dnsRoot: dnsRoot)
        guard fileManager.fileExists(atPath: markerURL.path) else {
            return false
        }
        let marker: NetworkHelperRemovalMarker = try loadCanonical(
            NetworkHelperRemovalMarker.self,
            from: markerURL
        )
        guard marker.schemaVersion == 1,
              marker.projectUUID == identity.projectUUID,
              marker.dnsUUID == identity.dnsUUID else {
            throw NetworkHelperError.quarantined
        }
        return true
    }

    func commitPreparedRemoval(
        identity: NetworkHelperDNSIdentity
    ) throws -> NetworkHelperStatus {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        guard fileManager.fileExists(atPath: dnsRoot.path) else {
            return NetworkHelperStatus(
                disposition: .absent,
                identity: nil,
                corefileSHA256: nil,
                reason: nil
            )
        }
        let markerURL = preparedRemovalURL(dnsRoot: dnsRoot)
        let marker: NetworkHelperRemovalMarker = try loadCanonical(
            NetworkHelperRemovalMarker.self,
            from: markerURL
        )
        guard marker.schemaVersion == 1,
              marker.projectUUID == identity.projectUUID,
              marker.dnsUUID == identity.dnsUUID else {
            throw NetworkHelperError.quarantined
        }
        let committedMarkerURL = dnsRoot.appendingPathComponent(
            "removal.json",
            isDirectory: false
        )
        guard rename(markerURL.path, committedMarkerURL.path) == 0 else {
            throw NetworkHelperError.ioFailure
        }
        try synchronizeDirectory(dnsRoot)

        let projectRoot = dnsRoot.deletingLastPathComponent()
        let removingURL = projectRoot.appendingPathComponent(
            ".removing-\(identity.dnsUUID)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard rename(dnsRoot.path, removingURL.path) == 0 else {
            throw NetworkHelperError.ioFailure
        }
        try synchronizeDirectory(projectRoot)
        try finishRemoval(at: removingURL)
        try removeDirectoryIfEmpty(projectRoot)
        return NetworkHelperStatus(
            disposition: .absent,
            identity: nil,
            corefileSHA256: nil,
            reason: nil
        )
    }

    func remove(identity: NetworkHelperDNSIdentity) throws -> NetworkHelperStatus {
        try prepareRemoval(identity: identity)
        return try commitPreparedRemoval(identity: identity)
    }

    func recover() throws {
        lock.lock()
        defer { lock.unlock() }
        try recoverLocked(
            recoverInterruptedCertificateIntent: true
        )
    }

    func activeHostAccessConfigurations() throws
        -> [NetworkHelperPersistedHostAccessConfiguration]
    {
        lock.lock()
        defer { lock.unlock() }
        try recoverLocked()
        var result: [NetworkHelperPersistedHostAccessConfiguration] = []
        for projectURL in try safeDirectoryContents(at: rootURL) {
            for dnsRoot in try safeDirectoryContents(at: projectURL) {
                guard Self.isCanonicalUUID(
                    dnsRoot.lastPathComponent
                ),
                !fileManager.fileExists(
                    atPath: preparedRemovalURL(dnsRoot: dnsRoot).path
                ) else {
                    continue
                }
                let pointerURL = dnsRoot.appendingPathComponent(
                    "current.json",
                    isDirectory: false
                )
                guard fileManager.fileExists(atPath: pointerURL.path)
                else {
                    continue
                }
                let pointer: NetworkHelperCurrentPointer =
                    try loadCanonical(
                        NetworkHelperCurrentPointer.self,
                        from: pointerURL
                    )
                guard let expected = pointer.hostAccessSHA256 else {
                    continue
                }
                let data = try loadRegularFile(
                    dnsRoot
                        .appendingPathComponent(
                            "active",
                            isDirectory: true
                        )
                        .appendingPathComponent(
                            "HostAccess.json",
                            isDirectory: false
                        )
                )
                guard Self.sha256(data) == expected else {
                    throw NetworkHelperError.quarantined
                }
                let bindings = try NetworkHelperCanonicalJSON.decode(
                    [ProjectDNSHostAccessBinding].self,
                    from: data
                )
                result.append(
                    NetworkHelperPersistedHostAccessConfiguration(
                        identity: pointer.identity,
                        bindings:
                            try NetworkHelperHostAccessValidation
                                .validated(bindings),
                        sha256: expected
                    )
                )
            }
        }
        return result.sorted {
            ($0.identity.projectUUID, $0.identity.dnsUUID)
                < ($1.identity.projectUUID, $1.identity.dnsUUID)
        }
    }

    func activeIngressConfigurations() throws
        -> [NetworkHelperPersistedIngressConfiguration]
    {
        lock.lock()
        defer { lock.unlock() }
        try recoverLocked()
        var result: [NetworkHelperPersistedIngressConfiguration] = []
        for projectURL in try safeDirectoryContents(at: rootURL) {
            for dnsRoot in try safeDirectoryContents(at: projectURL) {
                guard Self.isCanonicalUUID(dnsRoot.lastPathComponent),
                      !fileManager.fileExists(
                        atPath: preparedRemovalURL(dnsRoot: dnsRoot).path
                      ) else {
                    continue
                }
                let pointerURL = dnsRoot.appendingPathComponent("current.json")
                guard fileManager.fileExists(atPath: pointerURL.path) else {
                    continue
                }
                let pointer: NetworkHelperCurrentPointer = try loadCanonical(
                    NetworkHelperCurrentPointer.self, from: pointerURL
                )
                guard let expected = pointer.ingressSHA256 else { continue }
                let data = try loadRegularFile(
                    dnsRoot.appendingPathComponent("active", isDirectory: true)
                        .appendingPathComponent("Ingress.json", isDirectory: false)
                )
                guard Self.sha256(data) == expected else {
                    throw NetworkHelperError.quarantined
                }
                let bindings = try NetworkHelperCanonicalJSON.decode(
                    [ProjectIngressListenerBinding].self, from: data
                )
                result.append(NetworkHelperPersistedIngressConfiguration(
                    identity: pointer.identity,
                    bindings: try NetworkHelperIngressValidation.validated(bindings),
                    sha256: expected
                ))
            }
        }
        return result.sorted {
            ($0.identity.projectUUID, $0.identity.dnsUUID) <
                ($1.identity.projectUUID, $1.identity.dnsUUID)
        }
    }

    func activeCertificateConfigurations() throws
        -> [NetworkHelperPersistedCertificateConfiguration]
    {
        lock.lock()
        defer { lock.unlock() }
        try recoverLocked()
        var result: [NetworkHelperPersistedCertificateConfiguration] = []
        for projectURL in try safeDirectoryContents(at: rootURL) {
            for dnsRoot in try safeDirectoryContents(at: projectURL) {
                guard Self.isCanonicalUUID(dnsRoot.lastPathComponent),
                      !fileManager.fileExists(
                        atPath: preparedRemovalURL(dnsRoot: dnsRoot).path
                      ) else {
                    continue
                }
                let pointerURL = dnsRoot.appendingPathComponent("current.json")
                guard fileManager.fileExists(atPath: pointerURL.path) else { continue }
                let pointer: NetworkHelperCurrentPointer = try loadCanonical(NetworkHelperCurrentPointer.self, from: pointerURL)
                guard let expected = pointer.certificateSHA256 else { continue }
                let data = try loadRegularFile(dnsRoot.appendingPathComponent("active", isDirectory: true).appendingPathComponent("Certificate.json", isDirectory: false))
                guard Self.sha256(data) == expected else { throw NetworkHelperError.quarantined }
                let bindings = try NetworkHelperCertificateValidation.validated(try NetworkHelperCanonicalJSON.decode([ProjectCertificateRequestBinding].self, from: data))
                result.append(NetworkHelperPersistedCertificateConfiguration(identity: pointer.identity, bindings: bindings, sha256: expected))
            }
        }
        return result.sorted { ($0.identity.projectUUID, $0.identity.dnsUUID) < ($1.identity.projectUUID, $1.identity.dnsUUID) }
    }

    func persistedCertificateBindings(
        identity: NetworkHelperDNSIdentity
    ) throws -> [ProjectCertificateRequestBinding] {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        guard fileManager.fileExists(atPath: dnsRoot.path) else {
            return []
        }
        let status = try currentStatusLocked(
            requestedIdentity: identity,
            dnsRoot: dnsRoot
        )
        guard status.disposition == .active else {
            throw status.disposition == .quarantined
                ? NetworkHelperError.quarantined
                : NetworkHelperError.conflict
        }
        return try certificateBindings(
            dnsRoot: dnsRoot,
            expectedSHA256: status.certificateSHA256
        )
    }

    func activePolicyConfigurations() throws
        -> [NetworkHelperPersistedPolicyConfiguration]
    {
        lock.lock()
        defer { lock.unlock() }
        try recoverLocked()
        var result: [NetworkHelperPersistedPolicyConfiguration] = []
        for projectURL in try safeDirectoryContents(at: rootURL) {
            for dnsRoot in try safeDirectoryContents(at: projectURL) {
                guard Self.isCanonicalUUID(dnsRoot.lastPathComponent),
                      !fileManager.fileExists(
                        atPath: preparedRemovalURL(dnsRoot: dnsRoot).path
                      ) else {
                    continue
                }
                let pointerURL = dnsRoot.appendingPathComponent("current.json")
                guard fileManager.fileExists(atPath: pointerURL.path) else {
                    continue
                }
                let pointer: NetworkHelperCurrentPointer = try loadCanonical(
                    NetworkHelperCurrentPointer.self, from: pointerURL
                )
                guard let expected = pointer.policySHA256 else { continue }
                let data = try loadRegularFile(
                    dnsRoot.appendingPathComponent("active", isDirectory: true)
                        .appendingPathComponent("Policy.json", isDirectory: false)
                )
                let plan = try NetworkHelperCanonicalJSON.decode(
                    NetworkPolicyPlan.self, from: data
                )
                try NetworkHelperPolicyBroker.validated(
                    plan: plan, identity: pointer.identity
                )
                guard plan.sha256 == expected else {
                    throw NetworkHelperError.quarantined
                }
                result.append(NetworkHelperPersistedPolicyConfiguration(
                    identity: pointer.identity, plan: plan, sha256: expected
                ))
            }
        }
        return result.sorted {
            ($0.identity.projectUUID, $0.identity.dnsUUID) <
                ($1.identity.projectUUID, $1.identity.dnsUUID)
        }
    }

    func certificateEvidence(
        identity: NetworkHelperDNSIdentity
    ) throws -> NetworkHelperPersistedCertificateEvidence? {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        guard fileManager.fileExists(atPath: dnsRoot.path) else {
            return nil
        }
        let status = try currentStatusLocked(
            requestedIdentity: identity,
            dnsRoot: dnsRoot
        )
        guard status.disposition == .active else {
            if status.disposition == .quarantined {
                throw NetworkHelperError.quarantined
            }
            throw NetworkHelperError.conflict
        }
        let evidenceURL = certificateEvidenceURL(dnsRoot: dnsRoot)
        guard fileManager.fileExists(atPath: evidenceURL.path) else {
            return nil
        }
        let evidence: NetworkHelperPersistedCertificateEvidence =
            try loadCanonical(
                NetworkHelperPersistedCertificateEvidence.self,
                from: evidenceURL
            )
        let bindings = try certificateBindings(
            dnsRoot: dnsRoot,
            expectedSHA256: status.certificateSHA256
        )
        return try validatedCertificateEvidence(
            evidence,
            expectedIdentity: identity,
            expectedRequestSHA256: status.certificateSHA256,
            expectedBindings: bindings
        )
    }

    func recordCertificateEvidence(
        identity: NetworkHelperDNSIdentity,
        certificates: [NetworkHelperCertificateEvidence]
    ) throws -> NetworkHelperPersistedCertificateEvidence? {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        let status = try currentStatusLocked(
            requestedIdentity: identity,
            dnsRoot: dnsRoot
        )
        guard status.disposition == .active else {
            if status.disposition == .quarantined {
                throw NetworkHelperError.quarantined
            }
            throw NetworkHelperError.conflict
        }
        let evidenceURL = certificateEvidenceURL(dnsRoot: dnsRoot)
        guard let requestSHA256 = status.certificateSHA256 else {
            guard certificates.isEmpty else {
                throw NetworkHelperError.invalidCertificate
            }
            try removeRegularFileIfPresent(evidenceURL)
            try synchronizeDirectory(dnsRoot)
            return nil
        }
        let evidence = try validatedCertificateEvidence(
            NetworkHelperPersistedCertificateEvidence(
                identity: identity,
                requestSHA256: requestSHA256,
                certificates: certificates
            ),
            expectedIdentity: identity,
            expectedRequestSHA256: requestSHA256,
            expectedBindings: try certificateBindings(
                dnsRoot: dnsRoot,
                expectedSHA256: requestSHA256
            )
        )
        let temporary = dnsRoot.appendingPathComponent(
            ".certificate-evidence-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        try writeExclusive(
            try NetworkHelperCanonicalJSON.encode(evidence),
            to: temporary
        )
        guard rename(temporary.path, evidenceURL.path) == 0 else {
            _ = unlink(temporary.path)
            throw NetworkHelperError.ioFailure
        }
        try synchronizeDirectory(dnsRoot)
        return evidence
    }

    /// Persists the fenced replacement intent before acquisition starts.
    /// Repeating the call after a crash returns the exact pending transaction.
    func beginCertificateReplacement(
        identity: NetworkHelperDNSIdentity
    ) throws -> NetworkHelperPendingCertificateReplacement {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        let status = try currentStatusLocked(
            requestedIdentity: identity,
            dnsRoot: dnsRoot
        )
        guard status.disposition == .active,
              let requestSHA256 = status.certificateSHA256 else {
            throw status.disposition == .quarantined
                ? NetworkHelperError.quarantined
                : NetworkHelperError.conflict
        }
        if let pending = try pendingCertificateReplacementLocked(
            dnsRoot: dnsRoot
        ) {
            return try validatedPendingCertificateReplacement(
                pending,
                expectedIdentity: identity,
                expectedRequestSHA256: requestSHA256,
                dnsRoot: dnsRoot
            )
        }
        let prior = try currentOrRetiredCertificateEvidence(
            dnsRoot: dnsRoot
        )
        let transaction = NetworkHelperPendingCertificateReplacement(
            identity: identity,
            requestSHA256: requestSHA256,
            phase: .intent,
            priorEvidenceSHA256: try prior.map {
                Self.sha256(try NetworkHelperCanonicalJSON.encode($0))
            },
            replacement: nil
        )
        try replacePendingCertificateReplacement(
            transaction,
            dnsRoot: dnsRoot
        )
        return transaction
    }

    /// Adds validated replacement evidence without changing the current
    /// certificate pointer or the retained prior generation.
    func recordPendingCertificateReplacement(
        identity: NetworkHelperDNSIdentity,
        certificates: [NetworkHelperCertificateEvidence]
    ) throws -> NetworkHelperPendingCertificateReplacement {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        guard let pending = try pendingCertificateReplacementLocked(
            dnsRoot: dnsRoot
        ) else {
            throw NetworkHelperError.conflict
        }
        let validated = try validatedPendingCertificateReplacement(
            pending,
            expectedIdentity: identity,
            expectedRequestSHA256: pending.requestSHA256,
            dnsRoot: dnsRoot
        )
        let replacement = try validatedCertificateEvidence(
            NetworkHelperPersistedCertificateEvidence(
                identity: identity,
                requestSHA256: validated.requestSHA256,
                certificates: certificates
            ),
            expectedIdentity: identity,
            expectedRequestSHA256: validated.requestSHA256,
            expectedBindings: try certificateBindings(
                dnsRoot: dnsRoot,
                expectedSHA256: validated.requestSHA256
            )
        )
        let verified = NetworkHelperPendingCertificateReplacement(
            identity: identity,
            requestSHA256: validated.requestSHA256,
            phase: .verified,
            priorEvidenceSHA256: validated.priorEvidenceSHA256,
            replacement: replacement
        )
        try replacePendingCertificateReplacement(
            verified,
            dnsRoot: dnsRoot
        )
        return verified
    }

    func pendingCertificateReplacement(
        identity: NetworkHelperDNSIdentity
    ) throws -> NetworkHelperPendingCertificateReplacement? {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        guard let pending = try pendingCertificateReplacementLocked(
            dnsRoot: dnsRoot
        ) else {
            return nil
        }
        return try validatedPendingCertificateReplacement(
            pending,
            expectedIdentity: identity,
            expectedRequestSHA256: pending.requestSHA256,
            dnsRoot: dnsRoot
        )
    }

    /// Advances the certificate evidence pointer only after the replacement
    /// was durably verified. The operation is idempotent across crashes.
    func promotePendingCertificateReplacement(
        identity: NetworkHelperDNSIdentity
    ) throws -> NetworkHelperPersistedCertificateEvidence {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        guard let raw = try pendingCertificateReplacementLocked(
            dnsRoot: dnsRoot
        ) else {
            throw NetworkHelperError.conflict
        }
        let pending = try validatedPendingCertificateReplacement(
            raw,
            expectedIdentity: identity,
            expectedRequestSHA256: raw.requestSHA256,
            dnsRoot: dnsRoot
        )
        guard pending.phase == .verified,
              let replacement = pending.replacement else {
            throw NetworkHelperError.conflict
        }

        let currentURL = certificateEvidenceURL(dnsRoot: dnsRoot)
        let retiredURL = retiredCertificateEvidenceURL(dnsRoot: dnsRoot)
        if fileManager.fileExists(atPath: currentURL.path) {
            let current: NetworkHelperPersistedCertificateEvidence =
                try loadCanonical(
                    NetworkHelperPersistedCertificateEvidence.self,
                    from: currentURL
                )
            if current == replacement {
                try removeRegularFileIfPresent(
                    pendingCertificateReplacementURL(dnsRoot: dnsRoot)
                )
                try synchronizeDirectory(dnsRoot)
                return replacement
            }
            guard !fileManager.fileExists(atPath: retiredURL.path) else {
                throw NetworkHelperError.conflict
            }
            let currentDigest = Self.sha256(
                try NetworkHelperCanonicalJSON.encode(current)
            )
            guard currentDigest == pending.priorEvidenceSHA256 else {
                throw NetworkHelperError.quarantined
            }
            _ = try validatedRetiredCertificateEvidence(current)
            guard rename(currentURL.path, retiredURL.path) == 0 else {
                throw NetworkHelperError.ioFailure
            }
            try synchronizeDirectory(dnsRoot)
        } else if let expectedPrior = pending.priorEvidenceSHA256 {
            guard fileManager.fileExists(atPath: retiredURL.path) else {
                throw NetworkHelperError.quarantined
            }
            let retired: NetworkHelperPersistedCertificateEvidence =
                try loadCanonical(
                    NetworkHelperPersistedCertificateEvidence.self,
                    from: retiredURL
                )
            guard Self.sha256(
                try NetworkHelperCanonicalJSON.encode(retired)
            ) == expectedPrior else {
                throw NetworkHelperError.quarantined
            }
        }

        let temporary = dnsRoot.appendingPathComponent(
            ".certificate-evidence-\(UUID().uuidString.lowercased())"
        )
        try writeExclusive(
            try NetworkHelperCanonicalJSON.encode(replacement),
            to: temporary
        )
        guard rename(temporary.path, currentURL.path) == 0 else {
            _ = unlink(temporary.path)
            throw NetworkHelperError.ioFailure
        }
        try synchronizeDirectory(dnsRoot)
        try removeRegularFileIfPresent(
            pendingCertificateReplacementURL(dnsRoot: dnsRoot)
        )
        try synchronizeDirectory(dnsRoot)
        return replacement
    }

    /// Removes only the pending record and returns verified evidence so the
    /// coordinator can delete the exact newly-created owned items.
    @discardableResult
    func rollbackPendingCertificateReplacement(
        identity: NetworkHelperDNSIdentity
    ) throws -> NetworkHelperPersistedCertificateEvidence? {
        lock.lock()
        defer { lock.unlock() }
        let identity = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        guard let raw = try pendingCertificateReplacementLocked(
            dnsRoot: dnsRoot
        ) else {
            return nil
        }
        let pending = try validatedPendingCertificateReplacement(
            raw,
            expectedIdentity: identity,
            expectedRequestSHA256: raw.requestSHA256,
            dnsRoot: dnsRoot
        )
        try removeRegularFileIfPresent(
            pendingCertificateReplacementURL(dnsRoot: dnsRoot)
        )
        try synchronizeDirectory(dnsRoot)
        return pending.replacement
    }

    func retiredCertificateEvidence(
        identity: NetworkHelperDNSIdentity
    ) throws -> NetworkHelperPersistedCertificateEvidence? {
        lock.lock()
        defer { lock.unlock() }
        _ = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        let url = retiredCertificateEvidenceURL(dnsRoot: dnsRoot)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let evidence: NetworkHelperPersistedCertificateEvidence =
            try loadCanonical(
                NetworkHelperPersistedCertificateEvidence.self,
                from: url
            )
        return try validatedRetiredCertificateEvidence(evidence)
    }

    func clearRetiredCertificateEvidence(
        identity: NetworkHelperDNSIdentity,
        expected: NetworkHelperPersistedCertificateEvidence
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try identity.validated()
        try recoverLocked()
        let dnsRoot = dnsRootURL(for: identity)
        let url = retiredCertificateEvidenceURL(dnsRoot: dnsRoot)
        guard fileManager.fileExists(atPath: url.path) else { return }
        let actual: NetworkHelperPersistedCertificateEvidence =
            try loadCanonical(
                NetworkHelperPersistedCertificateEvidence.self,
                from: url
            )
        guard try validatedRetiredCertificateEvidence(actual)
                == expected else {
            throw NetworkHelperError.quarantined
        }
        try removeRegularFileIfPresent(url)
        try synchronizeDirectory(dnsRoot)
        let pointer: NetworkHelperCurrentPointer = try loadCanonical(
            NetworkHelperCurrentPointer.self,
            from: dnsRoot.appendingPathComponent(
                "current.json",
                isDirectory: false
            )
        )
        try removeSupersededGenerations(
            dnsRoot: dnsRoot,
            keeping: pointer.identity.generation,
            projectUUID: pointer.identity.projectUUID,
            dnsUUID: pointer.identity.dnsUUID
        )
    }

    private func certificateBindings(
        dnsRoot: URL,
        expectedSHA256: String?
    ) throws -> [ProjectCertificateRequestBinding] {
        guard let expectedSHA256 else { return [] }
        let data = try loadRegularFile(
            dnsRoot
                .appendingPathComponent("active", isDirectory: true)
                .appendingPathComponent(
                    "Certificate.json",
                    isDirectory: false
                )
        )
        guard Self.sha256(data) == expectedSHA256 else {
            throw NetworkHelperError.quarantined
        }
        return try NetworkHelperCertificateValidation.validated(
            try NetworkHelperCanonicalJSON.decode(
                [ProjectCertificateRequestBinding].self,
                from: data
            )
        )
    }

    private func validatedCertificateEvidence(
        _ evidence: NetworkHelperPersistedCertificateEvidence,
        expectedIdentity: NetworkHelperDNSIdentity,
        expectedRequestSHA256: String?,
        expectedBindings: [ProjectCertificateRequestBinding]
    ) throws -> NetworkHelperPersistedCertificateEvidence {
        guard evidence.schemaVersion == 1,
              evidence.identity == expectedIdentity,
              evidence.requestSHA256 == expectedRequestSHA256,
              Self.isCanonicalSHA256(evidence.requestSHA256),
              evidence.certificates == evidence.certificates.sorted(
                by: NetworkHelperCertificateEvidence.canonicalPrecedes
              ),
              evidence.certificates.count == expectedBindings.count else {
            throw NetworkHelperError.quarantined
        }
        let expectedByName = Dictionary(
            uniqueKeysWithValues: expectedBindings.map { ($0.name, $0) }
        )
        var seenNames = Set<String>()
        var seenUUIDs = Set<String>()
        for certificate in evidence.certificates {
            guard let binding = expectedByName[certificate.name],
                  certificate.certificateUUID == binding.certificateUUID,
                  certificate.source == binding.source,
                  seenNames.insert(certificate.name).inserted,
                  seenUUIDs.insert(certificate.certificateUUID).inserted,
                  Self.isCanonicalSHA256(
                      certificate.certificateSHA256
                  ),
                  certificate.dnsNames == binding.dnsNames,
                  certificate.dnsNames == certificate.dnsNames.sorted(),
                  certificate.uriNames ==
                    certificate.uriNames.sorted(),
                  Set(certificate.uriNames).count ==
                    certificate.uriNames.count,
                  certificate.supportsServerAuthentication,
                  certificate.peers == certificate.peers.sorted(
                    by:
                        NetworkHelperPeerCertificateEvidence
                            .canonicalPrecedes
                  ),
                  Set(certificate.peers.map(\.identity)).count ==
                    certificate.peers.count,
                  certificate.notValidBefore < certificate.notValidAfter,
                  Self.validKeychainReferences(
                    certificate.keychainReferences
                  ),
                  CertificateRevocationStatus(
                    rawValue: certificate.revocationStatus
                  ) != nil else {
                throw NetworkHelperError.quarantined
            }
            switch certificate.source {
            case .imported:
                guard binding.peerIdentities.isEmpty,
                      certificate.peers.isEmpty,
                      certificate.issuerCertificateSHA256 == nil,
                      certificate.certificateSHA256
                        == binding.identitySHA256 else {
                    throw NetworkHelperError.quarantined
                }
            case .localCA:
                let serverIdentity = try? HostwrightMutualTLSIdentity(
                    projectUUID: expectedIdentity.projectUUID,
                    resourceUUID: binding.certificateUUID,
                    role: binding.identityRole,
                    generation: expectedIdentity.generation
                )
                let serverIdentityMatches =
                    certificate.uriNames ==
                    (serverIdentity.map { [$0.uriSAN] } ?? [])
                let legacyTLSOnlyEvidence =
                    binding.peerIdentities.isEmpty &&
                    certificate.uriNames.isEmpty
                guard let issuer = certificate.issuerCertificateSHA256,
                      Self.isCanonicalSHA256(issuer),
                      serverIdentityMatches ||
                        legacyTLSOnlyEvidence,
                      certificate.peers.map(\.identity) ==
                        binding.peerIdentities else {
                    throw NetworkHelperError.quarantined
                }
                for peer in certificate.peers {
                    guard
                        Self.isCanonicalSHA256(
                            peer.certificateSHA256
                        ),
                        peer.issuerCertificateSHA256 == issuer,
                        peer.notValidBefore < peer.notValidAfter,
                        CertificateRevocationStatus(
                            rawValue: peer.revocationStatus
                        ) != nil
                    else {
                        throw NetworkHelperError.quarantined
                    }
                }
            case .provider:
                guard binding.peerIdentities.isEmpty,
                      certificate.peers.isEmpty,
                      binding.issuer != nil,
                      !certificate.managed ||
                        (
                            certificate.issuerCertificateSHA256
                                .map(Self.isCanonicalSHA256) == true &&
                            certificate.keychainReferences != nil
                        ) else {
                    throw NetworkHelperError.quarantined
                }
            }
        }
        return evidence
    }

    private func validatedRetiredCertificateEvidence(
        _ evidence: NetworkHelperPersistedCertificateEvidence
    ) throws -> NetworkHelperPersistedCertificateEvidence {
        guard evidence.schemaVersion == 1,
              (try? evidence.identity.validated()) != nil,
              Self.isCanonicalSHA256(evidence.requestSHA256),
              evidence.certificates ==
                evidence.certificates.sorted(
                    by: NetworkHelperCertificateEvidence.canonicalPrecedes
                ),
              !evidence.certificates.isEmpty else {
            throw NetworkHelperError.quarantined
        }
        var names = Set<String>()
        var identifiers = Set<String>()
        for certificate in evidence.certificates {
            guard names.insert(certificate.name).inserted,
                  identifiers.insert(certificate.certificateUUID)
                    .inserted,
                  Self.isCanonicalUUID(certificate.certificateUUID),
                  Self.isCanonicalSHA256(
                    certificate.certificateSHA256
                  ),
                  certificate.dnsNames ==
                    certificate.dnsNames.sorted(),
                  !certificate.dnsNames.isEmpty,
                  certificate.uriNames ==
                    certificate.uriNames.sorted(),
                  Set(certificate.uriNames).count ==
                    certificate.uriNames.count,
                  certificate.supportsServerAuthentication,
                  certificate.peers == certificate.peers.sorted(
                    by:
                        NetworkHelperPeerCertificateEvidence
                            .canonicalPrecedes
                  ),
                  Set(certificate.peers.map(\.identity)).count ==
                    certificate.peers.count,
                  certificate.notValidBefore <
                    certificate.notValidAfter,
                  Self.validKeychainReferences(
                    certificate.keychainReferences
                  ),
                  CertificateRevocationStatus(
                    rawValue: certificate.revocationStatus
                  ) != nil else {
                throw NetworkHelperError.quarantined
            }
            switch certificate.source {
            case .localCA:
                guard let issuer =
                        certificate.issuerCertificateSHA256,
                      Self.isCanonicalSHA256(issuer) else {
                    throw NetworkHelperError.quarantined
                }
                for peer in certificate.peers {
                    guard
                        peer.identity.isExactCanonicalValue(),
                        Self.isCanonicalSHA256(
                            peer.certificateSHA256
                        ),
                        peer.issuerCertificateSHA256 == issuer,
                        peer.notValidBefore < peer.notValidAfter,
                        CertificateRevocationStatus(
                            rawValue: peer.revocationStatus
                        ) != nil
                    else {
                        throw NetworkHelperError.quarantined
                    }
                }
            case .imported:
                guard certificate.peers.isEmpty,
                      certificate.issuerCertificateSHA256 == nil else {
                    throw NetworkHelperError.quarantined
                }
            case .provider:
                guard certificate.peers.isEmpty,
                      !certificate.managed ||
                        (
                            certificate.issuerCertificateSHA256
                                .map(Self.isCanonicalSHA256) == true &&
                            certificate.keychainReferences != nil
                        ) else {
                    throw NetworkHelperError.quarantined
                }
            }
        }
        return evidence
    }

    private func recoverLocked(
        recoverInterruptedCertificateIntent: Bool = false
    ) throws {
        try Self.validatePrivateDirectory(rootURL, owner: owner)
        var rootMetadata = stat()
        guard lstat(rootURL.path, &rootMetadata) == 0,
              NetworkHelperFileIdentity(rootMetadata) == rootIdentity else {
            throw NetworkHelperError.unsafePath
        }
        for projectURL in try safeDirectoryContents(at: rootURL) {
            guard Self.isCanonicalUUID(projectURL.lastPathComponent) else {
                throw NetworkHelperError.quarantined
            }
            try Self.validatePrivateDirectory(projectURL, owner: owner)
            for entry in try safeDirectoryContents(at: projectURL) {
                if entry.lastPathComponent.hasPrefix(".removing-") {
                    let markerURL = entry.appendingPathComponent(
                        "removal.json",
                        isDirectory: false
                    )
                    if fileManager.fileExists(atPath: markerURL.path) {
                        try finishRemoval(at: entry)
                    } else {
                        try Self.validatePrivateDirectory(entry, owner: owner)
                        guard try safeDirectoryContents(at: entry).isEmpty,
                              rmdir(entry.path) == 0 else {
                            throw NetworkHelperError.quarantined
                        }
                    }
                    continue
                }
                guard Self.isCanonicalUUID(entry.lastPathComponent) else {
                    throw NetworkHelperError.quarantined
                }
                let markerURL = entry.appendingPathComponent(
                    "removal.json",
                    isDirectory: false
                )
                if fileManager.fileExists(atPath: markerURL.path) {
                    let marker: NetworkHelperRemovalMarker = try loadCanonical(
                        NetworkHelperRemovalMarker.self,
                        from: markerURL
                    )
                    guard marker.schemaVersion == 1,
                          marker.projectUUID == projectURL.lastPathComponent,
                          marker.dnsUUID == entry.lastPathComponent else {
                        throw NetworkHelperError.quarantined
                    }
                    let removingURL = projectURL.appendingPathComponent(
                        ".removing-\(marker.dnsUUID)-\(UUID().uuidString.lowercased())",
                        isDirectory: true
                    )
                    guard rename(entry.path, removingURL.path) == 0 else {
                        throw NetworkHelperError.ioFailure
                    }
                    try finishRemoval(at: removingURL)
                    continue
                }
                try recoverDNSRoot(
                    entry,
                    projectUUID: projectURL.lastPathComponent,
                    dnsUUID: entry.lastPathComponent,
                    recoverInterruptedCertificateIntent:
                        recoverInterruptedCertificateIntent
                )
            }
            try removeDirectoryIfEmpty(projectURL)
        }
    }

    private func recoverDNSRoot(
        _ dnsRoot: URL,
        projectUUID: String,
        dnsUUID: String,
        recoverInterruptedCertificateIntent: Bool
    ) throws {
        try Self.validatePrivateDirectory(dnsRoot, owner: owner)
        let generations = dnsRoot.appendingPathComponent(
            "generations",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: generations.path) else {
            throw NetworkHelperError.quarantined
        }
        try Self.validatePrivateDirectory(generations, owner: owner)

        for entry in try safeDirectoryContents(at: generations)
            where entry.lastPathComponent.hasPrefix(".pending-") {
            let suffix = String(entry.lastPathComponent.dropFirst(".pending-".count))
            guard Self.isCanonicalUUID(suffix) else {
                throw NetworkHelperError.quarantined
            }
            let metadataURL = entry.appendingPathComponent(
                "metadata.json",
                isDirectory: false
            )
            if fileManager.fileExists(atPath: metadataURL.path) {
                let metadata = try loadMetadataIfIncomplete(from: entry)
                guard metadata.identity.projectUUID == projectUUID,
                      metadata.identity.dnsUUID == dnsUUID else {
                    throw NetworkHelperError.quarantined
                }
            }
            try removeGenerationDirectory(entry)
        }

        for entry in try safeDirectoryContents(at: dnsRoot)
            where entry.lastPathComponent.hasPrefix(".current-") {
            let suffix = String(entry.lastPathComponent.dropFirst(".current-".count))
            guard Self.isCanonicalUUID(suffix) else {
                throw NetworkHelperError.quarantined
            }
            try removeRegularFileIfPresent(entry)
        }
        for entry in try safeDirectoryContents(at: dnsRoot)
            where entry.lastPathComponent.hasPrefix(
                ".certificate-evidence-"
            ) {
            let suffix = String(
                entry.lastPathComponent.dropFirst(
                    ".certificate-evidence-".count
                )
            )
            guard Self.isCanonicalUUID(suffix) else {
                throw NetworkHelperError.quarantined
            }
            try removeRegularFileIfPresent(entry)
        }
        for entry in try safeDirectoryContents(at: dnsRoot)
            where entry.lastPathComponent.hasPrefix(
                ".certificate-pending-"
            ) {
            let suffix = String(
                entry.lastPathComponent.dropFirst(
                    ".certificate-pending-".count
                )
            )
            guard Self.isCanonicalUUID(suffix) else {
                throw NetworkHelperError.quarantined
            }
            try removeRegularFileIfPresent(entry)
        }

        let pointerURL = dnsRoot.appendingPathComponent(
            "current.json",
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: pointerURL.path) else {
            let active = dnsRoot.appendingPathComponent(
                "active",
                isDirectory: true
            )
            try cleanActiveTemporaryFiles(at: active)
            if try safeDirectoryContents(at: generations).isEmpty,
               try safeDirectoryContents(at: active).isEmpty,
               !fileManager.fileExists(
                    atPath: certificateEvidenceURL(
                        dnsRoot: dnsRoot
                    ).path
               ),
               !fileManager.fileExists(
                    atPath: retiredCertificateEvidenceURL(
                        dnsRoot: dnsRoot
                    ).path
               ),
               !fileManager.fileExists(
                    atPath: pendingCertificateReplacementURL(
                        dnsRoot: dnsRoot
                    ).path
               ) {
                return
            }
            throw NetworkHelperError.quarantined
        }
        var pointer: NetworkHelperCurrentPointer = try loadCanonical(
            NetworkHelperCurrentPointer.self,
            from: pointerURL
        )
        guard [1, 2, 3, 4, 5].contains(pointer.schemaVersion),
              pointer.identity.projectUUID == projectUUID,
              pointer.identity.dnsUUID == dnsUUID else {
            throw NetworkHelperError.quarantined
        }
        _ = try pointer.identity.validated()
        try validateGeneration(
            at: generationURL(
                dnsRoot: dnsRoot,
                generation: pointer.identity.generation
            ),
            expected: pointer
        )
        let retiredURL = retiredCertificateEvidenceURL(
            dnsRoot: dnsRoot
        )
        if recoverInterruptedCertificateIntent,
           let rawPending = try pendingCertificateReplacementLocked(
            dnsRoot: dnsRoot
        ), let requestSHA256 = pointer.certificateSHA256 {
            let pending = try validatedPendingCertificateReplacement(
                rawPending,
                expectedIdentity: pointer.identity,
                expectedRequestSHA256: requestSHA256,
                dnsRoot: dnsRoot
            )
            if pending.phase == .intent,
           let expectedPrior = pending.priorEvidenceSHA256,
           fileManager.fileExists(atPath: retiredURL.path) {
            let retired: NetworkHelperPersistedCertificateEvidence =
                try loadCanonical(
                    NetworkHelperPersistedCertificateEvidence.self,
                    from: retiredURL
                )
            _ = try validatedRetiredCertificateEvidence(retired)
            guard Self.sha256(
                try NetworkHelperCanonicalJSON.encode(retired)
            ) == expectedPrior,
                  retired.identity.projectUUID == projectUUID,
                  retired.identity.dnsUUID == dnsUUID,
                  retired.identity.generation <
                    pointer.identity.generation else {
                throw NetworkHelperError.quarantined
            }
            let priorGenerationURL = generationURL(
                dnsRoot: dnsRoot,
                generation: retired.identity.generation
            )
            guard fileManager.fileExists(
                atPath: priorGenerationURL.path
            ) else {
                throw NetworkHelperError.quarantined
            }
            let priorMetadata: NetworkHelperPersistedMetadata =
                try loadCanonical(
                    NetworkHelperPersistedMetadata.self,
                    from: priorGenerationURL.appendingPathComponent(
                        "metadata.json",
                        isDirectory: false
                    )
                )
            let priorPointer = NetworkHelperCurrentPointer(
                metadata: priorMetadata
            )
            guard priorPointer.identity == retired.identity,
                  priorPointer.certificateSHA256 ==
                    retired.requestSHA256 else {
                throw NetworkHelperError.quarantined
            }
            try validateGeneration(
                at: priorGenerationURL,
                expected: priorPointer
            )
            let interruptedGeneration = pointer.identity.generation
            try replaceCurrentPointer(
                priorPointer,
                dnsRoot: dnsRoot
            )
            try refreshActiveCorefile(
                pointer: priorPointer,
                dnsRoot: dnsRoot
            )
            let currentEvidenceURL = certificateEvidenceURL(
                dnsRoot: dnsRoot
            )
            guard !fileManager.fileExists(
                atPath: currentEvidenceURL.path
            ), rename(
                retiredURL.path,
                currentEvidenceURL.path
            ) == 0 else {
                throw NetworkHelperError.quarantined
            }
            try removeRegularFileIfPresent(
                pendingCertificateReplacementURL(
                    dnsRoot: dnsRoot
                )
            )
            if interruptedGeneration !=
                priorPointer.identity.generation {
                try removeGenerationDirectory(
                    generationURL(
                        dnsRoot: dnsRoot,
                        generation: interruptedGeneration
                    )
                )
            }
            try synchronizeDirectory(dnsRoot)
            pointer = priorPointer
            }
        }
        try refreshActiveCorefile(pointer: pointer, dnsRoot: dnsRoot)
        let currentEvidenceURL = certificateEvidenceURL(
            dnsRoot: dnsRoot
        )
        if !fileManager.fileExists(atPath: currentEvidenceURL.path),
           fileManager.fileExists(atPath: retiredURL.path) {
            let retired: NetworkHelperPersistedCertificateEvidence =
                try loadCanonical(
                    NetworkHelperPersistedCertificateEvidence.self,
                    from: retiredURL
                )
            if retired.identity == pointer.identity,
               retired.requestSHA256 == pointer.certificateSHA256 {
                _ = try validatedRetiredCertificateEvidence(retired)
                guard rename(
                    retiredURL.path,
                    currentEvidenceURL.path
                ) == 0 else {
                    throw NetworkHelperError.ioFailure
                }
                try synchronizeDirectory(dnsRoot)
            }
        }
        try validateCurrentCertificateEvidenceIfPresent(
            pointer: pointer,
            dnsRoot: dnsRoot
        )
        if fileManager.fileExists(atPath: retiredURL.path) {
            let retired: NetworkHelperPersistedCertificateEvidence =
                try loadCanonical(
                    NetworkHelperPersistedCertificateEvidence.self,
                    from: retiredURL
                )
            _ = try validatedRetiredCertificateEvidence(retired)
        }
        if let pending = try pendingCertificateReplacementLocked(
            dnsRoot: dnsRoot
        ) {
            let validated = try validatedPendingCertificateReplacement(
                pending,
                expectedIdentity: pointer.identity,
                expectedRequestSHA256:
                    pending.requestSHA256,
                dnsRoot: dnsRoot
            )
            guard validated.requestSHA256 ==
                    pointer.certificateSHA256 else {
                throw NetworkHelperError.quarantined
            }
            if let replacement = validated.replacement,
               fileManager.fileExists(
                    atPath: currentEvidenceURL.path
               ) {
                let current:
                    NetworkHelperPersistedCertificateEvidence =
                    try loadCanonical(
                        NetworkHelperPersistedCertificateEvidence.self,
                        from: currentEvidenceURL
                    )
                if current == replacement {
                    try removeRegularFileIfPresent(
                        pendingCertificateReplacementURL(
                            dnsRoot: dnsRoot
                        )
                    )
                    try synchronizeDirectory(dnsRoot)
                }
            }
        }
        if try pendingCertificateReplacementLocked(
            dnsRoot: dnsRoot
        ) == nil,
           !fileManager.fileExists(atPath: retiredURL.path) {
            try removeSupersededGenerations(
                dnsRoot: dnsRoot,
                keeping: pointer.identity.generation,
                projectUUID: projectUUID,
                dnsUUID: dnsUUID
            )
        }
    }

    private func currentStatusLocked(
        requestedIdentity: NetworkHelperDNSIdentity,
        dnsRoot: URL
    ) throws -> NetworkHelperStatus {
        do {
            try Self.validatePrivateDirectory(dnsRoot, owner: owner)
            let pointerURL = dnsRoot.appendingPathComponent(
                "current.json",
                isDirectory: false
            )
            guard fileManager.fileExists(atPath: pointerURL.path) else {
                let generations = dnsRoot.appendingPathComponent(
                    "generations",
                    isDirectory: true
                )
                if fileManager.fileExists(atPath: generations.path),
                   try safeDirectoryContents(at: generations).isEmpty {
                    return NetworkHelperStatus(
                        disposition: .absent,
                        identity: nil,
                        corefileSHA256: nil,
                        reason: nil
                    )
                }
                return quarantinedStatus("current generation is missing")
            }
            let pointer: NetworkHelperCurrentPointer = try loadCanonical(
                NetworkHelperCurrentPointer.self,
                from: pointerURL
            )
            guard [1, 2, 3, 4, 5].contains(pointer.schemaVersion) else {
                return quarantinedStatus("metadata schema is unsupported")
            }
            _ = try pointer.identity.validated()
            try validateGeneration(
                at: generationURL(
                    dnsRoot: dnsRoot,
                    generation: pointer.identity.generation
                ),
                expected: pointer
            )
            try validateActiveCorefile(
                pointer: pointer,
                dnsRoot: dnsRoot
            )
            return NetworkHelperStatus(
                disposition: pointer.identity == requestedIdentity
                    ? .active
                    : .conflict,
                identity: pointer.identity,
                corefileSHA256: pointer.corefileSHA256,
                hostAccessSHA256: pointer.hostAccessSHA256,
                ingressSHA256: pointer.ingressSHA256,
                certificateSHA256: pointer.certificateSHA256,
                policySHA256: pointer.policySHA256,
                reason: pointer.identity == requestedIdentity
                    ? nil
                    : "active DNS generation has different ownership"
            )
        } catch let error as NetworkHelperError {
            if error == .unsafePath {
                throw error
            }
            return quarantinedStatus("persisted DNS metadata is invalid")
        } catch {
            return quarantinedStatus("persisted DNS metadata is invalid")
        }
    }

    private func ensureDNSRoot(
        for identity: NetworkHelperDNSIdentity
    ) throws -> URL {
        let projectRoot = rootURL.appendingPathComponent(
            identity.projectUUID,
            isDirectory: true
        )
        try Self.preparePrivateDirectory(
            projectRoot,
            owner: owner,
            requireSafeParent: false
        )
        let dnsRoot = projectRoot.appendingPathComponent(
            identity.dnsUUID,
            isDirectory: true
        )
        try Self.preparePrivateDirectory(
            dnsRoot,
            owner: owner,
            requireSafeParent: false
        )
        try Self.preparePrivateDirectory(
            dnsRoot.appendingPathComponent("generations", isDirectory: true),
            owner: owner,
            requireSafeParent: false
        )
        try Self.preparePrivateDirectory(
            dnsRoot.appendingPathComponent("active", isDirectory: true),
            owner: owner,
            requireSafeParent: false
        )
        return dnsRoot
    }

    private func dnsRootURL(for identity: NetworkHelperDNSIdentity) -> URL {
        rootURL
            .appendingPathComponent(identity.projectUUID, isDirectory: true)
            .appendingPathComponent(identity.dnsUUID, isDirectory: true)
    }

    private func certificateEvidenceURL(dnsRoot: URL) -> URL {
        dnsRoot.appendingPathComponent(
            "certificate-evidence.json",
            isDirectory: false
        )
    }

    private func retiredCertificateEvidenceURL(dnsRoot: URL) -> URL {
        dnsRoot.appendingPathComponent(
            "certificate-retired.json",
            isDirectory: false
        )
    }

    private func pendingCertificateReplacementURL(dnsRoot: URL) -> URL {
        dnsRoot.appendingPathComponent(
            "certificate-pending.json",
            isDirectory: false
        )
    }

    private func pendingCertificateReplacementLocked(
        dnsRoot: URL
    ) throws -> NetworkHelperPendingCertificateReplacement? {
        let url = pendingCertificateReplacementURL(dnsRoot: dnsRoot)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try loadCanonical(
            NetworkHelperPendingCertificateReplacement.self,
            from: url
        )
    }

    private func currentOrRetiredCertificateEvidence(
        dnsRoot: URL
    ) throws -> NetworkHelperPersistedCertificateEvidence? {
        for url in [
            certificateEvidenceURL(dnsRoot: dnsRoot),
            retiredCertificateEvidenceURL(dnsRoot: dnsRoot),
        ] where fileManager.fileExists(atPath: url.path) {
            let evidence: NetworkHelperPersistedCertificateEvidence =
                try loadCanonical(
                    NetworkHelperPersistedCertificateEvidence.self,
                    from: url
                )
            _ = try validatedRetiredCertificateEvidence(evidence)
            return evidence
        }
        return nil
    }

    private func replacePendingCertificateReplacement(
        _ pending: NetworkHelperPendingCertificateReplacement,
        dnsRoot: URL
    ) throws {
        let temporary = dnsRoot.appendingPathComponent(
            ".certificate-pending-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        try writeExclusive(
            try NetworkHelperCanonicalJSON.encode(pending),
            to: temporary
        )
        guard rename(
            temporary.path,
            pendingCertificateReplacementURL(dnsRoot: dnsRoot).path
        ) == 0 else {
            _ = unlink(temporary.path)
            throw NetworkHelperError.ioFailure
        }
        try synchronizeDirectory(dnsRoot)
    }

    private func validatedPendingCertificateReplacement(
        _ pending: NetworkHelperPendingCertificateReplacement,
        expectedIdentity: NetworkHelperDNSIdentity,
        expectedRequestSHA256: String,
        dnsRoot: URL
    ) throws -> NetworkHelperPendingCertificateReplacement {
        guard pending.schemaVersion == 1,
              pending.identity == expectedIdentity,
              pending.requestSHA256 == expectedRequestSHA256,
              Self.isCanonicalSHA256(pending.requestSHA256),
              pending.priorEvidenceSHA256.map(Self.isCanonicalSHA256)
                ?? true else {
            throw NetworkHelperError.quarantined
        }
        switch pending.phase {
        case .intent:
            guard pending.replacement == nil else {
                throw NetworkHelperError.quarantined
            }
        case .verified:
            guard let replacement = pending.replacement else {
                throw NetworkHelperError.quarantined
            }
            _ = try validatedCertificateEvidence(
                replacement,
                expectedIdentity: expectedIdentity,
                expectedRequestSHA256: expectedRequestSHA256,
                expectedBindings: try certificateBindings(
                    dnsRoot: dnsRoot,
                    expectedSHA256: expectedRequestSHA256
                )
            )
        }
        if let expectedPrior = pending.priorEvidenceSHA256 {
            var foundPrior = false
            for url in [
                certificateEvidenceURL(dnsRoot: dnsRoot),
                retiredCertificateEvidenceURL(dnsRoot: dnsRoot),
            ] where fileManager.fileExists(atPath: url.path) {
                let evidence:
                    NetworkHelperPersistedCertificateEvidence =
                    try loadCanonical(
                        NetworkHelperPersistedCertificateEvidence.self,
                        from: url
                    )
                if Self.sha256(
                    try NetworkHelperCanonicalJSON.encode(evidence)
                ) == expectedPrior {
                    foundPrior = true
                    break
                }
            }
            guard foundPrior else {
                throw NetworkHelperError.quarantined
            }
        }
        return pending
    }

    private func retireCertificateEvidenceIfPresent(
        dnsRoot: URL
    ) throws {
        let active = certificateEvidenceURL(dnsRoot: dnsRoot)
        guard fileManager.fileExists(atPath: active.path) else {
            return
        }
        let retired = retiredCertificateEvidenceURL(dnsRoot: dnsRoot)
        guard !fileManager.fileExists(atPath: retired.path) else {
            throw NetworkHelperError.conflict
        }
        let evidence: NetworkHelperPersistedCertificateEvidence =
            try loadCanonical(
                NetworkHelperPersistedCertificateEvidence.self,
                from: active
            )
        _ = try validatedRetiredCertificateEvidence(evidence)
        guard rename(active.path, retired.path) == 0 else {
            throw NetworkHelperError.ioFailure
        }
        try synchronizeDirectory(dnsRoot)
    }

    private func validateCurrentCertificateEvidenceIfPresent(
        pointer: NetworkHelperCurrentPointer,
        dnsRoot: URL
    ) throws {
        let url = certificateEvidenceURL(dnsRoot: dnsRoot)
        guard fileManager.fileExists(atPath: url.path) else { return }
        let evidence: NetworkHelperPersistedCertificateEvidence =
            try loadCanonical(
                NetworkHelperPersistedCertificateEvidence.self,
                from: url
            )
        _ = try validatedCertificateEvidence(
            evidence,
            expectedIdentity: pointer.identity,
            expectedRequestSHA256: pointer.certificateSHA256,
            expectedBindings: try certificateBindings(
                dnsRoot: dnsRoot,
                expectedSHA256: pointer.certificateSHA256
            )
        )
    }

    private func stageGeneration(
        metadata: NetworkHelperPersistedMetadata,
        corefile: Data,
        hostAccess: Data?,
        ingress: Data?,
        certificates: Data?,
        policy: Data?,
        dnsRoot: URL
    ) throws {
        let generations = dnsRoot.appendingPathComponent(
            "generations",
            isDirectory: true
        )
        let destination = generationURL(
            dnsRoot: dnsRoot,
            generation: metadata.identity.generation
        )
        if fileManager.fileExists(atPath: destination.path) {
            let pointer = NetworkHelperCurrentPointer(metadata: metadata)
            try validateGeneration(at: destination, expected: pointer)
            return
        }

        let staging = generations.appendingPathComponent(
            ".pending-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard mkdir(staging.path, S_IRWXU) == 0,
              chmod(staging.path, S_IRWXU) == 0 else {
            throw NetworkHelperError.ioFailure
        }
        var shouldRemove = true
        defer {
            if shouldRemove {
                try? removeGenerationDirectory(staging)
            }
        }
        try writeExclusive(
            try NetworkHelperCanonicalJSON.encode(metadata),
            to: staging.appendingPathComponent(
                "metadata.json",
                isDirectory: false
            )
        )
        try writeExclusive(
            corefile,
            to: staging.appendingPathComponent("Corefile", isDirectory: false)
        )
        if let hostAccess {
            try writeExclusive(
                hostAccess,
                to: staging.appendingPathComponent(
                    "HostAccess.json",
                    isDirectory: false
                )
            )
        }
        if let ingress {
            try writeExclusive(
                ingress,
                to: staging.appendingPathComponent(
                    "Ingress.json",
                    isDirectory: false
                )
            )
        }
        if let certificates {
            try writeExclusive(certificates, to: staging.appendingPathComponent("Certificate.json", isDirectory: false))
        }
        if let policy {
            try writeExclusive(
                policy,
                to: staging.appendingPathComponent("Policy.json", isDirectory: false)
            )
        }
        try synchronizeDirectory(staging)
        guard rename(staging.path, destination.path) == 0 else {
            throw NetworkHelperError.ioFailure
        }
        shouldRemove = false
        try synchronizeDirectory(generations)
    }

    private func replaceCurrentPointer(
        _ pointer: NetworkHelperCurrentPointer,
        dnsRoot: URL
    ) throws {
        let destination = dnsRoot.appendingPathComponent(
            "current.json",
            isDirectory: false
        )
        let temporary = dnsRoot.appendingPathComponent(
            ".current-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        try writeExclusive(
            try NetworkHelperCanonicalJSON.encode(pointer),
            to: temporary
        )
        guard rename(temporary.path, destination.path) == 0 else {
            _ = unlink(temporary.path)
            throw NetworkHelperError.ioFailure
        }
        try synchronizeDirectory(dnsRoot)
    }

    private func refreshActiveCorefile(
        pointer: NetworkHelperCurrentPointer,
        dnsRoot: URL
    ) throws {
        let active = dnsRoot.appendingPathComponent(
            "active",
            isDirectory: true
        )
        try Self.preparePrivateDirectory(
            active,
            owner: owner,
            requireSafeParent: false
        )
        try cleanActiveTemporaryFiles(at: active)

        let source = generationURL(
            dnsRoot: dnsRoot,
            generation: pointer.identity.generation
        ).appendingPathComponent("Corefile", isDirectory: false)
        let sourceData = try loadRegularFile(source)
        guard Self.sha256(sourceData) == pointer.corefileSHA256 else {
            throw NetworkHelperError.quarantined
        }

        let destination = active.appendingPathComponent(
            "Corefile",
            isDirectory: false
        )
        let currentCorefileMatches: Bool
        if fileManager.fileExists(atPath: destination.path) {
            currentCorefileMatches =
                Self.sha256(try loadRegularFile(destination))
                == pointer.corefileSHA256
        } else {
            currentCorefileMatches = false
        }
        let activeHostAccess = active.appendingPathComponent(
            "HostAccess.json",
            isDirectory: false
        )
        let currentHostAccessMatches: Bool
        if let expected = pointer.hostAccessSHA256 {
            if fileManager.fileExists(atPath: activeHostAccess.path) {
                currentHostAccessMatches =
                    Self.sha256(try loadRegularFile(activeHostAccess))
                    == expected
            } else {
                currentHostAccessMatches = false
            }
        } else {
            currentHostAccessMatches =
                !fileManager.fileExists(atPath: activeHostAccess.path)
        }
        let activeIngress = active.appendingPathComponent(
            "Ingress.json",
            isDirectory: false
        )
        let activeCertificate = active.appendingPathComponent("Certificate.json", isDirectory: false)
        let activePolicy = active.appendingPathComponent(
            "Policy.json", isDirectory: false
        )
        let currentCertificateMatches: Bool
        if let expected = pointer.certificateSHA256 {
            if fileManager.fileExists(atPath: activeCertificate.path) {
                currentCertificateMatches =
                    Self.sha256(try loadRegularFile(activeCertificate)) == expected
            } else {
                currentCertificateMatches = false
            }
        } else {
            currentCertificateMatches = !fileManager.fileExists(atPath: activeCertificate.path)
        }
        let currentIngressMatches: Bool
        if let expected = pointer.ingressSHA256 {
            if fileManager.fileExists(atPath: activeIngress.path) {
                currentIngressMatches =
                    Self.sha256(try loadRegularFile(activeIngress)) == expected
            } else {
                currentIngressMatches = false
            }
        } else {
            currentIngressMatches = !fileManager.fileExists(atPath: activeIngress.path)
        }
        let currentPolicyMatches: Bool
        if let expected = pointer.policySHA256 {
            if fileManager.fileExists(atPath: activePolicy.path) {
                let plan = try NetworkHelperCanonicalJSON.decode(
                    NetworkPolicyPlan.self,
                    from: loadRegularFile(activePolicy)
                )
                currentPolicyMatches = plan.sha256 == expected
            } else {
                currentPolicyMatches = false
            }
        } else {
            currentPolicyMatches = !fileManager.fileExists(atPath: activePolicy.path)
        }
        if currentCorefileMatches && currentHostAccessMatches && currentIngressMatches && currentCertificateMatches && currentPolicyMatches {
            return
        }
        let temporary = active.appendingPathComponent(
            ".Corefile-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        try writeExclusive(sourceData, to: temporary)
        guard rename(temporary.path, destination.path) == 0 else {
            _ = unlink(temporary.path)
            throw NetworkHelperError.ioFailure
        }
        if let expected = pointer.hostAccessSHA256 {
            let sourceHostAccess = generationURL(
                dnsRoot: dnsRoot,
                generation: pointer.identity.generation
            ).appendingPathComponent(
                "HostAccess.json",
                isDirectory: false
            )
            let hostAccessData = try loadRegularFile(sourceHostAccess)
            guard Self.sha256(hostAccessData) == expected else {
                throw NetworkHelperError.quarantined
            }
            let temporaryHostAccess = active.appendingPathComponent(
                ".HostAccess-\(UUID().uuidString.lowercased())",
                isDirectory: false
            )
            try writeExclusive(hostAccessData, to: temporaryHostAccess)
            guard rename(
                temporaryHostAccess.path,
                activeHostAccess.path
            ) == 0 else {
                _ = unlink(temporaryHostAccess.path)
                throw NetworkHelperError.ioFailure
            }
        } else {
            try removeRegularFileIfPresent(activeHostAccess)
        }
        if let expected = pointer.ingressSHA256 {
            let sourceIngress = generationURL(
                dnsRoot: dnsRoot,
                generation: pointer.identity.generation
            ).appendingPathComponent("Ingress.json", isDirectory: false)
            let ingressData = try loadRegularFile(sourceIngress)
            guard Self.sha256(ingressData) == expected else {
                throw NetworkHelperError.quarantined
            }
            let temporaryIngress = active.appendingPathComponent(
                ".Ingress-\(UUID().uuidString.lowercased())",
                isDirectory: false
            )
            try writeExclusive(ingressData, to: temporaryIngress)
            guard rename(temporaryIngress.path, activeIngress.path) == 0 else {
                _ = unlink(temporaryIngress.path)
                throw NetworkHelperError.ioFailure
            }
        } else {
            try removeRegularFileIfPresent(activeIngress)
        }
        if let expected = pointer.certificateSHA256 {
            let sourceCertificate = generationURL(dnsRoot: dnsRoot, generation: pointer.identity.generation).appendingPathComponent("Certificate.json", isDirectory: false)
            let certificateData = try loadRegularFile(sourceCertificate)
            guard Self.sha256(certificateData) == expected else { throw NetworkHelperError.quarantined }
            let temporaryCertificate = active.appendingPathComponent(".Certificate-\(UUID().uuidString.lowercased())", isDirectory: false)
            try writeExclusive(certificateData, to: temporaryCertificate)
            guard rename(temporaryCertificate.path, activeCertificate.path) == 0 else { _ = unlink(temporaryCertificate.path); throw NetworkHelperError.ioFailure }
        } else {
            try removeRegularFileIfPresent(activeCertificate)
        }
        if let expected = pointer.policySHA256 {
            let sourcePolicy = generationURL(
                dnsRoot: dnsRoot,
                generation: pointer.identity.generation
            ).appendingPathComponent("Policy.json", isDirectory: false)
            let policyData = try loadRegularFile(sourcePolicy)
            let plan = try NetworkHelperCanonicalJSON.decode(
                NetworkPolicyPlan.self,
                from: policyData
            )
            try NetworkHelperPolicyBroker.validated(
                plan: plan,
                identity: pointer.identity
            )
            guard plan.sha256 == expected else {
                throw NetworkHelperError.quarantined
            }
            let temporaryPolicy = active.appendingPathComponent(
                ".Policy-\(UUID().uuidString.lowercased())",
                isDirectory: false
            )
            try writeExclusive(policyData, to: temporaryPolicy)
            guard rename(temporaryPolicy.path, activePolicy.path) == 0 else {
                _ = unlink(temporaryPolicy.path)
                throw NetworkHelperError.ioFailure
            }
        } else {
            try removeRegularFileIfPresent(activePolicy)
        }
        try synchronizeDirectory(active)
        try validateActiveCorefile(pointer: pointer, dnsRoot: dnsRoot)
    }

    private func validateActiveCorefile(
        pointer: NetworkHelperCurrentPointer,
        dnsRoot: URL
    ) throws {
        let active = dnsRoot.appendingPathComponent(
            "active",
            isDirectory: true
        )
        try Self.validatePrivateDirectory(active, owner: owner)
        let entries = try safeDirectoryContents(at: active)
        var expectedEntries = Set(["Corefile"])
        if pointer.hostAccessSHA256 != nil {
            expectedEntries.insert("HostAccess.json")
        }
        if pointer.ingressSHA256 != nil {
            expectedEntries.insert("Ingress.json")
        }
        if pointer.certificateSHA256 != nil { expectedEntries.insert("Certificate.json") }
        if pointer.policySHA256 != nil { expectedEntries.insert("Policy.json") }
        guard Set(entries.map(\.lastPathComponent)) == expectedEntries else {
            throw NetworkHelperError.quarantined
        }
        let data = try loadRegularFile(
            active.appendingPathComponent("Corefile", isDirectory: false)
        )
        guard Self.sha256(data) == pointer.corefileSHA256 else {
            throw NetworkHelperError.quarantined
        }
        if let expected = pointer.hostAccessSHA256 {
            let hostAccess = try loadRegularFile(
                active.appendingPathComponent(
                    "HostAccess.json",
                    isDirectory: false
                )
            )
            guard Self.sha256(hostAccess) == expected else {
                throw NetworkHelperError.quarantined
            }
            _ = try NetworkHelperCanonicalJSON.decode(
                [ProjectDNSHostAccessBinding].self,
                from: hostAccess
            )
        }
        if let expected = pointer.ingressSHA256 {
            let ingress = try loadRegularFile(
                active.appendingPathComponent("Ingress.json", isDirectory: false)
            )
            guard Self.sha256(ingress) == expected else {
                throw NetworkHelperError.quarantined
            }
            _ = try NetworkHelperIngressValidation.validated(
                try NetworkHelperCanonicalJSON.decode(
                    [ProjectIngressListenerBinding].self,
                    from: ingress
                )
            )
        }
        if let expected = pointer.certificateSHA256 {
            let certificate = try loadRegularFile(active.appendingPathComponent("Certificate.json", isDirectory: false))
            guard Self.sha256(certificate) == expected else { throw NetworkHelperError.quarantined }
            _ = try NetworkHelperCertificateValidation.validated(try NetworkHelperCanonicalJSON.decode([ProjectCertificateRequestBinding].self, from: certificate))
        }
        if let expected = pointer.policySHA256 {
            let policy = try loadRegularFile(
                active.appendingPathComponent("Policy.json", isDirectory: false)
            )
            let plan = try NetworkHelperCanonicalJSON.decode(
                NetworkPolicyPlan.self,
                from: policy
            )
            try NetworkHelperPolicyBroker.validated(
                plan: plan,
                identity: pointer.identity
            )
            guard plan.sha256 == expected else {
                throw NetworkHelperError.quarantined
            }
        }
    }

    private func cleanActiveTemporaryFiles(at active: URL) throws {
        try Self.validatePrivateDirectory(active, owner: owner)
        for entry in try safeDirectoryContents(at: active)
            where entry.lastPathComponent.hasPrefix(".Corefile-")
                || entry.lastPathComponent.hasPrefix(".HostAccess-")
                || entry.lastPathComponent.hasPrefix(".Ingress-")
                || entry.lastPathComponent.hasPrefix(".Certificate-")
                || entry.lastPathComponent.hasPrefix(".Policy-") {
            let prefix = entry.lastPathComponent.hasPrefix(".Corefile-")
                ? ".Corefile-"
                : entry.lastPathComponent.hasPrefix(".HostAccess-")
                    ? ".HostAccess-"
                    : entry.lastPathComponent.hasPrefix(".Ingress-")
                        ? ".Ingress-"
                        : entry.lastPathComponent.hasPrefix(".Certificate-")
                            ? ".Certificate-" : ".Policy-"
            let suffix = String(
                entry.lastPathComponent.dropFirst(prefix.count)
            )
            guard Self.isCanonicalUUID(suffix) else {
                throw NetworkHelperError.quarantined
            }
            try removeRegularFileIfPresent(entry)
        }
    }

    private func validateGeneration(
        at generationURL: URL,
        expected: NetworkHelperCurrentPointer
    ) throws {
        let metadata = try loadMetadata(from: generationURL)
        guard [1, 2, 3, 4, 5].contains(metadata.schemaVersion),
              metadata.schemaVersion == Self.schemaVersion(
                hostAccessSHA256: metadata.hostAccessSHA256,
                ingressSHA256: metadata.ingressSHA256,
                certificateSHA256: metadata.certificateSHA256,
                policySHA256: metadata.policySHA256
              ),
              metadata.identity == expected.identity,
              metadata.corefileSHA256 == expected.corefileSHA256,
              metadata.hostAccessSHA256
                == expected.hostAccessSHA256,
              metadata.ingressSHA256 == expected.ingressSHA256 else {
            throw NetworkHelperError.quarantined
        }
        guard metadata.certificateSHA256 == expected.certificateSHA256,
              metadata.policySHA256 == expected.policySHA256 else {
            throw NetworkHelperError.quarantined
        }
        let corefileURL = generationURL.appendingPathComponent(
            "Corefile",
            isDirectory: false
        )
        let corefile = try loadRegularFile(corefileURL)
        guard Self.sha256(corefile) == metadata.corefileSHA256 else {
            throw NetworkHelperError.quarantined
        }
        if let expectedHostAccess = metadata.hostAccessSHA256 {
            let hostAccess = try loadRegularFile(
                generationURL.appendingPathComponent(
                    "HostAccess.json",
                    isDirectory: false
                )
            )
            guard Self.sha256(hostAccess) == expectedHostAccess else {
                throw NetworkHelperError.quarantined
            }
            let bindings = try NetworkHelperCanonicalJSON.decode(
                [ProjectDNSHostAccessBinding].self,
                from: hostAccess
            )
            _ = try NetworkHelperHostAccessValidation.validated(bindings)
        }
        if let expectedIngress = metadata.ingressSHA256 {
            let ingress = try loadRegularFile(
                generationURL.appendingPathComponent("Ingress.json", isDirectory: false)
            )
            guard Self.sha256(ingress) == expectedIngress else {
                throw NetworkHelperError.quarantined
            }
            _ = try NetworkHelperIngressValidation.validated(
                try NetworkHelperCanonicalJSON.decode(
                    [ProjectIngressListenerBinding].self,
                    from: ingress
                )
            )
        }
        if let expectedCertificate = metadata.certificateSHA256 {
            let certificate = try loadRegularFile(generationURL.appendingPathComponent("Certificate.json", isDirectory: false))
            guard Self.sha256(certificate) == expectedCertificate else { throw NetworkHelperError.quarantined }
            _ = try NetworkHelperCertificateValidation.validated(try NetworkHelperCanonicalJSON.decode([ProjectCertificateRequestBinding].self, from: certificate))
        }
        if let expectedPolicy = metadata.policySHA256 {
            let policy = try loadRegularFile(
                generationURL.appendingPathComponent("Policy.json", isDirectory: false)
            )
            let plan = try NetworkHelperCanonicalJSON.decode(
                NetworkPolicyPlan.self,
                from: policy
            )
            try NetworkHelperPolicyBroker.validated(
                plan: plan,
                identity: metadata.identity
            )
            guard plan.sha256 == expectedPolicy else {
                throw NetworkHelperError.quarantined
            }
        }
    }

    private func loadMetadata(
        from generationURL: URL
    ) throws -> NetworkHelperPersistedMetadata {
        try Self.validatePrivateDirectory(generationURL, owner: owner)
        let entries = try safeDirectoryContents(at: generationURL)
        guard Set(entries.map(\.lastPathComponent))
            .isSubset(of: Set([
                "metadata.json",
                "Corefile",
                "HostAccess.json",
                "Ingress.json",
                "Certificate.json",
                "Policy.json"
            ])) else {
            throw NetworkHelperError.quarantined
        }
        let metadata: NetworkHelperPersistedMetadata = try loadCanonical(
            NetworkHelperPersistedMetadata.self,
            from: generationURL.appendingPathComponent(
                "metadata.json",
                isDirectory: false
            )
        )
        _ = try metadata.identity.validated()
        var expectedEntries = Set(["metadata.json", "Corefile"])
        if metadata.hostAccessSHA256 != nil {
            expectedEntries.insert("HostAccess.json")
        }
        if metadata.ingressSHA256 != nil {
            expectedEntries.insert("Ingress.json")
        }
        if metadata.certificateSHA256 != nil { expectedEntries.insert("Certificate.json") }
        if metadata.policySHA256 != nil { expectedEntries.insert("Policy.json") }
        guard Set(entries.map(\.lastPathComponent)) == expectedEntries
        else {
            throw NetworkHelperError.quarantined
        }
        return metadata
    }

    private func loadMetadataIfIncomplete(
        from generationURL: URL
    ) throws -> NetworkHelperPersistedMetadata {
        try Self.validatePrivateDirectory(generationURL, owner: owner)
        let entries = try safeDirectoryContents(at: generationURL)
        guard Set(entries.map(\.lastPathComponent))
            .isSubset(of: Set([
                "metadata.json",
                "Corefile",
                "HostAccess.json",
                "Ingress.json",
                "Certificate.json",
                "Policy.json"
            ])) else {
            throw NetworkHelperError.quarantined
        }
        let metadata: NetworkHelperPersistedMetadata = try loadCanonical(
            NetworkHelperPersistedMetadata.self,
            from: generationURL.appendingPathComponent(
                "metadata.json",
                isDirectory: false
            )
        )
        _ = try metadata.identity.validated()
        return metadata
    }

    private func validateGenerationDirectoryContents(
        at dnsRoot: URL,
        projectUUID: String,
        dnsUUID: String
    ) throws {
        let allowedRootEntries = Set([
            "active",
            "certificate-evidence.json",
            "certificate-pending.json",
            "certificate-retired.json",
            "current.json",
            "generations",
            "removal-intent.json"
        ])
        let rootEntries = try safeDirectoryContents(at: dnsRoot)
        guard Set(rootEntries.map(\.lastPathComponent))
            .isSubset(of: allowedRootEntries) else {
            throw NetworkHelperError.quarantined
        }
        let generations = dnsRoot.appendingPathComponent(
            "generations",
            isDirectory: true
        )
        let active = dnsRoot.appendingPathComponent(
            "active",
            isDirectory: true
        )
        try Self.validatePrivateDirectory(active, owner: owner)
        try Self.validatePrivateDirectory(generations, owner: owner)
        for generation in try safeDirectoryContents(at: generations) {
            guard let generationValue = Int(generation.lastPathComponent),
                  generationValue > 0 else {
                throw NetworkHelperError.quarantined
            }
            let metadata = try loadMetadata(from: generation)
            guard metadata.identity.projectUUID == projectUUID,
                  metadata.identity.dnsUUID == dnsUUID,
                  metadata.identity.generation == generationValue else {
                throw NetworkHelperError.quarantined
            }
            let pointer = NetworkHelperCurrentPointer(metadata: metadata)
            try validateGeneration(at: generation, expected: pointer)
        }
        let pointerURL = dnsRoot.appendingPathComponent(
            "current.json",
            isDirectory: false
        )
        if fileManager.fileExists(atPath: pointerURL.path) {
            let pointer: NetworkHelperCurrentPointer = try loadCanonical(
                NetworkHelperCurrentPointer.self,
                from: pointerURL
            )
            try validateActiveCorefile(pointer: pointer, dnsRoot: dnsRoot)
        } else {
            guard try safeDirectoryContents(at: active).isEmpty else {
                throw NetworkHelperError.quarantined
            }
        }
    }

    private func removeSupersededGenerations(
        dnsRoot: URL,
        keeping generation: Int,
        projectUUID: String,
        dnsUUID: String
    ) throws {
        let generations = dnsRoot.appendingPathComponent(
            "generations",
            isDirectory: true
        )
        for entry in try safeDirectoryContents(at: generations) {
            guard let value = Int(entry.lastPathComponent), value > 0 else {
                throw NetworkHelperError.quarantined
            }
            guard value != generation else { continue }
            let metadata = try loadMetadata(from: entry)
            guard metadata.identity.projectUUID == projectUUID,
                  metadata.identity.dnsUUID == dnsUUID,
                  metadata.identity.generation == value else {
                throw NetworkHelperError.quarantined
            }
            try removeGenerationDirectory(entry)
        }
    }

    private func preparedRemovalURL(dnsRoot: URL) -> URL {
        dnsRoot.appendingPathComponent(
            "removal-intent.json",
            isDirectory: false
        )
    }

    private func finishRemoval(at removalURL: URL) throws {
        try Self.validatePrivateDirectory(removalURL, owner: owner)
        let markerURL = removalURL.appendingPathComponent(
            "removal.json",
            isDirectory: false
        )
        let marker: NetworkHelperRemovalMarker = try loadCanonical(
            NetworkHelperRemovalMarker.self,
            from: markerURL
        )
        guard marker.schemaVersion == 1,
              Self.isCanonicalUUID(marker.projectUUID),
              Self.isCanonicalUUID(marker.dnsUUID),
              removalURL.deletingLastPathComponent().lastPathComponent
                == marker.projectUUID else {
            throw NetworkHelperError.quarantined
        }

        let generations = removalURL.appendingPathComponent(
            "generations",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: generations.path) {
            try Self.validatePrivateDirectory(generations, owner: owner)
            for generation in try safeDirectoryContents(at: generations) {
                let metadata = try loadMetadata(from: generation)
                guard metadata.identity.projectUUID == marker.projectUUID,
                      metadata.identity.dnsUUID == marker.dnsUUID else {
                    throw NetworkHelperError.quarantined
                }
                try removeGenerationDirectory(generation)
            }
            guard rmdir(generations.path) == 0 else {
                throw NetworkHelperError.ioFailure
            }
        }
        let active = removalURL.appendingPathComponent(
            "active",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: active.path) {
            try Self.validatePrivateDirectory(active, owner: owner)
            let activeEntries = try safeDirectoryContents(at: active)
            guard Set(activeEntries.map(\.lastPathComponent))
                .isSubset(of: Set([
                    "Corefile",
                    "HostAccess.json",
                    "Ingress.json",
                    "Certificate.json",
                    "Policy.json"
                ])) else {
                throw NetworkHelperError.quarantined
            }
            for entry in activeEntries {
                try removeRegularFileIfPresent(entry)
            }
            guard rmdir(active.path) == 0 else {
                throw NetworkHelperError.ioFailure
            }
        }
        try removeRegularFileIfPresent(
            removalURL.appendingPathComponent(
                "current.json",
                isDirectory: false
            )
        )
        try removeRegularFileIfPresent(
            removalURL.appendingPathComponent(
                "certificate-evidence.json",
                isDirectory: false
            )
        )
        try removeRegularFileIfPresent(
            removalURL.appendingPathComponent(
                "certificate-retired.json",
                isDirectory: false
            )
        )
        try removeRegularFileIfPresent(
            removalURL.appendingPathComponent(
                "certificate-pending.json",
                isDirectory: false
            )
        )
        try removeRegularFileIfPresent(markerURL)
        guard rmdir(removalURL.path) == 0 else {
            throw NetworkHelperError.ioFailure
        }
    }

    private func removeGenerationDirectory(_ directoryURL: URL) throws {
        try Self.validatePrivateDirectory(directoryURL, owner: owner)
        let entries = try safeDirectoryContents(at: directoryURL)
        let allowed = Set([
            "metadata.json",
            "Corefile",
            "HostAccess.json",
            "Ingress.json",
            "Certificate.json",
            "Policy.json"
        ])
        guard Set(entries.map(\.lastPathComponent)).isSubset(of: allowed) else {
            throw NetworkHelperError.quarantined
        }
        for entry in entries {
            try removeRegularFileIfPresent(entry)
        }
        guard rmdir(directoryURL.path) == 0 else {
            throw NetworkHelperError.ioFailure
        }
    }

    private func removeRegularFileIfPresent(_ url: URL) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw NetworkHelperError.ioFailure
            }
            return
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == owner,
              metadata.st_nlink == 1,
              metadata.st_mode & networkHelperPermissionBits
                == S_IRUSR | S_IWUSR else {
            throw NetworkHelperError.unsafePath
        }
        guard unlink(url.path) == 0 else {
            throw NetworkHelperError.ioFailure
        }
    }

    private func loadCanonical<Value: Codable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value {
        try NetworkHelperCanonicalJSON.decode(
            type,
            from: loadRegularFile(url)
        )
    }

    private func loadRegularFile(_ url: URL) throws -> Data {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw NetworkHelperError.unsafePath
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == owner,
              metadata.st_nlink == 1,
              metadata.st_mode & networkHelperPermissionBits
                == S_IRUSR | S_IWUSR,
              metadata.st_size >= 0,
              metadata.st_size <= off_t(
                NetworkHelperProtocolV1.maximumFrameBytes
              ) else {
            throw NetworkHelperError.unsafePath
        }
        var result = Data()
        result.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](
            repeating: 0,
            count: min(max(Int(metadata.st_size), 1), 64 * 1_024)
        )
        while result.count < Int(metadata.st_size) {
            let count = Darwin.read(
                descriptor,
                &buffer,
                min(buffer.count, Int(metadata.st_size) - result.count)
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw NetworkHelperError.ioFailure
            }
            result.append(contentsOf: buffer[0..<count])
        }
        return result
    }

    private func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NetworkHelperError.ioFailure
        }
        var succeeded = false
        defer {
            Darwin.close(descriptor)
            if !succeeded {
                _ = unlink(url.path)
            }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw NetworkHelperError.ioFailure
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw NetworkHelperError.ioFailure
        }
        succeeded = true
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw NetworkHelperError.ioFailure
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw NetworkHelperError.ioFailure
        }
    }

    private func safeDirectoryContents(at url: URL) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw NetworkHelperError.ioFailure
        }
    }

    private func removeDirectoryIfEmpty(_ url: URL) throws {
        guard try safeDirectoryContents(at: url).isEmpty else { return }
        if rmdir(url.path) != 0, errno != ENOENT {
            throw NetworkHelperError.ioFailure
        }
    }

    private func generationURL(
        dnsRoot: URL,
        generation: Int
    ) -> URL {
        dnsRoot
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(String(generation), isDirectory: true)
    }

    private func quarantinedStatus(_ reason: String) -> NetworkHelperStatus {
        NetworkHelperStatus(
            disposition: .quarantined,
            identity: nil,
            corefileSHA256: nil,
            reason: reason
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 &&
            value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func validKeychainReferences(
        _ references: NetworkHelperCertificateKeychainReferences?
    ) -> Bool {
        guard let references else { return true }
        return !references.leafCertificate.isEmpty &&
            !references.leafKey.isEmpty &&
            references.leafCertificate.count <=
                NetworkHelperCertificateKeychainReferences
                    .maximumReferenceBytes &&
            references.leafKey.count <=
                NetworkHelperCertificateKeychainReferences
                    .maximumReferenceBytes &&
            (references.issuerCertificate?.count ?? 0) <=
                NetworkHelperCertificateKeychainReferences
                    .maximumReferenceBytes &&
            (references.issuerKey?.count ?? 0) <=
                NetworkHelperCertificateKeychainReferences
                    .maximumReferenceBytes
    }

    private static func preparePrivateDirectory(
        _ url: URL,
        owner: uid_t,
        requireSafeParent: Bool
    ) throws {
        guard isLexicallyNormalizedAbsolutePath(url.path) else {
            throw NetworkHelperError.unsafePath
        }
        if requireSafeParent {
            try validatePrivateDirectory(
                url.deletingLastPathComponent(),
                owner: owner
            )
        }

        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            guard errno == ENOENT,
                  mkdir(url.path, S_IRWXU) == 0,
                  chmod(url.path, S_IRWXU) == 0 else {
                throw NetworkHelperError.unsafePath
            }
        }
        try validatePrivateDirectory(url, owner: owner)
    }

    private static func validatePrivateDirectory(
        _ url: URL,
        owner: uid_t
    ) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == owner,
              metadata.st_mode & networkHelperPermissionBits == S_IRWXU else {
            throw NetworkHelperError.unsafePath
        }
    }

    private static func isLexicallyNormalizedAbsolutePath(
        _ path: String
    ) -> Bool {
        guard path.first == "/",
              path == "/" || !path.hasSuffix("/") else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.first?.isEmpty == true else {
            return false
        }
        return components.dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
