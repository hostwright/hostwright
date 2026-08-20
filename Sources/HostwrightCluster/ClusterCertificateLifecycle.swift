import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
@preconcurrency import Security
import X509

public enum ClusterCertificateLifecycleError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case invalidConfiguration(String)
    case invalidState(String)
    case notBootstrapped
    case alreadyBootstrapped
    case transitionInProgress
    case concurrentMutation
    case collision
    case tampered
    case credentialNotYetValid
    case credentialExpired
    case keychainLocked
    case accessDenied
    case cancelled
    case keychainFailure(Int32)
    case partialEffect
    case persistenceFailure(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let reason):
            "Cluster certificate lifecycle configuration is invalid: \(reason)"
        case .invalidState(let reason):
            "Cluster certificate lifecycle state is invalid: \(reason)"
        case .notBootstrapped:
            "Cluster certificate lifecycle is not bootstrapped."
        case .alreadyBootstrapped:
            "Cluster certificate lifecycle is already bootstrapped."
        case .transitionInProgress:
            "Cluster certificate lifecycle already has a pending transition."
        case .concurrentMutation:
            "Cluster certificate lifecycle state changed concurrently."
        case .collision:
            "Cluster certificate lifecycle ownership scope collides with an existing Keychain item."
        case .tampered:
            "Cluster certificate lifecycle evidence is missing, altered, or not exactly owned."
        case .credentialNotYetValid:
            "Cluster certificate credential is not yet valid."
        case .credentialExpired:
            "Cluster certificate credential has expired."
        case .keychainLocked:
            "The cluster certificate Keychain is locked and interaction is disabled."
        case .accessDenied:
            "The cluster certificate Keychain denied access."
        case .cancelled:
            "The cluster certificate Keychain operation was cancelled."
        case .keychainFailure(let status):
            "The cluster certificate Keychain operation failed with status \(status)."
        case .partialEffect:
            "Cluster certificate compensation was incomplete; recovery is required."
        case .persistenceFailure(let reason):
            "Cluster certificate lifecycle persistence failed: \(reason)"
        }
    }
}

public enum ClusterCertificateLifecycleContract {
    public static let metadataSchemaVersion = 1
    public static let journalSchemaVersion = 1
    public static let maximumPersistentReferenceBytes = 4_096
    public static let maximumStateBytes = 2 * 1_024 * 1_024
    public static let maximumAuthorityValidity: TimeInterval = 10 * 365 * 24 * 60 * 60
    public static let maximumLeafValidity: TimeInterval = 397 * 24 * 60 * 60
    public static let defaultAuthorityValidity: TimeInterval = 5 * 365 * 24 * 60 * 60
    public static let defaultLeafValidity: TimeInterval = 90 * 24 * 60 * 60
    public static let keyApplicationTagPrefix = "dev.hostwright.cluster.certificate.v1"
}

public struct ClusterCertificateOwnedReferences: Codable, Equatable, Sendable {
    public let keyPersistentReference: Data
    public let certificatePersistentReference: Data

    public init(
        keyPersistentReference: Data,
        certificatePersistentReference: Data
    ) throws {
        guard !keyPersistentReference.isEmpty,
              !certificatePersistentReference.isEmpty,
              keyPersistentReference.count
                <= ClusterCertificateLifecycleContract.maximumPersistentReferenceBytes,
              certificatePersistentReference.count
                <= ClusterCertificateLifecycleContract.maximumPersistentReferenceBytes,
              keyPersistentReference != certificatePersistentReference else {
            throw ClusterCertificateLifecycleError.invalidState(
                "persistent references are malformed"
            )
        }
        self.keyPersistentReference = keyPersistentReference
        self.certificatePersistentReference = certificatePersistentReference
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            keyPersistentReference: container.decode(
                Data.self,
                forKey: .keyPersistentReference
            ),
            certificatePersistentReference: container.decode(
                Data.self,
                forKey: .certificatePersistentReference
            )
        )
    }
}

public struct ClusterCertificateAuthorityCredential: Codable, Equatable, Sendable {
    public let authority: ClusterCertificateAuthority
    public let references: ClusterCertificateOwnedReferences

    public init(
        authority: ClusterCertificateAuthority,
        references: ClusterCertificateOwnedReferences
    ) {
        self.authority = authority
        self.references = references
    }
}

public struct ClusterCertificateLeafCredential: Codable, Equatable, Sendable {
    public let identity: ClusterCertificateIdentity
    public let certificateDER: Data
    public let certificateSHA256: String
    public let references: ClusterCertificateOwnedReferences

    public init(
        identity: ClusterCertificateIdentity,
        certificateDER: Data,
        references: ClusterCertificateOwnedReferences
    ) throws {
        guard !certificateDER.isEmpty,
              certificateDER.count <= ClusterCertificateContract.maximumCertificateBytes else {
            throw ClusterCertificateLifecycleError.invalidState(
                "leaf certificate size is invalid"
            )
        }
        do {
            _ = try Certificate(derEncoded: Array(certificateDER))
        } catch {
            throw ClusterCertificateLifecycleError.invalidState(
                "leaf certificate DER is invalid"
            )
        }
        self.identity = identity
        self.certificateDER = certificateDER
        self.certificateSHA256 = Self.sha256(certificateDER)
        self.references = references
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let certificateDER = try container.decode(Data.self, forKey: .certificateDER)
        try self.init(
            identity: container.decode(ClusterCertificateIdentity.self, forKey: .identity),
            certificateDER: certificateDER,
            references: container.decode(
                ClusterCertificateOwnedReferences.self,
                forKey: .references
            )
        )
        guard certificateSHA256
                == (try container.decode(String.self, forKey: .certificateSHA256)) else {
            throw ClusterCertificateLifecycleError.tampered
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ClusterCertificateGenerationCredential: Codable, Equatable, Sendable {
    public let clusterID: ClusterID
    public let nodeID: ClusterNodeID
    public let generation: ClusterCertificateGeneration
    public let ownershipID: String
    public let authority: ClusterCertificateAuthorityCredential
    public let leaves: [ClusterCertificateLeafCredential]

    public init(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        authority: ClusterCertificateAuthorityCredential,
        leaves: [ClusterCertificateLeafCredential]
    ) throws {
        let leaves = leaves.sorted { $0.identity.role.rawValue < $1.identity.role.rawValue }
        guard let ownershipUUID = UUID(uuidString: ownershipID),
              ownershipUUID.uuidString.lowercased() == ownershipID,
              authority.authority.clusterID == clusterID,
              authority.authority.generation == generation,
              !leaves.isEmpty,
              Set(leaves.map(\.identity.role)).count == leaves.count,
              leaves.allSatisfy({ leaf in
                  leaf.identity.clusterID == clusterID
                    && leaf.identity.nodeID == nodeID
                    && leaf.identity.generation == generation
              }) else {
            throw ClusterCertificateLifecycleError.invalidState(
                "generation ownership or role coverage is invalid"
            )
        }
        let trustBundle: ClusterCertificateTrustBundle
        do {
            trustBundle = try ClusterCertificateTrustBundle(
                clusterID: clusterID,
                activeGeneration: generation,
                authorities: [authority.authority]
            )
            for leaf in leaves {
                let certificate = try Certificate(derEncoded: Array(leaf.certificateDER))
                let lowerBound = max(
                    authority.authority.notValidBeforeMilliseconds,
                    try Self.milliseconds(certificate.notValidBefore)
                )
                let upperBound = min(
                    authority.authority.notValidAfterMilliseconds,
                    try Self.milliseconds(certificate.notValidAfter)
                )
                guard lowerBound <= upperBound else {
                    throw ClusterCertificateLifecycleError.invalidState(
                        "leaf validity is outside its authority validity"
                    )
                }
                let validationTime = lowerBound < upperBound
                    ? lowerBound + min(1_000, upperBound - lowerBound)
                    : lowerBound
                _ = try ClusterMutualTLSVerifier(trustBundle: trustBundle).verify(
                    peerCertificateDER: leaf.certificateDER,
                    expectedIdentity: leaf.identity,
                    nowMilliseconds: validationTime
                )
            }
        } catch let error as ClusterCertificateLifecycleError {
            throw error
        } catch {
            throw ClusterCertificateLifecycleError.invalidState(
                "generation certificates do not satisfy the trust contract"
            )
        }
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.generation = generation
        self.ownershipID = ownershipID
        self.authority = authority
        self.leaves = leaves
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            nodeID: container.decode(ClusterNodeID.self, forKey: .nodeID),
            generation: container.decode(
                ClusterCertificateGeneration.self,
                forKey: .generation
            ),
            ownershipID: container.decode(String.self, forKey: .ownershipID),
            authority: container.decode(
                ClusterCertificateAuthorityCredential.self,
                forKey: .authority
            ),
            leaves: container.decode(
                [ClusterCertificateLeafCredential].self,
                forKey: .leaves
            )
        )
    }

    fileprivate var roles: [ClusterCertificateRole] {
        leaves.map(\.identity.role)
    }

    fileprivate func leaf(
        role: ClusterCertificateRole
    ) -> ClusterCertificateLeafCredential? {
        leaves.first { $0.identity.role == role }
    }

    private static func milliseconds(_ date: Date) throws -> UInt64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= Double(UInt64.max) else {
            throw ClusterCertificateLifecycleError.invalidState(
                "certificate validity is outside the supported clock range"
            )
        }
        return UInt64(milliseconds.rounded(.down))
    }
}

public struct ClusterCertificateLifecycleMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: UInt64
    public let clusterID: ClusterID
    public let nodeID: ClusterNodeID
    public let roles: [ClusterCertificateRole]
    public let currentGeneration: ClusterCertificateGeneration
    public let retiringGeneration: ClusterCertificateGeneration?
    public let generations: [ClusterCertificateGenerationCredential]

