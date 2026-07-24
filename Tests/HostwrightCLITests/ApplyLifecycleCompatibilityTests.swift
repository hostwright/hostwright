import Foundation
import HostwrightCore
import HostwrightPolicy
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState
import Testing
@testable import HostwrightCLI

@Suite
struct ApplyLifecycleCompatibilityTests {
    @Test
    func approvedApplyExecutesTheConfirmedUpPlanAndRecordsApproval() throws {
        try withFixture { fixture in
            let preparation = try lifecyclePreparation()
            let previewOptions = LifecycleCLIOptions(
                command: .up,
                manifestPath: fixture.manifest.path,
                stateDatabasePath: fixture.database.path,
                dryRun: true,
                runtimeProvider: .appleCLI,
                output: .text
            )
            let confirmed = try LifecycleCommandPlanCompiler().compile(
                options: previewOptions,
                preparation: preparation
            ).plan.planSHA256
            try fixture.writeApproval(planHash: confirmed)
            let driver = CapturingApplyLifecycleDriver(preparation: preparation)

            let result = ApplyLifecycleCompatibilityRunner(
                manifestPath: fixture.manifest.path,
                stateDatabasePath: fixture.database.path,
                confirmedPlanHash: confirmed,
                teamProfilePath: fixture.profile.path,
                approvalRecordPath: fixture.approval.path,
                runtimeProvider: .appleCLI,
                environment: .live,
                driverFactory: { _ in driver }
            ).run()

            #expect(result.exitCode == 0, "\(result.standardError)")
            #expect(result.standardOutput.contains("Lifecycle succeeded"))
            #expect(
                driver.snapshot() ==
                    ApplyDriverSnapshot(
                        imageChecks: 1,
                        revalidations: 1,
                        executions: 1,
                        executedCommand: .up
                    )
            )

            let store = SQLiteStateStore(path: fixture.database.path)
            try store.migrate()
            let events = try store.events.loadAll()
            #expect(events.contains { $0.type == "team.profile.selected" })
            let approval = try #require(
                events.first { $0.type == "team.approval.recorded" }
            )
            #expect(approval.payloadJSONRedacted.contains(confirmed))
            #expect(!approval.payloadJSONRedacted.contains("reviewer-secret"))
        }
    }

    @Test
    func mismatchedApprovalFailsBeforeLifecyclePreparationOrMutation() throws {
        try withFixture { fixture in
            let preparation = try lifecyclePreparation()
            let previewOptions = LifecycleCLIOptions(
                command: .up,
                manifestPath: fixture.manifest.path,
                stateDatabasePath: fixture.database.path,
                dryRun: true,
                runtimeProvider: .appleCLI,
                output: .text
            )
            let confirmed = try LifecycleCommandPlanCompiler().compile(
                options: previewOptions,
                preparation: preparation
            ).plan.planSHA256
            try fixture.writeApproval(
                planHash: String(repeating: "f", count: 64)
            )
            let driver = CapturingApplyLifecycleDriver(preparation: preparation)

            let result = ApplyLifecycleCompatibilityRunner(
                manifestPath: fixture.manifest.path,
                stateDatabasePath: fixture.database.path,
                confirmedPlanHash: confirmed,
                teamProfilePath: fixture.profile.path,
                approvalRecordPath: fixture.approval.path,
                runtimeProvider: .appleCLI,
                environment: .live,
                driverFactory: { _ in driver }
            ).run()

            #expect(result.exitCode == CLIExitCode.confirmationMismatch.rawValue)
            #expect(result.standardError.contains(HostwrightErrorCode.teamBindingMismatch.rawValue))
            #expect(driver.snapshot() == ApplyDriverSnapshot())
            #expect(!FileManager.default.fileExists(atPath: fixture.database.path))
        }
    }

    @Test
    func unprofiledLegacyApplyHashDoesNotConstructLifecycleDriver() throws {
        try withFixture { fixture in
            let probe = ApplyDriverFactoryProbe(
                driver: CapturingApplyLifecycleDriver(
                    preparation: try lifecyclePreparation()
                )
            )

            let result = ApplyLifecycleCompatibilityRunner(
                manifestPath: fixture.manifest.path,
                stateDatabasePath: "/dev/null/hostwright.sqlite",
                confirmedPlanHash: "wrong-hash",
                teamProfilePath: nil,
                approvalRecordPath: nil,
                runtimeProvider: .appleCLI,
                environment: .live,
                driverFactory: probe.makeDriver(options:)
            ).run()

            #expect(result.exitCode != 0)
            #expect(probe.callCount() == 0)
        }
    }

    @Test
    func profiledLegacyApplyHashDoesNotConstructLifecycleDriver() throws {
        try withFixture { fixture in
            try fixture.writeApproval(planHash: "wrong-hash")
            let probe = ApplyDriverFactoryProbe(
                driver: CapturingApplyLifecycleDriver(
                    preparation: try lifecyclePreparation()
                )
            )

            let result = ApplyLifecycleCompatibilityRunner(
                manifestPath: fixture.manifest.path,
                stateDatabasePath: "/dev/null/hostwright.sqlite",
                confirmedPlanHash: "wrong-hash",
                teamProfilePath: fixture.profile.path,
                approvalRecordPath: fixture.approval.path,
                runtimeProvider: .appleCLI,
                environment: .live,
                driverFactory: probe.makeDriver(options:)
            ).run()

            #expect(result.exitCode != 0)
            #expect(probe.callCount() == 0)
        }
    }

    private func lifecyclePreparation() throws -> LifecycleCommandPreparation {
        let capability = String(repeating: "c", count: 64)
        let desired = DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api"
            ),
            image:
                "example.invalid/api@sha256:" +
                String(repeating: "1", count: 64),
            virtualization: false
        )
        return LifecycleCommandPreparation(
            manifestSHA256: String(repeating: "a", count: 64),
            manifestBaseDirectory: "/tmp",
            desiredState: DesiredRuntimeState(
                projectName: "demo",
                services: [desired]
            ),
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: [],
                adapterMetadata: RuntimeAdapterMetadata(
                    providerID: .appleContainerCLI,
                    adapterName: "test-apple-cli",
                    adapterVersion: "1",
                    runtimeName: "container",
                    runtimeVersion: "1.1.0",
                    supportsMutation: true,
                    capabilities: [.readOnlyObservation, .lifecycleMutation]
                ),
                capabilitySHA256: capability
            ),
            observationSHA256: String(repeating: "b", count: 64),
            projectID: "project-demo",
            projectResourceUUID: HostwrightResourceUUID.legacy(
                kind: "project",
                identifier: "project-demo"
            ),
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            capabilitySHA256: capability,
            planFencingToken: HostwrightResourceUUID.legacy(
                kind: "apply-compatibility-test",
                identifier: capability
            )
        )
    }

    private func withFixture(
        _ body: (ApplyCompatibilityFixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-apply-compatibility-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = ApplyCompatibilityFixture(root: root)
        try fixture.writeInputs()
        try body(fixture)
    }
}

