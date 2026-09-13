import CryptoKit
import Foundation
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore
import HostwrightRuntime
import HostwrightScheduler
import HostwrightState

enum LocalLifecycleScheduler {
    static let nodeID = UUID(uuidString: HostwrightResourceUUID.legacy(
        kind: "scheduler-node", identifier: "local-mac"
    ))!

    static func rejection(
        request: ControlRequestEnvelope, repository: SchedulerAdmissionRepository
    ) throws -> ControlResponseEnvelope? {
        guard request.protocolRevision == .current else { return nil }
        let supported: Bool
        switch request.operation {
        case SchedulerControlOperation.plan.rawValue:
            let body = try SchedulerControlWireContract.scopedInputData(from: request.body)
            let input = try Phase09StrictDecoder.decode(
                SchedulerEngineInput.self, from: body.inputData,
                allowedKeys: SchedulerControlWireContract.inputKeys, requiredKeys: ["pendingWorkloads", "nodes"]
            )
            supported = supports(input)
        case SchedulerControlOperation.apply.rawValue:
            let body = try SchedulerControlWireContract.workloadMutationData(from: request.body)
            let projectUUID = HostwrightResourceUUID.isValid(body.projectID) ? body.projectID
                : try repository.projectResourceUUID(forProjectID: body.projectID)
            guard let projectUUID,
                  let artifact = try repository.decisionArtifact(id: body.decisionID, projectUUID: projectUUID) else { return nil }
            supported = artifact.decision.workloadDecisions.allSatisfy {
                $0.outcome != .preemptionProposed
            }
        default:
            return nil
        }
        guard !supported else { return nil }
        return ControlResponseEnvelope(
            protocolRevision: .current, requestID: request.requestID,
            status: .rejected, reasonCode: .invalidRequest,
            error: SanitizedError(
                code: "schedulerUnsupportedReleaseScope",
                message: "v0.0.2 supports local CPU/memory placement with hard constraints. This request includes deferred scheduling capabilities."
            )
        )
    }

    static func supports(_ input: SchedulerEngineInput) -> Bool {
        input.nodes.count == 1 &&
            input.nodes.allSatisfy { RuntimeProviderID.knownValues.contains(RuntimeProviderID(rawValue: $0.snapshot.provider)) } &&
            input.fairnessStates.isEmpty && input.victimAllocations.isEmpty && input.disruptionBudgets.isEmpty &&
            input.overcommitRatios.isEmpty && !input.preemptionPolicy.preemptionAuthorized &&
            input.pendingWorkloads.allSatisfy { workload in
                Set(workload.request.resourceNames).isSubset(of: ["cpu", "memory"]) &&
                    workload.requirements.acceleratorRequirements == .zero &&
                    workload.preemptionEligibility == .nonPreempting &&
                    workload.topology.spreadKey == nil &&
                    workload.topology.preferredDomainValues.isEmpty &&
                    workload.topology.affinityWorkloadIDs.isEmpty && workload.topology.antiAffinityWorkloadIDs.isEmpty &&
                    workload.topology.preferredAffinity.isEmpty && workload.topology.preferredAntiAffinity.isEmpty &&
                    workload.locality == .none && workload.disruption == .default
            }
    }

    static func context(
        subjectID: String,
        store: SQLiteStateStore,
        configPath: String,
        pressure: SchedulerPressureAuthorityCoordinator
    ) -> LifecycleSchedulerContext {
        LifecycleSchedulerContext(subjectID: subjectID) {
            let physicalMemory = ProcessInfo.processInfo.physicalMemory
            let reserve = max(2 * 1_024 * 1_024 * 1_024, physicalMemory / 4)
            guard physicalMemory > reserve, physicalMemory <= UInt64(Int64.max),
                  ProcessInfo.processInfo.processorCount > 1 else {
                throw SchedulerAdmissionError.invalidBinding(field: "local-host-capacity")
            }
            let capacity = try ResourceVector([
                "cpu": Int64(ProcessInfo.processInfo.processorCount - 1),
                "memory": Int64(physicalMemory - reserve)
            ])
            let repository = store.schedulerAdmissions
            let now = Date()
            let existing = try repository.nodeCapacity(nodeID: nodeID)
            let snapshot: SchedulerNodeCapacitySnapshot
            if let existing, existing.capacity == capacity {
                snapshot = existing
            } else {
                guard (existing?.generation ?? 0) < Int64.max else {
                    throw SchedulerAdmissionError.invalidBinding(field: "local-capacity-generation")
                }
                snapshot = try repository.recordNodeCapacity(snapshot: SchedulerNodeCapacitySnapshot(
                    nodeID: nodeID, capacity: capacity, generation: (existing?.generation ?? 0) + 1,
                    observedAt: ISO8601DateFormatter().string(from: now)
                ))
            }
            try pressure.refresh(nodeIDs: [nodeID])
            guard let record = try repository.hostPressure(nodeID: nodeID) else {
                throw SchedulerAdmissionError.staleInput(field: "local-pressure")
            }
            let config = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let profiles = try ControlPlaneCanonicalJSON.encode(store.workloadProfiles.listProfiles())
            return LifecycleSchedulerHostSnapshot(
                capacity: snapshot, pressure: record,
                configDigest: SHA256.hash(data: config).map { String(format: "%02x", $0) }.joined(),
                profileDigest: SHA256.hash(data: profiles).map { String(format: "%02x", $0) }.joined(),
                labels: ["hostwright.io/node": "local", "hostwright.io/architecture": "arm64"],
                observedAt: Date()
            )
        }
    }
}
