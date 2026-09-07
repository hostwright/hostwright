import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightScheduler
import HostwrightState

final class LifecycleSchedulerSession: @unchecked Sendable {
    private let context: LifecycleSchedulerContext
    private let store: SQLiteStateStore
    private let plan: LifecyclePlan
    private let snapshot: LifecycleSchedulerHostSnapshot
    private let reservations: [SchedulerReservationRecord]
    private let lock = NSLock()

    private init(
        context: LifecycleSchedulerContext, store: SQLiteStateStore, plan: LifecyclePlan,
        snapshot: LifecycleSchedulerHostSnapshot, reservations: [SchedulerReservationRecord]
    ) {
        self.context = context
        self.store = store
        self.plan = plan
        self.snapshot = snapshot
        self.reservations = reservations
    }

    static func admit(
        context: LifecycleSchedulerContext,
        store: SQLiteStateStore,
        manifest: HostwrightManifest,
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation,
        options: LifecycleCLIOptions,
        providerVersion: String
    ) throws -> LifecycleSchedulerSession {
        let snapshot = try context.refresh()
        let repository = store.schedulerAdmissions
        let entries = try LifecycleSchedulerWorkloads.prepare(
            manifest: manifest, compiled: compiled, preparation: preparation,
            options: options, subjectID: context.subjectID, providerVersion: providerVersion
        )
        try validate(snapshot: snapshot, context: context, store: store, admissionRequired: !entries.isEmpty)
        var retained: [SchedulerReservationRecord] = []
        var pending: [LifecycleSchedulerWorkload] = []
        for entry in entries {
            if let existing = try repository.activeReservation(
                workloadID: entry.workload.workloadID, projectUUID: preparation.projectResourceUUID
            ) {
                guard [.pending, .committed].contains(existing.status),
                      existing.runtimeOwnership == entry.ownership,
                      existing.resources == entry.workload.request,
                      existing.nodeID == snapshot.capacity.nodeID else {
                    throw SchedulerAdmissionError.invalidBinding(field: "lifecycle-active-reservation")
                }
                retained.append(existing)
            } else {
                pending.append(entry)
            }
        }
        guard !entries.isEmpty else {
            return LifecycleSchedulerSession(
                context: context, store: store, plan: compiled.plan,
                snapshot: snapshot, reservations: retained
            )
        }
        let fence = try repository.fencingState(nodeID: snapshot.capacity.nodeID)
        var labels = snapshot.labels
        labels["hostwright.io/admission-epoch"] = String(fence.nodeEpoch)
        labels["hostwright.io/admission-sequence"] = String(fence.nextReservationSequence)
        labels["hostwright.io/pressure-generation"] = String(snapshot.pressure.generation)
        labels["hostwright.io/lifecycle-plan"] = compiled.plan.planSHA256
        let node = try SchedulerNode(
            snapshot: NodePlacementSnapshot(
                nodeID: snapshot.capacity.nodeID, capacity: snapshot.capacity.capacity,
                allocation: repository.activeCapacity(nodeID: snapshot.capacity.nodeID),
                architecture: "arm64", runtime: "linux-vm", provider: preparation.providerID.rawValue,
                labels: labels
            ), topologyDomains: snapshot.labels, posture: snapshot.pressure.posture
        )
        let existingPlacements = try retained.map { reservation in
            try SchedulerExistingPlacement(
                workloadID: reservation.workloadID, nodeID: reservation.nodeID,
                allocation: reservation.resources,
                topologyGroupID: entries.first { $0.workload.workloadID == reservation.workloadID }?.workload.topology.groupID
            )
        }
        let validatedDecision = try SchedulerEngine().plan(SchedulerEngineInput(
            pendingWorkloads: entries.map(\.workload), nodes: [node], existingPlacements: existingPlacements,
            preemptionPolicy: SchedulerPreemptionPolicy(incomingNonPreempting: true)
        ))
        try requirePlacements(validatedDecision)
        guard !pending.isEmpty else {
            return LifecycleSchedulerSession(
                context: context, store: store, plan: compiled.plan,
                snapshot: snapshot, reservations: retained
            )
        }
        let decision = try pending.count == entries.count ? validatedDecision : SchedulerEngine().plan(SchedulerEngineInput(
            pendingWorkloads: pending.map(\.workload), nodes: [node], existingPlacements: existingPlacements,
            preemptionPolicy: SchedulerPreemptionPolicy(incomingNonPreempting: true)
        ))
        try requirePlacements(decision)
        let now = timestamp(snapshot.observedAt)
        try store.desiredStates.registerProjectForAdmission(StateProjectRecord(
            id: preparation.projectID, name: preparation.desiredState.projectName,
            manifestPath: options.manifestPath, manifestHash: preparation.manifestSHA256,
            createdAt: now, updatedAt: now, resourceUUID: preparation.projectResourceUUID,
            manifestVersion: manifest.effectiveVersion, mutationProvider: preparation.providerID.rawValue,
            providerGeneration: preparation.providerGeneration
        ))
        let bindings = try pending.map { entry in
            try SchedulerDecisionWorkloadBinding(
                workloadID: entry.workload.workloadID, nodeID: snapshot.capacity.nodeID,
                resources: entry.workload.request, capacityDigest: snapshot.capacity.capacityDigest,
                capacityGeneration: snapshot.capacity.generation, ownerSubjectID: context.subjectID,
                projectUUID: preparation.projectResourceUUID, runtimeOwnership: entry.ownership
            )
        }
        try repository.recordDecisionArtifact(
            decision: decision, workloadBindings: bindings, projectUUID: preparation.projectResourceUUID,
            configDigest: snapshot.configDigest, profileDigest: snapshot.profileDigest,
            lifecyclePlanDigest: compiled.plan.planSHA256, createdAt: now, updatedAt: now
        )
        let authority = try SchedulerAdmissionCurrentAuthority(
            nodeCapacityDigest: snapshot.capacity.capacityDigest,
            nodeCapacityGeneration: snapshot.capacity.generation,
            configDigest: snapshot.configDigest, profileDigest: snapshot.profileDigest,
            lifecyclePlanDigest: compiled.plan.planSHA256, expectedNodeEpoch: fence.nodeEpoch,
            expectedPressureGeneration: snapshot.pressure.generation,
            expectedPressureEvidenceDigest: snapshot.pressure.evidenceDigest,
            expectedPressurePosture: snapshot.pressure.posture.pressure,
            leaseCreatedAt: now, leaseExpiresAt: timestamp(snapshot.observedAt.addingTimeInterval(300))
        )
        let admitted = try repository.applyPlacements(
            decisionID: decision.decisionID, projectUUID: preparation.projectResourceUUID,
            expectedInputDigest: decision.inputDigest,
            authorities: Dictionary(uniqueKeysWithValues: pending.map { ($0.workload.workloadID, authority) })
        )
        return LifecycleSchedulerSession(
            context: context, store: store, plan: compiled.plan,
            snapshot: snapshot, reservations: retained + admitted
        )
    }

