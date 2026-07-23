import Foundation
import HostwrightCore

public enum DistributionLayout {
    public static let manifestFileName = "manifest.json"
    public static let sbomFileName = "sbom.spdx.json"
    public static let provenanceFileName = "provenance.intoto.json"
    public static let checksumFileName = "SHA256SUMS"
    public static let evidenceFileName = "distribution-evidence.json"
    public static let installManifestFileName = ".hostwright-install-manifest.json"
    public static let lifecycleDirectoryName = ".hostwright-lifecycle"
    public static let lifecycleStatusFileName = "status.json"
    public static let lifecycleJournalFileName = "journal.json"
    public static let lifecycleLockFileName = "lifecycle.lock"
    public static let lifecycleTransactionsDirectoryName = "transactions"
    public static let lifecycleRollbackFileName = "rollback.json"
    public static let lifecycleBackupInventoryFileName = "backup-inventory.json"
    public static let packageIdentifier = "dev.hostwright.cli"
    public static let packageStagingPath = "/Library/Application Support/Hostwright/InstallerPayload"
    public static let packageInstallPrefix = "/usr/local"
    public static let shippedExecutableNames = [
        "hostwright",
        "hostwright-control",
        "hostwright-containerization-helper",
        "hostwright-dist",
        "hostwrightd"
    ]
    public static let shippedBinaryPaths = shippedExecutableNames.map { "bin/\($0)" }
    static let legacyPayloadModesV1: [String: Int] = [
        "bin/hostwright": 0o755,
        "bin/hostwright-control": 0o755,
        "bin/hostwrightd": 0o755,
        "share/hostwright/examples/hostwright.yaml": 0o644,
        "share/doc/hostwright/LICENSE": 0o644,
        "share/doc/hostwright/README.md": 0o644
    ]

    public static let payloadModes: [String: Int] = [
        "bin/hostwright": 0o755,
        "bin/hostwright-control": 0o755,
        "bin/hostwright-containerization-helper": 0o755,
        "bin/hostwright-dist": 0o755,
        "bin/hostwrightd": 0o755,
        "share/hostwright/examples/hostwright.yaml": 0o644,
        "share/doc/hostwright/LICENSE": 0o644,
        "share/doc/hostwright/README.md": 0o644
    ].merging(DistributionContainerizationAssets.payloadModes) { _, _ in
        preconditionFailure("duplicate distribution payload path")
    }
}

public enum DistributionInstallationSource: String, Codable, Equatable, Sendable {
    case package
}

public struct DistributionPackageOrigin: Codable, Equatable, Sendable {
    public let installationSource: DistributionInstallationSource
    public let packageIdentifier: String
    public let packageVersion: String
    public let mostRecentPackageReceiptVersion: String
    public let pendingReceiptCleanup: Bool

    public init(
        packageIdentifier: String,
        packageVersion: String,
        mostRecentPackageReceiptVersion: String,
        pendingReceiptCleanup: Bool = false
    ) {
        self.installationSource = .package
        self.packageIdentifier = packageIdentifier
        self.packageVersion = packageVersion
        self.mostRecentPackageReceiptVersion = mostRecentPackageReceiptVersion
        self.pendingReceiptCleanup = pendingReceiptCleanup
    }

    public func validate() throws {
        guard installationSource == .package,
              packageIdentifier == DistributionLayout.packageIdentifier,
              DistributionPackageVersion.isValid(packageVersion),
              DistributionPackageVersion.isValid(mostRecentPackageReceiptVersion),
              DistributionPackageVersion.compare(
                packageVersion,
                mostRecentPackageReceiptVersion
              ) != .orderedDescending else {
            throw DistributionError.lifecycleFailed("package installation origin is invalid")
        }
    }

