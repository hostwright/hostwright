import Foundation
import HostwrightCore

public enum TrustedReleaseLayout {
    public static let manifestFileName = "release-manifest.json"
    public static let manifestSignatureFileName = "release-manifest.json.cms"
    public static let checksumFileName = "SHA256SUMS"
    public static let checksumSignatureFileName = "SHA256SUMS.cms"
    public static let provenanceFileName = "provenance.intoto.json"
    public static let provenanceSignatureFileName = "provenance.intoto.json.cms"
    public static let evidenceFileName = "release-evidence.json"
    public static let evidenceSignatureFileName = "release-evidence.json.cms"

    public static func archiveFileName(artifactID: String) -> String {
        "\(artifactID).zip"
    }

    public static func packageFileName(artifactID: String) -> String {
        "\(artifactID).pkg"
    }

    public static func archiveSBOMFileName(artifactID: String) -> String {
        "\(artifactID).archive.spdx.json"
    }

    public static func packageSBOMFileName(artifactID: String) -> String {
        "\(artifactID).pkg.spdx.json"
    }
}

public struct TrustedReleaseRetentionPolicy: Codable, Equatable, Sendable {
    public static let current = TrustedReleaseRetentionPolicy(
        workflowBundleDays: 90,
        publishedReleaseAssets: "indefinite",
        publishedReleaseEvidence: "indefinite"
    )

    public let workflowBundleDays: Int
    public let publishedReleaseAssets: String
    public let publishedReleaseEvidence: String

    public init(
        workflowBundleDays: Int,
        publishedReleaseAssets: String,
        publishedReleaseEvidence: String
    ) {
        self.workflowBundleDays = workflowBundleDays
        self.publishedReleaseAssets = publishedReleaseAssets
        self.publishedReleaseEvidence = publishedReleaseEvidence
    }

    public func validate() throws {
        guard self == .current else {
            throw DistributionError.invalidArtifact("trusted release retention policy is unsupported")
        }
    }
}

public enum TrustedReleaseIdentityKind: String, Codable, Equatable, Sendable {
    case application = "developer-id-application"
    case installer = "developer-id-installer"
}

public struct TrustedReleaseIdentity: Codable, Equatable, Sendable {
    public let kind: TrustedReleaseIdentityKind
    public let sha1Fingerprint: String
    public let commonName: String
    public let teamIdentifier: String

    public init(
        kind: TrustedReleaseIdentityKind,
        sha1Fingerprint: String,
        commonName: String,
        teamIdentifier: String
    ) {
        self.kind = kind
        self.sha1Fingerprint = sha1Fingerprint
        self.commonName = commonName
        self.teamIdentifier = teamIdentifier
    }

    public func validate() throws {
        let expectedPrefix = switch kind {
        case .application: "Developer ID Application: "
        case .installer: "Developer ID Installer: "
        }
        guard sha1Fingerprint.range(of: "^[A-F0-9]{40}$", options: .regularExpression) != nil,
              teamIdentifier.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              commonName.hasPrefix(expectedPrefix),
              commonName.hasSuffix("(\(teamIdentifier))"),
              !commonName.contains("\n"),
              !commonName.contains("\r") else {
            throw DistributionError.invalidArtifact("release signing identity is not an exact Developer ID identity")
        }
    }
}

public enum TrustedTicketAttachment: String, Codable, Equatable, Sendable {
    case online = "online-ticket"
    case stapled
}

public struct TrustedNotarizationRecord: Codable, Equatable, Sendable {
    public let artifactFileName: String
    public let submissionID: String
    public let status: String
    public let ticketAttachment: TrustedTicketAttachment
    public let gatekeeperSource: String

    public init(
        artifactFileName: String,
        submissionID: String,
        status: String,
        ticketAttachment: TrustedTicketAttachment,
        gatekeeperSource: String
    ) {
        self.artifactFileName = artifactFileName
        self.submissionID = submissionID
        self.status = status
        self.ticketAttachment = ticketAttachment
        self.gatekeeperSource = gatekeeperSource
    }

    public func validate(expectedFileName: String, expectedAttachment: TrustedTicketAttachment) throws {
        guard artifactFileName == expectedFileName,
              DistributionPathPolicy.isSafeFileName(artifactFileName),
              UUID(uuidString: submissionID) != nil,
              status == "Accepted",
              ticketAttachment == expectedAttachment,
              gatekeeperSource == "Notarized Developer ID" else {
            throw DistributionError.invalidArtifact("notarization record is incomplete or not accepted")
        }
    }
}

