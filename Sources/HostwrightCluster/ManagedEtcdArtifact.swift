import CryptoKit
import Darwin
import Foundation
import HostwrightCore

public enum ManagedEtcdPlatform: String, Codable, CaseIterable, Equatable, Sendable {
    case darwinArm64 = "darwin-arm64"
    case linuxArm64 = "linux-arm64"
}

public enum ManagedEtcdArchiveKind: String, Codable, CaseIterable, Equatable, Sendable {
    case zip
    case tarGz = "tar.gz"
}

public enum ManagedEtcdError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidArtifactDescriptor(String)
    case archiveNotFound
    case archiveTooLarge
    case archiveUnreadable(String)
    case checksumMismatch(expected: String, actual: String)
    case unsafeArchivePath(String)
    case unsafeArchiveEntryType(String)
    case archiveMissingExecutable(String)
    case cancelled
    case invalidLayout(String)
    case pathOutsideOwnedBoundary(String)
    case unsafePermissions(String)
    case cleanupRefused(String)
    case invalidSnapshotID(String)

    public var description: String {
        switch self {
        case .invalidArtifactDescriptor: "Managed etcd artifact descriptor is invalid."
        case .archiveNotFound: "Managed etcd archive does not exist as a regular file."
        case .archiveTooLarge: "Managed etcd archive exceeds the bounded acceptance size."
        case .archiveUnreadable: "Managed etcd archive could not be inspected safely."
        case .checksumMismatch: "Managed etcd archive checksum does not match the pinned digest."
        case .unsafeArchivePath: "Managed etcd archive contains an unsafe path."
        case .unsafeArchiveEntryType: "Managed etcd archive contains an unsafe entry type."
        case .archiveMissingExecutable: "Managed etcd archive does not contain the expected executable."
        case .cancelled: "Managed etcd archive acceptance was cancelled."
        case .invalidLayout: "Managed etcd private layout is invalid."
        case .pathOutsideOwnedBoundary: "Managed etcd path is outside the exact owned boundary."
        case .unsafePermissions: "Managed etcd path permissions are unsafe."
        case .cleanupRefused: "Managed etcd cleanup was refused."
        case .invalidSnapshotID: "Managed etcd snapshot ID is invalid."
        }
    }
}

public struct ManagedEtcdArtifact: Codable, Equatable, Hashable, Sendable {
    public let version: String
    public let platform: ManagedEtcdPlatform
    public let archiveKind: ManagedEtcdArchiveKind
    public let archiveFileName: String
    public let downloadURL: String
    public let sha256: String

    public static let darwinArm64: Self = try! Self(
        version: "v3.7.1",
        platform: .darwinArm64,
        archiveKind: .zip,
        archiveFileName: "etcd-v3.7.1-darwin-arm64.zip",
        downloadURL: "https://github.com/etcd-io/etcd/releases/download/v3.7.1/etcd-v3.7.1-darwin-arm64.zip",
        sha256: "a3e839d9128e170c299b1592bed92d8327f258eb94923aea24a0ccf923cf27e9"
    )

    public static let linuxArm64: Self = try! Self(
        version: "v3.7.1",
        platform: .linuxArm64,
        archiveKind: .tarGz,
        archiveFileName: "etcd-v3.7.1-linux-arm64.tar.gz",
        downloadURL: "https://github.com/etcd-io/etcd/releases/download/v3.7.1/etcd-v3.7.1-linux-arm64.tar.gz",
        sha256: "d7e25e08f694b6ed7792fc7b7a891fe2c3f3d3dccfe2f3bfdb1545b8200c75b6da"
    )

