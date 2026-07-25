import Foundation
import HostwrightCore
import HostwrightRegistry
@testable import HostwrightState
import XCTest

final class OCIReferrerRepositoryTests: XCTestCase {
    func testSchemaV9PersistsVerifiedGraphAndPayloads() throws {
        let fixture = try makeFixture()
        let store = try makeStore()
        defer { removeStore(store) }

        let saved = try store.ociReferrers.saveGraph(
            fixture.graph,
            observedAt: "2026-07-24T17:00:00Z"
        )
        let loaded = try store.ociReferrers.loadDiscovery(id: saved.id)

        XCTAssertEqual(
            try store.schemaVersion(),
            HostwrightContractVersions.stateSchema
        )
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(saved.subjectDigest, fixture.subject.canonicalValue)
        XCTAssertEqual(saved.descriptorCount, 1)
        XCTAssertTrue(saved.complete)

        let objects = try store.ociReferrers.loadObjects(
            discoveryID: saved.id
        )
        let reconstructed = try XCTUnwrap(
            store.ociReferrers.loadGraph(discoveryID: saved.id)
        )
        XCTAssertEqual(
            reconstructed.verifiedReferrers,
            fixture.graph.verifiedReferrers
        )
        XCTAssertEqual(
            reconstructed.objects.map(\.digest.canonicalValue).sorted(),
            fixture.graph.objects.map(\.digest.canonicalValue).sorted()
        )
        XCTAssertEqual(
            try store.ociReferrers.latestDiscovery(
                endpoint: "https://registry.example.com",
                repository: "team/app",
                subjectDigest: fixture.subject.canonicalValue,
                artifactType: nil
            ),
            saved
        )
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(
            objects.map(\.digest).sorted(),
            fixture.graph.objects.map(\.digest.canonicalValue).sorted()
        )
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: objects.map {
                    ($0.digest, $0.payload)
                }
            ),
            Dictionary(
                uniqueKeysWithValues: fixture.graph.objects.map {
                    ($0.digest.canonicalValue, $0.payload)
                }
            )
        )
    }

    func testLatestDiscoveryRequiresExactArtifactFilter() throws {
        let fixture = try makeFixture()
        let store = try makeStore()
        defer { removeStore(store) }
        let unfiltered = try store.ociReferrers.saveGraph(
            fixture.graph,
            observedAt: "2026-07-24T17:00:00Z"
        )
        let artifactType = try OCIArtifactType(
            "application/vnd.example.opaque.v1"
        )
        let filteredDiscovery = OCIReferrerDiscoveryResult(
            endpoint: fixture.graph.discovery.endpoint,
            repository: fixture.graph.discovery.repository,
            subjectDigest: fixture.subject,
            artifactType: artifactType,
            mode: .native,
            serverFilterApplied: true,
            pageCount: 1,
            descriptors: fixture.graph.verifiedReferrers,
            etag: #""filtered-v1""#
        )
        let filtered = try store.ociReferrers.saveGraph(
            OCIReferrerGraph(
                discovery: filteredDiscovery,
                verifiedReferrers: fixture.graph.verifiedReferrers,
                objects: fixture.graph.objects
            ),
            observedAt: "2026-07-24T17:01:00Z"
        )

        XCTAssertEqual(
            try store.ociReferrers.latestDiscovery(
                endpoint: "https://registry.example.com",
                repository: "team/app",
                subjectDigest: fixture.subject.canonicalValue,
                artifactType: nil
            ),
            unfiltered
        )
        XCTAssertEqual(
            try store.ociReferrers.latestDiscovery(
                endpoint: "https://registry.example.com",
                repository: "team/app",
                subjectDigest: fixture.subject.canonicalValue,
                artifactType: artifactType.value
            ),
            filtered
        )
    }

    func testLeaseBlocksExactDiscoveryRemovalUntilFencedRelease() throws {
        let fixture = try makeFixture()
        let store = try makeStore()
        defer { removeStore(store) }
        let discovery = try store.ociReferrers.saveGraph(
            fixture.graph,
            observedAt: "2026-07-24T17:00:00Z"
        )
        let lease = try store.ociReferrers.acquireRetentionLease(
            discoveryID: discovery.id,
            ownerID: "gate-7-verifier",
            acquiredAt: "2026-07-24T17:01:00Z",
            expiresAt: "2026-07-24T18:01:00Z"
        )

        XCTAssertThrowsError(
            try store.ociReferrers.removeDiscovery(
                id: discovery.id,
                expectedGraphSHA256: discovery.graphSHA256,
                currentTimestamp: "2026-07-24T17:02:00Z"
            )
        )
        XCTAssertFalse(
            try store.ociReferrers.releaseRetentionLease(
                id: lease.id,
                expectedFencingToken:
                    "00000000-0000-0000-0000-000000000000",
                releasedAt: "2026-07-24T17:03:00Z"
            )
        )
        XCTAssertTrue(
            try store.ociReferrers.releaseRetentionLease(
                id: lease.id,
                expectedFencingToken: lease.fencingToken,
                releasedAt: "2026-07-24T17:03:00Z"
            )
        )
        let leases = try store.ociReferrers.loadRetentionLeases(
            discoveryID: discovery.id
        )
        XCTAssertEqual(leases.count, 1)
        XCTAssertEqual(leases[0].id, lease.id)
        XCTAssertEqual(
            leases[0].releasedAt,
            "2026-07-24T17:03:00Z"
        )
        XCTAssertFalse(
            try store.ociReferrers.hasActiveRetentionLease(
                discoveryID: discovery.id,
                currentTimestamp: "2026-07-24T17:03:30Z"
            )
        )
        XCTAssertTrue(
            try store.ociReferrers.removeDiscovery(
                id: discovery.id,
                expectedGraphSHA256: discovery.graphSHA256,
                currentTimestamp: "2026-07-24T17:04:00Z"
            )
        )
        let removed = try store.ociReferrers.pruneUnreferencedCache(
            maximumObjects: 16,
            currentTimestamp: "2026-07-24T17:05:00Z"
        )
        XCTAssertEqual(removed.count, 2)
        XCTAssertTrue(
            try store.contentCache.listContent(
                providerScope: "oci-referrer-cache"
            ).isEmpty
        )
        XCTAssertTrue(
            try store.ociReferrers.loadObjects(
                discoveryID: discovery.id
            ).isEmpty
        )
    }

    func testCacheAccountingPinAndLeaseProtectExactUnreferencedObject()
        throws
    {
        let fixture = try makeFixture()
        let store = try makeStore()
        defer { removeStore(store) }
        let discovery = try store.ociReferrers.saveGraph(
            fixture.graph,
            observedAt: "2026-07-24T17:00:00Z"
        )
        XCTAssertEqual(
            try store.contentCache.listContent(
                providerScope: "oci-referrer-cache"
            ).count,
            2
        )
        XCTAssertTrue(
            try store.ociReferrers.removeDiscovery(
                id: discovery.id,
                expectedGraphSHA256: discovery.graphSHA256,
                currentTimestamp: "2026-07-24T17:01:00Z"
            )
        )
        XCTAssertTrue(
            try store.contentCache.setPinPolicy(
                providerScope: "oci-referrer-cache",
                digest: fixture.manifestDigest.canonicalValue,
                pinPolicy: .policyManaged,
                observedAt: "2026-07-24T17:02:00Z"
            )
        )
        let firstPrune = try store.ociReferrers
            .pruneUnreferencedCache(
                maximumObjects: 16,
                currentTimestamp: "2026-07-24T17:03:00Z"
            )
        XCTAssertEqual(firstPrune.count, 1)
        XCTAssertFalse(
            firstPrune.contains(fixture.manifestDigest.canonicalValue)
        )
        XCTAssertTrue(
            try store.contentCache.setPinPolicy(
                providerScope: "oci-referrer-cache",
                digest: fixture.manifestDigest.canonicalValue,
                pinPolicy: .unpinned,
                observedAt: "2026-07-24T17:04:00Z"
            )
        )
        let lease = try store.contentCache.acquireLease(
            providerScope: "oci-referrer-cache",
            digest: fixture.manifestDigest.canonicalValue,
            mode: .shared,
            ownerID: "reader",
            purpose: "verification",
            acquiredAt: "2026-07-24T17:05:00Z",
            expiresAt: "2026-07-24T17:15:00Z"
        )
        XCTAssertTrue(
            try store.ociReferrers.pruneUnreferencedCache(
                maximumObjects: 16,
                currentTimestamp: "2026-07-24T17:06:00Z"
            ).isEmpty
        )
        XCTAssertTrue(
            try store.contentCache.releaseLease(
                id: lease.id,
                expectedFencingToken: lease.fencingToken,
                releasedAt: "2026-07-24T17:07:00Z"
            )
        )
        XCTAssertEqual(
            try store.ociReferrers.pruneUnreferencedCache(
                maximumObjects: 16,
                currentTimestamp: "2026-07-24T17:08:00Z"
            ),
            [fixture.manifestDigest.canonicalValue]
        )
        XCTAssertTrue(
            try store.contentCache.listContent(
                providerScope: "oci-referrer-cache"
            ).isEmpty
        )
    }

    func testPublicationOwnershipProofIsImmutableAndLoadable() throws {
        let fixture = try makeFixture()
        let store = try makeStore()
        defer { removeStore(store) }
        let proof = String(repeating: "a", count: 64)
        let operationGroupID = HostwrightResourceUUID.generate()
        try insertOperationGroup(
            id: operationGroupID,
            into: store
        )

        _ = try store.ociReferrers.saveGraph(
            fixture.graph,
            publicationEvidence: [
                fixture.manifestDigest: OCIReferrerPublicationEvidence(
                    ownershipProofSHA256: proof,
                    operationGroupID: operationGroupID
                )
            ],
            observedAt: "2026-07-24T17:00:00Z"
        )
        let publication = try XCTUnwrap(
            store.ociReferrers.loadPublication(
                endpoint: "https://registry.example.com",
                repository: "team/app",
                subjectDigest: fixture.subject.canonicalValue,
                referrerDigest: fixture.manifestDigest.canonicalValue
            )
        )
        XCTAssertEqual(publication.ownershipProofSHA256, proof)
        XCTAssertEqual(publication.operationGroupID, operationGroupID)
        XCTAssertTrue(
            try store.ociReferrers.markPublicationCleaned(
                endpoint: publication.registryEndpoint,
                repository: publication.repository,
                subjectDigest: publication.subjectDigest,
                referrerDigest: publication.referrerDigest,
                expectedOwnershipProofSHA256: proof,
                observedAt: "2026-07-24T17:04:00Z"
            )
        )
        XCTAssertFalse(
            try XCTUnwrap(
                store.ociReferrers.loadPublication(
                    endpoint: publication.registryEndpoint,
                    repository: publication.repository,
                    subjectDigest: publication.subjectDigest,
                    referrerDigest: publication.referrerDigest
                )
            ).cleanupEligible
        )

        XCTAssertThrowsError(
            try store.ociReferrers.saveGraph(
                fixture.graph,
                publicationEvidence: [
                    fixture.manifestDigest:
                        OCIReferrerPublicationEvidence(
                            ownershipProofSHA256:
                                String(repeating: "b", count: 64),
                            operationGroupID: operationGroupID
                        )
                ],
                observedAt: "2026-07-24T17:05:00Z"
            )
        )
    }

    func testCacheLoadRejectsTamperedPayload() throws {
        let fixture = try makeFixture()
        let store = try makeStore()
        defer { removeStore(store) }
        let discovery = try store.ociReferrers.saveGraph(
            fixture.graph,
            observedAt: "2026-07-24T17:00:00Z"
        )
        try store.withValidatedConnection { connection in
            try connection.run(
                """
                UPDATE oci_referrer_cache_objects
                SET payload_base64 = ?
                WHERE digest = ?
                """,
                bindings: [
                    .text(Data("tampered".utf8).base64EncodedString()),
                    .text(fixture.manifestDigest.canonicalValue)
                ]
            )
        }

        XCTAssertThrowsError(
            try store.ociReferrers.loadObjects(
                discoveryID: discovery.id
            )
        )
        let integrity = StateIntegrityService(store: store).inspect()
        XCTAssertEqual(integrity.health, .unrecoverable)
        XCTAssertTrue(
            integrity.checks.contains {
                $0.identifier == "hostwright.authoritative-records" &&
                    $0.status == .failed
            }
        )
    }

    private func makeStore() throws -> SQLiteStateStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-referrers-\(UUID().uuidString).sqlite"
            ).path
        let store = SQLiteStateStore(path: path)
        try store.migrate()
        return store
    }

    private func insertOperationGroup(
        id: String,
        into store: SQLiteStateStore
    ) throws {
        let record = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "oci-referrer-lifecycle",
            projectID: nil,
            serviceName: nil,
            plannedActionType: "publish",
            status: .active,
            groupIdempotencyKey: String(repeating: "f", count: 64),
            planHash: String(repeating: "f", count: 64),
            checkpoint: "intent-persisted",
            lockOwner: "test",
            lockExpiresAt: "2099-01-01T00:00:00Z",
            rollbackAvailable: false,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-24T16:59:00Z",
            updatedAt: "2026-07-24T16:59:00Z",
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

    private func removeStore(_ store: SQLiteStateStore) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                atPath: store.path + suffix
            )
        }
    }

    private func makeFixture() throws -> (
        graph: OCIReferrerGraph,
        subject: OCIContentDigest,
        manifestDigest: OCIContentDigest
    ) {
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "1", count: 64)
        )
        let blob = Data("opaque".utf8)
        let blobDigest = try OCIContentDigest.sha256(of: blob)
        let manifest = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "mediaType":
                    OCIReferrerDescriptor.manifestMediaType,
                "artifactType": "application/vnd.example.opaque.v1",
                "subject": [
                    "mediaType":
                        OCIReferrerDescriptor.manifestMediaType,
                    "digest": subject.canonicalValue,
                    "size": 1
                ],
                "config": [
                    "mediaType": "application/vnd.example.opaque.v1",
                    "digest": blobDigest.canonicalValue,
                    "size": blob.count
                ],
                "layers": []
            ],
            options: [.sortedKeys]
        )
        let manifestDigest = try OCIContentDigest.sha256(of: manifest)
        let child = try OCIContentDescriptor(
            mediaType: "application/vnd.example.opaque.v1",
            digest: blobDigest,
            size: blob.count
        )
        let rootObject = try OCIReferrerFetchedObject(
            digest: manifestDigest,
            mediaType: OCIReferrerDescriptor.manifestMediaType,
            size: manifest.count,
            kind: .manifest,
            payload: manifest,
            childDescriptors: [child]
        )
        let blobObject = try OCIReferrerFetchedObject(
            digest: blobDigest,
            mediaType: child.mediaType,
            size: blob.count,
            kind: .blob,
            payload: blob,
            childDescriptors: []
        )
        let descriptor = try OCIReferrerDescriptor(
            mediaType: OCIReferrerDescriptor.manifestMediaType,
            digest: manifestDigest,
            size: manifest.count,
            artifactType: OCIArtifactType(
                "application/vnd.example.opaque.v1"
            ),
            annotations: [:]
        )
        let discovery = OCIReferrerDiscoveryResult(
            endpoint: try RegistryEndpoint("registry.example.com"),
            repository: try OCIRepositoryName("team/app"),
            subjectDigest: subject,
            artifactType: nil,
            mode: .native,
            serverFilterApplied: false,
            pageCount: 1,
            descriptors: [descriptor],
            etag: #""graph-v1""#
        )
        return (
            try OCIReferrerGraph(
                discovery: discovery,
                verifiedReferrers: [descriptor],
                objects: [rootObject, blobObject]
            ),
            subject,
            manifestDigest
        )
    }
}
