import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightPolicy
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

typealias ApplyLifecycleDriverFactory =
    @Sendable (LifecycleCLIOptions) -> any LifecycleCommandDriving

struct ApplyLifecycleCompatibilityRunner {
    let manifestPath: String
    let stateDatabasePath: String?
    let confirmedPlanHash: String
    let teamProfilePath: String?
    let approvalRecordPath: String?
    let runtimeProvider: RuntimeProviderSelection
    let environment: CLIEnvironment
    let driverFactory: ApplyLifecycleDriverFactory

    init(
        manifestPath: String,
        stateDatabasePath: String?,
        confirmedPlanHash: String,
        teamProfilePath: String?,
        approvalRecordPath: String?,
        runtimeProvider: RuntimeProviderSelection,
        environment: CLIEnvironment,
        driverFactory: ApplyLifecycleDriverFactory? = nil
    ) {
        self.manifestPath = manifestPath
        self.stateDatabasePath = stateDatabasePath
        self.confirmedPlanHash = confirmedPlanHash
        self.teamProfilePath = teamProfilePath
        self.approvalRecordPath = approvalRecordPath
        self.runtimeProvider = runtimeProvider
        self.environment = environment
        self.driverFactory = driverFactory ?? { options in
            LifecycleLiveDriver(environment: environment, options: options)
        }
    }

    func run() -> CLIRunResult {
        do {
            if shouldUseLegacyApplyRunner() {
                return try legacyApplyRunner().run()
            }

            let security = ApplyLifecycleSecurityGate(
                manifestPath: manifestPath,
                stateDatabasePath: stateDatabasePath,
                confirmedPlanHash: confirmedPlanHash,
                teamProfilePath: teamProfilePath,
                approvalRecordPath: approvalRecordPath,
                environment: environment
            )
            _ = try security.validate()

            let options = LifecycleCLIOptions(
                command: .up,
                manifestPath: manifestPath,
                stateDatabasePath: stateDatabasePath,
                confirmationPlanSHA256: confirmedPlanHash,
                dryRun: false,
                runtimeProvider: runtimeProvider,
                output: .text
            )
            let driver = ApplyApprovedLifecycleDriver(
                base: driverFactory(options),
                security: security
            )
            return LifecycleCommandRunner(options: options, driver: driver).run()
        } catch let error as HostwrightDiagnostic {
            return failure(error)
        } catch let error as ManifestParseError {
            return failure(
                HostwrightDiagnostic(
                    code: .manifestValidationFailed,
                    message: error.issues.map(\.rendered).joined(separator: "\n")
                )
            )
        } catch let error as CLIUsageError {
            return failure(
                HostwrightDiagnostic(code: .commandUsage, message: error.message)
            )
        } catch {
            return failure(
                HostwrightDiagnostic(
                    code: .fileIOFailed,
                    message: RuntimeRedactionPolicy.default.redact(
                        String(describing: error)
                    )
                )
            )
        }
    }

    private func shouldUseLegacyApplyRunner() -> Bool {
        guard isLifecycleConfirmationHash(confirmedPlanHash) else {
            return true
        }
        guard teamProfilePath == nil, approvalRecordPath == nil else {
            return false
        }
        return hasLegacyApplyRecoveryState()
    }

    private func hasLegacyApplyRecoveryState() -> Bool {
        guard let configuration = try? hostwrightStateStoreConfiguration(
            explicitPath: stateDatabasePath,
            environment: environment
        ) else {
            return false
        }
        guard FileManager.default.fileExists(atPath: configuration.databasePath) else {
            return false
        }
        let store = SQLiteStateStore(configuration: configuration)
        guard let groups = try? store.operationGroups.loadAll() else {
            return false
        }
        return groups.contains { group in
            group.groupKind == "apply" &&
                group.planHash == confirmedPlanHash &&
                (
                    group.status == .active ||
                        (
                            group.status == .interrupted &&
                                group.checkpoint == ApplyCommandRunner.preRuntimeStateIncompleteCheckpoint
                        )
                )
        }
    }

