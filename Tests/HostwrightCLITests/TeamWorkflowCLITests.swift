import Foundation
import HostwrightPolicy
import HostwrightTestSupport
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightHealth
@testable import HostwrightManifest
@testable import HostwrightReconciler
@testable import HostwrightRuntime
@testable import HostwrightSecrets
@testable import HostwrightState

final class TeamWorkflowCLITests: XCTestCase {
    func testParserRequiresExplicitProfileAndApprovalPairForMutations() throws {
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["validate", "manifest.yaml", "--team-profile", "team.json"]),
            .validate(path: "manifest.yaml", teamProfilePath: "team.json")
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["plan", "--team-profile", "team.json", "--output", "json"]),
            .plan(path: "hostwright.yaml", output: .json, teamProfilePath: "team.json")
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["import-stack", "compose.yaml", "--team-profile", "team.json"]),
            .importStack(path: "compose.yaml", output: .text, teamProfilePath: "team.json")
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "apply", "--state-db", "state.sqlite", "--confirm-plan", "plan",
                "--team-profile", "team.json", "--approval-record", "approval.json"
            ]),
            .apply(
                path: "hostwright.yaml",
                stateDatabasePath: "state.sqlite",
                confirmedPlanHash: "plan",
                teamProfilePath: "team.json",
                approvalRecordPath: "approval.json"
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "cleanup", "--state-db", "state.sqlite", "--dry-run", "--team-profile", "team.json"
            ]),
            .cleanup(
                path: "hostwright.yaml",
                stateDatabasePath: "state.sqlite",
                confirmation: .dryRun,
                teamProfilePath: "team.json",
                approvalRecordPath: nil
            )
        )

        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "apply", "--state-db", "state.sqlite", "--confirm-plan", "plan", "--team-profile", "team.json"
        ]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "apply", "--state-db", "state.sqlite", "--confirm-plan", "plan", "--approval-record", "approval.json"
        ]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "cleanup", "--state-db", "state.sqlite", "--dry-run", "--team-profile", "team.json", "--approval-record", "approval.json"
        ]))
    }

    func testDirectCommandConstructionCannotBypassTeamPathPairing() throws {
        try withTemporaryDirectory { directory in
            let databasePath = directory.appendingPathComponent("state.sqlite").path
            let apply = try HostwrightCLI.run(
                command: .apply(
                    path: directory.appendingPathComponent("missing.yaml").path,
                    stateDatabasePath: databasePath,
                    confirmedPlanHash: "plan",
                    teamProfilePath: directory.appendingPathComponent("team.json").path,
                    approvalRecordPath: nil
                ),
                environment: .live
            )
            XCTAssertEqual(apply.exitCode, CLIExitCode.commandUsage.rawValue)
            XCTAssertTrue(apply.standardError.contains("both --team-profile and --approval-record"))

            let cleanup = try HostwrightCLI.run(
                command: .cleanup(
                    path: directory.appendingPathComponent("missing.yaml").path,
                    stateDatabasePath: databasePath,
                    confirmation: .dryRun,
                    teamProfilePath: nil,
                    approvalRecordPath: directory.appendingPathComponent("approval.json").path
                ),
                environment: .live
            )
            XCTAssertEqual(cleanup.exitCode, CLIExitCode.commandUsage.rawValue)
            XCTAssertTrue(cleanup.standardError.contains("requires --team-profile"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath))
        }
    }

    func testReadOnlyCommandsLoadRealProfileFilesAndEnforceDigestPolicy() throws {
        try withTemporaryDirectory { directory in
            let taggedManifestURL = directory.appendingPathComponent("tagged.yaml")
            let digestManifestURL = directory.appendingPathComponent("digest.yaml")
            let stackURL = directory.appendingPathComponent("compose.yaml")
            let profileURL = directory.appendingPathComponent("team.json")
            try taggedManifest.write(to: taggedManifestURL, atomically: true, encoding: .utf8)
            try digestManifest.write(to: digestManifestURL, atomically: true, encoding: .utf8)
            try digestStack.write(to: stackURL, atomically: true, encoding: .utf8)
            try writeJSON(validProfile(requirements: [.requireImageDigest, .requireManifestReview]), to: profileURL)

            let rejected = HostwrightCLI.run(
                arguments: ["validate", taggedManifestURL.path, "--team-profile", profileURL.path],
                environment: .live
            )
            XCTAssertEqual(rejected.exitCode, CLIExitCode.validation.rawValue)
            XCTAssertTrue(rejected.standardError.contains("require-digest"))

            let validated = HostwrightCLI.run(
                arguments: ["validate", digestManifestURL.path, "--team-profile", profileURL.path],
                environment: .live
            )
            XCTAssertEqual(validated.exitCode, 0)
            XCTAssertTrue(validated.standardOutput.contains("Team profile: dev.hostwright.team.local"))
            XCTAssertTrue(validated.standardOutput.contains("Profile hash:"))
            XCTAssertTrue(validated.standardOutput.contains("Manifest hash:"))

            let plan = HostwrightCLI.run(
                arguments: ["plan", digestManifestURL.path, "--team-profile", profileURL.path, "--output", "json"],
                environment: .live
            )
            XCTAssertEqual(plan.exitCode, 0)
            let planJSON = try jsonObject(plan.standardOutput)
            let teamPolicy = try XCTUnwrap(planJSON["teamPolicy"] as? [String: Any])
            XCTAssertEqual(teamPolicy["profileIdentifier"] as? String, "dev.hostwright.team.local")
            XCTAssertEqual(teamPolicy["approvalRequiredForMutation"] as? Bool, true)
            XCTAssertEqual((teamPolicy["profileHash"] as? String)?.count, 64)
            XCTAssertEqual((teamPolicy["manifestHash"] as? String)?.count, 64)
            XCTAssertEqual(teamPolicy["planHash"] as? String, planJSON["planHash"] as? String)

            let ordinaryPlan = HostwrightCLI.run(
                arguments: ["plan", digestManifestURL.path, "--output", "json"],
                environment: .live
            )
            XCTAssertNil(try jsonObject(ordinaryPlan.standardOutput)["teamPolicy"])

            let imported = HostwrightCLI.run(
                arguments: ["import-stack", stackURL.path, "--team-profile", profileURL.path, "--output", "json"],
                environment: .live
            )
            XCTAssertEqual(imported.exitCode, 0)
            XCTAssertNotNil(try jsonObject(imported.standardOutput)["teamPolicy"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.sqlite").path))
        }
    }

    func testInvalidProfileProducesStableRedactedJSONError() throws {
        try withTemporaryDirectory { directory in
            let manifestURL = directory.appendingPathComponent("hostwright.yaml")
            let profileURL = directory.appendingPathComponent("team.json")
            let secret = "token=profile-secret-value"
            try digestManifest.write(to: manifestURL, atomically: true, encoding: .utf8)
            try """
            {"kind":"HostwrightTeamProfile","apiVersion":"\(secret)","identifier":"dev.hostwright.team","displayName":"Team","optIn":true,"requiredGates":[],"requirements":[]}
            """.write(to: profileURL, atomically: true, encoding: .utf8)

            let result = HostwrightCLI.run(
                arguments: ["plan", manifestURL.path, "--team-profile", profileURL.path, "--output", "json"],
                environment: .live
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.validation.rawValue)
            XCTAssertEqual(result.standardOutput, "")
            let error = try jsonObject(result.standardError)
            XCTAssertEqual(error["code"] as? String, HostwrightErrorCode.teamProfileInvalid.rawValue)
            XCTAssertFalse(result.standardError.contains(secret))
        }
    }

    func testApplyBindsApprovalToRuntimeConfirmationAndRealSQLiteAudit() throws {
        try withTemporaryDirectory { directory in
            let manifestURL = directory.appendingPathComponent("hostwright.yaml")
            let profileURL = directory.appendingPathComponent("team.json")
            let approvalURL = directory.appendingPathComponent("approval.json")
            let databaseURL = directory.appendingPathComponent("state.sqlite")
            try digestManifest.write(to: manifestURL, atomically: true, encoding: .utf8)
            let profile = validProfile(requirements: [.requireImageDigest, .requireManifestReview])
            try writeJSON(profile, to: profileURL)

            let adapter = CapturingRuntimeAdapter(observedServices: [])
            let planHash = try currentPlanHash(manifestText: digestManifest, observedState: adapter.observedState)
            let profileArtifact = try TeamWorkflowDocumentParser.parseProfile(String(contentsOf: profileURL, encoding: .utf8))
            let manifestHash = TeamWorkflowDocumentParser.manifestHash(digestManifest)
            let reviewerSecret = "approval-reviewer-secret"
            let approval = TeamApprovalRecord(
                id: "approval-apply-1",
                reviewer: "maintainer token=\(reviewerSecret)",
                decision: .approved,
                scope: .apply,
                recordedAt: "2026-07-12T12:00:00Z",
                profileHash: profileArtifact.profileHash,
                manifestHash: manifestHash,
                planHash: planHash
            )
            try writeJSON(approval, to: approvalURL)
            let approvalArtifact = try TeamWorkflowDocumentParser.parseApproval(String(contentsOf: approvalURL, encoding: .utf8))

            let result = HostwrightCLI.run(
                arguments: [
                    "apply", manifestURL.path, "--state-db", databaseURL.path, "--confirm-plan", planHash,
                    "--team-profile", profileURL.path, "--approval-record", approvalURL.path
                ],
                environment: environment(adapter: adapter)
            )

            XCTAssertEqual(result.exitCode, 0, result.standardError)
            XCTAssertEqual(adapter.executedActions.count, 1)
            let confirmation = try XCTUnwrap(adapter.confirmations.first)
            XCTAssertEqual(confirmation.planHash, planHash)
            XCTAssertEqual(confirmation.profileHash, profileArtifact.profileHash)
            XCTAssertEqual(confirmation.manifestHash, manifestHash)
            XCTAssertEqual(confirmation.approvalHash, approvalArtifact.approvalHash)

            let store = SQLiteStateStore(path: databaseURL.path)
            try store.migrate()
            let operations = try store.operations.loadAll()
            XCTAssertTrue(operations.contains { $0.payloadJSONRedacted.contains(approvalArtifact.approvalHash) })
            let audit = try XCTUnwrap(try store.events.loadAll().first { $0.type == "team.approval.recorded" })
            XCTAssertTrue(audit.payloadJSONRedacted.contains(profileArtifact.profileHash))
            XCTAssertTrue(audit.payloadJSONRedacted.contains(manifestHash))
            XCTAssertTrue(audit.payloadJSONRedacted.contains(planHash))
            XCTAssertTrue(audit.payloadJSONRedacted.contains(approvalArtifact.approvalHash))
            XCTAssertFalse(audit.payloadJSONRedacted.contains(reviewerSecret))
            XCTAssertTrue(audit.payloadJSONRedacted.contains("[REDACTED]"))
        }
    }

    func testMismatchedApprovalStopsBeforeRuntimeMutation() throws {
        try withTemporaryDirectory { directory in
            let manifestURL = directory.appendingPathComponent("hostwright.yaml")
            let profileURL = directory.appendingPathComponent("team.json")
            let approvalURL = directory.appendingPathComponent("approval.json")
            let databaseURL = directory.appendingPathComponent("state.sqlite")
            try digestManifest.write(to: manifestURL, atomically: true, encoding: .utf8)
            let profile = validProfile(requirements: [.requireManifestReview])
            try writeJSON(profile, to: profileURL)
            let profileArtifact = try TeamWorkflowDocumentParser.parseProfile(String(contentsOf: profileURL, encoding: .utf8))
            let adapter = CapturingRuntimeAdapter(observedServices: [])
            let planHash = try currentPlanHash(manifestText: digestManifest, observedState: adapter.observedState)
            try writeJSON(
                TeamApprovalRecord(
                    id: "approval-wrong-plan",
                    reviewer: "local-maintainer",
                    decision: .approved,
                    scope: .apply,
                    recordedAt: "2026-07-12T12:00:00Z",
                    profileHash: profileArtifact.profileHash,
                    manifestHash: TeamWorkflowDocumentParser.manifestHash(digestManifest),
                    planHash: "stale-plan"
                ),
                to: approvalURL
            )

            let result = HostwrightCLI.run(
                arguments: [
                    "apply", manifestURL.path, "--state-db", databaseURL.path, "--confirm-plan", planHash,
                    "--team-profile", profileURL.path, "--approval-record", approvalURL.path
                ],
                environment: environment(adapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.confirmationMismatch.rawValue)
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.teamBindingMismatch.rawValue))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            let store = SQLiteStateStore(path: databaseURL.path)
            try store.migrate()
            XCTAssertTrue(try store.operations.loadAll().isEmpty)
        }
    }

    func testCleanupBindsProfileIntoTokenAndPersistsApprovalAudit() throws {
        try withTemporaryDirectory { directory in
            let manifestURL = directory.appendingPathComponent("hostwright.yaml")
            let profileURL = directory.appendingPathComponent("team.json")
            let approvalURL = directory.appendingPathComponent("approval.json")
            let databaseURL = directory.appendingPathComponent("state.sqlite")
            try digestManifest.write(to: manifestURL, atomically: true, encoding: .utf8)
            try writeJSON(validProfile(requirements: [.requireManifestReview]), to: profileURL)
            let profileArtifact = try TeamWorkflowDocumentParser.parseProfile(String(contentsOf: profileURL, encoding: .utf8))
            let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
            let observedService = ObservedRuntimeService(
                identity: identity,
                resourceIdentifier: identity.managedResourceIdentifier,
                image: digestImage,
                lifecycleState: .stopped,
                healthState: .unknown
            )
            let adapter = CapturingRuntimeAdapter(observedServices: [observedService])
            let store = SQLiteStateStore(path: databaseURL.path)
            try store.migrate()
            try seedDesiredProject(store: store, manifestPath: manifestURL.path)
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "ownership-api",
                    resourceIdentifier: identity.managedResourceIdentifier,
                    resourceType: "container",
                    projectID: "project-demo",
                    serviceName: "api",
                    runtimeAdapter: adapter.adapterMetadata.adapterName,
                    createdAt: "2026-07-12T12:00:00Z",
                    observedAt: "2026-07-12T12:00:00Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}",
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion
                )
            )

            let dryRun = HostwrightCLI.run(
                arguments: [
                    "cleanup", manifestURL.path, "--state-db", databaseURL.path, "--dry-run",
                    "--team-profile", profileURL.path
                ],
                environment: environment(adapter: adapter)
            )
            XCTAssertEqual(dryRun.exitCode, 0, dryRun.standardError)
            let token = try value(after: "Confirmation token: ", in: dryRun.standardOutput)
            XCTAssertTrue(dryRun.standardOutput.contains("Approval required for confirmed cleanup: yes"))
            let manifestHash = TeamWorkflowDocumentParser.manifestHash(digestManifest)
            try writeJSON(
                TeamApprovalRecord(
                    id: "approval-cleanup-1",
                    reviewer: "local-maintainer",
                    decision: .approved,
                    scope: .cleanup,
                    recordedAt: "2026-07-12T12:00:00Z",
                    profileHash: profileArtifact.profileHash,
                    manifestHash: manifestHash,
                    planHash: token
                ),
                to: approvalURL
            )
            let approvalArtifact = try TeamWorkflowDocumentParser.parseApproval(String(contentsOf: approvalURL, encoding: .utf8))

            let confirmed = HostwrightCLI.run(
                arguments: [
                    "cleanup", manifestURL.path, "--state-db", databaseURL.path, "--confirm-cleanup", token,
                    "--team-profile", profileURL.path, "--approval-record", approvalURL.path
                ],
                environment: environment(adapter: adapter)
            )

            XCTAssertEqual(confirmed.exitCode, 0, confirmed.standardError)
            XCTAssertEqual(adapter.executedActions.map(\.kind), [.remove])
            let confirmation = try XCTUnwrap(adapter.confirmations.last)
            XCTAssertEqual(confirmation.planHash, token)
            XCTAssertEqual(confirmation.profileHash, profileArtifact.profileHash)
            XCTAssertEqual(confirmation.manifestHash, manifestHash)
            XCTAssertEqual(confirmation.approvalHash, approvalArtifact.approvalHash)
            let events = try store.events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "team.profile.selected" })
            XCTAssertTrue(events.contains { $0.type == "team.approval.recorded" && $0.payloadJSONRedacted.contains(approvalArtifact.approvalHash) })
        }
    }

    func testApprovalCannotBypassCleanupOwnership() throws {
        try withTemporaryDirectory { directory in
            let manifestURL = directory.appendingPathComponent("hostwright.yaml")
            let profileURL = directory.appendingPathComponent("team.json")
            let approvalURL = directory.appendingPathComponent("approval.json")
            let databaseURL = directory.appendingPathComponent("state.sqlite")
            try digestManifest.write(to: manifestURL, atomically: true, encoding: .utf8)
            try writeJSON(validProfile(requirements: [.requireManifestReview]), to: profileURL)
            let profileArtifact = try TeamWorkflowDocumentParser.parseProfile(String(contentsOf: profileURL, encoding: .utf8))
            let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
            let adapter = CapturingRuntimeAdapter(
                observedServices: [
                    ObservedRuntimeService(
                        identity: identity,
                        resourceIdentifier: identity.managedResourceIdentifier,
                        image: digestImage,
                        lifecycleState: .stopped,
                        healthState: .unknown
                    )
                ]
            )
            let store = SQLiteStateStore(path: databaseURL.path)
            try store.migrate()
            try seedDesiredProject(store: store, manifestPath: manifestURL.path)

            let dryRun = HostwrightCLI.run(
                arguments: [
                    "cleanup", manifestURL.path, "--state-db", databaseURL.path, "--dry-run",
                    "--team-profile", profileURL.path
                ],
                environment: environment(adapter: adapter)
            )
            let token = try value(after: "Confirmation token: ", in: dryRun.standardOutput)
            try writeJSON(
                TeamApprovalRecord(
                    id: "approval-unowned",
                    reviewer: "local-maintainer",
                    decision: .approved,
                    scope: .cleanup,
                    recordedAt: "2026-07-12T12:00:00Z",
                    profileHash: profileArtifact.profileHash,
                    manifestHash: TeamWorkflowDocumentParser.manifestHash(digestManifest),
                    planHash: token
                ),
                to: approvalURL
            )

            let confirmed = HostwrightCLI.run(
                arguments: [
                    "cleanup", manifestURL.path, "--state-db", databaseURL.path, "--confirm-cleanup", token,
                    "--team-profile", profileURL.path, "--approval-record", approvalURL.path
                ],
                environment: environment(adapter: adapter)
            )

            XCTAssertEqual(confirmed.exitCode, CLIExitCode.commandUsage.rawValue)
            XCTAssertTrue(confirmed.standardError.contains("no eligible Hostwright-owned"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
        }
    }

    func testApprovalCannotBypassManagedStartOwnership() throws {
        try withTemporaryDirectory { directory in
            let manifestURL = directory.appendingPathComponent("hostwright.yaml")
            let profileURL = directory.appendingPathComponent("team.json")
            let approvalURL = directory.appendingPathComponent("approval.json")
            let databaseURL = directory.appendingPathComponent("state.sqlite")
            try digestRestartManifest.write(to: manifestURL, atomically: true, encoding: .utf8)
            try writeJSON(validProfile(requirements: [.requireManifestReview]), to: profileURL)
            let profileArtifact = try TeamWorkflowDocumentParser.parseProfile(String(contentsOf: profileURL, encoding: .utf8))
            let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
            let adapter = CapturingRuntimeAdapter(
                observedServices: [
                    ObservedRuntimeService(
                        identity: identity,
                        resourceIdentifier: identity.managedResourceIdentifier,
                        image: digestImage,
                        lifecycleState: .stopped,
                        healthState: .unknown
                    )
                ]
            )
            let planHash = try currentPlanHash(manifestText: digestRestartManifest, observedState: adapter.observedState)
            try writeJSON(
                TeamApprovalRecord(
                    id: "approval-unowned-start",
                    reviewer: "local-maintainer",
                    decision: .approved,
                    scope: .apply,
                    recordedAt: "2026-07-12T12:00:00Z",
                    profileHash: profileArtifact.profileHash,
                    manifestHash: TeamWorkflowDocumentParser.manifestHash(digestRestartManifest),
                    planHash: planHash
                ),
                to: approvalURL
            )

            let result = HostwrightCLI.run(
                arguments: [
                    "apply", manifestURL.path, "--state-db", databaseURL.path, "--confirm-plan", planHash,
                    "--team-profile", profileURL.path, "--approval-record", approvalURL.path
                ],
                environment: environment(adapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("Hostwright ownership record"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
            let store = SQLiteStateStore(path: databaseURL.path)
            try store.migrate()
            XCTAssertTrue(try store.operations.loadAll().isEmpty)
        }
    }

    private var digestImage: String {
        "local/demo@sha256:\(String(repeating: "a", count: 64))"
    }

    private var digestManifest: String {
        """
        version: 2
        project: demo
        services:
          api:
            image: \(digestImage)
            command: ["serve"]
            ports:
              - "8080:8080"

        """
    }

    private var taggedManifest: String {
        """
        version: 2
        project: demo
        services:
          api:
            image: local/demo:latest

        """
    }

    private var digestRestartManifest: String {
        """
        version: 2
        project: demo
        services:
          api:
            image: \(digestImage)
            restart:
              policy: on-failure

        """
    }

    private var digestStack: String {
        """
        name: demo
        services:
          api:
            image: \(digestImage)
            command: ["serve"]
            ports:
              - "8080:8080"

        """
    }

    private func validProfile(requirements: [TeamPolicyRequirement]) -> TeamPolicyProfile {
        TeamPolicyProfile(
            identifier: "dev.hostwright.team.local",
            displayName: "Local Maintainers",
            optIn: true,
            requiredGates: TeamWorkflowGate.allCases,
            requirements: requirements
        )
    }

    private func currentPlanHash(manifestText: String, observedState: ObservedRuntimeState) throws -> String {
        let manifest = try ManifestValidator.validated(manifestText)
        return ReconciliationPlanner().plan(manifest: manifest, observedState: observedState).planHash
    }

    private func seedDesiredProject(store: SQLiteStateStore, manifestPath: String) throws {
        try store.desiredStates.saveManifestSnapshot(
            projectID: "project-demo",
            manifestPath: manifestPath,
            manifestHash: TeamWorkflowDocumentParser.manifestHash(digestManifest),
            desiredGeneration: 1,
            manifest: try ManifestValidator.validated(digestManifest),
            timestamp: "2026-07-12T12:00:00Z"
        )
    }

    private func environment(adapter: CapturingRuntimeAdapter) -> CLIEnvironment {
        CLIEnvironment(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            readTextFile: { try String(contentsOfFile: $0, encoding: .utf8) },
            writeTextFile: { path, text in try text.write(toFile: path, atomically: true, encoding: .utf8) },
            executablePath: { _ in nil },
            runtimeAdapter: { adapter },
            secretStore: { UnavailableKeychainSecretStore() },
            swiftVersion: { "Swift test" },
            platformSnapshot: { PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64") },
            operatingSystemDescription: { "macOS test" }
        )
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func value(after prefix: String, in output: String) throws -> String {
        let line = try XCTUnwrap(output.split(separator: "\n").first { $0.hasPrefix(prefix) })
        return String(line.dropFirst(prefix.count))
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-team-xctest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private final class CapturingRuntimeAdapter: RuntimeAdapter, @unchecked Sendable {
    let adapterMetadata = RuntimeAdapterMetadata(
        adapterName: "TeamWorkflowTestAdapter",
        adapterVersion: "1",
        runtimeName: "test-runtime",
        runtimeVersion: "1",
        supportsMutation: true,
        capabilities: [.readOnlyObservation, .lifecycleMutation, .cleanup]
    )
    let observedState: ObservedRuntimeState
    private let lock = NSLock()
    private var capturedActions: [PlannedRuntimeAction] = []
    private var capturedConfirmations: [RuntimeMutationConfirmation] = []

    init(observedServices: [ObservedRuntimeService]) {
        observedState = ObservedRuntimeState(
            projectName: "demo",
            services: observedServices,
            adapterMetadata: adapterMetadata
        )
    }

    var executedActions: [PlannedRuntimeAction] {
        lock.withLock { capturedActions }
    }

    var confirmations: [RuntimeMutationConfirmation] {
        lock.withLock { capturedConfirmations }
    }

    func metadata() async -> RuntimeAdapterMetadata {
        adapterMetadata
    }

    func capabilities() async throws -> [RuntimeCapability] {
        adapterMetadata.capabilities
    }

    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        observedState
    }

    func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
        RuntimePlan(actions: [])
    }

    func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        lock.withLock {
            capturedActions.append(action)
            if let confirmation {
                capturedConfirmations.append(confirmation)
            }
        }
        return RuntimeEvent(
            identity: action.identity,
            message: "test runtime mutation completed",
            resourceIdentifier: action.resourceIdentifier
        )
    }

    func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        throw RuntimeAdapterError.capabilityUnavailable(.logStreaming)
    }
}
