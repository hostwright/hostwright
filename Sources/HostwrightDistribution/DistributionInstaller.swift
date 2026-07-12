import Darwin
import Foundation
import HostwrightCore

public struct DistributionInstaller: Sendable {
    private let runner: DistributionProcessRunner

    public init(runner: DistributionProcessRunner = DistributionProcessRunner()) {
        self.runner = runner
    }

    @discardableResult
    public func install(
        artifact: VerifiedDistributionArtifact,
        prefix: URL
    ) throws -> DistributionInstallManifest {
        try validatePrefix(prefix)
        let manifestURL = prefix.appendingPathComponent(DistributionLayout.installManifestFileName)
        let existing = try loadExistingManifest(manifestURL)
        if let existing {
            try verifyOwnedFiles(existing, prefix: prefix)
        } else {
            for path in DistributionLayout.payloadModes.keys {
                guard !DistributionFileSystem.entryExists(prefix.appendingPathComponent(path)) else {
                    throw DistributionError.installOwnershipMismatch(path)
                }
            }
        }

        let createdDirectories = existing?.createdDirectories ?? directoriesCreatedByFirstInstall(prefix: prefix)
        let nextManifest = DistributionInstallManifest(
            artifact: artifact.manifest,
            createdDirectories: createdDirectories
        )
        try nextManifest.validate()

        let transaction = prefix.deletingLastPathComponent()
            .appendingPathComponent("hostwright-dist-txn-\(UUID().uuidString)", isDirectory: true)
        try DistributionTemporaryPathPolicy.validate(transaction, role: "install transaction")
        try DistributionFileSystem.createExclusiveDirectory(transaction)
        var transactionRemoved = false
        defer {
            if !transactionRemoved { try? DistributionFileSystem.removeOwnedTemporaryItem(transaction) }
        }
        let staged = transaction.appendingPathComponent("staged", isDirectory: true)
        let backup = transaction.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)

        for file in artifact.manifest.files {
            try DistributionFileSystem.copyRegularFile(
                from: artifact.extractedRoot.appendingPathComponent(file.path),
                to: staged.appendingPathComponent(file.path),
                mode: file.mode
            )
        }
        try DistributionFileSystem.writeNewFile(
            try DistributionJSON.encode(nextManifest),
            to: staged.appendingPathComponent(DistributionLayout.installManifestFileName),
            mode: 0o644
        )
        if let existing {
            for file in existing.files {
                try DistributionFileSystem.copyRegularFile(
                    from: prefix.appendingPathComponent(file.path),
                    to: backup.appendingPathComponent(file.path),
                    mode: file.mode
                )
            }
            try DistributionFileSystem.copyRegularFile(
                from: manifestURL,
                to: backup.appendingPathComponent(DistributionLayout.installManifestFileName),
                mode: 0o644
            )
        }