public struct TrustedReleaseManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let artifactID: String
    public let packageVersion: String
    public let releaseTag: String
    public let sourceCommit: String
    public let sourceDirty: Bool
    public let platform: String
    public let architecture: String
    public let minimumMacOSMajorVersion: Int
    public let createdAt: String
    public let applicationSigner: TrustedReleaseIdentity
    public let installerSigner: TrustedReleaseIdentity
    public let payloadFiles: [DistributionFileRecord]
    public let archive: DistributionArtifactDescriptor
    public let package: DistributionArtifactDescriptor
    public let archiveSBOM: DistributionArtifactDescriptor
    public let packageSBOM: DistributionArtifactDescriptor
    public let provenance: DistributionArtifactDescriptor
    public let archiveNotarization: TrustedNotarizationRecord
    public let packageNotarization: TrustedNotarizationRecord

    public init(
        schemaVersion: Int = 1,
        artifactID: String,
        packageVersion: String,
        releaseTag: String,
        sourceCommit: String,
        sourceDirty: Bool,
        platform: String = "macos",
        architecture: String = "arm64",
        minimumMacOSMajorVersion: Int,
        createdAt: String,
        applicationSigner: TrustedReleaseIdentity,
        installerSigner: TrustedReleaseIdentity,
        payloadFiles: [DistributionFileRecord],
        archive: DistributionArtifactDescriptor,
        package: DistributionArtifactDescriptor,
        archiveSBOM: DistributionArtifactDescriptor,
        packageSBOM: DistributionArtifactDescriptor,
        provenance: DistributionArtifactDescriptor,
        archiveNotarization: TrustedNotarizationRecord,
        packageNotarization: TrustedNotarizationRecord
    ) {
        self.schemaVersion = schemaVersion
        self.artifactID = artifactID
        self.packageVersion = packageVersion
        self.releaseTag = releaseTag
        self.sourceCommit = sourceCommit
        self.sourceDirty = sourceDirty
        self.platform = platform
        self.architecture = architecture
        self.minimumMacOSMajorVersion = minimumMacOSMajorVersion
        self.createdAt = createdAt
        self.applicationSigner = applicationSigner
        self.installerSigner = installerSigner
        self.payloadFiles = payloadFiles
        self.archive = archive
        self.package = package
        self.archiveSBOM = archiveSBOM
        self.packageSBOM = packageSBOM
        self.provenance = provenance
        self.archiveNotarization = archiveNotarization
        self.packageNotarization = packageNotarization
    }

    public func validate() throws {
        guard schemaVersion == 1,
              packageVersion.range(
                of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$",
                options: .regularExpression
              ) != nil,
              releaseTag == "v\(packageVersion)",
              sourceCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              sourceCommit != String(repeating: "0", count: 40),
              !sourceDirty,
              platform == "macos",
              architecture == "arm64",
              minimumMacOSMajorVersion == 26,
              ISO8601DateFormatter().date(from: createdAt) != nil,
              artifactID == "hostwright-\(packageVersion)-macos-arm64-\(sourceCommit.prefix(12))" else {
            throw DistributionError.invalidManifest("trusted release identity or compatibility metadata is invalid")
        }
        try applicationSigner.validate()
        try installerSigner.validate()
        guard applicationSigner.kind == .application,
              installerSigner.kind == .installer,
              applicationSigner.teamIdentifier == installerSigner.teamIdentifier else {
            throw DistributionError.invalidManifest("application and installer identities must belong to one Developer ID team")
        }
        guard payloadFiles.map(\.path) == payloadFiles.map(\.path).sorted(),
              Set(payloadFiles.map(\.path)) == Set(DistributionLayout.payloadModes.keys),
              Set(payloadFiles.map(\.path)).count == payloadFiles.count else {
            throw DistributionError.invalidManifest("trusted release payload inventory is incomplete")
        }
        for file in payloadFiles {
            guard DistributionPathPolicy.isSafeRelativePath(file.path),
                  file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  file.sizeBytes > 0,
                  DistributionLayout.payloadModes[file.path] == file.mode else {
                throw DistributionError.invalidManifest("trusted release payload metadata is invalid for \(file.path)")
            }
        }
        try archive.validate(suffix: ".zip")
        try package.validate(suffix: ".pkg")
        try archiveSBOM.validate(suffix: ".archive.spdx.json")
        try packageSBOM.validate(suffix: ".pkg.spdx.json")
        try provenance.validate(suffix: ".intoto.json")
        guard archive.fileName == TrustedReleaseLayout.archiveFileName(artifactID: artifactID),
              package.fileName == TrustedReleaseLayout.packageFileName(artifactID: artifactID),
              archiveSBOM.fileName == TrustedReleaseLayout.archiveSBOMFileName(artifactID: artifactID),
              packageSBOM.fileName == TrustedReleaseLayout.packageSBOMFileName(artifactID: artifactID),
              provenance.fileName == TrustedReleaseLayout.provenanceFileName else {
            throw DistributionError.invalidManifest("trusted release artifact names do not match their identity")
        }
        try archiveNotarization.validate(
            expectedFileName: archive.fileName,
            expectedAttachment: .online
        )
        try packageNotarization.validate(
            expectedFileName: package.fileName,
            expectedAttachment: .stapled
        )
    }
}

