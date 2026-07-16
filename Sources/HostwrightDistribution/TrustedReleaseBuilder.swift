import Foundation
import HostwrightCore

public struct TrustedReleaseBuildRequest: Sendable {
    public let sourceRoot: URL
    public let outputDirectory: URL
    public let expectedCommit: String
    public let expectedVersion: String
    public let releaseTag: String
    public let applicationIdentityFingerprint: String
    public let installerIdentityFingerprint: String
    public let teamIdentifier: String
    public let notaryKeychainProfile: String

    public init(
        sourceRoot: URL,
        outputDirectory: URL,
        expectedCommit: String,
        expectedVersion: String,
        releaseTag: String,
        applicationIdentityFingerprint: String,
        installerIdentityFingerprint: String,
        teamIdentifier: String,
        notaryKeychainProfile: String
    ) {
        self.sourceRoot = sourceRoot
        self.outputDirectory = outputDirectory
        self.expectedCommit = expectedCommit
        self.expectedVersion = expectedVersion
        self.releaseTag = releaseTag
        self.applicationIdentityFingerprint = applicationIdentityFingerprint
        self.installerIdentityFingerprint = installerIdentityFingerprint
        self.teamIdentifier = teamIdentifier
        self.notaryKeychainProfile = notaryKeychainProfile
    }

    public func validate() throws {
        guard expectedCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              expectedCommit != String(repeating: "0", count: 40),
              expectedVersion.range(
                of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$",
                options: .regularExpression
              ) != nil,
              releaseTag == "v\(expectedVersion)",
              applicationIdentityFingerprint.range(
                of: "^[A-F0-9]{40}$",
                options: .regularExpression
              ) != nil,
              installerIdentityFingerprint.range(
                of: "^[A-F0-9]{40}$",
                options: .regularExpression
              ) != nil,
              applicationIdentityFingerprint != installerIdentityFingerprint,
              teamIdentifier.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              notaryKeychainProfile.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
                options: .regularExpression
              ) != nil,
              sourceRoot.path.hasPrefix("/"),
              outputDirectory.path.hasPrefix("/") else {
            throw DistributionError.invalidArguments("Trusted release inputs are incomplete or not exact immutable identifiers.")
        }
        _ = try DistributionPackageVersion.make(from: expectedVersion)
        guard try DistributionFileSystem.isDirectoryNonSymlink(sourceRoot),
              try DistributionFileSystem.isRegularNonSymlink(sourceRoot.appendingPathComponent("Package.swift")),
              try DistributionFileSystem.isDirectoryNonSymlink(
                outputDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
              ),
              !DistributionFileSystem.entryExists(outputDirectory) else {
            throw DistributionError.invalidArguments("Trusted release source and output paths must be safe, existing-parent, non-symlink paths.")
        }
    }
}

public struct TrustedReleaseBuilder: Sendable {
    private let runner: DistributionProcessRunner
    private let identityResolver: DeveloperIDIdentityResolver

    public init(runner: DistributionProcessRunner = DistributionProcessRunner()) {
        self.runner = runner
        self.identityResolver = DeveloperIDIdentityResolver(runner: runner)
    }

