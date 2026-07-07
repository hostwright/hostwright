import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

struct CleanupCommandRunner {
    let manifestPath: String
    let stateDatabasePath: String
    let confirmation: CleanupConfirmation
    let environment: CLIEnvironment

    func run() -> CLIRunResult {
        do {
            let manifest = try ManifestValidator.validated(environment.readTextFile(manifestPath))
            let mapping = ManifestRuntimeMapper.map(manifest)
            let configuration = StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
            try configuration.validate()
            let store = SQLiteStateStore(configuration: configuration)
            try store.migrate()

            let adapter = environment.runtimeAdapter()
            let observed: ObservedRuntimeState
            do {
                observed = try hostwrightWaitForAsync {
                    try await adapter.observe(desiredState: mapping.desiredState)
                }
            } catch {
                return failure(code: .runtimeUnavailable, message: "Runtime observation failed: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))")
            }
            let candidates = try cleanupCandidates(
                store: store,
                projectName: mapping.desiredState.projectName,
                observed: observed
            )
            let token = cleanupToken(for: candidates)

            switch confirmation {
            case .dryRun:
                try recordCleanupPlanned(store: store, projectName: mapping.desiredState.projectName, candidates: candidates, token: token, observed: observed)
                return CLIRunResult(standardOutput: renderDryRun(candidates: candidates, token: token))
            case .confirmed(let providedToken):
                guard providedToken == token else {
                    return failure(code: .confirmationMismatch, message: "cleanup confirmation token does not match current cleanup plan. Expected token: \(token)")
                }
                guard !candidates.isEmpty else {
                    return failure(code: .commandUsage, message: "cleanup has no eligible Hostwright-owned stopped/created/exited containers.")
                }
                return try executeCleanup(candidates: candidates, token: token, adapter: adapter, observed: observed, store: store, projectName: mapping.desiredState.projectName)
            }
        } catch let error as ManifestParseError {
            return CLIRunResult(standardError: error.issues.map(\.rendered).joined(separator: "\n") + "\n", exitCode: CLIExitCode.validation.rawValue)
        } catch {
            return failure(code: .stateStoreUnavailable, message: RuntimeRedactionPolicy.default.redact(String(describing: error)))
        }
    }

    private func cleanupCandidates(store: SQLiteStateStore, projectName: String, observed: ObservedRuntimeState) throws -> [CleanupCandidate] {
        let projectID = "project-\(projectName)"
        let observedByIdentifier = Dictionary(uniqueKeysWithValues: observed.services.map {
            ($0.identity.managedResourceIdentifier, $0)
        })

        return try store.ownership.loadAll()
            .filter { ownership in
                ownership.cleanupEligible &&
                ownership.resourceType == "container" &&
                ownership.projectID == projectID &&
                ownership.resourceIdentifier.hasPrefix("hostwright-")
            }
            .compactMap { ownership in
                guard let serviceName = ownership.serviceName,
                      let observedService = observedByIdentifier[ownership.resourceIdentifier],
                      observedService.identity.serviceName == serviceName,
                      isCleanupLifecycle(observedService.lifecycleState)
                else {
                    return nil
                }

                return CleanupCandidate(
                    identity: observedService.identity,
                    resourceIdentifier: ownership.resourceIdentifier,
                    lifecycleState: observedService.lifecycleState,
                    runtimeAdapter: ownership.runtimeAdapter
                )
            }
            .sorted { $0.resourceIdentifier < $1.resourceIdentifier }
    }

    private func isCleanupLifecycle(_ state: RuntimeLifecycleState) -> Bool {
        state == .created || state == .stopped || state == .exited
    }

