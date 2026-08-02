import Foundation
import HostwrightCore
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class OwnershipCommandTests: XCTestCase {
    func testParserRequiresExactBoundedHandoffContract() throws {
        let groupID = HostwrightResourceUUID.generate()
        let fence = HostwrightResourceUUID.generate()
        let plan = String(repeating: "a", count: 64)
        let command = try CLICommand.parse(arguments: [
            "ownership", "handoff",
            "--group", groupID,
            "--confirm-plan", plan,
            "--confirm-fence", fence,
            "--from-controller", "hostwright-cli:operation",
            "--from-expiry", "2026-08-01T00:00:00Z",
            "--to-controller", "resume",
            "--lease-seconds", "60",
            "--json"
        ])
        guard case .ownership(let options) = command,
              case let .handoff(
                  parsedGroup,
                  parsedPlan,
                  parsedFence,
                  priorController,
                  priorExpiry,
                  targetController,
                  leaseSeconds
              ) = options.action else {
            return XCTFail("Expected an ownership handoff command.")
        }
        XCTAssertEqual(parsedGroup, groupID)
        XCTAssertEqual(parsedPlan, plan)
        XCTAssertEqual(parsedFence, fence)
        XCTAssertEqual(priorController, "hostwright-cli:operation")
        XCTAssertEqual(priorExpiry, "2026-08-01T00:00:00Z")
        XCTAssertEqual(targetController, "hostwright-recovery-resume")
        XCTAssertEqual(leaseSeconds, 60)
        XCTAssertEqual(options.output, .json)

        XCTAssertThrowsError(
            try CLICommand.parse(arguments: [
                "ownership", "handoff",
                "--group", groupID,
                "--confirm-plan", plan,
                "--confirm-fence", fence,
                "--from-controller", "hostwright-cli:operation",
                "--from-expiry", "2026-08-01T00:00:00Z",
                "--to-controller", "remote-controller",
                "--lease-seconds", "60"
            ])
        )
    }

    func testStatusAndExpiredHandoffAreVersionedAndExact() throws {
        try withTemporaryStore { store, databaseURL in
            let groupID = HostwrightResourceUUID.generate()
            let operationID = HostwrightResourceUUID.generate()
            let fence = HostwrightResourceUUID.generate()
            let resourceUUID = HostwrightResourceUUID.generate()
            let plan = String(repeating: "b", count: 64)
            let originalOwner = "hostwright-cli:\(operationID)"
            let priorExpiry = "2026-07-31T00:00:00Z"
            let group = OperationGroupRecord(
                id: groupID,
                operationID: operationID,
                groupKind: "lifecycle-v1",
                projectID: nil,
                serviceName: "api",
                plannedActionType: "rm",
                status: .active,
                groupIdempotencyKey: plan,
                planHash: plan,
                checkpoint: "remove-api:effect-pending",
                lockOwner: originalOwner,
                lockExpiresAt: priorExpiry,
                rollbackAvailable: true,
                manualRecoveryHintRedacted: "",
                createdAt: "2026-07-31T00:00:00Z",
                updatedAt: "2026-07-31T00:00:00Z",
                metadataJSONRedacted: "{}",
                fencingToken: fence
            )
            XCTAssertNotNil(
                try store.operationGroups.acquire(
                    group,
                    currentTimestamp: "2026-07-31T00:00:00Z"
                ).acquired
            )
            let base = OwnershipRecord(
                id: "ownership-api",
                resourceIdentifier: "hostwright-demo-api",
                resourceType: "container",
                projectID: nil,
                serviceName: "api",
                runtimeAdapter: "AppleContainerApplyAdapter",
                createdAt: "2026-07-31T00:00:00Z",
                observedAt: "2026-07-31T00:00:00Z",
                cleanupEligible: true,
                metadataJSONRedacted: "{}",
                resourceUUID: resourceUUID,
                projectResourceUUID: nil,
                fencingToken: fence
            )
            let authority = try OwnershipAuthorityRecord.lifecycle(
                ownership: base,
                operationGroup: group,
                finalizerState: .active
            )
            try store.ownership.upsert(
                OwnershipRecord(
                    id: base.id,
                    resourceIdentifier: base.resourceIdentifier,
                    resourceType: base.resourceType,
                    projectID: base.projectID,
                    serviceName: base.serviceName,
                    runtimeAdapter: base.runtimeAdapter,
                    createdAt: base.createdAt,
                    observedAt: base.observedAt,
                    cleanupEligible: base.cleanupEligible,
                    metadataJSONRedacted:
                        try OwnershipAuthorityMetadata.encode(
                            authority,
                            into: "{}"
                        ),
                    resourceUUID: base.resourceUUID,
                    projectResourceUUID: nil,
                    fencingToken: base.fencingToken
                )
            )

            let status = HostwrightCLI.run(arguments: [
                "ownership", "status", "--state-db", databaseURL.path,
                "--json"
            ])
            XCTAssertEqual(status.exitCode, 0, status.standardError)
            let statusObject = try jsonObject(status.standardOutput)
            XCTAssertEqual(statusObject["schemaVersion"] as? Int, 1)
            let ownership = try XCTUnwrap(
                statusObject["ownership"] as? [[String: Any]]
            )
            XCTAssertEqual(ownership.count, 1)
            XCTAssertEqual(
                ownership[0]["authorityClassification"] as? String,
                "active"
            )
            XCTAssertEqual(
                ownership[0]["ownershipProofSHA256"] as? String,
                authority.ownershipProofSHA256
            )

            let handedOff = HostwrightCLI.run(arguments: [
                "ownership", "handoff",
                "--group", groupID,
                "--confirm-plan", plan,
                "--confirm-fence", fence,
                "--from-controller", originalOwner,
                "--from-expiry", priorExpiry,
                "--to-controller", "resume",
                "--lease-seconds", "60",
                "--state-db", databaseURL.path,
                "--json"
            ])
            XCTAssertEqual(handedOff.exitCode, 0, handedOff.standardError)
            let loadedGroup = try XCTUnwrap(
                store.operationGroups.load(id: groupID)
            )
            XCTAssertEqual(
                loadedGroup.lockOwner,
                "hostwright-recovery-resume"
            )
            let loadedOwnership = try XCTUnwrap(
                store.ownership.loadAll().first
            )
            let reboundAuthority = try XCTUnwrap(
                OwnershipAuthorityMetadata.decode(
                    from: loadedOwnership.metadataJSONRedacted
                )
            )
            XCTAssertEqual(
                reboundAuthority.leaseOwner,
                "hostwright-recovery-resume"
            )
            XCTAssertEqual(reboundAuthority.handoffGeneration, 1)

            let stale = HostwrightCLI.run(arguments: [
                "ownership", "handoff",
                "--group", groupID,
                "--confirm-plan", plan,
                "--confirm-fence", fence,
                "--from-controller", originalOwner,
                "--from-expiry", priorExpiry,
                "--to-controller", "rollback",
                "--lease-seconds", "60",
                "--state-db", databaseURL.path,
                "--json"
            ])
            XCTAssertEqual(
                stale.exitCode,
                CLIExitCode.confirmationMismatch.rawValue
            )
            XCTAssertTrue(
                stale.standardError.contains(
                    HostwrightErrorCode.confirmationMismatch.rawValue
                )
            )
        }
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any]
        )
    }

    private func withTemporaryStore(
        _ body: (SQLiteStateStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-ownership-command-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let store = SQLiteStateStore(path: databaseURL.path)
        try store.migrate()
        try body(store, databaseURL)
    }
}