    public init(
        version: String,
        platform: ManagedEtcdPlatform,
        archiveKind: ManagedEtcdArchiveKind,
        archiveFileName: String,
        downloadURL: String,
        sha256: String
    ) throws {
        self.version = version
        self.platform = platform
        self.archiveKind = archiveKind
        self.archiveFileName = archiveFileName
        self.downloadURL = downloadURL
        self.sha256 = sha256
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case platform
        case archiveKind
        case archiveFileName
        case downloadURL
        case sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .version)
        let platform = try container.decode(ManagedEtcdPlatform.self, forKey: .platform)
        let archiveKind = try container.decode(ManagedEtcdArchiveKind.self, forKey: .archiveKind)
        let archiveFileName = try container.decode(String.self, forKey: .archiveFileName)
        let downloadURL = try container.decode(String.self, forKey: .downloadURL)
        let sha256 = try container.decode(String.self, forKey: .sha256)
        try self.init(
            version: version,
            platform: platform,
            archiveKind: archiveKind,
            archiveFileName: archiveFileName,
            downloadURL: downloadURL,
            sha256: sha256
        )
    }

    public var archiveRoot: String {
        "etcd-" + version + "-" + platform.rawValue
    }

    public var executableEntryPath: String {
        archiveRoot + "/etcd"
    }

    public func validate() throws {
        let expectedFileName: String
        let expectedKind: ManagedEtcdArchiveKind
        let expectedURL: String
        let expectedDigest: String
        switch platform {
        case .darwinArm64:
            expectedFileName = "etcd-v3.7.1-darwin-arm64.zip"
            expectedKind = .zip
            expectedURL = "https://github.com/etcd-io/etcd/releases/download/v3.7.1/etcd-v3.7.1-darwin-arm64.zip"
            expectedDigest = "a3e839d9128e170c299b1592bed92d8327f258eb94923aea24a0ccf923cf27e9"
        case .linuxArm64:
            expectedFileName = "etcd-v3.7.1-linux-arm64.tar.gz"
            expectedKind = .tarGz
            expectedURL = "https://github.com/etcd-io/etcd/releases/download/v3.7.1/etcd-v3.7.1-linux-arm64.tar.gz"
            expectedDigest = "d7e25e08f694b6ed7792fc7b7a891fe2c3f3d3dccfe2f3bfdb1545b8200c75b6da"
        }
        guard version == "v3.7.1",
              archiveKind == expectedKind,
              archiveFileName == expectedFileName,
              downloadURL == expectedURL,
              sha256 == expectedDigest else {
            throw ManagedEtcdError.invalidArtifactDescriptor("descriptor is not the pinned etcd v3.7.1 catalog entry")
        }
        guard let url = URL(string: downloadURL),
              url.scheme == "https",
              url.host == "github.com",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw ManagedEtcdError.invalidArtifactDescriptor("artifact source or digest is unsafe")
        }
    }
}

public enum ManagedEtcdArchiveEntryType: String, Codable, Equatable, Sendable {
    case regular
    case directory
    case symbolicLink
    case hardLink
    case special
}

public struct ManagedEtcdArchiveEntry: Codable, Equatable, Sendable {
    public let path: String
    public let type: ManagedEtcdArchiveEntryType
    public let mode: UInt16?

    public init(path: String, type: ManagedEtcdArchiveEntryType, mode: UInt16? = nil) {
        self.path = path
        self.type = type
        self.mode = mode
    }
}

public enum ManagedEtcdArchiveValidator {
    public static func validate(
        entries: [ManagedEtcdArchiveEntry],
        for artifact: ManagedEtcdArtifact
    ) throws {
        try artifact.validate()
        guard !entries.isEmpty else {
            throw ManagedEtcdError.archiveMissingExecutable(artifact.executableEntryPath)
        }
        var paths = Set<String>()
        var canonicalEntries: [(path: String, type: ManagedEtcdArchiveEntryType)] = []
        for entry in entries {
            let canonicalPath: String
            if entry.type == .directory, entry.path.hasSuffix("/") {
                canonicalPath = String(entry.path.dropLast())
            } else {
                canonicalPath = entry.path
            }
            guard isSafeRelativePath(canonicalPath) else {
                throw ManagedEtcdError.unsafeArchivePath(entry.path)
            }
            guard paths.insert(canonicalPath).inserted else {
                throw ManagedEtcdError.unsafeArchivePath("duplicate archive path " + canonicalPath)
            }
            guard canonicalPath == artifact.archiveRoot || canonicalPath.hasPrefix(artifact.archiveRoot + "/") else {
                throw ManagedEtcdError.unsafeArchivePath(canonicalPath)
            }
            guard entry.type == .regular || entry.type == .directory else {
                throw ManagedEtcdError.unsafeArchiveEntryType(entry.path)
            }
            if let mode = entry.mode {
                let fileType = mode & 0o170000
                if entry.type == .directory {
                    guard fileType == 0 || fileType == 0o040000 else {
                        throw ManagedEtcdError.unsafeArchiveEntryType(entry.path)
                    }
                } else {
                    guard fileType == 0 || fileType == 0o100000 else {
                        throw ManagedEtcdError.unsafeArchiveEntryType(entry.path)
                    }
                }
                guard mode & (0o002 | 0o020 | 0o4000 | 0o2000) == 0 else {
                    throw ManagedEtcdError.unsafePermissions(entry.path)
                }
            }
            canonicalEntries.append((canonicalPath, entry.type))
        }
        guard canonicalEntries.contains(where: { $0.path == artifact.archiveRoot && $0.type == .directory }),
              canonicalEntries.contains(where: { $0.path == artifact.executableEntryPath && $0.type == .regular }) else {
            throw ManagedEtcdError.archiveMissingExecutable(artifact.executableEntryPath)
        }
    }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.contains("\0"),
              !path.contains("\\"),
              !path.contains("//"),
              !path.hasPrefix("/"),
              path.utf8.count <= 4_096 else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            component != "." && component != ".." && !component.isEmpty
        }
    }
}