public struct TrustedReleaseBuildMetadata: Equatable, Sendable {
    public static let requiredToolVersionNames = [
        "git",
        "hostwright-dist",
        "notarytool",
        "swift",
        "tar"
    ]

    public let externalSwiftPMDependencies: [String]
    public let packageLicenseSPDX: String
    public let reproducibilityBuildCount: Int
    public let byteIdenticalUnsignedPayloads: Bool
    public let toolVersions: [String: String]

    public init(
        externalSwiftPMDependencies: [String],
        packageLicenseSPDX: String,
        reproducibilityBuildCount: Int,
        byteIdenticalUnsignedPayloads: Bool,
        toolVersions: [String: String]
    ) {
        self.externalSwiftPMDependencies = externalSwiftPMDependencies
        self.packageLicenseSPDX = packageLicenseSPDX
        self.reproducibilityBuildCount = reproducibilityBuildCount
        self.byteIdenticalUnsignedPayloads = byteIdenticalUnsignedPayloads
        self.toolVersions = toolVersions
    }

    public func validate() throws {
        guard externalSwiftPMDependencies.isEmpty,
              packageLicenseSPDX == "Apache-2.0",
              reproducibilityBuildCount == 2,
              byteIdenticalUnsignedPayloads else {
            throw DistributionError.invalidArtifact(
                "trusted release dependency, license, or reproducibility evidence is invalid"
            )
        }
        try Self.validateToolVersions(toolVersions)
    }

    public static func validateToolVersions(_ toolVersions: [String: String]) throws {
        let expectedNames = Set(requiredToolVersionNames)
        guard Set(toolVersions.keys) == expectedNames,
              toolVersions["hostwright-dist"] == "2",
              toolVersions.allSatisfy({ name, version in
                  expectedNames.contains(name) &&
                    !version.isEmpty &&
                    version.utf8.count <= 512 &&
                    !version.contains("\n") &&
                    !version.contains("\r") &&
                    version.lowercased() != "unavailable"
              }) else {
            throw DistributionError.invalidArtifact(
                "trusted release tool-version evidence is incomplete or unsupported"
            )
        }
    }
}

public struct TrustedReleaseProvenanceStatement: Codable, Equatable, Sendable {
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

