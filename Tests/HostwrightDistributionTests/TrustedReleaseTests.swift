import Foundation
import HostwrightCore
@testable import HostwrightDistribution
import XCTest

final class TrustedReleaseTests: XCTestCase {
    func testDeveloperIDParserSelectsOnlyExactApplicationAndInstallerIdentities() throws {
        let applicationFingerprint = String(repeating: "A", count: 40)
        let installerFingerprint = String(repeating: "B", count: 40)
        let output = """
          1) \(applicationFingerprint) "Developer ID Application: Hostwright Project (A1B2C3D4E5)"
          2) \(installerFingerprint) "Developer ID Installer: Hostwright Project (A1B2C3D4E5)"
          3) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC "Apple Development: Ignored (A1B2C3D4E5)"
             3 valid identities found
        """

        let identities = DeveloperIDIdentityParser.parse(output)
        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(identities.map(\.kind), [.application, .installer])
        XCTAssertEqual(identities.map(\.teamIdentifier), ["A1B2C3D4E5", "A1B2C3D4E5"])
        XCTAssertNoThrow(try identities[0].validate())
        XCTAssertNoThrow(try identities[1].validate())
        XCTAssertTrue(DeveloperIDIdentityParser.parse("malformed\n0 valid identities found").isEmpty)
    }

    func testNotarytoolParserRequiresAcceptedUUIDBoundJSON() throws {
        let identifier = UUID().uuidString
        let record = try NotarytoolOutputParser.acceptedRecord(
            output: "{\"id\":\"\(identifier)\",\"status\":\"Accepted\",\"message\":\"ok\"}",
            artifactFileName: "hostwright.zip",
            attachment: .online
        )
        XCTAssertEqual(record.submissionID, identifier)
        XCTAssertThrowsError(
            try NotarytoolOutputParser.acceptedRecord(
                output: "{\"id\":\"\(identifier)\",\"status\":\"Invalid\"}",
                artifactFileName: "hostwright.zip",
                attachment: .online
            )
        )
        XCTAssertThrowsError(
            try NotarytoolOutputParser.acceptedRecord(
                output: "not-json",
                artifactFileName: "hostwright.zip",
                attachment: .online
            )
        )
    }

    func testTrustedManifestAndProvenanceBindEveryPublishedArtifact() throws {
        let manifest = makeManifest()
        XCTAssertNoThrow(try manifest.validate())
        let provenance = makeProvenance(manifest: manifest)
        XCTAssertNoThrow(try provenance.validate(manifest: manifest))

        let wrongPackage = DistributionArtifactDescriptor(
            fileName: manifest.package.fileName,
            sha256: String(repeating: "f", count: 64),
            sizeBytes: manifest.package.sizeBytes
        )
        let changed = TrustedReleaseManifest(
            artifactID: manifest.artifactID,
            packageVersion: manifest.packageVersion,
            releaseTag: manifest.releaseTag,
            sourceCommit: manifest.sourceCommit,
            sourceDirty: false,
            minimumMacOSMajorVersion: manifest.minimumMacOSMajorVersion,
            createdAt: manifest.createdAt,
            applicationSigner: manifest.applicationSigner,
            installerSigner: manifest.installerSigner,
            payloadFiles: manifest.payloadFiles,
            archive: manifest.archive,
            package: wrongPackage,
            archiveSBOM: manifest.archiveSBOM,
            packageSBOM: manifest.packageSBOM,
            provenance: manifest.provenance,
            archiveNotarization: manifest.archiveNotarization,
            packageNotarization: manifest.packageNotarization
        )
        XCTAssertNoThrow(try changed.validate())
        XCTAssertThrowsError(try provenance.validate(manifest: changed))
    }

