import Foundation
import Synchronization
import XCTest
@testable import HostwrightState

extension HostwrightStateTests {
    func testHealthCheckResultsAppendInOrderAndRedactOutputs() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try store.healthResults.append([
                HealthCheckResultRecord(
                    id: "health-1",
                    projectID: projectID,
                    serviceName: "api",
                    checkedAt: "2026-07-01T00:00:01Z",
                    status: .healthy,
                    exitStatus: 0,
                    timedOut: false,
                    commandJSONRedacted: #"["curl","http://localhost?token=\#(fakeSecret)"]"#,
                    stdoutRedacted: "ok token=\(fakeSecret)",
                    stderrRedacted: "",
                    metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                ),
                HealthCheckResultRecord(
                    id: "health-2",
                    projectID: projectID,
                    serviceName: "api",
                    checkedAt: "2026-07-01T00:00:02Z",
                    status: .unhealthy,
                    exitStatus: 7,
                    timedOut: false,
                    commandJSONRedacted: #"["curl","http://localhost"]"#,
                    stdoutRedacted: "",
                    stderrRedacted: "password=\(fakeSecret)",
                    metadataJSONRedacted: "{}"
                )
            ])

            let results = try store.healthResults.loadProject(projectID: projectID)
            XCTAssertEqual(results.map(\.id), ["health-1", "health-2"])
            XCTAssertEqual(results.map(\.status), [.healthy, .unhealthy])
            XCTAssertEqual(try store.healthResults.latest(projectID: projectID, serviceName: "api")?.id, "health-2")
            XCTAssertFalse(results.map(\.commandJSONRedacted).joined().contains(fakeSecret))
            XCTAssertFalse(results.map(\.stdoutRedacted).joined().contains(fakeSecret))
            XCTAssertFalse(results.map(\.stderrRedacted).joined().contains(fakeSecret))
            XCTAssertFalse(results.map(\.metadataJSONRedacted).joined().contains(fakeSecret))
            XCTAssertTrue(
                results.allSatisfy {
                    StateJSON.isArray($0.commandJSONRedacted) &&
                        StateJSON.isObject($0.metadataJSONRedacted)
                }
            )
        }
    }

    func testRestartPolicyStateUpsertsAndRedactsMetadata() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try store.restartPolicies.upsert(
                RestartPolicyStateRecord(
                    id: "restart-1",
                    projectID: projectID,
                    serviceName: "api",
                    policy: .onFailure,
                    status: .backingOff,
                    attemptCount: 1,
                    maxAttempts: 3,
                    backoffSeconds: 60,
                    backoffUntil: "2026-07-01T00:01:00Z",
                    lastFailureAt: "2026-07-01T00:00:00Z",
                    updatedAt: timestamp,
                    metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                )
            )
            try store.restartPolicies.upsert(
                RestartPolicyStateRecord(
                    id: "restart-2",
                    projectID: projectID,
                    serviceName: "api",
                    policy: .onFailure,
                    status: .crashLoopBlocked,
                    attemptCount: 3,
                    maxAttempts: 3,
                    backoffSeconds: 60,
                    backoffUntil: nil,
                    lastFailureAt: "2026-07-01T00:00:30Z",
                    updatedAt: "2026-07-01T00:00:30Z",
                    metadataJSONRedacted: #"{"password":"\#(fakeSecret)"}"#
                )
            )

            let state = try XCTUnwrap(store.restartPolicies.load(projectID: projectID, serviceName: "api"))
            XCTAssertEqual(state.id, "restart-2")
            XCTAssertEqual(state.status, .crashLoopBlocked)
            XCTAssertEqual(state.attemptCount, 3)
            XCTAssertFalse(state.metadataJSONRedacted.contains(fakeSecret))
            XCTAssertTrue(StateJSON.isObject(state.metadataJSONRedacted))
            XCTAssertEqual(try store.restartPolicies.loadProject(projectID: projectID).count, 1)
        }
    }

    func testPhase08RestartHoldReleaseRequiresExactTokenAndRecordsHistoryAtomically() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            let holdToken = String(repeating: "a", count: 64)
            let policySHA = String(repeating: "b", count: 64)
            try store.restartPolicies.upsert(
                RestartPolicyStateRecord(
                    id: "restart-held",
                    projectID: projectID,
                    serviceName: "api",
                    policy: .onFailure,
                    status: .crashLoopBlocked,
                    attemptCount: 3,
                    maxAttempts: 3,
                    holdToken: holdToken,
                    policySHA256: policySHA,
                    updatedAt: timestamp,
                    metadataJSONRedacted: "{}"
                )
            )

            XCTAssertNil(
                try store.restartPolicies.releaseHold(
                    projectID: projectID,
                    serviceName: "api",
                    expectedHoldToken: String(repeating: "c", count: 64),
                    timestamp: "2026-07-01T00:01:00Z",
                    historyID: "11111111-1111-4111-8111-111111111111"
                )
            )
            XCTAssertEqual(try store.restartAttempts.loadProject(projectID), [])

            let released = try XCTUnwrap(
                store.restartPolicies.releaseHold(
                    projectID: projectID,
                    serviceName: "api",
                    expectedHoldToken: holdToken,
                    timestamp: "2026-07-01T00:01:00Z",
                    historyID: "22222222-2222-4222-8222-222222222222",
                    eventID: "44444444-4444-4444-8444-444444444444"
                )
            )
            XCTAssertEqual(released.status, .active)
            XCTAssertEqual(released.attemptCount, 0)
            XCTAssertNil(released.holdToken)
            XCTAssertEqual(released.releaseGeneration, 1)
            let history = try store.restartAttempts.loadProject(projectID)
            XCTAssertEqual(history.count, 1)
            XCTAssertEqual(history[0].decision, .manualRelease)
            XCTAssertFalse(history[0].admitted)
            XCTAssertEqual(history[0].holdToken, holdToken)
            XCTAssertTrue(
                try store.events.contains(
                    type: "restart.policy.manual-release",
                    source: "hostwright-cli",
                    payloadContains: "\"releaseGeneration\":1"
                )
            )
            XCTAssertNil(
                try store.restartPolicies.releaseHold(
                    projectID: projectID,
                    serviceName: "api",
                    expectedHoldToken: holdToken,
                    timestamp: "2026-07-01T00:02:00Z",
                    historyID: "33333333-3333-4333-8333-333333333333"
                )
            )
            XCTAssertEqual(try store.restartAttempts.loadProject(projectID).count, 1)
        }
    }

    func testPhase08ConcurrentRestartHoldReleaseHasExactlyOneWinner() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            let holdToken = String(repeating: "d", count: 64)
            try store.restartPolicies.upsert(
                RestartPolicyStateRecord(
                    id: "restart-held-concurrent",
                    projectID: projectID,
                    serviceName: "api",
                    policy: .onFailure,
                    status: .crashLoopBlocked,
                    attemptCount: 3,
                    maxAttempts: 3,
                    holdToken: holdToken,
                    policySHA256: String(repeating: "e", count: 64),
                    updatedAt: timestamp,
                    metadataJSONRedacted: "{}"
                )
            )
            let targetProjectID = projectID
            let outcome = Mutex((winners: 0, failures: [String]()))
            DispatchQueue.concurrentPerform(iterations: 16) { index in
                do {
                    let suffix = String(format: "%012x", index + 1)
                    let released = try StateUpgradeService(store: store)
                        .withBoundedStateAccessWait(lockWaitMilliseconds: 5_000) {
                            try store.restartPolicies.releaseHold(
                                projectID: targetProjectID,
                                serviceName: "api",
                                expectedHoldToken: holdToken,
                                timestamp: "2026-08-01T12:01:00Z",
                                historyID: "11111111-1111-4111-8111-\(suffix)",
                                eventID: "22222222-2222-4222-8222-\(suffix)"
                            )
                        }
                    if released != nil { outcome.withLock { $0.winners += 1 } }
                } catch {
                    outcome.withLock { $0.failures.append(String(describing: error)) }
                }
            }
            let result = outcome.withLock { $0 }
            XCTAssertEqual(result.winners, 1)
            XCTAssertEqual(result.failures, [])
            XCTAssertEqual(try store.restartAttempts.loadProject(projectID).count, 1)
            XCTAssertEqual(
                try store.events.loadAll().filter { $0.type == "restart.policy.manual-release" }.count,
                1
            )
        }
    }

    func testPhase08StaleRestartTransitionCannotResurrectReleasedHold() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            let holdToken = String(repeating: "f", count: 64)
            let policySHA = String(repeating: "a", count: 64)
            let staleState = RestartPolicyStateRecord(
                id: "restart-stale-transition",
                projectID: projectID,
                serviceName: "api",
                policy: .onFailure,
                status: .crashLoopBlocked,
                attemptCount: 3,
                maxAttempts: 3,
                holdToken: holdToken,
                policySHA256: policySHA,
                updatedAt: timestamp,
                metadataJSONRedacted: "{}"
            )
            try store.restartPolicies.upsert(staleState)
            _ = try XCTUnwrap(
                store.restartPolicies.releaseHold(
                    projectID: projectID,
                    serviceName: "api",
                    expectedHoldToken: holdToken,
                    timestamp: "2026-08-01T12:01:00Z",
                    historyID: "55555555-5555-4555-8555-555555555555"
                )
            )
            let staleHistory = RestartAttemptHistoryRecord(
                id: "66666666-6666-4666-8666-666666666666",
                projectID: projectID,
                serviceName: "api",
                reasonClass: .processExit,
                decision: .hold,
                attemptNumber: 3,
                projectAttemptNumber: 0,
                admitted: false,
                holdToken: holdToken,
                occurredAt: "2026-08-01T12:01:01Z",
                policySHA256: policySHA,
                metadataJSONRedacted: "{}"
            )

            XCTAssertThrowsError(
                try store.restartPolicies.recordTransition(
                    state: staleState,
                    history: staleHistory
                )
            ) { error in
                XCTAssertEqual(
                    error as? StateStoreError,
                    .invalidRecord(
                        "Restart state update was fenced by a newer manual release generation."
                    )
                )
            }
            let current = try XCTUnwrap(
                store.restartPolicies.load(
                    projectID: projectID,
                    serviceName: "api"
                )
            )
            XCTAssertEqual(current.status, .active)
            XCTAssertNil(current.holdToken)
            XCTAssertEqual(current.releaseGeneration, 1)
            XCTAssertEqual(
                try store.restartAttempts.loadProject(projectID).map(\.decision),
                [.manualRelease]
            )
        }
    }

    func testRestartRecoveryRecordsAppendAndRedactHints() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try store.restartRecovery.append(
                RestartRecoveryRecord(
                    id: "recovery-1",
                    operationID: "operation-restart",
                    projectID: projectID,
                    serviceName: "api",
                    resourceIdentifier: "hostwright-demo-api",
                    planHash: "plan-hash",
                    status: .prepared,
                    completedStepsJSONRedacted: #"[]"#,
                    manualRecoveryHintRedacted: "prepared token=\(fakeSecret)",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                )
            )
            try store.restartRecovery.append(
                RestartRecoveryRecord(
                    id: "recovery-2",
                    operationID: "operation-restart",
                    projectID: projectID,
                    serviceName: "api",
                    resourceIdentifier: "hostwright-demo-api",
                    planHash: "plan-hash",
                    status: .stopSucceeded,
                    completedStepsJSONRedacted: #"["stop"]"#,
                    manualRecoveryHintRedacted: "container stopped; password=\(fakeSecret)",
                    createdAt: timestamp,
                    updatedAt: "2026-07-01T00:00:01Z",
                    metadataJSONRedacted: "{}"
                )
            )

            let records = try store.restartRecovery.load(operationID: "operation-restart")
            XCTAssertEqual(records.map(\.status), [.prepared, .stopSucceeded])
            XCTAssertEqual(try store.restartRecovery.latest(operationID: "operation-restart")?.status, .stopSucceeded)
            XCTAssertEqual(try store.restartRecovery.loadAll().count, 2)
            XCTAssertFalse(records.map(\.manualRecoveryHintRedacted).joined().contains(fakeSecret))
            XCTAssertFalse(records.map(\.metadataJSONRedacted).joined().contains(fakeSecret))
            XCTAssertTrue(
                records.allSatisfy {
                    StateJSON.isArray($0.completedStepsJSONRedacted) &&
                        StateJSON.isObject($0.metadataJSONRedacted)
                }
            )
        }
    }
}