    public func build(
        _ request: TrustedReleaseBuildRequest,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> TrustedReleaseReport {
        try request.validate()
        guard !cancellation.isCancelled else {
            throw DistributionError.commandCancelled("trusted release preflight")
        }
        var commands: [HostwrightEvidenceCommand] = []
        let applicationResolution = try identityResolver.resolve(
            fingerprint: request.applicationIdentityFingerprint,
            kind: .application,
            expectedTeamIdentifier: request.teamIdentifier,
            cancellation: cancellation
        )
        commands.append(record("resolve exact Developer ID Application identity", applicationResolution.command))
        let installerResolution = try identityResolver.resolve(
            fingerprint: request.installerIdentityFingerprint,
            kind: .installer,
            expectedTeamIdentifier: request.teamIdentifier,
            cancellation: cancellation
        )
        commands.append(record("resolve exact Developer ID Installer identity", installerResolution.command))

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-dist-release-\(UUID().uuidString)", isDirectory: true)
        try DistributionTemporaryPathPolicy.validate(scratch, role: "trusted release scratch")
        try DistributionFileSystem.createExclusiveDirectory(scratch)
        var scratchRemoved = false
        defer {
            if !scratchRemoved, DistributionFileSystem.entryExists(scratch) {
                try? DistributionFileSystem.removeOwnedTemporaryItem(scratch)
            }
        }

        let outputParent = request.outputDirectory.deletingLastPathComponent()
        let stagedOutput = outputParent.appendingPathComponent(
            ".hostwright-dist-release-\(UUID().uuidString)",
            isDirectory: true
        )
        try DistributionFileSystem.createExclusiveDirectory(stagedOutput)
        var outputPublished = false
        defer {
            if !outputPublished, DistributionFileSystem.entryExists(stagedOutput) {
                try? FileManager.default.removeItem(at: stagedOutput)
            }
        }

        let firstOutput = scratch.appendingPathComponent("unsigned-first", isDirectory: true)
        let secondOutput = scratch.appendingPathComponent("unsigned-second", isDirectory: true)
        let cleanBuilder = DistributionCleanBuilder(runner: runner)
        let firstBuild = try cleanBuilder.buildWithDependencyInventory(
            sourceRoot: request.sourceRoot,
            outputDirectory: firstOutput,
            expectedCommit: request.expectedCommit,
            cancellation: cancellation
        )
        guard !cancellation.isCancelled else {
            throw DistributionError.commandCancelled("trusted release reproducibility build")
        }
        let secondBuild = try cleanBuilder.buildWithDependencyInventory(
            sourceRoot: request.sourceRoot,
            outputDirectory: secondOutput,
            expectedCommit: request.expectedCommit,
            cancellation: cancellation
        )
        let firstReport = firstBuild.report
        let secondReport = secondBuild.report
        let cleanBuilds = [firstBuild, secondBuild]
        commands.append(contentsOf: firstReport.evidence.commands)
        commands.append(contentsOf: secondReport.evidence.commands)
        let dependencyInventoriesMatch = cleanBuilds.dropFirst().allSatisfy {
            $0.externalSwiftPMDependencies == firstBuild.externalSwiftPMDependencies
        }
        let toolVersions = try requireMatchingToolVersions(
            cleanBuilds.map { $0.report.evidence.environment.toolVersions }
        )
        let unsignedPayloadsByteIdentical = cleanBuilds.dropFirst().allSatisfy {
            $0.report.manifest.files == firstReport.manifest.files
        }
        guard firstReport.manifest.packageVersion == request.expectedVersion,
              secondReport.manifest.packageVersion == request.expectedVersion,
              firstReport.manifest.sourceCommit == request.expectedCommit,
              secondReport.manifest.sourceCommit == request.expectedCommit,
              dependencyInventoriesMatch,
              unsignedPayloadsByteIdentical else {
            throw DistributionError.invalidArtifact("two isolated clean builds did not produce identical payload bytes")
        }

        let firstExtraction = scratch.appendingPathComponent("hostwright-dist-release-first-extract", isDirectory: true)
        let secondExtraction = scratch.appendingPathComponent("hostwright-dist-release-second-extract", isDirectory: true)
        let firstVerified = try DistributionVerifier(runner: runner).verify(
            distributionDirectory: firstOutput,
            extractionDirectory: firstExtraction,
            cancellation: cancellation
        )
        let secondVerified = try DistributionVerifier(runner: runner).verify(
            distributionDirectory: secondOutput,
            extractionDirectory: secondExtraction,
            cancellation: cancellation
        )
        let verifiedPayloadsByteIdentical = firstVerified.manifest.files == secondVerified.manifest.files
        guard verifiedPayloadsByteIdentical else {
            throw DistributionError.invalidArtifact("verified reproducibility payloads differ")
        }
        let buildMetadata = TrustedReleaseBuildMetadata(
            externalSwiftPMDependencies: firstBuild.externalSwiftPMDependencies,
            packageLicenseSPDX: "Apache-2.0",
            reproducibilityBuildCount: cleanBuilds.count,
            byteIdenticalUnsignedPayloads: unsignedPayloadsByteIdentical && verifiedPayloadsByteIdentical,
            toolVersions: toolVersions
        )
        try buildMetadata.validate()
        commands.append(HostwrightEvidenceCommand(
            command: "compare two isolated verified release payloads",
            exitCode: 0,
            durationMilliseconds: 0
        ))

        let artifactID = "hostwright-\(request.expectedVersion)-macos-arm64-\(request.expectedCommit.prefix(12))"
        let signedRoot = stagedOutput.appendingPathComponent(artifactID, isDirectory: true)
        try FileManager.default.createDirectory(at: signedRoot, withIntermediateDirectories: false)
        for file in firstVerified.manifest.files {
            try DistributionFileSystem.copyRegularFile(
                from: firstVerified.extractedRoot.appendingPathComponent(file.path),
                to: signedRoot.appendingPathComponent(file.path),
                mode: file.mode
            )
        }

        for binaryPath in shippedBinaryPaths {
            let binary = signedRoot.appendingPathComponent(binaryPath)
            let sign = try runner.run(
                executablePath: "/usr/bin/codesign",
                arguments: [
                    "--force", "--options", "runtime", "--timestamp",
                    "--sign", applicationResolution.identity.sha1Fingerprint,
                    binary.path
                ],
                label: "Developer ID sign \(binary.lastPathComponent)",
                timeoutSeconds: 300,
                cancellation: cancellation
            )
            commands.append(record("Developer ID sign \(binary.lastPathComponent)", sign))
            let verify = try runner.run(
                executablePath: "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "--verbose=4", binary.path],
                label: "verify Developer ID signature for \(binary.lastPathComponent)",
                timeoutSeconds: 30,
                cancellation: cancellation
            )
            commands.append(record("verify Developer ID signature for \(binary.lastPathComponent)", verify))
        }

        let createdAt = DistributionTimestamp.string(Date())
        let signedFiles = try DistributionLayout.payloadModes.keys.sorted().map { path in
            let file = signedRoot.appendingPathComponent(path)
            return DistributionFileRecord(
                path: path,
                sha256: try DistributionHash.sha256(fileURL: file, cancellation: cancellation),
                sizeBytes: try DistributionFileSystem.size(of: file),
                mode: try DistributionFileSystem.mode(of: file)
            )
        }
        let payloadManifest = DistributionArtifactManifest(
            artifactID: artifactID,
            packageVersion: request.expectedVersion,
            sourceCommit: request.expectedCommit,
            sourceDirty: false,
            architecture: "arm64",
            createdAt: createdAt,
            files: signedFiles
        )
        try payloadManifest.validate()
        try DistributionFileSystem.writeNewFile(
            try DistributionJSON.encode(payloadManifest),
            to: signedRoot.appendingPathComponent(DistributionLayout.manifestFileName),
            mode: 0o644
        )

        let archiveURL = stagedOutput.appendingPathComponent(
            TrustedReleaseLayout.archiveFileName(artifactID: artifactID)
        )
        let archiveEntries = (signedFiles.map(\.path) + [DistributionLayout.manifestFileName])
            .map { "\(artifactID)/\($0)" }
            .sorted()
        let archiveResult = try runner.run(
            executablePath: "/usr/bin/zip",
            arguments: ["-X", "-q", archiveURL.path] + archiveEntries,
            workingDirectory: stagedOutput,
            label: "create exact signed ZIP archive",
            timeoutSeconds: 300,
            cancellation: cancellation
        )
        commands.append(record("create exact signed ZIP archive", archiveResult))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: archiveURL.path)
        let archiveNotaryResult = try notarize(
            archiveURL,
            profile: request.notaryKeychainProfile,
            label: "notarize signed archive",
            cancellation: cancellation,
            commands: &commands
        )
        let archiveGatekeeperSource = try assessArchiveBinaries(
            signedRoot,
            cancellation: cancellation,
            commands: &commands
        )
        let archiveDescriptor = try descriptor(archiveURL, cancellation: cancellation)
        let archiveNotarization = try NotarytoolOutputParser.acceptedRecord(
            output: archiveNotaryResult.standardOutput,
            artifactFileName: archiveDescriptor.fileName,
            attachment: .online,
            gatekeeperSource: archiveGatekeeperSource
        )

        let packageRoot = scratch.appendingPathComponent("hostwright-dist-release-package-root", isDirectory: true)
        try DistributionFileSystem.createExclusiveDirectory(packageRoot)
        for file in signedFiles {
            let installedPath = packageInstalledPath(for: file.path)
            try DistributionFileSystem.copyRegularFile(
                from: signedRoot.appendingPathComponent(file.path),
                to: packageRoot.appendingPathComponent(installedPath),
                mode: file.mode
            )
        }
        let packageStagingRoot = packageRoot.appendingPathComponent(
            packageStagingRelativePath,
            isDirectory: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: packageStagingRoot.path
        )
        try DistributionFileSystem.writeNewFile(
            try DistributionJSON.encode(payloadManifest),
            to: packageStagingRoot.appendingPathComponent(DistributionLayout.manifestFileName),
            mode: 0o644
        )
        let installerPackageVersion = try DistributionPackageVersion.make(
            from: request.expectedVersion
        )
        let packageScripts = scratch.appendingPathComponent(
            "hostwright-dist-release-package-scripts",
            isDirectory: true
        )
        try DistributionFileSystem.createExclusiveDirectory(packageScripts)
        try DistributionFileSystem.writeNewFile(
            Data(DistributionPackageScripts.postinstall(
                packageVersion: installerPackageVersion,
                teamIdentifier: request.teamIdentifier
            ).utf8),
            to: packageScripts.appendingPathComponent("postinstall"),
            mode: 0o755
        )
        let packageURL = stagedOutput.appendingPathComponent(
            TrustedReleaseLayout.packageFileName(artifactID: artifactID)
        )
        let packageResult = try runner.run(
            executablePath: "/usr/bin/pkgbuild",
            arguments: [
                "--root", packageRoot.path,
                "--identifier", "dev.hostwright.cli",
                "--version", installerPackageVersion,
                "--install-location", "/",
                "--scripts", packageScripts.path,
                "--ownership", "recommended",
                "--sign", installerResolution.identity.sha1Fingerprint,
                packageURL.path
            ],
            label: "build signed flat installer package",
            timeoutSeconds: 300,
            cancellation: cancellation
        )
        commands.append(record("build signed flat installer package", packageResult))
        let packageSignature = try runner.run(
            executablePath: "/usr/sbin/pkgutil",
            arguments: ["--check-signature", packageURL.path],
            label: "verify Developer ID Installer signature",
            timeoutSeconds: 30,
            cancellation: cancellation
        )
        guard (packageSignature.standardOutput + packageSignature.standardError)
            .contains(installerResolution.identity.commonName) else {
            throw DistributionError.invalidArtifact("package signature does not use the selected Developer ID Installer identity")
        }
        commands.append(record("verify Developer ID Installer signature", packageSignature))
        let packageNotaryResult = try notarize(
            packageURL,
            profile: request.notaryKeychainProfile,
            label: "notarize signed package",
            cancellation: cancellation,
            commands: &commands
        )
        let staple = try runner.run(
            executablePath: "/usr/bin/xcrun",
            arguments: ["stapler", "staple", "-v", packageURL.path],
            label: "staple package notarization ticket",
            timeoutSeconds: 300,
            cancellation: cancellation
        )
        commands.append(record("staple package notarization ticket", staple))
        let stapleValidation = try runner.run(
            executablePath: "/usr/bin/xcrun",
            arguments: ["stapler", "validate", "-v", packageURL.path],
            label: "validate stapled package ticket",
            timeoutSeconds: 300,
            cancellation: cancellation
        )
        commands.append(record("validate stapled package ticket", stapleValidation))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: packageURL.path)
        let packageGatekeeper = try runner.run(
            executablePath: "/usr/sbin/spctl",
            arguments: ["--assess", "--verbose=4", "--type", "install", packageURL.path],
            label: "assess package with Gatekeeper",
            timeoutSeconds: 60,
            cancellation: cancellation
        )
        let packageGatekeeperSource = try requireNotarizedGatekeeperSource(packageGatekeeper)
        commands.append(record("assess package with Gatekeeper", packageGatekeeper))
        let packageDescriptor = try descriptor(packageURL, cancellation: cancellation)
        let packageNotarization = try NotarytoolOutputParser.acceptedRecord(
            output: packageNotaryResult.standardOutput,
            artifactFileName: packageDescriptor.fileName,
            attachment: .stapled,
            gatekeeperSource: packageGatekeeperSource
        )

