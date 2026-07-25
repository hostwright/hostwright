import Foundation
import XCTest
@testable import HostwrightState

final class ImageOwnershipLedgerTests: XCTestCase {
    private let provider = "apple-container-cli"
    private let firstDigest = "sha256:" + String(repeating: "1", count: 64)
    private let secondDigest = "sha256:" + String(repeating: "2", count: 64)

    func testEmptyLegacyHistoryAndUnrelatedGroupsProduceEmptyProjection() throws {
        try withTemporaryStore { store in
            XCTAssertEqual(try store.imageOwnership.load(), .empty)

            try finishGroup(
                in: store,
                id: "unrelated",
                kind: "lifecycle-v1",
                status: .succeeded,
                updatedAt: "2026-07-24T00:00:00Z",
                metadata: #"{"not":"image ownership"}"#
            )
            try finishGroup(
                in: store,
                id: "failed-image",
                kind: ImageOwnershipLedger.groupKind,
                status: .failed,
                updatedAt: "2026-07-24T00:01:00Z",
                metadata: #"{"malformed":"ignored because it did not succeed"}"#
            )
            try acquireActiveGroup(
                in: store,
                id: "active-image",
                kind: ImageOwnershipLedger.groupKind
            )

            XCTAssertEqual(try store.imageOwnership.load(), .empty)
        }
    }

    func testExactOwnershipQueriesNeverAdoptUnrecordedImages() throws {
        try withTemporaryStore { store in
            try succeed(
                in: store,
                id: "pull",
                updatedAt: "2026-07-24T00:00:01Z",
                changes: [
                    try change(
                        .add,
                        reference: "registry.example.com/team/api:1",
                        digest: firstDigest
                    )
                ]
            )

            let projection = try store.imageOwnership.load()
            XCTAssertTrue(
                projection.ownsExact(
                    reference: "registry.example.com/team/api:1",
                    digest: firstDigest,
                    providerID: provider
                )
            )
            XCTAssertTrue(projection.ownsDigest(firstDigest, providerID: provider))
            XCTAssertEqual(
                projection.ownedReferences(forDigest: firstDigest, providerID: provider),
                ["registry.example.com/team/api:1"]
            )
            XCTAssertFalse(
                projection.ownsReference(
                    "registry.example.com/team/preexisting:1",
                    providerID: provider
                )
            )
            XCTAssertFalse(
                projection.ownsExact(
                    reference: "registry.example.com/team/api:1",
                    digest: secondDigest,
                    providerID: provider
                )
            )
        }
    }

    func testReplayUsesUpdatedAtThenIDRatherThanInsertionOrder() throws {
        try withTemporaryStore { store in
            try succeed(
                in: store,
                id: "group-z",
                updatedAt: "2026-07-24T00:00:02Z",
                changes: [
                    try change(.add, reference: "example/api:latest", digest: secondDigest)
                ]
            )
            try succeed(
                in: store,
                id: "group-a",
                updatedAt: "2026-07-24T00:00:01Z",
                changes: [
                    try change(.add, reference: "example/api:latest", digest: firstDigest)
                ]
            )

            var projection = try store.imageOwnership.load()
            XCTAssertTrue(
                projection.ownsExact(
                    reference: "example/api:latest",
                    digest: secondDigest,
                    providerID: provider
                )
            )

            try succeed(
                in: store,
                id: "same-time-a",
                updatedAt: "2026-07-24T00:00:03Z",
                changes: [
                    try change(.add, reference: "example/api:tied", digest: firstDigest)
                ]
            )
            try succeed(
                in: store,
                id: "same-time-b",
                updatedAt: "2026-07-24T00:00:03Z",
                changes: [
                    try change(.add, reference: "example/api:tied", digest: secondDigest)
                ]
            )

            projection = try store.imageOwnership.load()
            XCTAssertTrue(
                projection.ownsExact(
                    reference: "example/api:tied",
                    digest: secondDigest,
                    providerID: provider
                )
            )
        }
    }

