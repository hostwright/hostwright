import Foundation
import HostwrightCore

public struct DistributionAssemblyRequest: Sendable {
    public let hostwrightBinary: URL
    public let hostwrightDaemonBinary: URL
    public let licenseFile: URL
    public let readmeFile: URL
    public let outputDirectory: URL
    public let packageVersion: String
    public let sourceCommit: String
    public let sourceDirty: Bool
    public let architecture: String
    public let inputStageIdentifier: String
    public let inputStageDetail: String
    public let priorCommands: [HostwrightEvidenceCommand]

    public init(
        hostwrightBinary: URL,
        hostwrightDaemonBinary: URL,
        licenseFile: URL,
        readmeFile: URL,
        outputDirectory: URL,
        packageVersion: String,
        sourceCommit: String,
        sourceDirty: Bool,
        architecture: String,
        inputStageIdentifier: String,
        inputStageDetail: String,
        priorCommands: [HostwrightEvidenceCommand] = []
    ) {
        self.hostwrightBinary = hostwrightBinary
        self.hostwrightDaemonBinary = hostwrightDaemonBinary
        self.licenseFile = licenseFile
        self.readmeFile = readmeFile
        self.outputDirectory = outputDirectory
        self.packageVersion = packageVersion
        self.sourceCommit = sourceCommit
        self.sourceDirty = sourceDirty
        self.architecture = architecture
        self.inputStageIdentifier = inputStageIdentifier
        self.inputStageDetail = inputStageDetail
        self.priorCommands = priorCommands
    }
}

public struct DistributionAssembler: Sendable {
    private let runner: DistributionProcessRunner

    public init(runner: DistributionProcessRunner = DistributionProcessRunner()) {
        self.runner = runner
    }

    public func assemble(_ request: DistributionAssemblyRequest) throws -> DistributionBuildReport {
        guard !FileManager.default.fileExists(atPath: request.outputDirectory.path) else {
            throw DistributionError.existingOutput(request.outputDirectory.path)
        }
        guard request.architecture == "arm64",
              !request.inputStageIdentifier.isEmpty,
              !request.inputStageDetail.isEmpty else {
            throw DistributionError.invalidArguments("Distribution assembly requires an ARM64 input stage.")
        }
        guard (request.inputStageIdentifier == "release-build" && !request.sourceDirty) ||
                (request.inputStageIdentifier == "prebuilt-validation" && request.sourceDirty) else {
            throw DistributionError.invalidArguments(
                "Clean evidence requires the verified release-build path; prebuilt assembly must record source-dirty true."
            )
        }
        guard try DistributionFileSystem.isRegularNonSymlink(request.licenseFile),
              try DistributionFileSystem.isRegularNonSymlink(request.readmeFile) else {
            throw DistributionError.invalidArtifact("License and README inputs must be regular non-symlink files.")
        }

        var commands = request.priorCommands
        try validateBinary(
            request.hostwrightBinary,
            versionArguments: ["--version"],
            expectedVersion: request.packageVersion,
            label: "validate hostwright version",
            commands: &commands
        )
        try validateBinary(
            request.hostwrightDaemonBinary,
            versionArguments: ["--version"],
            expectedVersion: request.packageVersion,
            label: "validate hostwrightd version",
            commands: &commands
        )
        try validateArchitecture(request.hostwrightBinary, label: "validate hostwright architecture", commands: &commands)
        try validateArchitecture(request.hostwrightDaemonBinary, label: "validate hostwrightd architecture", commands: &commands)

        let timestamp = DistributionTimestamp.string(Date())
        let artifactID = "hostwright-\(request.packageVersion)-macos-arm64-\(request.sourceCommit.prefix(12))"
        let parent = request.outputDirectory.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw DistributionError.invalidArguments("Distribution output parent directory does not exist.")
        }
        let temporaryOutput = parent.appendingPathComponent(".hostwright-dist-\(UUID().uuidString)", isDirectory: true)
        try DistributionFileSystem.createExclusiveDirectory(temporaryOutput)
        var movedIntoPlace = false
        defer {
            if !movedIntoPlace, FileManager.default.fileExists(atPath: temporaryOutput.path) {
                try? FileManager.default.removeItem(at: temporaryOutput)
            }
        }