        let archiveSBOMURL = stagedOutput.appendingPathComponent(
            TrustedReleaseLayout.archiveSBOMFileName(artifactID: artifactID)
        )
        let archiveSBOM = TrustedReleaseSPDXFactory.make(
            payloadManifest: payloadManifest,
            artifact: archiveDescriptor
        )
        try archiveSBOM.validate(
            manifest: payloadManifest,
            archive: archiveDescriptor,
            expectedCreator: "Tool: hostwright-dist-2"
        )
        try DistributionFileSystem.writeNewFile(
            try DistributionJSON.encode(archiveSBOM),
            to: archiveSBOMURL,
            mode: 0o644
        )
        let packageSBOMURL = stagedOutput.appendingPathComponent(
            TrustedReleaseLayout.packageSBOMFileName(artifactID: artifactID)
        )
        let packageSBOM = TrustedReleaseSPDXFactory.make(
            payloadManifest: payloadManifest,
            artifact: packageDescriptor
        )
        try packageSBOM.validate(
            manifest: payloadManifest,
            archive: packageDescriptor,
            expectedCreator: "Tool: hostwright-dist-2"
        )
        try DistributionFileSystem.writeNewFile(
            try DistributionJSON.encode(packageSBOM),
            to: packageSBOMURL,
            mode: 0o644
        )
        let archiveSBOMDescriptor = try descriptor(archiveSBOMURL, cancellation: cancellation)
        let packageSBOMDescriptor = try descriptor(packageSBOMURL, cancellation: cancellation)

