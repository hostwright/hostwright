import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightState
import HostwrightStorage

struct StorageReclaimCommandCoordinator {
    private static var lockOwner: String {
        "hostwright-storage-reclaim:\(getpid())"
    }
    private static let maximumPlanResources = 256

    let options: StorageCLIOptions
    let environment: CLIEnvironment
    private let nowUnixMilliseconds: @Sendable () -> Int64

    init(
        options: StorageCLIOptions,
        environment: CLIEnvironment,
        nowUnixMilliseconds:
            @escaping @Sendable () -> Int64 = {
                Int64(Date().timeIntervalSince1970 * 1_000)
            }
    ) {
        self.options = options
        self.environment = environment
        self.nowUnixMilliseconds = nowUnixMilliseconds
    }

    func delete(
        volumeID: String,
        confirmation: StorageDestructiveCLIOptions,
        client: StorageProviderClient
    ) async throws -> CLIRunResult {
        let context = try stateContext()
        let state = try requireVolume(volumeID, state: context.state)
        guard state.reclaimPolicy != .recycle else {
            throw diagnostic(
                .storageUnavailable,
                "The built-in provider cannot prove safe recycle support; no provider mutation was attempted."
            )
        }

        let observation = try await observe(
            client,
            volumeID: volumeID,
            idempotencyDomain: "delete-preview"
        )
        if let replay = try replayPlanIfProviderMissing(
            state: state,
            observation: observation,
            store: context.store
        ) {
            if confirmation.dryRun {
                return renderPlan(
                    operation: "delete",
                    volumeIDs: [volumeID],
                    planSHA256: replay.planSHA256
                )
            }
            try requireConfirmation(
                confirmation,
                planSHA256: replay.planSHA256
            )
            return try finalizeProviderMissingReplay(
                replay,
                state: state,
                store: context.store,
                repository: context.state
            )
        }

        let prepared = try await prepareDelete(
            state: state,
            observation: observation,
            stateRepository: context.state,
            authorizationSeed: "cli-delete",
            requestedPolicy:
                state.reclaimPolicy == .retain ? .delete : nil,
            client: client
        )
        if confirmation.dryRun {
            return renderPlan(
                operation: "delete",
                volumeIDs: [volumeID],
                planSHA256: prepared.authorizationPlanSHA256
            )
        }
        try requireConfirmation(
            confirmation,
            planSHA256: prepared.authorizationPlanSHA256
        )
        return try await executeDelete(
            prepared,
            operationPlanSHA256:
                prepared.authorizationPlanSHA256,
            client: client,
            store: context.store,
            stateRepository: context.state
        )
    }

    /// Applies the volume's persisted reclaim policy after a lifecycle
    /// remove whose exact plan digest has already been confirmed.
    func applyPolicy(
        volumeID: String,
        authorizedLifecyclePlanSHA256: String,
        client: StorageProviderClient
    ) async throws -> CLIRunResult {
        try await applyPolicy(
            volumeID: volumeID,
            authorizedLifecyclePlanSHA256:
                authorizedLifecyclePlanSHA256,
            client: client,
            context: try stateContext()
        )
    }

    func applyPolicies(
        volumeIDs: [String],
        authorizedLifecyclePlanSHA256: String,
        client: StorageProviderClient
    ) async throws -> [CLIRunResult] {
        let ordered = Array(Set(volumeIDs)).sorted()
        guard ordered.count <= Self.maximumPlanResources else {
            throw diagnostic(
                .storageInvalid,
                "Lifecycle reclaim exceeds the bounded volume limit."
            )
        }
        let context = try stateContext()
        var results: [CLIRunResult] = []
        results.reserveCapacity(ordered.count)
        for volumeID in ordered {
            results.append(
                try await applyPolicy(
                    volumeID: volumeID,
                    authorizedLifecyclePlanSHA256:
                        authorizedLifecyclePlanSHA256,
                    client: client,
                    context: context
                )
            )
        }
        return results
    }

    private func applyPolicy(
        volumeID: String,
        authorizedLifecyclePlanSHA256: String,
        client: StorageProviderClient,
        context: StateContext
    ) async throws -> CLIRunResult {
        guard Self.validSHA256(authorizedLifecyclePlanSHA256) else {
            throw diagnostic(
                .storageInvalid,
                "Lifecycle reclaim requires the exact authorized lifecycle plan digest."
            )
        }
        let state = try requireVolume(volumeID, state: context.state)
        if state.reclaimPolicy == .retain {
            let report = StorageReclaimCommandReport(
                operation: "apply-policy",
                disposition: "retained",
                volumeIDs: [volumeID],
                planSHA256: authorizedLifecyclePlanSHA256,
                reclaimedCapacityBytes: 0
            )
            return render(
                report,
                text: """
                Storage reclaim policy: retained
                Volume: \(volumeID)
                Authorized lifecycle plan: \(authorizedLifecyclePlanSHA256)

                """
            )
        }
        guard state.reclaimPolicy != .recycle else {
            throw diagnostic(
                .storageUnavailable,
                "The built-in provider cannot prove safe recycle support; no provider mutation was attempted."
            )
        }
        let observation = try await observe(
            client,
            volumeID: volumeID,
            idempotencyDomain: "lifecycle-policy"
        )
        if state.lifecycleState == .deleted,
           providerIsAbsent(
               volumeID,
               observation: observation
           ) {
            guard !observation.ambiguousVolumeIDs.contains(
                volumeID
            ) else {
                throw diagnostic(
                    .storageConflict,
                    "The provider reports ambiguous ownership for the requested volume."
                )
            }
            return completedReport(
                volumeID: volumeID,
                planSHA256:
                    authorizedLifecyclePlanSHA256,
                disposition: "already-satisfied"
            )
        }
        if let replay = try replayPlanIfProviderMissing(
            state: state,
            observation: observation,
            store: context.store
        ) {
            guard replay.planSHA256 ==
                    authorizedLifecyclePlanSHA256 else {
                throw diagnostic(
                    .storageConflict,
                    "The interrupted reclaim operation belongs to a different authorized lifecycle plan."
                )
            }
            return try finalizeProviderMissingReplay(
                replay,
                state: state,
                store: context.store,
                repository: context.state
            )
        }
        let prepared = try await prepareDelete(
            state: state,
            observation: observation,
            stateRepository: context.state,
            authorizationSeed:
                "lifecycle:\(authorizedLifecyclePlanSHA256)",
            client: client
        )
        return try await executeDelete(
            prepared,
            operationPlanSHA256:
                authorizedLifecyclePlanSHA256,
            client: client,
            store: context.store,
            stateRepository: context.state
        )
    }

    func prune(
        confirmation: StorageDestructiveCLIOptions,
        client: StorageProviderClient
    ) async throws -> CLIRunResult {
        let context = try stateContext()
        if !confirmation.dryRun,
           let planSHA256 =
               confirmation.confirmationPlanSHA256,
           Self.validSHA256(planSHA256),
           let recovered = try await resumeInterruptedPrune(
               planSHA256: planSHA256,
               client: client,
               context: context
           ) {
            return recovered
        }
        let observation = try await observe(
            client,
            volumeID: nil,
            idempotencyDomain: "prune-preview"
        )
        let snapshot = try orphanSnapshot(
            observation: observation,
            state: context.state,
            store: context.store
        )
        let engine = StorageOrphanEngine()
        let report: StorageOrphanReport
        do {
            report = try engine.discover(
                inventory: snapshot.inventory,
                authoritativeState: snapshot.authoritativeState,
                atUnixMilliseconds: nowUnixMilliseconds()
            )
        } catch {
            throw diagnostic(
                .storageConflict,
                "Storage orphan discovery refused inconsistent or unbounded provider evidence."
            )
        }
        let exactCandidates = try exactPruneCandidates(
            report.reclaimPlan.entries,
            observation: observation,
            volumesByID: snapshot.volumesByID
        )
        let gcPlan = try garbageCollectionPlan(
            candidates: exactCandidates,
            report: report
        )
        let candidatesByID = Dictionary(
            uniqueKeysWithValues: exactCandidates.map {
                ($0.state.id, $0)
            }
        )
        let candidates = gcPlan.selected.compactMap {
            candidatesByID[$0.resourceID]
        }
        guard candidates.count == exactCandidates.count else {
            throw diagnostic(
                .storageConflict,
                "The prioritized storage GC plan omitted an exact reclaim candidate."
            )
        }
        let planSHA256 = sha256(
            [
                "hostwright.storage.pressure-prune.v1",
                report.reclaimPlan.confirmationSHA256,
                gcPlan.confirmationSHA256,
            ].joined(separator: "\n")
        )
        if confirmation.dryRun {
            return renderPlan(
                operation: "prune",
                volumeIDs: candidates.map(\.state.id),
                planSHA256: planSHA256
            )
        }
        try requireConfirmation(
            confirmation,
            planSHA256: planSHA256
        )
        do {
            _ = try engine.reclaim(
                plan: report.reclaimPlan,
                exactConfirmationSHA256:
                    report.reclaimPlan.confirmationSHA256
            )
        } catch {
            throw diagnostic(
                .storageConflict,
                "The exact storage prune plan changed; run the dry-run again."
            )
        }

        let intent = try PruneOperationIntent(
            authorizationPlanSHA256: planSHA256,
            report: report,
            garbageCollectionPlan: gcPlan,
            candidates: candidates.map {
                try PruneCandidateIntent(
                    finding: $0.finding,
                    state: $0.state,
                    observedSHA256:
                        canonicalSHA256($0.observed),
                    providerMutationContext:
                        try providerContext($0.observed)
                )
            }
        )
        let group = try acquirePruneOperation(
            planSHA256: planSHA256,
            intent: intent,
            store: context.store
        )
        return try await executePrune(
            intent,
            group: group,
            client: client,
            context: context,
            resumed: false
        )
    }