    func replacing(
        packageVersion: String? = nil,
        mostRecentPackageReceiptVersion: String? = nil,
        pendingReceiptCleanup: Bool? = nil
    ) -> Self {
        Self(
            packageIdentifier: packageIdentifier,
            packageVersion: packageVersion ?? self.packageVersion,
            mostRecentPackageReceiptVersion: mostRecentPackageReceiptVersion
                ?? self.mostRecentPackageReceiptVersion,
            pendingReceiptCleanup: pendingReceiptCleanup ?? self.pendingReceiptCleanup
        )
    }
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
    case commandCancelled(String)
    case commandOutputLimitExceeded(String)
    case commandProcessTreeViolation(String)
    case dirtySource
    case sourceCommitMismatch(expected: String, actual: String)
    case installOwnershipMismatch(String)
    case downgradeRefused(installed: String, candidate: String)
    case versionConflict(String)
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
        case .commandCancelled(let command): return "Distribution command was cancelled: \(command)."
        case .commandOutputLimitExceeded(let command): return "Distribution command exceeded its output limit: \(command)."
        case .commandProcessTreeViolation(let command): return "Distribution command left an unexpected process tree: \(command)."
        case .dirtySource: return "Clean-source distribution build refused a dirty working tree."
        case .sourceCommitMismatch(let expected, let actual):
            return "Source commit mismatch: expected \(expected), observed \(actual)."
        case .installOwnershipMismatch(let path):
            return "Installed file no longer matches its ownership manifest: \(path)."
        case .downgradeRefused(let installed, let candidate):
            return "Downgrade refused: installed version \(installed) is newer than candidate \(candidate). Use a verified Hostwright rollback record instead."
        case .versionConflict(let message): return message
        case .lifecycleFailed(let message): return "Distribution lifecycle failed: \(message)"
        }
    }
}

public struct DistributionSemanticVersion: Equatable, Comparable, Sendable {
    private enum PrereleaseIdentifier: Equatable, Sendable {
        case numeric(String)
        case alphanumeric(String)
    }

    public let rawValue: String
    private let major: String
    private let minor: String
    private let patch: String
    private let prerelease: [PrereleaseIdentifier]

    public init(parsing rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 128,
              !rawValue.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw DistributionError.invalidManifest("package version must be strict semantic version text")
        }

        let buildSplit = rawValue.split(separator: "+", omittingEmptySubsequences: false)
        guard buildSplit.count <= 2,
              !buildSplit[0].isEmpty,
              buildSplit.dropFirst().allSatisfy({ Self.validIdentifiers(String($0), rejectNumericLeadingZero: false) }) else {
            throw DistributionError.invalidManifest("package version must be strict semantic version text")
        }
        let precedence = String(buildSplit[0])
        let prereleaseSplit = precedence.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard !prereleaseSplit[0].isEmpty,
              prereleaseSplit.count == 1 || Self.validIdentifiers(
                String(prereleaseSplit[1]),
                rejectNumericLeadingZero: true
              ) else {
            throw DistributionError.invalidManifest("package version must be strict semantic version text")
        }
        let core = prereleaseSplit[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              core.allSatisfy({ Self.validCoreNumber(String($0)) }) else {
            throw DistributionError.invalidManifest("package version must be strict semantic version text")
        }

        self.rawValue = rawValue
        self.major = String(core[0])
        self.minor = String(core[1])
        self.patch = String(core[2])
        if prereleaseSplit.count == 2 {
            self.prerelease = prereleaseSplit[1].split(separator: ".").map { identifier in
                let value = String(identifier)
                return value.allSatisfy(\.isNumber) ? .numeric(value) : .alphanumeric(value)
            }
        } else {
            self.prerelease = []
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        compareCore(lhs.major, rhs.major) == 0
            && compareCore(lhs.minor, rhs.minor) == 0
            && compareCore(lhs.patch, rhs.patch) == 0
            && comparePrerelease(lhs.prerelease, rhs.prerelease) == 0
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for pair in [(lhs.major, rhs.major), (lhs.minor, rhs.minor), (lhs.patch, rhs.patch)] {
            let comparison = compareCore(pair.0, pair.1)
            if comparison != 0 { return comparison < 0 }
        }
        return comparePrerelease(lhs.prerelease, rhs.prerelease) < 0
    }

    private static func validCoreNumber(_ value: String) -> Bool {
        !value.isEmpty
            && value.allSatisfy(\.isNumber)
            && (value == "0" || !value.hasPrefix("0"))
    }

    private static func validIdentifiers(_ value: String, rejectNumericLeadingZero: Bool) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !identifiers.isEmpty else { return false }
        return identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (65...90).contains(byte) ||
                        (97...122).contains(byte) || byte == 45
                  }) else { return false }
            let text = String(identifier)
            return !rejectNumericLeadingZero || !text.allSatisfy(\.isNumber) ||
                text == "0" || !text.hasPrefix("0")
        }
    }

    private static func compareCore(_ lhs: String, _ rhs: String) -> Int {
        if lhs.count != rhs.count { return lhs.count < rhs.count ? -1 : 1 }
        if lhs == rhs { return 0 }
        return lhs.lexicographicallyPrecedes(rhs) ? -1 : 1
    }

    private static func comparePrerelease(
        _ lhs: [PrereleaseIdentifier],
        _ rhs: [PrereleaseIdentifier]
    ) -> Int {
        if lhs.isEmpty || rhs.isEmpty {
            if lhs.isEmpty, rhs.isEmpty { return 0 }
            return lhs.isEmpty ? 1 : -1
        }
        for (left, right) in zip(lhs, rhs) {
            let comparison: Int
            switch (left, right) {
            case (.numeric(let l), .numeric(let r)):
                comparison = compareCore(l, r)
            case (.numeric, .alphanumeric):
                comparison = -1
            case (.alphanumeric, .numeric):
                comparison = 1
            case (.alphanumeric(let l), .alphanumeric(let r)):
                comparison = l == r ? 0 : (l.lexicographicallyPrecedes(r) ? -1 : 1)
            }
            if comparison != 0 { return comparison }
        }
        if lhs.count == rhs.count { return 0 }
        return lhs.count < rhs.count ? -1 : 1
    }
}

