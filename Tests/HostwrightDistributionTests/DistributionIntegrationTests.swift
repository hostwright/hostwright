import Foundation
import HostwrightCore
@testable import HostwrightDistribution
import XCTest

final class DistributionIntegrationTests: XCTestCase {
    private let baselineCommit = String(repeating: "a", count: 40)
    private let candidateCommit = String(repeating: "b", count: 40)

    func testBuiltDistributionToolRunsBlockedArtifactAndLifecycleEvidence() throws {
        try withTemporaryRoot { root in
            let repository = repositoryRoot()
            let binaries = repository.appendingPathComponent(".build/debug", isDirectory: true)
            let tool = binaries.appendingPathComponent("hostwright-dist")
            let common = [
                "--hostwright-binary", binaries.appendingPathComponent("hostwright").path,
                "--hostwrightd-binary", binaries.appendingPathComponent("hostwrightd").path,
                "--license", repository.appendingPathComponent("LICENSE").path,
                "--readme", repository.appendingPathComponent("README.md").path,
                "--version", HostwrightIdentity.version,
                "--source-dirty", "true",
                "--architecture", "arm64"
            ]
            let baselineDirectory = root.appendingPathComponent("baseline")
            let candidateDirectory = root.appendingPathComponent("candidate")
            var falseCleanClaim = common
            falseCleanClaim[falseCleanClaim.firstIndex(of: "true")!] = "false"
            let rejected = try runExecutable(tool, arguments: [
                "assemble", "--output-dir", root.appendingPathComponent("false-clean").path,
                "--source-commit", baselineCommit
            ] + falseCleanClaim)
            XCTAssertEqual(rejected.status, 64)
            XCTAssertTrue(rejected.error.contains("use build for clean-source evidence"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("false-clean").path))

            let baseline = try runExecutable(tool, arguments: [
                "assemble", "--output-dir", baselineDirectory.path,
                "--source-commit", baselineCommit
            ] + common)
            XCTAssertEqual(baseline.status, 69)
            XCTAssertTrue(baseline.error.contains("HW-DIST-002"))
            let candidate = try runExecutable(tool, arguments: [
                "assemble", "--output-dir", candidateDirectory.path,
                "--source-commit", candidateCommit
            ] + common)
            XCTAssertEqual(candidate.status, 69)

            let missing = try runExecutable(tool, arguments: [
                "verify", "--distribution-dir", root.appendingPathComponent("missing-distribution").path
            ])
            XCTAssertEqual(missing.status, 65)
            XCTAssertTrue(missing.error.contains("HW-DIST-001"))

            let collisionPrefix = root.appendingPathComponent("hostwright-dist-prefix-collision", isDirectory: true)
            try FileManager.default.createDirectory(
                at: collisionPrefix.appendingPathComponent("bin", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("operator-owned".utf8).write(
                to: collisionPrefix.appendingPathComponent("bin/hostwright"),
                options: .withoutOverwriting
            )
            let ownershipRefusal = try runExecutable(tool, arguments: [
                "lifecycle",
                "--baseline-dir", baselineDirectory.path,
                "--candidate-dir", candidateDirectory.path,
                "--prefix", collisionPrefix.path,
                "--report", root.appendingPathComponent("collision-report.json").path
            ])
            XCTAssertEqual(ownershipRefusal.status, 71)
            XCTAssertTrue(ownershipRefusal.error.contains("HW-DIST-001"))
            XCTAssertEqual(
                try String(contentsOf: collisionPrefix.appendingPathComponent("bin/hostwright"), encoding: .utf8),
                "operator-owned"
            )

            let sameRevisionPrefix = root.appendingPathComponent("hostwright-dist-prefix-same", isDirectory: true)
            try FileManager.default.createDirectory(at: sameRevisionPrefix, withIntermediateDirectories: false)
            let lifecycleRefusal = try runExecutable(tool, arguments: [
                "lifecycle",
                "--baseline-dir", baselineDirectory.path,
                "--candidate-dir", baselineDirectory.path,
                "--prefix", sameRevisionPrefix.path,
                "--report", root.appendingPathComponent("same-report.json").path
            ])
            XCTAssertEqual(lifecycleRefusal.status, 72)
            XCTAssertTrue(lifecycleRefusal.error.contains("HW-DIST-001"))

            let verified = try runExecutable(tool, arguments: [
                "verify", "--distribution-dir", candidateDirectory.path
            ])
            XCTAssertEqual(verified.status, 0)
            XCTAssertTrue(verified.output.contains("Verified unsigned distribution artifact"))

            let prefix = root.appendingPathComponent("hostwright-dist-prefix-cli", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let sentinel = prefix.appendingPathComponent("operator-sentinel")
            try Data("keep".utf8).write(to: sentinel, options: .withoutOverwriting)
            let reportURL = root.appendingPathComponent("cli-lifecycle.json")
            let lifecycle = try runExecutable(tool, arguments: [
                "lifecycle",
                "--baseline-dir", baselineDirectory.path,
                "--candidate-dir", candidateDirectory.path,
                "--prefix", prefix.path,
                "--report", reportURL.path
            ])
            XCTAssertEqual(lifecycle.status, 69)
            XCTAssertTrue(lifecycle.output.contains("Stages: 4/4"))
            XCTAssertTrue(lifecycle.error.contains("HW-DIST-002"))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
            let report = try DistributionJSON.decode(DistributionLifecycleReport.self, from: reportURL)
            XCTAssertEqual(report.evidence.status, .blocked)
            XCTAssertEqual(report.evidence.cleanup.status, .succeeded)
        }
    }

    func testActualHostwrightBinariesArchiveVerifyAndLifecyclePreserveUnrelatedFile() throws {
        try withTemporaryRoot { root in
            let baseline = try makeArtifact(root: root, name: "baseline", commit: baselineCommit)
            let candidate = try makeArtifact(root: root, name: "candidate", commit: candidateCommit)
            XCTAssertEqual(baseline.evidence.status, .blocked)
            XCTAssertEqual(candidate.evidence.status, .blocked)

            let verified = try DistributionVerifier().verifyAndCleanup(
                distributionDirectory: root.appendingPathComponent("baseline")
            )
            XCTAssertEqual(verified.archive.sha256.count, 64)
            XCTAssertEqual(verified.sbom.fileName, DistributionLayout.sbomFileName)
            XCTAssertEqual(verified.provenance.fileName, DistributionLayout.provenanceFileName)

            let prefix = root.appendingPathComponent("hostwright-dist-prefix-real", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let operatorDirectory = prefix.appendingPathComponent("operator-data", isDirectory: true)
            try FileManager.default.createDirectory(at: operatorDirectory, withIntermediateDirectories: false)
            let sentinel = operatorDirectory.appendingPathComponent("sentinel.txt")
            try Data("operator-owned\n".utf8).write(to: sentinel, options: .withoutOverwriting)
            let reportURL = root.appendingPathComponent("lifecycle.json")
            let report = try DistributionLifecycleRunner().run(
                baselineDirectory: root.appendingPathComponent("baseline"),
                candidateDirectory: root.appendingPathComponent("candidate"),
                prefix: prefix,
                reportURL: reportURL
            )

            XCTAssertEqual(report.stages.map(\.identifier), ["install", "upgrade", "downgrade", "uninstall"])
            XCTAssertTrue(report.stages.allSatisfy { $0.status == .passed })
            XCTAssertEqual(report.evidence.status, .blocked)
            XCTAssertEqual(report.evidence.cleanup.status, .succeeded)
            XCTAssertTrue(report.evidence.cleanup.exactResourceIdentifiers.contains(
                prefix.appendingPathComponent("share/doc/hostwright").path
            ))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "operator-owned\n")
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: prefix.appendingPathComponent(DistributionLayout.installManifestFileName).path
            ))
            XCTAssertEqual(try DistributionFileSystem.mode(of: reportURL), 0o600)
        }
    }

    func testVerifierRejectsTamperedSidecarAndSymlinkArchive() throws {
        try withTemporaryRoot { root in
            let report = try makeArtifact(root: root, name: "tampered", commit: baselineCommit)
            let distribution = root.appendingPathComponent("tampered")
            let hidden = distribution.appendingPathComponent(".unexpected")
            try Data("hidden".utf8).write(to: hidden, options: .withoutOverwriting)
            XCTAssertThrowsError(try DistributionVerifier().verifyAndCleanup(distributionDirectory: distribution))
            try FileManager.default.removeItem(at: hidden)

            let sbom = distribution.appendingPathComponent(DistributionLayout.sbomFileName)
            let handle = try FileHandle(forWritingTo: sbom)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("tampered".utf8))
            try handle.close()
            XCTAssertThrowsError(try DistributionVerifier().verifyAndCleanup(distributionDirectory: distribution)) {
                XCTAssertEqual($0 as? DistributionError, .checksumMismatch(DistributionLayout.sbomFileName))
            }

            let maliciousRoot = root.appendingPathComponent("malicious", isDirectory: true)
            let artifactRoot = maliciousRoot.appendingPathComponent(report.manifest.artifactID, isDirectory: true)
            try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
            for (index, file) in report.manifest.files.enumerated() {
                let url = artifactRoot.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if index == 0 {
                    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
                } else {
                    try Data("payload".utf8).write(to: url, options: .withoutOverwriting)
                }
            }
            try DistributionFileSystem.writeNewFile(
                try DistributionJSON.encode(report.manifest),
                to: artifactRoot.appendingPathComponent(DistributionLayout.manifestFileName),
                mode: 0o644
            )
            let archive = maliciousRoot.appendingPathComponent("malicious.tar.gz")
            _ = try DistributionProcessRunner().run(
                executablePath: "/usr/bin/tar",
                arguments: ["-czf", archive.path, "-C", maliciousRoot.path, report.manifest.artifactID],
                label: "create symlink rejection archive",
                timeoutSeconds: 30
            )
            XCTAssertThrowsError(
                try DistributionVerifier().validateArchiveTable(archiveURL: archive, manifest: report.manifest)
            )
        }
    }

