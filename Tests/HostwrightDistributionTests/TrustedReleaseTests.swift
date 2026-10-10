import Foundation
import HostwrightCore
@testable import HostwrightDistribution
import XCTest

final class TrustedReleaseTests: XCTestCase {
    func testPublishedPhaseTwoReleaseSchemaRemainsVerifiable() throws {
        let manifest = makeManifest(
            schemaVersion: 1,
            payloadModes: DistributionLayout.legacyTrustedPayloadModesV1
        )

        XCTAssertNoThrow(try manifest.validate())
        XCTAssertNoThrow(
            try makeProvenance(manifest: manifest).validate(manifest: manifest)
        )
    }

    func testPublishedSchemaOneEmptyDependencyInventoryRemainsVerifiable() throws {
        let manifest = makeManifest(
            schemaVersion: 1,
            payloadModes: DistributionLayout.legacyTrustedPayloadModesV1
        )
        XCTAssertNoThrow(try provenanceWithEmptyDependencies(manifest: manifest).validate(manifest: manifest))
    }

    func testCurrentSchemaRejectsEmptyDependencyInventory() throws {
        let manifest = makeManifest()
        XCTAssertThrowsError(try provenanceWithEmptyDependencies(manifest: manifest).validate(manifest: manifest))
        let metadata = TrustedReleaseBuildMetadata(
            externalSwiftPMDependencies: [],
            packageLicenseSPDX: "Apache-2.0",
            reproducibilityBuildCount: 2,
            byteIdenticalUnsignedPayloads: true,
            toolVersions: trustedToolVersions()
        )
        XCTAssertThrowsError(try metadata.validate())
        XCTAssertThrowsError(try metadata.validate(manifestSchemaVersion: 3))
    }

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

    func testArchiveNotaryTicketsAcceptRecordedDesktopBundleAndExecutable() throws {
        let fixture = try recordedDesktopNotaryFixture()
        let expected = try TrustedReleaseBuilder.archiveNotaryTicketExpectations(
            archiveFileName: fixture.archiveName,
            artifactID: fixture.artifactID,
            signedBinaryCDHashes: fixture.signedHashes
        )
        XCTAssertEqual(expected.count, 10)
        XCTAssertEqual(Set(expected.map(\.path)).count, 10)
        XCTAssertNoThrow(try NotarytoolLogParser.requireAcceptedTicketContents(
            output: String(decoding: JSONSerialization.data(withJSONObject: fixture.object), as: UTF8.self),
            archiveFileName: fixture.archiveName,
            expectedTickets: expected
        ))
    }

    func testArchiveNotaryTicketsBindBundleToFinalDesktopExecutableHash() throws {
        let fixture = try recordedDesktopNotaryFixture()
        var signedHashes = fixture.signedHashes
        let finalDesktopHash = String(repeating: "f", count: 40)
        signedHashes[DistributionLayout.desktopExecutablePath] = finalDesktopHash
        let expected = try TrustedReleaseBuilder.archiveNotaryTicketExpectations(
            archiveFileName: fixture.archiveName,
            artifactID: fixture.artifactID,
            signedBinaryCDHashes: signedHashes
        )
        let prefix = "\(fixture.archiveName)/\(fixture.artifactID)/"
        for path in [DistributionLayout.desktopAppPath, DistributionLayout.desktopExecutablePath] {
            let ticket = try XCTUnwrap(expected.first { $0.path == prefix + path })
            XCTAssertEqual(ticket.cdHash, finalDesktopHash)
            XCTAssertEqual(ticket.architecture, "arm64")
        }
        XCTAssertThrowsError(try NotarytoolLogParser.requireAcceptedTicketContents(
            output: String(decoding: JSONSerialization.data(withJSONObject: fixture.object), as: UTF8.self),
            archiveFileName: fixture.archiveName,
            expectedTickets: expected
        ))
    }

    func testArchiveNotaryTicketsRequireEverySignedExecutableHash() throws {
        let fixture = try recordedDesktopNotaryFixture()
        for path in DistributionLayout.shippedBinaryPaths {
            var signedHashes = fixture.signedHashes
            signedHashes.removeValue(forKey: path)
            XCTAssertThrowsError(try TrustedReleaseBuilder.archiveNotaryTicketExpectations(
                archiveFileName: fixture.archiveName,
                artifactID: fixture.artifactID,
                signedBinaryCDHashes: signedHashes
            ), path)
        }
    }