    private func executePrune(
        _ intent: PruneOperationIntent,
        group: OperationGroupRecord,
        client: StorageProviderClient,
        context: StateContext,
        resumed: Bool
    ) async throws -> CLIRunResult {
        let planSHA256 =
            intent.authorizationPlanSHA256
        do {
            let persisted = try persistFindings(
                intent.report.findings,
                group: group,
                repository: context.state
            )
            try checkpoint(
                group,
                name: "classifications-persisted",
                verification:
                    #"{"findingCount":\#(intent.report.findings.count),"selectedCount":\#(intent.candidates.count)}"#,
                store: context.store
            )

            var reclaimedBytes: Int64 = 0
            var removed: [String] = []
            for candidate in intent.candidates {
                let current = try requireVolume(
                    candidate.state.id,
                    state: context.state
                )
                let stateIsInitial = current == candidate.state
                let stateIsFinalized = isFinalizedPruneState(
                    current,
                    original: candidate.state,
                    group: group
                )
                guard stateIsInitial || stateIsFinalized else {
                    throw diagnostic(
                        .storageConflict,
                        "A persisted prune candidate no longer has its exact authoritative generation and fencing state."
                    )
                }
                let fresh = try await observe(
                    client,
                    volumeID: candidate.state.id,
                    idempotencyDomain:
                        "prune-fresh:\(planSHA256)"
                )
                if providerIsAbsent(
                    candidate.state.id,
                    observation: fresh
                ) {
                    try await recoverPendingPruneDelete(
                        candidate,
                        planSHA256: planSHA256,
                        observation: fresh,
                        client: client
                    )
                    if stateIsInitial {
                        try finalizePrunedVolume(
                            candidate.state,
                            group: group,
                            repository: context.state
                        )
                    }
                    try markPersistedOrphanReclaimed(
                        candidate,
                        persisted: persisted,
                        group: group,
                        repository: context.state
                    )
                    removed.append(candidate.state.id)
                    reclaimedBytes = addingCapacity(
                        candidate.state.capacityBytes,
                        to: reclaimedBytes
                    )
                    try checkpoint(
                        group,
                        name: "candidate-recovered",
                        verification:
                            #"{"volumeID":"\#(candidate.state.id)"}"#,
                        store: context.store
                    )
                    continue
                }
                guard stateIsInitial else {
                    throw diagnostic(
                        .storagePartialEffect,
                        "A finalized prune candidate unexpectedly reappeared at the provider."
                    )
                }
                let freshVolume = try requireExactObservedVolume(
                    candidate.state,
                    observation: fresh,
                    allowDeletingGeneration: false
                )
                guard try canonicalSHA256(freshVolume) ==
                        candidate.observedSHA256 else {
                    throw diagnostic(
                        .storageConflict,
                        "A selected prune resource changed after confirmation; no further provider mutation was attempted."
                    )
                }
                try checkpoint(
                    group,
                    name: "provider-effect-requested",
                    verification:
                        #"{"volumeID":"\#(candidate.state.id)"}"#,
                    store: context.store
                )
                let result: LocalStorageMutationResult =
                    try await client.invoke(
                        operation: .delete,
                        mutationContext:
                            try providerContext(freshVolume),
                        idempotencyKey:
                            pruneDeleteIdempotencyKey(
                                planSHA256: planSHA256,
                                volumeID:
                                    candidate.state.id
                            ),
                        payload: LocalStorageDeletePayload(),
                        result: LocalStorageMutationResult.self
                    )
                guard result.removedVolumeID ==
                        candidate.state.id else {
                    throw diagnostic(
                        .storagePartialEffect,
                        "The provider returned mismatched prune deletion evidence."
                    )
                }
                let after = try await observe(
                    client,
                    volumeID: candidate.state.id,
                    idempotencyDomain:
                        "prune-verify:\(planSHA256)"
                )
                try requireProviderAbsent(
                    candidate.state.id,
                    observation: after
                )
                try finalizePrunedVolume(
                    candidate.state,
                    group: group,
                    repository: context.state
                )
                try markPersistedOrphanReclaimed(
                    candidate,
                    persisted: persisted,
                    group: group,
                    repository: context.state
                )
                removed.append(candidate.state.id)
                reclaimedBytes = addingCapacity(
                    candidate.state.capacityBytes,
                    to: reclaimedBytes
                )
            }
            try checkpoint(
                group,
                name: "provider-absence-verified",
                verification:
                    #"{"removedCount":\#(removed.count)}"#,
                store: context.store
            )
            try finishSucceeded(group, store: context.store)
            let result = StorageReclaimCommandReport(
                operation: "prune",
                disposition: resumed ? "recovered" : "performed",
                volumeIDs: removed.sorted(),
                planSHA256: planSHA256,
                reclaimedCapacityBytes: reclaimedBytes
            )
            return render(
                result,
                text: """
                Storage prune: \(resumed ? "recovered" : "performed")
                Volumes: \(removed.isEmpty ? "none" : removed.sorted().joined(separator: ", "))
                Reclaimed bytes: \(reclaimedBytes)

                """
            )
        } catch {
            try? finishInterrupted(group, store: context.store)
            throw error
        }
    }

    private func recoverPendingPruneDelete(
        _ candidate: PruneCandidateIntent,
        planSHA256: String,
        observation: LocalStorageObservation,
        client: StorageProviderClient
    ) async throws {
        let deleteKey = pruneDeleteIdempotencyKey(
            planSHA256: planSHA256,
            volumeID: candidate.state.id
        )
        let pendingID = sha256(deleteKey)
        guard observation.pendingRecoveryIDs.contains(
            pendingID
        ) else {
            return
        }
        let recovered: LocalStorageRecoveryResult =
            try await client.invoke(
                operation: .recovery,
                mutationContext:
                    candidate.providerMutationContext,
                idempotencyKey: sha256(
                    "prune-recovery:\(planSHA256):\(candidate.state.id)"
                ),
                payload: LocalStorageRecoveryPayload(
                    idempotencyKey: deleteKey
                ),
                result: LocalStorageRecoveryResult.self
            )
        guard recovered.recoveredOperation == .delete else {
            throw diagnostic(
                .storagePartialEffect,
                "Provider recovery returned evidence for a different storage operation."
            )
        }
        let verified = try await observe(
            client,
            volumeID: candidate.state.id,
            idempotencyDomain:
                "prune-recovery-verify:\(planSHA256)"
        )
        guard providerIsAbsent(
                candidate.state.id,
                observation: verified
              ),
              !verified.pendingRecoveryIDs.contains(
                pendingID
              ) else {
            throw diagnostic(
                .storagePartialEffect,
                "Recovered prune deletion did not prove exact provider absence and journal cleanup."
            )
        }
    }

    private func pruneDeleteIdempotencyKey(
        planSHA256: String,
        volumeID: String
    ) -> String {
        sha256("prune:\(planSHA256):\(volumeID)")
    }

    private struct StateContext {
        let store: SQLiteStateStore
        let state: StorageStateRepository
    }

    private struct PreparedDelete {
        let state: StorageStateVolumeRecord
        let observed: LocalStorageVolumeObservation
        let request: StorageReclaimRequest
        let plan: StorageReclaimPlan
        let checkpoint: StorageReclaimCheckpoint
        let authorizationPlanSHA256: String
    }

    private struct DeleteOperationIntent: Encodable {
        let request: StorageReclaimRequest
        let plan: StorageReclaimPlan
        let observedProviderGeneration: Int
        let observedProviderFencingToken: String
    }

    private struct ProviderMissingReplay {
        let planSHA256: String
        let group: OperationGroupRecord?
    }

    private struct OrphanSnapshot {
        let inventory: StorageOrphanObservedInventory
        let authoritativeState: StorageOrphanAuthoritativeState
        let volumesByID: [String: StorageStateVolumeRecord]
    }

    private struct PruneCandidate {
        let finding: StorageOrphanFinding
        let state: StorageStateVolumeRecord
        let observed: LocalStorageVolumeObservation
    }

    private struct PruneCandidateIntent:
        Codable,
        Equatable,
        Sendable
    {
        let finding: StorageOrphanFinding
        let state: StorageStateVolumeRecord
        let observedSHA256: String
        let providerMutationContext:
            StorageProviderMutationContext

        init(
            finding: StorageOrphanFinding,
            state: StorageStateVolumeRecord,
            observedSHA256: String,
            providerMutationContext:
                StorageProviderMutationContext
        ) throws {
            guard StorageReclaimCommandCoordinator.validSHA256(
                    observedSHA256
                  ),
                  providerMutationContext.isValid else {
                throw HostwrightDiagnostic(
                    code: .storageInvalid,
                    message:
                        "Storage prune intent requires exact observed candidate authority."
                )
            }
            self.finding = finding
            self.state = state
            self.observedSHA256 = observedSHA256
            self.providerMutationContext =
                providerMutationContext
        }
    }

    private struct PruneOperationIntent:
        Codable,
        Equatable,
        Sendable
    {
        let authorizationPlanSHA256: String
        let report: StorageOrphanReport
        let garbageCollectionPlan: StorageGCPlan
        let candidates: [PruneCandidateIntent]

        init(
            authorizationPlanSHA256: String,
            report: StorageOrphanReport,
            garbageCollectionPlan: StorageGCPlan,
            candidates: [PruneCandidateIntent]
        ) throws {
            let selectedIDs =
                garbageCollectionPlan.selected.map(
                    \.resourceID
                )
            let candidatesByID = Dictionary(
                uniqueKeysWithValues: candidates.map {
                    ($0.state.id, $0)
                }
            )
            let ordered = selectedIDs.compactMap {
                candidatesByID[$0]
            }
            let orderedFindings =
                ordered.map(\.finding).sorted {
                    (
                        $0.providerID,
                        $0.resourceKind.rawValue,
                        $0.providerResourceIDHash
                    ) < (
                        $1.providerID,
                        $1.resourceKind.rawValue,
                        $1.providerResourceIDHash
                    )
                }
            guard StorageReclaimCommandCoordinator
                    .validSHA256(
                        authorizationPlanSHA256
                    ),
                  ordered.count <=
                    StorageReclaimCommandCoordinator
                        .maximumPlanResources,
                  Set(ordered.map(\.state.id)).count ==
                    ordered.count,
                  ordered.count == candidates.count,
                  orderedFindings ==
                    report.reclaimPlan.entries,
                  garbageCollectionPlan.targetSatisfied,
                  !garbageCollectionPlan.cancelled else {
                throw HostwrightDiagnostic(
                    code: .storageConflict,
                    message:
                        "Storage prune intent does not exactly match its confirmed reclaim plan."
                )
            }
            self.authorizationPlanSHA256 =
                authorizationPlanSHA256
            self.report = report
            self.garbageCollectionPlan =
                garbageCollectionPlan
            self.candidates = ordered
        }
    }

    private func stateContext() throws -> StateContext {
        let configuration = try hostwrightStateStoreConfiguration(
            explicitPath: options.stateDatabasePath,
            environment: environment
        )
        let store = SQLiteStateStore(configuration: configuration)
        try store.migrate()
        guard try store.schemaVersion() ==
                HostwrightContractVersions.stateSchema else {
            throw diagnostic(
                .stateStoreUnavailable,
                "Volume reclaim requires the current schema-v15 state."
            )
        }
        return StateContext(
            store: store,
            state: StorageStateRepository(store: store)
        )
    }