public struct ManagedEtcdVerifiedArchive: Equatable, Sendable {
    public let artifact: ManagedEtcdArtifact
    public let archivePath: String
    public let archiveSHA256: String
    public let entries: [ManagedEtcdArchiveEntry]
    public let provenance: ManagedEtcdProvenanceRecord

    public init(
        artifact: ManagedEtcdArtifact,
        archivePath: String,
        archiveSHA256: String,
        entries: [ManagedEtcdArchiveEntry],
        provenance: ManagedEtcdProvenanceRecord
    ) {
        self.artifact = artifact
        self.archivePath = archivePath
        self.archiveSHA256 = archiveSHA256
        self.entries = entries
        self.provenance = provenance
    }
}

public struct ManagedEtcdArtifactVerifier: Sendable {
    public static let maximumArchiveBytes = 512 * 1_024 * 1_024

    public init() {}

    public func accept(
        artifact: ManagedEtcdArtifact,
        archiveURL: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> ManagedEtcdVerifiedArchive {
        try artifact.validate()
        guard !cancellation.isCancelled else { throw ManagedEtcdError.cancelled }
        let metadata = try ManagedEtcdFileSystem.regularFileMetadata(archiveURL)
        guard metadata.size > 0 else { throw ManagedEtcdError.archiveNotFound }
        guard metadata.size <= UInt64(Self.maximumArchiveBytes) else {
            throw ManagedEtcdError.archiveTooLarge
        }
        let digest = try ManagedEtcdFileSystem.sha256(
            fileURL: archiveURL,
            cancellation: cancellation
        )
        guard digest == artifact.sha256 else {
            throw ManagedEtcdError.checksumMismatch(expected: artifact.sha256, actual: digest)
        }
        let entries = try ManagedEtcdArchiveInspector.inspect(
            archiveURL: archiveURL,
            artifact: artifact,
            cancellation: cancellation
        )
        try ManagedEtcdArchiveValidator.validate(entries: entries, for: artifact)
        let provenance = ManagedEtcdProvenanceRecord(
            artifact: artifact,
            verifierVersion: "hostwright-cluster-contract-v1",
            entryPaths: entries.map(\.path)
        )
        try provenance.validate()
        return ManagedEtcdVerifiedArchive(
            artifact: artifact,
            archivePath: archiveURL.path,
            archiveSHA256: digest,
            entries: entries,
            provenance: provenance
        )
    }
}

public struct ManagedEtcdProvenanceRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let version: String
    public let platform: ManagedEtcdPlatform
    public let archiveFileName: String
    public let archiveSHA256: String
    public let sourceURL: String
    public let verifierVersion: String
    public let entryPaths: [String]

    public init(
        artifact: ManagedEtcdArtifact,
        verifierVersion: String,
        sourceURL: String? = nil,
        entryPaths: [String] = []
    ) {
        self.schemaVersion = 1
        self.version = artifact.version
        self.platform = artifact.platform
        self.archiveFileName = artifact.archiveFileName
        self.archiveSHA256 = artifact.sha256
        self.sourceURL = sourceURL ?? artifact.downloadURL
        self.verifierVersion = verifierVersion
        self.entryPaths = entryPaths.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case version
        case platform
        case archiveFileName
        case archiveSHA256
        case sourceURL
        case verifierVersion
        case entryPaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.version = try container.decode(String.self, forKey: .version)
        self.platform = try container.decode(ManagedEtcdPlatform.self, forKey: .platform)
        self.archiveFileName = try container.decode(String.self, forKey: .archiveFileName)
        self.archiveSHA256 = try container.decode(String.self, forKey: .archiveSHA256)
        self.sourceURL = try container.decode(String.self, forKey: .sourceURL)
        self.verifierVersion = try container.decode(String.self, forKey: .verifierVersion)
        self.entryPaths = try container.decode([String].self, forKey: .entryPaths)
        try validate()
    }

    public func validate() throws {
        let artifact = try ManagedEtcdArtifact(
            version: version,
            platform: platform,
            archiveKind: platform == .darwinArm64 ? .zip : .tarGz,
            archiveFileName: archiveFileName,
            downloadURL: sourceURL,
            sha256: archiveSHA256
        )
        try artifact.validate()
        guard schemaVersion == 1,
              !verifierVersion.isEmpty,
              entryPaths == entryPaths.sorted(),
              Set(entryPaths).count == entryPaths.count,
              entryPaths.allSatisfy(ManagedEtcdArchiveValidator.isSafeRelativePath),
              entryPaths.allSatisfy({
                  $0 == artifact.archiveRoot || $0.hasPrefix(artifact.archiveRoot + "/")
              }) else {
            throw ManagedEtcdError.invalidArtifactDescriptor("provenance record is not canonical")
        }
    }

