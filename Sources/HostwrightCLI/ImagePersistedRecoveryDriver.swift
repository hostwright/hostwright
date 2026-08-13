import CryptoKit
import Foundation
import HostwrightCore
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

struct ImagePersistedRecoveryDriver {
    let environment: CLIEnvironment

    func execute(
        _ recovery: LifecyclePersistedRecoveryRequest,
        sourceGroup: OperationGroupRecord
    ) throws -> LifecycleSagaExecutionResult {
        guard sourceGroup.groupKind == ImageOwnershipLedger.groupKind else {
            throw LifecyclePersistedRecoveryError.invalidRequest(
                "The selected operation group is not an image lifecycle intent."
            )
        }
        guard recovery.confirmationPlanSHA256 == sourceGroup.planHash else {
            throw LifecyclePersistedRecoveryError.confirmationMismatch
        }
        if sourceGroup.status == .succeeded {
            return result(
                status: .alreadySucceeded,
                group: sourceGroup,
                checkpoint: sourceGroup.checkpoint,
                completed: []
            )
        }
        guard sourceGroup.status == .interrupted else {
            throw LifecyclePersistedRecoveryError.invalidRequest(
                "Only an interrupted image lifecycle intent can be recovered."
            )
        }
        let intent = try ImageLifecycleIntentV1.decodeStrict(
            sourceGroup.intentJSONRedacted
        )
        guard try intent.request.planSHA256() == sourceGroup.planHash,
              intent.request.operation.rawValue ==
                sourceGroup.plannedActionType else {
            throw LifecyclePersistedRecoveryError.safeHold(
                hold(
                    sourceGroup,
                    "Persisted image request identity does not match its durable group."
                )
            )
        }
        let provider = try selectedProvider(intent: intent)
        let capability = try hostwrightWaitForAsync {
            try await provider.imageOperationCapabilities()
        }
        guard capability.providerID == intent.providerID,
              capability.capabilitySHA256 ==
                intent.request.capabilitySHA256 else {
            throw LifecyclePersistedRecoveryError.safeHold(
                hold(
                    sourceGroup,
                    "Image provider capability changed after interruption."
                )
            )
        }

        let store = SQLiteStateStore(
            configuration: recovery.stateStoreConfiguration
        )
        try store.migrate()
        let timestamp = imageLifecycleTimestamp()
        let active = try store.operationGroups.resumeInterrupted(
            groupID: sourceGroup.id,
            expectedFencingToken: sourceGroup.fencingToken,
            lockOwner: "image-recovery-\(UUID().uuidString.lowercased())",
            lockExpiresAt: hostwrightTimestampAdding(
                seconds: 900,
                to: timestamp
            ),
            updatedAt: timestamp
        )
        do {
            switch recovery.action {
            case .resume:
                return try resume(
                    active,
                    intent: intent,
                    provider: provider,
                    capability: capability,
                    store: store
                )
            case .rollback:
                return try rollback(
                    active,
                    intent: intent,
                    provider: provider,
                    capability: capability,
                    store: store
                )
            }
        } catch let error as LifecyclePersistedRecoveryError {
            try? returnToSafeHold(active, store: store)
            throw error
        } catch {
            try? returnToSafeHold(active, store: store)
            throw LifecyclePersistedRecoveryError.safeHold(
                hold(
                    active,
                    "Image recovery could not prove an exact safe next effect."
                )
            )
        }
    }

