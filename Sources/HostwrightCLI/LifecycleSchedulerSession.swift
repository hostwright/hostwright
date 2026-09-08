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
    private var reservations: [SchedulerReservationRecord]
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
        var priorWorkloads: [UUID: SchedulerWorkload] = [:]
        for reservation in try store.schedulerAdmissions.activeReservations()
            where reservation.projectUUID == preparation.projectResourceUUID {
            if let workload = try store.schedulerAdmissions.decisionArtifact(id: reservation.decisionID)?
                .binding(for: reservation.workloadID)?.lifecycleWorkload {
                priorWorkloads[reservation.workloadID] = workload
            }
        }
        let entries = try LifecycleSchedulerWorkloads.prepare(
            manifest: manifest, compiled: compiled, preparation: preparation,
            options: options, subjectID: context.subjectID, providerVersion: providerVersion,
            priorWorkloads: priorWorkloads
        )
        let now = timestamp(Date())
        return try reserve(
            context: context, store: store, entries: entries, plan: compiled.plan,
            project: StateProjectRecord(
                id: preparation.projectID, name: preparation.desiredState.projectName,
                manifestPath: options.manifestPath, manifestHash: preparation.manifestSHA256,
                createdAt: now, updatedAt: now, resourceUUID: preparation.projectResourceUUID,
                manifestVersion: manifest.effectiveVersion, mutationProvider: preparation.providerID.rawValue,
                providerGeneration: preparation.providerGeneration
            )
        )
    }

    private static func reserve(
        context: LifecycleSchedulerContext, store: SQLiteStateStore,
        entries: [LifecycleSchedulerWorkload], plan: LifecyclePlan, project: StateProjectRecord
    ) throws -> LifecycleSchedulerSession {
        try context.authorize(plan)
        let snapshot = try context.refresh()
        let repository = store.schedulerAdmissions
        try validate(snapshot: snapshot, context: context, store: store, admissionRequired: !entries.isEmpty)
        var retained: [SchedulerReservationRecord] = []
        var pending: [LifecycleSchedulerWorkload] = []
        for entry in entries {
            if let existing = try repository.activeReservation(
                workloadID: entry.workload.workloadID, projectUUID: project.resourceUUID
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
                context: context, store: store, plan: plan,
                snapshot: snapshot, reservations: retained
            )
        }
        let fence = try repository.fencingState(nodeID: snapshot.capacity.nodeID)
        var labels = snapshot.labels
        labels["hostwright.io/admission-epoch"] = String(fence.nodeEpoch)
        labels["hostwright.io/admission-sequence"] = String(fence.nextReservationSequence)
        labels["hostwright.io/pressure-generation"] = String(snapshot.pressure.generation)
        labels["hostwright.io/lifecycle-plan"] = plan.planSHA256
        let node = try SchedulerNode(
            snapshot: NodePlacementSnapshot(
                nodeID: snapshot.capacity.nodeID, capacity: snapshot.capacity.capacity,
                allocation: repository.activeCapacity(nodeID: snapshot.capacity.nodeID),
                architecture: "arm64", runtime: "linux-vm", provider: plan.providerID.rawValue,
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
                context: context, store: store, plan: plan,
                snapshot: snapshot, reservations: retained
            )
        }
        let decision = validatedDecision
        let now = timestamp(snapshot.observedAt)
        try store.desiredStates.registerProjectForAdmission(project)
        let bindings = try entries.map { entry in
            try SchedulerDecisionWorkloadBinding(
                workloadID: entry.workload.workloadID, nodeID: snapshot.capacity.nodeID,
                resources: entry.workload.request, capacityDigest: snapshot.capacity.capacityDigest,
                capacityGeneration: snapshot.capacity.generation, ownerSubjectID: context.subjectID,
                projectUUID: project.resourceUUID, runtimeOwnership: entry.ownership, lifecycleWorkload: entry.workload
            )
        }
        try repository.recordDecisionArtifact(
            decision: decision, workloadBindings: bindings, projectUUID: project.resourceUUID,
            configDigest: snapshot.configDigest, profileDigest: snapshot.profileDigest,
            lifecyclePlanDigest: plan.planSHA256, createdAt: now, updatedAt: now
        )
        let authority = try SchedulerAdmissionCurrentAuthority(
            nodeCapacityDigest: snapshot.capacity.capacityDigest,
            nodeCapacityGeneration: snapshot.capacity.generation,
            configDigest: snapshot.configDigest, profileDigest: snapshot.profileDigest,
            lifecyclePlanDigest: plan.planSHA256, expectedNodeEpoch: fence.nodeEpoch,
            expectedPressureGeneration: snapshot.pressure.generation,
            expectedPressureEvidenceDigest: snapshot.pressure.evidenceDigest,
            expectedPressurePosture: snapshot.pressure.posture.pressure,
            leaseCreatedAt: now, leaseExpiresAt: timestamp(snapshot.observedAt.addingTimeInterval(300))
        )
        let admitted = try repository.applyPlacements(
            decisionID: decision.decisionID, projectUUID: project.resourceUUID,
            expectedInputDigest: decision.inputDigest,
            authorities: Dictionary(uniqueKeysWithValues: entries.map { ($0.workload.workloadID, authority) }),
            retaining: Dictionary(uniqueKeysWithValues: retained.map { ($0.workloadID, $0) })
        )
        return LifecycleSchedulerSession(
            context: context, store: store, plan: plan,
            snapshot: snapshot, reservations: admitted
        )
    }

    func validate(node: LifecyclePlanNode) throws {
        guard [.create, .start, .restart].contains(node.action) else { return }
        try lock.withLock {
            try context.authorize(plan)
            let fresh = try context.refresh()
            try Self.validate(snapshot: fresh, context: context, store: store)
            guard fresh.capacity == snapshot.capacity,
                  fresh.configDigest == snapshot.configDigest,
                  fresh.profileDigest == snapshot.profileDigest,
                  let index = reservations.firstIndex(where: {
                      $0.runtimeOwnership?.resourceUUID == node.resourceUUID &&
                        $0.runtimeOwnership?.resourceGeneration == Int64(node.resourceGeneration)
                  }) else {
                throw SchedulerAdmissionError.staleInput(field: "lifecycle-reservation-authority")
            }
            var reservation = reservations[index]
            if try store.schedulerAdmissions.reservation(id: reservation.reservationID)?.status == .released {
                guard let persisted = try store.schedulerAdmissions.decisionArtifact(id: reservation.decisionID)?
                    .binding(for: reservation.workloadID), let workload = persisted.lifecycleWorkload,
                      let oldOwnership = persisted.runtimeOwnership else {
                    throw SchedulerAdmissionError.staleInput(field: "lifecycle-readmission-constraints")
                }
                let ownership = try Self.activationOwnership(oldOwnership, node: node)
                let renewed = try Self.reserve(
                    context: context, store: store,
                    entries: [LifecycleSchedulerWorkload(workload: workload, ownership: ownership)],
                    plan: plan, project: store.desiredStates.loadProject(id: plan.projectID)
                )
                guard let replacement = renewed.reservations.first else {
                    throw SchedulerAdmissionError.staleInput(field: "lifecycle-readmission")
                }
                reservations[index] = replacement
                reservation = replacement
            }
            guard let current = try store.schedulerAdmissions.reservation(id: reservation.reservationID),
                  [.pending, .committed].contains(current.status),
                  current.fencingToken == reservation.fencingToken,
                  current.runtimeOwnership == reservation.runtimeOwnership,
                  try store.schedulerAdmissions.fencingState(nodeID: current.nodeID).nodeEpoch ==
                    current.fencingToken.nodeEpoch else {
                throw SchedulerAdmissionError.staleInput(field: "lifecycle-reservation-authority")
            }
        }
    }

    static func validateRecoveryActivation(
        context: LifecycleSchedulerContext, store: SQLiteStateStore,
        plan: LifecyclePlan, node: LifecyclePlanNode, environment: CLIEnvironment
    ) throws {
        let snapshot = try context.refresh()
        try validate(snapshot: snapshot, context: context, store: store)
        var selectedPrevious: SchedulerReservationRecord?
        let workloadID = UUID(uuidString: HostwrightResourceUUID.legacy(
            kind: "local-scheduler-workload", identifier: "\(node.resourceUUID):\(node.resourceGeneration)"
        ))!
        try store.schedulerAdmissions.visitReservationHistory(
            projectUUID: plan.projectResourceUUID, workloadID: workloadID
        ) { reservation in
            if reservation.runtimeOwnership?.resourceUUID == node.resourceUUID &&
                reservation.runtimeOwnership?.resourceGeneration == Int64(node.resourceGeneration) &&
                reservation.runtimeOwnership?.lifecycleWorkloadID == reservation.workloadID {
                selectedPrevious = reservation
            }
            return true
        }
        guard let previous = selectedPrevious, let ownership = previous.runtimeOwnership,
              ownership.resourceIdentifier == node.resourceIdentifier,
              ownership.projectUUID == plan.projectResourceUUID,
              ownership.projectGeneration == Int64(plan.projectGeneration),
              ownership.providerID == plan.providerID,
              ownership.providerGeneration == Int64(plan.providerGeneration),
              previous.nodeID == snapshot.capacity.nodeID,
              previous.capacityDigest == snapshot.capacity.capacityDigest,
              previous.capacityGeneration == snapshot.capacity.generation,
              previous.configDigest == snapshot.configDigest,
              previous.profileDigest == snapshot.profileDigest,
              Set(previous.resources.resourceNames).isSubset(of: ["cpu", "memory"]),
              previous.resources["cpu"] > 0, previous.resources["memory"] > 0 else {
            throw SchedulerAdmissionError.staleInput(field: "recovery-local-admission-lineage")
        }
        let project = try store.desiredStates.loadProject(id: plan.projectID)
        guard project.resourceUUID == plan.projectResourceUUID,
              project.providerGeneration == plan.providerGeneration,
              project.mutationProvider == plan.providerID.rawValue else {
            throw SchedulerAdmissionError.staleInput(field: "recovery-local-project")
        }
        guard project.manifestHash == plan.manifestSHA256, let manifestPath = project.manifestPath else {
            throw SchedulerAdmissionError.staleInput(field: "recovery-local-manifest")
        }
        let text = try hostwrightReadManifestText(path: manifestPath, environment: environment)
        let manifest = try hostwrightValidatedManifest(
            text: text, teamProfilePath: nil, environment: environment
        ).manifest
        guard try lifecycleManifestSHA256(text: text, manifest: manifest) == plan.manifestSHA256,
              manifest.project == project.name else {
            throw SchedulerAdmissionError.staleInput(field: "recovery-local-manifest")
        }
        var selectedOrigin: LifecyclePlan?
        try store.operationGroups.visitProjectLifecycleHistory(
            projectID: plan.projectID, planHash: previous.lifecyclePlanDigest
        ) { group in
            let origin = try LifecyclePersistedIntentCodec.decode(group.intentJSONRedacted)
            guard origin.planSHA256 == group.planHash else {
                throw SchedulerAdmissionError.staleInput(field: "recovery-local-plan-lineage")
            }
            if selectedOrigin == nil && origin.projectID == plan.projectID &&
                origin.projectResourceUUID == plan.projectResourceUUID &&
                origin.projectGeneration == plan.projectGeneration && origin.providerID == plan.providerID &&
                origin.providerGeneration == plan.providerGeneration && origin.nodes.contains(where: {
                    $0.resourceUUID == node.resourceUUID && $0.resourceGeneration == node.resourceGeneration &&
                        $0.resourceIdentifier == ownership.resourceIdentifier &&
                        ($0.serviceName == ownership.serviceName || $0.serviceName == RuntimeServiceIdentity(
                            projectName: ownership.projectName, serviceName: ownership.serviceName,
                            instanceName: ownership.instanceName
                        ).displayName)
                }) { selectedOrigin = origin }
        }
        guard let origin = selectedOrigin else {
            throw SchedulerAdmissionError.staleInput(field: "recovery-local-plan-lineage")
        }
        let artifact = try store.schedulerAdmissions.decisionArtifact(id: previous.decisionID)
        let persistedWorkload = artifact?.binding(for: previous.workloadID)?.lifecycleWorkload
        let sourceWorkload: SchedulerWorkload
        if let persistedWorkload {
            guard artifact?.lifecyclePlanDigest == origin.planSHA256,
                  artifact?.binding(for: previous.workloadID)?.runtimeOwnership == ownership,
                  persistedWorkload.request == previous.resources else {
                throw SchedulerAdmissionError.staleInput(field: "recovery-local-workload")
            }
            if origin.manifestSHA256 != plan.manifestSHA256 {
                let currentAdmission = try ManifestSchedulerAdmissionBridge.admit(manifest: manifest, subjectID: context.subjectID)
                    .first { $0.serviceName == ownership.serviceName &&
                        ($0.replicaIndex == 0 ? nil : "replica-\($0.replicaIndex)") == ownership.instanceName }
                let sameConstraints = try currentAdmission.map {
                    try LifecycleSchedulerWorkloads.bind(
                        workload: $0.workload, workloadID: previous.workloadID,
                        subjectID: persistedWorkload.subjectID, projectID: plan.projectResourceUUID
                    ) == persistedWorkload
                } ?? false
                let inverse = plan.nodes.contains {
                    $0.resourceUUID == node.resourceUUID && $0.resourceGeneration == node.resourceGeneration &&
                        $0.key == node.key && $0.compensation?.action == node.action
                } || (plan.command == .rollback && node.preconditions.contains { $0.kind == "rollback-source-group" })
                guard sameConstraints || inverse else {
                    throw SchedulerAdmissionError.staleInput(field: "recovery-local-constraints-changed")
                }
            }
            sourceWorkload = persistedWorkload
        } else {
            guard origin.manifestSHA256 == plan.manifestSHA256 else {
                throw SchedulerAdmissionError.staleInput(field: "recovery-local-constraints-unavailable")
            }
            let admissions = try ManifestSchedulerAdmissionBridge.admit(manifest: manifest, subjectID: context.subjectID)
            guard let admission = admissions.first(where: {
                $0.serviceName == ownership.serviceName &&
                    ($0.replicaIndex == 0 ? nil : "replica-\($0.replicaIndex)") == ownership.instanceName
            }), admission.workload.request == previous.resources else {
                throw SchedulerAdmissionError.staleInput(field: "recovery-local-workload")
            }
            sourceWorkload = admission.workload
        }
        let workload = try LifecycleSchedulerWorkloads.bind(
            workload: sourceWorkload, workloadID: previous.workloadID,
            subjectID: context.subjectID, projectID: plan.projectResourceUUID
        )
        let session = try reserve(
            context: context, store: store,
            entries: [LifecycleSchedulerWorkload(
                workload: workload, ownership: activationOwnership(ownership, node: node)
            )],
            plan: plan, project: project
        )
        try session.validate(node: node)
    }

    private static func activationOwnership(
        _ binding: SchedulerRuntimeOwnershipBinding, node: LifecyclePlanNode
    ) throws -> SchedulerRuntimeOwnershipBinding {
        guard node.action == .create else { return binding }
        return try SchedulerRuntimeOwnershipBinding(
            resourceIdentifier: binding.resourceIdentifier, resourceType: binding.resourceType,
            resourceUUID: binding.resourceUUID, resourceGeneration: binding.resourceGeneration,
            projectUUID: binding.projectUUID, projectName: binding.projectName, projectGeneration: binding.projectGeneration,
            serviceName: binding.serviceName, instanceName: binding.instanceName, identityVersion: binding.identityVersion,
            providerID: binding.providerID, providerAPIVersion: binding.providerAPIVersion,
            providerVersion: binding.providerVersion, providerGeneration: binding.providerGeneration,
            fencingToken: node.fencingToken
        )
    }

    static func reconcile(
        store: SQLiteStateStore,
        projectUUID: String,
        providerID: RuntimeProviderID,
        inventory: RuntimeInventory,
        resourceUUID: String? = nil
    ) throws {
        let repository = store.schedulerAdmissions
        for reservation in try repository.activeReservations() {
            guard reservation.projectUUID == projectUUID,
                  let expected = reservation.runtimeOwnership,
                  expected.providerID == providerID,
                  expected.lifecycleWorkloadID == reservation.workloadID,
                  resourceUUID == nil || expected.resourceUUID == resourceUUID else { continue }
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
