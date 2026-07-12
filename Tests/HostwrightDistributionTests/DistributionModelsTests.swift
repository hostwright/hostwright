import Foundation
import HostwrightCore
@testable import HostwrightDistribution
import XCTest

final class DistributionModelsTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let digest = String(repeating: "b", count: 64)

    func testManifestRequiresExactSafePayloadLayout() throws {
        let manifest = validManifest()
        XCTAssertNoThrow(try manifest.validate())

        let missing = DistributionArtifactManifest(
            artifactID: manifest.artifactID,
            packageVersion: manifest.packageVersion,
            sourceCommit: manifest.sourceCommit,
            sourceDirty: false,
            architecture: "arm64",
            createdAt: manifest.createdAt,
            files: Array(manifest.files.dropLast())
        )
        XCTAssertThrowsError(try missing.validate())

        var unsafe = manifest.files
        unsafe[0] = DistributionFileRecord(path: "../hostwright", sha256: digest, sizeBytes: 1, mode: 0o755)
        let traversing = DistributionArtifactManifest(
            artifactID: manifest.artifactID,
            packageVersion: manifest.packageVersion,
            sourceCommit: manifest.sourceCommit,
            sourceDirty: false,
            architecture: "arm64",
            createdAt: manifest.createdAt,
            files: unsafe.sorted { $0.path < $1.path }
        )
        XCTAssertThrowsError(try traversing.validate())
    }

    func testPathPolicyRejectsAbsoluteTraversalControlAndNestedFileNames() {
        XCTAssertTrue(DistributionPathPolicy.isSafeRelativePath("share/doc/hostwright/LICENSE"))
        XCTAssertFalse(DistributionPathPolicy.isSafeRelativePath("/tmp/file"))
        XCTAssertFalse(DistributionPathPolicy.isSafeRelativePath("../file"))
        XCTAssertFalse(DistributionPathPolicy.isSafeRelativePath("bin//hostwright"))
        XCTAssertFalse(DistributionPathPolicy.isSafeRelativePath("bin\\hostwright"))
        XCTAssertFalse(DistributionPathPolicy.isSafeRelativePath("bin/host\nwright"))
        XCTAssertTrue(DistributionPathPolicy.isSafeFileName("manifest.json"))
        XCTAssertFalse(DistributionPathPolicy.isSafeFileName("nested/manifest.json"))
    }

    func testSPDXAndProvenanceMustBindExactArchiveAndSource() throws {
        let manifest = validManifest()
        let archive = DistributionArtifactDescriptor(
            fileName: "\(manifest.artifactID).tar.gz",
            sha256: digest,
            sizeBytes: 10
        )
        let spdxFiles = manifest.files.enumerated().map { index, file in
            SPDXFileRecord(
                fileName: "./\(file.path)",
                SPDXID: "SPDXRef-File-\(index)",
                checksums: [SPDXChecksum(algorithm: "SHA256", checksumValue: file.sha256)],
                fileTypes: [file.path.hasPrefix("bin/") ? "BINARY" : "TEXT"],
                licenseConcluded: "NOASSERTION",
                copyrightText: "NOASSERTION"
            )
        }
        let spdx = DistributionSPDXDocument(
            spdxVersion: "SPDX-2.3",
            dataLicense: "CC0-1.0",
            SPDXID: "SPDXRef-DOCUMENT",
            name: "Hostwright artifact-content SBOM",
            documentNamespace: "urn:hostwright:spdx:\(commit):\(digest)",
            creationInfo: SPDXCreationInfo(created: manifest.createdAt, creators: ["Tool: hostwright-dist-1"]),
            packages: [
                SPDXPackageRecord(
                    name: "Hostwright",
                    SPDXID: "SPDXRef-Package-Hostwright",
                    versionInfo: manifest.packageVersion,
                    downloadLocation: "NOASSERTION",
                    filesAnalyzed: true,
                    checksums: [SPDXChecksum(algorithm: "SHA256", checksumValue: digest)],
                    licenseConcluded: "NOASSERTION",
                    licenseDeclared: "NOASSERTION",
                    copyrightText: "NOASSERTION"
                )
            ],
            files: spdxFiles,
            relationships: [
                SPDXRelationship(
                    spdxElementId: "SPDXRef-DOCUMENT",
                    relationshipType: "DESCRIBES",
                    relatedSpdxElement: "SPDXRef-Package-Hostwright"
                )
            ] + spdxFiles.map {
                SPDXRelationship(
                    spdxElementId: "SPDXRef-Package-Hostwright",
                    relationshipType: "CONTAINS",
                    relatedSpdxElement: $0.SPDXID
                )
            }
        )
        XCTAssertNoThrow(try spdx.validate(manifest: manifest, archive: archive))

        let provenance = DistributionProvenanceStatement(
            statementType: "https://in-toto.io/Statement/v1",
            subject: [ProvenanceSubject(name: archive.fileName, digest: ["sha256": digest])],
            predicateType: "https://slsa.dev/provenance/v1",
            predicate: DistributionProvenancePredicate(
                buildDefinition: ProvenanceBuildDefinition(
                    buildType: "urn:hostwright:buildtype:swiftpm-archive:v1",
                    externalParameters: ProvenanceExternalParameters(
                        configuration: "release",
                        products: ["hostwright", "hostwrightd"],
                        platform: "macos",
                        architecture: "arm64"
                    ),
                    internalParameters: ProvenanceInternalParameters(sourceDirty: false, unsigned: true),
                    resolvedDependencies: [
                        ProvenanceResolvedDependency(
                            uri: "git+https://github.com/hostwright/hostwright.git",
                            digest: ["gitCommit": commit]
                        )
                    ]
                ),
                runDetails: ProvenanceRunDetails(
                    builder: ProvenanceBuilder(id: "urn:hostwright:builder:local-swiftpm:v1"),
                    metadata: ProvenanceMetadata(
                        invocationId: UUID().uuidString,
                        startedOn: manifest.createdAt,
                        finishedOn: manifest.createdAt
                    )
                )
            )
        )
        XCTAssertNoThrow(try provenance.validate(manifest: manifest, archive: archive))

        let wrongSubject = DistributionProvenanceStatement(
            statementType: provenance.statementType,
            subject: [ProvenanceSubject(name: archive.fileName, digest: ["sha256": String(repeating: "c", count: 64)])],
            predicateType: provenance.predicateType,
            predicate: provenance.predicate
        )
        XCTAssertThrowsError(try wrongSubject.validate(manifest: manifest, archive: archive))
    }

    private func validManifest() -> DistributionArtifactManifest {
        DistributionArtifactManifest(
            artifactID: "hostwright-0.1.0-alpha.1-macos-arm64-\(commit.prefix(12))",
            packageVersion: "0.1.0-alpha.1",
            sourceCommit: commit,
            sourceDirty: false,
            architecture: "arm64",
            createdAt: "2026-07-12T19:00:00Z",
            files: DistributionLayout.payloadModes.keys.sorted().map { path in
                DistributionFileRecord(
                    path: path,
                    sha256: digest,
                    sizeBytes: 1,
                    mode: DistributionLayout.payloadModes[path]!
                )
            }
        )
    }
}
