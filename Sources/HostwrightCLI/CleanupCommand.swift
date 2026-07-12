import HostwrightCore
import HostwrightManifest
import HostwrightPolicy
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
            let projectID = "project-\(mapping.desiredState.projectName)"
            let observationDesiredState = try hostwrightDesiredStateWithOwnershipHints(
                mapping.desiredState,
                store: store,
                projectID: projectID
            )

            let adapter = environment.runtimeAdapter()
            let observed: ObservedRuntimeState
            do {
                observed = try hostwrightWaitForAsync {
                    try await adapter.observe(desiredState: observationDesiredState)
                }
            } catch {
                return failure(code: .runtimeUnavailable, message: "Runtime observation failed: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))")
            }
            let assessments = try cleanupAssessments(
                store: store,
                projectName: mapping.desiredState.projectName,
                observed: observed
            )
            let candidates = assessments.compactMap(\.candidate)
            let token = cleanupToken(for: candidates)

            switch confirmation {
            case .dryRun:
                try recordCleanupPlanned(
                    store: store,
                    projectName: mapping.desiredState.projectName,
                    assessments: assessments,
                    token: token,
                    observed: observed
                )
                return CLIRunResult(standardOutput: renderDryRun(assessments: assessments, token: token))
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

    private func cleanupAssessments(store: SQLiteStateStore, projectName: String, observed: ObservedRuntimeState) throws -> [CleanupAssessment] {
        let projectID = "project-\(projectName)"
        var observedByIdentifier: [String: [ObservedRuntimeService]] = [:]
        for observedService in observed.services {
            observedByIdentifier[observedService.resourceIdentifier, default: []].append(observedService)
        }
        let observedAdapterName = observed.adapterMetadata?.adapterName

        let ownershipRecords = try store.ownership.loadAll()
        let ownershipIdentifiers = Set(ownershipRecords.map(\.resourceIdentifier))
        let ownershipAssessments = ownershipRecords
            .map { ownership in
                cleanupAssessment(
                    ownership: ownership,
                    projectID: projectID,
                    observedServices: observedByIdentifier[ownership.resourceIdentifier] ?? [],
                    observedAdapterName: observedAdapterName
                )
            }

        let observedOnlyAssessments = observedByIdentifier
            .filter { resourceIdentifier, _ in !ownershipIdentifiers.contains(resourceIdentifier) }
            .map { resourceIdentifier, services in
                observedOnlyAssessment(resourceIdentifier: resourceIdentifier, observedServices: services)
            }

        return (ownershipAssessments + observedOnlyAssessments)
            .sorted { lhs, rhs in
                if lhs.resourceIdentifier != rhs.resourceIdentifier {
                    return lhs.resourceIdentifier < rhs.resourceIdentifier
                }
                if lhs.classification.sortOrder != rhs.classification.sortOrder {
                    return lhs.classification.sortOrder < rhs.classification.sortOrder
                }
                return lhs.serviceName < rhs.serviceName
            }
    }

    private func cleanupAssessment(
        ownership: OwnershipRecord,
        projectID: String,
        observedServices: [ObservedRuntimeService],
        observedAdapterName: String?
    ) -> CleanupAssessment {
        let serviceName = ownership.serviceName ?? "unknown"
        let policyDecision = LocalPolicyEvaluator.default.evaluateCleanupOwnership(
            CleanupOwnershipPolicyInput(
                cleanupEligible: ownership.cleanupEligible,
                resourceType: ownership.resourceType,
                ownershipProjectID: ownership.projectID,
                expectedProjectID: projectID,
                resourceIdentifier: ownership.resourceIdentifier,
                serviceName: ownership.serviceName,
                ownershipRuntimeAdapter: ownership.runtimeAdapter,
                ownershipIdentityVersion: ownership.identityVersion,
                observedAdapterName: observedAdapterName,
                observedServices: observedServices
            )
        )
        let classification = CleanupClassification(policyDecision.classification)
        let observedService = observedServices.count == 1 ? observedServices.first : nil

        if classification == .eligible, let expectedServiceName = ownership.serviceName, let observedService {
            let candidate = CleanupCandidate(
                identity: observedService.identity,
                resourceIdentifier: ownership.resourceIdentifier,
                lifecycleState: observedService.lifecycleState,
                runtimeAdapter: ownership.runtimeAdapter
            )
            return CleanupAssessment(
                classification: .eligible,
                resourceIdentifier: ownership.resourceIdentifier,
                serviceName: expectedServiceName,
                lifecycleState: observedService.lifecycleState,
                reason: policyDecision.reason,
                candidate: candidate
            )
        }

        return CleanupAssessment(
            classification: classification,
            resourceIdentifier: ownership.resourceIdentifier,
            serviceName: serviceName,
            lifecycleState: observedService?.lifecycleState,
            reason: policyDecision.reason,
            candidate: nil
        )
    }

    private func observedOnlyAssessment(
        resourceIdentifier: String,
        observedServices: [ObservedRuntimeService]
    ) -> CleanupAssessment {
        let policyDecision = LocalPolicyEvaluator.default.evaluateObservedOnlyCleanup(
            resourceIdentifier: resourceIdentifier,
            observedServices: observedServices
        )
        let classification = CleanupClassification(policyDecision.classification)

        guard observedServices.count == 1, let observedService = observedServices.first else {
            return CleanupAssessment(
                classification: classification,
                resourceIdentifier: resourceIdentifier,
                serviceName: "unknown",
                lifecycleState: nil,
                reason: policyDecision.reason,
                candidate: nil
            )
        }

        return CleanupAssessment(
            classification: classification,
            resourceIdentifier: resourceIdentifier,
            serviceName: observedService.identity.serviceName,
            lifecycleState: observedService.lifecycleState,
            reason: policyDecision.reason,
            candidate: nil
        )
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
                            resourceIdentifier: candidate.resourceIdentifier,
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
                do {
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
                    let redactedPersistenceError = RuntimeRedactionPolicy.default.redact(String(describing: error))
                    lines.append("- deleted \(candidate.resourceIdentifier)")
                    lines.append("- state update failed \(candidate.resourceIdentifier): \(redactedPersistenceError)")
                    lines.append("")
                    return CLIRunResult(
                        standardOutput: lines.joined(separator: "\n"),
                        standardError: "\(HostwrightErrorCode.stateStoreUnavailable.rawValue): Cleanup deleted \(candidate.resourceIdentifier), but success state persistence failed: \(redactedPersistenceError)\n",
                        exitCode: CLIExitCode.stateUnavailable.rawValue
                    )
                }
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
        assessments: [CleanupAssessment],
        token: String,
        observed: ObservedRuntimeState
    ) throws {
        let timestamp = hostwrightTimestamp()
        let eligibleCount = assessments.filter { $0.classification == .eligible }.count
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
                message: "Cleanup planned \(eligibleCount) eligible Hostwright-owned container(s).",
                payloadJSONRedacted: #"{"token":"\#(token)","eligible":\#(eligibleCount),"total":\#(assessments.count)}"#
            )
        ])
    }

    private func renderDryRun(assessments: [CleanupAssessment], token: String) -> String {
        var lines = [
            "Hostwright cleanup (dry run)",
            "State DB: \(stateDatabasePath)",
            "Confirmation token: \(token)",
            ""
        ]
        if assessments.isEmpty {
            lines.append("- [blocked] no ownership records found for cleanup assessment")
        } else {
            lines += assessments.map { assessment in
                "- [\(assessment.classification.rawValue)] \(assessment.resourceIdentifier) service=\(assessment.serviceName) lifecycle=\(assessment.lifecycleText): \(assessment.reason)"
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func cleanupToken(for candidates: [CleanupCandidate]) -> String {
        let joined = candidates.map { candidate in
            [
                candidate.resourceIdentifier,
                candidate.identity.displayName,
                candidate.lifecycleState.rawValue,
                candidate.runtimeAdapter
            ].joined(separator: ":")
        }.joined(separator: "|")
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

private enum CleanupClassification: String, Equatable {
    case eligible
    case ambiguous
    case stale
    case running
    case unknown
    case blocked
    case neverDelete = "never-delete"

    var sortOrder: Int {
        switch self {
        case .eligible: 0
        case .ambiguous: 1
        case .stale: 2
        case .running: 3
        case .unknown: 4
        case .blocked: 5
        case .neverDelete: 6
        }
    }
}

private extension CleanupClassification {
    init(_ policyClassification: CleanupPolicyClassification) {
        switch policyClassification {
        case .eligible:
            self = .eligible
        case .ambiguous:
            self = .ambiguous
        case .stale:
            self = .stale
        case .running:
            self = .running
        case .unknown:
            self = .unknown
        case .blocked:
            self = .blocked
        case .neverDelete:
            self = .neverDelete
        }
    }
}

private struct CleanupAssessment: Equatable {
    let classification: CleanupClassification
    let resourceIdentifier: String
    let serviceName: String
    let lifecycleState: RuntimeLifecycleState?
    let reason: String
    let candidate: CleanupCandidate?

    var lifecycleText: String {
        lifecycleState?.rawValue ?? "unobserved"
    }
}