    func testTrustedSPDXInventoriesArchiveAndPackageWithLicense() throws {
        let trusted = makeManifest()
        let payload = DistributionArtifactManifest(
            artifactID: trusted.artifactID,
            packageVersion: trusted.packageVersion,
            sourceCommit: trusted.sourceCommit,
            sourceDirty: false,
            architecture: trusted.architecture,
            createdAt: trusted.createdAt,
            files: trusted.payloadFiles
        )
        let archive = TrustedReleaseSPDXFactory.make(payloadManifest: payload, artifact: trusted.archive)
        let package = TrustedReleaseSPDXFactory.make(payloadManifest: payload, artifact: trusted.package)
        XCTAssertNoThrow(try archive.validate(
            manifest: payload,
            archive: trusted.archive,
            expectedCreator: "Tool: hostwright-dist-2"
        ))
        XCTAssertNoThrow(try package.validate(
            manifest: payload,
            archive: trusted.package,
            expectedCreator: "Tool: hostwright-dist-2"
        ))
        XCTAssertThrowsError(try archive.validate(manifest: payload, archive: trusted.archive))
        XCTAssertEqual(archive.packages.first?.licenseDeclared, "Apache-2.0")
        XCTAssertTrue(archive.files.allSatisfy { $0.licenseConcluded == "Apache-2.0" })
    }

    func testHomebrewFormulaUsesImmutableArtifactAndCompleteInstalledSurface() throws {
        let manifest = makeManifest()
        let url = "https://github.com/hostwright/hostwright/releases/download/\(manifest.releaseTag)/\(manifest.archive.fileName)"
        let formula = try HomebrewFormulaRenderer.render(
            HomebrewFormulaRequest(manifest: manifest, artifactURL: url)
        )
        XCTAssertTrue(formula.contains("class Hostwright < Formula"))
        XCTAssertTrue(formula.contains("sha256 \"\(manifest.archive.sha256)\""))
        XCTAssertTrue(formula.contains("%w[hostwright hostwright-control hostwrightd]"))
        XCTAssertTrue(formula.contains("service do"))
        XCTAssertTrue(formula.contains("depends_on arch: :arm64"))
        XCTAssertTrue(formula.contains("depends_on macos: :tahoe"))
        XCTAssertTrue(formula.contains("codesign"))

        let rejected = [
            url.replacingOccurrences(of: "https://", with: "http://"),
            "https://github.com/hostwright/hostwright/releases/latest/download/\(manifest.archive.fileName)",
            url + "?download=1",
            url.replacingOccurrences(of: "hostwright/hostwright", with: "attacker/hostwright")
        ]
        for value in rejected {
            XCTAssertThrowsError(
                try HomebrewFormulaRenderer.render(
                    HomebrewFormulaRequest(manifest: manifest, artifactURL: value)
                )
            )
        }
    }