    private func resume(
        _ group: OperationGroupRecord,
        intent: ImageLifecycleIntentV1,
        provider: any RuntimeImageLifecycleProviding,
        capability: RuntimeImageOperationCapabilityContract,
        store: SQLiteStateStore
    ) throws -> LifecycleSagaExecutionResult {
        let inventory = try hostwrightWaitForAsync {
            try await provider.inventory()
        }
        let current = try currentReferences(inventory)
        switch intent.request.operation {
        case .pull, .build, .tag, .load:
            guard let evidence = try partialEffectEvidence(group),
                  Set(evidence.createdReferences.map(\.reference)) ==
                    Set(intent.createdReferences),
                  evidence.createdReferences.allSatisfy({
                      current[$0.reference] == $0.digest
                  }) else {
                throw LifecyclePersistedRecoveryError.safeHold(
                    hold(
                        group,
                        "Interrupted image creation lacks exact durable reference-to-digest proof."
                    )
                )
            }
            let images = try inspectRecords(
                references: intent.createdReferences,
                expected: evidence.createdReferences,
                provider: provider,
                capability: capability,
                group: group
            )
            let operationResult = try RuntimeImageOperationResult(
                operation: intent.request.operation,
                operationID: intent.request.operationID,
                idempotencyKey: intent.request.idempotencyKey,
                planSHA256: group.planHash,
                providerID: intent.providerID,
                providerVersion: try hostwrightWaitForAsync {
                    try await provider.runtimeVersion()
                },
                disposition: .succeeded,
                images: images
            )
            let changes = try intent.createdReferences.map { reference in
                let matches = images.filter {
                    $0.references.contains(reference)
                }
                guard matches.count == 1 else {
                    throw LifecyclePersistedRecoveryError.safeHold(
                        hold(
                            group,
                            "Recovered image reference does not resolve to one immutable digest."
                        )
                    )
                }
                return try ImageOwnershipChangeV1(
                    action: .add,
                    reference: reference,
                    digest: matches[0].digest,
                    providerID: intent.providerID.rawValue
                )
            }
            let contentLeases = try recordRecoveredCreation(
                group: group,
                images: images,
                changes: changes,
                providerID: intent.providerID,
                store: store
            )
            defer {
                releaseContentLeases(contentLeases, store: store)
            }
            try finish(
                group,
                status: .succeeded,
                checkpoint: "recovery-observation-verified",
                changes: changes,
                operationResult: operationResult,
                direction: .forward,
                store: store
            )
            return result(
                status: .succeeded,
                group: group,
                checkpoint: "recovery-observation-verified",
                completed: ["observe-created-references"]
            )
        case .delete, .prune:
            return try resumeRemoval(
                group,
                intent: intent,
                provider: provider,
                capability: capability,
                inventory: inventory,
                current: current,
                store: store
            )
        case .push:
            guard exactPriorSources(intent, current: current) else {
                throw LifecyclePersistedRecoveryError.safeHold(
                    hold(
                        group,
                        "The local push source digest changed after interruption."
                    )
                )
            }
            let contentLeases = try prepareRecoverySourceLeases(
                group: group,
                intent: intent,
                provider: provider,
                capability: capability,
                store: store
            )
            defer {
                releaseContentLeases(contentLeases, store: store)
            }
            let operationResult = try hostwrightWaitForAsync {
                try await provider.performImageOperation(
                    intent.request,
                    confirmation: RuntimeMutationConfirmation(
                        confirmed: true,
                        reason: "Resume exact immutable image push.",
                        planHash: group.planHash
                    ),
                    progress: { _ in }
                )
            }
            try finish(
                group,
                status: .succeeded,
                checkpoint: "recovery-provider-effect-verified",
                changes: [],
                operationResult: operationResult,
                direction: .forward,
                store: store
            )
            return result(
                status: .succeeded,
                group: group,
                checkpoint: "recovery-provider-effect-verified",
                completed: ["resume-push"]
            )
        case .save:
            throw LifecyclePersistedRecoveryError.safeHold(
                hold(
                    group,
                    "Archive completion cannot be inferred after interruption; remove only the exact output after inspection and issue a fresh save."
                )
            )
        case .inspect:
            throw LifecyclePersistedRecoveryError.invalidRequest(
                "Read-only image inspection does not create recovery state."
            )
        }
    }

