import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightPolicy
import HostwrightReconciler
import HostwrightRuntime
import HostwrightSecrets
import HostwrightState

struct ApplyCommandRunner {
    static let preRuntimeStateIncompleteCheckpoint = "pre-runtime-state-incomplete"

    let manifestPath: String
    let stateStoreConfiguration: StateStoreConfiguration
    let confirmedPlanHash: String
    let teamProfilePath: String?
    let approvalRecordPath: String?
    let runtimeProvider: RuntimeProviderSelection
    let environment: CLIEnvironment

    init(
        manifestPath: String,
        stateStoreConfiguration: StateStoreConfiguration,
        confirmedPlanHash: String,
        teamProfilePath: String? = nil,
        approvalRecordPath: String? = nil,
        runtimeProvider: RuntimeProviderSelection = .automatic,
        environment: CLIEnvironment
    ) {
        self.manifestPath = manifestPath
        self.stateStoreConfiguration = stateStoreConfiguration
        self.confirmedPlanHash = confirmedPlanHash
        self.teamProfilePath = teamProfilePath
        self.approvalRecordPath = approvalRecordPath
        self.runtimeProvider = runtimeProvider
        self.environment = environment
    }

    func run() -> CLIRunResult {
        guard (teamProfilePath == nil) == (approvalRecordPath == nil) else {
            return failure(
                code: .commandUsage,
                message: "Profile-aware apply requires both --team-profile and --approval-record. No file, state, or runtime operation was attempted."
            )
        }
        do {
            let manifestText = try hostwrightReadManifestText(path: manifestPath, environment: environment)
            let validatedManifest = try hostwrightValidatedManifest(
                text: manifestText,
                teamProfilePath: teamProfilePath,
                environment: environment
            )
            let manifest = validatedManifest.manifest
            let mapping = ManifestRuntimeMapper.map(manifest)
            let store = SQLiteStateStore(configuration: stateStoreConfiguration)
            try store.migrate()
            let timestamp = hostwrightTimestamp()
            let projectName = mapping.desiredState.projectName
            let projectID = "project-\(projectName)"
            let selectedProvider: HostwrightSelectedRuntimeProvider
            do {
                selectedProvider = try hostwrightSelectRuntimeProvider(
                    requested: runtimeProvider,
                    store: store,
                    projectID: projectID,
                    requiredFeatures: [.observation, .lifecycle],
                    environment: environment
                )
            } catch let selectionError as RuntimeProviderSelectionError {
                return failure(
                    code: .runtimeUnavailable,
                    message: "Runtime provider selection failed: \(selectionError). \(selectionError.guidance) No mutation was attempted."
                )
            }
            let observationDesiredState = try hostwrightDesiredStateWithOwnershipHints(
                mapping.desiredState,
                store: store,
                projectID: projectID,
                providerID: selectedProvider.selection.providerID
            )
            let restartPolicyStates = try hostwrightRestartPolicyStateMap(store: store, projectID: projectID, projectName: projectName)
            let adapter = selectedProvider.adapter
            let observed: ObservedRuntimeState
            do {
                observed = try waitForAsync {
                    try await adapter.observe(desiredState: observationDesiredState)
                }
            } catch {
                return failure(code: .runtimeUnavailable, message: "Runtime observation failed: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))")
            }
            let observedForPlanning = try hostwrightPlanningObservedState(
                observed: observed,
                desiredState: mapping.desiredState,
                store: store,
                projectID: projectID,
                currentTimestamp: timestamp
            )
            guard let observedMetadata = observedForPlanning.adapterMetadata else {
                return failure(
                    code: .runtimeUnavailable,
                    message: "Runtime observation did not include adapter metadata. No mutation was attempted."
                )
            }
            guard observedMetadata.providerID == selectedProvider.selection.providerID,
                  observedForPlanning.capabilitySHA256 == selectedProvider.selection.capabilitySHA256 else {
                return failure(
                    code: .runtimeUnavailable,
                    message: "Runtime provider capability changed during observation. Generate a new plan from a fresh capability snapshot. No mutation was attempted."
                )
            }
            if let incompatibility = RuntimeProviderCompatibility.mutationIncompatibility(observedMetadata) {
                return failure(
                    code: .runtimeUnavailable,
                    message: "\(incompatibility) No mutation was attempted."
                )
            }
            let observedRuntimeAdapter = observedMetadata.providerID.rawValue
            guard let capabilitySHA256 = observedForPlanning.capabilitySHA256,
                  capabilitySHA256.range(
                      of: "^[a-f0-9]{64}$",
                      options: .regularExpression
                  ) != nil else {
                return failure(
                    code: .runtimeUnavailable,
                    message: "Runtime observation did not include a valid immutable capability digest. No mutation was attempted."
                )
            }
            let plan = ReconciliationPlanner().plan(
                manifest: manifest,
                observedState: observedForPlanning,
                restartPolicyStates: restartPolicyStates,
                currentTimestamp: timestamp
            )

            guard plan.planHash == confirmedPlanHash else {
                return failure(
                    code: .confirmationMismatch,
                    message: "Confirmed plan hash does not match current observed plan. expected=\(plan.planHash) provided=\(confirmedPlanHash)\n\n\(PlanRenderer.render(plan))"
                )
            }

            guard !plan.includesBlockers else {
                return failure(
                    code: .unsafeExposure,
                    message: "Current plan has blocker issues. No mutation was attempted.\n\n\(PlanRenderer.render(plan))"
                )
            }

            let teamBinding: TeamWorkflowBinding?
            if validatedManifest.profileArtifact != nil {
                guard let approvalRecordPath else {
                    return failure(
                        code: .teamApprovalInvalid,
                        message: "Profile-aware apply requires an explicit approval record. No mutation was attempted."
                    )
                }
                teamBinding = try hostwrightApprovedBinding(
                    approvalRecordPath: approvalRecordPath,
                    scope: .apply,
                    validatedManifest: validatedManifest,
                    planHash: plan.planHash,
                    environment: environment
                )
            } else {
                teamBinding = nil
            }

            let executableActions = plan.actions.filter {
                $0.executionAvailability == .availableForCreateMissingService ||
                $0.executionAvailability == .availableForStartManagedService ||
                $0.executionAvailability == .availableForRestartManagedService
            }
            guard !executableActions.isEmpty else {
                return failure(
                    code: .runtimeMutationNotImplemented,
                    message: "No executable createMissingService, startManagedService, or restartManagedService action exists in the current plan. No mutation was attempted.\n\n\(PlanRenderer.render(plan))"
                )
            }
            guard executableActions.count == 1, let action = executableActions.first else {
                return failure(
                    code: .commandUsage,
                    message: "Apply supports exactly one executable action. Current executable action count: \(executableActions.count). No mutation was attempted.\n\n\(PlanRenderer.render(plan))"
                )
            }

            let desiredByIdentity = Dictionary(uniqueKeysWithValues: mapping.desiredState.services.map { ($0.identity, $0) })
            let desiredService = desiredByIdentity[action.identity]
            guard let desiredService else {
                return failure(code: .runtimeMutationNotImplemented, message: "Could not find desired service for \(action.identity.displayName). No mutation was attempted.")
            }

            let idempotencyKey = "\(plan.planHash):\(action.kind.rawValue):\(action.identity.displayName)"
            if let existingOperation = try blockingOperation(store: store, idempotencyKey: idempotencyKey) {
                if let existingGroup = try store.operationGroups.latest(groupIdempotencyKey: idempotencyKey),
                   existingGroup.status == .active {
                    return failure(
                        code: .commandUsage,
                        message: activeOperationConflictMessage(existingGroup, hasRecordedIntent: true)
                    )
                }
                return failure(
                    code: .commandUsage,
                    message: "Operation with the same idempotency key is already \(existingOperation.status.rawValue). No mutation was attempted."
                )
            }

            let executionDesiredService: DesiredRuntimeService
            if action.executionAvailability == .availableForCreateMissingService {
                do {
                    executionDesiredService = try resolveSecretReferences(in: desiredService)
                } catch {
                    return failure(
                        code: .unsafeExposure,
                        message: "Secret reference resolution failed before mutation: \(RuntimeRedactionPolicy.default.redact(String(describing: error))). No mutation was attempted."
                    )
                }
                if let safeSubsetFailure = validateCreateOnlyApplySubset(executionDesiredService) {
                    return failure(code: .unsafeExposure, message: "\(safeSubsetFailure) No mutation was attempted.")
                }
            } else {
                executionDesiredService = desiredService
            }
            if action.executionAvailability == .availableForStartManagedService ||
                action.executionAvailability == .availableForRestartManagedService {
                if let ownershipGateFailure = try validateManagedOwnershipGate(
                    action: action,
                    observed: observedForPlanning,
                    store: store,
                    projectID: projectID,
                    runtimeAdapter: observedRuntimeAdapter
                ) {
                    return failure(code: .unsafeExposure, message: "\(ownershipGateFailure) No mutation was attempted.")
                }
            }
            if action.executionAvailability == .availableForRestartManagedService {
                if let restartGateFailure = try validateManagedRestartGate(
                    action: action,
                    desiredService: executionDesiredService,
                    observed: observedForPlanning,
                    store: store,
                    projectID: projectID,
                    currentTimestamp: timestamp
                ) {
                    return failure(code: .unsafeExposure, message: "\(restartGateFailure) No mutation was attempted.")
                }
            }

            do {
                let freshCapability = try waitForAsync {
                    try await adapter.capabilitySnapshot()
                }
                guard freshCapability.descriptor.providerID == observedMetadata.providerID else {
                    return failure(
                        code: .runtimeUnavailable,
                        message: "The runtime provider identity changed after planning. No state or runtime mutation was attempted."
                    )
                }
                try RuntimeProviderSelector.requireFreshCapability(
                    expectedSHA256: capabilitySHA256,
                    currentSnapshot: freshCapability
                )
            } catch {
                return failure(
                    code: .runtimeUnavailable,
                    message: "Runtime capability revalidation failed before mutation: \(RuntimeRedactionPolicy.default.redact(String(describing: error))). No state or runtime mutation was attempted."
                )
            }

            let operationID = hostwrightUniqueID(prefix: "operation-apply")
            let operationGroupID = hostwrightUniqueID(prefix: "operation-group")
            let operationFencingToken = HostwrightResourceUUID.generate()
            let existingOwnership = try store.ownership.loadAll().first { record in
                record.resourceIdentifier == action.resourceIdentifier &&
                RuntimeProviderBinding.stableID(for: record.runtimeAdapter) == observedMetadata.providerID &&
                record.projectID == projectID &&
                record.serviceName == action.identity.serviceName
            }
            let mutationContext = RuntimeMutationContext(
                providerID: observedMetadata.providerID,
                capabilitySHA256: capabilitySHA256,
                operationID: operationID,
                resourceUUID: existingOwnership?.resourceUUID ?? HostwrightResourceUUID.legacy(
                    kind: "service", identifier: "\(projectID):\(action.identity.serviceName)"
                ),
                resourceGeneration: existingOwnership?.resourceGeneration ?? 1,
                projectResourceUUID: existingOwnership?.projectResourceUUID ?? HostwrightResourceUUID.legacy(
                    kind: "project", identifier: projectID
                ),
                projectGeneration: existingOwnership?.projectGeneration ?? 1,
                providerGeneration: existingOwnership?.providerGeneration ?? 1,
                fencingToken: existingOwnership?.fencingToken ?? operationFencingToken
            )
            if let issue = mutationContext.validationIssue {
                return failure(code: .stateStoreUnavailable, message: "\(issue) No mutation was attempted.")
            }
            let preparedOperationGroup = operationGroup(
                id: operationGroupID,
                operationID: operationID,
                action: action,
                idempotencyKey: idempotencyKey,
                planHash: plan.planHash,
                projectID: projectID,
                timestamp: timestamp,
                status: .active,
                checkpoint: "prepared",
                lockOwner: "hostwright-cli:\(operationID)",
                lockExpiresAt: hostwrightTimestampAdding(seconds: 600, to: timestamp),
                manualRecoveryHint: manualRecoveryHint(
                    status: .active,
                    checkpoint: "prepared",
                    action: action
                ),
                runtimeAdapter: observedRuntimeAdapter,
                mutationContext: mutationContext,
                operationFencingToken: operationFencingToken
            )
            let groupAcquire = try store.operationGroups.acquire(
                preparedOperationGroup
            )
            if let existing = groupAcquire.existingActive {
                return failure(
                    code: .commandUsage,
                    message: activeOperationConflictMessage(existing, hasRecordedIntent: false)
                )
            }
            guard let acquiredGroup = groupAcquire.acquired else {
                return failure(
                    code: .stateStoreUnavailable,
                    message: "Operation group acquisition returned neither an acquired nor an existing group. No mutation was attempted."
                )
            }
            guard acquiredGroup.fencingToken == operationFencingToken else {
                try? finishOperationGroup(
                    store: store,
                    groupID: operationGroupID,
                    status: .interrupted,
                    checkpoint: Self.preRuntimeStateIncompleteCheckpoint,
                    action: action,
                    timestamp: timestamp,
                    metadata: ["error": "operation fencing mismatch", "runtimeMutation": "not-attempted"]
                )
                return failure(
                    code: .stateStoreUnavailable,
                    message: "Acquired operation fencing did not match the prepared mutation context. No mutation was attempted."
                )
            }
            var ownershipFenceAdvanced = false
            do {
                try recordRollbackUnsupportedStep(
                    store: store,
                    groupID: operationGroupID,
                    action: action,
                    idempotencyKey: idempotencyKey,
                    timestamp: timestamp
                )

                try persistPreMutationState(
                    store: store,
                    manifest: manifest,
                    manifestText: manifestText,
                    observed: observedForPlanning,
                    plan: plan,
                    action: action,
                    operationID: operationID,
                    idempotencyKey: idempotencyKey,
                    projectID: projectID,
                    timestamp: timestamp,
                    runtimeAdapter: observedRuntimeAdapter,
                    teamBinding: teamBinding,
                    mutationContext: mutationContext
                )
                if let existingOwnership {
                    guard try store.ownership.advanceFencingToken(
                        resourceIdentifier: existingOwnership.resourceIdentifier,
                        runtimeAdapter: existingOwnership.runtimeAdapter,
                        expectedResourceUUID: existingOwnership.resourceUUID,
                        expectedFencingToken: existingOwnership.fencingToken,
                        newFencingToken: operationFencingToken,
                        observedAt: timestamp
                    ) != nil else {
                        throw StateStoreError.invalidRecord(
                            "Ownership fencing changed before runtime execution; refusing stale mutation."
                        )
                    }
                    ownershipFenceAdvanced = true
                }
                try recordOperationGroupStep(
                    store: store,
                    groupID: operationGroupID,
                    action: action,
                    stepKey: "runtime-execute",
                    direction: .forward,
                    status: .started,
                    idempotencyKey: idempotencyKey,
                    timestamp: timestamp,
                    resourceIdentifier: action.resourceIdentifier,
                    error: nil,
                    hint: "Runtime mutation started for \(action.identity.displayName). If this process is interrupted, inspect the exact runtime resource and rerun apply only after confirming the current plan."
                )
            } catch {
                if ownershipFenceAdvanced, let existingOwnership {
                    _ = try? store.ownership.advanceFencingToken(
                        resourceIdentifier: existingOwnership.resourceIdentifier,
                        runtimeAdapter: existingOwnership.runtimeAdapter,
                        expectedResourceUUID: existingOwnership.resourceUUID,
                        expectedFencingToken: operationFencingToken,
                        newFencingToken: existingOwnership.fencingToken,
                        observedAt: timestamp
                    )
                }
                try? finishOperationGroup(
                    store: store,
                    groupID: operationGroupID,
                    status: .interrupted,
                    checkpoint: Self.preRuntimeStateIncompleteCheckpoint,
                    action: action,
                    timestamp: timestamp,
                    metadata: [
                        "error": RuntimeRedactionPolicy.default.redact(String(describing: error)),
                        "runtimeMutation": "not-attempted",
                        "rollback": "unsupported"
                    ]
                )
                return failure(
                    code: .stateStoreUnavailable,
                    message: "Apply operation group was recorded, but pre-runtime state persistence failed before mutation: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))"
                )
            }

            let runtimeAction = runtimeAction(for: action, desiredService: executionDesiredService)

            let event: RuntimeEvent
            do {
                event = try waitForAsync {
                    try await adapter.execute(
                        runtimeAction,
                        confirmation: RuntimeMutationConfirmation(
                            confirmed: true,
                            reason: "Confirmed Hostwright plan \(plan.planHash)",
                            planHash: plan.planHash,
                            manifestHash: teamBinding?.manifestHash,
                            profileHash: teamBinding?.profileHash,
                            approvalHash: teamBinding?.approvalHash,
                            context: mutationContext
                        )
                    )
                }
            } catch {
                let runtimeErrorDescription = RuntimeRedactionPolicy.default.redact(String(describing: error))
                let normalizedFailure = normalizedRuntimeFailure(
                    error,
                    metadata: observedMetadata,
                    operationID: operationID
                )
                let reobservation = reobserveUncertainMutation(
                    adapter: adapter,
                    action: action,
                    desiredState: observationDesiredState,
                    providerID: observedMetadata.providerID,
                    capabilitySHA256: capabilitySHA256,
                    failure: normalizedFailure
                )
                if let recoveredEvent = reobservation.recoveredEvent {
                    event = recoveredEvent
                } else {
                    if reobservation.provedNoEffect,
                       ownershipFenceAdvanced,
                       let existingOwnership {
                        _ = try? store.ownership.advanceFencingToken(
                            resourceIdentifier: existingOwnership.resourceIdentifier,
                            runtimeAdapter: existingOwnership.runtimeAdapter,
                            expectedResourceUUID: existingOwnership.resourceUUID,
                            expectedFencingToken: operationFencingToken,
                            newFencingToken: existingOwnership.fencingToken,
                            observedAt: timestamp
                        )
                    }
                    do {
                    if restartStopSucceededBeforeFailure(error) {
                        try recordOperationGroupStep(
                            store: store,
                            groupID: operationGroupID,
                            action: action,
                            stepKey: "restart-stop",
                            direction: .forward,
                            status: .succeeded,
                            idempotencyKey: idempotencyKey,
                            timestamp: timestamp,
                            resourceIdentifier: action.resourceIdentifier,
                            error: nil,
                            hint: "Managed restart stop completed for \(action.identity.displayName); start did not complete."
                        )
                        try recordRestartRecoveryIfNeeded(
                            store: store,
                            action: action,
                            operationID: operationID,
                            planHash: plan.planHash,
                            projectID: projectID,
                            timestamp: timestamp,
                            status: .stopSucceeded
                        )
                    }
                    try recordOperationGroupStep(
                        store: store,
                        groupID: operationGroupID,
                        action: action,
                        stepKey: "runtime-execute",
                        direction: .forward,
                        status: .failed,
                        idempotencyKey: idempotencyKey,
                        timestamp: timestamp,
                        resourceIdentifier: action.resourceIdentifier,
                        error: runtimeErrorDescription,
                        hint: manualRecoveryHint(status: .failed, checkpoint: "runtime-failed", action: action)
                    )
                    try persistFailure(
                        store: store,
                        error: error,
                        action: action,
                        operationID: operationID,
                        idempotencyKey: idempotencyKey,
                        planHash: plan.planHash,
                        projectID: projectID,
                        timestamp: timestamp,
                        teamBinding: teamBinding,
                        capabilitySHA256: capabilitySHA256,
                        normalizedFailure: normalizedFailure
                    )
                    try recordManagedStartAttempt(
                        store: store,
                        action: action,
                        desiredService: desiredService,
                        projectID: projectID,
                        timestamp: timestamp,
                        outcome: "failed"
                    )
                    try finishOperationGroup(
                        store: store,
                        groupID: operationGroupID,
                        status: .failed,
                        checkpoint: "runtime-failed",
                        action: action,
                        timestamp: timestamp,
                        metadata: [
                            "category": normalizedFailure.category.rawValue,
                            "error": runtimeErrorDescription,
                            "recoveryDisposition": normalizedFailure.recoveryDisposition.rawValue,
                            "retryDisposition": normalizedFailure.retryDisposition.rawValue,
                            "rollback": "unsupported"
                        ]
                    )
                    } catch {
                        try? finishOperationGroup(
                            store: store,
                            groupID: operationGroupID,
                            status: .failed,
                            checkpoint: "runtime-failed",
                            action: action,
                            timestamp: timestamp,
                            metadata: [
                                "category": normalizedFailure.category.rawValue,
                                "error": runtimeErrorDescription,
                                "persistenceError": RuntimeRedactionPolicy.default.redact(String(describing: error)),
                                "rollback": "unsupported"
                            ]
                        )
                        return failure(
                            code: .runtimeUnavailable,
                            message: "Runtime mutation failed after operation intent was recorded: \(runtimeErrorDescription). Failure state persistence also failed: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))"
                        )
                    }
                    return failure(
                        code: .runtimeUnavailable,
                        message: "Runtime mutation failed after operation intent was recorded: \(runtimeErrorDescription)"
                    )
                }
            }

            do {
                try recordOperationGroupStep(
                    store: store,
                    groupID: operationGroupID,
                    action: action,
                    stepKey: "runtime-execute",
                    direction: .forward,
                    status: .succeeded,
                    idempotencyKey: idempotencyKey,
                    timestamp: timestamp,
                    resourceIdentifier: event.resourceIdentifier ?? action.resourceIdentifier,
                    error: nil,
                    hint: "Runtime mutation completed for \(action.identity.displayName)."
                )
                try persistSuccess(
                    store: store,
                    event: event,
                    action: action,
                    operationID: operationID,
                    idempotencyKey: idempotencyKey,
                    planHash: plan.planHash,
                    projectID: projectID,
                    timestamp: timestamp,
                    runtimeAdapter: observedRuntimeAdapter,
                    teamBinding: teamBinding,
                    mutationContext: mutationContext
                )
                if ownershipFenceAdvanced, let existingOwnership {
                    guard try store.ownership.advanceFencingToken(
                        resourceIdentifier: existingOwnership.resourceIdentifier,
                        runtimeAdapter: existingOwnership.runtimeAdapter,
                        expectedResourceUUID: existingOwnership.resourceUUID,
                        expectedFencingToken: operationFencingToken,
                        newFencingToken: existingOwnership.fencingToken,
                        observedAt: timestamp
                    ) != nil else {
                        throw StateStoreError.invalidRecord(
                            "Runtime mutation succeeded, but the operation fence could not be released back to the verified resource fence."
                        )
                    }
                }
                try recordManagedStartAttempt(
                    store: store,
                    action: action,
                    desiredService: desiredService,
                    projectID: projectID,
                    timestamp: timestamp,
                    outcome: "succeeded"
                )
                try finishOperationGroup(
                    store: store,
                    groupID: operationGroupID,
                    status: .succeeded,
                    checkpoint: "completed",
                    action: action,
                    timestamp: timestamp,
                    metadata: [
                        "rollback": "unsupported",
                        "runtimeEventSeverity": event.severity.rawValue
                    ]
                )

                let teamOutput = teamBinding.map { binding in
                    "Profile hash: \(binding.profileHash)\nManifest hash: \(binding.manifestHash)\nApproval hash: \(binding.approvalHash ?? "")\n"
                } ?? ""
                return CLIRunResult(
                    standardOutput: """
                    Hostwright apply
                    Plan hash: \(plan.planHash)
                    Applied action: \(action.kind.rawValue) \(action.identity.displayName)
                    Resource: \(action.resourceIdentifier)
                    Runtime event: \(RuntimeRedactionPolicy.default.redact(event.message))
                    State DB: \(stateStoreConfiguration.databasePath)
                    """ + teamOutput + "\n"
                )
            } catch {
                try? finishOperationGroup(
                    store: store,
                    groupID: operationGroupID,
                    status: .interrupted,
                    checkpoint: "runtime-finished-state-incomplete",
                    action: action,
                    timestamp: timestamp,
                    metadata: [
                        "error": RuntimeRedactionPolicy.default.redact(String(describing: error)),
                        "rollback": "unsupported"
                    ]
                )
                return failure(
                    code: .stateStoreUnavailable,
                    message: "Runtime mutation succeeded but success state persistence failed: \(RuntimeRedactionPolicy.default.redact(String(describing: error)))"
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
}
