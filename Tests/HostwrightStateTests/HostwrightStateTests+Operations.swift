import Foundation
import Synchronization
import XCTest
@testable import HostwrightRuntime
@testable import HostwrightState

extension HostwrightStateTests {
    func testOperationLedgerRecordsIntentWithoutExecution() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try store.operations.record(
                OperationRecord(
                    id: "operation-1",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    plannedActionType: "create",
                    projectID: projectID,
                    serviceName: "api",
                    status: .planned,
                    idempotencyKey: "plan-hash:create:api",
                    planHash: "plan-hash",
                    payloadJSONRedacted: #"{"password":"\#(fakeSecret)"}"#
                )
            )
            try store.operations.record(
                OperationRecord(
                    id: "operation-2",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    plannedActionType: "createMissingService",
                    projectID: projectID,
                    serviceName: "api",
                    status: .succeeded,
                    idempotencyKey: "plan-hash:create:api:2",
                    planHash: "plan-hash",
                    payloadJSONRedacted: #"{"result":"succeeded"}"#
                )
            )
            try store.operations.record(
                OperationRecord(
                    id: "operation-3",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    plannedActionType: "createMissingService",
                    projectID: projectID,
                    serviceName: "api",
                    status: .recorded,
                    idempotencyKey: "plan-hash:create:api:retry",
                    planHash: "plan-hash",
                    payloadJSONRedacted: #"{"intent":"recorded"}"#
                )
            )
            try store.operations.record(
                OperationRecord(
                    id: "operation-4",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    plannedActionType: "createMissingService",
                    projectID: projectID,
                    serviceName: "api",
                    status: .failed,
                    idempotencyKey: "plan-hash:create:api:retry",
                    planHash: "plan-hash",
                    payloadJSONRedacted: #"{"error":"token=\#(fakeSecret)"}"#
                )
            )
            XCTAssertEqual(try store.operations.latest(idempotencyKey: "plan-hash:create:api:retry")?.status, .failed)
            try store.operations.record(
                OperationRecord(
                    id: "operation-5",
                    createdAt: timestamp,
                    updatedAt: "2026-07-01T00:00:01Z",
                    plannedActionType: "createMissingService",
                    projectID: projectID,
                    serviceName: "api",
                    status: .succeeded,
                    idempotencyKey: "plan-hash:create:api:retry",
                    planHash: "plan-hash",
                    payloadJSONRedacted: #"{"result":"succeeded"}"#
                )
            )

