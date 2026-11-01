import Foundation
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

enum LifecycleSchedulerOwnershipAuthority {
    static func currentBinding(
        for expected: SchedulerRuntimeOwnershipBinding, store: SQLiteStateStore
    ) throws -> SchedulerRuntimeOwnershipBinding? {
        guard expected.providerID == .appleContainerization else { return expected }
        let candidates = try store.ownership.loadAll().filter {
            $0.resourceIdentifier == expected.resourceIdentifier || $0.resourceUUID == expected.resourceUUID
        }
        guard candidates.count <= 1 else { return nil }
        guard let current = candidates.first else { return expected }
        guard current.resourceIdentifier == expected.resourceIdentifier,
              current.resourceType == expected.resourceType,
              current.resourceUUID == expected.resourceUUID,
              Int64(current.resourceGeneration) == expected.resourceGeneration,
              current.projectResourceUUID == expected.projectUUID,
              Int64(current.projectGeneration) == expected.projectGeneration,
              Int64(current.providerGeneration) == expected.providerGeneration,
              current.identityVersion == expected.identityVersion,
              current.serviceName == expected.serviceName,
              RuntimeProviderBinding.stableID(for: current.runtimeAdapter) == expected.providerID else { return nil }
        guard current.fencingToken != expected.fencingToken else { return expected }

        // SDK mutations transfer the native fence; the admission decision remains immutable.
        guard let authority = try? OwnershipAuthorityMetadata.decode(from: current.metadataJSONRedacted),
              (try? authority.validate(for: current)) != nil,
              authority.controllerID == OwnershipAuthorityRecord.lifecycleController,
              authority.deletionTimestamp == nil,
              let groupID = authority.operationGroupID,
              let group = try store.operationGroups.load(id: groupID),
              group.groupKind == "lifecycle-v1",
              group.projectID == current.projectID,
              group.fencingToken == current.fencingToken,
              let plan = try? LifecyclePersistedIntentCodec.decode(group.intentJSONRedacted),
              plan.planSHA256 == group.planHash,
              plan.command.rawValue == group.plannedActionType,
              plan.projectID == current.projectID,
              plan.projectResourceUUID == expected.projectUUID,
              plan.projectName == expected.projectName,
              Int64(plan.projectGeneration) == expected.projectGeneration,
              plan.providerID == expected.providerID,
              Int64(plan.providerGeneration) == expected.providerGeneration,
              plan.nodes.contains(where: {
                  [.create, .start, .stop, .restart, .delete, .retire].contains($0.action) &&
                      $0.resourceIdentifier == expected.resourceIdentifier &&
                      $0.resourceUUID == expected.resourceUUID &&
                      Int64($0.resourceGeneration) == expected.resourceGeneration
              }) else { return nil }
        switch group.status {
        case .active:
            guard let owner = group.lockOwner, let expiry = group.lockExpiresAt,
                  authority.leaseOwner == owner, authority.leaseExpiresAt == expiry,
                  let expiresAt = ISO8601DateFormatter().date(from: expiry), expiresAt > Date() else { return nil }
        case .succeeded:
            guard group.checkpoint == "verified",
                  group.lockOwner == nil, group.lockExpiresAt == nil,
                  authority.leaseOwner == nil, authority.leaseExpiresAt == nil else { return nil }
        case .failed, .interrupted:
            return nil
        }
        return try replacingFence(in: expected, with: current.fencingToken)
    }

    static func replacingFence(
        in binding: SchedulerRuntimeOwnershipBinding, with fencingToken: String
    ) throws -> SchedulerRuntimeOwnershipBinding {
        try SchedulerRuntimeOwnershipBinding(
            resourceIdentifier: binding.resourceIdentifier, resourceType: binding.resourceType,
            resourceUUID: binding.resourceUUID, resourceGeneration: binding.resourceGeneration,
            projectUUID: binding.projectUUID, projectName: binding.projectName, projectGeneration: binding.projectGeneration,
            serviceName: binding.serviceName, instanceName: binding.instanceName, identityVersion: binding.identityVersion,
            providerID: binding.providerID, providerAPIVersion: binding.providerAPIVersion,
            providerVersion: binding.providerVersion, providerGeneration: binding.providerGeneration,
            fencingToken: fencingToken
        )
    }
}
