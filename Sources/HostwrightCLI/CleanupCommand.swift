import HostwrightCore
import HostwrightManifest
import HostwrightPolicy
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

struct CleanupCommandRunner {
    let manifestPath: String
    let stateStoreConfiguration: StateStoreConfiguration
    let confirmation: CleanupConfirmation
    let teamProfilePath: String?
    let approvalRecordPath: String?
    let environment: CLIEnvironment

    init(
        manifestPath: String,
        stateStoreConfiguration: StateStoreConfiguration,
        confirmation: CleanupConfirmation,
        teamProfilePath: String? = nil,
        approvalRecordPath: String? = nil,
        environment: CLIEnvironment
    ) {
        self.manifestPath = manifestPath
        self.stateStoreConfiguration = stateStoreConfiguration
        self.confirmation = confirmation
        self.teamProfilePath = teamProfilePath
        self.approvalRecordPath = approvalRecordPath
        self.environment = environment
    }

    func run() -> CLIRunResult {
        if approvalRecordPath != nil, teamProfilePath == nil {
            return failure(
                code: .commandUsage,
                message: "Cleanup requires --team-profile when --approval-record is present. No file, state, or runtime operation was attempted."
            )
        }
        switch confirmation {
        case .dryRun where approvalRecordPath != nil:
            return failure(
                code: .commandUsage,
                message: "Cleanup dry-run does not accept an approval record. No file, state, or runtime operation was attempted."
            )
        case .confirmed where teamProfilePath != nil && approvalRecordPath == nil:
            return failure(
                code: .commandUsage,
                message: "Profile-aware confirmed cleanup requires --approval-record. No file, state, or runtime operation was attempted."
            )
        default:
            break
        }
        do {
            let manifestText = try hostwrightReadManifestText(path: manifestPath, environment: environment)
            let validatedManifest = try hostwrightValidatedManifest(
                text: manifestText,
                teamProfilePath: teamProfilePath,
                environment: environment
            )
            let mapping = ManifestRuntimeMapper.map(validatedManifest.manifest)
            let store = SQLiteStateStore(configuration: stateStoreConfiguration)
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
            let token = cleanupToken(for: candidates, validatedManifest: validatedManifest)
            let previewBinding = validatedManifest.previewBinding(planHash: token)

            switch confirmation {
            case .dryRun:
                try recordCleanupPlanned(
                    store: store,
                    projectName: mapping.desiredState.projectName,
                    assessments: assessments,
                    token: token,
                    observed: observed,
                    teamBinding: previewBinding
                )
                return CLIRunResult(
                    standardOutput: renderDryRun(assessments: assessments, token: token, teamBinding: previewBinding)
                )
            case .confirmed(let providedToken):
                guard providedToken == token else {
                    return failure(code: .confirmationMismatch, message: "cleanup confirmation token does not match current cleanup plan. Expected token: \(token)")
                }
                guard !candidates.isEmpty else {
                    return failure(code: .commandUsage, message: "cleanup has no eligible Hostwright-owned stopped/created/exited containers.")
                }
                let teamBinding: TeamWorkflowBinding?
                if validatedManifest.profileArtifact != nil {
                    guard let approvalRecordPath else {
                        return failure(
                            code: .teamApprovalInvalid,
                            message: "Profile-aware confirmed cleanup requires an explicit approval record. No mutation was attempted."
                        )
                    }
                    teamBinding = try hostwrightApprovedBinding(
                        approvalRecordPath: approvalRecordPath,
                        scope: .cleanup,
                        validatedManifest: validatedManifest,
                        planHash: token,
                        environment: environment
                    )
                } else {
                    teamBinding = nil
                }
                return try executeCleanup(
                    candidates: candidates,
                    token: token,
                    adapter: adapter,
                    observed: observed,
                    observationDesiredState: observationDesiredState,
                    store: store,
                    projectName: mapping.desiredState.projectName,
                    teamBinding: teamBinding
                )
            }
        } catch let error as HostwrightDiagnostic {
            return failure(code: error.code, message: error.message)
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
        let observedAdapterName = observed.adapterMetadata?.providerID.rawValue

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
                ownershipRuntimeAdapter: RuntimeProviderBinding.stableID(for: ownership.runtimeAdapter)?.rawValue
                    ?? ownership.runtimeAdapter,
                ownershipIdentityVersion: ownership.identityVersion,
                observedAdapterName: observedAdapterName,
                observedServices: observedServices
            )
        )
        let classification = CleanupClassification(policyDecision.classification)
        let observedService = observedServices.count == 1 ? observedServices.first : nil