    public func validate(
        manifest: TrustedReleaseManifest,
        expectedBuildMetadata: TrustedReleaseBuildMetadata? = nil
    ) throws {
        try manifest.validate()
        let internalParameters = predicate.buildDefinition.internalParameters
        guard let externalSwiftPMDependencies = internalParameters.externalSwiftPMDependencies,
              let packageLicenseSPDX = internalParameters.packageLicenseSPDX,
              let reproducibilityBuildCount = internalParameters.reproducibilityBuildCount,
              let byteIdenticalUnsignedPayloads = internalParameters.byteIdenticalUnsignedPayloads,
              let toolVersions = internalParameters.toolVersions else {
            throw DistributionError.invalidArtifact(
                "trusted provenance omits dependency, license, or reproducibility evidence"
            )
        }
        let recordedBuildMetadata = TrustedReleaseBuildMetadata(
            externalSwiftPMDependencies: externalSwiftPMDependencies,
            packageLicenseSPDX: packageLicenseSPDX,
            reproducibilityBuildCount: reproducibilityBuildCount,
            byteIdenticalUnsignedPayloads: byteIdenticalUnsignedPayloads,
            toolVersions: toolVersions
        )
        try recordedBuildMetadata.validate()
        if let expectedBuildMetadata, recordedBuildMetadata != expectedBuildMetadata {
            throw DistributionError.invalidArtifact(
                "trusted provenance build evidence differs from the observed release build"
            )
        }
        let expectedSubjects = [manifest.archive, manifest.package]
            .sorted { $0.fileName < $1.fileName }
            .map { ProvenanceSubject(name: $0.fileName, digest: ["sha256": $0.sha256]) }
        let started = ISO8601DateFormatter().date(from: predicate.runDetails.metadata.startedOn)
        let finished = ISO8601DateFormatter().date(from: predicate.runDetails.metadata.finishedOn)
        guard statementType == "https://in-toto.io/Statement/v1",
              predicateType == "https://slsa.dev/provenance/v1",
              subject == expectedSubjects,
              predicate.buildDefinition.buildType == "urn:hostwright:buildtype:swiftpm-developer-id:v1",
              predicate.buildDefinition.externalParameters.configuration == "release",
              predicate.buildDefinition.externalParameters.products == DistributionLayout.shippedExecutableNames,
              predicate.buildDefinition.externalParameters.platform == manifest.platform,
              predicate.buildDefinition.externalParameters.architecture == manifest.architecture,
              !predicate.buildDefinition.internalParameters.sourceDirty,
              !predicate.buildDefinition.internalParameters.unsigned,
              predicate.buildDefinition.resolvedDependencies == [
                ProvenanceResolvedDependency(
                    uri: "git+https://github.com/hostwright/hostwright.git",
                    digest: ["gitCommit": manifest.sourceCommit]
                )
              ],
              predicate.runDetails.builder.id == "urn:hostwright:builder:release-macos:v1",
              UUID(uuidString: predicate.runDetails.metadata.invocationId) != nil,
              predicate.runDetails.metadata.startedOn == manifest.createdAt,
              let started,
              let finished,
              finished >= started else {
            throw DistributionError.invalidArtifact("trusted provenance is not bound to the signed release")
        }
    }
}

public struct TrustedReleaseReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let manifest: TrustedReleaseManifest
    public let manifestDescriptor: DistributionArtifactDescriptor
    public let checksumDescriptor: DistributionArtifactDescriptor
    public let manifestSignature: DistributionArtifactDescriptor
    public let checksumSignature: DistributionArtifactDescriptor
    public let provenanceSignature: DistributionArtifactDescriptor
    public let retentionPolicy: TrustedReleaseRetentionPolicy
    public let stages: [DistributionStageRecord]
    public let evidence: HostwrightEvidenceReport

    public init(
        schemaVersion: Int = 1,
        manifest: TrustedReleaseManifest,
        manifestDescriptor: DistributionArtifactDescriptor,
        checksumDescriptor: DistributionArtifactDescriptor,
        manifestSignature: DistributionArtifactDescriptor,
        checksumSignature: DistributionArtifactDescriptor,
        provenanceSignature: DistributionArtifactDescriptor,
        retentionPolicy: TrustedReleaseRetentionPolicy = .current,
        stages: [DistributionStageRecord],
        evidence: HostwrightEvidenceReport
    ) {
        self.schemaVersion = schemaVersion
        self.manifest = manifest
        self.manifestDescriptor = manifestDescriptor
        self.checksumDescriptor = checksumDescriptor
        self.manifestSignature = manifestSignature
        self.checksumSignature = checksumSignature
        self.provenanceSignature = provenanceSignature
        self.retentionPolicy = retentionPolicy
        self.stages = stages
        self.evidence = evidence
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw DistributionError.invalidArtifact("unsupported trusted-release report schema")
        }
        try manifest.validate()
        try manifestDescriptor.validate(suffix: ".json")
        try checksumDescriptor.validate()
        try manifestSignature.validate(suffix: ".cms")
        try checksumSignature.validate(suffix: ".cms")
        try provenanceSignature.validate(suffix: ".cms")
        try retentionPolicy.validate()
        let expectedStages = [
            "source-reproducibility",
            "developer-id-application-signing",
            "archive",
            "archive-notarization",
            "installer-package",
            "package-notarization",
            "package-stapling",
            "gatekeeper",
            "sbom",
            "provenance",
            "checksums",
            "detached-signatures",
            "independent-verification"
        ]
        guard manifestDescriptor.fileName == TrustedReleaseLayout.manifestFileName,
              checksumDescriptor.fileName == TrustedReleaseLayout.checksumFileName,
              manifestSignature.fileName == TrustedReleaseLayout.manifestSignatureFileName,
              checksumSignature.fileName == TrustedReleaseLayout.checksumSignatureFileName,
              provenanceSignature.fileName == TrustedReleaseLayout.provenanceSignatureFileName,
              stages.map(\.identifier) == expectedStages,
              stages.allSatisfy({ $0.status == .passed && !$0.detail.isEmpty }) else {
            throw DistributionError.invalidArtifact("trusted release stages or sidecar identity are incomplete")
        }
        try evidence.validate()
        try TrustedReleaseBuildMetadata.validateToolVersions(evidence.environment.toolVersions)
        guard evidence.evidenceClass == .distributionArtifact,
              evidence.status == .passed,
              evidence.source.commit == manifest.sourceCommit,
              !evidence.source.dirty,
              evidence.failures.isEmpty,
              evidence.blockers.isEmpty,
              evidence.rawResults.executed == stages.count,
              evidence.rawResults.passed == stages.count,
              evidence.rawResults.failed == 0,
              evidence.rawResults.blocked == 0,
              evidence.cleanup.status == .succeeded else {
            throw DistributionError.invalidArtifact("trusted release evidence is not a clean passing result")
        }
    }
}