        let provenanceURL = stagedOutput.appendingPathComponent(TrustedReleaseLayout.provenanceFileName)
        let provenance = makeProvenance(
            packageVersion: request.expectedVersion,
            sourceCommit: request.expectedCommit,
            archive: archiveDescriptor,
            package: packageDescriptor,
            createdAt: createdAt,
            buildMetadata: buildMetadata
        )
        try DistributionFileSystem.writeNewFile(
            try DistributionJSON.encode(provenance),
            to: provenanceURL,
            mode: 0o644
        )
        let provenanceDescriptor = try descriptor(provenanceURL, cancellation: cancellation)
        let manifest = TrustedReleaseManifest(
            artifactID: artifactID,
            packageVersion: request.expectedVersion,
            releaseTag: request.releaseTag,
            sourceCommit: request.expectedCommit,
            sourceDirty: false,
            minimumMacOSMajorVersion: 26,
            createdAt: createdAt,
            applicationSigner: applicationResolution.identity,
            installerSigner: installerResolution.identity,
            payloadFiles: signedFiles,
            archive: archiveDescriptor,
            package: packageDescriptor,
            archiveSBOM: archiveSBOMDescriptor,
            packageSBOM: packageSBOMDescriptor,
            provenance: provenanceDescriptor,
            archiveNotarization: archiveNotarization,
            packageNotarization: packageNotarization
        )
        try manifest.validate()
        try provenance.validate(
            manifest: manifest,
            expectedBuildMetadata: buildMetadata
        )
        let manifestURL = stagedOutput.appendingPathComponent(TrustedReleaseLayout.manifestFileName)
        try DistributionFileSystem.writeNewFile(
            try DistributionJSON.encode(manifest),
            to: manifestURL,
            mode: 0o644
        )
        let manifestDescriptor = try descriptor(manifestURL, cancellation: cancellation)