            let operations = try store.operations.loadAll()
            XCTAssertEqual(operations.count, 5)
            XCTAssertEqual(operations[0].status, .planned)
            XCTAssertEqual(operations[1].status, .succeeded)
            XCTAssertEqual(operations[2].status, .recorded)
            XCTAssertEqual(operations[3].status, .failed)
            XCTAssertEqual(operations[4].status, .succeeded)
            XCTAssertFalse(operations[0].payloadJSONRedacted.contains(fakeSecret))
            XCTAssertFalse(operations[3].payloadJSONRedacted.contains(fakeSecret))
            XCTAssertTrue(
                operations.allSatisfy {
                    StateJSON.isObject($0.payloadJSONRedacted)
                }
            )
            XCTAssertEqual(try store.operations.latest(idempotencyKey: "plan-hash:create:api:retry")?.status, .succeeded)
        }
    }

    func testOperationGroupsAcquireReleaseAndRedactRecoveryHints() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            let group = OperationGroupRecord(
                id: "group-1",
                operationID: "operation-1",
                groupKind: "apply",
                projectID: projectID,
                serviceName: "api",
                plannedActionType: "createMissingService",
                status: .active,
                groupIdempotencyKey: "plan-hash:create:api",
                planHash: "plan-hash",
                checkpoint: "prepared",
                lockOwner: "hostwright-cli token=\(fakeSecret)",
                lockExpiresAt: "2026-07-01T00:10:00Z",
                rollbackAvailable: false,
                manualRecoveryHintRedacted: "inspect token=\(fakeSecret)",
                createdAt: timestamp,
                updatedAt: timestamp,
                metadataJSONRedacted: #"{"message":"token=\#(fakeSecret)","token":"\#(fakeSecret)"}"#,
                intentJSONRedacted: #"{"message":"password=\#(fakeSecret)"}"#,
                compensationJSONRedacted: #"[{"message":"auth=\#(fakeSecret)"}]"#,
                verificationJSONRedacted: #"{"credential":"\#(fakeSecret)"}"#
            )

            let first = try store.operationGroups.acquire(group, currentTimestamp: "2026-07-01T00:00:00Z")
            let acquired = try XCTUnwrap(first.acquired)
            XCTAssertTrue(StateJSON.isObject(acquired.metadataJSONRedacted))
            XCTAssertTrue(StateJSON.isObject(acquired.intentJSONRedacted))
            XCTAssertTrue(StateJSON.isArray(acquired.compensationJSONRedacted))
            XCTAssertTrue(StateJSON.isObject(acquired.verificationJSONRedacted))
            XCTAssertFalse(acquired.metadataJSONRedacted.contains(fakeSecret))
            XCTAssertTrue(acquired.metadataJSONRedacted.contains(#""message":"token=[REDACTED]""#))
            let second = try store.operationGroups.acquire(group, currentTimestamp: "2026-07-01T00:00:00Z")
            XCTAssertNil(second.acquired)
            XCTAssertEqual(second.existingActive?.id, "group-1")

            try store.operationGroups.finish(
                groupID: "group-1",
                status: .failed,
                checkpoint: "runtime-failed",
                manualRecoveryHintRedacted: "manual password=\(fakeSecret)",
                updatedAt: "2026-07-01T00:00:01Z",
                metadataJSONRedacted: #"{"password":"\#(fakeSecret)"}"#
            )

            let loaded = try XCTUnwrap(store.operationGroups.latest(groupIdempotencyKey: "plan-hash:create:api"))
            XCTAssertEqual(loaded.status, .failed)
            XCTAssertNil(loaded.lockOwner)
            XCTAssertNil(loaded.lockExpiresAt)
            XCTAssertFalse(loaded.manualRecoveryHintRedacted.contains(fakeSecret))
            XCTAssertFalse(loaded.metadataJSONRedacted.contains(fakeSecret))
            XCTAssertTrue(StateJSON.isObject(loaded.metadataJSONRedacted))

            XCTAssertThrowsError(
                try store.operationGroups.finish(
                    groupID: "group-1",
                    status: .succeeded,
                    checkpoint: "verified",
                    manualRecoveryHintRedacted: "none",
                    updatedAt: "2026-07-01T00:00:02Z",
                    metadataJSONRedacted: "{}"
                )
            ) { error in
                guard case StateStoreError.invalidRecord(let message) = error else {
                    return XCTFail("Expected terminal-transition rejection, got \(error)")
                }
                XCTAssertTrue(message.contains("already terminal"))
            }
        }
    }

    func testOperationGroupsRejectInvalidSagaPayloadsAndFinishInputs() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            let invalid = OperationGroupRecord(
                id: "group-invalid",
                operationID: "operation-invalid",
                groupKind: "apply",
                projectID: projectID,
                serviceName: "api",
                plannedActionType: "createMissingService",
                status: .active,
                groupIdempotencyKey: "plan-hash:create:api:invalid",
                planHash: "plan-hash",
                checkpoint: "prepared",
                lockOwner: "hostwright-cli",
                lockExpiresAt: "2026-07-01T00:10:00Z",
                rollbackAvailable: false,
                manualRecoveryHintRedacted: "inspect api",
                createdAt: timestamp,
                updatedAt: timestamp,
                metadataJSONRedacted: #"{"message":"unterminated}"#
            )

            XCTAssertThrowsError(try store.operationGroups.acquire(invalid)) { error in
                guard case StateStoreError.invalidRecord = error else {
                    return XCTFail("Expected invalid-record rejection, got \(error)")
                }
            }
            XCTAssertThrowsError(
                try store.operationGroups.finish(
                    groupID: "missing-group",
                    status: .active,
                    checkpoint: "prepared",
                    manualRecoveryHintRedacted: "none",
                    updatedAt: timestamp,
                    metadataJSONRedacted: "{}"
                )
            )
            XCTAssertThrowsError(
                try store.operationGroups.finish(
                    groupID: "missing-group",
                    status: .failed,
                    checkpoint: "failed",
                    manualRecoveryHintRedacted: "none",
                    updatedAt: timestamp,
                    metadataJSONRedacted: "not-json"
                )
            )
        }
    }

    func testOperationGroupsExpireStaleActiveLeaseBeforeAcquire() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            let stale = OperationGroupRecord(
                id: "group-stale",
                operationID: "operation-stale",
                groupKind: "apply",
                projectID: projectID,
                serviceName: "api",
                plannedActionType: "createMissingService",
                status: .active,
                groupIdempotencyKey: "plan-hash:create:api:stale",
                planHash: "plan-hash",
                checkpoint: "runtime-started",
                lockOwner: "hostwright-cli",
                lockExpiresAt: "2026-07-01T00:00:10Z",
                rollbackAvailable: false,
                manualRecoveryHintRedacted: "inspect api",
                createdAt: "2026-07-01T00:00:00Z",
                updatedAt: "2026-07-01T00:00:00Z",
                metadataJSONRedacted: "{}"
            )
            let fresh = OperationGroupRecord(
                id: "group-fresh",
                operationID: "operation-fresh",
                groupKind: "apply",
                projectID: projectID,
                serviceName: "api",
                plannedActionType: "createMissingService",
                status: .active,
                groupIdempotencyKey: stale.groupIdempotencyKey,
                planHash: "plan-hash",
                checkpoint: "prepared",
                lockOwner: "hostwright-cli",
                lockExpiresAt: "2026-07-01T00:10:00Z",
                rollbackAvailable: false,
                manualRecoveryHintRedacted: "inspect api",
                createdAt: "2026-07-01T00:00:11Z",
                updatedAt: "2026-07-01T00:00:11Z",
                metadataJSONRedacted: "{}"
            )

            XCTAssertNotNil(try store.operationGroups.acquire(stale, currentTimestamp: "2026-07-01T00:00:00Z").acquired)
            let reacquired = try store.operationGroups.acquire(fresh, currentTimestamp: "2026-07-01T00:00:11Z")

            XCTAssertNotNil(reacquired.acquired)
            XCTAssertNil(reacquired.existingActive)
            let groups = try store.operationGroups.loadAll()
            XCTAssertEqual(groups.map(\.id), ["group-stale", "group-fresh"])
            XCTAssertEqual(groups.map(\.status), [.interrupted, .active])
            XCTAssertEqual(groups[0].checkpoint, "lock-expired")
            XCTAssertNil(groups[0].lockOwner)
            XCTAssertNil(groups[0].lockExpiresAt)
        }
    }

    func testOperationGroupStepsAppendAndRedactFailureState() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            _ = try store.operationGroups.acquire(
                OperationGroupRecord(
                    id: "group-steps",
                    operationID: "operation-steps",
                    groupKind: "apply",
                    projectID: projectID,
                    serviceName: "api",
                    plannedActionType: "restartManagedService",
                    status: .active,
                    groupIdempotencyKey: "plan-hash:restart:api",
                    planHash: "plan-hash",
                    checkpoint: "runtime-started",
                    lockOwner: "hostwright-cli",
                    lockExpiresAt: "2026-07-01T00:10:00Z",
                    rollbackAvailable: false,
                    manualRecoveryHintRedacted: "inspect api",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    metadataJSONRedacted: "{}"
                )
            )
            try store.operationGroupSteps.append(
                OperationGroupStepRecord(
                    id: "step-1",
                    groupID: "group-steps",
                    stepKey: "runtime-execute",
                    direction: .forward,
                    plannedActionType: "restartManagedService",
                    serviceName: "api",
                    resourceIdentifier: "hostwright-api token=\(fakeSecret)",
                    stepIdempotencyKey: "plan-hash:restart:api:forward:runtime-execute",
                    status: .started,
                    startedAt: timestamp,
                    updatedAt: timestamp,
                    finishedAt: nil,
                    lastErrorRedacted: nil,
                    manualRecoveryHintRedacted: "started token=\(fakeSecret)",
                    metadataJSONRedacted: "{}"
                )
            )
            try store.operationGroupSteps.append(
                OperationGroupStepRecord(
                    id: "step-2",
                    groupID: "group-steps",
                    stepKey: "runtime-execute",
                    direction: .forward,
                    plannedActionType: "restartManagedService",
                    serviceName: "api",
                    resourceIdentifier: "hostwright-api",
                    stepIdempotencyKey: "plan-hash:restart:api:forward:runtime-execute",
                    status: .failed,
                    startedAt: timestamp,
                    updatedAt: "2026-07-01T00:00:01Z",
                    finishedAt: "2026-07-01T00:00:01Z",
                    lastErrorRedacted: "password=\(fakeSecret)",
                    manualRecoveryHintRedacted: "inspect password=\(fakeSecret)",
                    metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                )
            )

            let steps = try store.operationGroupSteps.load(groupID: "group-steps")
            XCTAssertEqual(steps.map(\.status), [.started, .failed])
            XCTAssertEqual(try store.operationGroupSteps.latest(groupID: "group-steps", stepKey: "runtime-execute")?.status, .failed)
            XCTAssertFalse(steps.map { $0.resourceIdentifier ?? "" }.joined().contains(fakeSecret))
            XCTAssertFalse(steps.map { $0.lastErrorRedacted ?? "" }.joined().contains(fakeSecret))
            XCTAssertFalse(steps.map(\.manualRecoveryHintRedacted).joined().contains(fakeSecret))
            XCTAssertFalse(steps.map(\.metadataJSONRedacted).joined().contains(fakeSecret))
        }
    }
}
