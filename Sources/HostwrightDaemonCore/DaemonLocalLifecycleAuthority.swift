import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

public enum DaemonLocalLifecycleAuthorityError: String, Error, Equatable, Sendable {
    case staleProject
    case invalidHistory
    case unresolvedIntent
    case missingIntent
    case conflictingOwnership
    case missingReservation
    case revokedSubject
    case authorityChanged
}

public struct DaemonLocalLifecycleAuthority: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let serviceName: String
        public let resourceUUID: String
        public let resourceGeneration: Int64
        public let reservation: SchedulerReservationRecord
        public let operationGroupID: String
        public let planSHA256: String
    }

    public let projectUUID: String
    public let sourceManifestSHA256: String
    public let manifestSHA256: String
    public let entries: [Entry]

    private struct Intent {
        let group: OperationGroupRecord
        let plan: LifecyclePlan
    }

    public static func resolve(
        store: SQLiteStateStore,
        manifest: HostwrightManifest,
        manifestSHA256: String,
        projectID: String,
        lifecycleManifestSHA256: String? = nil
    ) throws -> DaemonLocalLifecycleAuthority? {
        guard try store.schedulerAdmissions.projectAuthority(forProjectID: projectID) != nil else { return nil }
        let project = try store.desiredStates.loadProject(id: projectID)
        var hasHistory = false
        try store.schedulerAdmissions.visitReservationHistory(projectUUID: project.resourceUUID) { reservation in
            hasHistory = hasHistory || reservation.runtimeOwnership?.lifecycleWorkloadID == reservation.workloadID
            return true
        }
        guard hasHistory else { return nil }
        guard lifecycleManifestSHA256 != nil ||
                (manifest.imageTrust == nil && manifest.imageSBOM == nil &&
                    manifest.imageVulnerability == nil && manifest.imageProvenance == nil) else {
            throw DaemonLocalLifecycleAuthorityError.staleProject
        }
        let effectiveManifestSHA256 = lifecycleManifestSHA256 ?? manifestSHA256
        guard ManifestValidator.validate(manifest).isEmpty,
              projectID == "project-\(manifest.project ?? "")",
              project.name == manifest.project,
              project.manifestHash == effectiveManifestSHA256,
              project.manifestVersion == manifest.effectiveVersion,
              let provider = project.mutationProvider.flatMap(RuntimeProviderBinding.stableID(for:)),
              RuntimeProviderID.knownValues.contains(provider), project.providerGeneration > 0 else {
            throw DaemonLocalLifecycleAuthorityError.staleProject
        }
        let expectedIdentities = Set(manifest.services.flatMap { service in
            (0..<service.replicas).map { replica in
                RuntimeServiceIdentity(projectName: project.name, serviceName: service.name,
                    instanceName: replica == 0 ? nil : "replica-\(replica)").displayName
            }
        })
        var latest: [String: Intent] = [:]
        var identityCache: [String: Set<RuntimeServiceIdentity>] = [:]
        var completedPlanCache: [String: LifecyclePlan?] = [:]
        try store.operationGroups.visitProjectLifecycleHistory(projectID: projectID) { group in
            guard let plan = try? LifecyclePersistedIntentCodec.decode(group.intentJSONRedacted),
                  group.planHash == plan.planSHA256,
                  group.plannedActionType == plan.command.rawValue,
                  plan.projectID == projectID, plan.projectResourceUUID == project.resourceUUID else {
                throw DaemonLocalLifecycleAuthorityError.invalidHistory
            }
            for node in plan.nodes where node.serviceName != nil && node.resourceIdentifier != nil {
                guard let identity = try Self.identityKey(node: node, plan: plan, store: store, cache: &identityCache) else {
                    throw DaemonLocalLifecycleAuthorityError.invalidHistory
                }
                if expectedIdentities.contains(identity) { latest[identity] = Intent(group: group, plan: plan) }
            }
        }
        let ownership = try store.ownership.loadAll()
        var entries: [Entry] = []
        for service in manifest.services.sorted(by: { $0.name < $1.name }) {
            for replica in 0..<service.replicas {
                let identity = RuntimeServiceIdentity(
                    projectName: project.name, serviceName: service.name,
                    instanceName: replica == 0 ? nil : "replica-\(replica)"
                )
                guard let intent = latest[identity.displayName] else {
                    throw DaemonLocalLifecycleAuthorityError.missingIntent
                }
                guard intent.group.status == .succeeded else {
                    throw DaemonLocalLifecycleAuthorityError.unresolvedIntent
                }
                guard intent.plan.manifestSHA256 == effectiveManifestSHA256,
                      intent.plan.providerID == provider,
                      intent.plan.providerGeneration == project.providerGeneration else {
                    throw DaemonLocalLifecycleAuthorityError.staleProject
                }
                if [.down, .stop, .remove, .run].contains(intent.plan.command) { continue }
                guard [.up, .start, .restart, .update].contains(intent.plan.command) else {
                    throw DaemonLocalLifecycleAuthorityError.unresolvedIntent
                }
                let currentOwnership = try ownership.filter { record in
                    guard record.projectID == projectID && record.projectResourceUUID == project.resourceUUID &&
                        record.resourceType == "container" && record.serviceName == service.name &&
                        RuntimeProviderBinding.stableID(for: record.runtimeAdapter) == provider else { return false }
                    var matches = false
                    try store.schedulerAdmissions.visitReservationHistory(
                        projectUUID: project.resourceUUID,
                        workloadID: Self.workloadID(resourceUUID: record.resourceUUID, generation: record.resourceGeneration)
                    ) { reservation in
                        let binding = reservation.runtimeOwnership
                        matches = binding?.serviceName == identity.serviceName && binding?.instanceName == identity.instanceName &&
                            binding?.resourceUUID == record.resourceUUID && binding?.resourceGeneration == Int64(record.resourceGeneration)
                        return !matches
                    }
                    return matches
                }
                guard currentOwnership.count == 1, let current = currentOwnership.first else {
                    throw DaemonLocalLifecycleAuthorityError.conflictingOwnership
                }
                guard let node = try intent.plan.nodes.first(where: {
                    try Self.identityKey(node: $0, plan: intent.plan, store: store, cache: &identityCache) == identity.displayName &&
                        $0.resourceUUID == current.resourceUUID &&
                        $0.resourceGeneration == current.resourceGeneration &&
                        $0.resourceIdentifier == current.resourceIdentifier
                }) else { throw DaemonLocalLifecycleAuthorityError.missingReservation }
                let resourceUUID = current.resourceUUID
                var selectedReservation: SchedulerReservationRecord?
                try store.schedulerAdmissions.visitReservationHistory(
                    projectUUID: project.resourceUUID,
                    workloadID: Self.workloadID(resourceUUID: resourceUUID, generation: node.resourceGeneration)
                ) { candidate in
                    guard let origin = try Self.completedPlan(
                        store: store, projectID: projectID, projectUUID: project.resourceUUID,
                        planHash: candidate.lifecyclePlanDigest, cache: &completedPlanCache
                    ) else { return true }
                    if try candidate.runtimeOwnership?.resourceUUID == resourceUUID &&
                        candidate.runtimeOwnership?.resourceGeneration == Int64(node.resourceGeneration) &&
                        [.up, .start, .restart, .update].contains(origin.command) &&
                        origin.projectResourceUUID == intent.plan.projectResourceUUID &&
                        origin.projectGeneration == intent.plan.projectGeneration &&
                        origin.providerID == intent.plan.providerID &&
                        origin.providerGeneration == intent.plan.providerGeneration &&
                        origin.nodes.contains(where: { originNode in
                            try originNode.resourceUUID == resourceUUID &&
                                originNode.resourceGeneration == node.resourceGeneration &&
                                originNode.resourceIdentifier == node.resourceIdentifier &&
                                Self.identityKey(node: originNode, plan: origin, store: store, cache: &identityCache) == identity.displayName
                        }) { selectedReservation = candidate }
                    return true
                }
                guard let reservation = selectedReservation, let binding = reservation.runtimeOwnership,
                      [.committed, .released].contains(reservation.status),
                      binding.projectUUID == project.resourceUUID,
                      binding.projectName == project.name,
                      binding.projectGeneration == Int64(intent.plan.projectGeneration),
                      binding.providerID == provider,
                      binding.providerAPIVersion == HostwrightContractVersions.runtimeProviderAPI,
                      binding.providerGeneration == Int64(project.providerGeneration),
                      binding.resourceIdentifier == node.resourceIdentifier else {
                    throw DaemonLocalLifecycleAuthorityError.missingReservation
                }
                let records = ownership.filter {
                    $0.resourceUUID == binding.resourceUUID ||
                        ($0.resourceIdentifier == binding.resourceIdentifier &&
                            RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) == provider)
                }
                guard records.count == 1, let record = records.first,
                      record.resourceUUID == binding.resourceUUID,
                      record.resourceGeneration == Int(binding.resourceGeneration),
                      record.resourceType == "container", record.resourceIdentifier == binding.resourceIdentifier,
                      record.projectID == projectID, record.projectResourceUUID == binding.projectUUID,
                      record.projectGeneration == Int(binding.projectGeneration),
                      record.serviceName == binding.serviceName,
                      record.providerGeneration == Int(binding.providerGeneration),
                      RuntimeProviderBinding.stableID(for: record.runtimeAdapter) == binding.providerID,
                      record.identityVersion == binding.identityVersion,
                      record.fencingToken == binding.fencingToken else {
                    throw DaemonLocalLifecycleAuthorityError.conflictingOwnership
                }
                guard let subject = try store.controlIdentities.loadIdentity(reservation.ownerSubjectID),
                      subject.revokedAt == nil else {
                    throw DaemonLocalLifecycleAuthorityError.revokedSubject
                }
                entries.append(Entry(
                    serviceName: service.name, resourceUUID: resourceUUID,
                    resourceGeneration: binding.resourceGeneration, reservation: reservation,
                    operationGroupID: intent.group.id, planSHA256: intent.plan.planSHA256
                ))
            }
        }
        return DaemonLocalLifecycleAuthority(
            projectUUID: project.resourceUUID, sourceManifestSHA256: manifestSHA256,
            manifestSHA256: effectiveManifestSHA256,
            entries: entries.sorted { $0.resourceUUID < $1.resourceUUID }
        )
    }

    private static func workloadID(resourceUUID: String, generation: Int) -> UUID {
        UUID(uuidString: HostwrightResourceUUID.legacy(
            kind: "local-scheduler-workload", identifier: "\(resourceUUID):\(generation)"
        ))!
    }

    private static func completedPlan(
        store: SQLiteStateStore, projectID: String, projectUUID: String, planHash: String,
        cache: inout [String: LifecyclePlan?]
    ) throws -> LifecyclePlan? {
        if let cached = cache[planHash] { return cached }
        var result: LifecyclePlan?
        try store.operationGroups.visitProjectLifecycleHistory(projectID: projectID, planHash: planHash) { group in
            guard let plan = try? LifecyclePersistedIntentCodec.decode(group.intentJSONRedacted),
                  group.planHash == plan.planSHA256, group.plannedActionType == plan.command.rawValue,
                  plan.projectID == projectID, plan.projectResourceUUID == projectUUID else {
                throw DaemonLocalLifecycleAuthorityError.invalidHistory
            }
            if group.status == .succeeded { result = plan }
        }
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[planHash] = .some(result)
        return result
    }

    private static func identityKey(
        node: LifecyclePlanNode, plan: LifecyclePlan, store: SQLiteStateStore,
        cache: inout [String: Set<RuntimeServiceIdentity>]
    ) throws -> String? {
        let key = "\(node.resourceUUID):\(node.resourceGeneration):\(node.resourceIdentifier ?? "")"
        var identities = cache[key] ?? []
        if cache[key] == nil {
            try store.schedulerAdmissions.visitReservationHistory(
                projectUUID: plan.projectResourceUUID,
                workloadID: workloadID(resourceUUID: node.resourceUUID, generation: node.resourceGeneration)
            ) { reservation in
                guard let binding = reservation.runtimeOwnership,
                      binding.lifecycleWorkloadID == reservation.workloadID,
                      binding.resourceUUID == node.resourceUUID,
                      binding.resourceGeneration == Int64(node.resourceGeneration),
                      binding.resourceIdentifier == node.resourceIdentifier else { return true }
                identities.insert(RuntimeServiceIdentity(
                    projectName: binding.projectName, serviceName: binding.serviceName, instanceName: binding.instanceName
                ))
                guard identities.count < 2 else { throw DaemonLocalLifecycleAuthorityError.invalidHistory }
                return true
            }
            if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
            cache[key] = identities
        }
        let identity: RuntimeServiceIdentity
        if identities.count == 1, let recorded = identities.first {
            identity = recorded
        } else if identities.isEmpty, let desired = try? LifecycleRevisionCodec.decodeRedactedDesiredJSON(
            node.desiredSpecificationJSONRedacted
        ) {
            identity = desired.identity
        } else { return nil }
        guard identity.projectName == plan.projectName,
              node.serviceName == identity.displayName || node.serviceName == identity.serviceName else { return nil }
        return identity.displayName
    }

    public func revalidate(
        store: SQLiteStateStore, manifest: HostwrightManifest, projectID: String,
        lifecycleManifestSHA256: String? = nil
    ) throws {
        guard try Self.resolve(
            store: store, manifest: manifest, manifestSHA256: sourceManifestSHA256, projectID: projectID,
            lifecycleManifestSHA256: lifecycleManifestSHA256
        ) == self else { throw DaemonLocalLifecycleAuthorityError.authorityChanged }
    }
}
