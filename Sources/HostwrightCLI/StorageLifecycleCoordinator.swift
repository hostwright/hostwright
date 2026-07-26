import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightState
import HostwrightStorage

struct StorageLifecycleReconciliationResult: Sendable {
    let volumesByName: [String: StorageStateVolumeRecord]
    let newlyAttachedIDs: [String]
}

struct StorageRuntimeQuiescenceProof: Equatable, Sendable {
    let observationSHA256: String
    let workloadUUIDs: Set<String>

    init(
        observationSHA256: String,
        workloadUUIDs: Set<String>
    ) throws {
        guard observationSHA256.utf8.count == 64,
              observationSHA256.allSatisfy({
                  ("0"..."9").contains($0) ||
                      ("a"..."f").contains($0)
              }),
              workloadUUIDs.allSatisfy(
                  HostwrightResourceUUID.isValid
              ) else {
            throw HostwrightDiagnostic(
                code: .storageConflict,
                message:
                    "Runtime quiescence evidence is malformed; no attachment fence was advanced."
            )
        }
        self.observationSHA256 = observationSHA256
        self.workloadUUIDs = workloadUUIDs
    }
}

struct StorageVolumeOperationIntent: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let action: String
    let name: String
    let volumeID: String
    let projectID: String
    let projectResourceUUID: String
    let projectGeneration: Int
    let providerID: String
    let topologyNodeID: String
    let generation: Int64
    let fencingToken: String
    let capacityBytes: Int64
    let reclaimPolicy: StorageReclaimPolicy
    let accessMode: StorageAccessMode
    let expectedDataPath: String
}

enum StorageLifecycleCoordinator {
    static let topologyNodeID = "local-apple-silicon"

    static func repairRecoverableCreateMetadata(
        observation: LocalStorageObservation,
        store: SQLiteStateStore,
        state: StorageStateRepository
    ) throws -> [String] {
        let decoder = JSONDecoder()
        let groups = try store.operationGroups.loadAll().filter {
            $0.groupKind == "storage-volume" &&
                $0.plannedActionType == "create" &&
                $0.status == .interrupted
        }
        var intentsByVolumeID:
            [String: [(OperationGroupRecord, StorageVolumeOperationIntent)]] =
            [:]
        for group in groups {
            guard let data = group.intentJSONRedacted.data(
                using: .utf8
            ),
            let intent = try? decoder.decode(
                StorageVolumeOperationIntent.self,
                from: data
            ),
            intent.schemaVersion == 1,
            intent.action == "create",
            intent.providerID ==
                LocalStorageProviderContract.providerID,
            intent.generation > 0,
            group.projectID == intent.projectID,
            group.fencingToken == intent.fencingToken else {
                continue
            }
            intentsByVolumeID[
                intent.volumeID,
                default: []
            ].append((group, intent))
        }

        var repaired: [String] = []
        for observed in observation.volumes.sorted(
            by: { $0.volumeID < $1.volumeID }
        ) {
            let prior = try state.loadVolume(id: observed.volumeID)
            guard (prior == nil ||
                    exactDeletedPredecessor(
                        prior!,
                        intentCandidates:
                            intentsByVolumeID[observed.volumeID]
                    )),
                  !observation.ambiguousVolumeIDs.contains(
                      observed.volumeID
                  ),
                  observed.attachments.isEmpty,
                  let candidates =
                    intentsByVolumeID[observed.volumeID],
                  candidates.count == 1,
                  let candidate = candidates.first else {
                continue
            }
            let (storedGroup, intent) = candidate
            guard exactCreateObservation(
                observed,
                matches: intent
            ) else {
                continue
            }
            let group = try store.operationGroups
                .resumeInterrupted(
                    groupID: storedGroup.id,
                    expectedFencingToken:
                        storedGroup.fencingToken,
                    lockOwner: "hostwright-cli",
                    lockExpiresAt:
                        hostwrightTimestampAdding(
                            seconds: 86_400,
                            to: hostwrightTimestamp()
                        ),
                    updatedAt: hostwrightTimestamp()
                )
            let record = StorageStateVolumeRecord(
                id: intent.volumeID,
                projectID: intent.projectID,
                name: intent.name,
                providerID: intent.providerID,
                providerVolumeID: intent.volumeID,
                topologyNodeID: intent.topologyNodeID,
                generation: intent.generation,
                fencingToken: intent.fencingToken,
                capacityBytes: intent.capacityBytes,
                lifecycleState: .available,
                reclaimPolicy: intent.reclaimPolicy,
                accessMode: intent.accessMode,
                operationGroupID: group.id,
                createdAt:
                    prior?.createdAt ?? group.createdAt,
                updatedAt: hostwrightTimestamp()
            )
            try state.saveVolume(
                record,
                replacing: prior.map {
                    StorageStateExpectedVersion(
                        generation: $0.generation,
                        fencingToken: $0.fencingToken
                    )
                }
            )
            try saveQuota(for: record, state: state)
            try checkpoint(
                group,
                name: "provider-observed",
                verification:
                    #"{"metadataRepair":"exact-create-intent","volumeID":"\#(intent.volumeID)"}"#,
                store: store
            )
            try succeed(group, store: store)
            repaired.append(intent.volumeID)
        }
        return repaired.sorted()
    }

    private static func exactDeletedPredecessor(
        _ prior: StorageStateVolumeRecord,
        intentCandidates:
            [(OperationGroupRecord, StorageVolumeOperationIntent)]?
    ) -> Bool {
        guard let candidates = intentCandidates,
              candidates.count == 1,
              let intent = candidates.first?.1 else {
            return false
        }
        return prior.id == intent.volumeID &&
            prior.projectID == intent.projectID &&
            prior.name == intent.name &&
            prior.providerID == intent.providerID &&
            prior.providerVolumeID == intent.volumeID &&
            prior.topologyNodeID == intent.topologyNodeID &&
            prior.lifecycleState == .deleted &&
            prior.generation + 1 == intent.generation
    }

    static func exactCreateObservation(
        _ observed: LocalStorageVolumeObservation,
        matches intent: StorageVolumeOperationIntent
    ) -> Bool {
        observed.volumeID == intent.volumeID &&
            observed.providerID == intent.providerID &&
            observed.name == intent.name &&
            observed.projectID ==
                intent.projectResourceUUID &&
            observed.projectGeneration ==
                intent.projectGeneration &&
            observed.generation == Int(intent.generation) &&
            observed.fencingToken == intent.fencingToken &&
            observed.capacityBytes == intent.capacityBytes &&
            observed.retention ==
                localRetention(intent.reclaimPolicy) &&
            observed.dataPath == intent.expectedDataPath
    }