    func testTagReplacementAndDeleteReplayExactly() throws {
        try withTemporaryStore { store in
            try succeed(
                in: store,
                id: "pull",
                updatedAt: "2026-07-24T00:00:01Z",
                changes: [
                    try change(.add, reference: "example/api:1", digest: firstDigest)
                ]
            )
            try succeed(
                in: store,
                id: "tag",
                updatedAt: "2026-07-24T00:00:02Z",
                changes: [
                    try change(.add, reference: "example/api:stable", digest: firstDigest)
                ]
            )
            try succeed(
                in: store,
                id: "replace",
                updatedAt: "2026-07-24T00:00:03Z",
                changes: [
                    try change(.add, reference: "example/api:1", digest: secondDigest)
                ]
            )
            try succeed(
                in: store,
                id: "delete-tag",
                updatedAt: "2026-07-24T00:00:04Z",
                changes: [
                    try change(.remove, reference: "example/api:stable", digest: firstDigest)
                ]
            )

            let projection = try store.imageOwnership.load()
            XCTAssertEqual(projection.records.count, 1)
            XCTAssertEqual(
                projection.records[0].reference,
                "example/api:1"
            )
            XCTAssertEqual(projection.records[0].digest, secondDigest)
            XCTAssertEqual(projection.records[0].providerID, provider)
            XCTAssertNotNil(
                projection.records[0].ownershipOperationID
            )
            XCTAssertEqual(
                projection.records[0].ownershipProofSHA256?.count,
                64
            )
        }
    }

    func testStaleRemovalCannotEraseNewerReplacement() throws {
        try withTemporaryStore { store in
            try succeed(
                in: store,
                id: "old",
                updatedAt: "2026-07-24T00:00:01Z",
                changes: [
                    try change(.add, reference: "example/api:latest", digest: firstDigest)
                ]
            )
            try succeed(
                in: store,
                id: "new",
                updatedAt: "2026-07-24T00:00:02Z",
                changes: [
                    try change(.add, reference: "example/api:latest", digest: secondDigest)
                ]
            )
            try succeed(
                in: store,
                id: "stale-delete",
                updatedAt: "2026-07-24T00:00:03Z",
                changes: [
                    try change(.remove, reference: "example/api:latest", digest: firstDigest)
                ]
            )

            XCTAssertTrue(
                try store.imageOwnership.load().ownsExact(
                    reference: "example/api:latest",
                    digest: secondDigest,
                    providerID: provider
                )
            )
        }
    }

    func testEveryReferenceMustBeExactlyOwnedForDigestCleanup() throws {
        try withTemporaryStore { store in
            try succeed(
                in: store,
                id: "owned",
                updatedAt: "2026-07-24T00:00:01Z",
                changes: [
                    try change(.add, reference: "example/api:1", digest: firstDigest),
                    try change(.add, reference: "example/api:stable", digest: firstDigest)
                ]
            )
            let projection = try store.imageOwnership.load()

            XCTAssertTrue(
                projection.everyReferenceIsOwned(
                    ["example/api:stable", "example/api:1"],
                    digest: firstDigest,
                    providerID: provider
                )
            )
            XCTAssertFalse(
                projection.everyReferenceIsOwned(
                    ["example/api:1", "example/api:unmanaged"],
                    digest: firstDigest,
                    providerID: provider
                )
            )
            XCTAssertFalse(
                projection.everyReferenceIsOwned(
                    ["example/api:1", "example/api:1"],
                    digest: firstDigest,
                    providerID: provider
                )
            )
            XCTAssertFalse(
                projection.everyReferenceIsOwned(
                    [],
                    digest: firstDigest,
                    providerID: provider
                )
            )
        }
    }

    func testSucceededMatchingGroupFailsClosedOnMalformedMetadata() throws {
        try withTemporaryStore { store in
            try finishGroup(
                in: store,
                id: "malformed",
                kind: ImageOwnershipLedger.groupKind,
                status: .succeeded,
                updatedAt: "2026-07-24T00:00:01Z",
                metadata: #"{"version":2,"changes":[]}"#
            )

            XCTAssertThrowsError(try store.imageOwnership.load()) { error in
                guard case StateStoreError.invalidRecord(let message) = error else {
                    return XCTFail("Expected fail-closed invalid metadata, got \(error).")
                }
                XCTAssertTrue(message.contains("malformed"))
                XCTAssertTrue(message.contains("unsupported"))
            }
        }
    }