        var appliedPaths: [String] = []
        do {
            for path in payloadDirectories().sorted() {
                let directory = prefix.appendingPathComponent(path, isDirectory: true)
                if !FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                }
            }
            for file in nextManifest.files {
                try atomicMoveReplacing(
                    from: staged.appendingPathComponent(file.path),
                    to: prefix.appendingPathComponent(file.path)
                )
                appliedPaths.append(file.path)
            }
            try atomicMoveReplacing(
                from: staged.appendingPathComponent(DistributionLayout.installManifestFileName),
                to: manifestURL
            )
            appliedPaths.append(DistributionLayout.installManifestFileName)
            try verifyOwnedFiles(nextManifest, prefix: prefix)
        } catch {
            let applyError = error
            do {
                try rollback(
                    appliedPaths: appliedPaths,
                    backup: existing == nil ? nil : backup,
                    prefix: prefix
                )
                try removeCreatedDirectoriesIfEmpty(createdDirectories, prefix: prefix)
            } catch {
                throw DistributionError.lifecycleFailed(
                    "install failed and rollback could not restore the exact prior payload"
                )
            }
            throw applyError
        }
        do {
            try DistributionFileSystem.removeOwnedTemporaryItem(transaction)
            transactionRemoved = true
        } catch {
            do {
                try rollback(
                    appliedPaths: appliedPaths,
                    backup: existing == nil ? nil : backup,
                    prefix: prefix
                )
                try removeCreatedDirectoriesIfEmpty(createdDirectories, prefix: prefix)
            } catch {
                throw DistributionError.lifecycleFailed(
                    "install transaction cleanup failed and rollback could not restore the exact prior payload"
                )
            }
            throw DistributionError.lifecycleFailed(
                "install transaction cleanup failed; the exact prior payload was restored"
            )
        }
        return nextManifest
    }

    public func verifyInstalled(
        prefix: URL,
        expectedManifest: DistributionInstallManifest
    ) throws -> [HostwrightEvidenceCommand] {
        try validatePrefix(prefix)
        let installed = try DistributionJSON.decode(
            DistributionInstallManifest.self,
            from: prefix.appendingPathComponent(DistributionLayout.installManifestFileName)
        )
        try installed.validate()
        guard installed == expectedManifest else {
            throw DistributionError.installOwnershipMismatch(DistributionLayout.installManifestFileName)
        }
        try verifyOwnedFiles(installed, prefix: prefix)

        let version = try runner.run(
            executablePath: prefix.appendingPathComponent("bin/hostwright").path,
            arguments: ["--version"],
            label: "run installed hostwright --version",
            timeoutSeconds: 30
        )
        guard version.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == installed.packageVersion else {
            throw DistributionError.lifecycleFailed("installed hostwright version output did not match its manifest")
        }
        let daemon = try runner.run(
            executablePath: prefix.appendingPathComponent("bin/hostwrightd").path,
            arguments: ["--help"],
            label: "run installed hostwrightd --help",
            timeoutSeconds: 30
        )
        guard daemon.standardOutput.contains("Usage:"),
              daemon.standardOutput.contains("does not perform unattended runtime mutation") else {
            throw DistributionError.lifecycleFailed("installed hostwrightd help did not preserve its safety boundary")
        }
        return [
            evidenceCommand("installed hostwright --version", result: version),
            evidenceCommand("installed hostwrightd --help", result: daemon)
        ]
    }

    @discardableResult
    public func uninstall(prefix: URL) throws -> [String] {
        try validatePrefix(prefix)
        let manifestURL = prefix.appendingPathComponent(DistributionLayout.installManifestFileName)
        let manifest = try DistributionJSON.decode(DistributionInstallManifest.self, from: manifestURL)
        try manifest.validate()
        try verifyOwnedFiles(manifest, prefix: prefix)

        let transaction = prefix.deletingLastPathComponent()
            .appendingPathComponent("hostwright-dist-uninstall-\(UUID().uuidString)", isDirectory: true)
        try DistributionTemporaryPathPolicy.validate(transaction, role: "uninstall transaction")
        try DistributionFileSystem.createExclusiveDirectory(transaction)
        var transactionRemoved = false
        defer {
            if !transactionRemoved { try? DistributionFileSystem.removeOwnedTemporaryItem(transaction) }
        }
        let paths = manifest.files.map(\.path) + [DistributionLayout.installManifestFileName]
        var moved: [String] = []
        var removedDirectories: [String] = []
        do {
            for path in paths {
                let backup = transaction.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: backup.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try atomicMoveReplacing(from: prefix.appendingPathComponent(path), to: backup)
                moved.append(path)
            }
            for path in manifest.createdDirectories.sorted(by: directoryDepthDescending) {
                let url = prefix.appendingPathComponent(path, isDirectory: true)
                guard DistributionFileSystem.entryExists(url),
                      try DistributionFileSystem.isDirectoryNonSymlink(url) else { continue }
                if try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty {
                    try FileManager.default.removeItem(at: url)
                    removedDirectories.append(path)
                }
            }
        } catch {
            let primaryError = error
            do {
                for path in removedDirectories.sorted() {
                    let directory = prefix.appendingPathComponent(path, isDirectory: true)
                    if !FileManager.default.fileExists(atPath: directory.path) {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    }
                }
                for path in moved.reversed() {
                    try atomicMoveReplacing(
                        from: transaction.appendingPathComponent(path),
                        to: prefix.appendingPathComponent(path)
                    )
                }
                try verifyOwnedFiles(manifest, prefix: prefix)
            } catch {
                throw DistributionError.lifecycleFailed(
                    "uninstall failed and rollback could not restore the exact prior payload"
                )
            }
            throw primaryError
        }
        try DistributionFileSystem.removeOwnedTemporaryItem(transaction)
        transactionRemoved = true
        return (paths + removedDirectories).sorted()
    }

    private func loadExistingManifest(_ url: URL) throws -> DistributionInstallManifest? {
        guard DistributionFileSystem.entryExists(url) else { return nil }
        let manifest = try DistributionJSON.decode(DistributionInstallManifest.self, from: url)
        try manifest.validate()
        return manifest
    }

    private func verifyOwnedFiles(_ manifest: DistributionInstallManifest, prefix: URL) throws {
        for file in manifest.files {
            let url = prefix.appendingPathComponent(file.path)
            guard try DistributionFileSystem.isRegularNonSymlink(url),
                  try DistributionHash.sha256(fileURL: url) == file.sha256,
                  try DistributionFileSystem.size(of: url) == file.sizeBytes,
                  try DistributionFileSystem.mode(of: url) == file.mode else {
                throw DistributionError.installOwnershipMismatch(file.path)
            }
        }
    }

    private func rollback(
        appliedPaths: [String],
        backup: URL?,
        prefix: URL
    ) throws {
        for path in appliedPaths.reversed() {
            let destination = prefix.appendingPathComponent(path)
            if let backup {
                let source = backup.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw DistributionError.lifecycleFailed("rollback backup is incomplete")
                }
                try atomicMoveReplacing(from: source, to: destination)
            } else if FileManager.default.fileExists(atPath: destination.path) {
                try removeExactOwnedFile(destination)
            }
        }
    }

    private func atomicMoveReplacing(from source: URL, to destination: URL) throws {
        guard try DistributionFileSystem.isRegularNonSymlink(source),
              DistributionPathPolicy.isSafeRelativePath(destination.lastPathComponent) else {
            throw DistributionError.invalidArtifact("atomic install input is invalid")
        }
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func removeCreatedDirectoriesIfEmpty(_ paths: [String], prefix: URL) throws {
        for path in paths.sorted(by: directoryDepthDescending) {
            let url = prefix.appendingPathComponent(path, isDirectory: true)
            guard DistributionFileSystem.entryExists(url),
                  try DistributionFileSystem.isDirectoryNonSymlink(url) else { continue }
            if try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func removeExactOwnedFile(_ url: URL) throws {
        guard try DistributionFileSystem.isRegularNonSymlink(url) else {
            throw DistributionError.installOwnershipMismatch(url.lastPathComponent)
        }
        try FileManager.default.removeItem(at: url)
    }

    private func directoriesCreatedByFirstInstall(prefix: URL) -> [String] {
        payloadDirectories().filter {
            !DistributionFileSystem.entryExists(prefix.appendingPathComponent($0))
        }.sorted()
    }

    private func payloadDirectories() -> [String] {
        Array(Set(DistributionLayout.payloadModes.keys.flatMap { path -> [String] in
            let components = path.split(separator: "/").map(String.init)
            var directories: [String] = []
            var current = ""
            for component in components.dropLast() {
                current = current.isEmpty ? component : "\(current)/\(component)"
                directories.append(current)
            }
            return directories
        }))
    }

    private func validatePrefix(_ prefix: URL) throws {
        try DistributionTemporaryPathPolicy.validate(prefix, role: "install prefix")
        guard try DistributionFileSystem.isDirectoryNonSymlink(prefix) else {
            throw DistributionError.unsafePath("Install prefix must already exist as a non-symlink directory.")
        }
        for path in payloadDirectories() {
            let directory = prefix.appendingPathComponent(path, isDirectory: true)
            if DistributionFileSystem.entryExists(directory),
               try !DistributionFileSystem.isDirectoryNonSymlink(directory) {
                throw DistributionError.unsafePath(
                    "Install payload parent must be a non-symlink directory: \(path)."
                )
            }
        }
    }

    private func directoryDepthDescending(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "/").count
        let right = rhs.split(separator: "/").count
        return left == right ? lhs > rhs : left > right
    }

    private func evidenceCommand(
        _ label: String,
        result: DistributionCommandResult
    ) -> HostwrightEvidenceCommand {
        HostwrightEvidenceCommand(
            command: label,
            exitCode: Int(result.exitStatus),
            durationMilliseconds: result.durationMilliseconds
        )
    }
}

public struct DistributionLifecycleRunner: Sendable {
    private let verifier: DistributionVerifier
    private let installer: DistributionInstaller

    public init(
        verifier: DistributionVerifier = DistributionVerifier(),
        installer: DistributionInstaller = DistributionInstaller()
    ) {
        self.verifier = verifier
        self.installer = installer
    }

    public func run(
        baselineDirectory: URL,
        candidateDirectory: URL,
        prefix: URL,
        reportURL: URL
    ) throws -> DistributionLifecycleReport {
        try DistributionTemporaryPathPolicy.validate(prefix, role: "lifecycle prefix")
        guard !FileManager.default.fileExists(atPath: reportURL.path) else {
            throw DistributionError.existingOutput(reportURL.path)
        }
        let initialSnapshot = try PrefixSnapshot.capture(prefix)
        for path in DistributionLayout.payloadModes.keys + [DistributionLayout.installManifestFileName] {
            guard !DistributionFileSystem.entryExists(prefix.appendingPathComponent(path)) else {
                throw DistributionError.installOwnershipMismatch(path)
            }
        }

        let baselineExtraction = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-dist-baseline-\(UUID().uuidString)", isDirectory: true)
        let candidateExtraction = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-dist-candidate-\(UUID().uuidString)", isDirectory: true)
        var extractionsRemoved = false
        defer {
            if !extractionsRemoved {
                try? DistributionFileSystem.removeOwnedTemporaryItem(baselineExtraction)
                try? DistributionFileSystem.removeOwnedTemporaryItem(candidateExtraction)
            }
        }
        let baseline = try verifier.verify(
            distributionDirectory: baselineDirectory,
            extractionDirectory: baselineExtraction
        )
        let candidate = try verifier.verify(
            distributionDirectory: candidateDirectory,
            extractionDirectory: candidateExtraction
        )
        guard baseline.manifest.sourceCommit != candidate.manifest.sourceCommit,
              baseline.manifest.architecture == candidate.manifest.architecture else {
            throw DistributionError.lifecycleFailed("baseline and candidate must be distinct compatible source revisions")
        }

        do {
            var stages: [DistributionStageRecord] = []
            var commands = [
            HostwrightEvidenceCommand(command: "verify baseline archive and sidecars", exitCode: 0, durationMilliseconds: 0),
            HostwrightEvidenceCommand(command: "verify candidate archive and sidecars", exitCode: 0, durationMilliseconds: 0)
        ]
            let baselineInstall = try installer.install(artifact: baseline, prefix: prefix)
            commands.append(contentsOf: try installer.verifyInstalled(prefix: prefix, expectedManifest: baselineInstall))
            stages.append(DistributionStageRecord(
            identifier: "install",
            status: .passed,
            detail: "Installed and executed the baseline revision under the explicit temporary prefix."
        ))

            let candidateInstall = try installer.install(artifact: candidate, prefix: prefix)
            commands.append(contentsOf: try installer.verifyInstalled(prefix: prefix, expectedManifest: candidateInstall))
            stages.append(DistributionStageRecord(
            identifier: "upgrade",
            status: .passed,
            detail: "Replaced the exact owned baseline payload with the distinct candidate revision and executed it."
        ))

            let downgradedInstall = try installer.install(artifact: baseline, prefix: prefix)
            commands.append(contentsOf: try installer.verifyInstalled(prefix: prefix, expectedManifest: downgradedInstall))
            stages.append(DistributionStageRecord(
            identifier: "downgrade",
            status: .passed,
            detail: "Restored the exact baseline revision and executed it after candidate replacement."
        ))

            let removedPaths = try installer.uninstall(prefix: prefix)
            stages.append(DistributionStageRecord(
            identifier: "uninstall",
            status: .passed,
            detail: "Removed only checksum-verified installer-owned files and retained unrelated prefix content."
        ))
            let finalSnapshot = try PrefixSnapshot.capture(prefix)
            guard initialSnapshot == finalSnapshot else {
                throw DistributionError.lifecycleFailed("uninstall changed unrelated prefix content")
            }
            do {
                try DistributionFileSystem.removeOwnedTemporaryItem(baselineExtraction)
                try DistributionFileSystem.removeOwnedTemporaryItem(candidateExtraction)
                extractionsRemoved = true
            } catch {
                throw DistributionError.lifecycleFailed("verified artifact extraction cleanup failed")
            }

            var blockers = Array(Set(
                baseline.report.evidence.blockers + candidate.report.evidence.blockers
            )).sorted()
            let host = DistributionEnvironmentProbe.current
            if !host.unavailableFacts.isEmpty {
                blockers.append("Required lifecycle host facts were unavailable.")
            }
            let toolVersions = candidate.report.evidence.environment.toolVersions
            let evidence = HostwrightEvidenceReport(
            evidenceClass: .distributionArtifact,
            status: .blocked,
            recordedAt: DistributionTimestamp.string(Date()),
            source: HostwrightEvidenceSource(
                commit: candidate.manifest.sourceCommit,
                dirty: candidate.manifest.sourceDirty
            ),
            environment: host.evidenceEnvironment(toolVersions: toolVersions),
            commands: commands,
            rawResults: HostwrightEvidenceCounts(
                executed: stages.count + blockers.count,
                passed: stages.count,
                failed: 0,
                blocked: blockers.count
            ),
            failures: [],
            blockers: blockers,
            cleanup: HostwrightEvidenceCleanup(
                status: .succeeded,
                exactResourceIdentifiers: removedPaths.map { prefix.appendingPathComponent($0).path },
                message: "Every exact installer-owned path was removed; the prefix snapshot returned to its initial unrelated content."
            )
        )
            let report = DistributionLifecycleReport(
            baselineCommit: baseline.manifest.sourceCommit,
            candidateCommit: candidate.manifest.sourceCommit,
            prefix: prefix.path,
            stages: stages,
            preservedPaths: initialSnapshot.entries.map(\.path),
            evidence: evidence
        )
            try report.validate()
            try DistributionFileSystem.writeNewFile(try DistributionJSON.encode(report), to: reportURL, mode: 0o600)
            return report
        } catch {
            let primaryError = error
            let installedManifest = prefix.appendingPathComponent(DistributionLayout.installManifestFileName)
            if FileManager.default.fileExists(atPath: installedManifest.path) {
                do {
                    _ = try installer.uninstall(prefix: prefix)
                } catch {
                    throw DistributionError.lifecycleFailed(
                        "lifecycle failed and exact installer-owned cleanup also failed"
                    )
                }
            }
            throw primaryError
        }
    }
}

private struct PrefixSnapshot: Equatable {
    struct Entry: Equatable {
        let path: String
        let kind: String
        let sha256: String?
        let mode: Int
    }

    let entries: [Entry]

    static func capture(_ prefix: URL) throws -> PrefixSnapshot {
        let values = try prefix.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw DistributionError.unsafePath("Lifecycle prefix must exist as a non-symlink directory.")
        }
        let paths = try FileManager.default.subpathsOfDirectory(atPath: prefix.path).sorted()
        var entries: [Entry] = []
        for path in paths {
            guard DistributionPathPolicy.isSafeRelativePath(path) else {
                throw DistributionError.unsafePath("Lifecycle prefix contains an unsafe relative path.")
            }
            let url = prefix.appendingPathComponent(path)
            let resource = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard resource.isSymbolicLink != true else {
                throw DistributionError.unsafePath("Lifecycle prefix contains a symbolic link.")
            }
            if resource.isDirectory == true {
                entries.append(Entry(path: path, kind: "directory", sha256: nil, mode: try DistributionFileSystem.mode(of: url)))
            } else if resource.isRegularFile == true {
                entries.append(Entry(
                    path: path,
                    kind: "file",
                    sha256: try DistributionHash.sha256(fileURL: url),
                    mode: try DistributionFileSystem.mode(of: url)
                ))
            } else {
                throw DistributionError.unsafePath("Lifecycle prefix contains an unsupported entry type.")
            }
        }
        return PrefixSnapshot(entries: entries)
    }
}
