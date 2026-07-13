import Foundation
import HostwrightControl
import HostwrightCore
import HostwrightManifest
import HostwrightState
import XCTest

final class LocalControlAPIIntegrationTests: XCTestCase {
    func testRealFilesAndSQLiteServeAllFiveApprovedOperations() throws {
        try withWorkspace { workspace in
            let store = SQLiteStateStore(
                configuration: StateStoreConfiguration(explicitDatabasePath: workspace.database.path)
            )
            try store.migrate()
            try store.desiredStates.saveManifestSnapshot(
                projectID: "project-demo",
                manifestPath: workspace.manifest.path,
                manifestHash: "control-manifest-hash",
                desiredGeneration: 1,
                manifest: try ManifestParser.parse(validManifest),
                timestamp: "2026-07-12T20:00:00Z"
            )
            try store.events.append([
                EventRecord(
                    id: "event-control-1",
                    timestamp: "2026-07-12T20:00:00Z",
                    severity: .warning,
                    type: "apply.failed",
                    source: "control-integration",
                    projectID: "project-demo",
                    serviceName: "api",
                    runtimeAdapter: nil,
                    message: "token=control-secret-must-not-leak",
                    payloadJSONRedacted: #"{"token":"control-secret-must-not-leak"}"#
                )
            ])
            let acquiredGroup = try store.operationGroups.acquire(
                OperationGroupRecord(
                    id: "group-control-1",
                    operationID: "operation-control-1",
                    groupKind: "apply",
                    projectID: "project-demo",
                    serviceName: "api",
                    plannedActionType: "createMissingService",
                    status: .active,
                    groupIdempotencyKey: "control-integration-key",
                    planHash: "control-plan-hash",
                    checkpoint: "intent-recorded",
                    lockOwner: "hostwright-control-integration",
                    lockExpiresAt: "2026-07-12T20:10:00Z",
                    rollbackAvailable: false,
                    manualRecoveryHintRedacted: "token=control-secret-must-not-leak",
                    createdAt: "2026-07-12T20:00:00Z",
                    updatedAt: "2026-07-12T20:00:01Z",
                    metadataJSONRedacted: #"{"token":"control-secret-must-not-leak"}"#
                ),
                currentTimestamp: "2026-07-12T20:00:00Z"
            )
            XCTAssertEqual(acquiredGroup.acquired?.id, "group-control-1")
            try store.operationGroups.finish(
                groupID: "group-control-1",
                status: .failed,
                checkpoint: "runtime-failed",
                manualRecoveryHintRedacted: "token=control-secret-must-not-leak",
                updatedAt: "2026-07-12T20:00:01Z",
                metadataJSONRedacted: #"{"token":"control-secret-must-not-leak"}"#
            )

            let api = LocalControlAPI(
                configuration: LocalControlConfiguration(
                    manifestPath: workspace.manifest.path,
                    stateDatabasePath: workspace.database.path
                )
            )

            let plan = try run(api, LocalControlRequest(requestID: "plan-1", operation: .plan))
            XCTAssertTrue(plan.success)
            XCTAssertEqual(string("kind", in: plan.result), "plan")
            XCTAssertEqual(string("project", in: plan.result), "demo")

            let status = try run(
                LocalControlAPI(
                    configuration: LocalControlConfiguration(manifestPath: workspace.manifest.path)
                ),
                LocalControlRequest(requestID: "status-1", operation: .status)
            )
            XCTAssertTrue(status.success)
            XCTAssertEqual(string("kind", in: status.result), "status")
            let runtime = try XCTUnwrap(object("runtime", in: status.result))
            XCTAssertEqual(bool("observed", in: .object(runtime)), false)

            let events = try run(
                api,
                LocalControlRequest(
                    requestID: "events-1",
                    operation: .events,
                    project: "demo",
                    eventType: "apply.failed",
                    service: "api",
                    severity: "warning",
                    limit: 10,
                    sort: "desc"
                )
            )
            XCTAssertTrue(events.success)
            XCTAssertEqual(string("kind", in: events.result), "events")
            XCTAssertEqual(array("events", in: events.result)?.count, 1)

            let recovery = try run(
                api,
                LocalControlRequest(requestID: "recovery-1", operation: .recovery, project: "demo")
            )
            XCTAssertTrue(recovery.success)
            XCTAssertEqual(string("kind", in: recovery.result), "recovery")
            XCTAssertEqual(array("operationGroups", in: recovery.result)?.count, 1)

            let doctor = try run(api, LocalControlRequest(requestID: "doctor-1", operation: .doctor))
            XCTAssertTrue(doctor.success)
            XCTAssertEqual(string("kind", in: doctor.result), "doctor")

            let allOutput = [plan, status, events, recovery, doctor]
                .compactMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
                .joined(separator: "\n")
            XCTAssertFalse(allOutput.contains("control-secret-must-not-leak"))
            XCTAssertTrue(allOutput.contains("[REDACTED]"))

            XCTAssertEqual(try store.events.loadAll().count, 1)
            XCTAssertEqual(try store.operationGroups.loadAll().count, 1)
        }
    }

    func testRealTeamProfileIsAppliedToPlanWithoutRequestPath() throws {
        try withWorkspace { workspace in
            let teamProfile = workspace.root.appendingPathComponent("team-profile.json")
            try Data(validTeamProfile.utf8).write(to: teamProfile, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: teamProfile.path)

            let response = try run(
                LocalControlAPI(
                    configuration: LocalControlConfiguration(
                        manifestPath: workspace.manifest.path,
                        teamProfilePath: teamProfile.path
                    )
                ),
                LocalControlRequest(requestID: "plan-team-1", operation: .plan)
            )

            XCTAssertTrue(response.success)
            XCTAssertNotNil(object("teamPolicy", in: response.result))
        }
    }

