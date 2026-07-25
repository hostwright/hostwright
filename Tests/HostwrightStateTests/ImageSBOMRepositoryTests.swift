import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightState

final class ImageSBOMRepositoryTests: XCTestCase {
    func testRecordRoundTripsIdempotentlyAndProtectsCleanupReferences()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let groupID = HostwrightResourceUUID.generate()
            try insertOperationGroup(id: groupID, into: store)
            let discoveryID = try insertDiscovery(
                graphSHA256: String(repeating: "a", count: 64),
                sbomReferrerDigest:
                    "sha256:\(String(repeating: "b", count: 64))",
                documentDigest:
                    "sha512:\(String(repeating: "c", count: 128))",
                provenanceReferrerDigest:
                    "sha256:\(String(repeating: "d", count: 64))",
                provenanceDescriptorDigest:
                    "sha256:\(String(repeating: "e", count: 64))",
                into: store
            )

            let record = ImageSBOMRecord(
                projectID: "project-demo",
                serviceName: "api",
                descriptorDigest: "sha256:\(String(repeating: "1", count: 64))",
                policySHA256: String(repeating: "2", count: 64),
                format: .spdxJSON,
                documentDigest: "sha512:\(String(repeating: "c", count: 128))",
                documentMediaType: "application/spdx+json",
                evidenceDiscoveryID: discoveryID,
                evidenceGraphSHA256: String(repeating: "a", count: 64),
                sbomReferrerDigest: "sha256:\(String(repeating: "b", count: 64))",
                provenanceDescriptorDigest:
                    "sha256:\(String(repeating: "e", count: 64))",
                provenanceReferrerDigest:
                    "sha256:\(String(repeating: "d", count: 64))",
                componentCount: 42,
                normalizedComponentsSHA256: String(repeating: "3", count: 64),
                operationGroupID: groupID,
                createdAt: "2026-07-25T12:00:00Z"
            )

