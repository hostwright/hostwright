import Foundation
import HostwrightCore

public struct VerifiedDistributionArtifact: Sendable {
    public let distributionDirectory: URL
    public let extractedRoot: URL
    public let manifest: DistributionArtifactManifest
    public let report: DistributionBuildReport

    public init(
        distributionDirectory: URL,
        extractedRoot: URL,
        manifest: DistributionArtifactManifest,
        report: DistributionBuildReport
    ) {
        self.distributionDirectory = distributionDirectory
        self.extractedRoot = extractedRoot
        self.manifest = manifest
        self.report = report
    }
}

public struct DistributionVerifier: Sendable {
    private let runner: DistributionProcessRunner

    public init(runner: DistributionProcessRunner = DistributionProcessRunner()) {
        self.runner = runner
    }

    public func verify(
        distributionDirectory: URL,
        extractionDirectory: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> VerifiedDistributionArtifact {
        guard !cancellation.isCancelled else {
            throw DistributionError.commandCancelled("distribution verification preflight")
        }
        guard try DistributionFileSystem.isDirectoryNonSymlink(distributionDirectory) else {
            throw DistributionError.invalidArtifact("distribution input is not a regular directory")
        }
        try DistributionTemporaryPathPolicy.validate(extractionDirectory, role: "artifact extraction")
        let reportURL = distributionDirectory.appendingPathComponent(DistributionLayout.evidenceFileName)
        let report = try DistributionJSON.decode(DistributionBuildReport.self, from: reportURL)
        try report.validate()

        let expectedTopLevel = Set([
            report.archive.fileName,
            DistributionLayout.manifestFileName,
            DistributionLayout.sbomFileName,
            DistributionLayout.provenanceFileName,
            DistributionLayout.checksumFileName,
            DistributionLayout.evidenceFileName
        ])
        let actualTopLevel = try FileManager.default.contentsOfDirectory(
            at: distributionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        guard Set(actualTopLevel.map(\.lastPathComponent)) == expectedTopLevel,
              actualTopLevel.count == expectedTopLevel.count,
              try actualTopLevel.allSatisfy(DistributionFileSystem.isRegularNonSymlink) else {
            throw DistributionError.invalidArtifact("distribution directory contains missing, extra, or non-regular entries")
        }
        try validateSidecarModes(distributionDirectory: distributionDirectory, archiveName: report.archive.fileName)
        try validateChecksums(
            distributionDirectory: distributionDirectory,
            expectedFileNames: expectedTopLevel.subtracting([DistributionLayout.checksumFileName]),
            cancellation: cancellation
        )

        let manifestURL = distributionDirectory.appendingPathComponent(DistributionLayout.manifestFileName)
        let manifest = try DistributionJSON.decode(DistributionArtifactManifest.self, from: manifestURL)
        try manifest.validate()
        guard manifest == report.manifest else {
            throw DistributionError.invalidArtifact("sidecar manifest does not match the evidence report")
        }
        try validateDescriptor(
            report.archive,
            at: distributionDirectory.appendingPathComponent(report.archive.fileName),
            cancellation: cancellation
        )
        try validateDescriptor(
            report.sbom,
            at: distributionDirectory.appendingPathComponent(DistributionLayout.sbomFileName),
            cancellation: cancellation
        )
        try validateDescriptor(
            report.provenance,
            at: distributionDirectory.appendingPathComponent(DistributionLayout.provenanceFileName),
            cancellation: cancellation
        )
        let sbom = try DistributionJSON.decode(
            DistributionSPDXDocument.self,
            from: distributionDirectory.appendingPathComponent(DistributionLayout.sbomFileName)
        )
        try sbom.validate(manifest: manifest, archive: report.archive)
        let provenance = try DistributionJSON.decode(
            DistributionProvenanceStatement.self,
            from: distributionDirectory.appendingPathComponent(DistributionLayout.provenanceFileName)
        )
        try provenance.validate(manifest: manifest, archive: report.archive)

        let archiveURL = distributionDirectory.appendingPathComponent(report.archive.fileName)
        try validateArchiveTable(archiveURL: archiveURL, manifest: manifest, cancellation: cancellation)
        try DistributionFileSystem.createExclusiveDirectory(extractionDirectory)
        var verified = false
        defer {
            if !verified, FileManager.default.fileExists(atPath: extractionDirectory.path) {
                try? FileManager.default.removeItem(at: extractionDirectory)
            }
        }
        _ = try runner.run(
            executablePath: "/usr/bin/tar",
            arguments: ["-xzf", archiveURL.path, "-C", extractionDirectory.path],
            label: "extract verified distribution archive",
            timeoutSeconds: 120,
            cancellation: cancellation
        )
        let extractedRoot = extractionDirectory.appendingPathComponent(manifest.artifactID, isDirectory: true)
        try validateExtractedTree(
            extractionDirectory: extractionDirectory,
            extractedRoot: extractedRoot,
            manifestURL: manifestURL,
            manifest: manifest,
            cancellation: cancellation
        )
        verified = true
        return VerifiedDistributionArtifact(
            distributionDirectory: distributionDirectory,
            extractedRoot: extractedRoot,
            manifest: manifest,
            report: report
        )
    }

    public func verifyAndCleanup(
        distributionDirectory: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionBuildReport {
        let extraction = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-dist-verify-\(UUID().uuidString)", isDirectory: true)
        let artifact = try verify(
            distributionDirectory: distributionDirectory,
            extractionDirectory: extraction,
            cancellation: cancellation
        )
        do {
            try DistributionFileSystem.removeOwnedTemporaryItem(extraction)
        } catch {
            throw DistributionError.invalidArtifact("verified extraction could not be cleaned up")
        }
        return artifact.report
    }

    private func validateChecksums(
        distributionDirectory: URL,
        expectedFileNames: Set<String>,
        cancellation: SecureSubprocessCancellation
    ) throws {
        let checksumURL = distributionDirectory.appendingPathComponent(DistributionLayout.checksumFileName)
        let text = try String(contentsOf: checksumURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var values: [String: String] = [:]
        for line in lines {
            let parts = line.components(separatedBy: "  ")
            guard parts.count == 2,
                  parts[0].range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  DistributionPathPolicy.isSafeFileName(parts[1]),
                  values[parts[1]] == nil else {
                throw DistributionError.invalidArtifact("SHA256SUMS contains malformed or duplicate entries")
            }
            values[parts[1]] = parts[0]
        }
        guard Set(values.keys) == expectedFileNames else {
            throw DistributionError.invalidArtifact("SHA256SUMS does not cover the exact sidecar set")
        }
        for (name, expected) in values {
            let actual = try DistributionHash.sha256(
                fileURL: distributionDirectory.appendingPathComponent(name),
                cancellation: cancellation
            )
            guard actual == expected else {
                throw DistributionError.checksumMismatch(name)
            }
        }
    }

    private func validateDescriptor(
        _ descriptor: DistributionArtifactDescriptor,
        at url: URL,
        cancellation: SecureSubprocessCancellation
    ) throws {
        guard descriptor.sha256 == (try DistributionHash.sha256(fileURL: url, cancellation: cancellation)),
              descriptor.sizeBytes == (try DistributionFileSystem.size(of: url)) else {
            throw DistributionError.checksumMismatch(descriptor.fileName)
        }
    }

    func validateArchiveTable(
        archiveURL: URL,
        manifest: DistributionArtifactManifest,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws {
        let result = try runner.run(
            executablePath: "/usr/bin/tar",
            arguments: ["-tvzf", archiveURL.path],
            label: "inspect distribution archive entries",
            timeoutSeconds: 120,
            cancellation: cancellation
        )
        let lines = result.standardOutput.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let expected = expectedArchivePaths(manifest: manifest)
        var observed: [String] = []
        for line in lines {
            guard let type = line.first, type == "d" || type == "-",
                  let rawPath = line.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) else {
                throw DistributionError.invalidArtifact("archive contains a link, device, or unsupported entry type")
            }
            let path = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            guard DistributionPathPolicy.isSafeRelativePath(path),
                  path == manifest.artifactID || path.hasPrefix(manifest.artifactID + "/") else {
                throw DistributionError.invalidArtifact("archive entry escapes its exact artifact root")
            }
            observed.append(path)
        }
        guard observed.count == Set(observed).count, Set(observed) == expected else {
            throw DistributionError.invalidArtifact("archive entry inventory does not match the manifest")
        }
    }

    private func validateExtractedTree(
        extractionDirectory: URL,
        extractedRoot: URL,
        manifestURL: URL,
        manifest: DistributionArtifactManifest,
        cancellation: SecureSubprocessCancellation
    ) throws {
        guard try DistributionFileSystem.isDirectoryNonSymlink(extractedRoot) else {
            throw DistributionError.invalidArtifact("archive did not extract one regular artifact root")
        }
        let subpaths = try FileManager.default.subpathsOfDirectory(atPath: extractionDirectory.path)
        guard subpaths.count == Set(subpaths).count,
              Set(subpaths) == expectedArchivePaths(manifest: manifest) else {
            throw DistributionError.invalidArtifact("extracted file tree contains missing or extra entries")
        }
        let expectedDirectories = expectedDirectoryPaths(manifest: manifest)
        for path in subpaths {
            guard !cancellation.isCancelled else {
                throw DistributionError.commandCancelled("validate extracted distribution tree")
            }
            let url = extractionDirectory.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw DistributionError.invalidArtifact("extracted tree contains a symbolic link")
            }
            if expectedDirectories.contains(path) {
                guard values.isDirectory == true else {
                    throw DistributionError.invalidArtifact("expected archive directory is not a directory")
                }
            } else {
                guard values.isRegularFile == true else {
                    throw DistributionError.invalidArtifact("expected archive file is not regular")
                }
            }
        }
        let insideManifest = extractedRoot.appendingPathComponent(DistributionLayout.manifestFileName)
        guard try Data(contentsOf: insideManifest) == Data(contentsOf: manifestURL),
              try DistributionFileSystem.mode(of: insideManifest) == 0o644 else {
            throw DistributionError.invalidArtifact("archive manifest differs from its verified sidecar")
        }
        for file in manifest.files {
            guard !cancellation.isCancelled else {
                throw DistributionError.commandCancelled("hash extracted distribution payload")
            }
            let url = extractedRoot.appendingPathComponent(file.path)
            guard try DistributionHash.sha256(fileURL: url, cancellation: cancellation) == file.sha256,
                  try DistributionFileSystem.size(of: url) == file.sizeBytes,
                  try DistributionFileSystem.mode(of: url) == file.mode else {
                throw DistributionError.invalidArtifact("payload metadata drifted for \(file.path)")
            }
        }
    }

    private func expectedArchivePaths(manifest: DistributionArtifactManifest) -> Set<String> {
        var paths = expectedDirectoryPaths(manifest: manifest)
        paths.insert("\(manifest.artifactID)/\(DistributionLayout.manifestFileName)")
        for file in manifest.files {
            paths.insert("\(manifest.artifactID)/\(file.path)")
        }
        return paths
    }

    private func expectedDirectoryPaths(manifest: DistributionArtifactManifest) -> Set<String> {
        var directories: Set<String> = [manifest.artifactID]
        for file in manifest.files {
            let components = file.path.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            var current = manifest.artifactID
            for component in components.dropLast() {
                current += "/\(component)"
                directories.insert(current)
            }
        }
        return directories
    }

    private func validateSidecarModes(distributionDirectory: URL, archiveName: String) throws {
        let expected: [String: Int] = [
            archiveName: 0o644,
            DistributionLayout.manifestFileName: 0o644,
            DistributionLayout.sbomFileName: 0o644,
            DistributionLayout.provenanceFileName: 0o644,
            DistributionLayout.checksumFileName: 0o644,
            DistributionLayout.evidenceFileName: 0o600
        ]
        for (name, mode) in expected {
            guard try DistributionFileSystem.mode(of: distributionDirectory.appendingPathComponent(name)) == mode else {
                throw DistributionError.invalidArtifact("unexpected file mode for \(name)")
            }
        }
    }

}

public enum DistributionTemporaryPathPolicy {
    public static func validate(_ url: URL, role: String) throws {
        guard url.path.hasPrefix("/") else {
            throw DistributionError.unsafePath("\(role) requires an absolute path.")
        }
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath().path
        let systemTemp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let inSystemTemp = standardized.hasPrefix(systemTemp + "/") ||
            standardized.hasPrefix("/private/tmp/") ||
            standardized.hasPrefix("/tmp/")
        guard inSystemTemp,
              standardized != systemTemp,
              standardized != "/private/tmp",
              url.lastPathComponent.hasPrefix("hostwright-dist-") else {
            throw DistributionError.unsafePath("\(role) must use a unique hostwright-dist-* path under a temporary directory.")
        }
    }
}