    func testMetadataRejectsDuplicatesUnknownFieldsAndDuplicateJSONKeys() throws {
        let first = try change(.add, reference: "example/api:1", digest: firstDigest)
        let duplicate = try change(.remove, reference: "example/api:1", digest: firstDigest)

        XCTAssertThrowsError(
            try ImageOwnershipMetadataV1(changes: [first, duplicate])
        )

        XCTAssertThrowsError(
            try ImageOwnershipMetadataV1.decodeStrict(
                #"{"version":1,"changes":[{"action":"add","reference":"example/api:1","digest":"\#(firstDigest)","providerID":"\#(provider)","extra":true}]}"#
            )
        )

        XCTAssertThrowsError(
            try ImageOwnershipMetadataV1.decodeStrict(
                #"{"version":1,"version":1,"changes":[{"action":"add","reference":"example/api:1","digest":"\#(firstDigest)","providerID":"\#(provider)"}]}"#
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("duplicate JSON key"))
        }
    }

    func testMetadataEnforcesReferenceChangeAndByteBounds() throws {
        XCTAssertThrowsError(
            try change(
                .add,
                reference: "example/" + String(repeating: "a", count: 4_100),
                digest: firstDigest
            )
        )

        let tooMany = try (0...ImageOwnershipMetadataLimits.maximumChanges).map {
            try change(.add, reference: "example/image-\($0):1", digest: firstDigest)
        }
        XCTAssertThrowsError(try ImageOwnershipMetadataV1(changes: tooMany))

        let oversized = try (0..<20).map {
            try change(
                .add,
                reference: "example/" + String(repeating: "a", count: 3_800) + "-\($0):1",
                digest: firstDigest
            )
        }
        XCTAssertThrowsError(try ImageOwnershipMetadataV1(changes: oversized)) { error in
            XCTAssertTrue(String(describing: error).contains("byte limit"))
        }
    }

    func testCanonicalMetadataIsStableAcrossInputOrder() throws {
        let first = try change(.add, reference: "example/api:z", digest: firstDigest)
        let second = try change(.add, reference: "example/api:a", digest: secondDigest)
        let lhs = try ImageOwnershipMetadataV1(changes: [first, second])
        let rhs = try ImageOwnershipMetadataV1(changes: [second, first])
        let noChanges = try ImageOwnershipMetadataV1(changes: [])

        XCTAssertEqual(try lhs.canonicalJSONString(), try rhs.canonicalJSONString())
        XCTAssertEqual(
            try ImageOwnershipMetadataV1.decodeStrict(lhs.canonicalJSONString()),
            lhs
        )
        XCTAssertEqual(
            try ImageOwnershipMetadataV1.decodeStrict(noChanges.canonicalJSONString()),
            noChanges
        )
    }

    private func change(
        _ action: ImageOwnershipChangeAction,
        reference: String,
        digest: String
    ) throws -> ImageOwnershipChangeV1 {
        try ImageOwnershipChangeV1(
            action: action,
            reference: reference,
            digest: digest,
            providerID: provider
        )
    }

    private func succeed(
        in store: SQLiteStateStore,
        id: String,
        updatedAt: String,
        changes: [ImageOwnershipChangeV1]
    ) throws {
        try finishGroup(
            in: store,
            id: id,
            kind: ImageOwnershipLedger.groupKind,
            status: .succeeded,
            updatedAt: updatedAt,
            metadata: try ImageOwnershipMetadataV1(changes: changes).canonicalJSONString()
        )
    }

    private func finishGroup(
        in store: SQLiteStateStore,
        id: String,
        kind: String,
        status: OperationGroupStatus,
        updatedAt: String,
        metadata: String
    ) throws {
        try acquireActiveGroup(in: store, id: id, kind: kind)
        try store.operationGroups.finish(
            groupID: id,
            status: status,
            checkpoint: "verified",
            manualRecoveryHintRedacted: "",
            updatedAt: updatedAt,
            metadataJSONRedacted: metadata
        )
    }

    private func acquireActiveGroup(
        in store: SQLiteStateStore,
        id: String,
        kind: String
    ) throws {
        let group = OperationGroupRecord(
            id: id,
            operationID: "operation-\(id)",
            groupKind: kind,
            projectID: nil,
            serviceName: nil,
            plannedActionType: "image",
            status: .active,
            groupIdempotencyKey: "image:\(id)",
            planHash: String(repeating: "a", count: 64),
            checkpoint: "intent-persisted",
            lockOwner: "test",
            lockExpiresAt: "2026-07-24T01:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-24T00:00:00Z",
            updatedAt: "2026-07-24T00:00:00Z",
            metadataJSONRedacted: "{}"
        )
        XCTAssertNotNil(try store.operationGroups.acquire(group).acquired)
    }

    private func withTemporaryStore(
        _ body: (SQLiteStateStore) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-image-ownership-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        try store.migrate()
        try body(store)
    }
}
