import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

struct ImageLifecycleInput: Codable, Equatable, Sendable {
    let operation: RuntimeImageLifecycleOperation
    let sourceReferences: [String]
    let targetReference: String?
    let contextPath: String?
    let dockerfilePath: String?
    let archivePath: String?
    let platform: String?
    let offline: Bool
    let noCache: Bool
    let exactPruneReferences: [String]?
    let expectedAbsentPruneReferences: [String]?
    let confirmedCachePlanSHA256: String?
    let expectedProviderID: RuntimeProviderID?
    let expectedCapabilitySHA256: String?

    init(
        operation: RuntimeImageLifecycleOperation,
        sourceReferences: [String] = [],
        targetReference: String? = nil,
        contextPath: String? = nil,
        dockerfilePath: String? = nil,
        archivePath: String? = nil,
        platform: String? = nil,
        offline: Bool = false,
        noCache: Bool = false,
        exactPruneReferences: [String]? = nil,
        expectedAbsentPruneReferences: [String]? = nil,
        confirmedCachePlanSHA256: String? = nil,
        expectedProviderID: RuntimeProviderID? = nil,
        expectedCapabilitySHA256: String? = nil
    ) {
        self.operation = operation
        self.sourceReferences = sourceReferences
        self.targetReference = targetReference
        self.contextPath = contextPath
        self.dockerfilePath = dockerfilePath
        self.archivePath = archivePath
        self.platform = platform
        self.offline = offline
        self.noCache = noCache
        self.exactPruneReferences =
            exactPruneReferences.map { Array(Set($0)).sorted() }
        self.expectedAbsentPruneReferences =
            expectedAbsentPruneReferences.map {
                Array(Set($0)).sorted()
            }
        self.confirmedCachePlanSHA256 = confirmedCachePlanSHA256
        self.expectedProviderID = expectedProviderID
        self.expectedCapabilitySHA256 =
            expectedCapabilitySHA256
    }
}

struct ImageLifecycleExecution: Sendable {
    let providerID: RuntimeProviderID
    let result: RuntimeImageOperationResult
    let createdReferences: [String]
    let deletedReferences: [String]
    let progress: [RuntimeImageProgressEvent]
}

struct ImageLifecycleCoordinator {
    let environment: CLIEnvironment
    let stateStoreConfiguration: StateStoreConfiguration

    func execute(
        input: ImageLifecycleInput,
        selection: RuntimeProviderSelection
    ) throws -> ImageLifecycleExecution {
        try hostwrightWaitForAsync {
            try await executeAsync(input: input, selection: selection)
        }
    }

    func executeAsyncForCache(
        input: ImageLifecycleInput,
        selection: RuntimeProviderSelection
    ) async throws -> ImageLifecycleExecution {
        try await executeAsync(
            input: input,
            selection: selection
        )
    }

    private func executeAsync(
        input: ImageLifecycleInput,
        selection: RuntimeProviderSelection
    ) async throws -> ImageLifecycleExecution {
        let selected = try await selectProvider(
            operation: input.operation,
            selection: selection
        )
        if let expectedProviderID = input.expectedProviderID {
            guard selected.providerID == expectedProviderID,
                  input.expectedCapabilitySHA256 ==
                    selected.capability.capabilitySHA256 else {
                throw HostwrightDiagnostic(
                    code: .imageConflict,
                    message:
                        "Image provider capability changed after cache-plan confirmation."
                )
            }
        } else if input.expectedCapabilitySHA256 != nil {
            throw HostwrightDiagnostic(
                code: .imageInvalid,
                message:
                    "Expected image capability requires one exact provider identity."
            )
        }
        let progress = ImageLifecycleProgressCollector()
        if input.operation == .inspect {
            let idempotencyKey = try inputSHA256(
                input: input,
                providerID: selected.providerID,
                effectiveReferences: input.sourceReferences.sorted(),
                removals: []
            )
            let request = try RuntimeImageLifecycleRequest(
                operation: .inspect,
                operationID: UUID().uuidString.lowercased(),
                idempotencyKey: idempotencyKey,
                capabilitySHA256: selected.capability.capabilitySHA256,
                sourceReferences: input.sourceReferences
            )
            let result = try await selected.provider.performImageOperation(
                request,
                confirmation: nil,
                progress: { event in
                    progress.append(event)
                }
            )
            return ImageLifecycleExecution(
                providerID: selected.providerID,
                result: result,
                createdReferences: [],
                deletedReferences: [],
                progress: progress.values
            )
        }

        let store = SQLiteStateStore(configuration: stateStoreConfiguration)
        try store.migrate()
        let inventory = try await selected.provider.inventory()
        let projection = try store.imageOwnership.load()
        let prepared = try prepare(
            input: input,
            providerID: selected.providerID,
            capability: selected.capability,
            inventory: inventory,
            projection: projection
        )
        try await ensurePreparedContentAccounting(
            prepared: prepared,
            inventory: inventory,
            projection: projection,
            providerID: selected.providerID,
            provider: selected.provider,
            capability: selected.capability,
            store: store
        )
        let group = try acquireGroup(
            prepared: prepared,
            providerID: selected.providerID,
            store: store
        )
        var contentLeases = try acquirePreparedContentLeases(
            prepared: prepared,
            providerID: selected.providerID,
            group: group,
            store: store
        )
        defer {
            releaseContentLeases(contentLeases, store: store)
        }
        do {
            let result: RuntimeImageOperationResult
            if prepared.request.sourceReferences.isEmpty,
               input.operation == .delete || input.operation == .prune {
                result = try await unchangedResult(
                    request: prepared.request,
                    providerID: selected.providerID,
                    provider: selected.provider,
                    deletedDigests:
                        prepared.provenAbsentDigests
                )
            } else {
                result = try await selected.provider.performImageOperation(
                    prepared.request,
                    confirmation: RuntimeMutationConfirmation(
                        confirmed: true,
                        reason: "Execute exact durable image lifecycle request.",
                        planHash: prepared.request.planSHA256()
                    ),
                    progress: { event in
                        progress.append(event)
                    }
                )
            }
            let changes = try ownershipChanges(
                prepared: prepared,
                result: result,
                providerID: selected.providerID
            )
            let createdLeases = try recordSuccessfulContent(
                prepared: prepared,
                group: group,
                result: result,
                changes: changes,
                providerID: selected.providerID,
                existingLeases: contentLeases,
                provenAbsentDigests:
                    prepared.provenAbsentDigests,
                store: store
            )
            contentLeases.append(contentsOf: createdLeases)
            try finishSucceeded(
                group: group,
                result: result,
                changes: changes,
                store: store
            )
            return ImageLifecycleExecution(
                providerID: selected.providerID,
                result: result,
                createdReferences: prepared.createdReferences,
                deletedReferences: prepared.removedOwnership.map(\.reference),
                progress: progress.values
            )
        } catch {
            let reportedPartialEffect =
                error as? RuntimeImagePartialEffectError
            if let recovered = try await recoverImmediateFailure(
                group: group,
                prepared: prepared,
                providerID: selected.providerID,
                provider: selected.provider,
                capability: selected.capability,
                reportedPartialEffect: reportedPartialEffect,
                store: store
            ) {
                try reconcileRecoveredDeletionAccounting(
                    prepared: prepared,
                    result: recovered,
                    providerID: selected.providerID,
                    leases: contentLeases,
                    store: store
                )
                return ImageLifecycleExecution(
                    providerID: selected.providerID,
                    result: recovered,
                    createdReferences: [],
                    deletedReferences: prepared.removedOwnership.map(\.reference),
                    progress: progress.values
                )
            }
            throw diagnostic(for: error)
        }
    }