    public func canonicalJSON() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decodeCanonical(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(value) == data else {
            throw ManagedEtcdError.invalidArtifactDescriptor("provenance JSON is not canonical")
        }
        return value
    }
}

public struct ManagedEtcdLayout: Codable, Equatable, Sendable {
    public let rootDirectory: String
    public let artifact: ManagedEtcdArtifact
    public let clusterID: ClusterID
    public let nodeID: ClusterNodeID?

    public init(
        rootDirectory: String,
        artifact: ManagedEtcdArtifact,
        clusterID: ClusterID,
        nodeID: ClusterNodeID? = nil
    ) throws {
        guard ManagedEtcdPath.isSafeAbsolutePath(rootDirectory), rootDirectory != "/" else {
            throw ManagedEtcdError.invalidLayout("root directory must be a private absolute path")
        }
        try artifact.validate()
        self.rootDirectory = rootDirectory
        self.artifact = artifact
        self.clusterID = clusterID
        self.nodeID = nodeID
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case rootDirectory
        case artifact
        case clusterID
        case nodeID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            rootDirectory: container.decode(String.self, forKey: .rootDirectory),
            artifact: container.decode(ManagedEtcdArtifact.self, forKey: .artifact),
            clusterID: container.decode(ClusterID.self, forKey: .clusterID),
            nodeID: container.decodeIfPresent(ClusterNodeID.self, forKey: .nodeID)
        )
    }

    public var versionsDirectory: String { rootDirectory + "/versions" }
    public var installDirectory: String {
        versionsDirectory + "/" + artifact.version + "/" + artifact.platform.rawValue
    }
    public var executablePath: String { installDirectory + "/etcd" }
    public var dataDirectory: String { scoped(rootDirectory + "/data") }
    public var configDirectory: String { scoped(rootDirectory + "/config") }
    public var snapshotsDirectory: String { scoped(rootDirectory + "/snapshots") }
    public var metadataDirectory: String { scoped(rootDirectory + "/metadata") }
    public var provenancePath: String { metadataDirectory + "/provenance.json" }
    public var runtimeDirectory: String { scoped(rootDirectory + "/run") }
    public var expectedDirectoryMode: Int { 0o700 }
    public var expectedConfigFileMode: Int { 0o600 }

    public var ownedCleanupPaths: [String] {
        [installDirectory, dataDirectory, configDirectory, snapshotsDirectory, metadataDirectory, runtimeDirectory]
            .sorted()
    }

    public func validate() throws {
        let paths = [
            versionsDirectory,
            installDirectory,
            executablePath,
            dataDirectory,
            configDirectory,
            snapshotsDirectory,
            metadataDirectory,
            provenancePath,
            runtimeDirectory
        ]
        guard paths.allSatisfy({ ManagedEtcdPath.isWithin($0, root: rootDirectory) }) else {
            throw ManagedEtcdError.invalidLayout("canonical path escaped the root directory")
        }
        guard !ownedCleanupPaths.contains(rootDirectory) else {
            throw ManagedEtcdError.invalidLayout("root directory cannot be an owned cleanup target")
        }
    }

    public func prepareDirectories(fileManager: FileManager = .default) throws -> ManagedEtcdLayoutPreparationReport {
        try validate()
        try ManagedEtcdPath.validateExistingParentChain(rootDirectory)
        let versionDirectory = versionsDirectory + "/" + artifact.version
        var directories = [rootDirectory, versionsDirectory, versionDirectory, installDirectory]
        let scopedBases = [
            rootDirectory + "/data",
            rootDirectory + "/config",
            rootDirectory + "/snapshots",
            rootDirectory + "/metadata",
            rootDirectory + "/run"
        ]
        for base in scopedBases {
            directories.append(base)
            let clusterDirectory = base + "/" + clusterID.rawValue
            directories.append(clusterDirectory)
            if let nodeID {
                directories.append(clusterDirectory + "/" + nodeID.rawValue)
            }
        }
        var seen = Set<String>()
        directories = directories.filter { seen.insert($0).inserted }
        for directory in directories {
            try ManagedEtcdFileSystem.ensurePrivateDirectory(directory, fileManager: fileManager)
        }
        return ManagedEtcdLayoutPreparationReport(directories: directories, mode: expectedDirectoryMode)
    }

    private func scoped(_ base: String) -> String {
        if let nodeID {
            return base + "/" + clusterID.rawValue + "/" + nodeID.rawValue
        }
        return base + "/" + clusterID.rawValue
    }
}

public struct ManagedEtcdLayoutPreparationReport: Codable, Equatable, Sendable {
    public let directories: [String]
    public let mode: Int