    public init(
        revision: UInt64,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        roles: [ClusterCertificateRole],
        currentGeneration: ClusterCertificateGeneration,
        retiringGeneration: ClusterCertificateGeneration?,
        generations: [ClusterCertificateGenerationCredential]
    ) throws {
        let roles = roles.sorted { $0.rawValue < $1.rawValue }
        let generations = generations.sorted { $0.generation < $1.generation }
        guard revision > 0,
              !roles.isEmpty,
              Set(roles).count == roles.count,
              (1...ClusterCertificateContract.maximumAuthorities).contains(generations.count),
              generations.allSatisfy({ record in
                  record.clusterID == clusterID
                    && record.nodeID == nodeID
                    && record.roles == roles
              }),
              Set(generations.map(\.generation)).count == generations.count,
              Set(generations.map(\.ownershipID)).count == generations.count,
              generations.last?.generation == currentGeneration else {
            throw ClusterCertificateLifecycleError.invalidState(
                "metadata ownership, roles, or generations are invalid"
            )
        }
        if generations.count == 1 {
            guard retiringGeneration == nil else {
                throw ClusterCertificateLifecycleError.invalidState(
                    "stable metadata cannot name a retiring generation"
                )
            }
        } else {
            guard let retiringGeneration,
                  generations.first?.generation == retiringGeneration,
                  try retiringGeneration.advanced() == currentGeneration else {
                throw ClusterCertificateLifecycleError.invalidState(
                    "rotation overlap is not sequential"
                )
            }
        }
        _ = try ClusterCertificateTrustBundle(
            clusterID: clusterID,
            activeGeneration: currentGeneration,
            authorities: generations.map(\.authority.authority)
        )
        self.schemaVersion = ClusterCertificateLifecycleContract.metadataSchemaVersion
        self.revision = revision
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.roles = roles
        self.currentGeneration = currentGeneration
        self.retiringGeneration = retiringGeneration
        self.generations = generations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion)
                == ClusterCertificateLifecycleContract.metadataSchemaVersion else {
            throw ClusterCertificateLifecycleError.invalidState(
                "metadata schema version is unsupported"
            )
        }
        try self.init(
            revision: container.decode(UInt64.self, forKey: .revision),
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            nodeID: container.decode(ClusterNodeID.self, forKey: .nodeID),
            roles: container.decode([ClusterCertificateRole].self, forKey: .roles),
            currentGeneration: container.decode(
                ClusterCertificateGeneration.self,
                forKey: .currentGeneration
            ),
            retiringGeneration: container.decodeIfPresent(
                ClusterCertificateGeneration.self,
                forKey: .retiringGeneration
            ),
            generations: container.decode(
                [ClusterCertificateGenerationCredential].self,
                forKey: .generations
            )
        )
    }

    public func trustBundle() throws -> ClusterCertificateTrustBundle {
        try ClusterCertificateTrustBundle(
            clusterID: clusterID,
            activeGeneration: currentGeneration,
            authorities: generations.map(\.authority.authority)
        )
    }

    public func credential(
        role: ClusterCertificateRole,
        generation: ClusterCertificateGeneration? = nil
    ) -> ClusterCertificateLeafCredential? {
        let generation = generation ?? currentGeneration
        return generations.first { $0.generation == generation }?.leaf(role: role)
    }

    fileprivate func adding(
        _ prepared: ClusterCertificateGenerationCredential
    ) throws -> Self {
        guard generations.count == 1,
              retiringGeneration == nil,
              prepared.clusterID == clusterID,
              prepared.nodeID == nodeID,
              prepared.roles == roles,
              prepared.generation == (try currentGeneration.advanced()),
              revision < UInt64.max else {
            throw ClusterCertificateLifecycleError.invalidState(
                "rotation activation does not match stable metadata"
            )
        }
        return try Self(
            revision: revision + 1,
            clusterID: clusterID,
            nodeID: nodeID,
            roles: roles,
            currentGeneration: prepared.generation,
            retiringGeneration: currentGeneration,
            generations: generations + [prepared]
        )
    }

    fileprivate func completingRotation() throws -> Self {
        guard generations.count == 2,
              retiringGeneration != nil,
              revision < UInt64.max,
              let current = generations.last else {
            throw ClusterCertificateLifecycleError.invalidState(
                "rotation retirement does not match overlapping metadata"
            )
        }
        return try Self(
            revision: revision + 1,
            clusterID: clusterID,
            nodeID: nodeID,
            roles: roles,
            currentGeneration: currentGeneration,
            retiringGeneration: nil,
            generations: [current]
        )
    }
}

enum ClusterCertificateLifecycleJournalStage: String, Codable, Sendable {
    case creating
    case activating
    case retiring
}

struct ClusterCertificateLifecycleJournal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let operationID: String
    let stage: ClusterCertificateLifecycleJournalStage
    let expectedRevision: UInt64
    let clusterID: ClusterID
    let nodeID: ClusterNodeID
    let roles: [ClusterCertificateRole]
    let sourceGeneration: ClusterCertificateGeneration?
    let targetGeneration: ClusterCertificateGeneration
    let preparedGeneration: ClusterCertificateGenerationCredential?
    let retiringCredential: ClusterCertificateGenerationCredential?
    let startedAtMilliseconds: UInt64

    init(
        operationID: String = UUID().uuidString.lowercased(),
        stage: ClusterCertificateLifecycleJournalStage,
        expectedRevision: UInt64,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        roles: [ClusterCertificateRole],
        sourceGeneration: ClusterCertificateGeneration?,
        targetGeneration: ClusterCertificateGeneration,
        preparedGeneration: ClusterCertificateGenerationCredential?,
        retiringCredential: ClusterCertificateGenerationCredential?,
        startedAtMilliseconds: UInt64
    ) throws {
        let roles = roles.sorted { $0.rawValue < $1.rawValue }
        guard let operationUUID = UUID(uuidString: operationID),
              operationUUID.uuidString.lowercased() == operationID,
              !roles.isEmpty,
              Set(roles).count == roles.count,
              startedAtMilliseconds > 0 else {
            throw ClusterCertificateLifecycleError.invalidState(
                "journal identity, roles, or time are invalid"
            )
        }
        switch stage {
        case .creating:
            let generationIsValid: Bool
            if let sourceGeneration {
                generationIsValid = try sourceGeneration.advanced() == targetGeneration
            } else {
                generationIsValid = targetGeneration.value == 1
            }
            guard preparedGeneration == nil,
                  retiringCredential == nil,
                  generationIsValid else {
                throw ClusterCertificateLifecycleError.invalidState(
                    "create journal transition is invalid"
                )
            }
        case .activating:
            let generationIsValid: Bool
            if let sourceGeneration {
                generationIsValid = try sourceGeneration.advanced() == targetGeneration
            } else {
                generationIsValid = targetGeneration.value == 1
            }
            guard retiringCredential == nil,
                  let preparedGeneration,
                  preparedGeneration.clusterID == clusterID,
                  preparedGeneration.nodeID == nodeID,
                  preparedGeneration.roles == roles,
                  preparedGeneration.generation == targetGeneration,
                  preparedGeneration.ownershipID == operationID,
                  generationIsValid else {
                throw ClusterCertificateLifecycleError.invalidState(
                    "activation journal transition is invalid"
                )
            }
        case .retiring:
            guard preparedGeneration == nil,
                  let sourceGeneration,
                  let retiringCredential,
                  retiringCredential.clusterID == clusterID,
                  retiringCredential.nodeID == nodeID,
                  retiringCredential.roles == roles,
                  retiringCredential.generation == sourceGeneration,
                  try sourceGeneration.advanced() == targetGeneration else {
                throw ClusterCertificateLifecycleError.invalidState(
                    "retirement journal transition is invalid"
                )
            }
        }
        self.schemaVersion = ClusterCertificateLifecycleContract.journalSchemaVersion
        self.operationID = operationID
        self.stage = stage
        self.expectedRevision = expectedRevision
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.roles = roles
        self.sourceGeneration = sourceGeneration
        self.targetGeneration = targetGeneration
        self.preparedGeneration = preparedGeneration
        self.retiringCredential = retiringCredential
        self.startedAtMilliseconds = startedAtMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion)
                == ClusterCertificateLifecycleContract.journalSchemaVersion else {
            throw ClusterCertificateLifecycleError.invalidState(
                "journal schema version is unsupported"
            )
        }
        try self.init(
            operationID: container.decode(String.self, forKey: .operationID),
            stage: container.decode(
                ClusterCertificateLifecycleJournalStage.self,
                forKey: .stage
            ),
            expectedRevision: container.decode(UInt64.self, forKey: .expectedRevision),
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            nodeID: container.decode(ClusterNodeID.self, forKey: .nodeID),
            roles: container.decode([ClusterCertificateRole].self, forKey: .roles),
            sourceGeneration: container.decodeIfPresent(
                ClusterCertificateGeneration.self,
                forKey: .sourceGeneration
            ),
            targetGeneration: container.decode(
                ClusterCertificateGeneration.self,
                forKey: .targetGeneration
            ),
            preparedGeneration: container.decodeIfPresent(
                ClusterCertificateGenerationCredential.self,
                forKey: .preparedGeneration
            ),
            retiringCredential: container.decodeIfPresent(
                ClusterCertificateGenerationCredential.self,
                forKey: .retiringCredential
            ),
            startedAtMilliseconds: container.decode(
                UInt64.self,
                forKey: .startedAtMilliseconds
            )
        )
    }

    func activating(
        _ prepared: ClusterCertificateGenerationCredential
    ) throws -> Self {
        try Self(
            operationID: operationID,
            stage: .activating,
            expectedRevision: expectedRevision,
            clusterID: clusterID,
            nodeID: nodeID,
            roles: roles,
            sourceGeneration: sourceGeneration,
            targetGeneration: targetGeneration,
            preparedGeneration: prepared,
            retiringCredential: nil,
            startedAtMilliseconds: startedAtMilliseconds
        )
    }
}

