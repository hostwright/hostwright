import Foundation
import Synchronization
import XCTest
@testable import HostwrightState

extension HostwrightStateTests {
    func testEventLedgerAppendsInOrderAndRedactsPayloads() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try store.events.append([
                EventRecord(
                    id: "event-1",
                    timestamp: "2026-07-01T00:00:01Z",
                    severity: .info,
                    type: "state.desired.saved",
                    source: "state-test",
                    projectID: projectID,
                    serviceName: "api",
                    runtimeAdapter: nil,
                    message: "saved token=\(fakeSecret)",
                    payloadJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                ),
                EventRecord(
                    id: "event-2",
                    timestamp: "2026-07-01T00:00:01Z",
                    severity: .warning,
                    type: "state.observed.saved",
                    source: "state-test",
                    projectID: projectID,
                    serviceName: "api",
                    runtimeAdapter: "apple-container-cli",
                    message: "snapshot persisted",
                    payloadJSONRedacted: "{}"
                )
            ])

            let events = try store.events.loadAll()
            XCTAssertEqual(events.map(\.id), ["event-1", "event-2"])
            XCTAssertEqual(events.map(\.timestamp), ["2026-07-01T00:00:01Z", "2026-07-01T00:00:01Z"])
            XCTAssertTrue(events[0].message.contains("[REDACTED]"))
            XCTAssertFalse(events[0].payloadJSONRedacted.contains(fakeSecret))
            XCTAssertTrue(
                events.allSatisfy {
                    StateJSON.isObject($0.payloadJSONRedacted)
                }
            )
        }
    }

    func testTeamWorkflowAuditEventsPersistAndRedactPayloads() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try store.events.append([
                EventRecord(
                    id: "team-approval-1",
                    timestamp: "2026-07-09T00:00:00Z",
                    severity: .info,
                    type: "team.approval.recorded",
                    source: "team-workflow",
                    projectID: projectID,
                    serviceName: nil,
                    runtimeAdapter: nil,
                    message: "team approval recorded token=\(fakeSecret)",
                    payloadJSONRedacted: #"{"profile":"dev.hostwright.team.local","approvalID":"approval-1","token":"\#(fakeSecret)"}"#
                ),
                EventRecord(
                    id: "team-profile-1",
                    timestamp: "2026-07-09T00:00:01Z",
                    severity: .warning,
                    type: "team.profile.selected",
                    source: "team-workflow",
                    projectID: projectID,
                    serviceName: nil,
                    runtimeAdapter: nil,
                    message: "team profile selected",
                    payloadJSONRedacted: #"{"profile":"dev.hostwright.team.local","requirement":"requireImageDigest"}"#
                )
            ])

            let events = try store.events.loadAll()
            let teamEvents = events.filter { $0.type.hasPrefix("team.") }

            XCTAssertEqual(teamEvents.map(\.id), ["team-approval-1", "team-profile-1"])
            XCTAssertEqual(teamEvents.map(\.source), ["team-workflow", "team-workflow"])
            XCTAssertEqual(teamEvents.map(\.projectID), [projectID, projectID])
            XCTAssertTrue(teamEvents[0].message.contains("[REDACTED]"))
            XCTAssertFalse(teamEvents.map(\.payloadJSONRedacted).joined().contains(fakeSecret))
        }
    }

    func testDiagnosticsExportCollectsRedactedStateWithoutCreatingRuntimeArtifacts() throws {
        try withTemporaryStore { store, _ in
            try saveDesiredState(in: store)
            try saveObservedSnapshot(in: store)
            try store.events.append([
                EventRecord(
                    id: "event-diagnostics",
                    timestamp: "2026-07-01T00:00:01Z",
                    severity: .error,
                    type: "apply.failed",
                    source: "state-test",
                    projectID: projectID,
                    serviceName: "api",
                    runtimeAdapter: "apple-container-cli",
                    message: "token=\(fakeSecret)",
                    payloadJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                )
            ])
            try store.operations.record(
                OperationRecord(
                    id: "operation-diagnostics",
                    createdAt: timestamp,
                    updatedAt: "2026-07-01T00:00:01Z",
                    plannedActionType: "createMissingService",
                    projectID: projectID,
                    serviceName: "api",
                    status: .failed,
                    idempotencyKey: "plan:create:api:diagnostics",
                    planHash: "plan",
                    payloadJSONRedacted: #"{"password":"\#(fakeSecret)"}"#
                )
            )
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "ownership-diagnostics",
                    resourceIdentifier: "hostwright-api token=\(fakeSecret)",
                    resourceType: "container",
                    projectID: projectID,
                    serviceName: "api",
                    runtimeAdapter: "apple-container-cli",
                    createdAt: timestamp,
                    observedAt: timestamp,
                    cleanupEligible: true,
                    metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                )
            )
            _ = try store.operationGroups.acquire(
                OperationGroupRecord(
                    id: "group-diagnostics",
                    operationID: "operation-diagnostics",
                    groupKind: "apply",
                    projectID: projectID,
                    serviceName: "api",
                    plannedActionType: "restartManagedService",
                    status: .active,
                    groupIdempotencyKey: "plan:restart:api",
                    planHash: "plan",
                    checkpoint: "runtime-started",
                    lockOwner: "hostwright-cli token=\(fakeSecret)",
                    lockExpiresAt: "2026-07-01T00:10:00Z",
                    rollbackAvailable: false,
                    manualRecoveryHintRedacted: "inspect token=\(fakeSecret)",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                )
            )
            try store.operationGroupSteps.append(
                OperationGroupStepRecord(
                    id: "step-diagnostics",
                    groupID: "group-diagnostics",
                    stepKey: "runtime-execute",
                    direction: .forward,
                    plannedActionType: "restartManagedService",
                    serviceName: "api",
                    resourceIdentifier: "hostwright-api token=\(fakeSecret)",
                    stepIdempotencyKey: "plan:restart:api:forward:runtime-execute",
                    status: .failed,
                    startedAt: timestamp,
                    updatedAt: "2026-07-01T00:00:01Z",
                    finishedAt: "2026-07-01T00:00:01Z",
                    lastErrorRedacted: "password=\(fakeSecret)",
                    manualRecoveryHintRedacted: "inspect password=\(fakeSecret)",
                    metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                )
            )
            try store.healthResults.append([
                HealthCheckResultRecord(
                    id: "health-diagnostics",
                    projectID: projectID,
                    serviceName: "api",
                    checkedAt: "2026-07-01T00:00:01Z",
                    status: .unhealthy,
                    exitStatus: 7,
                    timedOut: false,
                    commandJSONRedacted: #"["curl","http://localhost?token=\#(fakeSecret)"]"#,
                    stdoutRedacted: "token=\(fakeSecret)",
                    stderrRedacted: "password=\(fakeSecret)",
                    metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                )
            ])
            try store.restartPolicies.upsert(
                RestartPolicyStateRecord(
                    id: "restart-policy-diagnostics",
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
            try store.restartRecovery.append(
                RestartRecoveryRecord(
                    id: "restart-recovery-diagnostics",
                    operationID: "operation-diagnostics",
                    projectID: projectID,
                    serviceName: "api",
                    resourceIdentifier: "hostwright-api token=\(fakeSecret)",
                    planHash: "plan",
                    status: .stopSucceeded,
                    completedStepsJSONRedacted: #"["stop token=\#(fakeSecret)"]"#,
                    manualRecoveryHintRedacted: "manual token=\(fakeSecret)",
                    createdAt: timestamp,
                    updatedAt: "2026-07-01T00:00:01Z",
                    metadataJSONRedacted: #"{"token":"\#(fakeSecret)"}"#
                )
            )

            let export = try store.diagnostics.loadExport(
                query: DiagnosticsExportQuery(
                    projectID: projectID,
                    manifest: DiagnosticsManifestSummary(
                        path: "/tmp/hostwright.yaml",
                        projectName: "api-local",
                        serviceNames: ["api"],
                        manifestHash: "manifest-hash-1"
                    ),
                    generatedAt: timestamp
                )
            )
            let json = try export.jsonString()

            XCTAssertEqual(export.telemetryPolicy, "local-only; no upload")
            XCTAssertEqual(export.events.count, 1)
            XCTAssertEqual(export.operations.count, 1)
            XCTAssertEqual(export.operationGroups.count, 1)
            XCTAssertEqual(export.operationGroupSteps.count, 1)
            XCTAssertEqual(export.healthResults.count, 1)
            XCTAssertEqual(export.restartPolicyStates.count, 1)
            XCTAssertEqual(export.restartRecoveryRecords.count, 1)
            XCTAssertEqual(export.ownershipRecords.count, 1)
            XCTAssertEqual(export.observedSnapshots.count, 1)
            XCTAssertFalse(json.contains(fakeSecret))
            XCTAssertTrue(json.contains("\"kind\" : \"diagnostics\""))
            XCTAssertTrue(json.contains("\"telemetryPolicy\" : \"local-only; no upload\""))
        }
    }
}
