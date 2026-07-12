import Foundation
import HostwrightCore

public enum DistributionLayout {
    public static let manifestFileName = "manifest.json"
    public static let sbomFileName = "sbom.spdx.json"
    public static let provenanceFileName = "provenance.intoto.json"
    public static let checksumFileName = "SHA256SUMS"
    public static let evidenceFileName = "distribution-evidence.json"
    public static let installManifestFileName = ".hostwright-install-manifest.json"

    public static let payloadModes: [String: Int] = [
        "bin/hostwright": 0o755,
        "bin/hostwrightd": 0o755,
        "share/doc/hostwright/LICENSE": 0o644,
        "share/doc/hostwright/README.md": 0o644
    ]
}

public enum DistributionError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidArguments(String)
    case unsafePath(String)
    case existingOutput(String)
    case invalidManifest(String)
    case invalidArtifact(String)
    case checksumMismatch(String)
    case commandFailed(String, Int32)
    case commandTimedOut(String)
    case dirtySource
    case sourceCommitMismatch(expected: String, actual: String)
    case installOwnershipMismatch(String)
    case lifecycleFailed(String)

    public var description: String {
        switch self {
        case .invalidArguments(let message): return message
        case .unsafePath(let message): return message
        case .existingOutput(let path): return "Refused to overwrite existing distribution output at \(path)."
        case .invalidManifest(let message): return "Invalid distribution manifest: \(message)"
        case .invalidArtifact(let message): return "Invalid distribution artifact: \(message)"
        case .checksumMismatch(let name): return "SHA-256 verification failed for \(name)."
        case .commandFailed(let command, let status): return "Distribution command failed with exit \(status): \(command)."
        case .commandTimedOut(let command): return "Distribution command timed out: \(command)."
        case .dirtySource: return "Clean-source distribution build refused a dirty working tree."
        case .sourceCommitMismatch(let expected, let actual):
            return "Source commit mismatch: expected \(expected), observed \(actual)."
        case .installOwnershipMismatch(let path):
            return "Installed file no longer matches its ownership manifest: \(path)."
        case .lifecycleFailed(let message): return "Distribution lifecycle failed: \(message)"
        }
    }
}

public struct DistributionFileRecord: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let sizeBytes: Int
    public let mode: Int

    public init(path: String, sha256: String, sizeBytes: Int, mode: Int) {
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.mode = mode
    }
}

public struct DistributionArtifactManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let artifactID: String
    public let packageVersion: String
    public let sourceCommit: String
    public let sourceDirty: Bool
    public let platform: String
    public let architecture: String
    public let createdAt: String
    public let files: [DistributionFileRecord]

    public init(
        schemaVersion: Int = 1,
        artifactID: String,
        packageVersion: String,
        sourceCommit: String,
        sourceDirty: Bool,
        platform: String = "macos",
        architecture: String,
        createdAt: String,
        files: [DistributionFileRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.artifactID = artifactID
        self.packageVersion = packageVersion
        self.sourceCommit = sourceCommit
        self.sourceDirty = sourceDirty
        self.platform = platform
        self.architecture = architecture
        self.createdAt = createdAt
        self.files = files
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw DistributionError.invalidManifest("unsupported schema version \(schemaVersion)")
        }
        guard sourceCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              sourceCommit != String(repeating: "0", count: 40) else {
            throw DistributionError.invalidManifest("source commit must be nonzero lowercase 40-hex")
        }
        guard packageVersion.range(
            of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$",
            options: .regularExpression
        ) != nil else {
            throw DistributionError.invalidManifest("package version must be exact semantic version text")
        }
        let escapedVersion = NSRegularExpression.escapedPattern(for: packageVersion)
        let expectedArtifactPattern = "^hostwright-\(escapedVersion)-macos-arm64-[a-f0-9]{12}$"
        guard artifactID.range(of: expectedArtifactPattern, options: .regularExpression) != nil,
              platform == "macos",
              architecture == "arm64",
              ISO8601DateFormatter().date(from: createdAt) != nil else {
            throw DistributionError.invalidManifest("artifact identity, platform, architecture, or timestamp is invalid")
        }
        guard files.map(\.path) == files.map(\.path).sorted(),
              Set(files.map(\.path)).count == files.count,
              Set(files.map(\.path)) == Set(DistributionLayout.payloadModes.keys) else {
            throw DistributionError.invalidManifest("payload file set must exactly match the supported archive layout")
        }
        for file in files {
            guard DistributionPathPolicy.isSafeRelativePath(file.path),
                  file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  file.sizeBytes > 0,
                  DistributionLayout.payloadModes[file.path] == file.mode else {
                throw DistributionError.invalidManifest("payload metadata is invalid for \(file.path)")
            }
        }
    }
}