    private func executeCleanup(
        candidates: [CleanupCandidate],
        token: String,
        adapter: any RuntimeAdapter,
        observed: ObservedRuntimeState,
        store: SQLiteStateStore,
        projectName: String
    ) throws -> CLIRunResult {
        let timestamp = hostwrightTimestamp()
        let projectID = "project-\(projectName)"
        let runtimeAdapter = observed.adapterMetadata?.adapterName
        var hadFailure = false
        var lines = [
            "Hostwright cleanup",
            "State DB: \(stateDatabasePath)",
            "Confirmation token: \(token)",
            ""
        ]

        for candidate in candidates {
            let idempotencyKey = "\(token):\(candidate.resourceIdentifier)"
            if let existingOperation = try store.operations.latest(idempotencyKey: idempotencyKey),
               existingOperation.status == .planned || existingOperation.status == .recorded || existingOperation.status == .succeeded {
                lines.append("- skipped \(candidate.resourceIdentifier): operation already \(existingOperation.status.rawValue)")
                continue
            }

            let operationID = hostwrightUniqueID(prefix: "operation-cleanup")
            try store.operations.record(
                OperationRecord(
                    id: "\(operationID)-recorded",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    plannedActionType: "deleteManagedContainer",
                    projectID: projectID,
                    serviceName: candidate.identity.serviceName,
                    status: .recorded,
                    idempotencyKey: idempotencyKey,
                    planHash: token,
                    payloadJSONRedacted: #"{"resourceIdentifier":"\#(candidate.resourceIdentifier)"}"#
                )
            )

            do {
                let event = try hostwrightWaitForAsync {
                    try await adapter.execute(
                        PlannedRuntimeAction(
                            kind: .remove,
                            identity: candidate.identity,
                            isDestructive: true,
                            summary: "Delete cleanup-eligible Hostwright-owned container \(candidate.resourceIdentifier)."
                        ),
                        confirmation: RuntimeMutationConfirmation(
                            confirmed: true,
                            reason: "Confirmed Hostwright cleanup \(token)",
                            planHash: token
                        )
                    )
                }

                let successTimestamp = hostwrightTimestamp()
                try store.operations.record(
                    OperationRecord(
                        id: "\(operationID)-succeeded",
                        createdAt: timestamp,
                        updatedAt: successTimestamp,
                        plannedActionType: "deleteManagedContainer",
                        projectID: projectID,
                        serviceName: candidate.identity.serviceName,
                        status: .succeeded,
                        idempotencyKey: idempotencyKey,
                        planHash: token,
                        payloadJSONRedacted: #"{"result":"deleted"}"#
                    )
                )
                try store.events.append([
                    EventRecord(
                        id: hostwrightUniqueID(prefix: "event-cleanup-deleted"),
                        timestamp: successTimestamp,
                        severity: .info,
                        type: "cleanup.deleted",
                        source: "hostwright-cli",
                        projectID: projectID,
                        serviceName: candidate.identity.serviceName,
                        runtimeAdapter: runtimeAdapter,
                        message: event.message,
                        payloadJSONRedacted: #"{"resourceIdentifier":"\#(candidate.resourceIdentifier)"}"#
                    )
                ])
                try store.ownership.markCleanupCompleted(
                    resourceIdentifier: candidate.resourceIdentifier,
                    runtimeAdapter: candidate.runtimeAdapter,
                    observedAt: successTimestamp,
                    metadataJSONRedacted: #"{"cleanupToken":"\#(token)","cleanupStatus":"deleted"}"#
                )
                lines.append("- deleted \(candidate.resourceIdentifier)")
            } catch {
                hadFailure = true
                let redactedError = RuntimeRedactionPolicy.default.redact(String(describing: error))
                do {
                    try store.operations.record(
                        OperationRecord(
                            id: "\(operationID)-failed",
                            createdAt: timestamp,
                            updatedAt: hostwrightTimestamp(),
                            plannedActionType: "deleteManagedContainer",
                            projectID: projectID,
                            serviceName: candidate.identity.serviceName,
                            status: .failed,
                            idempotencyKey: idempotencyKey,
                            planHash: token,
                            payloadJSONRedacted: #"{"error":"\#(redactedError)"}"#
                        )
                    )
                    try store.events.append([
                        EventRecord(
                            id: hostwrightUniqueID(prefix: "event-cleanup-failed"),
                            timestamp: hostwrightTimestamp(),
                            severity: .error,
                            type: "cleanup.failed",
                            source: "hostwright-cli",
                            projectID: projectID,
                            serviceName: candidate.identity.serviceName,
                            runtimeAdapter: runtimeAdapter,
                            message: "Cleanup failed for \(candidate.resourceIdentifier): \(redactedError)",
                            payloadJSONRedacted: #"{"resourceIdentifier":"\#(candidate.resourceIdentifier)"}"#
                        )
                    ])
                } catch {
                    lines.append("- failed \(candidate.resourceIdentifier): \(redactedError)")
                    lines.append("")
                    return CLIRunResult(
                        standardOutput: lines.joined(separator: "\n"),
                        standardError: "\(HostwrightErrorCode.runtimeUnavailable.rawValue): Cleanup runtime failure was primary: \(redactedError). Failure state persistence also failed: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))\n",
                        exitCode: CLIExitCode.runtimeUnavailable.rawValue
                    )
                }
                lines.append("- failed \(candidate.resourceIdentifier): \(redactedError)")
            }
        }

        lines.append("")
        if hadFailure {
            return CLIRunResult(
                standardOutput: lines.joined(separator: "\n"),
                standardError: "\(HostwrightErrorCode.partialFailure.rawValue): cleanup completed with one or more runtime failures; successful deletions were preserved in the report.\n",
                exitCode: CLIExitCode.partialFailure.rawValue
            )
        }
        return CLIRunResult(standardOutput: lines.joined(separator: "\n"))
    }

    private func recordCleanupPlanned(
        store: SQLiteStateStore,
        projectName: String,
        candidates: [CleanupCandidate],
        token: String,
        observed: ObservedRuntimeState
    ) throws {
        let timestamp = hostwrightTimestamp()
        try store.events.append([
            EventRecord(
                id: hostwrightUniqueID(prefix: "event-cleanup-planned"),
                timestamp: timestamp,
                severity: .info,
                type: "cleanup.planned",
                source: "hostwright-cli",
                projectID: "project-\(projectName)",
                serviceName: nil,
                runtimeAdapter: observed.adapterMetadata?.adapterName,
                message: "Cleanup planned \(candidates.count) eligible Hostwright-owned container(s).",
                payloadJSONRedacted: #"{"token":"\#(token)","count":\#(candidates.count)}"#
            )
        ])
    }

    private func renderDryRun(candidates: [CleanupCandidate], token: String) -> String {
        var lines = [
            "Hostwright cleanup (dry run)",
            "State DB: \(stateDatabasePath)",
            "Confirmation token: \(token)",
            ""
        ]
        if candidates.isEmpty {
            lines.append("- no cleanup-eligible Hostwright-owned stopped/created/exited containers")
        } else {
            lines += candidates.map { candidate in
                "- \(candidate.resourceIdentifier) service=\(candidate.identity.displayName) lifecycle=\(candidate.lifecycleState.rawValue)"
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func cleanupToken(for candidates: [CleanupCandidate]) -> String {
        let joined = candidates.map(\.resourceIdentifier).joined(separator: "|")
        return "cleanup-\(hostwrightStableHash(joined))"
    }

    private func failure(code: HostwrightErrorCode, message: String) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: code)
        return CLIRunResult(standardError: "\(code.rawValue): \(message)\n", exitCode: exitCode.rawValue)
    }
}

private struct CleanupCandidate: Equatable {
    let identity: RuntimeServiceIdentity
    let resourceIdentifier: String
    let lifecycleState: RuntimeLifecycleState
    let runtimeAdapter: String
}