    func testAtomicUpgradeFailureRestoresVerifiedBaseline() throws {
        try withTemporaryRoot { root in
            _ = try makeArtifact(root: root, name: "baseline", commit: baselineCommit)
            _ = try makeArtifact(root: root, name: "candidate", commit: candidateCommit)
            let baselineExtraction = root.appendingPathComponent("hostwright-dist-baseline-extract")
            let candidateExtraction = root.appendingPathComponent("hostwright-dist-candidate-extract")
            let verifier = DistributionVerifier()
            let baseline = try verifier.verify(
                distributionDirectory: root.appendingPathComponent("baseline"),
                extractionDirectory: baselineExtraction
            )
            let candidate = try verifier.verify(
                distributionDirectory: root.appendingPathComponent("candidate"),
                extractionDirectory: candidateExtraction
            )
            let prefix = root.appendingPathComponent("hostwright-dist-prefix-rollback", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let installer = DistributionInstaller()
            let baselineInstall = try installer.install(artifact: baseline, prefix: prefix)
            _ = try installer.verifyInstalled(prefix: prefix, expectedManifest: baselineInstall)

            let protectedDirectory = prefix.appendingPathComponent("share/doc/hostwright", isDirectory: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: protectedDirectory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protectedDirectory.path) }
            XCTAssertThrowsError(try installer.install(artifact: candidate, prefix: prefix))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protectedDirectory.path)

            _ = try installer.verifyInstalled(prefix: prefix, expectedManifest: baselineInstall)
            _ = try installer.uninstall(prefix: prefix)
        }
    }

    func testUninstallRefusesModifiedOwnedFile() throws {
        try withTemporaryRoot { root in
            _ = try makeArtifact(root: root, name: "artifact", commit: baselineCommit)
            let extraction = root.appendingPathComponent("hostwright-dist-owned-extract")
            let artifact = try DistributionVerifier().verify(
                distributionDirectory: root.appendingPathComponent("artifact"),
                extractionDirectory: extraction
            )
            let prefix = root.appendingPathComponent("hostwright-dist-prefix-owned", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let installer = DistributionInstaller()
            _ = try installer.install(artifact: artifact, prefix: prefix)
            let binary = prefix.appendingPathComponent("bin/hostwright")
            let handle = try FileHandle(forWritingTo: binary)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("modified".utf8))
            try handle.close()

            XCTAssertThrowsError(try installer.uninstall(prefix: prefix)) { error in
                XCTAssertEqual(error as? DistributionError, .installOwnershipMismatch("bin/hostwright"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: binary.path))
        }
    }

    func testUninstallFailureRestoresVerifiedInstalledPayload() throws {
        try withTemporaryRoot { root in
            _ = try makeArtifact(root: root, name: "artifact", commit: baselineCommit)
            let extraction = root.appendingPathComponent("hostwright-dist-uninstall-extract")
            let artifact = try DistributionVerifier().verify(
                distributionDirectory: root.appendingPathComponent("artifact"),
                extractionDirectory: extraction
            )
            let prefix = root.appendingPathComponent("hostwright-dist-prefix-uninstall", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let installer = DistributionInstaller()
            let installed = try installer.install(artifact: artifact, prefix: prefix)
            let protectedDirectory = prefix.appendingPathComponent("share/doc/hostwright", isDirectory: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: protectedDirectory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protectedDirectory.path) }

            XCTAssertThrowsError(try installer.uninstall(prefix: prefix))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protectedDirectory.path)
            _ = try installer.verifyInstalled(prefix: prefix, expectedManifest: installed)
            _ = try installer.uninstall(prefix: prefix)
        }
    }

    func testInstallRejectsSymlinkPayloadParentWithoutWritingOutsidePrefix() throws {
        try withTemporaryRoot { root in
            _ = try makeArtifact(root: root, name: "artifact", commit: baselineCommit)
            let extraction = root.appendingPathComponent("hostwright-dist-symlink-extract")
            let artifact = try DistributionVerifier().verify(
                distributionDirectory: root.appendingPathComponent("artifact"),
                extractionDirectory: extraction
            )
            let prefix = root.appendingPathComponent("hostwright-dist-prefix-symlink", isDirectory: true)
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: prefix.appendingPathComponent("bin"),
                withDestinationURL: outside
            )

            XCTAssertThrowsError(try DistributionInstaller().install(artifact: artifact, prefix: prefix)) { error in
                guard case let DistributionError.unsafePath(message) = error else {
                    return XCTFail("Expected unsafePath, received \(error)")
                }
                XCTAssertTrue(message.contains("bin"))
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
            XCTAssertFalse(DistributionFileSystem.entryExists(outside.appendingPathComponent("hostwright")))
        }
    }

    func testCleanBuilderRejectsRealDirtyGitRepositoryBeforeBuild() throws {
        try withTemporaryRoot { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("// package marker\n".utf8).write(
                to: source.appendingPathComponent("Package.swift"),
                options: .withoutOverwriting
            )
            let runner = DistributionProcessRunner()
            _ = try runner.run(executablePath: "/usr/bin/git", arguments: ["init"], workingDirectory: source, label: "git init")
            _ = try runner.run(executablePath: "/usr/bin/git", arguments: ["add", "Package.swift"], workingDirectory: source, label: "git add")
            _ = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: ["-c", "user.name=Hostwright Tests", "-c", "user.email=tests@invalid", "commit", "-m", "baseline"],
                workingDirectory: source,
                label: "git commit"
            )
            let commit = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: ["rev-parse", "HEAD"],
                workingDirectory: source,
                label: "git rev-parse"
            ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            try Data("dirty\n".utf8).write(
                to: source.appendingPathComponent("untracked.txt"),
                options: .withoutOverwriting
            )

            XCTAssertThrowsError(
                try DistributionCleanBuilder().build(
                    sourceRoot: source,
                    outputDirectory: root.appendingPathComponent("output"),
                    expectedCommit: commit
                )
            ) { error in
                XCTAssertEqual(error as? DistributionError, .dirtySource)
            }
        }
    }

    @discardableResult
    private func makeArtifact(root: URL, name: String, commit: String) throws -> DistributionBuildReport {
        let repository = repositoryRoot()
        let binaries = repository.appendingPathComponent(".build/debug", isDirectory: true)
        return try DistributionAssembler().assemble(
            DistributionAssemblyRequest(
                hostwrightBinary: binaries.appendingPathComponent("hostwright"),
                hostwrightDaemonBinary: binaries.appendingPathComponent("hostwrightd"),
                licenseFile: repository.appendingPathComponent("LICENSE"),
                readmeFile: repository.appendingPathComponent("README.md"),
                outputDirectory: root.appendingPathComponent(name),
                packageVersion: HostwrightIdentity.version,
                sourceCommit: commit,
                sourceDirty: true,
                architecture: "arm64",
                inputStageIdentifier: "prebuilt-validation",
                inputStageDetail: "Executed current Hostwright binaries for local integration only."
            )
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runExecutable(_ executable: URL, arguments: [String]) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let output = LockedData()
        let error = LockedData()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            output.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            error.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        process.waitUntilExit()
        readers.wait()
        return (
            process.terminationStatus,
            String(data: output.value(), encoding: .utf8) ?? "",
            String(data: error.value(), encoding: .utf8) ?? ""
        )
    }

    private func withTemporaryRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-dist-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.withLock { data = value }
    }

    func value() -> Data {
        lock.withLock { data }
    }
}