    func testRenderedHomebrewFormulaPassesRealRubyAndHomebrewStyle() throws {
        let manifest = makeManifest()
        let url = "https://github.com/hostwright/hostwright/releases/download/\(manifest.releaseTag)/\(manifest.archive.fileName)"
        let formula = try HomebrewFormulaRenderer.render(
            HomebrewFormulaRequest(manifest: manifest, artifactURL: url)
        )
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: brew.path))
        let tap = "hostwright-test-\(UUID().uuidString.prefix(8).lowercased())/tap"
        let created = try run(brew, arguments: ["tap-new", tap])
        XCTAssertEqual(created.status, 0, created.output)
        defer { _ = try? run(brew, arguments: ["untap", "--force", tap]) }
        let repository = try run(brew, arguments: ["--repository", tap])
        XCTAssertEqual(repository.status, 0, repository.output)
        let formulaURL = URL(
            fileURLWithPath: repository.output.trimmingCharacters(in: .whitespacesAndNewlines),
            isDirectory: true
        ).appendingPathComponent("Formula/hostwright.rb")
        try Data(formula.utf8).write(to: formulaURL, options: .withoutOverwriting)

        let syntax = try run(brew, arguments: ["ruby", "--", "-c", formulaURL.path])
        XCTAssertEqual(syntax.status, 0, syntax.output)
        XCTAssertTrue(syntax.output.contains("Syntax OK"))
        let style = try run(brew, arguments: ["style", "--formula", formulaURL.path])
        XCTAssertEqual(style.status, 0, style.output)
    }

    func testTrustedReleaseRequestRejectsSecretsAndMutableIdentifiersBeforeIO() {
        let request = TrustedReleaseBuildRequest(
            sourceRoot: URL(fileURLWithPath: "/missing"),
            outputDirectory: URL(fileURLWithPath: "/missing-output"),
            expectedCommit: String(repeating: "a", count: 40),
            expectedVersion: "0.0.2-dev",
            releaseTag: "v0.0.2-dev",
            applicationIdentityFingerprint: String(repeating: "A", count: 40),
            installerIdentityFingerprint: String(repeating: "B", count: 40),
            teamIdentifier: "A1B2C3D4E5",
            notaryKeychainProfile: "--password"
        )
        XCTAssertThrowsError(try request.validate())
    }

    func testPreCancelledTrustedReleaseCreatesNoOutputAndReadsNoIdentity() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-trusted-release-cancelled-\(UUID().uuidString)")
        let request = TrustedReleaseBuildRequest(
            sourceRoot: repository,
            outputDirectory: output,
            expectedCommit: String(repeating: "a", count: 40),
            expectedVersion: "0.0.2-dev",
            releaseTag: "v0.0.2-dev",
            applicationIdentityFingerprint: String(repeating: "A", count: 40),
            installerIdentityFingerprint: String(repeating: "B", count: 40),
            teamIdentifier: "A1B2C3D4E5",
            notaryKeychainProfile: "hostwright-release"
        )
        let cancellation = SecureSubprocessCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try TrustedReleaseBuilder().build(request, cancellation: cancellation)) { error in
            XCTAssertEqual(error as? DistributionError, .commandCancelled("trusted release preflight"))
        }
        XCTAssertFalse(DistributionFileSystem.entryExists(output))
    }

    func testCMSSignerInspectorRejectsMalformedAndEmptyInputs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-cms-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let signature = root.appendingPathComponent("signature.cms")
        let content = root.appendingPathComponent("content.json")
        try Data("not-cms".utf8).write(to: signature, options: .withoutOverwriting)
        try Data("{}\n".utf8).write(to: content, options: .withoutOverwriting)
        XCTAssertThrowsError(
            try TrustedCMSSignerInspector.inspect(signature: signature, detachedContent: content)
        )
        try FileManager.default.removeItem(at: signature)
        try Data().write(to: signature, options: .withoutOverwriting)
        XCTAssertThrowsError(
            try TrustedCMSSignerInspector.inspect(signature: signature, detachedContent: content)
        )
    }

    func testDistributionHashHonorsPreCancellation() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-hash-cancel-\(UUID().uuidString)")
        try Data(repeating: 0x41, count: 1_024).write(to: file, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: file) }
        let cancellation = SecureSubprocessCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(
            try DistributionHash.sha256(fileURL: file, cancellation: cancellation)
        ) { error in
            XCTAssertEqual(error as? DistributionError, .commandCancelled("hash distribution file"))
        }
    }

    private func makeManifest() -> TrustedReleaseManifest {
        let version = "0.0.2-dev"
        let commit = String(repeating: "a", count: 40)
        let artifactID = "hostwright-\(version)-macos-arm64-\(commit.prefix(12))"
        let digest = String(repeating: "b", count: 64)
        let application = TrustedReleaseIdentity(
            kind: .application,
            sha1Fingerprint: String(repeating: "A", count: 40),
            commonName: "Developer ID Application: Hostwright Project (A1B2C3D4E5)",
            teamIdentifier: "A1B2C3D4E5"
        )
        let installer = TrustedReleaseIdentity(
            kind: .installer,
            sha1Fingerprint: String(repeating: "B", count: 40),
            commonName: "Developer ID Installer: Hostwright Project (A1B2C3D4E5)",
            teamIdentifier: "A1B2C3D4E5"
        )
        let archive = DistributionArtifactDescriptor(
            fileName: TrustedReleaseLayout.archiveFileName(artifactID: artifactID),
            sha256: digest,
            sizeBytes: 100
        )
        let package = DistributionArtifactDescriptor(
            fileName: TrustedReleaseLayout.packageFileName(artifactID: artifactID),
            sha256: String(repeating: "c", count: 64),
            sizeBytes: 200
        )
        return TrustedReleaseManifest(
            artifactID: artifactID,
            packageVersion: version,
            releaseTag: "v\(version)",
            sourceCommit: commit,
            sourceDirty: false,
            minimumMacOSMajorVersion: 26,
            createdAt: "2026-07-13T12:00:00Z",
            applicationSigner: application,
            installerSigner: installer,
            payloadFiles: DistributionLayout.payloadModes.keys.sorted().map {
                DistributionFileRecord(
                    path: $0,
                    sha256: digest,
                    sizeBytes: 1,
                    mode: DistributionLayout.payloadModes[$0]!
                )
            },
            archive: archive,
            package: package,
            archiveSBOM: DistributionArtifactDescriptor(
                fileName: TrustedReleaseLayout.archiveSBOMFileName(artifactID: artifactID),
                sha256: String(repeating: "d", count: 64),
                sizeBytes: 300
            ),
            packageSBOM: DistributionArtifactDescriptor(
                fileName: TrustedReleaseLayout.packageSBOMFileName(artifactID: artifactID),
                sha256: String(repeating: "e", count: 64),
                sizeBytes: 300
            ),
            provenance: DistributionArtifactDescriptor(
                fileName: TrustedReleaseLayout.provenanceFileName,
                sha256: String(repeating: "f", count: 64),
                sizeBytes: 300
            ),
            archiveNotarization: TrustedNotarizationRecord(
                artifactFileName: archive.fileName,
                submissionID: "11111111-1111-1111-1111-111111111111",
                status: "Accepted",
                ticketAttachment: .online,
                gatekeeperSource: "Notarized Developer ID"
            ),
            packageNotarization: TrustedNotarizationRecord(
                artifactFileName: package.fileName,
                submissionID: "22222222-2222-2222-2222-222222222222",
                status: "Accepted",
                ticketAttachment: .stapled,
                gatekeeperSource: "Notarized Developer ID"
            )
        )
    }

    private func makeProvenance(manifest: TrustedReleaseManifest) -> TrustedReleaseProvenanceStatement {
        TrustedReleaseProvenanceStatement(
            statementType: "https://in-toto.io/Statement/v1",
            subject: [manifest.archive, manifest.package].sorted { $0.fileName < $1.fileName }.map {
                ProvenanceSubject(name: $0.fileName, digest: ["sha256": $0.sha256])
            },
            predicateType: "https://slsa.dev/provenance/v1",
            predicate: DistributionProvenancePredicate(
                buildDefinition: ProvenanceBuildDefinition(
                    buildType: "urn:hostwright:buildtype:swiftpm-developer-id:v1",
                    externalParameters: ProvenanceExternalParameters(
                        configuration: "release",
                        products: ["hostwright", "hostwright-control", "hostwrightd"],
                        platform: "macos",
                        architecture: "arm64"
                    ),
                    internalParameters: ProvenanceInternalParameters(sourceDirty: false, unsigned: false),
                    resolvedDependencies: [
                        ProvenanceResolvedDependency(
                            uri: "git+https://github.com/hostwright/hostwright.git",
                            digest: ["gitCommit": manifest.sourceCommit]
                        )
                    ]
                ),
                runDetails: ProvenanceRunDetails(
                    builder: ProvenanceBuilder(id: "urn:hostwright:builder:release-macos:v1"),
                    metadata: ProvenanceMetadata(
                        invocationId: "33333333-3333-3333-3333-333333333333",
                        startedOn: manifest.createdAt,
                        finishedOn: manifest.createdAt
                    )
                )
            )
        )
    }

    private func run(_ executable: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