    func testArchiveNotaryTicketsRejectChangedRecordedDesktopInventory() throws {
        let fixture = try recordedDesktopNotaryFixture()
        let expected = try TrustedReleaseBuilder.archiveNotaryTicketExpectations(
            archiveFileName: fixture.archiveName,
            artifactID: fixture.artifactID,
            signedBinaryCDHashes: fixture.signedHashes
        )
        let tickets = try XCTUnwrap(fixture.object["ticketContents"] as? [[String: String]])
        let prefix = "\(fixture.archiveName)/\(fixture.artifactID)/"
        let bundleIndex = try XCTUnwrap(tickets.firstIndex {
            $0["path"] == prefix + DistributionLayout.desktopAppPath
        })
        let executableIndex = try XCTUnwrap(tickets.firstIndex {
            $0["path"] == prefix + DistributionLayout.desktopExecutablePath
        })
        var variants: [(String, [[String: String]])] = []
        for (name, index) in [("missing bundle", bundleIndex), ("missing executable", executableIndex)] {
            var changed = tickets
            changed.remove(at: index)
            variants.append((name, changed))
        }
        for (key, value) in [
            ("cdhash", String(repeating: "0", count: 40)),
            ("arch", "x86_64"),
            ("path", prefix + "libexec/hostwright/Unexpected.app")
        ] {
            var changed = tickets
            changed[bundleIndex][key] = value
            variants.append(("wrong bundle \(key)", changed))
        }
        var extra = tickets[bundleIndex]
        extra["path"] = prefix + "libexec/hostwright/Unexpected.app"
        variants.append(("arbitrary extra ticket", tickets + [extra]))
        variants.append(("duplicate bundle ticket", tickets + [tickets[bundleIndex]]))
        var duplicateAtExpectedCount = tickets
        duplicateAtExpectedCount[executableIndex] = tickets[bundleIndex]
        variants.append(("duplicate bundle replacing executable", duplicateAtExpectedCount))
        for (name, changed) in variants {
            var object = fixture.object
            object["ticketContents"] = changed
            XCTAssertThrowsError(try NotarytoolLogParser.requireAcceptedTicketContents(
                output: String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self),
                archiveFileName: fixture.archiveName,
                expectedTickets: expected
            ), name)
        }
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
                "--build-system", "native",
                "--package-path", source.path,
                "--scratch-path", scratch.path,
                "-c", "release",
                "--jobs", "1",
                "-debug-info-format", "none",
                "-Xlinker", "-reproducible",
                "-Xswiftc", "-num-threads",
                "-Xswiftc", "1",
                "-Xswiftc", "-no-whole-module-optimization",
                "-Xswiftc", "-disable-cmo",
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
        XCTAssertEqual(
            DistributionDeterministicSwiftEnvironment.values,
            ["SWIFT_DETERMINISTIC_HASHING": "1"]
        )
    }

    func testPackageComponentPolicyProducesExactNonrelocatingPkgbuildMetadata() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hostwright-package-policy-\(UUID().uuidString)")
        try DistributionFileSystem.createExclusiveDirectory(root)
        defer { try? DistributionFileSystem.removeOwnedTemporaryItem(root) }
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        let app = payload.appendingPathComponent(TrustedReleasePackageComponentPolicy.rootRelativeBundlePath)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/hostwright-desktop")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DistributionFileSystem.createExclusiveDirectory(scripts)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.hostwright.desktop",
            "CFBundleName": "Hostwright",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "hostwright-desktop",
            "CFBundleShortVersionString": "0.0.2",
            "CFBundleVersion": "2.1.1"
        ]
        try DistributionFileSystem.writeNewFile(
            PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0),
            to: contents.appendingPathComponent("Info.plist"), mode: 0o644
        )
        let components = root.appendingPathComponent("components.plist")
        let componentData = try TrustedReleasePackageComponentPolicy.propertyListData()
        let values = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: componentData, format: nil) as? [[String: Any]]
        )
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0]["RootRelativeBundlePath"] as? String,
                       "Library/Application Support/Hostwright/InstallerPayload/libexec/hostwright/Hostwright.app")
        XCTAssertEqual(values[0]["BundleIsRelocatable"] as? Bool, false)
        XCTAssertEqual(values[0]["BundleIsVersionChecked"] as? Bool, false)
        XCTAssertEqual(values[0]["BundleHasStrictIdentifier"] as? Bool, true)
        XCTAssertEqual(values[0]["BundleOverwriteAction"] as? String, "upgrade")
        try DistributionFileSystem.writeNewFile(componentData, to: components, mode: 0o600)
        let package = root.appendingPathComponent("candidate.pkg")
        var arguments = TrustedReleasePackageComponentPolicy.buildArguments(
            root: payload, scripts: scripts, componentPropertyList: components,
            packageVersion: "0.0.2.1001", installerIdentity: String(repeating: "A", count: 40), output: package
        )
        let signingIndex = try XCTUnwrap(arguments.firstIndex(of: "--sign"))
        XCTAssertEqual(arguments[signingIndex + 1], String(repeating: "A", count: 40))
        arguments.removeSubrange(signingIndex...(signingIndex + 1))
        let built = try run(URL(fileURLWithPath: "/usr/bin/pkgbuild"), arguments: arguments)
        XCTAssertEqual(built.status, 0, built.output)
        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        let expansion = try run(URL(fileURLWithPath: "/usr/sbin/pkgutil"), arguments: ["--expand", package.path, expanded.path])
        XCTAssertEqual(expansion.status, 0, expansion.output)
        let packageInfo = try Data(contentsOf: expanded.appendingPathComponent("PackageInfo"))
        XCTAssertNoThrow(try TrustedReleasePackageComponentPolicy.validatePackageInfo(
            packageInfo, packageVersion: "0.0.2.1001", desktopBundleVersion: "2.1.1"
        ))
        let document = try XMLDocument(data: packageInfo, options: .nodeLoadExternalEntitiesNever)
        let metadata = try XCTUnwrap(document.rootElement())
        let relocate = XMLElement(name: "relocate")
        let bundle = XMLElement(name: "bundle")
        bundle.addAttribute(XMLNode.attribute(withName: "id", stringValue: "dev.hostwright.desktop") as! XMLNode)
        relocate.addChild(bundle)
        metadata.addChild(relocate)
        XCTAssertEqual(metadata.attribute(forName: "relocatable")?.stringValue, "false")
        XCTAssertThrowsError(try TrustedReleasePackageComponentPolicy.validatePackageInfo(
            document.xmlData, packageVersion: "0.0.2.1001", desktopBundleVersion: "2.1.1"
        ))
    }

    func testPackageComponentPolicyRejectsSkippedOrInexactBundleMetadata() throws {
        let metadata = """
        <pkg-info identifier="dev.hostwright.cli" version="0.0.2.1001" install-location="/" relocatable="false">
          <bundle path="./Library/Application Support/Hostwright/InstallerPayload/libexec/hostwright/Hostwright.app"
            id="dev.hostwright.desktop" CFBundleVersion="2.1.1"/>
          <bundle-version/>
          <upgrade-bundle><bundle id="dev.hostwright.desktop"/></upgrade-bundle>
          <strict-identifier><bundle id="dev.hostwright.desktop"/></strict-identifier>
          <relocate/><update-bundle/><atomic-update-bundle/>
        </pkg-info>
        """
        func validate(_ value: String) throws {
            try TrustedReleasePackageComponentPolicy.validatePackageInfo(
                Data(value.utf8), packageVersion: "0.0.2.1001", desktopBundleVersion: "2.1.1"
            )
        }
        XCTAssertNoThrow(try validate(metadata))
        let mutations = [
            metadata.replacingOccurrences(of: "<bundle-version/>", with: "<bundle-version><bundle id=\"dev.hostwright.desktop\"/></bundle-version>"),
            metadata.replacingOccurrences(of: "InstallerPayload/libexec", with: "Other/libexec"),
            metadata.replacingOccurrences(of: "dev.hostwright.desktop", with: "other.desktop"),
            metadata.replacingOccurrences(of: "CFBundleVersion=\"2.1.1\"", with: "CFBundleVersion=\"2.1.2\""),
            metadata.replacingOccurrences(of: "version=\"0.0.2.1001\"", with: "version=\"0.0.2.12\""),
            metadata.replacingOccurrences(of: "<strict-identifier><bundle id=\"dev.hostwright.desktop\"/></strict-identifier>", with: "<strict-identifier/>"),
            metadata.replacingOccurrences(of: "<update-bundle/>", with: "<update-bundle><bundle id=\"dev.hostwright.desktop\"/></update-bundle>"),
            metadata.replacingOccurrences(of: "<relocate/>", with: "<relocate><bundle id=\"dev.hostwright.desktop\"/></relocate>"),
            metadata.replacingOccurrences(of: "</pkg-info>", with: "<bundle path=\"./other.app\" id=\"other.desktop\"/></pkg-info>"),
            "<!DOCTYPE pkg-info [<!ENTITY app 'dev.hostwright.desktop'>]>" + metadata,
            "<pkg-info>",
            ""
        ]
        for value in mutations {
            XCTAssertThrowsError(try validate(value))
        }
    }

    func testPackageComponentPolicyPreservesPublishedSchemaTwoDesktopCompatibility() throws {
        let manifest = makeManifest(schemaVersion: 2, payloadModes: DistributionLayout.legacyPayloadModesV5)
        XCTAssertNoThrow(try manifest.validate())
        XCTAssertTrue(manifest.payloadFiles.contains { $0.path == DistributionLayout.desktopInfoPlistPath })
        let legacyMetadata = Data("""
        <pkg-info identifier="dev.hostwright.cli" version="0.0.2.1001" install-location="/" relocatable="false">
          <bundle path="./Library/Application Support/Hostwright/InstallerPayload/libexec/hostwright/Hostwright.app"
            id="dev.hostwright.desktop" CFBundleVersion="2.1.1"/>
          <bundle-version><bundle id="dev.hostwright.desktop"/></bundle-version>
          <relocate><bundle id="dev.hostwright.desktop"/></relocate>
        </pkg-info>
        """.utf8)
        XCTAssertNoThrow(try TrustedReleasePackageComponentPolicy.validatePackageInfo(legacyMetadata, manifest: manifest))
        XCTAssertThrowsError(try TrustedReleasePackageComponentPolicy.validatePackageInfo(legacyMetadata, manifest: makeManifest()))
    }

    func testCleanBuildCommandEvidenceRecordsExactDeterministicInvocation() {
        let arguments = DistributionCleanBuilder.deterministicReleaseBuildArguments(
            sourceRoot: URL(fileURLWithPath: "/private/tmp/source with space", isDirectory: true),
            scratch: URL(fileURLWithPath: "/private/tmp/scratch with space", isDirectory: true),
            additionalArguments: ["--product", "hostwright"]
        )

        let command = DistributionCleanBuilder.evidenceCommand(
            executablePath: "/usr/bin/swift",
            arguments: arguments,
            environment: DistributionDeterministicSwiftEnvironment.values
        )
        XCTAssertEqual(
            command,
            "SWIFT_DETERMINISTIC_HASHING=1 /usr/bin/swift build --build-system native " +
                "--package-path '/private/tmp/source with space' " +
                "--scratch-path '/private/tmp/scratch with space' -c release " +
                "--jobs 1 -debug-info-format none -Xlinker -reproducible " +
                "-Xswiftc -num-threads -Xswiftc 1 " +
                "-Xswiftc -no-whole-module-optimization -Xswiftc -disable-cmo " +
                "-Xswiftc -file-prefix-map " +
                "-Xswiftc '/private/tmp/scratch with space=/hostwright-build' " +
                "-Xcc '-ffile-prefix-map=/private/tmp/scratch with space=/hostwright-build' " +
                "-Xcc '-fmacro-prefix-map=/private/tmp/scratch with space=/hostwright-build' " +
                "-Xcxx '-ffile-prefix-map=/private/tmp/scratch with space=/hostwright-build' " +
                "-Xcxx '-fmacro-prefix-map=/private/tmp/scratch with space=/hostwright-build' " +
                "--product hostwright"
        )
    }

    func testContainerizationHelperSigningUsesOnlyVirtualizationEntitlement() throws {
        let binary = URL(fileURLWithPath: "/private/tmp/release/bin/hostwright-containerization-helper")
        let entitlements = URL(fileURLWithPath: "/private/tmp/helper.entitlements")
        let fingerprint = String(repeating: "A", count: 40)

        XCTAssertEqual(
            TrustedReleaseCodeSigningPolicy.signingArguments(
                relativePath: "bin/hostwright-containerization-helper",
                binary: binary,
                fingerprint: fingerprint,
                entitlements: entitlements
            ),
            [
                "--force", "--options", "runtime", "--timestamp",
                "--entitlements", entitlements.path,
                "--sign", fingerprint, binary.path
            ]
        )
        XCTAssertEqual(
            TrustedReleaseCodeSigningPolicy.signingArguments(
                relativePath: "bin/hostwright",
                binary: URL(fileURLWithPath: "/private/tmp/release/bin/hostwright"),
                fingerprint: fingerprint,
                entitlements: entitlements
            ),
            [
                "--force", "--options", "runtime", "--timestamp",
                "--sign", fingerprint, "/private/tmp/release/bin/hostwright"
            ]
        )
        XCTAssertEqual(
            TrustedReleaseCodeSigningPolicy.signingArguments(
                relativePath: "bin/hostwright-storage-helper",
                binary: URL(
                    fileURLWithPath:
                        "/private/tmp/release/bin/hostwright-storage-helper"
                ),
                fingerprint: fingerprint,
                entitlements: entitlements
            ),
            [
                "--force", "--options", "runtime", "--timestamp",
                "--sign", fingerprint,
                "/private/tmp/release/bin/hostwright-storage-helper"
            ]
        )

        let plist = try XCTUnwrap(
            String(
                data: TrustedReleaseCodeSigningPolicy.containerizationHelperEntitlements,
                encoding: .utf8
            )
        )
        XCTAssertNoThrow(
            try TrustedReleaseCodeSigningPolicy.requireContainerizationHelperEntitlement(plist)
        )
        XCTAssertThrowsError(
            try TrustedReleaseCodeSigningPolicy.requireContainerizationHelperEntitlement(
                plist.replacingOccurrences(of: "<true/>", with: "<false/>")
            )
        )
    }

    func testDistributionRunnerRestrictsDeterministicSwiftEnvironment() throws {
        let runner = DistributionProcessRunner()
        let result = try runner.run(
            executablePath: "/usr/bin/swift",
            arguments: [
                "-e",
                "import Foundation; print(ProcessInfo.processInfo.environment[\"SWIFT_DETERMINISTIC_HASHING\"] ?? \"missing\")"
            ],
            label: "inspect deterministic Swift environment",
            timeoutSeconds: 30,
            trustedEnvironmentOverrides: DistributionDeterministicSwiftEnvironment.values
        )
        XCTAssertEqual(result.standardOutput, "1\n")

        XCTAssertThrowsError(
            try runner.run(
                executablePath: "/usr/bin/true",
                arguments: [],
                label: "reject deterministic Swift environment on another executable",
                trustedEnvironmentOverrides: DistributionDeterministicSwiftEnvironment.values
            )
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

    func testRevisionOnlyProvenanceKeepsExactCommitAndRejectsMissingOrDuplicateIdentity() throws {
        let containerization = "containerization|https://github.com/apple/containerization.git|0.35.0|\(DistributionContainerizationAssets.frameworkRevision)"
        let crypto = "swift-crypto|\(HostwrightSecurityDependencyPins.swiftCryptoLocation)||\(HostwrightSecurityDependencyPins.swiftCryptoRevision)"
        XCTAssertNoThrow(try TrustedReleaseBuildMetadata.validateExternalDependencies([containerization, crypto].sorted()))
        for invalid in ["swift-crypto|https://github.com/apple/swift-crypto.git||",
                        "swift-crypto|https://github.com/apple/swift-crypto.git||not-a-revision",
                        "swift-crypto|https://github.com/apple/swift-crypto.git|invented|\(HostwrightSecurityDependencyPins.swiftCryptoRevision)"] {
            XCTAssertThrowsError(try TrustedReleaseBuildMetadata.validateExternalDependencies([containerization, invalid].sorted()))
        }
        XCTAssertThrowsError(try TrustedReleaseBuildMetadata.validateExternalDependencies([
            containerization, crypto, crypto.replacingOccurrences(of: "||", with: "|4.5.2|")
        ].sorted()))
    }

    func testCleanBuildInventoryRequiresQualifiedSecurityRevisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-security-dependency-inventory-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = root.appendingPathComponent("Package.resolved")
        let builder = DistributionCleanBuilder()
        let pins: [[String: Any]] = [
            [
                "identity": "containerization", "kind": "remoteSourceControl",
                "location": "https://github.com/apple/containerization.git",
                "state": [
                    "version": "0.35.0",
                    "revision": DistributionContainerizationAssets.frameworkRevision,
                ],
            ],
            [
                "identity": "swift-crypto", "kind": "remoteSourceControl",
                "location": HostwrightSecurityDependencyPins.swiftCryptoLocation,
                "state": ["revision": HostwrightSecurityDependencyPins.swiftCryptoRevision],
            ],
            [
                "identity": "swift-nio-http2", "kind": "remoteSourceControl",
                "location": HostwrightSecurityDependencyPins.swiftNIOHTTP2Location,
                "state": [
                    "version": HostwrightSecurityDependencyPins.swiftNIOHTTP2Version,
                    "revision": HostwrightSecurityDependencyPins.swiftNIOHTTP2Revision,
                ],
            ],
        ]
        let graph: [[String: Any]] = pins.map { pin in
            let state = pin["state"] as? [String: String]
            return [
                "identity": pin["identity"] as Any, "url": pin["location"] as Any,
                "version": state?["version"] ?? "unspecified", "dependencies": [],
            ]
        }
        func inventory(_ pins: [[String: Any]], _ graph: [[String: Any]]) throws -> [String] {
            try JSONSerialization.data(withJSONObject: ["pins": pins, "version": 3])
                .write(to: resolved)
            let data = try JSONSerialization.data(withJSONObject: ["dependencies": graph])
            return try builder.requirePinnedExternalDependencies(
                String(decoding: data, as: UTF8.self), resolvedFile: resolved
            )
        }
        let valid = try inventory(pins, graph)
        XCTAssertTrue(valid.contains(
            "swift-crypto|\(HostwrightSecurityDependencyPins.swiftCryptoLocation)||\(HostwrightSecurityDependencyPins.swiftCryptoRevision)"
        ))
        for scenario in ["crypto-revision", "crypto-version", "crypto-branch", "http2-downgrade", "reported-version"] {
            var changedPins = pins
            var changedGraph = graph
            switch scenario {
            case "crypto-revision":
                changedPins[1]["state"] = ["revision": String(repeating: "a", count: 40)]
            case "crypto-version":
                changedPins[1]["state"] = [
                    "revision": HostwrightSecurityDependencyPins.swiftCryptoRevision,
                    "version": "4.5.2",
                ]
            case "crypto-branch":
                changedPins[1]["state"] = [
                    "revision": HostwrightSecurityDependencyPins.swiftCryptoRevision,
                    "branch": "main",
                ]
            case "http2-downgrade":
                changedPins[2]["state"] = [
                    "revision": "61d1b44f6e4e118792be1cff88ee2bc0267c6f9a",
                    "version": "1.44.0",
                ]
            default:
                changedGraph[1]["version"] = "4.5.1"
            }
            XCTAssertThrowsError(try inventory(changedPins, changedGraph), scenario)
        }
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
        XCTAssertEqual(archive.packages.first?.licenseConcluded, "NOASSERTION")
        XCTAssertTrue(archive.files.allSatisfy {
            $0.licenseConcluded == ($0.fileName == "./" + ContainerizationRuntimeAssetContract.kernelInstallationRelativePath ? "GPL-2.0-only" : "NOASSERTION")
        })
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
            """
            executables = %w[
                  hostwright
                  hostwright-control
                  hostwright-containerization-helper
                  hostwright-network-helper
                  hostwright-network-provider-worker
                  hostwright-storage-helper
                  hostwright-dist
                  hostwrightd
                ]
            """
        ))
        XCTAssertTrue(formula.contains(
            "assert_equal \"network-helper-protocol-v1\", shell_output(" +
                "\"#{bin}/hostwright-network-helper --version\").strip"
        ))
        XCTAssertTrue(formula.contains(
            "assert_equal \"network-provider-spi-v1\", shell_output(" +
                "\"#{bin}/hostwright-network-provider-worker --version\").strip"
        ))
        XCTAssertTrue(formula.contains(
            "storage_helper_version = shell_output(" +
                "\"#{bin}/hostwright-storage-helper --version\").strip"
        ))
        XCTAssertTrue(formula.contains("assert_equal \"1.0.0\", storage_helper_version"))
        XCTAssertTrue(formula.contains("pkgshare.install \"share/hostwright/containerization\""))
        XCTAssertTrue(formula.contains("libexec.install \"libexec/hostwright\""))
        XCTAssertTrue(formula.contains("assert_path_exists libexec/\"hostwright/Hostwright.app/Contents/MacOS/hostwright-desktop\""))
        XCTAssertTrue(formula.contains("service do"))
        XCTAssertTrue(formula.contains("depends_on arch: :arm64"))
        XCTAssertTrue(formula.contains("depends_on macos: :tahoe"))
        XCTAssertTrue(formula.contains("codesign"))
        let testStart = try XCTUnwrap(formula.range(of: "  test do\n"))
        let testBody = String(formula[testStart.upperBound...])
        let commands = testBody.components(separatedBy: "shell_output(\"").dropFirst().map {
            $0.components(separatedBy: "\"").first ?? ""
        }
        XCTAssertEqual(commands.count, 8)
        XCTAssertTrue(commands.allSatisfy { $0.hasSuffix(" --version") },
                      "Homebrew test must execute without a configured daemon or Control API.")
        XCTAssertTrue(formula.contains("reviewed Manifest v3 file"))
        XCTAssertTrue(formula.contains("#{opt_bin}/hostwright daemon bootstrap-identities"))

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

        let stage = try String(
            contentsOf: packageRoot().appendingPathComponent(".github/workflows/trusted-release.yml"),
            encoding: .utf8
        )
        let promotion = try String(
            contentsOf: packageRoot().appendingPathComponent(".github/workflows/promote-release.yml"),
            encoding: .utf8
        )
        XCTAssertFalse(stage.contains("contents: write"))
        XCTAssertFalse(stage.contains("gh release create"))
        XCTAssertFalse(promotion.contains("swift build"))
        XCTAssertFalse(promotion.contains("swift run"))
        XCTAssertTrue(promotion.contains("--signer-digest"))
        XCTAssertTrue(promotion.contains("staged-release.py receipt"))
        let workflow = stage + "\n" + promotion
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

    func testCMSSigningCertificateRequiresExactFingerprintAndCommonName() throws {
        let identity = makeManifest().applicationSigner
        let selected = TrustedCMSSigningCertificate.Record(
            sha1Fingerprint: identity.sha1Fingerprint,
            commonName: identity.commonName,
            subjectKeyIdentifier: Data([0x01, 0xab, 0xff])
        )
        let unrelated = TrustedCMSSigningCertificate.Record(
            sha1Fingerprint: String(repeating: "C", count: 40),
            commonName: identity.commonName,
            subjectKeyIdentifier: Data([0x02])
        )
        XCTAssertEqual(try TrustedCMSSigningCertificate.selectSubjectKeyIdentifier(
            for: identity, certificates: [unrelated, selected]
        ), "01ABFF")
        XCTAssertThrowsError(try TrustedCMSSigningCertificate.selectSubjectKeyIdentifier(
            for: identity, certificates: []
        ))
        XCTAssertThrowsError(try TrustedCMSSigningCertificate.selectSubjectKeyIdentifier(
            for: identity, certificates: [unrelated]
        ))
        for name in [nil, "Developer ID Application: Wrong Project (A1B2C3D4E5)"] {
            let wrongName = TrustedCMSSigningCertificate.Record(
                sha1Fingerprint: identity.sha1Fingerprint,
                commonName: name,
                subjectKeyIdentifier: selected.subjectKeyIdentifier
            )
            XCTAssertThrowsError(try TrustedCMSSigningCertificate.selectSubjectKeyIdentifier(
                for: identity, certificates: [wrongName]
            ))
        }
    }

    func testCMSSigningCertificateRejectsMissingAndAmbiguousIdentifiers() throws {
        let identity = makeManifest().applicationSigner
        for identifier in [nil, Data()] {
            let missingIdentifier = TrustedCMSSigningCertificate.Record(
                sha1Fingerprint: identity.sha1Fingerprint,
                commonName: identity.commonName,
                subjectKeyIdentifier: identifier
            )
            XCTAssertThrowsError(try TrustedCMSSigningCertificate.selectSubjectKeyIdentifier(
                for: identity, certificates: [missingIdentifier]
            ))
        }
        let selected = TrustedCMSSigningCertificate.Record(
            sha1Fingerprint: identity.sha1Fingerprint,
            commonName: identity.commonName,
            subjectKeyIdentifier: Data([0x01])
        )
        let renewedCertificate = TrustedCMSSigningCertificate.Record(
            sha1Fingerprint: String(repeating: "C", count: 40),
            commonName: identity.commonName,
            subjectKeyIdentifier: selected.subjectKeyIdentifier
        )
        for certificates in [[selected, selected], [selected, renewedCertificate]] {
            XCTAssertThrowsError(try TrustedCMSSigningCertificate.selectSubjectKeyIdentifier(
                for: identity, certificates: certificates
            ))
        }
    }

    func testCMSDecoderAuthenticatesPublicDetachedFixtureAndReadsActualSubjectKeyIdentifier() throws {
        let fixture = try detachedCMSFixture()
        let signer = try TrustedCMSSignerInspector.verifiedSigner(
            signatureData: fixture.signature, contentData: fixture.content
        )
        let record = try TrustedCMSSigningCertificate.record(signer.certificate)
        XCTAssertEqual(record.sha1Fingerprint, "A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB")
        let identity = TrustedReleaseIdentity(
            kind: .application,
            sha1Fingerprint: record.sha1Fingerprint,
            commonName: try XCTUnwrap(record.commonName),
            teamIdentifier: "993YC3JY4Q"
        )
        XCTAssertEqual(try TrustedCMSSigningCertificate.selectSubjectKeyIdentifier(
            for: identity, certificates: [record]
        ), "C502C6F9B8148AA6B7D6A2D018787F1DE134569E")
    }

    func testCMSDecoderRejectsTamperedDetachedContentDespiteUnchangedSignerCertificate() throws {
        let fixture = try detachedCMSFixture()
        var tampered = fixture.content
        tampered[0] ^= 1
        XCTAssertThrowsError(try TrustedCMSSignerInspector.verifiedSigner(
            signatureData: fixture.signature, contentData: tampered
        )) { error in
            XCTAssertEqual(error as? DistributionError, .invalidArtifact(
                "detached CMS signature does not authenticate its content"
            ))
        }
    }

    func testCMSDecoderRejectsEmbeddedContentForMatchingAndDifferentDetachedInput() throws {
        let fixture = try detachedCMSFixture()
        let signature = """
        MIAGCSqGSIb3DQEHAqCAMIACAQExDzANBglghkgBZQMEAgEFADCABgkqhkiG9w0BBwGggCSABIH3SG9zdHdyaWdodCBkZXRhY2hl
        ZCBDTVMgc2VsZWN0aW9uIGRpYWdub3N0aWMgb25seS4gVGhpcyBpcyBub3QgYSByZWxlYXNlIG1hbmlmZXN0LCBjaGVja3N1bSwg
        cHJvdmVuYW5jZSBzdGF0ZW1lbnQsIG9yIGF1dGhvcml6YXRpb24uClNvdXJjZSA1MWM5NGNjMDgxNjcxY2UyZDNkZTFhYmFhMTI3
        MDYwNDJhY2MxMDhjOyBmYWlsZWQgcnVuMzY5Njk5NTE3MTkgYXR0ZW1wdDIuCjIwMjYtMTAtMDJUMTA6MzE6MjUuMzQ4NDkyKzAw
        OjAwCgAAAAAAAKCCCggwggQ+MIIDJqADAgECAhR/tAA/zZdJesuDTZKkinhzwoRdQzANBgkqhkiG9w0BAQsFADBiMQswCQYDVQQG
        EwJVUzETMBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxFjAUBgNVBAMT
        DUFwcGxlIFJvb3QgQ0EwHhcNMjEwOTIyMTg1NTEwWhcNMzEwOTE3MDAwMDAwWjBeMS0wKwYDVQQDDCREZXZlbG9wZXIgSUQgQ2Vy
        dGlmaWNhdGlvbiBBdXRob3JpdHkxCzAJBgNVBAsMAkcyMRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzCCASIwDQYJ
        KoZIhvcNAQEBBQADggEPADCCAQoCggEBANMslWghVJGKv2VxwhhO9s0N4ZEoddcDupUf0xKZUkTegEZn/CmLAIWIijCHTUxuSrTH
        5QLj12NMqszq7NtCL5F9JelfpEsqVG8XrDCfKSg0pH+P5XjjXSMqIUbQicNf+GqXnXEbGKiyDMkDCjWyAqct9bPcG4PFJyFAcqbn
        N3Yx57sGv3Sy9nCsTKwtzcleRYvP+wjmYtVAlbU3XMwbDuHv3KXljclQt0CfCiMlRUCPlGd74JTqOdN4pTTRwsvgM38utizD5SbV
        Jc6qjSp3/J4Ulpfg9V8u8uincac7o5lMeiKjTe9wEdXWhoGC8WczkzNaQLGSxKpzlh3EXP/h6zcCAwEAAaOB7zCB7DASBgNVHRMB
        Af8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFCvQaUeUdgn+9GuNLkCm90dNfwheMEQGCCsGAQUFBwEBBDgwNjA0BggrBgEFBQcwAYYo
        aHR0cDovL29jc3AuYXBwbGUuY29tL29jc3AwMy1hcHBsZXJvb3RjYTAuBgNVHR8EJzAlMCOgIaAfhh1odHRwOi8vY3JsLmFwcGxl
        LmNvbS9yb290LmNybDAdBgNVHQ4EFgQU+DoMaRF24O2s0eumWfo31cRVsB4wDgYDVR0PAQH/BAQDAgEGMBAGCiqGSIb3Y2QGAgYE
        AgUAMA0GCSqGSIb3DQEBCwUAA4IBAQDB/UMKWb/xsbdDEFrWGDIwFFYm4RFIYytpcpdIH45byl4mFft0I4AzVDMZoSKGWti4S2mq
        p86WlsIKxzVq0G/OimmDYm1KOfX+g03XotSIH+2IwA/4+TMetBC3wlwRN0Q3BLCkRJ2MaA17fR1+zLWT8NZvPRV6gKV00+GPfdKI
        6DGnmMUf3+KCWa6AgWBGFuyeuYpAqhsq4WGGCoxwD9lKLOxMogUR1nmMpWMlISMCb5NbWleh10Vt38z3f59f28ftZKdvRC9vTT14
        eApWtDvXOsgrZaKT6ttY6o7UucTAMPwyGk26kgwkOZiCOqCZ3ufk5LwOvIWvWqtc0PzbzBDDMIIFwjCCBKqgAwIBAgIQBq1ozfR9
        MElhwR5DvSs1gTANBgkqhkiG9w0BAQsFADBeMS0wKwYDVQQDDCREZXZlbG9wZXIgSUQgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkx
        CzAJBgNVBAsMAkcyMRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzAeFw0yNjA3MTYxNjQzMzNaFw0zMTA3MTcxNjQz
        MzJaMIGRMRowGAYKCZImiZPyLGQBAQwKOTkzWUMzSlk0UTE7MDkGA1UEAwwyRGV2ZWxvcGVyIElEIEFwcGxpY2F0aW9uOiBEZXYg
        VHJpdmVkaSAoOTkzWUMzSlk0USkxEzARBgNVBAsMCjk5M1lDM0pZNFExFDASBgNVBAoMC0RldiBUcml2ZWRpMQswCQYDVQQGEwJV
        UzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAK6JaMYMzUffrf4dKaxvnKJ+Wk8i5I1lofjwMY8vo107NROTNZOe7YPo
        756vEv8vRn/M0U4V+d8Pi21Ws4/6BPy/GLNPYw6bqP3KcIP67yGtqTxOdu5esr2Aly6CNoFStouBmNuEiI8RyTZSHvwhzZSbjtK6
        KZybTXs3l+KZM82Lh/pl6urPtXeHWP8xlHXiPYSaWQaC+VEkOydzyyk7Km5MGns128ob4VU9dKVsjF/OzoKEaKqYNOWbGDsLZu4v
        p3Ec14kwVdcWLOf7LNMzDU1qCdjJla9nT0/wQVWO7Kk07fK29z+oxbExlXpCOXkExGrRBaeeN+/gEjwetRlSiVcCAwEAAaOCAkYw
        ggJCMAwGA1UdEwEB/wQCMAAwHwYDVR0jBBgwFoAU+DoMaRF24O2s0eumWfo31cRVsB4wcgYIKwYBBQUHAQEEZjBkMC4GCCsGAQUF
        BzAChiJodHRwOi8vY2VydHMuYXBwbGUuY29tL2RldmlkZzIuZGVyMDIGCCsGAQUFBzABhiZodHRwOi8vb2NzcC5hcHBsZS5jb20v
        b2NzcDAzLWRldmlkZzIwMTCCAR4GA1UdIASCARUwggERMIIBDQYJKoZIhvdjZAUBMIH/MIHDBggrBgEFBQcCAjCBtgyBs1JlbGlh
        bmNlIG9uIHRoaXMgY2VydGlmaWNhdGUgYnkgYW55IHBhcnR5IGFzc3VtZXMgYWNjZXB0YW5jZSBvZiB0aGUgdGhlbiBhcHBsaWNh
        YmxlIHN0YW5kYXJkIHRlcm1zIGFuZCBjb25kaXRpb25zIG9mIHVzZSwgY2VydGlmaWNhdGUgcG9saWN5IGFuZCBjZXJ0aWZpY2F0
        aW9uIHByYWN0aWNlIHN0YXRlbWVudHMuMDcGCCsGAQUFBwIBFitodHRwczovL3d3dy5hcHBsZS5jb20vY2VydGlmaWNhdGVhdXRo
        b3JpdHkvMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBTFAsb5uBSKprfWotAYeH8d4TRWnjAOBgNVHQ8BAf8EBAMC
        B4AwHwYKKoZIhvdjZAYBIQQRDA8yMDI2MDcxNjAwMDAwMFowEwYKKoZIhvdjZAYBDQEB/wQCBQAwDQYJKoZIhvcNAQELBQADggEB
        AClQISmizPTS22uM+YudGY9qludeDqTBb/rCZU5YRJ3txwANtpJ98OUf3VlyKHSaJb5HA2h9a+GghoEdyK1Iwiaftrvh8kmAyuV9
        NdvT/c5Ei4enUhR2kYPH3u1a7z+RqVC48k47zcg6gC8XvvV/kOn2jxHHAIcLfT+Ndv5w51x+BIypmuUC5QL63b2T0AqXbtOT0R4o
        HOcIVwYwJoSGSNWHniTLeEyam8EK4azOh93eyi6q90nskPK/rPZmlNvoLwhvhl5+ZIWj0n1n08bF3xtu/yTRC6oE+2oicUupaD8+
        1JYrXiOf/58pLnUSsTE3VbWvqGxBK4sSFka+D1dQ7UYxggMUMIIDEAIBATByMF4xLTArBgNVBAMMJERldmVsb3BlciBJRCBDZXJ0
        aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzIxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTAhAGrWjN9H0w
        SWHBHkO9KzWBMA0GCWCGSAFlAwQCAQUAoIIBczAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjEw
        MDIxMTAwMTlaMC8GCSqGSIb3DQEJBDEiBCAxFYImARnzmTw4n6T6WONkW/JTE1AyQNvEMMYFqDtUizCBgQYJKwYBBAGCNxAEMXQw
        cjBeMS0wKwYDVQQDDCREZXZlbG9wZXIgSUQgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxCzAJBgNVBAsMAkcyMRMwEQYDVQQKDApB
        cHBsZSBJbmMuMQswCQYDVQQGEwJVUwIQBq1ozfR9MElhwR5DvSs1gTCBgwYLKoZIhvcNAQkQAgsxdKByMF4xLTArBgNVBAMMJERl
        dmVsb3BlciBJRCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzIxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNV
        BAYTAlVTAhAGrWjN9H0wSWHBHkO9KzWBMA0GCSqGSIb3DQEBCwUABIIBAKlqkdJApGjO8WpJCDlyoFwSfkYX2PL6gvZR+MUyDUpb
        50MF/1f5zDVzNcB9TVQcjf+nHiFjvLhh/Wb2+4LSOQUFU9nlt8qx6TmWDm6HJnz8F0rgZ0948scqh71B4pWKhIlldiEb2oveWEcB
        QIdB+xmwZjH94Qa1y5BT2WjkZYQ1fA/ZFB2GSdPKogdTmnshzaG3AiDDW3b7VWyf7leQxJ3TzVEdNMa2+pokq+Cnd2UxU9JsnJIv
        KPXIy6OqJI40c1L3J1dmyHH8YtzSoOK/rCCL0hepv5DjBviimUqV3kl1s4GaweRh6LKVNzyWQt6qN7cCMtMpnuuaBXsVSf4ClDcA
        AAAAAAA=
        """
        let signatureData = try XCTUnwrap(Data(base64Encoded: signature, options: .ignoreUnknownCharacters))
        for content in [fixture.content, Data("different supplied content".utf8)] {
            XCTAssertThrowsError(try TrustedCMSSignerInspector.verifiedSigner(
                signatureData: signatureData, contentData: content
            )) { error in
                XCTAssertEqual(error as? DistributionError, .invalidArtifact(
                    "CMS signature must use detached content"
                ))
            }
        }
    }

    func testCMSDecoderRejectsEmptyEmbeddedContentWithNonemptyDetachedInput() throws {
        let fixture = try detachedCMSFixture()
        let signature = """
        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
        GDAWgBT4OgxpEXbg7azR66ZZ+jfVxFWwHjByBggrBgEFBQcBAQRmMGQwLgYIKwYBBQUHMAKGImh0dHA6Ly9jZXJ0cy5hcHBsZS5j
        b20vZGV2aWRnMi5kZXIwMgYIKwYBBQUHMAGGJmh0dHA6Ly9vY3NwLmFwcGxlLmNvbS9vY3NwMDMtZGV2aWRnMjAxMIIBHgYDVR0g
        BIIBFTCCAREwggENBgkqhkiG92NkBQEwgf8wgcMGCCsGAQUFBwICMIG2DIGzUmVsaWFuY2Ugb24gdGhpcyBjZXJ0aWZpY2F0ZSBi
        eSBhbnkgcGFydHkgYXNzdW1lcyBhY2NlcHRhbmNlIG9mIHRoZSB0aGVuIGFwcGxpY2FibGUgc3RhbmRhcmQgdGVybXMgYW5kIGNv
        bmRpdGlvbnMgb2YgdXNlLCBjZXJ0aWZpY2F0ZSBwb2xpY3kgYW5kIGNlcnRpZmljYXRpb24gcHJhY3RpY2Ugc3RhdGVtZW50cy4w
        NwYIKwYBBQUHAgEWK2h0dHBzOi8vd3d3LmFwcGxlLmNvbS9jZXJ0aWZpY2F0ZWF1dGhvcml0eS8wFgYDVR0lAQH/BAwwCgYIKwYB
        BQUHAwMwHQYDVR0OBBYEFMUCxvm4FIqmt9ai0Bh4fx3hNFaeMA4GA1UdDwEB/wQEAwIHgDAfBgoqhkiG92NkBgEhBBEMDzIwMjYw
        NzE2MDAwMDAwWjATBgoqhkiG92NkBgENAQH/BAIFADANBgkqhkiG9w0BAQsFAAOCAQEAKVAhKaLM9NLba4z5i50Zj2qW514OpMFv
        +sJlTlhEne3HAA22kn3w5R/dWXIodJolvkcDaH1r4aCGgR3IrUjCJp+2u+HySYDK5X0129P9zkSLh6dSFHaRg8fe7VrvP5GpULjy
        TjvNyDqALxe+9X+Q6faPEccAhwt9P412/nDnXH4EjKma5QLlAvrdvZPQCpdu05PRHigc5whXBjAmhIZI1YeeJMt4TJqbwQrhrM6H
        3d7KLqr3SeyQ8r+s9maU2+gvCG+GXn5khaPSfWfTxsXfG27/JNELqgT7aiJxS6loPz7UliteI5//nykudRKxMTdVta+obEErixIW
        Rr4PV1DtRjGCAxQwggMQAgEBMHIwXjEtMCsGA1UEAwwkRGV2ZWxvcGVyIElEIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MQswCQYD
        VQQLDAJHMjETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMCEAataM30fTBJYcEeQ70rNYEwDQYJYIZIAWUDBAIBBQCg
        ggFzMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MTAwMjExMDE1NVowLwYJKoZIhvcNAQkEMSIE
        IOOwxEKY/BwUmvv0yJlvuSQnrkHkZJuTTKSVmRt4UrhVMIGBBgkrBgEEAYI3EAQxdDByMF4xLTArBgNVBAMMJERldmVsb3BlciBJ
        RCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzIxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTAhAG
        rWjN9H0wSWHBHkO9KzWBMIGDBgsqhkiG9w0BCRACCzF0oHIwXjEtMCsGA1UEAwwkRGV2ZWxvcGVyIElEIENlcnRpZmljYXRpb24g
        QXV0aG9yaXR5MQswCQYDVQQLDAJHMjETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMCEAataM30fTBJYcEeQ70rNYEw
        DQYJKoZIhvcNAQELBQAEggEAfefnxn0gaYv/PtkGsQLLBey67KKdqwzYLOyM5tiOV4DTCs7TC3e5rFeK5243Jii0KsLXgST7GHOR
        0uR7QfYI2INbF9e2uZMPv0PQa/MD8HsAPoLG7RlOlW8iQoxyoOGuFXQ6eNdtbEQXz8+8iMgGWY3MuvZDgH6zzhl383R4oQeCKK8L
        ECqnp6AG5uQOG/Rtb9NLQtJh30NTlEThti4ugm4lOSUyZoLPTZMTPY1dQFbz9QKIC/nTJBYvGW9BtzypKa2UGFwu7GvxNjfLdjds
        HYchqPgLjXxv5BUnWgQoalbxsNnBi1z9SIHd/4Tu8/ysFklKP8rdyCpDklokIfsaigAAAAAAAA==
        """
        XCTAssertThrowsError(try TrustedCMSSignerInspector.verifiedSigner(
            signatureData: XCTUnwrap(Data(base64Encoded: signature, options: .ignoreUnknownCharacters)),
            contentData: fixture.content
        )) { error in
            XCTAssertEqual(error as? DistributionError, .invalidArtifact(
                "detached CMS signature does not authenticate its content"
            ))
        }
    }

    private func detachedCMSFixture() throws -> (signature: Data, content: Data) {
        // Public detached signature only; cryptographic checks are independent of certificate expiry and network trust.
        let content = """
        Hostwright detached CMS selection diagnostic only. This is not a release manifest, checksum, provenance statement, or authorization.
        Source 51c94cc081671ce2d3de1abaa12706042acc108c; failed run36969951719 attempt2.
        2026-10-02T10:31:25.348492+00:00
        """ + "\n"
        let signature = """
        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
        aRF24O2s0eumWfo31cRVsB4wcgYIKwYBBQUHAQEEZjBkMC4GCCsGAQUFBzAChiJodHRwOi8vY2VydHMuYXBwbGUuY29tL2Rldmlk
        ZzIuZGVyMDIGCCsGAQUFBzABhiZodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLWRldmlkZzIwMTCCAR4GA1UdIASCARUwggER
        MIIBDQYJKoZIhvdjZAUBMIH/MIHDBggrBgEFBQcCAjCBtgyBs1JlbGlhbmNlIG9uIHRoaXMgY2VydGlmaWNhdGUgYnkgYW55IHBh
        cnR5IGFzc3VtZXMgYWNjZXB0YW5jZSBvZiB0aGUgdGhlbiBhcHBsaWNhYmxlIHN0YW5kYXJkIHRlcm1zIGFuZCBjb25kaXRpb25z
        IG9mIHVzZSwgY2VydGlmaWNhdGUgcG9saWN5IGFuZCBjZXJ0aWZpY2F0aW9uIHByYWN0aWNlIHN0YXRlbWVudHMuMDcGCCsGAQUF
        BwIBFitodHRwczovL3d3dy5hcHBsZS5jb20vY2VydGlmaWNhdGVhdXRob3JpdHkvMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMDMB0G
        A1UdDgQWBBTFAsb5uBSKprfWotAYeH8d4TRWnjAOBgNVHQ8BAf8EBAMCB4AwHwYKKoZIhvdjZAYBIQQRDA8yMDI2MDcxNjAwMDAw
        MFowEwYKKoZIhvdjZAYBDQEB/wQCBQAwDQYJKoZIhvcNAQELBQADggEBAClQISmizPTS22uM+YudGY9qludeDqTBb/rCZU5YRJ3t
        xwANtpJ98OUf3VlyKHSaJb5HA2h9a+GghoEdyK1Iwiaftrvh8kmAyuV9NdvT/c5Ei4enUhR2kYPH3u1a7z+RqVC48k47zcg6gC8X
        vvV/kOn2jxHHAIcLfT+Ndv5w51x+BIypmuUC5QL63b2T0AqXbtOT0R4oHOcIVwYwJoSGSNWHniTLeEyam8EK4azOh93eyi6q90ns
        kPK/rPZmlNvoLwhvhl5+ZIWj0n1n08bF3xtu/yTRC6oE+2oicUupaD8+1JYrXiOf/58pLnUSsTE3VbWvqGxBK4sSFka+D1dQ7UYx
        ggMUMIIDEAIBATByMF4xLTArBgNVBAMMJERldmVsb3BlciBJRCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzIx
        EzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTAhAGrWjN9H0wSWHBHkO9KzWBMA0GCWCGSAFlAwQCAQUAoIIBczAYBgkq
        hkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjEwMDIxMDMxMzVaMC8GCSqGSIb3DQEJBDEiBCAxFYImARnz
        mTw4n6T6WONkW/JTE1AyQNvEMMYFqDtUizCBgQYJKwYBBAGCNxAEMXQwcjBeMS0wKwYDVQQDDCREZXZlbG9wZXIgSUQgQ2VydGlm
        aWNhdGlvbiBBdXRob3JpdHkxCzAJBgNVBAsMAkcyMRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUwIQBq1ozfR9MElh
        wR5DvSs1gTCBgwYLKoZIhvcNAQkQAgsxdKByMF4xLTArBgNVBAMMJERldmVsb3BlciBJRCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0
        eTELMAkGA1UECwwCRzIxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTAhAGrWjN9H0wSWHBHkO9KzWBMA0GCSqGSIb3
        DQEBCwUABIIBAC81wnnBdvNJKaubZtAfOXyqNQtuEwg80BI+VnLHR8YDiN5YHMxkzY/Sfo+uAf4ot75D0tXpDLZjH0MxCcl58XKH
        OV4To5gQl0duljCceqMTtfWholVfW9fbyPWyKuXB+uBbW2pJpMf+iBR9tUiNEYMQxUg5cFin+UPEJ5BrjfxdD/KDN/mDx/0yId8/
        xdQwZjVD0oGQXDA2MgfXLWJnkkAfgA8yrACjvlf3GSKieQkt4gGg0YMFgMXIDuR1RUuhz4DziT1R38q3Aq375A0H8kWpwxKoL1jj
        yl+bPFOKgcQcG0VK/hlQroGiE/CgdO887PzIfVGaKNTKcZEiD/E9tIQAAAAAAAA=
        """
        return (try XCTUnwrap(Data(base64Encoded: signature, options: .ignoreUnknownCharacters)), Data(content.utf8))
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

    private func makeManifest(
        schemaVersion: Int = 3,
        payloadModes: [String: Int] = DistributionLayout.payloadModes
    ) -> TrustedReleaseManifest {
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
            schemaVersion: schemaVersion,
            artifactID: artifactID,
            packageVersion: version,
            releaseTag: "v\(version)",
            sourceCommit: commit,
            sourceDirty: false,
            minimumMacOSMajorVersion: 26,
            createdAt: "2026-07-13T12:00:00Z",
            applicationSigner: application,
            installerSigner: installer,
            payloadFiles: payloadModes.keys.sorted().map {
                DistributionFileRecord(
                    path: $0,
                    sha256: digest,
                    sizeBytes: 1,
                    mode: payloadModes[$0]!
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
                        products: DistributionLayout.executableNames(
                            payloadPaths: Set(manifest.payloadFiles.map(\.path))
                        )!,
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

    private func provenanceWithEmptyDependencies(
        manifest: TrustedReleaseManifest
    ) throws -> TrustedReleaseProvenanceStatement {
        let data = try JSONEncoder().encode(makeProvenance(manifest: manifest))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var predicate = try XCTUnwrap(object["predicate"] as? [String: Any])
        var definition = try XCTUnwrap(predicate["buildDefinition"] as? [String: Any])
        var parameters = try XCTUnwrap(definition["internalParameters"] as? [String: Any])
        parameters["externalSwiftPMDependencies"] = [String]()
        definition["internalParameters"] = parameters
        definition["resolvedDependencies"] = [[
            "uri": "git+https://github.com/hostwright/hostwright.git",
            "digest": ["gitCommit": manifest.sourceCommit],
        ]]
        predicate["buildDefinition"] = definition
        object["predicate"] = predicate
        return try JSONDecoder().decode(
            TrustedReleaseProvenanceStatement.self,
            from: JSONSerialization.data(withJSONObject: object)
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

    private func recordedDesktopNotaryFixture() throws -> (
        archiveName: String, artifactID: String, object: [String: Any], signedHashes: [String: String]
    ) {
        let output = """
        {
          "logFormatVersion": 1,
          "jobId": "90a8e507-358a-47f6-97d9-7b9a31f573b5",
          "status": "Accepted",
          "statusSummary": "Ready for distribution",
          "statusCode": 0,
          "archiveFilename": "hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da.zip",
          "uploadDate": "2026-10-02T01:29:45.611Z",
          "sha256": "0a9336cfb6455c60a48d478ab6e6003a0d0b54e11ff04f988a24e835669c94a7",
          "ticketContents": [
            {
              "path": "hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da.zip/hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da/libexec/hostwright/Hostwright.app",
              "digestAlgorithm": "SHA-256",
              "cdhash": "53f90820d4a04d9cec5aedfc84324df4adc39c47",
              "arch": "arm64"
            },
            {
              "path": "hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da.zip/hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da/libexec/hostwright/Hostwright.app/Contents/MacOS/hostwright-desktop",
              "digestAlgorithm": "SHA-256",
              "cdhash": "53f90820d4a04d9cec5aedfc84324df4adc39c47",
              "arch": "arm64"
            },
            {
              "path": "hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da.zip/hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da/bin/hostwright-network-helper",
              "digestAlgorithm": "SHA-256",
              "cdhash": "d5c859a9ee16aef2330bf61f5261b86abea01853",
              "arch": "arm64"
            },
            {
              "path": "hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da.zip/hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da/bin/hostwright-dist",
              "digestAlgorithm": "SHA-256",
              "cdhash": "823c450796d5cd6119a30d0d464aec7c1ee05542",
              "arch": "arm64"
            },
            {
              "path": "hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da.zip/hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da/bin/hostwright-storage-helper",
              "digestAlgorithm": "SHA-256",
              "cdhash": "175b08442f6c43bb1ea400ac925bb061361564de",
              "arch": "arm64"
            },
            {
              "path": "hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da.zip/hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da/bin/hostwrightd",
              "digestAlgorithm": "SHA-256",
              "cdhash": "2c9c25450e0e8a543d8e7a097e1659ed73708d27",
              "arch": "arm64"
            },
            {
              "path": "hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da.zip/hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da/bin/hostwright-network-provider-worker",
              "digestAlgorithm": "SHA-256",
              "cdhash": "ed5cafbddde1c87bf8fec3a7b1c1d90b045c960b",
              "arch": "arm64"
            },
            {
              "path": "hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da.zip/hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da/bin/hostwright",
              "digestAlgorithm": "SHA-256",
              "cdhash": "372c3538febcc9afc208a7cd936cfee88e3ea9df",
              "arch": "arm64"
            },
            {
              "path": "hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da.zip/hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da/bin/hostwright-control",
              "digestAlgorithm": "SHA-256",
              "cdhash": "f7918175bcbe2b34888c483a07a5628ef32c9dd0",
              "arch": "arm64"
            },
            {
              "path": "hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da.zip/hostwright-0.0.2-rc.1-macos-arm64-f95ee80d66da/bin/hostwright-containerization-helper",
              "digestAlgorithm": "SHA-256",
              "cdhash": "123e3e5fa98c0995940c3d1bba8ae3dce8c4cc51",
              "arch": "arm64"
            }
          ],
          "issues": null
        }
        """
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        let archiveName = try XCTUnwrap(object["archiveFilename"] as? String)
        let artifactID = String(archiveName.dropLast(4))
        let prefix = "\(archiveName)/\(artifactID)/"
        let tickets = try XCTUnwrap(object["ticketContents"] as? [[String: String]])
        var signedHashes: [String: String] = [:]
        for ticket in tickets {
            let path = try XCTUnwrap(ticket["path"])
            XCTAssertTrue(path.hasPrefix(prefix))
            let relativePath = String(path.dropFirst(prefix.count))
            if relativePath != "libexec/hostwright/Hostwright.app" {
                signedHashes[relativePath] = try XCTUnwrap(ticket["cdhash"])
            }
        }
        return (archiveName, artifactID, object, signedHashes)
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