        let artifactRoot = temporaryOutput.appendingPathComponent(artifactID, isDirectory: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: false)
        let inputs: [(String, URL)] = [
            ("bin/hostwright", request.hostwrightBinary),
            ("bin/hostwrightd", request.hostwrightDaemonBinary),
            ("share/doc/hostwright/LICENSE", request.licenseFile),
            ("share/doc/hostwright/README.md", request.readmeFile)
        ]
        for (path, source) in inputs {
            try DistributionFileSystem.copyRegularFile(
                from: source,
                to: artifactRoot.appendingPathComponent(path),
                mode: DistributionLayout.payloadModes[path]!
            )
        }

        let files = try DistributionLayout.payloadModes.keys.sorted().map { path -> DistributionFileRecord in
            let url = artifactRoot.appendingPathComponent(path)
            return DistributionFileRecord(
                path: path,
                sha256: try DistributionHash.sha256(fileURL: url),
                sizeBytes: try DistributionFileSystem.size(of: url),
                mode: try DistributionFileSystem.mode(of: url)
            )
        }
        let manifest = DistributionArtifactManifest(
            artifactID: artifactID,
            packageVersion: request.packageVersion,
            sourceCommit: request.sourceCommit,
            sourceDirty: request.sourceDirty,
            architecture: request.architecture,
            createdAt: timestamp,
            files: files
        )
        try manifest.validate()
        let manifestData = try DistributionJSON.encode(manifest)
        try DistributionFileSystem.writeNewFile(
            manifestData,
            to: artifactRoot.appendingPathComponent(DistributionLayout.manifestFileName),
            mode: 0o644
        )
        try DistributionFileSystem.writeNewFile(
            manifestData,
            to: temporaryOutput.appendingPathComponent(DistributionLayout.manifestFileName),
            mode: 0o644
        )

