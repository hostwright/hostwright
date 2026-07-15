import Foundation
import HostwrightCore
@testable import HostwrightDistribution
import XCTest

final class DistributionModelsTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let digest = String(repeating: "b", count: 64)

    func testPostCommitCleanupReportsPendingWithoutTurningCommittedMutationIntoFailure() {
        let extraction = URL(fileURLWithPath: "/tmp/hostwright-dist-lifecycle-extract-test")
        let pending = DistributionPostCommitCleanup.removeOwnedTemporaryItem(extraction) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(pending.pendingPaths, [extraction.path])

        let complete = DistributionPostCommitCleanup.removeOwnedTemporaryItem(extraction) { _ in }
        XCTAssertEqual(complete.status, .complete)
        XCTAssertEqual(complete.pendingPaths, [])
    }

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

        let mismatchedCommitPrefix = DistributionArtifactManifest(
            artifactID: "hostwright-0.1.0-alpha.1-macos-arm64-\(String(repeating: "c", count: 12))",
            packageVersion: manifest.packageVersion,
            sourceCommit: manifest.sourceCommit,
            sourceDirty: false,
            architecture: "arm64",
            createdAt: manifest.createdAt,
            files: manifest.files
        )
        XCTAssertThrowsError(try mismatchedCommitPrefix.validate())
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

    func testSemanticVersionOrderingAndLifecycleTransitionPolicyFailClosed() throws {
        let prior = try DistributionSemanticVersion(parsing: "0.0.1")
        let candidate = try DistributionSemanticVersion(parsing: "0.0.2-dev")
        let release = try DistributionSemanticVersion(parsing: "0.0.2")
        let historicalAlpha = try DistributionSemanticVersion(parsing: "0.1.0-alpha.1")

        XCTAssertLessThan(prior, candidate)
        XCTAssertLessThan(candidate, release)
        XCTAssertLessThan(release, historicalAlpha)
        XCTAssertEqual(
            try DistributionVersionTransition.classify(
                installedVersion: prior.rawValue,
                installedCommit: String(repeating: "a", count: 40),
                candidateVersion: candidate.rawValue,
                candidateCommit: String(repeating: "b", count: 40)
            ),
            .upgrade
        )
        XCTAssertEqual(
            try DistributionVersionTransition.classify(
                installedVersion: candidate.rawValue,
                installedCommit: String(repeating: "a", count: 40),
                candidateVersion: candidate.rawValue,
                candidateCommit: String(repeating: "a", count: 40)
            ),
            .repair
        )

        XCTAssertThrowsError(
            try DistributionVersionTransition.classify(
                installedVersion: historicalAlpha.rawValue,
                installedCommit: String(repeating: "a", count: 40),
                candidateVersion: release.rawValue,
                candidateCommit: String(repeating: "b", count: 40)
            )
        ) { error in
            XCTAssertEqual(
                error as? DistributionError,
                .downgradeRefused(installed: "0.1.0-alpha.1", candidate: "0.0.2")
            )
        }
        XCTAssertThrowsError(
            try DistributionVersionTransition.classify(
                installedVersion: candidate.rawValue,
                installedCommit: String(repeating: "a", count: 40),
                candidateVersion: candidate.rawValue,
                candidateCommit: String(repeating: "b", count: 40)
            )
        ) { error in
            XCTAssertEqual(
                error as? DistributionError,
                .versionConflict("Version 0.0.2-dev is already installed from a different source commit.")
            )
        }

        for invalid in [
            "v0.0.2", "00.0.2", "0.00.2", "0.0.02", "0.0", "0.0.2-01", "0.0.2+", "0.0.2\n"
        ] {
            XCTAssertThrowsError(try DistributionSemanticVersion(parsing: invalid), invalid)
        }
    }

    func testGeneratedVersionPairsPreserveStrictTransitionProperties() throws {
        let versions = [
            "0.0.0-alpha", "0.0.0", "0.0.1-alpha.1", "0.0.1",
            "0.0.2-dev", "0.0.2", "1.0.0"
        ]
        let installedCommit = String(repeating: "a", count: 40)
        let candidateCommit = String(repeating: "b", count: 40)

        for (installedIndex, installedVersion) in versions.enumerated() {
            XCTAssertEqual(
                try DistributionVersionTransition.classify(
                    installedVersion: installedVersion,
                    installedCommit: installedCommit,
                    candidateVersion: installedVersion,
                    candidateCommit: installedCommit
                ),
                .repair
            )
            XCTAssertThrowsError(
                try DistributionVersionTransition.classify(
                    installedVersion: installedVersion,
                    installedCommit: installedCommit,
                    candidateVersion: installedVersion,
                    candidateCommit: candidateCommit
                )
            )

            for (candidateIndex, candidateVersion) in versions.enumerated()
                where candidateIndex != installedIndex {
                if installedIndex < candidateIndex {
                    XCTAssertEqual(
                        try DistributionVersionTransition.classify(
                            installedVersion: installedVersion,
                            installedCommit: installedCommit,
                            candidateVersion: candidateVersion,
                            candidateCommit: candidateCommit
                        ),
                        .upgrade
                    )
                } else {
                    XCTAssertThrowsError(
                        try DistributionVersionTransition.classify(
                            installedVersion: installedVersion,
                            installedCommit: installedCommit,
                            candidateVersion: candidateVersion,
                            candidateCommit: candidateCommit
                        )
                    ) { error in
                        guard case .downgradeRefused = error as? DistributionError else {
                            return XCTFail("Expected downgrade refusal, received \(error)")
                        }
                    }
                }
            }
        }
    }

    func testDistributionJSONRejectsUnknownAndNoncanonicalFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-distribution-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("manifest.json")
        let canonical = try DistributionJSON.encode(validManifest())
        try canonical.write(to: url, options: .withoutOverwriting)
        XCTAssertNoThrow(try DistributionJSON.decode(DistributionArtifactManifest.self, from: url))

        let text = try XCTUnwrap(String(data: canonical, encoding: .utf8))
        let unknown = text.replacingOccurrences(
            of: "{\n",
            with: "{\n  \"unexpected\" : true,\n",
            options: .anchored
        )
        try Data(unknown.utf8).write(to: url, options: .atomic)
        XCTAssertThrowsError(try DistributionJSON.decode(DistributionArtifactManifest.self, from: url)) {
            XCTAssertEqual(
                $0 as? DistributionError,
                .invalidArtifact("JSON input is not the exact canonical schema encoding")
            )
        }
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
                SPDXID: "SPDXRef-File-\(index + 1)",
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
            name: "Hostwright \(manifest.packageVersion) artifact-content SBOM",
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

        let duplicateSPDXFile = DistributionSPDXDocument(
            spdxVersion: spdx.spdxVersion,
            dataLicense: spdx.dataLicense,
            SPDXID: spdx.SPDXID,
            name: spdx.name,
            documentNamespace: spdx.documentNamespace,
            creationInfo: spdx.creationInfo,
            packages: spdx.packages,
            files: spdx.files + [spdx.files[0]],
            relationships: spdx.relationships
        )
        XCTAssertThrowsError(try duplicateSPDXFile.validate(manifest: manifest, archive: archive)) {
            XCTAssertEqual(
                $0 as? DistributionError,
                .invalidArtifact("SPDX file inventory contains duplicate or malformed entries")
            )
        }

        let provenance = DistributionProvenanceStatement(
            statementType: "https://in-toto.io/Statement/v1",
            subject: [ProvenanceSubject(name: archive.fileName, digest: ["sha256": digest])],
            predicateType: "https://slsa.dev/provenance/v1",
            predicate: DistributionProvenancePredicate(
                buildDefinition: ProvenanceBuildDefinition(
                    buildType: "urn:hostwright:buildtype:swiftpm-archive:v1",
                    externalParameters: ProvenanceExternalParameters(
                        configuration: "release",
                        products: DistributionLayout.shippedExecutableNames,
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