    private func requireVolume(
        _ volumeID: String,
        state: StorageStateRepository
    ) throws -> StorageStateVolumeRecord {
        guard let record = try state.loadVolume(id: volumeID) else {
            throw diagnostic(
                .storageConflict,
                "The requested volume has no authoritative Hostwright ownership state."
            )
        }
        guard record.id == volumeID,
              record.providerID ==
                LocalStorageProviderContract.providerID,
              record.providerVolumeID == volumeID else {
            throw diagnostic(
                .storageConflict,
                "The requested volume state does not prove exact local-provider ownership."
            )
        }
        return record
    }

    private func prepareDelete(
        state: StorageStateVolumeRecord,
        observation: LocalStorageObservation,
        stateRepository: StorageStateRepository,
        authorizationSeed: String,
        requestedPolicy: StorageReclaimMode? = nil,
        client: StorageProviderClient
    ) async throws -> PreparedDelete {
        let observed = try requireExactObservedVolume(
            state,
            observation: observation,
            allowDeletingGeneration: true
        )
        let activeAttachments = try stateRepository
            .loadAttachments(volumeID: state.id)
            .filter { $0.lifecycleState != .detached }
            .map(\.id)
        let providerAttachments =
            observed.attachments.map(\.attachmentID)
        let attachments =
            Array(Set(activeAttachments + providerAttachments))
                .sorted()
        let now = timestamp(nowUnixMilliseconds())
        let holds = try stateRepository.activeHolds(
            resourceKind: .volume,
            resourceID: state.id,
            at: now
        ).map(\.id)
        let ownershipProof = ownershipProofSHA256(
            state: state,
            observed: observed
        )
        let currentPolicy = reclaimMode(state.reclaimPolicy)
        let policy = requestedPolicy ?? currentPolicy
        let operationID = HostwrightResourceUUID.legacy(
            kind: "storage-reclaim-operation",
            identifier: [
                authorizationSeed,
                state.id,
                String(observed.generation),
                observed.fencingToken,
                policy.rawValue,
            ].joined(separator: ":")
        )
        let idempotencySHA256 = sha256(
            [
                "hostwright.storage.reclaim-command.v1",
                authorizationSeed,
                operationID,
                ownershipProof,
            ].joined(separator: "\n")
        )
        let prerequisite = try await prerequisiteProof(
            policy: policy,
            state: state,
            observed: observed,
            observedGeneration: Int64(observed.generation),
            observedFence: observed.fencingToken,
            ownershipProofSHA256: ownershipProof,
            repository: stateRepository,
            client: client
        )
        let request: StorageReclaimRequest
        do {
            request = try StorageReclaimRequest(
                operationID: operationID,
                idempotencySHA256: idempotencySHA256,
                volumeID: state.id,
                projectID: observed.projectID,
                providerID: state.providerID,
                generation: Int64(observed.generation),
                fencingToken: observed.fencingToken,
                currentPolicy: currentPolicy,
                requestedPolicy: policy,
                activeAttachmentIDs: attachments,
                activeHoldIDs: holds,
                ownershipProofSHA256: ownershipProof
            )
        } catch let error as StorageReclaimError {
            throw reclaimDiagnostic(error)
        }
        let engine = StorageReclaimEngine()
        let plan: StorageReclaimPlan
        do {
            plan = try engine.preview(request)
        } catch let error as StorageReclaimError {
            throw reclaimDiagnostic(error)
        }
        let completed: [StorageReclaimAction]
        switch policy {
        case .snapshotBeforeDelete:
            completed = [.createSnapshot, .verifySnapshot]
        case .backupBeforeDelete:
            completed = [.createBackup, .verifyBackup]
        case .delete:
            completed = []
        case .retain, .recycle:
            completed = []
        }
        let checkpoint: StorageReclaimCheckpoint
        do {
            checkpoint = try StorageReclaimCheckpoint(
                operationID: operationID,
                idempotencySHA256: idempotencySHA256,
                confirmationSHA256: plan.confirmationSHA256,
                completedActions: completed,
                prerequisiteProof: prerequisite
            )
            let decision = try engine.nextAction(
                request: request,
                plan: plan,
                confirmationSHA256:
                    plan.confirmationSHA256,
                checkpoint: checkpoint
            )
            guard decision.disposition == .perform,
                  decision.action == .delete else {
                throw diagnostic(
                    .storageConflict,
                    "The persisted reclaim policy did not authorize an exact provider deletion."
                )
            }
        } catch let error as StorageReclaimError {
            throw reclaimDiagnostic(error)
        }
        let authorizationPlan =
            state.lifecycleState == .deleting
                ? nil
                : plan.confirmationSHA256
        return PreparedDelete(
            state: state,
            observed: observed,
            request: request,
            plan: plan,
            checkpoint: checkpoint,
            authorizationPlanSHA256:
                authorizationPlan ?? plan.confirmationSHA256
        )
    }

    private func executeDelete(
        _ prepared: PreparedDelete,
        operationPlanSHA256: String,
        client: StorageProviderClient,
        store: SQLiteStateStore,
        stateRepository: StorageStateRepository
    ) async throws -> CLIRunResult {
        let group = try acquireDeleteOperation(
            prepared,
            operationPlanSHA256: operationPlanSHA256,
            store: store
        )
        let deleting: StorageStateVolumeRecord
        do {
            if prepared.state.lifecycleState == .deleting {
                deleting = prepared.state
            } else {
                deleting = nextVolumeState(
                    prepared.state,
                    lifecycleState: .deleting,
                    group: group
                )
                try stateRepository.saveVolume(
                    deleting,
                    replacing: expected(prepared.state)
                )
                try synchronizeQuota(
                    for: deleting,
                    lifecycleState: .releasing,
                    group: group,
                    repository: stateRepository
                )
            }
            try checkpoint(
                group,
                name: "delete-intent-persisted",
                verification:
                    #"{"volumeID":"\#(prepared.state.id)"}"#,
                store: store
            )
        } catch {
            try? finishInterrupted(group, store: store)
            throw error
        }

        do {
            try checkpoint(
                group,
                name: "provider-effect-requested",
                verification: "{}",
                store: store
            )
            let result: LocalStorageMutationResult =
                try await client.invoke(
                    operation: .delete,
                    mutationContext:
                        try providerContext(prepared.observed),
                    idempotencyKey:
                        prepared.request.idempotencySHA256,
                    payload: LocalStorageDeletePayload(),
                    result: LocalStorageMutationResult.self
                )
            guard result.removedVolumeID == prepared.state.id else {
                throw diagnostic(
                    .storagePartialEffect,
                    "The provider returned mismatched volume deletion evidence."
                )
            }
            let after = try await observe(
                client,
                volumeID: prepared.state.id,
                idempotencyDomain:
                    "delete-verify:\(prepared.request.operationID)"
            )
            try requireProviderAbsent(
                prepared.state.id,
                observation: after
            )
            return try finalizeDelete(
                deleting,
                group: group,
                disposition: result.disposition.rawValue,
                store: store,
                repository: stateRepository
            )
        } catch {
            if let after = try? await observe(
                client,
                volumeID: prepared.state.id,
                idempotencyDomain:
                    "delete-recovery:\(prepared.request.operationID)"
            ), providerIsAbsent(
                prepared.state.id,
                observation: after
            ) {
                return try finalizeDelete(
                    deleting,
                    group: group,
                    disposition: "recovered",
                    store: store,
                    repository: stateRepository
                )
            }
            try? finishInterrupted(group, store: store)
            throw error
        }
    }

    private func replayPlanIfProviderMissing(
        state: StorageStateVolumeRecord,
        observation: LocalStorageObservation,
        store: SQLiteStateStore
    ) throws -> ProviderMissingReplay? {
        guard providerIsAbsent(state.id, observation: observation) else {
            return nil
        }
        guard !observation.ambiguousVolumeIDs.contains(state.id) else {
            throw diagnostic(
                .storageConflict,
                "The provider reports ambiguous ownership for the requested volume."
            )
        }
        switch state.lifecycleState {
        case .deleting:
            let group = try store.operationGroups.load(
                id: state.operationGroupID
            )
            guard let group,
                  group.fencingToken == state.fencingToken,
                  Self.validSHA256(group.planHash) else {
                throw diagnostic(
                    .storagePartialEffect,
                    "Provider absence cannot be finalized without the exact persisted delete operation."
                )
            }
            return ProviderMissingReplay(
                planSHA256: group.planHash,
                group: group
            )
        case .deleted:
            return ProviderMissingReplay(
                planSHA256: sha256(
                    "hostwright.storage.deleted.v1\n\(state.id)\n\(state.generation)\n\(state.fencingToken)"
                ),
                group: nil
            )
        case .creating, .available, .expanding, .faulted:
            throw diagnostic(
                .storagePartialEffect,
                "The provider volume is missing while authoritative state is not in a deletable recovery checkpoint."
            )
        }
    }

    private func finalizeProviderMissingReplay(
        _ replay: ProviderMissingReplay,
        state: StorageStateVolumeRecord,
        store: SQLiteStateStore,
        repository: StorageStateRepository
    ) throws -> CLIRunResult {
        if state.lifecycleState == .deleted {
            return completedReport(
                volumeID: state.id,
                planSHA256: replay.planSHA256,
                disposition: "already-satisfied"
            )
        }
        guard var group = replay.group else {
            throw diagnostic(
                .storagePartialEffect,
                "Delete recovery has no durable operation group."
            )
        }
        switch group.status {
        case .active:
            break
        case .interrupted:
            group = try store.operationGroups.resumeInterrupted(
                groupID: group.id,
                expectedFencingToken: group.fencingToken,
                lockOwner: Self.lockOwner,
                lockExpiresAt: hostwrightTimestampAdding(
                    seconds: 86_400,
                    to: hostwrightTimestamp()
                ),
                updatedAt: hostwrightTimestamp()
            )
        case .succeeded:
            let deleted = nextVolumeState(
                state,
                lifecycleState: .deleted,
                group: group
            )
            try repository.saveVolume(
                deleted,
                replacing: expected(state)
            )
            return completedReport(
                volumeID: state.id,
                planSHA256: replay.planSHA256,
                disposition: "recovered"
            )
        case .failed:
            throw diagnostic(
                .storagePartialEffect,
                "A failed delete operation cannot be finalized without explicit recovery authority."
            )
        }
        return try finalizeDelete(
            state,
            group: group,
            disposition: "recovered",
            store: store,
            repository: repository
        )
    }