        let archiveName = "\(artifactID).tar.gz"
        let archiveURL = temporaryOutput.appendingPathComponent(archiveName)
        let archiveResult = try runner.run(
            executablePath: "/usr/bin/tar",
            arguments: ["-czf", archiveURL.path, "-C", temporaryOutput.path, artifactID],
            label: "create distribution archive"
        )
        commands.append(command("tar create exact artifact root", result: archiveResult))
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw DistributionError.invalidArtifact("archive command did not create its exact output")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: archiveURL.path)
        let archive = try descriptor(archiveURL)

        let sbomDocument = makeSPDX(manifest: manifest, archive: archive)
        let sbomURL = temporaryOutput.appendingPathComponent(DistributionLayout.sbomFileName)
        try DistributionFileSystem.writeNewFile(try DistributionJSON.encode(sbomDocument), to: sbomURL, mode: 0o644)
        let sbom = try descriptor(sbomURL)
        commands.append(HostwrightEvidenceCommand(command: "generate SPDX 2.3 artifact-content SBOM", exitCode: 0, durationMilliseconds: 0))

        let provenanceDocument = makeProvenance(manifest: manifest, archive: archive, timestamp: timestamp)
        let provenanceURL = temporaryOutput.appendingPathComponent(DistributionLayout.provenanceFileName)
        try DistributionFileSystem.writeNewFile(
            try DistributionJSON.encode(provenanceDocument),
            to: provenanceURL,
            mode: 0o644
        )
        let provenance = try descriptor(provenanceURL)
        commands.append(HostwrightEvidenceCommand(command: "generate unsigned in-toto provenance statement", exitCode: 0, durationMilliseconds: 0))

        commands.append(HostwrightEvidenceCommand(command: "generate SHA-256 sidecar checksums", exitCode: 0, durationMilliseconds: 0))

        let identityAvailable = developerIDApplicationIdentityAvailable(commands: &commands)
        var stages = [
            DistributionStageRecord(
                identifier: request.inputStageIdentifier,
                status: .passed,
                detail: request.inputStageDetail
            ),
            DistributionStageRecord(identifier: "archive", status: .passed, detail: "Created one exact macOS ARM64 tar.gz payload."),
            DistributionStageRecord(identifier: "checksums", status: .passed, detail: "Generated and bound SHA-256 sidecars."),
            DistributionStageRecord(identifier: "sbom", status: .passed, detail: "Generated an SPDX 2.3 artifact-content inventory."),
            DistributionStageRecord(identifier: "provenance", status: .passed, detail: "Generated an unsigned source/archive-bound provenance statement."),
            DistributionStageRecord(
                identifier: "developer-id-signing",
                status: .blocked,
                detail: identityAvailable
                    ? "A Developer ID Application identity was detected but no signing operation was approved or executed."
                    : "No Developer ID Application signing identity is installed."
            ),
            DistributionStageRecord(
                identifier: "notarization-stapling-gatekeeper",
                status: .blocked,
                detail: "No notarization credentials or approved network submission were supplied; stapling and Gatekeeper verification were not run."
            ),
            DistributionStageRecord(
                identifier: "installer-package",
                status: .blocked,
                detail: "No signed or notarized pkg installer was built."
            )
        ]
        if request.sourceDirty {
            stages.append(
                DistributionStageRecord(
                    identifier: "clean-source",
                    status: .blocked,
                    detail: "Prebuilt local-integration assembly recorded a dirty source input and is not release evidence."
                )
            )
        }
        let host = DistributionEnvironmentProbe.current
        if !host.unavailableFacts.isEmpty {
            stages.append(
                DistributionStageRecord(
                    identifier: "host-environment",
                    status: .blocked,
                    detail: "Required build-host facts were unavailable."
                )
            )
        }
        let toolVersions = collectToolVersions(identityAvailable: identityAvailable, commands: &commands)
        let passed = stages.filter { $0.status == .passed }.count
        let blocked = stages.filter { $0.status == .blocked }.count
        let evidence = HostwrightEvidenceReport(
            evidenceClass: .distributionArtifact,
            status: .blocked,
            recordedAt: timestamp,
            source: HostwrightEvidenceSource(commit: request.sourceCommit, dirty: request.sourceDirty),
            environment: host.evidenceEnvironment(toolVersions: toolVersions),
            commands: commands,
            rawResults: HostwrightEvidenceCounts(executed: stages.count, passed: passed, failed: 0, blocked: blocked),
            failures: [],
            blockers: stages.filter { $0.status == .blocked }.map(\.detail),
            cleanup: HostwrightEvidenceCleanup(
                status: .notRequired,
                exactResourceIdentifiers: [],
                message: "Requested local distribution output is retained for verification; no runtime or system resource was created."
            )
        )
        let report = DistributionBuildReport(
            manifest: manifest,
            archive: archive,
            sbom: sbom,
            provenance: provenance,
            stages: stages,
            evidence: evidence
        )
        try report.validate()
        try DistributionFileSystem.writeNewFile(
            try DistributionJSON.encode(report),
            to: temporaryOutput.appendingPathComponent(DistributionLayout.evidenceFileName),
            mode: 0o600
        )
        let checksumInputs = [
            archive,
            try descriptor(temporaryOutput.appendingPathComponent(DistributionLayout.manifestFileName)),
            sbom,
            provenance,
            try descriptor(temporaryOutput.appendingPathComponent(DistributionLayout.evidenceFileName))
        ].sorted { $0.fileName < $1.fileName }
        let checksumText = checksumInputs.map { "\($0.sha256)  \($0.fileName)" }.joined(separator: "\n") + "\n"
        try DistributionFileSystem.writeNewFile(
            Data(checksumText.utf8),
            to: temporaryOutput.appendingPathComponent(DistributionLayout.checksumFileName),
            mode: 0o644
        )
        try FileManager.default.removeItem(at: artifactRoot)
        try FileManager.default.moveItem(at: temporaryOutput, to: request.outputDirectory)
        movedIntoPlace = true
        return report
    }

    private func validateBinary(
        _ url: URL,
        versionArguments: [String],
        expectedVersion: String,
        label: String,
        commands: inout [HostwrightEvidenceCommand]
    ) throws {
        guard try DistributionFileSystem.isRegularNonSymlink(url),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw DistributionError.invalidArtifact("\(label) input is not an executable regular file")
        }
        let result = try runner.run(executablePath: url.path, arguments: versionArguments, label: label, timeoutSeconds: 30)
        commands.append(command(label, result: result))
        guard result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == expectedVersion else {
            throw DistributionError.invalidArtifact("\(label) output did not match the package version")
        }
    }

    private func validateArchitecture(
        _ url: URL,
        label: String,
        commands: inout [HostwrightEvidenceCommand]
    ) throws {
        let result = try runner.run(
            executablePath: "/usr/bin/lipo",
            arguments: ["-archs", url.path],
            label: label,
            timeoutSeconds: 30
        )
        commands.append(command(label, result: result))
        guard result.standardOutput.split(whereSeparator: { $0.isWhitespace }).map(String.init) == ["arm64"] else {
            throw DistributionError.invalidArtifact("\(label) requires one ARM64 Mach-O slice")
        }
    }

    private func developerIDApplicationIdentityAvailable(commands: inout [HostwrightEvidenceCommand]) -> Bool {
        do {
            let result = try runner.run(
                executablePath: "/usr/bin/security",
                arguments: ["find-identity", "-v", "-p", "codesigning"],
                label: "inspect local code-signing identities",
                timeoutSeconds: 30
            )
            commands.append(command("inspect Developer ID Application identity availability", result: result))
            return result.standardOutput.contains("Developer ID Application:")
        } catch {
            commands.append(HostwrightEvidenceCommand(
                command: "inspect Developer ID Application identity availability",
                exitCode: 1,
                durationMilliseconds: 0
            ))
            return false
        }
    }

    private func collectToolVersions(
        identityAvailable: Bool,
        commands: inout [HostwrightEvidenceCommand]
    ) -> [String: String] {
        var versions = [
            "hostwright-dist": "1",
            "developer-id-application": identityAvailable ? "available-unconsumed" : "unavailable"
        ]
        let probes = [
            ("swift", "/usr/bin/swift", ["--version"]),
            ("git", "/usr/bin/git", ["--version"]),
            ("tar", "/usr/bin/tar", ["--version"]),
            ("notarytool", "/usr/bin/xcrun", ["notarytool", "--version"])
        ]
        for (name, executable, arguments) in probes {
            do {
                let result = try runner.run(
                    executablePath: executable,
                    arguments: arguments,
                    label: "read \(name) version",
                    timeoutSeconds: 30
                )
                commands.append(command("read \(name) version", result: result))
                let output = (result.standardOutput + result.standardError)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n")
                    .first
                    .map(String.init)
                versions[name] = output?.isEmpty == false ? output : "unavailable"
            } catch {
                versions[name] = "unavailable"
            }
        }
        return versions
    }

    private func descriptor(_ url: URL) throws -> DistributionArtifactDescriptor {
        DistributionArtifactDescriptor(
            fileName: url.lastPathComponent,
            sha256: try DistributionHash.sha256(fileURL: url),
            sizeBytes: try DistributionFileSystem.size(of: url)
        )
    }

    private func command(_ label: String, result: DistributionCommandResult) -> HostwrightEvidenceCommand {
        HostwrightEvidenceCommand(
            command: label,
            exitCode: Int(result.exitStatus),
            durationMilliseconds: result.durationMilliseconds
        )
    }

    private func makeSPDX(
        manifest: DistributionArtifactManifest,
        archive: DistributionArtifactDescriptor
    ) -> DistributionSPDXDocument {
        let packageID = "SPDXRef-Package-Hostwright"
        let fileRecords = manifest.files.enumerated().map { index, file in
            SPDXFileRecord(
                fileName: "./\(file.path)",
                SPDXID: "SPDXRef-File-\(index + 1)",
                checksums: [SPDXChecksum(algorithm: "SHA256", checksumValue: file.sha256)],
                fileTypes: [file.path.hasPrefix("bin/") ? "BINARY" : "TEXT"],
                licenseConcluded: "NOASSERTION",
                copyrightText: "NOASSERTION"
            )
        }
        return DistributionSPDXDocument(
            spdxVersion: "SPDX-2.3",
            dataLicense: "CC0-1.0",
            SPDXID: "SPDXRef-DOCUMENT",
            name: "Hostwright \(manifest.packageVersion) artifact-content SBOM",
            documentNamespace: "urn:hostwright:spdx:\(manifest.sourceCommit):\(archive.sha256)",
            creationInfo: SPDXCreationInfo(created: manifest.createdAt, creators: ["Tool: hostwright-dist-1"]),
            packages: [
                SPDXPackageRecord(
                    name: "Hostwright",
                    SPDXID: packageID,
                    versionInfo: manifest.packageVersion,
                    downloadLocation: "NOASSERTION",
                    filesAnalyzed: true,
                    checksums: [SPDXChecksum(algorithm: "SHA256", checksumValue: archive.sha256)],
                    licenseConcluded: "NOASSERTION",
                    licenseDeclared: "NOASSERTION",
                    copyrightText: "NOASSERTION"
                )
            ],
            files: fileRecords,
            relationships: [
                SPDXRelationship(
                    spdxElementId: "SPDXRef-DOCUMENT",
                    relationshipType: "DESCRIBES",
                    relatedSpdxElement: packageID
                )
            ] + fileRecords.map {
                SPDXRelationship(
                    spdxElementId: packageID,
                    relationshipType: "CONTAINS",
                    relatedSpdxElement: $0.SPDXID
                )
            }
        )
    }

    private func makeProvenance(
        manifest: DistributionArtifactManifest,
        archive: DistributionArtifactDescriptor,
        timestamp: String
    ) -> DistributionProvenanceStatement {
        DistributionProvenanceStatement(
            statementType: "https://in-toto.io/Statement/v1",
            subject: [ProvenanceSubject(name: archive.fileName, digest: ["sha256": archive.sha256])],
            predicateType: "https://slsa.dev/provenance/v1",
            predicate: DistributionProvenancePredicate(
                buildDefinition: ProvenanceBuildDefinition(
                    buildType: "urn:hostwright:buildtype:swiftpm-archive:v1",
                    externalParameters: ProvenanceExternalParameters(
                        configuration: "release",
                        products: ["hostwright", "hostwrightd"],
                        platform: manifest.platform,
                        architecture: manifest.architecture
                    ),
                    internalParameters: ProvenanceInternalParameters(
                        sourceDirty: manifest.sourceDirty,
                        unsigned: true
                    ),
                    resolvedDependencies: [
                        ProvenanceResolvedDependency(
                            uri: "git+https://github.com/hostwright/hostwright.git",
                            digest: ["gitCommit": manifest.sourceCommit]
                        )
                    ]
                ),
                runDetails: ProvenanceRunDetails(
                    builder: ProvenanceBuilder(id: "urn:hostwright:builder:local-swiftpm:v1"),
                    metadata: ProvenanceMetadata(
                        invocationId: UUID().uuidString,
                        startedOn: timestamp,
                        finishedOn: DistributionTimestamp.string(Date())
                    )
                )
            )
        )
    }
}

