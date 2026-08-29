import Foundation
import HostwrightCore
import HostwrightScheduler

extension SchedulerAdmissionError: StateTransactionPreservedError {}

private struct SchedulerPreemptionIntentStoragePayload: Codable {
    let decisionID: UUID
    let intentID: UUID
    let proposal: SchedulerPreemptionProposal
}

private enum SchedulerAdmissionAuthorityTables {
    static let decisions = "scheduler_decisions"
    static let reservations = "scheduler_reservations"
    static let fairness = "scheduler_fairness_accounting"
    static let budgets = "scheduler_disruption_budgets"
    static let preemptionIntents = "scheduler_preemption_intents"
    static let hostPressure = "scheduler_host_pressure"

    static let fairnessColumns: Set<String> = [
        "subject_id", "project_id", "state_json", "generation", "updated_at",
        "accounting_digest",
    ]
    static let decisionColumns: Set<String> = [
        "decision_id", "project_uuid", "input_digest", "config_digest",
        "profile_digest", "lifecycle_plan_digest", "decision_json",
        "workload_ids_json", "workload_bindings_json", "created_at", "updated_at",
        "artifact_digest",
    ]
    static let reservationColumns: Set<String> = [
        "decision_id", "reservation_id", "workload_uuid", "node_uuid",
        "resource_vector_json", "capacity_digest", "capacity_generation",
        "input_digest", "config_digest", "profile_digest",
        "lifecycle_plan_digest", "owner_subject_id", "project_uuid", "status",
        "created_at", "updated_at", "expires_at", "fencing_node_epoch",
        "fencing_reservation_sequence",
    ]
    static let budgetColumns: Set<String> = [
        "budget_id", "project_id", "remaining_victim_count",
        "remaining_disruption_cost_basis_points", "generation", "updated_at",
        "budget_digest",
    ]
    static let preemptionIntentColumns: Set<String> = [
        "intent_id", "project_id", "proposal_json", "intent_digest", "status",
        "created_at", "updated_at", "record_digest",
    ]
    static let hostPressureColumns: Set<String> = [
        "node_uuid", "pressure", "energy", "generation", "observed_at",
        "evidence_digest", "policy_state_json", "record_digest",
    ]
}