enum ClusterCertificateLifecycleStateMachine {
    static func activate(
        metadata: ClusterCertificateLifecycleMetadata?,
        journal: ClusterCertificateLifecycleJournal
    ) throws -> ClusterCertificateLifecycleMetadata {
        guard journal.stage == .activating,
              let prepared = journal.preparedGeneration else {
            throw ClusterCertificateLifecycleError.invalidState(
                "activation requires a prepared generation"
            )
        }
        if let metadata {
            guard metadata.clusterID == journal.clusterID,
                  metadata.nodeID == journal.nodeID,
                  metadata.roles == journal.roles else {
                throw ClusterCertificateLifecycleError.concurrentMutation
            }
        }
        if journal.sourceGeneration == nil {
            if let metadata {
                guard metadata.revision == journal.expectedRevision + 1,
                      metadata.currentGeneration == journal.targetGeneration,
                      metadata.generations == [prepared] else {
                    throw ClusterCertificateLifecycleError.concurrentMutation
                }
                return metadata
            }
            guard journal.expectedRevision == 0 else {
                throw ClusterCertificateLifecycleError.concurrentMutation
            }
            return try ClusterCertificateLifecycleMetadata(
                revision: 1,
                clusterID: journal.clusterID,
                nodeID: journal.nodeID,
                roles: journal.roles,
                currentGeneration: journal.targetGeneration,
                retiringGeneration: nil,
                generations: [prepared]
            )
        }
        guard let metadata else {
            throw ClusterCertificateLifecycleError.concurrentMutation
        }
        if metadata.revision == journal.expectedRevision + 1,
           metadata.currentGeneration == journal.targetGeneration,
           metadata.generations.contains(prepared) {
            return metadata
        }
        guard metadata.revision == journal.expectedRevision,
              metadata.currentGeneration == journal.sourceGeneration else {
            throw ClusterCertificateLifecycleError.concurrentMutation
        }
        return try metadata.adding(prepared)
    }

    static func retire(
        metadata: ClusterCertificateLifecycleMetadata,
        journal: ClusterCertificateLifecycleJournal
    ) throws -> ClusterCertificateLifecycleMetadata {
        guard journal.stage == .retiring,
              let source = journal.sourceGeneration,
              let retiring = journal.retiringCredential,
              metadata.clusterID == journal.clusterID,
              metadata.nodeID == journal.nodeID,
              metadata.roles == journal.roles else {
            throw ClusterCertificateLifecycleError.invalidState(
                "retirement requires exact retiring evidence"
            )
        }
        if metadata.revision == journal.expectedRevision + 1,
           metadata.currentGeneration == journal.targetGeneration,
           metadata.retiringGeneration == nil,
           !metadata.generations.contains(where: { $0.generation == source }) {
            return metadata
        }
        guard metadata.revision == journal.expectedRevision,
              metadata.currentGeneration == journal.targetGeneration,
              metadata.retiringGeneration == source,
              metadata.generations.contains(retiring) else {
            throw ClusterCertificateLifecycleError.concurrentMutation
        }
        return try metadata.completingRotation()
    }
}

final class ClusterCertificateLifecycleFileStore: @unchecked Sendable {
    private struct Envelope: Codable, Equatable {
        let format: String
        let payload: Data
        let payloadSHA256: String
    }

    private static let metadataName = "certificate-lifecycle.json"
    private static let journalName = "certificate-lifecycle-journal.json"
    private static let lockName = ".certificate-lifecycle.lock"
    private let rootURL: URL
    private let rootDevice: dev_t
    private let rootInode: ino_t