    private func finalizeDelete(
        _ deleting: StorageStateVolumeRecord,
        group: OperationGroupRecord,
        disposition: String,
        store: SQLiteStateStore,
        repository: StorageStateRepository
    ) throws -> CLIRunResult {
        try checkpoint(
            group,
            name: "provider-absence-verified",
            verification:
                #"{"volumeID":"\#(deleting.id)"}"#,
            store: store
        )
        let deleted = nextVolumeState(
            deleting,
            lifecycleState: .deleted,
            group: group
        )
        try repository.saveVolume(
            deleted,
            replacing: expected(deleting)
        )
        try synchronizeQuota(
            for: deleted,
            lifecycleState: .released,
            group: group,
            repository: repository
        )
        try finishSucceeded(group, store: store)
        return completedReport(
            volumeID: deleted.id,
            planSHA256: group.planHash,
            disposition: disposition
        )
    }

    private func completedReport(
        volumeID: String,
        planSHA256: String,
        disposition: String
    ) -> CLIRunResult {
        let report = StorageReclaimCommandReport(
            operation: "delete",
            disposition: disposition,
            volumeIDs: [volumeID],
            planSHA256: planSHA256,
            reclaimedCapacityBytes: 0
        )
        return render(
            report,
            text: """
            Storage delete: \(disposition)
            Volume: \(volumeID)

            """
        )
    }

    private func prerequisiteProof(
        policy: StorageReclaimMode,
        state: StorageStateVolumeRecord,
        observed: LocalStorageVolumeObservation,
        observedGeneration: Int64,
        observedFence: String,
        ownershipProofSHA256: String,
        repository: StorageStateRepository,
        client: StorageProviderClient
    ) async throws -> StorageReclaimPrerequisiteProof? {
        switch policy {
        case .snapshotBeforeDelete:
            guard let record = try repository
                .loadSnapshots(sourceVolumeID: state.id)
                .filter({
                    $0.lifecycleState == .ready &&
                        $0.providerID == state.providerID
                })
                .sorted(by: {
                    ($0.updatedAt, $0.id) >
                        ($1.updatedAt, $1.id)
                })
                .first else {
                throw diagnostic(
                    .storageUnavailable,
                    "Snapshot-before-delete requires an exact ready snapshot proof in schema-v15 state."
                )
            }
            let result: LocalStorageSnapshotResult
            do {
                result = try await client.invoke(
                    operation: .snapshot,
                    mutationContext:
                        try providerContext(observed),
                    idempotencyKey: sha256(
                        [
                            "reclaim-snapshot-verify",
                            state.id,
                            record.id,
                            record.contentTreeSHA256,
                        ].joined(separator: "\n")
                    ),
                    payload: LocalStorageSnapshotPayload(
                        action: .verify,
                        snapshotID: record.id,
                        expectedContentTreeSHA256:
                            record.contentTreeSHA256
                    ),
                    result:
                        LocalStorageSnapshotResult.self
                )
            } catch {
                throw diagnostic(
                    .storageConflict,
                    "Snapshot-before-delete fresh provider integrity verification failed."
                )
            }
            guard result.snapshotID == record.id,
                  result.sourceVolumeID == state.id,
                  result.sourceGeneration ==
                    observed.generation,
                  result.sourceFencingToken ==
                    observed.fencingToken,
                  result.consistencyClass ==
                    record.consistencyClass,
                  result.parentContentTreeSHA256 ==
                    record.parentContentTreeSHA256,
                  result.contentTreeSHA256 ==
                    record.contentTreeSHA256,
                  result.lineage == record.lineage else {
                throw diagnostic(
                    .storageConflict,
                    "Snapshot-before-delete fresh provider verification did not match authoritative state."
                )
            }
            return try StorageReclaimPrerequisiteProof(
                kind: .snapshot,
                volumeID: state.id,
                generation: observedGeneration,
                fencingToken: observedFence,
                ownershipProofSHA256:
                    ownershipProofSHA256,
                artifactID: record.id,
                artifactContentSHA256:
                    result.contentTreeSHA256,
                verified: true
            )
        case .backupBeforeDelete:
            guard let record = try repository
                .loadBackups(volumeID: state.id)
                .filter({
                    $0.lifecycleState == .ready &&
                        Self.validSHA256($0.contentSHA256)
                })
                .sorted(by: {
                    ($0.updatedAt, $0.id) >
                        ($1.updatedAt, $1.id)
                })
                .first else {
                throw diagnostic(
                    .storageUnavailable,
                    "Backup-before-delete requires an exact verified backup proof in schema-v15 state."
                )
            }
            let result: LocalStorageBackupResult
            do {
                result = try await client.invoke(
                    operation: .backup,
                    mutationContext:
                        try providerContext(observed),
                    idempotencyKey: sha256(
                        [
                            "reclaim-backup-verify",
                            state.id,
                            record.id,
                            record.contentSHA256,
                        ].joined(separator: "\n")
                    ),
                    payload: LocalStorageBackupPayload(
                        action: .verify,
                        backupID: record.id,
                        volumes: [
                            LocalStorageBackupVolumePayload(
                                volumeID: state.id,
                                generation:
                                    observed.generation,
                                fencingToken:
                                    observed.fencingToken
                            ),
                        ],
                        expectedManifestSHA256:
                            record.contentSHA256
                    ),
                    result:
                        LocalStorageBackupResult.self
                )
            } catch {
                throw diagnostic(
                    .storageConflict,
                    "Backup-before-delete fresh provider integrity verification failed."
                )
            }
            guard result.backupID == record.id,
                  result.manifestSHA256 ==
                    record.contentSHA256,
                  result.verifiedVolumeIDs.contains(
                      state.id
                  ) else {
                throw diagnostic(
                    .storageConflict,
                    "Backup-before-delete fresh provider verification did not match authoritative state."
                )
            }
            return try StorageReclaimPrerequisiteProof(
                kind: .backup,
                volumeID: state.id,
                generation: observedGeneration,
                fencingToken: observedFence,
                ownershipProofSHA256:
                    ownershipProofSHA256,
                artifactID: record.id,
                artifactContentSHA256:
                    record.contentSHA256,
                verified: true
            )
        case .delete, .retain, .recycle:
            return nil
        }
    }

