import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightState

final class OperationGroupResumeTests: XCTestCase {
    func testProjectlessInterruptedGroupRefusesActiveIdempotencyConflict() throws {
        try withTemporaryStore { store in
            let target = operationGroup(
                id: "secret-target",
                key: "secret:create:api-token",
                projectID: nil
            )
            try acquireAndInterrupt(target, in: store)

            let conflict = operationGroup(
                id: "secret-conflict",
                key: target.groupIdempotencyKey,
                projectID: nil
            )
            XCTAssertNotNil(try store.operationGroups.acquire(conflict).acquired)

            XCTAssertThrowsError(
                try store.operationGroups.resumeInterrupted(
                    groupID: target.id,
                    expectedFencingToken: target.fencingToken,
                    lockOwner: "resumer",
                    lockExpiresAt: "2026-07-24T00:30:00Z",
                    updatedAt: "2026-07-24T00:02:00Z"
                )
            ) { error in
                guard case StateStoreError.invalidRecord(let message) = error else {
                    return XCTFail("Expected an invalid-record conflict, got \(error).")
                }
                XCTAssertTrue(message.contains("same idempotency key"))
            }

            XCTAssertEqual(try store.operationGroups.load(id: target.id)?.status, .interrupted)
            XCTAssertEqual(try store.operationGroups.load(id: conflict.id)?.status, .active)
        }
    }

    func testInterruptedGroupStillRefusesActiveProjectConflict() throws {
        try withTemporaryStore { store in
            let target = operationGroup(
                id: "project-target",
                key: "project:update:target",
                projectID: "project-1"
            )
            try acquireAndInterrupt(target, in: store)

            let conflict = operationGroup(
                id: "project-conflict",
                key: "project:update:conflict",
                projectID: "project-1"
            )
            XCTAssertNotNil(try store.operationGroups.acquire(conflict).acquired)

            XCTAssertThrowsError(
                try store.operationGroups.resumeInterrupted(
                    groupID: target.id,
                    expectedFencingToken: target.fencingToken,
                    lockOwner: "resumer",
                    lockExpiresAt: "2026-07-24T00:30:00Z",
                    updatedAt: "2026-07-24T00:02:00Z"
                )
            ) { error in
                guard case StateStoreError.invalidRecord(let message) = error else {
                    return XCTFail("Expected an invalid-record conflict, got \(error).")
                }
                XCTAssertTrue(message.contains("active for this project"))
            }

            XCTAssertEqual(try store.operationGroups.load(id: target.id)?.status, .interrupted)
            XCTAssertEqual(try store.operationGroups.load(id: conflict.id)?.status, .active)
        }
    }

    func testInterruptedGroupResumesWhenNoAdmissionConflictExists() throws {
        try withTemporaryStore { store in
            let target = operationGroup(
                id: "secret-resumable",
                key: "secret:update:resumable",
                projectID: nil
            )
            try acquireAndInterrupt(target, in: store)

            let resumed = try store.operationGroups.resumeInterrupted(
                groupID: target.id,
                expectedFencingToken: target.fencingToken,
                lockOwner: "resumer",
                lockExpiresAt: "2026-07-24T00:30:00Z",
                updatedAt: "2026-07-24T00:02:00Z"
            )

            XCTAssertEqual(resumed.status, .active)
            XCTAssertEqual(resumed.lockOwner, "resumer")
            XCTAssertEqual(resumed.lockExpiresAt, "2026-07-24T00:30:00Z")
        }
    }

    private func acquireAndInterrupt(
        _ group: OperationGroupRecord,
        in store: SQLiteStateStore
    ) throws {
        XCTAssertNotNil(try store.operationGroups.acquire(group).acquired)
        try store.operationGroups.finish(
            groupID: group.id,
            status: .interrupted,
            checkpoint: "interrupted",
            manualRecoveryHintRedacted: "resume after verification",
            updatedAt: "2026-07-24T00:01:00Z",
            metadataJSONRedacted: "{}"
        )
    }

    private func operationGroup(
        id: String,
        key: String,
        projectID: String?
    ) -> OperationGroupRecord {
        OperationGroupRecord(
            id: id,
            operationID: "operation-\(id)",
            groupKind: "secret-mutation",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: "update",
            status: .active,
            groupIdempotencyKey: key,
            planHash: String(repeating: "a", count: 64),
            checkpoint: "intent-persisted",
            lockOwner: "initial-owner",
            lockExpiresAt: "2026-07-24T00:10:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-24T00:00:00Z",
            updatedAt: "2026-07-24T00:00:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: HostwrightResourceUUID.generate()
        )
    }

    private func withTemporaryStore(
        _ body: (SQLiteStateStore) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-operation-resume-\(UUID().uuidString)"
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