private final class ApplyDriverFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let driver: any LifecycleCommandDriving
    private var calls = 0

    init(driver: any LifecycleCommandDriving) {
        self.driver = driver
    }

    func makeDriver(options: LifecycleCLIOptions) -> any LifecycleCommandDriving {
        lock.withLock {
            calls += 1
        }
        return driver
    }

    func callCount() -> Int {
        lock.withLock { calls }
    }
}

private struct ApplyCompatibilityFixture {
    let root: URL

    var manifest: URL { root.appendingPathComponent("hostwright.yaml") }
    var profile: URL { root.appendingPathComponent("team.json") }
    var approval: URL { root.appendingPathComponent("approval.json") }
    var database: URL { root.appendingPathComponent("state.sqlite") }

    func writeInputs() throws {
        try """
        version: 2
        project: demo
        services:
          api:
            image: example.invalid/api@sha256:\(String(repeating: "1", count: 64))

        """.write(to: manifest, atomically: true, encoding: .utf8)
        try writeJSON(
            TeamPolicyProfile(
                identifier: "dev.hostwright.team.apply",
                displayName: "Apply Reviewers",
                optIn: true,
                requiredGates: TeamWorkflowGate.allCases
            ),
            to: profile
        )
    }

    func writeApproval(planHash: String) throws {
        let profileArtifact = try TeamWorkflowDocumentParser.parseProfile(
            String(contentsOf: profile, encoding: .utf8)
        )
        let manifestText = try String(contentsOf: manifest, encoding: .utf8)
        try writeJSON(
            TeamApprovalRecord(
                id: "approval-phase04-apply",
                reviewer: "maintainer reviewer-secret",
                decision: .approved,
                scope: .apply,
                recordedAt: "2026-07-23T12:00:00Z",
                profileHash: profileArtifact.profileHash,
                manifestHash: TeamWorkflowDocumentParser.manifestHash(manifestText),
                planHash: planHash
            ),
            to: approval
        )
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

private struct ApplyDriverSnapshot: Equatable {
    var imageChecks = 0
    var revalidations = 0
    var executions = 0
    var executedCommand: LifecycleCommandKind?
}

private final class CapturingApplyLifecycleDriver:
    LifecycleCommandDriving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let preparation: LifecycleCommandPreparation
    private var counts = ApplyDriverSnapshot()

    init(preparation: LifecycleCommandPreparation) {
        self.preparation = preparation
    }

    func prepare(
        options: LifecycleCLIOptions
    ) throws -> LifecycleCommandPreparation {
        preparation
    }

    func localImageEvidence(
        for requirement: LifecycleLocalImageRequirement,
        preparation: LifecycleCommandPreparation
    ) throws -> RuntimeLocalImageEvidence {
        lock.withLock {
            counts.imageChecks += 1
        }
        return RuntimeLocalImageEvidence(
            reference: requirement.reference,
            descriptorDigest: "sha256:\(String(repeating: "d", count: 64))",
            variantDigest: "sha256:\(String(repeating: "e", count: 64))",
            architecture: requirement.architecture,
            operatingSystem: requirement.operatingSystem
        )
    }

    func revalidate(
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation
    ) throws {
        lock.withLock {
            counts.revalidations += 1
        }
    }

    func execute(
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation,
        options: LifecycleCLIOptions
    ) throws -> LifecycleSagaExecutionResult {
        lock.withLock {
            counts.executions += 1
            counts.executedCommand = options.command
        }
        return LifecycleSagaExecutionResult(
            status: .succeeded,
            operationID: HostwrightResourceUUID.generate(),
            groupID: HostwrightResourceUUID.generate(),
            planSHA256: compiled.plan.planSHA256,
            checkpoint: "complete",
            completedNodeKeys: compiled.plan.nodes.map(\.key),
            recoveryHintRedacted: ""
        )
    }

    func snapshot() -> ApplyDriverSnapshot {
        lock.withLock { counts }
    }
}