    private func orphanSnapshot(
        observation: LocalStorageObservation,
        state: StorageStateRepository,
        store: SQLiteStateStore
    ) throws -> OrphanSnapshot {
        let records = try state.loadVolumes()
        let activeGroups = try store.operationGroups
            .loadAll().filter {
                $0.status == .active ||
                    $0.status == .interrupted
            }
        let activeGroupIDs = Set(activeGroups.map(\.id))
        var durableOperationResourceIDs = Set(
            records.filter {
                activeGroupIDs.contains(
                    $0.operationGroupID
                )
            }.map(\.id)
        )
        for observed in observation.volumes
        where activeGroups.contains(where: {
            $0.intentJSONRedacted.contains(
                observed.volumeID
            )
        }) {
            durableOperationResourceIDs.insert(
                observed.volumeID
            )
        }
        let volumesByID = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id, $0) }
        )
        let authoritativeVolumes = try records.map {
            try StorageOrphanAuthoritativeVolume(
                volumeID: $0.id,
                providerID: $0.providerID,
                providerVolumeID: $0.providerVolumeID,
                projectID: HostwrightResourceUUID.legacy(
                    kind: "project",
                    identifier: $0.projectID
                ),
                lifecycleState:
                    orphanLifecycle($0.lifecycleState),
                reclaimPolicy:
                    localRetention($0.reclaimPolicy)
            )
        }
        var attachments: [StorageOrphanAuthoritativeAttachment] =
            []
        var snapshots: [StorageOrphanAuthoritativeSnapshot] =
            []
        var backups: [StorageOrphanAuthoritativeBackup] = []
        var holds: [StorageOrphanActiveHold] = []
        let now = timestamp(nowUnixMilliseconds())
        for volume in records {
            attachments += try state
                .loadAttachments(volumeID: volume.id)
                .map {
                    try StorageOrphanAuthoritativeAttachment(
                        attachmentID: $0.id,
                        volumeID: volume.id,
                        lifecycleState:
                            orphanAttachmentLifecycle(
                                $0.lifecycleState
                            )
                    )
                }
            holds += try state.activeHolds(
                resourceKind: .volume,
                resourceID: volume.id,
                at: now
            ).map {
                _ in
                try StorageOrphanActiveHold(
                    resourceKind: .volume,
                    resourceID: volume.id
                )
            }
            let volumeSnapshots = try state.loadSnapshots(
                sourceVolumeID: volume.id
            )
            snapshots += try volumeSnapshots.map {
                guard let lifecycleState =
                    StorageOrphanStateSnapshotLifecycle(
                        rawValue: $0.lifecycleState.rawValue
                    ) else {
                    throw HostwrightDiagnostic(
                        code: .storageInvalid,
                        message:
                            "Snapshot lifecycle state cannot be represented by orphan discovery."
                    )
                }
                return try StorageOrphanAuthoritativeSnapshot(
                    snapshotID: $0.id,
                    sourceVolumeID: $0.sourceVolumeID,
                    lifecycleState: lifecycleState
                )
            }
            durableOperationResourceIDs.formUnion(
                volumeSnapshots.filter {
                    activeGroupIDs.contains(
                        $0.operationGroupID
                    )
                }.map(\.id)
            )
            for snapshot in volumeSnapshots {
                holds += try state.activeHolds(
                    resourceKind: .snapshot,
                    resourceID: snapshot.id,
                    at: now
                ).map {
                    _ in
                    try StorageOrphanActiveHold(
                        resourceKind: .snapshot,
                        resourceID: snapshot.id
                    )
                }
            }
            let volumeBackups = try state.loadBackups(
                volumeID: volume.id
            )
            backups += try volumeBackups.map {
                guard let lifecycleState =
                    StorageOrphanStateBackupLifecycle(
                        rawValue: $0.lifecycleState.rawValue
                    ) else {
                    throw HostwrightDiagnostic(
                        code: .storageInvalid,
                        message:
                            "Backup lifecycle state cannot be represented by orphan discovery."
                    )
                }
                return try StorageOrphanAuthoritativeBackup(
                    backupID: $0.id,
                    volumeID: $0.volumeID,
                    snapshotID: $0.snapshotID,
                    lifecycleState: lifecycleState
                )
            }
            durableOperationResourceIDs.formUnion(
                volumeBackups.filter {
                    activeGroupIDs.contains(
                        $0.operationGroupID
                    )
                }.map(\.id)
            )
            for backup in volumeBackups {
                holds += try state.activeHolds(
                    resourceKind: .backup,
                    resourceID: backup.id,
                    at: now
                ).map {
                    _ in
                    try StorageOrphanActiveHold(
                        resourceKind: .backup,
                        resourceID: backup.id
                    )
                }
            }
        }
        let tracked = try state.loadOrphans(
            providerID:
                LocalStorageProviderContract.providerID
        ).map {
            try StorageOrphanTrackedRecord(
                providerID: $0.providerID,
                resourceKind:
                    orphanResourceKind($0.resourceKind),
                providerResourceIDHash:
                    $0.providerResourceIDHash,
                ownershipProofSHA256:
                    $0.ownershipProofSHA256,
                lifecycleState:
                    orphanLifecycle($0.lifecycleState),
                discoveredAtUnixMilliseconds:
                    try unixMilliseconds($0.discoveredAt),
                resolvedAtUnixMilliseconds:
                    try $0.resolvedAt.map(unixMilliseconds)
            )
        }
        return OrphanSnapshot(
            inventory: try StorageOrphanObservedInventory(
                observation
            ),
            authoritativeState:
                try StorageOrphanAuthoritativeState(
                    volumes: authoritativeVolumes,
                    attachments: attachments,
                    snapshots: snapshots,
                    backups: backups,
                    activeHolds: holds,
                    durableOperationResourceIDs:
                        Array(
                            durableOperationResourceIDs
                        ),
                    trackedOrphans: tracked
                ),
            volumesByID: volumesByID
        )
    }

    private func exactPruneCandidates(
        _ findings: [StorageOrphanFinding],
        observation: LocalStorageObservation,
        volumesByID: [String: StorageStateVolumeRecord]
    ) throws -> [PruneCandidate] {
        guard findings.count <= Self.maximumPlanResources else {
            throw diagnostic(
                .storageConflict,
                "The prune plan exceeded its bounded resource selection."
            )
        }
        return try findings.map { finding in
            guard finding.resourceKind == .volume,
                  finding.isEligibleForReclaim else {
                throw diagnostic(
                    .storageConflict,
                    "The prune engine selected a resource without exact reclaim eligibility."
                )
            }
            let matches = observation.volumes.filter {
                orphanResourceHash(
                    providerID: $0.providerID,
                    kind: .volume,
                    providerResourceID: $0.volumeID
                ) == finding.providerResourceIDHash
            }
            guard matches.count == 1,
                  let observed = matches.first,
                  let state = volumesByID[observed.volumeID],
                  state.lifecycleState == .deleted,
                  state.id == observed.volumeID,
                  state.providerVolumeID == observed.volumeID,
                  state.providerID == observed.providerID,
                  HostwrightResourceUUID.legacy(
                    kind: "project",
                    identifier: state.projectID
                  ) == observed.projectID,
                  state.generation ==
                    Int64(observed.generation),
                  state.fencingToken ==
                    observed.fencingToken,
                  state.reclaimPolicy != .retain,
                  state.reclaimPolicy != .recycle,
                  state.capacityBytes ==
                    observed.capacityBytes,
                  observed.attachments.isEmpty else {
                throw diagnostic(
                    .storageConflict,
                    "A prune candidate lacks exact current UUID, project, generation, fence, ownership, or attachment proof."
                )
            }
            return PruneCandidate(
                finding: finding,
                state: state,
                observed: observed
            )
        }.sorted { $0.state.id < $1.state.id }
    }

    private func garbageCollectionPlan(
        candidates: [PruneCandidate],
        report: StorageOrphanReport
    ) throws -> StorageGCPlan {
        var targetBytes: Int64 = 0
        var targetInodes: Int64 = 0
        let gcCandidates = try candidates.map { candidate in
            let bytes = targetBytes.addingReportingOverflow(
                candidate.finding.reclaimableBytes
            )
            let inodes = targetInodes.addingReportingOverflow(1)
            guard !bytes.overflow,
                  !inodes.overflow,
                  bytes.partialValue <=
                    StorageCapacityLimits.maximumBytes,
                  inodes.partialValue <=
                    StorageCapacityLimits.maximumInodes else {
                throw diagnostic(
                    .storageConflict,
                    "The prioritized storage GC target exceeded bounded accounting."
                )
            }
            targetBytes = bytes.partialValue
            targetInodes = inodes.partialValue
            return try StorageGCCandidate(
                resourceID: candidate.state.id,
                kind: .orphan,
                reclaimPolicy: .delete,
                reclaimableBytes:
                    candidate.finding.reclaimableBytes,
                reclaimableInodes: 1,
                hasActiveHold: false,
                hasActiveAttachment:
                    !candidate.observed.attachments.isEmpty,
                disruptionBudgetAllows:
                    candidate.state.lifecycleState == .deleted,
                ownershipProofSHA256:
                    candidate.finding
                        .ownershipProofSHA256,
                disruptionPolicySHA256: sha256(
                    [
                        "hostwright.storage.gc-disruption.v1",
                        candidate.state.id,
                        "requires-deleted-unattached",
                    ].joined(separator: "\n")
                ),
                generation:
                    candidate.state.generation,
                fencingToken:
                    candidate.state.fencingToken,
                lastUsedAtUnixMilliseconds:
                    candidate.finding
                        .discoveredAtUnixMilliseconds
            )
        }
        do {
            return try StorageCapacityPolicy()
                .planGarbageCollection(
                    candidates: gcCandidates,
                    targetBytes: targetBytes,
                    targetInodes: targetInodes,
                    maximumItems: max(
                        candidates.count,
                        1
                    ),
                    sampleDigestSHA256:
                        try canonicalSHA256(report)
                )
        } catch let diagnostic as HostwrightDiagnostic {
            throw diagnostic
        } catch {
            throw diagnostic(
                .storageConflict,
                "Storage pressure GC planning refused the exact owned reclaim set."
            )
        }
    }

    private func persistFindings(
        _ findings: [StorageOrphanFinding],
        group: OperationGroupRecord,
        repository: StorageStateRepository
    ) throws -> [String: StorageStateOrphanRecord] {
        let existing = try repository.loadOrphans(
            providerID:
                LocalStorageProviderContract.providerID
        )
        let existingByKey = Dictionary(
            uniqueKeysWithValues: existing.map {
                (
                    orphanKey(
                        providerID: $0.providerID,
                        kind: orphanResourceKind(
                            $0.resourceKind
                        ),
                        hash:
                            $0.providerResourceIDHash
                    ),
                    $0
                )
            }
        )
        var result: [String: StorageStateOrphanRecord] = [:]
        for finding in findings {
            let key = orphanKey(
                providerID: finding.providerID,
                kind: finding.resourceKind,
                hash: finding.providerResourceIDHash
            )
            let prior = existingByKey[key]
            if let prior,
               prior.operationGroupID == group.id {
                guard prior.fencingToken == group.fencingToken,
                      prior.providerID == finding.providerID,
                      prior.resourceKind ==
                        stateOrphanResourceKind(
                            finding.resourceKind
                        ),
                      prior.providerResourceIDHash ==
                        finding.providerResourceIDHash,
                      prior.ownershipProofSHA256 ==
                        finding.ownershipProofSHA256 else {
                    throw diagnostic(
                        .storageConflict,
                        "Persisted orphan classification changed within the same prune operation."
                    )
                }
                result[key] = prior
                continue
            }
            let record = StorageStateOrphanRecord(
                id: prior?.id ??
                    HostwrightResourceUUID.legacy(
                        kind: "storage-orphan",
                        identifier: key
                    ),
                providerID: finding.providerID,
                resourceKind:
                    stateOrphanResourceKind(
                        finding.resourceKind
                    ),
                providerResourceIDHash:
                    finding.providerResourceIDHash,
                ownershipProofSHA256:
                    finding.ownershipProofSHA256,
                generation: (prior?.generation ?? 0) + 1,
                fencingToken: group.fencingToken,
                lifecycleState:
                    stateOrphanLifecycle(
                        finding.lifecycleState
                    ),
                operationGroupID: group.id,
                discoveredAt:
                    prior?.discoveredAt ??
                        timestamp(
                            finding
                                .discoveredAtUnixMilliseconds
                        ),
                resolvedAt:
                    finding.lifecycleState == .ignored ||
                        finding.lifecycleState == .reclaimed
                        ? timestamp(nowUnixMilliseconds())
                        : nil
            )
            try repository.saveOrphan(
                record,
                replacing: prior.map(expected)
            )
            result[key] = record
        }
        let activeKeys = Set(result.keys)
        for prior in existing where !activeKeys.contains(
            orphanKey(
                providerID: prior.providerID,
                kind: orphanResourceKind(prior.resourceKind),
                hash: prior.providerResourceIDHash
            )
        ) {
            guard prior.lifecycleState != .ignored,
                  prior.lifecycleState != .reclaimed else {
                continue
            }
            let resolved = StorageStateOrphanRecord(
                id: prior.id,
                providerID: prior.providerID,
                resourceKind: prior.resourceKind,
                providerResourceIDHash:
                    prior.providerResourceIDHash,
                ownershipProofSHA256:
                    prior.ownershipProofSHA256,
                generation: prior.generation + 1,
                fencingToken: group.fencingToken,
                lifecycleState: .ignored,
                operationGroupID: group.id,
                discoveredAt: prior.discoveredAt,
                resolvedAt: timestamp(nowUnixMilliseconds())
            )
            try repository.saveOrphan(
                resolved,
                replacing: expected(prior)
            )
        }
        return result
    }

    private func markOrphanReclaimed(
        _ record: StorageStateOrphanRecord,
        group: OperationGroupRecord,
        repository: StorageStateRepository
    ) throws {
        if record.lifecycleState == .reclaimed {
            guard record.operationGroupID == group.id,
                  record.fencingToken == group.fencingToken else {
                throw diagnostic(
                    .storageConflict,
                    "A reclaimed orphan record belongs to different mutation authority."
                )
            }
            return
        }
        let reclaimed = StorageStateOrphanRecord(
            id: record.id,
            providerID: record.providerID,
            resourceKind: record.resourceKind,
            providerResourceIDHash:
                record.providerResourceIDHash,
            ownershipProofSHA256:
                record.ownershipProofSHA256,
            generation: record.generation + 1,
            fencingToken: group.fencingToken,
            lifecycleState: .reclaimed,
            operationGroupID: group.id,
            discoveredAt: record.discoveredAt,
            resolvedAt: timestamp(nowUnixMilliseconds())
        )
        try repository.saveOrphan(
            reclaimed,
            replacing: expected(record)
        )
    }

    private func markPersistedOrphanReclaimed(
        _ candidate: PruneCandidateIntent,
        persisted: [String: StorageStateOrphanRecord],
        group: OperationGroupRecord,
        repository: StorageStateRepository
    ) throws {
        let key = orphanKey(
            providerID: candidate.finding.providerID,
            kind: candidate.finding.resourceKind,
            hash: candidate.finding.providerResourceIDHash
        )
        guard let orphan = persisted[key] else {
            throw diagnostic(
                .storagePartialEffect,
                "The exact persisted orphan classification is missing during prune recovery."
            )
        }
        try markOrphanReclaimed(
            orphan,
            group: group,
            repository: repository
        )
    }

    private func finalizePrunedVolume(
        _ record: StorageStateVolumeRecord,
        group: OperationGroupRecord,
        repository: StorageStateRepository
    ) throws {
        let deleted = nextVolumeState(
            record,
            lifecycleState: .deleted,
            group: group
        )
        try repository.saveVolume(
            deleted,
            replacing: expected(record)
        )
        try synchronizeQuota(
            for: deleted,
            lifecycleState: .released,
            group: group,
            repository: repository
        )
    }

    private func synchronizeQuota(
        for volume: StorageStateVolumeRecord,
        lifecycleState:
            StorageQuotaLifecycleState,
        group: OperationGroupRecord,
        repository: StorageStateRepository
    ) throws {
        let quotaID = HostwrightResourceUUID.legacy(
            kind: "storage-quota",
            identifier: volume.id
        )
        guard var current = try repository.loadQuota(
            id: quotaID
        ) else {
            return
        }
        guard current.resourceID == volume.id,
              current.providerID == volume.providerID,
              current.generation <= volume.generation else {
            throw diagnostic(
                .storageConflict,
                "The persisted quota no longer matches the exact volume generation."
            )
        }
        if current.generation == volume.generation {
            guard current.lifecycleState ==
                    lifecycleState,
                  current.fencingToken ==
                    volume.fencingToken else {
                throw diagnostic(
                    .storageConflict,
                    "The persisted quota has conflicting lifecycle or fencing state."
                )
            }
            return
        }

        while current.generation < volume.generation {
            let nextGeneration = current.generation + 1
            let nextLifecycle:
                StorageQuotaLifecycleState =
                nextGeneration == volume.generation
                    ? lifecycleState
                    : .releasing
            let next = StorageStateQuotaRecord(
                id: current.id,
                resourceID: current.resourceID,
                providerID: current.providerID,
                byteLimit: current.byteLimit,
                inodeLimit: current.inodeLimit,
                enforcementMode:
                    current.enforcementMode,
                enforcementEvidenceSHA256:
                    current
                        .enforcementEvidenceSHA256,
                generation: nextGeneration,
                fencingToken: volume.fencingToken,
                lifecycleState: nextLifecycle,
                retryAttempt: current.retryAttempt,
                recoveryCheckpoint: .admitted,
                operationID: group.operationID,
                idempotencyKey: sha256(
                    "quota-reclaim:\(volume.id):\(nextGeneration)"
                ),
                operationGroupID: group.id,
                createdAt: current.createdAt,
                updatedAt: hostwrightTimestamp()
            )
            try repository.saveQuota(
                next,
                replacing:
                    StorageStateExpectedVersion(
                        generation:
                            current.generation,
                        fencingToken:
                            current.fencingToken
                    )
            )
            current = next
        }
    }

    private func isFinalizedPruneState(
        _ current: StorageStateVolumeRecord,
        original: StorageStateVolumeRecord,
        group: OperationGroupRecord
    ) -> Bool {
        current.id == original.id &&
            current.projectID == original.projectID &&
            current.name == original.name &&
            current.providerID == original.providerID &&
            current.providerVolumeID ==
                original.providerVolumeID &&
            current.topologyNodeID == original.topologyNodeID &&
            current.generation == original.generation + 1 &&
            current.fencingToken == group.fencingToken &&
            current.capacityBytes == original.capacityBytes &&
            current.lifecycleState == .deleted &&
            current.reclaimPolicy == original.reclaimPolicy &&
            current.accessMode == original.accessMode &&
            current.sourceKind == original.sourceKind &&
            current.sourceID == original.sourceID &&
            current.operationGroupID == group.id &&
            current.createdAt == original.createdAt
    }

    private func addingCapacity(
        _ capacityBytes: Int64,
        to total: Int64
    ) -> Int64 {
        let (sum, overflow) =
            total.addingReportingOverflow(capacityBytes)
        return overflow ? Int64.max : sum
    }

    private func acquireDeleteOperation(
        _ prepared: PreparedDelete,
        operationPlanSHA256: String,
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        if prepared.state.lifecycleState == .deleting,
           let existing = try store.operationGroups.load(
               id: prepared.state.operationGroupID
           ) {
            guard existing.planHash ==
                    operationPlanSHA256,
                  existing.fencingToken ==
                    prepared.state.fencingToken else {
                throw diagnostic(
                    .storageConflict,
                    "The interrupted delete operation has different plan or fencing authority."
                )
            }
            switch existing.status {
            case .active:
                return existing
            case .interrupted:
                return try store.operationGroups.resumeInterrupted(
                    groupID: existing.id,
                    expectedFencingToken:
                        existing.fencingToken,
                    lockOwner: Self.lockOwner,
                    lockExpiresAt:
                        hostwrightTimestampAdding(
                            seconds: 86_400,
                            to: hostwrightTimestamp()
                        ),
                    updatedAt: hostwrightTimestamp()
                )
            case .succeeded, .failed:
                throw diagnostic(
                    .storagePartialEffect,
                    "A terminal delete operation is inconsistent with deleting volume state."
                )
            }
        }
        let now = hostwrightTimestamp()
        let operationFence = HostwrightResourceUUID.legacy(
            kind: "storage-reclaim-fence",
            identifier: prepared.request.operationID
        )
        let group = OperationGroupRecord(
            id: prepared.request.operationID,
            operationID: prepared.request.operationID,
            groupKind: "storage-reclaim",
            projectID: prepared.state.projectID,
            serviceName: nil,
            plannedActionType: "delete",
            status: .active,
            groupIdempotencyKey:
                prepared.request.idempotencySHA256,
            planHash: operationPlanSHA256,
            checkpoint: "intent-persisted",
            lockOwner: Self.lockOwner,
            lockExpiresAt: hostwrightTimestampAdding(
                seconds: 86_400,
                to: now
            ),
            rollbackAvailable: false,
            manualRecoveryHintRedacted:
                "Re-observe the exact provider volume before resuming deletion.",
            createdAt: now,
            updatedAt: now,
            metadataJSONRedacted:
                #"{"resource":"volume","workflow":"reclaim"}"#,
            fencingToken: operationFence,
            intentJSONRedacted:
                (try? canonicalJSONString(
                    DeleteOperationIntent(
                        request: prepared.request,
                        plan: prepared.plan,
                        observedProviderGeneration:
                            prepared.observed.generation,
                        observedProviderFencingToken:
                            prepared.observed.fencingToken
                    )
                )) ??
                    "{}",
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        return try acquire(group, store: store)
    }

    private func resumeInterruptedPrune(
        planSHA256: String,
        client: StorageProviderClient,
        context: StateContext
    ) async throws -> CLIRunResult? {
        let groupID = pruneGroupID(planSHA256)
        guard var existing = try context.store.operationGroups
            .load(id: groupID) else {
            return nil
        }
        guard existing.groupKind == "storage-orphan-prune",
              existing.plannedActionType == "prune",
              existing.planHash == planSHA256,
              existing.fencingToken ==
                pruneFence(groupID),
              existing.groupIdempotencyKey ==
                pruneIdempotencySHA256(planSHA256) else {
            throw diagnostic(
                .storageConflict,
                "The persisted prune operation does not match its exact recovery authority."
            )
        }
        if existing.status == .active {
            guard Self.abandonedLocalOwner(
                existing.lockOwner
            ) else {
                throw diagnostic(
                    .storageConflict,
                    "The exact storage prune operation still has a live or unverifiable owner."
                )
            }
            try context.store.operationGroups.finish(
                groupID: existing.id,
                status: .interrupted,
                checkpoint: existing.checkpoint,
                manualRecoveryHintRedacted:
                    "The prior local prune process exited; resume from exact persisted intent.",
                updatedAt: hostwrightTimestamp(),
                metadataJSONRedacted:
                    #"{"result":"abandoned-local-owner"}"#
            )
            guard let reloaded = try context.store.operationGroups
                .load(id: groupID) else {
                throw diagnostic(
                    .storagePartialEffect,
                    "The abandoned prune operation disappeared before exact recovery."
                )
            }
            existing = reloaded
        }
        guard existing.status == .interrupted else {
            return nil
        }
        let intent: PruneOperationIntent
        do {
            intent = try JSONDecoder().decode(
                PruneOperationIntent.self,
                from: Data(
                    existing.intentJSONRedacted.utf8
                )
            )
            guard try canonicalJSONString(intent) ==
                    existing.intentJSONRedacted else {
                throw diagnostic(
                    .storagePartialEffect,
                    "The interrupted prune intent is not canonical exact recovery evidence."
                )
            }
            try validatePruneIntent(
                intent,
                planSHA256: planSHA256
            )
        } catch let diagnostic as HostwrightDiagnostic {
            throw diagnostic
        } catch {
            throw diagnostic(
                .storagePartialEffect,
                "The interrupted prune operation lacks valid exact candidate recovery evidence."
            )
        }
        let resumed = try context.store.operationGroups
            .resumeInterrupted(
                groupID: existing.id,
                expectedFencingToken:
                    existing.fencingToken,
                lockOwner: Self.lockOwner,
                lockExpiresAt:
                    hostwrightTimestampAdding(
                        seconds: 86_400,
                        to: hostwrightTimestamp()
                    ),
                updatedAt: hostwrightTimestamp()
            )
        return try await executePrune(
            intent,
            group: resumed,
            client: client,
            context: context,
            resumed: true
        )
    }

    private static func abandonedLocalOwner(
        _ owner: String?
    ) -> Bool {
        let prefix = "hostwright-storage-reclaim:"
        guard let owner,
              owner.hasPrefix(prefix),
              let rawPID = Int32(owner.dropFirst(prefix.count)),
              rawPID > 0,
              rawPID != getpid() else {
            return false
        }
        errno = 0
        if Darwin.kill(rawPID, 0) == 0 || errno == EPERM {
            return false
        }
        return errno == ESRCH
    }

    private func validatePruneIntent(
        _ intent: PruneOperationIntent,
        planSHA256: String
    ) throws {
        let selectedIDs =
            intent.garbageCollectionPlan.selected.map(
                \.resourceID
            )
        let orderedFindings =
            intent.candidates.map(\.finding).sorted {
                (
                    $0.providerID,
                    $0.resourceKind.rawValue,
                    $0.providerResourceIDHash
                ) < (
                    $1.providerID,
                    $1.resourceKind.rawValue,
                    $1.providerResourceIDHash
                )
            }
        let recomputedGC: StorageGCPlan
        do {
            recomputedGC = try StorageCapacityPolicy()
                .planGarbageCollection(
                    candidates:
                        intent.garbageCollectionPlan
                            .selected,
                    targetBytes:
                        intent.garbageCollectionPlan
                            .targetBytes,
                    targetInodes:
                        intent.garbageCollectionPlan
                            .targetInodes,
                    maximumItems: max(
                        intent.garbageCollectionPlan
                            .selected.count,
                        1
                    ),
                    sampleDigestSHA256:
                        intent.garbageCollectionPlan
                            .sampleDigestSHA256,
                    policyDigestSHA256:
                        intent.garbageCollectionPlan
                            .policyDigestSHA256
                )
        } catch {
            throw diagnostic(
                .storageConflict,
                "The interrupted prune intent contains an invalid pressure GC plan."
            )
        }
        let expectedAuthorization = sha256(
            [
                "hostwright.storage.pressure-prune.v1",
                intent.report.reclaimPlan
                    .confirmationSHA256,
                intent.garbageCollectionPlan
                    .confirmationSHA256,
            ].joined(separator: "\n")
        )
        guard intent.authorizationPlanSHA256 ==
                planSHA256,
              expectedAuthorization == planSHA256,
              recomputedGC ==
                intent.garbageCollectionPlan,
              intent.candidates.count <=
                Self.maximumPlanResources,
              Set(intent.candidates.map(\.state.id)).count ==
                intent.candidates.count,
              intent.candidates.map(\.state.id) ==
                selectedIDs,
              orderedFindings ==
                intent.report.reclaimPlan.entries else {
            throw diagnostic(
                .storageConflict,
                "The interrupted prune intent differs from its confirmed exact plan."
            )
        }
        for candidate in intent.candidates {
            let state = candidate.state
            let mutation = candidate.providerMutationContext
            guard candidate.finding.isEligibleForReclaim,
                  candidate.finding.resourceKind == .volume,
                  state.lifecycleState == .deleted,
                  state.id == state.providerVolumeID,
                  state.providerID ==
                    candidate.finding.providerID,
                  state.reclaimPolicy != .retain,
                  state.reclaimPolicy != .recycle,
                  Self.validSHA256(
                      candidate.observedSHA256
                  ),
                  orphanResourceHash(
                      providerID: state.providerID,
                      kind: .volume,
                      providerResourceID:
                        state.providerVolumeID
                  ) ==
                    candidate.finding
                        .providerResourceIDHash,
                  UUID(uuidString: state.id) != nil,
                  UUID(
                      uuidString: state.fencingToken
                  ) != nil,
                  mutation.isValid,
                  mutation.projectUUID.uuidString.lowercased() ==
                    HostwrightResourceUUID.legacy(
                        kind: "project",
                        identifier: state.projectID
                    ),
                  mutation.resourceUUID.uuidString.lowercased() ==
                    state.id,
                  mutation.resourceGeneration ==
                    Int(state.generation),
                  mutation.fencingToken.uuidString.lowercased() ==
                    state.fencingToken else {
                throw diagnostic(
                    .storageConflict,
                    "The interrupted prune intent lacks exact UUID, ownership, generation, fence, or observation proof."
                )
            }
        }
    }

    private func acquirePruneOperation(
        planSHA256: String,
        intent: PruneOperationIntent,
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        let groupID = pruneGroupID(planSHA256)
        let fence = pruneFence(groupID)
        let now = hostwrightTimestamp()
        let group = OperationGroupRecord(
            id: groupID,
            operationID: groupID,
            groupKind: "storage-orphan-prune",
            projectID: nil,
            serviceName: nil,
            plannedActionType: "prune",
            status: .active,
            groupIdempotencyKey:
                pruneIdempotencySHA256(planSHA256),
            planHash: planSHA256,
            checkpoint: "intent-persisted",
            lockOwner: Self.lockOwner,
            lockExpiresAt: hostwrightTimestampAdding(
                seconds: 86_400,
                to: now
            ),
            rollbackAvailable: false,
            manualRecoveryHintRedacted:
                "Re-run prune observation with the exact prior plan.",
            createdAt: now,
            updatedAt: now,
            metadataJSONRedacted:
                #"{"resource":"orphan","workflow":"prune"}"#,
            fencingToken: fence,
            intentJSONRedacted:
                try canonicalJSONString(intent),
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        return try acquire(group, store: store)
    }

    private func pruneGroupID(_ planSHA256: String) -> String {
        HostwrightResourceUUID.legacy(
            kind: "storage-prune-operation",
            identifier: planSHA256
        )
    }

    private func pruneFence(_ groupID: String) -> String {
        HostwrightResourceUUID.legacy(
            kind: "storage-prune-fence",
            identifier: groupID
        )
    }

    private func pruneIdempotencySHA256(
        _ planSHA256: String
    ) -> String {
        sha256(
            "hostwright.storage.prune.v1\n\(planSHA256)"
        )
    }

    private func acquire(
        _ group: OperationGroupRecord,
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        if let existing = try store.operationGroups.load(id: group.id) {
            guard existing.planHash == group.planHash,
                  existing.fencingToken ==
                    group.fencingToken,
                  existing.groupIdempotencyKey ==
                    group.groupIdempotencyKey else {
                throw diagnostic(
                    .storageConflict,
                    "A prior reclaim operation reused identity with different authority."
                )
            }
            switch existing.status {
            case .active:
                return existing
            case .interrupted:
                return try store.operationGroups.resumeInterrupted(
                    groupID: existing.id,
                    expectedFencingToken:
                        existing.fencingToken,
                    lockOwner: Self.lockOwner,
                    lockExpiresAt:
                        hostwrightTimestampAdding(
                            seconds: 86_400,
                            to: hostwrightTimestamp()
                        ),
                    updatedAt: hostwrightTimestamp()
                )
            case .succeeded:
                throw diagnostic(
                    .storageConflict,
                    "The exact reclaim plan was already completed."
                )
            case .failed:
                throw diagnostic(
                    .storagePartialEffect,
                    "The exact reclaim plan is terminally failed and requires recovery."
                )
            }
        }
        let acquired = try store.operationGroups.acquire(
            group,
            currentTimestamp: hostwrightTimestamp()
        )
        if let value = acquired.acquired {
            return value
        }
        guard let existing = acquired.existingActive,
              existing.id == group.id,
              existing.planHash == group.planHash,
              existing.fencingToken == group.fencingToken else {
            throw diagnostic(
                .storageConflict,
                "Another active operation owns the storage mutation authority."
            )
        }
        return existing
    }

    private func observe(
        _ client: StorageProviderClient,
        volumeID: String?,
        idempotencyDomain: String
    ) async throws -> LocalStorageObservation {
        let full: LocalStorageObservation = try await client.invoke(
            operation: .observe,
            idempotencyKey: sha256(
                [
                    "hostwright.storage.reclaim-observe.v1",
                    idempotencyDomain,
                    volumeID ?? "all",
                ].joined(separator: "\n")
            ),
            payload: LocalStorageObservePayload(),
            result: LocalStorageObservation.self
        )
        guard let volumeID else {
            return full
        }
        return LocalStorageObservation(
            volumes: full.volumes.filter {
                $0.volumeID == volumeID
            },
            unmanagedEntries: full.unmanagedEntries,
            ambiguousVolumeIDs: full.ambiguousVolumeIDs,
            pendingRecoveryIDs: full.pendingRecoveryIDs,
            totalCapacityBytes: full.totalCapacityBytes,
            reservedCapacityBytes:
                full.reservedCapacityBytes
        )
    }

    private func requireExactObservedVolume(
        _ state: StorageStateVolumeRecord,
        observation: LocalStorageObservation,
        allowDeletingGeneration: Bool
    ) throws -> LocalStorageVolumeObservation {
        guard !observation.ambiguousVolumeIDs.contains(state.id),
              observation.volumes.count == 1,
              let observed = observation.volumes.first,
              observed.volumeID == state.id,
              observed.providerID == state.providerID,
              state.providerVolumeID == observed.volumeID,
              observed.projectID ==
                HostwrightResourceUUID.legacy(
                    kind: "project",
                    identifier: state.projectID
                ),
              observed.name == state.name,
              observed.capacityBytes == state.capacityBytes,
              observed.fencingToken == state.fencingToken,
              localRetention(state.reclaimPolicy) ==
                observed.retention else {
            throw diagnostic(
                .storageConflict,
                "The provider observation does not exactly match authoritative UUID, project, ownership, fence, capacity, or policy state."
            )
        }
        let generationMatches =
            state.generation == Int64(observed.generation)
        let interruptedDeleteMatches =
            allowDeletingGeneration &&
                state.lifecycleState == .deleting &&
                state.generation ==
                    Int64(observed.generation) + 1
        guard generationMatches || interruptedDeleteMatches else {
            throw diagnostic(
                .storageConflict,
                "The provider volume generation changed after authoritative state was recorded."
            )
        }
        return observed
    }

    private func providerContext(
        _ volume: LocalStorageVolumeObservation
    ) throws -> StorageProviderMutationContext {
        guard let project = UUID(uuidString: volume.projectID),
              let resource = UUID(uuidString: volume.volumeID),
              let fence = UUID(
                  uuidString: volume.fencingToken
              ) else {
            throw diagnostic(
                .storageConflict,
                "The provider returned non-canonical volume ownership authority."
            )
        }
        return StorageProviderMutationContext(
            projectUUID: project,
            projectGeneration: volume.projectGeneration,
            resourceUUID: resource,
            resourceGeneration: volume.generation,
            fencingToken: fence
        )
    }

    private func requireProviderAbsent(
        _ volumeID: String,
        observation: LocalStorageObservation
    ) throws {
        guard providerIsAbsent(
            volumeID,
            observation: observation
        ) else {
            throw diagnostic(
                .storagePartialEffect,
                "The provider did not prove exact volume absence after deletion."
            )
        }
    }

    private func providerIsAbsent(
        _ volumeID: String,
        observation: LocalStorageObservation
    ) -> Bool {
        !observation.ambiguousVolumeIDs.contains(volumeID) &&
            !observation.volumes.contains {
                $0.volumeID == volumeID
            }
    }

    private func nextVolumeState(
        _ current: StorageStateVolumeRecord,
        lifecycleState: StorageVolumeLifecycleState,
        group: OperationGroupRecord
    ) -> StorageStateVolumeRecord {
        StorageStateVolumeRecord(
            id: current.id,
            projectID: current.projectID,
            name: current.name,
            providerID: current.providerID,
            providerVolumeID: current.providerVolumeID,
            topologyNodeID: current.topologyNodeID,
            generation: current.generation + 1,
            fencingToken: group.fencingToken,
            capacityBytes: current.capacityBytes,
            lifecycleState: lifecycleState,
            reclaimPolicy: current.reclaimPolicy,
            accessMode: current.accessMode,
            sourceKind: current.sourceKind,
            sourceID: current.sourceID,
            operationGroupID: group.id,
            createdAt: current.createdAt,
            updatedAt: timestamp(nowUnixMilliseconds())
        )
    }

    private func checkpoint(
        _ group: OperationGroupRecord,
        name: String,
        verification: String,
        store: SQLiteStateStore
    ) throws {
        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: name,
            verificationJSONRedacted: verification,
            updatedAt: hostwrightTimestamp()
        )
    }

    private func finishSucceeded(
        _ group: OperationGroupRecord,
        store: SQLiteStateStore
    ) throws {
        guard try store.operationGroups.load(id: group.id)?
            .status == .active else {
            return
        }
        try store.operationGroups.finish(
            groupID: group.id,
            status: .succeeded,
            checkpoint: "state-committed",
            manualRecoveryHintRedacted: "",
            updatedAt: hostwrightTimestamp(),
            metadataJSONRedacted:
                #"{"result":"succeeded"}"#
        )
    }

    private func finishInterrupted(
        _ group: OperationGroupRecord,
        store: SQLiteStateStore
    ) throws {
        guard try store.operationGroups.load(id: group.id)?
            .status == .active else {
            return
        }
        try store.operationGroups.finish(
            groupID: group.id,
            status: .interrupted,
            checkpoint: "recovery-required",
            manualRecoveryHintRedacted:
                "Re-observe exact storage ownership before resuming.",
            updatedAt: hostwrightTimestamp(),
            metadataJSONRedacted:
                #"{"result":"interrupted"}"#
        )
    }

    private func requireConfirmation(
        _ confirmation: StorageDestructiveCLIOptions,
        planSHA256: String
    ) throws {
        guard confirmation.confirmationPlanSHA256 ==
                planSHA256 else {
            throw diagnostic(
                .storageConflict,
                "The exact storage plan changed; run the dry-run again."
            )
        }
    }

    private func renderPlan(
        operation: String,
        volumeIDs: [String],
        planSHA256: String
    ) -> CLIRunResult {
        let report = StorageReclaimCommandReport(
            operation: operation,
            disposition: "dry-run",
            volumeIDs: volumeIDs.sorted(),
            planSHA256: planSHA256,
            reclaimedCapacityBytes: 0
        )
        return render(
            report,
            text: """
            Storage \(operation) plan
            Resources: \(volumeIDs.isEmpty ? "none" : volumeIDs.sorted().joined(separator: ", "))
            Confirm with: --confirm-plan \(planSHA256)

            """
        )
    }

    private func render<T: Encodable>(
        _ report: T,
        text: String
    ) -> CLIRunResult {
        CLIRunResult(
            standardOutput:
                options.output == .json
                    ? CLIJSON.codable(report)
                    : text
        )
    }

    private func reclaimDiagnostic(
        _ error: StorageReclaimError
    ) -> HostwrightDiagnostic {
        let code: HostwrightErrorCode
        switch error.code {
        case .prerequisiteUnavailable,
             .missingPrerequisiteProof,
             .mismatchedPrerequisiteProof:
            code = .storageUnavailable
        case .invalidArgument:
            code = .storageInvalid
        case .activeAttachment,
             .activeHold,
             .ambiguousOwnership,
             .missingOwnershipProof,
             .stalePlan,
             .confirmationMismatch,
             .invalidCheckpoint:
            code = .storageConflict
        }
        return diagnostic(code, error.message)
    }

    private func diagnostic(
        _ code: HostwrightErrorCode,
        _ message: String
    ) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: code, message: message)
    }

    private func ownershipProofSHA256(
        state: StorageStateVolumeRecord,
        observed: LocalStorageVolumeObservation
    ) -> String {
        sha256(
            [
                "hostwright.storage.reclaim-ownership.v1",
                state.id,
                state.providerID,
                state.providerVolumeID,
                state.projectID,
                observed.projectID,
                String(observed.projectGeneration),
                String(observed.generation),
                observed.fencingToken,
                state.name,
                String(state.capacityBytes),
                state.reclaimPolicy.rawValue,
            ].joined(separator: "\n")
        )
    }

    private func orphanResourceHash(
        providerID: String,
        kind: HostwrightStorage.StorageOrphanResourceKind,
        providerResourceID: String
    ) -> String {
        sha256(
            [
                "hostwright.storage.orphan-resource-id.v1",
                providerID,
                kind.rawValue,
                providerResourceID,
            ].joined(separator: "\n")
        )
    }

    private func orphanKey(
        providerID: String,
        kind: HostwrightStorage.StorageOrphanResourceKind,
        hash: String
    ) -> String {
        "\(providerID)\n\(kind.rawValue)\n\(hash)"
    }

    private func reclaimMode(
        _ policy: StorageReclaimPolicy
    ) -> StorageReclaimMode {
        switch policy {
        case .retain:
            .retain
        case .delete:
            .delete
        case .snapshotBeforeDelete:
            .snapshotBeforeDelete
        case .backupBeforeDelete:
            .backupBeforeDelete
        case .recycle:
            .recycle
        }
    }

    private func localRetention(
        _ policy: StorageReclaimPolicy
    ) -> LocalStorageRetentionPolicy {
        switch policy {
        case .retain, .recycle:
            .retain
        case .delete, .snapshotBeforeDelete,
             .backupBeforeDelete:
            .deleteWhenUnused
        }
    }

    private func orphanLifecycle(
        _ value: StorageVolumeLifecycleState
    ) -> StorageOrphanStateVolumeLifecycle {
        switch value {
        case .creating:
            .creating
        case .available:
            .available
        case .expanding:
            .expanding
        case .deleting:
            .deleting
        case .deleted:
            .deleted
        case .faulted:
            .faulted
        }
    }

    private func orphanAttachmentLifecycle(
        _ value: StorageAttachmentLifecycleState
    ) -> StorageOrphanStateAttachmentLifecycle {
        switch value {
        case .attaching:
            .attaching
        case .attached:
            .attached
        case .detaching:
            .detaching
        case .detached:
            .detached
        case .faulted:
            .faulted
        case .ambiguousHold:
            .ambiguousHold
        }
    }

    private func orphanResourceKind(
        _ value: HostwrightState.StorageOrphanResourceKind
    ) -> HostwrightStorage.StorageOrphanResourceKind {
        switch value {
        case .volume:
            .volume
        case .attachment:
            .attachment
        case .snapshot:
            .snapshot
        case .backup:
            .backup
        }
    }

    private func stateOrphanResourceKind(
        _ value: HostwrightStorage.StorageOrphanResourceKind
    ) -> HostwrightState.StorageOrphanResourceKind {
        switch value {
        case .volume:
            .volume
        case .attachment:
            .attachment
        case .snapshot:
            .snapshot
        case .backup:
            .backup
        }
    }

    private func orphanLifecycle(
        _ value: HostwrightState.StorageOrphanLifecycleState
    ) -> HostwrightStorage.StorageOrphanLifecycleState {
        switch value {
        case .discovered:
            .discovered
        case .held:
            .held
        case .reclaimed:
            .reclaimed
        case .ignored:
            .ignored
        }
    }

    private func stateOrphanLifecycle(
        _ value: HostwrightStorage.StorageOrphanLifecycleState
    ) -> HostwrightState.StorageOrphanLifecycleState {
        switch value {
        case .discovered:
            .discovered
        case .held:
            .held
        case .reclaimed:
            .reclaimed
        case .ignored:
            .ignored
        }
    }

    private func expected(
        _ record: StorageStateVolumeRecord
    ) -> StorageStateExpectedVersion {
        StorageStateExpectedVersion(
            generation: record.generation,
            fencingToken: record.fencingToken
        )
    }

    private func expected(
        _ record: StorageStateOrphanRecord
    ) -> StorageStateExpectedVersion {
        StorageStateExpectedVersion(
            generation: record.generation,
            fencingToken: record.fencingToken
        )
    }

    private func canonicalSHA256<T: Encodable>(
        _ value: T
    ) throws -> String {
        sha256(try canonicalJSONString(value))
    }

    private func canonicalJSONString<T: Encodable>(
        _ value: T
    ) throws -> String {
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(
            with: encoded
        )
        let canonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard let string = String(
            data: canonical,
            encoding: .utf8
        ) else {
            throw diagnostic(
                .storageInvalid,
                "Storage evidence could not be encoded canonically."
            )
        }
        return string
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ("0"..."9").contains($0) ||
                ("a"..."f").contains($0)
        }
    }

    private func timestamp(_ milliseconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(
            from: Date(
                timeIntervalSince1970:
                    TimeInterval(milliseconds) / 1_000
            )
        )
    }

    private func unixMilliseconds(
        _ value: String
    ) throws -> Int64 {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        guard let date = fractional.date(from: value) ??
                ISO8601DateFormatter().date(from: value) else {
            throw diagnostic(
                .storageInvalid,
                "Persisted orphan discovery time is invalid."
            )
        }
        return Int64(date.timeIntervalSince1970 * 1_000)
    }
}

private struct StorageReclaimCommandReport: Encodable {
    let schemaVersion = 1
    let kind = "storageReclaim"
    let operation: String
    let disposition: String
    let volumeIDs: [String]
    let planSHA256: String
    let reclaimedCapacityBytes: Int64
}