    public init(directories: [String], mode: Int) {
        self.directories = directories
        self.mode = mode
    }
}

public struct ManagedEtcdInstallPlan: Codable, Equatable, Sendable {
    public let artifact: ManagedEtcdArtifact
    public let archivePath: String
    public let installDirectory: String
    public let executablePath: String
    public let provenancePath: String
    public let directoryMode: Int
    public let executableMode: Int
    public let configFileMode: Int

    public init(verifiedArchive: ManagedEtcdVerifiedArchive, layout: ManagedEtcdLayout) throws {
        guard verifiedArchive.artifact == layout.artifact,
              verifiedArchive.archiveSHA256 == layout.artifact.sha256 else {
            throw ManagedEtcdError.invalidArtifactDescriptor("verified archive does not match layout artifact")
        }
        try layout.validate()
        self.artifact = verifiedArchive.artifact
        self.archivePath = verifiedArchive.archivePath
        self.installDirectory = layout.installDirectory
        self.executablePath = layout.executablePath
        self.provenancePath = layout.provenancePath
        self.directoryMode = layout.expectedDirectoryMode
        self.executableMode = 0o700
        self.configFileMode = layout.expectedConfigFileMode
    }
}

public enum ManagedEtcdInitialClusterState: String, Codable, Equatable, Sendable {
    case new
    case existing
}

public struct ManagedEtcdSupervisedProcessConfiguration: Codable, Equatable, Sendable {
    public let executablePath: String
    public let workingDirectory: String
    public let arguments: [String]
    public let environment: [String: String]
    public let terminationGraceMilliseconds: Int

    public init(
        layout: ManagedEtcdLayout,
        nodeID: ClusterNodeID,
        peerEndpoint: String,
        clientEndpoint: String,
        initialCluster: [ClusterMembershipMember],
        initialClusterState: ManagedEtcdInitialClusterState = .existing,
        terminationGraceMilliseconds: Int = 2_000
    ) throws {
        guard (10...5_000).contains(terminationGraceMilliseconds),
              ManagedEtcdPath.isSafeAbsolutePath(layout.executablePath),
              ManagedEtcdPath.isSafeAbsolutePath(layout.runtimeDirectory) else {
            throw ManagedEtcdError.invalidLayout("supervised process paths or grace period are invalid")
        }
        let selfMember = try ClusterMembershipMember(
            nodeID: nodeID,
            role: .voter,
            peerEndpoint: peerEndpoint,
            clientEndpoint: clientEndpoint
        )
        let clusterMembers = initialCluster + [selfMember]
        var nodeIDs = Set<ClusterNodeID>()
        var endpoints = Set<String>()
        for member in clusterMembers {
            try member.validate()
            guard nodeIDs.insert(member.nodeID).inserted else {
                throw ManagedEtcdError.invalidLayout("duplicate initial-cluster node identity")
            }
            guard endpoints.insert(member.peerEndpoint).inserted,
                  endpoints.insert(member.clientEndpoint).inserted else {
                throw ManagedEtcdError.invalidLayout("duplicate initial-cluster endpoint")
            }
        }
        let sortedClusterMembers = clusterMembers.sorted { $0.nodeID < $1.nodeID }
        let initialClusterValue = sortedClusterMembers
            .map { $0.nodeID.rawValue + "=" + $0.peerEndpoint }
            .joined(separator: ",")
        self.executablePath = layout.executablePath
        self.workingDirectory = layout.runtimeDirectory
        self.environment = SecureSubprocessEnvironment.minimal
        self.terminationGraceMilliseconds = terminationGraceMilliseconds
        self.arguments = [
            "--name", nodeID.rawValue,
            "--data-dir", layout.dataDirectory,
            "--listen-peer-urls", peerEndpoint,
            "--initial-advertise-peer-urls", peerEndpoint,
            "--listen-client-urls", clientEndpoint,
            "--advertise-client-urls", clientEndpoint,
            "--initial-cluster", initialClusterValue,
            "--initial-cluster-state", initialClusterState.rawValue
        ]
    }

    public func validate() throws {
        guard ManagedEtcdPath.isSafeAbsolutePath(executablePath),
              ManagedEtcdPath.isSafeAbsolutePath(workingDirectory),
              (10...5_000).contains(terminationGraceMilliseconds),
              environment == SecureSubprocessEnvironment.minimal,
              arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw ManagedEtcdError.invalidLayout("supervised process configuration is invalid")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case executablePath
        case workingDirectory
        case arguments
        case environment
        case terminationGraceMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.executablePath = try container.decode(String.self, forKey: .executablePath)
        self.workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        self.arguments = try container.decode([String].self, forKey: .arguments)
        self.environment = try container.decode([String: String].self, forKey: .environment)
        self.terminationGraceMilliseconds = try container.decode(Int.self, forKey: .terminationGraceMilliseconds)
        try validate()
    }