        let checksumInputs = [
            archiveDescriptor,
            packageDescriptor,
            archiveSBOMDescriptor,
            packageSBOMDescriptor,
            provenanceDescriptor,
            manifestDescriptor
        ].sorted { $0.fileName < $1.fileName }
        let checksumText = checksumInputs.map { "\($0.sha256)  \($0.fileName)" }
            .joined(separator: "\n") + "\n"
        let checksumURL = stagedOutput.appendingPathComponent(TrustedReleaseLayout.checksumFileName)
        try DistributionFileSystem.writeNewFile(Data(checksumText.utf8), to: checksumURL, mode: 0o644)
        let checksumDescriptor = try descriptor(checksumURL, cancellation: cancellation)

        let manifestSignature = try signDetachedCMS(
            input: manifestURL,
            output: stagedOutput.appendingPathComponent(TrustedReleaseLayout.manifestSignatureFileName),
            identity: applicationResolution.identity,
            cancellation: cancellation,
            commands: &commands
        )
        let checksumSignature = try signDetachedCMS(
            input: checksumURL,
            output: stagedOutput.appendingPathComponent(TrustedReleaseLayout.checksumSignatureFileName),
            identity: applicationResolution.identity,
            cancellation: cancellation,
            commands: &commands
        )
        let provenanceSignature = try signDetachedCMS(
            input: provenanceURL,
            output: stagedOutput.appendingPathComponent(TrustedReleaseLayout.provenanceSignatureFileName),
            identity: applicationResolution.identity,
            cancellation: cancellation,
            commands: &commands
        )

