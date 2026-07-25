import Foundation
@testable import HostwrightState
import XCTest

final class ContentCacheRepositoryTests: XCTestCase {
    func testContentAccountingIsBoundedDeterministicAndMonotonic()
        throws
    {
        let store = try makeStore()
        defer { removeStore(store) }
        let content = makeContent()

        try store.contentCache.upsert(content)
        XCTAssertTrue(
            try store.contentCache.touch(
                providerScope: content.providerScope,
                digest: content.digest,
                lastUsedAt: "2026-07-25T12:01:00Z",
                observedAt: "2026-07-25T12:01:00Z"
            )
        )
        XCTAssertTrue(
            try store.contentCache.setPinPolicy(
                providerScope: content.providerScope,
                digest: content.digest,
                pinPolicy: .operatorManaged,
                observedAt: "2026-07-25T12:02:00Z"
            )
        )

        let snapshot = try store.contentCache.snapshot(
            currentTimestamp: "2026-07-25T12:02:00Z"
        )
        XCTAssertEqual(snapshot.contents.count, 1)
        XCTAssertEqual(snapshot.contents[0].pinPolicy, .operatorManaged)
        XCTAssertEqual(
            snapshot.contents[0].lastUsedAt,
            "2026-07-25T12:01:00Z"
        )
        XCTAssertEqual(snapshot.totalBytes, 42)
        XCTAssertEqual(snapshot.pinnedBytes, 42)
        XCTAssertThrowsError(
            try store.contentCache.listContent(limit: 1_025)
        )
        XCTAssertThrowsError(
            try store.contentCache.touch(
                providerScope: content.providerScope,
                digest: content.digest,
                lastUsedAt: "2026-07-25T11:00:00Z",
                observedAt: "2026-07-25T12:03:00Z"
            )
        )
    }

    func testOwnedReferenceRequiresExactProofAndRemovalIdentity()
        throws
    {
        let store = try makeStore()
        defer { removeStore(store) }
        let content = makeContent()
        try store.contentCache.upsert(content)
        let reference = makeReference(content: content)
        try store.contentCache.saveReference(reference)

        XCTAssertEqual(
            try store.contentCache.listReferences(
                providerScope: content.providerScope
            ),
            [reference]
        )
        XCTAssertFalse(
            try store.contentCache.removeReference(
                id: reference.id,
                providerScope: reference.providerScope,
                reference: reference.reference,
                digest: reference.digest,
                ownershipOperationID: reference.ownershipOperationID,
                ownershipProofSHA256: String(repeating: "b", count: 64)
            )
        )
        XCTAssertTrue(
            try store.contentCache.removeReference(
                id: reference.id,
                providerScope: reference.providerScope,
                reference: reference.reference,
                digest: reference.digest,
                ownershipOperationID: reference.ownershipOperationID,
                ownershipProofSHA256: reference.ownershipProofSHA256
            )
        )
        XCTAssertTrue(
            try store.contentCache.listReferences(
                providerScope: content.providerScope
            ).isEmpty
        )
    }

    func testSharedReadersCoexistAndExclusiveLeaseConflictsByDigest()
        throws
    {
        let store = try makeStore()
        defer { removeStore(store) }
        let content = makeContent()
        try store.contentCache.upsert(content)

        let first = try store.contentCache.acquireLease(
            providerScope: content.providerScope,
            digest: content.digest,
            mode: .shared,
            ownerID: "reader-1",
            purpose: "inspect",
            acquiredAt: "2026-07-25T12:01:00Z",
            expiresAt: "2026-07-25T12:11:00Z"
        )
        _ = try store.contentCache.acquireLease(
            providerScope: content.providerScope,
            digest: content.digest,
            mode: .shared,
            ownerID: "reader-2",
            purpose: "inspect",
            acquiredAt: "2026-07-25T12:02:00Z",
            expiresAt: "2026-07-25T12:12:00Z"
        )
        XCTAssertThrowsError(
            try store.contentCache.acquireLease(
                providerScope: content.providerScope,
                digest: content.digest,
                mode: .exclusiveDelete,
                ownerID: "collector",
                purpose: "plan-1",
                acquiredAt: "2026-07-25T12:03:00Z",
                expiresAt: "2026-07-25T12:13:00Z"
            )
        )
        XCTAssertFalse(
            try store.contentCache.releaseLease(
                id: first.id,
                expectedFencingToken:
                    "00000000-0000-0000-0000-000000000000",
                releasedAt: "2026-07-25T12:04:00Z"
            )
        )
        XCTAssertTrue(
            try store.contentCache.releaseLease(
                id: first.id,
                expectedFencingToken: first.fencingToken,
                releasedAt: "2026-07-25T12:04:00Z"
            )
        )
    }