    init(rootURL: URL) throws {
        guard rootURL.path.hasPrefix("/") else {
            throw ClusterCertificateLifecycleError.invalidConfiguration(
                "metadata root must be absolute"
            )
        }
        let standardized = rootURL.standardizedFileURL
        var metadata = stat()
        if lstat(standardized.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw Self.persistence("metadata root could not be inspected")
            }
            do {
                try FileManager.default.createDirectory(
                    at: standardized,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                throw Self.persistence("metadata root could not be created")
            }
            guard chmod(standardized.path, 0o700) == 0,
                  lstat(standardized.path, &metadata) == 0 else {
                throw Self.persistence("metadata root permissions could not be set")
            }
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw ClusterCertificateLifecycleError.tampered
        }
        self.rootURL = standardized
        self.rootDevice = metadata.st_dev
        self.rootInode = metadata.st_ino
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        let root = try openRoot()
        defer { close(root) }
        let lock = openat(
            root,
            Self.lockName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard lock >= 0 else {
            throw Self.persistence("lifecycle lock could not be opened")
        }
        defer { close(lock) }
        try validate(descriptor: lock, expectedMode: 0o600)
        guard flock(lock, LOCK_EX) == 0 else {
            throw Self.persistence("lifecycle lock could not be acquired")
        }
        defer { _ = flock(lock, LOCK_UN) }
        var lockedMetadata = stat()
        var namedMetadata = stat()
        guard fstat(lock, &lockedMetadata) == 0,
              fstatat(root, Self.lockName, &namedMetadata, AT_SYMLINK_NOFOLLOW) == 0,
              lockedMetadata.st_dev == namedMetadata.st_dev,
              lockedMetadata.st_ino == namedMetadata.st_ino else {
            throw ClusterCertificateLifecycleError.tampered
        }
        return try body()
    }

    func loadMetadata() throws -> ClusterCertificateLifecycleMetadata? {
        try read(
            name: Self.metadataName,
            format: "hostwright-cluster-certificate-metadata-v1",
            as: ClusterCertificateLifecycleMetadata.self
        )
    }

    func loadJournal() throws -> ClusterCertificateLifecycleJournal? {
        try read(
            name: Self.journalName,
            format: "hostwright-cluster-certificate-journal-v1",
            as: ClusterCertificateLifecycleJournal.self
        )
    }

    func saveMetadata(_ metadata: ClusterCertificateLifecycleMetadata) throws {
        try write(
            metadata,
            name: Self.metadataName,
            format: "hostwright-cluster-certificate-metadata-v1"
        )
    }

    func saveJournal(_ journal: ClusterCertificateLifecycleJournal) throws {
        try write(
            journal,
            name: Self.journalName,
            format: "hostwright-cluster-certificate-journal-v1"
        )
    }

    func removeJournal() throws {
        try remove(name: Self.journalName)
    }

    private func read<Value: Codable>(
        name: String,
        format: String,
        as _: Value.Type
    ) throws -> Value? {
        let root = try openRoot()
        defer { close(root) }
        let descriptor = openat(root, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else {
            throw Self.persistence("\(name) could not be opened")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try validate(descriptor: descriptor, expectedMode: 0o600)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_size > 0,
              metadata.st_size <= ClusterCertificateLifecycleContract.maximumStateBytes else {
            throw ClusterCertificateLifecycleError.tampered
        }
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw Self.persistence("\(name) could not be read")
        }
        let decoder = JSONDecoder()
        let encoder = Self.encoder()
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.format == format,
                  envelope.payloadSHA256 == Self.sha256(envelope.payload),
                  try encoder.encode(envelope) == data else {
                throw ClusterCertificateLifecycleError.tampered
            }
            let value = try decoder.decode(Value.self, from: envelope.payload)
            guard try encoder.encode(value) == envelope.payload else {
                throw ClusterCertificateLifecycleError.tampered
            }
            return value
        } catch let error as ClusterCertificateLifecycleError {
            throw error
        } catch {
            throw ClusterCertificateLifecycleError.tampered
        }
    }

    private func write<Value: Codable>(
        _ value: Value,
        name: String,
        format: String
    ) throws {
        let encoder = Self.encoder()
        let payload: Data
        let data: Data
        do {
            payload = try encoder.encode(value)
            data = try encoder.encode(
                Envelope(
                    format: format,
                    payload: payload,
                    payloadSHA256: Self.sha256(payload)
                )
            )
        } catch {
            throw Self.persistence("\(name) could not be encoded")
        }
        guard data.count <= ClusterCertificateLifecycleContract.maximumStateBytes else {
            throw Self.persistence("\(name) exceeds the size limit")
        }
        let root = try openRoot()
        defer { close(root) }
        try validateExisting(root: root, name: name)
        let temporaryName = ".\(name).\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(
            root,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw Self.persistence("\(name) staging file could not be created")
        }
        var published = false
        defer {
            close(descriptor)
            if !published {
                _ = unlinkat(root, temporaryName, 0)
            }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw Self.persistence("\(name) staging permissions could not be set")
        }
        try validate(descriptor: descriptor, expectedMode: 0o600)
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                guard let baseAddress = rawBuffer.baseAddress else {
                    throw Self.persistence("\(name) staging bytes are unavailable")
                }
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard count > 0 else {
                    throw Self.persistence("\(name) staging write failed")
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
              renameat(root, temporaryName, root, name) == 0,
              fsync(root) == 0 else {
            throw Self.persistence("\(name) could not be atomically published")
        }
        published = true
    }

    private func remove(name: String) throws {
        let root = try openRoot()
        defer { close(root) }
        var metadata = stat()
        if fstatat(root, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else {
                throw Self.persistence("\(name) could not be inspected")
            }
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o077 == 0 else {
            throw ClusterCertificateLifecycleError.tampered
        }
        guard unlinkat(root, name, 0) == 0, fsync(root) == 0 else {
            throw Self.persistence("\(name) could not be removed")
        }
    }

    private func openRoot() throws -> Int32 {
        let descriptor = open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw Self.persistence("metadata root could not be opened")
        }
        do {
            try validate(descriptor: descriptor, expectedMode: 0o700, kind: S_IFDIR)
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_dev == rootDevice,
                  metadata.st_ino == rootInode else {
                throw ClusterCertificateLifecycleError.tampered
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func validateExisting(root: Int32, name: String) throws {
        var metadata = stat()
        if fstatat(root, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else {
                throw Self.persistence("\(name) could not be inspected")
            }
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o077 == 0 else {
            throw ClusterCertificateLifecycleError.tampered
        }
    }

    private func validate(
        descriptor: Int32,
        expectedMode: mode_t,
        kind: mode_t = S_IFREG
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == kind,
              metadata.st_uid == getuid(),
              (kind != S_IFREG || metadata.st_nlink == 1),
              metadata.st_mode & 0o777 == expectedMode else {
            throw ClusterCertificateLifecycleError.tampered
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func persistence(
        _ reason: String
    ) -> ClusterCertificateLifecycleError {
        .persistenceFailure(reason)
    }
}

public struct ClusterCertificateIdentityHandle: @unchecked Sendable {
    public let identity: SecIdentity
    public let certificateChain: [SecCertificate]
    public let credential: ClusterCertificateLeafCredential

    fileprivate init(
        identity: SecIdentity,
        certificateChain: [SecCertificate],
        credential: ClusterCertificateLeafCredential
    ) {
        self.identity = identity
        self.certificateChain = certificateChain
        self.credential = credential
    }
}

final class ClusterCertificateKeychainStore: @unchecked Sendable {
    private struct PersistedItemEvidence {
        let persistentReference: Data
    }

    private enum ItemRole: Hashable {
        case authority
        case leaf(ClusterCertificateRole)

        var value: String {
            switch self {
            case .authority:
                "authority"
            case .leaf(let role):
                "leaf.\(role.rawValue)"
            }
        }
    }

    private let keychain: SecKeychain
    private static let userInteractionLock = NSRecursiveLock()

    init(keychain: SecKeychain) {
        self.keychain = keychain
    }

    static func productionDefault() throws -> ClusterCertificateKeychainStore {
        var keychain: SecKeychain?
        let status = SecKeychainCopyDefault(&keychain)
        guard status == errSecSuccess, let keychain else {
            throw status == errSecSuccess
                ? ClusterCertificateLifecycleError.tampered
                : Self.mapStatus(status)
        }
        return Self(keychain: keychain)
    }

    private var authenticationContext: LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private func withUserInteractionDisabled<T>(
        _ operation: () throws -> T
    ) throws -> T {
        // Legacy SecKeychain interaction is process-global, so the disable window
        // must be serialized and restored exactly.
        Self.userInteractionLock.lock()
        defer { Self.userInteractionLock.unlock() }

        var priorInteraction = DarwinBoolean(false)
        let readStatus = SecKeychainGetUserInteractionAllowed(&priorInteraction)
        guard readStatus == errSecSuccess else {
            throw Self.mapStatus(readStatus)
        }
        let disableStatus = SecKeychainSetUserInteractionAllowed(false)
        guard disableStatus == errSecSuccess else {
            throw Self.mapStatus(disableStatus)
        }

        let result: Result<T, Error>
        do {
            try requireUnlockedKeychain()
            result = .success(try operation())
        } catch {
            result = .failure(error)
        }

        let restoreStatus = SecKeychainSetUserInteractionAllowed(
            priorInteraction.boolValue
        )
        guard restoreStatus == errSecSuccess else {
            throw Self.mapStatus(restoreStatus)
        }
        return try result.get()
    }

    private func applyNonInteractiveLookup(to query: inout [CFString: Any]) {
        query[kSecUseAuthenticationContext] = authenticationContext
        query[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
    }

    func createGeneration(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        roles: [ClusterCertificateRole],
        authorityValidity: TimeInterval,
        leafValidity: TimeInterval,
        now: Date
    ) throws -> ClusterCertificateGenerationCredential {
        try withUserInteractionDisabled {
            let roles = roles.sorted { $0.rawValue < $1.rawValue }
            guard !roles.isEmpty,
                  Set(roles).count == roles.count,
                  authorityValidity > 0,
                  authorityValidity
                    <= ClusterCertificateLifecycleContract.maximumAuthorityValidity,
                  leafValidity > 0,
                  leafValidity <= ClusterCertificateLifecycleContract.maximumLeafValidity,
                  leafValidity <= authorityValidity,
                  now.timeIntervalSince1970.isFinite,
                  now.timeIntervalSince1970 >= 60,
                  UUID(uuidString: ownershipID)?.uuidString.lowercased() == ownershipID else {
                throw ClusterCertificateLifecycleError.invalidConfiguration(
                    "roles, validity, or clock are invalid"
                )
            }
            try ensureScopeAvailable(
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                roles: roles
            )

        var created: [(role: ItemRole, key: SecKey?, certificate: SecCertificate?)] = []
        do {
            let authorityRole = ItemRole.authority
            let authorityKey = try generateKey(
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: authorityRole
            )
            created.append((authorityRole, authorityKey, nil))
            let authorityPrivateKey = try Certificate.PrivateKey(authorityKey)
            let authorityName = try DistinguishedName {
                OrganizationName("Hostwright")
                CommonName(
                    "Hostwright Cluster CA \(clusterID.rawValue) g\(generation.value)"
                )
            }
            let notValidBefore = now.addingTimeInterval(-60)
            let authorityNotValidAfter = now.addingTimeInterval(authorityValidity)
            let authorityCertificate = try Certificate(
                version: .v3,
                serialNumber: try Self.secureSerialNumber(),
                publicKey: authorityPrivateKey.publicKey,
                notValidBefore: notValidBefore,
                notValidAfter: authorityNotValidAfter,
                issuer: authorityName,
                subject: authorityName,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: Certificate.Extensions {
                    Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                    Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                    SubjectAlternativeNames([
                        .uniformResourceIdentifier(
                            ClusterCertificateAuthority.identityURI(
                                clusterID: clusterID,
                                generation: generation
                            )
                        )
                    ])
                    SubjectKeyIdentifier(hash: authorityPrivateKey.publicKey)
                },
                issuerPrivateKey: authorityPrivateKey
            )
            let authoritySecCertificate = try SecCertificate.makeWithCertificate(
                authorityCertificate
            )
            try addCertificate(
                authoritySecCertificate,
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: authorityRole
            )
            created[0].certificate = authoritySecCertificate
            let authorityReferences = try references(
                key: authorityKey,
                certificate: authoritySecCertificate
            )
            let authority = try ClusterCertificateAuthority(
                clusterID: clusterID,
                generation: generation,
                certificateDER: SecCertificateCopyData(authoritySecCertificate) as Data
            )
            let authorityKeyIdentifier = try authorityCertificate.extensions
                .subjectKeyIdentifier!.keyIdentifier

            var leaves: [ClusterCertificateLeafCredential] = []
            for role in roles {
                let identity = try ClusterCertificateIdentity(
                    clusterID: clusterID,
                    nodeID: nodeID,
                    role: role,
                    generation: generation
                )
                let itemRole = ItemRole.leaf(role)
                let leafKey = try generateKey(
                    clusterID: clusterID,
                    nodeID: nodeID,
                    generation: generation,
                    ownershipID: ownershipID,
                    role: itemRole
                )
                created.append((itemRole, leafKey, nil))
                let leafPrivateKey = try Certificate.PrivateKey(leafKey)
                let leafNotValidAfter = min(
                    now.addingTimeInterval(leafValidity),
                    authorityNotValidAfter
                )
                let leaf = try Certificate(
                    version: .v3,
                    serialNumber: try Self.secureSerialNumber(),
                    publicKey: leafPrivateKey.publicKey,
                    notValidBefore: notValidBefore,
                    notValidAfter: leafNotValidAfter,
                    issuer: authorityName,
                    subject: try DistinguishedName {
                        OrganizationName("Hostwright")
                        CommonName("Hostwright Cluster \(role.rawValue)")
                    },
                    signatureAlgorithm: .ecdsaWithSHA256,
                    extensions: Certificate.Extensions {
                        Critical(BasicConstraints.notCertificateAuthority)
                        Critical(KeyUsage(digitalSignature: true))
                        try ExtendedKeyUsage(Self.extendedKeyUsages(for: role))
                        SubjectAlternativeNames([
                            .uniformResourceIdentifier(identity.uri)
                        ])
                        SubjectKeyIdentifier(hash: leafPrivateKey.publicKey)
                        AuthorityKeyIdentifier(keyIdentifier: authorityKeyIdentifier)
                    },
                    issuerPrivateKey: authorityPrivateKey
                )
                let leafSecCertificate = try SecCertificate.makeWithCertificate(leaf)
                try addCertificate(
                    leafSecCertificate,
                    clusterID: clusterID,
                    nodeID: nodeID,
                    generation: generation,
                    ownershipID: ownershipID,
                    role: itemRole
                )
                created[created.count - 1].certificate = leafSecCertificate
                leaves.append(
                    try ClusterCertificateLeafCredential(
                        identity: identity,
                        certificateDER: SecCertificateCopyData(leafSecCertificate) as Data,
                        references: references(
                            key: leafKey,
                            certificate: leafSecCertificate
                        )
                    )
                )
            }
            let record = try ClusterCertificateGenerationCredential(
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                authority: ClusterCertificateAuthorityCredential(
                    authority: authority,
                    references: authorityReferences
                ),
                leaves: leaves
            )
            try validateGeneration(record, now: now)
            return record
        } catch let creationError {
            if creationError as? ClusterCertificateLifecycleError == .partialEffect {
                throw creationError
            }
            do {
                try compensateCreated(
                    created,
                    clusterID: clusterID,
                    nodeID: nodeID,
                    generation: generation,
                    ownershipID: ownershipID
                )
            } catch {
                throw ClusterCertificateLifecycleError.partialEffect
            }
            throw creationError
        }
        }
    }

    private func compensateCreated(
        _ created: [(role: ItemRole, key: SecKey?, certificate: SecCertificate?)],
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String
    ) throws {
        for item in created.reversed() {
            if let certificate = item.certificate {
                try deleteCertificate(
                    certificate,
                    clusterID: clusterID,
                    nodeID: nodeID,
                    generation: generation,
                    ownershipID: ownershipID,
                    role: item.role
                )
            }
            if let key = item.key {
                try deleteKey(
                    key,
                    clusterID: clusterID,
                    nodeID: nodeID,
                    generation: generation,
                    ownershipID: ownershipID,
                    role: item.role
                )
            }
        }
    }

    func ensureScopeAvailable(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        roles: [ClusterCertificateRole]
    ) throws {
        try withUserInteractionDisabled {
        try refuseCollision(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            roles: roles.sorted { $0.rawValue < $1.rawValue }
        )
        }
    }

    func validateGeneration(
        _ record: ClusterCertificateGenerationCredential
    ) throws {
        try withUserInteractionDisabled {
        let authorityCertificate = try resolveCertificate(
            reference: record.authority.references.certificatePersistentReference,
            expectedDER: record.authority.authority.certificateDER,
            clusterID: record.clusterID,
            nodeID: record.nodeID,
            generation: record.generation,
            ownershipID: record.ownershipID,
            role: .authority
        )
        let authorityKey = try resolveKey(
            reference: record.authority.references.keyPersistentReference,
            clusterID: record.clusterID,
            nodeID: record.nodeID,
            generation: record.generation,
            ownershipID: record.ownershipID,
            role: .authority
        )
        try requirePair(certificate: authorityCertificate, key: authorityKey)
        let trustBundle = try ClusterCertificateTrustBundle(
            clusterID: record.clusterID,
            activeGeneration: record.generation,
            authorities: [record.authority.authority]
        )
        for leaf in record.leaves {
            let itemRole = ItemRole.leaf(leaf.identity.role)
            let certificate = try resolveCertificate(
                reference: leaf.references.certificatePersistentReference,
                expectedDER: leaf.certificateDER,
                clusterID: record.clusterID,
                nodeID: record.nodeID,
                generation: record.generation,
                ownershipID: record.ownershipID,
                role: itemRole
            )
            let key = try resolveKey(
                reference: leaf.references.keyPersistentReference,
                clusterID: record.clusterID,
                nodeID: record.nodeID,
                generation: record.generation,
                ownershipID: record.ownershipID,
                role: itemRole
            )
            try requirePair(certificate: certificate, key: key)
            do {
                let parsed = try Certificate(derEncoded: Array(leaf.certificateDER))
                let lowerBound = max(
                    record.authority.authority.notValidBeforeMilliseconds,
                    try Self.milliseconds(parsed.notValidBefore)
                )
                let upperBound = min(
                    record.authority.authority.notValidAfterMilliseconds,
                    try Self.milliseconds(parsed.notValidAfter)
                )
                guard lowerBound <= upperBound else {
                    throw ClusterCertificateLifecycleError.tampered
                }
                let validationTime = lowerBound < upperBound
                    ? lowerBound + min(1_000, upperBound - lowerBound)
                    : lowerBound
                _ = try ClusterMutualTLSVerifier(trustBundle: trustBundle).verify(
                    peerCertificateDER: leaf.certificateDER,
                    expectedIdentity: leaf.identity,
                    nowMilliseconds: validationTime
                )
            } catch let error as ClusterCertificateLifecycleError {
                throw error
            } catch {
                throw ClusterCertificateLifecycleError.tampered
            }
        }
        }
    }

    func validateGeneration(
        _ record: ClusterCertificateGenerationCredential,
        now: Date
    ) throws {
        try withUserInteractionDisabled {
        try validateGeneration(record)
        let trustBundle = try ClusterCertificateTrustBundle(
            clusterID: record.clusterID,
            activeGeneration: record.generation,
            authorities: [record.authority.authority]
        )
        let nowMilliseconds = try Self.milliseconds(now)
        guard nowMilliseconds >= record.authority.authority.notValidBeforeMilliseconds else {
            throw ClusterCertificateLifecycleError.credentialNotYetValid
        }
        guard nowMilliseconds <= record.authority.authority.notValidAfterMilliseconds else {
            throw ClusterCertificateLifecycleError.credentialExpired
        }
        for leaf in record.leaves {
            do {
                _ = try ClusterMutualTLSVerifier(trustBundle: trustBundle).verify(
                    peerCertificateDER: leaf.certificateDER,
                    expectedIdentity: leaf.identity,
                    nowMilliseconds: nowMilliseconds
                )
            } catch ClusterCertificateError.certificateNotYetValid {
                throw ClusterCertificateLifecycleError.credentialNotYetValid
            } catch ClusterCertificateError.certificateExpired {
                throw ClusterCertificateLifecycleError.credentialExpired
            } catch ClusterCertificateError.certificateTrustRejected {
                throw ClusterCertificateLifecycleError.credentialExpired
            } catch {
                throw ClusterCertificateLifecycleError.tampered
            }
        }
        }
    }

    func identityHandle(
        generation: ClusterCertificateGenerationCredential,
        role: ClusterCertificateRole,
        now: Date
    ) throws -> ClusterCertificateIdentityHandle {
        try withUserInteractionDisabled {
        try validateGeneration(generation, now: now)
        guard let credential = generation.leaf(role: role) else {
            throw ClusterCertificateLifecycleError.invalidConfiguration(
                "requested role was not provisioned"
            )
        }
        let certificate = try resolveCertificate(
            reference: credential.references.certificatePersistentReference,
            expectedDER: credential.certificateDER,
            clusterID: generation.clusterID,
            nodeID: generation.nodeID,
            generation: generation.generation,
            ownershipID: generation.ownershipID,
            role: .leaf(role)
        )
        let key = try resolveKey(
            reference: credential.references.keyPersistentReference,
            clusterID: generation.clusterID,
            nodeID: generation.nodeID,
            generation: generation.generation,
            ownershipID: generation.ownershipID,
            role: .leaf(role)
        )
        try requirePair(certificate: certificate, key: key)
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(
            keychain,
            certificate,
            &identity
        )
        guard status == errSecSuccess, let identity else {
            throw Self.mapStatus(status)
        }
        var identityKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &identityKey) == errSecSuccess,
              let identityKey else {
            throw ClusterCertificateLifecycleError.tampered
        }
        try requirePair(certificate: certificate, key: identityKey)
        let authority = try resolveCertificate(
            reference: generation.authority.references.certificatePersistentReference,
            expectedDER: generation.authority.authority.certificateDER,
            clusterID: generation.clusterID,
            nodeID: generation.nodeID,
            generation: generation.generation,
            ownershipID: generation.ownershipID,
            role: .authority
        )
        return ClusterCertificateIdentityHandle(
            identity: identity,
            certificateChain: [authority],
            credential: credential
        )
        }
    }

    func cleanupGeneration(
        _ record: ClusterCertificateGenerationCredential
    ) throws {
        try withUserInteractionDisabled {
        for leaf in record.leaves.reversed() {
            try deleteOwned(
                references: leaf.references,
                expectedDER: leaf.certificateDER,
                clusterID: record.clusterID,
                nodeID: record.nodeID,
                generation: record.generation,
                ownershipID: record.ownershipID,
                role: .leaf(leaf.identity.role)
            )
        }
        try deleteOwned(
            references: record.authority.references,
            expectedDER: record.authority.authority.certificateDER,
            clusterID: record.clusterID,
            nodeID: record.nodeID,
            generation: record.generation,
            ownershipID: record.ownershipID,
            role: .authority
        )
        }
    }

    func cleanupPartialGeneration(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        roles: [ClusterCertificateRole]
    ) throws {
        try withUserInteractionDisabled {
        for role in roles.reversed() {
            try cleanupPartialItem(
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: .leaf(role)
            )
        }
        try cleanupPartialItem(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: .authority
        )
        }
    }

    private func cleanupPartialItem(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws {
        let key = try copyKeyIfPresent(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        )
        let certificate = try copyCertificateIfPresent(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        )
        if let certificate {
            guard let key else {
                throw ClusterCertificateLifecycleError.tampered
            }
            try requirePair(certificate: certificate, key: key)
            try deleteCertificate(
                certificate,
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: role
            )
        }
        if let key {
            try deleteKey(
                key,
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: role
            )
        }
    }

    private func deleteOwned(
        references: ClusterCertificateOwnedReferences,
        expectedDER: Data,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws {
        let certificate = try resolveCertificateIfPresent(
            reference: references.certificatePersistentReference,
            expectedDER: expectedDER,
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        )
        let key = try resolveKeyIfPresent(
            reference: references.keyPersistentReference,
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        )
        if let key {
            guard let expectedCertificate = SecCertificateCreateWithData(
                nil,
                expectedDER as CFData
            ) else {
                throw ClusterCertificateLifecycleError.tampered
            }
            try requirePair(certificate: expectedCertificate, key: key)
        }
        if let certificate, let key {
            try requirePair(certificate: certificate, key: key)
        }
        if let certificate {
            try deleteCertificate(
                certificate,
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: role
            )
        }
        if let key {
            try deleteKey(
                key,
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: role
            )
        }
    }

    private func refuseCollision(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        roles: [ClusterCertificateRole]
    ) throws {
        for role in [ItemRole.authority] + roles.map(ItemRole.leaf) {
            guard try copyKeyIfPresent(
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: role
            ) == nil,
            try copyCertificateIfPresent(
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: role
            ) == nil else {
                throw ClusterCertificateLifecycleError.collision
            }
        }
    }

    private func generateKey(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws -> SecKey {
        let tag = applicationTag(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            role: role
        )
        let label = label(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        )
        let privateAttributes: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrIsSensitive: true,
            kSecAttrIsExtractable: false,
            kSecAttrApplicationTag: tag,
            kSecAttrLabel: label,
        ]
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsSensitive: true,
            kSecAttrIsExtractable: false,
            kSecPrivateKeyAttrs: privateAttributes,
            kSecUseKeychain: keychain,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error = error?.takeRetainedValue() {
                throw Self.mapStatus(OSStatus((error as Error as NSError).code))
            }
            throw ClusterCertificateLifecycleError.keychainFailure(errSecParam)
        }
        do {
            guard let persisted = try copyKeyIfPresent(
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: role
            ), try publicKeyData(persisted) == publicKeyData(key) else {
                throw ClusterCertificateLifecycleError.tampered
            }
            return persisted
        } catch {
            var cleanup: [CFString: Any] = [
                kSecClass: kSecClassKey,
                kSecMatchItemList: [key],
            ]
            applySearch(to: &cleanup)
            let cleanupStatus = SecItemDelete(cleanup as CFDictionary)
            guard cleanupStatus == errSecSuccess
                    || cleanupStatus == errSecItemNotFound else {
                throw ClusterCertificateLifecycleError.partialEffect
            }
            throw error
        }
    }

    private func addCertificate(
        _ certificate: SecCertificate,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws {
        let status = SecCertificateAddToKeychain(certificate, keychain)
        guard status == errSecSuccess else {
            throw Self.mapStatus(status)
        }
        var exact: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecMatchItemList: [certificate],
        ]
        applySearch(to: &exact)
        let updateStatus = SecItemUpdate(
            exact as CFDictionary,
            [
                kSecAttrLabel: label(
                    clusterID: clusterID,
                    nodeID: nodeID,
                    generation: generation,
                    ownershipID: ownershipID,
                    role: role
                )
            ] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            let cleanupStatus = SecItemDelete(exact as CFDictionary)
            guard cleanupStatus == errSecSuccess
                    || cleanupStatus == errSecItemNotFound else {
                throw ClusterCertificateLifecycleError.partialEffect
            }
            throw Self.mapStatus(updateStatus)
        }
        do {
            try requireCertificateLabel(
                certificate,
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: role
            )
        } catch {
            let cleanupStatus = SecItemDelete(exact as CFDictionary)
            guard cleanupStatus == errSecSuccess
                    || cleanupStatus == errSecItemNotFound else {
                throw ClusterCertificateLifecycleError.partialEffect
            }
            throw error
        }
    }

    private func references(
        key: SecKey,
        certificate: SecCertificate
    ) throws -> ClusterCertificateOwnedReferences {
        try ClusterCertificateOwnedReferences(
            keyPersistentReference: persistentReference(
                item: key,
                itemClass: kSecClassKey
            ),
            certificatePersistentReference: persistentReference(
                item: certificate,
                itemClass: kSecClassCertificate
            )
        )
    }

    private func persistentReference(
        item: CFTypeRef,
        itemClass: CFString
    ) throws -> Data {
        var resolvedQuery: [CFString: Any] = [
            kSecClass: itemClass,
            kSecMatchItemList: [item],
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        applyNonInteractiveLookup(to: &resolvedQuery)
        applySearch(to: &resolvedQuery)
        var resolved: CFTypeRef?
        let resolvedStatus = SecItemCopyMatching(
            resolvedQuery as CFDictionary,
            &resolved
        )
        guard resolvedStatus == errSecSuccess, let resolved else {
            throw resolvedStatus == errSecSuccess
                ? ClusterCertificateLifecycleError.tampered
                : Self.mapStatus(resolvedStatus)
        }
        if itemClass == kSecClassKey {
            guard CFGetTypeID(resolved) == SecKeyGetTypeID() else {
                throw ClusterCertificateLifecycleError.tampered
            }
        } else if itemClass == kSecClassCertificate {
            guard CFGetTypeID(resolved) == SecCertificateGetTypeID() else {
                throw ClusterCertificateLifecycleError.tampered
            }
        }
        let resolvedItem = resolved
        var query: [CFString: Any] = [
            kSecClass: itemClass,
            kSecMatchItemList: [resolvedItem],
            kSecReturnPersistentRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        applyNonInteractiveLookup(to: &query)
        applySearch(to: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let reference = result as? Data else {
            throw status == errSecSuccess
                ? ClusterCertificateLifecycleError.tampered
                : Self.mapStatus(status)
        }
        return reference
    }

    private func resolveKey(
        reference: Data,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws -> SecKey {
        guard let key = try resolveKeyIfPresent(
            reference: reference,
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        ) else {
            throw ClusterCertificateLifecycleError.tampered
        }
        return key
    }

    private func resolveKeyIfPresent(
        reference: Data,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws -> SecKey? {
        guard !reference.isEmpty,
              reference.count
                <= ClusterCertificateLifecycleContract.maximumPersistentReferenceBytes else {
            throw ClusterCertificateLifecycleError.tampered
        }
        guard let evidence = try persistedKeyEvidence(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        ) else {
            return nil
        }
        guard evidence.persistentReference == reference else {
            throw ClusterCertificateLifecycleError.tampered
        }
        return try resolveKeyReference(evidence.persistentReference)
    }

    private func resolveKeyReference(_ reference: Data) throws -> SecKey? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecMatchItemList: [reference],
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        applyNonInteractiveLookup(to: &query)
        applySearch(to: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let result,
              CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw status == errSecSuccess
                ? ClusterCertificateLifecycleError.tampered
                : Self.mapStatus(status)
        }
        let key = result as! SecKey
        try requireCryptographicKey(key)
        return key
    }

    private func resolveCertificate(
        reference: Data,
        expectedDER: Data,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws -> SecCertificate {
        guard let certificate = try resolveCertificateIfPresent(
            reference: reference,
            expectedDER: expectedDER,
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        ) else {
            throw ClusterCertificateLifecycleError.tampered
        }
        return certificate
    }

    private func resolveCertificateIfPresent(
        reference: Data,
        expectedDER: Data,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws -> SecCertificate? {
        guard !reference.isEmpty,
              reference.count
                <= ClusterCertificateLifecycleContract.maximumPersistentReferenceBytes else {
            throw ClusterCertificateLifecycleError.tampered
        }
        guard let certificate = try resolveCertificateReference(reference) else {
            return nil
        }
        guard SecCertificateCopyData(certificate) as Data == expectedDER else {
            throw ClusterCertificateLifecycleError.tampered
        }
        try requireCertificateLabel(
            certificate,
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        )
        return certificate
    }

    private func resolveCertificateReference(
        _ reference: Data
    ) throws -> SecCertificate? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecMatchItemList: [reference],
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        applyNonInteractiveLookup(to: &query)
        applySearch(to: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let result,
              CFGetTypeID(result) == SecCertificateGetTypeID() else {
            throw status == errSecSuccess
                ? ClusterCertificateLifecycleError.tampered
                : Self.mapStatus(status)
        }
        return result as! SecCertificate
    }

    private func copyKeyIfPresent(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws -> SecKey? {
        guard let evidence = try persistedKeyEvidence(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        ) else {
            return nil
        }
        return try resolveKeyReference(evidence.persistentReference)
    }

    private func persistedKeyEvidence(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws -> PersistedItemEvidence? {
        let expectedTag = applicationTag(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            role: role
        )
        let expectedLabel = label(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        )
        var query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: expectedTag,
            kSecReturnAttributes: true,
            kSecReturnPersistentRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        applyNonInteractiveLookup(to: &query)
        applySearch(to: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let matches = result as? NSArray,
              matches.count == 1,
              let attributes = matches[0] as? NSDictionary,
              attributes[kSecAttrApplicationTag] as? Data == expectedTag,
              attributes[kSecAttrLabel] as? String == expectedLabel,
              Self.boolean(attributes[kSecAttrIsPermanent]) == true,
              let reference = attributes[kSecValuePersistentRef] as? Data,
              !reference.isEmpty,
              reference.count
                <= ClusterCertificateLifecycleContract.maximumPersistentReferenceBytes else {
            throw status == errSecSuccess
                ? ClusterCertificateLifecycleError.tampered
                : Self.mapStatus(status)
        }
        return PersistedItemEvidence(persistentReference: reference)
    }

    private func copyCertificateIfPresent(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws -> SecCertificate? {
        let expectedLabel = label(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        )
        var query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: expectedLabel,
            kSecReturnAttributes: true,
            kSecReturnPersistentRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        applyNonInteractiveLookup(to: &query)
        applySearch(to: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let matches = result as? NSArray,
              matches.count == 1,
              let attributes = matches[0] as? NSDictionary,
              attributes[kSecAttrLabel] as? String == expectedLabel,
              let reference = attributes[kSecValuePersistentRef] as? Data,
              !reference.isEmpty,
              reference.count
                <= ClusterCertificateLifecycleContract.maximumPersistentReferenceBytes,
              let certificate = try resolveCertificateReference(reference) else {
            throw status == errSecSuccess
                ? ClusterCertificateLifecycleError.tampered
                : Self.mapStatus(status)
        }
        try requireCertificateLabel(
            certificate,
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        )
        return certificate
    }

    private func requireCryptographicKey(_ key: SecKey) throws {
        guard let attributes = SecKeyCopyAttributes(key) as NSDictionary? else {
            throw ClusterCertificateLifecycleError.tampered
        }
        let keySize = (attributes[kSecAttrKeySizeInBits] as? NSNumber)?.intValue
            ?? Int(attributes[kSecAttrKeySizeInBits] as? String ?? "")
        guard Self.hasExpectedKeyType(attributes[kSecAttrKeyType]),
              keySize == 256,
              Self.hasExpectedKeyClass(attributes[kSecAttrKeyClass]),
              Self.boolean(attributes[kSecAttrCanSign]) == true,
              SecKeyIsAlgorithmSupported(
                key,
                .sign,
                .ecdsaSignatureMessageX962SHA256
              ) else {
            throw ClusterCertificateLifecycleError.tampered
        }
        var exportError: Unmanaged<CFError>?
        guard SecKeyCopyExternalRepresentation(key, &exportError) == nil else {
            throw ClusterCertificateLifecycleError.tampered
        }
        _ = exportError?.takeRetainedValue()
        guard SecKeyCopyPublicKey(key) != nil else {
            throw ClusterCertificateLifecycleError.tampered
        }
    }

    static func hasExpectedKeyType(_ attribute: Any?) -> Bool {
        guard let keyType = attribute as? String else { return false }
        return keyType == (kSecAttrKeyTypeECSECPrimeRandom as String)
    }

    private static func hasExpectedKeyClass(_ attribute: Any?) -> Bool {
        guard let keyClass = attribute as? String else { return false }
        return keyClass == (kSecAttrKeyClassPrivate as String)
    }

    private static func boolean(_ attribute: Any?) -> Bool? {
        (attribute as? NSNumber)?.boolValue ?? attribute as? Bool
    }

    private func requireUnlockedKeychain() throws {
        var keychainStatus: SecKeychainStatus = 0
        let status = SecKeychainGetStatus(keychain, &keychainStatus)
        guard status == errSecSuccess else {
            throw Self.mapStatus(status)
        }
        guard keychainStatus & UInt32(kSecUnlockStateStatus) != 0 else {
            throw ClusterCertificateLifecycleError.keychainLocked
        }
    }

    private func requireCertificateLabel(
        _ certificate: SecCertificate,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws {
        var query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecMatchItemList: [certificate],
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        applyNonInteractiveLookup(to: &query)
        applySearch(to: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let attributes = result as? NSDictionary,
              attributes[kSecAttrLabel] as? String == label(
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: role
              ) else {
            throw status == errSecSuccess
                ? ClusterCertificateLifecycleError.tampered
                : Self.mapStatus(status)
        }
    }

    private func requirePair(certificate: SecCertificate, key: SecKey) throws {
        guard try publicKeyData(certificate) == publicKeyData(key) else {
            throw ClusterCertificateLifecycleError.tampered
        }
    }

    private func publicKeyData(_ certificate: SecCertificate) throws -> Data {
        guard let key = SecCertificateCopyKey(certificate) else {
            throw ClusterCertificateLifecycleError.tampered
        }
        return try publicKeyData(key)
    }

    private func publicKeyData(_ key: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw ClusterCertificateLifecycleError.tampered
        }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw ClusterCertificateLifecycleError.tampered
        }
        return data
    }

    private func deleteCertificate(
        _ certificate: SecCertificate,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws {
        try requireCertificateLabel(
            certificate,
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        )
        var query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecMatchItemList: [certificate],
            kSecAttrLabel: label(
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: role
            ),
        ]
        applySearch(to: &query)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.mapStatus(status)
        }
    }

    private func deleteKey(
        _ key: SecKey,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) throws {
        guard let evidence = try persistedKeyEvidence(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: generation,
            ownershipID: ownershipID,
            role: role
        ), let persisted = try resolveKeyReference(
            evidence.persistentReference
        ), try publicKeyData(persisted) == publicKeyData(key) else {
            throw ClusterCertificateLifecycleError.tampered
        }
        try requireCryptographicKey(persisted)
        var query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecMatchItemList: [key],
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: applicationTag(
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                role: role
            ),
            kSecAttrLabel: label(
                clusterID: clusterID,
                nodeID: nodeID,
                generation: generation,
                ownershipID: ownershipID,
                role: role
            ),
        ]
        applySearch(to: &query)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.mapStatus(status)
        }
    }

    private func applicationTag(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        role: ItemRole
    ) -> Data {
        Data(
            "\(ClusterCertificateLifecycleContract.keyApplicationTagPrefix)."
                .appending(clusterID.rawValue)
                .appending(".\(nodeID.rawValue).g\(generation.value).\(role.value)")
                .utf8
        )
    }

    private func label(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        generation: ClusterCertificateGeneration,
        ownershipID: String,
        role: ItemRole
    ) -> String {
        "Hostwright Cluster Certificate v1 \(clusterID.rawValue) "
            + "\(nodeID.rawValue) g\(generation.value) \(role.value) \(ownershipID)"
    }

    private func applySearch(to query: inout [CFString: Any]) {
        query[kSecMatchSearchList] = [keychain]
    }

    private static func extendedKeyUsages(
        for role: ClusterCertificateRole
    ) -> [ExtendedKeyUsage.Usage] {
        switch role {
        case .etcdPeer:
            [.serverAuth, .clientAuth]
        case .etcdClient, .nodeAgentClient:
            [.clientAuth]
        case .nodeAgentServer:
            [.serverAuth]
        }
    }

    private static func secureSerialNumber() throws -> Certificate.SerialNumber {
        for _ in 0..<2 {
            var bytes = [UInt8](repeating: 0, count: 20)
            let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
                guard let baseAddress = buffer.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
            }
            guard status == errSecSuccess else { throw mapStatus(status) }
            if bytes.contains(where: { $0 != 0 }) {
                return Certificate.SerialNumber(bytes: ArraySlice(bytes))
            }
        }
        throw ClusterCertificateLifecycleError.keychainFailure(errSecInternalError)
    }

    private static func milliseconds(_ date: Date) throws -> UInt64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value <= Double(UInt64.max) else {
            throw ClusterCertificateLifecycleError.invalidConfiguration(
                "clock is outside the supported range"
            )
        }
        return UInt64(value.rounded(.down))
    }

    private static func mapStatus(
        _ status: OSStatus
    ) -> ClusterCertificateLifecycleError {
        switch status {
        case errSecDuplicateItem:
            .collision
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed:
            .keychainLocked
        case errSecNotAvailable, errSecMissingEntitlement, errSecNoAccessForItem:
            .accessDenied
        case errSecUserCanceled:
            .cancelled
        case errSecItemNotFound:
            .tampered
        default:
            .keychainFailure(status)
        }
    }
}

public final class ClusterCertificateLifecycle:
    @unchecked Sendable,
    ClusterSessionCredentialGenerationAuthorizing
{
    private let files: ClusterCertificateLifecycleFileStore
    private let keychain: ClusterCertificateKeychainStore

    public init(metadataDirectory: URL) throws {
        let keychain = try ClusterCertificateKeychainStore.productionDefault()
        self.files = try ClusterCertificateLifecycleFileStore(rootURL: metadataDirectory)
        self.keychain = keychain
    }

    init(metadataDirectory: URL, keychain: SecKeychain) throws {
        self.files = try ClusterCertificateLifecycleFileStore(rootURL: metadataDirectory)
        self.keychain = ClusterCertificateKeychainStore(keychain: keychain)
    }

    @discardableResult
    public func bootstrap(
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        roles: [ClusterCertificateRole] = ClusterCertificateRole.allCases,
        authorityValidity: TimeInterval =
            ClusterCertificateLifecycleContract.defaultAuthorityValidity,
        leafValidity: TimeInterval =
            ClusterCertificateLifecycleContract.defaultLeafValidity,
        now: Date = Date()
    ) throws -> ClusterCertificateLifecycleMetadata {
        try files.withLock {
            let existing = try recoverLocked()
            guard existing == nil else {
                throw ClusterCertificateLifecycleError.alreadyBootstrapped
            }
            return try createAndActivate(
                metadata: nil,
                clusterID: clusterID,
                nodeID: nodeID,
                roles: roles,
                targetGeneration: ClusterCertificateGeneration(1),
                authorityValidity: authorityValidity,
                leafValidity: leafValidity,
                now: now
            )
        }
    }

    @discardableResult
    public func beginRotation(
        authorityValidity: TimeInterval =
            ClusterCertificateLifecycleContract.defaultAuthorityValidity,
        leafValidity: TimeInterval =
            ClusterCertificateLifecycleContract.defaultLeafValidity,
        now: Date = Date()
    ) throws -> ClusterCertificateLifecycleMetadata {
        try files.withLock {
            guard let metadata = try recoverLocked() else {
                throw ClusterCertificateLifecycleError.notBootstrapped
            }
            guard metadata.retiringGeneration == nil else {
                throw ClusterCertificateError.rotationAlreadyInProgress
            }
            return try createAndActivate(
                metadata: metadata,
                clusterID: metadata.clusterID,
                nodeID: metadata.nodeID,
                roles: metadata.roles,
                targetGeneration: metadata.currentGeneration.advanced(),
                authorityValidity: authorityValidity,
                leafValidity: leafValidity,
                now: now
            )
        }
    }

    @discardableResult
    public func completeRotation(
        now: Date = Date()
    ) throws -> ClusterCertificateLifecycleMetadata {
        return try files.withLock {
            guard let metadata = try recoverLocked() else {
                throw ClusterCertificateLifecycleError.notBootstrapped
            }
            guard let retiringGeneration = metadata.retiringGeneration,
                  let retiring = metadata.generations.first(where: {
                    $0.generation == retiringGeneration
                  }) else {
                throw ClusterCertificateError.rotationNotInProgress
            }
            guard try files.loadJournal() == nil else {
                throw ClusterCertificateLifecycleError.transitionInProgress
            }
            let journal = try ClusterCertificateLifecycleJournal(
                stage: .retiring,
                expectedRevision: metadata.revision,
                clusterID: metadata.clusterID,
                nodeID: metadata.nodeID,
                roles: metadata.roles,
                sourceGeneration: retiringGeneration,
                targetGeneration: metadata.currentGeneration,
                preparedGeneration: nil,
                retiringCredential: retiring,
                startedAtMilliseconds: try Self.milliseconds(now)
            )
            try files.saveJournal(journal)
            let completed = try ClusterCertificateLifecycleStateMachine.retire(
                metadata: metadata,
                journal: journal
            )
            try keychain.validateGeneration(completed.generations[0])
            try keychain.cleanupGeneration(retiring)
            try files.saveMetadata(completed)
            try files.removeJournal()
            return completed
        }
    }

    @discardableResult
    public func recover(now: Date = Date()) throws -> ClusterCertificateLifecycleMetadata? {
        _ = now
        return try files.withLock {
            try recoverLocked()
        }
    }

    public func metadata(now: Date = Date()) throws -> ClusterCertificateLifecycleMetadata {
        _ = now
        return try files.withLock {
            guard let metadata = try recoverLocked() else {
                throw ClusterCertificateLifecycleError.notBootstrapped
            }
            return metadata
        }
    }

    /// Resolves certificate-derived session credentials against the same
    /// digest-bound generation metadata used for lifecycle recovery. Both
    /// generations remain admitted during overlap; publication of completed
    /// retirement removes the old generation from this decision immediately.
    public func permits(
        _ credential: ClusterSessionCredential,
        nowMilliseconds: UInt64
    ) throws -> Bool {
        try credential.validate()
        guard case .x509(let binding) = credential.provenance else {
            return false
        }
        return try files.withLock {
            guard let metadata = try recoverLocked() else {
                throw ClusterCertificateLifecycleError.notBootstrapped
            }
            return try metadata.generations.contains { generation in
                guard let leaf = generation.leaf(role: .nodeAgentClient),
                      binding.identity == leaf.identity,
                      binding.identity.clusterID == metadata.clusterID,
                      binding.identity.nodeID == metadata.nodeID,
                      binding.identity.generation == generation.generation,
                      binding.leafCertificateSHA256 == leaf.certificateSHA256,
                      binding.authorityCertificateSHA256
                        == generation.authority.authority.certificateSHA256 else {
                    return false
                }
                let certificate = try Certificate(
                    derEncoded: Array(leaf.certificateDER)
                )
                let notValidBefore = max(
                    generation.authority.authority.notValidBeforeMilliseconds,
                    try Self.milliseconds(certificate.notValidBefore)
                )
                let notValidAfter = min(
                    generation.authority.authority.notValidAfterMilliseconds,
                    try Self.milliseconds(certificate.notValidAfter)
                )
                return nowMilliseconds >= notValidBefore
                    && nowMilliseconds <= notValidAfter
                    && Data(certificate.publicKey.subjectPublicKeyInfoBytes)
                        == credential.p256X963PublicKey
            }
        }
    }

    public func identity(
        role: ClusterCertificateRole,
        generation requestedGeneration: ClusterCertificateGeneration? = nil,
        now: Date = Date()
    ) throws -> ClusterCertificateIdentityHandle {
        try files.withLock {
            guard let metadata = try recoverLocked() else {
                throw ClusterCertificateLifecycleError.notBootstrapped
            }
            let generation = requestedGeneration ?? metadata.currentGeneration
            guard let record = metadata.generations.first(where: {
                $0.generation == generation
            }) else {
                throw ClusterCertificateError.trustAnchorNotFound
            }
            return try keychain.identityHandle(
                generation: record,
                role: role,
                now: now
            )
        }
    }

    private func createAndActivate(
        metadata: ClusterCertificateLifecycleMetadata?,
        clusterID: ClusterID,
        nodeID: ClusterNodeID,
        roles: [ClusterCertificateRole],
        targetGeneration: ClusterCertificateGeneration,
        authorityValidity: TimeInterval,
        leafValidity: TimeInterval,
        now: Date
    ) throws -> ClusterCertificateLifecycleMetadata {
        guard try files.loadJournal() == nil else {
            throw ClusterCertificateLifecycleError.transitionInProgress
        }
        let creating = try ClusterCertificateLifecycleJournal(
            stage: .creating,
            expectedRevision: metadata?.revision ?? 0,
            clusterID: clusterID,
            nodeID: nodeID,
            roles: roles,
            sourceGeneration: metadata?.currentGeneration,
            targetGeneration: targetGeneration,
            preparedGeneration: nil,
            retiringCredential: nil,
            startedAtMilliseconds: try Self.milliseconds(now)
        )
        try keychain.ensureScopeAvailable(
            clusterID: clusterID,
            nodeID: nodeID,
            generation: targetGeneration,
            ownershipID: creating.operationID,
            roles: creating.roles
        )
        try files.saveJournal(creating)
        let prepared: ClusterCertificateGenerationCredential
        do {
            prepared = try keychain.createGeneration(
                clusterID: clusterID,
                nodeID: nodeID,
                generation: targetGeneration,
                ownershipID: creating.operationID,
                roles: creating.roles,
                authorityValidity: authorityValidity,
                leafValidity: leafValidity,
                now: now
            )
        } catch let creationError {
            if creationError as? ClusterCertificateLifecycleError == .partialEffect {
                throw creationError
            }
            try files.removeJournal()
            throw creationError
        }
        let activating = try creating.activating(prepared)
        try files.saveJournal(activating)
        try keychain.validateGeneration(prepared, now: now)
        let activated = try ClusterCertificateLifecycleStateMachine.activate(
            metadata: metadata,
            journal: activating
        )
        try files.saveMetadata(activated)
        try files.removeJournal()
        return activated
    }

    private func recoverLocked() throws -> ClusterCertificateLifecycleMetadata? {
        guard let journal = try files.loadJournal() else {
            return try validatedMetadata()
        }
        let metadata = try files.loadMetadata()
        switch journal.stage {
        case .creating:
            if let metadata {
                guard metadata.revision == journal.expectedRevision,
                      metadata.clusterID == journal.clusterID,
                      metadata.nodeID == journal.nodeID,
                      metadata.roles == journal.roles,
                      metadata.currentGeneration == journal.sourceGeneration else {
                    throw ClusterCertificateLifecycleError.concurrentMutation
                }
                for generation in metadata.generations {
                    try keychain.validateGeneration(generation)
                }
            } else {
                guard journal.expectedRevision == 0,
                      journal.sourceGeneration == nil,
                      journal.targetGeneration.value == 1 else {
                    throw ClusterCertificateLifecycleError.concurrentMutation
                }
            }
            try keychain.cleanupPartialGeneration(
                clusterID: journal.clusterID,
                nodeID: journal.nodeID,
                generation: journal.targetGeneration,
                ownershipID: journal.operationID,
                roles: journal.roles
            )
            try files.removeJournal()
            return metadata
        case .activating:
            guard let prepared = journal.preparedGeneration else {
                throw ClusterCertificateLifecycleError.tampered
            }
            if let metadata {
                for generation in metadata.generations {
                    try keychain.validateGeneration(generation)
                }
            }
            try keychain.validateGeneration(prepared)
            let activated = try ClusterCertificateLifecycleStateMachine.activate(
                metadata: metadata,
                journal: journal
            )
            try files.saveMetadata(activated)
            try files.removeJournal()
            return activated
        case .retiring:
            guard let metadata,
                  let retiring = journal.retiringCredential else {
                throw ClusterCertificateLifecycleError.concurrentMutation
            }
            let completed = try ClusterCertificateLifecycleStateMachine.retire(
                metadata: metadata,
                journal: journal
            )
            try keychain.validateGeneration(completed.generations[0])
            try keychain.cleanupGeneration(retiring)
            try files.saveMetadata(completed)
            try files.removeJournal()
            return completed
        }
    }

    private func validatedMetadata() throws -> ClusterCertificateLifecycleMetadata? {
        guard let metadata = try files.loadMetadata() else { return nil }
        for generation in metadata.generations {
            try keychain.validateGeneration(generation)
        }
        return metadata
    }

    private static func milliseconds(_ date: Date) throws -> UInt64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value <= Double(UInt64.max) else {
            throw ClusterCertificateLifecycleError.invalidConfiguration(
                "clock is outside the supported range"
            )
        }
        return UInt64(value.rounded(.down))
    }
}