    public func secureSubprocessRequest() -> SecureSubprocessRequest {
        SecureSubprocessRequest(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeoutMilliseconds: 86_400_000,
            terminationGraceMilliseconds: terminationGraceMilliseconds,
            maximumStandardOutputBytes: 16 * 1_024 * 1_024,
            maximumStandardErrorBytes: 16 * 1_024 * 1_024
        )
    }
}

public struct ManagedEtcdSnapshotPlan: Codable, Equatable, Sendable {
    public let snapshotID: String
    public let sourceDataDirectory: String
    public let destinationDirectory: String
    public let operations: [String]

    init(snapshotID: String, sourceDataDirectory: String, destinationDirectory: String) {
        self.snapshotID = snapshotID
        self.sourceDataDirectory = sourceDataDirectory
        self.destinationDirectory = destinationDirectory
        self.operations = ["stop-supervised-process", "copy-data", "fsync", "record-provenance"]
    }
}

public struct ManagedEtcdRestorePlan: Codable, Equatable, Sendable {
    public let snapshotDirectory: String
    public let targetDataDirectory: String
    public let backupDirectory: String
    public let requiresQuorumStopped: Bool
    public let operations: [String]

    init(snapshotDirectory: String, targetDataDirectory: String, backupDirectory: String) {
        self.snapshotDirectory = snapshotDirectory
        self.targetDataDirectory = targetDataDirectory
        self.backupDirectory = backupDirectory
        self.requiresQuorumStopped = true
        self.operations = ["stop-supervised-process", "verify-snapshot", "backup-target", "restore-data", "fsync"]
    }
}

public struct ManagedEtcdSnapshotPlanner: Sendable {
    public init() {}