    func testStaleLeaseDoesNotBlockExclusiveDeletionLease() throws {
        let store = try makeStore()
        defer { removeStore(store) }
        let content = makeContent()
        try store.contentCache.upsert(content)
        _ = try store.contentCache.acquireLease(
            providerScope: content.providerScope,
            digest: content.digest,
            mode: .shared,
            ownerID: "expired-reader",
            purpose: "inspect",
            acquiredAt: "2026-07-25T12:01:00Z",
            expiresAt: "2026-07-25T12:02:00Z"
        )

        let lease = try store.contentCache.acquireLease(
            providerScope: content.providerScope,
            digest: content.digest,
            mode: .exclusiveDelete,
            ownerID: "collector",
            purpose: "plan-2",
            acquiredAt: "2026-07-25T12:03:00Z",
            expiresAt: "2026-07-25T12:13:00Z"
        )
        XCTAssertEqual(lease.mode, .exclusiveDelete)
        XCTAssertEqual(
            try store.contentCache.activeLeases(
                providerScope: content.providerScope,
                digest: content.digest,
                currentTimestamp: "2026-07-25T12:03:00Z"
            ),
            [lease]
        )
    }

    func testSeparateStoreConnectionCannotRaceExclusiveLease()
        throws
    {
        let store = try makeStore()
        defer { removeStore(store) }
        let second = SQLiteStateStore(path: store.path)
        let content = makeContent()
        try store.contentCache.upsert(content)
        _ = try store.contentCache.acquireLease(
            providerScope: content.providerScope,
            digest: content.digest,
            mode: .exclusiveDelete,
            ownerID: "collector",
            purpose: "plan-3",
            acquiredAt: "2026-07-25T12:01:00Z",
            expiresAt: "2026-07-25T12:11:00Z"
        )

        XCTAssertThrowsError(
            try second.contentCache.acquireLease(
                providerScope: content.providerScope,
                digest: content.digest,
                mode: .shared,
                ownerID: "racing-reader",
                purpose: "inspect",
                acquiredAt: "2026-07-25T12:02:00Z",
                expiresAt: "2026-07-25T12:12:00Z"
            )
        )
        XCTAssertThrowsError(
            try second.contentCache.upsert(
                ContentCacheRecord(
                    providerScope: content.providerScope,
                    digest: content.digest,
                    kind: content.kind,
                    sizeBytes: content.sizeBytes,
                    createdAt: content.createdAt,
                    observedAt: "2026-07-25T12:02:00Z",
                    lastUsedAt: "2026-07-25T12:02:00Z"
                )
            )
        )
    }