    private func isLifecycleConfirmationHash(_ value: String) -> Bool {
        value.range(
            of: "^[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil
    }

    private func legacyApplyRunner() throws -> ApplyCommandRunner {
        ApplyCommandRunner(
            manifestPath: manifestPath,
            stateStoreConfiguration: try hostwrightStateStoreConfiguration(
                explicitPath: stateDatabasePath,
                environment: environment
            ),
            confirmedPlanHash: confirmedPlanHash,
            teamProfilePath: teamProfilePath,
            approvalRecordPath: approvalRecordPath,
            runtimeProvider: runtimeProvider,
            environment: environment
        )
    }

    private func failure(_ diagnostic: HostwrightDiagnostic) -> CLIRunResult {
        let exit = CLIExitCode.mapped(from: diagnostic.code)
        return CLIRunResult(
            standardError:
                "\(diagnostic.code.rawValue): " +
                "\(RuntimeRedactionPolicy.default.redact(diagnostic.message))\n",
            exitCode: exit.rawValue
        )
    }
}

private struct ApplyLifecycleSecurityGate: Sendable {
    let manifestPath: String
    let stateDatabasePath: String?
    let confirmedPlanHash: String
    let teamProfilePath: String?
    let approvalRecordPath: String?
    let environment: CLIEnvironment

    func validate() throws -> TeamWorkflowBinding? {
        guard (teamProfilePath == nil) == (approvalRecordPath == nil) else {
            throw HostwrightDiagnostic(
                code: .commandUsage,
                message:
                    "Profile-aware apply requires both --team-profile and " +
                    "--approval-record. No file, state, or runtime operation was attempted."
            )
        }
        let text = try hostwrightReadManifestText(
            path: manifestPath,
            environment: environment
        )
        let validated = try hostwrightValidatedManifest(
            text: text,
            teamProfilePath: teamProfilePath,
            environment: environment
        )
        guard validated.profileArtifact != nil else {
            return nil
        }
        guard let approvalRecordPath else {
            throw HostwrightDiagnostic(
                code: .teamApprovalInvalid,
                message: "Profile-aware apply requires an explicit approval record. No mutation was attempted."
            )
        }
        return try hostwrightApprovedBinding(
            approvalRecordPath: approvalRecordPath,
            scope: .apply,
            validatedManifest: validated,
            planHash: confirmedPlanHash,
            environment: environment
        )
    }

    func recordApproval(
        _ binding: TeamWorkflowBinding,
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation
    ) throws {
        let store = SQLiteStateStore(
            configuration: try hostwrightStateStoreConfiguration(
                explicitPath: stateDatabasePath,
                environment: environment
            )
        )
        try store.migrate()
        let timestamp = hostwrightTimestamp()
        var bindingPayload = hostwrightTeamBindingPayload(binding)
        if bindingPayload["approvalReviewer"] != nil {
            bindingPayload["approvalReviewer"] =
                RuntimeRedactionPolicy.default.replacement
        }
        let payload = jsonPayload(
            bindingPayload.merging([
                "lifecycleCommand": LifecycleCommand.up.rawValue,
                "lifecyclePlanSHA256": compiled.plan.planSHA256,
                "projectResourceUUID": preparation.projectResourceUUID,
                "providerID": preparation.providerID.rawValue
            ]) { current, _ in current }
        )
        try store.events.append([
            EventRecord(
                id: hostwrightUniqueID(prefix: "event-team-profile-selected"),
                timestamp: timestamp,
                severity: .info,
                type: "team.profile.selected",
                source: "hostwright-cli",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: preparation.providerID.rawValue,
                message: "Local team profile validated for lifecycle apply.",
                payloadJSONRedacted: payload
            ),
            EventRecord(
                id: hostwrightUniqueID(prefix: "event-team-approval-recorded"),
                timestamp: timestamp,
                severity: .info,
                type: "team.approval.recorded",
                source: "hostwright-cli",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: preparation.providerID.rawValue,
                message: "Local team approval validated for lifecycle apply.",
                payloadJSONRedacted: payload
            )
        ])
    }
}

private struct ApplyApprovedLifecycleDriver: LifecycleCommandDriving {
    let base: any LifecycleCommandDriving
    let security: ApplyLifecycleSecurityGate

    func prepare(
        options: LifecycleCLIOptions
    ) throws -> LifecycleCommandPreparation {
        try base.prepare(options: options)
    }

    func localImageEvidence(
        for requirement: LifecycleLocalImageRequirement,
        preparation: LifecycleCommandPreparation
    ) throws -> RuntimeLocalImageEvidence {
        try base.localImageEvidence(
            for: requirement,
            preparation: preparation
        )
    }

    func revalidate(
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation
    ) throws {
        _ = try security.validate()
        try base.revalidate(
            compiled: compiled,
            preparation: preparation
        )
    }

    func execute(
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation,
        options: LifecycleCLIOptions
    ) throws -> LifecycleSagaExecutionResult {
        if let binding = try security.validate() {
            try security.recordApproval(
                binding,
                compiled: compiled,
                preparation: preparation
            )
        }
        return try base.execute(
            compiled: compiled,
            preparation: preparation,
            options: options
        )
    }
}
