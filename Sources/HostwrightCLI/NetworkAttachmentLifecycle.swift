import CryptoKit
import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

enum NetworkAttachmentLifecycleError: Error, Equatable {
    case invalidIdentity(String)
    case ownershipConflict(String)
    case observationIndeterminate(String)
}

struct NetworkAttachmentCreateDescriptor:
    Equatable,
    Sendable
{
    let network: NetworkStateResourceRecord
    let containerRuntimeIdentifier: String
    let containerContext: RuntimeMutationContext
    let aliases: [String]

    init(
        network: NetworkStateResourceRecord,
        containerRuntimeIdentifier: String,
        containerContext: RuntimeMutationContext,
        aliases: [String] = []
    ) throws {
        guard network.lifecycleState == .available,
              network.finalizerState == .active,
              network.projectUUID ==
                containerContext.projectResourceUUID,
              network.providerID ==
                containerContext.providerID.rawValue,
              network.providerGeneration ==
                Int64(containerContext.providerGeneration),
              containerContext.validationIssue == nil,
              RuntimeManagedResourceIdentity.isCurrentIdentifier(
                containerRuntimeIdentifier
              ),
              aliases == aliases.sorted(),
              Set(aliases).count == aliases.count else {
            throw NetworkAttachmentLifecycleError.invalidIdentity(
                "Create-time network attachment identity is invalid."
            )
        }
        self.network = network
        self.containerRuntimeIdentifier =
            containerRuntimeIdentifier
        self.containerContext = containerContext
        self.aliases = aliases
    }

    var attachmentUUID: String {
        NetworkAttachmentLifecycle.attachmentUUID(
            networkUUID: network.id,
            resourceUUID: containerContext.resourceUUID
        )
    }

    var desiredSHA256: String {
        NetworkAttachmentLifecycle.desiredSHA256(
            attachmentUUID: attachmentUUID,
            networkUUID: network.id,
            networkRuntimeIdentifier: network.runtimeName,
            projectUUID: network.projectUUID,
            resourceUUID: containerContext.resourceUUID,
            containerRuntimeIdentifier:
                containerRuntimeIdentifier,
            aliases: aliases
        )
    }
}

enum NetworkAttachmentCreateResolution:
    Equatable,
    Sendable
{
    case absent
    case attached(NetworkStateAttachmentRecord)
    case quarantined(NetworkStateAttachmentRecord)
}

enum NetworkAttachmentLifecycle {
    static func attachmentUUID(
        networkUUID: String,
        resourceUUID: String
    ) -> String {
        HostwrightResourceUUID.legacy(
            kind: "network-attachment",
            identifier: "\(networkUUID):\(resourceUUID)"
        )
    }

