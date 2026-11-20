import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightNetworking
import HostwrightObservability
import HostwrightPolicy
import HostwrightReconciler
import HostwrightRegistry
import HostwrightRuntime
import HostwrightSecrets
import HostwrightState
import HostwrightStorage

extension LifecycleLiveEffects {
    func verifyCompensation(
        plan: LifecyclePlan,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaCompensationVerification {
        let verification = await verifyRestoredRevision(plan: plan, context: context)
        guard case .verified = verification else { return verification }
        do {
            try await LifecycleOwnershipFinalizer(store: store, adapter: adapter)
                .finalize(context: context)
            return verification
        } catch {
            return .safeHold(
                reasonCode: LifecycleRecoverySafeHoldReason.compensationFailed.rawValue,
                hintRedacted: "Compensated ownership cleanup could not be verified: " +
                    RuntimeRedactionPolicy.default.redact(String(describing: error))
            )
        }
    }

    private func verifyRestoredRevision(
        plan: LifecyclePlan,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaCompensationVerification {
        guard plan.command == .update else {
            return .verified(
                LifecycleNodeVerification(
                    summaryRedacted: "No update revision restoration was required."
                )
            )
        }
        let priorNodes = plan.nodes.filter { $0.action == .retire }
            .sorted { $0.key < $1.key }
        guard !priorNodes.isEmpty else {
            return .verified(
                LifecycleNodeVerification(
                    summaryRedacted: "The update had no prior revision to restore."
                )
            )
        }
        do {
            let capability = try await adapter.capabilitySnapshot()
            guard capability.descriptor.providerID == plan.providerID,
                  capability.canonicalSHA256 == plan.capabilitySHA256 else {
                throw LifecycleSpecialExecutionError.staleCapability
            }
            var finalVerification = LifecycleNodeVerification(
                summaryRedacted: "Exact prior revisions were restored and verified healthy."
            )
            for prior in priorNodes {
                let desired = try LifecycleRevisionCodec
                    .decodeRedactedDesiredJSON(
                        prior.desiredSpecificationJSONRedacted
                    )
                let revisionSHA256 = try LifecycleRevisionCodec
                    .revisionSHA256(for: desired)
                guard prior.preconditions.contains(where: {
                    $0.kind == "old-revision-verified-healthy" &&
                        $0.expectedValue == revisionSHA256
                }) else {
                    throw StateStoreError.invalidRecord(
                        "The compensated update lacks exact prior healthy-revision proof."
                    )
                }
                let allRecords = try store.ownership.loadAll()
                let records = allRecords.filter { record in
                    record.resourceUUID == prior.resourceUUID &&
                        record.resourceIdentifier == prior.resourceIdentifier &&
                        record.resourceGeneration == prior.resourceGeneration &&
                        record.projectResourceUUID == plan.projectResourceUUID &&
                        record.projectGeneration == plan.projectGeneration &&
                        record.providerGeneration == plan.providerGeneration &&
                        RuntimeProviderBinding.stableID(for: record.runtimeAdapter) ==
                            plan.providerID
                }
                guard records.count == 1,
                      let binding = await state.binding(
                          resourceUUID: prior.resourceUUID,
                          resourceIdentifier: prior.resourceIdentifier
                      ),
                      binding.resourceUUID == prior.resourceUUID,
                      binding.resourceGeneration == prior.resourceGeneration else {
                    throw StateStoreError.invalidRecord(
                        "The compensated update lacks one exact restored ownership binding."
                    )
                }
                let checks = restoredHealthChecks(for: desired)
                var finalNode: LifecyclePlanNode?
                for check in checks {
                    let key = String(
                        "rollback-verify-\(prior.key)-\(check.suffix)".prefix(127)
                    )
                    let verificationNode = try LifecyclePlanNode(
                        key: key,
                        action: .verify,
                        serviceName: prior.serviceName,
                        resourceIdentifier: prior.resourceIdentifier,
                        resourceUUID: prior.resourceUUID,
                        resourceGeneration: prior.resourceGeneration,
                        fencingToken: context.fencingToken,
                        dependencies: [],
                        preconditions: [
                            LifecyclePlanCondition(
                                kind: "rollback-restored-revision",
                                subject: desired.identity.displayName,
                                expectedValue: revisionSHA256
                            )
                        ],
                        postconditions: [check.condition],
                        timeoutSeconds: prior.timeoutSeconds,
                        compensation: nil,
                        desiredSpecificationJSONRedacted:
                            prior.desiredSpecificationJSONRedacted
                    )
                    await state.setDesiredService(desired, for: key)
                    guard case .accepted = await apply(
                        node: verificationNode,
                        context: context
                    ) else {
                        throw StateStoreError.invalidRecord(
                            "A restored revision did not pass its bounded \(check.suffix) health check."
                        )
                    }
                    guard case .satisfied(let verification) = await observe(
                        node: verificationNode,
                        context: context
                    ) else {
                        throw StateStoreError.invalidRecord(
                            "A restored revision lacks exact structured \(check.suffix) health proof."
                        )
                    }
                    finalVerification = verification
                    finalNode = verificationNode
                }
                guard let finalNode else {
                    throw StateStoreError.invalidRecord(
                        "Restored revision verification produced no health check."
                    )
                }
                try await markHealthyRevision(
                    node: finalNode,
                    context: context,
                    identity: desired.identity,
                    observedAt: hostwrightTimestamp(),
                    desiredService: desired
                )
            }
            return .verified(finalVerification)
        } catch {
            let diagnostic = RuntimeRedactionPolicy.default.redact(
                String(describing: error)
            )
            return .safeHold(
                reasonCode:
                    LifecycleRecoverySafeHoldReason.restoredHealthFailed.rawValue,
                hintRedacted:
                    "Restored revision health could not be proven: \(diagnostic) " +
                    "Inspect with `hostwright recovery --output json`; retry only the exact group " +
                    "with `hostwright recovery rollback --group \(context.groupID) " +
                    "--confirm-plan \(plan.planSHA256)`."
            )
        }
    }

    private func restoredHealthChecks(
        for desired: DesiredRuntimeService
    ) -> [(suffix: String, condition: LifecyclePlanCondition)] {
        if desired.probes.configuredKinds.isEmpty {
            return [
                (
                    "running",
                    LifecyclePlanCondition(
                        kind: "lifecycle",
                        subject: desired.identity.displayName,
                        expectedValue: RuntimeLifecycleState.running.rawValue
                    )
                )
            ]
        }
        return desired.probes.configuredKinds.map { kind in
            let expected: String
            switch kind {
            case .startup: expected = "succeeded"
            case .readiness: expected = "ready"
            case .liveness: expected = "healthy"
            }
            return (
                kind.rawValue,
                LifecyclePlanCondition(
                    kind: "probe-\(kind.rawValue)",
                    subject: desired.identity.displayName,
                    expectedValue: expected
                )
            )
        }
    }

    func compensate(
        compensation: LifecycleCompensation,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaCompensationOutcome {
        if compensation.action == .create,
           let desired = await state.desiredService(for: node.key),
           desired.environment.contains(where: {
               $0.isSensitive && $0.secretReference == nil
           }) {
            return .failed(
                RuntimeNormalizedFailure(
                    category: .ambiguousEffect,
                    retryDisposition: .never,
                    recoveryDisposition: .none,
                    providerID: context.plan.providerID.rawValue,
                    providerVersion:
                        "bound-generation-\(context.plan.providerGeneration)",
                    operationID: context.operationID,
                    diagnostic:
                        "Rollback requires sensitive configuration that cannot be reconstructed exactly.",
                    guidance:
                        "Preserve the safe-hold checkpoint and restore the verified revision with an available secret provider."
                )
            )
        }
        do {
            let compensatingNode = try LifecyclePlanNode(
                key: node.key,
                action: compensation.action,
                serviceName: node.serviceName,
                resourceIdentifier: node.resourceIdentifier,
                resourceUUID: node.resourceUUID,
                resourceGeneration: node.resourceGeneration,
                fencingToken: node.fencingToken,
                dependencies: [],
                preconditions: compensation.preconditions,
                postconditions: [],
                timeoutSeconds: compensation.timeoutSeconds,
                compensation: nil,
                desiredSpecificationJSONRedacted: node.desiredSpecificationJSONRedacted
            )
            switch await apply(node: compensatingNode, context: context) {
            case .accepted:
                switch await observe(node: compensatingNode, context: context) {
                case .satisfied(let verification):
                    _ = try await reconcileCompensatedOwnershipProjection(
                        context: context,
                        allowObservedRuntimeFence: false
                    )
                    return .compensated(verification)
                case .noEffect, .effectPresent:
                    return .failed(
                        RuntimeNormalizedFailure(
                            category: .partialEffect,
                            retryDisposition: .resumeFromCheckpoint,
                            recoveryDisposition: .resume,
                            providerID: context.plan.providerID.rawValue,
                            providerVersion: "bound-generation-\(context.plan.providerGeneration)",
                            operationID: context.operationID,
                            diagnostic: "Compensation did not satisfy its exact structured postcondition.",
                            guidance: "Preserve the safe-hold checkpoint and inspect only the exact owned resource."
                        )
                    )
                case .ambiguous:
                    return .failed(
                        RuntimeNormalizedFailure(
                            category: .ambiguousEffect,
                            retryDisposition: .safeAfterObservation,
                            recoveryDisposition: .reobserve,
                            providerID: context.plan.providerID.rawValue,
                            providerVersion: "bound-generation-\(context.plan.providerGeneration)",
                            operationID: context.operationID,
                            diagnostic: "Compensation could not be verified by structured observation.",
                            guidance: "Preserve the safe-hold checkpoint and inspect only the exact owned resource."
                        )
                    )
                }
            case .failed(let failure):
                return .failed(failure)
            }
        } catch {
            return .failed(
                RuntimeNormalizedFailure(
                    category: .ambiguousEffect,
                    retryDisposition: .safeAfterObservation,
                    recoveryDisposition: .reobserve,
                    providerID: context.plan.providerID.rawValue,
                    providerVersion: "bound-generation-\(context.plan.providerGeneration)",
                    operationID: context.operationID,
                    diagnostic: RuntimeRedactionPolicy.default.redact(String(describing: error)),
                    guidance: "Re-observe the exact owned resource before deciding whether compensation is complete."
                )
            )
        }
    }

    @discardableResult
    func reconcileCompensatedOwnershipProjection(
        context: LifecycleSagaContext,
        allowObservedRuntimeFence: Bool
    ) async throws -> Int {
        let inventory = try await adapter.inventory()
        let records = try store.ownership.loadAll()
        var bindingsByResourceUUID: [
            String: LifecycleResourceBinding
        ] = [:]
        for record in records where
            record.projectID == context.plan.projectID &&
            record.fencingToken == context.fencingToken
        {
            if let binding = await state.binding(
                resourceUUID: record.resourceUUID,
                resourceIdentifier: record.resourceIdentifier
            ) {
                bindingsByResourceUUID[record.resourceUUID] = binding
            }
        }
        let restoredRecords =
            try lifecycleRestoreCompensatedOwnershipProjection(
                store: store,
                plan: context.plan,
                operationFencingToken: context.fencingToken,
                inventory: inventory,
                expectedPriorFencesByResourceUUID: bindingsByResourceUUID
                    .mapValues(\.currentFencingToken),
                allowObservedRuntimeFence: allowObservedRuntimeFence
            )
        for restored in restoredRecords {
            guard let binding = bindingsByResourceUUID[
                restored.resourceUUID
            ] else {
                throw StateStoreError.invalidRecord(
                    "Completed compensation lost its exact in-memory ownership binding."
                )
            }
            await state.setBinding(
                try LifecycleResourceBinding(
                    record: restored,
                    identity: binding.identity,
                    providerID: context.plan.providerID
                )
            )
        }
        return restoredRecords.count
    }

    func rolloutDeadlineFailure(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) -> RuntimeNormalizedFailure? {
        guard context.plan.command == .update,
              context.direction == .forward else {
            return nil
        }
        let conditions = node.preconditions.filter {
            $0.kind == "progress-deadline-seconds"
        }
        guard conditions.count == 1,
              let seconds = Int(conditions[0].expectedValue),
              seconds > 0,
              let group = try? store.operationGroups.load(id: context.groupID),
              let startedAt = lifecycleEpochMilliseconds(group.createdAt) else {
            return RuntimeNormalizedFailure(
                category: .staleCapability,
                retryDisposition: .never,
                recoveryDisposition: .none,
                providerID: context.plan.providerID.rawValue,
                providerVersion:
                    "bound-generation-\(context.plan.providerGeneration)",
                operationID: context.operationID,
                diagnostic:
                    "Rollout progress deadline evidence is missing or invalid.",
                guidance:
                    "Preserve the fenced operation and inspect its durable intent before retrying."
            )
        }
        guard nowMilliseconds() >= startedAt + Int64(seconds) * 1_000 else {
            return nil
        }
        return RuntimeNormalizedFailure(
            category: .timedOut,
            retryDisposition: .never,
            recoveryDisposition: .compensate,
            providerID: context.plan.providerID.rawValue,
            providerVersion:
                "bound-generation-\(context.plan.providerGeneration)",
            operationID: context.operationID,
            diagnostic:
                "Rollout progress deadline of \(seconds) seconds was exceeded before \(node.key).",
            guidance:
                "Restore the last verified healthy revision through the recorded compensation checkpoints."
        )
    }
}

func lifecycleRestoreCompensatedOwnershipProjection(
    store: SQLiteStateStore,
    plan: LifecyclePlan,
    operationFencingToken: String,
    inventory: RuntimeInventory,
    expectedPriorFencesByResourceUUID: [String: String],
    allowObservedRuntimeFence: Bool
) throws -> [OwnershipRecord] {
    var restoredRecords: [OwnershipRecord] = []
    let records = try store.ownership.loadAll()
    var restorations: [(record: OwnershipRecord, fencingToken: String)] = []

    for record in records.sorted(by: {
        $0.resourceIdentifier < $1.resourceIdentifier
    }) {
        guard record.projectID == plan.projectID,
              record.projectResourceUUID == plan.projectResourceUUID,
              record.projectGeneration == plan.projectGeneration,
              record.providerGeneration == plan.providerGeneration,
              RuntimeProviderBinding.stableID(
                  for: record.runtimeAdapter
              ) == plan.providerID,
              record.fencingToken == operationFencingToken,
              plan.nodes.contains(where: {
                  $0.resourceUUID == record.resourceUUID &&
                      $0.resourceIdentifier == record.resourceIdentifier &&
                      $0.resourceGeneration == record.resourceGeneration
              }) else {
            continue
        }

        let matches = inventory.containers.filter {
            $0.ownership?.resourceUUID == record.resourceUUID
        }
        guard matches.count == 1,
              matches[0].name == record.resourceIdentifier,
              let observed = matches[0].ownership,
              observed.resourceGeneration == record.resourceGeneration,
              observed.projectUUID == plan.projectResourceUUID,
              observed.projectGeneration == plan.projectGeneration,
              observed.providerID == plan.providerID,
              observed.providerGeneration == plan.providerGeneration,
              HostwrightResourceUUID.isValid(observed.fencingToken) else {
            if allowObservedRuntimeFence {
                throw StateStoreError.invalidRecord(
                    "Completed compensation could not prove one exact runtime ownership projection."
                )
            }
            continue
        }

        let restoredFence: String
        if let expectedPriorFence =
            expectedPriorFencesByResourceUUID[record.resourceUUID],
           expectedPriorFence != operationFencingToken
        {
            guard observed.fencingToken == expectedPriorFence else {
                if allowObservedRuntimeFence {
                    throw StateStoreError.invalidRecord(
                        "Completed compensation runtime fencing does not match its exact pre-operation binding."
                    )
                }
                continue
            }
            restoredFence = expectedPriorFence
        } else {
            guard allowObservedRuntimeFence,
                  observed.fencingToken != operationFencingToken else {
                continue
            }
            restoredFence = observed.fencingToken
        }

        restorations.append((record, restoredFence))
    }

    if allowObservedRuntimeFence, !restorations.isEmpty {
        guard lifecycleCompensatedFenceProofMatches(
            plan: plan,
            operationFencingToken: operationFencingToken,
            records: records,
            restoredFencesByResourceUUID: Dictionary(
                uniqueKeysWithValues: restorations.map {
                    ($0.record.resourceUUID, $0.fencingToken)
                }
            )
        ) else {
            throw StateStoreError.invalidRecord(
                "Completed compensation could not prove the observed prior fences against the confirmed lifecycle plan."
            )
        }
    }

    for restoration in restorations {
        let record = restoration.record
        guard let restored = try store.ownership.advanceFencingToken(
            resourceIdentifier: record.resourceIdentifier,
            runtimeAdapter: record.runtimeAdapter,
            expectedResourceUUID: record.resourceUUID,
            expectedFencingToken: operationFencingToken,
            newFencingToken: restoration.fencingToken,
            observedAt: hostwrightTimestamp()
        ) else {
            throw StateStoreError.invalidRecord(
                "Completed compensation could not restore the exact ownership fence."
            )
        }
        restoredRecords.append(restored)
    }
    return restoredRecords
}

private func lifecycleCompensatedFenceProofMatches(
    plan: LifecyclePlan,
    operationFencingToken: String,
    records: [OwnershipRecord],
    restoredFencesByResourceUUID: [String: String]
) -> Bool {
    let timeoutValues = Set(plan.nodes.map(\.timeoutSeconds))
    guard timeoutValues.count == 1,
          let timeoutSeconds = timeoutValues.first,
          let command = LifecycleCommandKind(
              rawValue: plan.command.rawValue
          ) else {
        return false
    }
    let bindings: [LifecycleResourceBinding]
    do {
        bindings = try records.compactMap { record in
            guard record.projectID == plan.projectID,
                  record.projectResourceUUID ==
                    plan.projectResourceUUID,
                  record.projectGeneration == plan.projectGeneration,
                  record.providerGeneration == plan.providerGeneration,
                  RuntimeProviderBinding.stableID(
                      for: record.runtimeAdapter
                  ) == plan.providerID else {
                return nil
            }
            let identity =
                lifecycleOwnershipMetadata(from: record)?.identity ??
                plan.nodes.first(where: {
                    $0.resourceUUID == record.resourceUUID &&
                        $0.resourceIdentifier == record.resourceIdentifier &&
                        $0.resourceGeneration == record.resourceGeneration
                }).flatMap {
                    try? LifecycleRevisionCodec.decodeRedactedDesiredJSON(
                        $0.desiredSpecificationJSONRedacted
                    ).identity
                }
            guard let identity else { return nil }
            return try LifecycleResourceBinding(
                identity: identity,
                resourceIdentifier: record.resourceIdentifier,
                identityVersion: record.identityVersion,
                resourceUUID: record.resourceUUID,
                resourceGeneration: record.resourceGeneration,
                projectResourceUUID: plan.projectResourceUUID,
                projectGeneration: plan.projectGeneration,
                providerID: plan.providerID,
                providerGeneration: plan.providerGeneration,
                currentFencingToken:
                    restoredFencesByResourceUUID[record.resourceUUID] ??
                    record.fencingToken
            )
        }
    } catch {
        return false
    }
    return lifecyclePlanFence(
        command: command,
        manifestSHA256: plan.manifestSHA256,
        observationSHA256: plan.observationSHA256,
        capabilitySHA256: plan.capabilitySHA256,
        projectID: plan.projectID,
        providerID: plan.providerID,
        providerGeneration: plan.providerGeneration,
        selectedServices: Set(plan.nodes.compactMap(\.serviceName)).sorted(),
        timeoutSeconds: timeoutSeconds,
        parallelism: plan.parallelism,
        resourceBindings: bindings
    ) == operationFencingToken
}
