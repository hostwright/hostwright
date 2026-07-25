import CryptoKit
import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightRegistry
@testable import HostwrightState

final class ImageProvenanceRepositoryTests: XCTestCase {
    func testRecordRoundTripsIdempotentlyAndProtectsExactReferrer()
        throws
    {
        try withStore { store, directory in
            try seedProject(store)
            let groupID = try insertOperationGroup(into: store)
            let fixture = try provenanceFixture(
                store: store,
                directory: directory,
                operationGroupID: groupID
            )

            let saved = try store.imageProvenance.record(
                fixture.record
            )
            XCTAssertEqual(
                try store.imageProvenance.record(fixture.record),
                saved
            )
            XCTAssertEqual(
                try store.imageProvenance.loadRecord(id: saved.id),
                saved
            )
            XCTAssertEqual(
                try store.imageProvenance.loadRecords(
                    projectID: saved.projectID,
                    serviceName: saved.serviceName,
                    descriptorDigest: saved.descriptorDigest,
                    policySHA256: saved.policySHA256
                ),
                [saved]
            )
            XCTAssertTrue(
                try store.imageProvenance.hasActiveReference(
                    discoveryID: saved.evidenceDiscoveryID,
                    referrerDigest: saved.referrerDigest
                )
            )
            XCTAssertFalse(
                try store.imageProvenance.hasActiveReference(
                    discoveryID: saved.evidenceDiscoveryID,
                    referrerDigest: digest("f").canonicalValue
                )
            )
            XCTAssertEqual(
                StateIntegrityService(store: store).inspect().health,
                .healthy
            )
        }
    }

    func testConflictingDuplicateAndInexactEvidenceFailClosed()
        throws
    {
        try withStore { store, directory in
            try seedProject(store)
            let groupID = try insertOperationGroup(into: store)
            let fixture = try provenanceFixture(
                store: store,
                directory: directory,
                operationGroupID: groupID
            )
            _ = try store.imageProvenance.record(fixture.record)
            try store.operationGroups.finish(
                groupID: groupID,
                status: .succeeded,
                checkpoint: "provenance-verified",
                manualRecoveryHintRedacted: "",
                updatedAt: "2026-07-24T00:05:30Z",
                metadataJSONRedacted: "{}"
            )

            let secondGroupID = try insertOperationGroup(
                into: store
            )
            let conflict = replacing(
                fixture.record,
                operationGroupID: secondGroupID,
                createdAt: "2026-07-24T00:06:00Z"
            )
            XCTAssertEqual(conflict.id, fixture.record.id)
            XCTAssertThrowsError(
                try store.imageProvenance.record(conflict)
            ) {
                XCTAssertTrue(
                    String(describing: $0).contains(
                        "different immutable evidence"
                    )
                )
            }

            let inexact = replacing(
                fixture.record,
                envelopeDigest: try digest("e").canonicalValue
            )
            XCTAssertThrowsError(
                try store.imageProvenance.record(inexact)
            ) {
                XCTAssertTrue(
                    String(describing: $0).contains(
                        "exact verified OCI provenance referrer"
                    )
                )
            }
        }
    }

    func testIntegrityDetectsTamperedImmutableProvenanceMetadata()
        throws
    {
        try withStore { store, directory in
            try seedProject(store)
            let groupID = try insertOperationGroup(into: store)
            let fixture = try provenanceFixture(
                store: store,
                directory: directory,
                operationGroupID: groupID
            )
            let saved = try store.imageProvenance.record(
                fixture.record
            )
            try store.withValidatedConnection { connection in
                try connection.run(
                    """
                    UPDATE image_provenance_records
                    SET signature_sha256 = ?
                    WHERE id = ?
                    """,
                    bindings: [
                        .text(String(repeating: "f", count: 64)),
                        .text(saved.id)
                    ]
                )
            }

            let report = StateIntegrityService(
                store: store
            ).inspect()
            XCTAssertEqual(report.health, .unrecoverable)
            XCTAssertEqual(
                report.checks.first {
                    $0.identifier ==
                        "hostwright.authoritative-records"
                }?.status,
                .failed
            )
        }
    }

    func testSchemaV12MigratesToV13WithoutGaps() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(
            path: directory.appendingPathComponent(
                "state.sqlite"
            ).path
        )
        try MigrationRunner().apply(
            to: store,
            throughVersion: 12
        )
        XCTAssertEqual(try store.schemaVersion(), 12)

        try store.migrate()