    static func persistCreateIntent(
        _ descriptor: NetworkAttachmentCreateDescriptor,
        authority: NetworkStateMutationAuthority,
        timestamp: String,
        repository: NetworkStateRepository
    ) throws -> NetworkStateAttachmentRecord {
        try requireAuthority(
            authority,
            descriptor: descriptor
        )
        if let existing = try repository.loadAttachment(
            id: descriptor.attachmentUUID
        ) {
            guard exactIdentity(
                existing,
                descriptor: descriptor
            ),
            existing.desiredSHA256 ==
                descriptor.desiredSHA256,
            [
                NetworkStateAttachmentLifecycle.attaching,
                .attached
            ].contains(existing.lifecycleState),
            existing.finalizerState != .quarantined else {
                throw NetworkAttachmentLifecycleError
                    .ownershipConflict(
                        "Existing network attachment state does not match the exact desired UUID ownership."
                    )
            }
            return existing
        }

        let record = NetworkStateAttachmentRecord(
            id: descriptor.attachmentUUID,
            networkUUID: descriptor.network.id,
            projectUUID: descriptor.network.projectUUID,
            resourceUUID:
                descriptor.containerContext.resourceUUID,
            generation: 1,
            providerID:
                descriptor.containerContext.providerID.rawValue,
            providerGeneration: Int64(
                descriptor.containerContext.providerGeneration
            ),
            fencingToken: authority.fencingToken,
            desiredSHA256: descriptor.desiredSHA256,
            observedSHA256: nil,
            lifecycleState: .attaching,
            finalizerState: .pending,
            operationGroupID: authority.operationGroupID,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        return try repository.saveAttachment(
            record,
            authority: authority
        )
    }

    static func resolveCreateObservation(
        record: NetworkStateAttachmentRecord,
        descriptor: NetworkAttachmentCreateDescriptor,
        inventory: RuntimeInventory?,
        trigger: NetworkStateRecoveryTrigger,
        authority: NetworkStateMutationAuthority,
        timestamp: String,
        repository: NetworkStateRepository
    ) throws -> NetworkAttachmentCreateResolution {
        guard exactIdentity(record, descriptor: descriptor),
              record.desiredSHA256 ==
                descriptor.desiredSHA256 else {
            throw NetworkAttachmentLifecycleError
                .ownershipConflict(
                    "Network attachment observation does not match persisted UUID ownership."
                )
        }
        try requireAuthority(
            authority,
            descriptor: descriptor
        )
        let observation = classify(
            record: record,
            descriptor: descriptor,
            inventory: inventory
        )
        let expected = version(record)
        let decision = try repository
            .evaluateAttachmentRecovery(
                id: record.id,
                expected: expected,
                authority: authority,
                trigger: trigger,
                observation: observation
            )

        switch (decision.action, observation) {
        case (
            .verifyAndAdvance,
            .exactOwned(let observedSHA256)
        ):
            let attached = NetworkStateAttachmentRecord(
                id: record.id,
                networkUUID: record.networkUUID,
                projectUUID: record.projectUUID,
                resourceUUID: record.resourceUUID,
                generation: record.generation + 1,
                providerID: authority.providerID,
                providerGeneration:
                    authority.providerGeneration,
                fencingToken: authority.fencingToken,
                desiredSHA256: record.desiredSHA256,
                observedSHA256: observedSHA256,
                lifecycleState: .attached,
                finalizerState: .active,
                operationGroupID:
                    authority.operationGroupID,
                createdAt: record.createdAt,
                updatedAt: timestamp
            )
            return .attached(
                try repository.saveAttachment(
                    attached,
                    replacing: expected,
                    authority: authority
                )
            )
        case (.stable, .exactOwned):
            return .attached(record)
        case (.retryMutation, .absent):
            return .absent
        case (.quarantine, let ambiguous):
            let quarantined = try repository
                .quarantineAttachment(
                    id: record.id,
                    expected: expected,
                    authority: authority,
                    observedSHA256:
                        ambiguous.observedSHA256,
                    updatedAt: timestamp
                )
            return .quarantined(quarantined)
        default:
            throw NetworkAttachmentLifecycleError
                .observationIndeterminate(
                    "Network attachment recovery produced an incompatible state transition."
                )
        }
    }

    static func reverseReleaseOrder(
        projectUUID: String,
        resourceUUID: String? = nil,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        repository: NetworkStateRepository
    ) throws -> [NetworkStateAttachmentRecord] {
        let targets = try repository.reverseTeardownOrder(
            projectUUID: projectUUID
        ).filter {
            $0.kind == .attachment &&
                (resourceUUID == nil ||
                    $0.resourceUUID == resourceUUID)
        }
        return try targets.map { target in
            guard let record = try repository.loadAttachment(
                id: target.id
            ),
            record.projectUUID == projectUUID,
            record.networkUUID == target.networkUUID,
            record.generation == target.generation,
            record.fencingToken == target.fencingToken,
            record.providerID == providerID.rawValue,
            record.providerGeneration ==
                Int64(providerGeneration),
            record.finalizerState != .quarantined else {
                throw NetworkAttachmentLifecycleError
                    .ownershipConflict(
                        "Reverse attachment teardown refused non-exact ownership state."
                    )
            }
            return record
        }
    }

    static func persistReleaseIntent(
        record: NetworkStateAttachmentRecord,
        authority: NetworkStateMutationAuthority,
        timestamp: String,
        repository: NetworkStateRepository
    ) throws -> NetworkStateAttachmentRecord {
        guard record.providerID == authority.providerID,
              record.providerGeneration ==
                authority.providerGeneration,
              record.finalizerState != .quarantined else {
            throw NetworkAttachmentLifecycleError
                .ownershipConflict(
                    "Attachment release intent requires exact provider ownership."
                )
        }
        if record.lifecycleState == .detaching,
           record.operationGroupID ==
            authority.operationGroupID,
           record.fencingToken == authority.fencingToken {
            return record
        }
        guard [
            NetworkStateAttachmentLifecycle.attaching,
            .attached,
        ].contains(record.lifecycleState) else {
            throw NetworkAttachmentLifecycleError
                .ownershipConflict(
                    "Attachment release intent requires an attaching or attached record."
                )
        }
        let detaching = NetworkStateAttachmentRecord(
            id: record.id,
            networkUUID: record.networkUUID,
            projectUUID: record.projectUUID,
            resourceUUID: record.resourceUUID,
            generation: record.generation + 1,
            providerID: authority.providerID,
            providerGeneration:
                authority.providerGeneration,
            fencingToken: authority.fencingToken,
            desiredSHA256: record.desiredSHA256,
            observedSHA256: record.observedSHA256,
            lifecycleState: .detaching,
            finalizerState: .releasing,
            operationGroupID: authority.operationGroupID,
            createdAt: record.createdAt,
            updatedAt: timestamp
        )
        return try repository.saveAttachment(
            detaching,
            replacing: version(record),
            authority: authority
        )
    }

    static func releaseAfterVerifiedAbsence(
        record: NetworkStateAttachmentRecord,
        containerRuntimeIdentifier: String,
        inventory: RuntimeInventory,
        authority: NetworkStateMutationAuthority,
        timestamp: String,
        repository: NetworkStateRepository
    ) throws {
        guard inventory.machine.state == .running,
              RuntimeManagedResourceIdentity.isCurrentIdentifier(
                containerRuntimeIdentifier
              ) else {
            throw NetworkAttachmentLifecycleError
                .observationIndeterminate(
                    "A running structured runtime inventory is required before attachment release."
                )
        }
        let candidates = inventory.containers.filter {
            $0.runtimeID == containerRuntimeIdentifier ||
                $0.name == containerRuntimeIdentifier ||
                $0.ownership?.resourceUUID ==
                    record.resourceUUID
        }
        guard candidates.isEmpty else {
            throw NetworkAttachmentLifecycleError
                .ownershipConflict(
                    "Attachment release requires structured proof that the exact workload is absent."
                )
        }
        guard record.providerID == authority.providerID,
              record.providerGeneration ==
                authority.providerGeneration,
              record.finalizerState != .quarantined else {
            throw NetworkAttachmentLifecycleError
                .ownershipConflict(
                    "Attachment release authority does not match exact persisted ownership."
                )
        }

        var current = record
        if current.lifecycleState != .detaching &&
            current.lifecycleState != .detached
        {
            let detaching = NetworkStateAttachmentRecord(
                id: current.id,
                networkUUID: current.networkUUID,
                projectUUID: current.projectUUID,
                resourceUUID: current.resourceUUID,
                generation: current.generation + 1,
                providerID: authority.providerID,
                providerGeneration:
                    authority.providerGeneration,
                fencingToken: authority.fencingToken,
                desiredSHA256: current.desiredSHA256,
                observedSHA256: current.observedSHA256,
                lifecycleState: .detaching,
                finalizerState: .releasing,
                operationGroupID:
                    authority.operationGroupID,
                createdAt: current.createdAt,
                updatedAt: timestamp
            )
            current = try repository.saveAttachment(
                detaching,
                replacing: version(current),
                authority: authority
            )
        }
        if current.lifecycleState != .detached {
            let detached = NetworkStateAttachmentRecord(
                id: current.id,
                networkUUID: current.networkUUID,
                projectUUID: current.projectUUID,
                resourceUUID: current.resourceUUID,
                generation: current.generation + 1,
                providerID: authority.providerID,
                providerGeneration:
                    authority.providerGeneration,
                fencingToken: authority.fencingToken,
                desiredSHA256: current.desiredSHA256,
                observedSHA256: absenceSHA256(
                    attachmentUUID: current.id,
                    inventory: inventory
                ),
                lifecycleState: .detached,
                finalizerState: .released,
                operationGroupID:
                    authority.operationGroupID,
                createdAt: current.createdAt,
                updatedAt: timestamp
            )
            current = try repository.saveAttachment(
                detached,
                replacing: version(current),
                authority: authority
            )
        }
        _ = try repository.removeDetachedAttachment(
            id: current.id,
            expected: version(current)
        )
    }

    static func classify(
        record: NetworkStateAttachmentRecord,
        descriptor: NetworkAttachmentCreateDescriptor,
        inventory: RuntimeInventory?
    ) -> NetworkStateRecoveryObservation {
        guard let inventory,
              inventory.machine.state == .running else {
            return .indeterminate
        }

        let networkCandidates = inventory.networks.filter {
            $0.runtimeID == descriptor.network.runtimeName ||
                $0.name == descriptor.network.runtimeName ||
                $0.ownership?.resourceUUID ==
                    descriptor.network.id
        }
        guard networkCandidates.count == 1,
              let network = networkCandidates.first else {
            return networkCandidates.isEmpty
                ? .indeterminate
                : .conflictingOwner(
                    observedSHA256:
                        inventory.semanticSHA256
                )
        }
        guard exactNetworkOwnership(
            network,
            record: descriptor.network,
            context: descriptor.containerContext
        ) else {
            return .conflictingOwner(
                observedSHA256: inventory.semanticSHA256
            )
        }

        let containers = inventory.containers.filter {
            $0.runtimeID ==
                descriptor.containerRuntimeIdentifier ||
                $0.name ==
                    descriptor.containerRuntimeIdentifier ||
                $0.ownership?.resourceUUID ==
                    descriptor.containerContext.resourceUUID
        }
        guard containers.count <= 1 else {
            return .conflictingOwner(
                observedSHA256: inventory.semanticSHA256
            )
        }
        guard let container = containers.first else {
            return .absent
        }
        guard exactContainerOwnership(
            container,
            descriptor: descriptor
        ) else {
            return .conflictingOwner(
                observedSHA256: inventory.semanticSHA256
            )
        }
        let attachments = container.networks.filter {
            $0.networkID == descriptor.network.runtimeName ||
                $0.networkID == descriptor.network.id
        }
        guard attachments.count <= 1 else {
            return .conflictingOwner(
                observedSHA256: inventory.semanticSHA256
            )
        }
        guard let attachment = attachments.first else {
            return .absent
        }
        return .exactOwned(
            observedSHA256: observedSHA256(
                record: record,
                network: network,
                container: container,
                attachment: attachment
            )
        )
    }

    private static func requireAuthority(
        _ authority: NetworkStateMutationAuthority,
        descriptor: NetworkAttachmentCreateDescriptor
    ) throws {
        let context = descriptor.containerContext
        guard authority.providerID ==
                context.providerID.rawValue,
              authority.providerGeneration ==
                Int64(context.providerGeneration),
              authority.fencingToken ==
                context.fencingToken,
              authority.plannedCapabilitySHA256 ==
                context.capabilitySHA256,
              authority.currentCapabilitySHA256 ==
                context.capabilitySHA256 else {
            throw NetworkAttachmentLifecycleError
                .ownershipConflict(
                    "Network attachment authority is stale or does not match the container mutation fence."
                )
        }
    }

    private static func exactIdentity(
        _ record: NetworkStateAttachmentRecord,
        descriptor: NetworkAttachmentCreateDescriptor
    ) -> Bool {
        record.id == descriptor.attachmentUUID &&
            record.networkUUID == descriptor.network.id &&
            record.projectUUID ==
                descriptor.network.projectUUID &&
            record.resourceUUID ==
                descriptor.containerContext.resourceUUID &&
            record.providerID ==
                descriptor.containerContext.providerID.rawValue &&
            record.providerGeneration ==
                Int64(
                    descriptor.containerContext.providerGeneration
                )
    }

    private static func exactNetworkOwnership(
        _ observed: RuntimeInventoryNetwork,
        record: NetworkStateResourceRecord,
        context: RuntimeMutationContext
    ) -> Bool {
        guard observed.runtimeID == record.runtimeName ||
                observed.name == record.runtimeName,
              let ownership = observed.ownership else {
            return false
        }
        return ownership.resourceUUID == record.id &&
            ownership.projectUUID == record.projectUUID &&
            ownership.resourceGeneration ==
                Int(record.generation) &&
            ownership.projectGeneration ==
                context.projectGeneration &&
            ownership.providerID == context.providerID &&
            ownership.providerGeneration ==
                context.providerGeneration &&
            ownership.fencingToken == record.fencingToken
    }

    private static func exactContainerOwnership(
        _ observed: RuntimeInventoryContainer,
        descriptor: NetworkAttachmentCreateDescriptor
    ) -> Bool {
        let context = descriptor.containerContext
        guard observed.runtimeID ==
                descriptor.containerRuntimeIdentifier ||
                observed.name ==
                    descriptor.containerRuntimeIdentifier,
              let ownership = observed.ownership else {
            return false
        }
        return ownership.resourceUUID == context.resourceUUID &&
            ownership.projectUUID ==
                context.projectResourceUUID &&
            ownership.resourceGeneration ==
                context.resourceGeneration &&
            ownership.projectGeneration ==
                context.projectGeneration &&
            ownership.providerID == context.providerID &&
            ownership.providerGeneration ==
                context.providerGeneration &&
            ownership.fencingToken == context.fencingToken
    }

    static func desiredSHA256(
        attachmentUUID: String,
        networkUUID: String,
        networkRuntimeIdentifier: String,
        projectUUID: String,
        resourceUUID: String,
        containerRuntimeIdentifier: String,
        aliases: [String]
    ) -> String {
        sha256([
            "schema=1",
            "attachment=\(attachmentUUID)",
            "network=\(networkUUID)",
            "network-runtime=\(networkRuntimeIdentifier)",
            "project=\(projectUUID)",
            "resource=\(resourceUUID)",
            "container-runtime=\(containerRuntimeIdentifier)",
            "aliases=\(aliases.joined(separator: ","))",
        ].joined(separator: "\n"))
    }

    private static func observedSHA256(
        record: NetworkStateAttachmentRecord,
        network: RuntimeInventoryNetwork,
        container: RuntimeInventoryContainer,
        attachment: RuntimeInventoryNetworkAttachment
    ) -> String {
        sha256([
            "schema=1",
            "attachment=\(record.id)",
            "network=\(record.networkUUID)",
            "network-runtime=\(network.runtimeID)",
            "resource=\(record.resourceUUID)",
            "container-runtime=\(container.runtimeID)",
            "interface=\(attachment.interfaceName ?? "")",
            "addresses=\(attachment.addresses.sorted().joined(separator: ","))",
            "gateway=\(attachment.gateway ?? "")",
            "mac=\(attachment.macAddress ?? "")",
        ].joined(separator: "\n"))
    }

    private static func absenceSHA256(
        attachmentUUID: String,
        inventory: RuntimeInventory
    ) -> String {
        sha256(
            "schema=1\nattachment=\(attachmentUUID)\nstate=absent\nmachine=\(inventory.machine.state.rawValue)"
        )
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func version(
        _ record: NetworkStateAttachmentRecord
    ) -> NetworkStateExpectedVersion {
        NetworkStateExpectedVersion(
            generation: record.generation,
            fencingToken: record.fencingToken
        )
    }
}

private extension NetworkStateRecoveryObservation {
    var observedSHA256: String? {
        switch self {
        case .absent, .indeterminate:
            return nil
        case .exactOwned(let observedSHA256):
            return observedSHA256
        case .conflictingOwner(let observedSHA256):
            return observedSHA256
        }
    }
}
