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

    func testNotarytoolLogParserRequiresExactArchiveTicketContents() throws {
        let archiveName = "hostwright-0.0.2-dev.1-macos-arm64-640e54d43d3f.zip"
        let hostwrightPath = "\(archiveName)/hostwright-0.0.2-dev.1-macos-arm64-640e54d43d3f/bin/hostwright"
        let controlPath = "\(archiveName)/hostwright-0.0.2-dev.1-macos-arm64-640e54d43d3f/bin/hostwright-control"
        let hostwrightHash = String(repeating: "a", count: 40)
        let controlHash = String(repeating: "b", count: 40)
        let output = """
        {
          "status": "Accepted",
          "archiveFilename": "\(archiveName)",
          "ticketContents": [
            {
              "path": "\(controlPath)",
              "digestAlgorithm": "SHA-256",
              "cdhash": "\(controlHash)",
              "arch": "arm64"
            },
            {
              "path": "\(hostwrightPath)",
              "digestAlgorithm": "SHA-256",
              "cdhash": "\(hostwrightHash)",
              "arch": "arm64"
            }
          ]
        }
        """

        XCTAssertNoThrow(try NotarytoolLogParser.requireAcceptedTicketContents(
            output: output,
            archiveFileName: archiveName,
            expectedTickets: [
                TrustedNotaryTicketExpectation(path: hostwrightPath, cdHash: hostwrightHash),
                TrustedNotaryTicketExpectation(path: controlPath, cdHash: controlHash)
            ]
        ))
    }

    func testNotarytoolLogParserRejectsIncompleteOrMismatchedArchiveTickets() throws {
        let archiveName = "hostwright.zip"
        let executablePath = "hostwright.zip/hostwright/bin/hostwright"
        let expected = [
            TrustedNotaryTicketExpectation(path: executablePath, cdHash: String(repeating: "a", count: 40))
        ]
        let mismatchedHash = """
        {
          "status": "Accepted",
          "archiveFilename": "\(archiveName)",
          "ticketContents": [
            {
              "path": "\(executablePath)",
              "digestAlgorithm": "SHA-256",
              "cdhash": "\(String(repeating: "b", count: 40))",
              "arch": "arm64"
            }
          ]
        }
        """
        XCTAssertThrowsError(try NotarytoolLogParser.requireAcceptedTicketContents(
            output: mismatchedHash,
            archiveFileName: archiveName,
            expectedTickets: expected
        ))

        let missingTicket = """
        {
          "status": "Accepted",
          "archiveFilename": "\(archiveName)",
          "ticketContents": []
        }
        """
        XCTAssertThrowsError(try NotarytoolLogParser.requireAcceptedTicketContents(
            output: missingTicket,
            archiveFileName: archiveName,
            expectedTickets: expected
        ))

        let malformedTicket = """
        {
          "status": "Accepted",
          "archiveFilename": "\(archiveName)",
          "ticketContents": [
            {
              "path": "\(executablePath)",
              "digestAlgorithm": "SHA-1",
              "cdhash": "\(String(repeating: "a", count: 40))",
              "arch": "arm64"
            }
          ]
        }
        """
        XCTAssertThrowsError(try NotarytoolLogParser.requireAcceptedTicketContents(
            output: malformedTicket,
            archiveFileName: archiveName,
            expectedTickets: expected
        ))

        let duplicateTicket = """
        {
          "status": "Accepted",
          "archiveFilename": "\(archiveName)",
          "ticketContents": [
            {
              "path": "\(executablePath)",
              "digestAlgorithm": "SHA-256",
              "cdhash": "\(String(repeating: "a", count: 40))",
              "arch": "arm64"
            },
            {
              "path": "\(executablePath)",
              "digestAlgorithm": "SHA-256",
              "cdhash": "\(String(repeating: "a", count: 40))",
              "arch": "arm64"
            }
          ]
        }
        """
        XCTAssertThrowsError(try NotarytoolLogParser.requireAcceptedTicketContents(
            output: duplicateTicket,
            archiveFileName: archiveName,
            expectedTickets: expected
        ))
    }

    func testTrustedManifestAndProvenanceBindEveryPublishedArtifact() throws {
        let manifest = makeManifest()
        XCTAssertNoThrow(try manifest.validate())
        let provenance = makeProvenance(manifest: manifest)
        XCTAssertNoThrow(try provenance.validate(manifest: manifest))
        let internalParameters = provenance.predicate.buildDefinition.internalParameters
        XCTAssertEqual(
            internalParameters.externalSwiftPMDependencies,
            trustedSwiftPMDependencies()
        )
        XCTAssertEqual(internalParameters.packageLicenseSPDX, "Apache-2.0")
        XCTAssertEqual(internalParameters.reproducibilityBuildCount, 2)
        XCTAssertEqual(internalParameters.byteIdenticalUnsignedPayloads, true)
        XCTAssertEqual(internalParameters.toolVersions, trustedToolVersions())
        let expectedBuildMetadata = TrustedReleaseBuildMetadata(
            externalSwiftPMDependencies: try XCTUnwrap(internalParameters.externalSwiftPMDependencies),
            packageLicenseSPDX: try XCTUnwrap(internalParameters.packageLicenseSPDX),
            reproducibilityBuildCount: try XCTUnwrap(internalParameters.reproducibilityBuildCount),
            byteIdenticalUnsignedPayloads: try XCTUnwrap(
                internalParameters.byteIdenticalUnsignedPayloads
            ),
            toolVersions: try XCTUnwrap(internalParameters.toolVersions)
        )
        XCTAssertNoThrow(
            try provenance.validate(
                manifest: manifest,
                expectedBuildMetadata: expectedBuildMetadata
            )
        )
        XCTAssertThrowsError(
            try provenance.validate(
                manifest: manifest,
                expectedBuildMetadata: TrustedReleaseBuildMetadata(
                    externalSwiftPMDependencies: trustedSwiftPMDependencies(),
                    packageLicenseSPDX: "Apache-2.0",
                    reproducibilityBuildCount: 3,
                    byteIdenticalUnsignedPayloads: true,
                    toolVersions: trustedToolVersions()
                )
            )
        )

        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: DistributionJSON.encode(provenance)) as? [String: Any]
        )
        XCTAssertEqual(Set(envelope.keys), Set(["_type", "subject", "predicateType", "predicate"]))
        let predicate = try XCTUnwrap(envelope["predicate"] as? [String: Any])
        let buildDefinition = try XCTUnwrap(predicate["buildDefinition"] as? [String: Any])
        let encodedInternalParameters = try XCTUnwrap(
            buildDefinition["internalParameters"] as? [String: Any]
        )
        XCTAssertEqual(
            encodedInternalParameters["externalSwiftPMDependencies"] as? [String],
            trustedSwiftPMDependencies()
        )
        XCTAssertNil(envelope["buildMetadata"])

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

        let alteredMetadata = ProvenanceInternalParameters(
            sourceDirty: false,
            unsigned: false,
            externalSwiftPMDependencies: ["https://example.invalid/unrecorded"],
            packageLicenseSPDX: "Apache-2.0",
            reproducibilityBuildCount: 2,
            byteIdenticalUnsignedPayloads: true,
            toolVersions: trustedToolVersions()
        )
        let alteredProvenance = TrustedReleaseProvenanceStatement(
            statementType: provenance.statementType,
            subject: provenance.subject,
            predicateType: provenance.predicateType,
            predicate: DistributionProvenancePredicate(
                buildDefinition: ProvenanceBuildDefinition(
                    buildType: provenance.predicate.buildDefinition.buildType,
                    externalParameters: provenance.predicate.buildDefinition.externalParameters,
                    internalParameters: alteredMetadata,
                    resolvedDependencies: provenance.predicate.buildDefinition.resolvedDependencies
                ),
                runDetails: provenance.predicate.runDetails
            )
        )
        XCTAssertThrowsError(try alteredProvenance.validate(manifest: manifest))

        var driftedToolVersions = trustedToolVersions()
        driftedToolVersions["swift"] = "Swift version changed during build"
        XCTAssertThrowsError(
            try provenance.validate(
                manifest: manifest,
                expectedBuildMetadata: TrustedReleaseBuildMetadata(
                    externalSwiftPMDependencies: trustedSwiftPMDependencies(),
                    packageLicenseSPDX: "Apache-2.0",
                    reproducibilityBuildCount: 2,
                    byteIdenticalUnsignedPayloads: true,
                    toolVersions: driftedToolVersions
                )
            )
        )
    }

    func testTrustedReleaseRequiresMatchingActualToolVersionsFromBothCleanBuilds() throws {
        let builder = TrustedReleaseBuilder()
        var cleanBuildVersions = trustedToolVersions()
        cleanBuildVersions["hostwright-dist"] = "1"
        XCTAssertEqual(
            try builder.requireMatchingToolVersions([cleanBuildVersions, cleanBuildVersions]),
            trustedToolVersions()
        )

        var drifted = cleanBuildVersions
        drifted["notarytool"] = "notarytool changed"
        XCTAssertThrowsError(try builder.requireMatchingToolVersions([cleanBuildVersions, drifted]))

        var unavailable = cleanBuildVersions
        unavailable["tar"] = "unavailable"
        XCTAssertThrowsError(try builder.requireMatchingToolVersions([cleanBuildVersions, unavailable]))
    }

    func testCleanBuildArgumentsUseOneDeterministicReleaseContract() {
        let source = URL(fileURLWithPath: "/private/tmp/source with space", isDirectory: true)
        let scratch = URL(fileURLWithPath: "/private/tmp/scratch with space", isDirectory: true)
        let prefixMap = "\(scratch.path)=/hostwright-build"

        let productArguments = DistributionCleanBuilder.deterministicReleaseBuildArguments(
            sourceRoot: source,
            scratch: scratch,
            additionalArguments: ["--product", "hostwright"]
        )
        XCTAssertEqual(
            productArguments,
            [
                "build",
                "--package-path", source.path,
                "--scratch-path", scratch.path,
                "-c", "release",
                "--jobs", "1",
                "-debug-info-format", "none",
                "-Xlinker", "-reproducible",
                "-Xswiftc", "-num-threads",
                "-Xswiftc", "1",
                "-Xswiftc", "-file-prefix-map",
                "-Xswiftc", prefixMap,
                "-Xcc", "-ffile-prefix-map=\(prefixMap)",
                "-Xcc", "-fmacro-prefix-map=\(prefixMap)",
                "-Xcxx", "-ffile-prefix-map=\(prefixMap)",
                "-Xcxx", "-fmacro-prefix-map=\(prefixMap)",
                "--product", "hostwright"
            ]
        )

        let binPathArguments = DistributionCleanBuilder.deterministicReleaseBuildArguments(
            sourceRoot: source,
            scratch: scratch,
            additionalArguments: ["--show-bin-path"]
        )
        XCTAssertEqual(
            binPathArguments,
            Array(productArguments.dropLast(2)) + ["--show-bin-path"]
        )
    }

    func testCleanBuildCommandEvidenceRecordsExactDeterministicInvocation() {
        let arguments = DistributionCleanBuilder.deterministicReleaseBuildArguments(
            sourceRoot: URL(fileURLWithPath: "/private/tmp/source with space", isDirectory: true),
            scratch: URL(fileURLWithPath: "/private/tmp/scratch with space", isDirectory: true),
            additionalArguments: ["--product", "hostwright"]
        )

        let command = DistributionCleanBuilder.evidenceCommand(
            executablePath: "/usr/bin/swift",
            arguments: arguments
        )
        XCTAssertEqual(
            command,
            "/usr/bin/swift build --package-path '/private/tmp/source with space' " +
                "--scratch-path '/private/tmp/scratch with space' -c release " +
                "--jobs 1 -debug-info-format none -Xlinker -reproducible " +
                "-Xswiftc -num-threads -Xswiftc 1 -Xswiftc -file-prefix-map " +
                "-Xswiftc '/private/tmp/scratch with space=/hostwright-build' " +
                "-Xcc '-ffile-prefix-map=/private/tmp/scratch with space=/hostwright-build' " +
                "-Xcc '-fmacro-prefix-map=/private/tmp/scratch with space=/hostwright-build' " +
                "-Xcxx '-ffile-prefix-map=/private/tmp/scratch with space=/hostwright-build' " +
                "-Xcxx '-fmacro-prefix-map=/private/tmp/scratch with space=/hostwright-build' " +
                "--product hostwright"
        )
    }

    func testReproducibilityMismatchNamesSortedDifferingPayloadPaths() throws {
        let builder = TrustedReleaseBuilder()
        let first = [
            fileRecord(path: "bin/changed", sha256: String(repeating: "a", count: 64), sizeBytes: 10, mode: 0o755),
            fileRecord(path: "bin/missing", sha256: String(repeating: "b", count: 64), sizeBytes: 11, mode: 0o755),
            fileRecord(path: "share/same", sha256: String(repeating: "c", count: 64), sizeBytes: 12, mode: 0o644)
        ]
        let second = [
            fileRecord(path: "bin/changed", sha256: String(repeating: "d", count: 64), sizeBytes: 13, mode: 0o644),
            fileRecord(path: "bin/extra", sha256: String(repeating: "e", count: 64), sizeBytes: 14, mode: 0o755),
            fileRecord(path: "share/same", sha256: String(repeating: "c", count: 64), sizeBytes: 12, mode: 0o644)
        ]

        let description = try XCTUnwrap(builder.payloadMismatchDescription(first: first, second: second))
        XCTAssertTrue(description.contains("missing from second: bin/missing"))
        XCTAssertTrue(description.contains("extra in second: bin/extra"))
        XCTAssertTrue(description.contains(
            "bin/changed: first(size=10, sha256=\(String(repeating: "a", count: 64)), mode=0o755)"
        ))
        XCTAssertTrue(description.contains(
            "second(size=13, sha256=\(String(repeating: "d", count: 64)), mode=0o644)"
        ))
        XCTAssertLessThan(
            try XCTUnwrap(description.range(of: "missing from second")?.lowerBound),
            try XCTUnwrap(description.range(of: "extra in second")?.lowerBound)
        )
    }

    func testCleanBuildDependencyInventoryUsesParsedSwiftPMGraph() throws {
        let builder = DistributionCleanBuilder()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-dependency-inventory-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = root.appendingPathComponent("Package.resolved")
        let resolvedText = """
        {
          "pins": [
            {
              "identity": "containerization",
              "kind": "remoteSourceControl",
              "location": "https://github.com/apple/containerization.git",
              "state": {
                "revision": "\(DistributionContainerizationAssets.frameworkRevision)",
                "version": "\(DistributionContainerizationAssets.frameworkVersion)"
              }
            },
            {
              "identity": "swift-nio",
              "kind": "remoteSourceControl",
              "location": "https://github.com/apple/swift-nio.git",
              "state": {
                "revision": "\(String(repeating: "a", count: 40))",
                "version": "2.101.3"
              }
            },
            {
              "identity": "swift-nio-extras",
              "kind": "remoteSourceControl",
              "location": "https://github.com/apple/swift-nio-extras.git",
              "state": {
                "revision": "\(String(repeating: "b", count: 40))",
                "version": "1.34.3"
              }
            }
          ],
          "version": 3
        }
        """
        try Data(resolvedText.utf8).write(to: resolved, options: .withoutOverwriting)
        let graph = #"{"dependencies":[{"identity":"containerization","url":"https://github.com/apple/containerization.git","version":"0.35.0","dependencies":[{"identity":"swift-nio","url":"https://github.com/apple/swift-nio.git","version":"2.101.3","dependencies":[]},{"identity":"swift-nio-extras","url":"https://github.com/apple/swift-nio-extras.git","version":"1.34.3","dependencies":[]}]}]}"#
        XCTAssertEqual(
            try builder.requirePinnedExternalDependencies(graph, resolvedFile: resolved),
            [
                "containerization|https://github.com/apple/containerization.git|0.35.0|\(DistributionContainerizationAssets.frameworkRevision)",
                "swift-nio-extras|https://github.com/apple/swift-nio-extras.git|1.34.3|\(String(repeating: "b", count: 40))",
                "swift-nio|https://github.com/apple/swift-nio.git|2.101.3|\(String(repeating: "a", count: 40))"
            ]
        )
        XCTAssertThrowsError(
            try builder.requirePinnedExternalDependencies(
                #"{"dependencies":[{"identity":"containerization","url":"https://github.com/apple/containerization.git","version":"0.35.1","dependencies":[]}]}"#,
                resolvedFile: resolved
            )
        )
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
        XCTAssertTrue(formula.contains(
            "%w[hostwright hostwright-control hostwright-containerization-helper hostwright-dist hostwrightd]"
        ))
        XCTAssertTrue(formula.contains("pkgshare.install \"share/hostwright/containerization\""))
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

    func testVerifierRejectsUntrustedTeamAndMissingReleaseInventory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-trusted-release-incomplete-\(UUID().uuidString)")
        try DistributionFileSystem.createExclusiveDirectory(root)
        defer { try? DistributionFileSystem.removeOwnedTemporaryItem(root) }
        try DistributionFileSystem.writeNewFile(
            try DistributionJSON.encode(makeManifest()),
            to: root.appendingPathComponent(TrustedReleaseLayout.manifestFileName),
            mode: 0o644
        )

        XCTAssertThrowsError(
            try TrustedReleaseVerifier().verify(
                releaseDirectory: root,
                expectedTeamIdentifier: "Z9Y8X7W6V5"
            )
        ) { error in
            XCTAssertEqual(
                error as? DistributionError,
                .invalidArtifact("release signer team does not match the verifier trust policy")
            )
        }
        XCTAssertThrowsError(
            try TrustedReleaseVerifier().verify(
                releaseDirectory: root,
                expectedTeamIdentifier: "A1B2C3D4E5"
            )
        ) { error in
            XCTAssertEqual(
                error as? DistributionError,
                .invalidArtifact("release directory inventory is incomplete or contains unexpected entries")
            )
        }

        for name in [
            makeManifest().archive.fileName,
            makeManifest().package.fileName,
            makeManifest().archiveSBOM.fileName,
            makeManifest().packageSBOM.fileName,
            TrustedReleaseLayout.provenanceFileName,
            TrustedReleaseLayout.manifestSignatureFileName,
            TrustedReleaseLayout.checksumFileName,
            TrustedReleaseLayout.checksumSignatureFileName,
            TrustedReleaseLayout.provenanceSignatureFileName,
            TrustedReleaseLayout.evidenceFileName,
            TrustedReleaseLayout.evidenceSignatureFileName
        ] {
            try DistributionFileSystem.writeNewFile(
                Data("inventory-entry".utf8),
                to: root.appendingPathComponent(name),
                mode: name == TrustedReleaseLayout.evidenceFileName ? 0o600 : 0o644
            )
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(makeManifest().artifactID, isDirectory: true),
            withIntermediateDirectories: false
        )
        XCTAssertThrowsError(
            try TrustedReleaseVerifier().verify(
                releaseDirectory: root,
                expectedTeamIdentifier: "A1B2C3D4E5"
            )
        ) { error in
            XCTAssertEqual(
                error as? DistributionError,
                .invalidArtifact("release directory inventory is incomplete or contains unexpected entries")
            )
        }
    }

    func testStructuredReleaseOutputsAndRetentionPolicyAreStable() throws {
        let report = makeReport()
        XCTAssertNoThrow(try report.retentionPolicy.validate())
        XCTAssertEqual(report.retentionPolicy.workflowBundleDays, 90)
        XCTAssertEqual(report.retentionPolicy.publishedReleaseAssets, "indefinite")
        XCTAssertEqual(report.retentionPolicy.publishedReleaseEvidence, "indefinite")

        let release = TrustedReleaseCommandOutput(
            report: report,
            releaseDirectory: "/tmp/hostwright-release-output"
        )
        let cleanup = HostwrightEvidenceCleanup(
            status: .succeeded,
            exactResourceIdentifiers: ["/tmp/hostwright-dist-release-verification"]
        )
        let verification = TrustedReleaseVerificationCommandOutput(
            result: TrustedReleaseVerificationResult(
                manifest: report.manifest,
                commands: [HostwrightEvidenceCommand(command: "verify", exitCode: 0, durationMilliseconds: 1)],
                cleanup: cleanup
            )
        )
        let formula = HomebrewFormulaCommandOutput(
            manifest: report.manifest,
            outputFile: "/tmp/Formula/hostwright.rb"
        )

        let releaseJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: DistributionJSON.encode(release)) as? [String: Any]
        )
        let verificationJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: DistributionJSON.encode(verification)) as? [String: Any]
        )
        let formulaJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: DistributionJSON.encode(formula)) as? [String: Any]
        )
        XCTAssertEqual(releaseJSON["schemaVersion"] as? Int, 1)
        XCTAssertEqual(releaseJSON["kind"] as? String, "trustedRelease")
        XCTAssertEqual(releaseJSON["sourceCommit"] as? String, report.manifest.sourceCommit)
        XCTAssertNotNil(releaseJSON["retentionPolicy"] as? [String: Any])
        XCTAssertEqual(verificationJSON["kind"] as? String, "trustedReleaseVerification")
        XCTAssertEqual(verificationJSON["verificationCommandCount"] as? Int, 1)
        XCTAssertEqual(formulaJSON["kind"] as? String, "homebrewFormula")
        let formulaArchive = try XCTUnwrap(formulaJSON["archive"] as? [String: Any])
        XCTAssertEqual(formulaArchive["sha256"] as? String, report.manifest.archive.sha256)

        let workflow = try String(
            contentsOf: packageRoot().appendingPathComponent(".github/workflows/trusted-release.yml"),
            encoding: .utf8
        )
        XCTAssertEqual(workflow.components(separatedBy: "retention-days: 90").count - 1, 1)
        let runScripts = workflowRunScriptBodies(workflow)
        XCTAssertFalse(runScripts.contains("${{ inputs."))
        XCTAssertEqual(workflow.components(separatedBy: "RELEASE_COMMIT: ${{ inputs.commit }}").count - 1, 3)
        XCTAssertEqual(workflow.components(separatedBy: "RELEASE_VERSION: ${{ inputs.version }}").count - 1, 3)
        XCTAssertEqual(workflow.components(separatedBy: "RELEASE_TAG: ${{ inputs.tag }}").count - 1, 3)
        XCTAssertTrue(workflow.contains("release-evidence.json.cms"))
        XCTAssertTrue(workflow.contains(")\" = 12"))
        XCTAssertTrue(workflow.contains("failure() || cancelled()"))
        XCTAssertFalse(workflow.contains("steps.publish.outputs.tag_created"))
        XCTAssertTrue(workflow.contains("resolved_commit\" != \"$RELEASE_COMMIT"))
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
                        products: DistributionLayout.shippedExecutableNames,
                        platform: "macos",
                        architecture: "arm64"
                    ),
                    internalParameters: ProvenanceInternalParameters(
                        sourceDirty: false,
                        unsigned: false,
                        externalSwiftPMDependencies: trustedSwiftPMDependencies(),
                        packageLicenseSPDX: "Apache-2.0",
                        reproducibilityBuildCount: 2,
                        byteIdenticalUnsignedPayloads: true,
                        toolVersions: trustedToolVersions()
                    ),
                    resolvedDependencies: [
                        ProvenanceResolvedDependency(
                            uri: "git+https://github.com/hostwright/hostwright.git",
                            digest: ["gitCommit": manifest.sourceCommit]
                        ),
                        ProvenanceResolvedDependency(
                            uri: "git+https://github.com/apple/containerization.git@\(DistributionContainerizationAssets.frameworkVersion)",
                            digest: ["gitCommit": DistributionContainerizationAssets.frameworkRevision]
                        )
                    ].sorted { $0.uri < $1.uri }
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

    private func makeReport() -> TrustedReleaseReport {
        let manifest = makeManifest()
        let descriptor = { (name: String) in
            DistributionArtifactDescriptor(
                fileName: name,
                sha256: String(repeating: "9", count: 64),
                sizeBytes: 10
            )
        }
        return TrustedReleaseReport(
            manifest: manifest,
            manifestDescriptor: descriptor(TrustedReleaseLayout.manifestFileName),
            checksumDescriptor: descriptor(TrustedReleaseLayout.checksumFileName),
            manifestSignature: descriptor(TrustedReleaseLayout.manifestSignatureFileName),
            checksumSignature: descriptor(TrustedReleaseLayout.checksumSignatureFileName),
            provenanceSignature: descriptor(TrustedReleaseLayout.provenanceSignatureFileName),
            stages: [],
            evidence: HostwrightEvidenceReport(
                evidenceClass: .distributionArtifact,
                status: .passed,
                recordedAt: manifest.createdAt,
                source: HostwrightEvidenceSource(commit: manifest.sourceCommit, dirty: false),
                environment: HostwrightEvidenceEnvironment(
                    operatingSystem: "macOS 26",
                    build: "test",
                    architecture: "arm64",
                    hardwareModel: "test",
                    memoryBytes: 1,
                    toolVersions: trustedToolVersions()
                ),
                commands: [HostwrightEvidenceCommand(command: "test", exitCode: 0, durationMilliseconds: 0)],
                rawResults: HostwrightEvidenceCounts(executed: 1, passed: 1, failed: 0, blocked: 0),
                failures: [],
                blockers: [],
                cleanup: HostwrightEvidenceCleanup(
                    status: .succeeded,
                    exactResourceIdentifiers: ["/tmp/hostwright-dist-release-test"]
                )
            )
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func trustedToolVersions() -> [String: String] {
        [
            "git": "git version 2.50.1",
            "hostwright-dist": "2",
            "notarytool": "notarytool version 1.1.2",
            "swift": "Swift version 6.2",
            "tar": "bsdtar 3.7.7"
        ]
    }

    private func trustedSwiftPMDependencies() -> [String] {
        [
            "containerization|https://github.com/apple/containerization.git|\(DistributionContainerizationAssets.frameworkVersion)|\(DistributionContainerizationAssets.frameworkRevision)"
        ]
    }

    private func fileRecord(path: String, sha256: String, sizeBytes: Int, mode: Int) -> DistributionFileRecord {
        DistributionFileRecord(path: path, sha256: sha256, sizeBytes: sizeBytes, mode: mode)
    }

    private func workflowRunScriptBodies(_ workflow: String) -> String {
        let lines = workflow.components(separatedBy: "\n")
        var scripts: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.trimmingCharacters(in: .whitespaces) == "run: |" else {
                index += 1
                continue
            }
            let runIndent = line.prefix { $0 == " " }.count
            index += 1
            while index < lines.count {
                let bodyLine = lines[index]
                let trimmed = bodyLine.trimmingCharacters(in: .whitespaces)
                let indent = bodyLine.prefix { $0 == " " }.count
                if !trimmed.isEmpty, indent <= runIndent { break }
                scripts.append(bodyLine)
                index += 1
            }
        }
        return scripts.joined(separator: "\n")
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