    func testUnderlyingManifestFailurePreservesStableCLIError() throws {
        try withWorkspace(manifestText: "project: broken\nservices:\n  api:\n    unsupported: true\n") { workspace in
            let response = try run(
                LocalControlAPI(
                    configuration: LocalControlConfiguration(manifestPath: workspace.manifest.path)
                ),
                LocalControlRequest(requestID: "plan-failed-1", operation: .plan),
                expectedExitCode: 65
            )

            XCTAssertFalse(response.success)
            XCTAssertEqual(string("kind", in: response.error), "error")
            XCTAssertEqual(string("code", in: response.error), HostwrightErrorCode.manifestUnsupportedFeature.rawValue)
        }
    }

    func testUnsafeOrMissingConfiguredFilesFailClosedBeforeDelegation() throws {
        try withWorkspace { workspace in
            let request = LocalControlRequest(requestID: "plan-unsafe-1", operation: .plan)
            let manifestLink = workspace.root.appendingPathComponent("manifest-link.yaml")
            try FileManager.default.createSymbolicLink(at: manifestLink, withDestinationURL: workspace.manifest)

            let linked = try run(
                LocalControlAPI(
                    configuration: LocalControlConfiguration(manifestPath: manifestLink.path)
                ),
                request,
                expectedExitCode: LocalControlExitCode.unavailable.rawValue
            )
            XCTAssertEqual(string("code", in: linked.error), HostwrightErrorCode.controlAPIUnavailable.rawValue)

            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: workspace.manifest.path)
            let unsafe = try run(
                LocalControlAPI(
                    configuration: LocalControlConfiguration(manifestPath: workspace.manifest.path)
                ),
                request,
                expectedExitCode: LocalControlExitCode.unavailable.rawValue
            )
            XCTAssertEqual(string("code", in: unsafe.error), HostwrightErrorCode.controlAPIUnavailable.rawValue)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspace.manifest.path)

            let missingState = try run(
                LocalControlAPI(
                    configuration: LocalControlConfiguration(manifestPath: workspace.manifest.path)
                ),
                LocalControlRequest(requestID: "events-no-state", operation: .events),
                expectedExitCode: LocalControlExitCode.unavailable.rawValue
            )
            XCTAssertEqual(string("code", in: missingState.error), HostwrightErrorCode.controlAPIUnavailable.rawValue)

            let missingDatabaseURL = workspace.root.appendingPathComponent("missing-state.sqlite")
            let missingConfiguredState = try run(
                LocalControlAPI(
                    configuration: LocalControlConfiguration(
                        manifestPath: workspace.manifest.path,
                        stateDatabasePath: missingDatabaseURL.path
                    )
                ),
                LocalControlRequest(requestID: "events-missing-state", operation: .events),
                expectedExitCode: LocalControlExitCode.unavailable.rawValue
            )
            XCTAssertEqual(string("code", in: missingConfiguredState.error), HostwrightErrorCode.controlAPIUnavailable.rawValue)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missingDatabaseURL.path))
        }
    }

    private func run(
        _ api: LocalControlAPI,
        _ request: LocalControlRequest,
        expectedExitCode: Int32 = 0
    ) throws -> LocalControlResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let result = api.run(requestData: try encoder.encode(request))
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(result.exitCode, expectedExitCode)
        return try JSONDecoder().decode(LocalControlResponse.self, from: result.standardOutput)
    }

    private func object(_ key: String, in value: ControlJSONValue?) -> [String: ControlJSONValue]? {
        guard case .object(let object) = value, case .object(let nested)? = object[key] else { return nil }
        return nested
    }

    private func array(_ key: String, in value: ControlJSONValue?) -> [ControlJSONValue]? {
        guard case .object(let object) = value, case .array(let nested)? = object[key] else { return nil }
        return nested
    }

    private func string(_ key: String, in value: ControlJSONValue?) -> String? {
        guard case .object(let object) = value, case .string(let nested)? = object[key] else { return nil }
        return nested
    }

    private func bool(_ key: String, in value: ControlJSONValue?) -> Bool? {
        guard case .object(let object) = value, case .bool(let nested)? = object[key] else { return nil }
        return nested
    }

    private func withWorkspace(
        manifestText: String? = nil,
        _ body: (Workspace) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-control-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = root.appendingPathComponent("hostwright.yaml")
        try Data((manifestText ?? validManifest).utf8).write(to: manifest, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        try body(
            Workspace(
                root: root,
                manifest: manifest,
                database: root.appendingPathComponent("state.sqlite")
            )
        )
    }

    private var validManifest: String {
        """
        version: 2
        project: demo
        services:
          api:
            image: local/demo:latest
            command: ["serve"]

        """
    }

    private var validTeamProfile: String {
        """
        {
          "kind": "HostwrightTeamProfile",
          "apiVersion": 1,
          "identifier": "dev.hostwright.control.integration",
          "displayName": "Control Integration",
          "optIn": true,
          "requiredGates": ["runtimeAdapter", "explicitStatePath", "localPolicy", "redaction", "auditTrail", "planConfirmation", "cleanupConfirmation", "ownershipChecks", "localOnlyNoCloud", "noTelemetryUpload"],
          "requirements": ["requireManifestReview"]
        }
        """
    }
}

private struct Workspace {
    let root: URL
    let manifest: URL
    let database: URL
}
