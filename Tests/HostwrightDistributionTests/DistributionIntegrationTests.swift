import Darwin
import Foundation
import HostwrightCore
@testable import HostwrightDistribution
import XCTest

final class DistributionIntegrationTests: XCTestCase {
    private let baselineCommit = String(repeating: "a", count: 40)
    private let candidateCommit = String(repeating: "b", count: 40)

    func testPackageRemoveCLIRefusesBeforeInspectingOrMutatingPrefix() throws {
        try withTemporaryRoot { root in
            let tool = repositoryRoot().appendingPathComponent(".build/debug/hostwright-dist")
            let absentPrefix = root.appendingPathComponent("package-remove-must-not-create")

            let result = try runExecutable(tool, arguments: [
                "package-uninstall",
                "--prefix", absentPrefix.path,
                "--data-policy", "remove",
                "--confirmation", String(repeating: "a", count: 64),
                "--output", "json"
            ])

            XCTAssertEqual(result.status, 64)
            XCTAssertTrue(result.output.isEmpty)
            let error = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(result.error.utf8)) as? [String: Any]
            )
            XCTAssertEqual(error["kind"] as? String, "distributionToolError")
            XCTAssertEqual(error["code"] as? String, "HW-DIST-001")
            XCTAssertEqual(error["exitCode"] as? Int, 64)
            XCTAssertEqual(
                error["message"] as? String,
                DistributionPackagePolicy.removeDataUnsupportedMessage
            )
            XCTAssertFalse(DistributionFileSystem.entryExists(absentPrefix))