public struct DistributionArtifactDescriptor: Codable, Equatable, Sendable {
    public let fileName: String
    public let sha256: String
    public let sizeBytes: Int

    public init(fileName: String, sha256: String, sizeBytes: Int) {
        self.fileName = fileName
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }

    public func validate(suffix: String? = nil) throws {
        guard DistributionPathPolicy.isSafeFileName(fileName),
              suffix.map(fileName.hasSuffix) ?? true,
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              sizeBytes > 0 else {
            throw DistributionError.invalidArtifact("invalid sidecar descriptor \(fileName)")
        }
    }
}

public struct DistributionStageRecord: Codable, Equatable, Sendable {
    public let identifier: String
    public let status: HostwrightEvidenceStatus
    public let detail: String

    public init(identifier: String, status: HostwrightEvidenceStatus, detail: String) {
        self.identifier = identifier
        self.status = status
        self.detail = detail
    }
}

public struct DistributionBuildReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let manifest: DistributionArtifactManifest
    public let archive: DistributionArtifactDescriptor
    public let sbom: DistributionArtifactDescriptor
    public let provenance: DistributionArtifactDescriptor
    public let stages: [DistributionStageRecord]
    public let evidence: HostwrightEvidenceReport

    public init(
        schemaVersion: Int = 1,
        manifest: DistributionArtifactManifest,
        archive: DistributionArtifactDescriptor,
        sbom: DistributionArtifactDescriptor,
        provenance: DistributionArtifactDescriptor,
        stages: [DistributionStageRecord],
        evidence: HostwrightEvidenceReport
    ) {
        self.schemaVersion = schemaVersion
        self.manifest = manifest
        self.archive = archive
        self.sbom = sbom
        self.provenance = provenance
        self.stages = stages
        self.evidence = evidence
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw DistributionError.invalidArtifact("unsupported build-report schema version")
        }
        try manifest.validate()
        try archive.validate(suffix: ".tar.gz")
        try sbom.validate(suffix: ".spdx.json")
        try provenance.validate(suffix: ".intoto.json")
        let inputStage = stages.first { $0.identifier == "release-build" || $0.identifier == "prebuilt-validation" }
        guard archive.fileName == "\(manifest.artifactID).tar.gz",
              sbom.fileName == DistributionLayout.sbomFileName,
              provenance.fileName == DistributionLayout.provenanceFileName,
              Set(stages.map(\.identifier)).count == stages.count,
              stages.allSatisfy({ !$0.identifier.isEmpty && !$0.detail.isEmpty }),
              stages.allSatisfy({ $0.status != .failed }),
              inputStage?.status == .passed,
              (inputStage?.identifier == "release-build") == !manifest.sourceDirty,
              stages.first(where: { $0.identifier == "archive" })?.status == .passed,
              stages.first(where: { $0.identifier == "checksums" })?.status == .passed,
              stages.first(where: { $0.identifier == "sbom" })?.status == .passed,
              stages.first(where: { $0.identifier == "provenance" })?.status == .passed,
              stages.first(where: { $0.identifier == "developer-id-signing" })?.status == .blocked,
              stages.first(where: { $0.identifier == "notarization-stapling-gatekeeper" })?.status == .blocked,
              stages.first(where: { $0.identifier == "installer-package" })?.status == .blocked else {
            throw DistributionError.invalidArtifact("build stages do not preserve the unsigned distribution boundary")
        }
        try evidence.validate()
        let blockedDetails = stages.filter { $0.status == .blocked }.map(\.detail)
        guard evidence.evidenceClass == .distributionArtifact,
              evidence.status == .blocked,
              evidence.source.commit == manifest.sourceCommit,
              evidence.source.dirty == manifest.sourceDirty,
              evidence.failures.isEmpty,
              evidence.blockers == blockedDetails,
              evidence.rawResults.passed == stages.filter({ $0.status == .passed }).count,
              evidence.rawResults.failed == 0,
              evidence.rawResults.blocked == stages.filter({ $0.status == .blocked }).count,
              evidence.cleanup.status == .notRequired else {
            throw DistributionError.invalidArtifact("build evidence is not bound to the artifact manifest")
        }
    }
}