    func selectProvider(
        operation: RuntimeImageLifecycleOperation,
        selection: RuntimeProviderSelection
    ) async throws -> SelectedImageProvider {
        let candidates = selection.explicitProviderID.map { [$0] } ?? [
            RuntimeProviderID.appleContainerCLI,
            .appleContainerization
        ]
        var explicitUnavailableReason: RuntimeImageOperationCapabilityReason?
        for providerID in candidates {
            do {
                let adapter = try environment.runtimeAdapterForProvider(providerID)
                guard let provider = adapter as? any RuntimeImageLifecycleProviding else {
                    continue
                }
                let capability = try await provider.imageOperationCapabilities()
                guard capability.providerID == providerID else {
                    continue
                }
                let status = capability.status(for: operation)
                guard status.state == .available,
                      status.reason == .implemented else {
                    explicitUnavailableReason = status.reason
                    continue
                }
                return SelectedImageProvider(
                    providerID: providerID,
                    provider: provider,
                    capability: capability
                )
            } catch {
                continue
            }
        }
        let detail = explicitUnavailableReason.map {
            " (\($0.rawValue))"
        } ?? ""
        throw HostwrightDiagnostic(
            code: .imageUnavailable,
            message:
                "No selected runtime provider implements image " +
                "\(operation.rawValue)\(detail); no effects were attempted."
        )
    }

    private func prepare(
        input: ImageLifecycleInput,
        providerID: RuntimeProviderID,
        capability: RuntimeImageOperationCapabilityContract,
        inventory: RuntimeInventory,
        projection: ImageOwnershipProjection
    ) throws -> PreparedImageLifecycle {
        let current = try currentReferences(inventory)
        let referenced = referencedContent(inventory: inventory, current: current)
        let createdReferences: [String]
        switch input.operation {
        case .pull, .load:
            createdReferences = input.sourceReferences
        case .build, .tag:
            createdReferences = [input.targetReference].compactMap { $0 }
        case .push, .save, .inspect, .delete, .prune:
            createdReferences = []
        }
        let collisions = createdReferences.filter { current[$0] != nil }
        guard collisions.isEmpty else {
            throw HostwrightDiagnostic(
                code: .imageConflict,
                message:
                    "Image creation refused existing references: " +
                    collisions.sorted().joined(separator: ", ") + "."
            )
        }
        if input.operation == .push ||
            input.operation == .tag ||
            input.operation == .save {
            let missing = input.sourceReferences.filter {
                current[$0] == nil
            }
            guard missing.isEmpty else {
                throw HostwrightDiagnostic(
                    code: .imageConflict,
                    message:
                        "Image source references are unavailable: " +
                        missing.sorted().joined(separator: ", ") + "."
                )
            }
        }

        var effectiveReferences = input.sourceReferences.sorted()
        var removals: [ImageIntentReference] = []
        if input.operation == .delete {
            for reference in input.sourceReferences.sorted() {
                guard let owned = projection.record(
                    forReference: reference,
                    providerID: providerID.rawValue
                ) else {
                    throw HostwrightDiagnostic(
                        code: .imageConflict,
                        message: "Image delete refused unmanaged reference '\(reference)'."
                    )
                }
                if let digest = current[reference] {
                    guard digest == owned.digest else {
                        throw HostwrightDiagnostic(
                            code: .imageConflict,
                            message:
                                "Image delete refused ownership mismatch for " +
                                "'\(reference)'."
                        )
                    }
                    guard !referenced.digests.contains(digest),
                          !referenced.references.contains(reference) else {
                        throw HostwrightDiagnostic(
                            code: .imageConflict,
                            message:
                                "Image delete refused content referenced by a live " +
                                "container: '\(reference)'."
                        )
                    }
                }
                removals.append(
                    ImageIntentReference(reference: reference, digest: owned.digest)
                )
            }
            effectiveReferences = input.sourceReferences.filter {
                current[$0] != nil
            }.sorted()
        } else if input.operation == .prune {
            effectiveReferences = []
            for owned in projection.records
                where owned.providerID == providerID.rawValue {
                if let digest = current[owned.reference] {
                    if digest != owned.digest {
                        throw HostwrightDiagnostic(
                            code: .imageConflict,
                            message:
                                "Image prune refused ownership mismatch for " +
                                "'\(owned.reference)'."
                        )
                    } else if !referenced.digests.contains(digest),
                              !referenced.references.contains(owned.reference) {
                        effectiveReferences.append(owned.reference)
                        removals.append(
                            ImageIntentReference(
                                reference: owned.reference,
                                digest: owned.digest
                            )
                        )
                    }
                } else {
                    removals.append(
                        ImageIntentReference(
                            reference: owned.reference,
                            digest: owned.digest
                        )
                    )
                }
            }
            effectiveReferences.sort()
            if let exactPruneReferences =
                input.exactPruneReferences {
                let exact = Set(exactPruneReferences)
                let removalReferences = Set(
                    removals.map(\.reference)
                )
                let expectedAbsent = Set(
                    input.expectedAbsentPruneReferences ?? []
                )
                guard !exact.isEmpty,
                      exact.count == exactPruneReferences.count,
                      exact.isSubset(of: removalReferences),
                      expectedAbsent.isSubset(of: exact),
                      expectedAbsent.allSatisfy({
                          current[$0] == nil
                      }),
                      input.confirmedCachePlanSHA256?.range(
                          of: "^[0-9a-f]{64}$",
                          options: .regularExpression
                      ) != nil else {
                    throw HostwrightDiagnostic(
                        code: .imageConflict,
                        message:
                            "Image prune candidates changed after the confirmed cache plan."
                    )
                }
                effectiveReferences = effectiveReferences.filter {
                    exact.contains($0)
                }.sorted()
                removals = removals.filter {
                    exact.contains($0.reference)
                }
            } else if input.confirmedCachePlanSHA256 != nil {
                throw HostwrightDiagnostic(
                    code: .imageInvalid,
                    message:
                        "Image prune confirmation requires exact planned references."
                )
            }
        }

        let platform = try RuntimeImageLifecycleContract.parsedPlatform(
            input.platform
        )
        let idempotencyKey = try inputSHA256(
            input: input,
            providerID: providerID,
            effectiveReferences: effectiveReferences,
            removals: removals
        )
        let expectedSourceDigests: [String: String]
        switch input.operation {
        case .push, .tag, .save:
            expectedSourceDigests = Dictionary(
                uniqueKeysWithValues: effectiveReferences.compactMap {
                    reference in
                    current[reference].map { (reference, $0) }
                }
            )
        case .delete, .prune:
            let effectiveSet = Set(effectiveReferences)
            expectedSourceDigests = Dictionary(
                uniqueKeysWithValues: removals.compactMap {
                    effectiveSet.contains($0.reference)
                        ? ($0.reference, $0.digest)
                        : nil
                }
            )
        case .pull, .build, .load, .inspect:
            expectedSourceDigests = [:]
        }
        let request = try RuntimeImageLifecycleRequest(
            operation: input.operation,
            operationID: UUID().uuidString.lowercased(),
            idempotencyKey: idempotencyKey,
            capabilitySHA256: capability.capabilitySHA256,
            sourceReferences: effectiveReferences,
            expectedSourceDigests: expectedSourceDigests,
            targetReference: input.operation == .push
                ? input.sourceReferences.first
                : input.targetReference,
            contextPath: input.contextPath,
            dockerfilePath: input.dockerfilePath,
            archivePath: input.archivePath,
            platformOS: platform.operatingSystem,
            platformArchitecture: platform.architecture,
            offline: input.offline,
            noCache: input.noCache
        )
        let currentDigests = Set(current.values)
        let provenAbsentDigests = Set(
            removals.compactMap {
                currentDigests.contains($0.digest)
                    ? nil
                    : $0.digest
            }
        ).sorted()
        return PreparedImageLifecycle(
            request: request,
            createdReferences: createdReferences.sorted(),
            priorReferences: input.sourceReferences.compactMap { reference in
                current[reference].map {
                    ImageIntentReference(reference: reference, digest: $0)
                }
            },
            removedOwnership: removals.sorted {
                ($0.reference, $0.digest) < ($1.reference, $1.digest)
            },
            provenAbsentDigests: provenAbsentDigests
        )
    }