        let preliminaryVerification = try TrustedReleaseVerifier(runner: runner).verify(
            releaseDirectory: stagedOutput,
            expectedTeamIdentifier: request.teamIdentifier,
            requireEvidenceReport: false,
            cancellation: cancellation
        )
        commands.append(contentsOf: preliminaryVerification.commands)

        try DistributionFileSystem.removeOwnedTemporaryItem(scratch)
        scratchRemoved = true
        let stages = passingStages
        let host = DistributionEnvironmentProbe.current
        guard host.unavailableFacts.isEmpty, host.architecture == "arm64" else {
            throw DistributionError.invalidArtifact("trusted release host identity is incomplete or not Apple silicon")
        }
        let evidence = HostwrightEvidenceReport(
            evidenceClass: .distributionArtifact,
            status: .passed,
            recordedAt: DistributionTimestamp.string(Date()),
            source: HostwrightEvidenceSource(commit: request.expectedCommit, dirty: false),
            environment: host.evidenceEnvironment(toolVersions: toolVersions),
            commands: commands,
            rawResults: HostwrightEvidenceCounts(
                executed: stages.count,
                passed: stages.count,
                failed: 0,
                blocked: 0
            ),
            failures: [],
            blockers: [],
            cleanup: HostwrightEvidenceCleanup(
                status: .succeeded,
                exactResourceIdentifiers: [scratch.path],
                message: "Both isolated build trees, verification extractions, and package staging were removed exactly."
            )
        )
        let report = TrustedReleaseReport(
            manifest: manifest,
            manifestDescriptor: manifestDescriptor,
            checksumDescriptor: checksumDescriptor,
            manifestSignature: manifestSignature,
            checksumSignature: checksumSignature,
            provenanceSignature: provenanceSignature,
            stages: stages,
            evidence: evidence
        )
        try report.validate()
        let evidenceURL = stagedOutput.appendingPathComponent(TrustedReleaseLayout.evidenceFileName)
        try DistributionFileSystem.writeNewFile(
            try DistributionJSON.encode(report),
            to: evidenceURL,
            mode: 0o600
        )
        _ = try signDetachedCMS(
            input: evidenceURL,
            output: stagedOutput.appendingPathComponent(TrustedReleaseLayout.evidenceSignatureFileName),
            identity: applicationResolution.identity,
            cancellation: cancellation,
            commands: &commands
        )
        _ = try TrustedReleaseVerifier(runner: runner).verify(
            releaseDirectory: stagedOutput,
            expectedTeamIdentifier: request.teamIdentifier,
            requireEvidenceReport: true,
            cancellation: cancellation
        )
        try FileManager.default.moveItem(at: stagedOutput, to: request.outputDirectory)
        outputPublished = true
        return report
    }

    private var shippedBinaryPaths: [String] { DistributionLayout.shippedBinaryPaths }

    private var passingStages: [DistributionStageRecord] {
        [
            ("source-reproducibility", "Two isolated clean builds produced byte-identical shipped payloads."),
            ("developer-id-application-signing", "All shipped Mach-O executables use hardened-runtime Developer ID signatures."),
            ("archive", "Created one exact signed ZIP archive with a manifest-bound payload."),
            ("archive-notarization", "Apple accepted the exact signed ZIP; its nested executable tickets are available online."),
            ("installer-package", "Built a flat package signed by the exact Developer ID Installer identity."),
            ("package-notarization", "Apple accepted the exact signed installer package."),
            ("package-stapling", "Stapled and independently validated the package ticket for offline Gatekeeper use."),
            ("gatekeeper", "Gatekeeper accepted the archive executables and package as Notarized Developer ID software."),
            ("sbom", "Generated and validated separate SPDX 2.3 inventories for archive and package."),
            ("provenance", "Generated source- and digest-bound in-toto/SLSA-shaped release provenance."),
            ("checksums", "Generated an exact sorted SHA-256 inventory for every release artifact and unsigned sidecar."),
            ("detached-signatures", "Developer ID CMS signatures cover checksums, release manifest, provenance, and release evidence."),
            ("independent-verification", "A fresh extraction verified paths, payload bytes, signatures, tickets, SBOMs, provenance, and checksums.")
        ].map { DistributionStageRecord(identifier: $0.0, status: .passed, detail: $0.1) }
    }

    private func notarize(
        _ artifact: URL,
        profile: String,
        label: String,
        cancellation: SecureSubprocessCancellation,
        commands: inout [HostwrightEvidenceCommand]
    ) throws -> DistributionCommandResult {
        let result = try runner.run(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "notarytool", "submit", artifact.path,
                "--keychain-profile", profile,
                "--wait", "--timeout", "60m",
                "--output-format", "json", "--no-progress"
            ],
            label: label,
            timeoutSeconds: 4_000,
            cancellation: cancellation
        )
        _ = try NotarytoolOutputParser.acceptedRecord(
            output: result.standardOutput,
            artifactFileName: artifact.lastPathComponent,
            attachment: .online
        )
        commands.append(record(label, result))
        return result
    }

    private func assessArchiveBinaries(
        _ signedRoot: URL,
        cancellation: SecureSubprocessCancellation,
        commands: inout [HostwrightEvidenceCommand]
    ) throws -> String {
        for binaryPath in shippedBinaryPaths {
            let binary = signedRoot.appendingPathComponent(binaryPath)
            let result = try runner.run(
                executablePath: "/usr/sbin/spctl",
                arguments: ["--assess", "--verbose=4", "--type", "execute", binary.path],
                label: "assess notarized \(binary.lastPathComponent)",
                timeoutSeconds: 60,
                cancellation: cancellation
            )
            _ = try requireNotarizedGatekeeperSource(result)
            commands.append(record("assess notarized \(binary.lastPathComponent)", result))
        }
        return "Notarized Developer ID"
    }

    private func requireNotarizedGatekeeperSource(_ result: DistributionCommandResult) throws -> String {
        let output = result.standardOutput + result.standardError
        guard output.contains("source=Notarized Developer ID") else {
            throw DistributionError.invalidArtifact("Gatekeeper did not identify the artifact as Notarized Developer ID software")
        }
        return "Notarized Developer ID"
    }

    private func signDetachedCMS(
        input: URL,
        output: URL,
        identity: TrustedReleaseIdentity,
        cancellation: SecureSubprocessCancellation,
        commands: inout [HostwrightEvidenceCommand]
    ) throws -> DistributionArtifactDescriptor {
        let sign = try runner.run(
            executablePath: "/usr/bin/security",
            arguments: [
                "cms", "-S", "-N", identity.commonName,
                "-G", "-H", "SHA256", "-T",
                "-i", input.path, "-o", output.path
            ],
            label: "sign \(input.lastPathComponent) with detached CMS",
            timeoutSeconds: 60,
            cancellation: cancellation
        )
        commands.append(record("sign \(input.lastPathComponent) with detached CMS", sign))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: output.path)
        let verify = try runner.run(
            executablePath: "/usr/bin/security",
            arguments: [
                "cms", "-D", "-i", output.path,
                "-c", input.path, "-n", "-u", "6"
            ],
            label: "verify detached CMS for \(input.lastPathComponent)",
            timeoutSeconds: 60,
            cancellation: cancellation
        )
        commands.append(record("verify detached CMS for \(input.lastPathComponent)", verify))
        return try descriptor(output, cancellation: cancellation)
    }

    private func packageInstalledPath(for archivePath: String) -> String {
        "\(packageStagingRelativePath)/\(archivePath)"
    }

    private var packageStagingRelativePath: String {
        String(DistributionLayout.packageStagingPath.dropFirst())
    }

    private func makeProvenance(
        packageVersion: String,
        sourceCommit: String,
        archive: DistributionArtifactDescriptor,
        package: DistributionArtifactDescriptor,
        createdAt: String,
        buildMetadata: TrustedReleaseBuildMetadata
    ) -> TrustedReleaseProvenanceStatement {
        TrustedReleaseProvenanceStatement(
            statementType: "https://in-toto.io/Statement/v1",
            subject: [archive, package].sorted { $0.fileName < $1.fileName }.map {
                ProvenanceSubject(name: $0.fileName, digest: ["sha256": $0.sha256])
            },
            predicateType: "https://slsa.dev/provenance/v1",
            predicate: DistributionProvenancePredicate(
                buildDefinition: ProvenanceBuildDefinition(
                    buildType: "urn:hostwright:buildtype:swiftpm-developer-id:v1",
                    externalParameters: ProvenanceExternalParameters(
                        configuration: "release",
                        products: DistributionLayout.shippedExecutableNames,
                        platform: "macos",
                        architecture: "arm64"
                    ),
                    internalParameters: ProvenanceInternalParameters(
                        sourceDirty: false,
                        unsigned: false,
                        externalSwiftPMDependencies: buildMetadata.externalSwiftPMDependencies,
                        packageLicenseSPDX: buildMetadata.packageLicenseSPDX,
                        reproducibilityBuildCount: buildMetadata.reproducibilityBuildCount,
                        byteIdenticalUnsignedPayloads: buildMetadata.byteIdenticalUnsignedPayloads,
                        toolVersions: buildMetadata.toolVersions
                    ),
                    resolvedDependencies: [
                        ProvenanceResolvedDependency(
                            uri: "git+https://github.com/hostwright/hostwright.git",
                            digest: ["gitCommit": sourceCommit]
                        )
                    ]
                ),
                runDetails: ProvenanceRunDetails(
                    builder: ProvenanceBuilder(id: "urn:hostwright:builder:release-macos:v1"),
                    metadata: ProvenanceMetadata(
                        invocationId: UUID().uuidString,
                        startedOn: createdAt,
                        finishedOn: DistributionTimestamp.string(Date())
                    )
                )
            )
        )
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

    func requireMatchingToolVersions(_ observedVersions: [[String: String]]) throws -> [String: String] {
        let cleanBuildToolNames = ["git", "notarytool", "swift", "tar"]
        guard observedVersions.count == 2 else {
            throw DistributionError.invalidArtifact(
                "trusted release requires tool-version evidence from exactly two clean builds"
            )
        }
        let observed = try observedVersions.map { versions -> [String: String] in
            guard versions["hostwright-dist"] == "1" else {
                throw DistributionError.invalidArtifact(
                    "clean-build hostwright-dist contract is missing or unsupported"
                )
            }
            var selected: [String: String] = [:]
            for name in cleanBuildToolNames {
                guard let version = versions[name],
                      !version.isEmpty,
                      version.lowercased() != "unavailable" else {
                    throw DistributionError.invalidArtifact(
                        "clean-build tool-version evidence is incomplete"
                    )
                }
                selected[name] = version
            }
            return selected
        }
        guard observed[0] == observed[1] else {
            throw DistributionError.invalidArtifact(
                "clean-build tool versions changed between reproducibility builds"
            )
        }
        var trustedVersions = observed[0]
        trustedVersions["hostwright-dist"] = "2"
        try TrustedReleaseBuildMetadata.validateToolVersions(trustedVersions)
        return trustedVersions
    }

    private func record(_ label: String, _ result: DistributionCommandResult) -> HostwrightEvidenceCommand {
        HostwrightEvidenceCommand(
            command: label,
            exitCode: Int(result.exitStatus),
            durationMilliseconds: result.durationMilliseconds
        )
    }
}