public enum DistributionVersionTransition: String, Codable, Equatable, Sendable {
    case upgrade
    case repair

    public static func classify(
        installedVersion: String,
        installedCommit: String,
        candidateVersion: String,
        candidateCommit: String
    ) throws -> DistributionVersionTransition {
        guard installedCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              candidateCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else {
            throw DistributionError.versionConflict("Installed or candidate source identity is invalid.")
        }
        let installed = try DistributionSemanticVersion(parsing: installedVersion)
        let candidate = try DistributionSemanticVersion(parsing: candidateVersion)
        if candidate < installed {
            throw DistributionError.downgradeRefused(
                installed: installedVersion,
                candidate: candidateVersion
            )
        }
        if installed < candidate { return .upgrade }
        guard installedVersion == candidateVersion,
              installedCommit == candidateCommit else {
            throw DistributionError.versionConflict(
                "Version \(candidateVersion) is already installed from a different source commit."
            )
        }
        return .repair
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
        _ = try DistributionSemanticVersion(parsing: packageVersion)
        let expectedArtifactID = "hostwright-\(packageVersion)-macos-arm64-\(sourceCommit.prefix(12))"
        guard artifactID == expectedArtifactID,
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
        let inputStageID = manifest.sourceDirty ? "prebuilt-validation" : "release-build"
        var expectedStageIDs = [
            inputStageID,
            "archive",
            "checksums",
            "sbom",
            "provenance",
            "developer-id-signing",
            "notarization-stapling-gatekeeper",
            "installer-package"
        ]
        if manifest.sourceDirty { expectedStageIDs.append("clean-source") }
        if stages.last?.identifier == "host-environment" { expectedStageIDs.append("host-environment") }
        guard archive.fileName == "\(manifest.artifactID).tar.gz",
              sbom.fileName == DistributionLayout.sbomFileName,
              provenance.fileName == DistributionLayout.provenanceFileName,
              stages.map(\.identifier) == expectedStageIDs,
              stages.allSatisfy({ !$0.identifier.isEmpty && !$0.detail.isEmpty }),
              stages.allSatisfy({ $0.status != .failed }),
              stages.first?.status == .passed,
              stages.first(where: { $0.identifier == "archive" })?.status == .passed,
              stages.first(where: { $0.identifier == "checksums" })?.status == .passed,
              stages.first(where: { $0.identifier == "sbom" })?.status == .passed,
              stages.first(where: { $0.identifier == "provenance" })?.status == .passed,
              stages.first(where: { $0.identifier == "developer-id-signing" })?.status == .blocked,
              stages.first(where: { $0.identifier == "notarization-stapling-gatekeeper" })?.status == .blocked,
              stages.first(where: { $0.identifier == "installer-package" })?.status == .blocked,
              !manifest.sourceDirty || stages.first(where: { $0.identifier == "clean-source" })?.status == .blocked,
              stages.first(where: { $0.identifier == "host-environment" })?.status != .passed else {
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
              evidence.rawResults.blocked == stages.filter({ $0.status == .blocked }).count else {
            throw DistributionError.invalidArtifact("build evidence is not bound to the artifact manifest")
        }
        if manifest.sourceDirty {
            guard evidence.cleanup.status == .notRequired,
                  evidence.cleanup.exactResourceIdentifiers.isEmpty else {
                throw DistributionError.invalidArtifact("prebuilt evidence must not claim clean-build scratch cleanup")
            }
        } else {
            guard evidence.cleanup.status == .succeeded,
                  evidence.cleanup.exactResourceIdentifiers.count == 1,
                  let cleanupPath = evidence.cleanup.exactResourceIdentifiers.first,
                  URL(fileURLWithPath: cleanupPath).lastPathComponent.hasPrefix(
                    "hostwright-dist-clean-scratch-"
                  ) else {
                throw DistributionError.invalidArtifact("clean-build scratch cleanup evidence is missing")
            }
            try DistributionTemporaryPathPolicy.validate(
                URL(fileURLWithPath: cleanupPath),
                role: "recorded clean-build scratch cleanup"
            )
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

    public func validate(
        manifest: DistributionArtifactManifest,
        archive: DistributionArtifactDescriptor,
        expectedCreator: String = "Tool: hostwright-dist-1"
    ) throws {
        try manifest.validate()
        try archive.validate()
        guard archive.fileName.hasSuffix(".tar.gz") ||
                archive.fileName.hasSuffix(".zip") ||
                archive.fileName.hasSuffix(".pkg") else {
            throw DistributionError.invalidArtifact("SPDX subject must be a supported archive or package")
        }
        let packageID = "SPDXRef-Package-Hostwright"
        let expectedNamespace = "urn:hostwright:spdx:\(manifest.sourceCommit):\(archive.sha256)"
        let expectedFileIDs = Set(manifest.files.indices.map { "SPDXRef-File-\($0 + 1)" })
        guard expectedCreator == "Tool: hostwright-dist-1" ||
                expectedCreator == "Tool: hostwright-dist-2" else {
            throw DistributionError.invalidArtifact("SPDX creator policy is unsupported")
        }
        let isTrustedRelease = expectedCreator == "Tool: hostwright-dist-2"
        let expectedLicense = isTrustedRelease ? "Apache-2.0" : "NOASSERTION"
        guard spdxVersion == "SPDX-2.3",
              dataLicense == "CC0-1.0",
              SPDXID == "SPDXRef-DOCUMENT",
              name == "Hostwright \(manifest.packageVersion) artifact-content SBOM",
              documentNamespace == expectedNamespace,
              creationInfo.created == manifest.createdAt,
              creationInfo.creators == [expectedCreator],
              packages.count == 1,
              let package = packages.first,
              package.name == "Hostwright",
              package.SPDXID == packageID,
              package.versionInfo == manifest.packageVersion,
              package.downloadLocation == "NOASSERTION",
              package.filesAnalyzed,
              package.checksums == [SPDXChecksum(algorithm: "SHA256", checksumValue: archive.sha256)],
              package.licenseConcluded == expectedLicense,
              package.licenseDeclared == expectedLicense,
              package.copyrightText == "NOASSERTION" else {
            throw DistributionError.invalidArtifact("SPDX package binding is invalid")
        }
        let expectedFiles = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.sha256) })
        guard files.count == expectedFiles.count,
              Set(files.map(\.fileName)).count == files.count,
              Set(files.map(\.SPDXID)).count == files.count,
              Set(files.map(\.SPDXID)) == expectedFileIDs,
              files.allSatisfy({ file in
                  guard file.fileName.hasPrefix("./") else { return false }
                  let path = String(file.fileName.dropFirst(2))
                  return expectedFiles[path] == file.checksums.first?.checksumValue &&
                    file.checksums == [SPDXChecksum(algorithm: "SHA256", checksumValue: expectedFiles[path] ?? "")] &&
                    file.fileTypes == [path.hasPrefix("bin/") ? "BINARY" : "TEXT"] &&
                    file.licenseConcluded == expectedLicense &&
                    file.copyrightText == "NOASSERTION"
              }) else {
            throw DistributionError.invalidArtifact("SPDX file inventory contains duplicate or malformed entries")
        }
        let actualFiles = files.reduce(into: [String: String]()) { result, file in
            result[String(file.fileName.dropFirst(2))] = file.checksums[0].checksumValue
        }
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
              relationships.count == actualRelationships.count,
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
    public let externalSwiftPMDependencies: [String]?
    public let packageLicenseSPDX: String?
    public let reproducibilityBuildCount: Int?
    public let byteIdenticalUnsignedPayloads: Bool?
    public let toolVersions: [String: String]?

    public init(
        sourceDirty: Bool,
        unsigned: Bool,
        externalSwiftPMDependencies: [String]? = nil,
        packageLicenseSPDX: String? = nil,
        reproducibilityBuildCount: Int? = nil,
        byteIdenticalUnsignedPayloads: Bool? = nil,
        toolVersions: [String: String]? = nil
    ) {
        self.sourceDirty = sourceDirty
        self.unsigned = unsigned
        self.externalSwiftPMDependencies = externalSwiftPMDependencies
        self.packageLicenseSPDX = packageLicenseSPDX
        self.reproducibilityBuildCount = reproducibilityBuildCount
        self.byteIdenticalUnsignedPayloads = byteIdenticalUnsignedPayloads
        self.toolVersions = toolVersions
    }
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
        try manifest.validate()
        try archive.validate(suffix: ".tar.gz")
        let started = ISO8601DateFormatter().date(from: predicate.runDetails.metadata.startedOn)
        let finished = ISO8601DateFormatter().date(from: predicate.runDetails.metadata.finishedOn)
        guard statementType == "https://in-toto.io/Statement/v1",
              predicateType == "https://slsa.dev/provenance/v1",
              subject == [ProvenanceSubject(name: archive.fileName, digest: ["sha256": archive.sha256])],
              predicate.buildDefinition.buildType == "urn:hostwright:buildtype:swiftpm-archive:v1",
              predicate.buildDefinition.externalParameters.configuration == "release",
              predicate.buildDefinition.externalParameters.products == DistributionLayout.shippedExecutableNames,
              predicate.buildDefinition.externalParameters.platform == manifest.platform,
              predicate.buildDefinition.externalParameters.architecture == manifest.architecture,
              predicate.buildDefinition.internalParameters.sourceDirty == manifest.sourceDirty,
              predicate.buildDefinition.internalParameters.unsigned,
              predicate.buildDefinition.resolvedDependencies == [
                  ProvenanceResolvedDependency(
                      uri: "git+https://github.com/hostwright/hostwright.git",
                      digest: ["gitCommit": manifest.sourceCommit]
                  )
              ],
              predicate.runDetails.builder.id == "urn:hostwright:builder:local-swiftpm:v1",
              UUID(uuidString: predicate.runDetails.metadata.invocationId) != nil,
              predicate.runDetails.metadata.startedOn == manifest.createdAt,
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
        self.schemaVersion = 2
        self.artifactID = artifact.artifactID
        self.sourceCommit = artifact.sourceCommit
        self.packageVersion = artifact.packageVersion
        self.files = artifact.files
        self.createdDirectories = createdDirectories
    }