public struct SPDXChecksum: Codable, Equatable, Sendable {
    public let algorithm: String
    public let checksumValue: String
}

public struct SPDXCreationInfo: Codable, Equatable, Sendable {
    public let created: String
    public let creators: [String]
}

public struct SPDXPackageRecord: Codable, Equatable, Sendable {
    public let name: String
    public let SPDXID: String
    public let versionInfo: String
    public let downloadLocation: String
    public let filesAnalyzed: Bool
    public let checksums: [SPDXChecksum]
    public let licenseConcluded: String
    public let licenseDeclared: String
    public let copyrightText: String
}

public struct SPDXFileRecord: Codable, Equatable, Sendable {
    public let fileName: String
    public let SPDXID: String
    public let checksums: [SPDXChecksum]
    public let fileTypes: [String]
    public let licenseConcluded: String
    public let copyrightText: String
}

public struct SPDXRelationship: Codable, Equatable, Sendable {
    public let spdxElementId: String
    public let relationshipType: String
    public let relatedSpdxElement: String
}

public struct DistributionSPDXDocument: Codable, Equatable, Sendable {
    public let spdxVersion: String
    public let dataLicense: String
    public let SPDXID: String
    public let name: String
    public let documentNamespace: String
    public let creationInfo: SPDXCreationInfo
    public let packages: [SPDXPackageRecord]
    public let files: [SPDXFileRecord]
    public let relationships: [SPDXRelationship]

    public func validate(manifest: DistributionArtifactManifest, archive: DistributionArtifactDescriptor) throws {
        guard spdxVersion == "SPDX-2.3",
              dataLicense == "CC0-1.0",
              SPDXID == "SPDXRef-DOCUMENT",
              packages.count == 1,
              let package = packages.first,
              package.name == "Hostwright",
              package.versionInfo == manifest.packageVersion,
              package.filesAnalyzed,
              package.checksums == [SPDXChecksum(algorithm: "SHA256", checksumValue: archive.sha256)],
              documentNamespace.contains(manifest.sourceCommit),
              documentNamespace.contains(archive.sha256) else {
            throw DistributionError.invalidArtifact("SPDX package binding is invalid")
        }
        let expectedFiles = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.sha256) })
        let actualFiles = Dictionary(uniqueKeysWithValues: files.map {
            ($0.fileName.replacingOccurrences(of: "./", with: ""), $0.checksums.first?.checksumValue ?? "")
        })
        let packageID = package.SPDXID
        let expectedRelationships = Set(
            [
                "SPDXRef-DOCUMENT|DESCRIBES|\(packageID)"
            ] + files.map {
                "\(packageID)|CONTAINS|\($0.SPDXID)"
            }
        )
        let actualRelationships = Set(relationships.map {
            "\($0.spdxElementId)|\($0.relationshipType)|\($0.relatedSpdxElement)"
        })
        guard expectedFiles == actualFiles,
              files.allSatisfy({ $0.checksums.count == 1 && $0.checksums[0].algorithm == "SHA256" }),
              actualRelationships == expectedRelationships else {
            throw DistributionError.invalidArtifact("SPDX file inventory is not bound to the manifest")
        }
    }
}

public struct ProvenanceSubject: Codable, Equatable, Sendable {
    public let name: String
    public let digest: [String: String]
}

public struct ProvenanceExternalParameters: Codable, Equatable, Sendable {
    public let configuration: String
    public let products: [String]
    public let platform: String
    public let architecture: String
}

