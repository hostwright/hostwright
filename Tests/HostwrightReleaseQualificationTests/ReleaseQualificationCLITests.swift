import Foundation
import XCTest
import HostwrightCore
@testable import HostwrightReleaseQualification

final class ReleaseQualificationCLITests: XCTestCase {
    func testLaneEvidenceStatusPreservesPrimaryExecutionFailure() {
        XCTAssertEqual(
            ReleaseQualificationLaneEvidenceStatus.resolve(
                executionStatus: .passed,
                sourceAvailability: .available,
                sourceDirty: true
            ),
            .dirty
        )
        XCTAssertEqual(
            ReleaseQualificationLaneEvidenceStatus.resolve(
                executionStatus: .blocked,
                sourceAvailability: .available,
                sourceDirty: true
            ),
            .blocked
        )
        XCTAssertEqual(
            ReleaseQualificationLaneEvidenceStatus.resolve(
                executionStatus: .unavailable,
                sourceAvailability: .unavailable,
                sourceDirty: nil
            ),
            .unavailable
        )
        XCTAssertEqual(
            ReleaseQualificationLaneEvidenceStatus.resolve(
                executionStatus: .failed,
                sourceAvailability: .available,
                sourceDirty: true
            ),
            .failed
        )
        XCTAssertEqual(
            ReleaseQualificationLaneEvidenceStatus.resolve(
                executionStatus: .passed,
                sourceAvailability: .available,
                sourceDirty: false,
                sourceChangedDuringExecution: true
            ),
            .stale
        )
    }