    private func acquireGroup(
        prepared: PreparedImageLifecycle,
        providerID: RuntimeProviderID,
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        let timestamp = imageLifecycleTimestamp()
        let intent = ImageLifecycleIntentV1(
            providerID: providerID,
            request: prepared.request,
            createdReferences: prepared.createdReferences,
            priorReferences: prepared.priorReferences,
            removedOwnership: prepared.removedOwnership
        )
        let intentJSON = try intent.canonicalJSONString()
        let compensationJSON = try canonicalJSONString(
            [
                ImageLifecycleCompensationV1(
                    action: "delete-created-references",
                    references: prepared.createdReferences
                )
            ]
        )
        let emptyMetadata = try ImageOwnershipMetadataV1(
            changes: []
        ).canonicalJSONString()
        let group = OperationGroupRecord(
            id: prepared.request.operationID,
            operationID: prepared.request.operationID,
            groupKind: ImageOwnershipLedger.groupKind,
            projectID: "image-provider-\(providerID.rawValue)",
            serviceName: nil,
            plannedActionType: prepared.request.operation.rawValue,
            status: .active,
            groupIdempotencyKey:
                "\(ImageOwnershipLedger.groupKind):\(prepared.request.idempotencyKey)",
            planHash: try prepared.request.planSHA256(),
            checkpoint: "prepared",
            lockOwner: nil,
            lockExpiresAt: nil,
            rollbackAvailable: !prepared.createdReferences.isEmpty,
            manualRecoveryHintRedacted:
                "Resume or roll back only this exact fenced image lifecycle intent.",
            createdAt: timestamp,
            updatedAt: timestamp,
            metadataJSONRedacted: emptyMetadata,
            intentJSONRedacted: intentJSON,
            compensationJSONRedacted: compensationJSON,
            verificationJSONRedacted: "{}"
        )
        let acquired = try store.operationGroups.acquire(group)
        guard let record = acquired.acquired else {
            throw HostwrightDiagnostic(
                code: .imageConflict,
                message:
                    "Another image lifecycle operation with the same exact " +
                    "idempotency key is active."
            )
        }
        return record
    }