public struct ProvenanceInternalParameters: Codable, Equatable, Sendable {
    public let sourceDirty: Bool
    public let unsigned: Bool
}

public struct ProvenanceResolvedDependency: Codable, Equatable, Sendable {
    public let uri: String
    public let digest: [String: String]
}

public struct ProvenanceBuildDefinition: Codable, Equatable, Sendable {
    public let buildType: String
    public let externalParameters: ProvenanceExternalParameters
    public let internalParameters: ProvenanceInternalParameters
    public let resolvedDependencies: [ProvenanceResolvedDependency]
}

public struct ProvenanceBuilder: Codable, Equatable, Sendable {
    public let id: String
}

public struct ProvenanceMetadata: Codable, Equatable, Sendable {
    public let invocationId: String
    public let startedOn: String
    public let finishedOn: String
}

public struct ProvenanceRunDetails: Codable, Equatable, Sendable {
    public let builder: ProvenanceBuilder
    public let metadata: ProvenanceMetadata
}

public struct DistributionProvenancePredicate: Codable, Equatable, Sendable {
    public let buildDefinition: ProvenanceBuildDefinition
    public let runDetails: ProvenanceRunDetails
}

public struct DistributionProvenanceStatement: Codable, Equatable, Sendable {
    public let statementType: String
    public let subject: [ProvenanceSubject]
    public let predicateType: String
    public let predicate: DistributionProvenancePredicate

    enum CodingKeys: String, CodingKey {
        case statementType = "_type"
        case subject
        case predicateType
        case predicate
    }

    public func validate(manifest: DistributionArtifactManifest, archive: DistributionArtifactDescriptor) throws {
        let started = ISO8601DateFormatter().date(from: predicate.runDetails.metadata.startedOn)
        let finished = ISO8601DateFormatter().date(from: predicate.runDetails.metadata.finishedOn)
        guard statementType == "https://in-toto.io/Statement/v1",
              predicateType == "https://slsa.dev/provenance/v1",
              subject == [ProvenanceSubject(name: archive.fileName, digest: ["sha256": archive.sha256])],
              predicate.buildDefinition.buildType == "urn:hostwright:buildtype:swiftpm-archive:v1",
              predicate.buildDefinition.externalParameters.configuration == "release",
              predicate.buildDefinition.externalParameters.products == ["hostwright", "hostwrightd"],
              predicate.buildDefinition.externalParameters.platform == manifest.platform,
              predicate.buildDefinition.externalParameters.architecture == manifest.architecture,
              predicate.buildDefinition.internalParameters.sourceDirty == manifest.sourceDirty,
              predicate.buildDefinition.internalParameters.unsigned,
              predicate.buildDefinition.resolvedDependencies.contains(where: {
                  $0.uri == "git+https://github.com/hostwright/hostwright.git" &&
                    $0.digest["gitCommit"] == manifest.sourceCommit
              }),
              predicate.runDetails.builder.id == "urn:hostwright:builder:local-swiftpm:v1",
              UUID(uuidString: predicate.runDetails.metadata.invocationId) != nil,
              let started,
              let finished,
              finished >= started else {
            throw DistributionError.invalidArtifact("provenance statement is not bound to the archive and source")
        }
    }
}