            let ignoredConfirmation = try runExecutable(tool, arguments: [
                "package-uninstall",
                "--prefix", absentPrefix.path,
                "--data-policy", "preserve",
                "--confirmation", String(repeating: "a", count: 64),
                "--output", "json"
            ])
            XCTAssertEqual(ignoredConfirmation.status, 64)
            let confirmationError = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(ignoredConfirmation.error.utf8)
                ) as? [String: Any]
            )
            XCTAssertEqual(
                confirmationError["message"] as? String,
                DistributionPackagePolicy.preserveConfirmationUnsupportedMessage
            )
            XCTAssertFalse(DistributionFileSystem.entryExists(absentPrefix))
        }
    }

    func testBuiltDistributionToolRunsBlockedArtifactAndLifecycleEvidence() throws {
        try withTemporaryRoot { root in
            let repository = repositoryRoot()
            let binaries = repository.appendingPathComponent(".build/debug", isDirectory: true)
            let tool = binaries.appendingPathComponent("hostwright-dist")
            let common = [
                "--hostwright-binary", binaries.appendingPathComponent("hostwright").path,
                "--hostwright-control-binary", binaries.appendingPathComponent("hostwright-control").path,
                "--hostwright-containerization-helper-binary",
                binaries.appendingPathComponent("hostwright-containerization-helper").path,
                "--hostwright-dist-binary", binaries.appendingPathComponent("hostwright-dist").path,
                "--hostwrightd-binary", binaries.appendingPathComponent("hostwrightd").path,
                "--containerization-asset-root", root.appendingPathComponent("unused-assets").path,
                "--example-manifest", repository.appendingPathComponent("examples/single-service/hostwright.yaml").path,
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

            let baseline = try makeArtifact(root: root, name: "baseline", commit: baselineCommit)
            let candidate = try makeArtifact(root: root, name: "candidate", commit: candidateCommit)
            XCTAssertEqual(baseline.evidence.status, .blocked)
            XCTAssertEqual(candidate.evidence.status, .blocked)

            let managedPrefix = root.appendingPathComponent("managed-prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: managedPrefix, withIntermediateDirectories: false)
            let toolVersion = try runExecutable(tool, arguments: ["--version"])
            XCTAssertEqual(toolVersion.status, 0)
            XCTAssertEqual(toolVersion.output.trimmingCharacters(in: .whitespacesAndNewlines), HostwrightIdentity.version)

            let installed = try runExecutable(tool, arguments: [
                "install",
                "--developer-distribution-dir", baselineDirectory.path,
                "--prefix", managedPrefix.path,
                "--output", "json"
            ])
            XCTAssertEqual(installed.status, 0, installed.error)
            let installedJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(installed.output.utf8)) as? [String: Any]
            )
            XCTAssertEqual(installedJSON["kind"] as? String, "distributionLifecycleMutation")
            XCTAssertEqual(installedJSON["operation"] as? String, "install")
            let installedCleanup = try XCTUnwrap(installedJSON["cleanup"] as? [String: Any])
            XCTAssertEqual(installedCleanup["status"] as? String, "complete")
            XCTAssertEqual(installedCleanup["pendingPaths"] as? [String], [])

            let inspected = try runExecutable(tool, arguments: [
                "status", "--prefix", managedPrefix.path, "--output", "json"
            ])
            XCTAssertEqual(inspected.status, 0, inspected.error)
            let inspectedJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(inspected.output.utf8)) as? [String: Any]
            )
            XCTAssertEqual(inspectedJSON["readiness"] as? String, "ready")

            let duplicateInstall = try runExecutable(tool, arguments: [
                "install",
                "--developer-distribution-dir", baselineDirectory.path,
                "--prefix", managedPrefix.path,
                "--output", "json"
            ])
            XCTAssertEqual(duplicateInstall.status, 65)
            let duplicateError = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(duplicateInstall.error.utf8)) as? [String: Any]
            )
            XCTAssertEqual(duplicateError["kind"] as? String, "distributionToolError")
            XCTAssertEqual(duplicateError["code"] as? String, "HW-DIST-001")

            let repaired = try runExecutable(tool, arguments: [
                "repair",
                "--developer-distribution-dir", baselineDirectory.path,
                "--prefix", managedPrefix.path,
                "--output", "json"
            ])
            XCTAssertEqual(repaired.status, 0, repaired.error)
            let repairedJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(repaired.output.utf8)) as? [String: Any]
            )
            XCTAssertEqual(repairedJSON["operation"] as? String, "repair")

            let noRollback = try runExecutable(tool, arguments: [
                "rollback", "--prefix", managedPrefix.path, "--output", "json"
            ])
            XCTAssertEqual(noRollback.status, 72)
            let rollbackError = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(noRollback.error.utf8)) as? [String: Any]
            )
            XCTAssertEqual(rollbackError["kind"] as? String, "distributionToolError")

            let uninstalled = try runExecutable(tool, arguments: [
                "uninstall", "--prefix", managedPrefix.path,
                "--data-policy", "preserve", "--output", "json"
            ])
            XCTAssertEqual(uninstalled.status, 0, uninstalled.error)
            let uninstalledJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(uninstalled.output.utf8)) as? [String: Any]
            )
            XCTAssertEqual(uninstalledJSON["kind"] as? String, "distributionUninstallResult")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: managedPrefix.path), [])

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
            XCTAssertEqual(lifecycle.status, 65)
            XCTAssertTrue(lifecycle.error.contains("different source commit"))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
            XCTAssertFalse(DistributionFileSystem.entryExists(reportURL))
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
            XCTAssertThrowsError(
                try DistributionLifecycleRunner().run(
                    baselineDirectory: root.appendingPathComponent("baseline"),
                    candidateDirectory: root.appendingPathComponent("candidate"),
                    prefix: prefix,
                    reportURL: prefix.appendingPathComponent("in-prefix-report.json")
                )
            ) { error in
                XCTAssertEqual(
                    error as? DistributionError,
                    .unsafePath("Lifecycle report must be outside the install prefix.")
                )
            }
            XCTAssertFalse(DistributionFileSystem.entryExists(
                prefix.appendingPathComponent(DistributionLayout.installManifestFileName)
            ))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "operator-owned\n")

            let extraction = root.appendingPathComponent("hostwright-dist-real-lifecycle-extract")
            let artifact = try DistributionVerifier().verify(
                distributionDirectory: root.appendingPathComponent("baseline"),
                extractionDirectory: extraction
            )
            let lifecycle = DistributionInstalledLifecycle()
            _ = try lifecycle.install(artifact: artifact, prefix: prefix)
            _ = try lifecycle.install(artifact: artifact, prefix: prefix)
            _ = try lifecycle.uninstall(prefix: prefix, dataPolicy: .preserve)
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "operator-owned\n")
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: prefix.appendingPathComponent(DistributionLayout.installManifestFileName).path
            ))
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

    func testVerifierAcceptsExactArchiveUnderRestrictiveUmask() throws {
        try withTemporaryRoot { root in
            let report = try makeArtifact(root: root, name: "restrictive-umask", commit: baselineCommit)
            let previousMask = umask(0o077)
            defer { _ = umask(previousMask) }

            let verified = try DistributionVerifier().verifyAndCleanup(
                distributionDirectory: root.appendingPathComponent("restrictive-umask")
            )

            XCTAssertEqual(verified.manifest, report.manifest)
        }
    }

    func testArchiveTableRejectsRegularFileModeThatDiffersFromManifest() throws {
        try withTemporaryRoot { root in
            let report = try makeArtifact(root: root, name: "mode-source", commit: baselineCommit)
            let distribution = root.appendingPathComponent("mode-source")
            let extracted = root.appendingPathComponent("mode-tree", isDirectory: true)
            try DistributionFileSystem.createExclusiveDirectory(extracted)
            let runner = DistributionProcessRunner()
            _ = try runner.run(
                executablePath: "/usr/bin/tar",
                arguments: [
                    "-xzf", distribution.appendingPathComponent(report.archive.fileName).path,
                    "-C", extracted.path
                ],
                label: "extract archive for mode rejection"
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o777],
                ofItemAtPath: extracted.appendingPathComponent(
                    "\(report.manifest.artifactID)/bin/hostwright"
                ).path
            )
            let archive = root.appendingPathComponent("wrong-mode.tar.gz")
            _ = try runner.run(
                executablePath: "/usr/bin/tar",
                arguments: [
                    "-czf", archive.path, "-C", extracted.path, report.manifest.artifactID
                ],
                label: "create wrong-mode archive"
            )

            XCTAssertThrowsError(
                try DistributionVerifier().validateArchiveTable(
                    archiveURL: archive,
                    manifest: report.manifest
                )
            ) { error in
                guard case let DistributionError.invalidArtifact(message) = error else {
                    return XCTFail("Expected invalidArtifact, received \(error)")
                }
                XCTAssertTrue(message.contains("regular-file mode"))
            }
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

            try FileManager.default.removeItem(at: source.appendingPathComponent("untracked.txt"))
            try Data("ignored.txt\n".utf8).write(
                to: source.appendingPathComponent(".gitignore"),
                options: .withoutOverwriting
            )
            _ = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: ["add", ".gitignore"],
                workingDirectory: source,
                label: "git add ignored inventory"
            )
            _ = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: [
                    "-c", "user.name=Hostwright Tests", "-c", "user.email=tests@invalid",
                    "commit", "-m", "ignored inventory"
                ],
                workingDirectory: source,
                label: "git commit ignored inventory"
            )
            let ignoredCommit = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: ["rev-parse", "HEAD"],
                workingDirectory: source,
                label: "git rev-parse ignored inventory"
            ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            try Data("ignored input\n".utf8).write(
                to: source.appendingPathComponent("ignored.txt"),
                options: .withoutOverwriting
            )
            XCTAssertThrowsError(
                try DistributionCleanBuilder().build(
                    sourceRoot: source,
                    outputDirectory: root.appendingPathComponent("ignored-output"),
                    expectedCommit: ignoredCommit
                )
            ) { error in
                XCTAssertEqual(error as? DistributionError, .dirtySource)
            }
        }
    }

    func testCleanBuilderProducesIdenticalPayloadManifestFromIsolatedReleaseBuilds() throws {
        try withTemporaryRoot { root in
            let repository = repositoryRoot()
            let source = root.appendingPathComponent("source", isDirectory: true)
            let runner = DistributionProcessRunner()
            _ = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: ["clone", "--quiet", "--local", "--no-hardlinks", repository.path, source.path],
                label: "clone clean source snapshot"
            )
            let commit = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: ["-C", source.path, "rev-parse", "HEAD"],
                label: "read clean source snapshot commit"
            ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

            let builder = DistributionCleanBuilder(
                containerizationAssets: try makeDistributionTestContainerizationAssets(at: root)
            )
            let firstOutput = root.appendingPathComponent("first-output", isDirectory: true)
            let secondOutput = root.appendingPathComponent("second-output", isDirectory: true)
            XCTAssertNotEqual(firstOutput, secondOutput)
            let first = try builder.buildWithDependencyInventory(
                sourceRoot: source,
                outputDirectory: firstOutput,
                expectedCommit: commit
            )
            let firstScratch = try XCTUnwrap(first.report.evidence.cleanup.exactResourceIdentifiers.first)
            XCTAssertFalse(DistributionFileSystem.entryExists(URL(fileURLWithPath: firstScratch)))
            let second = try builder.buildWithDependencyInventory(
                sourceRoot: source,
                outputDirectory: secondOutput,
                expectedCommit: commit
            )

            XCTAssertEqual(first.externalSwiftPMDependencies, second.externalSwiftPMDependencies)
            XCTAssertEqual(
                first.externalSwiftPMDependencies,
                first.externalSwiftPMDependencies.sorted()
            )
            XCTAssertTrue(
                first.externalSwiftPMDependencies.contains {
                    $0 == "containerization|https://github.com/apple/containerization.git|\(DistributionContainerizationAssets.frameworkVersion)|\(DistributionContainerizationAssets.frameworkRevision)"
                }
            )
            let secondScratch = try XCTUnwrap(second.report.evidence.cleanup.exactResourceIdentifiers.first)
            XCTAssertEqual(first.report.evidence.cleanup.exactResourceIdentifiers.count, 1)
            XCTAssertEqual(second.report.evidence.cleanup.exactResourceIdentifiers.count, 1)
            XCTAssertEqual(firstScratch, secondScratch)
            XCTAssertTrue(URL(fileURLWithPath: firstScratch).lastPathComponent.hasPrefix(
                "hostwright-dist-clean-scratch-"
            ))
            XCTAssertFalse(DistributionFileSystem.entryExists(URL(fileURLWithPath: secondScratch)))
            XCTAssertEqual(first.report.manifest.files, second.report.manifest.files)
            let payloadPaths = Set(first.report.manifest.files.map(\.path))
            XCTAssertTrue(Set(DistributionLayout.shippedBinaryPaths).isSubset(of: payloadPaths))
        }
    }

    func testCleanBuilderLeaseRejectsConcurrentStructCopyWithoutDeletingActiveScratch() throws {
        try withTemporaryRoot { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let scratch = root.appendingPathComponent(
                "hostwright-dist-clean-scratch-\(UUID().uuidString)",
                isDirectory: true
            )
            let firstOutput = root.appendingPathComponent("first-output", isDirectory: true)
            let secondOutput = root.appendingPathComponent("second-output", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let slowManifest = """
            // swift-tools-version: 6.2
            import Foundation
            import PackageDescription

            Thread.sleep(forTimeInterval: 30)
            let package = Package(name: "ConcurrentCleanBuildFixture")
            """ + "\n"
            try Data(slowManifest.utf8).write(
                to: source.appendingPathComponent("Package.swift"),
                options: .withoutOverwriting
            )
            let runner = DistributionProcessRunner()
            _ = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: ["init", "--quiet", source.path],
                label: "initialize concurrent clean-build source"
            )
            _ = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: ["-C", source.path, "add", "Package.swift"],
                label: "stage concurrent clean-build source"
            )
            _ = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: [
                    "-C", source.path,
                    "-c", "user.name=Hostwright Tests",
                    "-c", "user.email=tests@invalid",
                    "commit", "--quiet", "-m", "concurrent clean-build fixture"
                ],
                label: "commit concurrent clean-build source"
            )
            let commit = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: ["-C", source.path, "rev-parse", "HEAD"],
                label: "read concurrent clean-build commit"
            ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

            let builder = DistributionCleanBuilder(compilerScratchPath: scratch)
            let copiedBuilder = builder
            let cancellation = SecureSubprocessCancellation()
            let firstFinished = DispatchGroup()
            let firstError = LockedData()
            firstFinished.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { firstFinished.leave() }
                do {
                    _ = try builder.buildWithDependencyInventory(
                        sourceRoot: source,
                        outputDirectory: firstOutput,
                        expectedCommit: commit,
                        cancellation: cancellation
                    )
                } catch {
                    firstError.set(Data(String(describing: error).utf8))
                }
            }
            defer {
                cancellation.cancel()
                _ = firstFinished.wait(timeout: .now() + 10)
            }

            let scratchDeadline = Date().addingTimeInterval(10)
            while !DistributionFileSystem.entryExists(scratch), Date() < scratchDeadline {
                usleep(10_000)
            }
            XCTAssertTrue(try DistributionFileSystem.isDirectoryNonSymlink(scratch))
            var identityBefore = stat()
            XCTAssertEqual(lstat(scratch.path, &identityBefore), 0)

            XCTAssertThrowsError(
                try copiedBuilder.buildWithDependencyInventory(
                    sourceRoot: source,
                    outputDirectory: secondOutput,
                    expectedCommit: commit
                )
            ) { error in
                XCTAssertEqual(
                    error as? DistributionError,
                    .invalidArguments("A clean distribution build is already active for this builder.")
                )
            }

            var identityAfter = stat()
            XCTAssertEqual(lstat(scratch.path, &identityAfter), 0)
            XCTAssertEqual(identityAfter.st_dev, identityBefore.st_dev)
            XCTAssertEqual(identityAfter.st_ino, identityBefore.st_ino)
            XCTAssertFalse(DistributionFileSystem.entryExists(secondOutput))

            cancellation.cancel()
            XCTAssertEqual(firstFinished.wait(timeout: .now() + 10), .success)
            XCTAssertTrue(String(data: firstError.value(), encoding: .utf8)?.contains("cancelled") == true)
            XCTAssertFalse(DistributionFileSystem.entryExists(scratch))
            XCTAssertFalse(DistributionFileSystem.entryExists(firstOutput))
            XCTAssertFalse(DistributionFileSystem.entryExists(secondOutput))
        }
    }

    func testDistributionToolSignalCancelsBuildWithoutPublishingOutput() throws {
        try withTemporaryRoot { root in
            let repository = repositoryRoot()
            let source = root.appendingPathComponent("source", isDirectory: true)
            let runtime = root.appendingPathComponent("runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
            let slowManifest = """
            // swift-tools-version: 6.2
            import Foundation
            import PackageDescription

            Thread.sleep(forTimeInterval: 30)
            let package = Package(name: "SignalCancellationFixture")
            """ + "\n"
            try Data(slowManifest.utf8).write(
                to: source.appendingPathComponent("Package.swift"),
                options: .withoutOverwriting
            )
            let runner = DistributionProcessRunner()
            _ = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: ["init", "--quiet", source.path],
                label: "initialize signal-cancellation source"
            )
            _ = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: ["-C", source.path, "add", "Package.swift"],
                label: "stage signal-cancellation source"
            )
            _ = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: [
                    "-C", source.path,
                    "-c", "user.name=Hostwright Tests",
                    "-c", "user.email=tests@invalid",
                    "commit", "--quiet", "-m", "signal cancellation fixture"
                ],
                label: "commit signal-cancellation source"
            )
            let commit = try runner.run(
                executablePath: "/usr/bin/git",
                arguments: ["-C", source.path, "rev-parse", "HEAD"],
                label: "read signal-cancellation source commit"
            ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

            let process = Process()
            process.executableURL = repository.appendingPathComponent(".build/debug/hostwright-dist")
            process.arguments = [
                "build",
                "--source-root", source.path,
                "--output-dir", root.appendingPathComponent("output").path,
                "--expected-commit", commit
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["TMPDIR"] = runtime.path + "/"
            process.environment = environment
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

            usleep(250_000)
            XCTAssertTrue(process.isRunning)
            XCTAssertEqual(Darwin.kill(process.processIdentifier, SIGTERM), 0)
            process.waitUntilExit()
            readers.wait()

            XCTAssertEqual(process.terminationStatus, 69)
            XCTAssertTrue((String(data: error.value(), encoding: .utf8) ?? "").contains("cancelled"))
            XCTAssertTrue(output.value().isEmpty)
            XCTAssertFalse(DistributionFileSystem.entryExists(root.appendingPathComponent("output")))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: runtime.path).isEmpty)
        }
    }

    @discardableResult
    private func makeArtifact(root: URL, name: String, commit: String) throws -> DistributionBuildReport {
        let repository = repositoryRoot()
        let binaries = repository.appendingPathComponent(".build/debug", isDirectory: true)
        return try DistributionAssembler().assemble(
            DistributionAssemblyRequest(
                hostwrightBinary: binaries.appendingPathComponent("hostwright"),
                hostwrightControlBinary: binaries.appendingPathComponent("hostwright-control"),
                hostwrightContainerizationHelperBinary: binaries
                    .appendingPathComponent("hostwright-containerization-helper"),
                hostwrightDistributionBinary: binaries.appendingPathComponent("hostwright-dist"),
                hostwrightDaemonBinary: binaries.appendingPathComponent("hostwrightd"),
                containerizationAssets: try makeDistributionTestContainerizationAssets(at: root),
                exampleManifestFile: repository.appendingPathComponent("examples/single-service/hostwright.yaml"),
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