    init(
        schemaVersion: Int,
        artifactID: String,
        sourceCommit: String,
        packageVersion: String,
        files: [DistributionFileRecord],
        createdDirectories: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.artifactID = artifactID
        self.sourceCommit = sourceCommit
        self.packageVersion = packageVersion
        self.files = files
        self.createdDirectories = createdDirectories
    }

    public func validate() throws {
        let expectedModes: [String: Int]
        switch schemaVersion {
        case 1:
            expectedModes = DistributionLayout.legacyPayloadModesV1
        case 2:
            expectedModes = DistributionLayout.payloadModes
        default:
            throw DistributionError.invalidManifest("install ownership manifest schema is unsupported")
        }
        let allowedDirectories = Set(expectedModes.keys.flatMap { path -> [String] in
            let components = path.split(separator: "/").map(String.init)
            var result: [String] = []
            var current = ""
            for component in components.dropLast() {
                current = current.isEmpty ? component : "\(current)/\(component)"
                result.append(current)
            }
            return result
        })
        _ = try DistributionSemanticVersion(parsing: packageVersion)
        guard artifactID == "hostwright-\(packageVersion)-macos-arm64-\(sourceCommit.prefix(12))",
              sourceCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              sourceCommit != String(repeating: "0", count: 40),
              files.map(\.path) == files.map(\.path).sorted(),
              Set(files.map(\.path)) == Set(expectedModes.keys),
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
                  expectedModes[file.path] == file.mode else {
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
        schemaVersion: Int = 2,
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
        guard schemaVersion == 2,
              baselineCommit != candidateCommit,
              baselineCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              candidateCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              baselineCommit != String(repeating: "0", count: 40),
              candidateCommit != String(repeating: "0", count: 40),
              stages.map(\.identifier) == ["install", "upgrade", "rollback", "uninstall"],
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

public enum DistributionLifecycleOperation: String, Codable, Equatable, Sendable {
    case install
    case upgrade
    case repair
    case rollback
    case uninstall
}

public enum DistributionLifecycleCheckpoint: String, Codable, Equatable, Sendable {
    case intentRecorded = "intent-recorded"
    case payloadStaged = "payload-staged"
    case priorPayloadBackedUp = "prior-payload-backed-up"
    case stateBackedUp = "state-backed-up"
    case serviceStopped = "service-stopped"
    case payloadPublishing = "payload-publishing"
    case payloadPublished = "payload-published"
    case stateMigrating = "state-migrating"
    case stateMigrated = "state-migrated"
    case serviceRestored = "service-restored"
    case verifying
    case statusPublished = "status-published"
    case compensationPublished = "compensation-published"
}

public enum DistributionManagedServiceState: String, Codable, Equatable, Sendable {
    case notInstalled = "not-installed"
    case stopped
    case running
}

public enum DistributionUninstallDataPolicy: String, Codable, Equatable, Sendable {
    case preserve
    case remove
}

public struct DistributionStateSnapshotRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let databasePath: String
    public let snapshotRelativePath: String
    public let databaseSHA256: String
    public let databaseBytes: UInt64
    public let stateSchemaVersion: Int

    public init(
        schemaVersion: Int = 1,
        databasePath: String,
        snapshotRelativePath: String,
        databaseSHA256: String,
        databaseBytes: UInt64,
        stateSchemaVersion: Int
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "distributionStateSnapshot"
        self.databasePath = databasePath
        self.snapshotRelativePath = snapshotRelativePath
        self.databaseSHA256 = databaseSHA256
        self.databaseBytes = databaseBytes
        self.stateSchemaVersion = stateSchemaVersion
    }

    public func validate(transactionRelativePath: String) throws {
        let normalizedDatabase = try HostwrightLocalPathResolver.normalizedAbsolutePath(
            databasePath,
            role: "distribution state database"
        )
        let expectedPrefix = transactionRelativePath + "/state/"
        guard schemaVersion == 1,
              kind == "distributionStateSnapshot",
              normalizedDatabase == databasePath,
              DistributionPathPolicy.isSafeRelativePath(snapshotRelativePath),
              snapshotRelativePath.hasPrefix(expectedPrefix),
              snapshotRelativePath == expectedPrefix + "state.sqlite",
              databaseSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              databaseBytes > 0,
              (0...HostwrightContractVersions.stateSchema).contains(stateSchemaVersion) else {
            throw DistributionError.lifecycleFailed("state snapshot record is invalid or not transaction-bound")
        }
    }
}

public struct DistributionLifecycleJournal: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let operationID: String
    public let operation: DistributionLifecycleOperation
    public let checkpoint: DistributionLifecycleCheckpoint
    public let prefix: String
    public let transactionRelativePath: String
    public let fromManifest: DistributionInstallManifest?
    public let toManifest: DistributionInstallManifest?
    public let stateSnapshot: DistributionStateSnapshotRecord?
    public let serviceBefore: DistributionManagedServiceState
    public let dataPolicy: DistributionUninstallDataPolicy
    public let startedAt: String
    public let authorizedRollbackOperationID: String?
    public let priorStatus: DistributionInstallationStatus?
    public let packageReceiptCleanup: Bool?

    public init(
        schemaVersion: Int = 1,
        operationID: String,
        operation: DistributionLifecycleOperation,
        checkpoint: DistributionLifecycleCheckpoint,
        prefix: String,
        transactionRelativePath: String,
        fromManifest: DistributionInstallManifest?,
        toManifest: DistributionInstallManifest?,
        stateSnapshot: DistributionStateSnapshotRecord?,
        serviceBefore: DistributionManagedServiceState,
        dataPolicy: DistributionUninstallDataPolicy,
        startedAt: String,
        authorizedRollbackOperationID: String? = nil,
        priorStatus: DistributionInstallationStatus? = nil,
        packageReceiptCleanup: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "distributionLifecycleJournal"
        self.operationID = operationID
        self.operation = operation
        self.checkpoint = checkpoint
        self.prefix = prefix
        self.transactionRelativePath = transactionRelativePath
        self.fromManifest = fromManifest
        self.toManifest = toManifest
        self.stateSnapshot = stateSnapshot
        self.serviceBefore = serviceBefore
        self.dataPolicy = dataPolicy
        self.startedAt = startedAt
        self.authorizedRollbackOperationID = authorizedRollbackOperationID
        self.priorStatus = priorStatus
        self.packageReceiptCleanup = packageReceiptCleanup
    }

    public func replacing(
        checkpoint: DistributionLifecycleCheckpoint,
        stateSnapshot: DistributionStateSnapshotRecord? = nil
    ) -> DistributionLifecycleJournal {
        DistributionLifecycleJournal(
            operationID: operationID,
            operation: operation,
            checkpoint: checkpoint,
            prefix: prefix,
            transactionRelativePath: transactionRelativePath,
            fromManifest: fromManifest,
            toManifest: toManifest,
            stateSnapshot: stateSnapshot ?? self.stateSnapshot,
            serviceBefore: serviceBefore,
            dataPolicy: dataPolicy,
            startedAt: startedAt,
            authorizedRollbackOperationID: authorizedRollbackOperationID,
            priorStatus: priorStatus,
            packageReceiptCleanup: packageReceiptCleanup
        )
    }

    public func validate() throws {
        guard schemaVersion == 1,
              kind == "distributionLifecycleJournal",
              Self.isCanonicalUUID(operationID),
              try HostwrightLocalPathResolver.normalizedAbsolutePath(
                prefix,
                role: "distribution lifecycle prefix"
              ) == prefix,
              transactionRelativePath == "\(DistributionLayout.lifecycleDirectoryName)/\(DistributionLayout.lifecycleTransactionsDirectoryName)/\(operationID)",
              DistributionPathPolicy.isSafeRelativePath(transactionRelativePath),
              ISO8601DateFormatter().date(from: startedAt) != nil else {
            throw DistributionError.lifecycleFailed("lifecycle journal identity, path, or timestamp is invalid")
        }
        if checkpoint == .serviceStopped || checkpoint == .serviceRestored {
            guard serviceBefore != .notInstalled, operation != .install else {
                throw DistributionError.lifecycleFailed(
                    "lifecycle service checkpoint is not bound to an existing managed service"
                )
            }
        }
        try fromManifest?.validate()
        try toManifest?.validate()
        try stateSnapshot?.validate(transactionRelativePath: transactionRelativePath)
        try priorStatus?.validate()
        guard packageReceiptCleanup != false else {
            throw DistributionError.lifecycleFailed(
                "lifecycle journal must omit a disabled package receipt marker"
            )
        }
        if let priorStatus {
            guard priorStatus.prefix == prefix,
                  priorStatus.installedManifest == fromManifest else {
                throw DistributionError.lifecycleFailed(
                    "lifecycle journal prior status is not bound to its source generation"
                )
            }
        }

        switch operation {
        case .install:
            guard fromManifest == nil, toManifest != nil,
                  stateSnapshot == nil, authorizedRollbackOperationID == nil,
                  priorStatus == nil, dataPolicy == .preserve,
                  packageReceiptCleanup == nil else {
                throw DistributionError.lifecycleFailed("install journal shape is invalid")
            }
        case .upgrade:
            guard let fromManifest, let toManifest,
                  priorStatus != nil,
                  authorizedRollbackOperationID == nil,
                  dataPolicy == .preserve,
                  packageReceiptCleanup == nil,
                  try DistributionVersionTransition.classify(
                    installedVersion: fromManifest.packageVersion,
                    installedCommit: fromManifest.sourceCommit,
                    candidateVersion: toManifest.packageVersion,
                    candidateCommit: toManifest.sourceCommit
                  ) == .upgrade else {
                throw DistributionError.lifecycleFailed("upgrade journal shape is invalid")
            }
        case .repair:
            guard let fromManifest, let toManifest,
                  priorStatus != nil,
                  authorizedRollbackOperationID == nil,
                  dataPolicy == .preserve,
                  packageReceiptCleanup == nil,
                  try DistributionVersionTransition.classify(
                    installedVersion: fromManifest.packageVersion,
                    installedCommit: fromManifest.sourceCommit,
                    candidateVersion: toManifest.packageVersion,
                    candidateCommit: toManifest.sourceCommit
                  ) == .repair else {
                throw DistributionError.lifecycleFailed("repair journal shape is invalid")
            }
        case .rollback:
            guard let fromManifest, let toManifest,
                  let priorStatus,
                  let authorizedRollbackOperationID,
                  Self.isCanonicalUUID(authorizedRollbackOperationID),
                  authorizedRollbackOperationID != operationID,
                  priorStatus.rollbackOperationID == authorizedRollbackOperationID,
                  dataPolicy == .preserve,
                  packageReceiptCleanup == nil,
                  try DistributionSemanticVersion(parsing: toManifest.packageVersion)
                    < DistributionSemanticVersion(parsing: fromManifest.packageVersion) else {
                throw DistributionError.lifecycleFailed("rollback journal is not bound to a prior verified generation")
            }
        case .uninstall:
            guard fromManifest != nil, toManifest == nil,
                  priorStatus != nil,
                  authorizedRollbackOperationID == nil else {
                throw DistributionError.lifecycleFailed("uninstall journal shape is invalid")
            }
            if packageReceiptCleanup == true {
                guard priorStatus?.packageOrigin?.pendingReceiptCleanup == false else {
                    throw DistributionError.lifecycleFailed(
                        "package receipt cleanup is not bound to a package-owned generation"
                    )
                }
            }
        }
    }

    static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && value == value.lowercased()
    }
}