public struct SchedulerAdmissionRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    @discardableResult
    public func recordNodeCapacity(
        snapshot: SchedulerNodeCapacitySnapshot
    ) throws -> SchedulerNodeCapacitySnapshot {
        try validateNodeCapacitySnapshot(snapshot)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                if let existing = try loadNodeCapacity(
                    snapshot.nodeID,
                    generation: snapshot.generation,
                    on: connection
                ) {
                    if existing == snapshot {
                        try ensureFenceState(
                            snapshot.nodeID,
                            initialUpdatedAt: snapshot.observedAt,
                            on: connection
                        )
                        return existing
                    }
                    throw SchedulerAdmissionError.staleInput(
                        field: "node-capacity-generation"
                    )
                }

                if let latest = try loadNodeCapacity(snapshot.nodeID, on: connection) {
                    guard snapshot.generation > latest.generation else {
                        throw SchedulerAdmissionError.staleInput(
                            field: "node-capacity-generation"
                        )
                    }
                    guard timestamp(snapshot.observedAt) >= timestamp(latest.observedAt) else {
                        throw SchedulerAdmissionError.staleInput(
                            field: "node-capacity-observed-at"
                        )
                    }
                }

                try connection.run(
                    """
                    INSERT INTO scheduler_node_capacity_snapshots (
                        node_uuid, capacity_json, capacity_digest, generation,
                        observed_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(uuidText(snapshot.nodeID)),
                        .text(SchedulerAdmissionCanonicalJSON.vectorJSON(snapshot.capacity)),
                        .text(snapshot.capacityDigest),
                        .int64(snapshot.generation),
                        .text(snapshot.observedAt),
                        .text(snapshot.observedAt),
                    ]
                )
                try ensureFenceState(
                    snapshot.nodeID,
                    initialUpdatedAt: snapshot.observedAt,
                    on: connection
                )

                guard let stored = try loadNodeCapacity(
                    snapshot.nodeID,
                    generation: snapshot.generation,
                    on: connection
                ), stored == snapshot else {
                    throw SchedulerAdmissionError.stateInvariant(
                        "node-capacity-snapshot-persisted-differently"
                    )
                }
                return stored
            }
        }
    }

    public func nodeCapacity(nodeID: UUID) throws -> SchedulerNodeCapacitySnapshot? {
        try store.withValidatedConnection(readOnly: true) { connection in
            try loadNodeCapacity(nodeID, on: connection)
        }
    }

    public func fencingState(nodeID: UUID) throws -> SchedulerFenceStateSnapshot {
        try store.withValidatedConnection(readOnly: true) { connection in
            guard try loadNodeCapacity(nodeID, on: connection) != nil else {
                throw SchedulerAdmissionError.notFound(kind: "node", id: nodeID)
            }
            return try requiredFenceState(nodeID, on: connection)
        }
    }

    @discardableResult
    public func recoverNode(
        evidence: SchedulerNodeRecoveryEvidence
    ) throws -> SchedulerFenceStateSnapshot {
        try validateRecoveryEvidence(evidence)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                guard try loadNodeCapacity(evidence.nodeID, on: connection) != nil else {
                    throw SchedulerAdmissionError.notFound(kind: "node", id: evidence.nodeID)
                }
                let current = try requiredFenceState(evidence.nodeID, on: connection)

                if current.nodeEpoch == evidence.newNodeEpoch,
                   current.recoveryEvidenceDigest == evidence.evidenceDigest,
                   current.recoveryEvidenceAt == evidence.verifiedAt {
                    return current
                }

                guard current.nodeEpoch == evidence.expectedNodeEpoch else {
                    throw SchedulerAdmissionError.staleNodeEpoch(
                        nodeID: evidence.nodeID,
                        expected: evidence.expectedNodeEpoch,
                        actual: current.nodeEpoch
                    )
                }
                guard evidence.newNodeEpoch > current.nodeEpoch else {
                    throw SchedulerAdmissionError.invalidEvidence(
                        "recovery-epoch-not-newer"
                    )
                }
                try requireEvidenceNotBefore(
                    evidence.verifiedAt,
                    updatedAt: current.updatedAt,
                    field: "recovery-evidence-at"
                )

                try connection.run(
                    """
                    UPDATE scheduler_fence_state
                    SET node_epoch = ?, updated_at = ?,
                        recovery_evidence_digest = ?, recovery_evidence_at = ?
                    WHERE node_uuid = ? AND node_epoch = ?
                    """,
                    bindings: [
                        .int64(evidence.newNodeEpoch),
                        .text(evidence.verifiedAt),
                        .text(evidence.evidenceDigest),
                        .text(evidence.verifiedAt),
                        .text(uuidText(evidence.nodeID)),
                        .int64(evidence.expectedNodeEpoch),
                    ]
                )

                let stored = try requiredFenceState(evidence.nodeID, on: connection)
                guard stored.nodeEpoch == evidence.newNodeEpoch,
                      stored.nextReservationSequence == current.nextReservationSequence,
                      stored.updatedAt == evidence.verifiedAt,
                      stored.recoveryEvidenceDigest == evidence.evidenceDigest,
                      stored.recoveryEvidenceAt == evidence.verifiedAt else {
                    throw SchedulerAdmissionError.stateInvariant(
                        "recovery-state-persisted-differently"
                    )
                }
                return stored
            }
        }
    }

    public func reserve(
        binding: SchedulerAdmissionBinding,
        authority: SchedulerAdmissionAuthority
    ) throws -> SchedulerReservationRecord {
        try validateAdmissionBinding(binding)
        try validateAdmissionAuthority(authority)
        try requireAuthorityMatches(binding: binding, authority: authority)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try reserveInTransaction(binding: binding, authority: authority, on: connection)
            }
        }
    }

    /// Applies one persisted decision without accepting a client-built
    /// binding, expiry, authority, or fence proof. Placement decisions create
    /// one pending reservation from the artifact's immutable binding. A
    /// preemption decision persists its immutable `.proposed` intent only;
    /// victims are released by `completePreemptionDecision` after a
    /// reservation-lineage runtime absence proof (or an authoritative node
    /// recovery fence), and the intent remains durable if the later runtime
    /// operation fails.
    @discardableResult
    public func applyDecision(
        decisionID: UUID,
        projectUUID: String,
        workloadID: UUID,
        expectedInputDigest: String,
        currentAuthority: SchedulerAdmissionCurrentAuthority
    ) throws -> SchedulerAdmissionApplyResult {
        try SchedulerAdmissionValidation.digest(
            expectedInputDigest,
            field: "apply-input-digest"
        )
        guard HostwrightResourceUUID.isValid(projectUUID) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "apply-project-uuid"
            )
        }
        return try store.withValidatedConnection { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.decisions,
                columns: SchedulerAdmissionAuthorityTables.decisionColumns,
                on: connection
            )
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.hostPressure,
                columns: SchedulerAdmissionAuthorityTables.hostPressureColumns,
                on: connection
            )
            return try connection.transaction {
                guard let artifact = try loadDecisionArtifact(decisionID, on: connection) else {
                    throw SchedulerAdmissionError.notFound(
                        kind: "decision",
                        id: decisionID
                    )
                }
                guard artifact.projectUUID == projectUUID.lowercased() else {
                    throw SchedulerAdmissionError.invalidBinding(
                        field: "apply-project-scope"
                    )
                }
                guard artifact.inputDigest == expectedInputDigest else {
                    throw SchedulerAdmissionError.staleInput(field: "input-digest")
                }
                guard let workloadBinding = artifact.binding(for: workloadID) else {
                    throw SchedulerAdmissionError.invalidBinding(
                        field: "apply-workload-binding"
                    )
                }
                guard workloadBinding.projectUUID == artifact.projectUUID else {
                    throw SchedulerAdmissionError.invalidBinding(
                        field: "apply-workload-project-scope"
                    )
                }
                guard artifact.configDigest == currentAuthority.configDigest,
                      artifact.profileDigest == currentAuthority.profileDigest,
                      artifact.lifecyclePlanDigest == currentAuthority.lifecyclePlanDigest,
                      workloadBinding.capacityDigest == currentAuthority.nodeCapacityDigest,
                      workloadBinding.capacityGeneration
                        == currentAuthority.nodeCapacityGeneration else {
                    throw SchedulerAdmissionError.staleInput(
                        field: "apply-authority"
                    )
                }
                let authority = try SchedulerAdmissionAuthority(
                    nodeCapacityDigest: currentAuthority.nodeCapacityDigest,
                    nodeCapacityGeneration: currentAuthority.nodeCapacityGeneration,
                    inputDigest: expectedInputDigest,
                    configDigest: currentAuthority.configDigest,
                    profileDigest: currentAuthority.profileDigest,
                    lifecyclePlanDigest: currentAuthority.lifecyclePlanDigest,
                    expectedNodeEpoch: currentAuthority.expectedNodeEpoch
                )
                let decisionWorkload = artifact.decision.workloadDecisions.first {
                    $0.workloadID == workloadID
                }
                guard let decisionWorkload else {
                    throw SchedulerAdmissionError.invalidBinding(
                        field: "apply-decision-workload"
                    )
                }
                try validateCurrentPressure(
                    nodeID: workloadBinding.nodeID,
                    authority: currentAuthority,
                    on: connection
                )
                switch decisionWorkload.outcome {
                case .placed, .retainedExistingPlacement:
                    let binding = try SchedulerAdmissionBinding(
                        decisionID: decisionID,
                        workloadID: workloadBinding.workloadID,
                        nodeID: workloadBinding.nodeID,
                        resources: workloadBinding.resources,
                        nodeCapacityDigest: workloadBinding.capacityDigest,
                        nodeCapacityGeneration: workloadBinding.capacityGeneration,
                        inputDigest: artifact.inputDigest,
                        configDigest: artifact.configDigest,
                        profileDigest: artifact.profileDigest,
                        lifecyclePlanDigest: artifact.lifecyclePlanDigest,
                        ownerSubjectID: workloadBinding.ownerSubjectID,
                        projectUUID: artifact.projectUUID,
                        createdAt: currentAuthority.leaseCreatedAt,
                        expiresAt: currentAuthority.leaseExpiresAt
                    )
                    let reservation = try reserveInTransaction(
                        binding: binding,
                        authority: authority,
                        pressureAuthority: currentAuthority,
                        on: connection
                    )
                    return try SchedulerAdmissionApplyResult(
                        decisionID: decisionID,
                        inputDigest: expectedInputDigest,
                        reservation: reservation,
                        preemptionIntent: nil
                    )
                case .preemptionProposed:
                    guard let proposal = decisionWorkload.preemption,
                          proposal.projectID == artifact.projectUUID,
                          proposal.nodeID == workloadBinding.nodeID else {
                        throw SchedulerAdmissionError.invalidBinding(
                            field: "apply-preemption-project-or-node"
                        )
                    }
                    try validateCurrentAuthority(
                        nodeID: workloadBinding.nodeID,
                        authority: authority,
                        on: connection
                    )
                    let intentID = SchedulerAdmissionStableIdentifier.preemptionIntentID(
                        decisionID: decisionID,
                        targetWorkloadID: proposal.targetWorkloadID
                    )
                    if let existing = try loadPreemptionIntent(intentID, on: connection) {
                        guard existing.proposal == proposal else {
                            throw SchedulerAdmissionError.stateInvariant(
                                "preemption-intent-replay-mismatch"
                            )
                        }
                        switch existing.status {
                        case .fenced, .applied:
                            guard let reservation = try loadReservation(
                                decisionID: decisionID,
                                workloadID: workloadID,
                                on: connection
                            ) else {
                                throw SchedulerAdmissionError.stateInvariant(
                                    "preemption-reservation-missing"
                                )
                            }
                            try validateArtifactReservationPair(artifact, reservation)
                            return try SchedulerAdmissionApplyResult(
                                decisionID: decisionID,
                                inputDigest: expectedInputDigest,
                                reservation: reservation,
                                preemptionIntent: existing
                            )
                        case .proposed, .fencePending:
                            return try SchedulerAdmissionApplyResult(
                                decisionID: decisionID,
                                inputDigest: expectedInputDigest,
                                reservation: nil,
                                preemptionIntent: existing
                            )
                        case .recovered, .rejected:
                            throw SchedulerAdmissionError.invalidBinding(
                                field: "preemption-intent-status"
                            )
                        }
                    }
                    let intent = try SchedulerPreemptionIntentRecord(
                        decisionID: decisionID,
                        intentID: intentID,
                        proposal: proposal,
                        status: .proposed,
                        createdAt: artifact.createdAt,
                        updatedAt: artifact.updatedAt
                    )
                    let storedIntent = try insertPreemptionIntentInTransaction(
                        intent,
                        on: connection
                    )
                    return try SchedulerAdmissionApplyResult(
                        decisionID: decisionID,
                        inputDigest: expectedInputDigest,
                        reservation: nil,
                        preemptionIntent: storedIntent
                    )
                case .unschedulable:
                    throw SchedulerAdmissionError.invalidBinding(
                        field: "apply-unschedulable-decision"
                    )
                }
            }
        }
    }

    /// Completes a daemon-owned preemption transition. Fence evidence is
    /// accepted only from the internal runtime/recovery seam; callers cannot
    /// submit it through the wire contract. Victim fences, budget consumption,
    /// intent transition, and the target pending reservation are one durable
    /// transaction. A fenced/applied replay returns the first durable result
    /// without consuming budget twice.
    @discardableResult
    public func completePreemptionDecision(
        decisionID: UUID,
        projectUUID: String,
        workloadID: UUID,
        expectedInputDigest: String,
        currentAuthority: SchedulerAdmissionCurrentAuthority,
        fenceEvidence: [SchedulerFenceEvidence],
        transitionAt: String
    ) throws -> SchedulerAdmissionApplyResult {
        try SchedulerAdmissionValidation.digest(
            expectedInputDigest,
            field: "apply-input-digest"
        )
        guard HostwrightResourceUUID.isValid(projectUUID) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "apply-project-uuid"
            )
        }
        try SchedulerAdmissionValidation.timestamp(
            transitionAt,
            field: "preemption-transition-at"
        )
        guard fenceEvidence.count <= SchedulerAdmissionStateLimits.maximumFenceEvidenceCount else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "fence-evidence-count"
            )
        }
        return try store.withValidatedConnection { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.decisions,
                columns: SchedulerAdmissionAuthorityTables.decisionColumns,
                on: connection
            )
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.hostPressure,
                columns: SchedulerAdmissionAuthorityTables.hostPressureColumns,
                on: connection
            )
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.preemptionIntents,
                columns: SchedulerAdmissionAuthorityTables.preemptionIntentColumns,
                on: connection
            )
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.budgets,
                columns: SchedulerAdmissionAuthorityTables.budgetColumns,
                on: connection
            )
            return try connection.transaction {
                guard let artifact = try loadDecisionArtifact(decisionID, on: connection),
                      artifact.projectUUID == projectUUID.lowercased(),
                      artifact.inputDigest == expectedInputDigest,
                      let workloadBinding = artifact.binding(for: workloadID),
                      let decisionWorkload = artifact.decision.workloadDecisions.first(
                          where: { $0.workloadID == workloadID }
                      ),
                      decisionWorkload.outcome == .preemptionProposed,
                      let proposal = decisionWorkload.preemption,
                      proposal.projectID == artifact.projectUUID,
                      proposal.nodeID == workloadBinding.nodeID else {
                    throw SchedulerAdmissionError.invalidBinding(
                        field: "preemption-decision-binding"
                    )
                }
                guard artifact.configDigest == currentAuthority.configDigest,
                      artifact.profileDigest == currentAuthority.profileDigest,
                      artifact.lifecyclePlanDigest == currentAuthority.lifecyclePlanDigest,
                      workloadBinding.capacityDigest == currentAuthority.nodeCapacityDigest,
                      workloadBinding.capacityGeneration
                          == currentAuthority.nodeCapacityGeneration else {
                    throw SchedulerAdmissionError.staleInput(
                        field: "apply-authority"
                    )
                }
                try validateCurrentPressure(
                    nodeID: workloadBinding.nodeID,
                    authority: currentAuthority,
                    on: connection
                )
                let authority = try SchedulerAdmissionAuthority(
                    nodeCapacityDigest: currentAuthority.nodeCapacityDigest,
                    nodeCapacityGeneration: currentAuthority.nodeCapacityGeneration,
                    inputDigest: expectedInputDigest,
                    configDigest: currentAuthority.configDigest,
                    profileDigest: currentAuthority.profileDigest,
                    lifecyclePlanDigest: currentAuthority.lifecyclePlanDigest,
                    expectedNodeEpoch: currentAuthority.expectedNodeEpoch
                )
                let intentID = SchedulerAdmissionStableIdentifier.preemptionIntentID(
                    decisionID: decisionID,
                    targetWorkloadID: proposal.targetWorkloadID
                )
                guard let existingIntent = try loadPreemptionIntent(
                    intentID,
                    on: connection
                ), existingIntent.proposal == proposal else {
                    throw SchedulerAdmissionError.stateInvariant(
                        "preemption-intent-missing"
                    )
                }
                if existingIntent.status == .fenced || existingIntent.status == .applied {
                    guard let reservation = try loadReservation(
                        decisionID: decisionID,
                        workloadID: workloadID,
                        on: connection
                    ) else {
                        throw SchedulerAdmissionError.stateInvariant(
                            "preemption-reservation-missing"
                        )
                    }
                    try validateArtifactReservationPair(artifact, reservation)
                    return try SchedulerAdmissionApplyResult(
                        decisionID: decisionID,
                        inputDigest: expectedInputDigest,
                        reservation: reservation,
                        preemptionIntent: existingIntent
                    )
                }
                guard existingIntent.status == .proposed
                        || existingIntent.status == .fencePending else {
                    throw SchedulerAdmissionError.invalidBinding(
                        field: "preemption-intent-status"
                    )
                }
                let orderedEvidence = fenceEvidence.sorted { lhs, rhs in
                    (uuidText(lhs.workloadID), uuidText(lhs.reservationID)) <
                        (uuidText(rhs.workloadID), uuidText(rhs.reservationID))
                }
                guard orderedEvidence.count == proposal.victims.count,
                      Set(orderedEvidence.map(\.workloadID)).count == orderedEvidence.count,
                      Set(orderedEvidence.map(\.reservationID)).count == orderedEvidence.count,
                      Set(orderedEvidence.map(\.workloadID)) ==
                          Set(proposal.victims.map(\.workloadID)) else {
                    throw SchedulerAdmissionError.invalidEvidence(
                        "preemption-fence-lineage-count"
                    )
                }
                let fencePendingIntent: SchedulerPreemptionIntentRecord
                if existingIntent.status == .proposed {
                    fencePendingIntent = try SchedulerPreemptionIntentRecord(
                        decisionID: existingIntent.decisionID,
                        intentID: existingIntent.intentID,
                        proposal: existingIntent.proposal,
                        status: .fencePending,
                        createdAt: existingIntent.createdAt,
                        updatedAt: transitionAt
                    )
                    try updatePreemptionIntentInTransaction(
                        existing: existingIntent,
                        next: fencePendingIntent,
                        on: connection
                    )
                } else {
                    fencePendingIntent = existingIntent
                    try requireUpdatedAtNotBefore(
                        transitionAt,
                        current: existingIntent.updatedAt
                    )
                }
                for evidence in orderedEvidence {
                    try validateFenceEvidence(evidence)
                    guard let victim = proposal.victims.first(
                        where: { $0.workloadID == evidence.workloadID }
                    ),
                    let reservation = try loadReservation(
                        evidence.reservationID,
                        on: connection
                    ),
                    reservation.workloadID == victim.workloadID,
                    reservation.nodeID == victim.nodeID,
                    reservation.resources == victim.allocation,
                    reservation.ownerSubjectID == victim.subjectID,
                    reservation.projectUUID == projectUUID.lowercased() else {
                        throw SchedulerAdmissionError.invalidEvidence(
                            "preemption-fence-victim-binding"
                        )
                    }
                    let currentState = try requiredFenceState(
                        reservation.nodeID,
                        on: connection
                    )
                    let releaseEvidence: SchedulerReleaseEvidence
                    if evidence.token == reservation.fencingToken {
                        // A selective victim removal is not a node recovery.
                        // The runtime mutation has already produced a fresh,
                        // authoritative absence observation, so consume this
                        // reservation's own token without changing the
                        // node-global epoch.  This keeps unrelated sibling
                        // reservations valid while retaining the strict
                        // recovery fencing path below for real node resets.
                        try requireCurrentStoredToken(
                            reservation,
                            expected: evidence.token,
                            state: currentState
                        )
                        try requireEvidenceNotBefore(
                            evidence.verifiedAt,
                            updatedAt: reservation.updatedAt,
                            field: "victim-absence-verified-at"
                        )
                        try requireEvidenceNotBefore(
                            evidence.verifiedAt,
                            updatedAt: currentState.updatedAt,
                            field: "victim-absence-verified-at"
                        )
                        releaseEvidence = .verifiedRuntimeAbsence(
                            evidenceDigest: evidence.evidenceDigest,
                            verifiedAt: evidence.verifiedAt
                        )
                    } else {
                        _ = try fenceInTransaction(
                            reservationID: evidence.reservationID,
                            evidence: evidence,
                            on: connection
                        )
                        // A recovered node produces a newer epoch-scoped
                        // fence.  Preserve that authoritative recovery path
                        // and release only after its same-lineage proof.
                        releaseEvidence = .authoritativeFence(
                            token: evidence.token,
                            reservationID: evidence.reservationID,
                            workloadID: evidence.workloadID,
                            evidenceDigest: evidence.evidenceDigest,
                            verifiedAt: evidence.verifiedAt
                        )
                    }
                    _ = try updateReleaseEvidence(
                        reservationID: evidence.reservationID,
                        evidence: releaseEvidence,
                        updatedAt: evidence.verifiedAt,
                        on: connection
                    )
                }
                let binding = try SchedulerAdmissionBinding(
                    decisionID: decisionID,
                    workloadID: workloadBinding.workloadID,
                    nodeID: workloadBinding.nodeID,
                    resources: workloadBinding.resources,
                    nodeCapacityDigest: workloadBinding.capacityDigest,
                    nodeCapacityGeneration: workloadBinding.capacityGeneration,
                    inputDigest: artifact.inputDigest,
                    configDigest: artifact.configDigest,
                    profileDigest: artifact.profileDigest,
                    lifecyclePlanDigest: artifact.lifecyclePlanDigest,
                    ownerSubjectID: workloadBinding.ownerSubjectID,
                    projectUUID: artifact.projectUUID,
                    createdAt: currentAuthority.leaseCreatedAt,
                    expiresAt: currentAuthority.leaseExpiresAt
                )
                let reservation = try reserveInTransaction(
                    binding: binding,
                    authority: authority,
                    pressureAuthority: currentAuthority,
                    allowPreemptionOutcome: true,
                    on: connection
                )
                let fencedIntent = try SchedulerPreemptionIntentRecord(
                    decisionID: fencePendingIntent.decisionID,
                    intentID: fencePendingIntent.intentID,
                    proposal: fencePendingIntent.proposal,
                    status: .fenced,
                    createdAt: fencePendingIntent.createdAt,
                    updatedAt: transitionAt
                )
                try validatePreemptionBudgets(fencedIntent, on: connection)
                try decrementPreemptionBudgets(
                    intent: fencedIntent,
                    on: connection
                )
                try updatePreemptionIntentInTransaction(
                    existing: fencePendingIntent,
                    next: fencedIntent,
                    on: connection
                )
                return try SchedulerAdmissionApplyResult(
                    decisionID: decisionID,
                    inputDigest: expectedInputDigest,
                    reservation: reservation,
                    preemptionIntent: fencedIntent
                )
            }
        }
    }

    private func reserveInTransaction(
        binding: SchedulerAdmissionBinding,
        authority: SchedulerAdmissionAuthority,
        pressureAuthority: SchedulerAdmissionCurrentAuthority? = nil,
        allowPreemptionOutcome: Bool = false,
        on connection: SQLiteConnection
    ) throws -> SchedulerReservationRecord {
        guard let artifact = try loadDecisionArtifact(
            binding.decisionID,
            on: connection
        ) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "decision-artifact-required"
            )
        }
        try validateArtifactBinding(
            artifact,
            binding: binding,
            allowPreemptionOutcome: allowPreemptionOutcome
        )
        let currentState = try requiredFenceState(binding.nodeID, on: connection)
        try requireExpectedNodeEpoch(
            authority.expectedNodeEpoch,
            current: currentState.nodeEpoch,
            nodeID: binding.nodeID
        )

        if let existingReservation = try loadReservation(
            decisionID: binding.decisionID,
            workloadID: binding.workloadID,
            on: connection
        ) {
            guard let historicalSnapshot = try loadNodeCapacity(
                binding.nodeID,
                generation: binding.nodeCapacityGeneration,
                on: connection
            ), historicalSnapshot.capacityDigest == binding.nodeCapacityDigest else {
                throw SchedulerAdmissionError.staleInput(
                    field: "node-capacity-snapshot"
                )
            }
            try validateArtifactReservationPair(artifact, existingReservation)
            guard existingReservation.status != .released else {
                throw SchedulerAdmissionError.invalidTransition(
                    reservationID: existingReservation.reservationID,
                    status: existingReservation.status
                )
            }
            try requireAllocatedReservationToken(
                existingReservation.fencingToken,
                state: currentState,
                nodeID: binding.nodeID
            )
            return existingReservation
        }

        guard let latestSnapshot = try loadNodeCapacity(
            binding.nodeID,
            on: connection
        ), latestSnapshot.capacityDigest == binding.nodeCapacityDigest,
              latestSnapshot.generation == binding.nodeCapacityGeneration,
              latestSnapshot.capacityDigest == authority.nodeCapacityDigest,
              latestSnapshot.generation == authority.nodeCapacityGeneration else {
            throw SchedulerAdmissionError.staleInput(
                field: "node-capacity-snapshot"
            )
        }

        if let duplicate = try activeReservation(
            workloadID: binding.workloadID,
            on: connection
        ) {
            throw SchedulerAdmissionError.duplicateActiveWorkload(
                workloadID: binding.workloadID,
                decisionID: duplicate
            )
        }

        let used = try activeCapacity(binding.nodeID, on: connection)
        let available = try clampedRemaining(
            capacity: latestSnapshot.capacity,
            allocation: used
        )
        guard binding.resources.fits(in: available) else {
            throw SchedulerAdmissionError.insufficientCapacity(
                nodeID: binding.nodeID,
                requested: binding.resources,
                available: available
            )
        }

        if let pressureAuthority {
            try validateCurrentPressure(
                nodeID: binding.nodeID,
                authority: pressureAuthority,
                on: connection
            )
        }

        let token = try allocateReservationToken(
            nodeID: binding.nodeID,
            state: currentState,
            on: connection
        )
        let reservationID = try reservationID(
            for: binding.decisionID,
            workloadID: binding.workloadID
        )
        try insertReservation(
            binding: binding,
            reservationID: reservationID,
            fencingToken: token,
            on: connection
        )

        guard let storedReservation = try loadReservation(
            reservationID,
            on: connection
        ), try self.binding(for: storedReservation) == binding,
              storedReservation.status == .pending,
              storedReservation.fencingToken == token else {
            throw SchedulerAdmissionError.stateInvariant(
                "reservation-persisted-differently"
            )
        }
        try validateArtifactReservationPair(artifact, storedReservation)
        return storedReservation
    }

    private func validateCurrentAuthority(
        nodeID: UUID,
        authority: SchedulerAdmissionAuthority,
        on connection: SQLiteConnection
    ) throws {
        guard let snapshot = try loadNodeCapacity(nodeID, on: connection),
              snapshot.capacityDigest == authority.nodeCapacityDigest,
              snapshot.generation == authority.nodeCapacityGeneration else {
            throw SchedulerAdmissionError.staleInput(
                field: "node-capacity-snapshot"
            )
        }
        let state = try requiredFenceState(nodeID, on: connection)
        try requireExpectedNodeEpoch(
            authority.expectedNodeEpoch,
            current: state.nodeEpoch,
            nodeID: nodeID
        )
    }

    private func validateCurrentPressure(
        nodeID: UUID,
        authority: SchedulerAdmissionCurrentAuthority,
        on connection: SQLiteConnection
    ) throws {
        guard let pressure = try loadHostPressure(nodeID, on: connection) else {
            throw SchedulerAdmissionError.staleInput(field: "pressure-snapshot")
        }
        guard pressure.generation == authority.expectedPressureGeneration,
              pressure.evidenceDigest == authority.expectedPressureEvidenceDigest,
              pressure.posture.pressure == authority.expectedPressurePosture else {
            throw SchedulerAdmissionError.staleInput(field: "pressure-snapshot")
        }
        guard pressure.posture.pressure == .nominal
                || pressure.posture.pressure == .elevated else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "pressure-not-admissible"
            )
        }
    }

    public func decision(id: UUID) throws -> SchedulerDecisionRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            guard let reservation = try loadReservation(
                decisionID: id,
                on: connection
            ) else {
                return nil
            }
            guard let artifact = try loadDecisionArtifact(id, on: connection) else {
                throw SchedulerAdmissionError.stateInvariant(
                    "decision-artifact-missing"
                )
            }
            try validateArtifactReservationPair(artifact, reservation)
            return decisionProjection(for: reservation)
        }
    }

    public func reservation(id: UUID) throws -> SchedulerReservationRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            guard let reservation = try loadReservation(id, on: connection) else {
                return nil
            }
            guard let artifact = try loadDecisionArtifact(
                reservation.decisionID,
                on: connection
            ) else {
                throw SchedulerAdmissionError.stateInvariant(
                    "decision-artifact-missing"
                )
            }
            try validateArtifactReservationPair(artifact, reservation)
            return reservation
        }
    }

    public func reservations(nodeID: UUID) throws -> [SchedulerReservationRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT decision_id, reservation_id, workload_uuid, node_uuid,
                       resource_vector_json, capacity_digest, capacity_generation,
                       input_digest, config_digest, profile_digest, lifecycle_plan_digest,
                       owner_subject_id, project_uuid, status, created_at, updated_at,
                       expires_at, fencing_node_epoch, fencing_reservation_sequence,
                       fence_evidence_digest, fence_evidence_at,
                       fence_evidence_node_epoch, fence_evidence_reservation_sequence,
                       fence_evidence_reservation_id, fence_evidence_workload_uuid,
                       release_evidence_kind, release_evidence_digest, release_evidence_at,
                       release_evidence_node_epoch, release_evidence_reservation_sequence,
                       release_evidence_reservation_id, release_evidence_workload_uuid
                FROM scheduler_reservations
                WHERE node_uuid = ?
                ORDER BY reservation_id ASC
                """,
                bindings: [.text(uuidText(nodeID))]
            )
            let records = try rows.map(decodeReservation)
            for reservation in records {
                guard let artifact = try loadDecisionArtifact(
                    reservation.decisionID,
                    on: connection
                ) else {
                    throw SchedulerAdmissionError.stateInvariant(
                        "decision-artifact-missing"
                    )
                }
                try validateArtifactReservationPair(artifact, reservation)
            }
            return records
        }
    }

    /// Returns only reservations whose runtime transition is recoverable after
    /// a daemon restart.  Expiry never changes this set or releases capacity.
    public func recoverableReservations() throws -> [SchedulerReservationRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.reservations,
                columns: SchedulerAdmissionAuthorityTables.reservationColumns,
                on: connection
            )
            let rows = try boundedQuery(
                """
                SELECT decision_id, reservation_id, workload_uuid, node_uuid,
                       resource_vector_json, capacity_digest, capacity_generation,
                       input_digest, config_digest, profile_digest, lifecycle_plan_digest,
                       owner_subject_id, project_uuid, status, created_at, updated_at,
                       expires_at, fencing_node_epoch, fencing_reservation_sequence,
                       fence_evidence_digest, fence_evidence_at,
                       fence_evidence_node_epoch, fence_evidence_reservation_sequence,
                       fence_evidence_reservation_id, fence_evidence_workload_uuid,
                       release_evidence_kind, release_evidence_digest, release_evidence_at,
                       release_evidence_node_epoch, release_evidence_reservation_sequence,
                       release_evidence_reservation_id, release_evidence_workload_uuid
                FROM scheduler_reservations
                WHERE status IN ('pending', 'release-pending', 'fenced')
                ORDER BY reservation_id ASC
                LIMIT ?
                """,
                bindings: [
                    .int(SchedulerAdmissionStateLimits.maximumRecoverableReservationCount + 1)
                ],
                limit: SchedulerAdmissionStateLimits.maximumRecoverableReservationCount,
                field: "recoverable-reservations",
                on: connection
            )
            let records = try rows.map(decodeReservation)
            for reservation in records {
                guard let artifact = try loadDecisionArtifact(
                    reservation.decisionID,
                    on: connection
                ) else {
                    throw SchedulerAdmissionError.stateInvariant(
                        "decision-artifact-missing"
                    )
                }
                try validateArtifactReservationPair(artifact, reservation)
            }
            return records
        }
    }

    /// Returns the single active reservation for a project-bound victim
    /// workload. Multiple active rows are a state invariant, not an
    /// authorization opportunity.
    public func activeReservation(
        workloadID: UUID,
        projectUUID: String
    ) throws -> SchedulerReservationRecord? {
        guard HostwrightResourceUUID.isValid(projectUUID) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "reservation-project-uuid"
            )
        }
        return try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try boundedQuery(
                """
                SELECT reservation_id
                FROM scheduler_reservations
                WHERE workload_uuid = ? AND project_uuid = ?
                  AND status IN ('pending', 'committed', 'release-pending', 'fenced')
                ORDER BY reservation_id ASC
                LIMIT ?
                """,
                bindings: [
                    .text(uuidText(workloadID)),
                    .text(projectUUID.lowercased()),
                    .int(2),
                ],
                limit: 1,
                field: "active-reservation",
                on: connection
            )
            guard rows.count <= 1 else {
                throw SchedulerAdmissionError.stateInvariant(
                    "duplicate-active-workload"
                )
            }
            guard let firstRow = rows.first,
                  let reservationText = firstRow.first ?? nil,
                  let reservationID = UUID(uuidString: reservationText),
                  let reservation = try loadReservation(
                      reservationID,
                      on: connection
                  ) else {
                return nil
            }
            guard reservation.projectUUID == projectUUID.lowercased(),
                  reservation.workloadID == workloadID else {
                throw SchedulerAdmissionError.stateInvariant(
                    "active-reservation-binding"
                )
            }
            guard let artifact = try loadDecisionArtifact(
                reservation.decisionID,
                on: connection
            ) else {
                throw SchedulerAdmissionError.stateInvariant(
                    "decision-artifact-missing"
                )
            }
            try validateArtifactReservationPair(artifact, reservation)
            return reservation
        }
    }

    /// Returns the single unambiguous reservation lineage for restart
    /// recovery, including a released terminal row. Multiple historical rows
    /// are intentionally rejected so an intent cannot be rebound by guessing.
    public func recoveryReservation(
        workloadID: UUID,
        projectUUID: String
    ) throws -> SchedulerReservationRecord? {
        guard HostwrightResourceUUID.isValid(projectUUID) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "reservation-project-uuid"
            )
        }
        return try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try boundedQuery(
                """
                SELECT decision_id, reservation_id, workload_uuid, node_uuid,
                       resource_vector_json, capacity_digest, capacity_generation,
                       input_digest, config_digest, profile_digest, lifecycle_plan_digest,
                       owner_subject_id, project_uuid, status, created_at, updated_at,
                       expires_at, fencing_node_epoch, fencing_reservation_sequence,
                       fence_evidence_digest, fence_evidence_at,
                       fence_evidence_node_epoch, fence_evidence_reservation_sequence,
                       fence_evidence_reservation_id, fence_evidence_workload_uuid,
                       release_evidence_kind, release_evidence_digest, release_evidence_at,
                       release_evidence_node_epoch, release_evidence_reservation_sequence,
                       release_evidence_reservation_id, release_evidence_workload_uuid
                FROM scheduler_reservations
                WHERE workload_uuid = ? AND project_uuid = ?
                ORDER BY updated_at DESC, reservation_id ASC
                LIMIT 2
                """,
                bindings: [
                    .text(uuidText(workloadID)),
                    .text(projectUUID.lowercased()),
                ],
                limit: 2,
                field: "recovery-reservation",
                on: connection
            )
            guard rows.count <= 1 else {
                throw SchedulerAdmissionError.stateInvariant(
                    "recovery-reservation-ambiguous"
                )
            }
            guard let row = rows.first else { return nil }
            let reservation = try hydrateReservation(
                try decodeReservation(row),
                on: connection
            )
            guard reservation.workloadID == workloadID,
                  reservation.projectUUID == projectUUID.lowercased(),
                  let artifact = try loadDecisionArtifact(
                      reservation.decisionID,
                      on: connection
                  ) else {
                throw SchedulerAdmissionError.stateInvariant(
                    "recovery-reservation-binding"
                )
            }
            try validateArtifactReservationPair(artifact, reservation)
            return reservation
        }
    }

    public func activeCapacity(nodeID: UUID) throws -> ResourceVector {
        try store.withValidatedConnection(readOnly: true) { connection in
            guard try loadNodeCapacity(nodeID, on: connection) != nil else {
                throw SchedulerAdmissionError.notFound(kind: "node", id: nodeID)
            }
            return try activeCapacity(nodeID, on: connection)
        }
    }

    public func availableCapacity(nodeID: UUID) throws -> ResourceVector {
        try store.withValidatedConnection(readOnly: true) { connection in
            guard let snapshot = try loadNodeCapacity(nodeID, on: connection) else {
                throw SchedulerAdmissionError.notFound(kind: "node", id: nodeID)
            }
            return try clampedRemaining(
                capacity: snapshot.capacity,
                allocation: activeCapacity(nodeID, on: connection)
            )
        }
    }

    /// Persists the complete immutable scheduler plan. This never creates a
    /// reservation; apply must later select one workload from this artifact.
    @discardableResult
    public func recordDecisionArtifact(
        decision: SchedulerDecision,
        workloadBindings: [SchedulerDecisionWorkloadBinding],
        projectUUID: String,
        configDigest: String,
        profileDigest: String,
        lifecyclePlanDigest: String,
        createdAt: String,
        updatedAt: String
    ) throws -> SchedulerDecisionArtifactRecord {
        let record = try SchedulerDecisionArtifactRecord(
            decision: decision,
            workloadBindings: workloadBindings,
            projectUUID: projectUUID,
            configDigest: configDigest,
            profileDigest: profileDigest,
            lifecyclePlanDigest: lifecyclePlanDigest,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        return try store.withValidatedConnection { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.decisions,
                columns: SchedulerAdmissionAuthorityTables.decisionColumns,
                on: connection
            )
            return try connection.transaction {
                if let existing = try loadDecisionArtifact(
                    record.decisionID,
                    on: connection
                ) {
                    guard existing.decision == record.decision,
                          existing.workloadBindings == record.workloadBindings,
                          existing.projectUUID == record.projectUUID,
                          existing.configDigest == record.configDigest,
                          existing.profileDigest == record.profileDigest,
                          existing.lifecyclePlanDigest == record.lifecyclePlanDigest else {
                        throw SchedulerAdmissionError.conflictingReplay(
                            decisionID: record.decisionID
                        )
                    }
                    return existing
                }
                try requireRecordCapacity(
                    SchedulerAdmissionAuthorityTables.decisions,
                    maximum: SchedulerAdmissionStateLimits.maximumDecisionArtifactCount,
                    on: connection
                )
                try connection.run(
                    """
                    INSERT INTO scheduler_decisions (
                        decision_id, project_uuid, input_digest, config_digest,
                        profile_digest, lifecycle_plan_digest, decision_json,
                        workload_ids_json, workload_bindings_json, created_at,
                        updated_at, artifact_digest
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(uuidText(record.decisionID)),
                        .text(record.projectUUID),
                        .text(record.inputDigest),
                        .text(record.configDigest),
                        .text(record.profileDigest),
                        .text(record.lifecyclePlanDigest),
                        .text(try boundedJSON(record.decision, field: "decision")),
                        .text(try boundedJSON(record.workloadIDs, field: "decision-workloads")),
                        .text(try boundedJSON(
                            record.workloadBindings,
                            field: "decision-workload-bindings"
                        )),
                        .text(record.createdAt),
                        .text(record.updatedAt),
                        .text(record.artifactDigest),
                    ]
                )
                guard let stored = try loadDecisionArtifact(
                    record.decisionID,
                    on: connection
                ), stored == record else {
                    throw SchedulerAdmissionError.stateInvariant(
                        "decision-artifact-persisted-differently"
                    )
                }
                return stored
            }
        }
    }

    public func decisionArtifact(id: UUID) throws -> SchedulerDecisionArtifactRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.decisions,
                columns: SchedulerAdmissionAuthorityTables.decisionColumns,
                on: connection
            )
            return try loadDecisionArtifact(id, on: connection)
        }
    }

    /// Project-scoped artifact lookup. A present artifact belonging to a
    /// different project is a binding failure rather than an ambiguous miss.
    public func decisionArtifact(
        id: UUID,
        projectUUID: String
    ) throws -> SchedulerDecisionArtifactRecord? {
        guard HostwrightResourceUUID.isValid(projectUUID) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "decision-project-uuid"
            )
        }
        guard let artifact = try decisionArtifact(id: id) else {
            return nil
        }
        guard artifact.projectUUID == projectUUID.lowercased() else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "decision-project-scope"
            )
        }
        return artifact
    }

    /// Resolves a control-plane project identifier to the canonical resource
    /// UUID used by scheduler authority records. The lookup is read-only and
    /// never treats a human project ID as a resource UUID implicitly.
    public func projectResourceUUID(forProjectID projectID: String) throws -> String? {
        try validateScopedIdentity(projectID, field: "project-id")
        return try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT resource_uuid
                FROM projects
                WHERE id = ?
                LIMIT 1
                """,
                bindings: [.text(projectID)]
            )
            guard let row = rows.first,
                  let resourceUUID = row.first ?? nil else {
                return nil
            }
            guard HostwrightResourceUUID.isValid(resourceUUID) else {
                throw SchedulerAdmissionError.stateInvariant(
                    "project-resource-uuid"
                )
            }
            return resourceUUID.lowercased()
        }
    }

    public func projectAuthority(
        forProjectID projectID: String
    ) throws -> SchedulerProjectAuthoritySnapshot? {
        try validateScopedIdentity(projectID, field: "project-id")
        return try store.withValidatedConnection(readOnly: true) { connection in
            try loadProjectAuthority(
                where: "id = ?",
                value: projectID,
                on: connection
            )
        }
    }

    public func projectAuthority(
        forResourceUUID resourceUUID: String
    ) throws -> SchedulerProjectAuthoritySnapshot? {
        guard HostwrightResourceUUID.isValid(resourceUUID) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "project-resource-uuid"
            )
        }
        return try store.withValidatedConnection(readOnly: true) { connection in
            try loadProjectAuthority(
                where: "resource_uuid = ?",
                value: resourceUUID.lowercased(),
                on: connection
            )
        }
    }

    /// Returns the immutable plan plus every reservation created from it.
    /// Unapplied plans are valid snapshots with an empty reservation list.
    public func decisionState(
        id: UUID,
        projectUUID: String
    ) throws -> SchedulerDecisionStateSnapshot? {
        guard HostwrightResourceUUID.isValid(projectUUID) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "decision-project-uuid"
            )
        }
        return try store.withValidatedConnection(readOnly: true) { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.decisions,
                columns: SchedulerAdmissionAuthorityTables.decisionColumns,
                on: connection
            )
            guard let artifact = try loadDecisionArtifact(id, on: connection) else {
                return nil
            }
            guard artifact.projectUUID == projectUUID.lowercased() else {
                throw SchedulerAdmissionError.invalidBinding(
                    field: "decision-project-scope"
                )
            }
            let reservations = try loadReservations(id, on: connection)
            for reservation in reservations {
                try validateArtifactReservationPair(artifact, reservation)
            }
            return try SchedulerDecisionStateSnapshot(
                artifact: artifact,
                reservations: reservations
            )
        }
    }

    public func decisionArtifacts(
        projectUUID: String
    ) throws -> [SchedulerDecisionArtifactRecord] {
        guard HostwrightResourceUUID.isValid(projectUUID) else {
            throw SchedulerAdmissionError.invalidBinding(field: "decision-project-uuid")
        }
        return try store.withValidatedConnection(readOnly: true) { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.decisions,
                columns: SchedulerAdmissionAuthorityTables.decisionColumns,
                on: connection
            )
            let rows = try boundedQuery(
                """
                SELECT decision_id, project_uuid, input_digest, config_digest,
                       profile_digest, lifecycle_plan_digest, decision_json,
                       workload_ids_json, workload_bindings_json, created_at,
                       updated_at, artifact_digest
                FROM scheduler_decisions
                WHERE project_uuid = ?
                ORDER BY decision_id ASC
                LIMIT ?
                """,
                bindings: [
                    .text(projectUUID.lowercased()),
                    .int(SchedulerAdmissionStateLimits.maximumDecisionArtifactCount + 1),
                ],
                limit: SchedulerAdmissionStateLimits.maximumDecisionArtifactCount,
                field: "decision-artifacts",
                on: connection
            )
            return try rows.map(decodeDecisionArtifact)
        }
    }

    @discardableResult
    public func recordFairnessAccounting(
        state: SchedulerFairnessState,
        generation: Int64,
        updatedAt: String
    ) throws -> SchedulerFairnessAccountingRecord {
        let record = try SchedulerFairnessAccountingRecord(
            state: state,
            generation: generation,
            updatedAt: updatedAt
        )
        return try store.withValidatedConnection { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.fairness,
                columns: SchedulerAdmissionAuthorityTables.fairnessColumns,
                on: connection
            )
            return try connection.transaction {
                if let existing = try loadFairnessAccounting(
                    subjectID: record.subjectID,
                    projectID: record.projectID,
                    on: connection
                ) {
                    if existing == record { return existing }
                    guard record.generation > existing.generation else {
                        throw SchedulerAdmissionError.staleInput(field: "fairness-generation")
                    }
                    try requireUpdatedAtNotBefore(record.updatedAt, current: existing.updatedAt)
                    try connection.run(
                        """
                        UPDATE scheduler_fairness_accounting
                        SET state_json = ?, generation = ?, updated_at = ?, accounting_digest = ?
                        WHERE subject_id = ? AND project_id = ? AND generation = ?
                        """,
                        bindings: [
                            .text(try boundedJSON(record.state, field: "fairness-state")),
                            .int64(record.generation),
                            .text(record.updatedAt),
                            .text(record.accountingDigest),
                            .text(record.subjectID),
                            .text(record.projectID),
                            .int64(existing.generation),
                        ]
                    )
                    guard try connection.query("SELECT changes()").first?.first == "1",
                          let stored = try loadFairnessAccounting(
                              subjectID: record.subjectID,
                              projectID: record.projectID,
                              on: connection
                          ), stored == record else {
                        throw SchedulerAdmissionError.stateInvariant("fairness-accounting-update")
                    }
                    return stored
                }

                try requireRecordCapacity(
                    SchedulerAdmissionAuthorityTables.fairness,
                    maximum: SchedulerAdmissionStateLimits.maximumFairnessRecordCount,
                    on: connection
                )
                try connection.run(
                    """
                    INSERT INTO scheduler_fairness_accounting (
                        subject_id, project_id, state_json, generation, updated_at,
                        accounting_digest
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(record.subjectID),
                        .text(record.projectID),
                        .text(try boundedJSON(record.state, field: "fairness-state")),
                        .int64(record.generation),
                        .text(record.updatedAt),
                        .text(record.accountingDigest),
                    ]
                )
                guard let stored = try loadFairnessAccounting(
                    subjectID: record.subjectID,
                    projectID: record.projectID,
                    on: connection
                ), stored == record else {
                    throw SchedulerAdmissionError.stateInvariant("fairness-accounting-insert")
                }
                return stored
            }
        }
    }

    public func fairnessAccounting(
        subjectID: String,
        projectID: String
    ) throws -> SchedulerFairnessAccountingRecord? {
        try validateScopedIdentity(subjectID, field: "fairness-subject-id")
        try validateScopedIdentity(projectID, field: "fairness-project-id")
        return try store.withValidatedConnection(readOnly: true) { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.fairness,
                columns: SchedulerAdmissionAuthorityTables.fairnessColumns,
                on: connection
            )
            return try loadFairnessAccounting(
                subjectID: subjectID,
                projectID: projectID,
                on: connection
            )
        }
    }

    public func fairnessAccounting(projectID: String) throws -> [SchedulerFairnessAccountingRecord] {
        try validateScopedIdentity(projectID, field: "fairness-project-id")
        return try store.withValidatedConnection(readOnly: true) { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.fairness,
                columns: SchedulerAdmissionAuthorityTables.fairnessColumns,
                on: connection
            )
            let rows = try boundedQuery(
                """
                SELECT subject_id, project_id, state_json, generation, updated_at,
                       accounting_digest
                FROM scheduler_fairness_accounting
                WHERE project_id = ?
                ORDER BY subject_id ASC
                LIMIT ?
                """,
                bindings: [
                    .text(projectID),
                    .int(SchedulerAdmissionStateLimits.maximumFairnessRecordCount + 1),
                ],
                limit: SchedulerAdmissionStateLimits.maximumFairnessRecordCount,
                field: "fairness-accounting",
                on: connection
            )
            return try rows.map(decodeFairnessAccounting)
        }
    }

    @discardableResult
    public func recordDisruptionBudget(
        budget: SchedulerDisruptionBudget,
        generation: Int64,
        updatedAt: String
    ) throws -> SchedulerDisruptionBudgetRecord {
        let record = try SchedulerDisruptionBudgetRecord(
            budget: budget,
            generation: generation,
            updatedAt: updatedAt
        )
        return try store.withValidatedConnection { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.budgets,
                columns: SchedulerAdmissionAuthorityTables.budgetColumns,
                on: connection
            )
            return try connection.transaction {
                if let existing = try loadDisruptionBudget(
                    budgetID: record.budgetID,
                    projectID: record.projectID,
                    on: connection
                ) {
                    if existing == record { return existing }
                    guard record.generation > existing.generation else {
                        throw SchedulerAdmissionError.staleInput(
                            field: "disruption-budget-generation"
                        )
                    }
                    try requireUpdatedAtNotBefore(record.updatedAt, current: existing.updatedAt)
                    try connection.run(
                        """
                        UPDATE scheduler_disruption_budgets
                        SET remaining_victim_count = ?,
                            remaining_disruption_cost_basis_points = ?,
                            generation = ?, updated_at = ?, budget_digest = ?
                        WHERE budget_id = ? AND project_id = ? AND generation = ?
                        """,
                        bindings: [
                            .int(record.budget.remainingVictimCount),
                            .int64(record.budget.remainingDisruptionCostBasisPoints),
                            .int64(record.generation),
                            .text(record.updatedAt),
                            .text(record.budgetDigest),
                            .text(record.budgetID),
                            .text(record.projectID),
                            .int64(existing.generation),
                        ]
                    )
                    guard try connection.query("SELECT changes()").first?.first == "1",
                          let stored = try loadDisruptionBudget(
                              budgetID: record.budgetID,
                              projectID: record.projectID,
                              on: connection
                          ), stored == record else {
                        throw SchedulerAdmissionError.stateInvariant("disruption-budget-update")
                    }
                    return stored
                }

                try requireRecordCapacity(
                    SchedulerAdmissionAuthorityTables.budgets,
                    maximum: SchedulerAdmissionStateLimits.maximumDisruptionBudgetCount,
                    on: connection
                )
                try connection.run(
                    """
                    INSERT INTO scheduler_disruption_budgets (
                        budget_id, project_id, remaining_victim_count,
                        remaining_disruption_cost_basis_points, generation,
                        updated_at, budget_digest
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(record.budgetID),
                        .text(record.projectID),
                        .int(record.budget.remainingVictimCount),
                        .int64(record.budget.remainingDisruptionCostBasisPoints),
                        .int64(record.generation),
                        .text(record.updatedAt),
                        .text(record.budgetDigest),
                    ]
                )
                guard let stored = try loadDisruptionBudget(
                    budgetID: record.budgetID,
                    projectID: record.projectID,
                    on: connection
                ), stored == record else {
                    throw SchedulerAdmissionError.stateInvariant("disruption-budget-insert")
                }
                return stored
            }
        }
    }

    public func disruptionBudget(
        budgetID: String,
        projectID: String
    ) throws -> SchedulerDisruptionBudgetRecord? {
        try validateScopedIdentity(budgetID, field: "disruption-budget-id")
        try validateScopedIdentity(projectID, field: "disruption-budget-project-id")
        return try store.withValidatedConnection(readOnly: true) { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.budgets,
                columns: SchedulerAdmissionAuthorityTables.budgetColumns,
                on: connection
            )
            return try loadDisruptionBudget(
                budgetID: budgetID,
                projectID: projectID,
                on: connection
            )
        }
    }

    public func disruptionBudgets(projectID: String) throws -> [SchedulerDisruptionBudgetRecord] {
        try validateScopedIdentity(projectID, field: "disruption-budget-project-id")
        return try store.withValidatedConnection(readOnly: true) { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.budgets,
                columns: SchedulerAdmissionAuthorityTables.budgetColumns,
                on: connection
            )
            let rows = try boundedQuery(
                """
                SELECT budget_id, project_id, remaining_victim_count,
                       remaining_disruption_cost_basis_points, generation,
                       updated_at, budget_digest
                FROM scheduler_disruption_budgets
                WHERE project_id = ?
                ORDER BY budget_id ASC
                LIMIT ?
                """,
                bindings: [
                    .text(projectID),
                    .int(SchedulerAdmissionStateLimits.maximumDisruptionBudgetCount + 1),
                ],
                limit: SchedulerAdmissionStateLimits.maximumDisruptionBudgetCount,
                field: "disruption-budgets",
                on: connection
            )
            return try rows.map(decodeDisruptionBudget)
        }
    }

    public func preemptionIntent(intentID: UUID) throws -> SchedulerPreemptionIntentRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.preemptionIntents,
                columns: SchedulerAdmissionAuthorityTables.preemptionIntentColumns,
                on: connection
            )
            return try loadPreemptionIntent(intentID, on: connection)
        }
    }

    /// Looks up the apply intent using the stable decision/target lineage.
    /// Multiple preemption proposals in one decision therefore never share an
    /// intent row or replay key.
    public func preemptionIntent(
        decisionID: UUID,
        targetWorkloadID: UUID,
        projectUUID: String
    ) throws -> SchedulerPreemptionIntentRecord? {
        guard HostwrightResourceUUID.isValid(projectUUID) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "preemption-project-uuid"
            )
        }
        let intentID = SchedulerAdmissionStableIdentifier.preemptionIntentID(
            decisionID: decisionID,
            targetWorkloadID: targetWorkloadID
        )
        guard let intent = try preemptionIntent(intentID: intentID) else {
            return nil
        }
        guard intent.projectID == projectUUID.lowercased() else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "preemption-project-scope"
            )
        }
        guard intent.proposal.targetWorkloadID == targetWorkloadID else {
            throw SchedulerAdmissionError.stateInvariant(
                "preemption-intent-target-binding"
            )
        }
        return intent
    }

    public func preemptionIntents(projectID: String) throws -> [SchedulerPreemptionIntentRecord] {
        try validateScopedIdentity(projectID, field: "preemption-project-id")
        return try store.withValidatedConnection(readOnly: true) { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.preemptionIntents,
                columns: SchedulerAdmissionAuthorityTables.preemptionIntentColumns,
                on: connection
            )
            let rows = try boundedQuery(
                """
                SELECT intent_id, project_id, proposal_json, intent_digest,
                       status, created_at, updated_at, record_digest
                FROM scheduler_preemption_intents
                WHERE project_id = ?
                ORDER BY intent_id ASC
                LIMIT ?
                """,
                bindings: [
                    .text(projectID),
                    .int(SchedulerAdmissionStateLimits.maximumPreemptionIntentCount + 1),
                ],
                limit: SchedulerAdmissionStateLimits.maximumPreemptionIntentCount,
                field: "preemption-intents",
                on: connection
            )
            return try rows.map(decodePreemptionIntent)
        }
    }

    /// Returns non-terminal preemption intents for bounded daemon restart
    /// recovery.  The query is deterministic and never treats expiry as proof
    /// that a victim runtime is absent.
    public func recoverablePreemptionIntents() throws -> [SchedulerPreemptionRecoveryRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.preemptionIntents,
                columns: SchedulerAdmissionAuthorityTables.preemptionIntentColumns,
                on: connection
            )
            let rows = try boundedQuery(
                """
                SELECT intent_id, project_id, proposal_json, intent_digest,
                       status, created_at, updated_at, record_digest
                FROM scheduler_preemption_intents
                WHERE status IN ('proposed', 'fence-pending', 'fenced')
                ORDER BY intent_id ASC
                LIMIT ?
                """,
                bindings: [
                    .int(SchedulerAdmissionStateLimits.maximumPreemptionIntentCount + 1)
                ],
                limit: SchedulerAdmissionStateLimits.maximumPreemptionIntentCount,
                field: "recoverable-preemption-intents",
                on: connection
            )
            return try rows
                .map(decodePreemptionIntent)
                .map { try validatePreemptionRecoveryLineage($0, on: connection) }
        }
    }

    private func validatePreemptionRecoveryLineage(
        _ intent: SchedulerPreemptionIntentRecord,
        on connection: SQLiteConnection
    ) throws -> SchedulerPreemptionRecoveryRecord {
        guard intent.intentID == SchedulerAdmissionStableIdentifier.preemptionIntentID(
            decisionID: intent.decisionID,
            targetWorkloadID: intent.proposal.targetWorkloadID
        ) else {
            throw SchedulerAdmissionError.stateInvariant(
                "preemption-recovery-intent-lineage"
            )
        }
        guard HostwrightResourceUUID.isValid(intent.projectID),
              let artifact = try loadDecisionArtifact(intent.decisionID, on: connection),
              artifact.projectUUID == intent.projectID.lowercased(),
              artifact.inputDigest == artifact.decision.inputDigest,
              let targetBinding = artifact.binding(
                  for: intent.proposal.targetWorkloadID
              ),
              targetBinding.projectUUID == artifact.projectUUID,
              targetBinding.nodeID == intent.proposal.nodeID,
              let targetDecision = artifact.decision.workloadDecisions.first(
                  where: { $0.workloadID == intent.proposal.targetWorkloadID }
              ),
              targetDecision.outcome == .preemptionProposed,
              targetDecision.preemption == intent.proposal,
              artifact.decisionID == intent.decisionID else {
            throw SchedulerAdmissionError.stateInvariant(
                "preemption-recovery-artifact-lineage"
            )
        }
        guard Set(intent.proposal.victims.map(\.workloadID)).count
                == intent.proposal.victims.count,
              !intent.proposal.victims.contains(where: {
                  $0.workloadID == intent.proposal.targetWorkloadID
              }) else {
            throw SchedulerAdmissionError.stateInvariant(
                "preemption-recovery-victim-lineage"
            )
        }

        let targetReservation = try loadUniqueReservationForRecovery(
            workloadID: intent.proposal.targetWorkloadID,
            projectUUID: artifact.projectUUID,
            on: connection
        )
        if let targetReservation {
            guard targetReservation.decisionID == artifact.decisionID else {
                throw SchedulerAdmissionError.stateInvariant(
                    "preemption-recovery-target-reservation"
                )
            }
            try validateArtifactReservationPair(artifact, targetReservation)
        }
        switch intent.status {
        case .fenced:
            guard targetReservation != nil else {
                throw SchedulerAdmissionError.stateInvariant(
                    "preemption-recovery-target-reservation-missing"
                )
            }
        case .proposed, .fencePending:
            guard targetReservation == nil else {
                throw SchedulerAdmissionError.stateInvariant(
                    "preemption-recovery-target-reservation-unexpected"
                )
            }
        case .applied, .recovered, .rejected:
            throw SchedulerAdmissionError.stateInvariant(
                "preemption-recovery-terminal-intent"
            )
        }

        let victimReservations = try intent.proposal.victims
            .sorted {
                SchedulerOrdering.uuidKey($0.workloadID)
                    < SchedulerOrdering.uuidKey($1.workloadID)
            }
            .map { victim in
                guard let reservation = try loadUniqueReservationForRecovery(
                    workloadID: victim.workloadID,
                    projectUUID: artifact.projectUUID,
                    on: connection
                ) else {
                    throw SchedulerAdmissionError.stateInvariant(
                        "preemption-recovery-victim-reservation-missing"
                    )
                }
                guard reservation.nodeID == victim.nodeID,
                      reservation.resources == victim.allocation,
                      reservation.ownerSubjectID == victim.subjectID,
                      reservation.projectUUID == artifact.projectUUID else {
                    throw SchedulerAdmissionError.stateInvariant(
                        "preemption-recovery-victim-reservation-lineage"
                    )
                }
                guard let victimArtifact = try loadDecisionArtifact(
                    reservation.decisionID,
                    on: connection
                ) else {
                    throw SchedulerAdmissionError.stateInvariant(
                        "preemption-recovery-victim-artifact-missing"
                    )
                }
                try validateArtifactReservationPair(victimArtifact, reservation)
                return reservation
            }

        return SchedulerPreemptionRecoveryRecord(
            intent: intent,
            artifact: artifact,
            targetBinding: targetBinding,
            targetReservation: targetReservation,
            victimReservations: victimReservations
        )
    }

    @discardableResult
    public func transitionPreemptionIntent(
        intentID: UUID,
        expectedRecordDigest: String,
        to status: SchedulerPreemptionIntentStatus,
        updatedAt: String
    ) throws -> SchedulerPreemptionIntentRecord {
        try SchedulerAdmissionValidation.digest(
            expectedRecordDigest,
            field: "preemption-record-digest"
        )
        _ = try SchedulerAdmissionValidation.timestamp(
            updatedAt,
            field: "preemption-updated-at"
        )
        return try store.withValidatedConnection { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.preemptionIntents,
                columns: SchedulerAdmissionAuthorityTables.preemptionIntentColumns,
                on: connection
            )
            return try connection.transaction {
                guard let existing = try loadPreemptionIntent(intentID, on: connection) else {
                    throw SchedulerAdmissionError.notFound(kind: "preemption-intent", id: intentID)
                }
                guard existing.recordDigest == expectedRecordDigest else {
                    throw SchedulerAdmissionError.staleInput(field: "preemption-record-digest")
                }
                guard existing.status.canTransition(to: status) else {
                    throw SchedulerAdmissionError.invalidBinding(
                        field: "preemption-status-transition"
                    )
                }
                try requireUpdatedAtNotBefore(updatedAt, current: existing.updatedAt)
                let next = try SchedulerPreemptionIntentRecord(
                    decisionID: existing.decisionID,
                    intentID: existing.intentID,
                    proposal: existing.proposal,
                    status: status,
                    createdAt: existing.createdAt,
                    updatedAt: updatedAt
                )
                if next == existing { return existing }
                try connection.run(
                    """
                    UPDATE scheduler_preemption_intents
                    SET status = ?, updated_at = ?, record_digest = ?
                    WHERE intent_id = ? AND record_digest = ?
                    """,
                    bindings: [
                        .text(status.rawValue),
                        .text(updatedAt),
                        .text(next.recordDigest),
                        .text(uuidText(intentID)),
                        .text(expectedRecordDigest),
                    ]
                )
                guard try connection.query("SELECT changes()").first?.first == "1",
                      let stored = try loadPreemptionIntent(intentID, on: connection),
                      stored == next else {
                    throw SchedulerAdmissionError.stateInvariant("preemption-intent-transition")
                }
                return stored
            }
        }
    }

    @discardableResult
    public func recordHostPressure(
        record: SchedulerHostPressureRecord
    ) throws -> SchedulerHostPressureRecord {
        try store.withValidatedConnection { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.hostPressure,
                columns: SchedulerAdmissionAuthorityTables.hostPressureColumns,
                on: connection
            )
            return try connection.transaction {
                if let existing = try loadHostPressure(record.nodeID, on: connection) {
                    if existing == record { return existing }
                    guard record.generation > existing.generation else {
                        throw SchedulerAdmissionError.staleInput(field: "pressure-generation")
                    }
                    try requireUpdatedAtNotBefore(record.observedAt, current: existing.observedAt)
                    try connection.run(
                        """
                        UPDATE scheduler_host_pressure
                        SET pressure = ?, energy = ?, generation = ?, observed_at = ?,
                            evidence_digest = ?, policy_state_json = ?, record_digest = ?
                        WHERE node_uuid = ? AND generation = ?
                        """,
                        bindings: [
                            .text(record.posture.pressure.rawValue),
                            .text(record.posture.energy.rawValue),
                            .int64(record.generation),
                            .text(record.observedAt),
                            .text(record.evidenceDigest),
                            .text(try SchedulerAdmissionCanonicalJSON.json(record.policyState)),
                            .text(record.recordDigest),
                            .text(uuidText(record.nodeID)),
                            .int64(existing.generation),
                        ]
                    )
                    guard try connection.query("SELECT changes()").first?.first == "1",
                          let stored = try loadHostPressure(record.nodeID, on: connection),
                          stored == record else {
                        throw SchedulerAdmissionError.stateInvariant("pressure-update")
                    }
                    return stored
                }

                try requireRecordCapacity(
                    SchedulerAdmissionAuthorityTables.hostPressure,
                    maximum: SchedulerAdmissionStateLimits.maximumHostPressureRecordCount,
                    on: connection
                )
                try connection.run(
                    """
                    INSERT INTO scheduler_host_pressure (
                        node_uuid, pressure, energy, generation, observed_at,
                        evidence_digest, policy_state_json, record_digest
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(uuidText(record.nodeID)),
                        .text(record.posture.pressure.rawValue),
                        .text(record.posture.energy.rawValue),
                        .int64(record.generation),
                        .text(record.observedAt),
                        .text(record.evidenceDigest),
                        .text(try SchedulerAdmissionCanonicalJSON.json(record.policyState)),
                        .text(record.recordDigest),
                    ]
                )
                guard let stored = try loadHostPressure(record.nodeID, on: connection),
                      stored == record else {
                    throw SchedulerAdmissionError.stateInvariant("pressure-insert")
                }
                return stored
            }
        }
    }

    public func hostPressure(nodeID: UUID) throws -> SchedulerHostPressureRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.hostPressure,
                columns: SchedulerAdmissionAuthorityTables.hostPressureColumns,
                on: connection
            )
            return try loadHostPressure(nodeID, on: connection)
        }
    }

    public func hostPressures() throws -> [SchedulerHostPressureRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            try requireSchedulerTable(
                SchedulerAdmissionAuthorityTables.hostPressure,
                columns: SchedulerAdmissionAuthorityTables.hostPressureColumns,
                on: connection
            )
            let rows = try boundedQuery(
                """
                SELECT node_uuid, pressure, energy, generation, observed_at,
                       evidence_digest, policy_state_json, record_digest
                FROM scheduler_host_pressure
                ORDER BY node_uuid ASC
                LIMIT ?
                """,
                bindings: [.int(SchedulerAdmissionStateLimits.maximumHostPressureRecordCount + 1)],
                limit: SchedulerAdmissionStateLimits.maximumHostPressureRecordCount,
                field: "host-pressure",
                on: connection
            )
            return try rows.map(decodeHostPressure)
        }
    }

    @discardableResult
    public func commit(
        reservationID: UUID,
        expectedToken: SchedulerFencingToken,
        updatedAt: String
    ) throws -> SchedulerReservationRecord {
        try validateExpectedToken(expectedToken)
        try SchedulerAdmissionValidation.timestamp(updatedAt, field: "updated-at")
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                guard let existing = try loadReservation(reservationID, on: connection) else {
                    throw SchedulerAdmissionError.notFound(
                        kind: "reservation",
                        id: reservationID
                    )
                }
                try requireCurrentStoredToken(
                    existing,
                    expected: expectedToken,
                    on: connection
                )
                switch existing.status {
                case .committed:
                    return existing
                case .pending:
                    try requireUpdatedAtNotBefore(updatedAt, current: existing.updatedAt)
                    try updateStatus(
                        reservationID: reservationID,
                        status: .committed,
                        updatedAt: updatedAt,
                        on: connection
                    )
                case .releasePending, .fenced, .released:
                    throw SchedulerAdmissionError.invalidTransition(
                        reservationID: reservationID,
                        status: existing.status
                    )
                }
                return try requiredReservation(reservationID, on: connection)
            }
        }
    }

    @discardableResult
    public func requestRelease(
        reservationID: UUID,
        expectedToken: SchedulerFencingToken,
        updatedAt: String
    ) throws -> SchedulerReservationRecord {
        try validateExpectedToken(expectedToken)
        try SchedulerAdmissionValidation.timestamp(updatedAt, field: "updated-at")
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                guard let existing = try loadReservation(reservationID, on: connection) else {
                    throw SchedulerAdmissionError.notFound(
                        kind: "reservation",
                        id: reservationID
                    )
                }
                try requireCurrentStoredToken(
                    existing,
                    expected: expectedToken,
                    on: connection
                )
                switch existing.status {
                case .releasePending:
                    return existing
                case .pending, .committed:
                    try requireUpdatedAtNotBefore(updatedAt, current: existing.updatedAt)
                    try updateStatus(
                        reservationID: reservationID,
                        status: .releasePending,
                        updatedAt: updatedAt,
                        on: connection
                    )
                case .fenced, .released:
                    throw SchedulerAdmissionError.invalidTransition(
                        reservationID: reservationID,
                        status: existing.status
                    )
                }
                return try requiredReservation(reservationID, on: connection)
            }
        }
    }

    @discardableResult
    public func fence(
        reservationID: UUID,
        evidence: SchedulerFenceEvidence
    ) throws -> SchedulerReservationRecord {
        try validateFenceEvidence(evidence)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try fenceInTransaction(
                    reservationID: reservationID,
                    evidence: evidence,
                    on: connection
                )
            }
        }
    }

    @discardableResult
    public func release(
        reservationID: UUID,
        expectedToken: SchedulerFencingToken,
        evidence: SchedulerReleaseEvidence
    ) throws -> SchedulerReservationRecord {
        try validateExpectedToken(expectedToken)
        try validateReleaseEvidence(evidence)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                guard let existing = try loadReservation(reservationID, on: connection) else {
                    throw SchedulerAdmissionError.notFound(
                        kind: "reservation",
                        id: reservationID
                    )
                }
                if existing.status == .released {
                    guard expectedToken == existing.fencingToken,
                          existing.releaseEvidence == evidence else {
                        throw SchedulerAdmissionError.invalidEvidence(
                            "release-proof-mismatch"
                        )
                    }
                    return existing
                }
                guard existing.status.reservesCapacity else {
                    throw SchedulerAdmissionError.releaseEvidenceRequired(
                        reservationID: reservationID
                    )
                }

                let state = try requiredFenceState(existing.nodeID, on: connection)
                switch evidence {
                case .verifiedRuntimeAbsence(_, let verifiedAt):
                    try requireCurrentStoredToken(
                        existing,
                        expected: expectedToken,
                        state: state
                    )
                    try requireEvidenceNotBefore(
                        verifiedAt,
                        updatedAt: existing.updatedAt,
                        field: "runtime-absence-verified-at"
                    )
                case .authoritativeFence(
                    let token,
                    let evidenceReservationID,
                    let evidenceWorkloadID,
                    _,
                    let verifiedAt
                ):
                    guard expectedToken == existing.fencingToken else {
                        throw SchedulerAdmissionError.staleFence(
                            nodeID: existing.nodeID,
                            expected: expectedToken,
                            actual: existing.fencingToken
                        )
                    }
                    try requireAuthoritativeEvidence(
                        token: token,
                        reservationID: evidenceReservationID,
                        workloadID: evidenceWorkloadID,
                        record: existing,
                        state: state,
                        field: "release-lineage"
                    )
                    try requireEvidenceNotBefore(
                        verifiedAt,
                        updatedAt: existing.updatedAt,
                        field: "fence-verified-at"
                    )
                    try requireEvidenceNotBefore(
                        verifiedAt,
                        updatedAt: state.updatedAt,
                        field: "fence-verified-at"
                    )
                }

                try updateReleaseEvidence(
                    reservationID: reservationID,
                    evidence: evidence,
                    updatedAt: evidenceTimestamp(evidence),
                    on: connection
                )
                return try requiredReservation(reservationID, on: connection)
            }
        }
    }

    private func fenceInTransaction(
        reservationID: UUID,
        evidence: SchedulerFenceEvidence,
        on connection: SQLiteConnection
    ) throws -> SchedulerReservationRecord {
        guard let existing = try loadReservation(reservationID, on: connection) else {
            throw SchedulerAdmissionError.notFound(
                kind: "reservation",
                id: reservationID
            )
        }
        if existing.status == .fenced {
            guard existing.fenceEvidence == evidence else {
                throw SchedulerAdmissionError.invalidEvidence(
                    "fence-proof-mismatch"
                )
            }
            return existing
        }
        guard existing.status != .released else {
            throw SchedulerAdmissionError.invalidTransition(
                reservationID: reservationID,
                status: existing.status
            )
        }
        let state = try requiredFenceState(existing.nodeID, on: connection)
        try requireAuthoritativeEvidence(
            token: evidence.token,
            reservationID: evidence.reservationID,
            workloadID: evidence.workloadID,
            record: existing,
            state: state,
            field: "fence-lineage"
        )
        try requireEvidenceNotBefore(
            evidence.verifiedAt,
            updatedAt: existing.updatedAt,
            field: "fence-evidence-at"
        )
        try requireEvidenceNotBefore(
            evidence.verifiedAt,
            updatedAt: state.updatedAt,
            field: "fence-evidence-at"
        )
        try updateFenceEvidence(
            reservationID: reservationID,
            status: .fenced,
            evidence: evidence,
            updatedAt: evidence.verifiedAt,
            on: connection
        )
        return try requiredReservation(reservationID, on: connection)
    }

    private func requireSchedulerTable(
        _ table: String,
        columns requiredColumns: Set<String>,
        on connection: SQLiteConnection
    ) throws {
        guard try connection.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            bindings: [.text(table)]
        ).first != nil else {
            throw SchedulerAdmissionError.stateInvariant("scheduler-schema-missing:\(table)")
        }
        let columns = Set(
            try connection.query("PRAGMA table_info(\(table))")
                .compactMap { $0.count > 1 ? $0[1] : nil }
        )
        guard requiredColumns.isSubset(of: columns) else {
            throw SchedulerAdmissionError.stateInvariant("scheduler-schema-columns:\(table)")
        }
    }

    private func validateScopedIdentity(_ value: String, field: String) throws {
        try SchedulerAdmissionValidation.scopedIdentifier(value, field: field)
    }

    private func boundedJSON<T: Encodable>(_ value: T, field: String) throws -> String {
        let json = try SchedulerAdmissionCanonicalJSON.json(value)
        guard json.utf8.count <= SchedulerAdmissionStateLimits.maximumRecordJSONBytes else {
            throw SchedulerAdmissionError.invalidBinding(field: "\(field)-size")
        }
        return json
    }

    private func boundedQuery(
        _ sql: String,
        bindings: [SQLiteValue],
        limit: Int,
        field: String,
        on connection: SQLiteConnection
    ) throws -> [[String?]] {
        let rows = try connection.query(sql, bindings: bindings)
        guard rows.count <= limit else {
            throw SchedulerAdmissionError.stateInvariant("scheduler-query-limit:\(field)")
        }
        return rows
    }

    private func requireRecordCapacity(
        _ table: String,
        maximum: Int,
        on connection: SQLiteConnection
    ) throws {
        guard let countRow = try connection.query(
            "SELECT COUNT(*) FROM \(table)"
        ).first,
        let countText = countRow.first ?? nil,
        let count = Int(countText), count < maximum else {
            throw SchedulerAdmissionError.stateInvariant("scheduler-record-limit:\(table)")
        }
    }

    private func decodeCanonical<T: Codable>(
        _ type: T.Type,
        json: String,
        field: String
    ) throws -> T {
        guard let data = json.data(using: .utf8),
              data.count <= SchedulerAdmissionStateLimits.maximumRecordJSONBytes else {
            throw SchedulerAdmissionError.stateInvariant("scheduler-json-size:\(field)")
        }
        do {
            let value = try JSONDecoder().decode(type, from: data)
            guard try boundedJSON(value, field: field) == json else {
                throw SchedulerAdmissionError.stateInvariant("scheduler-json-canonicality:\(field)")
            }
            return value
        } catch let error as SchedulerAdmissionError {
            throw error
        } catch {
            throw SchedulerAdmissionError.stateInvariant("scheduler-json-shape:\(field)")
        }
    }

    private func loadProjectAuthority(
        where predicate: String,
        value: String,
        on connection: SQLiteConnection
    ) throws -> SchedulerProjectAuthoritySnapshot? {
        let rows = try connection.query(
            """
            SELECT id, name, resource_uuid, manifest_hash, manifest_version, updated_at
            FROM projects
            WHERE \(predicate)
            LIMIT 1
            """,
            bindings: [.text(value)]
        )
        guard let row = rows.first else { return nil }
        guard row.count == 6,
              let projectID = row[0],
              let projectName = row[1],
              let resourceUUID = row[2],
              let manifestDigest = row[3],
              let manifestVersionText = row[4],
              let manifestVersion = Int64(manifestVersionText),
              let updatedAt = row[5] else {
            throw SchedulerAdmissionError.stateInvariant(
                "project-authority-row-shape"
            )
        }
        return try SchedulerProjectAuthoritySnapshot(
            projectID: projectID,
            projectName: projectName,
            resourceUUID: resourceUUID,
            manifestDigest: manifestDigest,
            manifestVersion: manifestVersion,
            updatedAt: updatedAt
        )
    }

    private func loadFairnessAccounting(
        subjectID: String,
        projectID: String,
        on connection: SQLiteConnection
    ) throws -> SchedulerFairnessAccountingRecord? {
        let rows = try connection.query(
            """
            SELECT subject_id, project_id, state_json, generation, updated_at,
                   accounting_digest
            FROM scheduler_fairness_accounting
            WHERE subject_id = ? AND project_id = ?
            LIMIT 1
            """,
            bindings: [.text(subjectID), .text(projectID)]
        )
        guard let row = rows.first else { return nil }
        return try decodeFairnessAccounting(row)
    }

    private func decodeFairnessAccounting(
        _ row: [String?]
    ) throws -> SchedulerFairnessAccountingRecord {
        guard row.count == 6,
              let subjectID = row[0],
              let projectID = row[1],
              let stateJSON = row[2],
              let generationText = row[3],
              let generation = Int64(generationText),
              let updatedAt = row[4],
              let digest = row[5] else {
            throw SchedulerAdmissionError.stateInvariant("fairness-accounting-row-shape")
        }
        let state = try decodeCanonical(
            SchedulerFairnessState.self,
            json: stateJSON,
            field: "fairness-state"
        )
        guard state.subjectID == subjectID, state.projectID == projectID else {
            throw SchedulerAdmissionError.stateInvariant("fairness-accounting-identity")
        }
        let record = try SchedulerFairnessAccountingRecord(
            state: state,
            generation: generation,
            updatedAt: updatedAt
        )
        guard record.accountingDigest == digest else {
            throw SchedulerAdmissionError.stateInvariant("fairness-accounting-digest")
        }
        return record
    }

    private func loadDisruptionBudget(
        budgetID: String,
        projectID: String,
        on connection: SQLiteConnection
    ) throws -> SchedulerDisruptionBudgetRecord? {
        let rows = try connection.query(
            """
            SELECT budget_id, project_id, remaining_victim_count,
                   remaining_disruption_cost_basis_points, generation,
                   updated_at, budget_digest
            FROM scheduler_disruption_budgets
            WHERE budget_id = ? AND project_id = ?
            LIMIT 1
            """,
            bindings: [.text(budgetID), .text(projectID)]
        )
        guard let row = rows.first else { return nil }
        return try decodeDisruptionBudget(row)
    }

    private func decodeDisruptionBudget(
        _ row: [String?]
    ) throws -> SchedulerDisruptionBudgetRecord {
        guard row.count == 7,
              let budgetID = row[0],
              let projectID = row[1],
              let victimCountText = row[2],
              let victimCount = Int(victimCountText),
              let costText = row[3],
              let cost = Int64(costText),
              let generationText = row[4],
              let generation = Int64(generationText),
              let updatedAt = row[5],
              let digest = row[6] else {
            throw SchedulerAdmissionError.stateInvariant("disruption-budget-row-shape")
        }
        let budget = try SchedulerDisruptionBudget(
            budgetID: budgetID,
            projectID: projectID,
            remainingVictimCount: victimCount,
            remainingDisruptionCostBasisPoints: cost
        )
        let record = try SchedulerDisruptionBudgetRecord(
            budget: budget,
            generation: generation,
            updatedAt: updatedAt
        )
        guard record.budgetDigest == digest else {
            throw SchedulerAdmissionError.stateInvariant("disruption-budget-digest")
        }
        return record
    }

    private func validatePreemptionIntent(
        _ intent: SchedulerPreemptionIntentRecord
    ) throws {
        try validateScopedIdentity(intent.projectID, field: "preemption-project-id")
        let proposalJSON = try boundedJSON(
            SchedulerPreemptionIntentStoragePayload(
                decisionID: intent.decisionID,
                intentID: intent.intentID,
                proposal: intent.proposal
            ),
            field: "preemption-proposal"
        )
        guard intent.proposal.victims.allSatisfy({ $0.projectID == intent.projectID }),
              intent.proposal.intentDigest.count == 64 else {
            throw SchedulerAdmissionError.invalidBinding(field: "preemption-project-scope")
        }
        guard proposalJSON.utf8.count <= SchedulerAdmissionStateLimits.maximumRecordJSONBytes else {
            throw SchedulerAdmissionError.invalidBinding(field: "preemption-proposal-size")
        }
    }

    private func validatePreemptionBudgets(
        _ intent: SchedulerPreemptionIntentRecord,
        on connection: SQLiteConnection
    ) throws {
        var budgetIDs = Set(intent.proposal.explanation.budgetIDs)
        budgetIDs.formUnion(intent.proposal.victims.compactMap(\.budgetID))
        for budgetID in budgetIDs {
            guard try loadDisruptionBudget(
                budgetID: budgetID,
                projectID: intent.projectID,
                on: connection
            ) != nil else {
                throw SchedulerAdmissionError.stateInvariant(
                    "preemption-budget-missing:\(budgetID)"
                )
            }
        }
    }

    private func insertPreemptionIntentInTransaction(
        _ intent: SchedulerPreemptionIntentRecord,
        on connection: SQLiteConnection
    ) throws -> SchedulerPreemptionIntentRecord {
        if let existing = try loadPreemptionIntent(intent.intentID, on: connection) {
            guard existing == intent else {
                throw SchedulerAdmissionError.stateInvariant(
                    "preemption-intent-replay-mismatch"
                )
            }
            return existing
        }
        try validatePreemptionBudgets(intent, on: connection)
        try requireRecordCapacity(
            SchedulerAdmissionAuthorityTables.preemptionIntents,
            maximum: SchedulerAdmissionStateLimits.maximumPreemptionIntentCount,
            on: connection
        )
        try connection.run(
            """
            INSERT INTO scheduler_preemption_intents (
                intent_id, project_id, proposal_json, intent_digest,
                status, created_at, updated_at, record_digest
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(uuidText(intent.intentID)),
                .text(intent.projectID),
                .text(try boundedJSON(
                    SchedulerPreemptionIntentStoragePayload(
                        decisionID: intent.decisionID,
                        intentID: intent.intentID,
                        proposal: intent.proposal
                    ),
                    field: "preemption-proposal"
                )),
                .text(intent.proposal.intentDigest),
                .text(intent.status.rawValue),
                .text(intent.createdAt),
                .text(intent.updatedAt),
                .text(intent.recordDigest),
            ]
        )
        guard let stored = try loadPreemptionIntent(intent.intentID, on: connection),
              stored == intent else {
            throw SchedulerAdmissionError.stateInvariant("preemption-intent-insert")
        }
        return stored
    }

    private func updatePreemptionIntentInTransaction(
        existing: SchedulerPreemptionIntentRecord,
        next: SchedulerPreemptionIntentRecord,
        on connection: SQLiteConnection
    ) throws {
        guard existing.intentID == next.intentID,
              existing.proposal == next.proposal,
              existing.status.canTransition(to: next.status) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "preemption-status-transition"
            )
        }
        try requireUpdatedAtNotBefore(
            next.updatedAt,
            current: existing.updatedAt
        )
        try connection.run(
            """
            UPDATE scheduler_preemption_intents
            SET status = ?, updated_at = ?, record_digest = ?
            WHERE intent_id = ? AND record_digest = ?
            """,
            bindings: [
                .text(next.status.rawValue),
                .text(next.updatedAt),
                .text(next.recordDigest),
                .text(uuidText(next.intentID)),
                .text(existing.recordDigest),
            ]
        )
        guard try connection.query("SELECT changes()").first?.first == "1",
              let stored = try loadPreemptionIntent(next.intentID, on: connection),
              stored == next else {
            throw SchedulerAdmissionError.stateInvariant(
                "preemption-intent-transition"
            )
        }
    }

    private func decrementPreemptionBudgets(
        intent: SchedulerPreemptionIntentRecord,
        on connection: SQLiteConnection
    ) throws {
        struct Aggregate {
            var victimCount: Int
            var disruptionCost: Int64
        }
        var aggregates: [String: Aggregate] = [:]
        for victim in intent.proposal.victims {
            guard let budgetID = victim.budgetID else {
                throw SchedulerAdmissionError.invalidBinding(
                    field: "preemption-budget-required"
                )
            }
            guard let existing = aggregates[budgetID] else {
                aggregates[budgetID] = Aggregate(
                    victimCount: 1,
                    disruptionCost: victim.disruptionCostBasisPoints
                )
                continue
            }
            let (count, countOverflow) = existing.victimCount.addingReportingOverflow(1)
            let (cost, costOverflow) = existing.disruptionCost.addingReportingOverflow(
                victim.disruptionCostBasisPoints
            )
            guard !countOverflow, !costOverflow else {
                throw SchedulerAdmissionError.resourceArithmetic(
                    resource: "preemption-budget-aggregate"
                )
            }
            aggregates[budgetID] = Aggregate(
                victimCount: count,
                disruptionCost: cost
            )
        }

        for budgetID in aggregates.keys.sorted() {
            guard let aggregate = aggregates[budgetID],
                  let existing = try loadDisruptionBudget(
                      budgetID: budgetID,
                      projectID: intent.projectID,
                      on: connection
                  ) else {
                throw SchedulerAdmissionError.stateInvariant(
                    "preemption-budget-missing:\(budgetID)"
                )
            }
            try requireUpdatedAtNotBefore(
                intent.updatedAt,
                current: existing.updatedAt
            )
            guard existing.budget.remainingVictimCount >= aggregate.victimCount,
                  existing.budget.remainingDisruptionCostBasisPoints >= aggregate.disruptionCost else {
                throw SchedulerAdmissionError.invalidEvidence(
                    "preemption-budget-exhausted:\(budgetID)"
                )
            }
            let remainingCost = existing.budget.remainingDisruptionCostBasisPoints
                - aggregate.disruptionCost
            let nextGeneration = existing.generation.addingReportingOverflow(1)
            guard !nextGeneration.overflow, nextGeneration.partialValue >= 1 else {
                throw SchedulerAdmissionError.stateInvariant(
                    "preemption-budget-generation"
                )
            }
            let nextBudget = try SchedulerDisruptionBudget(
                budgetID: existing.budget.budgetID,
                projectID: existing.budget.projectID,
                remainingVictimCount: existing.budget.remainingVictimCount
                    - aggregate.victimCount,
                remainingDisruptionCostBasisPoints: remainingCost
            )
            let nextRecord = try SchedulerDisruptionBudgetRecord(
                budget: nextBudget,
                generation: nextGeneration.partialValue,
                updatedAt: intent.updatedAt
            )
            try connection.run(
                """
                UPDATE scheduler_disruption_budgets
                SET remaining_victim_count = ?,
                    remaining_disruption_cost_basis_points = ?,
                    generation = ?, updated_at = ?, budget_digest = ?
                WHERE budget_id = ? AND project_id = ? AND generation = ?
                """,
                bindings: [
                    .int(nextBudget.remainingVictimCount),
                    .int64(nextBudget.remainingDisruptionCostBasisPoints),
                    .int64(nextRecord.generation),
                    .text(nextRecord.updatedAt),
                    .text(nextRecord.budgetDigest),
                    .text(existing.budgetID),
                    .text(existing.projectID),
                    .int64(existing.generation),
                ]
            )
            guard try connection.query("SELECT changes()").first?.first == "1",
                  let stored = try loadDisruptionBudget(
                      budgetID: budgetID,
                      projectID: intent.projectID,
                      on: connection
                  ), stored == nextRecord else {
                throw SchedulerAdmissionError.staleInput(
                    field: "preemption-budget-generation"
                )
            }
        }
    }

    private func loadPreemptionIntent(
        _ intentID: UUID,
        on connection: SQLiteConnection
    ) throws -> SchedulerPreemptionIntentRecord? {
        let rows = try connection.query(
            """
            SELECT intent_id, project_id, proposal_json, intent_digest,
                   status, created_at, updated_at, record_digest
            FROM scheduler_preemption_intents
            WHERE intent_id = ?
            LIMIT 1
            """,
            bindings: [.text(uuidText(intentID))]
        )
        guard let row = rows.first else { return nil }
        return try decodePreemptionIntent(row)
    }

    private func decodePreemptionIntent(
        _ row: [String?]
    ) throws -> SchedulerPreemptionIntentRecord {
        guard row.count == 8,
              let intentText = row[0],
              let intentID = UUID(uuidString: intentText),
              let projectID = row[1],
              let proposalJSON = row[2],
              let intentDigest = row[3],
              let statusText = row[4],
              let status = SchedulerPreemptionIntentStatus(rawValue: statusText),
              let createdAt = row[5],
              let updatedAt = row[6],
              let recordDigest = row[7] else {
            throw SchedulerAdmissionError.stateInvariant("preemption-intent-row-shape")
        }
        let payload = try decodeCanonical(
            SchedulerPreemptionIntentStoragePayload.self,
            json: proposalJSON,
            field: "preemption-proposal"
        )
        guard payload.proposal.projectID == projectID,
              payload.proposal.intentDigest == intentDigest,
              payload.intentID == SchedulerAdmissionStableIdentifier.preemptionIntentID(
                  decisionID: payload.decisionID,
                  targetWorkloadID: payload.proposal.targetWorkloadID
              ),
              payload.intentID == intentID else {
            throw SchedulerAdmissionError.stateInvariant("preemption-intent-binding")
        }
        let record = try SchedulerPreemptionIntentRecord(
            decisionID: payload.decisionID,
            intentID: intentID,
            proposal: payload.proposal,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        guard record.recordDigest == recordDigest else {
            throw SchedulerAdmissionError.stateInvariant("preemption-record-digest")
        }
        return record
    }

    private func loadHostPressure(
        _ nodeID: UUID,
        on connection: SQLiteConnection
    ) throws -> SchedulerHostPressureRecord? {
        let rows = try connection.query(
            """
            SELECT node_uuid, pressure, energy, generation, observed_at,
                   evidence_digest, policy_state_json, record_digest
            FROM scheduler_host_pressure
            WHERE node_uuid = ?
            LIMIT 1
            """,
            bindings: [.text(uuidText(nodeID))]
        )
        guard let row = rows.first else { return nil }
        return try decodeHostPressure(row)
    }

    private func decodeHostPressure(
        _ row: [String?]
    ) throws -> SchedulerHostPressureRecord {
        guard row.count == 8,
              let nodeText = row[0],
              let nodeID = UUID(uuidString: nodeText),
              let pressureText = row[1],
              let pressure = SchedulerPressurePosture(rawValue: pressureText),
              let energyText = row[2],
              let energy = SchedulerEnergyPosture(rawValue: energyText),
              let generationText = row[3],
              let generation = Int64(generationText),
              let observedAt = row[4],
              let evidenceDigest = row[5],
              let policyStateJSON = row[6],
              let recordDigest = row[7] else {
            throw SchedulerAdmissionError.stateInvariant("pressure-row-shape")
        }
        guard let policyData = policyStateJSON.data(using: .utf8) else {
            throw SchedulerAdmissionError.stateInvariant("pressure-policy-state-encoding")
        }
        let policyState: SchedulerHostPressurePolicyState
        do {
            policyState = try JSONDecoder().decode(
                SchedulerHostPressurePolicyState.self,
                from: policyData
            )
        } catch let error as SchedulerAdmissionError {
            throw error
        } catch {
            throw SchedulerAdmissionError.stateInvariant("pressure-policy-state-shape")
        }
        guard try SchedulerAdmissionCanonicalJSON.json(policyState) == policyStateJSON else {
            throw SchedulerAdmissionError.stateInvariant("pressure-policy-state-canonicality")
        }
        let record = try SchedulerHostPressureRecord(
            nodeID: nodeID,
            posture: SchedulerHostPosture(pressure: pressure, energy: energy),
            generation: generation,
            observedAt: observedAt,
            evidenceDigest: evidenceDigest,
            policyState: policyState
        )
        guard record.recordDigest == recordDigest else {
            throw SchedulerAdmissionError.stateInvariant("pressure-record-digest")
        }
        return record
    }

    private func validateNodeCapacitySnapshot(
        _ snapshot: SchedulerNodeCapacitySnapshot
    ) throws {
        guard snapshot.capacityDigest == SchedulerNodeCapacitySnapshot.digest(for: snapshot.capacity) else {
            throw SchedulerAdmissionError.invalidBinding(field: "node-capacity-digest")
        }
        try SchedulerAdmissionValidation.digest(
            snapshot.capacityDigest,
            field: "node-capacity-digest"
        )
        guard snapshot.generation >= 1 else {
            throw SchedulerAdmissionError.invalidBinding(field: "node-capacity-generation")
        }
        try SchedulerAdmissionValidation.timestamp(
            snapshot.observedAt,
            field: "node-capacity-observed-at"
        )
    }

    private func validateRecoveryEvidence(
        _ evidence: SchedulerNodeRecoveryEvidence
    ) throws {
        guard evidence.expectedNodeEpoch >= 1 else {
            throw SchedulerAdmissionError.invalidEvidence("expected-node-epoch")
        }
        guard evidence.newNodeEpoch > evidence.expectedNodeEpoch else {
            throw SchedulerAdmissionError.invalidEvidence("recovery-epoch-not-newer")
        }
        try SchedulerAdmissionValidation.evidenceDigest(
            evidence.evidenceDigest,
            field: "recovery-evidence-digest"
        )
        try SchedulerAdmissionValidation.timestamp(
            evidence.verifiedAt,
            field: "recovery-evidence-at"
        )
    }

    private func validateAdmissionBinding(
        _ binding: SchedulerAdmissionBinding
    ) throws {
        _ = try SchedulerAdmissionBinding(
            decisionID: binding.decisionID,
            workloadID: binding.workloadID,
            nodeID: binding.nodeID,
            resources: binding.resources,
            nodeCapacityDigest: binding.nodeCapacityDigest,
            nodeCapacityGeneration: binding.nodeCapacityGeneration,
            inputDigest: binding.inputDigest,
            configDigest: binding.configDigest,
            profileDigest: binding.profileDigest,
            lifecyclePlanDigest: binding.lifecyclePlanDigest,
            ownerSubjectID: binding.ownerSubjectID,
            projectUUID: binding.projectUUID,
            createdAt: binding.createdAt,
            expiresAt: binding.expiresAt
        )
        try validateLeaseWindow(
            createdAt: binding.createdAt,
            expiresAt: binding.expiresAt,
            field: "binding-lease"
        )
    }

    private func validateLeaseWindow(
        createdAt: String,
        expiresAt: String,
        field: String
    ) throws {
        let createdDate = try SchedulerAdmissionValidation.timestamp(
            createdAt,
            field: "\(field)-created-at"
        )
        let expiresDate = try SchedulerAdmissionValidation.timestamp(
            expiresAt,
            field: "\(field)-expires-at"
        )
        guard expiresDate > createdDate,
              expiresDate.timeIntervalSince(createdDate)
                <= TimeInterval(SchedulerAdmissionStateLimits.reservationLeaseDurationSeconds) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "\(field)-duration"
            )
        }
    }

    private func validateAdmissionAuthority(
        _ authority: SchedulerAdmissionAuthority
    ) throws {
        _ = try SchedulerAdmissionAuthority(
            nodeCapacityDigest: authority.nodeCapacityDigest,
            nodeCapacityGeneration: authority.nodeCapacityGeneration,
            inputDigest: authority.inputDigest,
            configDigest: authority.configDigest,
            profileDigest: authority.profileDigest,
            lifecyclePlanDigest: authority.lifecyclePlanDigest,
            expectedNodeEpoch: authority.expectedNodeEpoch
        )
    }

    private func validateExpectedToken(
        _ token: SchedulerFencingToken
    ) throws {
        _ = try SchedulerFencingToken(
            nodeEpoch: token.nodeEpoch,
            reservationSequence: token.reservationSequence
        )
    }

    private func requireAuthorityMatches(
        binding: SchedulerAdmissionBinding,
        authority: SchedulerAdmissionAuthority
    ) throws {
        guard authority.nodeCapacityDigest == binding.nodeCapacityDigest else {
            throw SchedulerAdmissionError.staleInput(field: "node-capacity-digest")
        }
        guard authority.nodeCapacityGeneration == binding.nodeCapacityGeneration else {
            throw SchedulerAdmissionError.staleInput(field: "node-capacity-generation")
        }
        guard authority.inputDigest == binding.inputDigest else {
            throw SchedulerAdmissionError.staleInput(field: "input-digest")
        }
        guard authority.configDigest == binding.configDigest else {
            throw SchedulerAdmissionError.staleInput(field: "config-digest")
        }
        guard authority.profileDigest == binding.profileDigest else {
            throw SchedulerAdmissionError.staleInput(field: "profile-digest")
        }
        guard authority.lifecyclePlanDigest == binding.lifecyclePlanDigest else {
            throw SchedulerAdmissionError.staleInput(field: "lifecycle-plan-digest")
        }
    }

    private func requireExpectedNodeEpoch(
        _ expected: Int64,
        current: Int64,
        nodeID: UUID
    ) throws {
        guard expected == current else {
            throw SchedulerAdmissionError.staleNodeEpoch(
                nodeID: nodeID,
                expected: expected,
                actual: current
            )
        }
    }

    private func loadNodeCapacity(
        _ nodeID: UUID,
        generation: Int64? = nil,
        on connection: SQLiteConnection
    ) throws -> SchedulerNodeCapacitySnapshot? {
        let rows: [[String?]]
        if let generation {
            rows = try connection.query(
                """
                SELECT capacity_json, capacity_digest, generation, observed_at, updated_at
                FROM scheduler_node_capacity_snapshots
                WHERE node_uuid = ? AND generation = ?
                LIMIT 1
                """,
                bindings: [.text(uuidText(nodeID)), .int64(generation)]
            )
        } else {
            rows = try connection.query(
                """
                SELECT capacity_json, capacity_digest, generation, observed_at, updated_at
                FROM scheduler_node_capacity_snapshots
                WHERE node_uuid = ?
                ORDER BY generation DESC
                LIMIT 1
                """,
                bindings: [.text(uuidText(nodeID))]
            )
        }
        guard let row = rows.first else { return nil }
        guard row.count == 5,
              let vectorJSON = row[0],
              let capacityDigest = row[1],
              let generationText = row[2],
              let generation = Int64(generationText),
              let observedAt = row[3],
              let updatedAt = row[4] else {
            throw SchedulerAdmissionError.stateInvariant("node-capacity-row-shape")
        }
        let capacity = try SchedulerAdmissionCanonicalJSON.vector(from: vectorJSON)
        guard timestamp(updatedAt) >= timestamp(observedAt) else {
            throw SchedulerAdmissionError.stateInvariant("node-capacity-timestamp-order")
        }
        let snapshot = try SchedulerNodeCapacitySnapshot(
            nodeID: nodeID,
            capacity: capacity,
            capacityDigest: capacityDigest,
            generation: generation,
            observedAt: observedAt
        )
        guard snapshot.capacityDigest == capacityDigest else {
            throw SchedulerAdmissionError.stateInvariant("node-capacity-digest")
        }
        return snapshot
    }

    private func ensureFenceState(
        _ nodeID: UUID,
        initialUpdatedAt: String,
        on connection: SQLiteConnection
    ) throws {
        if try loadFenceState(nodeID, on: connection) != nil {
            return
        }
        try connection.run(
            """
            INSERT INTO scheduler_fence_state (
                node_uuid, node_epoch, next_reservation_sequence, updated_at,
                recovery_evidence_digest, recovery_evidence_at
            ) VALUES (?, 1, 1, ?, NULL, NULL)
            """,
            bindings: [.text(uuidText(nodeID)), .text(initialUpdatedAt)]
        )
    }

    private func loadFenceState(
        _ nodeID: UUID,
        on connection: SQLiteConnection
    ) throws -> SchedulerFenceStateSnapshot? {
        let rows = try connection.query(
            """
            SELECT node_epoch, next_reservation_sequence, updated_at,
                   recovery_evidence_digest, recovery_evidence_at
            FROM scheduler_fence_state
            WHERE node_uuid = ?
            LIMIT 1
            """,
            bindings: [.text(uuidText(nodeID))]
        )
        guard let row = rows.first else { return nil }
        guard row.count == 5,
              let epochText = row[0], let nodeEpoch = Int64(epochText), nodeEpoch >= 1,
              let sequenceText = row[1], let nextSequence = Int64(sequenceText),
              nextSequence >= 1,
              let updatedAt = row[2] else {
            throw SchedulerAdmissionError.stateInvariant("fence-state-row-shape")
        }
        try SchedulerAdmissionValidation.timestamp(updatedAt, field: "fence-state-updated-at")
        let recoveryDigest = row[3]
        let recoveryAt = row[4]
        guard (recoveryDigest == nil) == (recoveryAt == nil) else {
            throw SchedulerAdmissionError.stateInvariant("fence-state-recovery-shape")
        }
        if let recoveryDigest, let recoveryAt {
            try SchedulerAdmissionValidation.evidenceDigest(
                recoveryDigest,
                field: "recovery-evidence-digest"
            )
            try SchedulerAdmissionValidation.timestamp(
                recoveryAt,
                field: "recovery-evidence-at"
            )
            guard timestamp(recoveryAt) >= timestamp(updatedAt) else {
                throw SchedulerAdmissionError.stateInvariant(
                    "fence-state-recovery-time-order"
                )
            }
        }
        return try SchedulerFenceStateSnapshot(
            nodeID: nodeID,
            nodeEpoch: nodeEpoch,
            nextReservationSequence: nextSequence,
            updatedAt: updatedAt,
            recoveryEvidenceDigest: recoveryDigest,
            recoveryEvidenceAt: recoveryAt
        )
    }

    private func requiredFenceState(
        _ nodeID: UUID,
        on connection: SQLiteConnection
    ) throws -> SchedulerFenceStateSnapshot {
        guard let state = try loadFenceState(nodeID, on: connection) else {
            throw SchedulerAdmissionError.stateInvariant("fence-state-missing")
        }
        return state
    }

    private func allocateReservationToken(
        nodeID: UUID,
        state: SchedulerFenceStateSnapshot,
        on connection: SQLiteConnection
    ) throws -> SchedulerFencingToken {
        let sequence = state.nextReservationSequence
        let (nextSequence, overflow) = sequence.addingReportingOverflow(1)
        guard !overflow, nextSequence > 0 else {
            throw SchedulerAdmissionError.fencingTokenExhausted(nodeID: nodeID)
        }
        let token = try SchedulerFencingToken(
            nodeEpoch: state.nodeEpoch,
            reservationSequence: sequence
        )
        try connection.run(
            """
            UPDATE scheduler_fence_state
            SET next_reservation_sequence = ?
            WHERE node_uuid = ? AND node_epoch = ? AND next_reservation_sequence = ?
            """,
            bindings: [
                .int64(nextSequence),
                .text(uuidText(nodeID)),
                .int64(state.nodeEpoch),
                .int64(sequence),
            ]
        )
        guard let stored = try loadFenceState(nodeID, on: connection),
              stored.nodeEpoch == state.nodeEpoch,
              stored.nextReservationSequence == nextSequence else {
            throw SchedulerAdmissionError.stateInvariant(
                "reservation-sequence-persisted-differently"
            )
        }
        return token
    }

    private func requireCurrentStoredToken(
        _ reservation: SchedulerReservationRecord,
        expected: SchedulerFencingToken,
        on connection: SQLiteConnection
    ) throws {
        let state = try requiredFenceState(reservation.nodeID, on: connection)
        try requireCurrentStoredToken(reservation, expected: expected, state: state)
    }

    private func requireCurrentStoredToken(
        _ reservation: SchedulerReservationRecord,
        expected: SchedulerFencingToken,
        state: SchedulerFenceStateSnapshot
    ) throws {
        guard expected == reservation.fencingToken else {
            throw SchedulerAdmissionError.staleFence(
                nodeID: reservation.nodeID,
                expected: expected,
                actual: reservation.fencingToken
            )
        }
        guard expected.nodeEpoch == state.nodeEpoch else {
            throw SchedulerAdmissionError.staleNodeEpoch(
                nodeID: reservation.nodeID,
                expected: expected.nodeEpoch,
                actual: state.nodeEpoch
            )
        }
        guard expected.reservationSequence < state.nextReservationSequence else {
            throw SchedulerAdmissionError.stateInvariant(
                "reservation-sequence-not-allocated"
            )
        }
    }

    private func requireAllocatedReservationToken(
        _ token: SchedulerFencingToken,
        state: SchedulerFenceStateSnapshot,
        nodeID: UUID
    ) throws {
        guard token.nodeEpoch == state.nodeEpoch else {
            throw SchedulerAdmissionError.staleNodeEpoch(
                nodeID: nodeID,
                expected: token.nodeEpoch,
                actual: state.nodeEpoch
            )
        }
        guard token.reservationSequence < state.nextReservationSequence else {
            throw SchedulerAdmissionError.stateInvariant(
                "reservation-sequence-not-allocated"
            )
        }
    }

    private func requireAuthoritativeEvidence(
        token: SchedulerFencingToken,
        reservationID: UUID,
        workloadID: UUID,
        record: SchedulerReservationRecord,
        state: SchedulerFenceStateSnapshot,
        field: String
    ) throws {
        guard reservationID == record.reservationID,
              workloadID == record.workloadID,
              token.reservationSequence == record.fencingToken.reservationSequence else {
            throw SchedulerAdmissionError.invalidEvidence(field)
        }
        guard token.nodeEpoch == state.nodeEpoch else {
            throw SchedulerAdmissionError.staleNodeEpoch(
                nodeID: record.nodeID,
                expected: token.nodeEpoch,
                actual: state.nodeEpoch
            )
        }
        guard token.reservationSequence < state.nextReservationSequence else {
            throw SchedulerAdmissionError.invalidEvidence(
                "reservation-sequence-not-allocated"
            )
        }
        guard token.nodeEpoch > record.fencingToken.nodeEpoch else {
            throw SchedulerAdmissionError.invalidEvidence(
                "fencing-token-not-newer"
            )
        }
    }

    private func insertReservation(
        binding: SchedulerAdmissionBinding,
        reservationID: UUID,
        fencingToken: SchedulerFencingToken,
        on connection: SQLiteConnection
    ) throws {
        try connection.run(
            """
            INSERT INTO scheduler_reservations (
                reservation_id, decision_id, workload_uuid, node_uuid,
                resource_vector_json, capacity_digest, capacity_generation,
                input_digest, config_digest, profile_digest, lifecycle_plan_digest,
                owner_subject_id, project_uuid, status, created_at, updated_at,
                expires_at, fencing_node_epoch, fencing_reservation_sequence,
                fence_evidence_digest, fence_evidence_at, fence_evidence_node_epoch,
                fence_evidence_reservation_sequence, fence_evidence_reservation_id,
                fence_evidence_workload_uuid, release_evidence_kind,
                release_evidence_digest, release_evidence_at, release_evidence_node_epoch,
                release_evidence_reservation_sequence, release_evidence_reservation_id,
                release_evidence_workload_uuid
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                      NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                      NULL, NULL, NULL)
            """,
            bindings: [
                .text(uuidText(reservationID)),
                .text(uuidText(binding.decisionID)),
            ] + bindingValues(
                binding: binding,
                reservationID: reservationID,
                fencingToken: fencingToken,
                omitReservationID: true
            )
        )
    }

    private func bindingValues(
        binding: SchedulerAdmissionBinding,
        reservationID: UUID,
        fencingToken: SchedulerFencingToken,
        omitReservationID: Bool = false
    ) -> [SQLiteValue] {
        var values: [SQLiteValue] = []
        if !omitReservationID {
            values.append(.text(uuidText(binding.decisionID)))
            values.append(.text(uuidText(reservationID)))
        }
        values.append(contentsOf: [
            .text(uuidText(binding.workloadID)),
            .text(uuidText(binding.nodeID)),
            .text(SchedulerAdmissionCanonicalJSON.vectorJSON(binding.resources)),
            .text(binding.nodeCapacityDigest),
            .int64(binding.nodeCapacityGeneration),
            .text(binding.inputDigest),
            .text(binding.configDigest),
            .text(binding.profileDigest),
            .text(binding.lifecyclePlanDigest),
            .text(binding.ownerSubjectID),
            .text(binding.projectUUID),
            .text(SchedulerAdmissionStatus.pending.rawValue),
            .text(binding.createdAt),
            .text(binding.createdAt),
            .text(binding.expiresAt),
            .int64(fencingToken.nodeEpoch),
            .int64(fencingToken.reservationSequence),
        ])
        return values
    }

    private func updateStatus(
        reservationID: UUID,
        status: SchedulerAdmissionStatus,
        updatedAt: String,
        on connection: SQLiteConnection
    ) throws {
        try connection.run(
            """
            UPDATE scheduler_reservations
            SET status = ?, updated_at = ?
            WHERE reservation_id = ?
            """,
            bindings: [
                .text(status.rawValue),
                .text(updatedAt),
                .text(uuidText(reservationID)),
            ]
        )
    }

    private func updateFenceEvidence(
        reservationID: UUID,
        status: SchedulerAdmissionStatus,
        evidence: SchedulerFenceEvidence,
        updatedAt: String,
        on connection: SQLiteConnection
    ) throws {
        let values: [SQLiteValue] = [
            .text(status.rawValue),
            .text(updatedAt),
            .text(evidence.evidenceDigest),
            .text(evidence.verifiedAt),
            .int64(evidence.token.nodeEpoch),
            .int64(evidence.token.reservationSequence),
            .text(uuidText(evidence.reservationID)),
            .text(uuidText(evidence.workloadID)),
            .text(uuidText(reservationID)),
        ]
        try connection.run(
            """
            UPDATE scheduler_reservations
            SET status = ?, updated_at = ?, fence_evidence_digest = ?,
                fence_evidence_at = ?, fence_evidence_node_epoch = ?,
                fence_evidence_reservation_sequence = ?,
                fence_evidence_reservation_id = ?, fence_evidence_workload_uuid = ?
            WHERE reservation_id = ?
            """,
            bindings: values
        )
    }

    private func updateReleaseEvidence(
        reservationID: UUID,
        evidence: SchedulerReleaseEvidence,
        updatedAt: String,
        on connection: SQLiteConnection
    ) throws {
        let fields: [SQLiteValue]
        switch evidence {
        case .verifiedRuntimeAbsence(let digest, let verifiedAt):
            fields = [
                .text("runtime-absence"),
                .text(digest),
                .text(verifiedAt),
                .null, .null, .null, .null,
            ]
        case .authoritativeFence(
            let token,
            let evidenceReservationID,
            let evidenceWorkloadID,
            let digest,
            let verifiedAt
        ):
            fields = [
                .text("authoritative-fence"),
                .text(digest),
                .text(verifiedAt),
                .int64(token.nodeEpoch),
                .int64(token.reservationSequence),
                .text(uuidText(evidenceReservationID)),
                .text(uuidText(evidenceWorkloadID)),
            ]
        }
        let values: [SQLiteValue] = [
            .text(SchedulerAdmissionStatus.released.rawValue),
            .text(updatedAt),
        ] + fields + [.text(uuidText(reservationID))]
        try connection.run(
            """
            UPDATE scheduler_reservations
            SET status = ?, updated_at = ?, release_evidence_kind = ?,
                release_evidence_digest = ?, release_evidence_at = ?,
                release_evidence_node_epoch = ?,
                release_evidence_reservation_sequence = ?,
                release_evidence_reservation_id = ?,
                release_evidence_workload_uuid = ?
            WHERE reservation_id = ?
            """,
            bindings: values
        )
    }

    private func activeReservation(
        workloadID: UUID,
        on connection: SQLiteConnection
    ) throws -> UUID? {
        let row = try connection.query(
            """
            SELECT decision_id
            FROM scheduler_reservations
            WHERE workload_uuid = ?
              AND status IN ('pending', 'committed', 'release-pending', 'fenced')
            ORDER BY decision_id ASC
            LIMIT 1
            """,
            bindings: [.text(uuidText(workloadID))]
        ).first
        guard let value = row?.first ?? nil else { return nil }
        guard let id = UUID(uuidString: value) else {
            throw SchedulerAdmissionError.stateInvariant("active-workload-decision-id")
        }
        return id
    }

    private func activeCapacity(
        _ nodeID: UUID,
        on connection: SQLiteConnection
    ) throws -> ResourceVector {
        let rows = try connection.query(
            """
            SELECT resource_vector_json
            FROM scheduler_reservations
            WHERE node_uuid = ?
              AND status IN ('pending', 'committed', 'release-pending', 'fenced')
            ORDER BY reservation_id ASC
            """,
            bindings: [.text(uuidText(nodeID))]
        )
        var total = ResourceVector.zero
        for row in rows {
            guard let vectorJSON = row.first ?? nil else {
                throw SchedulerAdmissionError.stateInvariant("active-capacity-row-shape")
            }
            let vector = try SchedulerAdmissionCanonicalJSON.vector(from: vectorJSON)
            do {
                total = try total.adding(vector)
            } catch let error as SchedulerValidationError {
                throw SchedulerAdmissionError.resourceArithmetic(
                    resource: error.stableKey
                )
            }
        }
        return total
    }

    private func clampedRemaining(
        capacity: ResourceVector,
        allocation: ResourceVector
    ) throws -> ResourceVector {
        let names = Set(capacity.resourceNames).union(allocation.resourceNames).sorted()
        var values: [String: Int64] = [:]
        for resource in names {
            let remaining = capacity[resource] - min(capacity[resource], allocation[resource])
            if remaining > 0 {
                values[resource] = remaining
            }
        }
        do {
            return try ResourceVector(values)
        } catch let error as SchedulerValidationError {
            throw SchedulerAdmissionError.resourceArithmetic(resource: error.stableKey)
        }
    }

    private func requiredReservation(
        _ reservationID: UUID,
        on connection: SQLiteConnection
    ) throws -> SchedulerReservationRecord {
        guard let record = try loadReservation(reservationID, on: connection) else {
            throw SchedulerAdmissionError.stateInvariant("reservation-disappeared")
        }
        guard let artifact = try loadDecisionArtifact(record.decisionID, on: connection) else {
            throw SchedulerAdmissionError.stateInvariant(
                "decision-artifact-missing"
            )
        }
        try validateArtifactReservationPair(artifact, record)
        return record
    }

    private func loadReservation(
        decisionID: UUID,
        workloadID: UUID? = nil,
        on connection: SQLiteConnection
    ) throws -> SchedulerReservationRecord? {
        let rows: [[String?]]
        if let workloadID {
            rows = try connection.query(
                """
                SELECT decision_id, reservation_id, workload_uuid, node_uuid,
                       resource_vector_json, capacity_digest, capacity_generation,
                       input_digest, config_digest, profile_digest, lifecycle_plan_digest,
                       owner_subject_id, project_uuid, status, created_at, updated_at,
                       expires_at, fencing_node_epoch, fencing_reservation_sequence,
                       fence_evidence_digest, fence_evidence_at,
                       fence_evidence_node_epoch, fence_evidence_reservation_sequence,
                       fence_evidence_reservation_id, fence_evidence_workload_uuid,
                       release_evidence_kind, release_evidence_digest, release_evidence_at,
                       release_evidence_node_epoch, release_evidence_reservation_sequence,
                       release_evidence_reservation_id, release_evidence_workload_uuid
                FROM scheduler_reservations
                WHERE decision_id = ? AND workload_uuid = ?
                ORDER BY reservation_id ASC
                LIMIT 1
                """,
                bindings: [.text(uuidText(decisionID)), .text(uuidText(workloadID))]
            )
        } else {
            rows = try connection.query(
                """
                SELECT decision_id, reservation_id, workload_uuid, node_uuid,
                       resource_vector_json, capacity_digest, capacity_generation,
                       input_digest, config_digest, profile_digest, lifecycle_plan_digest,
                       owner_subject_id, project_uuid, status, created_at, updated_at,
                       expires_at, fencing_node_epoch, fencing_reservation_sequence,
                       fence_evidence_digest, fence_evidence_at,
                       fence_evidence_node_epoch, fence_evidence_reservation_sequence,
                       fence_evidence_reservation_id, fence_evidence_workload_uuid,
                       release_evidence_kind, release_evidence_digest, release_evidence_at,
                       release_evidence_node_epoch, release_evidence_reservation_sequence,
                       release_evidence_reservation_id, release_evidence_workload_uuid
                FROM scheduler_reservations
                WHERE decision_id = ?
                ORDER BY reservation_id ASC
                LIMIT 1
                """,
                bindings: [.text(uuidText(decisionID))]
            )
        }
        guard let row = rows.first else { return nil }
        return try hydrateReservation(
            try decodeReservation(row),
            on: connection
        )
    }

    private func loadReservations(
        _ decisionID: UUID,
        on connection: SQLiteConnection
    ) throws -> [SchedulerReservationRecord] {
        let rows = try boundedQuery(
            """
            SELECT decision_id, reservation_id, workload_uuid, node_uuid,
                   resource_vector_json, capacity_digest, capacity_generation,
                   input_digest, config_digest, profile_digest, lifecycle_plan_digest,
                   owner_subject_id, project_uuid, status, created_at, updated_at,
                   expires_at, fencing_node_epoch, fencing_reservation_sequence,
                   fence_evidence_digest, fence_evidence_at,
                   fence_evidence_node_epoch, fence_evidence_reservation_sequence,
                   fence_evidence_reservation_id, fence_evidence_workload_uuid,
                   release_evidence_kind, release_evidence_digest, release_evidence_at,
                   release_evidence_node_epoch, release_evidence_reservation_sequence,
                   release_evidence_reservation_id, release_evidence_workload_uuid
            FROM scheduler_reservations
            WHERE decision_id = ?
            ORDER BY workload_uuid ASC, reservation_id ASC
            LIMIT ?
            """,
            bindings: [
                .text(uuidText(decisionID)),
                .int(SchedulerAdmissionStateLimits.maximumDecisionWorkloadCount + 1),
            ],
            limit: SchedulerAdmissionStateLimits.maximumDecisionWorkloadCount,
            field: "decision-reservations",
            on: connection
        )
        return try rows.map(decodeReservation)
    }

    private func validateArtifactBinding(
        _ artifact: SchedulerDecisionArtifactRecord,
        binding: SchedulerAdmissionBinding,
        allowPreemptionOutcome: Bool = false
    ) throws {
        guard artifact.decisionID == binding.decisionID,
              artifact.projectUUID == binding.projectUUID else {
            throw SchedulerAdmissionError.staleInput(field: "decision-project-uuid")
        }
        guard artifact.inputDigest == binding.inputDigest else {
            throw SchedulerAdmissionError.staleInput(field: "input-digest")
        }
        guard artifact.configDigest == binding.configDigest else {
            throw SchedulerAdmissionError.staleInput(field: "config-digest")
        }
        guard artifact.profileDigest == binding.profileDigest else {
            throw SchedulerAdmissionError.staleInput(field: "profile-digest")
        }
        guard artifact.lifecyclePlanDigest == binding.lifecyclePlanDigest else {
            throw SchedulerAdmissionError.staleInput(field: "lifecycle-plan-digest")
        }
        guard let storedBinding = artifact.binding(for: binding.workloadID),
              storedBinding.nodeID == binding.nodeID,
              storedBinding.resources == binding.resources,
              storedBinding.capacityDigest == binding.nodeCapacityDigest,
              storedBinding.capacityGeneration == binding.nodeCapacityGeneration,
              storedBinding.ownerSubjectID == binding.ownerSubjectID,
              storedBinding.projectUUID == binding.projectUUID else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "decision-workload-binding"
            )
        }
        guard let workloadDecision = artifact.decision.workloadDecisions.first(
            where: { $0.workloadID == binding.workloadID }
        ) else {
            throw SchedulerAdmissionError.invalidBinding(field: "decision-workload")
        }
        let isPlacement = (workloadDecision.outcome == .placed
                || workloadDecision.outcome == .retainedExistingPlacement)
            && workloadDecision.chosenNodeID == binding.nodeID
        let isFencedPreemption = allowPreemptionOutcome
            && workloadDecision.outcome == .preemptionProposed
            && workloadDecision.preemption?.targetWorkloadID == binding.workloadID
            && workloadDecision.preemption?.projectID == artifact.projectUUID
            && workloadDecision.preemption?.nodeID == binding.nodeID
        guard isPlacement || isFencedPreemption else {
            throw SchedulerAdmissionError.invalidBinding(field: "decision-placement")
        }
    }

    private func validateArtifactReservationPair(
        _ artifact: SchedulerDecisionArtifactRecord,
        _ reservation: SchedulerReservationRecord
    ) throws {
        guard artifact.decisionID == reservation.decisionID,
              artifact.projectUUID == reservation.projectUUID,
              artifact.inputDigest == reservation.inputDigest,
              artifact.configDigest == reservation.configDigest,
              artifact.profileDigest == reservation.profileDigest,
              artifact.lifecyclePlanDigest == reservation.lifecyclePlanDigest,
              artifact.workloadIDs.contains(reservation.workloadID),
              let storedBinding = artifact.binding(for: reservation.workloadID),
              storedBinding.nodeID == reservation.nodeID,
              storedBinding.resources == reservation.resources,
              storedBinding.capacityDigest == reservation.capacityDigest,
              storedBinding.capacityGeneration == reservation.capacityGeneration,
              storedBinding.ownerSubjectID == reservation.ownerSubjectID,
              storedBinding.projectUUID == reservation.projectUUID,
              let workloadDecision = artifact.decision.workloadDecisions.first(
                  where: { $0.workloadID == reservation.workloadID }
              ),
              ((workloadDecision.outcome == .placed
                || workloadDecision.outcome == .retainedExistingPlacement)
                && workloadDecision.chosenNodeID == reservation.nodeID
                || (workloadDecision.outcome == .preemptionProposed
                    && workloadDecision.preemption?.targetWorkloadID
                        == reservation.workloadID
                    && workloadDecision.preemption?.projectID
                        == artifact.projectUUID
                    && workloadDecision.preemption?.nodeID
                        == reservation.nodeID)) else {
            throw SchedulerAdmissionError.stateInvariant(
                "decision-reservation-binding-mismatch"
            )
        }
        try validateLeaseWindow(
            createdAt: reservation.createdAt,
            expiresAt: reservation.expiresAt,
            field: "reservation-lease"
        )
    }

    private func decisionProjection(
        for reservation: SchedulerReservationRecord
    ) -> SchedulerDecisionRecord {
        SchedulerDecisionRecord(
            decisionID: reservation.decisionID,
            reservationID: reservation.reservationID,
            workloadID: reservation.workloadID,
            nodeID: reservation.nodeID,
            resources: reservation.resources,
            capacityDigest: reservation.capacityDigest,
            capacityGeneration: reservation.capacityGeneration,
            inputDigest: reservation.inputDigest,
            configDigest: reservation.configDigest,
            profileDigest: reservation.profileDigest,
            lifecyclePlanDigest: reservation.lifecyclePlanDigest,
            ownerSubjectID: reservation.ownerSubjectID,
            projectUUID: reservation.projectUUID,
            status: reservation.status,
            createdAt: reservation.createdAt,
            updatedAt: reservation.updatedAt,
            expiresAt: reservation.expiresAt,
            fencingToken: reservation.fencingToken,
            fenceEvidence: reservation.fenceEvidence,
            releaseEvidence: reservation.releaseEvidence
        )
    }

    private func loadDecisionArtifact(
        _ decisionID: UUID,
        on connection: SQLiteConnection
    ) throws -> SchedulerDecisionArtifactRecord? {
        let rows = try connection.query(
            """
            SELECT decision_id, project_uuid, input_digest, config_digest,
                   profile_digest, lifecycle_plan_digest, decision_json,
                   workload_ids_json, workload_bindings_json, created_at,
                   updated_at, artifact_digest
            FROM scheduler_decisions
            WHERE decision_id = ?
            LIMIT 1
            """,
            bindings: [.text(uuidText(decisionID))]
        )
        guard let row = rows.first else { return nil }
        return try decodeDecisionArtifact(row)
    }

    private func decodeDecisionArtifact(
        _ row: [String?]
    ) throws -> SchedulerDecisionArtifactRecord {
        guard row.count == 12,
              let decisionText = row[0],
              let storedDecisionID = UUID(uuidString: decisionText),
              let projectUUID = row[1],
              let inputDigest = row[2],
              let configDigest = row[3],
              let profileDigest = row[4],
              let lifecyclePlanDigest = row[5],
              let decisionJSON = row[6],
              let workloadIDsJSON = row[7],
              let workloadBindingsJSON = row[8],
              let createdAt = row[9],
              let updatedAt = row[10],
              let artifactDigest = row[11] else {
            throw SchedulerAdmissionError.stateInvariant("decision-artifact-row-shape")
        }
        let decision = try decodeCanonical(
            SchedulerDecision.self,
            json: decisionJSON,
            field: "decision"
        )
        let workloadIDs = try decodeCanonical(
            [UUID].self,
            json: workloadIDsJSON,
            field: "decision-workloads"
        )
        let workloadBindings = try decodeCanonical(
            [SchedulerDecisionWorkloadBinding].self,
            json: workloadBindingsJSON,
            field: "decision-workload-bindings"
        )
        guard storedDecisionID == decision.decisionID,
              inputDigest == decision.inputDigest,
              workloadIDs == decision.orderedWorkloadIDs else {
            throw SchedulerAdmissionError.stateInvariant("decision-artifact-binding")
        }
        let record = try SchedulerDecisionArtifactRecord(
            decision: decision,
            workloadBindings: workloadBindings,
            projectUUID: projectUUID,
            configDigest: configDigest,
            profileDigest: profileDigest,
            lifecyclePlanDigest: lifecyclePlanDigest,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        guard record.artifactDigest == artifactDigest else {
            throw SchedulerAdmissionError.stateInvariant("decision-artifact-digest")
        }
        return record
    }

    private func loadUniqueReservationForRecovery(
        workloadID: UUID,
        projectUUID: String,
        on connection: SQLiteConnection
    ) throws -> SchedulerReservationRecord? {
        let rows = try connection.query(
            """
            SELECT decision_id, reservation_id, workload_uuid, node_uuid,
                   resource_vector_json, capacity_digest, capacity_generation,
                   input_digest, config_digest, profile_digest, lifecycle_plan_digest,
                   owner_subject_id, project_uuid, status, created_at, updated_at,
                   expires_at, fencing_node_epoch, fencing_reservation_sequence,
                   fence_evidence_digest, fence_evidence_at,
                   fence_evidence_node_epoch, fence_evidence_reservation_sequence,
                   fence_evidence_reservation_id, fence_evidence_workload_uuid,
                   release_evidence_kind, release_evidence_digest, release_evidence_at,
                   release_evidence_node_epoch, release_evidence_reservation_sequence,
                   release_evidence_reservation_id, release_evidence_workload_uuid
            FROM scheduler_reservations
            WHERE workload_uuid = ? AND project_uuid = ?
            ORDER BY decision_id ASC, reservation_id ASC
            LIMIT 2
            """,
            bindings: [
                .text(uuidText(workloadID)),
                .text(projectUUID.lowercased()),
            ]
        )
        guard rows.count <= 1 else {
            throw SchedulerAdmissionError.stateInvariant(
                "preemption-recovery-reservation-ambiguous"
            )
        }
        guard let row = rows.first else { return nil }
        return try hydrateReservation(
            try decodeReservation(row),
            on: connection
        )
    }

    private func loadReservation(
        _ reservationID: UUID,
        on connection: SQLiteConnection
    ) throws -> SchedulerReservationRecord? {
        let rows = try connection.query(
            """
            SELECT decision_id, reservation_id, workload_uuid, node_uuid,
                   resource_vector_json, capacity_digest, capacity_generation,
                   input_digest, config_digest, profile_digest, lifecycle_plan_digest,
                   owner_subject_id, project_uuid, status, created_at, updated_at,
                   expires_at, fencing_node_epoch, fencing_reservation_sequence,
                   fence_evidence_digest, fence_evidence_at,
                   fence_evidence_node_epoch, fence_evidence_reservation_sequence,
                   fence_evidence_reservation_id, fence_evidence_workload_uuid,
                   release_evidence_kind, release_evidence_digest, release_evidence_at,
                   release_evidence_node_epoch, release_evidence_reservation_sequence,
                   release_evidence_reservation_id, release_evidence_workload_uuid
            FROM scheduler_reservations
            WHERE reservation_id = ?
            LIMIT 1
            """,
            bindings: [.text(uuidText(reservationID))]
        )
        guard let row = rows.first else { return nil }
        return try hydrateReservation(
            try decodeReservation(row),
            on: connection
        )
    }

    private func decodeReservation(_ row: [String?]) throws -> SchedulerReservationRecord {
        let decoded = try decodeStored(row)
        return SchedulerReservationRecord(
            reservationID: decoded.reservationID,
            decisionID: decoded.decisionID,
            workloadID: decoded.workloadID,
            nodeID: decoded.nodeID,
            resources: decoded.resources,
            capacityDigest: decoded.nodeCapacityDigest,
            capacityGeneration: decoded.nodeCapacityGeneration,
            inputDigest: decoded.inputDigest,
            configDigest: decoded.configDigest,
            profileDigest: decoded.profileDigest,
            lifecyclePlanDigest: decoded.lifecyclePlanDigest,
            ownerSubjectID: decoded.ownerSubjectID,
            projectUUID: decoded.projectUUID,
            status: decoded.status,
            createdAt: decoded.createdAt,
            updatedAt: decoded.updatedAt,
            expiresAt: decoded.expiresAt,
            fencingToken: decoded.fencingToken,
            fenceEvidence: decoded.fenceEvidence,
            releaseEvidence: decoded.releaseEvidence
        )
    }

    private func hydrateReservation(
        _ reservation: SchedulerReservationRecord,
        on connection: SQLiteConnection
    ) throws -> SchedulerReservationRecord {
        guard let artifact = try loadDecisionArtifact(
            reservation.decisionID,
            on: connection
        ), let binding = artifact.binding(for: reservation.workloadID) else {
            throw SchedulerAdmissionError.stateInvariant(
                "reservation-runtime-ownership-artifact-missing"
            )
        }
        return reservation.hydrated(with: binding.runtimeOwnership)
    }

    private struct DecodedStoredRecord {
        let decisionID: UUID
        let reservationID: UUID
        let workloadID: UUID
        let nodeID: UUID
        let resources: ResourceVector
        let nodeCapacityDigest: String
        let nodeCapacityGeneration: Int64
        let inputDigest: String
        let configDigest: String
        let profileDigest: String
        let lifecyclePlanDigest: String
        let ownerSubjectID: String
        let projectUUID: String
        let status: SchedulerAdmissionStatus
        let createdAt: String
        let updatedAt: String
        let expiresAt: String
        let fencingToken: SchedulerFencingToken
        let fenceEvidence: SchedulerFenceEvidence?
        let releaseEvidence: SchedulerReleaseEvidence?
    }

    private func decodeStored(_ row: [String?]) throws -> DecodedStoredRecord {
        guard row.count == 32,
              let decisionText = row[0], let decisionID = UUID(uuidString: decisionText),
              let reservationText = row[1], let reservationID = UUID(uuidString: reservationText),
              let workloadText = row[2], let workloadID = UUID(uuidString: workloadText),
              let nodeText = row[3], let nodeID = UUID(uuidString: nodeText),
              let vectorJSON = row[4],
              let nodeCapacityDigest = row[5],
              let generationText = row[6], let nodeCapacityGeneration = Int64(generationText),
              let inputDigest = row[7], let configDigest = row[8],
              let profileDigest = row[9], let lifecyclePlanDigest = row[10],
              let ownerSubjectID = row[11], let projectUUID = row[12],
              let statusText = row[13], let status = SchedulerAdmissionStatus(rawValue: statusText),
              let createdAt = row[14], let updatedAt = row[15], let expiresAt = row[16],
              let nodeEpochText = row[17], let nodeEpoch = Int64(nodeEpochText),
              let sequenceText = row[18], let reservationSequence = Int64(sequenceText),
              let resources = try? SchedulerAdmissionCanonicalJSON.vector(from: vectorJSON) else {
            throw SchedulerAdmissionError.stateInvariant("scheduler-record-shape")
        }
        let fencingToken: SchedulerFencingToken
        do {
            fencingToken = try SchedulerFencingToken(
                nodeEpoch: nodeEpoch,
                reservationSequence: reservationSequence
            )
        } catch {
            throw SchedulerAdmissionError.stateInvariant("scheduler-fencing-token")
        }

        try SchedulerAdmissionValidation.digest(nodeCapacityDigest, field: "node-capacity-digest")
        try SchedulerAdmissionValidation.digest(inputDigest, field: "input-digest")
        try SchedulerAdmissionValidation.digest(configDigest, field: "config-digest")
        try SchedulerAdmissionValidation.digest(profileDigest, field: "profile-digest")
        try SchedulerAdmissionValidation.digest(
            lifecyclePlanDigest,
            field: "lifecycle-plan-digest"
        )
        try SchedulerAdmissionValidation.subject(ownerSubjectID)
        guard HostwrightResourceUUID.isValid(projectUUID) else {
            throw SchedulerAdmissionError.stateInvariant("scheduler-project-uuid")
        }
        try SchedulerAdmissionValidation.timestamp(createdAt, field: "created-at")
        try SchedulerAdmissionValidation.timestamp(updatedAt, field: "updated-at")
        try SchedulerAdmissionValidation.timestamp(expiresAt, field: "expires-at")
        guard timestamp(updatedAt) >= timestamp(createdAt),
              timestamp(expiresAt) > timestamp(createdAt),
              nodeCapacityGeneration >= 1 else {
            throw SchedulerAdmissionError.stateInvariant("scheduler-record-timestamp-order")
        }
        do {
            _ = try SchedulerAdmissionBinding(
                decisionID: decisionID,
                workloadID: workloadID,
                nodeID: nodeID,
                resources: resources,
                nodeCapacityDigest: nodeCapacityDigest,
                nodeCapacityGeneration: nodeCapacityGeneration,
                inputDigest: inputDigest,
                configDigest: configDigest,
                profileDigest: profileDigest,
                lifecyclePlanDigest: lifecyclePlanDigest,
                ownerSubjectID: ownerSubjectID,
                projectUUID: projectUUID,
                createdAt: createdAt,
                expiresAt: expiresAt
            )
        } catch {
            throw SchedulerAdmissionError.stateInvariant("scheduler-record-binding")
        }

        let fenceEvidence = try decodeFenceEvidence(row)
        let releaseEvidence = try decodeReleaseEvidence(row)
        let createdDate = timestamp(createdAt)
        let updatedDate = timestamp(updatedAt)
        switch status {
        case .pending, .committed, .releasePending:
            guard fenceEvidence == nil, releaseEvidence == nil else {
                throw SchedulerAdmissionError.stateInvariant("unreleased-record-with-proof")
            }
        case .fenced:
            guard let fenceEvidence, releaseEvidence == nil else {
                throw SchedulerAdmissionError.stateInvariant("fenced-record-proof-shape")
            }
            try validateStoredFenceEvidence(
                fenceEvidence,
                reservationID: reservationID,
                workloadID: workloadID,
                fencingToken: fencingToken,
                currentDate: updatedDate,
                createdDate: createdDate
            )
        case .released:
            guard let releaseEvidence else {
                throw SchedulerAdmissionError.stateInvariant("released-without-proof")
            }
            let releaseDate = timestamp(evidenceTimestamp(releaseEvidence))
            guard releaseDate >= createdDate, releaseDate == updatedDate else {
                throw SchedulerAdmissionError.stateInvariant("release-proof-order")
            }
            if let fenceEvidence {
                try validateStoredFenceEvidence(
                    fenceEvidence,
                    reservationID: reservationID,
                    workloadID: workloadID,
                    fencingToken: fencingToken,
                    currentDate: nil,
                    createdDate: createdDate
                )
                guard timestamp(fenceEvidence.verifiedAt) <= releaseDate else {
                    throw SchedulerAdmissionError.stateInvariant("fence-proof-order")
                }
            }
            if case .authoritativeFence(let token, let evidenceReservationID, let evidenceWorkloadID, _, _) = releaseEvidence {
                guard evidenceReservationID == reservationID,
                      evidenceWorkloadID == workloadID,
                      token.reservationSequence == fencingToken.reservationSequence,
                      token.nodeEpoch > fencingToken.nodeEpoch else {
                    throw SchedulerAdmissionError.stateInvariant("release-lineage")
                }
                if let fenceEvidence {
                    guard fenceEvidence.token.reservationSequence
                        == token.reservationSequence,
                          fenceEvidence.reservationID == reservationID,
                          fenceEvidence.workloadID == workloadID,
                          token.nodeEpoch >= fenceEvidence.token.nodeEpoch else {
                        throw SchedulerAdmissionError.stateInvariant("fence-release-token-mismatch")
                    }
                }
            }
        }
        return DecodedStoredRecord(
            decisionID: decisionID,
            reservationID: reservationID,
            workloadID: workloadID,
            nodeID: nodeID,
            resources: resources,
            nodeCapacityDigest: nodeCapacityDigest,
            nodeCapacityGeneration: nodeCapacityGeneration,
            inputDigest: inputDigest,
            configDigest: configDigest,
            profileDigest: profileDigest,
            lifecyclePlanDigest: lifecyclePlanDigest,
            ownerSubjectID: ownerSubjectID,
            projectUUID: projectUUID.lowercased(),
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            expiresAt: expiresAt,
            fencingToken: fencingToken,
            fenceEvidence: fenceEvidence,
            releaseEvidence: releaseEvidence
        )
    }

    private func validateStoredFenceEvidence(
        _ evidence: SchedulerFenceEvidence,
        reservationID: UUID,
        workloadID: UUID,
        fencingToken: SchedulerFencingToken,
        currentDate: Date?,
        createdDate: Date
    ) throws {
        guard evidence.reservationID == reservationID,
              evidence.workloadID == workloadID,
              evidence.token.reservationSequence == fencingToken.reservationSequence,
              evidence.token.nodeEpoch > fencingToken.nodeEpoch,
              timestamp(evidence.verifiedAt) >= createdDate else {
            throw SchedulerAdmissionError.stateInvariant("fence-proof-order")
        }
        if let currentDate {
            guard timestamp(evidence.verifiedAt) == currentDate else {
                throw SchedulerAdmissionError.stateInvariant("fence-proof-order")
            }
        }
    }

    private func decodeFenceEvidence(
        _ row: [String?]
    ) throws -> SchedulerFenceEvidence? {
        let fields = (19...24).map { row[$0] }
        guard fields.contains(where: { $0 != nil }) else { return nil }
        guard let digest = row[19],
              let verifiedAt = row[20],
              let epochText = row[21], let nodeEpoch = Int64(epochText),
              let sequenceText = row[22], let reservationSequence = Int64(sequenceText),
              let reservationText = row[23], let reservationID = UUID(uuidString: reservationText),
              let workloadText = row[24], let workloadID = UUID(uuidString: workloadText) else {
            throw SchedulerAdmissionError.stateInvariant("fence-evidence-shape")
        }
        let token: SchedulerFencingToken
        do {
            token = try SchedulerFencingToken(
                nodeEpoch: nodeEpoch,
                reservationSequence: reservationSequence
            )
        } catch {
            throw SchedulerAdmissionError.stateInvariant("fence-evidence-token")
        }
        try validateEvidenceDigestAndTimestamp(
            digest: digest,
            verifiedAt: verifiedAt,
            digestField: "fence-evidence-digest",
            timestampField: "fence-evidence-at"
        )
        return try SchedulerFenceEvidence(
            token: token,
            reservationID: reservationID,
            workloadID: workloadID,
            evidenceDigest: digest,
            verifiedAt: verifiedAt
        )
    }

    private func decodeReleaseEvidence(
        _ row: [String?]
    ) throws -> SchedulerReleaseEvidence? {
        let fields = (25...31).map { row[$0] }
        guard fields.contains(where: { $0 != nil }) else { return nil }
        guard let kind = row[25], let digest = row[26], let verifiedAt = row[27] else {
            throw SchedulerAdmissionError.stateInvariant("release-evidence-shape")
        }
        try validateEvidenceDigestAndTimestamp(
            digest: digest,
            verifiedAt: verifiedAt,
            digestField: "release-evidence-digest",
            timestampField: "release-evidence-at"
        )
        switch kind {
        case "runtime-absence":
            guard (28...31).allSatisfy({ row[$0] == nil }) else {
                throw SchedulerAdmissionError.stateInvariant("runtime-release-fence-token")
            }
            return .verifiedRuntimeAbsence(
                evidenceDigest: digest,
                verifiedAt: verifiedAt
            )
        case "authoritative-fence":
            guard let epochText = row[28], let nodeEpoch = Int64(epochText),
                  let sequenceText = row[29], let reservationSequence = Int64(sequenceText),
                  let reservationText = row[30], let reservationID = UUID(uuidString: reservationText),
                  let workloadText = row[31], let workloadID = UUID(uuidString: workloadText) else {
                throw SchedulerAdmissionError.stateInvariant(
                    "authoritative-release-fence-token"
                )
            }
            let token: SchedulerFencingToken
            do {
                token = try SchedulerFencingToken(
                    nodeEpoch: nodeEpoch,
                    reservationSequence: reservationSequence
                )
            } catch {
                throw SchedulerAdmissionError.stateInvariant(
                    "authoritative-release-fence-token"
                )
            }
            return .authoritativeFence(
                token: token,
                reservationID: reservationID,
                workloadID: workloadID,
                evidenceDigest: digest,
                verifiedAt: verifiedAt
            )
        default:
            throw SchedulerAdmissionError.stateInvariant("release-evidence-kind")
        }
    }

    private func validateEvidenceDigestAndTimestamp(
        digest: String,
        verifiedAt: String,
        digestField: String,
        timestampField: String
    ) throws {
        try SchedulerAdmissionValidation.evidenceDigest(digest, field: digestField)
        try SchedulerAdmissionValidation.timestamp(verifiedAt, field: timestampField)
    }

    private func validateFenceEvidence(_ evidence: SchedulerFenceEvidence) throws {
        try SchedulerAdmissionValidation.fencingToken(evidence.token, field: "fencing-token")
        try validateEvidenceDigestAndTimestamp(
            digest: evidence.evidenceDigest,
            verifiedAt: evidence.verifiedAt,
            digestField: "fence-evidence-digest",
            timestampField: "fence-evidence-at"
        )
    }

    private func validateReleaseEvidence(_ evidence: SchedulerReleaseEvidence) throws {
        switch evidence {
        case .verifiedRuntimeAbsence(let digest, let verifiedAt):
            try validateEvidenceDigestAndTimestamp(
                digest: digest,
                verifiedAt: verifiedAt,
                digestField: "release-evidence-digest",
                timestampField: "release-evidence-at"
            )
        case .authoritativeFence(
            let token,
            _,
            _,
            let digest,
            let verifiedAt
        ):
            try SchedulerAdmissionValidation.fencingToken(token, field: "fencing-token")
            try validateEvidenceDigestAndTimestamp(
                digest: digest,
                verifiedAt: verifiedAt,
                digestField: "release-evidence-digest",
                timestampField: "release-evidence-at"
            )
        }
    }

    private func requireEvidenceNotBefore(
        _ verifiedAt: String,
        updatedAt: String,
        field: String
    ) throws {
        guard timestamp(verifiedAt) >= timestamp(updatedAt) else {
            throw SchedulerAdmissionError.invalidEvidence(field)
        }
    }

    private func requireUpdatedAtNotBefore(
        _ updatedAt: String,
        current: String
    ) throws {
        guard timestamp(updatedAt) >= timestamp(current) else {
            throw SchedulerAdmissionError.invalidBinding(field: "updated-at-order")
        }
    }

    private func evidenceTimestamp(_ evidence: SchedulerReleaseEvidence) -> String {
        switch evidence {
        case .verifiedRuntimeAbsence(_, let verifiedAt):
            return verifiedAt
        case .authoritativeFence(_, _, _, _, let verifiedAt):
            return verifiedAt
        }
    }

    private func binding(
        for record: SchedulerDecisionRecord
    ) throws -> SchedulerAdmissionBinding {
        try SchedulerAdmissionBinding(
            decisionID: record.decisionID,
            workloadID: record.workloadID,
            nodeID: record.nodeID,
            resources: record.resources,
            nodeCapacityDigest: record.capacityDigest,
            nodeCapacityGeneration: record.capacityGeneration,
            inputDigest: record.inputDigest,
            configDigest: record.configDigest,
            profileDigest: record.profileDigest,
            lifecyclePlanDigest: record.lifecyclePlanDigest,
            ownerSubjectID: record.ownerSubjectID,
            projectUUID: record.projectUUID,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt
        )
    }

    private func binding(
        for record: SchedulerReservationRecord
    ) throws -> SchedulerAdmissionBinding {
        try SchedulerAdmissionBinding(
            decisionID: record.decisionID,
            workloadID: record.workloadID,
            nodeID: record.nodeID,
            resources: record.resources,
            nodeCapacityDigest: record.capacityDigest,
            nodeCapacityGeneration: record.capacityGeneration,
            inputDigest: record.inputDigest,
            configDigest: record.configDigest,
            profileDigest: record.profileDigest,
            lifecyclePlanDigest: record.lifecyclePlanDigest,
            ownerSubjectID: record.ownerSubjectID,
            projectUUID: record.projectUUID,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt
        )
    }

    private func reservationID(
        for decisionID: UUID,
        workloadID: UUID
    ) throws -> UUID {
        guard let id = UUID(
            uuidString: HostwrightResourceUUID.legacy(
                kind: "scheduler-reservation",
                identifier: "\(uuidText(decisionID)):\(uuidText(workloadID))"
            )
        ) else {
            throw SchedulerAdmissionError.stateInvariant("reservation-id-generation")
        }
        return id
    }

    private func timestamp(_ value: String) -> Date {
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        return .distantPast
    }

    private func uuidText(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }
}
