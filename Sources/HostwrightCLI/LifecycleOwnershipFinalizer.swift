import Foundation
import HostwrightCore
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

struct LifecycleCompositeFinalizer: LifecycleSagaFinalizing {
    let dependent: (any LifecycleSagaFinalizing)?
    let ownership: LifecycleOwnershipFinalizer

    func finalize(context: LifecycleSagaContext) async throws {
        try await dependent?.finalize(context: context)
        try await ownership.finalize(context: context)
    }
}

struct LifecycleOwnershipFinalizer: LifecycleSagaFinalizing {
    let store: SQLiteStateStore
    let adapter: any RuntimeAdapter

    func finalize(context: LifecycleSagaContext) async throws {
        let operationGroup = try exactOperationGroup(context: context)
        let deletingUUIDs = Set(
            context.plan.nodes.compactMap { node in
                node.action == .delete || node.action == .retire
                    ? node.resourceUUID
                    : nil
            }
        )
        let records = try store.ownership.loadAll().filter {
            $0.projectID == context.plan.projectID &&
                $0.projectResourceUUID ==
                    context.plan.projectResourceUUID &&
                RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) ==
                    context.plan.providerID
        }
        let inventory = deletingUUIDs.isEmpty
            ? nil
            : try await adapter.inventory()
        let activePorts = try store.networkPorts.loadProject(
            projectUUID: context.plan.projectResourceUUID
        )
        let activeTunnels = try store.serviceTunnels.listRecoverable(
            projectUUID: context.plan.projectResourceUUID
        )

        for record in records.sorted(by: {
            $0.resourceIdentifier < $1.resourceIdentifier
        }) {
            guard let authority = try OwnershipAuthorityMetadata.decode(
                from: record.metadataJSONRedacted
            ) else {
                if deletingUUIDs.contains(record.resourceUUID) {
                    throw StateStoreError.invalidRecord(
                        "Lifecycle deletion cannot finalize legacy ownership without versioned authority."
                    )
                }
                continue
            }
            try authority.validate(for: record)
            guard authority.operationGroupID == operationGroup.id else {
                continue
            }
            if deletingUUIDs.contains(record.resourceUUID) {
                try finalizeDeletion(
                    record: record,
                    authority: authority,
                    operationGroup: operationGroup,
                    inventory: inventory,
                    activePorts: activePorts,
                    activeTunnels: activeTunnels
                )
            } else if authority.leaseOwner != nil {
                guard let leaseOwner = operationGroup.lockOwner,
                      let leaseExpiry = operationGroup.lockExpiresAt else {
                    throw StateStoreError.invalidRecord(
                        "Ownership finalizer lost its exact finite lease."
                    )
                }
                try store.ownership.releaseMutationLease(
                    resourceIdentifier: record.resourceIdentifier,
                    runtimeAdapter: record.runtimeAdapter,
                    expectedResourceUUID: record.resourceUUID,
                    expectedFencingToken: record.fencingToken,
                    expectedOperationGroupID: operationGroup.id,
                    expectedLeaseOwner: leaseOwner,
                    expectedLeaseExpiresAt: leaseExpiry,
                    observedAt: ISO8601DateFormatter().string(from: Date())
                )
            }
        }
    }

    private func exactOperationGroup(
        context: LifecycleSagaContext
    ) throws -> OperationGroupRecord {
        guard let group = try store.operationGroups.load(id: context.groupID),
              group.status == .active,
              group.planHash == context.plan.planSHA256,
              group.fencingToken == context.fencingToken,
              let leaseOwner = context.leaseOwner,
              group.lockOwner == leaseOwner,
              group.lockExpiresAt != nil else {
            throw StateStoreError.invalidRecord(
                "Ownership finalization requires the exact active fenced operation lease."
            )
        }
        return group
    }

    private func finalizeDeletion(
        record: OwnershipRecord,
        authority: OwnershipAuthorityRecord,
        operationGroup: OperationGroupRecord,
        inventory: RuntimeInventory?,
        activePorts: [NetworkPortReservationRecord],
        activeTunnels: [ServiceTunnelStateRecord]
    ) throws {
        guard authority.deletionTimestamp != nil,
              authority.operationGroupID == operationGroup.id,
              authority.fencingToken == operationGroup.fencingToken,
              authority.leaseOwner == operationGroup.lockOwner,
              authority.leaseExpiresAt == operationGroup.lockExpiresAt,
              Set(authority.finalizers.map(\.state)) == [.releasing],
              activePorts.allSatisfy({
                  $0.resourceUUID != record.resourceUUID
              }),
              activeTunnels.isEmpty,
              inventory?.containers.allSatisfy({ container in
                  container.name != record.resourceIdentifier &&
                      container.ownership?.resourceUUID !=
                        record.resourceUUID
              }) == true else {
            throw StateStoreError.invalidRecord(
                "Ownership deletion finalizer could not prove dependent release and exact runtime absence."
            )
        }
        guard let leaseOwner = operationGroup.lockOwner,
              let leaseExpiry = operationGroup.lockExpiresAt else {
            throw StateStoreError.invalidRecord(
                "Ownership deletion finalizer lost its exact finite lease."
            )
        }
        _ = try store.ownership.markCleanupCompleted(
            resourceIdentifier: record.resourceIdentifier,
            runtimeAdapter: record.runtimeAdapter,
            expectedResourceUUID: record.resourceUUID,
            expectedFencingToken: record.fencingToken,
            expectedOperationGroupID: operationGroup.id,
            expectedLeaseOwner: leaseOwner,
            expectedLeaseExpiresAt: leaseExpiry,
            observedAt: ISO8601DateFormatter().string(from: Date())
        )
    }
}