            let saved = try store.imageSBOM.record(record)
            XCTAssertEqual(try store.imageSBOM.record(record), saved)
            XCTAssertEqual(
                try store.imageSBOM.loadRecords(
                    projectID: record.projectID,
                    serviceName: record.serviceName,
                    descriptorDigest: record.descriptorDigest,
                    policySHA256: record.policySHA256
                ),
                [saved]
            )
            XCTAssertTrue(
                try store.imageSBOM.hasActiveReference(
                    discoveryID: discoveryID,
                    referrerDigest: record.sbomReferrerDigest
                )
            )
            XCTAssertTrue(
                try store.imageSBOM.hasActiveReference(
                    discoveryID: discoveryID,
                    referrerDigest:
                        try XCTUnwrap(record.provenanceReferrerDigest)
                )
            )
            XCTAssertFalse(
                try store.imageSBOM.hasActiveReference(
                    discoveryID: discoveryID,
                    referrerDigest:
                        "sha256:\(String(repeating: "f", count: 64))"
                )
            )
        }
    }

    func testConflictingDuplicateFailsClosed() throws {
        try withStore { store in
            try seedProject(store)
            let initialGroupID = HostwrightResourceUUID.generate()
            try insertOperationGroup(id: initialGroupID, into: store)
            let discoveryID = try insertDiscovery(
                graphSHA256: String(repeating: "4", count: 64),
                sbomReferrerDigest:
                    "sha256:\(String(repeating: "5", count: 64))",
                documentDigest:
                    "sha256:\(String(repeating: "6", count: 64))",
                provenanceReferrerDigest: nil,
                provenanceDescriptorDigest: nil,
                into: store
            )

            let original = ImageSBOMRecord(
                projectID: "project-demo",
                serviceName: "api",
                descriptorDigest: "sha256:\(String(repeating: "7", count: 64))",
                policySHA256: String(repeating: "8", count: 64),
                format: .cyclonedxJSON,
                documentDigest: "sha256:\(String(repeating: "6", count: 64))",
                documentMediaType: "application/vnd.cyclonedx+json",
                evidenceDiscoveryID: discoveryID,
                evidenceGraphSHA256: String(repeating: "4", count: 64),
                sbomReferrerDigest: "sha256:\(String(repeating: "5", count: 64))",
                componentCount: 2,
                normalizedComponentsSHA256: String(repeating: "9", count: 64),
                operationGroupID: initialGroupID,
                createdAt: "2026-07-25T12:30:00Z"
            )
            _ = try store.imageSBOM.record(original)
            try store.operationGroups.finish(
                groupID: initialGroupID,
                status: .succeeded,
                checkpoint: "binding-observed",
                manualRecoveryHintRedacted: "",
                updatedAt: "2026-07-25T12:30:30Z",
                metadataJSONRedacted: "{}"
            )

            let conflictingGroupID = HostwrightResourceUUID.generate()
            try insertOperationGroup(id: conflictingGroupID, into: store)
            XCTAssertThrowsError(
                try store.imageSBOM.record(
                    ImageSBOMRecord(
                        projectID: original.projectID,
                        serviceName: original.serviceName,
                        descriptorDigest: original.descriptorDigest,
                        policySHA256: original.policySHA256,
                        format: original.format,
                        documentDigest: original.documentDigest,
                        documentMediaType: original.documentMediaType,
                        evidenceDiscoveryID: original.evidenceDiscoveryID,
                        evidenceGraphSHA256: original.evidenceGraphSHA256,
                        sbomReferrerDigest: original.sbomReferrerDigest,
                        componentCount: original.componentCount,
                        normalizedComponentsSHA256:
                            original.normalizedComponentsSHA256,
                        operationGroupID: conflictingGroupID,
                        createdAt: "2026-07-25T12:31:00Z"
                    )
                )
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "different immutable evidence"
                    )
                )
            }
        }
    }

    func testRecordRejectsMissingExactDiscoveryEvidenceBinding() throws {
        try withStore { store in
            try seedProject(store)
            let groupID = HostwrightResourceUUID.generate()
            try insertOperationGroup(id: groupID, into: store)
            let discoveryID = try insertDiscovery(
                graphSHA256: String(repeating: "a", count: 64),
                sbomReferrerDigest:
                    "sha256:\(String(repeating: "b", count: 64))",
                documentDigest:
                    "sha256:\(String(repeating: "c", count: 64))",
                provenanceReferrerDigest: nil,
                provenanceDescriptorDigest: nil,
                into: store
            )

            XCTAssertThrowsError(
                try store.imageSBOM.record(
                    ImageSBOMRecord(
                        projectID: "project-demo",
                        serviceName: "api",
                        descriptorDigest:
                            "sha256:\(String(repeating: "1", count: 64))",
                        policySHA256: String(repeating: "2", count: 64),
                        format: .spdxJSON,
                        documentDigest:
                            "sha256:\(String(repeating: "f", count: 64))",
                        documentMediaType: "application/spdx+json",
                        evidenceDiscoveryID: discoveryID,
                        evidenceGraphSHA256: String(repeating: "a", count: 64),
                        sbomReferrerDigest:
                            "sha256:\(String(repeating: "b", count: 64))",
                        componentCount: 1,
                        normalizedComponentsSHA256:
                            String(repeating: "3", count: 64),
                        operationGroupID: groupID,
                        createdAt: "2026-07-25T12:00:00Z"
                    )
                )
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "exact persisted SBOM document object"
                    )
                )
            }
        }
    }

    private func seedProject(_ store: SQLiteStateStore) throws {
        try store.desiredStates.saveManifestSnapshot(
            projectID: "project-demo",
            manifestPath: "hostwright.yaml",
            manifestHash: "manifest-hash",
            desiredGeneration: 1,
            manifest: HostwrightManifest(project: "demo", services: []),
            timestamp: "2026-07-25T11:00:00Z",
            mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue
        )
    }

    private func insertOperationGroup(
        id: String,
        into store: SQLiteStateStore
    ) throws {
        let identity = id.replacingOccurrences(
            of: "-",
            with: ""
        )
        let idempotency = identity + identity
        let planHash = String(idempotency.reversed())
        let record = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "image-sbom-lifecycle",
            projectID: "project-demo",
            serviceName: "api",
            plannedActionType: "ingest",
            status: .active,
            groupIdempotencyKey: idempotency,
            planHash: planHash,
            checkpoint: "intent-persisted",
            lockOwner: "test",
            lockExpiresAt: "2099-01-01T00:00:00Z",
            rollbackAvailable: false,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-25T11:59:00Z",
            updatedAt: "2026-07-25T11:59:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: HostwrightResourceUUID.generate(),
            intentJSONRedacted: "{}",
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        let acquired = try store.operationGroups.acquire(
            record,
            currentTimestamp: record.createdAt
        )
        XCTAssertEqual(acquired.acquired?.id, id)
    }

    private func insertDiscovery(
        graphSHA256: String,
        sbomReferrerDigest: String,
        documentDigest: String,
        provenanceReferrerDigest: String?,
        provenanceDescriptorDigest: String?,
        into store: SQLiteStateStore
    ) throws -> String {
        let discoveryID = HostwrightResourceUUID.generate()
        let sbomReferrerID = HostwrightResourceUUID.generate()
        try store.withValidatedConnection { connection in
            try connection.run(
                """
                INSERT INTO oci_referrer_discoveries (
                    id, registry_endpoint, repository, subject_digest,
                    artifact_type, discovery_mode, server_filter_applied,
                    page_count, descriptor_count, graph_sha256, etag,
                    complete, observed_at
                )
                VALUES (?, ?, ?, ?, NULL, 'native', 0, 1, 2, ?, NULL, 1, ?)
                """,
                bindings: [
                    .text(discoveryID),
                    .text("https://registry.example.com"),
                    .text("team/api"),
                    .text("sha256:\(String(repeating: "1", count: 64))"),
                    .text(graphSHA256),
                    .text("2026-07-25T11:58:00Z")
                ]
            )
            try connection.run(
                """
                INSERT INTO oci_referrers (
                    id, discovery_id, registry_endpoint, repository,
                    subject_digest, referrer_digest, media_type,
                    artifact_type, size_bytes, annotations_json,
                    verified_subject, observed_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, '{}', 1, ?)
                """,
                bindings: [
                    .text(sbomReferrerID),
                    .text(discoveryID),
                    .text("https://registry.example.com"),
                    .text("team/api"),
                    .text("sha256:\(String(repeating: "1", count: 64))"),
                    .text(sbomReferrerDigest),
                    .text("application/vnd.oci.image.manifest.v1+json"),
                    .text("application/spdx+json"),
                    .int(512),
                    .text("2026-07-25T11:58:00Z")
                ]
            )
            try connection.run(
                """
                INSERT INTO oci_referrer_cache_objects (
                    digest, media_type, size_bytes, object_kind,
                    payload_base64, payload_sha256, children_json,
                    created_at, last_accessed_at
                )
                VALUES (?, ?, 2, 'blob', 'e30=', ?, '[]', ?, ?)
                """,
                bindings: [
                    .text(documentDigest),
                    .text("application/spdx+json"),
                    .text(String(repeating: "a", count: 64)),
                    .text("2026-07-25T11:58:00Z"),
                    .text("2026-07-25T11:58:00Z")
                ]
            )
            try connection.run(
                """
                INSERT INTO oci_referrer_graph_objects (
                    discovery_id, referrer_digest, object_digest
                )
                VALUES (?, ?, ?)
                """,
                bindings: [
                    .text(discoveryID),
                    .text(sbomReferrerDigest),
                    .text(documentDigest)
                ]
            )

            if let provenanceReferrerDigest,
               let provenanceDescriptorDigest {
                try connection.run(
                    """
                    INSERT INTO oci_referrer_cache_objects (
                        digest, media_type, size_bytes, object_kind,
                        payload_base64, payload_sha256, children_json,
                        created_at, last_accessed_at
                    )
                    VALUES (?, ?, 2, 'blob', 'e30=', ?, '[]', ?, ?)
                    """,
                    bindings: [
                        .text(provenanceDescriptorDigest),
                        .text("application/vnd.in-toto+json"),
                        .text(String(repeating: "b", count: 64)),
                        .text("2026-07-25T11:58:01Z"),
                        .text("2026-07-25T11:58:01Z")
                    ]
                )
                try connection.run(
                    """
                    INSERT INTO oci_referrers (
                        id, discovery_id, registry_endpoint, repository,
                        subject_digest, referrer_digest, media_type,
                        artifact_type, size_bytes, annotations_json,
                        verified_subject, observed_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, '{}', 1, ?)
                    """,
                    bindings: [
                        .text(HostwrightResourceUUID.generate()),
                        .text(discoveryID),
                        .text("https://registry.example.com"),
                        .text("team/api"),
                        .text("sha256:\(String(repeating: "1", count: 64))"),
                        .text(provenanceReferrerDigest),
                        .text("application/vnd.oci.image.manifest.v1+json"),
                        .text("application/vnd.in-toto+json"),
                        .int(1024),
                        .text("2026-07-25T11:58:01Z")
                    ]
                )
                try connection.run(
                    """
                    INSERT INTO oci_referrer_graph_objects (
                        discovery_id, referrer_digest, object_digest
                    )
                    VALUES (?, ?, ?)
                    """,
                    bindings: [
                        .text(discoveryID),
                        .text(provenanceReferrerDigest),
                        .text(provenanceDescriptorDigest)
                    ]
                )
            }
        }
        return discoveryID
    }

    private func withStore(
        _ body: (SQLiteStateStore) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-image-sbom-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        try store.migrate()
        try body(store)
    }
}