    static func namedVolumeSources(
        manifest: HostwrightManifest,
        projectResourceUUID: String,
        providerRootURL: URL
    ) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: manifest.volumes.keys.sorted().map {
                name in
                let volumeID = volumeID(
                    projectResourceUUID: projectResourceUUID,
                    name: name
                )
                let path = providerRootURL
                    .appendingPathComponent("volumes", isDirectory: true)
                    .appendingPathComponent(volumeID, isDirectory: true)
                    .appendingPathComponent("data", isDirectory: true)
                    .standardizedFileURL.path
                return (name, path)
            }
        )
    }

    static func reconcileNamedVolumes(
        manifest: HostwrightManifest,
        preparation: LifecycleCommandPreparation,
        compiled: LifecycleCompiledCommand,
        planSHA256: String,
        timeoutSeconds: Int,
        store: SQLiteStateStore,
        environment: CLIEnvironment
    ) async throws -> StorageLifecycleReconciliationResult {
        guard !manifest.volumes.isEmpty else {
            return StorageLifecycleReconciliationResult(
                volumesByName: [:],
                newlyAttachedIDs: []
            )
        }
        guard let projectUUID = UUID(
            uuidString: preparation.projectResourceUUID
        ) else {
            throw diagnostic(
                .storageInvalid,
                "The project storage identity is not a canonical UUID."
            )
        }

        let provider = try await environment.storageProvider()
        let client = try StorageProviderClient(
            provider: provider,
            requestTimeoutMilliseconds:
                Int64(min(timeoutSeconds, 15 * 60)) * 1_000
        )
        let descriptor = try await client.descriptor()
        guard descriptor.providerID ==
                LocalStorageProviderContract.providerID else {
            throw diagnostic(
                .storageUnavailable,
                "Named volumes require the built-in signed hostwright-local provider."
            )
        }
        guard manifest.volumes.values.allSatisfy({
            $0.provider == descriptor.providerID
        }) else {
            throw diagnostic(
                .storageUnavailable,
                "A declared named volume selected a provider that is not available."
            )
        }

        let capabilitySHA256 = try descriptor.canonicalSHA256()
        let observation: LocalStorageObservation = try await client.invoke(
            operation: .observe,
            idempotencyKey: sha256(
                "observe:\(preparation.projectID):\(planSHA256)"
            ),
            payload: LocalStorageObservePayload(),
            result: LocalStorageObservation.self
        )
        guard observation.unmanagedEntries.isEmpty,
              observation.ambiguousVolumeIDs.isEmpty else {
            throw diagnostic(
                .storageConflict,
                "Storage observation contains unmanaged or ambiguous entries; no volume mutation was attempted."
            )
        }

        let state = StorageStateRepository(store: store)
        let existingRecords = try state.loadVolumes(
            projectID: preparation.projectID
        )
        let stateByName = Dictionary(
            uniqueKeysWithValues: existingRecords.map { ($0.name, $0) }
        )
        let providerByID = Dictionary(
            uniqueKeysWithValues: observation.volumes.map {
                ($0.volumeID, $0)
            }
        )
        let providerByName = Dictionary(
            grouping: observation.volumes,
            by: \.name
        )
        let sources = namedVolumeSources(
            manifest: manifest,
            projectResourceUUID: preparation.projectResourceUUID,
            providerRootURL: environment.storageProviderRootURL()
        )
        let providerRootURL = environment.storageProviderRootURL()

        var reconciled: [String: StorageStateVolumeRecord] = [:]
        for name in manifest.volumes.keys.sorted() {
            guard let declaration = manifest.volumes[name],
                  let expectedPath = sources[name] else {
                throw diagnostic(
                    .storageInvalid,
                    "The named-volume plan is incomplete."
                )
            }
            let desiredCapacity = try capacityBytes(
                declaration.capacity
            )
            let desiredVolumeID = volumeID(
                projectResourceUUID: preparation.projectResourceUUID,
                name: name
            )
            let persisted = stateByName[name]
            let deletedPredecessor =
                persisted?.lifecycleState == .deleted
                    ? persisted
                    : nil
            let existing =
                deletedPredecessor == nil
                    ? persisted
                    : nil

            if let deletedPredecessor {
                guard deletedPredecessor.id == desiredVolumeID,
                      deletedPredecessor.providerVolumeID ==
                        desiredVolumeID,
                      deletedPredecessor.providerID ==
                        LocalStorageProviderContract.providerID,
                      deletedPredecessor.projectID ==
                        preparation.projectID,
                      deletedPredecessor.name == name else {
                    throw diagnostic(
                        .storageConflict,
                        "Deleted named-volume state does not match the exact project ownership identity."
                    )
                }
            }

            if let collisions = providerByName[name],
               collisions.contains(where: {
                   $0.volumeID != desiredVolumeID
               }) {
                throw diagnostic(
                    .storageConflict,
                    "Named volume '\(name)' collides with a provider resource that Hostwright does not own."
                )
            }
            if existing == nil, providerByID[desiredVolumeID] != nil {
                throw diagnostic(
                    .storageConflict,
                    "Named volume '\(name)' exists at the provider without matching durable ownership state."
                )
            }

            if let existing {
                try requireOwned(
                    existing,
                    name: name,
                    volumeID: desiredVolumeID,
                    declaration: declaration,
                    projectID: preparation.projectID
                )
                guard let observed = providerByID[desiredVolumeID] else {
                    throw diagnostic(
                        .storagePartialEffect,
                        "Named volume '\(name)' is recorded but absent from the provider; recovery is required."
                    )
                }
                try requireObservation(
                    observed,
                    record: existing,
                    expectedPath: expectedPath,
                    projectResourceUUID:
                        preparation.projectResourceUUID
                )
                if desiredCapacity < existing.capacityBytes {
                    throw diagnostic(
                        .storageInvalid,
                        "Named volume '\(name)' cannot be shrunk."
                    )
                }
                if desiredCapacity == existing.capacityBytes {
                    try saveQuota(for: existing, state: state)
                    reconciled[name] = existing
                    continue
                }
                reconciled[name] = try await expand(
                    existing: existing,
                    declaration: declaration,
                    desiredCapacity: desiredCapacity,
                    expectedPath: expectedPath,
                    projectUUID: projectUUID,
                    projectGeneration: preparation.projectGeneration,
                    planSHA256: planSHA256,
                    capabilitySHA256: capabilitySHA256,
                    providerRootURL: providerRootURL,
                    providerTotalCapacityBytes:
                        observation.totalCapacityBytes,
                    client: client,
                    state: state,
                    store: store
                )
            } else {
                reconciled[name] = try await create(
                    name: name,
                    declaration: declaration,
                    desiredCapacity: desiredCapacity,
                    volumeID: desiredVolumeID,
                    expectedPath: expectedPath,
                    projectID: preparation.projectID,
                    projectUUID: projectUUID,
                    projectGeneration: preparation.projectGeneration,
                    planSHA256: planSHA256,
                    capabilitySHA256: capabilitySHA256,
                    providerRootURL: providerRootURL,
                    providerTotalCapacityBytes:
                        observation.totalCapacityBytes,
                    client: client,
                    state: state,
                    store: store,
                    replacing: deletedPredecessor
                )
            }
        }

        let newlyAttached = try await attachNamedVolumes(
            compiled: compiled,
            sources: sources,
            volumesByName: reconciled,
            projectResourceUUID: preparation.projectResourceUUID,
            projectGeneration: preparation.projectGeneration,
            planSHA256: planSHA256,
            providerRootURL: providerRootURL,
            providerTotalCapacityBytes:
                observation.totalCapacityBytes,
            client: client,
            state: state,
            store: store
        )
        return StorageLifecycleReconciliationResult(
            volumesByName: reconciled,
            newlyAttachedIDs: newlyAttached
        )
    }

    private struct AttachmentSpec {
        let volumeName: String
        let volume: StorageStateVolumeRecord
        let workloadUUID: String
        let sourcePath: String
        let targetPath: String
        let readOnly: Bool

        var orderingKey: String {
            "\(volumeName)|\(workloadUUID)|\(targetPath)"
        }
    }

    private static func attachNamedVolumes(
        compiled: LifecycleCompiledCommand,
        sources: [String: String],
        volumesByName: [String: StorageStateVolumeRecord],
        projectResourceUUID: String,
        projectGeneration: Int,
        planSHA256: String,
        providerRootURL: URL,
        providerTotalCapacityBytes: Int64,
        client: StorageProviderClient,
        state: StorageStateRepository,
        store: SQLiteStateStore
    ) async throws -> [String] {
        let namesBySource = Dictionary(
            uniqueKeysWithValues: sources.map { ($0.value, $0.key) }
        )
        var specsByKey: [String: AttachmentSpec] = [:]
        for key in compiled.desiredServicesByNodeKey.keys.sorted() {
            guard let service = compiled.desiredServicesByNodeKey[key],
                  let node = compiled.plan.nodes.first(where: {
                      $0.key == key
                  }) else {
                continue
            }
            for mount in service.mounts where mount.kind == .volume {
                guard let volumeName = namesBySource[mount.source],
                      let volume = volumesByName[volumeName] else {
                    continue
                }
                let spec = AttachmentSpec(
                    volumeName: volumeName,
                    volume: volume,
                    workloadUUID: node.resourceUUID,
                    sourcePath: mount.source,
                    targetPath: mount.target,
                    readOnly: mount.access == .readOnly
                )
                specsByKey[spec.orderingKey] = spec
            }
        }

        let nodeUUID = HostwrightResourceUUID.legacy(
            kind: "storage-node",
            identifier: topologyNodeID
        )
        var newlyAttached: [String] = []
        for spec in specsByKey.values.sorted(by: {
            $0.orderingKey < $1.orderingKey
        }) {
            let attachmentID = HostwrightResourceUUID.legacy(
                kind: "storage-attachment",
                identifier:
                    "\(spec.volume.id):\(spec.workloadUUID):\(spec.targetPath)"
            )
            let existingState = try state.loadAttachment(
                id: attachmentID
            )
            let currentObservation = try await observeVolume(
                spec.volume.id,
                planSHA256: planSHA256,
                client: client
            )
            if let existingState,
               existingState.checkpoint == .attachedCommitted,
               existingState.lifecycleState == .attached {
                guard providerAttachment(
                    attachmentID,
                    in: currentObservation
                ).map({
                    $0.consumerID == spec.workloadUUID &&
                        $0.generation ==
                            Int(existingState.generation) &&
                        $0.fencingToken ==
                            existingState.fencingToken &&
                        $0.readOnly == existingState.readOnly
                }) == true else {
                    throw diagnostic(
                        .storagePartialEffect,
                        "A durable volume attachment is not confirmed by exact provider observation."
                    )
                }
                continue
            }

            let generation = existingState.map {
                Int($0.generation) +
                    ($0.checkpoint == .detachedCommitted ? 1 : 0)
            } ?? 1
            let group = try acquireAttachmentOperation(
                attachmentID: attachmentID,
                volumeID: spec.volume.id,
                workloadUUID: spec.workloadUUID,
                generation: generation,
                projectID: spec.volume.projectID,
                planSHA256: planSHA256,
                store: store
            )
            let authority = try StorageAttachmentAuthority(
                generation: Int64(generation),
                fencingToken: group.fencingToken
            )
            do {
                try admitCapacityGrowth(
                    action: .attach,
                    additionalBytes: 0,
                    additionalInodes: 0,
                    currentQuotaBytes:
                        spec.volume.capacityBytes,
                    desiredQuotaBytes:
                        spec.volume.capacityBytes,
                    writable: !(
                        spec.readOnly ||
                            spec.volume.accessMode ==
                            .readOnlyMany
                    ),
                    group: group,
                    providerRootURL: providerRootURL,
                    providerTotalCapacityBytes:
                        providerTotalCapacityBytes,
                    state: state,
                    store: store
                )
            } catch {
                try? interrupt(group, store: store)
                throw error
            }
            var ledger = try attachmentLedger(
                records: state.loadAttachments(
                    volumeID: spec.volume.id
                )
            )
            var record: StorageAttachmentRecord
            if let existing = ledger.record(id: attachmentID),
               existing.checkpoint != .detachedCommitted {
                guard existing.authority == authority,
                      existing.nodeUUID == nodeUUID,
                      existing.workloadUUID == spec.workloadUUID else {
                    throw diagnostic(
                        .storageConflict,
                        "An incomplete attachment is owned by a different holder or fence."
                    )
                }
                record = existing
            } else {
                let coordinator = StorageAttachmentCoordinator()
                let intent = StorageAttachmentIntent(
                    attachmentID: attachmentID,
                    volumeID: spec.volume.id,
                    nodeUUID: nodeUUID,
                    workloadUUID: spec.workloadUUID,
                    accessMode:
                        semanticAccess(spec.volume.accessMode),
                    readOnly: spec.readOnly ||
                        spec.volume.accessMode == .readOnlyMany,
                    authority: authority,
                    expectedAuthority: ledger.record(
                        id: attachmentID
                    )?.authority,
                    operationID: group.operationID,
                    idempotencyKey: group.groupIdempotencyKey,
                    leaseDurationMilliseconds: 15 * 60 * 1_000
                )
                let transition = try coordinator.beginAttach(
                    intent,
                    in: ledger
                )
                ledger = transition.ledger
                record = transition.record
                try persistAttachment(
                    record,
                    targetPath: spec.targetPath,
                    stagingPath: spec.sourcePath,
                    topologyNodeID: topologyNodeID,
                    groupID: group.id,
                    state: state
                )
                newlyAttached.append(attachmentID)
            }

            let coordinator = StorageAttachmentCoordinator()
            if record.ambiguousHoldReason != nil {
                let observed = try await observeVolume(
                    spec.volume.id,
                    planSHA256: planSHA256,
                    client: client
                )
                let attached = providerAttachment(
                    attachmentID,
                    in: observed
                ) != nil
                let resolved = try coordinator.resolveAmbiguous(
                    attachmentID: attachmentID,
                    expectedAuthority: authority,
                    providerObservedAttached: attached,
                    providerObservationSHA256:
                        try observationSHA256(observed),
                    in: ledger
                )
                ledger = resolved.ledger
                record = resolved.record
                try persistAttachment(
                    record,
                    targetPath: spec.targetPath,
                    stagingPath: spec.sourcePath,
                    topologyNodeID: topologyNodeID,
                    groupID: group.id,
                    state: state
                )
            }

            if record.checkpoint == .attachIntentPersisted {
                let transition = try coordinator.advance(
                    attachmentID: attachmentID,
                    expectedAuthority: authority,
                    to: .attachFenceAcquired,
                    in: ledger
                )
                ledger = transition.ledger
                record = transition.record
                try persistAttachment(
                    record,
                    targetPath: spec.targetPath,
                    stagingPath: spec.sourcePath,
                    topologyNodeID: topologyNodeID,
                    groupID: group.id,
                    state: state
                )
            }
            if record.checkpoint == .attachFenceAcquired {
                let transition = try coordinator.advance(
                    attachmentID: attachmentID,
                    expectedAuthority: authority,
                    to: .attachProviderEffectRequested,
                    in: ledger
                )
                ledger = transition.ledger
                record = transition.record
                try persistAttachment(
                    record,
                    targetPath: spec.targetPath,
                    stagingPath: spec.sourcePath,
                    topologyNodeID: topologyNodeID,
                    groupID: group.id,
                    state: state
                )
            }
            if record.checkpoint == .attachProviderEffectRequested {
                do {
                    let context = StorageProviderMutationContext(
                        projectUUID: UUID(
                            uuidString: projectResourceUUID
                        )!,
                        projectGeneration: projectGeneration,
                        resourceUUID: UUID(
                            uuidString: spec.volume.id
                        )!,
                        resourceGeneration:
                            Int(spec.volume.generation),
                        attachmentGeneration: generation,
                        fencingToken: UUID(
                            uuidString: record.authority.fencingToken
                        )!
                    )
                    let result: LocalStorageMutationResult =
                        try await client.invoke(
                            operation: .attach,
                            mutationContext: context,
                            idempotencyKey:
                                record.idempotencyKey,
                            payload: LocalStorageAttachPayload(
                                attachmentID: attachmentID,
                                consumerID:
                                    spec.workloadUUID,
                                readOnly: record.readOnly,
                                volumeGeneration:
                                    Int(spec.volume.generation),
                                volumeFencingToken:
                                    spec.volume.fencingToken
                            ),
                            result:
                                LocalStorageMutationResult.self
                        )
                    guard let observed = result.volume,
                          providerAttachment(
                              attachmentID,
                              in: observed
                          ).map({
                              $0.consumerID ==
                                spec.workloadUUID &&
                                $0.generation == generation &&
                                $0.fencingToken ==
                                    record.authority
                                        .fencingToken &&
                                $0.readOnly == record.readOnly
                          }) == true else {
                        throw diagnostic(
                            .storagePartialEffect,
                            "The storage provider did not return exact attachment evidence."
                        )
                    }
                    let transition = try coordinator.advance(
                        attachmentID: attachmentID,
                        expectedAuthority: authority,
                        to: .attachProviderObserved,
                        providerObservationSHA256:
                            try observationSHA256(observed),
                        in: ledger
                    )
                    ledger = transition.ledger
                    record = transition.record
                    try persistAttachment(
                        record,
                        targetPath: spec.targetPath,
                        stagingPath: spec.sourcePath,
                        topologyNodeID: topologyNodeID,
                        groupID: group.id,
                        state: state
                    )
                } catch {
                    let held = try coordinator.advance(
                        attachmentID: attachmentID,
                        expectedAuthority: authority,
                        to: .attachProviderObserved,
                        interruption: .crashed,
                        in: ledger
                    )
                    try persistAttachment(
                        held.record,
                        targetPath: spec.targetPath,
                        stagingPath: spec.sourcePath,
                        topologyNodeID: topologyNodeID,
                        groupID: group.id,
                        state: state
                    )
                    try? interrupt(group, store: store)
                    throw error
                }
            }
            if record.checkpoint == .attachProviderObserved {
                let transition = try coordinator.advance(
                    attachmentID: attachmentID,
                    expectedAuthority: authority,
                    to: .attachedCommitted,
                    in: ledger
                )
                record = transition.record
                try persistAttachment(
                    record,
                    targetPath: spec.targetPath,
                    stagingPath: spec.sourcePath,
                    topologyNodeID: topologyNodeID,
                    groupID: group.id,
                    state: state
                )
            }
            guard record.checkpoint == .attachedCommitted else {
                throw diagnostic(
                    .storagePartialEffect,
                    "Volume attachment stopped at a resumable checkpoint."
                )
            }
            try succeed(group, store: store)
        }
        return newlyAttached.sorted()
    }

    static func detachNamedVolumes(
        preparation: LifecycleCommandPreparation,
        compiled: LifecycleCompiledCommand,
        planSHA256: String,
        timeoutSeconds: Int,
        quiescenceProof: StorageRuntimeQuiescenceProof,
        onlyAttachmentIDs: Set<String>? = nil,
        store: SQLiteStateStore,
        environment: CLIEnvironment
    ) async throws {
        let provider = try await environment.storageProvider()
        let client = try StorageProviderClient(
            provider: provider,
            requestTimeoutMilliseconds:
                Int64(min(timeoutSeconds, 15 * 60)) * 1_000
        )
        let descriptor = try await client.descriptor()
        guard descriptor.providerID ==
                LocalStorageProviderContract.providerID,
              let projectUUID = UUID(
                  uuidString: preparation.projectResourceUUID
              ) else {
            throw diagnostic(
                .storageUnavailable,
                "The signed local storage provider is unavailable."
            )
        }
        let storageState = StorageStateRepository(store: store)
        let workloadIDs = Set(
            compiled.plan.nodes.map(\.resourceUUID)
        )
        for volume in try storageState.loadVolumes(
            projectID: preparation.projectID
        ) {
            let attachments = try storageState.loadAttachments(
                volumeID: volume.id
            )
            for persisted in attachments.sorted(by: {
                $0.id < $1.id
            }) {
                guard persisted.checkpoint != .detachedCommitted,
                      workloadIDs.contains(persisted.workloadUUID),
                      onlyAttachmentIDs?.contains(persisted.id) ??
                        true else {
                    continue
                }
                try await detach(
                    persisted: persisted,
                    volume: volume,
                    projectUUID: projectUUID,
                    projectGeneration:
                        preparation.projectGeneration,
                    planSHA256: planSHA256,
                    quiescenceProof: quiescenceProof,
                    client: client,
                    storageState: storageState,
                    store: store
                )
            }
        }
    }

    static func applyReclaimPolicies(
        manifest: HostwrightManifest,
        preparation: LifecycleCommandPreparation,
        planSHA256: String,
        timeoutSeconds: Int,
        stateDatabasePath: String?,
        output: CLIOutputFormat,
        environment: CLIEnvironment
    ) async throws {
        guard !manifest.volumes.isEmpty else {
            return
        }
        let provider = try await environment.storageProvider()
        let client = try StorageProviderClient(
            provider: provider,
            requestTimeoutMilliseconds:
                Int64(min(timeoutSeconds, 15 * 60)) * 1_000
        )
        let descriptor = try await client.descriptor()
        guard descriptor.providerID ==
                LocalStorageProviderContract.providerID else {
            throw diagnostic(
                .storageUnavailable,
                "Named-volume reclaim requires the signed local storage provider."
            )
        }
        let volumeIDs = manifest.volumes.keys.sorted().map {
            volumeID(
                projectResourceUUID:
                    preparation.projectResourceUUID,
                name: $0
            )
        }
        _ = try await StorageReclaimCommandCoordinator(
            options: StorageCLIOptions(
                action: .list(projectID: preparation.projectID),
                stateDatabasePath: stateDatabasePath,
                timeoutSeconds: timeoutSeconds,
                output: output
            ),
            environment: environment
        ).applyPolicies(
            volumeIDs: volumeIDs,
            authorizedLifecyclePlanSHA256: planSHA256,
            client: client
        )
    }

    private static func detach(
        persisted: StorageStateAttachmentRecord,
        volume: StorageStateVolumeRecord,
        projectUUID: UUID,
        projectGeneration: Int,
        planSHA256: String,
        quiescenceProof: StorageRuntimeQuiescenceProof,
        client: StorageProviderClient,
        storageState: StorageStateRepository,
        store: SQLiteStateStore
    ) async throws {
        guard let stagingPath = persisted.stagingPath else {
            throw diagnostic(
                .storageInvalid,
                "The attachment is missing its exact staging path."
            )
        }
        var ledger = try attachmentLedger(
            records: storageState.loadAttachments(
                volumeID: volume.id
            )
        )
        guard let previous = ledger.record(id: persisted.id) else {
            throw diagnostic(
                .storageConflict,
                "The exact attachment disappeared before detach."
            )
        }
        let generation = Int(previous.authority.generation + 1)
        let group = try acquireDetachOperation(
            attachmentID: persisted.id,
            volumeID: volume.id,
            workloadUUID: persisted.workloadUUID,
            generation: generation,
            projectID: volume.projectID,
            planSHA256: planSHA256,
            store: store
        )
        guard quiescenceProof.workloadUUIDs.contains(
            persisted.workloadUUID
        ) else {
            try? interrupt(group, store: store)
            throw diagnostic(
                .storageConflict,
                "The exact workload holder was not proven quiesced; no attachment fence was advanced."
            )
        }
        try checkpoint(
            group,
            name: "runtime-holder-quiesced",
            verification:
                #"{"runtimeObservationSHA256":"\#(quiescenceProof.observationSHA256)","workloadUUID":"\#(persisted.workloadUUID)"}"#,
            store: store
        )
        let replacement = try StorageAttachmentAuthority(
            generation: Int64(generation),
            fencingToken: group.fencingToken
        )
        let nowMilliseconds = Int64(
            Date().timeIntervalSince1970 * 1_000
        )
        let coordinator = StorageAttachmentCoordinator(
            nowUnixMilliseconds: nowMilliseconds
        )
        let authorizationExpiry = nowMilliseconds + 60_000
        let needsForce = previous.leaseStatus(
            atUnixMilliseconds: nowMilliseconds
        ) != .active
        let intent = StorageDetachIntent(
            attachmentID: persisted.id,
            holderNodeUUID: persisted.nodeUUID,
            holderWorkloadUUID: persisted.workloadUUID,
            expectedAuthority: previous.authority,
            replacementAuthority: replacement,
            operationID: group.operationID,
            idempotencyKey: group.groupIdempotencyKey,
            leaseDurationMilliseconds: 15 * 60 * 1_000,
            forceAuthorization: needsForce
                ? coordinator.forceDetachAuthorization(
                    for: previous,
                    validUntilUnixMilliseconds:
                        authorizationExpiry
                )
                : nil,
            forceAuthorizationExpiresAtUnixMilliseconds:
                needsForce ? authorizationExpiry : nil
        )
        var record: StorageAttachmentRecord
        if previous.checkpoint == .attachedCommitted {
            let transition = try coordinator.beginDetach(
                intent,
                in: ledger
            )
            ledger = transition.ledger
            record = transition.record
            try persistAttachment(
                record,
                targetPath: persisted.path,
                stagingPath: stagingPath,
                topologyNodeID: persisted.nodeID,
                groupID: group.id,
                state: storageState
            )
        } else if previous.checkpoint.isAttach {
            throw diagnostic(
                .storagePartialEffect,
                "An incomplete attach must be recovered before detach."
            )
        } else {
            guard previous.authority == replacement,
                  previous.operationID == group.operationID else {
                throw diagnostic(
                    .storageConflict,
                    "An incomplete detach has different authority."
                )
            }
            record = previous
        }

        if record.ambiguousHoldReason != nil {
            let observed = try await observeVolume(
                volume.id,
                planSHA256: planSHA256,
                client: client
            )
            let stillAttached = providerAttachment(
                persisted.id,
                in: observed
            ) != nil
            let resolved = try coordinator.resolveAmbiguous(
                attachmentID: persisted.id,
                expectedAuthority: replacement,
                providerObservedAttached: stillAttached,
                providerObservationSHA256:
                    try observationSHA256(observed),
                in: ledger
            )
            ledger = resolved.ledger
            record = resolved.record
            try persistAttachment(
                record,
                targetPath: persisted.path,
                stagingPath: stagingPath,
                topologyNodeID: persisted.nodeID,
                groupID: group.id,
                state: storageState
            )
        }
        if record.checkpoint == .detachIntentPersisted {
            let transition = try coordinator.advance(
                attachmentID: persisted.id,
                expectedAuthority: replacement,
                to: .detachFenceAcquired,
                in: ledger
            )
            ledger = transition.ledger
            record = transition.record
            try persistAttachment(
                record,
                targetPath: persisted.path,
                stagingPath: stagingPath,
                topologyNodeID: persisted.nodeID,
                groupID: group.id,
                state: storageState
            )
        }
        if record.checkpoint == .detachFenceAcquired {
            let transition = try coordinator.advance(
                attachmentID: persisted.id,
                expectedAuthority: replacement,
                to: .detachProviderEffectRequested,
                in: ledger
            )
            ledger = transition.ledger
            record = transition.record
            try persistAttachment(
                record,
                targetPath: persisted.path,
                stagingPath: stagingPath,
                topologyNodeID: persisted.nodeID,
                groupID: group.id,
                state: storageState
            )
        }
        if record.checkpoint ==
            .detachProviderEffectRequested {
            do {
                let context = StorageProviderMutationContext(
                    projectUUID: projectUUID,
                    projectGeneration: projectGeneration,
                    resourceUUID: UUID(
                        uuidString: volume.id
                    )!,
                    resourceGeneration: Int(volume.generation),
                    attachmentGeneration: generation,
                    fencingToken: UUID(
                        uuidString: replacement.fencingToken
                    )!
                )
                let result: LocalStorageMutationResult =
                    try await client.invoke(
                        operation: .detach,
                        mutationContext: context,
                        idempotencyKey:
                            group.groupIdempotencyKey,
                        payload: LocalStorageDetachPayload(
                            attachmentID: persisted.id,
                            volumeGeneration:
                                Int(volume.generation),
                            volumeFencingToken:
                                volume.fencingToken,
                            expectedAttachmentGeneration:
                                Int(previous.authority.generation),
                            expectedAttachmentFencingToken:
                                previous.authority.fencingToken
                        ),
                        result: LocalStorageMutationResult.self
                    )
                guard let observed = result.volume,
                      providerAttachment(
                          persisted.id,
                          in: observed
                      ) == nil else {
                    throw diagnostic(
                        .storagePartialEffect,
                        "The provider did not prove attachment removal."
                    )
                }
                let transition = try coordinator.advance(
                    attachmentID: persisted.id,
                    expectedAuthority: replacement,
                    to: .detachProviderAbsentObserved,
                    providerObservationSHA256:
                        try observationSHA256(observed),
                    in: ledger
                )
                ledger = transition.ledger
                record = transition.record
                try persistAttachment(
                    record,
                    targetPath: persisted.path,
                    stagingPath: stagingPath,
                    topologyNodeID: persisted.nodeID,
                    groupID: group.id,
                    state: storageState
                )
            } catch {
                let held = try coordinator.advance(
                    attachmentID: persisted.id,
                    expectedAuthority: replacement,
                    to: .detachProviderAbsentObserved,
                    interruption: .crashed,
                    in: ledger
                )
                try persistAttachment(
                    held.record,
                    targetPath: persisted.path,
                    stagingPath: stagingPath,
                    topologyNodeID: persisted.nodeID,
                    groupID: group.id,
                    state: storageState
                )
                try? interrupt(group, store: store)
                throw error
            }
        }
        if record.checkpoint ==
            .detachProviderAbsentObserved {
            let transition = try coordinator.advance(
                attachmentID: persisted.id,
                expectedAuthority: replacement,
                to: .detachedCommitted,
                in: ledger
            )
            record = transition.record
            try persistAttachment(
                record,
                targetPath: persisted.path,
                stagingPath: stagingPath,
                topologyNodeID: persisted.nodeID,
                groupID: group.id,
                state: storageState
            )
        }
        guard record.checkpoint == .detachedCommitted else {
            throw diagnostic(
                .storagePartialEffect,
                "Volume detach stopped at a resumable checkpoint."
            )
        }
        try succeed(group, store: store)
    }

    private static func observeVolume(
        _ volumeID: String,
        planSHA256: String,
        client: StorageProviderClient
    ) async throws -> LocalStorageVolumeObservation {
        let observation: LocalStorageObservation =
            try await client.invoke(
                operation: .observe,
                idempotencyKey:
                    sha256("observe:\(planSHA256):\(volumeID)"),
                payload: LocalStorageObservePayload(
                    volumeID: volumeID
                ),
                result: LocalStorageObservation.self
            )
        guard observation.volumes.count == 1,
              let volume = observation.volumes.first,
              volume.volumeID == volumeID,
              observation.unmanagedEntries.isEmpty,
              observation.ambiguousVolumeIDs.isEmpty else {
            throw diagnostic(
                .storageConflict,
                "Exact volume observation is unavailable."
            )
        }
        return volume
    }

    private static func providerAttachment(
        _ attachmentID: String,
        in observation: LocalStorageVolumeObservation
    ) -> LocalStorageAttachmentObservation? {
        observation.attachments.first {
            $0.attachmentID == attachmentID
        }
    }

    private static func attachmentLedger(
        records: [StorageStateAttachmentRecord]
    ) throws -> StorageAttachmentLedger {
        try StorageAttachmentLedger(
            records: records.map {
                try StorageAttachmentRecord(
                    id: $0.id,
                    volumeID: $0.volumeID,
                    nodeUUID: $0.nodeUUID,
                    workloadUUID: $0.workloadUUID,
                    accessMode: semanticAccess($0.accessMode),
                    readOnly: $0.readOnly,
                    authority: StorageAttachmentAuthority(
                        generation: $0.generation,
                        fencingToken: $0.fencingToken
                    ),
                    operationID: $0.operationID,
                    idempotencyKey: $0.idempotencyKey,
                    checkpoint: $0.checkpoint,
                    leaseRenewedAtUnixMilliseconds:
                        unixMilliseconds($0.leaseRenewedAt),
                    leaseExpiresAtUnixMilliseconds:
                        unixMilliseconds($0.leaseExpiresAt),
                    providerObservationSHA256:
                        $0.providerObservationSHA256,
                    forceDetachAuthorizationSHA256:
                        $0.forceDetachAuthorizationSHA256,
                    ambiguousHoldReason:
                        $0.ambiguousHoldReasonRedacted
                )
            }
        )
    }

    private static func persistAttachment(
        _ record: StorageAttachmentRecord,
        targetPath: String,
        stagingPath: String,
        topologyNodeID: String,
        groupID: String,
        state: StorageStateRepository
    ) throws {
        let existing = try state.loadAttachment(id: record.id)
        let createdAt = existing?.createdAt ?? hostwrightTimestamp()
        let updatedAt = timestamp(
            max(
                Int64(Date().timeIntervalSince1970 * 1_000),
                record.leaseRenewedAtUnixMilliseconds
            )
        )
        let normalizedStagingPath = URL(
            fileURLWithPath: stagingPath
        ).standardizedFileURL.path
        let persisted = StorageStateAttachmentRecord(
            id: record.id,
            volumeID: record.volumeID,
            nodeID: topologyNodeID,
            nodeUUID: record.nodeUUID,
            workloadUUID: record.workloadUUID,
            kind: .publish,
            path: targetPath,
            stagingPath: normalizedStagingPath,
            accessMode: stateAccess(record.accessMode),
            readOnly: record.readOnly,
            generation: record.authority.generation,
            fencingToken: record.authority.fencingToken,
            lifecycleState: record.lifecycleState,
            checkpoint: record.checkpoint,
            leaseRenewedAt: timestamp(
                record.leaseRenewedAtUnixMilliseconds
            ),
            leaseExpiresAt: timestamp(
                record.leaseExpiresAtUnixMilliseconds
            ),
            operationID: record.operationID,
            idempotencyKey: record.idempotencyKey,
            providerObservationSHA256:
                record.providerObservationSHA256,
            forceDetachAuthorizationSHA256:
                record.forceDetachAuthorizationSHA256,
            ambiguousHoldReasonRedacted:
                record.ambiguousHoldReason,
            operationGroupID: groupID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        try state.saveAttachment(
            persisted,
            replacing: existing.map {
                StorageStateExpectedVersion(
                    generation: $0.generation,
                    fencingToken: $0.fencingToken
                )
            }
        )
    }

    private static func acquireAttachmentOperation(
        attachmentID: String,
        volumeID: String,
        workloadUUID: String,
        generation: Int,
        projectID: String,
        planSHA256: String,
        action: String = "attach",
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        let id = HostwrightResourceUUID.legacy(
            kind: "storage-attachment-operation",
            identifier:
                "\(planSHA256):\(action):\(attachmentID):\(generation)"
        )
        let fence = HostwrightResourceUUID.legacy(
            kind: "storage-attachment-fence",
            identifier: id
        )
        let now = hostwrightTimestamp()
        let group = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "storage-attachment",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: action,
            status: .active,
            groupIdempotencyKey: sha256(
                "\(action):\(attachmentID):\(generation):\(planSHA256)"
            ),
            planHash: planSHA256,
            checkpoint: "attach-intent-persisted",
            lockOwner: "hostwright-cli",
            lockExpiresAt: hostwrightTimestampAdding(
                seconds: 86_400,
                to: now
            ),
            rollbackAvailable: true,
            manualRecoveryHintRedacted:
                "Observe the exact attachment before resuming.",
            createdAt: now,
            updatedAt: now,
            metadataJSONRedacted: #"{"resource":"attachment"}"#,
            fencingToken: fence,
            intentJSONRedacted:
                #"{"attachmentID":"\#(attachmentID)","volumeID":"\#(volumeID)","workloadUUID":"\#(workloadUUID)"}"#,
            compensationJSONRedacted:
                action == "attach"
                    ? #"["detach-created-attachment"]"#
                    : #"["restore-detached-attachment"]"#,
            verificationJSONRedacted: "{}"
        )
        if let existing = try store.operationGroups.load(id: id) {
            guard existing.planHash == planSHA256,
                  existing.fencingToken == fence else {
                throw diagnostic(
                    .storageConflict,
                    "A prior attachment operation has different authority."
                )
            }
            switch existing.status {
            case .active:
                return existing
            case .interrupted:
                return try store.operationGroups.resumeInterrupted(
                    groupID: id,
                    expectedFencingToken: fence,
                    lockOwner: "hostwright-cli",
                    lockExpiresAt: group.lockExpiresAt,
                    updatedAt: now
                )
            case .succeeded, .failed:
                throw diagnostic(
                    .storagePartialEffect,
                    "A terminal attachment operation is missing committed state."
                )
            }
        }
        let acquired = try store.operationGroups.acquire(
            group,
            currentTimestamp: now
        )
        guard let value = acquired.acquired else {
            throw diagnostic(
                .storageConflict,
                "Another active operation owns the project storage fence."
            )
        }
        return value
    }

    private static func acquireDetachOperation(
        attachmentID: String,
        volumeID: String,
        workloadUUID: String,
        generation: Int,
        projectID: String,
        planSHA256: String,
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        try acquireAttachmentOperation(
            attachmentID: attachmentID,
            volumeID: volumeID,
            workloadUUID: workloadUUID,
            generation: generation,
            projectID: projectID,
            planSHA256: planSHA256,
            action: "detach",
            store: store
        )
    }

    private static func observationSHA256<T: Encodable>(
        _ value: T
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return SHA256.hash(data: try encoder.encode(value))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func unixMilliseconds(
        _ value: String
    ) throws -> Int64 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let date = formatter.date(from: value) ??
            ISO8601DateFormatter().date(from: value)
        guard let date else {
            throw diagnostic(
                .storageInvalid,
                "Attachment lease timestamp is invalid."
            )
        }
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
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

    private static func create(
        name: String,
        declaration: HostwrightVolumeDeclaration,
        desiredCapacity: Int64,
        volumeID: String,
        expectedPath: String,
        projectID: String,
        projectUUID: UUID,
        projectGeneration: Int,
        planSHA256: String,
        capabilitySHA256: String,
        providerRootURL: URL,
        providerTotalCapacityBytes: Int64,
        client: StorageProviderClient,
        state: StorageStateRepository,
        store: SQLiteStateStore,
        replacing predecessor:
            StorageStateVolumeRecord? = nil
    ) async throws -> StorageStateVolumeRecord {
        let generation =
            Int(predecessor?.generation ?? 0) + 1
        let group = try acquireOperation(
            action: "create",
            name: name,
            volumeID: volumeID,
            generation: generation,
            projectID: projectID,
            projectUUID: projectUUID,
            projectGeneration: projectGeneration,
            declaration: declaration,
            capacityBytes: desiredCapacity,
            expectedDataPath: expectedPath,
            planSHA256: planSHA256,
            store: store
        )
        do {
            try admitCapacityGrowth(
                action: .create,
                additionalBytes: desiredCapacity,
                additionalInodes: 1,
                currentQuotaBytes: 0,
                desiredQuotaBytes: desiredCapacity,
                group: group,
                providerRootURL: providerRootURL,
                providerTotalCapacityBytes:
                    providerTotalCapacityBytes,
                state: state,
                store: store
            )
        } catch {
            try? interrupt(group, store: store)
            throw error
        }
        let context = StorageProviderMutationContext(
            projectUUID: projectUUID,
            projectGeneration: projectGeneration,
            resourceUUID: UUID(uuidString: volumeID)!,
            resourceGeneration: generation,
            fencingToken: UUID(uuidString: group.fencingToken)!
        )
        let result: LocalStorageMutationResult
        do {
            try checkpoint(
                group,
                name: "provider-effect-requested",
                verification: "{}",
                store: store
            )
            result = try await client.invoke(
                operation: .create,
                mutationContext: context,
                idempotencyKey: group.groupIdempotencyKey,
                payload: LocalStorageCreatePayload(
                    name: name,
                    capacityBytes: desiredCapacity,
                    retention: localRetention(declaration.reclaimPolicy)
                ),
                result: LocalStorageMutationResult.self
            )
        } catch {
            try interrupt(group, store: store)
            throw error
        }
        guard let observed = result.volume else {
            try interrupt(group, store: store)
            throw diagnostic(
                .storagePartialEffect,
                "The storage provider did not return exact create evidence."
            )
        }
        let record = StorageStateVolumeRecord(
            id: volumeID,
            projectID: projectID,
            name: name,
            providerID: LocalStorageProviderContract.providerID,
            providerVolumeID: volumeID,
            topologyNodeID: topologyNodeID,
            generation: Int64(generation),
            fencingToken: group.fencingToken,
            capacityBytes: desiredCapacity,
            lifecycleState: .available,
            reclaimPolicy: stateReclaim(declaration.reclaimPolicy),
            accessMode: stateAccess(declaration.accessMode),
            operationGroupID: group.id,
            createdAt:
                predecessor?.createdAt ?? group.createdAt,
            updatedAt: hostwrightTimestamp()
        )
        try requireObservation(
            observed,
            record: record,
            expectedPath: expectedPath,
            projectResourceUUID:
                projectUUID.uuidString.lowercased()
        )
        try checkpoint(
            group,
            name: "provider-observed",
            verification:
                #"{"capabilitySHA256":"\#(capabilitySHA256)","volumeID":"\#(volumeID)"}"#,
            store: store
        )
        do {
            try state.saveVolume(
                record,
                replacing: predecessor.map {
                    StorageStateExpectedVersion(
                        generation: $0.generation,
                        fencingToken: $0.fencingToken
                    )
                }
            )
            try saveQuota(for: record, state: state)
            try succeed(group, store: store)
            return record
        } catch {
            try? interrupt(group, store: store)
            throw error
        }
    }

    private static func expand(
        existing: StorageStateVolumeRecord,
        declaration: HostwrightVolumeDeclaration,
        desiredCapacity: Int64,
        expectedPath: String,
        projectUUID: UUID,
        projectGeneration: Int,
        planSHA256: String,
        capabilitySHA256: String,
        providerRootURL: URL,
        providerTotalCapacityBytes: Int64,
        client: StorageProviderClient,
        state: StorageStateRepository,
        store: SQLiteStateStore
    ) async throws -> StorageStateVolumeRecord {
        let generation = Int(existing.generation + 1)
        let group = try acquireOperation(
            action: "expand",
            name: existing.name,
            volumeID: existing.id,
            generation: generation,
            projectID: existing.projectID,
            projectUUID: projectUUID,
            projectGeneration: projectGeneration,
            declaration: declaration,
            capacityBytes: desiredCapacity,
            expectedDataPath: expectedPath,
            planSHA256: planSHA256,
            store: store
        )
        do {
            try admitCapacityGrowth(
                action: .expand,
                additionalBytes:
                    desiredCapacity - existing.capacityBytes,
                additionalInodes: 0,
                currentQuotaBytes: existing.capacityBytes,
                desiredQuotaBytes: desiredCapacity,
                group: group,
                providerRootURL: providerRootURL,
                providerTotalCapacityBytes:
                    providerTotalCapacityBytes,
                state: state,
                store: store
            )
        } catch {
            try? interrupt(group, store: store)
            throw error
        }
        let context = StorageProviderMutationContext(
            projectUUID: projectUUID,
            projectGeneration: projectGeneration,
            resourceUUID: UUID(uuidString: existing.id)!,
            resourceGeneration: generation,
            fencingToken: UUID(uuidString: group.fencingToken)!
        )
        let result: LocalStorageMutationResult
        do {
            try checkpoint(
                group,
                name: "provider-effect-requested",
                verification: "{}",
                store: store
            )
            result = try await client.invoke(
                operation: .expand,
                mutationContext: context,
                idempotencyKey: group.groupIdempotencyKey,
                payload: LocalStorageExpandPayload(
                    capacityBytes: desiredCapacity
                ),
                result: LocalStorageMutationResult.self
            )
        } catch {
            try interrupt(group, store: store)
            throw error
        }
        guard let observed = result.volume else {
            try interrupt(group, store: store)
            throw diagnostic(
                .storagePartialEffect,
                "The storage provider did not return exact expansion evidence."
            )
        }
        let timestamp = hostwrightTimestamp()
        let record = StorageStateVolumeRecord(
            id: existing.id,
            projectID: existing.projectID,
            name: existing.name,
            providerID: existing.providerID,
            providerVolumeID: existing.providerVolumeID,
            topologyNodeID: existing.topologyNodeID,
            generation: Int64(generation),
            fencingToken: group.fencingToken,
            capacityBytes: desiredCapacity,
            lifecycleState: .available,
            reclaimPolicy: stateReclaim(declaration.reclaimPolicy),
            accessMode: stateAccess(declaration.accessMode),
            sourceKind: existing.sourceKind,
            sourceID: existing.sourceID,
            operationGroupID: group.id,
            createdAt: existing.createdAt,
            updatedAt: timestamp
        )
        try requireObservation(
            observed,
            record: record,
            expectedPath: expectedPath,
            projectResourceUUID:
                projectUUID.uuidString.lowercased()
        )
        try checkpoint(
            group,
            name: "provider-observed",
            verification:
                #"{"capabilitySHA256":"\#(capabilitySHA256)","volumeID":"\#(existing.id)"}"#,
            store: store
        )
        do {
            try state.saveVolume(
                record,
                replacing: StorageStateExpectedVersion(
                    generation: existing.generation,
                    fencingToken: existing.fencingToken
                )
            )
            try saveQuota(for: record, state: state)
            try succeed(group, store: store)
            return record
        } catch {
            try? interrupt(group, store: store)
            throw error
        }
    }

    private static func admitCapacityGrowth(
        action: StorageCapacityAction,
        additionalBytes: Int64,
        additionalInodes: Int64,
        currentQuotaBytes: Int64,
        desiredQuotaBytes: Int64,
        writable: Bool = true,
        group: OperationGroupRecord,
        providerRootURL: URL,
        providerTotalCapacityBytes: Int64,
        state: StorageStateRepository,
        store: SQLiteStateStore
    ) throws {
        let existingAdmissions = try state.loadCapacityAdmissions(
            operationID: group.operationID
        )
        if let admitted = existingAdmissions.last,
           admitted.result.disposition == .admit {
            guard admitted.action == action,
                  admitted.additionalBytes == additionalBytes,
                  admitted.additionalInodes == additionalInodes else {
                throw diagnostic(
                    .storageConflict,
                    "Persisted capacity admission does not match the current storage mutation."
                )
            }
            return
        }
        let attempt = existingAdmissions.count + 1
        guard attempt <= StorageCapacityLimits.maximumRetryAttempts else {
            throw diagnostic(
                .storageUnavailable,
                "Storage capacity admission exhausted its bounded retry attempts."
            )
        }

        let nowMilliseconds = Int64(
            Date().timeIntervalSince1970 * 1_000
        )
        let allocatedBytes = try state.allocatedCapacityBytes(
            topologyNodeID: topologyNodeID
        )
        let allocatedInodes = Int64(
            try state.loadVolumes(
                topologyNodeID: topologyNodeID
            ).filter {
                $0.lifecycleState != .deleted
            }.count
        )
        let prior = try state.latestCapacitySample(
            providerID: LocalStorageProviderContract.providerID,
            topologyNodeID: topologyNodeID
        )
        let quotaCapability = try StorageQuotaCapability(
            mode: .logical
        )
        let sampleID = HostwrightResourceUUID.legacy(
            kind: "storage-capacity-sample",
            identifier: "\(group.id):\(attempt)"
        )
        let filesystemSample = try StorageCapacityProbe().sample(
            path: providerRootURL.standardizedFileURL.path,
            id: sampleID,
            providerID: LocalStorageProviderContract.providerID,
            topologyNodeID: topologyNodeID,
            requestedBytes: 0,
            reservedBytes: 0,
            reclaimableBytes: 0,
            requestedInodes: 0,
            reservedInodes: 0,
            reclaimableInodes: 0,
            quotaCapability: quotaCapability,
            capturedAtUnixMilliseconds: nowMilliseconds,
            lifetimeMilliseconds: 60_000
        )
        let effectiveTotalBytes = min(
            providerTotalCapacityBytes,
            filesystemSample.totalBytes
        )
        let effectiveAvailableBytes = min(
            effectiveTotalBytes,
            filesystemSample.availableBytes
        )
        let sample = try StorageCapacitySample(
            id: sampleID,
            providerID: LocalStorageProviderContract.providerID,
            topologyNodeID: topologyNodeID,
            source: .reconciledState,
            requestedBytes: allocatedBytes,
            reservedBytes: allocatedBytes,
            usedBytes:
                effectiveTotalBytes - effectiveAvailableBytes,
            reclaimableBytes: 0,
            availableBytes: effectiveAvailableBytes,
            totalBytes: effectiveTotalBytes,
            requestedInodes: allocatedInodes,
            reservedInodes: allocatedInodes,
            usedInodes: filesystemSample.usedInodes,
            reclaimableInodes: 0,
            availableInodes: filesystemSample.availableInodes,
            totalInodes: filesystemSample.totalInodes,
            quotaCapability: quotaCapability,
            capturedAtUnixMilliseconds: nowMilliseconds,
            validUntilUnixMilliseconds:
                nowMilliseconds + 60_000
        )
        let policy = StorageCapacityPolicy()
        let request = try StorageCapacityAdmissionRequest(
            operationID: group.operationID,
            idempotencyKey: group.groupIdempotencyKey,
            action: action,
            additionalBytes: additionalBytes,
            additionalInodes: additionalInodes,
            writable: writable,
            quotaUsedBytes: currentQuotaBytes,
            quotaLimitBytes: desiredQuotaBytes,
            attempt: attempt
        )
        let result = policy.evaluate(
            request,
            sample: sample,
            previousPressure:
                prior?.pressureLevel ?? .normal,
            atUnixMilliseconds: nowMilliseconds
        )
        let timestamp = hostwrightTimestamp()
        try state.saveCapacitySample(
            StorageStateCapacitySampleRecord(
                sample: sample,
                pressureLevel: result.pressure,
                fencingToken: group.fencingToken,
                operationGroupID: group.id,
                createdAt: timestamp
            )
        )
        try state.saveCapacityAdmission(
            StorageStateCapacityAdmissionRecord(
                id: HostwrightResourceUUID.legacy(
                    kind: "storage-capacity-admission",
                    identifier: "\(group.id):\(attempt)"
                ),
                sampleID: sample.id,
                sampleDigestSHA256: sample.digestSHA256,
                action: action,
                additionalBytes: additionalBytes,
                additionalInodes: additionalInodes,
                writable: writable,
                result: result,
                maximumAttempts:
                    StorageCapacityLimits.maximumRetryAttempts,
                fencingToken: group.fencingToken,
                operationGroupID: group.id,
                createdAt: timestamp
            )
        )
        guard result.disposition == .admit else {
            if result.retryDisposition == .never {
                try store.operationGroups.finish(
                    groupID: group.id,
                    status: .failed,
                    checkpoint: "capacity-rejected",
                    manualRecoveryHintRedacted:
                        "Reduce the requested storage or free verified owned capacity.",
                    updatedAt: hostwrightTimestamp(),
                    metadataJSONRedacted:
                        #"{"result":"capacity-rejected"}"#
                )
            }
            throw diagnostic(
                .storageUnavailable,
                "Storage capacity admission refused the mutation: \(result.reason.rawValue)."
            )
        }
        try checkpoint(
            group,
            name: "capacity-admitted",
            verification:
                #"{"pressure":"\#(result.pressure.rawValue)","sampleSHA256":"\#(sample.digestSHA256)"}"#,
            store: store
        )
    }

    private static func saveQuota(
        for volume: StorageStateVolumeRecord,
        state: StorageStateRepository
    ) throws {
        let quotaID = HostwrightResourceUUID.legacy(
            kind: "storage-quota",
            identifier: volume.id
        )
        let existing = try state.loadQuota(id: quotaID)
        if let existing,
           existing.resourceID == volume.id,
           existing.providerID == volume.providerID,
           existing.byteLimit == volume.capacityBytes,
           existing.inodeLimit == nil,
           existing.enforcementMode == .logical,
           existing.generation == volume.generation,
           existing.fencingToken == volume.fencingToken,
           existing.lifecycleState == .active {
            return
        }
        if let existing,
           existing.generation >= volume.generation {
            throw diagnostic(
                .storageConflict,
                "The persisted quota has newer or conflicting volume authority."
            )
        }
        let timestamp = hostwrightTimestamp()
        let record = StorageStateQuotaRecord(
            id: quotaID,
            resourceID: volume.id,
            providerID: volume.providerID,
            byteLimit: volume.capacityBytes,
            inodeLimit: nil,
            enforcementMode: .logical,
            enforcementEvidenceSHA256: nil,
            generation: volume.generation,
            fencingToken: volume.fencingToken,
            lifecycleState: .active,
            retryAttempt: 1,
            recoveryCheckpoint: .admitted,
            operationID: volume.operationGroupID,
            idempotencyKey: sha256(
                "quota:\(volume.id):\(volume.generation):\(volume.capacityBytes)"
            ),
            operationGroupID: volume.operationGroupID,
            createdAt: existing?.createdAt ?? volume.createdAt,
            updatedAt: timestamp
        )
        try state.saveQuota(
            record,
            replacing: existing.map {
                StorageStateExpectedVersion(
                    generation: $0.generation,
                    fencingToken: $0.fencingToken
                )
            }
        )
    }

    private static func acquireOperation(
        action: String,
        name: String,
        volumeID: String,
        generation: Int,
        projectID: String,
        projectUUID: UUID,
        projectGeneration: Int,
        declaration: HostwrightVolumeDeclaration,
        capacityBytes: Int64,
        expectedDataPath: String,
        planSHA256: String,
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        let id = HostwrightResourceUUID.legacy(
            kind: "storage-volume-operation",
            identifier:
                "\(planSHA256):\(action):\(volumeID):\(generation)"
        )
        let fence = HostwrightResourceUUID.legacy(
            kind: "storage-volume-fence",
            identifier: id
        )
        let intent = StorageVolumeOperationIntent(
            schemaVersion: 1,
            action: action,
            name: name,
            volumeID: volumeID,
            projectID: projectID,
            projectResourceUUID:
                projectUUID.uuidString.lowercased(),
            projectGeneration: projectGeneration,
            providerID:
                LocalStorageProviderContract.providerID,
            topologyNodeID: topologyNodeID,
            generation: Int64(generation),
            fencingToken: fence,
            capacityBytes: capacityBytes,
            reclaimPolicy:
                stateReclaim(declaration.reclaimPolicy),
            accessMode: stateAccess(declaration.accessMode),
            expectedDataPath:
                URL(fileURLWithPath: expectedDataPath)
                    .standardizedFileURL.path
        )
        let now = hostwrightTimestamp()
        let group = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "storage-volume",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: action,
            status: .active,
            groupIdempotencyKey: sha256(
                "\(action):\(volumeID):\(generation):\(planSHA256)"
            ),
            planHash: planSHA256,
            checkpoint: "intent-persisted",
            lockOwner: "hostwright-cli",
            lockExpiresAt: hostwrightTimestampAdding(
                seconds: 86_400,
                to: now
            ),
            rollbackAvailable: action == "create",
            manualRecoveryHintRedacted:
                "Run hostwright volume recover for the exact operation.",
            createdAt: now,
            updatedAt: now,
            metadataJSONRedacted: #"{"resource":"volume"}"#,
            fencingToken: fence,
            intentJSONRedacted: try encodeOperationIntent(intent),
            compensationJSONRedacted:
                action == "create" ? #"["delete-created-volume"]"# : "[]",
            verificationJSONRedacted: "{}"
        )
        if let existing = try store.operationGroups.load(id: id) {
            guard existing.planHash == planSHA256,
                  existing.fencingToken == fence,
                  existing.groupIdempotencyKey ==
                    group.groupIdempotencyKey else {
                throw diagnostic(
                    .storageConflict,
                    "A prior storage operation reused an identity with different authority."
                )
            }
            switch existing.status {
            case .active:
                return existing
            case .interrupted:
                return try store.operationGroups.resumeInterrupted(
                    groupID: id,
                    expectedFencingToken: fence,
                    lockOwner: "hostwright-cli",
                    lockExpiresAt: group.lockExpiresAt,
                    updatedAt: now
                )
            case .succeeded, .failed:
                throw diagnostic(
                    .storagePartialEffect,
                    "A terminal storage operation is missing its authoritative state; recovery is required."
                )
            }
        }
        let acquired = try store.operationGroups.acquire(
            group,
            currentTimestamp: now
        )
        if let value = acquired.acquired {
            return value
        }
        guard let existing = acquired.existingActive,
              existing.id == group.id,
              existing.planHash == planSHA256,
              existing.fencingToken == fence else {
            throw diagnostic(
                .storageConflict,
                "Another active operation owns the project storage fence."
            )
        }
        return existing
    }

    private static func encodeOperationIntent(
        _ intent: StorageVolumeOperationIntent
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        guard let value = String(
            data: try encoder.encode(intent),
            encoding: .utf8
        ) else {
            throw diagnostic(
                .storageInvalid,
                "Storage operation intent could not be encoded."
            )
        }
        return value
    }

    private static func checkpoint(
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

    private static func succeed(
        _ group: OperationGroupRecord,
        store: SQLiteStateStore
    ) throws {
        try store.operationGroups.finish(
            groupID: group.id,
            status: .succeeded,
            checkpoint: "state-committed",
            manualRecoveryHintRedacted: "",
            updatedAt: hostwrightTimestamp(),
            metadataJSONRedacted: #"{"result":"succeeded"}"#
        )
    }

    private static func interrupt(
        _ group: OperationGroupRecord,
        store: SQLiteStateStore
    ) throws {
        guard try store.operationGroups.load(id: group.id)?.status ==
                .active else {
            return
        }
        try store.operationGroups.finish(
            groupID: group.id,
            status: .interrupted,
            checkpoint: "recovery-required",
            manualRecoveryHintRedacted:
                "Observe the exact provider resource before retrying.",
            updatedAt: hostwrightTimestamp(),
            metadataJSONRedacted: #"{"result":"interrupted"}"#
        )
    }

    private static func requireOwned(
        _ record: StorageStateVolumeRecord,
        name: String,
        volumeID: String,
        declaration: HostwrightVolumeDeclaration,
        projectID: String
    ) throws {
        guard record.id == volumeID,
              record.providerVolumeID == volumeID,
              record.projectID == projectID,
              record.name == name,
              record.providerID ==
                LocalStorageProviderContract.providerID,
              record.lifecycleState == .available else {
            throw diagnostic(
                .storageConflict,
                "Named volume '\(name)' does not have exact usable ownership evidence."
            )
        }
        guard record.accessMode ==
                stateAccess(declaration.accessMode),
              record.reclaimPolicy ==
                stateReclaim(declaration.reclaimPolicy) else {
            throw diagnostic(
                .storageInvalid,
                "Named volume '\(name)' changes an access or reclaim policy that requires an explicit volume update."
            )
        }
    }

    private static func requireObservation(
        _ observed: LocalStorageVolumeObservation,
        record: StorageStateVolumeRecord,
        expectedPath: String,
        projectResourceUUID: String
    ) throws {
        var mismatches: [String] = []
        if observed.volumeID != record.providerVolumeID {
            mismatches.append("volume-id")
        }
        if observed.name != record.name {
            mismatches.append("name")
        }
        if observed.providerID != record.providerID {
            mismatches.append("provider-id")
        }
        if observed.projectID != projectResourceUUID {
            mismatches.append("project-id")
        }
        if observed.generation != Int(record.generation) {
            mismatches.append("generation")
        }
        if observed.fencingToken != record.fencingToken {
            mismatches.append("fencing-token")
        }
        if observed.capacityBytes != record.capacityBytes {
            mismatches.append("capacity")
        }
        let observedPath = URL(
            fileURLWithPath: observed.dataPath,
            isDirectory: true
        ).standardizedFileURL.path
        let plannedPath = URL(
            fileURLWithPath: expectedPath,
            isDirectory: true
        ).standardizedFileURL.path
        if observedPath != plannedPath {
            mismatches.append("data-path")
        }
        guard mismatches.isEmpty else {
            throw diagnostic(
                .storageConflict,
                "Named volume '\(record.name)' failed exact provider verification for: \(mismatches.joined(separator: ", "))."
            )
        }
    }

    private static func volumeID(
        projectResourceUUID: String,
        name: String
    ) -> String {
        HostwrightResourceUUID.legacy(
            kind: "storage-volume",
            identifier: "\(projectResourceUUID):\(name)"
        )
    }

    private static func capacityBytes(_ value: String) throws -> Int64 {
        let suffixes: [(String, Int64)] = [
            ("TiB", 1_099_511_627_776),
            ("GiB", 1_073_741_824),
            ("MiB", 1_048_576),
            ("KiB", 1_024),
            ("B", 1),
        ]
        guard let (suffix, multiplier) = suffixes.first(where: {
            value.hasSuffix($0.0)
        }),
        let count = Int64(value.dropLast(suffix.count)),
        count > 0 else {
            throw diagnostic(
                .storageInvalid,
                "Named-volume capacity is not a normalized positive size."
            )
        }
        let result = count.multipliedReportingOverflow(by: multiplier)
        guard !result.overflow,
              result.partialValue <=
                StorageSemanticLimits.maximumCapacityBytes else {
            throw diagnostic(
                .storageInvalid,
                "Named-volume capacity exceeds the supported bound."
            )
        }
        return result.partialValue
    }

    private static func stateReclaim(
        _ value: HostwrightVolumeReclaimPolicy
    ) -> StorageReclaimPolicy {
        switch value {
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

    private static func stateAccess(
        _ value: HostwrightVolumeAccessMode
    ) -> StorageAccessMode {
        switch value {
        case .readWriteOnce:
            .readWriteOnce
        case .readOnlyMany:
            .readOnlyMany
        }
    }

    private static func stateAccess(
        _ value: StorageSemanticAccessMode
    ) -> StorageAccessMode {
        switch value {
        case .readWriteOnce:
            .readWriteOnce
        case .readOnlyMany:
            .readOnlyMany
        }
    }

    private static func semanticAccess(
        _ value: StorageAccessMode
    ) -> StorageSemanticAccessMode {
        switch value {
        case .readWriteOnce:
            .readWriteOnce
        case .readOnlyMany:
            .readOnlyMany
        }
    }

    private static func localRetention(
        _ value: HostwrightVolumeReclaimPolicy
    ) -> LocalStorageRetentionPolicy {
        switch value {
        case .retain, .recycle:
            .retain
        case .delete, .snapshotBeforeDelete,
             .backupBeforeDelete:
            .deleteWhenUnused
        }
    }

    private static func localRetention(
        _ value: StorageReclaimPolicy
    ) -> LocalStorageRetentionPolicy {
        switch value {
        case .retain, .recycle:
            .retain
        case .delete, .snapshotBeforeDelete,
             .backupBeforeDelete:
            .deleteWhenUnused
        }
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func diagnostic(
        _ code: HostwrightErrorCode,
        _ message: String
    ) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: code, message: message)
    }
}