public struct DistributionCleanBuilder: Sendable {
    private let runner: DistributionProcessRunner
    private let assembler: DistributionAssembler

    public init(runner: DistributionProcessRunner = DistributionProcessRunner()) {
        self.runner = runner
        self.assembler = DistributionAssembler(runner: runner)
    }

    public func build(sourceRoot: URL, outputDirectory: URL, expectedCommit: String) throws -> DistributionBuildReport {
        guard expectedCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              try DistributionFileSystem.isDirectoryNonSymlink(sourceRoot),
              try DistributionFileSystem.isRegularNonSymlink(sourceRoot.appendingPathComponent("Package.swift")) else {
            throw DistributionError.invalidArguments("Clean build requires a package root and exact expected commit.")
        }
        var commands: [HostwrightEvidenceCommand] = []
        let commitResult = try runner.run(
            executablePath: "/usr/bin/git",
            arguments: ["-C", sourceRoot.path, "rev-parse", "HEAD"],
            label: "read source commit",
            timeoutSeconds: 30
        )
        commands.append(record("git rev-parse HEAD", commitResult))
        let actualCommit = commitResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard actualCommit == expectedCommit else {
            throw DistributionError.sourceCommitMismatch(expected: expectedCommit, actual: actualCommit)
        }
        let statusResult = try runner.run(
            executablePath: "/usr/bin/git",
            arguments: ["-C", sourceRoot.path, "status", "--porcelain=v1", "--untracked-files=all"],
            label: "verify clean source",
            timeoutSeconds: 30
        )
        commands.append(record("git status --porcelain=v1 --untracked-files=all", statusResult))
        guard statusResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DistributionError.dirtySource
        }