public struct DistributionInstallManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let artifactID: String
    public let sourceCommit: String
    public let packageVersion: String
    public let files: [DistributionFileRecord]
    public let createdDirectories: [String]

    public init(artifact: DistributionArtifactManifest, createdDirectories: [String]) {
        self.schemaVersion = 1
        self.artifactID = artifact.artifactID
        self.sourceCommit = artifact.sourceCommit
        self.packageVersion = artifact.packageVersion
        self.files = artifact.files
        self.createdDirectories = createdDirectories
    }

    public func validate() throws {
        let allowedDirectories = Set(DistributionLayout.payloadModes.keys.flatMap { path -> [String] in
            let components = path.split(separator: "/").map(String.init)
            var result: [String] = []
            var current = ""
            for component in components.dropLast() {
                current = current.isEmpty ? component : "\(current)/\(component)"
                result.append(current)
            }
            return result
        })
        guard schemaVersion == 1,
              packageVersion.range(
                of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$",
                options: .regularExpression
              ) != nil,
              artifactID == "hostwright-\(packageVersion)-macos-arm64-\(sourceCommit.prefix(12))",
              sourceCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              Set(files.map(\.path)) == Set(DistributionLayout.payloadModes.keys),
              Set(files.map(\.path)).count == files.count,
              createdDirectories == createdDirectories.sorted(),
              Set(createdDirectories).count == createdDirectories.count,
              createdDirectories.allSatisfy(DistributionPathPolicy.isSafeRelativePath),
              Set(createdDirectories).isSubset(of: allowedDirectories) else {
            throw DistributionError.invalidManifest("install ownership manifest is invalid")
        }
        for file in files {
            guard DistributionPathPolicy.isSafeRelativePath(file.path),
                  file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  file.sizeBytes > 0,
                  DistributionLayout.payloadModes[file.path] == file.mode else {
                throw DistributionError.invalidManifest("install file metadata is invalid")
            }
        }
    }
}

public struct DistributionLifecycleReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let baselineCommit: String
    public let candidateCommit: String
    public let prefix: String
    public let stages: [DistributionStageRecord]
    public let preservedPaths: [String]
    public let evidence: HostwrightEvidenceReport

    public init(
        schemaVersion: Int = 1,
        baselineCommit: String,
        candidateCommit: String,
        prefix: String,
        stages: [DistributionStageRecord],
        preservedPaths: [String],
        evidence: HostwrightEvidenceReport
    ) {
        self.schemaVersion = schemaVersion
        self.baselineCommit = baselineCommit
        self.candidateCommit = candidateCommit
        self.prefix = prefix
        self.stages = stages
        self.preservedPaths = preservedPaths
        self.evidence = evidence
    }

    public func validate() throws {
        try DistributionTemporaryPathPolicy.validate(URL(fileURLWithPath: prefix), role: "lifecycle report prefix")
        let requiredCleanupPaths = Set(
            (Array(DistributionLayout.payloadModes.keys) + [DistributionLayout.installManifestFileName])
                .map { URL(fileURLWithPath: prefix).appendingPathComponent($0).path }
        )
        let allowedCleanupPaths = requiredCleanupPaths.union(
            DistributionLayout.payloadModes.keys.flatMap { path -> [String] in
                let components = path.split(separator: "/").map(String.init)
                var directories: [String] = []
                var current = ""
                for component in components.dropLast() {
                    current = current.isEmpty ? component : "\(current)/\(component)"
                    directories.append(URL(fileURLWithPath: prefix).appendingPathComponent(current).path)
                }
                return directories
            }
        )
        let recordedCleanupPaths = Set(evidence.cleanup.exactResourceIdentifiers)
        guard schemaVersion == 1,
              baselineCommit != candidateCommit,
              baselineCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              candidateCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              Set(stages.map(\.identifier)) == Set(["install", "upgrade", "downgrade", "uninstall"]),
              stages.allSatisfy({ $0.status == .passed && !$0.detail.isEmpty }),
              preservedPaths == preservedPaths.sorted(),
              Set(preservedPaths).count == preservedPaths.count,
              preservedPaths.allSatisfy(DistributionPathPolicy.isSafeRelativePath) else {
            throw DistributionError.lifecycleFailed("stage or source binding is invalid")
        }
        try evidence.validate()
        guard evidence.evidenceClass == .distributionArtifact,
              evidence.status == .blocked,
              evidence.source.commit == candidateCommit,
              evidence.rawResults.passed == stages.count,
              evidence.rawResults.failed == 0,
              evidence.rawResults.blocked == evidence.blockers.count,
              requiredCleanupPaths.isSubset(of: recordedCleanupPaths),
              recordedCleanupPaths.isSubset(of: allowedCleanupPaths),
              evidence.cleanup.status == .succeeded else {
            throw DistributionError.lifecycleFailed("evidence does not preserve the blocked distribution boundary")
        }
    }
}

public enum DistributionPathPolicy {
    public static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public static func isSafeFileName(_ value: String) -> Bool {
        isSafeRelativePath(value) && !value.contains("/")
    }
}
