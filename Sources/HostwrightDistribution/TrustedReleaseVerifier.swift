import Darwin
import Foundation
import HostwrightCore

public struct TrustedReleaseVerificationResult: Sendable {
    public let manifest: TrustedReleaseManifest
    public let commands: [HostwrightEvidenceCommand]
    public let cleanup: HostwrightEvidenceCleanup

    public init(
        manifest: TrustedReleaseManifest,
        commands: [HostwrightEvidenceCommand],
        cleanup: HostwrightEvidenceCleanup
    ) {
        self.manifest = manifest
        self.commands = commands
        self.cleanup = cleanup
    }
}

public struct VerifiedTrustedReleaseArtifact: Sendable {
    public let releaseDirectory: URL
    public let extractedRoot: URL
    public let manifest: DistributionArtifactManifest
    public let trustedManifest: TrustedReleaseManifest

    init(
        releaseDirectory: URL,
        extractedRoot: URL,
        manifest: DistributionArtifactManifest,
        trustedManifest: TrustedReleaseManifest
    ) {
        self.releaseDirectory = releaseDirectory
        self.extractedRoot = extractedRoot
        self.manifest = manifest
        self.trustedManifest = trustedManifest
    }
}

public struct TrustedReleaseVerifier: Sendable {
    private let runner: DistributionProcessRunner

    public init(runner: DistributionProcessRunner = DistributionProcessRunner()) {
        self.runner = runner
    }