public struct TrustedReleaseCommandOutput: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let status: HostwrightEvidenceStatus
    public let releaseDirectory: String
    public let releaseTag: String
    public let sourceCommit: String
    public let signerTeamIdentifier: String
    public let archive: DistributionArtifactDescriptor
    public let package: DistributionArtifactDescriptor
    public let archiveSBOM: DistributionArtifactDescriptor
    public let packageSBOM: DistributionArtifactDescriptor
    public let provenance: DistributionArtifactDescriptor
    public let retentionPolicy: TrustedReleaseRetentionPolicy
    public let cleanup: HostwrightEvidenceCleanup

    public init(report: TrustedReleaseReport, releaseDirectory: String) {
        self.schemaVersion = 1
        self.kind = "trustedRelease"
        self.status = report.evidence.status
        self.releaseDirectory = releaseDirectory
        self.releaseTag = report.manifest.releaseTag
        self.sourceCommit = report.manifest.sourceCommit
        self.signerTeamIdentifier = report.manifest.applicationSigner.teamIdentifier
        self.archive = report.manifest.archive
        self.package = report.manifest.package
        self.archiveSBOM = report.manifest.archiveSBOM
        self.packageSBOM = report.manifest.packageSBOM
        self.provenance = report.manifest.provenance
        self.retentionPolicy = report.retentionPolicy
        self.cleanup = report.evidence.cleanup
    }
}

public struct TrustedReleaseVerificationCommandOutput: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let status: HostwrightEvidenceStatus
    public let packageVersion: String
    public let releaseTag: String
    public let sourceCommit: String
    public let signerTeamIdentifier: String
    public let archive: DistributionArtifactDescriptor
    public let package: DistributionArtifactDescriptor
    public let archiveSBOM: DistributionArtifactDescriptor
    public let packageSBOM: DistributionArtifactDescriptor
    public let provenance: DistributionArtifactDescriptor
    public let verificationCommandCount: Int
    public let cleanup: HostwrightEvidenceCleanup

    public init(result: TrustedReleaseVerificationResult) {
        self.schemaVersion = 1
        self.kind = "trustedReleaseVerification"
        self.status = .passed
        self.packageVersion = result.manifest.packageVersion
        self.releaseTag = result.manifest.releaseTag
        self.sourceCommit = result.manifest.sourceCommit
        self.signerTeamIdentifier = result.manifest.applicationSigner.teamIdentifier
        self.archive = result.manifest.archive
        self.package = result.manifest.package
        self.archiveSBOM = result.manifest.archiveSBOM
        self.packageSBOM = result.manifest.packageSBOM
        self.provenance = result.manifest.provenance
        self.verificationCommandCount = result.commands.count
        self.cleanup = result.cleanup
    }
}

public struct HomebrewFormulaCommandOutput: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let status: HostwrightEvidenceStatus
    public let outputFile: String
    public let releaseTag: String
    public let sourceCommit: String
    public let archive: DistributionArtifactDescriptor

    public init(manifest: TrustedReleaseManifest, outputFile: String) {
        self.schemaVersion = 1
        self.kind = "homebrewFormula"
        self.status = .passed
        self.outputFile = outputFile
        self.releaseTag = manifest.releaseTag
        self.sourceCommit = manifest.sourceCommit
        self.archive = manifest.archive
    }
}