    func testLocalLaneEvidenceClassBindsProducerInsteadOfRegistryOrder() throws {
        let committed = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "dependency-lock-integrity"
            }
        )
        XCTAssertTrue(committed.requiredEvidenceClasses.contains(.unitContract))
        XCTAssertEqual(
            try ReleaseQualificationLocalLaneEvidenceClass.resolve(for: committed),
            .localIntegration
        )

        let mismatched = ReleaseQualificationLane(
            id: committed.id,
            kind: committed.kind,
            target: committed.target,
            executionMode: committed.executionMode,
            authority: committed.authority,
            requiredEvidenceClasses: [.unitContract],
            budget: committed.budget,
            corpus: committed.corpus,
            exclusions: committed.exclusions
        )
        XCTAssertThrowsError(
            try ReleaseQualificationLocalLaneEvidenceClass.resolve(for: mismatched)
        ) { error in
            XCTAssertEqual(
                error as? ReleaseQualificationContractError,
                .invalid(
                    field: "lane.requiredEvidenceClasses",
                    reason: "local lane producer evidence class is not declared"
                )
            )
        }
    }

    func testParserRejectsUnknownAndDuplicateOptions() {
        XCTAssertThrowsError(
            try ReleaseQualificationCLIInvocation(
                arguments: ["plan", "--unknown"]
            )
        )
        XCTAssertThrowsError(
            try ReleaseQualificationCLIInvocation(
                arguments: ["plan", "--root", "/tmp", "--root", "/tmp"]
            )
        )
        XCTAssertThrowsError(
            try ReleaseQualificationCLIInvocation(
                arguments: ["verify", "--cell", "not-a-committed-cell"]
            )
        )
        XCTAssertThrowsError(
            try ReleaseQualificationCLIInvocation(
                arguments: ["status", "--ledger-root", "/tmp", "--root", "/tmp"]
            )
        )
        XCTAssertThrowsError(
            try ReleaseQualificationCLIInvocation(
                arguments: [
                    "verify", "--cell", "macos26-arm64-container-1.0.0",
                    "--lane", "documentation-source-contracts"
                ]
            )
        )
        XCTAssertThrowsError(
            try ReleaseQualificationCLIInvocation(
                arguments: ["verify", "--lane", "unknown-lane"]
            )
        )
        XCTAssertThrowsError(
            try ReleaseQualificationCLIInvocation(
                arguments: [
                    "verify", "--cell", "macos26-arm64-container-1.0.0",
                    "--execute-safe-checks",
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? ReleaseQualificationCLIError,
                .usage("unknown option --execute-safe-checks")
            )
        }
    }

    func testVerifyAcceptsExactLocalDocumentationLane() throws {
        let invocation = try ReleaseQualificationCLIInvocation(
            arguments: ["verify", "--lane", "documentation-source-contracts"]
        )

        XCTAssertEqual(invocation.command, .verify)
        XCTAssertNil(invocation.cellID)
        XCTAssertEqual(invocation.laneID, "documentation-source-contracts")
    }

    func testVerifyAcceptsCommittedDependencyLicenseAndSecretLaneIDs() throws {
        for laneID in ["dependency-lock-integrity", "license-policy", "secret-scan"] {
            let invocation = try ReleaseQualificationCLIInvocation(
                arguments: ["verify", "--lane", laneID]
            )
            XCTAssertEqual(invocation.command, .verify)
            XCTAssertNil(invocation.cellID)
            XCTAssertEqual(invocation.laneID, laneID)
        }
    }

    func testPlanUsesDetectedExactCommitDirtyBoundaryForLicensePolicy() throws {
        let fixture = try makeLicensePolicySnapshotFixture()
        let root = try makeSafeCheckSnapshotRepository(files: fixture.files)
        defer { try? FileManager.default.removeItem(at: root) }

        let planOutput = try ReleaseQualificationCLIExecutor().execute(
            try ReleaseQualificationCLIInvocation(
                arguments: ["plan", "--root", root.path]
            ),
            currentDirectory: root
        )
        let plan = try ReleaseQualificationJSON.decode(
            ReleaseQualificationPlanDocument.self,
            from: planOutput
        )
        XCTAssertEqual(
            plan.lanes.first { $0.laneID == "license-policy" }?.status,
            .ready
        )

        try Data("untracked drift\n".utf8).write(
            to: root.appendingPathComponent("drift.txt"),
            options: [.atomic]
        )
        let dirtyPlanOutput = try ReleaseQualificationCLIExecutor().execute(
            try ReleaseQualificationCLIInvocation(
                arguments: ["plan", "--root", root.path]
            ),
            currentDirectory: root
        )
        let dirtyPlan = try ReleaseQualificationJSON.decode(
            ReleaseQualificationPlanDocument.self,
            from: dirtyPlanOutput
        )
        let license = try XCTUnwrap(
            dirtyPlan.lanes.first { $0.laneID == "license-policy" }
        )
        XCTAssertEqual(license.status, .blocked)
        XCTAssertEqual(license.blockers.map(\.reason), [.dirtySource])
    }

    func testPhase15ScriptCannotReportSuccessForDirtyDocumentationEvidence() throws {
        let script = try String(
            contentsOf: ReleaseQualificationTestSupport.repositoryRoot()
                .appendingPathComponent("scripts/phase15-release-qualification.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("if evidence.get(\"status\") != \"passed\":"))
        XCTAssertTrue(
            script.contains(
                "if evidence.get(\"blockers\") or evidence.get(\"failures\"):"
            )
        )
        XCTAssertFalse(script.contains("{\"passed\", \"dirty\"}"))
        let rejection = try XCTUnwrap(
            script.range(of: "documentation lane is not promotable")
        )
        let success = try XCTUnwrap(
            script.range(of: "phase15 release qualification focused checks passed")
        )
        XCTAssertLessThan(rejection.lowerBound, success.lowerBound)
    }

    func testDocumentationLaneProducesExactNonPromotableOrPassingEvidence() throws {
        let root = ReleaseQualificationTestSupport.repositoryRoot()
        let invocation = try ReleaseQualificationCLIInvocation(
            arguments: [
                "verify", "--lane", "documentation-source-contracts",
                "--root", root.path
            ]
        )

        let output = try ReleaseQualificationCLIExecutor().execute(
            invocation,
            currentDirectory: root
        )
        let evidence = try ReleaseQualificationJSON.decode(
            ReleaseQualificationEvidence.self,
            from: output
        )

        XCTAssertEqual(evidence.claim.id, "lane.documentation-source-contracts")
        XCTAssertEqual(evidence.claim.matrixCellID, nil)
        XCTAssertEqual(evidence.evidenceClass, .localIntegration)
        let commands = evidence.commands.filter {
            $0.identity.purpose.hasPrefix("validate ")
        }
        XCTAssertEqual(commands.count, 2)
        guard commands.count == 2 else { return }
        XCTAssertEqual(commands.map(\.exitStatus), [0, 0])
        XCTAssertEqual(commands[0].identity.arguments.suffix(2), ["README.md", "docs"])
        XCTAssertTrue(commands[0].identity.arguments.contains {
            $0 == root.appendingPathComponent("scripts/check-doc-links.py").path
        })
        XCTAssertTrue(commands[1].identity.arguments.contains {
            $0 == root.appendingPathComponent("scripts/check-current-truth.py").path
        })
        XCTAssertTrue(evidence.failures.isEmpty)
        if evidence.source.dirty == true {
            XCTAssertEqual(evidence.status, .dirty)
            XCTAssertTrue(evidence.blockers.contains { $0.reason == .dirtySource })
            XCTAssertFalse(evidence.satisfiesRequiredGate)
        } else {
            XCTAssertEqual(evidence.status, .passed)
            XCTAssertTrue(evidence.satisfiesRequiredGate)
        }
    }

    func testDocumentationLaneMarksEvidenceStaleWhenTrackedSourceChangesDuringExecution() throws {
        let root = try makeDocumentationSnapshotRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = try ReleaseQualificationCLIInvocation(
            arguments: [
                "verify", "--lane", "documentation-source-contracts",
                "--root", root.path
            ]
        )
        let executor = ReleaseQualificationCLIExecutor(
            localLaneRunner: ReleaseQualificationLocalLaneRunner(
                commandRunner: ReleaseQualificationMutatingValidatorRunner(
                    sourceRoot: root,
                    replacement: Data("transient stale source drift\n".utf8)
                )
            )
        )

        let output = try executor.execute(invocation, currentDirectory: root)
        let evidence = try ReleaseQualificationJSON.decode(
            ReleaseQualificationEvidence.self,
            from: output
        )

        XCTAssertEqual(evidence.status, .stale)
        XCTAssertFalse(evidence.satisfiesRequiredGate)
        XCTAssertTrue(evidence.blockers.contains { $0.reason == .staleEvidence })
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("README.md")),
            Data("transient stale source drift\n".utf8)
        )
        XCTAssertEqual(
            evidence.commands.filter { $0.identity.purpose.hasPrefix("validate ") }
                .map(\.exitStatus),
            [0, 0]
        )
    }

    func testDependencyLockLaneProducesPassingGateEvidenceFromExactCommit() throws {
        let source = ReleaseQualificationTestSupport.repositoryRoot()
        let root = try makeSafeCheckSnapshotRepository(
            files: [
                "Package.swift": try Data(
                    contentsOf: source.appendingPathComponent("Package.swift")
                ),
                "Package.resolved": try Data(
                    contentsOf: source.appendingPathComponent("Package.resolved")
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = try ReleaseQualificationCLIInvocation(
            arguments: [
                "verify", "--lane", "dependency-lock-integrity", "--root", root.path,
            ]
        )

        let output = try ReleaseQualificationCLIExecutor().execute(
            invocation,
            currentDirectory: root
        )
        let evidence = try ReleaseQualificationJSON.decode(
            ReleaseQualificationEvidence.self,
            from: output
        )

        XCTAssertEqual(evidence.claim.id, "lane.dependency-lock-integrity")
        XCTAssertEqual(evidence.evidenceClass, .localIntegration)
        XCTAssertEqual(evidence.status, .passed)
        XCTAssertTrue(evidence.satisfiesRequiredGate)
        XCTAssertTrue(evidence.failures.isEmpty)
        XCTAssertTrue(evidence.blockers.isEmpty)
        let snapshotCommands = evidence.commands.filter {
            $0.identity.purpose.hasPrefix("snapshot committed safe-check input")
        }
        XCTAssertEqual(snapshotCommands.first?.identity.purpose,
                       "snapshot committed safe-check input names")
        XCTAssertFalse(snapshotCommands.dropFirst().isEmpty)
        XCTAssertTrue(snapshotCommands.dropFirst().allSatisfy {
            $0.identity.purpose.range(
                of: #"^snapshot committed safe-check input bytes request-sha256=[a-f0-9]{64}$"#,
                options: .regularExpression
            ) != nil
        })
    }

    func testLicensePolicyLaneProducesPassingExactCommitEvidenceWithoutTextLeakage() throws {
        let fixture = try makeLicensePolicySnapshotFixture()
        let root = try makeSafeCheckSnapshotRepository(files: fixture.files)
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = try ReleaseQualificationCLIInvocation(
            arguments: ["verify", "--lane", "license-policy", "--root", root.path]
        )

        let output = try ReleaseQualificationCLIExecutor().execute(
            invocation,
            currentDirectory: root
        )
        let evidence = try ReleaseQualificationJSON.decode(
            ReleaseQualificationEvidence.self,
            from: output
        )

        XCTAssertEqual(evidence.claim.id, "lane.license-policy")
        XCTAssertEqual(evidence.evidenceClass, .localIntegration)
        XCTAssertEqual(evidence.status, .passed)
        XCTAssertTrue(evidence.satisfiesRequiredGate)
        XCTAssertTrue(evidence.blockers.isEmpty)
        XCTAssertTrue(evidence.failures.isEmpty)
        XCTAssertFalse(
            String(decoding: output, as: UTF8.self).contains(
                "synthetic license-policy fixture"
            )
        )
        XCTAssertTrue(evidence.commands.contains {
            $0.identity.purpose == "snapshot committed safe-check input names"
        })

        try Data("untracked drift\n".utf8).write(
            to: root.appendingPathComponent("drift.txt"),
            options: [.atomic]
        )
        let dirtyOutput = try ReleaseQualificationCLIExecutor().execute(
            invocation,
            currentDirectory: root
        )
        let dirtyEvidence = try ReleaseQualificationJSON.decode(
            ReleaseQualificationEvidence.self,
            from: dirtyOutput
        )
        XCTAssertEqual(dirtyEvidence.status, .dirty)
        XCTAssertTrue(dirtyEvidence.blockers.contains { $0.reason == .dirtySource })
        XCTAssertFalse(dirtyEvidence.satisfiesRequiredGate)
    }

    func testLicensePolicyLaneMarksEvidenceStaleWhenSourceChangesDuringExecution() throws {
        var fixture = try makeLicensePolicySnapshotFixture()
        fixture.files["README.md"] = Data("clean committed source\n".utf8)
        let root = try makeSafeCheckSnapshotRepository(files: fixture.files)
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = try ReleaseQualificationCLIInvocation(
            arguments: ["verify", "--lane", "license-policy", "--root", root.path]
        )
        let replacement = Data("transient license-policy source drift\n".utf8)
        let executor = ReleaseQualificationCLIExecutor(
            localLaneRunner: ReleaseQualificationLocalLaneRunner(
                sourceSnapshotRunner: ReleaseQualificationMutatingSnapshotRunner(
                    sourceRoot: root,
                    replacement: replacement
                )
            )
        )

        let output = try executor.execute(invocation, currentDirectory: root)
        let evidence = try ReleaseQualificationJSON.decode(
            ReleaseQualificationEvidence.self,
            from: output
        )

        XCTAssertEqual(evidence.status, .stale)
        XCTAssertTrue(evidence.blockers.contains { $0.reason == .staleEvidence })
        XCTAssertFalse(evidence.satisfiesRequiredGate)
        XCTAssertTrue(evidence.failures.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("README.md")),
            replacement
        )
    }

    func testSecretScanLanePreservesRealFailureAndCannotSatisfyGate() throws {
        let credential = "AKIA" + String(repeating: "B", count: 16)
        let root = try makeSafeCheckSnapshotRepository(
            files: ["credentials.txt": Data((credential + "\n").utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = try ReleaseQualificationCLIInvocation(
            arguments: ["verify", "--lane", "secret-scan", "--root", root.path]
        )

        let output = try ReleaseQualificationCLIExecutor().execute(
            invocation,
            currentDirectory: root
        )
        let evidence = try ReleaseQualificationJSON.decode(
            ReleaseQualificationEvidence.self,
            from: output
        )

        XCTAssertEqual(evidence.claim.id, "lane.secret-scan")
        XCTAssertEqual(evidence.evidenceClass, .securityAssessment)
        XCTAssertEqual(evidence.status, .failed)
        XCTAssertEqual(
            evidence.failures,
            ["high-confidence AWS-access-key pattern in credentials.txt"]
        )
        XCTAssertFalse(evidence.satisfiesRequiredGate)
    }

    func testExactCommitSafeLaneCannotPromoteDirtyWorkingTree() throws {
        let root = try makeSafeCheckSnapshotRepository(
            files: ["README.md": Data("clean committed source\n".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("untracked drift\n".utf8).write(
            to: root.appendingPathComponent("drift.txt"),
            options: [.atomic]
        )
        let invocation = try ReleaseQualificationCLIInvocation(
            arguments: ["verify", "--lane", "secret-scan", "--root", root.path]
        )

        let output = try ReleaseQualificationCLIExecutor().execute(
            invocation,
            currentDirectory: root
        )
        let evidence = try ReleaseQualificationJSON.decode(
            ReleaseQualificationEvidence.self,
            from: output
        )

        XCTAssertEqual(evidence.status, .dirty)
        XCTAssertTrue(evidence.blockers.contains { $0.reason == .dirtySource })
        XCTAssertFalse(evidence.satisfiesRequiredGate)
    }

    func testPlanCommandIsCanonicalAndBounded() throws {
        let invocation = try ReleaseQualificationCLIInvocation(
            arguments: [
                "plan",
                "--root",
                ReleaseQualificationTestSupport.repositoryRoot().path
            ]
        )
        let output = try ReleaseQualificationCLIExecutor().execute(
            invocation,
            currentDirectory: ReleaseQualificationTestSupport.repositoryRoot()
        )
        let document = try ReleaseQualificationJSON.decode(
            ReleaseQualificationPlanDocument.self,
            from: output
        )
        XCTAssertEqual(document.kind, "hostwright.release-qualification.plan.v1")
        XCTAssertLessThanOrEqual(
            output.count,
            ReleaseQualificationLimits.maximumJSONBytes
        )
    }

    func testPrivateLedgerStatusAndResumeAreExplicit() throws {
        let root = try ReleaseQualificationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledgerRoot = root.appendingPathComponent("ledger")
        _ = try ReleaseQualificationLedgerStore(root: ledgerRoot)
        let statusInvocation = try ReleaseQualificationCLIInvocation(
            arguments: ["status", "--ledger-root", ledgerRoot.path]
        )
        let statusData = try ReleaseQualificationCLIExecutor().execute(
            statusInvocation,
            currentDirectory: root
        )
        let summary = try ReleaseQualificationJSON.decode(
            ReleaseQualificationLedgerSummary.self,
            from: statusData
        )
        XCTAssertEqual(summary.running, 0)

        let resumeInvocation = try ReleaseQualificationCLIInvocation(
            arguments: ["resume", "--ledger-root", ledgerRoot.path]
        )
        let resumeData = try ReleaseQualificationCLIExecutor().execute(
            resumeInvocation,
            currentDirectory: root
        )
        let resume = try ReleaseQualificationJSON.decode(
            ReleaseQualificationCLIResumeReport.self,
            from: resumeData
        )
        XCTAssertTrue(resume.recoveredRunIDs.isEmpty)
    }
}

private struct ReleaseQualificationMutatingValidatorRunner:
    ReleaseQualificationStandardInputCommandRunning,
    Sendable
{
    private final class State: @unchecked Sendable {
        var mutated = false
    }

    private let subprocess = ReleaseQualificationSubprocessRunner()
    private let state = State()
    private let sourceRoot: URL
    private let replacement: Data

    init(sourceRoot: URL, replacement: Data) {
        self.sourceRoot = sourceRoot
        self.replacement = replacement
    }

    func run(
        _ command: ReleaseQualificationCommandIdentity,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        try run(
            command,
            standardInput: nil,
            limits: limits,
            cancellation: cancellation
        )
    }

    func run(
        _ command: ReleaseQualificationCommandIdentity,
        standardInput: Data?,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        let result = try subprocess.run(
            command,
            standardInput: standardInput,
            limits: limits,
            cancellation: cancellation
        )
        if command.purpose.hasPrefix("validate "), !state.mutated {
            try replacement.write(
                to: sourceRoot.appendingPathComponent("README.md"),
                options: .atomic
            )
            state.mutated = true
        }
        return result
    }
}