    private func finishSucceeded(
        group: OperationGroupRecord,
        result: RuntimeImageOperationResult,
        changes: [ImageOwnershipChangeV1],
        store: SQLiteStateStore
    ) throws {
        let timestamp = imageLifecycleTimestamp()
        let metadata = try ImageOwnershipMetadataV1(
            changes: changes
        ).canonicalJSONString()
        let verification = try canonicalJSONString(
            ImageLifecycleVerificationV1(result: result)
        )
        try appendStep(
            group: group,
            key: "provider-effect-verified",
            direction: .forward,
            status: .succeeded,
            metadata: verification,
            timestamp: timestamp,
            store: store
        )
        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: "provider-effect-verified",
            verificationJSONRedacted: verification,
            updatedAt: timestamp
        )
        try store.operationGroups.finish(
            groupID: group.id,
            status: .succeeded,
            checkpoint: "provider-effect-verified",
            manualRecoveryHintRedacted: "No recovery is required.",
            updatedAt: timestamp,
            metadataJSONRedacted: metadata
        )
    }

    private func recoverImmediateFailure(
        group: OperationGroupRecord,
        prepared: PreparedImageLifecycle,
        providerID: RuntimeProviderID,
        provider: any RuntimeImageLifecycleProviding,
        capability: RuntimeImageOperationCapabilityContract,
        reportedPartialEffect: RuntimeImagePartialEffectError?,
        store: SQLiteStateStore
    ) async throws -> RuntimeImageOperationResult? {
        let inventory: RuntimeInventory
        do {
            inventory = try await provider.inventory()
        } catch {
            try finishInterrupted(
                group: group,
                createdEvidence: reportedEvidence(
                    reportedPartialEffect,
                    prepared: prepared
                ),
                store: store
            )
            return nil
        }
        let current = try currentReferences(inventory)
        if prepared.request.operation == .delete ||
            prepared.request.operation == .prune {
            let remaining = prepared.request.sourceReferences.filter {
                current[$0] != nil
            }
            if remaining.isEmpty {
                let currentDigests = Set(current.values)
                let result = try await unchangedResult(
                    request: prepared.request,
                    providerID: providerID,
                    provider: provider,
                    deletedDigests:
                        prepared.removedOwnership.compactMap {
                            currentDigests.contains($0.digest)
                                ? nil
                                : $0.digest
                        }
                )
                let changes = try ownershipChanges(
                    prepared: prepared,
                    result: result,
                    providerID: providerID
                )
                try finishSucceeded(
                    group: group,
                    result: result,
                    changes: changes,
                    store: store
                )
                return result
            }
            try finishInterrupted(group: group, store: store)
            return nil
        }

        let priorReferences = Set(prepared.priorReferences.map(\.reference))
        var createdEvidence = prepared.createdReferences.compactMap {
            reference -> ImageIntentReference? in
            guard let digest = current[reference],
                  !priorReferences.contains(reference) else {
                return nil
            }
            return ImageIntentReference(
                reference: reference,
                digest: digest
            )
        }
        if let reportedPartialEffect {
            for effect in reportedPartialEffect.createdReferences {
                guard current[effect.reference] == effect.digest,
                      !priorReferences.contains(effect.reference) else {
                    continue
                }
                if !createdEvidence.contains(where: {
                    $0.reference == effect.reference
                }) {
                    createdEvidence.append(
                        ImageIntentReference(
                            reference: effect.reference,
                            digest: effect.digest
                        )
                    )
                }
            }
        }
        createdEvidence.sort {
            ($0.reference, $0.digest) < ($1.reference, $1.digest)
        }
        let createdNow = createdEvidence.map(\.reference)
        if !createdNow.isEmpty {
            do {
                let cleanup = try RuntimeImageLifecycleRequest(
                    operation: .delete,
                    operationID: UUID().uuidString.lowercased(),
                    idempotencyKey: sha256(
                        "rollback:\(group.planHash):\(createdNow.joined(separator: ","))"
                    ),
                    capabilitySHA256: capability.capabilitySHA256,
                    sourceReferences: createdNow,
                    expectedSourceDigests: Dictionary(
                        uniqueKeysWithValues: createdEvidence.map {
                            ($0.reference, $0.digest)
                        }
                    )
                )
                _ = try await provider.performImageOperation(
                    cleanup,
                    confirmation: RuntimeMutationConfirmation(
                        confirmed: true,
                        reason: "Compensate exact references created by failed image intent.",
                        planHash: cleanup.planSHA256()
                    ),
                    progress: { _ in }
                )
                if reportedPartialEffect?.unrestorableChange == true {
                    try finishInterrupted(group: group, store: store)
                } else {
                    try finishFailed(
                        group: group,
                        checkpoint: "rolled-back",
                        direction: .rollback,
                        store: store
                    )
                }
            } catch {
                try finishInterrupted(
                    group: group,
                    createdEvidence: createdEvidence,
                    store: store
                )
            }
            return nil
        }

        if reportedPartialEffect?.unrestorableChange == true {
            try finishInterrupted(group: group, store: store)
            return nil
        }

        if prepared.request.operation == .save,
           let archivePath = prepared.request.archivePath {
            do {
                let removed = try removeExactOwnedImageArchiveIfPresent(
                    archivePath
                )
                try finishFailed(
                    group: group,
                    checkpoint: removed
                        ? "rolled-back"
                        : "failed-before-observed-effect",
                    direction: removed ? .rollback : .forward,
                    store: store
                )
            } catch {
                try finishInterrupted(group: group, store: store)
            }
        } else if prepared.request.operation == .push {
            try finishInterrupted(group: group, store: store)
        } else {
            try finishFailed(
                group: group,
                checkpoint: "failed-before-observed-effect",
                direction: .forward,
                store: store
            )
        }
        return nil
    }

    private func reportedEvidence(
        _ reportedPartialEffect: RuntimeImagePartialEffectError?,
        prepared: PreparedImageLifecycle
    ) -> [ImageIntentReference] {
        guard let reportedPartialEffect,
              reportedPartialEffect.operation == prepared.request.operation
        else {
            return []
        }
        let priorReferences = Set(prepared.priorReferences.map(\.reference))
        let declaredCreatedReferences = Set(prepared.createdReferences)
        return reportedPartialEffect.createdReferences.compactMap { effect in
            guard !priorReferences.contains(effect.reference),
                  prepared.request.operation == .load ||
                    declaredCreatedReferences.contains(effect.reference)
            else {
                return nil
            }
            return ImageIntentReference(
                reference: effect.reference,
                digest: effect.digest
            )
        }
    }

    private func finishFailed(
        group: OperationGroupRecord,
        checkpoint: String,
        direction: OperationGroupStepDirection,
        store: SQLiteStateStore
    ) throws {
        let timestamp = imageLifecycleTimestamp()
        let metadata = try ImageOwnershipMetadataV1(
            changes: []
        ).canonicalJSONString()
        try appendStep(
            group: group,
            key: checkpoint,
            direction: direction,
            status: .failed,
            metadata: "{}",
            timestamp: timestamp,
            store: store
        )
        try store.operationGroups.finish(
            groupID: group.id,
            status: .failed,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted:
                checkpoint == "rolled-back"
                    ? "Exact created references were removed; no recovery is required."
                    : "No provider effect was observed; retry with a new exact request.",
            updatedAt: timestamp,
            metadataJSONRedacted: metadata
        )
    }

    private func finishInterrupted(
        group: OperationGroupRecord,
        createdEvidence: [ImageIntentReference] = [],
        store: SQLiteStateStore
    ) throws {
        let timestamp = imageLifecycleTimestamp()
        let metadata = try ImageOwnershipMetadataV1(
            changes: []
        ).canonicalJSONString()
        let verification = createdEvidence.isEmpty
            ? "{}"
            : try ImageLifecyclePartialEffectEvidenceV1(
                createdReferences: createdEvidence
            ).canonicalJSONString()
        try appendStep(
            group: group,
            key: "partial-effect-safe-hold",
            direction: .forward,
            status: .failed,
            metadata: verification,
            timestamp: timestamp,
            store: store
        )
        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: "partial-effect-safe-hold",
            verificationJSONRedacted: verification,
            updatedAt: timestamp
        )
        try store.operationGroups.finish(
            groupID: group.id,
            status: .interrupted,
            checkpoint: "partial-effect-safe-hold",
            manualRecoveryHintRedacted:
                "Confirm the persisted plan hash, then resume or roll back this exact image intent.",
            updatedAt: timestamp,
            metadataJSONRedacted: metadata
        )
    }

    private func appendStep(
        group: OperationGroupRecord,
        key: String,
        direction: OperationGroupStepDirection,
        status: OperationGroupStepStatus,
        metadata: String,
        timestamp: String,
        store: SQLiteStateStore
    ) throws {
        try store.operationGroupSteps.append(
            OperationGroupStepRecord(
                id: "image-step-\(UUID().uuidString.lowercased())",
                groupID: group.id,
                stepKey: key,
                direction: direction,
                plannedActionType: group.plannedActionType,
                serviceName: nil,
                resourceIdentifier: nil,
                stepIdempotencyKey: "\(group.planHash):\(direction.rawValue):\(key)",
                status: status,
                startedAt: timestamp,
                updatedAt: timestamp,
                finishedAt: timestamp,
                lastErrorRedacted: status == .failed
                    ? "Image lifecycle step did not complete."
                    : nil,
                manualRecoveryHintRedacted:
                    status == .succeeded
                        ? "No recovery is required."
                        : "Use only the exact persisted image recovery intent.",
                metadataJSONRedacted: metadata
            ),
            expectedFencingToken: group.fencingToken
        )
    }

    private func ownershipChanges(
        prepared: PreparedImageLifecycle,
        result: RuntimeImageOperationResult,
        providerID: RuntimeProviderID
    ) throws -> [ImageOwnershipChangeV1] {
        var changes = try prepared.removedOwnership.map {
            try ImageOwnershipChangeV1(
                action: .remove,
                reference: $0.reference,
                digest: $0.digest,
                providerID: providerID.rawValue
            )
        }
        for reference in prepared.createdReferences {
            let matches = result.images.filter {
                $0.references.contains(reference)
            }
            guard matches.count == 1 else {
                throw HostwrightDiagnostic(
                    code: .imagePartialEffect,
                    message:
                        "The provider result did not prove one immutable digest " +
                        "for created reference '\(reference)'."
                )
            }
            changes.append(
                try ImageOwnershipChangeV1(
                    action: .add,
                    reference: reference,
                    digest: matches[0].digest,
                    providerID: providerID.rawValue
                )
            )
        }
        return changes
    }

    private func unchangedResult(
        request: RuntimeImageLifecycleRequest,
        providerID: RuntimeProviderID,
        provider: any RuntimeImageLifecycleProviding,
        deletedDigests: [String] = []
    ) async throws -> RuntimeImageOperationResult {
        try RuntimeImageOperationResult(
            operation: request.operation,
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            planSHA256: request.planSHA256(),
            providerID: providerID,
            providerVersion: try await provider.runtimeVersion(),
            disposition: .unchanged,
            images: [],
            deletedDigests: Array(Set(deletedDigests)).sorted()
        )
    }

    private func ensurePreparedContentAccounting(
        prepared: PreparedImageLifecycle,
        inventory: RuntimeInventory,
        projection: ImageOwnershipProjection,
        providerID: RuntimeProviderID,
        provider: any RuntimeImageLifecycleProviding,
        capability: RuntimeImageOperationCapabilityContract,
        store: SQLiteStateStore
    ) async throws {
        let timestamp = imageLifecycleTimestamp()
        let snapshot = try store.contentCache.snapshot(
            providerScope: providerID.rawValue,
            currentTimestamp: timestamp,
            limit: ImageCacheLimits.maximumRecords
        )
        let existingByDigest = Dictionary(
            uniqueKeysWithValues: snapshot.contents.map {
                ($0.digest, $0)
            }
        )
        let existingReferences = Dictionary(
            uniqueKeysWithValues: snapshot.references.map {
                ($0.reference, $0)
            }
        )
        let current = try currentReferences(inventory)
        let requestedReferences = Set(
            prepared.request.expectedSourceDigests.keys
        ).union(prepared.removedOwnership.map(\.reference))
        let referencesByDigest = Dictionary(
            grouping: requestedReferences.compactMap {
                reference -> (reference: String, digest: String)? in
                current[reference].map { (reference, $0) }
            },
            by: \.digest
        )
        let missingRepresentatives = referencesByDigest.compactMap {
            digest, references -> (String, String)? in
            guard existingByDigest[digest] == nil,
                  let reference = references
                    .map(\.reference)
                    .sorted()
                    .first else {
                return nil
            }
            return (digest, reference)
        }.sorted { $0.0 < $1.0 }
        var inspectedByDigest: [String: RuntimeImageRecord] = [:]
        if !missingRepresentatives.isEmpty {
            guard capability.status(for: .inspect).state == .available,
                  capability.status(for: .inspect).reason == .implemented
            else {
                throw HostwrightDiagnostic(
                    code: .imageUnavailable,
                    message:
                        "Exact content size observation is unavailable before image mutation."
                )
            }
            for start in stride(
                from: 0,
                to: missingRepresentatives.count,
                by:
                    RuntimeImageLifecycleLimits
                        .maximumSourceReferencesPerRequest
            ) {
                let end = min(
                    start +
                        RuntimeImageLifecycleLimits
                            .maximumSourceReferencesPerRequest,
                    missingRepresentatives.count
                )
                let batch = Array(
                    missingRepresentatives[start..<end]
                )
                let references = batch.map(\.1)
                let idempotencyKey = sha256(
                    [
                        "content-accounting-inspect",
                        providerID.rawValue,
                        references.joined(separator: ",")
                    ].joined(separator: "\u{1f}")
                )
                let request = try RuntimeImageLifecycleRequest(
                    operation: .inspect,
                    operationID:
                        UUID().uuidString.lowercased(),
                    idempotencyKey: idempotencyKey,
                    capabilitySHA256:
                        capability.capabilitySHA256,
                    sourceReferences: references
                )
                let result = try await provider.performImageOperation(
                    request,
                    confirmation: nil,
                    progress: { _ in }
                )
                for image in result.images {
                    inspectedByDigest[image.digest] = image
                }
            }
        }

        for (digest, references) in referencesByDigest.sorted(
            by: { $0.key < $1.key }
        ) {
            let existing = existingByDigest[digest]
            guard let sizeBytes = existing?.sizeBytes ??
                    inspectedByDigest[digest]?.sizeBytes else {
                throw HostwrightDiagnostic(
                    code: .imageUnavailable,
                    message:
                        "Runtime inspection did not return exact size accounting for owned content."
                )
            }
            try store.contentCache.upsert(
                ContentCacheRecord(
                    providerScope: providerID.rawValue,
                    digest: digest,
                    kind: .runtimeImage,
                    sizeBytes: sizeBytes,
                    pinPolicy: existing?.pinPolicy ?? .unpinned,
                    createdAt: existing?.createdAt ?? timestamp,
                    observedAt: timestamp,
                    lastUsedAt: existing?.lastUsedAt ?? timestamp
                )
            )
            for reference in references.map(\.reference).sorted() {
                guard let ownership = projection.record(
                    forReference: reference,
                    providerID: providerID.rawValue
                ), ownership.digest == digest else {
                    continue
                }
                try saveContentReference(
                    ownership,
                    existing: existingReferences[ownership.reference],
                    observedAt: timestamp,
                    store: store
                )
            }
        }
    }

    private func acquirePreparedContentLeases(
        prepared: PreparedImageLifecycle,
        providerID: RuntimeProviderID,
        group: OperationGroupRecord,
        store: SQLiteStateStore
    ) throws -> [ContentCacheLeaseRecord] {
        let timestamp = imageLifecycleTimestamp()
        let expiresAt = hostwrightTimestampAdding(
            seconds: 86_400,
            to: timestamp
        )
        var acquired: [ContentCacheLeaseRecord] = []
        do {
            switch prepared.request.operation {
            case .push, .tag, .save:
                let references = try store.contentCache.listReferences(
                    providerScope: providerID.rawValue,
                    limit: ImageCacheLimits.maximumRecords
                )
                let mapped = Dictionary(
                    uniqueKeysWithValues: references.map {
                        ($0.reference, $0.digest)
                    }
                )
                for (reference, digest) in
                    prepared.request.expectedSourceDigests.sorted(
                        by: { $0.key < $1.key }
                    ) {
                    acquired.append(
                        try store.contentCache.acquireLease(
                            providerScope: providerID.rawValue,
                            digest: digest,
                            reference: mapped[reference] == digest
                                ? reference
                                : nil,
                            mode: .shared,
                            ownerID: group.id,
                            purpose:
                                "image-\(prepared.request.operation.rawValue)",
                            acquiredAt: timestamp,
                            expiresAt: expiresAt
                        )
                    )
                }
            case .delete, .prune:
                let contentDigests = Set(
                    try store.contentCache.listContent(
                        providerScope: providerID.rawValue,
                        limit: ImageCacheLimits.maximumRecords
                    ).map(\.digest)
                )
                let digests = Set(
                    prepared.removedOwnership.map(\.digest)
                )
                for digest in digests.sorted()
                    where contentDigests.contains(digest) {
                    acquired.append(
                        try store.contentCache.acquireLease(
                            providerScope: providerID.rawValue,
                            digest: digest,
                            mode: .exclusiveDelete,
                            ownerID: group.id,
                            purpose:
                                "image-\(prepared.request.operation.rawValue)",
                            acquiredAt: timestamp,
                            expiresAt: expiresAt
                        )
                    )
                }
            case .pull, .build, .load, .inspect:
                break
            }
            return acquired
        } catch {
            releaseContentLeases(acquired, store: store)
            throw error
        }
    }

    private func recordSuccessfulContent(
        prepared: PreparedImageLifecycle,
        group: OperationGroupRecord,
        result: RuntimeImageOperationResult,
        changes: [ImageOwnershipChangeV1],
        providerID: RuntimeProviderID,
        existingLeases: [ContentCacheLeaseRecord],
        provenAbsentDigests: [String],
        store: SQLiteStateStore
    ) throws -> [ContentCacheLeaseRecord] {
        let timestamp = imageLifecycleTimestamp()
        let snapshot = try store.contentCache.snapshot(
            providerScope: providerID.rawValue,
            currentTimestamp: timestamp,
            limit: ImageCacheLimits.maximumRecords
        )
        var existingByDigest = Dictionary(
            uniqueKeysWithValues: snapshot.contents.map {
                ($0.digest, $0)
            }
        )
        var existingReferences = Dictionary(
            uniqueKeysWithValues: snapshot.references.map {
                ($0.reference, $0)
            }
        )
        for image in result.images {
            let existing = existingByDigest[image.digest]
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
            existingByDigest[image.digest] = record
        }

        var createdLeases: [ContentCacheLeaseRecord] = []
        do {
            for change in changes where change.action == .add {
                guard existingByDigest[change.digest] != nil else {
                    continue
                }
                let ownership = ImageOwnershipRecord(
                    reference: change.reference,
                    digest: change.digest,
                    providerID: change.providerID,
                    ownershipOperationID: group.id,
                    ownershipProofSHA256: contentOwnershipProof(
                        group: group,
                        change: change
                    )
                )
                try saveContentReference(
                    ownership,
                    existing: existingReferences[change.reference],
                    observedAt: timestamp,
                    store: store
                )
                let refreshed = try store.contentCache.listReferences(
                    providerScope: providerID.rawValue,
                    digest: change.digest,
                    limit:
                        RuntimeImageLifecycleLimits
                            .maximumSourceReferencesPerRequest
                )
                existingReferences = Dictionary(
                    uniqueKeysWithValues: refreshed.map {
                        ($0.reference, $0)
                    }
                )
                createdLeases.append(
                    try store.contentCache.acquireLease(
                        providerScope: providerID.rawValue,
                        digest: change.digest,
                        reference: change.reference,
                        mode: .shared,
                        ownerID: group.id,
                        purpose: "image-create",
                        acquiredAt: timestamp,
                        expiresAt: hostwrightTimestampAdding(
                            seconds: 86_400,
                            to: timestamp
                        )
                    )
                )
            }
            try removeVerifiedContentAccounting(
                changes: changes,
                result: result,
                providerID: providerID,
                leases: existingLeases,
                provenAbsentDigests:
                    provenAbsentDigests,
                store: store
            )
            return createdLeases
        } catch {
            releaseContentLeases(createdLeases, store: store)
            throw error
        }
    }

    private func reconcileRecoveredDeletionAccounting(
        prepared: PreparedImageLifecycle,
        result: RuntimeImageOperationResult,
        providerID: RuntimeProviderID,
        leases: [ContentCacheLeaseRecord],
        store: SQLiteStateStore
    ) throws {
        guard prepared.request.operation == .delete ||
                prepared.request.operation == .prune else {
            return
        }
        var changes: [ImageOwnershipChangeV1] = []
        for removal in prepared.removedOwnership {
            changes.append(
                try ImageOwnershipChangeV1(
                    action: .remove,
                    reference: removal.reference,
                    digest: removal.digest,
                    providerID: providerID.rawValue
                )
            )
        }
        try removeVerifiedContentAccounting(
            changes: changes,
            result: result,
            providerID: providerID,
            leases: leases,
            provenAbsentDigests:
                prepared.provenAbsentDigests,
            store: store
        )
    }

    private func removeVerifiedContentAccounting(
        changes: [ImageOwnershipChangeV1],
        result: RuntimeImageOperationResult,
        providerID: RuntimeProviderID,
        leases: [ContentCacheLeaseRecord],
        provenAbsentDigests: [String],
        store: SQLiteStateStore
    ) throws {
        let removals = changes.filter { $0.action == .remove }
        guard !removals.isEmpty else { return }
        let timestamp = imageLifecycleTimestamp()
        var snapshot = try store.contentCache.snapshot(
            providerScope: providerID.rawValue,
            currentTimestamp: timestamp,
            limit: ImageCacheLimits.maximumRecords
        )
        for removal in removals {
            guard let reference = snapshot.references.first(where: {
                $0.providerScope == providerID.rawValue &&
                    $0.reference == removal.reference &&
                    $0.digest == removal.digest
            }) else {
                continue
            }
            guard let lease = leases.first(where: {
                $0.providerScope == providerID.rawValue &&
                    $0.digest == removal.digest &&
                    $0.mode == .exclusiveDelete
            }) else {
                throw HostwrightDiagnostic(
                    code: .imageConflict,
                    message:
                        "Verified image deletion lost its exact exclusive content lease."
                )
            }
            guard try store.contentCache.removeReferenceUnderLease(
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
                throw HostwrightDiagnostic(
                    code: .imagePartialEffect,
                    message:
                        "Verified image deletion could not remove exact cache ownership accounting."
                )
            }
            snapshot = try store.contentCache.snapshot(
                providerScope: providerID.rawValue,
                currentTimestamp: timestamp,
                limit: ImageCacheLimits.maximumRecords
            )
        }
        let deletedDigests = Set(result.deletedDigests)
            .union(provenAbsentDigests)
        for digest in Set(removals.map(\.digest)).sorted()
            where deletedDigests.contains(digest) &&
                !snapshot.references.contains(where: {
                    $0.providerScope == providerID.rawValue &&
                        $0.digest == digest
                }) {
            guard let content = snapshot.contents.first(where: {
                $0.providerScope == providerID.rawValue &&
                    $0.digest == digest
            }),
            let lease = leases.first(where: {
                $0.providerScope == providerID.rawValue &&
                    $0.digest == digest &&
                    $0.mode == .exclusiveDelete
            }) else {
                continue
            }
            guard try store.contentCache.removeContent(
                providerScope: providerID.rawValue,
                digest: digest,
                expectedKind: .runtimeImage,
                expectedSizeBytes: content.sizeBytes,
                expectedCreatedAt: content.createdAt,
                exclusiveLeaseID: lease.id,
                expectedFencingToken: lease.fencingToken,
                removedAt: timestamp
            ) else {
                throw HostwrightDiagnostic(
                    code: .imagePartialEffect,
                    message:
                        "Verified image deletion could not remove exact content accounting."
                )
            }
        }
    }

    private func saveContentReference(
        _ ownership: ImageOwnershipRecord,
        existing: ContentCacheReferenceRecord?,
        observedAt: String,
        store: SQLiteStateStore
    ) throws {
        guard let ownershipOperationID =
                ownership.ownershipOperationID,
              let ownershipProofSHA256 =
                ownership.ownershipProofSHA256 else {
            throw HostwrightDiagnostic(
                code: .imageConflict,
                message:
                    "Image cache accounting requires exact ownership provenance."
            )
        }
        if let existing,
           existing.digest != ownership.digest ||
            existing.ownershipOperationID != ownershipOperationID ||
            existing.ownershipProofSHA256 != ownershipProofSHA256 {
            throw HostwrightDiagnostic(
                code: .imageConflict,
                message:
                    "Image cache ownership changed during accounting."
            )
        }
        let record = ContentCacheReferenceRecord(
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
        try store.contentCache.saveReference(record)
    }

    private func contentOwnershipProof(
        group: OperationGroupRecord,
        change: ImageOwnershipChangeV1
    ) -> String {
        sha256(
            [
                group.id,
                group.planHash,
                change.action.rawValue,
                change.providerID,
                change.reference,
                change.digest
            ].joined(separator: "\u{1f}")
        )
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
        var result: [String: String] = [:]
        for image in inventory.images {
            for reference in image.references {
                if let existing = result[reference],
                   existing != image.descriptorDigest {
                    throw HostwrightDiagnostic(
                        code: .imageConflict,
                        message:
                            "Runtime inventory returned conflicting digests for " +
                            "one image reference."
                    )
                }
                result[reference] = image.descriptorDigest
            }
        }
        return result
    }

    private func referencedContent(
        inventory: RuntimeInventory,
        current: [String: String]
    ) -> (digests: Set<String>, references: Set<String>) {
        var digests = Set(inventory.containers.compactMap(\.imageID))
        let references = Set(inventory.containers.map(\.imageReference))
        for reference in references {
            if let digest = current[reference] {
                digests.insert(digest)
            }
        }
        return (digests, references)
    }

    private func inputSHA256(
        input: ImageLifecycleInput,
        providerID: RuntimeProviderID,
        effectiveReferences: [String],
        removals: [ImageIntentReference]
    ) throws -> String {
        let seed = ImageLifecycleIdempotencySeed(
            providerID: providerID,
            input: input,
            effectiveReferences: effectiveReferences,
            removals: removals
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(String(decoding: try encoder.encode(seed), as: UTF8.self))
    }

    private func diagnostic(for error: Error) -> HostwrightDiagnostic {
        if let diagnostic = error as? HostwrightDiagnostic {
            return diagnostic
        }
        if error is CancellationError {
            return HostwrightDiagnostic(
                code: .imageCancelled,
                message: "The image lifecycle operation was cancelled."
            )
        }
        if let runtimeError = error as? RuntimeAdapterError {
            switch runtimeError {
            case .commandCancelled:
                return HostwrightDiagnostic(
                    code: .imageCancelled,
                    message: "The image lifecycle operation was cancelled."
                )
            case .commandRejected, .mutationUnavailableByPolicy:
                return HostwrightDiagnostic(
                    code: .imageDenied,
                    message:
                        "The runtime provider rejected the exact image lifecycle request."
                )
            case .commandTimedOut, .commandProcessTreeViolation:
                return HostwrightDiagnostic(
                    code: .imagePartialEffect,
                    message:
                        "The bounded runtime operation stopped with an uncertain effect; " +
                        "inspect the durable recovery record."
                )
            default:
                return HostwrightDiagnostic(
                    code: .imageUnavailable,
                    message:
                        "The runtime provider could not complete the image lifecycle request."
                )
            }
        }
        return HostwrightDiagnostic(
            code: .imageUnavailable,
            message: "The image lifecycle operation could not complete."
        )
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func canonicalJSONString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

struct SelectedImageProvider: Sendable {
    let providerID: RuntimeProviderID
    let provider: any RuntimeImageLifecycleProviding
    let capability: RuntimeImageOperationCapabilityContract
}

private struct PreparedImageLifecycle: Sendable {
    let request: RuntimeImageLifecycleRequest
    let createdReferences: [String]
    let priorReferences: [ImageIntentReference]
    let removedOwnership: [ImageIntentReference]
    let provenAbsentDigests: [String]
}

struct ImageIntentReference: Codable, Equatable, Sendable {
    let reference: String
    let digest: String
}

struct ImageLifecyclePartialEffectEvidenceV1:
    Codable,
    Equatable,
    Sendable
{
    static let currentVersion = 1

    let version: Int
    let createdReferences: [ImageIntentReference]

    init(
        version: Int = currentVersion,
        createdReferences: [ImageIntentReference]
    ) throws {
        let sorted = createdReferences.sorted {
            ($0.reference, $0.digest) < ($1.reference, $1.digest)
        }
        guard version == Self.currentVersion,
              !sorted.isEmpty,
              sorted.count <=
                RuntimeImageLifecycleLimits.maximumSourceReferencesPerRequest,
              Set(sorted.map(\.reference)).count == sorted.count else {
            throw HostwrightDiagnostic(
                code: .imageInvalid,
                message: "Partial image effect evidence is invalid."
            )
        }
        for item in sorted {
            _ = try RuntimeImageLifecycleContract.validatedReference(
                item.reference
            )
            _ = try RuntimeImageLifecycleContract.validatedDigest(item.digest)
        }
        self.version = version
        self.createdReferences = sorted
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case createdReferences
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: try values.decode(Int.self, forKey: .version),
            createdReferences: try values.decode(
                [ImageIntentReference].self,
                forKey: .createdReferences
            )
        )
    }

    func canonicalJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decodeStrict(
        _ value: String
    ) throws -> ImageLifecyclePartialEffectEvidenceV1 {
        guard let data = value.data(using: .utf8),
              data.count <= RuntimeImageLifecycleLimits.maximumRequestBytes,
              let decoded = try? JSONDecoder().decode(
                  ImageLifecyclePartialEffectEvidenceV1.self,
                  from: data
              ),
              let rawObject = try? JSONSerialization.jsonObject(with: data),
              let canonicalData = try? decoded.canonicalJSONString().data(
                  using: .utf8
              ),
              let canonicalObject = try? JSONSerialization.jsonObject(
                  with: canonicalData
              ),
              NSDictionary(dictionary: rawObject as? [String: Any] ?? [:])
                .isEqual(
                    to: canonicalObject as? [String: Any] ?? [:]
                ) else {
            throw HostwrightDiagnostic(
                code: .imageInvalid,
                message: "Partial image effect evidence is malformed."
            )
        }
        return decoded
    }
}

struct ImageLifecycleIntentV1: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let providerID: RuntimeProviderID
    let request: RuntimeImageLifecycleRequest
    let createdReferences: [String]
    let priorReferences: [ImageIntentReference]
    let removedOwnership: [ImageIntentReference]

    init(
        version: Int = currentVersion,
        providerID: RuntimeProviderID,
        request: RuntimeImageLifecycleRequest,
        createdReferences: [String],
        priorReferences: [ImageIntentReference],
        removedOwnership: [ImageIntentReference]
    ) {
        self.version = version
        self.providerID = providerID
        self.request = request
        self.createdReferences = createdReferences.sorted()
        self.priorReferences = priorReferences.sorted {
            ($0.reference, $0.digest) < ($1.reference, $1.digest)
        }
        self.removedOwnership = removedOwnership.sorted {
            ($0.reference, $0.digest) < ($1.reference, $1.digest)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case providerID
        case requestBase64
        case requestPlanSHA256
        case createdReferences
        case priorReferences
        case removedOwnership
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let requestBase64 = try values.decode(
            String.self,
            forKey: .requestBase64
        )
        guard let requestData = Data(base64Encoded: requestBase64),
              requestData.base64EncodedString() == requestBase64 else {
            throw HostwrightDiagnostic(
                code: .imageInvalid,
                message: "Persisted image request encoding is invalid."
            )
        }
        let request = try JSONDecoder().decode(
            RuntimeImageLifecycleRequest.self,
            from: requestData
        )
        let requestPlanSHA256 = try values.decode(
            String.self,
            forKey: .requestPlanSHA256
        )
        guard try request.planSHA256() == requestPlanSHA256 else {
            throw HostwrightDiagnostic(
                code: .imageInvalid,
                message: "Persisted image request digest does not match."
            )
        }
        self.init(
            version: try values.decode(Int.self, forKey: .version),
            providerID: try values.decode(
                RuntimeProviderID.self,
                forKey: .providerID
            ),
            request: request,
            createdReferences: try values.decode(
                [String].self,
                forKey: .createdReferences
            ),
            priorReferences: try values.decode(
                [ImageIntentReference].self,
                forKey: .priorReferences
            ),
            removedOwnership: try values.decode(
                [ImageIntentReference].self,
                forKey: .removedOwnership
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(providerID, forKey: .providerID)
        try values.encode(
            try request.canonicalJSONData().base64EncodedString(),
            forKey: .requestBase64
        )
        try values.encode(
            request.planSHA256(),
            forKey: .requestPlanSHA256
        )
        try values.encode(createdReferences, forKey: .createdReferences)
        try values.encode(priorReferences, forKey: .priorReferences)
        try values.encode(removedOwnership, forKey: .removedOwnership)
    }

    func canonicalJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decodeStrict(_ value: String) throws -> ImageLifecycleIntentV1 {
        guard let data = value.data(using: .utf8),
              data.count <= RuntimeImageLifecycleLimits.maximumRequestBytes,
              let decoded = try? JSONDecoder().decode(
                  ImageLifecycleIntentV1.self,
                  from: data
              ),
              let rawObject = try? JSONSerialization.jsonObject(with: data),
              let canonicalData = try? decoded.canonicalJSONString().data(
                  using: .utf8
              ),
              let canonicalObject = try? JSONSerialization.jsonObject(
                  with: canonicalData
              ),
              decoded.version == currentVersion,
              RuntimeProviderID.knownValues.contains(decoded.providerID),
              Set(decoded.createdReferences).count ==
                decoded.createdReferences.count,
              Set(decoded.priorReferences.map(\.reference)).count ==
                decoded.priorReferences.count,
              Set(decoded.removedOwnership.map(\.reference)).count ==
                decoded.removedOwnership.count,
              NSDictionary(dictionary: rawObject as? [String: Any] ?? [:])
                .isEqual(
                    to: canonicalObject as? [String: Any] ?? [:]
                ) else {
            throw HostwrightDiagnostic(
                code: .imageInvalid,
                message:
                    "Persisted image lifecycle intent is malformed or non-canonical."
            )
        }
        return decoded
    }
}

private struct ImageLifecycleIdempotencySeed: Codable {
    let providerID: RuntimeProviderID
    let input: ImageLifecycleInput
    let effectiveReferences: [String]
    let removals: [ImageIntentReference]
}

private struct ImageLifecycleCompensationV1: Encodable {
    let version = 1
    let action: String
    let references: [String]
}

private struct ImageLifecycleVerificationV1: Encodable {
    let version = 1
    let result: RuntimeImageOperationResult
}

private final class ImageLifecycleProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RuntimeImageProgressEvent] = []

    func append(_ event: RuntimeImageProgressEvent) {
        lock.lock()
        defer { lock.unlock() }
        if events.count < RuntimeImageLifecycleLimits.maximumProgressEvents {
            events.append(event)
        }
    }

    var values: [RuntimeImageProgressEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

func imageLifecycleTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [
        .withInternetDateTime,
        .withFractionalSeconds
    ]
    return formatter.string(from: Date())
}

@discardableResult
func removeExactOwnedImageArchiveIfPresent(_ path: String) throws -> Bool {
    _ = try RuntimeImageLifecycleContract.validatedAbsolutePath(path)
    var pathMetadata = stat()
    guard lstat(path, &pathMetadata) == 0 else {
        if errno == ENOENT {
            return false
        }
        throw HostwrightDiagnostic(
            code: .imageDenied,
            message: "Exact image archive cleanup could not inspect its target."
        )
    }
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw HostwrightDiagnostic(
            code: .imageDenied,
            message: "Exact image archive cleanup refused its target."
        )
    }
    defer { close(descriptor) }
    var descriptorMetadata = stat()
    guard fstat(descriptor, &descriptorMetadata) == 0,
          (descriptorMetadata.st_mode & S_IFMT) == S_IFREG,
          descriptorMetadata.st_uid == geteuid(),
          descriptorMetadata.st_nlink == 1,
          descriptorMetadata.st_mode &
            (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0,
          descriptorMetadata.st_dev == pathMetadata.st_dev,
          descriptorMetadata.st_ino == pathMetadata.st_ino else {
        throw HostwrightDiagnostic(
            code: .imageDenied,
            message:
                "Exact image archive cleanup refused unsafe ownership or identity."
        )
    }
    var currentMetadata = stat()
    guard lstat(path, &currentMetadata) == 0,
          currentMetadata.st_dev == descriptorMetadata.st_dev,
          currentMetadata.st_ino == descriptorMetadata.st_ino,
          unlink(path) == 0 else {
        throw HostwrightDiagnostic(
            code: .imageDenied,
            message: "Exact image archive cleanup lost its target identity."
        )
    }
    let parent = (path as NSString).deletingLastPathComponent
    let parentDescriptor = open(
        parent,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC
    )
    guard parentDescriptor >= 0 else {
        throw HostwrightDiagnostic(
            code: .imagePartialEffect,
            message: "Image archive was removed but its parent could not be synced."
        )
    }
    defer { close(parentDescriptor) }
    guard fsync(parentDescriptor) == 0 else {
        throw HostwrightDiagnostic(
            code: .imagePartialEffect,
            message: "Image archive was removed but its parent sync failed."
        )
    }
    return true
}