        XCTAssertEqual(
            try store.schemaVersion(),
            HostwrightContractVersions.stateSchema
        )
        let evidence = try store.withConnection(
            createIfNeeded: false,
            readOnly: true
        ) { connection in
            let versions = try connection.query(
                """
                SELECT version
                FROM schema_migrations
                ORDER BY version
                """
            ).compactMap { $0.first ?? nil }.compactMap(Int.init)
            let tables = Set(
                try connection.query(
                    """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'table'
                      AND name = 'image_provenance_records'
                    """
                ).compactMap { $0.first ?? nil }
            )
            let indexes = Set(
                try connection.query(
                    """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'index'
                      AND name LIKE 'image_provenance_records_%'
                    """
                ).compactMap { $0.first ?? nil }
            )
            return (versions, tables, indexes)
        }
        XCTAssertEqual(
            evidence.0,
            Array(1...HostwrightContractVersions.stateSchema)
        )
        XCTAssertEqual(
            evidence.1,
            Set(["image_provenance_records"])
        )
        XCTAssertEqual(
            evidence.2,
            Set([
                "image_provenance_records_cleanup_idx",
                "image_provenance_records_operation_idx",
                "image_provenance_records_statement_idx",
                "image_provenance_records_subject_idx"
            ])
        )
    }

    private func provenanceFixture(
        store: SQLiteStateStore,
        directory: URL,
        operationGroupID: String
    ) throws -> (
        record: ImageProvenanceRecord,
        artifact: ImageProvenanceArtifact
    ) {
        let subject = try digest("a")
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 7, count: 32)
        )
        let build = try ImageBuildProvenanceRecord.parse(
            buildRecord(subject: subject),
            expectedSubjectDigest: subject
        )
        let signed = try ImageProvenanceDSSEEnvelope.sign(
            statementPayload: build.statementPayload(
                signerID: "release-builder"
            ),
            expectedSubjectDigest: subject,
            signerID: "release-builder",
            privateKeyText:
                privateKey.rawRepresentation.base64EncodedString()
        )
        let artifact = try ImageProvenanceArtifact.make(
            envelopePayload: signed.envelopePayload,
            subjectDescriptor: try OCIContentDescriptor(
                mediaType:
                    OCIReferrerDescriptor.manifestMediaType,
                digest: subject,
                size: 512
            ),
            endpoint: try RegistryEndpoint(
                "https://registry.example.test"
            ),
            repository: try OCIRepositoryName("team/image")
        )
        let discovery = try store.ociReferrers.saveGraph(
            artifact.graph,
            observedAt: "2026-07-24T00:02:00Z"
        )
        let keyURL = directory.appendingPathComponent(
            "provenance-signer-\(UUID().uuidString).pub"
        )
        try privateKey.publicKey.rawRepresentation.write(to: keyURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyURL.path
        )
        let policy = try ImageProvenancePolicy(
            requirement: .required,
            builderIDs: [
                "urn:hostwright:builder:apple-container"
            ],
            buildTypes: [
                "https://hostwright.dev/build-types/apple-container/v1"
            ],
            signers: [
                try ImageProvenanceSigner(
                    id: "release-builder",
                    publicKeyPath: keyURL.path
                )
            ],
            maximumAgeSeconds: 3_600,
            requireReproducible: true
        )
        let material = try ImageProvenancePolicyMaterial.resolve(
            policy
        )
        let verification = try ImageProvenanceVerifier.verify(
            envelopePayload: signed.envelopePayload,
            expectedSubjectDigest: subject,
            policy: policy,
            material: material,
            at: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-07-24T00:05:00Z"
                )
            )
        )
        return (
            ImageProvenanceRecord(
                projectID: "project-demo",
                serviceName: "api",
                referrerDigest:
                    artifact.rootDescriptor.digest.canonicalValue,
                evidenceDiscoveryID: discovery.id,
                evidenceGraphSHA256: discovery.graphSHA256,
                verification: verification,
                operationGroupID: operationGroupID,
                createdAt: "2026-07-24T00:05:00Z"
            ),
            artifact
        )
    }

    private func replacing(
        _ record: ImageProvenanceRecord,
        envelopeDigest: String? = nil,
        operationGroupID: String? = nil,
        createdAt: String? = nil
    ) -> ImageProvenanceRecord {
        ImageProvenanceRecord(
            projectID: record.projectID,
            serviceName: record.serviceName,
            descriptorDigest: record.descriptorDigest,
            policySHA256: record.policySHA256,
            statementDigest: record.statementDigest,
            envelopeDigest:
                envelopeDigest ?? record.envelopeDigest,
            referrerDigest: record.referrerDigest,
            evidenceDiscoveryID: record.evidenceDiscoveryID,
            evidenceGraphSHA256: record.evidenceGraphSHA256,
            sourceURI: record.sourceURI,
            sourceDigest: record.sourceDigest,
            builderID: record.builderID,
            builderVersion: record.builderVersion,
            buildType: record.buildType,
            invocationID: record.invocationID,
            normalizedMaterialsSHA256:
                record.normalizedMaterialsSHA256,
            commandSHA256: record.commandSHA256,
            environmentPolicySHA256:
                record.environmentPolicySHA256,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt,
            reproducibilityStatus:
                record.reproducibilityStatus,
            comparisonDigest: record.comparisonDigest,
            signerID: record.signerID,
            signerPublicKeySHA256:
                record.signerPublicKeySHA256,
            signatureSHA256: record.signatureSHA256,
            verifierVersion: record.verifierVersion,
            verifiedAt: record.verifiedAt,
            operationGroupID:
                operationGroupID ?? record.operationGroupID,
            createdAt: createdAt ?? record.createdAt
        )
    }

    private func buildRecord(
        subject: OCIContentDigest
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "source": [
                    "uri":
                        "https://source.example.test/repository",
                    "digest":
                        try digest("1").canonicalValue
                ],
                "builder": [
                    "id":
                        "urn:hostwright:builder:apple-container",
                    "version": "1.0.0"
                ],
                "buildType":
                    "https://hostwright.dev/build-types/apple-container/v1",
                "invocationID":
                    "00000000-0000-4000-8000-000000000010",
                "dependencies": [[
                    "uri":
                        "https://packages.example.test/library.json",
                    "digest":
                        try digest("2").canonicalValue
                ]],
                "materials": [[
                    "uri": "urn:hostwright:base-image",
                    "digest":
                        try digest("3").canonicalValue
                ]],
                "command": [
                    "name": "apple-container-build",
                    "version": 1,
                    "contextDigest":
                        try digest("4").canonicalValue,
                    "definitionDigest":
                        try digest("5").canonicalValue,
                    "target": "release"
                ],
                "environment": [
                    "mode": "allowlisted",
                    "network": "declared",
                    "variables": ["LANG"],
                    "secretVariables": ["REGISTRY_TOKEN"]
                ],
                "startedAt": "2026-07-24T00:00:00Z",
                "finishedAt": "2026-07-24T00:01:00Z",
                "output": [
                    "name": "team/image",
                    "digest": subject.canonicalValue
                ],
                "reproducibility": [
                    "status": "verified",
                    "comparisonDigest": subject.canonicalValue
                ]
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func seedProject(
        _ store: SQLiteStateStore
    ) throws {
        try store.desiredStates.saveManifestSnapshot(
            projectID: "project-demo",
            manifestPath: "hostwright.yaml",
            manifestHash: "manifest-hash",
            desiredGeneration: 1,
            manifest: HostwrightManifest(
                project: "demo",
                services: []
            ),
            timestamp: "2026-07-23T23:55:00Z",
            mutationProvider: "apple-container-cli"
        )
    }

    private func insertOperationGroup(
        into store: SQLiteStateStore
    ) throws -> String {
        let id = HostwrightResourceUUID.generate()
        let identity = id.replacingOccurrences(
            of: "-",
            with: ""
        )
        let record = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "image-provenance-lifecycle",
            projectID: "project-demo",
            serviceName: "api",
            plannedActionType: "verify",
            status: .active,
            groupIdempotencyKey: identity + identity,
            planHash: String((identity + identity).reversed()),
            checkpoint: "intent-persisted",
            lockOwner: "test",
            lockExpiresAt: "2099-01-01T00:00:00Z",
            rollbackAvailable: false,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-23T23:59:00Z",
            updatedAt: "2026-07-23T23:59:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: HostwrightResourceUUID.generate(),
            intentJSONRedacted: "{}",
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        let result = try store.operationGroups.acquire(
            record,
            currentTimestamp: record.createdAt
        )
        XCTAssertEqual(result.acquired?.id, id)
        return id
    }

    private func digest(
        _ scalar: Character
    ) throws -> OCIContentDigest {
        try OCIContentDigest(
            "sha256:" + String(repeating: scalar, count: 64)
        )
    }

    private func withStore(
        _ body: (SQLiteStateStore, URL) throws -> Void
    ) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(
            path: directory.appendingPathComponent(
                "state.sqlite"
            ).path
        )
        try store.migrate()
        try body(store, directory)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-image-provenance-\(UUID().uuidString)",
                isDirectory: true
            )
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