    private func resumeRemoval(
        _ group: OperationGroupRecord,
        intent: ImageLifecycleIntentV1,
        provider: any RuntimeImageLifecycleProviding,
        capability: RuntimeImageOperationCapabilityContract,
        inventory: RuntimeInventory,
        current: [String: String],
        store: SQLiteStateStore
    ) throws -> LifecycleSagaExecutionResult {
        let ownership = try store.imageOwnership.load()
        let liveDigests = Set(inventory.containers.compactMap(\.imageID))
        let liveReferences = Set(inventory.containers.map(\.imageReference))
        let remaining = intent.request.sourceReferences.filter { reference in
            current[reference] != nil
        }
        for reference in remaining {
            guard let removal = intent.removedOwnership.first(where: {
                $0.reference == reference
            }),
            current[reference] == removal.digest,
            ownership.ownsExact(
                reference: reference,
                digest: removal.digest,
                providerID: intent.providerID.rawValue
            ),
            !liveDigests.contains(removal.digest),
            !liveReferences.contains(reference) else {
                throw LifecyclePersistedRecoveryError.safeHold(
                    hold(
                        group,
                        "Removal recovery lost exact ownership or unreferenced-content proof."
                    )
                )
            }
        }
        let contentLeases = try prepareRecoveryRemovalLeases(
            group: group,
            intent: intent,
            remainingReferences: remaining,
            provider: provider,
            capability: capability,
            store: store
        )
        defer {
            releaseContentLeases(contentLeases, store: store)
        }

        let operationResult: RuntimeImageOperationResult
        if remaining.isEmpty {
            operationResult = try RuntimeImageOperationResult(
                operation: intent.request.operation,
                operationID: intent.request.operationID,
                idempotencyKey: intent.request.idempotencyKey,
                planSHA256: group.planHash,
                providerID: intent.providerID,
                providerVersion: try hostwrightWaitForAsync {
                    try await provider.runtimeVersion()
                },
                disposition: .unchanged,
                deletedDigests: intent.removedOwnership.map(\.digest)
            )
        } else {
            let resumedRequest = try RuntimeImageLifecycleRequest(
                operation: intent.request.operation,
                operationID: UUID().uuidString.lowercased(),
                idempotencyKey: recoveryDigest(
                    group.planHash,
                    remaining: remaining
                ),
                capabilitySHA256: capability.capabilitySHA256,
                sourceReferences: remaining,
                expectedSourceDigests: Dictionary(
                    uniqueKeysWithValues: remaining.compactMap {
                        reference in
                        current[reference].map { (reference, $0) }
                    }
                )
            )
            operationResult = try hostwrightWaitForAsync {
                try await provider.performImageOperation(
                    resumedRequest,
                    confirmation: RuntimeMutationConfirmation(
                        confirmed: true,
                        reason: "Resume exact owned image removal.",
                        planHash: resumedRequest.planSHA256()
                    ),
                    progress: { _ in }
                )
            }
        }
        let postInventory = try hostwrightWaitForAsync {
            try await provider.inventory()
        }
        let postCurrent = try currentReferences(postInventory)
        guard intent.request.sourceReferences.allSatisfy({
            postCurrent[$0] == nil
        }) else {
            throw LifecyclePersistedRecoveryError.safeHold(
                hold(
                    group,
                    "Removal recovery did not observe every exact target reference as absent."
                )
            )
        }
        let changes = try intent.removedOwnership.map {
            try ImageOwnershipChangeV1(
                action: .remove,
                reference: $0.reference,
                digest: $0.digest,
                providerID: intent.providerID.rawValue
            )
        }
        try removeRecoveredContentAccounting(
            removals: intent.removedOwnership,
            providerID: intent.providerID,
            runtimeDigests: Set(postCurrent.values),
            leases: contentLeases,
            store: store
        )
        try finish(
            group,
            status: .succeeded,
            checkpoint: "recovery-removal-verified",
            changes: changes,
            operationResult: operationResult,
            direction: .forward,
            store: store
        )
        return result(
            status: .succeeded,
            group: group,
            checkpoint: "recovery-removal-verified",
            completed: ["resume-exact-removal"]
        )
    }

    private func rollback(
        _ group: OperationGroupRecord,
        intent: ImageLifecycleIntentV1,
        provider: any RuntimeImageLifecycleProviding,
        capability: RuntimeImageOperationCapabilityContract,
        store: SQLiteStateStore
    ) throws -> LifecycleSagaExecutionResult {
        if intent.request.operation == .save,
           let archivePath = intent.request.archivePath {
            _ = try removeExactOwnedImageArchiveIfPresent(archivePath)
            try finish(
                group,
                status: .failed,
                checkpoint: "recovery-rolled-back",
                changes: [],
                operationResult: nil,
                direction: .rollback,
                store: store
            )
            return result(
                status: .compensated,
                group: group,
                checkpoint: "recovery-rolled-back",
                completed: ["delete-created-archive"]
            )
        }
        guard let evidence = try partialEffectEvidence(group),
              !evidence.createdReferences.isEmpty,
              Set(evidence.createdReferences.map(\.reference)).isDisjoint(
                  with: Set(intent.priorReferences.map(\.reference))
              ) else {
            throw LifecyclePersistedRecoveryError.safeHold(
                hold(
                    group,
                    "This image operation has no exact digest-bound reversible creation proof."
                )
            )
        }
        let inventory = try hostwrightWaitForAsync {
            try await provider.inventory()
        }
        let current = try currentReferences(inventory)
        let liveDigests = Set(inventory.containers.compactMap(\.imageID))
        let liveReferences = Set(inventory.containers.map(\.imageReference))
        let targets = evidence.createdReferences.filter {
            current[$0.reference] != nil
        }
        for target in targets {
            guard current[target.reference] == target.digest,
                  !liveDigests.contains(target.digest),
                  !liveReferences.contains(target.reference) else {
                throw LifecyclePersistedRecoveryError.safeHold(
                    hold(
                        group,
                        "Rollback refused replaced or live-referenced image content."
                    )
                )
            }
        }
        if !targets.isEmpty {
            let targetReferences = targets.map(\.reference).sorted()
            let cleanup = try RuntimeImageLifecycleRequest(
                operation: .delete,
                operationID: UUID().uuidString.lowercased(),
                idempotencyKey: recoveryDigest(
                    group.planHash,
                    remaining: targetReferences
                ),
                capabilitySHA256: capability.capabilitySHA256,
                sourceReferences: targetReferences,
                expectedSourceDigests: Dictionary(
                    uniqueKeysWithValues: targets.map {
                        ($0.reference, $0.digest)
                    }
                )
            )
            _ = try hostwrightWaitForAsync {
                try await provider.performImageOperation(
                    cleanup,
                    confirmation: RuntimeMutationConfirmation(
                        confirmed: true,
                        reason: "Roll back exact references created by image intent.",
                        planHash: cleanup.planSHA256()
                    ),
                    progress: { _ in }
                )
            }
            let postInventory = try hostwrightWaitForAsync {
                try await provider.inventory()
            }
            let postCurrent = try currentReferences(postInventory)
            guard targetReferences.allSatisfy({
                postCurrent[$0] == nil
            }) else {
                throw LifecyclePersistedRecoveryError.safeHold(
                    hold(
                        group,
                        "Rollback did not observe every exact created reference as absent."
                    )
                )
            }
        }
        try finish(
            group,
            status: .failed,
            checkpoint: "recovery-rolled-back",
            changes: [],
            operationResult: nil,
            direction: .rollback,
            store: store
        )
        return result(
            status: .compensated,
            group: group,
            checkpoint: "recovery-rolled-back",
            completed: ["delete-created-references"]
        )
    }

