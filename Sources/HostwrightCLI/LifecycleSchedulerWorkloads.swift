import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightScheduler
import HostwrightState

struct LifecycleSchedulerWorkload: Sendable {
    let workload: SchedulerWorkload
    let ownership: SchedulerRuntimeOwnershipBinding
}

enum LifecycleSchedulerWorkloads {
    static func prepare(
        manifest: HostwrightManifest,
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation,
        options: LifecycleCLIOptions,
        subjectID: String,
        providerVersion: String,
        priorWorkloads: [UUID: SchedulerWorkload] = [:]
    ) throws -> [LifecycleSchedulerWorkload] {
        let admissions = try ManifestSchedulerAdmissionBridge.admit(
            manifest: manifest, subjectID: subjectID
        )
        let executionFence = options.operationIdempotencyKeySHA256.map {
            HostwrightResourceUUID.legacy(kind: "lifecycle-fencing", identifier: $0)
        } ?? preparation.planFencingToken
        let createResources = Set(compiled.plan.nodes.filter { $0.action == .create }.map(\.resourceUUID))
        var result: [UUID: LifecycleSchedulerWorkload] = [:]
        for node in compiled.plan.nodes where [.create, .start, .restart, .verify].contains(node.action) ||
            node.compensation.map({ [.create, .start, .restart].contains($0.action) }) == true {
            guard [.up, .run, .start, .restart, .update].contains(compiled.plan.command),
                  compiled.desiredServicesByNodeKey[node.key] != nil else { continue }
            if node.action == .verify,
               compiled.plan.nodes.contains(where: {
                   $0.action == .create && $0.resourceUUID == node.resourceUUID &&
                       $0.resourceGeneration != node.resourceGeneration
               }) { continue }
            guard let desired = compiled.desiredServicesByNodeKey[node.key],
                  let admission = admissions.first(where: {
                      $0.serviceName == desired.identity.serviceName && $0.replicaIndex == desired.replicaIndex
                  }),
                  let identifier = node.resourceIdentifier else {
                throw SchedulerAdmissionError.invalidBinding(field: "lifecycle-workload-mapping")
            }
            let prior = preparation.resourceBindings.first { $0.resourceUUID == node.resourceUUID }
            let ownership = try SchedulerRuntimeOwnershipBinding(
                resourceIdentifier: identifier,
                resourceType: "container",
                resourceUUID: node.resourceUUID,
                resourceGeneration: Int64(node.resourceGeneration),
                projectUUID: preparation.projectResourceUUID,
                projectName: preparation.desiredState.projectName,
                projectGeneration: Int64(preparation.projectGeneration),
                serviceName: desired.identity.serviceName,
                instanceName: desired.identity.instanceName,
                identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                providerID: preparation.providerID,
                providerAPIVersion: HostwrightContractVersions.runtimeProviderAPI,
                providerVersion: providerVersion,
                providerGeneration: Int64(preparation.providerGeneration),
                fencingToken: createResources.contains(node.resourceUUID)
                    ? executionFence : (prior?.currentFencingToken ?? executionFence)
            )
            let workloadID = ownership.lifecycleWorkloadID
            let previousWorkload = compiled.plan.command == .update && !createResources.contains(node.resourceUUID)
                ? priorWorkloads[workloadID] : nil
            let workload = try bind(
                workload: previousWorkload ?? admission.workload, workloadID: workloadID,
                subjectID: subjectID, projectID: preparation.projectResourceUUID
            )
            if let existing = result[workloadID] {
                guard existing.workload == workload, existing.ownership == ownership else {
                    throw SchedulerAdmissionError.invalidBinding(field: "lifecycle-workload-conflict")
                }
            } else {
                result[workloadID] = LifecycleSchedulerWorkload(workload: workload, ownership: ownership)
            }
        }
        return result.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { result[$0] }
    }

    static func bind(
        workload: SchedulerWorkload, workloadID: UUID,
        subjectID: String, projectID: String
    ) throws -> SchedulerWorkload {
        let requirement = workload.requirements
        return try SchedulerWorkload(
            requirements: WorkloadPlacementRequirements(
                workloadID: workloadID,
                resources: requirement.resources,
                requiredArchitectures: requirement.requiredArchitectures,
                requiredRuntime: requirement.requiredRuntime,
                requiredProvider: requirement.requiredProvider,
                requiredCapabilities: requirement.requiredCapabilities,
                affinity: requirement.affinity,
                tolerations: requirement.tolerations,
                acceleratorRequirements: requirement.acceleratorRequirements
            ),
            priority: workload.priority,
            subjectID: subjectID, projectID: projectID,
            topology: workload.topology
        )
    }

}