    public func makeSnapshotPlan(
        layout: ManagedEtcdLayout,
        snapshotID: String,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> ManagedEtcdSnapshotPlan {
        try layout.validate()
        guard !cancellation.isCancelled else { throw ManagedEtcdError.cancelled }
        guard ManagedEtcdPath.isSafeOpaqueID(snapshotID) else {
            throw ManagedEtcdError.invalidSnapshotID(snapshotID)
        }
        let destination = layout.snapshotsDirectory + "/" + snapshotID
        guard ManagedEtcdPath.isWithin(destination, root: layout.snapshotsDirectory) else {
            throw ManagedEtcdError.pathOutsideOwnedBoundary(destination)
        }
        return ManagedEtcdSnapshotPlan(
            snapshotID: snapshotID,
            sourceDataDirectory: layout.dataDirectory,
            destinationDirectory: destination
        )
    }

    public func makeRestorePlan(
        layout: ManagedEtcdLayout,
        snapshotDirectory: String,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> ManagedEtcdRestorePlan {
        try layout.validate()
        guard !cancellation.isCancelled else { throw ManagedEtcdError.cancelled }
        guard snapshotDirectory != layout.snapshotsDirectory,
              ManagedEtcdPath.isWithin(snapshotDirectory, root: layout.snapshotsDirectory) else {
            throw ManagedEtcdError.pathOutsideOwnedBoundary(snapshotDirectory)
        }
        let backup = layout.runtimeDirectory + "/restore-backup"
        return ManagedEtcdRestorePlan(
            snapshotDirectory: snapshotDirectory,
            targetDataDirectory: layout.dataDirectory,
            backupDirectory: backup
        )
    }
}

public struct ManagedEtcdCleanupPlan: Sendable {
    public let ownedPaths: [String]

    public init(layout: ManagedEtcdLayout) throws {
        try layout.validate()
        self.ownedPaths = layout.ownedCleanupPaths
    }

    public func owns(_ path: String) -> Bool {
        ownedPaths.contains(path)
    }

    public func validateCandidate(_ path: String) throws {
        guard owns(path) else {
            throw ManagedEtcdError.pathOutsideOwnedBoundary(path)
        }
    }

    public func execute(fileManager: FileManager = .default) throws -> ManagedEtcdCleanupReport {
        var removed: [String] = []
        var absent: [String] = []
        for path in ownedPaths {
            try validateCandidate(path)
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else {
                if errno == ENOENT || errno == ENOTDIR {
                    absent.append(path)
                    continue
                }
                throw ManagedEtcdError.cleanupRefused(path)
            }
            guard (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == getuid(),
                  metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
                throw ManagedEtcdError.cleanupRefused(path)
            }
            do {
                try fileManager.removeItem(atPath: path)
            } catch {
                throw ManagedEtcdError.cleanupRefused(path)
            }
            removed.append(path)
        }
        return ManagedEtcdCleanupReport(removedPaths: removed, absentPaths: absent)
    }
}

public struct ManagedEtcdCleanupReport: Codable, Equatable, Sendable {
    public let removedPaths: [String]
    public let absentPaths: [String]

    public init(removedPaths: [String], absentPaths: [String]) {
        self.removedPaths = removedPaths
        self.absentPaths = absentPaths
    }
}

private enum ManagedEtcdArchiveInspector {
    static func inspect(
        archiveURL: URL,
        artifact: ManagedEtcdArtifact,
        cancellation: SecureSubprocessCancellation
    ) throws -> [ManagedEtcdArchiveEntry] {
        guard !cancellation.isCancelled else { throw ManagedEtcdError.cancelled }
        switch artifact.archiveKind {
        case .zip:
            let data = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
            guard !cancellation.isCancelled else { throw ManagedEtcdError.cancelled }
            return try inspectZip(data)
        case .tarGz:
            return try inspectTarGz(archiveURL: archiveURL, cancellation: cancellation)
        }
    }

    private static func inspectZip(_ data: Data) throws -> [ManagedEtcdArchiveEntry] {
        guard data.count >= 22 else { throw ManagedEtcdError.archiveUnreadable("ZIP is truncated") }
        let lowerBound = max(0, data.count - 65_557)
        var endOffset: Int?
        if data.count >= 4 {
            for offset in stride(from: data.count - 4, through: lowerBound, by: -1) {
                if readUInt32(data, offset) == 0x06054b50 {
                    endOffset = offset
                    break
                }
            }
        }
        guard let endOffset else { throw ManagedEtcdError.archiveUnreadable("ZIP end record is missing") }
        let diskNumber = readUInt16(data, endOffset + 4)
        let centralDisk = readUInt16(data, endOffset + 6)
        let entryCount = Int(readUInt16(data, endOffset + 10))
        let centralSize = Int(readUInt32(data, endOffset + 12))
        let centralOffset = Int(readUInt32(data, endOffset + 16))
        guard diskNumber == 0,
              centralDisk == 0,
              entryCount != 0xffff,
              centralSize != Int(UInt32.max),
              centralOffset != Int(UInt32.max),
              centralOffset >= 0,
              centralSize >= 0,
              centralOffset + centralSize <= data.count else {
            throw ManagedEtcdError.archiveUnreadable("ZIP64 or invalid central directory is unsupported")
        }

        var cursor = centralOffset
        var entries: [ManagedEtcdArchiveEntry] = []
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count,
                  readUInt32(data, cursor) == 0x02014b50 else {
                throw ManagedEtcdError.archiveUnreadable("ZIP central entry is truncated")
            }
            let madeBy = readUInt16(data, cursor + 4)
            let flags = readUInt16(data, cursor + 8)
            let nameLength = Int(readUInt16(data, cursor + 28))
            let extraLength = Int(readUInt16(data, cursor + 30))
            let commentLength = Int(readUInt16(data, cursor + 32))
            let attributes = readUInt32(data, cursor + 38)
            let end = cursor + 46 + nameLength + extraLength + commentLength
            guard end <= data.count,
                  flags & 0x0001 == 0 else {
                throw ManagedEtcdError.archiveUnreadable("encrypted or truncated ZIP entry")
            }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ManagedEtcdError.unsafeArchivePath("ZIP entry is not UTF-8")
            }
            let isDirectory = name.hasSuffix("/")
            let unixMode = (madeBy >> 8) == 3 ? UInt16((attributes >> 16) & 0xffff) : nil
            let type: ManagedEtcdArchiveEntryType
            if isDirectory {
                type = .directory
            } else if let unixMode {
                switch unixMode & 0o170000 {
                case 0o120000:
                    type = .symbolicLink
                case 0o040000:
                    type = .directory
                case 0, 0o100000:
                    type = .regular
                default:
                    type = .special
                }
            } else {
                type = .regular
            }
            entries.append(ManagedEtcdArchiveEntry(path: name, type: type, mode: unixMode))
            cursor = end
        }
        return entries
    }