        let dependencyResult = try runner.run(
            executablePath: "/usr/bin/swift",
            arguments: ["package", "--package-path", sourceRoot.path, "show-dependencies", "--format", "json"],
            label: "inspect SwiftPM dependencies"
        )
        commands.append(record("swift package show-dependencies --format json", dependencyResult))
        try requireNoExternalDependencies(dependencyResult.standardOutput)

        for product in ["hostwright", "hostwrightd"] {
            let result = try runner.run(
                executablePath: "/usr/bin/swift",
                arguments: ["build", "--package-path", sourceRoot.path, "-c", "release", "--product", product],
                label: "build release product \(product)"
            )
            commands.append(record("swift build -c release --product \(product)", result))
        }
        let binPathResult = try runner.run(
            executablePath: "/usr/bin/swift",
            arguments: ["build", "--package-path", sourceRoot.path, "-c", "release", "--show-bin-path"],
            label: "read release binary path"
        )
        commands.append(record("swift build -c release --show-bin-path", binPathResult))
        let binPath = binPathResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard binPath.hasPrefix("/") else {
            throw DistributionError.invalidArtifact("SwiftPM did not return an absolute release binary path")
        }
        let hostwright = URL(fileURLWithPath: binPath).appendingPathComponent("hostwright")
        let daemon = URL(fileURLWithPath: binPath).appendingPathComponent("hostwrightd")
        let versionResult = try runner.run(
            executablePath: hostwright.path,
            arguments: ["--version"],
            label: "read release package version",
            timeoutSeconds: 30
        )
        commands.append(record("release hostwright --version", versionResult))
        let version = versionResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        let finalCommitResult = try runner.run(
            executablePath: "/usr/bin/git",
            arguments: ["-C", sourceRoot.path, "rev-parse", "HEAD"],
            label: "recheck source commit",
            timeoutSeconds: 30
        )
        commands.append(record("post-build git rev-parse HEAD", finalCommitResult))
        let finalCommit = finalCommitResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard finalCommit == actualCommit else {
            throw DistributionError.sourceCommitMismatch(expected: actualCommit, actual: finalCommit)
        }
        let finalStatusResult = try runner.run(
            executablePath: "/usr/bin/git",
            arguments: ["-C", sourceRoot.path, "status", "--porcelain=v1", "--untracked-files=all"],
            label: "recheck clean source",
            timeoutSeconds: 30
        )
        commands.append(record("post-build git status --porcelain=v1 --untracked-files=all", finalStatusResult))
        guard finalStatusResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DistributionError.dirtySource
        }

        return try assembler.assemble(
            DistributionAssemblyRequest(
                hostwrightBinary: hostwright,
                hostwrightDaemonBinary: daemon,
                licenseFile: sourceRoot.appendingPathComponent("LICENSE"),
                readmeFile: sourceRoot.appendingPathComponent("README.md"),
                outputDirectory: outputDirectory,
                packageVersion: version,
                sourceCommit: actualCommit,
                sourceDirty: false,
                architecture: "arm64",
                inputStageIdentifier: "release-build",
                inputStageDetail: "Built both SwiftPM release products from the clean exact source commit with no external package dependencies.",
                priorCommands: commands
            )
        )
    }

    private func requireNoExternalDependencies(_ json: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let dependencies = object["dependencies"] as? [Any],
              dependencies.isEmpty else {
            throw DistributionError.invalidArtifact("SwiftPM dependency inventory is malformed or contains external dependencies")
        }
    }

    private func record(_ label: String, _ result: DistributionCommandResult) -> HostwrightEvidenceCommand {
        HostwrightEvidenceCommand(
            command: label,
            exitCode: Int(result.exitStatus),
            durationMilliseconds: result.durationMilliseconds
        )
    }
}