    func validate(node: LifecyclePlanNode) throws {
        guard [.create, .start, .restart].contains(node.action) else { return }
        try lock.withLock {
            let fresh = try context.refresh()
            try Self.validate(snapshot: fresh, context: context, store: store)
            guard fresh.capacity == snapshot.capacity,
                  fresh.configDigest == snapshot.configDigest,
                  fresh.profileDigest == snapshot.profileDigest,
                  let reservation = reservations.first(where: {
                      $0.runtimeOwnership?.resourceUUID == node.resourceUUID &&
                        $0.runtimeOwnership?.resourceGeneration == Int64(node.resourceGeneration)
                  }),
                  let current = try store.schedulerAdmissions.reservation(id: reservation.reservationID),
                  [.pending, .committed].contains(current.status),
                  current.fencingToken == reservation.fencingToken,
                  current.runtimeOwnership == reservation.runtimeOwnership,
                  try store.schedulerAdmissions.fencingState(nodeID: current.nodeID).nodeEpoch ==
                    current.fencingToken.nodeEpoch else {
                throw SchedulerAdmissionError.staleInput(field: "lifecycle-reservation-authority")
            }
        }
    }

    static func reconcile(
        store: SQLiteStateStore,
        projectUUID: String,
        providerID: RuntimeProviderID,
        inventory: RuntimeInventory
    ) throws {
        let repository = store.schedulerAdmissions
        for reservation in try repository.activeReservations() {
            guard reservation.projectUUID == projectUUID,
                  let expected = reservation.runtimeOwnership,
                  expected.providerID == providerID,
                  expected.lifecycleWorkloadID == reservation.workloadID else { continue }
            let observation = try LifecycleSchedulerRuntimeObservation.observe(expected: expected, inventory: inventory)
            switch observation.state {
            case .running:
                if reservation.status == .pending {
                    try repository.commit(
                        reservationID: reservation.reservationID,
                        expectedToken: reservation.fencingToken, updatedAt: timestamp(Date())
                    )
                }
            case .inactive, .absent:
                try repository.release(
                    reservationID: reservation.reservationID, expectedToken: reservation.fencingToken,
                    evidence: .verifiedRuntimeAbsence(
                        evidenceDigest: observation.evidenceDigest, verifiedAt: timestamp(Date())
                    )
                )
            case .unknown:
                continue
            }
        }
    }

    func reconcile(inventory: RuntimeInventory) throws {
        try Self.reconcile(
            store: store, projectUUID: plan.projectResourceUUID, providerID: plan.providerID, inventory: inventory
        )
    }

    private static func validate(
        snapshot: LifecycleSchedulerHostSnapshot, context: LifecycleSchedulerContext, store: SQLiteStateStore,
        admissionRequired: Bool = true
    ) throws {
        guard let identity = try store.controlIdentities.loadIdentity(context.subjectID),
              identity.revokedAt == nil else {
            throw SchedulerAdmissionError.invalidBinding(field: "lifecycle-subject-authority")
        }
        guard admissionRequired else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let observedAt = formatter.date(from: snapshot.pressure.observedAt)
            ?? ISO8601DateFormatter().date(from: snapshot.pressure.observedAt)
        guard let observedAt,
              snapshot.observedAt.timeIntervalSince(observedAt) >= 0,
              snapshot.observedAt.timeIntervalSince(observedAt) <= 5,
              Date().timeIntervalSince(snapshot.observedAt) >= -1,
              Date().timeIntervalSince(snapshot.observedAt) <= 5,
              snapshot.capacity.nodeID == snapshot.pressure.nodeID,
              [.nominal, .elevated].contains(snapshot.pressure.posture.pressure),
              try store.schedulerAdmissions.nodeCapacity(nodeID: snapshot.capacity.nodeID) == snapshot.capacity,
              try store.schedulerAdmissions.hostPressure(nodeID: snapshot.capacity.nodeID) == snapshot.pressure else {
            throw SchedulerAdmissionError.staleInput(field: "lifecycle-host-authority")
        }
    }

    private static func requirePlacements(_ decision: SchedulerDecision) throws {
        let rejected = decision.workloadDecisions.filter {
            ![.placed, .retainedExistingPlacement].contains($0.outcome)
        }
        guard rejected.isEmpty else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "scheduler-admission-rejected: " + rejected.map {
                    "\($0.workloadID.uuidString.lowercased()): \($0.explanation.summary)"
                }.joined(separator: "; ")
            )
        }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