    private static func inspectTarGz(
        archiveURL: URL,
        cancellation: SecureSubprocessCancellation
    ) throws -> [ManagedEtcdArchiveEntry] {
        let request = SecureSubprocessRequest(
            executablePath: "/usr/bin/tar",
            arguments: ["-tvzf", archiveURL.path],
            environment: SecureSubprocessEnvironment.minimal,
            workingDirectory: "/",
            timeoutMilliseconds: 30_000,
            terminationGraceMilliseconds: 500,
            maximumStandardOutputBytes: 16 * 1_024 * 1_024,
            maximumStandardErrorBytes: 1 * 1_024 * 1_024
        )
        let result: SecureSubprocessResult
        do {
            result = try SecureSubprocessRunner().run(request, cancellation: cancellation)
        } catch let error as SecureSubprocessError {
            if case .cancelled = error { throw ManagedEtcdError.cancelled }
            throw ManagedEtcdError.archiveUnreadable("tar listing failed")
        }
        guard result.exitStatus == 0,
              let output = String(data: result.standardOutput, encoding: .utf8) else {
            throw ManagedEtcdError.archiveUnreadable("tar listing failed")
        }
        return try output.split(whereSeparator: \.isNewline).map { line in
            let first = line.first ?? "?"
            let type: ManagedEtcdArchiveEntryType
            switch first {
            case "d": type = .directory
            case "-": type = .regular
            case "l": type = .symbolicLink
            case "h": type = .hardLink
            default: type = .special
            }
            let pieces = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard let rawPath = pieces.last else {
                throw ManagedEtcdError.archiveUnreadable("tar entry has no path")
            }
            let path = String(rawPath).split(separator: " -> ", maxSplits: 1).first.map(String.init) ?? String(rawPath)
            return ManagedEtcdArchiveEntry(path: path, type: type)
        }
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) |
            (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }
}

private enum ManagedEtcdPath {
    static func isSafeAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              !path.contains("\0"),
              !path.contains("//"),
              !path.hasSuffix("/"),
              path.utf8.count <= Int(PATH_MAX) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return !components.isEmpty && components.allSatisfy { $0 != "." && $0 != ".." }
    }

    static func isWithin(_ path: String, root: String) -> Bool {
        guard isSafeAbsolutePath(path), isSafeAbsolutePath(root) else { return false }
        return path == root || path.hasPrefix(root + "/")
    }

    static func validateExistingParentChain(_ path: String) throws {
        let components = path.split(separator: "/").map(String.init)
        var current = ""
        for component in components.dropLast() {
            current += "/" + component
            var metadata = stat()
            guard stat(current, &metadata) == 0 else {
                throw ManagedEtcdError.invalidLayout(current)
            }
            let type = metadata.st_mode & S_IFMT
            guard type == S_IFDIR else {
                throw ManagedEtcdError.invalidLayout(current)
            }
            let trustedOwnerPrivate = (metadata.st_uid == getuid() || metadata.st_uid == 0) &&
                metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
            let rootStickyDirectory = metadata.st_uid == 0 &&
                metadata.st_mode & S_ISVTX != 0
            guard trustedOwnerPrivate || rootStickyDirectory else {
                throw ManagedEtcdError.unsafePermissions(current)
            }
        }
    }

    static func isSafeOpaqueID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 45 || scalar.value == 46 || scalar.value == 95 ||
                (scalar.value >= 48 && scalar.value <= 57) ||
                (scalar.value >= 65 && scalar.value <= 90) ||
                (scalar.value >= 97 && scalar.value <= 122)
        }
    }
}

private enum ManagedEtcdFileSystem {
    struct FileMetadata {
        let size: UInt64
    }

    static func regularFileMetadata(_ url: URL) throws -> FileMetadata {
        guard url.isFileURL, ManagedEtcdPath.isSafeAbsolutePath(url.path) else {
            throw ManagedEtcdError.archiveNotFound
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == getuid(),
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw ManagedEtcdError.archiveNotFound
        }
        return FileMetadata(size: UInt64(metadata.st_size))
    }

    static func sha256(
        fileURL: URL,
        cancellation: SecureSubprocessCancellation
    ) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw ManagedEtcdError.archiveNotFound
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard !cancellation.isCancelled else { throw ManagedEtcdError.cancelled }
            let data: Data
            do {
                data = try handle.read(upToCount: 1 * 1_024 * 1_024) ?? Data()
            } catch {
                throw ManagedEtcdError.archiveUnreadable("archive read failed")
            }
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func ensurePrivateDirectory(_ path: String, fileManager: FileManager) throws {
        guard ManagedEtcdPath.isSafeAbsolutePath(path) else {
            throw ManagedEtcdError.invalidLayout(path)
        }
        var metadata = stat()
        if lstat(path, &metadata) == 0 {
            guard (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == getuid(),
                  metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
                throw ManagedEtcdError.unsafePermissions(path)
            }
            guard chmod(path, 0o700) == 0 else {
                throw ManagedEtcdError.unsafePermissions(path)
            }
            return
        }
        guard errno == ENOENT || errno == ENOTDIR else {
            throw ManagedEtcdError.invalidLayout(path)
        }
        do {
            try fileManager.createDirectory(
                atPath: path,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ManagedEtcdError.invalidLayout(path)
        }
        guard chmod(path, 0o700) == 0 else {
            throw ManagedEtcdError.unsafePermissions(path)
        }
    }
}