    private func partialEffectEvidence(
        _ group: OperationGroupRecord
    ) throws -> ImageLifecyclePartialEffectEvidenceV1? {
        guard group.verificationJSONRedacted != "{}" else {
            return nil
        }
        return try ImageLifecyclePartialEffectEvidenceV1.decodeStrict(
            group.verificationJSONRedacted
        )
    }

    private func selectedProvider(
        intent: ImageLifecycleIntentV1
    ) throws -> any RuntimeImageLifecycleProviding {
        let adapter = try environment.runtimeAdapterForProvider(
            intent.providerID
        )
        guard let provider = adapter as? any RuntimeImageLifecycleProviding else {
            throw LifecyclePersistedRecoveryError.unavailable(
                "The persisted image runtime provider is unavailable."
            )
        }
        return provider
    }

    private func finish(
        _ group: OperationGroupRecord,
        status: OperationGroupStatus,
        checkpoint: String,
        changes: [ImageOwnershipChangeV1],
        operationResult: RuntimeImageOperationResult?,
        direction: OperationGroupStepDirection,
        store: SQLiteStateStore
    ) throws {
        let timestamp = imageLifecycleTimestamp()
        let metadata = try ImageOwnershipMetadataV1(
            changes: changes
        ).canonicalJSONString()
        let verification = try verificationJSON(operationResult)
        try store.operationGroupSteps.append(
            OperationGroupStepRecord(
                id: "image-recovery-step-\(UUID().uuidString.lowercased())",
                groupID: group.id,
                stepKey: checkpoint,
                direction: direction,
                plannedActionType: group.plannedActionType,
                serviceName: nil,
                resourceIdentifier: nil,
                stepIdempotencyKey:
                    "\(group.planHash):recovery:\(direction.rawValue):\(checkpoint)",
                status: .succeeded,
                startedAt: timestamp,
                updatedAt: timestamp,
                finishedAt: timestamp,
                lastErrorRedacted: nil,
                manualRecoveryHintRedacted: "No recovery is required.",
                metadataJSONRedacted: verification
            ),
            expectedFencingToken: group.fencingToken
        )
        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: checkpoint,
            verificationJSONRedacted: verification,
            updatedAt: timestamp
        )
        try store.operationGroups.finish(
            groupID: group.id,
            status: status,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted: "No recovery is required.",
            updatedAt: timestamp,
            metadataJSONRedacted: metadata
        )
    }

    private func returnToSafeHold(
        _ group: OperationGroupRecord,
        store: SQLiteStateStore
    ) throws {
        let metadata = try ImageOwnershipMetadataV1(
            changes: []
        ).canonicalJSONString()
        try store.operationGroups.finish(
            groupID: group.id,
            status: .interrupted,
            checkpoint: "recovery-safe-hold",
            manualRecoveryHintRedacted:
                "Recovery stopped before an unproven image effect.",
            updatedAt: imageLifecycleTimestamp(),
            metadataJSONRedacted: metadata
        )
    }

    private func inspectRecords(
        references: [String],
        expected: [ImageIntentReference],
        provider: any RuntimeImageLifecycleProviding,
        capability: RuntimeImageOperationCapabilityContract,
        group: OperationGroupRecord
    ) throws -> [RuntimeImageRecord] {
        guard capability.status(for: .inspect).state == .available,
              capability.status(for: .inspect).reason == .implemented else {
            throw LifecyclePersistedRecoveryError.safeHold(
                hold(
                    group,
                    "Structured image inspection is unavailable for recovery content verification."
                )
            )
        }
        let request = try RuntimeImageLifecycleRequest(
            operation: .inspect,
            operationID: UUID().uuidString.lowercased(),
            idempotencyKey: recoveryDigest(
                "inspect-\(group.planHash)",
                remaining: references
            ),
            capabilitySHA256: capability.capabilitySHA256,
            sourceReferences: references
        )
        let result = try hostwrightWaitForAsync {
            try await provider.performImageOperation(
                request,
                confirmation: nil,
                progress: { _ in }
            )
        }
        let requestPlanSHA256 = try request.planSHA256()
        let expectedByReference = Dictionary(
            uniqueKeysWithValues: expected.map {
                ($0.reference, $0.digest)
            }
        )
        guard result.operation == .inspect,
              result.providerID == capability.providerID,
              result.planSHA256 == requestPlanSHA256,
              references.allSatisfy({ reference in
                  let matches = result.images.filter {
                      $0.references.contains(reference)
                  }
                  return matches.count == 1 &&
                      matches[0].digest ==
                        expectedByReference[reference]
              }) else {
            throw LifecyclePersistedRecoveryError.safeHold(
                hold(
                    group,
                    "Structured image inspection did not reproduce the exact recovery digest evidence."
                )
            )
        }
        let requested = Set(references)
        return result.images.filter {
            !requested.isDisjoint(with: $0.references)
        }
    }

    private func recordRecoveredCreation(
        group: OperationGroupRecord,
        images: [RuntimeImageRecord],
        changes: [ImageOwnershipChangeV1],
        providerID: RuntimeProviderID,
        store: SQLiteStateStore
    ) throws -> [ContentCacheLeaseRecord] {
        let timestamp = imageLifecycleTimestamp()
        var snapshot = try store.contentCache.snapshot(
            providerScope: providerID.rawValue,
            currentTimestamp: timestamp,
            limit: ImageCacheLimits.maximumRecords
        )
        var contentByDigest = Dictionary(
            uniqueKeysWithValues: snapshot.contents.map {
                ($0.digest, $0)
            }
        )
        var references = Dictionary(
            uniqueKeysWithValues: snapshot.references.map {
                ($0.reference, $0)
            }
        )
        for image in images {
            let existing = contentByDigest[image.digest]
            let record = ContentCacheRecord(
                providerScope: providerID.rawValue,
                digest: image.digest,
                kind: .runtimeImage,
                sizeBytes: image.sizeBytes,
                pinPolicy: existing?.pinPolicy ?? .unpinned,
                createdAt: existing?.createdAt ?? timestamp,
                observedAt: timestamp,
                lastUsedAt: timestamp
            )
            try store.contentCache.upsert(record)
            contentByDigest[image.digest] = record
        }
        for change in changes where change.action == .add {
            let ownership = ImageOwnershipRecord(
                reference: change.reference,
                digest: change.digest,
                providerID: change.providerID,
                ownershipOperationID: group.id,
                ownershipProofSHA256: contentOwnershipProof(
                    group: group,
                    action: .add,
                    reference: change.reference,
                    digest: change.digest,
                    providerID: change.providerID
                )
            )
            try saveRecoveryContentReference(
                ownership,
                existing: references[change.reference],
                observedAt: timestamp,
                store: store
            )
            snapshot = try store.contentCache.snapshot(
                providerScope: providerID.rawValue,
                currentTimestamp: timestamp,
                limit: ImageCacheLimits.maximumRecords
            )
            references = Dictionary(
                uniqueKeysWithValues: snapshot.references.map {
                    ($0.reference, $0)
                }
            )
        }

        var leases: [ContentCacheLeaseRecord] = []
        do {
            for change in changes where change.action == .add {
                leases.append(
                    try store.contentCache.acquireLease(
                        providerScope: providerID.rawValue,
                        digest: change.digest,
                        reference: change.reference,
                        mode: .shared,
                        ownerID: group.id,
                        purpose: "image-recovery-create",
                        acquiredAt: timestamp,
                        expiresAt: hostwrightTimestampAdding(
                            seconds: 86_400,
                            to: timestamp
                        )
                    )
                )
            }
            return leases
        } catch {
            releaseContentLeases(leases, store: store)
            throw error
        }
    }

    private func prepareRecoverySourceLeases(
        group: OperationGroupRecord,
        intent: ImageLifecycleIntentV1,
        provider: any RuntimeImageLifecycleProviding,
        capability: RuntimeImageOperationCapabilityContract,
        store: SQLiteStateStore
    ) throws -> [ContentCacheLeaseRecord] {
        let expected = intent.request.expectedSourceDigests
            .map {
                ImageIntentReference(
                    reference: $0.key,
                    digest: $0.value
                )
            }
            .sorted { $0.reference < $1.reference }
        let images = try inspectRecords(
            references: expected.map(\.reference),
            expected: expected,
            provider: provider,
            capability: capability,
            group: group
        )
        let timestamp = imageLifecycleTimestamp()
        let snapshot = try store.contentCache.snapshot(
            providerScope: intent.providerID.rawValue,
            currentTimestamp: timestamp,
            limit: ImageCacheLimits.maximumRecords
        )
        var contentByDigest = Dictionary(
            uniqueKeysWithValues: snapshot.contents.map {
                ($0.digest, $0)
            }
        )
        for image in images {
            let existing = contentByDigest[image.digest]
            let record = ContentCacheRecord(
                providerScope: intent.providerID.rawValue,
                digest: image.digest,
                kind: .runtimeImage,
                sizeBytes: image.sizeBytes,
                pinPolicy: existing?.pinPolicy ?? .unpinned,
                createdAt: existing?.createdAt ?? timestamp,
                observedAt: timestamp,
                lastUsedAt: existing?.lastUsedAt ?? timestamp
            )
            try store.contentCache.upsert(record)
            contentByDigest[image.digest] = record
        }
        let projection = try store.imageOwnership.load()
        var existingReferences = Dictionary(
            uniqueKeysWithValues: snapshot.references.map {
                ($0.reference, $0)
            }
        )
        for source in expected {
            guard let ownership = projection.record(
                forReference: source.reference,
                providerID: intent.providerID.rawValue
            ), ownership.digest == source.digest else {
                continue
            }
            try saveRecoveryContentReference(
                ownership,
                existing: existingReferences[source.reference],
                observedAt: timestamp,
                store: store
            )
            existingReferences[source.reference] =
                try store.contentCache.listReferences(
                    providerScope: intent.providerID.rawValue,
                    digest: source.digest,
                    limit:
                        RuntimeImageLifecycleLimits
                            .maximumSourceReferencesPerRequest
                ).first {
                    $0.reference == source.reference
                }
        }

        var leases: [ContentCacheLeaseRecord] = []
        do {
            for source in expected {
                leases.append(
                    try store.contentCache.acquireLease(
                        providerScope: intent.providerID.rawValue,
                        digest: source.digest,
                        reference:
                            existingReferences[source.reference]?.digest ==
                                source.digest
                            ? source.reference
                            : nil,
                        mode: .shared,
                        ownerID: group.id,
                        purpose: "image-recovery-push",
                        acquiredAt: timestamp,
                        expiresAt: hostwrightTimestampAdding(
                            seconds: 86_400,
                            to: timestamp
                        )
                    )
                )
            }
            return leases
        } catch {
            releaseContentLeases(leases, store: store)
            throw error
        }
    }

    private func prepareRecoveryRemovalLeases(
        group: OperationGroupRecord,
        intent: ImageLifecycleIntentV1,
        remainingReferences: [String],
        provider: any RuntimeImageLifecycleProviding,
        capability: RuntimeImageOperationCapabilityContract,
        store: SQLiteStateStore
    ) throws -> [ContentCacheLeaseRecord] {
        let expected = intent.removedOwnership.filter {
            remainingReferences.contains($0.reference)
        }
        if !expected.isEmpty {
            let images = try inspectRecords(
                references: expected.map(\.reference),
                expected: expected,
                provider: provider,
                capability: capability,
                group: group
            )
            let timestamp = imageLifecycleTimestamp()
            let before = try store.contentCache.snapshot(
                providerScope: intent.providerID.rawValue,
                currentTimestamp: timestamp,
                limit: ImageCacheLimits.maximumRecords
            )
            var contentByDigest = Dictionary(
                uniqueKeysWithValues: before.contents.map {
                    ($0.digest, $0)
                }
            )
            let projection = try store.imageOwnership.load()
            let references = Dictionary(
                uniqueKeysWithValues: before.references.map {
                    ($0.reference, $0)
                }
            )
            for image in images {
                let existing = contentByDigest[image.digest]
                let record = ContentCacheRecord(
                    providerScope: intent.providerID.rawValue,
                    digest: image.digest,
                    kind: .runtimeImage,
                    sizeBytes: image.sizeBytes,
                    pinPolicy:
                        existing?.pinPolicy ?? .unpinned,
                    createdAt:
                        existing?.createdAt ?? timestamp,
                    observedAt: timestamp,
                    lastUsedAt:
                        existing?.lastUsedAt ?? timestamp
                )
                try store.contentCache.upsert(record)
                contentByDigest[image.digest] = record
            }
            for removal in expected {
                guard let ownership = projection.record(
                    forReference: removal.reference,
                    providerID: intent.providerID.rawValue
                ), ownership.digest == removal.digest else {
                    throw LifecyclePersistedRecoveryError.safeHold(
                        hold(
                            group,
                            "Removal recovery lost exact cache ownership provenance."
                        )
                    )
                }
                try saveRecoveryContentReference(
                    ownership,
                    existing: references[removal.reference],
                    observedAt: timestamp,
                    store: store
                )
            }
        }

        let timestamp = imageLifecycleTimestamp()
        let snapshot = try store.contentCache.snapshot(
            providerScope: intent.providerID.rawValue,
            currentTimestamp: timestamp,
            limit: ImageCacheLimits.maximumRecords
        )
        let existingDigests = Set(snapshot.contents.map(\.digest))
        let digests = Set(
            intent.removedOwnership.map(\.digest)
        ).intersection(existingDigests)
        var leases: [ContentCacheLeaseRecord] = []
        do {
            for digest in digests.sorted() {
                leases.append(
                    try store.contentCache.acquireLease(
                        providerScope: intent.providerID.rawValue,
                        digest: digest,
                        mode: .exclusiveDelete,
                        ownerID: group.id,
                        purpose: "image-recovery-delete",
                        acquiredAt: timestamp,
                        expiresAt: hostwrightTimestampAdding(
                            seconds: 86_400,
                            to: timestamp
                        )
                    )
                )
            }
            return leases
        } catch {
            releaseContentLeases(leases, store: store)
            throw error
        }
    }

    private func removeRecoveredContentAccounting(
        removals: [ImageIntentReference],
        providerID: RuntimeProviderID,
        runtimeDigests: Set<String>,
        leases: [ContentCacheLeaseRecord],
        store: SQLiteStateStore
    ) throws {
        let timestamp = imageLifecycleTimestamp()
        var snapshot = try store.contentCache.snapshot(
            providerScope: providerID.rawValue,
            currentTimestamp: timestamp,
            limit: ImageCacheLimits.maximumRecords
        )
        for removal in removals {
            guard let reference = snapshot.references.first(where: {
                $0.reference == removal.reference &&
                    $0.digest == removal.digest
            }) else {
                continue
            }
            guard let lease = leases.first(where: {
                $0.digest == removal.digest &&
                    $0.mode == .exclusiveDelete
            }), try store.contentCache.removeReferenceUnderLease(
                id: reference.id,
                providerScope: reference.providerScope,
                reference: reference.reference,
                digest: reference.digest,
                ownershipOperationID:
                    reference.ownershipOperationID,
                ownershipProofSHA256:
                    reference.ownershipProofSHA256,
                exclusiveLeaseID: lease.id,
                expectedFencingToken: lease.fencingToken,
                removedAt: timestamp
            ) else {
                throw LifecyclePersistedRecoveryError.safeHold(
                    LifecycleRecoverySafeHold(
                        reason:
                            "Recovery could not fence exact cache ownership removal.",
                        affectedNodeKeys: []
                    )
                )
            }
            snapshot = try store.contentCache.snapshot(
                providerScope: providerID.rawValue,
                currentTimestamp: timestamp,
                limit: ImageCacheLimits.maximumRecords
            )
        }
        for digest in Set(removals.map(\.digest)).sorted()
            where !runtimeDigests.contains(digest) &&
                !snapshot.references.contains(where: {
                    $0.digest == digest
                }) {
            guard let content = snapshot.contents.first(where: {
                $0.digest == digest
            }) else {
                continue
            }
            guard let lease = leases.first(where: {
                $0.digest == digest &&
                    $0.mode == .exclusiveDelete
            }), try store.contentCache.removeContent(
                providerScope: providerID.rawValue,
                digest: digest,
                expectedKind: .runtimeImage,
                expectedSizeBytes: content.sizeBytes,
                expectedCreatedAt: content.createdAt,
                exclusiveLeaseID: lease.id,
                expectedFencingToken: lease.fencingToken,
                removedAt: timestamp
            ) else {
                throw LifecyclePersistedRecoveryError.safeHold(
                    LifecycleRecoverySafeHold(
                        reason:
                            "Recovery could not fence exact cache content removal.",
                        affectedNodeKeys: []
                    )
                )
            }
        }
    }

    private func saveRecoveryContentReference(
        _ ownership: ImageOwnershipRecord,
        existing: ContentCacheReferenceRecord?,
        observedAt: String,
        store: SQLiteStateStore
    ) throws {
        guard let ownershipOperationID =
                ownership.ownershipOperationID,
              let ownershipProofSHA256 =
                ownership.ownershipProofSHA256 else {
            throw StateStoreError.invalidRecord(
                "Recovery cache ownership lacks immutable provenance."
            )
        }
        if let existing {
            guard existing.digest == ownership.digest,
                  existing.ownershipOperationID ==
                    ownershipOperationID,
                  existing.ownershipProofSHA256 ==
                    ownershipProofSHA256 else {
                throw StateStoreError.invalidRecord(
                    "Recovery cache ownership changed."
                )
            }
        }
        try store.contentCache.saveReference(
            ContentCacheReferenceRecord(
                id: existing?.id ??
                    HostwrightResourceUUID.legacy(
                        kind: "image-content-reference",
                        identifier:
                            "\(ownership.providerID):\(ownership.reference)"
                    ),
                providerScope: ownership.providerID,
                reference: ownership.reference,
                digest: ownership.digest,
                ownershipOperationID: ownershipOperationID,
                ownershipProofSHA256: ownershipProofSHA256,
                createdAt: existing?.createdAt ?? observedAt,
                observedAt: observedAt
            )
        )
    }

    private func contentOwnershipProof(
        group: OperationGroupRecord,
        action: ImageOwnershipChangeAction,
        reference: String,
        digest: String,
        providerID: String
    ) -> String {
        let value = [
            group.id,
            group.planHash,
            action.rawValue,
            providerID,
            reference,
            digest
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func releaseContentLeases(
        _ leases: [ContentCacheLeaseRecord],
        store: SQLiteStateStore
    ) {
        let timestamp = imageLifecycleTimestamp()
        for lease in leases.reversed() {
            _ = try? store.contentCache.releaseLease(
                id: lease.id,
                expectedFencingToken: lease.fencingToken,
                releasedAt: timestamp
            )
        }
    }

    private func currentReferences(
        _ inventory: RuntimeInventory
    ) throws -> [String: String] {
        var current: [String: String] = [:]
        for image in inventory.images {
            for reference in image.references {
                if let existing = current[reference],
                   existing != image.descriptorDigest {
                    throw LifecyclePersistedRecoveryError.safeHold(
                        LifecycleRecoverySafeHold(
                            reason:
                                "Runtime inventory conflicts for one image reference.",
                            affectedNodeKeys: []
                        )
                    )
                }
                current[reference] = image.descriptorDigest
            }
        }
        return current
    }

    private func exactPriorSources(
        _ intent: ImageLifecycleIntentV1,
        current: [String: String]
    ) -> Bool {
        let prior = Dictionary(
            uniqueKeysWithValues: intent.priorReferences.map {
                ($0.reference, $0.digest)
            }
        )
        return intent.request.sourceReferences.allSatisfy {
            current[$0] == prior[$0]
        }
    }

    private func verificationJSON(
        _ result: RuntimeImageOperationResult?
    ) throws -> String {
        let value = ImageRecoveryVerificationV1(result: result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func recoveryDigest(
        _ planSHA256: String,
        remaining: [String]
    ) -> String {
        let value =
            "image-recovery:\(planSHA256):" +
            remaining.sorted().joined(separator: ",")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func hold(
        _ group: OperationGroupRecord,
        _ reason: String
    ) -> LifecycleRecoverySafeHold {
        LifecycleRecoverySafeHold(
            reason: reason,
            affectedNodeKeys: [group.id],
            operatorCommands: [
                "hostwright recovery --output json",
                "hostwright image inspect --output json"
            ]
        )
    }

    private func result(
        status: LifecycleSagaExecutionStatus,
        group: OperationGroupRecord,
        checkpoint: String,
        completed: [String]
    ) -> LifecycleSagaExecutionResult {
        LifecycleSagaExecutionResult(
            status: status,
            operationID: group.operationID,
            groupID: group.id,
            planSHA256: group.planHash,
            checkpoint: checkpoint,
            completedNodeKeys: completed,
            recoveryHintRedacted: "No further recovery is required."
        )
    }
}

private struct ImageRecoveryVerificationV1: Encodable {
    let version: Int
    let result: RuntimeImageOperationResult?

    init(result: RuntimeImageOperationResult?) {
        version = 1
        self.result = result
    }
}