    func testExclusiveLeaseAllowsOwnedReferenceCleanupThenExactContentRemoval()
        throws
    {
        let store = try makeStore()
        defer { removeStore(store) }
        let content = makeContent()
        let reference = makeReference(content: content)
        try store.contentCache.upsert(content)
        try store.contentCache.saveReference(reference)
        let lease = try store.contentCache.acquireLease(
            providerScope: content.providerScope,
            digest: content.digest,
            mode: .exclusiveDelete,
            ownerID: "collector",
            purpose: "plan-4",
            acquiredAt: "2026-07-25T12:01:00Z",
            expiresAt: "2026-07-25T12:11:00Z"
        )
        XCTAssertThrowsError(
            try store.contentCache.removeContent(
                providerScope: content.providerScope,
                digest: content.digest,
                expectedKind: content.kind,
                expectedSizeBytes: content.sizeBytes,
                expectedCreatedAt: content.createdAt,
                exclusiveLeaseID: lease.id,
                expectedFencingToken: lease.fencingToken,
                removedAt: "2026-07-25T12:02:00Z"
            )
        )
        XCTAssertTrue(
            try store.contentCache.removeReferenceUnderLease(
                id: reference.id,
                providerScope: reference.providerScope,
                reference: reference.reference,
                digest: reference.digest,
                ownershipOperationID: reference.ownershipOperationID,
                ownershipProofSHA256: reference.ownershipProofSHA256,
                exclusiveLeaseID: lease.id,
                expectedFencingToken: lease.fencingToken,
                removedAt: "2026-07-25T12:02:30Z"
            )
        )
        XCTAssertTrue(
            try store.contentCache.removeContent(
                providerScope: content.providerScope,
                digest: content.digest,
                expectedKind: content.kind,
                expectedSizeBytes: content.sizeBytes,
                expectedCreatedAt: content.createdAt,
                exclusiveLeaseID: lease.id,
                expectedFencingToken: lease.fencingToken,
                removedAt: "2026-07-25T12:03:00Z"
            )
        )
        XCTAssertTrue(try store.contentCache.listContent().isEmpty)
        XCTAssertTrue(
            try store.contentCache.activeLeases(
                providerScope: content.providerScope,
                currentTimestamp: "2026-07-25T12:03:30Z"
            ).isEmpty
        )
    }

    func testExclusiveLeaseCannotAuthorizeAnUnrelatedOwnedReference()
        throws
    {
        let store = try makeStore()
        defer { removeStore(store) }
        let first = makeContent()
        let second = ContentCacheRecord(
            providerScope: first.providerScope,
            digest: "sha256:" + String(repeating: "b", count: 64),
            kind: first.kind,
            sizeBytes: 84,
            createdAt: first.createdAt,
            observedAt: first.observedAt,
            lastUsedAt: first.lastUsedAt
        )
        let secondReference = ContentCacheReferenceRecord(
            id: "00000000-0000-0000-0000-000000000021",
            providerScope: second.providerScope,
            reference: "registry.example.com/team/other:stable",
            digest: second.digest,
            ownershipOperationID:
                "00000000-0000-0000-0000-000000000022",
            ownershipProofSHA256: String(repeating: "b", count: 64),
            createdAt: second.createdAt,
            observedAt: second.observedAt
        )
        try store.contentCache.upsert(first)
        try store.contentCache.upsert(second)
        try store.contentCache.saveReference(secondReference)

        XCTAssertThrowsError(
            try store.contentCache.acquireLease(
                providerScope: first.providerScope,
                digest: first.digest,
                reference: secondReference.reference,
                mode: .exclusiveDelete,
                ownerID: "collector",
                purpose: "cross-digest-attempt",
                acquiredAt: "2026-07-25T12:01:00Z",
                expiresAt: "2026-07-25T12:11:00Z"
            )
        )

        let firstLease = try store.contentCache.acquireLease(
            providerScope: first.providerScope,
            digest: first.digest,
            mode: .exclusiveDelete,
            ownerID: "collector",
            purpose: "exact-digest",
            acquiredAt: "2026-07-25T12:01:30Z",
            expiresAt: "2026-07-25T12:11:30Z"
        )
        XCTAssertThrowsError(
            try store.contentCache.removeReferenceUnderLease(
                id: secondReference.id,
                providerScope: secondReference.providerScope,
                reference: secondReference.reference,
                digest: secondReference.digest,
                ownershipOperationID:
                    secondReference.ownershipOperationID,
                ownershipProofSHA256:
                    secondReference.ownershipProofSHA256,
                exclusiveLeaseID: firstLease.id,
                expectedFencingToken: firstLease.fencingToken,
                removedAt: "2026-07-25T12:02:00Z"
            )
        )
        XCTAssertEqual(
            try store.contentCache.listReferences(
                providerScope: second.providerScope,
                digest: second.digest
            ),
            [secondReference]
        )
    }