    public func verify(
        releaseDirectory: URL,
        expectedTeamIdentifier: String,
        requireEvidenceReport: Bool = true,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> TrustedReleaseVerificationResult {
        guard expectedTeamIdentifier.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              try DistributionFileSystem.isDirectoryNonSymlink(releaseDirectory) else {
            throw DistributionError.invalidArguments("Trusted release verification requires a directory and exact team identifier.")
        }
        let manifestURL = releaseDirectory.appendingPathComponent(TrustedReleaseLayout.manifestFileName)
        let manifest = try DistributionJSON.decode(TrustedReleaseManifest.self, from: manifestURL)
        try manifest.validate()
        guard manifest.applicationSigner.teamIdentifier == expectedTeamIdentifier,
              manifest.installerSigner.teamIdentifier == expectedTeamIdentifier else {
            throw DistributionError.invalidArtifact("release signer team does not match the verifier trust policy")
        }

        var expectedFiles: Set<String> = [
            manifest.archive.fileName,
            manifest.package.fileName,
            manifest.archiveSBOM.fileName,
            manifest.packageSBOM.fileName,
            manifest.provenance.fileName,
            TrustedReleaseLayout.manifestFileName,
            TrustedReleaseLayout.manifestSignatureFileName,
            TrustedReleaseLayout.checksumFileName,
            TrustedReleaseLayout.checksumSignatureFileName,
            TrustedReleaseLayout.provenanceSignatureFileName
        ]
        if requireEvidenceReport {
            expectedFiles.insert(TrustedReleaseLayout.evidenceFileName)
            expectedFiles.insert(TrustedReleaseLayout.evidenceSignatureFileName)
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: releaseDirectory.path)
        guard Set(entries) == expectedFiles, entries.count == expectedFiles.count else {
            throw DistributionError.invalidArtifact("release directory inventory is incomplete or contains unexpected entries")
        }
        for name in entries {
            let url = releaseDirectory.appendingPathComponent(name)
            guard try DistributionFileSystem.isRegularNonSymlink(url),
                  try linkCount(url) == 1 else {
                throw DistributionError.invalidArtifact("release sidecars must be regular single-link files")
            }
            let expectedMode = name == TrustedReleaseLayout.evidenceFileName ? 0o600 : 0o644
            guard try DistributionFileSystem.mode(of: url) == expectedMode else {
                throw DistributionError.invalidArtifact("release sidecar has an unsafe mode: \(name)")
            }
        }

        let manifestDescriptor = try descriptor(manifestURL, cancellation: cancellation)
        let checksumURL = releaseDirectory.appendingPathComponent(TrustedReleaseLayout.checksumFileName)
        let checksumDescriptor = try descriptor(checksumURL, cancellation: cancellation)
        let descriptors = [
            manifest.archive,
            manifest.package,
            manifest.archiveSBOM,
            manifest.packageSBOM,
            manifest.provenance,
            manifestDescriptor
        ].sorted { $0.fileName < $1.fileName }
        for descriptor in descriptors {
            let actual = try self.descriptor(
                releaseDirectory.appendingPathComponent(descriptor.fileName),
                cancellation: cancellation
            )
            guard actual == descriptor else {
                throw DistributionError.checksumMismatch(descriptor.fileName)
            }
        }
        let expectedChecksumText = descriptors.map { "\($0.sha256)  \($0.fileName)" }
            .joined(separator: "\n") + "\n"
        guard try String(contentsOf: checksumURL, encoding: .utf8) == expectedChecksumText else {
            throw DistributionError.invalidArtifact("SHA256SUMS is not the exact sorted release inventory")
        }

        var commands: [HostwrightEvidenceCommand] = []
        try verifyDetachedCMS(
            content: manifestURL,
            signature: releaseDirectory.appendingPathComponent(TrustedReleaseLayout.manifestSignatureFileName),
            signer: manifest.applicationSigner,
            cancellation: cancellation,
            commands: &commands
        )
        try verifyDetachedCMS(
            content: checksumURL,
            signature: releaseDirectory.appendingPathComponent(TrustedReleaseLayout.checksumSignatureFileName),
            signer: manifest.applicationSigner,
            cancellation: cancellation,
            commands: &commands
        )
        let provenanceURL = releaseDirectory.appendingPathComponent(manifest.provenance.fileName)
        try verifyDetachedCMS(
            content: provenanceURL,
            signature: releaseDirectory.appendingPathComponent(TrustedReleaseLayout.provenanceSignatureFileName),
            signer: manifest.applicationSigner,
            cancellation: cancellation,
            commands: &commands
        )

        let payloadManifest = DistributionArtifactManifest(
            artifactID: manifest.artifactID,
            packageVersion: manifest.packageVersion,
            sourceCommit: manifest.sourceCommit,
            sourceDirty: false,
            architecture: manifest.architecture,
            createdAt: manifest.createdAt,
            files: manifest.payloadFiles
        )
        try payloadManifest.validate()
        let archiveSBOM = try DistributionJSON.decode(
            DistributionSPDXDocument.self,
            from: releaseDirectory.appendingPathComponent(manifest.archiveSBOM.fileName)
        )
        try archiveSBOM.validate(
            manifest: payloadManifest,
            archive: manifest.archive,
            expectedCreator: "Tool: hostwright-dist-2"
        )
        let packageSBOM = try DistributionJSON.decode(
            DistributionSPDXDocument.self,
            from: releaseDirectory.appendingPathComponent(manifest.packageSBOM.fileName)
        )
        try packageSBOM.validate(
            manifest: payloadManifest,
            archive: manifest.package,
            expectedCreator: "Tool: hostwright-dist-2"
        )
        let provenance = try DistributionJSON.decode(
            TrustedReleaseProvenanceStatement.self,
            from: provenanceURL
        )
        try provenance.validate(manifest: manifest)

        let verificationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-dist-release-verify-\(UUID().uuidString)", isDirectory: true)
        try DistributionTemporaryPathPolicy.validate(verificationRoot, role: "trusted release verification")
        try DistributionFileSystem.createExclusiveDirectory(verificationRoot)
        var verificationRemoved = false
        defer {
            if !verificationRemoved, DistributionFileSystem.entryExists(verificationRoot) {
                try? DistributionFileSystem.removeOwnedTemporaryItem(verificationRoot)
            }
        }
        try verifyArchive(
            manifest: manifest,
            releaseDirectory: releaseDirectory,
            extractionRoot: verificationRoot.appendingPathComponent("archive", isDirectory: true),
            cancellation: cancellation,
            commands: &commands
        )
        try verifyPackage(
            manifest: manifest,
            releaseDirectory: releaseDirectory,
            expansionRoot: verificationRoot.appendingPathComponent("package", isDirectory: true),
            cancellation: cancellation,
            commands: &commands
        )

        if requireEvidenceReport {
            let evidenceURL = releaseDirectory.appendingPathComponent(TrustedReleaseLayout.evidenceFileName)
            try verifyDetachedCMS(
                content: evidenceURL,
                signature: releaseDirectory.appendingPathComponent(
                    TrustedReleaseLayout.evidenceSignatureFileName
                ),
                signer: manifest.applicationSigner,
                cancellation: cancellation,
                commands: &commands
            )
            let report = try DistributionJSON.decode(
                TrustedReleaseReport.self,
                from: evidenceURL
            )
            try report.validate()
            let expectedBuildMetadata = TrustedReleaseBuildMetadata(
                externalSwiftPMDependencies: [],
                packageLicenseSPDX: "Apache-2.0",
                reproducibilityBuildCount: 2,
                byteIdenticalUnsignedPayloads: true,
                toolVersions: report.evidence.environment.toolVersions
            )
            try provenance.validate(
                manifest: manifest,
                expectedBuildMetadata: expectedBuildMetadata
            )
            let actualManifestSignature = try descriptor(
                releaseDirectory.appendingPathComponent(TrustedReleaseLayout.manifestSignatureFileName),
                cancellation: cancellation
            )
            let actualChecksumSignature = try descriptor(
                releaseDirectory.appendingPathComponent(TrustedReleaseLayout.checksumSignatureFileName),
                cancellation: cancellation
            )
            let actualProvenanceSignature = try descriptor(
                releaseDirectory.appendingPathComponent(TrustedReleaseLayout.provenanceSignatureFileName),
                cancellation: cancellation
            )
            guard report.manifest == manifest,
                  report.manifestDescriptor == manifestDescriptor,
                  report.checksumDescriptor == checksumDescriptor,
                  report.manifestSignature == actualManifestSignature,
                  report.checksumSignature == actualChecksumSignature,
                  report.provenanceSignature == actualProvenanceSignature else {
                throw DistributionError.invalidArtifact("release evidence report is not bound to the verified sidecars")
            }
        }
        try DistributionFileSystem.removeOwnedTemporaryItem(verificationRoot)
        verificationRemoved = true
        commands.append(HostwrightEvidenceCommand(
            command: "remove exact trusted release verification root",
            exitCode: 0,
            durationMilliseconds: 0
        ))
        return TrustedReleaseVerificationResult(
            manifest: manifest,
            commands: commands,
            cleanup: HostwrightEvidenceCleanup(
                status: .succeeded,
                exactResourceIdentifiers: [verificationRoot.path],
                message: "The exact private trusted-release verification root was removed."
            )
        )
    }

    public func verifyForInstallation(
        releaseDirectory: URL,
        expectedTeamIdentifier: String,
        extractionDirectory: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> VerifiedTrustedReleaseArtifact {
        let verified = try verify(
            releaseDirectory: releaseDirectory,
            expectedTeamIdentifier: expectedTeamIdentifier,
            requireEvidenceReport: true,
            cancellation: cancellation
        )
        try DistributionTemporaryPathPolicy.validate(
            extractionDirectory,
            role: "trusted release lifecycle extraction"
        )
        guard !DistributionFileSystem.entryExists(extractionDirectory) else {
            throw DistributionError.existingOutput(extractionDirectory.path)
        }
        var commands = verified.commands
        var retained = false
        defer {
            if !retained, DistributionFileSystem.entryExists(extractionDirectory) {
                try? DistributionFileSystem.removeOwnedTemporaryItem(extractionDirectory)
            }
        }
        try verifyArchive(
            manifest: verified.manifest,
            releaseDirectory: releaseDirectory,
            extractionRoot: extractionDirectory,
            cancellation: cancellation,
            commands: &commands
        )
        let payloadManifest = DistributionArtifactManifest(
            artifactID: verified.manifest.artifactID,
            packageVersion: verified.manifest.packageVersion,
            sourceCommit: verified.manifest.sourceCommit,
            sourceDirty: false,
            architecture: verified.manifest.architecture,
            createdAt: verified.manifest.createdAt,
            files: verified.manifest.payloadFiles
        )
        try payloadManifest.validate()
        let extractedRoot = extractionDirectory.appendingPathComponent(
            verified.manifest.artifactID,
            isDirectory: true
        )
        retained = true
        return VerifiedTrustedReleaseArtifact(
            releaseDirectory: releaseDirectory,
            extractedRoot: extractedRoot,
            manifest: payloadManifest,
            trustedManifest: verified.manifest
        )
    }

    private func verifyArchive(
        manifest: TrustedReleaseManifest,
        releaseDirectory: URL,
        extractionRoot: URL,
        cancellation: SecureSubprocessCancellation,
        commands: inout [HostwrightEvidenceCommand]
    ) throws {
        let archive = releaseDirectory.appendingPathComponent(manifest.archive.fileName)
        let expectedEntries = Set(
            (manifest.payloadFiles.map(\.path) + [DistributionLayout.manifestFileName])
                .map { "\(manifest.artifactID)/\($0)" }
        )
        let table = try runner.run(
            executablePath: "/usr/bin/tar",
            arguments: ["-tf", archive.path],
            label: "inspect trusted ZIP paths",
            timeoutSeconds: 60,
            cancellation: cancellation
        )
        let actualEntries = table.standardOutput.split(separator: "\n").map(String.init)
        guard Set(actualEntries) == expectedEntries,
              actualEntries.count == expectedEntries.count else {
            throw DistributionError.invalidArtifact("trusted ZIP path inventory is unsafe or incomplete")
        }
        commands.append(record("inspect trusted ZIP paths", table))
        let types = try runner.run(
            executablePath: "/usr/bin/tar",
            arguments: ["-tvf", archive.path],
            label: "inspect trusted ZIP entry types",
            timeoutSeconds: 60,
            cancellation: cancellation
        )
        let typeLines = types.standardOutput.split(separator: "\n")
        guard typeLines.count == expectedEntries.count,
              typeLines.allSatisfy({ $0.first == "-" }) else {
            throw DistributionError.invalidArtifact("trusted ZIP contains a link, directory entry, or special file")
        }
        commands.append(record("inspect trusted ZIP entry types", types))
        try DistributionFileSystem.createExclusiveDirectory(extractionRoot)
        let extraction = try runner.run(
            executablePath: "/usr/bin/tar",
            arguments: ["-xf", archive.path, "-C", extractionRoot.path],
            label: "extract trusted ZIP into a new private directory",
            timeoutSeconds: 120,
            cancellation: cancellation
        )
        commands.append(record("extract trusted ZIP into a new private directory", extraction))
        let root = extractionRoot.appendingPathComponent(manifest.artifactID, isDirectory: true)
        guard try DistributionFileSystem.isDirectoryNonSymlink(root) else {
            throw DistributionError.invalidArtifact("trusted ZIP did not extract its exact artifact root")
        }
        let internalManifest = try DistributionJSON.decode(
            DistributionArtifactManifest.self,
            from: root.appendingPathComponent(DistributionLayout.manifestFileName)
        )
        let expectedInternal = DistributionArtifactManifest(
            artifactID: manifest.artifactID,
            packageVersion: manifest.packageVersion,
            sourceCommit: manifest.sourceCommit,
            sourceDirty: false,
            architecture: manifest.architecture,
            createdAt: manifest.createdAt,
            files: manifest.payloadFiles
        )
        guard internalManifest == expectedInternal else {
            throw DistributionError.invalidArtifact("trusted ZIP internal manifest differs from the signed release manifest")
        }
        try verifyPayloadFiles(manifest.payloadFiles, under: root, cancellation: cancellation)
        try verifyExecutableTrust(
            root: root,
            signer: manifest.applicationSigner,
            cancellation: cancellation,
            commands: &commands
        )
    }

    private func verifyPackage(
        manifest: TrustedReleaseManifest,
        releaseDirectory: URL,
        expansionRoot: URL,
        cancellation: SecureSubprocessCancellation,
        commands: inout [HostwrightEvidenceCommand]
    ) throws {
        let package = releaseDirectory.appendingPathComponent(manifest.package.fileName)
        let signature = try runner.run(
            executablePath: "/usr/sbin/pkgutil",
            arguments: ["--check-signature", package.path],
            label: "verify trusted package signature",
            timeoutSeconds: 60,
            cancellation: cancellation
        )
        let signatureText = signature.standardOutput + signature.standardError
        guard signatureText.contains(manifest.installerSigner.commonName) else {
            throw DistributionError.invalidArtifact("trusted package signer differs from the release manifest")
        }
        commands.append(record("verify trusted package signature", signature))
        let staple = try runner.run(
            executablePath: "/usr/bin/xcrun",
            arguments: ["stapler", "validate", "-v", package.path],
            label: "validate trusted package staple",
            timeoutSeconds: 300,
            cancellation: cancellation
        )
        commands.append(record("validate trusted package staple", staple))
        let gatekeeper = try runner.run(
            executablePath: "/usr/sbin/spctl",
            arguments: ["--assess", "--verbose=4", "--type", "install", package.path],
            label: "assess trusted package with Gatekeeper",
            timeoutSeconds: 60,
            cancellation: cancellation
        )
        guard (gatekeeper.standardOutput + gatekeeper.standardError)
            .contains("source=Notarized Developer ID") else {
            throw DistributionError.invalidArtifact("Gatekeeper did not accept the trusted package as notarized")
        }
        commands.append(record("assess trusted package with Gatekeeper", gatekeeper))
        let expansion = try runner.run(
            executablePath: "/usr/sbin/pkgutil",
            arguments: ["--expand-full", package.path, expansionRoot.path],
            label: "expand trusted package into a new private directory",
            timeoutSeconds: 120,
            cancellation: cancellation
        )
        commands.append(record("expand trusted package into a new private directory", expansion))
        let payloadRoot = expansionRoot.appendingPathComponent("Payload", isDirectory: true)
        guard try DistributionFileSystem.isDirectoryNonSymlink(payloadRoot) else {
            throw DistributionError.invalidArtifact("expanded trusted package has no exact Payload root")
        }
        let expected = Dictionary(uniqueKeysWithValues: manifest.payloadFiles.map {
            (packageInstalledPath(for: $0.path), $0)
        })
        let actualFiles = try regularFileInventory(payloadRoot)
        guard Set(actualFiles) == Set(expected.keys), actualFiles.count == expected.count else {
            throw DistributionError.invalidArtifact("trusted package payload contains unexpected or missing files")
        }
        for (path, file) in expected {
            guard !cancellation.isCancelled else {
                throw DistributionError.commandCancelled("verify trusted package payload")
            }
            let url = payloadRoot.appendingPathComponent(path)
            guard try DistributionHash.sha256(fileURL: url, cancellation: cancellation) == file.sha256,
                  try DistributionFileSystem.size(of: url) == file.sizeBytes,
                  try DistributionFileSystem.mode(of: url) == file.mode,
                  try linkCount(url) == 1 else {
                throw DistributionError.checksumMismatch(path)
            }
        }
    }

    private func verifyPayloadFiles(
        _ files: [DistributionFileRecord],
        under root: URL,
        cancellation: SecureSubprocessCancellation
    ) throws {
        let actualFiles = try regularFileInventory(root)
        let expectedPaths = Set(files.map(\.path) + [DistributionLayout.manifestFileName])
        guard Set(actualFiles) == expectedPaths, actualFiles.count == expectedPaths.count else {
            throw DistributionError.invalidArtifact("trusted archive extraction contains unexpected or missing files")
        }
        for file in files {
            guard !cancellation.isCancelled else {
                throw DistributionError.commandCancelled("verify trusted archive payload")
            }
            let url = root.appendingPathComponent(file.path)
            guard try DistributionHash.sha256(fileURL: url, cancellation: cancellation) == file.sha256,
                  try DistributionFileSystem.size(of: url) == file.sizeBytes,
                  try DistributionFileSystem.mode(of: url) == file.mode,
                  try linkCount(url) == 1 else {
                throw DistributionError.checksumMismatch(file.path)
            }
        }
    }

    private func verifyExecutableTrust(
        root: URL,
        signer: TrustedReleaseIdentity,
        cancellation: SecureSubprocessCancellation,
        commands: inout [HostwrightEvidenceCommand]
    ) throws {
        for relativePath in DistributionLayout.shippedBinaryPaths {
            let binary = root.appendingPathComponent(relativePath)
            let signature = try runner.run(
                executablePath: "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "--verbose=4", binary.path],
                label: "verify extracted Developer ID signature",
                timeoutSeconds: 60,
                cancellation: cancellation
            )
            commands.append(record("verify extracted Developer ID signature for \(binary.lastPathComponent)", signature))
            let details = try runner.run(
                executablePath: "/usr/bin/codesign",
                arguments: ["--display", "--verbose=4", binary.path],
                label: "inspect extracted Developer ID signature",
                timeoutSeconds: 60,
                cancellation: cancellation
            )
            let detailText = details.standardOutput + details.standardError
            guard detailText.contains("Authority=\(signer.commonName)"),
                  detailText.contains("TeamIdentifier=\(signer.teamIdentifier)"),
                  detailText.contains("runtime") else {
                throw DistributionError.invalidArtifact("extracted executable signer or hardened-runtime flags differ")
            }
            commands.append(record("inspect extracted Developer ID signature for \(binary.lastPathComponent)", details))
            let gatekeeper = try runner.run(
                executablePath: "/usr/sbin/spctl",
                arguments: ["--assess", "--verbose=4", "--type", "execute", binary.path],
                label: "assess extracted executable with Gatekeeper",
                timeoutSeconds: 60,
                cancellation: cancellation
            )
            guard (gatekeeper.standardOutput + gatekeeper.standardError)
                .contains("source=Notarized Developer ID") else {
                throw DistributionError.invalidArtifact("Gatekeeper did not accept an extracted executable as notarized")
            }
            commands.append(record("assess extracted \(binary.lastPathComponent) with Gatekeeper", gatekeeper))
        }
    }

    private func verifyDetachedCMS(
        content: URL,
        signature: URL,
        signer: TrustedReleaseIdentity,
        cancellation: SecureSubprocessCancellation,
        commands: inout [HostwrightEvidenceCommand]
    ) throws {
        let result = try runner.run(
            executablePath: "/usr/bin/security",
            arguments: [
                "cms", "-D", "-i", signature.path,
                "-c", content.path, "-n", "-u", "6"
            ],
            label: "verify detached CMS signature for \(content.lastPathComponent)",
            timeoutSeconds: 60,
            cancellation: cancellation
        )
        let observedSigner = try TrustedCMSSignerInspector.inspect(
            signature: signature,
            detachedContent: content
        )
        guard observedSigner.sha1Fingerprint == signer.sha1Fingerprint,
              observedSigner.commonName == signer.commonName else {
            throw DistributionError.invalidArtifact("detached CMS signer does not match the exact release identity")
        }
        commands.append(record("verify detached CMS signature for \(content.lastPathComponent)", result))
    }

    private func regularFileInventory(_ root: URL) throws -> [String] {
        let entries = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        var files: [String] = []
        for path in entries {
            guard DistributionPathPolicy.isSafeRelativePath(path) else {
                throw DistributionError.invalidArtifact("expanded release contains an unsafe relative path")
            }
            let url = root.appendingPathComponent(path)
            if try DistributionFileSystem.isRegularNonSymlink(url) {
                files.append(path)
            } else if try DistributionFileSystem.isDirectoryNonSymlink(url) {
                continue
            } else {
                throw DistributionError.invalidArtifact("expanded release contains a link or special file")
            }
        }
        return files
    }

    private func packageInstalledPath(for archivePath: String) -> String {
        "usr/local/\(archivePath)"
    }

    private func linkCount(_ url: URL) throws -> UInt64 {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return UInt64(metadata.st_nlink)
    }

    private func descriptor(
        _ url: URL,
        cancellation: SecureSubprocessCancellation
    ) throws -> DistributionArtifactDescriptor {
        DistributionArtifactDescriptor(
            fileName: url.lastPathComponent,
            sha256: try DistributionHash.sha256(fileURL: url, cancellation: cancellation),
            sizeBytes: try DistributionFileSystem.size(of: url)
        )
    }

    private func record(_ label: String, _ result: DistributionCommandResult) -> HostwrightEvidenceCommand {
        HostwrightEvidenceCommand(
            command: label,
            exitCode: Int(result.exitStatus),
            durationMilliseconds: result.durationMilliseconds
        )
    }
}