        if classification == .eligible,
           let expectedServiceName = ownership.serviceName,
           let observedService,
           ownership.projectResourceUUID != nil {
            let candidate = CleanupCandidate(
                identity: observedService.identity,
                resourceIdentifier: ownership.resourceIdentifier,
                lifecycleState: observedService.lifecycleState,
                runtimeAdapter: ownership.runtimeAdapter,
                ownership: ownership
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

        if classification == .eligible, ownership.projectResourceUUID == nil {
            return CleanupAssessment(
                classification: .blocked,
                resourceIdentifier: ownership.resourceIdentifier,
                serviceName: serviceName,
                lifecycleState: observedService?.lifecycleState,
                reason: "Cleanup requires a project UUID binding in the ownership record.",
                candidate: nil
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
        observationDesiredState: DesiredRuntimeState,
        store: SQLiteStateStore,
        projectName: String,
        teamBinding: TeamWorkflowBinding?
    ) throws -> CLIRunResult {
        let timestamp = hostwrightTimestamp()
        let projectID = "project-\(projectName)"
        let runtimeAdapter = observed.adapterMetadata?.providerID.rawValue
        guard let providerID = observed.adapterMetadata?.providerID,
              let capabilitySHA256 = observed.capabilitySHA256,
              capabilitySHA256.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil else {
            return failure(
                code: .runtimeUnavailable,
                message: "Runtime observation did not include an immutable provider identity and capability digest. No cleanup mutation was attempted."
            )
        }
        var hadFailure = false
        var lines = [
            "Hostwright cleanup",
            "State DB: \(stateStoreConfiguration.databasePath)",
            "Confirmation token: \(token)",
            ""
        ]
        if let teamBinding {
            try store.events.append([
                EventRecord(
                    id: hostwrightUniqueID(prefix: "event-team-approval-recorded"),
                    timestamp: timestamp,
                    severity: .info,
                    type: "team.approval.recorded",
                    source: "hostwright-cli",
                    projectID: projectID,
                    serviceName: nil,
                    runtimeAdapter: runtimeAdapter,
                    message: "Local team approval \(teamBinding.approvalID ?? "unknown") recorded for cleanup.",
                    payloadJSONRedacted: jsonPayload(hostwrightTeamBindingPayload(teamBinding))
                )
            ])
            lines.insert("Approval hash: \(teamBinding.approvalHash ?? "")", at: 3)
            lines.insert("Manifest hash: \(teamBinding.manifestHash)", at: 3)
            lines.insert("Profile hash: \(teamBinding.profileHash)", at: 3)
        }

        for candidate in candidates {
            let idempotencyKey = "\(token):\(candidate.resourceIdentifier)"
            if let existingOperation = try store.operations.latest(idempotencyKey: idempotencyKey),
               existingOperation.status == .planned || existingOperation.status == .recorded || existingOperation.status == .succeeded {
                lines.append("- skipped \(candidate.resourceIdentifier): operation already \(existingOperation.status.rawValue)")
                continue
            }

            let operationID = hostwrightUniqueID(prefix: "operation-cleanup")
            let operationFencingToken = HostwrightResourceUUID.generate()
            var failureRecovery = "not-attempted"
            var failureRecoveryError: String?
            var successPayload: [String: Any] = ["result": "deleted"]
            var successEventPayload: [String: Any] = ["resourceIdentifier": candidate.resourceIdentifier]
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
                    payloadJSONRedacted: jsonPayload(
                        [
                            "fencingToken": operationFencingToken,
                            "resourceIdentifier": candidate.resourceIdentifier,
                            "resourceUUID": candidate.ownership.resourceUUID
                        ]
                            .merging(hostwrightTeamBindingPayload(teamBinding)) { current, _ in current }
                    )
                )
            )

            do {
                guard let projectResourceUUID = candidate.ownership.projectResourceUUID else {
                    throw StateStoreError.invalidRecord("Cleanup ownership lost its project UUID binding.")
                }
                guard try store.ownership.advanceFencingToken(
                    resourceIdentifier: candidate.resourceIdentifier,
                    runtimeAdapter: candidate.runtimeAdapter,
                    expectedResourceUUID: candidate.ownership.resourceUUID,
                    expectedFencingToken: candidate.ownership.fencingToken,
                    newFencingToken: operationFencingToken,
                    observedAt: timestamp
                ) != nil else {
                    throw StateStoreError.invalidRecord(
                        "Ownership fencing changed before cleanup execution; refusing stale deletion."
                    )
                }
                let context = RuntimeMutationContext(
                    providerID: providerID,
                    capabilitySHA256: capabilitySHA256,
                    operationID: operationID,
                    resourceUUID: candidate.ownership.resourceUUID,
                    resourceGeneration: candidate.ownership.resourceGeneration,
                    projectResourceUUID: projectResourceUUID,
                    projectGeneration: candidate.ownership.projectGeneration,
                    providerGeneration: candidate.ownership.providerGeneration,
                    fencingToken: candidate.ownership.fencingToken
                )
                if let issue = context.validationIssue {
                    throw StateStoreError.invalidRecord(issue)
                }
                let event: RuntimeEvent
                do {
                    event = try hostwrightWaitForAsync {
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
                                planHash: token,
                                manifestHash: teamBinding?.manifestHash,
                                profileHash: teamBinding?.profileHash,
                                approvalHash: teamBinding?.approvalHash,
                                context: context
                            )
                        )
                    }
                } catch {
                    let providerError = error
                    switch reobserveFailedDelete(
                        adapter: adapter,
                        desiredState: observationDesiredState,
                        candidate: candidate,
                        providerID: providerID,
                        capabilitySHA256: capabilitySHA256
                    ) {
                    case .resourceAbsent:
                        let redactedProviderError = RuntimeRedactionPolicy.default.redact(
                            String(describing: providerError)
                        )
                        successPayload = [
                            "providerError": redactedProviderError,
                            "recovery": "resource-absence-verified",
                            "result": "deleted-after-provider-error"
                        ]
                        successEventPayload = [
                            "providerError": redactedProviderError,
                            "recovery": "resource-absence-verified",
                            "resourceIdentifier": candidate.resourceIdentifier
                        ]
                        event = RuntimeEvent(
                            identity: candidate.identity,
                            severity: .warning,
                            message: "The runtime provider reported a cleanup failure, but exact structured re-observation verified the managed container is absent.",
                            resourceIdentifier: candidate.resourceIdentifier
                        )
                    case .resourcePresent:
                        do {
                            let restored = try store.ownership.advanceFencingToken(
                                resourceIdentifier: candidate.resourceIdentifier,
                                runtimeAdapter: candidate.runtimeAdapter,
                                expectedResourceUUID: candidate.ownership.resourceUUID,
                                expectedFencingToken: operationFencingToken,
                                newFencingToken: candidate.ownership.fencingToken,
                                observedAt: hostwrightTimestamp()
                            )
                            failureRecovery = restored == nil
                                ? "resource-present-fence-retained"
                                : "resource-present-fence-restored"
                        } catch {
                            failureRecovery = "resource-present-fence-retained"
                            failureRecoveryError = RuntimeRedactionPolicy.default.redact(
                                String(describing: error)
                            )
                        }
                        throw providerError
                    case .ambiguous:
                        failureRecovery = "reobservation-ambiguous-operation-fence-retained"
                        throw providerError
                    }
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
                            payloadJSONRedacted: jsonPayload(
                                successPayload.merging(hostwrightTeamBindingPayload(teamBinding)) { current, _ in current }
                            )
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
                            payloadJSONRedacted: jsonPayload(
                                successEventPayload
                                    .merging(hostwrightTeamBindingPayload(teamBinding)) { current, _ in current }
                            )
                        )
                    ])
                    try store.ownership.markCleanupCompleted(
                        resourceIdentifier: candidate.resourceIdentifier,
                        runtimeAdapter: candidate.runtimeAdapter,
                        observedAt: successTimestamp,
                        metadataJSONRedacted: jsonPayload(
                            ["cleanupToken": token, "cleanupStatus": "deleted"]
                                .merging(hostwrightTeamBindingPayload(teamBinding)) { current, _ in current }
                        )
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
                    var failurePayload: [String: Any] = [
                        "error": redactedError,
                        "fencingToken": operationFencingToken,
                        "priorFencingToken": candidate.ownership.fencingToken,
                        "recovery": failureRecovery
                    ]
                    if let failureRecoveryError {
                        failurePayload["recoveryError"] = failureRecoveryError
                    }
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
                            payloadJSONRedacted: jsonPayload(
                                failurePayload.merging(hostwrightTeamBindingPayload(teamBinding)) { current, _ in current }
                            )
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
                            payloadJSONRedacted: jsonPayload(
                                [
                                    "recovery": failureRecovery,
                                    "resourceIdentifier": candidate.resourceIdentifier
                                ]
                                    .merging(hostwrightTeamBindingPayload(teamBinding)) { current, _ in current }
                            )
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

    private enum FailedDeleteObservation {
        case resourcePresent
        case resourceAbsent
        case ambiguous
    }

    private func reobserveFailedDelete(
        adapter: any RuntimeAdapter,
        desiredState: DesiredRuntimeState,
        candidate: CleanupCandidate,
        providerID: RuntimeProviderID,
        capabilitySHA256: String
    ) -> FailedDeleteObservation {
        guard let projectResourceUUID = candidate.ownership.projectResourceUUID else {
            return .ambiguous
        }
        let expectedOwnership = RuntimeInventoryOwnershipEvidence(
            resourceUUID: candidate.ownership.resourceUUID,
            projectUUID: projectResourceUUID,
            resourceGeneration: candidate.ownership.resourceGeneration,
            projectGeneration: candidate.ownership.projectGeneration,
            providerID: providerID,
            providerGeneration: candidate.ownership.providerGeneration,
            fencingToken: candidate.ownership.fencingToken
        )
        let exactHints = desiredState.ownedResourceHints.filter {
            $0.resourceIdentifier == candidate.resourceIdentifier &&
                $0.identity == candidate.identity &&
                $0.identityVersion == candidate.ownership.identityVersion &&
                $0.ownership == expectedOwnership
        }
        guard exactHints.count == 1 else {
            return .ambiguous
        }

        let reobserved: ObservedRuntimeState
        do {
            reobserved = try hostwrightWaitForAsync {
                try await adapter.observe(desiredState: desiredState)
            }
        } catch {
            return .ambiguous
        }
        guard reobserved.adapterMetadata?.providerID == providerID,
              reobserved.capabilitySHA256 == capabilitySHA256 else {
            return .ambiguous
        }
        let matching = reobserved.services.filter {
            $0.identity == candidate.identity &&
                $0.resourceIdentifier == candidate.resourceIdentifier
        }
        guard matching.count <= 1 else {
            return .ambiguous
        }
        guard let service = matching.first else {
            return .resourceAbsent
        }
        return service.lifecycleState == .missing ? .resourceAbsent : .resourcePresent
    }

    private func recordCleanupPlanned(
        store: SQLiteStateStore,
        projectName: String,
        assessments: [CleanupAssessment],
        token: String,
        observed: ObservedRuntimeState,
        teamBinding: TeamWorkflowBinding?
    ) throws {
        let timestamp = hostwrightTimestamp()
        let eligibleCount = assessments.filter { $0.classification == .eligible }.count
        var events = [
            EventRecord(
                id: hostwrightUniqueID(prefix: "event-cleanup-planned"),
                timestamp: timestamp,
                severity: .info,
                type: "cleanup.planned",
                source: "hostwright-cli",
                projectID: "project-\(projectName)",
                serviceName: nil,
                runtimeAdapter: observed.adapterMetadata?.providerID.rawValue,
                message: "Cleanup planned \(eligibleCount) eligible Hostwright-owned container(s).",
                payloadJSONRedacted: jsonPayload(
                    ["token": token, "eligible": eligibleCount, "total": assessments.count]
                        .merging(hostwrightTeamBindingPayload(teamBinding)) { current, _ in current }
                )
            )
        ]
        if let teamBinding {
            events.append(
                EventRecord(
                    id: hostwrightUniqueID(prefix: "event-team-profile-selected"),
                    timestamp: timestamp,
                    severity: .info,
                    type: "team.profile.selected",
                    source: "hostwright-cli",
                    projectID: "project-\(projectName)",
                    serviceName: nil,
                    runtimeAdapter: observed.adapterMetadata?.providerID.rawValue,
                    message: "Local team profile \(teamBinding.profileIdentifier) selected for cleanup dry-run.",
                    payloadJSONRedacted: jsonPayload(hostwrightTeamBindingPayload(teamBinding))
                )
            )
        }
        try store.events.append(events)
    }

    private func renderDryRun(
        assessments: [CleanupAssessment],
        token: String,
        teamBinding: TeamWorkflowBinding?
    ) -> String {
        var lines = [
            "Hostwright cleanup (dry run)",
            "State DB: \(stateStoreConfiguration.databasePath)",
            "Confirmation token: \(token)",
            ""
        ]
        if let teamBinding {
            lines.insert("Approval required for confirmed cleanup: yes", at: 3)
            lines.insert("Manifest hash: \(teamBinding.manifestHash)", at: 3)
            lines.insert("Profile hash: \(teamBinding.profileHash)", at: 3)
        }
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

    private func cleanupToken(for candidates: [CleanupCandidate], validatedManifest: TeamValidatedManifest) -> String {
        let joined = candidates.map { candidate in
            [
                candidate.resourceIdentifier,
                candidate.identity.displayName,
                candidate.lifecycleState.rawValue,
                candidate.runtimeAdapter
            ].joined(separator: ":")
        }.joined(separator: "|")
        let baseToken = "cleanup-\(hostwrightStableHash(joined))"
        guard let profileHash = validatedManifest.profileHash,
              let manifestHash = validatedManifest.manifestHash
        else {
            return baseToken
        }
        return "cleanup-\(hostwrightStableHash("\(baseToken)|\(profileHash)|\(manifestHash)"))"
    }

    private func failure(code: HostwrightErrorCode, message: String) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: code)
        let redactedMessage = RuntimeRedactionPolicy.default.redact(message)
        return CLIRunResult(standardError: "\(code.rawValue): \(redactedMessage)\n", exitCode: exitCode.rawValue)
    }
}

private struct CleanupCandidate: Equatable {
    let identity: RuntimeServiceIdentity
    let resourceIdentifier: String
    let lifecycleState: RuntimeLifecycleState
    let runtimeAdapter: String
    let ownership: OwnershipRecord
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