public struct DistributionInstallationStatus: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let installationID: String
    public let generation: Int
    public let prefix: String
    public let installedManifest: DistributionInstallManifest
    public let stateDatabasePath: String?
    public let service: DistributionManagedServiceState
    public let rollbackOperationID: String?
    public let installationSource: DistributionInstallationSource?
    public let packageIdentifier: String?
    public let packageVersion: String?
    public let mostRecentPackageReceiptVersion: String?
    public let pendingReceiptCleanup: Bool?
    public let updatedAt: String

    public init(
        schemaVersion: Int = 1,
        installationID: String,
        generation: Int,
        prefix: String,
        installedManifest: DistributionInstallManifest,
        stateDatabasePath: String?,
        service: DistributionManagedServiceState,
        rollbackOperationID: String?,
        packageOrigin: DistributionPackageOrigin? = nil,
        updatedAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "distributionInstallationStatus"
        self.installationID = installationID
        self.generation = generation
        self.prefix = prefix
        self.installedManifest = installedManifest
        self.stateDatabasePath = stateDatabasePath
        self.service = service
        self.rollbackOperationID = rollbackOperationID
        self.installationSource = packageOrigin?.installationSource
        self.packageIdentifier = packageOrigin?.packageIdentifier
        self.packageVersion = packageOrigin?.packageVersion
        self.mostRecentPackageReceiptVersion = packageOrigin?.mostRecentPackageReceiptVersion
        self.pendingReceiptCleanup = packageOrigin?.pendingReceiptCleanup
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        guard schemaVersion == 1,
              kind == "distributionInstallationStatus",
              DistributionLifecycleJournal.isCanonicalUUID(installationID),
              generation > 0,
              try HostwrightLocalPathResolver.normalizedAbsolutePath(
                prefix,
                role: "distribution installation prefix"
              ) == prefix,
              rollbackOperationID.map(DistributionLifecycleJournal.isCanonicalUUID) ?? true,
              ISO8601DateFormatter().date(from: updatedAt) != nil else {
            throw DistributionError.lifecycleFailed("installation status identity, path, or timestamp is invalid")
        }
        try installedManifest.validate()
        if let stateDatabasePath {
            guard try HostwrightLocalPathResolver.normalizedAbsolutePath(
                stateDatabasePath,
                role: "distribution installation state database"
            ) == stateDatabasePath else {
                throw DistributionError.lifecycleFailed("installation state database path is invalid")
            }
        }
        let packageFields: [Any?] = [
            installationSource,
            packageIdentifier,
            packageVersion,
            mostRecentPackageReceiptVersion,
            pendingReceiptCleanup
        ]
        guard packageFields.allSatisfy({ $0 == nil }) || packageFields.allSatisfy({ $0 != nil }) else {
            throw DistributionError.lifecycleFailed("installation status package origin is incomplete")
        }
        if let packageOrigin {
            try packageOrigin.validate()
            guard try DistributionPackageVersion.make(from: installedManifest.packageVersion)
                == packageOrigin.packageVersion else {
                throw DistributionError.lifecycleFailed(
                    "installation status package version does not match installed manifest"
                )
            }
        }
    }

    public var packageOrigin: DistributionPackageOrigin? {
        guard installationSource == .package,
              let packageIdentifier,
              let packageVersion,
              let mostRecentPackageReceiptVersion,
              let pendingReceiptCleanup else {
            return nil
        }
        return DistributionPackageOrigin(
            packageIdentifier: packageIdentifier,
            packageVersion: packageVersion,
            mostRecentPackageReceiptVersion: mostRecentPackageReceiptVersion,
            pendingReceiptCleanup: pendingReceiptCleanup
        )
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