    func testPinsBlockExclusiveLeaseUntilExplicitlyCleared() throws {
        let store = try makeStore()
        defer { removeStore(store) }
        let content = makeContent(pinPolicy: .policyManaged)
        try store.contentCache.upsert(content)
        XCTAssertThrowsError(
            try store.contentCache.acquireLease(
                providerScope: content.providerScope,
                digest: content.digest,
                mode: .exclusiveDelete,
                ownerID: "collector",
                purpose: "plan-5",
                acquiredAt: "2026-07-25T12:01:00Z",
                expiresAt: "2026-07-25T12:11:00Z"
            )
        )
        XCTAssertTrue(
            try store.contentCache.setPinPolicy(
                providerScope: content.providerScope,
                digest: content.digest,
                pinPolicy: .unpinned,
                observedAt: "2026-07-25T12:01:00Z"
            )
        )
        XCTAssertNoThrow(
            try store.contentCache.acquireLease(
                providerScope: content.providerScope,
                digest: content.digest,
                mode: .exclusiveDelete,
                ownerID: "collector",
                purpose: "plan-5",
                acquiredAt: "2026-07-25T12:02:00Z",
                expiresAt: "2026-07-25T12:12:00Z"
            )
        )
    }

    func testRejectsInvalidBoundaryInputs() throws {
        let store = try makeStore()
        defer { removeStore(store) }
        XCTAssertThrowsError(
            try store.contentCache.upsert(
                ContentCacheRecord(
                    providerScope: "../unsafe",
                    digest: "sha256:" + String(repeating: "A", count: 64),
                    kind: .runtimeImage,
                    sizeBytes: -1,
                    createdAt: "not-time",
                    observedAt: "not-time",
                    lastUsedAt: "not-time"
                )
            )
        )
        let content = makeContent()
        try store.contentCache.upsert(content)
        XCTAssertThrowsError(
            try store.contentCache.acquireLease(
                providerScope: content.providerScope,
                digest: content.digest,
                mode: .shared,
                ownerID: String(repeating: "x", count: 129),
                purpose: "inspect",
                acquiredAt: "2026-07-25T12:00:00Z",
                expiresAt: "2026-07-27T12:00:00Z"
            )
        )
    }

    private func makeContent(
        pinPolicy: ContentCachePinPolicy = .unpinned
    ) -> ContentCacheRecord {
        ContentCacheRecord(
            providerScope: "apple-container-cli",
            digest: "sha256:" + String(repeating: "a", count: 64),
            kind: .runtimeImage,
            sizeBytes: 42,
            pinPolicy: pinPolicy,
            createdAt: "2026-07-25T12:00:00Z",
            observedAt: "2026-07-25T12:00:00Z",
            lastUsedAt: "2026-07-25T12:00:00Z"
        )
    }

    private func makeReference(
        content: ContentCacheRecord
    ) -> ContentCacheReferenceRecord {
        ContentCacheReferenceRecord(
            id: "00000000-0000-0000-0000-000000000011",
            providerScope: content.providerScope,
            reference: "registry.example.com/team/app:stable",
            digest: content.digest,
            ownershipOperationID:
                "00000000-0000-0000-0000-000000000012",
            ownershipProofSHA256: String(repeating: "a", count: 64),
            createdAt: "2026-07-25T12:00:00Z",
            observedAt: "2026-07-25T12:00:00Z"
        )
    }

    private func makeStore() throws -> SQLiteStateStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-content-cache-\(UUID().uuidString).sqlite"
            ).path
        let store = SQLiteStateStore(path: path)
        try store.migrate()
        return store
    }

    private func removeStore(_ store: SQLiteStateStore) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                atPath: store.path + suffix
            )
        }
    }
}
